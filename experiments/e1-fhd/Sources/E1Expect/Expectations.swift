// 독립 기대값 표.
//
// 이 파일의 값은 fixture 정의(소스 시각의 톤 구간·클릭 시각)와 케이스 설정에서 손으로 유도해
// 리터럴로 적었다. 구현의 대응식(ClipPlacement.sourceTime), 밴드 계산(SpectrumKernel),
// 렌더러를 호출해서 만든 값이 아니다.
//
// S 원본(20 s): 톤 [0,3) 135 Hz, [5,8) 600 Hz, [12,15) 2700 Hz, 나머지 무음.
//               클릭(원본 시각) 211/60, 271/60, 391/60, 811/60, 991/60, 1111/60 s
//               = 3.5167, 4.5167, 6.5167, 13.5167, 16.5167, 18.5167 s
// U 원본(20 s): 4700 Hz 연속, 클릭 1.25 + 2k s.
// 밴드: 40 Hz~16 kHz 로그 32등분, 밴드 b의 하한 = 40·400^(b/32).
//   135 Hz → ln(135/40)/ln(400)·32 = 6.50 → 6
//   600 Hz → 14.46 → 14,  2700 Hz → 22.50 → 22,  4700 Hz(U) → 25.46 → 25
// 시각 대응: 타임라인 t = 원본 s − s_in + t_start, 반열린 구간 [t_start, t_start + d).

public struct ToneSpan: Sendable { public let start: Double; public let end: Double; public let hz: Double; public let band: Int }

public struct CaseExpect: Sendable {
    public let id: String
    public let title: String
    // 구현에 넘기는 입력(초 단위 정수)
    public let sIn: Int64, tStart: Int64, dur: Int64
    // 손으로 유도한 기대값(타임라인 초)
    public let clicks: [Double]
    public let tones: [ToneSpan]
    public let quiet: [(Double, Double)]   // S가 없거나 클릭 없는 무음 구간
    // 같은 원본 시각을 가리키는 프레임 (원본 6.0 s, 7.0 s)
    public let framesForSource6and7: (Int, Int)
}

public enum Expect {
    public static let sHz = [135.0, 600.0, 2700.0]
    public static let uHz = 4700.0
    public static let uBand = 25
    public static let uClicks: [Double] = [1.25, 3.25, 5.25, 7.25, 9.25]
    public static let highBands = 27...31          // 톤이 없는 고역: 클릭 반응 검출용
    public static let captionFirstFrame = 60, captionLastFrame = 239
    public static let frameCount = 300
    /// 끝 프레임 유지(P-007, 2026-10-10 소유자 채택)의 독립 기대값. 10 s × 30 fps: 시작 시각이 [0, 10) 안인 프레임은
    /// 0…299이므로 마지막 유효 프레임은 299(손으로 유도한 리터럴. 구현의 FrameGrid를 호출하지 않음).
    public static let lastValidFrame = 299
    /// 시각 프레임 번호 n(끝 시각 t = 10.0 s이면 300)에서 화면에 보여야 할 내용의 프레임 번호.
    public static func contentFrame(forTimeIndex n: Int) -> Int { min(n, lastValidFrame) }

    public static func caseByID(_ id: String) -> CaseExpect? { cases.first { $0.id == id } }

    /// 구간 [a + startPad, b − endPad)에 시작 시각이 들어가는 프레임 번호(30fps)
    public static func frames(in span: (Double, Double), startPad: Double, endPad: Double) -> [Int] {
        let a = Int(((span.0 + startPad) * 30).rounded(.up)), b = Int(((span.1 - endPad) * 30).rounded(.up))
        return a < b ? Array(a..<min(b, frameCount)) : []
    }

    /// 클릭 시각 t(프레임 중간)에 대한 기대 반응 프레임: 후행 분석 창이므로 floor(t·30) + 1
    public static func clickResponseFrame(_ t: Double) -> Int { Int((t * 30).rounded(.down)) + 1 }

    public static let cases: [CaseExpect] = [
        CaseExpect(id: "c1-baseline", title: "기본: s_in 0, t_start 0, d 10",
                   sIn: 0, tStart: 0, dur: 10,
                   clicks: [211.0 / 60, 271.0 / 60, 391.0 / 60],
                   tones: [ToneSpan(start: 0, end: 3, hz: 135, band: 6), ToneSpan(start: 5, end: 8, hz: 600, band: 14)],
                   quiet: [(8, 10)],
                   framesForSource6and7: (180, 210)),
        CaseExpect(id: "c2-trim", title: "트림: s_in 5, t_start 0, d 10",
                   sIn: 5, tStart: 0, dur: 10,
                   clicks: [91.0 / 60, 511.0 / 60],
                   tones: [ToneSpan(start: 0, end: 3, hz: 600, band: 14), ToneSpan(start: 7, end: 10, hz: 2700, band: 22)],
                   quiet: [(3, 7)],
                   framesForSource6and7: (30, 60)),
        CaseExpect(id: "c3-offset", title: "오프셋: s_in 0, t_start 2, d 8",
                   sIn: 0, tStart: 2, dur: 8,
                   clicks: [331.0 / 60, 391.0 / 60, 511.0 / 60],
                   tones: [ToneSpan(start: 2, end: 5, hz: 135, band: 6), ToneSpan(start: 7, end: 10, hz: 600, band: 14)],
                   quiet: [(0, 2)],
                   framesForSource6and7: (240, 270)),
        CaseExpect(id: "c4-trim-offset", title: "트림+오프셋: s_in 5, t_start 2, d 8",
                   sIn: 5, tStart: 2, dur: 8,
                   clicks: [211.0 / 60],
                   tones: [ToneSpan(start: 2, end: 5, hz: 600, band: 14), ToneSpan(start: 9, end: 10, hz: 2700, band: 22)],
                   quiet: [(0, 2), (5, 9)],
                   framesForSource6and7: (90, 120)),
    ]
}
