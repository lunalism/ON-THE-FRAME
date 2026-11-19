import AVFoundation
import OnTheFrameEngine

/// Output timing is a proxy for media available for display, not AVPlayerLayer scan-out proof.
/// The preview display link supplies target host timestamps.
@MainActor
final class SpectrumPlaybackTiming {
    private(set) weak var item: AVPlayerItem?
    private(set) var output: AVPlayerItemVideoOutput?
    private var lastFrame: Int?

    private weak var previewView: PlayerNSView?

    func attach(_ item: AVPlayerItem, view: PlayerNSView? = nil) {
        guard self.item !== item else { return }
        detach()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        self.item = item; self.output = output
        previewView = view
        view?.spectrumOutputChanged(on: item)
    }
    func detach() {
        if let item, let output {
            item.remove(output)
            previewView?.spectrumOutputChanged(on: item)
        }
        previewView = nil
        item = nil; output = nil
        invalidateApproval()
    }
    /// A transport can prepare the new target while no Spectrum frame is approved.
    /// Clearing this evidence never substitutes the previous frame for a seek target.
    func invalidateApproval() {
        lastFrame = nil
        #if DEBUG
        confirmedPTSForTest = .invalid
        #endif
    }
    /// Rational floor on the fixed 30fps grid; never clamp invalid/end time to a plausible frame.
    static func frame(_ time: CMTime, duration: Int) -> Int? {
        guard time.isNumeric, time.epoch == 0, time >= .zero, duration > 0 else { return nil }
        let value = CMTimeConvertScale(time, timescale: 30, method: .roundTowardNegativeInfinity).value
        guard value >= 0, value < Int64(duration) else { return nil }
        return Int(value)
    }
    static func select(requested: CMTime, display: CMTime, timeline: Timeline) -> Int? {
        guard let requestFrame = frame(requested, duration: timeline.durationFrames),
              let displayFrame = frame(display, duration: timeline.durationFrames), requestFrame == displayFrame,
              timeline.clips.contains(where: { $0.start <= displayFrame && displayFrame < $0.start + $0.length }) else { return nil }
        return displayFrame
    }
    /// Audio-backed intervals without video coverage follow the existing player item time.
    static func audioIntervalFrame(at time: CMTime, timeline: Timeline, validatedImageAccess: Bool = false) -> Int? {
        guard let frame = frame(time, duration: timeline.durationFrames),
              !timeline.clips.contains(where: { $0.start <= frame && frame < $0.end }),
              (!InternalImagePreview.containsImages(timeline) || validatedImageAccess),
              timeline.audioClips.contains(where: { $0.start <= frame && frame < $0.end }) else { return nil }
        if InternalImagePreview.containsImages(timeline) || !timeline.clips.contains(where: { $0.start <= frame }) {
            guard timeline.spectra.contains(where: { $0.visible(atFrame: frame) && hasActiveSource($0, at: frame, timeline: timeline) }) else { return nil }
        }
        return frame
    }

    static func hasActiveSource(_ item: SpectrumItem, at frame: Int, timeline: Timeline) -> Bool {
        guard let key = item.sourceKey else { return false }
        return timeline.audioClips.contains { $0.lineageKey == key && $0.start <= frame && frame < $0.end }
    }

    #if DEBUG
    private(set) var confirmedPTSForTest = CMTime.invalid
    private static func traceBoundary(_ frame: Int?) -> Bool {
        guard let frame else { return true }
        return (0...2).contains(frame) || (118...122).contains(frame)
            || (238...242).contains(frame) || (358...360).contains(frame)
    }
    #endif

    func sample(hostTime: CFTimeInterval, timeline: Timeline) -> Int? {
        guard hostTime.isFinite, let output, item != nil else {
            #if DEBUG
            if SpectrumContinuityTrace.ownerCapturing {
                SpectrumContinuityTrace.record(100, SpectrumContinuityTrace.tick, hostTime.isFinite ? 1 : 0,
                    SpectrumContinuityTrace.id(output), SpectrumContinuityTrace.id(item))
            }
            #endif
            return nil
        }
        let requested = output.itemTime(forHostTime: hostTime)
        return sample(requested: requested, timeline: timeline, hasNewBuffer: output.hasNewPixelBuffer(forItemTime: requested)) { display in
            output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &display) != nil
        }
    }

    func sample(requested: CMTime, timeline: Timeline, hasNewBuffer: @autoclosure () -> Bool,
                copyDisplayTime: (inout CMTime) -> Bool) -> Int? {
        #if DEBUG
        var traceDisplay = CMTime.invalid, traceReason: Int64 = 1, traceSelected: Int? = nil
        defer {
            if SpectrumContinuityTrace.active, SpectrumContinuityTrace.ownerCapturing || Self.traceBoundary(Self.frame(requested, duration: timeline.durationFrames)) {
                SpectrumContinuityTrace.record(23, SpectrumContinuityTrace.tick,
                    requested.isNumeric ? Int64(requested.seconds * 1_000_000) : -1,
                    traceDisplay.isNumeric ? Int64(traceDisplay.seconds * 1_000_000) : -1,
                    Int64(Self.frame(requested, duration: timeline.durationFrames) ?? -1),
                    Int64(traceSelected ?? -1), traceReason, Int64(lastFrame ?? -1),
                    SpectrumContinuityTrace.ownerCapturing ? Int64(Self.frame(traceDisplay, duration: timeline.durationFrames) ?? -1) : 0)
            }
        }
        #endif
        guard let frame = Self.frame(requested, duration: timeline.durationFrames),
              timeline.clips.contains(where: { $0.start <= frame && frame < $0.start + $0.length }) else { lastFrame = nil; return nil }
        guard hasNewBuffer() else {
            #if DEBUG
            traceReason = 2; traceSelected = lastFrame == frame ? frame : nil
            #endif
            return lastFrame == frame ? frame : nil
        }
        var display = CMTime.invalid
        // Acquire only to obtain its media timestamp. No readback, image copy, or retained pixel buffer.
        guard copyDisplayTime(&display) else {
            #if DEBUG
            traceReason = 3; traceDisplay = display
            #endif
            lastFrame = nil; return nil
        }
        lastFrame = Self.select(requested: requested, display: display, timeline: timeline)
        #if DEBUG
        confirmedPTSForTest = lastFrame == nil ? .invalid : display
        #endif
        #if DEBUG
        traceReason = 4; traceDisplay = display; traceSelected = lastFrame
        #endif
        return lastFrame
    }
}

/// Bounded playback consumer of the same coordinator as the paused overlay.
/// Cancelled tickets occupy slots until terminal delivery, bounding queued cancellation storms too.
@MainActor
final class PlaybackSpectrumController {
    struct Key: Hashable { let spectrum: UUID; let frame: Int }
    struct Pending {
        let ticket: SpectrumFrameTicket; let serial: Int; let start: Double; var cancelled = false
        #if DEBUG
        var traceRequest: Int64 = 0
        var traceCaptureID: UUID?
        var requestTiming: SpectrumRequestTiming?
        #endif
    }
    struct Stored { let outcome: SpectrumFrameOutcome; let bytes: Int }
    private enum CompletionState {
        case settled // retained image, stable empty result, or terminal source/analysis failure
        case needsCurrentImage // image evicted/not retained, or a cancelled/superseded delivery
        case budgetFailure // explicit terminal delivery policy; never exceeds the approved budget
    }
    struct Metrics {
        var requested = 0, cancelled = 0, stale = 0, dropped = 0, reused = 0, prefetchedCurrentHits = 0, peakPending = 0
        var peakBytes = 0, peakRetained = 0, recoveryRequests = 0, evicted = 0, retentionFailures = 0
        var accepted = 0, latencyTotal = 0.0, latencyMax = 0.0
        var ticks = 0, tickSeconds = 0.0, maxTickSeconds = 0.0
        var suspensions = 0, retainedWhileSuspended = 0, sourceRevalidations = 0, sourceRejections = 0
    }
    static let pendingLimit = 8, retainedLimit = 8, byteLimit = 16 * 1024 * 1024, lookahead = 2
    private weak var session: SpectrumPreviewSession?
    let timing = SpectrumPlaybackTiming()
    private(set) var currentFrame: Int?
    private var serial = 0
    private var firstVideoFrame = 0
    private var epoch = -1, revision = -1
    private var desired: [Key] = []
    private var completed: [Key: CompletionState] = [:]
    private var recoveryAttempted: Set<Key> = [] // at most one recovery per key during one current-frame activation
    private var pending: [Key: Pending] = [:]
    private var retained: [Key: Stored] = [:]
    private var needsSourceValidation: Set<Key> = []
    private var validationTask: Task<Void, Never>?
    private var validationSerial = 0
    private(set) var retainedBytes = 0
    private(set) var metrics = Metrics()
    var pendingCount: Int { pending.count }
    var retainedCount: Int { retained.count }
    init(session: SpectrumPreviewSession) { self.session = session }

    func stop(detachTiming: Bool = true) {
        #if DEBUG
        SpectrumContinuityTrace.record(30, Int64(currentFrame ?? -1), Int64(serial), SpectrumContinuityTrace.tick)
        #endif
        serial &+= 1; currentFrame = nil; desired.removeAll(keepingCapacity: true)
        cancelSourceValidation(); needsSourceValidation.removeAll(keepingCapacity: true)
        completed.removeAll(keepingCapacity: true); recoveryAttempted.removeAll(keepingCapacity: true)
        retained.removeAll(keepingCapacity: true); retainedBytes = 0
        cancelObsolete()
        if detachTiming { timing.detach() }
    }
    /// Keep only the same item's video-output transport across style/play/pause
    /// boundaries. Explicit seeks retire it through the preview host.
    /// Every accepted image and timestamp approval is still revoked.
    func prepareForTransition(item: AVPlayerItem, view: PlayerNSView) {
        stop(detachTiming: false)
        timing.attach(item, view: view)
        timing.invalidateApproval()
    }

    /// Schedule the confirmed paused position as a candidate in the ordinary
    /// playback budget. Only a later display tick can assign currentFrame.
    func prepareStartingFrame(_ frame: Int, timeline: Timeline) {
        guard let session, currentFrame == nil, desired.isEmpty,
              (0..<timeline.durationFrames).contains(frame) else { return }
        synchronizePlan(session, timeline: timeline)
        for item in timeline.spectra where item.visible(atFrame: frame) &&
            SpectrumPlaybackTiming.hasActiveSource(item, at: frame, timeline: timeline) {
            desired.append(Key(spectrum: item.id, frame: frame))
            if desired.count == Self.pendingLimit { break }
        }
        // A source can change while the player waits for its first display PTS.
        needsSourceValidation.formUnion(desired)
        pump(preparing: frame)
    }

    private func synchronizePlan(_ session: SpectrumPreviewSession, timeline: Timeline) {
        if epoch != session.epoch || revision != session.revision {
            stop(detachTiming: false); epoch = session.epoch; revision = session.revision
            firstVideoFrame = timeline.clips.lazy.map(\.start).min() ?? Int.max
        }
    }
    private func cancelObsolete() {
        for key in pending.keys {
            guard var p = pending[key], !p.cancelled, !desired.contains(key) else { continue }
            p.cancelled = true; pending[key] = p; metrics.cancelled += 1
            #if DEBUG
            p.requestTiming?.mark(.cancellationRequested)
            if p.traceCaptureID == SpectrumContinuityTrace.ownerCaptureID {
                SpectrumContinuityTrace.record(35, p.traceRequest, Int64(key.frame), Int64(p.serial), Int64(key.spectrum.hashValue))
            }
            #endif
            session?.cancel(p.ticket)
        }
    }
    /// nil means timing unavailable. No previous frame is carried forward as a current identity.
    func advance(frame: Int?, timeline: Timeline) {
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            metrics.ticks += 1; metrics.tickSeconds += elapsed; metrics.maxTickSeconds = max(metrics.maxTickSeconds, elapsed)
        }
        guard let session else { stop(); return }
        synchronizePlan(session, timeline: timeline)
        guard let frame else {
            if currentFrame != nil {
                // Timing permission is absent, but this seek/session's work can
                // still finish. No currentOutcome is exposed until fresh timing
                // and source validation both succeed.
                needsSourceValidation.formUnion(desired)
                cancelSourceValidation(); currentFrame = nil
                metrics.suspensions += 1
                #if DEBUG
                SpectrumContinuityTrace.record(39, Int64(serial), Int64(pending.count), Int64(retained.count))
                #endif
            }
            return
        }
        guard frame >= 0, frame < timeline.durationFrames else {
            stop(detachTiming: false)
            return
        }
        guard currentFrame != frame else { metrics.reused += 1; return }
        cancelSourceValidation()
        if retained.keys.contains(where: { $0.frame == frame }) { metrics.prefetchedCurrentHits += 1 }
        currentFrame = frame
        #if DEBUG
        SpectrumContinuityTrace.record(31, Int64(frame), Int64(serial), SpectrumContinuityTrace.tick)
        #endif
        desired.removeAll(keepingCapacity: true)
        // Current items precede all future items. More than 8 simultaneous items are explicitly capped.
        for offset in 0...Self.lookahead {
            let next = frame + offset
            guard next < timeline.durationFrames else { break }
            for item in timeline.spectra where item.visible(atFrame: next) {
                if desired.count == Self.pendingLimit { break }
                if next < firstVideoFrame && !SpectrumPlaybackTiming.hasActiveSource(item, at: next, timeline: timeline) { continue }
                desired.append(Key(spectrum: item.id, frame: next))
            }
        }
        completed = completed.filter { desired.contains($0.key) }
        needsSourceValidation = needsSourceValidation.filter { desired.contains($0) }
        recoveryAttempted.removeAll(keepingCapacity: true)
        for key in retained.keys where !desired.contains(key) {
            retainedBytes -= retained.removeValue(forKey: key)?.bytes ?? 0
        }
        cancelObsolete(); validateCurrentRetained(); pump()
    }
    private func pump(preparing frame: Int? = nil) {
        guard let session, let priorityFrame = currentFrame ?? frame,
              epoch == session.epoch, revision == session.revision else { return }
        for key in desired {
            guard pending.count < Self.pendingLimit else { break }
            guard pending[key] == nil else { continue }
            if let state = completed[key] {
                guard state == .needsCurrentImage, key.frame == currentFrame,
                      !recoveryAttempted.contains(key) else { continue }
                recoveryAttempted.insert(key); metrics.recoveryRequests += 1
            }
            let requestSerial = serial, start = ProcessInfo.processInfo.systemUptime
            #if DEBUG
            let requestTiming = session.requestTimings?.begin(frame: key.frame, priority: key.frame == priorityFrame ? 0 : 1,
                                                             serial: requestSerial, epoch: epoch, revision: revision)
            let traceRequest = requestTiming?.id ?? SpectrumContinuityTrace.next()
            let captureID = SpectrumContinuityTrace.ownerCaptureID
            SpectrumContinuityTrace.record(32, traceRequest, Int64(key.frame), Int64(requestSerial), Int64(epoch), Int64(revision), Int64(key.spectrum.hashValue))
            #else
            let traceRequest: Int64 = 0
            let captureID: UUID? = nil
            #endif
            let ticket = session.request(spectrum: key.spectrum, frame: key.frame,
                                         priority: key.frame == priorityFrame ? 0 : 1, checkPlaybackMedia: true,
                                         traceRequestID: traceRequest) { [weak self] outcome in
                #if DEBUG
                requestTiming?.mark(.controllerCallback, outcome: outcome.playbackTraceCode)
                if captureID == SpectrumContinuityTrace.ownerCaptureID {
                    SpectrumContinuityTrace.record(33, traceRequest, Int64(key.frame), Int64(requestSerial), SpectrumContinuityTrace.outcome(outcome))
                }
                #endif
                self?.finish(key, serial: requestSerial, outcome: outcome, traceRequest: traceRequest, captureID: captureID)
            }
            pending[key] = Pending(ticket: ticket, serial: requestSerial, start: start)
            #if DEBUG
            pending[key]?.requestTiming = requestTiming
            pending[key]?.traceRequest = traceRequest
            pending[key]?.traceCaptureID = captureID
            #endif
            metrics.requested += 1; metrics.peakPending = max(metrics.peakPending, pending.count)
        }
    }
    private func finish(_ key: Key, serial requestSerial: Int, outcome: SpectrumFrameOutcome, traceRequest: Int64, captureID: UUID?) {
        guard let p = pending[key], p.serial == requestSerial else {
            #if DEBUG
            if SpectrumContinuityTrace.ownerCapturing, SpectrumContinuityTrace.ownerCaptureID == captureID {
                SpectrumContinuityTrace.record(101, traceRequest, pending[key] == nil ? 1 : 2, Int64(key.frame), Int64(requestSerial), Int64(serial))
            }
            #endif
            metrics.stale += 1; return
        }
        pending[key] = nil
        #if DEBUG
        p.requestTiming?.mark(.slotReleased)
        #endif
        guard let session, !p.cancelled, serial == requestSerial, epoch == session.epoch,
              revision == session.revision, desired.contains(key) else {
            #if DEBUG
            if SpectrumContinuityTrace.ownerCapturing, SpectrumContinuityTrace.ownerCaptureID == captureID {
                let reason: Int64
                if session == nil { reason = 3 }
                else if p.cancelled { reason = 4 }
                else if serial != requestSerial { reason = 5 }
                else if epoch != session?.epoch { reason = 6 }
                else if revision != session?.revision { reason = 7 }
                else { reason = 8 } // no longer desired
                SpectrumContinuityTrace.record(101, traceRequest, reason, Int64(key.frame), Int64(requestSerial), Int64(serial))
            }
            #endif
            metrics.stale += 1; pump(); return
        }
        #if DEBUG
        if captureID == SpectrumContinuityTrace.ownerCaptureID {
            let traceImage: Int64
            if case let .ready(_, rendered) = outcome { traceImage = SpectrumContinuityTrace.id(rendered?.image) } else { traceImage = 0 }
            SpectrumContinuityTrace.record(34, p.traceRequest, Int64(key.frame), Int64(requestSerial), SpectrumContinuityTrace.outcome(outcome), traceImage, Int64(key.spectrum.hashValue))
        }
        #endif
        completed[key] = .settled
        let latency = ProcessInfo.processInfo.systemUptime - p.start
        metrics.accepted += 1; metrics.latencyTotal += latency; metrics.latencyMax = max(metrics.latencyMax, latency)
        if case .dropped = outcome { metrics.dropped += 1 }
        switch outcome {
        case let .ready(_, rendered):
            let bytes = rendered.map { $0.image.bytesPerRow * $0.image.height } ?? 0
            // An individually oversized image cannot be delivered within the fixed budget.
            // Do not evict useful entries for an impossible fit or silently report success.
            guard bytes <= Self.byteLimit else {
                completed[key] = .budgetFailure; metrics.retentionFailures += 1
                pump(); return
            }
            while bytes > Self.byteLimit - retainedBytes,
                  let victim = retained.keys.filter({ $0.frame > key.frame && (retained[$0]?.bytes ?? 0) > 0 }).max(by: { $0.frame < $1.frame }) {
                retainedBytes -= retained.removeValue(forKey: victim)?.bytes ?? 0
                completed[victim] = .needsCurrentImage; metrics.evicted += 1
            }
            if retained.count < Self.retainedLimit, bytes <= Self.byteLimit - retainedBytes {
                retained[key] = Stored(outcome: outcome, bytes: bytes); retainedBytes += bytes
                if currentFrame == nil { metrics.retainedWhileSuspended += 1 }
                #if DEBUG
                SpectrumContinuityTrace.record(41, Int64(key.frame), Int64(serial), Int64(bytes), currentFrame == nil ? 1 : 0)
                #endif
                metrics.peakBytes = max(metrics.peakBytes, retainedBytes)
                metrics.peakRetained = max(metrics.peakRetained, retained.count)
            } else if key.frame == currentFrame {
                // Same-frame items may collectively exceed capacity. Keep earlier admissions,
                // return an explicit failure, and do not recompute them on every tick.
                completed[key] = .budgetFailure; metrics.retentionFailures += 1
            } else {
                completed[key] = .needsCurrentImage // defer recovery until this frame is current
            }
        case .cancelled, .superseded:
            // One fresh ticket per current activation; persistent cancellation waits for a new activation.
            completed[key] = .needsCurrentImage
        default:
            break // nil/error/unavailable/overlap/drop remain stable for this desired window
        }
        validateCurrentRetained(); pump()
    }

    private func cancelSourceValidation() {
        validationSerial &+= 1
        // Keep the slot occupied until terminal completion: cancelling a Task
        // cannot interrupt an in-progress file metadata syscall.
        validationTask?.cancel()
    }

    private func validateCurrentRetained() {
        guard validationTask == nil, let session, let frame = currentFrame else { return }
        let keys = desired.filter { $0.frame == frame && needsSourceValidation.contains($0) && retained[$0] != nil }
        guard !keys.isEmpty else { return }
        let lifetime = serial, validation = validationSerial, e = epoch, r = revision
        // Only keys are captured: an async check never holds extra raster bytes
        // outside the controller's existing 16 MiB / eight-result budget.
        validationTask = Task { @MainActor [weak self, weak session] in
            defer {
                self?.validationTask = nil
                self?.validateCurrentRetained()
            }
            guard let session else { return }
            for key in keys {
                guard let self, !Task.isCancelled else { return }
                let failure: SpectrumFrameOutcome?
                if case .ready(_, .some)? = self.retained[key]?.outcome {
                    self.metrics.sourceRevalidations += 1
                    failure = await session.playbackMediaFailure(spectrum: key.spectrum)
                } else { failure = nil }
                guard !Task.isCancelled, self.serial == lifetime, self.validationSerial == validation,
                      self.epoch == e, self.revision == r, session.epoch == e, session.revision == r,
                      self.currentFrame == frame, self.desired.contains(key) else { return }
                if let failure, let old = self.retained[key] {
                    self.retainedBytes -= old.bytes
                    self.retained[key] = Stored(outcome: failure, bytes: 0)
                    self.metrics.sourceRejections += 1
                }
                self.needsSourceValidation.remove(key)
                #if DEBUG
                SpectrumContinuityTrace.record(42, Int64(key.frame), Int64(lifetime), failure == nil ? 1 : 0)
                #endif
            }
        }
    }
    /// A future result may be retained, but can only be retrieved once that exact frame is current.
    func currentOutcome(spectrum: UUID, frame: Int) -> SpectrumFrameOutcome? {
        guard frame == currentFrame, let session, epoch == session.epoch, revision == session.revision else { return nil }
        let key = Key(spectrum: spectrum, frame: frame)
        if needsSourceValidation.contains(key), case .ready(_, .some)? = retained[key]?.outcome { return nil }
        if completed[key] == .budgetFailure {
            return .failed(.render(.invalidCanvas("playback retained-image budget unavailable (16 MiB / 8 results)")))
        }
        return retained[key]?.outcome
    }

    #if DEBUG
    /// Explain a missing layer using the state actually seen at this publication.
    /// Ready-empty and terminal errors have a delivery; a queued request has none yet.
    func traceMissingLayer(spectrum: UUID, frame: Int, outcome: SpectrumFrameOutcome?) {
        guard SpectrumContinuityTrace.ownerCapturing else { return }
        let key = Key(spectrum: spectrum, frame: frame)
        let reason: Int64
        if frame != currentFrame { reason = 1 }
        else if epoch != session?.epoch || revision != session?.revision { reason = 2 }
        else if needsSourceValidation.contains(key), case .ready(_, .some)? = retained[key]?.outcome { reason = 3 }
        else if completed[key] == .budgetFailure { reason = 4 }
        else if outcome != nil { reason = 5 }
        else if let p = pending[key] { reason = p.cancelled ? 6 : 7 }
        else if !desired.contains(key) { reason = 8 }
        else if completed[key] == .settled { reason = 9 }
        else if completed[key] == .needsCurrentImage { reason = 10 }
        else { reason = 11 } // desired, awaiting admission
        let p = pending[key]
        SpectrumContinuityTrace.record(102, SpectrumContinuityTrace.tick, Int64(frame), Int64(spectrum.hashValue),
            Int64(serial), reason, p?.traceCaptureID == SpectrumContinuityTrace.ownerCaptureID ? (p?.traceRequest ?? 0) : 0,
            outcome.map(SpectrumContinuityTrace.outcome) ?? 0, Int64(pending.count))
    }
    #endif
}

extension ProjectStore {
    /// 3C-2 entry point. Called by the active preview display link.
    /// No CALayer assignment occurs here or in the controller.
    func sampleSpectrumPlayback(hostTime: CFTimeInterval) {
        let playback = spectrumPreview.playback
        guard isPlaying, player.rate != 0, let view = previewHost, view.window != nil,
              gestureBase == nil, !view.isShowingStill, appliedGeneration == generation,
              !view.hasPendingSpectrumSeek, let item = player.currentItem else {
            #if DEBUG
            SpectrumContinuityTrace.record(21, SpectrumContinuityTrace.tick, 1, isPlaying ? 1 : 0, Int64(generation), Int64(appliedGeneration))
            if SpectrumContinuityTrace.ownerCapturing {
                let reason: Int64
                if !isPlaying { reason = 1 }
                else if player.rate == 0 { reason = 2 }
                else if previewHost == nil { reason = 3 }
                else if previewHost?.window == nil { reason = 4 }
                else if gestureBase != nil { reason = 5 }
                else if previewHost?.isShowingStill == true { reason = 6 }
                else if appliedGeneration != generation { reason = 7 }
                else if previewHost?.hasPendingSpectrumSeek == true { reason = 8 }
                else { reason = 9 }
                SpectrumContinuityTrace.record(103, SpectrumContinuityTrace.tick, reason, Int64(seekToken),
                    Int64(projectSession), SpectrumContinuityTrace.id(player.currentItem), SpectrumContinuityTrace.id(playback.timing.item))
            }
            #endif
            if let view = previewHost, view.window != nil, view.spectrumOverlay.store === self,
               let item = player.currentItem, playback.timing.item === item {
                playback.stop(detachTiming: false)
                playback.timing.invalidateApproval()
            } else { playback.stop() }
            return
        }
        let hasImages = InternalImagePreview.containsImages(timeline)
        // Preserve composited timestamps in covered intervals. Access failure blanks
        // the spectrum even when already-decoded image textures remain displayable.
        if hasImages && !imagePlaybackAccessIsCurrent(for: item, allowProactiveRenewal: true) {
            #if DEBUG
            SpectrumContinuityTrace.record(21, SpectrumContinuityTrace.tick, 2, SpectrumContinuityTrace.lease)
            #endif
            if playback.timing.item === item, view.spectrumOverlay.store === self {
                playback.stop(detachTiming: false)
                playback.timing.invalidateApproval()
            } else { playback.stop() }
            return
        }
        playback.timing.attach(item, view: view)
        var frame = playback.timing.sample(hostTime: hostTime, timeline: timeline)
        #if DEBUG
        if frame == nil {
            let status = player.timeControlStatus
            // Capture the exact existing fallback query; no second playback clock.
            let fallbackTime = status == .playing ? item.currentTime() : CMTime.invalid
            if status == .playing {
                frame = SpectrumPlaybackTiming.audioIntervalFrame(at: fallbackTime, timeline: timeline, validatedImageAccess: hasImages)
            }
            let fallbackFrame = SpectrumPlaybackTiming.frame(fallbackTime, duration: timeline.durationFrames)
            if SpectrumContinuityTrace.active, SpectrumContinuityTrace.ownerCapturing || fallbackFrame == nil || [0, 1, 2, 118, 119, 120, 121, 122, 238, 239, 240, 241, 242, 358, 359, 360].contains(fallbackFrame!) {
                let covered = fallbackFrame.map { f in timeline.clips.contains { $0.start <= f && f < $0.end } } ?? false
                SpectrumContinuityTrace.record(24, SpectrumContinuityTrace.tick,
                    fallbackTime.isNumeric ? Int64(fallbackTime.seconds * 1_000_000) : -1,
                    Int64(fallbackFrame ?? -1), Int64(frame ?? -1), Int64(status.rawValue), covered ? 1 : 0)
            }
        }
        #else
        if frame == nil, player.timeControlStatus == .playing {
            frame = SpectrumPlaybackTiming.audioIntervalFrame(at: item.currentTime(), timeline: timeline, validatedImageAccess: hasImages)
        }
        #endif
        #if DEBUG
        SpectrumContinuityTrace.record(22, SpectrumContinuityTrace.tick, Int64(frame ?? -1), SpectrumContinuityTrace.lease)
        #endif
        playback.advance(frame: frame, timeline: timeline)
    }
}
