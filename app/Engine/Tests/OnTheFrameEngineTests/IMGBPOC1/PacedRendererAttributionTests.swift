import XCTest
import AVFoundation
import CoreGraphics

final class PacedRendererAttributionTests:XCTestCase {
    var base:URL!,root:URL!,diag:IBDiagnostics!
    override func setUp() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF05_RUN"] else{throw XCTSkip("IMG-B-PERF-04 explicit opt-in")}
        base=URL(fileURLWithPath:path).standardizedFileURL
        let allowed=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path+"/"
        guard base.path.hasPrefix(allowed),!_isDebugAssertConfiguration(),_isReleaseAssertConfiguration(),IBPerfProbe.enabled else{throw IBContract.error("PERF05 verified Release/probe/root required",code:300)}
        root=base.appendingPathComponent("renderer-recheck")
        guard !FileManager.default.fileExists(atPath:root.path) else{throw IBContract.error("PERF05 fresh mode root",code:300)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);diag=IBDiagnostics(root:root)
    }
    func testOneCalibratedPaced90() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF05_CALIBRATION"] else{throw IBContract.error("PERF05 calibration prerequisite",code:300)}
        let data=try Data(contentsOf:URL(fileURLWithPath:path)),file=try JSONSerialization.jsonObject(with:data) as? [String:Any]
        guard file?["strategy"] as? String=="strict-absolute",let summary=file?["summary"] as? [String:Any],summary["fidelityValidated"] as? Bool==true,summary["n"] as? Int==90 else{throw IBContract.error("PERF05 strict calibration not suitable; renderer test forbidden",code:300)}
        try diag.note("documented-calibration-before-render",["path":path,"SHA256":QA01.sha(data),"summary":summary])
        try await execute("paced-perf05-strict")
    }
    func buffer(_ raw:Data)throws->CVPixelBuffer {
        guard raw.count==3_110_400 else{throw IBContract.error("PERF05 representative bounds",code:200)}
        var pb:CVPixelBuffer?;guard CVPixelBufferCreate(nil,1920,1080,IBContract.format,nil,&pb)==kCVReturnSuccess,let pb else{throw IBContract.error("PERF05 representative allocation",code:300)}
        CVPixelBufferLockBaseAddress(pb,[])
        do {defer{CVPixelBufferUnlockBaseAddress(pb,[])};try raw.withUnsafeBytes{bytes in
            let source=try XCTUnwrap(bytes.baseAddress);var offset=0
            for p in 0..<2 {let d=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,p)),stride=CVPixelBufferGetBytesPerRowOfPlane(pb,p),height=CVPixelBufferGetHeightOfPlane(pb,p)
                for y in 0..<height {memcpy(d+y*stride,source+offset,1920);offset+=1920}}
        }}
        IBContract.tag(pb);return pb
    }
    func execute(_ mode:String) async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF05_FIXTURES"],let baselinePath=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF05_BASELINE"] else{throw IBContract.error("PERF05 existing inputs required",code:300)}
        let dir=URL(fileURLWithPath:path),urls=["bottom.mov","top.mov","middle.png"].map{dir.appendingPathComponent($0)},setup=IBPerfClock.now(process:true)
        let digest=try IBReference.digest(urls)
        guard digest=="26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1" else{throw IBContract.error("PERF05 fixture fingerprint",code:200)}
        let png=try IBReference.loadPNG(urls[2]),transfer=try IBTransfer()
        var bottom=[Int:CVPixelBuffer](),top=[Int:CVPixelBuffer](),sourceHashes=[[String:Any]]()
        for phase in 1...4 {
            let pb=try await IBReference.read(AVURLAsset(url:urls[0]),frame:phase,format:IBContract.format);bottom[phase]=pb
            sourceHashes.append(["source":"bottom","frame":phase,"activeSHA256":QA01.sha(try QA01.active(pb)),"metadata":try QA01.metadata(pb,allocation:"actual AVFoundation decode, retained for repeated source use")])
            if phase==2 || phase==3 {let pb=try await IBReference.read(AVURLAsset(url:urls[1]),frame:phase,format:IBContract.format);top[phase]=pb;sourceHashes.append(["source":"top","frame":phase,"activeSHA256":QA01.sha(try QA01.active(pb))])}
        }
        let baselineURL=URL(fileURLWithPath:baselinePath),baselineData=try Data(contentsOf:baselineURL),baseline=try JSONSerialization.jsonObject(with:baselineData) as? [[String:Any]] ?? []
        guard baseline.count==6 else{throw IBContract.error("PERF05 Debug baseline count",code:200)}
        var expected=[Int:String]();for phase in 1...4 {expected[phase]=try XCTUnwrap(baseline.first{$0["frame"] as? Int==phase}?["SHA256"] as? String)}
        try diag.note("setup",["mode":mode,"setup":IBPerfClock.span(setup,IBPerfClock.now(process:true)),"fixtureDigest":digest,"baselineSHA256":QA01.sha(baselineData),"sourceHashes":sourceHashes,"DEBUG":_isDebugAssertConfiguration(),"release":_isReleaseAssertConfiguration(),"probe":IBPerfProbe.enabled,
            "workload":"exactly90 positions n/30 over3s nominal; phase=n%4+1; 45image-no-top and45image-with-top; no no-image samples; static original PNG, independently rendered each position",
            "limitations":"AVFoundation decodes6 distinct original source buffers at setup, reused across90 jobs; driver timestamps output samples n/30; not90 unique decoded inputs/AVVideoCompositing callbacks/playback",
            "schedule":"one fixed50ms scheduling lead excluded from elapsed; offline6 in-flight window/refill on terminal; paced anchored arrivals t0+n/30, deadlines t0+(n+1)/30; no timer adjustment after observation",
            "warmup":"no extra rendered warmup or discarded frames; first6 vsremaining84 separately reported; OS caches not flushed"])
        let inputs=IBSustainedInputs(bottom,top,png.0,png.1,transfer,expected),run=IBSustainedRun(mode:mode,inputs:inputs,root:root,diag:diag),cpuStart=IBPerfClock.now(process:true)
        run.begin();let completed=run.wait(),runAccounting=IBPerfClock.span(cpuStart,IBPerfClock.now(process:true)),report=run.report()
        try JSONSerialization.data(withJSONObject:diag.safe(report),options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("run-records.json"),options:.atomic)
        try diag.note("run-collected",["completedWithin30s":completed,"accountingIncludesSchedulingLead":runAccounting,"submitted":report["submitted"] ?? 0,"terminals":report["terminals"] ?? 0,"errors":report["errors"] ?? [],"deadlineMissesArePerformanceResults":"not assertion failures; all bounded timing evidence retained"])
        guard completed else{throw IBContract.error("PERF05 bounded timeout",code:300)}
        let fidelityRows=(report["rows"] as? [[String:Any]] ?? []).map{r -> [String:Any] in
            ["position":r["position"] ?? -1,"intendedNs":r["scheduledArrivalNs"] ?? 0,"actualSubmissionNs":r["arrivalNs"] ?? 0]
        }
        let loadedFidelity=IBPacedFidelity.summary(fidelityRows)
        try diag.note("arrival-fidelity-under-render-load",loadedFidelity)
        guard loadedFidelity["fidelityValidated"] as? Bool==true else{throw IBContract.error("PERF05 DRIVER UNRELIABLE under renderer load; no renderer verdict",code:300)}

        guard (report["errors"] as? [String] ?? []).isEmpty,report["submitted"] as? Int==90,report["terminals"] as? Int==90 else{throw IBContract.error("PERF05 stopped/correctness failure",code:200)}
        let counts=report["completionCounts"] as? [[String:Int]] ?? [];guard counts.count==90,counts.allSatisfy({$0["count"]==1}) else{throw IBContract.error("PERF05 missing/duplicate terminal",code:200)}
        let final=run.admission.snapshot;guard final["active"] as? Int==0,final["pending"] as? Int==0,final["overflowCount"] as? Int==0 else{throw IBContract.error("PERF05 scheduler did not drain",code:300)}
        let helper=ImageAware420GateTests();helper.root=root;helper.base=base;helper.diagnostics=diag
        let qualityStart=IBPerfClock.now(process:true)
        for n in run.representatives.sorted() {
            let raw=try XCTUnwrap(run.samples[n]),pb=try buffer(raw),phase=n%4+1
            try raw.write(to:root.appendingPathComponent("representative-position\(n)-phase\(phase).420v"))
            try await helper.geometry(pb,topURL:urls[1],frame:phase)
            try await helper.checkQuality(pb,dir:dir,frame:phase,png:png.0,label:"quality-position\(n)")
        }
        guard try IBReference.digest(urls)==digest,try Data(contentsOf:baselineURL)==baselineData else{throw IBContract.error("PERF05 inputs changed",code:200)}
        try diag.note("correctness-complete",["mode":mode,"positions":90,"rawHashMatches":90,"representativePositions":run.representatives.sorted(),"qualityAndGeometryAfterTimedRun":IBPerfClock.span(qualityStart,IBPerfClock.now(process:true)),"allRepresentativesQualityPass":true,"canonical":"unchanged QA02; global>=40dB/flat<=3; other83 positions hash/source/PTS validated but not separately pixel-scored","newAVPlayerRuns":0,"newExports":0])
    }
}
