#if DEBUG
import AppKit
import AVFoundation
import CryptoKit
import OnTheFrameEngine

/// SP-EXPORT-E4D-SEMANTIC-ORACLE-113 (DEBUG only, explicit argument only): L1 prototype of display-independent parity.
/// Compares the composited video of the ACTUAL Preview AVPlayerItem (a separate AVPlayerItemVideoOutput attached through the
/// existing `itemCreatedHookForTest`, before AVPlayerLayer scaling and display colour matching) with the decoded Export of the
/// same timeline (same `CompositionPlanner.plan`, builtin compositor, public export path without overlays).
/// Base video only: Spectrum/subtitle overlays are L2 and are not judged here (the L1 scenarios G, M2, M3 have none).
/// No screen capture, no CAL-B/RES-B, no display identity precondition (the window's screen is recorded only).
/// Launch: `open -n -W -a OnTheFrame.app <run folder> --args -OTFLayoutReset -OTFLayoutSuite <suite> -OTFPreviewL1 <G|M2|M3>`
/// with `<run folder>/sources` holding isolated fixture copies. Writes only `<run folder>/l1-result.json` and `<run folder>/out/l1.mp4`.
/// Verdicts: MATCH / MISMATCH / INCONCLUSIVE / NOT RUN. Pixel residuals are RECORDED only (no tolerance is approved for this domain).
@MainActor
enum PreviewOutputParityL1 {
    static let version = "l1-prototype-113"
    static let scenarios = ["G", "M2", "M3"]
    /// Measurability floor for an edge transition (Y' code values between adjacent column/row means). PROPOSED, not an accepted
    /// threshold: below it the edge is INCONCLUSIVE rather than judged.
    static let edgeContrastFloor = 8.0

    final class Box: @unchecked Sendable {
        var outputs: [(item: AVPlayerItem, output: AVPlayerItemVideoOutput, generation: Int)] = []
    }
    enum L1Error: Error, CustomStringConvertible {
        case setup(String), export(String)
        var description: String { switch self { case .setup(let s): "setup: \(s)"; case .export(let s): "export: \(s)" } }
    }

    struct Residual: Codable { let plane: String; let count: Int; let mean: Double; let p99: Int; let max: Int; let fractionOver2: Double; let fractionOver8: Double }
    struct Edge: Codable {
        let layer: String; let edge: String; let expected: Double
        let preview: Int?; let export: Int?; let previewContrast: Double; let exportContrast: Double; let verdict: String
    }
    struct FrameResult: Codable {
        let frame: Int
        var requestedItemTime = ""
        var previewItemTime: String?
        var previewTimeExact: Bool?
        var acquisition = ""
        var acquisitionAttempts = 0
        var otherItemTimesReturned: [String] = []
        var previewItem = ""
        var previewGeneration: Int?
        var exportPTSExact: Bool?
        var previewDims: [Int]?
        var exportDims: [Int]?
        var dimensions = "NOT RUN"
        var previewPixelFormat: String?
        var previewBytesPerRow: [Int]?
        var previewDeclaration: ColorDeclaration?
        var exportDeclaration: ColorDeclaration?
        var colorMetadata = "NOT RUN"
        var colorMetadataDetail = ""
        var identity = "NOT RUN"
        var identityDetail = ""
        var geometry: [Edge] = []
        var geometryVerdict = "NOT RUN"
        var rawResidual: [Residual] = []
        var normalizedResidual: [Residual] = []
        var normalizedNote = ""
        var previewYSHA256: String?
        var exportYSHA256: String?
        var missing: [String] = []
        var settle: SeekSettlement?
        var verdict = "NOT RUN"
    }
    struct L1Result: Codable {
        let version: String
        let scenario: String
        var startedUTC = ""
        var finishedUTC = ""
        var api = "AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:itemTimeForDisplay:) — available from macOS 10.8, deprecated only from macOS 27 "
            + "(deployment target 15.0; pixelBufferAndDisplayTime(forItemTime:) needs macOS 26). Requested pixel format 420v (video range)."
        var appBinarySHA256 = ""
        var sourceSHA256: [String: String] = [:]
        var sourceSHA256After: [String: String] = [:]
        var exportFile: String?
        var exportSHA256: String?
        var exportInterpretation: DeclaredInterpretation?
        var environmentRecordedNotRequired: [String: String] = [:]
        var setup: [String] = []
        var frames: [FrameResult] = []
        var counts: [String: Int] = [:]
        var verdict = "NOT RUN"
        var notes: [String] = []
    }

    static func run(folder: URL, args: [String]) async {
        if args.contains("-OTFPreviewL1Patches") { await runPatches(folder: folder, args: args); return }   // SP-EXPORT-E4D-L1-COLOR-115B
        let scenario = FullPreviewParitySelfTest.value(after: "-OTFPreviewL1", in: args) ?? "?"
        var r = L1Result(version: version, scenario: scenario)
        let iso = ISO8601DateFormatter()
        r.startedUTC = iso.string(from: Date())
        do { try await execute(folder: folder, result: &r) }
        catch { r.setup.append("execution stopped: \(error)"); r.verdict = "NOT RUN" }
        r.finishedUTC = iso.string(from: Date())
        FullPreviewParitySelfTest.write(r, folder.appendingPathComponent("l1-result.json"))
        FullPreviewParitySelfTest.finish()
    }

    static func execute(folder: URL, result r: inout L1Result) async throws {
        guard scenarios.contains(r.scenario) else { throw L1Error.setup("scenario \(r.scenario) not in the L1 set \(scenarios)") }
        let s = ProjectStore.shared
        let box = Box()
        // A separate output per Preview item; existing outputs (e.g. the playback Spectrum clock) are neither removed nor read.
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
            "note": "recorded only; L1 reads the Preview item's video output before layer scaling and display colour matching"]
        r.appBinarySHA256 = FullPreviewParitySelfTest.appBinaryHash()

        let src = folder.appendingPathComponent("sources")
        var assets: [String: MediaAsset] = [:]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? [] where n.hasSuffix(".mp4") || n.hasSuffix(".mov") {
            let a = try await MediaProbe.inspect(src.appendingPathComponent(n)); s.assetCache[a.url.standardizedFileURL.path] = a; assets[n] = a
        }
        let scene = try FullPreviewParityScenes.make(r.scenario, assets: assets)
        for f in scene.files { r.sourceSHA256[f] = FullPreviewParityIO.sha256(src.appendingPathComponent(f)) }
        defer { for f in scene.files { r.sourceSHA256After[f] = FullPreviewParityIO.sha256(src.appendingPathComponent(f)) } }

        s.loadTimelineForTest(scene.timeline)
        let applied = await LaneSelfTest.waitUntil(15) { s.appliedGeneration == s.generation && s.player.currentItem?.status == .readyToPlay }
        guard applied, s.timeline == scene.timeline else { throw L1Error.setup("timeline not applied") }
        guard let item = s.player.currentItem, let entry = box.outputs.last(where: { $0.item === item }) else {
            throw L1Error.setup("no L1 video output on the current Preview item (hook not applied)")
        }
        guard item.videoComposition?.customVideoCompositorClass == nil else { throw L1Error.setup("custom compositor on the Preview item (L1 is builtin only)") }
        r.setup.append("Preview item \(ObjectIdentifier(item)) generation \(entry.generation); item outputs \(item.outputs.count) (L1 output separate)")
        s.selection = nil
        let frames = Array(Set([0] + scene.frames)).sorted()

        // Export of the same timeline (same planner; public export path; builtin), decoded at exactly k/30.
        let out = folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let media = s.mediaByID
        let plan = try await CompositionPlanner.plan(scene.timeline, media: media, settings: .m1)
        let dest = ExportDestination(url: out.appendingPathComponent("l1.mp4"), confirmedReplace: false, identityAtConfirmation: nil)
        let outcome = await ExportService.export(plan, to: dest, sources: Array(media.values), progress: { _ in })
        guard case .completed(let url) = outcome else { throw L1Error.export("\(outcome)") }
        r.exportFile = url.path; r.exportSHA256 = FullPreviewParityIO.sha256(url)
        let decoded = try await FullPreviewParityIO.decode(url, frames: Set(frames), origin: "output")
        r.exportInterpretation = decoded.interpretation

        for k in frames {
            r.frames.append(await measure(k, scene: scene, view: view, item: item, output: entry.output, generation: entry.generation,
                                          decoded: decoded, media: media))
        }
        var counts: [String: Int] = [:]
        for f in r.frames { counts[f.verdict, default: 0] += 1 }
        r.counts = counts
        if r.frames.contains(where: { $0.verdict == "MISMATCH" }) { r.verdict = "MISMATCH" }
        else if !r.frames.isEmpty && r.frames.allSatisfy({ $0.verdict == "MATCH" }) { r.verdict = "MATCH" }
        else { r.verdict = "INCONCLUSIVE" }
        r.notes.append("L1 base video only; overlays (L2), physical presentation (A-010) and display colour are not judged. Residuals recorded, not judged.")
    }

    // MARK: one frame

    static func measure(_ k: Int, scene: ParityScene, view: PlayerNSView, item: AVPlayerItem, output: AVPlayerItemVideoOutput, generation: Int,
                        decoded: FullPreviewParityIO.Decoded, media: [UUID: MediaAsset]) async -> FrameResult {
        var f = FrameResult(frame: k)
        let want = CMTime(value: CMTimeValue(k), timescale: 30)
        f.requestedItemTime = "\(want.value)/\(want.timescale)"
        f.previewItem = "\(ObjectIdentifier(item))"; f.previewGeneration = generation
        let s = ProjectStore.shared
        let (settled, d) = await FullPreviewParitySelfTest.settle(k, scene: scene, view: view)
        f.settle = d
        guard settled else { f.missing.append("preview not settled: \(d.outcome)"); return f }
        guard s.player.currentItem === item else { f.missing.append("Preview item changed"); f.verdict = "INCONCLUSIVE"; return f }

        // Acquisition: only a buffer whose returned item time is exactly k/30 (rational) is used; never a substitute.
        var buffer: CVPixelBuffer?
        var shown = CMTime.invalid
        var attempts = 0
        let deadline = CACurrentMediaTime() + 5
        while CACurrentMediaTime() < deadline {
            attempts += 1
            let hasNew = output.hasNewPixelBuffer(forItemTime: want)
            if hasNew || attempts % 10 == 1 {
                var t = CMTime.invalid
                if let b = output.copyPixelBuffer(forItemTime: want, itemTimeForDisplay: &t) {
                    if t.isNumeric && t.value * 30 == CMTimeValue(k) * CMTimeValue(t.timescale) {
                        buffer = b; shown = t
                        f.acquisition = hasNew ? "hasNewPixelBuffer → copyPixelBuffer" : "copyPixelBuffer (no hasNew signal; paused item)"
                        break
                    }
                    if f.otherItemTimesReturned.count < 8 { f.otherItemTimesReturned.append(t.isNumeric ? "\(t.value)/\(t.timescale)" : "non-numeric") }
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        f.acquisitionAttempts = attempts
        guard let pb = buffer else { f.missing.append("no Preview buffer with item time exactly \(k)/30 within 5 s"); return f }
        f.previewItemTime = "\(shown.value)/\(shown.timescale)"; f.previewTimeExact = true
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        f.previewPixelFormat = fourCC(fmt)
        f.previewDims = [CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)]
        f.previewBytesPerRow = (0..<CVPixelBufferGetPlaneCount(pb)).map { CVPixelBufferGetBytesPerRowOfPlane(pb, $0) }
        let pdecl = FullPreviewParityIO.bufferDeclaration(pb, origin: "Preview item video output buffer attachments")
        f.previewDeclaration = pdecl
        guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            f.missing.append("Preview buffer pixel format \(fourCC(fmt)) is not the requested 420v"); f.verdict = "INCONCLUSIVE"; return f
        }
        // Range comes from the pixel format (420v = video range), not from an attachment; nothing else is filled in.
        let pv = FullPreviewParityIO.planes(pb, declaration: ColorDeclaration(primaries: pdecl.primaries, transfer: pdecl.transfer, matrix: pdecl.matrix,
                                                                             fullRange: false, origin: "Preview 420v (range from pixel format)"))
        guard let ex = decoded.frames[k] else { f.missing.append("no decoded export frame at \(k)/30"); f.verdict = "INCONCLUSIVE"; return f }
        f.exportPTSExact = decoded.exactTimes.contains(k)
        f.exportDims = [ex.width, ex.height]
        f.exportDeclaration = ex.declaration
        f.previewYSHA256 = planeHash(pv.y); f.exportYSHA256 = planeHash(ex.y)
        let dimsOK = pv.width == 1920 && pv.height == 1080 && ex.width == 1920 && ex.height == 1080
        f.dimensions = dimsOK ? "MATCH" : "MISMATCH"

        // Colour metadata: declared values only; a missing value is INCONCLUSIVE (never inferred).
        let pd = [pdecl.primaries, pdecl.transfer, pdecl.matrix], ed = [ex.declaration.primaries, ex.declaration.transfer, ex.declaration.matrix]
        if pd.contains(where: { $0 == nil }) || ed.contains(where: { $0 == nil }) { f.colorMetadata = "INCONCLUSIVE" }
        else { f.colorMetadata = pd == ed ? "MATCH" : "MISMATCH" }
        f.colorMetadataDetail = "preview \(pd.map { $0 ?? "missing" }) / export \(ed.map { $0 ?? "missing" }) (primaries, transfer, matrix); both 420v video range by pixel format"

        // Identity (same native Y' domain and code reader as the accepted exportIdentity check).
        if let placed = scene.target(k) {
            if let expect = scene.sourceFrame(k) {
                let a = ParityCode.read(placed: placed, luma: ParityCode.nativeSampler(pv)), b = ParityCode.read(placed: placed, luma: ParityCode.nativeSampler(ex))
                func ok(_ x: ParityCode.Reading?) -> Bool? { x.map { $0.sourceID == placed.sourceID && $0.frame == expect && $0.margin >= ParityThresholdsV1.codeMarginMinimum } }
                let oa = ok(a), ob = ok(b)
                f.identity = oa == true && ob == true ? "MATCH" : (oa == false || ob == false ? "MISMATCH" : "INCONCLUSIVE")
                func show(_ x: ParityCode.Reading?) -> String { x.map { "id \($0.sourceID) frame \($0.frame) margin \($0.margin)" } ?? "unreadable" }
                f.identityDetail = "expected id \(placed.sourceID) frame \(expect); preview \(show(a)); export \(show(b))"
            } else {
                f.identity = "NOT VERIFIED"; f.identityDetail = "uncoded source (\(scene.sourceFile(k) ?? "?")); identity not verifiable"
            }
        } else {
            let py = pv.y.mean(x: 0, y: 0, w: pv.width, h: pv.height), ey = ex.y.mean(x: 0, y: 0, w: ex.width, h: ex.height)
            f.identity = py <= 20 && ey <= 20 ? "MATCH" : "MISMATCH"
            f.identityDetail = String(format: "empty gap: mean Y' preview %.2f export %.2f (gapBlackExport rule Y' ≤ 20, same native domain)", py, ey)
        }

        // Geometry: expected layer rectangles from the planner's own semantics; measured transitions in both frames.
        if dimsOK {
            let render = CGSize(width: 1920, height: 1080)
            let stack = (try? CompositionPlanner.layerStack(scene.timeline, from: k, to: k + 1, media: media, render: render)) ?? []
            for (i, c) in stack.enumerated() {
                guard let m = media[c.mediaID] else { continue }
                let rect = CompositionPlanner.displayRect(m, c.effectiveTransform, render: render)
                f.geometry += edges(of: rect, layer: "layer\(i) \(m.name)", preview: pv.y, export: ex.y)
            }
            if f.geometry.isEmpty { f.geometryVerdict = "NOT VERIFIED"; f.missing.append("no interior layer edge at this frame") }
            else if f.geometry.contains(where: { $0.verdict == "MISMATCH" }) { f.geometryVerdict = "MISMATCH" }
            else if f.geometry.contains(where: { $0.verdict == "MATCH" }) { f.geometryVerdict = f.geometry.allSatisfy { $0.verdict == "MATCH" } ? "MATCH" : "MATCH (some edges INCONCLUSIVE)" }
            else { f.geometryVerdict = "INCONCLUSIVE" }

            // Residuals (recorded only). Raw: 8-bit Y'CbCr code values (chroma repeated to full size). Normalized: each frame's own
            // declared matrix, video range → non-linear R'G'B' 0…255 (ColorMath.rgb, clamped); no transfer or primaries conversion.
            f.rawResidual = [residual("Y'", pv.y, ex.y), residual("Cb", pv.cb, ex.cb), residual("Cr", pv.cr, ex.cr)]
            if let pm = pdecl.matrix, let em = ex.declaration.matrix, ColorMath.coefficients(pm) != nil, ColorMath.coefficients(em) != nil {
                f.normalizedResidual = normalized(pv, pm, ex, em)
                f.normalizedNote = "Y'CbCr (video range) → R'G'B' with preview matrix \(pm) and export matrix \(em)"
            } else {
                f.normalizedNote = "NOT RUN: matrix missing or unsupported (preview \(pdecl.matrix ?? "missing"), export \(ex.declaration.matrix ?? "missing"))"
            }
        }

        let times = f.previewTimeExact == true && f.exportPTSExact == true
        let parts = [f.dimensions, f.colorMetadata, f.identity, f.geometryVerdict]
        if parts.contains("MISMATCH") || !times { f.verdict = times ? "MISMATCH" : "INCONCLUSIVE" }
        else if f.identity == "MATCH" && f.dimensions == "MATCH" && f.colorMetadata == "MATCH" && f.geometryVerdict != "INCONCLUSIVE" { f.verdict = "MATCH" }
        else { f.verdict = "INCONCLUSIVE" }
        return f
    }

    // MARK: measurements

    static func edges(of r: CGRect, layer: String, preview p: ParityPlane, export e: ParityPlane) -> [Edge] {
        var out: [Edge] = []
        let w = Double(p.width), h = Double(p.height)
        func span(_ a: CGFloat, _ b: CGFloat, _ limit: Int) -> ClosedRange<Int> {   // inside the layer, 4 px margin; never an invalid range
            let lo = max(0, Int(a.rounded()) + 4), hi = min(limit - 1, Int(b.rounded()) - 5)
            return lo...max(lo, hi)
        }
        let rows = span(r.minY, r.maxY, p.height), cols = span(r.minX, r.maxX, p.width)
        func judge(_ name: String, _ expected: Double, vertical: Bool) {
            guard expected >= 2, expected <= (vertical ? w : h) - 2 else { return }   // only edges inside the frame
            let span = vertical ? rows : cols
            guard span.count >= 8 else { return }
            let (pp, pc) = transition(p, around: expected, vertical: vertical, span: span)
            let (ep, ec) = transition(e, around: expected, vertical: vertical, span: span)
            let v: String
            if pc < edgeContrastFloor || ec < edgeContrastFloor { v = "INCONCLUSIVE" } else { v = pp == ep ? "MATCH" : "MISMATCH" }
            out.append(Edge(layer: layer, edge: name, expected: expected, preview: pp, export: ep, previewContrast: pc, exportContrast: ec, verdict: v))
        }
        judge("left", Double(r.minX), vertical: true); judge("right", Double(r.maxX), vertical: true)
        judge("top", Double(r.minY), vertical: false); judge("bottom", Double(r.maxY), vertical: false)
        return out
    }

    /// Index c (first pixel after the transition) maximizing |mean(c) − mean(c − 1)| within ±6 px of the expected edge.
    static func transition(_ p: ParityPlane, around e: Double, vertical: Bool, span: ClosedRange<Int>) -> (Int?, Double) {
        let limit = vertical ? p.width : p.height
        let lo = max(1, Int(e.rounded()) - 6), hi = min(limit - 1, Int(e.rounded()) + 6)
        guard lo <= hi else { return (nil, 0) }
        func line(_ c: Int) -> Double {
            var s = 0.0
            for t in span { s += Double(vertical ? p[c, t] : p[t, c]) }
            return s / Double(span.count)
        }
        var best: Int?, bestC = 0.0, prev = line(lo - 1)
        for c in lo...hi {
            let cur = line(c), d = abs(cur - prev)
            if d > bestC { bestC = d; best = c }
            prev = cur
        }
        return (best, bestC)
    }

    static func residual(_ name: String, _ a: ParityPlane, _ b: ParityPlane) -> Residual {
        var hist = [Int](repeating: 0, count: 256), sum = 0.0
        let n = min(a.data.count, b.data.count)
        for i in 0..<n {
            let d = min(255, Int(abs(a.data[i].rounded() - b.data[i].rounded())))
            hist[d] += 1; sum += Double(d)
        }
        return summarize(name, hist, n, sum)
    }

    static func normalized(_ p: NativeFrame, _ pm: String, _ e: NativeFrame, _ em: String) -> [Residual] {
        var hr = [Int](repeating: 0, count: 256), hg = hr, hb = hr, sr = 0.0, sg = 0.0, sb = 0.0
        let n = min(p.y.data.count, e.y.data.count)
        for i in 0..<n {
            guard let a = ColorMath.rgb(y: Double(p.y.data[i]), cb: Double(p.cb.data[i]), cr: Double(p.cr.data[i]), matrix: pm, fullRange: false),
                  let b = ColorMath.rgb(y: Double(e.y.data[i]), cb: Double(e.cb.data[i]), cr: Double(e.cr.data[i]), matrix: em, fullRange: false) else { continue }
            let dr = min(255, Int((abs(a.r - b.r) * 255).rounded())), dg = min(255, Int((abs(a.g - b.g) * 255).rounded())), db = min(255, Int((abs(a.b - b.b) * 255).rounded()))
            hr[dr] += 1; hg[dg] += 1; hb[db] += 1; sr += Double(dr); sg += Double(dg); sb += Double(db)
        }
        return [summarize("R'", hr, n, sr), summarize("G'", hg, n, sg), summarize("B'", hb, n, sb)]
    }

    static func summarize(_ name: String, _ hist: [Int], _ n: Int, _ sum: Double) -> Residual {
        guard n > 0 else { return Residual(plane: name, count: 0, mean: .nan, p99: -1, max: -1, fractionOver2: .nan, fractionOver8: .nan) }
        var acc = 0, p99 = 0, mx = 0
        for (d, c) in hist.enumerated() where c > 0 { mx = d }
        for (d, c) in hist.enumerated() { acc += c; if Double(acc) >= 0.99 * Double(n) { p99 = d; break } }
        let over2 = hist[3...].reduce(0, +), over8 = hist[9...].reduce(0, +)
        return Residual(plane: name, count: n, mean: sum / Double(n), p99: p99, max: mx, fractionOver2: Double(over2) / Double(n), fractionOver8: Double(over8) / Double(n))
    }

    static func planeHash(_ p: ParityPlane) -> String {
        var h = SHA256()
        h.update(data: Data(p.data.map { UInt8(max(0, min(255, $0.rounded()))) }))
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fourCC(_ v: OSType) -> String {
        String([24, 16, 8, 0].map { Character(UnicodeScalar(UInt8(truncatingIfNeeded: v >> UInt32($0)))) })
    }
}
#endif
