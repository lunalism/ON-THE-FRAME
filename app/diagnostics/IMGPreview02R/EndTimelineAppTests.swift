import AppKit
import AVFoundation
import XCTest
@testable import OnTheFrameEngine
@testable import OnTheFrameEngineTests

@main struct EndTimelineAppTests {
    struct Failure:Error{let message:String}
    static func check(_ value:@autoclosure ()throws->Bool,_ message:String)throws{if try !value(){throw Failure(message:message)}}
    static func record(_ root:URL,_ row:[String:Any])throws {
        let file=root.appendingPathComponent("surface.jsonl")
        if !FileManager.default.fileExists(atPath:file.path){FileManager.default.createFile(atPath:file.path,contents:Data())}
        let h=try FileHandle(forWritingTo:file);defer{try? h.close()};try h.seekToEnd();try h.write(contentsOf:JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])+Data([10]))
    }
    @MainActor static func frame(_ store:ProjectStore,_ view:PlayerNSView,_ item:AVPlayerItem,_ output:AVPlayerItemVideoOutput,_ n:Int,_ hash:String,_ root:URL)async throws {
        store.seek(to:n);let token=store.seekToken,g=store.generation
        try await ClockCarrierCompatibilityTests.wait(5){view.spectrumOverlay.confirmedFrame==n}
        var stamp=CMTime.invalid,pb:CVPixelBuffer?
        let requested=CMTime(value:Int64(n),timescale:30)
        try await ClockCarrierCompatibilityTests.wait(5){pb=output.copyPixelBuffer(forItemTime:requested,itemTimeForDisplay:&stamp);return pb != nil && CMTimeCompare(stamp,requested)==0}
        let raw=try QA01.sha(QA01.active(pb!))
        try check(raw==hash,"video-output strict raw frame \(n)")
        let initial=view.playerLayer.displayedPixelBuffer().flatMap{try? QA01.sha(QA01.active($0))}
        try await ClockCarrierCompatibilityTests.wait(5){
            guard let p=view.playerLayer.displayedPixelBuffer() else{return false}
            return (try? QA01.sha(QA01.active(p)))==hash
        }
        try check(store.player.currentItem === item && store.seekToken==token && store.generation==g && store.appliedGeneration==g,"surface generation/token unchanged")
        try check(try QA01.sha(QA01.active(view.playerLayer.displayedPixelBuffer()!))==hash,"exact displayed raw")
        try record(root,["event":"frame-PASS","frame":n,"expectedPTS":requested.seconds,"actualPTS":stamp.seconds,"expectedHash":hash,"actualHash":raw,"surfaceInitialHash":initial ?? "none","surfaceFinalHash":hash,"seekToken":token,"generation":g])
    }
    @MainActor final class Gate {
        var arrived=false,continuation:CheckedContinuation<Void,Never>?
        func wait()async{await withCheckedContinuation{continuation=$0;arrived=true}}
        func release(){continuation?.resume();continuation=nil}
    }
    @MainActor static func main()async {
        do {
            _ = NSApplication.shared
            try check(EditorLayout.shared.suiteName != nil && ProjectStore.imageImportEnabled,"isolated layout/internal gate")
            let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let mode=ProcessInfo.processInfo.environment["OTF_END_SURFACE_MODE"] ?? "product"
            let cases=mode=="video-only" ? ["video-only"]:(mode=="legacy-mixed" ? ["legacy-mixed"]:["image-only","mixed","short-mixed"])
            for label in cases {
                let dir=root.appendingPathComponent(label);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                let timeline:Timeline,media:[MediaAsset],planItem:AVPlayerItem,expected:[Int:String]
                if label=="short-mixed" || label=="legacy-mixed" {
                    let f=try await ClockCarrierCompatibilityTests.plan(source:URL(fileURLWithPath:ProcessInfo.processInfo.environment["OTF_CLOCK_SOURCE"]!),run:dir.appendingPathComponent("reference"),mixed:true)
                    timeline=f.timeline;media=f.media;planItem=f.item();expected=f.expected
                } else {
                    let f=try await EndTimelinePlaybackTests.fixture(root:dir.appendingPathComponent("reference"),mixed:label != "image-only")
                    media=f.media
                    if label=="video-only" {
                        timeline=Timeline(clips:f.timeline.clips.filter{!f.timeline.stillImageIDs.contains($0.mediaID)},subtitles:f.timeline.subtitles,lanes:f.timeline.lanes,media:f.timeline.media,mediaFrames:f.timeline.mediaFrames,mediaHasAudio:f.timeline.mediaHasAudio,mediaHasVideo:f.timeline.mediaHasVideo,durationFrames:150)
                        planItem=AVPlayerItem(url:media[0].url)
                        var hashes=[Int:String]()
                        for n in [0,1,2,3,75,145,148,149]{hashes[n]=QA01.sha(try QA01.active(await IBReference.read(AVURLAsset(url:media[0].url),frame:n%6,format:IBContract.format)))}
                        expected=hashes
                    } else {
                        timeline=f.timeline;planItem=AVPlayerItem(asset:f.plan.composition);planItem.videoComposition=f.plan.videoComposition;planItem.audioMix=f.plan.audioMix;expected=f.expected
                    }
                }
                let store=ProjectStore(),view=PlayerNSView(frame:NSRect(x:0,y:0,width:640,height:360)),window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:360),styleMask:[.titled],backing:.buffered,defer:false)
                window.contentView=view;window.orderFront(nil);view.playerLayer.player=store.player;store.previewHost=view
                defer{store.player.pause();store.player.replaceCurrentItem(with:nil);view.spectrumOverlay.detach();window.orderOut(nil)}
                store.installClockCompatibilityForTest(timeline:timeline,media:media,item:planItem)
                if label != "legacy-mixed" {store.timelineChanged();try await ClockCarrierCompatibilityTests.wait(5){store.currentPlan != nil && store.appliedGeneration==store.generation && store.player.currentItem !== planItem}}
                let item=store.player.currentItem!,output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);item.add(output);defer{item.remove(output)}
                let ends=IBLog(),observer=NotificationCenter.default.addObserver(forName:AVPlayerItem.didPlayToEndTimeNotification,object:item,queue:.main){_ in ends.add(["ns":DispatchTime.now().uptimeNanoseconds])};defer{NotificationCenter.default.removeObserver(observer)}
                ImagePreviewCompositor.trace.reset()
                try await ClockCarrierCompatibilityTests.wait(5){item.status != .unknown};try check(item.status == .readyToPlay,"item ready")
                print("checkpoint \(label) item ready, subtitles=\(timeline.renderedSubtitles.count)")
                try await ClockCarrierCompatibilityTests.wait(5){view.subtitleBoundItem === item}
                if label != "legacy-mixed" && label != "video-only" {try check(item.videoComposition?.customVideoCompositorClass === ImagePreviewCompositor.self,"actual product adapter")}
                let layers=view.layer!.sublayers!
                try check(layers.firstIndex(of:view.playerLayer)! < layers.firstIndex(of:view.spectrumCanvas)! && layers.firstIndex(of:view.spectrumCanvas)! < layers.firstIndex(of:view.subtitleHost)!,"native image/video < spectrum < subtitle")
                for n in expected.keys.sorted() where n<timeline.durationFrames {
                    try await frame(store,view,item,output,n,expected[n]!,dir)
                    if label=="short-mixed" && n>=1 && n<5 {try await ClockCarrierCompatibilityTests.wait(5){!view.spectrumOverlay.layers.isEmpty && view.spectrumOverlay.layers.values.allSatisfy{$0.contents != nil}}}
                }
                let old=store.seekToken;store.seek(to:0);store.seek(to:timeline.durationFrames-1);view.subtitleSeekFinished(token:old,frame:0,finished:true)
                try await ClockCarrierCompatibilityTests.wait(5){view.spectrumOverlay.confirmedFrame==timeline.durationFrames-1}
                try check(store.seekToken != old,"stale seek rejected")
                if label=="legacy-mixed" {
                    print("PASS legacy mixed exact surface/output identity");continue
                }
                for replay in 0..<2 {
                    if replay==0 {store.seek(to:0);try await ClockCarrierCompatibilityTests.wait(5){view.spectrumOverlay.confirmedFrame==0}}
                    let previous=ends.snapshot.count
                    store.play() // Second pass deliberately uses actual ProjectStore end-to-replay path.
                    try await ClockCarrierCompatibilityTests.wait(Double(timeline.durationFrames)/30+2){ends.snapshot.count==previous+1 && !store.isPlaying}
                    try check(CMTimeCompare(store.player.currentTime(),CMTime(value:Int64(timeline.durationFrames),timescale:30))==0,"exact normal endpoint")
                    try check(store.playhead==timeline.durationFrames && item.status == .readyToPlay,"store normal completion state")
                    let surface=try QA01.sha(QA01.active(try XCTUnwrap(view.playerLayer.displayedPixelBuffer())))
                    try check(surface==expected[timeline.durationFrames-1],"last visible frame held at end")
                    try record(dir,["event":"playback-end-PASS","replay":replay,"itemTime":store.player.currentTime().seconds,"endNotifications":ends.snapshot.count,"surfaceHash":surface,"expectedFinalHash":expected[timeline.durationFrames-1]!,"generation":store.generation,"seekToken":store.seekToken])
                }
                try await frame(store,view,item,output,0,expected[0]!,dir)
                try check(label=="video-only" || store.exportBlockReason != nil,"image export remains blocked")
                if label != "video-only" {
                    let gate=Gate(),before=store.imagePreviewStaleDropsForTest
                    store.imagePreviewPreparedForTest={_ in await gate.wait()};store.timelineChanged()
                    try await ClockCarrierCompatibilityTests.wait(5){gate.arrived}
                    store.resetProject();gate.release()
                    try await ClockCarrierCompatibilityTests.wait(5){store.imagePreviewStaleDropsForTest==before+1}
                    try check(store.timeline.isEmpty && store.player.currentItem==nil && store.currentPlan==nil,"obsolete prepared plan cannot publish after replacement")
                }
                try await ClockCarrierCompatibilityTests.wait(5){ImagePreviewCompositor.admission.outstanding==0 && ImagePreviewMetal.ownership.counts.active==0}
                try check(ImagePreviewMetal.ownership.counts.resources==0,"GPU wrappers drained")
                try record(dir,["event":"drain-PASS","active":ImagePreviewMetal.ownership.counts.active,"resources":ImagePreviewMetal.ownership.counts.resources,"pendingAndActive":ImagePreviewCompositor.admission.outstanding,"events":ImagePreviewCompositor.trace.snapshot])
                print("PASS \(label): strict real surface, normal end notification, replay, stale seek/session and drain")
            }
            print("END APP: \(cases.count) PASS, 0 FAIL, 0 SKIP");exit(0)
        } catch {print("END APP FAIL: \(error)");exit(1)}
    }
}
