import Foundation
@testable import OnTheFrameEngine
import os
import OTFDevSupport
import XCTest

/// 스펙트럼 분석 일정(제품 엔진, SP-0 (3)) — 시제품 일정 검사(SpectrumSchedulerPrototypeTests, OTF_SPECTRUM_PROTO=1)를 기본 실행 검사로 옮기고
/// 시제품 결함(세션을 바꾼 뒤 같은 덩어리 요청이 이전 세션 디코딩을 기다리다 끝나지 않음)의 재현 검사를 더함.
final class SpectrumSchedulerTests: XCTestCase {
    /// 가짜 원본: 1000 Hz 진폭 0.2(두 채널), 덩어리 0.5초. 디코딩 수·동시 수·주 스레드 호출·실패 덩어리·멈춤 문을 센다.
    final class FakePCM: SpectrumPCMProvider {
        struct Counters { var decodes = 0, running = 0, peakRunning = 0, onMain = 0, released = true, releasedCalls: Set<Int> = [], cancelledSeen = 0, labels: Set<String> = [] }
        let identity: SpectrumSourceIdentity, sampleRate = 48_000, channelCount = 2, chunkSamples = 24_000
        let delayMs: Int, failing: Set<Int>
        /// gateCalls: 그 차례(0부터)의 호출만 멈춤(release(call:)까지). ignoresCancellation: 멈춘 동안 취소를 보지 않음(협조하지 않는 원본 흉내)
        let gateCalls: Set<Int>?, ignoresCancellation: Bool
        let c = OSAllocatedUnfairLock(initialState: Counters())
        init(_ id: String = UUID().uuidString, delayMs: Int = 1, failing: Set<Int> = [], gated: Bool = false, gateCalls: Set<Int>? = nil, ignoresCancellation: Bool = false) {
            identity = SpectrumSourceIdentity(id); self.delayMs = delayMs; self.failing = failing; self.gateCalls = gateCalls; self.ignoresCancellation = ignoresCancellation
            if gated { c.withLock { $0.released = false } }
        }
        var decodes: Int { c.withLock { $0.decodes } }
        func release() { c.withLock { $0.released = true } }
        func release(call n: Int) { c.withLock { _ = $0.releasedCalls.insert(n) } }
        func decodeChunk(_ i: Int) async throws -> [[Float]] {
            let main = pthread_main_np() != 0, label = String(cString: __dispatch_queue_get_label(nil))
            let n: Int = c.withLock { $0.decodes += 1; $0.running += 1; $0.peakRunning = max($0.peakRunning, $0.running); if main { $0.onMain += 1 }; $0.labels.insert(label); return $0.decodes - 1 }
            defer { c.withLock { $0.running -= 1 } }
            func held() -> Bool { c.withLock { st in gateCalls.map { g in g.contains(n) && !st.releasedCalls.contains(n) } ?? !st.released } }
            while held() {
                if ignoresCancellation { try? await Task.sleep(nanoseconds: 1_000_000); continue }
                do { try await Task.sleep(nanoseconds: 1_000_000) } catch { c.withLock { $0.cancelledSeen += 1 }; throw error }
            }
            try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            if failing.contains(i) { throw SpectrumAnalysisError.decodeFailed("fake \(i)") }
            let x = (0..<chunkSamples).map { Float(0.2 * sin(2 * Double.pi * 1000 * Double(i * chunkSamples + $0) / 48_000)) }
            return [x, x]
        }
    }
    /// 완료 기록: 요청마다 정확히 한 번인지
    final class Log: Sendable {
        let l = OSAllocatedUnfairLock(initialState: [Int: [Result<[Float], SpectrumAnalysisError>]]())
        func add(_ i: Int, _ r: Result<[Float], SpectrumAnalysisError>) { l.withLock { $0[i, default: []].append(r) } }
        var all: [Int: [Result<[Float], SpectrumAnalysisError>]] { l.withLock { $0 } }
        func one(_ i: Int) -> Result<[Float], SpectrumAnalysisError>? { all[i]?.first }
    }
    func req(_ k: Int, settings: SpectrumAnalysisSettings = .init(), pieces: [SpectrumSourcePiece] = [SpectrumSourcePiece(start: 0, length: 100_000, sourceIn: 0)]) -> SpectrumFrameRequest {
        SpectrumFrameRequest(frame: k, fps: 30, settings: settings, pieces: pieces)
    }
    func waitIdle(_ s: SpectrumAnalysisScheduler, _ t: Double = 20) async {
        let end = Date().addingTimeInterval(t)
        while Date() < end { let x = s.statistics; if x.active == 0 && x.waiters == 0 && x.pendingJobs == 0 && x.runningJobs == 0 { return }; try? await Task.sleep(nanoseconds: 2_000_000) }
    }
    func waitCount(_ log: Log, _ n: Int, _ t: Double = 20) async -> Bool {
        let end = Date().addingTimeInterval(t)
        while Date() < end { if log.all.values.reduce(0, { $0 + $1.count }) >= n { return true }; try? await Task.sleep(nanoseconds: 2_000_000) }
        return false
    }

    func testCoalescingEqualRequestsAndSharedChunks() async {
        let s = SpectrumAnalysisScheduler(), p = FakePCM(), log = Log()
        for i in 0..<3 { s.request(req(30), from: p, priority: i) { log.add(i, $0) } }   // 같은 열쇠 셋 → 작업 하나
        for (i, b) in [16, 32, 64].enumerated() { s.request(req(30, settings: .init(bands: b)), from: p) { log.add(10 + i, $0) } }   // 설정이 다른 스펙트럼 셋, 같은 원본
        let done = await waitCount(log, 6)
        XCTAssertTrue(done)
        await waitIdle(s)
        let x = s.statistics
        XCTAssertEqual(x.analyses, 3, "같은 열쇠 요청은 분석 한 번(밴드 64는 위의 셋과 같은 열쇠) — 64·16·32")
        let chunks = try! SpectrumAnalysis.chunks(frame: 30, pieces: req(30).pieces, fps: 30, rate: 48_000, settings: .init(), chunkSamples: 24_000).count
        XCTAssertEqual(p.decodes, chunks, "설정이 달라도 같은 원본 덩어리는 한 번 디코딩")
        XCTAssertEqual(log.one(0).flatMap { try? $0.get() }, log.one(2).flatMap { try? $0.get() })
        XCTAssertTrue(log.all.values.allSatisfy { $0.count == 1 })
    }

    func testRapidSeeksBoundPendingConcurrencyAndSettleExactlyOnce() async {
        let lim = SpectrumSchedulerLimits(maxPending: 8, maxConcurrent: 2, chunkCacheBytes: 8 << 20, bandCacheEntries: 100)
        let s = SpectrumAnalysisScheduler(limits: lim), p = FakePCM(delayMs: 2), log = Log()
        var n = 0
        for i in 0..<500 {   // 빠른 탐색: 재생 헤드가 바뀔 때마다 앞쪽 프레임 넷
            let head = Int.random(in: 0..<3000)
            for d in 0..<4 { let id = n; s.request(req(head + d), from: p, priority: d) { log.add(id, $0) }; n += 1 }
            if i % 50 == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        let done = await waitCount(log, n, 60)
        XCTAssertTrue(done, "모든 요청이 끝남")
        await waitIdle(s)
        let all = log.all, x = s.statistics
        XCTAssertEqual(all.count, n); XCTAssertTrue(all.values.allSatisfy { $0.count == 1 }, "정확히 한 번")
        let ok = all.values.filter { if case .success = $0[0] { return true }; return false }.count
        let dropped = all.values.filter { $0[0] == .failure(.dropped) }.count
        XCTAssertEqual(ok + dropped, n, "결과 또는 버림만(오류 없음)")
        XCTAssertLessThanOrEqual(x.peakPending, 8); XCTAssertLessThanOrEqual(x.peakActive, 2)
        XCTAssertLessThanOrEqual(p.c.withLock { $0.peakRunning }, 2)
        XCTAssertLessThanOrEqual(x.peakChunkCacheBytes, (8 << 20) + 2 * 24_000 * 4)
        XCTAssertLessThanOrEqual(x.bandCacheEntries, 100)
        XCTAssertEqual(p.c.withLock { $0.onMain }, 0, "디코딩은 주 스레드에서 돌지 않음")
        print("SPECTRUM rapid seeks: requests \(n) ok \(ok) dropped \(dropped) decodes \(x.decodes) analyses \(x.analyses) peakPending \(x.peakPending) peakActive \(x.peakActive)")
    }

    func testCancellationSettlesAndReleases() async throws {
        let s = SpectrumAnalysisScheduler(limits: .init(maxPending: 8, maxConcurrent: 1)), p = FakePCM(gated: true), log = Log()
        let a = s.request(req(30), from: p, priority: 0) { log.add(0, $0) }    // 디코딩 시작(문에서 멈춤)
        let b = s.request(req(600), from: p, priority: 1) { log.add(1, $0) }   // 다른 덩어리, 기다림
        s.request(req(900), from: p, priority: 2) { log.add(2, $0) }
        s.cancel(b)
        let gotB = await waitCount(log, 1)
        XCTAssertTrue(gotB)
        XCTAssertEqual(log.one(1), .failure(.cancelled))
        XCTAssertEqual(s.statistics.pendingJobs, 2, "기다리는 쪽이 없는 작업은 버림(30 — 디코딩 기다림 — 과 900만 남음)")
        s.cancel(a)   // 디코딩 진행 중 작업의 유일한 요청 취소 → 알림은 바로, 작업은 버림
        s.cancel(a)   // 두 번째 취소는 아무 일 없음
        p.release()
        let all3 = await waitCount(log, 3)
        XCTAssertTrue(all3)
        await waitIdle(s)
        XCTAssertEqual(log.one(0), .failure(.cancelled))
        guard case .success = log.one(2) else { return XCTFail("\(String(describing: log.one(2)))") }
        XCTAssertTrue(log.all.values.allSatisfy { $0.count == 1 })
        XCTAssertEqual(s.statistics.waiters, 0)
        // async 형태: 작업 취소 → .cancelled
        let q = FakePCM(gated: true)
        let t = Task { try await s.bands(req(30), from: q) }
        try await Task.sleep(nanoseconds: 20_000_000)
        t.cancel()
        do { _ = try await t.value; XCTFail("not cancelled") } catch { XCTAssertEqual(error as? SpectrumAnalysisError, .cancelled) }
        q.release()
        await waitIdle(s)
        XCTAssertEqual(s.statistics.waiters, 0)
    }

    func testInvalidationDropsStaleCompletions() async {
        let s = SpectrumAnalysisScheduler(), p = FakePCM(gated: true), log = Log()
        for i in 0..<6 { s.request(req(i * 400), from: p, priority: i) { log.add(i, $0) } }
        try? await Task.sleep(nanoseconds: 20_000_000)   // 디코딩 둘 진행 중(문에서 멈춤)
        s.invalidateSession()
        let all = await waitCount(log, 6)
        XCTAssertTrue(all)
        XCTAssertTrue(log.all.values.allSatisfy { $0 == [.failure(.invalidated)] }, "모두 무효로 한 번")
        p.release()
        await waitIdle(s)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let x = s.statistics
        XCTAssertEqual(x.chunkCacheEntries, 0, "늦게 끝난 디코딩이 비운 캐시를 다시 채우지 않음")
        XCTAssertEqual(x.bandCacheEntries, 0)
        XCTAssertGreaterThanOrEqual(x.staleDecodes, 1)
        XCTAssertTrue(log.all.values.allSatisfy { $0.count == 1 }, "늦은 결과를 알리지 않음")
    }

    /// 시제품 결함 회귀: 세션을 바꾼 뒤 같은 덩어리를 다시 요청하면, 이전 세션의 디코딩이 끝나지 않아도(취소를 보지 않는 원본) 새로 디코딩해 끝나야 한다.
    /// 진행 중 디코딩을 덩어리만으로 구분하면(시제품처럼) 새 요청이 이전 디코딩을 기다려 이 시험은 3초 시간 초과로 실패한다(변이 검사로 확인, 문서 §11.1).
    func testNewSessionRequestDoesNotWaitForOldSessionDecode() async {
        let s = SpectrumAnalysisScheduler(limits: .init(maxPending: 8, maxConcurrent: 4))
        let p = FakePCM(gateCalls: [0], ignoresCancellation: true), log = Log()   // 프레임 7 = 덩어리 0 하나
        s.request(req(7), from: p) { log.add(0, $0) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        s.invalidateSession()
        s.request(req(7), from: p) { log.add(1, $0) }
        let both = await waitCount(log, 2, 3)
        XCTAssertTrue(both, "새 세션 요청이 이전 세션 디코딩(아직 멈춤)을 기다리지 않고 끝남")
        XCTAssertEqual(log.one(0), .failure(.invalidated))
        guard case .success = log.one(1) else { return XCTFail("\(String(describing: log.one(1)))") }
        XCTAssertEqual(s.statistics.retiredActive, 1, "멈춘 이전 세션 디코딩은 끝날 때까지 동시 수에 든다")
        p.release(call: 0)
        await waitIdle(s)
        let x = s.statistics
        XCTAssertGreaterThanOrEqual(x.staleDecodes, 1); XCTAssertEqual(x.retiredActive, 0)
        XCTAssertTrue(log.all.values.allSatisfy { $0.count == 1 })
    }

    /// 늦게 끝난 이전 세션 디코딩이 같은 열쇠의 새 작업을 없애거나 덮지 않는다: 새 작업은 자기 디코딩이 끝날 때 한 번만 끝난다.
    func testStaleCompletionDoesNotSettleOrReplaceNewerJob() async {
        let s = SpectrumAnalysisScheduler(limits: .init(maxPending: 8, maxConcurrent: 4))
        let p = FakePCM(gateCalls: [0, 1], ignoresCancellation: true), log = Log()
        s.request(req(7), from: p) { log.add(0, $0) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        s.invalidateSession()
        s.request(req(7), from: p) { log.add(1, $0) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        p.release(call: 0)   // 이전 세션 디코딩만 끝냄
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(log.one(1), "이전 세션 결과로 새 요청을 끝내지 않음")
        let mid = s.statistics
        XCTAssertEqual(mid.pendingJobs, 1, "새 작업이 그대로 남음"); XCTAssertEqual(mid.chunkCacheEntries, 0, "이전 결과를 캐시에 넣지 않음")
        p.release(call: 1)
        let done = await waitCount(log, 2)
        XCTAssertTrue(done)
        guard case .success = log.one(1) else { return XCTFail("\(String(describing: log.one(1)))") }
        await waitIdle(s)
        XCTAssertTrue(log.all.values.allSatisfy { $0.count == 1 })
    }

    /// 무효로 하면 진행 중 디코딩 작업을 취소한다(취소를 보는 원본은 멈춘 채 남지 않고 동시 자리가 빈다)
    func testInvalidationCancelsInFlightDecodes() async {
        let s = SpectrumAnalysisScheduler(), p = FakePCM(gated: true), log = Log()
        s.request(req(30), from: p) { log.add(0, $0) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(s.statistics.active, 2)
        s.invalidateSession()
        await waitIdle(s, 3)
        let x = s.statistics
        XCTAssertEqual(x.active, 0, "문을 열지 않아도 취소로 끝남"); XCTAssertEqual(p.c.withLock { $0.cancelledSeen }, 2)
        XCTAssertEqual(log.one(0), .failure(.invalidated))
    }

    /// 디코딩은 전용 작업자 큐에서 돈다(Swift 협력 스레드·주 스레드가 아님)
    func testDecodesRunOnDedicatedWorkerQueue() async {
        let s = SpectrumAnalysisScheduler(), p = FakePCM(), log = Log()
        for i in 0..<6 { s.request(req(i * 50), from: p) { log.add(i, $0) } }
        _ = await waitCount(log, 6)
        await waitIdle(s)
        XCTAssertEqual(p.c.withLock { $0.labels }, [SpectrumWorkExecutor.label])
        XCTAssertEqual(p.c.withLock { $0.onMain }, 0)
    }

    /// 합쳐진 호출 하나를 취소해도 나머지는 결과를 받는다. 등록 전에 취소된 async 호출도 정확히 한 번 .cancelled로 끝난다.
    func testCancellingOneCoalescedCallerKeepsOthersAndPreRegistrationCancel() async throws {
        let s = SpectrumAnalysisScheduler(), p = FakePCM(gated: true), log = Log()
        let a = s.request(req(30), from: p) { log.add(0, $0) }
        s.request(req(30), from: p) { log.add(1, $0) }
        s.request(req(30), from: p) { log.add(2, $0) }
        s.cancel(a)
        p.release()
        let done = await waitCount(log, 3)
        XCTAssertTrue(done)
        XCTAssertEqual(log.one(0), .failure(.cancelled))
        guard case .success(let v1) = log.one(1), case .success(let v2) = log.one(2) else { return XCTFail("\(log.all)") }
        XCTAssertEqual(v1, v2); XCTAssertEqual(s.statistics.analyses, 1)
        let q = FakePCM()
        let t = Task { () -> Result<[Float], Error> in
            withUnsafeCurrentTask { $0?.cancel() }   // 이 작업 안에서 bands를 부르기 전에 취소
            do { return .success(try await s.bands(req(99), from: q)) } catch { return .failure(error) }
        }
        let r = await t.value
        guard case .failure(let e) = r else { return XCTFail("not cancelled: \(r)") }
        XCTAssertEqual(e as? SpectrumAnalysisError, .cancelled)
        await waitIdle(s)
        XCTAssertEqual(s.statistics.waiters, 0)
        XCTAssertTrue(log.all.values.allSatisfy { $0.count == 1 })
    }

    func testWaiterLimitDropsNewCallers() async {
        let s = SpectrumAnalysisScheduler(limits: .init(maxWaiters: 3)), p = FakePCM(gated: true), log = Log()
        for i in 0..<5 { s.request(req(30), from: p) { log.add(i, $0) } }
        let two = await waitCount(log, 2)
        XCTAssertTrue(two)
        XCTAssertEqual(log.one(3), .failure(.dropped)); XCTAssertEqual(log.one(4), .failure(.dropped))
        XCTAssertEqual(s.statistics.waiters, 3); XCTAssertEqual(s.statistics.peakWaiters, 3)
        p.release()
        _ = await waitCount(log, 5)
        await waitIdle(s)
        XCTAssertTrue(log.all.values.allSatisfy { $0.count == 1 })
    }

    /// 범위 밖 값은 넘쳐 멈추지 않고 오류로 끝난다
    func testOutOfRangeRequestsFailWithoutTrapping() async {
        let s = SpectrumAnalysisScheduler(), p = FakePCM(), log = Log()
        s.request(SpectrumFrameRequest(frame: Int.max, fps: 30, pieces: []), from: p) { log.add(0, $0) }
        s.request(SpectrumFrameRequest(frame: 0, fps: Int.max, pieces: []), from: p) { log.add(1, $0) }
        s.request(SpectrumFrameRequest(frame: 0, fps: 30, pieces: [SpectrumSourcePiece(start: Int.min, length: 10, sourceIn: 0)]), from: p) { log.add(2, $0) }
        s.request(SpectrumFrameRequest(frame: 0, fps: 30, pieces: [SpectrumSourcePiece(start: 0, length: 10, sourceIn: 0, laneGain: .nan)]), from: p) { log.add(3, $0) }
        _ = await waitCount(log, 4)
        for i in 0..<4 { guard case .failure(.invalidRequest) = log.one(i) else { return XCTFail("\(i): \(String(describing: log.one(i)))") } }
        XCTAssertThrowsError(try SpectrumAnalysis.chunks(frame: Int.max, pieces: [], fps: 30, rate: 48_000, settings: .init(), chunkSamples: 24_000))
        XCTAssertNotNil(SpectrumAnalysisSettings(highHz: Int.max).validationError(rate: 48_000))
        XCTAssertNotNil(SpectrumAnalysisSettings(offsetMs: Int.min).validationError(rate: 48_000))
        XCTAssertNotNil(SpectrumAnalysisSettings().validationError(rate: Int.max))
    }

    func testDecodeFailureSettlesWaitersAndIsNotCached() async {
        let s = SpectrumAnalysisScheduler(), log = Log()
        let p = FakePCM(failing: [SpectrumFrameMap.sample(atFrame: 300, fps: 30, rate: 48_000) / 24_000])
        for i in 0..<3 { s.request(req(300), from: p) { log.add(i, $0) } }
        let done = await waitCount(log, 3)
        XCTAssertTrue(done)
        for i in 0..<3 { guard case .failure(.decodeFailed) = log.one(i) else { return XCTFail("\(String(describing: log.one(i)))") } }
        await waitIdle(s)
        let before = p.decodes
        s.request(req(300), from: p) { log.add(3, $0) }
        _ = await waitCount(log, 4)
        XCTAssertGreaterThan(p.decodes, before, "실패는 캐시하지 않음(다시 시도)")
        XCTAssertEqual(s.statistics.waiters, 0)
    }

    /// 캐시 열쇠: 원본 정체·설정·창에 드는 조각(이득 포함)이 다르면 다시 쓰지 않고, 창 밖 조각이 바뀌어도 같은 값을 다시 쓴다.
    func testCacheKeysSeparateSourceSettingsAndPieces() async throws {
        let s = SpectrumAnalysisScheduler(), p = FakePCM("same"), q = FakePCM("other")
        let full = SpectrumSourcePiece(start: 0, length: 300, sourceIn: 0), quiet = SpectrumSourcePiece(start: 0, length: 300, sourceIn: 0, audio: ClipAudio(volumePercent: 50))
        let a = try await s.bands(req(60, pieces: [full]), from: p)
        let b = try await s.bands(req(60, pieces: [quiet]), from: p)
        XCTAssertNotEqual(a, b, "클립 음량이 다르면 다른 값(다시 쓰지 않음)")
        let k = SpectrumAnalysis.bandIndex(ofHz: 1000, settings: .init())
        XCTAssertEqual(b[k] - a[k], Float(-6.0206 / 60), accuracy: 0.003)
        let c = try await s.bands(req(60, settings: .init(offsetMs: 40), pieces: [full]), from: p)
        XCTAssertEqual(s.statistics.bandCacheEntries, 3, "설정이 다르면 다른 항목")
        _ = c
        let before = s.statistics.analyses
        _ = try await s.bands(req(60, pieces: [full, SpectrumSourcePiece(start: 400, length: 20, sourceIn: 0)]), from: p)
        XCTAssertEqual(s.statistics.analyses, before, "창 밖 조각만 바뀌면 같은 열쇠(다시 씀)")
        let dq = q.decodes
        _ = try await s.bands(req(60, pieces: [full]), from: q)
        XCTAssertGreaterThan(q.decodes, dq, "원본 정체가 다르면 덩어리도 다시 디코딩")
        XCTAssertNotNil(s.cachedBands(req(60, pieces: [full]), from: p))
        XCTAssertNil(s.cachedBands(req(61, pieces: [full]), from: p))
    }

    /// 실제 파일로: 일정을 거친 값 = 바로 계산한 값, 덩어리 캐시는 바이트 상한 안(작은 상한으로 자주 다시 읽음), 섞은 순서와 같은 값.
    /// 프로세스 메모리는 기록만(짧은 실행 — 누수 없음의 증명이 아니다).
    func testRealFileThroughSchedulerMatchesDirectAndStaysInBudget() async throws {
        let fx = ExportEndToEndTests.root.appendingPathComponent("fixtures")
        try await DevFixtures.ensureAll(in: fx)
        let src = try await SpectrumFileSource.open(url: fx.appendingPathComponent("aud-steady48s.wav"), chunkSamples: 24_000, marginSamples: 4_800)
        let budget = 2 * 2 * 24_000 * 4   // 덩어리 둘
        let s = SpectrumAnalysisScheduler(limits: .init(maxPending: 64, maxConcurrent: 2, chunkCacheBytes: budget, bandCacheEntries: 0))
        let pieces = [SpectrumSourcePiece(start: 0, length: 180, sourceIn: 0)]
        var direct: [Int: [Float]] = [:]
        for f in [0, 7, 15, 16, 31, 89, 150, 179] {
            var d: [Int: [[Float]]] = [:]
            for c in try SpectrumAnalysis.chunks(frame: f, pieces: pieces, fps: 30, rate: 48_000, settings: .init(), chunkSamples: 24_000) { d[c] = try await src.decodeChunk(c) }
            direct[f] = try SpectrumAnalysis.bands(frame: f, pieces: pieces, fps: 30, rate: 48_000, channelCount: 2, chunkSamples: 24_000, settings: .init()) { d[$0] }
        }
        var rounds: [Double] = []
        for _ in 0..<3 {
            for f in direct.keys.shuffled() {
                let v = try await s.bands(SpectrumFrameRequest(frame: f, fps: 30, pieces: pieces), from: src)
                XCTAssertEqual(v, direct[f], "frame \(f)")
            }
            rounds.append(Self.footprintMB())
        }
        let x = s.statistics
        XCTAssertLessThanOrEqual(x.peakChunkCacheBytes, budget + 2 * 24_000 * 4)
        XCTAssertLessThanOrEqual(x.chunkCacheBytes, budget)
        print("SPECTRUM real file: decodes \(x.decodes) peakChunkCache \(x.peakChunkCacheBytes) footprint MB per round \(rounds.map { String(format: "%.1f", $0) })")
    }
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
