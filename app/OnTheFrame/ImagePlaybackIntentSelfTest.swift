#if DEBUG
import AppKit
import AVFoundation
@testable import OnTheFrameEngine

/// Real plans/items and exact seeks, gated only at replacement boundaries.
/// The caller supplies a disposable Format 10 template and fresh output folder.
@MainActor enum ImagePlaybackIntentSelfTest {
    typealias Check = LaneSelfTest.Check
    private struct Failure: Error { let message: String }
    @MainActor private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    @MainActor private final class Context {
        let store = ProjectStore()
        let view = PlayerNSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        let window: NSWindow
        init() {
            window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            window.title = "PREVIEW-IMAGE-01B isolated regression"
            store.player.isMuted = true; view.playerLayer.player = store.player; store.previewHost = view
            window.orderFront(nil)
        }
        func close() {
            store.imagePreviewPreparedForTest = nil; store.imagePreviewSeekCompletedForTest = nil
            store.imageSourceValidatedForTest = nil
            view.spectrumOverlay.playbackObservationForTest = nil
            store.pause(); store.previewHost = nil; store.resetProject(); window.close()
        }
        func ready() -> Bool {
            store.generation == store.appliedGeneration && !view.hasPendingSpectrumSeek &&
                store.imagePreviewEligibility(for: store.player.currentItem, session: store.projectSession,
                                              generation: store.generation) == .validatedAtInstallation
        }
        func edit(_ scale: Double = 1.125) throws {
            guard let clip = store.timeline.clips.first else { throw Failure(message: "image clip missing") }
            store.select(clip.id); store.setTransform(clip.id, ClipTransform(scale: scale, x: 32, y: 16))
        }
    }
    private static func wait(_ name: String, _ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 10
        while !predicate(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 5_000_000) }
        guard predicate() else { throw Failure(message: "timeout: " + name) }
    }

    /// No owner store, native panels, global input, project saves or export.
    /// Original media is read-only; the failure case moves only its own image copy.
    static func run(template: URL, folder: URL) async -> [Check] {
        var checks = [Check](), evidence = [[String: Any]]()
        func check(_ name: String, _ value: Bool, _ detail: String = "") {
            checks.append(Check(name: name, pass: value, detail: detail))
        }
        let shared = ProjectStore.shared
        guard EditorLayout.shared.suiteName != nil, ProjectStore.imageImportEnabled,
              shared.projectURL == nil, shared.timeline.isEmpty, !shared.isDirty,
              !FileManager.default.fileExists(atPath: folder.path) else {
            check("isolated invocation", false, "requires fresh output/suite and empty shared application session")
            return checks
        }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        catch { check("output creation", false, String(describing: error)); return checks }

        let scenarios = ["play", "pause", "duplicate", "toggle-even", "toggle-odd", "pause-play",
            "new-generation-clears-old", "new-generation-keeps-new", "project-switch", "project-reset",
            "item-replacement", "exact-seek-play", "exact-seek-pause", "seek-token-replaced",
            "source-proof-invalidated", "source-failure", "project-close", "space"]
        for scenario in scenarios {
            let x = Context(), gate = Gate(), s = x.store
            defer { gate.release(); x.close() }
            do {
                let project = folder.appendingPathComponent(scenario + ".ontheframe")
                var fixtureImage: URL?
                if scenario == "source-failure" {
                    var document = try JSONSerialization.jsonObject(with: Data(contentsOf: template)) as! [String: Any]
                    var media = document["media"] as! [[String: Any]]
                    guard let index = media.firstIndex(where: { ($0["ref"] as? [String: Any])?["kind"] as? String == "stillImage" }) else {
                        throw Failure(message: "image reference missing")
                    }
                    var reference = media[index]["ref"] as! [String: Any]
                    let original = URL(fileURLWithPath: reference["path"] as! String)
                    let copy = folder.appendingPathComponent("failure-owned-image.jpg")
                    try FileManager.default.copyItem(at: original, to: copy)
                    reference["path"] = copy.path; reference.removeValue(forKey: "bookmark"); reference.removeValue(forKey: "relativePath")
                    media[index]["ref"] = reference; document["media"] = media
                    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: project, options: .withoutOverwriting)
                    fixtureImage = copy
                } else { try FileManager.default.copyItem(at: template, to: project) }
                guard await s.openProject(at: project) else { throw Failure(message: "copied project open failed") }
                try await wait("baseline image installed") { x.ready() }
                s.seek(to: 118)
                try await wait("baseline exact seek") { x.ready() }
                let applications = s.imagePlayIntentApplicationsForTest, session = s.projectSession

                if scenario == "source-failure" {
                    guard let image = fixtureImage, image.path.hasPrefix(folder.path + "/") else {
                        throw Failure(message: "failure fixture ownership")
                    }
                    try FileManager.default.moveItem(at: image, to: folder.appendingPathComponent("failure-owned-image-moved.jpg"))
                    try x.edit(); s.play()
                    check(scenario + ".intent accepted", s.imagePlayIntentPendingForTest && !s.isPlaying)
                    try await wait("failed reconstruction retires intent") { s.imagePreviewError != nil && !s.imagePlayIntentPendingForTest }
                    check(scenario + ".does not start", !s.isPlaying && s.player.rate == 0 && s.player.currentItem == nil &&
                          s.imagePlayIntentApplicationsForTest == applications)
                    continue
                }

                let gatedGeneration = s.generation + 1
                let afterSeek = ["exact-seek-play", "exact-seek-pause", "seek-token-replaced", "source-proof-invalidated"].contains(scenario)
                if afterSeek {
                    s.imagePreviewSeekCompletedForTest = { generation, _ in
                        if generation == gatedGeneration { await gate.hold() }
                    }
                } else {
                    s.imagePreviewPreparedForTest = { generation in
                        if generation == gatedGeneration { await gate.hold() }
                    }
                }
                try x.edit()
                try await wait("replacement boundary") { gate.entered }
                check(scenario + ".boundary", s.generation == gatedGeneration && s.appliedGeneration != gatedGeneration &&
                      (afterSeek ? s.player.currentItem != nil : s.player.currentItem == nil))
                check(scenario + ".command available", s.canRequestPlayback)

                var expectedPlay = true, validImage = true, reset = false
                switch scenario {
                case "toggle-even": s.togglePlay(); s.togglePlay(); expectedPlay = false
                case "toggle-odd": s.togglePlay(); s.togglePlay(); s.togglePlay()
                case "space":
                    // Actual router/responder guards with local events, not physical keys.
                    s.attachEditorWindow(x.window); x.window.makeKeyAndOrderFront(nil)
                    evidence.append(["scenario": "space-before-focus", "active": NSApp.isActive,
                        "keyWindow": NSApp.keyWindow === x.window, "acceptsShortcuts": KeyRouting.editorAcceptsShortcuts(s),
                        "canRequestPlayback": s.canRequestPlayback])
                    let owners = NSWorkspace.shared.runningApplications.filter {
                        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                            ($0.bundleIdentifier?.hasPrefix("dev.ontheframe.") ?? false)
                    }
                    guard owners.isEmpty else { throw Failure(message: "owner app running; native focus test not admitted") }
                    NSApp.activate(); x.window.makeKeyAndOrderFront(nil)
                    try await wait("task-owned editor focus") {
                        NSApp.keyWindow === x.window && KeyRouting.editorAcceptsShortcuts(s)
                    }
                    evidence.append(["scenario": "space-after-focus", "active": NSApp.isActive,
                        "keyWindow": NSApp.keyWindow === x.window, "acceptsShortcuts": KeyRouting.editorAcceptsShortcuts(s)])
                    x.window.makeFirstResponder(x.view)
                    for index in 1...3 {
                        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: x.window.windowNumber,
                            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else {
                            throw Failure(message: "local Space event creation")
                        }
                        check(scenario + ".router consumes \(index)", KeyRouting.handle(event, store: s) == nil)
                        check(scenario + ".desired parity \(index)", s.playbackRequested == (index % 2 == 1))
                    }
                    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
                    x.view.addSubview(text); x.window.makeFirstResponder(text)
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: x.window.windowNumber,
                        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
                    check(scenario + ".text input preserved", KeyRouting.handle(event, store: s) != nil && s.playbackRequested)
                    x.window.makeFirstResponder(x.view); text.removeFromSuperview()
                default: s.play()
                }
                check(scenario + ".not active before readiness", !s.isPlaying && s.player.rate == 0 &&
                      s.imagePlayIntentApplicationsForTest == applications)
                switch scenario {
                case "pause", "exact-seek-pause": s.pause(); expectedPlay = false
                case "duplicate": for _ in 0..<10 { s.play() }
                case "pause-play": s.pause(); check(scenario + ".pause cancels", !s.playbackRequested); s.play()
                case "new-generation-clears-old", "new-generation-keeps-new":
                    try x.edit(1.25)
                    check(scenario + ".new generation cancels old", !s.imagePlayIntentPendingForTest && s.generation != gatedGeneration)
                    expectedPlay = scenario == "new-generation-keeps-new"
                    if expectedPlay { s.play() }
                case "project-switch":
                    let next = folder.appendingPathComponent("next-project.ontheframe")
                    try FileManager.default.copyItem(at: template, to: next)
                    guard await s.openProject(at: next) else { throw Failure(message: "replacement project open failed") }
                    check(scenario + ".new session", s.projectSession != session)
                    expectedPlay = false
                case "project-reset":
                    s.resetProject(); expectedPlay = false; reset = true
                case "item-replacement":
                    s.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
                    try await wait("foreign item cancels old intent") { !s.imagePlayIntentPendingForTest }
                    expectedPlay = false
                case "seek-token-replaced": s.seek(to: 238); expectedPlay = false
                case "source-proof-invalidated":
                    let image = s.timeline.stillImageIDs.first!
                    s.applyImageAvailability(false, id: image, snapshot: s.timeline, session: s.projectSession, generation: s.generation)
                    expectedPlay = false; validImage = false
                case "project-close":
                    s.savedTimeline = s.timeline // Test store only; avoid any native discard panel.
                    check(scenario + ".close accepted", s.windowShouldClose(x.window, original: nil))
                    expectedPlay = false
                default: break
                }
                check(scenario + ".desired state", s.playbackRequested == expectedPlay &&
                      s.imagePlayIntentPendingForTest == expectedPlay && !s.isPlaying)
                if scenario == "pause" || scenario == "exact-seek-pause" {
                    check(scenario + ".pause preserves target", s.playhead == 118)
                }
                gate.release()
                if reset {
                    try await wait("stale reset result drained") { s.imagePreviewStaleDropsForTest > 0 }
                    check(scenario + ".empty remains stopped", s.timeline.isEmpty && !s.isPlaying && s.player.currentItem == nil)
                } else if validImage {
                    try await wait("latest replacement installed") { x.ready() }
                } else {
                    try await wait("invalid source proof retires intent") { s.appliedGeneration == s.generation && !s.imagePlayIntentPendingForTest }
                    check(scenario + ".proof remains invalid", !x.ready())
                }
                if expectedPlay {
                    try await wait("pending intent starts playback") { s.isPlaying && s.player.rate > 0 }
                    let start = s.player.currentTime().seconds
                    try await wait("real audio item clock advances") { s.player.currentTime().seconds - start >= 0.1 }
                    let audio = try await s.player.currentItem!.asset.loadTracks(withMediaType: .audio)
                    check(scenario + ".audio and current image ready", !audio.isEmpty && s.currentPlan?.hasAudio == true && x.ready())
                }
                // Drain already-scheduled KVO callbacks, without a timed retry.
                for _ in 0..<3 { await Task.yield() }
                check(scenario + ".consumed once or cancelled", !s.imagePlayIntentPendingForTest &&
                      s.imagePlayIntentApplicationsForTest - applications == (expectedPlay ? 1 : 0))
                check(scenario + ".final transport", s.isPlaying == expectedPlay && s.playbackRequested == expectedPlay &&
                      (expectedPlay || s.player.rate == 0))
                if scenario.hasPrefix("new-generation") {
                    check(scenario + ".stale completion isolated", s.imagePreviewStaleDropsForTest == 1 &&
                          s.timeline.clips.first?.effectiveTransform.scale == 1.25)
                }
                evidence.append(["scenario": scenario, "session": s.projectSession, "generation": s.generation,
                    "appliedGeneration": s.appliedGeneration, "playing": s.isPlaying,
                    "pending": s.imagePlayIntentPendingForTest, "applications": s.imagePlayIntentApplicationsForTest - applications,
                    "stalePlanDrops": s.imagePreviewStaleDropsForTest, "physicalInput": false])
            } catch { check(scenario + ".completed", false, String(describing: error)) }
        }
        do {
            try await wait("GPU ownership drained") {
                ImagePreviewCompositor.admission.outstanding == 0 && ImagePreviewMetal.ownership.counts.active == 0 &&
                    ImagePreviewMetal.ownership.counts.resources == 0
            }
            check("GPU ownership drained", true)
        } catch { check("GPU ownership drained", false, String(describing: error)) }
        do {
            try JSONEncoder().encode(checks).write(to: folder.appendingPathComponent("image-playback-intent-checks.json"), options: .withoutOverwriting)
            try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
                .write(to: folder.appendingPathComponent("image-playback-intent-evidence.json"), options: .withoutOverwriting)
        } catch { check("evidence written", false, String(describing: error)) }
        return checks
    }
}
#endif
