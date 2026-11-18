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
        try await startingFrameChecks(audio: relink, check: check)
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
