import XCTest
import AVFoundation
import Metal
import CoreGraphics
@testable import OnTheFrameEngine

/// Compatibility probe only: six REAL carrier samples; carrier is never a model media reference.
final class ClockCarrierInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing=false, containsTweening=false
    let passthroughTrackID=kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs:[NSValue]?
    let carrier:CMPersistentTrackID, bottom:CMPersistentTrackID?, top:CMPersistentTrackID?
    let frame:Int, phase:Int, gpu:GMNV12, black:CVPixelBuffer, log:IBLog
    init(frame:Int,phase:Int,carrier:CMPersistentTrackID,bottom:CMPersistentTrackID?,top:CMPersistentTrackID?,gpu:GMNV12,black:CVPixelBuffer,log:IBLog) {
        self.frame=frame;self.phase=phase;self.carrier=carrier;self.bottom=bottom;self.top=top;self.gpu=gpu;self.black=black;self.log=log
        timeRange=CMTimeRange(start:CMTime(value:Int64(frame),timescale:30),duration:CMTime(value:1,timescale:30))
        requiredSourceTrackIDs=([carrier]+[bottom,top].compactMap{$0}).map{NSNumber(value:$0)}
    }
}
final class ClockCarrierCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes:[String:any Sendable]?=[kCVPixelBufferPixelFormatTypeKey as String:[IBContract.format]]
    let requiredPixelBufferAttributesForRenderContext:[String:any Sendable]=[kCVPixelBufferPixelFormatTypeKey as String:[IBContract.format],kCVPixelBufferIOSurfacePropertiesKey as String:[String:Int]()]
    private let queue=DispatchQueue(label:"dev.ontheframe.clock-carrier.compat")
    private let lock=NSLock()
    private var epoch=0,outstanding=0
    func renderContextChanged(_ c:AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {lock.lock();epoch+=1;lock.unlock()}
    private struct Box:@unchecked Sendable {let request:AVAsynchronousVideoCompositionRequest}
    func startRequest(_ request:AVAsynchronousVideoCompositionRequest) {
        lock.lock();let generation=epoch
        guard outstanding<5 else {lock.unlock();request.finishCancelledRequest();return}
        outstanding+=1;lock.unlock()
        let box=Box(request:request)
        queue.async { [self] in
            defer {lock.lock();outstanding-=1;lock.unlock()}
            func current()->Bool {lock.lock();defer{lock.unlock()};return generation==epoch}
            guard current() else {box.request.finishCancelledRequest();return}
            do {
                guard let i=box.request.videoCompositionInstruction as? ClockCarrierInstruction,
                      CMTimeCompare(box.request.compositionTime,CMTime(value:Int64(i.frame),timescale:30))==0,
                      box.request.sourceFrame(byTrackID:i.carrier) != nil else {throw IBContract.error("clock source/PTS missing")}
                // Required carrier is solely a timing input. It is NEVER passed to the renderer.
                let bottom:CVPixelBuffer
                if let id=i.bottom {guard let p=box.request.sourceFrame(byTrackID:id) else{throw IBContract.error("bottom missing")};bottom=p}
                else {bottom=i.black}
                let top:CVPixelBuffer?
                if let id=i.top {guard let p=box.request.sourceFrame(byTrackID:id) else{throw IBContract.error("top missing")};top=p}
                else {top=nil}
                let output=try i.gpu.render(bottom:bottom,top:top,phase:i.phase).0
                guard current() else {i.log.add(["event":"stale-cancelled","frame":i.frame]);box.request.finishCancelledRequest();return}
                i.log.add(["event":"composed","ns":DispatchTime.now().uptimeNanoseconds,"rawSHA256":try QA01.sha(QA01.active(output)),"epoch":generation,"compositionTime":box.request.compositionTime.seconds,"frame":i.frame,"carrierSampledAsVisual":false,"active":i.gpu.leases.counts.active,"pending":i.gpu.leases.counts.pending])
                box.request.finish(withComposedVideoFrame:output)
            } catch {box.request.finish(with:error)}
        }
    }
}

final class ClockCarrierCompatibilityTests:XCTestCase {
    struct Plan {
        let asset:AVComposition,vc:AVVideoComposition,timeline:Timeline,log:IBLog,gpu:GMNV12
        let expected:[Int:String]
        let retainedAssets:[AVURLAsset], media:[MediaAsset]
        func item()->AVPlayerItem {let i=AVPlayerItem(asset:asset);i.videoComposition=vc;return i}
    }
    static func black()throws->CVPixelBuffer {
        let p=try GMNV12.allocate();CVPixelBufferLockBaseAddress(p,[]);defer{CVPixelBufferUnlockBaseAddress(p,[])}
        for plane in 0..<2 {guard let b=CVPixelBufferGetBaseAddressOfPlane(p,plane) else{throw IBContract.error("black plane")};memset(b,plane==0 ? 16:128,CVPixelBufferGetBytesPerRowOfPlane(p,plane)*CVPixelBufferGetHeightOfPlane(p,plane))}
        IBContract.tag(p);return p
    }
    /// Deliberately fixed geometry, matching the frozen GPU shader. Not a general product planner.
    static func plan(source:URL,run:URL,mixed:Bool,start:Int=1,end:Int=5)async throws->Plan {
        try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
        let carrier=run.appendingPathComponent("transport-only.mov")
        try FileManager.default.copyItem(at:source.appendingPathComponent("top.mov"),to:carrier)
        let asset=AVMutableComposition(),duration=CMTime(value:6,timescale:30)
        var retainedAssets=[AVURLAsset]()
        func insert(_ url:URL,kind:AVMediaType)async throws->CMPersistentTrackID {
            let a=AVURLAsset(url:url);retainedAssets.append(a);guard let src=try await a.loadTracks(withMediaType:kind).first,
                  let dst=asset.addMutableTrack(withMediaType:kind,preferredTrackID:kCMPersistentTrackID_Invalid) else{throw IBContract.error("real transport track")}
            let range=try await src.load(.timeRange)
            try dst.insertTimeRange(CMTimeRange(start:range.start,duration:duration),of:src,at:.zero)
            return dst.trackID
        }
        let clock=try await insert(carrier,kind:.video)
        let bottom=mixed ? try await insert(source.appendingPathComponent("bottom.mov"),kind:.video):nil
        let top=mixed ? try await insert(source.appendingPathComponent("top.mov"),kind:.video):nil
        if mixed,let audio=ProcessInfo.processInfo.environment["OTF_CLOCK_AUDIO"] { _=try await insert(URL(fileURLWithPath:audio),kind:.audio) }
        guard CMTimeCompare(asset.duration,duration)==0 else{throw IBContract.error("carrier transport duration")}
        let pngURL=source.appendingPathComponent("middle.png"),png=try IBReference.loadPNG(pngURL),transfer=try IBTransfer()
        let gpu=try GMNV12(image:png.1,transfer:transfer),black=try black(),log=IBLog(),cpu=IB420Compositor()
        var timeline=Timeline(),media=[MediaAsset](),imageLane=Lane.videoID
        if mixed {
            let b=try await MediaProbe.inspect(source.appendingPathComponent("bottom.mov")),t=try await MediaProbe.inspect(source.appendingPathComponent("top.mov"))
            media=[b,t];timeline=timeline.registering(b).registering(t)
            let middle=UUID(),upper=UUID();imageLane=middle
            timeline=try timeline.addingLane(.video,name:"image",id:middle,outward:true).addingLane(.video,name:"top",id:upper,outward:true)
            var audioClips=[Clip]()
            if let audio=ProcessInfo.processInfo.environment["OTF_CLOCK_AUDIO"] {
                let a=try await MediaProbe.inspect(URL(fileURLWithPath:audio));media.append(a);timeline=timeline.registering(a)
                audioClips=[Clip(mediaID:a.id,start:0,sourceIn:0,length:6,lane:Lane.audioID)]
            }
            timeline=timeline.rebuilt(video:[Clip(mediaID:b.id,start:0,sourceIn:0,length:6,lane:Lane.videoID),Clip(mediaID:t.id,start:2,sourceIn:2,length:2,lane:upper,transform:.init(scale:1,x:960,y:540))],audio:audioClips,duration:6)
        }
        let proof=try await StillImageProjectModel.ValidatedImage.inspect(pngURL)
        timeline=try timeline.registeringImage(proof,id:UUID())
        let imageID=timeline.stillImageIDs.first!,clipID=UUID()
        timeline=try timeline.placingImage(media:imageID,at:start,lane:imageLane,length:end-start,clipID:clipID)
        if end-start>=2 {timeline=try timeline.splitting(clip:clipID,atFrame:start+1)}
        let subtitle=UUID();timeline=try timeline.addingLane(.subtitle,name:"subtitle",id:subtitle).addingSubtitle(lane:subtitle,at:2,length:2,text:"clock")
        if let audio=timeline.audioClips.first {
            let spectrum=UUID();timeline=try timeline.addingLane(.spectrum,name:"spectrum",id:spectrum).addingSpectrum(lane:spectrum,at:1,length:4,sourceKey:audio.lineageKey)
        }
        guard timeline.mediaFrames[imageID]==nil,timeline.clips.filter({$0.mediaID==imageID}).allSatisfy({$0.sourceIn==0}),!ProjectPersistence.references(timeline).contains(where:{$0.path==carrier.path}) else{throw IBContract.error("carrier leaked into model")}
        _ = try ProjectPersistence.make(timeline:timeline,projectID:UUID())
        var instructions=[ClockCarrierInstruction](),expected=[Int:String]()
        for frame in 0..<6 {
            let imageOn=timeline.clips.contains{$0.mediaID==imageID && $0.start<=frame && frame<$0.end},topOn=mixed && frame>=2 && frame<4
            guard !topOn || imageOn else{throw IBContract.error("fixed shader cannot express top without image; not generalized")}
            let phase=topOn ? 2:(imageOn ? 1:0)
            let b=mixed ? try await IBReference.read(AVURLAsset(url:source.appendingPathComponent("bottom.mov")),frame:frame,format:IBContract.format):black
            let t=topOn ? try await IBReference.read(AVURLAsset(url:source.appendingPathComponent("top.mov")),frame:frame,format:IBContract.format):nil
            let reference=try GMNV12.allocate(),referenceInstruction=IBInstruction(frame:phase,bottom:11,top:12,png:png.1,transfer:transfer,log:IBLog())
            try cpu.render(bottom:b,top:t,out:reference,ins:referenceInstruction,deadline:Date().addingTimeInterval(10));IBContract.tag(reference)
            expected[frame]=QA01.sha(try QA01.active(reference))
            instructions.append(ClockCarrierInstruction(frame:frame,phase:phase,carrier:clock,bottom:bottom,top:topOn ? top:nil,gpu:gpu,black:black,log:log))
        }
        let vc=AVMutableVideoComposition();vc.customVideoCompositorClass=ClockCarrierCompositor.self;vc.renderSize=CGSize(width:1920,height:1080);vc.frameDuration=CMTime(value:1,timescale:30);vc.instructions=instructions
        return Plan(asset:asset.copy() as! AVComposition,vc:vc.copy() as! AVVideoComposition,timeline:timeline,log:log,gpu:gpu,expected:expected,retainedAssets:retainedAssets,media:media)
    }
    @MainActor static func wait(_ seconds:Double,_ predicate:@escaping @MainActor ()->Bool)async throws {
        let until=Date().addingTimeInterval(seconds)
        while !predicate() {guard Date()<until else{throw IBContract.error("clock compatibility timeout")};try await Task.sleep(nanoseconds:10_000_000)}
    }
    @MainActor static func seek(_ player:AVPlayer,_ frame:Int)async throws {
        let state=IBLog()
        player.seek(to:CMTime(value:Int64(frame),timescale:30),toleranceBefore:.zero,toleranceAfter:.zero){ok in state.add(["ok":ok])}
        try await wait(5){!state.snapshot.isEmpty};guard state.snapshot[0]["ok"] as? Bool==true else{throw IBContract.error("seek cancelled")}
    }
    @MainActor func testNativeCarrierCompatibility()async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_CLOCK_RUN"],let source=ProcessInfo.processInfo.environment["OTF_CLOCK_SOURCE"] else{throw XCTSkip("explicit bounded clock carrier opt-in")}
        let run=URL(fileURLWithPath:path),input=URL(fileURLWithPath:source)
        try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
        var report=[[String:Any]]()
        for (name,mixed,start,end) in [("image-only",false,1,5),("mixed-audio",true,1,5),("trim-move",false,2,6)] {
            let plan=try await Self.plan(source:input,run:run.appendingPathComponent(name),mixed:mixed,start:start,end:end)
            let item=plan.item(),output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);item.add(output)
            let player=AVPlayer(playerItem:item);player.isMuted=true;player.actionAtItemEnd = .pause
            defer{player.pause();item.cancelPendingSeeks();item.remove(output);player.replaceCurrentItem(with:nil)}
            try await Self.wait(5){item.status != .unknown};guard item.status == .readyToPlay else{throw item.error ?? IBContract.error("native clock item failed")}
            var frameObservations=[[String:Any]]()
            for (seekToken,frame) in [0,5,1,4,2,3].enumerated() {
                try await Self.seek(player,frame)
                let time=CMTime(value:Int64(frame),timescale:30);var pb:CVPixelBuffer?,shown=CMTime.invalid
                let deadline=Date().addingTimeInterval(5)
                var recordedInitial=false
                repeat {
                    pb=output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&shown)
                    if let first=pb,!recordedInitial {
                        recordedInitial=true
                        frameObservations.append(["event":"initial-non-nil","observationNs":DispatchTime.now().uptimeNanoseconds,"seekToken":seekToken+1,"itemGeneration":name,"frame":frame,"expectedPTS":time.seconds,"actualPTS":shown.seconds.isFinite ? shown.seconds:-1,"expectedHash":plan.expected[frame]!,"actualHash":try QA01.sha(QA01.active(first)),"itemTime":player.currentTime().seconds,"compositorEvents":plan.log.snapshot])
                        try JSONSerialization.data(withJSONObject:frameObservations,options:[.prettyPrinted,.sortedKeys]).write(to:run.appendingPathComponent(name+"-frame-observations.json"))
                    }
                    // One original five-second readiness budget. Matching PTS is
                    // readiness; the unchanged raw assertion below remains independent.
                    if pb != nil && (CMTimeCompare(shown,time)==0 || ProcessInfo.processInfo.environment["OTF_CLOCK_STRICT_INITIAL"]=="1") {break}
                    guard Date()<deadline else {throw IBContract.error("native exact output readiness timeout case=\(name) frame=\(frame)")}
                    try await Task.sleep(nanoseconds:10_000_000)
                } while true
                frameObservations.append(["event":"assertion-observation","observationNs":DispatchTime.now().uptimeNanoseconds,"seekToken":seekToken+1,"itemGeneration":name,"frame":frame,"expectedPTS":time.seconds,"actualPTS":shown.seconds.isFinite ? shown.seconds:-1,"expectedHash":plan.expected[frame]!,"actualHash":pb.flatMap{try? QA01.sha(QA01.active($0))} ?? "none","itemTime":player.currentTime().seconds,"compositorEvents":plan.log.snapshot])
                try JSONSerialization.data(withJSONObject:frameObservations,options:[.prettyPrinted,.sortedKeys]).write(to:run.appendingPathComponent(name+"-frame-observations.json"))
                guard let pb,CMTimeCompare(shown,time)==0,QA01.sha(try QA01.active(pb))==plan.expected[frame] else{throw IBContract.error("native displayed PTS/raw mismatch case=\(name) frame=\(frame)")}
            }
            try await Self.seek(player,0);player.play()
            try await Self.wait(5){player.currentTime().seconds>=4.0/30};player.pause()
            guard item.status == .readyToPlay,plan.gpu.leases.counts.active==0,plan.gpu.leases.counts.pending==0 else{throw IBContract.error("playback/resource retirement")}
            report.append(["case":name,"durationFrames":6,"carrierModelReferences":0,"seekRawParity":6,"audioTracks":try await plan.asset.loadTracks(withMediaType:.audio).count,"events":plan.log.snapshot])
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:run.appendingPathComponent("observations.json"))
        }
    }
}
