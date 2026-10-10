import AVFoundation
import E2Core
import Foundation
import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 영상·원본 소리 레인 분리(A-012) 내보내기·프리뷰 판정. 기대값은 fixture를 쓸 때 정한 화면 코드·클릭 위치에서 직접 계산한다
/// (ExportJudge: 영상 레인 배치 → 원본 프레임, 소리 레인 배치 → 클릭 위치·빈틈 무음).
final class LaneExportTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var out: URL!
    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        out = ExportEndToEndTests.root.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: out) }

    /// 연결된 쌍을 자르고, 오른쪽 쌍의 연결을 해제해 소리만 +15프레임 옮긴다(빈틈으로). TB는 소리만 일반 삭제.
    /// 영상: TA#0–59 @0, TA#60–119 @60, TB#0–89 @120. 소리: TA[0,60) @0, 빈틈 [60,75), TA[60,120) @75, 빈틈 [135,210).
    func testUnlinkedOffsetAudioExportAndCompositionAudio() async throws {
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        let tb = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TB.mp4"))
        var t = Timeline().registering(ta).registering(tb)
        t = try t.inserting(media: ta.id).inserting(media: tb.id)
        XCTAssertEqual(t.audioClips.count, 2)
        let right = UUID()
        t = try t.splitting(clip: t.clips[0].id, atFrame: 60, newIDs: (UUID(), right))
        let rightAudio = try XCTUnwrap(t.partner(of: right)).id
        t = try t.unlinking(clip: right)
        let tbAudio = try XCTUnwrap(t.partner(of: t.clips[2].id)).id
        t = try t.unlinking(clip: tbAudio).lifting(clip: tbAudio)          // TB 소리만 지움
        // 연결된 쌍이었다면 막혔을 겹침: 소리를 [70,130)으로 옮기면 겹치지 않음, [−]는 거부
        XCTAssertThrowsError(try t.movingFree(clip: rightAudio, toStart: 30))   // 왼쪽 TA 소리 [0,60)과 겹침
        t = try t.movingFree(clip: rightAudio, toStart: 75)
        XCTAssertEqual(t.audioClips.map { [$0.start, $0.sourceIn, $0.length] }, [[0, 0, 60], [75, 60, 60]])
        XCTAssertEqual(t.durationFrames, 210); XCTAssertTrue(t.isValid)

        let plan = try await CompositionPlanner.plan(t, media: [ta.id: ta, tb.id: tb])
        XCTAssertEqual(plan.settings.nearestFrame(plan.composition.duration), 210)
        let dest = out.appendingPathComponent("lanes.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [ta, tb]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let video: [ExportJudge.ClipRef] = [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 60), .init(file: "otf-TA.mp4", start: 60, sourceIn: 60, length: 60),
                                            .init(file: "otf-TB.mp4", start: 120, sourceIn: 0, length: 90)]
        let audio: [ExportJudge.ClipRef] = [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 60), .init(file: "otf-TA.mp4", start: 75, sourceIn: 60, length: 60)]
        let v = try await ExportJudge.judge(dest, clips: video, audioClips: audio, durationFrames: 210, toneCheck: true)
        XCTAssertTrue(v.pass, "\(v)")
        // 손 계산: TA 클릭 원본 프레임 30, 50 → 첫 소리 클립 [0,60): 30·50 / 75, 100 → 둘째 클립(원본 60~) @75: 75+15=90, 75+40=115
        XCTAssertEqual(v.expectedOnsets, [30, 50, 90, 115].map { $0 * DevFixtures.samplesPerFrame })
        print("lane export: onsets max error \(v.maxOnsetErrorSamples ?? -1), gap rms \(v.gapRMSMax ?? -1), clip rms \(v.clipRMSMin ?? -1)")
        // 음성 대조: 소리를 옮기지 않았다고(연결된 위치 @60) 기대하면 판정이 실패한다
        let wrong = try await ExportJudge.judge(dest, clips: video, audioClips: [audio[0], .init(file: "otf-TA.mp4", start: 60, sourceIn: 60, length: 60)],
                                                durationFrames: 210, toneCheck: true)
        XCTAssertFalse(wrong.pass)

        // 프리뷰와 같은 composition의 소리(오프라인으로 읽음)의 클릭 위치도 같은 기대값
        let mono = try await Self.compositionMono(plan)
        let onsets = E2Decoder.onsets(mono)
        XCTAssertEqual(onsets.count, 4)
        XCTAssertTrue(zip(onsets, v.expectedOnsets).allSatisfy { abs($0 - $1) <= 96 }, "composition onsets \(onsets)")
        // 프리뷰 경로 영상: 경계 프레임
        let (expected, _) = try ExportJudge.expectations(video, durationFrames: 210)
        let probe = [0, 59, 60, 119, 120, 209]
        let preview = try await PreviewProbe.frames(plan, at: probe)
        let exportPixels = try await FrameCompare.decode(dest, frames: Set(probe))
        let cmp = PreviewExportCompare.check(preview: preview, export: exportPixels, expected: expected, probes: probe)
        XCTAssertTrue(cmp.failures.isEmpty, cmp.failures.joined(separator: "; "))
    }

    /// 소리 레인만 남은 타임라인(영상 쌍의 영상을 연결 해제 뒤 일반 삭제): 영상은 검정, 소리는 그대로.
    func testAudioOnlyRemainingExportsBlackWithSound() async throws {
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        var t = try Timeline().registering(ta).inserting(media: ta.id)
        let vid = t.clips[0].id
        t = try t.unlinking(clip: vid).lifting(clip: vid)
        XCTAssertTrue(t.clips.isEmpty); XCTAssertEqual(t.audioClips.count, 1); XCTAssertFalse(t.isEmpty)
        let plan = try await CompositionPlanner.plan(t, media: [ta.id: ta])
        let dest = out.appendingPathComponent("audio-only.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [ta]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let v = try await ExportJudge.judge(dest, clips: [], audioClips: [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 120)], durationFrames: 120, toneCheck: true)
        XCTAssertTrue(v.pass, "\(v)")
        XCTAssertEqual(v.gapFrames, 120)
    }

    /// composition 소리를 48 kHz 모노 float로 읽는다(프리뷰가 재생하는 것과 같은 composition)
    static func compositionMono(_ p: PlannedComposition) async throws -> [Float] {
        let r = try AVAssetReader(asset: p.composition)
        let tracks = try await p.composition.loadTracks(withMediaType: .audio)
        let o = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        r.add(o)
        guard r.startReading() else { throw ProbeFailure("audio reader") }
        var mono: [Float] = []
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            mono += chunk
        }
        return mono
    }
}
