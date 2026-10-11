#if DEBUG
import AppKit
import OnTheFrameEngine

/// 프로젝트 열기·미디어 가져오기 회귀 자체 검사(2026-10-11, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFOpenImportTest`.
/// 실제 메뉴 항목("프로젝트 열기…"·"가져오기…"·"새 프로젝트")을 눌러 메뉴 동작 → 요청 → 저장하지 않은 변경 확인 → 열기·가져오기 경로를 지난다.
/// 패널만 고른 파일로 바꾼다(openPanelOverrideForTest·importPanelOverrideForTest). 폴더: sources/(otf-TA·otf-TB·aud-steady48s·long-180s),
/// p-v1(커밋 44943ea의 실제 저장기)·p-v2–v4(지금 저장 결과를 그 형식으로 바꾼 것)·p-v5(지금 저장기)·p-long(3분 원본).
/// 기대값은 fixture를 만든 배치에서 손으로 정했다. 결과는 <폴더>/openimport-result.json.
@MainActor
enum OpenImportSelfTest {
    typealias Check = LaneSelfTest.Check

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard s.editorWindow != nil else { return finish(folder, [Check(name: "setup.window", pass: false, detail: "")]) }
        let src = folder.appendingPathComponent("sources")
        func menu(_ title: String) async -> Bool { let ok = LaneSelfTest.menuItem(title); await LaneSelfTest.settle(); return ok }
        func dismissAlert() async { if s.alerts.isShowing { s.alerts.pressButton(0) }; _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing }; await LaneSelfTest.settle() }
        /// 메뉴로 열고 끝날 때까지(적용·실패·취소) 기다린다. 걸린 시간(초)과 진행 카드를 본 적이 있는가.
        func openViaMenu(_ url: URL, timeout: Double = 30) async -> (seconds: Double, menu: Bool, sawProgress: Bool) {
            s.openPanelOverrideForTest = { url }
            let t0 = Date()
            let ok = await menu("프로젝트 열기…")
            var saw = false
            let end = Date().addingTimeInterval(timeout)
            repeat {
                if s.openProgress != nil { saw = true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < end && (s.openProgress != nil || (Date().timeIntervalSince(t0) < 0.3 && !saw && s.projectURL != url.standardizedFileURL && !s.alerts.isShowing))
            s.openPanelOverrideForTest = nil
            return (Date().timeIntervalSince(t0), ok, saw)
        }

        // 1. 형식 1–5: 메뉴로 열기 → 적용(경로·레인·클립·변형·소리 값), 원본 모두 찾음
        struct Expect { let lanes: Int; let video: Int; let audio: Int; let duration: Int; let transform: ClipTransform?; let clipAudio: ClipAudio? }
        let later = Expect(lanes: 4, video: 2, audio: 3, duration: 220, transform: ClipTransform(scalePermille: 500, offsetX: 400, offsetY: -200), clipAudio: ClipAudio(volumePercent: 70, fadeIn: .init(length: 15)))
        let expects: [Int: Expect] = [
            1: Expect(lanes: 2, video: 2, audio: 2, duration: 210, transform: nil, clipAudio: nil),
            2: Expect(lanes: 4, video: 2, audio: 3, duration: 220, transform: nil, clipAudio: nil),
            3: Expect(lanes: later.lanes, video: 2, audio: 3, duration: 220, transform: later.transform, clipAudio: nil),
            4: Expect(lanes: later.lanes, video: 2, audio: 3, duration: 220, transform: later.transform, clipAudio: nil),
            5: later]
        for v in 1...5 {
            let p = folder.appendingPathComponent("p-v\(v).ontheframe")
            let r = await openViaMenu(p)
            let t = s.timeline
            let e = expects[v]!
            let transform = t.clips.compactMap(\.transform).first
            let clipAudio = t.audioClips.compactMap(\.audio).first
            let a2Volume = t.lanes(.audio).last?.volumePercent
            let ok = r.menu && s.projectURL == p.standardizedFileURL && s.missingMedia.isEmpty && t.lanes.count == e.lanes && t.clips.count == e.video
                && t.audioClips.count == e.audio && t.durationFrames == e.duration && transform == e.transform && clipAudio == e.clipAudio
                && (v == 1 || a2Volume == 60) && !s.alerts.isShowing && !s.isDirty
            check("open.version\(v).viaMenu", ok, String(format: "%.2fs menu %@ lanes %d v %d a %d dur %d missing %d transform %@ audio %@ alert %@", r.seconds, r.menu ? "ok" : "disabled",
                                                    t.lanes.count, t.clips.count, t.audioClips.count, t.durationFrames, s.missingMedia.count,
                                                    String(describing: transform), String(describing: clipAudio), s.alert?.message ?? "-"))
            if s.alerts.isShowing { await dismissAlert() }
        }
        let afterV5 = s.timeline, urlV5 = s.projectURL

        // 2. 손상된 파일: 알림(이유·현재 프로젝트 그대로), 현재 프로젝트·경로 그대로
        let bad = folder.appendingPathComponent("bad.ontheframe")
        try? Data("{ not a project".utf8).write(to: bad)
        _ = await openViaMenu(bad)
        _ = await LaneSelfTest.waitUntil(3) { s.alerts.isShowing }
        let badMsg = s.alert?.message ?? ""
        await dismissAlert()
        check("open.malformedKeepsProject", badMsg.contains("손상") && badMsg.contains("현재 프로젝트는 그대로") && s.timeline == afterV5 && s.projectURL == urlV5, badMsg)

        // 3. 긴 원본(3분 1080p) 프로젝트: 원본 확인 시간, 진행 카드
        let long = folder.appendingPathComponent("p-long.ontheframe")
        let rl = await openViaMenu(long)
        check("open.longMediaProject", s.projectURL == long.standardizedFileURL && s.missingMedia.isEmpty && s.timeline.clips.first?.length == 5_400 && rl.seconds < 15,
              String(format: "%.2fs progress seen %@", rl.seconds, rl.sawProgress ? "yes" : "no"))
        let afterLong = s.timeline

        // 4. 열기 취소(원본 확인 중): 현재 프로젝트 그대로, 늦은 결과 없음
        s.probeDelayForTest = 1_500_000_000
        s.openPanelOverrideForTest = { folder.appendingPathComponent("p-v5.ontheframe") }
        _ = await menu("프로젝트 열기…")
        _ = await LaneSelfTest.waitUntil(5) { (s.openProgress?.total ?? 0) > 0 }
        let cardStage = s.openProgress?.stage ?? "-", cardName = s.openProgress?.currentName ?? "-"
        s.cancelOpen()
        let cancelling = s.openProgress?.cancelling == true
        _ = await LaneSelfTest.waitUntil(10) { s.openProgress == nil }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        s.probeDelayForTest = 0; s.openPanelOverrideForTest = nil
        check("open.cancelKeepsProject", cancelling && s.projectURL == long.standardizedFileURL && s.timeline == afterLong && (s.statusMessage ?? "").contains("열기를 취소"),
              "stage '\(cardStage)' name '\(cardName)' status '\(s.statusMessage ?? "")'")

        // 5. 가져오기(메뉴): 새 프로젝트 → 3분 MP4 + 짧은 MP4 두 개, 단계 표시, 걸린 시간
        _ = await menu("새 프로젝트")
        _ = await LaneSelfTest.waitUntil(3) { s.projectURL == nil }
        let files = [src.appendingPathComponent("long-180s.mp4"), src.appendingPathComponent("otf-TB.mp4")]
        s.importPanelOverrideForTest = { files }
        let i0 = Date()
        let im = await menu("가져오기…")
        var stages = Set<String>(), names = Set<String>()
        while (s.importProgress != nil || s.importing > 0), Date().timeIntervalSince(i0) < 60 {
            if let st = s.importProgress?.stage { stages.insert(st.components(separatedBy: " · ").first ?? st) }
            if let n = s.importProgress?.currentName { names.insert(n) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let importSeconds = Date().timeIntervalSince(i0)
        s.importPanelOverrideForTest = nil
        check("import.twoMP4sViaMenu", im && s.assets.count == 2 && s.assets.map(\.name).sorted() == ["long-180s.mp4", "otf-TB.mp4"] && !s.alerts.isShowing && importSeconds < 15,
              String(format: "%.2fs assets %@ stages %@ names %d", importSeconds, s.assets.map(\.name).description, stages.sorted().description, names.count))
        if s.alerts.isShowing { await dismissAlert() }

        // 6. 가져오기 취소: 이번 묶음은 아무것도 넣지 않고 늦은 결과도 버린다
        _ = await menu("새 프로젝트")
        if s.alerts.isShowing { s.alerts.pressButton(2); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }   // 저장 안 함(가져오기로 바뀐 프로젝트)
        _ = await LaneSelfTest.waitUntil(3) { s.assets.isEmpty }
        s.probeDelayForTest = 1_500_000_000
        s.importPanelOverrideForTest = { files }
        _ = await menu("가져오기…")
        _ = await LaneSelfTest.waitUntil(5) { s.importProgress != nil }
        try? await Task.sleep(nanoseconds: 300_000_000)
        s.cancelImport()
        let importCancelling = s.importProgress?.cancelling == true
        _ = await LaneSelfTest.waitUntil(10) { s.importProgress == nil }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        s.probeDelayForTest = 0; s.importPanelOverrideForTest = nil
        check("import.cancelNoLateResults", importCancelling && s.assets.isEmpty && s.importing == 0 && (s.statusMessage ?? "").contains("가져오기를 취소"), s.statusMessage ?? "")
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true, detail: "메뉴 항목 동작은 NSMenu.performActionForItem(메뉴 선택과 같은 경로)")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("openimport-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
