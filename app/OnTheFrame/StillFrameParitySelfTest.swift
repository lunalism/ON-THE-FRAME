#if DEBUG
import AppKit
import AVFoundation
import CryptoKit
import OnTheFrameEngine

/// SP-4A-10: opt-in, generated immutable fixture only. Never saves the project or exports.
@MainActor enum StillFrameParitySelfTest {
    static let frames = [0, 1, 30, 60, 119, 120, 121, 150, 180, 239, 240, 241, 270, 300, 359]
    static let hashes = [
        "fixture.ontheframe": "4e060ce73b95a63ab6b6d40cb40f5de0b12695b0564fce1bed298820080db2f1",
        "selected.wav": "4c52190eb31fc3730032b745fed68ed386ba7b85582731f05a21687d67432151",
        "video.mp4": "ebc4ae53657439b8d05ff6981767b92cd402c56a7519d3945a20a3c06cf1ddf5",
        "spectrum.mp4": "04c346e4edcc1e442eb60cfb9e4a362b47f8d44e7e2dda068131640b421c4745"
    ]
    private struct ReferenceResult: Decodable {
        let bands: [String: [Float]]

        @MainActor func validate() throws {
            for frame in StillFrameParitySelfTest.frames {
                let field = "result.json.bands[\(frame)]"
                guard let values = bands[String(frame)] else {
                    throw NSError(domain: "missing " + field, code: 1)
                }
                try StillFrameParitySelfTest.demand(values.count == 64, field + " requires 64 numbers")
                try StillFrameParitySelfTest.demand(values.allSatisfy { $0.isFinite }, field + " requires finite numbers")
            }
            try StillFrameParitySelfTest.demand(bands.count == StillFrameParitySelfTest.frames.count,
                                               "result.json.bands contains unexpected frame entries")
        }
    }

    static func demand(_ ok: Bool, _ message: String) throws {
        if !ok { throw NSError(domain: "StillFrameParity: " + message, code: 1) }
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func image(_ layer: CALayer?) -> CGImage? {
        guard let value = layer?.contents, CFGetTypeID(value as CFTypeRef) == CGImage.typeID else { return nil }
        return (value as! CGImage)
    }
    /// Compare active rows, excluding allocator padding. Pixel format must also match.
    static func pixels(_ image: CGImage) throws -> Data {
        try demand(image.bitsPerPixel == 32, "non-32-bit raster")
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw NSError(domain: "raster data missing", code: 1)
        }
        var result = Data()
        for y in 0..<image.height { result.append(bytes + y * image.bytesPerRow, count: image.width * 4) }
        return result
    }
    static func same(_ a: CGImage, _ b: CGImage) throws -> Bool {
        try a.width == b.width && a.height == b.height && a.bitmapInfo == b.bitmapInfo && pixels(a) == pixels(b)
    }
    static func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }

    private static var activeRun: UUID?

    @discardableResult
    static func run(folder: URL) async -> Bool {
        guard activeRun == nil else { return false }
        let runID = UUID()
        activeRun = runID
        defer { if activeRun == runID { activeRun = nil } }
        let store = ProjectStore.shared
        let diagnostic = ProcessInfo.processInfo.arguments.contains("-OTFFrame120Diagnostic")
        let args = ProcessInfo.processInfo.arguments
        let safety = args.contains("-OTFParityOwnershipTest")
        let missingRaster = args.contains("-OTFParityMissingRasterTest")
        let wrongObject = args.contains("-OTFParityWrongObjectTest")
        let empty = args.contains("-OTFParityEmptyTest")
        let requested = empty ? [359] : diagnostic ? [119, 120] : frames
        let initialSession = store.projectSession
        var ownsSession: () -> Bool = { false }
        var verifyReplacement: (() -> Bool)?
        var rows = [[String: Any]]()
        var report: [String: Any] = ["task": "SP-4A-10", "status": "FAIL", "requestedFrames": requested,
            "fullScreenParity": "UNCONFIRMED", "physicalDisplay": "UNCONFIRMED"]
        var fixture: URL?
        defer {
            let mayTerminate = ownsSession() && !store.isDirty && store.exportPhase == .idle &&
                !store.openRequested && store.openProgress == nil && store.importProgress == nil
            report["terminationAuthorized"] = mayTerminate
            if let verifyReplacement { report["replacementIntact"] = verifyReplacement() }
            if let fixture {
                report["fixtureUnchanged"] = hashes.allSatisfy { name, expected in
                    (try? Data(contentsOf: fixture.appendingPathComponent(name))).map(sha) == expected
                }
            }
            report["frames"] = rows
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("still-frame-parity.json"), options: .withoutOverwriting)
            }
            if mayTerminate { NSApp.terminate(nil) }
        }
        do {
            try demand(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("still-frame-parity.json").path), "fresh output folder required")
            // Launcher supplies this small descriptor in a new test-owned folder. No project rewriting.
            let descriptor = try String(contentsOf: folder.appendingPathComponent("fixture-path.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let root = URL(fileURLWithPath: descriptor, isDirectory: true); fixture = root
            for (name, expected) in hashes {
                try demand(sha(Data(contentsOf: root.appendingPathComponent(name))) == expected, "hash " + name)
            }
            report["hashes"] = hashes
            let referenceURL = root.appendingPathComponent("result.json")
            let referenceResult: ReferenceResult
            do {
                referenceResult = try JSONDecoder().decode(ReferenceResult.self, from: Data(contentsOf: referenceURL))
            } catch {
                throw NSError(domain: "invalid result.json: " + String(describing: error), code: 1)
            }
            try referenceResult.validate()
            try demand(initialSession == 0 && store.projectURL == nil && !store.isDirty &&
                       store.timeline.isEmpty, "fresh standalone process required")
            let opened = await store.openProject(at: root.appendingPathComponent("fixture.ontheframe"))
            try demand(opened, "project open: " + (store.alert?.message ?? store.statusMessage ?? "unknown open failure"))
            let project = store.projectID, openedSession = store.projectSession
            try demand(openedSession == initialSession + 1 && store.projectURL?.standardizedFileURL ==
                       root.appendingPathComponent("fixture.ontheframe").standardizedFileURL, "fixture session")
            let ready = await LaneSelfTest.waitUntil(15) {
                store.player.currentItem?.status == .readyToPlay && store.appliedGeneration == store.generation && store.previewHost?.window != nil
            }
            try demand(ready, "project/window readiness")
            guard store.projectID == project, store.projectSession == openedSession, let view = store.previewHost, let item = store.player.currentItem,
                  let entry = store.timeline.spectra.first, let sourceID = store.timeline.spectrumMediaID(entry) else {
                throw NSError(domain: "missing preview context", code: 1)
            }
            try demand(store.projectID.uuidString == "0F3F7EFB-0FB0-4141-A049-F3BD438D9492", "project UUID")
            try demand(store.timeline.durationFrames == 360 && store.timeline.spectra.count == 1 && store.timeline.subtitles.count == 3, "snapshot shape")
            let snapshot = store.timeline, session = store.projectSession, generation = store.generation
            report["projectID"] = store.projectID.uuidString
            report["session"] = session; report["generation"] = generation
            report["sourceID"] = sourceID.uuidString
            report["sourcePieces"] = String(describing: snapshot.spectrumPieces(entry))
            report["style"] = String(describing: entry.style)
            let renderer = try SpectrumFrameRenderer(width: 1920, height: 1080)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            ownsSession = {
                activeRun == runID && store.projectID == project && store.projectSession == session &&
                    store.generation == generation && store.appliedGeneration == generation &&
                    store.previewHost === view && store.player.currentItem === item
            }
            try demand(view.spectrumOverlay.publicationForParityTest == nil, "publication observer occupied")
            item.add(output)
            view.spectrumOutputChanged(on: item)
            var publication: (Int, Int, UUID, SpectrumFrameOutcome)?
            let receive: (Int, Int, UUID, SpectrumFrameOutcome) -> Void = { frame, token, id, outcome in
                guard ownsSession(), !Task.isCancelled, store.seekToken == token,
                      view.spectrumOverlay.publicationForParityTest?.owner == runID else { return }
                publication = (frame, token, id, outcome)
            }
            view.spectrumOverlay.publicationForParityTest = (runID, receive)
            defer {
                if view.spectrumOverlay.publicationForParityTest?.owner == runID {
                    view.spectrumOverlay.publicationForParityTest = nil
                }
                if item.outputs.contains(where: { $0 === output }) {
                    item.remove(output)
                    if ownsSession() { view.spectrumOutputChanged(on: item) }
                }
                report["ownedResourcesReleased"] = !item.outputs.contains(where: { $0 === output }) &&
                    view.spectrumOverlay.publicationForParityTest?.owner != runID
            }
            if safety {
                let admitted = await run(folder: folder)
                try demand(!admitted && ownsSession() && view.spectrumOverlay.publicationForParityTest?.owner == runID,
                           "duplicate acquired resources")
                report["duplicateRejected"] = true
                let fixtureURL = root.appendingPathComponent("fixture.ontheframe").standardizedFileURL
                let replacementSession = session + 1
                let replaced = await store.openProject(at: fixtureURL)
                guard replaced, activeRun == runID, store.projectSession == replacementSession,
                      store.projectID == project, store.projectURL?.standardizedFileURL == fixtureURL,
                      let replacementView = store.previewHost else {
                    throw NSError(domain: "unexpected replacement project or session", code: 1)
                }
                let replacementGeneration = store.generation
                func isReplacementSession() -> Bool {
                    activeRun == runID && store.projectSession == replacementSession &&
                        store.projectID == project && store.projectURL?.standardizedFileURL == fixtureURL &&
                        store.generation == replacementGeneration && store.previewHost === replacementView
                }
                var appliedItem: AVPlayerItem?
                let applied = await LaneSelfTest.waitUntil(15) {
                    guard isReplacementSession(), store.appliedGeneration == replacementGeneration,
                          let candidate = store.player.currentItem, candidate !== item else { return false }
                    appliedItem = candidate
                    return true
                }
                try Task.checkCancellation()
                guard applied, isReplacementSession(), store.appliedGeneration == replacementGeneration,
                      let replacement = appliedItem, store.player.currentItem === replacement else {
                    throw NSError(domain: "replacement preview identity changed", code: 1)
                }
                // The same view may still carry this run's original hook. All other owners retain their slot.
                if let observer = replacementView.spectrumOverlay.publicationForParityTest {
                    try demand(replacementView === view && observer.owner == runID, "replacement observer occupied")
                }
                let sentinel = UUID()
                let scopes = store.scopedURLs, outputs = replacement.outputs
                replacementView.spectrumOverlay.publicationForParityTest = (sentinel, { _, _, _, _ in })
                publication = nil
                receive(119, store.seekToken, entry.id, .cancelled)
                report["lateRejected"] = publication == nil
                verifyReplacement = {
                    let intact = isReplacementSession() && store.appliedGeneration == replacementGeneration &&
                        store.scopedURLs == scopes &&
                        store.player.currentItem === replacement && replacement.outputs == outputs &&
                        replacementView.spectrumOverlay.publicationForParityTest?.owner == sentinel
                    if replacementView.spectrumOverlay.publicationForParityTest?.owner == sentinel {
                        replacementView.spectrumOverlay.publicationForParityTest = nil
                    }
                    return intact
                }
                throw NSError(domain: "fixture session replaced", code: 1)
            }
            for k in requested {
                try Task.checkCancellation()
                try demand(ownsSession(), "lost fixture session before seek")
                publication = nil
                store.seek(to: k)
                let token = store.seekToken, target = CMTime(value: Int64(k), timescale: 30)
                var buffer: CVPixelBuffer?, pts = CMTime.invalid
                let start = ProcessInfo.processInfo.systemUptime
                var events = [[String: Any]]()
                var previous = NSDictionary()
                var latest = [String: Any]()
                func observe() -> Bool {
                    let p = publication
                    let identity = ownsSession() && !Task.isCancelled &&
                        store.appliedGeneration == generation && store.seekToken == token &&
                        store.player.currentItem === item && !view.hasPendingSpectrumSeek &&
                        view.spectrumOverlay.confirmedFrame == k && p?.0 == k && p?.1 == token && p?.2 == entry.id
                    if identity && buffer == nil { buffer = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: &pts) }
                    let expected = Set(snapshot.subtitles(atFrame: k).map(\.id))
                    var presented = Set<UUID>()
                    var layers = [[String: Any]]()
                    for sub in snapshot.subtitles {
                        let model = view.subtitleLayerForTest(sub.id)
                        let layer = model?.presentation()
                        if let layer, layer.opacity > 0.5 && layer.contents != nil && !layer.isHidden {
                            presented.insert(sub.id)
                        }
                        if diagnostic {
                            layers.append(["id": sub.id.uuidString, "text": sub.text,
                                "presentation": layer != nil, "hidden": layer?.isHidden ?? true,
                                "opacity": layer?.opacity ?? -1, "contents": layer?.contents != nil,
                                "modelRaster": image(model).map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                                "rect": rect(layer?.frame ?? .zero)])
                        }
                    }
                    let exactPTS = buffer != nil && CMTimeCompare(pts, target) == 0
                    if diagnostic {
                        let siblings = view.layer?.sublayers ?? []
                        let order = [view.playerLayer, view.stageLayer, view.spectrumCanvas, view.subtitleHost]
                        latest = ["session": store.projectSession, "generation": store.generation,
                            "applied": store.appliedGeneration, "token": store.seekToken, "sameItem": store.player.currentItem === item,
                            "pending": view.hasPendingSpectrumSeek, "confirmed": view.spectrumOverlay.confirmedFrame ?? -1,
                            "publicationFrame": p?.0 ?? -1, "publicationToken": p?.1 ?? -1,
                            "entryMatches": p?.2 == entry.id, "sourceMatches": store.timeline.spectrumMediaID(entry) == sourceID,
                            "buffer": buffer != nil, "pts": pts.isNumeric ? pts.seconds : -1,
                            "expected": expected.map(\.uuidString).sorted(), "presented": presented.map(\.uuidString).sorted(),
                            "syncItem": view.subtitleSync?.playerItem === item, "layers": layers,
                            "ordered": siblings.count >= 4 && zip(siblings, order).allSatisfy { $0 === $1 }]
                        if !previous.isEqual(to: latest), events.count < 80 {
                            previous = latest as NSDictionary
                            events.append(["seconds": ProcessInfo.processInfo.systemUptime - start, "state": latest])
                        }
                    }
                    return identity && exactPTS && expected == presented
                }
                let settled = await LaneSelfTest.waitUntil(15) { observe() }
                var row: [String: Any] = ["frame": k, "seekToken": token, "session": store.projectSession,
                    "generation": store.generation, "appliedGeneration": store.appliedGeneration,
                    "itemTime": item.currentTime().seconds, "videoPTS": pts.isNumeric ? pts.seconds : -1,
                    "confirmedFrame": view.spectrumOverlay.confirmedFrame ?? -1, "ready": settled,
                    "sourceFrame": k + 30, "sourceSampleFrame": (k + 30) * 1600]
                if diagnostic {
                    row["atDeadlineOrPass"] = latest
                    row["decisionSeconds"] = ProcessInfo.processInfo.systemUptime - start
                    if !settled {
                        let late = await LaneSelfTest.waitUntil(1) { observe() }
                        row["lateReady"] = late
                        row["lastLateState"] = latest
                    }
                    row["transitions"] = events
                }
                try Task.checkCancellation()
                try demand(ownsSession(), "lost fixture session during seek")
                guard settled, let buffer, let p = publication else {
                    row["outcome"] = publication.map { String(describing: $0.3) } ?? "no publication"
                    rows.append(row); throw NSError(domain: "frame \(k) identity/readiness timeout", code: 1)
                }
                try demand(store.timeline == snapshot && CMTimeCompare(item.currentTime(), target) == 0, "snapshot/item time")
                guard case let .ready(bands, rendered) = p.3 else {
                    row["outcome"] = String(describing: p.3); rows.append(row)
                    throw NSError(domain: "frame \(k) analysis unavailable", code: 1)
                }
                guard let reference = referenceResult.bands[String(k)] else { throw NSError(domain: "missing result.json.bands[\(k)]", code: 1) }
                let bandsEqual = bands == reference
                row["bands"] = bands; row["bandsEqualExport"] = bandsEqual
                let expectedRaster = try renderer.render(bands: reference, style: entry.style)
                let spectrumLayer = view.spectrumOverlay.layers[entry.id]
                let actual = image(spectrumLayer)
                var publicationMatches = false
                var spectrumEqual = false
                if let actual, let expectedRaster, let rendered {
                    spectrumEqual = try same(actual, expectedRaster.image) && view.spectrumOverlay.layers[entry.id]!.frame == PausedSpectrumOverlay.layerRect(expectedRaster.drawRect)
                    let outcomeImage = wrongObject ? expectedRaster.image : rendered.image
                    publicationMatches = actual === outcomeImage
                    row["publishedObjectMatchesOutcome"] = publicationMatches
                    row["spectrumSHA256"] = try sha(pixels(actual))
                    row["spectrumRect"] = rect(view.spectrumOverlay.layers[entry.id]!.frame)
                } else if let spectrumLayer, expectedRaster == nil, rendered == nil {
                    publicationMatches = spectrumLayer.contents == nil && spectrumLayer.frame == .zero
                    spectrumEqual = publicationMatches && bandsEqual
                }
                row["spectrumExact"] = spectrumEqual
                row["outcome"] = actual == nil ? "ready-empty" : "ready-image"
                var subtitleRows = [[String: Any]](), subtitleEqual = true
                for sub in snapshot.subtitles {
                    let layer = view.subtitleLayerForTest(sub.id)
                    let visible = layer?.presentation().map { $0.opacity > 0.5 && !$0.isHidden && $0.contents != nil } ?? false
                    var sr: [String: Any] = ["id": sub.id.uuidString, "text": sub.text, "visible": visible, "expected": sub.visible(atFrame: k)]
                    subtitleEqual = subtitleEqual && visible == sub.visible(atFrame: k)
                    if visible {
                        guard let layer, let actual = missingRaster ? nil : image(layer) else {
                            sr["rasterExact"] = false
                            sr["error"] = "missing visible subtitle raster"
                            subtitleRows.append(sr)
                            subtitleEqual = false
                            continue
                        }
                        let reference = SubtitleRenderer.shared.raster(sub)
                        let equal = try same(actual, reference.image) && layer.frame == PausedSpectrumOverlay.layerRect(reference.drawRect)
                        sr["rasterExact"] = equal; sr["rect"] = rect(layer.frame); sr["sha256"] = try sha(pixels(actual))
                        subtitleEqual = subtitleEqual && equal
                    }
                    subtitleRows.append(sr)
                }
                row["subtitles"] = subtitleRows; row["subtitleExact"] = subtitleEqual
                let layers = view.layer?.sublayers ?? []
                let order = [view.playerLayer, view.stageLayer, view.spectrumCanvas, view.subtitleHost]
                let ordered = layers.count >= 4 && zip(layers, order).allSatisfy { $0 === $1 }
                row["zOrder"] = ordered
                // Independent marker decode from the actual AVPlayerItemVideoOutput, not CALayer.render.
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                var marker = 0
                for bit in 0..<9 { if bytes[60 * stride + (55 + bit * 40) * 4 + 1] > 128 { marker |= 1 << bit } }
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                row["videoMarker"] = marker
                rows.append(row)
                try demand(marker == k && bandsEqual && spectrumEqual && publicationMatches && subtitleEqual && ordered, "frame \(k) parity mismatch")
            }
            report["status"] = "CAPTURE PASS"
            report["decodedColorParity"] = "UNCONFIRMED; BGRA/420v conversion not equated"
        } catch { report["error"] = String(describing: error) }
        return true
    }
}
#endif
