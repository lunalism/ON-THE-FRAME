import XCTest
import Foundation

final class ImageAwareAdmissionTests: XCTestCase {
    final class Manual: @unchecked Sendable {
        private let lock = NSLock();private var jobs: [() -> Void] = []
        func put(_ job: @escaping () -> Void) { lock.lock();jobs.append(job);lock.unlock() }
        func take() -> (() -> Void)? { lock.lock();defer { lock.unlock() };return jobs.isEmpty ? nil : jobs.removeFirst() }
        func drain() { var count = 0;while let job = take() { count += 1;if count>32 { XCTFail("executor did not drain");return };job() } }
    }
    final class Sink: @unchecked Sendable {
        private let lock = NSLock();private var rows: [[String:Any]] = []
        func add(_ value: Int,_ result: IBTerminal<Int>) {
            let terminal: String
            switch result { case .success:terminal = "success";case .failure:terminal = "failure";case .cancelled:terminal = "cancelled" }
            lock.lock();rows.append(["value":value,"terminal":terminal]);lock.unlock()
        }
        var snapshot: [[String:Any]] { lock.lock();defer { lock.unlock() };return rows }
        func terminal(_ value: Int) -> [String] { snapshot.filter { $0["value"] as? Int == value }.compactMap { $0["terminal"] as? String } }
    }
    var diagnostics: IBDiagnostics!
    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["OTF_IMG_B_POC1R_SCHEDULER_RUN"] else { throw XCTSkip("IMG-B-POC-1R scheduler opt-in") }
        let base = URL(fileURLWithPath:path).standardizedFileURL
        let permitted = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path+"/"
        guard base.path.hasPrefix(permitted) else { throw IBContract.error("scheduler output root",code:300) }
        let method = name.components(separatedBy:" ").last?.replacingOccurrences(of:"]",with:"") ?? "unknown"
        let root = base.appendingPathComponent("scheduler").appendingPathComponent(method)
        guard !FileManager.default.fileExists(atPath:root.path) else { throw IBContract.error("fresh scheduler output required",code:300) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);diagnostics = IBDiagnostics(root:root)
    }
    @discardableResult func submit(_ scheduler: IBAdmission<Int>,_ sink: Sink,_ value: Int,work: ((IBLease)->IBTerminal<Int>)? = nil) -> UInt64 {
        scheduler.submit(tag:String(value),work:work ?? { _ in .success(value) },completion:{ sink.add(value,$0) })
    }
    func checked(_ s: IBAdmission<Int>,_ sink: Sink,_ count: Int) throws {
        let state = s.snapshot
        XCTAssertEqual(state["active"] as? Int,0);XCTAssertEqual(state["pending"] as? Int,0)
        XCTAssertLessThanOrEqual(state["maxActive"] as? Int ?? 99,2)
        XCTAssertLessThanOrEqual(state["maxPending"] as? Int ?? 99,4)
        XCTAssertEqual(state["terminalCount"] as? Int,count);XCTAssertEqual(sink.snapshot.count,count)
        for i in Set(sink.snapshot.compactMap { $0["value"] as? Int }) { XCTAssertEqual(sink.terminal(i).count,1) }
        try diagnostics.note("scheduler-result",["state":state,"completions":sink.snapshot])
    }
    func testAOneRequest() throws {
        let e = Manual(),sink = Sink(),s = IBAdmission<Int>(executor:e.put)
        submit(s,sink,0);XCTAssertEqual(s.snapshot["active"] as? Int,1);e.drain()
        XCTAssertEqual(sink.terminal(0),["success"]);try checked(s,sink,1)
    }
    func testBTwoSimultaneousWorkers() throws {
        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0),done = DispatchGroup(),sink = Sink()
        let s = IBAdmission<Int>(executor:{ job in done.enter();DispatchQueue.global().async { job();done.leave() } })
        for value in 0..<2 { submit(s,sink,value,work:{ _ in entered.signal();guard release.wait(timeout:.now()+3) == .success else { return .failure(IBContract.error("test barrier timeout")) };return .success(value) }) }
        XCTAssertEqual(entered.wait(timeout:.now()+3),.success);XCTAssertEqual(entered.wait(timeout:.now()+3),.success)
        XCTAssertEqual(s.snapshot["active"] as? Int,2)
        release.signal();release.signal();XCTAssertEqual(done.wait(timeout:.now()+3),.success)
        XCTAssertEqual(sink.snapshot.filter { $0["terminal"] as? String == "success" }.count,2);try checked(s,sink,2)
    }
    func testCSixRequestBurst() throws {
        let e = Manual(),sink = Sink(),s = IBAdmission<Int>(executor:e.put)
        for value in 0..<6 { submit(s,sink,value) }
        XCTAssertEqual(s.snapshot["active"] as? Int,2);XCTAssertEqual(s.snapshot["pending"] as? Int,4)
        e.drain();XCTAssertEqual(sink.snapshot.filter { $0["terminal"] as? String == "success" }.count,6);try checked(s,sink,6)
    }
    func testDFIFOPendingPromotionWithOutOfOrderActiveCompletion() throws {
        let e = Manual(),sink = Sink(),s = IBAdmission<Int>(executor:e.put)
        for value in 0..<5 { submit(s,sink,value) }
        let first = try XCTUnwrap(e.take()),second = try XCTUnwrap(e.take())
        second();first();e.drain()
        let events = s.snapshot["events"] as? [[String:Any]] ?? []
        XCTAssertEqual(events.filter { $0["event"] as? String == "promoted" }.compactMap { $0["tag"] as? String },["2","3","4"])
        try checked(s,sink,5)
    }
    func testEActiveFailureReleasesSlot() throws {
        let e = Manual(),sink = Sink(),s = IBAdmission<Int>(executor:e.put)
        submit(s,sink,0,work:{ _ in .failure(IBContract.error("injected active failure")) });submit(s,sink,1);submit(s,sink,2)
        e.drain();XCTAssertEqual(sink.terminal(0),["failure"]);XCTAssertEqual(sink.terminal(2),["success"]);try checked(s,sink,3)
    }
    func testFPendingCancellationAndOwnershipRemoval() throws {
        let e = Manual(),sink = Sink(),s = IBAdmission<Int>(executor:e.put)
        weak var retained: NSObject?
        for value in 0..<4 {
            if value == 2 {
                let payload = NSObject();retained = payload
                submit(s,sink,value,work:{ [payload] _ in _ = payload;return .success(value) })
            } else { submit(s,sink,value) }
        }
        XCTAssertNotNil(retained)
        s.cancelAll();XCTAssertEqual(s.snapshot["pending"] as? Int,0);XCTAssertEqual(s.snapshot["active"] as? Int,2)
        XCTAssertNil(retained,"cancelled pending job payload must release without waiting for the90s timer")
        XCTAssertEqual(sink.terminal(2),["cancelled"]);XCTAssertEqual(sink.terminal(3),["cancelled"])
        e.drain();for value in 0..<4 { XCTAssertEqual(sink.terminal(value),["cancelled"]) };try checked(s,sink,4)
    }
    func testGActiveCancellationRejectsLateSuccess() throws {
        let e = Manual(),sink = Sink(),s = IBAdmission<Int>(executor:e.put)
        submit(s,sink,0,work:{ lease in s.cancelAll();XCTAssertTrue(lease.isCancelled);return .success(100) })
        e.drain();XCTAssertEqual(sink.terminal(0),["cancelled"]);try checked(s,sink,1)
    }
    func testHConcurrentAdmissionCancellationRace() throws {
        let e = Manual(),sink = Sink(),s = IBAdmission<Int>(executor:e.put)
        for value in 0..<4 { submit(s,sink,value) }
        let start = DispatchSemaphore(value:0),done = DispatchGroup()
        done.enter();DispatchQueue.global().async { start.wait();s.cancelAll();done.leave() }
        done.enter();DispatchQueue.global().async { start.wait();self.submit(s,sink,4);done.leave() }
        start.signal();start.signal();XCTAssertEqual(done.wait(timeout:.now()+3),.success)
        e.drain()
        for value in 0..<4 { XCTAssertEqual(sink.terminal(value),["cancelled"]) }
        let events = s.snapshot["events"] as? [[String:Any]] ?? []
        let accepted = events.first { $0["tag"] as? String == "4" }
        let gen = (accepted?["generation"] as? UInt64) ?? (accepted?["generation"] as? NSNumber)?.uint64Value
        XCTAssertEqual(sink.terminal(4),[gen == 0 ? "cancelled" : "success"])
        try checked(s,sink,5)
    }
    func testIExactlyOnceAndReentrantCompletion() throws {
        let e = Manual(),sink = Sink(),s = IBAdmission<Int>(executor:e.put)
        s.submit(tag:"0",work:{ _ in .success(0) },completion:{ result in
            sink.add(0,result);_ = s.snapshot;s.cancelAll();self.submit(s,sink,99)
        })
        let job = try XCTUnwrap(e.take());job();job();e.drain()
        XCTAssertEqual(sink.terminal(0),["success"]);XCTAssertEqual(sink.terminal(99),["success"]);try checked(s,sink,2)
    }
    func testJExplicitOverflowCompletion() throws {
        let e = Manual(),sink = Sink(),s = IBAdmission<Int>(executor:e.put)
        for value in 0..<7 { submit(s,sink,value) }
        XCTAssertEqual(sink.terminal(6),["failure"]);XCTAssertEqual(s.snapshot["overflowCount"] as? Int,1)
        e.drain();try checked(s,sink,7)
    }
    func testKPendingDeadlineAndDuplicateExpiry() throws {
        let e = Manual(),sink = Sink(),s = IBAdmission<Int>(executor:e.put)
        submit(s,sink,0);submit(s,sink,1);let id = submit(s,sink,2);submit(s,sink,3)
        s.expirePending(id);s.expirePending(id)
        XCTAssertEqual(sink.terminal(2),["failure"]);e.drain();XCTAssertEqual(sink.terminal(3),["success"]);try checked(s,sink,4)
    }
}
