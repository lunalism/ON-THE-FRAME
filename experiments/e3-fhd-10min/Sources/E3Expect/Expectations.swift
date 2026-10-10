// E3-1 독립 기대값.
//
// 이 파일은 EXPERIMENT-PLAN §7.6과 fixture 정의에서 손으로 유도한 공식·리터럴만 담는다. E2Core·E3Core의 편집 모델,
// composition 구성, 합성기, 스펙트럼 계산을 호출하지 않는다(이 타깃은 다른 모듈에 의존하지 않는다).
//
// 타임라인(30 fps, 18 000프레임 = 10분):
//   클립 k = 0…38: 타임라인 [450k, 450k + 450), 소스 [A, B, C][k mod 3], 소스 시작 30·(k mod 5)
//   클립 39: [17 550, 17 940), 소스 A, 시작 120 (13 s)
//   클립 40: [17 940, 18 000), 소스 B, 시작 300 (2 s, 끝 직전 컷)
//   마지막 유효 프레임 17 999 = B 359. 끝 시각 18 000은 17 999를 유지(D-018).
// 소스(각 600프레임 = 20 s): 플래시는 소스 프레임 15와 315(f mod 300 = 15). 그 프레임 중간 시각에 클립 오디오 클릭.
// 선택 오디오 M: 원본 0 s를 타임라인 0.5 s에 놓고 599.5 s 동안(원본 = 타임라인 − 0.5 s).
//   분 m(0…9)의 톤: 타임라인 [60m + 2, 60m + 50) s. 밴드 = floor(ln(f/40)/ln(400)·32):
//     135 Hz → 6, 196 → 8, 286 → 10, 415 → 12, 604 → 14, 879 → 16, 1278 → 18, 1858 → 20, 2702 → 22, 729 → 15
//   음악 클릭(프레임 중간 시각): 타임라인 60m + 40 + 1/60 s, 끝 근처 35 929/60 s(= 598.8167 s)
// 클립 오디오(스펙트럼에 쓰면 안 됨): A 3500 Hz → 밴드 23, B 5000 → 25, C 7000 → 27.

public enum Expect3 {
    public static let frameCount = 18_000
    public static let lastValidFrame = 17_999
    public static let sources = ["A", "B", "C"]
    public static let sourceIDs: [String: Int] = ["A": 0x2D, "B": 0x5A, "C": 0xB4]

    public static func contentFrame(_ n: Int) -> Int { min(n, lastValidFrame) }

    /// 타임라인 프레임 n(0…17 999) → (소스, 소스 프레임)
    public static func source(at n: Int) -> (String, Int)? {
        guard n >= 0, n < frameCount else { return nil }
        if n < 17_550 { let k = n / 450; return (sources[k % 3], 30 * (k % 5) + n - 450 * k) }
        if n < 17_940 { return ("A", 120 + n - 17_550) }
        return ("B", 300 + n - 17_940)
    }
    /// 컷 경계(새 클립의 첫 프레임): 450k(k = 1…38), 17 550, 17 940
    public static let cutStarts: [Int] = (1...38).map { 450 * $0 } + [17_550, 17_940]

    public static func isFlash(at n: Int) -> Bool {
        guard let (_, f) = source(at: n) else { return false }
        return f % 300 == 15
    }

    // 자막: k = 0…18은 [900k + 150, 900k + 600)(= [30k + 5, 30k + 20) s), 정렬 k mod 3(0 왼쪽, 1 가운데, 2 오른쪽).
    // k = 19는 [17 700, 17 985)(= [590, 599.5) s), 정렬 1(가운데). 끝 직전 컷 17 940을 걸친다.
    public static let captionRanges: [(Range<Int>, Int)] = (0..<19).map { (900 * $0 + 150 ..< 900 * $0 + 600, $0 % 3) } + [(17_700 ..< 17_985, 1)]
    /// 프레임 n에서 [왼쪽, 가운데, 오른쪽] 자막 표시 여부
    public static func captions(at n: Int) -> [Bool] {
        var s = [false, false, false]
        for (r, a) in captionRanges where r.contains(n) { s[a] = true }
        return s
    }

    public static let toneBands = [6, 8, 10, 12, 14, 16, 18, 20, 22, 15]
    public static let clipBands = [23, 25, 27]
    public static let highBands = 28...31
    public static let musicClickTimeline: [Double] = (0..<10).map { 60.0 * Double($0) + 40 + 1.0 / 60 } + [35_929.0 / 60]
    /// 클릭 t(프레임 중간) → 후행 분석 창의 기대 반응 프레임 floor(t·30) + 1
    public static func clickResponseFrame(_ t: Double) -> Int { Int((t * 30).rounded(.down)) + 1 }
    /// 톤 판정 구간(타임라인 s): [60m + 2.2, 60m + 49.9)
    public static func toneSpan(_ m: Int) -> (Double, Double) { (60 * Double(m) + 2.2, 60 * Double(m) + 49.9) }
    /// 선택 오디오 톤의 시작·끝 직후 0.1 s(타임라인 [60m + 2, 60m + 2.1), [60m + 50, 60m + 50.1)).
    /// 이 구간에서는 선택 오디오 자체의 과도 응답이 인접 밴드로 번진다. 격리 검사(클립 밴드 0)에서만 뺀다.
    /// 2026-10-10 수정: 첫 실행(…022344Z)에서 분 8의 톤(밴드 22)의 시작·끝 프레임 14 461, 14 462, 15 901에서 밴드 23이 0이 아니어서
    /// 격리 실패로 기록되었다. 음악 파일만 분석한 캐시에서도 같은 프레임의 밴드 23이 0.013~0.072여서(…e3-diag-iso…) 선택 오디오
    /// 자체의 번짐이고 클립 오디오가 아니다. 기대값 설계(클립 밴드 23이 톤 밴드 22와 인접) 오류로 기록한다.
    public static var toneBoundaryFrames: [Int] {
        (0..<10).flatMap { m in frames(in: (60 * Double(m) + 2, 60 * Double(m) + 2.1)) + frames(in: (60 * Double(m) + 50, 60 * Double(m) + 50.1)) }
    }

    /// 막대가 모두 0이어야 하는 구간(타임라인 s)
    public static let quiet: [(Double, Double)] = [(0, 1.9)] + (0..<9).map { (60 * Double($0) + 50.1, 60 * Double($0) + 61.9) } + [(590.1, 598.7), (598.95, 600)]

    /// 구간 [a, b)에 시작 시각이 들어가는 프레임
    public static func frames(in span: (Double, Double)) -> [Int] {
        let a = Int((span.0 * 30).rounded(.up)), b = Int((span.1 * 30).rounded(.up))
        return a < b ? Array(a..<min(b, frameCount)) : []
    }

    // 내보낸 오디오의 클릭 onset(타임라인 샘플, 48 kHz)
    //   음악: 48 000·(60m + 40) + 800 = 2 880 000m + 1 920 800, 끝 근처 35 929·800 = 28 743 200
    //   클립: 플래시 프레임 n의 중간 = 1600n + 800
    public static let musicClickSamples: [Int] = (0..<10).map { 2_880_000 * $0 + 1_920_800 } + [28_743_200]
    public static var flashFrames: [Int] { (0..<frameCount).filter { isFlash(at: $0) } }
    public static var clipClickSamples: [Int] { flashFrames.map { 1600 * $0 + 800 } }
    public static let audioSamples = 28_800_000
}
