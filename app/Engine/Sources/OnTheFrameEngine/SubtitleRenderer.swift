import CoreGraphics
import CoreText
import Foundation

/// 자막 한 항목의 그림(2026-10-22): 프리뷰 층과 내보내기 자막 단계가 같은 그림·같은 사각형을 쓴다(R-30, docs/SUBTITLE-DESIGN.md §43).
/// - image: 미리 곱한 sRGB 8비트(premultipliedFirst, 메모리 B·G·R·A). 줄바꿈 너비(출력 폭 − 좌우 여백) 전체 폭이고, 정렬은 그 안에서 한다.
/// - rect: 출력 1920×1080 픽셀의 정수 사각형(왼쪽 위 원점). 화면 밖으로 나갈 수 있다(쓰는 쪽이 화면 안만 그린다).
public struct SubtitleRaster: @unchecked Sendable {
    public let image: CGImage
    public let rect: CGRect
    /// 실제로 그린 글꼴(PostScript 이름)과, 저장한 글꼴이 없어 대체했는가
    public let fontUsed: String
    public let missingFont: Bool
    /// CoreText가 글자 대체로 쓴 다른 글꼴(예: 한글 글꼴에 없는 일본어 글자)
    public let fallbackFonts: [String]
    public let lines: Int
    /// 글자가 차지하는 출력 사각형(줄마다 조판 너비·위아래 높이의 합집합, 줄 끝 공백 제외). 프리뷰 누름 판정에 쓴다(2026-10-22).
    /// 글자가 없거나 공백뿐이면 rect의 가로 기준점에 폭 0인 사각형.
    public let textBounds: CGRect
    /// 그리지 못함(그림을 만들 메모리를 얻지 못함 등, 2026-10-23). 글자는 그대로 저장되어 있고 그림은 비어 있다.
    /// 앱은 경고하고, 내보내기는 대상 파일을 바꾸기 전에 거부한다. 빈 자막(글자 없음)은 여기에 들지 않는다.
    public let failed: Bool
    /// 글자 일부(또는 전부)가 출력 화면(1920×1080) 밖이다 — 프리뷰·내보내기 모두 화면 밖 부분은 보이지 않는다(같은 결과). 앱이 알린다.
    public let clipped: Bool
    /// 누름·선택 사각형(글자 + 외곽선 + 배경 상자, 그림자 제외, 출력 좌표). 효과가 없으면 textBounds와 같다(2026-10-23).
    public let hitRect: CGRect
}

/// CoreText 자막 그리기. 같은 (글자, 모양)이면 같은 그림을 돌려준다(결정적, 캐시). 스레드 안전(잠금).
/// 캐시는 위치를 뺀 모양으로 잡는다(2026-10-23): 위치만 바뀌면(끌어 옮기기) 글자를 다시 그리지 않고 같은 그림의 사각형만 옮긴다.
/// 사각형은 예전과 같은 식(기준점에서 계산 후 반올림)이라 그림·위치가 그 전과 같다.
public final class SubtitleRenderer: @unchecked Sendable {
    public static let shared = SubtitleRenderer()
    struct Key: Hashable { let text: String; let style: SubtitleStyle }
    /// 위치와 무관한 조판 결과(그림, 크기, 문맥 좌표의 글자 사각형)
    /// image가 nil이면 키 큰 글(출력 화면보다 높은 상자): 놓인 자리마다 화면 안 띠만 그린다(frame으로).
    struct Layout {
        let image: CGImage?, width: Int, height: Int, tight: CGRect
        let fontUsed: String, missing: Bool, fallbackFonts: [String], lines: Int
        var frame: CTFrame? = nil
        var failed = false
        /// 그림 범위(조판 좌표: 논리 상자 아래 왼쪽 원점, 위 +Y). 효과가 없으면 논리 상자 (0, 0, w, h) 그대로.
        var ext: CGRect = .null
        /// 누름 범위(글자 ∪ 외곽선 ∪ 배경, 조판 좌표). 글자가 없으면 null.
        var hitExt: CGRect = .null
        /// 효과 그리기에 쓰는 것: 외곽선 조판(같은 줄 배치), 위치를 뺀 모양, 그림자가 띠 밖에서 들어올 수 있는 거리(행)
        var outlineFrame: CTFrame? = nil
        var style: SubtitleStyle? = nil
        var shadowReach = 0
    }
    private var cache: [Key: Layout] = [:]
    /// 캐시가 붙잡은 그림 바이트(2026-10-23): 개수(512)만으로는 색 패널을 끄는 동안 서로 다른 색마다 그림이 남았다(측정: 색 300개 약 269 MB).
    /// 바이트 예산을 넘으면 비운다(개수 상한과 같은 방식). 다시 필요하면 다시 그린다(한 장 수 ms 이하).
    private var cacheBytes = 0
    static let cacheByteBudget = 160 << 20
    var cachedBytesForTest: Int { lock.lock(); defer { lock.unlock() }; return cacheBytes }
    /// 키 큰 글의 띠 그림(위치마다 다름, 위치 포함 키)
    private var bandCache: [Key: SubtitleRaster] = [:]
    /// 시험 전용 상한(바이트): 이보다 큰 그림은 만들지 못한 것으로 본다(그리기 실패 길 시험). 보통 무한.
    nonisolated(unsafe) static var maxBitmapBytesForTest = Int.max
    private let lock = NSLock()
    private var renders = 0
    /// 지금까지 실제로 조판·그린 수(캐시에 없을 때만 늘어남). 끌기 중 다시 그리기 여부를 재는 데 쓴다.
    public var renderCount: Int { lock.lock(); defer { lock.unlock() }; return renders }

    /// 이 Mac에 글꼴이 있는가(PostScript 이름이 정확히 맞아야 함)
    /// 결과는 캐시한다(타임라인 그리기 상태가 갱신마다 묻는다, 2026-10-23). 글꼴 설치·삭제는 앱을 다시 열면 반영된다.
    public static func fontAvailable(_ name: String) -> Bool {
        fontLock.lock(); defer { fontLock.unlock() }
        if let v = fontCache[name] { return v }
        let f = CTFontCreateWithName(name as CFString, 12, nil)
        let v = (CTFontCopyPostScriptName(f) as String) == name
        fontCache[name] = v
        return v
    }
    nonisolated(unsafe) private static var fontCache: [String: Bool] = [:]
    private static let fontLock = NSLock()
    public static var wrapWidth: Int { SubtitleStyle.outputWidth - 2 * SubtitleStyle.sideMargin }

    public func raster(text: String, style: SubtitleStyle) -> SubtitleRaster {
        var base = style; base.xMilli = 0; base.yMilli = 0
        let key = Key(text: text, style: base)
        lock.lock(); let hit = cache[key]; lock.unlock()
        let l: Layout
        if let hit { l = hit } else {
            l = Self.layout(text: text, style: base)
            let b = l.image.map { $0.bytesPerRow * $0.height } ?? 0
            lock.lock()
            if cache.count > 512 || cacheBytes + b > Self.cacheByteBudget { cache.removeAll(); bandCache.removeAll(); cacheBytes = 0 }
            cache[key] = l; cacheBytes += b; renders += 1
            lock.unlock()
        }
        guard l.image == nil, !l.failed else { return Self.placed(l, style: style) }
        // 키 큰 글: 이 자리의 화면 안 띠
        let full = Key(text: text, style: style)
        lock.lock(); let bandHit = bandCache[full]; lock.unlock()
        if let bandHit { return bandHit }
        let r = Self.band(l, style: style)
        let b = r.image.bytesPerRow * r.image.height
        lock.lock()
        if bandCache.count > 64 || cacheBytes + b > Self.cacheByteBudget { cache.removeAll(); bandCache.removeAll(); cacheBytes = 0 }
        bandCache[full] = r; cacheBytes += b; renders += 1
        lock.unlock()
        return r
    }
    public func raster(_ item: SubtitleItem) -> SubtitleRaster { raster(text: item.text, style: item.style) }

    /// 그리는 글꼴: 저장한 이름의 글꼴, 없으면 시스템 글꼴 같은 크기(이름은 저장값 그대로)
    static func font(for style: SubtitleStyle) -> (font: CTFont, missing: Bool) {
        let size = CGFloat(style.size)
        let font = CTFontCreateWithName(style.fontName as CFString, size, nil)
        let missing = (CTFontCopyPostScriptName(font) as String) != style.fontName
        if missing, let sys = CTFontCreateUIFontForLanguage(.system, size, nil) { return (sys, true) }
        return (font, missing)
    }
    /// 위·아래 여유(그림 상자 = 글자 줄 높이 + 2 × pad)
    public static func pad(for style: SubtitleStyle) -> Int { Int((CGFloat(style.size) * 0.15).rounded(.up)) }
    /// 한 줄 높이(그리는 글꼴의 ascent + descent + leading, 출력 픽셀)
    public static func lineHeight(for style: SubtitleStyle) -> Double {
        let f = font(for: style).font
        return Double(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
    }
    /// 프리뷰를 누른 출력 위치 p에 첫 줄이 오도록 기준점을 정한다(2026-10-22): 가로는 정렬 기준점(가운데 정렬이면 누른 x가 줄 가운데),
    /// 세로는 한 줄 상자의 가운데가 누른 y(기준점 = 상자 아래 끝 = p.y + 줄 높이/2 + pad). 출력 화면 안으로 맞춘다(그래서 아래 끝 근처를 누르면 조금 위에 놓인다).
    public static func anchored(_ style: SubtitleStyle, firstLineAt p: CGPoint) -> SubtitleStyle {
        var s = style
        let y = Double(p.y) + lineHeight(for: style) / 2 + Double(pad(for: style))
        s.xMilli = Int((min(max(Double(p.x), 0), Double(SubtitleStyle.outputWidth)) * 1000).rounded())
        s.yMilli = Int((min(max(y, 0), Double(SubtitleStyle.outputHeight)) * 1000).rounded())
        return s
    }

    /// 빈 자막(글자 없음·공백뿐)의 누름·선택 사각형(2026-10-23): 글자 하나(크기 1 em) × 한 줄, 정렬 기준점·아래 끝(기준점 − 여유) 기준.
    public static func caretBounds(_ style: SubtitleStyle) -> CGRect {
        let w = CGFloat(style.size), h = CGFloat(lineHeight(for: style))
        let x: CGFloat
        switch style.alignment { case .left: x = CGFloat(style.x); case .center: x = CGFloat(style.x) - w / 2; case .right: x = CGFloat(style.x) - w }
        return CGRect(x: x, y: CGFloat(style.y) - CGFloat(pad(for: style)) - h, width: w, height: h)
    }
    /// 누름·선택 사각형: 글자가 있으면 글자 사각형, 빈 자막이면 caretBounds
    public func hitBounds(_ s: SubtitleItem) -> CGRect { s.isBlank ? Self.caretBounds(s.style) : raster(s).hitRect }

    /// 조판 결과를 기준점에 놓는다(사각형 계산은 예전 그대로)
    /// 놓인 자리의 전체(논리) 사각형과 글자 사각형(사각형 식은 예전 그대로: 기준점에서 계산 후 반올림)
    static func geometry(_ l: Layout, style: SubtitleStyle) -> (rect: CGRect, bounds: CGRect) {
        let w = l.width, h = l.height
        let minX: Double
        switch style.alignment {
        case .left: minX = style.x
        case .center: minX = style.x - Double(w) / 2
        case .right: minX = style.x - Double(w)
        }
        let rect = CGRect(x: minX.rounded(), y: (style.y - Double(h)).rounded(), width: Double(w), height: Double(h))
        let bounds = l.tight.isNull ? CGRect(x: style.x, y: rect.minY, width: 0, height: rect.height)
                                    : CGRect(x: rect.minX + l.tight.minX, y: rect.minY + CGFloat(h) - l.tight.maxY, width: l.tight.width, height: l.tight.height)
        return (rect, bounds)
    }
    /// 조판 좌표 사각형 → 출력 좌표(왼쪽 위 원점)
    static func toOutput(_ r: CGRect, logical: CGRect, h: Int) -> CGRect {
        r.isNull ? r : CGRect(x: logical.minX + r.minX, y: logical.minY + CGFloat(h) - r.maxY, width: r.width, height: r.height)
    }
    static let outputFrame = CGRect(x: 0, y: 0, width: SubtitleStyle.outputWidth, height: SubtitleStyle.outputHeight)
    static func isClipped(_ l: Layout, _ bounds: CGRect) -> Bool { !l.tight.isNull && !outputFrame.contains(bounds.insetBy(dx: 0.5, dy: 0.5)) }
    /// 조판 결과를 기준점에 놓는다(전체 그림이 있는 보통 글, 또는 그리지 못한 글)
    static func placed(_ l: Layout, style: SubtitleStyle) -> SubtitleRaster {
        let (rect, bounds) = geometry(l, style: style)
        let hit = l.hitExt.isNull ? bounds : toOutput(l.hitExt, logical: rect, h: l.height)
        if l.failed || l.image == nil {   // 그리지 못함: 투명 1줄 그림(그림·사각형 크기 일치)
            return SubtitleRaster(image: transparentRow(l.width), rect: CGRect(x: rect.minX, y: min(max(rect.maxY - 1, 0), 1079), width: CGFloat(l.width), height: 1),
                                  fontUsed: l.fontUsed, missingFont: l.missing, fallbackFonts: l.fallbackFonts, lines: l.lines, textBounds: bounds,
                                  failed: true, clipped: isClipped(l, bounds), hitRect: hit)
        }
        let img = l.ext.isNull ? rect : toOutput(l.ext, logical: rect, h: l.height)   // 효과가 없으면 rect 그대로
        return SubtitleRaster(image: l.image!, rect: img, fontUsed: l.fontUsed, missingFont: l.missing,
                              fallbackFonts: l.fallbackFonts, lines: l.lines, textBounds: bounds, failed: false, clipped: isClipped(l, bounds), hitRect: hit)
    }
    static func transparentRow(_ w: Int) -> CGImage {
        CGContext(data: nil, width: w, height: 1, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!.makeImage()!
    }
    static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        guard w * h * 4 <= maxBitmapBytesForTest else { return nil }
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
    /// 키 큰 글(2026-10-23): 상자가 출력 화면보다 높으면 화면 안에 드는 줄 띠만 그린다(그림 높이 ≤ 1080). 글자는 자르지 않고 그대로 조판하며,
    /// 화면 밖 부분은 프리뷰·내보내기 모두 원래 보이지 않는 자리다(clipped로 알림). 띠가 비면(전부 화면 밖) 투명 1줄.
    /// 효과: 그림 범위(ext)로 띠를 정하고, 그림자가 띠 밖 줄에서 들어올 수 있으므로 그 거리만큼 더 그린 뒤 띠만 잘라 낸다.
    static func band(_ l: Layout, style: SubtitleStyle) -> SubtitleRaster {
        let (full, bounds) = geometry(l, style: style)
        let hit = l.hitExt.isNull ? bounds : toOutput(l.hitExt, logical: full, h: l.height)
        let ext = l.ext.isNull ? CGRect(x: 0, y: 0, width: l.width, height: l.height) : l.ext
        let img = toOutput(ext, logical: full, h: l.height)
        let w = Int(ext.width)
        let top = max(Int(img.minY), 0), bottom = min(Int(img.maxY), SubtitleStyle.outputHeight)
        let visible = bottom > top
        let dTop = visible ? max(Int(img.minY), top - l.shadowReach) : top
        let dBottom = visible ? min(Int(img.maxY), bottom + l.shadowReach) : top + 1
        guard let frame = l.frame, let ctx = bitmap(w, dBottom - dTop) else {
            var f = l; f.failed = true
            return placed(f, style: style)
        }
        if visible {
            // 조판 좌표 y=Y의 출력 행 = full.minY + h − Y, 그림 y = dBottom − 출력 행 → 이동 (−ext.minX, dBottom − full.minY − h)
            ctx.translateBy(x: -ext.minX, y: CGFloat(dBottom) - full.minY - CGFloat(l.height))
            drawContent(ctx, fill: frame, outline: l.outlineFrame, style: l.style, tight: l.tight)
        }
        var image = ctx.makeImage()!
        if visible, dTop < top || dBottom > bottom, let c = image.cropping(to: CGRect(x: 0, y: top - dTop, width: w, height: bottom - top)) { image = c }
        let rect = CGRect(x: img.minX, y: CGFloat(visible ? top : min(max(Int(img.minY), 0), SubtitleStyle.outputHeight - 1)), width: CGFloat(w), height: CGFloat(visible ? bottom - top : 1))
        return SubtitleRaster(image: image, rect: rect, fontUsed: l.fontUsed, missingFont: l.missing, fallbackFonts: l.fallbackFonts,
                              lines: l.lines, textBounds: bounds, failed: false, clipped: isClipped(l, bounds), hitRect: hit)
    }

    /// 효과 그리기(조판 좌표, 2026-10-23, D-040). 효과가 없으면 예전과 같이 글자만 그린다.
    /// 순서: 배경 상자 → [투명 층: 외곽선 → 채움(복사 섞기, 외곽선 위에 채움 알파를 한 번만)] 층 전체에 그림자 한 번.
    /// 그림자는 글자 실루엣(외곽선 포함)의 것이고 배경 상자에는 붙지 않는다.
    static func drawContent(_ ctx: CGContext, fill: CTFrame, outline: CTFrame?, style: SubtitleStyle?, tight: CGRect) {
        guard let st = style, st.hasEnabledEffects, !tight.isNull else { CTFrameDraw(fill, ctx); return }
        func color(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255) }
        if let bg = st.activeBackground {
            let box = tight.insetBy(dx: -CGFloat(bg.padX), dy: -CGFloat(bg.padY))
            let r = min(CGFloat(bg.radius), box.width / 2, box.height / 2)
            ctx.setFillColor(color(bg.red, bg.green, bg.blue, bg.alpha))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.fillPath()
        }
        let ol = st.activeOutline.flatMap { _ in outline }, sh = st.activeShadow
        guard ol != nil || sh != nil else { CTFrameDraw(fill, ctx); return }
        ctx.saveGState()
        if let sh { ctx.setShadow(offset: CGSize(width: sh.offsetX, height: -sh.offsetY), blur: CGFloat(sh.blur), color: color(sh.red, sh.green, sh.blue, sh.alpha)) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if let ol {
            ctx.setLineJoin(.round)
            CTFrameDraw(ol, ctx)
            ctx.setBlendMode(.copy)   // 채움이 글자 안의 외곽선을 덮어씀(반투명 채움에서 외곽선이 비치지 않게)
        }
        CTFrameDraw(fill, ctx)
        ctx.setBlendMode(.normal)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func render(text: String, style: SubtitleStyle) -> SubtitleRaster { placed(layout(text: text, style: style), style: style) }

    /// 끝 줄바꿈(2026-10-23): CoreText는 끝 줄바꿈 뒤의 빈 줄을 줄로 만들지 않아(측정: "안녕하세요\n" → 1줄) 편집 칸(빈 캐럿 줄 포함)과
    /// 확정 그림의 줄 수가 달랐고, 아래 끝 기준이라 확정 때 글자가 한 줄 내려갔다. 조판할 때만 끝에 폭 없는 공백(U+200B)을 붙여 그 빈 줄을
    /// 같은 글꼴 줄 높이로 만든다. 저장 글자는 그대로이고, 끝 줄바꿈이 없는 글자의 그림은 바뀌지 않는다.
    static func layout(text: String, style: SubtitleStyle) -> Layout {
        let size = CGFloat(style.size)
        let (font, missing) = Self.font(for: style)
        var align: CTTextAlignment = style.alignment == .left ? .left : (style.alignment == .right ? .right : .center)
        let para = withUnsafeBytes(of: &align) { p in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: p.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let color = CGColor(srgbRed: CGFloat(style.red) / 255, green: CGFloat(style.green) / 255, blue: CGFloat(style.blue) / 255, alpha: CGFloat(style.alpha) / 255)
        let laid = text.hasSuffix("\n") ? text + "\u{200B}" : text
        let attr = NSAttributedString(string: laid, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                 kCTForegroundColorAttributeName as NSAttributedString.Key: color,
                                                                 kCTParagraphStyleAttributeName as NSAttributedString.Key: para])
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let w = wrapWidth
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil, CGSize(width: CGFloat(w), height: .greatestFiniteMagnitude), nil)
        let pad = Self.pad(for: style)   // 위·아래 여유(글자 모양이 줄 상자를 조금 넘는 경우)
        let h = max(1, Int(fit.height.rounded(.up)) + 2 * pad)
        // 상자가 출력 화면보다 높으면(키 큰 글) 여기서는 그리지 않고 조판만 한다 — 놓인 자리마다 화면 안 띠를 그린다(band).
        // 보통 글은 전체 그림(높이 ≤ 1080 + 여유, 위치와 무관하게 캐시). 그림을 만들지 못하면 failed(앱 경고·내보내기 거부, 2026-10-23).
        let framePath = CGPath(rect: CGRect(x: 0, y: CGFloat(pad), width: CGFloat(w), height: CGFloat(h - 2 * pad)), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), framePath, nil)
        let tall = h > SubtitleStyle.outputHeight
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var tight = CGRect.null   // 문맥 좌표(왼쪽 아래 원점)
        for (l, o) in zip(lines, origins) {
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(l, &asc, &desc, &lead)) - CGFloat(CTLineGetTrailingWhitespaceWidth(l))
            guard width > 0 else { continue }
            tight = tight.union(CGRect(x: o.x, y: CGFloat(pad) + o.y - desc, width: width, height: asc + desc))   // 줄 원점은 정렬을 반영한다
        }
        // 효과(2026-10-23): 그림 범위·누름 범위·외곽선 조판. 효과가 없으면(또는 글자 사각형이 없으면) 그림 범위 = 논리 상자(예전과 같은 그림).
        var ext = CGRect(x: 0, y: 0, width: w, height: h), hitExt = CGRect.null, outlineFrame: CTFrame? = nil, reach = 0
        let fx = style.hasEnabledEffects && !tight.isNull
        if fx {
            // 글자 잉크가 줄 사각형(진행 폭 × 위·아래 높이)을 넘는 만큼(왼쪽 아래로 내려간 j, 기울임꼴 등)도 효과 범위에 넣는다(2026-10-23 검토: 왼쪽 맞춤 "j"의 외곽선이 그림 왼쪽에서 잘렸다)
            var ink = tight
            for (l, o) in zip(lines, origins) {
                let b = CTLineGetImageBounds(l, nil)
                if !b.isNull && !b.isEmpty { ink = ink.union(b.offsetBy(dx: o.x, dy: CGFloat(pad) + o.y)) }
            }
            var drawn = ink, hits = tight
            if let ol = style.activeOutline {
                let ow = CGFloat(ol.width)
                drawn = ink.insetBy(dx: -ow - 1, dy: -ow - 1); hits = drawn   // + 1: 획 가장자리 앤티에일리어싱 화소
                // 외곽선: 같은 글자·글꼴·문단에 획만(CoreText 획 두께는 글자 크기의 %, 윤곽 가운데에 그리므로 바깥 ow = 두께 2·ow)
                let stroke = NSAttributedString(string: laid, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                           kCTParagraphStyleAttributeName as NSAttributedString.Key: para,
                                                                           kCTStrokeWidthAttributeName as NSAttributedString.Key: 2 * ow / size * 100,
                                                                           kCTStrokeColorAttributeName as NSAttributedString.Key: CGColor(srgbRed: CGFloat(ol.red) / 255, green: CGFloat(ol.green) / 255, blue: CGFloat(ol.blue) / 255, alpha: CGFloat(ol.alpha) / 255)])
                outlineFrame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(stroke), CFRange(location: 0, length: 0), framePath, nil)
            }
            var all = ext.union(drawn)
            if let sh = style.activeShadow {
                let spread = CGFloat(sh.blur) + 2
                all = all.union(drawn.offsetBy(dx: CGFloat(sh.offsetX), dy: -CGFloat(sh.offsetY)).insetBy(dx: -spread, dy: -spread))
                reach = Int((abs(sh.offsetY) + sh.blur + 2).rounded(.up))
            }
            if let bg = style.activeBackground {
                let box = tight.insetBy(dx: -CGFloat(bg.padX), dy: -CGFloat(bg.padY))
                all = all.union(box); hits = hits.union(box)
            }
            ext = all.integral; hitExt = hits
        }
        var ctx: CGContext? = nil
        if !tall, let c = Self.bitmap(Int(ext.width), Int(ext.height)) {
            c.translateBy(x: -ext.minX, y: -ext.minY)
            drawContent(c, fill: frame, outline: outlineFrame, style: fx ? style : nil, tight: tight)
            ctx = c
        }
        var used = Set<String>()
        let original = (text as NSString).length
        for l in lines { for r in CTLineGetGlyphRuns(l) as! [CTRun] where CTRunGetStringRange(r).location < original {   // 붙인 U+200B만의 글자 묶음은 빼고
            if let f = (CTRunGetAttributes(r) as NSDictionary)[kCTFontAttributeName] { used.insert(CTFontCopyPostScriptName(f as! CTFont) as String) }
        } }
        let fontUsed = CTFontCopyPostScriptName(font) as String
        return Layout(image: ctx?.makeImage(), width: w, height: h, tight: tight, fontUsed: fontUsed, missing: missing,
                      fallbackFonts: used.subtracting([fontUsed]).sorted(), lines: lines.count, frame: tall ? frame : nil, failed: !tall && ctx == nil,
                      ext: fx ? ext : .null, hitExt: fx ? hitExt : .null, outlineFrame: outlineFrame, style: fx ? style : nil, shadowReach: reach)
    }
}
