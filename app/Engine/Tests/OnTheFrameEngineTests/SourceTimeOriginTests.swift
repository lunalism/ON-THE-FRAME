import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// E1(2026-11-23): 재생·Spectrum 분석·파형이 같은 원본 시각을 읽는가.
/// 기준은 실제 재생 구성(CompositionPlanner가 만든 composition을 오디오 믹스로 읽은 소리)이다. 분석 쪽은 Spectrum과 같은
/// 표본 대응(SpectrumAnalysis.sourceSpans → SpectrumFileSource)으로 읽고, 두 쪽에서 소리가 시작하는 타임라인 표본을 비교한다.
final class SourceTimeOriginTests: XCTestCase {
    typealias F = SourceTimeFixture
    var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("otf-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: 계산(파일 없음)

    func testZeroOriginKeepsPreviousSampleFormula() {
        for (value, scale) in [(0, 48_000), (48_000, 48_000), (44_100, 44_100), (1_001, 30_000), (90_000, 90_000), (7, 3)] {
            let t = CMTime(value: CMTimeValue(value), timescale: CMTimeScale(scale))
            let previous = Int(CMTimeConvertScale(t, timescale: 48_000, method: .roundHalfAwayFromZero).value)
            XCTAssertEqual(SourceTimeOrigin.sample(atFileTime: t, rate: 48_000, origin: .zero), previous, "\(value)/\(scale)")
        }
        let r = SourceTimeOrigin.fileRange(samples: 24_000 ..< 72_000, rate: 48_000, origin: .zero)
        XCTAssertEqual(r, CMTimeRange(start: CMTime(value: 24_000, timescale: 48_000), end: CMTime(value: 72_000, timescale: 48_000)))
        XCTAssertEqual(SourceTimeOrigin.normalized(.invalid), .zero)
        XCTAssertEqual(SourceTimeOrigin.normalized(.positiveInfinity), .zero)
        XCTAssertEqual(SourceTimeOrigin.normalized(CMTime(value: 0, timescale: 600)), .zero)
    }
    func testNonzeroOriginShiftsSampleNumbers() {
        let half = CMTime(value: 1, timescale: 2)
        XCTAssertEqual(SourceTimeOrigin.sample(atFileTime: CMTime(value: 72_000, timescale: 48_000), rate: 48_000, origin: half), 48_000)
        XCTAssertEqual(SourceTimeOrigin.sample(atFileTime: half, rate: 48_000, origin: half), 0)
        XCTAssertEqual(SourceTimeOrigin.sample(atFileTime: .zero, rate: 48_000, origin: half), -24_000, "origin보다 앞은 음수 표본")
        // 시간 척도가 서로 달라도 정확히: 원점 1001/30000 s, 그 뒤 1 s
        let odd = CMTime(value: 1_001, timescale: 30_000)
        XCTAssertEqual(SourceTimeOrigin.sample(atFileTime: CMTimeAdd(odd, CMTime(value: 1, timescale: 1)), rate: 48_000, origin: odd), 48_000)
        let r = SourceTimeOrigin.fileRange(samples: 0 ..< 48_000, rate: 48_000, origin: half)
        XCTAssertEqual(r.start, half); XCTAssertEqual(r.end, CMTime(value: 3, timescale: 2))
    }
    func testFileRangeBeforeFileStartIsClamped() {
        let half = CMTime(value: 1, timescale: 2)
        let partly = SourceTimeOrigin.fileRange(samples: -48_000 ..< 48_000, rate: 48_000, origin: half)
        XCTAssertEqual(partly.start, .zero); XCTAssertEqual(partly.end, CMTime(value: 3, timescale: 2))
        let before = SourceTimeOrigin.fileRange(samples: -96_000 ..< -48_000, rate: 48_000, origin: half)
        XCTAssertEqual(before.duration, .zero, "파일 시각 0보다 앞은 읽을 것이 없다")
    }

    // MARK: 원점이 0이 아닐 때의 읽기(원점을 시험에서 지정)

    func testForcedOriginReadsShiftedSamples() async throws {
        let url = try await wav()
        func open(_ origin: CMTime?) async throws -> SpectrumFileSource {
            try await SpectrumFileSource.open(url: url, mediaID: nil, sampleRate: 48_000, chunkSamples: 8 * 48_000, marginSamples: 48_000, forcedOrigin: origin)
        }
        let zero = try await open(nil), half = try await open(CMTime(value: 1, timescale: 2))
        XCTAssertEqual(zero.timeOrigin, .zero)
        let a = try await zero.decodeRange(0, 96_000, keep: 0 ..< 96_000), b = try await half.decodeRange(0, 96_000, keep: 0 ..< 96_000)
        XCTAssertEqual(F.onsets(a[0]).count, 1); XCTAssertEqual(F.onsets(b[0]).count, 1)
        XCTAssertEqual(F.onsets(a[0]).first ?? -1, F.burstStart, accuracy: 4, "원점 0: 파일 시각 1.0 s = 표본 48000")
        XCTAssertEqual(F.onsets(b[0]).first ?? -1, F.burstStart - 24_000, accuracy: 4, "원점 0.5 s: 파일 시각 1.0 s = 표본 24000")
        XCTAssertEqual(Array(b[0][72_000...]).map(abs).max() ?? 1, 0, "파일 끝(2 s = 표본 72000) 뒤는 0")
        XCTAssertNotEqual(zero.identity, half.identity, "원점이 다르면 캐시 열쇠가 달라야 한다")
        // 덩어리 읽기도 같은 원점을 쓴다
        let chunk = try await half.decodeChunk(0)
        XCTAssertEqual(F.onsets(chunk[0]).first ?? -1, F.burstStart - 24_000, accuracy: 4)
    }
    func testZeroOriginIdentityIsUnchanged() async throws {
        let url = try await wav()
        let s = try await SpectrumFileSource.open(url: url)
        XCTAssertEqual(s.timeOrigin, .zero)
        // E1 이전의 열쇠 전체: 미디어 ID(없으면 "-") | 표준화한 경로 | 크기 | 수정 시각 | 표본율 | 덩어리 | 여유 — 원점 항목이 붙지 않는다
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = try XCTUnwrap(values.fileSize), modified = try XCTUnwrap(values.contentModificationDate)
        let legacy = ["-", url.standardizedFileURL.path, "\(size)|\(modified.timeIntervalSinceReferenceDate)", "48000", "384000", "48000"].joined(separator: "|")
        XCTAssertEqual(s.identity.key, legacy, "원점 0이면 열쇠는 전과 같다")
    }

    // MARK: 실제 파일 — 재생과 분석 비교

    /// A: 소리 트랙이 0에서 시작하는 WAV
    func testWavStartingAtZeroMatchesPlayback() async throws {
        let m = try await MediaProbe.inspect(try await wav())
        for layout in Layout.all { try await compare(layout, media: m, tolerance: 8, absolute: true) }
    }
    /// B: 소리 트랙이 0.5 s 뒤에 시작하는 소리 파일(앞은 빈 구간)
    func testAudioFileStartingLateMatchesPlayback() async throws {
        let url = dir.appendingPathComponent("late.mov")
        try await F.write(url, type: .mov, audio: F.lpcm, audioStart: 24_000, video: false)
        let m = try await MediaProbe.inspect(url)
        for layout in Layout.all { try await compare(layout, media: m, tolerance: 8, absolute: false) }
    }
    /// C: 영상은 0, 소리는 0.5 s에 시작하는 영상 파일(AAC — 가져오기 규칙). 압축 소리라 허용 오차를 넓힌다.
    func testVideoFileWithLaterAudioMatchesPlayback() async throws {
        let url = dir.appendingPathComponent("video-late-audio.mov")
        try await F.write(url, type: .mov, audio: F.aac, audioStart: 24_000, video: true)
        let m = try await MediaProbe.inspect(url)
        XCTAssertTrue(m.hasVideo); XCTAssertTrue(m.hasAudio)
        for layout in [Layout.whole, .trimmed, .moved] { try await compare(layout, media: m, tolerance: 128, absolute: false) }
    }

    // MARK: 파형

    func testWaveformShowsPlaybackPosition() async throws {
        let late = dir.appendingPathComponent("late.mov")
        try await F.write(late, type: .mov, audio: F.lpcm, audioStart: 24_000, video: false)
        for url in [try await wav(), late] {
            let m = try await MediaProbe.inspect(url)
            let t = Layout.whole.timeline(m)
            let heard = F.onsets(try await F.playback(try await CompositionPlanner.plan(t, media: [m.id: m])))
            let onset = try XCTUnwrap(heard.first, url.lastPathComponent)
            let w = try await WaveformPeaks.analyze(url: url, mediaID: m.id)
            let b = w.bucketSamples
            // 전체 클립(시작 0, 원본 0)이므로 타임라인 표본 = 원본 표본
            let quiet = try XCTUnwrap(w.envelope(channel: 0, samples: max(0, onset - 12 * b) ..< onset - 2 * b), url.lastPathComponent)
            let loud = try XCTUnwrap(w.envelope(channel: 0, samples: onset + 2 * b ..< onset + 2 * b + 4_800), url.lastPathComponent)
            XCTAssertLessThan(max(abs(quiet.min), abs(quiet.max)), 0.05, "\(url.lastPathComponent): 소리 시작 전은 조용")
            XCTAssertGreaterThan(loud.max, 0.4, "\(url.lastPathComponent): 재생에서 들리는 곳에 파형이 있다")
        }
    }
}
