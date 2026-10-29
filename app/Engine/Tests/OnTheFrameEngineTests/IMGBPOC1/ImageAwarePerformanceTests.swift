import XCTest
import AVFoundation
import CoreGraphics

final class ImageAwarePerformanceTests:XCTestCase {
    var base:URL!,root:URL!,diag:IBDiagnostics!
    override func setUp() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF02_RUN"] else {throw XCTSkip("IMG-B-PERF-02 explicit opt-in")}
        base=URL(fileURLWithPath:path).standardizedFileURL
        let allowed=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path+"/"
        guard base.path.hasPrefix(allowed) else {throw IBContract.error("PERF02 disposable root",code:300)}
        root=base.appendingPathComponent("profile")
        guard !FileManager.default.fileExists(atPath:root.path) else {throw IBContract.error("PERF02 fresh root",code:300)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);diag=IBDiagnostics(root:root)
    }
    func note(_ name:String,_ fields:[String:Any]) throws {try diag.note(name,fields)}
    func timed(_ start:IBPerfClock.Stamp)->[String:Any] {IBPerfClock.span(start,IBPerfClock.now(process:true))}
    func testBoundedReaderProfile() async throws {
        guard let dir=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF02_FIXTURES"] else {throw IBContract.error("PERF02 existing fixture required",code:300)}
        let source=URL(fileURLWithPath:dir),inputs=["bottom.mov","top.mov","middle.png"].map{source.appendingPathComponent($0)}
        let digest=try IBReference.digest(inputs)
        guard digest=="26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1" else {throw IBContract.error("PERF02 frozen fixture mismatch",code:200)}
        let repetitions=Int(ProcessInfo.processInfo.environment["OTF_IMG_B_PERF02_REPETITIONS"] ?? "1") ?? 0
        guard (1...2).contains(repetitions) else {throw IBContract.error("PERF02 repetition bound",code:300)}
        let helper=ImageAware420GateTests();helper.root=root;helper.base=base;helper.diagnostics=diag
        try note("contract",["probeEnabled":IBPerfProbe.enabled,"repetitions":repetitions,"fixtureDigest":digest,"quality":"unchanged QA02; Gate1 run separately",
            "cache":"first plan fresh in this process; OS/filesystem/codec caches NOT flushed; repetition1 after repetition0 is warm reuse, not a cold-cache claim",
            "timers":"monotonic wall; worker thread CPU in renderer; harness process CPU spans can include concurrent workers; cross-thread harness thread CPU marked unavailable",
            "combined":"C input conversion+D blending+E chroma/output conversion+pixel writes; no expression refactor or pixel timer",
            "bounds":"<=2 six-frame repetitions, no AVPlayer/export, no fixture generation; no arbitrary sleeps"])
        let calibrationStart=IBPerfClock.now(process:true)
        for _ in 0..<1000 {let p=IBPerfProbe();p.mark("empty");_ = p.total}
        try note("clock-calibration",["iterations":1000,"scope":"probe init+one mark+total; not subtracted from stage samples","aggregate":timed(calibrationStart)])
        var baseline:[[String:Any]]=[]
        if let path=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF02_BASELINE"] {
            baseline=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as? [[String:Any]] ?? []
            guard baseline.count==6 else {throw IBContract.error("PERF02 six-frame off baseline absent",code:200)}
        }
        for repetition in 0..<repetitions {
            let pngStart=IBPerfClock.now(process:true),png=try IBReference.loadPNG(inputs[2]),pngTiming=timed(pngStart)
            let planStart=IBPerfClock.now(process:true),plan=try await helper.makePlan(source,png:png.1),planTiming=timed(planStart)
            let setupStart=IBPerfClock.now(process:true),reader=try AVAssetReader(asset:plan.asset),tracks=try await plan.asset.loadTracks(withMediaType:.video)
            let output=AVAssetReaderVideoCompositionOutput(videoTracks:tracks,videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);output.videoComposition=plan.custom;reader.add(output)
            let readerSetup=timed(setupStart)
            try note("setup-\(repetition)",["PNGdecodeAndRGBAcache":pngTiming,"compositionAndICCLUTPlan":planTiming,"readerConfiguration":readerSetup,
                "cache":"process-first/OS-unknown"+(repetition==0 ? "; new plan":"; prior repetition completed, warm cache likely")])
            let pipelineStart=IBPerfClock.now(process:true)
            guard reader.startReading() else {throw reader.error ?? IBContract.error("PERF02 reader start")}
            var pulls=[[String:Any]](),raw=[[String:Any]](),n=0
            do {
                defer {reader.cancelReading()}
                while true {
                    let pullStart=IBPerfClock.now(process:true),sample=output.copyNextSampleBuffer(),pullTiming=timed(pullStart)
                    guard let sample else {break}
                    guard n<6,let pb=CMSampleBufferGetImageBuffer(sample) else {throw IBContract.error("PERF02 sample count",code:200)}
                    let pts=CMSampleBufferGetPresentationTimeStamp(sample)
                    guard pts.isNumeric,CMTimeCompare(pts,CMTime(value:Int64(n),timescale:30))==0 else {throw IBContract.error("PERF02 PTS",code:200)}
                    try IBContract.validate(pb)
                    let hashStart=IBPerfClock.now(process:true),hash=QA01.sha(try QA01.active(pb)),hashTiming=timed(hashStart)
                    if !baseline.isEmpty {guard baseline[n]["SHA256"] as? String==hash else {throw IBContract.error("instrumentation raw output changed frame\(n)",code:200)}}
                    raw.append(["frame":n,"PTS":"\(pts.value)/\(pts.timescale)","SHA256":hash])
                    pulls.append(["frame":n,"pullIncludingFrameworkDecodeAndWorkerWait":pullTiming,"activeByteHashOverhead":hashTiming]);n+=1
                }
                guard n==6,reader.status == .completed else {throw reader.error ?? IBContract.error("PERF02 reader incomplete",code:200)}
            }
            let pipelineTiming=timed(pipelineStart),rows=plan.log.snapshot
            let spans=rows.filter{$0["event"] as? String=="performance-spans"},renders=rows.filter{$0["event"] as? String=="rendered"}
            guard renders.count==6,spans.count==(IBPerfProbe.enabled ? 6:0) else {throw IBContract.error("PERF02 lost render/spans",code:200)}
            let last=try XCTUnwrap(rows.last(where:{$0["scheduler"] != nil})?["scheduler"] as? [String:Any])
            guard (last["maxActive"] as? Int ?? 99)<=2,(last["maxPending"] as? Int ?? 99)<=4,
                  last["active"] as? Int==0,last["pending"] as? Int==0,last["overflowCount"] as? Int==0 else {throw IBContract.error("PERF02 scheduler bounds",code:200)}
            try note("batch-\(repetition)",["repetition":repetition,"rawHashes":raw,"pulls":pulls,"pipelineWallAndProcessCPU":pipelineTiming,"requests":rows,"scheduler":last,
                "baselineByteEquality":baseline.isEmpty ? "off baseline collection":"all6 hashes equal probe-off",
                "diagnosticScope":"raw active hash occurs between pulls; excluded from worker spans but can perturb wall contention; no quality comparison during timed reader drain"])
            if repetition==0 {try JSONSerialization.data(withJSONObject:raw,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("raw-baseline.json"),options:.atomic)}
            // Native video-only composition includes reader/decode/startup; not a custom pixel kernel timer.
            for frame in [0,2,5] {
                let nativeStart=IBPerfClock.now(process:true),native=try await IBReference.read(plan.asset,frame:frame,vc:plan.native,format:IBContract.format),nativeTiming=timed(nativeStart)
                try IBContract.validate(native)
                try note("native-\(repetition)-\(frame)",["frame":frame,"timing":nativeTiming,"scope":"single-frame native video-only AVAssetReader incl decode/startup; PNG excluded by existing native plan"])
            }
        }
        if IBPerfProbe.enabled {
            guard let file=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF02_MP4"] else {throw IBContract.error("PERF02 retained overhead input required",code:300)}
            let url=URL(fileURLWithPath:file),before=QA01.sha(try Data(contentsOf:url))
            guard before=="c7781efd86c905b80ed60909bca4df0cae364c0eca85ff580b25a219e93acdf5" else {throw IBContract.error("PERF02 retained export digest",code:200)}
            let readStart=IBPerfClock.now(process:true),pb=try await IBReference.read(AVURLAsset(url:url),frame:2,format:IBContract.format),readTiming=timed(readStart)
            let png=try IBReference.loadPNG(inputs[2]),qualityStart=IBPerfClock.now(process:true)
            try await helper.checkQuality(pb,dir:source,frame:2,png:png.0,label:"overhead-retained")
            try note("reference-overhead",["retainedDecode":readTiming,"referenceAndCanonicalComparisonAndJSON":timed(qualityStart),"scope":"one retained export frame2; frozen helper/source-over/canonical/threshold unchanged; includes reference source decode and stats, not renderer work"])
            guard QA01.sha(try Data(contentsOf:url))==before else {throw IBContract.error("PERF02 retained MP4 changed",code:200)}
        }
        guard try IBReference.digest(inputs)==digest else {throw IBContract.error("PERF02 fixture mutated",code:200)}
        try note("completed",["repetitions":repetitions,"newExports":0,"AVPlayerRuns":0,"probeEnabled":IBPerfProbe.enabled,"rawByteParity":baseline.isEmpty ? "baseline collected":"all repetitions match baseline"])
    }
}
