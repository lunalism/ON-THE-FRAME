import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation

public struct RenderOptions: Sendable {
    public var caption = true
    public var bars = true
    public var frameCode = true
    public init(caption: Bool = true, bars: Bool = true, frameCode: Bool = true) {
        self.caption = caption; self.bars = bars; self.frameCode = frameCode
    }
}

public struct FrameInfo: Sendable {
    public let frame: Int
    public let bands: [Float]
    public let barHeights: [Int]
    public let captionShown: Bool
}

public struct CaptionLayout {
    public let origin: CGPoint            // CG 좌표(아래-왼쪽 원점)의 기준선 시작점
    public let inkRectTopLeft: CGRect     // 글리프 경로 경계, 위쪽-왼쪽 원점
    public let fontPostScriptName: String
    public let runFonts: [String]
    public let glyphCount: Int
    public let missingGlyphs: Int         // glyph id 0(.notdef) 개수
}

/// 결정적 합성 함수: (TimelineState, 프레임 번호) → BGRA 픽셀.
/// 저장 상태는 불변(let, Sendable)이고, CGContext·CTLine·색 공간은 호출마다 새로 만들어
/// 스레드 간에 공유하지 않는다(Core Text 제약). 따라서 여러 스레드에서 동시에 호출해도 된다.
/// Sendable 적합성은 컴파일러가 확인한다(@unchecked 아님).
public final class FrameRenderer: Sendable {
    public let state: TimelineState
    public let spectrum: SpectrumCache

    public init(state: TimelineState, spectrum: SpectrumCache) throws {
        guard spectrum.sourceID == state.selected.source.id else {
            throw E1Error.render("spectrum cache source \(spectrum.sourceID.prefix(12)) != selected source \(state.selected.source.id.prefix(12))")
        }
        self.state = state; self.spectrum = spectrum
    }

    /// 프레임 n의 밴드 값. 선택 소스가 배치되지 않았거나 원본 끝을 넘으면 0.
    public func bands(forFrame n: Int) -> [Float] {
        if let s = state.selected.sourceTime(atTimeline: Spec.frameTime(n)), let b = spectrum.bands(atSourceTime: s) {
            return Array(b)
        }
        return [Float](repeating: 0, count: spectrum.params.bandCount)
    }

    public func captionVisible(frame n: Int) -> Bool {
        let t = Spec.frameTime(n)
        return t >= Spec.captionStart && t < Spec.captionEnd
    }

    static func makeLine() -> (CTLine, CTFont) {
        let font = CTFontCreateWithName(Spec.captionFontName as CFString, Spec.captionFontSize, nil)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: Spec.captionText, attributes: attrs))
        return (line, font)
    }

    public static func captionLayout() -> CaptionLayout {
        let (line, font) = makeLine()
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let origin = CGPoint(x: ((Double(Spec.width) - width) / 2).rounded(), y: Double(Spec.height - Spec.captionBaselineY))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let abs = ink.offsetBy(dx: origin.x, dy: origin.y)
        let topLeft = CGRect(x: abs.minX, y: Double(Spec.height) - abs.maxY, width: abs.width, height: abs.height)
        var runFonts: [String] = []
        var glyphs = 0, missing = 0
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if let f = attrs[kCTFontAttributeName as String] {
                runFonts.append(CTFontCopyPostScriptName(f as! CTFont) as String)
            }
            let c = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: c)
            CTRunGetGlyphs(run, CFRange(location: 0, length: c), &ids)
            glyphs += c
            missing += ids.filter { $0 == 0 }.count
        }
        return CaptionLayout(origin: origin, inkRectTopLeft: topLeft,
                             fontPostScriptName: CTFontCopyPostScriptName(font) as String,
                             runFonts: runFonts, glyphCount: glyphs, missingGlyphs: missing)
    }

    @discardableResult
    public func render(frame n: Int, into pb: CVPixelBuffer, options: RenderOptions = RenderOptions()) throws -> FrameInfo {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pb) == Spec.width, CVPixelBufferGetHeight(pb) == Spec.height else {
            throw E1Error.render("unexpected pixel buffer format/size")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: Spec.width, height: Spec.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw E1Error.render("CGContext creation failed") }
        return draw(frame: n, ctx: ctx, options: options)
    }

    func draw(frame n: Int, ctx: CGContext, options: RenderOptions) -> FrameInfo {
        let H = Spec.height
        ctx.setShouldAntialias(false)
        func fill(_ x: Int, _ yTop: Int, _ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8)) {
            ctx.setFillColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
            ctx.fill(CGRect(x: x, y: H - yTop - h, width: w, height: h))
        }
        // 배경 + 격자 (생성 배경)
        fill(0, 0, Spec.width, H, Spec.bgColor)
        for x in stride(from: Spec.gridPitch, to: Spec.width, by: Spec.gridPitch) { fill(x, 0, Spec.gridLine, H, Spec.gridColor) }
        for y in stride(from: Spec.gridPitch, to: H, by: Spec.gridPitch) { fill(0, y, Spec.width, Spec.gridLine, Spec.gridColor) }
        // 프레임 번호 코드 (16비트, MSB 먼저)
        if options.frameCode {
            for b in 0..<Spec.codeBits {
                let on = (n >> (Spec.codeBits - 1 - b)) & 1 == 1
                fill(Spec.codeX + b * Spec.codePitch, Spec.codeY, Spec.codeCell, Spec.codeCell, on ? Spec.codeOn : Spec.codeOff)
            }
        }
        // 스펙트럼 막대
        let bands = bands(forFrame: n)
        let heights = bands.map(Spec.barHeight(forValue:))
        if options.bars {
            for (k, h) in heights.enumerated() where h > 0 {
                fill(Spec.barLeft(k), Spec.barBaselineY - h, Spec.barWidth, h, Spec.barColor)
            }
        }
        // 자막
        let shown = options.caption && captionVisible(frame: n)
        if shown {
            let (line, _) = Self.makeLine()
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(false)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: ((Double(Spec.width) - width) / 2).rounded(), y: Double(H - Spec.captionBaselineY))
            CTLineDraw(line, ctx)
        }
        return FrameInfo(frame: n, bands: bands, barHeights: heights, captionShown: shown)
    }

    public static func makeBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let st = CVPixelBufferCreate(nil, Spec.width, Spec.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let b = pb else { throw E1Error.render("CVPixelBufferCreate \(st)") }
        return b
    }
}

/// 픽셀 측정(렌더 결과와 디코딩 결과 모두에 사용). 구현과 독립된 측정 코드다.
public struct FrameMetrics: Sendable {
    public let code: Int
    public let captionPixels: Int
    public let barHeights: [Int]

    /// rect: 자막 측정 영역(위쪽-왼쪽 원점). 막대 높이는 기준선에서 위로 연속한 막대 색 픽셀 수.
    public static func measure(_ pb: CVPixelBuffer, captionRect: CGRect) -> FrameMetrics {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        func px(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let p = base + y * bpr + x * 4
            return (Int(p[2]), Int(p[1]), Int(p[0]))
        }
        var code = 0
        for b in 0..<Spec.codeBits {
            let c = px(Spec.codeX + b * Spec.codePitch + Spec.codeCell / 2, Spec.codeY + Spec.codeCell / 2)
            code = (code << 1) | ((c.r + c.g + c.b) / 3 > 128 ? 1 : 0)
        }
        var cap = 0
        let r = captionRect.integral
        for y in max(0, Int(r.minY))..<min(Spec.height, Int(r.maxY)) {
            for x in max(0, Int(r.minX))..<min(Spec.width, Int(r.maxX)) {
                let c = px(x, y)
                if min(c.r, c.g, c.b) > 200 { cap += 1 }
            }
        }
        var heights: [Int] = []
        for k in 0..<Spec.bandCount {
            let x = Spec.barLeft(k) + Spec.barWidth / 2
            var h = 0
            var y = Spec.barBaselineY - 1
            while y >= Spec.barBaselineY - Spec.barMaxHeight - 2 {
                let c = px(x, y)
                if c.g > 120 && c.b > 150 && c.r < 160 { h += 1; y -= 1 } else { break }
            }
            heights.append(h)
        }
        return FrameMetrics(code: code, captionPixels: cap, barHeights: heights)
    }
}
