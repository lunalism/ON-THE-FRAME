#if DEBUG
import AppKit
import OnTheFrameEngine

/// 레인·연결·레인 이름 자체 검사(A-012, Debug 전용, 일반 화면에 없음). `open -n -W -a OnTheFrame.app <폴더> --args -OTFLaneTest`.
/// 실제 앱 경로(합성 마우스·키 이벤트 → TimelineNSView·LaneHeaderView·KeyRouting → ProjectStore)를 쓴다. 결과는 <폴더>/lane-result.json,
/// 마지막 내보내기는 <폴더>/lane-manifest.json으로 남겨 `otf-dev verify-lanes`가 영상 원본 프레임·소리 클릭 위치·빈틈 무음을 판정한다.
/// 합성 이벤트 검사이며 실제 키보드·한글 입력기(IME) 확인이 아니다. 한글 조합은 필드 편집기의 NSTextInputClient(setMarkedText·insertText)로 흉내 낸다.
@MainActor
enum LaneSelfTest {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }
    struct Ref: Codable { let file: String; let start: Int; let sourceIn: Int; let length: Int }
    struct Manifest: Codable { let exportFile: String; let clips: [Ref]; let audioClips: [Ref]; let durationFrames: Int }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); checkCountForMode = checks.count }
        let src = folder.appendingPathComponent("sources"), out = folder.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApp.activate()
        _ = await waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { check("setup.window", false); return finish(folder, checks, nil) }
        w.makeKeyAndOrderFront(nil)
        // 앱을 활성화할 수 없으면(다른 앱이 앞에 있어 macOS가 거절) 직접 경로로 진행한다: 마우스는 보기에 직접, 키는 같은 저장소 동작·텍스트 칸 명령.
        // 직접 경로는 KeyRouting(단축키 경로)을 거치지 않으므로 그 사실을 결과에 남긴다(단축키 경로는 shortcut-test가 맡음).
        if !(await regainFocus(w)) { direct = true }
        s.importFiles(["otf-TA.mp4", "otf-TB.mp4", "otf-hevc.mp4"].map { src.appendingPathComponent($0) })
        _ = await waitUntil(60) { s.assets.count == 3 && s.importing == 0 }
        let by = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.name, $0) })
        guard let ta = by["otf-TA.mp4"], let tb = by["otf-TB.mp4"], let hv = by["otf-hevc.mp4"] else { check("setup.import", false); return finish(folder, checks, nil) }
        s.addToTimeline(ta.id); s.addToTimeline(tb.id); s.addToTimeline(hv.id)
        _ = await waitUntil(10) { s.canPlay }
        guard let container = find(TimelineContainerView.self, w.contentView) else { check("setup.timeline", false); return finish(folder, checks, nil) }
        let tv = container.timelineView, header = container.header
        await settle()
        let t0 = s.timeline, depthAtStart = s.history.undoDepth   // 세 클립을 넣은 뒤(검사의 시작 상태)
        let vTA = t0.clips[0].id, aTA = t0.audioClips[0].id
        check("lanes.created", t0.clips.count == 3 && t0.audioClips.count == 2 && t0.partner(of: vTA)?.id == aTA && t0.partner(of: t0.clips[1].id) != nil
              && t0.partner(of: t0.clips[2].id) == nil && t0.lanes.map(\.name) == ["원본소스", "원본소리"],
              "video \(t0.clips.count) audio \(t0.audioClips.count)")

        // 1. 레인 이름(키보드 입력이 많아 먼저 한다): 두 번 클릭 → 한글 조합·입력, 편집 중 Space·Delete·⌘K는 타임라인을 바꾸지 않음, Return 확정, 실행 취소 한 단계
        func headerPoint(_ k: LaneKind) -> NSPoint { header.convert(NSPoint(x: 50, y: header.rowRect(k).midY), to: nil) }
        let beforeRename = s.timeline, dN = s.history.undoDepth, phN = s.playhead
        await mouse(.leftMouseDown, headerPoint(.video), w, clicks: 1); await mouse(.leftMouseUp, headerPoint(.video), w, clicks: 1)
        await mouse(.leftMouseDown, headerPoint(.video), w, clicks: 2); await mouse(.leftMouseUp, headerPoint(.video), w, clicks: 2)
        let editing = header.editor != nil && KeyRouting.isTextInput(w.firstResponder)
        if let ed = w.firstResponder as? NSTextView {
            ed.selectAll(nil)
            ed.setMarkedText("ㅇ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let marked = ed.hasMarkedText()
            ed.setMarkedText("인", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            ed.insertText("인", replacementRange: NSRange(location: NSNotFound, length: 0))
            ed.insertText("터뷰", replacementRange: NSRange(location: NSNotFound, length: 0))
            check("rename.koreanComposition", marked && !ed.hasMarkedText() && ed.string == "인터뷰", "text \(ed.string)")
        } else { check("rename.koreanComposition", false, "no field editor") }
        await key(49, " ", [], w)                     // Space → 글자
        await key(40, "k", [.command], w)             // ⌘K → 자르지 않음
        await key(51, "\u{7f}", [], w)                // Delete → 글자 지움(공백)
        let typed = (w.firstResponder as? NSTextView)?.string ?? ""
        if direct {
            check("rename.textEditing.direct", editing && typed == "인터뷰" && s.timeline == beforeRename, "직접 경로: 단축키 가로채기 여부는 이 실행에서 검사하지 않음, text '\(typed)'")
        } else {
            check("rename.shortcutsNotIntercepted", editing && typed == "인터뷰" && s.timeline == beforeRename && s.playhead == phN && !s.isPlaying,
                  "editing \(editing) text '\(typed)'")
        }
        await key(36, "\r", [], w)                    // Return 확정
        check("rename.returnCommits", header.editor == nil && s.timeline.lanes[0].name == "인터뷰" && s.timeline.lanes[0].id == Lane.videoID
              && s.history.undoDepth == dN + 1 && s.timeline.clips == beforeRename.clips, "name \(s.timeline.lanes[0].name)")
        await settle()
        await key(6, "z", [.command], w)
        let undone = s.timeline.lanes[0].name == "원본소스"
        await key(6, "z", [.command, .shift], w)
        check("rename.undoRedoOneStep", undone && s.timeline.lanes[0].name == "인터뷰")
        // Esc 취소
        await mouse(.leftMouseDown, headerPoint(.audio), w, clicks: 2); await mouse(.leftMouseUp, headerPoint(.audio), w, clicks: 2)
        if let ed = w.firstResponder as? NSTextView { ed.selectAll(nil); ed.insertText("임시", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let dE = s.history.undoDepth
        await key(53, "\u{1b}", [], w)
        check("rename.escCancels", header.editor == nil && s.timeline.lanes[1].name == "원본소리" && s.history.undoDepth == dE)
        // 빈 이름 → 이전 이름 유지
        await mouse(.leftMouseDown, headerPoint(.audio), w, clicks: 2); await mouse(.leftMouseUp, headerPoint(.audio), w, clicks: 2)
        if let ed = w.firstResponder as? NSTextView { ed.selectAll(nil); ed.insertText("   ", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        await key(36, "\r", [], w)
        check("rename.emptyRestores", header.editor == nil && s.timeline.lanes[1].name == "원본소리" && s.history.undoDepth == dE && (s.statusMessage ?? "").contains("이전 이름"),
              s.statusMessage ?? "")
        // 9. 가로 스크롤해도 레인 머리는 그대로(문서 보기 밖, 같은 화면 위치)
        let headerBefore = header.convert(header.bounds, to: nil)
        container.scrollView.contentView.scroll(to: NSPoint(x: 400, y: 0)); container.scrollView.reflectScrolledClipView(container.scrollView.contentView)
        await settle()
        let scrolled = container.scrollView.contentView.bounds.minX
        check("header.visibleWhileScrolling", scrolled > 0 && header.convert(header.bounds, to: nil) == headerBefore && header.superview === container && !header.isDescendant(of: tv),
              "scrolled \(scrolled)")
        container.scrollView.contentView.scroll(to: .zero); container.scrollView.reflectScrolledClipView(container.scrollView.contentView)   // 다음 클릭이 보이는 영역에 오게
        await settle()
        // 화면 좌표: 클립 가운데
        func pt(_ id: UUID, dx: CGFloat = 0) -> NSPoint {
            guard let c = s.timeline.clip(id), let k = s.timeline.lane(of: id) else { return .zero }
            let r = TimelineNSView.laneRect(k)
            return tv.convert(NSPoint(x: tv.x(c.start) + CGFloat(c.length) * tv.pixelsPerFrame / 2 + dx, y: r.midY), to: nil)
        }
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("select")], nil) }
        // 2. 소리 클립을 누르면 연결된 쌍이 함께 선택된다
        await mouse(.leftMouseDown, pt(aTA), w); await mouse(.leftMouseUp, pt(aTA), w)
        check("select.audioSelectsLinkedPair", s.selection == aTA && s.selectedIDs == [vTA, aTA], "\(s.selectedIDs.count)")
        // 2. ⌘K: 연결된 쌍을 같은 위치에서 자른다
        s.seek(to: 60)
        await key(40, "k", [.command], w)
        let t1 = s.timeline
        let vR = t1.clips[1].id, aR = t1.partner(of: vR)?.id
        check("split.linkedPair", t1.clips.map(\.length) == [60, 60, 90, 30] && t1.audioClips.map(\.length) == [60, 60, 90] && aR != nil
              && t1.syncOffset(of: vR) == 0 && t1.clips[0].link != t1.clips[1].link, "video \(t1.clips.map(\.length)) audio \(t1.audioClips.map(\.length))")
        // 3. 문맥 메뉴 "연결 해제"
        func contextItem(_ at: NSPoint, _ title: String) -> Bool {
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let m = tv.menu(for: e), let i = m.items.firstIndex(where: { $0.title.hasPrefix(title) }), m.items[i].isEnabled else { return false }
            m.performActionForItem(at: i); return true
        }
        let unlinked = contextItem(pt(vR), "연결 해제")
        check("unlink.contextMenu", unlinked && s.timeline.partner(of: vR) == nil && s.timeline.clip(vR)?.start == 60 && aR.flatMap { s.timeline.clip($0) }?.start == 60)
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("freeMove")], nil) }
        // 4. 연결 해제한 소리를 +15프레임 끌기: TB 소리와 겹쳐 거부(빨간 제안 위치), 원래대로, 기록 없음
        guard let aRid = aR, unlinked else { return finish(folder, checks + [Check(name: "setup.pairAfterSplit", pass: false, detail: "자르기·연결 해제가 되지 않아 이후 검사를 하지 않음")], nil) }
        let d0 = s.history.undoDepth, beforeOverlap = s.timeline
        let p0 = pt(aRid), dx = 15 * tv.pixelsPerFrame
        await mouse(.leftMouseDown, p0, w); await mouse(.leftMouseDragged, NSPoint(x: p0.x + 6, y: p0.y), w)
        await mouse(.leftMouseDragged, NSPoint(x: p0.x + dx, y: p0.y), w)
        let redShown = s.freeMoveProposal?.ok == false
        await mouse(.leftMouseUp, NSPoint(x: p0.x + dx, y: p0.y), w)
        check("freeMove.overlapRejected", redShown && s.timeline == beforeOverlap && s.history.undoDepth == d0 && (s.statusMessage ?? "").contains("겹칩니다"),
              s.statusMessage ?? "")
        // TB 쌍 연결 해제 뒤 TB 소리만 Delete(빈틈) → 이제 +15 이동이 빈틈에 들어간다(원래 자리 [60,75)는 빈틈)
        guard s.timeline.clips.count > 2, let aTB = s.timeline.partner(of: s.timeline.clips[2].id)?.id else {
            return finish(folder, checks + [Check(name: "setup.tbPair", pass: false, detail: "TB 쌍을 찾지 못함")], nil)
        }
        let vTB = s.timeline.clips[2].id
        s.select(aTB); s.unlinkSelection()
        await mouse(.leftMouseDown, pt(aTB), w); await mouse(.leftMouseUp, pt(aTB), w)
        await key(51, "\u{7f}", [], w)
        let tbAudioGone = s.timeline.clip(aTB) == nil && s.timeline.clip(vTB) != nil
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("freeMoveGap")], nil) }
        let p1 = pt(aRid)
        await mouse(.leftMouseDown, p1, w); await mouse(.leftMouseDragged, NSPoint(x: p1.x + 6, y: p1.y), w)
        await mouse(.leftMouseDragged, NSPoint(x: p1.x + dx, y: p1.y), w)
        // 드래그 중 Esc는 취소
        await key(53, "\u{1b}", [], w)
        let escCancelled = s.timeline.clip(aRid)?.start == 60 && s.gestureBase == nil
        await mouse(.leftMouseUp, NSPoint(x: p1.x + dx, y: p1.y), w)
        await mouse(.leftMouseDown, p1, w); await mouse(.leftMouseDragged, NSPoint(x: p1.x + 6, y: p1.y), w)
        await mouse(.leftMouseDragged, NSPoint(x: p1.x + dx, y: p1.y), w)
        await mouse(.leftMouseUp, NSPoint(x: p1.x + dx, y: p1.y), w)
        let moved = s.timeline.clip(aRid)?.start == 75 && s.timeline.audioGaps.first == 60..<75
        check("freeMove.intoGap", tbAudioGone && escCancelled && moved, "audio starts \(s.timeline.audioClips.map(\.start)) gaps \(s.timeline.audioGaps)")
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("relink")], nil) }
        // 5. 다시 연결(영상 클릭 + 소리 ⌘-클릭 → 타임라인 메뉴 "연결"): 위치 그대로, 어긋남 +15 표시
        await mouse(.leftMouseDown, pt(vR), w); await mouse(.leftMouseUp, pt(vR), w)
        await mouse(.leftMouseDown, pt(aRid), w, mods: [.command]); await mouse(.leftMouseUp, pt(aRid), w, mods: [.command])
        let canLink = s.canLink
        let linked = menuItem("연결(⌘-클릭한 클립과)")
        check("relink.keepsOffset", canLink && linked && s.timeline.partner(of: vR)?.id == aRid && s.timeline.syncOffset(of: vR) == 15 && s.timeline.clip(aRid)?.start == 75,
              "canLink \(canLink) offset \(s.timeline.syncOffset(of: vR).map(String.init) ?? "nil")")
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("ripple")], nil) }
        // 6. 어긋난 쌍(영상 [60,120), 소리 [75,135)) 리플 삭제: 구간 [60,135)에 영상 TB가 걸침 → 거부·설명, 그대로
        let beforeRipple = s.timeline, dR = s.history.undoDepth
        await mouse(.leftMouseDown, pt(vR), w); await mouse(.leftMouseUp, pt(vR), w)
        await key(51, "\u{7f}", [.shift], w)
        check("ripple.crossingRejected", s.timeline == beforeRipple && s.history.undoDepth == dR && (s.statusMessage ?? "").contains("리플 편집을 할 수 없습니다"),
              "msg \(s.statusMessage ?? "nil") same \(s.timeline == beforeRipple) depth \(s.history.undoDepth - dR) sel \(s.selection == vR) focused \(s.editorFocused) key \(NSApp.keyWindow === w) active \(NSApp.isActive)")
        // 판독용 화면 코드가 없는 소리 없는 HEVC 클립은 내보내기 전에 일반 삭제(끝 빈틈 = 검정으로 판정)
        if let hevc = s.timeline.clips.first(where: { $0.mediaID == hv.id }) { s.select(hevc.id); s.deleteSelection(ripple: false) }
        let editedTimeline = s.timeline

        // 7. 내보내기(시작 시점 스냅샷) → otf-dev verify-lanes가 독립 판정
        let dest = out.appendingPathComponent("lanes.mp4")
        s.startExport(.fromSavePanel(dest))
        _ = await waitUntil(120) { s.exportPhase == .idle }
        check("export.offsetTimeline", s.alert?.title == "내보내기 완료" && FileManager.default.fileExists(atPath: dest.path), s.alert?.message ?? "")
        if s.alerts.isShowing { s.alerts.pressButton(1) }
        _ = await waitUntil(5) { !s.alerts.isShowing }
        guard await regainFocus(w) else { return finish(folder, checks + [lostFocus("rename")], nil) }
        let names = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.id, $0.name) })
        let manifest = Manifest(exportFile: "out/lanes.mp4",
                                clips: editedTimeline.clips.map { Ref(file: names[$0.mediaID] ?? "?", start: $0.start, sourceIn: $0.sourceIn, length: $0.length) },
                                audioClips: editedTimeline.audioClips.map { Ref(file: names[$0.mediaID] ?? "?", start: $0.start, sourceIn: $0.sourceIn, length: $0.length) },
                                durationFrames: editedTimeline.durationFrames)

        // 10. 실행 취소를 끝까지 하면 처음 두 레인(연결·위치·길이)으로, 다시 실행하면 편집 뒤로
        let final = s.timeline
        while s.history.canUndo, s.history.undoDepth > depthAtStart { s.undo() }
        let atStart = s.timeline.clips == t0.clips && s.timeline.audioClips == t0.audioClips && s.timeline.lanes == t0.lanes && s.timeline.durationFrames == t0.durationFrames
        while s.history.canRedo { s.redo() }
        check("undoRedo.bothLanes", atStart && s.timeline == final)
        finish(folder, checks, manifest)
    }

    // MARK: 도우미

    static func find<T: NSView>(_ type: T.Type, _ v: NSView?) -> T? {
        guard let v else { return nil }
        if let t = v as? T { return t }
        for c in v.subviews { if let t = find(type, c) { return t } }
        return nil
    }
    static func menuItem(_ title: String) -> Bool {
        func all(_ m: NSMenu?) -> [NSMenuItem] { guard let m else { return [] }; return m.items.flatMap { [$0] + all($0.submenu) } }
        guard let it = all(NSApp.mainMenu).first(where: { $0.title == title }), let m = it.menu else { return false }
        m.delegate?.menuNeedsUpdate?(m)
        guard let i = m.items.firstIndex(where: { $0.title == title }), m.items[i].isEnabled else { return false }
        m.performActionForItem(at: i)
        return true
    }
    /// 직접 경로(활성화 불가 시)
    static var direct = false
    /// 직접 경로로 바뀐 시점(그 앞 검사 수)과 기록용 검사 수
    static var directFromCheck = 0
    static var checkCountForMode = 0
    static func lostFocus(_ section: String) -> Check {
        Check(name: "harness.focusLost", pass: false, detail: "\(section) 앞에서 앱이 활성 상태를 잃음(다른 앱이 앞에 있음). 이후 검사를 하지 않았다. active \(NSApp.isActive) key \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "nil") sheet \(ProjectStore.shared.editorWindow?.attachedSheet != nil) alerts \(ProjectStore.shared.alerts.isShowing)")
    }
    static func regainFocus(_ w: NSWindow) async -> Bool {
        if direct { return true }
        NSApp.activate(); w.makeKeyAndOrderFront(nil)
        let ok = await waitUntil(3) { NSApp.isActive && NSApp.keyWindow === w }
        await settle()
        if !ok { direct = true; directFromCheck = checkCountForMode }   // 중간에 활성 상태를 잃으면 그 뒤는 직접 경로
        return true
    }
    static func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags, _ w: NSWindow) async {
        if direct { directKey(code, mods, w); await settle(); return }
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
        await settle()
    }
    static func mouse(_ t: NSEvent.EventType, _ p: NSPoint, _ w: NSWindow, mods: NSEvent.ModifierFlags = [], clicks: Int = 1) async {
        if direct, let cv = w.contentView, let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: t == .leftMouseUp ? 0 : 1) {
            // hitTest는 받는 보기의 상위 보기 좌표를 받는다
            let target = (t == .leftMouseDown ? cv.hitTest(cv.superview?.convert(p, from: nil) ?? p) : directTarget) ?? cv
            if t == .leftMouseDown { directTarget = target }
            switch t {
            case .leftMouseDown: target.mouseDown(with: e)
            case .leftMouseDragged: target.mouseDragged(with: e)
            default: target.mouseUp(with: e)
            }
            await settle(); return
        }
        if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: t == .leftMouseUp ? 0 : 1) {
            NSApp.postEvent(e, atStart: false)
        }
        await settle()
    }
    @MainActor final class Flag { var v = false }
    static var directTarget: NSView?
    /// 직접 경로의 키: 텍스트 칸 편집 중이면 텍스트 칸 명령, 아니면 단축키와 같은 저장소 동작
    static func directKey(_ code: UInt16, _ mods: NSEvent.ModifierFlags, _ w: NSWindow) {
        let s = ProjectStore.shared
        let ed = w.firstResponder as? NSTextView
        switch (code, mods.intersection([.command, .shift])) {
        case (36, []): ed?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case (53, []): if let ed { ed.doCommand(by: #selector(NSResponder.cancelOperation(_:))) } else { w.firstResponder?.cancelOperation(nil) }
        case (49, []): if let ed { ed.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0)) } else { s.togglePlay() }
        case (51, []): if let ed { ed.deleteBackward(nil) } else { s.deleteSelection(ripple: false) }
        case (51, [.shift]): if ed == nil { s.deleteSelection(ripple: true) }
        case (40, [.command]): if ed == nil { s.splitAtPlayhead() }
        case (6, [.command]): if let ed { ed.undoManager?.undo() } else { s.undo() }
        case (6, [.command, .shift]): if let ed { ed.undoManager?.redo() } else { s.redo() }
        // 2026-10-23(자막 자체 검사): 도구 키·⌘Return·복사·붙여넣기(직접 경로에서도 같은 저장소 동작·글 칸 명령)
        case (9, []): if let ed { ed.insertText("v", replacementRange: NSRange(location: NSNotFound, length: 0)) } else { s.setTool(.selection) }
        case (8, []): if let ed { ed.insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0)) } else { s.setTool(.cut) }
        case (17, []): if let ed { ed.insertText("t", replacementRange: NSRange(location: NSNotFound, length: 0)) } else { s.setTool(.text) }
        case (36, [.command]): (ed as? CommandReturnTextView)?.onCommandReturn?()
        case (8, [.command]): if ed == nil, s.canCopy { s.copySelection() }   // 키 창 확인 없이 같은 클립 복사·붙여넣기
        case (9, [.command]): if ed == nil, s.canPaste { s.pasteAtPlayhead() }
        default: break
        }
    }
    static func settle() async {
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
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    static func finish(_ folder: URL, _ checks: [Check], _ m: Manifest?) {
        let checks = checks + [Check(name: direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: direct ? "검사 \(directFromCheck)개 뒤부터 앱을 활성화할 수 없어(다른 앱이 앞에 있음) 마우스는 보기에 직접, 키는 같은 저장소 동작·텍스트 칸 명령으로 보냄. KeyRouting 경로는 이 실행에서 검사하지 않음"
                                                    : "합성 이벤트를 앱 이벤트 큐로 보냄(KeyRouting 경로 포함)")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let m, let d = try? enc.encode(m) { try? d.write(to: folder.appendingPathComponent("lane-manifest.json")) }
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("lane-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
