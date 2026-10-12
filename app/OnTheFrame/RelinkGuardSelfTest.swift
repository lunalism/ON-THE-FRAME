#if DEBUG
import AppKit
import OnTheFrameEngine

/// 진행 중인 미디어 재연결 보호(CP-04, 2026-10-12) 자체 검사(Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFRelinkGuardTest`.
/// 결과는 <폴더>/relinkguard-result.json, 진행은 relinkguard-progress.txt.
/// - 재연결 확인을 기존 지연 훅(`probeDelayForTest`, 확인 앞에서 기다림)으로 늦춘다. 재연결 대상은 같은 생성 fixture의 사본(검사 폴더 안)이다.
/// - 실제 열기 패널은 띄우지 않는다(검사 대체). 원래 경합(열기 패널이 떠 있는 동안 재연결이 끝남)은 대체 안에서 주 실행 루프를 잠깐 돌려 흉내 낸다.
/// - 프로젝트 교체 요청 경로: 메뉴(주 메뉴 항목 실행), ⌘ 키(앱 이벤트 큐), 최근 프로젝트, Finder 열기(앱 대리자의 파일 열기 처리), 저장소 직접 호출.
/// - 늦은 결과 보호는 교체 막기와 따로 본다: 저장소의 새 프로젝트·열기를 직접 불러 회차를 바꾼다.
@MainActor
enum RelinkGuardSelfTest {
    typealias Check = LaneSelfTest.Check
    @MainActor final class Box { var log: [String] = []; var appliedDuringPanel: Bool?; var result: Bool?; var result2: Bool? }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        let progress = folder.appendingPathComponent("relinkguard-progress.txt")
        func step(_ m: String) { GestureGuardSelfTest.step(m, progress) }
        let out = folder.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let mainURL = out.appendingPathComponent("main.ontheframe").standardizedFileURL
        let otherURL = out.appendingPathComponent("other.ontheframe").standardizedFileURL
        let src = folder.appendingPathComponent("sources/otf-TA.mp4")
        let copy = folder.appendingPathComponent("relink/otf-TA.mp4").standardizedFileURL
        let bad = folder.appendingPathComponent("relink/not-media.mp4").standardizedFileURL
        try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not media".utf8).write(to: bad)
        let box = Box()
        s.openPanelOverrideForTest = { box.log.append("openPanel"); return nil }
        defer { s.openPanelOverrideForTest = nil; s.probeDelayForTest = 0 }

        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { return finish(folder, [Check(name: "setup.window", pass: false, detail: "")]) }
        _ = await LaneSelfTest.regainFocus(w)

        func build(_ url: URL) async -> Bool {
            let n0 = s.assets.count
            s.importFiles([src])
            _ = await LaneSelfTest.waitUntil(30) { s.assets.count > n0 && s.importing == 0 }
            _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
            guard let a = s.assets.last else { return false }
            s.addToTimeline(a.id)
            s.savePanelResultForTest = url
            s.saveProject()
            await LaneSelfTest.settle()
            return s.projectURL == url && !s.isDirty
        }
        step("setup")
        let okOther = await build(otherURL)
        s.resetProject(); await LaneSelfTest.settle()
        let okMain = await build(mainURL)
        try? FileManager.default.copyItem(at: src, to: copy)
        guard okOther, okMain, let mid = s.timeline.media.first?.id, FileManager.default.fileExists(atPath: copy.path) else {
            check("setup", false, "other \(okOther) main \(okMain)"); return finish(folder, checks)
        }
        check("setup", true)
        func mediaPath() -> String { s.timeline.media.first { $0.id == mid }?.path ?? "nil" }
        let origPath = mediaPath()
        func openFile(_ u: URL) async -> Bool { _ = await s.openProject(at: u); await LaneSelfTest.settle(); return s.projectURL == u }
        func dismissAll() async {
            for _ in 0..<4 where s.alerts.isShowing {
                s.alerts.pressButton(s.alerts.currentButtons.count > 2 ? 1 : 0)   // 확인(단추 하나) 또는 저장 확인의 취소
                _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing && w.attachedSheet == nil }
                await LaneSelfTest.settle()
            }
        }
        /// 재연결을 늦춰 시작한다(결과는 box.result)
        func startRelink(_ to: URL, delay: Double, into keyPath: ReferenceWritableKeyPath<Box, Bool?> = \.result) {
            s.probeDelayForTest = UInt64(delay * 1e9)
            box[keyPath: keyPath] = nil
            Task { @MainActor in box[keyPath: keyPath] = await s.relinkMedia(mid, to: to) }
        }
        func relinkDone(_ keyPath: ReferenceWritableKeyPath<Box, Bool?> = \.result, _ seconds: Double = 15) async -> Bool {
            let ok = await LaneSelfTest.waitUntil(seconds) { box[keyPath: keyPath] != nil }
            s.probeDelayForTest = 0
            await LaneSelfTest.settle()
            return ok
        }
        struct Snap: Equatable { let url: URL?; let id: UUID; let t: Timeline; let depth: Int; let dirty: Bool }
        func snap() -> Snap { Snap(url: s.projectURL, id: s.projectID, t: s.timeline, depth: s.history.undoDepth, dirty: s.isDirty) }
        /// 교체 거절 알림이 떴는가(재연결 확인 중이라는 문구)
        func rejectedForRelink() -> Bool { s.alert?.title == "프로젝트를 바꿀 수 없습니다" && s.alert?.message.contains("재연결") == true }

        // 1. 원래 경합: 변경 없는 프로젝트에서 재연결 확인 중 열기 → 열기 패널(대체 안에서 주 실행 루프를 돌림) → 다른 프로젝트를 엶.
        //    실제 runModal처럼 패널이 떠 있는 동안에는 주 행위자 작업이 돌지 않아, 재연결은 패널이 닫힌 직후·열기 시작 전에 적용되고 열기가 그것을 덮었다(고치기 전).
        _ = await LaneSelfTest.regainFocus(w)
        step("race")
        let race0 = snap()
        s.openPanelOverrideForTest = {
            box.log.append("openPanel(race)")
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))   // 패널이 떠 있는 동안(주 실행 루프는 돈다)
            box.appliedDuringPanel = mediaPath() == copy.path
            return otherURL
        }
        startRelink(copy, delay: 1.0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        s.requestOpenProject(nil)
        let rejected1 = rejectedForRelink()
        _ = await relinkDone()
        _ = await LaneSelfTest.waitUntil(5) { s.openProgress == nil && !s.openRequested }
        await LaneSelfTest.settle()
        let lost = box.result == true && s.projectURL == otherURL   // 재연결은 적용되었다고 했는데 프로젝트가 바뀜(확인 없이 사라짐)
        check("race.replacementRejectedRelinkKept", rejected1 && box.appliedDuringPanel == nil && s.projectURL == mainURL && mediaPath() == copy.path
              && s.history.undoDepth == race0.depth + 1 && s.isDirty,
              "rejected \(rejected1) relinkResult \(box.result.map { "\($0)" } ?? "nil") panelRan \(box.appliedDuringPanel != nil) appliedDuringPanel \(box.appliedDuringPanel.map { "\($0)" } ?? "nil") project \(s.projectURL?.lastPathComponent ?? "nil") relinkLostByOpen \(lost)")
        await dismissAll()
        s.openPanelOverrideForTest = { box.log.append("openPanel"); return nil }
        _ = await openFile(mainURL)

        // 2. 재연결 확인 중 모든 교체 경로가 거절된다(메뉴·키·최근·Finder·직접). 끝나면(성공) 다시 쓸 수 있다.
        _ = await LaneSelfTest.regainFocus(w)
        _ = s.renameLane(Lane.audioID, to: "바뀜")   // 바뀐 프로젝트: 교체가 허용되면 저장 확인이 뜬다(거절과 구분)
        let pre2 = snap(), panels2 = box.log.count
        startRelink(copy, delay: 12)
        _ = await LaneSelfTest.waitUntil(1) { s.relinkInProgress }
        let busy2 = s.relinkInProgress
        var rows: [String] = []
        let attempts: [(String, () async -> Void)] = [
            ("new.menu", { _ = LaneSelfTest.menuItem("새 프로젝트") }),
            ("new.key", { await LaneSelfTest.key(45, "n", [.command], w) }),
            ("new.direct", { s.requestNewProject() }),
            ("open.menu", { _ = LaneSelfTest.menuItem("프로젝트 열기…") }),
            ("open.key", { await LaneSelfTest.key(31, "o", [.command], w) }),
            ("open.direct", { s.requestOpenProject(nil) }),
            ("recent.menu", { _ = LaneSelfTest.menuItem("other") }),
            ("recent.direct", { if let r = s.recentProjects.first(where: { $0.name == "other" }) { s.openRecent(r) } }),
            ("finder", { AppDelegate().application(NSApp, open: [otherURL]) }),
        ]
        for (name, act) in attempts {
            step("attempt \(name)")
            await act()
            _ = await LaneSelfTest.waitUntil(1) { s.alerts.isShowing }
            await LaneSelfTest.settle()
            let ok = rejectedForRelink() && snap() == pre2 && box.log.count == panels2
            rows.append("\(name)=\(ok ? "rejected" : "NOT(alert \(s.alert?.title ?? "nil") same \(snap() == pre2) panels +\(box.log.count - panels2))")")
            await dismissAll()
        }
        let allRejected = rows.allSatisfy { $0.hasSuffix("=rejected") }
        check("busy.replacementPathsRejected", busy2 && allRejected, "busy \(busy2) \(rows.joined(separator: " "))")
        let done2 = await relinkDone(\.result, 20)
        check("busy.relinkStillApplies", done2 && box.result == true && mediaPath() == copy.path && s.history.undoDepth == pre2.depth + 1 && !s.relinkInProgress,
              "done \(done2) result \(box.result.map { "\($0)" } ?? "nil") busy \(s.relinkInProgress)")
        s.requestNewProject()   // 바뀐 프로젝트: 이제 거절이 아니라 저장 확인
        _ = await LaneSelfTest.waitUntil(2) { s.alerts.isShowing }
        let availAfterSuccess = s.alert?.title == "변경 사항을 저장할까요?"
        await dismissAll()
        check("busy.availableAfterSuccess", availAfterSuccess, "alert \(s.alert?.title ?? "nil")")
        // 실패로 끝난 확인 뒤에도 다시 쓸 수 있다
        startRelink(bad, delay: 1.5)
        _ = await LaneSelfTest.waitUntil(1) { s.relinkInProgress }
        s.requestNewProject()
        let rejectedF = rejectedForRelink()
        await dismissAll()
        _ = await relinkDone()
        let failAlert = s.alert?.title == "다시 연결할 수 없습니다"
        await dismissAll()
        s.requestNewProject()
        _ = await LaneSelfTest.waitUntil(2) { s.alerts.isShowing }
        let availAfterFail = s.alert?.title == "변경 사항을 저장할까요?"
        await dismissAll()
        check("busy.availableAfterFailure", rejectedF && box.result == false && failAlert && !s.relinkInProgress && availAfterFail,
              "rejectedDuring \(rejectedF) result \(box.result.map { "\($0)" } ?? "nil") failAlert \(failAlert) busy \(s.relinkInProgress) avail \(availAfterFail)")
        _ = await openFile(mainURL)

        // 3. 늦은 결과(교체 막기와 따로): 확인 중 저장소의 열기·새 프로젝트를 직접 불러 회차를 바꾼다. 결과는 아무것도 바꾸지 않는다.
        for (label, replace) in [("reopenSame", 0), ("newProject", 1), ("otherProject", 2)] {
            _ = await LaneSelfTest.regainFocus(w)
            step("stale \(label)")
            startRelink(copy, delay: 2.5)
            _ = await LaneSelfTest.waitUntil(1) { s.relinkInProgress }
            try? await Task.sleep(nanoseconds: 100_000_000)
            s.probeDelayForTest = 0   // 이미 기다리는 확인은 그대로, 아래 열기는 늦추지 않음
            switch replace {
            case 0: _ = await openFile(mainURL)
            case 1: s.resetProject(); await LaneSelfTest.settle()
            default: _ = await openFile(otherURL)
            }
            let mid3 = snap()
            _ = await relinkDone()
            let after = snap()
            let sameID = label == "reopenSame" ? s.projectID == race0.id : true
            check("stale.\(label)Rejected", box.result == false && after == mid3 && sameID && !s.relinkInProgress && (label != "reopenSame" || mediaPath() == origPath),
                  "result \(box.result.map { "\($0)" } ?? "nil") changed \(after != mid3) sameID \(sameID) busy \(s.relinkInProgress) path \(mediaPath() == origPath ? "orig" : mediaPath())")
            await dismissAll()
            _ = await openFile(mainURL)
        }

        // 4. 겹친 재연결: 진행 중이면 두 번째는 시작하지 않는다(첫 번째는 그대로 적용). 끝나면 바쁨 상태가 풀린다.
        _ = await LaneSelfTest.regainFocus(w)
        step("overlap")
        let pre4 = snap()
        startRelink(copy, delay: 2.0)
        _ = await LaneSelfTest.waitUntil(1) { s.relinkInProgress }
        let second = await s.relinkMedia(mid, to: copy)
        let secondMsg = s.statusMessage ?? ""
        _ = await relinkDone()
        check("overlap.secondRejectedFirstApplies", !second && secondMsg.contains("재연결") && box.result == true && s.history.undoDepth == pre4.depth + 1 && !s.relinkInProgress,
              "second \(second) msg \(secondMsg) first \(box.result.map { "\($0)" } ?? "nil") depth +\(s.history.undoDepth - pre4.depth)")
        _ = await openFile(mainURL)
        // 이전 회차의 끝이 새 작업의 바쁨 상태를 지우지 않는다: A 확인 중 회차를 바꾸고(A는 늦은 결과가 됨) B를 시작 → A가 끝난 뒤에도 B는 진행 중
        startRelink(copy, delay: 2.0)
        _ = await LaneSelfTest.waitUntil(1) { s.relinkInProgress }
        s.probeDelayForTest = 0
        _ = await openFile(mainURL)
        let busyAfterReplace = s.relinkInProgress
        s.probeDelayForTest = 5_000_000_000
        box.result2 = nil
        Task { @MainActor in box.result2 = await s.relinkMedia(mid, to: copy) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        s.probeDelayForTest = 0
        _ = await LaneSelfTest.waitUntil(5) { box.result != nil }
        let bStillBusy = s.relinkInProgress && box.result2 == nil
        _ = await LaneSelfTest.waitUntil(10) { box.result2 != nil }
        await LaneSelfTest.settle()
        check("overlap.olderCompletionKeepsNewerBusy", !busyAfterReplace && box.result == false && bStillBusy && box.result2 == true && !s.relinkInProgress,
              "busyAfterReplace \(busyAfterReplace) A \(box.result.map { "\($0)" } ?? "nil") B busy while A ended \(bStillBusy) B \(box.result2.map { "\($0)" } ?? "nil") busy end \(s.relinkInProgress)")
        _ = await openFile(mainURL)

        // 5. 보통 재연결과 실행 취소(한 단계), 그 뒤 파일 명령
        _ = await LaneSelfTest.regainFocus(w)
        step("normal")
        let pre5 = snap()
        let ok5 = await s.relinkMedia(mid, to: copy)
        let applied = mediaPath() == copy.path && s.history.undoDepth == pre5.depth + 1 && s.isDirty
        s.undo(); await LaneSelfTest.settle()
        check("normal.relinkAndUndo", ok5 && applied && snap() == pre5 && mediaPath() == origPath, "ok \(ok5) applied \(applied) undone \(snap() == pre5)")
        let opened = await openFile(otherURL)
        check("normal.replacementAfterRelink", opened, "")
        finish(folder, checks)
    }

    /// CP-04 수동 확인 fixture 만들기(`-OTFMakeManualRelinkFixture`, 폴더를 열며 실행). 앱은 샌드박스라 원본 접근은 앱이 만든 북마크로만 이어진다.
    /// 그래서 프로젝트는 앱이 만든다: <폴더>/sources의 otf-TA·otf-TB를 가져와 타임라인에 놓고 <폴더>/cp04-manual.ontheframe에 저장한다
    /// (저장 패널 대신 위치 주입). 그 뒤 스크립트가 이 폴더의 otf-TA 사본만 지워 "찾을 수 없는 원본"을 만든다.
    static func makeManualFixture(folder: URL) async {
        let s = ProjectStore.shared
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        let names = ["otf-TA.mp4", "otf-TB.mp4"]
        s.importFiles(names.map { folder.appendingPathComponent("sources/\($0)") })
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == names.count && s.importing == 0 }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        for n in names { if let a = s.assets.first(where: { $0.url.lastPathComponent == n }) { s.addToTimeline(a.id) } }
        await LaneSelfTest.settle()
        s.savePanelResultForTest = folder.appendingPathComponent("cp04-manual.ontheframe")
        s.saveProject()
        await LaneSelfTest.settle()
        let ok = s.projectURL?.lastPathComponent == "cp04-manual.ontheframe" && !s.isDirty && s.timeline.media.count == 2
        try? Data((ok ? "ok" : "failed").utf8).write(to: folder.appendingPathComponent("fixture-made.txt"))
        s.discardConfirmedForTest()
        NSApp.terminate(nil)
    }

    /// CP-04 수동 확인 fixture 점검(`-OTFManualRelinkCheck <교체 파일>`, Finder로 연 fixture 프로젝트와 함께). 소유자 확인 전에 fixture가 의도대로 되는지 본다:
    /// 열면 원본 하나가 없음 → "미디어 재연결…" 메뉴가 켜짐 → 교체 파일로 재연결하면 확인이 지연 동안 진행 중이고 화면 이벤트는 계속 돎 → 열기 요청은 거절 →
    /// 확인이 끝나면 적용 → 실행 취소 한 단계. 지연 인자가 없으면 곧바로 끝나는지도 본다. 실제 열기 패널은 띄우지 않는다(대체). 결과는 <fixture 폴더>/manual-check-result.json.
    static func manualFixtureCheck(replacement: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)) }
        let folder = replacement.deletingLastPathComponent().deletingLastPathComponent()
        let progress = folder.appendingPathComponent("manual-check-progress.txt")
        func step(_ m: String) { GestureGuardSelfTest.step(m, progress) }
        step("start delay=\(s.relinkDelayForTest)")
        s.openPanelOverrideForTest = { nil }   // 거절이 깨져도 실제 패널을 띄우지 않게
        _ = await LaneSelfTest.waitUntil(30) { s.projectURL != nil && s.openProgress == nil && !s.openRequested }
        _ = await LaneSelfTest.waitUntil(5) { s.alerts.isShowing }
        let missingAlert = s.alert?.title ?? "nil"
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing }; await LaneSelfTest.settle() }
        let id = s.timeline.media.first { s.missingMedia[$0.id] != nil }?.id
        step("opened missing=\(s.missingMedia.count)")
        check("fixture.opensWithOneMissing", s.projectURL?.lastPathComponent == "cp04-manual.ontheframe" && s.missingMedia.count == 1 && id != nil,
              "project \(s.projectURL?.lastPathComponent ?? "nil") missing \(s.missingMedia.count) alert \(missingAlert)")
        func menuEnabled(_ title: String) -> Bool {
            func all(_ m: NSMenu?) -> [NSMenuItem] { guard let m else { return [] }; return m.items.flatMap { [$0] + all($0.submenu) } }
            guard let it = all(NSApp.mainMenu).first(where: { $0.title == title }), let m = it.menu else { return false }
            m.delegate?.menuNeedsUpdate?(m)
            return m.items.first { $0.title == title }?.isEnabled == true
        }
        check("fixture.relinkMenuEnabled", menuEnabled("미디어 재연결…"), "")
        guard let id else { return finishManual(folder, checks) }
        let delay = Double(s.relinkDelayForTest) / 1e9
        let path0 = s.timeline.media.first { $0.id == id }?.path, depth0 = s.history.undoDepth
        let t0 = Date()
        var result: Bool?
        Task { @MainActor in result = await s.relinkMedia(id, to: replacement) }
        _ = await LaneSelfTest.waitUntil(1) { s.relinkInProgress }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            var worst = 0.0
            for _ in 0..<5 { let a = Date(); await LaneSelfTest.settle(); worst = max(worst, Date().timeIntervalSince(a)) }   // 이벤트 왕복(settle은 50 ms 쉼 포함)
            let busy = s.relinkInProgress && result == nil
            check("delay.pendingAndResponsive", busy && worst < 0.5, "busy \(busy) worst event round trip \(String(format: "%.3f", worst))s delay \(delay)s")
            if busy {
                s.requestOpenProject(nil)
                _ = await LaneSelfTest.waitUntil(2) { s.alerts.isShowing }
                let rejected = s.alert?.title == "프로젝트를 바꿀 수 없습니다" && s.alert?.message.contains("재연결") == true
                while s.alerts.isShowing { s.alerts.pressButton(0); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing }; await LaneSelfTest.settle() }
                check("delay.openRejected", rejected && s.projectURL?.lastPathComponent == "cp04-manual.ontheframe", "")
            }
        }
        step("waiting result")
        _ = await LaneSelfTest.waitUntil(delay + 20) { result != nil }
        step("result \(result.map { "\($0)" } ?? "nil")")
        let elapsed = Date().timeIntervalSince(t0)
        let applied = result == true && s.timeline.media.first { $0.id == id }?.path == replacement.standardizedFileURL.path && s.history.undoDepth == depth0 + 1
        check(delay > 0 ? "delay.finishesAfterDelay" : "noDelay.finishesQuickly", applied && (delay > 0 ? elapsed >= delay * 0.9 : elapsed < 3),
              "result \(result.map { "\($0)" } ?? "nil") elapsed \(String(format: "%.1f", elapsed))s delay \(delay)s")
        s.undo(); await LaneSelfTest.settle()
        check("undoOneStep", s.history.undoDepth == depth0 && s.timeline.media.first { $0.id == id }?.path == path0, "")
        finishManual(folder, checks, name: delay > 0 ? "manual-check-delay.json" : "manual-check-nodelay.json")
    }
    static func finishManual(_ folder: URL, _ checks: [Check], name: String = "manual-check-result.json") {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent(name)) }
        ProjectStore.shared.discardConfirmedForTest()   // 저장하지 않고 끝낸다(fixture 파일은 그대로)
        NSApp.terminate(nil)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: "재연결 확인은 지연 훅으로 늦춤, 열기 패널은 검사 대체(실제 패널 아님), 메뉴는 주 메뉴 항목 실행, 키는 앱 이벤트 큐의 ⌘ 조합, Finder는 앱 대리자의 파일 열기 처리 직접 호출"
                                        + (LaneSelfTest.direct ? " (직접 경로: 앱 활성화 실패, 키 경로는 보지 않음)" : ""))]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("relinkguard-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
