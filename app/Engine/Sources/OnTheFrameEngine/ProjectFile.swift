import Foundation

/// 프로젝트 파일(.ontheframe, A-013). 구조화한 JSON, 버전 있음. 스키마는 app/README.md §15.
/// - 시각은 모두 정수 프레임(타임라인 30 fps)과 정수 렌더 설정이다. 부동소수점 시각을 저장하지 않는다.
/// - 원본 미디어는 밖에 둔다(넣거나 복사·이동·수정하지 않음). 참조는 절대 경로, 프로젝트 파일 기준 상대 경로, 샌드박스 북마크.
/// - 창 위치·패널 배치 같은 앱 설정은 넣지 않는다(UserDefaults, EditorLayout).
/// - 읽기는 전체를 검사한 뒤에만 결과를 돌려준다(현재 상태를 바꾸는 쪽은 성공한 결과만 쓴다).
public enum ProjectFile {
    public static let format = "dev.ontheframe.project"
    /// 형식 2(A-014): 여러 레인(임의 레인 ID·순서), 클립의 레인 ID, 오디오 레인 음소거·음량, 소리 파일 미디어(정확한 표본 수·표본율).
    /// 형식 1(A-013) 파일도 그대로 연다(레인 2개, 클립의 레인 없음 → 첫 레인). 저장은 늘 형식 2다.
    /// 형식 3(A-015): 영상 클립의 `transform`(크기 천분율·위치 픽셀, 정수). 없으면 변형 없음. 형식 1·2 파일도 그대로 연다.
    /// (형식 2를 읽는 이전 빌드가 모르는 변형을 조용히 버리고 다시 저장하지 않도록 버전을 올렸다.)
    /// 형식 4(2026-10-11): 변형을 더 고운 정수 격자로 저장한다(`scaleMicro` 백만분율, `offsetXMilli`·`offsetYMilli` 1/1000 픽셀 — ClipTransform).
    /// 형식 3 이전 파일의 천분율·정수 픽셀 변형도 그대로 연다. (형식 3을 읽는 이전 빌드가 새 키를 모른 채 열지 않도록 버전을 올렸다.)
    /// 형식 5(2026-10-11): 소리 클립의 `audio`(음량 퍼센트·음소거·페이드 인/아웃 {length, offset} 프레임). 없으면 기본값(100%, 페이드 없음).
    /// 형식 4 이전 파일도 그대로 연다(소리 그대로). (형식 4를 읽는 이전 빌드가 클립 음량·페이드를 모른 채 열고 다시 저장해 버리지 않도록 버전을 올렸다.)
    /// 형식 6(2026-10-22): 자막 레인(레인 종류 `subtitle`)과 `subtitles`(미디어 없는 글자 항목, 정수 프레임·정수 모양 값).
    /// 자막 레인·자막이 하나도 없는 프로젝트는 형식 5로 쓴다(이전 앱이 열 수 있게, 소유자 방향 2026-10-22). 자막 레인이 있으면(자막이 0개여도) 형식 6이다.
    /// 그래서 쓰는 형식은 내용에 따라 5 또는 6이고, 내려 쓸 때 버리는 값은 없다(형식 5에 자막이 들어갈 자리가 없으면 6으로 쓴다).
    /// 형식 5 이하에 자막 레인·`subtitles`가 있으면 잘못된 파일로 거부한다.
    /// 자막 글자는 빈 글자도 된다(2026-10-23, D-037: 프리뷰를 누르면 바로 빈 자막을 만든다). 형식 6은 커밋한 적이 없는 작업 중 형식이라
    /// 이 완화로 거부되는 공식 읽기 쪽은 없다(그 전 작업용 Debug 빌드만 빈 자막이 든 파일을 거부한다). 모양·시각·레인 검사는 그대로다.
    /// 형식 8(2026-10-25, SP-1A — docs/SPECTRUM-DESIGN.md §15): 스펙트럼 레인(레인 종류 `spectrum`)·`spectra`(스펙트럼 클립)·소리 클립의 `origin`(계보 키).
    /// 스펙트럼 레인·스펙트럼 또는 계보가 있으면 형식 8로 쓴다(버리는 값 없음 — 다시 읽으면 같음). 계보는 소리 자르기에서 늘 생기므로(P-S1 (나) 승인)
    /// 소리를 자른 보통 프로젝트도 형식 8이고, 형식 7까지만 읽는 이전 앱은 그 파일을 "더 새 버전"으로 열지 않는다. 계보도 스펙트럼도 없으면 지금처럼 7/6/5.
    /// 형식 7 이하에 스펙트럼 레인·`spectra`·`origin`이 있으면 잘못된 파일로 거부한다(형식 7을 읽는 이전 빌드는 모르는 키를 버린 채 다시 저장할 수 있으므로
    /// 그 값들은 형식 8에만 둔다). 이전 파일의 조각 사이 계보는 추측해 만들지 않는다(소유자 결정 2026-10-25).
    public static let currentVersion = 8
    public static let spectrumVersion = 8
    /// 켜진 자막 효과(외곽선·그림자·배경)가 있을 때의 형식(2026-10-23, D-040)
    public static let subtitleEffectsVersion = 7
    /// 자막(효과 없음)을 쓸 때의 형식. 켜진 자막 효과(외곽선·그림자·배경)가 있으면 형식 7(2026-10-23, D-040).
    public static let subtitleVersion = 6
    /// 자막이 없을 때 쓰는 형식(이전 앱 호환)
    public static let subtitleFreeVersion = 5
    public static let oldestReadableVersion = 1
    public static let fileExtension = "ontheframe"

    /// 미디어 항목: MediaRef + 프로젝트 파일 기준 상대 경로 + 앱 범위 보안 북마크(있으면)
    public struct MediaEntry: Codable, Sendable, Equatable {
        public var ref: MediaRef
        public var relativePath: String?
        public var bookmark: Data?
        public init(ref: MediaRef, relativePath: String?, bookmark: Data?) { self.ref = ref; self.relativePath = relativePath; self.bookmark = bookmark }
    }
    public struct Settings: Codable, Sendable, Equatable { public var width: Int; public var height: Int; public var fps: Int }
    public struct Document: Codable, Sendable, Equatable {
        public var format: String
        public var version: Int
        public var projectID: UUID
        public var settings: Settings
        public var durationFrames: Int
        public var lanes: [Lane]
        public var media: [MediaEntry]
        public var videoClips: [Clip]
        public var audioClips: [Clip]
        /// 형식 6만(없으면 키 없음)
        public var subtitles: [SubtitleItem]?
        /// 형식 8만(없으면 키 없음)
        public var spectra: [SpectrumItem]?
    }
    /// 이 타임라인을 쓸 형식 버전
    /// 쓰는 형식: 스펙트럼 레인·스펙트럼·소리 계보가 있으면 8, 켜진 자막 효과가 있으면 7, 자막·자막 레인이 있으면 6, 아니면 5.
    /// 꺼진 효과의 설정 값(enabled = false)은 형식 6에도 그대로 적는다 — 형식 6을 읽는 이전 빌드는 모르는 키를 무시하고(효과 없음),
    /// 이 빌드는 다시 읽어 설정을 되살린다. 이전 빌드가 그 파일을 다시 저장하면 꺼진 설정 값은 없어진다(효과가 꺼져 있으므로 그림은 같다).
    public static func version(for t: Timeline) -> Int {
        if t.needsSpectrumFormat || t.audioClips.contains(where: { $0.origin != nil }) { return spectrumVersion }
        if t.subtitles.contains(where: { $0.style.hasEnabledEffects }) { return subtitleEffectsVersion }
        return t.needsSubtitleFormat ? subtitleVersion : subtitleFreeVersion
    }
    private struct Header: Decodable { let format: String?; let version: Int? }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case notAProject
        case newerVersion(Int)
        case unsupportedVersion(Int)
        case malformed(String)
        case invalid(String)
        public var description: String {
            switch self {
            case .notAProject: return "ON THE FRAME 프로젝트 파일이 아닙니다."
            case .newerVersion(let v): return "더 새로운 버전(형식 \(v))에서 만든 프로젝트입니다. 이 앱은 형식 \(ProjectFile.currentVersion)까지 엽니다. 앱을 업데이트하세요."
            case .unsupportedVersion(let v): return "지원하지 않는 프로젝트 형식 버전(\(v))입니다."
            case .malformed(let s): return "프로젝트 파일이 손상되었거나 형식이 맞지 않습니다(\(s))."
            case .invalid(let s): return "프로젝트 내용이 올바르지 않습니다(\(s))."
            }
        }
    }

    /// 타임라인 → 파일 내용. bookmarks: 미디어 id → 북마크, projectURL: 상대 경로 기준(저장할 위치).
    /// 저장할 수 없는 타임라인(프레임 값 상한을 넘음 — 다시 열 수 없는 파일을 쓰지 않게)
    public struct SaveError: Error, Equatable, CustomStringConvertible { public var description: String { "타임라인이 너무 깁니다(프레임 값 상한을 넘어 저장하면 다시 열 수 없습니다)." } }
    /// Check the full catalog before producing any legacy bytes or touching a destination.
    public static func encode(_ content: ProductionContent, projectID: UUID, settings: RenderSettings, bookmarks: [UUID: Data], projectURL: URL?) throws -> Data {
        try encode(content.supportedTimeline(), projectID: projectID, settings: settings, bookmarks: bookmarks, projectURL: projectURL)
    }
    public static func encode(_ t: Timeline, projectID: UUID, settings: RenderSettings, bookmarks: [UUID: Data], projectURL: URL?) throws -> Data {
        _ = try ProductionContent(t).supportedTimeline()
        guard t.withinFrameLimit else { throw SaveError() }
        let dir = projectURL?.deletingLastPathComponent().standardizedFileURL
        let doc = Document(format: format, version: version(for: t), projectID: projectID,
                           settings: Settings(width: settings.width, height: settings.height, fps: Int(settings.fps)),
                           durationFrames: t.durationFrames, lanes: t.lanes,
                           media: t.media.map { r in
                               MediaEntry(ref: r, relativePath: dir.flatMap { d in relative(URL(fileURLWithPath: r.path), from: d) }, bookmark: bookmarks[r.id])
                           },
                           videoClips: t.clips, audioClips: t.audioClips, subtitles: t.needsSubtitleFormat ? t.subtitles : nil,
                           spectra: t.needsSpectrumFormat ? t.spectra : nil)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(doc)
    }

    /// 파일 안 프레임 값의 상한(2⁴⁰ 프레임, 30 fps로 약 1160년): 몇 개를 더해도 Int를 넘지 않는다. 실제 프로젝트는 이보다 훨씬 작다(입력은 길이 제한 안).
    static let maxFrames = Timeline.maxFrames
    /// 파일 내용 → 검사한 타임라인과 문서. 하나라도 맞지 않으면 오류(부분 결과 없음).
    public static func decode(_ data: Data, settings supported: RenderSettings = .m1) throws -> (timeline: Timeline, document: Document) {
        let dec = JSONDecoder()
        guard let h = try? dec.decode(Header.self, from: data) else { throw LoadError.malformed("JSON이 아님") }
        guard h.format == format else { throw LoadError.notAProject }
        guard let v = h.version else { throw LoadError.malformed("version 없음") }
        if v > currentVersion { throw LoadError.newerVersion(v) }
        guard v >= oldestReadableVersion else { throw LoadError.unsupportedVersion(v) }
        let doc: Document
        do { doc = try dec.decode(Document.self, from: data) } catch let e as DecodingError { throw LoadError.malformed(describe(e)) }
        // 렌더 설정: 1920×1080 30 fps만
        guard doc.settings == Settings(width: supported.width, height: supported.height, fps: Int(supported.fps)) else {
            throw LoadError.invalid("지원하지 않는 렌더 설정 \(doc.settings.width)×\(doc.settings.height) \(doc.settings.fps) fps")
        }
        // 레인: 형식 1은 영상 1 + 소리 1. 형식 2는 영상·오디오 각각 하나 이상(영상 레인이 위). ID 고유, 이름 있음, 음량 0–100.
        let lanes: [Lane]
        if v == 1 {
            guard doc.lanes.count == 2, Set(doc.lanes.map(\.kind)) == [.video, .audio] else { throw LoadError.invalid("레인") }
            lanes = [doc.lanes.first { $0.kind == .video }!, doc.lanes.first { $0.kind == .audio }!]
        } else if v <= 5 {
            // 형식 2 이상도 두 종류 레인이 하나씩은 있어야 한다(레인 없는 클립이 갈 곳이 없으면 잘못된 파일, 2026-10-11 리뷰).
            // 형식 5 이하에는 자막 레인·자막이 없다(있으면 잘못된 파일).
            guard Set(doc.lanes.map(\.kind)) == [.video, .audio], doc.subtitles == nil else { throw LoadError.invalid("레인") }
            lanes = doc.lanes
        } else {
            // 형식 6: 영상·오디오 각 하나 이상, 자막 레인은 0개 이상(형식 8: 스펙트럼 레인도 0개 이상)
            let kinds = Set(doc.lanes.map(\.kind))
            guard kinds.isSuperset(of: [.video, .audio]) else { throw LoadError.invalid("레인") }
            lanes = doc.lanes
        }
        // 스펙트럼 레인·스펙트럼·소리 계보는 형식 8에만 있다
        if v < spectrumVersion {
            guard !doc.lanes.contains(where: { $0.kind == .spectrum }), doc.spectra == nil, !(doc.videoClips + doc.audioClips).contains(where: { $0.origin != nil }) else {
                throw LoadError.invalid("스펙트럼·계보(형식 8 값)")
            }
        }
        guard Set(lanes.map(\.id)).count == lanes.count, lanes.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              lanes.allSatisfy({ (0...100).contains($0.volumePercent) }) else { throw LoadError.invalid("레인") }
        let laneKinds = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0.kind) })
        guard doc.videoClips.allSatisfy({ $0.lane == nil || laneKinds[$0.lane!] == .video }),
              doc.audioClips.allSatisfy({ $0.lane == nil || laneKinds[$0.lane!] == .audio }) else { throw LoadError.invalid("클립의 레인") }
        // 미디어: ID 고유, 길이 1 이상
        let refs = doc.media.map(\.ref)
        guard Set(refs.map(\.id)).count == refs.count, refs.allSatisfy({ $0.frameCount >= 1 && $0.frameCount <= maxFrames && !$0.name.isEmpty }) else { throw LoadError.invalid("미디어 목록") }
        let byID = Dictionary(uniqueKeysWithValues: refs.map { ($0.id, $0) })
        // 클립: ID 고유, 아는 미디어, 양수 길이·0 이상 위치
        let all = doc.videoClips + doc.audioClips
        let subs = doc.subtitles ?? [], sps = doc.spectra ?? []
        guard Set(all.map(\.id) + subs.map(\.id) + sps.map(\.id)).count == all.count + subs.count + sps.count else { throw LoadError.invalid("클립 ID 중복") }
        // 스펙트럼: 스펙트럼 레인, 범위·모양 값. 소스 키에 조각이 없어도 연다(소스 없음 — 정상 상태, 내보내기는 막음).
        guard sps.allSatisfy({ laneKinds[$0.lane] == .spectrum && $0.start >= 0 && $0.length >= 1 && $0.start <= maxFrames && $0.length <= maxFrames && $0.style.isValid }) else {
            throw LoadError.invalid("스펙트럼")
        }
        guard doc.videoClips.allSatisfy({ $0.origin == nil }) else { throw LoadError.invalid("영상 클립 계보") }
        // start + length가 넘치지 않게(손댄 파일, 코드 리뷰)
        guard subs.allSatisfy({ laneKinds[$0.lane] == .subtitle && $0.start >= 0 && $0.length >= 1 && $0.start <= Int.max - $0.length && $0.style.isValid
                                && $0.start <= maxFrames && $0.length <= maxFrames }) else { throw LoadError.invalid("자막") }
        // 켜진 효과는 형식 7에만 있다(형식 6 이하 파일에 켜진 효과가 있으면 잘못된 파일). 꺼진 효과 설정은 형식 6에도 있을 수 있다.
        if v < subtitleEffectsVersion, subs.contains(where: { $0.style.hasEnabledEffects }) { throw LoadError.invalid("자막 효과") }
        guard all.allSatisfy({ byID[$0.mediaID] != nil }) else { throw LoadError.invalid("알 수 없는 미디어를 쓰는 클립") }
        // 프레임 값 상한(2026-10-23 전체 검토): 모델을 만들기 전에 막는다. 만들자마자 끝(start + length)·원본 끝(sourceIn + length)을 계산하므로
        // 넘치는 값이 있으면 오류 대신 앱이 멈췄다(재현: start = Int.max). 페이드 길이·위치도 같은 상한이라 이후 덧셈(보이는 페이드 합, 자르기)이 넘치지 않는다.
        guard all.allSatisfy({ $0.start >= 0 && $0.sourceIn >= 0 && $0.length >= 1 }) else { throw LoadError.invalid("클립 위치·길이") }
        guard all.allSatisfy({ $0.start <= maxFrames && $0.sourceIn <= maxFrames && $0.length <= maxFrames }) else { throw LoadError.invalid("클립 위치·길이") }
        guard doc.durationFrames <= maxFrames else { throw LoadError.invalid("타임라인 길이") }
        guard doc.audioClips.allSatisfy({ a in [a.audio?.fadeIn, a.audio?.fadeOut].allSatisfy { f in f.map { (0...maxFrames).contains($0.length) && (0...maxFrames).contains($0.offset) } ?? true } }) else { throw LoadError.invalid("소리 페이드") }
        guard doc.audioClips.allSatisfy({ byID[$0.mediaID]!.hasAudio }) else { throw LoadError.invalid("소리 없는 미디어를 쓰는 소리 클립") }
        guard doc.videoClips.allSatisfy({ byID[$0.mediaID]!.hasVideo }) else { throw LoadError.invalid("영상 없는 미디어를 쓰는 영상 클립") }
        let t = Timeline(clips: doc.videoClips, audioClips: doc.audioClips, subtitles: subs, spectra: sps, lanes: lanes, media: refs, mediaFrames: byID.mapValues(\.frameCount),
                         mediaHasAudio: byID.mapValues(\.hasAudio), mediaHasVideo: byID.mapValues(\.hasVideo), durationFrames: doc.durationFrames)
        // 길이는 저장값 그대로여야 한다(클립 끝보다 짧으면 잘못된 파일). 겹침·원본 범위·연결 쌍은 isValid가 본다.
        guard t.durationFrames == doc.durationFrames, doc.durationFrames >= 0 else { throw LoadError.invalid("타임라인 길이") }
        guard t.isValid else { throw LoadError.invalid("겹침·원본 범위·연결 쌍·레인 순서") }
        return (t, doc)
    }

    /// 프로젝트 폴더 기준 상대 경로(같은 볼륨·하위 또는 ../ 경로). 계산할 수 없으면 nil.
    static func relative(_ file: URL, from dir: URL) -> String? {
        let f = file.standardizedFileURL.pathComponents, d = dir.standardizedFileURL.pathComponents
        guard f.count > 1, d.count > 1, f[1] == d[1] else { return nil }   // 같은 최상위(볼륨)만
        var i = 0
        while i < min(f.count, d.count), f[i] == d[i] { i += 1 }
        return (Array(repeating: "..", count: d.count - i) + f[i...]).joined(separator: "/")
    }
    static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, let c): return "\((c.codingPath + [k]).map(\.stringValue).joined(separator: ".")) 없음"
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): return c.codingPath.map(\.stringValue).joined(separator: ".") + " 값 오류"
        @unknown default: return "알 수 없는 오류"
        }
    }
}
