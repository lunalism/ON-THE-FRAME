import CoreMedia
import Foundation

/// 원본 미디어의 식별. id는 파일 내용의 SHA-256이며, 경로가 바뀌어도 같은 원본을 가리킨다.
public struct SourceRef: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public init(id: String, path: String) { self.id = id; self.path = path }
    public var url: URL { URL(fileURLWithPath: path) }
}

/// 타임라인 위 오디오 클립 1개. TECHNOLOGY-EVALUATION §3.3.2의 s_in, d, t_start.
public struct ClipPlacement: Sendable {
    public let source: SourceRef
    public let sourceIn: CMTime
    public let duration: CMTime
    public let timelineStart: CMTime

    public init(source: SourceRef, sourceIn: CMTime, duration: CMTime, timelineStart: CMTime) {
        self.source = source; self.sourceIn = sourceIn; self.duration = duration; self.timelineStart = timelineStart
    }

    /// 반열린 구간 [t_start, t_start + d) 안이면 s = s_in + (t − t_start), 밖이면 nil.
    public func sourceTime(atTimeline t: CMTime) -> CMTime? {
        guard t >= timelineStart, t < timelineStart + duration else { return nil }
        return sourceIn + (t - timelineStart)
    }
}

/// 렌더링·내보내기 입력. 스펙트럼은 selected에만 연결된다.
/// unrelated는 오디오 믹스에만 들어가며 분석 경로에 전달되지 않는다(DR-09 실험).
public struct TimelineState: Sendable {
    public let selected: ClipPlacement
    public let unrelated: ClipPlacement?
    public let duration: CMTime

    public init(selected: ClipPlacement, unrelated: ClipPlacement?, duration: CMTime = Spec.duration) {
        self.selected = selected; self.unrelated = unrelated; self.duration = duration
    }
}

/// 타임라인의 비디오 프레임 격자. 프레임 n은 시각 n·frameDuration에 시작하며, 시작 시각이 [0, duration) 안인
/// 프레임만 유효하다(반열린 구간). 마지막 유효 프레임 = ceil(duration / frameDuration) − 1.
/// duration이 0 이하이거나 수치가 아니면(빈 타임라인) 유효 프레임이 없으므로 nil.
public enum FrameGrid {
    public static func lastValidFrame(duration: CMTime, frameDuration: CMTime) -> Int? {
        guard duration.isNumeric, frameDuration.isNumeric, frameDuration > .zero, duration > .zero else { return nil }
        // 정수 연산: duration.value / duration.timescale ÷ (fd.value / fd.timescale), 올림
        let num = Int64(duration.value) * Int64(frameDuration.timescale)
        let den = Int64(duration.timescale) * Int64(frameDuration.value)
        let count = (num + den - 1) / den
        return count >= 1 ? Int(count - 1) : nil
    }
}

extension TimelineState {
    /// 이 타임라인의 마지막 유효 비디오 프레임 번호. 빈 타임라인이면 nil.
    public func lastValidFrame(frameDuration: CMTime) -> Int? {
        FrameGrid.lastValidFrame(duration: duration, frameDuration: frameDuration)
    }
}
