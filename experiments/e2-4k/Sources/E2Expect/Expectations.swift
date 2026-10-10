// E2 독립 기대값 표.
//
// 이 파일의 값은 편집 순서·fixture 정의에서 손으로 유도해 리터럴로 적었다. E2Core의 편집 모델(EditTimeline),
// composition 구성, 합성기, 스펙트럼 계산을 호출해서 만든 값이 아니다(이 타깃은 E2Core에 의존하지 않는다).
//
// 소스(30 fps): A 240프레임(8 s), B 240(8 s), C 180(6 s). 소스 ID 코드 A=0x2D, B=0x5A, C=0xB4.
// 편집: A,B,C 붙임 → A를 [30,120)으로 트림 → 타임라인 150에서 B 분할(B.1=[0,60), B.2=[60,240))
//       → B.2를 [150,210)으로 트림 → C를 [20,110)으로 트림 → C를 A 다음으로 이동.
// 결과(타임라인 프레임 → 소스 프레임):
//   [0, 90)    A  30 + n          (A 30…119)
//   [90, 180)  C  20 + (n − 90)   (C 20…109)
//   [180, 240) B  n − 180         (B 0…59)
//   [240, 300) B  150 + (n − 240) (B 150…209)
// 길이 300프레임(10 s). 마지막 유효 프레임 299(B 209). 끝 시각 300은 299를 유지(D-018).

public struct ExpectedSegment: Sendable {
    public let start: Int, end: Int, source: String, sourceIn: Int
}

public enum Expect2 {
    public static let frameCount = 300
    public static let lastValidFrame = 299
    public static let segments: [ExpectedSegment] = [
        ExpectedSegment(start: 0, end: 90, source: "A", sourceIn: 30),
        ExpectedSegment(start: 90, end: 180, source: "C", sourceIn: 20),
        ExpectedSegment(start: 180, end: 240, source: "B", sourceIn: 0),
        ExpectedSegment(start: 240, end: 300, source: "B", sourceIn: 150),
    ]
    public static let sourceIDs: [String: Int] = ["A": 0x2D, "B": 0x5A, "C": 0xB4]
    /// 컷 경계 양쪽(직전·직후)과 끝: (타임라인 프레임, 소스, 소스 프레임)
    public static let boundaryFrames: [(Int, String, Int)] = [
        (0, "A", 30), (89, "A", 119), (90, "C", 20), (179, "C", 109), (180, "B", 0),
        (239, "B", 59), (240, "B", 150), (299, "B", 209),
    ]

    /// 시각 프레임 n에서 보여야 할 내용의 타임라인 프레임(끝 유지)
    public static func contentFrame(_ n: Int) -> Int { min(n, lastValidFrame) }

    /// 타임라인 프레임 n(0…299)의 기대 (소스, 소스 프레임)
    public static func source(at n: Int) -> (String, Int)? {
        for s in segments where n >= s.start && n < s.end { return (s.source, s.sourceIn + n - s.start) }
        return nil
    }
    /// 이동 상자 x: 80 + (소스 프레임 · 24) mod 2800
    public static func boxX(sourceFrame f: Int) -> Int { 80 + (f * 24) % 2800 }

    // 자막(반열린 프레임 구간): 왼쪽 [15,75) = [0.5,2.5) s, 가운데 [75,165) = [2.5,5.5) s, 오른쪽 [210,270) = [7,9) s
    public static let captionRanges: [Range<Int>] = [15..<75, 75..<165, 210..<270]
    public static func captions(at n: Int) -> [Bool] { captionRanges.map { $0.contains(n) } }

    // 선택 오디오(음악 M) — 타임라인 [1, 10) s에 원본 [2, 11) s가 놓인다(원본 = 타임라인 + 1 s).
    //   톤 250 Hz 원본 [2,5) → 타임라인 [1,4): 밴드 floor(ln(250/40)/ln(400)·32) = floor(9.79) = 9
    //   톤 1500 Hz 원본 [6,9) → 타임라인 [5,8): floor(19.36) = 19
    //   클릭 원본 211/60, 451/60, 571/60 s → 타임라인 151/60, 391/60, 511/60 s (원본 61/60, 691/60은 배치 밖)
    // 클립 오디오(소스 영상의 오디오, 스펙트럼에 쓰면 안 됨): A 3500 Hz → 밴드 23, B 5000 Hz → 25, C 7000 Hz → 27.
    public static let musicTones: [(start: Double, end: Double, band: Int)] = [(1, 4, 9), (5, 8, 19)]
    public static let clipBands = [23, 25, 27]
    public static let highBands = 28...31   // 톤이 없는 고역: 클릭 반응 검출용
    /// 막대가 모두 0이어야 하는 구간(타임라인 s): 음악 없음 [0,1), 톤 사이 무음 [4.1,5), 마지막 톤 뒤 [8.1, 8.5), 마지막 클릭 뒤 [8.7, 10)
    public static let quiet: [(Double, Double)] = [(0, 1), (4.1, 5), (8.1, 8.5), (8.7, 10)]
    public static let musicClickTimeline: [Double] = [151.0 / 60, 391.0 / 60, 511.0 / 60]

    /// 구간 [a, b)에 시작 시각이 들어가는 프레임(30 fps)
    public static func frames(in span: (Double, Double), startPad: Double = 0, endPad: Double = 0) -> [Int] {
        let a = Int(((span.0 + startPad) * 30).rounded(.up)), b = Int(((span.1 - endPad) * 30).rounded(.up))
        return a < b ? Array(a..<min(b, frameCount)) : []
    }
    /// 클릭 t(프레임 중간) → 후행 분석 창의 기대 반응 프레임 floor(t·30) + 1
    public static func clickResponseFrame(_ t: Double) -> Int { Int((t * 30).rounded(.down)) + 1 }

    // 내보낸 오디오의 클릭 onset(타임라인 샘플, 48 kHz):
    //   음악: 151/60 s = 120 800, 391/60 s = 312 800, 511/60 s = 408 800
    //   클립 A(원본 1.25+k s, 타임라인 = 원본 − 1.0): 원본 1.25, 2.25, 3.25 → 12 000, 60 000, 108 000
    //   클립 C(원본 0.6+k s, 타임라인 = 원본 − 20/30 + 3): 원본 1.6, 2.6, 3.6 → 188 800, 236 800, 284 800
    //   클립 B.1(원본 0.1+k s, 타임라인 = 원본 + 6): 원본 0.1, 1.1 → 292 800, 340 800
    //   클립 B.2(타임라인 = 원본 − 5 + 8): 원본 5.1, 6.1 → 388 800, 436 800
    //   잘려 나간 클릭(나오면 안 됨): A 0.25·4.25…, C 0.6·4.6·5.6, B 2.1·3.1·4.1·7.1
    public static let musicClickSamples = [120_800, 312_800, 408_800]
    public static let clipClickSamples = [12_000, 60_000, 108_000, 188_800, 236_800, 284_800, 292_800, 340_800, 388_800, 436_800]
    public static let audioSamples = 480_000
}
