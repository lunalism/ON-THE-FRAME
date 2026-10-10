#if DEBUG
import AppKit
import OnTheFrameEngine
import os

/// 닫기·종료 보호 자체 검사(Debug 전용, 일반 화면에 없음).
/// `open -n -W -a OnTheFrame.app <폴더> --args -OTFCloseTest window|quit-export`.
/// 실제 앱 경로(창 대리자 감싸기의 windowShouldClose, applicationShouldTerminate, 대기열 AppKit 알림)를 쓴다.
/// 결과는 <폴더>/close-result.json. 마지막 "버리기 확정"은 앱을 끝내므로, 그 직전에 결과를 쓰고 끝난 뒤 상태(앱 종료,
/// 대상 파일 없음, 임시 디렉터리 정리)는 scripts/close-test.sh가 확인한다.
@MainActor
enum CloseSelfTest {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }
    struct Result: Codable { var checks: [Check]; var pendingDiscard: String?; var exportDestination: String?; var exportTempDir: String? }

    static func run(folder: URL, mode: String) async {
        let s = ProjectStore.shared
        var r = Result(checks: [], pendingDiscard: nil, exportDestination: nil, exportTempDir: nil)
        let log = Logger(subsystem: "dev.ontheframe.app", category: "closetest")
        func save() {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { try enc.encode(r).write(to: folder.appendingPathComponent("close-result.json")) }
            catch { log.error("save failed \(error.localizedDescription, privacy: .public)") }
        }
        func check(_ n: String, _ p: Bool, _ d: String = "") {
            r.checks.append(Check(name: n, pass: p, detail: d)); save()
            log.notice("\(p ? "PASS" : "FAIL", privacy: .public) \(n, privacy: .public) \(d, privacy: .public)")
        }
        NSApp.activate()
        _ = await waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { check("setup.window", false); save(); return quit() }
        // 폴더를 열며 시작하면 편집기 창이 아직 화면에 없을 수 있다(그 상태도 아래 숨김 시나리오로 따로 본다)
        w.makeKeyAndOrderFront(nil)
        _ = await waitUntil(5) { w.isVisible }
        let src = folder.appendingPathComponent("sources"), out = folder.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // 빈 프로젝트는 확인 없이 닫을 수 있다
        check("empty.noPrompt", !s.hasUnsavedWork && s.canCloseWithoutPrompt)
        check("guard.installed", s.closeGuardInstalled)
        s.importFiles([src.appendingPathComponent("otf-A.mp4"), src.appendingPathComponent("otf-B.mp4")])
        _ = await waitUntil(30) { s.assets.count == 2 && s.importing == 0 }
        guard s.assets.count == 2 else { check("setup.import", false); save(); return quit() }
        let reps = mode == "quit-export" ? 3 : 1
        for _ in 0..<reps { s.addToTimeline(s.assets[0].id); s.addToTimeline(s.assets[1].id) }
        _ = await waitUntil(10) { s.canPlay }
        let tl = s.timeline
        check("work.present", s.hasUnsavedWork && !s.canCloseWithoutPrompt)

        /// 확인 알림이 하나 떠 있는지(제목·단추) 확인
        func promptShown(_ titlePart: String) async -> (ok: Bool, detail: String) {
            let shown = await waitUntil(5) { s.alerts.isShowing && (s.alert?.title.contains(titlePart) ?? false) }
            let b = s.alerts.currentButtons
            let keys = b.map { $0.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) }.joined() }
            let detail = "title \(s.alert?.title ?? "nil") buttons \(b.map(\.title)) keys \(keys) destructive \(b.count > 1 && b[1].hasDestructiveAction) queued \(s.alerts.queuedCount)"
            let ok = shown && b.map(\.title).first == "취소" && b.first?.keyEquivalent == "\r" && b.count == 2 && b[1].hasDestructiveAction && s.alerts.queuedCount == 0
            return (ok, detail)
        }
        func dismissed() async -> Bool { await waitUntil(5) { !s.alerts.isShowing } }

        if mode == "window" {
            // 닫기 단추 → 확인 → 취소
            w.standardWindowButton(.closeButton)?.performClick(nil)
            let p1 = await promptShown("창을 닫을까요")
            s.alerts.pressButton(0)
            let c1 = await dismissed()
            check("closeButton.promptAndCancel", p1.ok && c1 && w.isVisible && s.timeline == tl, p1.detail)
            // ⌘W(파일 > 닫기의 performClose:) → 확인 → Return(기본 = 취소)
            w.performClose(nil)
            let p2 = await promptShown("창을 닫을까요")
            if let k = NSApp.keyWindow { await key(36, "\r", k) }
            let c2 = await dismissed()
            check("cmdW.returnIsCancel", p2.ok && c2 && w.isVisible && s.timeline == tl, p2.detail)
            // 모두 닫기(closeAll:) → 확인 → Esc 동작 기록 → 취소
            NSApp.sendAction(Selector(("closeAll:")), to: nil, from: nil)
            let p3 = await promptShown("창을 닫을까요")
            if let k = NSApp.keyWindow { await key(53, "\u{1b}", k) }
            let escClosed = await waitUntil(1.5) { !s.alerts.isShowing }
            if !escClosed { s.alerts.pressButton(0) }
            let c3 = await dismissed()
            check("closeAll.prompt", p3.ok && c3 && w.isVisible && s.timeline == tl, p3.detail)
            check("esc.behavior", true, escClosed ? "Esc가 취소로 닫음" : "Esc로는 닫히지 않음(취소 단추·Return으로 닫음)")
            // 겹친 요청: 확인은 하나만
            w.performClose(nil); w.performClose(nil)
            let p4 = await promptShown("창을 닫을까요")
            s.alerts.pressButton(0)
            let c4 = await dismissed()
            check("duplicate.singlePrompt", p4.ok && c4 && w.isVisible, p4.detail)
            // 내보내기는 프로젝트 저장이 아니다: 내보내기 완료 뒤에도 확인
            let dest = out.appendingPathComponent("done.mp4")
            s.startExport(.fromSavePanel(dest))
            _ = await waitUntil(120) { s.exportPhase == .idle }
            let exported = FileManager.default.fileExists(atPath: dest.path) && s.alert?.title == "내보내기 완료"
            if s.alerts.isShowing { s.alerts.pressButton(1) }
            _ = await dismissed()
            w.performClose(nil)
            let p5 = await promptShown("창을 닫을까요")
            s.alerts.pressButton(0)
            _ = await dismissed()
            check("afterExport.stillPrompts", exported && p5.ok && w.isVisible, p5.detail)
            // 마지막: 버리고 닫기 → 창이 닫히고(마지막 창) 앱이 두 번째 확인 없이 끝나야 한다(스크립트가 확인)
            r.pendingDiscard = "window"
            save()
            w.performClose(nil)
            _ = await promptShown("창을 닫을까요")
            s.alerts.pressButton(1)
            return
        }

        // quit-export
        // 종료 → 확인 → 겹친 종료 요청은 두 번째 확인을 만들지 않음 → 취소
        requestQuit()
        let q1 = await promptShown("종료할까요")
        requestQuit()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let single = s.alerts.queuedCount == 0
        s.alerts.pressButton(0)
        let qc = await dismissed()
        check("quit.promptCancelSingle", q1.ok && single && qc && w.isVisible && s.timeline == tl, q1.detail)
        // 앱을 숨긴 채 종료 요청: 확인이 보이도록 앱·창이 다시 나타나야 한다(숨긴 채 영원히 기다리지 않음)
        NSApp.hide(nil)
        _ = await waitUntil(3) { NSApp.isHidden }
        requestQuit()
        let h1 = await promptShown("종료할까요")
        let visibleAgain = !NSApp.isHidden && w.isVisible
        s.alerts.pressButton(0)
        _ = await dismissed()
        check("hidden.quitPromptVisible", h1.ok && visibleAgain, h1.detail)
        // 창을 최소화한 채 종료 요청
        w.miniaturize(nil)
        _ = await waitUntil(3) { w.isMiniaturized }
        requestQuit()
        let m1 = await promptShown("종료할까요")
        let restored = !w.isMiniaturized && w.isVisible
        s.alerts.pressButton(0)
        _ = await dismissed()
        check("minimized.quitPromptVisible", m1.ok && restored, m1.detail)
        // 내보내기 중 창 닫기 → 확인(내보내기 취소 안내) → 취소하면 내보내기는 계속
        let temps = TempBox()
        s.exportOptions = ExportService.Options(onTempDirectory: { u in temps.set(u) })
        let dest = out.appendingPathComponent("running.mp4")
        s.startExport(.fromSavePanel(dest))
        _ = await waitUntil(20) { if case .running(let p) = s.exportPhase { return p > 0.02 } else { return false } }
        w.performClose(nil)
        let e1 = await promptShown("창을 닫을까요")
        let mentionsExport = s.alert?.message.contains("진행 중인 내보내기는 취소") ?? false
        s.alerts.pressButton(0)
        _ = await dismissed()
        let stillRunning: Bool = { if case .running = s.exportPhase { return true } else { return false } }()
        check("exporting.closePromptCancelKeepsExport", e1.ok && mentionsExport && stillRunning, e1.detail)
        // 마지막: 내보내는 중 종료 → 버리고 종료 → 내보내기 취소·정리 뒤 종료(스크립트가 앱 종료·대상 없음·임시 정리 확인)
        guard stillRunning else { save(); return quit() }
        r.exportDestination = dest.path
        r.exportTempDir = temps.get()?.path
        r.pendingDiscard = "quit-export"
        save()
        requestQuit()
        _ = await promptShown("종료할까요")
        s.alerts.pressButton(1)
    }

    final class TempBox: @unchecked Sendable {   // 안전성: 잠금으로만 접근
        private let lock = NSLock(); private var u: URL?
        func set(_ x: URL) { lock.lock(); u = x; lock.unlock() }
        func get() -> URL? { lock.lock(); defer { lock.unlock() }; return u }
    }

    /// 종료 요청(⌘Q와 같은 경로). applicationShouldTerminate가 나중에 답하는 동안 terminate:가 돌아오지 않을 수 있어 다음 차례에 보낸다.
    private static func requestQuit() { DispatchQueue.main.async { NSApp.terminate(nil) } }

    private static func key(_ code: UInt16, _ chars: String, _ w: NSWindow) async {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { NSApp.postEvent(e, atStart: false) }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    private static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    private static func quit() {
        ProjectStore.shared.discardConfirmedForTest()
        requestQuit()
    }
}
#endif
