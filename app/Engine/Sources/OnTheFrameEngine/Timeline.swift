import Foundation

/// 타임라인의 클립. 타임라인 구간 [start, start + length) 타임라인 프레임(30 fps), 원본 구간 [sourceIn, sourceIn + length)는
/// 원본 트랙 시작에서 잰 시각을 같은 1/30 s 단위로 나타낸다(A-010: 원본 프레임레이트와 무관, 29.97·25·가변 원본 포함).
/// 타임라인 프레임 k의 원본 시각은 정확히 (sourceIn + k − start)/30 s이고, 그 시각에 표시 중인 원본 프레임(영상)·소리(소리 레인)가 나온다.
/// A-012: 클립은 영상 레인 또는 원본 소리 레인에 있다. 같은 link 값을 가진 영상·소리 클립 한 쌍이 "연결된 쌍"이다.
public struct Clip: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let mediaID: UUID
    public let start: Int
    public let sourceIn: Int
    public let length: Int
    /// 연결 묶음 ID(연결된 영상·소리 쌍이 같은 값을 가진다). nil이면 연결 없음.
    public let link: UUID?
    public init(id: UUID = UUID(), mediaID: UUID, start: Int, sourceIn: Int, length: Int, link: UUID? = nil) {
        self.id = id; self.mediaID = mediaID; self.start = start; self.sourceIn = sourceIn; self.length = length; self.link = link
    }
    public var end: Int { start + length }
    public var sourceOut: Int { sourceIn + length }
    /// 원본 시각 0이 놓이는 타임라인 위치(영상·소리 동기 비교용): start − sourceIn
    public var anchor: Int { start - sourceIn }
    func moved(by d: Int) -> Clip { Clip(id: id, mediaID: mediaID, start: start + d, sourceIn: sourceIn, length: length, link: link) }
    func with(start: Int? = nil, sourceIn: Int? = nil, length: Int? = nil, id: UUID? = nil, link: UUID?? = nil) -> Clip {
        Clip(id: id ?? self.id, mediaID: mediaID, start: start ?? self.start, sourceIn: sourceIn ?? self.sourceIn,
             length: length ?? self.length, link: link ?? self.link)
    }
}

/// 프로젝트가 참조하는 원본 미디어(A-013). 원본은 프로젝트 밖에 있고 읽기만 한다. 같은 id가 클립의 mediaID다.
/// 위치(path)·식별(크기·수정 시각)·검사 결과(길이·소리·크기·코덱)를 담는다. 샌드박스 접근 북마크는 저장 파일에만 있다(여기 없음).
public struct MediaRef: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    /// 절대 경로(표시·재연결 힌트)
    public var path: String
    /// 원본 길이 안의 타임라인(30 fps) 프레임 수
    public var frameCount: Int
    public var hasAudio: Bool
    public var size: Int64
    public var modifiedNs: Int64
    public var codec: String
    public var width: Int
    public var height: Int
    public init(id: UUID, name: String, path: String, frameCount: Int, hasAudio: Bool, size: Int64, modifiedNs: Int64, codec: String, width: Int, height: Int) {
        self.id = id; self.name = name; self.path = path; self.frameCount = frameCount; self.hasAudio = hasAudio
        self.size = size; self.modifiedNs = modifiedNs; self.codec = codec; self.width = width; self.height = height
    }
    public init(_ a: MediaAsset) {
        self.init(id: a.id, name: a.name, path: a.url.standardizedFileURL.path, frameCount: a.frameCount, hasAudio: a.hasAudio,
                  size: a.identity.size, modifiedNs: a.identity.modifiedNs, codec: a.codec, width: Int(a.displaySize.width), height: Int(a.displaySize.height))
    }
}

/// 레인(A-012). 이름은 클립·파일 이름과 따로이며 안정된 레인 ID에 붙는다(이후 프로젝트 파일에 그대로 둘 수 있게 Codable).
public enum LaneKind: String, Sendable, Codable { case video, audio }
public struct Lane: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let kind: LaneKind
    public var name: String
    public init(id: UUID, kind: LaneKind, name: String) { self.id = id; self.kind = kind; self.name = name }
    public static let videoID = UUID(uuidString: "0F7EF0A0-0000-4000-8000-000000000001")!
    public static let audioID = UUID(uuidString: "0F7EF0A0-0000-4000-8000-000000000002")!
    public static let defaults = [Lane(id: videoID, kind: .video, name: "원본소스"), Lane(id: audioID, kind: .audio, name: "원본소리")]
}

public enum EditError: Error, Equatable, CustomStringConvertible {
    case unknownClip, unknownMedia, splitAtBoundary, outOfSource, tooShort, badIndex
    /// 리플 편집 지점·구간에 다른 클립이 걸쳐 있음(그대로 하면 동기가 깨지거나 겹친다)
    case crossingContent
    /// 같은 레인의 다른 클립과 겹침(덮어쓰지 않는다)
    case overlap
    /// 연결된 쌍의 다른 클립 범위 밖이라 함께 자를 수 없음
    case linkedSplitOutside
    case linkNeedsPair, linkDifferentMedia, alreadyLinked, notLinked
    case emptyName, unknownLane
    /// 재연결: 새 파일이 기존 클립의 원본 구간을 모두 덮지 못함(클립을 줄이지 않음)
    case relinkTooShort(need: Int, have: Int)
    /// 재연결: 소리 클립이 쓰는데 새 파일에 소리가 없음
    case relinkNoAudio
    public var description: String {
        switch self {
        case .unknownClip: return "클립을 찾을 수 없습니다."
        case .unknownMedia: return "미디어를 찾을 수 없습니다."
        case .splitAtBoundary: return "클립 경계, 빈틈, 클립 밖에서는 자를 수 없습니다."
        case .outOfSource: return "원본 범위를 벗어납니다."
        case .tooShort: return "클립은 최소 1프레임이어야 합니다."
        case .badIndex: return "위치가 올바르지 않습니다."
        case .crossingContent: return "다른 레인의 클립이 이 지점(구간)에 걸쳐 있어 리플 편집을 할 수 없습니다. 동기가 깨질 수 있기 때문입니다. 일반 삭제(Delete)를 쓰거나 걸친 클립을 먼저 옮기세요."
        case .overlap: return "같은 레인의 다른 클립과 겹칩니다. 클립을 덮어쓰지 않으므로 빈 곳에 놓으세요."
        case .linkedSplitOutside: return "연결된 짝 클립이 이 위치를 덮지 않아 함께 자를 수 없습니다. 연결을 해제한 뒤 자르세요."
        case .linkNeedsPair: return "연결하려면 연결되지 않은 영상 클립 하나와 소리 클립 하나를 고르세요(⌘-클릭으로 둘째 클립 추가)."
        case .linkDifferentMedia: return "같은 원본에서 나온 영상·소리 클립만 연결할 수 있습니다."
        case .alreadyLinked: return "이미 연결된 클립입니다."
        case .notLinked: return "연결되지 않은 클립입니다."
        case .emptyName: return "이름이 비어 있어 이전 이름으로 되돌렸습니다."
        case .unknownLane: return "레인을 찾을 수 없습니다."
        case .relinkTooShort(let need, let have): return "고른 파일이 너무 짧습니다(필요 \(need)프레임, 파일 \(have)프레임). 클립을 줄이지 않으므로 같은 원본을 고르세요."
        case .relinkNoAudio: return "고른 파일에 소리가 없습니다. 원본 소리 레인의 클립이 이 원본의 소리를 씁니다."
        }
    }
}

/// 불변 타임라인 스냅샷(A-012: 영상 레인 1개 + 원본 소리 레인 1개, 레인마다 클립은 겹치지 않음, 명시적 빈틈 허용 — D-020).
/// - clips = 영상 레인, audioClips = 원본 소리 레인(각각 시작 순). 클립이 덮지 않는 [0, durationFrames)는 빈틈이다(영상 검정, 소리 없음).
/// - 길이(durationFrames)는 따로 저장한다. 일반 삭제는 길이를 바꾸지 않는다.
/// - 편집은 대상 클립의 "묶음"(연결된 쌍이면 둘, 아니면 하나)에 함께 적용된다.
///   - 삽입: 기존 영상 클립의 시작(또는 끝)에 영상(+소리가 있으면 연결된 소리) 클립을 끼워 넣고, 그 지점 이후 두 레인의 클립을 민다(리플).
///   - 트림: 묶음 각각의 시작 위치는 고정, 같은 양만큼 길이를 바꾸고 뒤를 리플로 민다·당긴다.
///   - 이동(끼워 넣기): 연결된 쌍·소리 없는 영상 클립은 원래 구간을 닫고(리플) 대상 지점에 리플 삽입한다(D-020 유지).
///   - 이동(자유): 연결을 해제한 클립은 같은 레인의 원하는 위치(빈틈 포함)로 옮긴다. 원래 자리는 빈틈이 되고, 겹치면 거부한다.
///   - 일반 삭제: 묶음만 지우고 빈틈을 남긴다. 리플 삭제: 묶음 구간을 두 레인에서 닫는다.
///   - 리플 편집(삽입·트림·이동·리플 삭제)의 지점·구간에 묶음이 아닌 클립이 걸치면 거부한다(동기 보호, 이 마일스톤의 규칙).
///   - 연결 해제·연결: 위치·원본 구간을 바꾸지 않는다(다시 맞추지 않음). 어긋남은 offset으로 보인다.
/// 편집은 새 스냅샷을 돌려주고, 잘못된 편집은 오류를 던지며 원래 스냅샷을 바꾸지 않는다. 결과는 늘 불변식(isValid)을 만족한다.
public struct Timeline: Sendable, Equatable {
    public let clips: [Clip]
    public let audioClips: [Clip]
    public let lanes: [Lane]
    /// 프로젝트의 원본 미디어 목록(가져온 순서). 타임라인에 쓰지 않은 미디어도 포함한다(A-013).
    public let media: [MediaRef]
    /// 미디어 id → 원본 프레임 수(범위 검사용)
    public let mediaFrames: [UUID: Int]
    /// 미디어 id → 소리 트랙이 있는가(삽입 때 연결된 소리 클립을 만들지)
    public let mediaHasAudio: [UUID: Bool]
    public let durationFrames: Int

    /// durationFrames를 주지 않으면 마지막 클립 끝을 길이로 한다. 주면 마지막 클립 끝보다 짧을 수 없다.
    public init(clips: [Clip] = [], audioClips: [Clip] = [], lanes: [Lane] = Lane.defaults, media: [MediaRef] = [], mediaFrames: [UUID: Int] = [:],
                mediaHasAudio: [UUID: Bool] = [:], durationFrames: Int? = nil) {
        let v = clips.sorted { $0.start < $1.start }, a = audioClips.sorted { $0.start < $1.start }
        self.clips = v; self.audioClips = a; self.lanes = lanes; self.media = media
        self.mediaFrames = mediaFrames; self.mediaHasAudio = mediaHasAudio
        self.durationFrames = max(durationFrames ?? 0, v.last?.end ?? 0, a.map(\.end).max() ?? 0)
    }
    private func rebuilt(video: [Clip]? = nil, audio: [Clip]? = nil, lanes: [Lane]? = nil, media: [MediaRef]? = nil, mediaFrames: [UUID: Int]? = nil,
                         mediaHasAudio: [UUID: Bool]? = nil, duration: Int? = nil) -> Timeline {
        Timeline(clips: video ?? clips, audioClips: audio ?? audioClips, lanes: lanes ?? self.lanes, media: media ?? self.media, mediaFrames: mediaFrames ?? self.mediaFrames,
                 mediaHasAudio: mediaHasAudio ?? self.mediaHasAudio, durationFrames: duration ?? durationFrames)
    }

    /// 두 레인 모두 클립이 없는가(길이가 0보다 커도 전부 빈틈이면 true)
    public var isEmpty: Bool { clips.isEmpty && audioClips.isEmpty }
    /// 마지막 유효 프레임(D-018: 끝 시각에서는 이 프레임을 유지. 빈틈이면 검정). 길이 0이면 nil.
    public var lastValidFrame: Int? { durationFrames > 0 ? durationFrames - 1 : nil }
    /// 영상 레인 클립 시작들
    public var starts: [Int] { clips.map(\.start) }
    /// 영상 레인 빈틈 구간(프레임, 시작 순)
    public var gaps: [Range<Int>] { Self.gaps(clips, durationFrames) }
    /// 소리 레인 빈틈 구간
    public var audioGaps: [Range<Int>] { Self.gaps(audioClips, durationFrames) }
    static func gaps(_ cs: [Clip], _ dur: Int) -> [Range<Int>] {
        var out: [Range<Int>] = [], cursor = 0
        for c in cs { if c.start > cursor { out.append(cursor..<c.start) }; cursor = c.end }
        if dur > cursor { out.append(cursor..<dur) }
        return out
    }
    /// 불변식: 레인마다 정렬, 겹침 없음, 0 이상, 길이 안, 1프레임 이상, 원본 범위 안. 연결 묶음은 영상 1 + 소리 1.
    public var isValid: Bool {
        for lane in [clips, audioClips] {
            var cursor = 0
            for c in lane {
                guard c.start >= cursor, c.length >= 1, c.sourceIn >= 0 else { return false }
                if let n = mediaFrames[c.mediaID], c.sourceOut > n { return false }
                cursor = c.end
            }
            if cursor > durationFrames { return false }
        }
        var groups: [UUID: (v: Int, a: Int)] = [:]
        for c in clips { if let l = c.link { groups[l, default: (0, 0)].v += 1 } }
        for c in audioClips { if let l = c.link { groups[l, default: (0, 0)].a += 1 } }
        return groups.values.allSatisfy { $0.v == 1 && $0.a == 1 }
    }

    // MARK: 찾기

    public func index(of id: UUID) -> Int? { clips.firstIndex { $0.id == id } }
    public func audioIndex(of id: UUID) -> Int? { audioClips.firstIndex { $0.id == id } }
    public func start(of id: UUID) -> Int? { clip(id)?.start }
    public func clip(_ id: UUID) -> Clip? { clips.first { $0.id == id } ?? audioClips.first { $0.id == id } }
    public func lane(of id: UUID) -> LaneKind? { index(of: id) != nil ? .video : (audioIndex(of: id) != nil ? .audio : nil) }
    /// 연결된 짝(없으면 nil)
    public func partner(of id: UUID) -> Clip? {
        guard let c = clip(id), let l = c.link else { return nil }
        return (clips + audioClips).first { $0.link == l && $0.id != id }
    }
    /// 편집 묶음: 클립과 연결된 짝
    public func group(of id: UUID) -> [Clip] { clip(id).map { [$0] + (partner(of: id).map { [$0] } ?? []) } ?? [] }
    /// 연결된 쌍의 동기 어긋남(프레임, 소리가 영상보다 늦으면 +). 같은 원본이 아니거나 연결되지 않았으면 nil.
    public func syncOffset(of id: UUID) -> Int? {
        guard let c = clip(id), let p = partner(of: id), c.mediaID == p.mediaID else { return nil }
        let (v, a) = lane(of: id) == .video ? (c, p) : (p, c)
        return a.anchor - v.anchor
    }
    /// 자유 이동 대상인가: 연결되지 않은 소리 클립, 또는 소리가 있는 원본에서 연결을 해제한 영상 클립.
    /// 연결된 쌍과 소리 없는 영상 클립은 끼워 넣기 이동(리플)을 쓴다.
    public func movesFreely(_ id: UUID) -> Bool {
        guard let c = clip(id), c.link == nil else { return false }
        return lane(of: id) == .audio || (mediaHasAudio[c.mediaID] ?? false)
    }
    /// 타임라인 프레임 n을 포함하는 영상 클립 위치(빈틈이면 nil)
    public func clipIndex(atFrame n: Int) -> Int? { clips.firstIndex { n >= $0.start && n < $0.end } }
    public func audioClipIndex(atFrame n: Int) -> Int? { audioClips.firstIndex { n >= $0.start && n < $0.end } }
    /// 타임라인 프레임 n → (미디어, 원본 위치(1/30 s 단위 원본 시각)), 영상 레인. 빈틈이면 nil.
    public func source(atFrame n: Int) -> (mediaID: UUID, frame: Int)? {
        guard let i = clipIndex(atFrame: n) else { return nil }
        return (clips[i].mediaID, clips[i].sourceIn + n - clips[i].start)
    }
    public func laneName(_ kind: LaneKind) -> String { lanes.first { $0.kind == kind }?.name ?? "" }

    /// 미디어 등록(가져오기): 범위 검사 정보와 미디어 목록(MediaRef)에 넣는다. 이미 있으면 정보만 갱신한다.
    public func registering(_ asset: MediaAsset) -> Timeline {
        var m = mediaFrames; m[asset.id] = asset.frameCount
        var h = mediaHasAudio; h[asset.id] = asset.hasAudio
        var refs = media
        if let i = refs.firstIndex(where: { $0.id == asset.id }) { refs[i] = MediaRef(asset) } else { refs.append(MediaRef(asset)) }
        return rebuilt(media: refs, mediaFrames: m, mediaHasAudio: h)
    }
    /// 프리뷰용(A-013): 쓸 수 없는 원본의 클립을 뺀 사본(그 구간은 검정·무음). 길이·다른 클립·레인은 그대로다.
    /// 편집 상태가 아니라 프리뷰 구성에만 쓴다(빈틈과 구별해 화면에 따로 표시).
    public func excludingMedia(_ ids: Set<UUID>) -> Timeline {
        guard !ids.isEmpty else { return self }
        return rebuilt(video: clips.filter { !ids.contains($0.mediaID) }, audio: audioClips.filter { !ids.contains($0.mediaID) })
    }
    /// 미디어 재연결(A-013): 같은 id에 새 원본을 붙인다. 이 미디어를 쓰는 모든 클립의 원본 구간이 새 파일 안에 있어야 하고,
    /// 소리 클립이 쓰면 새 파일에 소리가 있어야 한다. 클립·ID·위치는 그대로다(줄이지 않음).
    public func relinking(media id: UUID, to new: MediaRef) throws -> Timeline {
        guard let i = media.firstIndex(where: { $0.id == id }), new.id == id else { throw EditError.unknownMedia }
        let need = (clips + audioClips).filter { $0.mediaID == id }.map(\.sourceOut).max() ?? 0
        guard new.frameCount >= need else { throw EditError.relinkTooShort(need: need, have: new.frameCount) }
        if audioClips.contains(where: { $0.mediaID == id }), !new.hasAudio { throw EditError.relinkNoAudio }
        var refs = media; refs[i] = new
        var m = mediaFrames; m[id] = new.frameCount
        var h = mediaHasAudio; h[id] = new.hasAudio
        return try checked(rebuilt(media: refs, mediaFrames: m, mediaHasAudio: h))
    }

    // MARK: 편집 도우미

    /// 결과 불변식 확인(겹침이면 덮어쓰지 않고 거부)
    private func checked(_ t: Timeline) throws -> Timeline { guard t.isValid else { throw EditError.overlap }; return t }
    /// 지점 p에 묶음이 아닌 클립이 걸쳐 있는가(start < p < end)
    private func crossing(at p: Int, excluding ids: Set<UUID>) -> Bool {
        (clips + audioClips).contains { !ids.contains($0.id) && $0.start < p && p < $0.end }
    }
    /// 시작 ≥ p인(묶음이 아닌) 클립을 d만큼 옮긴다(두 레인)
    private func shifted(_ cs: [Clip], from p: Int, by d: Int, excluding ids: Set<UUID> = []) -> [Clip] {
        cs.map { !ids.contains($0.id) && $0.start >= p ? $0.moved(by: d) : $0 }
    }
    private func replacing(_ cs: [Clip], _ m: [UUID: Clip]) -> [Clip] { cs.map { m[$0.id] ?? $0 } }

    // MARK: 편집

    /// 미디어 전체를 영상 클립(+원본에 소리가 있으면 연결된 소리 클립)으로 index 위치(기본: 끝)에 리플 삽입한다.
    /// 위치는 clips[index]의 시작, 또는 타임라인 끝. 그 지점에 다른 클립이 걸쳐 있으면 거부한다.
    public func inserting(media id: UUID, at index: Int? = nil, clipID: UUID = UUID(), audioClipID: UUID = UUID(), linkID: UUID = UUID()) throws -> Timeline {
        guard let n = mediaFrames[id], n >= 1 else { throw EditError.unknownMedia }
        let i = index ?? clips.count
        guard (0...clips.count).contains(i) else { throw EditError.badIndex }
        let p = i < clips.count ? clips[i].start : durationFrames
        guard !crossing(at: p, excluding: []) else { throw EditError.crossingContent }
        let audio = mediaHasAudio[id] ?? false
        var v = shifted(clips, from: p, by: n), a = shifted(audioClips, from: p, by: n)
        v.append(Clip(id: clipID, mediaID: id, start: p, sourceIn: 0, length: n, link: audio ? linkID : nil))
        if audio { a.append(Clip(id: audioClipID, mediaID: id, start: p, sourceIn: 0, length: n, link: linkID)) }
        return try checked(rebuilt(video: v, audio: a, duration: durationFrames + n))
    }

    /// 타임라인 프레임 at에서 클립(과 연결된 짝)을 나눈다. 짝은 같은 원본 위치에서 나누어 어긋남(offset)이 그대로다.
    /// 왼쪽 조각 쌍은 원래 연결을, 오른쪽 조각 쌍은 새 연결을 갖는다. newIDs는 대상 클립의 (왼쪽, 오른쪽) ID.
    public func splitting(clip id: UUID, atFrame at: Int, newIDs: (UUID, UUID) = (UUID(), UUID())) throws -> Timeline {
        guard let c = clip(id) else { throw EditError.unknownClip }
        guard at > c.start, at < c.end else { throw EditError.splitAtBoundary }
        let k = c.sourceIn + (at - c.start)   // 원본 위치
        let rightLink: UUID? = c.link == nil ? nil : UUID()
        var v = clips, a = audioClips
        for m in group(of: id) {
            let atM = m.start + (k - m.sourceIn)
            guard atM > m.start, atM < m.end else { throw EditError.linkedSplitOutside }
            let ids = m.id == id ? newIDs : (UUID(), UUID())
            let left = m.with(length: atM - m.start, id: ids.0)
            let right = m.with(start: atM, sourceIn: m.sourceIn + (atM - m.start), length: m.end - atM, id: ids.1, link: .some(rightLink))
            if lane(of: m.id) == .video { v.removeAll { $0.id == m.id }; v += [left, right] } else { a.removeAll { $0.id == m.id }; a += [left, right] }
        }
        return try checked(rebuilt(video: v, audio: a))
    }

    /// 대상 클립의 원본 구간을 [sourceIn, sourceIn + length)로 바꾼다. 연결된 짝도 같은 양만큼(앞 가장자리·길이) 바꾼다.
    /// 시작 위치 고정, 리플: 묶음의 원래 끝(가장 이른 끝) 이후 클립이 길이 변화만큼 움직인다. 그 지점에 다른 클립이 걸치면 거부한다.
    public func trimming(clip id: UUID, sourceIn: Int, length: Int) throws -> Timeline {
        guard let c = clip(id) else { throw EditError.unknownClip }
        guard length >= 1 else { throw EditError.tooShort }
        let dIn = sourceIn - c.sourceIn, dLen = length - c.length
        let g = group(of: id), ids = Set(g.map(\.id))
        var changed: [UUID: Clip] = [:]
        for m in g {
            guard let n = mediaFrames[m.mediaID] else { throw EditError.unknownMedia }
            let si = m.sourceIn + dIn, len = m.length + dLen
            guard len >= 1 else { throw EditError.tooShort }
            guard si >= 0, si + len <= n else { throw EditError.outOfSource }
            changed[m.id] = m.with(sourceIn: si, length: len)
        }
        let p = g.map(\.end).min()!
        if dLen != 0, crossing(at: p, excluding: ids) { throw EditError.crossingContent }
        let v = shifted(replacing(clips, changed), from: p, by: dLen, excluding: ids)
        let a = shifted(replacing(audioClips, changed), from: p, by: dLen, excluding: ids)
        return try checked(rebuilt(video: v, audio: a, duration: durationFrames + dLen))
    }
    /// 왼쪽 가장자리를 delta 프레임 옮긴다(양수 = 안쪽으로). 묶음 모두의 원본 범위·최소 1프레임 안으로 제한한다.
    public func trimmingStart(clip id: UUID, by delta: Int) throws -> Timeline {
        guard let c = clip(id) else { throw EditError.unknownClip }
        let g = group(of: id)
        let d = max(g.map { -$0.sourceIn }.max()!, min(delta, g.map { $0.length - 1 }.min()!))
        return try trimming(clip: id, sourceIn: c.sourceIn + d, length: c.length - d)
    }
    /// 오른쪽 가장자리를 delta 프레임 옮긴다(양수 = 바깥쪽으로).
    public func trimmingEnd(clip id: UUID, by delta: Int) throws -> Timeline {
        guard let c = clip(id) else { throw EditError.unknownClip }
        let g = group(of: id)
        var hi = Int.max
        for m in g { guard let n = mediaFrames[m.mediaID] else { throw EditError.unknownMedia }; hi = min(hi, n - m.sourceOut) }
        let d = max(g.map { 1 - $0.length }.max()!, min(delta, hi))
        return try trimming(clip: id, sourceIn: c.sourceIn, length: c.length + d)
    }

    /// 끼워 넣기 이동(연결된 쌍·소리 없는 영상 클립): 묶음의 원래 구간을 닫고(리플 삭제) 대상 지점에 리플 삽입한다.
    /// toIndex는 "옮기기 전 영상 레인 목록"에서의 끼워 넣을 자리(0…count). 제자리면 그대로 돌려준다.
    public func moving(clip id: UUID, toIndex: Int) throws -> Timeline {
        guard let vi = index(of: id) ?? partner(of: id).flatMap({ index(of: $0.id) }) else { throw EditError.unknownClip }
        guard (0...clips.count).contains(toIndex) else { throw EditError.badIndex }
        if toIndex == vi || toIndex == vi + 1 { return self }
        let g = group(of: id), ids = Set(g.map(\.id))
        let a0 = g.map(\.start).min()!
        let closed = try rippleDeleting(clip: id)
        let j = toIndex > vi ? toIndex - 1 : toIndex
        let p = j < closed.clips.count ? closed.clips[j].start : closed.durationFrames
        guard !closed.crossing(at: p, excluding: ids) else { throw EditError.crossingContent }
        let span = g.map(\.end).max()! - a0
        var v = closed.shifted(closed.clips, from: p, by: span), a = closed.shifted(closed.audioClips, from: p, by: span)
        for m in g {
            let placed = m.with(start: p + (m.start - a0))
            if lane(of: m.id) == .video { v.append(placed) } else { a.append(placed) }
        }
        return try checked(closed.rebuilt(video: v, audio: a, duration: closed.durationFrames + span))
    }

    /// 자유 이동(연결되지 않은 클립): 같은 레인의 시작 위치 toStart(0 이상)로 옮긴다. 원래 자리는 빈틈이 되고,
    /// 다른 클립과 겹치면 거부한다(덮어쓰지 않음). 끝을 넘어가면 타임라인 길이가 늘어난다.
    public func movingFree(clip id: UUID, toStart s: Int) throws -> Timeline {
        guard let c = clip(id) else { throw EditError.unknownClip }
        guard c.link == nil else { throw EditError.alreadyLinked }
        guard s >= 0 else { throw EditError.badIndex }
        let moved = c.with(start: s)
        let isVideo = lane(of: id) == .video
        let laneClips = (isVideo ? clips : audioClips).filter { $0.id != id }
        if laneClips.contains(where: { $0.start < moved.end && moved.start < $0.end }) { throw EditError.overlap }
        let v = isVideo ? laneClips + [moved] : clips, a = isVideo ? audioClips : laneClips + [moved]
        return try checked(rebuilt(video: v, audio: a, duration: max(durationFrames, moved.end)))
    }

    /// 일반 삭제: 묶음(클립과 연결된 짝)만 지우고 빈틈을 남긴다. 다른 클립 위치와 타임라인 길이는 그대로다.
    public func lifting(clip id: UUID) throws -> Timeline {
        guard clip(id) != nil else { throw EditError.unknownClip }
        let ids = Set(group(of: id).map(\.id))
        return rebuilt(video: clips.filter { !ids.contains($0.id) }, audio: audioClips.filter { !ids.contains($0.id) })
    }

    /// 리플 삭제: 묶음이 차지한 구간 [가장 이른 시작, 가장 늦은 끝)을 두 레인에서 닫고 뒤를 당긴다. 타임라인 길이가 그만큼 줄어든다.
    /// 그 구간에 묶음이 아닌 클립이 (어느 레인이든) 걸쳐 있으면 거부한다(동기 보호).
    public func rippleDeleting(clip id: UUID) throws -> Timeline {
        guard clip(id) != nil else { throw EditError.unknownClip }
        let g = group(of: id), ids = Set(g.map(\.id))
        let lo = g.map(\.start).min()!, hi = g.map(\.end).max()!
        if (clips + audioClips).contains(where: { !ids.contains($0.id) && $0.start < hi && lo < $0.end }) { throw EditError.crossingContent }
        let v = shifted(clips.filter { !ids.contains($0.id) }, from: hi, by: lo - hi)
        let a = shifted(audioClips.filter { !ids.contains($0.id) }, from: hi, by: lo - hi)
        return try checked(rebuilt(video: v, audio: a, duration: durationFrames - (hi - lo)))
    }

    /// 연결 해제: 위치·원본 구간은 그대로.
    public func unlinking(clip id: UUID) throws -> Timeline {
        guard let c = clip(id) else { throw EditError.unknownClip }
        guard c.link != nil else { throw EditError.notLinked }
        let ids = Set(group(of: id).map(\.id))
        let f: (Clip) -> Clip = { ids.contains($0.id) ? $0.with(link: .some(nil)) : $0 }
        return rebuilt(video: clips.map(f), audio: audioClips.map(f))
    }
    /// 연결: 연결되지 않은 같은 원본의 영상 클립 하나와 소리 클립 하나. 위치·원본 구간은 그대로(다시 맞추지 않음).
    public func linking(_ x: UUID, _ y: UUID, linkID: UUID = UUID()) throws -> Timeline {
        guard let cx = clip(x), let cy = clip(y) else { throw EditError.unknownClip }
        guard Set([lane(of: x), lane(of: y)]) == Set([LaneKind.video, LaneKind.audio]) else { throw EditError.linkNeedsPair }
        guard cx.link == nil, cy.link == nil else { throw EditError.alreadyLinked }
        guard cx.mediaID == cy.mediaID else { throw EditError.linkDifferentMedia }
        let f: (Clip) -> Clip = { $0.id == x || $0.id == y ? $0.with(link: .some(linkID)) : $0 }
        return try checked(rebuilt(video: clips.map(f), audio: audioClips.map(f)))
    }

    /// 레인 이름 바꾸기. 앞뒤 공백을 뺀 이름이 비어 있으면 거부한다(호출 쪽이 이전 이름을 유지).
    public func renamingLane(_ id: UUID, to name: String) throws -> Timeline {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw EditError.emptyName }
        guard let i = lanes.firstIndex(where: { $0.id == id }) else { throw EditError.unknownLane }
        var ls = lanes; ls[i].name = n
        return rebuilt(lanes: ls)
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
    /// 모든 단계(현재·실행 취소·다시 실행·드래그 기준)에 같은 변경을 적용한다(A-013: 미디어 가져오기는 실행 취소로 사라지지 않음)
    public mutating func mapAll(_ f: (Timeline) -> Timeline) {
        current = Entry(timeline: f(current.timeline), focus: current.focus)
        undoStack = undoStack.map { Entry(timeline: f($0.timeline), focus: $0.focus) }
        redoStack = redoStack.map { Entry(timeline: f($0.timeline), focus: $0.focus) }
        if let g = gestureBase { gestureBase = Entry(timeline: f(g.timeline), focus: g.focus) }
    }

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
