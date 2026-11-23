import Foundation

/// 스펙트럼 때문에 내보내지 못하는 이유의 분류와 사용자에게 보일 글(SP-EXPORT-E3, 2026-11-23, 엔진 내부).
/// 정책은 기존 그대로다: 그릴 수 없는 스펙트럼은 빼지 않고 내보내기를 막는다(D-S3·D-S8).
/// 아직 앱의 내보내기 단추·알림에 이어져 있지 않다 — 앱은 스펙트럼이 있으면 전부 막는 기존 안내를 쓴다. 글은 제안이며 소유자 승인 전이다.
enum SpectrumExportIssue: Equatable, Sendable {
    /// 소스를 고르지 않음
    case unsetSource(lane: String, range: Range<Int>)
    /// 고른 소스(소리 클립 계보)가 타임라인에 없음
    case missingSource(lane: String, range: Range<Int>)
    /// 고른 소스의 조각이 같은 시각에 겹침(D-S8). overlaps는 겹친 타임라인 구간
    case overlappingSource(lane: String, range: Range<Int>, overlaps: [Range<Int>])
    /// 소스의 원본 파일을 쓸 수 없음(목록에 없음 — 누락·재연결 전)
    case originalUnavailable(lane: String)
    /// 원본 파일이 바뀌었거나 읽을 수 없음
    case originalChanged
    /// 메모리 한도(그림·발자국 또는 디코딩한 소리)를 넘음
    case resourceLimit
    /// 그 밖의 내부 오류(글에 원시 오류를 싣지 않는다)
    case internalFailure

    /// 타임라인만 보고 아는 이유(내보내기 전에 쓴다). Timeline.spectrumExportBlockers와 같은 판정·같은 차례.
    static func blocking(_ timeline: Timeline) -> [SpectrumExportIssue] { timeline.spectrumExportBlockers().map(issue) }
    static func issue(_ b: SpectrumExportBlocker) -> SpectrumExportIssue {
        switch b.reason {
        case .unsetSource: return .unsetSource(lane: b.laneLabel, range: b.range)
        case .missingSource: return .missingSource(lane: b.laneLabel, range: b.range)
        case .overlappingSource(let o): return .overlappingSource(lane: b.laneLabel, range: b.range, overlaps: o.map(\.range))
        }
    }
    /// 공급기의 오류를 이유로. 취소는 이유가 아니다(빈 배열).
    static func issues(for error: Error, timeline: Timeline) -> [SpectrumExportIssue] {
        if error is CancellationError { return [] }
        if let e = error as? SpectrumAnalysisError {
            switch e {
            case .cancelled: return []
            case .overlappingPieces: return blocking(timeline).filter { if case .overlappingSource = $0 { return true }; return false }.nonEmpty ?? [.internalFailure]
            default: return [.internalFailure]
            }
        }
        guard let e = error as? SpectrumTimelineExportError else { return [.internalFailure] }
        switch e {
        case .blocked(let blockers): return blockers.map(issue)
        case .sourceUnavailable(let id): return [.originalUnavailable(lane: timeline.spectrum(id).map { timeline.laneLabel($0.lane) } ?? "")]
        case .sourceChanged: return [.originalChanged]
        case .frameState(let id, _, let state):
            guard let s = timeline.spectrum(id) else { return [.internalFailure] }
            let lane = timeline.laneLabel(s.lane), range = s.start..<s.end
            switch state {
            case .unset: return [.unsetSource(lane: lane, range: range)]
            case .missing: return [.missingSource(lane: lane, range: range)]
            case .overlap: return [.overlappingSource(lane: lane, range: range, overlaps: timeline.spectrumOverlaps(key: s.sourceKey ?? UUID(), within: timeline.spectrumAnalysisReach(s)).map(\.range))]
            case .ok, .notVisible: return [.internalFailure]
            }
        case .pcmBudgetExceeded, .frameMemoryBudgetExceeded: return [.resourceLimit]
        case .invalidLimits, .invalidTimeline, .frameOutOfRange, .concurrentRequest, .closed: return [.internalFailure]
        }
    }

    /// 타임라인 프레임(30 fps)을 분:초로
    static func clock(_ frame: Int) -> String {
        let seconds = max(0, frame) / 30
        return "\(seconds / 60):" + (seconds % 60 < 10 ? "0" : "") + "\(seconds % 60)"
    }
    static func span(_ r: Range<Int>) -> String { clock(r.lowerBound) + "~" + clock(r.upperBound) }
    private static func name(_ lane: String, _ range: Range<Int>? = nil) -> String {
        let where_ = range.map { lane.isEmpty ? span($0) : "\(lane), \(span($0))" } ?? lane
        return where_.isEmpty ? "스펙트럼" : "스펙트럼(\(where_))"
    }
    /// 사용자에게 보일 글(한국어). 무엇이 문제이고 무엇을 하면 되는지 적는다.
    var message: String {
        switch self {
        case let .unsetSource(lane, range):
            return "\(Self.name(lane, range))의 소리 소스를 고르지 않아 내보낼 수 없습니다. 소스를 고르거나 스펙트럼을 삭제해 주세요."
        case let .missingSource(lane, range):
            return "\(Self.name(lane, range))이 쓰던 소리 클립이 타임라인에 없어 내보낼 수 없습니다. 다른 소스를 고르거나 스펙트럼을 삭제해 주세요."
        case let .overlappingSource(lane, range, overlaps):
            let at = overlaps.isEmpty ? "" : "(" + overlaps.prefix(3).map(Self.span).joined(separator: ", ") + (overlaps.count > 3 ? " 등" : "") + ")"
            return "\(Self.name(lane, range))의 소스 소리 조각이 같은 시각에 겹쳐 있어\(at) 내보낼 수 없습니다. 겹친 조각을 옮기거나 다른 소스를 골라 주세요."
        case let .originalUnavailable(lane):
            return "\(Self.name(lane))의 소리 원본 파일을 찾을 수 없어 내보낼 수 없습니다. 원본을 다시 연결해 주세요."
        case .originalChanged:
            return "내보내는 동안 원본 파일이 바뀌었거나 읽을 수 없게 되어 내보내기를 멈췄습니다. 원본을 확인한 뒤 다시 내보내 주세요."
        case .resourceLimit:
            return "스펙트럼을 그리는 데 필요한 메모리가 한도를 넘어 내보내기를 멈췄습니다. 같은 시각에 보이는 스펙트럼의 수나 크기를 줄여 주세요."
        case .internalFailure:
            return "스펙트럼을 내보내는 중 문제가 생겨 내보내기를 멈췄습니다. 다시 시도해 주세요."
        }
    }
}

private extension Array {
    var nonEmpty: [Element]? { isEmpty ? nil : self }
}
