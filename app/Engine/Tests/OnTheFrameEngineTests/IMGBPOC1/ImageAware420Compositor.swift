import AVFoundation
import CoreGraphics
import Foundation
@testable import OnTheFrameEngine

enum IBContract {
    static let w = 1920, h = 1080
    static let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    static let attachments: [String: Any] = [
        kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCVImageBufferChromaLocationTopFieldKey as String: kCVImageBufferChromaLocation_Left]
    static let writerTags: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    static func error(_ message: String, code: Int = 1) -> NSError { NSError(domain: "IMG-B-POC-1",code: code,userInfo: [NSLocalizedDescriptionKey: message]) }
    static func tag(_ pb: CVPixelBuffer) {
        for (key,value) in attachments { CVBufferSetAttachment(pb,key as CFString,value as CFTypeRef,.shouldPropagate) }
    }
    static func profile() throws -> CGColorSpace {
        guard let space = CVImageBufferCreateColorSpaceFromAttachments(attachments as CFDictionary) else { throw error("709 profile synthesis unsupported",code: 300) }
        return space.takeRetainedValue()
    }
    static func validate(_ pb: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(pb) == format, CVPixelBufferGetWidth(pb) == w,
              CVPixelBufferGetHeight(pb) == h,CVPixelBufferGetPlaneCount(pb) == 2 else { throw error("unsupported source/render format or size",code: 300) }
        for key in [kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey,kCVImageBufferYCbCrMatrixKey,kCVImageBufferChromaLocationTopFieldKey] {
            let expected = attachments[key as String] as? String
            guard let value = CVBufferCopyAttachment(pb,key,nil) as? String,value == expected else { throw error("source color contract: \(key)",code: 300) }
        }
    }
}

struct IBImage: Sendable { let rgba: [UInt8] }

/// Component LUTs use the declared 709 ICC profile and sRGB with identical primaries.
/// No per-frame full-canvas RGB intermediate is retained by the candidate.
final class IBTransfer: @unchecked Sendable {
    let toSRGB: [Float], to709: [Float]
    init() throws {
        let profile = try IBContract.profile()
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { throw IBContract.error("sRGB") }
        toSRGB = try Self.ramp(from: profile,to: sRGB)
        to709 = try Self.ramp(from: sRGB,to: profile)
    }
    private static func ramp(from: CGColorSpace,to: CGColorSpace) throws -> [Float] {
        let n = 4097
        var samples = [UInt16](repeating: 65535,count: n*4)
        for x in 0..<n { let v = UInt16((Double(x)*65535/Double(n-1)).rounded());samples[x*4] = v;samples[x*4+1] = v;samples[x*4+2] = v }
        let data = samples.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: n,height: 1,bitsPerComponent: 16,bitsPerPixel: 64,bytesPerRow: n*8,
                space: from,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),provider: provider,decode: nil,shouldInterpolate: false,intent: .relativeColorimetric),
              let context = CGContext(data: nil,width: n,height: 1,bitsPerComponent: 32,bytesPerRow: n*16,space: to,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let address = context.data else { throw IBContract.error("float ICC LUT unsupported",code: 300) }
        context.interpolationQuality = .none;context.draw(image,in: CGRect(x: 0,y: 0,width: n,height: 1))
        let values = address.assumingMemoryBound(to: Float.self)
        return (0..<n).map { values[$0*4] }
    }
    @inline(__always) func convert(_ v: Float,table: [Float]) -> Float {
        let p = max(0,min(1,v))*4096, i = min(4095,Int(p)), a = p-Float(i)
        return table[i]*(1-a)+table[i+1]*a
    }
}

final class IBLog: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[String: Any]] = []
    func add(_ row: [String: Any]) { lock.lock();rows.append(row);lock.unlock() }
    var snapshot: [[String: Any]] { lock.lock();defer { lock.unlock() };return rows }
}

final class IBInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false, containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let bottom: CMPersistentTrackID, top: CMPersistentTrackID
    let frame: Int, png: IBImage, transfer: IBTransfer, log: IBLog
    init(frame: Int,bottom: CMPersistentTrackID,top: CMPersistentTrackID,png: IBImage,transfer: IBTransfer,log: IBLog) {
        self.frame = frame;self.bottom = bottom;self.top = top;self.png = png;self.transfer = transfer;self.log = log
        timeRange = CMTimeRange(start: CMTime(value: Int64(frame),timescale: 30),duration: CMTime(value: 1,timescale: 30))
        requiredSourceTrackIDs = (frame >= 2 && frame < 4 ? [bottom,top] : [bottom]).map { NSNumber(value: $0) }
    }
}

final class IB420Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: [IBContract.format]] }
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [IBContract.format],kCVPixelBufferIOSurfacePropertiesKey as String: [String:Int]()]
    private let lock = NSLock()
    private let admission: IBAdmission<CVPixelBuffer>
    private var context: AVVideoCompositionRenderContext?
    override init() {
        let workers = DispatchQueue(label:"dev.ontheframe.img-b-poc1.workers",attributes:.concurrent)
        admission = IBAdmission(pendingLimit:4,pendingTimeout:90,executor:{ work in workers.async(execute:DispatchWorkItem(block:work)) })
        super.init()
    }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { lock.lock();context = newRenderContext;lock.unlock() }
    func cancelAllPendingVideoCompositionRequests() { admission.cancelAll() }
    private struct Box: @unchecked Sendable { let request: AVAsynchronousVideoCompositionRequest }
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let ins = request.videoCompositionInstruction as? IBInstruction
        let box = Box(request: request)
        admission.submit(tag:"frame\(ins?.frame ?? -1)",work:{ [self] lease in
            process(box.request,ins:ins,lease:lease)
        },completion:{ [self] result in
            ins?.log.add(["event":"admission-terminal","frame":ins?.frame ?? -1,"scheduler":admission.snapshot])
            switch result {
            case .success(let output):box.request.finish(withComposedVideoFrame:output)
            case .failure(let error):box.request.finish(with:error)
            case .cancelled:box.request.finishCancelledRequest()
            }
        })
    }
    private func process(_ request: AVAsynchronousVideoCompositionRequest,ins: IBInstruction?,lease: IBLease) -> IBTerminal<CVPixelBuffer> {
        guard let ins else { return .failure(IBContract.error("instruction",code:200)) }
        let started = Date()
        let perf = IBPerfProbe.enabled ? IBPerfProbe():nil
        if lease.isCancelled { ins.log.add(["event":"cancelled-before","frame":ins.frame]);return .cancelled }
        do {
            let expected = CMTime(value: Int64(ins.frame),timescale: 30)
            guard CMTimeCompare(request.compositionTime,expected) == 0 else { throw IBContract.error("composition request off grid",code: 200) }
            guard let bottom = request.sourceFrame(byTrackID: ins.bottom) else { throw IBContract.error("missing bottom",code: 200) }
            let topActive = ins.frame >= 2 && ins.frame < 4
            let top = topActive ? request.sourceFrame(byTrackID: ins.top) : nil
            if topActive && top == nil { throw IBContract.error("missing top",code: 200) }
            perf?.mark("A-sourceFrame-lookup")
            try IBContract.validate(bottom);if let top { try IBContract.validate(top) }
            var sources: [[String: Any]] = []
            for (id,pb) in [(ins.bottom,Optional(bottom)),(ins.top,top)] {
                guard let pb else { continue }
                guard let t = ExperimentalCompositor.movieTime(pb),CMTimeCompare(t,expected) == 0 else { throw IBContract.error("missing/stale source timestamp",code: 200) }
                CVPixelBufferLockBaseAddress(pb,.readOnly)
                guard let address = CVPixelBufferGetBaseAddressOfPlane(pb,0) else { CVPixelBufferUnlockBaseAddress(pb,.readOnly);throw IBContract.error("source plane",code: 200) }
                let y = address.assumingMemoryBound(to: UInt8.self),stride = CVPixelBufferGetBytesPerRowOfPlane(pb,0)
                var identifier = 0
                for bit in 0..<3 { if y[40*stride+40+bit*48] > 128 { identifier |= 1 << bit } }
                CVPixelBufferUnlockBaseAddress(pb,.readOnly)
                guard identifier == ins.frame else { throw IBContract.error("source ID \(identifier) expected \(ins.frame)",code: 200) }
                sources.append(["track":id,"sourceFrameID":identifier,"time":"\(t.value)/\(t.timescale)","pixelFormat":CVPixelBufferGetPixelFormatType(pb)])
            }
            perf?.mark("source-validation-ID-metadata")
            lock.lock();let ctx = context;lock.unlock()
            guard let output = ctx?.newPixelBuffer() else { throw IBContract.error("render buffer",code: 300) }
            guard CVPixelBufferGetPixelFormatType(output) == IBContract.format,CVPixelBufferGetWidth(output) == IBContract.w,
                  CVPixelBufferGetHeight(output) == IBContract.h else { throw IBContract.error("output not FHD420v",code: 300) }
            perf?.mark("F-context-buffer-allocation")
            try render(bottom: bottom,top: top,out: output,ins: ins,deadline: started.addingTimeInterval(30))
            perf?.mark("CDE-and-pixel-writes")
            IBContract.tag(output)
            if lease.isCancelled { ins.log.add(["event":"cancelled-after","frame":ins.frame]);return .cancelled }
            perf?.mark("output-tags-and-cancel-check")
            if let perf { ins.log.add(["event":"performance-spans","frame":ins.frame,"requestID":lease.id,"spans":perf.rows,"activeTotal":perf.total]) }
            ins.log.add(["event":"rendered","frame":ins.frame,"requestID":lease.id,"sources":sources,"seconds":Date().timeIntervalSince(started),"outputFormat":CVPixelBufferGetPixelFormatType(output)])
            return .success(output)
        } catch {
            ins.log.add(["event":"failed","frame":ins.frame,"error":String(describing: error)])
            return .failure(error)
        }
    }
    private struct Planes {
        let y: UnsafeMutablePointer<UInt8>,uv: UnsafeMutablePointer<UInt8>,ys: Int,uvs: Int
        init(_ pb: CVPixelBuffer) throws {
            guard let yy = CVPixelBufferGetBaseAddressOfPlane(pb,0),let cc = CVPixelBufferGetBaseAddressOfPlane(pb,1) else { throw IBContract.error("plane address") }
            y = yy.assumingMemoryBound(to: UInt8.self);uv = cc.assumingMemoryBound(to: UInt8.self)
            ys = CVPixelBufferGetBytesPerRowOfPlane(pb,0);uvs = CVPixelBufferGetBytesPerRowOfPlane(pb,1)
        }
    }
    @inline(__always) private func byte(_ v: Float) -> UInt8 { UInt8(max(0,min(255,v.rounded()))) }
    // PERF04: test-only offline driver access; pixel body and AVFoundation process path unchanged.
    func render(bottom: CVPixelBuffer,top: CVPixelBuffer?,out: CVPixelBuffer,ins: IBInstruction,deadline: Date) throws {
        guard ins.png.rgba.count == IBContract.w*IBContract.h*4 else { throw IBContract.error("PNG bounds",code: 200) }
        CVPixelBufferLockBaseAddress(bottom,.readOnly);if let top { CVPixelBufferLockBaseAddress(top,.readOnly) };CVPixelBufferLockBaseAddress(out,[])
        defer { CVPixelBufferUnlockBaseAddress(out,[]);if let top { CVPixelBufferUnlockBaseAddress(top,.readOnly) };CVPixelBufferUnlockBaseAddress(bottom,.readOnly) }
        let b = try Planes(bottom),t = try top.map { try Planes($0) },o = try Planes(out)
        let imageActive = ins.frame >= 1 && ins.frame < 5, width = IBContract.w,height = IBContract.h
        // Integer-only gate: top translated (+960,+540), 1:1 pixels. No image-aware visibility culler.
        try ins.png.rgba.withUnsafeBufferPointer { png in
            for y in stride(from: 0,to: height,by: 2) {
                if y % 64 == 0 && Date() > deadline { throw IBContract.error("render time budget",code: 300) }
                for x in stride(from: 0,to: width,by: 2) {
                    if let t,x >= 960,y >= 540 {
                        let sx = x-960,sy = y-540
                        o.y[y*o.ys+x] = t.y[sy*t.ys+sx];o.y[y*o.ys+x+1] = t.y[sy*t.ys+sx+1]
                        o.y[(y+1)*o.ys+x] = t.y[(sy+1)*t.ys+sx];o.y[(y+1)*o.ys+x+1] = t.y[(sy+1)*t.ys+sx+1]
                        o.uv[(y/2)*o.uvs+x] = t.uv[(sy/2)*t.uvs+sx];o.uv[(y/2)*o.uvs+x+1] = t.uv[(sy/2)*t.uvs+sx+1]
                        continue
                    }
                    if !imageActive {
                        o.y[y*o.ys+x] = b.y[y*b.ys+x];o.y[y*o.ys+x+1] = b.y[y*b.ys+x+1]
                        o.y[(y+1)*o.ys+x] = b.y[(y+1)*b.ys+x];o.y[(y+1)*o.ys+x+1] = b.y[(y+1)*b.ys+x+1]
                        o.uv[(y/2)*o.uvs+x] = b.uv[(y/2)*b.uvs+x];o.uv[(y/2)*o.uvs+x+1] = b.uv[(y/2)*b.uvs+x+1]
                        continue
                    }
                    var leftCb: Float = 0,leftCr: Float = 0
                    for dy in 0..<2 { for dx in 0..<2 {
                        let xx = x+dx,yy = y+dy,k = (yy*width+xx)*4
                        let yyv = (Float(b.y[yy*b.ys+xx])-16)/219
                        let cb = (Float(b.uv[(yy/2)*b.uvs+(xx/2)*2])-128)/224
                        let cr = (Float(b.uv[(yy/2)*b.uvs+(xx/2)*2+1])-128)/224
                        let a = Float(png[k+3])/255,remain = 1-a
                        let r = ins.transfer.convert(Float(png[k])/255 + remain*ins.transfer.convert(yyv+1.5748*cr,table: ins.transfer.toSRGB),table: ins.transfer.to709)
                        let g = ins.transfer.convert(Float(png[k+1])/255 + remain*ins.transfer.convert(yyv-0.187324*cb-0.468124*cr,table: ins.transfer.toSRGB),table: ins.transfer.to709)
                        let blue = ins.transfer.convert(Float(png[k+2])/255 + remain*ins.transfer.convert(yyv+1.8556*cb,table: ins.transfer.toSRGB),table: ins.transfer.to709)
                        let l = 0.2126*r+0.7152*g+0.0722*blue
                        o.y[yy*o.ys+xx] = byte(16+219*l)
                        if dx == 0 { leftCb += (blue-l)/1.8556;leftCr += (r-l)/1.5748 }
                    } }
                    // Declared Left chroma: first column, mean of the two vertical samples.
                    o.uv[(y/2)*o.uvs+x] = byte(128+112*leftCb)
                    o.uv[(y/2)*o.uvs+x+1] = byte(128+112*leftCr)
                }
            }
        }
    }
}
