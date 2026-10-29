import XCTest
import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
@testable import OnTheFrameEngine

/// IMG-1A-3 isolated investigation. Original helpers, contracts and evidence are immutable.
final class ImageSamplingContractTests: XCTestCase {
    var h: ImageCacheFeasibilityTests!
    var i: ImageCacheInvestigationTests!
    var root: URL!
    var source: URL!
    override func setUp() async throws {
        guard let run=ProcessInfo.processInfo.environment["OTF_IMG1A3_RUN"] else { throw XCTSkip("IMG-1A-3 opt-in") }
        guard let input=ProcessInfo.processInfo.environment["OTF_IMG1A3_SOURCE"] else { throw NSError(domain:"source-required",code:1) }
        source=URL(fileURLWithPath:input)
        let method=name.components(separatedBy:" ").last!.replacingOccurrences(of:"]",with:"")
        root=URL(fileURLWithPath:run).appendingPathComponent(method)
        guard !FileManager.default.fileExists(atPath:root.path) else { throw NSError(domain:"fresh-root-required",code:1) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        h=ImageCacheFeasibilityTests();h.root=root
        i=ImageCacheInvestigationTests();i.h=h;i.root=root;i.source=source
    }
    func jsonSafe(_ value:Any)->Any {
        if let dictionary=value as? [String:Any] { return dictionary.mapValues(jsonSafe) }
        if let array=value as? [Any] { return array.map(jsonSafe) }
        if let number=value as? NSNumber, !number.doubleValue.isFinite { return "nonfinite:"+String(describing:number) }
        return value
    }
    func note(_ name:String,_ value:[String:Any]) throws { try h.record(name,jsonSafe(value) as! [String:Any]) }
    func stats(_ actual:[UInt8],_ expected:[UInt8],width:Int,height:Int,rect:CGRect?=nil,excluded:CGRect?=nil)->[String:Any] {
        precondition(actual.count==expected.count && actual.count==width*height*4)
        let region=rect ?? CGRect(x:0,y:0,width:width,height:height)
        var sse=0.0,maximum=0,hist=[Int](repeating:0,count:256),worstX=Int(region.minX),worstY=Int(region.minY),worstChannel=0,n=0,changed=0
        for y in Int(region.minY)..<Int(region.maxY) { for x in Int(region.minX)..<Int(region.maxX) {
            if let excluded, Double(x)>=excluded.minX && Double(x)<excluded.maxX && Double(y)>=excluded.minY && Double(y)<excluded.maxY { continue }
            let k=(y*width+x)*4;var pixelMaximum=0
            for c in 0..<3 { let error=abs(Int(actual[k+c])-Int(expected[k+c]));sse += Double(error*error);hist[error] += 1;n += 1;pixelMaximum=max(pixelMaximum,error)
                if error>maximum { maximum=error;worstX=x;worstY=y;worstChannel=c }
            };if pixelMaximum>3 { changed += 1 }
        } }
        var total=0,p99=0;for error in 0..<256 { total += hist[error];if total>=n*99/100 { p99=error;break } }
        let index=(worstY*width+worstX)*4,psnr=sse==0 ? 999 : 10*log10(65025/(sse/Double(n)))
        return ["psnr":psnr,"max":maximum,"p99":p99,"worstXY":[worstX,worstY],"worstChannel":worstChannel,"actualRGBA":Array(actual[index..<index+4]).map(Int.init),"expectedRGBA":Array(expected[index..<index+4]).map(Int.init),"fractionPixelsOver3":Double(changed)/Double(max(1,n/3)),"rect":[region.minX,region.minY,region.width,region.height],"psnr40":psnr>=40]
    }
    func measure(_ name:String,_ actual:[UInt8],_ expected:[UInt8],portrait:Bool=false) throws {
        try note(name+"-global",stats(actual,expected,width:1920,height:1080))
        let regions:[(String,CGRect)] = portrait ? [("portrait-left",CGRect(x:650,y:0,width:16,height:1080)),("portrait-right",CGRect(x:1255,y:0,width:16,height:1080)),("portrait-interior",CGRect(x:720,y:350,width:400,height:300))] : [
            ("neutral",CGRect(x:1420,y:450,width:160,height:200)),("saturated",CGRect(x:200,y:450,width:160,height:200)),("gradient",CGRect(x:200,y:160,width:1400,height:100)),("fine-lines",CGRect(x:200,y:870,width:1400,height:100)),("alpha-edge",CGRect(x:158,y:400,width:10,height:300)),("opaque-marker",CGRect(x:20,y:1020,width:80,height:40))]
        for (label,rect) in regions { try note(name+"-"+label,stats(actual,expected,width:1920,height:1080,rect:rect)) }
    }
    /// Independent arithmetic, no CG/CI scaling or candidate pixels in the reference.
    /// Top-left canvas; bilinear interpolation of premultiplied encoded-sRGB RGBA.
    func analytic(_ layers:[ImageCacheFeasibilityTests.Layer],frame:Int,nativeMask:Bool)->[UInt8] {
        var output=[UInt8](repeating:0,count:1920*1080*4)
        for k in stride(from:3,to:output.count,by:4) { output[k]=255 }
        for layer in layers.reversed() where layer.start<=frame && frame<layer.end {
            let image=layer.image,pixels=h.bytes(image),w=image.width,height=image.height,rect=layer.rect
            let loX=max(0,Int(floor(rect.minX))-2),hiX=min(1920,Int(ceil(rect.maxX))+2),loY=max(0,Int(floor(rect.minY))-2),hiY=min(1080,Int(ceil(rect.maxY))+2)
            for y in loY..<hiY {
                let edgeY=(Double(y)+0.5-rect.minY)*Double(height)/rect.height
                if nativeMask ? (edgeY < -0.25 || edgeY >= Double(height)-0.25) : (edgeY<0 || edgeY>=Double(height)) { continue }
                let sy=edgeY-0.5,y0=Int(floor(sy)),fy=sy-Double(y0),top=max(0,min(height-1,y0)),bottom=max(0,min(height-1,y0+1))
                for x in loX..<hiX {
                    let edgeX=(Double(x)+0.5-rect.minX)*Double(w)/rect.width
                    if nativeMask ? (edgeX < -0.25 || edgeX >= Double(w)-0.25) : (edgeX<0 || edgeX>=Double(w)) { continue }
                    let sx=edgeX-0.5,x0=Int(floor(sx)),fx=sx-Double(x0),left=max(0,min(w-1,x0)),right=max(0,min(w-1,x0+1))
                    let taps=[(top*w+left)*4,(top*w+right)*4,(bottom*w+left)*4,(bottom*w+right)*4],weights=[(1-fx)*(1-fy),fx*(1-fy),(1-fx)*fy,fx*fy]
                    var rgba=[Double](repeating:0,count:4)
                    for n in 0..<4 { for c in 0..<4 { rgba[c] += Double(pixels[taps[n]+c])*weights[n] } }
                    let k=(y*1920+x)*4,remaining=1-rgba[3]/255
                    for c in 0..<3 { output[k+c]=UInt8(max(0,min(255,(rgba[c]+Double(output[k+c])*remaining).rounded()))) }
                }
            }
        };return output
    }
    func imageFrom(_ pixels:[UInt8],width:Int,height:Int,space:CGColorSpace?=nil)->CGImage {
        CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space ?? h.cs,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(pixels) as CFData)!,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric)!
    }
    func testSixteenBitRepresentation() async throws {
        let controls=source.deletingLastPathComponent().appendingPathComponent("img1a2-20261027-01/testColorStages")
        let u=controls.appendingPathComponent("srgbTag.mov"),image=try await i.managed(u),expected=h.bytes(try h.decode(source.appendingPathComponent("png.png"))),pb=try await i.sample(u),raw8=i.rgb(pb)
        let flags=image.bitmapInfo.rawValue,floatComponents=image.bitmapInfo.contains(.floatComponents),order=flags & CGBitmapInfo.byteOrderMask.rawValue
        let data=try XCTUnwrap(image.dataProvider?.data) as Data
        let count=image.colorSpace!.numberOfComponents,decode=image.decode.map { Array(UnsafeBufferPointer(start:$0,count:count*2)).map(Double.init) } ?? []
        try note("generator-representation",["image":i.space(image),"bitmapFlags":flags,"float":floatComponents,"byteOrder":order,"bytesPerRow":image.bytesPerRow,"providerBytes":data.count,"decode":decode,"shouldInterpolate":image.shouldInterpolate])
        guard image.bitsPerComponent==16 && image.bitsPerPixel==64 else { throw XCTSkip("representation differs; metadata recorded") }
        let little=order==CGBitmapInfo.byteOrder16Little.rawValue || (order==0 && CFByteOrderGetCurrent()==CFByteOrderLittleEndian.rawValue)
        var reconstructed=[UInt8](repeating:255,count:image.width*image.height*4),rawWorst=0.0,rawMinimum=Double.infinity,rawMaximum = -Double.infinity
        for y in 0..<image.height { for x in 0..<image.width { for c in 0..<3 {
            let offset=y*image.bytesPerRow+x*8+c*2
            let word=little ? UInt16(data[offset]) | UInt16(data[offset+1])<<8 : UInt16(data[offset])<<8 | UInt16(data[offset+1])
            var value=floatComponents ? Double(Float16(bitPattern:word)) : Double(word)/65535
            if !decode.isEmpty { value=decode[c*2]+value*(decode[c*2+1]-decode[c*2]) }
            guard value.isFinite else { throw NSError(domain:"nonfinite-half-float",code:1) }
            rawWorst=max(rawWorst,abs(value));rawMinimum=min(rawMinimum,value);rawMaximum=max(rawMaximum,value);reconstructed[(y*image.width+x)*4+c]=UInt8(max(0,min(255,(value*255).rounded())))
        } } }
        try note("raw16-range",["maxAbsolute":rawWorst,"minComponent":rawMinimum,"maxComponent":rawMaximum,"littleEndian":little])
        try note("raw16-rounded-vs-reader8",stats(reconstructed,raw8,width:960,height:540))
        let rebuilt=imageFrom(reconstructed,width:960,height:540,space:image.colorSpace),managed8=h.bytes(rebuilt),normal=h.bytes(image)
        try note("raw16-rounded-ICC-vs-source",stats(managed8,expected,width:960,height:540))
        try note("original16-CG8-vs-source",stats(normal,expected,width:960,height:540))
        try note("original16-vs-rebuilt8",stats(normal,managed8,width:960,height:540))
        for (name,quality) in [("none",CGInterpolationQuality.none),("low",.low),("high",.high)] {
            let c=h.context(960,540);c.interpolationQuality=quality;c.setShouldAntialias(false);c.draw(image,in:CGRect(x:0,y:0,width:960,height:540))
            try note("CG16-to8-"+name,stats(h.bytes(c.makeImage()!),expected,width:960,height:540))
        }
        let ci=CIImage(cgImage:image),context=CIContext(options:[.cacheIntermediates:false]),converted=context.createCGImage(ci,from:ci.extent,format:.RGBA8,colorSpace:h.cs)!
        try note("CI16-to8",stats(h.bytes(converted),expected,width:960,height:540))
    }
    func testControlledMatrix() async throws {
        // Historical source-quarter hypothesis scores remain diagnostic only.
        // Use testReanalyzeMatrix for the validated ideal-coordinate comparisons.
        try note("initial-quarter-hypothesis-not-quality-contract",["falsifiedAt2x":true,"authoritativeAnalysis":"testReanalyzeMatrix"])
        let black=source.appendingPathComponent("black.mov")
        // The existing video's intended colors come from its tagged decoded source,
        // not the pre-encoding synthetic CG plate (a different comparison).
        let videoURL=source.appendingPathComponent("ordinary-video.mov"),videoImage=try await i.managed(videoURL)
        let lower=ImageCacheFeasibilityTests.Layer(url:videoURL,image:videoImage,start:0,end:90)
        let names=["jpeg","png","alpha","p3","orientation"]
        for name in names {
            let input=source.appendingPathComponent(name+(name=="jpeg" || name=="orientation" ? ".jpg" : ".png")),image=try h.decode(input)
            let cache=try await i.encode(image,name:"corrected-"+name,mode:"srgbTag")
            var upper=ImageCacheFeasibilityTests.Layer(url:cache,image:image,start:0,end:90)
            if name=="orientation" { upper.rect=CGRect(x:656.25,y:0,width:607.5,height:1080) }
            let all=name=="alpha" ? [upper,lower] : [upper],kept=i.visible(all)
            XCTAssertEqual(kept.count,all.count)
            let reference=analytic(all,frame:30,nativeMask:true),ideal=analytic(all,frame:30,nativeMask:false),cg=h.reference(all,frame:30)
            try note(name+"-source",["image":i.space(image),"cache":try await i.tags(cache),"layers":kept.count,"referencePolicy":"proposed encoded-premultiplied bilinear + separately labeled native mask"])
            let base=try await h.plan(kept,frames:90,black:black)
            let preview=try await i.managed(cache,frame:30,plan:base)
            try measure(name+"-preview-vs-analytic",h.bytes(preview),reference,portrait:name=="orientation")
            try note(name+"-preview-vs-original-CG",stats(h.bytes(preview),h.bytes(cg),width:1920,height:1080))
            try note(name+"-CG-vs-analytic",stats(h.bytes(cg),reference,width:1920,height:1080))
            if name=="orientation" { try note(name+"-preview-vs-ideal-coverage",stats(h.bytes(preview),ideal,width:1920,height:1080)) }
            for subtitle in [false,true] {
                var plan=base
                if subtitle { plan.subtitles=[SubtitleItem(lane:UUID(),start:30,length:30,text:"IMG-1A-3 subtitle")] }
                let label=name+(subtitle ? "-subtitle" : "-plain"),dest=root.appendingPathComponent(label+".mp4")
                let outcome=await ExportService.export(plan,to:.init(url:dest,confirmedReplace:false,identityAtConfirmation:nil),sources:[]) { _ in }
                try note(label+"-export",["outcome":String(describing:outcome)]);XCTAssertEqual(outcome,.completed(dest))
                let output=try await i.managed(dest,frame:30)
                // Unmasked scores are retained; subtitle is intentionally absent in image reference.
                try measure(label+"-unmasked-vs-analytic",h.bytes(output),reference,portrait:name=="orientation")
                try note(label+"-vs-original-CG",stats(h.bytes(output),h.bytes(cg),width:1920,height:1080))
                if subtitle {
                    // Measure subtitle-free frame29 against the same image reference, no mask.
                    let outside=try await i.managed(dest,frame:29)
                    try measure(label+"-frame29-vs-analytic",h.bytes(outside),reference,portrait:name=="orientation")
                    let a=h.bytes(output),b=h.bytes(preview)
                    try note(label+"-subtitle-ROI-path-difference",stats(a,b,width:1920,height:1080,rect:CGRect(x:300,y:700,width:1320,height:380)))
                }
                try await timing(dest,frames:90,name:label)
                let generator=AVAssetImageGenerator(asset:AVURLAsset(url:dest));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                for frame in [0,29,30,59,60,89] {
                    let result=try await generator.image(at:CMTime(value:Int64(frame),timescale:30))
                    XCTAssertEqual(CMTimeCompare(result.actualTime,CMTime(value:Int64(frame),timescale:30)),0)
                    let pixels=h.bytes(result.image)
                    // Stable image interiors, excluding the subtitle footprint, detect black flashes.
                    try note(label+"-boundary-\(frame)",stats(pixels,reference,width:1920,height:1080,rect:name=="orientation" ? CGRect(x:720,y:350,width:400,height:250) : CGRect(x:200,y:400,width:1400,height:250)))
                }
                if h.rss()>1_073_741_824 { throw NSError(domain:"memory-budget",code:1) }
            }
        }
    }
    func timing(_ url:URL,frames:Int,name:String) async throws {
        let a=AVURLAsset(url:url),track=try await a.loadTracks(withMediaType:.video)[0],reader=try AVAssetReader(asset:a),output=AVAssetReaderTrackOutput(track:track,outputSettings:nil)
        reader.add(output);XCTAssertTrue(reader.startReading());var count=0,badDuration=0;var pts:[CMTime]=[]
        while let sample=output.copyNextSampleBuffer() {
            pts.append(CMSampleBufferGetPresentationTimeStamp(sample));if CMTimeCompare(CMSampleBufferGetDuration(sample),CMTime(value:1,timescale:30)) != 0 { badDuration += 1 };count += 1
        }
        pts.sort { CMTimeCompare($0,$1)<0 };var badPTS=0
        for (n,p) in pts.enumerated() { if CMTimeCompare(p,CMTime(value:Int64(n),timescale:30)) != 0 { badPTS += 1 } }
        let duration=try await track.load(.timeRange).duration
        try note(name+"-timing",["frames":count,"badPTS":badPTS,"badSampleDuration":badDuration,"duration":duration.seconds,"readerStatus":reader.status.rawValue])
        // Coded edit/empty buffers are not displayed frames. Preserve their raw
        // diagnostic counts, but use image-bearing decoded samples for the gate.
        XCTAssertEqual(CMTimeCompare(duration,CMTime(value:Int64(frames),timescale:30)),0)
        XCTAssertEqual(reader.status,.completed)
        try await decodedTiming(url,name:name+"-display-validation")
    }
    var matrixRoot:URL {
        if let value=ProcessInfo.processInfo.environment["OTF_IMG1A3_MATRIX"] { return URL(fileURLWithPath:value) }
        return source.deletingLastPathComponent().appendingPathComponent("img1a3-20261028-01/testControlledMatrix")
    }
    func decodedTiming(_ url:URL,name:String) async throws {
        let asset=AVURLAsset(url:url),track=try await asset.loadTracks(withMediaType:.video)[0]
        for compressed in [true,false] {
            let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:compressed ? nil : [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData=false;reader.add(output);XCTAssertTrue(reader.startReading())
            var pts:[CMTime]=[],rows:[[String:Any]]=[],emptyBuffers=0
            while let sample=output.copyNextSampleBuffer() {
                let time=CMSampleBufferGetPresentationTimeStamp(sample),samples=CMSampleBufferGetNumSamples(sample)
                let displayed=CMSampleBufferGetImageBuffer(sample) != nil
                if samples==0 { emptyBuffers += 1 }
                if compressed || displayed { pts.append(time) }
                if rows.count<8 { rows.append(["ptsValue":time.value,"ptsScale":time.timescale,"outputPTS":CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds,"decodePTS":CMSampleBufferGetDecodeTimeStamp(sample).seconds,"duration":CMSampleBufferGetDuration(sample).seconds,"samples":samples,"hasImage":displayed,"attachments":String(describing:CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false))]) }
            }
            pts.sort { CMTimeCompare($0,$1)<0 };let negative=pts.filter { CMTimeCompare($0,.zero)<0 }.count
            var bad=0;for (index,p) in pts.enumerated() { if CMTimeCompare(p,CMTime(value:Int64(index),timescale:30)) != 0 { bad += 1 } }
            try note(name+(compressed ? "-compressed-representation" : "-decoded-timing"),["count":pts.count,"emptyBuffers":emptyBuffers,"negativePTS":negative,"badAgainstDisplayGrid":bad,"readerStatus":reader.status.rawValue,"firstRows":rows])
            if !compressed { XCTAssertEqual(pts.count,90);XCTAssertEqual(bad,0);XCTAssertEqual(reader.status,.completed) }
        }
    }
    func testReanalyzeMatrix() async throws {
        let videoURL=source.appendingPathComponent("ordinary-video.mov"),video=try await i.managed(videoURL),black=source.appendingPathComponent("black.mov")
        let lower=ImageCacheFeasibilityTests.Layer(url:videoURL,image:video,start:0,end:90)
        // Full-frame white has no outside canvas pixels. This independently disproves
        // the source-quarter hypothesis at 2x without selecting a quality score.
        let white=h.context(960,540);white.setFillColorSpace(h.cs);white.setFillColor([1,1,1,1]);white.fill(CGRect(x:0,y:0,width:960,height:540))
        let whiteLayer=ImageCacheFeasibilityTests.Layer(url:black,image:white.makeImage()!,start:0,end:90)
        let incorrect=analytic([whiteLayer],frame:0,nativeMask:true),correct=analytic([whiteLayer],frame:0,nativeMask:false)
        try note("quarter-mask-falsification",["oldRightBottom":Array(incorrect.suffix(4)).map(Int.init),"idealRightBottom":Array(correct.suffix(4)).map(Int.init),"expectedRightBottom":[255,255,255,255]])
        XCTAssertEqual(Array(correct.suffix(4)),[255,255,255,255])
        for name in ["jpeg","png","alpha","p3","orientation"] {
            let input=source.appendingPathComponent(name+(name=="jpeg" || name=="orientation" ? ".jpg" : ".png")),image=try h.decode(input),cache=matrixRoot.appendingPathComponent("corrected-"+name+".mov")
            var upper=ImageCacheFeasibilityTests.Layer(url:cache,image:image,start:0,end:90)
            if name=="orientation" { upper.rect=CGRect(x:656.25,y:0,width:607.5,height:1080) }
            let all=name=="alpha" ? [upper,lower] : [upper],plan=try await h.plan(i.visible(all),frames:90,black:black)
            let ideal=analytic(all,frame:30,nativeMask:false)
            var reference=ideal
            if name=="orientation" {
                // Fixture-specific native parity from immutable prior production/plate evidence.
                // This is a separately reported geometry convention, NOT a general new floor rule.
                for y in 0..<1080 { for x in 0..<1920 where x<656 || x>=1263 { let k=(y*1920+x)*4;reference[k]=0;reference[k+1]=0;reference[k+2]=0 } }
            }
            let preview=h.bytes(try await i.managed(cache,frame:30,plan:plan))
            try measure(name+"-corrected-preview",preview,reference,portrait:name=="orientation")
            if name=="orientation" { try note("portrait-preview-ideal-full-coverage",stats(preview,ideal,width:1920,height:1080)) }
            try note(name+"-preview-original-CG-reference",stats(preview,h.bytes(h.reference(all,frame:30)),width:1920,height:1080))
            for subtitle in [false,true] {
                let label=name+(subtitle ? "-subtitle" : "-plain"),url=matrixRoot.appendingPathComponent(label+".mp4")
                let at30=h.bytes(try await i.managed(url,frame:30))
                if subtitle {
                    let item=SubtitleItem(lane:UUID(),start:30,length:30,text:"IMG-1A-3 subtitle"),raster=SubtitleRenderer.shared.raster(item)
                    let footprint=raster.drawRect.insetBy(dx:-2,dy:-2).intersection(CGRect(x:0,y:0,width:1920,height:1080))
                    try note(label+"-image-background-excluding-subtitle",stats(at30,reference,width:1920,height:1080,excluded:footprint))
                    try note(label+"-declared-subtitle-exclusion",["rect":[footprint.minX,footprint.minY,footprint.width,footprint.height],"reason":"image-only reference has no glyphs; tight raster +2 chroma pixels; unmasked comparison retained"])
                    let at29=h.bytes(try await i.managed(url,frame:29));try measure(label+"-corrected-frame29",at29,reference,portrait:name=="orientation")
                } else { try measure(label+"-corrected-frame30",at30,reference,portrait:name=="orientation") }
                try note(label+"-corrected-unmasked",stats(at30,reference,width:1920,height:1080))
                try await decodedTiming(url,name:label)
                for frame in [0,29,30,59,60,89] {
                    let pixels=h.bytes(try await i.managed(url,frame:frame))
                    try note(label+"-corrected-boundary-\(frame)",stats(pixels,reference,width:1920,height:1080,rect:name=="orientation" ? CGRect(x:720,y:350,width:400,height:250) : CGRect(x:200,y:400,width:1400,height:250)))
                }
            }
        }
    }

    func testIndependentHalfFloatAndAlphaControls() async throws {
        let controls=source.deletingLastPathComponent().appendingPathComponent("img1a2-20261027-01/testColorStages"),image=try h.decode(source.appendingPathComponent("png.png")),expected=h.bytes(image)
        let extracted=try await i.managed(controls.appendingPathComponent("srgbTag.mov"))
        var data=Data();data.reserveCapacity(960*540*8)
        for byte in expected { var word=Float16(Double(byte)/255).bitPattern.littleEndian;withUnsafeBytes(of:&word) { data.append(contentsOf:$0) } }
        let flags=CGBitmapInfo.floatComponents.rawValue|CGBitmapInfo.byteOrder16Little.rawValue|CGImageAlphaInfo.noneSkipLast.rawValue
        let synthetic=CGImage(width:960,height:540,bitsPerComponent:16,bitsPerPixel:64,bytesPerRow:960*8,space:extracted.colorSpace!,bitmapInfo:CGBitmapInfo(rawValue:flags),provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:true,intent:.relativeColorimetric)!
        try note("synthetic-half16-same-profile",stats(h.bytes(synthetic),expected,width:960,height:540))
        var gray=expected
        for k in stride(from:0,to:gray.count,by:4) { let y=UInt8((Double(gray[k])*0.2126+Double(gray[k+1])*0.7152+Double(gray[k+2])*0.0722).rounded());gray[k]=y;gray[k+1]=y;gray[k+2]=y }
        let grayImage=imageFrom(gray,width:960,height:540),cache=try await i.encode(grayImage,name:"gray-chroma-control",mode:"srgbTag")
        let reader=i.rgb(try await i.sample(cache)),generator=h.bytes(try await i.managed(cache))
        try note("gray-reader8-vs-source",stats(reader,gray,width:960,height:540))
        try note("gray-generator16-vs-source",stats(generator,gray,width:960,height:540))
        try note("gray-generator-vs-reader8",stats(generator,reader,width:960,height:540))
        // Separate blending-space hypotheses at a flat 50% alpha patch. Neither
        // model is silently substituted into the full-image contract.
        let alpha=try h.decode(source.appendingPathComponent("alpha.png")),fg=h.bytes(alpha),videoURL=source.appendingPathComponent("ordinary-video.mov"),video=try await i.managed(videoURL),bg=h.bytes(video)
        let upper=ImageCacheFeasibilityTests.Layer(url:matrixRoot.appendingPathComponent("corrected-alpha.mov"),image:alpha,start:0,end:90),lower=ImageCacheFeasibilityTests.Layer(url:videoURL,image:video,start:0,end:90),plan=try await h.plan([upper,lower],frames:90,black:source.appendingPathComponent("black.mov"))
        let pb=try await i.sample(videoURL,plan:plan,frame:30),profile=CVBufferCopyAttachment(pb,kCVImageBufferCGColorSpaceKey,nil) as! CGColorSpace
        let sourceOffset=(250*960+150)*4,a=Double(fg[sourceOffset+3])/255
        let foreground=(0..<3).map { Double(fg[sourceOffset+$0])/255/a },background=(0..<3).map { Double(bg[sourceOffset+$0])/255 }
        func color(_ values:[Double],space:CGColorSpace)->CGColor {
            var components:[CGFloat]=values.map { CGFloat($0) }
            components.append(CGFloat(1))
            return CGColor(colorSpace:space,components:components)!
        }
        let foreground709=color(foreground,space:h.cs).converted(to:profile,intent:.relativeColorimetric,options:nil)!.components!,background709=color(background,space:h.cs).converted(to:profile,intent:.relativeColorimetric,options:nil)!.components!
        let blended709=(0..<3).map { Double(foreground709[$0])*a+Double(background709[$0])*(1-a) }
        let display709=color(blended709,space:profile).converted(to:h.cs,intent:.relativeColorimetric,options:nil)!.components!
        let encodedSRGB=(0..<3).map { Int(((foreground[$0]*a+background[$0]*(1-a))*255).rounded()) },encoded709=(0..<3).map { Int((display709[$0]*255).rounded()) }
        let preview=h.bytes(try await i.managed(videoURL,frame:30,plan:plan)),export=h.bytes(try await i.managed(matrixRoot.appendingPathComponent("alpha-plain.mp4"),frame:30)),offset=(500*1920+300)*4
        try note("alpha-flat-working-space-models",["point":[300,500],"alpha":a,"encodedSRGBBlend":encodedSRGB,"outputICCBlendThenSRGB":encoded709,"nativePreview":Array(preview[offset..<offset+3]).map(Int.init),"export":Array(export[offset..<offset+3]).map(Int.init),"outputProfile":String(describing:profile)])
    }

    func testAnalyticReferenceHandCalculations() throws {
        let url=root.appendingPathComponent("unused-reference-only")
        let opaque=imageFrom([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255],width:2,height:2)
        let layer=ImageCacheFeasibilityTests.Layer(url:url,image:opaque,start:0,end:1,rect:CGRect(x:0,y:0,width:4,height:4))
        let reference=analytic([layer],frame:0,nativeMask:false)
        func pixel(_ a:[UInt8],_ x:Int,_ y:Int)->[UInt8] { let k=(y*1920+x)*4;return Array(a[k..<k+4]) }
        XCTAssertEqual(pixel(reference,1,1),[159,64,64,255])
        XCTAssertEqual(pixel(reference,0,0),[255,0,0,255])
        XCTAssertEqual(pixel(reference,4,0),[0,0,0,255])
        let partiallyTransparent=imageFrom([128,0,0,128, 0,0,0,0, 0,0,0,0, 255,255,255,255],width:2,height:2)
        let alpha=ImageCacheFeasibilityTests.Layer(url:url,image:partiallyTransparent,start:0,end:1,rect:CGRect(x:0,y:0,width:4,height:4))
        let blue=imageFrom([0,0,255,255, 0,0,255,255, 0,0,255,255, 0,0,255,255],width:2,height:2)
        let lower=ImageCacheFeasibilityTests.Layer(url:url,image:blue,start:0,end:1,rect:CGRect(x:0,y:0,width:4,height:4))
        let over=analytic([alpha,lower],frame:0,nativeMask:false)
        XCTAssertEqual(pixel(over,1,1),[88,16,183,255])
        XCTAssertEqual(pixel(over,0,0),[128,0,127,255])
        var cropped=layer;cropped.rect.origin.x = -2
        XCTAssertEqual(pixel(analytic([cropped],frame:0,nativeMask:false),0,1),[96,191,64,255])
        try note("independent-hand-calculations",["opaqueBilinear":[159,64,64,255],"premultipliedSourceOver":[88,16,183,255],"clampedCorner":[128,0,127,255],"clippedSample":[96,191,64,255],"cropOffsetX":-2,"candidatePixelsUsed":false])
    }

}
