import Foundation

/// 타임라인의 클립. 타임라인 구간 [start, start + length) 타임라인 프레임(30 fps), 원본 구간 [sourceIn, sourceIn + length)는
/// 원본 트랙 시작에서 잰 시각을 같은 1/30 s 단위로 나타낸다(A-010: 원본 프레임레이트와 무관, 29.97·25·가변 원본 포함).
/// 타임라인 프레임 k의 원본 시각은 정확히 (sourceIn + k − start)/30 s이고, 그 시각에 표시 중인 원본 프레임(영상)·소리(소리 레인)가 나온다.
/// A-012: 클립은 영상 레인 또는 소리(오디오) 레인에 있다(A-014부터 각 종류 여러 레인). 같은 link 값을 가진 영상·소리 클립 한 쌍이 "연결된 쌍"이다.
public struct Clip: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let mediaID: UUID
    public let start: Int
    public let sourceIn: Int
    public let length: Int
    /// 연결 묶음 ID(연결된 영상·소리 쌍이 같은 값을 가진다). nil이면 연결 없음.
    public let link: UUID?
    /// 레인 ID(A-014). nil이면(형식 1 파일·레인을 정하지 않은 생성) Timeline이 그 종류의 첫 레인으로 채운다.
    public let lane: UUID?
    /// 영상 클립의 화면 변형(A-015: 크기·위치). nil이면 변형 없음(기존 전체 화면 비율 유지 맞춤). 소리 클립은 늘 nil.
    public let transform: ClipTransform?
    /// 소리 클립의 음량·음소거·페이드(형식 5). nil이면 기본값(100%, 음소거 아님, 페이드 없음). 영상 클립은 늘 nil.
    public let audio: ClipAudio?
    public init(id: UUID = UUID(), mediaID: UUID, start: Int, sourceIn: Int, length: Int, link: UUID? = nil, lane: UUID? = nil, transform: ClipTransform? = nil,
                audio: ClipAudio? = nil) {
        self.id = id; self.mediaID = mediaID; self.start = start; self.sourceIn = sourceIn; self.length = length; self.link = link; self.lane = lane
        self.transform = transform?.isIdentity == true ? nil : transform
        self.audio = audio?.isDefault == true ? nil : audio
    }
    /// 소리 설정(없으면 기본값)
    public var effectiveAudio: ClipAudio { audio ?? .default }
    public var end: Int { start + length }
    public var sourceOut: Int { sourceIn + length }
    /// 원본 시각 0이 놓이는 타임라인 위치(영상·소리 동기 비교용): start − sourceIn
    public var anchor: Int { start - sourceIn }
    /// 변형(없으면 기본값)
    public var effectiveTransform: ClipTransform { transform ?? .identity }
    func moved(by d: Int) -> Clip { with(start: start + d) }
    func with(start: Int? = nil, sourceIn: Int? = nil, length: Int? = nil, id: UUID? = nil, link: UUID?? = nil, lane: UUID?? = nil,
              transform: ClipTransform?? = nil, audio: ClipAudio?? = nil) -> Clip {
        Clip(id: id ?? self.id, mediaID: mediaID, start: start ?? self.start, sourceIn: sourceIn ?? self.sourceIn,
             length: length ?? self.length, link: link ?? self.link, lane: lane ?? self.lane, transform: transform ?? self.transform,
             audio: audio ?? self.audio)
    }
}

/// 소리 클립의 음량·음소거·페이드(2026-10-11, 프로젝트 형식 5). 영상 클립에는 없다(연결된 쌍의 소리는 소리 클립에 있다).
/// 실제 크기(진폭 배율) = 클립 음량 × 레인 음량 × 페이드 모양(클립 시작에서 잰 시각 t의 함수). 클립·레인 어느 쪽이든 음소거면 0.
/// 정규화·리미터는 없다(최대는 원래 크기, 100%).
/// - 음량: 정수 퍼센트 0–100(레인 음량과 같은 단위). 기본 100.
/// - 페이드: 선형 진폭 경사. 시간 단위는 타임라인 프레임(1/30 s)이라 자르기·트림 지점과 같은 격자에 놓인다.
///   페이드 하나는 (경사 전체 길이 length, 건너뛴 앞부분 offset)이다. 보통 페이드는 offset 0이다.
///   - 페이드 인: 클립 시작에서 t 프레임 지난 곳의 배율 min(1, (t + offset) / length).
///   - 페이드 아웃: 클립 끝까지 r 프레임 남은 곳의 배율 min(1, (r + offset) / length).
///   offset은 자르기가 페이드 경사 안에서 일어났을 때 남은 조각이 원래 경사를 그대로 이어 가도록 쓴다(아래 Timeline.splitting).
///   보이는 길이 = min(length − offset, 클립 길이). 페이드 인·아웃의 보이는 길이 합은 클립 길이를 넘지 않는다(겹치지 않음).
public struct ClipAudio: Sendable, Equatable, Codable {
    public struct Fade: Sendable, Equatable, Codable {
        public var length: Int
        public var offset: Int
        public init(length: Int, offset: Int = 0) { self.length = length; self.offset = offset }
        public static let none = Fade(length: 0)
        /// 보이는 경사 길이(클립 길이 l 안)
        public func visible(in l: Int) -> Int { max(0, min(length - offset, l)) }
        public var isNone: Bool { length <= offset }   // length − offset ≤ 0과 같다(빼기 없이: 파일을 읽는 중 넘치지 않게, 2026-10-23)
        /// 경사 시작(또는 끝)의 배율: offset/length
        public var edgeGain: Double { length > 0 ? Double(offset) / Double(length) : 1 }
        /// 경사가 없으면 none으로
        var normalized: Fade { isNone ? .none : self }
        var isValid: Bool { length >= 0 && offset >= 0 && (length == 0 ? offset == 0 : offset < length) }
    }
    public var volumePercent: Int
    public var muted: Bool
    public var fadeIn: Fade
    public var fadeOut: Fade
    public init(volumePercent: Int = 100, muted: Bool = false, fadeIn: Fade = .none, fadeOut: Fade = .none) {
        self.volumePercent = volumePercent; self.muted = muted; self.fadeIn = fadeIn.normalized; self.fadeOut = fadeOut.normalized
    }
    public static let `default` = ClipAudio()
    public var isDefault: Bool { self == .default }
    /// 클립 길이 l에서 올바른가: 음량 0–100, 페이드 값이 맞고 보이는 길이 합이 l 이하
    public func isValid(length l: Int) -> Bool {
        (0...100).contains(volumePercent) && fadeIn.isValid && fadeOut.isValid && fadeIn.visible(in: l) + fadeOut.visible(in: l) <= l
    }
    /// 길이 l에 맞춘 값(트림 뒤·입력 뒤의 결정적 규칙): 페이드 인을 먼저 두고(보이는 길이는 클립 길이로 잘림),
    /// 페이드 아웃의 보이는 길이가 남은 길이(l − 페이드 인)를 넘으면 페이드 아웃을 그 길이의 보통 페이드(offset 0)로 줄인다.
    public func fitted(length l: Int) -> ClipAudio {
        var a = self
        let room = l - a.fadeIn.visible(in: l)
        if a.fadeOut.visible(in: l) > room { a.fadeOut = Fade(length: max(0, room)).normalized }
        return a
    }
    /// 클립 시작에서 t 프레임(소수 가능) 지난 곳의 페이드 배율(음량·음소거 제외), 클립 길이 l
    public func envelope(at t: Double, length l: Int) -> Double {
        var g = 1.0
        if fadeIn.length > 0 { g *= min(1, max(0, (t + Double(fadeIn.offset)) / Double(fadeIn.length))) }
        if fadeOut.length > 0 { g *= min(1, max(0, (Double(l) - t + Double(fadeOut.offset)) / Double(fadeOut.length))) }
        return g
    }
    /// 클립 음량 배율(음소거면 0)
    public var gain: Double { muted ? 0 : Double(volumePercent) / 100 }
    /// 페이드 모양의 꺾이는 점(클립 시작에서 잰 프레임, 0과 l 포함, 오름차순). 이 점 사이에서 배율은 선형이다.
    public func breakpoints(length l: Int) -> [Int] {
        Array(Set([0, fadeIn.visible(in: l), l - fadeOut.visible(in: l), l])).sorted()
    }
    /// 자르기(클립 시작에서 k 프레임, 0 < k < l): 왼쪽 조각·오른쪽 조각의 값. 음량·음소거는 둘 다 그대로다.
    /// 각 조각의 페이드 모양은 원래 클립의 같은 시각 모양과 같다(새 페이드를 만들지 않음, 원래 페이드를 둘 다에 복사하지 않음):
    /// - 페이드 인은 클립 시작에 붙어 있으므로 왼쪽 조각은 그대로, 오른쪽 조각은 경사의 앞 k 프레임을 건너뛴다(offset + k).
    /// - 페이드 아웃은 클립 끝에 붙어 있으므로 오른쪽 조각은 그대로, 왼쪽 조각은 경사의 뒤 l − k 프레임을 건너뛴다(offset + l − k).
    /// - 건너뛴 결과 경사가 남지 않으면 그 페이드는 없음이다.
    public func split(at k: Int, length l: Int) -> (left: ClipAudio, right: ClipAudio) {
        var left = self, right = self
        left.fadeOut = Fade(length: fadeOut.length, offset: fadeOut.offset + (l - k)).normalized
        right.fadeIn = Fade(length: fadeIn.length, offset: fadeIn.offset + k).normalized
        if fadeOut.length == 0 { left.fadeOut = .none }
        if fadeIn.length == 0 { right.fadeIn = .none }
        return (left, right)
    }
    enum CodingKeys: String, CodingKey { case volumePercent, muted, fadeIn, fadeOut }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(volumePercent: try c.decodeIfPresent(Int.self, forKey: .volumePercent) ?? 100, muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
                  fadeIn: try c.decodeIfPresent(Fade.self, forKey: .fadeIn) ?? .none, fadeOut: try c.decodeIfPresent(Fade.self, forKey: .fadeOut) ?? .none)
    }
}

/// 영상 클립의 화면 변형(A-015). 좌표계: 출력 화면(1920×1080) 픽셀, 원점은 왼쪽 위, X는 오른쪽·Y는 아래쪽이 +.
/// - 크기: 기본 맞춤(원본 전체가 화면 안에 들어가게 비율을 유지해 키우거나 줄이고 가운데 둔 크기)에 대한 배율.
///   1 = 100%(기본 맞춤 그대로). 화면 가운데를 기준으로 키우거나 줄인다. 가로·세로 비율은 늘 원본 그대로다.
/// - 위치: 그 뒤 영상 가운데를 화면 가운데(960, 540)에서 옮긴 거리(출력 픽셀).
/// 기본값(100%, 0, 0)은 변형 없음과 같다. 화면 밖으로 나간 부분은 잘린다. 회전·불투명도·자르기·애니메이션은 없다.
///
/// 저장 표현(2026-10-11, 프로젝트 형식 4): 정수 세 개 — 크기 `scaleMicro`(백만분율, 1_000_000 = 100%),
/// 위치 `offsetXMilli`·`offsetYMilli`(출력 픽셀의 1/1000). 프리뷰 손잡이 끌기의 소수 값을 이 격자로만 맞추고(0.0001%, 0.001 px)
/// 그대로 저장하므로, 끌기 중 보인 값·놓은 값·저장·다시 열기·내보내기가 같다. 정수라 저장·다시 열기가 정확하다.
/// 형식 3 이전 파일의 `scalePermille`(천분율)·`offsetX`·`offsetY`(정수 픽셀)도 그대로 읽는다(정확히 같은 값으로 바뀜).
public struct ClipTransform: Sendable, Equatable, Codable {
    public var scaleMicro: Int
    public var offsetXMilli: Int
    public var offsetYMilli: Int
    public static let identity = ClipTransform(scaleMicro: 1_000_000, offsetXMilli: 0, offsetYMilli: 0)
    /// 허용 범위: 크기 1%–1000%, 위치 ±7680·±4320 픽셀(화면 네 배)
    public static let scaleMicroRange = 10_000...10_000_000
    public static let offsetXMilliRange = -7_680_000...7_680_000, offsetYMilliRange = -4_320_000...4_320_000
    public init(scaleMicro: Int, offsetXMilli: Int, offsetYMilli: Int) { self.scaleMicro = scaleMicro; self.offsetXMilli = offsetXMilli; self.offsetYMilli = offsetYMilli }
    /// 천분율·정수 픽셀(형식 3 이전 표현, 정보 패널의 정수 입력)
    public init(scalePermille: Int, offsetX: Int, offsetY: Int) { self.init(scaleMicro: scalePermille * 1000, offsetXMilli: offsetX * 1000, offsetYMilli: offsetY * 1000) }
    /// 소수 값(배율, 픽셀) → 저장 격자로 반올림(범위는 맞추지 않음, clamped 참고)
    public init(scale: Double, x: Double, y: Double) {
        func q(_ v: Double, _ k: Double) -> Int { v.isFinite ? Int(max(-1e12, min(1e12, (v * k).rounded()))) : 0 }
        self.init(scaleMicro: q(scale, 1_000_000), offsetXMilli: q(x, 1000), offsetYMilli: q(y, 1000))
    }
    public var scale: Double { Double(scaleMicro) / 1_000_000 }
    public var x: Double { Double(offsetXMilli) / 1000 }
    public var y: Double { Double(offsetYMilli) / 1000 }
    /// 크기 퍼센트(표시·입력용)
    public var percent: Double { Double(scaleMicro) / 10_000 }
    public var isIdentity: Bool { self == .identity }
    public var isValid: Bool { Self.scaleMicroRange.contains(scaleMicro) && Self.offsetXMilliRange.contains(offsetXMilli) && Self.offsetYMilliRange.contains(offsetYMilli) }
    /// 범위 안으로 맞춘 값
    public var clamped: ClipTransform {
        ClipTransform(scaleMicro: min(max(scaleMicro, Self.scaleMicroRange.lowerBound), Self.scaleMicroRange.upperBound),
                      offsetXMilli: min(max(offsetXMilli, Self.offsetXMilliRange.lowerBound), Self.offsetXMilliRange.upperBound),
                      offsetYMilli: min(max(offsetYMilli, Self.offsetYMilliRange.lowerBound), Self.offsetYMilliRange.upperBound))
    }
    /// 기본값이면 nil(클립에 저장하는 모양)
    public var normalized: ClipTransform? { isIdentity ? nil : self }

    enum CodingKeys: String, CodingKey { case scaleMicro, offsetXMilli, offsetYMilli, scalePermille, offsetX, offsetY }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if let m = try c.decodeIfPresent(Int.self, forKey: .scaleMicro) {
            self.init(scaleMicro: m, offsetXMilli: try c.decode(Int.self, forKey: .offsetXMilli), offsetYMilli: try c.decode(Int.self, forKey: .offsetYMilli))
        } else {   // 형식 3: 천분율·정수 픽셀
            let p = try c.decode(Int.self, forKey: .scalePermille), x = try c.decode(Int.self, forKey: .offsetX), y = try c.decode(Int.self, forKey: .offsetY)
            // magnitude: abs(Int.min)은 넘쳐 멈춘다(2026-10-23 전체 검토)
            guard p.magnitude <= 1_000_000_000, x.magnitude <= 1_000_000_000, y.magnitude <= 1_000_000_000 else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "transform out of range"))
            }
            self.init(scalePermille: p, offsetX: x, offsetY: y)
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(scaleMicro, forKey: .scaleMicro); try c.encode(offsetXMilli, forKey: .offsetXMilli); try c.encode(offsetYMilli, forKey: .offsetYMilli)
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
    /// 영상 트랙이 있는가(A-014: 소리 파일은 false). 형식 1 파일에는 없고 true로 읽는다.
    public var hasVideo: Bool
    /// 소리 파일의 정확한 길이: 표본 수와 표본율(A-014). 영상 파일은 nil. frameCount는 이 길이를 1/30 s 격자로 올림한 값이다.
    public var sampleRate: Int?
    public var sampleCount: Int64?
    public var channels: Int?
    public init(id: UUID, name: String, path: String, frameCount: Int, hasAudio: Bool, size: Int64, modifiedNs: Int64, codec: String, width: Int, height: Int,
                hasVideo: Bool = true, sampleRate: Int? = nil, sampleCount: Int64? = nil, channels: Int? = nil) {
        self.id = id; self.name = name; self.path = path; self.frameCount = frameCount; self.hasAudio = hasAudio
        self.size = size; self.modifiedNs = modifiedNs; self.codec = codec; self.width = width; self.height = height
        self.hasVideo = hasVideo; self.sampleRate = sampleRate; self.sampleCount = sampleCount; self.channels = channels
    }
    public init(_ a: MediaAsset) {
        self.init(id: a.id, name: a.name, path: a.url.standardizedFileURL.path, frameCount: a.frameCount, hasAudio: a.hasAudio,
                  size: a.identity.size, modifiedNs: a.identity.modifiedNs, codec: a.codec, width: Int(a.displaySize.width), height: Int(a.displaySize.height),
                  hasVideo: a.hasVideo, sampleRate: a.audioSampleRate, sampleCount: a.audioSampleCount, channels: a.audioChannels)
    }
    enum CodingKeys: String, CodingKey { case id, name, path, frameCount, hasAudio, size, modifiedNs, codec, width, height, hasVideo, sampleRate, sampleCount, channels }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name), path: try c.decode(String.self, forKey: .path),
                  frameCount: try c.decode(Int.self, forKey: .frameCount), hasAudio: try c.decode(Bool.self, forKey: .hasAudio),
                  size: try c.decode(Int64.self, forKey: .size), modifiedNs: try c.decode(Int64.self, forKey: .modifiedNs), codec: try c.decode(String.self, forKey: .codec),
                  width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height),
                  hasVideo: try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? true, sampleRate: try c.decodeIfPresent(Int.self, forKey: .sampleRate),
                  sampleCount: try c.decodeIfPresent(Int64.self, forKey: .sampleCount), channels: try c.decodeIfPresent(Int.self, forKey: .channels))
    }
}

/// 레인(A-012, A-014). 이름은 클립·파일 이름과 따로이며 안정된 레인 ID에 붙는다.
/// 종류는 영상·소리·자막(2026-10-22, 형식 6)이다. 스펙트럼 레인은 이후 종류를 더해 넣는다.
public enum LaneKind: String, Sendable, Codable { case video, audio, subtitle }
public struct Lane: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let kind: LaneKind
    public var name: String
    /// 오디오 레인: 음소거(기본 false)와 음량(정수 퍼센트 0–100, 기본 100 = 원래 크기). 영상 레인에서는 쓰지 않는다.
    public var muted: Bool
    public var volumePercent: Int
    public init(id: UUID, kind: LaneKind, name: String, muted: Bool = false, volumePercent: Int = 100) {
        self.id = id; self.kind = kind; self.name = name; self.muted = muted; self.volumePercent = volumePercent
    }
    enum CodingKeys: String, CodingKey { case id, kind, name, muted, volumePercent }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), kind: try c.decode(LaneKind.self, forKey: .kind), name: try c.decode(String.self, forKey: .name),
                  muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false, volumePercent: try c.decodeIfPresent(Int.self, forKey: .volumePercent) ?? 100)
    }
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
    /// 재연결: 영상 클립이 쓰는데 새 파일에 영상이 없음
    case relinkNoVideo
    /// 레인: 종류가 맞지 않는 레인(영상 클립은 영상 레인에만)
    case laneKindMismatch
    /// 레인: 그 종류의 마지막 레인은 지우지 않는다
    case lastLane
    case volumeRange
    /// 변형: 영상 클립만, 범위 안
    case transformNotVideo
    case transformRange
    /// 클립 음량·페이드: 소리 클립만
    case audioNotAudioClip
    /// 붙여넣기(2026-10-11): 복사한 클립이 없음
    case clipboardEmpty
    /// 붙여넣기: 복사한 클립이 이 프로젝트의 미디어·원본 범위와 맞지 않음
    case clipboardMismatch
    /// 자막(2026-10-22): 글자가 비어 있음(이전 글자를 유지)
    /// 자막: 그 자리에 1프레임도 들어갈 빈 곳이 없음(같은 레인의 다른 자막)
    case subtitleNoRoom
    /// 자막: 모양 값이 범위 밖
    case subtitleStyleRange
    /// 프레임 값 상한(Timeline.maxFrames)을 넘음
    case frameLimit
    public var description: String {
        switch self {
        case .frameLimit: return "타임라인이 너무 깁니다(프레임 값 상한을 넘습니다)."
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
        case .relinkNoAudio: return "고른 파일에 소리가 없습니다. 오디오 레인의 클립이 이 원본의 소리를 씁니다."
        case .relinkNoVideo: return "고른 파일에 영상이 없습니다. 영상 레인의 클립이 이 원본의 영상을 씁니다."
        case .laneKindMismatch: return "영상 클립은 영상 레인으로, 소리 클립은 오디오 레인으로, 자막은 자막 레인으로만 옮길 수 있습니다."
        case .lastLane: return "영상 레인과 오디오 레인은 하나 이상 있어야 합니다. 이 레인은 지울 수 없습니다."
        case .volumeRange: return "음량은 0%(무음)에서 100%(원래 크기) 사이입니다."
        case .transformNotVideo: return "크기·위치는 영상 클립에만 있습니다."
        case .transformRange: return "크기는 1%–1000%, 위치는 가로 ±7680·세로 ±4320 픽셀 안이어야 합니다."
        case .audioNotAudioClip: return "클립 음량·음소거·페이드는 소리 클립에만 있습니다. 연결된 쌍이면 소리 클립 쪽에 적용합니다."
        case .clipboardEmpty: return "붙여 넣을 클립이 없습니다. 먼저 클립을 골라 복사하세요."
        case .clipboardMismatch: return "복사한 클립을 이 프로젝트에 붙여 넣을 수 없습니다(미디어가 없거나 원본 범위가 맞지 않음)."
        case .subtitleNoRoom: return "그 자리에는 다른 자막이 있어 새 자막을 넣을 수 없습니다. 자막 레인의 빈 곳을 누르세요."
        case .subtitleStyleRange: return "자막 크기는 8–300pt, 위치는 화면(1920×1080) 안, 색은 0–255여야 합니다."
        }
    }
}

/// 불변 타임라인 스냅샷(A-014: 영상 레인 여러 개 + 오디오 레인 여러 개, 레인마다 클립은 겹치지 않음, 명시적 빈틈 허용 — D-020).
/// - lanes: 화면 순서(위 → 아래). 영상 레인이 모두 오디오 레인보다 위에 있고, 각 종류는 하나 이상 있다.
///   영상은 같은 시각에 클립이 있는 가장 위 영상 레인 하나가 보인다(불투명 전체 화면, 하드 컷). 위 레인의 빈틈은 아래 레인을 보이고,
///   어느 레인에도 영상이 없으면 검정이다. 소리는 음소거하지 않은 오디오 레인을 모두 더한다(레인 음량 적용).
/// - clips = 모든 영상 레인의 클립, audioClips = 모든 오디오 레인의 클립(레인 순서, 같은 레인 안에서는 시작 순). 클립의 lane이 레인 ID다.
///   레인을 정하지 않은 클립(lane nil)은 그 종류의 첫 레인에 둔다(형식 1 파일·이전 코드 호환).
/// - 길이(durationFrames)는 따로 저장한다. 일반 삭제는 길이를 바꾸지 않는다.
/// - 편집은 대상 클립의 "묶음"(연결된 쌍이면 둘, 아니면 하나)에 함께 적용된다.
///   - 삽입: 첫 영상 레인 클립의 시작(또는 끝)에 리플 삽입하고, 그 지점 이후 모든 레인의 클립을 민다. 그 지점에 걸친 클립이 있으면 거부한다.
///   - 놓기: 고른 레인의 고른 위치에 놓는다(리플 없음). 겹치면 거부한다.
///   - 트림: 묶음 각각의 시작 위치는 고정, 같은 양만큼 길이를 바꾸고 모든 레인의 뒤를 리플로 민다·당긴다(걸치면 거부).
///   - 이동(옮기기, relocating): 묶음(연결된 쌍이면 둘, 상대 위치 그대로)을 같은 종류의 레인과 위치로 옮긴다. 원래 자리는 빈틈이 되고
///     다른 클립은 움직이지 않는다(리플 없음). 어느 레인에서든 겹치면 아무것도 옮기지 않고 거부한다.
///     2026-10-11 소유자 요청: 편집기의 일반 끌기는 연결 여부와 관계없이 이 옮기기다.
///   - 이동(끼워 넣기, moving): 묶음의 원래 구간을 닫고 대상 지점에 리플 삽입한다. 일반 끌기·놓기에서는 더 쓰지 않는다(엔진 API·검사용).
/// - 화면 배치(2026-10-11): 영상 레인 묶음과 오디오 레인 묶음 사이가 가운데 경계다. V1(배열의 마지막 영상 레인)은 경계 바로 위,
///   A1(첫 오디오 레인)은 바로 아래이고 번호는 바깥쪽으로 커진다(lanesFromBoundary). 배열 순서가 곧 화면 순서·영상 쌓음 순서라
///   이전 파일을 열어도 순서·우선순위가 바뀌지 않는다.
///   - 일반 삭제: 묶음만 지우고 빈틈을 남긴다. 리플 삭제: 묶음 구간을 모든 레인에서 닫는다(묶음이 아닌 클립이 걸치면 거부).
///   - 레인 추가·이름·순서·삭제·음소거·음량도 새 스냅샷이다(실행 취소 대상). 레인을 지우면 그 클립도 지우고, 짝을 잃은 클립의 연결을 푼다.
/// 편집은 새 스냅샷을 돌려주고, 잘못된 편집은 오류를 던지며 원래 스냅샷을 바꾸지 않는다. 결과는 늘 불변식(isValid)을 만족한다.
public struct Timeline: Sendable, Equatable {
    public let clips: [Clip]
    public let audioClips: [Clip]
    /// 자막 항목(2026-10-22, 형식 6): 자막 레인의 미디어 없는 글자 항목(레인 순서, 같은 레인 안에서는 시작 순). Subtitles.swift 참고.
    public let subtitles: [SubtitleItem]
    public let lanes: [Lane]
    /// 프로젝트의 원본 미디어 목록(가져온 순서). 타임라인에 쓰지 않은 미디어도 포함한다(A-013).
    public let media: [MediaRef]
    /// 미디어 id → 원본 프레임 수(범위 검사용)
    public let mediaFrames: [UUID: Int]
    /// 미디어 id → 소리 트랙이 있는가(삽입 때 연결된 소리 클립을 만들지)
    public let mediaHasAudio: [UUID: Bool]
    /// 미디어 id → 영상 트랙이 있는가(A-014: 소리 파일은 false, 없으면 true로 본다)
    public let mediaHasVideo: [UUID: Bool]
    public let durationFrames: Int

    /// durationFrames를 주지 않으면 마지막 클립 끝을 길이로 한다. 주면 마지막 클립 끝보다 짧을 수 없다.
    public init(clips: [Clip] = [], audioClips: [Clip] = [], subtitles: [SubtitleItem] = [], lanes: [Lane] = Lane.defaults, media: [MediaRef] = [], mediaFrames: [UUID: Int] = [:],
                mediaHasAudio: [UUID: Bool] = [:], mediaHasVideo: [UUID: Bool] = [:], durationFrames: Int? = nil) {
        let order = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($1.id, $0) })
        func normalize(_ cs: [Clip], _ kind: LaneKind) -> [Clip] {
            // 레인을 정하지 않은 클립(형식 1·레인 없는 생성)은 그 종류의 기본 레인(경계에 가장 가까운 V1·A1)에 둔다(CP-12).
            // 형식 1 파일은 종류마다 레인이 하나라 이전과 같다.
            let ofKind = lanes.filter { $0.kind == kind }
            let first = (kind == .video ? ofKind.last : ofKind.first)?.id
            return cs.map { $0.lane == nil ? $0.with(lane: .some(first)) : $0 }
                .sorted { ($0.lane.flatMap { order[$0] } ?? Int.max, $0.start) < ($1.lane.flatMap { order[$0] } ?? Int.max, $1.start) }
        }
        let v = normalize(clips, .video), a = normalize(audioClips, .audio)
        let s = subtitles.sorted { (order[$0.lane] ?? Int.max, $0.start) < (order[$1.lane] ?? Int.max, $1.start) }
        self.clips = v; self.audioClips = a; self.subtitles = s; self.lanes = lanes; self.media = media
        // 미디어 목록에 있는데 영상 유무 표가 비어 있으면 목록 값으로 채운다(같은 뜻의 두 표현을 같게)
        var hv = mediaHasVideo
        for r in media where hv[r.id] == nil { hv[r.id] = r.hasVideo }
        self.mediaFrames = mediaFrames; self.mediaHasAudio = mediaHasAudio; self.mediaHasVideo = hv
        self.durationFrames = max(durationFrames ?? 0, v.map(\.end).max() ?? 0, a.map(\.end).max() ?? 0, s.map(\.end).max() ?? 0)
    }
    func rebuilt(video: [Clip]? = nil, audio: [Clip]? = nil, subtitles subs: [SubtitleItem]? = nil, lanes: [Lane]? = nil, media: [MediaRef]? = nil, mediaFrames: [UUID: Int]? = nil,
                 mediaHasAudio: [UUID: Bool]? = nil, mediaHasVideo: [UUID: Bool]? = nil, duration: Int? = nil) -> Timeline {
        Timeline(clips: video ?? clips, audioClips: audio ?? audioClips, subtitles: subs ?? subtitles, lanes: lanes ?? self.lanes, media: media ?? self.media, mediaFrames: mediaFrames ?? self.mediaFrames,
                 mediaHasAudio: mediaHasAudio ?? self.mediaHasAudio, mediaHasVideo: mediaHasVideo ?? self.mediaHasVideo, durationFrames: duration ?? durationFrames)
    }

    // MARK: 레인

    public func lanes(_ kind: LaneKind) -> [Lane] { lanes.filter { $0.kind == kind } }
    /// 그 종류의 배열 첫(화면 가장 위) 레인. 영상은 쌓음 우선순위가 가장 높은 레인이다(V1이 아님 — 기본 레인은 baseLane, CP-12).
    /// 여러 레인 이전의 단일 레인 API(inserting·starts·gaps)가 이 레인을 쓴다.
    public func primaryLane(_ kind: LaneKind) -> Lane? { lanes.first { $0.kind == kind } }
    /// 가운데 경계에서 바깥쪽 순서의 레인(2026-10-11 배치): 영상은 경계 바로 위(배열의 마지막 영상 레인)부터 위로,
    /// 오디오는 경계 바로 아래(첫 오디오 레인)부터 아래로. 배열 순서(화면 위 → 아래, 영상 쌓음 우선순위)는 그대로다.
    /// 자막 레인은 영상 레인 묶음 위에 있고, 영상 묶음과의 경계(배열의 마지막 자막 레인)부터 위로 S1, S2…다.
    public func lanesFromBoundary(_ kind: LaneKind) -> [Lane] { kind == .audio ? lanes(.audio) : lanes(kind).reversed() }
    /// 기본 레인: 경계에 가장 가까운 레인(V1·A1)
    public func baseLane(_ kind: LaneKind) -> Lane? { lanesFromBoundary(kind).first }
    /// 레인 번호(1부터, 경계에서 바깥쪽). 표시용이며 레인 이름과 따로다(순서를 바꾸면 번호도 바뀐다).
    public func laneNumber(_ id: UUID) -> Int? {
        guard let l = laneInfo(id) else { return nil }
        return lanesFromBoundary(l.kind).firstIndex { $0.id == id }.map { $0 + 1 }
    }
    /// 표시용 레인 번호 라벨: "V1", "A2"
    public func laneLabel(_ id: UUID) -> String {
        guard let l = laneInfo(id), let n = laneNumber(id) else { return "" }
        return (l.kind == .video ? "V" : l.kind == .audio ? "A" : "S") + "\(n)"
    }
    /// 같은 번호의 반대 종류 레인(V2 ↔ A2). 없으면 nil. 자막 레인에는 짝이 없다.
    public func pairedLane(of id: UUID) -> Lane? {
        guard let l = laneInfo(id), l.kind != .subtitle, let n = laneNumber(id) else { return nil }
        let other = lanesFromBoundary(l.kind == .video ? .audio : .video)
        return n <= other.count ? other[n - 1] : nil
    }
    /// 레인에서 마지막으로 차지한 끝(클립이 없으면 0)
    public func occupiedEnd(lane id: UUID) -> Int { max(clips(inLane: id).map(\.end).max() ?? 0, subtitles(inLane: id).map(\.end).max() ?? 0) }
    public func laneInfo(_ id: UUID) -> Lane? { lanes.first { $0.id == id } }
    /// 클립이 있는 레인 ID
    public func laneID(of clipID: UUID) -> UUID? { clip(clipID)?.lane }
    /// 레인의 클립(시작 순)
    public func clips(inLane id: UUID) -> [Clip] { (clips + audioClips).filter { $0.lane == id } }
    public func gaps(inLane id: UUID) -> [Range<Int>] {
        laneInfo(id)?.kind == .subtitle ? Self.gaps(ranges: subtitles(inLane: id).map { $0.start..<$0.end }, durationFrames) : Self.gaps(clips(inLane: id), durationFrames)
    }

    /// 두 레인 종류 모두 클립이 없는가(길이가 0보다 커도 전부 빈틈이면 true)
    public var isEmpty: Bool { clips.isEmpty && audioClips.isEmpty }
    /// 마지막 유효 프레임(D-018: 끝 시각에서는 이 프레임을 유지. 빈틈이면 검정). 길이 0이면 nil.
    public var lastValidFrame: Int? { durationFrames > 0 ? durationFrames - 1 : nil }
    /// 첫 영상 레인의 클립 시작들(끼워 넣기 이동·삽입 위치 기준)
    public var starts: [Int] { primaryLane(.video).map { clips(inLane: $0.id).map(\.start) } ?? [] }
    /// 첫 영상 레인 빈틈(이전 단일 레인 의미)
    public var gaps: [Range<Int>] { primaryLane(.video).map { gaps(inLane: $0.id) } ?? [] }
    /// 첫 오디오 레인 빈틈
    public var audioGaps: [Range<Int>] { primaryLane(.audio).map { gaps(inLane: $0.id) } ?? [] }
    static func gaps(_ cs: [Clip], _ dur: Int) -> [Range<Int>] { gaps(ranges: cs.map { $0.start..<$0.end }, dur) }
    static func gaps(ranges rs: [Range<Int>], _ dur: Int) -> [Range<Int>] {
        var out: [Range<Int>] = [], cursor = 0
        for r in rs.sorted(by: { $0.lowerBound < $1.lowerBound }) { if r.lowerBound > cursor { out.append(cursor..<r.lowerBound) }; cursor = max(cursor, r.upperBound) }
        if dur > cursor { out.append(cursor..<dur) }
        return out
    }
    /// 불변식: 레인 ID 고유, 순서는 자막 레인(0개 이상) → 영상 레인 → 오디오 레인(각 하나 이상), 음량 0–100. 클립은 자기 종류의 레인에 있고,
    /// 레인마다 겹침 없음·0 이상·길이 안·1프레임 이상·원본 범위 안. 연결 묶음은 영상 1 + 소리 1, 같은 미디어(CP-11).
    /// 클립·자막 ID는 모두 고유하고, 클립의 미디어는 등록되어 있어야 한다(CP-11). 자막은 자막 레인에 있고 글자가 있으며 모양 값이 범위 안이다.
    /// 프레임 값 상한(2026-10-23 전체 검토): 2⁴⁰ 프레임(30 fps로 약 1160년). 파일 읽기·편집·저장이 같은 상한을 쓴다 —
    /// 그 안의 값은 몇 개를 더해도 Int를 넘지 않는다. 읽을 때만 막으면 경계 값 프로젝트가 편집 한 번으로 상한을 넘어 저장된 뒤 다시 열리지 않았다(Codex 검토).
    public static let maxFrames = 1 << 40
    /// 모든 프레임 값이 상한 안인가: 길이(모든 클립·자막의 끝 포함), 원본 위치·길이, 페이드, 미디어 길이
    public var withinFrameLimit: Bool {
        let m = Self.maxFrames
        return (0...m).contains(durationFrames) && mediaFrames.values.allSatisfy { (0...m).contains($0) }
            && (clips + audioClips).allSatisfy { c in
                (0...m).contains(c.start) && (0...m).contains(c.sourceIn) && (0...m).contains(c.length)
                    && [c.audio?.fadeIn, c.audio?.fadeOut].allSatisfy { f in f.map { (0...m).contains($0.length) && (0...m).contains($0.offset) } ?? true }
            }
            && subtitles.allSatisfy { (0...m).contains($0.start) && (0...m).contains($0.length) }
    }
    public var isValid: Bool {
        guard withinFrameLimit else { return false }
        guard Set(lanes.map(\.id)).count == lanes.count, !lanes(.video).isEmpty, !lanes(.audio).isEmpty,
              let lastVideo = lanes.lastIndex(where: { $0.kind == .video }), let firstAudio = lanes.firstIndex(where: { $0.kind == .audio }),
              lastVideo < firstAudio, lanes.allSatisfy({ (0...100).contains($0.volumePercent) }) else { return false }
        if let lastSub = lanes.lastIndex(where: { $0.kind == .subtitle }), let firstVideo = lanes.firstIndex(where: { $0.kind == .video }), lastSub > firstVideo { return false }
        let allIDs = clips.map(\.id) + audioClips.map(\.id) + subtitles.map(\.id)
        guard Set(allIDs).count == allIDs.count else { return false }
        guard (clips + audioClips).allSatisfy({ mediaFrames[$0.mediaID] != nil }) else { return false }
        let kinds = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0.kind) })
        guard clips.allSatisfy({ $0.lane.flatMap { kinds[$0] } == .video }), audioClips.allSatisfy({ $0.lane.flatMap { kinds[$0] } == .audio }) else { return false }
        guard clips.allSatisfy({ $0.transform?.isValid ?? true }), audioClips.allSatisfy({ $0.transform == nil }) else { return false }
        guard clips.allSatisfy({ $0.audio == nil }), audioClips.allSatisfy({ $0.audio?.isValid(length: $0.length) ?? true }) else { return false }
        guard subtitles.allSatisfy({ kinds[$0.lane] == .subtitle && $0.length >= 1 && $0.start >= 0 && $0.style.isValid }) else { return false }
        for lane in lanes {
            var cursor = 0
            for c in clips(inLane: lane.id).sorted(by: { $0.start < $1.start }) {
                guard c.start >= cursor, c.length >= 1, c.sourceIn >= 0 else { return false }
                if let n = mediaFrames[c.mediaID], c.sourceOut > n { return false }
                cursor = c.end
            }
            for s in subtitles(inLane: lane.id) { guard s.start >= cursor else { return false }; cursor = s.end }
            if cursor > durationFrames { return false }
        }
        var groups: [UUID: (v: Int, a: Int, media: Set<UUID>)] = [:]
        for c in clips { if let l = c.link { groups[l, default: (0, 0, [])].v += 1; groups[l]!.media.insert(c.mediaID) } }
        for c in audioClips { if let l = c.link { groups[l, default: (0, 0, [])].a += 1; groups[l]!.media.insert(c.mediaID) } }
        return groups.values.allSatisfy { $0.v == 1 && $0.a == 1 && $0.media.count == 1 }
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
    /// A-014까지의 구분(이전 동작 기록·검사용): 연결되지 않은 소리 클립, 소리가 있는 원본에서 연결을 해제한 영상 클립, 첫 영상 레인 밖의 영상 클립.
    /// 2026-10-11부터 편집기의 끌기는 모든 클립에 옮기기(relocating)를 쓰므로 이 값으로 동작을 나누지 않는다.
    public func movesFreely(_ id: UUID) -> Bool {
        guard let c = clip(id), c.link == nil else { return false }
        return lane(of: id) == .audio || (mediaHasAudio[c.mediaID] ?? false) || c.lane != primaryLane(.video)?.id
    }
    /// 타임라인 프레임 n에서 보이는 영상 클립(가장 위 영상 레인)의 위치
    public func clipIndex(atFrame n: Int) -> Int? { clips.firstIndex { n >= $0.start && n < $0.end } }
    /// 첫 오디오 레인부터 찾은, 프레임 n을 덮는 소리 클립의 위치
    public func audioClipIndex(atFrame n: Int) -> Int? { audioClips.firstIndex { n >= $0.start && n < $0.end } }
    /// 타임라인 프레임 n → 보이는 영상의 (미디어, 원본 위치(1/30 s 단위 원본 시각)). 빈틈이면 nil.
    public func source(atFrame n: Int) -> (mediaID: UUID, frame: Int)? {
        guard let i = clipIndex(atFrame: n) else { return nil }
        return (clips[i].mediaID, clips[i].sourceIn + n - clips[i].start)
    }
    public func laneName(_ kind: LaneKind) -> String { primaryLane(kind)?.name ?? "" }

    /// 보이는 영상 조각(A-014): 각 시각에 클립이 있는 가장 위 영상 레인의 클립 부분만, 시간 순·겹침 없음.
    /// 프리뷰·내보내기의 영상 트랙은 이 조각으로 만든다(불투명 전체 화면 하드 컷이라 겹친 아래 레인은 보이지 않는다).
    /// 조각은 원래 클립의 id·미디어·원본 위치를 이어받는다(원본 시각 = sourceIn + (t − start)).
    public func visibleVideoSegments() -> [Clip] {
        var bounds = Set<Int>()
        for c in clips { bounds.insert(c.start); bounds.insert(c.end) }
        let b = bounds.sorted()
        var out: [Clip] = []
        for k in 0..<max(0, b.count - 1) {
            let lo = b[k], hi = b[k + 1]
            guard hi > lo, let top = clips.first(where: { $0.start <= lo && hi <= $0.end }) else { continue }   // clips는 레인 순서(위 먼저)
            if let last = out.last, last.id == top.id, last.end == lo {
                out[out.count - 1] = last.with(length: last.length + (hi - lo))
            } else {
                out.append(top.with(start: lo, sourceIn: top.sourceIn + (lo - top.start), length: hi - lo))
            }
        }
        return out
    }

    /// 미디어 등록(가져오기): 범위 검사 정보와 미디어 목록(MediaRef)에 넣는다. 이미 있으면 정보만 갱신한다.
    public func registering(_ asset: MediaAsset) -> Timeline {
        var m = mediaFrames; m[asset.id] = asset.frameCount
        var h = mediaHasAudio; h[asset.id] = asset.hasAudio
        var hv = mediaHasVideo; hv[asset.id] = asset.hasVideo
        var refs = media
        if let i = refs.firstIndex(where: { $0.id == asset.id }) { refs[i] = MediaRef(asset) } else { refs.append(MediaRef(asset)) }
        return rebuilt(media: refs, mediaFrames: m, mediaHasAudio: h, mediaHasVideo: hv)
    }
    /// 프리뷰용(A-013): 쓸 수 없는 원본의 클립을 뺀 사본(그 구간은 검정·무음). 길이·다른 클립·레인은 그대로다.
    public func excludingMedia(_ ids: Set<UUID>) -> Timeline {
        guard !ids.isEmpty else { return self }
        return rebuilt(video: clips.filter { !ids.contains($0.mediaID) }, audio: audioClips.filter { !ids.contains($0.mediaID) })
    }
    /// 미디어 재연결(A-013): 같은 id에 새 원본을 붙인다. 이 미디어를 쓰는 모든 클립의 원본 구간이 새 파일 안에 있어야 하고,
    /// 소리 클립이 쓰면 소리, 영상 클립이 쓰면 영상이 있어야 한다. 클립·ID·위치는 그대로다(줄이지 않음).
    public func relinking(media id: UUID, to new: MediaRef) throws -> Timeline {
        guard let i = media.firstIndex(where: { $0.id == id }), new.id == id else { throw EditError.unknownMedia }
        let need = (clips + audioClips).filter { $0.mediaID == id }.map(\.sourceOut).max() ?? 0
        guard new.frameCount >= need else { throw EditError.relinkTooShort(need: need, have: new.frameCount) }
        if audioClips.contains(where: { $0.mediaID == id }), !new.hasAudio { throw EditError.relinkNoAudio }
        if clips.contains(where: { $0.mediaID == id }), !new.hasVideo { throw EditError.relinkNoVideo }
        var refs = media; refs[i] = new
        var m = mediaFrames; m[id] = new.frameCount
        var h = mediaHasAudio; h[id] = new.hasAudio
        var hv = mediaHasVideo; hv[id] = new.hasVideo
        return try checked(rebuilt(media: refs, mediaFrames: m, mediaHasAudio: h, mediaHasVideo: hv))
    }

    // MARK: 편집 도우미

    /// 결과 불변식 확인(겹침이면 덮어쓰지 않고 거부)
    func checked(_ t: Timeline) throws -> Timeline {
        guard t.withinFrameLimit else { throw EditError.frameLimit }
        guard t.isValid else { throw EditError.overlap }
        return t
    }
    /// 지점 p에 묶음이 아닌 클립·자막이 걸쳐 있는가(start < p < end, 모든 레인)
    func crossing(at p: Int, excluding ids: Set<UUID>) -> Bool {
        (clips + audioClips).contains { !ids.contains($0.id) && $0.start < p && p < $0.end } || subtitles.contains { !ids.contains($0.id) && $0.start < p && p < $0.end }
    }
    /// 구간 [lo, hi)과 겹치는 묶음이 아닌 클립·자막이 있는가(모든 레인)
    func occupied(_ lo: Int, _ hi: Int, excluding ids: Set<UUID>) -> Bool {
        (clips + audioClips).contains { !ids.contains($0.id) && $0.start < hi && lo < $0.end } || subtitles.contains { !ids.contains($0.id) && $0.start < hi && lo < $0.end }
    }
    /// 시작 ≥ p인(묶음이 아닌) 클립을 d만큼 옮긴다(모든 레인)
    func shifted(_ cs: [Clip], from p: Int, by d: Int, excluding ids: Set<UUID> = []) -> [Clip] {
        cs.map { !ids.contains($0.id) && $0.start >= p ? $0.moved(by: d) : $0 }
    }
    /// 리플 편집이 자막도 함께 민다(2026-10-22): 시작 ≥ p인 자막을 d만큼
    func shiftedSubtitles(from p: Int, by d: Int, excluding ids: Set<UUID> = []) -> [SubtitleItem] {
        subtitles.map { !ids.contains($0.id) && $0.start >= p ? $0.with(start: $0.start + d) : $0 }
    }
    private func replacing(_ cs: [Clip], _ m: [UUID: Clip]) -> [Clip] { cs.map { m[$0.id] ?? $0 } }

    // MARK: 편집

    /// 미디어 전체를 영상 클립(+원본에 소리가 있으면 연결된 소리 클립)으로 첫 영상 레인의 index 위치(기본: 끝)에 리플 삽입한다.
    /// 위치는 그 레인 clips[index]의 시작, 또는 타임라인 끝. 그 지점에 다른 클립이 걸쳐 있으면 거부한다. 영상·소리는 첫 레인에 들어간다.
    /// 소리 파일(영상 없음)은 첫 오디오 레인에 소리 클립만 넣는다.
    public func inserting(media id: UUID, at index: Int? = nil, clipID: UUID = UUID(), audioClipID: UUID = UUID(), linkID: UUID = UUID()) throws -> Timeline {
        guard let n = mediaFrames[id], n >= 1 else { throw EditError.unknownMedia }
        let pv = primaryLane(.video).map { clips(inLane: $0.id) } ?? []
        let i = index ?? pv.count
        guard (0...pv.count).contains(i) else { throw EditError.badIndex }
        let p = i < pv.count ? pv[i].start : durationFrames
        guard !crossing(at: p, excluding: []) else { throw EditError.crossingContent }
        let video = mediaHasVideo[id] ?? true, audio = mediaHasAudio[id] ?? false
        var v = shifted(clips, from: p, by: n), a = shifted(audioClips, from: p, by: n)
        let link: UUID? = video && audio ? linkID : nil
        if video { v.append(Clip(id: clipID, mediaID: id, start: p, sourceIn: 0, length: n, link: link, lane: primaryLane(.video)?.id)) }
        if audio { a.append(Clip(id: video ? audioClipID : clipID, mediaID: id, start: p, sourceIn: 0, length: n, link: link, lane: primaryLane(.audio)?.id)) }
        return try checked(rebuilt(video: v, audio: a, subtitles: shiftedSubtitles(from: p, by: n), duration: durationFrames + n))
    }

    /// 놓기(A-014): 미디어 전체를 고른 레인의 start에 놓는다(리플 없음). 영상(videoLane)과 연결된 소리(audioLane)를 함께 놓고,
    /// 소리 파일이면 소리만 audioLane에 놓는다. 어느 쪽이든 겹치면 아무것도 놓지 않고 거부한다. 끝을 넘으면 길이가 늘어난다.
    public func placing(media id: UUID, at start: Int, videoLane: UUID?, audioLane: UUID?, clipID: UUID = UUID(), audioClipID: UUID = UUID(),
                        linkID: UUID = UUID()) throws -> Timeline {
        guard let n = mediaFrames[id], n >= 1 else { throw EditError.unknownMedia }
        guard start >= 0 else { throw EditError.badIndex }
        let video = mediaHasVideo[id] ?? true, audio = mediaHasAudio[id] ?? false
        var v = clips, a = audioClips
        let link: UUID? = video && audio ? linkID : nil
        if video {
            guard let vl = videoLane, laneInfo(vl)?.kind == .video else { throw EditError.laneKindMismatch }
            v.append(Clip(id: clipID, mediaID: id, start: start, sourceIn: 0, length: n, link: link, lane: vl))
        }
        if audio {
            guard let al = audioLane, laneInfo(al)?.kind == .audio else { throw EditError.laneKindMismatch }
            a.append(Clip(id: video ? audioClipID : clipID, mediaID: id, start: start, sourceIn: 0, length: n, link: link, lane: al))
        }
        return try checked(rebuilt(video: v, audio: a, duration: max(durationFrames, start + n)))
    }

    /// 추가(2026-10-11): 미디어 전체를 고른 레인(영상 파일은 videoLane과 연결된 소리 audioLane, 소리 파일은 audioLane)의
    /// 마지막으로 차지한 끝 뒤에 놓는다(리플 없음, 재생 헤드와 무관). 고른 레인이 모두 비었으면 0에서 시작한다.
    /// 시작은 고른 레인들의 마지막 끝 가운데 가장 늦은 값이라 어느 레인에서도 겹치지 않는다. 다른 레인과 기존 빈틈은 그대로다.
    public func appending(media id: UUID, videoLane: UUID?, audioLane: UUID?, clipID: UUID = UUID(), audioClipID: UUID = UUID(),
                          linkID: UUID = UUID()) throws -> Timeline {
        guard mediaFrames[id] != nil else { throw EditError.unknownMedia }
        let video = mediaHasVideo[id] ?? true, audio = mediaHasAudio[id] ?? false
        var used: [UUID] = []
        if video { guard let v = videoLane else { throw EditError.laneKindMismatch }; used.append(v) }
        if audio { guard let a = audioLane else { throw EditError.laneKindMismatch }; used.append(a) }
        let start = used.map { occupiedEnd(lane: $0) }.max() ?? 0
        return try placing(media: id, at: start, videoLane: video ? videoLane : nil, audioLane: audio ? audioLane : nil,
                           clipID: clipID, audioClipID: audioClipID, linkID: linkID)
    }

    /// 끌어 옮기기 붙음(2026-10-11): 대상 클립 묶음을 delta(포인터에서 잰 소수 프레임)만큼 옮길 때, 묶음 클립의 시작·끝이 붙을 곳
    /// (0과 묶음이 아닌 클립의 시작·끝, extra)에서 threshold 프레임 안이면 가장 가까운 곳에 붙인 정수 delta와 붙은 위치를 돌려준다.
    /// 없으면 (반올림한 delta, nil). 거리는 반올림 전 값으로 재므로 확대가 커도 화면 거리 그대로 붙는다.
    /// threshold는 화면 거리(포인트)를 확대 배율로 나눈 프레임 수다(호출 쪽). 같은 거리면 앞선 후보를 쓴다.
    public func snappedDelta(clip id: UUID, delta raw: Double, threshold: Double, extra: [Int] = []) -> (delta: Int, snap: Int?) {
        let delta = Int(raw.rounded())
        let g = group(of: id), ids = Set(g.map(\.id))
        guard !g.isEmpty, threshold > 0 else { return (delta, nil) }
        var targets = Set([0] + extra)
        for c in clips + audioClips where !ids.contains(c.id) { targets.insert(c.start); targets.insert(c.end) }
        let earliest = g.map(\.start).min()!
        var best: (dist: Double, delta: Int, snap: Int)?
        for c in g {
            for edge in [c.start, c.end] {
                for t in targets.sorted() {
                    let d = t - edge, dist = abs(Double(edge) + raw - Double(t))
                    guard dist <= threshold, earliest + d >= 0 else { continue }
                    if best == nil || dist < best!.dist { best = (dist, d, t) }
                }
            }
        }
        return best.map { ($0.delta, $0.snap) } ?? (delta, nil)
    }

    /// 타임라인 프레임 at에서 클립(과 연결된 짝)을 나눈다. 짝은 같은 원본 위치에서 나누어 어긋남(offset)이 그대로다.
    /// 왼쪽 조각 쌍은 원래 연결을, 오른쪽 조각 쌍은 새 연결을 갖는다. newIDs는 대상 클립의 (왼쪽, 오른쪽) ID. 레인은 그대로다.
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
            // 소리 설정: 두 조각의 페이드 모양이 자르기 전 같은 시각의 모양과 같도록 나눈다(ClipAudio.split)
            let parts = m.audio.map { $0.split(at: atM - m.start, length: m.length) }
            let left = m.with(length: atM - m.start, id: ids.0, audio: .some(parts?.left))
            let right = m.with(start: atM, sourceIn: m.sourceIn + (atM - m.start), length: m.end - atM, id: ids.1, link: .some(rightLink), audio: .some(parts?.right))
            if lane(of: m.id) == .video { v.removeAll { $0.id == m.id }; v += [left, right] } else { a.removeAll { $0.id == m.id }; a += [left, right] }
        }
        return try checked(rebuilt(video: v, audio: a))
    }

    /// 대상 클립의 원본 구간을 [sourceIn, sourceIn + length)로 바꾼다. 연결된 짝도 같은 양만큼(앞 가장자리·길이) 바꾼다.
    /// 시작 위치 고정, 리플: 묶음의 원래 끝(가장 이른 끝) 이후 모든 레인의 클립이 길이 변화만큼 움직인다. 그 지점에 다른 클립이 걸치면 거부한다.
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
            // 소리 설정: 페이드는 각자의 가장자리에 붙어 따라가고(길이 그대로), 새 길이에 맞게 줄인다(ClipAudio.fitted)
            changed[m.id] = m.with(sourceIn: si, length: len, audio: .some(m.audio?.fitted(length: len)))
        }
        let p = g.map(\.end).min()!
        if dLen != 0, crossing(at: p, excluding: ids) { throw EditError.crossingContent }
        let v = shifted(replacing(clips, changed), from: p, by: dLen, excluding: ids)
        let a = shifted(replacing(audioClips, changed), from: p, by: dLen, excluding: ids)
        let out = rebuilt(video: v, audio: a, subtitles: shiftedSubtitles(from: p, by: dLen), duration: durationFrames + dLen)
        // 당기는 트림(dLen < 0)이 겹침을 만들면, 닫히는 구간 [p + dLen, p)에서 끝나는 다른 레인 내용과 뒤에서 당겨진 내용이 부딪힌 것이다.
        // 같은 레인 겹침(.overlap)이 아니라 리플 거부로 알린다(CP-10). 허용·거부 자체는 이전과 같다.
        guard out.isValid else { throw dLen < 0 ? EditError.crossingContent : EditError.overlap }
        return out
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
    /// toIndex는 "옮기기 전, 묶음의 영상 클립이 있는 레인(없으면 대상 클립의 레인)의 클립 목록"에서의 자리(0…count). 제자리면 그대로.
    public func moving(clip id: UUID, toIndex: Int) throws -> Timeline {
        guard let c0 = clip(id) else { throw EditError.unknownClip }
        let anchor = group(of: id).first { lane(of: $0.id) == .video } ?? c0
        guard let laneID = anchor.lane else { throw EditError.unknownLane }
        let lc = clips(inLane: laneID)
        guard let vi = lc.firstIndex(where: { $0.id == anchor.id }) else { throw EditError.unknownClip }
        guard (0...lc.count).contains(toIndex) else { throw EditError.badIndex }
        if toIndex == vi || toIndex == vi + 1 { return self }
        let g = group(of: id), ids = Set(g.map(\.id))
        let a0 = g.map(\.start).min()!
        let closed = try rippleDeleting(clip: id)
        let j = toIndex > vi ? toIndex - 1 : toIndex
        let cl = closed.clips(inLane: laneID)
        let p = j < cl.count ? cl[j].start : closed.durationFrames
        guard !closed.crossing(at: p, excluding: ids) else { throw EditError.crossingContent }
        let span = g.map(\.end).max()! - a0
        var v = closed.shifted(closed.clips, from: p, by: span), a = closed.shifted(closed.audioClips, from: p, by: span)
        for m in g {
            let placed = m.with(start: p + (m.start - a0))
            if lane(of: m.id) == .video { v.append(placed) } else { a.append(placed) }
        }
        return try checked(closed.rebuilt(video: v, audio: a, subtitles: closed.shiftedSubtitles(from: p, by: span), duration: closed.durationFrames + span))
    }

    /// 옮기기(A-014): 대상 클립을 toStart로(묶음은 같은 양만큼) 옮기고, 레인을 바꾼다. lane은 대상 클립의 새 레인, partnerLane은
    /// 연결된 짝의 새 레인(nil이면 그대로). 레인 종류가 맞지 않거나 어느 레인에서든 겹치면 아무것도 옮기지 않고 거부한다(일부만 옮기지 않음).
    /// 원래 자리는 빈틈이 된다. 끝을 넘어가면 타임라인 길이가 늘어난다.
    public func relocating(clip id: UUID, toStart: Int? = nil, lane: UUID? = nil, partnerLane: UUID? = nil) throws -> Timeline {
        guard let c = clip(id) else { throw EditError.unknownClip }
        let d = (toStart ?? c.start) - c.start
        let g = group(of: id), ids = Set(g.map(\.id))
        var moved: [Clip] = []
        for m in g {
            let target = m.id == id ? (lane ?? m.lane) : (partnerLane ?? m.lane)
            guard let t = target, let info = laneInfo(t) else { throw EditError.unknownLane }
            guard info.kind == self.lane(of: m.id) else { throw EditError.laneKindMismatch }
            guard m.start + d >= 0 else { throw EditError.badIndex }
            moved.append(m.with(start: m.start + d, lane: .some(t)))
        }
        for m in moved {
            if clips(inLane: m.lane!).contains(where: { !ids.contains($0.id) && $0.start < m.end && m.start < $0.end }) { throw EditError.overlap }
        }
        let byID = Dictionary(uniqueKeysWithValues: moved.map { ($0.id, $0) })
        return try checked(rebuilt(video: replacing(clips, byID), audio: replacing(audioClips, byID), duration: max(durationFrames, moved.map(\.end).max() ?? 0)))
    }
    /// 자유 이동(연결되지 않은 클립): 같은 레인의 시작 위치 toStart로 옮긴다(A-012). 겹치면 거부한다.
    public func movingFree(clip id: UUID, toStart s: Int) throws -> Timeline {
        guard let c = clip(id) else { throw EditError.unknownClip }
        guard c.link == nil else { throw EditError.alreadyLinked }
        guard s >= 0 else { throw EditError.badIndex }
        return try relocating(clip: id, toStart: s)
    }

    /// 일반 삭제: 묶음(클립과 연결된 짝)만 지우고 빈틈을 남긴다. 다른 클립 위치와 타임라인 길이는 그대로다.
    public func lifting(clip id: UUID) throws -> Timeline {
        guard clip(id) != nil else { throw EditError.unknownClip }
        let ids = Set(group(of: id).map(\.id))
        return rebuilt(video: clips.filter { !ids.contains($0.id) }, audio: audioClips.filter { !ids.contains($0.id) })
    }

    /// 리플 삭제: 묶음이 차지한 구간 [가장 이른 시작, 가장 늦은 끝)을 모든 레인에서 닫고 뒤를 당긴다. 타임라인 길이가 그만큼 줄어든다.
    /// 그 구간에 묶음이 아닌 클립이 (어느 레인이든) 걸쳐 있으면 거부한다(다른 레인을 망가뜨리지 않음).
    public func rippleDeleting(clip id: UUID) throws -> Timeline {
        guard clip(id) != nil else { throw EditError.unknownClip }
        let g = group(of: id), ids = Set(g.map(\.id))
        let lo = g.map(\.start).min()!, hi = g.map(\.end).max()!
        if occupied(lo, hi, excluding: ids) { throw EditError.crossingContent }
        let v = shifted(clips.filter { !ids.contains($0.id) }, from: hi, by: lo - hi)
        let a = shifted(audioClips.filter { !ids.contains($0.id) }, from: hi, by: lo - hi)
        return try checked(rebuilt(video: v, audio: a, subtitles: shiftedSubtitles(from: hi, by: lo - hi), duration: durationFrames - (hi - lo)))
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

    /// 영상 클립 변형(A-015). 연결된 소리는 바꾸지 않는다(시각·위치 그대로). nil 또는 기본값이면 변형 없음.
    public func settingTransform(clip id: UUID, _ t: ClipTransform?) throws -> Timeline {
        guard let i = index(of: id) else { throw clip(id) == nil ? EditError.unknownClip : EditError.transformNotVideo }
        if let t, !t.isValid { throw EditError.transformRange }
        var v = clips; v[i] = v[i].with(transform: .some(t))
        return try checked(rebuilt(video: v))
    }

    /// 소리 클립 음량·음소거·페이드(2026-10-11). 영상 클립을 주면 연결된 소리 클립에 적용한다(연결된 짝이 소리 클립일 때).
    /// 주지 않은 값은 그대로다. 페이드 길이(프레임)를 주면 보통 페이드(offset 0)가 되고, 다른 쪽 페이드와 겹치지 않게
    /// (클립 길이 − 다른 쪽 보이는 길이) 안으로 줄인다. 0이면 페이드 없음. 음량은 0–100(범위 밖이면 거부).
    /// 다른 클립·레인은 바꾸지 않는다.
    public func settingClipAudio(clip id: UUID, volumePercent: Int? = nil, muted: Bool? = nil, fadeInFrames: Int? = nil, fadeOutFrames: Int? = nil) throws -> Timeline {
        guard let target = audioTarget(of: id) else { throw clip(id) == nil ? EditError.unknownClip : EditError.audioNotAudioClip }
        guard let i = audioIndex(of: target) else { throw EditError.unknownClip }
        let c = audioClips[i]
        var a = c.effectiveAudio
        if let v = volumePercent { guard (0...100).contains(v) else { throw EditError.volumeRange }; a.volumePercent = v }
        if let m = muted { a.muted = m }
        if let f = fadeInFrames { a.fadeIn = ClipAudio.Fade(length: max(0, min(f, c.length - a.fadeOut.visible(in: c.length)))).normalized }
        if let f = fadeOutFrames { a.fadeOut = ClipAudio.Fade(length: max(0, min(f, c.length - a.fadeIn.visible(in: c.length)))).normalized }
        var au = audioClips; au[i] = c.with(audio: .some(a))
        return try checked(rebuilt(audio: au))
    }
    /// 소리 설정을 적용할 소리 클립: 소리 클립이면 그 클립, 영상 클립이면 연결된 소리 클립(없으면 nil)
    public func audioTarget(of id: UUID) -> UUID? {
        if audioIndex(of: id) != nil { return id }
        guard index(of: id) != nil, let p = partner(of: id), audioIndex(of: p.id) != nil else { return nil }
        return p.id
    }

    // MARK: 레인 편집(A-014)

    /// 레인 이름 바꾸기. 앞뒤 공백을 뺀 이름이 비어 있으면 거부한다(호출 쪽이 이전 이름을 유지).
    public func renamingLane(_ id: UUID, to name: String) throws -> Timeline {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw EditError.emptyName }
        guard let i = lanes.firstIndex(where: { $0.id == id }) else { throw EditError.unknownLane }
        var ls = lanes; ls[i].name = n
        return rebuilt(lanes: ls)
    }
    /// 레인 추가: 그 종류 묶음의 맨 아래(after가 있으면 그 레인 바로 아래)에 넣는다.
    /// outward(2026-10-11 배치)면 경계에서 가장 먼 곳: 영상은 영상 묶음 맨 위(새 Vn, 가장 높은 쌓음 우선순위), 오디오는 맨 아래(새 An).
    public func addingLane(_ kind: LaneKind, name: String, id: UUID = UUID(), after: UUID? = nil, outward: Bool = false) throws -> Timeline {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw EditError.emptyName }
        var ls = lanes
        let pos: Int
        // 자막 레인(2026-10-22)은 영상 묶음 위: outward = 맨 위(새 Sn), 아니면 자막 묶음 맨 아래(영상 바로 위)
        // 바깥쪽 새 영상 레인은 영상 묶음 맨 위 = 자막 레인 바로 아래(2026-10-23 전체 검토: 0에 넣어 자막 레인 위로 가서 레인 순서가 깨지고
        // "겹칩니다"로 거부되었다 — 자막 레인이 있으면 영상 레인 추가·레인 쌍 추가·새 레인에 놓기·새 레인이 필요한 붙여넣기가 모두 실패)
        if outward { pos = kind == .audio ? ls.count : kind == .video ? (ls.lastIndex { $0.kind == .subtitle } ?? -1) + 1 : 0 }
        else if let a = after, let i = ls.firstIndex(where: { $0.id == a }), ls[i].kind == kind { pos = i + 1 }
        else if kind == .subtitle { pos = (ls.lastIndex { $0.kind == .subtitle } ?? -1) + 1 }
        else { pos = (ls.lastIndex { $0.kind == kind } ?? (kind == .video ? (ls.lastIndex { $0.kind == .subtitle } ?? -1) : ls.count - 1)) + 1 }
        ls.insert(Lane(id: id, kind: kind, name: n), at: pos)
        return try checked(rebuilt(lanes: ls))
    }
    /// 레인 순서: 같은 종류 안에서 위(−)·아래(+)로 step 칸(보통 한 칸). 영상 레인 순서는 겹친 영상 중 무엇이 보이는지를 바꾼다.
    public func movingLane(_ id: UUID, by step: Int) throws -> Timeline {
        guard let i = lanes.firstIndex(where: { $0.id == id }) else { throw EditError.unknownLane }
        let j = i + step
        guard step != 0, lanes.indices.contains(j), lanes[j].kind == lanes[i].kind else { return self }
        var ls = lanes; let l = ls.remove(at: i); ls.insert(l, at: j)   // 사이의 레인 순서는 그대로(맞바꾸지 않음)
        return try checked(rebuilt(lanes: ls))
    }
    /// 레인 삭제: 레인과 그 클립을 지운다. 다른 레인의 클립은 그대로이고, 짝을 잃은 클립은 연결만 풀린다. 그 종류의 마지막 레인은 지우지 않는다.
    public func removingLane(_ id: UUID) throws -> Timeline {
        guard let lane = laneInfo(id) else { throw EditError.unknownLane }
        guard lane.kind == .subtitle || lanes(lane.kind).count > 1 else { throw EditError.lastLane }   // 자막 레인은 0개여도 된다
        let gone = clips(inLane: id)
        let brokenLinks = Set(gone.compactMap(\.link))
        let f: (Clip) -> Clip = { brokenLinks.contains($0.link ?? UUID()) ? $0.with(link: .some(nil)) : $0 }
        return try checked(rebuilt(video: clips.filter { $0.lane != id }.map(f), audio: audioClips.filter { $0.lane != id }.map(f),
                                   subtitles: subtitles.filter { $0.lane != id }, lanes: lanes.filter { $0.id != id }))
    }
    /// 오디오 레인 음소거·음량(0–100%, 100 = 원래 크기). 자동 정규화·리미터는 없다(합친 소리가 잘릴 수 있음).
    public func settingLaneAudio(_ id: UUID, muted: Bool? = nil, volumePercent: Int? = nil) throws -> Timeline {
        guard let i = lanes.firstIndex(where: { $0.id == id }) else { throw EditError.unknownLane }
        guard lanes[i].kind == .audio else { throw EditError.laneKindMismatch }
        if let v = volumePercent, !(0...100).contains(v) { throw EditError.volumeRange }
        var ls = lanes
        if let m = muted { ls[i].muted = m }
        if let v = volumePercent { ls[i].volumePercent = v }
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

// MARK: 복사·붙여넣기(2026-10-11)

/// 복사한 클립 묶음(앱 안 클립보드의 내용). 같은 프로젝트의 Clip 값을 그대로 담는다(원본 ID·레인·연결·변형·소리 설정 포함).
/// 영상·소리를 나눠 담는 것은 Clip이 자기 종류를 갖지 않기 때문이다(종류는 타임라인의 어느 배열에 있는지로 정해진다).
public struct ClipboardContent: Sendable, Equatable {
    public let video: [Clip]
    public let audio: [Clip]
    /// 자막(2026-10-22): 미디어 없는 글자 항목(같은 프로젝트·다른 프로젝트 어디든 붙일 수 있음)
    public let subtitles: [SubtitleItem]
    public init(video: [Clip], audio: [Clip], subtitles: [SubtitleItem] = []) { self.video = video; self.audio = audio; self.subtitles = subtitles }
    public var isEmpty: Bool { video.isEmpty && audio.isEmpty && subtitles.isEmpty }
    public var all: [Clip] { video + audio }
}

extension Timeline {
    /// 복사: 클립 하나와 그 연결된 짝(기존 연결 선택 의미, group(of:)). 타임라인은 바꾸지 않는다.
    public func copying(clip id: UUID) throws -> ClipboardContent {
        let g = group(of: id)
        guard !g.isEmpty else { throw EditError.unknownClip }
        return ClipboardContent(video: g.filter { lane(of: $0.id) == .video }, audio: g.filter { lane(of: $0.id) == .audio })
    }

    /// 붙여넣기 결과: 새 타임라인, 원래 클립 ID → 새 클립 ID, 새로 만든 레인 ID(있으면).
    public struct PasteResult: Sendable { public let timeline: Timeline; public let ids: [UUID: UUID]; public let createdLanes: [UUID] }

    /// 붙여넣기(2026-10-11): 복사한 묶음의 가장 이른 시작을 at에 두고 상대 위치를 그대로 지킨 복제를 넣는다(리플·덮어쓰기 없음, 기존 클립은 그대로).
    /// - 새 클립 ID, 연결 묶음은 새 연결 ID(원래 클립과 연결되지 않음). 미디어·원본 구간·길이·변형·음량·음소거·페이드(자른 페이드의 offset 포함)는 그대로.
    /// - 레인: 원래 레인별로 한 대상 레인을 고른다. 차례: 원래 레인 → 같은 종류의 다른 레인(가운데 경계에서 가까운 순서) → 새 레인(경계 바깥쪽 끝).
    ///   그 레인의 기존 클립과 하나라도 겹치면 다음 레인을 본다. 원래 레인이 다르면 같은 대상 레인을 쓰지 않는다. 새 레인은 이 편집에 함께 들어간다.
    /// - 미디어가 이 타임라인에 없거나 원본 범위를 넘으면 거부(clipboardMismatch). 일부만 넣지 않는다.
    public func pasting(_ content: ClipboardContent, at: Int, newLaneName: (LaneKind) -> String) throws -> PasteResult {
        guard !content.isEmpty else { throw EditError.clipboardEmpty }
        guard at >= 0 else { throw EditError.badIndex }
        for c in content.all {
            guard let n = mediaFrames[c.mediaID], c.sourceIn >= 0, c.length >= 1, c.sourceOut <= n else { throw EditError.clipboardMismatch }
        }
        for c in content.video { guard mediaHasVideo[c.mediaID] ?? true else { throw EditError.clipboardMismatch } }
        for c in content.audio { guard mediaHasAudio[c.mediaID] ?? false else { throw EditError.clipboardMismatch } }
        // 연결: 묶음 안에서 영상 1 + 소리 1인 연결만 새 ID로 잇는다(짝이 묶음에 없으면 연결 없이 — 복사는 늘 짝을 함께 담는다)
        var linkCount: [UUID: (v: Int, a: Int)] = [:]
        for c in content.video { if let l = c.link { linkCount[l, default: (0, 0)].v += 1 } }
        for c in content.audio { if let l = c.link { linkCount[l, default: (0, 0)].a += 1 } }
        let newLink = Dictionary(uniqueKeysWithValues: linkCount.filter { $0.value == (1, 1) }.map { ($0.key, UUID()) })
        let d = at - ((content.all.map(\.start) + content.subtitles.map(\.start)).min() ?? 0)
        var t = self
        var created: [UUID] = [], ids: [UUID: UUID] = [:]
        var placedVideo: [Clip] = [], placedAudio: [Clip] = []
        for kind in [LaneKind.video, .audio] {
            let src = kind == .video ? content.video : content.audio
            var used = Set<UUID>()
            // 원래 레인별 묶음(원래 레인 순서를 지킨다)
            var order: [UUID?] = []
            for c in src where !order.contains(c.lane) { order.append(c.lane) }
            for original in order {
                let members = src.filter { $0.lane == original }.map { $0.with(start: $0.start + d) }
                func fits(_ lane: UUID) -> Bool {
                    let existing = t.clips(inLane: lane)
                    return members.allSatisfy { m in !existing.contains { $0.start < m.end && m.start < $0.end } }
                }
                var candidates: [UUID] = []
                if let o = original, t.laneInfo(o)?.kind == kind { candidates.append(o) }
                candidates += t.lanesFromBoundary(kind).map(\.id).filter { !candidates.contains($0) }
                var target = candidates.first { !used.contains($0) && fits($0) }
                if target == nil {
                    let id = UUID()
                    t = try t.addingLane(kind, name: newLaneName(kind), id: id, outward: true)
                    created.append(id); target = id
                }
                used.insert(target!)
                for m in members {
                    let nid = UUID(); ids[m.id] = nid
                    let c = m.with(id: nid, link: .some(m.link.flatMap { newLink[$0] }), lane: .some(target!))
                    if kind == .video { placedVideo.append(c) } else { placedAudio.append(c) }
                }
            }
        }
        // 자막: 원래 레인 → 다른 자막 레인(경계에서 가까운 순서) → 새 자막 레인(맨 위). 같은 레인의 기존 자막과 겹치면 다음 레인을 본다.
        var placedSubs: [SubtitleItem] = []
        var usedSub = Set<UUID>()
        var subOrder: [UUID] = []
        for c in content.subtitles where !subOrder.contains(c.lane) { subOrder.append(c.lane) }
        for original in subOrder {
            let members = content.subtitles.filter { $0.lane == original }.map { $0.with(start: $0.start + d) }
            func fits(_ lane: UUID) -> Bool { members.allSatisfy { m in !t.subtitles(inLane: lane).contains { $0.start < m.end && m.start < $0.end } } }
            var candidates: [UUID] = []
            if t.laneInfo(original)?.kind == .subtitle { candidates.append(original) }
            candidates += t.lanesFromBoundary(.subtitle).map(\.id).filter { !candidates.contains($0) }
            var target = candidates.first { !usedSub.contains($0) && fits($0) }
            if target == nil {
                let id = UUID()
                t = try t.addingLane(.subtitle, name: newLaneName(.subtitle), id: id, outward: true)
                created.append(id); target = id
            }
            usedSub.insert(target!)
            for m in members { let nid = UUID(); ids[m.id] = nid; placedSubs.append(m.with(id: nid, lane: target!)) }
        }
        let end = ((placedVideo + placedAudio).map(\.end) + placedSubs.map(\.end)).max() ?? 0
        let out = t.rebuilt(video: t.clips + placedVideo, audio: t.audioClips + placedAudio, subtitles: t.subtitles + placedSubs, duration: max(t.durationFrames, end))
        guard out.isValid else { throw EditError.overlap }
        return PasteResult(timeline: out, ids: ids, createdLanes: created)
    }
}
