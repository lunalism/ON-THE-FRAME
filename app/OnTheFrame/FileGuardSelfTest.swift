#if DEBUG
import AppKit
import OnTheFrameEngine

/// 시트·알림·패널 중 파일 명령(CP-03)과 레인 삭제 확인의 프로젝트 확인(CP-02) 자체 검사(Debug 전용, 2026-10-12).
/// `open -n -W -a OnTheFrame.app <폴더> --args -OTFFileGuardTest`. 결과는 <폴더>/fileguard-result.json, 진행은 fileguard-progress.txt.
/// - 실제 저장·열기·가져오기·내보내기 패널은 띄우지 않는다: 열기·가져오기·내보내기 패널은 검사 대체(패널을 띄우려 했는지만 기록),
///   저장은 위치가 있는 프로젝트(패널 없이 씀)와 주입한 "다른 이름으로 저장" 위치(검사 폴더 안)로 본다.
/// - 알림은 실제 AppKit 시트(NSAlert)다. 앱 모달은 검사용 창을 `NSApp.runModal(for:)`로 돌린 상태다(실제 저장·열기 패널 아님).
/// - 메뉴는 실제 주 메뉴 항목(사용 가능 상태를 읽고 켜져 있으면 실행), 키는 앱 이벤트 큐에 넣은 ⌘ 조합, 직접 호출은 저장소 함수다.
/// - CP-02는 파일 명령 보호와 따로 본다: 프로젝트 바꾸기는 저장소의 열기(`openProject(at:)`)·새 프로젝트(`resetProject`)를 직접 부른다.
/// 생성 fixture(otf-TA)만. 프로젝트 파일은 검사 폴더 안에만 쓴다.
@MainActor
enum FileGuardSelfTest {
    typealias Check = LaneSelfTest.Check
    @MainActor final class Hits { var list: [String] = [] }
    @MainActor final class ModalLog { var bad: [String] = []; var menuOn: [String] = []; var seen = false }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        let progress = folder.appendingPathComponent("fileguard-progress.txt")
        func step(_ m: String) { GestureGuardSelfTest.step(m, progress) }
        let out = folder.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let mainURL = out.appendingPathComponent("main.ontheframe").standardizedFileURL
        let otherURL = out.appendingPathComponent("other.ontheframe").standardizedFileURL
        let saveAsURL = out.appendingPathComponent("saveas.ontheframe").standardizedFileURL
        let chainURL = out.appendingPathComponent("chain.ontheframe").standardizedFileURL
        let hits = Hits()
        s.openPanelOverrideForTest = { hits.list.append("openPanel"); return nil }
        s.importPanelOverrideForTest = { hits.list.append("importPanel"); return nil }
        s.exportPanelOverrideForTest = { hits.list.append("exportPanel") }
        defer { s.openPanelOverrideForTest = nil; s.importPanelOverrideForTest = nil; s.exportPanelOverrideForTest = nil }

        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { return finish(folder, [Check(name: "setup.window", pass: false, detail: "")]) }
        _ = await LaneSelfTest.regainFocus(w)
        let src = folder.appendingPathComponent("sources/otf-TA.mp4")

        /// 클립 하나(V1·A1 연결) + 빈 영상 레인 하나를 만들고 위치에 저장(패널 없이 주입한 위치)
        func build(_ url: URL) async -> Bool {
            let n0 = s.assets.count
            s.importFiles([src])
            _ = await LaneSelfTest.waitUntil(30) { s.assets.count > n0 && s.importing == 0 }
            _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
            guard let a = s.assets.last else { return false }
            s.addToTimeline(a.id)
            s.addLane(.video)
            s.savePanelResultForTest = url
            s.saveProject()
            await LaneSelfTest.settle()
            return s.projectURL == url && !s.isDirty
        }
        step("setup other")
        let okOther = await build(otherURL)
        s.resetProject(); await LaneSelfTest.settle()
        step("setup main")
        let okMain = await build(mainURL)
        let mainID = s.projectID
        check("setup.projects", okOther && okMain && s.timeline.lanes(.video).count == 2 && !s.timeline.clips(inLane: Lane.videoID).isEmpty,
              "other \(okOther) main \(okMain) lanes \(s.timeline.lanes.count)")
        guard okOther, okMain else { return finish(folder, checks) }
        func openFile(_ u: URL) async -> Bool {
            _ = await s.openProject(at: u)
            await LaneSelfTest.settle()
            return s.projectURL == u
        }

        // MARK: CP-03 — 시트·알림·앱 모달 중 파일 명령

        struct World: Equatable { let url: URL?; let id: UUID; let t: Timeline; let depth: Int; let dirty: Bool; let mainMod: Date?; let saveAs: Bool; let hits: Int; let queued: Int }
        func mod(_ u: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        func world() -> World {
            World(url: s.projectURL, id: s.projectID, t: s.timeline, depth: s.history.undoDepth, dirty: s.isDirty, mainMod: mod(mainURL),
                  saveAs: FileManager.default.fileExists(atPath: saveAsURL.path), hits: hits.list.count, queued: s.alerts.queuedCount)
        }
        struct Cmd { let name: String; let menu: String; let key: (UInt16, String, NSEvent.ModifierFlags); let direct: () -> Void }
        let cmds: [Cmd] = [
            Cmd(name: "open", menu: "프로젝트 열기…", key: (31, "o", [.command]), direct: { s.requestOpenProject(nil) }),
            Cmd(name: "recent", menu: "other", key: (0, "", []), direct: { if let r = s.recentProjects.first(where: { $0.name == "other" }) { s.openRecent(r) } }),
            Cmd(name: "import", menu: "가져오기…", key: (34, "i", [.command]), direct: { s.presentImportPanel() }),
            Cmd(name: "export", menu: "내보내기…", key: (14, "e", [.command]), direct: { s.presentExportPanel() }),
            Cmd(name: "save", menu: "프로젝트 저장", key: (1, "s", [.command]), direct: { s.saveProject() }),
            Cmd(name: "saveAs", menu: "다른 이름으로 저장…", key: (1, "s", [.command, .shift]), direct: { s.saveProject(saveAs: true) }),
            Cmd(name: "new", menu: "새 프로젝트", key: (45, "n", [.command]), direct: { s.requestNewProject() }),
        ]
        /// 한 명령을 한 경로로 시도하고 무엇이 바뀌었는지 돌려준다(nil = 아무것도 바뀌지 않음). menuEnabled는 메뉴 경로에서 항목이 켜져 있었는가.
        func attempt(_ c: Cmd, via: String) async -> (changed: String?, menuEnabled: Bool?) {
            let w0 = world()
            var enabled: Bool?
            s.savePanelResultForTest = saveAsURL   // "다른 이름으로 저장"이 실행되면 검사 폴더 안에 쓴다(실제 패널 없음)
            step("attempt \(c.name) via \(via)")
            switch via {
            case "menu": enabled = LaneSelfTest.menuItem(c.menu)
            case "key": if c.key.1.isEmpty { return (nil, nil) }; await LaneSelfTest.key(c.key.0, c.key.1, c.key.2, w)
            default: c.direct()
            }
            _ = await LaneSelfTest.waitUntil(0.6) { world() != w0 }
            await LaneSelfTest.settle()
            s.savePanelResultForTest = nil
            let w1 = world()
            guard w1 != w0 else { return (nil, enabled) }
            var d: [String] = []
            if w1.url != w0.url { d.append("project \(w0.url?.lastPathComponent ?? "nil")→\(w1.url?.lastPathComponent ?? "nil")") }
            if w1.id != w0.id { d.append("projectID") }
            if w1.t != w0.t { d.append("timeline") }
            if w1.mainMod != w0.mainMod { d.append("main file written") }
            if w1.saveAs != w0.saveAs { d.append("saveAs file written") }
            if w1.hits != w0.hits { d.append("panel \(hits.list.suffix(w1.hits - w0.hits).joined(separator: ","))") }
            if w1.queued != w0.queued { d.append("alert queued +\(w1.queued - w0.queued)") }
            if w1.depth != w0.depth || w1.dirty != w0.dirty { d.append("history/dirty") }
            return (d.joined(separator: "; "), enabled)
        }
        /// 효과가 있었으면 기준 상태(main, 깨끗함)로 되돌린다(고치기 전 코드에서 다음 시도가 오염되지 않게)
        func restore() async {
            if FileManager.default.fileExists(atPath: saveAsURL.path) { try? FileManager.default.removeItem(at: saveAsURL) }
            if s.projectURL != mainURL || s.isDirty { _ = await openFile(mainURL) }
        }
        /// 모달 상태 하나에서 모든 명령·경로를 시도한다
        func sweep(_ label: String, paths: [String]) async -> (blocked: Bool, detail: String) {
            var bad: [String] = [], menuOn: [String] = []
            for c in cmds {
                for via in paths {
                    let r = await attempt(c, via: via)
                    if r.menuEnabled == true { menuOn.append(c.name) }
                    if let ch = r.changed { bad.append("\(c.name)/\(via): \(ch)"); }
                }
            }
            return (bad.isEmpty && menuOn.isEmpty, "changed [\(bad.joined(separator: " | "))] menuEnabled [\(menuOn.joined(separator: ","))]")
        }
        func showAlertAndWait(_ make: () -> Void) async -> Bool {
            make()
            return await LaneSelfTest.waitUntil(3) { s.alerts.isShowing && w.attachedSheet != nil }
        }
        func dismiss(_ i: Int) async {
            s.alerts.pressButton(i)
            _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing && w.attachedSheet == nil }
            await LaneSelfTest.settle()
        }

        // A. 일반 알림 시트
        _ = await LaneSelfTest.regainFocus(w)
        let shownA = await showAlertAndWait { s.presentAlert(ProjectStore.AlertInfo(title: "검사 알림", message: "파일 명령 보호 검사")) }
        let a = await sweep("alert", paths: ["menu", "key", "direct"])
        check("cp03.alertSheet.blocked", shownA && a.blocked, "shown \(shownA) \(a.detail)")
        await dismiss(0); await restore()
        // 닫은 뒤 다시 쓸 수 있다(메뉴 저장 → 실제로 씀, 메뉴 내보내기 → 패널을 띄우려 함)
        let m0 = mod(mainURL), h0 = hits.list.count
        try? await Task.sleep(nanoseconds: 20_000_000)
        let saveOn = LaneSelfTest.menuItem("프로젝트 저장"); await LaneSelfTest.settle()
        let exportOn = LaneSelfTest.menuItem("내보내기…"); await LaneSelfTest.settle()
        check("cp03.availableAfterDismiss", saveOn && exportOn && mod(mainURL) != m0 && hits.list.count == h0 + 1,
              "save menu \(saveOn) written \(mod(mainURL) != m0) export menu \(exportOn) panel \(hits.list.count - h0)")

        // B. 저장하지 않은 변경 확인(새 프로젝트 요청이 띄운 것)
        _ = await LaneSelfTest.regainFocus(w)
        _ = s.renameLane(Lane.audioID, to: "확인 중")
        let shownB = await showAlertAndWait { s.requestNewProject() }
        let b = await sweep("unsavedPrompt", paths: ["menu", "key", "direct"])
        check("cp03.unsavedPrompt.blocked", shownB && b.blocked, "shown \(shownB) \(b.detail)")
        await dismiss(1)   // 취소
        check("cp03.unsavedPrompt.cancelKeepsProject", s.projectURL == mainURL && s.isDirty && s.timeline.lanes.contains { $0.name == "확인 중" }, "")
        s.undo(); await restore()

        // C. 레인 삭제 확인(그 자체가 CP-02의 계기)
        _ = await LaneSelfTest.regainFocus(w)
        let shownC = await showAlertAndWait { s.requestRemoveLane(Lane.videoID) }
        let c = await sweep("laneConfirm", paths: ["menu", "key", "direct"])
        check("cp03.laneConfirm.blocked", shownC && c.blocked, "shown \(shownC) \(c.detail)")
        await dismiss(1); await restore()

        // D. 앱 모달(검사용 창을 실제 패널과 같은 방식으로 runModal: 패널 수를 올림). 모달 실행 루프 안에서 메뉴·직접 호출을 시도하고 끝낸다(키는 모달 창이 받으므로 보지 않음).
        _ = await LaneSelfTest.regainFocus(w)
        let modal = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 260, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        modal.title = "검사 모달"
        let ml = ModalLog()
        let mw0 = world()
        nonisolated(unsafe) let runInModal: () -> Void = {
            ml.seen = NSApp.modalWindow === modal
            for cmd in cmds {
                s.savePanelResultForTest = saveAsURL
                if LaneSelfTest.menuItem(cmd.menu) { ml.menuOn.append(cmd.name) }
                cmd.direct()
                s.savePanelResultForTest = nil
            }
            if world() != mw0 { ml.bad.append("world changed") }
            NSApp.stopModal()
        }
        let t = Timer(timeInterval: 0.3, repeats: false) { _ in MainActor.assumeIsolated { runInModal() } }
        RunLoop.main.add(t, forMode: .modalPanel)
        step("modal")
        s.runModalLikePanelForTest(modal)
        modal.orderOut(nil)
        await LaneSelfTest.settle()
        if world() != mw0 { ml.bad.append("world changed after") }
        check("cp03.appModal.actionsBlocked", ml.seen && ml.bad.isEmpty, "modal \(ml.seen) bad \(ml.bad) (메뉴 실행·직접 호출 모두 저장소 확인에서 막힘)")
        check("cp03.appModal.menuDisabled", ml.seen && ml.menuOn.isEmpty, "menuEnabled \(ml.menuOn) (모달 실행 루프 안에서 SwiftUI 메뉴 상태를 읽은 결과)")
        await restore()

        // E. 정당한 이어지는 흐름: 저장 → 새 프로젝트, 저장(처음, 주입 위치) → 열기, 저장 안 함 → 열기
        _ = await LaneSelfTest.regainFocus(w)
        _ = s.renameLane(Lane.audioID, to: "저장 뒤 새로")
        let shownE1 = await showAlertAndWait { s.requestNewProject() }
        await dismiss(0)   // 저장
        _ = await LaneSelfTest.waitUntil(5) { s.projectURL == nil }
        await LaneSelfTest.settle()
        let savedE1 = (try? Data(contentsOf: mainURL)).flatMap { try? ProjectFile.decode($0).timeline }?.lanes.contains { $0.name == "저장 뒤 새로" } == true
        check("chain.saveThenNew", shownE1 && savedE1 && s.projectURL == nil && s.timeline.clips.isEmpty && !s.isDirty, "shown \(shownE1) saved \(savedE1) url \(s.projectURL?.lastPathComponent ?? "nil")")
        s.addLane(.video)   // 새 프로젝트를 바꿔(위치 없음) 저장 패널이 필요한 저장 → 열기
        let open0 = hits.list.count
        s.openPanelOverrideForTest = { hits.list.append("openPanel"); return mainURL }
        let shownE2 = await showAlertAndWait { s.requestOpenProject(nil) }
        s.savePanelResultForTest = chainURL
        await dismiss(0)   // 저장(패널 결과 주입) → 열기 패널(대체) → main
        _ = await LaneSelfTest.waitUntil(5) { s.projectURL == mainURL }
        await LaneSelfTest.settle()
        s.savePanelResultForTest = nil
        check("chain.saveThenOpen", shownE2 && FileManager.default.fileExists(atPath: chainURL.path) && s.projectURL == mainURL && hits.list.count == open0 + 1,
              "shown \(shownE2) chain saved \(FileManager.default.fileExists(atPath: chainURL.path)) url \(s.projectURL?.lastPathComponent ?? "nil")")
        s.openPanelOverrideForTest = { hits.list.append("openPanel"); return otherURL }
        _ = s.renameLane(Lane.audioID, to: "버림")
        let mainBefore = try? Data(contentsOf: mainURL)
        let shownE3 = await showAlertAndWait { s.requestOpenProject(nil) }
        await dismiss(2)   // 저장 안 함
        _ = await LaneSelfTest.waitUntil(5) { s.projectURL == otherURL }
        await LaneSelfTest.settle()
        check("chain.discardThenOpen", shownE3 && s.projectURL == otherURL && (try? Data(contentsOf: mainURL)) == mainBefore && !s.isDirty, "url \(s.projectURL?.lastPathComponent ?? "nil")")
        s.openPanelOverrideForTest = { hits.list.append("openPanel"); return nil }
        _ = await openFile(mainURL)

        // MARK: CP-02 — 레인 삭제 확인은 띄운 프로젝트·레인에만

        struct Snap: Equatable { let url: URL?; let t: Timeline; let depth: Int; let dirty: Bool }
        func snap() -> Snap { Snap(url: s.projectURL, t: s.timeline, depth: s.history.undoDepth, dirty: s.isDirty) }
        let v1 = Lane.videoID
        /// V1 삭제 확인을 띄우고, between을 한 뒤 "레인 삭제"를 누른다. between 뒤 상태와 누른 뒤 상태를 돌려준다.
        func confirmDelete(_ label: String, between: () async -> Void) async -> (shown: Bool, mid: Snap, after: Snap) {
            _ = await LaneSelfTest.regainFocus(w)
            step("cp02 \(label)")
            let shown = await showAlertAndWait { s.requestRemoveLane(v1) }
            await between()
            await LaneSelfTest.settle()
            let mid = snap()
            await dismiss(0)
            _ = await LaneSelfTest.waitUntil(0.5) { snap() != mid }
            return (shown, mid, snap())
        }
        // 1. 보통 삭제: 한 단계, 기록 +1, 저장하지 않은 상태. 실행 취소로 되돌림
        let n0 = snap()
        let r1 = await confirmDelete("normal") {}
        check("cp02.normalDelete", r1.shown && r1.after.t.laneInfo(v1) == nil && r1.after.depth == n0.depth + 1 && r1.after.dirty, "depth +\(r1.after.depth - n0.depth)")
        s.undo(); await LaneSelfTest.settle()
        check("cp02.normalDeleteUndo", snap() == n0, "")
        // 2. 취소: 아무것도 바뀌지 않음
        _ = await showAlertAndWait { s.requestRemoveLane(v1) }
        await dismiss(1)
        check("cp02.cancel", snap() == n0, "")
        // 3. 확인이 떠 있는 동안 다른 프로젝트 열기(V1 같은 고정 ID, 클립 있음, 영상 레인 2개)
        let r3 = await confirmDelete("otherProject") { _ = await openFile(otherURL) }
        check("cp02.otherProjectNotDeleted", r3.shown && r3.mid.url == otherURL && r3.after == r3.mid && r3.after.t.laneInfo(v1) != nil,
              "opened \(r3.mid.url?.lastPathComponent ?? "nil") changed \(r3.after != r3.mid) depth \(r3.after.depth) dirty \(r3.after.dirty)")
        _ = await openFile(mainURL)
        // 4. 확인이 떠 있는 동안 새 프로젝트(빈 V1에 영상 레인 하나를 더해 지울 수 있는 상태로)
        let r4 = await confirmDelete("newProject") { s.resetProject(); s.addLane(.video) }
        check("cp02.newProjectNotDeleted", r4.shown && r4.mid.url == nil && r4.after == r4.mid && r4.after.t.laneInfo(v1) != nil,
              "changed \(r4.after != r4.mid)")
        _ = await openFile(mainURL)
        // 5. 같은 프로젝트를 다시 엶(같은 프로젝트 ID, 같은 내용): 이전 확인은 동작하지 않는다
        let r5 = await confirmDelete("reopenSame") { _ = await openFile(mainURL) }
        check("cp02.reopenSameNotDeleted", r5.shown && r5.mid.url == mainURL && s.projectID == mainID && r5.after == r5.mid && r5.after.t.laneInfo(v1) != nil,
              "same id \(s.projectID == mainID) same timeline \(r5.mid.t == n0.t) changed \(r5.after != r5.mid)")
        _ = await openFile(mainURL)
        // 6. 대상 레인이 없어짐
        let r6 = await confirmDelete("missingLane") { if let t = try? s.timeline.removingLane(v1) { s.loadTimelineForTest(t) } }
        check("cp02.missingLaneNoChange", r6.shown && r6.mid.t.laneInfo(v1) == nil && r6.after == r6.mid, "changed \(r6.after != r6.mid)")
        _ = await openFile(mainURL)
        // 7. 레인 안 클립이 바뀜(확인 문구의 클립과 다름)
        let r7 = await confirmDelete("clipsChanged") { if let a = s.assets.first { s.addToTimeline(a.id) } }
        let grew = r7.mid.t.clips(inLane: v1).count > n0.t.clips(inLane: v1).count
        check("cp02.clipsChangedNoDelete", r7.shown && grew && r7.after == r7.mid, "grew \(grew) changed \(r7.after != r7.mid)")
        _ = await openFile(mainURL)
        // 8. 그 종류의 마지막 레인이 됨
        let v2 = s.timeline.lanes(.video).first { $0.id != v1 }?.id
        let r8 = await confirmDelete("becameLast") { if let v2, let t = try? s.timeline.removingLane(v2) { s.loadTimelineForTest(t) } }
        check("cp02.lastLaneNoDelete", r8.shown && r8.mid.t.lanes(.video).count == 1 && r8.after == r8.mid, "changed \(r8.after != r8.mid)")
        _ = await openFile(mainURL)
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: "알림은 실제 NSAlert 시트, 앱 모달은 검사용 창 runModal(실제 저장·열기 패널 아님), 메뉴는 주 메뉴 항목 실행, 키는 앱 이벤트 큐의 ⌘ 조합"
                                        + (LaneSelfTest.direct ? " (직접 경로: 앱 활성화 실패, 키 경로는 같은 저장소 동작)" : ""))]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("fileguard-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
