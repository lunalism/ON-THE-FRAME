import AVFoundation
import OnTheFrameEngine
import QuartzCore

/// Output timing is a proxy for media available for display, not AVPlayerLayer scan-out proof.
/// The preview display link supplies target host timestamps.
@MainActor
final class SpectrumPlaybackTiming {
    private(set) weak var item: AVPlayerItem?
    private(set) var output: AVPlayerItemVideoOutput?
    private var lastFrame: Int?
    /// VIDEO-TIMING-FIX-01: armed only by `armStartupRegression` for one exact playback start.
    /// Any approval invalidation (Pause, Seek, session revision, item/output change, transport guard)
    /// disarms it; forward progress past the start frame or the deadline ends it.
    private var startupRegression: (frame: Int, item: ObjectIdentifier, deadline: CFTimeInterval)?
    /// Same bound as the overlay's playback-start transition (PausedSpectrumOverlay.transitionLimit).
    static let startupRegressionLimit: CFTimeInterval = 0.25
    /// About the bound in composition frames; a deeper regression is not a startup preroll.
    static let startupRegressionFrames = 8
    #if DEBUG
    private(set) var startupRegressionReusesForTest = 0
    private(set) var repeatedImageAdvancesForTest = 0
    #endif

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
        startupRegression = nil
        #if DEBUG
        confirmedPTSForTest = .invalid
        #endif
    }
    /// Called by the playback controller when it prepares the confirmed paused frame of an
    /// image-free playback start. At startup the video output can map display host times to item
    /// times slightly before the start position (FX02C-TIMING-CAPTURE-01: 342 approved, then
    /// requests for 340–341 for ~55 ms with no new buffer). Only that pattern may reuse the start
    /// frame; see `sample(requested:...)`.
    func armStartupRegression(frame: Int, now: CFTimeInterval = CACurrentMediaTime()) {
        guard let item, lastFrame == nil else { startupRegression = nil; return }
        startupRegression = (frame, ObjectIdentifier(item), now + Self.startupRegressionLimit)
    }

    /// The exact start frame was approved from a real buffer in this transport run, the same item is
    /// attached, no newer buffer exists, the request lies at most `startupRegressionFrames` before the
    /// start frame (it may be negative only for a start at 0), and the bound has not expired.
    private func startupRegressionReuse(requested: CMTime, hasNewBuffer: () -> Bool, now: CFTimeInterval?) -> Int? {
        guard let armed = startupRegression, let last = lastFrame, last == armed.frame,
              let item, ObjectIdentifier(item) == armed.item, requested.isNumeric, requested.epoch == 0 else { return nil }
        let start = CMTime(value: CMTimeValue(armed.frame), timescale: 30)
        let earliest = CMTime(value: CMTimeValue(armed.frame - Self.startupRegressionFrames), timescale: 30)
        guard requested < start, requested >= earliest, !hasNewBuffer() else { return nil }
        guard (now ?? CACurrentMediaTime()) < armed.deadline else { startupRegression = nil; return nil }
        return last
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

    func sample(hostTime: CFTimeInterval, timeline: Timeline, repeatsPreviousImage: (Int) -> Bool = { _ in false }) -> Int? {
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
        return sample(requested: requested, timeline: timeline, hasNewBuffer: output.hasNewPixelBuffer(forItemTime: requested),
                      repeatsPreviousImage: repeatsPreviousImage) { display in
            output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &display) != nil
        }
    }

    /// `repeatsPreviousImage(n)`: true only when sample-table evidence shows timeline frame n displays the
    /// same source video sample as frame n − 1 (see `VideoSampleIndex.repeats`). Defaults to never.
    func sample(requested: CMTime, timeline: Timeline, hasNewBuffer: @autoclosure () -> Bool,
                now: CFTimeInterval? = nil, repeatsPreviousImage: (Int) -> Bool = { _ in false },
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
        // Startup-only reuse, decided before the invalid/uncovered guard: a start at timeline zero
        // briefly maps display host times before 0 (FX02C-REAL-VIDEO-FLICKER-01, −57 ms), which that
        // guard would otherwise treat as invalid and use to discard the approved start frame.
        if let reused = startupRegressionReuse(requested: requested, hasNewBuffer: hasNewBuffer, now: now) {
            #if DEBUG
            traceReason = 5; traceSelected = reused; startupRegressionReusesForTest += 1
            #endif
            return reused
        }
        guard let frame = Self.frame(requested, duration: timeline.durationFrames),
              timeline.clips.contains(where: { $0.start <= frame && frame < $0.start + $0.length }) else { lastFrame = nil; return nil }
        guard hasNewBuffer() else {
            if lastFrame == frame {
                #if DEBUG
                traceReason = 2; traceSelected = frame
                #endif
                return frame
            }
            // REAL-MEDIA-FIX-01: a one-frame advance from an approved frame onto a timeline frame whose
            // displayed source sample is, per the file's own sample table, the same as the previous
            // frame's (e.g. 29.97 fps material on the 30 fps timeline). No new buffer is expected there.
            // A frame that should show a new sample still requires a new, PTS-matching buffer.
            if let last = lastFrame, frame == last + 1, repeatsPreviousImage(frame) {
                lastFrame = frame
                if let armed = startupRegression, frame > armed.frame { startupRegression = nil }
                #if DEBUG
                traceReason = 6; traceSelected = frame; repeatedImageAdvancesForTest += 1
                #endif
                return frame
            }
            #if DEBUG
            traceReason = 2; traceSelected = nil
            #endif
            return nil
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
        // Forward progress (or a rejected buffer) ends the startup allowance for good.
        if let armed = startupRegression, lastFrame.map({ $0 > armed.frame }) ?? true { startupRegression = nil }
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
    /// PCM warm-up distance (1 s); the measured cold 8 s AAC chunk decode was about 0.1 s.
    static let prefetchLeadFrames = 30
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
        if !InternalImagePreview.containsImages(timeline) { timing.armStartupRegression(frame: frame) }
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
        // REAL-MEDIA-FIX-01: keep the PCM chunk about one second ahead decoded, so the analysis
        // window never waits for a chunk decode at a boundary (warm-up only; results unchanged).
        let ahead = frame + Self.prefetchLeadFrames
        if ahead < timeline.durationFrames {
            for item in timeline.spectra where item.visible(atFrame: frame) && item.visible(atFrame: ahead) {
                session.prefetchAnalysis(spectrum: item.id, frame: ahead)
            }
        }
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
        var frame = playback.timing.sample(hostTime: hostTime, timeline: timeline,
                                           repeatsPreviousImage: { videoImageRepeats(frame: $0) })
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


/// REAL-MEDIA-FIX-01: presentation timestamps of a video file's samples, read from the file's sample
/// table (AVSampleCursor) — actual data, not a nominal frame rate.
struct VideoSampleIndex: Sendable {
    let trackStart: CMTime
    let pts: [CMTime] // sorted

    /// True when 30 fps source frame k (item time trackStart + k/30, as CompositionPlanner inserts it)
    /// shows the same sample as source frame k − 1, and a later sample exists (not past the media end).
    func repeats(sourceFrame k: Int) -> Bool {
        guard k > 0 else { return false }
        let a = trackStart + CMTime(value: CMTimeValue(k - 1), timescale: 30)
        let b = trackStart + CMTime(value: CMTimeValue(k), timescale: 30)
        guard let ia = lastIndex(atOrBefore: a), let ib = lastIndex(atOrBefore: b), ib + 1 < pts.count else { return false }
        return ia == ib
    }
    func lastIndex(atOrBefore t: CMTime) -> Int? {
        var lo = 0, hi = pts.count
        while lo < hi { let mid = (lo + hi) / 2; if pts[mid] <= t { lo = mid + 1 } else { hi = mid } }
        return lo == 0 ? nil : lo - 1
    }

    /// One track segment as AVFoundation reports it: `source` on the track's media-sample timeline,
    /// `target` on the track timeline (AVAssetTrack.segments).
    struct Segment: Sendable { let source: CMTimeRange; let target: CMTimeRange; let isEmpty: Bool }

    /// Builds the index on the track timeline from sample PTS on the media-sample timeline.
    /// Accepted (EDIT-LIST-CADENCE-FIX-01): exactly one nonempty segment that is either the identity
    /// or a 1× shift (equal, positive, numeric durations). For a shift, the earliest sample PTS must equal
    /// `source.start` exactly — this verifies that the PTS really are media-timeline values aligned with
    /// the edit (PTS already on the track timeline start at the track start instead, so an offset is never
    /// applied twice; an edit that trims leading samples is also refused) — and only samples inside the
    /// edit are kept, converted exactly by `target.start − source.start`.
    /// Everything else (several or empty edits, non-1× rate, invalid times, unaligned samples) is nil.
    static func make(rawPTS: [CMTime], trackStart: CMTime, segments: [Segment]) -> VideoSampleIndex? {
        guard segments.count == 1, let seg = segments.first, !seg.isEmpty,
              [seg.source.start, seg.source.duration, seg.target.start, seg.target.duration, trackStart].allSatisfy({ $0.isNumeric }),
              seg.source.duration > .zero, seg.source.duration == seg.target.duration else { return nil }
        let raw = rawPTS.sorted()
        guard !raw.isEmpty, raw.allSatisfy({ $0.isNumeric }) else { return nil }
        if seg.source == seg.target { return VideoSampleIndex(trackStart: trackStart, pts: raw) }
        guard raw.first == seg.source.start else { return nil }
        let shift = seg.target.start - seg.source.start, end = seg.source.end
        let pts = raw.filter { $0 >= seg.source.start && $0 < end }.map { $0 + shift }
        guard pts.first == seg.target.start else { return nil }
        return VideoSampleIndex(trackStart: trackStart, pts: pts)
    }

    /// nil when the track cannot provide sample cursors or its edit list is not supported by `make`,
    /// so no repeat is ever inferred.
    static func load(url: URL, limit: Int = 2_000_000) async -> VideoSampleIndex? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.timeRange, .segments, .canProvideSampleCursors) else { return nil }
        let (range, segments, cursors) = loaded
        guard cursors, let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        var raw: [CMTime] = []
        repeat {
            guard raw.count < limit else { return nil }
            raw.append(cursor.presentationTimeStamp)
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        return make(rawPTS: raw, trackStart: range.start,
                    segments: segments.map { Segment(source: $0.timeMapping.source, target: $0.timeMapping.target, isEmpty: $0.isEmpty) })
    }
}

/// Per-file cache of `VideoSampleIndex`, keyed by path and file identity (a relinked or changed file
/// is a different key). Loading is asynchronous; until ready, no repeat is inferred.
@MainActor
final class VideoCadenceIndex {
    static let shared = VideoCadenceIndex()
    struct Key: Hashable { let path: String; let device: Int64, inode: UInt64, size: Int64, modifiedNs: Int64 }
    private enum State { case loading, ready(VideoSampleIndex), unavailable }
    private var states: [Key: State] = [:]
    static func key(_ a: MediaAsset) -> Key {
        Key(path: a.url.standardizedFileURL.path, device: a.identity.device, inode: a.identity.inode,
            size: a.identity.size, modifiedNs: a.identity.modifiedNs)
    }
    func preload(_ assets: [MediaAsset]) {
        let live = Set(assets.filter(\.hasVideo).map(Self.key))
        for k in states.keys where !live.contains(k) { states[k] = nil }
        for a in assets where a.hasVideo {
            let k = Self.key(a), url = a.url
            guard states[k] == nil else { continue }
            states[k] = .loading
            Task.detached(priority: .utility) { [weak self] in
                let index = await VideoSampleIndex.load(url: url)
                await MainActor.run { [weak self] in
                    guard let self, case .loading? = self.states[k] else { return }
                    if let index { self.states[k] = .ready(index) } else { self.states[k] = .unavailable }
                }
            }
        }
    }
    func ready(for a: MediaAsset) -> VideoSampleIndex? {
        if case let .ready(index)? = states[Self.key(a)] { return index }
        return nil
    }
}

extension ProjectStore {
    /// True only when exactly one video clip covers frames n − 1 and n (no layer, edit or clip
    /// boundary between them) and that file's sample table shows the same sample for both.
    func videoImageRepeats(frame n: Int) -> Bool {
        // Image compositions keep their existing access-driven behavior (no inference there).
        guard n > 0, !InternalImagePreview.containsImages(timeline) else { return false }
        let touching = timeline.clips.filter { $0.start <= n && n - 1 < $0.start + $0.length }
        guard touching.count == 1, let clip = touching.first, clip.start <= n - 1, n < clip.start + clip.length,
              let asset = assets.first(where: { $0.id == clip.mediaID }), asset.hasVideo,
              let index = VideoCadenceIndex.shared.ready(for: asset) else { return false }
        return index.repeats(sourceFrame: clip.sourceIn + n - clip.start)
    }
}
