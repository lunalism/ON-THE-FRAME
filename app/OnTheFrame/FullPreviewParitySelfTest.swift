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
    struct WindowInfo: Codable { var attempted = true; var achievedTwoToOne = false; var videoRectPoints: [Double] = []; var backingScale = 0.0; var note = "" }
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
        var sourceSHA256Before: [String: String] = [:], sourceSHA256After: [String: String] = [:]
        var provenance: ModelProvenance?
        var notes: [String] = []
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
        for k in scene.frames {
            let settled = await settle(k, scene: scene, view: view)
            if !settled { record.checks.append(ParityCheck(name: "frame\(k).previewSettled", verdict: .inconclusive, detail: "preview did not settle within 15 s")); continue }
            // A. Preview stability (pixel fingerprint of the ROI). B. Source identity is judged later on the crop, independently.
            let g = await capture.grab()
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
        let calMatrix = record.prerequisites.calibrationValid ? calibration?.matrix : nil
        let model = record.prerequisites.resamplingEstablished ? resampling : nil

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
    }

    static func firstFrame(of file: String, scene: ParityScene) -> Int { scene.frames.first { scene.sourceFile($0) == file } ?? 0 }

    // MARK: per frame

    static func judgeFrame(_ k: Int, scene: ParityScene, decoded: FullPreviewParityIO.Decoded, reference: FullPreviewParityIO.Decoded?,
                           sources: [String: FullPreviewParityIO.Decoded], crop: PreviewCrop?, calMatrix: [[Double]]?, calibrationReference: ColorDeclaration?,
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
            if let crop {
                let m = FullPreviewWindowCapture.meanLuma(crop)
                record.checks.append(ParityCheck(name: "\(p).gapBlackPreview", verdict: m <= 8 ? .pass : .fail, detail: String(format: "preview mean luma %.2f (gap)", m)))
            }
        }
        // Masks and overlay exclusion.
        var exclusion: [Bool]?
        if let ref = reference?.frames[k] {
            let (checks, _) = ParityJudge.masks(frame: export, reference: ref, layout: scene.layout(k), preview: calibrated, prefix: p, calibrationNote: record.prerequisites.calibrationNote)
            record.checks += checks
            if let crop { exclusion = ParityJudge.overlayExclusion(frame: export, reference: ref, mapping: crop.mapping, width: crop.r.width, height: crop.r.height) }
        } else if scene.reference != nil {
            record.checks.append(ParityCheck(name: "\(p).mask", verdict: .inconclusive, detail: "reference export frame missing"))
        }
        // Geometry.
        if let placed = scene.target(k), let c = calibrated ?? crop {
            record.checks.append(ParityJudge.geometry(preview: c, placed: placed, withModel: model != nil, prefix: p))
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
            let checks = ParityJudge.patchColour(measures, source: sd.interpretation, output: decoded.interpretation, tagged: tagged,
                                                 calibrationReference: calMatrix == nil ? nil : calibrationReference, prefix: p)
            record.checks += checks
            for c in checks where c.name.contains(".C5.") { c5["\(p).\(c.name.split(separator: ".").last!)"] = c.verdict }
            if let roi = scene.roi, let dims = try? FullPreviewParityIO.saveROI(folder: folder, frame: k, export: export, roi: roi, preview: calibrated) {
                record.roiDimensions["\(k)"] = dims
            }
        }
        // Fidelity.
        if let placed = scene.target(k) {
            if let c = calibrated, let model {
                record.checks.append(ParityJudge.fidelity(export: export, preview: c, model: model, placed: placed, exclude: exclusion, prefix: p))
            } else {
                record.checks.append(ParityCheck(name: "\(p).fidelity", verdict: crop == nil ? .notRun : .inconclusive,
                                                 detail: crop == nil ? "no capture" : "calibration: \(record.prerequisites.calibrationNote); resampling: \(record.prerequisites.resamplingNote)"))
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
                record.checks.append(ParityJudge.previewEdge(preview: c, model: model, placed: placed, level: (level - 16) * 255 / 219, noise: noise, builtin: builtin, prefix: p))
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
        // The reference colour needs the conversion of the decoded calibration source (declared primaries/transfer/matrix + decoded
        // 420v range). The source's own range declaration is recorded, not assumed.
        guard let refDecl = sd.interpretation.conversion, let m = refDecl.matrix else {
            record.checks.append(ParityCheck(name: "CAL.reference", verdict: .inconclusive, detail: "calibration source primaries/transfer/matrix not all declared and agreeing: \(sd.interpretation.problem ?? "unresolved")")); return
        }
        record.checks.append(ParityCheck(name: "CAL.sourceDeclaration", verdict: .recorded,
                                         detail: "otf-CAL track \(ParityJudge.describe(sd.interpretation.track)); complete declaration: \(sd.interpretation.resolved != nil)"))
        let srcPlaced = PlacedSource(sourceID: placed.sourceID, x: 0, y: 0, w: Double(sframe.width), h: Double(sframe.height))
        var patches: [Calibration.Patch] = []
        for i in 0..<ParityLayout.patchCount {
            let r = ParityLayout.patch(i)
            guard let meas = ParityJudge.cropMean(crop, placed: placed, rect: r), let s = ParityJudge.nativeMean(sframe, placed: srcPlaced, rect: r),
                  let ref = ColorMath.rgb(y: s[0], cb: s[1], cr: s[2], matrix: m, fullRange: sframe.declaration.fullRange ?? false) else { continue }
            patches.append(Calibration.Patch(index: i, measured: meas, reference: [ref.r, ref.g, ref.b], pixels: 0))
        }
        let refForLab = ColorDeclaration(primaries: refDecl.primaries, transfer: refDecl.transfer, matrix: refDecl.matrix, fullRange: false, origin: "calibration reference")
        if record.compositor == "builtin" {   // CAL-B: fit on training, validate, freeze (never overwrites an existing frozen file)
            let target = folder.appendingPathComponent("calibration-frozen.json")
            guard !FileManager.default.fileExists(atPath: target.path) else {
                record.checks.append(ParityCheck(name: "CAL-B.calibration", verdict: .notRun, detail: "calibration-frozen.json already exists; not overwritten")); return
            }
            let f = Calibration.calibrate(patches: patches, reference: refForLab, provenance: provenance)
            write(f, target)
            record.checks.append(ParityCheck(name: "CAL-B.calibration", verdict: f.valid ? .pass : .fail,
                                             detail: f.reason + " (frozen to calibration-frozen.json, parameters \(f.parameters))",
                                             values: ["validationMeanDE": f.validationDE.mean, "validationMaxDE": f.validationDE.max]))
            record.prerequisites.calibrationValid = f.valid
            record.prerequisites.calibrationNote = f.valid ? "valid (this run)" : f.reason
        } else {                              // CAL-V: residual with the frozen CAL-B only
            guard record.prerequisites.calibrationValid, let f = frozen, f.valid, f.integrityOK, f.provenance.environmentMatches(provenance) else {
                record.checks.append(ParityCheck(name: "CAL-V.residual", verdict: .inconclusive, detail: "CAL-B missing, invalid or from another environment (\(record.prerequisites.calibrationNote))")); return
            }
            var des: [Double] = []
            for p in patches where ParityLayout.validationPatches.contains(p.index) {
                let a = Calibration.apply(f.matrix, p.measured)
                if let la = ColorMath.lab((a[0], a[1], a[2]), primaries: refForLab.primaries!, transfer: refForLab.transfer!),
                   let lb = ColorMath.lab((p.reference[0], p.reference[1], p.reference[2]), primaries: refForLab.primaries!, transfer: refForLab.transfer!) { des.append(ColorMath.deltaE2000(la, lb)) }
            }
            let d = Distribution(des)
            record.checks.append(ParityCheck(name: "CAL-V.residual", verdict: .recorded,
                                             detail: String(format: "corrected display through frozen CAL-B: validation ΔE00 mean %.3f max %.3f (recorded, not fitted)", d.mean, d.max),
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
        let c = ParityJudge.calibrated(raw, matrix: cal.matrix)
        var previewLuma = ParityPlane(width: c.r.width, height: c.r.height)
        for i in 0..<previewLuma.data.count { previewLuma.data[i] = 0.2126 * c.r.data[i] + 0.7152 * c.g.data[i] + 0.0722 * c.b.data[i] }
        var sourceLuma = ParityPlane(width: sframe.width, height: sframe.height)
        for i in 0..<sourceLuma.data.count { sourceLuma.data[i] = (sframe.y.data[i] - 16) * 255 / 219 }
        let inputs = resamplingInputs(source: sourceLuma, preview: previewLuma, mapping: c.mapping)
        record.checks.append(ParityCheck(name: "\(record.compositor == "builtin" ? "RES-B" : "RES-C").calibrationDependency", verdict: .recorded,
                                         detail: "consumes frozen CAL-B \(cal.parameters) (stored \(cal.storedParameters)), CAL-B provenance: \(cal.provenance.displayProfile), video rect \(cal.provenance.videoRectPixels), app \(cal.provenance.appBinarySHA256.prefix(16))…"))
        if record.compositor == "builtin" {   // RES-B: establish and freeze (never overwrites an existing frozen file)
            let target = folder.appendingPathComponent("resampling-frozen.json")
            guard !FileManager.default.fileExists(atPath: target.path) else {
                record.checks.append(ParityCheck(name: "RES-B.model", verdict: .notRun, detail: "resampling-frozen.json already exists; not overwritten")); return
            }
            let f = Resampling.establish(xProfiles: inputs.x, yProfiles: inputs.y, validation: inputs.validation, calibration: cal.parameters,
                                         calibrationProvenance: cal.provenance, provenance: provenance)
            write(f, target)
            record.checks.append(ParityCheck(name: "RES-B.model", verdict: f.established ? .pass : .inconclusive,
                                             detail: (f.established ? "established: \(f.candidate!.rawValue)" : "unresolved") + " — \(f.reason)" + (f.disagreement.map { "; \($0)" } ?? "")))
            record.prerequisites.resamplingEstablished = f.established
            record.prerequisites.resamplingNote = f.established ? "established (this run)" : f.reason
        } else {                              // RES-C: validation fidelity with the frozen RES-B model only
            guard record.prerequisites.resamplingEstablished, let f = frozen, f.established, let cand = f.candidate, let px = f.phaseX, let py = f.phaseY,
                  f.calibrationParameters == cal.parameters, f.provenance.environmentMatches(provenance) else {
                record.checks.append(ParityCheck(name: "RES-C.fidelity", verdict: .inconclusive,
                                                 detail: "frozen RES-B not usable (not established, other environment, or fitted with another CAL-B): \(record.prerequisites.resamplingNote)")); return
            }
            var se = 0.0, n = 0, mx = 0.0
            for b in inputs.validation {
                let pred = Resampling.predict(cand, b, phaseX: px, phaseY: py)
                for y in 2..<max(2, b.measured.height - 2) { for x in 2..<max(2, b.measured.width - 2) { let d = Double(pred[x, y] - b.measured[x, y]); se += d * d; n += 1; mx = max(mx, abs(d)) } }
            }
            let rms = n > 0 ? sqrt(se / Double(n)) : .nan
            let ok = n > 0 && rms <= ParityThresholdsV1.resamplingValidationRMS && mx <= ParityThresholdsV1.resamplingValidationMax
            record.checks.append(ParityCheck(name: "RES-C.fidelity", verdict: n == 0 ? .inconclusive : (ok ? .pass : .fail),
                                             detail: String(format: "frozen %@ on the corrected display: validation RMS %.3f max %.3f", cand.rawValue, rms, mx), values: ["rms": rms, "max": mx]))
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
        if let c = loadCalibration(args: args) {
            let env = c.provenance.environmentMatches(provenance), thr = c.thresholds == ParityThresholdsV1.fingerprint, intact = c.integrityOK
            record.prerequisites.calibrationValid = c.valid && env && thr && intact
            record.prerequisites.calibrationNote = !c.valid ? "CAL-B invalid: \(c.reason)" : (!intact ? "CAL-B fingerprint mismatch (stored \(c.storedParameters), recomputed \(c.parameters))"
                : (!env ? "CAL-B environment differs" : (!thr ? "CAL-B thresholds differ" : "frozen CAL-B \(c.parameters)")))
        } else { record.prerequisites.calibrationNote = "no frozen CAL-B supplied" }
        if record.scenario == "RES" && record.compositor == "builtin" { return }
        if let r = loadResampling(args: args) {
            let env = r.provenance.environmentMatches(provenance), thr = r.thresholds == ParityThresholdsV1.fingerprint
            let calOK = loadCalibration(args: args).map { $0.parameters == r.calibrationParameters } ?? false
            // One-way: a usable RES-B requires a usable CAL-B (D-042); RES-B never makes CAL-B usable.
            let calUsable = record.prerequisites.calibrationValid
            record.prerequisites.resamplingEstablished = calUsable && r.established && env && thr && calOK
            record.prerequisites.resamplingNote = !calUsable ? "CAL-B not usable (\(record.prerequisites.calibrationNote)); RES-B depends on it"
                : (!r.established ? "RES-B unresolved: \(r.reason)" : (!env ? "RES-B environment differs" : (!thr ? "RES-B thresholds differ" : (!calOK ? "RES-B fitted with another CAL-B fingerprint" : "frozen RES-B \(r.candidate!.rawValue)"))))
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

    /// Paused preview settled at frame k (same observable conditions as the existing parity test). Timelines without Spectrum
    /// do not wait for the overlay.
    static func settle(_ k: Int, scene: ParityScene, view: PlayerNSView) async -> Bool {
        let s = ProjectStore.shared, overlay = view.spectrumOverlay
        let spectra = scene.timeline.spectra.filter { $0.visible(atFrame: k) }.map(\.id)
        let subs = scene.timeline.subtitles.filter { (($0.start)..<($0.start + $0.length)).contains(k) }.map(\.id)
        s.seek(to: k)
        return await LaneSelfTest.waitUntil(15) {
            guard s.appliedGeneration == s.generation, !s.isPlaying, CMTimeCompare(s.player.currentTime(), CMTime(value: Int64(k), timescale: 30)) == 0 else { return false }
            if !scene.timeline.spectra.isEmpty {
                guard overlay.confirmedFrame == k else { return false }
                if spectra.isEmpty ? !overlay.layers.isEmpty : (overlay.presentedFrameForTest != k || overlay.layers.count != spectra.count) { return false }
            }
            for id in subs {
                guard let l = view.subtitleLayerForTest(id), l.contents != nil, (l.presentation()?.opacity ?? l.opacity) > 0.5 else { return false }
            }
            return true
        }
    }

    /// Tries to make the Preview video rectangle exactly 960×540 capture pixels with an integral origin (not mandatory).
    static func attemptTwoToOne(window: NSWindow, view: PlayerNSView) async -> WindowInfo {
        var info = WindowInfo()
        let scale = Double(window.backingScaleFactor)
        info.backingScale = scale
        let tw = 960 / scale, th = 540 / scale
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            let vr = view.playerLayer.videoRect, b = view.bounds
            let inWindow = view.convert(vr, to: nil)
            let integral = abs((inWindow.minX * scale).rounded() - inWindow.minX * scale) < 0.01 && abs((inWindow.minY * scale).rounded() - inWindow.minY * scale) < 0.01
            if abs(vr.width - tw) < 0.25, abs(vr.height - th) < 0.25, integral { info.achievedTwoToOne = true; break }
            guard b.width > 0, b.height > 0 else { break }
            var f = window.frame
            if b.width / b.height > 16.0 / 9 { f.size.height += (th - vr.height) * f.height / b.height } else { f.size.width += (tw - vr.width) * f.width / b.width }
            f.size.width = f.size.width.rounded(); f.size.height = f.size.height.rounded()
            window.setFrame(f, display: true)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let vr = view.playerLayer.videoRect, inWindow = view.convert(vr, to: nil)
        info.videoRectPoints = [inWindow.minX, inWindow.minY, vr.width, vr.height]
        info.note = info.achievedTwoToOne ? "2:1 achieved" : "2:1 not achieved; continuing with the actual size (not a failure)"
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
