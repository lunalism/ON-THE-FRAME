#if DEBUG
import AppKit
import AVFoundation
@testable import OnTheFrameEngine

/// SP-EXPORT-E4D-G1 (DEBUG only): full Preview versus Export parity, phase 1 (paused frames), one scenario per process.
/// Launch: `open -n -W -a OnTheFrame.app <run folder> --args -OTFFullPreviewParity <scenario> <builtin|corrected>
///          [-OTFParityCalibration <frozen.json>] [-OTFParityResampling <frozen.json>] [-OTFParityNoPNG]`
/// or `-OTFFullPreviewParity aggregate builtin` with a folder whose subfolders hold earlier run results (C1–C7).
/// <run folder>/sources holds isolated copies of the fixtures (G2). Writes only inside the run folder:
/// full-parity-result.json, frozen models (CAL-B, RES-B), generated-fixture PNG evidence and ROI binaries.
/// Never changes normal Preview/Export, ProjectStore playback, project format, permissions or the public Export guard.
@MainActor
enum FullPreviewParitySelfTest {
    struct WindowInfo: Codable {
        var attempted = true; var achievedTwoToOne = false; var videoRectPoints: [Double] = []; var backingScale = 0.0; var note = ""
        // GEOMETRY-FIX-84 (optional fields): measured adjustments, final measurement, and whether it was taken after the last resize.
        var attempts: [TwoToOneAttempt]? = nil
        var finalSample: TwoToOneSample? = nil
        var finalReason: String? = nil
        var verifiedAfterLastResize: Bool? = nil
    }
    struct RunRecord: Codable {
        let scenario: String, compositor: String
        let thresholdsVersion: String, thresholdsFingerprint: String, layoutVersion: Int
        var prerequisites: ParityPrerequisites
        var window = WindowInfo()
        var readiness: FullPreviewWindowCapture.Readiness?
        var selectedWindow = ""
        let workingColorSpace: WorkingColorSpace
        var sourceInterpretations: [String: DeclaredInterpretation] = [:]
        var outputInterpretation: DeclaredInterpretation?
        var referenceOutputInterpretation: DeclaredInterpretation?
        var checks: [ParityCheck] = []
        var summary: ScenarioSummary?
        var roiDimensions: [String: [String: Int]] = [:]
        var stabilityLogs: [String: [StabilitySample]] = [:]   // per frame: every sample seen while the grab was armed
        var captureDiagnostics: [String: FrameCaptureDiagnostics]? = nil   // STALE-CAPTURE-FIX-79: seek settlement, fence, grab outcome per frame
        var sourceSHA256Before: [String: String] = [:], sourceSHA256After: [String: String] = [:]
        var provenance: ModelProvenance?
        var notes: [String] = []
        /// parity-color-v3 (task 97): contract under which CAL-B/CAL-V/RES-B/RES-C and frame fidelity are judged.
        var colorContract: ColorContractIdentity? = ColorContractV3.identity
    }

    static func run(folder: URL, args: [String]) async {
        let scenario = value(after: "-OTFFullPreviewParity", in: args, offset: 1) ?? "?"
        let compositor = value(after: "-OTFFullPreviewParity", in: args, offset: 2) ?? "builtin"
        if scenario == "aggregate" { aggregate(folder: folder); finish(); return }
        var record = RunRecord(scenario: scenario, compositor: compositor, thresholdsVersion: ParityThresholdsV1.version,
                               thresholdsFingerprint: ParityThresholdsV1.fingerprint, layoutVersion: ParityLayout.version,
                               prerequisites: ParityPrerequisites(captureValid: false, calibrationValid: false, calibrationNote: "not loaded",
                                                                  resamplingEstablished: false, resamplingNote: "not loaded"),
                               workingColorSpace: compositor == "corrected" ? .corrected : .builtin)
        do { try await execute(folder: folder, args: args, record: &record) }
        catch { record.checks.append(ParityCheck(name: "execution", verdict: .notRun, detail: "\(error)")) }
        write(record, folder.appendingPathComponent("full-parity-result.json"))
        finish()
    }

    static func value(after flag: String, in args: [String], offset: Int = 1) -> String? {
        guard let i = args.firstIndex(of: flag), i + offset < args.count else { return nil }
        return args[i + offset]
    }
    static func finish() { ProjectStore.shared.itemCreatedHookForTest = nil; ProjectStore.shared.discardConfirmedForTest(); NSApp.terminate(nil) }
    /// NaN/∞ (empty distributions, unavailable values) are written as strings so a result is never lost.
    static func write<E: Encodable>(_ v: E, _ url: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        do { try enc.encode(v).write(to: url) }
        catch { try? Data("{\"writeError\": \"\(error)\"}".utf8).write(to: url) }
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    // MARK: one scenario

    static func execute(folder: URL, args: [String], record: inout RunRecord) async throws {
        let s = ProjectStore.shared, corrected = record.compositor == "corrected"
        guard record.compositor == "builtin" || corrected else { throw RunError.argument("compositor \(record.compositor)") }
        guard FullPreviewParityScenes.all.contains(record.scenario) else { throw RunError.argument("scenario \(record.scenario)") }
        let savePNG = !args.contains("-OTFParityNoPNG")   // all phase-1 scenarios use generated fixtures; real media (H) is excluded
        // Corrected Preview: same hook as the existing parity test. A failed swap keeps the item unchanged and is recorded
        // (never replaced by nil); installation is checked on the current item below.
        var swapFailures: [String] = []
        if corrected {
            s.itemCreatedHookForTest = { item, _ in
                guard let base = item.videoComposition else { return }
                do { item.videoComposition = try ExperimentalComposition.videoComposition(from: base, options: .init(edgeCoverage: .fullRectangle)) }
                catch { swapFailures.append("\(error)") }
            }
        }
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil && s.previewHost?.window != nil }
        guard let view = s.previewHost, let window = s.editorWindow else { throw RunError.setup("editor window or preview view missing") }
        NSApp.activate(); window.makeKeyAndOrderFront(nil)

        // Sources (isolated copies) and their fingerprints.
        let src = folder.appendingPathComponent("sources")
        var assets: [String: MediaAsset] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? []
        for n in names where n.hasSuffix(".mp4") || n.hasSuffix(".mov") || n.hasSuffix(".wav") {
            let a = try await MediaProbe.inspect(src.appendingPathComponent(n)); s.assetCache[a.url.standardizedFileURL.path] = a; assets[n] = a
        }
        let scene = try FullPreviewParityScenes.make(record.scenario, assets: assets)
        for f in scene.files { record.sourceSHA256Before[f] = FullPreviewParityIO.sha256(src.appendingPathComponent(f)) }
        defer { for f in scene.files { record.sourceSHA256After[f] = FullPreviewParityIO.sha256(src.appendingPathComponent(f)) } }

        s.loadTimelineForTest(scene.timeline)
        let applied = await LaneSelfTest.waitUntil(15) { s.appliedGeneration == s.generation && s.player.currentItem?.status == .readyToPlay }
        guard applied, s.timeline == scene.timeline else { throw RunError.setup("timeline not applied") }
        let installed = s.player.currentItem?.videoComposition?.customVideoCompositorClass != nil
        if corrected {
            record.checks.append(ParityCheck(name: "compositor.previewInstalled", verdict: installed && swapFailures.isEmpty ? .pass : .fail,
                                             detail: "custom compositor on the Preview item: \(installed); swap failures \(swapFailures)"))
            guard installed && swapFailures.isEmpty else { return }
        } else {
            record.checks.append(ParityCheck(name: "compositor.previewInstalled", verdict: installed ? .fail : .pass, detail: "builtin: custom compositor present \(installed)"))
        }
        s.selection = nil
        record.window = await attemptTwoToOne(window: window, view: view)

        // Capture (own window only). Failure → every capture-dependent judgment NOT RUN.
        let capture: FullPreviewWindowCapture
        do { capture = try await FullPreviewWindowCapture.start(window: window, view: view) }
        catch { record.checks.append(ParityCheck(name: "capture.start", verdict: .notRun, detail: "\(error)")); return }
        record.selectedWindow = capture.selectedWindow
        let ready = await capture.waitReady()
        record.readiness = ready
        guard ready.ready else {
            await capture.stop()
            record.checks.append(ParityCheck(name: "capture.readiness", verdict: .notRun, detail: ready.reason)); return
        }
        record.prerequisites.captureValid = true
        var crops: [Int: PreviewCrop] = [:]
        var diagnostics: [String: FrameCaptureDiagnostics] = [:]
        defer { record.captureDiagnostics = diagnostics }
        for k in scene.frames {
            let (settled, seek) = await settle(k, scene: scene, view: view)
            guard settled, let fence = seek.fenceTicks else {
                diagnostics["\(k)"] = FrameCaptureDiagnostics(seek: seek, grab: nil)
                record.checks.append(ParityCheck(name: "frame\(k).previewSettled", verdict: .inconclusive, detail: "preview not settled: \(seek.outcome)")); continue
            }
            // A. Preview stability over FRESH samples (displayed after the fence). For frame-coded sources the grab accepts only the
            // requested frame code; B. source identity is still judged later on the returned crop, independently.
            let expect: ExpectedPreviewCode? = scene.target(k).flatMap { placed in
                scene.sourceFrame(k).map { ExpectedPreviewCode(placed: placed, sourceID: placed.sourceID, frame: $0) }
            }
            let g = await capture.grab(fenceTicks: fence, expect: expect)
            diagnostics["\(k)"] = FrameCaptureDiagnostics(seek: seek, grab: g.diagnostics)
            record.stabilityLogs["\(k)"] = g.samples
            let complete = g.samples.filter { $0.status == "complete" }.count
            if let c = g.crop {
                crops[k] = c
                record.checks.append(ParityCheck(name: "frame\(k).previewStable", verdict: .pass,
                                                 detail: "\(g.note); \(complete) complete samples logged (stability only, not identity)"))
            } else {
                // Capture failure (error, terminal status, stopped stream) → NOT RUN; insufficient samples or no stable run → INCONCLUSIVE.
                let failed = g.note.hasPrefix("capture error") || g.note.hasPrefix("terminal status") || g.note.hasPrefix("stream stopped")
                record.checks.append(ParityCheck(name: "frame\(k).previewStable", verdict: failed ? .notRun : .inconclusive, detail: "\(g.note); \(complete) complete samples logged"))
            }
        }
        await capture.stop()

        // Provenance of this run (models frozen by CAL-B/RES-B are only reused under the same environment).
        let appHash = appBinaryHash()
        let fixtureFile = record.scenario == "RES" ? "otf-RES.mp4" : "otf-CAL.mp4"
        let provenance = ModelProvenance(displayProfile: capture.geometry.displayProfile, videoRectPixels: capture.videoRectPixels, backingScale: capture.geometry.backingScale,
                                         appBinarySHA256: appHash, captureColorSpace: "sRGB",
                                         fixtureSHA256: record.sourceSHA256Before[fixtureFile] ?? FullPreviewParityIO.sha256(src.appendingPathComponent(fixtureFile)),
                                         compositor: record.compositor)
        record.provenance = provenance

        // Export (DEBUG internal entry point for Spectrum timelines, public plan export otherwise) and decode.
        let wanted = Set(scene.frames)
        let out = folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let main = try await export(scene.timeline, media: s.mediaByID, to: out.appendingPathComponent("parity.mp4"), corrected: corrected, record: &record) else { return }
        let decoded = try await FullPreviewParityIO.decode(main, frames: wanted, origin: "output")
        // Independent of calibration and resampling: the encoded frames are 1920×1080 (FHD output).
        let sizes = Set(decoded.frames.values.map { "\($0.width)x\($0.height)" })
        record.checks.append(ParityCheck(name: "export.dimensions", verdict: sizes == ["1920x1080"] ? .pass : .fail, detail: "decoded frame sizes \(sizes.sorted())"))
        record.outputInterpretation = decoded.interpretation
        var reference: FullPreviewParityIO.Decoded?
        if let r = scene.reference, let url = try await export(r, media: s.mediaByID, to: out.appendingPathComponent("reference.mp4"), corrected: corrected, record: &record) {
            reference = try await FullPreviewParityIO.decode(url, frames: wanted, origin: "reference output")
            record.referenceOutputInterpretation = reference?.interpretation
        }
        // Source frames (for calibration, colour and edge expectations).
        var sources: [String: FullPreviewParityIO.Decoded] = [:]
        var byFile: [String: Set<Int>] = [:]
        for k in scene.frames { if let f = scene.sourceFile(k) { byFile[f, default: []].insert(scene.sourceFrame(k) ?? max(0, k - firstFrame(of: f, scene: scene))) } }
        for (f, idx) in byFile where !f.hasSuffix(".wav") {
            let d = try await FullPreviewParityIO.decode(src.appendingPathComponent(f), frames: idx, origin: "source \(f)")
            sources[f] = d; record.sourceInterpretations[f] = d.interpretation
        }

        // Frozen models.
        loadModels(args: args, provenance: provenance, record: &record)
        let calibration = loadCalibration(args: args)
        let resampling = loadResampling(args: args)

        switch record.scenario {
        case "CAL": calibrationStage(scene: scene, crops: crops, sources: sources, folder: folder, provenance: provenance, frozen: calibration, record: &record)
        case "RES": resamplingStage(scene: scene, crops: crops, sources: sources, folder: folder, provenance: provenance, calibration: calibration, frozen: resampling, record: &record)
        default: break
        }
        // Frame checks use only frozen models supplied as arguments (A: frozen CAL-B, B: frozen RES-B). A model fitted or established
        // in this run (C: CAL-B fit, D: RES-B establishment) is frozen for later stages and is NOT used here (G4-GATE-FIX-72).
        let calMatrix = record.prerequisites.calibrationValid ? calibration?.matrix : nil
        let model = record.prerequisites.resamplingEstablished ? resampling : nil
        let fittedCALBThisRun = record.scenario == "CAL" && record.compositor == "builtin" && record.prerequisites.calibrationValid
        let establishedRESBThisRun = record.scenario == "RES" && record.compositor == "builtin" && record.prerequisites.resamplingEstablished

        // Plan inspection (M5/M6 and every scenario as evidence).
        let plan = try await CompositionPlanner.plan(scene.timeline, media: s.mediaByID, settings: .m1)
        var layers: [Int: Int] = [:]
        for k in scene.frames { layers[k] = FullPreviewParityIO.activeLayers(plan, frame: k) }
        if record.scenario == "M6" {
            for k in scene.frames {
                record.checks.append(ParityCheck(name: "frame\(k).planActiveLayers", verdict: (layers[k] ?? 0) >= 2 ? .pass : .inconclusive,
                                                 detail: "CompositionPlanner instruction at frame \(k) has \(layers[k] ?? 0) active layer instructions (≥ 2 required)"))
            }
        } else if record.scenario == "M5" {
            for k in scene.frames { record.checks.append(ParityCheck(name: "frame\(k).planActiveLayers", verdict: .recorded, detail: "\(layers[k] ?? 0) active layer instructions (empty upper lane)")) }
        }

        var exportPatches: [Int: [[Double]]] = [:], c5: [String: ParityVerdict] = [:], anchor: [Double]?
        for k in scene.frames {
            judgeFrame(k, scene: scene, decoded: decoded, reference: reference, sources: sources, crop: crops[k], calMatrix: calMatrix,
                       fittedCALBThisRun: fittedCALBThisRun, establishedRESBThisRun: establishedRESBThisRun,
                       calibrationReference: calibration?.referenceDeclaration, model: model, builtin: !corrected, folder: folder, savePNG: savePNG,
                       exportPatches: &exportPatches, c5: &c5, record: &record)
            if k == scene.anchorFrame, let f = decoded.frames[k], let p = scene.target(k) {
                anchor = ParityJudge.nativeMean(f, placed: p, rect: (0.1, 0.1, 0.8, 0.8))
                record.checks.append(ParityCheck(name: "frame\(k).anchorMean", verdict: .recorded, detail: "plate-red export mean Y'CbCr \(anchor ?? [])"))
            }
        }
        record.summary = ScenarioSummary(scenario: record.scenario, compositor: record.compositor, frames: scene.frames, activeLayers: layers,
                                         exportPatches: exportPatches, outputDeclaration: decoded.interpretation.conversion,
                                         outputTrackDeclaration: decoded.interpretation.track, anchorMean: anchor, c5Verdicts: c5)
        record.summary?.colorContract = ColorContractV3.identity
        record.summary?.calibrationParameters = calMatrix == nil ? nil : calibration?.parameters
    }

    static func firstFrame(of file: String, scene: ParityScene) -> Int { scene.frames.first { scene.sourceFile($0) == file } ?? 0 }

    // MARK: per frame

    static func judgeFrame(_ k: Int, scene: ParityScene, decoded: FullPreviewParityIO.Decoded, reference: FullPreviewParityIO.Decoded?,
                           sources: [String: FullPreviewParityIO.Decoded], crop: PreviewCrop?, calMatrix: [[Double]]?,
                           fittedCALBThisRun: Bool = false, establishedRESBThisRun: Bool = false, calibrationReference: ColorDeclaration?,
                           model: Resampling.Frozen?, builtin: Bool, folder: URL, savePNG: Bool,
                           exportPatches: inout [Int: [[Double]]], c5: inout [String: ParityVerdict], record: inout RunRecord) {
        let p = "frame\(k)"
        guard let export = decoded.frames[k] else { record.checks.append(ParityCheck(name: "\(p).exportFrame", verdict: .fail, detail: "no decoded export frame at PTS \(k)/30")); return }
        record.checks.append(ParityCheck(name: "\(p).exportTiming", verdict: decoded.exactTimes.contains(k) ? .pass : .fail, detail: "export presentation time exactly \(k)/30: \(decoded.exactTimes.contains(k))"))
        let calibrated = crop.flatMap { c in calMatrix.map { ParityJudge.calibrated(c, matrix: $0) } }
        if savePNG {
            if let crop { FullPreviewParityIO.savePNG(crop, folder.appendingPathComponent("evidence/\(p)-preview.png")) }
            FullPreviewParityIO.savePNG(export, folder.appendingPathComponent("evidence/\(p)-export.png"))
        }
        // Identity.
        if let placed = scene.target(k) {
            if let expect = scene.sourceFrame(k) {
                let e = ParityCode.read(placed: placed, luma: ParityCode.nativeSampler(export))
                let ok = e.map { $0.sourceID == placed.sourceID && $0.frame == expect && $0.margin >= ParityThresholdsV1.codeMarginMinimum }
                record.checks.append(ParityCheck(name: "\(p).exportIdentity", verdict: e == nil ? .inconclusive : (ok! ? .pass : .fail),
                                                 detail: "expected id \(placed.sourceID) frame \(expect); read \(e.map { "id \($0.sourceID) frame \($0.frame) margin \($0.margin)" } ?? "unreadable")"))
                if let crop {
                    let r = ParityCode.read(placed: placed, luma: ParityCode.cropSampler(crop))
                    let okp = r.map { $0.sourceID == placed.sourceID && $0.frame == expect && $0.margin >= ParityThresholdsV1.codeMarginMinimum }
                    record.checks.append(ParityCheck(name: "\(p).previewIdentity", verdict: r == nil ? .inconclusive : (okp! ? .pass : .fail),
                                                     detail: "read \(r.map { "id \($0.sourceID) frame \($0.frame) margin \($0.margin)" } ?? "unreadable")"))
                } else { record.checks.append(ParityCheck(name: "\(p).previewIdentity", verdict: .notRun, detail: "no stable capture")) }
            } else {
                record.checks.append(ParityCheck(name: "\(p).identity", verdict: .notVerified, detail: "uncoded source; identity not verifiable"))
            }
        } else {
            let ey = export.y.mean(x: 0, y: 0, w: export.width, h: export.height)
            record.checks.append(ParityCheck(name: "\(p).gapBlackExport", verdict: ey <= 20 ? .pass : .fail, detail: String(format: "export mean Y' %.2f (gap)", ey)))
            if crop != nil { record.checks.append(ParityG5V3.gapBlackPreview(calibrated: calibrated, prefix: p)) }   // managed (v3 table)
        }
        // Masks and overlay exclusion.
        var exclusion: [Bool]?
        if let ref = reference?.frames[k] {
            let refPredict = calibrated == nil ? nil : ParityG5V3.referencePrediction(output: ParityG5V3.managedDeclaration(decoded.interpretation))
            let maskPreview = refPredict == nil ? nil : calibrated   // never difference a calibrated crop against an encoded reference
            let note = calibrated != nil && refPredict == nil ? "\(ParityG5V3.tag): output declaration outside parity-color-v3" : record.prerequisites.calibrationNote
            let (checks, _) = ParityJudge.masks(frame: export, reference: ref, layout: scene.layout(k), preview: maskPreview, prefix: p, calibrationNote: note,
                                                referencePrediction: refPredict)
            record.checks += checks.map { ParityG5V3.isPreviewMaskCheck($0.name) ? ParityG5V3.tagRepresentation($0, calibrated: maskPreview != nil) : $0 }
            if let crop { exclusion = ParityJudge.overlayExclusion(frame: export, reference: ref, mapping: crop.mapping, width: crop.r.width, height: crop.r.height) }
        } else if scene.reference != nil {
            record.checks.append(ParityCheck(name: "\(p).mask", verdict: .inconclusive, detail: "reference export frame missing"))
        }
        // Geometry.
        if let placed = scene.target(k), let c = calibrated ?? crop {
            record.checks.append(ParityG5V3.tagRepresentation(ParityJudge.geometry(preview: c, placed: placed, withModel: model != nil, prefix: p), calibrated: calibrated != nil))
        }
        // Patch colour (M scenarios).
        if let tagged = scene.colourTagged, let placed = scene.target(k), let file = scene.sourceFile(k), let sd = sources[file], let sf = scene.sourceFrame(k), let sframe = sd.frames[sf] {
            let srcPlaced = PlacedSource(sourceID: placed.sourceID, x: 0, y: 0, w: Double(sframe.width), h: Double(sframe.height))
            var measures: [ParityJudge.PatchMeasure] = [], ex: [[Double]] = []
            for i in 0..<ParityLayout.patchCount {
                let r = ParityLayout.patch(i)
                let e = ParityJudge.nativeMean(export, placed: placed, rect: r)
                measures.append(ParityJudge.PatchMeasure(index: i, source: ParityJudge.nativeMean(sframe, placed: srcPlaced, rect: r), export: e,
                                                         previewRaw: crop.flatMap { ParityJudge.cropMean($0, placed: placed, rect: r) },
                                                         previewCalibrated: calibrated.flatMap { ParityJudge.cropMean($0, placed: placed, rect: r) }))
                if let e { ex.append(e) }
            }
            exportPatches[k] = ex.count == ParityLayout.patchCount ? ex : []
            // parity-color-v3 (task 98): managed colour (previewVsExportColour, C5.previewFollowsDeclaration) compares the calibrated
            // capture with the v3 prediction in lab.v2; raw and Export-side C5 (lab.v1) are unchanged.
            let checks = ParityJudge.patchColour(measures, source: sd.interpretation, output: decoded.interpretation, tagged: tagged,
                                                 managedCalibration: calibrated != nil, prefix: p)
            record.checks += checks
            for c in checks where c.name.contains(".C5.") { c5["\(p).\(c.name.split(separator: ".").last!)"] = c.verdict }
            if let roi = scene.roi, let dims = try? FullPreviewParityIO.saveROI(folder: folder, frame: k, export: export, roi: roi, preview: calibrated) {
                record.roiDimensions["\(k)"] = dims
            }
        }
        // Fidelity.
        if let placed = scene.target(k) {
            if let c = calibrated, let model {
                record.checks.append(ParityG4V3.frameFidelity(export: export, calibrated: c, model: model, placed: placed, exclude: exclusion, prefix: p))
            } else {
                // Not evaluable: state exactly which frozen inputs were supplied to frame checks, separately from models fitted or
                // established in this run. Machine-readable flags (1 = yes, 0 = no) and a reason code for exact runner matching:
                // dependency.reasonCode 1 = frozen CAL-B and frozen RES-B both not usable, 2 = only frozen RES-B not usable,
                // 3 = only frozen CAL-B not usable. The verdict stays INCONCLUSIVE.
                let calUsable = calMatrix != nil, resUsable = model != nil
                let code: Double = !calUsable && !resUsable ? 1 : (calUsable && !resUsable ? 2 : 3)
                func yn(_ b: Bool) -> String { b ? "yes" : "no" }
                let detail = crop == nil ? "no capture"
                    : "not evaluable: frozen CAL-B supplied to frame checks: \(yn(calUsable)); frozen RES-B supplied to frame checks: \(yn(resUsable)); "
                      + "CAL-B fitted in this run: \(yn(fittedCALBThisRun)) (not used for frame checks); RES-B established in this run: \(yn(establishedRESBThisRun)) (not used for frame checks). "
                      + "calibration: \(record.prerequisites.calibrationNote); resampling: \(record.prerequisites.resamplingNote)"
                let values: [String: Double] = crop == nil ? [:] : [
                    "dependency.frozenCALBUsable": calUsable ? 1 : 0, "dependency.frozenRESBUsable": resUsable ? 1 : 0,
                    "dependency.fittedCALBThisRun": fittedCALBThisRun ? 1 : 0, "dependency.establishedRESBThisRun": establishedRESBThisRun ? 1 : 0,
                    "dependency.reasonCode": code]
                record.checks.append(ParityCheck(name: "\(p).fidelity", verdict: crop == nil ? .notRun : .inconclusive, detail: detail, values: values))
            }
        }
        // Edges (uniform plates reaching the output edge).
        if scene.edgeFrames.contains(k), let placed = scene.target(k), let file = scene.sourceFile(k), let sd = sources[file] {
            let idx = sd.frames.keys.sorted().first
            let levels: (y: ClosedRange<Double>, c: ClosedRange<Double>)? = idx.flatMap { sd.frames[$0] }.map { f in
                let ys = f.y.data, cs = f.cb.data + f.cr.data
                return (Double(ys.min()!)...Double(ys.max()!), Double(cs.min()!)...Double(cs.max()!))
            }
            record.checks.append(ParityJudge.exportEdge(export: export, placed: placed, sourceLevels: levels, builtin: builtin, prefix: p))
            if let c = calibrated, let model, let lv = levels {
                let cx = c.r.width / 2 - 20, cy = c.r.height / 2 - 20
                var lum: [Double] = []
                for y in cy..<(cy + 40) { for x in cx..<(cx + 40) { lum.append(0.2126 * Double(c.r[x, y]) + 0.7152 * Double(c.g[x, y]) + 0.0722 * Double(c.b[x, y])) } }
                let mean = lum.reduce(0, +) / Double(lum.count)
                let noise = sqrt(lum.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lum.count))
                let level = (lv.y.lowerBound + lv.y.upperBound) / 2
                if let od = ParityG5V3.managedDeclaration(decoded.interpretation), let fwd = ParityG4V3.Forward(primaries: od.primaries ?? "") {
                    record.checks.append(ParityG5V3.tagRepresentation(ParityJudge.previewEdge(preview: c, model: model, placed: placed, level: (level - 16) * 255 / 219, noise: noise,
                                                                                               builtin: builtin, prefix: p, output: ParityG4V3.resamplingOutput(fwd)), calibrated: true))
                } else {
                    record.checks.append(ParityCheck(name: "\(p).previewEdge", verdict: .notVerified, detail: "\(ParityG5V3.tag): output declaration outside parity-color-v3"))
                }
            } else {
                record.checks.append(ParityCheck(name: "\(p).previewEdge", verdict: .notVerified, detail: "calibration or resampling model unavailable"))
            }
        }
    }

    // MARK: stages

    static func calibrationStage(scene: ParityScene, crops: [Int: PreviewCrop], sources: [String: FullPreviewParityIO.Decoded], folder: URL,
                                 provenance: ModelProvenance, frozen: Calibration.Frozen?, record: inout RunRecord) {
        guard let k = scene.frames.first(where: { crops[$0] != nil }), let crop = crops[k], let placed = scene.target(k),
              let sd = sources["otf-CAL.mp4"], let sframe = sd.frames[k] else {
            record.checks.append(ParityCheck(name: "CAL.patches", verdict: .notRun, detail: "no captured calibration frame or source frame")); return
        }
        // parity-color-v3 (task 97): the target P comes from the managed source declaration (track-declared primaries/transfer/matrix +
        // decoded range, SourceDeclarationV3); the source's own range declaration is recorded, never assumed.
        let managed = ParityG4V3.managedDeclaration(sd.interpretation)
        guard let decl = managed.declaration else {
            record.checks.append(ParityCheck(name: "CAL.reference", verdict: .inconclusive, detail: "\(ParityG4V3.managedTag): \(managed.note)")); return
        }
        record.checks.append(ParityCheck(name: "CAL.sourceDeclaration", verdict: .recorded,
                                         detail: "otf-CAL track \(ParityJudge.describe(sd.interpretation.track)); complete declaration: \(sd.interpretation.resolved != nil); \(managed.note)"))
        let srcPlaced = PlacedSource(sourceID: placed.sourceID, x: 0, y: 0, w: Double(sframe.width), h: Double(sframe.height))
        var sourceMeans: [Int: [Double]] = [:], captured: [Int: [Double]] = [:]
        for i in 0..<ParityLayout.patchCount {
            let r = ParityLayout.patch(i)
            if let meas = ParityJudge.cropMean(crop, placed: placed, rect: r) { captured[i] = meas }
            if let s = ParityJudge.nativeMean(sframe, placed: srcPlaced, rect: r) { sourceMeans[i] = s }
        }
        let targets = ParityG4V3.calibrationTargets(sourceMeans: sourceMeans, declaration: decl)
        let patches = ParityG4V3.calibrationPatches(captured: captured, targets: targets)
        if record.compositor == "builtin" {   // CAL-B: fit on training, validate, freeze (never overwrites an existing frozen file)
            let target = folder.appendingPathComponent("calibration-frozen.json")
            guard !FileManager.default.fileExists(atPath: target.path) else {
                record.checks.append(ParityCheck(name: "CAL-B.calibration", verdict: .notRun, detail: "calibration-frozen.json already exists; not overwritten")); return
            }
            let (f, o) = ParityG4V3.freezeCalibration(patches: patches, declaration: decl, provenance: provenance, clipNote: ParityG4V3.clipSummary(targets))
            write(f, target)
            var values: [String: Double] = ["validationMeanDE": f.validationDE.mean, "validationMaxDE": f.validationDE.max]
            if let o {
                values["admissible"] = o.admissibility.admissible ? 1 : 0
                values["maxMatrixDeviation"] = o.admissibility.maxMatrixDeviation
                values["maxOffset"] = o.admissibility.maxOffset
                values["holdoutPass"] = o.holdoutPass ? 1 : 0
                values["greyMonotonic"] = o.greyMonotonic ? 1 : 0
                values["validationPass"] = o.validationVerdict == .pass ? 1 : 0
            }
            record.checks.append(ParityCheck(name: "CAL-B.calibration", verdict: f.aggregateVerdict ?? .inconclusive,
                                             detail: f.reason + " (frozen to calibration-frozen.json, parameters \(f.parameters), \(ColorContractV3.id) \(ColorContractV3.frozenFingerprint))",
                                             values: values))
            record.prerequisites.calibrationValid = f.valid
            record.prerequisites.calibrationNote = f.valid ? "valid (this run, \(ColorContractV3.id))" : f.reason
        } else {                              // CAL-V: managed residual with the frozen v3 CAL-B only (never refitted)
            let admitted = ParityG4V3.admitCalibration(frozen, provenance: provenance)
            guard record.prerequisites.calibrationValid, admitted.usable, let f = frozen else {
                record.checks.append(ParityCheck(name: "CAL-V.residual", verdict: .inconclusive, detail: "CAL-B missing, invalid, refused or from another environment (\(admitted.note))")); return
            }
            let d = ParityG4V3.calibrationResidual(f, patches: patches)
            record.checks.append(ParityCheck(name: "CAL-V.residual", verdict: .recorded,
                                             detail: String(format: "%@: corrected display through frozen CAL-B: holdout ΔE00 lab.v2 mean %.3f max %.3f (recorded, not fitted)", ParityG4V3.managedTag, d.mean, d.max),
                                             values: ["mean": d.mean, "max": d.max]))
        }
    }

    /// D-042 (owner Option A, one-way dependency CAL-B → RES-B → RES-C): RES-B fits on the raw capture transformed by the frozen
    /// CAL-B matrix and consumes nothing else from CAL-B; it never writes or refits CAL-B. It runs only with a valid CAL-B whose stored
    /// fingerprint matches its matrix and whose environment and thresholds match this run, and records that fingerprint and provenance
    /// in the frozen RES-B. RES-C uses only an established frozen RES-B whose recorded CAL-B fingerprint equals the supplied CAL-B.
    static func resamplingStage(scene: ParityScene, crops: [Int: PreviewCrop], sources: [String: FullPreviewParityIO.Decoded], folder: URL,
                                provenance: ModelProvenance, calibration: Calibration.Frozen?, frozen: Resampling.Frozen?, record: inout RunRecord) {
        guard record.prerequisites.calibrationValid, let cal = calibration else {
            let name = record.compositor == "builtin" ? "RES-B.model" : "RES-C.fidelity"
            record.checks.append(ParityCheck(name: name, verdict: .inconclusive, detail: "calibration not usable: \(record.prerequisites.calibrationNote)")); return
        }
        guard let k = scene.frames.first(where: { crops[$0] != nil }), let raw = crops[k], let sd = sources["otf-RES.mp4"], let sframe = sd.frames[k] else {
            record.checks.append(ParityCheck(name: "RES.capture", verdict: .notRun, detail: "no captured resampling frame or source frame")); return
        }
        let name = record.compositor == "builtin" ? "RES-B.model" : "RES-C.fidelity"
        let managed = ParityG4V3.managedDeclaration(sd.interpretation)
        guard let decl = managed.declaration, let fwd = ParityG4V3.Forward(primaries: decl.primaries ?? ""),
              let source = ParityG4V3.resamplingSource(sframe, declaration: decl) else {
            record.checks.append(ParityCheck(name: name, verdict: .inconclusive, detail: "\(ParityG4V3.managedTag): resampling source not usable: \(managed.note)")); return
        }
        // Capture: CAL-B residual applied once (clamp01(M · capture + b)). Prediction: encoded-domain resample, then the v3 forward
        // transform once (Resampling output). Neither is applied twice.
        let c = ParityJudge.calibrated(raw, matrix: cal.matrix)
        var previewLuma = ParityPlane(width: c.r.width, height: c.r.height)
        for i in 0..<previewLuma.data.count { previewLuma.data[i] = 0.2126 * c.r.data[i] + 0.7152 * c.g.data[i] + 0.0722 * c.b.data[i] }
        let inputs = resamplingInputs(source: source.plane, preview: previewLuma, mapping: c.mapping)
        record.checks.append(ParityCheck(name: "\(record.compositor == "builtin" ? "RES-B" : "RES-C").calibrationDependency", verdict: .recorded,
                                         detail: "consumes frozen CAL-B \(cal.parameters) (stored \(cal.storedParameters)), CAL-B provenance: \(cal.provenance.displayProfile), video rect \(cal.provenance.videoRectPixels), app \(cal.provenance.appBinarySHA256.prefix(16))…; \(fwd.description); \(managed.note)",
                                         values: ["sourceMaxChromaDeparture": source.maxChroma]))
        if record.compositor == "builtin" {   // RES-B: establish and freeze (never overwrites an existing frozen file)
            let target = folder.appendingPathComponent("resampling-frozen.json")
            guard !FileManager.default.fileExists(atPath: target.path) else {
                record.checks.append(ParityCheck(name: "RES-B.model", verdict: .notRun, detail: "resampling-frozen.json already exists; not overwritten")); return
            }
            let f = ParityG4V3.establishResampling(x: inputs.x, y: inputs.y, validation: inputs.validation, calibration: cal, provenance: provenance, forward: fwd)
            write(f, target)
            record.checks.append(ParityCheck(name: "RES-B.model", verdict: f.established ? .pass : .inconclusive,
                                             detail: "\(ParityG4V3.managedTag): " + (f.established ? "established: \(f.candidate!.rawValue)" : "unresolved") + " — \(f.reason)" + (f.disagreement.map { "; \($0)" } ?? "")))
            record.prerequisites.resamplingEstablished = f.established
            record.prerequisites.resamplingNote = f.established ? "established (this run, \(ColorContractV3.id))" : f.reason
        } else {                              // RES-C: validation fidelity with the frozen v3 RES-B model only
            let admitted = ParityG4V3.admitResampling(frozen, calibration: cal, calibrationUsable: record.prerequisites.calibrationValid, provenance: provenance)
            guard record.prerequisites.resamplingEstablished, admitted.usable, let f = frozen, let fid = ParityG4V3.resamplingFidelity(f, validation: inputs.validation, forward: fwd) else {
                record.checks.append(ParityCheck(name: "RES-C.fidelity", verdict: .inconclusive,
                                                 detail: "frozen RES-B not usable: \(admitted.note); \(record.prerequisites.resamplingNote)")); return
            }
            let ok = fid.n > 0 && fid.rms <= ParityThresholdsV1.resamplingValidationRMS && fid.max <= ParityThresholdsV1.resamplingValidationMax
            record.checks.append(ParityCheck(name: "RES-C.fidelity", verdict: fid.n == 0 ? .inconclusive : (ok ? .pass : .fail),
                                             detail: String(format: "%@: frozen %@ on the corrected display: validation RMS %.3f max %.3f", ParityG4V3.managedTag, f.candidate!.rawValue, fid.rms, fid.max),
                                             values: ["rms": fid.rms, "max": fid.max]))
        }
    }

    /// Training profiles (vertical structures → x, horizontal → y) and validation blocks from the fixed resolution regions.
    static func resamplingInputs(source: ParityPlane, preview: ParityPlane, mapping m: CropMapping) -> (x: [Resampling.Profile], y: [Resampling.Profile], validation: [Resampling.ValidationBlock]) {
        var xs: [Resampling.Profile] = [], ys: [Resampling.Profile] = [], blocks: [Resampling.ValidationBlock] = []
        for (index, r) in ParityLayout.resolutionRegions.enumerated() {
            let sx0 = r.x - 8, sy0 = r.y - 8
            let ci0 = Int(m.crop(Double(r.x + 4), 0).0.rounded(.up)), ci1 = Int(m.crop(Double(r.x + r.w - 4), 0).0.rounded(.down))
            let cj0 = Int(m.crop(0, Double(r.y + 4)).1.rounded(.up)), cj1 = Int(m.crop(0, Double(r.y + r.h - 4)).1.rounded(.down))
            guard ci0 >= 0, cj0 >= 0, ci1 <= preview.width, cj1 <= preview.height, ci1 > ci0 + 4, cj1 > cj0 + 2 else { continue }
            if r.validation {
                blocks.append(Resampling.ValidationBlock(regionIndex: index, source: source.crop(x: sx0, y: sy0, w: r.w + 16, h: r.h + 16),
                                                         measured: preview.crop(x: ci0, y: cj0, w: ci1 - ci0, h: cj1 - cj0),
                                                         basePhaseX: m.originX + Double(sx0) * m.scaleX - Double(ci0), basePhaseY: m.originY + Double(sy0) * m.scaleY - Double(cj0),
                                                         scaleX: m.scaleX, scaleY: m.scaleY))
                continue
            }
            if r.kind == "hlines" || r.kind == "hedge" {
                let srcCols = (r.x + 8)..<(r.x + r.w - 8)
                let srcProfile = (sy0..<(r.y + r.h + 8)).map { y in srcCols.map { Double(source[min(source.width - 1, $0), min(source.height - 1, max(0, y))]) }.reduce(0, +) / Double(srcCols.count) }
                let cCols = Int(m.crop(Double(r.x + 8), 0).0.rounded(.up))..<Int(m.crop(Double(r.x + r.w - 8), 0).0.rounded(.down))
                let measured = (cj0..<cj1).map { y in cCols.map { Double(preview[$0, y]) }.reduce(0, +) / Double(max(1, cCols.count)) }
                ys.append(Resampling.Profile(regionIndex: index, axis: "y", source: srcProfile, measured: measured, basePhase: m.originY + Double(sy0) * m.scaleY - Double(cj0), scale: m.scaleY))
            } else {
                let srcRows = (r.y + 8)..<(r.y + r.h - 8)
                let srcProfile = (sx0..<(r.x + r.w + 8)).map { x in srcRows.map { Double(source[min(source.width - 1, max(0, x)), $0]) }.reduce(0, +) / Double(srcRows.count) }
                let cRows = Int(m.crop(0, Double(r.y + 8)).1.rounded(.up))..<Int(m.crop(0, Double(r.y + r.h - 8)).1.rounded(.down))
                let measured = (ci0..<ci1).map { x in cRows.map { Double(preview[x, $0]) }.reduce(0, +) / Double(max(1, cRows.count)) }
                xs.append(Resampling.Profile(regionIndex: index, axis: "x", source: srcProfile, measured: measured, basePhase: m.originX + Double(sx0) * m.scaleX - Double(ci0), scale: m.scaleX))
            }
        }
        return (xs, ys, blocks)
    }

    // MARK: models

    static func loadCalibration(args: [String]) -> Calibration.Frozen? {
        guard let p = value(after: "-OTFParityCalibration", in: args), let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return nil }
        return try? decoder().decode(Calibration.Frozen.self, from: d)
    }
    static func loadResampling(args: [String]) -> Resampling.Frozen? {
        guard let p = value(after: "-OTFParityResampling", in: args), let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return nil }
        return try? decoder().decode(Resampling.Frozen.self, from: d)
    }
    /// Sets the prerequisites from the frozen files (CAL-B/RES-B runs set them in their own stage). No substitution, no refit.
    static func loadModels(args: [String], provenance: ModelProvenance, record: inout RunRecord) {
        if record.scenario == "CAL" && record.compositor == "builtin" { return }
        // parity-color-v3 (task 97): v1 / retired v2 / altered models are refused (ParityG4V3.admit*), never migrated or refitted.
        let calibration = loadCalibration(args: args)
        if calibration != nil || value(after: "-OTFParityCalibration", in: args) != nil {
            let a = ParityG4V3.admitCalibration(calibration, provenance: provenance)
            record.prerequisites.calibrationValid = a.usable
            record.prerequisites.calibrationNote = calibration == nil ? "frozen CAL-B unreadable" : a.note
        } else { record.prerequisites.calibrationNote = "no frozen CAL-B supplied" }
        if record.scenario == "RES" && record.compositor == "builtin" { return }
        let resampling = loadResampling(args: args)
        if resampling != nil || value(after: "-OTFParityResampling", in: args) != nil {
            // One-way: a usable RES-B requires a usable CAL-B (D-042); RES-B never makes CAL-B usable.
            let a = ParityG4V3.admitResampling(resampling, calibration: calibration, calibrationUsable: record.prerequisites.calibrationValid, provenance: provenance)
            record.prerequisites.resamplingEstablished = a.usable
            record.prerequisites.resamplingNote = resampling == nil ? "frozen RES-B unreadable" : a.note
        } else { record.prerequisites.resamplingNote = "no frozen RES-B supplied" }
    }

    // MARK: export

    static func export(_ t: Timeline, media: [UUID: MediaAsset], to url: URL, corrected: Bool, record: inout RunRecord) async throws -> URL? {
        let destination = ExportDestination(url: url, confirmedReplace: false, identityAtConfirmation: nil)
        let outcome: ExportOutcome
        let options = corrected ? ExperimentalCompositorOptions(edgeCoverage: .fullRectangle) : nil
        if !t.spectra.isEmpty {
            let limits = SpectrumTimelineExportLimits(stepTimeout: 30, jobTimeout: 300, frameMemoryBudgetBytes: 128 << 20)
            outcome = await ExportService.exportSpectrumTimeline(t, media: media, enabled: true, to: destination, limits: limits, experimentalCompositor: options)
        } else {
            var plan = try await CompositionPlanner.plan(t, media: media, settings: .m1)
            if let options { plan = try plan.replacingVideoComposition(withExperimental: options) }
            outcome = await ExportService.export(plan, to: destination, sources: Array(media.values), progress: { _ in })
        }
        if case .completed(let u) = outcome { return u }
        record.checks.append(ParityCheck(name: "export.\(url.deletingPathExtension().lastPathComponent)", verdict: .fail, detail: "\(outcome)"))
        return nil
    }

    // MARK: preview

    /// Paused preview settled at frame k. STALE-CAPTURE-FIX-79: player time alone is not settlement. Requires, from existing
    /// observable state only (no additional seek): the seek requested here is still the latest (token), it left the host's pending
    /// list as COMPLETED (overlay confirmation for this token with finished == true, displayed frame k; see `SeekProbe`), the item
    /// and generation are unchanged, the player is paused at exactly k, the player layer is ready for display, no still image covers
    /// it, plus the existing Spectrum/subtitle conditions. Then a monotonic freshness boundary is taken (mach absolute ticks, the
    /// clock of SCStreamFrameInfo.displayTime). A superseded, interrupted or unverifiable seek never settles.
    /// The boundary does not prove that the layer already shows frame k; the grab's identity gate and judgment decide that.
    static func settle(_ k: Int, scene: ParityScene, view: PlayerNSView) async -> (Bool, SeekSettlement) {
        let s = ProjectStore.shared, overlay = view.spectrumOverlay
        let spectra = scene.timeline.spectra.filter { $0.visible(atFrame: k) }.map(\.id)
        let subs = scene.timeline.subtitles.filter { (($0.start)..<($0.start + $0.length)).contains(k) }.map(\.id)
        let item = s.player.currentItem
        var d = SeekSettlement(frame: k)
        s.seek(to: k)
        d.token = s.seekToken; d.requested = CACurrentMediaTime()
        d.confirmationClearedAtRequest = overlay.confirmedFrame == nil   // seekRequested clears it synchronously for this (non-Pause) seek
        func snapshot() {
            d.readyForDisplay = view.playerLayer.isReadyForDisplay; d.showingStill = view.isShowingStill
            d.displayedFrame = view.displayedFrameForExperiment; d.overlayConfirmedFrame = overlay.confirmedFrame
            let t = s.player.currentTime(); d.playerTime = "\(t.value)/\(t.timescale)"
        }
        let deadline = d.requested + 15
        while true {
            let state = SeekProbe.classify(requestedToken: d.token, currentToken: s.seekToken, itemChanged: s.player.currentItem !== item,
                                           confirmationClearedAtRequest: d.confirmationClearedAtRequest, pending: view.hasPendingSpectrumSeek,
                                           overlayConfirmedFrame: overlay.confirmedFrame, displayedFrame: view.displayedFrameForExperiment, frame: k)
            switch state {
            case .superseded, .itemChanged, .unverifiable, .interrupted:
                d.outcome = state.rawValue; snapshot(); return (false, d)
            case .inFlight: break
            case .completed:
                if d.completionObserved == nil { d.completionObserved = CACurrentMediaTime() }
                if previewConditions(k, scene: scene, view: view, spectra: spectra, subs: subs) {
                    d.fenceTicks = mach_absolute_time()
                    d.fenceSeconds = FullPreviewWindowCapture.seconds(machTicks: d.fenceTicks!)
                    d.settled = CACurrentMediaTime(); d.outcome = "settled"; snapshot(); return (true, d)
                }
            }
            if CACurrentMediaTime() >= deadline {
                d.outcome = state == .completed ? "timeout: seek completed but the paused Preview conditions were not met within 15 s"
                                                : "timeout: seek not completed within 15 s"
                snapshot(); return (false, d)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The paused Preview conditions after a completed seek (existing conditions plus layer readiness and no covering still image).
    static func previewConditions(_ k: Int, scene: ParityScene, view: PlayerNSView, spectra: [UUID], subs: [UUID]) -> Bool {
        let s = ProjectStore.shared, overlay = view.spectrumOverlay
        guard s.appliedGeneration == s.generation, !s.isPlaying, CMTimeCompare(s.player.currentTime(), CMTime(value: Int64(k), timescale: 30)) == 0,
              view.playerLayer.isReadyForDisplay, !view.isShowingStill else { return false }
        if !scene.timeline.spectra.isEmpty {
            guard overlay.confirmedFrame == k else { return false }
            if spectra.isEmpty ? !overlay.layers.isEmpty : (overlay.presentedFrameForTest != k || overlay.layers.count != spectra.count) { return false }
        }
        for id in subs {
            guard let l = view.subtitleLayerForTest(id), l.contents != nil, (l.presentation()?.opacity ?? l.opacity) > 0.5 else { return false }
        }
        return true
    }

    /// Tries to make the Preview video rectangle exactly 960×540 capture pixels with an integral origin (not mandatory).
    /// Optional attempt (G0) to make the Preview video rectangle exactly 960×540 physical pixels at an integral physical origin.
    /// GEOMETRY-FIX-84: bounded, measured, discrete window adjustments (`TwoToOne.decide`): every decision uses a fresh measurement,
    /// so the result is verified after the last resize; window sizes are never revisited; a non-responsive resize, constraints or
    /// the attempt bound stop the attempt. Not achieving 2:1 is not a failure (the run continues with the actual size).
    static func attemptTwoToOne(window: NSWindow, view: PlayerNSView) async -> WindowInfo {
        var info = WindowInfo()
        func measure() -> TwoToOneSample {
            view.layoutSubtreeIfNeeded()
            let vr = view.playerLayer.videoRect, b = view.bounds, inWindow = view.convert(vr, to: nil), f = window.frame
            return TwoToOneSample(windowW: f.width, windowH: f.height, viewW: b.width, viewH: b.height,
                                  videoX: inWindow.minX, videoY: inWindow.minY, videoW: vr.width, videoH: vr.height, scale: Double(window.backingScaleFactor))
        }
        let minFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? window.frame.size
        let initial = measure()
        var current = initial, attempts: [TwoToOneAttempt] = [], reason = ""
        loop: while true {
            switch TwoToOne.decide(current: current, attempts: attempts, initial: initial,
                                   minSize: (Double(minFrame.width), Double(minFrame.height)), maxSize: (Double(visible.width), Double(visible.height))) {
            case .done(let achieved, let why):
                info.achievedTwoToOne = achieved; reason = why; break loop
            case .resize(let w, let h, let axis, let error, let step):
                var attempt = TwoToOneAttempt(index: attempts.count, before: current, axis: axis, errorPoints: error, stepPoints: step, requestedW: w, requestedH: h)
                var f = window.frame
                f.size = NSSize(width: w, height: h)
                window.setFrame(f, display: true)
                try? await Task.sleep(nanoseconds: 300_000_000)   // unchanged settling wait
                current = measure()                                // re-read; the request is never assumed to have succeeded
                attempt.after = current
                attempts.append(attempt)
            }
        }
        info.backingScale = current.scale
        info.videoRectPoints = [current.videoX, current.videoY, current.videoW, current.videoH]
        info.attempts = attempts
        info.finalSample = current
        info.finalReason = reason
        info.verifiedAfterLastResize = attempts.last.map { $0.after == current } ?? true
        info.note = info.achievedTwoToOne ? "2:1 achieved" : "2:1 not achieved (\(reason)); continuing with the actual size (not a failure)"
        return info
    }

    static func appBinaryHash() -> String {
        let exe = Bundle.main.executableURL
        let dylib = exe?.deletingLastPathComponent().appendingPathComponent("OnTheFrame.debug.dylib")
        let parts = [exe, dylib].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }.map { FullPreviewParityIO.sha256($0) }
        return parts.joined(separator: "+")
    }

    // MARK: aggregation (C1–C7)

    static func aggregate(folder: URL) {
        let subs = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.hasDirectoryPath }
        var summaries: [ScenarioSummary] = [], dims: [String: (URL, [String: [String: Int]])] = [:]
        for d in subs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("full-parity-result.json")),
                  let r = try? decoder().decode(RunRecord.self, from: data), let s = r.summary else { continue }
            summaries.append(s); dims["\(s.scenario)/\(s.compositor)"] = (d, r.roiDimensions)
        }
        let checks = Conformance.evaluate(summaries) { sc, comp, k in
            guard let entry = dims["\(sc)/\(comp)"], let d = entry.1["\(k)"] else { return nil }
            return FullPreviewParityIO.loadROI(folder: entry.0, frame: k, dims: d)
        }
        struct Out: Codable { let thresholdsVersion: String; let thresholdsFingerprint: String; let runs: [String]; let checks: [ParityCheck] }
        write(Out(thresholdsVersion: ParityThresholdsV1.version, thresholdsFingerprint: ParityThresholdsV1.fingerprint,
                  runs: summaries.map { "\($0.scenario)/\($0.compositor)" }.sorted(), checks: checks), folder.appendingPathComponent("conformance-result.json"))
    }

    enum RunError: Error, CustomStringConvertible {
        case argument(String), setup(String)
        var description: String { switch self { case .argument(let s): "argument: \(s)"; case .setup(let s): "setup: \(s)" } }
    }
}
#endif
