#if DEBUG
import AppKit
import OnTheFrameEngine

/// 끌기 중 실제 앱 전환 실험(CP-01 소유자 ⌘Tab 확인 실패 조사, 2026-10-11, Debug 전용).
/// `open -n -W -a OnTheFrame.app <폴더> --args -OTFGestureSwitchExperiment`.
/// 트림·옮기기·프리뷰 위치·프리뷰 크기 끌기를 합성 마우스 이벤트로 시작한 뒤, 활성화를 Finder에 넘기고(실제 앱 비활성) 무슨 일이 일어나는지 기록한다:
/// 받은 알림(편집기 창 키 상태 잃음·앱 비활성)의 순서, 끌기 취소 여부, 저장소·보기의 끌기 상태, 데이터(타임라인·기록·변형), 늦은 끌기·놓기 이벤트 뒤의 상태.
/// 다시 이 앱을 활성화한다(되지 않으면 기록). 결과는 <폴더>/switch-result.json(검사가 아니라 관찰 기록).
@MainActor
enum GestureSwitchExperiment {
    struct Row: Codable { let kind: String; let notes: [String]; var pass: Bool = true }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var rows: [Row] = []
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { return finish(folder, [Row(kind: "setup", notes: ["no window"])]) }
        _ = await LaneSelfTest.regainFocus(w)
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        guard let asset = s.assets.first else { return finish(folder, [Row(kind: "setup", notes: ["no import"])]) }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        s.addToTimeline(asset.id)
        await LaneSelfTest.settle()
        guard let v0 = s.timeline.clips.first?.id, let tv = LaneSelfTest.find(TimelineNSView.self, w.contentView),
              let ov = LaneSelfTest.find(PreviewOverlayView.self, w.contentView) else { return finish(folder, [Row(kind: "setup", notes: ["no clip/views"])]) }
        tv.enclosingScrollView?.contentView.scroll(to: .zero)
        if let sv = tv.enclosingScrollView { sv.reflectScrolledClipView(sv.contentView) }
        let v1 = Lane.videoID
        func pt(_ frame: Int, dx: CGFloat = 0.3) -> NSPoint {
            guard let r = tv.laneRect(v1) else { return .zero }
            return tv.convert(NSPoint(x: tv.x(frame) + dx, y: r.midY), to: nil)
        }
        func overlayPoint(_ cx: CGFloat, _ cy: CGFloat) -> NSPoint {
            let b = ov.bounds, k = min(b.width / 1920, b.height / 1080)
            return ov.convert(NSPoint(x: (b.width - 1920 * k) / 2 + cx * k, y: (b.height - 1080 * k) / 2 + cy * k), to: nil)
        }
        let names: [(Notification.Name, AnyObject?)] = [(NSWindow.didResignKeyNotification, w), (NSApplication.didResignActiveNotification, nil),
                                                        (NSWindow.didBecomeKeyNotification, w), (NSApplication.didBecomeActiveNotification, nil)]
        let box = LogBox()
        let tokens = names.map { (n, o) in
            NotificationCenter.default.addObserver(forName: n, object: o, queue: nil) { [box] note in
                let name = note.name.rawValue
                MainActor.assumeIsolated { box.lines.append("\(name) gesture=\(ProjectStore.shared.gestureBase != nil)") }
            }
        }
        defer { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first

        func state() -> String {
            "active=\(NSApp.isActive) key=\(NSApp.keyWindow === w) gesture=\(s.gestureBase != nil) tlDrag=\(tv.dragNameForTest) pvDrag=\(ov.isDraggingForTest) depth=\(s.history.undoDepth) interrupts=\(s.interruptCountForTest)"
        }
        func trial(_ kind: String, start: () async -> NSPoint?, data: () -> String) async {
            _ = await LaneSelfTest.regainFocus(w)
            await LaneSelfTest.settle()
            box.lines = []
            var notes: [String] = []
            let before = data(), depth0 = s.history.undoDepth
            guard NSApp.isActive, NSApp.keyWindow === w else {
                rows.append(Row(kind: kind, notes: ["harness: app not active/key before the drag (\(state())) — trial not run"], pass: false)); return
            }
            guard let last = await start() else { rows.append(Row(kind: kind, notes: ["could not start"], pass: false)); return }
            notes.append("started: \(state()) data=\(data())")
            // 실제 앱 전환: 활성화를 Finder에 넘긴다
            if let f = finder { NSApp.yieldActivation(to: f); f.activate() }
            let left = await LaneSelfTest.waitUntil(3) { !NSApp.isActive }
            await LaneSelfTest.settle()
            notes.append("after switch (left=\(left)): \(state()) data=\(data()) restored=\(data() == before)")
            let cancelledOnSwitch = left && s.gestureBase == nil && data() == before
            notes.append("cancelledOnSwitch=\(cancelledOnSwitch)")
            notes.append("notifications: \(box.lines.joined(separator: " | "))")
            // 늦은 끌기·놓기(앱이 비활성일 때 보낸 이벤트)
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: last.x + 25, y: last.y), w)
            await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: last.x + 25, y: last.y), w)
            notes.append("after late drag+up: \(state()) data=\(data()) restored=\(data() == before) depthDelta=\(s.history.undoDepth - depth0)")
            NSApp.activate()
            let back = await LaneSelfTest.waitUntil(3) { NSApp.isActive }
            await LaneSelfTest.settle()
            notes.append("returned (\(back)): \(state()) data=\(data()) restored=\(data() == before)")
            let ok = left && data() == before && s.gestureBase == nil && tv.dragNameForTest == "none" && !ov.isDraggingForTest && s.history.undoDepth == depth0
            rows.append(Row(kind: kind, notes: notes, pass: ok))
            if s.gestureBase != nil { s.cancelGesture() }
            if s.history.undoDepth > depth0 { s.undo() }
        }

        let only = ProcessInfo.processInfo.arguments.firstIndex(of: "-OTFSwitchKind").flatMap { i in
            i + 1 < ProcessInfo.processInfo.arguments.count ? ProcessInfo.processInfo.arguments[i + 1] : nil }
        func want(_ k: String) -> Bool { only == nil || only == k }
        if want("timeline.trim") { await trial("timeline.trim", start: {
            s.select(v0); await LaneSelfTest.settle()
            guard let c = s.timeline.clip(v0) else { return nil }
            let e = pt(c.end, dx: -2), to = NSPoint(x: e.x - 30, y: e.y)
            await LaneSelfTest.mouse(.leftMouseDown, e, w); await LaneSelfTest.mouse(.leftMouseDragged, to, w)
            return to
        }, data: { s.timeline.clip(v0).map { "start \($0.start) len \($0.length)" } ?? "nil" }) }
        if want("timeline.move") { await trial("timeline.move", start: {
            s.select(v0); await LaneSelfTest.settle()
            let b = pt(20), to = NSPoint(x: b.x + 40, y: b.y)
            await LaneSelfTest.mouse(.leftMouseDown, b, w); await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: b.x + 8, y: b.y), w)
            await LaneSelfTest.mouse(.leftMouseDragged, to, w)
            return to
        }, data: { s.timeline.clip(v0).map { "start \($0.start) len \($0.length)" } ?? "nil" }) }
        // 옮기기 누름 대기(4 pt 전, 저장소 끌기 없음)에서 전환: 늦은 끌기(아래 trial이 40 pt 더 보냄)가 같은 누름으로 새 옮기기를 시작하면 안 된다(2026-10-12)
        if want("timeline.pendingMove") { await trial("timeline.pendingMove", start: {
            s.select(v0); await LaneSelfTest.settle()
            let b = pt(20), to = NSPoint(x: b.x + 2, y: b.y)
            await LaneSelfTest.mouse(.leftMouseDown, b, w); await LaneSelfTest.mouse(.leftMouseDragged, to, w)
            return NSPoint(x: b.x + 15, y: b.y)
        }, data: { s.timeline.clip(v0).map { "start \($0.start) len \($0.length)" } ?? "nil" }) }
        s.select(v0); s.seek(to: 30)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        s.setTransform(v0, ClipTransform(scalePermille: 500, offsetX: 0, offsetY: 0))
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        await LaneSelfTest.settle()
        func tdata() -> String { "\((s.timeline.clip(v0)?.effectiveTransform).map { "s\($0.scale) x\($0.x) y\($0.y)" } ?? "nil") live=\(s.liveTransform != nil) still=\(s.previewHostShowingStillForTest)" }
        if want("preview.position") { await trial("preview.position", start: {
            guard let r = ov.state.rect else { return nil }
            let p0 = overlayPoint(r.midX, r.midY), to = NSPoint(x: p0.x + 40, y: p0.y)
            await LaneSelfTest.mouse(.leftMouseDown, p0, w); await LaneSelfTest.mouse(.leftMouseDragged, to, w)
            _ = await LaneSelfTest.waitUntil(1) { s.liveTransform != nil }
            return to
        }, data: tdata) }
        if want("preview.resize") { await trial("preview.resize", start: {
            guard let r = ov.state.rect else { return nil }
            let p0 = overlayPoint(r.maxX, r.maxY), to = NSPoint(x: p0.x + 30, y: p0.y - 20)
            await LaneSelfTest.mouse(.leftMouseDown, p0, w); await LaneSelfTest.mouse(.leftMouseDragged, to, w)
            _ = await LaneSelfTest.waitUntil(1) { s.liveTransform != nil }
            return to
        }, data: tdata) }
        if finder == nil { rows.append(Row(kind: "finder", notes: ["Finder not running — no real switch"], pass: false)) }
        finish(folder, rows)
    }

    @MainActor final class LogBox { var lines: [String] = [] }

    static func finish(_ folder: URL, _ rows: [Row]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(rows) { try? d.write(to: folder.appendingPathComponent("switch-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
