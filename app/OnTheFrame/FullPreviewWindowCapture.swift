#if DEBUG
import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit

/// SP-EXPORT-E4D-G1 (DEBUG only): own-window capture for the full Preview parity. A separate class so the F1 diagnostic
/// (`CompositorWindowCapture`) stays unchanged (owner decision 3). Same privacy boundary as the F1 capture:
/// - windows come only from `SCShareableContent.currentProcess`; the window ID must be this process's editor window and its owning
///   PID must be this process
/// - never calls `SCShareableContent.current`, `CGRequestScreenCaptureAccess` or any permission API; no audio, no cursor, no
///   desktop or other application content (`desktopIndependentWindow` filter of the one window)
/// - pixels stay in memory; only while a grab is armed is the video rectangle copied, and only the stable crop is returned
/// Differences from the F1 capture: the stream asks for sRGB (`colorSpaceName`); a grab ends when the pixel fingerprint of the
/// Preview ROI is stable (`PreviewStability`). Stability never checks the source frame: identity is a separate judgment.
/// SP-EXPORT-E4D-G4-STALE-CAPTURE-FIX-79: a grab is armed with a freshness fence (mach ticks, taken after the current seek is
/// confirmed complete) and a generation. Complete samples displayed at or before the fence, with no display time, or out of order
/// are refused at receipt before any pixel work; a processed sample is committed only into the grab whose generation it was
/// received under. For frame-coded fixtures a stable fresh run is accepted only if its frame code is the requested one; a fresh
/// stable run with another code is recorded and, at the timeout, returned so the separate identity judgment can FAIL it.
final class FullPreviewWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Geometry: Codable, Sendable {
        let windowID: UInt32
        let windowSize: CGSize       // points
        let videoRect: CGRect        // points, top-left origin, in window coordinates
        let backingScale: Double
        let displayProfile: String
    }
    struct Readiness: Codable, Sendable { let ready: Bool; let reason: String; let completeSamples: Int; let otherSamples: Int }
    struct GrabResult: Sendable { let crop: PreviewCrop?; let note: String; let samples: [StabilitySample]; let diagnostics: GrabDiagnostics? }
    enum CaptureError: Error, CustomStringConvertible {
        case geometry(String), windowNotOffered(String)
        var description: String { switch self { case .geometry(let s): "geometry: \(s)"; case .windowNotOffered(let s): "window not offered: \(s)" } }
    }

    let geometry: Geometry
    let selectedWindow: String
    private let queue = DispatchQueue(label: "dev.ontheframe.fullparity.capture")
    private let lock = NSLock()
    // Guarded by `lock`:
    private var firstComplete: Double?, terminal: String?, streamError: String?
    private var completeCount = 0, otherCount = 0, seq = 0, generations = 0
    private var armed: Armed?
    // Main actor only:
    private var stream: SCStream?

    private struct Armed {
        var grab: FreshGrab
        let expect: ExpectedPreviewCode?
        var acceptedCrop: PreviewCrop?   // crop of the sample that completed the accepted fresh stable run
        var lastWrongCrop: PreviewCrop?  // crop of the latest fresh stable run with another frame code
    }

    private init(geometry: Geometry, selected: String) { self.geometry = geometry; self.selectedWindow = selected }

    @MainActor static func geometry(window: NSWindow, view: PlayerNSView) -> Geometry {
        let inWindow = view.convert(view.playerLayer.videoRect, to: nil)
        let size = window.frame.size
        let rect = CGRect(x: inWindow.minX, y: size.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
        let profile = window.screen?.colorSpace?.localizedName ?? window.colorSpace?.localizedName ?? "unknown"
        return Geometry(windowID: UInt32(window.windowNumber), windowSize: size, videoRect: rect, backingScale: Double(window.backingScaleFactor), displayProfile: profile)
    }

    @MainActor static func start(window: NSWindow, view: PlayerNSView) async throws -> FullPreviewWindowCapture {
        let g = geometry(window: window, view: view)
        guard g.videoRect.width > 100, g.videoRect.height > 50 else { throw CaptureError.geometry("video rect \(g.videoRect)") }
        let content = try await SCShareableContent.currentProcess
        let own = getpid()
        guard let target = content.windows.first(where: { $0.windowID == g.windowID }) else {
            throw CaptureError.windowNotOffered("window \(g.windowID) not in currentProcess content (\(content.windows.count) windows)")
        }
        guard let pid = target.owningApplication?.processID, pid == own else {
            throw CaptureError.windowNotOffered("window owner pid \(target.owningApplication.map { "\($0.processID)" } ?? "unknown"), not \(own)")
        }
        let config = SCStreamConfiguration()
        config.width = Int((g.windowSize.width * g.backingScale).rounded())
        config.height = Int((g.windowSize.height * g.backingScale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 5
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = false
        config.ignoreShadowsSingleWindow = true
        let selected = "windowID \(target.windowID); pid \(pid) (own \(own)); frame \(target.frame)"
        let capture = FullPreviewWindowCapture(geometry: g, selected: selected)
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: capture)
        try s.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
        capture.stream = s
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                s.startCapture { error in if let error { c.resume(throwing: error) } else { c.resume() } }
            }
        } catch {
            await capture.stop()   // release the stream and the output on a failed start
            throw error
        }
        return capture
    }

    /// Readiness (unchanged rule): one complete sample with a usable buffer, then 0.3 s without an error or a terminal status,
    /// within 3 s. Readable source codes are not required.
    @MainActor func waitReady() async -> Readiness {
        let t0 = CACurrentMediaTime()
        while true {
            let now = CACurrentMediaTime()
            let (first, err, term, nc, no) = lock.withLock { (firstComplete, streamError, terminal, completeCount, otherCount) }
            if stream == nil { return Readiness(ready: false, reason: "stream stopped", completeSamples: nc, otherSamples: no) }
            if let err { return Readiness(ready: false, reason: "capture error: \(err)", completeSamples: nc, otherSamples: no) }
            if let term { return Readiness(ready: false, reason: "terminal status: \(term)", completeSamples: nc, otherSamples: no) }
            if let first, now - first >= 0.3 { return Readiness(ready: true, reason: "ready", completeSamples: nc, otherSamples: no) }
            if now - t0 >= 3 { return Readiness(ready: false, reason: "timeout", completeSamples: nc, otherSamples: no) }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Arms a grab of a new generation with the freshness fence `fenceTicks` (mach absolute time) and waits, bounded by the v1 timeout
    /// of 10 s, until a fresh stable run is accepted (v1 rule over fresh samples only; with `expect`, also the requested frame code).
    /// At the timeout, the latest fresh stable run with a wrong code is returned (identity is judged, and fails, separately);
    /// otherwise no crop. Error, terminal status or a stopped stream: no crop. Returns the logged samples and diagnostics.
    @MainActor func grab(fenceTicks: UInt64, expect: ExpectedPreviewCode?) async -> GrabResult {
        lock.withLock {
            generations += 1
            armed = Armed(grab: FreshGrab(generation: generations, fenceTicks: fenceTicks, identityRequired: expect != nil), expect: expect)
        }
        let t0 = CACurrentMediaTime()
        var stopNote: String?, stopOutcome = ""
        var crop: PreviewCrop?
        while CACurrentMediaTime() - t0 < ParityThresholdsV1.stableTimeoutSeconds {
            let (accepted, err, term) = lock.withLock { (armed?.acceptedCrop, streamError, terminal) }
            if let err { stopNote = "capture error: \(err)"; stopOutcome = "captureError"; break }
            if let term { stopNote = "terminal status: \(term)"; stopOutcome = "terminal"; break }
            if stream == nil { stopNote = "stream stopped"; stopOutcome = "streamStopped"; break }
            if let accepted { crop = accepted; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let final = lock.withLock { () -> Armed? in let a = armed; armed = nil; return a }
        guard let a = final else { return GrabResult(crop: nil, note: "grab state missing", samples: [], diagnostics: nil) }
        let g = a.grab, fresh = "fresh samples displayed after the boundary"
        let counts = g.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let identityText = a.expect == nil ? "identity not required (uncoded)" : "frame code matched"
        if let crop {
            return GrabResult(crop: crop, note: "stable: \(g.stability.run.count) identical \(fresh); \(identityText); generation \(g.generation) [\(counts)]",
                              samples: g.log, diagnostics: g.diagnostics(outcome: "accepted"))
        }
        if let stopNote {
            return GrabResult(crop: nil, note: stopNote, samples: g.log, diagnostics: g.diagnostics(outcome: stopOutcome))
        }
        let outcome = g.timeoutOutcome, timeout = "timeout after \(ParityThresholdsV1.stableTimeoutSeconds) s"
        switch outcome {
        case "wrongIdentityAtTimeout":
            return GrabResult(crop: a.lastWrongCrop, note: "\(timeout): fresh stable capture with a different frame code (\(g.wrongIdentityCount) stable runs); returned for the identity judgment; generation \(g.generation) [\(counts)]",
                              samples: g.log, diagnostics: g.diagnostics(outcome: outcome))
        case "noFreshCapture":
            return GrabResult(crop: nil, note: "\(timeout) without a fresh capture (no complete sample displayed after the boundary); generation \(g.generation) [\(counts)]",
                              samples: g.log, diagnostics: g.diagnostics(outcome: outcome))
        default:
            return GrabResult(crop: nil, note: "\(timeout) without a stable fingerprint over \(fresh); generation \(g.generation) [\(counts)]",
                              samples: g.log, diagnostics: g.diagnostics(outcome: outcome))
        }
    }

    /// Stops and detaches the stream (idempotent); releases any armed grab state.
    @MainActor func stop() async {
        lock.withLock { armed = nil }
        guard let s = stream else { return }
        stream = nil
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                s.stopCapture { error in if let error { c.resume(throwing: error) } else { c.resume() } }
            }
        } catch { lock.withLock { streamError = streamError ?? "stopCapture: \(error)" } }
        try? s.removeStreamOutput(self, type: .screen)
    }

    // MARK: stream callbacks (on `queue`)

    func stream(_ stream: SCStream, didStopWithError error: Error) { lock.withLock { streamError = "didStopWithError: \(error)" } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let arrival = CACurrentMediaTime()
        let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
        let status = (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        let ticks = info[.displayTime] as? UInt64
        let display = ticks.map(Self.seconds(machTicks:))
        // Receipt: counters, the generation of the grab armed NOW, and (complete samples) freshness admission before pixel work.
        // A refused or non-complete sample is committed immediately, under the same lock, into that same grab.
        enum Receipt { case notArmed, done, process(generation: Int, expect: ExpectedPreviewCode?) }
        let (n, receipt) = lock.withLock { () -> (Int, Receipt) in
            seq += 1
            if status == .complete { completeCount += 1; if firstComplete == nil { firstComplete = arrival } } else { otherCount += 1 }
            if status == .stopped { terminal = terminal ?? "stopped" }
            if status == .suspended, firstComplete != nil { terminal = terminal ?? "suspended" }
            guard var a = armed else { return (seq, .notArmed) }
            let g = a.grab.generation
            func record(_ text: String) -> (Int, Receipt) {
                let sample = StabilitySample(seq: seq, arrival: arrival, displayTime: display, status: text, roi: nil, fingerprint: nil, generation: g, displayTicks: ticks)
                _ = a.grab.commit(sample, receiptGeneration: g, identityMatches: nil); armed = a
                return (seq, .done)
            }
            switch status {
            case .complete: break
            case .idle: return record("idle")
            case .blank: return record("blank")
            case .suspended: return record("suspended")
            case .stopped: return record("stopped")
            default: return record("other")
            }
            let admission = a.grab.admit(displayTicks: ticks)
            armed = a
            guard admission == .fresh else { return record(admission.rawValue) }
            return (seq, .process(generation: g, expect: a.expect))
        }
        guard case .process(let generation, let expect) = receipt else { return }
        // Pixel work outside the lock; the sample buffer is only read inside this callback (copied into the crop).
        var sample = StabilitySample(seq: n, arrival: arrival, displayTime: display, status: "complete", roi: nil, fingerprint: nil, generation: generation, displayTicks: ticks)
        var crop: PreviewCrop?, matches: Bool?
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer), CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA {
            let rect = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            let sf = (info[.scaleFactor] as? NSNumber)?.doubleValue, cs = (info[.contentScale] as? NSNumber)?.doubleValue
            switch videoRectInBuffer(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), contentRect: rect, contentScale: cs, scaleFactor: sf) {
            case .failure:
                sample = StabilitySample(seq: n, arrival: arrival, displayTime: display, status: "unreadable-geometry", roi: nil, fingerprint: nil, generation: generation, displayTicks: ticks)
            case .success(let v):
                if let copied = copyCrop(pb, video: v) {
                    crop = copied.crop
                    sample = StabilitySample(seq: n, arrival: arrival, displayTime: display, status: "complete", roi: copied.roi, fingerprint: copied.fingerprint, generation: generation, displayTicks: ticks)
                    if let expect {
                        let r = ParityCode.read(placed: expect.placed, luma: ParityCode.cropSampler(copied.crop))
                        sample.identity = ExpectedPreviewCode.describe(r); matches = expect.matches(r)
                    }
                } else {
                    sample = StabilitySample(seq: n, arrival: arrival, displayTime: display, status: "unusable-buffer", roi: nil, fingerprint: nil, generation: generation, displayTicks: ticks)
                }
            }
        } else {
            sample = StabilitySample(seq: n, arrival: arrival, displayTime: display, status: "unusable-buffer", roi: nil, fingerprint: nil, generation: generation, displayTicks: ticks)
        }
        sample.processingMs = (CACurrentMediaTime() - arrival) * 1000
        // Commit: only into the grab of the receipt generation (a later grab rejects and counts it; no grab → dropped).
        lock.withLock {
            guard var a = armed else { return }
            let step = a.grab.commit(sample, receiptGeneration: generation, identityMatches: matches)
            switch step {
            case .accepted where a.grab.acceptedSeq == n: a.acceptedCrop = crop
            case .wrongIdentityStable: a.lastWrongCrop = crop
            default: break
            }
            armed = a
        }
    }

    static func seconds(machTicks t: UInt64) -> Double {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(t) * Double(tb.numer) / Double(tb.denom) / 1e9
    }

    struct GeometryProblem: Error { let text: String }
    /// Video rectangle in buffer pixels, cross-checked against the frame info (same contract as the F1 capture's pixel map):
    /// contentRect × scaleFactor is the window in the buffer; pixels per point must equal backingScale × contentScale within 1 %;
    /// a vertical content offset is refused.
    private func videoRectInBuffer(width w: Int, height h: Int, contentRect: CGRect?, contentScale: Double?, scaleFactor: Double?) -> Result<CGRect, GeometryProblem> {
        guard let r = contentRect, let cs = contentScale, let sf = scaleFactor, r.width > 0, r.height > 0, cs > 0, sf > 0 else {
            return .failure(GeometryProblem(text: "missing contentRect/contentScale/scaleFactor"))
        }
        let px = CGRect(x: r.minX * sf, y: r.minY * sf, width: r.width * sf, height: r.height * sf)
        guard abs(px.minY) <= 0.5 else { return .failure(GeometryProblem(text: "vertical content offset")) }
        guard px.minX >= -0.5, px.maxX <= Double(w) + 1, px.maxY <= Double(h) + 1 else { return .failure(GeometryProblem(text: "content outside buffer")) }
        let ppx = px.width / geometry.windowSize.width, ppy = px.height / geometry.windowSize.height, expected = geometry.backingScale * cs
        guard abs(ppx - expected) <= 0.01 * expected, abs(ppy - expected) <= 0.01 * expected else { return .failure(GeometryProblem(text: "pixels per point mismatch")) }
        let v = geometry.videoRect
        return .success(CGRect(x: px.minX + v.minX * ppx, y: px.minY + v.minY * ppy, width: v.width * ppx, height: v.height * ppy))
    }

    /// Copies the pixels covering the video rectangle (integer bounds) into sRGB planes, and fingerprints the canonical ROI:
    /// the integer interior of the video rectangle (pixels fully inside it), R, G, B row-major without padding or alpha.
    private func copyCrop(_ pb: CVPixelBuffer, video v: CGRect) -> (crop: PreviewCrop, roi: [Int], fingerprint: String)? {
        let x0 = Int(floor(v.minX)), y0 = Int(floor(v.minY)), x1 = Int(ceil(v.maxX)), y1 = Int(ceil(v.maxY))
        let ix0 = Int(ceil(v.minX)), iy0 = Int(ceil(v.minY)), ix1 = Int(floor(v.maxX)), iy1 = Int(floor(v.maxY))
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard x0 >= 0, y0 >= 0, x1 <= w, y1 <= h, x1 > x0, y1 > y0, ix1 > ix0, iy1 > iy0 else { return nil }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb), cw = x1 - x0, ch = y1 - y0
        var r = ParityPlane(width: cw, height: ch), g = r, b = r
        for y in 0..<ch {
            let row = base + (y0 + y) * bpr + x0 * 4
            for x in 0..<cw { let p = row + x * 4; let k = y * cw + x; b.data[k] = Float(p[0]); g.data[k] = Float(p[1]); r.data[k] = Float(p[2]) }
        }
        let rw = ix1 - ix0, rh = iy1 - iy0
        var canonical = [UInt8](repeating: 0, count: rw * rh * 3)
        for y in 0..<rh {
            let row = base + (iy0 + y) * bpr + ix0 * 4
            for x in 0..<rw { let p = row + x * 4, o = (y * rw + x) * 3; canonical[o] = p[2]; canonical[o + 1] = p[1]; canonical[o + 2] = p[0] }
        }
        let mapping = CropMapping(scaleX: v.width / 1920, scaleY: v.height / 1080, originX: v.minX - Double(x0), originY: v.minY - Double(y0))
        return (PreviewCrop(r: r, g: g, b: b, mapping: mapping), [ix0, iy0, rw, rh], PixelFingerprint.digest(width: rw, height: rh, rgb: canonical))
    }

    /// Mean luma of a crop on a fixed 1-in-8 grid. Used only by the empty-gap darkness check, never for stability.
    static func meanLuma(_ c: PreviewCrop) -> Double {
        var s = 0.0, n = 0
        for y in stride(from: 0, to: c.r.height, by: 8) { for x in stride(from: 0, to: c.r.width, by: 8) {
            s += 0.2126 * Double(c.r[x, y]) + 0.7152 * Double(c.g[x, y]) + 0.0722 * Double(c.b[x, y]); n += 1
        } }
        return n == 0 ? 0 : s / Double(n)
    }

    /// The video rectangle in capture pixels (for provenance), from the window geometry.
    var videoRectPixels: [Double] {
        let s = geometry.backingScale, v = geometry.videoRect
        return [v.minX * s, v.minY * s, v.width * s, v.height * s]
    }
}
#endif
