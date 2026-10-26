import CoreGraphics
import Foundation
import os

// 스펙트럼 그리기(2026-10-25, docs/SPECTRUM-DESIGN.md §13) — 엔진 안(package) API. 앱 프리뷰·내보내기·정보 패널·저장에 연결하지 않았다.
// 시제품 ProtoSpectrumRenderer(시험 대상)의 기하·그리기 명령을 그대로 옮겼다(같은 입력 → 같은 바이트, 시험으로 확인).
// 한 색만. 두 색·부드러움은 SP-2(D-S6), 기본값은 미정(D-S5) — 모양 값은 부르는 쪽이 명시한다.
// 그리기는 다시 쓰는 전체 캔버스 문맥에 하고(프레임마다 0으로 비움), 기하로 계산한 범위의 행만 자막과 같은 tightCrop으로 자른다.
// 범위만 그린 작은 문맥은 전체 캔버스 그림과 바이트가 달라(§12, 가장자리 최대 1/255) 쓰지 않는다.

/// 모양(1920×1080 기준 단위 — 캔버스에 비례: x는 너비/1920, y·높이·두께는 높이/1080)
package struct SpectrumStyle: Sendable, Equatable {
    package enum Mode: Sendable, Equatable { case digital, analog }
    package enum Sides: Sendable, Equatable { case above, mirrored, below }
    package var start: CGPoint, end: CGPoint
    package var maxHeight: Double, thickness: Double
    package var mode: Mode, sides: Sides
    /// 단색(sRGB 0~1, 미리 곱하지 않음)
    package var red: Double, green: Double, blue: Double, alpha: Double
    package init(start: CGPoint, end: CGPoint, maxHeight: Double, thickness: Double, mode: Mode, sides: Sides,
                 red: Double = 1, green: Double = 1, blue: Double = 1, alpha: Double = 1) {
        self.start = start; self.end = end; self.maxHeight = maxHeight; self.thickness = thickness; self.mode = mode; self.sides = sides
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    /// 쓸 수 있는지(유한한 좌표 ±10000, 시작 ≠ 끝, 높이 0~1080, 두께 0.5~64, 색 0~1)
    package func validationError() -> String? {
        let xs = [start.x, start.y, end.x, end.y].map(Double.init)
        guard xs.allSatisfy({ $0.isFinite && abs($0) <= 10_000 }) else { return "points" }
        guard hypot(end.x - start.x, end.y - start.y) >= 1 else { return "start = end" }
        guard maxHeight.isFinite, (0...1080).contains(maxHeight) else { return "maxHeight \(maxHeight)" }
        guard thickness.isFinite, (0.5...64).contains(thickness) else { return "thickness \(thickness)" }
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return "color" }
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
    /// 칠할 범위(막대·선 끝점 ± 두께 절반 + 앤티에일리어싱 1 px, 캔버스 안, 정수). 칠할 것이 없으면 null(디지털에서 모두 0).
    package static func bounds(_ v: [Float], style s: SpectrumStyle, canvas: CGSize) -> CGRect {
        let g = points(s, bands: v.count, canvas: canvas)
        let th = CGFloat(s.thickness) * g.scaleY
        var r = CGRect.null
        for (p, f) in zip(g.points, v) {
            let hh = CGFloat(f) * CGFloat(s.maxHeight) * g.scaleY
            guard s.mode == .analog || hh > 0 else { continue }
            let up = s.sides == .below ? 0 : hh, down = s.sides == .above ? 0 : hh
            for d in [up, -down] { r = r.union(CGRect(x: p.x + g.up.dx * d, y: p.y + g.up.dy * d, width: 0, height: 0)) }
        }
        guard !r.isNull else { return .null }
        return r.insetBy(dx: -(th / 2 + 1), dy: -(th / 2 + 1)).integral.intersection(CGRect(origin: .zero, size: canvas))
    }
    /// 위 왼쪽 원점으로 뒤집은 문맥에 그린다(디지털: 밴드마다 맞대 끝 막대, 아날로그: 둥근 이음·끝 꺾은선 — 거울이면 위·아래 두 줄)
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
        case .analog:
            ctx.setStrokeColor(color); ctx.setLineWidth(th); ctx.setLineJoin(.round); ctx.setLineCap(.round)
            for sign in (s.sides == .mirrored ? [1.0, -1.0] : (s.sides == .above ? [1.0] : [-1.0])) as [CGFloat] {
                for (i, (p, hh)) in zip(g.points, hs).enumerated() { if i == 0 { ctx.move(to: pt(p, sign * hh)) } else { ctx.addLine(to: pt(p, sign * hh)) } }
            }
            ctx.strokePath()
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
        SpectrumGeometry.draw(v, style: s, canvas: canvas, into: ctx)
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
    /// 결과(내부 SpectrumCanvas.render 의미 그대로): 그릴 범위가 없으면 nil(디지털 모두 0, 범위가 캔버스 밖 전체). 범위는 있으나 칠한 화소가 없으면
    /// (알파 0, 아날로그 밴드 1개 등) 투명 1×1 프레임. 그 밖에는 칠한 부분을 16 px 단위로 자른 프레임.
    public func render(bands v: [Float], style: SpectrumItemStyle) throws -> SpectrumRenderedFrame? {
        guard v.count == style.bands else { throw SpectrumRenderError.invalidValues("count \(v.count) ≠ style bands \(style.bands)") }
        guard let r = try canvas.render(v, style: style.renderStyle) else { return nil }
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
