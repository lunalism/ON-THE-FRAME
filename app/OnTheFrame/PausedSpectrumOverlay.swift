import AppKit
import AVFoundation
import OnTheFrameEngine

/// NotificationCenter removal is thread-safe; automatic destruction avoids accessing
/// a non-Sendable AppKit observer token from NSView's nonisolated deinit.
final class SpectrumWindowObservation {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// One confirmed paused frame, from an exact seek or a natural item end.
@MainActor
final class PausedSpectrumOverlay {
    weak var view: PlayerNSView?
    weak var store: ProjectStore?
    private(set) var confirmedFrame: Int?
    private var confirmedToken: Int?
    private weak var confirmedItem: AVPlayerItem?
    private var presentingNaturalEnd = false
    private var serial = 0 // view/request lifetime, not another project session
    private var tickets: [SpectrumFrameTicket] = []
    private var styleRequestsRemaining = 0
    private var pendingStyleRefresh = false
    private(set) var layers: [UUID: CALayer] = [:]
    /// Exact inputs of the complete presentation now on the canvas (paused batch or playing tick).
    private struct Presentation: Equatable {
        let frame: Int, item: ObjectIdentifier, token: Int, epoch: Int, revision: Int
        let entries: [SpectrumItem]
    }
    private enum TransitionKind { case start, end }
    /// A presentation kept across one transport edge until playback can replace it,
    /// any input changes, or the bound expires. Checked only by the playback tick.
    private var transition: (kind: TransitionKind, presentation: Presentation, deadline: CFTimeInterval)?
    private var presented: Presentation?
    private var readyInBatch: Set<UUID> = []
    /// Claimed only by the natural-end refresh that immediately follows completion.
    private var naturalEndRetained: Presentation?
    /// About 7 composition frames. Measured transition gaps were 35–47 ms (TRANSITION-FIX-01).
    private static let transitionLimit: CFTimeInterval = 0.25
    /// IMAGE-SPECTRUM-FLICKER-FIX-01: at most one pending one-shot renewal step, only while a
    /// complete paused image presentation is visible in the active editor window.
    private var accessRenewalTimer: Timer?
    private var accessRenewalObservers: [SpectrumWindowObservation] = []
    /// PAUSE-FLICKER-FIX-01: the playing presentation kept across a manual Pause, only when it shows
    /// exactly the Pause frame. `token` is the Pause-owned seek; the hold ends when that seek's paused
    /// batch completes, on any invalidation, or at `deadline`.
    private struct PauseHold { let presentation: Presentation; var token: Int?; let deadline: CFTimeInterval }
    private var pauseHold: PauseHold?
    private var pauseHoldTimer: Timer?
    /// Bound on showing the retained (same-frame) raster while the exact seek and paused render finish.
    static let pauseHoldLimit: CFTimeInterval = 0.5
    #if DEBUG
    private(set) var pausedAccessRenewalSteps = 0
    var pausedAccessRenewalScheduledForTest: Bool { accessRenewalTimer != nil }
    /// Automation cannot always make the app frontmost; nil uses the real window/app state.
    var windowActiveOverrideForTest: Bool?
    #endif
    #if DEBUG
    private(set) var retainedTransitionTicks = 0
    private(set) var retainedNaturalEnds = 0
    private(set) var pauseRetentions = 0, pauseFrameMismatches = 0, pauseRetentionsDeclined = 0
    private(set) var pauseRetentionTimeouts = 0, pauseRetentionReplacements = 0
    var transitionRetentionForTest: String? {
        if let transition { return transition.kind == .start ? "start" : "end" }
        if pauseHold != nil { return "pause" }
        return naturalEndRetained == nil ? nil : "naturalEnd"
    }
    var pauseHoldTokenForTest: Int? { pauseHold?.token }
    var presentedFrameForTest: Int? { presented?.frame }
    var pauseHoldRemainingForTest: CFTimeInterval? { pauseHold.map { $0.deadline - CACurrentMediaTime() } }
    var playbackObservationForTest: (owner: UUID, observe: () -> Void)?
    var publicationForParityTest: (owner: UUID, receive: (Int, Int, UUID, SpectrumFrameOutcome) -> Void)?
    private(set) var assignments = 0
    private(set) var styleBatches = 0
    private(set) var coalescedStyleUpdates = 0
    private(set) var latencies: [Double] = []
    private(set) var updateCosts: [Double] = []
    #endif

    init(view: PlayerNSView) { self.view = view }
    private var playbackLink: CADisplayLink?

    func updatePlaybackLink() {
        defer { updatePausedAccessRenewal() }
        guard let store, let view, view.window != nil, store.isPlaying,
              !store.timeline.spectra.isEmpty else {
            #if DEBUG
            if SpectrumContinuityTrace.ownerCapturing, store?.isPlaying == true {
                SpectrumContinuityTrace.record(105, 4, SpectrumContinuityTrace.id(playbackLink), SpectrumContinuityTrace.id(view),
                    view?.window == nil ? 0 : 1, Int64(store?.timeline.spectra.count ?? 0))
            }
            #endif
            stopPlaybackLink(); return
        }
        guard playbackLink == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(playbackTick(_:)))
        playbackLink = link
        link.add(to: .main, forMode: .common)
        #if DEBUG
        if SpectrumContinuityTrace.ownerCapturing {
            SpectrumContinuityTrace.record(105, 1, SpectrumContinuityTrace.id(link), SpectrumContinuityTrace.id(view),
                Int64(store.projectSession), Int64(store.seekToken))
        }
        #endif
    }

    func stopPlaybackLink() {
        #if DEBUG
        if SpectrumContinuityTrace.ownerCapturing, let playbackLink {
            SpectrumContinuityTrace.record(105, 2, SpectrumContinuityTrace.id(playbackLink), SpectrumContinuityTrace.id(view))
        }
        #endif
        playbackLink?.invalidate()
        playbackLink = nil
        // Retention expires only on playback ticks; without a link it must not survive.
        if transition != nil { invalidate(forgetFrame: true) }
    }

    @objc private func playbackTick(_ link: CADisplayLink) {
        guard link === playbackLink, let store, let view, store.previewHost === view else {
            #if DEBUG
            if SpectrumContinuityTrace.ownerCapturing {
                SpectrumContinuityTrace.record(105, 3, SpectrumContinuityTrace.id(link), SpectrumContinuityTrace.id(view),
                    SpectrumContinuityTrace.id(playbackLink), SpectrumContinuityTrace.id(store?.previewHost))
            }
            #endif
            return
        }
        #if DEBUG
        SpectrumContinuityTrace.tick = SpectrumContinuityTrace.next()
        SpectrumContinuityTrace.record(20, SpectrumContinuityTrace.tick, Int64(link.targetTimestamp * 1_000_000), Int64(store.playhead))
        let traceOld = layers.values.first.flatMap { $0.contents as AnyObject? }
        var visibleSpectra: Int64 = 0
        #endif
        store.sampleSpectrumPlayback(hostTime: link.targetTimestamp)
        let controller = store.spectrumPreview.playback
        let frame = controller.currentFrame
        // Read every outcome before touching a layer, so a retained presentation stays intact.
        var ready: [(id: UUID, rendered: SpectrumRenderedFrame)] = []
        var visible = 0
        // An exposed non-image result (ready-empty or a retained failure) is a decision, not a wait.
        var decidedWithoutImage = false
        if let frame {
            for entry in store.timeline.spectra.reversed() where entry.visible(atFrame: frame) {
                visible += 1
                let outcome = controller.currentOutcome(spectrum: entry.id, frame: frame)
                #if DEBUG
                if SpectrumContinuityTrace.ownerCapturing { visibleSpectra += 1 }
                #endif
                guard case let .ready(_, rendered?) = outcome else {
                    if outcome != nil { decidedWithoutImage = true }
                    #if DEBUG
                    controller.traceMissingLayer(spectrum: entry.id, frame: frame, outcome: outcome)
                    #endif
                    continue
                }
                ready.append((entry.id, rendered))
            }
        }
        let complete = frame != nil && visible > 0 && ready.count == visible
        if retainsTransition(frame: frame, complete: complete, pending: !decidedWithoutImage, at: link.targetTimestamp) {
            #if DEBUG
            retainedTransitionTicks += 1
            SpectrumContinuityTrace.record(40, SpectrumContinuityTrace.tick, Int64(frame ?? -1),
                SpectrumContinuityTrace.id(traceOld), SpectrumContinuityTrace.id(traceOld),
                Int64(view.spectrumCanvas.sublayers?.count ?? 0), SpectrumContinuityTrace.lease, visibleSpectra)
            playbackObservationForTest?.observe()
            #endif
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var ordered: [CALayer] = []
        for (id, rendered) in ready {
            let layer = layers[id] ?? CALayer()
            layer.actions = PlayerNSView.noActions
            layer.contents = rendered.image
            layer.frame = Self.layerRect(rendered.drawRect)
            layers[id] = layer
            ordered.append(layer)
        }
        layers = layers.filter { ordered.contains($0.value) }
        view.spectrumCanvas.sublayers = ordered
        presented = complete ? frame.flatMap { currentPresentation(frame: $0) } : nil
        #if DEBUG
        SpectrumContinuityTrace.record(40, SpectrumContinuityTrace.tick, Int64(frame ?? -1),
            SpectrumContinuityTrace.id(traceOld), SpectrumContinuityTrace.id(ordered.first?.contents as AnyObject?),
            Int64(ordered.count), SpectrumContinuityTrace.lease, visibleSpectra)
        if SpectrumContinuityTrace.ownerCapturing, let frame {
            for (id, layer) in layers { traceLayer(layer, spectrum: id, frame: frame, playing: true, view: view) }
        }
        playbackObservationForTest?.observe()
        #endif
    }

    func attach(_ store: ProjectStore) {
        self.store = store
        if accessRenewalObservers.isEmpty {
            let names: [Notification.Name] = [
                NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification]
            accessRenewalObservers = names.map { name in
                SpectrumWindowObservation(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePausedAccessRenewal() }
                })
            }
        }
        updatePlaybackLink()
    }
    func detach() { stopPlaybackLink(); invalidate(forgetFrame: true); cancelPausedAccessRenewal(); endPauseHold(); store = nil }

    /// PAUSE-FLICKER-FIX-01. Called by `setPlaying(false, pauseFrame:)` for a manual Pause that will
    /// issue its own exact seek to `frame`. Keeps the canvas only when the last complete playing
    /// presentation is confirmed for exactly `frame` and is current (item, seek, session epoch and
    /// revision, visible items, image lease for image compositions); otherwise clears as before.
    /// A start/end retention in progress is not converted.
    func suspendForPause(at frame: Int) {
        guard let store, store.isPlaying, transition == nil, naturalEndRetained == nil, !presentingNaturalEnd,
              let presentation = presented else {
            #if DEBUG
            pauseRetentionsDeclined += 1
            #endif
            invalidate(forgetFrame: true); return
        }
        guard presentation.frame == frame else {
            // A different displayed frame is never shown as the paused frame.
            #if DEBUG
            pauseFrameMismatches += 1
            #endif
            invalidate(forgetFrame: true); return
        }
        guard retainable(presentation) else {
            #if DEBUG
            pauseRetentionsDeclined += 1
            #endif
            invalidate(forgetFrame: true); return
        }
        serial &+= 1
        tickets.forEach { store.spectrumPreview.cancel($0) }
        tickets = []
        readyInBatch = []
        styleRequestsRemaining = 0
        pendingStyleRefresh = false
        confirmedFrame = nil; confirmedToken = nil; confirmedItem = nil
        presented = nil
        cancelPausedAccessRenewal()
        endPauseHold()
        // For an image composition the hold never outlives the current lease (no tick or paused
        // renewal runs during the hold).
        var limit = Self.pauseHoldLimit
        if InternalImagePreview.containsImages(store.timeline), let item = store.player.currentItem {
            limit = min(limit, store.imageAccessValidRemaining(for: item))
        }
        let deadline = CACurrentMediaTime() + limit
        pauseHold = PauseHold(presentation: presentation, token: nil, deadline: deadline)
        let timer = Timer(timeInterval: limit, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseHoldExpired(deadline: deadline) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseHoldTimer = timer
        #if DEBUG
        pauseRetentions += 1
        #endif
    }

    /// The Pause-owned exact seek. Binds the hold to that seek token; a different frame or a second
    /// claim clears.
    func claimPauseSeek(token: Int, frame: Int) {
        guard var hold = pauseHold else { return }
        guard hold.token == nil, hold.presentation.frame == frame else { invalidate(forgetFrame: true); return }
        hold.token = token
        pauseHold = hold
    }

    /// The host's seek request. Every seek clears as before, except the claimed Pause-owned seek.
    func seekRequested(token: Int, frame: Int) {
        if let hold = pauseHold, hold.token == token, hold.presentation.frame == frame,
           CACurrentMediaTime() < hold.deadline { return }
        invalidate(forgetFrame: true)
    }

    private func pauseHoldExpired(deadline: CFTimeInterval) {
        guard let hold = pauseHold, hold.deadline == deadline else { return }
        // Not replaced in time: clear every retained raster not yet replaced by this paused batch.
        // The exact seek and its paused requests continue and install normally.
        endPauseHold()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (id, layer) in layers where !readyInBatch.contains(id) { layer.contents = nil; layer.frame = .zero }
        CATransaction.commit()
        presented = nil
        #if DEBUG
        pauseRetentionTimeouts += 1
        #endif
    }

    private func endPauseHold() {
        pauseHold = nil
        pauseHoldTimer?.invalidate()
        pauseHoldTimer = nil
    }

    /// The hold's presentation is still exactly current for its claimed seek: same frame, item,
    /// session epoch/revision and visible items, only the seek token advanced to the Pause-owned one;
    /// no later seek, edit, relink or project change; image lease valid now for image compositions.
    private func pauseRetainable(_ hold: PauseHold) -> Bool {
        guard let store, let view, view.window != nil, store.previewHost === view, !view.isShowingStill,
              !store.isPlaying, store.gestureBase == nil, !store.relinkInProgress,
              store.appliedGeneration == store.generation, let token = hold.token, token == store.seekToken,
              CACurrentMediaTime() < hold.deadline, let item = store.player.currentItem,
              ObjectIdentifier(item) == hold.presentation.item,
              Set(layers.keys) == Set(hold.presentation.entries.map(\.id)) else { return false }
        let p = hold.presentation
        guard currentPresentation(frame: p.frame) == Presentation(frame: p.frame, item: p.item, token: token,
                                                                  epoch: p.epoch, revision: p.revision, entries: p.entries)
        else { return false }
        return !InternalImagePreview.containsImages(store.timeline) || store.imageAccessIsValidNow(for: item)
    }

    /// The editor window is visible, unobscured, not minimized, and the app and window are active.
    private var editorWindowActive: Bool {
        #if DEBUG
        if let windowActiveOverrideForTest { return windowActiveOverrideForTest && view?.window != nil }
        #endif
        guard let window = view?.window else { return false }
        return NSApp.isActive && window.isVisible && !window.isMiniaturized &&
            window.occlusionState.contains(.visible) && (window.isKeyWindow || window.isMainWindow)
    }

    /// The paused, complete, current image presentation whose access may be renewed, or nil.
    private var pausedRenewalItem: AVPlayerItem? {
        guard let store, !store.isPlaying, transition == nil, naturalEndRetained == nil,
              InternalImagePreview.containsImages(store.timeline), editorWindowActive,
              let presentation = presented, let item = confirmedItem, store.player.currentItem === item,
              ObjectIdentifier(item) == presentation.item, presentation.frame == confirmedFrame,
              presentation.token == confirmedToken, presentationIsCurrent(presentation) else { return nil }
        return item
    }

    /// Start, keep or stop paused image-access renewal (IMAGE-SPECTRUM-FLICKER-FIX-01). Called when a
    /// paused presentation completes or clears, on transport changes and on window/app activity changes.
    /// No timer exists while the window is hidden, inactive or minimized, or while playing.
    func updatePausedAccessRenewal() {
        guard pausedRenewalItem != nil else { cancelPausedAccessRenewal(); return }
        if accessRenewalTimer == nil { pausedAccessRenewalStep() }
    }

    private func cancelPausedAccessRenewal() {
        accessRenewalTimer?.invalidate()
        accessRenewalTimer = nil
    }

    private func pausedAccessRenewalStep() {
        cancelPausedAccessRenewal()
        guard let store, let item = pausedRenewalItem else { return }
        #if DEBUG
        pausedAccessRenewalSteps += 1
        #endif
        guard let delay = store.renewPausedImageAccess(for: item) else { return }
        // A confirmed failure clears this presentation synchronously or on publication; the next
        // step then finds no eligible presentation and schedules nothing.
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.accessRenewalTimer = nil; self?.pausedAccessRenewalStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessRenewalTimer = timer
    }

    /// Seek/resume immediately invalidates the paused batch. Publish its newest
    /// coalesced model first so cancellation cannot discard the final style.
    /// No frame/image is carried into the new transition, and an already-current
    /// batch needs no extra session revision or coordinator update.
    func flushPendingStyleBeforeTransition() {
        guard pendingStyleRefresh else { return }
        pendingStyleRefresh = false
        guard let store else { return }
        store.spectrumPreview.update(timeline: store.timeline, media: store.assets)
    }

    func invalidate(forgetFrame: Bool = false) {
        if forgetFrame || presentingNaturalEnd {
            confirmedFrame = nil; confirmedToken = nil; confirmedItem = nil
            presentingNaturalEnd = false
        }
        clearPresentation()
    }

    /// Playback starts at the confirmed paused frame. Keep that complete, current
    /// presentation until the first complete playing frame (see `retainsTransition`);
    /// otherwise clear as before.
    func beginPlaybackTransition(at frame: Int?) {
        guard let frame, let store, !store.isPlaying, !presentingNaturalEnd, confirmedFrame == frame,
              confirmedToken == store.seekToken, let item = confirmedItem, store.player.currentItem === item,
              styleRequestsRemaining == 0, !pendingStyleRefresh,
              let presentation = presented, presentation.frame == frame, retainable(presentation) else {
            invalidate(forgetFrame: true); return
        }
        serial &+= 1
        tickets.forEach { store.spectrumPreview.cancel($0) }
        tickets = []
        readyInBatch = []
        confirmedFrame = nil; confirmedToken = nil; confirmedItem = nil
        transition = (.start, presentation, CACurrentMediaTime() + Self.transitionLimit)
    }

    /// Natural completion keeps the final complete playing frame for the natural-end
    /// refresh that follows synchronously. Anything else clears as before.
    func suspendForNaturalEnd() {
        guard let store, store.isPlaying, let presentation = presented,
              presentation.frame == store.timeline.durationFrames - 1, retainable(presentation) else {
            invalidate(forgetFrame: true); return
        }
        serial &+= 1
        styleRequestsRemaining = 0
        pendingStyleRefresh = false
        tickets.forEach { store.spectrumPreview.cancel($0) }
        tickets = []
        readyInBatch = []
        confirmedFrame = nil; confirmedToken = nil; confirmedItem = nil
        presentingNaturalEnd = false
        transition = nil
        presented = nil
        naturalEndRetained = presentation
    }

    /// The completion notification did not authorize the retained final frame.
    func releaseUnclaimedNaturalEnd() {
        if naturalEndRetained != nil { invalidate(forgetFrame: true) }
    }

    private func currentPresentation(frame: Int) -> Presentation? {
        guard let store, let item = store.player.currentItem else { return nil }
        return Presentation(frame: frame, item: ObjectIdentifier(item), token: store.seekToken,
                            epoch: store.spectrumPreview.epoch, revision: store.spectrumPreview.revision,
                            entries: store.timeline.spectra.reversed().filter { $0.visible(atFrame: frame) })
    }

    /// Same item, seek, session inputs, visible items and styles, with the canvas holding
    /// exactly those layers.
    private func presentationIsCurrent(_ presentation: Presentation) -> Bool {
        guard let store, let view, view.window != nil, store.previewHost === view, !view.isShowingStill,
              !view.hasPendingSpectrumSeek, store.gestureBase == nil, !store.relinkInProgress,
              store.appliedGeneration == store.generation,
              !presentation.entries.isEmpty, Set(layers.keys) == Set(presentation.entries.map(\.id)) else { return false }
        return currentPresentation(frame: presentation.frame) == presentation
    }

    /// `presentationIsCurrent`, and for an image composition an unexpired image lease right now
    /// (IMAGE-SPECTRUM-FLICKER-FIX-01). Checked at every retention decision and on every playback
    /// tick, so expiry, a pending check without a valid lease, failure or invalidation ends retention.
    private func retainable(_ presentation: Presentation) -> Bool {
        guard presentationIsCurrent(presentation), let store else { return false }
        guard InternalImagePreview.containsImages(store.timeline) else { return true }
        guard let item = store.player.currentItem, ObjectIdentifier(item) == presentation.item else { return false }
        return store.imageAccessIsValidNow(for: item)
    }

    /// Decided on each playback tick; no timer. Start waits until the first complete
    /// playing frame, end waits while sampling is past the final frame. Any mismatch ends it.
    ///
    /// START-FLICKER-FIX-03: the transport often samples a frame after the paused one
    /// before that frame's raster exists (the start candidate is prepared only for the
    /// paused frame, and later frames are requested when they become current). Ending
    /// retention on that first later frame emptied the canvas for one request latency.
    /// Start therefore also waits on later frames, but only while the same Spectrum items
    /// are visible there and every one of their results is still pending. The deadline,
    /// the per-tick input check (`retainable`) and every Pause/Seek/session invalidation
    /// are unchanged. A result the controller exposes without an image (ready-empty,
    /// budget failure, source revalidation failure) ends retention at once. Outcomes the
    /// controller does not retain stay invisible here and are bounded only by the deadline.
    private func retainsTransition(frame: Int?, complete: Bool, pending: Bool, at time: CFTimeInterval) -> Bool {
        guard let store, store.isPlaying else { transition = nil; return false }
        let end = store.timeline.durationFrames
        if transition == nil, frame == nil, let presentation = presented, presentation.frame == end - 1,
           let item = store.player.currentItem, item.status == .readyToPlay,
           item.duration == store.settings.time(end), item.currentTime() >= store.settings.time(presentation.frame) {
            transition = (.end, presentation, time + Self.transitionLimit)
        }
        guard let current = transition else { return false }
        let waiting: Bool
        switch current.kind {
        case .start:
            let start = current.presentation
            waiting = !complete && (frame.map { playing in
                playing == start.frame || (pending && playing > start.frame &&
                    store.timeline.spectra.reversed().filter { $0.visible(atFrame: playing) } == start.entries)
            } ?? true)
        case .end: waiting = frame == nil
        }
        guard waiting, time < current.deadline, retainable(current.presentation) else {
            transition = nil; return false
        }
        return true
    }

    private func clearPresentation() {
        serial &+= 1
        transition = nil
        presented = nil
        readyInBatch = []
        naturalEndRetained = nil
        cancelPausedAccessRenewal()
        endPauseHold()
        styleRequestsRemaining = 0
        pendingStyleRefresh = false
        if let store { tickets.forEach { store.spectrumPreview.cancel($0) } }
        tickets = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view?.spectrumCanvas.sublayers = nil
        layers = [:]
        CATransaction.commit()
    }

    func discardNaturalEnd() {
        if presentingNaturalEnd { invalidate(forgetFrame: true) }
    }

    func naturalPlaybackEnded(item: AVPlayerItem) {
        guard let store, let view, store.previewHost === view, view.window != nil,
              !view.hasPendingSpectrumSeek, !store.isPlaying, !store.relinkInProgress,
              store.appliedGeneration == store.generation, store.player.currentItem === item,
              item.status == .readyToPlay, store.playhead == store.timeline.durationFrames,
              store.playhead > 0 else { return }
        let frame = store.playhead - 1
        guard store.timeline.spectra.contains(where: { $0.visible(atFrame: frame) }) else { return }
        presentingNaturalEnd = true
        confirmedFrame = frame; confirmedToken = store.seekToken; confirmedItem = item
        refresh()
    }

    func seekFinished(token: Int, frame: Int, finished: Bool) {
        guard let store, token == store.seekToken, finished, !store.isPlaying,
              store.appliedGeneration == store.generation, let item = store.player.currentItem else { return }
        // Image reconstruction can seek the AV item to its last sample while the
        // UI stays at the exclusive endpoint. Only natural completion gets that view.
        guard store.playhead != store.timeline.durationFrames || frame == store.playhead else { return }
        confirmedFrame = frame; confirmedToken = token; confirmedItem = item
        refresh()
    }

    func refresh(retainingStyleFrame: Bool = false) {
        // Ordinary seeks/session changes still clear immediately. Only a style update
        // of the same confirmed paused frame may keep its previously validated image,
        // and natural completion may keep the identical final frame it just played.
        let retainedEnd = naturalEndRetained
        naturalEndRetained = nil
        if retainedEnd != nil, retainingStyleFrame { invalidate(forgetFrame: true); return }
        let retainingNaturalEnd = presentingNaturalEnd &&
            retainedEnd.map { $0.frame == confirmedFrame && retainable($0) } == true
        // PAUSE-FLICKER-FIX-01: only the paused refresh of the claimed Pause-owned seek, for the same frame.
        let retainingPause = !retainingNaturalEnd && !retainingStyleFrame && !presentingNaturalEnd &&
            pauseHold.map { $0.token == confirmedToken && $0.presentation.frame == confirmedFrame && pauseRetainable($0) } == true
        if pauseHold != nil && !retainingPause { invalidate(forgetFrame: false) }
        if retainingNaturalEnd {
            serial &+= 1
            if let store { tickets.forEach { store.spectrumPreview.cancel($0) } }
            tickets = []
            #if DEBUG
            retainedNaturalEnds += 1
            #endif
        } else if retainingPause {
            // Keep the identical-frame raster until this batch publishes; the hold and its deadline stay.
            serial &+= 1
            if let store { tickets.forEach { store.spectrumPreview.cancel($0) } }
            tickets = []
        } else if retainingStyleFrame {
            if styleRequestsRemaining > 0 {
                pendingStyleRefresh = true
                #if DEBUG
                coalescedStyleUpdates += 1
                #endif
                return
            }
            if let store { store.spectrumPreview.update(timeline: store.timeline, media: store.assets) }
            serial &+= 1
            if let store { tickets.forEach { store.spectrumPreview.cancel($0) } }
            tickets = []
        } else { clearPresentation() }
        guard let store, let view, view.window != nil, store.previewHost === view,
              !store.isPlaying, store.gestureBase == nil, !view.isShowingStill, store.appliedGeneration == store.generation,
              let frame = confirmedFrame, let token = confirmedToken, token == store.seekToken,
              let item = confirmedItem, store.player.currentItem === item else {
            if retainingStyleFrame || retainingNaturalEnd || retainingPause { invalidate() }
            return
        }
        presented = nil
        readyInBatch = []
        let generation = serial
        let epoch = store.spectrumPreview.epoch, revision = store.spectrumPreview.revision
        // Timeline stores top lanes first; CA paints bottom lanes first, as subtitles do.
        let entries = store.timeline.spectra.reversed().filter { $0.visible(atFrame: frame) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let visibleIDs = Set(entries.map(\.id))
        for id in Array(layers.keys) where !visibleIDs.contains(id) {
            layers.removeValue(forKey: id)?.removeFromSuperlayer()
        }
        for entry in entries where layers[entry.id] == nil {
            let layer = CALayer(); layer.actions = PlayerNSView.noActions
            layer.magnificationFilter = .linear; layer.minificationFilter = .linear
            layers[entry.id] = layer
            view.spectrumCanvas.addSublayer(layer)
        }
        CATransaction.commit()
        if retainingStyleFrame {
            styleRequestsRemaining = entries.count
            pendingStyleRefresh = false
            #if DEBUG
            styleBatches += 1
            #endif
        }
        for entry in entries {
            let start = ProcessInfo.processInfo.systemUptime
            let ticket = store.spectrumPreview.request(spectrum: entry.id, frame: frame) { [weak self, weak item] outcome in
                Task { @MainActor [weak self, weak item] in
                    guard let self else { return }
                    defer { if retainingStyleFrame { self.finishedStyleRequest(serial: generation) } }
                    guard self.serial == generation, let currentStore = self.store,
                          currentStore.spectrumPreview.epoch == epoch, currentStore.spectrumPreview.revision == revision else { return }
                    var accepted = outcome
                    if case .ready(_, .some) = outcome {
                        if self.presentingNaturalEnd, let item,
                           !(await currentStore.imageAccessAtNaturalEnd(for: item)) {
                            if self.serial == generation { self.discardNaturalEnd() }
                            return
                        }
                        if let mediaID = currentStore.timeline.spectrumMediaID(entry), let asset = currentStore.mediaByID[mediaID] {
                            // Cached analysis does not prove the file is still present/unchanged.
                            // Metadata checks stay off the main actor; scope ownership stays in ProjectStore.
                            let available = await Task.detached(priority: .userInitiated) {
                                FileIdentity.of(asset.url) == asset.identity && FileManager.default.isReadableFile(atPath: asset.url.path)
                            }.value
                            if !available {
                                accepted = .mediaUnavailable(mediaID)
                                #if DEBUG
                                ProjectStore.log.debug("paused spectrum media no longer matches inspected identity")
                                #endif
                            }
                        } else { accepted = .missingSource }
                    }
                    guard let store = self.store, let view = self.view,
                          view.window != nil, store.previewHost === view, self.serial == generation,
                          self.confirmedFrame == frame, self.confirmedToken == token, store.seekToken == token,
                          store.spectrumPreview.epoch == epoch, store.spectrumPreview.revision == revision,
                          !store.isPlaying, store.gestureBase == nil, !view.isShowingStill, store.appliedGeneration == store.generation,
                          let item, store.player.currentItem === item, let layer = self.layers[entry.id] else { return }
                    // A coalesced style edit can change the model before the next
                    // session revision. Keep the installed image until the new
                    // batch is ready, and let this completed request drain.
                    guard !retainingStyleFrame || store.timeline.spectrum(entry.id) == entry else { return }
                    let updateStart = ProcessInfo.processInfo.systemUptime
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    switch accepted {
                    case let .ready(_, rendered):
                        layer.contents = rendered?.image
                        layer.frame = rendered.map { Self.layerRect($0.drawRect) } ?? .zero
                        self.readyInBatch.insert(entry.id)
                        if self.readyInBatch == visibleIDs {
                            self.presented = Presentation(frame: frame, item: ObjectIdentifier(item), token: token,
                                                          epoch: epoch, revision: revision, entries: entries)
                            if let hold = self.pauseHold, hold.token == token {
                                // The paused result replaced every retained layer.
                                self.endPauseHold()
                                #if DEBUG
                                self.pauseRetentionReplacements += 1
                                #endif
                            }
                            self.updatePausedAccessRenewal()
                        }
                    case .cancelled, .superseded, .dropped:
                        // A natural-end frame stays only until its own paused publication: a
                        // non-ready result clears it, so no unverified final frame persists.
                        if !retainingStyleFrame { layer.contents = nil; layer.frame = .zero }
                    case .notVisible, .itemMissing, .unsetSource, .missingSource, .overlap, .mediaUnavailable:
                        layer.contents = nil; layer.frame = .zero
                    case let .failed(error):
                        layer.contents = nil; layer.frame = .zero
                        #if DEBUG
                        ProjectStore.log.debug("paused spectrum failed: \(String(describing: error), privacy: .public)")
                        #endif
                    }
                    CATransaction.commit()
                    if case .ready = accepted {} else { self.presented = nil }
                    #if DEBUG
                    if SpectrumContinuityTrace.ownerCapturing {
                        self.traceLayer(layer, spectrum: entry.id, frame: frame, playing: false, view: view)
                    }
                    self.publicationForParityTest?.receive(frame, token, entry.id, accepted)
                    self.assignments += 1
                    self.latencies.append(updateStart - start)
                    self.updateCosts.append(ProcessInfo.processInfo.systemUptime - updateStart)
                    if self.latencies.count > 256 { self.latencies.removeFirst(); self.updateCosts.removeFirst() }
                    #endif
                }
            }
            tickets.append(ticket)
        }
    }

    private func finishedStyleRequest(serial completedSerial: Int) {
        guard serial == completedSerial, styleRequestsRemaining > 0 else { return }
        styleRequestsRemaining -= 1
        if styleRequestsRemaining == 0, pendingStyleRefresh {
            pendingStyleRefresh = false
            // One completed batch, then the newest model snapshot. No timer or
            // display-frame skipping; seek/project invalidation still cancels all.
            refresh(retainingStyleFrame: true)
        }
    }

    #if DEBUG
    /// Model-layer evidence only. Capture the identity actually assigned under the canvas.
    private func traceLayer(_ layer: CALayer, spectrum: UUID, frame: Int, playing: Bool, view: PlayerNSView) {
        let canvas = view.spectrumCanvas
        var flags: Int64 = 0
        if layer.superlayer === canvas { flags |= 1 }
        if view.layer != nil, canvas.superlayer === view.layer { flags |= 2 }
        if !layer.isHidden, layer.opacity > 0, !canvas.isHidden, canvas.opacity > 0 { flags |= 4 }
        if !layer.frame.isEmpty, layer.frame.intersects(canvas.bounds) { flags |= 8 }
        if !view.isHiddenOrHasHiddenAncestor, view.window?.isVisible == true { flags |= 16 }
        if !canvas.frame.isEmpty, canvas.frame.intersects(view.bounds) { flags |= 32 }
        SpectrumContinuityTrace.record(104, SpectrumContinuityTrace.tick, Int64(frame), Int64(spectrum.hashValue),
            SpectrumContinuityTrace.id(layer.contents as AnyObject?), flags, SpectrumContinuityTrace.id(layer),
            Int64(canvas.sublayers?.count ?? 0), playing ? 1 : 0)
    }
    #endif

    /// Cropped image remains cropped. The image's top row is CA contents' top row.
    static func layerRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1080 - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension ProjectStore {
    /// Narrow preview comparison: retain all video/audio inputs and FULL duration, omit overlay-only values.
    static func previewVideoInputs(_ timeline: Timeline) -> Timeline {
        Timeline(clips: timeline.clips, audioClips: timeline.audioClips,
                 lanes: timeline.lanes.filter { $0.kind != .spectrum }, media: timeline.media,
                 mediaFrames: timeline.mediaFrames, mediaHasAudio: timeline.mediaHasAudio,
                 mediaHasVideo: timeline.mediaHasVideo, durationFrames: timeline.durationFrames)
    }
}
