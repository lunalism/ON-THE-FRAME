#if DEBUG
import Foundation

/// SP-EXPORT-E4D-COLOR-V3-G4-INTEGRATION-97 (pure, Foundation only): the G4 stages (CAL-B, CAL-V, RES-B, RES-C and the
/// frame fidelity they require) under the frozen `parity-color-v3` contract. Every colour step calls the tested v3 core
/// (`ColorV3`, `CalibrationV3`, `ColorContractValidation`); nothing here fits a gamma, adds a parameter or changes a threshold.
/// Order (contract field `order`): decode → E-clip → resample (encoded) → γ 1.96 → primaries → G-clip → sRGB OETF → CAL-B.
/// The CAL-B affine (out = clamp01(M · capture + b)) is applied to the CAPTURE only; the v3 forward transform is applied to the
/// PREDICTION only, once, after the encoded-domain resample. Neither is applied twice.
enum ParityG4V3 {
    typealias T = ParityThresholdsV1
    static let managedTag = ParityLedgerV3.managedLabel

    // MARK: forward transform (no Lab work; identical arithmetic to ColorV3.predict(...).p)

    struct Forward: Sendable {
        let primaries: String
        let matrix: [[Double]]
        init?(primaries: String) {
            guard let m = ColorV3.declaredToLinearSRGB(primaries) else { return nil }
            self.primaries = primaries; matrix = m
        }
        /// Encoded R'G'B' (0…1, already resampled) → P (0…1, floating point).
        func callAsFunction(_ encoded: [Double]) -> [Double] {
            let lin = encoded.map(ColorV3.displayLinear)
            return ColorV3.apply(matrix, lin).map { ColorV3.srgbOETF(min(1, max(0, $0))) }
        }
        /// Neutral (R' = G' = B') sample on the 0…255 scale → luma of P on the 0…255 scale (RES planes are neutral luma).
        func neutralLuma255(_ v: Double) -> Double {
            let p = self([v / 255, v / 255, v / 255])
            return 255 * (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2])
        }
        var description: String {
            "\(ParityG4V3.managedTag): encoded-domain resample, then once per sample V^\(ColorContractV3.value("gamma") ?? "?") → \(primaries) → linear sRGB → G-clip → sRGB OETF"
        }
    }

    /// The managed source declaration for a decoded file, or the reason it is not usable (managed verdicts INCONCLUSIVE).
    static func managedDeclaration(_ i: DeclaredInterpretation) -> (declaration: ColorDeclaration?, note: String) {
        let s = SourceDeclarationV3.make(i)
        if let d = s.managed { return (d, "managed input \(d.primaries ?? "?")/\(d.transfer ?? "?")/\(d.matrix ?? "?") decoded range \(d.fullRange == true ? "full" : "video") (C5 eligible: \(s.c5Eligible))") }
        return (nil, s.managedProblem ?? "unsupported")
    }

    // MARK: CAL-B / CAL-V

    struct PatchTarget: Sendable {
        let index: Int
        let decoded: ColorV3.Decoded
        let prediction: ColorV3.Prediction
    }
    /// Target P per patch from the source patch means (Y'CbCr 0…255): declared matrix + decoded range → E-clip → predict.
    static func calibrationTargets(sourceMeans: [Int: [Double]], declaration d: ColorDeclaration) -> [PatchTarget] {
        guard let m = d.matrix, let full = d.fullRange, let p = d.primaries else { return [] }
        return sourceMeans.keys.sorted().compactMap { i in
            guard let s = sourceMeans[i], s.count == 3, let dec = ColorV3.decode(y: s[0], cb: s[1], cr: s[2], matrix: m, fullRange: full),
                  let pred = ColorV3.predict(encoded: dec.encoded, primaries: p) else { return nil }
            return PatchTarget(index: i, decoded: dec, prediction: pred)
        }
    }
    /// Pairs captured means (sRGB encoded 0…1) with the targets. Patches without both values are left out and counted.
    static func calibrationPatches(captured: [Int: [Double]], targets: [PatchTarget]) -> [CalibrationV3.Patch] {
        targets.compactMap { t in captured[t.index].map { CalibrationV3.Patch(index: t.index, capture: $0, target: t.prediction.p) } }
    }
    static func clipSummary(_ targets: [PatchTarget]) -> String {
        let e = targets.filter { $0.decoded.clippedChannels > 0 }.map(\.index)
        let g = targets.filter { $0.prediction.clipped }
        let loss = g.map(\.prediction.gamutLossDE00).max() ?? 0
        return "E-clip patches \(e), G-clip patches \(g.map(\.index)) (max |Δ| \(String(format: "%.6f", g.map(\.prediction.maxAbsClip).max() ?? 0)), max gamut loss ΔE00 \(String(format: "%.4f", loss))); none excluded"
    }

    static func parameterFingerprint(_ m: [[Double]]) -> String { Fingerprint.fnv(m.flatMap { $0 }.map { String(format: "%.9f", $0) }.joined(separator: ",")) }
    static func binding(_ c: Calibration.Frozen) -> String {
        Fingerprint.fnv([c.parameters, c.colorContract?.id ?? "-", c.colorContract?.fingerprint ?? "-", c.thresholds,
                         c.aggregateVerdict?.rawValue ?? "-", c.valid ? "valid" : "invalid"].joined(separator: "|"))
    }

    /// Fit on training patches, evaluate the three parts separately, freeze with the v3 identity and a binding fingerprint.
    static func freezeCalibration(patches: [CalibrationV3.Patch], declaration: ColorDeclaration, provenance: ModelProvenance,
                                  clipNote: String) -> (frozen: Calibration.Frozen, outcome: CalibrationV3.Outcome?) {
        let training = ParityLayout.trainingPatches.filter { i in patches.contains { $0.index == i } }
        let validation = ParityLayout.validationPatches.filter { i in patches.contains { $0.index == i } }
        func make(_ m: [[Double]], _ o: CalibrationV3.Outcome?, _ why: String) -> Calibration.Frozen {
            var f = Calibration.Frozen(kind: "calibration", thresholds: T.fingerprint, matrix: m, trainingIndices: training, validationIndices: validation,
                                       referenceDeclaration: declaration, validationDE: o?.holdoutDE ?? Distribution([]), greyMonotonic: o?.greyMonotonic ?? false,
                                       valid: o?.aggregate == .pass, reason: why, provenance: provenance, storedParameters: parameterFingerprint(m))
            f.colorContract = ColorContractV3.identity
            f.admissibility = o?.admissibility
            f.validationVerdict = o?.validationVerdict
            f.aggregateVerdict = o?.aggregate ?? .inconclusive
            f.targetDeclaration = declaration
            f.contractBinding = binding(f)
            return f
        }
        guard patches.count == ParityLayout.patchCount, validation.count == ParityLayout.validationPatches.count else {
            return (make([], nil, "expected \(ParityLayout.patchCount) patches with capture and target, got \(patches.count)"), nil)
        }
        guard let r = CalibrationV3.evaluate(patches: patches) else { return (make([], nil, "fit failed (singular or too few training patches)"), nil) }
        let o = r.outcome, a = o.admissibility
        let why = String(format: "%@: admissibility %@ (max |M−I| %.5f, max |b| %.5f%@); holdout ΔE00 lab.v2 mean %.3f max %.3f (limits %.1f/%.1f, %d/%d) %@; grey monotonic %@; validation %@; aggregate %@; %@",
                         managedTag, a.admissible ? "valid" : "VIOLATED", a.maxMatrixDeviation, a.maxOffset, a.violations.isEmpty ? "" : "; " + a.violations.joined(separator: "; "),
                         o.holdoutDE.mean, o.holdoutDE.max, T.calibrationValidationMeanDE, T.calibrationValidationMaxDE, o.holdoutComputed, o.holdoutExpected,
                         o.holdoutPass ? "pass" : "FAIL", o.greyMonotonic ? "yes" : "NO", o.validationVerdict.rawValue, o.aggregate.rawValue, clipNote)
        return (make(r.stored, o, why), o)
    }

    /// A frozen CAL-B is usable under v3 only with the exact contract identity, an intact binding and parameter fingerprint,
    /// a PASS aggregate whose matrix is still admissible, threshold v1 and a matching environment. Never refitted.
    static func admitCalibration(_ c: Calibration.Frozen?, provenance: ModelProvenance) -> (usable: Bool, note: String) {
        guard let c else { return (false, "no frozen CAL-B supplied") }
        if case .rejected(let why) = ColorContractValidation.admit(c.colorContract) { return (false, "CAL-B refused: \(why)") }
        guard c.integrityOK else { return (false, "CAL-B refused: parameter fingerprint mismatch (stored \(c.storedParameters), recomputed \(c.parameters))") }
        guard c.contractBinding == binding(c) else { return (false, "CAL-B refused: contract binding mismatch (model altered)") }
        guard c.thresholds == T.fingerprint else { return (false, "CAL-B refused: thresholds differ") }
        guard c.valid, c.aggregateVerdict == .pass else { return (false, "CAL-B not valid: aggregate \(c.aggregateVerdict?.rawValue ?? "missing"): \(c.reason)") }
        guard CalibrationV3.admissibility(c.matrix).admissible else { return (false, "CAL-B refused: stored matrix not admissible") }
        guard c.provenance.environmentMatches(provenance) else { return (false, "CAL-B environment differs") }
        return (true, "frozen CAL-B \(c.parameters) (\(ColorContractV3.id))")
    }

    /// CAL-V: holdout residual of the frozen CAL-B in lab.v2 (recorded, never fitted).
    static func calibrationResidual(_ c: Calibration.Frozen, patches: [CalibrationV3.Patch]) -> Distribution {
        var des: [Double] = []
        for p in patches where ParityLayout.validationPatches.contains(p.index) {
            guard let o = ColorV3.labV2Observed(calibratedCapture: CalibrationV3.apply(c.matrix, p.capture)),
                  let e = ColorV3.labFromLinearSRGB(p.target.map(ColorV3.srgbEOTF)) else { continue }
            des.append(ColorMath.deltaE2000(o, e))
        }
        return Distribution(des)
    }

    // MARK: RES-B / RES-C

    /// Encoded neutral source plane on 0…255 with E-clip: each pixel decoded with the declared matrix and decoded range,
    /// clamped to 0…1, then its luma. Also returns the largest chroma departure (recorded: RES patterns are neutral).
    static func resamplingSource(_ f: NativeFrame, declaration d: ColorDeclaration) -> (plane: ParityPlane, maxChroma: Double)? {
        guard let m = d.matrix, let full = d.fullRange else { return nil }
        var out = ParityPlane(width: f.width, height: f.height), maxC = 0.0
        for i in 0..<out.data.count {
            let y = Double(f.y.data[i]), cb = Double(f.cb.data[i]), cr = Double(f.cr.data[i])
            guard let dec = ColorV3.decode(y: y, cb: cb, cr: cr, matrix: m, fullRange: full) else { return nil }
            maxC = max(maxC, abs(cb - 128), abs(cr - 128))
            out.data[i] = Float(255 * (0.2126 * dec.encoded[0] + 0.7152 * dec.encoded[1] + 0.0722 * dec.encoded[2]))
        }
        return (out, maxC)
    }
    static func resamplingOutput(_ fwd: Forward) -> Resampling.Output { { v in fwd.neutralLuma255(v) } }

    static func binding(_ r: Resampling.Frozen) -> String {
        Fingerprint.fnv([r.candidate?.rawValue ?? "-", r.phaseX.map { String(format: "%.9f", $0) } ?? "-", r.phaseY.map { String(format: "%.9f", $0) } ?? "-",
                         r.calibrationParameters, r.colorContract?.id ?? "-", r.colorContract?.fingerprint ?? "-",
                         r.calibrationContract?.fingerprint ?? "-", r.thresholds, r.established ? "established" : "unresolved"].joined(separator: "|"))
    }

    /// RES-B: the six unchanged candidates, phases fitted on training profiles only, validated on the validation blocks,
    /// with the v3 forward transform applied once after each encoded-domain prediction. Thresholds v1 unchanged.
    static func establishResampling(x: [Resampling.Profile], y: [Resampling.Profile], validation: [Resampling.ValidationBlock],
                                    calibration c: Calibration.Frozen, provenance: ModelProvenance, forward: Forward) -> Resampling.Frozen {
        var f = Resampling.establish(xProfiles: x, yProfiles: y, validation: validation, calibration: c.parameters,
                                     calibrationProvenance: c.provenance, provenance: provenance, output: resamplingOutput(forward))
        f.colorContract = ColorContractV3.identity
        f.calibrationContract = c.colorContract
        f.outputTransform = forward.description
        f.contractBinding = binding(f)
        return f
    }

    /// RES-B usable under v3: exact identity, the same contract as the supplied (usable) CAL-B, the same CAL-B parameters,
    /// an intact binding, established, threshold v1, matching environment and a recorded v3 output transform.
    static func admitResampling(_ r: Resampling.Frozen?, calibration c: Calibration.Frozen?, calibrationUsable: Bool,
                                provenance: ModelProvenance) -> (usable: Bool, note: String) {
        guard let r else { return (false, "no frozen RES-B supplied") }
        guard calibrationUsable, let c else { return (false, "CAL-B not usable; RES-B depends on it (D-042)") }
        if case .rejected(let why) = ColorContractValidation.admitChain(calibration: c.colorContract, resampling: r.colorContract) { return (false, "RES-B refused: \(why)") }
        guard r.calibrationContract == c.colorContract else { return (false, "RES-B refused: fitted under another CAL-B contract") }
        guard r.calibrationParameters == c.parameters else { return (false, "RES-B refused: fitted with another CAL-B fingerprint") }
        guard r.contractBinding == binding(r) else { return (false, "RES-B refused: contract binding mismatch (model altered)") }
        guard r.outputTransform != nil else { return (false, "RES-B refused: no v3 output transform recorded") }
        guard r.thresholds == T.fingerprint else { return (false, "RES-B refused: thresholds differ") }
        guard r.established, let cand = r.candidate, r.phaseX != nil, r.phaseY != nil else { return (false, "RES-B unresolved: \(r.reason)") }
        guard r.provenance.environmentMatches(provenance) else { return (false, "RES-B environment differs") }
        return (true, "frozen RES-B \(cand.rawValue) (\(ColorContractV3.id))")
    }

    /// RES-C: validation fidelity of the frozen RES-B (frozen candidate and phases, same forward transform once).
    static func resamplingFidelity(_ r: Resampling.Frozen, validation: [Resampling.ValidationBlock], forward: Forward) -> (rms: Double, max: Double, n: Int)? {
        guard let cand = r.candidate, let px = r.phaseX, let py = r.phaseY else { return nil }
        var se = 0.0, n = 0, mx = 0.0
        let out = resamplingOutput(forward)
        for b in validation {
            let pred = Resampling.predict(cand, b, phaseX: px, phaseY: py, output: out)
            for y in 2..<max(2, b.measured.height - 2) { for x in 2..<max(2, b.measured.width - 2) {
                let d = Double(pred[x, y] - b.measured[x, y]); se += d * d; n += 1; mx = max(mx, abs(d))
            } }
        }
        return (n > 0 ? sqrt(se / Double(n)) : .nan, mx, n)
    }

    // MARK: frame fidelity (G4 frame check; same thresholds as v1)

    /// Export decoded with its declared matrix/range and E-clip, resampled per channel in the encoded domain with the frozen
    /// candidate and phases, transformed once to P, compared with the CAL-B-calibrated capture (managed representation).
    static func frameFidelity(export: NativeFrame, calibrated preview: PreviewCrop, model: Resampling.Frozen, placed: PlacedSource,
                              exclude: [Bool]?, prefix: String) -> ParityCheck {
        let name = "\(prefix).fidelity"
        guard model.established, let c = model.candidate, let px = model.phaseX, let py = model.phaseY else {
            return ParityCheck(name: name, verdict: .inconclusive, detail: "\(managedTag): resampling model not established")
        }
        let d = export.declaration
        guard let prim = d.primaries, ColorV3.supportedPrimaries.contains(prim), d.transfer == ColorV3.supportedTransfer,
              let m = d.matrix, ColorV3.supportedMatrices.contains(m), let full = d.fullRange, let fwd = Forward(primaries: prim) else {
            return ParityCheck(name: name, verdict: .inconclusive, detail: "\(managedTag): output declaration incomplete or outside parity-color-v3 (\(ParityJudge.describe(d)))")
        }
        var r = ParityPlane(width: export.width, height: export.height), g = r, b = r
        for i in 0..<r.data.count {
            guard let v = ColorV3.decode(y: Double(export.y.data[i]), cb: Double(export.cb.data[i]), cr: Double(export.cr.data[i]), matrix: m, fullRange: full) else { continue }
            r.data[i] = Float(v.encoded[0] * 255); g.data[i] = Float(v.encoded[1] * 255); b.data[i] = Float(v.encoded[2] * 255)
        }
        let map = preview.mapping, cw = preview.r.width, ch = preview.r.height
        let phaseX = map.originX + px, phaseY = map.originY + py
        let pr = Resampling.resample2D(r, w: cw, h: ch, scaleX: map.scaleX, scaleY: map.scaleY, phaseX: phaseX, phaseY: phaseY, c)
        let pg = Resampling.resample2D(g, w: cw, h: ch, scaleX: map.scaleX, scaleY: map.scaleY, phaseX: phaseX, phaseY: phaseY, c)
        let pb = Resampling.resample2D(b, w: cw, h: ch, scaleX: map.scaleX, scaleY: map.scaleY, phaseX: phaseX, phaseY: phaseY, c)
        let (sx0, sy0) = map.crop(placed.x, placed.y), (sx1, sy1) = map.crop(placed.x + placed.w, placed.y + placed.h)
        let mgn = Double(T.fidelityInteriorMargin)
        var total = 0, within = 0
        for y in 0..<ch { for x in 0..<cw {
            let fx = Double(x) + 0.5, fy = Double(y) + 0.5
            guard fx >= sx0 + mgn, fx <= sx1 - mgn, fy >= sy0 + mgn, fy <= sy1 - mgn else { continue }
            let k = y * cw + x
            if let exclude, exclude[k] { continue }
            total += 1
            let p = fwd([Double(pr.data[k]) / 255, Double(pg.data[k]) / 255, Double(pb.data[k]) / 255]).map { $0 * 255 }
            let dd = max(abs(p[0] - Double(preview.r.data[k])), abs(p[1] - Double(preview.g.data[k])), abs(p[2] - Double(preview.b.data[k])))
            if dd <= Double(T.fidelityChannel) { within += 1 }
        }}
        guard total > 0 else { return ParityCheck(name: name, verdict: .inconclusive, detail: "\(managedTag): no interior pixels") }
        let frac = Double(within) / Double(total)
        return ParityCheck(name: name, verdict: frac >= T.fidelityFraction ? .pass : .fail,
                           detail: String(format: "%@: interior pixels within ±%d: %d/%d (%.4f), model %@ (managed colour agreement, not raw pixel parity)",
                                          managedTag, T.fidelityChannel, within, total, frac, c.rawValue),
                           values: ["fraction": frac, "total": Double(total)])
    }
}
#endif
