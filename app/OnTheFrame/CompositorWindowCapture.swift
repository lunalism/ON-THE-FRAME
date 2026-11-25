#if DEBUG
import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit

/// SP-EXPORT-E4D-F1-PRESENTATION-PREP-56 (DEBUG only): captures ONLY this app's own editor window while the F1 sequence plays,
/// and reads the source-frame code drawn in the readable fixtures from the captured window pixels.
///
/// Privacy boundary:
/// - Windows come from `SCShareableContent.currentProcess` (macOS 14.4+), which the SDK documents as content "available to capture by
///   current process without user consent via TCC". This component never calls `SCShareableContent.current`, never calls
///   `CGRequestScreenCaptureAccess`, and never captures other apps, the desktop or audio. If the own window is not offered, it fails (NOT RUN).
/// - `CGPreflightScreenCaptureAccess()` is recorded as evidence only (it never prompts).
/// - Pixels are read inside the sample callback and released at once; no image, screenshot or recording is stored. Only numbers are kept,
///   at most `maxSamples` entries.
///
/// What this is evidence of: frames the window server composited for this window (SCStreamFrameInfo.displayTime = "when the frame was displayed
/// by the window server"). It is NOT evidence of physical display presentation. A 60 fps request does not guarantee every composited frame
/// is delivered; idle samples mean the window did not change.
final class CompositorWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// One delivered sample. Times are seconds on the mach host clock (same base as CACurrentMediaTime()).
    struct Sample: Codable, Sendable {
        let seq: Int
        let status: String           // complete, idle, blank, suspended, started, stopped, unknown(n)
        let displayTime: Double?     // SCStreamFrameInfo.displayTime (mach absolute time) in seconds
        let arrival: Double          // CACurrentMediaTime() when the callback ran
        let width: Int, height: Int  // pixel buffer size (0 when the sample carries no image)
        let pixelUsable: Bool        // READINESS-FIX-58: a lockable 32BGRA buffer with a base address and nonzero size
        let geometryState: String    // READINESS-FIX-58: "ok", "not-read" (not a usable complete sample) or "unreadable-geometry: <reason>"
        let sourceID: Int?, sourceFrame: Int?
        let minMargin: Int?          // smallest |cell luma − 128| over the 24 code cells (read confidence)
        let confident: Bool          // geometry "ok", known fixture ID and minMargin >= 40
        let scaleFactor: Double?, contentScale: Double?
        let contentRect: String?
    }
    /// READINESS-FIX-58: the outcome of `waitReady`. Readiness means the stream delivered at least one `.complete` sample with a usable
    /// pixel buffer and then stayed free of errors and terminal statuses for the stability interval. It says nothing about frame identity.
    struct Readiness: Codable, Sendable {
        let ready: Bool
        let reason: String
        let requestedAt: Double              // CACurrentMediaTime() when waitReady began
        let firstValidCompleteAt: Double?    // arrival of the first .complete sample with a usable pixel buffer
        let readyAt: Double?
        let statusCounts: [String: Int]      // all samples received until the decision
        let usablePixelSamples: Int
        let readableSamples: Int             // confident source-frame reads (evidence only; not required for readiness)
        let geometryStates: [String: Int]
        let error: String?
        let terminalStatus: String?
    }
    /// Geometry captured on the main actor before the stream starts (window points, top-left origin).
    struct Geometry: Codable, Sendable {
        let windowID: UInt32
        let windowSize: CGSize       // points
        let videoRect: CGRect        // the AVPlayerLayer video rect in window points, top-left origin
        let backingScale: Double
    }
    static let knownSourceIDs: Set<Int> = [0x33, 0xCC, 0x2D]   // otf-TA, otf-TB, otf-A (the F1 clips)
    static let maxSamples = 1500

    let geometry: Geometry
    /// The window the stream was built on (id, owning pid, title), recorded as evidence.
    let selectedWindow: String
    private let queue = DispatchQueue(label: "dev.ontheframe.f1capture")
    private let lock = NSLock()
    // Guarded by `lock` (written on `queue`, read on the main actor):
    private var samples: [Sample] = []
    private var overflow = 0, seq = 0
    private var stopError: String?
    private var firstValidComplete: Double?   // arrival of the first .complete sample with a usable pixel buffer
    private var terminalStatus: String?       // .stopped at any time, or .suspended after the first valid complete sample
    // Main actor only:
    private var stream: SCStream?

    private init(geometry: Geometry, selectedWindow: String) { self.geometry = geometry; self.selectedWindow = selectedWindow }

    /// Evidence only. Never prompts.
    static func screenRecordingPreflight() -> Bool { CGPreflightScreenCaptureAccess() }

    /// The video rect of the Preview inside the window (points, top-left origin).
    @MainActor static func geometry(window: NSWindow, view: PlayerNSView) -> Geometry {
        let layerRect = view.playerLayer.videoRect                       // playerLayer.frame == view.bounds (PlayerNSView.layout)
        let inWindow = view.convert(layerRect, to: nil)                  // window base coordinates, bottom-left origin
        let size = window.frame.size
        let topLeft = CGRect(x: inWindow.minX, y: size.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
        return Geometry(windowID: UInt32(window.windowNumber), windowSize: size, videoRect: topLeft, backingScale: Double(window.backingScaleFactor))
    }

    /// Starts a single-window stream on this process's own window. Throws if the window is not offered by `currentProcess`.
    @MainActor static func start(window: NSWindow, view: PlayerNSView) async throws -> CompositorWindowCapture {
        let g = geometry(window: window, view: view)
        guard g.videoRect.width > 100, g.videoRect.height > 50 else { throw CaptureError.geometry("video rect \(g.videoRect)") }
        let content = try await SCShareableContent.currentProcess
        let own = getpid()
        guard let target = content.windows.first(where: { $0.windowID == g.windowID }) else {
            throw CaptureError.windowNotOffered("window \(g.windowID) not in currentProcess content (\(content.windows.count) windows)")
        }
        if let pid = target.owningApplication?.processID, pid != own { throw CaptureError.windowNotOffered("window owned by pid \(pid), not \(own)") }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.width = Int((g.windowSize.width * g.backingScale).rounded())
        config.height = Int((g.windowSize.height * g.backingScale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = false
        config.ignoreShadowsSingleWindow = true
        let selected = "windowID \(target.windowID); pid \(target.owningApplication?.processID ?? -1) (own \(own)); title \(target.title ?? "nil"); frame \(target.frame)"
        let capture = CompositorWindowCapture(geometry: g, selectedWindow: selected)
        let stream = SCStream(filter: filter, configuration: config, delegate: capture)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
        capture.stream = stream
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        return capture
    }

    /// READINESS-FIX-58 (replaces the old "any 10 samples" rule, which counted idle and status-only samples).
    /// Ready when (1) a `.complete` sample with a usable pixel buffer has arrived and (2) `stability` seconds have passed since it
    /// without a stream error, a `.stopped` status, a `.suspended` status or a stop. No further callbacks are required during the
    /// stability interval: a static window may legitimately deliver only idle samples, or nothing, after its first complete frame.
    /// Readable source-frame codes are NOT required (the first frame may be black or an empty Preview). Bounded by `timeout` in total;
    /// a stability interval that would end after the timeout is a failure.
    @MainActor func waitReady(stability: TimeInterval = 0.3, timeout: TimeInterval = 3) async -> Readiness {
        let t0 = CACurrentMediaTime(), deadline = t0 + timeout
        var reason = String(format: "timeout: no .complete sample with a usable pixel buffer within %.1f s", timeout)
        var readyAt: Double?
        while true {
            let now = CACurrentMediaTime()
            let (first, err, terminal) = lock.withLock { (firstValidComplete, stopError, terminalStatus) }
            if stream == nil { reason = "stream stopped before readiness"; break }
            if let err { reason = "capture error: \(err)"; break }
            if let terminal { reason = "terminal status: \(terminal)"; break }
            if let first, now - first >= stability { readyAt = now; reason = "ready"; break }
            if now >= deadline {
                if let first { reason = String(format: "timeout during the %.1f s stability interval (first valid complete at +%.0f ms)", stability, (first - t0) * 1000) }
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let (snap, err, terminal, first) = lock.withLock { (samples, stopError, terminalStatus, firstValidComplete) }
        return Readiness(ready: readyAt != nil, reason: reason, requestedAt: t0, firstValidCompleteAt: first, readyAt: readyAt,
                         statusCounts: Dictionary(grouping: snap, by: \.status).mapValues(\.count),
                         usablePixelSamples: snap.filter(\.pixelUsable).count, readableSamples: snap.filter(\.confident).count,
                         geometryStates: Dictionary(grouping: snap, by: { $0.geometryState.hasPrefix("unreadable-geometry") ? "unreadable-geometry" : $0.geometryState }).mapValues(\.count),
                         error: err, terminalStatus: terminal)
    }

    /// Stops and detaches the stream (idempotent). Errors are recorded, not thrown.
    @MainActor func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                stream.stopCapture { error in if let error { c.resume(throwing: error) } else { c.resume() } }
            }
        } catch { lock.withLock { stopError = stopError ?? "stopCapture: \(error)" } }
        try? stream.removeStreamOutput(self, type: .screen)
    }

    func snapshot() -> (samples: [Sample], overflow: Int, error: String?) { lock.withLock { (samples, overflow, stopError) } }

    // MARK: SCStreamDelegate / SCStreamOutput (called on `queue`)

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { stopError = "didStopWithError: \(error)" }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let arrival = CACurrentMediaTime()
        let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
        let raw = info[.status] as? Int
        let status: String
        switch raw.flatMap(SCFrameStatus.init(rawValue:)) {
        case .complete: status = "complete"
        case .idle: status = "idle"
        case .blank: status = "blank"
        case .suspended: status = "suspended"
        case .started: status = "started"
        case .stopped: status = "stopped"
        default: status = "unknown(\(raw.map(String.init) ?? "nil"))"
        }
        let display = (info[.displayTime] as? UInt64).map(Self.seconds(machTicks:))
        let rect = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        let scaleFactor = (info[.scaleFactor] as? NSNumber)?.doubleValue, contentScale = (info[.contentScale] as? NSNumber)?.doubleValue
        var w = 0, h = 0, usable = false, geometryState = "not-read", id: Int?, frame: Int?, margin: Int?
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {   // read now, keep nothing
            w = CVPixelBufferGetWidth(pb); h = CVPixelBufferGetHeight(pb)
            if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA, w > 0, h > 0,
               CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess {
                defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
                    usable = true
                    // Only .complete samples carry a new image; idle/blank/status samples are never decoded.
                    if status == "complete" {
                        switch pixelMap(width: w, height: h, contentRect: rect, contentScale: contentScale, scaleFactor: scaleFactor) {
                        case .failure(let why): geometryState = "unreadable-geometry: \(why.text)"
                        case .success(let map):
                            geometryState = "ok"
                            if let r = read(base: base, width: w, height: h, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), map: map) { id = r.id; frame = r.frame; margin = r.margin }
                        }
                    }
                }
            }
        }
        let confident = geometryState == "ok" && id.map(Self.knownSourceIDs.contains) == true && (margin ?? 0) >= 40
        lock.withLock {
            seq += 1
            if status == "complete", usable, firstValidComplete == nil { firstValidComplete = arrival }
            if status == "stopped" { terminalStatus = terminalStatus ?? "stopped (seq \(seq))" }
            if status == "suspended", firstValidComplete != nil { terminalStatus = terminalStatus ?? "suspended after first valid complete (seq \(seq))" }
            guard samples.count < Self.maxSamples else { overflow += 1; return }
            samples.append(Sample(seq: seq, status: status, displayTime: display, arrival: arrival, width: w, height: h, pixelUsable: usable,
                                  geometryState: geometryState, sourceID: id, sourceFrame: frame, minMargin: margin, confident: confident,
                                  scaleFactor: scaleFactor, contentScale: contentScale, contentRect: rect.map { "\($0)" }))
        }
    }

    /// Window point → buffer pixel map for one sample: pixel = origin + point × perPoint.
    struct PixelMap { let originX: Double, originY: Double, perPointX: Double, perPointY: Double }
    struct GeometryFailure: Error { let text: String }

    /// READINESS-FIX-58: derives the map from the sample's own SCStreamFrameInfo instead of assuming that the window fills the buffer.
    /// Contract used: `contentRect` is the window content's rectangle in the buffer in points (top-left origin), and points × `scaleFactor`
    /// = buffer pixels. A nontrivial `contentScale` or horizontal offset is accepted only when it is cross-checked: the pixels per window point
    /// derived from contentRect must equal backingScale × contentScale (within 1 %) in both axes, and the content must lie inside the buffer.
    /// A vertical offset is refused (whether the origin is top or bottom is not verified on this Mac), as are missing attachments and code
    /// cells smaller than 8 px. Refused samples never produce a source identity.
    private func pixelMap(width w: Int, height h: Int, contentRect: CGRect?, contentScale: Double?, scaleFactor: Double?) -> Result<PixelMap, GeometryFailure> {
        func fail(_ s: String) -> Result<PixelMap, GeometryFailure> { .failure(GeometryFailure(text: s)) }
        guard let r = contentRect, let cs = contentScale, let sf = scaleFactor else { return fail("missing contentRect/contentScale/scaleFactor") }
        guard r.width > 0, r.height > 0, r.minX.isFinite, r.minY.isFinite, cs.isFinite, cs > 0, sf.isFinite, sf > 0 else { return fail("invalid attachment values") }
        let px = CGRect(x: r.minX * sf, y: r.minY * sf, width: r.width * sf, height: r.height * sf)
        guard abs(px.minY) <= 0.5 else { return fail(String(format: "vertical content offset %.1f px (origin convention unverified)", px.minY)) }
        guard px.minX >= -0.5, px.maxX <= Double(w) + 1, px.maxY <= Double(h) + 1 else { return fail("content \(px) outside buffer \(w)x\(h)") }
        let ppx = px.width / geometry.windowSize.width, ppy = px.height / geometry.windowSize.height
        let expected = geometry.backingScale * cs
        guard abs(ppx - expected) <= 0.01 * expected, abs(ppy - expected) <= 0.01 * expected else {
            return fail(String(format: "pixels per point %.4f×%.4f, expected backingScale %.2f × contentScale %.4f = %.4f", ppx, ppy, geometry.backingScale, cs, expected))
        }
        let v = geometry.videoRect
        guard v.minX >= 0, v.minY >= 0, v.maxX <= geometry.windowSize.width + 0.5, v.maxY <= geometry.windowSize.height + 0.5 else { return fail("video rect \(v) outside window") }
        let cell = 48.0 * v.width / 1920.0 * ppx
        guard cell >= 8 else { return fail(String(format: "code cell %.1f px < 8 px", cell)) }
        return .success(PixelMap(originX: px.minX, originY: px.minY, perPointX: ppx, perPointY: ppy))
    }

    /// Reads the source ID (8 bits, source y 100) and source frame (16 bits, source y 170) from the 48 px code cells
    /// (E2 FHD layout: left 40, pitch 56) of the 1920×1080 source as shown inside `geometry.videoRect`. The buffer is locked by the caller.
    private func read(base: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int, bytesPerRow bpr: Int, map: PixelMap) -> (id: Int, frame: Int, margin: Int)? {
        let v = geometry.videoRect
        let cell = 48.0 * v.width / 1920.0 * map.perPointX           // code cell size in buffer pixels
        let half = max(1, Int(cell * 0.2))
        var margin = Int.max
        func bit(_ srcX: Double, _ srcY: Double) -> Int? {
            let cx = Int((map.originX + (v.minX + srcX * v.width / 1920.0) * map.perPointX).rounded())
            let cy = Int((map.originY + (v.minY + srcY * v.height / 1080.0) * map.perPointY).rounded())
            guard cx - half >= 0, cy - half >= 0, cx + half < w, cy + half < h else { return nil }
            var sum = 0, n = 0
            for y in (cy - half)...(cy + half) { for x in (cx - half)...(cx + half) {
                let p = base + y * bpr + x * 4
                sum += (Int(p[2]) * 299 + Int(p[1]) * 587 + Int(p[0]) * 114) / 1000; n += 1
            } }
            let mean = sum / max(1, n)
            margin = min(margin, abs(mean - 128))
            return mean > 128 ? 1 : 0
        }
        func code(_ rowY: Double, _ bits: Int) -> Int? {
            var value = 0
            for b in 0..<bits { guard let x = bit(40 + Double(b) * 56 + 24, rowY + 24) else { return nil }; value = (value << 1) | x }
            return value
        }
        guard let id = code(100, 8), let frame = code(170, 16) else { return nil }
        return (id, frame, margin == Int.max ? 0 : margin)
    }

    static func seconds(machTicks t: UInt64) -> Double {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(t) * Double(tb.numer) / Double(tb.denom) / 1e9
    }

    enum CaptureError: Error, CustomStringConvertible {
        case geometry(String), windowNotOffered(String)
        var description: String { switch self { case .geometry(let s): "geometry: \(s)"; case .windowNotOffered(let s): "window not offered: \(s)" } }
    }
}
#endif
