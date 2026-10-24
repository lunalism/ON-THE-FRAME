import Foundation
@testable import OnTheFrameEngine
import XCTest

// 스펙트럼 타당성 검사 시제품(2026-10-24, docs/SPECTRUM-DESIGN.md §9) — 제품 코드가 아니다(시험 대상 안, 기본 실행에서 건너뜀).

/// 시제품: 분석 덩어리 디코딩 일정. 캐시 바이트 상한 + 기다리는 요청 상한 + 동시 디코딩 상한 + 같은 덩어리 요청 합치기 + 세션(프로젝트 바꿈) 거름.
final class ProtoAnalysisScheduler: @unchecked Sendable {
    struct Key: Hashable { let media: UUID; let chunk: Int }
    typealias Done = ([[Float]]?) -> Void   // nil = 취소·버려짐(정확히 한 번 불림)
    let maxPending: Int, maxConcurrent: Int, cacheBudget: Int
    private let decoder: (Key) throws -> [[Float]]
    private let lock = NSLock()
    private let work = DispatchQueue(label: "proto.spectrum.decode", attributes: .concurrent)
    private var session = 0
    private var pending: [(key: Key, priority: Int)] = []
    private var inFlight: [Key: Int] = [:]                  // 키 → 세션
    private var waiters: [Key: [(session: Int, done: Done)]] = [:]
    private var cache: [Key: [[Float]]] = [:], lru: [Key] = []
    private(set) var cacheBytes = 0
    // 기록
    private(set) var decodes = 0, peakPending = 0, peakInFlight = 0, staleDropped = 0, droppedPending = 0, peakCacheBytes = 0, peakInFlightBytes = 0
    var chunkBytesEstimate = 0
    init(maxPending: Int, maxConcurrent: Int, cacheBudget: Int, decoder: @escaping (Key) throws -> [[Float]]) {
        self.maxPending = maxPending; self.maxConcurrent = maxConcurrent; self.cacheBudget = cacheBudget; self.decoder = decoder
    }
    static func bytes(_ d: [[Float]]) -> Int { d.reduce(0) { $0 + $1.count * 4 } }
    /// priority: 작을수록 먼저(재생 헤드와의 거리)
    func request(_ key: Key, priority: Int, done: @escaping Done) {
        lock.lock()
        if let d = cache[key] { lru.removeAll { $0 == key }; lru.append(key); lock.unlock(); done(d); return }
        waiters[key, default: []].append((session, done))
        if inFlight[key] == nil {
            if let i = pending.firstIndex(where: { $0.key == key }) { pending[i].priority = min(pending[i].priority, priority) }
            else { pending.append((key, priority)) }
            // 상한: 가장 먼(우선순위가 낮은) 요청을 버리고 그 기다리는 쪽에 취소를 알린다
            var dropped: [Done] = []
            while pending.count > maxPending {
                let worst = pending.indices.max { pending[$0].priority < pending[$1].priority }!
                let k = pending.remove(at: worst).key
                dropped += (waiters.removeValue(forKey: k) ?? []).map(\.done); droppedPending += 1
            }
            peakPending = max(peakPending, pending.count)
            lock.unlock()
            dropped.forEach { $0(nil) }
        } else { lock.unlock() }
        pump()
    }
    /// 프로젝트 바꿈: 세션 증가, 캐시·기다림 비움(기다리는 쪽에 취소), 진행 중 디코딩은 끝나도 버림
    func newSession() {
        lock.lock()
        session += 1
        let all = waiters.values.flatMap { $0.map(\.done) }
        waiters = [:]; pending = []; cache = [:]; lru = []; cacheBytes = 0
        lock.unlock()
        all.forEach { $0(nil) }
    }
    var cachedKeys: Int { lock.lock(); defer { lock.unlock() }; return cache.count }
    private func pump() {
        lock.lock()
        var starts: [(Key, Int)] = []
        while inFlight.count < maxConcurrent, let i = pending.indices.min(by: { pending[$0].priority < pending[$1].priority }) {
            let k = pending.remove(at: i).key
            inFlight[k] = session; starts.append((k, session))
        }
        peakInFlight = max(peakInFlight, inFlight.count)
        peakInFlightBytes = max(peakInFlightBytes, inFlight.count * chunkBytesEstimate)
        lock.unlock()
        for (k, s) in starts {
            work.async { [self] in
                let d = try? decoder(k)
                lock.lock()
                decodes += 1
                inFlight[k] = nil
                var deliver: [Done] = []
                if s == session, let d {
                    cache[k] = d; lru.append(k); cacheBytes += Self.bytes(d)
                    while cacheBytes > cacheBudget, lru.count > 1 { let old = lru.removeFirst(); cacheBytes -= Self.bytes(cache[old] ?? []); cache[old] = nil }
                    peakCacheBytes = max(peakCacheBytes, cacheBytes)
                    deliver = (waiters.removeValue(forKey: k) ?? []).filter { $0.session == s }.map(\.done)
                } else {
                    staleDropped += 1   // 다른 세션: 캐시에 넣지 않고 알리지 않음(바꿀 때 이미 취소를 알렸다)
                    if s == session { deliver = (waiters.removeValue(forKey: k) ?? []).map(\.done) }   // 디코딩 실패(같은 세션)
                }
                lock.unlock()
                let data = s == self.currentSession ? d : nil
                deliver.forEach { $0(data) }
                pump()
            }
        }
    }
    private var currentSession: Int { lock.lock(); defer { lock.unlock() }; return session }
}

final class SpectrumSchedulerPrototypeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SPECTRUM_PROTO"] == "1", "스펙트럼 시제품 검사는 OTF_SPECTRUM_PROTO=1일 때만")
    }
    final class Counter: @unchecked Sendable { let l = NSLock(); var data = 0, cancelled = 0; func add(_ ok: Bool) { l.lock(); if ok { data += 1 } else { cancelled += 1 }; l.unlock() } }
    func fake(delayMs: Int) -> (ProtoAnalysisScheduler.Key) throws -> [[Float]] {
        { _ in usleep(useconds_t(delayMs * 1000)); return [[Float](repeating: 0.1, count: 24_000), [Float](repeating: 0.1, count: 24_000)] }
    }

    func testCoalescingAcrossSpectraSameSource() {
        let s = ProtoAnalysisScheduler(maxPending: 64, maxConcurrent: 2, cacheBudget: 64 << 20, decoder: fake(delayMs: 5))
        let media = UUID(), g = DispatchGroup(), c = Counter()
        for spectrum in 0..<3 { for chunk in 0..<10 { g.enter(); s.request(.init(media: media, chunk: chunk), priority: chunk + spectrum) { c.add($0 != nil); g.leave() } } }
        XCTAssertEqual(g.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(s.decodes, 10, "스펙트럼 셋이 같은 소스 덩어리 10개 → 디코딩 10번")
        XCTAssertEqual(c.data, 30)
    }

    func testRapidSeeksBoundPendingAndConcurrency() {
        let s = ProtoAnalysisScheduler(maxPending: 8, maxConcurrent: 2, cacheBudget: 8 << 20, decoder: fake(delayMs: 2))
        let media = UUID(), g = DispatchGroup(), c = Counter()
        var rng = SystemRandomNumberGenerator()
        for i in 0..<2000 {   // 빠른 탐색: 재생 헤드가 계속 바뀌며 앞쪽 덩어리 넷씩 요청
            let head = Int.random(in: 0..<500, using: &rng)
            for d in 0..<4 { g.enter(); s.request(.init(media: media, chunk: head + d), priority: d) { c.add($0 != nil); g.leave() } }
            if i % 200 == 0 { usleep(1000) }
        }
        XCTAssertEqual(g.wait(timeout: .now() + 60), .success, "모든 요청이 정확히 한 번 끝남(자료 또는 취소)")
        print("PROTO rapid seeks: requests 8000 data \(c.data) cancelled \(c.cancelled) decodes \(s.decodes) peakPending \(s.peakPending) peakInFlight \(s.peakInFlight) peakCacheBytes \(s.peakCacheBytes)")
        XCTAssertEqual(c.data + c.cancelled, 8000)
        XCTAssertLessThanOrEqual(s.peakPending, 8); XCTAssertLessThanOrEqual(s.peakInFlight, 2)
        XCTAssertLessThanOrEqual(s.peakCacheBytes, (8 << 20) + 2 * 24_000 * 4)   // 상한 + 마지막에 넣은 덩어리 하나
    }

    func testProjectSwitchDropsStaleCompletions() {
        let s = ProtoAnalysisScheduler(maxPending: 16, maxConcurrent: 2, cacheBudget: 64 << 20, decoder: fake(delayMs: 50))
        let media = UUID(), g = DispatchGroup(), c = Counter()
        for chunk in 0..<6 { g.enter(); s.request(.init(media: media, chunk: chunk), priority: chunk) { c.add($0 != nil); g.leave() } }
        usleep(10_000)          // 디코딩 둘이 진행 중
        s.newSession()          // 프로젝트 바꿈
        XCTAssertEqual(g.wait(timeout: .now() + 10), .success)
        usleep(150_000)         // 진행 중이던 디코딩이 끝날 때까지
        print("PROTO switch: data \(c.data) cancelled \(c.cancelled) staleDropped \(s.staleDropped) cached \(s.cachedKeys)")
        XCTAssertEqual(c.data, 0, "바꾼 뒤 이전 세션 결과를 알리지 않음"); XCTAssertEqual(c.cancelled, 6)
        XCTAssertEqual(s.cachedKeys, 0, "늦게 끝난 디코딩이 비운 캐시를 다시 채우지 않음")
        XCTAssertGreaterThanOrEqual(s.staleDropped, 1)
    }

    /// 실제 디코딩(aud-steady48s, 0.5초 덩어리)으로 무작위 탐색 세 차례: 캐시 바이트는 상한 안, 프로세스 메모리는 기록만(짧은 실행 — 누수 없음의 증명 아님)
    func testRealDecodeMemoryAccounting() throws {
        let url = ExportEndToEndTests.root.appendingPathComponent("fixtures/aud-steady48s.wav")
        let src = ProtoPCMSource(url: url, chunk: 24_000, margin: 4_800)
        let budget = 1 << 20   // 1 MiB(덩어리 하나 약 188 KB: 2채널 × 24000 × 4)
        let s = ProtoAnalysisScheduler(maxPending: 8, maxConcurrent: 2, cacheBudget: budget) { try src.decode(chunkIndex: $0.chunk) }
        s.chunkBytesEstimate = 2 * 24_000 * 4
        let media = UUID()
        func footprintMB() -> Double {
            var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
            return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        }
        var rounds: [Double] = []
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3 {
            let g = DispatchGroup()
            for _ in 0..<120 { let h = Int.random(in: 0..<12, using: &rng); g.enter(); s.request(.init(media: media, chunk: h), priority: 0) { _ in g.leave() } }
            XCTAssertEqual(g.wait(timeout: .now() + 60), .success)
            rounds.append(footprintMB())
        }
        print("PROTO real decode: decodes \(s.decodes) cacheBytes \(s.cacheBytes) peakCache \(s.peakCacheBytes) peakInFlightBytes(est) \(s.peakInFlightBytes) footprint per round \(rounds.map { String(format: "%.1f", $0) })")
        XCTAssertLessThanOrEqual(s.cacheBytes, budget)
        XCTAssertLessThanOrEqual(s.peakCacheBytes, budget + 2 * 24_000 * 4)
    }
}
