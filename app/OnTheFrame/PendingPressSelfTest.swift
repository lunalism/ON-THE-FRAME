#if DEBUG
import AppKit
import OnTheFrameEngine

/// 누름 대기 중 편집 명령 보호(CP-08, 2026-10-12) 자체 검사(Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFPendingPressTest`.
/// 타임라인 클립 본문을 누른 채 4 pt 전(누름 대기, 저장소 끌기 없음)에 Delete·⌘Z·⌘V·⌘K를 보내고, 같은 누름의 늦은 끌기·놓기를 보낸다.
/// 명령은 그대로 실행되고, 늦은 이벤트는 지운 클립 ID를 다시 고르거나 원래 클립을 옮기지 않아야 한다. 이어서 새 누름의 끌기는 평소대로 한 단계.
/// 마우스·키는 앱 이벤트 큐(실제 KeyRouting 경로). 결과는 <폴더>/pendingpress-result.json. 생성 fixture(otf-TA)만, 저장하지 않는다.
@MainActor
enum PendingPressSelfTest {
    typealias Check = LaneSelfTest.Check

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { return finish(folder, [Check(name: "setup.window", pass: false, detail: "")]) }
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, [LaneSelfTest.lostFocus("setup")]) }

        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        guard let asset = s.assets.first else { return finish(folder, [Check(name: "setup.import", pass: false, detail: "")]) }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        s.addToTimeline(asset.id)
        await LaneSelfTest.settle()
        guard let a = s.timeline.clips.first?.id, s.timeline.partner(of: a) != nil,
              let tv = LaneSelfTest.find(TimelineNSView.self, w.contentView) else { return finish(folder, [Check(name: "setup.place", pass: false, detail: "")]) }
        tv.enclosingScrollView?.contentView.scroll(to: .zero)
        if let sv = tv.enclosingScrollView { sv.reflectScrolledClipView(sv.contentView) }
        await LaneSelfTest.settle()

        struct St: Equatable { let t: Timeline; let sel: UUID?; let depth: Int; let redo: Bool; let dirty: Bool }
        func st() -> St { St(t: s.timeline, sel: s.selection, depth: s.history.undoDepth, redo: s.history.canRedo, dirty: s.isDirty) }
        func pt(_ frame: Int, lane: UUID = Lane.videoID) -> NSPoint {
            guard let r = tv.laneRect(lane) else { return .zero }
            return tv.convert(NSPoint(x: tv.x(frame) + 0.3, y: r.midY), to: nil)
        }
        func body(_ id: UUID) -> NSPoint { pt((s.timeline.clip(id)?.start ?? 0) + 20, lane: s.timeline.clip(id)?.lane ?? Lane.videoID) }
        /// 누름 대기: 클립 본문 누름 + 4 pt 안 끌기(저장소 끌기 없음)
        func pressPending(_ p: NSPoint) async -> Bool {
            await LaneSelfTest.mouse(.leftMouseDown, p, w)
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p.x + 2, y: p.y), w)
            return s.gestureBase == nil && tv.dragNameForTest == "pending"
        }
        /// 같은 누름의 늦은 끌기(4 pt 넘김)와 놓기. 끌기 직후의 상태(저장소 끌기, 보기 상태, 선택)를 돌려준다.
        func lateDragRelease(_ p: NSPoint) async -> (gesture: Bool, drag: String, sel: UUID?) {
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p.x + 40, y: p.y), w)
            let mid = (s.gestureBase != nil, tv.dragNameForTest, s.selection)
            await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: p.x + 40, y: p.y), w)
            return mid
        }
        func key(_ code: UInt16, _ ch: String, _ mods: NSEvent.ModifierFlags) async {
            w.makeFirstResponder(tv)
            if LaneSelfTest.direct {   // 직접 경로: 단축키와 같은 저장소 동작(KeyRouting 경로는 보지 않음, 결과에 표시)
                switch (code, mods) {
                case (51, []): s.deleteSelection(ripple: false)
                case (6, [.command]): s.undo()
                case (9, [.command]): s.pasteAtPlayhead()
                case (40, [.command]): s.splitAtPlayhead()
                default: break
                }
                await LaneSelfTest.settle(); return
            }
            await LaneSelfTest.key(code, ch, mods, w)
        }
        func idText(_ id: UUID?) -> String { id.map { String($0.uuidString.prefix(4)) } ?? "nil" }

        // 클립보드에 A(연결된 쌍)를 넣고, 재생 헤드를 A 끝 뒤에 둔다(붙여넣기 자리). 저장 상태는 각 경우의 전후로 비교한다.
        s.select(a); s.copySelection()
        let aEnd = s.timeline.clip(a)?.end ?? 120
        s.seek(to: aEnd + 30)
        await LaneSelfTest.settle()

        // 1. Delete: 누름 대기 중 삭제(빈틈 남김) → 늦은 끌기·놓기가 지운 ID를 고르거나 끌기를 시작하지 않는다
        s.select(nil); await LaneSelfTest.settle()
        let pre1 = st()
        let p1 = body(a)
        let pend1 = await pressPending(p1)
        await key(51, "\u{7f}", [])
        let afterDel = st()
        let deleted = s.timeline.clip(a) == nil && afterDel.depth == pre1.depth + 1 && afterDel.dirty
        let late1 = await lateDragRelease(p1)
        check("delete.commandRunsDuringPendingPress", pend1 && deleted, "pending \(pend1) deleted \(s.timeline.clip(a) == nil) depth +\(afterDel.depth - pre1.depth) dirty \(afterDel.dirty)")
        check("delete.lateDragNoStaleTarget", !late1.gesture && late1.drag == "none" && late1.sel != a && st() == afterDel,
              "late gesture \(late1.gesture) drag \(late1.drag) sel \(idText(late1.sel)) (deleted \(idText(a))) unchanged \(st() == afterDel) selNow \(idText(s.selection))")
        if s.gestureBase != nil { s.cancelGesture() }
        await key(6, "z", [.command])
        check("delete.undoRestores", s.timeline == pre1.t && s.history.undoDepth == pre1.depth, "depth \(s.history.undoDepth - pre1.depth)")

        // 2. Undo: 옮기기 한 단계 뒤, 누름 대기 중 ⌘Z → 늦은 끌기가 되돌린 클립을 다시 옮기거나 다시 실행 기록을 지우지 않는다
        let pre2a = st()
        let b2 = body(a)
        await LaneSelfTest.mouse(.leftMouseDown, b2, w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: b2.x + 8, y: b2.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: b2.x + CGFloat(30) * tv.pixelsPerFrame, y: b2.y), w)
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: b2.x + CGFloat(30) * tv.pixelsPerFrame, y: b2.y), w)
        let moved2 = s.timeline.clip(a)?.start == (pre2a.t.clip(a)?.start ?? 0) + 30 && s.history.undoDepth == pre2a.depth + 1
        let p2 = body(a)
        let pend2 = await pressPending(p2)
        await key(6, "z", [.command])
        let afterUndo = st()
        let undone = s.timeline == pre2a.t && afterUndo.redo
        let late2 = await lateDragRelease(p2)
        check("undo.commandRunsDuringPendingPress", moved2 && pend2 && undone, "moved \(moved2) pending \(pend2) undone \(undone) redo \(afterUndo.redo)")
        check("undo.lateDragNoMoveKeepsRedo", !late2.gesture && late2.drag == "none" && st() == afterUndo,
              "late gesture \(late2.gesture) drag \(late2.drag) start \(s.timeline.clip(a).map { "\($0.start)" } ?? "nil") redo \(s.history.canRedo) depth \(s.history.undoDepth - afterUndo.depth)")
        if s.gestureBase != nil { s.cancelGesture() }
        while s.history.undoDepth > pre2a.depth { s.undo() }
        if s.timeline != pre2a.t { s.undo() }

        // 3. Paste: 누름 대기 중 ⌘V → 붙여 넣은 클립이 선택으로 남고, 늦은 끌기가 원래 클립을 옮기지 않는다
        s.seek(to: (s.timeline.clip(a)?.end ?? 120) + 30); await LaneSelfTest.settle()
        let pre3 = st()
        let p3 = body(a)
        let pend3 = await pressPending(p3)
        await key(9, "v", [.command])
        let afterPaste = st()
        let pasted = afterPaste.sel.flatMap { s.timeline.clip($0) }
        let pasteOK = afterPaste.depth == pre3.depth + 1 && pasted != nil && afterPaste.sel != a && s.timeline.clip(a) == pre3.t.clip(a)
        let late3 = await lateDragRelease(p3)
        check("paste.commandRunsDuringPendingPress", pend3 && pasteOK, "pending \(pend3) depth +\(afterPaste.depth - pre3.depth) sel \(idText(afterPaste.sel)) pastedStart \(pasted.map { "\($0.start)" } ?? "nil")")
        check("paste.lateDragKeepsPastedSelectionNoMove", !late3.gesture && late3.drag == "none" && late3.sel == afterPaste.sel && st() == afterPaste,
              "late gesture \(late3.gesture) drag \(late3.drag) sel \(idText(late3.sel)) (pasted \(idText(afterPaste.sel)), original \(idText(a))) originalStart \(s.timeline.clip(a).map { "\($0.start)" } ?? "nil")/\(pre3.t.clip(a).map { "\($0.start)" } ?? "nil") depth +\(s.history.undoDepth - pre3.depth)")
        if s.gestureBase != nil { s.cancelGesture() }

        // 4. 같은 길의 다른 명령(⌘K 자르기): 누른 클립 ID가 사라진다 → 늦은 끌기가 사라진 ID를 고르지 않는다
        s.seek(to: (s.timeline.clip(a)?.start ?? 0) + 60); await LaneSelfTest.settle()
        s.select(a); await LaneSelfTest.settle()
        let pre4 = st()
        let p4 = pt((s.timeline.clip(a)?.start ?? 0) + 20)
        let pend4 = await pressPending(p4)
        await key(40, "k", [.command])
        let afterSplit = st()
        let split = s.timeline.clip(a) == nil && afterSplit.depth == pre4.depth + 1
        let late4 = await lateDragRelease(p4)
        check("split.lateDragNoStaleTarget", pend4 && split && !late4.gesture && late4.drag == "none" && late4.sel != a && st() == afterSplit,
              "pending \(pend4) split \(split) late gesture \(late4.gesture) drag \(late4.drag) sel \(idText(late4.sel)) unchanged \(st() == afterSplit)")
        if s.gestureBase != nil { s.cancelGesture() }

        // 5. 새 누름의 끌기는 평소대로: 붙여 넣은 클립(3)을 끌어 옮기면 한 단계, 선택은 그 클립
        _ = await LaneSelfTest.regainFocus(w)
        if let q = afterPaste.sel, s.timeline.clip(q) != nil {
            let pre5 = st(), q0 = s.timeline.clip(q)!.start
            let b5 = body(q)
            await LaneSelfTest.mouse(.leftMouseDown, b5, w)
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: b5.x + 8, y: b5.y), w)
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: b5.x + CGFloat(20) * tv.pixelsPerFrame, y: b5.y), w)
            await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: b5.x + CGFloat(20) * tv.pixelsPerFrame, y: b5.y), w)
            check("fresh.dragAfterCommandMovesOneStep", s.gestureBase == nil && s.history.undoDepth == pre5.depth + 1 && s.timeline.clip(q)?.start == q0 + 20 && s.selection == q,
                  "start \(s.timeline.clip(q).map { "\($0.start)" } ?? "nil")/\(q0 + 20) depth +\(s.history.undoDepth - pre5.depth) sel \(idText(s.selection))")
        } else { check("fresh.dragAfterCommandMovesOneStep", false, "no pasted clip") }

        // 6. 보통 클릭(움직임 없음): 선택만, 기록·타임라인 그대로
        let pre6 = st()
        let target6 = s.timeline.clips.first(where: { $0.id != s.selection })?.id
        if let t6 = target6 {
            let b6 = body(t6)
            await LaneSelfTest.mouse(.leftMouseDown, b6, w)
            await LaneSelfTest.mouse(.leftMouseUp, b6, w)
            check("click.selectsOnly", s.selection == t6 && s.timeline == pre6.t && s.history.undoDepth == pre6.depth && tv.dragNameForTest == "none", "sel \(idText(s.selection))")
        } else { check("click.selectsOnly", false, "no other clip") }

        // 7. 누름 대기 중 타임라인을 바꾸지 않는 명령(재생 헤드 이동 →)은 누름 대기를 지우지 않는다: 이어 끌면 평소대로 옮기기
        //    (붙여 넣은 클립: 뒤에 다른 클립이 없어 오른쪽으로 옮겨도 겹치지 않는다)
        if let t7 = afterPaste.sel, s.timeline.clip(t7) != nil {
            let pre7 = st(), s0 = s.timeline.clip(t7)!.start
            let b7 = body(t7)
            let pend7 = await pressPending(b7)
            await key(124, "\u{f703}", [])
            let still = tv.dragNameForTest == "pending"
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: b7.x + CGFloat(10) * tv.pixelsPerFrame, y: b7.y), w)
            await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: b7.x + CGFloat(10) * tv.pixelsPerFrame, y: b7.y), w)
            check("step.keepsPendingThenMoves", pend7 && still && s.history.undoDepth == pre7.depth + 1 && s.timeline.clip(t7)?.start == s0 + 10,
                  "pending \(pend7) still \(still) start \(s.timeline.clip(t7).map { "\($0.start)" } ?? "nil")/\(s0 + 10)")
        } else { check("step.keepsPendingThenMoves", false, "no selection") }
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: LaneSelfTest.direct ? "앱을 활성화할 수 없어 마우스는 보기에 직접, 키는 같은 저장소 동작으로 보냄(KeyRouting 경로 미검사)"
                                                                 : "마우스·키를 앱 이벤트 큐로 보냄(KeyRouting 경로 포함)")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("pendingpress-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
