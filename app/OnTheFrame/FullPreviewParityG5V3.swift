#if DEBUG
import Foundation

/// SP-EXPORT-E4D-COLOR-V3-G5-INTEGRATION-98 (pure, Foundation only): G5 (C1–C7) helpers under the frozen `parity-color-v3`
/// contract. Managed colour = v3 prediction (declared matrix + decoded range → E-clip → γ 1.96 → primaries → G-clip → OETF)
/// against the CAL-B-calibrated capture in lab.v2. Spatial detection (masks, edges, geometry) stays a RAW geometric verdict:
/// where it needs pixel levels, the reference is only brought into the same representation as the calibrated crop and the
/// representation is recorded (`representation.managedCalibrated`), never turned into a colour verdict.
enum ParityG5V3 {
    typealias T = ParityThresholdsV1
    static let tag = ParityLedgerV3.managedLabel
    static let representationKey = "representation.managedCalibrated"

    /// The managed declaration of a decoded file (source or output), nil outside v3 (missing / partial / contradictory / unsupported).
    static func managedDeclaration(_ i: DeclaredInterpretation) -> ColorDeclaration? { SourceDeclarationV3.make(i).managed }

    /// Per-patch managed ΔE00: expected = v3 prediction of a Y'CbCr mean (0…255) under `d`; observed = calibrated capture (0…1).
    struct PatchDE: Sendable { let des: [Double]; let clipped: Int; let maxGamutLoss: Double; let pairs: Int }
    static func managedPatchDE(expectedYCbCr: [[Double]?], observed: [[Double]?], declaration d: ColorDeclaration) -> PatchDE? {
        guard let m = d.matrix, let full = d.fullRange, let p = d.primaries, ColorV3.supportedPrimaries.contains(p),
              d.transfer == ColorV3.supportedTransfer else { return nil }
        var des: [Double] = [], clipped = 0, loss = 0.0, pairs = 0
        for (e, o) in zip(expectedYCbCr, observed) {
            guard let e, e.count == 3, let o, o.count == 3 else { continue }
            pairs += 1
            guard let dec = ColorV3.decode(y: e[0], cb: e[1], cr: e[2], matrix: m, fullRange: full),
                  let pred = ColorV3.predict(encoded: dec.encoded, primaries: p),
                  let le = ColorV3.labV2Expected(pred), let lo = ColorV3.labV2Observed(calibratedCapture: o) else { continue }
            if pred.clipped || dec.clippedChannels > 0 { clipped += 1 }
            loss = max(loss, pred.gamutLossDE00)
            des.append(ColorMath.deltaE2000(lo, le))
        }
        return PatchDE(des: des, clipped: clipped, maxGamutLoss: loss, pairs: pairs)
    }

    /// Mask detection only: a reference Y'CbCr cell mean (0…255, encoded) → predicted calibrated-capture R'G'B' (0…1), so the
    /// calibrated crop is differenced in one representation. nil when the output declaration is outside v3.
    static func referencePrediction(output d: ColorDeclaration?) -> (@Sendable (Double, Double, Double) -> [Double])? {
        guard let d, let m = d.matrix, let full = d.fullRange, let p = d.primaries, let fwd = ParityG4V3.Forward(primaries: p),
              d.transfer == ColorV3.supportedTransfer, ColorV3.supportedMatrices.contains(m) else { return nil }
        return { y, cb, cr in
            guard let dec = ColorV3.decode(y: y, cb: cb, cr: cr, matrix: m, fullRange: full) else { return [0, 0, 0] }
            return fwd(dec.encoded)
        }
    }

    /// gapBlackPreview (managed per the v3 table): mean luma of the CAL-B-calibrated crop on the existing 8-px grid, ≤ 8.
    static func gapBlackPreview(calibrated c: PreviewCrop?, prefix: String) -> ParityCheck {
        let name = "\(prefix).gapBlackPreview"
        guard let c else { return ParityCheck(name: name, verdict: .inconclusive, detail: "\(tag): no frozen parity-color-v3 CAL-B (managed gap check needs the calibrated capture)") }
        var s = 0.0, n = 0
        for y in stride(from: 0, to: c.r.height, by: 8) { for x in stride(from: 0, to: c.r.width, by: 8) {
            s += 0.2126 * Double(c.r[x, y]) + 0.7152 * Double(c.g[x, y]) + 0.0722 * Double(c.b[x, y]); n += 1
        } }
        let m = n == 0 ? 0 : s / Double(n)
        return ParityCheck(name: name, verdict: n > 0 && m <= 8 ? .pass : (n == 0 ? .inconclusive : .fail),
                           detail: String(format: "%@: calibrated preview mean luma %.2f (gap)", tag, m), values: ["meanLuma": m])
    }

    /// Records the representation of a geometric check without changing its detail text or verdict.
    static func tagRepresentation(_ c: ParityCheck, calibrated: Bool) -> ParityCheck {
        var v = c.values; v[representationKey] = calibrated ? 1 : 0
        return ParityCheck(name: c.name, verdict: c.verdict, detail: c.detail, values: v)
    }
    static func isPreviewMaskCheck(_ name: String) -> Bool {
        let leaf = name.split(separator: ".").last.map(String.init) ?? ""
        return leaf.hasPrefix("previewMask") || leaf == "maskIoU" || leaf == "maskBoundingBox"
    }

    /// C1/C2 Preview ROIs are comparable only when both scenarios were calibrated with the same frozen v3 CAL-B.
    /// Returns nil when comparable, otherwise the reason (previewPixels INCONCLUSIVE).
    static func previewComparability(_ a: ScenarioSummary, _ b: ScenarioSummary) -> String? {
        guard a.colorContract == ColorContractV3.identity, b.colorContract == ColorContractV3.identity else { return "\(tag): scenario not judged under parity-color-v3" }
        guard let ca = a.calibrationParameters, let cb = b.calibrationParameters else { return "\(tag): calibrated preview ROI without a frozen CAL-B" }
        guard ca == cb else { return "\(tag): preview ROIs calibrated with different CAL-B (\(ca) vs \(cb))" }
        return nil
    }

    /// C5.<scenario>: every frame that produced C5 judgments must carry BOTH exportFollowsDeclaration and previewFollowsDeclaration,
    /// unless its source interpretation was unusable (sourceInterpretation, INCONCLUSIVE). Any FAIL stays visible; missing evidence
    /// is INCONCLUSIVE; PASS only when every required judgment is PASS.
    static func c5ScenarioVerdict(_ verdicts: [String: ParityVerdict]) -> (verdict: ParityVerdict, detail: String) {
        guard !verdicts.isEmpty else { return (.inconclusive, "no C5 frame judgments") }
        var frames: [String: [String: ParityVerdict]] = [:]
        for (k, v) in verdicts {
            let parts = k.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            frames[parts[0], default: [:]][parts[1]] = v
        }
        let incomplete = frames.filter { $0.value["sourceInterpretation"] == nil && ($0.value["exportFollowsDeclaration"] == nil || $0.value["previewFollowsDeclaration"] == nil) }.keys.sorted()
        let all = Array(verdicts.values)
        if all.contains(.fail) { return (.fail, "a required C5 judgment failed (\(frames.count) frames)") }
        if !incomplete.isEmpty || frames.isEmpty { return (.inconclusive, "frames missing export or preview C5 judgment: \(incomplete)") }
        return all.allSatisfy { $0 == .pass } ? (.pass, "export (lab.v1) and \(tag) preview (lab.v2) follow the declaration in \(frames.count) frames")
                                              : (.inconclusive, "not all C5 judgments PASS (\(frames.count) frames)")
    }
}
#endif
