import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E2: 소리 클립을 자르고 나누고 옮겼을 때, 빈 구간, 0높이 점, 원본 시각 대응(E1).
final class SpectrumTimelineSourceTests: SpectrumTimelineTestCase {
    func bands(_ t: Timeline, _ m: MediaAsset, _ k: Int) async throws -> [Float] {
        let layers = try await provider(t, [m]).layers(k)
        return try XCTUnwrap(layers.first).bands
    }
    /// 앞 2 s는 440 Hz, 뒤 2 s는 1000 Hz — 원본 위치가 달라지면 값이 달라진다
    func twoTones() async throws -> MediaAsset {
        try await media("two.wav") { i, _ in 0.5 * sin(2 * Double.pi * (i < 96_000 ? 440 : 1_000) * Double(i) / 48_000) }
    }
    // E. 옮기기: 30프레임 옮긴 소스의 프레임 k + 30 = 옮기기 전 프레임 k
    func testMovedSourceIsFollowed() async throws {
        let m = try await twoTones()
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 150, sourceKey: sc.key)
        let moved = try t.relocating(clip: sc.clip, toStart: 30)
        for k in [10, 55, 70] {
            let a = try await bands(t, m, k), b = try await bands(moved, m, k + 30)
            XCTAssertEqual(a, b, "frame \(k)")
        }
        let early = try await bands(t, m, 20), late = try await bands(t, m, 80)
        XCTAssertNotEqual(early, late, "440 Hz 구간과 1000 Hz 구간")
    }
    // E. 나누기: 나눈 뒤에도 같은 타임라인 프레임에서 같은 값(나눈 곳에 걸친 창 포함)
    func testSplitSourceKeepsValues() async throws {
        let m = try await twoTones()
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 120, sourceKey: sc.key)
        let split = try t.splitting(clip: sc.clip, atFrame: 60)
        XCTAssertEqual(split.spectrumPieces(split.spectra[0]).count, 2)
        for k in [30, 59, 60, 61, 90] {
            let a = try await bands(t, m, k), b = try await bands(split, m, k)
            XCTAssertEqual(a, b, "frame \(k)")
        }
    }
    // E. 자르기: 앞을 자르면 그 타임라인 프레임은 원본의 같은 곳을 읽는다(남은 구간에서 값이 같다)
    func testTrimmedSourceKeepsValues() async throws {
        let m = try await twoTones()
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 120, sourceKey: sc.key)
        let split = try t.splitting(clip: sc.clip, atFrame: 45, newIDs: (UUID(), UUID()))
        let left = try XCTUnwrap(split.audioClips.first { $0.start == 0 })
        let trimmed = try split.lifting(clip: left.id)   // 오른쪽 조각만 남김(시작 45, 원본 45)
        XCTAssertEqual(trimmed.spectrumPieces(trimmed.spectra[0]).map { [$0.start, $0.sourceIn] }, [[45, 45]])
        for k in [50, 70, 100] {
            let a = try await bands(t, m, k), b = try await bands(trimmed, m, k)
            XCTAssertEqual(a, b, "frame \(k)")
        }
    }
    // F. 소스가 덮지 않는 구간은 무음이며 오류가 아니다
    func testUncoveredIntervalIsSilentNotAnError() async throws {
        let m = try await media("short.wav", seconds: 1, Fx.tone(440))
        let sc = try scene(m, at: 30)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 120, sourceKey: sc.key)
        let p = try provider(t, [m])
        for k in [0, 10, 100] {   // 클립 [30, 60) 앞과 뒤
            let layers = try await p.layers(k)
            XCTAssertEqual(layers.count, 1, "frame \(k): 보이는 스펙트럼은 그대로 낸다")
            XCTAssertEqual(layers[0].bands.max(), 0, "frame \(k): 무음")
        }
        let inside = try await p.layers(45)
        XCTAssertGreaterThan(inside[0].bands.max() ?? 0, 0.3)
    }
    // H. SPECTRUM-ZERO-01: 유효한 무음의 Digital은 최소 점을 그린다(그림이 비지 않는다)
    func testSilentDigitalFrameDrawsZeroDots() async throws {
        let m = try await media("silent.wav", seconds: 2) { _, _ in 0 }
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 60, sourceKey: sc.key)
        let layers = try await provider(t, [m]).layers(20), ref = try await Fx.reference(t, t.spectra[0], frame: 20, asset: m)
        XCTAssertEqual(layers[0].bands.max(), 0)
        XCTAssertTrue(Fx.same(layers[0].rendered, ref.rendered))
        XCTAssertGreaterThan(Fx.painted(layers[0].rendered), 0, "0높이 점")
        let footprints = try await provider(t, [m]).prepareFootprints(20)
        XCTAssertEqual(footprints.count, 1)
    }
    // M. 원본 시각 대응(E1): 파일 시각 1.0 s에 시작하는 소리가 그 타임라인 프레임에서 나타난다
    func testSourceTimeMappingIsPreserved() async throws {
        let url = dir.appendingPathComponent("burst.wav")
        try await SourceTimeFixture.write(url, type: .wav, audio: SourceTimeFixture.lpcm, audioStart: 0, video: false)
        let m = try await MediaProbe.inspect(url)
        let origin = try await SpectrumFileSource.open(url: url, mediaID: m.id).timeOrigin
        XCTAssertEqual(origin, .zero)
        let sc = try scene(m, at: 15)   // 소리 시작 = 타임라인 프레임 15 + 30 = 45
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 75, sourceKey: sc.key)
        let quiet = try await bands(t, m, 40), loud = try await bands(t, m, 48)
        XCTAssertEqual(quiet.max(), 0, "소리 시작 전(창 90 ms가 닿지 않는 프레임)")
        XCTAssertGreaterThan(loud.max() ?? 0, 0.3, "1 kHz 소리 구간")
    }
}
