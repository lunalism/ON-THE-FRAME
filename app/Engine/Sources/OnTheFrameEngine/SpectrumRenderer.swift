import CoreGraphics
import Foundation
import os

// 스펙트럼 그리기(2026-10-25, docs/SPECTRUM-DESIGN.md §13) — 엔진 안(package) API. 앱 프리뷰·내보내기·정보 패널·저장에 연결하지 않았다.
// 시제품 ProtoSpectrumRenderer(시험 대상)의 기하·그리기 명령을 그대로 옮겼다(같은 입력 → 같은 바이트, 시험으로 확인).
// FX-02B: 두 색은 기준선→Maximum Height의 선형광 RGB 공간 gradient. Hue·Softness는 구현하지 않는다.
// 그리기는 다시 쓰는 전체 캔버스 문맥에 하고(프레임마다 0으로 비움), 기하로 계산한 범위의 행만 자막과 같은 tightCrop으로 자른다.
// 범위만 그린 작은 문맥은 전체 캔버스 그림과 바이트가 달라(§12, 가장자리 최대 1/255) 쓰지 않는다.

/// 모양(1920×1080 기준 단위 — 캔버스에 비례: x는 너비/1920, y·높이·두께는 높이/1080)
package struct SpectrumStyle: Sendable, Equatable {
    package enum Mode: Sendable, Equatable { case digital, analog }
    package enum Sides: Sendable, Equatable { case above, mirrored, below }
    package var start: CGPoint, end: CGPoint
    package var maxHeight: Double, thickness: Double
    package var mode: Mode, sides: Sides
    /// Inside와 공통 alpha(sRGB 0~1, 미리 곱하지 않음). nil Outside는 현재 Inside를 따른다.
    package var red: Double, green: Double, blue: Double, alpha: Double
    package var outsideRed: Double?, outsideGreen: Double?, outsideBlue: Double?
    package var resolvedOutsideRed: Double { outsideRed ?? red }
    package var resolvedOutsideGreen: Double { outsideGreen ?? green }
    package var resolvedOutsideBlue: Double { outsideBlue ?? blue }
    package var hasColorGradient: Bool {
        red != resolvedOutsideRed || green != resolvedOutsideGreen || blue != resolvedOutsideBlue
    }
    package init(start: CGPoint, end: CGPoint, maxHeight: Double, thickness: Double, mode: Mode, sides: Sides,
                 red: Double = 1, green: Double = 1, blue: Double = 1, alpha: Double = 1,
                 outsideRed: Double? = nil, outsideGreen: Double? = nil, outsideBlue: Double? = nil) {
        self.start = start; self.end = end; self.maxHeight = maxHeight; self.thickness = thickness; self.mode = mode; self.sides = sides
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        self.outsideRed = outsideRed; self.outsideGreen = outsideGreen; self.outsideBlue = outsideBlue
    }
    /// 쓸 수 있는지(유한한 좌표 ±10000, 시작 ≠ 끝, 높이 0~1080, 두께 0.5~64, 색 0~1)
    package func validationError() -> String? {
        let xs = [start.x, start.y, end.x, end.y].map(Double.init)
        guard xs.allSatisfy({ $0.isFinite && abs($0) <= 10_000 }) else { return "points" }
        guard hypot(end.x - start.x, end.y - start.y) >= 1 else { return "start = end" }
        guard maxHeight.isFinite, (0...1080).contains(maxHeight) else { return "maxHeight \(maxHeight)" }
        guard thickness.isFinite, (0.5...64).contains(thickness) else { return "thickness \(thickness)" }
        guard [red, green, blue, alpha, resolvedOutsideRed, resolvedOutsideGreen, resolvedOutsideBlue]
            .allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return "color" }
        return nil
    }
}

/// 그리기 입력 오류(2026-10-26 SP-1A 3A-1부터 public — 공개 그리기 입구 SpectrumFrameRenderer가 던진다)
public enum SpectrumRenderError: Error, Equatable {
    case invalidStyle(String), invalidValues(String), invalidCanvas(String)
}

package enum SpectrumGeometry {
    /// 밴드 i의 기준선 위 자리(캔버스 픽셀, 위 왼쪽 원점) = 기준선을 밴드 수로 나눈 칸의 가운데, 위쪽 단위 벡터(기준선에 수직, 가로 기준선이면 (0, −1)), 세로 배율
    package static func points(_ s: SpectrumStyle, bands: Int, canvas: CGSize) -> (points: [CGPoint], up: CGVector, scaleY: CGFloat) {
        let sx = canvas.width / 1920, sy = canvas.height / 1080
        let a = CGPoint(x: s.start.x * sx, y: s.start.y * sy), b = CGPoint(x: s.end.x * sx, y: s.end.y * sy)
        let dx = b.x - a.x, dy = b.y - a.y, len = max(1e-6, hypot(dx, dy))
        let up = CGVector(dx: dy / len, dy: -dx / len)
        let pts = (0..<bands).map { i -> CGPoint in let t = (CGFloat(i) + 0.5) / CGFloat(bands); return CGPoint(x: a.x + dx * t, y: a.y + dy * t) }
        return (pts, up, sy)
    }
    /// 칠할 범위(막대·선 끝점 또는 Digital 0높이 원 ± 두께 절반 + 앤티에일리어싱 1 px, 캔버스 안, 정수).
    package static func bounds(_ v: [Float], style s: SpectrumStyle, canvas: CGSize) -> CGRect {
        let g = points(s, bands: v.count, canvas: canvas)
        let th = CGFloat(s.thickness) * g.scaleY
        var r = CGRect.null
        for (p, f) in zip(g.points, v) {
            let hh = CGFloat(f) * CGFloat(s.maxHeight) * g.scaleY
            let up = s.sides == .below ? 0 : hh, down = s.sides == .above ? 0 : hh
            for d in [up, -down] { r = r.union(CGRect(x: p.x + g.up.dx * d, y: p.y + g.up.dy * d, width: 0, height: 0)) }
        }
        guard !r.isNull else { return .null }
        return r.insetBy(dx: -(th / 2 + 1), dy: -(th / 2 + 1)).integral.intersection(CGRect(origin: .zero, size: canvas))
    }
    /// 위 왼쪽 원점으로 뒤집은 문맥에 그린다(Digital: 양수는 맞대 끝 막대, 0높이는 기준점 중심의 두께 직경 원).
    /// Analog는 기존 둥근 이음·끝 꺾은선(거울이면 위·아래 두 줄)을 유지한다.
    static func draw(_ v: [Float], style s: SpectrumStyle, canvas: CGSize, into ctx: CGContext) {
        let g = points(s, bands: v.count, canvas: canvas)
        let color = CGColor(srgbRed: CGFloat(s.red), green: CGFloat(s.green), blue: CGFloat(s.blue), alpha: CGFloat(s.alpha))
        let th = CGFloat(s.thickness) * g.scaleY
        func pt(_ p: CGPoint, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + g.up.dx * d, y: p.y + g.up.dy * d) }
        let hs = v.map { CGFloat($0) * CGFloat(s.maxHeight) * g.scaleY }
        switch s.mode {
        case .digital:
            ctx.setStrokeColor(color); ctx.setLineWidth(th); ctx.setLineCap(.butt)
            for (p, hh) in zip(g.points, hs) where hh > 0 {
                let top = s.sides == .below ? 0 : hh, bottom = s.sides == .above ? 0 : hh
                ctx.move(to: pt(p, top)); ctx.addLine(to: pt(p, -bottom))
            }
            ctx.strokePath()
            // Valid collapsed heights (including strength/maximum height 0) stay
            // locatable without changing analysis values or positive bar geometry.
            // Separate ellipses never connect adjacent bands into a baseline.
            ctx.setFillColor(color)
            for (p, hh) in zip(g.points, hs) where hh == 0 {
                ctx.addEllipse(in: CGRect(x: p.x - th / 2, y: p.y - th / 2, width: th, height: th))
            }
            ctx.fillPath()
        case .analog:
            ctx.setStrokeColor(color); ctx.setLineWidth(th); ctx.setLineJoin(.round); ctx.setLineCap(.round)
            for sign in (s.sides == .mirrored ? [1.0, -1.0] : (s.sides == .above ? [1.0] : [-1.0])) as [CGFloat] {
                for (i, (p, hh)) in zip(g.points, hs).enumerated() { if i == 0 { ctx.move(to: pt(p, sign * hh)) } else { ctx.addLine(to: pt(p, sign * hh)) } }
            }
            ctx.strokePath()
        }
    }
}

/// Recolor existing coverage in place; the field is independent of each band's height.
/// Common alpha is already present in the white mask and is not applied a second time.
private enum SpectrumColorField {
    static func linear(_ s: Double) -> Double {
        s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    static func sRGB(_ value: Double) -> Double {
        let v = min(1, max(0, value))
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    static func apply(style s: SpectrumStyle, canvas: CGSize, bounds: CGRect, into ctx: CGContext) {
        let g = SpectrumGeometry.points(s, bands: 1, canvas: canvas)
        let a = CGPoint(x: s.start.x * canvas.width / 1920, y: s.start.y * canvas.height / 1080)
        let height = CGFloat(s.maxHeight) * g.scaleY
        let inside = (linear(s.red), linear(s.green), linear(s.blue))
        let outside = (linear(s.resolvedOutsideRed), linear(s.resolvedOutsideGreen), linear(s.resolvedOutsideBlue))
        func color(_ distance: CGFloat) -> (Double, Double, Double) {
            let t = height > 0 ? Double(min(1, max(0, abs(distance) / height))) : 0
            return (sRGB(inside.0 + (outside.0 - inside.0) * t),
                    sRGB(inside.1 + (outside.1 - inside.1) * t),
                    sRGB(inside.2 + (outside.2 - inside.2) * t))
        }
        let x0 = Int(bounds.minX), x1 = Int(bounds.maxX)
        let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            let row = pixels + y * ctx.bytesPerRow
            let distance = (CGFloat(x0) + 0.5 - a.x) * g.up.dx + (CGFloat(y) + 0.5 - a.y) * g.up.dy
            // Horizontal baselines share a color across a row; avoid per-pixel powers.
            let rowColor = g.up.dx == 0 ? color(distance) : nil
            for x in x0..<x1 {
                let pixel = row + x * 4, alpha = pixel[3]
                guard alpha != 0 else { pixel[0] = 0; pixel[1] = 0; pixel[2] = 0; continue }
                let c = rowColor ?? color(distance + CGFloat(x - x0) * g.up.dx)
                func premultiplied(_ value: Double) -> UInt8 {
                    UInt8(min(Int(alpha), max(0, Int((value * Double(alpha)).rounded()))))
                }
                pixel[0] = premultiplied(c.2); pixel[1] = premultiplied(c.1); pixel[2] = premultiplied(c.0)
            }
        }
    }
}

/// 한 프레임의 칠한 부분(자막 발자국과 같은 모양: 미리 곱한 sRGB BGRA, 칠한 곳만 16 px 단위로 자름)
package struct SpectrumFrameRaster {
    package let image: CGImage
    /// 캔버스 좌표(위 왼쪽 원점)에서 image를 놓을 사각형, 미리 계산한 칠할 범위
    package let drawRect: CGRect, bounds: CGRect, canvas: CGSize
    /// 4:2:0 합성(SubtitleFootprint)에 넘길 래스터
    package var subtitleRaster: SubtitleRaster {
        SubtitleRaster(image: image, rect: CGRect(origin: .zero, size: canvas), fontUsed: "", missingFont: false, fallbackFonts: [],
                       lines: 0, textBounds: .zero, failed: false, clipped: false, hitRect: .zero, drawRect: drawRect)
    }
}

/// 다시 쓰는 전체 캔버스(한 번 할당, 크기 16~3840 × 16~2160). 한 작업(예: 한 내보내기의 영상 큐)에서만 쓴다 — 스레드 안전하지 않다.
package final class SpectrumCanvas {
    package let width: Int, height: Int
    private let ctx: CGContext
    private static let live = OSAllocatedUnfairLock(initialState: 0)
    /// 살아 있는 캔버스 수(취소·실패 뒤 놓였는지 시험용)
    package static var liveCount: Int { live.withLock { $0 } }
    package init(width: Int, height: Int) throws {
        guard (16...3840).contains(width), (16...2160).contains(height) else { throw SpectrumRenderError.invalidCanvas("\(width)x\(height)") }
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), c.data != nil else {
            throw SpectrumRenderError.invalidCanvas("allocation \(width)x\(height)")
        }
        c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
        self.width = width; self.height = height; ctx = c
        Self.live.withLock { $0 += 1 }
    }
    deinit { Self.live.withLock { $0 -= 1 } }
    package var allocatedBytes: Int { width * height * 4 }

    /// 그 밴드 값(0~1, 1~1024개)을 그려 칠한 부분만 자른 래스터. 칠한 곳이 없으면 nil(캔버스는 비어 있음).
    package func render(_ v: [Float], style s: SpectrumStyle) throws -> SpectrumFrameRaster? {
        if let e = s.validationError() { throw SpectrumRenderError.invalidStyle(e) }
        guard (1...1024).contains(v.count), v.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw SpectrumRenderError.invalidValues("count \(v.count) or value out of 0…1") }
        memset(ctx.data!, 0, allocatedBytes)
        let canvas = CGSize(width: width, height: height)
        let b = SpectrumGeometry.bounds(v, style: s, canvas: canvas)
        guard !b.isNull, b.height > 0, b.width > 0 else { return nil }
        if s.hasColorGradient {
            var mask = s; mask.red = 1; mask.green = 1; mask.blue = 1
            SpectrumGeometry.draw(v, style: mask, canvas: canvas, into: ctx)
            SpectrumColorField.apply(style: s, canvas: canvas, bounds: b, into: ctx)
        } else {
            // Exact legacy path, including AA, overlapping primitives and common alpha.
            SpectrumGeometry.draw(v, style: s, canvas: canvas, into: ctx)
        }
        let rows = Int(b.minY)..<Int(b.maxY)
        let (img, box) = SubtitleRenderer.tightCrop(ctx, rows: rows)
        let draw = box.isNull ? CGRect(x: 0, y: rows.lowerBound, width: width, height: rows.count) : box.offsetBy(dx: 0, dy: CGFloat(rows.lowerBound))
        return SpectrumFrameRaster(image: img, drawRect: draw, bounds: b, canvas: canvas)
    }
    /// 마지막으로 그린 캔버스의 화소(위 왼쪽 원점, 미리 곱한 BGRA 32비트) — 시험·진단용
    package func pixel(x: Int, y: Int) -> UInt32 {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        return ctx.data!.assumingMemoryBound(to: UInt32.self)[y * width + x]
    }
    /// 마지막으로 그린 캔버스의 r 부분(정수 화소, 캔버스 안)을 새로 할당한 버퍼에 복사한 이미지(SP-1A 3A-1 공개 입구용 — SpectrumFrameRenderer.ownedCopy)
    func ownedImage(_ r: CGRect) throws -> CGImage {
        guard r.integral == r, r.width >= 1, r.height >= 1, CGRect(x: 0, y: 0, width: width, height: height).contains(r) else {
            throw SpectrumRenderError.invalidCanvas("copy rect \(r)")
        }
        return try withExtendedLifetime(ctx) { try SpectrumFrameRenderer.ownedCopy(UnsafeRawPointer(ctx.data!), bytesPerRow: ctx.bytesPerRow, rect: r) }
    }
    /// 마지막으로 그린 캔버스에서 r 밖에 칠한 화소 수(전체 훑기 — 시험·진단용)
    package func paintedPixels(outside r: CGRect) -> Int {
        let px = ctx.data!.assumingMemoryBound(to: UInt32.self)
        var n = 0
        for y in 0..<height { for x in 0..<width where px[y * width + x] != 0 && !r.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { n += 1 } }
        return n
    }
}

// MARK: 공개 그리기 입구(2026-10-26, SP-1A 3A-1 — docs/SPECTRUM-DESIGN.md §15.12)
// 앱(프리뷰)이 스펙트럼 한 프레임을 그려 받는 가장 작은 public 입구. 그리기는 위 SpectrumCanvas.render를 그대로 쓴다(따로 그리는 코드 없음).
// 모양은 저장 모양 SpectrumItemStyle(public)을 받아 안에서 renderStyle(package)로 바꾼다. 캔버스·SpectrumStyle·SpectrumGeometry는 package 그대로다.

/// 그린 한 프레임(불변). 화소는 이 값만 가진 버퍼에 복사되어 있어 뒤의 그리기가 바꾸지 못한다.
/// - image: 미리 곱한 sRGB 8비트(premultipliedFirst, 메모리 B·G·R·A, 행 바이트 = 폭 × 4). 보통 칠한 부분만 16 px 단위로 자른 것이고
///   (내부 그리기와 같은 바이트), 자른 비트맵을 얻지 못한 경우는 내부 그림과 같은 전체 폭 행 띠다. 화소는 캔버스에서 drawRect 부분을 복사한 것.
/// - drawRect: 캔버스 화소 좌표(위 왼쪽 원점)에서 image를 놓을 사각형. 그 밖의 캔버스는 모두 투명이다.
public struct SpectrumRenderedFrame: @unchecked Sendable {   // CGImage는 불변이고 그 버퍼를 다른 곳에서 쓰지 않는다(아래 ownedCopy)
    public let image: CGImage
    public let drawRect: CGRect
    public let canvasWidth: Int, canvasHeight: Int
}

/// 스펙트럼 프레임 그리기(캔버스 한 번 할당, 크기 16~3840 × 16~2160). 한 작업에서만 쓴다 — 스레드 안전하지 않다(SpectrumCanvas와 같음).
/// 돌려준 SpectrumRenderedFrame은 그 뒤로 이 그리기와 무관하다: 다른 스레드로 넘기거나 오래 들고 있어도 된다. 이 객체는 지난 프레임을 붙잡지 않는다.
public final class SpectrumFrameRenderer {
    private let canvas: SpectrumCanvas
    public var width: Int { canvas.width }
    public var height: Int { canvas.height }
    public init(width: Int, height: Int) throws { canvas = try SpectrumCanvas(width: width, height: height) }

    /// 밴드 값(분석 결과, 0~1 유한, 개수 = style.bands)을 그 모양으로 그린다. 잘못된 모양·값이면 그리기 전에 던진다(캔버스·앞서 돌려준 프레임 모두 그대로).
    /// Digital 0높이 밴드는 기존 중심·색·두께의 작은 원이다. 양수 높이와 Analog는 기존 기하를 유지한다.
    /// 결과(내부 SpectrumCanvas.render 의미 그대로): 그릴 범위가 캔버스 밖 전체면 nil. 범위는 있으나 칠한 화소가 없으면
    /// (알파 0, 아날로그 밴드 1개 등) 투명 1×1 프레임. 그 밖에는 칠한 부분을 16 px 단위로 자른 프레임.
    public func render(bands v: [Float], style: SpectrumItemStyle) throws -> SpectrumRenderedFrame? {
        guard v.count == style.bands else { throw SpectrumRenderError.invalidValues("count \(v.count) ≠ style bands \(style.bands)") }
        guard (0...200).contains(style.reactionPercent) else { throw SpectrumRenderError.invalidStyle("reactionPercent") }
        guard v.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw SpectrumRenderError.invalidValues("value out of 0…1") }
        // Retain the original bands at 100%; analysis/cache keys remain independent of visual strength.
        let adjusted: [Float] = style.reactionPercent == 100 ? v : v.map {
            min(1, max(0, $0 * (Float(style.reactionPercent) / 100)))
        }
        guard let r = try canvas.render(adjusted, style: style.renderStyle) else { return nil }
        // 화소는 내부 그림(r.image)에서 꺼내지 않고 방금 그린 캔버스에서 drawRect 부분을 직접 복사한다. 내부 그림은 보통 따로 자른 비트맵이지만
        // 비트맵을 얻지 못하면 캔버스 makeImage().cropping(행 띠)이고, 그 공급자 데이터의 원점·행 간격은 문서로 보장되지 않는다(2026-10-26 검토).
        // drawRect가 내부 그림을 그대로 설명할 때만(같은 크기, 정수, 캔버스 안) 복사하고, 아니면 실패한다.
        let d = r.drawRect
        guard d.integral == d, r.image.width == Int(d.width), r.image.height == Int(d.height) else {
            throw SpectrumRenderError.invalidCanvas("frame rect \(d) vs image \(r.image.width)x\(r.image.height)")
        }
        return SpectrumRenderedFrame(image: try canvas.ownedImage(d), drawRect: d, canvasWidth: width, canvasHeight: height)
    }

    /// base(위 왼쪽 원점, 행 간격 bytesPerRow, 미리 곱한 sRGB BGRA 32비트 — 캔버스와 같은 형식)의 rect 부분을 새로 할당한 Data에 행마다 복사해,
    /// 그 Data만 가진 CGImage(행 바이트 = 폭 × 4, 데이터 길이 = 행 바이트 × 높이)를 만든다. 부르는 쪽이 rect가 base 안임을 보장한다(SpectrumCanvas.ownedImage가 확인).
    /// 복사가 끝나면 base와 무관하다: 그 Data는 불변이고 provider → 이미지만 붙잡는다.
    static func ownedCopy(_ base: UnsafeRawPointer, bytesPerRow: Int, rect: CGRect) throws -> CGImage {
        let x0 = Int(rect.minX), y0 = Int(rect.minY), w = Int(rect.width), h = Int(rect.height), rowBytes = w * 4
        guard w >= 1, h >= 1, x0 >= 0, y0 >= 0, (x0 + w) * 4 <= bytesPerRow else { throw SpectrumRenderError.invalidCanvas("copy rect \(rect)") }
        var owned = Data(count: rowBytes * h)
        owned.withUnsafeMutableBytes { dst in
            for r in 0..<h { memcpy(dst.baseAddress! + r * rowBytes, base + (y0 + r) * bytesPerRow + x0 * 4, rowBytes) }
        }
        guard let provider = CGDataProvider(data: owned as CFData),
              let out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw SpectrumRenderError.invalidCanvas("image copy") }
        return out
    }
}
