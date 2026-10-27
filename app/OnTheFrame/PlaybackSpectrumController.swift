import AVFoundation
import OnTheFrameEngine

/// Output timing is a proxy for media available for display, not AVPlayerLayer scan-out proof.
/// No display link is installed in 3C-1. The eventual driver supplies target host timestamps.
@MainActor
final class SpectrumPlaybackTiming {
    private(set) weak var item: AVPlayerItem?
    private(set) var output: AVPlayerItemVideoOutput?
    private var lastFrame: Int?

    func attach(_ item: AVPlayerItem) {
        guard self.item !== item else { return }
        detach()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        self.item = item; self.output = output
    }
    func detach() {
        if let item, let output { item.remove(output) }
        item = nil; output = nil; lastFrame = nil
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
    func sample(hostTime: CFTimeInterval, timeline: Timeline) -> Int? {
        guard hostTime.isFinite, let output, item != nil else { return nil }
        let requested = output.itemTime(forHostTime: hostTime)
        guard let frame = Self.frame(requested, duration: timeline.durationFrames),
              timeline.clips.contains(where: { $0.start <= frame && frame < $0.start + $0.length }) else { lastFrame = nil; return nil }
        guard output.hasNewPixelBuffer(forItemTime: requested) else { return lastFrame == frame ? frame : nil }
        var display = CMTime.invalid
        // Acquire only to obtain its media timestamp. No readback, image copy, or retained pixel buffer.
        guard output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &display) != nil else { lastFrame = nil; return nil }
        lastFrame = Self.select(requested: requested, display: display, timeline: timeline)
        return lastFrame
    }
}

/// Bounded nonpresenting consumer of the same coordinator as the paused overlay.
/// Cancelled tickets occupy slots until terminal delivery, bounding queued cancellation storms too.
@MainActor
final class PlaybackSpectrumController {
    struct Key: Hashable { let spectrum: UUID; let frame: Int }
    struct Pending { let ticket: SpectrumFrameTicket; let serial: Int; let start: Double; var cancelled = false }
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
    }
    static let pendingLimit = 8, retainedLimit = 8, byteLimit = 16 * 1024 * 1024, lookahead = 2
    private weak var session: SpectrumPreviewSession?
    let timing = SpectrumPlaybackTiming()
    private(set) var currentFrame: Int?
    private var serial = 0
    private var epoch = -1, revision = -1
    private var desired: [Key] = []
    private var completed: [Key: CompletionState] = [:]
    private var recoveryAttempted: Set<Key> = [] // at most one recovery per key during one current-frame activation
    private var pending: [Key: Pending] = [:]
    private var retained: [Key: Stored] = [:]
    private(set) var retainedBytes = 0
    private(set) var metrics = Metrics()
    var pendingCount: Int { pending.count }
    var retainedCount: Int { retained.count }
    init(session: SpectrumPreviewSession) { self.session = session }

    func stop(detachTiming: Bool = true) {
        serial &+= 1; currentFrame = nil; desired.removeAll(keepingCapacity: true)
        completed.removeAll(keepingCapacity: true); recoveryAttempted.removeAll(keepingCapacity: true)
        retained.removeAll(keepingCapacity: true); retainedBytes = 0
        cancelObsolete()
        if detachTiming { timing.detach() }
    }
    private func cancelObsolete() {
        for key in pending.keys {
            guard var p = pending[key], !p.cancelled, !desired.contains(key) else { continue }
            p.cancelled = true; pending[key] = p; metrics.cancelled += 1
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
        if epoch != session.epoch || revision != session.revision {
            stop(detachTiming: false); epoch = session.epoch; revision = session.revision
        }
        guard let frame, frame >= 0, frame < timeline.durationFrames else {
            if currentFrame != nil { stop(detachTiming: false) }
            return
        }
        guard currentFrame != frame else { metrics.reused += 1; return }
        if retained.keys.contains(where: { $0.frame == frame }) { metrics.prefetchedCurrentHits += 1 }
        currentFrame = frame
        desired.removeAll(keepingCapacity: true)
        // Current items precede all future items. More than 8 simultaneous items are explicitly capped.
        for offset in 0...Self.lookahead {
            let next = frame + offset
            guard next < timeline.durationFrames else { break }
            for item in timeline.spectra where item.visible(atFrame: next) {
                if desired.count == Self.pendingLimit { break }
                desired.append(Key(spectrum: item.id, frame: next))
            }
        }
        completed = completed.filter { desired.contains($0.key) }
        recoveryAttempted.removeAll(keepingCapacity: true)
        for key in retained.keys where !desired.contains(key) {
            retainedBytes -= retained.removeValue(forKey: key)?.bytes ?? 0
        }
        cancelObsolete(); pump()
    }
    private func pump() {
        guard let session, currentFrame != nil, epoch == session.epoch, revision == session.revision else { return }
        for key in desired {
            guard pending.count < Self.pendingLimit else { break }
            guard pending[key] == nil else { continue }
            if let state = completed[key] {
                guard state == .needsCurrentImage, key.frame == currentFrame,
                      !recoveryAttempted.contains(key) else { continue }
                recoveryAttempted.insert(key); metrics.recoveryRequests += 1
            }
            let requestSerial = serial, start = ProcessInfo.processInfo.systemUptime
            let ticket = session.request(spectrum: key.spectrum, frame: key.frame,
                                         priority: key.frame == currentFrame ? 0 : 1) { [weak self] outcome in
                self?.finish(key, serial: requestSerial, outcome: outcome)
            }
            pending[key] = Pending(ticket: ticket, serial: requestSerial, start: start)
            metrics.requested += 1; metrics.peakPending = max(metrics.peakPending, pending.count)
        }
    }
    private func finish(_ key: Key, serial requestSerial: Int, outcome: SpectrumFrameOutcome) {
        guard let p = pending[key], p.serial == requestSerial else { metrics.stale += 1; return }
        pending[key] = nil
        guard let session, !p.cancelled, serial == requestSerial, epoch == session.epoch,
              revision == session.revision, desired.contains(key), currentFrame != nil else {
            metrics.stale += 1; pump(); return
        }
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
        pump()
    }
    /// A future result may be retained, but can only be retrieved once that exact frame is current.
    func currentOutcome(spectrum: UUID, frame: Int) -> SpectrumFrameOutcome? {
        guard frame == currentFrame, let session, epoch == session.epoch, revision == session.revision else { return nil }
        let key = Key(spectrum: spectrum, frame: frame)
        if completed[key] == .budgetFailure {
            return .failed(.render(.invalidCanvas("playback retained-image budget unavailable (16 MiB / 8 results)")))
        }
        return retained[key]?.outcome
    }
}

extension ProjectStore {
    /// 3C-2 entry point. Not called by a timer/display link or the periodic playhead observer in 3C-1.
    /// No CALayer assignment occurs here or in the controller.
    func sampleSpectrumPlayback(hostTime: CFTimeInterval) {
        let playback = spectrumPreview.playback
        guard isPlaying, player.rate != 0, let view = previewHost, view.window != nil,
              gestureBase == nil, !view.isShowingStill, appliedGeneration == generation,
              !view.hasPendingSpectrumSeek, let item = player.currentItem else {
            playback.stop(); return
        }
        playback.timing.attach(item)
        let frame = playback.timing.sample(hostTime: hostTime, timeline: timeline)
        playback.advance(frame: frame, timeline: timeline)
    }
}
