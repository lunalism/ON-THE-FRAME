#if DEBUG
import Foundation

/// SP-EXPORT-E4D-G1 (pure, Foundation only): judgments of one measured frame and the cross-run D-041 conformance (C1–C7).
/// Every judgment states its prerequisites; a missing prerequisite yields INCONCLUSIVE / NOT VERIFIED / NOT RUN, never PASS.

/// What a run may rely on (G0 conditional failure rules).
struct ParityPrerequisites: Codable, Sendable {
    var captureValid: Bool
    var calibrationValid: Bool          // a frozen, valid CAL-B whose environment matches this run
    var calibrationNote: String
    var resamplingEstablished: Bool     // a frozen, established RES-B whose environment matches this run
    var resamplingNote: String
}

enum ParityJudge {
    typealias T = ParityThresholdsV1

    // MARK: preview conversion

    /// Calibrated Preview (reference R'G'B' scaled 0…255) from the raw sRGB crop with the frozen matrix.
    static func calibrated(_ c: PreviewCrop, matrix m: [[Double]]) -> PreviewCrop {
        var r = c.r, g = c.g, b = c.b
        for i in 0..<c.r.data.count {
            let v = Calibration.apply(m, [Double(c.r.data[i]) / 255, Double(c.g.data[i]) / 255, Double(c.b.data[i]) / 255])
            r.data[i] = Float(v[0] * 255); g.data[i] = Float(v[1] * 255); b.data[i] = Float(v[2] * 255)
        }
        return PreviewCrop(r: r, g: g, b: b, mapping: c.mapping)
    }

    // MARK: masks

    struct MaskResult: Codable, Sendable {
        var exportPixels = 0, exportOutsideLayout = 0
        var exportPixelsPerBox: [Int] = []
        var previewCore = 0, previewEdge = 0, previewMask = 0, previewOutside = 0, previewFalsePositive = 0
        var iou: Double?
        var exportBox: [Double]?, previewBox: [Double]?
        var boxDelta: Double?
    }

    /// Layer mask of one frame. `layout` lists the expected overlay boxes in output pixels (empty: no overlay expected;
    /// nil: layout unknown → INCONCLUSIVE). `preview` is the calibrated crop or nil (calibration invalid).
    /// `referencePrediction` (parity-color-v3, task 98): when the Preview crop is CAL-B-calibrated, each reference cell mean is
    /// brought into the same representation before differencing. Detection only — the mask verdicts stay geometric (raw).
    static func masks(frame: NativeFrame, reference: NativeFrame, layout: [[Double]]?, preview: PreviewCrop?, prefix: String,
                      calibrationNote: String, referencePrediction: (@Sendable (Double, Double, Double) -> [Double])? = nil) -> ([ParityCheck], MaskResult) {
        var out: [ParityCheck] = [], r = MaskResult()
        guard frame.width == reference.width, frame.height == reference.height else {
            return ([ParityCheck(name: "\(prefix).mask", verdict: .inconclusive, detail: "frame and reference sizes differ")], r)
        }
        let w = frame.width, h = frame.height
        var native = [Bool](repeating: false, count: w * h)
        var bx0 = Int.max, by0 = Int.max, bx1 = -1, by1 = -1
        for i in 0..<(w * h) {
            let dy = abs(Int(frame.y.data[i].rounded()) - Int(reference.y.data[i].rounded()))
            let dc = max(abs(Int(frame.cb.data[i].rounded()) - Int(reference.cb.data[i].rounded())), abs(Int(frame.cr.data[i].rounded()) - Int(reference.cr.data[i].rounded())))
            if dy > T.maskDeltaY || dc > T.maskDeltaC {
                native[i] = true; r.exportPixels += 1
                let x = i % w, y = i / w
                bx0 = min(bx0, x); by0 = min(by0, y); bx1 = max(bx1, x); by1 = max(by1, y)
            }
        }
        if r.exportPixels > 0 { r.exportBox = [Double(bx0), Double(by0), Double(bx1 + 1), Double(by1 + 1)] }
        guard let layout else {
            out.append(ParityCheck(name: "\(prefix).maskLayout", verdict: .inconclusive, detail: "overlay layout unknown"))
            return (out, r)
        }
        // Export false positives: mask pixels outside every layout box dilated by 8 native px.
        let d = Double(T.exportFalsePositiveDilation)
        func inBox(_ x: Int, _ y: Int, _ b: [Double], _ pad: Double) -> Bool {
            Double(x) + 0.5 >= b[0] - pad && Double(x) + 0.5 <= b[2] + pad && Double(y) + 0.5 >= b[1] - pad && Double(y) + 0.5 <= b[3] + pad
        }
        r.exportPixelsPerBox = layout.map { _ in 0 }
        for i in 0..<(w * h) where native[i] {
            let x = i % w, y = i / w
            var inside = false
            for (k, b) in layout.enumerated() where inBox(x, y, b, 0) { r.exportPixelsPerBox[k] += 1 }
            for b in layout where inBox(x, y, b, d) { inside = true; break }
            if !inside { r.exportOutsideLayout += 1 }
        }
        out.append(ParityCheck(name: "\(prefix).exportMaskFalsePositive", verdict: r.exportOutsideLayout <= T.exportFalsePositiveMax ? .pass : .fail,
                               detail: "export mask pixels outside the layout (+\(T.exportFalsePositiveDilation) px): \(r.exportOutsideLayout); total \(r.exportPixels)",
                               values: ["outside": Double(r.exportOutsideLayout), "total": Double(r.exportPixels)]))
        if layout.isEmpty {
            out.append(ParityCheck(name: "\(prefix).exportMaskEmpty", verdict: r.exportPixels == 0 ? .pass : .fail, detail: "no overlay expected; export mask pixels \(r.exportPixels)"))
        } else {
            let small = r.exportPixelsPerBox.enumerated().filter { $0.element < T.maskMinimumCoreNativePixels }
            out.append(ParityCheck(name: "\(prefix).exportMaskSize", verdict: small.isEmpty ? .pass : .fail,
                                   detail: "mask pixels per expected layer \(r.exportPixelsPerBox) (minimum \(T.maskMinimumCoreNativePixels)); an empty or small mask cannot pass"))
        }
        guard let preview else {
            out.append(ParityCheck(name: "\(prefix).previewMask", verdict: .inconclusive, detail: "calibration not usable: \(calibrationNote)"))
            return (out, r)
        }
        // Coverage of each Preview pixel by native mask pixels (native pixel centres assigned to the crop cell that contains them).
        let cw = preview.r.width, ch = preview.r.height
        var hit = [Int](repeating: 0, count: cw * ch), all = [Int](repeating: 0, count: cw * ch)
        var refY = [Double](repeating: 0, count: cw * ch), refCb = refY, refCr = refY
        for y in 0..<h { for x in 0..<w {
            let (cx, cy) = preview.mapping.crop(Double(x) + 0.5, Double(y) + 0.5)
            let ix = Int(floor(cx)), iy = Int(floor(cy))
            guard ix >= 0, iy >= 0, ix < cw, iy < ch else { continue }
            let k = iy * cw + ix, i = y * w + x
            all[k] += 1; if native[i] { hit[k] += 1 }
            refY[k] += Double(reference.y.data[i]); refCb[k] += Double(reference.cb.data[i]); refCr[k] += Double(reference.cr.data[i])
        }}
        var core = [Bool](repeating: false, count: cw * ch), edge = core, pmask = core
        var px0 = Int.max, py0 = Int.max, px1 = -1, py1 = -1
        for k in 0..<(cw * ch) where all[k] > 0 {
            let f = Double(hit[k]) / Double(all[k])
            if f >= T.coverageCore { core[k] = true; r.previewCore += 1 } else if f >= T.coverageEdgeLow { edge[k] = true; r.previewEdge += 1 }
            let rgb = (ColorMath.clamp(Double(preview.r.data[k]) / 255), ColorMath.clamp(Double(preview.g.data[k]) / 255), ColorMath.clamp(Double(preview.b.data[k]) / 255))
            guard let ycc = ColorMath.ycbcr(rgb, matrix: "ITU_R_709_2") else { continue }
            let n = Double(all[k])
            var ry = refY[k] / n, rcb = refCb[k] / n, rcr = refCr[k] / n
            if let predict = referencePrediction {
                let q = predict(ry, rcb, rcr)
                guard let r = ColorMath.ycbcr((ColorMath.clamp(q[0]), ColorMath.clamp(q[1]), ColorMath.clamp(q[2])), matrix: "ITU_R_709_2") else { continue }
                ry = r.y; rcb = r.cb; rcr = r.cr
            }
            let dy = abs(ycc.y - ry), dc = max(abs(ycc.cb - rcb), abs(ycc.cr - rcr))
            if dy > Double(T.maskDeltaY) || dc > Double(T.maskDeltaC) {
                pmask[k] = true; r.previewMask += 1
                px0 = min(px0, k % cw); py0 = min(py0, k / cw); px1 = max(px1, k % cw); py1 = max(py1, k / cw)
            }
        }
        // Preview false positives: mask cells outside the expected region (core ∪ edge) dilated by 2 Preview px.
        let pad = T.previewFalsePositiveDilation
        var expected = [Bool](repeating: false, count: cw * ch)
        for k in 0..<(cw * ch) where core[k] || edge[k] {
            let x = k % cw, y = k / cw
            for yy in max(0, y - pad)...min(ch - 1, y + pad) { for xx in max(0, x - pad)...min(cw - 1, x + pad) { expected[yy * cw + xx] = true } }
        }
        for k in 0..<(cw * ch) where !expected[k] { r.previewOutside += 1; if pmask[k] { r.previewFalsePositive += 1 } }
        let fpLimit = min(Double(T.previewFalsePositiveMax), Double(r.previewOutside) * T.previewFalsePositiveFraction)
        out.append(ParityCheck(name: "\(prefix).previewMaskFalsePositive", verdict: Double(r.previewFalsePositive) <= fpLimit ? .pass : .fail,
                               detail: "preview mask cells outside the expected region: \(r.previewFalsePositive) of \(r.previewOutside) (limit \(String(format: "%.1f", fpLimit)))",
                               values: ["falsePositive": Double(r.previewFalsePositive), "outside": Double(r.previewOutside)]))
        if layout.isEmpty {
            out.append(ParityCheck(name: "\(prefix).previewMaskEmpty", verdict: Double(r.previewMask) <= fpLimit ? .pass : .fail, detail: "no overlay expected; preview mask cells \(r.previewMask)"))
            return (out, r)
        }
        // IoU on core cells (edge-band cells excluded from both sets).
        var inter = 0, union = 0
        for k in 0..<(cw * ch) where !edge[k] {
            if core[k] && pmask[k] { inter += 1 }
            if core[k] || pmask[k] { union += 1 }
        }
        if r.previewCore == 0 || union == 0 {
            out.append(ParityCheck(name: "\(prefix).maskIoU", verdict: .fail, detail: "empty expected core (\(r.previewCore)) or empty union; cannot pass"))
        } else {
            r.iou = Double(inter) / Double(union)
            out.append(ParityCheck(name: "\(prefix).maskIoU", verdict: r.iou! >= T.maskCoreIoU ? .pass : .fail,
                                   detail: String(format: "core IoU %.4f (core %d, preview mask %d, edge band %d)", r.iou!, r.previewCore, r.previewMask, r.previewEdge),
                                   values: ["iou": r.iou!]))
        }
        if let eb = r.exportBox, r.previewMask > 0 {
            let (ex0, ey0) = preview.mapping.crop(eb[0], eb[1]), (ex1, ey1) = preview.mapping.crop(eb[2], eb[3])
            r.previewBox = [Double(px0), Double(py0), Double(px1 + 1), Double(py1 + 1)]
            let delta = [abs(ex0 - Double(px0)), abs(ey0 - Double(py0)), abs(ex1 - Double(px1 + 1)), abs(ey1 - Double(py1 + 1))].max()!
            r.boxDelta = delta
            out.append(ParityCheck(name: "\(prefix).maskBoundingBox", verdict: delta <= T.maskBoundingBoxPixels ? .pass : .fail,
                                   detail: String(format: "largest box edge difference %.2f Preview px", delta), values: ["delta": delta]))
        } else {
            out.append(ParityCheck(name: "\(prefix).maskBoundingBox", verdict: .fail, detail: "export or preview mask empty; cannot pass"))
        }
        return (out, r)
    }

    /// Crop cells touched by any overlay pixel (export vs reference, native ±24 rule), dilated by the fidelity interior margin.
    /// Used only to keep overlay pixels out of the video fidelity measure.
    static func overlayExclusion(frame: NativeFrame, reference: NativeFrame, mapping: CropMapping, width cw: Int, height ch: Int) -> [Bool] {
        var cells = [Bool](repeating: false, count: cw * ch)
        guard frame.width == reference.width, frame.height == reference.height else { return [Bool](repeating: true, count: cw * ch) }
        for y in 0..<frame.height { for x in 0..<frame.width {
            let i = y * frame.width + x
            let dy = abs(frame.y.data[i] - reference.y.data[i]), dc = max(abs(frame.cb.data[i] - reference.cb.data[i]), abs(frame.cr.data[i] - reference.cr.data[i]))
            guard dy > Float(T.maskDeltaY) || dc > Float(T.maskDeltaC) else { continue }
            let (cx, cy) = mapping.crop(Double(x) + 0.5, Double(y) + 0.5)
            let ix = Int(floor(cx)), iy = Int(floor(cy))
            if ix >= 0, iy >= 0, ix < cw, iy < ch { cells[iy * cw + ix] = true }
        }}
        let m = T.fidelityInteriorMargin
        var out = cells
        for k in 0..<(cw * ch) where cells[k] {
            let x = k % cw, y = k / cw
            for yy in max(0, y - m)...min(ch - 1, y + m) { for xx in max(0, x - m)...min(cw - 1, x + m) { out[yy * cw + xx] = true } }
        }
        return out
    }

    // MARK: patch colour (C5, Preview vs Export, untagged diagnostics)

    struct PatchMeasure: Codable, Sendable {
        let index: Int
        let source: [Double]?    // source Y'CbCr mean (native, decoded)
        let export: [Double]?    // export Y'CbCr mean (native, decoded)
        let previewRaw: [Double]? // raw sRGB R'G'B' 0…1
        let previewCalibrated: [Double]? // reference R'G'B' 0…1
    }

    /// Mean of a normalised source rectangle (shrunk to its central 60 %) in a native frame.
    static func nativeMean(_ f: NativeFrame, placed: PlacedSource, rect n: (x: Double, y: Double, w: Double, h: Double)) -> [Double]? {
        let (x0, y0) = placed.output(n.x + 0.2 * n.w, n.y + 0.2 * n.h), (x1, y1) = placed.output(n.x + 0.8 * n.w, n.y + 0.8 * n.h)
        let ix = Int(x0.rounded()), iy = Int(y0.rounded()), iw = Int((x1 - x0).rounded()), ih = Int((y1 - y0).rounded())
        guard iw > 1, ih > 1, ix >= 0, iy >= 0, ix + iw <= f.width, iy + ih <= f.height else { return nil }
        return [f.y.mean(x: ix, y: iy, w: iw, h: ih), f.cb.mean(x: ix, y: iy, w: iw, h: ih), f.cr.mean(x: ix, y: iy, w: iw, h: ih)]
    }
    static func cropMean(_ c: PreviewCrop, placed: PlacedSource, rect n: (x: Double, y: Double, w: Double, h: Double)) -> [Double]? {
        let (ox0, oy0) = placed.output(n.x + 0.2 * n.w, n.y + 0.2 * n.h), (ox1, oy1) = placed.output(n.x + 0.8 * n.w, n.y + 0.8 * n.h)
        let (x0, y0) = c.mapping.crop(ox0, oy0), (x1, y1) = c.mapping.crop(ox1, oy1)
        let ix = Int(x0.rounded(.up)), iy = Int(y0.rounded(.up)), iw = Int(x1.rounded(.down)) - ix, ih = Int(y1.rounded(.down)) - iy
        guard iw > 0, ih > 0, ix >= 0, iy >= 0, ix + iw <= c.r.width, iy + ih <= c.r.height else { return nil }
        return [c.r.mean(x: ix, y: iy, w: iw, h: ih) / 255, c.g.mean(x: ix, y: iy, w: iw, h: ih) / 255, c.b.mean(x: ix, y: iy, w: iw, h: ih) / 255]
    }

    /// Diagnostic references for untagged sources (C6). They vary only primaries/matrix; `fullRange: false` is the decoded 420v buffer
    /// range (pixel-format property of the reader output), not a claimed source range: an untagged source's own range stays undeclared.
    static let hypothesis601 = ColorDeclaration(primaries: "SMPTE_C", transfer: "ITU_R_709_2", matrix: "ITU_R_601_4", fullRange: false, origin: "diagnostic BT.601 reference (decoded 420v)")
    static let hypothesis709 = ColorDeclaration(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: false, origin: "diagnostic BT.709 reference (decoded 420v)")

    static func describe(_ d: ColorDeclaration) -> String {
        "\(d.primaries ?? "-")/\(d.transfer ?? "-")/\(d.matrix ?? "-")/\(d.fullRange.map { $0 ? "full" : "video" } ?? "range not declared")"
    }

    static func distributionCheck(_ name: String, _ d: Distribution, mean: Double, p95: Double?, max mx: Double, detail: String) -> ParityCheck {
        let ok = d.count > 0 && d.mean <= mean && (p95.map { d.p95 <= $0 } ?? true) && d.max <= mx
        return ParityCheck(name: name, verdict: d.count == 0 ? .inconclusive : (ok ? .pass : .fail),
                           detail: String(format: "%@: ΔE00 mean %.3f p95 %.3f max %.3f (n %d)", detail, d.mean, d.p95, d.max, d.count),
                           values: ["mean": d.mean, "p95": d.p95, "max": d.max, "n": Double(d.count)])
    }

    /// Colour judgments of one frame's patches.
    /// - Export samples are converted with the output conversion (declared primaries/transfer/matrix + decoded 420v range); without it
    ///   every colour judgment is INCONCLUSIVE. The output's own declared range is recorded (C7), not used.
    /// - C5 (tagged sources) requires the complete source declaration — primaries, transfer, matrix and explicit range — from the
    ///   track and decoded buffer; missing or contradictory → INCONCLUSIVE. The expected colour uses the source conversion.
    /// - Untagged sources: BT.601/BT.709 references recorded only (C6); no source range is assumed.
    /// Managed comparisons (previewVsExportColour, C5.previewFollowsDeclaration) use parity-color-v3 (task 98): the calibrated capture
    /// against the v3 prediction of the export / declared source in lab.v2. `managedCalibration` = a frozen v3 CAL-B calibrated the
    /// capture. Raw (previewVsExportPreCalibration) and Export-side C5 (lab.v1) are unchanged.
    static func patchColour(_ patches: [PatchMeasure], source: DeclaredInterpretation, output: DeclaredInterpretation, tagged: Bool,
                            managedCalibration: Bool, prefix: String) -> [ParityCheck] {
        var out: [ParityCheck] = []
        out.append(ParityCheck(name: "\(prefix).C7.outputDeclaration", verdict: .recorded,
                               detail: "output track declaration \(describe(output.track)); decoded buffer observation \(describe(output.buffer)); declared complete: \(output.resolved != nil) (\(output.problem ?? "ok")); buffer-only observations \(output.bufferOnlyObservations); conflicts \(output.conflicts)"))
        guard let outDecl = output.conversion else {
            out.append(ParityCheck(name: "\(prefix).outputConversion", verdict: .inconclusive, detail: "output primaries/transfer/matrix not all declared and agreeing"))
            return out
        }
        func lab(_ v: [Double]?, _ d: ColorDeclaration) -> ColorMath.Lab? { v.flatMap { ColorMath.lab(y: $0[0], cb: $0[1], cr: $0[2], declaration: d) } }
        func labRGB(_ v: [Double]?, _ d: ColorDeclaration?) -> ColorMath.Lab? {
            guard let v, let d, let p = d.primaries, let t = d.transfer else { return nil }
            return ColorMath.lab((v[0], v[1], v[2]), primaries: p, transfer: t)
        }
        let srgb = ColorDeclaration(primaries: "IEC_sRGB", transfer: "IEC_sRGB", matrix: nil, fullRange: true, origin: "capture sRGB")
        var preCal: [Double] = []
        for p in patches {
            if let e = lab(p.export, outDecl), let raw = labRGB(p.previewRaw, srgb) { preCal.append(ColorMath.deltaE2000(e, raw)) }
        }
        let tag = ParityG5V3.tag
        func managedNote(_ m: ParityG5V3.PatchDE) -> String { "clipped patches \(m.clipped), max gamut loss ΔE00 \(String(format: "%.4f", m.maxGamutLoss)), pairs \(m.pairs); none excluded" }
        let pre = Distribution(preCal)
        out.append(ParityCheck(name: "\(prefix).previewVsExportPreCalibration", verdict: .recorded,
                               detail: String(format: "raw capture (sRGB) vs export: ΔE00 mean %.3f p95 %.3f max %.3f (n %d) — recorded only", pre.mean, pre.p95, pre.max, pre.count),
                               values: ["mean": pre.mean, "p95": pre.p95, "max": pre.max]))
        if !managedCalibration {
            out.append(ParityCheck(name: "\(prefix).previewVsExportColour", verdict: .inconclusive, detail: "\(tag): no frozen parity-color-v3 CAL-B (calibration not usable)"))
        } else if let od = ParityG5V3.managedDeclaration(output),
                  let m = ParityG5V3.managedPatchDE(expectedYCbCr: patches.map(\.export), observed: patches.map(\.previewCalibrated), declaration: od) {
            out.append(distributionCheck("\(prefix).previewVsExportColour", Distribution(m.des), mean: T.previewVersusExportMeanDE, p95: nil,
                                         max: T.previewVersusExportMaxDE, detail: "\(tag): calibrated preview vs v3 prediction of the export (lab.v2; \(managedNote(m)))"))
        } else {
            out.append(ParityCheck(name: "\(prefix).previewVsExportColour", verdict: .inconclusive, detail: "\(tag): output declaration outside parity-color-v3"))
        }
        if tagged {
            // C5 needs E (complete track declaration, no conflict); decoded-buffer observations never complete it.
            guard source.resolved != nil, source.problem == nil, source.conflicts.isEmpty, let srcDecl = source.conversion else {
                out.append(ParityCheck(name: "\(prefix).C5.sourceInterpretation", verdict: .inconclusive,
                                       detail: "declared source interpretation unusable (primaries, transfer, matrix and range are all required): \(source.problem ?? "unresolved")"))
                return out
            }
            var ex: [Double] = []
            for p in patches {
                guard let s = lab(p.source, srcDecl) else { continue }
                if let e = lab(p.export, outDecl) { ex.append(ColorMath.deltaE2000(s, e)) }
            }
            let declaredRange = source.resolved?.fullRange == true ? "full" : "video"
            out.append(distributionCheck("\(prefix).C5.exportFollowsDeclaration", Distribution(ex), mean: T.sourceInterpretationMeanDE, p95: T.sourceInterpretationP95DE,
                                         max: T.sourceInterpretationMaxDE, detail: "export vs declared source (\(srcDecl.primaries!)/\(srcDecl.transfer!)/\(srcDecl.matrix!), declared range \(declaredRange))"))
            if !managedCalibration {
                out.append(ParityCheck(name: "\(prefix).C5.previewFollowsDeclaration", verdict: .inconclusive, detail: "\(tag): no frozen parity-color-v3 CAL-B (calibration not usable)"))
            } else if let sm = ParityG5V3.managedDeclaration(source),
                      let m = ParityG5V3.managedPatchDE(expectedYCbCr: patches.map(\.source), observed: patches.map(\.previewCalibrated), declaration: sm) {
                out.append(distributionCheck("\(prefix).C5.previewFollowsDeclaration", Distribution(m.des), mean: T.sourceInterpretationMeanDE, p95: T.sourceInterpretationP95DE,
                                             max: T.sourceInterpretationMaxDE, detail: "\(tag): calibrated preview vs v3 prediction of the declared source \(sm.primaries!)/\(sm.matrix!) (lab.v2; \(managedNote(m)))"))
            } else {
                out.append(ParityCheck(name: "\(prefix).C5.previewFollowsDeclaration", verdict: .inconclusive, detail: "\(tag): declared source outside parity-color-v3"))
            }
        } else {
            for (name, hyp) in [("601", hypothesis601), ("709", hypothesis709)] {
                var ex: [Double] = []
                for p in patches { if let s = lab(p.source, hyp), let e = lab(p.export, outDecl) { ex.append(ColorMath.deltaE2000(s, e)) } }
                let d = Distribution(ex)
                out.append(ParityCheck(name: "\(prefix).C6.untaggedHypothesis\(name)", verdict: .recorded,
                                       detail: String(format: "export vs source under the BT.%@ reference: ΔE00 mean %.3f p95 %.3f max %.3f — diagnostic only, not a correct-colour claim; source range undeclared (%@)", name, d.mean, d.p95, d.max, source.track.fullRange == nil ? "not declared" : "declared"),
                                       values: ["mean": d.mean, "p95": d.p95, "max": d.max]))
            }
        }
        return out
    }

    // MARK: fidelity

    /// Interior pixel fidelity: export channels resampled with the frozen model vs the calibrated Preview.
    /// `exclude` marks crop cells to skip (overlay masks); the interior also skips cells within 3 px of the placed source edges.
    static func fidelity(export: NativeFrame, preview: PreviewCrop, model: Resampling.Frozen, placed: PlacedSource, exclude: [Bool]?, prefix: String) -> ParityCheck {
        guard model.established, let c = model.candidate, let px = model.phaseX, let py = model.phaseY, let outDecl = Optional(export.declaration),
              let m = outDecl.matrix, let full = outDecl.fullRange else {
            return ParityCheck(name: "\(prefix).fidelity", verdict: .inconclusive, detail: "resampling model not established or output declaration incomplete")
        }
        // Export R'G'B' planes (0…255) at native resolution.
        var r = ParityPlane(width: export.width, height: export.height), g = r, b = r
        for i in 0..<r.data.count {
            guard let v = ColorMath.rgb(y: Double(export.y.data[i]), cb: Double(export.cb.data[i]), cr: Double(export.cr.data[i]), matrix: m, fullRange: full) else { continue }
            r.data[i] = Float(v.r * 255); g.data[i] = Float(v.g * 255); b.data[i] = Float(v.b * 255)
        }
        let map = preview.mapping, cw = preview.r.width, ch = preview.r.height
        // Phase of crop pixel 0 relative to output pixel 0: crop = origin + output × scale.
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
            let d = max(abs(pr.data[k] - preview.r.data[k]), abs(pg.data[k] - preview.g.data[k]), abs(pb.data[k] - preview.b.data[k]))
            if d <= Float(T.fidelityChannel) { within += 1 }
        }}
        guard total > 0 else { return ParityCheck(name: "\(prefix).fidelity", verdict: .inconclusive, detail: "no interior pixels") }
        let frac = Double(within) / Double(total)
        return ParityCheck(name: "\(prefix).fidelity", verdict: frac >= T.fidelityFraction ? .pass : .fail,
                           detail: String(format: "interior pixels within ±%d: %d/%d (%.4f), model %@", T.fidelityChannel, within, total, frac, c.rawValue),
                           values: ["fraction": frac, "total": Double(total)])
    }

    // MARK: edges

    /// Export last column/row at native resolution against a uniform source level (±16). Non-uniform sources → NOT VERIFIED.
    static func exportEdge(export: NativeFrame, placed: PlacedSource, sourceLevels: (y: ClosedRange<Double>, c: ClosedRange<Double>)?, builtin: Bool, prefix: String) -> ParityCheck {
        guard let lv = sourceLevels, lv.y.upperBound - lv.y.lowerBound <= 3 else {
            return ParityCheck(name: "\(prefix).exportEdge", verdict: .notVerified, detail: "source not uniform; edge expectation unavailable")
        }
        let right = Int((placed.x + placed.w).rounded()) - 1, bottom = Int((placed.y + placed.h).rounded()) - 1
        guard right == export.width - 1 || bottom == export.height - 1 else {
            return ParityCheck(name: "\(prefix).exportEdge", verdict: .notVerified, detail: "placed source does not reach the output edge")
        }
        var off = 0, n = 0
        func test(_ x: Int, _ y: Int) {
            n += 1
            let yy = Double(export.y[x, y]), cb = Double(export.cb[x, y]), cr = Double(export.cr[x, y])
            let dy = max(lv.y.lowerBound - yy, yy - lv.y.upperBound), dc = max(lv.c.lowerBound - min(cb, cr), max(cb, cr) - lv.c.upperBound)
            if dy > Double(T.exportEdgeTolerance) || dc > Double(T.exportEdgeTolerance) { off += 1 }
        }
        let x0 = max(0, Int(placed.x.rounded())), y0 = max(0, Int(placed.y.rounded()))
        if right == export.width - 1 { for y in y0...bottom { test(right, y) } }
        if bottom == export.height - 1 { for x in x0...right { test(x, bottom) } }
        let verdict: ParityVerdict = off == 0 ? .pass : (builtin ? .expectedBaselineFail : .fail)
        return ParityCheck(name: "\(prefix).exportEdge", verdict: verdict, detail: "edge pixels beyond ±\(T.exportEdgeTolerance) of the source: \(off)/\(n)", values: ["off": Double(off), "n": Double(n)])
    }

    /// Preview last column under two hypotheses (full coverage vs a black 1-px source column) predicted with the frozen model.
    /// If the hypotheses differ by less than 3 × capture noise, the result is NOT VERIFIED.
    /// `output` (parity-color-v3, task 98): applied once to both hypotheses after the encoded-domain resample so they are in the
    /// calibrated capture's representation. The verdict stays an edge-geometry decision (which hypothesis is closer).
    static func previewEdge(preview: PreviewCrop, model: Resampling.Frozen, placed: PlacedSource, level: Double, noise: Double, builtin: Bool, prefix: String,
                            output: Resampling.Output? = nil) -> ParityCheck {
        guard model.established, let c = model.candidate, let px = model.phaseX else {
            return ParityCheck(name: "\(prefix).previewEdge", verdict: .notVerified, detail: "resampling model not established")
        }
        let map = preview.mapping
        let lastX = Int(floor(map.crop(placed.x + placed.w, 0).0 - 1e-6))
        guard lastX >= 1, lastX < preview.r.width else { return ParityCheck(name: "\(prefix).previewEdge", verdict: .notVerified, detail: "edge outside the crop") }
        let n = Int(placed.w.rounded()) + 8
        var full = [Double](repeating: level, count: n), defect = full
        for i in Int(placed.w.rounded())..<n { full[i] = 0; defect[i] = 0 }
        defect[Int(placed.w.rounded()) - 1] = 0
        let count = lastX + 2
        let phase = map.originX + placed.x * map.scaleX + px
        let a0 = Resampling.resample1D(full, count: count, scale: map.scaleX, phase: phase, c)
        let b0 = Resampling.resample1D(defect, count: count, scale: map.scaleX, phase: phase, c)
        let a = output.map { f in a0.map(f) } ?? a0, b = output.map { f in b0.map(f) } ?? b0
        let separation = abs(a[lastX] - b[lastX]), floorNoise = max(1, noise)
        guard separation >= T.previewEdgeNoiseFactor * floorNoise else {
            return ParityCheck(name: "\(prefix).previewEdge", verdict: .notVerified,
                               detail: String(format: "hypotheses differ by %.2f at the last Preview column; capture noise %.2f (needs ≥ %.1f×)", separation, floorNoise, T.previewEdgeNoiseFactor))
        }
        let midY = Int(map.crop(0, placed.y + placed.h / 2).1)
        let measured = 0.2126 * Double(preview.r[lastX, midY]) + 0.7152 * Double(preview.g[lastX, midY]) + 0.0722 * Double(preview.b[lastX, midY])
        let full0 = abs(measured - a[lastX]) <= abs(measured - b[lastX])
        let verdict: ParityVerdict = full0 ? .pass : (builtin ? .expectedBaselineFail : .fail)
        return ParityCheck(name: "\(prefix).previewEdge", verdict: verdict,
                           detail: String(format: "measured %.2f, full-coverage %.2f, defect %.2f", measured, a[lastX], b[lastX]))
    }

    // MARK: geometry

    /// Left/right edges of the placed source along its middle row (50 % crossing in the calibrated Preview) vs the mapped placement.
    static func geometry(preview: PreviewCrop, placed: PlacedSource, withModel: Bool, prefix: String) -> ParityCheck {
        let limit = withModel ? T.geometryWithModel : T.geometryWithoutModel
        let map = preview.mapping, cw = preview.r.width
        let midY = Int(map.crop(0, placed.y + placed.h / 2).1)
        guard midY >= 0, midY < preview.r.height else { return ParityCheck(name: "\(prefix).geometry", verdict: .notVerified, detail: "middle row outside the crop") }
        func luma(_ x: Int) -> Double { 0.2126 * Double(preview.r[x, midY]) + 0.7152 * Double(preview.g[x, midY]) + 0.0722 * Double(preview.b[x, midY]) }
        var deltas: [Double] = [], notes: [String] = []
        for (name, ox) in [("left", placed.x), ("right", placed.x + placed.w)] {
            let ex = map.crop(ox, 0).0
            let lo = Int(ex) - 4, hi = Int(ex) + 4
            guard lo >= 0, hi < cw, ox > 0.5, ox < 1919.5 else { notes.append("\(name) edge at the output boundary: not measurable"); continue }
            let a = luma(lo), b = luma(hi), mid = (a + b) / 2
            guard abs(a - b) > 8 else { notes.append("\(name) edge contrast too low"); continue }
            var found: Double?
            for x in lo..<hi { let v0 = luma(x), v1 = luma(x + 1); if (v0 - mid) * (v1 - mid) <= 0, v0 != v1 { found = Double(x) + 0.5 + (mid - v0) / (v1 - v0); break } }
            if let f = found { deltas.append(abs(f - ex)) } else { notes.append("\(name) crossing not found") }
        }
        guard !deltas.isEmpty else { return ParityCheck(name: "\(prefix).geometry", verdict: .notVerified, detail: notes.joined(separator: "; ")) }
        let worst = deltas.max()!
        return ParityCheck(name: "\(prefix).geometry", verdict: worst <= limit ? .pass : .fail,
                           detail: String(format: "largest edge position difference %.3f Preview px (limit %.1f)", worst, limit) + (notes.isEmpty ? "" : "; " + notes.joined(separator: "; ")),
                           values: ["delta": worst])
    }
}

// MARK: - D-041 conformance across runs

/// The stored region of interest of one measured frame (generated fixtures only).
struct ROIPixels: Sendable {
    let width: Int, height: Int
    let exportYCbCr: [UInt8]      // 3 × w × h (planar Y, Cb, Cr) native
    let previewRGB: [UInt8]?      // 3 × pw × ph calibrated reference R'G'B'; nil if calibration unusable
    let previewWidth: Int, previewHeight: Int
}

struct ScenarioSummary: Codable, Sendable {
    let scenario: String, compositor: String
    let frames: [Int]
    let activeLayers: [Int: Int]          // frame → active layer instructions in the CompositionPlanner plan
    let exportPatches: [Int: [[Double]]]  // frame → 24 × Y'CbCr (target source), may be empty
    let outputDeclaration: ColorDeclaration?          // conversion of the decoded export (declared primaries/transfer/matrix + 420v range)
    let outputTrackDeclaration: ColorDeclaration?     // the export track's own declaration, range only if explicit (C7)
    let anchorMean: [Double]?             // plate-red segment mean Y'CbCr (scenario G only)
    let c5Verdicts: [String: ParityVerdict]
    /// parity-color-v3 (task 98): contract and frozen CAL-B fingerprint the scenario's calibrated Preview was produced with.
    var colorContract: ColorContractIdentity? = nil
    var calibrationParameters: String? = nil
}

enum Conformance {
    typealias T = ParityThresholdsV1

    /// `previewIncomparable` (task 98): reason the two calibrated Preview ROIs are not comparable under parity-color-v3 (nil = comparable).
    static func roiInvariance(_ name: String, a: ROIPixels, b: ROIPixels, patchesA: [[Double]], patchesB: [[Double]], output: ColorDeclaration?,
                              previewIncomparable: String? = nil) -> [ParityCheck] {
        var out: [ParityCheck] = []
        if a.width == b.width, a.height == b.height, a.exportYCbCr.count == b.exportYCbCr.count, !a.exportYCbCr.isEmpty {
            var within = 0
            let n = a.width * a.height
            for i in 0..<n {
                let ok = (0..<3).allSatisfy { abs(Int(a.exportYCbCr[$0 * n + i]) - Int(b.exportYCbCr[$0 * n + i])) <= T.laneInvarianceChannel }
                if ok { within += 1 }
            }
            let f = Double(within) / Double(n)
            out.append(ParityCheck(name: "\(name).exportPixels", verdict: f >= T.laneInvarianceFraction ? .pass : .fail,
                                   detail: String(format: "export ROI pixels within ±%d: %.5f", T.laneInvarianceChannel, f), values: ["fraction": f]))
        } else {
            out.append(ParityCheck(name: "\(name).exportPixels", verdict: .inconclusive, detail: "ROI sizes differ or empty"))
        }
        if let why = previewIncomparable {
            out.append(ParityCheck(name: "\(name).previewPixels", verdict: .inconclusive, detail: why))
        } else if let pa = a.previewRGB, let pb = b.previewRGB, pa.count == pb.count, !pa.isEmpty {
            let n = pa.count / 3
            var within = 0
            for i in 0..<n where (0..<3).allSatisfy({ abs(Int(pa[$0 * n + i]) - Int(pb[$0 * n + i])) <= T.laneInvarianceChannel }) { within += 1 }
            let f = Double(within) / Double(n)
            out.append(ParityCheck(name: "\(name).previewPixels", verdict: f >= T.laneInvarianceFraction ? .pass : .fail,
                                   detail: String(format: "%@: calibrated preview ROI pixels within ±%d: %.5f", ParityG5V3.tag, T.laneInvarianceChannel, f), values: ["fraction": f]))
        } else {
            out.append(ParityCheck(name: "\(name).previewPixels", verdict: .inconclusive, detail: "calibrated preview ROI unavailable or sizes differ"))
        }
        if let d = output, patchesA.count == patchesB.count, !patchesA.isEmpty {
            var des: [Double] = []
            for (p, q) in zip(patchesA, patchesB) {
                if let la = ColorMath.lab(y: p[0], cb: p[1], cr: p[2], declaration: d), let lb = ColorMath.lab(y: q[0], cb: q[1], cr: q[2], declaration: d) { des.append(ColorMath.deltaE2000(la, lb)) }
            }
            let dist = Distribution(des)
            out.append(ParityCheck(name: "\(name).patchDE", verdict: dist.count == patchesA.count && dist.max <= T.laneInvariancePatchMaxDE ? .pass : .fail,
                                   detail: String(format: "export patch ΔE00 max %.3f (limit %.1f)", dist.max, T.laneInvariancePatchMaxDE), values: ["max": dist.max]))
        } else {
            out.append(ParityCheck(name: "\(name).patchDE", verdict: .inconclusive, detail: "patches or output declaration unavailable"))
        }
        return out
    }

    /// C1–C7. `roi(scenario, compositor, frame)` loads stored ROI pixels.
    static func evaluate(_ s: [ScenarioSummary], roi: (String, String, Int) -> ROIPixels?) -> [ParityCheck] {
        func find(_ sc: String, _ comp: String) -> ScenarioSummary? { s.first { $0.scenario == sc && $0.compositor == comp } }
        var out: [ParityCheck] = []
        func compare(_ label: String, _ a: ScenarioSummary?, _ b: ScenarioSummary?, requireLayers: Bool) -> [ParityCheck] {
            guard let a, let b else { return [ParityCheck(name: label, verdict: .notRun, detail: "required scenario record missing")] }
            var checks: [ParityCheck] = []
            for k in a.frames where b.frames.contains(k) {
                if requireLayers, (b.activeLayers[k] ?? 0) < 2 {
                    checks.append(ParityCheck(name: "\(label).frame\(k)", verdict: .inconclusive, detail: "plan has \(b.activeLayers[k] ?? 0) active layers; at least 2 required"))
                    continue
                }
                guard let ra = roi(a.scenario, a.compositor, k), let rb = roi(b.scenario, b.compositor, k) else {
                    checks.append(ParityCheck(name: "\(label).frame\(k)", verdict: .inconclusive, detail: "ROI pixels missing")); continue
                }
                checks += roiInvariance("\(label).frame\(k)", a: ra, b: rb, patchesA: a.exportPatches[k] ?? [], patchesB: b.exportPatches[k] ?? [], output: a.outputDeclaration,
                                        previewIncomparable: ParityG5V3.previewComparability(a, b))
            }
            if checks.isEmpty { checks.append(ParityCheck(name: label, verdict: .inconclusive, detail: "no common frames")) }
            return checks
        }
        func roll(_ name: String, _ checks: [ParityCheck], detail: String) -> ParityCheck {
            let v: ParityVerdict = checks.contains { $0.verdict == .fail } ? .fail : (checks.allSatisfy { $0.verdict == .pass } ? .pass
                : (checks.contains { $0.verdict == .notRun } ? .notRun : .inconclusive))
            return ParityCheck(name: name, verdict: v, detail: detail + " (\(checks.count) sub-checks)")
        }
        let c1 = compare("C1", find("M1", "corrected"), find("M6", "corrected"), requireLayers: true)
        out += c1; out.append(roll("C1.realMultiLayerInvariance", c1, detail: "corrected M6 (≥ 2 active layers) vs M1, target ROI"))
        let c2 = compare("C2", find("M1", "corrected"), find("M5", "corrected"), requireLayers: false)
        out += c2; out.append(roll("C2.emptyLaneInvariance", c2, detail: "corrected M5 vs M1 (auxiliary; not a multi-layer claim)"))
        // C3: corrected M1 export patches vs builtin M6 (actual multi-layer) export patches, plus the plate-red anchor.
        var c3: [ParityCheck] = []
        if let a = find("M1", "corrected"), let b = find("M6", "builtin"), let d = a.outputDeclaration {
            for k in a.frames where b.frames.contains(k) {
                guard (b.activeLayers[k] ?? 0) >= 2 else { c3.append(ParityCheck(name: "C3.frame\(k)", verdict: .inconclusive, detail: "builtin M6 plan not multi-layer")); continue }
                let pa = a.exportPatches[k] ?? [], pb = b.exportPatches[k] ?? []
                var des: [Double] = []
                for (p, q) in zip(pa, pb) {
                    if let la = ColorMath.lab(y: p[0], cb: p[1], cr: p[2], declaration: d), let lb = ColorMath.lab(y: q[0], cb: q[1], cr: q[2], declaration: d) { des.append(ColorMath.deltaE2000(la, lb)) }
                }
                let dist = Distribution(des)
                let ok = dist.count == ParityLayout.patchCount && dist.mean <= T.approvedReferenceMeanDE && dist.max <= T.approvedReferenceMaxDE
                c3.append(ParityCheck(name: "C3.frame\(k)", verdict: dist.count == 0 ? .inconclusive : (ok ? .pass : .fail),
                                      detail: String(format: "corrected M1 vs builtin M6 export patches ΔE00 mean %.3f max %.3f (n %d)", dist.mean, dist.max, dist.count)))
            }
        } else { c3.append(ParityCheck(name: "C3", verdict: .notRun, detail: "corrected M1 or builtin M6 record missing")) }
        if let g = find("G", "corrected"), let m = g.anchorMean {
            let ref = [Double(T.anchorYCbCr.0), Double(T.anchorYCbCr.1), Double(T.anchorYCbCr.2)]
            let ok = zip(m, ref).allSatisfy { abs($0 - $1) <= Double(T.anchorTolerance) }
            c3.append(ParityCheck(name: "C3.anchorPlateRed", verdict: ok ? .pass : .fail, detail: String(format: "corrected export plate-red mean Y'CbCr [%.1f, %.1f, %.1f] vs recorded [69, 119, 207] ±2", m[0], m[1], m[2])))
        } else { c3.append(ParityCheck(name: "C3.anchorPlateRed", verdict: .notRun, detail: "corrected G record or anchor missing")) }
        out += c3; out.append(roll("C3.approvedReference", c3, detail: "untagged SD vs the approved multi-lane rendering reference"))
        out.append(ParityCheck(name: "C4.chromaResampling", verdict: .recorded, detail: "corrected chroma resampling on downscale accepted by D-041; not compared with the previous bias"))
        var c5: [ParityCheck] = []
        for sc in ["M2", "M3"] {
            guard let r = find(sc, "corrected") else { c5.append(ParityCheck(name: "C5.\(sc)", verdict: .notRun, detail: "record missing")); continue }
            let v = ParityG5V3.c5ScenarioVerdict(r.c5Verdicts)
            c5.append(ParityCheck(name: "C5.\(sc)", verdict: v.verdict, detail: "explicit declaration followed by export and preview (\(r.c5Verdicts.count) frame judgments): \(v.detail)"))
        }
        out += c5; out.append(roll("C5.declaredInterpretation", c5, detail: "M2 (BT.601) and M3 (BT.709): complete declared interpretation"))
        out.append(ParityCheck(name: "C6.untaggedHypotheses", verdict: .recorded, detail: "BT.601 / BT.709 hypotheses recorded per untagged scenario; no correct-colour claim"))
        let outputs = s.compactMap { $0.outputTrackDeclaration }.map { "\($0.primaries ?? "-")/\($0.transfer ?? "-")/\($0.matrix ?? "-")/\($0.fullRange.map { $0 ? "full" : "video" } ?? "-")" }
        out.append(ParityCheck(name: "C7.outputMetadata", verdict: .recorded, detail: "observed output declarations: \(Set(outputs).sorted().joined(separator: ", ")) (implementation fact; no output policy implied)"))
        // Builtin lane dependence is the documented baseline.
        if let a = find("M1", "builtin"), let b = find("M6", "builtin") {
            let base = compare("builtinM6vsM1", a, b, requireLayers: true)
            let differs = base.contains { $0.verdict == .fail }
            out.append(ParityCheck(name: "baseline.builtinLaneDependence", verdict: differs ? .expectedBaselineDifference : .recorded,
                                   detail: differs ? "builtin M6 differs from M1 (known lane-dependent behaviour)" : "builtin M6 did not differ from M1 in these frames"))
        }
        let key = out.filter { ["C1.realMultiLayerInvariance", "C3.approvedReference", "C5.declaredInterpretation"].contains($0.name) }
        let conform: ParityVerdict = key.count == 3 && key.allSatisfy { $0.verdict == .pass } ? .pass : (key.contains { $0.verdict == .fail } ? .fail : .inconclusive)
        out.append(ParityCheck(name: "D041.conformance", verdict: conform, detail: "C1 ∧ C3 ∧ C5 (C2 auxiliary, C4/C6/C7 recorded)"))
        return out
    }
}
#endif
