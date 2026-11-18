import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import os
import XCTest

/// Compare the actual internal Export worker with the Preview coordinator.
/// Generated media only, fresh output folder, public Spectrum Export stays gated.
final class SpectrumInternalZeroTests: XCTestCase {
    private func media(in folder: URL) async throws -> (MediaAsset, MediaAsset) {
        let video = folder.appendingPathComponent("video.mp4"), audio = folder.appendingPathComponent("initial-silence.wav")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<360 {
            while !input.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard result == kCVReturnSuccess, let buffer else { throw SpectrumRenderError.invalidCanvas("fixture allocation") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 64, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 12, timescale: 1))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let frames = 48_000 * 12, dataBytes = frames * 4
        var wav = Data()
        func u16(_ v: UInt16) { wav.append(UInt8(v & 255)); wav.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { u16(UInt16(v & 65535)); u16(UInt16(v >> 16)) }
        wav.append(Data("RIFF".utf8)); u32(UInt32(36 + dataBytes)); wav.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(48_000); u32(192_000); u16(4); u16(16)
        wav.append(Data("data".utf8)); u32(UInt32(dataBytes))
        for n in 0..<frames {
            let value = n < 24_000 ? Int16(0) : Int16((0.25 * 32767 * sin(2 * Double.pi * 440 * Double(n) / 48_000)).rounded())
            u16(UInt16(bitPattern: value)); u16(UInt16(bitPattern: value))
        }
        try wav.write(to: audio, options: .withoutOverwriting)
        return (try await MediaProbe.inspect(video), try await MediaProbe.inspect(audio))
    }

    func testValidZeroAndNonzeroFramesMatchActualInternalExportWorker() async throws {
        let folder = ExportEndToEndTests.root.appendingPathComponent("spectrum-zero-internal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (video, audio) = try await media(in: folder), mediaByID = [video.id: video, audio.id: audio]
        let spectrumLane = UUID(), subtitleLane = UUID(), id = UUID()
        let clip = Clip(mediaID: audio.id, start: 0, sourceIn: 0, length: 360, lane: Lane.audioID)
        var style = SpectrumItemStyle.provisionalDefault; style.bands = 8; style.thicknessMilli = 6_000
        let spectrum = SpectrumItem(id: id, lane: spectrumLane, start: 0, length: 360, sourceKey: clip.lineageKey, style: style)
        let subs = (0..<3).map { SubtitleItem(lane: subtitleLane, start: $0 * 120, length: 120, text: "Generated \($0)") }
        let timeline = Timeline(clips: [Clip(mediaID: video.id, start: 0, sourceIn: 0, length: 360, lane: Lane.videoID)],
            audioClips: [clip], subtitles: subs, spectra: [spectrum],
            lanes: [Lane(id: subtitleLane, kind: .subtitle, name: "S"), Lane(id: spectrumLane, kind: .spectrum, name: "SP")] + Lane.defaults,
            media: [MediaRef(video), MediaRef(audio)], mediaFrames: [video.id: video.frameCount, audio.id: audio.frameCount],
            mediaHasAudio: [video.id: video.hasAudio, audio.id: audio.hasAudio], durationFrames: 360)
        XCTAssertTrue(timeline.isValid)
        let probeFrames: Set<Int> = [0, 1, 5, 29, 30]
        typealias Result = (bands: [Float], frame: SpectrumRenderedFrame?)
        let results = OSAllocatedUnfairLock(initialState: [Int: Result]())
        var controls = SpectrumExportControls(stepTimeout: 10, jobTimeout: 120)
        controls.prepared = { frame, bands, raster, bytes in
            if probeFrames.contains(frame) { results.withLock { $0[frame] = (bands, raster) } }
        }
        var worker: SpectrumExportFrames? = try SpectrumExportFrames(timeline: timeline, assets: [video, audio], controls: controls)
        let preview = SpectrumFrameCoordinator(deliveryQueue: DispatchQueue(label: "test.zero.preview"))
        preview.update(timeline: timeline, media: [video, audio])
        for frame in 0...30 {
            let footprint = try await worker!.prepare(frame)
            XCTAssertNotNil(footprint, "valid silent and sounding frames both produce footprints")
            guard probeFrames.contains(frame) else { continue }
            let outcome = await withCheckedContinuation { continuation in
                preview.request(spectrum: id, frame: frame, canvasWidth: 1920, canvasHeight: 1080) { continuation.resume(returning: $0) }
            }
            guard case let .ready(bands, actual?) = outcome else { return XCTFail("Preview result was not ready") }
            let exported = try XCTUnwrap(results.withLock { $0[frame] }), expected = try XCTUnwrap(exported.frame)
            XCTAssertEqual(bands, exported.bands, "Preview/Export analysis remains identical frame \(frame)")
            XCTAssertEqual(actual.drawRect, expected.drawRect)
            XCTAssertEqual(SpectrumFrameRendererTests.bytes(actual.image), SpectrumFrameRendererTests.bytes(expected.image))
            if frame < 6 {
                XCTAssertTrue(bands.allSatisfy { $0 == 0 })
                XCTAssertTrue(SpectrumFrameRendererTests.bytes(actual.image).contains { $0 != 0 })
                XCTAssertLessThanOrEqual(actual.drawRect.height, 16)
            } else { XCTAssertGreaterThan(bands.max()!, 0) }
        }
        worker = nil; preview.resetProject()
        XCTAssertTrue(SpectrumExportFrames.isIdleForTest)
        let plan = try await CompositionPlanner.plan(timeline, media: mediaByID)
        let destination = folder.appendingPathComponent("public-gate.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(destination), sources: [video, audio]) { _ in }
        if case .failed = outcome {} else { XCTFail("Public Spectrum Export must remain disabled") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Six bounded appearance configurations, five Preview/internal-worker
    /// raster checkpoints per configuration, including initial silence.
    func testTwoColorAppearanceMatchesActualInternalWorker() async throws {
        let folder = ExportEndToEndTests.root.appendingPathComponent("spectrum-color-internal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (video, audio) = try await media(in: folder)
        let spectrumLane = UUID(), subtitleLane = UUID(), id = UUID()
        let clip = Clip(mediaID: audio.id, start: 0, sourceIn: 0, length: 360, lane: Lane.audioID)
        let subtitles = (0..<3).map { SubtitleItem(lane: subtitleLane, start: $0 * 120, length: 120, text: "Color \($0)") }
        let cases: [(SpectrumItemStyle.Mode, SpectrumItemStyle.Sides, Bool, Int, Int)] = [
            (.digital, .above, false, 400_000, 0), (.digital, .mirrored, true, 400_000, 0),
            (.analog, .mirrored, true, 400_000, 0), (.digital, .below, false, 0, 0),
            (.digital, .mirrored, false, 400_000, 180), (.analog, .mirrored, true, 400_000, 360)
        ]
        let probes: Set<Int> = [0, 1, 15, 29, 30]
        for (mode, sides, diagonal, height, hue) in cases {
            var style = SpectrumItemStyle.provisionalDefault
            style.mode = mode; style.sides = sides; style.bands = 8; style.thicknessMilli = 6_000
            style.startYMilli = 800_500; style.endYMilli = diagonal ? 300_500 : 800_500
            style.maxHeightMilli = height; style.red = 255; style.green = 0; style.blue = 0; style.alpha = 160
            style.outsideRGB = .init(red: 0, green: 32, blue: 255)
            style.hueInterpolationDegrees = hue
            let spectrum = SpectrumItem(id: id, lane: spectrumLane, start: 0, length: 360, sourceKey: clip.lineageKey, style: style)
            let timeline = Timeline(clips: [Clip(mediaID: video.id, start: 0, sourceIn: 0, length: 360, lane: Lane.videoID)],
                audioClips: [clip], subtitles: subtitles, spectra: [spectrum],
                lanes: [Lane(id: subtitleLane, kind: .subtitle, name: "S"), Lane(id: spectrumLane, kind: .spectrum, name: "SP")] + Lane.defaults,
                media: [MediaRef(video), MediaRef(audio)], mediaFrames: [video.id: video.frameCount, audio.id: audio.frameCount],
                mediaHasAudio: [video.id: video.hasAudio, audio.id: audio.hasAudio], durationFrames: 360)
            XCTAssertTrue(timeline.isValid)
            typealias Result = (bands: [Float], raster: SpectrumRenderedFrame?, bytes: Int)
            let results = OSAllocatedUnfairLock(initialState: [Int: Result]())
            var controls = SpectrumExportControls(stepTimeout: 10, jobTimeout: 120)
            controls.prepared = { frame, bands, raster, bytes in
                if probes.contains(frame) { results.withLock { $0[frame] = (bands, raster, bytes) } }
            }
            var worker: SpectrumExportFrames? = try SpectrumExportFrames(timeline: timeline, assets: [video, audio], controls: controls)
            let preview = SpectrumFrameCoordinator(deliveryQueue: DispatchQueue(label: "test.color.internal.preview"))
            preview.update(timeline: timeline, media: [video, audio])
            for frame in 0...30 {
                let footprint = try await worker!.prepare(frame)
                guard probes.contains(frame) else { continue }
                let outcome = await withCheckedContinuation { continuation in
                    preview.request(spectrum: id, frame: frame, canvasWidth: 1920, canvasHeight: 1080) { continuation.resume(returning: $0) }
                }
                guard case let .ready(bands, actual?) = outcome else { return XCTFail("appearance Preview must be ready") }
                let exported = try XCTUnwrap(results.withLock { $0[frame] })
                let expected = try XCTUnwrap(exported.raster)
                XCTAssertNotNil(footprint)
                XCTAssertEqual(bands, exported.bands)
                XCTAssertEqual(actual.drawRect, expected.drawRect)
                XCTAssertEqual(SpectrumFrameRendererTests.bytes(actual.image), SpectrumFrameRendererTests.bytes(expected.image))
                XCTAssertLessThanOrEqual(exported.bytes, 8 << 20)
                XCTAssertLessThanOrEqual(actual.image.bytesPerRow * actual.image.height, 16 << 20)
                if frame < 2 { XCTAssertTrue(bands.allSatisfy { $0 == 0 }) }
            }
            XCTAssertEqual(results.withLock { $0.count }, probes.count)
            worker = nil; preview.resetProject()
            XCTAssertTrue(SpectrumExportFrames.isIdleForTest)
            let plan = try await CompositionPlanner.plan(timeline, media: [video.id: video, audio.id: audio])
            let destination = folder.appendingPathComponent("public-gate-\(mode.rawValue)-\(sides.rawValue).mp4")
            let outcome = await ExportService.export(plan, to: .fromSavePanel(destination), sources: [video, audio]) { _ in }
            if case .failed = outcome {} else { XCTFail("Two-color appearance does not enable public Spectrum Export") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// Bounded frame production, not an encoded Export or a full parity claim.
    /// Reuse one generated 12s source pair; each worker still starts at frame zero
    /// and advances sequentially through at most frame 60.
    func testTimingControlsMatchActualInternalWorkerInDigitalAndAnalog() async throws {
        let folder = ExportEndToEndTests.root.appendingPathComponent("spectrum-timing-internal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (video, audio) = try await media(in: folder)
        let spectrumLane = UUID(), subtitleLane = UUID(), id = UUID()
        let clip = Clip(mediaID: audio.id, start: 0, sourceIn: 0, length: 360, lane: Lane.audioID)
        let subtitles = (0..<3).map { SubtitleItem(lane: subtitleLane, start: $0 * 120, length: 120, text: "Timing \($0)") }
        let cases: [(name: String, ms: Int, offset: Int, mode: SpectrumItemStyle.Mode, last: Int)] = [
            ("negative limit / Digital zero", 1, -10_000, .digital, 30),
            ("positive limit / source end", 1000, 10_000, .digital, 60),
            ("negative offset / Analog", 1000, -500, .analog, 30),
            ("positive offset / Analog", 1, 500, .analog, 30)
        ]
        for c in cases {
            var style = SpectrumItemStyle.provisionalDefault
            style.windowMs = c.ms; style.offsetMs = c.offset; style.mode = c.mode
            style.bands = 8; style.thicknessMilli = 6_000
            let spectrum = SpectrumItem(id: id, lane: spectrumLane, start: 0, length: 360, sourceKey: clip.lineageKey, style: style)
            let timeline = Timeline(clips: [Clip(mediaID: video.id, start: 0, sourceIn: 0, length: 360, lane: Lane.videoID)],
                audioClips: [clip], subtitles: subtitles, spectra: [spectrum],
                lanes: [Lane(id: subtitleLane, kind: .subtitle, name: "S"), Lane(id: spectrumLane, kind: .spectrum, name: "SP")] + Lane.defaults,
                media: [MediaRef(video), MediaRef(audio)], mediaFrames: [video.id: video.frameCount, audio.id: audio.frameCount],
                mediaHasAudio: [video.id: video.hasAudio, audio.id: audio.hasAudio], durationFrames: 360)
            XCTAssertTrue(timeline.isValid)
            XCTAssertEqual(timeline.audioClips, [clip], "Analysis settings do not move or retime the audio clip")
            let probes: Set<Int> = c.last == 60 ? [0, 1, 29, 30, 59, 60] : [0, 1, 29, 30]
            typealias Result = (bands: [Float], raster: SpectrumRenderedFrame?, bytes: Int)
            let results = OSAllocatedUnfairLock(initialState: [Int: Result]())
            var controls = SpectrumExportControls(stepTimeout: 10, jobTimeout: 120)
            controls.prepared = { frame, bands, raster, bytes in
                if probes.contains(frame) { results.withLock { $0[frame] = (bands, raster, bytes) } }
            }
            var worker: SpectrumExportFrames? = try SpectrumExportFrames(timeline: timeline, assets: [video, audio], controls: controls)
            let preview = SpectrumFrameCoordinator(deliveryQueue: DispatchQueue(label: "test.timing.internal.preview"))
            preview.update(timeline: timeline, media: [video, audio])
            for frame in 0...c.last {
                let footprint = try await worker!.prepare(frame)
                guard probes.contains(frame) else { continue }
                let outcome = await withCheckedContinuation { continuation in
                    preview.request(spectrum: id, frame: frame, canvasWidth: 1920, canvasHeight: 1080) { continuation.resume(returning: $0) }
                }
                guard case let .ready(bands, actual) = outcome else { return XCTFail("\(c.name): Preview was not ready at \(frame)") }
                let exported = try XCTUnwrap(results.withLock { $0[frame] })
                XCTAssertEqual(bands, exported.bands, "\(c.name), frame \(frame)")
                XCTAssertEqual(actual == nil, exported.raster == nil)
                XCTAssertEqual(footprint == nil, exported.raster == nil)
                XCTAssertLessThanOrEqual(exported.bytes, 8 << 20, "Existing internal PCM bound")
                if let actual, let expected = exported.raster {
                    XCTAssertEqual(actual.drawRect, expected.drawRect)
                    XCTAssertEqual(SpectrumFrameRendererTests.bytes(actual.image), SpectrumFrameRendererTests.bytes(expected.image), "\(c.name), frame \(frame)")
                }
                if c.offset == -10_000 {
                    XCTAssertTrue(bands.allSatisfy { $0 == 0 })
                    let raster = try XCTUnwrap(actual, "Valid zero Digital frames retain their dots")
                    XCTAssertTrue(SpectrumFrameRendererTests.bytes(raster.image).contains { $0 != 0 })
                }
                if c.offset == 10_000 {
                    // Frame 59 centers on source frame 359; frame 60 straddles
                    // the real source end. Existing zero padding retains the
                    // earlier half of this 1000ms Hann window in both consumers.
                    XCTAssertGreaterThan(bands.max() ?? 0, 0, "Valid source tail must not be discarded")
                }
            }
            XCTAssertEqual(results.withLock { $0.count }, probes.count)
            worker = nil; preview.resetProject()
            XCTAssertTrue(SpectrumExportFrames.isIdleForTest)
        }
    }
}
