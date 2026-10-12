import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// `ClipAudioTests.testPreviewAndExportFollowHandEnvelope`의 "reopened mix identical"(간헐 실패, D-033) 진단. 그 테스트와 같은 생성 fixture·배치로
/// 원래 계획과 저장·다시 연 계획을 만들고, 매번 새 AVAssetReader로 디코딩해 짝마다 비교한다. 판정(단언)은 하지 않고 기록만 남긴다.
/// 기록: .build/test-work/diagnostics/clipaudio-*.txt. 실행: OTF_CLIPAUDIO_DIAG=1 swift test --filter ClipAudioDiagnosticsTests
/// (OTF_CLIPAUDIO_ROUNDS=라운드 수, 기본 4). 원래 테스트의 단언은 그대로다.
final class ClipAudioDiagnosticsTests: XCTestCase {
    typealias Stereo = AudioMixExportTests.Stereo
    var lines: [String] = []
    func log(_ s: String) { lines.append(s); print("CADIAG \(s)") }

    struct Diff { var count = 0, first = -1, last = -1, nonFinite = 0; var max: Float = 0; var lenA = 0, lenB = 0 }
    func diff(_ a: [Float], _ b: [Float]) -> Diff {
        var d = Diff(); d.lenA = a.count; d.lenB = b.count
        for i in 0..<min(a.count, b.count) {
            if !a[i].isFinite || !b[i].isFinite { d.nonFinite += 1 }
            let e = abs(a[i] - b[i])
            if a[i].bitPattern != b[i].bitPattern { d.count += 1; if d.first < 0 { d.first = i }; d.last = i; d.max = max(d.max, e) }
        }
        return d
    }
    func describe(_ name: String, _ x: Stereo, _ y: Stereo) -> Bool {
        let l = diff(x.l, y.l), r = diff(x.r, y.r)
        let same = l.count == 0 && r.count == 0 && l.lenA == l.lenB && r.lenA == r.lenB
        func f(_ d: Diff) -> String {
            d.count == 0 ? "same(len \(d.lenA)/\(d.lenB) nonFinite \(d.nonFinite))"
                : "diff \(d.count) samples [\(d.first)…\(d.last)] frames \(String(format: "%.2f…%.2f", Double(d.first) / 1_600, Double(d.last) / 1_600)) max \(d.max) len \(d.lenA)/\(d.lenB) nonFinite \(d.nonFinite)"
        }
        log("\(name): L \(f(l)) | R \(f(r))\(same ? " IDENTICAL" : "")")
        return same
    }
    /// 오디오 믹스 없이(트랙을 그대로 섞음, 음량 1) 읽기: 원본 디코딩·composition 구간과 음량 경사를 가른다
    func decodeNoMix(_ p: PlannedComposition) async throws -> Stereo {
        let r = try AVAssetReader(asset: p.composition)
        let o = AVAssetReaderAudioMixOutput(audioTracks: try await p.composition.loadTracks(withMediaType: .audio), audioSettings: AudioMixExportTests.pcmSettings)
        r.add(o)
        return try AudioMixExportTests.read(r, o)
    }
    /// 출력 지문(FNV-1a, 왼쪽 채널 비트): 서로 다른 출력이 몇 가지인지 센다
    func hash(_ x: Stereo) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for v in x.l { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
        return String(h & 0xFFFFFF, radix: 16)
    }
    /// 트랙 하나만(그 트랙의 믹스 매개변수와 함께) 읽기
    func decodeTrack(_ p: PlannedComposition, _ id: CMPersistentTrackID) async throws -> Stereo {
        let r = try AVAssetReader(asset: p.composition)
        let tracks = try await p.composition.loadTracks(withMediaType: .audio).filter { $0.trackID == id }
        let o = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: AudioMixExportTests.pcmSettings)
        if let mix = p.audioMix {
            let m = AVMutableAudioMix(); m.inputParameters = mix.inputParameters.filter { $0.trackID == id }; o.audioMix = m
        }
        r.add(o)
        return try AudioMixExportTests.read(r, o)
    }
    func structure(_ name: String, _ p: PlannedComposition) async throws -> String {
        var out: [String] = []
        for t in try await p.composition.loadTracks(withMediaType: .audio) {
            let segs = try await t.load(.segments).map { s in
                "\(s.isEmpty ? "empty" : "src")[\(s.timeMapping.target.start.seconds)+\(s.timeMapping.target.duration.seconds) <- \(s.timeMapping.source.start.seconds)]"
            }
            out.append("track \(t.trackID): \(segs.joined(separator: " "))")
        }
        for ip in p.audioMix?.inputParameters ?? [] {
            var ramps: [String] = []
            var t = CMTime.zero
            let end = CMTime(value: 200, timescale: 30)
            while t < end {
                var a: Float = 0, b: Float = 0, tr = CMTimeRange.invalid
                if ip.getVolumeRamp(for: t, startVolume: &a, endVolume: &b, timeRange: &tr), tr.isValid {
                    ramps.append(String(format: "[%.4f+%.4f %.6f→%.6f]", tr.start.seconds, tr.duration.seconds, a, b))
                    t = tr.end > t ? tr.end : t + CMTime(value: 1, timescale: 30)
                } else { t = t + CMTime(value: 1, timescale: 30) }
            }
            out.append("mix track \(ip.trackID): \(ramps.joined(separator: " "))")
        }
        let s = out.joined(separator: "\n  ")
        log("\(name) structure:\n  \(s)")
        return s
    }

    /// 가설 확인(2라운드째 추가): 차이가 난 트랙(페이드 아웃이 든 트랙)만 여러 번 읽고, 읽기 버퍼의 경계(표시 시각·표본 수)를 함께 남긴다.
    /// 출력이 다른 실행끼리 버퍼 경계도 다른지, 차이가 시작하는 표본이 버퍼 경계와 맞는지 본다.
    func testFadeTrackChunkingDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_CLIPAUDIO_DIAG"] == "1", "진단 실행은 OTF_CLIPAUDIO_DIAG=1일 때만")
        let runs = Int(ProcessInfo.processInfo.environment["OTF_CLIPAUDIO_ROUNDS"] ?? "") ?? 8
        let c = ClipAudioTests()
        let s = try await c.steady()
        let t = try c.layout(s)
        let plate = try await MediaProbe.inspect(c.fixtures.appendingPathComponent(PlateFixture.blue.file))
        let tv = try t.registering(plate).placing(media: plate.id, at: 0, videoLane: Lane.videoID, audioLane: nil)
            .placing(media: plate.id, at: 90, videoLane: Lane.videoID, audioLane: nil)
        let plan = try await CompositionPlanner.plan(tv, media: [s.id: s, plate.id: plate])
        // 페이드 아웃(끝 값 0)이 든 믹스 트랙
        guard let fadeParams = plan.audioMix?.inputParameters.first(where: { ip in
            var a: Float = 0, b: Float = 0, r = CMTimeRange.invalid
            return ip.getVolumeRamp(for: CMTime(value: 80, timescale: 30), startVolume: &a, endVolume: &b, timeRange: &r) && a > 0 && b == 0
        }) else { return XCTFail("no fade-out track") }
        let id = fadeParams.trackID
        log("fade-out track \(id)")
        func read() async throws -> (Stereo, [String]) {
            let r = try AVAssetReader(asset: plan.composition)
            let tracks = try await plan.composition.loadTracks(withMediaType: .audio).filter { $0.trackID == id }
            let o = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: AudioMixExportTests.pcmSettings)
            let m = AVMutableAudioMix(); m.inputParameters = [fadeParams]; o.audioMix = m
            r.add(o)
            guard r.startReading() else { throw ProbeFailure("reader") }
            var st = Stereo(), chunks: [String] = []
            while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
                let n = CMBlockBufferGetDataLength(bb) / 4
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                chunks.append("\(Int((pts.seconds * 48_000).rounded()))+\(n / 2)")
                var chunk = [Float](repeating: 0, count: n)
                _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
                var i = 0
                while i + 1 < n { st.l.append(chunk[i]); st.r.append(chunk[i + 1]); i += 2 }
            }
            return (st, chunks)
        }
        if ProcessInfo.processInfo.environment["OTF_CLIPAUDIO_EXPORT"] == "1" {   // 원래 테스트처럼 먼저 내보내기(AVAssetExportSession)를 한 번 돌린다
            let out = ExportEndToEndTests.root.appendingPathComponent("diag-ca-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: out) }
            log("export first: \(await ExportService.export(plan, to: .fromSavePanel(out.appendingPathComponent("x.mp4")), sources: [s, plate]) { _ in })")
        }
        let (ref, refChunks) = try await read()
        log("reference chunks (start sample + count, from sample 110000): \(refChunks.filter { (Int($0.split(separator: "+")[0]) ?? 0) >= 110_000 }.joined(separator: " "))")
        var same = 0, different = 0, layoutDiffers = 0
        let interleave = ProcessInfo.processInfo.environment["OTF_CLIPAUDIO_INTERLEAVE"] == "1"
        for k in 1...runs {
            if interleave { _ = try await AudioMixExportTests.decodePreview(plan) }   // 전체 믹스 읽기를 끼워 프로세스 상태를 바꾼다
            let (x, ch) = try await read()
            let ok = describe("fade track run \(k) vs reference", x, ref)
            if ok { same += 1 } else { different += 1 }
            if ch != refChunks { layoutDiffers += 1; log("  run \(k) chunk layout differs: \(ch.filter { (Int($0.split(separator: "+")[0]) ?? 0) >= 110_000 }.joined(separator: " "))") }
            if !ok {
                // 차이가 난 표본들: 처음 몇 개의 값과 기대 경사 값(0.2 사인 × 0.4 × (90 − f)/15)
                let d = diff(x.l, ref.l)
                var maxUlp: UInt32 = 0, sameSign = true
                for i in d.first...d.last where x.l[i].bitPattern != ref.l[i].bitPattern {
                    if (x.l[i] < 0) != (ref.l[i] < 0) { sameSign = false }
                    let u = x.l[i].bitPattern > ref.l[i].bitPattern ? x.l[i].bitPattern - ref.l[i].bitPattern : ref.l[i].bitPattern - x.l[i].bitPattern
                    maxUlp = max(maxUlp, u)
                }
                log("  max ULP distance \(maxUlp) sameSign \(sameSign) first differing sample \(d.first) (chunk starts at 121152 and 129344 in reference)")
                for i in [d.first, d.first + 1, 130_000, 140_000, d.last] where i >= 0 && i < x.l.count {
                    log(String(format: "  sample %d: run %.9g ref %.9g diff %.3g", i, x.l[i], ref.l[i], x.l[i] - ref.l[i]))
                }
            }
        }
        log("=== fade track: identical \(same) / different \(different) of \(runs); chunk layout differs in \(layoutDiffers)")
        let dir = ExportEndToEndTests.root.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("clipaudio-chunks-\(Int(Date().timeIntervalSince1970)).txt"), atomically: true, encoding: .utf8)
    }

    func testReopenedMixDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_CLIPAUDIO_DIAG"] == "1", "진단 실행은 OTF_CLIPAUDIO_DIAG=1일 때만")
        let rounds = Int(ProcessInfo.processInfo.environment["OTF_CLIPAUDIO_ROUNDS"] ?? "") ?? 4
        let c = ClipAudioTests()
        let s = try await c.steady()
        let t = try c.layout(s)
        let plate = try await MediaProbe.inspect(c.fixtures.appendingPathComponent(PlateFixture.blue.file))
        let tv = try t.registering(plate).placing(media: plate.id, at: 0, videoLane: Lane.videoID, audioLane: nil)
            .placing(media: plate.id, at: 90, videoLane: Lane.videoID, audioLane: nil)
        let media = [s.id: s, plate.id: plate]
        let (back, _) = try ProjectFile.decode(try ProjectFile.encode(tv, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil))

        // 1. 모델·경사 값(저장 전·뒤)
        log("timeline equal after round trip: \(back == tv)")
        for lane in tv.lanes where lane.kind == .audio {
            let a = CompositionPlanner.volumeRamps(tv.clips(inLane: lane.id), lane: lane)
            let b = back.laneInfo(lane.id).map { CompositionPlanner.volumeRamps(back.clips(inLane: lane.id), lane: $0) }
            log("lane \(lane.name) ramps equal \(a == b) tracks \(CompositionPlanner.volumeTracks(tv.clips(inLane: lane.id), lane: lane).map(\.count))")
        }
        if back != tv {
            for (x, y) in zip(tv.audioClips.sorted { $0.id.uuidString < $1.id.uuidString }, back.audioClips.sorted { $0.id.uuidString < $1.id.uuidString }) where x != y {
                log("clip differs: \(x) vs \(y)")
            }
            log("lanes equal \(tv.lanes == back.lanes) media equal \(tv.media == back.media)")
        }

        // 2. 계획 구조(트랙·구간·믹스 경사)
        let vplan = try await CompositionPlanner.plan(tv, media: media)
        let bplan = try await CompositionPlanner.plan(back, media: media)
        let sv = try await structure("original plan", vplan)
        let sb = try await structure("reopened plan", bplan)
        log("structure identical: \(sv == sb)")

        // 3. 원래 테스트 순서 재현(프리뷰 → 내보내기 → 다시 연 계획 디코딩 → 원래 계획 디코딩)
        let plan0 = try await CompositionPlanner.plan(t, media: [s.id: s])
        _ = try await AudioMixExportTests.decodePreview(plan0)
        let out = ExportEndToEndTests.root.appendingPathComponent("diag-ca-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = await ExportService.export(vplan, to: .fromSavePanel(out.appendingPathComponent("x.mp4")), sources: [s, plate]) { _ in }
        log("export outcome \(outcome)")
        let bp0 = try await AudioMixExportTests.decodePreview(bplan)
        let vp0 = try await AudioMixExportTests.decodePreview(vplan)
        _ = describe("test-order reopened vs original (the failing comparison)", bp0, vp0)

        // 4. 라운드마다 새 디코딩: 같은 계획 두 번, 다시 연 계획 두 번, 새로 만든 계획, 믹스 없이, 트랙별
        let trackIDs = try await vplan.composition.loadTracks(withMediaType: .audio).map(\.trackID)
        var tally: [String: (same: Int, diff: Int)] = [:]
        func note(_ k: String, _ same: Bool) { var v = tally[k] ?? (0, 0); if same { v.same += 1 } else { v.diff += 1 }; tally[k] = v }
        for round in 1...rounds {
            log("--- round \(round)")
            let v1 = try await AudioMixExportTests.decodePreview(vplan)
            let v2 = try await AudioMixExportTests.decodePreview(vplan)
            let b1 = try await AudioMixExportTests.decodePreview(bplan)
            let b2 = try await AudioMixExportTests.decodePreview(bplan)
            let vfresh = try await AudioMixExportTests.decodePreview(try await CompositionPlanner.plan(tv, media: media))
            log("hashes v1 \(hash(v1)) v2 \(hash(v2)) b1 \(hash(b1)) b2 \(hash(b2)) vfresh \(hash(vfresh)) testOrder vp0 \(hash(vp0)) bp0 \(hash(bp0))")
            note("original twice", describe("original plan decoded twice", v1, v2))
            note("reopened twice", describe("reopened plan decoded twice", b1, b2))
            note("reopened vs original", describe("reopened vs original", b1, v1))
            note("fresh original plan vs original", describe("freshly planned original vs original", vfresh, v1))
            note("vs test-order original", describe("original now vs test-order original", v1, vp0))
            let n1 = try await decodeNoMix(vplan), n2 = try await decodeNoMix(vplan), nb = try await decodeNoMix(bplan)
            note("no-mix original twice", describe("no audio mix: original twice", n1, n2))
            note("no-mix reopened vs original", describe("no audio mix: reopened vs original", nb, n1))
            for id in trackIDs {
                let a = try await decodeTrack(vplan, id), b = try await decodeTrack(vplan, id), r = try await decodeTrack(bplan, id)
                log("track \(id) hashes a \(hash(a)) b \(hash(b)) r \(hash(r))")
                note("track \(id) original twice", describe("track \(id) with mix: original twice", a, b))
                note("track \(id) reopened vs original", describe("track \(id) with mix: reopened vs original", r, a))
            }
        }
        log("=== tally (identical / different) over \(rounds) rounds")
        for (k, v) in tally.sorted(by: { $0.key < $1.key }) { log("\(k): \(v.same) / \(v.diff)") }

        let dir = ExportEndToEndTests.root.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("clipaudio-\(Int(Date().timeIntervalSince1970)).txt")
        try lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        print("CADIAG report \(f.path)")
    }
}
