import AVFoundation
import CoreVideo
import E2Core
import Foundation
import OTFDevSupport
import OnTheFrameEngine

// 개발 검증 도구(앱 번들에 들어가지 않음).
//   otf-dev fixtures <dir>        생성 fixture를 dir에 만든다(있으면 그대로)
//   otf-dev verify <selftest-dir> 앱 자체 검사 결과(selftest-result.json)와 내보낸 파일의 프레임·소리를 판정하고 verify-result.json을 쓴다
//   otf-dev verify-preview <dir>  편집 뒤 프리뷰 갱신 자체 검사(preview-manifest.json)의 저장 프레임을 화면 코드·검정으로 판정한다
let args = CommandLine.arguments
guard args.count == 3 || (args.count > 2 && args[1] == "probe-timing") else { print("usage: otf-dev fixtures <dir> | verify <selftest-dir>"); exit(2) }
let dir = URL(fileURLWithPath: args[2], isDirectory: true)

struct ManifestExport: Codable { let exportFile: String; let clips: [ExportJudge.ClipRef]; let durationFrames: Int? }
struct Manifest: Codable { let fps: Int32; let exportFile: String; let clips: [ExportJudge.ClipRef]; let durationFrames: Int?; let timedExport: ManifestExport? }
struct Check: Codable { let name: String; let pass: Bool; let detail: String }
struct SelfTestResult: Codable { let sandboxContainer: Bool; let checks: [Check]; let tempLocations: [String] }
struct Output: Codable { let selfTestPass: Bool; let failedChecks: [String]; let export: ExportJudge.Verdict?; let timedExport: ExportJudge.Verdict?; let pass: Bool }

func report(_ name: String, _ v: ExportJudge.Verdict, audio: Bool = true) {
    print("\(name):", v.pass ? "PASS" : "FAIL", "frames \(v.frames)/\(v.expectedFrames)", v.dimensions, v.codec, v.audioFormat)
    for b in v.boundaries { print("  boundary", b.frame, "expected", b.expected, "measured", b.measured, b.pass ? "ok" : "MISMATCH") }
    if audio { print("  onsets expected", v.expectedOnsets, "measured", v.measuredOnsets, "max error", v.maxOnsetErrorSamples.map(String.init) ?? "-") }
    if !v.mismatchedFrames.isEmpty { print("  mismatched frames", v.mismatchedFrames) }
    if !v.notes.isEmpty { print("  notes", v.notes) }
}

struct PreviewStep: Codable { let name: String; let file: String?; let expected: String; let playhead: Int; let generation: Int; let applied: Int }
struct PreviewManifest: Codable { let width: Int; let height: Int; let steps: [PreviewStep]; let checks: [Check] }

switch args[1] {
case "verify-preview":
    Spec4K.configure(.fhd)
    let m = try JSONDecoder().decode(PreviewManifest.self, from: Data(contentsOf: dir.appendingPathComponent("preview-manifest.json")))
    var fails = 0
    for c in m.checks { print(c.pass ? "PASS" : "FAIL", c.name, c.detail.isEmpty ? "" : "— \(c.detail)"); if !c.pass { fails += 1 } }
    for st in m.steps {
        guard let f = st.file, let data = try? Data(contentsOf: dir.appendingPathComponent("preview").appendingPathComponent(f)) else {
            print("FAIL frame", st.name, "no frame"); fails += 1; continue
        }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, m.width, m.height, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { fails += 1; continue }
        CVPixelBufferLockBaseAddress(pb, [])
        let bpr = CVPixelBufferGetBytesPerRow(pb), base = CVPixelBufferGetBaseAddress(pb)!
        data.withUnsafeBytes { src in for y in 0..<m.height { memcpy(base + y * bpr, src.baseAddress! + y * m.width * 4, m.width * 4) } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let got = ExportJudge.label(E2Metrics.measure(pb))
        let ok = got == st.expected
        if !ok { fails += 1 }
        print(ok ? "PASS" : "FAIL", "frame", st.name, "expected", st.expected, "got", got, "gen \(st.applied)/\(st.generation)")
    }
    print(fails == 0 ? "OVERALL PASS" : "OVERALL FAIL")
    exit(fails == 0 ? 0 : 1)
case "verify-layer":
    // A-010 프레임 0 진단: 앱이 저장한 비디오 출력·레이어 프레임의 화면 코드. 기대값은 원본 PTS에서 직접(25 fps 원본 시각 13/30 s).
    Spec4K.configure(.fhd)
    struct LEntry: Codable { let cycle: Int; let kind: String; let tMs: Int; let displayTime: String?; let file: String; let fingerprint: UInt64; let readyForDisplay: Bool? }
    struct LManifest: Codable { let entries: [LEntry]; let notes: [String] }
    struct LRow: Codable { let cycle: Int; let kind: String; let tMs: Int; let displayTime: String?; let label: String; let readyForDisplay: Bool? }
    let lm = try JSONDecoder().decode(LManifest.self, from: Data(contentsOf: dir.appendingPathComponent("layer-manifest.json")))
    let want = String(format: "id%02X#%d", TimedFixture.pal.spec.idCode, TimedFixture.pal.frame(atTimelineUnits: 13))
    var rows: [LRow] = []
    for e in lm.entries {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("layerdiag").appendingPathComponent(e.file)) else { continue }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { continue }
        CVPixelBufferLockBaseAddress(pb, [])
        let bpr = CVPixelBufferGetBytesPerRow(pb), base = CVPixelBufferGetBaseAddress(pb)!
        data.withUnsafeBytes { s in for y in 0..<1080 { memcpy(base + y * bpr, s.baseAddress! + y * 1920 * 4, 1920 * 4) } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        rows.append(LRow(cycle: e.cycle, kind: e.kind, tMs: e.tMs, displayTime: e.displayTime, label: ExportJudge.label(E2Metrics.measure(pb)), readyForDisplay: e.readyForDisplay))
    }
    for c in Set(rows.map(\.cycle)).sorted() {
        for k in ["output", "layer"] {
            let seq = rows.filter { $0.cycle == c && $0.kind == k }.map { "\($0.label)@\($0.tMs)ms" }
            print("cycle \(c) \(k):", seq.isEmpty ? "-" : seq.joined(separator: " → "), "(expected \(want))")
        }
    }
    for n in lm.notes { print("note:", n) }
    let mismatch = rows.contains { $0.label != want }
    let enc2 = JSONEncoder(); enc2.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc2.encode(rows).write(to: dir.appendingPathComponent("layer-result.json"))
    print(mismatch ? "MISMATCH SEEN" : "ALL EXPECTED")
case "verify-lanes", "verify-project":
    // verify-project(A-013): 다시 연 프로젝트의 내보내기를 같은 독립 판정으로 본다(project-result.json, project-manifest.json)
    let stem = args[1] == "verify-project" ? "project" : "lane"
    // A-012 레인 자체 검사의 내보내기: 영상 레인 배치 → 원본 프레임, 소리 레인 배치 → 클릭 위치·빈틈 무음(독립 기대값)
    struct LRef: Codable { let file: String; let start: Int; let sourceIn: Int; let length: Int }
    struct LaneManifest: Codable { let exportFile: String; let clips: [LRef]; let audioClips: [LRef]; let durationFrames: Int }
    struct LCheck: Codable { let name: String; let pass: Bool; let detail: String }
    let checks = try JSONDecoder().decode([LCheck].self, from: Data(contentsOf: dir.appendingPathComponent("\(stem)-result.json")))
    for c in checks { print(c.pass ? "PASS" : "FAIL", c.name, c.detail.isEmpty ? "" : "— \(c.detail)") }
    var ok = checks.allSatisfy(\.pass) && !checks.isEmpty
    if let md = try? Data(contentsOf: dir.appendingPathComponent("\(stem)-manifest.json")) {
        let m = try JSONDecoder().decode(LaneManifest.self, from: md)
        let ref = { (r: LRef) in ExportJudge.ClipRef(file: r.file, start: r.start, sourceIn: r.sourceIn, length: r.length) }
        let v = try await ExportJudge.judge(dir.appendingPathComponent(m.exportFile), clips: m.clips.map(ref), audioClips: m.audioClips.map(ref),
                                            durationFrames: m.durationFrames, toneCheck: true)
        report("\(stem) export", v)
        ok = ok && v.pass
    } else { print("\(stem) export: no manifest"); ok = false }
    print(ok ? "OVERALL PASS" : "OVERALL FAIL")
    exit(ok ? 0 : 1)
case "verify-multilane":
    // A-014 여러 레인 자체 검사: multilane-result.json(앱 검사)과 multilane-manifest.json(레인 배치)의 내보내기를 MultiLaneJudge로 판정
    struct MCheck: Codable { let name: String; let pass: Bool; let detail: String }
    let checks = try JSONDecoder().decode([MCheck].self, from: Data(contentsOf: dir.appendingPathComponent("multilane-result.json")))
    for c in checks { print(c.pass ? "PASS" : "FAIL", c.name, c.detail.isEmpty ? "" : "— \(c.detail)") }
    var ok = checks.allSatisfy(\.pass) && !checks.isEmpty
    if let md = try? Data(contentsOf: dir.appendingPathComponent("multilane-manifest.json")) {
        let m = try JSONDecoder().decode(MultiLaneJudge.Manifest.self, from: md)
        let r = try await MultiLaneJudge.judge(dir.appendingPathComponent(m.exportFile), m)
        report("multilane export video", r.video, audio: false)
        print("  audio onsets expected", r.expectedOnsets, "measured", r.measuredOnsets, "max error", r.maxOnsetError.map(String.init) ?? "-")
        for t in r.tones { print("  tone", t.file, "lane", t.lane, String(format: "expected %.3f measured %.4f", t.expected, t.measured), t.pass ? "ok" : "MISMATCH") }
        print("  audio tracks in MP4:", r.audioTracks)
        print("multilane export:", r.pass ? "PASS" : "FAIL")
        ok = ok && r.pass
    } else { print("multilane export: no manifest"); ok = false }
    print(ok ? "OVERALL PASS" : "OVERALL FAIL")
    exit(ok ? 0 : 1)
case "verify-editfix":
    // 2026-10-11 편집 수정 자체 검사: editfix-result.json(앱 검사)과 editfix-manifest.json(레인 배치, 위 → 아래)의 내보내기를
    // MultiLaneJudge로 판정한다(가장 위 영상 레인 원본 프레임, 소리 클릭 위치 = 옮긴 연결된 쌍의 동기)
    struct ECheck: Codable { let name: String; let pass: Bool; let detail: String }
    let checks = try JSONDecoder().decode([ECheck].self, from: Data(contentsOf: dir.appendingPathComponent("editfix-result.json")))
    for c in checks { print(c.pass ? "PASS" : "FAIL", c.name, c.detail.isEmpty ? "" : "— \(c.detail)") }
    var ok = checks.allSatisfy(\.pass) && !checks.isEmpty
    if let md = try? Data(contentsOf: dir.appendingPathComponent("editfix-manifest.json")) {
        let m = try JSONDecoder().decode(MultiLaneJudge.Manifest.self, from: md)
        let r = try await MultiLaneJudge.judge(dir.appendingPathComponent(m.exportFile), m)
        report("editfix export video", r.video, audio: false)
        print("  audio onsets expected", r.expectedOnsets, "measured", r.measuredOnsets, "max error", r.maxOnsetError.map(String.init) ?? "-")
        for t in r.tones { print("  tone", t.file, "lane", t.lane, String(format: "expected %.3f measured %.4f", t.expected, t.measured), t.pass ? "ok" : "MISMATCH") }
        print("  audio tracks in MP4:", r.audioTracks)
        print("editfix export:", r.pass ? "PASS" : "FAIL")
        ok = ok && r.pass
    } else { print("editfix export: no manifest"); ok = false }
    print(ok ? "OVERALL PASS" : "OVERALL FAIL")
    exit(ok ? 0 : 1)
case "verify-overlay":
    // A-015 크기·위치 자체 검사: transform-result.json(앱 검사)과 transform-manifest.json(판 레이어, 위 → 아래)의 내보내기를 격자로 판정
    struct TCheck: Codable { let name: String; let pass: Bool; let detail: String }
    struct TManifest: Codable { let exportFile: String; let durationFrames: Int; let frames: [Int]; let layers: [OverlayJudge.Layer] }
    let checks = try JSONDecoder().decode([TCheck].self, from: Data(contentsOf: dir.appendingPathComponent("transform-result.json")))
    for c in checks { print(c.pass ? "PASS" : "FAIL", c.name, c.detail.isEmpty ? "" : "— \(c.detail)") }
    var ok = checks.allSatisfy(\.pass) && !checks.isEmpty
    if let md = try? Data(contentsOf: dir.appendingPathComponent("transform-manifest.json")) {
        let m = try JSONDecoder().decode(TManifest.self, from: md)
        let url = dir.appendingPathComponent(m.exportFile)
        let frames = try await FrameCompare.decode(url, frames: Set(m.frames))
        let total = try await AVURLAsset(url: url).load(.duration)
        let n = Int((total.seconds * 30).rounded())
        print("overlay export: frames \(n)/\(m.durationFrames)")
        ok = ok && n == m.durationFrames
        for fno in m.frames {
            guard let f = frames[fno] else { print("  frame \(fno): unreadable"); ok = false; continue }
            let r = OverlayJudge.judgeGrid(f, frame: fno, layers: m.layers)
            print("  frame \(fno): checked \(r.checked) points, mismatches \(r.mismatches.count)", r.mismatches.prefix(8).joined(separator: " "))
            ok = ok && r.mismatches.isEmpty && r.checked > 500 && f.width == 1920 && f.height == 1080
        }
    } else { print("overlay export: no manifest"); ok = false }
    print(ok ? "OVERALL PASS" : "OVERALL FAIL")
    exit(ok ? 0 : 1)
case "probe-timing":
    // 진단(2026-10-11): 미디어 검사 단계별 시간. 파일 이름·경로는 출력하지 않는다(번호만).
    for (i, path) in args.dropFirst(2).enumerated() {
        let t0 = Date()
        let log = StageLog()
        do {
            let a = try await MediaProbe.inspect(URL(fileURLWithPath: path)) { log.mark($0) }
            print("file#\(i + 1) ok \(String(format: "%.3f", Date().timeIntervalSince(t0)))s frames \(a.frameCount) \(a.timing.detail) | \(log.summary(t0))")
        } catch { print("file#\(i + 1) error \(error) | \(log.summary(t0))") }
    }
case "make-projects":
    // 진단(2026-10-11): <dir>/sources의 otf-TA·otf-TB·aud-steady48s(·long-180s)를 쓰는 형식 2–5 프로젝트를 만든다.
    // 형식 5는 지금 저장기, 2–4는 지금 저장 결과에서 그 형식에 없던 키를 빼거나 이전 키로 바꿔 만든 것이다(그 형식의 저장기는 커밋되지 않았다).
    let src = dir.appendingPathComponent("sources")
    let ta = try await MediaProbe.inspect(src.appendingPathComponent("otf-TA.mp4")), tb = try await MediaProbe.inspect(src.appendingPathComponent("otf-TB.mp4"))
    let wav = try await MediaProbe.inspect(src.appendingPathComponent("aud-steady48s.wav"))
    let a2 = UUID(), v2 = UUID()
    var t = Timeline().registering(ta).registering(tb).registering(wav)
    t = try t.addingLane(.video, name: "위 영상", id: v2, outward: true).addingLane(.audio, name: "효과음", id: a2, outward: true)
    t = try t.placing(media: ta.id, at: 0, videoLane: Lane.videoID, audioLane: Lane.audioID)
    t = try t.placing(media: tb.id, at: 130, videoLane: v2, audioLane: Lane.audioID)
    t = try t.placing(media: wav.id, at: 0, videoLane: nil, audioLane: a2)
    t = try t.settingLaneAudio(a2, volumePercent: 60)
    let top = t.clips(inLane: v2)[0].id
    t = try t.settingTransform(clip: top, ClipTransform(scalePermille: 500, offsetX: 400, offsetY: -200))
    let wc = t.clips(inLane: a2)[0].id
    t = try t.settingClipAudio(clip: wc, volumePercent: 70, fadeInFrames: 15)
    func write(_ name: String, _ obj: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent(name))
    }
    let p5 = dir.appendingPathComponent("p-v5.ontheframe")
    let d5 = try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: p5)
    try d5.write(to: p5)
    var o = try JSONSerialization.jsonObject(with: d5) as! [String: Any]
    func clips(_ k: String, _ f: ([String: Any]) -> [String: Any]) { o[k] = (o[k] as! [[String: Any]]).map(f) }
    o["version"] = 4; clips("audioClips") { var c = $0; c.removeValue(forKey: "audio"); return c }
    try write("p-v4.ontheframe", o)
    o["version"] = 3
    clips("videoClips") { var c = $0
        if let x = c["transform"] as? [String: Int] { c["transform"] = ["scalePermille": x["scaleMicro"]! / 1000, "offsetX": x["offsetXMilli"]! / 1000, "offsetY": x["offsetYMilli"]! / 1000] }
        return c }
    try write("p-v3.ontheframe", o)
    o["version"] = 2; clips("videoClips") { var c = $0; c.removeValue(forKey: "transform"); return c }
    try write("p-v2.ontheframe", o)
    // 긴 원본을 쓰는 프로젝트(열기 시간·취소 검사용)
    if FileManager.default.fileExists(atPath: src.appendingPathComponent("long-180s.mp4").path) {
        let lg = try await MediaProbe.inspect(src.appendingPathComponent("long-180s.mp4"))
        var tl = Timeline().registering(lg)
        tl = try tl.placing(media: lg.id, at: 0, videoLane: Lane.videoID, audioLane: Lane.audioID)
        let pl = dir.appendingPathComponent("p-long.ontheframe")
        try ProjectFile.encode(tl, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: pl).write(to: pl)
    }
    print("projects written")
case "fixtures":
    let names = try await DevFixtures.ensureAll(in: dir)
    print("fixtures:", names.joined(separator: ", "))
case "verify":
    let st = try JSONDecoder().decode(SelfTestResult.self, from: Data(contentsOf: dir.appendingPathComponent("selftest-result.json")))
    for c in st.checks { print(c.pass ? "PASS" : "FAIL", c.name, c.detail.isEmpty ? "" : "— \(c.detail)") }
    print("temp locations:", st.tempLocations.joined(separator: " | "))
    var verdict: ExportJudge.Verdict? = nil, timed: ExportJudge.Verdict? = nil
    var timedExpected = false
    if let md = try? Data(contentsOf: dir.appendingPathComponent("selftest-manifest.json")) {
        let m = try JSONDecoder().decode(Manifest.self, from: md)
        let v = try await ExportJudge.judge(dir.appendingPathComponent(m.exportFile), clips: m.clips, durationFrames: m.durationFrames)
        verdict = v
        report("export", v)
        // A-010: 30 fps가 아닌 원본 타임라인 내보내기
        if let te = m.timedExport {
            timedExpected = true
            let tv = try await ExportJudge.judge(dir.appendingPathComponent(te.exportFile), clips: te.clips, durationFrames: te.durationFrames)
            timed = tv
            report("timed export", tv)
        }
    } else { print("export: no manifest") }
    let failed = st.checks.filter { !$0.pass }.map(\.name)
    let out = Output(selfTestPass: failed.isEmpty, failedChecks: failed, export: verdict, timedExport: timed,
                     pass: failed.isEmpty && verdict?.pass == true && (!timedExpected || timed?.pass == true))
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(out).write(to: dir.appendingPathComponent("verify-result.json"))
    print(out.pass ? "OVERALL PASS" : "OVERALL FAIL")
    exit(out.pass ? 0 : 1)
default:
    print("unknown command"); exit(2)
}

/// 단계 시각 기록(진단용)
final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [(String, Date)] = []
    func mark(_ s: MediaProbe.Stage) {
        let name: String
        switch s { case .opening: name = "open"; case .checkingFormat: name = "format"; case .scanningFrames(let n): name = n == 0 ? "scan" : "scan+\(n)"; case .finished: name = "done" }
        lock.lock(); if !(name.hasPrefix("scan+") && marks.last?.0.hasPrefix("scan+") == true) { marks.append((name, Date())) } else { marks[marks.count - 1] = (name, Date()) }; lock.unlock()
    }
    func summary(_ t0: Date) -> String { lock.lock(); defer { lock.unlock() }; return marks.map { "\($0.0)@\(String(format: "%.3f", $0.1.timeIntervalSince(t0)))" }.joined(separator: " ") }
}
