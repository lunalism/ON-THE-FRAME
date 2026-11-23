import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E2: 일반 타임라인의 스펙트럼 프레임 공급이 프리뷰와 같은 함수의 값을 내는가(합성 전 — 분석 값과 그림).
/// 합성한 뒤의 화소와 인코딩한 MP4는 이 시험의 범위가 아니다.
final class SpectrumTimelineFramesTests: SpectrumTimelineTestCase {
    // A. 스펙트럼 하나: 분석 값과 그림이 직접 계산과 같다
    func testSingleSpectrumMatchesDirectAnalysisAndRaster() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        var sc = try scene(m)
        sc.timeline = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 90, sourceKey: sc.key)
        let s = sc.timeline.spectra[0], p = try provider(sc.timeline, [m])
        for k in [0, 31, 89] {
            let layers = try await p.layers(k), ref = try await Fx.reference(sc.timeline, s, frame: k, asset: m)
            XCTAssertEqual(layers.count, 1, "frame \(k)")
            XCTAssertEqual(layers.first?.spectrumID, s.id); XCTAssertEqual(layers.first?.bands, ref.bands, "bands \(k)")
            XCTAssertTrue(Fx.same(layers.first?.rendered, ref.rendered), "raster \(k)")
        }
        let sounding = try await p.layers(31)
        XCTAssertGreaterThan(sounding[0].bands.max() ?? 0, 0.3, "440 Hz가 들리는 프레임")
    }
    // 보이는 스펙트럼이 없으면 아무것도 내지 않고 분석하지도 않는다
    func testNoVisibleSpectrumReturnsNothing() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        var sc = try scene(m)
        sc.timeline = try sc.timeline.addingSpectrum(lane: sc.low, at: 30, length: 30, sourceKey: sc.key)
        let p = try provider(sc.timeline, [m])
        let before = try await p.layers(10), footprints = try await p.prepareFootprints(10)
        XCTAssertTrue(before.isEmpty); XCTAssertTrue(footprints.isEmpty)
        let idle = await p.retained()
        XCTAssertEqual(idle.pcmBytes, 0); XCTAssertEqual(idle.openSources, 0, "보이지 않으면 원본도 열지 않는다")
        let inside = try await p.layers(40)
        XCTAssertEqual(inside.count, 1)
        let after = try await p.layers(70)
        XCTAssertTrue(after.isEmpty)
        let released = await p.retained()
        XCTAssertEqual(released.pcmBytes, 0, "보이는 것이 없으면 디코딩한 소리를 놓는다")
    }
    // B·C. 동시에 보이는 스펙트럼 둘: 거부하지 않고, 프리뷰와 같은 차례(아래 먼저)
    func testTwoVisibleSpectraUsePreviewOrder() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        var sc = try scene(m)
        sc.timeline = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 60, sourceKey: sc.key)
            .addingSpectrum(lane: sc.high, at: 20, length: 60, sourceKey: sc.key, style: analog())
        let t = sc.timeline, p = try provider(t, [m])
        let both = try await p.layers(30)
        let previewOrder = t.spectra.reversed().filter { $0.visible(atFrame: 30) }.map(\.id)
        XCTAssertEqual(both.count, 2); XCTAssertEqual(both.map(\.spectrumID), previewOrder)
        XCTAssertEqual(Set(both.map(\.lane)), [sc.low, sc.high])
        for layer in both {
            let s = try XCTUnwrap(t.spectrum(layer.spectrumID)), ref = try await Fx.reference(t, s, frame: 30, asset: m)
            XCTAssertEqual(layer.bands, ref.bands); XCTAssertTrue(Fx.same(layer.rendered, ref.rendered))
        }
        let one = try await p.layers(10), other = try await p.layers(70)
        XCTAssertEqual(one.map(\.lane), [sc.low]); XCTAssertEqual(other.map(\.lane), [sc.high])
        let footprints = try await p.prepareFootprints(30)
        XCTAssertEqual(footprints.count, 2)
    }
    // D. 서로 다른 원본(스테레오 440 Hz, 모노 1000 Hz)
    func testDifferentSourceMedia() async throws {
        let a = try await media("a.wav", Fx.tone(440)), b = try await media("b.wav", channels: 1, Fx.tone(1_000))
        var sc = try scene(a, others: [b])
        let a2 = UUID(), clipB = UUID()
        var t = try sc.timeline.addingLane(.audio, name: "A2", id: a2).placing(media: b.id, at: 0, videoLane: nil, audioLane: a2, clipID: clipB)
        let keyB = try XCTUnwrap(t.clip(clipB)).lineageKey
        t = try t.addingSpectrum(lane: sc.low, at: 0, length: 60, sourceKey: sc.key).addingSpectrum(lane: sc.high, at: 0, length: 60, sourceKey: keyB)
        sc.timeline = t
        let p = try provider(t, [a, b]), layers = try await p.layers(30)
        XCTAssertEqual(layers.count, 2)
        for layer in layers {
            let s = try XCTUnwrap(t.spectrum(layer.spectrumID)), asset = s.sourceKey == keyB ? b : a
            let ref = try await Fx.reference(t, s, frame: 30, asset: asset)
            XCTAssertEqual(layer.bands, ref.bands, s.sourceKey == keyB ? "1000 Hz 모노" : "440 Hz 스테레오")
        }
        XCTAssertNotEqual(layers[0].bands, layers[1].bands, "다른 소리는 다른 값")
        let held = await p.retained()
        XCTAssertEqual(held.openSources, 2)
    }
    // G. Digital과 Analog
    func testDigitalAndAnalogRender() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        var sc = try scene(m)
        let base = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 60, sourceKey: sc.key)
        let digital = try await provider(base, [m]).layers(30)
        let analogTimeline = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 60, sourceKey: sc.key, style: analog())
        sc.timeline = analogTimeline
        let analogLayers = try await provider(analogTimeline, [m]).layers(30)
        let ref = try await Fx.reference(analogTimeline, analogTimeline.spectra[0], frame: 30, asset: m)
        XCTAssertEqual(digital[0].bands, analogLayers[0].bands, "모양은 분석 값을 바꾸지 않는다")
        XCTAssertTrue(Fx.same(analogLayers[0].rendered, ref.rendered))
        XCTAssertFalse(Fx.same(digital[0].rendered, analogLayers[0].rendered), "Digital과 Analog의 그림은 다르다")
        XCTAssertGreaterThan(Fx.painted(digital[0].rendered), 0); XCTAssertGreaterThan(Fx.painted(analogLayers[0].rendered), 0)
    }
    // 같은 프레임은 언제나 같은 결과(요청 차례·새 공급기와 무관)
    func testFramesAreDeterministic() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        var sc = try scene(m)
        sc.timeline = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 90, sourceKey: sc.key)
        let p = try provider(sc.timeline, [m])
        let first = try await p.layers(45)
        _ = try await p.layers(80); _ = try await p.layers(3)
        let again = try await p.layers(45), fresh = try await provider(sc.timeline, [m]).layers(45)
        XCTAssertEqual(first[0].bands, again[0].bands); XCTAssertEqual(first[0].bands, fresh[0].bands)
        XCTAssertTrue(Fx.same(first[0].rendered, again[0].rendered)); XCTAssertTrue(Fx.same(first[0].rendered, fresh[0].rendered))
    }
}
