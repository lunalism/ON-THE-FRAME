#if DEBUG
import AppKit
import CryptoKit
import OnTheFrameEngine

/// 프로젝트 저장·열기 자체 검사(A-013, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFProjectTest`.
/// 샌드박스 앱에서 실제 저장·열기 함수(패널이 고른 뒤 부르는 것과 같은 writeProject·openProject·requestDiscard)를 쓴다. 패널 자체는 띄우지 않는다.
/// 결과는 <폴더>/project-result.json, 다시 연 프로젝트의 내보내기는 <폴더>/project-manifest.json(otf-dev verify-project가 독립 판정).
@MainActor
enum ProjectSelfTest {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)) }
        let src = folder.appendingPathComponent("sources"), out = folder.appendingPathComponent("out")
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        _ = await waitUntil(5) { s.editorWindow != nil }
        s.editorWindow?.makeKeyAndOrderFront(nil)
        func dismiss() async { while s.alerts.isShowing { s.alerts.pressButton(s.alerts.currentButtons.count > 1 ? 1 : 0); _ = await waitUntil(5) { !s.alerts.isShowing } } }
        func sha(_ u: URL) -> String { (try? Data(contentsOf: u)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "none" }

        check("start.clean", !s.isDirty && s.projectURL == nil && s.windowTitle == "제목 없음", s.windowTitle)
        // 1. 편집: 빈틈, 연결 해제 뒤 옮긴 소리(+15), 다시 연결, 레인 이름
        s.importFiles(["otf-TA.mp4", "otf-TB.mp4"].map { src.appendingPathComponent($0) })
        _ = await waitUntil(60) { s.assets.count == 2 && s.importing == 0 }
        let by = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.name, $0) })
        guard let ta = by["otf-TA.mp4"], let tb = by["otf-TB.mp4"] else { check("setup.import", false); return finish(folder, checks, nil) }
        check("import.makesDirty", s.isDirty && s.windowTitle.hasSuffix("편집됨"), s.windowTitle)
        s.addToTimeline(ta.id); s.addToTimeline(tb.id)
        s.seek(to: 60); s.select(s.timeline.clips[0].id); s.splitAtPlayhead()
        let right = s.timeline.clips[1].id
        guard let ra = s.timeline.partner(of: right)?.id, let tbA = s.timeline.partner(of: s.timeline.clips[2].id)?.id else { check("setup.edit", false); return finish(folder, checks, nil) }
        s.select(right); s.unlinkSelection()
        s.select(tbA); s.unlinkSelection(); s.select(tbA); s.deleteSelection()
        s.beginGesture(select: ra); s.updateFreeMove(ra, delta: 15); s.commitGesture()
        s.select(right); s.select(ra, extend: true); s.linkSelection()
        s.renameLane(Lane.videoID, to: "인터뷰 영상"); s.renameLane(Lane.audioID, to: "현장음")
        check("setup.edit", s.timeline.syncOffset(of: right) == 15 && s.timeline.audioGaps.contains(60..<75) && s.timeline.lanes.map(\.name) == ["인터뷰 영상", "현장음"],
              "offset \(s.timeline.syncOffset(of: right) ?? -99) gaps \(s.timeline.audioGaps)")

        // 2. 저장(새 위치) → 저장 상태, 제목, 최근 목록. 회귀(2026-10-10 저장 실패): 메뉴·⌘S처럼 완료 처리기 없이 처음 저장해도
        //    패널이 고른 위치에 실제로 쓰고 검사한 뒤에만 저장 상태가 된다(패널 결과만 주입, 뒤 경로는 실제)
        let p1 = out.appendingPathComponent("p1.ontheframe")
        s.savePanelResultForTest = p1
        s.saveProject()
        let saved1 = FileManager.default.fileExists(atPath: p1.path) && !s.isDirty
        let savedTimeline = s.timeline
        check("save.firstNoCompletion", saved1 && fm.fileExists(atPath: p1.path) && !s.isDirty && s.projectURL?.lastPathComponent == "p1.ontheframe" && s.windowTitle == "p1"
              && s.recentProjects.first?.path == p1.standardizedFileURL.path, "title \(s.windowTitle) recents \(s.recentProjects.map(\.name))")
        if let data = try? Data(contentsOf: p1), let (t, doc) = try? ProjectFile.decode(data) {
            // 연결 쌍을 잘라 소리 계보가 생김 → 스펙트럼 없이 계보만 든 형식 8(P-S1 (나), 2026-10-25)
            let lineageOnly = savedTimeline.audioClips.contains { $0.origin != nil } && !savedTimeline.needsSpectrumFormat
            check("save.fileContents", t == savedTimeline && doc.version == ProjectFile.spectrumVersion && lineageOnly && doc.media.allSatisfy { $0.bookmark != nil } && doc.projectID == s.projectID,
                  "version \(doc.version) lineageOnly \(lineageOnly) bookmarks \(doc.media.filter { $0.bookmark != nil }.count)/\(doc.media.count)")
        } else { check("save.fileContents", false, "decode") }
        // 2b. 회귀(2026-10-10 저장 실패): 메뉴·⌘S와 같은 완료 처리기 없는 저장도 실제로 파일을 쓴다
        s.renameLane(Lane.audioID, to: "메뉴 저장")
        let mBefore = (try? FileManager.default.attributesOfItem(atPath: p1.path)[.modificationDate] as? Date) ?? .distantPast
        s.saveProject()   // done 없음(메뉴 "프로젝트 저장"·⌘S 경로)
        let backMenu = (try? Data(contentsOf: p1)).flatMap { try? ProjectFile.decode($0).timeline }
        let mAfter = (try? FileManager.default.attributesOfItem(atPath: p1.path)[.modificationDate] as? Date) ?? .distantPast
        check("save.noCompletionWritesFile", !s.isDirty && backMenu?.lanes[1].name == "메뉴 저장" && mAfter >= mBefore, "dirty \(s.isDirty) name \(backMenu?.lanes[1].name ?? "nil")")
        s.undo()   // 저장 상태 기준으로 아래 검사를 잇기 위해 다시 저장
        _ = s.writeProject(to: p1)
        // 3. 저장하지 않은 상태: 편집 → 표시, 실행 취소로 저장 상태에 돌아오면 사라짐
        s.renameLane(Lane.audioID, to: "임시")
        let dirtyAfterEdit = s.isDirty
        s.undo()
        let cleanAfterUndo = !s.isDirty
        s.redo()
        let dirtyAfterRedo = s.isDirty
        s.undo()
        check("dirty.undoToSaved", dirtyAfterEdit && cleanAfterUndo && dirtyAfterRedo && !s.isDirty)
        // 4. 원본 미디어 보호(같은 경로, 하드 링크), 실패한 저장은 이전 파일·상태 유지
        let taHash = sha(src.appendingPathComponent("otf-TA.mp4"))
        let r1 = s.writeProject(to: src.appendingPathComponent("otf-TA.mp4"))
        let msg1 = s.alert?.message ?? ""
        await dismiss()
        let link = out.appendingPathComponent("ta-link.mp4")
        let linked = Darwin.link(src.appendingPathComponent("otf-TA.mp4").path, link.path) == 0
        let r2 = linked ? s.writeProject(to: link) : false
        await dismiss()
        check("save.protectsSourceMedia", !r1 && !r2 && linked && msg1.contains("원본") && sha(src.appendingPathComponent("otf-TA.mp4")) == taHash && s.projectURL == p1.standardizedFileURL,
              "linked \(linked) msg \(msg1)")
        s.renameLane(Lane.audioID, to: "바뀐 이름")
        let p1Hash = sha(p1), recentsBefore = s.recentProjects
        s.saveFailureForTest = true
        let r3 = s.writeProject(to: p1)
        let msg3 = s.alert?.message ?? ""
        await dismiss()
        check("save.failurePreserves", !r3 && sha(p1) == p1Hash && s.isDirty && s.recentProjects == recentsBefore && msg3.contains("그대로"), msg3)
        // 5. 저장하지 않은 변경이 있을 때 새 프로젝트: 확인(저장·취소·저장 안 함), 취소는 그대로, 저장은 저장 뒤 진행
        s.requestNewProject()
        _ = await waitUntil(5) { s.alerts.isShowing }
        let b = s.alerts.currentButtons
        let shape = b.map(\.title) == ["저장", "취소", "저장 안 함"] && b[0].keyEquivalent == "\r" && b[1].keyEquivalent == "\u{1b}" && b[2].hasDestructiveAction
        s.alerts.pressButton(1)
        _ = await waitUntil(5) { !s.alerts.isShowing }
        let cancelled = s.isDirty && s.projectURL == p1.standardizedFileURL && s.timeline.lanes[1].name == "바뀐 이름"
        s.requestNewProject()
        _ = await waitUntil(5) { s.alerts.isShowing }
        s.alerts.pressButton(0)   // 저장(현재 위치) → 새 프로젝트
        _ = await waitUntil(10) { s.projectURL == nil && !s.alerts.isShowing }
        let savedThenNew = s.projectURL == nil && s.timeline.isEmpty && s.assets.isEmpty && !s.isDirty
        let p1Now = (try? Data(contentsOf: p1)).flatMap { try? ProjectFile.decode($0).timeline }
        check("pending.newProject", shape && cancelled && savedThenNew && p1Now?.lanes[1].name == "바뀐 이름",
              "buttons \(b.map(\.title)) keys \(b.map { $0.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) } })")
        // 6. 다시 열기: 같은 타임라인(ID·연결·어긋남·빈틈·레인 이름·소리 계보 — 계보만 든 형식 8도 연다), 저장 상태
        let opened = await s.openProject(at: p1)
        let reopened = s.timeline
        check("open.roundTrip", opened && reopened.clips == p1Now?.clips && reopened.audioClips == p1Now?.audioClips && reopened.lanes == p1Now?.lanes
              && reopened.durationFrames == p1Now?.durationFrames && reopened.media.map(\.id) == p1Now?.media.map(\.id) && !s.isDirty && s.missingMedia.isEmpty
              && reopened.syncOffset(of: right) == 15, "dirty \(s.isDirty) missing \(s.missingMedia.count)")
        // 다시 연 프로젝트 내보내기(편집 의미 그대로) → otf-dev verify-project 독립 판정
        let dest = out.appendingPathComponent("restored.mp4")
        s.startExport(.fromSavePanel(dest))
        _ = await waitUntil(120) { s.exportPhase == .idle }
        let exportedOK = s.alert?.title == "내보내기 완료"
        await dismiss()
        check("export.restoredNotSaving", exportedOK && !s.isDirty, "dirty after export \(s.isDirty)")
        let names = Dictionary(uniqueKeysWithValues: reopened.media.map { ($0.id, $0.name) })
        let manifest = LaneSelfTest.Manifest(exportFile: "out/restored.mp4",
            clips: reopened.clips.map { .init(file: names[$0.mediaID] ?? "?", start: $0.start, sourceIn: $0.sourceIn, length: $0.length) },
            audioClips: reopened.audioClips.map { .init(file: names[$0.mediaID] ?? "?", start: $0.start, sourceIn: $0.sourceIn, length: $0.length) },
            durationFrames: reopened.durationFrames)
        // 7. 잘못된·더 새로운 파일은 거부, 현재 상태·최근 목록 그대로
        let bad = out.appendingPathComponent("bad.ontheframe"), newer = out.appendingPathComponent("newer.ontheframe")
        try? Data("{ not a project".utf8).write(to: bad)
        if var o = (try? Data(contentsOf: p1)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
            o["version"] = 99; try? JSONSerialization.data(withJSONObject: o).write(to: newer)
        }
        let recents2 = s.recentProjects
        let okBad = await s.openProject(at: bad)
        let badMsg = s.alert?.message ?? ""; await dismiss()
        let okNewer = await s.openProject(at: newer)
        let newerMsg = s.alert?.message ?? ""; await dismiss()
        check("open.rejectsMalformedAndNewer", !okBad && !okNewer && s.timeline == reopened && s.projectURL == p1.standardizedFileURL && s.recentProjects == recents2
              && badMsg.contains("손상") && newerMsg.contains("더 새로운 버전"), "bad '\(badMsg)' newer '\(newerMsg)'")
        // 7b. 스펙트럼이 든 형식 8(SP-1A 2B-1, 2026-10-26 — 1단계의 임시 열기 거부를 뺌): 열리고 타임라인이 그대로(스펙트럼 레인 포함), 저장 상태, 파일 그대로.
        //     같은 내용을 형식 7로 적은 파일은 잘못된 파일로 거부한다(현재 상태·파일 그대로). 그 뒤 p1을 다시 열어 아래 검사를 잇는다.
        let spec = out.appendingPathComponent("spectrum.ontheframe"), spec7 = out.appendingPathComponent("spectrum-v7.ontheframe")
        let specTimeline = try? reopened.addingLane(.spectrum, name: "SP", id: UUID())
        let specData = specTimeline.flatMap { try? ProjectFile.encode($0, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: spec) }
        try? specData?.write(to: spec)
        let okSpec = await s.openProject(at: spec)
        let specAlert = s.alert?.message; await dismiss()
        let specVersion = specData.flatMap { try? ProjectFile.decode($0).document.version }
        check("open.spectrumProject", specData != nil && okSpec && specAlert == nil && s.timeline == specTimeline && s.timeline.lanes(.spectrum).count == 1
              && s.projectURL == spec.standardizedFileURL && !s.isDirty && specVersion == 8 && (try? Data(contentsOf: spec)) == specData,
              "opened \(okSpec) version \(specVersion ?? -1) alert '\(specAlert ?? "")'")
        if var o = specData.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
            o["version"] = 7; try? JSONSerialization.data(withJSONObject: o).write(to: spec7)
        }
        let spec7Data = try? Data(contentsOf: spec7)
        let okSpec7 = await s.openProject(at: spec7)
        let spec7Msg = s.alert?.message ?? ""; await dismiss()
        check("open.rejectsSpectrumDeclaredV7", spec7Data != nil && !okSpec7 && spec7Msg.contains("올바르지 않") && s.timeline == specTimeline
              && s.projectURL == spec.standardizedFileURL && (try? Data(contentsOf: spec7)) == spec7Data, "msg '\(spec7Msg)'")
        _ = await s.openProject(at: p1); await dismiss()
        // 8. 가져오는 중에는 프로젝트를 바꾸지 않는다
        s.importFiles([src.appendingPathComponent("otf-A.mp4")])
        s.requestOpenProject(p1)
        let refused = (s.alert?.title ?? "") == "프로젝트를 바꿀 수 없습니다"
        await dismiss()
        _ = await waitUntil(30) { s.importing == 0 }
        check("open.refusedWhileImporting", refused && s.projectURL == p1.standardizedFileURL)
        // 저장하지 않은 변경(가져오기) + 열기 → 저장 안 함 → 열림
        s.requestOpenProject(p1)
        _ = await waitUntil(5) { s.alerts.isShowing }
        s.alerts.pressButton(2)
        _ = await waitUntil(10) { !s.alerts.isShowing && !s.isDirty }
        check("pending.openDiscard", !s.isDirty && !s.assets.contains { $0.name == "otf-A.mp4" } && s.projectURL == p1.standardizedFileURL)

        // 9. 찾을 수 없는 원본 → 열기는 되고 내보내기는 막힘 → 짧은 파일 재연결 거부 → 맞는 파일 재연결(실행 취소 가능)
        let mv = out.appendingPathComponent("mv"); try? fm.createDirectory(at: mv, withIntermediateDirectories: true)
        let copy = mv.appendingPathComponent("tb-copy.mp4"), other = out.appendingPathComponent("tb-other.mp4")
        try? fm.copyItem(at: src.appendingPathComponent("otf-TB.mp4"), to: copy)
        try? fm.copyItem(at: src.appendingPathComponent("otf-TB.mp4"), to: other)
        s.resetProject()
        s.importFiles([copy]); _ = await waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        if let c = s.assets.first { s.addToTimeline(c.id) }
        let p2 = out.appendingPathComponent("p2.ontheframe")
        _ = s.writeProject(to: p2)
        let p2Timeline = s.timeline
        try? fm.removeItem(at: copy)
        _ = await s.openProject(at: p2)
        let missingShown = s.alert?.title == "찾을 수 없는 원본 미디어가 있습니다"
        await dismiss()
        let mid = p2Timeline.media[0].id
        check("missing.opensStructure", missingShown && s.timeline.clips == p2Timeline.clips && s.missingMedia[mid] != nil && !s.canExport && s.exportBlockReason != nil
              && s.missingNameAtPlayhead == "tb-copy.mp4" && !s.isDirty, s.exportBlockReason ?? "")
        let shortOK = await s.relinkMedia(mid, to: src.appendingPathComponent("otf-hevc.mp4"))   // 30프레임, 소리 없음
        let shortMsg = s.alert?.message ?? ""; await dismiss()
        let relinked = await s.relinkMedia(mid, to: other)
        let afterRelink = s.missingMedia.isEmpty && s.canExport && s.isDirty && s.timeline.clips == p2Timeline.clips
        s.undo()
        let undoMissing = s.missingMedia[mid] != nil && !s.canExport
        s.redo()
        check("missing.relink", !shortOK && shortMsg.contains("짧습니다") && relinked && afterRelink && undoMissing && s.missingMedia.isEmpty,
              "short '\(shortMsg)'")
        // 10. 이동한 원본: 북마크로 찾고(샌드박스 접근), 새 프로젝트로 바꾸면 접근을 모두 멈춘다
        let bm = out.appendingPathComponent("bm"); try? fm.createDirectory(at: bm, withIntermediateDirectories: true)
        let bmFile = bm.appendingPathComponent("x.mp4")
        try? fm.copyItem(at: src.appendingPathComponent("otf-TA.mp4"), to: bmFile)
        s.resetProject()
        s.importFiles([bmFile]); _ = await waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        if let c = s.assets.first { s.addToTimeline(c.id) }
        let p3 = out.appendingPathComponent("p3.ontheframe")
        _ = s.writeProject(to: p3)
        let moved = bm.appendingPathComponent("moved"); try? fm.createDirectory(at: moved, withIntermediateDirectories: true)
        try? fm.moveItem(at: bmFile, to: moved.appendingPathComponent("x.mp4"))
        s.resetProject()
        _ = await s.openProject(at: p3)
        await dismiss()
        let foundMoved = s.missingMedia.isEmpty && (s.assets.first?.url.path.hasSuffix("moved/x.mp4") ?? false)
        let scopes = s.scopedURLs.count
        s.resetProject()
        check("bookmark.movedAndBalanced", foundMoved && scopes >= 1 && s.scopedURLs.isEmpty, "found \(foundMoved) scopes \(scopes) url \(s.assets.first?.url.lastPathComponent ?? "-")")
        // 11. 최근 목록: 최신이 앞, 중복 없음, 최대 10, 지우기는 목록만
        let paths = s.recentProjects.map(\.path)
        check("recent.orderDedupBounded", paths.first == p3.standardizedFileURL.path && Set(paths).count == paths.count && paths.count <= 10
              && !paths.contains(bad.standardizedFileURL.path) && !paths.contains(newer.standardizedFileURL.path), "\(s.recentProjects.map(\.name))")
        s.clearRecents()
        check("recent.clearKeepsFiles", s.recentProjects.isEmpty && fm.fileExists(atPath: p1.path) && fm.fileExists(atPath: p3.path))
        // 12. Finder에서 열기(앱 대리자 경로)
        let delegateCalled = NSApp.delegate?.application?(NSApp, open: [p1]) != nil   // SwiftUI 대리자 어댑터를 거쳐 AppDelegate로
        _ = await waitUntil(10) { s.projectURL == p1.standardizedFileURL }
        await dismiss()
        check("finder.open", delegateCalled && s.projectURL == p1.standardizedFileURL && s.timeline.lanes.map(\.name) == ["인터뷰 영상", "바뀐 이름"] && s.recentProjects.first?.path == p1.standardizedFileURL.path)
        finish(folder, checks, manifest)
    }

    static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    static func finish(_ folder: URL, _ checks: [Check], _ m: LaneSelfTest.Manifest?) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let m, let d = try? enc.encode(m) { try? d.write(to: folder.appendingPathComponent("project-manifest.json")) }
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("project-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
