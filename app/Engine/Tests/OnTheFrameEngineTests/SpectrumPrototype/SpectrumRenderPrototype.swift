// 스펙트럼 타당성 검사 시제품(2026-10-24, docs/SPECTRUM-DESIGN.md §9) — 제품 코드가 아니다.
// 엔진 시험 대상과 앱 Debug 실험(app/OnTheFrame/SpectrumProto/의 기호 링크, -OTFSpectrumPreviewTest)이 같은 원본을 쓴다. Debug에서만 컴파일된다
// (release 설정 측정은 -Xswiftc -DOTF_PROTO_RELEASE).
#if DEBUG || OTF_PROTO_RELEASE
import CoreGraphics
import Foundation

/// 시제품 모양: 기준 단위는 1080p(1920×1080) — 캔버스 크기에 비례해 키운다(x는 너비/1920, y·높이·두께는 높이/1080). 단색(시험용 흰색).
struct ProtoSpectrumStyle {
    enum Mode { case digital, analog }
    enum Sides { case above, mirrored, below }
    var start = CGPoint(x: 192, y: 540), end = CGPoint(x: 1728, y: 540)
    var maxHeight: CGFloat = 480, thickness: CGFloat = 3
    var mode = Mode.digital, sides = Sides.mirrored
    var rgba: (CGFloat, CGFloat, CGFloat, CGFloat) = (1, 1, 1, 1)
}

enum ProtoSpectrumRenderer {
    /// 밴드 i의 기준선 위 자리(캔버스 픽셀, 위 왼쪽 원점)와 위쪽 단위 벡터
    static func geometry(_ s: ProtoSpectrumStyle, bands: Int, canvas: CGSize) -> (points: [CGPoint], up: CGVector, scaleY: CGFloat) {
        let sx = canvas.width / 1920, sy = canvas.height / 1080
        let a = CGPoint(x: s.start.x * sx, y: s.start.y * sy), b = CGPoint(x: s.end.x * sx, y: s.end.y * sy)
        let dx = b.x - a.x, dy = b.y - a.y, len = max(1e-6, hypot(dx, dy))
        let up = CGVector(dx: dy / len, dy: -dx / len)   // 기준선에 수직, 화면 위쪽(가로 기준선이면 (0, −1))
        let pts = (0..<bands).map { i -> CGPoint in let t = (CGFloat(i) + 0.5) / CGFloat(bands); return CGPoint(x: a.x + dx * t, y: a.y + dy * t) }
        return (pts, up, sy)
    }
    /// 캔버스 크기 그림(미리 곱한 sRGB BGRA, 위 왼쪽 원점 좌표로 그림) — 결정적
    static func render(_ v: [Float], style s: ProtoSpectrumStyle, canvas: CGSize) -> CGContext {
        let w = Int(canvas.width), h = Int(canvas.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // 위 왼쪽 원점
        draw(v, style: s, canvas: canvas, into: ctx)
        return ctx
    }
    static func draw(_ v: [Float], style s: ProtoSpectrumStyle, canvas: CGSize, into ctx: CGContext) {
        let g = geometry(s, bands: v.count, canvas: canvas)
        let color = CGColor(srgbRed: s.rgba.0, green: s.rgba.1, blue: s.rgba.2, alpha: s.rgba.3)
        let th = s.thickness * g.scaleY
        func pt(_ p: CGPoint, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + g.up.dx * d, y: p.y + g.up.dy * d) }
        let hs = v.map { CGFloat($0) * s.maxHeight * g.scaleY }
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
    /// 그리기 전에 그림 범위를 기하로 계산(2026-10-24 SP-0): 막대·선 끝점 ± 두께 절반 + 앤티에일리어싱 1 px, 캔버스 안으로 자르고 정수로.
    /// 그 크기 문맥에만 그린다 — 전체 캔버스에 그린 뒤 전체를 훑어 자르지 않는다.
    static func bounds(_ v: [Float], style s: ProtoSpectrumStyle, canvas: CGSize) -> CGRect {
        let g = geometry(s, bands: v.count, canvas: canvas)
        let th = s.thickness * g.scaleY
        var r = CGRect.null
        for (p, f) in zip(g.points, v) {
            let hh = CGFloat(f) * s.maxHeight * g.scaleY
            guard s.mode == .analog || hh > 0 else { continue }
            let up = s.sides == .below ? 0 : hh, down = s.sides == .above ? 0 : hh
            for d in [up, -down] { r = r.union(CGRect(x: p.x + g.up.dx * d, y: p.y + g.up.dy * d, width: 0, height: 0)) }
        }
        guard !r.isNull else { return .null }
        return r.insetBy(dx: -(th / 2 + 1), dy: -(th / 2 + 1)).integral.intersection(CGRect(origin: .zero, size: canvas))
    }
    /// 범위 크기 문맥에만 그린다(같은 그리기 명령, 원점만 옮김). 돌려주는 그림은 bounds 자리에 놓는다.
    static func renderBounded(_ v: [Float], style s: ProtoSpectrumStyle, canvas: CGSize) -> (image: CGImage, rect: CGRect)? {
        let b = bounds(v, style: s, canvas: canvas)
        guard !b.isNull, b.width > 0, b.height > 0 else { return nil }
        let ctx = CGContext(data: nil, width: Int(b.width), height: Int(b.height), bitsPerComponent: 8, bytesPerRow: Int(b.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: b.height); ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: -b.minX, y: -b.minY)
        draw(v, style: s, canvas: canvas, into: ctx)
        return (ctx.makeImage()!, b)
    }

}
#endif
