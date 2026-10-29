import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import CryptoKit
import Darwin
import XCTest

final class IBDiagnostics {
    let root: URL, started = Date()
    var records: [[String: Any]] = [],peakRSS: UInt64 = 0
    init(root: URL) { self.root = root }
    func safe(_ value: Any) -> Any {
        if let d = value as? [String:Any] { return d.mapValues(safe) }
        if let a = value as? [Any] { return a.map(safe) }
        if let n = value as? NSNumber,!n.doubleValue.isFinite { return "nonfinite:"+String(describing:n) }
        return value
    }
    func rss() -> UInt64 {
        var info = mach_task_basic_info(),count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/4)
        _ = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self,capacity: Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
        return info.resident_size
    }
    func note(_ name: String,_ fields: [String:Any]) throws {
        let memory = rss();peakRSS = max(peakRSS,memory)
        records.append(["name":name,"fields":safe(fields),"rssBytes":memory,"elapsed":Date().timeIntervalSince(started)])
        let data = try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:root.appendingPathComponent("results.json"),options:.atomic)
        print("IMG-B-POC-1 \(name): \(fields)")
        guard memory <= 1_073_741_824 else { throw IBContract.error("observed RSS limit",code:300) }
        guard Date().timeIntervalSince(started) <= 120 else { throw IBContract.error("test execution 120s limit",code:300) }
        var total = 0
        let enumerator = FileManager.default.enumerator(at:root.deletingLastPathComponent(),includingPropertiesForKeys:[.fileSizeKey])
        while let u = enumerator?.nextObject() as? URL { total += (try? u.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0 }
        guard total <= 536_870_912 else { throw IBContract.error("artifact limit",code:300) }
    }
}

enum IBReference {
    static let w = IBContract.w,h = IBContract.h
    static func context(_ width: Int = w,_ height: Int = h,space: CGColorSpace? = nil) throws -> CGContext {
        guard let color = space ?? CGColorSpace(name:CGColorSpace.sRGB),let c = CGContext(data:nil,width:width,height:height,
            bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw IBContract.error("CG context",code:300) }
        return c
    }
    static func bytes(_ image: CGImage,space: CGColorSpace? = nil) throws -> [UInt8] {
        let c = try context(image.width,image.height,space:space);c.interpolationQuality = .none
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let data = c.data else { throw IBContract.error("CG data") }
        return Array(UnsafeBufferPointer(start:data.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
    }
    static func image(_ rgba: [UInt8],width: Int = w,height: Int = h,space: CGColorSpace? = nil) throws -> CGImage {
        guard rgba.count == width*height*4,let color = space ?? CGColorSpace(name:CGColorSpace.sRGB),
              let p = CGDataProvider(data:Data(rgba) as CFData),let im = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,
                bytesPerRow:width*4,space:color,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:p,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric) else { throw IBContract.error("image bounds/creation") }
        return im
    }
    static func save(_ image: CGImage,to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw IBContract.error("PNG destination") }
        CGImageDestinationAddImage(destination,image,nil);guard CGImageDestinationFinalize(destination) else { throw IBContract.error("PNG write") }
    }
    static func createPNG(_ url: URL) throws -> (CGImage,IBImage) {
        var rgba = [UInt8](repeating:255,count:w*h*4)
        for y in 0..<h { for x in 0..<w {
            let (r,g,b,a): (Int,Int,Int,Int) = x < 640 ? (200,50,26,128) : (x < 1280 ? (40,180,80,255) : (40,70,200,128))
            let k = (y*w+x)*4;rgba[k] = UInt8((r*a+127)/255);rgba[k+1] = UInt8((g*a+127)/255);rgba[k+2] = UInt8((b*a+127)/255);rgba[k+3] = UInt8(a)
        } }
        try save(image(rgba),to:url)
        return try loadPNG(url)
    }
    static func loadPNG(_ url: URL) throws -> (CGImage,IBImage) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL,nil),CGImageSourceGetCount(src) == 1,
              let im = CGImageSourceCreateImageAtIndex(src,0,nil),im.width == w,im.height == h,im.bitsPerComponent == 8 else { throw IBContract.error("PNG contract",code:300) }
        let rgba = try bytes(im)
        guard rgba[3] == 128,rgba[640*4+3] == 255,rgba[1280*4+3] == 128 else { throw IBContract.error("PNG alpha lost",code:200) }
        return (try image(rgba),IBImage(rgba:rgba))
    }
    /// Original sources are decoded separately; candidate arithmetic/LUTs are never used here.
    static func managed(_ pb: CVPixelBuffer) throws -> CGImage {
        let width = CVPixelBufferGetWidth(pb),height = CVPixelBufferGetHeight(pb)
        guard width == w,height == h else { throw IBContract.error("inspection dimensions",code:300) }
        var cg: CGImage?
        if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA {
            CVPixelBufferLockBaseAddress(pb,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
            guard let address = CVPixelBufferGetBaseAddress(pb),let attrs = CVBufferCopyAttachments(pb,.shouldPropagate),
                  let profile = CVImageBufferCreateColorSpaceFromAttachments(attrs) else { throw IBContract.error("source ICC absent",code:300) }
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let data = Data(bytes:address,count:stride*height)
            guard let provider = CGDataProvider(data:data as CFData) else { throw IBContract.error("BGRA provider") }
            cg = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:stride,space:profile.takeRetainedValue(),
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric)
        } else if CVPixelBufferGetPixelFormatType(pb) == IBContract.format {
            // IMG-B-QA-02: versioned, backing-independent diagnostic conversion only.
            return try image(IBCanonicalNV12.bytes(pb))
        } else { throw IBContract.error("inspection pixel format",code:300) }
        guard let cg,cg.colorSpace != nil else { throw IBContract.error("CG inspection profile",code:300) }
        return try image(bytes(cg))
    }
    static func read(_ asset: AVAsset,frame: Int,vc: AVVideoComposition? = nil,format: OSType = kCVPixelFormatType_32BGRA) async throws -> CVPixelBuffer {
        let reader = try AVAssetReader(asset:asset),tracks = try await asset.loadTracks(withMediaType:.video)
        let output: AVAssetReaderOutput
        let settings: [String:Any] = [kCVPixelBufferPixelFormatTypeKey as String:format]
        if let vc { let o = AVAssetReaderVideoCompositionOutput(videoTracks:tracks,videoSettings:settings);o.videoComposition = vc;output = o }
        else { guard let track = tracks.first else { throw IBContract.error("no track") };output = AVAssetReaderTrackOutput(track:track,outputSettings:settings) }
        reader.add(output);reader.timeRange = CMTimeRange(start:CMTime(value:Int64(frame),timescale:30),duration:CMTime(value:1,timescale:30))
        guard reader.startReading(),let sample = output.copyNextSampleBuffer(),let pb = CMSampleBufferGetImageBuffer(sample) else { throw reader.error ?? IBContract.error("original read") }
        defer { reader.cancelReading() }
        guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),CMTime(value:Int64(frame),timescale:30)) == 0 else { throw IBContract.error("source read PTS",code:200) }
        return pb
    }
    static func composite(bottom: CGImage,top: CGImage?,png: CGImage,frame: Int) throws -> CGImage {
        let c = try context();c.interpolationQuality = .none
        c.draw(bottom,in:CGRect(x:0,y:0,width:w,height:h))
        if frame >= 1 && frame < 5 { c.draw(png,in:CGRect(x:0,y:0,width:w,height:h)) }
        if let top,frame >= 2 && frame < 4 {
            // Project top-left (+960,+540), converted independently to Quartz rectangle.
            c.draw(top,in:CGRect(x:960,y:h-540-h,width:w,height:h))
        }
        guard let result = c.makeImage() else { throw IBContract.error("reference composite") };return result
    }
    /// Reference output sampling: CG converts complete sRGB reference to tagged709 RGBA8.
    /// Separate scalar conversion, not candidate blending or candidate transfer tables.
    static func sampled420(_ reference: CGImage) throws -> CVPixelBuffer {
        let rgb = try bytes(reference,space:IBContract.profile())
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil,w,h,IBContract.format,nil,&pb) == kCVReturnSuccess,let pb else { throw IBContract.error("reference420 allocate",code:300) }
        CVPixelBufferLockBaseAddress(pb,[]);defer { CVPixelBufferUnlockBaseAddress(pb,[]) }
        guard let yp = CVPixelBufferGetBaseAddressOfPlane(pb,0),let cp = CVPixelBufferGetBaseAddressOfPlane(pb,1) else { throw IBContract.error("reference plane") }
        let yplane = yp.assumingMemoryBound(to:UInt8.self),chroma = cp.assumingMemoryBound(to:UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb,0),cs = CVPixelBufferGetBytesPerRowOfPlane(pb,1)
        rgb.withUnsafeBufferPointer { p in
            for y in 0..<h { for x in 0..<w {
                let k = (y*w+x)*4,r = Double(p[k])/255,g = Double(p[k+1])/255,b = Double(p[k+2])/255
                let l = 0.2126*r+0.7152*g+0.0722*b
                yplane[y*ys+x] = UInt8(max(0,min(255,(16+219*l).rounded())))
                if x % 2 == 0 && y % 2 == 0 {
                    let next = k+w*4
                    let rr = Double(p[next])/255,gg = Double(p[next+1])/255,bb = Double(p[next+2])/255
                    let ll = 0.2126*rr+0.7152*gg+0.0722*bb
                    let u = 128+112*((b-l)/1.8556+(bb-ll)/1.8556)
                    let v = 128+112*((r-l)/1.5748+(rr-ll)/1.5748)
                    chroma[(y/2)*cs+x] = UInt8(max(0,min(255,u.rounded())))
                    chroma[(y/2)*cs+x+1] = UInt8(max(0,min(255,v.rounded())))
                }
            } }
        }
        IBContract.tag(pb);return pb
    }
    static func stats(_ actual: [UInt8],_ expected: [UInt8],region: CGRect? = nil) throws -> [String:Any] {
        guard actual.count == w*h*4,expected.count == actual.count else { throw IBContract.error("stats bounds") }
        let rect = region ?? CGRect(x:0,y:0,width:w,height:h)
        guard rect.minX >= 0,rect.minY >= 0,rect.maxX <= CGFloat(w),rect.maxY <= CGFloat(h),rect.width>0,rect.height>0 else { throw IBContract.error("ROI bounds") }
        var sum = 0.0,maximum = 0,flat = 0,over3 = 0,worstX = Int(rect.minX),worstY = Int(rect.minY),worstC = 0,edgeMax = 0,hist = [Int](repeating:0,count:256)
        actual.withUnsafeBufferPointer { a in expected.withUnsafeBufferPointer { b in
            for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
                let k = (y*w+x)*4
                let inFlat = (y >= 200 && y < 300 && ((x >= 100 && x < 200)||(x >= 800 && x < 900)||(x >= 1500 && x < 1600)))
                    || (y >= 800 && y < 900 && x >= 1500 && x < 1600)
                let edge = abs(x-640)<=3 || abs(x-1280)<=3 || abs(x-960)<=3 || abs(y-540)<=3
                var pixelMax = 0
                for c in 0..<3 {
                    let d = abs(Int(a[k+c])-Int(b[k+c]));sum += Double(d*d);hist[d] += 1;pixelMax = max(pixelMax,d)
                    if d > maximum { maximum = d;worstX = x;worstY = y;worstC = c }
                    if inFlat { flat = max(flat,d) };if edge { edgeMax = max(edgeMax,d) }
                }
                if pixelMax > 3 { over3 += 1 }
            } }
        } }
        let n = Int(rect.width*rect.height)*3,psnr = sum == 0 ? 999.0 : 10*log10(65025/(sum/Double(n)))
        var cumulative = 0,p99 = 0
        for i in 0..<256 { cumulative += hist[i];if cumulative >= n*99/100 { p99 = i;break } }
        let k = (worstY*w+worstX)*4
        return ["psnr":psnr,"maximum":maximum,"flatMaximum":flat,"edgeMaximum":edgeMax,"p99":p99,"pixelsOver3":over3,
            "worstXYC":[worstX,worstY,worstC],"actualAtWorst":Array(actual[k..<k+4]),"referenceAtWorst":Array(expected[k..<k+4]),"qualityPass":psnr>=40 && flat<=3]
    }
    static func fixture(_ url: URL,top: Bool) async throws {
        let writer = try AVAssetWriter(outputURL:url,fileType:.mov)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:w,AVVideoHeightKey:h,
            AVVideoColorPropertiesKey:IBContract.writerTags,AVVideoCompressionPropertiesKey:[AVVideoAllowFrameReorderingKey:false,AVVideoAverageBitRateKey:8_000_000]])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format,
            kCVPixelBufferWidthKey as String:w,kCVPixelBufferHeightKey as String:h])
        guard writer.startWriting() else { throw writer.error ?? IBContract.error("fixture writer") };writer.startSession(atSourceTime:.zero)
        for f in 0..<6 {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil,w,h,IBContract.format,nil,&buffer) == kCVReturnSuccess,let buffer else { throw IBContract.error("fixture allocate") }
            CVPixelBufferLockBaseAddress(buffer,[])
            guard let yp = CVPixelBufferGetBaseAddressOfPlane(buffer,0),let cp = CVPixelBufferGetBaseAddressOfPlane(buffer,1) else { throw IBContract.error("fixture plane") }
            let yy = yp.assumingMemoryBound(to:UInt8.self),uv = cp.assumingMemoryBound(to:UInt8.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(buffer,0),cs = CVPixelBufferGetBytesPerRowOfPlane(buffer,1)
            for y in 0..<h { memset(yy+y*ys,Int32(top ? 130+f*6 : 45+f*8),w) }
            for y in 0..<h/2 { for x in stride(from:0,to:w,by:2) { uv[y*cs+x] = UInt8(top ? 100+f : 150+f*2);uv[y*cs+x+1] = UInt8(top ? 165-f*2 : 110+f) } }
            for bit in 0..<3 { let left = 24+48*bit,value = (f & (1<<bit)) != 0 ? 235 : 16
                for y in 24..<56 { memset(yy+y*ys+left,Int32(value),32) }
                for y in 12..<28 { for x in stride(from:left,to:left+32,by:2) { uv[y*cs+x] = 128;uv[y*cs+x+1] = 128 } }
            }
            CVPixelBufferUnlockBaseAddress(buffer,[]);IBContract.tag(buffer)
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData { guard Date()<deadline,writer.status != .failed else { writer.cancelWriting();throw IBContract.error("fixture writer timeout",code:300) };try await Task.sleep(nanoseconds:1_000_000) }
            guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(f),timescale:30)) else { throw writer.error ?? IBContract.error("fixture append") }
        }
        input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:6,timescale:30));await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? IBContract.error("fixture finish") }
    }
    static func digest(_ urls: [URL]) throws -> String {
        var hash = SHA256();for u in urls { hash.update(data:try Data(contentsOf:u)) };return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
