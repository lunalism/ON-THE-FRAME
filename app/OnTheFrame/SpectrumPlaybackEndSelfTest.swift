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
            // IMAGE-SPECTRUM-FLICKER-FIX-01: image compositions retain the start frame only while the
            // image lease is valid at Play; otherwise they clear as before (fail closed).
            try await seek(30)
            try check(await LaneSelfTest.waitUntil(8) { installedImage() != nil }, "image-backed paused raster before start")
            let leaseValidAtPlay = store.player.currentItem.map { store.imageAccessIsValidNow(for: $0) } ?? false
            store.play()
            if leaseValidAtPlay {
                try check(store.isPlaying && overlay.transitionRetentionForTest == "start" && !blank(),
                          "image-backed start with a valid lease retains the paused raster")
            } else {
                try check(store.isPlaying && overlay.transitionRetentionForTest == nil && blank(),
                          "image-backed start without a valid lease clears at Play")
            }
            store.pause()
            try check(overlay.transitionRetentionForTest == nil || overlay.transitionRetentionForTest == "pause",
                      "Pause ends any start retention of the image-backed playback")
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

/// Per-tick rows for the image access checks (every tick, no capacity limit).
@MainActor final class ImageRetentionTicks {
    var section = "idle"
    var t0 = CACurrentMediaTime()
    var rows: [[String: Any]] = []
    func sectionRows(_ section: String) -> [[String: Any]] { rows.filter { $0["section"] as? String == section } }
    func empty(_ section: String, where keep: ([String: Any]) -> Bool = { _ in true }) -> (empty: Int, ticks: Int) {
        let r = sectionRows(section).filter(keep)
        return (r.filter { $0["empty"] as? Bool == true }.count, r.count)
    }
}

extension SpectrumPlaybackEndSelfTest {
    /// IMAGE-SPECTRUM-FLICKER-FIX-01: still-image + audio project built through the app's import, "+",
    /// trim and Debug "add Spectrum" paths (600 frames, image covers the whole project). Exercises paused
    /// renewal, start/end retention only under a valid lease, negative startup time, failure, late results,
    /// Seek, Pause, relink and project replacement. Each check is recorded; later sections still run.
    static func imageAccessRetentionChecks(png: URL, wav: URL, relinkPNG: URL, ticks: ImageRetentionTicks) async -> [LaneSelfTest.Check] {
        var checks: [LaneSelfTest.Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            print(pass ? "PASS" : "FAIL", "[image]", name, detail.isEmpty ? "" : "(\(detail))")
            checks.append(LaneSelfTest.Check(name: name, pass: pass, detail: detail))
        }
        let store = ProjectStore.shared
        guard ProjectStore.imageImportEnabled, let host = store.previewHost else {
            check("image import enabled and editor attached", false); return checks
        }
        let overlay = host.spectrumOverlay
        let owner = UUID()
        overlay.windowActiveOverrideForTest = true
        defer {
            overlay.windowActiveOverrideForTest = nil
            store.imagePlaybackAccessPreparedForTest = nil
            store.persistenceScopeStartForTest = nil; store.persistenceScopeStopForTest = nil
            if overlay.playbackObservationForTest?.owner == owner { overlay.playbackObservationForTest = nil }
        }
        func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool { await LaneSelfTest.waitUntil(seconds, cond) }
        func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func canvasEmpty() -> Bool { (host.spectrumCanvas.sublayers ?? []).isEmpty }
        func valid() -> Bool { store.player.currentItem.map { store.imageAccessIsValidNow(for: $0) } ?? false }

        // Setup through the owner's workflow.
        store.importFiles([png, wav])
        let imported = await wait(90) {
            store.importProgress == nil && !store.imageImportBusy &&
                ProjectPersistence.references(store.timeline).contains { $0.kind == .stillImage } &&
                store.timeline.media.contains { $0.hasAudio && !$0.hasVideo }
        }
        guard imported, let imageID = ProjectPersistence.references(store.timeline).first(where: { $0.kind == .stillImage })?.id,
              let audioID = store.timeline.media.first(where: { $0.hasAudio && !$0.hasVideo })?.id else {
            check("imported PNG and WAV copies", false); return checks
        }
        store.addToTimeline(imageID); store.addToTimeline(audioID)
        guard await wait(10, { !store.timeline.clips.isEmpty && !store.timeline.audioClips.isEmpty }),
              let imageClip = store.timeline.clips.first, let audioClip = store.timeline.audioClips.first else {
            check("placed image and audio with +", false); return checks
        }
        let length = 600
        store.commit({ try $0.trimming(clip: audioClip.id, sourceIn: 0, length: length) }, focus: nil)
        store.commit({ try $0.resizingStillImage(clip: imageClip.id, length: length) }, focus: nil)
        store.addSpectrum(fromAudioClip: audioClip.id, session: store.projectSession)
        let built = await wait(30) {
            guard let item = store.player.currentItem, store.timeline.spectra.count == 1 else { return false }
            return store.appliedGeneration == store.generation && item.status == .readyToPlay &&
                store.imagePreviewEligibility(for: item, session: store.projectSession, generation: store.generation) == .validatedAtInstallation
        }
        guard built, let entry = store.timeline.spectra.first else { check("built 600-frame image + audio Spectrum project", false); return checks }
        let covered = store.timeline.durationFrames == length && store.timeline.clips.count == 1 &&
            store.timeline.clips[0].start == 0 && store.timeline.clips[0].length == length && entry.start == 0 && entry.end == length
        check("built 600-frame image + audio Spectrum project (image covers the end)", covered,
              "duration \(store.timeline.durationFrames), spectrum \(entry.start)..<\(entry.end)")
        func image() -> Bool {
            guard let c = overlay.layers[entry.id]?.contents else { return false }
            return CFGetTypeID(c as CFTypeRef) == CGImage.typeID
        }
        func seekPaused(_ frame: Int) async -> Bool {
            store.seek(to: frame)
            return await wait(10) { !host.hasPendingSpectrumSeek && overlay.confirmedFrame == frame && store.playhead == frame && image() }
        }
        overlay.playbackObservationForTest = (owner, {
            let lease = store.imagePlaybackLeaseForTest, now = store.player.currentTime()
            ticks.rows.append([
                "section": ticks.section, "t": CACurrentMediaTime() - ticks.t0,
                "frame": store.spectrumPreview.playback.currentFrame ?? -1, "itemSeconds": now.isNumeric ? now.seconds : -1,
                "empty": canvasEmpty(), "retention": overlay.transitionRetentionForTest ?? "none",
                "leaseValid": valid(), "leasePending": lease.pending, "leaseUntil": lease.until,
                "uptime": ProcessInfo.processInfo.systemUptime,
                "startupReuses": store.spectrumPreview.playback.timing.startupRegressionReusesForTest,
                "suspensions": store.spectrumPreview.playback.metrics.suspensions,
                "retainedTransitionTicks": overlay.retainedTransitionTicks,
            ])
        })
        func begin(_ section: String) { ticks.section = section; ticks.t0 = CACurrentMediaTime() }

        // 1. Paused renewal in an active window.
        let atRest = await seekPaused(60)
        let renewing = await wait(5) { valid() && overlay.pausedAccessRenewalScheduledForTest }
        check("paused visible image Spectrum acquires access and schedules renewal", atRest && renewing)
        let checks0 = store.imagePlaybackAccessChecksForTest
        await sleep(2.5)
        let renewed = store.imagePlaybackAccessChecksForTest - checks0
        check("paused 2.5 s: lease renewed before expiry and still valid", valid() && renewed >= 2 && image(), "renewal checks +\(renewed)")

        // 2. Inactive window: no renewal; the lease expires; the paused drawing follows existing policy.
        overlay.windowActiveOverrideForTest = false; overlay.updatePausedAccessRenewal()
        let stopped = !overlay.pausedAccessRenewalScheduledForTest
        await sleep(0.3)
        let inactiveChecks = store.imagePlaybackAccessChecksForTest
        await sleep(1.2)
        check("inactive window stops renewal and the lease expires", stopped && !valid() &&
              store.imagePlaybackAccessChecksForTest == inactiveChecks && !overlay.pausedAccessRenewalScheduledForTest)

        // 3. Expired lease forbids start retention (fail closed), then recovers by fresh validation.
        let retainedBefore = overlay.retainedTransitionTicks
        begin("expiredStart")
        store.play()
        let clearedAtPlay = overlay.transitionRetentionForTest == nil && canvasEmpty()
        let recovered = await wait(5) { !canvasEmpty() && store.spectrumPreview.playback.currentFrame != nil }
        store.pause()
        check("expired lease forbids start retention (cleared at Play)", clearedAtPlay && overlay.retainedTransitionTicks == retainedBefore)
        check("expired-lease start recovers after fresh validation", recovered)
        _ = await wait(5) { !host.hasPendingSpectrumSeek }

        // 4. Reactivation reacquires; staying paused longer than the lease keeps it valid.
        let paused120 = await seekPaused(120)
        await sleep(1.2)
        let expiredWhileInactive = !valid()
        overlay.windowActiveOverrideForTest = true; overlay.updatePausedAccessRenewal()
        let reacquired = await wait(3) { valid() && overlay.pausedAccessRenewalScheduledForTest }
        check("reactivated window reacquires access", paused120 && expiredWhileInactive && reacquired)
        await sleep(1.5)
        let warmValid = valid()
        begin("warmStart")
        let warmBefore = overlay.retainedTransitionTicks
        store.play()
        let retainedAtPlay = overlay.transitionRetentionForTest == "start" && !canvasEmpty()
        _ = await wait(4) { store.player.currentTime().seconds >= 5.0 }
        store.pause()
        let warm = ticks.empty("warmStart")
        check("paused >1 s then Play keeps the start presentation (valid lease)", warmValid && retainedAtPlay && warm.empty == 0,
              "empty \(warm.empty)/\(warm.ticks), retained ticks +\(overlay.retainedTransitionTicks - warmBefore)")
        _ = await wait(5) { !host.hasPendingSpectrumSeek }

        // 5. Continuous 0 → natural end: negative startup time, mid-playback renewals, end retention.
        let atZero = await seekPaused(0)
        let zeroValid = await wait(3) { valid() }
        let reuses0 = store.spectrumPreview.playback.timing.startupRegressionReusesForTest
        let ends0 = overlay.retainedNaturalEnds
        begin("continuous")
        store.play()
        let ended = await wait(40) { !store.isPlaying && store.playhead == length }
        let visibleAtEnd = !canvasEmpty()
        let finalShown = await wait(5) { overlay.confirmedFrame == length - 1 && image() }
        let endTime = Double(length) / 30
        let startW = ticks.empty("continuous") { ($0["t"] as? Double ?? 9) <= 0.5 }
        let midW = ticks.empty("continuous") { ($0["t"] as? Double ?? 0) > 0.5 && ($0["itemSeconds"] as? Double ?? 0) < endTime - 0.2 }
        let endW = ticks.empty("continuous") { ($0["itemSeconds"] as? Double ?? 0) >= endTime - 0.2 }
        let reuses = store.spectrumPreview.playback.timing.startupRegressionReusesForTest - reuses0
        check("negative startup time with valid image access: no empty tick in the first 0.5 s", atZero && zeroValid && startW.empty == 0 && startW.ticks > 0,
              "empty \(startW.empty)/\(startW.ticks), startup reuses +\(reuses)")
        check("mid-playback continuity across lease renewals: no empty tick", midW.empty == 0 && midW.ticks > 0, "empty \(midW.empty)/\(midW.ticks)")
        check("natural end with valid access retains the final presentation", ended && endW.empty == 0 && visibleAtEnd &&
              overlay.retainedNaturalEnds == ends0 + 1 && finalShown,
              "end-window empty \(endW.empty)/\(endW.ticks), retained ends +\(overlay.retainedNaturalEnds - ends0), visibleAtEnd \(visibleAtEnd)")

        // 6. Seek and Pause end start retention at once.
        _ = await seekPaused(150); _ = await wait(3) { valid() }
        store.play()
        let seekRetained = overlay.transitionRetentionForTest == "start"
        store.seek(to: 300)
        let seekEnded = await wait(0.2) { overlay.transitionRetentionForTest == nil }
        store.pause(); _ = await wait(5) { !host.hasPendingSpectrumSeek }
        check("Seek during start retention ends it", seekRetained && seekEnded)
        _ = await seekPaused(150); _ = await wait(3) { valid() }
        store.play()
        let pauseRetained = overlay.transitionRetentionForTest == "start"
        store.pause()
        check("Pause during start retention ends it", pauseRetained && overlay.transitionRetentionForTest == nil)
        _ = await wait(5) { !host.hasPendingSpectrumSeek }

        // 6b. Manual Pause (PAUSE-FLICKER-FIX-01).
        checks += await pauseRetentionChecks(entry: entry, imageID: imageID, startFrame: 60)

        // 7. Relink: old item access is revoked and its drawing cleared; renewal resumes on the new item.
        _ = await seekPaused(60); _ = await wait(3) { valid() }
        let oldItem = store.player.currentItem
        store.persistenceScopeStartForTest = { _ in true }; store.persistenceScopeStopForTest = { _ in }
        let linked = await store.relinkStillImage(imageID, to: relinkPNG)
        store.persistenceScopeStartForTest = nil; store.persistenceScopeStopForTest = nil
        let oldRevoked = oldItem.map { !store.imageAccessIsValidNow(for: $0) } ?? false
        let newItem = await wait(15) {
            guard let item = store.player.currentItem, item !== oldItem else { return false }
            return store.imagePreviewEligibility(for: item, session: store.projectSession, generation: store.generation) == .validatedAtInstallation
        }
        var relinkedPaused = false
        if newItem { relinkedPaused = await seekPaused(60) }
        let relinkedRenewal = await wait(3) { valid() && overlay.pausedAccessRenewalScheduledForTest }
        check("relink revokes old access and resumes renewal on the new item", linked && oldRevoked && newItem && relinkedPaused && relinkedRenewal,
              "linked \(linked), oldRevoked \(oldRevoked), newItem \(newItem)")

        // 8. Confirmed failure while paused clears the drawing and stops renewal; nothing stale returns.
        if let ref = ProjectPersistence.references(store.timeline).first(where: { $0.kind == .stillImage }) {
            let source = URL(fileURLWithPath: ref.path), moved = source.deletingLastPathComponent().appendingPathComponent("moved-\(source.lastPathComponent)")
            do {
                try FileManager.default.moveItem(at: source, to: moved)
                let cleared = await wait(3) { overlay.layers.isEmpty && canvasEmpty() }
                await sleep(0.5)
                check("confirmed access failure clears the paused presentation and stops renewal", cleared && canvasEmpty() && !valid() &&
                      !overlay.pausedAccessRenewalScheduledForTest)
                try FileManager.default.moveItem(at: moved, to: source)
                let back = await seekPaused(60)
                let recoveredAccess = await wait(3) { valid() }
                check("restored source is freshly validated before renewal resumes", back && recoveredAccess)
            } catch { check("confirmed access failure setup", false, "\(error)") }
        } else { check("confirmed access failure setup", false, "no image reference") }

        // 9. Late validation results never restore an invalidated presentation (generation change).
        var release: CheckedContinuation<Void, Never>?
        store.imagePlaybackAccessPreparedForTest = { await withCheckedContinuation { release = $0 } }
        let blocked = await wait(3) { release != nil }   // the next paused renewal blocks before publication
        let staleBefore = store.imagePlaybackAccessStaleForTest
        let lateItem = store.player.currentItem
        store.timelineChanged()
        let invalidatedCleared = canvasEmpty() && !overlay.pausedAccessRenewalScheduledForTest
        release?.resume(); release = nil
        store.imagePlaybackAccessPreparedForTest = nil
        let rejected = await wait(3) { store.imagePlaybackAccessStaleForTest > staleBefore }
        await sleep(0.2)
        let oldNotRevived = lateItem.map { !store.imageAccessIsValidNow(for: $0) } ?? false
        check("late validation after invalidation is rejected and restores nothing", blocked && invalidatedCleared && rejected && oldNotRevived,
              "blocked \(blocked), cleared \(invalidatedCleared), rejected \(rejected), oldItemNotRevived \(oldNotRevived)")

        // 10. Revocation (source availability withdrawn) while paused and valid clears at once.
        _ = await wait(15) {
            guard let item = store.player.currentItem else { return false }
            return store.appliedGeneration == store.generation &&
                store.imagePreviewEligibility(for: item, session: store.projectSession, generation: store.generation) == .validatedAtInstallation
        }
        let revokeReady = await seekPaused(60)
        let revokeValid = await wait(3) { valid() }
        store.applyImageAvailability(false, id: imageID, snapshot: store.timeline, session: store.projectSession, generation: store.generation)
        let revokedNow = canvasEmpty() && !valid() && !overlay.pausedAccessRenewalScheduledForTest
        await sleep(1.0)
        check("revocation clears the presentation immediately and it stays cleared", revokeReady && revokeValid && revokedNow && canvasEmpty() && !valid())

        // 11. Project replacement leaves no renewal or drawing.
        store.resetProject()
        let replaced = await wait(5) { canvasEmpty() && !overlay.pausedAccessRenewalScheduledForTest && store.timeline.isEmpty }
        check("project replacement leaves no renewal or Spectrum drawing", replaced)
        return checks
    }

    /// PAUSE-FLICKER-FIX-01: manual Pause through the Space action (`togglePlay`) on the open project
    /// with one visible Spectrum `entry`, paused at `startFrame` with at least ~8 s of playable range
    /// after it. Model-layer evidence: the canvas is polled every millisecond from the Pause until the
    /// Pause frame's own paused raster is installed. `imageID` enables the image-lease cases.
    /// One row per Pause performed by `pauseRetentionChecks` (read by validation harnesses).
    static var pauseMeasurements: [[String: Any]] = []

    static func pauseRetentionChecks(entry: SpectrumItem, imageID: UUID?, startFrame: Int) async -> [LaneSelfTest.Check] {
        var checks: [LaneSelfTest.Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            print(pass ? "PASS" : "FAIL", "[pause]", name, detail.isEmpty ? "" : "(\(detail))")
            checks.append(LaneSelfTest.Check(name: name, pass: pass, detail: detail))
        }
        let store = ProjectStore.shared
        guard let host = store.previewHost else { check("editor attached", false); return checks }
        let overlay = host.spectrumOverlay
        let image = imageID != nil
        defer { store.pauseOfferFrameForTest = nil; store.spectrumPreview.beforeDeliveryForTest = nil; store.imagePlaybackAccessClockForTest = nil }
        func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool { await LaneSelfTest.waitUntil(seconds, cond) }
        func shown() -> Bool {
            guard !(host.spectrumCanvas.sublayers ?? []).isEmpty, let c = overlay.layers[entry.id]?.contents else { return false }
            return CFGetTypeID(c as CFTypeRef) == CGImage.typeID
        }
        func valid() -> Bool { store.player.currentItem.map { store.imageAccessIsValidNow(for: $0) } ?? false }
        func installedAtPlayhead() -> Bool {
            !store.isPlaying && !host.hasPendingSpectrumSeek && overlay.confirmedFrame == store.playhead &&
                overlay.transitionRetentionForTest == nil && shown()
        }
        func seekPaused(_ frame: Int) async -> Bool {
            store.seek(to: frame)
            let paused = await wait(10) { !host.hasPendingSpectrumSeek && overlay.confirmedFrame == frame && shown() }
            guard paused, image else { return paused }
            return await wait(3) { valid() }
        }
        /// Plays, waits until the displayed Spectrum frame equals the frame containing the player time
        /// (so a Pause now targets the displayed frame), up to `limit` seconds.
        func playUntilAligned(minimum: Double, limit: Double = 3) async -> Bool {
            store.togglePlay()
            let start = Date()
            _ = await wait(minimum + 1) { Date().timeIntervalSince(start) >= minimum && overlay.presentedFrameForTest != nil }
            return await wait(limit) {
                guard let shownFrame = overlay.presentedFrameForTest else { return false }
                return shownFrame == store.settings.frame(containing: store.player.currentTime())
            }
        }
        struct Measured {
            var retained = false, mismatch = false, declined = false; var empty = 0, polls = 0; var installed = false; var target = -1
            var displayed = -1, emptyMs = 0.0, emptyIntervals = 0, installMs = -1.0
        }
        var section = "A.aligned"
        /// Space Pause, then poll the canvas until the Pause frame's own raster is installed.
        /// Every Pause is also recorded in `pauseMeasurements` (displayed vs Pause frame, outcome, gaps).
        func pauseAndMeasure(then follow: (() -> Void)? = nil) async -> Measured {
            var m = Measured()
            let r0 = overlay.pauseRetentions, mm0 = overlay.pauseFrameMismatches, d0 = overlay.pauseRetentionsDeclined
            let timeouts0 = overlay.pauseRetentionTimeouts
            m.displayed = overlay.presentedFrameForTest ?? -1
            let t0 = CACurrentMediaTime()
            store.togglePlay()
            m.target = store.playhead
            m.retained = overlay.pauseRetentions > r0; m.mismatch = overlay.pauseFrameMismatches > mm0
            m.declined = overlay.pauseRetentionsDeclined > d0
            follow?()
            if follow == nil {
                let end = Date().addingTimeInterval(3)
                var last = CACurrentMediaTime(), wasEmpty = false
                while Date() < end {
                    let now = CACurrentMediaTime(), empty = !shown()
                    m.polls += 1
                    if empty { m.empty += 1; if !wasEmpty { m.emptyIntervals += 1 } }
                    if wasEmpty { m.emptyMs += (now - last) * 1000 }
                    wasEmpty = empty; last = now
                    if installedAtPlayhead() { m.installed = true; m.installMs = (now - t0) * 1000; break }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            pauseMeasurements.append([
                "section": section, "displayedFrame": m.displayed, "pauseFrame": m.target,
                "outcome": m.retained ? "retained" : (m.mismatch ? "mismatch" : (m.declined ? "declined" : "other")),
                "measured": follow == nil, "emptyPolls": m.empty, "polls": m.polls, "emptyMs": m.emptyMs,
                "emptyIntervals": m.emptyIntervals, "installMs": m.installMs, "installed": m.installed,
                "timeoutsDuring": overlay.pauseRetentionTimeouts - timeouts0, "image": image,
            ])
            return m
        }

        // A. Space Pause with matching frames: no empty canvas, own frame installed, playhead exact.
        var cycles: [Measured] = []
        _ = await seekPaused(startFrame)
        for _ in 0..<5 {
            guard await playUntilAligned(minimum: 0.4) else { store.togglePlay(); continue }
            cycles.append(await pauseAndMeasure())
            _ = await wait(3) { image ? valid() : true }
        }
        let retainedCycles = cycles.filter(\.retained)
        let detailA = cycles.map { "r\($0.retained ? 1 : 0)m\($0.mismatch ? 1 : 0) e\($0.empty)/\($0.polls) f\($0.target)" }.joined(separator: ", ")
        check("Space Pause with matching frames keeps the Spectrum until its own paused raster", !retainedCycles.isEmpty &&
              retainedCycles.allSatisfy { $0.empty == 0 && $0.installed }, detailA)
        check("every Pause installs the exact Pause frame (playhead unchanged by retention)",
              !cycles.isEmpty && cycles.allSatisfy(\.installed), detailA)
        check("non-matching Pauses clear instead of showing another frame", cycles.filter(\.mismatch).allSatisfy { $0.empty > 0 && $0.installed },
              "mismatches \(cycles.filter(\.mismatch).count)")

        _ = await seekPaused(startFrame)
        section = "B.forcedMismatch"
        // B. Forced mismatch (offer only; the playhead stays the exact Pause frame).
        if await playUntilAligned(minimum: 0.3) {
            store.pauseOfferFrameForTest = { $0 + 1 }
            let m = await pauseAndMeasure()
            store.pauseOfferFrameForTest = nil
            check("Pause with a mismatched frame clears at once and installs the exact Pause frame",
                  m.mismatch && !m.retained && m.empty > 0 && m.installed && overlay.confirmedFrame == m.target, "e\(m.empty)/\(m.polls) f\(m.target)")
        } else { store.togglePlay(); check("Pause with a mismatched frame (setup)", false, "not aligned") }

        _ = await seekPaused(startFrame)
        section = "C.pauseThenSeek"
        // C. Pause-owned seek versus an ordinary Seek issued immediately after the Pause.
        if await playUntilAligned(minimum: 0.3) {
            var seekCleared = false, retained = false
            let target = store.playhead + 45
            _ = await pauseAndMeasure {
                retained = overlay.transitionRetentionForTest == "pause"
                store.seek(to: target)
                seekCleared = overlay.transitionRetentionForTest == nil && overlay.pauseHoldTokenForTest == nil &&
                    !(overlay.layers.values.contains { $0.contents != nil })
            }
            let landed = await wait(5) { installedAtPlayhead() && store.playhead == target }
            check("ordinary Seek right after Pause ends the Pause hold and clears", retained && seekCleared && landed,
                  "retained \(retained), cleared \(seekCleared), landed \(landed)")
        } else { store.togglePlay(); check("Pause then Seek (setup)", false, "not aligned") }

        _ = await seekPaused(startFrame)
        section = "D.pauseThenPlay"
        // D. Pause immediately followed by Play: the hold ends; playback resumes normally.
        if await playUntilAligned(minimum: 0.3) {
            var held = false, ended = false
            _ = await pauseAndMeasure {
                held = overlay.transitionRetentionForTest == "pause"
                store.togglePlay()
                ended = overlay.pauseHoldTokenForTest == nil && overlay.transitionRetentionForTest != "pause"
            }
            let resumed = await wait(4) { store.isPlaying && store.spectrumPreview.playback.currentFrame != nil && shown() }
            let m = await pauseAndMeasure()
            check("Play right after Pause ends the hold and resumes", held && ended && resumed && m.installed,
                  "held \(held), ended \(ended), resumed \(resumed)")
        } else { store.togglePlay(); check("Pause then Play (setup)", false, "not aligned") }

        _ = await seekPaused(startFrame)
        section = "E.repeatedUnaligned"
        // E. Repeated Play/Pause (not aligned): the natural match rate; each Pause lands on its own frame.
        var repeated: [Measured] = []
        for _ in 0..<10 {
            store.togglePlay()
            _ = await wait(1) { false }   // ~0.3–1 s of playback, not aligned on purpose
            repeated.append(await pauseAndMeasure())
        }
        check("repeated Play/Pause: every Pause installs its own frame; retained Pauses stay drawn",
              repeated.allSatisfy(\.installed) && repeated.filter(\.retained).allSatisfy { $0.empty == 0 },
              repeated.map { "r\($0.retained ? 1 : 0) e\($0.empty)" }.joined(separator: ", "))

        _ = await seekPaused(startFrame)
        section = "F.timeout"
        // F. Timeout: a paused result held past the bound leaves no retained raster.
        if await playUntilAligned(minimum: 0.3) {
            let gate = SpectrumOverlaySelfTest.Gate()
            store.spectrumPreview.beforeDeliveryForTest = { _ in if !store.isPlaying { await gate.wait() } }
            let t0 = overlay.pauseRetentionTimeouts
            var held = false
            _ = await pauseAndMeasure { held = overlay.transitionRetentionForTest == "pause" }
            let timedOut = await wait(PausedSpectrumOverlay.pauseHoldLimit + 0.5) { overlay.pauseRetentionTimeouts > t0 }
            let noStale = overlay.pauseHoldTokenForTest == nil && !(overlay.layers.values.contains { $0.contents != nil })
            gate.release()
            store.spectrumPreview.beforeDeliveryForTest = nil
            let installed = await wait(5) { installedAtPlayhead() }
            check("timeout leaves no stale retained raster; the paused raster installs after release",
                  held && timedOut && noStale && installed, "held \(held), timedOut \(timedOut), noStale \(noStale), installed \(installed)")
        } else { store.togglePlay(); check("timeout (setup)", false, "not aligned") }

        _ = await seekPaused(startFrame)
        section = "G.invalidation"
        // G. Source and session invalidation during the hold clear at once.
        if await playUntilAligned(minimum: 0.3) {
            var held = false, cleared = false
            _ = await pauseAndMeasure {
                held = overlay.transitionRetentionForTest == "pause"
                store.refreshAssets(refreshSpectrum: false)
                cleared = overlay.pauseHoldTokenForTest == nil && overlay.transitionRetentionForTest == nil &&
                    !(overlay.layers.values.contains { $0.contents != nil })
            }
            check("source invalidation during the Pause hold clears at once", held && cleared, "held \(held), cleared \(cleared)")
            _ = await wait(5) { !host.hasPendingSpectrumSeek }
        } else { store.togglePlay(); check("source invalidation (setup)", false, "not aligned") }
        _ = await seekPaused(startFrame)
        if await playUntilAligned(minimum: 0.3) {
            var held = false, cleared = false
            _ = await pauseAndMeasure {
                held = overlay.transitionRetentionForTest == "pause"
                store.timelineChanged()
                cleared = overlay.pauseHoldTokenForTest == nil && overlay.transitionRetentionForTest == nil &&
                    !(host.spectrumCanvas.sublayers ?? []).contains { $0.contents != nil }
            }
            check("session invalidation (rebuild) during the Pause hold clears at once", held && cleared, "held \(held), cleared \(cleared)")
            _ = await wait(15) {
                guard let item = store.player.currentItem else { return false }
                return store.appliedGeneration == store.generation && item.status == .readyToPlay && !host.hasPendingSpectrumSeek
            }
        } else { store.togglePlay(); check("session invalidation (setup)", false, "not aligned") }

        section = "H.imageLease"
        // H. Image lease: expired lease forbids the hold; the hold never outlives the lease;
        // a validation failure during the hold clears it.
        if image, let imageID {
            _ = await seekPaused(startFrame)
            if await playUntilAligned(minimum: 0.3) {
                store.imagePlaybackAccessClockForTest = store.imagePlaybackLeaseForTest.until + 0.01
                let m = await pauseAndMeasure { }
                store.imagePlaybackAccessClockForTest = nil
                let cleared = !(overlay.layers.values.contains { $0.contents != nil })
                _ = await wait(5) { installedAtPlayhead() }
                check("expired image lease forbids the Pause hold", m.declined && !m.retained && cleared, "declined \(m.declined), cleared \(cleared)")
            } else { store.togglePlay(); check("expired lease (setup)", false, "not aligned") }
            _ = await seekPaused(startFrame)
            if await playUntilAligned(minimum: 0.3) {
                store.imagePlaybackAccessClockForTest = store.imagePlaybackLeaseForTest.until - 0.05
                var remaining: CFTimeInterval = 9
                _ = await pauseAndMeasure { remaining = overlay.pauseHoldRemainingForTest ?? 9 }
                store.imagePlaybackAccessClockForTest = nil
                _ = await wait(5) { installedAtPlayhead() }
                check("the Pause hold never outlives the image lease", remaining <= 0.06, String(format: "remaining %.3f s", remaining))
            } else { store.togglePlay(); check("lease cap (setup)", false, "not aligned") }
            _ = await seekPaused(startFrame)
            if let ref = ProjectPersistence.references(store.timeline).first(where: { $0.id == imageID }), await playUntilAligned(minimum: 0.3) {
                let source = URL(fileURLWithPath: ref.path), moved = source.deletingLastPathComponent().appendingPathComponent("pause-moved-\(source.lastPathComponent)")
                let until = store.imagePlaybackLeaseForTest.until
                store.imagePlaybackAccessClockForTest = max(until - 0.2, store.imagePlaybackLeaseForTest.retry)
                var held = false
                let t0 = overlay.pauseRetentionTimeouts
                _ = await pauseAndMeasure { held = overlay.transitionRetentionForTest == "pause" }
                var cleared = false
                do {
                    try FileManager.default.moveItem(at: source, to: moved)
                    if let item = store.player.currentItem { _ = store.imagePlaybackAccessIsCurrent(for: item, allowProactiveRenewal: true) }
                    cleared = await wait(1) { store.imagePlaybackLeaseForTest.until == 0 && !(overlay.layers.values.contains { $0.contents != nil }) }
                    try FileManager.default.moveItem(at: moved, to: source)
                } catch { check("validation failure (file move)", false, "\(error)") }
                store.imagePlaybackAccessClockForTest = nil
                check("validation failure during the Pause hold clears it (before any timeout)", held && cleared && overlay.pauseRetentionTimeouts == t0,
                      "held \(held), cleared \(cleared)")
                _ = await wait(5) { !host.hasPendingSpectrumSeek }
                _ = await wait(2) { false }
                _ = await seekPaused(startFrame)
            } else { store.togglePlay(); check("validation failure (setup)", false, "not aligned or no reference") }
        }
        return checks
    }
}
#endif
