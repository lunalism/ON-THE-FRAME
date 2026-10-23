import AppKit
import OnTheFrameEngine
import SwiftUI

// MARK: - 자막 편집(2026-10-22, docs/SUBTITLE-DESIGN.md §43·§44·§45)
//
// 주된 흐름(§45, D-037 — §44의 미룬 만들기를 대체): 텍스트 도구(T)로 프리뷰 화면을 누르면 재생 헤드·누른 자리에 진짜 3초 자막(필요하면 새 자막 레인)을
// 문서에 바로 만들고(실행 취소 한 단계), 고른 뒤 그 자리 편집 칸을 연다. 글자를 실제로 바꾸면 확정 때 한 단계 더. Esc는 시작 글자로 되돌리고
// 만든 자막·레인은 남는다. 비워 두어도 지우지 않는다(빈 자막: 타임라인에 "빈 자막", 프리뷰·내보내기에 그리지 않음).
// 보이는 기존 자막을 T로 누르거나 V로 두 번 누르면 그 자막을 고친다. 타임라인을 누르는 것으로는 만들지 않는다(메뉴 "자막 추가"는 같은 즉시 만들기).

/// 프리뷰 위 글 편집(기존 자막). session은 프로젝트 회차(다른 프로젝트로 새지 않게), serial은 편집마다 새 번호.
struct InlineSubtitleEdit: Equatable {
    let id: UUID
    let session: Int
    let serial: Int
    /// 편집을 시작한 때 글자(Esc는 이 글자로)
    let original: String
    var existingID: UUID? { id }
}

extension ProjectStore {
    /// 고른 자막
    var selectedSubtitle: SubtitleItem? { selection.flatMap { timeline.subtitle($0) } }

    // MARK: 프리뷰에서 만들기·글 편집

    /// 즉시 만들기(T로 프리뷰 누름, 메뉴 "자막 추가"): 재생 헤드(타임라인 끝까지)에 3초 빈 자막을 문서에 넣고(새 레인 포함 한 단계) 그 자리 편집을 연다.
    /// output이 nil이면 기본 위치(가운데 아래). 레인: 고른 자막 레인(또는 고른 자막의 레인) → 경계에서 바깥쪽으로 비어 있는 첫 레인 → 새 레인. 시작은 옮기지 않는다.
    @discardableResult func createSubtitleAndEdit(atFrame f: Int, output p: CGPoint?) -> UUID? {
        commitInlineEditIfAny()
        guard gestureBase == nil, openProgress == nil else { return nil }
        let style = p.map { SubtitleRenderer.anchored(.default, firstLineAt: $0) } ?? .default
        let preferred = selectedLane.flatMap { timeline.laneInfo($0)?.kind == .subtitle ? $0 : nil } ?? selectedSubtitle?.lane
        let id = UUID(), name = newLaneName(.subtitle), start = max(0, min(f, timeline.durationFrames))
        commit({ try $0.addingSubtitleCreatingLane(at: start, text: "", style: style, id: id, preferredLane: preferred, newLaneName: name) }, focus: id)
        guard timeline.subtitle(id) != nil else { return nil }
        beginInlineEdit(id)
        return id
    }
    /// 기존 자막을 그 자리에서 고치기(T 누름, V 두 번 누름, 방금 만든 자막)
    @discardableResult func beginInlineEdit(_ id: UUID) -> Bool {
        if inlineEdit?.id == id { return true }
        commitInlineEditIfAny()
        guard gestureBase == nil, let s = timeline.subtitle(id) else { return false }
        interruptGesture(reason: "inlineEdit", clearViewDrags: true)   // 누름 대기 지우기(CP-08과 같은 길)
        pauseForEdit()
        selection = id; selectedLane = nil
        inlineSerial &+= 1
        inlineEdit = InlineSubtitleEdit(id: id, session: projectSession, serial: inlineSerial, original: s.text)
        statusMessage = nil
        return true
    }
    /// 글 편집 끝(편집 칸이 부른다). commit: 글자가 실제로 바뀌었으면 한 단계(빈 글자도 됨). 취소(Esc)는 문서를 바꾸지 않는다(자막·레인은 남음).
    /// 다른 프로젝트 회차의 편집은 버린다.
    func finishInlineEdit(commit: Bool, text: String?) {
        guard let e = inlineEdit, !inlineFinishing else { return }
        inlineFinishing = true
        defer { inlineFinishing = false; inlineEdit = nil }
        guard e.session == projectSession, commit, let text, text != e.original else { return }
        setSubtitleText(e.id, text)
    }
    /// 진행 중인 글 편집·색 조정을 지금 값으로 확정한다(재생·탐색·도구 바꿈·다른 편집·저장·내보내기·프로젝트 교체·닫기 앞).
    /// 편집 칸이 있으면 그 칸이 글자를 읽어 끝내고(조합 중 글자 포함), 없으면 그대로 둔다.
    func commitInlineEditIfAny() {
        finishColorSession()
        if let f = panelTextCommit { panelTextCommit = nil; f() }   // 정보 패널 글 칸
        guard inlineEdit != nil, !inlineFinishing else { return }
        if let finish = inlineEditorFinish { finish(true) } else { finishInlineEdit(commit: true, text: nil) }
    }
    /// 확정을 기다리는 글 편집·색 조정이 있는가
    var hasPendingSubtitleEdits: Bool { inlineEdit != nil || colorSession != nil || panelTextCommit != nil }

    /// 메뉴 "자막 추가": 재생 헤드·기본 위치에 즉시 만들기
    func addSubtitleAtPlayhead() {
        createSubtitleAndEdit(atFrame: playhead, output: nil)
    }
    /// 글자 확정(한 단계). 같은 글자면 기록하지 않는다. 빈 글자도 된다(빈 자막, D-037).
    @discardableResult func setSubtitleText(_ id: UUID, _ text: String) -> Bool {
        guard let s = timeline.subtitle(id) else { return false }
        if s.text == text { return true }
        guard gestureBase == nil else { return false }
        commit({ try $0.settingSubtitleText(id, text) }, focus: id)
        return timeline.subtitle(id)?.text == text
    }

    // MARK: 색 조정 세션(2026-10-23, D-039 — 0.4초 멈춤 경계를 없앰)

    /// 색 조정(팔레트·색 패널·HEX·불투명도)은 한 세션이다. 실제로 색이 바뀐 첫 순간 시작하고, 그동안 문서는 바꾸지 않고 프리뷰 층만 바꾼다
    /// (영상 항목 그대로). 색 패널 닫힘, 다른 편집·다른 것 고르기·실행 취소·저장·내보내기 같은 문서 동작 앞에서 끝나며, 끝날 때 한 번만 넣는다
    /// (처음 값과 같으면 기록 없음). 멈춘 시간은 세션을 나누지 않는다.
    /// - project: 그 색 상자를 그린 프로젝트 회차. 늦게 온 패널 값이 다른 프로젝트·다른 자막(고른 것이 아님)을 바꾸지 않게 거른다.
    func colorEditChange(_ id: UUID, red: Int, green: Int, blue: Int, alpha: Int, project: Int) {
        styleEditChange(id, project: project) { $0.red = red; $0.green = green; $0.blue = blue; $0.alpha = alpha }
    }
    /// 모양 조정 세션(2026-10-23, D-040에서 넓힘): 색과 같은 세션으로 효과(외곽선·그림자·배경)의 켜기·색·숫자 조정을 받는다.
    /// 첫 실제 변화에 시작, 문서는 그대로 두고 프리뷰 층만 바꾸며(영상 항목 그대로), 끝날 때 한 번 넣는다. 멈춘 시간은 세션을 나누지 않는다.
    func styleEditChange(_ id: UUID, project: Int, _ change: (inout SubtitleStyle) -> Void) {
        guard project == projectSession, gestureBase == nil, selection == id, let s = timeline.subtitle(id) else { return }
        if let c = colorSession, c.id != id { finishColorSession() }
        var st = colorSession?.id == id ? colorSession!.current : s.style
        change(&st)
        guard st.isValid else { return }
        if var c = colorSession {
            guard c.current != st else { return }
            c.current = st; colorSession = c
        } else {
            guard st != s.style else { return }   // 실제 변화가 없으면 세션을 열지 않음(패널을 열 때 같은 색이 와도)
            colorSession = ColorEditSession(id: id, project: projectSession, initial: s.style, current: st)
            if colorPanelObserver == nil {
                colorPanelObserver = NotificationCenter.default.addObserver(forName: NSColorPanel.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finishColorSession() }
                }
            }
        }
        if !s.isBlank { previewHost?.moveSubtitleLayer(s.with(style: st)) }
    }
    /// 색 조정 세션 끝: 처음과 다르면 한 단계로 넣는다. 여러 번 불려도 한 번만(세션은 먼저 비운다). 대상이 지워졌거나 다른 프로젝트면 버린다.
    func finishColorSession() {
        guard let c = colorSession else { return }
        colorSession = nil
        guard c.project == projectSession, let s = timeline.subtitle(c.id) else { return }
        // 처음에 없던 효과를 켰다가 그대로 끈 것(기본값·꺼짐)은 그림이 같으니 처음처럼 없음으로 돌린다 — 바뀐 게 없는 실행 취소 단계를 만들지 않게(2026-10-23 검토)
        var current = c.current
        if c.initial.outline == nil, current.outline == SubtitleOutline.default.disabled { current.outline = nil }
        if c.initial.shadow == nil, current.shadow == SubtitleShadow.default.disabled { current.shadow = nil }
        if c.initial.background == nil, current.background == SubtitleBackground.default.disabled { current.background = nil }
        if current != s.style { setSubtitleStyle(c.id, current) } else { refreshPreviewSubtitles() }
    }
    /// 모양 바꾸기(한 단계). 같으면 기록하지 않는다.
    func setSubtitleStyle(_ id: UUID, _ style: SubtitleStyle) {
        guard gestureBase == nil, let s = timeline.subtitle(id), s.style != style else { return }
        commit({ try $0.settingSubtitleStyle(id, style) }, focus: id)
    }
    /// 이 Mac에 없는 자막 글꼴(PostScript 이름, 정렬)
    var missingSubtitleFonts: [String] {
        Set(timeline.subtitles.map(\.style.fontName)).filter { !SubtitleRenderer.fontAvailable($0) }.sorted()
    }
}

// MARK: - 왼쪽 "클립 조정" 탭: 자막

struct SubtitleAdjustView: View {
    @Bindable var store: ProjectStore
    let item: SubtitleItem
    /// 측정용 이전 동작(Debug 자체 검사만): 모양 칸이 자막 전체에 의존하게 한다
    var legacyProbe: SubtitleItem? {
        #if DEBUG
        return store.legacySubtitleUIForTest ? item : nil
        #else
        return nil
        #endif
    }
    var body: some View {
        // 그리기 상태(2026-10-23): 그리지 못함은 빨강(내보내기 막힘), 화면 밖으로 나간 글은 주황. 빈 자막은 원래 그리지 않으므로 경고 없음.
        if !item.isBlank {
            let r = SubtitleRenderer.shared.raster(item)
            if r.failed {
                Label("이 자막을 그릴 수 없습니다(글이 너무 큼). 글은 그대로 저장되어 있습니다. 글을 줄이거나 글자 크기를 줄이세요. 이 상태에서는 내보낼 수 없습니다.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if r.clipped {
                Label("글 일부가 화면(1920×1080) 밖이라 프리뷰·내보내기에서 보이지 않습니다. 글을 줄이거나 글자 크기·위치를 바꾸세요.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        AdjustSection(title: "글자") {
            SubtitleTextEditor(store: store, id: item.id, text: item.text)
                .frame(minHeight: 70, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            Text("프리뷰에서 텍스트 도구(T)로 누르거나 선택 도구로 두 번 누르면 화면 위에서 고칩니다. 여기서도 고칠 수 있습니다: Return 줄바꿈 · ⌘Return 또는 다른 곳을 누르면 확정 · Esc 되돌림")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        AdjustSection(title: "모양") { SubtitleStyleAdjust(store: store, id: item.id, stored: item.style, project: store.projectSession, legacyProbe: legacyProbe).equatable() }
        AdjustSection(title: "시간") {
            let tc = store.settings.timecode
            Text("\(tc(item.start)) – \(tc(item.end)) · 길이 \(tc(item.length))").font(.callout).textSelection(.enabled)
            Text("타임라인에서 선택 도구로 옮기고 양쪽 끝을 끌어 길이를 바꿉니다.").font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// ⌘Return을 확정으로 쓰는 글 칸(조합 중이면 입력기 몫). 정보 패널 글 칸과 프리뷰 위 편집 칸이 같이 쓴다.
class CommandReturnTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    override func keyDown(with e: NSEvent) {
        if !hasMarkedText(), e.keyCode == 36 || e.keyCode == 76,
           e.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command] { onCommandReturn?(); return }
        super.keyDown(with: e)
    }
}

/// 정보 패널의 여러 줄 글 칸(NSTextView). 자체 실행 취소 기록을 두고 확정할 때 비운다(타임라인 기록과 섞지 않음).
struct SubtitleTextEditor: NSViewRepresentable {
    let store: ProjectStore
    let id: UUID
    let text: String

    final class TextView: CommandReturnTextView {}
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SubtitleTextEditor
        weak var view: TextView?
        let undo = UndoManager()
        /// 편집을 시작한 자막과 그때 글자(Esc 되돌림·확정 대상)
        var editingID: UUID?
        var original = ""
        var reverting = false
        init(_ p: SubtitleTextEditor) { parent = p }
        func undoManager(for view: NSTextView) -> UndoManager? { undo }
        /// 편집을 시작한 프로젝트 회차(다른 프로젝트로 새지 않게)
        var session = 0
        func textDidBeginEditing(_ n: Notification) {
            editingID = parent.id; original = view?.string ?? parent.text; session = parent.store.projectSession
            // 저장·내보내기·닫기·끝내기·다른 편집 앞(commitInlineEditIfAny)에서 이 칸도 확정한다(코드 리뷰: 초점을 잃을 때만 확정하던 결함)
            parent.store.panelTextCommit = { [weak self] in self?.commit() }
        }
        func textDidEndEditing(_ n: Notification) { commit() }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if tv.hasMarkedText() { return false }   // 조합 중: 입력기 몫
            if sel == #selector(NSResponder.cancelOperation(_:)) {   // Esc: 시작한 때 글자로 되돌리고 초점을 놓는다
                reverting = true
                tv.string = original
                undo.removeAllActions()
                tv.window?.makeFirstResponder(nil)
                reverting = false
                return true
            }
            return false   // Return은 줄바꿈(기본)
        }
        /// 확정: 조합 중 글자는 끝낸 뒤 읽는다. 빈 글자·실패는 이전 글자로 되돌린다.
        func commit() {
            guard let tv = view else { return }
            if tv.hasMarkedText() { tv.unmarkText() }
            let editing = editingID != nil
            let id = editingID ?? parent.id
            editingID = nil
            undo.removeAllActions()
            parent.store.panelTextCommit = nil
            guard !reverting else { return }
            // 다른 프로젝트 회차에서 시작한 편집은 넣지 않는다(같은 파일을 다시 열면 자막 ID가 같다)
            guard !editing || session == parent.store.projectSession else { tv.string = parent.store.timeline.subtitle(id)?.text ?? ""; return }
            let s = tv.string
            if !parent.store.setSubtitleText(id, s) { tv.string = parent.store.timeline.subtitle(id)?.text ?? original }
        }
        func commandReturn() { view?.window?.makeFirstResponder(nil) }   // 초점이 떠나며 확정(textDidEndEditing)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType = .noBorder
        let tv = TextView(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.string = text
        tv.setAccessibilityLabel("자막 글자")
        tv.onCommandReturn = { [weak c = context.coordinator] in c?.commandReturn() }
        context.coordinator.view = tv
        sv.documentView = tv
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let tv = c.view else { return }
        let idChanged = c.parent.id != id
        if idChanged, c.editingID != nil { c.commit() }   // 다른 자막으로 바뀜: 이전 자막 글자 확정
        c.parent = self
        let editing = tv.window?.firstResponder === tv
        if idChanged || (!editing && tv.string != text) { tv.string = text; c.undo.removeAllActions() }   // 실행 취소 등 바깥 변경
    }
}

/// 글꼴·크기·색·정렬·위치. 값마다 한 단계(Return 또는 고르기).
/// 모양 칸. 입력은 자막 ID와 저장된 모양뿐이라(Equatable), 타임라인에서 자막을 끌어 시각만 바뀔 때는 다시 계산하지 않는다(§45.3:
/// 끌기마다 수백 개 글꼴 목록을 다시 만들던 비용). 색 고르개 연속 조정 중이면 그 값(문서 밖)을 보인다.
struct SubtitleStyleAdjust: View, @preconcurrency Equatable {
    @Bindable var store: ProjectStore
    let id: UUID
    let stored: SubtitleStyle
    /// 이 칸을 그린 프로젝트 회차(만들 때 정함)
    var project: Int = 0
    /// 자체 검사 전용 비교 값: 이전 동작(자막 전체에 의존 → 시각만 바뀌어도 다시 계산)을 재현할 때만 넣는다. 보통 nil.
    var legacyProbe: SubtitleItem? = nil
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.stored == b.stored && a.project == b.project && a.store === b.store && a.legacyProbe == b.legacyProbe }
    #if DEBUG
    /// 자체 검사 전용: body 계산 수
    nonisolated(unsafe) static var bodyCountForTest = 0
    #endif
    /// 설치된 글꼴 가족(한 번만 읽음, 앱을 다시 열면 갱신)
    static let families: [String] = NSFontManager.shared.availableFontFamilies
    @State private var size = "48"
    @State private var hex = "#FFFFFF"
    @State private var opacity = "100"
    @State private var x = "960"
    @State private var y = "990"
    /// 기본 팔레트 20색(D-039): 무채색 5, 선명한 색 8, 부드러운 색 7. sRGB 0–255. 고르면 RGB만 바꾸고 불투명도는 그대로.
    struct Preset: Equatable { let name: String; let r: Int, g: Int, b: Int }
    static let palette: [Preset] = [
        .init(name: "흰색", r: 255, g: 255, b: 255), .init(name: "밝은 회색", r: 204, g: 204, b: 204), .init(name: "회색", r: 128, g: 128, b: 128),
        .init(name: "어두운 회색", r: 64, g: 64, b: 64), .init(name: "검정", r: 0, g: 0, b: 0), .init(name: "빨강", r: 230, g: 40, b: 40),
        .init(name: "주황", r: 255, g: 140, b: 0), .init(name: "노랑", r: 255, g: 214, b: 0), .init(name: "초록", r: 40, g: 180, b: 70),
        .init(name: "청록", r: 0, g: 190, b: 200),
        .init(name: "파랑", r: 40, g: 120, b: 230), .init(name: "남색", r: 40, g: 50, b: 140), .init(name: "보라", r: 140, g: 70, b: 200),
        .init(name: "분홍", r: 240, g: 90, b: 160), .init(name: "갈색", r: 140, g: 90, b: 50), .init(name: "연노랑", r: 255, g: 240, b: 170),
        .init(name: "연분홍", r: 255, g: 200, b: 215), .init(name: "연하늘", r: 180, g: 220, b: 255), .init(name: "연두", r: 200, g: 240, b: 170),
        .init(name: "연보라", r: 215, g: 200, b: 245),
    ]
    /// 작은 조작 글꼴(11 pt, 숫자 같은 폭) — 줄이지 않은 표준 작은 크기
    static let fieldFont = Font.system(size: NSFont.smallSystemFontSize).monospacedDigit()
    var allColors: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("모든 색").font(.caption).fixedSize()
            CurrentColorWell(color: NSColor(srgbRed: CGFloat(style.red) / 255, green: CGFloat(style.green) / 255, blue: CGFloat(style.blue) / 255,
                                            alpha: CGFloat(style.alpha) / 255)) { c in let st = Self.styled(style, from: c); setColor(st.red, st.green, st.blue, st.alpha) }
                .frame(width: 40, height: 21)   // 작은 글 칸 높이(21 pt, 배치 검사로 잼)와 같게
        }
    }
    var hexField: some View {
        TextField("#RRGGBB", text: $hex).textFieldStyle(.roundedBorder).font(Self.fieldFont).frame(width: 70)
            .onSubmit(commitHex).accessibilityLabel("글자 색(16진수)").help("글자 색(16진수 #RRGGBB)")
    }
    var opacityField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            TextField("100", text: $opacity).textFieldStyle(.roundedBorder).font(Self.fieldFont).frame(width: 36)
                .onSubmit(commitOpacity)
                .accessibilityLabel("불투명도 퍼센트").help("불투명도(%): 0 = 투명, 100 = 불투명")
            Text("%").font(.caption).fixedSize().accessibilityHidden(true)
        }
    }
    /// 지금 색과 RGB가 같은 팔레트 칸(불투명도는 보지 않음)
    static func presetIndex(_ st: SubtitleStyle) -> Int? { palette.firstIndex { $0.r == st.red && $0.g == st.green && $0.b == st.blue } }

    var style: SubtitleStyle { store.colorSession.flatMap { $0.id == id ? $0.current : nil } ?? stored }
    /// 색 바꾸기(팔레트·색 패널·HEX·불투명도 모두 이 길): 색 조정 세션에 넣는다. 이 칸을 그린 프로젝트 회차를 함께 보낸다(늦은 값 거름).
    func setColor(_ r: Int, _ g: Int, _ b: Int, _ a: Int) {
        store.colorEditChange(id, red: r, green: g, blue: b, alpha: a, project: project)
    }
    /// 지금 색(sRGB)
    var color: Color { Color(.sRGB, red: Double(style.red) / 255, green: Double(style.green) / 255, blue: Double(style.blue) / 255, opacity: Double(style.alpha) / 255) }
    /// 색 고르개 값 → 저장 표현(sRGB 0–255 정수, 불투명도 포함). 다른 색 공간(예: 넓은 색역)은 sRGB로 바꾼 뒤 범위 안으로 자른다.
    static func styled(_ base: SubtitleStyle, from c: Color) -> SubtitleStyle { styled(base, from: NSColor(c)) }
    static func styled(_ base: SubtitleStyle, from c: NSColor) -> SubtitleStyle {
        var st = base
        guard let ns = c.usingColorSpace(.sRGB) else { return st }
        func q(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        st.red = q(ns.redComponent); st.green = q(ns.greenComponent); st.blue = q(ns.blueComponent); st.alpha = q(ns.alphaComponent)
        return st
    }
    var body: some View {
        #if DEBUG
        let _ = { Self.bodyCountForTest += 1 }()
        #endif
        VStack(alignment: .leading, spacing: 8) {
            if !SubtitleRenderer.fontAvailable(style.fontName) {
                Label("이 Mac에 없는 글꼴: \(style.fontName) — 시스템 글꼴로 그립니다(파일의 글꼴 이름은 그대로).", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            fontPickers
            HStack(spacing: 4) {
                Text("크기").font(.caption).frame(width: 34, alignment: .leading)
                TextField("pt", text: $size).textFieldStyle(.roundedBorder).frame(width: 64).onSubmit(commitSize).accessibilityLabel("글자 크기")
                Text("pt (8–300, 출력 1080 기준)").font(.caption2).foregroundStyle(.secondary)
            }
            // 색(D-039): 기본 팔레트 20색(두 줄) 위, 그 아래 지금 색 상자(시스템 색 패널: 휠·스펙트럼·불투명도), HEX·불투명도 칸.
            // 시스템 패널의 보조 영역(accessoryView)은 놓이는 자리를 시스템이 정해 스펙트럼 위에 둘 수 없으므로, 팔레트는 이 칸에 둔다.
            // 모두 한 색 조정 세션(패널 닫힘·다른 편집·다른 것 고르기 때 한 단계).
            // 배치(2026-10-23 소유자 정리): 1) "색" 2) 팔레트 20색 두 줄 열 칸(좁은 패널에서도 잘리지 않게 칸 크기가 폭을 따라 8–22 pt)
            // 3) "모든 색" + 남은 폭을 쓰는 지금 색 상자 4) HEX·불투명도 한 줄(작은 크기, 글자 기준선 맞춤). 모든 줄의 왼쪽 끝이 같다.
            VStack(alignment: .leading, spacing: 6) {
                Text("색").font(.caption)
                let sel = Self.presetIndex(style)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 8, maximum: 22), spacing: 3), count: 10), alignment: .leading, spacing: 3) {
                    ForEach(Self.palette.indices, id: \.self) { i in
                        let pc = Self.palette[i]
                        Button { setColor(pc.r, pc.g, pc.b, style.alpha) } label: {
                            RoundedRectangle(cornerRadius: 3).fill(Color(.sRGB, red: Double(pc.r) / 255, green: Double(pc.g) / 255, blue: Double(pc.b) / 255))
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(sel == i ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: sel == i ? 2.5 : 1))
                        }
                        .buttonStyle(.plain).help(pc.name)
                        .accessibilityLabel(pc.name + (sel == i ? ", 선택됨" : ""))
                        .accessibilityAddTraits(sel == i ? .isSelected : [])
                    }
                }
                // 지금 색 상자·HEX·불투명도(2026-10-23 소유자 정리): 들어가면 한 줄(보통 폭), 글자를 줄이거나 자르지 않고는 안 들어가면 두 줄.
                // 색 상자와 HEX 칸은 늘이지 않는다(고정 폭). 높이는 작은 조작 크기로 맞춘다.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 6) { allColors; hexField; opacityField }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) {
                        allColors
                        HStack(alignment: .center, spacing: 6) { hexField; opacityField }
                    }.fixedSize(horizontal: true, vertical: false)
                }
                .controlSize(.small)
            }
            EffectsAdjust(store: store, id: id, style: style, project: project)
            HStack(spacing: 4) {
                Text("정렬").font(.caption).frame(width: 34, alignment: .leading)
                Picker("정렬", selection: Binding(get: { style.alignment }, set: { setAlignment($0) })) {
                    Image(systemName: "text.alignleft").tag(SubtitleStyle.Alignment.left).help("왼쪽")
                    Image(systemName: "text.aligncenter").tag(SubtitleStyle.Alignment.center).help("가운데")
                    Image(systemName: "text.alignright").tag(SubtitleStyle.Alignment.right).help("오른쪽")
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(spacing: 4) {
                Text("위치").font(.caption).frame(width: 34, alignment: .leading)
                Text("X").font(.caption2)
                // 좁은 패널(최소 160 pt)에서 이 줄이 가장 넓어 모양 칸 전체(색 칸 포함)를 밀어냈다: 칸 폭을 남은 폭에 맞춘다(배치만 바꿈)
                TextField("X", text: $x).textFieldStyle(.roundedBorder).frame(minWidth: 28, maxWidth: 64).onSubmit(commitPosition).accessibilityLabel("가로 위치")
                Text("Y").font(.caption2)
                TextField("Y", text: $y).textFieldStyle(.roundedBorder).frame(minWidth: 28, maxWidth: 64).onSubmit(commitPosition).accessibilityLabel("세로 위치")
            }
            HStack {
                Text("").frame(width: 34)
                Button("기본 위치") { apply { $0.xMilli = Self.defaultX($0.alignment) * 1000; $0.yMilli = SubtitleStyle.default.yMilli } }.controlSize(.small)
                Button("기본 모양") { apply { $0 = .default } }.controlSize(.small)
            }
            Text("위치는 출력 화면(1920×1080) 픽셀, 왼쪽 위가 0입니다. X는 정렬 기준점(왼쪽 끝·가운데·오른쪽 끝), Y는 글자 상자 아래 끝입니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(store.gestureBase != nil)
        .onAppear(perform: load)
        .onChange(of: style) { _, _ in load() }   // 저장 값·색 조정 세션 값 모두(HEX·불투명도 칸 맞춤)
    }

    /// 글꼴 가족·굵기(설치된 글꼴). 저장값이 없는 글꼴이면 그 이름을 그대로 보인다.
    @ViewBuilder var fontPickers: some View {
        let fm = NSFontManager.shared
        let family = NSFont(name: style.fontName, size: 12).flatMap { $0.familyName }
        HStack(spacing: 4) {
            Text("글꼴").font(.caption).frame(width: 34, alignment: .leading)
            Picker("글꼴", selection: Binding(get: { family ?? "" }, set: { setFamily($0) })) {
                if family == nil { Text("\(style.fontName) (없음)").tag("") }
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().accessibilityLabel("글꼴")
        }
        if let family {
            let members = (fm.availableMembers(ofFontFamily: family) ?? []).compactMap { m -> (String, String)? in
                guard let ps = m.first as? String, let face = m.dropFirst().first as? String else { return nil }
                return (ps, face)
            }
            HStack(spacing: 4) {
                Text("굵기").font(.caption).frame(width: 34, alignment: .leading)
                Picker("굵기", selection: Binding(get: { style.fontName }, set: { n in apply { $0.fontName = n } })) {
                    ForEach(members, id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden().accessibilityLabel("글꼴 굵기")
            }
        }
    }

    static func defaultX(_ a: SubtitleStyle.Alignment) -> Int {
        switch a {
        case .left: SubtitleStyle.sideMargin
        case .center: SubtitleStyle.outputWidth / 2
        case .right: SubtitleStyle.outputWidth - SubtitleStyle.sideMargin
        }
    }
    func apply(_ f: (inout SubtitleStyle) -> Void) {
        var s = style; f(&s)
        store.setSubtitleStyle(id, s)   // 다른 모양 바꿈: 먼저 색 조정 세션이 끝난다(commit 앞 확정)
        load()
    }
    func load() {
        size = NumberText.trim(style.size, 1)
        hex = String(format: "#%02X%02X%02X", style.red, style.green, style.blue)
        opacity = String(Int((Double(style.alpha) * 100 / 255).rounded()))
        x = NumberText.trim(style.x, 3); y = NumberText.trim(style.y, 3)
    }
    func setFamily(_ fam: String) {
        guard !fam.isEmpty else { return }
        // 같은 굵기 이름이 있으면 그것, 없으면 가족의 첫 글꼴(보통 Regular)
        let fm = NSFontManager.shared
        let members = fm.availableMembers(ofFontFamily: fam) ?? []
        let curFace = NSFont(name: style.fontName, size: 12).flatMap { f in
            (fm.availableMembers(ofFontFamily: f.familyName ?? "") ?? []).first { ($0.first as? String) == style.fontName }?.dropFirst().first as? String
        }
        let pick = members.first { ($0.dropFirst().first as? String) == curFace } ?? members.first
        if let ps = pick?.first as? String { apply { $0.fontName = ps } }
    }
    func commitSize() {
        guard let v = Double(size.trimmingCharacters(in: .whitespaces)) else { load(); return }
        let t = min(max(Int((v * 10).rounded()), SubtitleStyle.sizeTenthsRange.lowerBound), SubtitleStyle.sizeTenthsRange.upperBound)
        apply { $0.sizeTenths = t }
    }
    func commitHex() {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { load(); return }
        setColor((v >> 16) & 255, (v >> 8) & 255, v & 255, style.alpha)   // 색 조정 세션
    }
    func commitOpacity() {
        guard let v = Double(opacity.trimmingCharacters(in: .whitespaces)) else { load(); return }
        setColor(style.red, style.green, style.blue, Int((min(max(v, 0), 100) * 255 / 100).rounded()))   // 색 조정 세션
    }
    func commitPosition() {
        guard let vx = Double(x.trimmingCharacters(in: .whitespaces)), let vy = Double(y.trimmingCharacters(in: .whitespaces)) else { load(); return }
        // 출력 화면 안(0…1920, 0…1080)으로 맞춘다
        let cx = min(max(vx, 0), Double(SubtitleStyle.outputWidth)), cy = min(max(vy, 0), Double(SubtitleStyle.outputHeight))
        apply { $0.xMilli = Int((cx * 1000).rounded()); $0.yMilli = Int((cy * 1000).rounded()) }
    }
    /// 정렬 바꾸기: 가로 위치가 이전 정렬의 기본값이면 새 정렬의 기본값으로 옮긴다(아니면 그대로)
    func setAlignment(_ a: SubtitleStyle.Alignment) {
        guard a != style.alignment else { return }
        apply {
            if $0.xMilli == Self.defaultX($0.alignment) * 1000 { $0.xMilli = Self.defaultX(a) * 1000 }
            $0.alignment = a
        }
    }
}

/// 지금 색 상자(2026-10-23): 시스템 색 상자(NSColorWell, 기본 모양 — 누르면 시스템 색 패널: 휠·스펙트럼·불투명도)를 남은 폭으로 넓혀 쓴다.
/// SwiftUI ColorPicker는 같은 색 상자를 48 pt로 고정해 넓힐 수 없었다(배치 검사로 확인). 값은 패널이 보내는 대로 onChange(색 조정 세션)로 넘긴다.
/// 색 상자 테두리가 밝은·어두운 바탕 모두에서 지금 색을 구별되게 한다.
struct CurrentColorWell: NSViewRepresentable {
    let color: NSColor
    let onChange: (NSColor) -> Void
    final class Coordinator: NSObject {
        var onChange: (NSColor) -> Void
        init(_ f: @escaping (NSColor) -> Void) { onChange = f }
        @MainActor @objc func changed(_ w: NSColorWell) { onChange(w.color) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onChange) }
    func makeNSView(context: Context) -> NSColorWell {
        let w = NSColorWell(style: .default)
        w.supportsAlpha = true
        w.color = color
        w.target = context.coordinator
        w.action = #selector(Coordinator.changed(_:))
        w.toolTip = "지금 글자 색. 누르면 색 패널(휠·스펙트럼·불투명도)이 열립니다"
        w.setAccessibilityLabel("지금 글자 색")
        w.setAccessibilityHelp("누르면 색 패널(휠·스펙트럼·불투명도)이 열립니다")
        w.setContentHuggingPriority(.defaultLow, for: .horizontal)
        w.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return w
    }
    /// 크기는 놓인 자리가 정한다(색 상자의 고유 높이 24 pt 대신, 옆 글 칸과 같은 높이를 줄 수 있게)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSColorWell, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 40, height: proposal.height ?? 21)
    }
    func updateNSView(_ w: NSColorWell, context: Context) {
        context.coordinator.onChange = onChange
        // 주변 조작과 같은 크기(작은 조작이면 작은 색 상자 — 높이를 글 칸과 맞춤)
        let cs: NSControl.ControlSize = context.environment.controlSize == .small ? .small : (context.environment.controlSize == .mini ? .mini : .regular)
        if w.controlSize != cs { w.controlSize = cs }
        if !w.color.isEqual(color) { w.color = color }   // 패널이 보낸 값과 같으면 다시 넣지 않음(되먹임 없음)
    }
}

// MARK: - 효과(외곽선·그림자·배경, 2026-10-23, D-040)

/// 효과 칸: 접을 수 있는 세 묶음(외곽선·그림자·배경), 묶음 이름 옆 켜기. 켜면 기본값(소유자 지정)으로 시작하고, 껐다 켜면 전에 쓴 값을 되살린다.
/// 모든 조정(켜기·색·불투명도·숫자)은 모양 조정 세션(styleEditChange) — 한 묶음 = 실행 취소 한 단계, 프리뷰 자막 층만 바뀜(영상 그대로).
/// 숫자 단위는 출력 1080p 픽셀(0.1 px까지). 효과는 확정된 자막 그림에 보인다(프리뷰 위 글 편집 칸에는 글자만).
struct EffectsAdjust: View {
    @Bindable var store: ProjectStore
    let id: UUID
    let style: SubtitleStyle
    let project: Int
    @State private var openOutline = false
    @State private var openShadow = false
    @State private var openBackground = false

    func edit(_ f: (inout SubtitleStyle) -> Void) { store.styleEditChange(id, project: project, f) }
    func nsColor(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("효과").font(.caption)
            DisclosureGroup(isExpanded: $openOutline) {
                if let o = style.outline { VStack(alignment: .leading, spacing: 4) {
                    colorRow(o.red, o.green, o.blue, o.alpha) { r, g, b, a in edit { $0.outline?.red = r; $0.outline?.green = g; $0.outline?.blue = b; $0.outline?.alpha = a } }
                    TenthsField(label: "두께", value: o.widthTenths, range: SubtitleOutline.widthRange) { v in edit { $0.outline?.widthTenths = v } }
                }.frame(maxWidth: .infinity, alignment: .leading) }   // 묶음 안 줄은 왼쪽 맞춤(DisclosureGroup 기본은 가운데)
            } label: {
                Toggle("외곽선", isOn: Binding(get: { style.outline?.enabled == true }, set: { on in
                    edit { if $0.outline == nil { $0.outline = .default }; $0.outline?.enabled = on }; if on { openOutline = true } }))
                    .font(.caption).toggleStyle(.checkbox)
            }
            DisclosureGroup(isExpanded: $openShadow) {
                if let sh = style.shadow { VStack(alignment: .leading, spacing: 4) {
                    colorRow(sh.red, sh.green, sh.blue, sh.alpha) { r, g, b, a in edit { $0.shadow?.red = r; $0.shadow?.green = g; $0.shadow?.blue = b; $0.shadow?.alpha = a } }
                    pair(TenthsField(label: "가로", value: sh.offsetXTenths, range: SubtitleShadow.offsetRange) { v in edit { $0.shadow?.offsetXTenths = v } },
                         TenthsField(label: "세로", value: sh.offsetYTenths, range: SubtitleShadow.offsetRange) { v in edit { $0.shadow?.offsetYTenths = v } },
                         caption: "거리(오른쪽·아래 +)")
                    TenthsField(label: "흐림", value: sh.blurTenths, range: SubtitleShadow.blurRange) { v in edit { $0.shadow?.blurTenths = v } }
                }.frame(maxWidth: .infinity, alignment: .leading) }   // 묶음 안 줄은 왼쪽 맞춤(DisclosureGroup 기본은 가운데)
            } label: {
                Toggle("그림자", isOn: Binding(get: { style.shadow?.enabled == true }, set: { on in
                    edit { if $0.shadow == nil { $0.shadow = .default }; $0.shadow?.enabled = on }; if on { openShadow = true } }))
                    .font(.caption).toggleStyle(.checkbox)
            }
            DisclosureGroup(isExpanded: $openBackground) {
                if let bg = style.background { VStack(alignment: .leading, spacing: 4) {
                    colorRow(bg.red, bg.green, bg.blue, bg.alpha) { r, g, b, a in edit { $0.background?.red = r; $0.background?.green = g; $0.background?.blue = b; $0.background?.alpha = a } }
                    pair(TenthsField(label: "가로", value: bg.padXTenths, range: SubtitleBackground.padRange) { v in edit { $0.background?.padXTenths = v } },
                         TenthsField(label: "세로", value: bg.padYTenths, range: SubtitleBackground.padRange) { v in edit { $0.background?.padYTenths = v } },
                         caption: "여백")
                    TenthsField(label: "모서리", value: bg.radiusTenths, range: SubtitleBackground.radiusRange) { v in edit { $0.background?.radiusTenths = v } }
                }.frame(maxWidth: .infinity, alignment: .leading) }   // 묶음 안 줄은 왼쪽 맞춤(DisclosureGroup 기본은 가운데)
            } label: {
                Toggle("배경", isOn: Binding(get: { style.background?.enabled == true }, set: { on in
                    edit { if $0.background == nil { $0.background = .default }; $0.background?.enabled = on }; if on { openBackground = true } }))
                    .font(.caption).toggleStyle(.checkbox)
            }
            Text("효과는 확정된 자막 그림에 보입니다(프리뷰 위 글 편집 칸에서는 글자만). 단위: 출력 1080p 픽셀.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
        .onAppear {
            openOutline = style.outline?.enabled == true; openShadow = style.shadow?.enabled == true; openBackground = style.background?.enabled == true
        }
    }

    /// 색 상자(시스템 색 패널) + 불투명도(%)
    func colorRow(_ r: Int, _ g: Int, _ b: Int, _ a: Int, set: @escaping (Int, Int, Int, Int) -> Void) -> some View {
        HStack(alignment: .center, spacing: 6) {   // 묶음 이름(외곽선·그림자·배경)이 무엇의 색인지 말해 준다 — 좁은 패널에 맞게 "색" 이름표는 두지 않음
            CurrentColorWell(color: nsColor(r, g, b, a)) { c in
                let st = SubtitleStyleAdjust.styled(.default, from: c); set(st.red, st.green, st.blue, st.alpha)
            }
            .frame(width: 40, height: 21)
            .accessibilityLabel("효과 색")
            OpacityField(alpha: a) { na in set(r, g, b, na) }
        }
    }
    /// 숫자 두 칸: 들어가면 한 줄, 아니면 두 줄(글자를 줄이거나 자르지 않음)
    func pair<A: View, B: View>(_ a: A, _ b: B, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.caption2).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { a; b }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) { a; b }.fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// 0.1 px 단위 숫자 칸(표시는 px, 소수 첫째 자리). Return에 범위 안으로 맞춰 넘긴다(크기·위치 칸과 같음 — 칸을 떠나기만 하면 넘기지 않는다).
struct TenthsField: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let commit: (Int) -> Void
    @State private var text = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label).font(.caption).frame(width: 34, alignment: .leading)
            TextField("px", text: $text).textFieldStyle(.roundedBorder).font(SubtitleStyleAdjust.fieldFont).frame(width: 52)
                .onSubmit(apply).accessibilityLabel(label + " (px)")
                .help("\(label): \(NumberText.trim(Double(range.lowerBound) / 10, 1))–\(NumberText.trim(Double(range.upperBound) / 10, 1)) px")
            Text("px").font(.caption2).fixedSize().accessibilityHidden(true)
        }
        .onAppear { text = NumberText.trim(Double(value) / 10, 1) }
        .onChange(of: value) { _, v in text = NumberText.trim(Double(v) / 10, 1) }
    }
    func apply() {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite else { text = NumberText.trim(Double(value) / 10, 1); return }
        let t = min(max(Int((v * 10).rounded()), range.lowerBound), range.upperBound)
        commit(t)
        text = NumberText.trim(Double(value) / 10, 1)   // 받아들이지 않았거나 같은 값이면 지금 값을 보인다(바뀌면 onChange가 새 값으로)
    }
}

/// 불투명도(%) 칸
struct OpacityField: View {
    let alpha: Int
    let commit: (Int) -> Void
    @State private var text = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            TextField("%", text: $text).textFieldStyle(.roundedBorder).font(SubtitleStyleAdjust.fieldFont).frame(width: 36)
                .onSubmit(apply).accessibilityLabel("불투명도 퍼센트").help("불투명도(%): 0 = 투명, 100 = 불투명")
            Text("%").font(.caption).fixedSize().accessibilityHidden(true)
        }
        .onAppear { text = String(Int((Double(alpha) * 100 / 255).rounded())) }
        .onChange(of: alpha) { _, a in text = String(Int((Double(a) * 100 / 255).rounded())) }
    }
    func apply() {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite else { text = String(Int((Double(alpha) * 100 / 255).rounded())); return }
        commit(Int((min(max(v, 0), 100) * 255 / 100).rounded()))
        text = String(Int((Double(alpha) * 100 / 255).rounded()))   // 받아들이지 않았거나 같은 값이면 지금 값을 보인다(바뀌면 onChange가 새 값으로)
    }
}

private extension SubtitleOutline { var disabled: Self { var d = self; d.enabled = false; return d } }
private extension SubtitleShadow { var disabled: Self { var d = self; d.enabled = false; return d } }
private extension SubtitleBackground { var disabled: Self { var d = self; d.enabled = false; return d } }
