import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E3: 공급기가 층을 하나씩 처리하며 프레임 메모리 예산을 지키는가. 128 MiB는 시험용 값이다.
/// 장부의 수치는 계산한 상한이다 — 프로세스 메모리가 안정적이라는 증거가 아니다.
final class SpectrumTimelineBudgetTests: SpectrumTimelineTestCase {
    func limits(budget: Int) -> SpectrumTimelineExportLimits {
        SpectrumTimelineExportLimits(stepTimeout: 30, jobTimeout: 600, frameMemoryBudgetBytes: budget)
    }
    /// 소리 클립 하나와 스펙트럼 둘(아래 Digital, 위 Analog), 둘 다 [0, 60)
    func twoLayers() async throws -> (Timeline, MediaAsset) {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 60, sourceKey: sc.key)
            .addingSpectrum(lane: sc.high, at: 0, length: 60, sourceKey: sc.key, style: analog())
        return (t, m)
    }
    /// 측정값 출력(보고용 — 판정은 시험이 한다): 층별 그림 크기·칠한 화소·계산한 필요량과 장부
    func record(_ name: String, _ p: SpectrumTimelineFrames, frame k: Int, report: SpectrumFrameMemoryReport, footprints: [SubtitleFootprint]) async throws {
        var lines = ["E3 MEMORY \(name): budget \(128 << 20) layers \(report.layers) ledger peak \(report.peakBytes) retained \(report.retainedBytes)"]
        for (i, layer) in try await p.layers(k).enumerated() {
            guard let r = layer.rendered else { continue }
            let painted = SpectrumFootprintCost.paintedPixels(r.image) ?? -1
            lines.append("  layer \(i): raster \(r.image.width)x\(r.image.height) at (\(Int(r.drawRect.minX)),\(Int(r.drawRect.minY))) imageBytes \(SpectrumFootprintCost.imageBytes(r.image) ?? -1) painted \(painted)"
                + " constructionPeak \(SpectrumFootprintCost.constructionPeak(r, painted: painted) ?? -1) worstCasePeak \(SpectrumFootprintCost.constructionPeak(r) ?? -1)"
                + " footprintRetained \(i < footprints.count ? footprints[i].retainedBytes : -1)")
        }
        print(lines.joined(separator: "\n"))
    }
    func sameFootprint(_ a: SubtitleFootprint, _ b: SubtitleFootprint) -> Bool {
        a.start == b.start && a.end == b.end && a.yIdx == b.yIdx && a.ya == b.ya && a.yaSub == b.yaSub
            && a.cIdx == b.cIdx && a.cWA == b.cWA && a.cWACb == b.cWACb && a.cWACr == b.cWACr
    }

    // 3. 스펙트럼 하나: 예산 안, 장부가 실제 발자국과 맞는다
    func testSingleSpectrumStaysWithinBudget() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 60, sourceKey: sc.key)
        let p = try provider(t, [m])
        let footprints = try await p.prepareFootprints(30), report = await p.memory()
        XCTAssertEqual(footprints.count, 1); XCTAssertEqual(report.layers, 1)
        XCTAssertEqual(report.retainedBytes, footprints[0].retainedBytes, "붙잡은 양 = 실제 발자국")
        XCTAssertGreaterThan(report.peakBytes, report.retainedBytes); XCTAssertLessThanOrEqual(report.peakBytes, 128 << 20)
        try await record("single digital", p, frame: 30, report: report, footprints: footprints)
        let outside = try await p.prepareFootprints(90), idle = await p.memory()
        XCTAssertTrue(outside.isEmpty); XCTAssertEqual(idle, SpectrumFrameMemoryReport(), "보이는 것이 없으면 장부도 0")
    }
    // 4. 여러 층: 예산 안, 붙잡은 양은 층의 합, 최대는 합보다 작지 않고 한도 이하
    func testMultipleLayersStayWithinBudget() async throws {
        let (t, m) = try await twoLayers()
        let p = try provider(t, [m])
        let footprints = try await p.prepareFootprints(30), report = await p.memory()
        XCTAssertEqual(footprints.count, 2); XCTAssertEqual(report.layers, 2)
        XCTAssertEqual(report.retainedBytes, footprints.reduce(0) { $0 + $1.retainedBytes })
        XCTAssertGreaterThanOrEqual(report.peakBytes, report.retainedBytes); XCTAssertLessThanOrEqual(report.peakBytes, 128 << 20)
        try await record("digital + analog", p, frame: 30, report: report, footprints: footprints)
    }
    // 5·6. 그림 하나도 들일 수 없는 예산: 원본을 열거나 소리를 디코딩하기 전에 거부, 남는 것 없음
    func testTinyBudgetIsRejectedBeforeAnyDecoding() async throws {
        let (t, m) = try await twoLayers()
        let p = try provider(t, [m], limits: limits(budget: 1 << 20))
        do { _ = try await p.prepareFootprints(30); XCTFail("거부해야 한다") }
        catch { XCTAssertEqual(error as? SpectrumTimelineExportError, .frameMemoryBudgetExceeded(required: SpectrumFootprintCost.maxImageBytes, limit: 1 << 20)) }
        let held = await p.retained(), report = await p.memory()
        XCTAssertEqual(held.pcmBytes, 0); XCTAssertEqual(held.openSources, 0, "원본도 열지 않았다")
        XCTAssertEqual(report.retainedBytes, 0); XCTAssertEqual(report.layers, 0)
    }
    // 5·6. 그림은 들어가지만 발자국을 만들 수 없는 예산: 발자국을 만들기 전에 거부, 일부만 내지 않음, 소리를 놓음, 공급기는 계속 쓸 수 있음
    func testBudgetIsRejectedBeforeFootprintConstruction() async throws {
        let (t, m) = try await twoLayers()
        let budget = 12 << 20
        let p = try provider(t, [m], limits: limits(budget: budget))
        do { _ = try await p.prepareFootprints(30); XCTFail("거부해야 한다") }
        catch {
            guard case .frameMemoryBudgetExceeded(let required, let limit)? = error as? SpectrumTimelineExportError else { return XCTFail("\(error)") }
            XCTAssertEqual(limit, budget); XCTAssertGreaterThan(required, budget)
        }
        let held = await p.retained(), report = await p.memory()
        XCTAssertEqual(held.pcmBytes, 0, "거부한 프레임의 소리를 놓았다"); XCTAssertEqual(report.retainedBytes, 0)
        do { _ = try await p.prepareFootprints(30); XCTFail("같은 프레임은 다시 요청해도 거부") }
        catch { guard case .frameMemoryBudgetExceeded? = error as? SpectrumTimelineExportError else { return XCTFail("\(error)") } }
        let outside = try await p.prepareFootprints(90)   // 스펙트럼이 없는 프레임: 공급기는 계속 쓸 수 있다
        XCTAssertTrue(outside.isEmpty)
        let roomy = try await provider(t, [m]).prepareFootprints(30)
        XCTAssertEqual(roomy.count, 2, "넉넉한 예산에서는 같은 프레임이 두 층을 모두 낸다(빼지 않는다)")
    }
    // 7. 처리 중 취소
    func testCancellationPropagatesAndProviderRecovers() async throws {
        let (t, m) = try await twoLayers()
        let p = try provider(t, [m])
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do { _ = try await p.prepareFootprints(5); return false } catch { return error is CancellationError }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        let after = try await p.prepareFootprints(6)
        XCTAssertEqual(after.count, 2)
        await p.close()
        let held = await p.retained()
        XCTAssertEqual(held.pcmBytes, 0); XCTAssertEqual(held.openSources, 0)
    }
    // 8·9·13. 층을 하나씩 처리해도 차례와 결과는 같다(Digital·Analog): 그림을 한꺼번에 받아 만든 발자국과 화소 단위로 같음
    func testIncrementalFootprintsEqualLayerRasters() async throws {
        let (t, m) = try await twoLayers()
        let p = try provider(t, [m])
        for k in [0, 30, 59] {
            let footprints = try await p.prepareFootprints(k), layers = try await p.layers(k)
            XCTAssertEqual(layers.map(\.spectrumID), t.spectra.reversed().filter { $0.visible(atFrame: k) }.map(\.id), "프리뷰 차례")
            let expected = layers.compactMap { layer in layer.rendered.map { SpectrumTimelineFrames.footprint($0, lane: layer.lane, frame: k) } }
            XCTAssertEqual(footprints.count, expected.count, "frame \(k)")
            for (a, b) in zip(footprints, expected) { XCTAssertTrue(sameFootprint(a, b), "frame \(k)") }
            for layer in layers {
                let s = try XCTUnwrap(t.spectrum(layer.spectrumID)), ref = try await Fx.reference(t, s, frame: k, asset: m)
                XCTAssertEqual(layer.bands, ref.bands); XCTAssertTrue(Fx.same(layer.rendered, ref.rendered))
            }
        }
    }
    // 10. 무음(소스가 덮지 않음)은 그리고, 소스 없음은 막는다
    func testSilenceIsDrawnButMissingSourceIsBlocked() async throws {
        let m = try await media("short.wav", seconds: 1, Fx.tone(440))
        let sc = try scene(m, at: 30)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 120, sourceKey: sc.key)
        let silent = try await provider(t, [m]).prepareFootprints(5)
        XCTAssertEqual(silent.count, 1, "덮지 않는 구간: 0높이 점을 그린다")
        let missing = try t.lifting(clip: sc.clip)
        XCTAssertThrowsError(try provider(missing, [m])) {
            guard case .blocked(let blockers)? = $0 as? SpectrumTimelineExportError else { return XCTFail("\($0)") }
            XCTAssertEqual(blockers.map(\.reason), [.missingSource])
        }
    }
}
