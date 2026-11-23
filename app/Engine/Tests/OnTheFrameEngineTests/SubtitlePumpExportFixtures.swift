import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E2 회귀: 자막이 있는 프로젝트를 제품 경로(ExportService.export → SubtitleExporter.encode → Pump.videoStep)로
/// 한 번 내보내고, 결과 MP4를 디코딩해 프레임마다 요약만 남긴다(프레임 그림을 쌓지 않는다).
/// 재료: 생성한 2 s 영상(320×180 단색 어두운 회색, AAC 소리 — 1.0 s에 1 kHz 소리가 시작)과 흰 자막 하나.
enum SubtitlePumpFixture {
    static let frames = 60, subtitleStart = 20, subtitleEnd = 40
    /// 밝기 문턱(8비트 비디오 범위 Y). 흰 글자는 235, 배경(BGRA 64)은 약 71이다. 그 사이에 여유를 둔다.
    static let brightLuma: UInt8 = 180, hotLuma: UInt8 = 140
    /// 자막 그림 사각형 밖으로 허용하는 가장자리 번짐(색차 4:2:0과 H.264 블록 경계)
    static let margin = 8

    struct FrameStat {
        var bright = 0, brightInside = 0, hotOutside = 0
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var cbSum = 0, crSum = 0
        var meanCb: Double { bright > 0 ? Double(cbSum) / Double(bright) : 128 }
        var meanCr: Double { bright > 0 ? Double(crSum) / Double(bright) : 128 }
    }
    /// 자막 그림에서 계산한 기대값(출력 좌표): 그림을 놓는 사각형, 불투명한 글자 화소 수와 그 테두리
    struct Expected { let rect: CGRect; let opaque: Int; let anyAlpha: Int; let bounds: CGRect }
    struct Exported {
        let source: URL, sourceHash: String, output: URL, tempDirectory: URL?
        let outcome: ExportOutcome, timelineUnchanged: Bool, planSubtitles: Int
        let width: Int, height: Int, videoTracks: Int, audioTracks: Int, durationFrames: Int
        let stats: [Int: FrameStat], audioOnsets: [Int], expected: Expected
    }
    nonisolated(unsafe) static var cached: Exported?

    static func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    static let style: SubtitleStyle = {
        var s = SubtitleStyle.default
        s.sizeTenths = 720; s.xMilli = 960_000; s.yMilli = 300_000   // 기본 위치(아래)가 아닌 곳: 위치 보존을 본다
        return s
    }()
    /// 영상+소리 클립 [0, 60)과 자막 [20, 40)
    static func timeline(_ m: MediaAsset) throws -> (Timeline, SubtitleItem) {
        let lane = UUID(), id = UUID()
        let t = try Timeline().registering(m).inserting(media: m.id).addingLane(.subtitle, name: "S1", id: lane)
            .addingSubtitle(lane: lane, at: subtitleStart, length: subtitleEnd - subtitleStart, text: "ON THE FRAME", style: style, id: id)
        guard let item = t.subtitles.first(where: { $0.id == id }) else { throw SourceTimeFixture.Failure("subtitle") }
        return (t, item)
    }
    static func expected(_ item: SubtitleItem) throws -> Expected {
        let r = SubtitleRenderer.shared.raster(item)
        guard !r.failed, let data = r.image.dataProvider?.data as Data? else { throw SourceTimeFixture.Failure("raster") }
        let w = r.image.width, h = r.image.height, bpr = r.image.bytesPerRow
        var opaque = 0, any = 0, x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<h { for x in 0..<w {
                let a = p[y * bpr + x * 4 + 3]
                if a > 0 { any += 1 }
                if a > 200 { opaque += 1; x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) }
            } }
        }
        guard opaque > 0 else { throw SourceTimeFixture.Failure("empty raster") }
        let bounds = CGRect(x: Int(r.drawRect.minX) + x0, y: Int(r.drawRect.minY) + y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
        return Expected(rect: r.drawRect, opaque: opaque, anyAlpha: any, bounds: bounds)
    }

    /// 한 프레임(잠근 420v 버퍼)의 요약
    static func stat(_ pb: CVPixelBuffer, expected e: Expected) -> FrameStat {
        var s = FrameStat()
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return s }
        let y = yBase.assumingMemoryBound(to: UInt8.self), c = cBase.assumingMemoryBound(to: UInt8.self)
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let rx0 = Int(e.rect.minX), ry0 = Int(e.rect.minY), rx1 = Int(e.rect.maxX), ry1 = Int(e.rect.maxY), m = margin
        for row in 0..<h {
            let line = y + row * ybpr
            let rowInside = row >= ry0 && row < ry1, rowNear = row >= ry0 - m && row < ry1 + m
            for x in 0..<w {
                let v = line[x]
                guard v > hotLuma else { continue }
                if !(rowNear && x >= rx0 - m && x < rx1 + m) { s.hotOutside += 1 }
                guard v > brightLuma else { continue }
                s.bright += 1
                if rowInside && x >= rx0 && x < rx1 { s.brightInside += 1 }
                s.minX = min(s.minX, x); s.maxX = max(s.maxX, x); s.minY = min(s.minY, row); s.maxY = max(s.maxY, row)
                let q = c + (row / 2) * cbpr + 2 * (x / 2)
                s.cbSum += Int(q[0]); s.crSum += Int(q[1])
            }
        }
        return s
    }
    /// 결과 MP4의 영상을 프레임마다 읽어 요약한다(프레임 번호 = 표시 시각 × 30)
    static func videoStats(_ url: URL, expected e: Expected) async throws -> (stats: [Int: FrameStat], width: Int, height: Int, tracks: Int, codec: String) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return ([:], 0, 0, 0, "") }
        let size = try await track.load(.naturalSize)
        let sub = try await track.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let codec = String(bytes: [24, 16, 8, 0].map { UInt8((sub >> $0) & 0xff) }, encoding: .ascii) ?? "\(sub)"
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(out)
        guard reader.startReading() else { throw SourceTimeFixture.Failure("video reader: \(String(describing: reader.error))") }
        var stats: [Int: FrameStat] = [:]
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let k = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded())
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            stats[k] = stat(pb, expected: e)
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        guard reader.status != .failed else { throw SourceTimeFixture.Failure("video read: \(String(describing: reader.error))") }
        return (stats, Int(size.width), Int(size.height), tracks.count, codec)
    }
    /// 결과 MP4의 소리 트랙 수와, 첫 트랙에서 소리가 시작하는 표본(48 kHz)
    static func audio(_ url: URL) async throws -> (tracks: Int, onsets: [Int]) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return (0, []) }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(out)
        guard reader.startReading() else { throw SourceTimeFixture.Failure("audio reader: \(String(describing: reader.error))") }
        var left: [Float] = []
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            for i in stride(from: 0, to: n - 1, by: 2) { left.append(chunk[i]) }
        }
        return (tracks.count, SourceTimeFixture.onsets(left))
    }

    /// 한 번만 만든다: 재료 → 제품 경로 내보내기 → 결과 요약. dir은 시험 묶음이 지운다.
    static func exported(in dir: URL) async throws -> Exported {
        if let cached { return cached }
        let source = dir.appendingPathComponent("gray-burst.mov"), output = dir.appendingPathComponent("out/subtitle.mp4")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await SourceTimeFixture.write(source, type: .mov, audio: SourceTimeFixture.aac, audioStart: 0, video: true)
        let hash = try sha(source)
        let m = try await MediaProbe.inspect(source)
        let (t, item) = try timeline(m)
        let snapshot = t, e = try expected(item)
        let plan = try await CompositionPlanner.plan(t, media: [m.id: m])
        let temp = TempBox()
        let options = ExportService.Options(onTempDirectory: { temp.set($0) })
        let outcome = await ExportService.export(plan, to: .fromSavePanel(output), sources: [m], options: options) { _ in }
        var video: (stats: [Int: FrameStat], width: Int, height: Int, tracks: Int, codec: String) = ([:], 0, 0, 0, "")
        var sound: (tracks: Int, onsets: [Int]) = (0, [])
        if FileManager.default.fileExists(atPath: output.path) {
            video = try await videoStats(output, expected: e)
            sound = try await audio(output)
        }
        let result = Exported(source: source, sourceHash: hash, output: output, tempDirectory: temp.url, outcome: outcome, timelineUnchanged: t == snapshot,
                              planSubtitles: plan.subtitles.count, width: video.width, height: video.height, videoTracks: video.tracks, audioTracks: sound.tracks,
                              durationFrames: plan.durationFrames, stats: video.stats, audioOnsets: sound.onsets, expected: e)
        cached = result
        print(summary(result, codec: video.codec))
        return result
    }
    /// 측정값 한 묶음(보고용 — 판정은 시험이 한다)
    static func summary(_ x: Exported, codec: String) -> String {
        let shown = x.stats.filter { $0.value.bright > 0 }.keys.sorted()
        let mid = x.stats[30] ?? FrameStat(), e = x.expected
        let inside = shown.compactMap { x.stats[$0]?.brightInside }
        return """
        SUBTITLE PUMP MEASUREMENTS
          outcome \(x.outcome) codec \(codec) size \(x.width)x\(x.height) videoTracks \(x.videoTracks) audioTracks \(x.audioTracks)
          decoded frames \(x.stats.count) (\(x.stats.keys.min() ?? -1)...\(x.stats.keys.max() ?? -1)) plan frames \(x.durationFrames)
          frames with bright pixels: \(shown.first.map(String.init) ?? "-")...\(shown.last.map(String.init) ?? "-") count \(shown.count)
          expected raster rect \(e.rect) glyph bounds \(e.bounds) opaque \(e.opaque) anyAlpha \(e.anyAlpha)
          frame 30: bright \(mid.bright) inside \(mid.brightInside) bbox x \(mid.minX)...\(mid.maxX) y \(mid.minY)...\(mid.maxY) meanCb \(mid.meanCb) meanCr \(mid.meanCr)
          brightInside over shown frames: min \(inside.min() ?? 0) max \(inside.max() ?? 0); hotOutside max \(x.stats.values.map(\.hotOutside).max() ?? 0)
          audio onsets \(x.audioOnsets) (expected \(SourceTimeFixture.burstStart)); source sha256 \(x.sourceHash.prefix(16))…
          temp directory \(x.tempDirectory?.path ?? "-") exists \(x.tempDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        """
    }
    final class TempBox: @unchecked Sendable {
        private let lock = NSLock(); private var value: URL?
        func set(_ u: URL) { lock.lock(); value = u; lock.unlock() }
        var url: URL? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
