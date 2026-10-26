import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import os
import OTFDevSupport
import XCTest

/// 스펙트럼 프레임 조율(SP-1A 3A-2, 2026-10-26 — docs/SPECTRUM-DESIGN.md §15.13). 프리뷰·디스플레이 링크 없음.
/// 대응 시험은 합성 원본(TonePCM — 원본 1–2초에만 1000 Hz 진폭 0.5, 나머지 0)을 opener로 넣는다. 타임라인은 생성 fixture(aud-steady48s, 6초)를
/// 등록해 실제 모델 편집(자르기·옮기기·붙여넣기·소리 설정)으로 만든다. 오래된 결과 시험은 디코딩을 문(gate)으로 멈춰 결정적으로 만든다(시간 기다림에 기대지 않음).
final class SpectrumFrameCoordinatorTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var steady: MediaAsset!, wav: MediaAsset!
    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        steady = try await MediaProbe.inspect(fixtures.appendingPathComponent(AudioFixture.steady.file))
        wav = try await MediaProbe.inspect(fixtures.appendingPathComponent(AudioFixture.wav.file))
    }

    /// 합성 원본(모노 48 kHz, 덩어리 0.5초): 원본 표본 [48 000, 96 000) = 원본 프레임 30–60에만 1000 Hz 진폭 0.5. gated면 release까지 디코딩을 멈춘다.
    final class TonePCM: SpectrumPCMProvider {
        let identity: SpectrumSourceIdentity, sampleRate = 48_000, channelCount = 1, chunkSamples = 24_000
        let st = OSAllocatedUnfairLock(initialState: (gated: false, started: 0, decodes: 0))
        init(_ id: String = UUID().uuidString, gated: Bool = false) { identity = SpectrumSourceIdentity(id); st.withLock { $0.gated = gated } }
        var started: Int { st.withLock { $0.started } }
        var decodes: Int { st.withLock { $0.decodes } }
        func release() { st.withLock { $0.gated = false } }
        func decodeChunk(_ c: Int) async throws -> [[Float]] {
            st.withLock { $0.started += 1 }
            while st.withLock({ $0.gated }) {
                do { try await Task.sleep(nanoseconds: 1_000_000) } catch { throw SpectrumAnalysisError.cancelled }
            }
            st.withLock { $0.decodes += 1 }
            return [(0..<chunkSamples).map { i in
                let n = c * chunkSamples + i
                return (48_000..<96_000).contains(n) ? Float(0.5 * sin(2 * Double.pi * 1000 * Double(n) / 48_000)) : 0
            }]
        }
    }
    /// 요청마다 결과 기록(정확히 한 번인지)
    final class Log: Sendable {
        let l = OSAllocatedUnfairLock(initialState: [String: [SpectrumFrameOutcome]]())
        func add(_ k: String, _ o: SpectrumFrameOutcome) { l.withLock { $0[k, default: []].append(o) } }
        func all(_ k: String) -> [SpectrumFrameOutcome] { l.withLock { $0[k] ?? [] } }
        var total: Int { l.withLock { $0.values.reduce(0) { $0 + $1.count } } }
    }
    static func name(_ o: SpectrumFrameOutcome) -> String {
        switch o {
        case .ready: return "ready"
        case .notVisible: return "notVisible"
        case .itemMissing: return "itemMissing"
        case .unsetSource: return "unsetSource"
        case .missingSource: return "missingSource"
        case .overlap: return "overlap"
        case .mediaUnavailable: return "mediaUnavailable"
        case .superseded: return "superseded"
        case .cancelled: return "cancelled"
        case .dropped: return "dropped"
        case let .failed(f): return "failed(\(f))"
        }
    }
    static func bands(_ o: SpectrumFrameOutcome) -> [Float]? { if case let .ready(b, _) = o { return b }; return nil }
    let peak = SpectrumAnalysis.bandIndex(ofHz: 1000, settings: .init())
    let deliveries = DispatchQueue(label: "test.spectrum.delivery")

    func coordinator(_ p: TonePCM, opens: OSAllocatedUnfairLock<Int>? = nil) -> SpectrumFrameCoordinator {
        SpectrumFrameCoordinator(deliveryQueue: deliveries) { _ in opens?.withLock { $0 += 1 }; return p }
    }
    /// 소리 클립 w(기본 레인, 20에서 길이 180 → 소리는 타임라인 50–80) + 스펙트럼 레인의 스펙트럼(0–300, 소스 = w의 계보)
    func base() throws -> (t: Timeline, clip: UUID, spectrum: UUID, lane: UUID) {
        let w = UUID(), sl = UUID(), sid = UUID()
        var t = Timeline().registering(steady)
        t = try t.placing(media: steady.id, at: 20, videoLane: nil, audioLane: Lane.audioID, clipID: w)
        XCTAssertEqual(t.clip(w)?.length, 180, "fixture: steady 6초 = 180프레임")
        t = try t.addingLane(.spectrum, name: "SP", id: sl).addingSpectrum(lane: sl, at: 0, length: 300, sourceKey: t.clip(w)!.lineageKey, id: sid)
        return (t, w, sid, sl)
    }
    func get(_ c: SpectrumFrameCoordinator, _ id: UUID, _ n: Int, _ w: Int = 1920, _ h: Int = 1080) async -> SpectrumFrameOutcome {
        await withCheckedContinuation { k in c.request(spectrum: id, frame: n, canvasWidth: w, canvasHeight: h) { k.resume(returning: $0) } }
    }
    func until(_ t: Double = 20, _ f: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(t)
        while Date() < end { if f() { return true }; try? await Task.sleep(nanoseconds: 1_000_000) }
        return f()
    }
    /// 엔진 분석을 직접(같은 조각·설정, 합성 원본) — 조율이 같은 값을 내는지 비교용
    func direct(_ t: Timeline, _ sid: UUID, _ n: Int, _ p: TonePCM) async throws -> [Float] {
        let s = t.spectrum(sid)!, pieces = t.spectrumPieces(s), st = s.style.analysisSettings
        var d: [Int: [[Float]]] = [:]
        for c in try SpectrumAnalysis.chunks(frame: n, pieces: pieces, fps: 30, rate: 48_000, settings: st, chunkSamples: p.chunkSamples) { d[c] = try await p.decodeChunk(c) }
        return try SpectrumAnalysis.bands(frame: n, pieces: pieces, fps: 30, rate: 48_000, channelCount: 1, chunkSamples: p.chunkSamples, settings: st) { d[$0] }
    }
    func assertTone(_ o: SpectrumFrameOutcome, _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let b = Self.bands(o) else { return XCTFail("\(msg): \(Self.name(o))", file: file, line: line) }
        XCTAssertGreaterThan(b[peak], 0.8, msg, file: file, line: line)
        XCTAssertEqual(b.firstIndex(of: b.max()!), peak, "\(msg): 1000 Hz 밴드가 가장 큼", file: file, line: line)
    }
    func assertSilent(_ o: SpectrumFrameOutcome, _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .ready(b, f) = o else { return XCTFail("\(msg): \(Self.name(o))", file: file, line: line) }
        XCTAssertEqual(b.max(), 0, msg, file: file, line: line)
        XCTAssertNil(f, "\(msg): 디지털 무음은 그릴 범위 없음", file: file, line: line)
    }

    // MARK: 시간·소스 대응

    /// 손 계산 기대(그리기·분석 코드와 따로): 소리 = 원본 프레임 30–60 → 클립(20, 원본 0)에서 타임라인 50–80. 창 90 ms = ±2160 표본.
    /// 자르기(60) + 오른쪽 조각을 120으로 옮김 → 소리 50–60, 140–?(오른쪽 원본 40–60 → 120–140), 그 사이 무음. 복사한 소리는 새 계보라 원래 스펙트럼에 들지 않는다.
    func testFrameToSourceMappingSplitMoveCopyAndSilence() async throws {
        var (t, w, sid, _) = try base()
        let p = TonePCM(), c = coordinator(p)
        c.update(timeline: t, media: [steady])
        assertTone(await get(c, sid, 65), "소리 가운데")
        assertSilent(await get(c, sid, 35), "클립 안, 소리 앞(원본 0)")
        assertSilent(await get(c, sid, 10), "클립 앞 — 조각 없음")
        assertSilent(await get(c, sid, 48), "창 끝 78 960 < 소리 시작 80 000")
        guard let b49 = Self.bands(await get(c, sid, 49)) else { return XCTFail("49") }
        XCTAssertGreaterThan(b49.max()!, 0, "창이 소리 시작에 닿음(560표본)")
        assertSilent(await get(c, sid, 82), "창 시작 129 040 ≥ 소리 끝 128 000")
        // 자르기 + 옮기기
        let (l, r) = (UUID(), UUID())
        t = try t.splitting(clip: w, atFrame: 60, newIDs: (l, r)).relocating(clip: r, toStart: 120, lane: Lane.audioID)
        XCTAssertEqual(t.clip(r)?.sourceIn, 40)
        c.update(timeline: t, media: [steady])
        assertTone(await get(c, sid, 55), "왼쪽 조각(원본 35)")
        assertSilent(await get(c, sid, 90), "조각 사이 빈틈")
        assertTone(await get(c, sid, 130), "옮긴 오른쪽 조각(원본 50)")
        assertSilent(await get(c, sid, 145), "오른쪽 조각, 소리 뒤(원본 65)")
        for k in [55, 59, 61, 125, 130] {   // 엔진 분석과 같은 값(같은 조각·설정)
            let x = Self.bands(await get(c, sid, k)), y = try await direct(t, sid, k, p)
            XCTAssertEqual(x, y, "frame \(k) = SpectrumAnalysis.bands")
        }
        // 복사·붙여넣기(새 계보): 70에 붙인 왼쪽 조각 사본(원본 0–40 → 소리 100–110)
        let pasted = try t.pasting(try t.copying(clip: l), at: 70) { _ in "A2" }
        t = pasted.timeline
        let copyKey = t.clip(pasted.ids[l]!)!.lineageKey
        XCTAssertNotEqual(copyKey, t.clip(l)!.lineageKey)
        let sid2 = UUID(), sl2 = UUID()
        t = try t.addingLane(.spectrum, name: "SP2", id: sl2).addingSpectrum(lane: sl2, at: 0, length: 300, sourceKey: copyKey, id: sid2)
        c.update(timeline: t, media: [steady])
        assertSilent(await get(c, sid, 105), "원래 계보 스펙트럼은 사본 소리를 보지 않음")
        assertTone(await get(c, sid2, 105), "사본 계보 스펙트럼은 사본 소리")
        // 스펙트럼 구간이 소스 범위를 넘어도 됨(트림으로 0–300 — 소스 밖은 무음, 소리를 늘이거나 옮기지 않음)
        XCTAssertEqual(t.spectrum(sid)?.end, 300)
        assertSilent(await get(c, sid, 290), "소스 범위 밖")
    }

    /// 클립 음량·음소거·페이드, 레인 음량·음소거, 분석 오프셋: 엔진 이득 규칙 그대로(손 계산 + SpectrumAnalysis.bands와 같은 값)
    func testGainMuteFadeOffsetAndWindow() async throws {
        let (t, w, sid, _) = try base()
        let p = TonePCM(), c = coordinator(p)
        c.update(timeline: t, media: [steady])
        let got1_ = await get(c, sid, 65)
        let full = try XCTUnwrap(Self.bands(got1_))
        // 음량 50% = −6.02 dB → 값 0.1003 낮음(바닥 −60 dB)
        let half = try t.settingClipAudio(clip: w, volumePercent: 50)
        c.update(timeline: half, media: [steady])
        let got2_ = await get(c, sid, 65)
        let h = try XCTUnwrap(Self.bands(got2_))
        XCTAssertEqual(full[peak] - h[peak], Float(20 * log10(2.0) / 60), accuracy: 0.002)
        let laneHalf = try t.settingLaneAudio(Lane.audioID, volumePercent: 50)
        c.update(timeline: laneHalf, media: [steady])
        let got3_ = await get(c, sid, 65)
        XCTAssertEqual(Self.bands(got3_), h, "레인 음량 50% = 클립 음량 50%")
        for (name, x) in [("clip mute", try t.settingClipAudio(clip: w, muted: true)), ("lane mute", try t.settingLaneAudio(Lane.audioID, muted: true))] {
            c.update(timeline: x, media: [steady])
            assertSilent(await get(c, sid, 65), name)
        }
        // 페이드 인 60프레임(20–80): 엔진 분석과 같은 값, 페이드 없을 때보다 작음
        let fade = try t.settingClipAudio(clip: w, fadeInFrames: 60)
        c.update(timeline: fade, media: [steady])
        let got4_ = await get(c, sid, 65)
        let f = try XCTUnwrap(Self.bands(got4_))
        let got5_ = try await direct(fade, sid, 65, p)
        XCTAssertEqual(f, got5_)
        XCTAssertLessThan(f[peak], full[peak])
        // 분석 오프셋 +500 ms = 24 000표본 = 정확히 15프레임: 프레임 k = 오프셋 0의 k + 15
        var st = t.spectrum(sid)!.style; st.offsetMs = 500
        let off = try t.settingSpectrumStyle(sid, st)
        c.update(timeline: off, media: [steady])
        for k in [36, 40, 50, 64] {
            c.update(timeline: off, media: [steady]); let a = Self.bands(await get(c, sid, k))
            c.update(timeline: t, media: [steady]); let b = Self.bands(await get(c, sid, k + 15))
            XCTAssertEqual(a, b, "offset frame \(k)")
        }
        // 창 길이: 200 ms(±4800표본)이면 프레임 47(창 끝 75 200 + 4 800 = 80 000)은 아직 0, 48은 닿음
        var wide = t.spectrum(sid)!.style; wide.windowMs = 200
        c.update(timeline: try t.settingSpectrumStyle(sid, wide), media: [steady])
        assertSilent(await get(c, sid, 47), "넓은 창 끝 = 소리 시작(닿지 않음)")
        let got6_ = await get(c, sid, 48)
        XCTAssertGreaterThan(Self.bands(got6_)?.max() ?? 0, 0)
    }

    /// 소스 고르지 않음·지워짐·같은 계보 겹침·원본 없음·안 보임·항목 없음·원본 열기 실패: 분석하지 않고 그 상태로 끝남
    func testSourceStatesAndFailures() async throws {
        let (t, w, sid, sl) = try base()
        let p = TonePCM(), opens = OSAllocatedUnfairLock(initialState: 0), c = coordinator(p, opens: opens)
        func expect(_ x: Timeline, _ media: [MediaAsset], _ id: UUID, _ n: Int, _ want: String, _ msg: String) async {
            c.update(timeline: x, media: media)
            let got7_ = await get(c, id, n)
            XCTAssertEqual(Self.name(got7_), want, msg)
        }
        let unset = UUID()
        await expect(try t.addingSpectrum(lane: sl, at: 300, length: 10, sourceKey: nil, id: unset), [steady], unset, 305, "unsetSource", "소스 고르지 않음")
        await expect(try t.lifting(clip: w), [steady], sid, 65, "missingSource", "소스 지워짐")
        let (l, r) = (UUID(), UUID()), a3 = UUID()
        let ov = try t.splitting(clip: w, atFrame: 60, newIDs: (l, r)).addingLane(.audio, name: "A3", id: a3).relocating(clip: r, toStart: 50, lane: a3)
        await expect(ov, [steady], sid, 55, "overlap", "같은 계보 조각 겹침(D-S8)")
        await expect(t, [], sid, 65, "mediaUnavailable", "원본을 앱이 찾지 못함")
        await expect(t, [steady], sid, 400, "notVisible", "구간 밖")
        await expect(t, [steady], UUID(), 65, "itemMissing", "없는 항목")
        XCTAssertEqual(opens.withLock { $0 }, 0, "분석이 필요 없는 상태에서는 원본을 열지 않음")
        let bad = SpectrumFrameCoordinator(deliveryQueue: deliveries) { _ in throw SpectrumAnalysisError.noAudioTrack }
        bad.update(timeline: t, media: [steady])
        for n in [65, 66] {   // 두 번째는 다시 열지 않고 같은 실패
            let o = await get(bad, sid, n)
            guard case .failed(.source(.noAudioTrack)) = o else { XCTFail("open failure \(n): \(Self.name(o))"); continue }
        }
    }

    /// 밴드가 준비되면 3A-1 입구로 그린 프레임: 같은 밴드·모양을 따로 그린 것과 바이트가 같고, 뒤 요청에도 바뀌지 않는다
    func testReadyFrameMatchesFacadeAndStaysImmutable() async throws {
        let (t, _, sid, _) = try base()
        let p = TonePCM(), c = coordinator(p)
        c.update(timeline: t, media: [steady])
        guard case let .ready(b, f?) = await get(c, sid, 65) else { return XCTFail("ready frame") }
        let ref = try XCTUnwrap(try SpectrumFrameRenderer(width: 1920, height: 1080).render(bands: b, style: t.spectrum(sid)!.style))
        XCTAssertEqual(SpectrumFrameRendererTests.bytes(f.image), SpectrumFrameRendererTests.bytes(ref.image)); XCTAssertEqual(f.drawRect, ref.drawRect)
        let before = SpectrumFrameRendererTests.bytes(f.image)
        for k in [50, 55, 70, 75] { _ = await get(c, sid, k) }
        _ = await get(c, sid, 65, 3840, 2160)   // 캔버스 크기가 바뀌어 그리기 객체를 다시 만듦
        _ = await get(c, sid, 60)
        XCTAssertEqual(SpectrumFrameRendererTests.bytes(f.image), before, "앞서 받은 프레임 그대로")
        guard case let .ready(_, f4?) = await get(c, sid, 65, 3840, 2160) else { return XCTFail("4K") }
        XCTAssertEqual(f4.canvasWidth, 3840)
    }

    // MARK: 기다림·오래된 결과

    /// 디코딩이 멈춘 동안 결과 없음(기다림), 풀면 ready 한 번
    func testPendingUntilAnalysisCompletes() async throws {
        let (t, _, sid, _) = try base()
        let p = TonePCM(gated: true), c = coordinator(p), log = Log()
        c.update(timeline: t, media: [steady])
        c.request(spectrum: sid, frame: 65, canvasWidth: 1920, canvasHeight: 1080) { log.add("a", $0) }
        let started = await until { p.started > 0 }
        XCTAssertTrue(started)
        XCTAssertEqual(log.total, 0, "디코딩이 끝나지 않으면 알리지 않음")
        XCTAssertEqual(c.diagnostics.waiting, 1)
        p.release()
        let done = await until { log.total == 1 }
        XCTAssertTrue(done)
        assertTone(log.all("a")[0], "풀린 뒤")
        XCTAssertEqual(c.diagnostics.waiting, 0)
    }

    /// 분석 중 프로젝트 교체: 멈춘 디코딩이 끝나기 전에 superseded로 한 번, 풀린 뒤 아무것도 더 알리지 않음
    func testProjectReplacementDuringAnalysis() async throws {
        let (t, _, sid, _) = try base()
        let p = TonePCM(gated: true), c = coordinator(p), log = Log()
        c.update(timeline: t, media: [steady])
        c.request(spectrum: sid, frame: 65, canvasWidth: 1920, canvasHeight: 1080) { log.add("a", $0) }
        _ = await until { p.started > 0 }
        c.resetProject()
        let got = await until { log.total == 1 }
        XCTAssertTrue(got)
        XCTAssertEqual(Self.name(log.all("a")[0]), "superseded")
        p.release()
        _ = await until(5) { c.scheduler.statistics.active == 0 }
        XCTAssertEqual(log.all("a").count, 1, "정확히 한 번")
        let d = c.diagnostics
        XCTAssertEqual(d.epoch, 1); XCTAssertEqual(d.sources, 0); XCTAssertFalse(d.hasRenderer)
        // 같은 항목 ID라도 교체 뒤 새 프로젝트를 알리기 전에는 없는 항목
        let got8_ = await get(c, sid, 65)
        XCTAssertEqual(Self.name(got8_), "itemMissing")
        // 원본을 여는 중(일정에 아직 넣지 않은 요청)에 교체: 그 요청도 superseded로 한 번, 늦게 끝난 열기는 버림
        let gate = OSAllocatedUnfairLock(initialState: true)
        let slow = SpectrumFrameCoordinator(deliveryQueue: deliveries) { _ in
            while gate.withLock({ $0 }) { try await Task.sleep(nanoseconds: 1_000_000) }
            return TonePCM()
        }
        slow.update(timeline: t, media: [steady])
        slow.request(spectrum: sid, frame: 65, canvasWidth: 1920, canvasHeight: 1080) { log.add("open", $0) }
        _ = await until { slow.diagnostics.sources == 1 }
        slow.resetProject()
        let opening = await until(5) { log.all("open").count == 1 }
        XCTAssertTrue(opening, "여는 중 교체도 끝남")
        gate.withLock { $0 = false }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(log.all("open").map(Self.name), ["superseded"])
        XCTAssertEqual(slow.diagnostics.sources, 0, "교체 전 열기 결과는 넣지 않음")
    }

    /// 편집 종류마다(분석 중): 그 요청의 입력이 바뀌면 superseded(일정 취소 포함), 관계없는 스펙트럼 B의 요청은 그대로 ready.
    /// 스펙트럼을 옮기거나 트림해도 그 프레임이 보이고 소스·조각·모양이 같으면 같은 값이라 ready.
    func testEditsSupersedeOnlyAffectedRequests() async throws {
        let (t0, w, sid, sl) = try base()
        // B: 다른 레인의 사본(새 계보), 소리 100–110 → 스펙트럼 B(0–300)
        let pasted = try t0.pasting(try t0.copying(clip: w), at: 70) { _ in "A2" }
        let bClip = pasted.ids[w]!, sidB = UUID(), slB = UUID()
        let t = try pasted.timeline.addingLane(.spectrum, name: "SPB", id: slB).addingSpectrum(lane: slB, at: 0, length: 300, sourceKey: pasted.timeline.clip(bClip)!.lineageKey, id: sidB)
        var style = t.spectrum(sid)!.style; style.red = 10
        var analysis = t.spectrum(sid)!.style; analysis.bands = 32
        let relinked = wav.withID(steady.id)   // 같은 미디어 ID, 다른 파일(재연결)
        let cases: [(String, Timeline, [MediaAsset], String, Bool)] = [
            ("항목 삭제", try t.liftingSpectrum(sid), [steady], "superseded", true),
            ("트림 — 프레임 밖", try t.trimmingSpectrum(sid, start: 0, end: 60), [steady], "superseded", true),
            ("트림 — 프레임 안(같은 값)", try t.trimmingSpectrum(sid, start: 40, end: 120), [steady], "ready", true),
            ("옮기기 — 프레임 안(같은 값)", try t.relocatingSpectrum(sid, toStart: 10, lane: sl), [steady], "ready", true),
            ("소스 바꾸기", try t.settingSpectrumSource(sid, t.clip(bClip)!.lineageKey), [steady], "superseded", true),
            ("소스 조각 옮기기", try t.relocating(clip: w, toStart: 25, lane: Lane.audioID), [steady], "superseded", true),
            ("음량", try t.settingClipAudio(clip: w, volumePercent: 70), [steady], "superseded", true),
            ("페이드", try t.settingClipAudio(clip: w, fadeOutFrames: 30), [steady], "superseded", true),
            ("클립 음소거", try t.settingClipAudio(clip: w, muted: true), [steady], "superseded", true),
            ("모양(색)", try t.settingSpectrumStyle(sid, style), [steady], "superseded", true),
            ("분석 설정(밴드 수)", try t.settingSpectrumStyle(sid, analysis), [steady], "superseded", true),
            ("재연결(같은 ID, 다른 파일)", t, [relinked], "superseded", false),
        ]
        for (name, edited, media, want, bUnaffected) in cases {
            let p = TonePCM(gated: true), c = coordinator(p), log = Log()
            c.update(timeline: t, media: [steady])
            c.request(spectrum: sid, frame: 65, canvasWidth: 1920, canvasHeight: 1080) { log.add("a", $0) }
            c.request(spectrum: sidB, frame: 105, canvasWidth: 1920, canvasHeight: 1080) { log.add("b", $0) }
            _ = await until { p.started > 0 }
            c.update(timeline: edited, media: media)
            if want == "superseded" {   // 디코딩이 멈춘 채로 바로 끝남(완료를 기다리지 않음)
                let early = await until(5) { !log.all("a").isEmpty }
                XCTAssertTrue(early, "\(name): 멈춘 동안 superseded")
            }
            p.release()
            let done = await until { log.all("a").count == 1 && log.all("b").count == 1 }
            XCTAssertTrue(done, name)
            XCTAssertEqual(log.all("a").map(Self.name), [want], name)
            if bUnaffected { assertTone(log.all("b").first ?? .superseded, "\(name): 관계없는 B") }
            _ = await until(5) { c.scheduler.statistics.active == 0 && c.diagnostics.waiting == 0 }
            XCTAssertEqual(log.total, 2, "\(name): 요청마다 한 번")
        }
    }

    /// update의 미리 끝내기를 끈 채(취소가 일어나지 않은 경우를 흉내): 완료 때 입력 비교만으로 오래된 값을 ready로 알리지 않는다
    func testLateCompletionRejectedWithoutProactiveCancel() async throws {
        let (t, w, sid, _) = try base()
        let p = TonePCM(gated: true), c = coordinator(p), log = Log()
        c.supersedeOnUpdate = false
        c.update(timeline: t, media: [steady])
        c.request(spectrum: sid, frame: 65, canvasWidth: 1920, canvasHeight: 1080) { log.add("a", $0) }
        _ = await until { p.started > 0 }
        c.update(timeline: try t.settingClipAudio(clip: w, volumePercent: 40), media: [steady])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(log.total, 0, "미리 끝내기를 껐으므로 완료 전에는 알림 없음")
        p.release()
        _ = await until { log.total == 1 }
        XCTAssertEqual(log.all("a").map(Self.name), ["superseded"], "완료 때 입력이 달라 버림")
        XCTAssertEqual(c.scheduler.statistics.analyses, 1, "분석은 끝까지 돌았음(취소되지 않음)")
    }

    /// 취소: cancelled 한 번, 늦은 디코딩 완료는 알리지 않음
    func testCancellationDeliversOnce() async throws {
        let (t, _, sid, _) = try base()
        let p = TonePCM(gated: true), c = coordinator(p), log = Log()
        c.update(timeline: t, media: [steady])
        let tk = c.request(spectrum: sid, frame: 65, canvasWidth: 1920, canvasHeight: 1080) { log.add("a", $0) }
        _ = await until { p.started > 0 }
        c.cancel(tk)
        _ = await until { log.total == 1 }
        XCTAssertEqual(log.all("a").map(Self.name), ["cancelled"])
        p.release()
        _ = await until(5) { c.scheduler.statistics.active == 0 }
        c.cancel(tk)   // 이미 끝난 요청: 아무 일 없음
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(log.total, 1)
        // 원본을 여는 중에 취소(opener가 끝나기 전)
        let slow = SpectrumFrameCoordinator(deliveryQueue: deliveries) { _ in try await Task.sleep(nanoseconds: 100_000_000); return TonePCM() }
        slow.update(timeline: t, media: [steady])
        let tk2 = slow.request(spectrum: sid, frame: 65, canvasWidth: 1920, canvasHeight: 1080) { log.add("b", $0) }
        slow.cancel(tk2)
        _ = await until { log.all("b").count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.all("b").map(Self.name), ["cancelled"], "열기가 끝나도 더 알리지 않음")
    }

    /// 캐시: 같은 입력은 다시 분석하지 않고 같은 값, 입력이 바뀌면 다시 계산(옛 값을 쓰지 않음), 되돌리면 캐시 값
    func testCacheReuseWithoutStaleValues() async throws {
        let (t, w, sid, _) = try base()
        let p = TonePCM(), c = coordinator(p)
        c.update(timeline: t, media: [steady])
        let a = Self.bands(await get(c, sid, 65))
        let n1 = c.scheduler.statistics.analyses
        let got9_ = await get(c, sid, 65)
        XCTAssertEqual(Self.bands(got9_), a)
        XCTAssertEqual(c.scheduler.statistics.analyses, n1, "같은 입력: 밴드 캐시")
        c.update(timeline: try t.settingClipAudio(clip: w, volumePercent: 50), media: [steady])
        let b = Self.bands(await get(c, sid, 65))
        XCTAssertNotEqual(a, b, "음량이 바뀐 입력은 새로 계산")
        XCTAssertEqual(c.scheduler.statistics.analyses, n1 + 1)
        let decodes = p.decodes
        c.update(timeline: t, media: [steady])
        let got10_ = await get(c, sid, 65)
        XCTAssertEqual(Self.bands(got10_), a, "되돌리면 처음 값")
        XCTAssertEqual(c.scheduler.statistics.analyses, n1 + 1, "되돌린 입력은 캐시")
        XCTAssertEqual(p.decodes, decodes, "덩어리도 다시 디코딩하지 않음")
    }

    // MARK: 프레임 경계·프레임레이트(2026-10-27, §15.13.1)

    /// 보임 경계와 소리·겹침 경계(30 fps 타임라인 격자, 손 계산). 1프레임 = 1600표본(48 kHz), 창 90 ms = ±2160표본.
    func testVisibilityAndBoundaryFrames() async throws {
        let (t, w, sid, _) = try base()
        let p = TonePCM(), c = coordinator(p)
        func name(_ x: Timeline, _ n: Int) async -> SpectrumFrameOutcome { c.update(timeline: x, media: [steady]); return await get(c, sid, n) }
        // 보임 [start, end): 트림 [40, 90) → 39 안 보임, 40·89 보임, 90 안 보임. 보이는 프레임 값은 트림 전과 같음(소리 대응은 스펙트럼 구간과 무관).
        let trimmed = try t.trimmingSpectrum(sid, start: 40, end: 90)
        for (n, want) in [(39, "notVisible"), (40, "ready"), (89, "ready"), (90, "notVisible")] {
            let o = await name(trimmed, n)
            XCTAssertEqual(Self.name(o), want, "trim [40,90) frame \(n)")
            if want == "ready" { let full = await name(t, n); XCTAssertEqual(Self.bands(o), Self.bands(full), "frame \(n) 값 = 트림 전") }
        }
        // 소리 구간 [50, 80)과 같은 스펙트럼 구간: 49 안 보임, 50 첫 프레임(창 [77 840, 82 160) — 소리 2160표본) > 0, 79 > 0, 80 안 보임
        let tone = try t.trimmingSpectrum(sid, start: 50, end: 80)
        for (n, want) in [(49, "notVisible"), (80, "notVisible")] { let o = await name(tone, n); XCTAssertEqual(Self.name(o), want, "tone span \(n)") }
        for n in [50, 79] { let o = await name(tone, n); XCTAssertGreaterThan(Self.bands(o)?.max() ?? 0, 0, "tone span \(n)") }
        // 무음 경계(스펙트럼 [45, 55)): 48 = 0(창 끝 78 960 < 80 000), 49 > 0
        let near = try t.trimmingSpectrum(sid, start: 45, end: 55)
        assertSilent(await name(near, 48), "48")
        let o49 = await name(near, 49); XCTAssertGreaterThan(Self.bands(o49)?.max() ?? 0, 0)
        // 같은 계보 겹침: 왼쪽 [20, 60) + 오른쪽을 다른 레인 50으로 → 겹침 [50, 60).
        // 분석 창이 겹침에 닿는 프레임(손 계산): 1600k + 2160 > 80 000 → k ≥ 49, 1600k − 2160 < 96 000 → k ≤ 61.
        // spectrumFrameState 여유 m = ⌈45·30/1000⌉ + 1 = 3 → [n−3, n+4)가 [50, 60)과 겹치면 겹침 → 47…62(보수적으로 2프레임 넓음).
        let (l, r) = (UUID(), UUID()), a3 = UUID()
        let ov = try t.splitting(clip: w, atFrame: 60, newIDs: (l, r)).addingLane(.audio, name: "A3", id: a3).relocating(clip: r, toStart: 50, lane: a3)
        let s = ov.spectrum(sid)!, pieces = ov.spectrumPieces(s)
        for k in 44...65 {
            let analysisOverlap: Bool
            do { _ = try SpectrumAnalysis.chunks(frame: k, pieces: pieces, fps: 30, rate: 48_000, settings: s.style.analysisSettings, chunkSamples: 24_000); analysisOverlap = false }
            catch SpectrumAnalysisError.overlappingPieces { analysisOverlap = true }
            XCTAssertEqual(analysisOverlap, (49...61).contains(k), "분석 창 겹침 frame \(k)")
            let o = await name(ov, k)
            XCTAssertEqual(Self.name(o), (47...62).contains(k) ? "overlap" : "ready", "조율 frame \(k)")
        }
        // 트림으로 겹침 앞부분을 보이지 않게: 보임이 먼저(54 안 보임, 55 겹침)
        let cut = try ov.trimmingSpectrum(sid, start: 55, end: 300)
        let o54 = await name(cut, 54), o55 = await name(cut, 55)
        XCTAssertEqual(Self.name(o54), "notVisible"); XCTAssertEqual(Self.name(o55), "overlap")
    }

    /// 타임라인 격자는 30 fps뿐이다(MediaProbe 소리 프레임 수·ProjectFile 렌더 설정·spectrumFrameState 여유가 30). 조율에 다른 fps를 주면
    /// 모든 요청을 원본을 열지 않고 invalidRequest로 거부한다(30 fps 프레임을 다른 fps로 잘못 읽지 않음). 크기는 조율이 쓰지 않으므로 상관없다.
    func testUnsupportedFrameRateRejected() async throws {
        let (t, _, sid, _) = try base()
        for settings in [RenderSettings.m1, RenderSettings(width: 3840, height: 2160, fps: 30)] {
            let c = SpectrumFrameCoordinator(settings: settings, deliveryQueue: deliveries) { _ in TonePCM() }
            c.update(timeline: t, media: [steady])
            assertTone(await get(c, sid, 65), "fps 30 (\(settings.width)×\(settings.height))")
        }
        for fps: Int32 in [60, 24, 25, 29, 0] {
            let opens = OSAllocatedUnfairLock(initialState: 0)
            let c = SpectrumFrameCoordinator(settings: RenderSettings(fps: fps), deliveryQueue: deliveries) { _ in opens.withLock { $0 += 1 }; return TonePCM() }
            c.update(timeline: t, media: [steady])
            for n in [65, 400] {
                let o = await get(c, sid, n)
                print("SPECTRUM fps \(fps) frame \(n): \(Self.name(o)) peak band \(Self.bands(o).map { $0.firstIndex(of: $0.max()!) ?? -1 } ?? -1) max \(Self.bands(o)?.max() ?? -1)")
                guard case .failed(.analysis(.invalidRequest)) = o else { XCTFail("fps \(fps) frame \(n): \(Self.name(o))"); continue }
            }
            XCTAssertEqual(opens.withLock { $0 }, 0, "fps \(fps): 원본을 열지 않음")
        }
    }

    // MARK: 실제 파일·재연결

    /// 기본 opener(SpectrumFileSource, 생성 WAV 440 Hz): 엔진 직접 분석과 같은 값. 재연결(같은 ID, 일회용 복사본)은 다른 원본 열쇠로 다시 열고 옛 원본을 놓는다.
    func testRealFileSourceAndRelink() async throws {
        let w = UUID(), sl = UUID(), sid = UUID()
        var t = Timeline().registering(wav)
        t = try t.placing(media: wav.id, at: 20, videoLane: nil, audioLane: Lane.audioID, clipID: w)
        t = try t.addingLane(.spectrum, name: "SP", id: sl).addingSpectrum(lane: sl, at: 0, length: 120, sourceKey: t.clip(w)!.lineageKey, id: sid)
        let c = SpectrumFrameCoordinator(deliveryQueue: deliveries)
        c.update(timeline: t, media: [wav])
        let got11_ = await get(c, sid, 45)
        let got = try XCTUnwrap(Self.bands(got11_))
        let src = try await SpectrumFileSource.open(url: wav.url, mediaID: wav.id)
        let s = t.spectrum(sid)!, pieces = t.spectrumPieces(s), st = s.style.analysisSettings
        var d: [Int: [[Float]]] = [:]
        for k in try SpectrumAnalysis.chunks(frame: 45, pieces: pieces, fps: 30, rate: 48_000, settings: st, chunkSamples: src.chunkSamples) { d[k] = try await src.decodeChunk(k) }
        XCTAssertEqual(got, try SpectrumAnalysis.bands(frame: 45, pieces: pieces, fps: 30, rate: 48_000, channelCount: 2, chunkSamples: src.chunkSamples, settings: st) { d[$0] })
        XCTAssertEqual(got.firstIndex(of: got.max()!), SpectrumAnalysis.bandIndex(ofHz: 440, settings: st), "440 Hz")
        // 재연결: 일회용 폴더의 복사본(원본 fixture는 건드리지 않음)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otf-coord-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("relinked.wav")
        try FileManager.default.copyItem(at: wav.url, to: copy)
        let moved = try await MediaProbe.inspect(copy).withID(wav.id)
        c.update(timeline: t, media: [moved])
        let got12_ = await get(c, sid, 45)
        XCTAssertEqual(Self.bands(got12_), got, "같은 내용의 재연결 파일: 같은 값")
        XCTAssertEqual(c.diagnostics.sources, 1, "옛 위치의 원본은 놓음")
    }
}
