import Foundation
import OnTheFrameEngine

/// Stage 3B-1 lifecycle slice. ProjectStore owns authorized media; this object owns no scopes.
/// A synchronous main-actor fence complements the coordinator's queued epoch/Plan checks:
/// even a ready callback already queued before reset/update cannot be accepted afterwards.
/// Presentation/frame/seek identity belongs to the subsequent paused-overlay slice.
@MainActor
final class SpectrumPreviewSession {
    lazy var playback = PlaybackSpectrumController(session: self)
    private var playbackAssets: [UUID: MediaAsset] = [:]
    private var playbackTimeline: Timeline?
    private let coordinator: SpectrumFrameCoordinator
    private(set) var epoch = 0
    private(set) var revision = 0
    #if DEBUG
    /// Hold an already produced outcome to test the app-side fence independently of engine cancellation.
    var transformOutcomeForTest: ((UUID, Int, SpectrumFrameOutcome) async -> SpectrumFrameOutcome)?
    var beforeDeliveryForTest: ((SpectrumFrameOutcome) async -> Void)?
    #endif

    init(coordinator: SpectrumFrameCoordinator? = nil) {
        self.coordinator = coordinator ?? SpectrumFrameCoordinator(settings: .m1, deliveryQueue: .main)
    }

    func resetProject() {
        playback.stop()
        playbackAssets.removeAll()
        playbackTimeline = nil
        epoch &+= 1
        revision &+= 1
        coordinator.resetProject()
    }

    func update(timeline: Timeline, media: [MediaAsset]) {
        playback.stop()
        revision &+= 1
        playbackTimeline = timeline
        playbackAssets = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        coordinator.update(timeline: timeline, media: media)
    }

    @discardableResult
    func request(spectrum: UUID, frame: Int, priority: Int = 0, checkPlaybackMedia: Bool = false,
                 completion: @escaping @MainActor @Sendable (SpectrumFrameOutcome) -> Void) -> SpectrumFrameTicket {
        let requestedEpoch = epoch, requestedRevision = revision
        return coordinator.request(spectrum: spectrum, frame: frame, canvasWidth: 1920, canvasHeight: 1080, priority: priority) { [weak self] outcome in
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG
                SpectrumContinuityTrace.record(36, Int64(spectrum.hashValue), Int64(frame), Int64(requestedEpoch), Int64(requestedRevision), SpectrumContinuityTrace.outcome(outcome))
                #endif
                var accepted = outcome
                if checkPlaybackMedia, case .ready(_, .some) = outcome {
                    if let timeline = self.playbackTimeline, let entry = timeline.spectra.first(where: { $0.id == spectrum }),
                       let id = timeline.spectrumMediaID(entry), let asset = self.playbackAssets[id] {
                        let available = await Task.detached(priority: .userInitiated) {
                            FileIdentity.of(asset.url) == asset.identity && FileManager.default.isReadableFile(atPath: asset.url.path)
                        }.value
                        if !available { accepted = .mediaUnavailable(id) }
                    } else { accepted = .missingSource }
                }
                #if DEBUG
                // Synthetic controller tests have no configured project or media.
                // Configured projects may delay delivery but always keep the validated outcome.
                let synthetic: Bool
                if case .itemMissing = outcome { synthetic = self.playbackTimeline == nil }
                else { synthetic = false }
                if let transform = self.transformOutcomeForTest {
                    let injected = await transform(spectrum, frame, accepted)
                    if synthetic { accepted = injected }
                }
                await self.beforeDeliveryForTest?(accepted)
                #endif
                guard self.epoch == requestedEpoch, self.revision == requestedRevision else {
                    #if DEBUG
                    SpectrumContinuityTrace.record(38, Int64(spectrum.hashValue), Int64(frame), Int64(requestedEpoch), Int64(requestedRevision))
                    #endif
                    completion(.superseded)
                    return
                }
                #if DEBUG
                SpectrumContinuityTrace.record(37, Int64(spectrum.hashValue), Int64(frame), Int64(requestedEpoch), Int64(requestedRevision), SpectrumContinuityTrace.outcome(accepted))
                #endif
                completion(accepted)
            }
        }
    }

    func cancel(_ ticket: SpectrumFrameTicket) { coordinator.cancel(ticket) }
}
