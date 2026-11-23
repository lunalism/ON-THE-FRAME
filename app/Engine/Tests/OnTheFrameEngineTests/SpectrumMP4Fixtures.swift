import AVFoundation
import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import XCTest
import os

/// SP-EXPORT-E4a 시험 재료: 스펙트럼이 든 타임라인을 제품 쓰기 경로(DEBUG 전용 진입점 → exportPrepared → SubtitleExporter.encode → Pump.videoStep)로
/// 내보내고, 결과 H.264 MP4를 디코딩해 프레임마다 요약만 남긴다. 프레임 그림을 쌓지 않는다.
/// 배경은 어두운 회색(Y ≈ 71, Cb = Cr = 128)이다. 스펙트럼은 굵은 노랑(Y ≈ 219, Cb ≈ 16) 또는 흰색, 자막은 흰색(Y 235, Cb 128)이다.
/// 다시 인코딩한 화소이므로 바이트가 아니라 문턱값으로 본다: 노랑 = Y > 150 그리고 Cb < 100, 흰색 = Y > 180 그리고 Cb ≥ 100.
enum SpectrumMP4Fixture {
    static let frames = 60
    /// 시험 한도: 프레임 메모리 예산 128 MiB(시험용 값), 프레임당 30초, 전체 300초(60프레임 — 프레임당 5초의 여유). 제품 값이 아니다.
    static let limits = SpectrumTimelineExportLimits(stepTimeout: 30, jobTimeout: 300, frameMemoryBudgetBytes: 128 << 20)
    /// 시험 모양의 막대가 닿을 수 있는 화면 범위(가로 192…1728, 세로 540 ± 200, 두께 16)에 여유를 둔 사각형
    static let zoneX = 160 ..< 1760, zoneY = 316 ..< 764
    struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    static func style(_ mode: SpectrumItemStyle.Mode, red: Int = 255, green: Int = 255, blue: Int = 0) -> SpectrumItemStyle {
        var s = SpectrumItemStyle.provisionalDefault
        s.mode = mode; s.maxHeightMilli = 200_000; s.thicknessMilli = 16_000; s.red = red; s.green = green; s.blue = blue
        return s
    }
    static let subtitleStyle: SubtitleStyle = {
        var s = SubtitleStyle.default
        s.sizeTenths = 720; s.xMilli = 960_000; s.yMilli = 565_000   // 막대 가운데 줄 위에 겹친다
        return s
    }()

    struct Media { let video: MediaAsset, tone: MediaAsset, shortTone: MediaAsset }
    /// 생성 재료(한 번만 쓴다): 2 s 영상(320×180 회색, AAC), 2 s 440 Hz 스테레오 WAV, 1 s 440 Hz WAV
    static func media(in dir: URL) async throws -> Media {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let video = dir.appendingPathComponent("gray.mov"), tone = dir.appendingPathComponent("tone.wav"), short = dir.appendingPathComponent("tone-1s.wav")
        if !FileManager.default.fileExists(atPath: video.path) {
            let began = Date()
            try await SourceTimeFixture.write(video, type: .mov, audio: SourceTimeFixture.aac, audioStart: 0, video: true)
            try SpectrumTimelineFixture.writeWAV(tone, seconds: 2, channels: 2, SpectrumTimelineFixture.tone(440))
            try SpectrumTimelineFixture.writeWAV(short, seconds: 1, channels: 2, SpectrumTimelineFixture.tone(440))
            print(String(format: "SPECTRUM MP4 fixture generation: %.2f s", Date().timeIntervalSince(began)))
        }
        return Media(video: try await MediaProbe.inspect(video), tone: try await MediaProbe.inspect(tone), shortTone: try await MediaProbe.inspect(short))
    }
    struct Base { var timeline: Timeline; let key: UUID, low: UUID, high: UUID, clip: UUID }
    /// 영상+소리 클립 [0, 60), 둘째 소리 레인의 WAV 클립(시작 at), 스펙트럼 레인 둘
    static func base(_ m: Media, source: MediaAsset, at: Int = 0) throws -> Base {
        let a2 = UUID(), clip = UUID(), low = UUID(), high = UUID()
        var t = Timeline().registering(m.video).registering(source)
        t = try t.inserting(media: m.video.id).addingLane(.audio, name: "A2", id: a2)
        t = try t.placing(media: source.id, at: at, videoLane: nil, audioLane: a2, clipID: clip)
        t = try t.addingLane(.spectrum, name: "SP1", id: low).addingLane(.spectrum, name: "SP2", id: high)
        guard t.isValid, let key = t.clip(clip)?.lineageKey else { throw Failure("timeline") }
        return Base(timeline: t, key: key, low: low, high: high, clip: clip)
    }

    // MARK: 기대값(공급기의 그림에서)

    /// peak: 그 프레임의 가장 큰 밴드 값(무음이면 0)
    struct Shape { let id: UUID, opaque: Int, anyAlpha: Int, bounds: CGRect, peak: Float }
    /// 프레임 k의 층마다(아래에서 위): 불투명한 화소 수와 그 테두리(출력 좌표)
    static func shapes(_ t: Timeline, _ assets: [MediaAsset], frame k: Int) async throws -> [Shape] {
        try await shapes(t, assets, frames: [k])[k] ?? []
    }
    /// 여러 프레임을 공급기 하나로(프레임 번호 차례)
    static func shapes(_ t: Timeline, _ assets: [MediaAsset], frames: [Int]) async throws -> [Int: [Shape]] {
        let p = try SpectrumTimelineFrames(timeline: t, assets: assets, limits: limits)
        var out: [Int: [Shape]] = [:]
        do { for k in frames.sorted() { out[k] = try await p.layers(k).compactMap(shape) } }
        catch { await p.close(); throw error }
        await p.close()
        return out
    }
    static func shape(_ layer: SpectrumTimelineLayer) -> Shape? {
        guard let r = layer.rendered, let data = r.image.dataProvider?.data as Data? else { return nil }
        let w = r.image.width, h = r.image.height, bpr = r.image.bytesPerRow, peak = layer.bands.max() ?? 0
        var opaque = 0, any = 0, x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for y in 0..<h { for x in 0..<w {
                let a = b[y * bpr + x * 4 + 3]
                if a > 0 { any += 1 }
                if a > 200 { opaque += 1; x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) }
            } }
        }
        guard opaque > 0 else { return Shape(id: layer.spectrumID, opaque: 0, anyAlpha: any, bounds: .zero, peak: peak) }
        return Shape(id: layer.spectrumID, opaque: opaque, anyAlpha: any,
                     bounds: CGRect(x: Int(r.drawRect.minX) + x0, y: Int(r.drawRect.minY) + y0, width: x1 - x0 + 1, height: y1 - y0 + 1), peak: peak)
    }
    /// 프레임 k의 층마다(아래에서 위) 출력 화면(1920×1080) 크기의 알파
    static func alphaMaps(_ t: Timeline, _ assets: [MediaAsset], frame k: Int) async throws -> [(id: UUID, alpha: [UInt8])] {
        let p = try SpectrumTimelineFrames(timeline: t, assets: assets, limits: limits)
        let layers: [SpectrumTimelineLayer]
        do { layers = try await p.layers(k) } catch { await p.close(); throw error }
        await p.close()
        return layers.compactMap { layer in
            guard let r = layer.rendered, let data = r.image.dataProvider?.data as Data? else { return nil }
            let w = r.image.width, h = r.image.height, bpr = r.image.bytesPerRow, ox = Int(r.drawRect.minX), oy = Int(r.drawRect.minY)
            var map = [UInt8](repeating: 0, count: 1920 * 1080)
            data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for y in 0..<h where oy + y >= 0 && oy + y < 1080 { for x in 0..<w where ox + x >= 0 && ox + x < 1920 {
                    map[(oy + y) * 1920 + ox + x] = b[y * bpr + x * 4 + 3]
                } }
            }
            return (layer.spectrumID, map)
        }
    }
    /// 두 층의 그림에서 고른 확인 자리(y · 1920 + x). 가장자리의 번짐(4:2:0 색, 압축)을 피하려고 둘레 margin 화소가 모두 같은 상태인 곳만 쓴다.
    /// overlap: 두 층이 모두 불투명, topOnly: 위 층만 불투명하고 아래 층은 투명, bottomOnly: 아래 층만 불투명하고 위 층은 투명
    struct Regions { var overlap: [Int32] = [], topOnly: [Int32] = [], bottomOnly: [Int32] = [] }
    static func regions(bottom: [UInt8], top: [UInt8], margin m: Int = 3) -> Regions {
        func all(_ a: [UInt8], _ x: Int, _ y: Int, _ ok: (UInt8) -> Bool) -> Bool {
            guard x >= m, x < 1920 - m, y >= m, y < 1080 - m else { return false }
            for dy in -m...m { for dx in -m...m where !ok(a[(y + dy) * 1920 + x + dx]) { return false } }
            return true
        }
        var r = Regions()
        for y in 0..<1080 { for x in 0..<1920 {
            let i = y * 1920 + x
            guard top[i] > 200 || bottom[i] > 200 else { continue }
            let solidTop = all(top, x, y) { $0 > 200 }, solidBottom = all(bottom, x, y) { $0 > 200 }
            if solidTop && solidBottom { r.overlap.append(Int32(i)) }
            else if solidTop && all(bottom, x, y, { $0 == 0 }) { r.topOnly.append(Int32(i)) }
            else if solidBottom && all(top, x, y, { $0 == 0 }) { r.bottomOnly.append(Int32(i)) }
        } }
        return r
    }
    /// 계산한 프레임 메모리 장부의 최고값: 내보내기와 같은 공급기 호출(prepareFootprints)을 따로 한 번 더 해서 잰다(내보내기 안의 값을 읽은 것이 아니다)
    static func ledgerPeak(_ t: Timeline, _ assets: [MediaAsset], frames: [Int]) async throws -> Int {
        let p = try SpectrumTimelineFrames(timeline: t, assets: assets, limits: limits)
        var peak = 0
        do { for k in frames.sorted() { _ = try await p.prepareFootprints(k); peak = max(peak, await p.memory().peakBytes) } }
        catch { await p.close(); throw error }
        await p.close()
        return peak
    }
    /// 자막 글자의 불투명한 화소 위치(y · 1920 + x)
    static func glyphMask(_ item: SubtitleItem) throws -> [Int32] {
        let r = SubtitleRenderer.shared.raster(item)
        guard !r.failed, let data = r.image.dataProvider?.data as Data? else { throw Failure("subtitle raster") }
        let w = r.image.width, h = r.image.height, bpr = r.image.bytesPerRow, ox = Int(r.drawRect.minX), oy = Int(r.drawRect.minY)
        var mask: [Int32] = []
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for y in 0..<h { for x in 0..<w where b[y * bpr + x * 4 + 3] > 200 {
                let fx = ox + x, fy = oy + y
                if fx >= 0, fx < 1920, fy >= 0, fy < 1080 { mask.append(Int32(fy * 1920 + fx)) }
            } }
        }
        return mask
    }

    // MARK: 결과 MP4의 프레임 요약

    struct Probe { var total = 0, yellow = 0, white = 0 }
    struct FrameStat {
        var yellow = 0, white = 0, hotOutside = 0
        /// 확인 자리 묶음마다 센 색(같은 문턱값)
        var probes: [Probe] = []
        var whiteAtMask: Int { probes.first?.white ?? 0 }
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min   // 노랑 또는 흰색 화소의 테두리(범위 안)
        var painted: Int { yellow + white }
    }
    static func stat(_ pb: CVPixelBuffer, probes: [[Int32]]) -> FrameStat {
        var s = FrameStat()
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return s }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let y = yBase.assumingMemoryBound(to: UInt8.self), c = cBase.assumingMemoryBound(to: UInt8.self)
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for row in 0..<h {
            let line = y + row * ybpr, chroma = c + (row / 2) * cbpr
            let inRows = zoneY.contains(row)
            for x in 0..<w {
                let v = line[x]
                guard v > 140 else { continue }
                guard inRows, zoneX.contains(x) else { s.hotOutside += 1; continue }
                guard v > 150 else { continue }
                let cb = chroma[2 * (x / 2)]
                if cb < 100 { s.yellow += 1 } else if v > 180 { s.white += 1 } else { continue }
                s.minX = min(s.minX, x); s.maxX = max(s.maxX, x); s.minY = min(s.minY, row); s.maxY = max(s.maxY, row)
            }
        }
        for mask in probes {
            var p = Probe(total: mask.count)
            for i in mask {
                let row = Int(i) / 1920, x = Int(i) % 1920
                guard row < h, x < w else { continue }
                let v = y[row * ybpr + x], cb = c[(row / 2) * cbpr + 2 * (x / 2)]
                if v > 150, cb < 100 { p.yellow += 1 } else if v > 180, cb >= 100 { p.white += 1 }
            }
            s.probes.append(p)
        }
        return s
    }
    struct Decoded { var stats: [Int: FrameStat] = [:]; var width = 0, height = 0, videoTracks = 0, audioTracks = 0; var codec = ""; var audioOnsets: [Int] = [] }
    static func decode(_ url: URL, probes: [[Int32]] = []) async throws -> Decoded {
        var d = Decoded()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        d.videoTracks = tracks.count
        guard let track = tracks.first else { return d }
        let size = try await track.load(.naturalSize)
        d.width = Int(size.width); d.height = Int(size.height)
        let sub = try await track.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        d.codec = String(bytes: [24, 16, 8, 0].map { UInt8((sub >> $0) & 0xff) }, encoding: .ascii) ?? "\(sub)"
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(out)
        guard reader.startReading() else { throw Failure("video reader: \(String(describing: reader.error))") }
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let k = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded())
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            d.stats[k] = stat(pb, probes: probes)
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        guard reader.status != .failed else { throw Failure("video read: \(String(describing: reader.error))") }
        let sound = try await SubtitlePumpFixture.audio(url)
        d.audioTracks = sound.tracks; d.audioOnsets = sound.onsets
        return d
    }

    // MARK: 내보내기

    /// exportSeconds: ExportService 호출만의 시간, decodeSeconds: 결과 MP4를 디코딩해 요약한 시간(기록일 뿐 합격 기준이 아니다)
    struct Run { let outcome: ExportOutcome, output: URL, temp: URL?, decoded: Decoded, exportSeconds: Double, decodeSeconds: Double, profile: SpectrumExportProfile? }
    /// 제품 쓰기 경로로 내보내고(대상 폴더는 새로 만든다) 결과가 있으면 디코딩한다
    static func export(_ t: Timeline, _ assets: [MediaAsset], to output: URL, probes: [[Int32]] = [], limits: SpectrumTimelineExportLimits = limits) async throws -> Run {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = SubtitlePumpFixture.TempBox()
        let options = ExportService.Options(onTempDirectory: { temp.set($0) })
        let media = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let profile = OSAllocatedUnfairLock<SpectrumExportProfile?>(initialState: nil)
        let began = Date()
        let outcome = await ExportService.exportSpectrumTimeline(t, media: media, enabled: true, to: .fromSavePanel(output), limits: limits, options: options,
                                                                 profile: { p in profile.withLock { $0 = p } })
        let exported = Date()
        let decoded = FileManager.default.fileExists(atPath: output.path) ? try await decode(output, probes: probes) : Decoded()
        return Run(outcome: outcome, output: output, temp: temp.url, decoded: decoded,
                   exportSeconds: exported.timeIntervalSince(began), decodeSeconds: Date().timeIntervalSince(exported), profile: profile.withLock { $0 })
    }
    static func describe(_ name: String, _ run: Run, frames: [Int]) -> String {
        var lines = ["SPECTRUM MP4 \(name): outcome \(run.outcome) codec \(run.decoded.codec) \(run.decoded.width)x\(run.decoded.height) frames \(run.decoded.stats.count) audioTracks \(run.decoded.audioTracks)"]
        lines.append(String(format: "  export %.2f s (%.1f frames/s), decode and summary %.2f s; first audio onsets (48 kHz samples) ", run.exportSeconds,
                            Double(run.decoded.stats.count) / max(run.exportSeconds, 0.001), run.decodeSeconds) + "\(run.decoded.audioOnsets.prefix(3))")
        lines.append(contentsOf: run.profile?.lines() ?? ["  profile: none"])
        let shown = run.decoded.stats.filter { $0.value.painted > 0 }.keys.sorted()
        lines.append("  frames with spectrum-coloured pixels: \(shown.first.map(String.init) ?? "-")...\(shown.last.map(String.init) ?? "-") count \(shown.count); hotOutside max \(run.decoded.stats.values.map(\.hotOutside).max() ?? 0)")
        for k in frames {
            guard let s = run.decoded.stats[k] else { continue }
            lines.append("  frame \(k): yellow \(s.yellow) white \(s.white) probes \(s.probes.map { "\($0.yellow)y/\($0.white)w/\($0.total)" }) bbox x \(s.minX)...\(s.maxX) y \(s.minY)...\(s.maxY)")
        }
        return lines.joined(separator: "\n")
    }
}

/// E4a 시험 묶음의 공통: 외부 폴더(OTF_SPECTRUM_MP4_DIR)가 있으면 거기에 쓰고 남긴다. 없으면 임시 폴더에 쓰고 지운다.
class SpectrumMP4TestCase: XCTestCase {
    typealias Fx = SpectrumMP4Fixture
    static let keptDir = ProcessInfo.processInfo.environment["OTF_SPECTRUM_MP4_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let root = keptDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("otf-spmp4-\(UUID().uuidString)", isDirectory: true)
    nonisolated(unsafe) static var runs: [String: SpectrumMP4Fixture.Run] = [:]
    var dir: URL { Self.root }
    func media() async throws -> Fx.Media { try await Fx.media(in: dir.appendingPathComponent("sources")) }
    /// 같은 이름의 내보내기는 한 번만 한다
    func run(_ name: String, probes: [[Int32]] = [], frames: [Int] = [10, 16, 30, 44, 50], _ make: () async throws -> (Timeline, [MediaAsset])) async throws -> Fx.Run {
        if let r = Self.runs[name] { return r }
        let (t, assets) = try await make()
        let r = try await Fx.export(t, assets, to: dir.appendingPathComponent(name).appendingPathComponent("out.mp4"), probes: probes)
        Self.runs[name] = r
        print(Fx.describe(name, r, frames: frames))
        if case .completed = r.outcome {
            let peak = try await Fx.ledgerPeak(t, assets, frames: frames.filter { (0..<t.durationFrames).contains($0) })
            print(String(format: "  frame memory ledger peak, recomputed for frames \(frames): %.1f MiB of %d MiB", Double(peak) / 1_048_576, Fx.limits.frameMemoryBudgetBytes >> 20))
        }
        return r
    }
    func assertCompleted(_ r: Fx.Run, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(r.outcome, .completed(r.output), file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.output.deletingLastPathComponent().path), ["out.mp4"], file: file, line: line)
        let temp = try XCTUnwrap(r.temp, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "임시 폴더를 지웠다", file: file, line: line)
        XCTAssertEqual(r.decoded.codec, "avc1", file: file, line: line); XCTAssertEqual(r.decoded.width, 1920, file: file, line: line)
        XCTAssertEqual(r.decoded.height, 1080, file: file, line: line); XCTAssertEqual(r.decoded.videoTracks, 1, file: file, line: line)
        XCTAssertEqual(r.decoded.audioTracks, 1, file: file, line: line)
        XCTAssertEqual(r.decoded.stats.keys.sorted(), Array(0..<Fx.frames), "모든 프레임을 디코딩했다", file: file, line: line)
        XCTAssertEqual(r.decoded.stats.values.map(\.hotOutside).max(), 0, "스펙트럼 범위 밖은 배경 그대로", file: file, line: line)
    }
    /// 디코딩한 프레임의 색 화소 테두리가 공급기 그림의 테두리와 맞는가(± 8 px), 화소 수가 그림과 견줄 만한가
    func assertShape(_ s: Fx.FrameStat, count: Int, _ shape: Fx.Shape, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(count, shape.opaque / 2, "\(label): 색 화소 수(기대 불투명 \(shape.opaque))", file: file, line: line)
        XCTAssertLessThanOrEqual(count, shape.anyAlpha * 13 / 10, "\(label): 그림보다 넓지 않다(기대 \(shape.anyAlpha))", file: file, line: line)
        XCTAssertEqual(Double(s.minX), shape.bounds.minX, accuracy: 8, "\(label) 왼쪽", file: file, line: line)
        XCTAssertEqual(Double(s.maxX), shape.bounds.maxX - 1, accuracy: 8, "\(label) 오른쪽", file: file, line: line)
        XCTAssertEqual(Double(s.minY), shape.bounds.minY, accuracy: 8, "\(label) 위", file: file, line: line)
        XCTAssertEqual(Double(s.maxY), shape.bounds.maxY - 1, accuracy: 8, "\(label) 아래", file: file, line: line)
    }
}
