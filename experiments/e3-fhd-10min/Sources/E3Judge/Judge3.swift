import E2Core
import E3Core
import E3Expect
import Foundation

/// 독립 기대값(Expect3)으로 측정값을 판정한다. 프레임 측정은 받는 즉시 요약하고 픽셀은 남기지 않는다.
public enum Judge3 {
    public static let boxTolerance = 3
    /// 클릭 반응 문턱(막대 높이 픽셀, 실험용): 최대 막대 높이의 10%
    public static var clickBarThreshold: Int { Spec4K.barMaxHeight / 10 }
    public static let onsetTolerance = 48

    public static func frameIssues(timeIndex n: Int, _ m: E2Metrics?) -> [String] {
        guard let m else { return ["unmeasurable"] }
        let c = Expect3.contentFrame(n)
        var out: [String] = []
        if m.timelineCode != c { out.append("timelineCode \(m.timelineCode) != \(c)") }
        guard let (src, f) = Expect3.source(at: c) else { return out + ["no expectation"] }
        if m.sourceID != Expect3.sourceIDs[src] { out.append("source \(m.sourceKey) != \(src)") }
        if m.sourceFrame != f { out.append("sourceFrame \(m.sourceFrame) != \(f)") }
        // 상자 가운데 위치로 판정(2026-10-10 수정): 첫 실행(…022344Z)에서 왼쪽 가장자리 기준은 10 Mbps 디코딩 프레임 7개에서
        // 압축으로 깎인 가장자리 때문에 5~6 px 어긋났다(같은 프레임의 소스 코드는 맞았고 무손실 오프라인 출력은 모두 정확).
        let wantCenter = Spec4K.boxX(f) + (Spec4K.boxSize - 1) / 2
        if abs(m.boxCenterX - wantCenter) > boxTolerance { out.append("boxCenter \(m.boxCenterX) != \(wantCenter) (left \(m.boxX))") }
        if m.captionShown != Expect3.captions(at: c) { out.append("captions \(m.captionShown) != \(Expect3.captions(at: c))") }
        if m.flashOn != Expect3.isFlash(at: c) { out.append("flash \(m.flashOn) != \(Expect3.isFlash(at: c)) (\(m.flash))") }
        return out
    }
}

/// 프레임별 판정 누적(스트리밍). 막대는 프레임당 몇 개의 작은 값만 남긴다.
public final class FrameTally {
    public private(set) var checked = 0, bad = 0
    public private(set) var issues: [String] = []
    public private(set) var cutIssues: [String] = []
    var argmax = [Int8](repeating: -1, count: Expect3.frameCount)
    var maxH = [Int16](repeating: -1, count: Expect3.frameCount)
    var highMax = [Int16](repeating: -1, count: Expect3.frameCount)
    var clipMax = [Int16](repeating: -1, count: Expect3.frameCount)
    var flashSeen = [Bool](repeating: false, count: Expect3.frameCount)
    var measured = [Bool](repeating: false, count: Expect3.frameCount)
    let cutSet: Set<Int>
    public init() { cutSet = Set(Expect3.cutStarts.flatMap { [$0 - 1, $0] }) }

    public func add(_ n: Int, _ m: E2Metrics?) {
        checked += 1
        let iss = Judge3.frameIssues(timeIndex: n, m)
        if !iss.isEmpty { bad += 1; if issues.count < 40 { issues.append("\(n): " + iss.joined(separator: "; ")) } }
        let c = Expect3.contentFrame(n)
        if cutSet.contains(c), !iss.isEmpty, cutIssues.count < 40 { cutIssues.append("\(n): " + iss.joined(separator: "; ")) }
        guard n < Expect3.frameCount, let m else { return }
        let h = m.barHeights
        measured[n] = true
        argmax[n] = Int8(h.indices.max { h[$0] < h[$1] } ?? -1)
        maxH[n] = Int16(h.max() ?? 0)
        highMax[n] = Int16(Expect3.highBands.map { h[$0] }.max() ?? 0)
        clipMax[n] = Int16(Expect3.clipBands.map { h[$0] }.max() ?? 0)
        flashSeen[n] = m.flashOn
    }

    /// 스펙트럼 판정(측정된 프레임만): 분별 톤 밴드, 무음, 클립 밴드 0(클릭 창 제외), 클릭 반응
    public func spectrum() -> (ok: Bool, detail: [String: Any]) {
        let clickFrames = Set(Expect3.musicClickTimeline.flatMap { t -> [Int] in let r = Expect3.clickResponseFrame(t); return Array(r..<(r + 4)) })
        var toneN = 0, toneBad: [Int] = []
        var perMinute: [[String: Any]] = []
        for m in 0..<10 {
            var n0 = 0, b0 = 0
            for n in Expect3.frames(in: Expect3.toneSpan(m)) where measured[n] && !clickFrames.contains(n) {
                n0 += 1; toneN += 1
                if Int(argmax[n]) != Expect3.toneBands[m] { b0 += 1; if toneBad.count < 20 { toneBad.append(n) } }
            }
            perMinute.append(["minute": m, "band": Expect3.toneBands[m], "framesChecked": n0, "mismatch": b0])
        }
        var quietN = 0, quietBad: [Int] = []
        for q in Expect3.quiet { for n in Expect3.frames(in: q) where measured[n] { quietN += 1; if maxH[n] > 0 && quietBad.count < 20 { quietBad.append(n) } } }
        var isoN = 0, isoBad: [Int] = []
        let boundary = Set(Expect3.toneBoundaryFrames)
        for n in 0..<Expect3.frameCount where measured[n] && !clickFrames.contains(n) && !boundary.contains(n) { isoN += 1; if clipMax[n] > 0 && isoBad.count < 20 { isoBad.append(n) } }
        var clicks: [[String: Any]] = [], clickBad = 0
        for t in Expect3.musicClickTimeline {
            let r = Expect3.clickResponseFrame(t)
            var st = "notMeasured"
            if r - 1 >= 0, r < Expect3.frameCount, measured[r - 1], measured[r] {
                st = Int(highMax[r - 1]) < Judge3.clickBarThreshold && Int(highMax[r]) >= Judge3.clickBarThreshold ? "pass" : "fail"
                if st == "fail" { clickBad += 1 }
            }
            clicks.append(["t": t, "responseFrame": r, "status": st])
        }
        let ok = toneBad.isEmpty && quietBad.isEmpty && isoBad.isEmpty && clickBad == 0
        return (ok, ["toneFramesChecked": toneN, "toneMismatch": toneBad, "perMinute": perMinute, "quietFramesChecked": quietN,
                     "quietNonZero": quietBad, "isolationFramesChecked": isoN, "clipBandNonZero": isoBad, "clicks": clicks])
    }

    /// 영상 플래시 위치(관찰 vs 기대): 분별 n_obs − n_exp
    public func flashDrift() -> (ok: Bool, detail: [String: Any]) {
        let expected = Expect3.flashFrames
        let seen = (0..<Expect3.frameCount).filter { measured[$0] && flashSeen[$0] }
        let seenSet = Set(seen), expSet = Set(expected)
        var rows: [[String: Any]] = []
        for m in 0..<10 {
            let r = (1800 * m)..<(1800 * (m + 1))
            let e = expected.filter { r.contains($0) }, s = seen.filter { r.contains($0) }
            let deltas = e.map { x in s.map { $0 - x }.min { abs($0) < abs($1) } ?? 99_999 }
            rows.append(["minute": m, "expected": e.count, "observed": s.count, "deltaFramesMin": deltas.min() ?? 0, "deltaFramesMax": deltas.max() ?? 0])
        }
        let missing = expected.filter { measured[$0] && !seenSet.contains($0) }, extra = seen.filter { !expSet.contains($0) }
        return (missing.isEmpty && extra.isEmpty, ["expectedFlashes": expected.count, "observedFlashes": seen.count, "missing": Array(missing.prefix(20)),
                                                    "extra": Array(extra.prefix(20)), "perMinute": rows])
    }
}

/// 내보낸 오디오 onset 대조: 음악 클릭 11개, 클립 클릭(플래시 프레임 중간)
public enum AudioJudge3 {
    public static func run(onsets: [Int]) -> (ok: Bool, detail: [String: Any]) {
        let expected = (Expect3.musicClickSamples.map { ($0, "music") } + Expect3.clipClickSamples.map { ($0, "clip") }).sorted { $0.0 < $1.0 }
        var bad: [String] = []
        var perMinute: [Int: [Int]] = [:]
        for (e, kind) in expected {
            let near = onsets.min { abs($0 - e) < abs($1 - e) }
            let d = near.map { $0 - e } ?? Int.max
            if abs(d) > Judge3.onsetTolerance { bad.append("\(kind) \(e): \(d == Int.max ? "none" : "\(d)")") }
            else { perMinute[e / 2_880_000, default: []].append(d) }
        }
        let extra = onsets.filter { o in !expected.contains { abs(o - $0.0) <= Judge3.onsetTolerance } }
        let rows = (0..<10).map { m -> [String: Any] in
            let d = perMinute[m] ?? []
            return ["minute": m, "matched": d.count, "deltaMin": d.min() ?? 0, "deltaMax": d.max() ?? 0]
        }
        return (bad.isEmpty && extra.isEmpty, ["expected": expected.count, "onsets": onsets.count, "unmatched": Array(bad.prefix(20)),
                                               "extraOnsets": Array(extra.prefix(20)), "perMinuteSampleDelta": rows])
    }
}
