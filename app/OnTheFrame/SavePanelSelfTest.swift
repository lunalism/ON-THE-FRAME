#if DEBUG
import AppKit
import OnTheFrameEngine

/// 실제 저장 패널로 프로젝트 저장 재현(A-013 저장 실패 조사, Debug 전용). `open -n -a OnTheFrame.app <폴더> --args -OTFSavePanelTest`.
/// 일회용 생성 프로젝트를 만들고, 파일 메뉴 "프로젝트 저장"(소유자와 같은 경로)으로 실제 NSSavePanel을 띄운 뒤
/// 바탕화면과 새 고유 이름으로 확인 단추(ok:)를 누른다. 기존 파일을 덮어쓰지 않는다. 결과는 <폴더>/savepanel-result.json,
/// 단계 기록은 컨테이너의 Library/Logs/OnTheFrame-save.log. 만든 바탕화면 파일 이름은 결과에 남기고 스크립트가 지운다.
@MainActor
enum SavePanelSelfTest {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }
    struct Result: Codable { var checks: [Check]; var created: [String] }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var r = Result(checks: [], created: [])
        func check(_ n: String, _ p: Bool, _ d: String = "") { r.checks.append(Check(name: n, pass: p, detail: d)) }
        _ = await waitUntil(5) { s.editorWindow != nil }
        s.editorWindow?.makeKeyAndOrderFront(nil)
        s.importFiles([folder.appendingPathComponent("sources/otf-A.mp4")])
        _ = await waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        if let a = s.assets.first { s.addToTimeline(a.id) }
        // 기본은 검사 폴더(out). -OTFSavePanelDesktop이면 소유자 상황과 같은 바탕화면(새 고유 이름, 스크립트가 지움)
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        let desktop = ProcessInfo.processInfo.arguments.contains("-OTFSavePanelDesktop") ? home.appendingPathComponent("Desktop", isDirectory: true)
            : folder.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let tag = UUID().uuidString.prefix(8)
        let name1 = "otf-diag-\(tag).ontheframe", name2 = "otf-diag-\(tag)-as.ontheframe"
        let f1 = desktop.appendingPathComponent(name1), f2 = desktop.appendingPathComponent(name2)
        r.created = [f1.path, f2.path]
        save(folder, r)
        SaveTrace.note("=== savepanel test start \(tag)")

        // 1. 처음 저장: 파일 메뉴 "프로젝트 저장" → 실제 패널 → 바탕화면 + 새 이름 → 확인
        s.savePanelAutoConfirmForTest = (desktop, name1)
        let menuOK = menuItem("프로젝트 저장")
        _ = await waitUntil(15) { FileManager.default.fileExists(atPath: f1.path) || s.alerts.isShowing }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("firstSave", menuOK && FileManager.default.fileExists(atPath: f1.path) && !s.isDirty && s.projectURL?.path == f1.path && s.recentProjects.first?.path == f1.path,
              "menu \(menuOK) exists \(FileManager.default.fileExists(atPath: f1.path)) dirty \(s.isDirty) url \(s.projectURL?.path ?? "nil") alert \(s.alert?.title ?? "none"): \(s.alert?.message ?? "") status \(s.statusMessage ?? "")")
        save(folder, r)
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await waitUntil(3) { !s.alerts.isShowing } }
        // 2. 이후 저장: 패널 없이 현재 위치
        s.renameLane(Lane.videoID, to: "다시 저장")
        let dirty2 = s.isDirty
        _ = menuItem("프로젝트 저장")
        _ = await waitUntil(5) { !s.isDirty || s.alerts.isShowing }
        let back = (try? Data(contentsOf: f1)).flatMap { try? ProjectFile.decode($0).timeline }
        check("subsequentSave", dirty2 && !s.isDirty && back?.lanes.first?.name == "다시 저장", "alert \(s.alert?.title ?? "none")")
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await waitUntil(3) { !s.alerts.isShowing } }
        // 3. 다른 이름으로 저장: 새 위치가 현재 프로젝트
        s.savePanelAutoConfirmForTest = (desktop, name2)
        _ = menuItem("다른 이름으로 저장…")
        _ = await waitUntil(15) { FileManager.default.fileExists(atPath: f2.path) || s.alerts.isShowing }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("saveAs", FileManager.default.fileExists(atPath: f2.path) && s.projectURL?.path == f2.path && !s.isDirty, "alert \(s.alert?.title ?? "none"): \(s.alert?.message ?? "")")
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await waitUntil(3) { !s.alerts.isShowing } }
        // 4. 실제 파일 다시 열기
        let before = s.timeline
        s.resetProject()
        let opened = await s.openProject(at: f1)
        check("reopen", opened && s.timeline.clips == before.clips && s.timeline.lanes.first?.name == "다시 저장" && s.missingMedia.isEmpty && !s.isDirty,
              "missing \(s.missingMedia.count)")
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await waitUntil(3) { !s.alerts.isShowing } }
        SaveTrace.note("=== savepanel test end \(tag)")
        s.savePanelAutoConfirmForTest = nil
        save(folder, r)
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }

    static func menuItem(_ title: String) -> Bool {
        func all(_ m: NSMenu?) -> [NSMenuItem] { guard let m else { return [] }; return m.items.flatMap { [$0] + all($0.submenu) } }
        for m in Set(all(NSApp.mainMenu).compactMap(\.submenu)) { m.delegate?.menuNeedsUpdate?(m) }
        guard let it = all(NSApp.mainMenu).first(where: { $0.title == title }), let m = it.menu, let i = m.items.firstIndex(of: it), it.isEnabled else { return false }
        m.performActionForItem(at: i)
        return true
    }
    static func save(_ folder: URL, _ r: Result) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(r) { try? d.write(to: folder.appendingPathComponent("savepanel-result.json")) }
    }
    static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
}
#endif
