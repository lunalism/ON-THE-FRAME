import Foundation
import OnTheFrameEngine

/// Stage 3B-1 lifecycle slice. ProjectStore owns authorized media; this object owns no scopes.
/// A synchronous main-actor fence complements the coordinator's queued epoch/Plan checks:
/// even a ready callback already queued before reset/update cannot be accepted afterwards.
/// Presentation/frame/seek identity belongs to the subsequent paused-overlay slice.
@MainActor
final class SpectrumPreviewSession {
    private let coordinator: SpectrumFrameCoordinator
    private(set) var epoch = 0
    private(set) var revision = 0
    #if DEBUG
    /// Hold an already produced outcome to test the app-side fence independently of engine cancellation.
    var beforeDeliveryForTest: ((SpectrumFrameOutcome) async -> Void)?
    #endif

    init(coordinator: SpectrumFrameCoordinator? = nil) {
        self.coordinator = coordinator ?? SpectrumFrameCoordinator(settings: .m1, deliveryQueue: .main)
    }

    func resetProject() {
        epoch &+= 1
        revision &+= 1
        coordinator.resetProject()
    }

    func update(timeline: Timeline, media: [MediaAsset]) {
        revision &+= 1
        coordinator.update(timeline: timeline, media: media)
    }

    @discardableResult
    func request(spectrum: UUID, frame: Int,
                 completion: @escaping @MainActor @Sendable (SpectrumFrameOutcome) -> Void) -> SpectrumFrameTicket {
        let requestedEpoch = epoch, requestedRevision = revision
        return coordinator.request(spectrum: spectrum, frame: frame, canvasWidth: 1920, canvasHeight: 1080) { [weak self] outcome in
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if DEBUG
                await self.beforeDeliveryForTest?(outcome)
                #endif
                guard self.epoch == requestedEpoch, self.revision == requestedRevision else {
                    completion(.superseded)
                    return
                }
                completion(outcome)
            }
        }
    }

    func cancel(_ ticket: SpectrumFrameTicket) { coordinator.cancel(ticket) }
}
