import Foundation

/// 내보내기 단계. 경과 시간은 준비(composition 구성)부터 승격까지 모두 센다.
public enum ExportStage: Sendable, Equatable {
    /// composition 구성 등 인코딩 전 준비
    case preparing
    /// 인코딩(진행률 [0, 0.99])
    case encoding
    /// 인코딩이 끝나고 출력 검증·대상 위치로 옮기는 중(진행률은 그대로 두고 1.0은 성공 뒤에만)
    case finalizing
}

/// 내보내기 남은 시간 추정(순수 값 타입, 시각은 호출자가 주는 단조 시계 초).
/// - 처음에는, 그리고 추정을 믿을 수 없으면 `.calculating`이다: 시작 뒤 `minElapsed` 초 미만, 진행률 `minProgress` 미만,
///   진행률 표본 `minSamples`개 미만, 최근 `stallSeconds` 초 동안 진행률이 늘지 않음, 속도가 거의 0.
/// - 속도는 최근 `window` 초 동안의 진행률 증가 ÷ 그 시간이다(조회 시각 기준). 짧은 흔들림은 창 안에서 평균되고,
///   계속된 느려짐은 창 길이만큼 지나면 그대로 드러난다. 경과 시간 ÷ 진행률(처음부터의 평균)은 쓰지 않는다
///   (진행률이 0에 가까울 때 값이 터지고, 느려짐을 숨긴다). 창이 아직 차지 않았으면 시작부터의 구간을 쓴다.
/// - 남은 양은 인코딩 상한(0.99)까지다. 검증·승격은 `.finalizing`으로 따로 보인다("0초 남음"을 보이지 않음).
/// - 진행률을 꾸며 내지 않는다. 추정은 표시용이며 진행률 값을 바꾸지 않는다.
public struct ExportTimeEstimator: Sendable {
    public enum Remaining: Sendable, Equatable {
        case calculating
        case approx(seconds: Double)
        case finalizing
    }

    public var minElapsed = 3.0
    public var minProgress = 0.02
    public var minSamples = 3
    public var window = 5.0
    public var stallSeconds = 5.0
    public var encodingCap = 0.99

    public private(set) var start: Double?
    public private(set) var stage: ExportStage = .preparing
    /// (시각, 진행률). 시작 시 (start, 0)을 넣는다.
    public private(set) var samples: [(t: Double, p: Double)] = []
    /// 마지막으로 진행률이 늘어난 시각
    public private(set) var lastIncrease: Double?

    public init() {}

    /// 새 내보내기 시작(이전 표본·추정은 모두 지운다)
    public mutating func reset(at t: Double) {
        start = t; stage = .preparing; samples = [(t, 0)]; lastIncrease = nil
    }
    public mutating func setStage(_ s: ExportStage) { stage = s }

    /// 진행률 표본. 줄어든 값·유한하지 않은 값은 버린다(ExportService도 보장하지만 방어).
    public mutating func record(progress p: Double, at t: Double) {
        guard start != nil, p.isFinite else { return }
        let last = samples.last?.p ?? 0
        guard p >= last else { return }
        if p > last { lastIncrease = t }
        samples.append((t, p))
        if samples.count > 2000 { samples.removeFirst(samples.count - 2000) }
    }

    public var progress: Double { samples.last?.p ?? 0 }

    public func elapsed(at now: Double) -> Double { start.map { max(0, now - $0) } ?? 0 }

    /// 시각 t의 진행률(표본 사이는 앞 표본 값 유지 — 진행률은 계단처럼 보고된다)
    func progress(at t: Double) -> Double {
        var v = 0.0
        for s in samples { if s.t <= t { v = s.p } else { break } }
        return v
    }

    public func remaining(at now: Double) -> Remaining {
        if stage == .finalizing { return .finalizing }
        guard let start, stage == .encoding else { return .calculating }
        // 인코딩 진행률이 상한에 닿았는데 아직 끝나지 않음(파일 마무리): "0초 남음" 대신 마무리로 보인다
        if encodingCap - progress <= 0.0005 { return .finalizing }
        let el = now - start
        let p = progress
        let increases = samples.dropFirst().count
        guard el >= minElapsed, p >= minProgress, increases >= minSamples else { return .calculating }
        guard let li = lastIncrease, now - li < stallSeconds else { return .calculating }
        let from = max(start, now - window)
        let span = now - from
        guard span > 0 else { return .calculating }
        let rate = (p - progress(at: from)) / span
        guard rate > 1e-4 else { return .calculating }
        return .approx(seconds: max(0, encodingCap - p) / rate)
    }
}

/// 시간 표시: 1시간 미만 "MM:SS", 이상 "H:MM:SS". 음수·비유한 값은 0으로 본다.
public enum ClockText {
    public static func format(_ seconds: Double, roundUp: Bool = false) -> String {
        let s = seconds.isFinite ? max(0, seconds) : 0
        let n = Int(roundUp ? s.rounded(.up) : s.rounded(.down))
        let h = n / 3600, m = (n / 60) % 60, sec = n % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
    /// "경과 00:12"
    public static func elapsed(_ seconds: Double) -> String { "경과 " + format(seconds) }
    /// "남은 시간 약 00:35" / "남은 시간 계산 중…" / "마무리 중…"
    public static func remaining(_ r: ExportTimeEstimator.Remaining) -> String {
        switch r {
        case .calculating: return "남은 시간 계산 중…"
        case .finalizing: return "마무리 중…"
        case .approx(let s): return "남은 시간 약 " + format(s, roundUp: true)
        }
    }
}
