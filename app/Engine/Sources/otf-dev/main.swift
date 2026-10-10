import CoreVideo
import E2Core
import Foundation
import OTFDevSupport

// 개발 검증 도구(앱 번들에 들어가지 않음).
//   otf-dev fixtures <dir>        생성 fixture를 dir에 만든다(있으면 그대로)
//   otf-dev verify <selftest-dir> 앱 자체 검사 결과(selftest-result.json)와 내보낸 파일의 프레임·소리를 판정하고 verify-result.json을 쓴다
//   otf-dev verify-preview <dir>  편집 뒤 프리뷰 갱신 자체 검사(preview-manifest.json)의 저장 프레임을 화면 코드·검정으로 판정한다
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: otf-dev fixtures <dir> | verify <selftest-dir>"); exit(2) }
let dir = URL(fileURLWithPath: args[2], isDirectory: true)

struct Manifest: Codable { let fps: Int32; let exportFile: String; let clips: [ExportJudge.ClipRef]; let durationFrames: Int? }
struct Check: Codable { let name: String; let pass: Bool; let detail: String }
struct SelfTestResult: Codable { let sandboxContainer: Bool; let checks: [Check]; let tempLocations: [String] }
struct Output: Codable { let selfTestPass: Bool; let failedChecks: [String]; let export: ExportJudge.Verdict?; let pass: Bool }

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
case "fixtures":
    let names = try await DevFixtures.ensureAll(in: dir)
    print("fixtures:", names.joined(separator: ", "))
case "verify":
    let st = try JSONDecoder().decode(SelfTestResult.self, from: Data(contentsOf: dir.appendingPathComponent("selftest-result.json")))
    for c in st.checks { print(c.pass ? "PASS" : "FAIL", c.name, c.detail.isEmpty ? "" : "— \(c.detail)") }
    print("temp locations:", st.tempLocations.joined(separator: " | "))
    var verdict: ExportJudge.Verdict? = nil
    if let md = try? Data(contentsOf: dir.appendingPathComponent("selftest-manifest.json")) {
        let m = try JSONDecoder().decode(Manifest.self, from: md)
        let v = try await ExportJudge.judge(dir.appendingPathComponent(m.exportFile), clips: m.clips, durationFrames: m.durationFrames)
        verdict = v
        print("export:", v.pass ? "PASS" : "FAIL", "frames \(v.frames)/\(v.expectedFrames)", v.dimensions, v.codec, v.audioFormat)
        for b in v.boundaries { print("  boundary", b.frame, "expected", b.expected, "measured", b.measured, b.pass ? "ok" : "MISMATCH") }
        print("  onsets expected", v.expectedOnsets, "measured", v.measuredOnsets, "max error", v.maxOnsetErrorSamples.map(String.init) ?? "-")
        if !v.mismatchedFrames.isEmpty { print("  mismatched frames", v.mismatchedFrames) }
        if !v.notes.isEmpty { print("  notes", v.notes) }
    } else { print("export: no manifest") }
    let failed = st.checks.filter { !$0.pass }.map(\.name)
    let out = Output(selfTestPass: failed.isEmpty, failedChecks: failed, export: verdict, pass: failed.isEmpty && verdict?.pass == true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(out).write(to: dir.appendingPathComponent("verify-result.json"))
    print(out.pass ? "OVERALL PASS" : "OVERALL FAIL")
    exit(out.pass ? 0 : 1)
default:
    print("unknown command"); exit(2)
}
