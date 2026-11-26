#if DEBUG
import Foundation

/// SP-EXPORT-E4D-G1 (pure, Foundation only): shared layout of the parity fixtures, image planes and coordinate mapping.
/// The fixture constants repeat `ParityFixtures` (OTFDevSupport, layout version 1); a mismatch shows up as unreadable codes or
/// patches and is reported INCONCLUSIVE, never as a pass.
enum ParityLayout {
    static let version = 1
    /// Source IDs drawn by the fixtures (ParityFixtures) and by the existing readable fixtures used in G and M6.
    static let calibrationID = 0xC1, resamplingID = 0xC2, sceneID = 0xC3
    static let sdUntaggedID = 0xD1, sd601ID = 0xD2, hd709ID = 0xD3, hdUntaggedID = 0xD4
    static let otfTA = 0x33, otfTB = 0xCC

    /// Code cell centre in source-normalised coordinates (0…1) for bit `b` of the ID row (row 0) or the frame row (row 1).
    static func codeCell(bit b: Int, row: Int) -> (x: Double, y: Double, w: Double, h: Double) {
        let x = (40.0 + Double(b) * 56 + 24) / 1920, y = ((row == 0 ? 100.0 : 170.0) + 24) / 1080
        return (x, y, 48.0 / 1920, 48.0 / 1080)
    }
    /// Patch rectangle in source-normalised coordinates (same grid as ParityFixtures.patchRect).
    static func patch(_ i: Int) -> (x: Double, y: Double, w: Double, h: Double) {
        let c = i % 6, r = i / 6
        return (Double(240 + 240 * c) / 1920, Double(320 + 180 * r) / 1080, 160.0 / 1920, 140.0 / 1080)
    }
    static let patchCount = 24
    static let greyPatches = Array(0...10)
    /// Fixed split (G0): 8 validation patches never used for fitting, 16 training patches.
    static let validationPatches: [Int] = [2, 5, 8, 12, 14, 17, 20, 23]
    static var trainingPatches: [Int] { (0..<patchCount).filter { !validationPatches.contains($0) } }

    struct Region: Codable, Sendable { let kind: String; let x: Int; let y: Int; let w: Int; let h: Int; let validation: Bool }
    /// Resampling regions in 1920×1080 source pixels (same as ParityFixtures.resolutionRegions).
    static let resolutionRegions: [Region] = {
        let kinds = ["vlines", "hlines", "checker1", "checker2", "checker3", "vedge", "hedge", "dots", "ramp"]
        var out: [Region] = []
        for (row, k) in kinds.enumerated() {
            out.append(Region(kind: k, x: 80, y: 300 + row * 80, w: 800, h: 64, validation: false))
            out.append(Region(kind: k, x: 1040, y: 300 + row * 80, w: 800, h: 64, validation: true))
        }
        return out
    }()
}

/// One image channel as Float (8-bit scale 0…255 unless stated).
struct ParityPlane: Sendable {
    let width: Int, height: Int
    var data: [Float]
    init(width: Int, height: Int, data: [Float]) { self.width = width; self.height = height; self.data = data }
    init(width: Int, height: Int, fill: Float = 0) { self.width = width; self.height = height; data = [Float](repeating: fill, count: width * height) }
    subscript(x: Int, y: Int) -> Float { data[y * width + x] }
    func crop(x: Int, y: Int, w: Int, h: Int) -> ParityPlane {
        var out = ParityPlane(width: w, height: h)
        for yy in 0..<h { for xx in 0..<w {
            let sx = min(width - 1, max(0, x + xx)), sy = min(height - 1, max(0, y + yy))
            out.data[yy * w + xx] = data[sy * width + sx]
        } }
        return out
    }
    func mean(x: Int, y: Int, w: Int, h: Int) -> Double {
        var s = 0.0, n = 0
        for yy in max(0, y)..<min(height, y + h) { for xx in max(0, x)..<min(width, x + w) { s += Double(data[yy * width + xx]); n += 1 } }
        return n == 0 ? .nan : s / Double(n)
    }
}

/// Native-resolution decoded frame (8-bit Y'CbCr, chroma upsampled by repetition to full size) with its colour declaration.
struct NativeFrame: Sendable {
    let y: ParityPlane, cb: ParityPlane, cr: ParityPlane
    let declaration: ColorDeclaration
    var width: Int { y.width }
    var height: Int { y.height }
}

/// Captured Preview crop: non-linear sRGB R'G'B' in 0…255 (as delivered by the capture stream) plus the mapping from output
/// (1920×1080 timeline) coordinates to crop pixels: crop = origin + output × scale.
struct PreviewCrop: Sendable {
    let r: ParityPlane, g: ParityPlane, b: ParityPlane
    let mapping: CropMapping
}
struct CropMapping: Codable, Sendable {
    let scaleX: Double, scaleY: Double       // crop pixels per output pixel
    let originX: Double, originY: Double     // crop pixel coordinate of output point (0, 0)
    func crop(_ ox: Double, _ oy: Double) -> (Double, Double) { (originX + ox * scaleX, originY + oy * scaleY) }
    func output(_ cx: Double, _ cy: Double) -> (Double, Double) { ((cx - originX) / scaleX, (cy - originY) / scaleY) }
}

/// A source drawn into the output frame: its rectangle in output pixels (top-left origin).
struct PlacedSource: Codable, Sendable {
    let sourceID: Int
    let x: Double, y: Double, w: Double, h: Double
    func output(_ nx: Double, _ ny: Double) -> (Double, Double) { (x + nx * w, y + ny * h) }
}

/// Preview stability by pixel fingerprint (G1 correction, owner decision 2). Independent of source-frame identity: a stable
/// fingerprint only says the captured Preview image did not change; it never says which source frame is shown.
enum PixelFingerprint {
    /// FNV-1a 64 over the canonical ROI bytes: width and height (4 bytes each, little endian), then R, G, B of every pixel,
    /// row-major, no row padding, no alpha. Exact equality is required; no tolerance is applied (none is approved).
    static func digest(width: Int, height: Int, rgb: [UInt8]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ b: UInt8) { h ^= UInt64(b); h = h &* 0x100000001b3 }
        for v in [UInt32(width), UInt32(height)] { for i in 0..<4 { mix(UInt8((v >> (8 * UInt32(i))) & 0xff)) } }
        for b in rgb { mix(b) }
        return String(format: "%016llx", h)
    }
}

/// One capture sample as seen by the stability rule.
struct StabilitySample: Codable, Sendable {
    let seq: Int
    let arrival: Double              // host clock (CACurrentMediaTime), seconds
    let displayTime: Double?         // SCStreamFrameInfo.displayTime, seconds, when present
    let status: String               // complete, idle, unreadable-geometry, unusable-buffer, blank, suspended, stopped, other
    let roi: [Int]?                  // canonical ROI in buffer pixels: x, y, w, h (integer interior of the video rectangle)
    let fingerprint: String?
    // SP-EXPORT-E4D-G4-STALE-CAPTURE-FIX-79 (optional, absent in earlier results):
    var generation: Int? = nil       // grab generation captured at sample receipt
    var displayTicks: UInt64? = nil  // SCStreamFrameInfo.displayTime as raw mach absolute ticks (compared with the fence in ticks)
    var processingMs: Double? = nil  // receipt → processed (host clock), complete samples that were processed
    var identity: String? = nil      // frame code read on this sample's crop ("id/frame/margin" or "unreadable"); coded grabs only
}

/// Stable = at least `required` consecutive complete, readable samples with the same ROI and the same fingerprint, spanning at least
/// `minimumSpan` seconds (host clock). Idle samples carry no new image: they neither count nor break a run. Unreadable geometry,
/// unusable buffers and other statuses break the run. Values come from threshold table v1 (3 samples, 50 ms).
struct PreviewStability: Sendable {
    let required: Int
    let minimumSpan: Double
    private(set) var run: [StabilitySample] = []
    private(set) var log: [StabilitySample] = []
    private(set) var stable = false
    static let logLimit = 256

    init(required: Int = ParityThresholdsV1.stableSamples, minimumSpan: Double = ParityThresholdsV1.stableMinimumSeconds) {
        self.required = required; self.minimumSpan = minimumSpan
    }

    /// Feeds one sample; returns true when the stability condition is met (and stays true).
    @discardableResult
    mutating func feed(_ s: StabilitySample) -> Bool {
        if log.count < Self.logLimit { log.append(s) }
        guard !stable else { return true }
        switch s.status {
        case "idle": return false
        case "complete":
            guard let fp = s.fingerprint, let roi = s.roi else { run = []; return false }
            if let last = run.last, last.fingerprint == fp, last.roi == roi { run.append(s) } else { run = [s] }
            if run.count >= required, let first = run.first, s.arrival - first.arrival >= minimumSpan { stable = true }
            return stable
        default:
            run = []; return false
        }
    }
}

// MARK: - SP-EXPORT-E4D-G4-STALE-CAPTURE-FIX-79: capture freshness, grab generations, identity-gated acceptance (pure)
//
// G4 CAL-B (2026-11-26) accepted three capture samples for frame 15 that were displayed before the frame-15 seek was even
// requested (ScreenCaptureKit queue backlog). PreviewStability proves repeated pixels only. These types add, without changing the
// v1 stability rule (3 samples, 50 ms, 10 s): a freshness fence (displayTime strictly after a monotonic boundary taken once the
// current seek is confirmed complete), strictly increasing display times, generation isolation between grabs, and, for
// frame-coded fixtures, acceptance only of a fresh stable run whose frame code is the requested one. Clock domain: the fence and
// SCStreamFrameInfo.displayTime are both mach absolute time; they are compared as raw ticks (no conversion).

/// Why a capture sample may or may not enter the stability rule of the current grab.
enum CaptureAdmission: String, Codable, Sendable {
    case fresh, stale, missingDisplayTime, nonMonotonic
}

/// Expected frame code of the Preview in one grab (frame-coded fixtures only; uncoded media have no identity requirement).
struct ExpectedPreviewCode: Sendable {
    let placed: PlacedSource
    let sourceID: Int
    let frame: Int
    /// Same rule as the previewIdentity judgment: source ID, frame and the v1 margin.
    func matches(_ r: ParityCode.Reading?) -> Bool {
        guard let r else { return false }
        return r.sourceID == sourceID && r.frame == frame && r.margin >= ParityThresholdsV1.codeMarginMinimum
    }
    static func describe(_ r: ParityCode.Reading?) -> String { r.map { "\($0.sourceID)/\($0.frame)/m\($0.margin)" } ?? "unreadable" }
}

struct WrongIdentityObservation: Codable, Sendable { let seq: Int; let displayTime: Double?; let reading: String }

/// Per-grab diagnostics written to the run record (no verdict of its own).
struct GrabDiagnostics: Codable, Sendable {
    let generation: Int
    let fenceTicks: UInt64
    let identityRequired: Bool
    let outcome: String                       // accepted | wrongIdentityAtTimeout | noFreshCapture | notStable | captureError | terminal | streamStopped
    let counts: [String: Int]                 // admissions (fresh, stale, missingDisplayTime, nonMonotonic), otherGeneration, idle, other statuses
    let freshComplete: Int
    let wrongIdentityCount: Int
    let wrongIdentity: [WrongIdentityObservation]
    let acceptedSeq: Int?
    let firstFreshDisplayTime: Double?
    let processingMsMean: Double?
    let processingMsMax: Double?
}

/// One grab: freshness admission at receipt (before pixel work), generation check at commit, the unchanged v1 stability rule over
/// fresh samples only, and identity-gated acceptance. Pure; the capture object holds it under its lock.
struct FreshGrab: Sendable {
    enum Step: Equatable, Sendable { case pending, accepted, wrongIdentityStable, rejectedOtherGeneration }
    static let logLimit = 256, wrongIdentityLimit = 16

    let generation: Int
    let fenceTicks: UInt64
    let identityRequired: Bool
    private(set) var stability = PreviewStability()
    private(set) var log: [StabilitySample] = []
    private(set) var lastAdmittedTicks: UInt64?
    private(set) var counts: [String: Int] = [:]
    private(set) var freshComplete = 0
    private(set) var wrongIdentity: [WrongIdentityObservation] = []
    private(set) var wrongIdentityCount = 0
    private(set) var lastWrongStableSeq: Int?
    private(set) var acceptedSeq: Int?
    private(set) var firstFreshDisplayTime: Double?

    init(generation: Int, fenceTicks: UInt64, identityRequired: Bool) {
        self.generation = generation; self.fenceTicks = fenceTicks; self.identityRequired = identityRequired
    }

    /// Freshness of a complete sample at receipt: a display time strictly after the fence and strictly after the last admitted one.
    /// Missing or zero display time is never freshness evidence. Updates the ordering state only for fresh samples.
    mutating func admit(displayTicks: UInt64?) -> CaptureAdmission {
        let a: CaptureAdmission
        if let t = displayTicks, t > 0 {
            if t <= fenceTicks { a = .stale }
            else if let last = lastAdmittedTicks, t <= last { a = .nonMonotonic }
            else { a = .fresh; lastAdmittedTicks = t }
        } else { a = .missingDisplayTime }
        counts[a.rawValue, default: 0] += 1
        return a
    }

    /// Commits a processed (or non-complete, or refused) sample of generation `receiptGeneration`. A sample of another generation
    /// never touches this grab. Fresh complete samples feed the v1 rule; any other status goes through the rule as before
    /// (idle ignored, everything else breaks the run). When the run becomes stable: identity required and not matching →
    /// recorded wrong-identity observation and a new run; otherwise accepted.
    mutating func commit(_ s: StabilitySample, receiptGeneration: Int, identityMatches: Bool?) -> Step {
        guard receiptGeneration == generation else { counts["otherGeneration", default: 0] += 1; return .rejectedOtherGeneration }
        if log.count < Self.logLimit { log.append(s) }
        // Refused complete samples were counted at admission; count the other non-complete statuses here.
        if s.status != "complete" && !CaptureAdmission.allStatuses.contains(s.status) { counts[s.status, default: 0] += 1 }
        guard acceptedSeq == nil else { return .accepted }
        if s.status == "complete" {
            freshComplete += 1
            if firstFreshDisplayTime == nil { firstFreshDisplayTime = s.displayTime }
        }
        guard stability.feed(s) else { return .pending }
        if identityRequired && identityMatches != true {
            wrongIdentityCount += 1
            if wrongIdentity.count < Self.wrongIdentityLimit {
                wrongIdentity.append(WrongIdentityObservation(seq: s.seq, displayTime: s.displayTime, reading: s.identity ?? "unreadable"))
            }
            lastWrongStableSeq = s.seq
            stability = PreviewStability()   // the next fresh samples must form a new run (same v1 rule)
            return .wrongIdentityStable
        }
        acceptedSeq = s.seq
        return .accepted
    }

    /// Reason when no capture was accepted within the timeout.
    var timeoutOutcome: String {
        if lastWrongStableSeq != nil { return "wrongIdentityAtTimeout" }
        return freshComplete == 0 ? "noFreshCapture" : "notStable"
    }

    func diagnostics(outcome: String) -> GrabDiagnostics {
        let p = log.compactMap(\.processingMs)
        return GrabDiagnostics(generation: generation, fenceTicks: fenceTicks, identityRequired: identityRequired, outcome: outcome, counts: counts,
                               freshComplete: freshComplete, wrongIdentityCount: wrongIdentityCount, wrongIdentity: wrongIdentity,
                               acceptedSeq: acceptedSeq, firstFreshDisplayTime: firstFreshDisplayTime,
                               processingMsMean: p.isEmpty ? nil : p.reduce(0, +) / Double(p.count), processingMsMax: p.max())
    }
}

extension CaptureAdmission {
    /// Status texts logged for refused complete samples (they break a run like any non-complete status).
    static let allStatuses: Set<String> = ["stale", "missingDisplayTime", "nonMonotonic"]
}

/// State of the seek requested for one Preview frame, from existing observable state only (no additional seek):
/// the store's latest seek token, the Preview host's pending-seek list (a seek leaves it when it completes or is cancelled), the
/// host's displayed frame (set only by a completed seek) and the paused overlay's confirmed frame (set only when the player reports
/// finished == true for the CURRENT token; cleared synchronously when the seek is requested). Player time alone is never used.
enum SeekProbe {
    enum State: String, Codable, Sendable { case superseded, itemChanged, unverifiable, inFlight, interrupted, completed }
    static func classify(requestedToken: Int, currentToken: Int, itemChanged: Bool, confirmationClearedAtRequest: Bool,
                         pending: Bool, overlayConfirmedFrame: Int?, displayedFrame: Int, frame: Int) -> State {
        if currentToken != requestedToken { return .superseded }
        if itemChanged { return .itemChanged }
        if !confirmationClearedAtRequest { return .unverifiable }
        if pending { return .inFlight }
        return overlayConfirmedFrame == frame && displayedFrame == frame ? .completed : .interrupted
    }
}

/// Seek, settlement and freshness boundary of one Preview frame (host clock seconds, fence in mach ticks).
struct SeekSettlement: Codable, Sendable {
    let frame: Int
    var token = 0
    var requested = 0.0
    var confirmationClearedAtRequest = false
    var completionObserved: Double?          // first poll that saw the completed state (≤ 10 ms after the completion handler ran)
    var settled: Double?
    var fenceTicks: UInt64?
    var fenceSeconds: Double?
    var outcome = "pending"                  // settled | superseded | itemChanged | unverifiable | interrupted | timeout…
    var readyForDisplay: Bool?
    var showingStill: Bool?
    var displayedFrame: Int?
    var overlayConfirmedFrame: Int?
    var playerTime: String?
}

struct FrameCaptureDiagnostics: Codable, Sendable {
    let seek: SeekSettlement
    let grab: GrabDiagnostics?
}

// MARK: - SP-EXPORT-E4D-G4-GEOMETRY-FIX-84: optional 2:1 Preview attempt, bounded measured adjustments (pure)
//
// G4-02 (task 83, reconstructed offline, not recorded): the old correction scaled the video-height error by window/view height
// (871/541 ≈ 1.61) and rounded, so a 1 pt error became a 2 pt window step: 871 → 869 → 871 → 869 → 871 (view 541 ↔ 539, never 540),
// ending on the start size with no check after the last resize. This decision function steps toward the target from the MEASURED
// error in physical-pixel quanta, scales a step by the response measured on an earlier attempt, measures a window size at most twice,
// stops on a non-responsive resize, constraints or the attempt bound, and is always evaluated on a fresh measurement, so the final
// verdict comes from a measurement taken after the last resize. Match rule unchanged from G0: video size within 0.25 pt of
// (960, 540) / backing scale, and origin × scale within 0.01 of an integer. 2:1 remains optional.

/// One measurement of the window and the Preview video rectangle (points; window coordinates, bottom-left origin).
struct TwoToOneSample: Codable, Sendable, Equatable {
    var windowW: Double, windowH: Double
    var viewW: Double, viewH: Double
    var videoX: Double, videoY: Double, videoW: Double, videoH: Double
    var scale: Double
    var physical: [Double] { [videoX * scale, videoY * scale, videoW * scale, videoH * scale] }
}

/// One adjustment: measurement before, the requested window size, the measurement after (re-read, never assumed).
struct TwoToOneAttempt: Codable, Sendable, Equatable {
    let index: Int
    let before: TwoToOneSample
    let axis: String                 // "height" (view wider than 16:9) or "width"
    let errorPoints: Double          // target − video along the axis, points
    let stepPoints: Double           // requested window change along the axis, points (a multiple of 1/scale)
    let requestedW: Double, requestedH: Double
    var after: TwoToOneSample?
}

enum TwoToOne {
    static let maxAttempts = 8
    static let coarseStepLimitPixels = 64.0

    /// G0 rule, unchanged: size within 0.25 pt and integral physical origin within 0.01.
    static func sizeMatches(_ s: TwoToOneSample) -> Bool {
        abs(s.videoW - 960 / s.scale) < 0.25 && abs(s.videoH - 540 / s.scale) < 0.25
    }
    static func originIntegral(_ s: TwoToOneSample) -> Bool {
        abs((s.videoX * s.scale).rounded() - s.videoX * s.scale) < 0.01 && abs((s.videoY * s.scale).rounded() - s.videoY * s.scale) < 0.01
    }

    enum Decision: Equatable, Sendable {
        case done(achieved: Bool, reason: String)
        case resize(width: Double, height: Double, axis: String, error: Double, step: Double)
    }

    /// Next action from the CURRENT (fresh) measurement and the attempts so far. `minSize`/`maxSize` are window frame limits (points).
    static func decide(current s: TwoToOneSample, attempts: [TwoToOneAttempt], initial: TwoToOneSample,
                       minSize: (w: Double, h: Double), maxSize: (w: Double, h: Double)) -> Decision {
        guard s.scale > 0, s.viewW > 0, s.viewH > 0 else { return .done(achieved: false, reason: "invalid geometry") }
        let size = sizeMatches(s), integral = originIntegral(s)
        if size && integral { return .done(achieved: true, reason: "achieved") }
        if size { return .done(achieved: false, reason: "size matched; origin not integral (origin is not adjusted)") }
        if attempts.count >= maxAttempts { return .done(achieved: false, reason: "attempt bound \(maxAttempts) reached") }
        if let last = attempts.last, let a = last.after, a.windowW == last.before.windowW, a.windowH == last.before.windowH {
            return .done(achieved: false, reason: "window did not resize (requested \(last.requestedW)×\(last.requestedH), actual \(a.windowW)×\(a.windowH))")
        }
        let quantum = 1 / s.scale
        let heightAxis = s.viewW / s.viewH > 16.0 / 9
        let axis = heightAxis ? "height" : "width"
        let error = heightAxis ? 540 / s.scale - s.videoH : 960 / s.scale - s.videoW
        if abs(error) < 0.25 { return .done(achieved: false, reason: "\(axis) matched; the other dimension differs (aspect)") }
        // Response (video change per window change) measured on the latest attempt on this axis that changed both; else 1.
        var slope = 1.0
        if let r = attempts.last(where: { $0.axis == axis && $0.after != nil }), let a = r.after {
            let dw = heightAxis ? a.windowH - r.before.windowH : a.windowW - r.before.windowW
            let dv = heightAxis ? a.videoH - r.before.videoH : a.videoW - r.before.videoW
            if dw != 0, dv != 0, dv / dw > 0 { slope = min(1, max(0.25, dv / dw)) }
        }
        let pixels = min(coarseStepLimitPixels, max(1, (abs(error) / slope * s.scale).rounded(.down)))
        let step = (error > 0 ? 1 : -1) * pixels * quantum
        let w = heightAxis ? s.windowW : s.windowW + step, h = heightAxis ? s.windowH + step : s.windowH
        if w < minSize.w || h < minSize.h || w > maxSize.w || h > maxSize.h {
            return .done(achieved: false, reason: "constraint: requested \(w)×\(h) outside \(minSize.w)×\(minSize.h)…\(maxSize.w)×\(maxSize.h)")
        }
        // A size may be measured at most twice: one revisit is allowed because the layout can change between requests; a third
        // request for the same size is oscillation.
        let visited = [initial] + attempts.compactMap(\.after)
        if visited.filter({ $0.windowW == w && $0.windowH == h }).count >= 2 {
            return .done(achieved: false, reason: "oscillation: window \(w)×\(h) already measured twice; exact 2:1 not reachable by \(axis) steps")
        }
        return .resize(width: w, height: h, axis: axis, error: error, step: step)
    }
}

enum ParityCode {
    struct Reading: Codable, Sendable { let sourceID: Int; let frame: Int; let margin: Int }
    /// Reads the frame code of `placed` from a luma sampler (8-bit full-range luma at an output coordinate, nil if outside).
    /// The cell is averaged over its central 40 % square.
    static func read(placed: PlacedSource, luma: (Double, Double, Double) -> Double?) -> Reading? {
        var margin = Int.max
        func bits(_ row: Int, _ count: Int) -> Int? {
            var v = 0
            for b in 0..<count {
                let c = ParityLayout.codeCell(bit: b, row: row)
                let (ox, oy) = placed.output(c.x, c.y)
                let half = 0.2 * min(c.w * placed.w, c.h * placed.h)
                guard let m = luma(ox, oy, half) else { return nil }
                margin = min(margin, Int(abs(m - 128).rounded()))
                v = (v << 1) | (m > 128 ? 1 : 0)
            }
            return v
        }
        guard let id = bits(0, 8), let frame = bits(1, 16) else { return nil }
        return Reading(sourceID: id, frame: frame, margin: margin == Int.max ? 0 : margin)
    }
    /// Luma sampler over a native frame (video-range Y' converted to 0…255 full scale).
    static func nativeSampler(_ f: NativeFrame) -> (Double, Double, Double) -> Double? {
        { ox, oy, half in
            let x0 = Int((ox - half).rounded()), x1 = Int((ox + half).rounded()), y0 = Int((oy - half).rounded()), y1 = Int((oy + half).rounded())
            guard x0 >= 0, y0 >= 0, x1 < f.width, y1 < f.height, x1 >= x0, y1 >= y0 else { return nil }
            let m = f.y.mean(x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1)
            let full = f.declaration.fullRange ?? false
            return full ? m : (m - 16) * 255 / 219
        }
    }
    /// Luma sampler over a Preview crop (sRGB values, BT.709 luma weights; only the bright/dark decision matters).
    static func cropSampler(_ c: PreviewCrop) -> (Double, Double, Double) -> Double? {
        { ox, oy, half in
            let (cx, cy) = c.mapping.crop(ox, oy)
            let h = max(1.0, half * c.mapping.scaleX)
            let x0 = Int((cx - h).rounded()), x1 = Int((cx + h).rounded()), y0 = Int((cy - h).rounded()), y1 = Int((cy + h).rounded())
            guard x0 >= 0, y0 >= 0, x1 < c.r.width, y1 < c.r.height, x1 >= x0, y1 >= y0 else { return nil }
            let w = x1 - x0 + 1, hh = y1 - y0 + 1
            return 0.2126 * c.r.mean(x: x0, y: y0, w: w, h: hh) + 0.7152 * c.g.mean(x: x0, y: y0, w: w, h: hh) + 0.0722 * c.b.mean(x: x0, y: y0, w: w, h: hh)
        }
    }
}
#endif
