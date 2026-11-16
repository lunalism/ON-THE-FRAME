#if DEBUG
import AppKit
import OnTheFrameEngine

/// 끌기 중 편집 보호(CP-01, 2026-10-11 체크포인트 리뷰) 자체 검사(Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFGestureGuardTest`.
/// - 실제 마우스 이벤트(앱 이벤트 큐)로 트림 끌기를 시작하고, 끌기 중 오른쪽 누름(타임라인·레인 머리)을 보낸다. 문맥 메뉴가 뜨면 메뉴 추적 루프 안에서
///   항목 상태를 읽고, 왼쪽 놓기를 메뉴 추적 중에 보내 메뉴가 그것을 먹는지 보고 닫는다(`-OTFGestureGuardPick`이면 "연결 해제"를 실행한다 — 고치기 전 재현용).
/// - 창 초점을 실제로 잃어 놓기 이벤트가 오지 않는 경우는 합성할 수 없어, 저장소의 끌기 시작(beginGesture)으로 "끝나지 않은 끌기" 상태를 만들고
///   모든 편집 진입점을 부른다.
/// 위험한 단계 앞마다 <폴더>/gestureguard-progress.txt에 단계를 남긴다(앱이 멈추면 어디서 멈췄는지 남는다). 결과는 gestureguard-result.json.
/// 생성 fixture(otf-TA)만, 저장하지 않는다.
@MainActor
enum GestureGuardSelfTest {
    typealias Check = LaneSelfTest.Check
    /// 문맥 메뉴 관찰: 메뉴 추적이 시작되면 항목을 읽고, 추적 루프 안(타이머, 공통 모드)에서 왼쪽 놓기를 보내거나 항목을 실행한 뒤 닫는다.
    @MainActor final class MenuProbe {
        var seen = false, info = "no menu", picked = false, upEaten: Bool?
        var token: NSObjectProtocol?
        var menu: NSMenu?
        let window: NSWindow, sendLeftUp: NSPoint?, pickTitle: String?, progress: URL
        init(window: NSWindow, sendLeftUp: NSPoint?, pickTitle: String?, progress: URL) {
            self.window = window; self.sendLeftUp = sendLeftUp; self.pickTitle = pickTitle; self.progress = progress
        }
        func began(_ m: NSMenu) {
            menu = m; seen = true
            info = m.items.filter { !$0.isSeparatorItem }.map { "\($0.title)=\($0.isEnabled)" }.joined(separator: "; ")
            let t = Timer(timeInterval: 0.2, repeats: false) { [self] _ in MainActor.assumeIsolated { self.act() } }
            RunLoop.main.add(t, forMode: .common)
        }
        func act() {
            guard let m = menu else { return }
            let s = ProjectStore.shared
            if let up = sendLeftUp {
                let before = s.gestureBase != nil
                GestureGuardSelfTest.post(.leftMouseUp, up, window, atStart: true)
                let t2 = Timer(timeInterval: 0.3, repeats: false) { [self] _ in
                    MainActor.assumeIsolated { self.upEaten = before && s.gestureBase != nil; self.menu?.cancelTracking() }
                }
                RunLoop.main.add(t2, forMode: .common)
                return
            }
            if let title = pickTitle, let i = m.items.firstIndex(where: { $0.title.hasPrefix(title) }), m.items[i].isEnabled {
                GestureGuardSelfTest.step("pick \(title) gestureBase=\(s.gestureBase != nil)", progress)
                picked = true
                m.performActionForItem(at: i)
                GestureGuardSelfTest.step("after-pick", progress)
            }
            m.cancelTracking()
        }
    }
    static func step(_ m: String, _ progress: URL) {
        let line = "\(m)\n"
        if let h = try? FileHandle(forWritingTo: progress) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: progress, atomically: true, encoding: .utf8) }
    }
    static func post(_ t: NSEvent.EventType, _ p: NSPoint, _ w: NSWindow, atStart: Bool = false) {
        if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: (t == .rightMouseDown || t == .leftMouseDown) ? 1 : 0) {
            NSApp.postEvent(e, atStart: atStart)
        }
    }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        let pick = ProcessInfo.processInfo.arguments.contains("-OTFGestureGuardPick")
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        let progress = folder.appendingPathComponent("gestureguard-progress.txt")
        func step(_ m: String) { Self.step(m, progress) }
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
        guard let v0 = s.timeline.clips.first?.id, let a0 = s.timeline.partner(of: v0)?.id,
              let tv = LaneSelfTest.find(TimelineNSView.self, w.contentView),
              let header = LaneSelfTest.find(LaneHeaderView.self, w.contentView) else { return finish(folder, [Check(name: "setup.place", pass: false, detail: "")]) }
        tv.enclosingScrollView?.contentView.scroll(to: .zero)
        if let sv = tv.enclosingScrollView { sv.reflectScrolledClipView(sv.contentView) }
        await LaneSelfTest.settle()
        let v1 = Lane.videoID
        func pt(_ frame: Int, dx: CGFloat = 0.3) -> NSPoint {
            guard let r = tv.laneRect(v1) else { return .zero }
            return tv.convert(NSPoint(x: tv.x(frame) + dx, y: r.midY), to: nil)
        }
        let headerPoint = header.convert(NSPoint(x: 40, y: header.rowRect(v1).midY), to: nil)
        /// 오른쪽 누름을 보내고, 메뉴가 뜨면 추적 루프 안에서 항목을 읽는다. sendLeftUp이면 메뉴가 열린 동안 왼쪽 놓기를 보낸 뒤 닫고, 놓기가 먹혔는지 기록한다.
        func rightClick(_ p: NSPoint, sendLeftUp: NSPoint?, pickTitle: String?) async -> MenuProbe {
            let probe = MenuProbe(window: w, sendLeftUp: sendLeftUp, pickTitle: pickTitle, progress: progress)
            probe.token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [probe] n in
                nonisolated(unsafe) let m = n.object as? NSMenu   // 주 대기열에서 받은 알림(queue: .main)
                MainActor.assumeIsolated { if let m { probe.began(m) } }
            }
            Self.post(.rightMouseDown, p, w); Self.post(.rightMouseUp, p, w)
            _ = await LaneSelfTest.waitUntil(2) { probe.seen }
            if probe.seen { _ = await LaneSelfTest.waitUntil(3) { probe.upEaten != nil || probe.picked || sendLeftUp == nil } }
            await LaneSelfTest.settle()
            if let tk = probe.token { NotificationCenter.default.removeObserver(tk) }
            return probe
        }

        // 1. 끌기 중 오른쪽 누름(타임라인 클립): 문맥 메뉴가 뜨지 않아야 하고(뜨면 연결 해제가 기록에 닿아 멈추고, 놓기도 메뉴가 먹는다), 놓기로 끌기가 끝나 한 단계
        s.select(v0); await LaneSelfTest.settle()
        let depth0 = s.history.undoDepth, len0 = s.timeline.clip(v0)?.length ?? 0
        let edge = pt(120, dx: -2)
        let dragTo = NSPoint(x: edge.x - CGFloat(10) * tv.pixelsPerFrame, y: edge.y)
        await LaneSelfTest.mouse(.leftMouseDown, edge, w)
        await LaneSelfTest.mouse(.leftMouseDragged, dragTo, w)
        check("setup.trimGestureActive", s.gestureBase != nil)
        step("right-click-clip-during-trim gestureBase=\(s.gestureBase != nil)")
        let m1 = await rightClick(pt(60), sendLeftUp: pick ? nil : dragTo, pickTitle: pick ? "연결 해제" : nil)
        step("clip-menu seen=\(m1.seen) picked=\(m1.picked) upEaten=\(String(describing: m1.upEaten)) gestureBase=\(s.gestureBase != nil)")
        check("menu.clipNotShownDuringGesture", !m1.seen && s.gestureBase != nil,
              "menu shown \(m1.seen) [\(m1.info)] leftUpEatenByMenu \(String(describing: m1.upEaten)) gestureBase \(s.gestureBase != nil)")
        step("right-click-header-during-trim")
        let m2 = await rightClick(headerPoint, sendLeftUp: nil, pickTitle: nil)
        check("menu.headerNotShownDuringGesture", !m2.seen && s.gestureBase != nil, "menu shown \(m2.seen) [\(m2.info)]")
        if s.gestureBase != nil { await LaneSelfTest.mouse(.leftMouseUp, dragTo, w) }
        check("trim.commitsOneStepAfterRightClick", s.gestureBase == nil && s.history.undoDepth == depth0 + 1 && s.timeline.clip(v0)?.length == len0 - 10
              && s.timeline.partner(of: v0)?.id == a0, "depth \(s.history.undoDepth - depth0) length \(s.timeline.clip(v0).map { "\($0.length)" } ?? "nil")")

        // 2. 끝나지 않은 끌기(놓기를 받지 못한 경우와 같은 상태)에서 모든 편집 진입점: 멈추지 않고, 기록·타임라인을 바꾸지 않는다
        s.select(v0)
        let before = s.timeline, beforeDepth = s.history.undoDepth
        s.beginGesture(select: v0)
        s.updateTrim(v0, edge: .end, delta: -5)
        let preview = s.history.timeline
        let calls: [(String, () -> Void)] = [
            ("unlinkSelection", { s.unlinkSelection() }),
            ("linkSelection", { s.select(v0); s.select(a0, extend: true); s.linkSelection() }),
            ("addToTimeline", { s.addToTimeline(asset.id) }),
            ("placeMedia", { s.placeMedia(asset.id, atFrame: 400, lane: nil) }),
            ("renameLane", { _ = s.renameLane(v1, to: "끌기 중 이름") }),
            ("splitAtPlayhead", { s.seek(to: 30); s.splitAtPlayhead() }),
            ("deleteSelection", { s.deleteSelection(ripple: false) }),
            ("rippleDelete", { s.deleteSelection(ripple: true) }),
            ("setClipAudio", { s.setClipAudio(a0, volumePercent: 50) }),
            ("setTransform", { s.setTransform(v0, ClipTransform(scalePermille: 500, offsetX: 0, offsetY: 0)) }),
            ("relocateSelection", { s.relocateSelection(lane: v1, partnerLane: nil) }),
            ("cutClip", { s.cutClip(v0, atFrame: 50) }),
            ("addLane", { s.addLane(.video) }),
        ]
        var unchanged: [String] = [], changed: [String] = []
        for (name, call) in calls {
            step("guard-call \(name)")
            call()
            if s.history.timeline == preview && s.history.undoDepth == beforeDepth && s.history.inGesture && s.gestureBase != nil { unchanged.append(name) } else { changed.append(name) }
        }
        step("guard-calls-done")
        check("guard.editEntryPointsDuringGesture", changed.isEmpty, "ok \(unchanged.count)/\(calls.count) changed \(changed)")
        s.cancelGesture(); await LaneSelfTest.settle()
        check("guard.cancelRestoresAfterBlockedCalls", s.gestureBase == nil && s.timeline == before && s.history.undoDepth == beforeDepth)

        // 3. 보통 끌기 그대로: Esc 취소(기록 없음), 끌어 옮기기 한 단계
        s.select(v0); await LaneSelfTest.settle()
        let t3 = s.timeline, d3 = s.history.undoDepth
        let edge3 = pt(s.timeline.clip(v0)?.end ?? 110, dx: -2)   // 1에서 줄인 뒤의 끝 가장자리
        await LaneSelfTest.mouse(.leftMouseDown, edge3, w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: edge3.x - 30, y: edge3.y), w)
        let midChanged = s.timeline != t3
        w.makeFirstResponder(tv); await LaneSelfTest.key(53, "\u{1b}", [], w)
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: edge3.x - 30, y: edge3.y), w)
        check("drag.escCancels", midChanged && s.timeline == t3 && s.history.undoDepth == d3 && s.gestureBase == nil, "mid changed \(midChanged)")
        let body = pt(40)
        await LaneSelfTest.mouse(.leftMouseDown, body, w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: body.x + 8, y: body.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: body.x + CGFloat(30) * tv.pixelsPerFrame, y: body.y), w)
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: body.x + CGFloat(30) * tv.pixelsPerFrame, y: body.y), w)
        check("drag.moveCommitsOneStep", s.gestureBase == nil && s.history.undoDepth == d3 + 1 && s.timeline.clip(v0)?.start == 30
              && s.timeline.partner(of: v0)?.start == 30, "start \(s.timeline.clip(v0).map { "\($0.start)" } ?? "nil")")

        // 4. 끌기가 없을 때 문맥 메뉴는 그대로: 타임라인 메뉴의 "연결 해제"가 켜져 있고 실행하면 한 단계
        let d4 = s.history.undoDepth
        let m3 = await rightClick(pt(60), sendLeftUp: nil, pickTitle: "연결 해제")
        check("menu.clipWorksWithoutGesture", m3.seen && m3.picked && s.timeline.partner(of: v0) == nil && s.history.undoDepth == d4 + 1, "seen \(m3.seen) [\(m3.info)]")
        let m4 = await rightClick(headerPoint, sendLeftUp: nil, pickTitle: nil)
        check("menu.headerWorksWithoutGesture", m4.seen, "[\(m4.info)]")

        // 5. 끌기 중단(D-031): 편집기 창이 키 상태를 잃거나 앱이 비활성이 되면 끌기를 취소(끌기 전 타임라인·선택·기록·저장 상태), 보기의 끌기 상태도 지움.
        //    뒤늦은 끌기·놓기 이벤트는 아무것도 하지 않고, 단축키는 다시 동작한다. 남은 끌기는 다음 끌기와 함께 확정되지 않는다.
        struct St: Equatable { let t: Timeline; let sel: UUID?; let depth: Int; let dirty: Bool }
        func st() -> St { St(t: s.timeline, sel: s.selection, depth: s.history.undoDepth, dirty: s.isDirty) }
        func startTrim() async -> (NSPoint, St) {
            s.select(v0); await LaneSelfTest.settle()
            let pre = st()
            let e = pt(s.timeline.clip(v0)?.end ?? 100, dx: -2)
            await LaneSelfTest.mouse(.leftMouseDown, e, w)
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: e.x - 30, y: e.y), w)
            return (NSPoint(x: e.x - 30, y: e.y), pre)
        }
        func auxKey() async -> NSWindow {
            let aux = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 220, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
            aux.isReleasedWhenClosed = false
            aux.title = "검사 보조 창"
            aux.makeKeyAndOrderFront(nil)
            _ = await LaneSelfTest.waitUntil(2) { NSApp.keyWindow === aux }
            await LaneSelfTest.settle()
            return aux
        }
        _ = await LaneSelfTest.regainFocus(w)
        // 5a. 실제 키 창 바뀜(앱 안 보조 창이 키 창이 됨)
        let (late, pre5) = await startTrim()
        let active5 = s.gestureBase != nil && tv.dragNameForTest == "trim" && s.timeline != pre5.t
        let n5 = s.interruptCountForTest
        let aux = await auxKey()
        let keyMoved = NSApp.keyWindow === aux
        check("interrupt.keyLossCancelsTimelineDrag", active5 && keyMoved && s.gestureBase == nil && st() == pre5 && tv.dragNameForTest == "none" && s.interruptCountForTest == n5 + 1,
              "active \(active5) keyMoved \(keyMoved) gesture \(s.gestureBase != nil) restored \(st() == pre5) drag \(tv.dragNameForTest) count +\(s.interruptCountForTest - n5)")
        aux.orderOut(nil); aux.close()
        _ = await LaneSelfTest.regainFocus(w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: late.x - 20, y: late.y), w)
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: late.x - 20, y: late.y), w)
        let lateNoop = st() == pre5 && s.gestureBase == nil
        w.makeFirstResponder(tv); await LaneSelfTest.key(8, "c", [], w)
        let toolC = s.tool == .cut
        await LaneSelfTest.key(9, "v", [], w)
        check("interrupt.lateEventsNoopShortcutsWork", lateNoop && toolC && s.tool == .selection, "late noop \(lateNoop) C \(toolC) tool \(s.tool)")

        // 5a-2. 옮기기 끌기 중 실제 키 창 바뀜
        s.select(v0); await LaneSelfTest.settle()
        let preM = st()
        let bm = pt((s.timeline.clip(v0)?.start ?? 0) + 10)
        await LaneSelfTest.mouse(.leftMouseDown, bm, w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: bm.x + 8, y: bm.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: bm.x + 40, y: bm.y), w)
        let activeM = s.gestureBase != nil && tv.dragNameForTest == "free" && s.timeline != preM.t
        let auxM = await auxKey()
        let okM = s.gestureBase == nil && st() == preM && tv.dragNameForTest == "none"
        auxM.orderOut(nil); auxM.close()
        _ = await LaneSelfTest.regainFocus(w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: bm.x + 60, y: bm.y), w)
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: bm.x + 60, y: bm.y), w)
        check("interrupt.keyLossCancelsTimelineMove", activeM && okM && st() == preM, "active \(activeM) cancelled \(okM) after late events \(st() == preM)")

        // 5a-3. 옮기기 누름 대기(4 pt 전, 저장소 끌기 없음) 중 실제 키 창 바뀜: 보기의 대기 상태를 지우고, 같은 누름의 늦은 끌기가 새 옮기기를 시작하지 않는다
        //       (2026-10-12 소유자 로그 조사: 중단 알림이 "끌기 없음"이면 보기에 알리지 않아 대기 상태가 남았다)
        for (label, viaApp) in [("KeyLoss", false), ("AppDeactivation", true)] {
            s.select(v0); await LaneSelfTest.settle()
            let preP = st(), nP = s.interruptCountForTest
            let bp = pt((s.timeline.clip(v0)?.start ?? 0) + 10)
            await LaneSelfTest.mouse(.leftMouseDown, bp, w)
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: bp.x + 2, y: bp.y), w)
            let pendingP = s.gestureBase == nil && tv.dragNameForTest == "pending"
            var auxP: NSWindow?
            if viaApp { NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp); await LaneSelfTest.settle() }
            else { auxP = await auxKey() }
            let clearedP = tv.dragNameForTest == "none" && s.gestureBase == nil
            // 늦은 끌기·놓기(같은 누름): 키 창이 돌아오기 전에 보낸다(실제 앱 전환에서 누른 채 끌면 이벤트는 누른 창으로 계속 온다)
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: bp.x + 40, y: bp.y), w)
            let noRestart = s.gestureBase == nil && tv.dragNameForTest == "none"
            await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: bp.x + 40, y: bp.y), w)
            auxP?.orderOut(nil); auxP?.close()
            _ = await LaneSelfTest.regainFocus(w)
            check("interrupt.pendingMove\(label)NoLateRestart", pendingP && clearedP && noRestart && st() == preP && s.interruptCountForTest == nP,
                  "pending \(pendingP) cleared \(clearedP) noRestart \(noRestart) unchanged \(st() == preP) depth +\(s.history.undoDepth - preP.depth)\(viaApp ? " (synthetic notification)" : " (real in-app key change)")")
            if s.gestureBase != nil { s.cancelGesture() }
            if s.history.undoDepth > preP.depth { s.undo() }
        }

        // 5b. 앱 비활성: 알림을 직접 보낸다(실제 비활성 전환은 검사하지 않음 — 결과에 표시)
        let (_, pre6) = await startTrim()
        let active6 = s.gestureBase != nil
        let n6 = s.interruptCountForTest
        // 실제 앱 비활성(NSApp.deactivate)은 이 환경에서 2 s 안에 일어나지 않았고 뒤의 마우스 처리를 흐트러뜨려, 알림을 직접 보낸다(직접 처리기 검사).
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        await LaneSelfTest.settle()
        check("interrupt.appDeactivationCancels", active6 && s.gestureBase == nil && st() == pre6 && tv.dragNameForTest == "none" && s.interruptCountForTest == n6 + 1,
              "synthetic notification (actual app deactivation not exercised) restored \(st() == pre6) count +\(s.interruptCountForTest - n6)")
        _ = await LaneSelfTest.regainFocus(w)

        // 5c. 같은 중단 알림이 여러 번 와도(직접 보낸 알림) 한 번만 취소
        let (_, pre7) = await startTrim()
        let active7 = s.gestureBase != nil
        let n7 = s.interruptCountForTest
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        await LaneSelfTest.settle()
        check("interrupt.duplicateNotificationsOnce", active7 && s.gestureBase == nil && st() == pre7 && s.interruptCountForTest == n7 + 1,
              "count +\(s.interruptCountForTest - n7) active \(active7) appActive \(NSApp.isActive) key \(NSApp.keyWindow === w) direct \(LaneSelfTest.direct) (synthetic notifications)")
        if NSApp.keyWindow !== w { _ = await LaneSelfTest.regainFocus(w) }
        await LaneSelfTest.mouse(.leftMouseUp, late, w)

        // 5d. 알림 없이 남은 끌기(놓기를 받지 못함) 위의 새 끌기: 남은 끌기는 취소되고 새 끌기만 한 단계로 확정
        s.select(v0); await LaneSelfTest.settle()
        let pre8 = st()
        guard let c8 = s.timeline.clip(v0) else { return finish(folder, checks) }
        s.beginGesture(select: v0); s.updateTrim(v0, edge: .end, delta: -5)
        let stale = s.gestureBase != nil && s.timeline.clip(v0)?.length == c8.length - 5
        let n8 = s.interruptCountForTest
        let b8 = pt(c8.start + 10)
        await LaneSelfTest.mouse(.leftMouseDown, b8, w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: b8.x + 8, y: b8.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: b8.x + CGFloat(20) * tv.pixelsPerFrame, y: b8.y), w)
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: b8.x + CGFloat(20) * tv.pixelsPerFrame, y: b8.y), w)
        let c8b = s.timeline.clip(v0)
        check("interrupt.staleNotCommittedWithNextDrag", stale && s.gestureBase == nil && s.history.undoDepth == pre8.depth + 1 && c8b?.length == c8.length
              && c8b?.start == c8.start + 20 && s.interruptCountForTest == n8 + 1,
              "stale \(stale) depth +\(s.history.undoDepth - pre8.depth) length \(c8b.map { "\($0.length)" } ?? "nil")/\(c8.length) start \(c8b.map { "\($0.start)" } ?? "nil")")
        await LaneSelfTest.key(6, "z", [.command], w)
        check("interrupt.undoRestoresBeforeStale", s.timeline == pre8.t, "")

        // 5e. 프리뷰 위치·크기 끌기 중 실제 키 창 바뀜(가운데 = 위치, 모서리 = 크기)
        _ = await LaneSelfTest.regainFocus(w)
        s.select(v0); s.seek(to: (s.timeline.clip(v0)?.start ?? 0) + 10)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        s.setTransform(v0, ClipTransform(scalePermille: 500, offsetX: 0, offsetY: 0))   // 모서리 손잡이가 화면 안에 오게
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        await LaneSelfTest.settle()
        if let ov = LaneSelfTest.find(PreviewOverlayView.self, w.contentView) {
            func opt(_ cx: CGFloat, _ cy: CGFloat) -> NSPoint {
                let b = ov.bounds, k = min(b.width / 1920, b.height / 1080)
                return ov.convert(NSPoint(x: (b.width - 1920 * k) / 2 + cx * k, y: (b.height - 1080 * k) / 2 + cy * k), to: nil)
            }
            for (name, corner) in [("Position", false), ("Resize", true)] {
                guard let r = ov.state.rect else { check("interrupt.keyLossCancelsPreview\(name)", false, "no overlay rect"); continue }
                let p0 = corner ? opt(r.maxX, r.maxY) : opt(r.midX, r.midY)
                let pre9 = st(), tr0 = s.timeline.clip(v0)?.transform
                await LaneSelfTest.mouse(.leftMouseDown, p0, w)
                await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p0.x + 40, y: p0.y - (corner ? 20 : 0)), w)
                _ = await LaneSelfTest.waitUntil(1) { s.liveTransform != nil }
                let live = s.liveTransform?.transform
                let active9 = s.gestureBase != nil && ov.isDraggingForTest && live != nil && (corner ? live?.scale != tr0?.scale : live?.x != tr0?.x)
                let aux9 = await auxKey()
                let ok9 = s.gestureBase == nil && !ov.isDraggingForTest && st() == pre9 && s.timeline.clip(v0)?.transform == tr0 && s.liveTransform == nil
                    && !s.previewHostShowingStillForTest
                aux9.orderOut(nil); aux9.close()
                _ = await LaneSelfTest.regainFocus(w)
                await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p0.x + 60, y: p0.y), w)
                await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: p0.x + 60, y: p0.y), w)
                check("interrupt.keyLossCancelsPreview\(name)", active9 && ok9 && st() == pre9,
                      "active \(active9) cancelled \(ok9) after late events \(st() == pre9) live \(live.map { "s\($0.scale) x\($0.x)" } ?? "nil")")
            }
        } else { check("interrupt.keyLossCancelsPreviewPosition", false, "no overlay") }
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: "마우스는 앱 이벤트 큐(postEvent), 문맥 메뉴는 실제 메뉴 추적 루프에서 읽고 닫음. 끝나지 않은 끌기는 저장소 끌기 시작으로 만든 상태(실제 창 초점 잃음 아님)")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("gestureguard-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
