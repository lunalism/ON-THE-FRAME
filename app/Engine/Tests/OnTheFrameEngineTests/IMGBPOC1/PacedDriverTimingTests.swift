import XCTest
import Foundation

final class PacedDriverTimingTests:XCTestCase {
    func testNoRender90() throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF05_CALIBRATION_RUN"],let strategy=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF05_CLOCK"] else{throw XCTSkip("PERF05 no-render calibration opt-in")}
        guard ["legacy-asyncAfter","strict-absolute"].contains(strategy),_isReleaseAssertConfiguration(),!_isDebugAssertConfiguration() else{throw IBContract.error("PERF05 Release/strategy",code:300)}
        let root=URL(fileURLWithPath:path).standardizedFileURL
        let allowed=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path+"/"
        guard root.path.hasPrefix(allowed),!FileManager.default.fileExists(atPath:root.path) else{throw IBContract.error("PERF05 fresh disposable calibration",code:300)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:IBPacedFidelity.criteria,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("criteria-before-run.json"))
        let queue=DispatchQueue(label:"img-b-perf05.calibration",qos:.userInitiated),done=DispatchSemaphore(value:0),start=DispatchTime.now().uptimeNanoseconds+50_000_000
        var records=[[String:Any]]()
        let plan=IBPacedArrivalPlan(queue:queue,start:start,strategy:strategy){n,actual in
            records.append(["position":n,"intendedNs":start+UInt64(n)*1_000_000_000/30,"actualSubmissionNs":actual])
            if records.count==90 {done.signal()}
        }
        let accounting=IBPerfClock.now(process:true);plan.begin();let complete=done.wait(timeout:.now()+6) == .success
        if !complete {plan.cancel()}
        let rows=queue.sync{records.sorted{($0["position"] as? Int ?? 0)<($1["position"] as? Int ?? 0)}}
        let summary=IBPacedFidelity.summary(rows)
        let output:[String:Any]=["strategy":strategy,"startNs":start,"records":rows,"summary":summary,"completeWithin6s":complete,"accounting":IBPerfClock.span(accounting,IBPerfClock.now(process:true)),"receiver":"append90 timestamp records only; no fixture, decode, render, scheduler or image buffers","qos":"userInitiated, same as original arrival/control queue"]
        try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("calibration.json"))
        guard complete,rows.count==90,Set(rows.compactMap{$0["position"] as? Int}).count==90 else{throw IBContract.error("PERF05 missing/duplicate calibration or timeout",code:200)}
        // Unsuitable timing is a recorded measurement, not a hidden XCTest PASS verdict.
        print("PERF05 calibration \(strategy): \(summary)")
    }
}
