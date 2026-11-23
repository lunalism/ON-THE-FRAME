import AVFoundation
import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E2 시험 재료: 생성한 WAV, 스펙트럼이 든 타임라인, 프리뷰와 같은 함수를 직접 부른 기준값.
enum SpectrumTimelineFixture {
    struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
    static let limits = SpectrumTimelineExportLimits(stepTimeout: 30, jobTimeout: 600)

    /// 48 kHz WAV. value(표본, 채널) → −1…1
    static func writeWAV(_ url: URL, seconds: Int, channels: Int, _ value: (Int, Int) -> Double) throws {
        let n = seconds * 48_000
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels)),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)), let data = buf.floatChannelData else { throw Failure("wav buffer") }
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<channels { for i in 0..<n { data[c][i] = Float(value(i, c)) } }
        let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
                                                          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        try f.write(from: buf)
    }
    static func tone(_ hz: Double, _ amplitude: Double = 0.5) -> (Int, Int) -> Double {
        { i, _ in amplitude * sin(2 * Double.pi * hz * Double(i) / 48_000) }
    }

    /// 프리뷰가 쓰는 함수를 직접 부른 기준: 그 스펙트럼의 프레임 k 밴드와 그림
    static func reference(_ t: Timeline, _ s: SpectrumItem, frame k: Int, asset: MediaAsset) async throws -> (bands: [Float], rendered: SpectrumRenderedFrame?) {
        let src = try await SpectrumFileSource.open(url: asset.url, mediaID: asset.id)
        let pieces = t.spectrumPieces(s), settings = s.style.analysisSettings
        var decoded: [Int: [[Float]]] = [:]
        for c in try SpectrumAnalysis.chunks(frame: k, pieces: pieces, fps: 30, rate: src.sampleRate, settings: settings, chunkSamples: src.chunkSamples) {
            decoded[c] = try await src.decodeChunk(c)
        }
        let bands = try SpectrumAnalysis.bands(frame: k, pieces: pieces, fps: 30, rate: src.sampleRate, channelCount: src.channelCount,
                                               chunkSamples: src.chunkSamples, settings: settings) { decoded[$0] }
        let rendered = try SpectrumFrameRenderer(width: 1920, height: 1080).render(bands: bands, style: s.style)
        return (bands, rendered)
    }
    static func bytes(_ r: SpectrumRenderedFrame?) -> Data? { r.flatMap { $0.image.dataProvider?.data as Data? } }
    /// 두 그림이 같은가(놓는 사각형, 크기, 바이트)
    static func same(_ a: SpectrumRenderedFrame?, _ b: SpectrumRenderedFrame?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.drawRect == y.drawRect && x.image.width == y.image.width && x.image.height == y.image.height && bytes(x) == bytes(y)
        default: return false
        }
    }
    /// 칠한 화소 수(알파 > 0)
    static func painted(_ r: SpectrumRenderedFrame?) -> Int {
        guard let r, let d = bytes(r) else { return 0 }
        var n = 0
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<r.image.height { for x in 0..<r.image.width where p[y * r.image.bytesPerRow + x * 4 + 3] > 0 { n += 1 } }
        }
        return n
    }
}

/// 시험마다 새 임시 폴더와, 흔히 쓰는 타임라인(소리 클립 하나 + 스펙트럼 레인 둘)
class SpectrumTimelineTestCase: XCTestCase {
    typealias Fx = SpectrumTimelineFixture
    var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("otf-sptl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func media(_ name: String, seconds: Int = 4, channels: Int = 2, _ value: @escaping (Int, Int) -> Double) async throws -> MediaAsset {
        let url = dir.appendingPathComponent(name)
        try Fx.writeWAV(url, seconds: seconds, channels: channels, value)
        return try await MediaProbe.inspect(url)
    }
    struct Scene {
        var timeline: Timeline
        let clip: UUID, key: UUID, low: UUID, high: UUID
    }
    /// 소리 클립(시작 at, 원본 전체)과 스펙트럼 레인 둘(SP1, SP2). 스펙트럼은 시험이 놓는다.
    func scene(_ m: MediaAsset, at: Int = 0, others: [MediaAsset] = []) throws -> Scene {
        let clip = UUID(), low = UUID(), high = UUID()
        var t = others.reduce(Timeline().registering(m)) { $0.registering($1) }
        t = try t.placing(media: m.id, at: at, videoLane: nil, audioLane: Lane.audioID, clipID: clip)
        t = try t.addingLane(.spectrum, name: "SP1", id: low).addingLane(.spectrum, name: "SP2", id: high)
        XCTAssertTrue(t.isValid)
        let key = try XCTUnwrap(t.clip(clip)).lineageKey
        return Scene(timeline: t, clip: clip, key: key, low: low, high: high)
    }
    func provider(_ t: Timeline, _ assets: [MediaAsset], limits: SpectrumTimelineExportLimits = SpectrumTimelineFixture.limits) throws -> SpectrumTimelineFrames {
        try SpectrumTimelineFrames(timeline: t, assets: assets, limits: limits)
    }
    func analog(_ base: SpectrumItemStyle = .provisionalDefault) -> SpectrumItemStyle { var s = base; s.mode = .analog; return s }
}
