#if DEBUG
import AppKit
import OnTheFrameEngine

/// 프로젝트 열기 ↔ 저장하지 않은 변경 확인 ↔ 저장 흐름 자체 검사(2026-10-11 소유자 보고, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFOpenFlowTest`.
/// 실제 메뉴 "프로젝트 열기…"·"새 프로젝트", 실제 확인 시트, 실제 열기 패널·저장 패널을 쓴다. 실제 패널은 보였는지 기록한 뒤 **취소만** 한다
/// (실제 저장 패널을 확인하지 않는다: 2026-10-11 위치 지정이 무시되어 검사 프로젝트가 사용자 폴더에 저장된 일이 있었다).
/// 제목 없는 프로젝트의 저장 성공·실패는 기존 주입 경로(savePanelResultForTest: 패널이 "확인 + 이 위치"를 돌려준 것과 같음)로 본다 — 모의 저장 결과다.
/// 저장된 프로젝트 고정물은 <폴더>/out에 저장 함수로 직접 쓴다(저장 패널 검사와 무관). 결과는 <폴더>/openflow-result.json.
@MainActor
enum OpenFlowSelfTest {
    typealias Check = LaneSelfTest.Check

    /// 실제 모달 패널 관찰. runModal 직전 훅으로 받은 패널이 보이면 기록하고 0.6 s 뒤 취소한다.
    @MainActor final class PanelWatcher {
        var events: [String] = []
        var requested: [String] = []
        var log: [String] = []
        private var current: NSSavePanel?
        private var shownAt: Date?
        private var cancelled = false
        private var timer: Timer?
        private let t0 = Date()
        func note(_ m: String) { log.append(String(format: "%7.2f ", Date().timeIntervalSince(t0)) + m) }
        func reset() { events = []; requested = [] }
        func willRun(_ p: NSSavePanel) {
            current = p; shownAt = nil; cancelled = false
            let kind = p is NSOpenPanel ? "open" : "save"
            requested.append(kind); note("panel run \(kind) active \(NSApp.isActive)")
        }
        func start() {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(t, forMode: .common); RunLoop.main.add(t, forMode: .modalPanel)
            timer = t
        }
        func stop() { timer?.invalidate(); timer = nil }
        private func tick() {
            guard let p = current, p.isVisible, !cancelled else { return }
            let kind = p is NSOpenPanel ? "open" : "save"
            guard let s0 = shownAt else { shownAt = Date(); events.append("\(kind) shown"); note("\(kind) shown"); return }
            if Date().timeIntervalSince(s0) > 0.6 { cancelled = true; events.append("\(kind) cancelled"); note("\(kind) cancelled"); p.cancel(nil) }
        }
    }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        s.editorWindow?.makeKeyAndOrderFront(nil)
        let fm = FileManager.default
        let out = folder.appendingPathComponent("out", isDirectory: true), locked = folder.appendingPathComponent("locked", isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)   // 쓰기 금지(저장 실패용)
        let source = folder.appendingPathComponent("sources/otf-A.mp4")
        let w = PanelWatcher(); w.start()
        s.panelWillRunForTest = { [weak w] p in w?.willRun(p) }
        let prompt = "변경 사항을 저장할까요?"

        func idle() async { _ = await LaneSelfTest.waitUntil(30) { !s.openRequested && !s.alerts.isShowing && NSApp.modalWindow == nil && s.importing == 0 } }
        /// 메뉴 항목 → (확인 시트가 뜨면) 단추 → 흐름 끝. 반환: 메뉴 동작 여부, 확인 시트 제목(없으면 nil), 실제 패널 기록.
        func viaMenu(_ title: String, prompt button: Int?) async -> (menu: Bool, prompt: String?, events: [String], requested: [String]) {
            await idle()
            w.reset(); w.note("menu \(title) dirty \(s.isDirty) url \(s.projectURL?.lastPathComponent ?? "nil")")
            let ok = LaneSelfTest.menuItem(title)
            var shown: String?
            if let button, await LaneSelfTest.waitUntil(5, { s.alerts.isShowing }) {
                shown = s.alert?.title
                try? await Task.sleep(nanoseconds: 400_000_000); w.note("press \(button)"); s.alerts.pressButton(button)
            }
            _ = await LaneSelfTest.waitUntil(30) { !s.openRequested && s.openProgress == nil && NSApp.modalWindow == nil && s.alert?.title != prompt }
            try? await Task.sleep(nanoseconds: 600_000_000)
            w.note("flow done openRequested \(s.openRequested)")
            return (ok, shown, w.events, w.requested)
        }
        /// 실패 알림이 뜨면 제목을 기록하고 닫는다
        func takeFailureAlert() async -> String? {
            guard await LaneSelfTest.waitUntil(5, { s.alerts.isShowing && s.alert?.title != prompt }) else { return nil }
            let t = s.alert?.title
            try? await Task.sleep(nanoseconds: 300_000_000); s.alerts.pressButton(0)
            _ = await LaneSelfTest.waitUntil(5) { !s.alerts.isShowing }
            return t
        }
        /// 새 제목 없는 프로젝트(변경 있음): 새 프로젝트(확인이 뜨면 저장 안 함) → 미디어 가져오기 → 타임라인에 하나
        func freshDirtyUntitled() async -> MediaAsset? {
            _ = await viaMenu("새 프로젝트", prompt: s.isDirty ? 2 : nil)
            _ = await LaneSelfTest.waitUntil(5) { s.projectURL == nil && s.timeline.isEmpty }
            s.importFiles([source])
            _ = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
            _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
            guard let a = s.assets.first else { return nil }
            s.addToTimeline(a.id)
            return a
        }

        // 1. 변경 없음(빈 새 프로젝트) → 열기 패널 바로 → 취소: 프로젝트 그대로, 뒤이은 새 프로젝트·가져오기·내보내기 가능
        let a = await viaMenu("프로젝트 열기…", prompt: nil)
        check("clean.openPanelShown", a.menu && a.events == ["open shown", "open cancelled"] && !s.alerts.isShowing && s.projectURL == nil && s.timeline.isEmpty && !s.openRequested,
              "requested \(a.requested) events \(a.events)")
        let n1 = await viaMenu("새 프로젝트", prompt: nil)
        let newOK = n1.menu && n1.prompt == nil && !s.alerts.isShowing
        s.importFiles([source])
        let importOK = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        if let x = s.assets.first { s.addToTimeline(x.id) }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        check("afterOpenCancel.newImportExportAvailable", newOK && importOK && s.canExport && !s.openRequested && s.pendingOps.isEmpty,
              "new \(newOK) import \(importOK) canExport \(s.canExport) alert \(s.alert?.title ?? "-")")

        // 2. 제목 없음 + 변경 + 취소 → 패널 없음, 그대로
        guard await freshDirtyUntitled() != nil else { return finish(folder, checks + [Check(name: "setup.untitled", pass: false, detail: "")], w) }
        let tU = s.timeline
        let c = await viaMenu("프로젝트 열기…", prompt: 1)
        check("untitled.cancelAtPromptStops", c.prompt == prompt && c.requested.isEmpty && s.isDirty && s.timeline == tU && s.projectURL == nil, "\(c.prompt ?? "no prompt") \(c.requested)")

        // 3. 제목 없음 + 저장 안 함 → 실제 열기 패널 → 취소: 현재 프로젝트(변경 포함) 그대로
        let d = await viaMenu("프로젝트 열기…", prompt: 2)
        check("untitled.dontSaveShowsOpenPanel", d.prompt == prompt && d.events == ["open shown", "open cancelled"] && s.isDirty && s.timeline == tU && s.projectURL == nil,
              "\(d.prompt ?? "no prompt") requested \(d.requested) events \(d.events)")

        // 4. 제목 없음 + 저장 → 실제 저장 패널 → 취소: 열기 없음, 그대로
        let e = await viaMenu("프로젝트 열기…", prompt: 0)
        check("untitled.savePanelCancelStops", e.prompt == prompt && e.events == ["save shown", "save cancelled"] && e.requested == ["save"] && s.isDirty && s.timeline == tU && s.projectURL == nil,
              "\(e.prompt ?? "no prompt") requested \(e.requested) events \(e.events)")

        // 5. 제목 없음 + 저장 → (모의) 저장 결과 = 쓰기 금지 폴더 → 실패 알림, 열기 없음, 그대로
        s.savePanelResultForTest = locked.appendingPathComponent("u-fail.ontheframe")
        let f = await viaMenu("프로젝트 열기…", prompt: 0)
        let fAlert = await takeFailureAlert()
        await idle()
        check("untitled.simulatedSaveFailureStops", f.prompt == prompt && fAlert == "프로젝트를 저장하지 못했습니다" && f.requested.isEmpty && s.isDirty && s.timeline == tU && s.projectURL == nil
              && s.savePanelResultForTest == nil, "\(f.prompt ?? "no prompt") failure \(fAlert ?? "none") requested \(f.requested)")

        // 6. 제목 없음 + 저장 → (모의) 저장 결과 = 일회용 폴더의 새 이름 → 저장 성공 → 실제 열기 패널 → 취소
        let uFile = out.appendingPathComponent("u-\(UUID().uuidString.prefix(8)).ontheframe")
        s.savePanelResultForTest = uFile
        let g = await viaMenu("프로젝트 열기…", prompt: 0)
        check("untitled.simulatedSaveThenOpenPanel", g.prompt == prompt && g.events == ["open shown", "open cancelled"] && g.requested == ["open"]
              && fm.fileExists(atPath: uFile.path) && s.projectURL?.standardizedFileURL == uFile.standardizedFileURL && !s.isDirty && s.timeline == tU,
              "\(g.prompt ?? "no prompt") requested \(g.requested) events \(g.events) url \(s.projectURL?.lastPathComponent ?? "nil") dirty \(s.isDirty)")

        // 저장된 프로젝트 고정물(위 검사와 무관): 새 제목 없는 프로젝트를 저장 함수로 일회용 폴더에 직접 쓴다
        guard let asset2 = await freshDirtyUntitled() else { return finish(folder, checks + [Check(name: "setup.savedFixture", pass: false, detail: "import")], w) }
        let sFile = out.appendingPathComponent("s-\(UUID().uuidString.prefix(8)).ontheframe")
        let fixtureOK = s.writeProject(to: sFile) && s.projectURL?.standardizedFileURL == sFile.standardizedFileURL && !s.isDirty
        check("setup.savedFixture", fixtureOK, sFile.lastPathComponent)
        func clipsOnDisk(_ u: URL) -> Int? { (try? Data(contentsOf: u)).flatMap { try? ProjectFile.decode($0).timeline.clips.count } }

        // 7. 저장된 프로젝트 + 변경 + 저장 → 저장 패널 없이 같은 파일에 저장 → 실제 열기 패널 → 취소
        s.addToTimeline(asset2.id)
        let t7 = s.timeline
        let h = await viaMenu("프로젝트 열기…", prompt: 0)
        check("saved.saveToExistingThenOpenPanel", h.prompt == prompt && h.requested == ["open"] && h.events == ["open shown", "open cancelled"] && !s.isDirty && s.timeline == t7
              && clipsOnDisk(sFile) == t7.clips.count && s.projectURL?.standardizedFileURL == sFile.standardizedFileURL,
              "\(h.prompt ?? "no prompt") requested \(h.requested) events \(h.events) dirty \(s.isDirty) clips on disk \(String(describing: clipsOnDisk(sFile)))/\(t7.clips.count)")

        // 8. 저장된 프로젝트 + 변경 + 저장 안 함 → 실제 열기 패널 → 취소: 변경 그대로, 파일 그대로
        s.addToTimeline(asset2.id)
        let t8 = s.timeline
        let i = await viaMenu("프로젝트 열기…", prompt: 2)
        check("saved.dontSaveShowsOpenPanel", i.prompt == prompt && i.requested == ["open"] && i.events == ["open shown", "open cancelled"] && s.isDirty && s.timeline == t8
              && clipsOnDisk(sFile) == t7.clips.count, "\(i.prompt ?? "no prompt") requested \(i.requested) events \(i.events)")

        // 9. 저장된 프로젝트 + 변경 + 저장 실패(고정물 폴더 쓰기 금지) → 실패 알림, 열기 없음, 변경·파일 그대로
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
        let j = await viaMenu("프로젝트 열기…", prompt: 0)
        let jAlert = await takeFailureAlert()
        await idle()
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path)
        check("saved.saveFailureStops", j.prompt == prompt && jAlert == "프로젝트를 저장하지 못했습니다" && j.requested.isEmpty && s.isDirty && s.timeline == t8
              && clipsOnDisk(sFile) == t7.clips.count && s.projectURL?.standardizedFileURL == sFile.standardizedFileURL,
              "\(j.prompt ?? "no prompt") failure \(jAlert ?? "none") requested \(j.requested)")

        // 10. 여러 번 취소한 뒤에도 열기·새 프로젝트·가져오기·내보내기가 막히지 않는다
        let k = await viaMenu("프로젝트 열기…", prompt: 2)
        let k2 = await viaMenu("새 프로젝트", prompt: 2)
        s.importFiles([source])
        let importOK2 = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        if let x = s.assets.first { s.addToTimeline(x.id) }
        check("repeat.requestsStillWork", k.events == ["open shown", "open cancelled"] && k2.prompt == prompt && s.projectURL == nil && importOK2 && s.canExport && !s.openRequested,
              "open \(k.events) new prompt \(k2.prompt ?? "none") import \(importOK2) canExport \(s.canExport)")

        // 11. 앞의 시트·패널이 사라지지 않는 상황(흉내): 시간 초과 → 고른 동작을 하지 않고 중단. 패널 없음, 프로젝트·변경 그대로, 요청 상태 풀림,
        //     늦은 이어짐 없음. 그 뒤 같은 흐름이 정상으로 된다.
        let tB = s.timeline
        ProjectStore.promptSettleTimeout = 0.5
        var blocked: [(String, Bool, String)] = []
        for (title, button) in [("프로젝트 열기…", 0), ("프로젝트 열기…", 2), ("새 프로젝트", 2)] {
            s.promptSettleBlockedForTest = true
            let r = await viaMenu(title, prompt: button)
            let notice = await takeFailureAlert()
            s.promptSettleBlockedForTest = false
            try? await Task.sleep(nanoseconds: 1_000_000_000)   // 늦게 이어지는 것이 없는지
            let ok = r.prompt == prompt && notice == "작업을 계속할 수 없습니다" && w.requested.isEmpty && s.isDirty && s.timeline == tB && s.projectURL == nil
                && !s.openRequested && !s.alerts.isShowing
            blocked.append(("\(title)/\(button)", ok, "notice \(notice ?? "none") requested \(w.requested) dirty \(s.isDirty)"))
        }
        ProjectStore.promptSettleTimeout = 2
        check("blocked.timeoutAbortsWithoutContinuing", blocked.allSatisfy(\.1), blocked.map { "\($0.0): \($0.2)" }.joined(separator: "; "))
        let after = await viaMenu("프로젝트 열기…", prompt: 2)
        check("blocked.nextOperationWorks", after.prompt == prompt && after.events == ["open shown", "open cancelled"] && !s.openRequested && s.timeline == tB,
              "\(after.prompt ?? "no prompt") \(after.events)")

        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        finish(folder, checks, w)
    }

    static func finish(_ folder: URL, _ checks: [Check], _ w: PanelWatcher) {
        w.stop(); ProjectStore.shared.panelWillRunForTest = nil
        let all = checks + [Check(name: "log", pass: true, detail: w.log.joined(separator: " | "))]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(all) { try? d.write(to: folder.appendingPathComponent("openflow-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
