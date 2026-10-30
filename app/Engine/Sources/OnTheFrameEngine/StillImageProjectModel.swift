import Foundation

/// Internal model/codec foundation. Never passed to the production renderer or ProjectStore.
enum StillImageProjectModel {
    enum MediaKind: String, Codable, Sendable { case video, audio, stillImage }
    enum Failure: Error { case invalid(String) }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.invalid(message) }
    }
    /// Portable descriptor snapshot; deliberately excludes inode/device and access ownership.
    /// A decoded snapshot is not proof of current file accessibility or validity.
    struct ImageInfo: Codable, Equatable, Sendable {
        let contractVersion: Int
        let encoding: StillImageDescriptor.Encoding
        let width: Int, height: Int, orientation: Int
        let componentBitDepth: Int, encodedSampleBitDepth: Int
        let colorModel: String, profileDisposition: String
        let profileSHA256: String?
        let alphaCapability: Bool
        init(_ d: StillImageDescriptor) {
            contractVersion=d.contractVersion; encoding=d.encoding; width=d.width; height=d.height; orientation=d.orientation
            componentBitDepth=d.componentBitDepth; encodedSampleBitDepth=d.encodedSampleBitDepth
            colorModel=d.colorModel; profileDisposition=d.profileDisposition; profileSHA256=d.profileSHA256; alphaCapability=d.alphaCapability
        }
        var displayWidth: Int { orientation >= 5 ? height : width }
        var displayHeight: Int { orientation >= 5 ? width : height }
        func validate() throws {
            try require(contractVersion == 1 && (1...8).contains(orientation), "image descriptor version/orientation")
            _ = try StillImageProbe.pixelAdmission(width: width, height: height, limits: .init())
            try require(componentBitDepth == 8 && ["RGB","Gray","Indexed"].contains(colorModel), "image descriptor color/depth")
            try require(colorModel == "Indexed" ? [1,2,4,8].contains(encodedSampleBitDepth) : encodedSampleBitDepth == 8, "encoded depth")
            if encoding == .jpeg { try require(encodedSampleBitDepth == 8 && colorModel != "Indexed" && !alphaCapability, "JPEG descriptor") }
            try require(["embedded-sRGB-ICC","explicit-sRGB","assumed-sRGB"].contains(profileDisposition), "image profile")
            if profileDisposition == "embedded-sRGB-ICC" {
                try require(profileSHA256?.count == 64 && profileSHA256!.allSatisfy { "0123456789abcdef".contains($0) }, "ICC digest")
            } else { try require(profileSHA256 == nil, "unexpected ICC digest") }
        }
    }
    /// Only full existing probe validation creates a relink capability, not JSON decoding.
    struct ValidatedImage: Sendable {
        let url: URL
        let descriptor: StillImageDescriptor
        private init(url: URL, descriptor: StillImageDescriptor) { self.url=url; self.descriptor=descriptor }
        static func inspect(_ url: URL) async throws -> Self {
            let metadata=try StillImageProbe.inspect(url)
            let result=try await StillImageProbe.validator.validate(metadata)
            return Self(url:url, descriptor:result.descriptor)
        }
    }
    struct ImageReference: Equatable, Sendable {
        let id: UUID
        let name: String, path: String
        let size: Int64, modifiedNs: Int64
        let image: ImageInfo
        init(id: UUID = UUID(), validated: ValidatedImage) {
            self.id=id; name=validated.url.lastPathComponent; path=validated.url.standardizedFileURL.path
            size=validated.descriptor.identity.size; modifiedNs=validated.descriptor.identity.modifiedNs
            image=ImageInfo(validated.descriptor)
        }
        func validate() throws {
            try image.validate()
            try require(!name.isEmpty && !path.isEmpty && size > 0 && size <= StillImageProbe.Limits().fileBytes, "image file metadata")
        }
        init(id: UUID, name: String, path: String, size: Int64, modifiedNs: Int64, image: ImageInfo) {
            self.id=id; self.name=name; self.path=path; self.size=size; self.modifiedNs=modifiedNs; self.image=image
        }
    }
    enum MediaReference: Equatable, Sendable {
        case video(MediaRef), audio(MediaRef), stillImage(ImageReference)
        var kind: MediaKind { switch self { case .video:return .video; case .audio:return .audio; case .stillImage:return .stillImage } }
        var temporal: MediaRef? { switch self { case .video(let r),.audio(let r):return r; case .stillImage:return nil } }
        var still: ImageReference? { if case .stillImage(let r)=self {return r}; return nil }
        var id: UUID { temporal?.id ?? still!.id }
        var path: String { temporal?.path ?? still!.path }
        var hasVideoTrack: Bool { kind == .video }
        var hasVisualContent: Bool { kind != .audio }
        var hasAudio: Bool { temporal?.hasAudio ?? false }
        static func legacy(_ r: MediaRef) -> Self { r.hasVideo ? .video(r) : .audio(r) }
    }
    struct MediaEntry: Equatable, Sendable {
        var ref: MediaReference
        var relativePath: String?
        var bookmark: Data?
    }
    struct Project: Equatable, Sendable {
        var projectID: UUID
        var settings: ProjectFile.Settings
        var durationFrames: Int
        var lanes: [Lane]
        var media: [MediaEntry]
        var videoClips: [Clip]
        var audioClips: [Clip]
        var subtitles: [SubtitleItem]?
        var spectra: [SpectrumItem]?
        init(_ d: ProjectFile.Document) {
            projectID=d.projectID; settings=d.settings; durationFrames=d.durationFrames; lanes=d.lanes
            media=d.media.map { .init(ref:.legacy($0.ref), relativePath:$0.relativePath, bookmark:$0.bookmark) }
            videoClips=d.videoClips; audioClips=d.audioClips; subtitles=d.subtitles; spectra=d.spectra
        }
        /// Temporal-only projection: images are omitted, never assigned a synthetic duration.
        func temporalDocument() -> ProjectFile.Document {
            let temporal=media.compactMap { e -> ProjectFile.MediaEntry? in
                guard let r=e.ref.temporal else {return nil}; return .init(ref:r, relativePath:e.relativePath, bookmark:e.bookmark)
            }
            let ids=Set(temporal.map { $0.ref.id })
            return .init(format:ProjectFile.format, version:8, projectID:projectID, settings:settings, durationFrames:durationFrames,
                         lanes:lanes, media:temporal, videoClips:videoClips.filter {ids.contains($0.mediaID)},
                         audioClips:audioClips, subtitles:subtitles, spectra:spectra)
        }
        func validate() throws {
            try require(Set(media.map { $0.ref.id }).count == media.count, "duplicate media")
            let byID=Dictionary(uniqueKeysWithValues:media.map { ($0.ref.id,$0.ref) })
            for entry in media {
                switch entry.ref {
                case .video(let r): try require(r.hasVideo, "video payload")
                case .audio(let r): try require(!r.hasVideo, "audio payload")
                case .stillImage(let r):
                    try r.validate()
                }
            }
            let all=videoClips+audioClips
            let ids=all.map(\.id)+(subtitles ?? []).map(\.id)+(spectra ?? []).map(\.id)
            try require(Set(ids).count == ids.count, "duplicate clip")
            try require(all.allSatisfy {byID[$0.mediaID] != nil}, "dangling media")
            let imageIDs=Set(media.filter {$0.ref.kind == .stillImage}.map {$0.ref.id})
            try require(audioClips.allSatisfy {!imageIDs.contains($0.mediaID)}, "image audio clip")
            let imageClips=videoClips.filter {imageIDs.contains($0.mediaID)}
            for c in imageClips { try validateImageClip(c, media:byID[c.mediaID]!, lanes:lanes) }
            let forbiddenSources=imageIDs.union(imageClips.map(\.id))
            let audioSources=Set(audioClips.map(\.lineageKey))
            // UUID namespaces may coincide. Existing audio lineage remains authoritative.
            try require((spectra ?? []).allSatisfy {$0.sourceKey.map {audioSources.contains($0) || !forbiddenSources.contains($0)} ?? true}, "image spectrum source")
            // Reuse all existing temporal, lane, subtitle, spectrum and lineage validation.
            _ = try ProjectFile.decode(JSONEncoder().encode(temporalDocument()))
            for lane in lanes where lane.kind == .video {
                var end=0
                for c in videoClips.filter({$0.lane == lane.id}).sorted(by:{$0.start < $1.start}) {
                    try require(c.start >= end, "visual overlap"); end=c.end
                }
                try require(end <= durationFrames, "project shorter than visual clips")
            }
        }
    }
    static let defaultInsertionFrames=150
    static func validateImageClip(_ c: Clip, media: MediaReference, lanes: [Lane]) throws {
        try require(media.kind == .stillImage && c.mediaID == media.id, "image media reference")
        let (end,overflow)=c.start.addingReportingOverflow(c.length)
        try require(!overflow && c.start >= 0 && c.length >= 1 && c.start <= Timeline.maxFrames && end <= Timeline.maxFrames, "image interval")
        try require(c.sourceIn == 0 && c.link == nil && c.audio == nil && c.origin == nil, "image temporal/audio lineage")
        try require(c.lane.flatMap { id in lanes.first {$0.id == id}?.kind } == .video && (c.transform?.isValid ?? true), "image visual lane/transform")
    }
    /// Explicit insertion/projection only. No duplicate ripple editor is introduced.
    static func insertingImage(media: MediaReference, at start: Int, lane: UUID, id: UUID = UUID(), length: Int = defaultInsertionFrames, lanes: [Lane] = Lane.defaults) throws -> Clip {
        let c=Clip(id:id, mediaID:media.id, start:start, sourceIn:0, length:length, lane:lane)
        try validateImageClip(c, media:media, lanes:lanes); return c
    }
    static func boundaries(_ c: Clip, media: MediaReference, start: Int, length: Int, lanes: [Lane], id: UUID? = nil) throws -> Clip {
        let result=c.with(start:start, length:length, id:id)
        try validateImageClip(result, media:media, lanes:lanes); return result
    }
    static func split(_ c: Clip, media: MediaReference, at: Int, lanes: [Lane], ids: (UUID,UUID) = (UUID(),UUID())) throws -> (Clip,Clip) {
        try validateImageClip(c, media:media, lanes:lanes)
        try require(at > c.start && at < c.end && ids.0 != ids.1 && ids.0 != c.id && ids.1 != c.id, "split interval/identity")
        return (try boundaries(c,media:media,start:c.start,length:at-c.start,lanes:lanes,id:ids.0),
                try boundaries(c,media:media,start:at,length:c.end-at,lanes:lanes,id:ids.1))
    }
    static func copy(_ c: Clip, media: MediaReference, at: Int, lanes: [Lane], id: UUID = UUID()) throws -> Clip {
        try require(id != c.id, "copy identity")
        return try boundaries(c,media:media,start:at,length:c.length,lanes:lanes,id:id)
    }
    struct RelinkChange: Equatable, Sendable {
        let before: ImageInfo, after: ImageInfo
        var requiresNotification: Bool { before.width != after.width || before.height != after.height || before.orientation != after.orientation }
    }
    static func relink(_ project: Project, mediaID: UUID, to replacement: ValidatedImage) throws -> (Project,RelinkChange) {
        try project.validate(); try Task.checkCancellation()
        try require(FileIdentity.of(replacement.url) == replacement.descriptor.identity, "relink source changed")
        guard let i=project.media.firstIndex(where:{$0.ref.id == mediaID}), let old=project.media[i].ref.still else {throw Failure.invalid("cross-kind relink")}
        let next=ImageReference(id:mediaID, validated:replacement)
        var result=project; result.media[i].ref = .stillImage(next)
        result.media[i].bookmark=nil; result.media[i].relativePath=nil // Old grants/relative hints do not describe the replacement.
        try result.validate()
        return (result,RelinkChange(before:old.image,after:next.image))
    }
}
