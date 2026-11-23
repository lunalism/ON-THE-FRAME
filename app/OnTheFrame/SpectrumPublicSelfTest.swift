#if DEBUG
import AppKit
import OnTheFrameEngine

/// 공개 스펙트럼 만들기·편집 자체 검사(SP-PUBLIC-01, 2026-11-23, 보통 Debug 앱).
/// 스펙트럼 진단 대상(OTF_SPECTRUM_DIAGNOSTICS)은 2026-10-31부터 컴파일 자원 한도 안에서 빌드되지 않으므로(IMG-BUILD-02) 그 대상과 SpectrumLaneSelfTest에
/// 기대지 않는다(SP-PUBLIC-PREBUILD-02): fixture·알림 닫기는 이 검사 안에 둔다.
/// `open -n -W -a OnTheFrame.app <폴더> --args -OTFNewProjectLanes2 -OTFSpectrumPublicTest`(scripts/spectrum-public-test.sh). 생성 fixture(<폴더>/sources/otf-TA.mp4)만 쓴다.
/// fixture가 두 레인 새 프로젝트(V1·A1)를 전제로 하므로 `-OTFNewProjectLanes2`를 명시한다(고정 목록 legacyTwoLaneEntryPoints에는 넣지 않음).
///
/// 컴파일 메모리(SP-PUBLIC-COMPILE-HARDEN-06, 2026-11-23): 검사 전체를 한 비동기 함수에 두었던 이전 모양은 Debug 코드 생성에서 컴파일러 RSS가
/// 조기 중지 한도(1280 MiB)를 넘었다(SpPublicUX-Validate-20261123-01). 그래서 절마다 작은 함수로 나누고 네 파일에 둔다. 검사 이름·단언·차례는 그대로다.
///   - 이 파일: 진입점, 공유 상태(Context), 기대 검사 목록, fixture, 결과 쓰기
///   - SpectrumPublicEditingChecks.swift: 1–8절(만들기·소스·모양·시작/길이·저장/다시 열기·고르기/삭제·소스 없음) 14개
///   - SpectrumPublicExportChecks.swift: 9절 내보내기 사전 차단 4개, 이미지 프로젝트 사전 차단 4개(별도 진입점)
///   - SpectrumPublicSaveFormatChecks.swift: 10–14절 저장 형식 안내 9개, 낡은 확인 닫기 1개
/// 한 실행의 성공 경로는 `expectedChecks` 28개 + 실행 방식 줄 1개 = 29줄이다. 앞 절이 멈춰 실행하지 못한 검사는 빠뜨리지 않고 실패 줄로 적는다(finish).
/// 패널 단추의 SwiftUI 누름 자체와 화면 표시는 보지 않는다(소유자 수동 확인). 움직이는 프리뷰는 기존 Spectrum 검사 묶음의 범위다.
/// 결과는 <폴더>/spectrum-public-result.json.
@MainActor
enum SpectrumPublicSelfTest {
    typealias Check = LaneSelfTest.Check

    /// 성공 경로에서 한 번씩 나와야 하는 검사 이름(차례대로). 결과에 없으면 finish가 실패 줄로 채운다.
    static let expectedChecks: [String] = [
        "create.menu", "create.panelCommand", "create.undoRedo", "create.staleSessionNoChange",
        "source.select", "source.keepsTiming", "style.edit",
        "timeline.placementAndDuration", "timeline.overlapRejected",
        "persist.saveReopen", "persist.existingSpectrumFormat",
        "select.clickAndHit", "delete.liftOnly", "missing.sourceHandledSafely",
        "export.preflightBeforePicker", "export.preflightMenuAndShortcut", "export.engineGuardPreserved", "export.noSpectrumUnaffected",
        "saveFormat.triggerTable",
        "saveFormat.new8WarnsAndCancelWritesNothing", "saveFormat.new8SaveWritesOnce", "saveFormat.same8NoRepeat",
        "saveFormat.upgrade8to11WarnsAndCancelKeepsFile", "saveFormat.failureKeepsFormatThenSaves11",
        "saveFormat.same11AndSaveAsNoRepeat", "saveFormat.reopenTracksFileFormat",
        "saveFormat.existing5to8", "alerts.cancelCurrentNeverApproves",
    ]
    /// 이미지 프로젝트 내보내기 사전 차단 실행(runImageExportGuard)의 기대 검사
    static let expectedImageChecks: [String] = [
        "image.spectrumCreated", "image.preflightBeforePicker", "image.startExportRefusedKeepsFile", "image.noSpectrumReasonAfterDelete",
    ]

    /// 시험 연결점(격리되지 않은 클로저)이 올리는 횟수
    final class Counter: @unchecked Sendable { var n = 0 }

    /// 절 사이에 넘기는 상태. 각 절 함수는 앞 절이 참을 돌려준 뒤에만 불리므로 앞 절이 채운 값을 쓴다.
    @MainActor
    final class Context {
        let s = ProjectStore.shared
        let folder: URL, out: URL, ta: URL
        let w: NSWindow, tv: TimelineNSView
        var checks: [Check] = []
        // 1–8절
        var base: Timeline!
        var f1: Clip!, f2: Clip!, g2: Clip!, cp: Clip!
        var made: SpectrumItem!
        var madeG: SpectrumItem?
        var t2: Timeline!, tY: Timeline!, tP: Timeline!, r: Timeline!
        var style: SpectrumItemStyle!
        // 11–13절
        let writes = Counter()
        var fileA: URL!

        init(folder: URL, w: NSWindow, tv: TimelineNSView) {
            self.folder = folder; self.w = w; self.tv = tv
            out = folder.appendingPathComponent("out")
            ta = folder.appendingPathComponent("sources/otf-TA.mp4")
        }
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)) }
        /// 절을 멈추는 실패 줄을 적고 거짓을 돌려준다(뒤 절은 실행하지 않고, finish가 남은 검사를 실패로 채운다)
        func stop(_ n: String, _ d: String = "") -> Bool { check(n, false, d); return false }
        func win(_ p: NSPoint) -> NSPoint { tv.convert(p, to: nil) }
        func center(_ c: Clip) -> NSPoint { NSPoint(x: tv.x(c.start + c.length / 2), y: tv.laneRect(c.lane ?? Lane.audioID)?.midY ?? 0) }
        /// 실제 문맥 메뉴(보기의 menu(for:) — 오른쪽 누름과 같은 경로)와 그 안의 "스펙트럼 추가"
        func contextMenu(at p: NSPoint) -> (NSMenu, NSMenuItem?)? {
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: win(p), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1), let m = tv.menu(for: e) else { return nil }
            return (m, m.items.first { $0.title == "스펙트럼 추가" })
        }
        func waitAlert() async -> Bool { await LaneSelfTest.waitUntil(5) { self.s.alerts.isShowing } }
        func press(_ i: Int) async {
            s.alerts.pressButton(i)
            _ = await LaneSelfTest.waitUntil(5) { !self.s.alerts.isShowing }
            await LaneSelfTest.settle()
        }
        func fileVersion(_ u: URL) -> Int? { (try? Data(contentsOf: u)).flatMap { try? ProjectFile.decode($0).document.version } }
        func bytes(_ u: URL) -> Data? { try? Data(contentsOf: u) }
    }

    static func run(folder: URL) async {
        guard let c = await setUp(folder: folder) else { return }
        await runSections(c)
        c.s.persistenceBeforeCommitForTest = nil; c.s.savePanelResultForTest = nil; c.s.saveFailureForTest = false; c.s.exportPanelOverrideForTest = nil
        finish(folder, c.checks, expected: expectedChecks)
    }

    /// 절을 차례대로. 한 절이 거짓(준비 실패)을 돌려주면 뒤 절은 실행하지 않는다.
    private static func runSections(_ c: Context) async {
        // 1–8절: 만들기·편집(SpectrumPublicEditingChecks.swift)
        guard await checkCreateFromMenu(c) else { return }
        await checkCreateFromPanelCommand(c)
        checkSourceSelection(c)
        guard await checkStyleEdit(c) else { return }
        checkPlacementAndDuration(c)
        await checkSaveReopen(c)
        guard await checkSelectAndDelete(c) else { return }
        guard checkMissingSource(c) else { return }
        // 9절: 내보내기 사전 차단(SpectrumPublicExportChecks.swift)
        let panelHits = Counter()
        c.s.exportPanelOverrideForTest = { panelHits.n += 1 }
        await checkExportPreflightDirect(c, panelHits)
        await checkExportPreflightMenuAndShortcut(c, panelHits)
        await checkExportEngineGuard(c)
        await checkExportWithoutSpectrum(c, panelHits)
        c.s.exportPanelOverrideForTest = nil
        // 10–14절: 저장 형식 안내, 낡은 확인 닫기(SpectrumPublicSaveFormatChecks.swift)
        checkSaveFormatTriggerTable(c)
        c.s.persistenceBeforeCommitForTest = { [writes = c.writes] in writes.n += 1 }
        guard await checkSaveFormatNew8Cancel(c) else { return }
        await checkSaveFormatNew8Save(c)
        checkSaveFormatSame8(c)
        guard await checkSaveFormatUpgrade11Cancel(c) else { return }
        await checkSaveFormatFailureThenSave11(c)
        checkSaveFormatSame11AndSaveAs(c)
        await checkSaveFormatReopen(c)
        guard await checkSaveFormatExisting5to8(c) else { return }
        await checkAlertCancelCurrent(c)
    }

    /// 창·fixture 준비. 실패하면 그 이유 한 줄과 함께 결과를 쓰고 nil.
    private static func setUp(folder: URL) async -> Context? {
        let s = ProjectStore.shared
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { finish(folder, [Check(name: "setup.window", pass: false, detail: "")], expected: expectedChecks); return nil }
        _ = await LaneSelfTest.regainFocus(w)
        let out = folder.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // fixture: V1·A1에 쌍 둘(첫 쌍을 60에서 잘라 소리 조각 둘이 같은 계보), 둘째 쌍을 0에 붙여 넣은 복사본(다른 레인, 독립 계보) — SpectrumLaneSelfTest 10절과 같은 모양
        guard let base = await makeProject(s, file: out.appendingPathComponent("public-base.ontheframe"), media: folder.appendingPathComponent("sources/otf-TA.mp4")) else {
            finish(folder, [Check(name: "setup.project", pass: false, detail: s.statusMessage ?? "")], expected: expectedChecks); return nil
        }
        await LaneSelfTest.settle()
        guard let container = LaneSelfTest.find(TimelineContainerView.self, w.contentView) else {
            finish(folder, [Check(name: "setup.timelineView", pass: false, detail: "")], expected: expectedChecks); return nil
        }
        let a1c = base.audioClips.filter { $0.lane == Lane.audioID }.sorted { $0.start < $1.start }
        let cpc = base.audioClips.filter { $0.lane != Lane.audioID }   // 복사본은 A1이 아닌 오디오 레인(레인 수와 무관)
        guard a1c.count == 3, cpc.count == 1, base.spectra.isEmpty else {
            finish(folder, [Check(name: "setup.fixture", pass: false, detail: "A1 \(a1c.count) A2 \(cpc.count) spectra \(base.spectra.count)")], expected: expectedChecks); return nil
        }
        let c = Context(folder: folder, w: w, tv: container.timelineView)
        c.base = base
        c.f1 = a1c[0]; c.f2 = a1c[1]; c.g2 = a1c[2]; c.cp = cpc[0]
        return c
    }

    // MARK: fixture

    /// 새 프로젝트에 생성 fixture 하나를 가져와 엔진 편집으로 만든 타임라인을 넣는다(실행 취소 기록 없음, 저장하지 않음 — 한 번도 저장하지 않은 프로젝트).
    static func prepare(_ s: ProjectStore, media: URL, build: (Timeline, UUID) throws -> Timeline = baseTimeline) async -> Timeline? {
        s.resetProject()
        s.importFiles([media])
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        guard let m = s.assets.first, let t = try? build(s.timeline, m.id) else { return nil }
        s.loadTimelineForTest(t)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        return s.timeline
    }
    /// prepare + 파일 쓰기(writeProject 직접 — 저장 형식 안내가 아닌 것을 보는 앞 절의 fixture)
    static func makeProject(_ s: ProjectStore, file: URL, media: URL) async -> Timeline? {
        guard await prepare(s, media: media) != nil else { return nil }
        return s.writeProject(to: file) ? s.timeline : nil
    }
    nonisolated static func baseTimeline(_ base: Timeline, _ m: UUID) throws -> Timeline {
        let c1 = UUID(), c2 = UUID()
        var x = try base.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: c1)
        x = try x.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: c2)
        x = try x.splitting(clip: c1, atFrame: 60)
        return try x.pasting(try x.copying(clip: c2), at: 0, newLaneName: { $0 == .video ? "영상" : "오디오" }).timeline
    }
    /// 자르지 않은 쌍 하나(계보·스펙트럼·자막 없음 → 형식 5)
    nonisolated static func plainTimeline(_ base: Timeline, _ m: UUID) throws -> Timeline {
        try base.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID)
    }
    static func dismiss() async {
        let s = ProjectStore.shared
        while s.alerts.isShowing { s.alerts.pressButton(s.alerts.currentButtons.count > 1 ? 1 : 0); _ = await LaneSelfTest.waitUntil(5) { !s.alerts.isShowing } }
    }

    // MARK: 결과

    /// 결과 쓰기. 기대 검사 가운데 결과가 없는 것은 실패 줄로 채우고(빠진 결과를 통과로 세지 않는다), 같은 이름이 두 번 나오면 실패 줄을 더한다.
    /// 성공 경로의 줄 수 = 기대 검사 수 + 실행 방식 줄 1.
    static func finish(_ folder: URL, _ checks: [Check], expected: [String], file: String = "spectrum-public-result.json") {
        var rows = checks
        let names = checks.map(\.name)
        for name in expected where !names.contains(name) {
            rows.append(Check(name: name, pass: false, detail: "결과 없음: 앞 단계가 멈춰 실행하지 못함"))
        }
        let repeated = Set(names.filter { n in names.filter { $0 == n }.count > 1 })
        for name in repeated.sorted() { rows.append(Check(name: "audit.duplicate." + name, pass: false, detail: "같은 검사 결과가 두 번 이상")) }
        rows.append(Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                          detail: LaneSelfTest.direct ? "앱을 활성화할 수 없어 직접 경로" : "합성 이벤트를 앱 이벤트 큐로 보냄"))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(rows) { try? d.write(to: folder.appendingPathComponent(file)) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
