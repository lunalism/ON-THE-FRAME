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
