#if DEBUG
import AppKit
import OnTheFrameEngine

/// 단축키 경로 자체 검사(Debug 전용, 일반 화면에 없음). `open -n -W -a OnTheFrame.app <폴더> --args -OTFShortcutTest`.
/// 합성한 키·마우스 이벤트를 앱 이벤트 큐에 넣어(NSApp.postEvent) 실제 경로(로컬 키 감시 → 메뉴 키 등가물 → 응답자 체인)를
/// 거치게 한다. 하드웨어 입력 계층은 거치지 않는다. 결과: <폴더>/shortcut-result.json. 미디어 내보내기는 하지 않는다.
@MainActor
enum ShortcutSelfTest {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }

    static func run(folder: URL) async {
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)) }
        let s = ProjectStore.shared
        let src = folder.appendingPathComponent("sources")
        NSApp.activate(ignoringOtherApps: true)
        _ = await waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { return finish(folder, [Check(name: "window", pass: false, detail: "no editor window")]) }
        w.makeKeyAndOrderFront(nil)
        _ = await waitUntil(5) { NSApp.keyWindow === w }
        check("setup.editorKey", NSApp.keyWindow === w)
        func responderInfo(_ r: NSResponder?) -> String {
            guard let r else { return "nil" }
            return "\(type(of: r)) textInputClient=\(r is NSTextInputClient) inputContext=\((r as? NSView)?.inputContext != nil || (r as? NSTextView)?.inputContext != nil)"
        }
        let launchResponder = responderInfo(w.firstResponder)
        check("probe.launchFirstResponder", true, launchResponder + " currentContext=\(NSTextInputContext.current != nil)")

        // 메뉴 구성: ⌘K 자르기, ⌘B 없음, 수정 키 없는 키 등가물 없음
        let items = allItems(NSApp.mainMenu)
        let closeish = items.filter { $0.keyEquivalent.lowercased() == "w" || $0.keyEquivalent.lowercased() == "q" || $0.action.map(NSStringFromSelector).map { $0.contains("lose") || $0.contains("erminate") } == true }
            .map { "\($0.menu?.title ?? "?")>\($0.title)[\($0.keyEquivalent)/\($0.keyEquivalentModifierMask.rawValue)] act=\($0.action.map(NSStringFromSelector) ?? "nil") tgt=\($0.target.map { String(describing: type(of: $0)) } ?? "nil")" }
        check("probe.closeMenuItems", true, closeish.joined(separator: " ; ") + " | delegate=\(w.delegate.map { String(describing: type(of: $0)) } ?? "nil") closeBtnTarget=\(w.standardWindowButton(.closeButton)?.target.map { String(describing: type(of: $0)) } ?? "nil") act=\(w.standardWindowButton(.closeButton)?.action.map(NSStringFromSelector) ?? "nil")")
        let split = items.first { $0.title == "재생 헤드에서 자르기" }
        check("menu.splitIsCmdK", split?.keyEquivalent == "k" && split?.keyEquivalentModifierMask == [.command],
              "\(split?.keyEquivalent ?? "nil") \(split?.keyEquivalentModifierMask.rawValue ?? 0)")
        let cmdB = items.filter { $0.keyEquivalent.lowercased() == "b" && $0.keyEquivalentModifierMask == [.command] }.map(\.title)
        check("menu.noCmdB", cmdB.isEmpty, cmdB.joined(separator: ","))
        let bare = items.filter { !$0.keyEquivalent.isEmpty && $0.keyEquivalentModifierMask.intersection([.command, .control, .option, .function]).isEmpty }
            .map { "\($0.title)[\($0.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) }.joined())]" }
        check("menu.noBareKeyEquivalents", bare.isEmpty, bare.joined(separator: ","))
        let undoItem = items.first { $0.title == "실행 취소" }, redoItem = items.first { $0.title == "다시 실행" }
        check("menu.undoRedo", undoItem?.keyEquivalent == "z" && undoItem?.keyEquivalentModifierMask == [.command]
              && redoItem?.keyEquivalent.lowercased() == "z" && redoItem?.keyEquivalentModifierMask == [.command, .shift])

        // 타임라인 준비: A(120) + B(90)
        s.importFiles([src.appendingPathComponent("otf-A.mp4"), src.appendingPathComponent("otf-B.mp4")])
        _ = await waitUntil(30) { s.assets.count == 2 && s.importing == 0 }
        guard s.assets.count == 2 else { return finish(folder, checks + [Check(name: "setup.import", pass: false, detail: "\(s.assets.count)")]) }
        s.addToTimeline(s.assets[0].id); s.addToTimeline(s.assets[1].id)
        _ = await waitUntil(10) { s.canPlay }
        s.selection = s.timeline.clips[0].id
        s.seek(to: 50)
        await settle()
        check("probe.afterSetupFirstResponder", true, responderInfo(w.firstResponder) + " currentContext=\(NSTextInputContext.current != nil)")
        check("setup.editorFocused", s.editorFocused)

        // ⌘K: 선택한 클립을 재생 헤드에서 한 번만 자른다
        var depth = s.history.undoDepth, count = s.timeline.clips.count
        let diag = "canSplit \(s.canSplit) itemEnabledBeforeMenuOpen \(split?.isEnabled ?? false)"
        await key(40, "k", [.command], w)
        check("cmdK.splitOnce", s.timeline.clips.count == count + 1 && s.history.undoDepth == depth + 1 && s.timeline.clips.map(\.length) == [50, 70, 90],
              "\(s.timeline.clips.map(\.length)) depth \(s.history.undoDepth - depth) | \(diag)")
        // 메뉴를 열 때(menuNeedsUpdate) 항목 상태가 현재 상태로 갱신되는지: 선택 있음 → 삭제 켜짐, 선택 없음 → 꺼짐
        let delOn = menuOpenState("선택한 클립 삭제(빈틈 남김)  Delete")
        let savedSel = s.selection; s.selection = nil; await settle()
        let delOff = menuOpenState("선택한 클립 삭제(빈틈 남김)  Delete")
        s.selection = savedSel; await settle()
        check("menu.stateRefreshedOnOpen", delOn && !delOff && menuOpenState("재생 헤드에서 자르기"), "on \(delOn) off \(delOff)")
        // 선택은 오른쪽 조각, 재생 헤드 50 = 그 조각의 시작 → 경계라서 거부(규칙 유지)
        depth = s.history.undoDepth; count = s.timeline.clips.count
        await key(40, "k", [.command], w)
        check("cmdK.boundaryRejected", s.timeline.clips.count == count && s.history.undoDepth == depth && (s.statusMessage ?? "").contains("경계"),
              s.statusMessage ?? "")
        // 메뉴 항목도 켜진 상태(메뉴를 연 뒤)에서 ⌘K·⌘Z가 두 번 실행되지 않는다(라우터가 소비)
        s.seek(to: 20); s.selection = s.timeline.clips[0].id; await settle()
        _ = menuOpenState("재생 헤드에서 자르기"); _ = menuOpenState("실행 취소")
        let enabledNow = allItems(NSApp.mainMenu).first { $0.title == "재생 헤드에서 자르기" }?.isEnabled ?? false
        let c0 = s.timeline.clips.count, d0 = s.history.undoDepth
        await key(40, "k", [.command], w)
        let afterK = (s.timeline.clips.count - c0, s.history.undoDepth - d0)
        await key(6, "z", [.command], w)
        check("cmdK.cmdZ.onceWithMenuEnabled", enabledNow && afterK == (1, 1) && s.timeline.clips.count == c0 && s.history.undoDepth == d0,
              "menuEnabled \(enabledNow) split Δ\(afterK) undo → \(s.timeline.clips.count - c0),\(s.history.undoDepth - d0)")
        s.seek(to: 50); s.selection = s.timeline.clips.first { $0.sourceIn == 50 }?.id; await settle()
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("korean")]) }
        // 한글 2벌식에서 시스템이 만드는 모양(실험으로 확인): characters는 단축키 배열의 라틴 문자, charactersIgnoringModifiers는 한글 자모
        do {
            s.seek(to: 20); s.selection = s.timeline.clips[0].id; await settle()
            let c0 = s.timeline.clips.count, d0 = s.history.undoDepth
            await key(40, "k", [.command], w, ignoring: "\u{314F}")
            let k = (s.timeline.clips.count - c0, s.history.undoDepth - d0)
            await key(6, "z", [.command], w, ignoring: "\u{314B}")
            let z = (s.timeline.clips.count - c0, s.history.undoDepth - d0)
            await key(6, "z", [.command, .shift], w, ignoring: "\u{314B}")
            let sz = (s.timeline.clips.count - c0, s.history.undoDepth - d0)
            await key(6, "z", [.command], w, ignoring: "\u{314B}")
            check("korean.cmdKZShapes", k == (1, 1) && z == (0, 0) && sz == (1, 1) && s.timeline.clips.count == c0,
                  "⌘K Δ\(k) ⌘Z Δ\(z) ⇧⌘Z Δ\(sz) end \(s.timeline.clips.count - c0)")
            s.seek(to: 50); s.selection = s.timeline.clips.first { $0.sourceIn == 50 }?.id; await settle()
        }
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("direct")]) }
        // 이벤트 큐를 거치지 않고 앱 sendEvent로 바로 전달된 경우: 로컬 감시·performKeyEquivalent·타임라인 keyDown 여러 층이
        // 같은 이벤트를 볼 수 있어도 한 번만 처리되는지. (로컬 감시는 sendEvent 안에서 불린다 — 이 검사로 확인. 따라서
        // 이 검사는 "로컬 감시를 건너뛰는 경로"를 재현하지 않는다.)
        do {
            s.seek(to: 20); s.selection = s.timeline.clips[0].id
            if let tv = findTimeline(w.contentView) { w.makeFirstResponder(tv) }
            await settle()
            let c0 = s.timeline.clips.count, d0 = s.history.undoDepth
            direct(40, "k", [.command], w, ignoring: "\u{314F}"); await settle()
            let k = (s.timeline.clips.count - c0, s.history.undoDepth - d0)
            direct(6, "z", [.command], w, ignoring: "\u{314B}"); await settle()
            let z = (s.timeline.clips.count - c0, s.history.undoDepth - d0)
            direct(6, "z", [.command, .shift], w, ignoring: "\u{314B}"); await settle()
            let sz = (s.timeline.clips.count - c0, s.history.undoDepth - d0)
            direct(6, "z", [.command], w, ignoring: "\u{314B}"); await settle()
            direct(49, " ", [], w); await settle()
            let played = s.isPlaying
            direct(49, " ", [], w); await settle()
            check("routing.directSendEventOnce", k == (1, 1) && z == (0, 0) && sz == (1, 1) && s.timeline.clips.count == c0 && played && !s.isPlaying,
                  "⌘K Δ\(k) ⌘Z Δ\(z) ⇧⌘Z Δ\(sz) space \(played)/\(s.isPlaying)")
            // ⌘E는 저장 패널(모달)을 여므로 검사에서는 해석만 확인한다. 실제 동작은 소유자 확인.
            let shapes: [(UInt16, String, NSEvent.ModifierFlags, KeyRouting.CommandAction)] = [
                (40, "\u{314F}", [.command], .split), (40, "k", [.command], .split),
                (6, "\u{314B}", [.command], .undo), (6, "z", [.command], .undo),
                (6, "\u{314B}", [.command, .shift], .redo), (6, "Z", [.command, .shift], .redo),
                (14, "\u{3137}", [.command], .export), (14, "e", [.command], .export)]
            let bad = shapes.filter { KeyRouting.commandAction(keyCode: $0.0, charactersIgnoringModifiers: $0.1, modifiers: $0.2) != $0.3 }
            let notCmd = [KeyRouting.commandAction(keyCode: 40, charactersIgnoringModifiers: "\u{314F}", modifiers: []),
                          KeyRouting.commandAction(keyCode: 11, charactersIgnoringModifiers: "\u{3160}", modifiers: [.command])]
            check("routing.koreanAndLatinShapesMap", bad.isEmpty && notCmd.allSatisfy { $0 == nil }, "bad \(bad.count)")
            s.seek(to: 50); s.selection = s.timeline.clips.first { $0.sourceIn == 50 }?.id; await settle()
        }
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("aux")]) }
        // 보조 창(주 창이 될 수 없는 패널)이 키 창이고 편집기가 주 창일 때도 단축키가 동작(입력 소스 표시 창 후보 대응)
        do {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.orderFront(nil); panel.makeKey()
            await settle()
            let auxKey = NSApp.keyWindow === panel && NSApp.mainWindow === w
            s.seek(to: 20); s.selection = s.timeline.clips[0].id; await settle()
            let c0 = s.timeline.clips.count, d0 = s.history.undoDepth
            KeyRouting.testStrictKeyWindow = true                       // 음성 대조: 엄격한 키 창 조건이면 처리되지 않아야 함
            await key(40, "k", [.command], panel, ignoring: "\u{314F}")
            let strictUnhandled = s.timeline.clips.count == c0
            KeyRouting.testStrictKeyWindow = false
            check("routing.negativeControlStrictKeyWindow", strictUnhandled)
            await key(40, "k", [.command], panel, ignoring: "\u{314F}")
            let split = s.timeline.clips.count == c0 + 1
            await key(6, "z", [.command], panel, ignoring: "\u{314B}")
            check("routing.auxKeyWindow", auxKey && split && s.timeline.clips.count == c0 && s.history.undoDepth == d0, "auxKey \(auxKey) split \(split)")
            // 보조 창을 닫은 뒤 편집기 창을 직접 키로 만들지 않아도 단축키가 동작하는가(키 상태가 어떻게 되든)
            panel.close()
            await settle()
            let keyAfterClose = NSApp.keyWindow === w ? "editor" : (NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")
            let c1 = s.timeline.clips.count
            await key(40, "k", [.command], NSApp.keyWindow ?? w, ignoring: "\u{314F}")
            let splitAfterClose = s.timeline.clips.count == c1 + 1
            await key(6, "z", [.command], NSApp.keyWindow ?? w, ignoring: "\u{314B}")
            check("routing.afterAuxWindowClosed", splitAfterClose && s.timeline.clips.count == c1, "key after close: \(keyAfterClose) active \(NSApp.isActive)")
            guard await regainFocus(w) else {
                return finish(folder, checks + [Check(name: "harness.focusLost", pass: false,
                                                      detail: "앱이 활성 상태를 잃음(다른 앱이 앞에 있음). 이후 검사를 하지 않았다. active \(NSApp.isActive)")])
            }
            s.seek(to: 50); s.selection = s.timeline.clips.first { $0.sourceIn == 50 }?.id; await settle()
        }
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("cmdB")]) }
        // ⌘B는 더 이상 자르지 않는다
        s.seek(to: 80)
        await key(11, "b", [.command], w)
        check("cmdB.removed", s.timeline.clips.count == count && s.history.undoDepth == depth)
        // ⌘Z / ⇧⌘Z: 한 번씩
        await key(6, "z", [.command], w)
        check("cmdZ.undoOnce", s.timeline.clips.count == 2 && s.history.undoDepth == depth - 1)
        await key(6, "Z", [.command, .shift], w)
        check("shiftCmdZ.redoOnce", s.timeline.clips.count == 3 && s.history.undoDepth == depth)

        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("space")]) }
        // Space: 한 번 누르면 한 번 전환, 반복 입력은 무시
        await key(49, " ", [], w)
        let started = s.isPlaying
        await key(49, " ", [], w, isRepeat: true)
        let stillPlaying = s.isPlaying
        await key(49, " ", [], w)
        check("space.toggleOnceAndIgnoreRepeat", started && stillPlaying && !s.isPlaying)
        // ←/→ 1프레임, 반복은 계속 이동, Home/End
        s.seek(to: 30); await settle()
        await key(124, arrow(0xF703), [.numericPad, .function], w)
        let r1 = s.playhead
        await key(123, arrow(0xF702), [.numericPad, .function], w)
        let l1 = s.playhead
        await key(124, arrow(0xF703), [.numericPad, .function], w, isRepeat: true)
        check("arrows.stepOneFrame", r1 == 31 && l1 == 30 && s.playhead == 31, "\(r1) \(l1) \(s.playhead)")
        await key(119, arrow(0xF72B), [.function], w)
        let atEnd = s.playhead
        await key(115, arrow(0xF729), [.function], w)
        check("homeEnd", atEnd == s.durationFrames && s.playhead == 0, "\(atEnd)/\(s.durationFrames) \(s.playhead)")
        // ⇧→ 등 수정 키 조합은 처리하지 않음(구현하지 않은 동작)
        await key(124, arrow(0xF703), [.numericPad, .function, .shift], w)
        check("shiftArrow.notHandled", s.playhead == 0)
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("delete")]) }
        // Delete: 빈틈을 남기는 삭제 한 번(D-020), 반복 무시. ⇧Delete: 리플 삭제 한 번. 선택 없으면 아무 일 없음
        guard s.timeline.clips.count >= 2 else {
            return finish(folder, checks + [Check(name: "harness.clipsForDelete", pass: false, detail: "\(s.timeline.clips.map(\.length))")])
        }
        s.selection = s.timeline.clips[1].id
        depth = s.history.undoDepth
        let before = s.timeline
        await key(51, "\u{7f}", [], w)
        await key(51, "\u{7f}", [], w, isRepeat: true)
        let removed = before.clips[1]
        check("delete.liftOnceLeavesGap", s.timeline.clips.count == before.clips.count - 1 && s.history.undoDepth == depth + 1
              && s.durationFrames == before.durationFrames && s.timeline.gaps.contains(removed.start..<removed.end)
              && Array(s.timeline.starts) == before.clips.filter { $0.id != removed.id }.map(\.start), "\(s.timeline.gaps)")
        await key(6, "z", [.command], w)
        check("delete.undo", s.timeline == before)
        s.selection = before.clips[1].id
        await key(51, "\u{7f}", [.shift], w)
        await key(51, "\u{7f}", [.shift], w, isRepeat: true)
        check("shiftDelete.rippleOnce", s.timeline.clips.count == before.clips.count - 1 && s.history.undoDepth == depth + 1
              && s.durationFrames == before.durationFrames - removed.length && s.timeline.gaps.isEmpty)
        await key(6, "z", [.command], w)
        check("shiftDelete.undo", s.timeline == before)
        // 빈틈에서: 재생 헤드가 빈틈에 있고 선택이 없으면 ⌘K·Delete 모두 아무 일 없음
        s.selection = before.clips[1].id
        await key(117, arrow(0xF728), [.function], w)                     // ⌦: 빈틈 남김
        let gapState = s.timeline, gd = s.history.undoDepth
        s.selection = nil
        s.seek(to: removed.start + 1); await settle()
        await key(40, "k", [.command], w)
        await key(51, "\u{7f}", [], w)
        check("gap.splitAndDeleteNoop", s.timeline == gapState && s.history.undoDepth == gd && (s.statusMessage ?? "").contains("나눌 클립"),
              s.statusMessage ?? "")
        await key(6, "z", [.command], w)
        check("gap.undoRestores", s.timeline == before)
        s.selection = nil
        await key(117, arrow(0xF728), [.function], w)
        check("delete.noSelectionNoop", s.timeline == before && s.history.undoDepth == depth)

        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("text")]) }
        // 텍스트 입력 초점: 입력·커서 이동·삭제·텍스트 실행 취소가 텍스트 칸으로 가고 타임라인은 그대로
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        w.contentView?.addSubview(field)
        w.makeFirstResponder(field)
        await settle()
        check("text.focusTracked", !s.editorFocused && KeyRouting.isTextInput(w.firstResponder))
        let tl = s.timeline, ph = s.playhead, dp = s.history.undoDepth
        s.selection = s.timeline.clips.first?.id
        for (c, k) in [("a", UInt16(0)), (" ", 49), ("b", 11)] { await key(k, c, [], w) }
        let typed = editorText(w)
        await key(123, arrow(0xF702), [.numericPad, .function], w)
        let caret = (w.firstResponder as? NSTextView)?.selectedRange().location
        await key(51, "\u{7f}", [], w)
        let afterDelete = editorText(w)
        await key(115, arrow(0xF729), [.function], w)
        await key(119, arrow(0xF72B), [.function], w)
        await key(40, "k", [.command], w)
        await key(6, "z", [.command], w, ignoring: "\u{314B}")   // 한글 2벌식 모양
        let afterUndo = editorText(w)
        await key(6, "z", [.command, .shift], w, ignoring: "\u{314B}")
        let afterRedo = editorText(w)
        await key(40, "k", [.command], w, ignoring: "\u{314F}")
        check("text.typingSpaceGoesToField", typed == "a b", typed)
        check("text.arrowMovesCaret", caret == 2, "\(caret ?? -1)")
        check("text.deleteEditsField", afterDelete == "ab", afterDelete)
        check("text.cmdZIsTextUndo", afterUndo == "a b" && afterRedo == "ab", "\(afterUndo) / \(afterRedo)")
        check("text.timelineUntouched", s.timeline == tl && s.playhead == ph && s.history.undoDepth == dp && !s.isPlaying,
              "playhead \(s.playhead) depth \(s.history.undoDepth - dp) playing \(s.isPlaying)")
        w.makeFirstResponder(nil)
        field.removeFromSuperview()
        await settle()
        check("text.focusReleased", s.editorFocused)

        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("modal")]) }
        // 시트(알림)가 떠 있으면 편집기 단축키를 실행하지 않는다
        s.presentAlert(.init(title: "단축키 검사", message: "모달 확인"))
        _ = await waitUntil(5) { s.alerts.isShowing && NSApp.keyWindow !== w }
        let sheetKey = NSApp.keyWindow
        let tl2 = s.timeline, ph2 = s.playhead
        if let k = sheetKey {
            await key(124, arrow(0xF703), [.numericPad, .function], k)
            await key(40, "k", [.command], k)
            await key(51, "\u{7f}", [], k)
        }
        check("modal.shortcutsIgnored", sheetKey != nil && s.timeline == tl2 && s.playhead == ph2 && !s.isPlaying)
        s.alerts.pressButton(0)
        _ = await waitUntil(5) { !s.alerts.isShowing && NSApp.keyWindow === w }
        await settle()

        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("drag")]) }
        // 드래그 중: Space·Delete 무시, Esc로 드래그 취소(마우스 이벤트로 실제 드래그)
        if let tv = findTimeline(w.contentView) {
            let base = s.timeline, d0 = s.history.undoDepth
            let edge = tv.convert(NSPoint(x: TimelineNSView.inset + CGFloat(base.clips[0].length) * tv.pixelsPerFrame - 2,
                                          y: TimelineNSView.trackY + TimelineNSView.trackHeight / 2), to: nil)
            await mouse(.leftMouseDown, edge, w)
            await mouse(.leftMouseDragged, NSPoint(x: edge.x - 30, y: edge.y), w)
            let dragging = s.gestureBase != nil && s.timeline != base
            await key(49, " ", [], w)
            await key(51, "\u{7f}", [], w)
            let ignoredInDrag = !s.isPlaying && s.timeline.clips.count == base.clips.count
            await key(53, "\u{1b}", [], w)
            let cancelled = s.timeline == base && s.gestureBase == nil
            await mouse(.leftMouseUp, NSPoint(x: edge.x - 30, y: edge.y), w)
            check("drag.shortcutsIgnoredDuringDrag", dragging && ignoredInDrag, "dragging \(dragging)")
            check("drag.escCancels", cancelled && s.timeline == base && s.history.undoDepth == d0)
            // 같은 드래그를 끝내면 실행 취소 한 단계
            await mouse(.leftMouseDown, edge, w)
            await mouse(.leftMouseDragged, NSPoint(x: edge.x - 30, y: edge.y), w)
            await mouse(.leftMouseUp, NSPoint(x: edge.x - 30, y: edge.y), w)
            let committed = s.history.undoDepth == d0 + 1 && s.timeline.clips[0].length < base.clips[0].length
            await key(6, "z", [.command], w)
            check("drag.commitOneUndoStep", committed && s.timeline == base,
                  "committed \(committed) depth \(s.history.undoDepth - d0) lens \(s.timeline.clips.map(\.length)) base \(base.clips.map(\.length)) starts \(s.timeline.starts)")
        } else { check("drag.timelineView", false, "not found") }

        finish(folder, checks)
    }

    // MARK: 도우미

    private static func lostFocus(_ section: String) -> Check {
        Check(name: "harness.focusLost", pass: false, detail: "\(section) 앞에서 앱이 활성 상태를 잃음(다른 앱이 앞에 있음). 이후 검사를 하지 않았다.")
    }
    /// 편집기 창을 다시 키 창으로. 다른 앱이 앞에 있으면 macOS가 활성화를 거절할 수 있다(협조적 활성화) — 그때 false.
    private static func regainFocus(_ w: NSWindow) async -> Bool {
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        let ok = await waitUntil(3) { NSApp.isActive && NSApp.keyWindow === w }
        await settle()
        return ok
    }

    private static func arrow(_ u: Int) -> String { String(UnicodeScalar(u)!) }
    private static func editorText(_ w: NSWindow) -> String { (w.firstResponder as? NSTextView)?.string ?? "<no editor>" }

    private static func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags, _ w: NSWindow, isRepeat: Bool = false, ignoring: String? = nil) async {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: ignoring ?? chars, isARepeat: isRepeat, keyCode: code) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
        await settle()
    }
    /// 이벤트 큐와 로컬 감시를 거치지 않고 앱 sendEvent로 바로 보낸다(keyDown·keyUp)
    private static func direct(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags, _ w: NSWindow, ignoring: String? = nil) {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code) {
                NSApp.sendEvent(e)
            }
        }
    }
    private static func mouse(_ t: NSEvent.EventType, _ p: NSPoint, _ w: NSWindow) async {
        if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1) {
            NSApp.postEvent(e, atStart: false)
        }
        await settle()
    }
    /// 넣은 이벤트가 처리될 때까지: 표지 이벤트(앱 정의)를 넣고 그것이 처리될 때까지 기다린 뒤 화면 갱신 한 번
    private static func settle() async {
        let marker = Int(Date().timeIntervalSince1970 * 1000) & 0x3FFF_FFFF
        let done = Flag()
        let mon = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { e in
            if e.data1 == marker { MainActor.assumeIsolated { done.v = true } }
            return e
        }
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, subtype: 0, data1: marker, data2: 0) { NSApp.postEvent(e, atStart: false) }
        _ = await waitUntil(3) { done.v }
        if let mon { NSEvent.removeMonitor(mon) }
        try? await Task.sleep(nanoseconds: 50_000_000)   // 관찰 값(focus)·화면 반영 한 차례
    }
    @MainActor final class Flag { var v = false }

    /// 메뉴를 여는 것과 같은 갱신(NSMenuDelegate.menuNeedsUpdate)을 하고 항목 사용 가능 상태를 돌려준다
    private static func menuOpenState(_ title: String) -> Bool {
        guard let it = allItems(NSApp.mainMenu).first(where: { $0.title == title }), let m = it.menu else { return false }
        m.delegate?.menuNeedsUpdate?(m)
        return allItems(NSApp.mainMenu).first(where: { $0.title == title })?.isEnabled ?? false
    }
    private static func findTimeline(_ v: NSView?) -> TimelineNSView? {
        guard let v else { return nil }
        if let t = v as? TimelineNSView { return t }
        for c in v.subviews { if let t = findTimeline(c) { return t } }
        return nil
    }
    private static func allItems(_ m: NSMenu?) -> [NSMenuItem] {
        guard let m else { return [] }
        return m.items.flatMap { [$0] + allItems($0.submenu) }
    }
    private static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    private static func finish(_ folder: URL, _ checks: [Check]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("shortcut-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
