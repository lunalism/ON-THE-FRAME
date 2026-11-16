import AppKit
import OnTheFrameEngine
import SwiftUI

/// 프리뷰 위 자막 만들기·고르기·옮기기·글 편집(2026-10-22, docs/SUBTITLE-DESIGN.md §44).
/// - 좌표: 출력 화면(1920×1080)을 보기 안에 비율 유지로 맞춘 사각형(PreviewMapping, AVPlayerLayer resizeAspect와 같음). 검은 여백은 출력 밖이라 누름을 받지 않는다.
/// - 텍스트 도구(T): 출력 화면 안을 누르면, 보이는 자막의 글자 위면 그 자막을 고치고, 아니면 재생 헤드·누른 자리에 초안을 만들어 바로 쓴다.
/// - 선택 도구(V): 보이는 자막의 글자 위를 누르면 고르고, 끌면 옮긴다(한 단계, Esc 취소, 끊긴 끌기 취소 D-031). 두 번 누르면 그 자리에서 고친다.
/// - 편집 칸: 시스템 글 칸(NSTextView) 하나. 입력기 조합·선택·클립보드·글 칸 안 실행 취소는 시스템 동작이다. 글꼴·크기(배율)·색·정렬·줄바꿈 폭을
///   자막 그림과 맞추고, 아래 끝을 자막 기준점(상자 아래 끝 − 여유)에 둔다. 편집 중인 기존 자막의 그림은 숨긴다(두 번 보이지 않게).
/// - 그 밖의 자리(자르기 도구, 자막 밖의 V 누름, 여백)는 아래 보기(영상 크기·위치 테두리, 프리뷰)로 넘긴다.
struct SubtitlePreview: NSViewRepresentable {
    let store: ProjectStore
    let state: State
    struct State: Equatable {
        var tool: ProjectStore.EditTool
        var playhead: Int
        var visible: [SubtitleItem]
        var selection: UUID?
        var edit: InlineSubtitleEdit?
    }
    @MainActor static func state(_ s: ProjectStore) -> State {
        State(tool: s.tool, playhead: s.playhead, visible: s.timeline.subtitles(atFrame: s.playhead), selection: s.selection, edit: s.inlineEdit)
    }
    func makeNSView(context: Context) -> SubtitlePreviewView { SubtitlePreviewView(store: store) }
    func updateNSView(_ v: SubtitlePreviewView, context: Context) {
        v.state = state
        v.syncEditor()
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
    }
}

/// 편집 칸을 담는 출력 화면 크기의 자르기 보기(뒤집힌 좌표, 원점 = 출력 화면 왼쪽 위). 칸이 검은 여백·옆 패널로 넘어가 보이지 않게 한다.
/// 출력 화면 밖 글자는 내보내기에서도 잘리므로 같은 모습이다(저장 위치는 바꾸지 않는다).
final class SubtitleCanvasClipView: NSView {
    override var isFlipped: Bool { true }
}

final class SubtitlePreviewView: NSView, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    let store: ProjectStore
    var state: SubtitlePreview.State?
    private enum Drag { case none, pending(UUID, NSPoint, SubtitleStyle), move(UUID, NSPoint, SubtitleStyle) }
    private var drag: Drag = .none
    /// 끌기 중 위치(문서 밖): 이벤트마다 관찰되는 타임라인을 바꾸지 않고(정보 패널·타임라인·SwiftUI 다시 계산 없음) 층과 테두리만 옮긴다.
    /// 놓을 때 이 값을 끌기 기록에 한 번 넣고 확정한다(한 단계). §45.3
    private var liveMove: SubtitleItem?
    #if DEBUG
    /// 자체 검사 전용: 끌기 이벤트 수
    private(set) var dragEventsForTest = 0
    #endif
    /// 편집 칸과 그 편집 번호·모양
    private(set) var editor: CommandReturnTextView?
    private var editorSerial: Int?
    private var editorStyle = SubtitleStyle.default
    private let editorUndo = UndoManager()
    /// 편집 칸의 부모(출력 화면 사각형, 자르기)
    let canvasClip = SubtitleCanvasClipView()
    private var finishing = false

    init(store: ProjectStore) {
        self.store = store
        super.init(frame: .zero)
        canvasClip.clipsToBounds = true
        addSubview(canvasClip)
        NotificationCenter.default.addObserver(self, selector: #selector(gestureInterrupted), name: ProjectStore.gestureInterruptedNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    /// 편집 칸이 있는 동안에는 첫 응답자가 되지 않는다: 칸 밖을 누를 때 창이 이 보기를 첫 응답자로 바꾸면 칸이 먼저 끝나
    /// mouseDown이 칸 없음으로 보고 새 초안을 만들었다(자체 검사에서 발견). 이렇게 하면 mouseDown이 칸을 확정만 한다.
    override var acceptsFirstResponder: Bool { editor == nil }
    var mapping: PreviewMapping { PreviewMapping(viewSize: bounds.size, render: store.settings.renderSize) }
    #if DEBUG
    var dragNameForTest: String { switch drag { case .none: "none"; case .pending: "pending"; case .move: "move" } }
    #endif

    /// 끌기 중단(D-031·CP-08): 저장소가 끌기를 취소했거나 누름 대기를 지우라고 하면 이 보기의 상태도 지우고, 옮기던 그림을 문서 상태로 되돌린다
    @objc private func gestureInterrupted() {
        let moving: Bool
        switch drag { case .none: return; case .pending: moving = false; case .move: moving = true }
        drag = .none; liveMove = nil
        if moving { store.refreshPreviewSubtitles() }
        needsDisplay = true
    }

    // MARK: 누름 판정

    /// 지금 보이는 자막 가운데 출력 위치 p의 것(위 레인 먼저)
    func hit(_ p: CGPoint) -> SubtitleItem? { store.timeline.subtitleHit(atFrame: store.playhead, output: p) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return nil }
        let p = convert(point, from: sv)
        guard bounds.contains(p) else { return nil }
        if let ed = editor { return canvasClip.convert(ed.frame, to: self).contains(p) ? ed.hitTest(ed.superview!.convert(p, from: self)) ?? ed : self }   // 편집 중: 칸 밖 누름은 확정
        if case .none = drag {} else { return self }
        guard let o = mapping.output(p) else { return nil }   // 검은 여백
        switch store.tool {
        case .text: return self
        case .selection: return hit(o) != nil ? self : nil
        case .cut: return nil
        }
    }
    override func resetCursorRects() {
        guard editor == nil else { return }
        let m = mapping
        switch store.tool {
        case .text: addCursorRect(m.videoRect.intersection(bounds), cursor: .iBeam)
        case .selection:
            for s in store.timeline.subtitles(atFrame: store.playhead) {
                addCursorRect(m.view(SubtitleRenderer.shared.hitBounds(s)).intersection(bounds), cursor: .openHand)
            }
        case .cut: break
        }
    }

    // MARK: 마우스

    override func mouseDown(with e: NSEvent) {
        if store.gestureBase != nil { store.interruptGesture() }   // 놓기를 받지 못한 끌기가 남아 있으면 취소(D-031)
        let p = convert(e.locationInWindow, from: nil)
        if editor != nil { finishEditor(commit: true); return }   // 편집 칸 밖을 누름: 확정만
        store.pauseForEdit()
        guard let o = mapping.output(p) else { return }
        let h = hit(o)
        switch store.tool {
        case .text:
            if let h { store.beginInlineEdit(h.id) } else { store.createSubtitleAndEdit(atFrame: store.playhead, output: o) }   // 즉시 만들기(D-037)
            syncEditor()
        case .selection:
            guard let h else { return }
            if e.clickCount >= 2 { store.beginInlineEdit(h.id); syncEditor(); return }
            window?.makeFirstResponder(self)
            store.select(h.id)
            drag = .pending(h.id, p, h.style)
        case .cut: break
        }
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .none: return
        case .pending(let id, let p0, let st0):
            guard abs(p.x - p0.x) > 3 || abs(p.y - p0.y) > 3 else { return }
            // 누른 뒤 도구·선택이 바뀌었거나 자막이 없어졌으면 옮기지 않는다(CP-08과 같은 마지막 확인)
            guard store.tool == .selection, store.timeline.subtitle(id) != nil, store.selection == id, store.gestureBase == nil else { drag = .none; return }
            store.beginGesture(select: id)
            drag = .move(id, p0, st0)
            move(id, p0, st0, p)
        case .move(let id, let p0, let st0):
            move(id, p0, st0, p)
        }
    }
    private func move(_ id: UUID, _ p0: NSPoint, _ st0: SubtitleStyle, _ p: NSPoint) {
        #if DEBUG
        dragEventsForTest += 1
        #endif
        let k = max(mapping.scale, .leastNonzeroMagnitude)
        guard let base = store.gestureBase?.subtitle(id) else { return }
        // 위치만 바꾼다: 모양의 나머지(색 등)는 끌기 시작 기록(gestureBase)의 값. 누를 때 잡은 st0에서는 위치만 쓴다
        // (누른 뒤 끌기 시작 때 색 조정 세션이 확정되면 st0의 색은 이전 색이다 — 코드 리뷰에서 찾음)
        let moved = ProjectStore.movedStyle(st0, dx: Double((p.x - p0.x) / k), dy: Double((p.y - p0.y) / k))
        var st = base.style; st.xMilli = moved.xMilli; st.yMilli = moved.yMilli
        let s = base.with(style: st)
        if s == liveMove { return }
        liveMove = s
        #if DEBUG
        if store.legacySubtitleUIForTest { store.updateSubtitleMove(id, to: s.style) }   // 측정용 이전 동작: 이벤트마다 문서 갱신
        #endif
        if !s.isBlank { store.previewHost?.moveSubtitleLayer(s) }   // 같은 그림(위치만 바뀜, 다시 그리지 않음)
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        if case .move(let id, let p0, let st0) = drag {
            move(id, p0, st0, convert(e.locationInWindow, from: nil))   // 놓은 위치 그대로
            drag = .none
            if let s = liveMove { store.updateSubtitleMove(id, to: s.style) }   // 끌기 기록에 한 번
            liveMove = nil
            store.commitGesture()
            store.refreshPreviewSubtitles()
        }
        drag = .none
        needsDisplay = true
    }
    /// 끌기 중 Esc: 끌기 전으로(기록 없음)
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53, case .move = drag { cancelOperation(nil); return }
        if KeyRouting.route(e, layer: "subtitlePreviewKeyDown", store: store) { return }
        super.keyDown(with: e)
    }
    override func cancelOperation(_ sender: Any?) {
        guard case .move = drag else { return }
        drag = .none; liveMove = nil
        store.cancelGesture()
        store.refreshPreviewSubtitles()
        needsDisplay = true
    }

    // MARK: 그리기(편집 경계, 고른 자막 테두리)

    override func draw(_ dirtyRect: NSRect) {
        if let r = editorOutline {
            let path = NSBezierPath(rect: r); path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.55).setStroke(); let under = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)); under.lineWidth = 1; under.stroke()
            NSColor.controlAccentColor.setStroke(); path.stroke()
            return
        }
        guard store.tool != .cut, let sel = store.selection, let s = store.timeline.subtitles(atFrame: store.playhead).first(where: { $0.id == sel }) else { return }
        let sv = liveMove?.id == sel ? liveMove! : s
        let r = mapping.view(SubtitleRenderer.shared.hitBounds(sv)).insetBy(dx: -4, dy: -3)
        let path = NSBezierPath(rect: r); path.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.55).setStroke(); let under = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)); under.lineWidth = 1; under.stroke()
        NSColor.controlAccentColor.setStroke(); path.stroke()
    }

    // MARK: 편집 칸

    /// 저장소의 글 편집 상태에 칸을 맞춘다: 새 편집이면 칸을 만들고 초점을 주며, 편집이 없어졌거나 다른 프로젝트 회차면 칸을 지운다(문서에 넣지 않음).
    func syncEditor() {
        guard let e = store.inlineEdit, e.session == store.projectSession else { removeEditor(); return }
        if editorSerial == e.serial { layoutEditor(); return }
        removeEditor()
        guard let item = store.timeline.subtitle(e.id) else { store.finishInlineEdit(commit: false, text: nil); return }
        editorStyle = item.style
        let text = item.text
        let ed = CommandReturnTextView(frame: .zero)
        ed.isRichText = false
        ed.importsGraphics = false
        ed.allowsUndo = true
        ed.drawsBackground = false
        ed.isAutomaticQuoteSubstitutionEnabled = false
        ed.isAutomaticDashSubstitutionEnabled = false
        ed.isAutomaticTextReplacementEnabled = false
        ed.isAutomaticSpellingCorrectionEnabled = false
        ed.textContainerInset = .zero
        ed.textContainer?.lineFragmentPadding = 0
        ed.textContainer?.widthTracksTextView = false   // 줄바꿈 폭(컨테이너)은 layoutEditor가 정한다
        ed.textContainer?.heightTracksTextView = false
        ed.isVerticallyResizable = false; ed.isHorizontallyResizable = false
        ed.textStorage?.delegate = self
        ed.delegate = self
        ed.setAccessibilityLabel("자막 글자(프리뷰)")
        ed.onCommandReturn = { [weak self] in self?.finishEditor(commit: true) }
        ed.string = text
        canvasClip.addSubview(ed)
        editor = ed; editorSerial = e.serial
        editorUndo.removeAllActions()
        store.inlineEditorFinish = { [weak self] c in self?.finishEditor(commit: c) }
        applyStyle()
        layoutEditor()
        window?.makeFirstResponder(ed)
        ed.setSelectedRange(NSRange(location: (ed.string as NSString).length, length: 0))
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    /// 글꼴(배율 반영)·색·정렬. 그리는 글꼴과 같게: 이 Mac에 없는 글꼴이면 시스템 글꼴.
    private func applyStyle() {
        guard let ed = editor else { return }
        let st = editorStyle, k = mapping.scale
        let size = max(1, CGFloat(st.size) * k)
        let font = NSFont(name: st.fontName, size: size).flatMap { $0.fontName == st.fontName ? $0 : nil } ?? .systemFont(ofSize: size)
        let color = NSColor(srgbRed: CGFloat(st.red) / 255, green: CGFloat(st.green) / 255, blue: CGFloat(st.blue) / 255, alpha: CGFloat(st.alpha) / 255)
        let para = NSMutableParagraphStyle()
        para.alignment = st.alignment == .left ? .left : (st.alignment == .right ? .right : .center)
        ed.font = font
        ed.textColor = color
        ed.alignment = para.alignment
        ed.defaultParagraphStyle = para
        ed.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        if let ts = ed.textStorage, ts.length > 0 {
            ts.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para], range: NSRange(location: 0, length: ts.length))
        }
        ed.insertionPointColor = color.withAlphaComponent(1)
    }
    /// 칸 자리(점 글자, §44.2 바로잡음): 글을 쓰는 만큼만 넓히고 높인다.
    /// - 줄바꿈은 자막 그림과 같은 논리 폭(출력 1728 px × 배율)으로 먼저 조판해 줄을 정한다. 보이는 칸 폭은 그 조판의 가장 긴 줄 폭 + 캐럿 몫이고,
    ///   그 폭이 논리 폭보다 좁으면 컨테이너도 그 폭으로 줄인다(가장 긴 줄보다 넓으므로 줄바꿈이 달라지지 않는다). 빈 초안은 글자 하나("가") 폭.
    /// - 높이는 실제 줄 조각들과 끝 줄바꿈 뒤의 빈 줄 조각(extraLineFragmentRect)의 아래 끝이다. 상수를 더하지 않는다
    ///   (이전 식은 usedRect가 이미 빈 줄 조각을 포함하는데 한 줄을 더 더해, Return 뒤에 유령 줄이 생겼다가 글을 치면 사라졌다 — 측정으로 확인).
    /// - 가로는 정렬 기준점(가운데·왼쪽 끝·오른쪽 끝)에 칸을 붙이고, 아래 끝 = 기준점 − 여유(자막 그림과 같은 줄 상자). 글이 늘면 정렬 방향·위로 자란다.
    /// - 칸은 출력 화면 크기의 자르기 보기 안에 둔다(검은 여백·옆 패널로 넘치지 않음). 저장 위치는 바꾸지 않는다.
    private func layoutEditor() {
        let m = mapping, vr = m.videoRect
        if canvasClip.frame != vr { canvasClip.frame = vr }
        guard let ed = editor, let lm = ed.layoutManager, let tc = ed.textContainer else { return }
        let k = m.scale, st = editorStyle
        if let f = ed.font, abs(f.pointSize - max(1, CGFloat(st.size) * k)) > 0.01 { applyStyle() }
        let g = Self.editorGeometry(lm, tc, font: ed.font ?? .systemFont(ofSize: 12), text: ed.string, wrapWidth: CGFloat(SubtitleRenderer.wrapWidth) * k)
        let anchorX = CGFloat(st.x) * k
        let x: CGFloat
        switch st.alignment {
        case .left: x = anchorX
        case .center: x = anchorX - g.width / 2
        case .right: x = anchorX - g.width
        }
        let bottom = (CGFloat(st.y) - CGFloat(SubtitleRenderer.pad(for: st))) * k
        let f = NSRect(x: x, y: bottom - g.height, width: g.width, height: g.height)
        if ed.frame != f { ed.frame = f }
        needsDisplay = true
    }
    /// 칸 크기 계산(시험할 수 있게 따로): 컨테이너를 정하고 조판한 뒤 (폭, 높이). 캐럿 몫 2 pt.
    static func editorGeometry(_ lm: NSLayoutManager, _ tc: NSTextContainer, font: NSFont, text: String, wrapWidth: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let caret: CGFloat = 2
        tc.size = NSSize(width: wrapWidth, height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        var longest: CGFloat = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, used, _, _, _ in longest = max(longest, used.width) }
        let content = text.isEmpty ? ceil(NSAttributedString(string: "가", attributes: [.font: font]).size().width) : longest
        let width = min(wrapWidth, ceil(content + caret))
        if width < wrapWidth {
            tc.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
        }
        var bottom: CGFloat = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { r, _, _, _, _ in bottom = max(bottom, r.maxY) }
        let extra = lm.extraLineFragmentRect   // 빈 글·끝 줄바꿈 뒤의 캐럿 줄(없으면 높이 0)
        if extra.height > 0 { bottom = max(bottom, extra.maxY) }
        if bottom <= 0 { bottom = lm.defaultLineHeight(for: font) }
        return (width, ceil(bottom))
    }
    /// 보이는 편집 경계(이 보기 좌표): 칸 둘레 여유 4×3 pt, 출력 화면 안으로 자름
    var editorOutline: CGRect? {
        guard let ed = editor else { return nil }
        let r = canvasClip.convert(ed.frame, to: self).insetBy(dx: -4, dy: -3).intersection(mapping.videoRect)
        return r.isNull ? nil : r
    }
    override func layout() { super.layout(); layoutEditor() }
    /// 편집 끝: 조합 중 글자를 끝낸 뒤 읽고, 칸을 지운 다음 저장소에 넘긴다(한 번만).
    func finishEditor(commit: Bool) {
        guard let ed = editor, !finishing else { return }
        finishing = true
        defer { finishing = false }
        if ed.hasMarkedText() { ed.unmarkText() }
        let text = ed.string
        let hadFocus = window?.firstResponder === ed
        removeEditor()
        if hadFocus { window?.makeFirstResponder(self) }   // 키는 편집기 단축키로(KeyRouting)
        store.finishInlineEdit(commit: commit, text: text)
        needsDisplay = true
    }
    /// 칸만 지운다(저장소에 넘기지 않음: 편집이 이미 끝났거나 버려졌을 때)
    private func removeEditor() {
        guard let ed = editor else { return }
        ed.delegate = nil   // 지우면서 초점을 잃어도 다시 끝내지 않게
        editor = nil; editorSerial = nil
        editorUndo.removeAllActions()
        if store.inlineEditorFinish != nil { store.inlineEditorFinish = nil }
        ed.removeFromSuperview()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // NSTextViewDelegate
    func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }   // 글 칸 안 실행 취소(문서 기록과 따로)
    func textDidChange(_ n: Notification) { layoutEditor() }
    /// 입력기 조합 글자(표시 글자)도 글 저장소를 바꾼다: 조판이 끝난 뒤 칸을 다시 맞춘다(조합 중에도 칸이 글자를 따라감)
    func textStorage(_ ts: NSTextStorage, didProcessEditing m: NSTextStorageEditActions, range: NSRange, changeInLength d: Int) {
        guard m.contains(.editedCharacters) else { return }
        DispatchQueue.main.async { [weak self] in self?.layoutEditor() }
    }
    func textDidEndEditing(_ n: Notification) { finishEditor(commit: true) }   // 다른 곳으로 초점이 감: 확정
    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if tv.hasMarkedText() { return false }   // 조합 중: 입력기 몫
        if sel == #selector(NSResponder.cancelOperation(_:)) { finishEditor(commit: false); return true }   // Esc: 편집 전으로
        return false   // Return은 줄바꿈
    }
}
