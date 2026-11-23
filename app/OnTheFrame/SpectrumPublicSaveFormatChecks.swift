#if DEBUG
import AppKit
import OnTheFrameEngine

/// SpectrumPublicSelfTest 10–14절: 저장 형식 안내(9개 검사)와 낡은 확인 닫기(1개). SP-PUBLIC-UX-IMPLEMENT-04(2026-11-23).
/// 실제 저장 경로(saveProject)를 쓰고 저장 패널의 결과만 주입한다. 쓰기 횟수는 커밋 직전 연결점(persistenceBeforeCommitForTest)이 올리는 c.writes로 센다.
/// 절마다 작은 함수 하나(컴파일 메모리 — SpectrumPublicSelfTest.swift 머리글). 차례: 표 → 새 8(취소 → 저장 → 다시 저장) → 8→11(취소 → 실패 → 저장 → 다시 저장·다른 이름 → 다시 열기) → 5→8 → 확인 닫기.
extension SpectrumPublicSelfTest {
    /// 10. 판정(순수 함수): 8·11로 처음 올라갈 때만, 같은 형식·내려가는 저장·그 밖의 형식은 안내 없음, 8 안내가 11 안내를 막지 않음
    static func checkSaveFormatTriggerTable(_ c: Context) {
        let table: [(Int?, Int?, Int?)] = [
            (8, nil, 8), (11, nil, 11), (8, 5, 8), (8, 7, 8), (11, 8, 11), (11, 10, 11), (11, 9, 11), (11, 5, 11),
            (8, 8, nil), (11, 11, nil), (8, 11, nil), (8, 9, nil), (5, nil, nil), (6, 5, nil), (7, nil, nil), (9, nil, nil), (nil, nil, nil), (nil, 8, nil),
        ]
        var wrong: [String] = []
        for row in table where ProjectStore.formatUpgradeNeedingWarning(target: row.0, last: row.1) != row.2 {
            wrong.append("\(row.0.map(String.init) ?? "nil")/\(row.1.map(String.init) ?? "nil")")
        }
        c.check("saveFormat.triggerTable", wrong.isEmpty, wrong.joined(separator: " "))
    }

    /// 11a. 새 프로젝트의 첫 저장이 형식 8(자른 소리의 계보, 스펙트럼 없음): 안내가 뜨고, "취소"면 아무것도 쓰지 않는다(저장 패널까지 가지 않음)
    static func checkSaveFormatNew8Cancel(_ c: Context) async -> Bool {
        let s = c.s, fm = FileManager.default
        guard let fresh = await prepare(s, media: c.ta) else { return c.stop("saveFormat.setup", s.statusMessage ?? "") }
        let fileA = c.out.appendingPathComponent("format-new.ontheframe")
        c.fileA = fileA
        let newState = s.lastPersistedFormat == nil && s.projectURL == nil && s.saveTargetFormat() == 8 && s.isDirty && fresh.spectra.isEmpty
        s.savePanelResultForTest = fileA
        s.saveProject()
        let warned = await c.waitAlert()
        let title = s.alert?.title ?? "", message = s.alert?.message ?? ""
        let nothingYet = !fm.fileExists(atPath: fileA.path) && c.writes.n == 0
        await c.press(1)   // 취소
        let notWritten = !fm.fileExists(atPath: fileA.path) && c.writes.n == 0
        let stateKept = s.projectURL == nil && s.isDirty && s.lastPersistedFormat == nil && s.timeline == fresh
        let panelNotReached = s.savePanelResultForTest == fileA
        let cancelled = notWritten && stateKept && panelNotReached
        let alertOK = warned && title == ProjectStore.formatWarningTitle && message.contains("형식 8")
        c.check("saveFormat.new8WarnsAndCancelWritesNothing", newState && alertOK && nothingYet && cancelled,
                "state \(newState) warned \(warned) '\(title)' cancelled \(cancelled) writes \(c.writes.n)")
        return true
    }

    /// 11b. 취소는 안내를 없애지 않는다: 다시 묻고, "저장"이면 한 번만 쓴다
    static func checkSaveFormatNew8Save(_ c: Context) async {
        let s = c.s, fileA: URL = c.fileA
        s.saveProject()
        let warned = await c.waitAlert()
        await c.press(0)
        _ = await LaneSelfTest.waitUntil(5) { !s.isDirty }
        await LaneSelfTest.settle()
        let written = c.writes.n == 1 && c.fileVersion(fileA) == 8 && s.lastPersistedFormat == 8
        let stateSaved = !s.isDirty && s.projectURL == fileA.standardizedFileURL && !s.alerts.isShowing
        c.check("saveFormat.new8SaveWritesOnce", warned && written && stateSaved,
                "warned \(warned) writes \(c.writes.n) version \(c.fileVersion(fileA).map(String.init) ?? "-")")
    }

    /// 11c. 같은 형식으로 다시 저장: 안내 없이 바로(기존 동작)
    static func checkSaveFormatSame8(_ c: Context) {
        let s = c.s, fileA: URL = c.fileA
        _ = s.renameLane(Lane.audioID, to: "다시 저장")
        s.saveProject()
        let saved = !s.alerts.isShowing && c.writes.n == 2 && !s.isDirty
        c.check("saveFormat.same8NoRepeat", saved && s.lastPersistedFormat == 8 && c.fileVersion(fileA) == 8, "writes \(c.writes.n) alert \(s.alert?.title ?? "-")")
    }

    /// 12a. 8 → 11(스펙트럼 항목 추가): 앞의 8 안내가 막지 않는다. 안내 중 겹친 저장은 하지 않고, "취소"면 이전 파일(형식 8) 그대로
    static func checkSaveFormatUpgrade11Cancel(_ c: Context) async -> Bool {
        let s = c.s, fileA: URL = c.fileA
        guard let anyAudio = s.timeline.audioClips.first else { return c.stop("saveFormat.setup11") }
        s.addSpectrum(fromAudioClip: anyAudio.id, session: s.projectSession)
        await LaneSelfTest.settle()
        let bytes8 = c.bytes(fileA)
        let edited11 = s.timeline
        s.saveProject()
        let warned = await c.waitAlert()
        let message = s.alert?.message ?? ""
        var nested: Bool?
        s.saveProject { nested = $0 }   // 안내가 떠 있는 동안의 저장 요청(완료 처리기가 있는 내부 경로)도 쓰지 않고 실패로 끝남
        let nestedRefused = nested == false && c.writes.n == 2
        await c.press(1)
        let fileKept = c.writes.n == 2 && c.bytes(fileA) == bytes8 && c.fileVersion(fileA) == 8
        let stateKept = s.isDirty && s.lastPersistedFormat == 8 && s.timeline == edited11 && s.projectURL == fileA.standardizedFileURL
        let cancelled = fileKept && stateKept
        let alertOK = s.saveTargetFormat() == 11 && warned && message.contains("형식 11")
        c.check("saveFormat.upgrade8to11WarnsAndCancelKeepsFile", alertOK && nestedRefused && cancelled,
                "warned \(warned) nested \(nested.map { "\($0)" } ?? "nil") cancelled \(cancelled) writes \(c.writes.n)")
        return true
    }

    /// 12b. 쓰기 실패(교체 전): 안내 → "저장" → 실패 알림. 이전 파일·저장 상태·기록된 형식 그대로이고, 다음 저장은 다시 안내한 뒤 형식 11로 쓴다
    static func checkSaveFormatFailureThenSave11(_ c: Context) async {
        let s = c.s, fileA: URL = c.fileA
        let bytes8 = c.bytes(fileA)
        let edited11 = s.timeline
        s.saveFailureForTest = true
        s.saveProject()
        _ = await c.waitAlert()
        await c.press(0)
        _ = await LaneSelfTest.waitUntil(5) { s.alerts.isShowing }
        let failTitle = s.alert?.title ?? ""
        await dismiss()
        await LaneSelfTest.settle()
        let fileKept = failTitle == "프로젝트를 저장하지 못했습니다" && c.bytes(fileA) == bytes8
        let failedSafe = fileKept && s.isDirty && s.lastPersistedFormat == 8 && s.timeline == edited11
        let writesAfterFailure = c.writes.n
        s.saveProject()
        let warnedAgain = await c.waitAlert()
        await c.press(0)
        _ = await LaneSelfTest.waitUntil(5) { !s.isDirty }
        await LaneSelfTest.settle()
        let saved11 = c.writes.n == writesAfterFailure + 1 && c.fileVersion(fileA) == 11 && s.lastPersistedFormat == 11 && !s.isDirty
        c.check("saveFormat.failureKeepsFormatThenSaves11", failedSafe && warnedAgain && saved11,
                "fail '\(failTitle)' safe \(failedSafe) warnedAgain \(warnedAgain) version \(c.fileVersion(fileA).map(String.init) ?? "-")")
    }

    /// 12c. 같은 형식 11로 다시 저장, 다른 이름으로 저장: 안내 없음(이 프로젝트는 이미 11로 저장됨)
    static func checkSaveFormatSame11AndSaveAs(_ c: Context) {
        let s = c.s, fileA: URL = c.fileA
        _ = s.renameLane(Lane.audioID, to: "11 다시")
        let writes11 = c.writes.n
        s.saveProject()
        let same11 = !s.alerts.isShowing && c.writes.n == writes11 + 1 && !s.isDirty
        let fileB = c.out.appendingPathComponent("format-saveas.ontheframe")
        s.savePanelResultForTest = fileB
        s.saveProject(saveAs: true)
        let newFile = !s.alerts.isShowing && c.fileVersion(fileB) == 11 && s.projectURL == fileB.standardizedFileURL
        let saveAs11 = newFile && s.lastPersistedFormat == 11 && c.fileVersion(fileA) == 11
        c.check("saveFormat.same11AndSaveAsNoRepeat", same11 && saveAs11, "same \(same11) saveAs \(saveAs11)")
    }

    /// 12d. 다시 열기: 기준은 연 파일의 형식. 새 프로젝트로 바꾸면 기준이 없어진다
    static func checkSaveFormatReopen(_ c: Context) async {
        let s = c.s
        let fileB = c.out.appendingPathComponent("format-saveas.ontheframe")
        let saved11 = s.timeline
        s.resetProject()
        let resetClears = s.lastPersistedFormat == nil
        let reopened = await s.openProject(at: fileB)
        await dismiss()
        await LaneSelfTest.settle()
        let reopenedState = reopened && s.lastPersistedFormat == 11 && s.timeline == saved11
        _ = s.renameLane(Lane.audioID, to: "다시 연 뒤")
        let writesReopen = c.writes.n
        s.saveProject()
        let savedQuietly = !s.alerts.isShowing && c.writes.n == writesReopen + 1 && !s.isDirty
        c.check("saveFormat.reopenTracksFileFormat", resetClears && reopenedState && savedQuietly,
                "reset \(resetClears) reopened \(reopenedState) writes \(c.writes.n - writesReopen)")
    }

    /// 13. 기존 형식 5 프로젝트 → 8: 자르지 않은 프로젝트를 형식 5로 쓰고 다시 연 뒤 소리를 잘라 계보가 생기면 안내. 취소면 형식 5 파일 그대로
    static func checkSaveFormatExisting5to8(_ c: Context) async -> Bool {
        let s = c.s
        let file5 = c.out.appendingPathComponent("format-5.ontheframe")
        guard await prepare(s, media: c.ta, build: plainTimeline) != nil, s.writeProject(to: file5) else {
            return c.stop("saveFormat.setup5", s.statusMessage ?? "")
        }
        let v5 = c.fileVersion(file5)
        s.resetProject()
        let opened = await s.openProject(at: file5)
        await dismiss()
        await LaneSelfTest.settle()
        let bytes5 = c.bytes(file5)
        let openedState = opened && v5 == 5 && s.lastPersistedFormat == 5 && s.saveTargetFormat() == 5
        if let clip = s.timeline.clips.first { s.commit({ try $0.splitting(clip: clip.id, atFrame: clip.start + 30) }, focus: nil) }
        let split5 = s.timeline
        let hasLineage = split5.audioClips.contains { $0.origin != nil }
        let writes5 = c.writes.n
        s.saveProject()
        let warned = await c.waitAlert()
        let message = s.alert?.message ?? ""
        await c.press(1)
        let fileKept = c.writes.n == writes5 && c.bytes(file5) == bytes5 && c.fileVersion(file5) == 5
        let kept5 = fileKept && s.isDirty && s.lastPersistedFormat == 5 && s.timeline == split5
        s.saveProject()
        _ = await c.waitAlert()
        await c.press(0)
        _ = await LaneSelfTest.waitUntil(5) { !s.isDirty }
        await LaneSelfTest.settle()
        let saved8 = c.writes.n == writes5 + 1 && c.fileVersion(file5) == 8 && s.lastPersistedFormat == 8 && !s.isDirty
        let alertOK = warned && message.contains("형식 8")
        c.check("saveFormat.existing5to8", openedState && hasLineage && alertOK && kept5 && saved8,
                "opened \(openedState) warned \(warned) kept \(kept5) version \(c.fileVersion(file5).map(String.init) ?? "-")")
        return true
    }

    /// 14. 낡은 확인 닫기(이미지 재연결이 쓰는 AlertPresenter.cancelCurrent — Debug·Release 공통): 취소 단추로만 닫고, 취소 단추가 없는 알림은 닫지 않는다(승인하지 않음)
    static func checkAlertCancelCurrent(_ c: Context) async {
        let s = c.s
        let pressed = Counter(), pressedPlain = Counter()
        pressed.n = -1; pressedPlain.n = -1   // -1 = 아직 아무 단추도 눌리지 않음
        s.presentAlert(ProjectStore.AlertInfo(title: "시험 확인", message: "취소 단추가 있는 확인", buttons: ["재연결", "취소"], cancelIndex: 1, onButton: { pressed.n = $0 }))
        _ = await c.waitAlert()
        s.alerts.cancelCurrent()
        _ = await LaneSelfTest.waitUntil(5) { !s.alerts.isShowing }
        let cancelledAsCancel = pressed.n == 1
        s.presentAlert(ProjectStore.AlertInfo(title: "시험 알림", message: "취소 단추가 없는 알림", onButton: { pressedPlain.n = $0 }))
        _ = await c.waitAlert()
        s.alerts.cancelCurrent()
        await LaneSelfTest.settle()
        let plainUntouched = s.alerts.isShowing && pressedPlain.n == -1
        await dismiss()
        c.check("alerts.cancelCurrentNeverApproves", cancelledAsCancel && plainUntouched, "pressed \(pressed.n) plainStillShowing \(plainUntouched)")
    }
}
#endif
