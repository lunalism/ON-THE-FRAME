#if DEBUG
import AppKit
import AVFoundation
import OnTheFrameEngine

@MainActor
enum SpectrumOverlaySelfTest {
    typealias Check = LaneSelfTest.Check
    @MainActor final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = false
        private var released = false
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { released = true; let all = waiters; waiters = []; all.forEach { $0.resume() } }
    }
    struct PixelProbe {
        let context: CGContext
        let painted: Int
        let wrong: Int
        let outside: Int
    }

    /// Synchronous bitmap work stays outside the long async scenario runner.
    static func makePixelProbe(image: CGImage, layerFrame: CGRect, drawRect: CGRect) -> PixelProbe? {
        let canvas = CALayer(); canvas.bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080); canvas.masksToBounds = true
        let copy = CALayer(); copy.frame = layerFrame; copy.contents = image; canvas.addSublayer(copy)
        guard let ctx = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let pixels = ctx.data, let data = image.dataProvider?.data, let source = CFDataGetBytePtr(data) else {
            return nil
        }
        canvas.render(in: ctx)
        var wrong = 0, painted = 0, outside = 0
        let destination = pixels.assumingMemoryBound(to: UInt8.self)
        let rect = drawRect
        withExtendedLifetime(data) {
            for y in 0..<1080 { for x in 0..<1920 {
                let alpha = destination[(y * 1920 + x) * 4 + 3]
                if rect.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    let expected = source[(y - Int(rect.minY)) * image.bytesPerRow + (x - Int(rect.minX)) * 4 + 3]
                    if abs(Int(alpha) - Int(expected)) > 1 { wrong += 1 }
                    if expected > 0 { painted += 1 }
                } else if alpha > 0 { outside += 1 }
            } }
        }
        return PixelProbe(context: ctx, painted: painted, wrong: wrong, outside: outside)
    }

    @MainActor final class Report {
        let s: ProjectStore
        let folder: URL
        let manual: Bool
        var checks: [Check] = []
        init(s: ProjectStore, folder: URL, manual: Bool) {
            self.s = s; self.folder = folder; self.manual = manual
        }
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            checks.append(Check(name: name, pass: pass, detail: detail)); LaneSelfTest.checkCountForMode = checks.count
        }
        func finish() {
            s.spectrumPreview.beforeDeliveryForTest = nil
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(checks) { try? data.write(to: folder.appendingPathComponent("spectrum-overlay-result.json")) }
            if !manual { s.discardConfirmedForTest(); NSApp.terminate(nil) }
        }
    }

    static func run(folder: URL, manual: Bool = false) async {
        let s = ProjectStore.shared
        let report = Report(s: s, folder: folder, manual: manual)
        func check(_ name: String, _ pass: Bool, _ detail: String = "") { report.check(name, pass, detail) }
        func finish() { report.finish() }
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil && s.previewHost?.window != nil }
        guard let view = s.previewHost, let window = s.editorWindow else { check("setup.view", false); finish(); return }
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
        do {
            guard let scenario = try await Scenario.prepare(report: report, view: view, window: window) else { return }
            guard try await scenario.initialAndSources() else { return }
            guard try await scenario.gatesAndTimeline() else { return }
            await scenario.seekAndTeardown()
            try await scenario.projectAndReport()
        } catch { check("fixture.orExecution", false, "\(error)") }
        finish()
    }

    @MainActor final class Scenario {
        let report: Report
        let s: ProjectStore
        let folder: URL
        let manual: Bool
        let view: PlayerNSView
        let window: NSWindow
        let overlay: PausedSpectrumOverlay
        let video: MediaAsset
        let audio: MediaAsset
        let ac: UUID, low: UUID, high: UUID, sub: UUID, key: UUID
        let topStyle: SpectrumItemStyle
        let t: Timeline

        init(report: Report, view: PlayerNSView, window: NSWindow, video: MediaAsset, audio: MediaAsset,
             ac: UUID, low: UUID, high: UUID, sub: UUID, key: UUID, topStyle: SpectrumItemStyle, t: Timeline) {
            self.report = report; s = report.s; folder = report.folder; manual = report.manual
            self.view = view; self.window = window; overlay = view.spectrumOverlay
            self.video = video; self.audio = audio; self.ac = ac; self.low = low; self.high = high
            self.sub = sub; self.key = key; self.topStyle = topStyle; self.t = t
        }
        func check(_ name: String, _ pass: Bool, _ detail: String = "") { report.check(name, pass, detail) }
        func finish() { report.finish() }

        static func prepare(report: Report, view: PlayerNSView, window: NSWindow) async throws -> Scenario? {
            let s = report.s, folder = report.folder
            let video = try await MediaProbe.inspect(folder.appendingPathComponent("sources/otf-TA.mp4"))
            let audio = try await MediaProbe.inspect(folder.appendingPathComponent("sources/aud-wav48s.wav"))
            let wavLane = UUID(), ac = UUID(), lowLane = UUID(), highLane = UUID(), low = UUID(), high = UUID(), subLane = UUID(), sub = UUID()
            var style = SpectrumItemStyle.provisionalDefault
            style.sides = .above; style.startYMilli = 420_000; style.endYMilli = 600_000; style.maxHeightMilli = 240_000
            style.red = 0; style.green = 255; style.blue = 0
            var topStyle = style; topStyle.red = 255; topStyle.green = 0
            var subtitleStyle = SubtitleStyle.default; subtitleStyle.yMilli = 500_000
            var t = try Timeline().registering(video).registering(audio)
                .addingLane(.audio, name: "WAV", id: wavLane)
                .placing(media: video.id, at: 0, videoLane: Lane.videoID, audioLane: Lane.audioID)
                .placing(media: audio.id, at: 0, videoLane: nil, audioLane: wavLane, clipID: ac)
            guard let key = t.clip(ac)?.lineageKey else { report.check("fixture.audio", false); report.finish(); return nil }
            t = try t.addingLane(.spectrum, name: "SP low", id: lowLane, outward: true)
                .addingSpectrum(lane: lowLane, at: 20, length: 80, sourceKey: key, style: style, id: low)
                .addingLane(.spectrum, name: "SP high", id: highLane, outward: true)
                .addingSpectrum(lane: highLane, at: 20, length: 80, sourceKey: key, style: topStyle, id: high)
                .addingLane(.subtitle, name: "S", id: subLane, outward: true)
                .addingSubtitle(lane: subLane, at: 20, length: 80, text: "SUBTITLE ABOVE SPECTRUM", style: subtitleStyle, id: sub)
            s.assetCache[video.url.standardizedFileURL.path] = video
            s.assetCache[audio.url.standardizedFileURL.path] = audio
            s.loadTimelineForTest(t)
            return Scenario(report: report, view: view, window: window, video: video, audio: audio,
                            ac: ac, low: low, high: high, sub: sub, key: key, topStyle: topStyle, t: t)
        }

        func seek(_ frame: Int, count: Int) async -> Bool {
            let before = overlay.assignments
            s.seek(to: frame)
            return await LaneSelfTest.waitUntil(15) {
                self.s.appliedGeneration == self.s.generation && self.overlay.confirmedFrame == frame &&
                self.overlay.assignments >= before + count
            }
        }
        func image(_ id: UUID) -> CGImage? {
            guard let content = overlay.layers[id]?.contents, CFGetTypeID(content as CFTypeRef) == CGImage.typeID else { return nil }
            return (content as! CGImage)
        }
        func settleEdit(_ frame: Int = 30, count: Int = 2) async -> Bool {
            _ = await LaneSelfTest.waitUntil(15) { self.s.appliedGeneration == self.s.generation }
            return await seek(frame, count: count)
        }

        func initialAndSources() async throws -> Bool {
            let s: ProjectStore = self.s
            let view: PlayerNSView = self.view
            let overlay: PausedSpectrumOverlay = self.overlay
            let audio: MediaAsset = self.audio
            let ac: UUID = self.ac
            let low: UUID = self.low
            let high: UUID = self.high
            let sub: UUID = self.sub
            let topStyle: SpectrumItemStyle = self.topStyle
            let t: Timeline = self.t
            let folder: URL = self.folder
            let setupReady = await self.settleEdit()
            check("paused.currentFrameVisible", setupReady && self.image(high) != nil && self.image(low) != nil && overlay.confirmedFrame == 30)
            guard setupReady, let actual = self.image(high) else { finish(); return false }
            let order = view.layer?.sublayers ?? []
            let expectedOrder = [view.playerLayer, view.stageLayer, view.spectrumCanvas, view.subtitleHost]
            check("layers.videoStageSpectrumSubtitle", order.count >= 4 && zip(order, expectedOrder).allSatisfy { $0 === $1 })
            let highLayer = overlay.layers[high], lowLayer = overlay.layers[low]
            check("layers.multipleLaneOrder", view.spectrumCanvas.sublayers?.count == 2 && view.spectrumCanvas.sublayers?.first === lowLayer && view.spectrumCanvas.sublayers?.last === highLayer)
            check("layers.noAnimations", view.spectrumCanvas.animationKeys() == nil && overlay.layers.values.allSatisfy { $0.animationKeys() == nil })
            check("subtitle.preserved", view.subtitleLayerCount == 1 && view.subtitleLayerForTest(sub)?.contents != nil)
            let geometry = PlayerNSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700)); geometry.layout()
            check("geometry.aspectFit", geometry.spectrumCanvas.bounds.size == CGSize(width: 1920, height: 1080)
                  && abs(geometry.spectrumCanvas.position.y - 68.75) < 0.001 && abs(geometry.spectrumCanvas.affineTransform().a - 1000 / 1920.0) < 0.00001)
            check("geometry.clipTransparentCanvas", view.spectrumCanvas.masksToBounds && view.spectrumCanvas.backgroundColor == nil)
            let result: SpectrumFrameOutcome = await withCheckedContinuation { continuation in
                s.spectrumPreview.request(spectrum: high, frame: 30) { continuation.resume(returning: $0) }
            }
            guard case let .ready(_, rendered?) = result, let highLayer else { check("fixture.rendered", false); finish(); return false }
            check("geometry.drawRectYAndCrop", highLayer.frame == PausedSpectrumOverlay.layerRect(rendered.drawRect)
                  && highLayer.frame.width == CGFloat(actual.width) && highLayer.frame.height == CGFloat(actual.height)
                  && highLayer.frame.minY == 1080 - rendered.drawRect.maxY && highLayer.frame.width < 1920)
            guard let probe = SpectrumOverlaySelfTest.makePixelProbe(image: actual, layerFrame: highLayer.frame, drawRect: rendered.drawRect) else {
                check("fixture.bitmap", false); finish(); return false
            }
            let ctx = probe.context
            let painted = probe.painted, wrong = probe.wrong, outside = probe.outside
            check("pixels.orientationAndTransparency", painted > 0 && wrong == 0 && outside == 0, "painted \(painted), wrong \(wrong), outside \(outside)")
            if let png = ctx.makeImage().flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }) {
                try png.write(to: folder.appendingPathComponent("spectrum-ca.png"))
            }
            check("interval.before", await self.seek(19, count: 0) && overlay.layers.isEmpty)
            check("interval.first", await self.seek(20, count: 2) && self.image(high) != nil)
            check("interval.last", await self.seek(99, count: 2) && self.image(high) != nil)
            check("interval.after", await self.seek(100, count: 0) && overlay.layers.isEmpty)
            _ = await self.seek(30, count: 2)
            let replacements = s.itemReplacements
            s.commit({ try $0.settingSpectrumSource(high, nil) }, focus: high)
            let unset = await self.settleEdit()
            check("source.unassignedClears", unset && self.image(high) == nil && self.image(low) != nil)
            check("composition.spectrumOnlyNoReplacement", s.itemReplacements == replacements)
            s.undo(); _ = await self.settleEdit()
            check("undo.restoresImage", self.image(high) != nil && s.itemReplacements == replacements)
            s.redo(); _ = await self.settleEdit()
            check("redo.clearsImage", self.image(high) == nil && s.itemReplacements == replacements)
            s.loadTimelineForTest(t); _ = await self.settleEdit()
            s.commit({ try $0.lifting(clip: ac) }, focus: high); _ = await self.settleEdit()
            check("source.deletedKeyClears", self.image(high) == nil && self.image(low) == nil)
            s.loadTimelineForTest(t); _ = await self.settleEdit()
            var transparent = topStyle; transparent.alpha = 0
            s.commit({ try $0.settingSpectrumStyle(high, transparent) }, focus: high); _ = await self.settleEdit()
            let transparentData = self.image(high)?.dataProvider?.data
            let transparentAlpha = transparentData.flatMap { CFDataGetBytePtr($0) }.map { $0[3] }
            check("ready.transparentReplaces", self.image(high)?.width == 1 && transparentAlpha == 0)
            s.loadTimelineForTest(t); _ = await self.settleEdit()
            s.commit({ try $0.settingClipAudio(clip: ac, muted: true) }, focus: ac); _ = await self.settleEdit()
            check("ready.nilOnMuteClearsBoth", self.image(high) == nil && self.image(low) == nil)
            s.loadTimelineForTest(t); _ = await self.settleEdit()
            s.assetCache[audio.url.standardizedFileURL.path] = nil; s.timelineChanged(); _ = await self.settleEdit()
            check("source.mediaUnavailableClears", self.image(high) == nil && self.image(low) == nil)
            s.assetCache[audio.url.standardizedFileURL.path] = audio; s.loadTimelineForTest(t); _ = await self.settleEdit()

            return true
        }

        func gatesAndTimeline() async throws -> Bool {
            let s: ProjectStore = self.s
            let overlay: PausedSpectrumOverlay = self.overlay
            let audio: MediaAsset = self.audio
            let ac: UUID = self.ac
            let low: UUID = self.low
            let high: UUID = self.high
            let key: UUID = self.key
            let t: Timeline = self.t
            let fileGate = Gate()
            s.spectrumPreview.beforeDeliveryForTest = { _ in await fileGate.wait() }
            s.self.seek(to: 31)
            let fileEntered = await LaneSelfTest.waitUntil(10) { fileGate.entered }
            s.spectrumPreview.beforeDeliveryForTest = nil
            let sourceURL = audio.url, hiddenURL = audio.url.deletingLastPathComponent().appendingPathComponent("hidden-\(UUID().uuidString).wav")
            try FileManager.default.moveItem(at: sourceURL, to: hiddenURL)
            let fileAssignments = overlay.assignments
            fileGate.release()
            _ = await LaneSelfTest.waitUntil(10) { overlay.assignments >= fileAssignments + 2 }
            check("media.physicalLossRejectsCachedReady", fileEntered && self.image(high) == nil && self.image(low) == nil)
            try FileManager.default.moveItem(at: hiddenURL, to: sourceURL)
            _ = await self.seek(30, count: 2)
            check("media.restoredIdentityUsable", self.image(high) != nil && self.image(low) != nil)
            let gestureGate = Gate()
            s.spectrumPreview.beforeDeliveryForTest = { _ in await gestureGate.wait() }
            s.self.seek(to: 31)
            let gestureEntered = await LaneSelfTest.waitUntil(10) { gestureGate.entered }
            s.spectrumPreview.beforeDeliveryForTest = nil
            s.beginGesture(select: high)
            s.updateTrim(high, edge: .start, delta: 20)
            gestureGate.release(); await Task.yield()
            check("gesture.suppressesOldAndLateImages", gestureEntered && overlay.layers.isEmpty && s.gestureBase != nil)
            s.cancelGesture()
            _ = await LaneSelfTest.waitUntil(10) { self.image(high) != nil && self.image(low) != nil }
            check("gesture.cancelRestoresCurrentFrame", self.image(high) != nil && overlay.confirmedFrame == 31)
            let gestureReplacements = s.itemReplacements
            s.beginGesture(select: high); s.updateTrim(high, edge: .start, delta: 20); s.commitGesture()
            _ = await LaneSelfTest.waitUntil(10) { overlay.layers[high] == nil && self.image(low) != nil }
            check("gesture.commitUpdatesOverlayOnly", overlay.layers[high] == nil && self.image(low) != nil && s.itemReplacements == gestureReplacements)
            s.loadTimelineForTest(t); _ = await self.settleEdit()
            let previousAudioImage = self.image(high)
            s.commit({ try $0.settingClipAudio(clip: ac, volumePercent: 50, fadeInFrames: 60) }, focus: ac)
            check("audio.gainFadeClearsImmediately", overlay.layers.isEmpty)
            _ = await self.settleEdit()
            check("audio.gainFadeProducesCurrentImage", self.image(high) != nil && self.image(high) !== previousAudioImage)
            s.loadTimelineForTest(t); _ = await self.settleEdit()

            // Conservative D-S8: overlapping lineage pieces [50,60) suppress [47,63).
            let overlapLane = UUID()
            let overlapBase = try t.addingLane(.audio, name: "overlap", id: overlapLane)
            let overlapClip = Clip(mediaID: audio.id, start: 50, sourceIn: 0, length: 10, lane: overlapLane, origin: key)
            let overlapTimeline = Timeline(clips: overlapBase.clips, audioClips: overlapBase.audioClips + [overlapClip],
                subtitles: overlapBase.subtitles, spectra: overlapBase.spectra, lanes: overlapBase.lanes, media: overlapBase.media,
                mediaFrames: overlapBase.mediaFrames, mediaHasAudio: overlapBase.mediaHasAudio, mediaHasVideo: overlapBase.mediaHasVideo,
                durationFrames: overlapBase.durationFrames)
            guard overlapTimeline.isValid else { check("fixture.overlap", false); finish(); return false }
            s.loadTimelineForTest(overlapTimeline); _ = await self.settleEdit(46)
            check("overlap.beforeConservativeWindow", self.image(high) != nil)
            _ = await self.seek(47, count: 2); check("overlap.firstSuppressed", self.image(high) == nil && self.image(low) == nil)
            _ = await self.seek(62, count: 2); check("overlap.lastSuppressed", self.image(high) == nil && self.image(low) == nil)
            _ = await self.seek(63, count: 2); check("overlap.afterConservativeWindow", self.image(high) != nil)
            s.loadTimelineForTest(t); _ = await self.settleEdit()
            let trimReplacements = s.itemReplacements
            s.commit({ try $0.trimmingSpectrum(high, start: 40, end: 80) }, focus: high)
            _ = await self.settleEdit(30, count: 1)
            check("trim.clearsOutOfRangeWithoutRebuild", self.image(high) == nil && self.image(low) != nil && s.itemReplacements == trimReplacements)
            s.loadTimelineForTest(t); _ = await self.settleEdit()
            s.commit({ try $0.relocatingSpectrum(high, toStart: 100) }, focus: high)
            _ = await self.settleEdit(30, count: 1)
            check("move.clearsOutOfRange", self.image(high) == nil && self.image(low) != nil)
            s.loadTimelineForTest(t); _ = await self.settleEdit()
            let durationReplacements = s.itemReplacements
            let fullDuration = s.timeline.durationFrames
            s.commit({ try $0.trimmingSpectrum(high, start: 20, end: fullDuration + 30) }, focus: high)
            _ = await self.settleEdit()
            check("composition.durationChangeRebuilds", s.itemReplacements > durationReplacements && s.timeline.durationFrames == fullDuration + 30)
            s.loadTimelineForTest(t); _ = await self.settleEdit()
            let alternativeLane = UUID(), alternativeClip = UUID()
            let alternative = try t.addingLane(.audio, name: "alternative", id: alternativeLane)
                .placing(media: audio.id, at: 120, videoLane: nil, audioLane: alternativeLane, clipID: alternativeClip)
            guard let alternativeKey = alternative.clip(alternativeClip)?.lineageKey else { check("fixture.alternative", false); finish(); return false }
            s.loadTimelineForTest(try alternative.settingSpectrumSource(high, alternativeKey)); _ = await self.settleEdit()
            check("source.reassignmentOutsideCoverageSilent", self.image(high) == nil && self.image(low) != nil)
            s.loadTimelineForTest(t); _ = await self.settleEdit()

            return true
        }

        func seekAndTeardown() async {
            let s: ProjectStore = self.s
            let view: PlayerNSView = self.view
            let window: NSWindow = self.window
            let overlay: PausedSpectrumOverlay = self.overlay
            let low: UUID = self.low
            let high: UUID = self.high
            let t: Timeline = self.t
            // Hold a completed ready at the app boundary, replace seeks, then release it.
            let gate = Gate()
            s.spectrumPreview.beforeDeliveryForTest = { _ in await gate.wait() }
            s.self.seek(to: 31)
            let replacedSeekToken = s.seekToken
            let gated = await LaneSelfTest.waitUntil(10) { gate.entered }
            s.spectrumPreview.beforeDeliveryForTest = nil
            s.self.seek(to: 32); s.self.seek(to: 33)
            check("seek.pendingClearsImmediately", overlay.layers.isEmpty)
            gate.release()
            let newest = await LaneSelfTest.waitUntil(10) { overlay.confirmedFrame == 33 && self.image(high) != nil }
            check("seek.lateReadyCannotReplaceNewest", gated && newest && overlay.confirmedFrame == 33)
            let newestImage = self.image(high), newestAssignments = overlay.assignments
            view.subtitleSeekFinished(token: replacedSeekToken, frame: 31, finished: true)
            check("seek.oldSuccessCallbackCannotReplaceNewest", newestImage != nil && overlay.confirmedFrame == 33
                  && self.image(high) === newestImage && overlay.assignments == newestAssignments)
            view.subtitleSeekFinished(token: replacedSeekToken, frame: 31, finished: false)
            check("seek.oldCancelCallbackCannotClearNewest", overlay.confirmedFrame == 33
                  && self.image(high) === newestImage && overlay.assignments == newestAssignments)
            check("play.noSchedulingOrRetainedImage", {
                s.play(); return overlay.layers.isEmpty && overlay.confirmedFrame == nil
            }())
            s.pause()
            check("pause.uncertainFrameSuppressed", overlay.layers.isEmpty && overlay.confirmedFrame == nil)
            _ = await self.seek(30, count: 2)
            let deletionGate = Gate()
            s.spectrumPreview.beforeDeliveryForTest = { _ in await deletionGate.wait() }
            s.self.seek(to: 31)
            let deletionEntered = await LaneSelfTest.waitUntil(10) { deletionGate.entered }
            s.spectrumPreview.beforeDeliveryForTest = nil
            s.commit({ try $0.liftingSpectrum(high) }, focus: nil)
            deletionGate.release(); _ = await self.settleEdit(30, count: 1)
            check("deletion.lateReadyCannotResurrect", deletionEntered && overlay.layers[high] == nil && self.image(low) != nil)
            s.loadTimelineForTest(t); _ = await self.settleEdit()
            let detachGate = Gate()
            s.spectrumPreview.beforeDeliveryForTest = { _ in await detachGate.wait() }
            s.self.seek(to: 31)
            let detachEntered = await LaneSelfTest.waitUntil(10) { detachGate.entered }
            s.spectrumPreview.beforeDeliveryForTest = nil
            let assignments = overlay.assignments
            s.previewHost = nil
            detachGate.release()
            await Task.yield()
            check("teardown.lateCallbackSuppressed", detachEntered && overlay.layers.isEmpty && overlay.assignments == assignments && overlay.store == nil)
            s.previewHost = view; _ = await self.seek(30, count: 2)
            check("teardown.recreationUsable", self.image(high) != nil)
            let temporaryView = PlayerNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            temporaryView.playerLayer.player = s.player
            let temporaryWindow = NSWindow(contentRect: temporaryView.frame, styleMask: [.titled], backing: .buffered, defer: false)
            temporaryWindow.isReleasedWhenClosed = false
            s.previewHost = temporaryView
            temporaryWindow.contentView = temporaryView; temporaryWindow.makeKeyAndOrderFront(nil)
            s.self.seek(to: 30)
            let attached = await LaneSelfTest.waitUntil(10) { temporaryView.spectrumOverlay.layers[high]?.contents != nil }
            temporaryWindow.contentView = nil
            check("view.removalClears", attached && temporaryView.window == nil && temporaryView.spectrumOverlay.layers.isEmpty)
            temporaryWindow.contentView = temporaryView; s.self.seek(to: 30)
            _ = await LaneSelfTest.waitUntil(10) { temporaryView.spectrumOverlay.layers[high]?.contents != nil }
            temporaryWindow.close()
            check("window.closeClears", temporaryView.spectrumOverlay.layers.isEmpty && temporaryView.spectrumOverlay.confirmedFrame == nil)
            s.previewHost = view; window.makeKeyAndOrderFront(nil); _ = await self.seek(30, count: 2)
        }

        func projectAndReport() async throws {
            let s: ProjectStore = self.s
            let overlay: PausedSpectrumOverlay = self.overlay
            let audio: MediaAsset = self.audio
            let low: UUID = self.low
            let high: UUID = self.high
            let folder: URL = self.folder
            let manual: Bool = self.manual
            let relinkGate = Gate()
            s.spectrumPreview.beforeDeliveryForTest = { _ in await relinkGate.wait() }
            s.self.seek(to: 31)
            let relinkEntered = await LaneSelfTest.waitUntil(10) { relinkGate.entered }
            s.spectrumPreview.beforeDeliveryForTest = nil
            let relinkURL = folder.appendingPathComponent("sources/relinked.wav")
            let relinked = await s.relinkMedia(audio.id, to: relinkURL)
            relinkGate.release(); _ = await self.settleEdit()
            check("media.relinkRejectsOldReady", relinkEntered && relinked && s.mediaByID[audio.id]?.url.standardizedFileURL == relinkURL.standardizedFileURL && self.image(high) != nil)
            let beforeFailureImage = self.image(high), epoch = s.spectrumPreview.epoch
            let bad = folder.appendingPathComponent("bad-\(UUID().uuidString).ontheframe")
            try Data("{ broken".utf8).write(to: bad)
            let badOpened = await s.openProject(at: bad)
            check("project.failedOpenPreservesOverlay", !badOpened && self.image(high) === beforeFailureImage && s.spectrumPreview.epoch == epoch)
            if s.alerts.isShowing { s.alerts.pressButton(0) }
            _ = await LaneSelfTest.waitUntil(5) { !s.alerts.isShowing }
            // A uniquely saved project supports reproducible owner testing; never drive a save panel.
            let saved = folder.appendingPathComponent("paused-spectrum-\(UUID().uuidString).ontheframe")
            check("save.uniqueDisposable", s.writeProject(to: saved))
            let beforeCancelImage = self.image(high), beforeCancelEpoch = s.spectrumPreview.epoch
            s.candidatePreparedForTest = { _ in s.cancelOpen() }
            let cancelledOpen = await s.openProject(at: saved)
            s.candidatePreparedForTest = nil
            check("project.cancelledOpenPreservesOverlay", !cancelledOpen && self.image(high) === beforeCancelImage && s.spectrumPreview.epoch == beforeCancelEpoch)
            let projectGate = Gate()
            s.spectrumPreview.beforeDeliveryForTest = { _ in await projectGate.wait() }
            s.self.seek(to: 31)
            let projectEntered = await LaneSelfTest.waitUntil(10) { projectGate.entered }
            s.spectrumPreview.beforeDeliveryForTest = nil
            let beforeResetAssignments = overlay.assignments
            s.resetProject()
            projectGate.release(); await Task.yield()
            check("project.lateReadyCannotPopulateEmptyProject", projectEntered && overlay.layers.isEmpty && overlay.assignments == beforeResetAssignments)
            check("project.replacementClearsSynchronously", overlay.layers.isEmpty && overlay.confirmedFrame == nil)
            let reopened = await s.openProject(at: saved)
            _ = await self.settleEdit()
            check("project.reopenExactFile", reopened && s.projectURL == saved.standardizedFileURL && self.image(high) != nil)
            // Candidate validation holds temporary scopes; a current-project edit must win.
            let conflictGate = Gate()
            let beforeConflictTimeline = s.timeline, beforeConflictScopes = s.scopedURLs
            let beforeConflictEpoch = s.spectrumPreview.epoch, beforeConflictSession = s.projectSession
            let beforeConflictImage = self.image(high)
            var candidateScopeCount = 0
            s.candidatePreparedForTest = { count in candidateScopeCount = count; await conflictGate.wait() }
            let conflictTask = Task { await s.openProject(at: saved) }
            let conflictPrepared = await LaneSelfTest.waitUntil(10) { conflictGate.entered }
            check("project.candidatePreparationPreservesCurrentImage", conflictPrepared && candidateScopeCount > 0
                  && self.image(high) === beforeConflictImage && s.scopedURLs == beforeConflictScopes
                  && s.spectrumPreview.epoch == beforeConflictEpoch)
            s.commit({ try $0.settingSpectrumSource(high, nil) }, focus: high)
            _ = await self.settleEdit()
            let editedDuringOpen = s.timeline, editedRevision = s.spectrumPreview.revision
            conflictGate.release()
            let conflictOpened = await conflictTask.value
            s.candidatePreparedForTest = nil
            check("project.editConflictKeepsEditedOverlayAndScopes", !conflictOpened && s.timeline == editedDuringOpen
                  && self.image(high) == nil && self.image(low) != nil && s.scopedURLs == beforeConflictScopes
                  && s.projectSession == beforeConflictSession && s.spectrumPreview.epoch == beforeConflictEpoch
                  && s.spectrumPreview.revision == editedRevision)
            if s.alerts.isShowing { s.alerts.pressButton(0) }
            _ = await LaneSelfTest.waitUntil(5) { !s.alerts.isShowing }
            s.loadTimelineForTest(beforeConflictTimeline); _ = await self.settleEdit()
            let memoryBefore = SpectrumPreviewProbe.footprintMB()
            var repeatedSeeksOK = true
            for frame in 20..<80 {
                if !(await self.seek(frame, count: 2)) { repeatedSeeksOK = false; break }
            }
            let memoryAfter = SpectrumPreviewProbe.footprintMB()
            check("performance.repeatedPausedSeeks", repeatedSeeksOK, "60 sequential exact seeks, two spectra, whole app footprint \(memoryBefore) -> \(memoryAfter) MiB; includes AVFoundation/analysis caches, not isolated overlay memory")
            _ = await self.seek(30, count: 2)
            let times = Array(overlay.latencies.suffix(120)).sorted(), costs = Array(overlay.updateCosts.suffix(120)).sorted()
            check("performance.record", true, "1080p native app requests \(times.count), latency p50 \(times.isEmpty ? 0 : times[times.count / 2] * 1000) ms, layer CPU p50 \(costs.isEmpty ? 0 : costs[costs.count / 2] * 1000) ms; CA display/commit completion not measured")
            if manual {
                try "Saved disposable project: \(saved.path)\n".write(to: folder.appendingPathComponent("manual-project.txt"), atomically: true, encoding: .utf8)
            }
        }

    }
}
#endif
