import XCTest
import AVFoundation
@testable import OnTheFrameEngine

final class EndTimelinePlaybackTests:XCTestCase {
    struct Fixture {
        let timeline:Timeline,media:[MediaAsset],plan:PlannedComposition,expected:[Int:String]
    }
    static func fixture(root:URL,mixed:Bool)async throws->Fixture {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let alphaURL=try ProductImagePreviewTests.solid(root,name:"alpha.png",color:[128,0,0,128])
        var t=Timeline(),media=[MediaAsset]()
        if mixed {
            let source=try XCTUnwrap(ProcessInfo.processInfo.environment["OTF_CLOCK_SOURCE"]),audio=try XCTUnwrap(ProcessInfo.processInfo.environment["OTF_CLOCK_AUDIO"])
            let v=try await MediaProbe.inspect(URL(fileURLWithPath:source).appendingPathComponent("bottom.mov")),a=try await MediaProbe.inspect(URL(fileURLWithPath:audio))
            XCTAssertEqual(v.frameCount,6);XCTAssertGreaterThanOrEqual(a.frameCount,60)
            media=[v,a];t=t.registering(v).registering(a)
            let video=(0..<25).map{Clip(mediaID:v.id,start:$0*6,sourceIn:0,length:6,lane:Lane.videoID)}
            let audioClips=(0..<3).map{Clip(mediaID:a.id,start:$0*60,sourceIn:0,length:min(60,150-$0*60),lane:Lane.audioID)}
            t=t.rebuilt(video:video,audio:audioClips,duration:150)
        } else {
            let blue=try ProductImagePreviewTests.solid(root,name:"blue.png",color:[0,0,255,255]),id=UUID()
            t=try t.registeringImage(await StillImageProjectModel.ValidatedImage.inspect(blue),id:id).placingImage(media:id,at:0,lane:Lane.videoID,length:150)
        }
        let upper=UUID(),id=UUID()
        t=try t.addingLane(.video,name:"alpha",id:upper,outward:true).registeringImage(await StillImageProjectModel.ValidatedImage.inspect(alphaURL),id:id).placingImage(media:id,at:1,lane:upper,length:148)
        let subtitle=UUID();t=try t.addingLane(.subtitle,name:"end",id:subtitle).addingSubtitle(lane:subtitle,at:148,length:2,text:"end")
        let plan=try await InternalImagePreview.plan(t,media:Dictionary(uniqueKeysWithValues:media.map{($0.id,$0)}),enabled:true)
        if mixed {
            let tracks=try await plan.composition.loadTracks(withMediaType:.audio)
            XCTAssertTrue(plan.hasAudio);XCTAssertNotNil(plan.audioMix);XCTAssertFalse(tracks.isEmpty)
            var spans=[[String:Any]]()
            for track in tracks {
                let range=try await track.load(.timeRange)
                XCTAssertEqual(CMTimeCompare(range.start,.zero),0)
                XCTAssertEqual(CMTimeCompare(range.end,CMTime(value:5,timescale:1)),0)
                spans.append(["trackID":track.trackID,"start":range.start.seconds,"end":range.end.seconds])
            }
            try JSONSerialization.data(withJSONObject:spans,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("native-audio-tracks.json"))
        }
        var expected=[Int:String](),bottoms=[Int:CVPixelBuffer]()
        let black=try ClockCarrierCompatibilityTests.black(),transfer=try IBTransfer(),cpu=IB420Compositor()
        for frame in [0,1,2,3,75,145,148,149] {
            let on=frame>=1 && frame<149,color:[UInt8]=mixed ? [128,0,0,128]:(on ? [128,0,127,255]:[0,0,255,255])
            var rgba=[UInt8](repeating:0,count:1920*1080*4)
            for k in 0..<1920*1080 {for c in 0..<4{rgba[k*4+c]=color[c]}}
            let bottom:CVPixelBuffer
            if mixed {
                if bottoms[frame%6]==nil {bottoms[frame%6]=try await IBReference.read(AVURLAsset(url:media[0].url),frame:frame%6,format:IBContract.format)}
                bottom=bottoms[frame%6]!
            } else {bottom=black}
            let output=try GMNV12.allocate(),instruction=IBInstruction(frame:mixed && !on ? 0:1,bottom:11,top:12,png:IBImage(rgba:rgba),transfer:transfer,log:IBLog())
            try cpu.render(bottom:bottom,top:nil,out:output,ins:instruction,deadline:Date().addingTimeInterval(10));IBContract.tag(output)
            expected[frame]=QA01.sha(try QA01.active(output))
        }
        return .init(timeline:t,media:media,plan:plan,expected:expected)
    }
    @MainActor static func exactOutput(_ player:AVPlayer,_ output:AVPlayerItemVideoOutput,frame:Int,expected:String)async throws->[String:Any] {
        try await ClockCarrierCompatibilityTests.seek(player,frame)
        let t=CMTime(value:Int64(frame),timescale:30);var pb:CVPixelBuffer?,shown=CMTime.invalid
        try await ClockCarrierCompatibilityTests.wait(5){pb=output.copyPixelBuffer(forItemTime:t,itemTimeForDisplay:&shown);return pb != nil && CMTimeCompare(shown,t)==0}
        let hash=QA01.sha(try QA01.active(XCTUnwrap(pb)))
        XCTAssertEqual(CMTimeCompare(shown,t),0);XCTAssertEqual(hash,expected)
        return ["frame":frame,"PTS":shown.seconds,"rawSHA256":hash,"expected":expected]
    }
    @MainActor func exercise(_ mixed:Bool)async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_END_TIMELINE_RUN"] else {throw XCTSkip("explicit end-of-timeline fixture opt-in")}
        let root=URL(fileURLWithPath:path).appendingPathComponent(mixed ? "mixed":"image-only")
        let f=try await Self.fixture(root:root,mixed:mixed)
        let item=AVPlayerItem(asset:f.plan.composition);item.videoComposition=f.plan.videoComposition;item.audioMix=f.plan.audioMix
        let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);item.add(output)
        let player=AVPlayer(playerItem:item);player.isMuted=true;player.actionAtItemEnd = .pause
        let ends=IBLog();var rows=[[String:Any]]();ImagePreviewCompositor.trace.reset()
        let observer=NotificationCenter.default.addObserver(forName:AVPlayerItem.didPlayToEndTimeNotification,object:item,queue:.main){_ in ends.add(["ns":DispatchTime.now().uptimeNanoseconds])}
        defer {
            let result:[String:Any]=["mixed":mixed,"duration":f.plan.composition.duration.seconds,"itemTime":player.currentTime().seconds,"itemStatus":item.status.rawValue,"endNotifications":ends.snapshot,"checks":rows,"events":ImagePreviewCompositor.trace.snapshot,"activeGPU":ImagePreviewMetal.ownership.counts.active,"heldResources":ImagePreviewMetal.ownership.counts.resources,"outstanding":ImagePreviewCompositor.admission.outstanding]
            try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("end-results.json"))
            NotificationCenter.default.removeObserver(observer);player.pause();item.remove(output);player.replaceCurrentItem(with:nil)
        }
        XCTAssertEqual(f.plan.durationFrames,150);XCTAssertEqual(CMTimeCompare(f.plan.composition.duration,CMTime(value:5,timescale:1)),0)
        try await ClockCarrierCompatibilityTests.wait(5){item.status != .unknown};XCTAssertEqual(item.status,.readyToPlay)
        for n in [149,148,145,0] {rows.append(try await Self.exactOutput(player,output,frame:n,expected:f.expected[n]!))}
        // Full 5-second playback, not just advancement through the old six-frame fixture.
        player.play();try await ClockCarrierCompatibilityTests.wait(7){ends.snapshot.count==1}
        XCTAssertEqual(CMTimeCompare(player.currentTime(),CMTime(value:5,timescale:1)),0)
        XCTAssertEqual(item.status,.readyToPlay)
        rows.append(["event":"full-playback-end","time":player.currentTime().seconds,"notificationCount":ends.snapshot.count])
        try await ClockCarrierCompatibilityTests.seek(player,150)
        XCTAssertEqual(CMTimeCompare(player.currentTime(),CMTime(value:5,timescale:1)),0)
        rows.append(try await Self.exactOutput(player,output,frame:149,expected:f.expected[149]!))
        rows.append(try await Self.exactOutput(player,output,frame:75,expected:f.expected[75]!))
        player.play();try await ClockCarrierCompatibilityTests.wait(2){player.currentTime().seconds>=76.0/30};player.pause()
        XCTAssertEqual(player.timeControlStatus,.paused)
        rows.append(["event":"pause","time":player.currentTime().seconds])
        rows.append(try await Self.exactOutput(player,output,frame:0,expected:f.expected[0]!))
        player.play();try await ClockCarrierCompatibilityTests.wait(7){ends.snapshot.count==2}
        XCTAssertEqual(CMTimeCompare(player.currentTime(),CMTime(value:5,timescale:1)),0)
        rows.append(["event":"replay-end","time":player.currentTime().seconds,"notificationCount":ends.snapshot.count])
        try await ClockCarrierCompatibilityTests.wait(5){ImagePreviewCompositor.admission.outstanding==0 && ImagePreviewMetal.ownership.counts.active==0}
        XCTAssertEqual(ImagePreviewMetal.ownership.counts.resources,0)
        XCTAssertTrue(ImagePreviewCompositor.trace.snapshot.contains{$0["event"] as? String=="end-boundary-cancelled"})
        XCTAssertFalse(ImagePreviewCompositor.trace.snapshot.contains{$0["event"] as? String=="error"})
        let dest=root.appendingPathComponent("export-must-not-exist.mp4")
        let result=await ExportService.export(f.plan,to:.init(url:dest,confirmedReplace:false,identityAtConfirmation:nil),sources:f.media,progress:{_ in})
        guard case .failed(.export)=result else {return XCTFail("preview exported")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:dest.path))
    }
    @MainActor func testImageOnlyEndAndReplay()async throws{try await exercise(false)}
    @MainActor func testMixedEndAndReplay()async throws{try await exercise(true)}
    func testExactBoundaryPolicy() {
        let end=CMTime(value:150,timescale:30),range=CMTimeRange(start:CMTime(value:149,timescale:30),end:end)
        XCTAssertEqual(ImagePreviewCompositor.disposition(time:range.start,range:range,projectEnd:end),.compose)
        XCTAssertEqual(ImagePreviewCompositor.disposition(time:end,range:range,projectEnd:end),.endBoundary)
        XCTAssertEqual(ImagePreviewCompositor.disposition(time:CMTime(value:5,timescale:1),range:range,projectEnd:end),.endBoundary)
        for t in [CMTime(value:-1,timescale:30),CMTime(value:151,timescale:30),CMTime.invalid] {XCTAssertEqual(ImagePreviewCompositor.disposition(time:t,range:range,projectEnd:end),.invalid)}
        let inner=CMTimeRange(start:.zero,duration:CMTime(value:1,timescale:30))
        XCTAssertEqual(ImagePreviewCompositor.disposition(time:inner.end,range:inner,projectEnd:end),.invalid)
    }
}
