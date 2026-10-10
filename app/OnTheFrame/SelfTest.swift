#if DEBUG
import AppKit
import CryptoKit
import OnTheFrameEngine
import os

/// 샌드박스 자체 검사(Debug 빌드 전용, 일반 화면에 나타나지 않음).
/// `open -n -W -a OnTheFrame.app <폴더> --args -OTFSelfTest`로 실행하면 Launch Services가 그 폴더 접근만 허락한다.
/// 실제 앱 상태(ProjectStore)로 가져오기·편집·내보내기를 수행하고 결과를 <폴더>/selftest-result.json,
/// 내보낸 타임라인을 <폴더>/selftest-manifest.json에 쓴 뒤 종료한다. 프레임 판정은 앱 밖의 `otf-dev verify`가 한다.
@MainActor
enum SelfTest {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }
    struct ManifestClip: Codable { let file: String; let start: Int; let sourceIn: Int; let length: Int }
    struct ManifestExport: Codable { let exportFile: String; let clips: [ManifestClip]; let durationFrames: Int }
    struct Manifest: Codable { let fps: Int32; let exportFile: String; let clips: [ManifestClip]; let durationFrames: Int; var timedExport: ManifestExport? }
    struct Result: Codable { let sandboxContainer: Bool; let checks: [Check]; let tempLocations: [String] }

    final class Recorder: @unchecked Sendable {   // 안전성: 잠금으로만 접근
        private let lock = OSAllocatedUnfairLock(initialState: [URL]())
        func add(_ u: URL) { lock.withLock { $0.append(u) } }
        var all: [URL] { lock.withLock { $0 } }
    }

    static func run(folder: URL) async {
        var checks: [Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") { checks.append(Check(name: name, pass: pass, detail: detail)) }
        let store = ProjectStore.shared
        let fm = FileManager.default
        let src = folder.appendingPathComponent("sources"), out = folder.appendingPathComponent("out")
        let temps = Recorder()

        // 1. 샌드박스가 실제로 막는지: 허락받은 폴더 밖 읽기·쓰기
        let inSandbox = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        check("sandbox.active", inSandbox, "APP_SANDBOX_CONTAINER_ID present=\(inSandbox)")
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside-probe.txt")
        check("sandbox.outsideReadDenied", (try? Data(contentsOf: outside)) == nil)
        let outsideWrite = folder.deletingLastPathComponent().appendingPathComponent("outside-write-\(UUID().uuidString).txt")
        let wrote = (try? Data("x".utf8).write(to: outsideWrite)) != nil
        if wrote { try? fm.removeItem(at: outsideWrite) }
        check("sandbox.outsideWriteDenied", !wrote)
        do { try fm.createDirectory(at: out, withIntermediateDirectories: false); check("sandbox.grantedFolderWritable", true) }
        catch { check("sandbox.grantedFolderWritable", false, error.localizedDescription) }

        let names = ["otf-A.mp4", "otf-B.mp4", "otf-rot90.mp4", "reject-prores.mov", "reject-500fps.mp4", "reject-audio-only.m4a", "reject-2video.mov",
                     "otf-hevc.mp4", "reject-uhd.mp4", "otf-N2997.mp4", "otf-P25.mp4", "otf-VFR.mp4"]
        let hashesBefore = Dictionary(uniqueKeysWithValues: names.map { ($0, sha(src.appendingPathComponent($0))) })
        check("fixtures.present", hashesBefore.values.allSatisfy { $0 != nil })

        // 2. 가져오기(실제 앱 경로). 거부 이유를 직접 판정으로도 분류한다.
        store.importFiles(names.map { src.appendingPathComponent($0) })
        // A-011: 묶음 진행 표시(현재 파일, 끝난 수/전체 수)를 관찰한다. 묶음이 끝나기 전에는 목록에 들어가지 않는다(묶음 반영).
        var seenTotal = 0, seenCompleted: [Int] = [], seenNames = Set<String>(), addedEarly = false
        let importDeadline = Date().addingTimeInterval(60)
        while store.importing > 0 || store.importProgress != nil, Date() < importDeadline {
            if let ip = store.importProgress {
                seenTotal = max(seenTotal, ip.total)
                if seenCompleted.last != ip.completed { seenCompleted.append(ip.completed) }
                if let n = ip.currentName { seenNames.insert(n) }
                if !store.assets.isEmpty { addedEarly = true }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        check("import.batchProgress", seenTotal == names.count && zip(seenCompleted, seenCompleted.dropFirst()).allSatisfy { $0 < $1 }
              && (seenCompleted.last ?? 0) <= names.count && seenNames.isSubset(of: Set(names)) && !seenNames.isEmpty && !addedEarly && store.importProgress == nil,
              "total \(seenTotal) completed \(seenCompleted) names \(seenNames.count) addedEarly \(addedEarly)")
        let imported = Set(store.assets.map(\.name))
        check("import.accepted", imported == ["otf-A.mp4", "otf-B.mp4", "otf-hevc.mp4", "otf-rot90.mp4", "otf-N2997.mp4", "otf-P25.mp4", "otf-VFR.mp4"],
              imported.sorted().joined(separator: ","))
        // A-010: 30 fps가 아닌 원본의 표시 시각 분석(손으로 계산한 타임라인 프레임 수: 4.004 s → 120, 4 s → 120, 2405/600 s → 120)
        let timedInfo = ["otf-N2997.mp4": ("30000/1001 fps CFR", 120), "otf-P25.mp4": ("25/1 fps CFR", 120), "otf-VFR.mp4": ("VFR", 120)]
        for (n, (detail, frames)) in timedInfo.sorted(by: { $0.key < $1.key }) {
            let m = store.assets.first { $0.name == n }
            check("probe.timing.\(n)", m.map { $0.timing.detail.hasPrefix(detail) && $0.frameCount == frames } ?? false, m.map { "\($0.timing.detail) frames \($0.frameCount)" } ?? "missing")
        }
        _ = await waitUntil(5) { store.alert != nil }   // 묶음 처리가 끝난 뒤 알림 하나
        let msg = store.alert?.message ?? ""
        check("import.rejectionsReported", ["reject-prores.mov", "reject-500fps.mp4", "reject-audio-only.m4a", "reject-2video.mov", "reject-uhd.mp4"].allSatisfy { msg.contains($0) })
        await dismissAlert()
        for (n, want) in [("reject-prores.mov", "unsupportedCodec"), ("reject-500fps.mp4", "frameRate"), ("reject-audio-only.m4a", "noVideo"), ("reject-2video.mov", "multipleVideoTracks"), ("reject-uhd.mp4", "dimensions")] {
            do { _ = try await MediaProbe.inspect(src.appendingPathComponent(n)); check("probe.\(n)", false, "accepted") }
            catch let e as ProbeError { check("probe.\(n)", e.kind == want, "\(e.kind): \(e)") }
            catch { check("probe.\(n)", false, "\(error)") }
        }
        if let rot = store.assets.first(where: { $0.name == "otf-rot90.mp4" }) {
            check("probe.rotation", rot.displaySize == CGSize(width: 360, height: 640) && rot.naturalSize == CGSize(width: 640, height: 360),
                  "natural \(rot.naturalSize) display \(rot.displaySize)")
        }
        guard let a = store.assets.first(where: { $0.name == "otf-A.mp4" }), let b = store.assets.first(where: { $0.name == "otf-B.mp4" }) else {
            return finish(folder, inSandbox, checks, temps, manifest: nil)
        }

        // 3. 편집(실제 앱 상태 경로)
        store.addToTimeline(a.id); store.addToTimeline(b.id)
        check("edit.add", store.durationFrames == a.frameCount + b.frameCount, "\(store.durationFrames)")
        store.seek(to: store.durationFrames)
        store.selection = store.timeline.clips[0].id
        store.seek(to: 50); store.splitAtPlayhead()
        check("edit.split", store.timeline.clips.map(\.length) == [50, a.frameCount - 50, b.frameCount])
        let beforeBoundary = store.timeline, depth0 = store.history.undoDepth
        store.seek(to: 50); store.splitAtPlayhead()   // 선택된 오른쪽 조각의 시작 = 경계
        check("edit.splitAtBoundaryRejected", store.timeline == beforeBoundary && store.history.undoDepth == depth0, store.statusMessage ?? "")
        let left = store.timeline.clips[0].id
        store.beginGesture(select: left); store.updateTrim(left, edge: .end, delta: -4); store.updateTrim(left, edge: .end, delta: -10); store.commitGesture()
        check("edit.trimDragOneStep", store.timeline.clips[0].length == 40 && store.history.undoDepth == depth0 + 1)
        let beforeCancel = store.timeline
        store.beginGesture(select: left); store.updateTrim(left, edge: .end, delta: -20); store.cancelGesture()
        check("edit.dragCancelRestores", store.timeline == beforeCancel && store.history.undoDepth == depth0 + 1)
        let bClip = store.timeline.clips[2].id
        store.beginGesture(select: bClip); store.updateMove(bClip, toIndex: 1); store.updateMove(bClip, toIndex: 0); store.commitGesture()
        check("edit.moveInsert", store.timeline.clips.first?.id == bClip)
        store.seek(to: store.durationFrames)
        store.selection = left; store.deleteSelection(ripple: true)
        check("edit.rippleDelete", store.timeline.clips.count == 2 && store.durationFrames == b.frameCount + a.frameCount - 50)
        check("edit.playheadClamped", store.playhead == store.durationFrames, "\(store.playhead)/\(store.durationFrames)")
        let afterDelete = store.timeline
        store.undo(); check("edit.undo", store.timeline.clips.count == 3)
        store.redo(); check("edit.redo", store.timeline == afterDelete)
        store.beginGesture(select: bClip); store.updateTrim(bClip, edge: .start, delta: 15); store.commitGesture()
        check("edit.trimStart", store.timeline.clips[0].sourceIn == 15 && store.timeline.clips[0].length == b.frameCount - 15)
        // 연속 편집 뒤 마지막 스냅샷의 프리뷰만 적용되는지(오래된 재구성 거부)
        for _ in 0..<3 { store.undo(); store.redo() }
        let ok = await waitUntil(20) { store.currentPlan?.durationFrames == store.durationFrames && store.player.currentItem != nil }
        check("preview.latestSnapshotApplied", ok, "plan \(store.currentPlan?.durationFrames ?? -1) timeline \(store.durationFrames)")
        store.seek(to: 10); store.play()
        let advanced = await waitUntil(5) { store.playhead > 20 }
        store.splitAtPlayhead(); store.undo()
        check("preview.playsAndEditPauses", advanced && !store.isPlaying)

        // 일반 삭제(D-020): 끝에 B를 붙였다 지우면 끝 빈틈이 남고 길이·다른 클립 위치는 그대로
        let durBefore = store.durationFrames, startsBefore = store.timeline.starts
        store.addToTimeline(b.id)
        let tail = store.timeline.clips.last!.id
        store.selection = tail; store.deleteSelection()
        check("edit.liftLeavesTrailingGap", store.timeline.starts == startsBefore && store.durationFrames == durBefore + b.frameCount
              && store.timeline.gaps == [durBefore..<(durBefore + b.frameCount)], "\(store.timeline.gaps)")
        let gapOK = await waitUntil(20) { store.currentPlan?.durationFrames == store.durationFrames }
        check("preview.gapTimelinePlanned", gapOK)

        let snapshot = store.timeline
        let mediaName = Dictionary(uniqueKeysWithValues: store.assets.map { ($0.id, $0.name) })
        var manifest = Manifest(fps: store.settings.fps, exportFile: "out/export.mp4",
                                clips: snapshot.clips.map { ManifestClip(file: mediaName[$0.mediaID] ?? "?", start: $0.start, sourceIn: $0.sourceIn, length: $0.length) },
                                durationFrames: snapshot.durationFrames)

        // 4. 내보내기
        store.exportOptions = ExportService.Options(onTempDirectory: { temps.add($0) })
        // 4a. 새 대상 + 내보내는 동안 편집(결과는 시작 시점 스냅샷이어야 함)
        let e1 = out.appendingPathComponent("export.mp4")
        store.startExport(.fromSavePanel(e1))
        let resetOK = store.exportEstimator.samples.count == 1 && store.lastExportElapsed == nil && store.exportEstimator.stage == .preparing
        var remainLabels: [String] = []
        func noteRemaining() {
            let l = ClockText.remaining(store.exportEstimator.remaining(at: store.monoSeconds()))
            if remainLabels.last != l { remainLabels.append(l) }
        }
        noteRemaining()
        _ = await waitUntil(5) { if case .running(let p) = store.exportPhase { return p > 0 } else { return false } }
        store.selection = snapshot.clips[0].id; store.deleteSelection()
        let end4a = Date().addingTimeInterval(120)
        while store.exportPhase != .idle, Date() < end4a { noteRemaining(); try? await Task.sleep(nanoseconds: 20_000_000) }
        // 경과 시간: 시작 때 초기화, 단계 준비 → 인코딩 → 마무리, 성공 알림에 걸린 시간, 끝난 뒤 멈춤
        let el1 = store.lastExportElapsed ?? -1
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("exportTime.success", resetOK && el1 > 0 && store.lastExportElapsed == el1 && store.exportStageLog == [.preparing, .encoding, .finalizing]
              && (store.alert?.message ?? "").contains("걸린 시간 \(ClockText.format(el1))") && remainLabels.first == "남은 시간 계산 중…",
              String(format: "elapsed %.2f stages %@ labels %@", el1, "\(store.exportStageLog)", remainLabels.joined(separator: " | ")))
        check("export.new", store.alert?.title == "내보내기 완료" && fm.fileExists(atPath: e1.path), store.alert?.message ?? "")
        func progressOK(_ v: [Double]) -> Bool { v.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } && zip(v, v.dropFirst()).allSatisfy { $0 <= $1 } }
        let pNew = store.exportProgressLog
        check("progress.successMonotonicEndsAtOne", progressOK(pNew) && pNew.last == 1 && pNew.filter { $0 == 1 }.count == 1, "\(pNew.count) values, last \(pNew.last ?? -1)")
        await dismissAlert(); store.undo()
        check("export.timelineRestoredAfterEditDuringExport", store.timeline == snapshot)

        // 4b. 취소
        let e2 = out.appendingPathComponent("cancel.mp4")
        store.startExport(.fromSavePanel(e2))
        _ = await waitUntil(10) { if case .running(let p) = store.exportPhase { return p > 0.1 } else { return false } }
        store.cancelExport()
        _ = await waitUntil(30) { store.exportPhase == .idle }
        check("export.cancel", !fm.fileExists(atPath: e2.path) && (store.statusMessage ?? "").contains("취소"), store.statusMessage ?? "")
        check("exportTime.cancelNotCompleted", !store.exportStageLog.contains(.finalizing) && (store.statusMessage ?? "").contains("경과")
              && (store.lastExportElapsed ?? 0) > 0 && store.alert?.title != "내보내기 완료", "\(store.exportStageLog) \(store.statusMessage ?? "")")
        check("progress.cancelNeverOne", progressOK(store.exportProgressLog) && (store.exportProgressLog.max() ?? 0) < 1, "max \(store.exportProgressLog.max() ?? -1)")

        // 4c. 실패(주입)
        store.exportOptions.failAfterFraction = 0.3
        let e3 = out.appendingPathComponent("fail.mp4")
        store.startExport(.fromSavePanel(e3))
        _ = await waitUntil(60) { store.exportPhase == .idle }
        check("export.failureReported", store.alert?.title == "내보내기 실패" && !fm.fileExists(atPath: e3.path), store.alert?.message ?? "")
        check("exportTime.failureNotCompleted", !store.exportStageLog.contains(.finalizing) && (store.alert?.message ?? "").contains("경과"), "\(store.exportStageLog)")
        check("progress.failureNeverOne", progressOK(store.exportProgressLog) && (store.exportProgressLog.max() ?? 0) < 1, "max \(store.exportProgressLog.max() ?? -1)")
        await dismissAlert(); store.exportOptions.failAfterFraction = nil

        // 4d. 확인한 대치
        let e4 = out.appendingPathComponent("existing.mp4")
        try? Data("placeholder".utf8).write(to: e4)
        store.startExport(.fromSavePanel(e4))
        _ = await waitUntil(120) { store.exportPhase == .idle }
        let replacedOK = (try? await MediaProbe.inspect(e4))?.frameCount == snapshot.durationFrames
        check("export.confirmedReplace", store.alert?.title == "내보내기 완료" && replacedOK, store.alert?.message ?? "")
        await dismissAlert()

        // 4e. 대치 확인 뒤 대상이 바뀜 → 그대로 둠
        let e5 = out.appendingPathComponent("changed.mp4")
        try? Data("v1".utf8).write(to: e5)
        let d5 = ExportDestination.fromSavePanel(e5)
        store.exportOptions.beforePromotion = { try? Data("v2-changed-by-someone".utf8).write(to: e5) }
        store.startExport(d5)
        _ = await waitUntil(120) { store.exportPhase == .idle }
        check("export.changedAfterConfirmationPreserved", (try? String(contentsOf: e5, encoding: .utf8)) == "v2-changed-by-someone" && (store.alert?.message ?? "").contains("바뀌었습니다"), store.alert?.message ?? "")
        await dismissAlert()

        // 4f. 새 대상이 내보내는 동안 생김 → 덮어쓰지 않음
        let e6 = out.appendingPathComponent("appeared.mp4")
        store.exportOptions.beforePromotion = { try? Data("created-meanwhile".utf8).write(to: e6) }
        store.startExport(.fromSavePanel(e6))
        _ = await waitUntil(120) { store.exportPhase == .idle }
        check("progress.promotionFailureNeverOne", (store.exportProgressLog.max() ?? 0) < 1 && store.alert?.title == "내보내기 실패", "max \(store.exportProgressLog.max() ?? -1)")
        check("export.appearedPreserved", (try? String(contentsOf: e6, encoding: .utf8)) == "created-meanwhile" && (store.alert?.message ?? "").contains("생겼습니다"), store.alert?.message ?? "")
        await dismissAlert(); store.exportOptions.beforePromotion = nil

        // 4g. 원본을 대상으로(대치 확인이 있어도 거부) — 같은 경로, 하드 링크(같은 inode)
        let link = out.appendingPathComponent("a-link.mp4")
        let linked = Darwin.link(src.appendingPathComponent("otf-A.mp4").path, link.path) == 0
        for (n, u) in [("path", src.appendingPathComponent("otf-A.mp4")), ("hardlink", link)] where n == "path" || linked {
            store.startExport(.fromSavePanel(u))
            _ = await waitUntil(30) { store.exportPhase == .idle }
            check("export.sourceRejected.\(n)", (store.alert?.message ?? "").contains("원본"), store.alert?.message ?? "")
            await dismissAlert()
        }
        // 4h. 확인하지 않은 기존 파일
        store.startExport(ExportDestination(url: e5, confirmedReplace: false, identityAtConfirmation: nil))
        _ = await waitUntil(30) { store.exportPhase == .idle }
        check("export.unconfirmedRejected", (store.alert?.message ?? "").contains("확인하지 않아"), store.alert?.message ?? "")
        await dismissAlert()

        // 4i. 알림 경로 반복(2026-10-10 충돌 경로): 즉시 실패하는 내보내기·거부 가져오기 묶음을 겹쳐 반복하고,
        //     알림이 떠 있는 동안 생긴 알림은 바꾸지 않고 대기열에 쌓였다가 닫을 때마다 하나씩 나오는지 본다.
        var shown: [String] = []
        for k in 0..<8 {
            store.startExport(.fromSavePanel(src.appendingPathComponent("otf-B.mp4")))    // 원본 대상 → 즉시 실패 알림
            store.importFiles([src.appendingPathComponent("reject-prores.mov"), src.appendingPathComponent("reject-500fps.mp4")])
            store.seek(to: k * 7)                                                          // 같은 시점의 다른 화면 갱신
            _ = await waitUntil(10) { store.exportPhase == .idle && store.importing == 0 }
        }
        _ = await waitUntil(10) { store.alert != nil }
        _ = await waitUntil(5) { store.importing == 0 }
        var guardCount = 0
        while let a = store.alert, guardCount < 40 {
            shown.append(a.title); guardCount += 1
            await dismissAlert()
        }
        let fails = shown.filter { $0 == "내보내기 실패" }.count, rejects = shown.filter { $0 == ProjectStore.rejectTitle }.count
        check("alert.queuedNotReplaced", fails == 8 && rejects == 8 && store.alert == nil, "shown \(shown.count): fail \(fails) reject \(rejects)")
        // 4j. 취소 반복
        var cancelOK = 0
        for k in 0..<4 {
            let u = out.appendingPathComponent("cancel-\(k).mp4")
            store.startExport(.fromSavePanel(u))
            _ = await waitUntil(10) { if case .running(let p) = store.exportPhase { return p > 0.05 } else { return false } }
            store.cancelExport()
            _ = await waitUntil(30) { store.exportPhase == .idle }
            if !fm.fileExists(atPath: u.path) && store.alert == nil { cancelOK += 1 }
        }
        check("export.cancelRepeated", cancelOK == 4, "\(cancelOK)/4")

        // 4k. A-010: 30 fps가 아닌 원본(29.97·가변)을 같은 앱 경로로 붙이고 자르기·앞 트림 뒤 내보낸다. 판정은 otf-dev verify(독립 기대값).
        if let nt = store.assets.first(where: { $0.name == "otf-N2997.mp4" }), let vf = store.assets.first(where: { $0.name == "otf-VFR.mp4" }) {
            store.addToTimeline(nt.id); store.addToTimeline(vf.id)
            let nClip = store.timeline.clips[store.timeline.clips.count - 2]
            store.selection = nClip.id; store.seek(to: nClip.start + 45); store.splitAtPlayhead()
            let right = store.timeline.clips[store.timeline.clips.count - 2].id
            store.beginGesture(select: right); store.updateTrim(right, edge: .start, delta: 7); store.commitGesture()
            let tl = store.timeline
            let e7 = out.appendingPathComponent("timed.mp4")
            store.startExport(.fromSavePanel(e7))
            _ = await waitUntil(180) { store.exportPhase == .idle }
            check("export.timedSources", store.alert?.title == "내보내기 완료" && fm.fileExists(atPath: e7.path), store.alert?.message ?? "")
            await dismissAlert()
            manifest.timedExport = ManifestExport(exportFile: "out/timed.mp4",
                                                  clips: tl.clips.map { ManifestClip(file: mediaName[$0.mediaID] ?? "?", start: $0.start, sourceIn: $0.sourceIn, length: $0.length) },
                                                  durationFrames: tl.durationFrames)
        } else { check("export.timedSources", false, "timed fixtures not imported") }

        // 4l. A-011 가져오기 취소: 첫 파일 검사가 끝난 뒤 취소하면 이번 묶음은 아무것도 추가하지 않고, 늦은 결과도 버린다
        let before = store.assets.map(\.id)
        store.importFiles(["otf-TA.mp4", "otf-TB.mp4", "otf-F23976.mp4"].map { src.appendingPathComponent($0) })
        _ = await waitUntil(30) { (store.importProgress?.completed ?? 0) >= 1 }
        let completedAtCancel = store.importProgress?.completed ?? -1
        store.cancelImport()
        let cancellingShown = store.importProgress?.cancelling == true
        _ = await waitUntil(30) { store.importProgress == nil }
        try? await Task.sleep(nanoseconds: 1_000_000_000)   // 늦게 끝난 검사가 있어도 추가되지 않아야 한다
        check("import.cancel", completedAtCancel >= 1 && cancellingShown && store.assets.map(\.id) == before && store.importing == 0
              && (store.statusMessage ?? "").contains("가져오기를 취소"), "completed at cancel \(completedAtCancel), \(store.statusMessage ?? "")")
        // 4m. 차례 실행: 내보내는 동안 고른 가져오기는 대기열에 들어가고 카드는 하나다. 대기 중 가져오기 취소, 내보내기 취소.
        let e8 = out.appendingPathComponent("queued.mp4")
        store.startExport(.fromSavePanel(e8))
        store.importFiles([src.appendingPathComponent("otf-TA.mp4")])
        let queued = store.pendingOps.count == 1 && store.importProgress == nil && store.exportPhase != .idle && !store.canExport && store.importing == 1
        store.cancelImport()
        let dropped = store.pendingOps.isEmpty && store.importing == 0
        store.cancelExport()
        _ = await waitUntil(30) { store.exportPhase == .idle }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("ops.serializedNoOverlap", queued && dropped && store.importProgress == nil && store.assets.map(\.id) == before && !fm.fileExists(atPath: e8.path),
              "queued \(queued) dropped \(dropped)")

        // 5. 원본 불변, 대상 폴더에 형제 임시 파일 없음, 임시 디렉터리 정리
        let hashesAfter = Dictionary(uniqueKeysWithValues: names.map { ($0, sha(src.appendingPathComponent($0))) })
        check("sources.unchanged", hashesAfter == hashesBefore)
        let left2 = (try? fm.contentsOfDirectory(atPath: out.path).sorted()) ?? []
        let expected = (["a-link.mp4", "appeared.mp4", "changed.mp4", "existing.mp4", "export.mp4", "timed.mp4"]).filter { linked || $0 != "a-link.mp4" }
        check("export.noSiblingTempFiles", left2 == expected, left2.joined(separator: ","))
        let tempDirs = temps.all
        check("export.tempDirsRemoved", !tempDirs.isEmpty && tempDirs.allSatisfy { !fm.fileExists(atPath: $0.path) }, "count \(tempDirs.count)")
        // 6. A-011 버리기(닫기·종료 확인에서 "버리기"를 고른 것과 같은 처리) 뒤 진행 중 가져오기 결과는 들어오지 않는다. 마지막 검사다(앱은 곧 끝남).
        let beforeDiscard = store.assets.map(\.id)
        store.importFiles(["otf-TA.mp4", "otf-TB.mp4"].map { src.appendingPathComponent($0) })
        _ = await waitUntil(10) { store.importProgress != nil }
        var discarded = false
        store.discardWithoutPromptForTest { discarded = true }
        _ = await waitUntil(30) { discarded }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        store.importFiles([src.appendingPathComponent("otf-TB.mp4")])   // 버린 뒤 요청은 시작하지 않는다
        check("import.ignoredAfterDiscard", discarded && store.assets.map(\.id) == beforeDiscard && store.importProgress == nil && store.importing == 0,
              "discarded \(discarded) assets \(store.assets.count)")
        finish(folder, inSandbox, checks, temps, manifest: manifest)
    }

    private static func finish(_ folder: URL, _ sandbox: Bool, _ checks: [Check], _ temps: Recorder, manifest: Manifest?) {
        let home = NSHomeDirectory()
        let locs = temps.all.map { u -> String in
            var p = u.deletingLastPathComponent().path
            p = p.replacingOccurrences(of: folder.path, with: "<folder>")
            p = p.replacingOccurrences(of: home, with: "<container-home>")
            return p.replacingOccurrences(of: #"folders\.\d+"#, with: "folders.<uid>", options: .regularExpression)
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let m = manifest, let d = try? enc.encode(m) { try? d.write(to: folder.appendingPathComponent("selftest-manifest.json")) }
        if let d = try? enc.encode(Result(sandboxContainer: sandbox, checks: checks, tempLocations: Array(Set(locs)).sorted())) {
            try? d.write(to: folder.appendingPathComponent("selftest-result.json"))
        }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }

    /// 사용자가 닫는 것과 같은 경로(알림의 마지막 단추 클릭)로 닫고, 그 알림이 내려갈 때까지 기다린다.
    private static func dismissAlert() async {
        let s = ProjectStore.shared
        guard let shown = s.alert else { return }
        s.alerts.pressButton(shown.revealURL == nil ? 0 : 1)
        _ = await waitUntil(5) { s.alert?.id != shown.id }
    }

    private static func sha(_ u: URL) -> String? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
}
#endif
