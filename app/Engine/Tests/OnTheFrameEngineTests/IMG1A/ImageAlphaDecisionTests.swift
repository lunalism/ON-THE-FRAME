import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import CryptoKit
@testable import OnTheFrameEngine

/// IMG-1A-4: one fixed matrix, two alpha declarations, one restricted alternative.
final class ImageAlphaDecisionTests: XCTestCase {
    var h: ImageCacheFeasibilityTests!
    var i: ImageCacheInvestigationTests!
    var s: ImageSamplingContractTests!
    var root: URL!
    var source: URL!
    let w=1920,hgt=1080
    override func setUp() async throws {
        guard let run=ProcessInfo.processInfo.environment["OTF_IMG1A4_RUN"] else { throw XCTSkip("IMG-1A-4 opt-in") }
        guard let input=ProcessInfo.processInfo.environment["OTF_IMG1A4_SOURCE"] else { throw NSError(domain:"source-required",code:1) }
        source=URL(fileURLWithPath:input)
        let method=name.components(separatedBy:" ").last!.replacingOccurrences(of:"]",with:"")
        root=URL(fileURLWithPath:run).appendingPathComponent(method)
        guard !FileManager.default.fileExists(atPath:root.path) else { throw NSError(domain:"fresh-root",code:1) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        h=ImageCacheFeasibilityTests();h.root=root
        i=ImageCacheInvestigationTests();i.root=root;i.h=h;i.source=source
        s=ImageSamplingContractTests();s.root=root;s.h=h;s.i=i;s.source=source
    }
    var matrixRoot:URL {
        if let value=ProcessInfo.processInfo.environment["OTF_IMG1A4_MATRIX"] { return URL(fileURLWithPath:value) }
        return source.deletingLastPathComponent().appendingPathComponent("img1a4-20261028-01/testAlphaMatrixAndAlternative")
    }
    func note(_ name:String,_ fields:[String:Any]) throws { try s.note(name,fields) }
    func image(_ bytes:[UInt8])->CGImage { s.imageFrom(bytes,width:w,height:hgt) }
    func fixture(_ name:String)->[UInt8] {
        var bytes=[UInt8](repeating:0,count:w*hgt*4)
        for y in 0..<hgt { for x in 0..<w {
            let alpha:Int
            switch name {
            case "opaque":alpha=255
            case "transparent":alpha=0
            case "half":alpha=128
            case "gradient":alpha=Int((Double(x)*255/Double(w-1)).rounded())
            default:alpha=x<640 ? 0 : (x<1280 ? 128 : 255)
            }
            let k=(y*w+x)*4
            for (channel,value) in [204,51,26].enumerated() { bytes[k+channel]=UInt8((value*alpha+127)/255) }
            bytes[k+3]=UInt8(alpha)
        } };return bytes
    }
    func foregroundOver(_ fg:[UInt8],_ bg:[UInt8],linear:Bool=false)->[UInt8] {
        var out=[UInt8](repeating:255,count:fg.count)
        func toLinear(_ value:Double)->Double { value<=0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4) }
        func toEncoded(_ value:Double)->Double { value<=0.0031308 ? 12.92*value : 1.055*pow(value,1/2.4)-0.055 }
        for k in stride(from:0,to:fg.count,by:4) {
            let alpha=Double(fg[k+3])/255
            for c in 0..<3 {
                let value:Double
                if linear {
                    let straight=alpha>0 ? min(1,Double(fg[k+c])/255/alpha) : 0
                    value=toEncoded(toLinear(straight)*alpha+toLinear(Double(bg[k+c])/255)*(1-alpha))*255
                } else { value=Double(fg[k+c])+Double(bg[k+c])*(1-alpha) }
                out[k+c]=UInt8(max(0,min(255,value.rounded())))
            }
        };return out
    }
    func cgOver(_ fg:CGImage,_ bg:CGImage)->[UInt8] {
        let context=h.context(w,hgt);context.interpolationQuality = .none
        context.draw(bg,in:CGRect(x:0,y:0,width:w,height:hgt));context.draw(fg,in:CGRect(x:0,y:0,width:w,height:hgt))
        return h.bytes(context.makeImage()!)
    }
    func decoded(_ url:URL,plan:PlannedComposition?=nil) async throws -> (raw:[UInt8],managed:[UInt8],metadata:[String:Any]) {
        let pb=try await i.sample(url,plan:plan,frame:0),width=CVPixelBufferGetWidth(pb),height=CVPixelBufferGetHeight(pb),raw=i.rgb(pb)
        let profile:CGColorSpace
        let profileRule:String
        if let attached=CVBufferCopyAttachment(pb,kCVImageBufferCGColorSpaceKey,nil) {
            profile=attached as! CGColorSpace;profileRule="attached-CGColorSpace"
        } else if let attachments=CVBufferCopyAttachments(pb,.shouldPropagate),let synthesized=CVImageBufferCreateColorSpaceFromAttachments(attachments) {
            profile=synthesized.takeRetainedValue();profileRule="synthesized-from-primaries-transfer-matrix"
        } else { throw NSError(domain:"unknown-buffer-color-space",code:1) }
        let cg=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:profile,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(raw) as CFData)!,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric)!
        var metadata=i.pbInfo(pb);metadata["profileRule"]=profileRule;metadata["interpretedSpace"]=String(describing:profile)
        return (raw,h.bytes(cg),metadata)
    }
    func metric(_ name:String,_ actual:[UInt8],_ reference:[UInt8]) throws {
        try note(name+"-global",s.stats(actual,reference,width:w,height:hgt))
        for (label,rect) in [("left-flat",CGRect(x:100,y:200,width:300,height:500)),("middle-flat",CGRect(x:800,y:200,width:300,height:500)),("right-flat",CGRect(x:1500,y:200,width:300,height:500)),("edge-640",CGRect(x:635,y:0,width:12,height:1080)),("edge-1280",CGRect(x:1275,y:0,width:12,height:1080))] {
            try note(name+"-"+label,s.stats(actual,reference,width:w,height:hgt,rect:rect))
        }
    }
    func encodeMode(_ im:CGImage,name:String,straight:Bool) async throws -> URL {
        let url=root.appendingPathComponent(name+".mov"),writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.proRes4444,AVVideoWidthKey:w,AVVideoHeightKey:hgt,AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_IEC_sRGB,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]])
        writer.add(input)
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        guard writer.startWriting() else { throw writer.error ?? NSError(domain:"writer",code:1) };writer.startSession(atSourceTime:.zero)
        let pb=i.buffer(im,mode:"srgbTag")
        if straight {
            CVPixelBufferLockBaseAddress(pb,[])
            let base=CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<hgt { for x in 0..<w { let k=y*stride+x*4,a=Int(base[k+3]);if a>0 { for c in 0..<3 { base[k+c]=UInt8(min(255,(Int(base[k+c])*255+a/2)/a)) } } } }
            CVPixelBufferUnlockBaseAddress(pb,[])
        }
        CVBufferSetAttachment(pb,kCVImageBufferAlphaChannelModeKey,straight ? kCVImageBufferAlphaChannelMode_StraightAlpha : kCVImageBufferAlphaChannelMode_PremultipliedAlpha,.shouldPropagate)
        try note(name+"-declared-input",i.pbInfo(pb))
        for f in 0..<30 {
            var attempts=0;while !input.isReadyForMoreMediaData { if writer.status == .failed { throw writer.error ?? NSError(domain:"writer-failed",code:1) };try await Task.sleep(nanoseconds:1_000_000);attempts += 1;if attempts>5000 { writer.cancelWriting();throw NSError(domain:"writer-timeout",code:1) } }
            guard adaptor.append(pb,withPresentationTime:CMTime(value:Int64(f),timescale:30)) else { throw writer.error ?? NSError(domain:"append",code:1) }
        }
        input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:30,timescale:30));await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain:"writer-finish",code:1) };return url
    }
    func export(_ p:PlannedComposition,name:String) async throws -> URL {
        let url=root.appendingPathComponent(name+".mp4"),start=Date()
        let result=await ExportService.export(p,to:.init(url:url,confirmedReplace:false,identityAtConfirmation:nil),sources:[]) { _ in }
        try note(name+"-export",["outcome":String(describing:result),"seconds":Date().timeIntervalSince(start),"bytes":(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0])
        XCTAssertEqual(result,.completed(url));guard result == .completed(url) else { throw NSError(domain:"export-failed",code:1) };return url
    }
    func testAlphaMatrixAndAlternative() async throws {
        let videoURL=source.appendingPathComponent("ordinary-video.mov"),background=try await decoded(videoURL),rawWidth=960,rawHeight=540
        var bg=[UInt8](repeating:255,count:w*hgt*4)
        // Existing video is a uniform plate. Nearest expansion keeps this independent
        // from CG/native filter choice; transparent control measures residual video error.
        for y in 0..<hgt { for x in 0..<w { let src=((y*rawHeight/hgt)*rawWidth+x*rawWidth/w)*4,dst=(y*w+x)*4;for c in 0..<4 { bg[dst+c]=background.managed[src+c] } } }
        let bgImage=image(bg),videoSourceImage=s.imageFrom(background.managed,width:rawWidth,height:rawHeight)
        let lower=ImageCacheFeasibilityTests.Layer(url:videoURL,image:videoSourceImage,start:0,end:60)
        try note("background-decoded-intent",background.metadata)
        for name in ["opaque","transparent","half","gradient","edge"] {
            let bytes=fixture(name),fg=image(bytes),png=try h.saveImage(fg,name+".png"),roundtrip=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(png as CFURL,nil)!,0,nil)!
            try note(name+"-PNG-roundtrip",s.stats(h.bytes(roundtrip),bytes,width:w,height:hgt))
            try note(name+"-source",i.space(roundtrip))
            let ref=foregroundOver(bytes,bg),cg=cgOver(fg,bgImage)
            try metric(name+"-independent-vs-CG-before-codec",cg,ref)
            try note(name+"-linear-vs-encoded-reference",s.stats(foregroundOver(bytes,bg,linear:true),ref,width:w,height:hgt))
            let started=Date(),cache=try await i.encode(fg,name:"cache-"+name,mode:"srgbTag")
            try note(name+"-cache-resource",["seconds":Date().timeIntervalSince(started),"bytes":try cache.resourceValues(forKeys:[.fileSizeKey]).fileSize!])
            let cachePixels=try await decoded(cache);try note(name+"-cache-metadata",cachePixels.metadata)
            try metric(name+"-cache-RGBA-managed",cachePixels.managed,bytes)
            var alphaMax=0;for k in stride(from:3,to:bytes.count,by:4) { alphaMax=max(alphaMax,abs(Int(bytes[k])-Int(cachePixels.raw[k]))) }
            try note(name+"-cache-alpha",["max":alphaMax]);XCTAssertEqual(alphaMax,0)
            let upper=ImageCacheFeasibilityTests.Layer(url:cache,image:fg,start:0,end:60),layers=i.visible([upper,lower])
            XCTAssertEqual(layers.count,name=="opaque" ? 1 : 2)
            let p=try await h.plan(layers,frames:60,black:source.appendingPathComponent("black.mov")),native=try await decoded(videoURL,plan:p)
            try note(name+"-native-metadata",native.metadata)
            try metric(name+"-native-vs-source-reference",native.managed,ref)
            try metric(name+"-native-vs-decoded-source-over",native.managed,foregroundOver(cachePixels.managed,bg))
            let preview=h.bytes(try await i.managed(videoURL,frame:0,plan:p))
            try metric(name+"-generator-preview",preview,ref)
            let result=try await export(p,name:name),out=try await decoded(result)
            try metric(name+"-final-export",out.managed,ref)
            try metric(name+"-final-vs-native",out.managed,native.managed)
            if name=="half" {
                for straight in [false,true] {
                    let label=straight ? "explicit-straight" : "explicit-premultiplied"
                    do {
                        let alternate=try await encodeMode(fg,name:label,straight:straight),layer=ImageCacheFeasibilityTests.Layer(url:alternate,image:fg,start:0,end:60),plan=try await h.plan([layer,lower],frames:60,black:source.appendingPathComponent("black.mov"))
                        let pixels=try await decoded(alternate);try note(label+"-cache-metadata",pixels.metadata)
                        try metric(label+"-cache-managed",pixels.managed,bytes)
                        let composite=try await decoded(videoURL,plan:plan);try metric(label+"-native",composite.managed,ref)
                        let final=try await export(plan,name:label);try metric(label+"-final",try await decoded(final).managed,ref)
                    } catch { try note(label+"-unsupported-or-failed",["error":String(describing:error)]) }
                }
            }
            if ["half","gradient","edge"].contains(name) {
                // The one alternative is only valid with this exact known opaque background.
                let baked=image(ref),alternate=try await i.encode(baked,name:"precomposed-"+name,mode:"srgbTag"),layer=ImageCacheFeasibilityTests.Layer(url:alternate,image:baked,start:0,end:60),plan=try await h.plan([layer],frames:60,black:source.appendingPathComponent("black.mov"))
                let composite=try await decoded(alternate,plan:plan);try metric("precomposed-"+name+"-native",composite.managed,ref)
                let result=try await export(plan,name:"precomposed-"+name);try metric("precomposed-"+name+"-final",try await decoded(result).managed,ref)
            }
            if h.rss()>1_073_741_824 { throw NSError(domain:"RSS-budget",code:1) }
        }
    }
    func testNonfiniteSerializationRegression() throws {
        let payload:[String:Any]=["nan":Double.nan,"plus":Double.infinity,"minus":-Double.infinity,"float":Float.nan,"cg":CGFloat.infinity,"time":CMTime.invalid.seconds,"nested":[["value":NSNumber(value:Double.nan)],NSNull(),"literal",17]]
        XCTAssertFalse(JSONSerialization.isValidJSONObject(payload))
        let safe=s.jsonSafe(payload);XCTAssertTrue(JSONSerialization.isValidJSONObject(safe))
        let data=try JSONSerialization.data(withJSONObject:safe,options:[.sortedKeys]),decoded=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        for name in ["nan","plus","minus","float","cg","time"] { XCTAssertTrue((decoded[name] as? String)?.hasPrefix("nonfinite:")==true) }
        try note("nonfinite-regression",["sanitized":decoded,"JSONRoundTrip":true,"historicalSIGABRTPreserved":true])
    }
    func testEightBitSDRExtractionRelevance() async throws {
        let cache=source.deletingLastPathComponent().appendingPathComponent("img1a2-20261027-01/testColorStages/srgbTag.mov"),input=try h.decode(source.appendingPathComponent("png.png")),pixels=h.bytes(input)
        let reader=try await decoded(cache),generator=try await i.managed(cache)
        try note("SDR-source",i.space(input));try note("SDR-generator-representation",i.space(generator));try note("SDR-reader-representation",reader.metadata)
        try note("SDR-reader8-error",s.stats(reader.managed,pixels,width:960,height:540))
        try note("SDR-generator-error",s.stats(h.bytes(generator),pixels,width:960,height:540))
        let layer=ImageCacheFeasibilityTests.Layer(url:cache,image:input,start:0,end:60,rect:CGRect(x:0,y:0,width:960,height:540)),plan=try await h.plan([layer],frames:60,black:source.appendingPathComponent("black.mov")),native=try await decoded(cache,plan:plan)
        var crop=[UInt8](repeating:255,count:960*540*4)
        for y in 0..<540 { for x in 0..<960 { for c in 0..<4 { crop[(y*960+x)*4+c]=native.managed[(y*w+x)*4+c] } } }
        try note("SDR-native-identity-reader8-error",s.stats(crop,pixels,width:960,height:540))
        try note("scope",["HDRTested":false,"wideGamutPipelineDeveloped":false,"ownerVisibleUI":false])
    }
    func testReadOnlyFinalEvidence() async throws {
        let matrix=matrixRoot,videoURL=source.appendingPathComponent("ordinary-video.mov"),background=try await decoded(videoURL)
        var bg=[UInt8](repeating:255,count:w*hgt*4)
        for y in 0..<hgt { for x in 0..<w { let src=((y/2)*960+x/2)*4,dst=(y*w+x)*4;for c in 0..<4 { bg[dst+c]=background.managed[src+c] } } }
        let sourceBG=s.imageFrom(background.managed,width:960,height:540),lower=ImageCacheFeasibilityTests.Layer(url:videoURL,image:sourceBG,start:0,end:60),black=source.appendingPathComponent("black.mov")
        for name in ["opaque","transparent","half","gradient","edge"] {
            let bytes=fixture(name),fg=image(bytes),ref=foregroundOver(bytes,bg),cache=matrix.appendingPathComponent("cache-"+name+".mov"),upper=ImageCacheFeasibilityTests.Layer(url:cache,image:fg,start:0,end:60),plan=try await h.plan(i.visible([upper,lower]),frames:60,black:black)
            let before=cgOver(fg,image(bg));try metric(name+"-verified-CG-vs-independent",before,ref)
            let cachePixels=try await decoded(cache);try note(name+"-cache-profile",cachePixels.metadata)
            try metric(name+"-raw-code-vs-writer-premultiplied",cachePixels.raw,bytes)
            try metric(name+"-cache-managed-premultiplied-assumption",cachePixels.managed,bytes)
            let native=try await decoded(videoURL,plan:plan);try note(name+"-correct-native-profile",native.metadata)
            try metric(name+"-correct-native",native.managed,ref)
            try metric(name+"-correct-native-vs-decoded-source-over",native.managed,foregroundOver(cachePixels.managed,bg))
            let output=try await decoded(matrix.appendingPathComponent(name+".mp4"));try metric(name+"-correct-final",output.managed,ref);try metric(name+"-correct-final-vs-native",output.managed,native.managed)
            if name=="half" {
                for mode in ["explicit-premultiplied","explicit-straight"] {
                    let u=matrix.appendingPathComponent(mode+".mov"),layer=ImageCacheFeasibilityTests.Layer(url:u,image:fg,start:0,end:60),p=try await h.plan([layer,lower],frames:60,black:black),raw=try await decoded(u),n=try await decoded(videoURL,plan:p),final=try await decoded(matrix.appendingPathComponent(mode+".mp4"))
                    try note(mode+"-raw-cache-probe",["RGBA":Array(raw.raw[0..<4]).map(Int.init),"metadata":raw.metadata,"writerPremultipliedRGBA":Array(bytes[0..<4]).map(Int.init)])
                    try metric(mode+"-correct-native",n.managed,ref);try metric(mode+"-correct-final",final.managed,ref)
                }
            }
            if ["half","gradient","edge"].contains(name) {
                let u=matrix.appendingPathComponent("precomposed-"+name+".mov"),layer=ImageCacheFeasibilityTests.Layer(url:u,image:image(ref),start:0,end:60),p=try await h.plan([layer],frames:60,black:black),n=try await decoded(u,plan:p),final=try await decoded(matrix.appendingPathComponent("precomposed-"+name+".mp4"))
                try note("precomposed-"+name+"-correct-profile",n.metadata)
                try metric("precomposed-"+name+"-correct-native",n.managed,ref);try metric("precomposed-"+name+"-correct-final",final.managed,ref)
            }
        }
    }

    func testPointModelsAndColorAttachmentRegression() async throws {
        let matrix=matrixRoot,videoURL=source.appendingPathComponent("ordinary-video.mov"),background=try await decoded(videoURL)
        let bgImage=s.imageFrom(background.managed,width:960,height:540),lower=ImageCacheFeasibilityTests.Layer(url:videoURL,image:bgImage,start:0,end:60)
        let half=fixture("half"),fg=image(half),upper=ImageCacheFeasibilityTests.Layer(url:matrix.appendingPathComponent("cache-half.mov"),image:fg,start:0,end:60),p=try await h.plan([upper,lower],frames:60,black:source.appendingPathComponent("black.mov")),native=try await decoded(videoURL,plan:p)
        for (x,y) in [(100,100),(900,500)] {
            let sourceIndex=((y/2)*960+x/2)*4,k=(y*w+x)*4
            let foreground=Array(half[k..<k+4]),bg=Array(background.managed[sourceIndex..<sourceIndex+4]),encoded=foregroundOver(foreground,bg),linear=foregroundOver(foreground,bg,linear:true)
            try note("half-point-\(x)-\(y)",["foregroundPremultiplied":foreground.map(Int.init),"backgroundSRGB":bg.map(Int.init),"encodedSRGBSourceOver":encoded.map(Int.init),"linearLightSourceOver":linear.map(Int.init),"native":Array(native.managed[k..<k+4]).map(Int.init)])
        }
        let opaque=image(fixture("opaque")),layer=ImageCacheFeasibilityTests.Layer(url:matrix.appendingPathComponent("cache-opaque.mov"),image:opaque,start:0,end:60),plan=try await h.plan([layer],frames:60,black:source.appendingPathComponent("black.mov")),reader=try await decoded(videoURL,plan:plan),generator=h.bytes(try await i.managed(videoURL,frame:0,plan:plan))
        XCTAssertEqual(reader.metadata["profileRule"] as? String,"synthesized-from-primaries-transfer-matrix")
        let difference=s.stats(reader.managed,generator,width:w,height:hgt)
        try note("missing-CGColorSpace-synthesis-regression",["profileRule":reader.metadata["profileRule"]!,"comparisonToGenerator":difference])
        XCTAssertLessThanOrEqual(difference["max"] as! Int,1)
    }

}
