#if DEBUG
import AppKit
import OnTheFrameEngine

/// SelfTest 4i(알림과 작업 대기열) — SP-PUBLIC-SELFTEST-ALIGN-17, 2026-11-23.
/// 소유자가 승인한 계약(DECISIONS "알림 중 작업 대기열"): 알림·시트·패널·모달이 떠 있는 동안 대기 중인 가져오기·내보내기는 시작하지 않고,
/// 닫으면 차례대로 이어서 실행한다. 유효한 작업을 버리거나 영영 멈춰 두지 않는다.
/// 이전 4i(2026-10-10)는 알림이 떠 있어도 작업이 계속 진행돼 알림 16개가 쌓인다고 봤다 — a153b99(2026-11-16)부터의 동작과 맞지 않았다.
/// 여기서는 같은 여덟 번의 "즉시 실패하는 내보내기 + 거부되는 가져오기"를 알림을 하나씩 닫으며 돌리고,
/// 처음 뜻(떠 있는 알림을 바꾸지 않고 차례로 보인다)과 새 계약(막힌 동안 시작하지 않음, 닫으면 재개)을 따로 본다.
/// SelfTest.run을 더 키우지 않게 이 파일에 둔다. 기다림은 모두 조건과 상한이 있는 대기다(임의로 쉬지 않는다).
extension SelfTest {
    static let queueExtraAlertTitle = "대기열 시험 알림"

    struct QueueRound {
        var titles: [String] = []
        /// 실패 알림이 떠 있는 동안 가져오기가 대기열에 남고 시작하지 않았는가
        var blocked = false
        /// 떠 있는 알림이 그대로였는가(다른 알림이 생겨도 바뀌지 않음)
        var notReplaced = false
        /// 알림을 볼 때마다 뒤에 쌓인 알림이 예상한 수였는가(보통 0, 일부러 하나 더 띄운 때만 1)
        var oneAtATime = false
        /// 닫은 뒤 대기한 가져오기가 실행돼 거부 알림이 떴는가
        var resumed = false
        /// 이 차례가 끝난 뒤 대기열·진행·알림이 모두 비었는가
        var idleAfter = false
    }

    private static func queueWait(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    /// 떠 있는 알림을 사용자가 누르는 것과 같은 경로로 닫고, 그 알림이 사라질 때까지(상한 5초) 기다린다.
    private static func queueDismiss(_ store: ProjectStore) async {
        guard let shown = store.alert else { return }
        store.alerts.pressButton(shown.revealURL == nil ? 0 : 1)
        _ = await queueWait(5) { store.alert?.id != shown.id }
    }

    /// 한 차례: 원본을 대상으로 한 내보내기(즉시 실패 알림) 뒤에 거부될 가져오기를 대기열에 넣는다.
    /// extraAlert면 실패 알림이 떠 있는 동안 알림을 하나 더 만들어, 떠 있는 알림이 바뀌지 않고 그 알림이 다음에 나오며 그동안에도 가져오기가 막혀 있는지 본다.
    private static func alertGatedRound(_ store: ProjectStore, src: URL, seekTo: Int, extraAlert: Bool) async -> QueueRound {
        var r = QueueRound()
        store.startExport(.fromSavePanel(src.appendingPathComponent("otf-B.mp4")))    // 원본 대상 → 즉시 실패 알림
        store.importFiles([src.appendingPathComponent("reject-prores.mov"), src.appendingPathComponent("reject-500fps.mp4")])
        store.seek(to: seekTo)                                                         // 같은 시점의 다른 화면 갱신
        let failed = await queueWait(10) { store.exportPhase == .idle && store.alert?.title == "내보내기 실패" }
        guard failed, let first = store.alert else { return r }
        r.titles.append(first.title)
        r.blocked = store.pendingOps.count == 1 && store.importProgress == nil && store.importing == 2
        r.oneAtATime = store.alerts.queuedCount == 0
        if extraAlert {
            store.presentAlert(ProjectStore.AlertInfo(title: queueExtraAlertTitle, message: "떠 있는 알림은 바뀌지 않고 이 알림은 그 다음에 나온다."))
            let stays = store.alert?.id == first.id && store.alerts.queuedCount == 1
            await queueDismiss(store)
            let second = store.alert
            let stillBlocked = second?.title == queueExtraAlertTitle && store.pendingOps.count == 1 && store.importProgress == nil
            r.notReplaced = stays && stillBlocked
            if let second { r.titles.append(second.title); await queueDismiss(store) }
        } else {
            r.notReplaced = store.alert?.id == first.id
            await queueDismiss(store)
        }
        let rejected = await queueWait(10) { store.alert?.title == ProjectStore.rejectTitle }
        r.resumed = rejected && store.pendingOps.isEmpty
        if let reject = store.alert {
            r.titles.append(reject.title)
            r.oneAtATime = r.oneAtATime && store.alerts.queuedCount == 0
            await queueDismiss(store)
        }
        r.idleAfter = await queueWait(10) { store.alert == nil && store.importing == 0 && store.importProgress == nil && store.exportPhase == .idle && store.pendingOps.isEmpty }
        return r
    }

    /// 4i 전체: 여덟 차례. 첫 차례만 알림을 하나 더 띄운다.
    static func alertGatedQueueChecks(_ store: ProjectStore, src: URL) async -> [Check] {
        let count = 8
        var rounds: [QueueRound] = []
        for k in 0..<count { rounds.append(await alertGatedRound(store, src: src, seekTo: k * 7, extraAlert: k == 0)) }
        let shown = rounds.flatMap(\.titles)
        var expected: [String] = []
        for k in 0..<count { expected += k == 0 ? ["내보내기 실패", queueExtraAlertTitle, ProjectStore.rejectTitle] : ["내보내기 실패", ProjectStore.rejectTitle] }
        let fails = shown.filter { $0 == "내보내기 실패" }.count, rejects = shown.filter { $0 == ProjectStore.rejectTitle }.count
        let kept = rounds.filter(\.notReplaced).count, single = rounds.filter(\.oneAtATime).count
        let blocked = rounds.filter(\.blocked).count, resumed = rounds.filter(\.resumed).count, idle = rounds.filter(\.idleAfter).count
        let quiet = store.alert == nil && store.pendingOps.isEmpty && store.importing == 0 && store.importProgress == nil && store.exportPhase == .idle
        return [
            Check(name: "alert.queuedNotReplaced", pass: fails == count && rejects == count && shown == expected && kept == count && single == count && store.alert == nil,
                  detail: "shown \(shown.count): fail \(fails) reject \(rejects) inOrder \(shown == expected) notReplaced \(kept)/\(count) oneAtATime \(single)/\(count)"),
            Check(name: "queue.blockedWhileAlertShown", pass: blocked == count, detail: "\(blocked)/\(count)"),
            Check(name: "queue.resumesAfterDismissal", pass: resumed == count && idle == count, detail: "resumed \(resumed)/\(count) idleAfter \(idle)/\(count)"),
            // 뒤 검사(4j 취소 반복, 4k 시간 기준이 다른 원본, 4l·4m 가져오기·차례 실행)는 빈 대기열에서 시작해야 뜻한 작업을 본다
            Check(name: "queue.idleBeforeDownstream", pass: quiet, detail: "pending \(store.pendingOps.count) importing \(store.importing) alert \(store.alert?.title ?? "-")"),
        ]
    }
}
#endif
