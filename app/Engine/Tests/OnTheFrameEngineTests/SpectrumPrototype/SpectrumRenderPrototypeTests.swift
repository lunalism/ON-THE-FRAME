import AVFoundation
import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import XCTest

// 스펙트럼 타당성 검사 시제품(2026-10-24, docs/SPECTRUM-DESIGN.md §9) — 제품 코드가 아니다(시험 대상 안, 기본 실행에서 건너뜀).

extension ProtoSpectrumRenderer {
    /// 칠한 부분만 잘라 출력 좌표 그림(자막과 같은 tightCrop·drawRect) → 4:2:0 발자국
    static func footprint(_ ctx: CGContext, frame k: Int) -> SubtitleFootprint {
        let (img, box) = SubtitleRenderer.tightCrop(ctx, rows: 0..<ctx.height)
        let full = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        let draw = box.isNull ? full : box
        let r = SubtitleRaster(image: img, rect: full, fontUsed: "", missingFont: false, fallbackFonts: [], lines: 0, textBounds: .zero, failed: false, clipped: false,
                               hitRect: .zero, drawRect: draw)
        return SubtitleFootprint(SubtitleItem(id: UUID(), lane: UUID(), start: k, length: 1, text: "spectrum", style: .default), r)
    }
}

final class SpectrumRenderPrototypeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SPECTRUM_PROTO"] == "1", "스펙트럼 시제품 검사는 OTF_SPECTRUM_PROTO=1일 때만")
    }
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }

    func testGeometryScalesWithCanvas() {
        let s = ProtoSpectrumStyle()
        let a = ProtoSpectrumRenderer.geometry(s, bands: 64, canvas: CGSize(width: 1920, height: 1080))
        let b = ProtoSpectrumRenderer.geometry(s, bands: 64, canvas: CGSize(width: 3840, height: 2160))
        for (p, q) in zip(a.points, b.points) { XCTAssertEqual(q.x, p.x * 2, accuracy: 1e-9); XCTAssertEqual(q.y, p.y * 2, accuracy: 1e-9) }
        XCTAssertEqual(b.scaleY, 2)
        XCTAssertEqual(a.points.first!.x, 192 + 1536 / 128, accuracy: 1e-9)   // 첫 밴드 = 기준선 첫 칸 가운데
    }

    /// 그리기 전 범위 계산(SP-0): 전체 캔버스에 그리고 잘라 낸 것과 화소가 같은지(캔버스에 다시 놓아 비교), 비용 비교. 디지털·아날로그 × 세 방향.
    func testBoundedRenderMatchesFullCanvas() {
        let canvas = CGSize(width: 1920, height: 1080)
        var rng = SystemRandomNumberGenerator()
        var tFull = 0.0, tBounded = 0.0, cases = 0, differ = 0, maxD = 0, outside = 0, painted = 0
        for mode in [ProtoSpectrumStyle.Mode.digital, .analog] { for sides in [ProtoSpectrumStyle.Sides.above, .mirrored, .below] { for _ in 0..<5 {
            var st = ProtoSpectrumStyle(); st.mode = mode; st.sides = sides
            let v = (0..<64).map { _ in Float.random(in: 0...1, using: &rng) * (Bool.random(using: &rng) ? 1 : 0.2) }
            var c0 = Date()
            let full = ProtoSpectrumRenderer.render(v, style: st, canvas: canvas)
            let fullImg = full.makeImage()!
            _ = SubtitleRenderer.tightCrop(full, rows: 0..<full.height)   // 제품 자막 경로와 같은 훑기(시간 비교용)
            tFull += Date().timeIntervalSince(c0); c0 = Date()
            let b = ProtoSpectrumRenderer.renderBounded(v, style: st, canvas: canvas)
            tBounded += Date().timeIntervalSince(c0)
            // 칠한 화소(0이 아닌 화소)가 모두 미리 계산한 범위 안인가 — 정확한 칠한 경계로(tightCrop 상자는 16 px 배수로 넓힘)
            do {
                let px = full.data!.assumingMemoryBound(to: UInt32.self)
                var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
                for y in 0..<1080 { for x in 0..<1920 where px[y * 1920 + x] != 0 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
                if x1 >= 0 { let painted = CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1); if !(b?.rect.contains(painted) ?? false) { outside += 1 } }
            }
            // 비교: 범위 그림을 캔버스 크기 투명 그림에 바이트 복사로 놓고 전체 그림과 비교
            let place = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            if let b {
                let src = b.image.dataProvider!.data! as Data, sbpr = b.image.bytesPerRow, dst = place.data!.assumingMemoryBound(to: UInt8.self)
                src.withUnsafeBytes { p in for y in 0..<b.image.height { for x in 0..<b.image.width * 4 { dst[(Int(b.rect.minY) + y) * 1920 * 4 + Int(b.rect.minX) * 4 + x] = p[y * sbpr + x] } } }
            }
            let a1 = fullImg.dataProvider!.data! as Data, a2 = place.makeImage()!.dataProvider!.data! as Data
            a1.withUnsafeBytes { p1 in a2.withUnsafeBytes { p2 in
                for i in 0..<(1920 * 1080 * 4) { if p1[i] != 0 { painted += 1 }; let d = abs(Int(p1[i]) - Int(p2[i])); if d > 0 { differ += 1; maxD = max(maxD, d) } }
            } }
            cases += 1
        } } }
        print(String(format: "PROTO bounded render: %d cases, painted bytes %d, differing bytes %d (max %d), box outside bounds %d, full+scan %.2f ms/case, bounded %.2f ms/case",
                     cases, painted, differ, maxD, outside, tFull / Double(cases) * 1000, tBounded / Double(cases) * 1000))
        XCTAssertEqual(outside, 0, "칠한 화소는 모두 미리 계산한 범위 안")
        // 비트 단위로 같지는 않다(측정: 앤티에일리어싱 가장자리 바이트 일부가 최대 7/255 다름 — 원점을 옮긴 문맥의 래스터화 차이로 보이나 원인 미확인)
        XCTAssertLessThanOrEqual(maxD, 8, "범위만 그린 그림 ≈ 전체에 그린 그림(같은 자리, 바이트 차 ≤ 8)")
    }

    /// 내보내기 타당성: 구조 R과 같은 차례(4:2:0 읽기 → 프레임 펼치기 → 칠한 화소만 섞기 → 4:2:0 쓰기)를 시험 안에서 돌린다(제품 코드 변경 없음).
    /// 분석은 aud-wav48s(440 Hz, 클릭 12345·60000)를 그 타임라인 자리 그대로 둔 소스로. 비교: 제품 구조 R의 같은 계획(자막 없음) 출력.
    func testExportFeasibilityThroughStructureR() async throws {
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        let t = try Timeline().registering(ta).inserting(media: ta.id)
        let p = try await CompositionPlanner.plan(t, media: [ta.id: ta])
        let n = 60
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otf-spectrum-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 1) 기준: 제품 구조 R(자막 없음 → 그대로 읽고 씀)
        let plainURL = dir.appendingPathComponent("plain.mp4")
        try await SubtitleExporter.encode(p, to: plainURL, failAfterFraction: nil) { _ in }
        // 2) 스펙트럼: 같은 리더·쓰기 설정, 프레임마다 분석 → 그림 → 발자국 → 섞기
        let analyzer = ProtoAnalyzer(source: ProtoPCMSource(url: fixtures.appendingPathComponent("aud-wav48s.wav")))
        let piece = ProtoPiece(start: 0, length: 120, sourceIn: 0, audio: .default, laneGain: 1)
        let style = ProtoSpectrumStyle()
        let canvas = CGSize(width: 1920, height: 1080)
        let specURL = dir.appendingPathComponent("spectrum.mp4")
        let reader = try AVAssetReader(asset: p.composition)
        var vs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat]; vs[AVVideoColorPropertiesKey] = SubtitleExporter.color709
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: vs)
        vOut.videoComposition = p.videoComposition; vOut.alwaysCopiesSampleData = false; reader.add(vOut)
        let writer = try AVAssetWriter(outputURL: specURL, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: SubtitleExporter.videoSettings); vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()])
        writer.add(vIn)
        XCTAssertTrue(reader.startReading()); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var current: CVPixelBuffer?, next: (CMTime, CVPixelBuffer)?
        func nextSample() -> (CMTime, CVPixelBuffer)? { while let sb = vOut.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb) { return (CMSampleBufferGetPresentationTimeStamp(sb), pb) } }; return nil }
        next = nextSample()
        var tAnalysis = 0.0, tRender = 0.0, tComposite = 0.0, changedOutsideBeforeEncode = 0
        var bandsByFrame: [[Float]] = [], drawRects: [CGRect] = []
        for k in 0..<n {
            let t = CMTime(value: CMTimeValue(k), timescale: 30)
            while let s = next, CMTimeCompare(s.0, t) <= 0 { current = s.1; next = nextSample() }
            let src = try XCTUnwrap(current)
            var c0 = Date()
            let v = try analyzer.bands(frame: k, pieces: [piece]); bandsByFrame.append(v)
            tAnalysis += Date().timeIntervalSince(c0); c0 = Date()
            let ctx = ProtoSpectrumRenderer.render(v, style: style, canvas: canvas)
            let fp = ProtoSpectrumRenderer.footprint(ctx, frame: k)
            drawRects.append(SubtitleRenderer.tightCrop(ctx, rows: 0..<ctx.height).box)
            tRender += Date().timeIntervalSince(c0); c0 = Date()
            var o: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &o)
            let ob = try XCTUnwrap(o)
            SubtitleFootprint.copyPlanes(src, ob)
            CVPixelBufferLockBaseAddress(ob, []); fp.composite(ob); CVPixelBufferUnlockBaseAddress(ob, [])
            tComposite += Date().timeIntervalSince(c0)   // 아래 불변식 검사는 시간에 넣지 않음
            // 인코딩 전 불변식: 그림 범위(+2 px, 색차 칸) 밖의 밝기·색차 값은 원본 버퍼와 같아야 한다(영상 전체를 다시 처리하지 않음)
            let box = SubtitleRenderer.tightCrop(ctx, rows: 0..<ctx.height).box.insetBy(dx: -2, dy: -2)
            CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(ob, .readOnly)
            for plane in 0..<2 {
                let sp = CVPixelBufferGetBaseAddressOfPlane(src, plane)!.assumingMemoryBound(to: UInt8.self), dp = CVPixelBufferGetBaseAddressOfPlane(ob, plane)!.assumingMemoryBound(to: UInt8.self)
                let sb = CVPixelBufferGetBytesPerRowOfPlane(src, plane), db = CVPixelBufferGetBytesPerRowOfPlane(ob, plane)
                let ph = CVPixelBufferGetHeightOfPlane(src, plane), pw = CVPixelBufferGetWidthOfPlane(src, plane) * (plane == 0 ? 1 : 2)
                let scale = plane == 0 ? 1 : 2
                for y in 0..<ph { for x in 0..<pw where !box.contains(CGPoint(x: (x / (plane == 0 ? 1 : 2)) * scale, y: y * scale)) {
                    if sp[y * sb + x] != dp[y * db + x] { changedOutsideBeforeEncode += 1 }
                } }
            }
            CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(ob, .readOnly)
            CVBufferPropagateAttachments(src, ob)
            CVBufferSetAttachment(ob, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(ob, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(ob, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            while !vIn.isReadyForMoreMediaData { usleep(1000) }
            XCTAssertTrue(adaptor.append(ob, withPresentationTime: t))
        }
        reader.cancelReading()
        vIn.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: CMTimeValue(n), timescale: 30)); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        print(String(format: "PROTO export per frame (60 frames): analysis %.1f ms render+crop %.1f ms footprint+composite %.1f ms",
                     tAnalysis / Double(n) * 1000, tRender / Double(n) * 1000, tComposite / Double(n) * 1000))
        // 분석: 클릭(표본 12345)이 창에 드는 프레임 7·8은 높은 밴드가 크고, 프레임 5는 작다
        let hiBand = analyzer.bandIndex(ofHz: 1800)
        print("PROTO click band \(hiBand): f5 \(bandsByFrame[5][hiBand]) f7 \(bandsByFrame[7][hiBand]) f8 \(bandsByFrame[8][hiBand])")
        XCTAssertGreaterThan(bandsByFrame[8][hiBand], bandsByFrame[5][hiBand] + 0.15); XCTAssertGreaterThan(bandsByFrame[7][hiBand], bandsByFrame[5][hiBand])
        XCTAssertEqual(changedOutsideBeforeEncode, 0, "인코딩 전: 그림 범위 밖 4:2:0 값은 바뀌지 않음")
        // 디코딩 비교
        let frames: Set<Int> = [5, 7, 8, 30]
        let a = try await SubtitleExportTests.planes(plainURL, frames), b = try await SubtitleExportTests.planes(specURL, frames)
        let g = ProtoSpectrumRenderer.geometry(style, bands: 64, canvas: canvas)
        let colX = Int(g.points[hiBand].x.rounded()), baseY = Int(g.points[hiBand].y.rounded())
        func barLen(_ f: Int) -> Int { (0..<480).filter { d in let y = baseY - d; return Int(b[f]!.y[y * 1920 + colX]) - Int(a[f]!.y[y * 1920 + colX]) > 40 }.count }
        print("PROTO decoded bar length at band \(hiBand) column \(colX): f5 \(barLen(5)) f7 \(barLen(7)) f8 \(barLen(8))")
        XCTAssertGreaterThan(barLen(8), barLen(5) + 40, "디코딩한 출력에서도 클릭 프레임 막대가 길다(프레임 대응)")
        XCTAssertGreaterThan(barLen(7), barLen(5))
        // 스펙트럼 밖(모든 프레임 그림 범위 + 16 px 여유 밖)은 기준과 같음
        let union = drawRects.filter { !$0.isNull }.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -16, dy: -16)
        var maxOut = 0, sumOut = 0, cnt = 0, maxIn = 0
        for f in frames { for y in stride(from: 0, to: 1080, by: 2) { for x in stride(from: 0, to: 1920, by: 2) {
            let d = abs(Int(a[f]!.y[y * 1920 + x]) - Int(b[f]!.y[y * 1920 + x]))
            if union.contains(CGPoint(x: x, y: y)) { maxIn = max(maxIn, d) } else { maxOut = max(maxOut, d); sumOut += d; cnt += 1 }
        } } }
        print("PROTO outside spectrum region: max |ΔY| \(maxOut) mean \(String(format: "%.4f", Double(sumOut) / Double(cnt))) (inside max \(maxIn)) union \(union)")
        // 바깥 차이가 어디서 오는가: 같은 입력을 두 번 인코딩한 기준 흔들림, 그리고 바깥 큰 차이(>3)의 그림 범위까지 거리
        let plain2 = dir.appendingPathComponent("plain2.mp4")
        try await SubtitleExporter.encode(p, to: plain2, failAfterFraction: nil) { _ in }
        let c2 = try await SubtitleExportTests.planes(plain2, frames)
        var base = 0; for f in frames { for i in stride(from: 0, to: 1920 * 1080, by: 3) { base = max(base, abs(Int(a[f]!.y[i]) - Int(c2[f]!.y[i]))) } }
        var big = 0, far = 0.0
        for f in frames { for y in 0..<1080 { for x in 0..<1920 where !union.contains(CGPoint(x: x, y: y)) {
            if abs(Int(a[f]!.y[y * 1920 + x]) - Int(b[f]!.y[y * 1920 + x])) > 3 {
                big += 1
                let dx = max(union.minX - CGFloat(x), 0, CGFloat(x) - union.maxX), dy = max(union.minY - CGFloat(y), 0, CGFloat(y) - union.maxY)
                far = max(far, Double(hypot(dx, dy)))
            }
        } } }
        print("PROTO encoder baseline (plain vs plain again) max |ΔY| \(base); outside pixels |ΔY|>3: \(big) of \(frames.count * 1920 * 1080 - Int(union.width * union.height) * frames.count), farthest \(String(format: "%.0f", far)) px from spectrum box")
    }

    /// 프리뷰 프레임 선택 — 직접 호출 흉내(실제 재생·디스플레이 링크가 아님): 항목 시각 k/30 + δ(δ < 1/30)는 프레임 k를 고르고, 그 프레임의 분석 값은 내보내기와 같다.
    func testPreviewFrameSelectionSimulation() throws {
        let analyzer = ProtoAnalyzer(source: ProtoPCMSource(url: fixtures.appendingPathComponent("aud-wav48s.wav")))
        let piece = ProtoPiece(start: 0, length: 120, sourceIn: 0, audio: .default, laneGain: 1)
        let settings = RenderSettings.m1
        for k in [0, 7, 8, 29, 59] {
            for delta in [0.0, 0.004, 0.0333] {
                let t = CMTime(seconds: Double(k) / 30 + delta, preferredTimescale: 600_000)
                XCTAssertEqual(settings.frame(containing: t), k)
            }
            XCTAssertEqual(try analyzer.bands(frame: settings.frame(containing: CMTime(value: CMTimeValue(k), timescale: 30)), pieces: [piece]), try analyzer.bands(frame: k, pieces: [piece]))
        }
    }
}
