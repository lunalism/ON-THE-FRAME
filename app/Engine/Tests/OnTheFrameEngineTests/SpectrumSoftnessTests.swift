import CoreGraphics
import XCTest
@testable import OnTheFrameEngine

final class SpectrumSoftnessTests: XCTestCase {
    // SpectrumFrameRenderer owns tightly packed, little-endian premultiplied BGRA.
    private struct Raster {
        let frame: SpectrumRenderedFrame
        let bytes: [UInt8]

        init(_ frame: SpectrumRenderedFrame) {
            self.frame = frame
            self.bytes = SpectrumFrameRendererTests.bytes(frame.image)
        }

        func offset(x: Int, y: Int) -> Int? {
            let col = x - Int(frame.drawRect.minX), row = y - Int(frame.drawRect.minY)
            guard (0..<frame.image.width).contains(col), (0..<frame.image.height).contains(row) else { return nil }
            return row * frame.image.bytesPerRow + col * 4
        }

        func alpha(x: Int, y: Int) -> Int {
            guard let i = offset(x: x, y: y) else { return 0 }
            return Int(bytes[i + 3])
        }
    }

    func testZeroUsesOriginalBytesAndDrawRectAcrossModesAndBandCounts() throws {
        let renderer = try SpectrumFrameRenderer(width: 384, height: 216)
        for mode in SpectrumFrameRendererTests.modes {
            for count in [1, 16, 1024] {
                var style = SpectrumItemStyle.provisionalDefault
                style.mode = mode
                style.bands = count
                style.startXMilli = -60_000
                style.endYMilli = 75_125
                style.thicknessMilli = 3_125
                style.red = 223
                style.alpha = 148
                style.outsideRGB = .init(red: 5, green: 61, blue: 239)
                var values = SpectrumFrameRendererTests.values(count, seed: 1985)
                values[0] = 0
                if count > 1 { values[1] = 0.00001 }
                for hue in [0, 180, 360] {
                    style.hueInterpolationDegrees = hue
                    let original = try XCTUnwrap(renderer.render(bands: values, style: style))
                    let zero = try XCTUnwrap(renderer.render(bands: values, style: style, experimentalSoftnessPercent: 0))
                    XCTAssertEqual(zero.drawRect, original.drawRect)
                    XCTAssertTrue(SpectrumFrameRendererTests.bytes(original.image) == SpectrumFrameRendererTests.bytes(zero.image),
                                  "\(mode) \(count) bands, Hue \(hue)")
                }
            }
        }
    }

    func testEmptyAndInvalidInputsPreserveExistingSemantics() throws {
        let renderer = try SpectrumFrameRenderer(width: 192, height: 108)
        var digital = SpectrumItemStyle.provisionalDefault
        digital.bands = 1
        var analog = digital
        analog.mode = .analog
        var clear = digital
        clear.alpha = 0
        var outside = digital
        outside.startYMilli = -3_000_000
        outside.endYMilli = outside.startYMilli
        for percent in [0, 1, 50, 100] {
            for style in [analog, clear] {
                let empty = try XCTUnwrap(renderer.render(bands: [0], style: style, experimentalSoftnessPercent: percent))
                XCTAssertEqual(empty.image.width, 1)
                XCTAssertEqual(empty.image.height, 1)
                XCTAssertEqual(SpectrumFrameRendererTests.bytes(empty.image), [0, 0, 0, 0])
            }
            XCTAssertNil(try renderer.render(bands: [0], style: outside, experimentalSoftnessPercent: percent))
        }
        let kept = try XCTUnwrap(renderer.render(bands: [0.8], style: digital, experimentalSoftnessPercent: 100))
        let oldBytes = SpectrumFrameRendererTests.bytes(kept.image)
        for invalid in [Int.min, -1, 101, Int.max] {
            XCTAssertThrowsError(try renderer.render(bands: [0.8], style: digital, experimentalSoftnessPercent: invalid))
        }
        XCTAssertThrowsError(try renderer.render(bands: [.nan], style: digital, experimentalSoftnessPercent: 50))
        XCTAssertThrowsError(try renderer.render(bands: [], style: digital, experimentalSoftnessPercent: 50))
        _ = try renderer.render(bands: [0], style: analog, experimentalSoftnessPercent: 0)
        XCTAssertEqual(SpectrumFrameRendererTests.bytes(kept.image), oldBytes)
    }

    func testPixelCentreDistanceAndFeatherWidthFollowTheCandidateCurve() throws {
        // One vertical rectangle crossing both canvas edges. The first covered pixel
        // centre is exactly 0.5 px from its left edge; Quartz coverage is 100% there.
        for height in [540, 1080] {
            let renderer = try SpectrumFrameRenderer(width: 192, height: height)
            for thickness in [6, 16] {
                var style = SpectrumItemStyle.provisionalDefault
                style.bands = 1
                style.maxHeightMilli = 1_080_000
                style.thicknessMilli = thickness * 1000
                style.alpha = 128
                // Keep both rectangle edges on integer pixels at both scales.
                let width = Double(thickness) * Double(height) / 1080
                let center = width.truncatingRemainder(dividingBy: 2) == 0 ? 96.0 : 96.5
                style.startXMilli = Int(center * 10_000) - 100_000
                style.endXMilli = Int(center * 10_000) + 100_000
                let left = Int(center - width / 2)
                for percent in [0, 1, 50, 100] {
                    let rendered = try XCTUnwrap(renderer.render(bands: [1], style: style, experimentalSoftnessPercent: percent))
                    let raster = Raster(rendered)
                    let radius = Double(percent) / 100 * min(Double(thickness) / 2, 4) * Double(height) / 1080
                    if height == 1080, thickness == 16 {
                        let profile = (0..<5).map { raster.alpha(x: left + $0, y: height / 2) }
                        print("SOFTNESS_EDGE percent=\(percent) alpha128 distance0.5through4.5=\(profile)")
                    }
                    for col in 0..<Int(width) {
                        let d = min(Double(col) + 0.5, width - Double(col) - 0.5)
                        let t = radius == 0 ? 1 : min(d / radius, 1)
                        let k = 1 - Double(percent) / 200 * (1 - t * t * (3 - 2 * t))
                        let expected = Int((128 * k).rounded())
                        for row in [0, 31, 63, 64, 127, height / 2, height - 1] {
                            XCTAssertLessThanOrEqual(abs(raster.alpha(x: left + col, y: row) - expected), 1,
                                           "\(height)p width \(width), \(percent)%, (\(left + col),\(row))")
                        }
                    }
                }
            }
        }
    }

    func testFeatherAttenuatesOnlyExistingCoverageAndPreservesPerPixelColor() throws {
        let renderer = try SpectrumFrameRenderer(width: 480, height: 540)
        let values: [Float] = [0, 0.75, 0.00001, 0.8, 0, 1, 0.15]
        for mode in SpectrumFrameRendererTests.modes {
            var style = SpectrumItemStyle.provisionalDefault
            style.bands = values.count
            style.mode = mode
            style.startXMilli = -40_000
            style.startYMilli = 600_000
            style.endXMilli = 1_980_000
            style.endYMilli = 310_000
            style.maxHeightMilli = 140_000
            style.thicknessMilli = 12_000
            style.alpha = 127
            style.red = 241
            style.green = 37
            style.blue = 88
            style.outsideRGB = .init(red: 21, green: 72, blue: 244)
            for hue in [0, 180, 360] {
                style.hueInterpolationDegrees = hue
                let original = Raster(try XCTUnwrap(renderer.render(bands: values, style: style)))
                for percent in [1, 50, 100] {
                    let result = Raster(try XCTUnwrap(renderer.render(bands: values, style: style, experimentalSoftnessPercent: percent)))
                    var changed = 0
                    let bounds = original.frame.drawRect.union(result.frame.drawRect)
                    for y in Int(bounds.minY)..<Int(bounds.maxY) {
                        for x in Int(bounds.minX)..<Int(bounds.maxX) {
                            let old = original.offset(x: x, y: y), new = result.offset(x: x, y: y)
                            let a = old.map { Int(original.bytes[$0 + 3]) } ?? 0
                            let b = new.map { Int(result.bytes[$0 + 3]) } ?? 0
                            guard b <= a, 2 * b + 1 >= a else {
                                return XCTFail("Alpha \(a)→\(b) outside inward feather range at (\(x),\(y))")
                            }
                            if a != b { changed += 1 }
                            guard let new else { continue }
                            for channel in 0..<3 {
                                let component = Int(result.bytes[new + channel])
                                let reference = old.map { Int(original.bytes[$0 + channel]) } ?? 0
                                // Both the original and resulting premultiplied colors are 8-bit.
                                guard component <= b, abs(component * a - reference * b) <= a + 1 else {
                                    return XCTFail("Premultiplication or color field changed at (\(x),\(y)), channel \(channel)")
                                }
                            }
                        }
                    }
                    if percent >= 50 { XCTAssertGreaterThan(changed, 0, "\(mode), hue \(hue), \(percent)%") }
                }
            }
        }
    }

    func testSilentDigitalDotsRemainDiscreteAndAnalogCrossesCanvasWithoutASeam() throws {
        let renderer = try SpectrumFrameRenderer(width: 480, height: 540)
        var style = SpectrumItemStyle.provisionalDefault
        style.bands = 8
        style.thicknessMilli = 12_000
        let silent = [Float](repeating: 0, count: style.bands)
        for percent in [1, 50, 100] {
            let raster = Raster(try XCTUnwrap(renderer.render(bands: silent, style: style, experimentalSoftnessPercent: percent)))
            for band in 0..<style.bands {
                let center = 72 + 48 * band
                XCTAssertGreaterThan(raster.alpha(x: center, y: 270), 0)
                XCTAssertEqual(raster.alpha(x: center + 24, y: 270), 0)
            }
        }
        style.mode = .analog
        style.startXMilli = -600_000
        style.endXMilli = 2_520_000
        let full = Raster(try XCTUnwrap(renderer.render(bands: silent, style: style, experimentalSoftnessPercent: 100)))
        for y in 266...274 {
            let expected = full.alpha(x: 250, y: y)
            for x in 0..<480 where full.alpha(x: x, y: y) != expected {
                return XCTFail("Spurious edge at tile or canvas boundary (\(x),\(y))")
            }
        }
        XCTAssertEqual(full.alpha(x: 0, y: 270), 255)
        XCTAssertLessThan(full.alpha(x: 0, y: 267), 255)
        XCTAssertGreaterThan(full.alpha(x: 0, y: 267), 0)
    }

    func testOverlappingBarsHaveOnlyOneOuterEdge() throws {
        // Three 12 px wide bars on 6 px centres combine into a solid 24 px rectangle.
        let renderer = try SpectrumFrameRenderer(width: 480, height: 540)
        var style = SpectrumItemStyle.provisionalDefault
        style.bands = 3
        style.thicknessMilli = 24_000
        style.maxHeightMilli = 100_000
        style.startXMilli = 444_000
        style.endXMilli = 516_000
        style.sides = .above
        style.alpha = 96
        let bands: [Float] = [1, 1, 1]
        let base = Raster(try XCTUnwrap(renderer.render(bands: bands, style: style)))
        let soft = Raster(try XCTUnwrap(renderer.render(bands: bands, style: style, experimentalSoftnessPercent: 100)))
        // Band centres: 114, 120 and 126. Overlap edges lie between 114 and 126.
        for x in 112...127 {
            XCTAssertEqual(base.alpha(x: x, y: 250), 96)
            XCTAssertEqual(soft.alpha(x: x, y: 250), base.alpha(x: x, y: 250))
        }
        XCTAssertLessThan(soft.alpha(x: 108, y: 250), base.alpha(x: 108, y: 250))
        XCTAssertEqual(soft.alpha(x: 107, y: 250), 0)
    }
}
