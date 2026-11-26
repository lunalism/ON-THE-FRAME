#if DEBUG
import Foundation

/// SP-EXPORT-E4D-G1 (pure, Foundation only): the fixed colour calibration and the Preview resampling model.
/// Both are fitted once (CAL-B, RES-B), frozen to JSON and only read afterwards. Validation data never enters a fit:
/// `Calibration.fit` and `Resampling.fitPhase` receive training items only and refuse an input that contains a validation item.

/// Where a frozen model came from. A later run whose environment differs cannot use the model (dependent judgments INCONCLUSIVE).
struct ModelProvenance: Codable, Sendable, Equatable {
    var displayProfile: String
    var videoRectPixels: [Double]       // x, y, w, h in capture pixels
    var backingScale: Double
    var appBinarySHA256: String
    var captureColorSpace: String
    var fixtureSHA256: String
    var compositor: String
    /// Fields that must match for a frozen model to be reusable (fixture and compositor are allowed to differ).
    func environmentMatches(_ o: ModelProvenance) -> Bool {
        displayProfile == o.displayProfile && backingScale == o.backingScale && appBinarySHA256 == o.appBinarySHA256
            && captureColorSpace == o.captureColorSpace && zip(videoRectPixels, o.videoRectPixels).allSatisfy { abs($0 - $1) < 0.01 }
            && videoRectPixels.count == o.videoRectPixels.count
    }
}

enum Fingerprint {
    static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }
}

// MARK: - Calibration

enum Calibration {
    /// One patch: captured Preview mean (sRGB R'G'B' 0…1) and the reference (source decoded with its declared interpretation, R'G'B' 0…1).
    struct Patch: Codable, Sendable { let index: Int; let measured: [Double]; let reference: [Double]; let pixels: Int }

    struct Frozen: Codable, Sendable {
        let kind: String                 // "calibration"
        let thresholds: String           // v1 fingerprint
        let matrix: [[Double]]           // 3 rows × [r, g, b, offset]: reference = M · [measured, 1]
        let trainingIndices: [Int], validationIndices: [Int]
        let referenceDeclaration: ColorDeclaration
        let validationDE: Distribution
        let greyMonotonic: Bool
        let valid: Bool
        let reason: String
        let provenance: ModelProvenance
        /// Parameter fingerprint stored when CAL-B froze the result (D-042). Consumers recompute it from `matrix` and refuse a mismatch.
        let storedParameters: String
        var parameters: String { Fingerprint.fnv(matrix.flatMap { $0 }.map { String(format: "%.9f", $0) }.joined(separator: ",")) }
        var integrityOK: Bool { !matrix.isEmpty && storedParameters == parameters }
        // parity-color-v3 (task 97). Absent in v1 files (decoded as nil), so a v1 model is refused by ParityG4V3.admitCalibration.
        var colorContract: ColorContractIdentity? = nil
        var admissibility: CalibrationV3.Admissibility? = nil
        var validationVerdict: ParityVerdict? = nil
        var aggregateVerdict: ParityVerdict? = nil
        var targetDeclaration: ColorDeclaration? = nil
        var contractBinding: String? = nil
    }

    enum FitError: Error, CustomStringConvertible {
        case validationLeak([Int]), tooFew(Int), singular
        var description: String {
            switch self {
            case .validationLeak(let i): "validation patches \(i) offered to the fit (refused)"
            case .tooFew(let n): "only \(n) training patches"
            case .singular: "singular normal equations"
            }
        }
    }

    /// Least-squares 3×3 + offset from training patches only.
    static func fit(training: [Patch]) throws -> [[Double]] {
        let leaked = training.map(\.index).filter { ParityLayout.validationPatches.contains($0) }
        guard leaked.isEmpty else { throw FitError.validationLeak(leaked) }
        guard training.count >= 8 else { throw FitError.tooFew(training.count) }
        var rows: [[Double]] = []
        for c in 0..<3 {
            var ata = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4), atb = [Double](repeating: 0, count: 4)
            for p in training {
                let v = [p.measured[0], p.measured[1], p.measured[2], 1]
                for i in 0..<4 { atb[i] += v[i] * p.reference[c]; for j in 0..<4 { ata[i][j] += v[i] * v[j] } }
            }
            guard let w = Linear.solve(ata, atb) else { throw FitError.singular }
            rows.append(w)
        }
        return rows
    }
    static func apply(_ m: [[Double]], _ rgb: [Double]) -> [Double] {
        (0..<3).map { c in ColorMath.clamp(m[c][0] * rgb[0] + m[c][1] * rgb[1] + m[c][2] * rgb[2] + m[c][3]) }
    }

    /// Fits on the training split, then validates on the untouched validation split (ΔE00 under the reference declaration)
    /// and checks that the grey steps stay strictly increasing. Never refits.
    static func calibrate(patches: [Patch], reference: ColorDeclaration, provenance: ModelProvenance) -> Frozen {
        let training = patches.filter { ParityLayout.trainingPatches.contains($0.index) }
        let validation = patches.filter { ParityLayout.validationPatches.contains($0.index) }
        func frozen(_ m: [[Double]], _ d: Distribution, _ mono: Bool, _ ok: Bool, _ why: String) -> Frozen {
            Frozen(kind: "calibration", thresholds: ParityThresholdsV1.fingerprint, matrix: m, trainingIndices: training.map(\.index),
                   validationIndices: validation.map(\.index), referenceDeclaration: reference, validationDE: d, greyMonotonic: mono,
                   valid: ok, reason: why, provenance: provenance,
                   storedParameters: Fingerprint.fnv(m.flatMap { $0 }.map { String(format: "%.9f", $0) }.joined(separator: ",")))
        }
        guard patches.count == ParityLayout.patchCount, validation.count == ParityLayout.validationPatches.count else {
            return frozen([], Distribution([]), false, false, "expected \(ParityLayout.patchCount) readable patches, got \(patches.count)")
        }
        guard let p = reference.primaries, let t = reference.transfer, reference.isComplete, reference.isSupported else {
            return frozen([], Distribution([]), false, false, "reference declaration incomplete or unsupported")
        }
        let m: [[Double]]
        do { m = try fit(training: training) } catch { return frozen([], Distribution([]), false, false, "\(error)") }
        var des: [Double] = []
        for v in validation {
            let a = apply(m, v.measured)
            guard let la = ColorMath.lab((a[0], a[1], a[2]), primaries: p, transfer: t),
                  let lb = ColorMath.lab((v.reference[0], v.reference[1], v.reference[2]), primaries: p, transfer: t) else { continue }
            des.append(ColorMath.deltaE2000(la, lb))
        }
        let d = Distribution(des)
        let greys = ParityLayout.greyPatches.compactMap { i in patches.first { $0.index == i } }
        let lumas = greys.map { g -> Double in let a = apply(m, g.measured); return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2] }
        let mono = lumas.count == ParityLayout.greyPatches.count && zip(lumas, lumas.dropFirst()).allSatisfy { $0 < $1 }
        let ok = des.count == validation.count && d.mean <= ParityThresholdsV1.calibrationValidationMeanDE
            && d.max <= ParityThresholdsV1.calibrationValidationMaxDE && mono
        let why = ok ? "valid" : String(format: "validation ΔE00 mean %.3f max %.3f (limits %.1f/%.1f), grey monotonic %@, ΔE computed %d/%d",
                                        d.mean, d.max, ParityThresholdsV1.calibrationValidationMeanDE, ParityThresholdsV1.calibrationValidationMaxDE,
                                        mono ? "yes" : "no", des.count, validation.count)
        return frozen(m, d, mono, ok, why)
    }
}

// MARK: - Resampling

enum Resampling {
    /// Approved candidates in their fixed order (ties resolve to the earlier one).
    enum Candidate: String, Codable, CaseIterable, Sendable { case area, bilinear, catmullRom, mitchell, lanczos2, lanczos3 }

    static func radius(_ c: Candidate) -> Double {
        switch c { case .area: 0.5; case .bilinear: 1; case .catmullRom, .mitchell, .lanczos2: 2; case .lanczos3: 3 }
    }
    static func kernel(_ c: Candidate, _ x: Double) -> Double {
        let a = abs(x)
        switch c {
        case .area: return a < 0.5 ? 1 : (a == 0.5 ? 0.5 : 0)
        case .bilinear: return max(0, 1 - a)
        case .catmullRom: return cubic(a, b: 0, c: 0.5)
        case .mitchell: return cubic(a, b: 1.0 / 3, c: 1.0 / 3)
        case .lanczos2: return lanczos(a, 2)
        case .lanczos3: return lanczos(a, 3)
        }
    }
    static func cubic(_ x: Double, b: Double, c: Double) -> Double {
        if x < 1 { return ((12 - 9 * b - 6 * c) * x * x * x + (-18 + 12 * b + 6 * c) * x * x + (6 - 2 * b)) / 6 }
        if x < 2 { return ((-b - 6 * c) * x * x * x + (6 * b + 30 * c) * x * x + (-12 * b - 48 * c) * x + (8 * b + 24 * c)) / 6 }
        return 0
    }
    static func lanczos(_ x: Double, _ n: Double) -> Double {
        if x == 0 { return 1 }
        if x >= n { return 0 }
        let p = Double.pi * x
        return n * sin(p) * sin(p / n) / (p * p)
    }

    /// Weights of one output sample at source coordinate u (pixel centres at j + 0.5). Minification widens the kernel by 1/scale;
    /// `area` integrates the exact footprint overlap. Weights are normalised.
    static func weights(_ c: Candidate, u: Double, scale: Double, count n: Int) -> (first: Int, w: [Double]) {
        let f = max(1, 1 / scale)
        if c == .area {
            let lo = u - 0.5 * f, hi = u + 0.5 * f
            let j0 = max(0, Int(floor(lo))), j1 = min(n - 1, Int(ceil(hi)) - 1)
            guard j0 <= j1 else { return (max(0, min(n - 1, Int(u))), [1]) }
            var w: [Double] = []
            for j in j0...j1 { w.append(max(0, min(hi, Double(j + 1)) - max(lo, Double(j)))) }
            let s = w.reduce(0, +)
            return (j0, s > 0 ? w.map { $0 / s } : w)
        }
        let r = radius(c) * f
        let j0 = max(0, Int(floor(u - r))), j1 = min(n - 1, Int(ceil(u + r)))
        var w: [Double] = []
        for j in j0...max(j0, j1) { w.append(kernel(c, (Double(j) + 0.5 - u) / f)) }
        let s = w.reduce(0, +)
        return (j0, abs(s) > 1e-12 ? w.map { $0 / s } : w)
    }

    /// 1-D resample of `src` to `count` outputs: output i covers source coordinate u = (i + 0.5 − phase) / scale.
    static func resample1D(_ src: [Double], count: Int, scale: Double, phase: Double, _ c: Candidate) -> [Double] {
        (0..<count).map { i in
            let (j0, w) = weights(c, u: (Double(i) + 0.5 - phase) / scale, scale: scale, count: src.count)
            var s = 0.0
            for (k, wk) in w.enumerated() { s += wk * src[min(src.count - 1, j0 + k)] }
            return s
        }
    }

    /// Separable 2-D resample of a source plane into a w×h block whose pixel (0, 0) centre maps to source coordinate
    /// ((0.5 − phaseX) / scaleX, (0.5 − phaseY) / scaleY).
    static func resample2D(_ src: ParityPlane, w: Int, h: Int, scaleX: Double, scaleY: Double, phaseX: Double, phaseY: Double, _ c: Candidate) -> ParityPlane {
        var rows = [[Double]](repeating: [], count: src.height)
        for y in 0..<src.height {
            let line = (0..<src.width).map { Double(src.data[y * src.width + $0]) }
            rows[y] = resample1D(line, count: w, scale: scaleX, phase: phaseX, c)
        }
        var out = ParityPlane(width: w, height: h)
        for x in 0..<w {
            let col = (0..<src.height).map { rows[$0][x] }
            let r = resample1D(col, count: h, scale: scaleY, phase: phaseY, c)
            for y in 0..<h { out.data[y * w + x] = Float(r[y]) }
        }
        return out
    }

    /// Training profile: a 1-D source profile and the measured Preview profile of the same training region.
    struct Profile: Sendable { let regionIndex: Int; let axis: String; let source: [Double]; let measured: [Double]; let basePhase: Double; let scale: Double }

    static func phases() -> [Double] {
        let n = ParityThresholdsV1.resamplingPhaseSteps
        return (0..<n).map { -0.5 + Double($0) / Double(n) }
    }

    /// Optional per-sample transform applied once AFTER the encoded-domain resample (parity-color-v3: the fixed forward colour
    /// transform). nil = v1 behaviour (prediction compared in the encoded domain). Kernels and candidates are unchanged.
    typealias Output = @Sendable (Double) -> Double

    /// Best phase offset (added to each profile's base phase) for one candidate on one axis, from training profiles only.
    static func fitPhase(_ c: Candidate, profiles: [Profile], output: Output? = nil) -> (phase: Double, rms: Double)? {
        guard !profiles.isEmpty, profiles.allSatisfy({ !ParityLayout.resolutionRegions[$0.regionIndex].validation }) else { return nil }
        var best: (Double, Double)?
        for p in phases() {
            var se = 0.0, n = 0
            for pr in profiles {
                let raw = resample1D(pr.source, count: pr.measured.count, scale: pr.scale, phase: pr.basePhase + p, c)
                let pred = output.map { f in raw.map(f) } ?? raw
                for i in 1..<max(1, pr.measured.count - 1) { let d = pred[i] - pr.measured[i]; se += d * d; n += 1 }
            }
            guard n > 0 else { continue }
            let rms = sqrt(se / Double(n))
            if best == nil || rms < best!.1 { best = (p, rms) }
        }
        return best
    }

    struct ValidationBlock: Sendable { let regionIndex: Int; let source: ParityPlane; let measured: ParityPlane; let basePhaseX: Double; let basePhaseY: Double; let scaleX: Double; let scaleY: Double }

    struct CandidateReport: Codable, Sendable {
        let candidate: Candidate
        let trainingRMSX: Double?, trainingRMSY: Double?   // recorded only; never used to select
        let phaseX: Double?, phaseY: Double?
        let validationRMS: Double?, validationMax: Double?
        let passed: Bool
    }
    struct Frozen: Codable, Sendable {
        let kind: String                 // "resampling"
        let thresholds: String
        let established: Bool
        let candidate: Candidate?
        let phaseX: Double?, phaseY: Double?
        let reports: [CandidateReport]
        let disagreement: String?
        let reason: String
        let calibrationParameters: String          // CAL-B parameter fingerprint this model was fitted with (D-042)
        let calibrationProvenance: ModelProvenance? // CAL-B provenance this model was fitted with (D-042)
        let provenance: ModelProvenance
        // parity-color-v3 (task 97). Absent in v1 files → refused by ParityG4V3.admitResampling.
        var colorContract: ColorContractIdentity? = nil
        var calibrationContract: ColorContractIdentity? = nil
        var outputTransform: String? = nil
        var contractBinding: String? = nil
    }

    static func predict(_ c: Candidate, _ b: ValidationBlock, phaseX: Double, phaseY: Double, output: Output? = nil) -> ParityPlane {
        var plane = resample2D(b.source, w: b.measured.width, h: b.measured.height, scaleX: b.scaleX, scaleY: b.scaleY,
                               phaseX: b.basePhaseX + phaseX, phaseY: b.basePhaseY + phaseY, c)
        if let f = output { for i in 0..<plane.data.count { plane.data[i] = Float(f(Double(plane.data[i]))) } }
        return plane
    }

    /// Deterministic selection (G0): fit phases on training profiles, validate each candidate on the validation blocks;
    /// 0 passing → unresolved; 1 → selected; several → unresolved if any passing pair materially disagrees, otherwise the lowest
    /// validation RMS (ties → candidate order). Training error is never used to choose.
    /// D-042 (owner Option A): RES-B consumes only the frozen CAL-B result; `calibration` is its parameter fingerprint and
    /// `calibrationProvenance` its provenance, both recorded in the frozen model. Nothing here changes CAL-B.
    static func establish(xProfiles: [Profile], yProfiles: [Profile], validation: [ValidationBlock], calibration: String,
                          calibrationProvenance: ModelProvenance? = nil, provenance: ModelProvenance, output: Output? = nil) -> Frozen {
        let margin = 2
        var reports: [CandidateReport] = []
        var predictions: [Candidate: [ParityPlane]] = [:]
        for c in Candidate.allCases {
            let fx = fitPhase(c, profiles: xProfiles, output: output), fy = fitPhase(c, profiles: yProfiles, output: output)
            guard let px = fx?.phase, let py = fy?.phase, !validation.isEmpty, validation.allSatisfy({ ParityLayout.resolutionRegions[$0.regionIndex].validation }) else {
                reports.append(CandidateReport(candidate: c, trainingRMSX: fx?.rms, trainingRMSY: fy?.rms, phaseX: fx?.phase, phaseY: fy?.phase,
                                               validationRMS: nil, validationMax: nil, passed: false)); continue
            }
            var se = 0.0, n = 0, mx = 0.0, preds: [ParityPlane] = []
            for b in validation {
                let pred = predict(c, b, phaseX: px, phaseY: py, output: output)
                preds.append(pred)
                for y in margin..<max(margin, b.measured.height - margin) { for x in margin..<max(margin, b.measured.width - margin) {
                    let d = Double(pred[x, y] - b.measured[x, y]); se += d * d; n += 1; mx = max(mx, abs(d))
                } }
            }
            let rms = n > 0 ? sqrt(se / Double(n)) : .infinity
            let pass = n > 0 && rms <= ParityThresholdsV1.resamplingValidationRMS && mx <= ParityThresholdsV1.resamplingValidationMax
            if pass { predictions[c] = preds }
            reports.append(CandidateReport(candidate: c, trainingRMSX: fx?.rms, trainingRMSY: fy?.rms, phaseX: px, phaseY: py,
                                           validationRMS: n > 0 ? rms : nil, validationMax: n > 0 ? mx : nil, passed: pass))
        }
        let passing = Candidate.allCases.filter { predictions[$0] != nil }
        func frozen(_ ok: Bool, _ c: Candidate?, _ dis: String?, _ why: String) -> Frozen {
            let r = reports.first { $0.candidate == c }
            return Frozen(kind: "resampling", thresholds: ParityThresholdsV1.fingerprint, established: ok, candidate: ok ? c : nil,
                          phaseX: ok ? r?.phaseX : nil, phaseY: ok ? r?.phaseY : nil, reports: reports, disagreement: dis, reason: why,
                          calibrationParameters: calibration, calibrationProvenance: calibrationProvenance, provenance: provenance)
        }
        if passing.isEmpty { return frozen(false, nil, nil, "no candidate passed validation") }
        if passing.count == 1 { return frozen(true, passing[0], nil, "single passing candidate") }
        var worst: (String, Double, Double)?
        for i in 0..<passing.count { for j in (i + 1)..<passing.count {
            var over = 0, total = 0, mx = 0.0
            for (a, b) in zip(predictions[passing[i]]!, predictions[passing[j]]!) {
                for k in 0..<a.data.count { let d = abs(Double(a.data[k] - b.data[k])); total += 1; mx = max(mx, d); if d > ParityThresholdsV1.resamplingDisagreementLevel { over += 1 } }
            }
            let frac = total > 0 ? Double(over) / Double(total) : 0
            if frac > ParityThresholdsV1.resamplingDisagreementFraction || mx > ParityThresholdsV1.resamplingDisagreementMax {
                let text = "\(passing[i].rawValue) vs \(passing[j].rawValue)"
                if worst == nil || mx > worst!.2 { worst = (text, frac, mx) }
            }
        } }
        if let w = worst {
            return frozen(false, nil, String(format: "%@: %.4f of pixels differ by > %.0f, max %.2f", w.0, w.1, ParityThresholdsV1.resamplingDisagreementLevel, w.2),
                          "passing candidates materially disagree")
        }
        let chosen = passing.min { a, b in
            let ra = reports.first { $0.candidate == a }!.validationRMS!, rb = reports.first { $0.candidate == b }!.validationRMS!
            return ra < rb || (ra == rb && Candidate.allCases.firstIndex(of: a)! < Candidate.allCases.firstIndex(of: b)!)
        }!
        return frozen(true, chosen, nil, "lowest validation RMS among \(passing.count) agreeing candidates")
    }
}
#endif
