import AVFoundation
import E1Core
import E2Core
import Foundation
import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 입력 호환 확장(A-010): 30 fps가 아닌 원본(29.97·25·23.976·59.94, 가변 간격)을 30 fps 타임라인에서 시간 기준으로 쓴다.
/// 기대값은 엔진 코드가 아니라 fixture를 쓸 때 정한 표시 시각(PTS)과 클릭 샘플 위치에서 직접 계산한다:
/// 타임라인 프레임 k(클립 시작 st, 원본 위치 sourceIn) → 원본 시각 (sourceIn + k − st)/30 s → PTS ≤ 그 시각인 마지막 원본 프레임.
final class InputCompatibilityTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var out: URL!

    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        out = ExportEndToEndTests.root.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: out) }

    func inspect(_ fx: TimedFixture) async throws -> MediaAsset { try await MediaProbe.inspect(fixtures.appendingPathComponent(fx.file)) }

    /// 표시 시각 분석과 타임라인 프레임 수(손으로 계산한 값)
    func testProbeAnalysesNonThirtyTiming() async throws {
        let n = try await inspect(.ntsc), p = try await inspect(.pal), v = try await inspect(.vfr)
        let f = try await inspect(.film), h = try await inspect(.high)
        // 29.97: 120 × 1001/30000 = 4.004 s → 30 fps 프레임 120(120.12 내림)
        XCTAssertEqual(n.timing.detail, "30000/1001 fps CFR"); XCTAssertEqual(n.timing.label, "29.97 fps")
        XCTAssertEqual(n.timing.sampleCount, 120); XCTAssertEqual(n.frameCount, 120); XCTAssertFalse(n.timing.isVariable); XCTAssertTrue(n.hasAudio)
        // 25: 100 / 25 = 4 s → 120
        XCTAssertEqual(p.timing.detail, "25/1 fps CFR"); XCTAssertEqual(p.timing.label, "25 fps"); XCTAssertEqual(p.frameCount, 120)
        // 가변: 마지막 PTS = 89개 간격 합 = 17주기 × 125 + (10 + 20 + 30 + 25) + 멈춤 추가(180 − 10) = 2380/600 s,
        // 마지막 샘플 길이 = 직전 간격 25/600 → 2405/600 s = 4.0083 s → 120(120.25 내림)
        XCTAssertTrue(v.timing.isVariable); XCTAssertEqual(v.timing.sampleCount, 90); XCTAssertEqual(v.frameCount, 120)
        XCTAssertEqual(v.timing.minInterval, 10.0 / 600, accuracy: 1e-9); XCTAssertEqual(v.timing.maxInterval, 0.3, accuracy: 1e-9)
        XCTAssertTrue(v.timing.label.hasPrefix("가변"))
        // 23.976: 48 × 1001/24000 = 2.002 s → 60. 59.94 HEVC MOV: 120 × 1001/60000 = 2.002 s → 60
        XCTAssertEqual(f.timing.detail, "24000/1001 fps CFR"); XCTAssertEqual(f.timing.label, "23.976 fps"); XCTAssertEqual(f.frameCount, 60)
        XCTAssertEqual(h.timing.detail, "60000/1001 fps CFR"); XCTAssertEqual(h.codec, "hvc1"); XCTAssertEqual(h.frameCount, 60)
        // 30 fps 원본은 그대로
        let a = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-A.mp4"))
        XCTAssertEqual(a.timing.detail, "30/1 fps CFR"); XCTAssertEqual(a.frameCount, 120)
        // 기대값 함수 자체의 손 계산 확인: 29.97 원본 1.0 s → 프레임 29(30 × 1001/30000 = 1.001 > 1), 25 원본 1/30 s → 0, 1.0 s → 25
        XCTAssertEqual(TimedFixture.ntsc.frame(atTimelineUnits: 30), 29); XCTAssertEqual(TimedFixture.ntsc.frame(atTimelineUnits: 0), 0)
        XCTAssertEqual(TimedFixture.pal.frame(atTimelineUnits: 1), 0); XCTAssertEqual(TimedFixture.pal.frame(atTimelineUnits: 30), 25)
        // 가변: 프레임 50(PTS 1250/600 s)은 0.3 s 유지 → 타임라인 단위 63~71(= 1.25 s ~ 1.55 s 미만)에서 모두 50
        XCTAssertEqual((63..<72).map { TimedFixture.vfr.frame(atTimelineUnits: $0) }, Array(repeating: 50, count: 9))
        XCTAssertEqual(TimedFixture.vfr.frame(atTimelineUnits: 72), 51)
    }

    /// 자르기·트림·이동·일반 삭제(끝 빈틈) 뒤 내보낸 파일의 모든 프레임(정확한 30 fps PTS 격자), 클릭 위치(소리 동기),
    /// 프리뷰 경로 대 내보내기를 독립 기대값과 비교한다.
    func testNonThirtySourcesEditExportAndPreview() async throws {
        let n = try await inspect(.ntsc), p = try await inspect(.pal), v = try await inspect(.vfr)
        let f = try await inspect(.film), h = try await inspect(.high)
        let names = [n.id: TimedFixture.ntsc.file, p.id: TimedFixture.pal.file, v.id: TimedFixture.vfr.file, f.id: TimedFixture.film.file, h.id: TimedFixture.high.file]
        var t = Timeline().registering(n).registering(p).registering(v).registering(f).registering(h)
        // 첫 클립을 25 fps로 둔다: 끝 빈틈 채움은 첫 클립 원본을 쓰므로 30 fps가 아닌 원본으로 채울 때도 프레임 수가 맞아야 한다
        t = try t.inserting(media: p.id).inserting(media: n.id).inserting(media: v.id).inserting(media: f.id).inserting(media: h.id)
        t = try t.trimmingStart(clip: t.clips[0].id, by: 13)                   // P[13,120)
        t = try t.trimmingEnd(clip: t.clips[0].id, by: -20)                    // P[13,100) 87
        t = try t.splitting(clip: t.clips[1].id, atFrame: t.clips[1].start + 45)   // N[0,45), N[45,120)
        t = try t.trimmingStart(clip: t.clips[2].id, by: 7)                    // N[52,120) 68
        t = try t.splitting(clip: t.clips[3].id, atFrame: t.clips[3].start + 66)   // V[0,66), V[66,120): 멈춤(63~71) 안에서 자름
        t = try t.moving(clip: t.clips[4].id, toIndex: 1)                      // P, V[66,120), N…, V[0,66), F, H
        t = try t.trimmingStart(clip: t.clips[6].id, by: 9)                    // H[9,60) 51
        t = try t.lifting(clip: t.clips[6].id)                                 // 마지막 H 일반 삭제 → 끝 빈틈 51
        XCTAssertTrue(t.isValid)
        XCTAssertEqual(t.clips.map(\.length), [87, 54, 45, 68, 66, 60])
        XCTAssertEqual(t.durationFrames, 87 + 54 + 45 + 68 + 66 + 60 + 51)

        let media = [n.id: n, p.id: p, v.id: v, f.id: f, h.id: h]
        let plan = try await CompositionPlanner.plan(t, media: media)
        XCTAssertEqual(plan.settings.nearestFrame(plan.composition.duration), t.durationFrames)
        let dest = out.appendingPathComponent("mixed.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: Array(media.values)) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let refs = t.clips.map { ExportJudge.ClipRef(file: names[$0.mediaID]!, start: $0.start, sourceIn: $0.sourceIn, length: $0.length) }
        let verdict = try await ExportJudge.judge(dest, clips: refs, durationFrames: t.durationFrames)
        XCTAssertTrue(verdict.pass, "\(verdict)")
        XCTAssertEqual(verdict.frames, t.durationFrames)
        XCTAssertEqual(verdict.gapFrames, 51)
        XCTAssertEqual(verdict.expectedOnsets.count, 2 + 4 + 2 + 2 + 1 + 0, "clicks \(verdict.expectedOnsets)")   // P 2, V 4(뒤 2+앞 2), N 2+2, F 1
        print("mixed export onsets max error \(verdict.maxOnsetErrorSamples ?? -1) samples, boundaries \(verdict.boundaries.map { "\($0.frame):\($0.measured)" })")

        // 프리뷰 경로 대 내보내기: 각 컷 앞뒤, 가변 멈춤 안, 끝 빈틈
        let (expected, _) = try ExportJudge.expectations(refs, durationFrames: t.durationFrames)
        let s = t.clips.map(\.start)
        let probe = Array(Set([0, 30, s[1] - 1, s[1], s[1] + 5, s[2] - 1, s[2], s[3] - 1, s[3], s[4] + 64, s[4] + 65, s[5] - 1, s[5], s[5] + 59, s[5] + 60, t.durationFrames - 1])).sorted()
        let preview = try await PreviewProbe.frames(plan, at: probe)
        let exportPixels = try await FrameCompare.decode(dest, frames: Set(probe))
        let cmp = PreviewExportCompare.check(preview: preview, export: exportPixels, expected: expected, probes: probe)
        XCTAssertTrue(cmp.failures.isEmpty, cmp.failures.joined(separator: "; "))
        print("mixed preview/export PSNR: \(cmp.summary)")

        // 음성 대조: 원본 시각이 1타임라인 프레임(1/30 s) 어긋났다고 기대하면 실패해야 한다(판정이 무조건 통과하지 않음)
        var shifted = refs
        shifted[3] = .init(file: shifted[3].file, start: shifted[3].start, sourceIn: shifted[3].sourceIn + 1, length: shifted[3].length)
        let neg = try await ExportJudge.judge(dest, clips: shifted, durationFrames: t.durationFrames)
        XCTAssertFalse(neg.pass)
        // 음성 대조: 29.97 원본을 30 fps로 잘못 가정(원본 프레임 = 위치)하면 4.004 s 중 어긋나는 프레임이 생겨야 한다
        let naive = (0..<68).map { 52 + $0 }, timed = (0..<68).map { TimedFixture.ntsc.frame(atTimelineUnits: 52 + $0) }
        XCTAssertNotEqual(naive, timed)
    }

    /// 원본 보존: 가져오기·composition·내보내기 전후 원본 SHA-256이 같다
    func testTimedSourcesUnchanged() async throws {
        let urls = TimedFixture.all.map { fixtures.appendingPathComponent($0.file) }
        let before = try urls.map { try Hashing.sha256(file: $0) }
        let p = try await inspect(.pal), v = try await inspect(.vfr)
        let t = try Timeline().registering(p).registering(v).inserting(media: p.id).inserting(media: v.id)
        let plan = try await CompositionPlanner.plan(t, media: [p.id: p, v.id: v])
        let dest = out.appendingPathComponent("keep.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [p, v]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        XCTAssertEqual(try urls.map { try Hashing.sha256(file: $0) }, before)
    }
}
