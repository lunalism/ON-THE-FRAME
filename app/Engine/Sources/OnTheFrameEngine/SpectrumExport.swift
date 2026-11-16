import AVFoundation
import Foundation
import CoreGraphics
import os

/// Internal frame producer. A nil footprint is an explicit ready-empty result, never pending.
protocol ExportFrameOverlay: Sendable {
    var stepTimeout: Double { get }
    var jobTimeout: Double { get }
    func prepare(_ frame: Int) async throws -> SubtitleFootprint?
    func validateSources() throws
    func composed(_ frame: Int, source: CVPixelBuffer, output: CVPixelBuffer)
    #if DEBUG
    func checkpoint(_ point: SpectrumExportCheckpoint) async
    func pausesWriter(at frame: Int) -> Bool
    #endif
}

#if DEBUG
/// Deterministic fault seams for the internal slice; never installed by ordinary export.
enum SpectrumExportCheckpoint: Equatable, Sendable {
    case framePreparation(Int), analysis(Int)
    case beforeFinalization, finalizationPending, afterFinalization, promotionPreparation, promoted
}
/// Test controls are required at the call site; they are not product export defaults.
struct SpectrumExportControls: Sendable {
    let stepTimeout: Double
    let jobTimeout: Double
    var composed: (@Sendable (Int, CVPixelBuffer, CVPixelBuffer) -> Void)?
    var prepared: (@Sendable (Int, [Float], SpectrumRenderedFrame?, Int) -> Void)?
    var checkpoint: (@Sendable (SpectrumExportCheckpoint) async -> Void)?
    var pausesWriter: (@Sendable (Int) -> Bool)?
}

/// One job owns both access and analysis until any cancelled worker has actually drained.
/// No preview session, live player time, or preview access lease is used.
final class SpectrumExportFrames: ExportFrameOverlay, @unchecked Sendable {
    private static let active = OSAllocatedUnfairLock(initialState: false)
    static var isIdleForTest: Bool { active.withLock { !$0 } }
    let stepTimeout: Double, jobTimeout: Double
    private let assets: [MediaAsset]
    private var scopes: [URL] = []
    private let timeline: Timeline, entry: SpectrumItem, asset: MediaAsset
    private let controls: SpectrumExportControls
    private let worker: Worker

    init(timeline: Timeline, assets: [MediaAsset], controls: SpectrumExportControls) throws {
        guard controls.stepTimeout.isFinite, controls.jobTimeout.isFinite,
              (0.1...30).contains(controls.stepTimeout), (1...180).contains(controls.jobTimeout),
              timeline.isValid, timeline.durationFrames == 360, timeline.clips.count == 1,
              timeline.clips[0].start == 0, timeline.clips[0].length == 360,
              !InternalImagePreview.containsImages(timeline), timeline.audioClips.count == 1,
              timeline.spectra.count == 1, timeline.subtitles.count == 3,
              let entry = timeline.spectra.first, entry.start == 0, entry.length == 360,
              let id = timeline.spectrumMediaID(entry), let asset = assets.first(where: { $0.id == id }),
              asset.url.pathExtension.lowercased() == "wav",
              (0..<360).allSatisfy({ timeline.spectrumFrameState(entry, atFrame: $0) == .ok }) else {
            throw ExportFailure.export("Internal spectrum slice requires one video, one selected WAV, one spectrum and three subtitles; valid source coverage is required.")
        }
        self.timeline = timeline; self.entry = entry; self.asset = asset; self.assets = assets
        self.controls = controls; stepTimeout = controls.stepTimeout; jobTimeout = controls.jobTimeout
        worker = Worker(entry: entry, pieces: timeline.spectrumPieces(entry), asset: asset, controls: controls)
        guard Self.active.withLock({ active in if active { return false }; active = true; return true }) else {
            throw ExportFailure.export("An internal spectrum export is still draining.")
        }
        ownsSlot = true
        for a in assets { if a.url.startAccessingSecurityScopedResource() { scopes.append(a.url) } }
        try validateSources()
    }
    private var ownsSlot = false
    deinit {
        for url in scopes { url.stopAccessingSecurityScopedResource() }
        if ownsSlot { Self.active.withLock { $0 = false } }
    }
    func validateSources() throws {
        for a in assets {
            guard FileIdentity.of(a.url) == a.identity, FileManager.default.isReadableFile(atPath: a.url.path) else {
                throw ExportFailure.export("An export source changed or became unreadable.")
            }
        }
    }
    func composed(_ frame: Int, source: CVPixelBuffer, output: CVPixelBuffer) { controls.composed?(frame, source, output) }
    func checkpoint(_ point: SpectrumExportCheckpoint) async { await controls.checkpoint?(point) }
    func pausesWriter(at frame: Int) -> Bool { controls.pausesWriter?(frame) ?? false }
    func prepare(_ frame: Int) async throws -> SubtitleFootprint? {
        await checkpoint(.framePreparation(frame))
        try Task.checkCancellation(); try validateSources()
        let result = try await worker.prepare(frame)
        try Task.checkCancellation(); try validateSources()
        return result
    }
    /// Exactly one caller is admitted by the writer pump. No per-frame task fan-out.
    private actor Worker {
        let entry: SpectrumItem, pieces: [SpectrumSourcePiece], asset: MediaAsset, controls: SpectrumExportControls
        var source: SpectrumFileSource?, renderer: SpectrumFrameRenderer?
        var chunks: [Int: [[Float]]] = [:]
        var next = 0
        init(entry: SpectrumItem, pieces: [SpectrumSourcePiece], asset: MediaAsset, controls: SpectrumExportControls) {
            self.entry = entry; self.pieces = pieces; self.asset = asset; self.controls = controls
        }
        func prepare(_ k: Int) async throws -> SubtitleFootprint? {
            await controls.checkpoint?(.analysis(k))
            guard k == next, k < 360 else { throw ExportFailure.export("Unexpected export frame sequence.") }
            if source == nil { source = try await SpectrumFileSource.open(url: asset.url, mediaID: asset.id) }
            guard let source, source.sampleRate == 48_000, source.channelCount == 2 else { throw ExportFailure.export("Internal slice requires stereo 48kHz analysis.") }
            let needed = try SpectrumAnalysis.chunks(frame: k, pieces: pieces, fps: 30, rate: source.sampleRate, settings: entry.style.analysisSettings, chunkSamples: source.chunkSamples)
            // Admission before decoding: at most two 8s stereo Float chunks (6.144 MB).
            guard needed.count <= 2 else { throw ExportFailure.export("Internal spectrum PCM budget exceeded.") }
            chunks = chunks.filter { needed.contains($0.key) }
            for index in needed where chunks[index] == nil {
                try Task.checkCancellation()
                chunks[index] = try await source.decodeChunk(index)
            }
            try Task.checkCancellation()
            let bytes = chunks.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count * MemoryLayout<Float>.stride } }
            guard bytes <= 8 << 20 else { throw ExportFailure.export("Internal spectrum decoded PCM budget exceeded.") }
            let bands = try SpectrumAnalysis.bands(frame: k, pieces: pieces, fps: 30, rate: source.sampleRate, channelCount: source.channelCount, chunkSamples: source.chunkSamples, settings: entry.style.analysisSettings) { chunks[$0] }
            if renderer == nil { renderer = try SpectrumFrameRenderer(width: 1920, height: 1080) }
            let rendered = try renderer!.render(bands: bands, style: entry.style)
            if let r = rendered, r.image.bytesPerRow * r.image.height > 16 << 20 { throw ExportFailure.export("Internal spectrum raster budget exceeded.") }
            controls.prepared?(k, bands, rendered, bytes)
            next += 1
            guard let r = rendered else { return nil }
            let raster = SubtitleRaster(image: r.image, rect: CGRect(x: 0, y: 0, width: 1920, height: 1080), fontUsed: "", missingFont: false, fallbackFonts: [], lines: 0, textBounds: .zero, failed: false, clipped: false, hitRect: .zero, drawRect: r.drawRect)
            return SubtitleFootprint(SubtitleItem(lane: entry.lane, start: k, length: 1, text: ""), raster)
        }
    }
}
#endif
