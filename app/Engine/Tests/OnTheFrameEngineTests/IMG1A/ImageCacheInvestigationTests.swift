import XCTest
import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import CryptoKit
import OTFDevSupport
@testable import OnTheFrameEngine

/// IMG-1A-2: opt-in diagnostics only; original IMG-1A sources/evidence stay intact.
final class ImageCacheInvestigationTests: XCTestCase {
    var h: ImageCacheFeasibilityTests!
    var root: URL!
    var source: URL!
    override func setUp() async throws {
        guard let run = ProcessInfo.processInfo.environment["OTF_IMG1A2_RUN"] else { throw XCTSkip("IMG-1A-2 opt-in") }
        source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OTF_IMG1A2_SOURCE"]!)
        let suffix = name.components(separatedBy: " ").last!.replacingOccurrences(of: "]", with: "")
        root = URL(fileURLWithPath: run).appendingPathComponent(suffix)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw NSError(domain:"fresh-investigation-root",code:1) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        h = ImageCacheFeasibilityTests(); h.root = root
    }
    var controlRoot: URL {
        if let path = ProcessInfo.processInfo.environment["OTF_IMG1A2_CONTROL_RUN"] { return URL(fileURLWithPath:path) }
        return root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("img1a2-20261027-01")
    }
    func note(_ name:String,_ data:[String:Any]) throws { try h.record(name,data) }
    func space(_ im:CGImage)->[String:Any] {
        let profile = im.colorSpace?.copyICCData() as Data?
        return ["width":im.width,"height":im.height,"bpc":im.bitsPerComponent,"bpp":im.bitsPerPixel,"alpha":im.alphaInfo.rawValue,"space":String(describing:im.colorSpace),"iccBytes":profile?.count ?? 0,"iccSHA256":profile.map { SHA256.hash(data:$0).map { String(format:"%02x",$0) }.joined() } ?? "none"]
    }
    func pbInfo(_ pb:CVPixelBuffer)->[String:Any] {
        ["width":CVPixelBufferGetWidth(pb),"height":CVPixelBufferGetHeight(pb),"pixelFormat":CVPixelBufferGetPixelFormatType(pb),"planar":CVPixelBufferIsPlanar(pb),"attachments":String(describing:CVBufferCopyAttachments(pb,.shouldPropagate)),"nonpropagating":String(describing:CVBufferCopyAttachments(pb,.shouldNotPropagate))]
    }
    func rgb(_ pb:CVPixelBuffer)->[UInt8] {
        let f=FrameCompare.copy(pb); var a=f.bgra
        for k in stride(from:0,to:a.count,by:4) { a.swapAt(k,k+2) }; return a
    }
    /// All arrays RGBA8 in explicitly declared spaces. Same-space is established by caller.
    func compare(_ a:[UInt8],_ b:[UInt8],width:Int,height:Int)->[String:Any] {
        precondition(a.count==b.count && a.count==width*height*4)
        var sum=0.0,maximum=0,hist=[Int](repeating:0,count:256),flat=0
        for y in 0..<height { for x in 0..<width { let k=(y*width+x)*4
            for c in 0..<3 { let e=abs(Int(a[k+c])-Int(b[k+c])); maximum=max(maximum,e); sum += Double(e*e); hist[e] += 1
                if x > width/10 && x < width/5 && y > height*4/10 && y < height*5/10 { flat=max(flat,e) }
            }
        } }
        let count=width*height*3; var cumulative=0,p99=0
        for e in 0..<256 { cumulative += hist[e]; if cumulative >= count*99/100 { p99=e; break } }
        let psnr=sum==0 ? 999 : 10*log10(65025/(sum/Double(count)))
        return ["psnr":psnr,"max":maximum,"p99":p99,"flatMax":flat,"screenPass":psnr>=40 && flat<=3]
    }
    func roi(_ actual:[UInt8],_ expected:[UInt8],width:Int,rect:CGRect)->[String:Any] {
        var hist=[Int](repeating:0,count:256),sum=0.0,n=0,maximum=0
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) { for c in 0..<3 { let k=(y*width+x)*4+c,e=abs(Int(actual[k])-Int(expected[k])); maximum=max(maximum,e);sum += Double(e*e);hist[e] += 1;n += 1 } } }
        var cumulative=0,p99=0; for e in 0..<256 { cumulative += hist[e];if cumulative>=n*99/100 { p99=e;break } }
        return ["rect":[rect.minX,rect.minY,rect.width,rect.height],"max":maximum,"p99":p99,"rmse":sqrt(sum/Double(n))]
    }
    func managed(_ u:URL,frame:Int=0,plan:PlannedComposition?=nil) async throws -> CGImage {
        let g=AVAssetImageGenerator(asset:plan?.composition ?? AVURLAsset(url:u)); g.videoComposition=plan?.videoComposition
        g.requestedTimeToleranceBefore = .zero;g.requestedTimeToleranceAfter = .zero
        let r=try await g.image(at:CMTime(value:Int64(frame),timescale:30)); XCTAssertEqual(CMTimeCompare(r.actualTime,CMTime(value:Int64(frame),timescale:30)),0); return r.image
    }
    func sample(_ u:URL,plan:PlannedComposition?=nil,frame:Int=0) async throws -> CVPixelBuffer {
        let asset:AVAsset=plan?.composition ?? AVURLAsset(url:u),reader=try AVAssetReader(asset:asset),tracks=try await asset.loadTracks(withMediaType:.video)
        let output:AVAssetReaderOutput
        if let plan { let o=AVAssetReaderVideoCompositionOutput(videoTracks:tracks,videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);o.videoComposition=plan.videoComposition;output=o }
        else { output=AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]) }
        reader.add(output);reader.timeRange=CMTimeRange(start:CMTime(value:Int64(frame),timescale:30),duration:CMTime(value:1,timescale:30)); guard reader.startReading(),let s=output.copyNextSampleBuffer(),let pb=CMSampleBufferGetImageBuffer(s) else { throw reader.error ?? NSError(domain:"reader",code:1) };reader.cancelReading();return pb
    }
    func buffer(_ im:CGImage,mode:String)->CVPixelBuffer {
        var p:CVPixelBuffer?;CVPixelBufferCreate(nil,im.width,im.height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&p);let pb=p!
        CVPixelBufferLockBaseAddress(pb,[])
        let c=CGContext(data:CVPixelBufferGetBaseAddress(pb),width:im.width,height:im.height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pb),space:h.cs,bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
        c.draw(im,in:CGRect(x:0,y:0,width:im.width,height:im.height))
        if mode=="explicit709" {
            let base=CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<im.height { for x in 0..<im.width { let k=y*stride+x*4,alpha=Double(base[k+3])/255
                if alpha>0 { for channel in 0..<3 { let v=min(1,Double(base[k+channel])/255/alpha),linear=v<=0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4),encoded=linear<0.018 ? 4.5*linear : 1.099*pow(linear,0.45)-0.099; base[k+channel]=UInt8(max(0,min(255,(encoded*alpha*255).rounded()))) } }
            } }
        }
        CVPixelBufferUnlockBaseAddress(pb,[])
        if mode != "legacy709" {
            CVBufferSetAttachment(pb,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
            CVBufferSetAttachment(pb,kCVImageBufferTransferFunctionKey,mode=="srgbTag" ? kCVImageBufferTransferFunction_sRGB : kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
            CVBufferSetAttachment(pb,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
            CVBufferSetAttachment(pb,kCVImageBufferCGColorSpaceKey,mode=="srgbTag" ? h.cs : CGColorSpace(name:CGColorSpace.itur_709)!, .shouldPropagate)
        }
        return pb
    }
    func encode(_ im:CGImage,name:String,mode:String) async throws -> URL {
        let u=root.appendingPathComponent(name+".mov"),writer=try AVAssetWriter(outputURL:u,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.proRes4444,AVVideoWidthKey:im.width,AVVideoHeightKey:im.height,AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:mode=="srgbTag" ? AVVideoTransferFunction_IEC_sRGB : AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]])
        writer.add(input);let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        guard writer.startWriting() else { throw writer.error! };writer.startSession(atSourceTime:.zero);let pb=buffer(im,mode:mode)
        try note(name+"-writer-input",pbInfo(pb))
        for f in 0..<30 { var waits=0;while !input.isReadyForMoreMediaData { if writer.status == .failed { throw writer.error! };try await Task.sleep(nanoseconds:1_000_000);waits += 1;if waits>5000 { writer.cancelWriting();throw NSError(domain:"writer-timeout",code:1) } };guard adaptor.append(pb,withPresentationTime:CMTime(value:Int64(f),timescale:30)) else { throw writer.error! } }
        input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:30,timescale:30));await writer.finishWriting();guard writer.status == .completed else { throw writer.error! };return u
    }
    func tags(_ u:URL) async throws -> [String:Any] {
        let t=try await AVURLAsset(url:u).loadTracks(withMediaType:.video)[0],descriptions=try await t.load(.formatDescriptions)
        return ["dimensions":String(describing:try await t.load(.naturalSize)),"transform":String(describing:try await t.load(.preferredTransform)),"formats":descriptions.map { String(describing:CMFormatDescriptionGetExtensions($0)) }]
    }
    func testColorStages() async throws {
        let image=try h.decode(source.appendingPathComponent("png.png")),expected=h.bytes(image)
        try note("ImageIO-normalized",space(image));let direct=buffer(image,mode:"legacy709")
        try note("A-no-codec-buffer",pbInfo(direct));try note("A-no-codec-error",compare(rgb(direct),expected,width:image.width,height:image.height))
        let rawSource=CGImageSourceCreateWithURL(source.appendingPathComponent("png.png") as CFURL,nil)!
        try note("source-image-properties",["properties":String(describing:CGImageSourceCopyPropertiesAtIndex(rawSource,0,nil))])
        for mode in ["legacy709","srgbTag","explicit709"] {
            let u:URL
            if mode=="legacy709" { u=source.appendingPathComponent("png.mov") } else { u=try await encode(image,name:mode,mode:mode) }
            try note(mode+"-encoded-tags",try await tags(u));let decoded=try await sample(u)
            try note(mode+"-decoded-buffer",pbInfo(decoded));try note(mode+"-raw-code-values",compare(rgb(decoded),mode=="explicit709" ? rgb(buffer(image,mode:mode)) : expected,width:image.width,height:image.height))
            let display=try await managed(u);try note(mode+"-cache-CGImage",space(display));try note(mode+"-B-cache-managed",compare(h.bytes(display),expected,width:image.width,height:image.height))
            let layer=ImageCacheFeasibilityTests.Layer(url:u,image:image,start:0,end:60),p=try await h.plan([layer],frames:60,black:source.appendingPathComponent("black.mov"))
            let ref=h.reference([layer],frame:30),composition=try await managed(u,frame:30,plan:p)
            try note(mode+"-C-composition-CGImage",space(composition));try note(mode+"-C-composition-managed",compare(h.bytes(composition),h.bytes(ref),width:1920,height:1080));try note(mode+"-composition-buffer",pbInfo(try await sample(u,plan:p,frame:30)))
            let destination=root.appendingPathComponent(mode+".mp4"),outcome=await ExportService.export(p,to:.init(url:destination,confirmedReplace:false,identityAtConfirmation:nil),sources:[]) { _ in }
            try note(mode+"-export",["outcome":String(describing:outcome)]);XCTAssertEqual(outcome,.completed(destination))
            let output=try await managed(destination,frame:30);try note(mode+"-D-export-CGImage",space(output));try note(mode+"-D-export-managed",compare(h.bytes(output),h.bytes(ref),width:1920,height:1080));try note(mode+"-export-tags",try await tags(destination))
            let a=h.bytes(output),b=h.bytes(ref)
            for (name,rect) in [("neutral",CGRect(x:1420,y:450,width:160,height:200)),("saturated",CGRect(x:200,y:450,width:160,height:200)),("gradient",CGRect(x:200,y:160,width:1400,height:100)),("edge",CGRect(x:158,y:400,width:10,height:300))] { try note(mode+"-ROI-"+name,roi(a,b,width:1920,rect:rect)) }
        }
    }
    func testPortraitGeometry() async throws {
        let image=try h.decode(source.appendingPathComponent("orientation.jpg"))
        let transform=CompositionPlanner.fitTransform(natural:CGSize(width:540,height:960),preferred:.identity,render:CGSize(width:1920,height:1080))
        try note("exact-geometry",["scaleNumerator":9,"scaleDenominator":8,"leftNumerator":2625,"rightNumerator":5055,"edgeDenominator":4,"width":607.5,"transform":String(describing:transform),"pixelCentersInside":[656,1263],"priorThreshold":25])
        try note("portrait-cache",try await tags(source.appendingPathComponent("orientation.mov")))
        // Opaque uniform control removes JPEG content, alpha and chroma-pattern ambiguity.
        let c=h.context(540,960);c.setFillColorSpace(h.cs);c.setFillColor([0.8,0.8,0.8,1]);c.fill(CGRect(x:0,y:0,width:540,height:960));let plate=c.makeImage()!
        let cache=try await encode(plate,name:"portrait-opaque",mode:"srgbTag")
        for (name,u,im) in [("original",source.appendingPathComponent("orientation.mov"),image),("uniform",cache,plate)] {
            let layer=ImageCacheFeasibilityTests.Layer(url:u,image:im,start:0,end:60,rect:CGRect(x:656.25,y:0,width:607.5,height:1080)),p=try await h.plan([layer],frames:60,black:source.appendingPathComponent("black.mov"))
            let reference=h.bytes(h.reference([layer],frame:30))
            let pb=try await sample(u,plan:p,frame:30),a=rgb(pb)
            let generator=h.bytes(try await managed(u,frame:30,plan:p))
            let prior=try await sample(source.appendingPathComponent("orientation-only.mp4"),frame:30),previous=rgb(prior)
            for (stage,pixels) in [("reference-CG",reference),("native-composition",a),("generator-composition",generator),("historical-original-JPEG-export",previous)] {
                var row: [[Int]] = []
                var occupied: [Int] = []
                for x in 0..<1920 {
                    let offset = (540 * 1920 + x) * 4
                    let red = Int(pixels[offset]), green = Int(pixels[offset+1]), blue = Int(pixels[offset+2])
                    if max(red, green, blue) > 25 { occupied.append(x) }
                    if (650...659).contains(x) || (1259...1268).contains(x) { row.append([x,red,green,blue]) }
                }
                let fields: [String:Any] = ["firstAt25":occupied.first ?? -1,"lastAt25":occupied.last ?? -1,"edgePixels":row]
                try note(name+"-"+stage,fields)
            }
            // No product rule change: compare native output to integerized native placement.
            let integerLayer=ImageCacheFeasibilityTests.Layer(url:u,image:im,start:0,end:60,rect:CGRect(x:656,y:0,width:607,height:1080)),integerPlan=try await h.plan([integerLayer],frames:60,black:source.appendingPathComponent("black.mov"))
            let integer=rgb(try await sample(u,plan:integerPlan,frame:30));try note(name+"-fractional-vs-integer-native",compare(a,integer,width:1920,height:1080))
        }
    }
    /// Conservative prototype: coverage can stop traversal only with proven opacity.
    func visible(_ layers:[ImageCacheFeasibilityTests.Layer])->[ImageCacheFeasibilityTests.Layer] {
        var result:[ImageCacheFeasibilityTests.Layer]=[]
        for layer in layers {
            result.append(layer)
            let bytes=h.bytes(layer.image),opaque=stride(from:3,to:bytes.count,by:4).allSatisfy { bytes[$0]==255 }
            if opaque && layer.rect.contains(CGRect(x:0,y:0,width:1920,height:1080)) { break }
        }
        return result
    }
    func testAlphaVisibility() async throws {
        let ctx=h.context(960,540);ctx.clear(CGRect(x:0,y:0,width:960,height:540));let transparent=ctx.makeImage()!
        let transparentURL=try await encode(transparent,name:"fully-transparent",mode:"srgbTag")
        let alpha=try h.decode(source.appendingPathComponent("alpha.png")),opaque=try h.decode(source.appendingPathComponent("png.png"))
        let blue=h.context(960,540);blue.setFillColor(CGColor(red:0.1,green:0.25,blue:0.7,alpha:1));blue.fill(CGRect(x:0,y:0,width:960,height:540))
        let lower=ImageCacheFeasibilityTests.Layer(url:source.appendingPathComponent("ordinary-video.mov"),image:blue.makeImage()!,start:0,end:60)
        let empty=ImageCacheFeasibilityTests.Layer(url:transparentURL,image:transparent,start:0,end:60),partial=ImageCacheFeasibilityTests.Layer(url:source.appendingPathComponent("alpha.mov"),image:alpha,start:0,end:60),full=ImageCacheFeasibilityTests.Layer(url:source.appendingPathComponent("png.mov"),image:opaque,start:0,end:60)
        for (name,layers,expectedCount) in [("transparent-over-video",[empty,lower],2),("partial-over-video",[partial,lower],2),("opaque-over-video",[full,lower],1),("video-over-partial",[lower,partial],1),("partial-black",[partial],1),("transparent-black",[empty],1)] {
            let kept=visible(layers);XCTAssertEqual(kept.count,expectedCount);let p=try await h.plan(kept,frames:60,black:source.appendingPathComponent("black.mov")),reference=h.reference(layers,frame:30)
            let preview=try await managed(source,frame:30,plan:p),out=root.appendingPathComponent(name+".mp4"),result=await ExportService.export(p,to:.init(url:out,confirmedReplace:false,identityAtConfirmation:nil),sources:[]) { _ in };XCTAssertEqual(result,.completed(out));let exported=try await managed(out,frame:30)
            try note(name+"-visibility",["input":layers.count,"kept":kept.count,"expected":expectedCount]);try note(name+"-preview",compare(h.bytes(preview),h.bytes(reference),width:1920,height:1080));try note(name+"-export",compare(h.bytes(exported),h.bytes(reference),width:1920,height:1080))
            for (stage,pixels) in [("preview",h.bytes(preview)),("export",h.bytes(exported)),("reference",h.bytes(reference))] {
                let points=[(50,320),(300,500),(50,1050),(1000,1000)].map { x,y in (0..<4).map { Int(pixels[(y*1920+x)*4+$0]) } };try note(name+"-"+stage+"-probes",["xy":[[50,320],[300,500],[50,1050],[1000,1000]],"rgba":points])
            }
        }
    }
    final class SeekCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool,Never>?
        init(_ continuation: CheckedContinuation<Bool,Never>) { self.continuation = continuation }
        func finish(_ value: Bool) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning:value)
        }
    }
    @MainActor func boundedSeek(_ player:AVPlayer,_ time:CMTime) async -> Bool {
        await withCheckedContinuation { continuation in
            let completion=SeekCompletion(continuation)
            Task { try? await Task.sleep(nanoseconds:5_000_000_000); completion.finish(false) }
            player.seek(to:time,toleranceBefore:.zero,toleranceAfter:.zero) { completion.finish($0) }
        }
    }
    @MainActor func testAVPlayerObservation() async throws {
        let png=try h.decode(source.appendingPathComponent("png.png")),alpha=try h.decode(source.appendingPathComponent("alpha.png")),portrait=try h.decode(source.appendingPathComponent("orientation.jpg"))
        let blue=h.context(960,540);blue.setFillColor(CGColor(red:0.1,green:0.25,blue:0.7,alpha:1));blue.fill(CGRect(x:0,y:0,width:960,height:540))
        let image=ImageCacheFeasibilityTests.Layer(url:source.appendingPathComponent("png.mov"),image:png,start:15,end:105)
        let lower=ImageCacheFeasibilityTests.Layer(url:source.appendingPathComponent("ordinary-video.mov"),image:blue.makeImage()!,start:0,end:120)
        let upper=ImageCacheFeasibilityTests.Layer(url:source.appendingPathComponent("alpha.mov"),image:alpha,start:15,end:105)
        let rotated=ImageCacheFeasibilityTests.Layer(url:source.appendingPathComponent("orientation.mov"),image:portrait,start:15,end:105,rect:CGRect(x:656.25,y:0,width:607.5,height:1080))
        let mixed=[ImageCacheFeasibilityTests.Layer(url:lower.url,image:lower.image,start:0,end:30),ImageCacheFeasibilityTests.Layer(url:image.url,image:png,start:30,end:90)]
        for (name,layers) in [("image-only",[image]),("mixed",mixed),("alpha",[upper,lower]),("portrait",[rotated])] {
            let p=try await h.plan(layers,frames:120,black:source.appendingPathComponent("black.mov"))
            let item=AVPlayerItem(asset:p.composition);item.videoComposition=p.videoComposition
            let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);item.add(output)
            let player=AVPlayer(playerItem:item);player.isMuted=true;player.actionAtItemEnd = .pause
            defer { player.pause();item.remove(output);player.replaceCurrentItem(with:nil) }
            for _ in 0..<100 { if item.status != .unknown { break };try await Task.sleep(nanoseconds:50_000_000) }
            try note(name+"-player-ready",["status":item.status.rawValue,"error":String(describing:item.error),"ownerVisible":false,"subtitleUI":"not installed; product synchronized overlay untouched"])
            guard item.status == .readyToPlay else { continue }
            for frame in [0,14,15,29,30,44,45,46,74,75,76,104,105,119] {
                let time=CMTime(value:Int64(frame),timescale:30)
                let finished=await boundedSeek(player,time)
                var display=CMTime.invalid,pixel:CVPixelBuffer?
                var rejectedDisplayTimes: [Double] = []
                for _ in 0..<40 {
                    let candidate=output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&display)
                    if let candidate {
                        if display.isNumeric && CMTimeCompare(display,time)==0 { pixel=candidate;break }
                        if display.isNumeric { rejectedDisplayTimes.append(display.seconds) }
                    }
                    try await Task.sleep(nanoseconds:25_000_000)
                }
                var result:[String:Any]=["seekFinished":finished,"requestedFrame":frame,"currentSeconds":player.currentTime().seconds,"pixelObserved":pixel != nil,"displayValue":display.value,"displayTimescale":display.timescale,"rejectedStaleSeconds":rejectedDisplayTimes,"matchedWithin1Second":pixel != nil]
                XCTAssertNotNil(pixel,"AVPlayer did not provide the requested timestamp: \(name) frame \(frame)")
                if let pixel { result["buffer"]=pbInfo(pixel);result["comparisonRawCodeDiagnosticOnly"]=compare(rgb(pixel),h.bytes(h.reference(layers,frame:frame)),width:1920,height:1080) }
                try note(name+"-player-seek-\(frame)",result)
            }
            _=await boundedSeek(player,.zero);player.play();var observed:[Int]=[]
            for _ in 0..<30 { try await Task.sleep(nanoseconds:16_666_667);let time=player.currentTime();var displayed=CMTime.invalid;if output.hasNewPixelBuffer(forItemTime:time),output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&displayed) != nil { observed.append(Int((displayed.seconds*30).rounded())) } }
            player.pause();try note(name+"-player-playback",["observedFrames":observed,"rateAfterPause":player.rate,"durationSeconds":player.currentTime().seconds])
        }
    }
    func testExtractionControlsAndNativeGeometry() async throws {
        let image=try h.decode(source.appendingPathComponent("png.png")),expected=h.bytes(image)
        let prior=controlRoot.appendingPathComponent("testColorStages")
        for (name,u) in [("legacy709",source.appendingPathComponent("png.mov")),("srgbTag",prior.appendingPathComponent("srgbTag.mov"))] {
            let pb=try await sample(u),a=rgb(pb),data=Data(a)
            let profile=CVBufferCopyAttachment(pb,kCVImageBufferCGColorSpaceKey,nil) as! CGColorSpace
            let cg=CGImage(width:image.width,height:image.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:image.width*4,space:profile,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric)!
            let manual=h.bytes(cg),generator=try await managed(u)
            try note(name+"-manual-ICC-from-BGRA",compare(manual,expected,width:image.width,height:image.height))
            try note(name+"-manual-vs-generator",compare(h.bytes(generator),manual,width:image.width,height:image.height))
            let ci=CIImage(cvPixelBuffer:pb,options:[.colorSpace:profile]),context=CIContext(options:[.cacheIntermediates:false])
            let ciResult=context.createCGImage(ci,from:ci.extent,format:.RGBA8,colorSpace:h.cs)!
            try note(name+"-CoreImage-normalized",compare(h.bytes(ciResult),expected,width:image.width,height:image.height))
            for mode in [AVAssetImageGenerator.ApertureMode.encodedPixels,.cleanAperture,.productionAperture] {
                let g=AVAssetImageGenerator(asset:AVURLAsset(url:u));g.apertureMode=mode;g.requestedTimeToleranceBefore = .zero;g.requestedTimeToleranceAfter = .zero
                let r=try await g.image(at:.zero);try note(name+"-aperture-"+mode.rawValue,compare(h.bytes(r.image),expected,width:image.width,height:image.height))
            }
        }
        // Unscaled composition control separates codec/presentation from 2x resampling.
        let corrected=prior.appendingPathComponent("srgbTag.mov")
        let layer=ImageCacheFeasibilityTests.Layer(url:corrected,image:image,start:0,end:60,rect:CGRect(x:0,y:0,width:960,height:540))
        let p=try await h.plan([layer],frames:60,black:source.appendingPathComponent("black.mov"))
        // AVFoundation transforms use top-left canvas coordinates; CG reference uses bottom-left.
        var referenceLayer=layer;referenceLayer.rect.origin.y=1080-layer.rect.maxY
        let ref=h.reference([referenceLayer],frame:30)
        let frame=try await managed(corrected,frame:30,plan:p);try note("unscaled-composition-corrected-top-left-mapping",compare(h.bytes(frame),h.bytes(ref),width:1920,height:1080))
        let fileSource=CGImageSourceCreateWithURL(source.appendingPathComponent("png.png") as CFURL,nil)!
        let independentImage=CGImageSourceCreateImageAtIndex(fileSource,0,nil)!
        try note("independent-source-vs-normalized",compare(h.bytes(independentImage),expected,width:image.width,height:image.height))
        // Existing production planner called unchanged with a generated ordinary video asset.
        let u=source.appendingPathComponent("orientation.mov"),asset=AVURLAsset(url:u),track=try await asset.loadTracks(withMediaType:.video)[0],size=try await track.load(.naturalSize)
        let m=MediaAsset(id:UUID(),url:u,name:"generated portrait video",frameCount:30,timing:SourceTiming(sampleCount:30,isVariable:false,frameDurationValue:1,frameDurationTimescale:30,averageFPS:30,minInterval:1/30,maxInterval:1/30),naturalSize:size,displaySize:size,preferredTransform:.identity,hasAudio:false,codec:"test-only ProRes",identity:FileIdentity.of(u)!)
        let timeline=try Timeline().registering(m).inserting(media:m.id),native=try await CompositionPlanner.plan(timeline,media:[m.id:m])
        let pixels=rgb(try await sample(u,plan:native,frame:15));var visible:[Int]=[]
        for x in 0..<1920 { let k=(540*1920+x)*4;if max(pixels[k],pixels[k+1],pixels[k+2])>25 { visible.append(x) } }
        try note("unchanged-production-planner-portrait",["first":visible.first! ,"last":visible.last!,"expectedNativeObserved":[656,1262]])
        XCTAssertEqual(visible.first,656);XCTAssertEqual(visible.last,1262)
        // Alpha strategy metamorphic controls do not confuse gamma error with visibility.
        let directory=prior.deletingLastPathComponent().appendingPathComponent("testAlphaVisibility")
        let transparent=h.bytes(try await managed(directory.appendingPathComponent("transparent-over-video.mp4"),frame:30)),lower=h.bytes(try await managed(directory.appendingPathComponent("video-over-partial.mp4"),frame:30))
        let comparison=compare(transparent,lower,width:1920,height:1080);try note("transparent-over-lower-vs-lower-only",comparison);XCTAssertLessThanOrEqual(comparison["max"] as! Int,3)
        let black=h.bytes(try await managed(directory.appendingPathComponent("transparent-black.mp4"),frame:30))
        let maxBlack=black.enumerated().filter { $0.offset%4 != 3 }.map { $0.element }.max()!
        XCTAssertLessThanOrEqual(maxBlack,3) // Original IMG-1A flat-field limit, not exact lossy equality.
        try note("transparent-without-lower-black",["measuredMaxRGB":Int(maxBlack),"originalFlatLimit":3])
    }

    @MainActor func testAVPlayerExportedSubtitleAndRepeat() async throws {
        let input=source.appendingPathComponent("alpha-subtitle.mp4"),item=AVPlayerItem(url:input)
        let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);item.add(output)
        let player=AVPlayer(playerItem:item);player.isMuted=true
        defer { player.pause();item.remove(output);player.replaceCurrentItem(with:nil) }
        for _ in 0..<100 { if item.status != .unknown { break };try await Task.sleep(nanoseconds:50_000_000) }
        try note("baked-subtitle-player-ready",["status":item.status.rawValue,"ownerVisible":false,"subtitleKind":"already-exported text; not app overlay"])
        guard item.status == .readyToPlay else { return XCTFail("subtitle player not ready") }
        let plain=source.appendingPathComponent("alpha-over-video.mp4")
        for frame in [29,30,59,60] {
            let time=CMTime(value:Int64(frame),timescale:30);_=await boundedSeek(player,time)
            var accepted:CVPixelBuffer?,display=CMTime.invalid
            for _ in 0..<40 { if let pb=output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&display),CMTimeCompare(display,time)==0 { accepted=pb;break };try await Task.sleep(nanoseconds:25_000_000) }
            guard let accepted else { XCTFail("no matched subtitle frame \(frame)");continue }
            let actual=rgb(accepted),baseline=rgb(try await sample(plain,frame:frame));var changed=0
            for y in 700..<1080 { for x in 300..<1620 { let k=(y*1920+x)*4;if (0..<3).contains(where:{ abs(Int(actual[k+$0])-Int(baseline[k+$0]))>30 }) { changed += 1 } } }
            try note("baked-subtitle-frame-\(frame)",["displayValue":display.value,"displayTimescale":display.timescale,"roiPixelsOver30":changed,"expectedSubtitle":frame>=30 && frame<60])
            if frame>=30 && frame<60 { XCTAssertGreaterThan(changed,1000) } else { XCTAssertEqual(changed,0) }
        }
        _=await boundedSeek(player,CMTime(value:40,timescale:30));player.play();var observed:[Int]=[]
        for _ in 0..<90 { try await Task.sleep(nanoseconds:16_666_667);let time=player.currentTime();var display=CMTime.invalid
            if output.hasNewPixelBuffer(forItemTime:time),output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&display) != nil { observed.append(Int((display.seconds*30).rounded())) }
        }
        player.pause();try note("exported-cache-repeat-playback",["observedFrames":observed,"crossed45":observed.contains(45),"crossed75":observed.contains(75),"bakedOutputNotProductUI":true])
    }

    func testSamplingKernelControls() async throws {
        let sourceImage=try h.decode(source.appendingPathComponent("png.png"))
        let controls=controlRoot.appendingPathComponent("testColorStages")
        let layer=ImageCacheFeasibilityTests.Layer(url:controls.appendingPathComponent("srgbTag.mov"),image:sourceImage,start:0,end:60)
        let plan=try await h.plan([layer],frames:60,black:source.appendingPathComponent("black.mov")),composition=try await managed(layer.url,frame:30,plan:plan),actual=h.bytes(composition)
        for (name,quality) in [("none",CGInterpolationQuality.none),("low",.low),("medium",.medium),("high-original",.high)] {
            let c=h.context(1920,1080);c.interpolationQuality=quality;c.draw(sourceImage,in:CGRect(x:0,y:0,width:1920,height:1080));let reference=c.makeImage()!
            try note("independent-CG-kernel-"+name,compare(actual,h.bytes(reference),width:1920,height:1080))
        }
        // Color conversion of the 8-bit decoded buffer is independently established;
        // compare spatial extraction branches after the same source-space declaration.
        let pb=try await sample(layer.url),input=CIImage(cvPixelBuffer:pb,options:[.colorSpace:h.cs]),context=CIContext(options:[.cacheIntermediates:false])
        let ci=context.createCGImage(input.transformed(by:CGAffineTransform(scaleX:2,y:2)),from:CGRect(x:0,y:0,width:1920,height:1080),format:.RGBA8,colorSpace:h.cs)!
        try note("independent-CI-default-scale",compare(actual,h.bytes(ci),width:1920,height:1080))
    }

    func testRangeAndAlphaBoundaryControls() async throws {
        for name in ["png","alpha"] {
            let u=source.appendingPathComponent(name+".mov"),pb=try await sample(u),image=try h.decode(source.appendingPathComponent(name+".png"))
            let actual=rgb(pb),expected=h.bytes(image)
            var maxAlpha=0
            for k in stride(from:3,to:actual.count,by:4) { maxAlpha=max(maxAlpha,abs(Int(actual[k])-Int(expected[k]))) }
            try note(name+"-BGRA-component-diagnostic",compare(actual,expected,width:image.width,height:image.height))
            try note(name+"-alpha",["maxAlphaDifference":maxAlpha,"reader":pbInfo(pb),"source":space(image)])
            XCTAssertEqual(maxAlpha,0)
        }
        let asset=AVURLAsset(url:source.appendingPathComponent("png.mov")),track=try await asset.loadTracks(withMediaType:.video)[0]
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output);guard reader.startReading(),let sample=output.copyNextSampleBuffer(),let pb=CMSampleBufferGetImageBuffer(sample) else { throw reader.error ?? NSError(domain:"range-reader",code:1) }
        defer { reader.cancelReading() };CVPixelBufferLockBaseAddress(pb,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
        let base=CVPixelBufferGetBaseAddressOfPlane(pb,0)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRowOfPlane(pb,0),w=CVPixelBufferGetWidthOfPlane(pb,0),height=CVPixelBufferGetHeightOfPlane(pb,0)
        var lo=255,hi=0
        for y in 0..<height { for x in 0..<w { let value=Int(base[y*stride+x]);lo=min(lo,value);hi=max(hi,value) } }
        try note("explicit-420v-range",["buffer":pbInfo(pb),"minY":lo,"maxY":hi,"rangeConvention":"video Y nominal16...235; codec residuals recorded, not clamped"])
    }

    func testIndependentBilinearReference() async throws {
        let image=try h.decode(source.appendingPathComponent("png.png")),pixels=h.bytes(image)
        let controls=controlRoot.appendingPathComponent("testColorStages")
        let layer=ImageCacheFeasibilityTests.Layer(url:controls.appendingPathComponent("srgbTag.mov"),image:image,start:0,end:60)
        let p=try await h.plan([layer],frames:60,black:source.appendingPathComponent("black.mov")),native=h.bytes(try await managed(layer.url,frame:30,plan:p))
        let finalExport=h.bytes(try await managed(controls.appendingPathComponent("srgbTag.mp4"),frame:30))
        let linearLUT=(0..<256).map { i -> Double in let v=Double(i)/255;return v<=0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
        let pb=try await sample(layer.url),ci=CIImage(cvPixelBuffer:pb,options:[.colorSpace:h.cs]),context=CIContext(options:[.cacheIntermediates:false])
        let ciImage=context.createCGImage(ci.transformed(by:CGAffineTransform(scaleX:2,y:2)),from:CGRect(x:0,y:0,width:1920,height:1080),format:.RGBA8,colorSpace:h.cs)!,ciPixels=h.bytes(ciImage)
        for linear in [false,true] {
            var expected=[UInt8](repeating:255,count:1920*1080*4)
            for y in 0..<1080 {
                let sy=(Double(y)+0.5)/2-0.5,y0=Int(floor(sy)),fy=sy-Double(y0),top=max(0,min(539,y0)),bottom=max(0,min(539,y0+1))
                for x in 0..<1920 {
                    let sx=(Double(x)+0.5)/2-0.5,x0=Int(floor(sx)),fx=sx-Double(x0),left=max(0,min(959,x0)),right=max(0,min(959,x0+1))
                    let indices=[(top*960+left)*4,(top*960+right)*4,(bottom*960+left)*4,(bottom*960+right)*4],weights=[(1-fx)*(1-fy),fx*(1-fy),(1-fx)*fy,fx*fy]
                    for channel in 0..<3 {
                        var value=0.0
                        for n in 0..<4 { let input=Int(pixels[indices[n]+channel]);value += (linear ? linearLUT[input] : Double(input)/255)*weights[n] }
                        if linear { value=value<=0.0031308 ? value*12.92 : 1.055*pow(value,1/2.4)-0.055 }
                        expected[(y*1920+x)*4+channel]=UInt8(max(0,min(255,(value*255).rounded())))
                    }
                }
            }
            try note(linear ? "manual-linear-light-vs-native" : "manual-encoded-light-vs-native",compare(native,expected,width:1920,height:1080))
            try note(linear ? "manual-linear-light-vs-CI" : "manual-encoded-light-vs-CI",compare(ciPixels,expected,width:1920,height:1080))
            try note(linear ? "manual-linear-light-vs-final-export" : "manual-encoded-light-vs-final-export",compare(finalExport,expected,width:1920,height:1080))
        }
    }

}
