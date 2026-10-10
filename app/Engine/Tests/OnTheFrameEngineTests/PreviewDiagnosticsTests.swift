import AVFoundation
import E2Core
import Foundation
import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// A-010 프리뷰 경로 프레임 0 불일치(1회: 기대 id71#10, 받음 id71#29) 진단. 원래 실패한 타임라인을 그대로 만들고
/// (1) 원본 파일 독립 디코딩, (2) composition 오프라인 렌더, (3) 원래 순서(내보내기 → 프리뷰 받기 → 내보낸 파일 디코딩 뒤 비교),
/// (4) 새 플레이어 항목 반복과 같은 항목 반복 탐색에서 프레임마다 진단 기록(항목, 요청·실제 시각, 탐색 완료, 받는 순간 코드·지문,
/// 나중 코드·지문)을 남긴다. 기록은 .build/test-work/diagnostics/에 JSON으로 둔다(실패해도 남김). 기대값은 바꾸지 않는다.
/// 실행: OTF_PREVIEW_DIAG=1 swift test --filter PreviewDiagnosticsTests. 받은 뒤 같은 시각 버퍼를 더 지켜보려면 OTF_DIAG_FOLLOWUP=초.
/// OTF_FRESH_FIXTURES=1이면 30 fps가 아닌 fixture를 새 폴더에 막 만들어 쓴다(원래 실패 직전 조건: fixture를 막 만든 상태).
final class PreviewDiagnosticsTests: XCTestCase {
    struct Probe: Codable { let pass: String; let record: PreviewProbe.Record; let expected: String; let laterLabel: String; let laterHash: UInt64 }
    struct Report: Codable {
        var fresh: Bool; var sourceDecode: String = ""; var offlineFrame0: String = ""; var probes: [Probe] = []
        var wrongAtAcquire = 0, changedAfterAcquire = 0, seekUnfinished = 0, missing = 0
    }

    /// 진단 실행은 선택 사항이다(OTF_PREVIEW_DIAG=1). 같은 불일치는 InputCompatibilityTests의 엄격한 검사가 늘 판정한다(숨기지 않음).
    @MainActor func testA010PreviewFrameZeroDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_PREVIEW_DIAG"] == "1", "진단 실행은 OTF_PREVIEW_DIAG=1일 때만")
        Spec4K.configure(.fhd)
        let fresh = ProcessInfo.processInfo.environment["OTF_FRESH_FIXTURES"] == "1"
        let base = ExportEndToEndTests.root
        let fx = fresh ? base.appendingPathComponent("fresh-\(UUID().uuidString)") : base.appendingPathComponent("fixtures")
        try await DevFixtures.ensureAll(in: base.appendingPathComponent("fixtures"))
        if fresh {
            try FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)
            for f in TimedFixture.all { try await DevFixtures.writeTimedForDiagnostics(f, to: fx.appendingPathComponent(f.file)) }
        }
        let out = base.appendingPathComponent("diag-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out); if fresh { try? FileManager.default.removeItem(at: fx) } }
        var report = Report(fresh: fresh)

        func ins(_ f: TimedFixture) async throws -> MediaAsset { try await MediaProbe.inspect(fx.appendingPathComponent(f.file)) }
        let n = try await ins(.ntsc), p = try await ins(.pal), v = try await ins(.vfr), f = try await ins(.film), h = try await ins(.high)
        let names = [n.id: TimedFixture.ntsc.file, p.id: TimedFixture.pal.file, v.id: TimedFixture.vfr.file, f.id: TimedFixture.film.file, h.id: TimedFixture.high.file]
        // 원래 실패한 테스트(testNonThirtySourcesEditExportAndPreview)와 같은 편집
        var t = Timeline().registering(n).registering(p).registering(v).registering(f).registering(h)
        t = try t.inserting(media: p.id).inserting(media: n.id).inserting(media: v.id).inserting(media: f.id).inserting(media: h.id)
        t = try t.trimmingStart(clip: t.clips[0].id, by: 13)
        t = try t.trimmingEnd(clip: t.clips[0].id, by: -20)
        t = try t.splitting(clip: t.clips[1].id, atFrame: t.clips[1].start + 45)
        t = try t.trimmingStart(clip: t.clips[2].id, by: 7)
        t = try t.splitting(clip: t.clips[3].id, atFrame: t.clips[3].start + 66)
        t = try t.moving(clip: t.clips[4].id, toIndex: 1)
        t = try t.trimmingStart(clip: t.clips[6].id, by: 9)
        t = try t.lifting(clip: t.clips[6].id)
        let media = [n.id: n, p.id: p, v.id: v, f.id: f, h.id: h]
        let plan = try await CompositionPlanner.plan(t, media: media)
        let refs = t.clips.map { ExportJudge.ClipRef(file: names[$0.mediaID]!, start: $0.start, sourceIn: $0.sourceIn, length: $0.length) }
        let (expected, _) = try ExportJudge.expectations(refs, durationFrames: t.durationFrames)
        XCTAssertEqual(expected[0].label, "id71#10")

        // (1) 원본 파일 독립 디코딩: P25 원본 시각 13/30 s에 표시 중인 프레임
        report.sourceDecode = try await Self.decodeSource(fx.appendingPathComponent(TimedFixture.pal.file), at: CMTime(value: 13, timescale: 30))
        // (2) composition 오프라인 렌더(AVAssetReaderVideoCompositionOutput) 타임라인 프레임 0
        report.offlineFrame0 = try await Self.renderOffline(plan, frame: 0)

        let s = t.clips.map(\.start)
        let probe = Array(Set([0, 30, s[1] - 1, s[1], s[1] + 5, s[2] - 1, s[2], s[3] - 1, s[3], s[4] + 64, s[4] + 65, s[5] - 1, s[5], s[5] + 59, s[5] + 60, t.durationFrames - 1])).sorted()
        func collect(_ pass: String, _ frames: [Int: PreviewProbe.Frame], _ wanted: [Int]) {
            for k in wanted {
                guard let fr = frames[k] else { report.missing += 1; continue }
                let later = ExportJudge.label(E2Metrics.measure(fr.pb)), lh = PreviewProbe.fingerprint(fr.pb)
                if fr.record.labelAtAcquire != expected[k].label { report.wrongAtAcquire += 1 }
                if later != fr.record.labelAtAcquire || lh != fr.record.hashAtAcquire { report.changedAfterAcquire += 1 }
                if !fr.record.seekFinished { report.seekUnfinished += 1 }
                report.probes.append(Probe(pass: pass, record: fr.record, expected: expected[k].label, laterLabel: later, laterHash: lh))
            }
        }
        // (3) 원래 순서: 내보내기 → 프리뷰 받기 → 내보낸 파일 디코딩 → 그 뒤에 프리뷰 버퍼를 잼
        let dest = out.appendingPathComponent("mixed.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: Array(media.values)) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let followUp = Double(ProcessInfo.processInfo.environment["OTF_DIAG_FOLLOWUP"] ?? "") ?? 0
        let originalSeq = try await PreviewProbe.framesSequence(plan, at: probe, followUpSeconds: followUp)
        var original: [Int: PreviewProbe.Frame] = [:]
        for (i, k) in probe.enumerated() { if let f = originalSeq[i] { original[k] = f } }
        _ = try await FrameCompare.decode(dest, frames: Set(probe))
        collect("original-order", original, probe)
        // (4) 새 플레이어 항목 4회, 같은 항목 반복 탐색(0으로 여러 번 돌아감)
        for r in 0..<4 { collect("fresh-item-\(r)", try await PreviewProbe.frames(plan, at: probe), probe) }
        let reseek = [0, 30, 0, s[1], 0, 0, t.durationFrames - 1, 0, 1, 0]
        var seq: [Int: PreviewProbe.Frame] = [:]
        // 같은 항목에서 같은 프레임을 여러 번 받으려면 한 번에 하나씩 받는다(사전 키가 겹치므로 항목을 새로 만들지 않는 별도 경로)
        let seqFrames = try await PreviewProbe.framesSequence(plan, at: reseek)
        for (i, fr) in seqFrames.enumerated() { seq[i] = fr }
        for (i, k) in reseek.enumerated() {
            guard let fr = seq[i] else { report.missing += 1; continue }
            let later = ExportJudge.label(E2Metrics.measure(fr.pb)), lh = PreviewProbe.fingerprint(fr.pb)
            if fr.record.labelAtAcquire != expected[k].label { report.wrongAtAcquire += 1 }
            if later != fr.record.labelAtAcquire || lh != fr.record.hashAtAcquire { report.changedAfterAcquire += 1 }
            if !fr.record.seekFinished { report.seekUnfinished += 1 }
            report.probes.append(Probe(pass: "same-item-reseek", record: fr.record, expected: expected[k].label, laterLabel: later, laterHash: lh))
        }

        // 기록 보존(통과·실패 모두)
        let dir = base.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        try enc.encode(report).write(to: dir.appendingPathComponent("preview-diag-\(stamp)-\(fresh ? "fresh" : "reused").json"))
        print("PREVIEWDIAG fresh=\(fresh) source=\(report.sourceDecode) offline0=\(report.offlineFrame0) probes=\(report.probes.count) wrongAtAcquire=\(report.wrongAtAcquire) changedAfterAcquire=\(report.changedAfterAcquire) seekUnfinished=\(report.seekUnfinished) missing=\(report.missing)")
        XCTAssertEqual(report.sourceDecode, "id71#10")
        XCTAssertEqual(report.offlineFrame0, "id71#10")
        XCTAssertEqual(report.wrongAtAcquire, 0, "\(report.probes.filter { $0.record.labelAtAcquire != $0.expected })")
        XCTAssertEqual(report.changedAfterAcquire, 0, "\(report.probes.filter { $0.laterLabel != $0.record.labelAtAcquire || $0.laterHash != $0.record.hashAtAcquire })")
        XCTAssertEqual(report.missing, 0)
    }

    /// 원본 파일에서 시각 t에 표시 중인 프레임(AVAssetImageGenerator, 허용 오차 0) → 화면 코드
    static func decodeSource(_ url: URL, at t: CMTime) async throws -> String {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let (img, _) = try await g.image(at: t)
        return ExportJudge.label(E2Metrics.measure(try bgra(img)))
    }
    /// composition을 오프라인으로 렌더해 타임라인 프레임 k를 읽는다
    static func renderOffline(_ p: PlannedComposition, frame k: Int) async throws -> String {
        let r = try AVAssetReader(asset: p.composition)
        let tracks = try await p.composition.loadTracks(withMediaType: .video)
        let o = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        o.videoComposition = p.videoComposition
        r.add(o)
        r.timeRange = CMTimeRange(start: p.settings.time(k), duration: p.settings.frameDuration)
        guard r.startReading(), let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return "unreadable" }
        r.cancelReading()
        return ExportJudge.label(E2Metrics.measure(pb))
    }
    static func bgra(_ img: CGImage) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, img.width, img.height, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { throw ProbeFailure("pb") }
        CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: img.width, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return pb
    }
}
