#if DEBUG
import AppKit
import OnTheFrameEngine

/// 편집 도구(선택 V·자르기 C, D-030) 자체 검사(2026-10-11, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFToolTest`.
/// 실제 키·마우스 이벤트(앱 이벤트 큐), 타임라인 메뉴, 툴바 분할 단추를 지난다. 생성 fixture(otf-TA)만, 저장하지 않는다.
/// - 한국어 입력 소스는 바꾸지 않는다: 한글 글자(ㅊ·ㅍ)를 실은 합성 키 이벤트로 물리 키 코드 경로만 본다(실제 입력기 조합은 아님).
/// - 안내선(포인터 이동·나감)은 타임라인 보기에 직접 보낸다(실제 포인터 위치에 따른 추적 영역 이벤트를 합성할 수 없어서).
/// - 끌기 중 보호는 저장소의 끌기 시작(beginGesture)으로 끌기 상태를 만든 뒤 키·메뉴·툴바·클릭을 보낸다.
/// 결과는 <폴더>/tool-result.json.
@MainActor
enum ToolSelfTest {
    typealias Check = LaneSelfTest.Check

    struct Snap: Equatable {
        let timeline: Timeline, playhead: Int, selection: UUID?, depth: Int, dirty: Bool
    }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { return finish(folder, [Check(name: "setup.window", pass: false, detail: "")]) }
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, [LaneSelfTest.lostFocus("setup")]) }

        // 준비: 영상+소리 클립(120프레임, V1·A1의 0에 연결된 쌍)
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        guard let asset = s.assets.first else { return finish(folder, [Check(name: "setup.import", pass: false, detail: "")]) }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        s.addToTimeline(asset.id)
        await LaneSelfTest.settle()
        guard let v0 = s.timeline.clips.first?.id, let a0 = s.timeline.audioClips.first?.id, s.timeline.partner(of: v0)?.id == a0,
              let tv = LaneSelfTest.find(TimelineNSView.self, w.contentView) else { return finish(folder, [Check(name: "setup.place", pass: false, detail: "")]) }
        tv.enclosingScrollView?.contentView.scroll(to: .zero)
        if let sv = tv.enclosingScrollView { sv.reflectScrolledClipView(sv.contentView) }
        await LaneSelfTest.settle()
        let v1 = Lane.videoID, a1 = Lane.audioID

        func snap() -> Snap { Snap(timeline: s.timeline, playhead: s.playhead, selection: s.selection, depth: s.history.undoDepth, dirty: s.isDirty) }
        /// 문서 x(프레임 경계 + dx)·레인 가운데의 창 좌표
        func pt(_ lane: UUID, _ frame: Int, dx: CGFloat = 0.3) -> NSPoint {
            guard let r = tv.laneRect(lane) else { return .zero }
            return tv.convert(NSPoint(x: tv.x(frame) + dx, y: r.midY), to: nil)
        }
        func key(_ code: UInt16, _ ch: String, _ mods: NSEvent.ModifierFlags = []) async { w.makeFirstResponder(tv); await LaneSelfTest.key(code, ch, mods, w) }
        func click(_ p: NSPoint, _ mods: NSEvent.ModifierFlags = []) async {
            await LaneSelfTest.mouse(.leftMouseDown, p, w, mods: mods); await LaneSelfTest.mouse(.leftMouseUp, p, w, mods: mods)
        }
        func move(_ p: NSPoint) {
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { tv.mouseMoved(with: e) }
        }
        func exit() {
            if let e = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) { tv.mouseExited(with: e) }
        }
        func rows(_ lane: UUID) -> [[Int]] { s.timeline.clips(inLane: lane).sorted { $0.start < $1.start }.map { [$0.start, $0.length] } }
        func toolbarSegment() -> NSSegmentedControl? {
            guard let frame = w.contentView?.superview, let cv = w.contentView else { return nil }
            func all(_ v: NSView) -> [NSSegmentedControl] { (v as? NSSegmentedControl).map { [$0] } ?? [] + v.subviews.flatMap(all) }
            return all(frame).first { !$0.isDescendant(of: cv) && $0.segmentCount == 3 }   // 선택·자르기·텍스트(2026-10-22)
        }
        func pressToolbar(_ i: Int) -> Bool {
            guard let seg = toolbarSegment() else { return false }
            seg.setSelected(true, forSegment: i)
            return seg.sendAction(seg.action, to: seg.target)
        }
        func menuState(_ title: String) -> NSControl.StateValue? {
            func all(_ m: NSMenu?) -> [NSMenuItem] { guard let m else { return [] }; return m.items.flatMap { [$0] + all($0.submenu) } }
            guard let it = all(NSApp.mainMenu).first(where: { $0.title == title }) else { return nil }
            it.menu.map { $0.delegate?.menuNeedsUpdate?($0) }
            return it.state
        }

        // 1. 처음 도구 = 선택
        check("tool.defaultSelection", s.tool == .selection)

        // 2. 키 C·V: 도구만 바뀐다(재생 헤드·선택·타임라인·기록·저장 상태 그대로), 같은 키 다시 = 그대로, 반복 입력 무시
        s.select(v0); s.seek(to: 30)
        let base0 = snap()
        await key(8, "c")
        check("tool.keyCSwitchesOnly", s.tool == .cut && snap() == base0, "tool \(s.tool)")
        await key(8, "c")
        check("tool.keyCIdempotent", s.tool == .cut && snap() == base0)
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                    context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: true, keyCode: 9) {
            w.makeFirstResponder(tv); NSApp.postEvent(e, atStart: false); await LaneSelfTest.settle()
        }
        check("tool.keyRepeatIgnored", s.tool == .cut && snap() == base0, "tool \(s.tool)")
        await key(9, "v")
        check("tool.keyVSwitchesOnly", s.tool == .selection && snap() == base0)

        // 3. 한국어 2벌식 모양(ㅊ·ㅍ, 합성 이벤트): 물리 키 코드로 같은 동작
        await key(8, "ㅊ")
        let kc = s.tool == .cut
        await key(9, "ㅍ")
        check("tool.koreanKeyCodes", kc && s.tool == .selection && snap() == base0, "synthetic Hangul characters, input source not changed")

        // 4. 재생 중 도구 바꾸기: 재생을 멈추지 않는다
        if s.canPlay {
            s.togglePlay()
            _ = await LaneSelfTest.waitUntil(3) { s.isPlaying }
            await key(8, "c")
            let playingAfterC = s.isPlaying, toolC = s.tool
            await key(9, "v")
            check("tool.switchKeepsPlayback", playingAfterC && s.isPlaying && toolC == .cut && s.tool == .selection, "after C \(playingAfterC) after V \(s.isPlaying)")
            s.togglePlay(); _ = await LaneSelfTest.waitUntil(3) { !s.isPlaying }
            s.seek(to: 30)
        } else { check("tool.switchKeepsPlayback", false, "canPlay false") }
        let base1 = snap()

        // 5. 타임라인 메뉴(체크 표시)·툴바 단추
        let mC = LaneSelfTest.menuItem("자르기 도구  C"); await LaneSelfTest.settle()
        let afterMenuC = s.tool, stC = menuState("자르기 도구  C"), stV = menuState("선택 도구  V")
        let mV = LaneSelfTest.menuItem("선택 도구  V"); await LaneSelfTest.settle()
        check("tool.menuItemsChecked", mC && mV && afterMenuC == .cut && stC == .on && stV == .off && s.tool == .selection && snap() == base1,
              "menu \(mC) \(mV) state C \(String(describing: stC?.rawValue)) V \(String(describing: stV?.rawValue))")
        let tb1 = pressToolbar(1); await LaneSelfTest.settle()
        let afterTB = s.tool
        let tb0 = pressToolbar(0); await LaneSelfTest.settle()
        check("tool.toolbarSegments", tb1 && tb0 && afterTB == .cut && s.tool == .selection && snap() == base1, "found \(toolbarSegment() != nil) sent \(tb1) \(tb0) tool \(afterTB)")

        // 6. 텍스트 입력: V·C는 글자로 들어가고 도구는 그대로, ⌘C·⌘V는 텍스트로 넘긴다(시스템 클립보드는 바꾸지 않음)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        w.contentView?.addSubview(field)
        w.makeFirstResponder(field); await LaneSelfTest.settle()
        await LaneSelfTest.key(8, "c", [], w); await LaneSelfTest.key(9, "v", [], w)
        let typed = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        func passes(_ code: UInt16, _ ch: String, _ mods: NSEvent.ModifierFlags) -> Bool {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                           context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) else { return false }
            return KeyRouting.handle(e, store: s) != nil
        }
        check("text.vcTypedToolUnchanged", typed == "cv" && s.tool == .selection && snap() == base1, "typed '\(typed)'")
        check("text.routerPassesVCAndCmdCV", KeyRouting.isTextInput(w.firstResponder) && passes(8, "c", []) && passes(9, "v", []) && passes(8, "ㅊ", [])
              && passes(8, "c", [.command]) && passes(9, "v", [.command]))
        w.makeFirstResponder(nil); field.removeFromSuperview(); await LaneSelfTest.settle()

        // 7. 자르기 도구에서도 ⌘C·⌘V는 지금처럼(클립 복사·붙여넣기), 도구 그대로
        await key(8, "c")
        s.select(v0)
        await key(8, "c", [.command])
        let copied = s.clipClipboard != nil
        s.seek(to: s.durationFrames)
        let dPaste = s.history.undoDepth
        await key(9, "v", [.command])
        let pasted = s.history.undoDepth == dPaste + 1
        await key(6, "z", [.command])
        check("cmd.copyPasteUnchangedInCutTool", copied && pasted && s.tool == .cut && s.timeline == base1.timeline, "copied \(copied) pasted \(pasted)")
        s.select(v0); s.seek(to: 30)
        let base2 = snap()

        // 8. 안내선과 자르기: 같은 프레임 변환, 연결된 쌍 함께 한 단계, 오른쪽 조각 선택, 재생 헤드 그대로, 실행 취소·다시 실행
        let p40 = pt(v1, 40)
        move(p40)
        let hover = tv.cutHover
        check("hover.alignedValid", hover?.id == v0 && hover?.frame == 40 && tv.frame(atX: tv.convert(p40, from: nil).x) == 40, "hover \(String(describing: hover))")
        await click(p40)
        let afterCut = snap()
        let right = s.timeline.clips.first { $0.start == 40 && $0.lane == v1 }
        check("cut.linkedOneStep", rows(v1) == [[0, 40], [40, 80]] && rows(a1) == [[0, 40], [40, 80]] && afterCut.depth == base2.depth + 1
              && s.selection == right?.id && s.playhead == 30 && s.isDirty && s.tool == .cut, "v1 \(rows(v1)) a1 \(rows(a1)) playhead \(s.playhead)")
        _ = await LaneSelfTest.waitUntil(2) { tv.cutHover == nil }
        check("hover.clearedWhenTargetInvalid", tv.cutHover == nil, "hover \(String(describing: tv.cutHover))")
        await key(6, "z", [.command])
        let undone = s.timeline
        await key(6, "z", [.command, .shift])
        check("cut.undoRedo", undone == base2.timeline && s.timeline == afterCut.timeline, "undo ok \(undone == base2.timeline) redo ok \(s.timeline == afterCut.timeline)")

        // 9. 거부: 경계·빈 곳·수정 키 누름은 아무것도 바꾸지 않는다(상태 줄도 그대로)
        s.statusMessage = nil
        let base3 = snap()
        await click(pt(v1, 40, dx: 0))
        check("cut.boundaryIgnored", snap() == base3 && s.statusMessage == nil)
        await click(pt(v1, 200))
        check("cut.emptySpaceKeepsSelection", snap() == base3 && s.selection == base3.selection && s.statusMessage == nil)
        await click(pt(v1, 80), [.command]); await click(pt(v1, 80), [.shift]); await click(pt(v1, 80), [.option])
        check("cut.modifiedClickNoop", snap() == base3 && s.statusMessage == nil)

        // 10. 누른 뒤 끌기: 한 번만 자르고 옮기기·트림 없음
        let p80 = pt(v1, 80)
        await LaneSelfTest.mouse(.leftMouseDown, p80, w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p80.x + 60, y: p80.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p80.x + 120, y: p80.y + 40), w)
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: p80.x + 120, y: p80.y + 40), w)
        check("cut.dragCutsOnceNoMove", rows(v1) == [[0, 40], [40, 40], [80, 40]] && rows(a1) == [[0, 40], [40, 40], [80, 40]] && s.history.undoDepth == base3.depth + 1,
              "v1 \(rows(v1))")
        let base4 = snap()
        // 가장자리(끝 경계에 반올림)를 누르고 끌기: 트림 없음
        let pEnd = pt(v1, 120, dx: -0.4)
        await LaneSelfTest.mouse(.leftMouseDown, pEnd, w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: pEnd.x + 40, y: pEnd.y), w)
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: pEnd.x + 40, y: pEnd.y), w)
        check("cut.edgeNoTrim", snap() == base4, "v1 \(rows(v1))")
        // 페이드 손잡이 자리(소리 클립 위쪽, 시작 경계): 손잡이 없음, 페이드 끌기 없음
        if let au = s.timeline.audioClips.first(where: { $0.start == 80 }) {
            s.select(au.id); await LaneSelfTest.settle()
            let base5 = snap()
            let noHandles = tv.state.map { tv.fadeHandleClips($0).isEmpty } ?? false
            guard let r = tv.laneRect(a1) else { return finish(folder, checks) }
            let ph = tv.convert(NSPoint(x: tv.x(80) + 0.3, y: r.minY + 6), to: nil)
            await LaneSelfTest.mouse(.leftMouseDown, ph, w)
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: ph.x + 30, y: ph.y), w)
            await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: ph.x + 30, y: ph.y), w)
            check("cut.fadeHandleInert", noHandles && snap() == base5 && s.timeline.clip(au.id)?.audio == au.audio, "handles hidden \(noHandles)")
        } else { check("cut.fadeHandleInert", false, "no audio piece at 80") }

        // 11. 눈금자 탐색은 자르기 도구에서도 그대로
        let base6 = snap()
        let r0 = tv.convert(NSPoint(x: tv.x(50) + 0.3, y: 10), to: nil), r1 = tv.convert(NSPoint(x: tv.x(70) + 0.3, y: 10), to: nil)
        await LaneSelfTest.mouse(.leftMouseDown, r0, w)
        let ph50 = s.playhead
        await LaneSelfTest.mouse(.leftMouseDragged, r1, w)
        await LaneSelfTest.mouse(.leftMouseUp, r1, w)
        check("ruler.scrubInCutTool", ph50 == 50 && s.playhead == 70 && s.timeline == base6.timeline && s.history.undoDepth == base6.depth, "playhead \(ph50) → \(s.playhead)")

        // 12. ⌘K(재생 헤드에서 자르기)는 도구와 따로
        s.select(nil); s.seek(to: 20)
        let dK = s.history.undoDepth
        await key(40, "k", [.command])
        check("cmdK.independentOfTool", rows(v1).first == [0, 20] && s.history.undoDepth == dK + 1 && s.tool == .cut, "v1 \(rows(v1))")
        await key(6, "z", [.command])

        // 13. 재생 중 클립을 누르면 멈추고 자른다
        if s.canPlay {
            s.seek(to: 0); s.togglePlay()
            _ = await LaneSelfTest.waitUntil(3) { s.isPlaying }
            let was = s.isPlaying, d = s.history.undoDepth
            await click(pt(v1, 10))
            check("cut.pausesPlayback", was && !s.isPlaying && s.history.undoDepth == d + 1 && rows(v1).first == [0, 10], "was \(was) v1 \(rows(v1))")
            await key(6, "z", [.command])
        } else { check("cut.pausesPlayback", false, "canPlay false") }

        // 14. 짝이 그 위치를 덮지 않는 연결 쌍: 안내선 없음, 누르면 상태 줄 이유만(타임라인·선택·기록·저장 상태 그대로)
        await key(9, "v")
        s.addToTimeline(asset.id); await LaneSelfTest.settle()
        if let v2 = s.timeline.clips.first(where: { $0.start == 120 && $0.lane == v1 })?.id, let a2 = s.timeline.partner(of: v2)?.id {
            s.select(v2); s.unlinkSelection()
            s.beginGesture(select: a2); s.updateTrim(a2, edge: .end, delta: -80); s.commitGesture()
            s.select(v2); s.select(a2, extend: true); s.linkSelection()
            await LaneSelfTest.settle()
            let linked = s.timeline.partner(of: v2)?.id == a2 && s.timeline.clip(a2)?.length == 40
            await key(8, "c")
            s.statusMessage = nil
            let base7 = snap()
            let p200 = pt(v1, 200)
            move(p200)
            let hidden = tv.cutHover == nil
            move(pt(v1, 140))
            let validNear = tv.cutHover?.frame == 140
            await click(p200)
            check("hover.invalidLinkedHidden", linked && hidden && validNear, "linked \(linked) hidden \(hidden) validNear \(validNear)")
            check("cut.linkedOutsideRejected", snap() == base7 && s.statusMessage == EditError.linkedSplitOutside.description, "status \(s.statusMessage ?? "nil")")
        } else { check("cut.linkedOutsideRejected", false, "setup pair missing") }

        // 15. 안내선 지우기: 도구 바꿈·포인터 나감
        move(pt(v1, 20))
        let shown = tv.cutHover?.frame == 20
        await key(9, "v")
        let clearedByTool = tv.cutHover == nil
        await key(8, "c")
        move(pt(v1, 20))
        let shownAgain = tv.cutHover != nil
        exit()
        check("hover.clearedOnToolChangeAndExit", shown && clearedByTool && shownAgain && tv.cutHover == nil, "shown \(shown) tool \(clearedByTool) again \(shownAgain)")

        // 16. 끌기 중 보호: 키·메뉴·툴바·저장소 경로 모두 도구를 바꾸지 않고, 자르기 누름은 편집 기록에 닿지 않는다
        if let target = s.timeline.clips.first?.id {
            s.beginGesture(select: target)
            let g0 = s.history.timeline, gd = s.history.undoDepth
            w.makeFirstResponder(tv); await LaneSelfTest.key(9, "v", [], w)
            let byKey = s.tool
            let byMenu = LaneSelfTest.menuItem("선택 도구  V"); await LaneSelfTest.settle()
            _ = pressToolbar(0); await LaneSelfTest.settle()
            let direct = s.setTool(.selection)
            let toolHeld = byKey == .cut && s.tool == .cut && !direct
            s.cutClip(target, atFrame: 30)   // 자르기 진입점 직접(끌기 중 보호). 마우스 누름은 남은 끌기를 먼저 취소한다(D-031, gestureguard-test)
            let noCut = s.history.timeline == g0 && s.history.undoDepth == gd && s.gestureBase != nil
            check("guard.toolSwitchBlockedDuringGesture", toolHeld, "key \(byKey) menuEnabled \(byMenu) direct \(direct) tool \(s.tool)")
            check("guard.cutBlockedDuringGesture", noCut, "depth \(s.history.undoDepth - gd)")
            s.cancelGesture(); await LaneSelfTest.settle()
        } else { check("guard.toolSwitchBlockedDuringGesture", false, "no clip") }

        // 17. 새 프로젝트로 바꿔도 도구는 그대로(프로젝트 파일에 저장하지 않음)
        _ = LaneSelfTest.menuItem("새 프로젝트")
        if await LaneSelfTest.waitUntil(5, { s.alerts.isShowing }) { try? await Task.sleep(nanoseconds: 300_000_000); s.alerts.pressButton(2) }   // 저장 안 함
        _ = await LaneSelfTest.waitUntil(5) { s.timeline.isEmpty && !s.isDirty && !s.alerts.isShowing }
        check("tool.keptOnNewProject", s.timeline.isEmpty && s.tool == .cut, "tool \(s.tool)")
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: "키·클릭은 앱 이벤트 큐(postEvent), 메뉴는 NSMenu.performActionForItem, 툴바는 분할 단추 동작, 안내선 포인터 이동·나감은 보기에 직접")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("tool-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
