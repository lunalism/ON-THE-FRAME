import Foundation

/// 타임라인의 클립. 타임라인 구간 [start, start + length) 타임라인 프레임(30 fps), 원본 구간 [sourceIn, sourceIn + length)는
/// 원본 트랙 시작에서 잰 시각을 같은 1/30 s 단위로 나타낸다(A-010: 원본 프레임레이트와 무관, 29.97·25·가변 원본 포함).
/// 타임라인 프레임 k의 원본 시각은 정확히 (sourceIn + k − start)/30 s이고, 그 시각에 표시 중인 원본 프레임이 나온다.
/// 클립의 소리는 영상에 연결되어 같은 시각 구간으로 움직인다.
public struct Clip: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let mediaID: UUID
    public let start: Int
    public let sourceIn: Int
    public let length: Int
    public init(id: UUID = UUID(), mediaID: UUID, start: Int, sourceIn: Int, length: Int) {
        self.id = id; self.mediaID = mediaID; self.start = start; self.sourceIn = sourceIn; self.length = length
    }
    public var end: Int { start + length }
    public var sourceOut: Int { sourceIn + length }
    func moved(by d: Int) -> Clip { Clip(id: id, mediaID: mediaID, start: start + d, sourceIn: sourceIn, length: length) }
}

public enum EditError: Error, Equatable, CustomStringConvertible {
    case unknownClip, unknownMedia, splitAtBoundary, outOfSource, tooShort, badIndex
    public var description: String {
        switch self {
        case .unknownClip: return "클립을 찾을 수 없습니다."
        case .unknownMedia: return "미디어를 찾을 수 없습니다."
        case .splitAtBoundary: return "클립 경계, 빈틈, 클립 밖에서는 자를 수 없습니다."
        case .outOfSource: return "원본 범위를 벗어납니다."
        case .tooShort: return "클립은 최소 1프레임이어야 합니다."
        case .badIndex: return "위치가 올바르지 않습니다."
        }
    }
}

/// 불변 타임라인 스냅샷(M1: 영상 트랙 1개, 클립은 겹치지 않음, 명시적 빈틈 허용 — D-020).
/// - 클립은 시작 프레임 순으로 정렬되고 서로 겹치지 않는다. 클립이 덮지 않는 [0, durationFrames) 구간은 빈틈이다
///   (영상 검정, 소리 없음).
/// - 길이(durationFrames)는 따로 저장한다. 일반 삭제는 길이를 바꾸지 않는다(마지막·유일한 클립을 지워도). 빈 새 프로젝트는 0이다.
/// - 편집 규칙(빈틈과 함께 일관되게):
///   - 삽입: 기존 클립의 시작(또는 타임라인 끝)에 끼워 넣고, 그 지점 이후 클립을 삽입 길이만큼 뒤로 민다(리플 삽입). 빈틈은 그대로 밀린다.
///   - 트림: 클립 시작 위치는 고정하고 길이를 바꾼다. 뒤 클립은 길이 변화만큼 움직인다(리플 트림, 빈틈 유지).
///   - 이동: 클립의 원래 구간을 닫고(리플), 대상 지점에 리플 삽입한다. 제자리 이동은 아무것도 바꾸지 않는다.
///   - 일반 삭제(lifting): 클립만 지우고 빈틈을 남긴다. 다른 클립 위치와 길이는 그대로다.
///   - 리플 삭제(rippleDeleting): 클립 구간을 지우고 그 뒤 클립을 클립 길이만큼 앞으로 당긴다. 길이가 그만큼 줄어든다.
///   - 자르기: 클립 내부에서만. 경계·빈틈·밖에서는 거부한다.
/// 편집은 새 스냅샷을 돌려주고, 잘못된 편집은 오류를 던지며 원래 스냅샷을 바꾸지 않는다.
public struct Timeline: Sendable, Equatable {
    public let clips: [Clip]
    /// 미디어 id → 원본 프레임 수(범위 검사용)
    public let mediaFrames: [UUID: Int]
    public let durationFrames: Int

    /// durationFrames를 주지 않으면 마지막 클립 끝을 길이로 한다. 주면 마지막 클립 끝보다 짧을 수 없다.
    public init(clips: [Clip] = [], mediaFrames: [UUID: Int] = [:], durationFrames: Int? = nil) {
        let sorted = clips.sorted { $0.start < $1.start }
        self.clips = sorted
        self.mediaFrames = mediaFrames
        self.durationFrames = max(durationFrames ?? 0, sorted.last?.end ?? 0)
    }

    /// 클립이 하나도 없는가(길이가 0보다 커도 전부 빈틈이면 true)
    public var isEmpty: Bool { clips.isEmpty }
    /// 마지막 유효 프레임(D-018: 끝 시각에서는 이 프레임을 유지. 빈틈이면 검정). 길이 0이면 nil.
    public var lastValidFrame: Int? { durationFrames > 0 ? durationFrames - 1 : nil }
    public var starts: [Int] { clips.map(\.start) }
    /// 빈틈 구간(프레임, 시작 순)
    public var gaps: [Range<Int>] {
        var out: [Range<Int>] = [], cursor = 0
        for c in clips { if c.start > cursor { out.append(cursor..<c.start) }; cursor = c.end }
        if durationFrames > cursor { out.append(cursor..<durationFrames) }
        return out
    }
    /// 불변식: 정렬, 겹침 없음, 0 이상, 길이 안, 1프레임 이상, 원본 범위 안
    public var isValid: Bool {
        var cursor = 0
        for c in clips {
            guard c.start >= cursor, c.length >= 1, c.sourceIn >= 0 else { return false }
            if let n = mediaFrames[c.mediaID], c.sourceOut > n { return false }
            cursor = c.end
        }
        return cursor <= durationFrames
    }

    public func index(of id: UUID) -> Int? { clips.firstIndex { $0.id == id } }
    public func start(of id: UUID) -> Int? { index(of: id).map { clips[$0].start } }
    /// 타임라인 프레임 n을 포함하는 클립의 위치(빈틈이면 nil)
    public func clipIndex(atFrame n: Int) -> Int? { clips.firstIndex { n >= $0.start && n < $0.end } }
    /// 타임라인 프레임 n → (미디어, 원본 위치(1/30 s 단위 원본 시각)). 빈틈이면 nil.
    public func source(atFrame n: Int) -> (mediaID: UUID, frame: Int)? {
        guard let i = clipIndex(atFrame: n) else { return nil }
        return (clips[i].mediaID, clips[i].sourceIn + n - clips[i].start)
    }

    public func registering(_ asset: MediaAsset) -> Timeline {
        var m = mediaFrames; m[asset.id] = asset.frameCount
        return Timeline(clips: clips, mediaFrames: m, durationFrames: durationFrames)
    }

    /// 지점 p 이후(시작 ≥ p) 클립을 d만큼 옮긴다
    private func shifting(from p: Int, by d: Int, clips cs: [Clip]) -> [Clip] { cs.map { $0.start >= p ? $0.moved(by: d) : $0 } }

    /// 미디어 전체를 클립으로 index 위치(기본: 끝)에 리플 삽입한다. 위치는 clips[index]의 시작, 또는 타임라인 끝.
    public func inserting(media id: UUID, at index: Int? = nil, clipID: UUID = UUID()) throws -> Timeline {
        guard let n = mediaFrames[id], n >= 1 else { throw EditError.unknownMedia }
        let i = index ?? clips.count
        guard (0...clips.count).contains(i) else { throw EditError.badIndex }
        let p = i < clips.count ? clips[i].start : durationFrames
        var cs = shifting(from: p, by: n, clips: clips)
        cs.append(Clip(id: clipID, mediaID: id, start: p, sourceIn: 0, length: n))
        return Timeline(clips: cs, mediaFrames: mediaFrames, durationFrames: durationFrames + n)
    }

    /// 타임라인 프레임 at에서 클립을 나눈다. at은 클립 내부(시작 초과, 끝 미만)여야 한다.
    public func splitting(clip id: UUID, atFrame at: Int, newIDs: (UUID, UUID) = (UUID(), UUID())) throws -> Timeline {
        guard let i = index(of: id) else { throw EditError.unknownClip }
        let c = clips[i]
        guard at > c.start, at < c.end else { throw EditError.splitAtBoundary }
        let k = at - c.start
        var cs = clips
        cs.replaceSubrange(i...i, with: [Clip(id: newIDs.0, mediaID: c.mediaID, start: c.start, sourceIn: c.sourceIn, length: k),
                                         Clip(id: newIDs.1, mediaID: c.mediaID, start: at, sourceIn: c.sourceIn + k, length: c.length - k)])
        return Timeline(clips: cs, mediaFrames: mediaFrames, durationFrames: durationFrames)
    }

    /// 클립의 원본 구간을 [sourceIn, sourceIn + length)로 바꾼다(시작 위치 고정, 리플: 뒤 클립이 길이 변화만큼 움직인다).
    public func trimming(clip id: UUID, sourceIn: Int, length: Int) throws -> Timeline {
        guard let i = index(of: id) else { throw EditError.unknownClip }
        let c = clips[i]
        guard let n = mediaFrames[c.mediaID] else { throw EditError.unknownMedia }
        guard length >= 1 else { throw EditError.tooShort }
        guard sourceIn >= 0, sourceIn + length <= n else { throw EditError.outOfSource }
        let d = length - c.length
        var cs = clips
        cs[i] = Clip(id: c.id, mediaID: c.mediaID, start: c.start, sourceIn: sourceIn, length: length)
        for k in (i + 1)..<cs.count { cs[k] = cs[k].moved(by: d) }
        return Timeline(clips: cs, mediaFrames: mediaFrames, durationFrames: durationFrames + d)
    }
    /// 왼쪽 가장자리를 delta 프레임 옮긴다(양수 = 안쪽으로). 원본 범위·최소 1프레임 안으로 제한한다.
    public func trimmingStart(clip id: UUID, by delta: Int) throws -> Timeline {
        guard let i = index(of: id) else { throw EditError.unknownClip }
        let c = clips[i]
        let d = max(-c.sourceIn, min(delta, c.length - 1))
        return try trimming(clip: id, sourceIn: c.sourceIn + d, length: c.length - d)
    }
    /// 오른쪽 가장자리를 delta 프레임 옮긴다(양수 = 바깥쪽으로).
    public func trimmingEnd(clip id: UUID, by delta: Int) throws -> Timeline {
        guard let i = index(of: id) else { throw EditError.unknownClip }
        let c = clips[i]
        guard let n = mediaFrames[c.mediaID] else { throw EditError.unknownMedia }
        let d = max(1 - c.length, min(delta, n - c.sourceOut))
        return try trimming(clip: id, sourceIn: c.sourceIn, length: c.length + d)
    }

    /// 클립을 다른 클립 사이에 끼워 넣는다. toIndex는 "옮기기 전 목록"에서의 끼워 넣을 자리(0…count).
    /// 원래 구간을 닫고(리플) 대상 지점(그 자리 클립의 시작 또는 끝)에 리플 삽입한다. 제자리면 그대로 돌려준다.
    public func moving(clip id: UUID, toIndex: Int) throws -> Timeline {
        guard let i = index(of: id) else { throw EditError.unknownClip }
        guard (0...clips.count).contains(toIndex) else { throw EditError.badIndex }
        if toIndex == i || toIndex == i + 1 { return self }
        let c = clips[i]
        let closed = try rippleDeleting(clip: id)
        let j = toIndex > i ? toIndex - 1 : toIndex
        let p = j < closed.clips.count ? closed.clips[j].start : closed.durationFrames
        var cs = shifting(from: p, by: c.length, clips: closed.clips)
        cs.append(Clip(id: c.id, mediaID: c.mediaID, start: p, sourceIn: c.sourceIn, length: c.length))
        return Timeline(clips: cs, mediaFrames: mediaFrames, durationFrames: closed.durationFrames + c.length)
    }

    /// 일반 삭제: 클립(과 연결된 소리)만 지우고 빈틈을 남긴다. 다른 클립 위치와 타임라인 길이는 그대로다.
    public func lifting(clip id: UUID) throws -> Timeline {
        guard let i = index(of: id) else { throw EditError.unknownClip }
        var cs = clips; cs.remove(at: i)
        return Timeline(clips: cs, mediaFrames: mediaFrames, durationFrames: durationFrames)
    }

    /// 리플 삭제: 클립 구간을 지우고 그 뒤 클립을 클립 길이만큼 앞으로 당긴다. 타임라인 길이가 그만큼 줄어든다.
    public func rippleDeleting(clip id: UUID) throws -> Timeline {
        guard let i = index(of: id) else { throw EditError.unknownClip }
        let c = clips[i]
        var cs = clips; cs.remove(at: i)
        cs = shifting(from: c.end, by: -c.length, clips: cs)
        return Timeline(clips: cs, mediaFrames: mediaFrames, durationFrames: durationFrames - c.length)
    }
}

/// 편집 기록: 실행 취소·다시 실행과 드래그 제스처(완료한 드래그 하나 = 한 단계, 취소하면 원래 상태).
/// 각 단계는 편집 뒤 선택할 클립 id(focus)를 함께 기록한다.
public struct EditHistory: Sendable {
    public struct Entry: Sendable, Equatable { public let timeline: Timeline; public let focus: UUID? }
    public private(set) var current: Entry
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var gestureBase: Entry?

    public init(_ t: Timeline = Timeline()) { current = Entry(timeline: t, focus: nil) }
    public var timeline: Timeline { current.timeline }
    public var canUndo: Bool { !undoStack.isEmpty && gestureBase == nil }
    public var canRedo: Bool { !redoStack.isEmpty && gestureBase == nil }
    public var inGesture: Bool { gestureBase != nil }
    public var undoDepth: Int { undoStack.count }

    /// 실행 취소 대상이 아닌 변경(미디어 등록 등)
    public mutating func replaceWithoutUndo(_ t: Timeline) { current = Entry(timeline: t, focus: current.focus) }

    /// 한 번에 끝나는 편집. 같은 상태면 기록하지 않는다.
    public mutating func apply(_ t: Timeline, focus: UUID?) {
        precondition(gestureBase == nil, "gesture in progress")
        guard t != current.timeline else { return }
        undoStack.append(current); redoStack.removeAll()
        current = Entry(timeline: t, focus: focus)
    }

    public mutating func beginGesture() { if gestureBase == nil { gestureBase = current } }
    /// 드래그 중 미리 보기 상태(기록하지 않음)
    public mutating func updateGesture(_ t: Timeline, focus: UUID?) { precondition(gestureBase != nil); current = Entry(timeline: t, focus: focus) }
    public mutating func commitGesture() {
        guard let base = gestureBase else { return }
        gestureBase = nil
        if base.timeline != current.timeline { undoStack.append(base); redoStack.removeAll() } else { current = base }
    }
    public mutating func cancelGesture() { if let base = gestureBase { current = base; gestureBase = nil } }

    /// 되돌린 편집이 영향을 준 클립(되돌리기 전 단계의 focus)을 돌려준다.
    @discardableResult public mutating func undo() -> UUID? {
        guard canUndo, let prev = undoStack.popLast() else { return nil }
        let focus = current.focus
        redoStack.append(current); current = prev
        return focus
    }
    @discardableResult public mutating func redo() -> UUID? {
        guard canRedo, let next = redoStack.popLast() else { return nil }
        undoStack.append(current); current = next
        return next.focus
    }
}
