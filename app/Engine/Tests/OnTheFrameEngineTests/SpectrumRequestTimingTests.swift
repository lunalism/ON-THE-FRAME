#if DEBUG
import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import XCTest

final class SpectrumRequestTimingTests: XCTestCase {
    private typealias Capture = SpectrumRequestTimingCapture
    private typealias Timing = SpectrumRequestTiming
    private let width = 1920, height = 1080

    // Deterministic changing input, with the 64-band horizontal style from the PILOT-02 fixture.
    private struct SweepPCM: SpectrumPCMProvider {
        let identity = SpectrumSourceIdentity("timing-test-sweep-48000")
        let sampleRate = 48_000, chunkSamples = 24_000, channelCount = 1

        func decodeChunk(_ index: Int) async throws -> [[Float]] {
            let samples: [Float] = (0..<chunkSamples).map { i in
                let t = Double(index * chunkSamples + i) / Double(sampleRate)
                let phase = 2 * Double.pi * (90 * t + 280 * t * t)
                return Float(0.45 * sin(phase) + 0.2 * sin(1.72 * phase))
            }
            return [samples]
        }
    }

    private struct Fixture {
        let coordinator: SpectrumFrameCoordinator
        let timeline: Timeline
        let item: SpectrumItem
    }

    private func fixture(strength: Int, provider: any SpectrumPCMProvider) throws -> Fixture {
        let source = SourceTiming(sampleCount: 60, isVariable: false, frameDurationValue: 1, frameDurationTimescale: 30,
                                  averageFPS: 30, minInterval: 1.0/30, maxInterval: 1.0/30)
        let asset = MediaAsset(id: UUID(), url: URL(fileURLWithPath: "/timing-test.wav"), name: "Timing test",
                               frameCount: 60, timing: source, naturalSize: .zero, displaySize: .zero,
                               preferredTransform: .identity, hasAudio: true, codec: "pcm",
                               identity: .init(device: 0, inode: 1, size: 0, modifiedNs: 0), hasVideo: false,
                               audioSampleRate: 48_000, audioSampleCount: 96_000, audioChannels: 1)
        var style = SpectrumItemStyle.provisionalDefault
        style.maxHeightMilli = 220_000
        style.red = 255; style.green = 165; style.blue = 40; style.alpha = 232
        style.outsideRGB = .init(red: 27, green: 145, blue: 255)
        style.hueInterpolationDegrees = 180
        style.reactionPercent = 150
        style.softnessPercent = strength
        let clipID = UUID()
        let timeline = try Timeline().registering(asset)
            .placing(media: asset.id, at: 0, videoLane: nil, audioLane: Lane.audioID, clipID: clipID)
            .addingSpectrum(fromAudioClip: clipID, style: style, newLaneName: "Spectrum")
        let coordinator = SpectrumFrameCoordinator(deliveryQueue: .main, digitalSoftnessPreviewPilot: true) { _ in provider }
        coordinator.update(timeline: timeline, media: [asset])
        return Fixture(coordinator: coordinator, timeline: timeline, item: try XCTUnwrap(timeline.spectra.first))
    }

    // The app-only session/controller are represented by these terminal markers.
    // All stages before delivery come from the real coordinator, scheduler and renderer.
    private static func received(_ timing: Timing?, _ result: SpectrumFrameOutcome) {
        timing?.mark(.deliveryInvoked)
        timing?.mark(.sessionReceived)
        timing?.mark(.controllerCallback, outcome: result.playbackTraceCode)
        timing?.mark(.slotReleased)
    }

    private struct Sample {
        let milliseconds: Double
        let bands: [Float]
        let frame: SpectrumRenderedFrame
        let timing: Timing?
    }

    @MainActor private func sample(_ fixture: Fixture, frame: Int, capture: Capture?) async throws -> Sample {
        let start = DispatchTime.now().uptimeNanoseconds
        let timing = capture?.begin(frame: frame)
        let (result, end): (SpectrumFrameOutcome, UInt64) = await withCheckedContinuation { continuation in
            let complete: SpectrumFrameCoordinator.Completion = { result in
                Self.received(timing, result)
                continuation.resume(returning: (result, DispatchTime.now().uptimeNanoseconds))
            }
            if let timing {
                fixture.coordinator.request(spectrum: fixture.item.id, frame: frame, canvasWidth: width, canvasHeight: height,
                                            priority: 0, playbackObserver: nil, timing: timing, completion: complete)
            } else {
                fixture.coordinator.request(spectrum: fixture.item.id, frame: frame, canvasWidth: width, canvasHeight: height,
                                            completion: complete)
            }
        }
        if capture != nil { XCTAssertNotNil(timing, "An enabled measurement must have a row") }
        guard case let .ready(bands, image?) = result else {
            throw NSError(domain: "SpectrumRequestTimingTests", code: Int(result.playbackTraceCode))
        }
        return Sample(milliseconds: Double(end - start) / 1_000_000, bands: bands, frame: image, timing: timing)
    }

    private func equalPixels(_ a: SpectrumRenderedFrame, _ b: SpectrumRenderedFrame,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(a.drawRect, b.drawRect, file: file, line: line)
        XCTAssertEqual(a.canvasWidth, b.canvasWidth, file: file, line: line)
        XCTAssertEqual(a.canvasHeight, b.canvasHeight, file: file, line: line)
        XCTAssertEqual(a.image.width, b.image.width, file: file, line: line)
        XCTAssertEqual(a.image.height, b.image.height, file: file, line: line)
        for frame in [a, b] {
            XCTAssertEqual(frame.image.alphaInfo, .premultipliedFirst, file: file, line: line)
            XCTAssertTrue(frame.image.bitmapInfo.contains(.byteOrder32Little), file: file, line: line)
            XCTAssertEqual(frame.image.bytesPerRow, 4 * frame.image.width, file: file, line: line)
        }
        let left = try XCTUnwrap(a.image.dataProvider?.data, file: file, line: line) as Data
        let right = try XCTUnwrap(b.image.dataProvider?.data, file: file, line: line) as Data
        XCTAssertEqual(left.count, a.image.height * a.image.bytesPerRow, file: file, line: line)
        XCTAssertTrue(left == right, "Cropped premultiplied BGRA differs", file: file, line: line)
    }

    @MainActor func testOptInRequiresStandaloneImageSelfTestAndExactArgument() {
        let mode = "-OTFImageSpectrumTest", flag = "-OTFSpectrumRequestTiming"
        for args in [[], [mode], [flag], [mode, flag + "X"], [mode, flag, "-OTFSpectrumContinuityTrace"],
                     [mode, flag, "-OTFOwnerSpectrumPlaybackTrace"]] {
            XCTAssertFalse(Capture.enabled(arguments: args))
        }
        XCTAssertTrue(Capture.enabled(arguments: [mode, flag]))
    }

    @MainActor func testRecorderBoundsIDsSelectionAndLateCompletion() throws {
        let capture = Capture(capacity: 1_000)
        XCTAssertNil(capture.begin(frame: -1)); XCTAssertNil(capture.begin(frame: 120))
        for index in 0..<256 {
            let row = try XCTUnwrap(capture.begin(frame: index % 120))
            XCTAssertEqual(row.id, Int64(index + 1))
        }
        XCTAssertNil(capture.begin(frame: 119))
        capture.endSelection()
        XCTAssertNil(capture.begin(frame: 1))
        let full = capture.report()
        XCTAssertEqual(full.capacity, 256); XCTAssertEqual(full.rows.count, 256)
        XCTAssertEqual(full.overflow, 1); XCTAssertEqual(full.outsideWindow, 2)
        XCTAssertEqual(full.incomplete, 256); XCTAssertFalse(full.complete)
        XCTAssertLessThanOrEqual(try capture.encodedReport().count, Capture.byteLimit)
        XCTAssertNil(capture.request(id: 0)); XCTAssertNil(capture.request(id: Int64.max))

        let one = Capture(capacity: 0)
        let request = try XCTUnwrap(one.begin(frame: 119, priority: 2, serial: 3, epoch: 4, revision: 5))
        one.endSelection()
        XCTAssertEqual(one.report().capacity, 1)
        XCTAssertFalse(one.report().complete)
        XCTAssertTrue(one.request(id: request.id) === request)
        let initial = request.snapshot()
        XCTAssertEqual(initial.frame, 119); XCTAssertEqual(initial.priority, 2); XCTAssertEqual(initial.serial, 3)
        XCTAssertEqual(initial.epoch, 4); XCTAssertEqual(initial.revision, 5)
        request.mark(.coordinatorEnqueued); request.mark(.coordinatorStarted)
        request.add(.baseGeometry, nanoseconds: 13); request.add(.baseGeometry, nanoseconds: 8)
        request.mark(.coordinatorFinished, outcome: 7)
        let firstStamp = request.snapshot()[.coordinatorFinished]
        request.mark(.coordinatorFinished, outcome: 99)
        request.mark(.deliveryInvoked); request.mark(.sessionReceived)
        request.mark(.controllerCallback, outcome: 7); request.mark(.slotReleased)
        let final = request.snapshot()
        XCTAssertNil(initial[.baseGeometry]); XCTAssertEqual(final[.baseGeometry], 21)
        XCTAssertEqual(final[.coordinatorFinished], firstStamp); XCTAssertEqual(final.coordinatorOutcome, 7)
        XCTAssertTrue(one.report().complete)
    }

    @MainActor func testCancelledAndReadyRequestsForSameFrameRemainDistinct() async throws {
        let pcm = SpectrumFrameCoordinatorTests.TonePCM(gated: true)
        let fx = try fixture(strength: 50, provider: pcm)
        defer { pcm.release(); fx.coordinator.resetProject() }
        let capture = Capture()
        let old = try XCTUnwrap(capture.begin(frame: 42, serial: 10, epoch: 7, revision: 2))
        let new = try XCTUnwrap(capture.begin(frame: 42, serial: 11, epoch: 7, revision: 2))
        let cancelled = expectation(description: "first request cancelled once")
        cancelled.assertForOverFulfill = true
        let ticket = fx.coordinator.request(spectrum: fx.item.id, frame: 42, canvasWidth: width, canvasHeight: height,
                                           priority: 0, playbackObserver: nil, timing: old) { outcome in
            Self.received(old, outcome)
            XCTAssertEqual(outcome.playbackTraceCode, SpectrumFrameOutcome.cancelled.playbackTraceCode)
            cancelled.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while pcm.started == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard pcm.started > 0 else { return XCTFail("Decoder never reached its gate") }
        let ready = expectation(description: "second request for the same frame completes once")
        ready.assertForOverFulfill = true
        fx.coordinator.request(spectrum: fx.item.id, frame: 42, canvasWidth: width, canvasHeight: height,
                               priority: 0, playbackObserver: nil, timing: new) { outcome in
            Self.received(new, outcome)
            guard case .ready(_, .some) = outcome else { XCTFail("Replacement didn't render"); ready.fulfill(); return }
            ready.fulfill()
        }
        old.mark(.cancellationRequested)
        fx.coordinator.cancel(ticket)
        _ = fx.coordinator.diagnostics
        pcm.release()
        await fulfillment(of: [cancelled, ready], timeout: 10)
        capture.endSelection()
        let report = capture.report()
        XCTAssertTrue(report.complete); XCTAssertEqual(report.rows.map(\.frame), [42, 42])
        XCTAssertEqual(report.rows.map(\.serial), [10, 11]); XCTAssertNotEqual(old.id, new.id)
        let a = old.snapshot(), b = new.snapshot()
        XCTAssertEqual(a.coordinatorOutcome, 3); XCTAssertEqual(a.controllerOutcome, 3)
        XCTAssertNotNil(a[.coordinatorCancelled]); XCTAssertNil(a[.rasterStarted]); XCTAssertNil(a[.ownedImage])
        XCTAssertEqual(b.coordinatorOutcome, 1); XCTAssertEqual(b.controllerOutcome, 1)
        XCTAssertNil(b[.cancellationRequested]); XCTAssertNil(b[.coordinatorCancelled]); XCTAssertNotNil(b[.ownedImage])
        for row in [a, b] {
            let stages: [Timing.Stage] = [.coordinatorEnqueued, .coordinatorStarted, .analysisSubmitted, .analysisReady, .analysisCallbackStarted]
            let stamps = try stages.map { try XCTUnwrap(row[$0]) }
            XCTAssertEqual(stamps, stamps.sorted())
        }
    }

    private struct Percentiles {
        let median: Double
        let p95: Double
        init(_ samples: [Double]) {
            let sorted = samples.sorted(), n = sorted.count
            median = (sorted[(n-1)/2] + sorted[n/2]) / 2
            p95 = sorted[Int(ceil(0.95 * Double(n))) - 1]
        }
    }

    @MainActor func testMatchedFHD64DigitalTimingOverheadAndExactRaster() async throws {
        for strength in [0, 50] {
            let fx = try fixture(strength: strength, provider: SweepPCM())
            defer { fx.coordinator.resetProject() }
            let frames = Array(30..<50)
            let reference = try SpectrumFrameRenderer(width: width, height: height)
            let capture = Capture()
            let initialStyle = fx.item.style, initialSource = fx.item.sourceKey
            // Fill the real band cache before the paired measurements; every draw still repaints the geometry.
            for frame in frames { _ = try await sample(fx, frame: frame, capture: nil) }
            var mediansExceeded = 0, tailsExceeded = 0
            for round in 0..<2 {
                for frame in frames.prefix(2) {
                    _ = try await sample(fx, frame: frame, capture: round == 0 ? nil : capture)
                    _ = try await sample(fx, frame: frame, capture: round == 0 ? capture : nil)
                }
                var off: [Double] = [], on: [Double] = []
                var priorBands: [Float]?, changes = 0
                for (i, frame) in (round == 0 ? frames : Array(frames.reversed())).enumerated() {
                    // Reversing both the frame order and its role order balances first-draw/cache effects.
                    let enabledFirst = (frame + round).isMultiple(of: 2)
                    let first = try await sample(fx, frame: frame, capture: enabledFirst ? capture : nil)
                    let second = try await sample(fx, frame: frame, capture: enabledFirst ? nil : capture)
                    let (enabled, disabled) = enabledFirst ? (first, second) : (second, first)
                    on.append(enabled.milliseconds); off.append(disabled.milliseconds)
                    XCTAssertNil(disabled.timing)
                    let row = try XCTUnwrap(enabled.timing).snapshot()
                    XCTAssertEqual(row.frame, frame); XCTAssertEqual(enabled.bands.count, 64)
                    XCTAssertTrue(enabled.bands == disabled.bands)
                    if let priorBands, priorBands != enabled.bands { changes += 1 }
                    priorBands = enabled.bands
                    try equalPixels(enabled.frame, disabled.frame)
                    if i == 0 {
                        let independent = try XCTUnwrap(reference.render(bands: enabled.bands, style: initialStyle,
                                                                         experimentalSoftnessPercent: strength))
                        try equalPixels(enabled.frame, independent)
                    }
                    let milestones: [Timing.Stage] = [.coordinatorEnqueued, .coordinatorStarted, .analysisSubmitted,
                        .analysisReady, .analysisCallbackStarted, .rasterStarted, .rasterFinished, .coordinatorFinished,
                        .deliveryInvoked, .sessionReceived, .controllerCallback, .slotReleased]
                    let stamps = try milestones.map { try XCTUnwrap(row[$0]) }
                    XCTAssertEqual(stamps, stamps.sorted())
                    for stage in [Timing.Stage.baseGeometry, .baseColor, .tightCrop, .ownedImage] {
                        XCTAssertGreaterThan(try XCTUnwrap(row[stage]), 0)
                    }
                    for stage in [Timing.Stage.coverageMask, .distanceForward, .distanceReverse, .attenuation] {
                        if strength == 0 { XCTAssertNil(row[stage]) } else { XCTAssertGreaterThan(try XCTUnwrap(row[stage]), 0) }
                    }
                }
                XCTAssertEqual(changes, frames.count - 1)
                let base = Percentiles(off), timed = Percentiles(on)
                if timed.median > 1.05 * base.median && timed.median - base.median > 0.25 { mediansExceeded += 1 }
                if timed.p95 > 1.10 * base.p95 && timed.p95 - base.p95 > 0.5 { tailsExceeded += 1 }
                print(String(format: "SPECTRUM_TIMING_OVERHEAD strength=%d round=%d pairs=%d offMedianMs=%.4f onMedianMs=%.4f offP95Ms=%.4f onP95Ms=%.4f medianRatio=%.4f p95Ratio=%.4f",
                             strength, round+1, on.count, base.median, timed.median, base.p95, timed.p95,
                             timed.median/base.median, timed.p95/base.p95))
            }
            capture.endSelection()
            XCTAssertTrue(capture.report().complete)
            XCTAssertEqual(capture.report().rows.count, 44)
            XCTAssertEqual(fx.timeline.spectrum(fx.item.id)?.style, initialStyle)
            XCTAssertEqual(fx.timeline.spectrum(fx.item.id)?.sourceKey, initialSource)
            XCTAssertLessThan(mediansExceeded, 2, "Both matched rounds crossed the median overhead threshold at \(strength)%")
            XCTAssertLessThan(tailsExceeded, 2, "Both matched rounds crossed the p95 overhead threshold at \(strength)%")
        }
    }
}
#endif
