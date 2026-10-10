import E2Core
import E2Expect
import Foundation

/// 측정값(E2Metrics)을 독립 기대값(Expect2)으로 판정한다. 기대값은 E2Core의 편집 모델을 호출하지 않는다.
public enum Judge {
    /// 이동 상자 위치 허용치(픽셀, 실험용): 압축·스케일 없이 같은 크기라 경계 번짐만 허용한다.
    public static let boxTolerance = 3
    /// 클릭 반응 문턱(막대 높이 픽셀, 실험용). 최대 960 px의 10%.
    public static let clickBarThreshold = 96

    /// 시각 프레임 n(끝 시각 300 포함)에서 측정한 프레임의 문제 목록. 비어 있으면 통과.
    public static func frameIssues(timeIndex n: Int, _ m: E2Metrics?) -> [String] {
        guard let m else { return ["unmeasurable"] }
        let content = Expect2.contentFrame(n)
        var out: [String] = []
        if m.timelineCode != content { out.append("timelineCode \(m.timelineCode) != \(content)") }
        guard let (src, f) = Expect2.source(at: content) else { return out + ["no expectation for \(content)"] }
        if m.sourceID != Expect2.sourceIDs[src] { out.append("source \(m.sourceKey) != \(src)") }
        if m.sourceFrame != f { out.append("sourceFrame \(m.sourceFrame) != \(f)") }
        if abs(m.boxX - Expect2.boxX(sourceFrame: f)) > boxTolerance { out.append("boxX \(m.boxX) != \(Expect2.boxX(sourceFrame: f))") }
        if m.captionShown != Expect2.captions(at: content) { out.append("captions \(m.captionShown) != \(Expect2.captions(at: content)) px=\(m.captionPixels)") }
        return out
    }

    /// 스펙트럼 판정(프레임별 측정 묶음). 측정이 없는 프레임은 건너뛰고 확인한 수를 남긴다.
    public static func spectrum(_ byFrame: [Int: E2Metrics]) -> (ok: Bool, detail: [String: Any]) {
        func argmax(_ h: [Int]) -> Int { h.indices.max { h[$0] < h[$1] } ?? -1 }
        var toneN = 0, toneBad: [Int] = []
        for t in Expect2.musicTones {
            for n in Expect2.frames(in: (t.start, t.end), startPad: 0.2, endPad: 0.1) {
                guard let m = byFrame[n] else { continue }
                toneN += 1
                if argmax(m.barHeights) != t.band { toneBad.append(n) }
            }
        }
        var quietN = 0, quietBad: [Int] = []
        for q in Expect2.quiet {
            for n in Expect2.frames(in: q, startPad: 0, endPad: 0) {
                guard let m = byFrame[n] else { continue }
                quietN += 1
                if (m.barHeights.max() ?? 0) > 0 { quietBad.append(n) }
            }
        }
        // 클립 오디오 밴드(23, 25, 27)는 클릭 반응 프레임 근처를 빼고 항상 0이어야 한다(선택 오디오 격리).
        let clickWindows = Set(Expect2.musicClickTimeline.flatMap { t -> [Int] in let r = Expect2.clickResponseFrame(t); return Array(r..<(r + 4)) })
        var isoN = 0, isoBad: [Int] = []
        for (n, m) in byFrame where !clickWindows.contains(Expect2.contentFrame(n)) {
            isoN += 1
            if Expect2.clipBands.contains(where: { m.barHeights.indices.contains($0) && m.barHeights[$0] > 0 }) { isoBad.append(n) }
        }
        var clicks: [[String: Any]] = []
        var clickBad = 0
        for t in Expect2.musicClickTimeline {
            let r = Expect2.clickResponseFrame(t)
            func high(_ m: E2Metrics) -> Int { Expect2.highBands.map { m.barHeights[$0] }.max() ?? 0 }
            var status = "notMeasured"
            if let a = byFrame[r - 1], let b = byFrame[r] {
                status = high(a) < clickBarThreshold && high(b) >= clickBarThreshold ? "pass" : "fail"
                if status == "fail" { clickBad += 1 }
            }
            clicks.append(["t": t, "responseFrame": r, "status": status])
        }
        let ok = toneBad.isEmpty && quietBad.isEmpty && isoBad.isEmpty && clickBad == 0
        let mismatchBars: [String: [Int]] = Dictionary(uniqueKeysWithValues: toneBad.sorted().prefix(5).compactMap { n in byFrame[n].map { ("\(n)", $0.barHeights) } })
        return (ok, ["toneMismatchBarHeights": mismatchBars, "toneFramesChecked": toneN, "toneMismatch": toneBad.sorted().prefix(20).map { $0 }, "quietFramesChecked": quietN,
                     "quietNonZero": quietBad.sorted().prefix(20).map { $0 }, "isolationFramesChecked": isoN,
                     "clipBandNonZero": isoBad.sorted().prefix(20).map { $0 }, "clicks": clicks])
    }

    /// 내보낸 오디오의 클릭 onset을 기대 목록과 대조. 허용치(실험용) ±48샘플(1 ms): 두 번의 AAC 인코딩을 거친다.
    public static let onsetTolerance = 48
    public static func audio(onsets: [Int]) -> (ok: Bool, detail: [String: Any]) {
        let expected = (Expect2.musicClickSamples.map { ($0, "music") } + Expect2.clipClickSamples.map { ($0, "clip") }).sorted { $0.0 < $1.0 }
        var rows: [[String: Any]] = []
        var bad = 0
        for (e, kind) in expected {
            let near = onsets.min { abs($0 - e) < abs($1 - e) }
            let d = near.map { $0 - e } ?? Int.max
            let ok = abs(d) <= onsetTolerance
            if !ok { bad += 1 }
            rows.append(["expectedSample": e, "kind": kind, "deltaSamples": d == Int.max ? "none" : "\(d)", "ok": ok])
        }
        let extra = onsets.filter { o in !expected.contains { abs(o - $0.0) <= onsetTolerance } }
        return (bad == 0 && extra.isEmpty, ["expected": rows, "extraOnsets": extra, "onsetCount": onsets.count])
    }
}

// MARK: - 결과 기록

public final class Report {
    public var checks: [[String: Any]] = []
    public var sections: [String: Any] = [:]
    public init() {}
    public func check(_ id: String, _ name: String, pass: Bool?, _ detail: [String: Any] = [:]) {
        var d = detail; d["id"] = id; d["name"] = name; d["result"] = pass.map { $0 ? "PASS" : "FAIL" } ?? "RECORD"
        checks.append(d)
        let brief = detail.filter { !($0.value is [Any]) && !($0.value is [String: Any]) }
            .sorted { $0.key < $1.key }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[\(pass.map { $0 ? "PASS" : "FAIL" } ?? "REC ")] \(id) \(name)  \(brief)")
    }
    public var summary: (pass: Int, fail: [String], record: Int) {
        (checks.filter { ($0["result"] as? String) == "PASS" }.count,
         checks.filter { ($0["result"] as? String) == "FAIL" }.map { $0["id"] as! String },
         checks.filter { ($0["result"] as? String) == "RECORD" }.count)
    }
    public func write(to url: URL) throws {
        let s = summary
        sections["summary"] = ["pass": s.pass, "fail": s.fail.count, "record": s.record, "failedIDs": s.fail]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = sanitize(["sections": sections, "checks": checks])
        // 저장소 절대 경로는 "<repo>"로 바꿔 남긴다(커밋 문서에 개인 경로를 남기지 않음). url = <repo>/experiments/e2-4k/results/x.json
        let repo = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: repo, with: "<repo>")
        try Data(text.utf8).write(to: url)
        print("\nPASS \(s.pass)  FAIL \(s.fail.count)  RECORD \(s.record)   failed: \(s.fail)")
    }
}

public func sanitize(_ v: Any) -> Any {
    switch v {
    case let d as Double: return d.isFinite ? (d * 1e4).rounded() / 1e4 : String(d)
    case let f as Float: return sanitize(Double(f))
    case let a as [Any]: return a.map(sanitize)
    case let m as [String: Any]: return m.mapValues(sanitize)
    case let e as Encodable:
        if let data = try? JSONEncoder().encode(AnyEncodable(e)), let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return o }
        return "\(v)"
    default: return v
    }
}

struct AnyEncodable: Encodable {
    let e: Encodable
    init(_ e: Encodable) { self.e = e }
    func encode(to encoder: Encoder) throws { try e.encode(to: encoder) }
}

public func stats(_ xs: [Double]) -> [String: Double] {
    guard !xs.isEmpty else { return ["n": 0] }
    let s = xs.sorted()
    func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
    return ["n": Double(s.count), "mean": s.reduce(0, +) / Double(s.count), "p50": q(0.5), "p95": q(0.95), "max": s.last!]
}

public func runID() -> String { ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "") }
