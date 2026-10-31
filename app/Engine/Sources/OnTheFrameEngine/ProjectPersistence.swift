import Foundation
import Darwin

/// Application persistence boundary. The legacy ProjectFile codec stays format 1–8;
/// format 9 uses the validated model/adapter without enabling image rendering.
public enum ProjectPersistence {
    public static let currentVersion = 9
    public enum Failure: Error, CustomStringConvertible {
        case futureVersion(Int), invalid(String), sourceChanged(UUID), beforeCommit(String)
        public var description: String {
            switch self {
            case .futureVersion(let v): return "더 새로운 프로젝트 형식(\(v))입니다. 이 앱은 형식 9까지 엽니다."
            case .invalid(let s): return "프로젝트를 검증하지 못했습니다: \(s)"
            case .sourceChanged: return "이미지 원본이 저장된 참조와 다릅니다. 편집 구조는 유지했습니다. 명시적인 재연결이 필요합니다."
            case .beforeCommit(let s): return "프로젝트 파일을 교체하기 전에 저장이 중단됐습니다: \(s)"
            }
        }
    }
    public enum Kind: Sendable { case video, audio, stillImage }
    public struct Reference: Sendable {
        public let id: UUID
        public let name: String, path: String
        public let kind: Kind
        public let temporal: MediaRef?
        public let relativePath: String?
        public let bookmark: Data?
    }
    public struct Project: Sendable {
        let state: OperationalProjectAdapter.State
        public let version: Int
        fileprivate init(state: OperationalProjectAdapter.State, version: Int? = nil) {
            self.state = state
            self.version = version ?? (state.timeline.stillImageIDs.isEmpty ? ProjectFile.version(for:state.timeline) : 9)
        }
        public var timeline: Timeline { state.timeline }
        public var projectID: UUID { state.projectID }
        public var settings: ProjectFile.Settings { state.settings }
        public var media: [Reference] {
            state.timeline.mediaCatalog.map { source in
                let location = state.locations[source.id]!
                return Reference(id:source.id,name:source.temporal?.name ?? source.still!.reference.name,
                    path:source.temporal?.path ?? source.still!.reference.path,
                    kind:source.kind == .stillImage ? .stillImage : (source.hasVideoTrack ? .video : .audio),
                    temporal:source.temporal,relativePath:location.relativePath,bookmark:location.bookmark)
            }
        }
    }
    public static func references(_ timeline: Timeline) -> [Reference] {
        timeline.mediaCatalog.map { source in
            Reference(id:source.id,name:source.temporal?.name ?? source.still!.reference.name,
                path:source.temporal?.path ?? source.still!.reference.path,
                kind:source.kind == .stillImage ? .stillImage : (source.hasVideoTrack ? .video : .audio),
                temporal:source.temporal,relativePath:nil,bookmark:nil)
        }
    }
    public static func make(timeline: Timeline, projectID: UUID, settings: RenderSettings = .m1,
                            bookmarks: [UUID: Data] = [:], relativePaths: [UUID: String] = [:]) throws -> Project {
        let keys = Set(bookmarks.keys).union(relativePaths.keys)
        let locations = Dictionary(uniqueKeysWithValues:keys.map {
            ($0,OperationalProjectAdapter.Location(relativePath:relativePaths[$0],bookmark:bookmarks[$0]))
        })
        return Project(state:try OperationalProjectAdapter.State(timeline:timeline,projectID:projectID,
            settings:.init(width:settings.width,height:settings.height,fps:Int(settings.fps)),locations:locations))
    }
    private struct Header: Decodable { let format: String; let version: Int }
    public static func decode(_ data: Data, settings: RenderSettings = .m1) throws -> Project {
        let header = try JSONDecoder().decode(Header.self,from:data)
        if header.format == ProjectFile.format, header.version > currentVersion { throw Failure.futureVersion(header.version) }
        let state = try OperationalProjectAdapter.decode(data)
        guard state.settings == .init(width:settings.width,height:settings.height,fps:Int(settings.fps)) else {
            throw Failure.invalid("지원하지 않는 프로젝트 렌더 설정")
        }
        return Project(state:state,version:header.version)
    }
    private static func prepared(_ project: Project, at destination: URL, resolvedURLs: [UUID: URL]) throws -> Project {
        let ids = Set(project.media.map(\.id))
        guard Set(resolvedURLs.keys).isSubset(of:ids) else { throw Failure.invalid("알 수 없는 미디어 위치") }
        var locations = project.state.locations
        for r in project.media {
            locations[r.id]?.relativePath = ProjectFile.relative(resolvedURLs[r.id] ?? URL(fileURLWithPath:r.path),from:destination.deletingLastPathComponent())
        }
        return Project(state:try .init(timeline:project.timeline,projectID:project.projectID,settings:project.settings,locations:locations))
    }
    public static func encode(_ project: Project, at destination: URL, resolvedURLs: [UUID: URL] = [:]) throws -> Data {
        let candidate = try prepared(project,at:destination,resolvedURLs:resolvedURLs)
        let data = try OperationalProjectAdapter.encode(candidate.state) // Prepared hints must not be recalculated from old paths.
        let decoded = try decode(data)
        guard try OperationalProjectAdapter.model(decoded.state) == OperationalProjectAdapter.model(candidate.state) else {
            throw Failure.invalid("저장 후보를 다시 읽었더니 내용이 다릅니다")
        }
        return data
    }
    /// Caller owns file access; this does not rewrite metadata or manufacture a validation proof.
    public static func validateImageReference(_ project: Project, mediaID: UUID, at source: URL) async throws {
        guard let reference = project.timeline.mediaCatalog.first(where:{$0.id == mediaID})?.still?.reference else { throw Failure.invalid("이미지 참조 없음") }
        let validated = try await StillImageProjectModel.ValidatedImage.inspect(source)
        guard reference.image == .init(validated.descriptor), reference.size == validated.descriptor.identity.size,
              reference.modifiedNs == validated.descriptor.identity.modifiedNs else { throw Failure.sourceChanged(mediaID) }
        try Task.checkCancellation()
    }
    public struct ImageChange: Sendable {
        public let requiresNotification: Bool
        public let oldWidth: Int, oldHeight: Int, oldOrientation: Int
        public let newWidth: Int, newHeight: Int, newOrientation: Int
    }
    /// Engine readiness only; no image relink menu/action is installed.
    public static func relinkImage(_ project: Project, mediaID: UUID, to source: URL) async throws -> (Project,ImageChange) {
        let validated = try await StillImageProjectModel.ValidatedImage.inspect(source)
        let (state,change) = try OperationalProjectAdapter.relink(project.state,mediaID:mediaID,to:validated)
        return (Project(state:state),ImageChange(requiresNotification:change.requiresNotification,
            oldWidth:change.before.width,oldHeight:change.before.height,oldOrientation:change.before.orientation,
            newWidth:change.after.width,newHeight:change.after.height,newOrientation:change.after.orientation))
    }
    public struct Receipt: Sendable {
        public let project: Project
        /// Replacement succeeded. A warning must never be reported as "the previous file is intact".
        public let postCommitWarning: String?
    }
    struct Operations {
        var commit: (URL,URL,Bool) throws -> Void = { temporary,destination,replacing in
            let result = replacing ? Darwin.rename(temporary.path,destination.path)
                : renamex_np(temporary.path,destination.path,UInt32(RENAME_EXCL))
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        }
        var afterCommit: () throws -> Void = {}
    }
    public static func write(_ project: Project, to destination: URL, resolvedURLs: [UUID: URL] = [:],
                             beforeCommit: () throws -> Void = {}) throws -> Receipt {
        try writeCandidate(project,to:destination,resolvedURLs:resolvedURLs,beforeCommit:beforeCommit,operations:Operations())
    }
    static func writeCandidate(_ project: Project, to destination: URL, resolvedURLs: [UUID: URL] = [:],
                               beforeCommit: () throws -> Void = {}, operations: Operations) throws -> Receipt {
        let destination = destination.standardizedFileURL
        func protectSources() throws {
            let identity = FileIdentity.of(destination), path = destination.resolvingSymlinksInPath().path
            let sources = project.media.map { URL(fileURLWithPath:$0.path) } + Array(resolvedURLs.values)
            for source in sources {
                if source.resolvingSymlinksInPath().path == path { throw Failure.invalid("원본 미디어를 프로젝트로 덮어쓸 수 없습니다") }
                if let identity, let original = FileIdentity.of(source), identity.sameFile(as:original) { throw Failure.invalid("원본 미디어 링크를 덮어쓸 수 없습니다") }
            }
        }
        let data: Data, decoded: Project
        do {
            try Task.checkCancellation()
            try protectSources()
            data = try encode(project,at:destination,resolvedURLs:resolvedURLs)
            decoded = try decode(data)
        } catch { throw Failure.beforeCommit(String(describing:error)) }
        let initial = FileIdentity.of(destination)
        let directory: URL
        do {
            // Preserve the app's Cocoa safe-save location convention: a raw sibling
            // is not necessarily writable under a file-only sandbox extension.
            directory = try FileManager.default.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:destination,create:true)
        } catch { throw Failure.beforeCommit(String(describing:error)) }
        let temporary = directory.appendingPathComponent(".ontheframe-save-"+UUID().uuidString+".tmp")
        defer { try? FileManager.default.removeItem(at:directory) }
        do {
            try data.write(to:temporary,options:.withoutOverwriting)
            if initial != nil {
                let attributes = try FileManager.default.attributesOfItem(atPath:destination.path)
                if let mode = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions:mode],ofItemAtPath:temporary.path) }
            }
            guard try Data(contentsOf:temporary) == data else { throw Failure.invalid("임시 파일 검증 실패") }
            try beforeCommit()
            try Task.checkCancellation()
            guard FileIdentity.of(destination) == initial else { throw Failure.invalid("저장 중 대상 파일이 바뀌었습니다") }
            // Same-volume rename: no cross-volume copy fallback and no direct destination writes.
            try protectSources()
            try operations.commit(temporary,destination,initial != nil)
        } catch { throw Failure.beforeCommit(String(describing:error)) }
        do {
            try operations.afterCommit()
            guard try Data(contentsOf:destination) == data else { throw Failure.invalid("교체 후 파일 검증 실패") }
            return Receipt(project:decoded,postCommitWarning:nil)
        } catch { return Receipt(project:decoded,postCommitWarning:String(describing:error)) }
    }
}
