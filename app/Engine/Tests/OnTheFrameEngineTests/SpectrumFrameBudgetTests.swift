import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E3: 발자국 메모리 계산과 프레임 장부(파일·디코딩 없음). 계산한 상한이며 프로세스 메모리의 측정이 아니다.
final class SpectrumFrameBudgetTests: XCTestCase {
    typealias Cost = SpectrumFootprintCost
    /// 불투명한 단색 그림(BGRA, 미리 곱함)을 (x, y)에 놓은 프레임
    static func solid(width w: Int, height h: Int, x: Int, y: Int) throws -> SpectrumRenderedFrame {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        px.withUnsafeMutableBufferPointer { p in for i in 0..<(w * h) { p[i * 4] = 40; p[i * 4 + 1] = 200; p[i * 4 + 2] = 90 } }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw SpectrumTimelineFixture.Failure("image") }
        return SpectrumRenderedFrame(image: image, drawRect: CGRect(x: x, y: y, width: w, height: h), canvasWidth: 1920, canvasHeight: 1080)
    }

    // 1. 계산식이 실제 발자국을 덮는다: 실제 원소 수와 붙잡은 바이트가 상한 이하
    func testEstimatesCoverRealFootprints() throws {
        for (w, h, x, y) in [(200, 100, 64, 64), (320, 48, 1, 3), (16, 16, 1904, 1064), (1536, 96, 192, 492)] {
            let r = try Self.solid(width: w, height: h, x: x, y: y)
            let fp = SpectrumTimelineFrames.footprint(r, lane: UUID(), frame: 0)
            let chroma = try XCTUnwrap(Cost.chromaSamples(x0: x, y0: y, width: w, height: h))
            XCTAssertEqual(fp.yIdx.count, w * h, "\(w)x\(h): 불투명한 화소마다 밝기 원소 하나")
            XCTAssertLessThanOrEqual(fp.cIdx.count, chroma, "\(w)x\(h): 색차 원소 수 ≤ 격자 칸 수")
            XCTAssertGreaterThanOrEqual(fp.cIdx.count, (w / 2) * (h / 2))
            XCTAssertEqual(Cost.paintedPixels(r.image), w * h, "모두 불투명")
            let retained = try XCTUnwrap(Cost.retainedBound(x0: x, y0: y, width: w, height: h, painted: w * h))
            let peak = try XCTUnwrap(Cost.constructionPeak(r, painted: w * h))
            XCTAssertEqual(Cost.constructionPeak(r), peak, "세지 않으면 모두 칠했다고 본다")
            let empty = try XCTUnwrap(Cost.constructionPeak(r, painted: 0))
            XCTAssertEqual(empty, 2 * w * h * 4 + 4 * 8 * w * h, "칠한 화소가 없으면 그림 둘과 Double 배열 넷뿐")
            XCTAssertLessThanOrEqual(fp.retainedBytes, retained, "\(w)x\(h): 붙잡은 바이트 ≤ 상한")
            XCTAssertGreaterThan(fp.retainedBytes, 0)
            XCTAssertGreaterThan(peak, retained, "만드는 동안의 상한은 남는 양보다 크다")
            XCTAssertGreaterThanOrEqual(peak, 2 * w * h * 4 + 4 * 8 * w * h, "그림 둘과 Double 배열 넷을 포함")
        }
    }
    // 화면 전체와 가장자리의 색차 격자 수는 SubtitleFootprint의 범위 식과 같다
    func testChromaGridMatchesFootprintRanges() {
        XCTAssertEqual(Cost.chromaSamples(x0: 0, y0: 0, width: 1920, height: 1080), 960 * 540, "화면 전체")
        XCTAssertEqual(Cost.chromaSamples(x0: 64, y0: 64, width: 16, height: 16), (41 - 30 + 1) * (41 - 31 + 1), "열 30…41, 행 31…41")
        XCTAssertEqual(Cost.chromaSamples(x0: 4000, y0: 0, width: 16, height: 16), 0, "화면 밖")
        XCTAssertEqual(Cost.maxImageBytes, 1920 * 1080 * 4)
        XCTAssertEqual(Cost.imageBytes(bytesPerRow: 7680, height: 1080), 8_294_400)
    }
    // 2. 넘치는 계산은 감기지 않고 nil → 거부
    func testOverflowIsRejectedNotWrapped() {
        XCTAssertNil(Cost.mul(Int.max, 2)); XCTAssertNil(Cost.add(Int.max, 1)); XCTAssertNil(Cost.mul(-1, 4)); XCTAssertNil(Cost.add(3, nil))
        XCTAssertNil(Cost.imageBytes(bytesPerRow: Int.max, height: 4))
        XCTAssertNil(Cost.chromaSamples(x0: 0, y0: 0, width: Int.max, height: 2))
        XCTAssertNil(Cost.retainedBound(x0: 0, y0: 0, width: 1 << 40, height: 1 << 40))
        XCTAssertNil(Cost.constructionPeak(imageBytes: nil, x0: 0, y0: 0, width: 16, height: 16))
        XCTAssertNil(Cost.constructionPeak(imageBytes: Int.max, x0: 0, y0: 0, width: 16, height: 16))
        XCTAssertNil(Cost.constructionPeak(imageBytes: 1_024, x0: 0, y0: 0, width: 16, height: 16, painted: -1))
        XCTAssertEqual(Cost.elements(x0: 0, y0: 0, width: 16, height: 16, painted: Int.max)?.luma, 256, "칠한 화소 수는 넓이를 넘지 않는다")
        var budget = SpectrumFrameBudget(limit: 1 << 30)
        XCTAssertThrowsError(try budget.admit(transient: nil)) {
            XCTAssertEqual($0 as? SpectrumTimelineExportError, .frameMemoryBudgetExceeded(required: Int.max, limit: 1 << 30))
        }
        XCTAssertThrowsError(try budget.retain(Int.max))
        XCTAssertEqual(budget.retained, 0); XCTAssertEqual(budget.peak, 0, "거부한 요청은 장부를 바꾸지 않는다")
    }
    // 장부는 누적 합이 아니라 동시에 쓰는 양의 최대를 본다
    func testBudgetTracksConcurrentPeakNotCumulativeSum() throws {
        var budget = SpectrumFrameBudget(limit: 100)
        try budget.admit(transient: 60); XCTAssertEqual(budget.peak, 60); XCTAssertEqual(budget.retained, 0)
        try budget.retain(20)
        try budget.admit(transient: 60); XCTAssertEqual(budget.peak, 80, "남은 20 + 잠깐 60")
        try budget.retain(20); XCTAssertEqual(budget.retained, 40)
        try budget.admit(transient: 60); XCTAssertEqual(budget.peak, 100, "한도와 같으면 허락")
        XCTAssertThrowsError(try budget.admit(transient: 61)) {
            XCTAssertEqual($0 as? SpectrumTimelineExportError, .frameMemoryBudgetExceeded(required: 101, limit: 100))
        }
        XCTAssertEqual(budget.retained, 40); XCTAssertEqual(budget.peak, 100)
    }
}
