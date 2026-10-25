import CoreGraphics
import Foundation

/// 자막 모양(2026-10-22, 프로젝트 형식 6). 모두 정수라 저장·다시 열기에서 정확히 같다(docs/SUBTITLE-DESIGN.md §3·§6·§7).
/// 좌표계는 영상 변형(ClipTransform)과 같은 출력 1920×1080 픽셀, 왼쪽 위 원점이다. 글자 크기 1pt = 출력 1px(1080p).
/// - 위치(xMilli, yMilli, 1/1000 픽셀)는 자막 상자의 기준점이다. 가로는 정렬에 따라 상자의 왼쪽 끝·가운데·오른쪽 끝, 세로는 상자의 아래 끝이다.
/// - 줄바꿈 너비는 출력 폭 − 좌우 여백(각 sideMargin)이다. 직접 넣은 줄바꿈(\n)은 지킨다.
/// - 글꼴은 PostScript 이름으로 저장한다. 이 Mac에 없으면 저장한 이름은 그대로 두고 시스템 글꼴로 그린 뒤 경고한다(SubtitleRenderer).
public struct SubtitleStyle: Sendable, Equatable, Codable, Hashable {
    public enum Alignment: String, Sendable, Codable, CaseIterable, Hashable { case left, center, right }
    public var fontName: String
    /// 글자 크기: 1080p 기준 pt × 10
    public var sizeTenths: Int
    public var red: Int, green: Int, blue: Int, alpha: Int
    public var alignment: Alignment
    public var xMilli: Int
    public var yMilli: Int
    /// 효과(2026-10-23, 형식 7, D-040): nil = 설정한 적 없음(꺼짐). 끄면 설정 값은 남는다(enabled = false).
    public var outline: SubtitleOutline?
    public var shadow: SubtitleShadow?
    public var background: SubtitleBackground?
    public init(fontName: String, sizeTenths: Int, red: Int, green: Int, blue: Int, alpha: Int = 255, alignment: Alignment, xMilli: Int, yMilli: Int) {
        self.fontName = fontName; self.sizeTenths = sizeTenths; self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        self.alignment = alignment; self.xMilli = xMilli; self.yMilli = yMilli
    }
    /// 출력 기준(1080p) 좌우 여백과 아래 여백(기본 위치)
    public static let sideMargin = 96, bottomMargin = 90
    public static let outputWidth = 1920, outputHeight = 1080
    public static let defaultFontName = "AppleSDGothicNeo-Bold"
    /// 기본값(소유자 방향 2026-10-22): Apple SD Gothic Neo, 흰색, 가운데 정렬, 가로 가운데·아래에서 90px, 48pt
    public static let `default` = SubtitleStyle(fontName: defaultFontName, sizeTenths: 480, red: 255, green: 255, blue: 255, alpha: 255, alignment: .center,
                                                xMilli: outputWidth * 500, yMilli: (outputHeight - bottomMargin) * 1000)
    public static let sizeTenthsRange = 80...3000
    public var size: Double { Double(sizeTenths) / 10 }
    public var x: Double { Double(xMilli) / 1000 }
    public var y: Double { Double(yMilli) / 1000 }
    public var isValid: Bool {
        !fontName.isEmpty && Self.sizeTenthsRange.contains(sizeTenths) && [red, green, blue, alpha].allSatisfy { (0...255).contains($0) }
            && (0...Self.outputWidth * 1000).contains(xMilli) && (0...Self.outputHeight * 1000).contains(yMilli)
            && (outline?.isValid ?? true) && (shadow?.isValid ?? true) && (background?.isValid ?? true)
    }
    /// 켜진 효과가 하나라도 있는가(형식 7이 필요한가)
    public var hasEnabledEffects: Bool { outline?.enabled == true || shadow?.enabled == true || background?.enabled == true }
    /// 켜진 효과만(그리기용). 꺼진 효과는 그림에 영향이 없다.
    public var activeOutline: SubtitleOutline? { outline?.enabled == true ? outline : nil }
    public var activeShadow: SubtitleShadow? { shadow?.enabled == true ? shadow : nil }
    public var activeBackground: SubtitleBackground? { background?.enabled == true ? background : nil }
}

private func rgbaValid(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Bool { [r, g, b, a].allSatisfy { (0...255).contains($0) } }

/// 외곽선(글자 윤곽 바깥으로 width만큼, 출력 1080p 픽셀). 단위: 0.1 px 정수(widthTenths). 색 sRGB RGBA 0–255.
/// 기본(켤 때): 검정 100%, 2 px.
public struct SubtitleOutline: Sendable, Equatable, Codable, Hashable {
    public var enabled: Bool
    public var red: Int, green: Int, blue: Int, alpha: Int
    public var widthTenths: Int
    public static let widthRange = 1...200   // 0.1–20 px
    public static let `default` = SubtitleOutline(enabled: true, red: 0, green: 0, blue: 0, alpha: 255, widthTenths: 20)
    public init(enabled: Bool, red: Int, green: Int, blue: Int, alpha: Int, widthTenths: Int) {
        self.enabled = enabled; self.red = red; self.green = green; self.blue = blue; self.alpha = alpha; self.widthTenths = widthTenths
    }
    public var width: Double { Double(widthTenths) / 10 }
    public var isValid: Bool { rgbaValid(red, green, blue, alpha) && Self.widthRange.contains(widthTenths) }
}

/// 그림자(글자 실루엣 — 외곽선 포함 — 의 그림자, 배경 상자의 그림자 아님). 거리: 오른쪽·아래가 +(출력 픽셀, 0.1 px 정수).
/// 흐림: CoreGraphics 그림자 blur 값(출력 픽셀, 0.1 px 정수) — 가장자리가 대략 그만큼 퍼진다. 0이면 또렷한 그림자.
/// 기본(켤 때): 검정 60%, +4/+4 px, 흐림 6 px.
public struct SubtitleShadow: Sendable, Equatable, Codable, Hashable {
    public var enabled: Bool
    public var red: Int, green: Int, blue: Int, alpha: Int
    public var offsetXTenths: Int, offsetYTenths: Int
    public var blurTenths: Int
    public static let offsetRange = -1000...1000   // ±100 px
    public static let blurRange = 0...500          // 0–50 px
    public static let `default` = SubtitleShadow(enabled: true, red: 0, green: 0, blue: 0, alpha: 153, offsetXTenths: 40, offsetYTenths: 40, blurTenths: 60)
    public init(enabled: Bool, red: Int, green: Int, blue: Int, alpha: Int, offsetXTenths: Int, offsetYTenths: Int, blurTenths: Int) {
        self.enabled = enabled; self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        self.offsetXTenths = offsetXTenths; self.offsetYTenths = offsetYTenths; self.blurTenths = blurTenths
    }
    public var offsetX: Double { Double(offsetXTenths) / 10 }
    public var offsetY: Double { Double(offsetYTenths) / 10 }
    public var blur: Double { Double(blurTenths) / 10 }
    public var isValid: Bool {
        rgbaValid(red, green, blue, alpha) && Self.offsetRange.contains(offsetXTenths) && Self.offsetRange.contains(offsetYTenths) && Self.blurRange.contains(blurTenths)
    }
}

/// 배경 상자(글자 사각형 — 모든 줄의 합 — 을 가로·세로 여백만큼 넓힌 둥근 사각형 하나, 글자 아래). 단위: 0.1 px 정수.
/// 기본(켤 때): 검정 50%, 여백 가로 16·세로 10 px, 모서리 8 px.
public struct SubtitleBackground: Sendable, Equatable, Codable, Hashable {
    public var enabled: Bool
    public var red: Int, green: Int, blue: Int, alpha: Int
    public var padXTenths: Int, padYTenths: Int
    public var radiusTenths: Int
    public static let padRange = 0...2000      // 0–200 px
    public static let radiusRange = 0...2000   // 0–200 px
    public static let `default` = SubtitleBackground(enabled: true, red: 0, green: 0, blue: 0, alpha: 128, padXTenths: 160, padYTenths: 100, radiusTenths: 80)
    public init(enabled: Bool, red: Int, green: Int, blue: Int, alpha: Int, padXTenths: Int, padYTenths: Int, radiusTenths: Int) {
        self.enabled = enabled; self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        self.padXTenths = padXTenths; self.padYTenths = padYTenths; self.radiusTenths = radiusTenths
    }
    public var padX: Double { Double(padXTenths) / 10 }
    public var padY: Double { Double(padYTenths) / 10 }
    public var radius: Double { Double(radiusTenths) / 10 }
    public var isValid: Bool {
        rgbaValid(red, green, blue, alpha) && Self.padRange.contains(padXTenths) && Self.padRange.contains(padYTenths) && Self.radiusRange.contains(radiusTenths)
    }
}

/// 자막 항목(2026-10-22): 자막 레인의 미디어 없는 글자. 타임라인 구간 [start, start + length) 정수 프레임(반 열린 구간, 최소 1프레임).
public struct SubtitleItem: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let lane: UUID
    public let start: Int
    public let length: Int
    public let text: String
    public let style: SubtitleStyle
    public init(id: UUID = UUID(), lane: UUID, start: Int, length: Int, text: String, style: SubtitleStyle = .default) {
        self.id = id; self.lane = lane; self.start = start; self.length = length; self.text = text; self.style = style
    }
    public var end: Int { start + length }
    /// 빈 자막(2026-10-23, D-037): 글자가 없거나 공백·줄바꿈뿐. 문서·타임라인의 진짜 항목이지만 프리뷰·내보내기에 그릴 글자가 없다.
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public func visible(atFrame n: Int) -> Bool { n >= start && n < end }
    public func with(id: UUID? = nil, lane: UUID? = nil, start: Int? = nil, length: Int? = nil, text: String? = nil, style: SubtitleStyle? = nil) -> SubtitleItem {
        SubtitleItem(id: id ?? self.id, lane: lane ?? self.lane, start: start ?? self.start, length: length ?? self.length, text: text ?? self.text, style: style ?? self.style)
    }
}

extension Timeline {
    /// 기본 자막 길이(소유자 방향 2026-10-22): 3초
    public static let defaultSubtitleFrames = 90

    public func subtitle(_ id: UUID) -> SubtitleItem? { subtitles.first { $0.id == id } }
    public func subtitles(inLane id: UUID) -> [SubtitleItem] { subtitles.filter { $0.lane == id } }
    /// 프레임 n에 보이는 자막을 그리는 순서(아래 레인 먼저, 위 레인이 위에 그린다). 같은 레인 안에서는 겹치지 않는다.
    public func subtitles(atFrame n: Int) -> [SubtitleItem] {
        let order = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($1.id, $0) })
        return subtitles.filter { $0.visible(atFrame: n) }.sorted { (order[$0.lane] ?? 0) > (order[$1.lane] ?? 0) }
    }
    /// 그리기 순서(아래 레인 먼저)로 모든 자막
    public var subtitlesInDrawOrder: [SubtitleItem] {
        let order = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($1.id, $0) })
        return subtitles.sorted { ((order[$0.lane] ?? 0), $1.start) > ((order[$1.lane] ?? 0), $0.start) }
    }
    /// 그릴 자막(그리기 순서, 빈 자막 제외): 프리뷰 층·내보내기 단계가 쓴다. 빈 자막만 있으면 내보내기는 자막 없는 기존 경로다.
    public var renderedSubtitles: [SubtitleItem] { subtitlesInDrawOrder.filter { !$0.isBlank } }
    /// 자막만 뺀 타임라인(길이는 그대로). 프리뷰가 자막만 바뀐 편집에서 영상 항목을 다시 만들지 않는지 판단하는 데 쓴다.
    public var withoutSubtitleItems: Timeline { rebuilt(subtitles: []) }
    /// 형식 6이 필요한가(자막 레인 또는 자막이 있음)
    public var needsSubtitleFormat: Bool { !subtitles.isEmpty || !lanes(.subtitle).isEmpty }

    /// 새 자막(만들기): 자막 레인의 at에 기본 길이(length)로 둔다. 같은 레인의 다음 자막에 닿으면 그 앞까지 줄이고,
    /// at이 다른 자막 안이거나 1프레임도 들어가지 않으면 거부한다. 끝을 넘으면 타임라인 길이가 늘어난다(영상이 없는 구간은 검정 위).
    public func addingSubtitle(lane: UUID, at: Int, length: Int = Timeline.defaultSubtitleFrames, text: String, style: SubtitleStyle = .default, id: UUID = UUID()) throws -> Timeline {
        guard laneInfo(lane)?.kind == .subtitle else { throw EditError.laneKindMismatch }
        guard at >= 0 else { throw EditError.badIndex }
        guard style.isValid else { throw EditError.subtitleStyleRange }
        let inLane = subtitles(inLane: lane)
        if inLane.contains(where: { $0.start <= at && at < $0.end }) { throw EditError.subtitleNoRoom }
        let next = inLane.filter { $0.start > at }.map(\.start).min() ?? Int.max
        let len = min(length, next - at)
        guard len >= 1 else { throw EditError.subtitleNoRoom }
        let item = SubtitleItem(id: id, lane: lane, start: at, length: len, text: text, style: style)
        return try checked(rebuilt(subtitles: subtitles + [item], duration: max(durationFrames, item.end)))
    }
    /// 글자 바꾸기. 빈 글자도 된다(빈 자막, D-037).
    public func settingSubtitleText(_ id: UUID, _ text: String) throws -> Timeline {
        guard let i = subtitles.firstIndex(where: { $0.id == id }) else { throw EditError.unknownClip }
        var s = subtitles; s[i] = s[i].with(text: text)
        return try checked(rebuilt(subtitles: s))
    }
    public func settingSubtitleStyle(_ id: UUID, _ style: SubtitleStyle) throws -> Timeline {
        guard let i = subtitles.firstIndex(where: { $0.id == id }) else { throw EditError.unknownClip }
        guard style.isValid else { throw EditError.subtitleStyleRange }
        var s = subtitles; s[i] = s[i].with(style: style)
        return try checked(rebuilt(subtitles: s))
    }
    /// 옮기기(리플 없음): 시작과 자막 레인을 바꾼다. 겹치면 거부한다. 원래 자리는 빈틈, 끝을 넘으면 길이가 늘어난다.
    public func relocatingSubtitle(_ id: UUID, toStart: Int? = nil, lane: UUID? = nil) throws -> Timeline {
        guard let c = subtitle(id) else { throw EditError.unknownClip }
        let l = lane ?? c.lane, st = toStart ?? c.start
        guard laneInfo(l)?.kind == .subtitle else { throw EditError.laneKindMismatch }
        guard st >= 0 else { throw EditError.badIndex }
        let m = c.with(lane: l, start: st)
        if subtitles(inLane: l).contains(where: { $0.id != id && $0.start < m.end && m.start < $0.end }) { throw EditError.overlap }
        return try checked(rebuilt(subtitles: subtitles.map { $0.id == id ? m : $0 }, duration: max(durationFrames, m.end)))
    }
    /// 트림(리플 없음): 자막 구간을 [start, end)로 바꾼다. 자막에는 원본 구간이 없어 가장자리를 그대로 옮긴다.
    /// 최소 1프레임, 0 이상, 같은 레인의 다른 자막과 겹치면 거부. 끝을 넘으면 길이가 늘어난다.
    public func trimmingSubtitle(_ id: UUID, start: Int, end: Int) throws -> Timeline {
        guard let c = subtitle(id) else { throw EditError.unknownClip }
        guard end - start >= 1 else { throw EditError.tooShort }
        guard start >= 0 else { throw EditError.badIndex }
        let m = c.with(start: start, length: end - start)
        if subtitles(inLane: c.lane).contains(where: { $0.id != id && $0.start < m.end && m.start < $0.end }) { throw EditError.overlap }
        return try checked(rebuilt(subtitles: subtitles.map { $0.id == id ? m : $0 }, duration: max(durationFrames, m.end)))
    }
    /// 자르기: 두 조각 모두 같은 글자·모양. 왼쪽 조각은 원래 ID를 newIDs.0으로 바꾼다.
    public func splittingSubtitle(_ id: UUID, atFrame at: Int, newIDs: (UUID, UUID) = (UUID(), UUID())) throws -> Timeline {
        guard let c = subtitle(id) else { throw EditError.unknownClip }
        guard at > c.start, at < c.end else { throw EditError.splitAtBoundary }
        let left = c.with(id: newIDs.0, length: at - c.start), right = c.with(id: newIDs.1, start: at, length: c.end - at)
        return try checked(rebuilt(subtitles: subtitles.filter { $0.id != id } + [left, right]))
    }
    /// 일반 삭제: 빈틈을 남긴다(다른 항목 위치·타임라인 길이 그대로).
    public func liftingSubtitle(_ id: UUID) throws -> Timeline {
        guard subtitle(id) != nil else { throw EditError.unknownClip }
        return rebuilt(subtitles: subtitles.filter { $0.id != id })
    }
    /// 리플 삭제: 자막 구간을 모든 레인에서 닫는다. 그 구간에 다른 클립·자막이 걸치면 거부한다.
    public func rippleDeletingSubtitle(_ id: UUID) throws -> Timeline {
        guard let c = subtitle(id) else { throw EditError.unknownClip }
        let ids: Set<UUID> = [id]
        if occupied(c.start, c.end, excluding: ids) { throw EditError.crossingContent }
        let rest = rebuilt(subtitles: subtitles.filter { $0.id != id })
        let v = rest.shifted(rest.clips, from: c.end, by: -c.length), a = rest.shifted(rest.audioClips, from: c.end, by: -c.length)
        return try checked(rest.rebuilt(video: v, audio: a, subtitles: rest.shiftedSubtitles(from: c.end, by: -c.length), spectra: rest.shiftedSpectra(from: c.end, by: -c.length),
                                         duration: durationFrames - c.length))
    }
    /// 끌어 옮기기 붙음(자막): 시작·끝이 다른 항목의 시작·끝·0·extra에서 threshold 프레임 안이면 붙인다(클립의 snappedDelta와 같은 규칙).
    public func snappedSubtitleDelta(_ id: UUID, delta raw: Double, threshold: Double, extra: [Int] = []) -> (delta: Int, snap: Int?) {
        let delta = Int(raw.rounded())
        guard let c = subtitle(id), threshold > 0 else { return (delta, nil) }
        var targets = Set([0] + extra)
        for o in clips + audioClips { targets.insert(o.start); targets.insert(o.end) }
        for o in subtitles where o.id != id { targets.insert(o.start); targets.insert(o.end) }
        var best: (dist: Double, delta: Int, snap: Int)?
        for edge in [c.start, c.end] {
            for t in targets.sorted() {
                let d = t - edge, dist = abs(Double(edge) + raw - Double(t))
                guard dist <= threshold, c.start + d >= 0 else { continue }
                if best == nil || dist < best!.dist { best = (dist, d, t) }
            }
        }
        return best.map { ($0.delta, $0.snap) } ?? (delta, nil)
    }
    /// 복사(자막 하나)
    public func copying(subtitle id: UUID) throws -> ClipboardContent {
        guard let c = subtitle(id) else { throw EditError.unknownClip }
        return ClipboardContent(video: [], audio: [], subtitles: [c])
    }
}

/// 프리뷰 보기 ↔ 출력 화면 좌표(2026-10-22). 출력(1920×1080)을 보기 안에 비율 유지로 맞춘 사각형(AVPlayerLayer resizeAspect와 같음)을 쓴다.
/// 보기 좌표는 왼쪽 위 원점(뒤집힌 보기), 출력도 왼쪽 위 원점이다. 검은 여백(레터박스)은 출력 밖이다.
public struct PreviewMapping: Equatable, Sendable {
    public let viewSize: CGSize
    public let render: CGSize
    public init(viewSize: CGSize, render: CGSize = CGSize(width: SubtitleStyle.outputWidth, height: SubtitleStyle.outputHeight)) {
        self.viewSize = viewSize; self.render = render
    }
    /// 배율(보기 pt / 출력 px)
    public var scale: CGFloat { max(0, min(viewSize.width / render.width, viewSize.height / render.height)) }
    /// 출력 화면이 보이는 사각형(보기 좌표)
    public var videoRect: CGRect {
        let k = scale, w = render.width * k, h = render.height * k
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }
    /// 보기 → 출력. 여백(출력 밖)이면 nil.
    public func output(_ p: CGPoint) -> CGPoint? {
        let r = videoRect, k = scale
        guard k > 0, r.contains(p) else { return nil }
        return CGPoint(x: (p.x - r.minX) / k, y: (p.y - r.minY) / k)
    }
    /// 보기 → 출력(여백도 계산, 끌기용)
    public func outputUnclamped(_ p: CGPoint) -> CGPoint {
        let r = videoRect, k = max(scale, .leastNonzeroMagnitude)
        return CGPoint(x: (p.x - r.minX) / k, y: (p.y - r.minY) / k)
    }
    public func view(_ p: CGPoint) -> CGPoint { let r = videoRect; return CGPoint(x: r.minX + p.x * scale, y: r.minY + p.y * scale) }
    public func view(_ r: CGRect) -> CGRect { let o = view(r.origin); return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale) }
}

extension Timeline {
    /// 프리뷰 누름 판정(2026-10-22): 프레임 n에 보이는 자막 가운데 출력 위치 p가 글자 사각형(여유 margin px) 안인 것. 위에 그리는 것(위 레인)이 먼저.
    public func subtitleHit(atFrame n: Int, output p: CGPoint, margin: CGFloat = 8) -> SubtitleItem? {
        subtitles(atFrame: n).reversed().first { SubtitleRenderer.shared.hitBounds($0).insetBy(dx: -margin, dy: -margin).contains(p) }
    }
    /// 새 자막(프리뷰에서 만들기)을 둘 자막 레인(2026-10-22): 경계에서 바깥쪽 순서로 시작 프레임이 비어 있고 1프레임 이상 들어가는 첫 레인.
    /// 없으면 nil(새 레인을 바깥쪽에 만든다). 시작 프레임은 옮기지 않는다(다음 자막에 닿으면 길이만 줄어든다).
    public func subtitleLaneForNew(at start: Int, preferred: UUID? = nil) -> UUID? {
        func fits(_ l: UUID) -> Bool {
            let inLane = subtitles(inLane: l)
            if inLane.contains(where: { $0.start <= start && start < $0.end }) { return false }
            return (inLane.filter { $0.start > start }.map(\.start).min() ?? Int.max) > start
        }
        if let p = preferred, laneInfo(p)?.kind == .subtitle, fits(p) { return p }
        return lanesFromBoundary(.subtitle).map(\.id).first(where: fits)
    }
    /// 프리뷰에서 만든 자막을 넣는다(한 단계로 쓸 결과): 알맞은 레인이 없으면 바깥쪽에 새 자막 레인을 만든다.
    public func addingSubtitleCreatingLane(at start: Int, text: String, style: SubtitleStyle, id: UUID, preferredLane: UUID? = nil,
                                           newLaneID: UUID = UUID(), newLaneName: String) throws -> Timeline {
        if let l = subtitleLaneForNew(at: start, preferred: preferredLane) {
            return try addingSubtitle(lane: l, at: start, text: text, style: style, id: id)
        }
        return try addingLane(.subtitle, name: newLaneName, id: newLaneID, outward: true).addingSubtitle(lane: newLaneID, at: start, text: text, style: style, id: id)
    }
}
