import Foundation

/// Isolated engine bridge. Never called by normal app open/save or rendering.
enum OperationalProjectAdapter {
    typealias Model = StillImageProjectModel
    enum Failure: Error, Equatable {
        case invalid(String)
        case sourceUnavailable(UUID)
        case cancelled
    }
    struct Location: Equatable, Sendable {
        var relativePath: String?
        var bookmark: Data?
    }
    struct State: Equatable, Sendable {
        let projectID: UUID
        let settings: ProjectFile.Settings
        let timeline: Timeline
        let locations: [UUID: Location]
        init(timeline: Timeline, projectID: UUID, settings: ProjectFile.Settings = .init(width:1920,height:1080,fps:30),
             locations: [UUID: Location] = [:]) throws {
            self.projectID = projectID; self.settings = settings; self.timeline = timeline
            let ids = Set(timeline.mediaCatalog.map(\.id))
            guard Set(locations.keys).isSubset(of:ids) else { throw Failure.invalid("location without media") }
            self.locations = Dictionary(uniqueKeysWithValues:ids.map { ($0,locations[$0] ?? Location()) })
            _ = try OperationalProjectAdapter.model(self)
        }
    }
    private static func checked<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as Failure { throw error }
        catch is CancellationError { throw Failure.cancelled }
        catch { throw Failure.invalid(String(describing:error)) }
    }
    static func model(_ state: State) throws -> Model.Project {
        try checked {
            let t = state.timeline, catalog = t.mediaCatalog
            try Model.require(t.isValid, "operational timeline invariants")
            let ids = Set(catalog.map(\.id)), temporal = catalog.compactMap(\.temporal)
            // A frame-only registry or contradictory capability table is not silently discarded.
            try Model.require(Set(t.mediaFrames.keys) == Set(temporal.map(\.id)), "temporal registry/catalog mismatch")
            try Model.require(Set(t.mediaHasAudio.keys).isSubset(of:ids) && Set(t.mediaHasVideo.keys).isSubset(of:ids), "unknown capability entry")
            for r in catalog {
                if let source = r.temporal { try Model.require(t.mediaFrames[r.id] == source.frameCount, "source frame mismatch") }
                try Model.require((t.mediaHasAudio[r.id] ?? false) == r.hasAudio && (t.mediaHasVideo[r.id] ?? true) == r.hasVideoTrack, "capability mismatch")
            }
            var p = Model.Project(.init(format:ProjectFile.format,version:8,projectID:state.projectID,settings:state.settings,
                durationFrames:t.durationFrames,lanes:t.lanes,media:[],videoClips:t.clips,audioClips:t.audioClips,
                subtitles:t.needsSubtitleFormat ? t.subtitles : nil,spectra:t.needsSpectrumFormat ? t.spectra : nil))
            p.media = catalog.map { r in
                let ref: Model.MediaReference
                switch r {
                case .temporal(let source): ref = .legacy(source)
                case .stillImage(let source): ref = .stillImage(source.reference)
                }
                let location = state.locations[r.id]!
                return .init(ref:ref,relativePath:location.relativePath,bookmark:location.bookmark)
            }
            try p.validate()
            return p
        }
    }
    static func restore(_ project: Model.Project,
                        validatedImages: [UUID: Model.ValidatedImage] = [:]) throws -> State {
        try checked {
            // Neither restoration nor project validity requires opening external media.
            let timeline = try Timeline.restoring(project,validatedImages:validatedImages)
            let locations = Dictionary(uniqueKeysWithValues:project.media.map {
                ($0.ref.id,Location(relativePath:$0.relativePath,bookmark:$0.bookmark))
            })
            return try State(timeline:timeline,projectID:project.projectID,settings:project.settings,locations:locations)
        }
    }
    static func encode(_ state: State, projectURL: URL? = nil) throws -> Data {
        try checked { try StillImageProjectCodec.encode(model(state),projectURL:projectURL) }
    }
    static func decode(_ data: Data) throws -> State {
        try checked { try restore(StillImageProjectCodec.decode(data)) }
    }
    /// Validation of the existing path is explicit; the caller owns security-scoped access.
    /// A failure reports availability separately and leaves the portable project unchanged.
    static func revalidate(_ state: State, mediaID: UUID) async throws -> State {
        guard let ref = state.timeline.mediaCatalog.first(where: { $0.id == mediaID })?.still?.reference else {
            throw Failure.invalid("not an image reference")
        }
        let validated: Model.ValidatedImage
        do { validated = try await Model.ValidatedImage.inspect(URL(fileURLWithPath:ref.path)) }
        catch is CancellationError { throw Failure.cancelled }
        catch { throw Failure.sourceUnavailable(mediaID) }
        var proofs = currentProofs(state); proofs[mediaID] = validated
        return try restore(model(state),validatedImages:proofs) // Reject mismatch; never silently migrate/relink.
    }
    static func relink(_ state: State, mediaID: UUID, to replacement: Model.ValidatedImage) throws -> (State,Model.RelinkChange) {
        try checked {
            let (project,change) = try Model.relink(model(state),mediaID:mediaID,to:replacement)
            var proofs = currentProofs(state); proofs[mediaID] = replacement
            return (try restore(project,validatedImages:proofs),change)
        }
    }
    private static func currentProofs(_ state: State) -> [UUID: Model.ValidatedImage] {
        Dictionary(uniqueKeysWithValues:state.timeline.mediaCatalog.compactMap { r in
            r.still?.validated.map { (r.id,$0) }
        })
    }
}
