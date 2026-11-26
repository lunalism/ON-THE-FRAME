#if DEBUG
import Foundation

/// SP-EXPORT-E4D-G1 (pure, Foundation only): verdicts, colour declarations and colour mathematics for the full Preview parity.
/// Three colour layers are kept apart and never merged:
/// 1. source interpretation — the declaration read from the source track and the decoded buffers (`ColorDeclaration`, origin "source")
/// 2. internal working colour space — a description only (`WorkingColorSpace`); it is never used to compute an expected colour
/// 3. final encoded output metadata — the declaration read from the exported track and its decoded buffers (origin "output")
/// HDR transfer functions and wide-gamut primaries are outside this phase and make a declaration unsupported (INCONCLUSIVE).

enum ParityVerdict: String, Codable, Sendable {
    case pass = "PASS", fail = "FAIL", expectedBaselineFail = "EXPECTED BASELINE FAIL", expectedBaselineDifference = "EXPECTED BASELINE DIFFERENCE"
    case inconclusive = "INCONCLUSIVE", notVerified = "NOT VERIFIED", notRun = "NOT RUN", recorded = "RECORDED"
}

struct ParityCheck: Codable, Sendable {
    let name: String
    let verdict: ParityVerdict
    let detail: String
    var values: [String: Double] = [:]
}

/// One colour declaration. nil fields are "not declared / not readable". `fullRange` is only ever an explicit declaration
/// (track: kCMFormatDescriptionExtension_FullRangeVideo) or a documented pixel-format property (decoded 420v = video range);
/// it is never inferred from the presence of other colour metadata (G1 correction, owner decision 4).
struct ColorDeclaration: Codable, Sendable, Equatable {
    var primaries: String?
    var transfer: String?
    var matrix: String?
    var fullRange: Bool?
    var origin: String          // e.g. "source track", "source decoded buffer", "output track", "output decoded buffer"

    var isComplete: Bool { primaries != nil && transfer != nil && matrix != nil && fullRange != nil }
    var isUntagged: Bool { primaries == nil && transfer == nil && matrix == nil }
    /// Supported in phase 1: BT.709 or SMPTE-C primaries, BT.709 transfer, BT.709 or BT.601 matrix.
    var isSupported: Bool {
        guard let p = primaries, let t = transfer, let m = matrix else { return false }
        return ColorMath.primaries(p) != nil && t == "ITU_R_709_2" && ColorMath.coefficients(m) != nil
    }
}

/// The colour interpretation of one file, with each source of information kept apart (G2 follow-up correction):
/// A. `track` — explicit declarations of the source track (format-description extensions). The ONLY source of declarations.
/// B. `buffer` — attributes observed on decoded buffers. Observations only: decoders attach default tags to untagged media
///    (G2: untagged SD → SMPTE_C/709/601, untagged HD → 709/709/709), so a buffer value never fills a missing declaration.
///    It may only corroborate a declared value or reveal a conflict.
/// C. `decodedPixelFormat` + the decoded range given to `resolve` — the format the reader produced ('420v' = video range by
///    definition). A conversion property of the samples, never the source's declared range.
/// D. Diagnostic hypotheses (BT.601 / BT.709) live in `ParityJudge` and are labelled as hypotheses, never stored here.
/// E. `resolved` — the complete declared interpretation required by C5: primaries, transfer, matrix and explicit range all
///    declared in the track, with no conflicting buffer observation. Otherwise nil and `problem` (C5 INCONCLUSIVE).
/// `conversion` turns decoded samples into colour: the track's declared primaries/transfer/matrix (no conflict) plus the decoded
/// range (C). nil when any of the three is not declared in the track or conflicts — untagged media stays untagged.
struct DeclaredInterpretation: Codable, Sendable {
    let track: ColorDeclaration
    let buffer: ColorDeclaration
    let resolved: ColorDeclaration?
    let problem: String?
    var conversion: ColorDeclaration?
    var decodedPixelFormat: String?
    /// Properties declared in the track whose buffer observation differs (with both values).
    var conflicts: [String] = []
    /// Buffer observations for properties the track does not declare (kept for inspection, never promoted).
    var bufferOnlyObservations: [String] = []

    static func resolve(track: ColorDeclaration, buffer: ColorDeclaration, decodedFullRange: Bool? = nil, decodedPixelFormat: String? = nil) -> DeclaredInterpretation {
        var conflicts: [String] = [], missing: [String] = [], observedOnly: [String] = []
        func examine<T: Equatable>(_ name: String, _ declared: T?, _ observed: T?) {
            if let d = declared {
                if let o = observed, o != d { conflicts.append("\(name): track \(d), decoded buffer \(o)") }
            } else {
                missing.append(name)
                if let o = observed { observedOnly.append("\(name)=\(o) (decoded buffer only, not a declaration)") }
            }
        }
        examine("primaries", track.primaries, buffer.primaries)
        examine("transfer", track.transfer, buffer.transfer)
        examine("matrix", track.matrix, buffer.matrix)
        examine("range", track.fullRange, buffer.fullRange)
        var resolved: ColorDeclaration?
        var problem: String?
        if missing.isEmpty && conflicts.isEmpty {
            let d = ColorDeclaration(primaries: track.primaries, transfer: track.transfer, matrix: track.matrix, fullRange: track.fullRange, origin: "track declaration")
            resolved = d
            problem = d.isSupported ? nil : "declaration outside phase 1 (HDR/wide gamut or unknown)"
        } else {
            var parts: [String] = []
            if !conflicts.isEmpty { parts.append("conflict: " + conflicts.joined(separator: "; ")) }
            if !missing.isEmpty { parts.append("not declared in the track: " + missing.joined(separator: ", ")) }
            problem = parts.joined(separator: " | ")
        }
        var out = DeclaredInterpretation(track: track, buffer: buffer, resolved: resolved, problem: problem)
        out.conflicts = conflicts
        out.bufferOnlyObservations = observedOnly
        out.decodedPixelFormat = decodedPixelFormat
        let colourConflict = conflicts.contains { $0.hasPrefix("primaries") || $0.hasPrefix("transfer") || $0.hasPrefix("matrix") }
        if let range = decodedFullRange, let p = track.primaries, let t = track.transfer, let m = track.matrix, !colourConflict {
            let c = ColorDeclaration(primaries: p, transfer: t, matrix: m, fullRange: range,
                                     origin: "conversion (track-declared primaries/transfer/matrix, decoded \(decodedPixelFormat ?? "buffer") range)")
            out.conversion = c.isSupported ? c : nil
        }
        return out
    }
}

/// Description of the internal working colour space. Recorded, never used for an expected colour.
struct WorkingColorSpace: Codable, Sendable {
    let compositor: String
    let description: String
    static let corrected = WorkingColorSpace(compositor: "corrected", description: "ExperimentalCompositor CIContext workingColorSpace = NSNull, outputColorSpace = NSNull (no colour management, device values pass through); output buffer carries ITU_R_709_2 primaries")
    static let builtin = WorkingColorSpace(compositor: "builtin", description: "AVFoundation built-in compositor: working colour space not documented; not inferred")
}

enum ColorMath {
    typealias RGB = (r: Double, g: Double, b: Double)
    typealias Lab = (l: Double, a: Double, b: Double)

    /// (x, y) chromaticities of R, G, B; D65 white for all supported sets.
    static func primaries(_ name: String) -> [(Double, Double)]? {
        switch name {
        case "ITU_R_709_2", "IEC_sRGB": return [(0.640, 0.330), (0.300, 0.600), (0.150, 0.060)]
        case "SMPTE_C": return [(0.630, 0.340), (0.310, 0.595), (0.155, 0.070)]
        default: return nil
        }
    }
    static func coefficients(_ name: String) -> (kr: Double, kb: Double)? {
        switch name {
        case "ITU_R_709_2": return (0.2126, 0.0722)
        case "ITU_R_601_4": return (0.299, 0.114)
        default: return nil
        }
    }

    /// 8-bit Y'CbCr → non-linear R'G'B' in 0…1 with the given matrix and range (values are clamped).
    static func rgb(y: Double, cb: Double, cr: Double, matrix: String, fullRange: Bool) -> RGB? {
        guard let k = coefficients(matrix) else { return nil }
        let yn = fullRange ? y / 255 : (y - 16) / 219
        let pb = fullRange ? (cb - 128) / 255 : (cb - 128) / 224, pr = fullRange ? (cr - 128) / 255 : (cr - 128) / 224
        let r = yn + 2 * (1 - k.kr) * pr
        let b = yn + 2 * (1 - k.kb) * pb
        let g = (yn - k.kr * r - k.kb * b) / (1 - k.kr - k.kb)
        return (clamp(r), clamp(g), clamp(b))
    }
    /// Non-linear R'G'B' (0…1) → 8-bit video-range Y'CbCr with the given matrix.
    static func ycbcr(_ c: RGB, matrix: String) -> (y: Double, cb: Double, cr: Double)? {
        guard let k = coefficients(matrix) else { return nil }
        let y = k.kr * c.r + (1 - k.kr - k.kb) * c.g + k.kb * c.b
        let pb = (c.b - y) / (2 * (1 - k.kb)), pr = (c.r - y) / (2 * (1 - k.kr))
        return (16 + 219 * y, 128 + 224 * pb, 128 + 224 * pr)
    }
    static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    /// Display-referred linearisation used for every ΔE in this test: BT.709 transfer → BT.1886 (γ 2.4, black 0); sRGB → IEC 61966-2-1.
    /// One fixed choice for all comparisons, so ΔE differences come from the values, not from the formula.
    static func linear(_ v: Double, transfer: String) -> Double {
        if transfer == "IEC_sRGB" { return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return pow(max(0, v), 2.4)
    }

    static func rgbToXYZ(_ prim: [(Double, Double)]) -> [[Double]] {
        let white = (0.3127, 0.3290)
        func xyz(_ c: (Double, Double)) -> [Double] { [c.0 / c.1, 1, (1 - c.0 - c.1) / c.1] }
        let r = xyz(prim[0]), g = xyz(prim[1]), b = xyz(prim[2]), w = xyz(white)
        let m = [[r[0], g[0], b[0]], [r[1], g[1], b[1]], [r[2], g[2], b[2]]]
        guard let s = Linear.solve3(m, w) else { return m }
        return [[r[0] * s[0], g[0] * s[1], b[0] * s[2]], [r[1] * s[0], g[1] * s[1], b[1] * s[2]], [r[2] * s[0], g[2] * s[1], b[2] * s[2]]]
    }

    /// Non-linear R'G'B' under (primaries, transfer) → CIE L*a*b* (D65).
    static func lab(_ c: RGB, primaries: String, transfer: String) -> Lab? {
        guard let p = ColorMath.primaries(primaries) else { return nil }
        let m = rgbToXYZ(p)
        let lr = linear(c.r, transfer: transfer), lg = linear(c.g, transfer: transfer), lb = linear(c.b, transfer: transfer)
        let x = m[0][0] * lr + m[0][1] * lg + m[0][2] * lb
        let y = m[1][0] * lr + m[1][1] * lg + m[1][2] * lb
        let z = m[2][0] * lr + m[2][1] * lg + m[2][2] * lb
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x / 0.95047), fy = f(y / 1.0), fz = f(z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Lab of an 8-bit Y'CbCr sample under a complete declaration.
    static func lab(y: Double, cb: Double, cr: Double, declaration d: ColorDeclaration) -> Lab? {
        guard let p = d.primaries, let t = d.transfer, let m = d.matrix, let full = d.fullRange,
              let c = rgb(y: y, cb: cb, cr: cr, matrix: m, fullRange: full) else { return nil }
        return lab(c, primaries: p, transfer: t)
    }

    /// CIEDE2000.
    static func deltaE2000(_ p: Lab, _ q: Lab) -> Double {
        let c1 = hypot(p.a, p.b), c2 = hypot(q.a, q.b), cm = (c1 + c2) / 2
        let g = 0.5 * (1 - sqrt(pow(cm, 7) / (pow(cm, 7) + pow(25, 7))))
        let a1 = (1 + g) * p.a, a2 = (1 + g) * q.a
        let cp1 = hypot(a1, p.b), cp2 = hypot(a2, q.b)
        func hue(_ b: Double, _ a: Double) -> Double { if a == 0 && b == 0 { return 0 }; let h = atan2(b, a) * 180 / .pi; return h < 0 ? h + 360 : h }
        let h1 = hue(p.b, a1), h2 = hue(q.b, a2)
        let dl = q.l - p.l, dc = cp2 - cp1
        var dh = 0.0
        if cp1 * cp2 != 0 { dh = h2 - h1; if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 } }
        let dH = 2 * sqrt(cp1 * cp2) * sin(dh * .pi / 360)
        let lm = (p.l + q.l) / 2, cpm = (cp1 + cp2) / 2
        var hm = h1 + h2
        if cp1 * cp2 != 0 { hm = abs(h1 - h2) <= 180 ? (h1 + h2) / 2 : ((h1 + h2 < 360) ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2) }
        let t = 1 - 0.17 * cos((hm - 30) * .pi / 180) + 0.24 * cos(2 * hm * .pi / 180) + 0.32 * cos((3 * hm + 6) * .pi / 180) - 0.20 * cos((4 * hm - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hm - 275) / 25, 2))
        let rc = 2 * sqrt(pow(cpm, 7) / (pow(cpm, 7) + pow(25, 7)))
        let sl = 1 + 0.015 * pow(lm - 50, 2) / sqrt(20 + pow(lm - 50, 2)), sc = 1 + 0.045 * cpm, sh = 1 + 0.015 * cpm * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc
        let x = dl / sl, y = dc / sc, z = dH / sh
        return sqrt(x * x + y * y + z * z + rt * y * z)
    }
}

/// Summary statistics of a list of ΔE or level differences.
struct Distribution: Codable, Sendable {
    let count: Int, mean: Double, p95: Double, max: Double
    init(_ values: [Double]) {
        count = values.count
        guard !values.isEmpty else { mean = .nan; p95 = .nan; max = .nan; return }
        let s = values.sorted()
        mean = values.reduce(0, +) / Double(values.count)
        p95 = s[Swift.min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
        max = s.last!
    }
}

enum Linear {
    /// Solves a 3×3 system (Gaussian elimination with partial pivoting).
    static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? { solve(a, b) }
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a.map { $0 }, v = b
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<max(c + 1, n) where abs(m[r][c]) > abs(m[p][c]) { p = r }
            guard abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p); v.swapAt(c, p)
            for r in 0..<n where r != c {
                let f = m[r][c] / m[c][c]
                if f == 0 { continue }
                for k in c..<n { m[r][k] -= f * m[c][k] }
                v[r] -= f * v[c]
            }
        }
        return (0..<n).map { v[$0] / m[$0][$0] }
    }
}
#endif
