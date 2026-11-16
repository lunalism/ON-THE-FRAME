import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import OTFDevSupport
@testable import OnTheFrameEngine

/// Opt-in only; all generated data belongs to a unique run, never the app.
final class ImageCacheFeasibilityTests: XCTestCase {
    let w = 960, h = 540
    var root: URL!
    var records: [[String: Any]] = []
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    struct Layer { let url: URL; let image: CGImage; let start: Int; let end: Int; var rect = CGRect(x: 0, y: 0, width: 1920, height: 1080) }
    func record(_ name: String, _ fields: [String: Any]) throws {
        var r = fields; r["name"] = name; r["rssBytes"] = rss(); records.append(r)
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json"), options: .atomic)
        print("IMG1A \(name): \(fields)")
    }
    func rss() -> UInt64 { var i = mach_task_basic_info(); var n = mach_msg_type_number_t(MemoryLayout.size(ofValue: i) / 4); _ = withUnsafeMutablePointer(to: &i) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n) } }; return i.resident_size }
    func context(_ width: Int, _ height: Int, space: CGColorSpace? = nil) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space ?? cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    func fixture(alpha: Bool = false, p3: Bool = false) -> CGImage {
        let c = context(w, h, space: p3 ? CGColorSpace(name: CGColorSpace.displayP3)! : nil)
        if !alpha { c.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)); c.fill(CGRect(x: 0,y: 0,width: w,height: h)) }
        // Independent analytic patches, ramp, fine lines and asymmetric corner markers.
        for (i, rgb) in [[0.8,0.2,0.2],[0.2,0.8,0.2],[0.2,0.2,0.8],[0.5,0.5,0.5]].enumerated() {
            c.setFillColor(CGColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha ? 0.5 : 1)); c.fill(CGRect(x: 80+i*200,y: 150,width: 150,height: 200))
        }
        for x in 0..<w { c.setFillColor(CGColor(gray: CGFloat(x)/CGFloat(w-1),alpha: 1)); c.fill(CGRect(x:x,y:400,width:1,height:70)) }
        for x in stride(from: 0, to: w, by: 4) { c.setFillColor(CGColor(gray: 1,alpha: alpha ? 0.25 : 1)); c.fill(CGRect(x:x,y:50,width:1,height:60)) }
        c.setFillColor(CGColor(red:1,green:1,blue:0,alpha:1)); c.fill(CGRect(x:0,y:0,width:70,height:35))
        c.setFillColor(CGColor(red:0,green:1,blue:1,alpha:1)); c.fill(CGRect(x:w-35,y:h-70,width:35,height:70))
        return c.makeImage()!
    }
    func saveImage(_ image: CGImage, _ name: String, jpeg: Bool = false, orientation: Int = 1) throws -> URL {
        let u = root.appendingPathComponent(name)
        let d = CGImageDestinationCreateWithURL(u as CFURL, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1,nil)!
        CGImageDestinationAddImage(d,image,[kCGImagePropertyOrientation:orientation,kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw NSError(domain:"image-finalize",code:1) }; return u
    }
    func decode(_ u: URL) throws -> CGImage {
        guard let s = CGImageSourceCreateWithURL(u as CFURL,nil), CGImageSourceGetCount(s) == 1,
              let type = CGImageSourceGetType(s), [UTType.jpeg.identifier,UTType.png.identifier].contains(type as String),
              let im = CGImageSourceCreateThumbnailAtIndex(s,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:960] as CFDictionary),
              CGImageSourceGetStatus(s) == .statusComplete else { throw NSError(domain:"image-rejected",code:1) }
        let c = context(im.width,im.height); c.draw(im,in:CGRect(x:0,y:0,width:im.width,height:im.height)); return c.makeImage()!
    }
    func cache(_ image: CGImage, name: String, codec: AVVideoCodecType, frames: Int = 30, cancelAt: Int? = nil) async throws -> URL {
        let u = root.appendingPathComponent(name + ".mov"), partial = root.appendingPathComponent(name + ".partial.mov")
        let start = Date(); let writer = try AVAssetWriter(outputURL: partial,fileType:.mov)
        defer { try? FileManager.default.removeItem(at:partial) }
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:codec,AVVideoWidthKey:image.width,AVVideoHeightKey:image.height,
            AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]])
        guard writer.canAdd(input) else { throw NSError(domain:"cache-input",code:1) }; writer.add(input)
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:image.width,kCVPixelBufferHeightKey as String:image.height,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime:.zero)
        var pb: CVPixelBuffer?; CVPixelBufferCreate(nil,image.width,image.height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pb)
        CVPixelBufferLockBaseAddress(pb!,[])
        let c = CGContext(data:CVPixelBufferGetBaseAddress(pb!),width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pb!),space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height)); CVPixelBufferUnlockBaseAddress(pb!,[])
        for f in 0..<frames {
            if f == cancelAt { writer.cancelWriting(); throw CancellationError() }
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData { if writer.status == .failed { throw writer.error! }; try await Task.sleep(nanoseconds:1_000_000) }
            guard ad.append(pb!,withPresentationTime:CMTime(value:Int64(f),timescale:30)) else { throw writer.error! }
        }
        input.markAsFinished(); writer.endSession(atSourceTime:CMTime(value:Int64(frames),timescale:30)); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }; try FileManager.default.moveItem(at:partial,to:u)
        try record("cache-"+name,["seconds":Date().timeIntervalSince(start),"bytes":try u.resourceValues(forKeys:[.fileSizeKey]).fileSize!,"codec":codec.rawValue,"frames":frames,"width":image.width,"height":image.height]); return u
    }
    func plan(_ layers: [Layer], frames: Int, black: URL, subtitle: Bool = false, audio: URL? = nil) async throws -> PlannedComposition {
        let c = AVMutableComposition(); var assets: [AVURLAsset] = []; var mapped: [(Layer,AVMutableCompositionTrack)] = []
        var segments = 0
        // Explicit experimental alpha-aware stack: never use the production opaque-rectangle culler.
        let bg = Layer(url:black,image:fixture(),start:0,end:frames)
        for l in [bg] + layers.reversed() {
            let a = AVURLAsset(url:l.url); assets.append(a); guard let source = try await a.loadTracks(withMediaType:.video).first else { throw NSError(domain:"cache-no-video",code:1) }
            let range = try await source.load(.timeRange); let count = Int((range.duration.seconds*30).rounded())
            let track = c.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!
            for start in stride(from:l.start,to:l.end,by:count) {
                try track.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(value:Int64(min(count,l.end-start)),timescale:30)),of:source,at:CMTime(value:Int64(start),timescale:30)); segments += 1
            }
            mapped.append((l,track))
        }
        let bounds = Set([0,frames] + layers.flatMap { [$0.start,$0.end] }).sorted()
        var ins: [AVMutableVideoCompositionInstruction] = []
        for (lo,hi) in zip(bounds,bounds.dropFirst()) {
            let i = AVMutableVideoCompositionInstruction(); i.timeRange = CMTimeRange(start:CMTime(value:Int64(lo),timescale:30),duration:CMTime(value:Int64(hi-lo),timescale:30)); i.backgroundColor = CGColor(gray:0,alpha:1)
            i.layerInstructions = mapped.reversed().filter { $0.0.start <= lo && lo < $0.0.end }.map { l,t in
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack:t)
                // Source raster dimensions are independent of output canvas dimensions.
                let a = assets.first { $0.url == l.url }!; _ = a
                let width = l.url == black ? 960 : l.image.width, height = l.url == black ? 540 : l.image.height
                li.setTransform(CGAffineTransform(a:l.rect.width/CGFloat(width),b:0,c:0,d:l.rect.height/CGFloat(height),tx:l.rect.minX,ty:l.rect.minY),at:.zero); return li
            }; ins.append(i)
        }
        if let audio {
            let a = AVURLAsset(url:audio); assets.append(a); let source = try await a.loadTracks(withMediaType:.audio)[0]
            let t = c.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!
            let n = min(Double(frames)/30,try await source.load(.timeRange).duration.seconds)
            try t.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:n,preferredTimescale:48000)),of:source,at:.zero)
        }
        let v = AVMutableVideoComposition(); v.renderSize = CGSize(width:1920,height:1080); v.frameDuration = CMTime(value:1,timescale:30); v.instructions = ins
        var p = PlannedComposition(composition:c,videoComposition:v,durationFrames:frames,settings:RenderSettings(),hasAudio:audio != nil,audioMix:nil,hasVideo:true,assets:assets)
        if subtitle { p.subtitles = [SubtitleItem(lane:UUID(),start:30,length:30,text:"IMG-1A subtitle")] }
        try record("plan",["frames":frames,"insertions":segments,"instructions":ins.count]); return p
    }
    func reference(_ layers: [Layer], frame: Int) -> CGImage {
        let c = context(1920,1080); c.setFillColor(CGColor(gray:0,alpha:1)); c.fill(CGRect(x:0,y:0,width:1920,height:1080)); c.interpolationQuality = .high
        for l in layers.reversed() where l.start <= frame && frame < l.end { c.draw(l.image,in:l.rect) }; return c.makeImage()!
    }
    func bytes(_ im: CGImage) -> [UInt8] { let c = context(im.width,im.height); c.draw(im,in:CGRect(x:0,y:0,width:im.width,height:im.height)); return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:im.width*im.height*4)) }
    func metrics(_ actual: [UInt8], reference: CGImage, bgra: Bool) -> [String:Any] {
        let expected = bytes(reference); var sum = 0.0, maxError = 0; var hist = [Int](repeating:0,count:256); var flatMax = 0; var local: [String:Int] = ["edge":0,"gradient":0,"alpha":0]
        for y in 0..<1080 { for x in 0..<1920 { let k = (y*1920+x)*4
            for ch in 0..<3 { let e = abs(Int(actual[k+(bgra ? 2-ch : ch)])-Int(expected[k+ch])); sum += Double(e*e); maxError = max(maxError,e); hist[e] += 1
                if x > 200 && x < 400 && y > 400 && y < 600 { flatMax = max(flatMax,e) }
                let region = y > 800 && y < 940 ? "gradient" : (x%400 < 12 ? "edge" : "alpha"); local[region] = max(local[region]!,e)
            }
        } }
        let n = 1920*1080*3; var total=0,p99=0; for i in 0..<256 { total += hist[i]; if total >= n*99/100 { p99=i; break } }
        let psnr = sum == 0 ? 999 : 10*log10(255*255/(sum/Double(n)))
        return ["psnr":psnr,"max":maxError,"p99":p99,"flatMax":flatMax,"localMax":local,"screenPass":psnr >= 40 && flatMax <= 3]
    }
    func inspect(_ url: URL, name: String, frames: Int, layers: [Layer], skipQuality: Bool = false) async throws {
        let a=AVURLAsset(url:url), vt=try await a.loadTracks(withMediaType:.video)[0]; let r=try AVAssetReader(asset:a)
        let o=AVAssetReaderTrackOutput(track:vt,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]); o.alwaysCopiesSampleData=false; r.add(o); XCTAssertTrue(r.startReading())
        let probes=Set([0,14,15,29,30,31,59,60,61,89,90,104,105,frames-1].filter { $0 >= 0 && $0 < frames }); var n=0, badPTS=0
        while let sb=o.copyNextSampleBuffer() {
            if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb),CMTime(value:Int64(n),timescale:30)) != 0 { badPTS += 1 }
            if probes.contains(n), !skipQuality { let f=FrameCompare.copy(CMSampleBufferGetImageBuffer(sb)!); try record(name+"-frame-\(n)",metrics(f.bgra,reference:reference(layers,frame:n),bgra:true)) }; n += 1
            if rss() > 1_073_741_824 { r.cancelReading(); throw NSError(domain:"memory-budget",code:1) }
        }
        let range=try await vt.load(.timeRange), formats=try await vt.load(.formatDescriptions)
        try record(name+"-timing",["actualFrames":n,"expectedFrames":frames,"badPTS":badPTS,"duration":range.duration.seconds,"reader":r.status.rawValue,"format":formats.map { String(describing:CMFormatDescriptionGetExtensions($0)) }])
        XCTAssertEqual(n,frames); XCTAssertEqual(badPTS,0); XCTAssertEqual(CMTimeCompare(range.duration,CMTime(value:Int64(frames),timescale:30)),0); XCTAssertEqual(r.status,.completed)
    }
    func export(_ p: PlannedComposition, name: String, layers: [Layer], skipQuality: Bool = false) async throws {
        let u=root.appendingPathComponent(name+".mp4"), start=Date(); let result=await ExportService.export(p,to:.init(url:u,confirmedReplace:false,identityAtConfirmation:nil),sources:[]) { _ in }
        try record(name+"-export",["outcome":String(describing:result),"seconds":Date().timeIntervalSince(start)])
        XCTAssertEqual(result,.completed(u)); if result == .completed(u) { try await inspect(u,name:name,frames:p.durationFrames,layers:layers,skipQuality:skipQuality) }
    }
    func testBoundedExperiment() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG1A_RUN"] else { throw XCTSkip("IMG-1A opt-in only") }
        root=URL(fileURLWithPath:path); guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("results.json").path) else { throw NSError(domain:"fresh-run-required",code:1) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try record("start",["date":ISO8601DateFormatter().string(from:Date()),"thresholds":"flat max<=3; PSNR>=40; exact timing; not production acceptance"])
        var images:[String:CGImage]=[:], urls:[String:URL]=[:]
        for name in ["jpeg","png","alpha","p3","orientation"] {
            let input=fixture(alpha:name == "alpha",p3:name == "p3")
            let u=try saveImage(input,name+((name == "jpeg" || name == "orientation") ? ".jpg" : ".png"),jpeg:name == "jpeg" || name == "orientation",orientation:name == "orientation" ? 6 : 1)
            let start=Date(); let im=try decode(u); images[name]=im
            let source=CGImageSourceCreateWithURL(u as CFURL,nil)!
            try record("fixture-"+name,["width":im.width,"height":im.height,"decodeSeconds":Date().timeIntervalSince(start),"properties":String(describing:CGImageSourceCopyPropertiesAtIndex(source,0,nil)),"normalizedColor":String(describing:im.colorSpace),"alphaInfo":im.alphaInfo.rawValue])
            if name == "orientation" { XCTAssertEqual(im.width,540); XCTAssertEqual(im.height,960) }
            urls[name]=try await cache(im,name:name,codec:.proRes4444)
        }
        let blackContext=context(w,h); blackContext.setFillColor(CGColor(gray:0,alpha:1)); blackContext.fill(CGRect(x:0,y:0,width:w,height:h)); let black=try await cache(blackContext.makeImage()!,name:"black",codec:.h264)
        // Actual ordinary H.264 video track, separate from the image-backed ProRes candidate.
        let bgContext=context(w,h); bgContext.setFillColor(CGColor(red:0.1,green:0.25,blue:0.7,alpha:1)); bgContext.fill(CGRect(x:0,y:0,width:w,height:h)); let bgImage=bgContext.makeImage()!; let video=try await cache(bgImage,name:"ordinary-video",codec:.h264)
        for name in ["jpeg","png","p3","orientation"] {
            var l=Layer(url:urls[name]!,image:images[name]!,start:15,end:105)
            if name == "orientation" { l.rect=CGRect(x:656.25,y:0,width:607.5,height:1080) }
            let p=try await plan([l],frames:120,black:black); try await export(p,name:name+"-only",layers:[l])
        }
        let upper=Layer(url:urls["alpha"]!,image:images["alpha"]!,start:15,end:105), lower=Layer(url:video,image:bgImage,start:0,end:120)
        let alphaPlan=try await plan([upper,lower],frames:120,black:black)
        try await export(alphaPlan,name:"alpha-over-video",layers:[upper,lower])
        let lowerAlpha=try await plan([lower,upper],frames:120,black:black); try await export(lowerAlpha,name:"video-over-alpha",layers:[lower,upper])
        let sequence=[Layer(url:video,image:bgImage,start:0,end:30),Layer(url:urls["png"]!,image:images["png"]!,start:30,end:90)]
        try await export(try await plan(sequence,frames:120,black:black),name:"sequential",layers:sequence)
        let sub=try await plan([upper,lower],frames:120,black:black,subtitle:true)
        try await export(sub,name:"alpha-subtitle",layers:[upper,lower])
        // H.264 negative control: alpha must NOT be reported preserved.
        let incompatible=try await cache(images["alpha"]!,name:"alpha-h264-negative",codec:.h264)
        let wrong=Layer(url:incompatible,image:images["alpha"]!,start:0,end:90), bottom=Layer(url:video,image:bgImage,start:0,end:90)
        try await export(try await plan([wrong,bottom],frames:90,black:black),name:"alpha-negative-control",layers:[wrong,bottom])
        // Offline exact-time preview composition probe (not live AVPlayer proof).
        let g=AVAssetImageGenerator(asset:alphaPlan.composition); g.videoComposition=alphaPlan.videoComposition; g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        for f in [0,14,15,29,30,59,60,104,105,119] { let result=try await g.image(at:CMTime(value:Int64(f),timescale:30)); try record("preview-\(f)",metrics(bytes(result.image),reference:reference([upper,lower],frame:f),bgra:false)); XCTAssertEqual(CMTimeCompare(result.actualTime,CMTime(value:Int64(f),timescale:30)),0) }
        do { _=try await cache(images["alpha"]!,name:"cancel-cache",codec:.proRes4444,cancelAt:3); XCTFail("cancellation missing") } catch is CancellationError { try record("cache-cancel",["partialRemoved":!FileManager.default.fileExists(atPath:root.appendingPathComponent("cancel-cache.partial.mov").path)]) }
        let bad=root.appendingPathComponent("malformed.png"); try Data([0,1,2,3]).write(to:bad); XCTAssertThrowsError(try decode(bad)); XCTAssertThrowsError(try decode(root.appendingPathComponent("missing.png")))
        let sentinel=root.appendingPathComponent("protected.mp4"); let sentinelData=Data("IMG1A-existing-output".utf8); try sentinelData.write(to:sentinel)
        let denied=await ExportService.export(alphaPlan,to:.init(url:sentinel,confirmedReplace:false,identityAtConfirmation:nil),sources:[]) { _ in }; XCTAssertEqual(denied,.failed(.destinationExistsUnconfirmed)); XCTAssertEqual(try Data(contentsOf:sentinel),sentinelData)
        let failed=root.appendingPathComponent("injected.mp4"); let failure=await ExportService.export(sub,to:.init(url:failed,confirmedReplace:false,identityAtConfirmation:nil),sources:[],options:.init(failAfterFraction:0.05)) { _ in }; try record("injected-failure",["result":String(describing:failure),"destinationAbsent":!FileManager.default.fileExists(atPath:failed.path)])
        let long=Layer(url:urls["png"]!,image:images["png"]!,start:0,end:5400)
        try await export(try await plan([long],frames:5400,black:black),name:"repeat-180s",layers:[long],skipQuality:true)
        let start=Date(); _=try await plan([Layer(url:long.url,image:long.image,start:0,end:54000)],frames:54000,black:black); try record("plan-1800s",["seconds":Date().timeIntervalSince(start),"exported":false])
        try record("finish",["date":ISO8601DateFormatter().string(from:Date())])
    }
    func wav(_ url: URL, frames: Int) throws {
        var d=Data(); func text(_ s:String) { d.append(contentsOf:s.utf8) }; func u16(_ n:UInt16) { var x=n.littleEndian; withUnsafeBytes(of:&x) { d.append(contentsOf:$0) } }; func u32(_ n:UInt32) { var x=n.littleEndian; withUnsafeBytes(of:&x) { d.append(contentsOf:$0) } }
        let samples=frames*1600; text("RIFF"); u32(UInt32(36+samples*2)); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16); text("data"); u32(UInt32(samples*2))
        for n in 0..<samples { let x=Int16(sin(Double(n)*2*Double.pi*440/48000)*6000); u16(UInt16(bitPattern:x)) }; try d.write(to:url)
    }
    func testSupplement() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG1A_SUPPLEMENT"],let source=ProcessInfo.processInfo.environment["OTF_IMG1A_SOURCE"] else { throw XCTSkip("IMG-1A supplement opt-in") }
        root=URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("results.json").path) else { throw NSError(domain:"fresh-run",code:1) }
        let src=URL(fileURLWithPath:source), black=src.appendingPathComponent("black.mov"), alpha=try decode(src.appendingPathComponent("alpha.png")), png=try decode(src.appendingPathComponent("png.png"))
        // Independent EXIF-6 reference: explicit CoreGraphics clockwise rotation.
        let orientationSource=CGImageSourceCreateWithURL(src.appendingPathComponent("orientation.jpg") as CFURL,nil)!
        let raw=CGImageSourceCreateImageAtIndex(orientationSource,0,nil)!,oriented=try decode(src.appendingPathComponent("orientation.jpg"))
        let rotation=context(raw.height,raw.width); rotation.translateBy(x:0,y:CGFloat(raw.width)); rotation.rotate(by:-CGFloat.pi/2); rotation.draw(raw,in:CGRect(x:0,y:0,width:raw.width,height:raw.height))
        let independent=bytes(rotation.makeImage()!),actualOrientation=bytes(oriented); let orientationMax=zip(independent,actualOrientation).map { abs(Int($0)-Int($1)) }.max()!
        try record("orientation-independent",["maxByteDifference":orientationMax,"reference":"explicit clockwise CG rotation; raw JPEG decoded without orientation"]); XCTAssertLessThanOrEqual(orientationMax,1)
        // Decode actual cache alpha, separately from composition and export.
        for name in ["alpha","alpha-h264-negative"] {
            let a=AVURLAsset(url:src.appendingPathComponent(name+".mov")),vt=try await a.loadTracks(withMediaType:.video)[0],r=try AVAssetReader(asset:a)
            let o=AVAssetReaderTrackOutput(track:vt,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]); r.add(o); XCTAssertTrue(r.startReading()); let sb=try XCTUnwrap(o.copyNextSampleBuffer()),f=FrameCompare.copy(CMSampleBufferGetImageBuffer(sb)!)
            let values=stride(from:3,to:f.bgra.count,by:4).map { f.bgra[$0] }; let expected=bytes(alpha)
            var maxA=0; for i in values.indices { maxA=max(maxA,abs(Int(values[i])-Int(expected[i*4+3]))) }
            try record("decoded-alpha-"+name,["min":values.min()!,"max":values.max()!,"maxAlphaError":maxA,"partialCount":values.filter { $0 > 0 && $0 < 255 }.count]); r.cancelReading()
            if name == "alpha" { XCTAssertLessThanOrEqual(maxA,1) } else { XCTAssertEqual(values.min(),255) }
        }
        let sampleAsset=AVURLAsset(url:src.appendingPathComponent("alpha-over-video.mp4")); let sampleGenerator=AVAssetImageGenerator(asset:sampleAsset); sampleGenerator.requestedTimeToleranceBefore = .zero; sampleGenerator.requestedTimeToleranceAfter = .zero
        let sample=try await sampleGenerator.image(at:CMTime(value:30,timescale:30)); _=try saveImage(sample.image,"alpha-export-frame30.png")
        let blueContext=context(w,h); blueContext.setFillColor(CGColor(red:0.1,green:0.25,blue:0.7,alpha:1)); blueContext.fill(CGRect(x:0,y:0,width:w,height:h)); let blue=blueContext.makeImage()!
        let ref=reference([Layer(url:src.appendingPathComponent("alpha.mov"),image:alpha,start:0,end:90),Layer(url:src.appendingPathComponent("ordinary-video.mov"),image:blue,start:0,end:90)],frame:30); _=try saveImage(ref,"alpha-reference-frame30.png")
        let repeatProbes:Set<Int>=[44,45,46,74,75,76]
        let repeatPixels=try await FrameCompare.decode(src.appendingPathComponent("alpha-over-video.mp4"),frames:repeatProbes)
        for f in repeatProbes.sorted() { let actual=try XCTUnwrap(repeatPixels[f]); try record("actual-repeat-boundary-\(f)",metrics(actual.bgra,reference:ref,bgra:true)) }
        // Existing production visibility culler, tested without changing it.
        func media(_ name:String) async throws -> MediaAsset {
            let u=src.appendingPathComponent(name+".mov"),a=AVURLAsset(url:u),vt=try await a.loadTracks(withMediaType:.video)[0],size=try await vt.load(.naturalSize)
            return MediaAsset(id:UUID(),url:u,name:name,frameCount:30,timing:SourceTiming(sampleCount:30,isVariable:false,frameDurationValue:1,frameDurationTimescale:30,averageFPS:30,minInterval:1/30,maxInterval:1/30),naturalSize:size,displaySize:size,preferredTransform:.identity,hasAudio:false,codec:"experimental",identity:FileIdentity.of(u)!)
        }
        let upper=try await media("alpha"),bottom=try await media("ordinary-video"),topLane=Lane(id:UUID(),kind:.video,name:"V2"),bottomLane=Lane(id:UUID(),kind:.video,name:"V1")
        let t=Timeline(clips:[Clip(mediaID:upper.id,start:0,sourceIn:0,length:30,lane:topLane.id),Clip(mediaID:bottom.id,start:0,sourceIn:0,length:30,lane:bottomLane.id)],lanes:[topLane,bottomLane],media:[MediaRef(upper),MediaRef(bottom)],mediaFrames:[upper.id:30,bottom.id:30])
        let stack=try CompositionPlanner.layerStack(t,from:0,to:30,media:[upper.id:upper,bottom.id:bottom],render:CGSize(width:1920,height:1080))
        try record("production-culler",["inputLayers":2,"keptLayers":stack.count,"alphaLowerLayerPreserved":stack.contains { $0.mediaID == bottom.id }])
        // Same outputs: subtitle presence inside [30,60), absent outside. Outside
        // subtitle footprint compare separately; this is path consistency, not reference quality.
        let probes:Set<Int>=[29,30,59,60]
        let normal=try await FrameCompare.decode(src.appendingPathComponent("alpha-over-video.mp4"),frames:probes),sub=try await FrameCompare.decode(src.appendingPathComponent("alpha-subtitle.mp4"),frames:probes)
        for f in probes.sorted() {
            let a=try XCTUnwrap(normal[f]),b=try XCTUnwrap(sub[f]); var roi=0,outsideMax=0
            for y in 0..<1080 { for x in 0..<1920 { let k=(y*1920+x)*4; let delta=(0..<3).map { abs(Int(a.bgra[k+$0])-Int(b.bgra[k+$0])) }.max()!
                if x > 300 && x < 1620 && y > 700 { if delta > 30 { roi += 1 } } else { outsideMax=max(outsideMax,delta) }
            } }
            try record("subtitle-diff-\(f)",["roiPixelsOver30":roi,"outsideMax":outsideMax,"subtitleExpected":f>=30 && f<60])
        }
        let audio=root.appendingPathComponent("tone.wav"); try wav(audio,frames:180)
        let imageLayer=Layer(url:src.appendingPathComponent("png.mov"),image:png,start:0,end:90)
        let p=try await plan([imageLayer],frames:180,black:black,audio:audio)
        try await export(p,name:"image-shorter-than-audio",layers:[imageLayer])
        let shortAudio=root.appendingPathComponent("short-tone.wav"); try wav(shortAudio,frames:90)
        let q=try await plan([Layer(url:imageLayer.url,image:png,start:0,end:180)],frames:180,black:black,subtitle:true,audio:shortAudio)
        try await export(q,name:"image-audio-subtitle",layers:[Layer(url:imageLayer.url,image:png,start:0,end:180)])
        for name in ["image-shorter-than-audio","image-audio-subtitle"] { let a=AVURLAsset(url:root.appendingPathComponent(name+".mp4")); let at=try await a.loadTracks(withMediaType:.audio); try record("audio-"+name,["tracks":at.count,"duration":try await at.first?.load(.timeRange).duration.seconds ?? 0]); XCTAssertEqual(at.count,1) }
        // Controlled export cancellation and both injected-failure branches.
        for subtitled in [false,true] {
            var plan=p; if subtitled { plan.subtitles=[SubtitleItem(lane:UUID(),start:30,length:30,text:"cancel")] }
            let dest=root.appendingPathComponent("cancel-\(subtitled).mp4")
            let task=Task { await ExportService.export(plan,to:.init(url:dest,confirmedReplace:false,identityAtConfirmation:nil),sources:[]) { _ in } }; task.cancel(); let outcome=await task.value
            try record("cancel-export-\(subtitled)",["outcome":String(describing:outcome),"destinationAbsent":!FileManager.default.fileExists(atPath:dest.path)]); XCTAssertEqual(outcome,.cancelled)
            let failed=root.appendingPathComponent("failure-\(subtitled).mp4"),r=await ExportService.export(plan,to:.init(url:failed,confirmedReplace:false,identityAtConfirmation:nil),sources:[],options:.init(failAfterFraction:0.05)) { _ in }
            try record("failure-export-\(subtitled)",["outcome":String(describing:r),"destinationAbsent":!FileManager.default.fileExists(atPath:failed.path)])
        }
        let truncated=root.appendingPathComponent("truncated.mov"); try Data((try Data(contentsOf:src.appendingPathComponent("alpha.mov"))).prefix(128)).write(to:truncated)
        let bad=AVURLAsset(url:truncated); do { let tracks=try await bad.loadTracks(withMediaType:.video); try record("corrupt-cache",["tracks":tracks.count]) } catch { try record("corrupt-cache",["rejected":String(describing:error)]) }
        for candidate in [truncated,root.appendingPathComponent("missing-cache.mov")] {
            do { _=try await plan([Layer(url:candidate,image:alpha,start:0,end:30)],frames:30,black:black); XCTFail("bad cache accepted") } catch { try record("bad-cache-reuse-"+candidate.lastPathComponent,["rejected":String(describing:error)]) }
        }
        let regenerated=try await cache(alpha,name:"regenerated-after-cancel",codec:.proRes4444); try record("regeneration",["exists":FileManager.default.fileExists(atPath:regenerated.path)])
        try record("finish",[:])
    }

    func testGeometryAndColor() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG1A_GEOMETRY"],let source=ProcessInfo.processInfo.environment["OTF_IMG1A_SOURCE"] else { throw XCTSkip("IMG-1A geometry opt-in") }
        root=URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("results.json").path) else { throw NSError(domain:"fresh-run",code:1) }
        let src=URL(fileURLWithPath:source),png=try decode(src.appendingPathComponent("png.png")),jpeg=try decode(src.appendingPathComponent("jpeg.jpg")),p3=try decode(src.appendingPathComponent("p3.png")),black=src.appendingPathComponent("black.mov")
        let expected=reference([Layer(url:black,image:fixture(),start:0,end:1)],frame:0),jpegReference=reference([Layer(url:black,image:jpeg,start:0,end:1)],frame:0)
        try record("JPEG-input-loss",metrics(bytes(jpegReference),reference:expected,bgra:false))
        // Independent published Display P3 -> XYZ D65 -> sRGB matrix reference.
        func linear(_ v:Double)->Double { v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
        func encode(_ v:Double)->Int { let c=max(0,min(1,v)); return Int(((c<=0.0031308 ? 12.92*c : 1.055*pow(c,1/2.4)-0.055)*255).rounded()) }
        let m1=[[0.4865709486,0.2656676932,0.1982172852],[0.2289745641,0.6917385218,0.0792869141],[0.0,0.0451133819,1.0439443689]],m2=[[3.24096994,-1.53738318,-0.49861076],[-0.96924364,1.87596750,0.04155506],[0.05563008,-0.20397696,1.05697151]]
        let pixels=bytes(p3)
        let encodedSource=CGImageSourceCreateWithURL(src.appendingPathComponent("p3.png") as CFURL,nil)!,encodedImage=CGImageSourceCreateImageAtIndex(encodedSource,0,nil)!
        let encodedContext=context(w,h,space:CGColorSpace(name:CGColorSpace.displayP3)!); encodedContext.draw(encodedImage,in:CGRect(x:0,y:0,width:w,height:h))
        let encoded=Array(UnsafeBufferPointer(start:encodedContext.data!.assumingMemoryBound(to:UInt8.self),count:w*h*4))
        for (index,nominalValues) in [[0.8,0.2,0.2],[0.2,0.8,0.2],[0.2,0.2,0.8],[0.5,0.5,0.5]].enumerated() {
            let offset=(250*w+100+index*200)*4,values=(0..<3).map { Double(encoded[offset+$0])/255 }
            let lin=values.map(linear),xyz=m1.map { row in zip(row,lin).reduce(0.0) { $0+$1.0*$1.1 } },rgb=m2.map { row in encode(zip(row,xyz).reduce(0.0) { $0+$1.0*$1.1 }) }
            let actual=(0..<3).map { Int(pixels[offset+$0]) },error=zip(rgb,actual).map { abs($0-$1) }.max()!
            try record("P3-matrix-patch-\(index)",["nominalDrawingColor":nominalValues,"storedP3Components":values,"expected":rgb,"actual":actual,"max":error]); XCTAssertLessThanOrEqual(error,2)
        }
        let crop=Layer(url:src.appendingPathComponent("png.mov"),image:png,start:0,end:90,rect:CGRect(x:-240,y:-135,width:2400,height:1350))
        try await export(try await plan([crop],frames:90,black:black),name:"crop",layers:[crop])
        // Input type negative: a valid TIFF is not silently accepted as PNG.
        let tiff=root.appendingPathComponent("unsupported.tiff"),dest=CGImageDestinationCreateWithURL(tiff as CFURL,UTType.tiff.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dest,png,nil); XCTAssertTrue(CGImageDestinationFinalize(dest)); XCTAssertThrowsError(try decode(tiff)); try record("unsupported-type",["TIFFRejected":true,"unsupportedICCProfileTested":false])
        try record("finish",[:])
    }

    func testColorManagedComparison() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG1A_MANAGED"],let source=ProcessInfo.processInfo.environment["OTF_IMG1A_SOURCE"] else { throw XCTSkip("IMG-1A common color space comparison opt-in") }
        root=URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("results.json").path) else { throw NSError(domain:"fresh-run",code:1) }
        let src=URL(fileURLWithPath:source),black=src.appendingPathComponent("black.mov")
        let blueContext=context(w,h); blueContext.setFillColor(CGColor(red:0.1,green:0.25,blue:0.7,alpha:1)); blueContext.fill(CGRect(x:0,y:0,width:w,height:h)); let blue=blueContext.makeImage()!
        for name in ["jpeg","png","p3","alpha"] {
            let image=try decode(src.appendingPathComponent(name == "jpeg" ? "jpeg.jpg" : name+".png"))
            let first=Layer(url:src.appendingPathComponent(name+".mov"),image:image,start:15,end:105)
            let layers=name == "alpha" ? [first,Layer(url:src.appendingPathComponent("ordinary-video.mov"),image:blue,start:0,end:120)] : [first]
            let p=try await plan(layers,frames:120,black:black)
            let preview=AVAssetImageGenerator(asset:p.composition); preview.videoComposition=p.videoComposition
            let output=AVAssetImageGenerator(asset:AVURLAsset(url:src.appendingPathComponent(name == "alpha" ? "alpha-over-video.mp4" : name+"-only.mp4")))
            preview.requestedTimeToleranceBefore = .zero; preview.requestedTimeToleranceAfter = .zero; output.requestedTimeToleranceBefore = .zero; output.requestedTimeToleranceAfter = .zero
            for frame in name == "alpha" ? [14,30,105] : [30] {
                let time=CMTime(value:Int64(frame),timescale:30),a=try await preview.image(at:time),b=try await output.image(at:time)
                XCTAssertEqual(CMTimeCompare(a.actualTime,time),0); XCTAssertEqual(CMTimeCompare(b.actualTime,time),0)
                try record("managed-preview-\(name)-\(frame)",metrics(bytes(a.image),reference:reference(layers,frame:frame),bgra:false))
                try record("managed-export-\(name)-\(frame)",metrics(bytes(b.image),reference:reference(layers,frame:frame),bgra:false))
                try record("managed-pair-\(name)-\(frame)",metrics(bytes(a.image),reference:b.image,bgra:false))
            }
        }
        try record("finish",[:])
    }

    func testLocalizedErrors() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG1A_LOCAL"],let source=ProcessInfo.processInfo.environment["OTF_IMG1A_SOURCE"] else { throw XCTSkip("IMG-1A local measurements opt-in") }
        root=URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("results.json").path) else { throw NSError(domain:"fresh-run",code:1) }
        let src=URL(fileURLWithPath:source),im=try decode(src.appendingPathComponent("alpha.png"))
        let c=context(w,h); c.setFillColor(CGColor(red:0.1,green:0.25,blue:0.7,alpha:1)); c.fill(CGRect(x:0,y:0,width:w,height:h))
        let ref=reference([Layer(url:src,image:im,start:0,end:90),Layer(url:src,image:c.makeImage()!,start:0,end:90)],frame:30)
        let gen=AVAssetImageGenerator(asset:AVURLAsset(url:src.appendingPathComponent("alpha-over-video.mp4"))); gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let output=try await gen.image(at:CMTime(value:30,timescale:30)),actual=bytes(output.image),expected=bytes(ref)
        for (name,x0,x1,y0,y1) in [("transparent-background",300,1600,310,340),("alpha-flat",200,400,450,700),("alpha-edge",158,165,400,700),("gradient",200,1700,160,260),("fine-lines",200,1700,870,970)] {
            var hist=[Int](repeating:0,count:256),maxError=0,sum=0.0,count=0
            for y in y0..<y1 { for x in x0..<x1 { for channel in 0..<3 { let i=(y*1920+x)*4+channel,e=abs(Int(actual[i])-Int(expected[i])); maxError=max(maxError,e); sum += Double(e*e); hist[e] += 1; count += 1 } } }
            var cumulative=0,p99=0; for e in 0..<256 { cumulative += hist[e]; if cumulative >= count*99/100 { p99=e; break } }
            try record("ROI-"+name,["rectTopLeftPixels":[x0,y0,x1-x0,y1-y0],"channels":count,"max":maxError,"p99":p99,"rmse":sqrt(sum/Double(count))])
        }
        let f=try await FrameCompare.decode(src.appendingPathComponent("orientation-only.mp4"),frames:[30])[30]!
        let visible=(0..<1920).filter { x in (0..<3).map { Int(f.bgra[(540*1920+x)*4+$0]) }.max()! > 25 }
        try record("portrait-fit-midrow",["first":visible.first!,"last":visible.last!,"expectedFirst":656,"expectedLast":1263]); XCTAssertEqual(visible.first,656); XCTAssertEqual(visible.last,1263)
        try record("finish",[:])
    }

}
