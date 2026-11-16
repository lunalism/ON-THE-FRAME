import XCTest
import Foundation

/// Configuration audit only. No renderer, threshold, or sampling changes.
final class ReleaseBuildVerificationTests:XCTestCase {
    func testOptimizedConfigurationAndOptIn() throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG_B_PERF03_RUN"] else {throw XCTSkip("IMG-B-PERF-03 configuration opt-in")}
        let root=URL(fileURLWithPath:path).standardizedFileURL
        let allowed=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path+"/"
        guard root.path.hasPrefix(allowed) else {throw IBContract.error("PERF03 disposable root",code:300)}
        let out=root.appendingPathComponent("release-runtime-configuration.json")
        guard !FileManager.default.fileExists(atPath:out.path) else {throw IBContract.error("PERF03 fresh config evidence required",code:300)}
        #if DEBUG
        let debugFlag=true
        #else
        let debugFlag=false
        #endif
        let fields:[String:Any]=["DEBUG":debugFlag,"isDebugAssertConfiguration":_isDebugAssertConfiguration(),
            "isReleaseAssertConfiguration":_isReleaseAssertConfiguration(),"isFastAssertConfiguration":_isFastAssertConfiguration(),
            "probeEnabled":IBPerfProbe.enabled,"qualityGuards":"existing explicit throws/XCTest gates remain; Swift assert disabled normally at -O",
            "testSource":#filePath]
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:fields,options:[.prettyPrinted,.sortedKeys]).write(to:out,options:.atomic)
        guard !debugFlag,!_isDebugAssertConfiguration(),_isReleaseAssertConfiguration(),!_isFastAssertConfiguration(),IBPerfProbe.enabled else {throw IBContract.error("PERF03 actual optimized Release configuration not established",code:300)}
        XCTAssertFalse(debugFlag);XCTAssertTrue(_isReleaseAssertConfiguration());XCTAssertTrue(IBPerfProbe.enabled)
    }
}
