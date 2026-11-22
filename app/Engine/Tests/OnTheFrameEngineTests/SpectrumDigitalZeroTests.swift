import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SPECTRUM-ZERO-01: raster geometry only; no fabricated analysis or time special case.
final class SpectrumDigitalZeroTests: XCTestCase {
    private func style(_ sides: SpectrumItemStyle.Sides = .above) -> SpectrumItemStyle {
        var s = SpectrumItemStyle.provisionalDefault
        s.bands = 8; s.mode = .digital; s.sides = sides
        s.startXMilli = 192_000; s.endXMilli = 1_728_000
        s.startYMilli = 540_000; s.endYMilli = 540_000
        s.thicknessMilli = 6_000; s.maxHeightMilli = 400_000
        return s
    }
    private func pixel(_ f: SpectrumRenderedFrame, _ x: Int, _ y: Int) -> [UInt8] {
        let dx = x - Int(f.drawRect.minX), dy = y - Int(f.drawRect.minY)
        guard (0..<f.image.width).contains(dx), (0..<f.image.height).contains(dy) else { return [0, 0, 0, 0] }
        let d = f.image.dataProvider!.data!
        let o = dy * f.image.bytesPerRow + dx * 4
        return withExtendedLifetime(d) {
            let p = CFDataGetBytePtr(d)!
            return (0..<4).map { p[o + $0] }
        }
    }
    private func same(_ a: SpectrumRenderedFrame, _ b: SpectrumRenderedFrame,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.drawRect, b.drawRect, file: file, line: line)
        XCTAssertEqual(SpectrumFrameRendererTests.bytes(a.image), SpectrumFrameRendererTests.bytes(b.image), file: file, line: line)
    }

    func testSilentBandsAreDiscreteCenteredDotsForEverySide() throws {
        let r = try SpectrumFrameRenderer(width: 1920, height: 1080)
        let zero = [Float](repeating: 0, count: 8)
        var previous: SpectrumRenderedFrame?
        for side in SpectrumFrameRendererTests.sides {
            let f = try XCTUnwrap(r.render(bands: zero, style: style(side)))
            if let previous { same(f, previous) }; previous = f
            var runs = 0, inside = false
            for x in 0..<1920 {
                let painted = pixel(f, x, 540)[3] > 0
                if painted && !inside { runs += 1 }; inside = painted
            }
            XCTAssertEqual(runs, 8, "one discrete element per configured band, no connecting baseline")
            for i in 0..<8 {
                let x = 288 + i * 192
                XCTAssertEqual(pixel(f, x, 540), [255, 255, 255, 255])
                XCTAssertGreaterThan(pixel(f, x - 2, 540)[3], 0)
                XCTAssertEqual(pixel(f, x, 536)[3], 0)
                XCTAssertEqual(pixel(f, x, 543)[3], 0)
                XCTAssertEqual(pixel(f, x + 96, 540)[3], 0)
                XCTAssertLessThan(pixel(f, x + 2, 542)[3], pixel(f, x, 540)[3], "rounded corner, not a square")
            }
            XCTAssertLessThanOrEqual(f.drawRect.height, 16, "tight row crop, not a full-height placeholder")
        }
        XCTAssertEqual(zero, [Float](repeating: 0, count: 8), "rendering never changes analysis data")
    }

    func testMixedZeroAndTinyPositiveBandsKeepPositiveBarGeometry() throws {
        var s = style(); s.bands = 3
        let v: [Float] = [0, 0.00001, 0.5]
        let r = try SpectrumFrameRenderer(width: 1920, height: 1080)
        let f = try XCTUnwrap(r.render(bands: v, style: s))
        XCTAssertGreaterThan(pixel(f, 448, 540)[3], 0, "zero dot at its own band center")
        XCTAssertEqual(pixel(f, 448, 535)[3], 0)
        XCTAssertEqual(pixel(f, 960, 542)[3], 0, "tiny positive is not raised to a dot or amplitude floor")
        XCTAssertEqual(pixel(f, 1472, 350)[3], 255, "actual positive response remains 200px above baseline")
        XCTAssertEqual(pixel(f, 1472, 541)[3], 0, "above bar does not grow below its baseline")
        XCTAssertEqual(pixel(f, 1472, 339)[3], 0)
        // Independent previous-renderer oracle for both positive bands, away from the zero dot.
        var old = ProtoSpectrumStyle(); old.start = s.renderStyle.start; old.end = s.renderStyle.end
        old.maxHeight = 400; old.thickness = 6; old.mode = .digital; old.sides = .above
        let ctx = ProtoSpectrumRenderer.render(v, style: old, canvas: CGSize(width: 1920, height: 1080))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for x in [960, 1472] { for y in 330..<550 {
            XCTAssertEqual(pixel(f, x, y), Array(UnsafeBufferPointer(start: p + (y * 1920 + x) * 4, count: 4)))
        } }
    }

    func testColorThicknessScalingAndLegacyHalfPixelAreHonored() throws {
        for (w, h) in [(960, 540), (1920, 1080), (3840, 2160)] {
            let r = try SpectrumFrameRenderer(width: w, height: h)
            for thickness in [500, 3_125, 6_000, 64_000] {
                var s = style(); s.thicknessMilli = thickness
                s.red = 240; s.green = 80; s.blue = 16; s.alpha = 128
                let v = [Float](repeating: 0, count: s.bands)
                let f = try XCTUnwrap(r.render(bands: v, style: s))
                let diameter = Double(thickness) / 1000 * Double(h) / 1080
                let x = Int(288.0 * Double(w) / 1920), y = h / 2
                let rgba = pixel(f, x, y)
                XCTAssertGreaterThan(rgba[3], 0, "configured subpixel thickness is retained")
                XCTAssertLessThanOrEqual(rgba[3], 128)
                // Subpixel coverage can quantize two small 8-bit channels to the
                // same value; it must not reverse their order or amplify alpha.
                XCTAssertGreaterThanOrEqual(rgba[2], rgba[1]); XCTAssertGreaterThanOrEqual(rgba[1], rgba[0])
                if diameter >= 1 { XCTAssertGreaterThan(rgba[2], rgba[1]); XCTAssertGreaterThan(rgba[1], rgba[0]) }
                XCTAssertEqual(pixel(f, x, y + Int(ceil(diameter / 2)) + 1)[3], 0)
                XCTAssertEqual(s.thicknessMilli, thickness, "no UI or persisted milli quantization")
            }
        }
        var clear = style(); clear.alpha = 0
        let f = try XCTUnwrap(SpectrumFrameRenderer(width: 1920, height: 1080).render(bands: [Float](repeating: 0, count: 8), style: clear))
        XCTAssertEqual(f.drawRect.size, CGSize(width: 1, height: 1))
        XCTAssertTrue(SpectrumFrameRendererTests.bytes(f.image).allSatisfy { $0 == 0 })
    }

    func testCollapsedVisualStrengthAndHeightUseTheSameZeroGeometry() throws {
        let r = try SpectrumFrameRenderer(width: 1920, height: 1080)
        let input: [Float] = [0, 0.1, 0.2, 0.4, 0.5, 0.7, 0.9, 1]
        for side in SpectrumFrameRendererTests.sides {
            let s = style(side), zero = [Float](repeating: 0, count: 8)
            let expected = try XCTUnwrap(r.render(bands: zero, style: s))
            var strength = s; strength.reactionPercent = 0
            same(try XCTUnwrap(r.render(bands: input, style: strength)), expected)
            var height = s; height.maxHeightMilli = 0
            same(try XCTUnwrap(r.render(bands: input, style: height)), expected)
            XCTAssertEqual(input, [0, 0.1, 0.2, 0.4, 0.5, 0.7, 0.9, 1])
        }
    }

    func testZeroDotBoundsIncludeClippedAndDiagonalElements() throws {
        for (w, h) in [(16, 16), (960, 540), (1920, 1080)] {
            let canvas = try SpectrumCanvas(width: w, height: h)
            for side in SpectrumFrameRendererTests.sides {
                for (a, b) in [(CGPoint(x: -192, y: 0), CGPoint(x: 2112, y: 0)),
                               (CGPoint(x: 0, y: 1080), CGPoint(x: 1920, y: 1080)),
                               (CGPoint(x: 0, y: 0), CGPoint(x: 1920, y: 1080))] {
                    var s = style(side); s.startXMilli = Int(a.x * 1000); s.startYMilli = Int(a.y * 1000)
                    s.endXMilli = Int(b.x * 1000); s.endYMilli = Int(b.y * 1000)
                    let f = try XCTUnwrap(canvas.render([Float](repeating: 0, count: 8), style: s.renderStyle))
                    XCTAssertEqual(canvas.paintedPixels(outside: f.bounds), 0)
                    XCTAssertEqual(canvas.paintedPixels(outside: f.drawRect), 0)
                    XCTAssertTrue(CGRect(x: 0, y: 0, width: w, height: h).contains(f.drawRect))
                }
            }
        }
        var off = style(); off.startYMilli = -5_000_000; off.endYMilli = -5_000_000
        XCTAssertNil(try SpectrumFrameRenderer(width: 1920, height: 1080).render(bands: [Float](repeating: 0, count: 8), style: off))
    }

    func testPositiveDigitalAndAnalogStillMatchPreviousRenderer() throws {
        let canvas = try SpectrumCanvas(width: 1920, height: 1080)
        for mode in SpectrumFrameRendererTests.modes { for side in SpectrumFrameRendererTests.sides {
            var s = style(side); s.mode = mode; s.alpha = 160; s.green = 80; s.blue = 16
            for zero in [false, true] where mode == .analog || !zero {
                let v: [Float] = zero ? [Float](repeating: 0, count: 8) : [0.00001, 0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 1]
                _ = try canvas.render(v, style: s.renderStyle)
                var old = ProtoSpectrumStyle(); old.start = s.renderStyle.start; old.end = s.renderStyle.end
                old.maxHeight = 400; old.thickness = 6
                old.mode = mode == .digital ? .digital : .analog
                old.sides = side == .above ? .above : (side == .below ? .below : .mirrored)
                old.rgba = (1, 80.0 / 255, 16.0 / 255, 160.0 / 255)
                let ref = ProtoSpectrumRenderer.render(v, style: old, canvas: CGSize(width: 1920, height: 1080))
                let p = ref.data!.assumingMemoryBound(to: UInt32.self)
                var differences = 0
                for y in 0..<1080 { for x in 0..<1920 where p[y * 1920 + x] != canvas.pixel(x: x, y: y) { differences += 1 } }
                XCTAssertEqual(differences, 0, "\(mode)/\(side) zero=\(zero): unchanged pixels")
            }
        } }
    }

    func testRepeatedZeroRendersRetainOnlyTheirOwnCanvasAndFrames() throws {
        let before = SpectrumCanvas.liveCount
        var r: SpectrumFrameRenderer? = try SpectrumFrameRenderer(width: 1920, height: 1080)
        let s = style(), zero = [Float](repeating: 0, count: 8)
        let kept = try XCTUnwrap(r!.render(bands: zero, style: s)), bytes = SpectrumFrameRendererTests.bytes(kept.image)
        for _ in 0..<100 { autoreleasepool { _ = try? r!.render(bands: zero, style: s) } }
        let m0 = SpectrumFrameRendererTests.footprintMB()
        for _ in 0..<2000 { autoreleasepool { _ = try? r!.render(bands: zero, style: s) } }
        XCTAssertLessThan(SpectrumFrameRendererTests.footprintMB() - m0, 32)
        XCTAssertEqual(SpectrumCanvas.liveCount, before + 1)
        XCTAssertEqual(SpectrumFrameRendererTests.bytes(kept.image), bytes)
        r = nil
        XCTAssertEqual(SpectrumCanvas.liveCount, before)
        XCTAssertEqual(SpectrumFrameRendererTests.bytes(kept.image), bytes, "owned frame survives canvas release")
    }

    func testAppearanceZeroDotsSampleTheSameFixedSpatialField() throws {
        let r = try SpectrumFrameRenderer(width: 1920, height: 1080)
        var previous: SpectrumRenderedFrame?
        for side in SpectrumFrameRendererTests.sides {
            var s = style(side); s.startYMilli = 540_500; s.endYMilli = 540_500
            s.thicknessMilli = 16_000; s.red = 255; s.green = 0; s.blue = 0; s.alpha = 128
            s.outsideRGB = .init(red: 0, green: 0, blue: 255)
            let zero = [Float](repeating: 0, count: s.bands)
            let f = try XCTUnwrap(r.render(bands: zero, style: s))
            if let previous { same(f, previous) }; previous = f
            XCTAssertEqual(pixel(f, 288, 540), [0, 0, 128, 128], "dot center uses Inside without an amplitude floor")
            XCTAssertEqual(pixel(f, 288, 534), [16, 0, 127, 128], "6/400 spatial position, linear-light interpolation")
            XCTAssertEqual(pixel(f, 384, 540), [0, 0, 0, 0], "no connecting baseline is introduced")
            XCTAssertEqual(zero, [Float](repeating: 0, count: s.bands))
        }
    }

    /// SPECTRUM-HUE-DOT-FIX-01 (characterization, no renderer change): Hue interpolation only recolors existing
    /// coverage. Zero dots, tiny positive bars and normal bars cover exactly the same pixels with and without Hue,
    /// so baseline dots seen with Hue come from the geometry (valid-zero dots / genuine short bars), not the color field.
    func testHueSweepRecolorsWithoutChangingZeroOrLowAmplitudeCoverage() throws {
        let r = try SpectrumFrameRenderer(width: 1920, height: 1080)
        // band centres x = 192 + (i + 0.5) × 192; mirrored, 6 px thick, 400 px maximum height
        let v: [Float] = [0, 0.00001, 0.002, 0.01, 0.5, 0, 0.3, 0]
        for mode in SpectrumFrameRendererTests.modes {
            var s = style(.mirrored); s.mode = mode
            s.red = 255; s.green = 0; s.blue = 0; s.outsideRGB = .init(red: 0, green: 0, blue: 255)
            s.hueInterpolationDegrees = 0
            let plain = try XCTUnwrap(r.render(bands: v, style: s))
            s.hueInterpolationDegrees = 180
            let hue = try XCTUnwrap(r.render(bands: v, style: s))
            XCTAssertEqual(plain.drawRect, hue.drawRect, "\(mode)")
            let a = SpectrumFrameRendererTests.bytes(plain.image), b = SpectrumFrameRendererTests.bytes(hue.image)
            XCTAssertEqual(a.count, b.count)
            let alphaA = stride(from: 3, to: a.count, by: 4).map { a[$0] }, alphaB = stride(from: 3, to: b.count, by: 4).map { b[$0] }
            XCTAssertEqual(alphaA, alphaB, "\(mode): Hue never adds or removes coverage")
            XCTAssertNotEqual(a, b, "\(mode): Hue does change color")
            guard mode == .digital else { continue }
            XCTAssertEqual(pixel(hue, 288, 540)[3], 255, "valid zero band: approved dot (SPECTRUM-ZERO-01)")
            XCTAssertEqual(pixel(hue, 480, 542)[3], 0, "0.00001 × 400 px: no dot and no amplitude floor")
            XCTAssertGreaterThan(pixel(hue, 672, 540)[3], 0, "0.002 × 400 px = 0.8 px each side: genuine short bar stays visible")
            XCTAssertEqual(pixel(hue, 672, 536)[3], 0, "short bar keeps its real height")
            XCTAssertEqual(pixel(hue, 864, 537)[3], 255, "0.01 × 400 px = 4 px each side")
        }
        XCTAssertEqual(v, [0, 0.00001, 0.002, 0.01, 0.5, 0, 0.3, 0], "rendering never changes analysis data")
    }

    func testMaximumHeightZeroUsesInsideWithoutDivisionForBothModes() throws {
        let r = try SpectrumFrameRenderer(width: 1920, height: 1080)
        let input: [Float] = [0, 0.125, 0.25, 0.5, 0.75, 1, 0.5, 0]
        for mode in SpectrumFrameRendererTests.modes { for side in SpectrumFrameRendererTests.sides {
            var s = style(side); s.mode = mode; s.maxHeightMilli = 0
            s.red = 255; s.green = 0; s.blue = 0; s.alpha = 128
            let expected = try XCTUnwrap(r.render(bands: input, style: s))
            s.outsideRGB = .init(red: 0, green: 0, blue: 255)
            same(try XCTUnwrap(r.render(bands: input, style: s)), expected)
        } }
    }
}
