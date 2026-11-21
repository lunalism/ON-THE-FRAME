#if DEBUG
import AppKit
import AVFoundation
import OnTheFrameEngine

/// Runs in an isolated normal editor with generated project copies. Every completion
/// below comes from playing the current AVPlayerItem through its actual end.
@MainActor
enum SpectrumPlaybackEndSelfTest {
    struct Failure: Error { let check: String }

    static func run(store: ProjectStore, active: URL, early: URL, empty: URL, relink: URL,
                    expectedLayoutSuite: String = "dev.ontheframe.spectrumfx02c.playbackend01.end-check") async throws {
        func check(_ result: Bool, _ name: String) throws {
            print(result ? "PASS" : "FAIL", name)
            if !result { throw Failure(check: name) }
        }
        func ready() -> Bool {
            store.appliedGeneration == store.generation && store.player.currentItem?.status == .readyToPlay
        }
        func open(_ url: URL) async throws {
            let opened = await store.openProject(at: url)
            let installed = await LaneSelfTest.waitUntil(15) { ready() && store.projectURL == url }
            try check(opened && installed && store.missingMedia.isEmpty, "opened generated " + url.lastPathComponent)
        }
        try check(store.projectURL == nil && !store.isDirty && store.recentProjects.isEmpty &&
                  expectedLayoutSuite.hasSuffix(".end-check") && EditorLayout.shared.suiteName == expectedLayoutSuite,
                  "fresh isolated editor")
        guard let host = store.previewHost, host.window?.isVisible == true else { throw Failure(check: "visible editor") }
        let overlay = host.spectrumOverlay
        store.player.isMuted = true
        try await open(active)
        guard let entry = store.timeline.spectra.first, let audioID = store.timeline.spectrumMediaID(entry),
              let initialItem = store.player.currentItem else { throw Failure(check: "final Spectrum and source") }
        let end = store.timeline.durationFrames
        let finalFrame = end - 1
        try check(end > 30 && entry.end == end, "fixture covers the final composition frame")
        func installedImage() -> CGImage? {
            guard let content = overlay.layers[entry.id]?.contents, CFGetTypeID(content as CFTypeRef) == CGImage.typeID else { return nil }
            return (content as! CGImage)
        }
        func blank() -> Bool { overlay.layers.values.allSatisfy { $0.contents == nil } }
        func seek(_ frame: Int) async throws {
            store.seek(to: frame)
            let finished = await LaneSelfTest.waitUntil(8) {
                !host.hasPendingSpectrumSeek && overlay.confirmedFrame == frame && store.playhead == frame
            }
            try check(finished, "ordinary paused seek to \(frame)")
        }
        func naturalEnd() async throws {
            try await seek(end - 18)
            guard let item = store.player.currentItem else { throw Failure(check: "playable item") }
            let notice = LaneSelfTest.Flag()
            let observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: item, queue: .main) { _ in
                MainActor.assumeIsolated { notice.v = true }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            store.play()
            try check(store.isPlaying, "transport starts from end minus 18 frames")
            let finished = await LaneSelfTest.waitUntil(10) {
                notice.v && !store.isPlaying && store.playhead == end
            }
            try check(finished && store.player.rate == 0 && store.player.currentItem === item &&
                      CMTimeCompare(store.player.currentTime(), store.settings.time(end)) == 0,
                      "real item completed at the exact end without rewinding")
        }

        let original = store.timeline
        try await seek(finalFrame)
        let referenceReady = await LaneSelfTest.waitUntil(8) { installedImage() != nil }
        guard referenceReady, let reference = installedImage(), let expected = reference.dataProvider?.data as Data?,
              expected.contains(where: { $0 != 0 }), let rect = overlay.layers[entry.id]?.frame else {
            throw Failure(check: "nonempty paused reference raster")
        }
        if InternalImagePreview.containsImages(store.timeline) {
            // Image compositions keep their existing access-driven clearing at playback start.
            try await seek(30)
            try check(await LaneSelfTest.waitUntil(8) { installedImage() != nil }, "image-backed paused raster before start")
            let retainedBefore = overlay.retainedTransitionTicks
            store.play()
            try check(store.isPlaying && overlay.transitionRetentionForTest == nil && blank(),
                      "image-backed start clears without transition retention")
            store.pause()
            try check(overlay.retainedTransitionTicks == retainedBefore && overlay.transitionRetentionForTest == nil,
                      "image-backed playback never retained a transition frame")
            try await seek(finalFrame)
            try check(await LaneSelfTest.waitUntil(8) { installedImage() != nil }, "reference frame restored after image start check")
        }
        let observerID = UUID()
        try check(overlay.publicationForParityTest == nil, "paused publication observer available")
        var endPublications = 0
        overlay.publicationForParityTest = (observerID, { frame, token, id, outcome in
            if store.playhead == end, !store.isPlaying, frame == finalFrame, token == store.seekToken,
               id == entry.id, case .ready(_, .some) = outcome { endPublications += 1 }
        })
        defer {
            if overlay.publicationForParityTest?.owner == observerID { overlay.publicationForParityTest = nil }
        }
        try await naturalEnd()
        let arrived = await LaneSelfTest.waitUntil(8) { endPublications > 0 && installedImage() != nil }
        let actual = installedImage()
        try check(arrived && overlay.confirmedFrame == finalFrame && overlay.layers.count == 1 &&
                  actual?.width == reference.width && actual?.height == reference.height &&
                  actual?.bytesPerRow == reference.bytesPerRow && actual?.dataProvider?.data as Data? == expected &&
                  overlay.layers[entry.id]?.frame == rect, "fresh paused publication matches last-frame pixels and geometry")
        try check(store.timeline == original && !store.isDirty, "completion preserves timeline, duration and dirty state")
        store.play()
        try check(store.isPlaying && store.playhead < finalFrame && overlay.confirmedFrame == nil,
                  "explicit restart clears the endpoint and starts at the beginning")
        let advanced = await LaneSelfTest.waitUntil(6) { store.playhead > 3 && store.playhead < end - 18 }
        store.pause()
        let paused = await LaneSelfTest.waitUntil(8) { overlay.confirmedFrame == store.playhead && installedImage() != nil }
        try check(advanced && paused && !store.isPlaying && store.playhead < finalFrame, "manual Pause renders its own frame")
        try await seek(end)
        try check(blank(), "manual seek to exclusive endpoint has no Spectrum")
        try await seek(30)
        store.play()
        try check(store.isPlaying, "playing before manual seek to end")
        let beforeManualEnd = endPublications
        store.seek(to: end)
        let atEnd = await LaneSelfTest.waitUntil(8) {
            !host.hasPendingSpectrumSeek && store.player.currentTime() == store.settings.time(end) &&
                store.playhead == end && store.player.rate == 0
        }
        try check(atEnd && endPublications == beforeManualEnd && overlay.confirmedFrame != finalFrame && blank(),
                  "manual seek during playback cannot authorize the preceding frame")
        store.pause()

        try await naturalEnd()
        try check(await LaneSelfTest.waitUntil(8) { endPublications > beforeManualEnd && installedImage() != nil },
                  "endpoint visible before appearance edit")
        store.select(entry.id)
        let beforeEditDepth = store.history.undoDepth
        let previousItem = store.player.currentItem
        var appearance = entry.style
        appearance.hueInterpolationDegrees = entry.style.hueInterpolationDegrees == 180 ? 360 : 180
        let edited = store.updateSpectrumLiveStyle(entry.id, style: appearance, project: store.projectSession,
            revision: store.spectrumSelectionRevision, expectedGeneration: store.generation, kind: "numeric")
        try check(edited && store.timeline.spectrum(entry.id)?.style == appearance && store.isDirty &&
                  store.history.undoDepth == beforeEditDepth + 1 && store.player.currentItem === previousItem &&
                  store.playhead == end && overlay.confirmedFrame != finalFrame && blank(),
                  "in-place Inspector Hue edit invalidates endpoint and creates exactly one Undo")
        store.undo()
        let undoReady = await LaneSelfTest.waitUntil(12) { ready() && !host.hasPendingSpectrumSeek }
        try check(undoReady && store.timeline == original && !store.isDirty && store.playhead == end &&
                  overlay.confirmedFrame != finalFrame && blank(), "Undo restores style without reviving endpoint presentation")

        // Delay a real paused result without replacing it. Release it after an
        // ordinary endpoint seek, then require a later exact seek to publish.
        func holdAtEnd() -> SpectrumOverlaySelfTest.Gate {
            let gate = SpectrumOverlaySelfTest.Gate()
            store.spectrumPreview.beforeDeliveryForTest = { result in
                if !store.isPlaying, store.playhead == end, overlay.confirmedFrame == finalFrame,
                   case .ready(_, .some) = result { await gate.wait() }
            }
            return gate
        }
        let staleGate = holdAtEnd()
        defer { staleGate.release(); store.spectrumPreview.beforeDeliveryForTest = nil }
        try await naturalEnd()
        try check(await LaneSelfTest.waitUntil(8) { staleGate.entered }, "validated ready result held at endpoint")
        let precedingCount = endPublications
        store.spectrumPreview.beforeDeliveryForTest = nil
        try await seek(end)
        staleGate.release()
        try await seek(finalFrame - 1)
        try check(await LaneSelfTest.waitUntil(8) { installedImage() != nil } && endPublications == precedingCount,
                  "held endpoint callback cannot publish after a manual seek")

        // The edit goes through the real audio relink and image item rebuild.
        let sourceGate = holdAtEnd()
        defer { sourceGate.release(); store.spectrumPreview.beforeDeliveryForTest = nil }
        try await naturalEnd()
        try check(await LaneSelfTest.waitUntil(8) { sourceGate.entered }, "endpoint callback pending during source change")
        store.spectrumPreview.beforeDeliveryForTest = nil
        let beforeRelink = store.player.currentItem
        let relinked = await store.relinkMedia(audioID, to: relink)
        sourceGate.release()
        let rebuilt = await LaneSelfTest.waitUntil(12) { ready() && store.player.currentItem !== beforeRelink &&
            !host.hasPendingSpectrumSeek && store.mediaByID[audioID]?.url.standardizedFileURL == relink.standardizedFileURL }
        try check(relinked && rebuilt && store.playhead == end && blank() && endPublications == precedingCount,
                  "source edit and rebuilt item at endpoint reject obsolete raster")
        try await seek(finalFrame)
        try check(await LaneSelfTest.waitUntil(8) { installedImage() != nil }, "new audio identity can render after ordinary seek")

        try await open(early)
        let length = store.timeline.spectra.first?.end ?? 0
        try check(length == finalFrame && store.timeline.durationFrames == end, "early Spectrum ends exactly one frame before project end")
        try await seek(length - 1)
        try check(await LaneSelfTest.waitUntil(8) { installedImage() != nil }, "early clip visible inside interval")
        try await naturalEnd()
        try check(overlay.layers.isEmpty && endPublications == precedingCount, "natural completion cannot resurrect an earlier clip")
        try await open(empty)
        try check(store.timeline.spectra.isEmpty && store.timeline.durationFrames == end, "project switch to no Spectrum")
        try await naturalEnd()
        try check(blank(), "no Spectrum project completes normally")
        try await seek(12)
        // Explicitly inject only an obsolete-item notification to challenge the
        // item guard. All positive endpoint tests above used native transport.
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: initialItem)
        try check(store.playhead == 12 && !store.isPlaying && blank(), "obsolete item cannot complete the new project")
        if InternalImagePreview.containsImages(original) {
            try check(overlay.retainedNaturalEnds == 0 && overlay.retainedTransitionTicks == 0,
                      "image-backed runs never retained a transition or natural-end frame")
        }
        try await startingFrameChecks(audio: relink, check: check)
        if InternalImagePreview.containsImages(original) {
            // Own temporary folder: never inside preserved evidence, removed afterwards.
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("otf-flicker-image-free-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let imageFree = try imageFreeCopy(of: active, in: folder)
            try await transitionRetentionChecks(store: store, project: imageFree, relinkAudio: relink, check: check)
            // Hand the caller the same final project state as before these checks.
            try await open(empty)
        }
    }

    /// The generated project's still clip is replaced by consecutive segments of its
    /// generated movie (shorter than the clip). This is the image-free (temporal) case of
    /// the owner check. Media keep their absolute `ref.path`, which the opener falls back
    /// to when the relative hint does not exist beside the temporary copy.
    private static func imageFreeCopy(of project: URL, in folder: URL) throws -> URL {
        guard var doc = try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any],
              var media = doc["media"] as? [[String: Any]], var clips = doc["videoClips"] as? [[String: Any]] else {
            throw Failure(check: "readable generated project")
        }
        func ref(_ entry: [String: Any]) -> [String: Any] { entry["ref"] as? [String: Any] ?? [:] }
        let stills = Set(media.filter { ref($0)["kind"] as? String == "stillImage" }.compactMap { ref($0)["id"] as? String })
        guard !stills.isEmpty,
              let movie = media.first(where: { ref($0)["kind"] as? String == "video" && ref($0)["hasVideo"] as? Bool == true }),
              let movieID = ref(movie)["id"] as? String, let movieFrames = ref(movie)["frameCount"] as? Int, movieFrames > 0 else {
            throw Failure(check: "generated still image and movie")
        }
        var replaced: [[String: Any]] = []
        for clip in clips {
            guard stills.contains(clip["mediaID"] as? String ?? "") else { replaced.append(clip); continue }
            guard let start = clip["start"] as? Int, let length = clip["length"] as? Int, length > 0 else {
                throw Failure(check: "generated still clip timing")
            }
            var offset = 0
            while offset < length {
                var segment = clip
                segment["id"] = UUID().uuidString
                segment["mediaID"] = movieID
                segment["sourceIn"] = 0
                segment["start"] = start + offset
                segment["length"] = min(movieFrames, length - offset)
                replaced.append(segment)
                offset += movieFrames
            }
        }
        clips = replaced
        media.removeAll { stills.contains(ref($0)["id"] as? String ?? "") }
        doc["media"] = media
        doc["videoClips"] = clips
        doc["projectID"] = UUID().uuidString
        let url = folder.appendingPathComponent("image-free-" + UUID().uuidString + ".ontheframe")
        try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .withoutOverwriting)
        return url
    }

    /// FX02C-FLICKER-FIX-02: start and natural-end retention, interruption and stale-input rejection.
    private static func transitionRetentionChecks(store: ProjectStore, project: URL, relinkAudio: URL,
                                                  check: (Bool, String) throws -> Void) async throws {
        guard let host = store.previewHost, host.window?.isVisible == true else { throw Failure(check: "visible editor") }
        let overlay = host.spectrumOverlay
        let opened = await store.openProject(at: project)
        let installed = await LaneSelfTest.waitUntil(15) {
            store.appliedGeneration == store.generation && store.player.currentItem?.status == .readyToPlay && store.projectURL == project
        }
        try check(opened && installed && store.missingMedia.isEmpty && !InternalImagePreview.containsImages(store.timeline),
                  "opened image-free generated project")
        guard let entry = store.timeline.spectra.first else { throw Failure(check: "image-free Spectrum") }
        let end = store.timeline.durationFrames
        try check(end > 90 && entry.end == end, "image-free Spectrum covers the final frame")
        func image() -> CGImage? {
            guard let content = overlay.layers[entry.id]?.contents, CFGetTypeID(content as CFTypeRef) == CGImage.typeID else { return nil }
            return (content as! CGImage)
        }
        func seek(_ frame: Int) async throws {
            store.seek(to: frame)
            let finished = await LaneSelfTest.waitUntil(8) {
                !host.hasPendingSpectrumSeek && overlay.confirmedFrame == frame && store.playhead == frame && image() != nil
            }
            try check(finished, "image-free paused raster at \(frame)")
        }
        // A frame-less playback tick is a transport edge. It must never show an empty canvas.
        let owner = UUID()
        var framelessTicks = 0, framelessBlank = 0
        // START-FLICKER-FIX-03: every playback tick between Play and the first installed
        // playing raster (start), and from the last three frames or a frame-less tick to the
        // end of playback (end), is checked for an empty canvas, whether or not it has a frame.
        // Ticks only: the gap between the last tick and the paused publication is not a tick.
        enum Window { case idle, start, middle, end }
        var window = Window.idle
        var startTicks = 0, startEmptyTicks = 0, endTicks = 0, endEmptyTicks = 0, forwardRetainedTicks = 0
        var retainedFrom: Int?
        overlay.playbackObservationForTest = (owner, {
            let playing = store.spectrumPreview.playback.currentFrame
            let empty = (host.spectrumCanvas.sublayers ?? []).isEmpty
            if playing == nil {
                framelessTicks += 1
                if empty { framelessBlank += 1 }
            }
            if overlay.transitionRetentionForTest == "start", let playing, let from = retainedFrom, playing > from {
                forwardRetainedTicks += 1
            }
            switch window {
            case .idle: break
            case .start:
                startTicks += 1
                if empty { startEmptyTicks += 1 }
                if playing != nil, overlay.transitionRetentionForTest == nil, !empty { window = .middle }
            case .middle:
                if playing.map({ $0 >= end - 3 }) ?? true { window = .end; endTicks += 1; if empty { endEmptyTicks += 1 } }
            case .end:
                endTicks += 1
                if empty { endEmptyTicks += 1 }
            }
        })
        defer { if overlay.playbackObservationForTest?.owner == owner { overlay.playbackObservationForTest = nil } }

        try await seek(end - 18)
        let paused = image()
        retainedFrom = end - 18
        window = .start
        store.play()
        try check(store.isPlaying && overlay.transitionRetentionForTest == "start" && image() === paused,
                  "start keeps the confirmed paused raster")
        try check(await LaneSelfTest.waitUntil(6) {
            overlay.transitionRetentionForTest == nil && store.spectrumPreview.playback.currentFrame != nil && image() != nil
        }, "first playing raster replaces the retained one")
        let naturalBefore = overlay.retainedNaturalEnds
        let completed = await LaneSelfTest.waitUntil(10) { !store.isPlaying && store.playhead == end }
        try check(completed && overlay.retainedNaturalEnds == naturalBefore + 1 && image() != nil,
                  "natural completion keeps the final raster for its paused publication")
        try check(await LaneSelfTest.waitUntil(8) { overlay.confirmedFrame == end - 1 && image() != nil &&
            overlay.transitionRetentionForTest == nil }, "final paused publication installed without retention state")
        window = .idle
        try check(framelessBlank == 0, "no frame-less playback tick was empty (\(framelessBlank) of \(framelessTicks))")
        print("MEASURE startEmptyTicks=\(startEmptyTicks) startTicks=\(startTicks) endEmptyTicks=\(endEmptyTicks) endTicks=\(endTicks) forwardRetainedTicks=\(forwardRetainedTicks)")
        try check(startTicks > 0 && startEmptyTicks == 0, "no playback tick before the first playing raster was empty (\(startEmptyTicks) of \(startTicks))")
        try check(endEmptyTicks == 0, "no playback tick at the natural end was empty (\(endEmptyTicks) of \(endTicks))")

        try await seek(end - 40)
        store.play()
        try check(overlay.transitionRetentionForTest == "start", "start retention engaged before Pause")
        store.pause()
        try check(!store.isPlaying && overlay.transitionRetentionForTest == nil && overlay.layers.isEmpty,
                  "Pause ends start retention and clears immediately")

        try await seek(end - 60)
        store.play()
        try check(overlay.transitionRetentionForTest == "start", "start retention engaged before Seek")
        store.seek(to: end - 80)
        try check(overlay.transitionRetentionForTest == nil && overlay.layers.isEmpty, "Seek ends start retention and clears immediately")
        store.pause()

        try await seek(end - 50)
        // Same model, new session revision: the installed raster is no longer proven current.
        store.spectrumPreview.update(timeline: store.timeline, media: store.assets)
        store.play()
        try check(store.isPlaying && overlay.transitionRetentionForTest == nil && overlay.layers.isEmpty,
                  "changed session revision cannot be retained at start")
        store.pause()

        try await seek(30)
        store.play()
        let manualBefore = overlay.retainedNaturalEnds
        store.seek(to: end)
        let atEnd = await LaneSelfTest.waitUntil(8) {
            !host.hasPendingSpectrumSeek && store.player.currentTime() == store.settings.time(end) &&
                store.playhead == end && store.player.rate == 0
        }
        try check(atEnd && overlay.retainedNaturalEnds == manualBefore && overlay.transitionRetentionForTest == nil &&
                  overlay.confirmedFrame != end - 1 && overlay.layers.values.allSatisfy { $0.contents == nil },
                  "manual end Seek cannot inherit natural-end retention")
        store.pause()

        // START-FLICKER-FIX-03 (deterministic): hold every playing ready delivery, so the
        // transport advances past the paused frame while its rasters are still pending.
        // The paused raster must stay installed on that later frame until a result arrives.
        let pendingGate = SpectrumOverlaySelfTest.Gate()
        store.spectrumPreview.beforeDeliveryForTest = { result in
            if store.isPlaying, case .ready(_, .some) = result { await pendingGate.wait() }
        }
        defer { pendingGate.release(); store.spectrumPreview.beforeDeliveryForTest = nil }
        let heldStart = end - 70
        try await seek(heldStart)
        let heldPaused = image()
        store.play()
        let advancedWhilePending = await LaneSelfTest.waitUntil(2) {
            store.spectrumPreview.playback.currentFrame.map { $0 > heldStart } == true
        }
        try check(advancedWhilePending && overlay.transitionRetentionForTest == "start" && image() === heldPaused &&
                  !(host.spectrumCanvas.sublayers ?? []).isEmpty,
                  "later playing frame with pending results keeps the paused raster")
        pendingGate.release()
        store.spectrumPreview.beforeDeliveryForTest = nil
        try check(await LaneSelfTest.waitUntil(6) {
            overlay.transitionRetentionForTest == nil && store.spectrumPreview.playback.currentFrame != nil && image() != nil
        }, "released playing raster replaces the retained one")
        store.pause()

        // Playback after a real audio relink: new item and session, then the same start check.
        guard let audioClip = store.timeline.audioClips.first(where: { $0.lineageKey == entry.sourceKey }) else {
            throw Failure(check: "image-free Spectrum audio source")
        }
        let audioID = audioClip.mediaID
        let beforeRelink = store.player.currentItem
        let relinked = await store.relinkMedia(audioID, to: relinkAudio)
        let rebuilt = await LaneSelfTest.waitUntil(12) {
            store.appliedGeneration == store.generation && store.player.currentItem?.status == .readyToPlay &&
                store.player.currentItem !== beforeRelink && !host.hasPendingSpectrumSeek &&
                store.mediaByID[audioID]?.url.standardizedFileURL == relinkAudio.standardizedFileURL
        }
        try check(relinked && rebuilt && store.missingMedia.isEmpty, "image-free audio relinked and item rebuilt")
        try await seek(end - 18)
        let relinkPaused = image()
        startTicks = 0; startEmptyTicks = 0; retainedFrom = end - 18
        window = .start
        store.play()
        try check(store.isPlaying && overlay.transitionRetentionForTest == "start" && image() === relinkPaused,
                  "start after relink keeps the confirmed paused raster")
        try check(await LaneSelfTest.waitUntil(6) {
            overlay.transitionRetentionForTest == nil && store.spectrumPreview.playback.currentFrame != nil && image() != nil
        }, "first playing raster after relink replaces the retained one")
        window = .idle
        store.pause()
        print("MEASURE relinkStartEmptyTicks=\(startEmptyTicks) relinkStartTicks=\(startTicks)")
        try check(startTicks > 0 && startEmptyTicks == 0, "no playback tick after relink before the first raster was empty (\(startEmptyTicks) of \(startTicks))")
    }

    private static func startingFrameChecks(audio: URL, check: (Bool, String) throws -> Void) async throws {
        let copy = audio.deletingLastPathComponent().appendingPathComponent("startup-" + UUID().uuidString + ".wav")
        try Data(contentsOf: audio).write(to: copy, options: .withoutOverwriting)
        let asset = try await MediaProbe.inspect(copy)
        var timeline = try Timeline().registering(asset).placing(media: asset.id, at: 0, videoLane: nil, audioLane: Lane.audioID)
        timeline = try timeline.addingSpectrum(fromAudioClip: timeline.audioClips[0].id, newLaneName: "Spectrum")
        let id = timeline.spectra[0].id, session = SpectrumPreviewSession(), controller = session.playback
        session.update(timeline: timeline, media: [asset])
        let gate = SpectrumOverlaySelfTest.Gate()
        defer { gate.release(); session.transformOutcomeForTest = nil; session.resetProject() }
        func prepare(_ frame: Int) async throws {
            controller.stop()
            controller.prepareStartingFrame(frame, timeline: timeline)
            let ready = await LaneSelfTest.waitUntil(8) { controller.pendingCount == 0 && controller.retainedBytes > 0 }
            try check(ready && controller.currentFrame == nil && controller.currentOutcome(spectrum: id, frame: frame) == nil,
                      "preparation alone cannot authorize a playback image")
        }
        var firstRaster: CGImage?, firstRequests = 0
        session.transformOutcomeForTest = { _, frame, outcome in
            if frame == 20, case let .ready(_, raster?) = outcome {
                firstRaster = raster.image
                firstRequests += 1
            }
            return outcome
        }
        try await prepare(20)
        controller.advance(frame: 20, timeline: timeline)
        let installed = await LaneSelfTest.waitUntil(8) {
            if case let .ready(_, raster?)? = controller.currentOutcome(spectrum: id, frame: 20) {
                return raster.image === firstRaster
            }
            return false
        }
        try check(installed && firstRequests == 1 && controller.metrics.sourceRevalidations > 0,
                  "exact first PTS releases the same revalidated raster without another request")
        session.transformOutcomeForTest = nil
        try await prepare(30)
        controller.advance(frame: 31, timeline: timeline)
        try check(controller.currentOutcome(spectrum: id, frame: 30) == nil && controller.currentOutcome(spectrum: id, frame: 31) == nil,
                  "a different first playback PTS cannot display the prepared image")

        try await prepare(40)
        // Replace the contents of this test's private copy after the first access
        // check. A retained startup raster must pass current source validation.
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        controller.advance(frame: 40, timeline: timeline)
        let rejected = await LaneSelfTest.waitUntil(8) {
            if case .mediaUnavailable(let media)? = controller.currentOutcome(spectrum: id, frame: 40) { return media == asset.id }
            return false
        }
        try check(rejected && controller.metrics.sourceRejections > 0, "matching PTS cannot revive a prepared raster after source replacement")

        session.update(timeline: timeline, media: [asset])
        session.transformOutcomeForTest = { _, frame, result in
            if frame == 50 { await gate.wait() }
            return result
        }
        controller.prepareStartingFrame(50, timeline: timeline)
        try check(await LaneSelfTest.waitUntil(8) { gate.entered }, "startup delivery pending before project reset")
        session.resetProject()
        gate.release()
        let drained = await LaneSelfTest.waitUntil(8) { controller.pendingCount == 0 }
        try check(drained && controller.currentFrame == nil && controller.retainedBytes == 0 &&
                  controller.currentOutcome(spectrum: id, frame: 50) == nil, "late preparation cannot enter a new project")
    }
}
#endif
