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
final class FullPreviewWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Geometry: Codable, Sendable {
        let windowID: UInt32
        let windowSize: CGSize       // points
        let videoRect: CGRect        // points, top-left origin, in window coordinates
        let backingScale: Double
        let displayProfile: String
    }
    struct Readiness: Codable, Sendable { let ready: Bool; let reason: String; let completeSamples: Int; let otherSamples: Int }
    struct GrabResult: Sendable { let crop: PreviewCrop?; let note: String; let samples: [StabilitySample] }
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
    private var completeCount = 0, otherCount = 0, seq = 0
    private var armed: Armed?
    // Main actor only:
    private var stream: SCStream?

    private struct Armed {
        var stability = PreviewStability()
        var crop: PreviewCrop?          // crop of the latest sample of the current identical run
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

    /// Arms a grab and waits (bounded by the v1 timeout of 10 s) until the Preview ROI fingerprint is stable. Returns the crop of
    /// the last sample of the stable run and the logged samples (timestamps, statuses, ROI, fingerprints). No crop on timeout,
    /// error or a terminal status. The caller judges source identity separately on the returned crop.
    @MainActor func grab() async -> GrabResult {
        lock.withLock { armed = Armed() }
        let t0 = CACurrentMediaTime()
        var note = "timeout after \(ParityThresholdsV1.stableTimeoutSeconds) s without a stable fingerprint"
        var crop: PreviewCrop?
        while CACurrentMediaTime() - t0 < ParityThresholdsV1.stableTimeoutSeconds {
            let (a, err, term) = lock.withLock { (armed, streamError, terminal) }
            if let err { note = "capture error: \(err)"; break }
            if let term { note = "terminal status: \(term)"; break }
            if stream == nil { note = "stream stopped"; break }
            if let a, a.stability.stable, let c = a.crop { crop = c; note = "stable: \(a.stability.run.count) identical samples"; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let log = lock.withLock { () -> [StabilitySample] in let l = armed?.stability.log ?? []; armed = nil; return l }
        return GrabResult(crop: crop, note: note, samples: log)
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
        let display = (info[.displayTime] as? UInt64).map(Self.seconds(machTicks:))
        let (n, isArmed) = lock.withLock { () -> (Int, Bool) in
            seq += 1
            if status == .complete { completeCount += 1; if firstComplete == nil { firstComplete = arrival } } else { otherCount += 1 }
            if status == .stopped { terminal = terminal ?? "stopped" }
            if status == .suspended, firstComplete != nil { terminal = terminal ?? "suspended" }
            return (seq, armed != nil)
        }
        guard isArmed else { return }
        func feed(_ statusText: String, roi: [Int]? = nil, fingerprint: String? = nil, crop: PreviewCrop? = nil) {
            let sample = StabilitySample(seq: n, arrival: arrival, displayTime: display, status: statusText, roi: roi, fingerprint: fingerprint)
            lock.withLock {
                guard var a = armed else { return }
                a.stability.feed(sample)
                if let crop, a.stability.run.last?.seq == n { a.crop = crop }   // keep the crop of the run's latest sample only
                armed = a
            }
        }
        switch status {
        case .complete: break
        case .idle: feed("idle"); return
        case .blank: feed("blank"); return
        case .suspended: feed("suspended"); return
        case .stopped: feed("stopped"); return
        default: feed("other"); return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { feed("unusable-buffer"); return }
        let rect = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        let sf = (info[.scaleFactor] as? NSNumber)?.doubleValue, cs = (info[.contentScale] as? NSNumber)?.doubleValue
        switch videoRectInBuffer(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), contentRect: rect, contentScale: cs, scaleFactor: sf) {
        case .failure: feed("unreadable-geometry")
        case .success(let v):
            guard let copied = copyCrop(pb, video: v) else { feed("unusable-buffer"); return }
            feed("complete", roi: copied.roi, fingerprint: copied.fingerprint, crop: copied.crop)
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
