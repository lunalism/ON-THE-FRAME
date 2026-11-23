import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E4a: 스펙트럼이 든 타임라인을 제품 쓰기 경로로 내보낸 H.264 MP4를 디코딩해 본다.
/// 공개 내보내기는 계속 막혀 있다 — 이 시험은 DEBUG 전용 내부 진입점만 쓴다. 화소는 문턱값으로 본다(바이트 비교가 아니다).
final class SpectrumMP4ExportTests: SpectrumMP4TestCase {
    override class func tearDown() { if keptDir == nil { try? FileManager.default.removeItem(at: root) }; runs = [:] }

    // 장면 1: 노란 Digital 스펙트럼 [15, 45)과 그 위에 겹친 흰 자막 [20, 40)
    func digitalScene() async throws -> (Timeline, [MediaAsset], SubtitleItem) {
        let m = try await media()
        let b = try Fx.base(m, source: m.tone)
        let lane = UUID(), sid = UUID()
        let t = try b.timeline.addingSpectrum(lane: b.low, at: 15, length: 30, sourceKey: b.key, style: Fx.style(.digital))
            .addingLane(.subtitle, name: "S1", id: lane).addingSubtitle(lane: lane, at: 20, length: 20, text: "ON THE FRAME", style: Fx.subtitleStyle, id: sid)
        XCTAssertTrue(t.isValid); XCTAssertTrue(t.spectra[0].style.isValid)
        return (t, [m.video, m.tone], try XCTUnwrap(t.subtitles.first { $0.id == sid }))
    }
    func digitalRun() async throws -> (Fx.Run, Timeline, [MediaAsset], [Int32]) {
        let (t, assets, subtitle) = try await digitalScene()
        let mask = try Fx.glyphMask(subtitle)
        return (try await run("digital-subtitle", probes: [mask]) { (t, assets) }, t, assets, mask)
    }
    // A. 내보내기가 끝났고 파일·임시 폴더·원본이 기대대로다
    func testDigitalSpectrumExportCompletes() async throws {
        let m = try await media()
        let before = [try SubtitlePumpFixture.sha(m.video.url), try SubtitlePumpFixture.sha(m.tone.url)]
        let (r, t, _, _) = try await digitalRun()
        try assertCompleted(r)
        XCTAssertEqual(t.spectra.count, 1); XCTAssertEqual(t.durationFrames, Fx.frames)
        XCTAssertEqual([try SubtitlePumpFixture.sha(m.video.url), try SubtitlePumpFixture.sha(m.tone.url)], before, "원본은 그대로")
        XCTAssertFalse(r.decoded.audioOnsets.isEmpty, "소리가 들어 있다")
    }
    // E. 스펙트럼은 [15, 45)에만 보인다
    func testSpectrumAppearsOnlyInItsInterval() async throws {
        let (r, _, _, _) = try await digitalRun()
        for k in 0..<Fx.frames {
            let s = try XCTUnwrap(r.decoded.stats[k], "frame \(k)")
            if (15..<45).contains(k) { XCTAssertGreaterThan(s.yellow, 1_000, "frame \(k): 스펙트럼이 보인다") }
            else { XCTAssertEqual(s.painted, 0, "frame \(k): 스펙트럼 구간 밖") }
        }
    }
    // A. 모양: 자막이 없는 프레임에서 노란 화소의 테두리와 양이 공급기 그림과 맞는다
    func testDigitalGeometryMatchesProviderRaster() async throws {
        let (r, t, assets, _) = try await digitalRun()
        for k in [16, 44] {
            let shapes = try await Fx.shapes(t, assets, frame: k)
            let shape = try XCTUnwrap(shapes.first, "frame \(k)")
            let s = try XCTUnwrap(r.decoded.stats[k])
            assertShape(s, count: s.yellow, shape, "frame \(k)")
            XCTAssertLessThan(s.white, s.yellow / 10, "frame \(k): 노랑이다")
        }
    }
    // D. 자막은 스펙트럼 위: 글자 자리의 화소가 자막 구간에는 흰색이고, 자막이 없을 때는 아니다
    func testSubtitleIsDrawnAboveSpectrum() async throws {
        let (r, _, _, mask) = try await digitalRun()
        XCTAssertGreaterThan(mask.count, 2_000)
        let with = try XCTUnwrap(r.decoded.stats[30]), without = try XCTUnwrap(r.decoded.stats[16])
        XCTAssertGreaterThan(with.yellow, 1_000, "자막과 같은 프레임에 스펙트럼도 있다")
        XCTAssertGreaterThanOrEqual(Double(with.whiteAtMask) / Double(mask.count), 0.5, "자막 구간: 글자 자리가 흰색")
        XCTAssertLessThanOrEqual(Double(without.whiteAtMask) / Double(mask.count), 0.15, "자막이 없으면 글자 자리는 막대(노랑)나 배경")
    }

    // B. Analog
    func testAnalogSpectrumIsEncoded() async throws {
        let m = try await media()
        let b = try Fx.base(m, source: m.tone)
        let t = try b.timeline.addingSpectrum(lane: b.low, at: 0, length: 60, sourceKey: b.key, style: Fx.style(.analog))
        let r = try await run("analog") { (t, [m.video, m.tone]) }
        try assertCompleted(r)
        for k in 0..<Fx.frames { XCTAssertGreaterThan(r.decoded.stats[k]?.yellow ?? 0, 500, "frame \(k)") }
        let shapes = try await Fx.shapes(t, [m.video, m.tone], frame: 30)
        let shape = try XCTUnwrap(shapes.first), s = try XCTUnwrap(r.decoded.stats[30])
        assertShape(s, count: s.yellow, shape, "analog frame 30")
    }
    // C. 두 층(노랑, 그리고 32 px 아래로 옮긴 흰색): 두 층이 각자 자리에 그려지고, 겹친 곳은 프리뷰 차례의 위 층 색이다
    func testTwoLayersKeepPreviewOrder() async throws {
        let m = try await media()
        let b = try Fx.base(m, source: m.tone), assets = [m.video, m.tone]
        var lowered = Fx.style(.digital, red: 255, green: 255, blue: 255)
        lowered.startYMilli += 32_000; lowered.endYMilli += 32_000
        let t = try b.timeline.addingSpectrum(lane: b.low, at: 0, length: 60, sourceKey: b.key, style: Fx.style(.digital))
            .addingSpectrum(lane: b.high, at: 0, length: 60, sourceKey: b.key, style: lowered)
        XCTAssertTrue(t.isValid)
        let maps = try await Fx.alphaMaps(t, assets, frame: 30)
        XCTAssertEqual(maps.count, 2)
        // 프리뷰의 차례(PausedSpectrumOverlay와 같은 식): timeline.spectra.reversed() 가운데 보이는 것, 앞이 아래
        XCTAssertEqual(maps.map(\.id), t.spectra.reversed().filter { $0.visible(atFrame: 30) }.map(\.id), "공급기의 차례 = 프리뷰의 차례")
        let bottom = try XCTUnwrap(t.spectrum(maps[0].id)), top = try XCTUnwrap(t.spectrum(maps[1].id))
        XCTAssertNotEqual(top.style.blue, bottom.style.blue, "두 층의 색이 다르다")
        let regions = Fx.regions(bottom: maps[0].alpha, top: maps[1].alpha)
        let r = try await run("two-layers-offset", probes: [regions.overlap, regions.topOnly, regions.bottomOnly]) { (t, assets) }
        try assertCompleted(r)
        let s = try XCTUnwrap(r.decoded.stats[30])
        XCTAssertEqual(s.probes.count, 3)
        for (i, name, layer) in [(0, "겹친 곳", top), (1, "위 층만 있는 곳", top), (2, "아래 층만 있는 곳", bottom)] where i < s.probes.count {
            let p = s.probes[i]
            let (expected, other) = layer.style.blue == 255 ? (p.white, p.yellow) : (p.yellow, p.white)
            XCTAssertGreaterThan(p.total, 500, "\(name): 확인할 자리가 충분하다")
            XCTAssertGreaterThanOrEqual(Double(expected) / Double(max(1, p.total)), 0.9, "\(name): 기대한 층의 색(\(expected)/\(p.total))")
            XCTAssertLessThanOrEqual(Double(other) / Double(max(1, p.total)), 0.05, "\(name): 다른 층의 색이 아니다(\(other)/\(p.total))")
        }
        // 두 층을 합친 그림의 테두리와 양
        let shapes = try await Fx.shapes(t, assets, frame: 30)
        XCTAssertEqual(shapes.count, 2)
        var opaque = 0, any = 0
        for i in 0..<(1920 * 1080) { if maps[0].alpha[i] > 200 || maps[1].alpha[i] > 200 { opaque += 1 }; if maps[0].alpha[i] > 0 || maps[1].alpha[i] > 0 { any += 1 } }
        let union = Fx.Shape(id: top.id, opaque: opaque, anyAlpha: any, bounds: shapes[0].bounds.union(shapes[1].bounds), peak: 0)
        assertShape(s, count: s.painted, union, "two layers frame 30")
    }
    // F·G. 옮긴 소스와 무음: 소리(1 s)가 [15, 45)에만 있다. 무음 프레임은 유효한 0 — 두께만큼의 점 줄(SPECTRUM-ZERO-01)이고 오류가 아니다.
    // 소리가 있는 프레임은 막대다. 모든 프레임에서 디코딩한 화소의 테두리와 양이 공급기 그림과 맞는다.
    func testMovedSourceAndSilenceAreEncoded() async throws {
        let m = try await media()
        let b = try Fx.base(m, source: m.shortTone, at: 15), assets = [m.video, m.shortTone]
        let t = try b.timeline.addingSpectrum(lane: b.low, at: 0, length: 60, sourceKey: b.key, style: Fx.style(.digital))
        let r = try await run("moved-silence-15", frames: [5, 14, 15, 16, 30, 44, 45, 50]) { (t, assets) }
        try assertCompleted(r)
        let expected = try await Fx.shapes(t, assets, frames: Array(0..<Fx.frames))
        let dot = Double(Fx.style(.digital).thicknessMilli) / 1000   // 0높이 점의 높이 = 두께(px)
        var audible: [Int] = []
        for k in 0..<Fx.frames {
            let shape = try XCTUnwrap(expected[k]?.first, "frame \(k)"), s = try XCTUnwrap(r.decoded.stats[k], "frame \(k)")
            assertShape(s, count: s.yellow, shape, "frame \(k)")
            let height = Double(s.maxY - s.minY + 1)
            if shape.peak > 0 { audible.append(k) }
            if k <= 12 || k >= 48 {          // 분석 창(90 ms)이 소리 구간 [0.5 s, 1.5 s)에 닿지 않는다
                XCTAssertEqual(shape.peak, 0, "frame \(k): 무음은 유효한 0")
                XCTAssertEqual(Double(shape.bounds.height), dot, accuracy: 1, "frame \(k): 0높이 점은 두께만큼")
                XCTAssertLessThanOrEqual(height, dot + 8, "frame \(k): 인코딩된 점 줄")
            } else if (18..<42).contains(k) { // 분석 창이 소리 구간 안에 있다
                XCTAssertGreaterThan(shape.peak, 0, "frame \(k): 소리가 있다")
                XCTAssertGreaterThan(Double(shape.bounds.height), dot + 16, "frame \(k): 막대는 점보다 높다")
                XCTAssertGreaterThan(height, dot + 16, "frame \(k): 인코딩된 막대")
            }
        }
        print("  moved source: frames with nonzero bands \(audible.first.map(String.init) ?? "-")...\(audible.last.map(String.init) ?? "-") count \(audible.count)")
        // 옮긴 소리는 타임라인 0.5 s(표본 24000)에 시작한다(영상의 소리는 1.0 s에 시작). AAC라 E1과 같은 허용 오차
        XCTAssertEqual(Double(try XCTUnwrap(r.decoded.audioOnsets.first, "소리가 들어 있다")), 24_000, accuracy: 128, "옮긴 소리의 시작 표본")
    }
}
