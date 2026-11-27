#if DEBUG
import AppKit
import AVFoundation
import CoreVideo
import OnTheFrameEngine

/// SP-EXPORT-E4D-L1-COLOR-115B (DEBUG only, explicit argument `-OTFPreviewL1Patches` together with `-OTFPreviewL1 <M2|M3>`):
/// records the ACTUAL Preview item's 420v patch codes and every raw colour attachment per sampled frame. Same Preview item,
/// separate AVPlayerItemVideoOutput (itemCreatedHookForTest), same seek settlement and exact-time acquisition as the L1 prototype.
/// No Export, no screen capture, no RGB conversion before measuring, no colour reinterpretation, no verdict.
/// Patch layout: ParityFixtures.patchRect (generator) in the source's natural pixels, central 50 % interior, mapped with
/// CompositionPlanner.layerTransform of the placed clip, 2 output pixels further inside (identical to task 115A's export ROIs).
/// Writes only `<run folder>/l1-patches-result.json`.
extension PreviewOutputParityL1 {
    struct PatchStat: Codable { let n: Int; let mean: Double; let sd: Double; let min: Int; let max: Int }
    struct PatchRecord: Codable { let index: Int; let rgb: [Int]; let sourceRect: [Int]; let roi: [Int]; let y: PatchStat; let cb: PatchStat; let cr: PatchStat }
    struct AttachmentRecord: Codable { let key: String; let type: String; let value: String; let mode: String }
    struct PatchFrame: Codable {
        let frame: Int
        var requestedItemTime = ""
        var previewItemTime: String?
        var acquisition = ""
        var attempts = 0
        var otherItemTimesReturned: [String] = []
        var pixelFormat: String?
        var size: [Int]?
        var keyAttachments: [AttachmentRecord] = []
        var allAttachments: [AttachmentRecord] = []
        var identity = "NOT RUN"
        var identityDetail = ""
        var patches: [PatchRecord] = []
        var missing: [String] = []
        var settle: SeekSettlement?
    }
    struct PatchResult: Codable {
        let version: String
        let scenario: String
        var startedUTC = ""
        var finishedUTC = ""
        var appBinarySHA256 = ""
        var sourceSHA256: [String: String] = [:]
        var sourceSHA256After: [String: String] = [:]
        var sourceFormatDescription: [AttachmentRecord] = []
        var layerTransform = ""
        var naturalSize: [Double] = []
        var environmentRecordedNotRequired: [String: String] = [:]
        var setup: [String] = []
        var frames: [PatchFrame] = []
        var notes: [String] = []
        // SP-EXPORT-E4D-COLOR-PARITY-118A: subtitle-free Export of the same timeline (I601/I709 only)
        var exportOutcome: String?
        var exportFile: String?
        var exportSHA256: String?
        var exportBuiltinCompositor: Bool?
    }

    static let patchIndices = [0, 5, 10, 11, 12, 13, 14, 15, 16]
    /// ParityFixtures.patchRGB entries for the indices above (app/Engine/Sources/OTFDevSupport/ParityFixtures.swift:42).
    static let patchRGB: [Int: [Int]] = [0: [0, 0, 0], 5: [127, 127, 127], 10: [255, 255, 255], 11: [191, 0, 0], 12: [0, 191, 0],
                                         13: [0, 0, 191], 14: [0, 191, 191], 15: [191, 0, 191], 16: [191, 191, 0]]
    /// ParityFixtures.patchRect, verbatim arithmetic.
    static func generatorPatchRect(_ i: Int, width w: Int, height h: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        let c = i % 6, r = i / 6
        let x0 = Double(240 + 240 * c) / 1920, y0 = Double(320 + 180 * r) / 1080
        return (Int((x0 * Double(w)).rounded()), Int((y0 * Double(h)).rounded()), Int((160.0 / 1920 * Double(w)).rounded()), Int((140.0 / 1080 * Double(h)).rounded()))
    }

    static func attachmentRecord(_ key: String, _ v: AnyObject?, mode: String) -> AttachmentRecord {
        guard let v else { return AttachmentRecord(key: key, type: "absent", value: "", mode: mode) }
        return AttachmentRecord(key: key, type: CFCopyTypeIDDescription(CFGetTypeID(v)) as String, value: "\(v)", mode: mode)
    }

    static func patchStat(_ v: [Int]) -> PatchStat {
        guard !v.isEmpty else { return PatchStat(n: 0, mean: .nan, sd: .nan, min: -1, max: -1) }
        let m = Double(v.reduce(0, +)) / Double(v.count)
        let sd = (v.map { (Double($0) - m) * (Double($0) - m) }.reduce(0, +) / Double(v.count)).squareRoot()
        return PatchStat(n: v.count, mean: m, sd: sd, min: v.min() ?? -1, max: v.max() ?? -1)
    }

    /// SP-EXPORT-E4D-COLOR-PARITY-118A: task 117 independent fixtures (I_PCM, no AVAssetWriter). One clip at frame 0 on the base video lane,
    /// identity transform (fit 640x480 → 1440x1080 pillarbox, ×2.25 + 240, same layout as M2). Frame codes: source 0xE1 (601) / 0xE2 (709).
    static func independentScene(_ name: String, assets: [String: MediaAsset]) throws -> ParityScene {
        let file = name == "I601" ? "SD601.mp4" : "SD709.mp4", sid = name == "I601" ? 0xE1 : 0xE2
        guard let src = assets[file] else { throw L1Error.setup("missing source \(file)") }
        let t = try Timeline().registering(src).placing(media: src.id, at: 0, videoLane: Lane.videoID, audioLane: nil, clipID: FullPreviewParityScenes.id(1))
        let placed = FullPreviewParityScenes.pillar(sid)
        return ParityScene(name: name, timeline: t, reference: nil, frames: [0, 5, 15, 25], target: { _ in placed }, sourceFrame: { $0 },
                           sourceFile: { _ in file }, layout: { _ in [] }, colourTagged: true, roi: nil, upperLayer: nil, edgeFrames: [],
                           anchorFrame: nil, files: [file])
    }

    static func runPatches(folder: URL, args: [String]) async {
        let scenario = FullPreviewParitySelfTest.value(after: "-OTFPreviewL1", in: args) ?? "?"
        var r = PatchResult(version: "l1-patches-115b", scenario: scenario)
        let iso = ISO8601DateFormatter()
        r.startedUTC = iso.string(from: Date())
        do { try await executePatches(folder: folder, result: &r) }
        catch { r.setup.append("execution stopped: \(error)") }
        r.finishedUTC = iso.string(from: Date())
        FullPreviewParitySelfTest.write(r, folder.appendingPathComponent("l1-patches-result.json"))
        FullPreviewParitySelfTest.finish()
    }

    static func executePatches(folder: URL, result r: inout PatchResult) async throws {
        guard ["M2", "M3", "I601", "I709"].contains(r.scenario) else { throw L1Error.setup("patch mode is defined for M2, M3, I601 and I709 only (got \(r.scenario))") }
        let s = ProjectStore.shared
        let box = Box()
        s.itemCreatedHookForTest = { item, g in
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            item.add(o)
            box.outputs.append((item: item, output: o, generation: g))
        }
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil && s.previewHost?.window != nil }
        guard let view = s.previewHost, let window = s.editorWindow else { throw L1Error.setup("editor window or preview view missing") }
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
        r.environmentRecordedNotRequired = [
            "windowBackingScale": "\(window.backingScaleFactor)",
            "windowScreen": window.screen?.localizedName ?? "unknown",
            "windowScreenColorSpace": window.screen?.colorSpace?.localizedName ?? "unknown",
            "note": "recorded only; measurements come from the Preview item's video output, not from the display"]
        r.appBinarySHA256 = FullPreviewParitySelfTest.appBinaryHash()

        let src = folder.appendingPathComponent("sources")
        var assets: [String: MediaAsset] = [:]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? [] where n.hasSuffix(".mp4") || n.hasSuffix(".mov") {
            let a = try await MediaProbe.inspect(src.appendingPathComponent(n)); s.assetCache[a.url.standardizedFileURL.path] = a; assets[n] = a
        }
        let scene = try (r.scenario.hasPrefix("I") ? independentScene(r.scenario, assets: assets) : FullPreviewParityScenes.make(r.scenario, assets: assets))   // 118A
        for f in scene.files { r.sourceSHA256[f] = FullPreviewParityIO.sha256(src.appendingPathComponent(f)) }
        defer { for f in scene.files { r.sourceSHA256After[f] = FullPreviewParityIO.sha256(src.appendingPathComponent(f)) } }
        // Source format description (separate from buffer attachments and pixels).
        if let file = scene.files.first {
            let track = try await AVURLAsset(url: src.appendingPathComponent(file)).loadTracks(withMediaType: .video)[0]
            if let d = try await track.load(.formatDescriptions).first {
                let ext = CMFormatDescriptionGetExtensions(d) as? [String: Any] ?? [:]
                for k in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
                          kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionExtension_FullRangeVideo] {
                    r.sourceFormatDescription.append(attachmentRecord(k as String, ext[k as String].map { $0 as AnyObject }, mode: "formatDescription"))
                }
            }
        }

        s.loadTimelineForTest(scene.timeline)
        let applied = await LaneSelfTest.waitUntil(15) { s.appliedGeneration == s.generation && s.player.currentItem?.status == .readyToPlay }
        guard applied, s.timeline == scene.timeline else { throw L1Error.setup("timeline not applied") }
        guard let item = s.player.currentItem, let entry = box.outputs.last(where: { $0.item === item }) else {
            throw L1Error.setup("no L1 video output on the current Preview item (hook not applied)")
        }
        guard item.videoComposition?.customVideoCompositorClass == nil else { throw L1Error.setup("custom compositor on the Preview item (builtin only)") }
        r.setup.append("Preview item \(ObjectIdentifier(item)) generation \(entry.generation); item outputs \(item.outputs.count) (L1 output separate); no Export in this mode")
        s.selection = nil

        // Patch mapping: the placed clip's CompositionPlanner.layerTransform.
        let media = s.mediaByID, render = CGSize(width: 1920, height: 1080)
        guard let clip = try CompositionPlanner.layerStack(scene.timeline, from: 5, to: 6, media: media, render: render).first, let m = media[clip.mediaID] else {
            throw L1Error.setup("placed clip not found")
        }
        let map = CompositionPlanner.layerTransform(m, clip.effectiveTransform, render: render)
        r.layerTransform = "\(map)"; r.naturalSize = [Double(m.naturalSize.width), Double(m.naturalSize.height)]
        let nw = Int(m.naturalSize.width.rounded()), nh = Int(m.naturalSize.height.rounded())

        for k in scene.frames {
            var f = PatchFrame(frame: k)
            let want = CMTime(value: CMTimeValue(k), timescale: 30)
            f.requestedItemTime = "\(want.value)/\(want.timescale)"
            let (settled, d) = await FullPreviewParitySelfTest.settle(k, scene: scene, view: view)
            f.settle = d
            guard settled else { f.missing.append("preview not settled: \(d.outcome)"); r.frames.append(f); continue }
            guard s.player.currentItem === item else { f.missing.append("Preview item changed"); r.frames.append(f); continue }
            var buffer: CVPixelBuffer?
            let deadline = CACurrentMediaTime() + 5
            while CACurrentMediaTime() < deadline {
                f.attempts += 1
                let hasNew = entry.output.hasNewPixelBuffer(forItemTime: want)
                if hasNew || f.attempts % 10 == 1 {
                    var t = CMTime.invalid
                    if let b = entry.output.copyPixelBuffer(forItemTime: want, itemTimeForDisplay: &t) {
                        if t.isNumeric && t.value * 30 == CMTimeValue(k) * CMTimeValue(t.timescale) {
                            buffer = b; f.previewItemTime = "\(t.value)/\(t.timescale)"
                            f.acquisition = hasNew ? "hasNewPixelBuffer → copyPixelBuffer" : "copyPixelBuffer (no hasNew signal; paused item)"
                            break
                        }
                        if f.otherItemTimesReturned.count < 8 { f.otherItemTimesReturned.append(t.isNumeric ? "\(t.value)/\(t.timescale)" : "non-numeric") }
                    }
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let pb = buffer else { f.missing.append("no Preview buffer with item time exactly \(k)/30 within 5 s"); r.frames.append(f); continue }
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            f.pixelFormat = fourCC(fmt)
            f.size = [CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)]
            // Raw attachments: the colour keys with their attachment mode, then every attachment of both modes.
            for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferCGColorSpaceKey, kCVImageBufferICCProfileKey] {
                var mode = CVAttachmentMode.shouldPropagate
                let v = CVBufferCopyAttachment(pb, key, &mode)
                f.keyAttachments.append(attachmentRecord(key as String, v, mode: v == nil ? "n/a" : (mode == .shouldPropagate ? "shouldPropagate" : "shouldNotPropagate")))
            }
            for (modeName, mode) in [("shouldPropagate", CVAttachmentMode.shouldPropagate), ("shouldNotPropagate", CVAttachmentMode.shouldNotPropagate)] {
                if let all = CVBufferCopyAttachments(pb, mode) as? [String: Any] {
                    for (key, v) in all.sorted(by: { $0.key < $1.key }) { f.allAttachments.append(attachmentRecord(key, v as AnyObject, mode: modeName)) }
                }
            }
            guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { f.missing.append("pixel format \(fourCC(fmt)) is not 420v"); r.frames.append(f); continue }
            // Frame identity (same reader as task 113).
            let native = FullPreviewParityIO.planes(pb, declaration: ColorDeclaration(primaries: nil, transfer: nil, matrix: nil, fullRange: false, origin: "Preview 420v (range from pixel format)"))
            if let placed = scene.target(k), let expect = scene.sourceFrame(k) {
                let rd = ParityCode.read(placed: placed, luma: ParityCode.nativeSampler(native))
                let ok = rd.map { $0.sourceID == placed.sourceID && $0.frame == expect && $0.margin >= ParityThresholdsV1.codeMarginMinimum }
                f.identity = ok == true ? "MATCH" : (ok == false ? "MISMATCH" : "INCONCLUSIVE")
                f.identityDetail = "expected id \(placed.sourceID) frame \(expect); read \(rd.map { "id \($0.sourceID) frame \($0.frame) margin \($0.margin)" } ?? "unreadable")"
            }
            // Patch codes straight from the planes.
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            if let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
               let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) {
                let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                for i in patchIndices {
                    let pr = generatorPatchRect(i, width: nw, height: nh)
                    let a = CGPoint(x: Double(pr.x) + Double(pr.w) / 4, y: Double(pr.y) + Double(pr.h) / 4).applying(map)
                    let b = CGPoint(x: Double(pr.x) + 3 * Double(pr.w) / 4, y: Double(pr.y) + 3 * Double(pr.h) / 4).applying(map)
                    let x0 = max(0, Int(ceil(a.x + 2))), x1 = min(w, Int(floor(b.x - 2))), y0 = max(0, Int(ceil(a.y + 2))), y1 = min(h, Int(floor(b.y - 2)))
                    var Y: [Int] = [], CB: [Int] = [], CR: [Int] = []
                    if x1 > x0 && y1 > y0 {
                        for y in y0..<y1 { for x in x0..<x1 { Y.append(Int(yb[y * ybpr + x])) } }
                        let cx0 = (x0 + 1) / 2, cx1 = x1 / 2, cy0 = (y0 + 1) / 2, cy1 = y1 / 2
                        if cx1 > cx0 && cy1 > cy0 {
                            for y in cy0..<cy1 { for x in cx0..<cx1 { CB.append(Int(cb[y * cbpr + 2 * x])); CR.append(Int(cb[y * cbpr + 2 * x + 1])) } }
                        }
                    }
                    f.patches.append(PatchRecord(index: i, rgb: patchRGB[i] ?? [], sourceRect: [pr.x, pr.y, pr.w, pr.h], roi: [x0, y0, x1 - x0, y1 - y0],
                                                 y: patchStat(Y), cb: patchStat(CB), cr: patchStat(CR)))
                }
            } else { f.missing.append("plane base addresses unavailable") }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            r.frames.append(f)
        }
        if r.scenario.hasPrefix("I") {   // 118A: one subtitle-free Export through the existing ExportService (builtin), decoded outside the app
            let out = folder.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let plan = try await CompositionPlanner.plan(scene.timeline, media: media, settings: .m1)
            r.exportBuiltinCompositor = plan.videoComposition.customVideoCompositorClass == nil
            let dest = ExportDestination(url: out.appendingPathComponent("export.mp4"), confirmedReplace: false, identityAtConfirmation: nil)
            let outcome = await ExportService.export(plan, to: dest, sources: Array(media.values), progress: { _ in })
            r.exportOutcome = "\(outcome)"
            if case .completed(let u) = outcome { r.exportFile = u.path; r.exportSHA256 = FullPreviewParityIO.sha256(u) }
        }
        r.notes.append("Measurements only: no verdict, no tolerance, no colour conversion. Comparison with task 115A is done outside the app.")
    }
}
#endif
