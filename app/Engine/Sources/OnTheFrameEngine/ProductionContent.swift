import Foundation

/// A complete content boundary, not a visible-layer or temporal-only projection.
/// Inspects the complete operational catalog, including unused still sources.
public struct ProductionContent: Sendable {
    public enum Unsupported: Error, Equatable, CustomStringConvertible {
        case stillImages([UUID])
        public var description: String {
            "정지 이미지가 포함된 프로젝트의 저장·프리뷰·내보내기는 아직 지원하지 않습니다. 프로젝트 내용은 변경하지 않았습니다."
        }
    }
    private let timeline: Timeline?
    private let imageIDs: [UUID]

    public init(_ timeline: Timeline) {
        self.timeline = timeline
        imageIDs = timeline.stillImageIDs.sorted { $0.uuidString < $1.uuidString }
    }

    /// Internal test/design adapter. No normal format-9 open/import entry point.
    init(isolated project: StillImageProjectModel.Project) throws {
        try project.validate()
        imageIDs = project.media.compactMap { $0.ref.still?.id }.sorted { $0.uuidString < $1.uuidString }
        // Never call the lossy temporal projection when even an unused image exists.
        if imageIDs.isEmpty {
            timeline = try ProjectFile.decode(JSONEncoder().encode(project.temporalDocument())).timeline
        } else {
            timeline = nil
        }
    }

    public func supportedTimeline() throws -> Timeline {
        guard imageIDs.isEmpty, let timeline else { throw Unsupported.stillImages(imageIDs) }
        return timeline
    }
}
