#if DEBUG
import AppKit
import AVFoundation
import OnTheFrameEngine
import os

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
    static func startupFrameSelection() -> [Check] {
        let session = SpectrumPreviewSession()
        let audio = Clip(mediaID: UUID(), start: 0, sourceIn: 30, length: 360, lane: Lane.audioID)
        let spectrum = SpectrumItem(lane: UUID(), start: 0, length: 360, sourceKey: audio.lineageKey)
        let video = Clip(mediaID: UUID(), start: 0, sourceIn: 0, length: 360)
        let timeline = Timeline(clips: [video], audioClips: [audio], spectra: [spectrum], durationFrames: 360)
        let pieces = timeline.spectrumPieces(spectrum)
        var checks: [Check] = []
        func step(_ name: String, _ micros: Int64, pts: CMTime? = nil, expected: Int?, source: Int?) {
            let requested = CMTime(value: micros, timescale: 1_000_000)
            let frame = session.playback.timing.sample(requested: requested, timeline: timeline, hasNewBuffer: pts != nil) { display in
                guard let pts else { return false }
                display = pts
                return true
            }
            let mapped = frame.flatMap { k in pieces.first { $0.start <= k && k < $0.end }.map { $0.sourceIn + k - $0.start } }
            let fallback = SpectrumPlaybackTiming.audioIntervalFrame(at: max(.zero, requested), timeline: timeline)
            checks.append(Check(name: name, pass: frame == expected && mapped == source && fallback == nil,
                                detail: "requestUs=\(micros) frame=\(String(describing: frame)) source=\(String(describing: mapped)) fallback=\(String(describing: fallback))"))
        }
        step("before evidence", 0, expected: nil, source: nil)
        step("confirmed zero", 0, pts: .zero, expected: 0, source: 30)
        for micros: Int64 in [-31105, -22772, -14438, -6105, 2227, 10561, 18894, 27227, 35561, 43894, 52227, 60561] {
            step("startup \(micros)", micros, expected: nil, source: nil)
        }
        step("confirmed two", 68894, pts: CMTime(value: 2, timescale: 30), expected: 2, source: 32)
        step("same confirmed frame", 68894, expected: 2, source: 32)
        session.resetProject()
        step("after project reset", 68894, expected: nil, source: nil)
        return checks
    }

    /// VIDEO-TIMING-FIX-01: injected timing for the startup backward item-time request seen in
    /// FX02C-TIMING-CAPTURE-01 (342 approved, then 340–341 requested with no new buffer).
    /// Only that bounded startup pattern may reuse the approved start frame.
    static func startupRegressionChecks() -> [Check] {
        var checks: [Check] = []
        let media = UUID()
        let audio = Clip(mediaID: media, start: 0, sourceIn: 0, length: 360, lane: Lane.audioID)
        let entry = SpectrumItem(lane: UUID(), start: 0, length: 360, sourceKey: audio.lineageKey)
        let timeline = Timeline(clips: [Clip(mediaID: media, start: 0, sourceIn: 0, length: 360)],
                                audioClips: [audio], spectra: [entry], durationFrames: 360)
        let view = PlayerNSView()
        var keep: [AnyObject] = [] // timing holds its item weakly; keep sessions and items alive
        defer { withExtendedLifetime(keep) {} }
        func frame(_ f: Int) -> CMTime { CMTime(value: CMTimeValue(f), timescale: 30) }
        let regressed = CMTime(value: 11_348_044, timescale: 1_000_000) // frame 340, as captured
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            checks.append(Check(name: "startupRegression." + name, pass: pass, detail: detail))
        }
        /// A fresh transport with 342 armed at t=100 s and approved from a matching buffer.
        func started() -> (SpectrumPreviewSession, PlaybackSpectrumController, AVPlayerItem) {
            let session = SpectrumPreviewSession(), controller = session.playback
            let item = AVPlayerItem(asset: AVMutableComposition())
            keep.append(session); keep.append(item)
            controller.prepareForTransition(item: item, view: view)
            controller.timing.armStartupRegression(frame: 342, now: 100)
            _ = controller.timing.sample(requested: frame(342), timeline: timeline, hasNewBuffer: true, now: 100.01) { d in
                d = frame(342); return true
            }
            return (session, controller, item)
        }
        func noBuffer(_ c: PlaybackSpectrumController, _ t: CMTime, at now: CFTimeInterval) -> Int? {
            c.timing.sample(requested: t, timeline: timeline, hasNewBuffer: false, now: now) { _ in false }
        }
        do {
            let (_, c, _) = started()
            check("approvedStartFrame", c.timing.confirmedPTSForTest == frame(342))
            let reused = noBuffer(c, regressed, at: 100.05)
            check("backwardRequestWithoutBufferReusesStartFrame", reused == 342, "frame=\(String(describing: reused))")
            check("forwardRequestWithoutBufferStaysNil", noBuffer(c, frame(343), at: 100.06) == nil)
            check("stillBoundedAfterForwardMiss", noBuffer(c, frame(341), at: 100.07) == 342)
            check("regressionDeeperThanBoundIsNil", noBuffer(c, frame(342 - SpectrumPlaybackTiming.startupRegressionFrames - 1), at: 100.08) == nil)
            check("expiredAllowanceIsNil", noBuffer(c, regressed, at: 100.30) == nil)
            check("expiryIsFinal", noBuffer(c, regressed, at: 100.10) == nil)
        }
        do {
            let (_, c, _) = started()
            let wrong = c.timing.sample(requested: frame(342), timeline: timeline, hasNewBuffer: true, now: 100.02) { d in
                d = frame(341); return true
            }
            check("wrongDisplayPTSWithNewBufferRejected", wrong == nil)
            check("noReuseAfterRejectedBuffer", noBuffer(c, regressed, at: 100.05) == nil)
        }
        do {
            let (_, c, item) = started()
            c.prepareForTransition(item: item, view: view) // Pause and every transport edge
            check("pauseTransitionRevokesAllowance", noBuffer(c, regressed, at: 100.05) == nil)
        }
        do {
            let (_, c, _) = started()
            c.stop() // explicit seek retires the output (PlayerNSView.subtitleSeekRequested)
            check("seekRetirementRevokesAllowance", noBuffer(c, regressed, at: 100.05) == nil && c.timing.item == nil)
        }
        do {
            let (session, c, _) = started()
            session.update(timeline: timeline, media: []) // source/session revision
            check("sessionRevisionRevokesAllowance", noBuffer(c, regressed, at: 100.05) == nil)
        }
        do {
            let (_, c, _) = started()
            _ = c.timing.sample(requested: frame(343), timeline: timeline, hasNewBuffer: true, now: 100.04) { d in
                d = frame(343); return true
            }
            check("forwardProgressEndsAllowance", noBuffer(c, frame(341), at: 100.05) == nil)
        }
        do {
            let (_, c, _) = started()
            let atEnd = c.timing.sample(requested: frame(360), timeline: timeline, hasNewBuffer: false, now: 100.05) { _ in false }
            check("naturalEndBoundaryIsNil", atEnd == nil && noBuffer(c, regressed, at: 100.06) == nil)
        }
        do {
            // Without arming, the original exact-frame contract is unchanged.
            let session = SpectrumPreviewSession(), c = session.playback
            let item = AVPlayerItem(asset: AVMutableComposition())
            keep.append(session); keep.append(item)
            c.prepareForTransition(item: item, view: view)
            _ = c.timing.sample(requested: frame(342), timeline: timeline, hasNewBuffer: true, now: 100.01) { d in
                d = frame(342); return true
            }
            check("unarmedBackwardRequestStaysNil", noBuffer(c, regressed, at: 100.05) == nil)
        }
        do {
            // The real arming path: an image-free start prepared by the controller.
            let session = SpectrumPreviewSession(), c = session.playback
            let item = AVPlayerItem(asset: AVMutableComposition())
            keep.append(session); keep.append(item)
            c.prepareForTransition(item: item, view: view)
            c.prepareStartingFrame(342, timeline: timeline)
            let now = CACurrentMediaTime()
            _ = c.timing.sample(requested: frame(342), timeline: timeline, hasNewBuffer: true, now: now) { d in
                d = frame(342); return true
            }
            check("imageFreeStartPreparationArms", noBuffer(c, regressed, at: now + 0.01) == 342)
            c.stop()
        }
        // REAL-MEDIA-FIX-01 (A): a start at timeline zero; the captured request was −57.531 ms.
        func startedAtZero() -> PlaybackSpectrumController {
            let session = SpectrumPreviewSession(), c = session.playback
            let item = AVPlayerItem(asset: AVMutableComposition())
            keep.append(session); keep.append(item)
            c.prepareForTransition(item: item, view: view)
            c.timing.armStartupRegression(frame: 0, now: 100)
            _ = c.timing.sample(requested: .zero, timeline: timeline, hasNewBuffer: true, now: 100.01) { d in d = .zero; return true }
            return c
        }
        let negative = CMTime(value: -57_531, timescale: 1_000_000)
        do {
            let c = startedAtZero()
            check("zeroStartNegativeRequestReusesFrameZero", noBuffer(c, negative, at: 100.05) == 0)
            check("zeroStartKeepsApprovalAfterNegativeRequests", noBuffer(c, .zero, at: 100.06) == 0)
            check("zeroStartNegativeBeyondBoundIsNil", noBuffer(c, CMTime(value: -9, timescale: 30), at: 100.07) == nil)
        }
        do {
            let c = startedAtZero()
            check("zeroStartNegativeAfterExpiryIsNil", noBuffer(c, negative, at: 100.30) == nil)
        }
        do {
            let c = startedAtZero()
            let withBuffer = c.timing.sample(requested: negative, timeline: timeline, hasNewBuffer: true, now: 100.05) { d in d = negative; return true }
            check("negativeRequestWithNewBufferStaysInvalid", withBuffer == nil)
        }
        do {
            let session = SpectrumPreviewSession(), c = session.playback
            let item = AVPlayerItem(asset: AVMutableComposition())
            keep.append(session); keep.append(item)
            c.prepareForTransition(item: item, view: view)
            _ = c.timing.sample(requested: .zero, timeline: timeline, hasNewBuffer: true, now: 100.01) { d in d = .zero; return true }
            check("unarmedNegativeRequestStaysInvalid", noBuffer(c, negative, at: 100.05) == nil)
        }
        // REAL-MEDIA-FIX-01 (C): a one-frame advance only onto a sample-table-verified repeated image.
        func approved(at f: Int) -> PlaybackSpectrumController {
            let session = SpectrumPreviewSession(), c = session.playback
            let item = AVPlayerItem(asset: AVMutableComposition())
            keep.append(session); keep.append(item)
            c.prepareForTransition(item: item, view: view)
            _ = c.timing.sample(requested: frame(f), timeline: timeline, hasNewBuffer: true, now: 200) { d in d = frame(f); return true }
            return c
        }
        func step(_ c: PlaybackSpectrumController, _ f: Int, repeats: @escaping (Int) -> Bool) -> Int? {
            c.timing.sample(requested: frame(f), timeline: timeline, hasNewBuffer: false, now: 200.05, repeatsPreviousImage: repeats) { _ in false }
        }
        do {
            let c = approved(at: 301)
            check("repeatedImageAdvancesOneFrame", step(c, 302, repeats: { $0 == 302 }) == 302)
            check("repeatedImageFrameStaysCurrent", step(c, 302, repeats: { _ in false }) == 302)
            check("nextRealSampleStillNeedsBuffer", step(c, 303, repeats: { _ in false }) == nil)
        }
        do {
            let c = approved(at: 301)
            check("missingVideoDataIsNotARepeat", step(c, 302, repeats: { _ in false }) == nil)
        }
        do {
            let c = approved(at: 301)
            check("repeatCannotSkipAFrame", step(c, 303, repeats: { _ in true }) == nil)
        }
        do {
            let c = approved(at: 301)
            c.prepareForTransition(item: c.timing.item!, view: view) // Pause/transport edge
            check("repeatNeedsAnApprovedFrame", step(c, 302, repeats: { _ in true }) == nil)
        }
        do {
            let c = approved(at: 301)
            let atEnd = c.timing.sample(requested: frame(360), timeline: timeline, hasNewBuffer: false, now: 200.05,
                                        repeatsPreviousImage: { _ in true }) { _ in false }
            check("repeatNeverPassesNaturalEnd", atEnd == nil)
        }
        return checks
    }

    /// REAL-MEDIA-FIX-01 (C): repeat evidence from sample timestamps, without a nominal-rate formula.
    static func videoSampleIndexChecks() -> [Check] {
        var checks: [Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            checks.append(Check(name: "videoSampleIndex." + name, pass: pass, detail: detail))
        }
        // 29.97 fps sample timestamps (j × 1001/30000 s) as stored in such files.
        let ntsc = VideoSampleIndex(trackStart: .zero, pts: (0..<1100).map { CMTime(value: CMTimeValue($0 * 1001), timescale: 30000) })
        let repeated = (1..<1099).filter { ntsc.repeats(sourceFrame: $0) }
        check("ntscRepeatsOnlyWhereNoSampleStarts", repeated == [1, 1002], "repeated=\(repeated)")
        let exact = VideoSampleIndex(trackStart: .zero, pts: (0..<400).map { CMTime(value: CMTimeValue($0), timescale: 30) })
        check("exact30HasNoRepeats", (1..<399).allSatisfy { !exact.repeats(sourceFrame: $0) })
        let offset = VideoSampleIndex(trackStart: CMTime(value: 1, timescale: 10),
                                      pts: (0..<200).map { CMTime(value: 3 + CMTimeValue($0) * 3, timescale: 30) }) // 10 fps from 0.1 s
        check("trackStartOffsetAndLowRate", offset.repeats(sourceFrame: 1) && offset.repeats(sourceFrame: 2) && !offset.repeats(sourceFrame: 3))
        check("pastLastSampleIsNotARepeat", !exact.repeats(sourceFrame: 400) && !exact.repeats(sourceFrame: 500))
        check("frameZeroIsNeverARepeat", !ntsc.repeats(sourceFrame: 0))

        // EDIT-LIST-CADENCE-FIX-01: one 1× edit with a media offset of 2002/30000 s, as in the owner's MP4.
        typealias Segment = VideoSampleIndex.Segment
        func t(_ v: Int) -> CMTime { CMTime(value: CMTimeValue(v), timescale: 30000) }
        let count = 1100, duration = t(count * 1001)
        // Media-timeline PTS with B-frame style decode reordering (pairs swapped); sorted by the index.
        var media = (0..<count).map { t(2002 + $0 * 1001) }
        for i in stride(from: 1, to: count - 1, by: 2) { media.swapAt(i, i + 1) }
        let shift = Segment(source: CMTimeRange(start: t(2002), duration: duration), target: CMTimeRange(start: .zero, duration: duration), isEmpty: false)
        let shifted = VideoSampleIndex.make(rawPTS: media, trackStart: .zero, segments: [shift])
        check("singleShiftedEditAccepted", shifted != nil)
        if let shifted {
            check("ptsConvertedExactlyToTrackTime", shifted.pts.first == .zero && shifted.pts[1] == t(1001) && shifted.pts.last == t((count - 1) * 1001))
            let found = (1..<count - 1).filter { shifted.repeats(sourceFrame: $0) }
            check("shiftedEditRepeatsFrames1And1002", found == [1, 1002], "repeated=\(found)")
            check("nextGenuinelyNewSampleIsNotARepeat", !shifted.repeats(sourceFrame: 1003) && !shifted.repeats(sourceFrame: 1001) && !shifted.repeats(sourceFrame: 2))
        }
        let earlier = (0..<count).map { t(1001 + $0 * 1001) } // one sample before the edit start (trimmed lead)
        check("editTrimmingLeadingSamplesUnavailable", VideoSampleIndex.make(rawPTS: earlier, trackStart: .zero, segments: [shift]) == nil)
        let longer = (0..<(count + 5)).map { t(2002 + $0 * 1001) } // samples after the edit end
        check("samplesAfterEditAreExcluded", VideoSampleIndex.make(rawPTS: longer, trackStart: .zero, segments: [shift])?.pts.count == count)
        let trackTimeline = (0..<count).map { t($0 * 1001) } // PTS already on the track timeline
        check("offsetNeverAppliedTwice", VideoSampleIndex.make(rawPTS: trackTimeline, trackStart: .zero, segments: [shift]) == nil)
        let unaligned = (0..<count).map { t(2003 + $0 * 1001) }
        check("unalignedSamplesUnavailable", VideoSampleIndex.make(rawPTS: unaligned, trackStart: .zero, segments: [shift]) == nil)
        check("multipleSegmentsUnavailable", VideoSampleIndex.make(rawPTS: media, trackStart: .zero, segments: [shift, shift]) == nil)
        check("emptyEditUnavailable", VideoSampleIndex.make(rawPTS: media, trackStart: .zero,
            segments: [Segment(source: shift.source, target: shift.target, isEmpty: true)]) == nil)
        check("non1xEditUnavailable", VideoSampleIndex.make(rawPTS: media, trackStart: .zero,
            segments: [Segment(source: shift.source, target: CMTimeRange(start: .zero, duration: t(count * 2002)), isEmpty: false)]) == nil)
        check("invalidMappingUnavailable", VideoSampleIndex.make(rawPTS: media, trackStart: .zero,
            segments: [Segment(source: CMTimeRange(start: .invalid, duration: duration), target: shift.target, isEmpty: false)]) == nil)
        check("noSegmentsUnavailable", VideoSampleIndex.make(rawPTS: media, trackStart: .zero, segments: []) == nil)
        let exact30 = (0..<400).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        let identityRange = CMTimeRange(start: .zero, duration: CMTime(value: 400, timescale: 30))
        let identity = VideoSampleIndex.make(rawPTS: exact30, trackStart: .zero,
            segments: [Segment(source: identityRange, target: identityRange, isEmpty: false)])
        check("identityEditUnchanged", identity != nil && (1..<399).allSatisfy { !(identity!.repeats(sourceFrame: $0)) })
        return checks
    }

    /// REAL-MEDIA-FIX-01 (B): bounded PCM chunk prefetch through the real scheduler with a counting provider.
    struct CountingPCM: SpectrumPCMProvider {
        let identity: SpectrumSourceIdentity
        let sampleRate = 48_000, channelCount = 2, chunkSamples = 48_000
        let delayNs: UInt64
        let decoded = OSAllocatedUnfairLock(initialState: [Int]())
        func decodeChunk(_ index: Int) async throws -> [[Float]] {
            decoded.withLock { $0.append(index) }
            try? await Task.sleep(nanoseconds: delayNs)
            return [[Float]](repeating: [Float](repeating: 0.01, count: chunkSamples), count: channelCount)
        }
    }
    static func analysisPrefetchChecks() async -> [Check] {
        var checks: [Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            checks.append(Check(name: "analysisPrefetch." + name, pass: pass, detail: detail))
        }
        let audio = Clip(mediaID: UUID(), start: 0, sourceIn: 0, length: 600, lane: Lane.audioID)
        let entry = SpectrumItem(lane: UUID(), start: 0, length: 600, sourceKey: audio.lineageKey)
        let timeline = Timeline(clips: [], audioClips: [audio], spectra: [entry], durationFrames: 600)
        let pieces = timeline.spectrumPieces(entry), settings = entry.style.analysisSettings
        func request(_ f: Int) -> SpectrumFrameRequest { SpectrumFrameRequest(frame: f, fps: 30, settings: settings, pieces: pieces) }
        func settled(_ s: SpectrumAnalysisScheduler) async -> Bool {
            await LaneSelfTest.waitUntil(5) { s.statistics.active == 0 }
        }
        let chunkBytes = 2 * 48_000 * MemoryLayout<Float>.size
        do {
            let s = SpectrumAnalysisScheduler(), p = CountingPCM(identity: .init("prefetch-a"), delayNs: 60_000_000)
            let first = s.prefetch(request(45), from: p)
            let duplicate = s.prefetch(request(45), from: p)
            check("startsOnceAndSkipsInFlight", first == 1 && duplicate == 0, "first=\(first) duplicate=\(duplicate)")
            let done = await settled(s)
            let st = s.statistics
            check("decodedIntoCache", done && st.prefetchDecodes == 1 && st.decodes == 1 && st.chunkCacheEntries == 1)
            check("cachedChunkIsNotPrefetchedAgain", s.prefetch(request(45), from: p) == 0)
            let bands = try? await s.bands(request(45), from: p)
            check("laterRequestUsesPrefetchedChunk", bands != nil && p.decoded.withLock { $0 } == [1], "decoded=\(p.decoded.withLock { $0 })")
            let direct = SpectrumAnalysisScheduler(), q = CountingPCM(identity: .init("prefetch-a"), delayNs: 0)
            let reference = try? await direct.bands(request(45), from: q)
            check("analysisResultUnchanged", reference != nil && reference == bands)
        }
        do {
            let s = SpectrumAnalysisScheduler(), p = CountingPCM(identity: .init("prefetch-b"), delayNs: 150_000_000)
            let waiting = Task { try? await s.bands(request(105), from: p) }
            _ = await LaneSelfTest.waitUntil(2) { s.statistics.pendingJobs > 0 }
            check("neverCompetesWithWaitingRequests", s.prefetch(request(165), from: p) == 0)
            _ = await waiting.value
        }
        do {
            let limits = SpectrumSchedulerLimits(chunkCacheBytes: chunkBytes)
            let s = SpectrumAnalysisScheduler(limits: limits), p = CountingPCM(identity: .init("prefetch-c"), delayNs: 10_000_000)
            _ = s.prefetch(request(165), from: p); _ = await settled(s)
            _ = s.prefetch(request(195), from: p); _ = await settled(s)
            let st = s.statistics
            check("respectsCacheBudget", st.chunkCacheEntries == 1 && st.chunkCacheBytes <= chunkBytes && st.peakChunkCacheBytes <= 2 * chunkBytes,
                  "entries=\(st.chunkCacheEntries) bytes=\(st.chunkCacheBytes)")
        }
        do {
            let s = SpectrumAnalysisScheduler(), p = CountingPCM(identity: .init("prefetch-d"), delayNs: 100_000_000)
            _ = s.prefetch(request(45), from: p)
            s.invalidateSession()
            _ = await settled(s)
            let st = s.statistics
            check("invalidatedPrefetchIsNeverCached", st.chunkCacheEntries == 0 && st.staleDecodes >= 1)
        }
        do {
            let s = SpectrumAnalysisScheduler()
            let old = CountingPCM(identity: .init("prefetch-e-old"), delayNs: 0), relinked = CountingPCM(identity: .init("prefetch-e-new"), delayNs: 0)
            _ = s.prefetch(request(45), from: old); _ = await settled(s)
            let again = s.prefetch(request(45), from: relinked)
            _ = await settled(s)
            check("relinkedSourceIsADifferentKey", again == 1 && relinked.decoded.withLock { $0 } == [1])
        }
        return checks
    }

    /// Deterministic transport/approval contract. Injected PTS values exercise the
    /// existing selector; this is not a native display-continuity measurement.
    static func transitionTransportChecks() async -> [Check] {
        var checks: [Check] = []
        func check(_ name: String, _ pass: Bool) {
            checks.append(Check(name: "transition." + name, pass: pass,
                detail: "transport identity and exact-frame approval; no old image carry"))
        }
        let media = UUID()
        let audio = Clip(mediaID: media, start: 0, sourceIn: 0, length: 120, lane: Lane.audioID)
        let entry = SpectrumItem(lane: UUID(), start: 0, length: 120, sourceKey: audio.lineageKey)
        let timeline = Timeline(clips: [Clip(mediaID: media, start: 0, sourceIn: 0, length: 120)],
                                audioClips: [audio], spectra: [entry], durationFrames: 120)
        let session = SpectrumPreviewSession(), controller = session.playback
        let view = PlayerNSView(), firstItem = AVPlayerItem(asset: AVMutableComposition())
        controller.prepareForTransition(item: firstItem, view: view)
        let output = controller.timing.output
        let time = CMTime(value: 30, timescale: 30)
        func approve(_ display: CMTime) -> Int? {
            controller.timing.sample(requested: time, timeline: timeline, hasNewBuffer: true) { value in
                value = display; return true
            }
        }
        check("matchingPTSInitiallyApproved", approve(time) == 30 && controller.timing.confirmedPTSForTest == time)
        controller.advance(frame: 30, timeline: timeline)
        controller.prepareForTransition(item: firstItem, view: view)
        check("sameItemKeepsSingleOutput", output != nil && controller.timing.output === output && firstItem.outputs.count == 1)
        check("prepareRevokesAllPresentationAndApproval", controller.currentFrame == nil && controller.retainedCount == 0 &&
              controller.retainedBytes == 0 && !controller.timing.confirmedPTSForTest.isNumeric)
        let reused = controller.timing.sample(requested: time, timeline: timeline, hasNewBuffer: false) { _ in false }
        check("priorFrameIsNotReapprovedWithoutBuffer", reused == nil)
        check("wrongDisplayPTSStillRejected", approve(CMTime(value: 29, timescale: 30)) == nil)
        check("newMatchingBufferCanApprove", approve(time) == 30)
        session.update(timeline: timeline, media: [])
        check("sessionRevisionKeepsTransportButRevokesApproval", controller.timing.output === output &&
              controller.currentFrame == nil && controller.retainedCount == 0 && !controller.timing.confirmedPTSForTest.isNumeric)
        var unavailable: SpectrumFrameOutcome?
        _ = session.request(spectrum: entry.id, frame: 30, checkPlaybackMedia: true) { unavailable = $0 }
        let delivered = await LaneSelfTest.waitUntil(10) { unavailable != nil }
        if case let .mediaUnavailable(id)? = unavailable { check("unavailableSourceStillRejected", delivered && id == media) }
        else { check("unavailableSourceStillRejected", false) }
        let secondItem = AVPlayerItem(asset: AVMutableComposition())
        controller.prepareForTransition(item: secondItem, view: view)
        check("differentItemRetiresPriorOutput", !firstItem.outputs.contains { $0 === output } &&
              controller.timing.item === secondItem && secondItem.outputs.count == 1)
        session.resetProject()
        check("projectResetDetachesTransport", secondItem.outputs.isEmpty && controller.timing.output == nil &&
              controller.timing.item == nil && !controller.timing.confirmedPTSForTest.isNumeric)

        let store = ProjectStore(), host = PlayerNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; store.previewHost = host
        let item = AVPlayerItem(asset: AVMutableComposition()), playback = store.spectrumPreview.playback
        store.player.replaceCurrentItem(with: item)
        playback.prepareForTransition(item: item, view: host)
        let pendingOutput = playback.timing.output
        host.subtitleSeekRequested(token: store.seekToken, frame: 30)
        playback.advance(frame: 30, timeline: timeline)
        store.sampleSpectrumPlayback(hostTime: ProcessInfo.processInfo.systemUptime)
        check("pendingSeekRetiresTransportAndApproval", host.hasPendingSpectrumSeek &&
              pendingOutput != nil && playback.timing.output == nil && playback.timing.item == nil &&
              item.outputs.isEmpty && playback.currentFrame == nil &&
              playback.retainedCount == 0 && !playback.timing.confirmedPTSForTest.isNumeric && host.spectrumOverlay.layers.isEmpty)
        host.subtitleSeekFinished(token: store.seekToken, frame: 30, finished: false)
        playback.prepareForTransition(item: item, view: host)
        let nilReplacementHadOutput = playback.timing.output != nil && item.outputs.count == 1
        store.player.replaceCurrentItem(with: nil)
        store.sampleSpectrumPlayback(hostTime: ProcessInfo.processInfo.systemUptime)
        check("nilCurrentItemDetachesOldTransport", nilReplacementHadOutput && item.outputs.isEmpty && playback.timing.output == nil)
        store.previewHost = nil; store.resetProject(); window.close()

        let heldSession = SpectrumPreviewSession(), held = heldSession.playback, delivery = Delivery()
        let heldItem = AVPlayerItem(asset: AVMutableComposition())
        held.prepareForTransition(item: heldItem, view: view)
        let heldOutput = held.timing.output
        heldSession.transformOutcomeForTest = { id, frame, _ in await delivery.hold(id, frame) }
        held.advance(frame: 30, timeline: timeline)
        let waiting = await LaneSelfTest.waitUntil(10) { delivery.waiting.count == 3 }
        heldSession.update(timeline: timeline, media: [])
        delivery.release(entry.id, 30, .ready(bands: [], frame: nil))
        heldSession.transformOutcomeForTest = nil; delivery.releaseAll()
        let drained = await LaneSelfTest.waitUntil(10) { held.pendingCount == 0 }
        check("sourceRevisionRejectsHeldReadyWhileKeepingTransport", waiting && drained &&
              held.currentFrame == nil && held.retainedCount == 0 && held.metrics.stale > 0 && held.timing.output === heldOutput)
        heldSession.resetProject()
        check("heldSessionResetReleasesOutput", heldItem.outputs.isEmpty && held.timing.output == nil)
        return checks
    }

    // Reuse the 17 checks; stderr completion lets the direct parent own shutdown.
    static func runDirectStartupContract(runID: UUID) {
        let store = ProjectStore.shared
        func ownsEmptySession() -> Bool {
            store.projectSession == 0 && store.projectURL == nil && store.timeline.isEmpty &&
                !store.isDirty && !store.openRequested && store.openProgress == nil &&
                store.importProgress == nil && store.exportPhase == .idle
        }
        guard admittedRun == nil, ownsEmptySession() else {
            StillFrameParitySelfTest.phase(runID, "regressionComplete", fields: ["checks": [], "mayStopChild": false])
            return
        }
        admittedRun = runID
        let checks = startupFrameSelection()
        let rows = checks.map { ["name": $0.name, "pass": $0.pass, "detail": $0.detail] as [String: Any] }
        StillFrameParitySelfTest.phase(runID, "regressionComplete", fields: ["checks": rows,
            "mayStopChild": admittedRun == runID && ownsEmptySession()])
    }

    private static var admittedRun: UUID?

    static func run(folder: URL) async {
        // One admission per dedicated process. A second open-folder event cannot take ownership.
        let runID = UUID()
        let shared = ProjectStore.shared
        let admittedView = shared.previewHost
        let admittedProject = shared.projectID, admittedGeneration = shared.generation
        func ownsEmptySession() -> Bool {
            shared.projectID == admittedProject && shared.projectSession == 0 &&
                shared.generation == admittedGeneration && shared.previewHost === admittedView &&
                shared.projectURL == nil && shared.timeline.isEmpty && !shared.isDirty &&
                !shared.openRequested && shared.openProgress == nil && shared.importProgress == nil &&
                shared.exportPhase == .idle
        }
        func failure(_ message: String) {
            let fields = ["status": "FAIL", "runID": runID.uuidString, "error": message]
            if let data = try? JSONEncoder().encode(fields) {
                FileHandle.standardError.write(data + Data([10]))
            }
        }
        guard admittedRun == nil, ownsEmptySession() else {
            failure("duplicate invocation or nonempty/unavailable application session")
            return
        }
        admittedRun = runID
        var checks = startupFrameSelection()
        func persist(_ filename: String) -> Bool {
            guard admittedRun == runID, ownsEmptySession() else {
                failure("application session replaced")
                return false
            }
            do {
                let data = try JSONEncoder().encode(checks)
                try data.write(to: folder.appendingPathComponent(filename), options: .withoutOverwriting)
                return true
            } catch {
                failure("result persistence failed: " + String(describing: error))
                return false
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-OTFStartupFrameContract") {
            _ = persist("startup-contract.json")
            // The launching runner owns its child process and handles its lifetime.
            return
        }
        checks.append(contentsOf: await transitionTransportChecks())
        checks.append(contentsOf: startupRegressionChecks())
        checks.append(contentsOf: videoSampleIndexChecks())
        checks.append(contentsOf: await analysisPrefetchChecks())
        checks.append(contentsOf: await temporaryTimingChecks(audioURL: folder.appendingPathComponent("sources/aud-wav48s.wav")))
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
        let gap = Timeline(clips: [Clip(mediaID: media, start: 60, sourceIn: 0, length: 60)], audioClips: timeline.audioClips, durationFrames: 180)
        check("timing.videoGapUnknown", SpectrumPlaybackTiming.select(requested: time, display: time, timeline: gap) == nil)
        check("timing.tailAtBoundary", SpectrumPlaybackTiming.audioIntervalFrame(at: CMTime(value: 120, timescale: 30), timeline: timeline) == 120)
        check("timing.noTailInsideVideo", SpectrumPlaybackTiming.audioIntervalFrame(at: time, timeline: timeline) == nil)
        check("timing.noLeadInWithoutSelection", SpectrumPlaybackTiming.audioIntervalFrame(at: time, timeline: gap) == nil)
        let selected = SpectrumItem(lane: lane, start: 0, length: 180, sourceKey: timeline.audioClips[0].lineageKey)
        let lead = Timeline(clips: gap.clips, audioClips: timeline.audioClips, spectra: [selected], durationFrames: 180)
        check("timing.selectedLeadIn", SpectrumPlaybackTiming.audioIntervalFrame(at: time, timeline: lead) == 30)
        check("timing.firstVideoOwnsBoundary", SpectrumPlaybackTiming.audioIntervalFrame(at: CMTime(value: 60, timescale: 30), timeline: lead) == nil)
        let unrelated = SpectrumItem(lane: lane, start: 0, length: 180, sourceKey: UUID())
        check("timing.unrelatedAudioCannotDriveLeadIn", !SpectrumPlaybackTiming.hasActiveSource(unrelated, at: 30, timeline: lead))
        let laterAudio = Clip(mediaID: media, start: 45, sourceIn: 0, length: 15)
        let laterSpectrum = selected.with(id: UUID(), sourceKey: .some(laterAudio.lineageKey))
        let mixedLead = Timeline(clips: lead.clips, audioClips: lead.audioClips + [laterAudio],
                                 spectra: [selected, laterSpectrum], durationFrames: 180)
        let leadSession = SpectrumPreviewSession()
        leadSession.playback.advance(frame: 30, timeline: mixedLead)
        check("schedule.leadInRequestsOnlyActiveLineage", leadSession.playback.pendingCount == 3)
        leadSession.playback.stop()
        check("timing.audioOnlyWithoutSelection", SpectrumPlaybackTiming.audioIntervalFrame(at: tail, timeline: audioOnly) == nil)
        let pure = Timeline(audioClips: timeline.audioClips, spectra: [selected], durationFrames: 180)
        check("timing.selectedAudioOnly", SpectrumPlaybackTiming.audioIntervalFrame(at: time, timeline: pure) == 30)
        check("timing.audioOnlyEnd", SpectrumPlaybackTiming.audioIntervalFrame(at: CMTime(value: 180, timescale: 30), timeline: pure) == nil)
        let pureMixed = Timeline(audioClips: mixedLead.audioClips, spectra: mixedLead.spectra, durationFrames: 180)
        let pureSession = SpectrumPreviewSession()
        pureSession.playback.advance(frame: 30, timeline: pureMixed)
        check("schedule.audioOnlyActiveLineage", pureSession.playback.pendingCount == 3)
        pureSession.playback.stop()
        check("timing.noTailAtEnd", SpectrumPlaybackTiming.audioIntervalFrame(at: CMTime(value: 180, timescale: 30), timeline: timeline) == nil)
        let boundedClips = [Clip(mediaID: media, start: 0, sourceIn: 0, length: 30),
                            Clip(mediaID: media, start: 60, sourceIn: 0, length: 60)]
        let boundedGap = Timeline(clips: boundedClips, audioClips: timeline.audioClips, durationFrames: 180)
        check("timing.gapStart", SpectrumPlaybackTiming.audioIntervalFrame(at: time, timeline: boundedGap) == 30)
        check("timing.returnToVideo", SpectrumPlaybackTiming.audioIntervalFrame(at: CMTime(value: 60, timescale: 30), timeline: boundedGap) == nil)
        check("timing.gapWithoutAudio", SpectrumPlaybackTiming.audioIntervalFrame(at: time, timeline: Timeline(clips: boundedClips, durationFrames: 180)) == nil)
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
        let many = Timeline(audioClips: timeline.audioClips, spectra: (0..<20).map { _ in SpectrumItem(lane: UUID(), start: 0, length: 180, sourceKey: timeline.audioClips[0].lineageKey) }, durationFrames: 180)
        c.advance(frame: 20, timeline: many)
        check("schedule.manyItemsBound", c.pendingCount == 8)
        _ = await wait { c.pendingCount == 0 }
        check("schedule.terminalUnavailableNoImage", c.retainedCount == 0)
        c.stop()
        session.resetProject() // Switching from the audio-only fixture back to video changes the project identity.

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
            check("timing.unavailableHidesBoundedImages", c.currentFrame == nil && c.retainedCount > 0
                  && c.currentOutcome(spectrum: id, frame: 60) == nil && c.retainedBytes <= PlaybackSpectrumController.byteLimit)
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
        if persist("spectrum-playback-result.json"), admittedRun == runID, ownsEmptySession() {
            NSApp.terminate(nil)
        }
    }

    /// Nil revokes presentation, not the identity of otherwise eligible work.
    /// Controlled terminal delivery tests lifetime fences independently of timing.
    static func temporaryTimingChecks(audioURL: URL) async -> [Check] {
        var checks: [Check] = []
        func check(_ name: String, _ pass: Bool) {
            checks.append(Check(name: "temporaryTiming." + name, pass: pass, detail: "bounded retention; no unverified presentation"))
        }
        let h = Controlled(), id = h.ids[0]
        h.c.advance(frame: 60, timeline: h.timeline)
        check("pendingSetup", await h.waiting(id, 60))
        let requests = h.c.metrics.requested, cancelled = h.c.metrics.cancelled
        for _ in 0..<1000 { h.c.advance(frame: nil, timeline: h.timeline) }
        check("nilPreservesEligibleWork", h.c.currentFrame == nil && h.c.pendingCount == 3
              && h.c.metrics.requested == requests && h.c.metrics.cancelled == cancelled)
        h.send(id, 60, .ready(bands: [], frame: nil))
        check("completionRetainedWhileHidden", await LaneSelfTest.waitUntil(10) { h.c.retainedCount == 1 })
        check("nilCannotExposeRetainedOutcome", h.c.currentOutcome(spectrum: id, frame: 60) == nil)
        h.c.advance(frame: 60, timeline: h.timeline)
        check("sameFrameRecoversWithoutNewRequest", await LaneSelfTest.waitUntil(10) {
            h.c.currentOutcome(spectrum: id, frame: 60) != nil && h.count(id, 60) == 1
        })
        check("noDuplicateWorkAfterRecovery", h.c.metrics.requested == requests)
        h.c.advance(frame: nil, timeline: h.timeline)
        h.c.advance(frame: 90, timeline: h.timeline)
        check("differentFrameNeverUsesOldOutcome", h.c.currentOutcome(spectrum: id, frame: 60) == nil
              && h.c.currentOutcome(spectrum: id, frame: 90) == nil)
        await h.close()

        for boundary in ["newSeekStop", "sourceRevision", "projectReset", "invalidFrame"] {
            let x = Controlled(), sid = x.ids[0]
            x.c.advance(frame: 40, timeline: x.timeline)
            check(boundary + "Setup", await x.waiting(sid, 40))
            x.c.advance(frame: nil, timeline: x.timeline)
            switch boundary {
            case "sourceRevision": x.session.update(timeline: x.timeline, media: [])
            case "projectReset": x.session.resetProject()
            case "invalidFrame": x.c.advance(frame: x.timeline.durationFrames, timeline: x.timeline)
            default: x.c.stop()
            }
            x.session.transformOutcomeForTest = nil
            x.delivery.releaseAll()
            check(boundary + "RejectsLateResults", await LaneSelfTest.waitUntil(10) {
                x.c.pendingCount == 0 && x.c.currentFrame == nil && x.c.retainedCount == 0
            })
            await x.close()
        }

        do {
            // Mutate only this disposable copy; the regression fixture is read-only.
            let copy = audioURL.deletingLastPathComponent().appendingPathComponent("nil-source-" + UUID().uuidString + ".wav")
            try FileManager.default.copyItem(at: audioURL, to: copy)
            let media = try await MediaProbe.inspect(copy), session = SpectrumPreviewSession(), delivery = Delivery()
            var timeline = try Timeline().registering(media).placing(media: media.id, at: 0, videoLane: nil, audioLane: Lane.audioID)
            timeline = try timeline.addingSpectrum(fromAudioClip: timeline.audioClips[0].id, newLaneName: "SP")
            let sid = timeline.spectra[0].id, c = session.playback
            session.update(timeline: timeline, media: [media])
            // Configured sessions delay real outcomes; they never substitute them.
            session.transformOutcomeForTest = { id, frame, _ in await delivery.hold(id, frame) }
            c.advance(frame: 60, timeline: timeline)
            check("realPendingSetup", await LaneSelfTest.waitUntil(10) { delivery.waiting.count == 3 })
            c.advance(frame: nil, timeline: timeline)
            delivery.releaseAll()
            check("realImagesRetainedDuringNil", await LaneSelfTest.waitUntil(10) { c.pendingCount == 0 && c.retainedBytes > 0 })
            let requestCount = c.metrics.requested
            c.advance(frame: 60, timeline: timeline)
            check("realRecoveryRevalidatesSource", await LaneSelfTest.waitUntil(10) {
                if case .ready(_, .some)? = c.currentOutcome(spectrum: sid, frame: 60) { return true }
                return false
            })
            check("realRecoveryAvoidsDuplicateRequest", c.metrics.requested == requestCount && c.metrics.sourceRevalidations > 0)
            c.advance(frame: nil, timeline: timeline)
            let file = try FileHandle(forWritingTo: copy); try file.seekToEnd(); try file.write(contentsOf: Data([0])); try file.close()
            c.advance(frame: 60, timeline: timeline)
            check("changedSourceRejectedOnRecovery", await LaneSelfTest.waitUntil(10) {
                if case .mediaUnavailable? = c.currentOutcome(spectrum: sid, frame: 60) { return true }
                return false
            })
            check("failedSourceDropsRasterBytes", c.metrics.sourceRejections == 1
                  && c.currentFrame == 60 && c.retainedBytes <= PlaybackSpectrumController.byteLimit)
            check("retentionBounds", c.pendingCount <= 8 && c.retainedCount <= 8
                  && c.retainedBytes <= PlaybackSpectrumController.byteLimit && c.metrics.peakBytes <= PlaybackSpectrumController.byteLimit)
            c.stop()
            check("definitiveStopReleasesRetainedBytes", c.currentFrame == nil && c.retainedCount == 0 && c.retainedBytes == 0)
            session.transformOutcomeForTest = nil; delivery.releaseAll(); session.resetProject()
        } catch { check("realFixture", false) }
        return checks
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
            let audio = Clip(mediaID: UUID(), start: 0, sourceIn: 0, length: 180)
            let timeline = Timeline(audioClips: [audio], spectra: [SpectrumItem(id: id, lane: UUID(), start: 0, length: 180, sourceKey: audio.lineageKey)], durationFrames: 180)
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
            let audio = Clip(mediaID: UUID(), start: 0, sourceIn: 0, length: 180)
            timeline = Timeline(audioClips: [audio], spectra: ids.map { SpectrumItem(id: $0, lane: UUID(), start: 0, length: 180, sourceKey: audio.lineageKey) }, durationFrames: 180)
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
