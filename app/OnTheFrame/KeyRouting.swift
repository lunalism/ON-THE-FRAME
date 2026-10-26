import AppKit
import OnTheFrameEngine

/// 편집기 단축키 경로(흔히 쓰는 기본 단축키, D-019·D-027. 다른 편집기와의 완전 호환을 주장하지 않는다).
/// 처리 층(2026-10-10 한국어 입력 소스 대응):
/// 1. 로컬 키 감시(ProjectStore.attachEditorWindow): 이벤트 큐에서 꺼낸 모든 키 이벤트를 먼저 본다. 키 창이 없어도 본다.
/// 2. 보조: 편집기 창 보기의 performKeyEquivalent(⌘ 조합, WindowAccessor)와 타임라인 보기의 keyDown(수정 키 없는 키).
///    앱 sendEvent를 거치지 않고 창에 바로 전달되는 경로가 있을 경우에 대비한 것이다(그런 경로는 확인되지 않음).
///    로컬 감시는 sendEvent 안에서 불린다는 것을 검사로 확인했다. 따라서 sendEvent로 다시 전달된 이벤트는 1층이 본다.
/// 모든 층은 같은 판단(route)을 쓰고, 이미 처리한 이벤트는 다시 처리하지 않는다(한 번 누름 = 한 번 동작).
/// `-OTFKeyTrace` 실행 인수를 주면 층별 경로를 기록한다(KeyTrace).
///
/// - 수정 키 없는 키(Space, ←/→, Home/End, Delete·⌫, 도구 V·C)는 메뉴 키 등가물로 두지 않는다. 메뉴 키 등가물은 텍스트 입력보다 먼저
///   처리되어 글자 입력·커서 이동·삭제를 가로채기 때문이다. 대신 이 라우터(위 처리 층)에서만 처리하고,
///   다음 조건을 모두 만족할 때만 실행한다. 아니면 이벤트를 건드리지 않고 그대로 보낸다.
///   편집기 창이 키 창 · 시트·모달 없음 · 텍스트 입력에 초점 없음 · 드래그 중 아님 · 동작이 켜져 있음.
/// - ⌘ 단축키(⌘K 자르기, ⌘Z/⇧⌘Z, ⌘E)도 이 라우터가 실제 상태로 판단해 처리하고 이벤트를 소비한다(한 번만 실행).
///   SwiftUI 메뉴 항목의 사용 가능 상태는 메뉴를 열 때(menuNeedsUpdate)만 갱신되어, 실행 때 꺼져 있던 항목의 키 등가물이
///   상태가 바뀐 뒤에도 동작하지 않았다(단축키 자체 검사로 확인). 메뉴는 표시·마우스 선택용으로 둔다.
///   편집기 창의 텍스트 입력에 초점이 있으면 ⌘Z/⇧⌘Z는 응답자 체인(`undo:`/`redo:`)으로 넘겨 텍스트 실행 취소가 되게 하고,
///   ⌘K·⌘E는 처리하지 않는다. 시트·모달·다른 창이 키 창이면 아무것도 처리하지 않고 그대로 보낸다.
/// - Esc(드래그 취소)는 타임라인 보기가 직접 처리한다(TimelineNSView.cancelOperation).
@MainActor
enum KeyRouting {
    enum BareKeyAction: Equatable { case playPause, stepBackward, stepForward, toStart, toEnd, deleteSelection, rippleDelete, selectionTool, cutTool, textTool }

    /// 키 코드(가상 키) → 동작. 수정 키(⌘⌥⌃⇧)가 있으면 nil(예: ⇧← 등은 처리하지 않음).
    /// 예외: ⇧Delete·⇧⌫·⇧⌦는 리플 삭제(D-020). 수정 키 없는 Delete·⌫·⌦는 빈틈을 남기는 삭제.
    /// 반복 입력은 프레임 이동에만 허용한다(누르고 있으면 계속 이동). Space·Delete·V·C 반복은 동작하지 않는다.
    /// 도구 V·C(2026-10-11, D-030)는 물리 키 코드(V=9, C=8)로 맞춰 한국어 입력 소스(ㅍ·ㅊ)에서도 같다.
    static func bareKeyAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> BareKeyAction? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        if mods == [.shift], keyCode == 51 || keyCode == 117 { return isRepeat ? nil : .rippleDelete }
        guard mods.isEmpty else { return nil }
        let a: BareKeyAction?
        switch keyCode {
        case 49: a = .playPause            // Space
        case 123: a = .stepBackward        // ←
        case 124: a = .stepForward         // →
        case 115: a = .toStart             // Home
        case 119: a = .toEnd               // End
        case 51, 117: a = .deleteSelection // ⌫(Delete), ⌦(Forward Delete)
        case 9: a = .selectionTool         // V(한국어 ㅍ)
        case 8: a = .cutTool               // C(한국어 ㅊ)
        case 17: a = .textTool             // T(한국어 ㅅ, 2026-10-22): 도구만 바꾼다(자막을 만들지 않음)
        default: a = nil
        }
        if isRepeat, a != .stepBackward, a != .stepForward { return nil }
        return a
    }

    enum CommandAction: Equatable { case split, undo, redo, export, newProject, openProject, save, saveAs, copy, paste }

    /// ⌘ 조합 → 명령. 글자는 수정 키를 뺀 문자로 맞추고, 한글 등 라틴 문자가 아닌 입력 소스에서는 키 코드(ANSI)로 맞춘다.
    static func commandAction(keyCode: UInt16, charactersIgnoringModifiers: String?, modifiers: NSEvent.ModifierFlags) -> CommandAction? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        let c = charactersIgnoringModifiers?.lowercased() ?? ""
        let latin = !c.isEmpty && c.unicodeScalars.allSatisfy { $0.isASCII }
        func letter(_ ch: String, _ code: UInt16) -> Bool { latin ? c == ch : keyCode == code }
        if mods == [.command] {
            if letter("k", 40) { return .split }
            if letter("z", 6) { return .undo }
            if letter("e", 14) { return .export }
            if letter("n", 45) { return .newProject }
            if letter("o", 31) { return .openProject }
            if letter("s", 1) { return .save }
            if letter("c", 8) { return .copy }    // 2026-10-11 클립 복사(텍스트 입력 중이면 텍스트로 넘김)
            if letter("v", 9) { return .paste }
        }
        if mods == [.command, .shift], letter("z", 6) { return .redo }
        if mods == [.command, .shift], letter("s", 1) { return .saveAs }
        return nil
    }

    /// 텍스트 입력 중인가: 첫 응답자가 텍스트 보기(NSTextField·SwiftUI TextField의 필드 편집기, NSTextView)인 경우.
    static func isTextInput(_ r: NSResponder?) -> Bool { r is NSText }

    /// 편집기 단축키를 받을 수 있는 상태인가(창·모달·텍스트 초점)
    /// - 편집기 창이 키 창이면: 첫 응답자가 텍스트 입력이 아닐 때
    /// - 편집기 창이 주 창이고 키 창이 없거나 보조 창(주 창이 될 수 없고 시트가 아니며 텍스트 입력 중이 아님)일 때도 받는다.
    ///   입력 소스를 바꿀 때 앱 안에 입력 소스 표시 창(TextInputUI)이 잠깐 생기는 것을 소유자 세션 기록에서 보았다.
    ///   그 창이 키 상태를 가져가도 편집기 단축키가 끊기지 않게 하려는 것이다(원인 후보 대응, 미확정).
    static func editorAcceptsShortcuts(_ store: ProjectStore) -> Bool {
        guard let w = store.editorWindow, w.attachedSheet == nil, NSApp.modalWindow == nil, !store.alerts.isShowing else { return false }
        if NSApp.keyWindow === w { return !isTextInput(w.firstResponder) }
        #if DEBUG
        if testStrictKeyWindow { return false }
        #endif
        guard NSApp.isActive, NSApp.mainWindow === w else { return false }
        if let k = NSApp.keyWindow {
            guard !k.canBecomeMain, k.sheetParent == nil, !k.isModalPanel, !isTextInput(k.firstResponder) else { return false }
        }
        return !isTextInput(w.firstResponder)
    }

    /// 이벤트 창이 편집기 창이거나, 편집기가 단축키를 받는 상태에서의 보조 키 창·창 없음인가
    static func eventWindowOK(_ e: NSEvent, _ store: ProjectStore) -> Bool {
        guard let w = store.editorWindow else { return false }
        return e.window === w || e.window == nil || (e.window === NSApp.keyWindow && NSApp.keyWindow !== w)
    }

    #if DEBUG
    /// 자체 검사의 음성 대조 전용: 완화한 창 조건을 끈다(이전의 엄격한 조건).
    static var testStrictKeyWindow = false
    #endif

    /// 이미 처리한 이벤트 표식(시각·키 코드·종류). 여러 층이 같은 이벤트를 보더라도 한 번만 처리한다.
    private static var lastHandled: (TimeInterval, UInt16, UInt)?

    /// 각 처리 층에서 부른다. 처리(소비)했으면 true.
    static func route(_ e: NSEvent, layer: String, store: ProjectStore) -> Bool {
        guard e.type == .keyDown else { return false }
        KeyTrace.log(layer, e, store: store)
        let token = (e.timestamp, e.keyCode, e.type.rawValue)
        if let l = lastHandled, l == token {
            KeyTrace.decision("alreadyHandled@\(layer)", e)
            return true
        }
        let consumed = handle(e, store: store) == nil
        if consumed { lastHandled = token }
        KeyTrace.decision(consumed ? "handled@\(layer)" : "passed@\(layer)", e)
        store.refreshFocus()
        return consumed
    }

    /// 판단과 실행. 처리하면 nil(소비), 아니면 이벤트를 그대로 돌려준다.
    static func handle(_ e: NSEvent, store: ProjectStore) -> NSEvent? {
        if let cmd = commandAction(keyCode: e.keyCode, charactersIgnoringModifiers: e.charactersIgnoringModifiers, modifiers: e.modifierFlags) {
            return handleCommand(cmd, e, store: store)
        }
        guard let action = bareKeyAction(keyCode: e.keyCode, modifiers: e.modifierFlags, isRepeat: e.isARepeat) else {
            // 반복된 Space·Delete는 편집기 문맥이면 조용히 버린다(한 번 누름 = 한 번 동작).
            if e.isARepeat, [49, 51, 117, 8, 9, 17].contains(e.keyCode),
               e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
               editorAcceptsShortcuts(store), eventWindowOK(e, store) { return nil }
            return e
        }
        guard eventWindowOK(e, store), editorAcceptsShortcuts(store), store.gestureBase == nil else { return e }
        switch action {
        case .playPause:
            guard store.canPlay else { return e }
            store.togglePlay()
        case .stepBackward, .stepForward, .toStart, .toEnd:
            guard !store.timeline.isEmpty else { return e }
            switch action {
            case .stepBackward: store.step(-1)
            case .stepForward: store.step(1)
            case .toStart: store.pauseForEdit(); store.seek(to: 0)
            default: store.pauseForEdit(); store.seek(to: store.durationFrames)
            }
        case .deleteSelection, .rippleDelete:
            guard store.selection != nil else { return e }
            store.deleteSelection(ripple: action == .rippleDelete)
        case .selectionTool: store.setTool(.selection)   // 도구만 바꾼다(재생·재생 헤드·선택·편집 그대로)
        case .cutTool: store.setTool(.cut)
        case .textTool: store.setTool(.text)
        }
        return nil
    }

    private static func handleCommand(_ cmd: CommandAction, _ e: NSEvent, store: ProjectStore) -> NSEvent? {
        guard let w = store.editorWindow, eventWindowOK(e, store), w.attachedSheet == nil,
              NSApp.modalWindow == nil, !store.alerts.isShowing else { return e }
        if NSApp.keyWindow === w, isTextInput(w.firstResponder) {
            switch cmd {
            case .undo: NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); return nil
            case .redo: NSApp.sendAction(Selector(("redo:")), to: nil, from: nil); return nil
            case .split, .export, .newProject, .openProject, .save, .saveAs, .copy, .paste: return e   // 텍스트 입력 중: 메뉴(응답자 체인 → 텍스트 복사·붙여넣기)로
            }
        }
        guard editorAcceptsShortcuts(store) else { return e }
        if e.isARepeat { return nil }   // 누르고 있어도 한 번
        var done = false
        switch cmd {
        // 초점은 위에서 실제 상태로 확인했다. 캐시된 editorFocused(store.canSplit)는 키 창 변화 알림이 늦으면 낡을 수 있어 쓰지 않는다.
        case .split: if !store.timeline.isEmpty, store.alert == nil, store.gestureBase == nil { store.splitAtPlayhead(); done = true }
        case .undo: if store.gestureBase == nil, store.history.canUndo || store.colorSession != nil { store.undo(); done = true }   // 색 조정 세션: 끝내고 되돌림(D-039)
        case .redo: if store.gestureBase == nil, store.history.canRedo { store.redo(); done = true }
        case .export: if store.gestureBase == nil, store.exportBlockReason != nil || store.canExport { store.presentExportPanel(); done = true }
        // 프로젝트 파일(A-013): 한국어 입력 소스에서도 한 번만 동작하도록 라우터가 처리한다
        case .newProject: if store.gestureBase == nil { store.requestNewProject(); done = true }
        case .openProject: if store.gestureBase == nil { store.requestOpenProject(nil); done = true }
        case .save: if store.gestureBase == nil { store.saveProject(); done = true }
        case .saveAs: if store.gestureBase == nil { store.saveProject(saveAs: true); done = true }
        case .copy: if store.canCopy { store.copySelection(); done = true } else if store.selectedSpectrum != nil { store.statusMessage = ProjectStore.spectrumEditUnsupported }   // 스펙트럼 복사 없음(2B-2): 경고음 + 안내
        case .paste: if store.canPaste { store.pasteAtPlayhead(); done = true } else if store.clipClipboard == nil { store.statusMessage = EditError.clipboardEmpty.description }
        }
        if !done { NSSound.beep() }   // 꺼진 동작: 메뉴 키 등가물과 같이 경고음만
        return nil
    }

    /// ⌘ 메뉴 명령이 편집기 동작을 할지, 응답자 체인으로 넘길지
    static func menuTargetsEditor(_ store: ProjectStore) -> Bool { editorAcceptsShortcuts(store) }
}
