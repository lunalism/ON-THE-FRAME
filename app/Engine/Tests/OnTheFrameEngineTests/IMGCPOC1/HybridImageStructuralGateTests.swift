import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import CryptoKit
@testable import OnTheFrameEngine

/// IMG-C-POC-1. Explicit opt-in; no application/model/export integration.
final class HybridImageStructuralGateTests: XCTestCase {
    let w = 1920, h = 1080, frames = 6
    var root: URL!
    var records: [[String: Any]] = []
    var peakRSS: UInt64 = 0
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let tags: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                              AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                              AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    struct Case { let name: String; let url: URL; let white: URL; let size: CGSize; let transform: CGAffineTransform }
    func error(_ message: String) -> NSError { NSError(domain: "IMG-C-POC-1:" + message, code: 1) }
    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["OTF_IMG_C_POC1_RUN"] else { throw XCTSkip("IMG-C-POC-1 opt-in") }
        let base = URL(fileURLWithPath: path).standardizedFileURL
        let allowed = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path + "/"
        guard base.path.hasPrefix(allowed) else { throw error("output-root") }
        root = base.appendingPathComponent("structural")
        guard !FileManager.default.fileExists(atPath: root.path) else { throw error("fresh-root-required") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func rss() -> UInt64 {
        var info = mach_task_basic_info(); var n = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / 4)
        _ = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n)
        } }
        return info.resident_size
    }
    func safe(_ value: Any) -> Any {
        if let d = value as? [String: Any] { return d.mapValues(safe) }
        if let a = value as? [Any] { return a.map(safe) }
        if let n = value as? NSNumber, !n.doubleValue.isFinite { return "nonfinite:" + String(describing: n) }
        return value
    }
    func note(_ label: String, _ fields: [String: Any]) throws {
        let current = rss(); peakRSS = max(peakRSS, current)
        records.append(["name": label, "fields": safe(fields), "rssBytes": current])
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json"), options: .atomic)
        print("IMG-C-POC-1 \(label): \(fields)")
        guard current <= 1_073_741_824 else { throw error("RSS-limit") }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let url = enumerator?.nextObject() as? URL { total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        guard total <= 536_870_912 else { throw error("artifact-limit") }
    }
    func png(_ bytes: [UInt8], _ label: String) throws {
        guard bytes.count == w*h*4 else { throw error("PNG-size") }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let im = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w*4, space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent(label + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, im, nil); guard CGImageDestinationFinalize(dest) else { throw error("PNG-write") }
    }
    func video(_ label: String, width: Int, height: Int, kind: String, rotation: Bool = false, colored: Bool = false) async throws -> URL {
        let url = root.appendingPathComponent(label + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoColorPropertiesKey: tags,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false, AVVideoAverageBitRateKey: 8_000_000]])
        if rotation { input.transform = CGAffineTransform(a: 0,b: 1,c: -1,d: 0,tx: CGFloat(height),ty: 0) }
        guard writer.canAdd(input) else { throw error("writer-input") }; writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.startWriting() else { throw writer.error ?? error("start-writer") }
        writer.startSession(atSourceTime: .zero)
        for f in 0..<frames {
            var pb: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess,
                  let pb else { throw error("allocate") }
            CVPixelBufferLockBaseAddress(pb, [])
            guard let address = CVPixelBufferGetBaseAddress(pb) else { throw error("base-address") }
            let p = address.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<height { for x in 0..<width {
                var v = kind == "white" ? 255 : (kind == "black" ? 0 : (kind == "bottom" ? 32 + f*8 : 180 + f*6))
                if kind == "bottom" || kind == "top" {
                    if x >= 64 && x < 128 && y >= 64 && y < 128 { v = kind == "bottom" ? 96 + f*4 : 240 - f*4 }
                    if x >= width-96 && y >= height-64 { v = kind == "bottom" ? 16+f*4 : 128+f*4 }
                }
                let k = y*stride+x*4; p[k] = UInt8(v); p[k+1] = UInt8(v); p[k+2] = UInt8(v); p[k+3] = 255
                if colored {
                    p[k] = UInt8(kind == "bottom" ? v : 24)
                    p[k+1] = UInt8(48+f*3)
                    p[k+2] = UInt8(kind == "top" ? v : 24)
                }
            } }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status != .failed else { writer.cancelWriting(); throw error("writer-timeout") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard adaptor.append(pb, withPresentationTime: CMTime(value: Int64(f), timescale: 30)) else { throw writer.error ?? error("append") }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
        await writer.finishWriting(); guard writer.status == .completed else { throw writer.error ?? error("finish") }
        try note("fixture", ["file": url.lastPathComponent, "width": width, "height": height, "frames": frames,
                              "fps": 30, "codec": "H264", "rotationMetadata": rotation, "pattern": kind, "colored": colored])
        return url
    }
    func composition(bottom: URL, top: URL, transform: CGAffineTransform, active: Bool) async throws -> (AVComposition, AVVideoComposition) {
        let comp = AVMutableComposition()
        var tracks: [AVMutableCompositionTrack] = []
        for u in [bottom, top] {
            let asset = AVURLAsset(url: u)
            let sourceTracks = try await asset.loadTracks(withMediaType: .video)
            let source = try XCTUnwrap(sourceTracks.first)
            let track = try XCTUnwrap(comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 6, timescale: 30)), of: source, at: .zero)
            tracks.append(track)
        }
        let vc = AVMutableVideoComposition(); vc.renderSize = CGSize(width: w, height: h); vc.frameDuration = CMTime(value: 1, timescale: 30)
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for (lo, hi) in [(0,1),(1,5),(5,6)] {
            let ins = AVMutableVideoCompositionInstruction(); ins.timeRange = CMTimeRange(start: CMTime(value: Int64(lo), timescale: 30), duration: CMTime(value: Int64(hi-lo), timescale: 30))
            ins.backgroundColor = CGColor(gray: 0, alpha: 1)
            let lower = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[0]); lower.setTransform(CGAffineTransform(scaleX: 2,y: 2), at: .zero)
            if active && lo == 1 {
                let upper = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[1]); upper.setTransform(transform, at: .zero)
                ins.layerInstructions = [upper, lower]
            } else { ins.layerInstructions = [lower] }
            instructions.append(ins)
        }
        vc.instructions = instructions; return (comp, vc)
    }
    func read(_ asset: AVAsset, vc: AVVideoComposition? = nil, frame: Int) async throws -> (bytes: [UInt8], width: Int, height: Int) {
        let reader = try AVAssetReader(asset: asset), tracks = try await asset.loadTracks(withMediaType: .video)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output: AVAssetReaderOutput
        if let vc { let out = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: settings); out.videoComposition = vc; output = out }
        else { output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: settings) }
        guard reader.canAdd(output) else { throw error("reader-output") }; reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(value: Int64(frame), timescale: 30), duration: CMTime(value: 1, timescale: 30))
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample) else { throw reader.error ?? error("sample") }
        defer { reader.cancelReading() }
        let actual = CMSampleBufferGetPresentationTimeStamp(sample)
        guard CMTimeCompare(actual, CMTime(value: Int64(frame), timescale: 30)) == 0 else { throw error("wrong-PTS") }
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        guard width > 0, height > 0, width <= 1920, height <= 1080,
              CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { throw error("decoded-size-or-format") }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(pb) else { throw error("read-base") }
        let base = address.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 255, count: width*height*4)
        for y in 0..<height { for x in 0..<width { let k = (y*width+x)*4, j = y*stride+x*4
            out[k] = base[j+2]; out[k+1] = base[j+1]; out[k+2] = base[j]
        } }
        return (out, width, height)
    }
    func bilinear(_ bytes: [UInt8], width: Int, height: Int, x: Double, y: Double, channel: Int) -> Double {
        let px = x-0.5, py = y-0.5, ix = Int(floor(px)), iy = Int(floor(py)), fx = px-Double(ix), fy = py-Double(iy)
        func at(_ xx: Int, _ yy: Int) -> Double { Double(bytes[(min(height-1,max(0,yy))*width+min(width-1,max(0,xx)))*4+channel]) }
        return at(ix,iy)*(1-fx)*(1-fy)+at(ix+1,iy)*fx*(1-fy)+at(ix,iy+1)*(1-fx)*fy+at(ix+1,iy+1)*fx*fy
    }
    func over(_ foreground: Double, alpha: Double, _ background: Double) -> Double { foreground*alpha + background*(1-alpha) }
    func testStructuralGate() async throws {
        XCTAssertEqual(over(200, alpha: 1, 40), 200)
        XCTAssertEqual(over(200, alpha: 0.5, 40), 120)
        XCTAssertEqual(over(100, alpha: 0.5, 40), 70)
        XCTAssertEqual(over(200, alpha: 0.25, over(100, alpha: 0.5, 40)), 102.5)
        try note("contract", ["reference": "unflattened decoded source layers, independent bilinear, encoded RGB code-domain; native white/black coverage probe separately labeled",
            "candidate": "one native flattened video + separate image stage; binary mask ONLY when probe supports hard coverage",
            "qualityGatesUnchanged": "40dB/flat3; no final color ACCEPT", "handChecks": "opaque200,half120,middle70,fractional-top102.5"])
        let bottom = try await video("bottom-changing", width: 960,height: 540,kind: "bottom")
        let top = try await video("top-changing", width: 960,height: 540,kind: "top")
        let portrait = try await video("top-portrait", width: 540,height: 960,kind: "top")
        let rotated = try await video("top-rotated", width: 960,height: 540,kind: "top",rotation: true)
        let black = try await video("probe-black",width: 960,height: 540,kind: "black")
        let white = try await video("probe-white",width: 960,height: 540,kind: "white")
        let portraitWhite = try await video("probe-portrait-white",width: 540,height: 960,kind: "white")
        let render = CGSize(width: w,height: h), wide = CGSize(width: 960,height: 540), tall = CGSize(width: 540,height: 960)
        var pngInputs: [Int: [UInt8]] = [:]
        for a in [0,128,255] {
            var bytes = [UInt8](repeating: 0,count: w*h*4)
            for k in stride(from: 0,to: bytes.count,by: 4) {
                let v = UInt8((100*a+127)/255); bytes[k] = v; bytes[k+1] = v; bytes[k+2] = v; bytes[k+3] = UInt8(a)
            }
            let label = "middle-alpha\(a)"; try png(bytes,label)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent(label+".png") as CFURL,nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
            let context = try XCTUnwrap(CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,
                space: cs,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image,in: CGRect(x: 0,y: 0,width: w,height: h))
            let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let decoded = Array(UnsafeBufferPointer(start: data,count: w*h*4))
            guard decoded == bytes else { throw error("PNG-roundtrip") }; pngInputs[a] = decoded
        }
        let rotation = CGAffineTransform(a: 0,b: 1,c: -1,d: 0,tx: 540,ty: 0)
        let cases = [Case(name: "A-integer",url: top,white: white,size: wide,transform: CGAffineTransform(translationX: 240,y: 180)),
            Case(name: "B-fractional",url: top,white: white,size: wide,transform: CGAffineTransform(translationX: 240.5,y: 180.5)),
            Case(name: "C-aspect-fit-scaled",url: top,white: white,size: wide,transform: CGAffineTransform(a: 1.25,b: 0,c: 0,d: 1.25,tx: 360,ty: 202.5)),
            Case(name: "D-crop",url: top,white: white,size: wide,transform: CGAffineTransform(a: 2.5,b: 0,c: 0,d: 2.5,tx: -1200,ty: -600)),
            Case(name: "E-portrait",url: portrait,white: portraitWhite,size: tall,transform: CompositionPlanner.fitTransform(natural: tall,preferred: .identity,render: render)),
            Case(name: "F-rot90",url: rotated,white: white,size: wide,transform: CompositionPlanner.fitTransform(natural: wide,preferred: rotation,render: render))]
        var allWithinThree = true
        for c in cases {
            let probePlan = try await composition(bottom: black,top: c.white,transform: c.transform,active: true)
            let probe = try await read(probePlan.0,vc: probePlan.1,frame: 2).bytes
            var mask = [Bool](repeating: false,count: w*h), partial = 0, idealMismatch = 0, firstPartial: [Int] = []
            let inv = c.transform.inverted()
            for y in 0..<h { for x in 0..<w { let pixel = y*w+x, value = Int(probe[pixel*4])
                mask[pixel] = value >= 128
                if value > 3 && value < 252 { partial += 1; if firstPartial.isEmpty { firstPartial = [x,y,value] } }
                let p = CGPoint(x: Double(x)+0.5,y: Double(y)+0.5).applying(inv)
                let ideal = p.x >= 0 && p.y >= 0 && p.x < c.size.width && p.y < c.size.height
                if ideal != mask[pixel] { idealMismatch += 1 }
            } }
            try png(probe,c.name + "-coverage")
            try note(c.name + "-coverage",["transform": String(describing: c.transform),"partialPixels": partial,
                "firstPartial": firstPartial,"idealPixelCenterMismatch": idealMismatch,"coveredPixels": mask.filter { $0 }.count,
                "maskProvenance": "separate native uniform opaque white/black calibration; not the candidate flattened image"])
            if partial > 0 {
                // Do not substitute a threshold mask for a partially covered native layer.
                try note("STOP",["verdict": "INCONCLUSIVE", "case": c.name,
                    "reason": "native grayscale intermediate edge observed; stop before binary image stage. Need distinguish raster coverage from reconstruction before claiming irreversible-loss witness",
                    "mathematicalWitness": "For 0<c<1: F=c*T+(1-c)*B; desired=c*T+(1-c)*(a*I+(1-a)*B); F alone does not determine B or T."])
                return
            }
            let plan = try await composition(bottom: bottom,top: c.url,transform: c.transform,active: true)
            for f in [0,1,2,4,5] {
                let flat = try await read(plan.0,vc: plan.1,frame: f).bytes
                let lower = try await read(AVURLAsset(url: bottom),frame: f)
                let upper = try await read(AVURLAsset(url: c.url),frame: f)
                for a in [0,128,255] {
                    let imageBytes = try XCTUnwrap(pngInputs[a])
                    let imageActive = f >= 2 && f < 5, topActive = f >= 1 && f < 5
                    var reference = [UInt8](repeating: 255,count: w*h*4), candidate = flat
                    var maxError = 0, mismatches = 0, outsideMax = 0, insideMax = 0, worst: [Int] = []
                    for y in 0..<h { for x in 0..<w {
                        let pixel = y*w+x, k = pixel*4
                        let p = CGPoint(x: Double(x)+0.5,y: Double(y)+0.5).applying(inv)
                        let occluded = topActive && mask[pixel]
                        let alpha = imageActive ? Double(imageBytes[k+3])/255 : 0
                        for ch in 0..<3 {
                            let foreground = alpha > 0 ? Double(imageBytes[k+ch])/alpha : 0
                            let b = bilinear(lower.bytes,width: lower.width,height: lower.height,x: (Double(x)+0.5)/2,y: (Double(y)+0.5)/2,channel: ch)
                            var desired = over(foreground,alpha: alpha,b)
                            if occluded { desired = bilinear(upper.bytes,width: upper.width,height: upper.height,x: p.x,y: p.y,channel: ch) }
                            reference[k+ch] = UInt8(max(0,min(255,desired.rounded())))
                            if !occluded { candidate[k+ch] = UInt8(max(0,min(255,over(foreground,alpha: alpha,Double(flat[k+ch])).rounded()))) }
                        }
                        let e = (0..<3).map { abs(Int(candidate[k+$0])-Int(reference[k+$0])) }.max() ?? 0
                        if e > 3 { mismatches += 1 }
                        if e > maxError { maxError = e; worst = [x,y,Int(candidate[k]),Int(reference[k])] }
                        if occluded { insideMax = max(insideMax,e) } else { outsideMax = max(outsideMax,e) }
                    } }
                    allWithinThree = allWithinThree && mismatches == 0
                    try note(c.name + "-frame\(f)-alpha\(a)",["PTS": "\(f)/30","maximum": maxError,"pixelsOver3": mismatches,
                        "topRegionMax": insideMax,"lowerRegionMax": outsideMax,"worstXYCandidateReference": worst,
                        "imageActive": imageActive,"topActive": topActive])
                    if f == 2 && a == 128 { try png(candidate,c.name+"-candidate"); try png(reference,c.name+"-reference") }
                }
            }
        }
        try note("decision",["verdict": allWithinThree ? "STRUCTURAL PASS" : "INCONCLUSIVE",
            "limitedTo": "opaque grayscale H264, six measured transforms, native-calibrated hard coverage; not a generic geometry recipe or production path",
            "nativeCoverageCalibrationRequired": true,"colorMatrixRun": false,"exportsRun": 0,"peakObservedRSS": peakRSS,
            "reason": allWithinThree ? "unflattened independent layer values agree within3 with native calibration" : "sampling/code-domain discrepancy prevents a structural pass; no irreversible-loss witness established"])
    }
    /// One color witness, not the deferred alpha/export/performance matrix.
    /// The grayscale gate cannot establish that chroma reconstructed at a video edge remains layer-separable.
    func testColorInterleavingWitness() async throws {
        guard let previous = ProcessInfo.processInfo.environment["OTF_IMG_C_POC1_PREVIOUS"] else { throw XCTSkip("existing grayscale gate required") }
        let old = URL(fileURLWithPath: previous)
        let bottom = try await video("bottom-blue-changing",width: 960,height: 540,kind: "bottom",colored: true)
        let top = try await video("top-red-changing",width: 960,height: 540,kind: "top",colored: true)
        let transform = CGAffineTransform(translationX: 240.5,y: 180.5), inv = transform.inverted()
        let probePlan = try await composition(bottom: old.appendingPathComponent("probe-black.mov"),
            top: old.appendingPathComponent("probe-white.mov"),transform: transform,active: true)
        let probe = try await read(probePlan.0,vc: probePlan.1,frame: 2).bytes
        let plan = try await composition(bottom: bottom,top: top,transform: transform,active: true)
        let flat = try await read(plan.0,vc: plan.1,frame: 2).bytes
        let b = try await read(AVURLAsset(url: bottom),frame: 2), t = try await read(AVURLAsset(url: top),frame: 2)
        var reference = [UInt8](repeating: 255,count: w*h*4), candidate = flat
        var mismatch = 0, maximum = 0, interiorMax = 0, edgeMax = 0, worst: [Int] = []
        // Use the same existing, roundtrip-verified PNG's actual premultiplied code values.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(old.appendingPathComponent("middle-alpha128.png") as CFURL,nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        let context = try XCTUnwrap(CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in: CGRect(x: 0,y: 0,width: w,height: h))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let k = (y*w+x)*4, occluded = probe[k] >= 128
            let p = CGPoint(x: Double(x)+0.5,y: Double(y)+0.5).applying(inv)
            let a = Double(data[k+3])/255
            for ch in 0..<3 {
                let background = bilinear(b.bytes,width: b.width,height: b.height,x: (Double(x)+0.5)/2,y: (Double(y)+0.5)/2,channel: ch)
                let expected = occluded ? bilinear(t.bytes,width: t.width,height: t.height,x: p.x,y: p.y,channel: ch) : Double(data[k+ch])+background*(1-a)
                reference[k+ch] = UInt8(max(0,min(255,expected.rounded())))
                if !occluded { candidate[k+ch] = UInt8(max(0,min(255,(Double(data[k+ch])+Double(flat[k+ch])*(1-a)).rounded()))) }
            }
            let e = (0..<3).map { abs(Int(candidate[k+$0])-Int(reference[k+$0])) }.max() ?? 0
            if e > 3 { mismatch += 1 }; if e > maximum { maximum = e; worst = [x,y] }
            let nearEdge = (abs(x-240)<=3 || abs(x-1199)<=3) && (177...723).contains(y)
                || (abs(y-180)<=3 || abs(y-719)<=3) && (237...1203).contains(x)
            if nearEdge { edgeMax = max(edgeMax,e) } else { interiorMax = max(interiorMax,e) }
        } }
        try png(candidate,"color-candidate");try png(reference,"color-unflattened-reference");try png(flat,"native-flattened")
        let xy = worst.isEmpty ? [0,0] : worst, k = (xy[1]*w+xy[0])*4
        try note("color-witness",["verdict": mismatch == 0 ? "STRUCTURAL PASS" : "INCONCLUSIVE",
            "maximum": maximum,"pixelsOver3": mismatch,"edgeMaximum": edgeMax,"nonVideoBoundaryMaximum": interiorMax,
            "worstXY": worst,"nativeAtWorst": Array(flat[k..<k+4]),"candidateAtWorst": Array(candidate[k..<k+4]),
            "referenceAtWorst": Array(reference[k..<k+4]),"PTS": "2/30", "transform": String(describing: transform),
            "reason": "Color witness is code-domain only. A mismatch is not by itself proof of irreversible flattening loss: native chroma reconstruction, resampling and transfer-space assumptions remain to be separated. No exports or broad matrix."])
    }
    /// Checks the proposed 420v boundary, rather than promoting the diagnostic BGRA result to a 420v claim.
    func testNative420BoundaryWitness() async throws {
        guard let previous = ProcessInfo.processInfo.environment["OTF_IMG_C_POC1_PREVIOUS"],
              let colored = ProcessInfo.processInfo.environment["OTF_IMG_C_POC1_COLOR"] else { throw XCTSkip("existing witnesses required") }
        let old = URL(fileURLWithPath: previous), color = URL(fileURLWithPath: colored)
        let bottom = color.appendingPathComponent("bottom-blue-changing.mov"), top = color.appendingPathComponent("top-red-changing.mov")
        let odd = ProcessInfo.processInfo.environment["OTF_IMG_C_POC1_ODD"] == "1"
        let transform = CGAffineTransform(translationX: odd ? 241 : 240.5,y: odd ? 181 : 180.5)
        let plan = try await composition(bottom: bottom,top: top,transform: transform,active: true)
        let reader = try AVAssetReader(asset: plan.0), tracks = try await plan.0.loadTracks(withMediaType: .video)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: tracks,videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            AVVideoColorPropertiesKey: tags])
        out.videoComposition = plan.1; reader.add(out)
        reader.timeRange = CMTimeRange(start: CMTime(value: 2,timescale: 30),duration: CMTime(value: 1,timescale: 30))
        guard reader.startReading(), let sample = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample) else { throw reader.error ?? error("420-read") }
        defer { reader.cancelReading() }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(pb) == w, CVPixelBufferGetHeight(pb) == h else { throw error("420-format") }
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),CMTime(value: 2,timescale: 30)),0)
        let probePlan = try await composition(bottom: old.appendingPathComponent("probe-black.mov"),top: old.appendingPathComponent("probe-white.mov"),transform: transform,active: true)
        let probe = try await read(probePlan.0,vc: probePlan.1,frame: 2).bytes
        let bgraFlat = try await read(plan.0,vc: plan.1,frame: 2).bytes
        let b = try await read(AVURLAsset(url: bottom),frame: 2), t = try await read(AVURLAsset(url: top),frame: 2)
        CVPixelBufferLockBaseAddress(pb,.readOnly); defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
        let yy = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,0)).assumingMemoryBound(to: UInt8.self)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,1)).assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb,0), uvs = CVPixelBufferGetBytesPerRowOfPlane(pb,1)
        func pixel(_ x: Int,_ y: Int) -> [Int] { [Int(yy[y*ys+x]),Int(uv[(y/2)*uvs+(x/2)*2]),Int(uv[(y/2)*uvs+(x/2)*2+1])] }
        var points: [[String: Any]] = []
        let dx = odd ? 1 : 0, dy = odd ? 1 : 0
        let coordinates = [(239+dx,400),(240+dx,400),(241+dx,400),(242+dx,400),
            (1198+dx,400),(1199+dx,400),(1200+dx,400),(1201+dx,400),
            (800,179+dy),(800,180+dy),(800,181+dy),(800,182+dy)]
        for (x,y) in coordinates {
            let k = (y*w+x)*4, codes = pixel(x,y), covered = probe[k] >= 128
            let p = CGPoint(x: Double(x)+0.5,y: Double(y)+0.5).applying(transform.inverted())
            let luma = (Double(codes[0])-16)*255/219, cb = (Double(codes[1])-128)*255/224, cr = (Double(codes[2])-128)*255/224
            // Explicit nearest chroma block reconstruction, a diagnostic assumption, NOT a new accepted sampler.
            let rgb = [luma+1.5748*cr,luma-0.187324*cb-0.468124*cr,luma+1.8556*cb].map { max(0,min(255,$0)) }
            var expected: [Int] = [], candidate: [Int] = []
            for ch in 0..<3 {
                let bg = bilinear(b.bytes,width: b.width,height: b.height,x: (Double(x)+0.5)/2,y: (Double(y)+0.5)/2,channel: ch)
                let ref = covered ? bilinear(t.bytes,width: t.width,height: t.height,x: p.x,y: p.y,channel: ch) : 50+bg*127/255
                expected.append(Int(ref.rounded())); candidate.append(Int((covered ? rgb[ch] : 50+rgb[ch]*127/255).rounded()))
            }
            points.append(["xy": [x,y],"native420YUV": codes,"topCovered": covered,
                "nativeBGRA-RGB": Array(bgraFlat[k..<k+3]),"nearest420RGB": rgb,"candidate": candidate,"unflattenedReference": expected,
                "maximumError": zip(candidate,expected).map { abs($0-$1) }.max() ?? 0])
        }
        try note("420-boundary",["verdict": "INCONCLUSIVE","format": "420v","colorAttachments": String(describing: CVBufferCopyAttachments(pb,.shouldPropagate)),
            "PTS": "2/30","points": points,"transform": String(describing: transform),"chromaRule": "nearest 2x2 diagnostic; no output/reference resampling amendment approved",
            "reason": "BGRA hard coverage does not prove layer-separable 420v chroma. This point inspection does not establish a native equal-flattened-output/different-required-output collision. Do not classify reconstruction/reference differences as a proven structural failure; stop before broad matrix."])
    }
    func constant420(_ label: String, cb: UInt8, cr: UInt8) async throws -> URL {
        let url = root.appendingPathComponent(label+".mov"), writer = try AVAssetWriter(outputURL: url,fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 960, AVVideoHeightKey: 540, AVVideoColorPropertiesKey: tags,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false,AVVideoAverageBitRateKey: 8_000_000]])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 960,kCVPixelBufferHeightKey as String: 540])
        guard writer.startWriting() else { throw writer.error ?? error("420-writer") }; writer.startSession(atSourceTime: .zero)
        for f in 0..<6 {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil,960,540,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,nil,&buffer) == kCVReturnSuccess,
                  let buffer else { throw error("420-allocate") }
            CVPixelBufferLockBaseAddress(buffer,[])
            let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer,0)).assumingMemoryBound(to: UInt8.self)
            let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer,1)).assumingMemoryBound(to: UInt8.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(buffer,0), uvs = CVPixelBufferGetBytesPerRowOfPlane(buffer,1)
            for row in 0..<540 { for x in 0..<960 { y[row*ys+x] = 85 } }
            for row in 0..<270 { for x in stride(from: 0,to: 960,by: 2) { uv[row*uvs+x] = cb; uv[row*uvs+x+1] = cr } }
            CVPixelBufferUnlockBaseAddress(buffer,[])
            CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
            CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
            CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
            CVBufferSetAttachment(buffer,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Left,.shouldPropagate)
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData { guard Date() < deadline,writer.status != .failed else { writer.cancelWriting();throw error("420-writer-timeout") };try await Task.sleep(nanoseconds: 1_000_000) }
            guard adaptor.append(buffer,withPresentationTime: CMTime(value: Int64(f),timescale: 30)) else { throw writer.error ?? error("420-append") }
        }
        input.markAsFinished();writer.endSession(atSourceTime: CMTime(value: 6,timescale: 30));await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? error("420-finish") }
        try note("collision-source",["file": url.lastPathComponent,"codec": "H264","size": [960,540],"frames": 6,"writer420": [85,Int(cb),Int(cr)]])
        return url
    }
    func nativePlanes(_ plan: (AVComposition,AVVideoComposition)) async throws -> (Data,[Int]) {
        let reader = try AVAssetReader(asset: plan.0), tracks = try await plan.0.loadTracks(withMediaType: .video)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks,videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,AVVideoColorPropertiesKey: tags])
        output.videoComposition = plan.1; reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(value: 2,timescale: 30),duration: CMTime(value: 1,timescale: 30))
        guard reader.startReading(),let sample = output.copyNextSampleBuffer(),let pb = CMSampleBufferGetImageBuffer(sample) else { throw reader.error ?? error("collision-reader") }
        defer { reader.cancelReading() }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(pb) == w,CVPixelBufferGetHeight(pb) == h else { throw error("collision-format") }
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),CMTime(value: 2,timescale: 30)),0)
        CVPixelBufferLockBaseAddress(pb,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
        var data = Data()
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,plane)).assumingMemoryBound(to: UInt8.self)
            let rows = CVPixelBufferGetHeightOfPlane(pb,plane),stride = CVPixelBufferGetBytesPerRowOfPlane(pb,plane)
            let bytes = CVPixelBufferGetWidthOfPlane(pb,plane)*(plane == 0 ? 1 : 2)
            for row in 0..<rows { data.append(base+row*stride,count: bytes) }
        }
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,0)).assumingMemoryBound(to: UInt8.self)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,1)).assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb,0),uvs = CVPixelBufferGetBytesPerRowOfPlane(pb,1)
        return (data,[Int(y[400*ys+1919]),Int(uv[200*uvs+1918]),Int(uv[200*uvs+1919])])
    }
    /// One predeclared same-luma/different-chroma pair, cropped to an odd one-pixel visible strip.
    /// If collision is not exact, record INCONCLUSIVE and stop; do not tune codec parameters.
    func testFlattened420Collision() async throws {
        guard let previous = ProcessInfo.processInfo.environment["OTF_IMG_C_POC1_PREVIOUS"],
              let colored = ProcessInfo.processInfo.environment["OTF_IMG_C_POC1_COLOR"] else { throw XCTSkip("existing witnesses required") }
        let old = URL(fileURLWithPath: previous), color = URL(fileURLWithPath: colored)
        let a = try await constant420("collision-top-A",cb: 101,cr: 190)
        let b = try await constant420("collision-top-B",cb: 140,cr: 90)
        let transform = CGAffineTransform(translationX: 1919,y: 0)
        let probePlan = try await composition(bottom: old.appendingPathComponent("probe-black.mov"),top: old.appendingPathComponent("probe-white.mov"),transform: transform,active: true)
        let probe = try await read(probePlan.0,vc: probePlan.1,frame: 2).bytes
        let pixel = (400*w+1919)*4
        guard probe[pixel] == 255 else { try note("collision-stop",["verdict": "INCONCLUSIVE","reason": "one-pixel strip not native-covered","probe": Int(probe[pixel])]);return }
        let lower = color.appendingPathComponent("bottom-blue-changing.mov")
        let planA = try await composition(bottom: lower,top: a,transform: transform,active: true)
        let planB = try await composition(bottom: lower,top: b,transform: transform,active: true)
        let flatA = try await nativePlanes(planA),flatB = try await nativePlanes(planB)
        let sourceA = try await read(AVURLAsset(url: a),frame: 2),sourceB = try await read(AVURLAsset(url: b),frame: 2)
        let sourcePixel = 400*960*4
        let expectedA = Array(sourceA.bytes[sourcePixel..<sourcePixel+3]),expectedB = Array(sourceB.bytes[sourcePixel..<sourcePixel+3])
        let nativeRGBA = try await read(planA.0,vc: planA.1,frame: 2).bytes
        var mismatches = 0,maximum = 0
        guard flatA.0.count == flatB.0.count else { throw error("collision-size") }
        for (x,y) in zip(flatA.0,flatB.0) { if x != y { mismatches += 1 };maximum = max(maximum,abs(Int(x)-Int(y))) }
        let differentRequired = zip(expectedA,expectedB).map { abs(Int($0)-Int($1)) }.max() ?? 0
        let failed = mismatches == 0 && differentRequired > 3
        try flatA.0.write(to: root.appendingPathComponent("native-A-420v.bin"))
        try flatB.0.write(to: root.appendingPathComponent("native-B-420v.bin"))
        // A pre-image RGB reconstruction collision alone is not yet a collision of the
        // required image-inserted output under the SAME final 420v sampling contract.
        // Keep the original run's stronger label as evidence, but do not promote it.
        try note("collision-decision",["verdict": "INCONCLUSIVE", "preImageRGBReconstructionCollision": failed,
            "qualification": "Original run labeled the RGB reconstruction collision STRUCTURAL FAIL. That label is insufficient for the overall gate: the sampled point is fully covered by the upper video, and the desired image-inserted final 420v outputs have not been shown to differ under identical sampling. No broader matrix is authorized.",
            "PTS": "2/30","transform": String(describing: transform),"probeAt1919x400": Int(probe[pixel]),
            "activePlaneBytes": flatA.0.count,"differentBytes": mismatches,"maximumByteDifference": maximum,
            "sha256A": SHA256.hash(data: flatA.0).map { String(format: "%02x",$0) }.joined(),
            "sha256B": SHA256.hash(data: flatB.0).map { String(format: "%02x",$0) }.joined(),
            "native420AtPointA": flatA.1,"native420AtPointB": flatB.1,
            "independentRequiredRGB-A": expectedA,"independentRequiredRGB-B": expectedB,
            "requiredMaximumDifference": differentRequired,"nativeBGRADiagnostic-A": Array(nativeRGBA[pixel..<pixel+3]),
            "middleImage": "same previously generated alpha128 PNG, lane between opaque top and bottom; top-covered point must retain top source identity",
            "informationLost": "The single visible top-video column has luma but no separately recoverable top chroma in the flattened 420v samples. Same flattened data + same image + same mask cannot produce both required colors. Extra source decoding or native decomposition would change the architecture.",
            "stop": "No further alpha/export/performance matrix or parameter tuning."])
    }
}
