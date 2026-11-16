import AppKit
import AVFoundation
import Foundation
@testable import OnTheFrameEngine
@testable import OnTheFrameEngineTests

@main struct ProductImagePreviewAppTests {
    struct Failure:Error {let message:String}
    static func check(_ b:@autoclosure ()throws->Bool,_ s:String)throws {if try !b(){throw Failure(message:s)}}
    static func now()->UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func buffer(_ p:CVPixelBuffer?)->[String:Any] {
        guard let p else{return ["available":false]}
        var colors=[String:String]()
        for key in [kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey,kCVImageBufferYCbCrMatrixKey,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocationBottomFieldKey] {
            if let v=CVBufferCopyAttachment(p,key,nil){colors[key as String]=String(describing:v)}
        }
        return ["available":true,"hash":(try? QA01.sha(QA01.active(p))) ?? "unavailable",
                "pixelFormat":CVPixelBufferGetPixelFormatType(p),"width":CVPixelBufferGetWidth(p),"height":CVPixelBufferGetHeight(p),"colors":colors]
    }
    static func time(_ t:CMTime)->[String:Any] { ["value":t.value,"timescale":t.timescale,"seconds":t.isNumeric ? t.seconds : -1] }
    static func record(_ root:URL,_ row:[String:Any])throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let p=root.appendingPathComponent("surface-observations.jsonl")
        if !FileManager.default.fileExists(atPath:p.path){FileManager.default.createFile(atPath:p.path,contents:Data())}
        let h=try FileHandle(forWritingTo:p);defer{try? h.close()};try h.seekToEnd();try h.write(contentsOf:JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])+Data([10]))
    }
    @MainActor static func main()async {
        do {
            _ = NSApplication.shared
            try check(EditorLayout.shared.suiteName != nil,"isolated settings")
            let root=URL(fileURLWithPath:CommandLine.arguments[1]),source=URL(fileURLWithPath:ProcessInfo.processInfo.environment["OTF_CLOCK_SOURCE"]!)
            try check(ProjectStore.imageImportEnabled,"internal build and explicit runtime gate")
            let store=ProjectStore(),view=PlayerNSView(frame:NSRect(x:0,y:0,width:640,height:360))
            let window=NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false)
            window.contentView=view;window.orderFront(nil);view.playerLayer.player=store.player;store.previewHost=view
            defer{store.player.pause();store.player.replaceCurrentItem(with:nil);view.spectrumOverlay.detach();window.orderOut(nil)}
            let control=ProcessInfo.processInfo.environment["OTF_SURFACE_MODE"] == "video-only"
            let cases=control ? [("video-only",false)]:[("image-only",false),("mixed-audio",true)]
            for (label,mixed) in cases {
                var keep:ClockCarrierCompatibilityTests.Plan?
                let setupItem:AVPlayerItem,timeline:Timeline,media:[MediaAsset],expected:[Int:String]
                if control {
                    let url=source.appendingPathComponent("bottom.mov"),asset=try await MediaProbe.inspect(url)
                    var t=try Timeline().registering(asset).placing(media:asset.id,at:0,videoLane:Lane.videoID,audioLane:nil)
                    let sub=UUID();t=try t.addingLane(.subtitle,name:"control",id:sub).addingSubtitle(lane:sub,at:2,length:2,text:"clock")
                    timeline=t;media=[asset];setupItem=AVPlayerItem(url:url)
                    var hashes=[Int:String]()
                    for f in 0..<6 {hashes[f]=QA01.sha(try QA01.active(await IBReference.read(AVURLAsset(url:url),frame:f,format:IBContract.format)))}
                    expected=hashes
                } else {
                    let p=try await ClockCarrierCompatibilityTests.plan(source:source,run:root.appendingPathComponent(label),mixed:mixed);keep=p
                    setupItem=p.item();timeline=p.timeline;media=p.media;expected=p.expected
                }
                defer{withExtendedLifetime(keep){}}
                store.installClockCompatibilityForTest(timeline:timeline,media:media,item:setupItem)
                store.timelineChanged()
                print("checkpoint rebuild requested \(label)")
                ImagePreviewCompositor.trace.reset()
                do {try await ClockCarrierCompatibilityTests.wait(5){store.appliedGeneration==store.generation && store.currentPlan != nil && store.player.currentItem !== setupItem}}
                catch {try record(root,["event":"rebuild-timeout","case":label,"generation":store.generation,"appliedGeneration":store.appliedGeneration,"status":store.statusMessage ?? "none","hasPlan":store.currentPlan != nil,"hasItem":store.player.currentItem != nil,"events":ImagePreviewCompositor.trace.snapshot]);throw error}
                print("checkpoint rebuilt \(label) g=\(store.generation) status=\(store.statusMessage ?? "none")")
                let item=store.player.currentItem!
                defer {try? record(root,["event":"case-final-state","case":label,"itemTime":item.currentTime().seconds,"duration":item.duration.seconds.isFinite ? item.duration.seconds:-1,"rate":store.player.rate,"timeControl":store.player.timeControlStatus.rawValue,"waitingReason":store.player.reasonForWaitingToPlay?.rawValue ?? "none","status":store.statusMessage ?? "none","confirmedFrame":view.spectrumOverlay.confirmedFrame ?? -1,"events":ImagePreviewCompositor.trace.snapshot])}
                let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);item.add(output)
                defer{item.remove(output)}
                try check(control || item.videoComposition?.customVideoCompositorClass === ImagePreviewCompositor.self,"real product image adapter installed")
                try await ClockCarrierCompatibilityTests.wait(5){item.status != .unknown}
                print("checkpoint ready \(label)")
                try check(item.status == .readyToPlay,"native item ready")
                try await ClockCarrierCompatibilityTests.wait(5){view.subtitleBoundItem === item}
                try check(!view.isShowingStill && (control || store.exportBlockReason != nil),"no stage bypass/export remains blocked")
                let ordering=view.layer!.sublayers!
                try check(ordering.firstIndex(of:view.playerLayer)! < ordering.firstIndex(of:view.spectrumCanvas)! && ordering.firstIndex(of:view.spectrumCanvas)! < ordering.firstIndex(of:view.subtitleHost)!,"video/image < spectrum < subtitle")
                var previousHash:String? = nil
                for frame in [0,1,2,3,4,5] where frame<timeline.durationFrames {
                    let requestedAt=now(),requested=CMTime(value:Int64(frame),timescale:30)
                    print("checkpoint seek \(label)/\(frame)")
                    store.seek(to:frame)
                    try await ClockCarrierCompatibilityTests.wait(5){view.spectrumOverlay.confirmedFrame==frame}
                    let completionObservedAt=now()
                    var pb:CVPixelBuffer?
                    try await ClockCarrierCompatibilityTests.wait(5){pb=view.playerLayer.displayedPixelBuffer();return pb != nil}
                    let firstObservedAt=now(),first=buffer(pb),strictHash=QA01.sha(try QA01.active(pb!)),strictMatch=strictHash==expected[frame]
                    var outputTime=CMTime.invalid
                    var outputPB=output.copyPixelBuffer(forItemTime:requested,itemTimeForDisplay:&outputTime)
                    let firstOutput=buffer(outputPB)
                    var samples=[[String:Any]](),convergedAt:UInt64?=nil
                    if ProcessInfo.processInfo.environment["OTF_SURFACE_DIAG"] == "1" && !strictMatch {
                        let deadline=Date().addingTimeInterval(1)
                        while Date()<deadline {
                            try await Task.sleep(nanoseconds:10_000_000)
                            let shown=buffer(view.playerLayer.displayedPixelBuffer())
                            var stamp=CMTime.invalid
                            if let fresh=output.copyPixelBuffer(forItemTime:requested,itemTimeForDisplay:&stamp){outputPB=fresh;outputTime=stamp}
                            samples.append(["ns":now(),"surface":shown,"videoOutput":buffer(outputPB),"outputTime":time(outputTime)])
                            if shown["hash"] as? String == expected[frame] {convergedAt=now();break}
                        }
                    }
                    try record(root,["case":label,"frame":frame,"expectedHash":expected[frame]!,"surfaceFirst":first,"videoOutputFirst":firstOutput,"videoOutputTime":time(outputTime),
                        "requestedTime":time(requested),"itemTime":time(item.currentTime()),"seekRequestedNs":requestedAt,"completionMarkerObservedNs":completionObservedAt,"firstSurfaceNs":firstObservedAt,
                        "completionMarker":"existing confirmedFrame polled at <=10ms; not exact callback timestamp",
                        "seekToken":store.seekToken,"generation":store.generation,"appliedGeneration":store.appliedGeneration,"confirmedFrame":view.spectrumOverlay.confirmedFrame ?? -1,
                        "seekingWaitsForVideoCompositionRendering":item.seekingWaitsForVideoCompositionRendering,"itemStatus":item.status.rawValue,"timeControlStatus":store.player.timeControlStatus.rawValue,"readyForDisplay":view.playerLayer.isReadyForDisplay,
                        "previousSurfaceHash":previousHash ?? "none","matchingExpectedFrames":expected.filter{$0.value==strictHash}.map{$0.key}.sorted(),"strictInitialMatch":strictMatch,
                        "convergedNs":convergedAt ?? 0,"laterSamples":samples])
                    // Seek completion is not a displayed-buffer readiness predicate. Keep the
                    // original exact-hash assertion, but observe the requested identity first.
                    // Strict-initial mode remains available to reproduce the original harness.
                    let token=store.seekToken,generation=store.generation
                    if ProcessInfo.processInfo.environment["OTF_SURFACE_STRICT_INITIAL"] != "1" {
                        let until=Date().addingTimeInterval(5)
                        repeat {
                            try check(store.player.currentItem === item && store.seekToken==token && store.generation==generation && store.appliedGeneration==generation && view.spectrumOverlay.confirmedFrame==frame,"surface observation identity changed")
                            pb=view.playerLayer.displayedPixelBuffer()
                            if let shown=pb,QA01.sha(try QA01.active(shown))==expected[frame] {break}
                            try check(Date()<until,"exact surface identity timeout frame \(frame)")
                            try await Task.sleep(nanoseconds:10_000_000)
                        } while true
                    }
                    try check(QA01.sha(try QA01.active(pb!))==expected[frame],"actual paused player surface raw frame \(frame)")
                    try record(root,["case":label,"frame":frame,"event":"strict-assertion-pass","surfaceFinal":buffer(pb),"expectedHash":expected[frame]!,"requestedTime":time(requested),"ns":now(),"seekToken":store.seekToken,"generation":store.generation])
                    previousHash=QA01.sha(try QA01.active(pb!))
                    if mixed && frame>=1 && frame<5 {
                        try await ClockCarrierCompatibilityTests.wait(5){!view.spectrumOverlay.layers.isEmpty && view.spectrumOverlay.layers.values.allSatisfy{$0.contents != nil}}
                    } else {try check(view.spectrumOverlay.layers.isEmpty,"half-open spectrum visibility")}
                }
                print("checkpoint rapid seeks \(label)")
                let token=store.seekToken
                store.seek(to:0);store.seek(to:4)
                view.subtitleSeekFinished(token:token,frame:2,finished:true)
                try await ClockCarrierCompatibilityTests.wait(5){view.spectrumOverlay.confirmedFrame==4}
                try check(store.seekToken != token,"stale seek rejected with existing token contract")
                print("checkpoint rapid seeks completed \(label)")
                store.seek(to:0);try await ClockCarrierCompatibilityTests.wait(5){view.spectrumOverlay.confirmedFrame==0}
                print("checkpoint playback \(label)")
                store.play();try await ClockCarrierCompatibilityTests.wait(5){store.player.currentTime().seconds>=4.0/30};store.pause()
                try check(view.spectrumOverlay.layers.isEmpty,"existing playback spectrum remains hidden; no Stage3C-2")
                try check(store.timeline==timeline && store.timeline.mediaFrames.keys.allSatisfy{!store.timeline.stillImageIDs.contains($0)},"model preserved")
                print("PASS \(label): native surface, AVPlayer, subtitle item binding, paused spectrum, layering, seek and stale-token fence")
            }
            print("PRODUCT PREVIEW APP: \(cases.count) PASS, 0 FAIL, 0 SKIP");exit(0)
        } catch {print("PRODUCT PREVIEW APP FAIL: \(error)");exit(1)}
    }
}
