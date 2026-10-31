import Foundation

/// Narrow probe-to-model bridge. File access and development gating belong to the caller.
public enum StillImageImport {
    public struct Prepared: Sendable {
        let source: StillImageProjectModel.ValidatedImage
        public var url: URL { source.url }
    }
    public static func prepare(_ url: URL) async throws -> Prepared {
        try Task.checkCancellation()
        let work = Task.detached { Prepared(source: try await StillImageProjectModel.ValidatedImage.inspect(url)) }
        return try await withTaskCancellationHandler(operation: {
            let value = try await work.value
            try Task.checkCancellation()
            return value
        }, onCancel: { work.cancel() })
    }
    /// Both values are built locally; failed placement never registers orphan media.
    public static func inserting(_ image: Prepared, into timeline: Timeline, at start: Int,
                                 lane: UUID, mediaID: UUID, clipID: UUID) throws -> Timeline {
        try timeline.registeringImage(image.source,id:mediaID)
            .placingImage(media:mediaID,at:start,lane:lane,length:150,clipID:clipID)
    }
}
