import AVFoundation
import CoreGraphics
import Foundation

/// 일반 타임라인의 스펙트럼 내보내기 프레임 공급(SP-EXPORT-E2, 2026-11-23, 엔진 내부).
/// 공개 내보내기에는 아직 이어져 있지 않다 — ExportService와 앱의 스펙트럼 거부는 그대로다.
///
/// 프레임 k: 그 프레임에 보이는 스펙트럼마다 프리뷰와 같은 함수로 계산한다
/// (Timeline.spectrumPieces → SpectrumAnalysis.chunks·bands → SpectrumFrameRenderer.render(bands:style:)).
/// 차례는 프리뷰와 같다: `timeline.spectra.reversed()` 가운데 보이는 것, 앞의 것이 아래다(PausedSpectrumOverlay).
/// 보이지 않는 스펙트럼은 분석하지 않는다. 고른 소스가 그 시각을 덮지 않으면 분석이 0을 낸다(무음 — 기존 규칙).
/// 그릴 수 없는 상태(소스 고르지 않음·소스 없음·겹침, D-S3·D-S8)는 빼지 않고 오류로 거부한다.
enum SpectrumTimelineExportError: Error, Equatable {
    case invalidLimits
    case invalidTimeline
    /// 내보내기를 막는 스펙트럼(Timeline.spectrumExportBlockers 그대로)
    case blocked([SpectrumExportBlocker])
    /// 그 스펙트럼의 소스 원본(미디어)이 넘겨받은 목록에 없다
    case sourceUnavailable(spectrum: UUID)
    /// 원본 파일이 바뀌었거나 읽을 수 없다
    case sourceChanged
    /// 보이는 프레임의 상태가 정상이 아니다(만든 뒤에는 생기지 않아야 하는 방어 검사)
    case frameState(spectrum: UUID, frame: Int, state: SpectrumFrameState)
    case frameOutOfRange(Int)
    case pcmBudgetExceeded(bytes: Int)
    case rasterBudgetExceeded(bytes: Int)
    /// 앞 프레임이 끝나기 전에 다음 요청이 옴(쓰기 펌프는 한 번에 하나만 요청한다)
    case concurrentRequest
    case closed
}

/// 시간·메모리 한도. 제품 기본값이 아니다 — 부르는 쪽이 정해서 넘긴다(공개 연결 때 정책을 정한다).
struct SpectrumTimelineExportLimits: Sendable, Equatable {
    /// 프레임 하나를 준비하는 데 허용하는 시간(초)
    let stepTimeout: Double
    /// 내보내기 전체에 허용하는 시간(초). 쓰기 펌프가 이 값으로 마무리 기한을 계산한다.
    let jobTimeout: Double
    /// 한 프레임을 위해 들고 있는 디코딩된 소리의 상한(바이트)
    var pcmBudgetBytes = 32 << 20
    /// 한 프레임의 스펙트럼 그림 바이트 합의 상한
    var rasterBudgetBytes = 128 << 20
    var isValid: Bool {
        stepTimeout.isFinite && jobTimeout.isFinite && stepTimeout > 0 && jobTimeout >= stepTimeout && jobTimeout <= 1_000_000_000
            && pcmBudgetBytes > 0 && rasterBudgetBytes > 0
    }
}

/// 프레임 하나에서 스펙트럼 하나의 결과(아래에서 위 차례로 돌려준다). rendered가 nil이면 그릴 것이 없다(캔버스 밖 전체).
struct SpectrumTimelineLayer: @unchecked Sendable {   // CGImage는 불변(SpectrumRenderedFrame과 같음)
    let spectrumID: UUID, lane: UUID
    let bands: [Float]
    let rendered: SpectrumRenderedFrame?
}

final class SpectrumTimelineFrames: ExportFrameOverlay, @unchecked Sendable {
    static let fps = 30
    let stepTimeout: Double, jobTimeout: Double
    private let assets: [MediaAsset]
    private let worker: SpectrumTimelineWorker
    private let scopes: [URL]

    /// 만들 때 모두 확인한다: 한도, 타임라인, 막는 스펙트럼(D-S3·D-S8), 소스 원본의 존재·정체.
    /// assets는 내보내기에 쓰는 원본 전체다(스펙트럼 소스가 아닌 것도 정체를 본다 — 기존 내부 조각과 같음).
    init(timeline: Timeline, assets: [MediaAsset], limits: SpectrumTimelineExportLimits) throws {
        guard limits.isValid else { throw SpectrumTimelineExportError.invalidLimits }
        guard timeline.isValid, timeline.durationFrames > 0 else { throw SpectrumTimelineExportError.invalidTimeline }
        let blockers = timeline.spectrumExportBlockers()
        guard blockers.isEmpty else { throw SpectrumTimelineExportError.blocked(blockers) }
        let byID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sources: [UUID: MediaAsset] = [:]
        for s in timeline.spectra {
            guard let id = timeline.spectrumMediaID(s), let a = byID[id] else { throw SpectrumTimelineExportError.sourceUnavailable(spectrum: s.id) }
            sources[s.id] = a
        }
        self.assets = assets; stepTimeout = limits.stepTimeout; jobTimeout = limits.jobTimeout
        var held: [URL] = []
        for a in assets where a.url.startAccessingSecurityScopedResource() { held.append(a.url) }
        scopes = held
        worker = SpectrumTimelineWorker(timeline: timeline, sources: sources, limits: limits)
        do { try validateSources() } catch { for url in held { url.stopAccessingSecurityScopedResource() }; throw error }
    }
    deinit { for url in scopes { url.stopAccessingSecurityScopedResource() } }

    func validateSources() throws {
        for a in assets {
            guard FileIdentity.of(a.url) == a.identity, FileManager.default.isReadableFile(atPath: a.url.path) else {
                throw SpectrumTimelineExportError.sourceChanged
            }
        }
    }
    /// 프레임 k의 스펙트럼 결과(아래에서 위). 보이는 것이 없으면 빈 배열.
    func layers(_ frame: Int) async throws -> [SpectrumTimelineLayer] {
        try Task.checkCancellation(); try validateSources()
        let result: [SpectrumTimelineLayer]
        do { result = try await worker.layers(frame) }
        catch SpectrumAnalysisError.cancelled { throw CancellationError() }   // 디코더가 취소를 알아챈 경우도 취소로 돌려준다
        try Task.checkCancellation(); try validateSources()
        return result
    }
    func prepareFootprints(_ frame: Int) async throws -> [SubtitleFootprint] {
        try await layers(frame).compactMap { layer in layer.rendered.map { Self.footprint($0, lane: layer.lane, frame: frame) } }
    }
    func composed(_ frame: Int, source: CVPixelBuffer, output: CVPixelBuffer) {}
    #if DEBUG
    func checkpoint(_ point: SpectrumExportCheckpoint) async {}
    func pausesWriter(at frame: Int) -> Bool { false }
    #endif
    /// 열어 둔 원본과 디코딩한 소리를 놓는다. 그 뒤의 요청은 closed로 거부한다. 여러 번 불러도 된다.
    func close() async { await worker.close() }
    /// 지금 들고 있는 디코딩된 소리(바이트)와 열어 둔 원본 수 — 시험·진단용
    func retained() async -> (pcmBytes: Int, openSources: Int) { await worker.retained() }

    /// 그림 하나를 4:2:0 합성 발자국으로(기존 내부 조각과 같은 꼴: 전체 화면 사각형 안의 drawRect에 놓는다)
    static func footprint(_ r: SpectrumRenderedFrame, lane: UUID, frame: Int) -> SubtitleFootprint {
        let full = CGRect(x: 0, y: 0, width: SubtitleFootprint.w, height: SubtitleFootprint.h)
        let raster = SubtitleRaster(image: r.image, rect: full, fontUsed: "", missingFont: false, fallbackFonts: [], lines: 0, textBounds: .zero,
                                    failed: false, clipped: false, hitRect: .zero, drawRect: r.drawRect)
        return SubtitleFootprint(SubtitleItem(lane: lane, start: frame, length: 1, text: ""), raster)
    }
}

/// 한 번에 한 프레임만 계산한다. 원본은 미디어마다 한 번 열어 다시 쓰고, 디코딩한 소리는 지금 프레임이 읽는 덩어리만 들고 있는다.
actor SpectrumTimelineWorker {
    private let timeline: Timeline, sources: [UUID: MediaAsset], limits: SpectrumTimelineExportLimits
    private var files: [UUID: SpectrumFileSource] = [:]          // 미디어 ID → 연 원본
    private var chunks: [UUID: [Int: [[Float]]]] = [:]           // 미디어 ID → 덩어리 번호 → 채널별 표본
    private var renderer: SpectrumFrameRenderer?
    private var busy = false, closed = false

    init(timeline: Timeline, sources: [UUID: MediaAsset], limits: SpectrumTimelineExportLimits) {
        self.timeline = timeline; self.sources = sources; self.limits = limits
    }
    func close() { closed = true; files = [:]; chunks = [:]; renderer = nil }
    func retained() -> (pcmBytes: Int, openSources: Int) { (pcmBytes, files.count) }
    private var pcmBytes: Int {
        chunks.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count * MemoryLayout<Float>.stride } } }
    }

    func layers(_ k: Int) async throws -> [SpectrumTimelineLayer] {
        guard !closed else { throw SpectrumTimelineExportError.closed }
        guard !busy else { throw SpectrumTimelineExportError.concurrentRequest }
        guard k >= 0, k < timeline.durationFrames else { throw SpectrumTimelineExportError.frameOutOfRange(k) }
        busy = true
        defer { busy = false }
        // 프리뷰와 같은 차례: 타임라인은 위 레인을 먼저 담고, 그릴 때는 아래부터다
        let visible = timeline.spectra.reversed().filter { $0.visible(atFrame: k) }
        guard !visible.isEmpty else { chunks = [:]; return [] }
        let plans = try await plans(visible, frame: k)
        try await load(plans)
        return try render(plans, frame: k)
    }

    private struct Plan {
        let entry: SpectrumItem, media: UUID, pieces: [SpectrumSourcePiece], needed: [Int]
    }
    private func file(_ entry: SpectrumItem) async throws -> (UUID, SpectrumFileSource) {
        guard let asset = sources[entry.id] else { throw SpectrumTimelineExportError.sourceUnavailable(spectrum: entry.id) }
        if let f = files[asset.id] { return (asset.id, f) }
        let f = try await SpectrumFileSource.open(url: asset.url, mediaID: asset.id)
        guard !closed else { throw SpectrumTimelineExportError.closed }
        files[asset.id] = f
        return (asset.id, f)
    }
    /// 보이는 스펙트럼마다: 상태 확인 → 원본 → 조각 → 이 프레임의 창이 읽는 덩어리
    private func plans(_ visible: [SpectrumItem], frame k: Int) async throws -> [Plan] {
        var out: [Plan] = []
        for entry in visible {
            let state = timeline.spectrumFrameState(entry, atFrame: k)
            guard state == .ok else { throw SpectrumTimelineExportError.frameState(spectrum: entry.id, frame: k, state: state) }
            let (media, f) = try await file(entry)
            let pieces = timeline.spectrumPieces(entry)
            let needed = try SpectrumAnalysis.chunks(frame: k, pieces: pieces, fps: SpectrumTimelineFrames.fps, rate: f.sampleRate,
                                                     settings: entry.style.analysisSettings, chunkSamples: f.chunkSamples)
            out.append(Plan(entry: entry, media: media, pieces: pieces, needed: needed))
        }
        return out
    }
    /// 이 프레임이 읽는 덩어리만 남기고 나머지는 버린 뒤, 없는 것을 디코딩한다. 디코딩 전에 상한을 본다.
    private func load(_ plans: [Plan]) async throws {
        var wanted: [UUID: Set<Int>] = [:]
        for p in plans { wanted[p.media, default: []].formUnion(p.needed) }
        var bytes = 0
        for (media, set) in wanted {
            guard let f = files[media] else { continue }
            bytes += set.count * f.chunkSamples * f.channelCount * MemoryLayout<Float>.stride
        }
        guard bytes <= limits.pcmBudgetBytes else { throw SpectrumTimelineExportError.pcmBudgetExceeded(bytes: bytes) }
        chunks = chunks.filter { wanted[$0.key] != nil }
        for (media, set) in wanted {
            guard let f = files[media] else { continue }
            var have = (chunks[media] ?? [:]).filter { set.contains($0.key) }
            for index in set.sorted() where have[index] == nil {
                try Task.checkCancellation()
                have[index] = try await f.decodeChunk(index)
                guard !closed else { throw SpectrumTimelineExportError.closed }
            }
            chunks[media] = have
        }
        try Task.checkCancellation()
    }
    private func render(_ plans: [Plan], frame k: Int) throws -> [SpectrumTimelineLayer] {
        if renderer == nil { renderer = try SpectrumFrameRenderer(width: SubtitleFootprint.w, height: SubtitleFootprint.h) }
        guard let renderer else { throw SpectrumTimelineExportError.closed }
        var out: [SpectrumTimelineLayer] = [], rasterBytes = 0
        for p in plans {
            guard let f = files[p.media] else { throw SpectrumTimelineExportError.sourceUnavailable(spectrum: p.entry.id) }
            let cache = chunks[p.media] ?? [:]
            let bands = try SpectrumAnalysis.bands(frame: k, pieces: p.pieces, fps: SpectrumTimelineFrames.fps, rate: f.sampleRate, channelCount: f.channelCount,
                                                   chunkSamples: f.chunkSamples, settings: p.entry.style.analysisSettings) { cache[$0] }
            let rendered = try renderer.render(bands: bands, style: p.entry.style)
            if let r = rendered { rasterBytes += r.image.bytesPerRow * r.image.height }
            guard rasterBytes <= limits.rasterBudgetBytes else { throw SpectrumTimelineExportError.rasterBudgetExceeded(bytes: rasterBytes) }
            out.append(SpectrumTimelineLayer(spectrumID: p.entry.id, lane: p.entry.lane, bands: bands, rendered: rendered))
        }
        return out
    }
}
