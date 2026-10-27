#if DEBUG
import AppKit
import AVFoundation
import OnTheFrameEngine

/// Controlled delivery gates determine ordering; timeouts only bound a failed test.
@MainActor
enum SpectrumPlaybackSelfTest {
    typealias Check = LaneSelfTest.Check
    typealias Key = PlaybackSpectrumController.Key
    @MainActor final class Delivery {
        var waiting: [Key: CheckedContinuation<SpectrumFrameOutcome, Never>] = [:]
        var requests: [Key: Int] = [:]
        func hold(_ id: UUID, _ frame: Int) async -> SpectrumFrameOutcome {
            let key = Key(spectrum: id, frame: frame)
            requests[key, default: 0] += 1
            return await withCheckedContinuation { waiting[key] = $0 }
        }
        func release(_ id: UUID, _ frame: Int, _ result: SpectrumFrameOutcome) {
            waiting.removeValue(forKey: Key(spectrum: id, frame: frame))?.resume(returning: result)
        }
        func releaseAll() { let all = waiting; waiting = [:]; for c in all.values { c.resume(returning: .cancelled) } }
    }
    static func run(folder: URL) async {
        var checks: [Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            checks.append(Check(name: name, pass: pass, detail: detail)); LaneSelfTest.checkCountForMode = checks.count
        }
        func wait(_ predicate: @escaping () -> Bool) async -> Bool { await LaneSelfTest.waitUntil(10, predicate) }
        let session = SpectrumPreviewSession(), delivery = Delivery()
        let c = session.playback
        defer { session.transformOutcomeForTest = nil; delivery.releaseAll(); c.stop() }
        session.transformOutcomeForTest = { id, frame, _ in await delivery.hold(id, frame) }
        let id = UUID(), lane = UUID(), media = UUID()
        let spectra = [SpectrumItem(id: id, lane: lane, start: 0, length: 180)]
        let timeline = Timeline(clips: [Clip(mediaID: media, start: 0, sourceIn: 0, length: 120)],
                                audioClips: [Clip(mediaID: media, start: 0, sourceIn: 0, length: 180)],
                                spectra: spectra, durationFrames: 180)
        let audioOnly = Timeline(audioClips: timeline.audioClips, spectra: spectra, durationFrames: 180)
        check("frame.zero", SpectrumPlaybackTiming.frame(.zero, duration: 180) == 0)
        check("frame.beforeBoundary", SpectrumPlaybackTiming.frame(CMTime(value: 999, timescale: 30000), duration: 180) == 0)
        check("frame.exactBoundary", SpectrumPlaybackTiming.frame(CMTime(value: 1000, timescale: 30000), duration: 180) == 1)
        check("frame.afterBoundary", SpectrumPlaybackTiming.frame(CMTime(value: 1001, timescale: 30000), duration: 180) == 1)
        check("frame.last", SpectrumPlaybackTiming.frame(CMTime(value: 179, timescale: 30), duration: 180) == 179)
        check("frame.endIsNotClamped", SpectrumPlaybackTiming.frame(CMTime(value: 180, timescale: 30), duration: 180) == nil)
        check("frame.invalid", SpectrumPlaybackTiming.frame(.invalid, duration: 180) == nil)
        check("frame.indefinite", SpectrumPlaybackTiming.frame(.indefinite, duration: 180) == nil)
        check("frame.negative", SpectrumPlaybackTiming.frame(CMTime(value: -1, timescale: 30000), duration: 180) == nil)
        check("frame.foreignEpoch", SpectrumPlaybackTiming.frame(CMTime(value: 1, timescale: 30, flags: .valid, epoch: 1), duration: 180) == nil)
        let timingItem = AVPlayerItem(asset: AVMutableComposition())
        c.timing.attach(timingItem)
        let attachedOutput = c.timing.output
        check("timing.outputAttached", attachedOutput != nil && timingItem.outputs.contains { $0 === attachedOutput })
        c.timing.attach(timingItem)
        check("timing.sameItemNoDuplicate", c.timing.output === attachedOutput && timingItem.outputs.count == 1)
        c.timing.detach()
        check("timing.detachRemovesOutput", timingItem.outputs.isEmpty && c.timing.output == nil && c.timing.item == nil)
        let time = CMTime(value: 30, timescale: 30)
        check("timing.availableMedia", SpectrumPlaybackTiming.select(requested: time, display: time, timeline: timeline) == 30)
        check("timing.oldSampleRejected", SpectrumPlaybackTiming.select(requested: time, display: CMTime(value: 29, timescale: 30), timeline: timeline) == nil)
        check("timing.audioOnlyUnknown", SpectrumPlaybackTiming.select(requested: time, display: time, timeline: audioOnly) == nil)
        let tail = CMTime(value: 120, timescale: 30)
        check("timing.videoEndedAudioContinues", SpectrumPlaybackTiming.select(requested: tail, display: CMTime(value: 119, timescale: 30), timeline: timeline) == nil)
        let gap = Timeline(clips: [Clip(mediaID: media, start: 60, sourceIn: 0, length: 60)], durationFrames: 180)
        check("timing.videoGapUnknown", SpectrumPlaybackTiming.select(requested: time, display: time, timeline: gap) == nil)
        check("timing.noSource", c.timing.sample(hostTime: 0, timeline: timeline) == nil)

        c.advance(frame: 30, timeline: timeline)
        check("schedule.currentPlusTwo", c.pendingCount == 3 && c.metrics.requested == 3)
        _ = await wait { delivery.waiting.count == 3 }
        for _ in 0..<1000 { c.advance(frame: 30, timeline: timeline) }
        check("schedule.sameFrameDeduplicated", c.metrics.requested == 3 && c.metrics.reused == 1000)
        delivery.release(id, 32, .ready(bands: [], frame: nil))
        _ = await wait { c.retainedCount == 1 }
        check("completion.futureNotCurrent", c.currentOutcome(spectrum: id, frame: 32) == nil && c.currentOutcome(spectrum: id, frame: 30) == nil)
        delivery.release(id, 30, .ready(bands: [], frame: nil))
        _ = await wait { c.currentOutcome(spectrum: id, frame: 30) != nil }
        check("completion.outOfOrderCurrentIdentity", c.currentOutcome(spectrum: id, frame: 30) != nil)
        let requests = c.metrics.requested
        c.advance(frame: 31, timeline: timeline)
        check("schedule.windowReuse", c.metrics.requested == requests + 1)
        c.advance(frame: 32, timeline: timeline)
        check("completion.prefetchBecomesCurrent", c.currentOutcome(spectrum: id, frame: 32) != nil)
        c.advance(frame: 90, timeline: timeline)
        check("completion.oldImageNeverCurrent", c.currentOutcome(spectrum: id, frame: 32) == nil && c.currentOutcome(spectrum: id, frame: 90) == nil)
        for frame in 0..<180 { c.advance(frame: frame, timeline: timeline) }
        check("schedule.rapidJumpBound", c.pendingCount <= 8 && c.metrics.peakPending <= 8)
        let beforeStopRequests = c.metrics.requested
        c.stop()
        check("pause.clearsIdentityAndImages", c.currentFrame == nil && c.retainedCount == 0 && c.retainedBytes == 0)
        check("cancel.slotsHeldUntilTerminal", c.pendingCount > 0 && c.metrics.requested == beforeStopRequests)
        session.transformOutcomeForTest = nil
        delivery.releaseAll()
        _ = await wait { c.pendingCount == 0 }
        check("cancel.lateResultsRejected", c.pendingCount == 0 && c.retainedCount == 0 && c.metrics.stale > 0)

        session.transformOutcomeForTest = { id, frame, _ in await delivery.hold(id, frame) }
        c.advance(frame: 40, timeline: timeline)
        _ = await wait { delivery.waiting.count == 3 }
        delivery.release(id, 40, .dropped)
        _ = await wait { c.metrics.dropped == 1 }
        let droppedRequests = c.metrics.requested
        for _ in 0..<100 { c.advance(frame: 40, timeline: timeline) }
        check("dropped.noTickRetryLoop", c.metrics.dropped == 1 && c.metrics.requested == droppedRequests && c.currentOutcome(spectrum: id, frame: 40) == nil)
        session.update(timeline: timeline, media: [])
        check("revision.invalidatesSynchronously", c.currentFrame == nil && c.retainedCount == 0)
        session.transformOutcomeForTest = nil; delivery.releaseAll()
        _ = await wait { c.pendingCount == 0 }
        check("revision.readyCannotSurvive", c.retainedCount == 0)
        session.transformOutcomeForTest = { id, frame, _ in await delivery.hold(id, frame) }
        c.advance(frame: 50, timeline: timeline)
        _ = await wait { delivery.waiting.count == 3 }
        session.resetProject()
        session.transformOutcomeForTest = nil; delivery.releaseAll()
        _ = await wait { c.pendingCount == 0 }
        check("project.resetReleasesResources", c.currentFrame == nil && c.retainedCount == 0 && c.pendingCount == 0 && c.timing.output == nil)
        let many = Timeline(spectra: (0..<20).map { _ in SpectrumItem(lane: UUID(), start: 0, length: 180) }, durationFrames: 180)
        c.advance(frame: 20, timeline: many)
        check("schedule.manyItemsBound", c.pendingCount == 8)
        _ = await wait { c.pendingCount == 0 }
        check("schedule.terminalUnavailableNoImage", c.retainedCount == 0)
        c.stop()

        do {
            // Large real owned images exercise the byte limit, rather than only the entry count.
            let large = try await Task.detached {
                var style = SpectrumItemStyle.provisionalDefault
                style.startXMilli = 0; style.endXMilli = 1_920_000
                style.startYMilli = 1_080_000; style.endYMilli = 1_080_000
                style.maxHeightMilli = 1_080_000; style.sides = .above
                return try SpectrumFrameRenderer(width: 1920, height: 1080).render(bands: Array(repeating: 1, count: style.bands), style: style)
            }.value
            session.transformOutcomeForTest = { id, frame, _ in await delivery.hold(id, frame) }
            c.advance(frame: 60, timeline: timeline)
            _ = await wait { delivery.waiting.count == 3 }
            delivery.release(id, 62, .ready(bands: [], frame: large))
            delivery.release(id, 61, .ready(bands: [], frame: large))
            _ = await wait { c.pendingCount == 1 }
            delivery.release(id, 60, .ready(bands: [], frame: large))
            _ = await wait { c.pendingCount == 0 }
            check("retention.byteBudgetAndCurrentPriority", large != nil && c.retainedBytes <= PlaybackSpectrumController.byteLimit && c.currentOutcome(spectrum: id, frame: 60) != nil && c.retainedCount < 3)
            c.advance(frame: nil, timeline: timeline)
            check("timing.unavailableClearsAllImages", c.currentFrame == nil && c.retainedCount == 0)
            c.advance(frame: 70, timeline: timeline)
            _ = await wait { delivery.waiting.count == 3 }
            delivery.release(id, 70, .overlap)
            delivery.release(id, 71, .mediaUnavailable(media))
            delivery.release(id, 72, .failed(.render(.invalidCanvas("injected"))))
            _ = await wait { c.pendingCount == 0 }
            check("unavailable.errorOverlapNoFallback", c.retainedCount == 0 && c.currentOutcome(spectrum: id, frame: 70) == nil)
            c.stop(); session.transformOutcomeForTest = nil
        } catch { check("retention.fixture", false, "\(error)") }

        await recoveryRegression(check: check)

        // Real coordinator, real file analysis/rendering on its own worker queues.
        do {
            let audio = try await MediaProbe.inspect(folder.appendingPathComponent("sources/aud-wav48s.wav"))
            let clip = UUID(), spectrum = UUID(), spectrumLane = UUID()
            var real = try Timeline().registering(audio).placing(media: audio.id, at: 0, videoLane: nil, audioLane: Lane.audioID, clipID: clip)
            real = try real.addingLane(.spectrum, name: "SP", id: spectrumLane)
                .addingSpectrum(lane: spectrumLane, at: 0, length: 180, sourceKey: clip, id: spectrum)
            session.update(timeline: real, media: [audio])
            let memoryBefore = SpectrumPreviewProbe.footprintMB()
            for frame in 20..<80 {
                c.advance(frame: frame, timeline: real)
                let ready = await wait { c.currentOutcome(spectrum: spectrum, frame: frame) != nil && c.pendingCount == 0 }
                if !ready { check("real.frame.\(frame)", false); break }
            }
            let m = c.metrics
            check("real.analysisAndRender", c.currentOutcome(spectrum: spectrum, frame: 79) != nil && c.retainedBytes > 0)
            check("real.retentionBounds", c.retainedCount <= 8 && c.retainedBytes <= PlaybackSpectrumController.byteLimit && m.peakPending <= 8)
            let before = c.metrics.requested
            for _ in 0..<10000 { c.advance(frame: 79, timeline: real) }
            check("performance.repeatTickNoRequests", c.metrics.requested == before)
            check("performance.record", true, "peakPending=\(m.peakPending), peakRetained=\(m.peakRetained), peakImageBytes=\(m.peakBytes), recoveryRequests=\(m.recoveryRequests), requests=\(m.requested), cancelled=\(m.cancelled), stale=\(m.stale), sameFrameSkips=\(c.metrics.reused), prefetchedCurrentHits=\(m.prefetchedCurrentHits), resultLatencyMeanMs=\(m.accepted == 0 ? 0 : 1000 * m.latencyTotal / Double(m.accepted)), maxMs=\(1000 * m.latencyMax), mainAdvanceMeanUs=\(1000000 * c.metrics.tickSeconds / Double(c.metrics.ticks)), maxUs=\(1000000 * c.metrics.maxTickSeconds), footprintMiB=\(memoryBefore)->\(SpectrumPreviewProbe.footprintMB()); synthetic + real requests; no display delivery measurement")
            c.stop()
            check("teardown.imagesReleased", c.retainedCount == 0 && c.retainedBytes == 0)
        } catch { check("real.fixture", false, "\(error)") }

        // Actual store transition wiring, independent of the paused overlay's test suite.
        let store = ProjectStore()
        let playback = store.spectrumPreview.playback
        playback.advance(frame: 20, timeline: timeline); store.seek(to: 30)
        check("seek.invalidatesPlayback", playback.currentFrame == nil)
        playback.advance(frame: 20, timeline: timeline); store.pause()
        check("pause.transitionInvalidates", playback.currentFrame == nil)
        let view = PlayerNSView(); store.previewHost = view
        playback.advance(frame: 20, timeline: timeline); store.previewHost = nil
        check("view.detachInvalidates", playback.currentFrame == nil && playback.timing.output == nil)
        playback.advance(frame: 20, timeline: timeline); store.resetProject()
        check("project.replacementInvalidates", playback.currentFrame == nil)
        store.stopAllScopes()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(checks) { try? data.write(to: folder.appendingPathComponent("spectrum-playback-result.json")) }
        ProjectStore.shared.discardConfirmedForTest(); NSApp.terminate(nil)
    }

    /// Run unchanged against both the original controller and its correction.
    private static func recoveryRegression(check: (String, Bool, String) -> Void) async {
        do {
            let images: [SpectrumRenderedFrame] = try await Task.detached {
                let renderer = try SpectrumFrameRenderer(width: 1920, height: 1080)
                var style = SpectrumItemStyle.provisionalDefault
                style.startXMilli = 0; style.endXMilli = 1_920_000
                style.startYMilli = 1_080_000; style.endYMilli = 1_080_000
                style.maxHeightMilli = 1_080_000; style.sides = .above
                var result: [SpectrumRenderedFrame] = []
                for color in 0..<4 {
                    style.red = 100 + color * 30
                    if let frame = try renderer.render(bands: Array(repeating: 1, count: style.bands), style: style) { result.append(frame) }
                }
                return result
            }.value
            guard images.count == 4 else { check("recovery.fixture", false, "four distinct large images required"); return }
            check("recovery.distinctLargeImages", images[0].image !== images[1].image && images[1].image !== images[2].image
                  && images[0].image.bytesPerRow * images[0].image.height > PlaybackSpectrumController.byteLimit / 3, "owned, distinct 1080p images")
            let session = SpectrumPreviewSession(), delivery = Delivery(), id = UUID()
            let controller = session.playback
            session.transformOutcomeForTest = { id, frame, _ in await delivery.hold(id, frame) }
            defer { session.transformOutcomeForTest = nil; controller.stop(); delivery.releaseAll() }
            let timeline = Timeline(spectra: [SpectrumItem(id: id, lane: UUID(), start: 0, length: 180)], durationFrames: 180)
            func hasImage(_ frame: Int, _ index: Int) -> Bool {
                guard case let .ready(_, rendered?) = controller.currentOutcome(spectrum: id, frame: frame) else { return false }
                return rendered.image === images[index].image
            }
            controller.advance(frame: 60, timeline: timeline)
            _ = await LaneSelfTest.waitUntil(10) { delivery.waiting.count == 3 }
            delivery.release(id, 62, .ready(bands: [], frame: images[2]))
            _ = await LaneSelfTest.waitUntil(10) { controller.pendingCount == 2 }
            delivery.release(id, 61, .ready(bands: [], frame: images[1]))
            _ = await LaneSelfTest.waitUntil(10) { controller.pendingCount == 1 }
            delivery.release(id, 60, .ready(bands: [], frame: images[0]))
            _ = await LaneSelfTest.waitUntil(10) { controller.pendingCount == 0 }
            check("recovery.evictionSetup", hasImage(60, 0) && controller.retainedCount == 2,
                  "62,61,60 completion order; 62 evicted")
            controller.advance(frame: 61, timeline: timeline)
            check("recovery.retained61Reused", hasImage(61, 1), "no recomputation needed for retained image")
            let beforePromotion = controller.metrics.requested
            controller.advance(frame: 62, timeline: timeline)
            let recoveryRequested = await LaneSelfTest.waitUntil(10) { delivery.waiting[Key(spectrum: id, frame: 62)] != nil }
            check("recovery.promoted62RequestsFreshTicket", recoveryRequested,
                  "expected second request for evicted frame 62; requests before promotion \(beforePromotion), after \(controller.metrics.requested)")
            let beforeRepeated = controller.metrics.requested
            for _ in 0..<1000 { controller.advance(frame: 62, timeline: timeline) }
            check("recovery.pendingNoRetryStorm", controller.metrics.requested == beforeRepeated, "1000 same-frame advances")
            let start = ProcessInfo.processInfo.systemUptime
            if recoveryRequested { delivery.release(id, 62, .ready(bands: [], frame: images[3])) }
            _ = await LaneSelfTest.waitUntil(10) { hasImage(62, 3) }
            let releaseToAcceptedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            check("recovery.promoted62Available", hasImage(62, 3), "fresh result identity required")
            let afterRecovery = controller.metrics.requested
            for _ in 0..<1000 { controller.advance(frame: 62, timeline: timeline) }
            check("recovery.availableNoRetryStorm", controller.metrics.requested == afterRecovery && hasImage(62, 3), "1000 same-frame advances")
            check("recovery.bounds", controller.pendingCount <= 8 && controller.retainedCount <= 8
                  && controller.retainedBytes <= PlaybackSpectrumController.byteLimit, "pending/image budget maintained")
            check("recovery.measurement", recoveryRequested && hasImage(62, 3),
                  "release-to-accepted ms \(releaseToAcceptedMs); not worker/decode or display latency")
            check("recovery.exactlyOneFreshRequest", delivery.requests[Key(spectrum: id, frame: 62)] == 2,
                  "original prefetch + one recovery; coordinator issues a fresh ticket for every request")
            check("recovery.metrics", true, "peakPending=\(controller.metrics.peakPending), peakRetained=\(controller.metrics.peakRetained), peakBytes=\(controller.metrics.peakBytes), recoveryRequests=\(controller.metrics.recoveryRequests), evicted=\(controller.metrics.evicted)")
            await recoveryPolicyChecks(images: images, check: check)
        } catch { check("recovery.fixture", false, "\(error)") }
    }


    @MainActor private final class Controlled {
        let session = SpectrumPreviewSession(), delivery = Delivery()
        let ids: [UUID]
        let timeline: Timeline
        var c: PlaybackSpectrumController { session.playback }
        init(items: Int = 1) {
            ids = (0..<items).map { _ in UUID() }
            timeline = Timeline(spectra: ids.map { SpectrumItem(id: $0, lane: UUID(), start: 0, length: 180) }, durationFrames: 180)
            let delivery = delivery
            session.transformOutcomeForTest = { id, frame, _ in await delivery.hold(id, frame) }
        }
        func waiting(_ id: UUID, _ frame: Int) async -> Bool {
            await LaneSelfTest.waitUntil(10) { self.delivery.waiting[Key(spectrum: id, frame: frame)] != nil }
        }
        func send(_ id: UUID, _ frame: Int, _ result: SpectrumFrameOutcome) { delivery.release(id, frame, result) }
        func count(_ id: UUID, _ frame: Int) -> Int { delivery.requests[Key(spectrum: id, frame: frame)] ?? 0 }
        func close() async {
            session.transformOutcomeForTest = nil; c.stop(); delivery.releaseAll()
            _ = await LaneSelfTest.waitUntil(10) { self.c.pendingCount == 0 }
        }
    }
    private static func recoveryPolicyChecks(images: [SpectrumRenderedFrame], check: (String, Bool, String) -> Void) async {
        let h = Controlled(), id = h.ids[0]
        h.c.advance(frame: 60, timeline: h.timeline)
        _ = await h.waiting(id, 62)
        // Current and +1 fill the budget. The late +2 cannot displace either one.
        h.send(id, 60, .ready(bands: [], frame: images[0]))
        h.send(id, 61, .ready(bands: [], frame: images[1]))
        _ = await LaneSelfTest.waitUntil(10) { h.c.pendingCount == 1 }
        h.send(id, 62, .ready(bands: [], frame: images[2]))
        _ = await LaneSelfTest.waitUntil(10) { h.c.pendingCount == 0 }
        h.c.advance(frame: 61, timeline: h.timeline)
        h.c.advance(frame: 62, timeline: h.timeline)
        let rejectedRecovery = await h.waiting(id, 62)
        check("recovery.rejectedRetentionPromotes", rejectedRecovery && h.count(id, 62) == 2, "unretained future recovers only on promotion")
        // A seek wins over that held recovery. Releasing ready must not resurrect 62.
        h.c.advance(frame: 100, timeline: h.timeline)
        h.send(id, 62, .ready(bands: [], frame: images[3]))
        _ = await h.waiting(id, 100)
        check("recovery.rapidSeekRejectsOldReady", h.c.currentFrame == 100 && h.c.currentOutcome(spectrum: id, frame: 62) == nil,
              "old recovery cancelled; latest frame remains authoritative")
        h.send(id, 100, .ready(bands: [], frame: nil))
        _ = await LaneSelfTest.waitUntil(10) { h.c.currentOutcome(spectrum: id, frame: 100) != nil }
        let nilRequests = h.c.metrics.requested
        for _ in 0..<1000 { h.c.advance(frame: 100, timeline: h.timeline) }
        check("recovery.nilStable", h.count(id, 100) == 1 && h.c.metrics.requested == nilRequests, "valid silence is not eviction")
        await h.close()

        let silent = Controlled(items: 2)
        // Keep one future silent entry while positive-sized future images are evicted.
        let silentItem = silent.ids[0], other = silent.ids[1]
        silent.c.advance(frame: 60, timeline: silent.timeline)
        _ = await silent.waiting(silentItem, 62)
        silent.send(silentItem, 62, .ready(bands: [], frame: nil))
        silent.send(silentItem, 61, .ready(bands: [], frame: images[1]))
        silent.send(other, 61, .ready(bands: [], frame: images[2]))
        _ = await LaneSelfTest.waitUntil(10) { silent.c.retainedCount == 3 }
        silent.send(silentItem, 60, .ready(bands: [], frame: images[0]))
        _ = await LaneSelfTest.waitUntil(10) { silent.c.currentOutcome(spectrum: silentItem, frame: 60) != nil }
        silent.c.advance(frame: 61, timeline: silent.timeline); silent.c.advance(frame: 62, timeline: silent.timeline)
        check("recovery.silentNotEvictedUnderPressure", silent.c.currentOutcome(spectrum: silentItem, frame: 62) != nil
              && silent.count(silentItem, 62) == 1, "zero-byte silent result survives image-budget eviction and promotion")
        await silent.close()

        let many = Controlled(items: 3)
        many.c.advance(frame: 60, timeline: many.timeline)
        _ = await LaneSelfTest.waitUntil(10) { many.delivery.waiting.count == 8 }
        for (n, spectrum) in many.ids.enumerated() {
            many.send(spectrum, 60, .ready(bands: [], frame: images[n]))
            _ = await LaneSelfTest.waitUntil(10) { many.c.currentOutcome(spectrum: spectrum, frame: 60) != nil }
        }
        let rejected = many.ids[2]
        var explicitFailure = false
        if case .failed(.render(.invalidCanvas)) = many.c.currentOutcome(spectrum: rejected, frame: 60) { explicitFailure = true }
        let manyRequests = many.c.metrics.requested
        for _ in 0..<1000 { many.c.advance(frame: 60, timeline: many.timeline) }
        check("recovery.multipleCurrentExplicitBudgetFailure", explicitFailure && many.c.retainedCount == 2
              && many.c.retainedBytes <= PlaybackSpectrumController.byteLimit && many.c.metrics.requested == manyRequests,
              "three distinct full-canvas current images cannot all fit; failure is explicit, no per-tick retry")
        check("recovery.multiplePendingBound", many.c.pendingCount <= 8 && many.c.metrics.peakPending <= 8, "future + current slots remain bounded")
        await many.close()

        do {
            // Defensive oversized-outcome injection only. Product requests remain fixed at 1920x1080.
            let oversized = try await Task.detached {
                var style = SpectrumItemStyle.provisionalDefault
                style.startXMilli = 0; style.endXMilli = 1_920_000
                style.startYMilli = 1_080_000; style.endYMilli = 1_080_000
                style.maxHeightMilli = 1_080_000; style.sides = .above
                return try SpectrumFrameRenderer(width: 3200, height: 1800).render(bands: Array(repeating: 1, count: style.bands), style: style)
            }.value
            let x = Controlled(), item = x.ids[0]
            x.c.advance(frame: 60, timeline: x.timeline)
            _ = await x.waiting(item, 62)
            x.send(item, 61, .ready(bands: [], frame: images[1]))
            _ = await LaneSelfTest.waitUntil(10) { x.c.retainedCount == 1 }
            x.send(item, 60, .ready(bands: [], frame: oversized))
            _ = await LaneSelfTest.waitUntil(10) { x.c.pendingCount == 1 }
            var failed = false
            if case .failed(.render(.invalidCanvas)) = x.c.currentOutcome(spectrum: item, frame: 60) { failed = true }
            let requests = x.c.metrics.requested
            for _ in 0..<1000 { x.c.advance(frame: 60, timeline: x.timeline) }
            check("recovery.singleOversizedExplicitFailure", oversized.map { $0.image.bytesPerRow * $0.image.height > PlaybackSpectrumController.byteLimit } == true
                  && failed && x.c.retainedCount == 1 && x.c.retainedBytes <= PlaybackSpectrumController.byteLimit,
                  "test-only oversized injection is rejected without evicting useful future image")
            check("recovery.oversizedNoRetry", x.count(item, 60) == 1 && x.c.metrics.requested == requests, "no limit increase or per-tick retry")
            await x.close()
        } catch { check("recovery.oversizedFixture", false, "\(error)") }

        let empty = Controlled(items: 8)
        empty.c.advance(frame: 60, timeline: empty.timeline)
        _ = await LaneSelfTest.waitUntil(10) { empty.delivery.waiting.count == 8 }
        for item in empty.ids { empty.send(item, 60, .ready(bands: [], frame: nil)) }
        _ = await LaneSelfTest.waitUntil(10) { empty.c.retainedCount == 8 }
        let emptyRequests = empty.c.metrics.requested
        for _ in 0..<1000 { empty.c.advance(frame: 60, timeline: empty.timeline) }
        check("recovery.eightEmptyResultsBound", empty.c.retainedCount == 8 && empty.c.metrics.peakRetained == 8
              && empty.c.retainedBytes == 0 && empty.c.metrics.requested == emptyRequests,
              "eight valid empty results occupy bounded entries and are not re-requested")
        await empty.close()

        // Direct terminal cancellation/supersession (not an obsolete-ticket guard) gets at most one recovery.
        for (name, outcome) in [("cancelled", SpectrumFrameOutcome.cancelled), ("superseded", .superseded)] {
            let x = Controlled(), item = x.ids[0]
            x.c.advance(frame: 60, timeline: x.timeline)
            _ = await x.waiting(item, 60); x.send(item, 60, outcome)
            _ = await LaneSelfTest.waitUntil(10) { x.count(item, 60) == 2 }
            x.send(item, 60, outcome)
            _ = await LaneSelfTest.waitUntil(10) { x.c.pendingCount == 2 }
            let requests = x.c.metrics.requested
            for _ in 0..<1000 { x.c.advance(frame: 60, timeline: x.timeline) }
            check("recovery.\(name)BoundedRetry", x.count(item, 60) == 2 && x.c.metrics.requested == requests
                  && x.c.currentOutcome(spectrum: item, frame: 60) == nil, "one fresh ticket, persistent terminal stops retry")
            x.c.advance(frame: 61, timeline: x.timeline); x.c.advance(frame: 60, timeline: x.timeline)
            _ = await x.waiting(item, 60)
            x.send(item, 60, .ready(bands: [], frame: images[0]))
            _ = await LaneSelfTest.waitUntil(10) { x.c.currentOutcome(spectrum: item, frame: 60) != nil }
            check("recovery.\(name)LaterValidWork", x.count(item, 60) == 3 && x.c.currentOutcome(spectrum: item, frame: 60) != nil,
                  "later activation is not permanently marked completed by cancellation")
            await x.close()
        }
        for (name, outcome) in [("failed", SpectrumFrameOutcome.failed(.render(.invalidCanvas("injected")))), ("dropped", .dropped), ("unavailable", .unsetSource)] {
            let x = Controlled(), item = x.ids[0]
            x.c.advance(frame: 60, timeline: x.timeline)
            _ = await x.waiting(item, 60); x.send(item, 60, outcome)
            _ = await LaneSelfTest.waitUntil(10) { x.c.pendingCount == 2 }
            let requests = x.c.metrics.requested
            for _ in 0..<1000 { x.c.advance(frame: 60, timeline: x.timeline) }
            check("recovery.\(name)Stable", x.count(item, 60) == 1 && x.c.metrics.requested == requests, "persistent terminal is not an evicted image")
            await x.close()
        }
        for reset in [false, true] {
            let x = Controlled(), item = x.ids[0]
            x.c.advance(frame: 60, timeline: x.timeline)
            _ = await x.waiting(item, 60)
            if reset { x.session.resetProject() } else { x.session.update(timeline: x.timeline, media: []) }
            x.send(item, 60, .ready(bands: [], frame: images[0]))
            x.session.transformOutcomeForTest = nil; x.delivery.releaseAll()
            _ = await LaneSelfTest.waitUntil(10) { x.c.pendingCount == 0 }
            check("recovery.\(reset ? "project" : "sourceRevision")RejectsReady", x.c.currentFrame == nil && x.c.retainedCount == 0,
                  "held ready rejected after epoch/revision change")
            await x.close()
        }
    }

}
#endif
