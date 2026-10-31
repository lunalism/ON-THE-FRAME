import XCTest
import AVFoundation
import ImageIO
@testable import OnTheFrameEngine

final class ProductImagePreviewTests:XCTestCase {
    @MainActor func testFrozenReferenceThroughProductPlanner() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_PRODUCT_IMAGE_PREVIEW_RUN"],let source=ProcessInfo.processInfo.environment["OTF_CLOCK_SOURCE"] else{throw XCTSkip("explicit disposable product preview opt-in")}
        let root=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var results=[[String:Any]]();ImagePreviewCompositor.trace.reset()
        for mixed in [false,true] {
            let name=mixed ? "mixed":"image-only"
            let reference=try await ClockCarrierCompatibilityTests.plan(source:URL(fileURLWithPath:source),run:root.appendingPathComponent(name),mixed:mixed)
            let media=Dictionary(uniqueKeysWithValues:reference.media.map{($0.id,$0)})
            do {_ = try await InternalImagePreview.plan(reference.timeline,media:media,enabled:false);XCTFail("disabled gate admitted images")}catch{}
            let plan=try await InternalImagePreview.plan(reference.timeline,media:media,enabled:true)
            let item=AVPlayerItem(asset:plan.composition);item.videoComposition=plan.videoComposition;item.audioMix=plan.audioMix
            let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);item.add(output)
            let player=AVPlayer(playerItem:item);player.isMuted=true
            defer{player.pause();item.cancelPendingSeeks();item.remove(output);player.replaceCurrentItem(with:nil)}
            try await ClockCarrierCompatibilityTests.wait(5){item.status != .unknown}
            guard item.status == .readyToPlay else {throw item.error ?? IBContract.error("product item failed")}
            XCTAssertEqual(CMTimeCompare(plan.composition.duration,CMTime(value:Int64(reference.timeline.durationFrames),timescale:30)),0)
            for frame in [0,5,1,4,2,3] where frame<reference.timeline.durationFrames {
                try await ClockCarrierCompatibilityTests.seek(player,frame)
                let time=CMTime(value:Int64(frame),timescale:30);var pb:CVPixelBuffer?,shown=CMTime.invalid
                do {try await ClockCarrierCompatibilityTests.wait(5){pb=output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&shown);return pb != nil && CMTimeCompare(shown,time)==0}}
                catch {
                    results.append(["case":name,"frame":frame,"failure":String(describing:error),"lastShownPTS":shown.seconds.isFinite ? shown.seconds:-1,"itemTime":player.currentTime().seconds,"duration":plan.composition.duration.seconds,"timeControl":player.timeControlStatus.rawValue,"itemStatus":item.status.rawValue,"events":ImagePreviewCompositor.trace.snapshot])
                    try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("observations.json"));throw error
                }
                let actual=try QA01.sha(QA01.active(XCTUnwrap(pb))),expected=try XCTUnwrap(reference.expected[frame])
                results.append(["case":name,"frame":frame,"shownPTS":shown.seconds,"hash":actual,"expected":expected]);try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("observations.json"))
                XCTAssertEqual(CMTimeCompare(shown,time),0);XCTAssertEqual(actual,expected,"original frozen CPU raw parity \(name)/\(frame)")
            }
        }
    }
    static func solid(_ root:URL,name:String,color:[UInt8],orientation:Int=1) throws -> URL {
        let width=64,height=orientation==6 ? 32:36
        var pixels=[UInt8](repeating:0,count:width*height*4)
        for y in 0..<height {for x in 0..<width {let c=orientation==6 && x>=width/2 ? [UInt8(0),200,0,255]:color;for k in 0..<4{pixels[(y*width+x)*4+k]=c[k]}}}
        let image=try IBReference.image(pixels,width:width,height:height)
        let url=root.appendingPathComponent(name)
        let dest=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,(name.hasSuffix("jpg") ? "public.jpeg":"public.png") as CFString,1,nil))
        CGImageDestinationAddImage(dest,image,[kCGImagePropertyOrientation:orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest));return url
    }
    @MainActor func testAdmissionAlphaJPEGOrientationDurationAndMissing() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_PRODUCT_IMAGE_PREVIEW_RUN"] else{throw XCTSkip("explicit disposable product preview opt-in")}
        ImagePreviewCompositor.trace.reset()
        let root=URL(fileURLWithPath:path).appendingPathComponent("matrix");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let bottom=try Self.solid(root,name:"blue.png",color:[0,0,255,255]),top=try Self.solid(root,name:"alpha.png",color:[128,0,0,128]),jpeg=try Self.solid(root,name:"oriented.jpg",color:[200,0,0,255],orientation:6)
        var timeline=Timeline();let b=UUID(),a=UUID(),upper=UUID()
        timeline=try timeline.registeringImage(await StillImageProjectModel.ValidatedImage.inspect(bottom),id:b).placingImage(media:b,at:0,lane:Lane.videoID,length:150)
        timeline=try timeline.addingLane(.video,name:"alpha",id:upper,outward:true).registeringImage(await StillImageProjectModel.ValidatedImage.inspect(top),id:a).placingImage(media:a,at:1,lane:upper,length:148)
        let plan=try await InternalImagePreview.plan(timeline,media:[:],enabled:true)
        XCTAssertEqual(plan.durationFrames,150);XCTAssertEqual(plan.composition.duration.seconds,5,accuracy:0.000001)
        XCTAssertTrue(timeline.mediaFrames.isEmpty);XCTAssertTrue(timeline.audioClips.isEmpty)
        let destination=root.appendingPathComponent("must-not-export.mp4"),sentinel=Data("disposable sentinel".utf8);try sentinel.write(to:destination)
        let outcome=await ExportService.export(plan,to:.init(url:destination,confirmedReplace:true,identityAtConfirmation:FileIdentity.of(destination)),sources:[],progress:{_ in})
        guard case .failed(.export)=outcome else {return XCTFail("direct preview-plan export admitted")}
        XCTAssertEqual(try Data(contentsOf:destination),sentinel)
        let item=AVPlayerItem(asset:plan.composition);item.videoComposition=plan.videoComposition
        let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);item.add(output)
        let player=AVPlayer(playerItem:item);player.isMuted=true;player.actionAtItemEnd = .pause
        let endEvents=IBLog()
        let endObserver=NotificationCenter.default.addObserver(forName:AVPlayerItem.didPlayToEndTimeNotification,object:item,queue:.main){_ in endEvents.add(["event":"didPlayToEnd","ns":DispatchTime.now().uptimeNanoseconds])}
        var sourceDurations=[[String:Any]]()
        for asset in plan.assets {for track in try await asset.loadTracks(withMediaType:.video){let range=try await track.load(.timeRange);sourceDurations.append(["duration":range.duration.seconds,"size":String(describing:try await track.load(.naturalSize))])}}
        let carrierInstruction=try XCTUnwrap(plan.videoComposition.instructions.last as? ImagePreviewInstruction)
        let carrierDuration=try XCTUnwrap(plan.composition.track(withTrackID:carrierInstruction.carrier)).timeRange.duration.seconds
        var lastDisplayed:[String:Any]=[:]
        defer{
            let row:[String:Any]=["status":item.status.rawValue,"error":item.error.map{String(describing:$0)} ?? "none","itemTime":player.currentTime().seconds,"duration":plan.composition.duration.seconds,"rate":player.rate,"timeControl":player.timeControlStatus.rawValue,"waitingReason":player.reasonForWaitingToPlay?.rawValue ?? "none","events":ImagePreviewCompositor.trace.snapshot,"endEvents":endEvents.snapshot,"sourceTracks":sourceDurations,"carrierDuration":carrierDuration,"lastOutput":lastDisplayed]
            NotificationCenter.default.removeObserver(endObserver)
            try? JSONSerialization.data(withJSONObject:row,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("lifecycle.json"))
            player.pause();item.remove(output);player.replaceCurrentItem(with:nil)
        }
        try await ClockCarrierCompatibilityTests.wait(5){item.status != .unknown};XCTAssertEqual(item.status,.readyToPlay)
        var qa=[[String:Any]]()
        for frame in [0,6,75,148,149,1] {
            try await ClockCarrierCompatibilityTests.seek(player,frame)
            let time=CMTime(value:Int64(frame),timescale:30);var pb:CVPixelBuffer?,shown=CMTime.invalid
            do {try await ClockCarrierCompatibilityTests.wait(5){pb=output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&shown);return pb != nil && CMTimeCompare(shown,time)==0}}
            catch {
                let row:[String:Any]=["frame":frame,"requested":time.seconds,"lastPTS":shown.seconds.isFinite ? shown.seconds:-1,"itemTime":player.currentTime().seconds,"duration":plan.composition.duration.seconds,"events":ImagePreviewCompositor.trace.snapshot]
                try JSONSerialization.data(withJSONObject:row,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("first-failure.json"));throw error
            }
            lastDisplayed=["frame":frame,"PTS":shown.seconds,"rawSHA256":try QA01.sha(QA01.active(XCTUnwrap(pb)))]
            if frame==75 {
                let rgba=try IBCanonicalNV12.bytes(XCTUnwrap(pb)),pixel:[UInt8]=[128,0,127,255]
                var reference=[UInt8](repeating:0,count:1920*1080*4)
                for i in 0..<1920*1080 {for c in 0..<4{reference[i*4+c]=pixel[c]}}
                let stats=try IBReference.stats(rgba,reference);qa.append(stats)
                XCTAssertGreaterThanOrEqual(stats["psnr"] as? Double ?? 0,40);XCTAssertLessThanOrEqual(stats["flatMaximum"] as? Int ?? 255,3)
            }
        }
        try JSONSerialization.data(withJSONObject:qa,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("quality-before-play.json"))
        try await ClockCarrierCompatibilityTests.seek(player,145);player.play()
        try await ClockCarrierCompatibilityTests.wait(5){player.currentTime().seconds>=149.0/30};player.pause()
        XCTAssertEqual(item.status,.readyToPlay)
        let data=try ProjectPersistence.encode(ProjectPersistence.make(timeline:timeline,projectID:UUID()),at:root.appendingPathComponent("project.ontheframe"))
        let restored=try ProjectPersistence.decode(data).timeline
        do {_ = try await InternalImagePreview.plan(restored,media:[:],enabled:true);XCTFail("persisted unverified descriptor authorized decode")}catch{}
        _ = try await InternalImagePreview.plan(restored,media:[:],enabled:true,resolvedImages:[b:bottom,a:top])
        try FileManager.default.moveItem(at:top,to:root.appendingPathComponent("temporarily-missing.png"))
        do {_ = try await InternalImagePreview.plan(timeline,media:[:],enabled:true);XCTFail("missing current image source admitted")}catch{}
        XCTAssertEqual(timeline.clips.count,2)
        let proof=try await StillImageProjectModel.ValidatedImage.inspect(jpeg),jid=UUID()
        XCTAssertEqual(proof.descriptor.displayWidth,32);XCTAssertEqual(proof.descriptor.displayHeight,64)
        let jt=try Timeline().registeringImage(proof,id:jid).placingImage(media:jid,at:0,lane:Lane.videoID,length:150)
        let jp=try await InternalImagePreview.plan(jt,media:[:],enabled:true)
        let ji=AVPlayerItem(asset:jp.composition);ji.videoComposition=jp.videoComposition;let jo=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);ji.add(jo)
        let jplayer=AVPlayer(playerItem:ji);jplayer.isMuted=true;defer{jplayer.pause();ji.remove(jo);jplayer.replaceCurrentItem(with:nil)}
        try await ClockCarrierCompatibilityTests.wait(5){ji.status != .unknown};XCTAssertEqual(ji.status,.readyToPlay)
        try await ClockCarrierCompatibilityTests.seek(jplayer,0)
        var image:CVPixelBuffer?;try await ClockCarrierCompatibilityTests.wait(5){image=jo.copyPixelBuffer(forItemTime:.zero,itemTimeForDisplay:nil);return image != nil}
        let rgb=try IBCanonicalNV12.bytes(XCTUnwrap(image))
        func pixel(_ x:Int,_ y:Int)->[UInt8]{Array(rgb[(y*1920+x)*4..<(y*1920+x)*4+3])}
        XCTAssertLessThanOrEqual(pixel(100,100).max() ?? 255,3,"portrait side bars")
        XCTAssertGreaterThan(pixel(960,100)[0],180,"EXIF6 left source half becomes top")
        XCTAssertGreaterThan(pixel(960,980)[1],180,"EXIF6 right source half becomes bottom")
        qa.append(["orientation":6,"displaySize":[32,64],"top":pixel(960,100),"bottom":pixel(960,980)])
        try JSONSerialization.data(withJSONObject:qa,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("quality.json"))
        try await ClockCarrierCompatibilityTests.wait(5){ImagePreviewCompositor.admission.outstanding==0 && ImagePreviewMetal.ownership.counts.active==0}
        XCTAssertEqual(ImagePreviewMetal.ownership.counts.resources,0)
    }

}
