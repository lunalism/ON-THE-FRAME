#if DEBUG
import CoreGraphics
import CryptoKit
import Foundation
@testable import OnTheFrameEngine
import XCTest

final class SpectrumDigitalSoftnessPreviewPilotTests: XCTestCase {
    private typealias PCM = SpectrumFrameCoordinatorTests.TonePCM
    private let width = 1920, height = 1080, frame = 42

    private func fixture() throws -> (timeline: Timeline, asset: MediaAsset, item: SpectrumItem) {
        let timing = SourceTiming(sampleCount: 60, isVariable: false, frameDurationValue: 1,
                                  frameDurationTimescale: 30, averageFPS: 30, minInterval: 1.0/30, maxInterval: 1.0/30)
        let asset = MediaAsset(id: UUID(), url: URL(fileURLWithPath: "/digital-pilot-fixture.wav"), name: "Pilot tone",
                               frameCount: 60, timing: timing, naturalSize: .zero, displaySize: .zero,
                               preferredTransform: .identity, hasAudio: true, codec: "pcm",
                               identity: .init(device: 0, inode: 1, size: 0, modifiedNs: 0), hasVideo: false,
                               audioSampleRate: 48_000, audioSampleCount: 96_000, audioChannels: 1)
        var style = SpectrumItemStyle.provisionalDefault
        style.red = 48; style.green = 221; style.blue = 241
        style.outsideRGB = .init(red: 255, green: 178, blue: 80)
        style.hueInterpolationDegrees = 120
        style.alpha = 232
        let source = UUID()
        let timeline = try Timeline().registering(asset)
            .placing(media: asset.id, at: 0, videoLane: nil, audioLane: Lane.audioID, clipID: source)
            .addingSpectrum(fromAudioClip: source, style: style, newLaneName: "Spectrum")
        return (timeline, asset, try XCTUnwrap(timeline.spectra.first))
    }

    private func request(_ coordinator: SpectrumFrameCoordinator, id: UUID) async -> SpectrumFrameOutcome {
        await withCheckedContinuation { continuation in
            coordinator.request(spectrum: id, frame: frame, canvasWidth: width, canvasHeight: height) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func bytes(_ result: SpectrumRenderedFrame) throws -> Data {
        XCTAssertEqual(result.canvasWidth, width)
        XCTAssertEqual(result.canvasHeight, height)
        XCTAssertEqual(result.image.alphaInfo, .premultipliedFirst)
        XCTAssertTrue(result.image.bitmapInfo.contains(.byteOrder32Little))
        XCTAssertEqual(result.image.bytesPerRow, 4 * result.image.width)
        let data = try XCTUnwrap(result.image.dataProvider?.data) as Data
        XCTAssertEqual(data.count, result.image.height * result.image.bytesPerRow)
        return data
    }

    private func checkSequence(pilot: Bool) async throws {
        let (initial, asset, item) = try fixture()
        let pcm = PCM(), queue = DispatchQueue(label: "test.digital-pilot.delivery")
        let opener: SpectrumFrameCoordinator.SourceOpener = { _ in pcm }
        let coordinator = pilot
            ? SpectrumFrameCoordinator(deliveryQueue: queue, digitalSoftnessPreviewPilot: true, opener: opener)
            : SpectrumFrameCoordinator(deliveryQueue: queue, opener: opener)
        defer { coordinator.resetProject() }
        let reference = try SpectrumFrameRenderer(width: width, height: height)
        var timeline = initial
        var baseline: (bands: [Float], stats: SpectrumSchedulerStatistics)?
        var digitalDigests: [Int: Data] = [:]
        let sequence: [(SpectrumItemStyle.Mode, Int)] =
            [(.digital, 0), (.digital, 50), (.analog, 50), (.digital, 50), (.digital, 100), (.digital, 0)]
        for (mode, stored) in sequence {
            var style = try XCTUnwrap(timeline.spectrum(item.id)).style
            // Switching only the mode preserves the previous value of 50.
            if style.mode != mode { XCTAssertEqual(style.softnessPercent, stored) }
            else { style.softnessPercent = stored }
            style.mode = mode
            timeline = try timeline.settingSpectrumStyle(item.id, style)
            coordinator.update(timeline: timeline, media: [asset])
            let outcome = await request(coordinator, id: item.id)
            guard case let .ready(bands, actual?) = outcome else {
                return XCTFail("Expected a ready Spectrum frame: \(SpectrumFrameCoordinatorTests.name(outcome))")
            }
            let stats = coordinator.scheduler.statistics
            if let baseline {
                XCTAssertEqual(bands, baseline.bands)
                XCTAssertEqual(stats.decodes, baseline.stats.decodes)
                XCTAssertEqual(stats.analyses, baseline.stats.analyses)
                XCTAssertEqual(stats.bandCacheEntries, baseline.stats.bandCacheEntries)
            } else {
                XCTAssertGreaterThan(bands.max() ?? 0, 0)
                XCTAssertGreaterThan(stats.decodes, 0)
                XCTAssertGreaterThan(stats.analyses, 0)
                baseline = (bands, stats)
            }
            let applied = pilot && mode == .digital ? stored : 0
            let expected = try XCTUnwrap(reference.render(bands: bands, style: style, experimentalSoftnessPercent: applied))
            XCTAssertEqual(actual.drawRect, expected.drawRect, "\(mode) stored \(stored)")
            let actualBytes = try bytes(actual)
            XCTAssertEqual(actualBytes, try bytes(expected), "\(mode) stored \(stored)")
            if mode == .digital {
                let digest = Data(SHA256.hash(data: actualBytes))
                if let prior = digitalDigests[stored] { XCTAssertEqual(digest, prior) }
                digitalDigests[stored] = digest
            } else {
                let inward = try XCTUnwrap(reference.render(bands: bands, style: style, experimentalSoftnessPercent: stored))
                XCTAssertNotEqual(actualBytes, try bytes(inward), "The Analog fixture must distinguish 0% from 50%")
            }
            let current = try XCTUnwrap(timeline.spectrum(item.id))
            XCTAssertEqual(current.style, style)
            XCTAssertEqual(current.style.softnessPercent, stored)
            XCTAssertEqual(current.sourceKey, item.sourceKey)
            XCTAssertEqual(timeline.spectrumPieces(current), initial.spectrumPieces(item))
        }
        XCTAssertEqual(Set(digitalDigests.keys), [0, 50, 100])
        XCTAssertEqual(Set(digitalDigests.values).count, pilot ? 3 : 1)
    }

    func testOptedInDigitalUsesStoredStrengthAndAnalogPreservesStoredValue() async throws {
        try await checkSequence(pilot: true)
    }

    func testOrdinaryDebugCoordinatorKeepsDigitalAndAnalogAtZero() async throws {
        try await checkSequence(pilot: false)
    }

    func testPilotDiscardsAnObsoleteStyleAndACancelledTicket() async throws {
        let (base, asset, item) = try fixture()
        let pcm = PCM(gated: true), queue = DispatchQueue(label: "test.digital-pilot.invalidations")
        let coordinator = SpectrumFrameCoordinator(deliveryQueue: queue, digitalSoftnessPreviewPilot: true) { _ in pcm }
        defer { pcm.release(); coordinator.resetProject() }
        var style = item.style
        style.softnessPercent = 50
        let digital = try base.settingSpectrumStyle(item.id, style)
        coordinator.update(timeline: digital, media: [asset])
        let log = SpectrumFrameCoordinatorTests.Log()
        let old = expectation(description: "superseded Digital"), cancelled = expectation(description: "cancelled Analog")
        let current = expectation(description: "current Analog")
        coordinator.request(spectrum: item.id, frame: frame, canvasWidth: width, canvasHeight: height) {
            log.add("old", $0); old.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while pcm.started == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard pcm.started > 0 else { return XCTFail("Pending Digital request did not enter PCM decoding") }
        style.mode = .analog
        let analog = try digital.settingSpectrumStyle(item.id, style)
        coordinator.update(timeline: analog, media: [asset])
        let ticket = coordinator.request(spectrum: item.id, frame: frame, canvasWidth: width, canvasHeight: height) {
            log.add("cancelled", $0); cancelled.fulfill()
        }
        coordinator.cancel(ticket)
        coordinator.request(spectrum: item.id, frame: frame, canvasWidth: width, canvasHeight: height) {
            log.add("current", $0); current.fulfill()
        }
        _ = coordinator.diagnostics  // queue barrier before releasing the decoder
        pcm.release()
        await fulfillment(of: [old, cancelled, current], timeout: 5)
        queue.sync {}
        XCTAssertEqual(log.all("old").map(SpectrumFrameCoordinatorTests.name), ["superseded"])
        XCTAssertEqual(log.all("cancelled").map(SpectrumFrameCoordinatorTests.name), ["cancelled"])
        XCTAssertEqual(log.total, 3)
        let outcome = try XCTUnwrap(log.all("current").first)
        guard case let .ready(bands, actual?) = outcome else { return XCTFail("Current Analog frame missing") }
        let reference = try SpectrumFrameRenderer(width: width, height: height)
        let expected = try XCTUnwrap(reference.render(bands: bands, style: style))
        XCTAssertEqual(actual.drawRect, expected.drawRect)
        XCTAssertEqual(try bytes(actual), try bytes(expected))
        XCTAssertEqual(analog.spectrum(item.id)?.style.softnessPercent, 50)
    }
}
#endif
