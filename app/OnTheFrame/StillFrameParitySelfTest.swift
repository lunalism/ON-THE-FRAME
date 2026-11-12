#if DEBUG
import AppKit
import AVFoundation
import CryptoKit
import Darwin
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

    // A dedicated launcher inherits the other end of this socket. Application logs use other FDs.
    private static func deliver(_ report: [String: Any], trace: Data?, runID: UUID,
                                rows: Int, mayStopChild: Bool) throws {
        guard let raw = ProcessInfo.processInfo.environment["OTF_RESULT_FD"],
              let fd = Int32(raw), fd > STDERR_FILENO else {
            throw NSError(domain: "missing launcher socket", code: 1)
        }
        let channel = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let result = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let events = trace ?? Data()
        try demand(rows <= 3000 && result.count <= 4 * 1024 * 1024 &&
                   events.count <= SpectrumContinuityTrace.byteLimit, "continuous record size")
        let passed = report["status"] as? String == "CONTINUOUS CAPTURE COMPLETE" &&
            report["fixtureUnchanged"] as? Bool == true && report["ownedResourcesReleased"] as? Bool == true &&
            mayStopChild && !events.isEmpty
        let header: [String: Any] = ["protocol": "OTFContinuous", "version": 1, "runID": runID.uuidString,
            "status": passed ? "PASS" : "FAIL", "rows": rows, "mayStopChild": mayStopChild,
            "reportBytes": result.count, "traceBytes": events.count, "reportSHA256": sha(result), "traceSHA256": sha(events)]
        var prefix = try JSONSerialization.data(withJSONObject: header)
        prefix.append(10)
        try channel.write(contentsOf: prefix)
        try channel.write(contentsOf: result)
        try channel.write(contentsOf: events)
        try channel.close()
    }

    // Control messages stay on stderr; OTFContinuous v1 remains one result/trace record.
    static func phase(_ runID: UUID, _ phase: String, fields: [String: Any] = [:]) {
        var value = fields
        value["runID"] = runID.uuidString; value["phase"] = phase
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            // A timed-out parent may have closed its pipe. Never turn that into SIGPIPE.
            guard fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1) != -1 else { return }
            try? FileHandle.standardError.write(contentsOf: Data("OTF_DEBUG ".utf8) + data + Data([10]))
        }
    }

    private static func fixtureRead(_ root: URL, fd: Int32, name: String) throws -> Data {
        var pinned = stat(), named = stat()
        guard fstat(fd, &pinned) == 0, lstat(root.path, &named) == 0,
              pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino,
              root.resolvingSymlinksInPath().path == root.path else {
            throw NSError(domain: "fixture directory identity changed", code: 1)
        }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "fixture read: " + name]) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat(), path = stat()
        try demand(fstat(file, &before) == 0 && (before.st_mode & S_IFMT) == S_IFREG &&
                   before.st_size >= 0 && before.st_size <= 16 * 1024 * 1024, "fixture regular bounded file: " + name)
        var data = Data()
        let limit = 16 * 1024 * 1024
        while let chunk = try handle.read(upToCount: min(65536, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            try demand(data.count <= limit, "fixture grew beyond read bound: " + name)
        }
        try demand(Int64(data.count) == before.st_size && fstat(file, &after) == 0 && fstatat(fd, name, &path, AT_SYMLINK_NOFOLLOW) == 0 &&
                   before.st_dev == path.st_dev && before.st_ino == path.st_ino &&
                   before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
                   before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, "fixture file replaced: " + name)
        return data
    }

    private static var activeRun: UUID?

    @discardableResult
    static func run(folder: URL, launcherRun: UUID? = nil) async -> Bool {
        guard activeRun == nil else { return false }
        let runID = launcherRun ?? UUID()
        activeRun = runID
        defer { if activeRun == runID { activeRun = nil } }
        let store = ProjectStore.shared
        let diagnostic = ProcessInfo.processInfo.arguments.contains("-OTFFrame120Diagnostic")
        let args = ProcessInfo.processInfo.arguments
        let continuous = args.contains("-OTFContinuousParityTest")
        let filename = "still-frame-parity.json"
        guard !continuous || launcherRun != nil else { return false }
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
        var traceData: Data?
        if continuous { report["runID"] = runID.uuidString }
        var fixture: URL?
        var selectedScope: URL?
        var rootFD: Int32 = -1
        var failureStage = "authorization"
        // Registered first: report/final hash and all inner async cleanup run before access retires.
        defer {
            if rootFD >= 0 { close(rootFD) }
            if let selectedScope { selectedScope.stopAccessingSecurityScopedResource() }
        }
        defer {
            let mayTerminate = ownsSession() && !store.isDirty && store.exportPhase == .idle &&
                !store.openRequested && store.openProgress == nil && store.importProgress == nil
            report["terminationAuthorized"] = mayTerminate
            if let verifyReplacement { report["replacementIntact"] = verifyReplacement() }
            if let fixture {
                let unchanged = hashes.allSatisfy { name, expected in
                    let data = continuous ? try? fixtureRead(fixture, fd: rootFD, name: name)
                        : try? Data(contentsOf: fixture.appendingPathComponent(name))
                    return data.map(sha) == expected
                }
                report["fixtureUnchanged"] = unchanged
                if continuous && !unchanged {
                    report["status"] = "FAIL"
                    if report["error"] == nil {
                        report["failureStage"] = "finalHashVerification"
                        report["error"] = "final fixture identity/read/hash verification failed"
                    }
                }
            }
            report["frames"] = rows
            do {
                if continuous {
                    report["terminationAuthorized"] = false
                    phase(runID, "delivery")
                    try deliver(report, trace: traceData, runID: runID, rows: rows.count, mayStopChild: mayTerminate)
                } else {
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: folder.appendingPathComponent(filename), options: .withoutOverwriting)
                    if mayTerminate { NSApp.terminate(nil) }
                }
            } catch {
                phase(runID, "deliveryFailure", fields: ["error": String(describing: error)])
                NSLog("Diagnostic delivery FAIL run=%@: %@", runID.uuidString, String(describing: error))
            }
        }
        do {
            let root: URL
            if continuous {
                failureStage = "folderSelection"
                phase(runID, "selection")
                let panel = NSOpenPanel()
                panel.canChooseFiles = false; panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
                panel.message = "Debug 연속 검사: 원본 sp4a01/color 폴더를 직접 선택하세요."
                guard panel.runModal() == .OK, let selected = panel.url else {
                    throw NSError(domain: "fixture selection cancelled", code: NSUserCancelledError)
                }
                failureStage = "fixtureDirectoryIdentity"
                let fixed = "/Volumes/LunaData/dev/ON-THE-FRAME/app/selftest-work/sp4a01/color"
                try demand(folder.standardizedFileURL.path == fixed && selected.standardizedFileURL.path == fixed &&
                           selected.resolvingSymlinksInPath().path == fixed, "wrong fixture directory or symbolic link")
                root = selected // Keep the actual authorized URL; never reconstruct it from the environment.
                if selected.startAccessingSecurityScopedResource() { selectedScope = selected }
                report["scopeStarted"] = selectedScope != nil
                failureStage = "authorizedDirectoryRead"
                rootFD = open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard rootFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                failureStage = "preflightHashes"
                phase(runID, "preflight")
            } else {
                try demand(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path), "fresh output folder required")
                let descriptor = try String(contentsOf: folder.appendingPathComponent("fixture-path.txt"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                root = URL(fileURLWithPath: descriptor, isDirectory: true)
            }
            fixture = root
            for (name, expected) in hashes {
                try demand(sha(continuous ? fixtureRead(root, fd: rootFD, name: name) : Data(contentsOf: root.appendingPathComponent(name))) == expected, "hash " + name)
            }
            report["hashes"] = hashes
            if continuous { failureStage = "referenceRead" }
            let referenceURL = root.appendingPathComponent("result.json")
            let referenceResult: ReferenceResult
            do {
                referenceResult = try JSONDecoder().decode(ReferenceResult.self, from: continuous ? fixtureRead(root, fd: rootFD, name: "result.json") : Data(contentsOf: referenceURL))
            } catch {
                throw NSError(domain: "invalid result.json: " + String(describing: error), code: 1)
            }
            try referenceResult.validate()
            try demand(initialSession == 0 && store.projectURL == nil && !store.isDirty &&
                       store.timeline.isEmpty, "fresh standalone process required")
            if continuous { failureStage = "projectOpen" }
            let opened = await store.openProject(at: root.appendingPathComponent("fixture.ontheframe"))
            try demand(opened, "project open: " + (store.alert?.message ?? store.statusMessage ?? "unknown open failure"))
            let project = store.projectID, openedSession = store.projectSession
            try demand(openedSession == initialSession + 1 && store.projectURL?.standardizedFileURL ==
                       root.appendingPathComponent("fixture.ontheframe").standardizedFileURL, "fixture session")
            if continuous { failureStage = "previewReadiness" }
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
            if continuous {
                report["task"] = "SP-4B-01"
                report.removeValue(forKey: "requestedFrames")
                let overlay = view.spectrumOverlay
                guard overlay.playbackObservationForTest == nil, !SpectrumContinuityTrace.active,
                      let media = store.mediaByID[sourceID],
                      media.url.standardizedFileURL == root.appendingPathComponent("selected.wav").standardizedFileURL,
                      let piece = snapshot.spectrumPieces(entry).first, piece.start == 0,
                      piece.sourceIn == 30, piece.length == 360 else {
                    throw NSError(domain: "continuous fixture or observer mismatch", code: 1)
                }
                let pieces = snapshot.spectrumPieces(entry), settings = entry.style.analysisSettings
                try demand(pieces.count == 1, "continuous source pieces")
                let expected = try await Task.detached {
                    let wav = try await SpectrumFileSource.open(url: media.url)
                    var chunks = [Int: [[Float]]](), values = [[Float]]()
                    for k in 0..<360 {
                        for key in try SpectrumAnalysis.chunks(frame: k, pieces: pieces, fps: 30, rate: wav.sampleRate,
                                                              settings: settings, chunkSamples: wav.chunkSamples) where chunks[key] == nil {
                            chunks[key] = try await wav.decodeChunk(key)
                        }
                        values.append(try SpectrumAnalysis.bands(frame: k, pieces: pieces, fps: 30, rate: wav.sampleRate,
                            channelCount: wav.channelCount, chunkSamples: wav.chunkSamples, settings: settings) { chunks[$0] })
                    }
                    return values
                }.value
                try demand(ownsSession(), "session changed during reference preparation")
                for k in frames { try demand(expected[k] == referenceResult.bands[String(k)], "export reference frame \(k)") }
                store.seek(to: 0)
                let token = store.seekToken
                let primed = await LaneSelfTest.waitUntil(15) {
                    ownsSession() && publication?.0 == 0 && publication?.1 == token && !view.hasPendingSpectrumSeek
                }
                guard primed, ownsSession(), case let .ready(_, rendered?) = publication?.3,
                      image(overlay.layers[entry.id]) === rendered.image else {
                    throw NSError(domain: "initial actual layer publication unconfirmed", code: 1)
                }
                try demand(!SpectrumContinuityTrace.active, "trace already active")
                let tracing = SpectrumContinuityTrace.validate()
                try demand(tracing && overlay.playbackObservationForTest == nil, "trace admission")
                SpectrumContinuityTrace.begin()
                let playback = store.spectrumPreview.playback
                let start = ProcessInfo.processInfo.systemUptime
                var truncated = false, lost = false
                defer {
                    if overlay.playbackObservationForTest?.owner == runID { overlay.playbackObservationForTest = nil }
                    do {
                        traceData = try SpectrumContinuityTrace.finishData(validated: tracing, runID: runID)
                    } catch {
                        report["status"] = "FAIL"
                        report["traceError"] = String(describing: error)
                    }
                    if ownsSession() && store.isPlaying { store.pause() }
                }
                overlay.playbackObservationForTest = (runID, {
                    guard ownsSession(), store.seekToken == token else { lost = true; return }
                    guard rows.count < 3000 else { truncated = true; return }
                    let time = item.currentTime(), f = playback.currentFrame
                    let layer = overlay.layers[entry.id], actual = image(layer)
                    let siblings = view.layer?.sublayers ?? []
                    let order = [view.playerLayer, view.stageLayer, view.spectrumCanvas, view.subtitleHost]
                    var row: [String: Any] = ["elapsed": ProcessInfo.processInfo.systemUptime - start,
                        "tick": SpectrumContinuityTrace.tick, "itemSeconds": time.seconds,
                        "frame": f ?? -1, "session": store.projectSession, "generation": store.appliedGeneration,
                        "layerImage": SpectrumContinuityTrace.id(actual), "hasContents": layer?.contents != nil,
                        "sourceMatches": store.timeline.spectrumMediaID(entry) == sourceID,
                        "ordered": siblings.count >= 4 && zip(siblings, order).allSatisfy { $0 === $1 }]
                    row["subtitles"] = snapshot.subtitles.map { sub -> [String: Any] in
                        let presented = view.subtitleLayerForTest(sub.id)?.presentation()
                        return ["id": sub.id.uuidString, "opacity": presented?.opacity ?? -1,
                                "visible": presented.map { $0.opacity > 0.5 && $0.contents != nil && !$0.isHidden } ?? false]
                    }
                    if let f, expected.indices.contains(f) {
                        let pts = playback.timing.confirmedPTSForTest
                        row["pts"] = pts.isNumeric ? pts.seconds : -1
                        row["ptsExact"] = CMTimeCompare(pts, CMTime(value: Int64(f), timescale: 30)) == 0
                        row["sourceFrame"] = f - piece.start + piece.sourceIn
                        if let outcome = playback.currentOutcome(spectrum: entry.id, frame: f) {
                            row["status"] = SpectrumContinuityTrace.outcome(outcome)
                            if case let .ready(bands, render) = outcome {
                                row["bandsExact"] = bands.count == 64 && bands == expected[f]
                                row["acceptedImage"] = SpectrumContinuityTrace.id(render?.image)
                                row["geometryExact"] = render.map { layer?.frame == PausedSpectrumOverlay.layerRect($0.drawRect) } ?? (layer == nil)
                            }
                        } else { row["status"] = "waiting" }
                    } else { row["status"] = "no selected frame" }
                    rows.append(row)
                })
                failureStage = "playback"
                phase(runID, "playback")
                store.play()
                let ended = await LaneSelfTest.waitUntil(17) { !ownsSession() || !store.isPlaying || truncated || lost }
                try demand(ownsSession(), "lost continuous session")
                report["endFrame"] = store.playhead
                report["endSeconds"] = item.currentTime().seconds
                report["elapsed"] = ProcessInfo.processInfo.systemUptime - start
                report["peakPending"] = playback.metrics.peakPending
                report["peakRetainedBytes"] = playback.metrics.peakBytes
                report["peakRetained"] = playback.metrics.peakRetained
                try demand(ended && !store.isPlaying && store.playhead == 360 && !rows.isEmpty &&
                           !lost && !truncated && !SpectrumContinuityTrace.truncated, "continuous capture incomplete")
                report["status"] = "CONTINUOUS CAPTURE COMPLETE"
                return true
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
        } catch {
            if continuous { report["failureStage"] = failureStage }
            report["error"] = String(describing: error)
            if continuous {
                report["errorDomain"] = (error as NSError).domain
                report["errorCode"] = (error as NSError).code
            }
        }
        return true
    }
}
#endif
