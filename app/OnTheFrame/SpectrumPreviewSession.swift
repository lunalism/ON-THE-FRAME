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
    var requestTimings: SpectrumRequestTimingCapture?
    /// Hold an already produced outcome to test the app-side fence independently of engine cancellation.
    var transformOutcomeForTest: ((UUID, Int, SpectrumFrameOutcome) async -> SpectrumFrameOutcome)?
    var beforeDeliveryForTest: ((SpectrumFrameOutcome) async -> Void)?
    #endif

    init(coordinator: SpectrumFrameCoordinator? = nil) {
        #if DEBUG
        if coordinator == nil, ProcessInfo.processInfo.arguments.contains("-OTFEnableDigitalSoftnessPreview") {
            self.coordinator = SpectrumFrameCoordinator(settings: .m1, deliveryQueue: .main, digitalSoftnessPreviewPilot: true)
            return
        }
        #endif
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

    /// REAL-MEDIA-FIX-01: warm the analysis PCM cache for a future frame (no request, no delivery).
    func prefetchAnalysis(spectrum: UUID, frame: Int) { coordinator.prefetchAnalysis(spectrum: spectrum, frame: frame) }
    var analysisStatistics: SpectrumSchedulerStatistics { coordinator.schedulerStatistics }

    func update(timeline: Timeline, media: [MediaAsset]) {
        playback.stop(detachTiming: false)
        playback.timing.invalidateApproval()
        revision &+= 1
        playbackTimeline = timeline
        playbackAssets = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        coordinator.update(timeline: timeline, media: media)
    }

    @discardableResult
    func request(spectrum: UUID, frame: Int, priority: Int = 0, checkPlaybackMedia: Bool = false, traceRequestID: Int64 = 0,
                 completion: @escaping @MainActor @Sendable (SpectrumFrameOutcome) -> Void) -> SpectrumFrameTicket {
        let requestedEpoch = epoch, requestedRevision = revision
        #if DEBUG
        let capture = checkPlaybackMedia && traceRequestID > 0 ? SpectrumContinuityTrace.ownerCaptureID : nil
        let timing = checkPlaybackMedia ? requestTimings?.request(id: traceRequestID) : nil
        #endif
        let receive: SpectrumFrameCoordinator.Completion = { [weak self] outcome in
            #if DEBUG
            timing?.mark(.deliveryInvoked)
            #endif
            Task { @MainActor [weak self] in
                #if DEBUG
                timing?.mark(.sessionReceived)
                #endif
                guard let self else { return }
                #if DEBUG
                if let capture { SpectrumContinuityTrace.recordOwner(capture, 157, traceRequestID, Int64(frame), outcome.playbackTraceCode) }
                if capture == SpectrumContinuityTrace.ownerCaptureID {
                    SpectrumContinuityTrace.record(36, Int64(spectrum.hashValue), Int64(frame), Int64(requestedEpoch), Int64(requestedRevision), SpectrumContinuityTrace.outcome(outcome))
                }
                #endif
                var accepted = outcome
                if checkPlaybackMedia, case .ready(_, .some) = outcome {
                    if let failure = await self.playbackMediaFailure(spectrum: spectrum) { accepted = failure }
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
                    if let capture { SpectrumContinuityTrace.recordOwner(capture, 158, traceRequestID, Int64(frame), self.epoch != requestedEpoch ? 2 : 3, SpectrumFrameOutcome.superseded.playbackTraceCode) }
                    if capture == SpectrumContinuityTrace.ownerCaptureID {
                        SpectrumContinuityTrace.record(38, Int64(spectrum.hashValue), Int64(frame), Int64(requestedEpoch), Int64(requestedRevision))
                    }
                    #endif
                    completion(.superseded)
                    return
                }
                #if DEBUG
                if let capture { SpectrumContinuityTrace.recordOwner(capture, 158, traceRequestID, Int64(frame), 1, accepted.playbackTraceCode) }
                if capture == SpectrumContinuityTrace.ownerCaptureID {
                    SpectrumContinuityTrace.record(37, Int64(spectrum.hashValue), Int64(frame), Int64(requestedEpoch), Int64(requestedRevision), SpectrumContinuityTrace.outcome(accepted))
                }
                #endif
                completion(accepted)
            }
        }
        #if DEBUG
        if let timing {
            return coordinator.request(spectrum: spectrum, frame: frame, canvasWidth: 1920, canvasHeight: 1080,
                                       priority: priority, playbackObserver: nil, timing: timing, completion: receive)
        }
        if let capture {
            return coordinator.request(spectrum: spectrum, frame: frame, canvasWidth: 1920, canvasHeight: 1080, priority: priority, playbackObserver: { stage, detail, value in
                SpectrumContinuityTrace.recordOwner(capture, stage.rawValue, traceRequestID, Int64(frame), detail, value)
            }, completion: receive)
        }
        #endif
        return coordinator.request(spectrum: spectrum, frame: frame, canvasWidth: 1920, canvasHeight: 1080, priority: priority, completion: receive)
    }

    func cancel(_ ticket: SpectrumFrameTicket) { coordinator.cancel(ticket) }

    /// Reused after a timing suspension too: a retained raster is not proof that
    /// its source is still accessible. Callers fence epoch/revision after await.
    func playbackMediaFailure(spectrum: UUID) async -> SpectrumFrameOutcome? {
        guard let timeline = playbackTimeline, let entry = timeline.spectrum(spectrum),
              let id = timeline.spectrumMediaID(entry), let asset = playbackAssets[id] else { return .missingSource }
        let available = await Task.detached(priority: .userInitiated) {
            FileIdentity.of(asset.url) == asset.identity && FileManager.default.isReadableFile(atPath: asset.url.path)
        }.value
        return available ? nil : .mediaUnavailable(id)
    }
}
