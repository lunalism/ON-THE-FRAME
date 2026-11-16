import CoreGraphics
import CoreVideo
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 스펙트럼 그리기 비용 측정(2026-10-25, docs/SPECTRUM-DESIGN.md §13) — OTF_SPECTRUM_BENCH=1일 때만(최적화 빌드로 돌림). 단계를 나눠 잰다:
/// 분석(덩어리를 미리 읽어 둔 순수 계산) · 덩어리 디코딩 · 그리기(비움 + 그리기) · 자르기(tightCrop 행 범위) · 발자국 만들기 · 섞기(4:2:0).
/// 고정 프레임 묶음: 체크포인트 fixture의 분석 프레임 5개 + 합성 밴드(모두 0.5, 모두 1.0 — 큰 막대). 여섯 조합 × 5회, 중앙값.
/// 4K(3840×2160)는 그리기·자르기만 — 발자국·섞기 코드는 1920×1080 전용이다(제품 출력 FHD). 시간 보장이 아니라 이 Mac의 한 번 기록이다.
final class SpectrumRenderBench: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SPECTRUM_BENCH"] == "1", "측정은 OTF_SPECTRUM_BENCH=1일 때만")
    }
    static func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
    static func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func testRenderStageCosts() async throws {
        #if DEBUG
        print("SPECTRUM bench build: DEBUG (최적화 아님)")
        #else
        print("SPECTRUM bench build: optimized")
        #endif
        let fixtures = ExportEndToEndTests.root.appendingPathComponent("fixtures")
        try await DevFixtures.ensureAll(in: fixtures)
        let src = try await SpectrumFileSource.open(url: fixtures.appendingPathComponent(AudioFixture.wav.file))
        let piece = SpectrumSourcePiece(start: 20, length: 50, sourceIn: 10)
        let settings = SpectrumAnalysisSettings()
        // 분석: 덩어리 디코딩(한 번씩) + 순수 계산
        var chunks: [Int: [[Float]]] = [:], decodeMs: [Double] = []
        let frames = [5, 35, 47, 48, 60]
        for k in frames { for c in try SpectrumAnalysis.chunks(frame: k, pieces: [piece], fps: 30, rate: 48_000, settings: settings, chunkSamples: src.chunkSamples) where chunks[c] == nil {
            let t = Self.now(); chunks[c] = try await src.decodeChunk(c); decodeMs.append(Self.ms(Self.now() - t))
        } }
        var analysisMs: [Double] = [], bandSets: [[Float]] = []
        for k in frames {
            var v: [Float] = []
            for _ in 0..<5 {
                let t = Self.now()
                v = try SpectrumAnalysis.bands(frame: k, pieces: [piece], fps: 30, rate: 48_000, channelCount: 2, chunkSamples: src.chunkSamples, settings: settings) { chunks[$0] }
                analysisMs.append(Self.ms(Self.now() - t))
            }
            bandSets.append(v)
        }
        bandSets.append([Float](repeating: 0.5, count: 64)); bandSets.append([Float](repeating: 1, count: 64))
        print(String(format: "SPECTRUM bench analysis: median %.3f ms/frame (%d samples), chunk decode median %.2f ms (%d chunks of %d samples, 8 s + 1 s margins)",
                     Self.median(analysisMs), analysisMs.count, Self.median(decodeMs), decodeMs.count, src.chunkSamples))
        // 섞기 대상 420v 버퍼(1920×1080)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()] as CFDictionary, &pb)
        let target = try XCTUnwrap(pb)
        for (w, h) in [(1920, 1080), (3840, 2160)] {
            let r = BenchRenderer(width: w, height: h)
            print(String(format: "SPECTRUM bench canvas %dx%d: reusable context %.1f MB", w, h, Double(w * h * 4) / 1_048_576))
            let engine = try SpectrumCanvas(width: w, height: h)
            for m in [SpectrumStyle.Mode.digital, .analog] { for sd in [SpectrumStyle.Sides.above, .mirrored, .below] {
                let st = SpectrumStyle(start: CGPoint(x: 192, y: 880), end: CGPoint(x: 1728, y: 880), maxHeight: 160, thickness: 6, mode: m, sides: sd)
                var whole: [Double] = []
                for v in bandSets { for _ in 0..<5 { let t = Self.now(); _ = try engine.render(v, style: st); whole.append(Self.ms(Self.now() - t)) } }
                var draw: [Double] = [], crop: [Double] = [], build: [Double] = [], blend: [Double] = [], cropBytes = 0, fpEntries = 0
                for v in bandSets { for _ in 0..<5 {
                    let o = r.measure(v, st, target: w == 1920 ? target : nil)
                    draw.append(o.draw); crop.append(o.crop); cropBytes = max(cropBytes, o.cropBytes)
                    if let b = o.build { build.append(b) }; if let bl = o.blend { blend.append(bl) }; fpEntries = max(fpEntries, o.footprintEntries)
                } }
                let worst = r.measure(bandSets.last!, st, target: w == 1920 ? target : nil)
                print(String(format: "SPECTRUM bench %dx%d %@ %@: SpectrumCanvas.render (clear+draw+crop) med %.3f ms", w, h, "\(m)", "\(sd)", Self.median(whole)))
                print(String(format: "SPECTRUM bench %dx%d %@ %@: clear+draw med %.3f ms, crop med %.3f ms, footprint build med %@, blend med %@; all-1.0 frame draw %.3f crop %.3f build %@ blend %@ ms; max crop buffer %.2f MB, max footprint entries %d",
                             w, h, "\(m)", "\(sd)", Self.median(draw), Self.median(crop), build.isEmpty ? "n/a" : String(format: "%.3f ms", Self.median(build)),
                             blend.isEmpty ? "n/a" : String(format: "%.3f ms", Self.median(blend)), worst.draw, worst.crop, worst.build.map { String(format: "%.3f", $0) } ?? "n/a",
                             worst.blend.map { String(format: "%.3f", $0) } ?? "n/a", Double(cropBytes) / 1_048_576, fpEntries))
            } }
        }
    }
}

/// 측정용 단계 나누기(엔진 SpectrumGeometry·tightCrop을 따로 불러 시간을 나눔 — SpectrumCanvas.render와 같은 차례): 비움+그리기 → 범위 행 tightCrop → SubtitleFootprint → 4:2:0 섞기
final class BenchRenderer {
    let w: Int, h: Int, ctx: CGContext
    init(width: Int, height: Int) {
        w = width; h = height
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    }
    struct Out { let draw: Double, crop: Double, build: Double?, blend: Double?, cropBytes: Int, footprintEntries: Int }
    func measure(_ v: [Float], _ st: SpectrumStyle, target: CVPixelBuffer?) -> Out {
        let canvas = CGSize(width: w, height: h)
        var t = SpectrumRenderBench.now()
        memset(ctx.data!, 0, w * h * 4)
        let b = SpectrumGeometry.bounds(v, style: st, canvas: canvas)
        SpectrumGeometry.draw(v, style: st, canvas: canvas, into: ctx)
        let draw = SpectrumRenderBench.ms(SpectrumRenderBench.now() - t); t = SpectrumRenderBench.now()
        guard !b.isNull else { return Out(draw: draw, crop: 0, build: nil, blend: nil, cropBytes: 0, footprintEntries: 0) }
        let rows = Int(b.minY)..<Int(b.maxY)
        let (img, box) = SubtitleRenderer.tightCrop(ctx, rows: rows)
        let crop = SpectrumRenderBench.ms(SpectrumRenderBench.now() - t)
        guard let target, w == 1920 else { return Out(draw: draw, crop: crop, build: nil, blend: nil, cropBytes: img.bytesPerRow * img.height, footprintEntries: 0) }
        t = SpectrumRenderBench.now()
        let draw2 = box.isNull ? CGRect(x: 0, y: rows.lowerBound, width: w, height: rows.count) : box.offsetBy(dx: 0, dy: CGFloat(rows.lowerBound))
        let r = SubtitleRaster(image: img, rect: CGRect(x: 0, y: 0, width: w, height: h), fontUsed: "", missingFont: false, fallbackFonts: [], lines: 0, textBounds: .zero,
                               failed: false, clipped: false, hitRect: .zero, drawRect: draw2)
        let fp = SubtitleFootprint(SubtitleItem(lane: UUID(), start: 0, length: 1, text: "spectrum"), r)
        let build = SpectrumRenderBench.ms(SpectrumRenderBench.now() - t); t = SpectrumRenderBench.now()
        CVPixelBufferLockBaseAddress(target, []); fp.composite(target); CVPixelBufferUnlockBaseAddress(target, [])
        let blend = SpectrumRenderBench.ms(SpectrumRenderBench.now() - t)
        return Out(draw: draw, crop: crop, build: build, blend: blend, cropBytes: img.bytesPerRow * img.height, footprintEntries: fp.yIdx.count + fp.cIdx.count)
    }
}
