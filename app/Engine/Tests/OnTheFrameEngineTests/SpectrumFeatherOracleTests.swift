import CoreGraphics
import XCTest
@testable import OnTheFrameEngine

/// DIGITAL-FEATHER-OPT-A01 test-only oracle: the pre-optimization scalar `SpectrumInsideEdgeFeather.apply`
/// (original file SHA-256 339b94fd6c81b6e70955a4c481580e50ed77d8d3517afaa3b829e5dc8cc36c74), copied mechanically
/// with only its `#if DEBUG` timing blocks removed. Those blocks never write pixels, distances or the return value.
private enum SpectrumInsideEdgeFeatherReference {
    static func apply(percent: Int, bands: [Float], style: SpectrumStyle, canvas: CGSize,
                      bounds: CGRect, into output: CGContext) throws -> Int {
        let strength = Float(percent) / 100
        let radius = strength * Float(min(style.thickness / 2, 4) * canvas.height / 1080)
        let halo = Int(radius.rounded(.up)) + 1
        // Draw the *unclipped* geometry beyond every canvas edge. Clipping before measuring
        // distance would turn the canvas border into a false contour of a crossing stroke.
        let region = bounds.insetBy(dx: -CGFloat(halo), dy: -CGFloat(halo))
        let width = Int(region.width), height = Int(region.height)
        let rowBytes = ((width + 63) / 64) * 64
        guard let mask = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let maskData = mask.data else {
            throw SpectrumRenderError.invalidCanvas("feather coverage mask")
        }
        memset(maskData, 0, rowBytes * height)
        mask.translateBy(x: -region.minX, y: region.maxY)
        mask.scaleBy(x: 1, y: -1)
        var opaque = style
        opaque.red = 1
        opaque.green = 1
        opaque.blue = 1
        opaque.alpha = 1
        SpectrumGeometry.draw(bands, style: opaque, canvas: canvas, into: mask)

        let coverage = maskData.assumingMemoryBound(to: UInt8.self)
        let pixels = output.data!.assumingMemoryBound(to: UInt8.self)
        let stripHeight = 64
        let pitch = width + 2  // one sentinel on each side
        let scratchRows = min(height, stripHeight + 2 * halo) + 2
        let distance = UnsafeMutableBufferPointer<Float>.allocate(capacity: pitch * scratchRows)
        distance.initialize(repeating: radius)
        defer { distance.deallocate() }
        let first = distance.baseAddress!
        let diagonal = Float(2).squareRoot()

        withExtendedLifetime(mask) {
            for start in stride(from: 0, to: Int(bounds.height), by: stripHeight) {
                let count = min(stripHeight, Int(bounds.height) - start)
                // region has a halo on all sides; these rows include both neighboring strips.
                let rows = count + 2 * halo
                first.update(repeating: radius, count: pitch)
                (first + (rows + 1) * pitch).update(repeating: radius, count: pitch)
                for y in 0..<rows {
                    let src = coverage + (start + y) * rowBytes
                    let line = first + (y + 1) * pitch + 1
                    let prev = line - pitch
                    for x in 0..<width {
                        // A partially covered pixel seeds a subpixel edge; a hard axis-aligned
                        // step lies halfway between its last empty and first full pixel centers.
                        if src[x] < 255 {
                            line[x] = Float(src[x]) / 255 - 0.5
                        } else {
                            let axial = min(line[x - 1], prev[x]) + 1
                            let corner = min(prev[x - 1], prev[x + 1]) + diagonal
                            line[x] = min(radius, axial, corner)
                        }
                    }
                }
                // The reverse sweep completes an eight-neighbor approximation to Euclidean
                // distance. No point farther away than radius affects the candidate curve.
                for y in stride(from: rows - 1, through: halo, by: -1) {
                    let line = first + (y + 1) * pitch + 1
                    let next = line + pitch
                    for x in stride(from: width - 1, through: 0, by: -1) where line[x] > 0.5 {
                        let axial = min(line[x + 1], next[x]) + 1
                        let corner = min(next[x - 1], next[x + 1]) + diagonal
                        line[x] = min(line[x], axial, corner)
                    }
                    guard y < halo + count else { continue }
                    let outputY = Int(region.minY) + start + y
                    let row = pixels + outputY * output.bytesPerRow + Int(bounds.minX) * 4
                    for x in 0..<Int(bounds.width) {
                        let pixel = row + x * 4
                        let d = line[x + halo]
                        guard pixel[3] != 0, d < radius else { continue }
                        let t = max(0, d / radius)
                        let smooth = t * t * (3 - 2 * t)
                        let k = 1 - strength * 0.5 * (1 - smooth)
                        // Apply the same factor once to all four already-premultiplied bytes.
                        for component in 0..<4 {
                            pixel[component] = UInt8((Float(pixel[component]) * k).rounded())
                        }
                    }
                }
            }
        }
        return rowBytes * height + distance.count * MemoryLayout<Float>.stride
    }
}

/// Byte-for-byte equivalence of the optimized inward feather against the reference oracle.
/// Compares the whole canvas, the cropped image, drawRect, bounds and the reported scratch payload.
final class SpectrumFeatherOracleTests: XCTestCase {
    private typealias Style = SpectrumStyle

    private static func style(_ mode: Style.Mode = .digital, _ sides: Style.Sides = .mirrored,
                              start: CGPoint = CGPoint(x: 192, y: 540), end: CGPoint = CGPoint(x: 1728, y: 540),
                              maxHeight: Double = 220, thickness: Double = 3, alpha: Double = 1,
                              rgb: (Double, Double, Double) = (1, 1, 1), outside: (Double, Double, Double)? = nil,
                              hue: Int = 0) -> Style {
        Style(start: start, end: end, maxHeight: maxHeight, thickness: thickness, mode: mode, sides: sides,
              red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha,
              outsideRed: outside?.0, outsideGreen: outside?.1, outsideBlue: outside?.2, hueInterpolationDegrees: hue)
    }

    /// Whole-canvas BGRA bytes (top-left origin, row bytes = width * 4) via the canvas' own copy.
    private static func bytes(of canvas: SpectrumCanvas) throws -> [UInt8] {
        SpectrumFrameRendererTests.bytes(try canvas.ownedImage(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)))
    }

    private static func context(_ bytes: [UInt8], width: Int, height: Int) throws -> CGContext {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        XCTAssertEqual(ctx.bytesPerRow, width * 4)
        bytes.withUnsafeBytes { memcpy(ctx.data!, $0.baseAddress!, bytes.count) }
        return ctx
    }

    private static func contextBytes(_ ctx: CGContext) -> [UInt8] {
        [UInt8](UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * ctx.height))
    }

    /// Renders through the production canvas at each percent and compares it with
    /// (production 0% canvas state) + reference feather + the production crop.
    private func assertOracle(_ v: [Float], _ s: Style, width w: Int, height h: Int, percents: [Int] = [1, 50, 100],
                              _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let size = CGSize(width: w, height: h)
        let base = try SpectrumCanvas(width: w, height: h), optimized = try SpectrumCanvas(width: w, height: h)
        let b = SpectrumGeometry.bounds(v, style: s, canvas: size)
        let baseRaster = try base.render(v, style: s, experimentalSoftnessPercent: 0)
        var start: [UInt8]? = nil
        if baseRaster != nil { start = try Self.bytes(of: base) }
        for p in percents {
            let r = try optimized.render(v, style: s, experimentalSoftnessPercent: p)
            XCTAssertEqual(r == nil, baseRaster == nil, "\(label) p\(p) nil", file: file, line: line)
            guard let r, let start else { continue }
            let ref = try Self.context(start, width: w, height: h)
            var scratch = 0
            if p > 0, s.alpha > 0 {
                scratch = try SpectrumInsideEdgeFeatherReference.apply(percent: p, bands: v, style: s, canvas: size, bounds: b, into: ref)
            }
            XCTAssertEqual(optimized.experimentalFeatherScratchPeakBytes, scratch, "\(label) p\(p) scratch", file: file, line: line)
            let got = try Self.bytes(of: optimized), want = Self.contextBytes(ref)
            if got != want {
                let first = zip(got, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                XCTFail("\(label) p\(p): \(zip(got, want).filter { $0 != $1 }.count) bytes differ, first at pixel \(first / 4) (x \(first / 4 % w), y \(first / 4 / w))",
                        file: file, line: line)
            }
            let rows = Int(b.minY)..<Int(b.maxY)
            let (img, box) = SubtitleRenderer.tightCrop(ref, rows: rows)
            let draw = box.isNull ? CGRect(x: 0, y: rows.lowerBound, width: w, height: rows.count) : box.offsetBy(dx: 0, dy: CGFloat(rows.lowerBound))
            XCTAssertEqual(r.bounds, b, "\(label) p\(p) bounds", file: file, line: line)
            XCTAssertEqual(r.drawRect, draw, "\(label) p\(p) drawRect", file: file, line: line)
            XCTAssertEqual([r.image.width, r.image.height], [img.width, img.height], "\(label) p\(p) size", file: file, line: line)
            XCTAssertEqual(SpectrumFrameRendererTests.bytes(r.image), SpectrumFrameRendererTests.bytes(img), "\(label) p\(p) image", file: file, line: line)
        }
    }

    private static let bandSets: [(String, [Float])] = [
        ("dots", [Float](repeating: 0, count: 16)),
        ("near-silent", (0..<16).map { Float($0 % 4) * 0.0025 }),
        ("seeded16", SpectrumFrameRendererTests.values(16, seed: 7)),
        ("seeded64", SpectrumFrameRendererTests.values(64, seed: 11)),
        ("narrow256", SpectrumFrameRendererTests.values(256, seed: 13)),
        ("wide1", [0.9]),
        ("wide3", [0.2, 1, 0]),
    ]

    func testSmallCanvasesAcrossSidesThicknessBandsAndAlpha() throws {
        for (w, h) in [(64, 36), (384, 216)] {
            for sides in [Style.Sides.above, .below, .mirrored] {
                for thickness in [0.5, 1, 2.5, 7.75, 16, 33.3, 64] {
                    for (name, v) in Self.bandSets {
                        for alpha in [1.0 / 255, 0.5, 232.0 / 255, 1] {
                            let s = Self.style(.digital, sides, maxHeight: 200, thickness: thickness, alpha: alpha)
                            try assertOracle(v, s, width: w, height: h, "\(w)x\(h) \(sides) th\(thickness) \(name) a\(alpha)")
                        }
                    }
                }
            }
        }
    }

    /// Colored, gradient and hue-swept outputs differ from the white opaque mask (mask/output raster difference).
    func testColoredGradientAndHueOutputsDifferFromMask() throws {
        let v = SpectrumFrameRendererTests.values(64, seed: 23)
        for sides in [Style.Sides.above, .below, .mirrored] {
            for (rgb, outside, hue) in [((0.87, 0.2, 0.1), nil, 0), ((0.87, 0.2, 0.1), (0.02, 0.24, 0.94), 0), ((1.0, 0.0, 0.0), (0.0, 0.0, 1.0), 180)] as [((Double, Double, Double), (Double, Double, Double)?, Int)] {
                let s = Self.style(.digital, sides, maxHeight: 180, thickness: 5, alpha: 148.0 / 255, rgb: rgb, outside: outside, hue: hue)
                try assertOracle(v, s, width: 384, height: 216, percents: [0, 1, 50, 100], "color \(sides) hue\(hue)")
            }
        }
    }

    /// Geometry crossing every canvas edge, a baseline at the top and bottom edge, and a tilted baseline.
    func testCanvasEdgesClippingAndTiltedGeometry() throws {
        let v = SpectrumFrameRendererTests.values(32, seed: 31)
        let cases: [(String, CGPoint, CGPoint)] = [
            ("beyond-left-right", CGPoint(x: -400, y: 540), CGPoint(x: 2400, y: 540)),
            ("top-edge", CGPoint(x: 100, y: 3), CGPoint(x: 1800, y: 3)),
            ("bottom-edge", CGPoint(x: 100, y: 1078), CGPoint(x: 1800, y: 1078)),
            ("tilted", CGPoint(x: -60, y: 75), CGPoint(x: 1920, y: 1000)),
            ("vertical", CGPoint(x: 960, y: -100), CGPoint(x: 960, y: 1200)),
        ]
        for (name, a, b) in cases {
            for sides in [Style.Sides.above, .below, .mirrored] {
                for thickness in [0.5, 3, 64] {
                    let s = Self.style(.digital, sides, start: a, end: b, maxHeight: 400, thickness: thickness, alpha: 0.9)
                    try assertOracle(v, s, width: 384, height: 216, "\(name) \(sides) th\(thickness)")
                }
            }
        }
    }

    /// Representative FHD30 / 64-band Preview geometry (the 50% pilot fixture shape) and the largest radius.
    func testRepresentativeFHD64BandGeometry() throws {
        let reaction: Float = 1.5
        let v = SpectrumFrameRendererTests.values(64, seed: 41).map { min(1, $0 * reaction) }
        let fixture = Self.style(.digital, .mirrored, maxHeight: 220, thickness: 3, alpha: 232.0 / 255,
                                 rgb: (1.0, 0.25, 0.1), outside: (0.1, 0.4, 1.0), hue: 180)
        try assertOracle(v, fixture, width: 1920, height: 1080, percents: [0, 1, 50, 100], "FHD fixture")
        try assertOracle(v, Self.style(.digital, .mirrored, maxHeight: 220, thickness: 64, alpha: 1), width: 1920, height: 1080,
                         percents: [50, 100], "FHD th64")
        try assertOracle([Float](repeating: 0, count: 64), fixture, width: 1920, height: 1080, percents: [50], "FHD dots")
    }

    /// Analog never takes the Preview pilot, but the renderer-level feather stays exact for it too.
    func testAnalogRendererLevelEquivalence() throws {
        let v = SpectrumFrameRendererTests.values(16, seed: 53)
        for sides in [Style.Sides.above, .below, .mirrored] {
            try assertOracle(v, Self.style(.analog, sides, maxHeight: 150, thickness: 6, alpha: 0.75), width: 384, height: 216,
                             percents: [0, 1, 50, 100], "analog \(sides)")
        }
    }

    func testZeroAlphaAndZeroSoftnessSkipTheFeather() throws {
        let v = SpectrumFrameRendererTests.values(16, seed: 59)
        try assertOracle(v, Self.style(alpha: 0), width: 384, height: 216, percents: [0, 50, 100], "alpha 0")
        try assertOracle(v, Self.style(alpha: 1), width: 384, height: 216, percents: [0], "softness 0")
    }

    /// Output alpha deliberately disagrees with mask coverage: nonzero alpha where the mask is empty,
    /// zero alpha inside covered geometry, and arbitrary premultiplied colors. Calls apply() directly.
    func testSyntheticOutputAlphaIndependentOfMaskCoverage() throws {
        let (w, h) = (192, 108), size = CGSize(width: 192, height: 108)
        let v = SpectrumFrameRendererTests.values(24, seed: 61)
        var g: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 { g = g &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: g >> 33) }
        let shapes: [(Style.Sides, Double)] = [(.mirrored, 6), (.above, 0.5), (.below, 64)]
        for (sides, thickness) in shapes {
            let s = Self.style(.digital, sides, start: CGPoint(x: 0, y: 540), end: CGPoint(x: 1920, y: 540), maxHeight: 300, thickness: thickness)
            let b = SpectrumGeometry.bounds(v, style: s, canvas: size)
            var start = [UInt8](repeating: 0, count: w * h * 4)
            for i in stride(from: 0, to: start.count, by: 4) {
                let a = next() % 3 == 0 ? 0 : next()
                start[i + 3] = a
                for c in 0..<3 { start[i + c] = a == 0 ? 0 : UInt8(UInt16(next()) % (UInt16(a) + 1)) }
            }
            for p in [1, 50, 100] {
                let optimized = try Self.context(start, width: w, height: h), reference = try Self.context(start, width: w, height: h)
                #if DEBUG
                let feather = SpectrumInsideEdgeFeather(timing: nil)
                #else
                let feather = SpectrumInsideEdgeFeather()
                #endif
                let got = try feather.apply(percent: p, bands: v, style: s, canvas: size, bounds: b, into: optimized)
                let want = try SpectrumInsideEdgeFeatherReference.apply(percent: p, bands: v, style: s, canvas: size, bounds: b, into: reference)
                XCTAssertEqual(got, want, "\(sides) th\(thickness) p\(p) scratch")
                XCTAssertEqual(Self.contextBytes(optimized), Self.contextBytes(reference), "\(sides) th\(thickness) p\(p) bytes")
            }
        }
    }
}
