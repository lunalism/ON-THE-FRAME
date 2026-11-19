import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import XCTest

final class SpectrumSoftnessModelTests: XCTestCase {
    private typealias Object = [String: Any]

    private var twoColor: SpectrumItemStyle {
        var style = SpectrumItemStyle.provisionalDefault
        style.red = 220
        style.green = 52
        style.blue = 79
        style.alpha = 157
        style.outsideRGB = .init(red: 25, green: 241, blue: 67)
        style.hueInterpolationDegrees = 317
        return style
    }

    private func wire(_ style: SpectrumItemStyle) throws -> Object {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as? Object)
    }

    private func decode(_ object: Object) throws -> SpectrumItemStyle {
        try JSONDecoder().decode(SpectrumItemStyle.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testWritesV2ForZeroAndV3ForPositiveValues() throws {
        XCTAssertEqual(SpectrumItemStyle.provisionalDefault.softnessPercent, 0)
        for value in [0, 1, 50, 100] {
            var style = twoColor
            style.softnessPercent = value
            XCTAssertTrue(style.isValid)
            XCTAssertEqual(style == twoColor, value == 0)
            let root = try wire(style)
            XCTAssertNil(root["softnessPercent"])
            let appearance = try XCTUnwrap(root["appearance"] as? Object)
            var keys: Set<String> = ["contractVersion", "outsideRGB", "hueInterpolationDegrees"]
            if value != 0 { keys.insert("softnessPercent") }
            XCTAssertEqual(Set(appearance.keys), keys)
            XCTAssertEqual(appearance["contractVersion"] as? Int, value == 0 ? 2 : 3)
            XCTAssertEqual(appearance["softnessPercent"] as? Int, value == 0 ? nil : value)
            XCTAssertEqual(appearance["hueInterpolationDegrees"] as? Int, 317)
            XCTAssertEqual(appearance["outsideRGB"] as? [String: Int], ["red": 25, "green": 241, "blue": 67])
            XCTAssertEqual(try decode(root), style)
        }
    }

    func testLegacyAndExplicitV3ZeroReadWithZeroSoftness() throws {
        var root = try wire(twoColor)
        let v2 = try XCTUnwrap(root["appearance"] as? Object)
        root.removeValue(forKey: "appearance")
        let legacy = try decode(root)
        XCTAssertEqual(legacy.softnessPercent, 0)
        XCTAssertEqual(legacy.hueInterpolationDegrees, 0)
        XCTAssertEqual(legacy.resolvedOutsideRGB, twoColor.insideRGB)
        var v1 = v2
        v1["contractVersion"] = 1
        v1.removeValue(forKey: "hueInterpolationDegrees")
        root["appearance"] = v1
        let first = try decode(root)
        XCTAssertEqual(first.softnessPercent, 0)
        XCTAssertEqual(first.hueInterpolationDegrees, 0)
        XCTAssertEqual(first.resolvedOutsideRGB, twoColor.resolvedOutsideRGB)
        root["appearance"] = v2
        XCTAssertEqual(try decode(root), twoColor)
        var v3 = v2
        v3["contractVersion"] = 3
        v3["softnessPercent"] = 0
        root["appearance"] = v3
        let explicitZero = try decode(root)
        XCTAssertEqual(explicitZero, twoColor)
        let saved = try XCTUnwrap(wire(explicitZero)["appearance"] as? Object)
        XCTAssertEqual(saved["contractVersion"] as? Int, 2)
        XCTAssertNil(saved["softnessPercent"])
    }

    func testDirectDecoderRejectsMalformedAppearanceAndColor() throws {
        var style = twoColor
        style.softnessPercent = 50
        let original = try wire(style)
        let v3 = try XCTUnwrap(original["appearance"] as? Object)
        func rejects(_ appearance: Any, _ label: String) throws {
            var root = original
            root["appearance"] = appearance
            XCTAssertThrowsError(try decode(root), label)
        }
        for key in v3.keys {
            var object = v3
            object.removeValue(forKey: key)
            try rejects(object, "missing " + key)
        }
        for value in [-1, 101, 1.25, true, "50", NSNull()] as [Any] {
            var object = v3
            object["softnessPercent"] = value
            try rejects(object, "invalid softness " + String(describing: value))
        }
        let badFields: [(String, Any)] = [
            ("contractVersion", 4), ("contractVersion", 2), ("future", 0), ("hueInterpolationDegrees", 361),
            ("outsideRGB", ["red": -1, "green": 3, "blue": 4]),
            ("outsideRGB", ["red": 1, "green": 3, "blue": 4, "extra": 5])
        ]
        for (key, value) in badFields {
            var object = v3
            object[key] = value
            try rejects(object, key)
        }
        try rejects(NSNull(), "null appearance")
        for (key,value) in [("red",256), ("alpha",-1), ("softnessPercent",50), ("future",0)] {
            var root = original
            root[key] = value
            XCTAssertThrowsError(try decode(root), key)
        }
    }

    func testModelRejectsInvalidAppearanceBeforeWriting() throws {
        for value in [-1, 101, Int.min, Int.max] {
            var style = twoColor
            style.softnessPercent = value
            XCTAssertFalse(style.isValid)
            XCTAssertThrowsError(try JSONEncoder().encode(style))
        }
        var invalid = twoColor
        invalid.red = 256
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
        invalid = twoColor
        invalid.outsideRGB = .init(red: 1, green: -1, blue: 3)
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
        invalid = twoColor
        invalid.hueInterpolationDegrees = 361
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
    }

    // No file IO. The coordinator's injected opener supplies a deterministic 440 Hz PCM source.
    private struct Tone: SpectrumPCMProvider {
        let identity = SpectrumSourceIdentity("softness-test-tone")
        let sampleRate = 48_000, channelCount = 1, chunkSamples = 24_000
        func decodeChunk(_ index: Int) async throws -> [[Float]] {
            [(0..<chunkSamples).map { sample in
                Float(0.5 * sin(2 * Double.pi * 440 * Double(index * chunkSamples + sample) / Double(sampleRate)))
            }]
        }
    }

    func testSoftnessOnlyEditReusesFFTAndPCMAndKeepsPreviewOnZeroPath() async throws {
        let timing = SourceTiming(sampleCount: 60, isVariable: false, frameDurationValue: 1, frameDurationTimescale: 30,
                                  averageFPS: 30, minInterval: 1.0/30, maxInterval: 1.0/30)
        let asset = MediaAsset(id: UUID(), url: FileManager.default.temporaryDirectory.appendingPathComponent("softness-tone.wav"),
                               name: "Tone", frameCount: 60, timing: timing, naturalSize: .zero, displaySize: .zero,
                               preferredTransform: .identity, hasAudio: true, codec: "pcm",
                               identity: .init(device: 0, inode: 1, size: 0, modifiedNs: 0), hasVideo: false,
                               audioSampleRate: 48_000, audioSampleCount: 96_000, audioChannels: 1)
        let sourceID = UUID()
        let timeline = try Timeline().registering(asset)
            .placing(media: asset.id, at: 12, videoLane: nil, audioLane: Lane.audioID, clipID: sourceID)
            .addingSpectrum(fromAudioClip: sourceID, newLaneName: "Spectrum")
        let item = try XCTUnwrap(timeline.spectra.first)
        XCTAssertEqual(item.style.softnessPercent, 0)
        XCTAssertEqual(item.sourceKey, sourceID)
        let coordinator = SpectrumFrameCoordinator(deliveryQueue: DispatchQueue(label: "test.softness.delivery")) { _ in Tone() }
        defer { coordinator.resetProject() }
        func request(_ t: Timeline) async throws -> ([Float], SpectrumRenderedFrame) {
            coordinator.update(timeline: t, media: [asset])
            let outcome: SpectrumFrameOutcome = await withCheckedContinuation { continuation in
                coordinator.request(spectrum: item.id, frame: 30, canvasWidth: 384, canvasHeight: 216) {
                    continuation.resume(returning: $0)
                }
            }
            guard case let .ready(bands, frame?) = outcome else { throw FixtureError.unexpectedFrame }
            return (bands, frame)
        }
        func pixels(_ frame: SpectrumRenderedFrame) throws -> Data {
            try XCTUnwrap(frame.image.dataProvider?.data) as Data
        }
        let (raw, original) = try await request(timeline)
        let initial = coordinator.scheduler.statistics
        XCTAssertGreaterThan(initial.analyses, 0)
        XCTAssertGreaterThan(initial.decodes, 0)
        XCTAssertGreaterThan(raw.max() ?? 0, 0)
        var style = item.style
        style.softnessPercent = 100
        let edited = try timeline.settingSpectrumStyle(item.id, style)
        let updated = try XCTUnwrap(edited.spectrum(item.id))
        XCTAssertEqual(updated.sourceKey, item.sourceKey)
        XCTAssertEqual(updated.start, item.start)
        XCTAssertEqual(updated.length, item.length)
        XCTAssertEqual(updated.lane, item.lane)
        XCTAssertEqual(edited.spectrumPieces(updated), timeline.spectrumPieces(item))
        XCTAssertEqual(updated.style.analysisSettings, item.style.analysisSettings)
        var history = EditHistory(timeline)
        history.apply(edited, focus: item.id)
        XCTAssertEqual(history.undoDepth, 1)
        history.undo()
        XCTAssertEqual(history.timeline, timeline)
        history.redo()
        XCTAssertEqual(history.timeline, edited)
        let (again, preview) = try await request(edited)
        XCTAssertEqual(again, raw)
        XCTAssertEqual(preview.drawRect, original.drawRect)
        XCTAssertEqual(try pixels(preview), try pixels(original))
        XCTAssertEqual(coordinator.scheduler.statistics.analyses, initial.analyses)
        XCTAssertEqual(coordinator.scheduler.statistics.decodes, initial.decodes)
        XCTAssertEqual(coordinator.scheduler.statistics.bandCacheEntries, initial.bandCacheEntries)
        let renderer = try SpectrumFrameRenderer(width: 384, height: 216)
        let feathered = try XCTUnwrap(renderer.render(bands: again, style: updated.style,
                                                      experimentalSoftnessPercent: updated.style.softnessPercent))
        XCTAssertNotEqual(try pixels(feathered), try pixels(original))
    }

    private enum FixtureError: Error { case unexpectedFrame }
}
