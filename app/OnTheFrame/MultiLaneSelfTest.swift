#if DEBUG
import AppKit
import OnTheFrameEngine

/// 여러 레인·소리 파일 자체 검사(A-014, Debug 전용, 일반 화면에 없음). `open -n -W -a OnTheFrame.app <폴더> --args -OTFMultiLaneTest`.
/// 앱 경로(타임라인 메뉴·레인 머리 문맥 메뉴·놓기 해석·합성 마우스 드래그·키·정보 패널과 같은 저장소 동작·저장·열기·재연결)로 편집하고,
/// 결과는 <폴더>/multilane-result.json, 마지막 내보내기의 레인 배치는 multilane-manifest.json(otf-dev verify-multilane이 독립 판정).
/// 미디어 목록에서 타임라인으로 끄는 것은 실제 끌어 놓기 세션 대신 놓은 위치 해석(TimelineNSView.drop)을 직접 부른다.
/// 음량 슬라이더는 놓을 때 부르는 저장소 동작(setLaneVolume)을 직접 부른다. 합성 이벤트 검사이며 실제 키보드·마우스 확인이 아니다.
@MainActor
enum MultiLaneSelfTest {
    typealias Check = LaneSelfTest.Check
    struct Manifest: Codable {
        struct LaneClip: Codable { let file: String; let start: Int; let sourceIn: Int; let length: Int }
        struct LaneRef: Codable { let kind: String; let name: String; let muted: Bool; let volumePercent: Int; let clips: [LaneClip] }
        let exportFile: String; let durationFrames: Int; let lanes: [LaneRef]
    }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        let src = folder.appendingPathComponent("sources"), out = folder.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { check("setup.window", false); return finish(folder, checks, nil) }
        w.makeKeyAndOrderFront(nil)
        if !(await LaneSelfTest.regainFocus(w)) { LaneSelfTest.direct = true }
        // 원본 보존 확인용: 크기·수정 시각·내용 지문
        let files = ["otf-TA.mp4", "otf-TB.mp4", "aud-wav48s.wav", "aud-aiff441m.aiff", "aud-aac48s.m4a", "aud-alac441s.m4a"]
        func fingerprint() -> [String] {
            files.map { f in
                let u = src.appendingPathComponent(f)
                let a = (try? FileManager.default.attributesOfItem(atPath: u.path)) ?? [:]
                let d = (try? Data(contentsOf: u)) ?? Data()
                var h: UInt64 = 0xcbf29ce484222325
                for b in d { h = (h ^ UInt64(b)) &* 0x100000001b3 }
                return "\(f):\(a[.size] as? Int ?? -1):\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1):\(String(h, radix: 16))"
            }
        }
        let before = fingerprint()

        // 1. 가져오기(한 묶음): 영상 2 + 소리 파일 4(WAV·AIFF·AAC·ALAC) + 4채널 WAV(거부, 묶음 오류 알림)
        s.importFiles((files + ["reject-4ch.wav"]).map { src.appendingPathComponent($0) })
        _ = await LaneSelfTest.waitUntil(60) { s.importing == 0 && s.assets.count == 6 && s.alerts.isShowing }
        check("import.audioAccepted", s.assets.count == 6 && s.assets.filter { !$0.hasVideo }.count == 4
              && s.assets.first { $0.name == "aud-aiff441m.aiff" }.map { $0.audioSampleRate == 44_100 && $0.audioChannels == 1 && $0.audioSampleCount == 66_000 && $0.frameCount == 45 } == true,
              s.assets.map { "\($0.name) \($0.codec) \($0.audioSampleRate ?? 0)" }.joined(separator: ", "))
        check("import.batchRejection", s.alert?.title == ProjectStore.rejectTitle && (s.alert?.message ?? "").contains("reject-4ch.wav") && (s.alert?.message ?? "").contains("채널"),
              s.alert?.message ?? "no alert")
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        let by = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.name, $0) })
        guard let ta = by["otf-TA.mp4"], let tb = by["otf-TB.mp4"], let wav = by["aud-wav48s.wav"], let aif = by["aud-aiff441m.aiff"],
              let aac = by["aud-aac48s.m4a"], let alac = by["aud-alac441s.m4a"] else { check("setup.assets", false); return finish(folder, checks, nil) }
        s.addToTimeline(ta.id)                                                      // 영상1/원본소리 [0,120)
        _ = await LaneSelfTest.waitUntil(10) { s.canPlay }
        guard let container = LaneSelfTest.find(TimelineContainerView.self, w.contentView) else { check("setup.timeline", false); return finish(folder, checks, nil) }
        let tv = container.timelineView, header = container.header
        await LaneSelfTest.settle()
        let v1 = Lane.videoID, a1 = Lane.audioID

        // 2. 영상 레인 추가(타임라인 메뉴) → 맨 위(경계에서 바깥쪽, V2, 2026-10-11 배치) → 레인 머리 문맥 메뉴 "아래로"·"위로"
        let menuAdded = LaneSelfTest.menuItem("영상 레인 추가")
        await LaneSelfTest.settle()
        guard let vTop = s.timeline.lanes(.video).first?.id, vTop != v1 else { check("lane.addVideo", false, "menu \(menuAdded)"); return finish(folder, checks, nil) }
        check("lane.addVideo", menuAdded && s.timeline.lanes.map(\.id) == [vTop, v1, a1] && s.timeline.laneInfo(vTop)?.name == "영상" && s.timeline.laneLabel(vTop) == "V2")
        func headerItem(_ lane: UUID?, _ title: String, y: CGFloat? = nil) -> Bool {
            let py = y ?? (lane.map { header.rowRect($0).midY } ?? 0)
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: header.convert(NSPoint(x: 50, y: py), to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let m = header.menu(for: e), let i = m.items.firstIndex(where: { $0.title.hasPrefix(title) }), m.items[i].isEnabled else { return false }
            m.performActionForItem(at: i); return true
        }
        let downOK = headerItem(vTop, "아래로")
        await LaneSelfTest.settle()
        let wentDown = s.timeline.lanes.map(\.id) == [v1, vTop, a1] && s.timeline.laneLabel(vTop) == "V1"
        let upOK = headerItem(vTop, "위로")
        await LaneSelfTest.settle()
        check("lane.moveUpViaHeaderMenu", downOK && wentDown && upOK && s.timeline.lanes.map(\.id) == [vTop, v1, a1] && !headerItem(vTop, "위로"), "\(s.timeline.lanes.map(\.name))")
        // 레인 이름(한글, 텍스트 칸): 두 번 눌러 편집 → "인서트" → Return. 편집 중 ⌘K·Delete는 타임라인을 바꾸지 않는다.
        func headerPoint(_ id: UUID) -> NSPoint { header.convert(NSPoint(x: 50, y: header.rowRect(id).midY), to: nil) }
        let beforeRename = s.timeline
        await LaneSelfTest.mouse(.leftMouseDown, headerPoint(vTop), w, clicks: 2); await LaneSelfTest.mouse(.leftMouseUp, headerPoint(vTop), w, clicks: 2)
        if let ed = w.firstResponder as? NSTextView {
            ed.selectAll(nil)
            ed.setMarkedText("ㅇ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            ed.insertText("인서트", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        await LaneSelfTest.key(40, "k", [.command], w)
        let unchanged = s.timeline == beforeRename
        await LaneSelfTest.key(36, "\r", [], w)
        check("lane.renameKorean", unchanged && s.timeline.laneInfo(vTop)?.name == "인서트" && header.editor == nil, s.timeline.laneInfo(vTop)?.name ?? "")

        // 3. 놓기: TB를 맨 위 영상 레인 30프레임에 → 연결된 소리는 빈 오디오 레인이 없어 "otf-TB" 새 오디오 레인
        func lanePoint(_ id: UUID, frame: Int) -> NSPoint { NSPoint(x: tv.x(frame), y: tv.laneRect(id)?.midY ?? 0) }
        tv.drop(tb.id, at: lanePoint(vTop, frame: 30))
        await LaneSelfTest.settle()
        let tbV = s.timeline.clips(inLane: vTop).first
        let aTB = tbV.flatMap { s.timeline.partner(of: $0.id)?.lane }
        check("drop.videoOnUpperLane", tbV.map { [$0.start, $0.sourceIn, $0.length] } == [30, 0, 90] && aTB != nil && aTB != a1
              && aTB.flatMap { s.timeline.laneInfo($0)?.name } == "otf-TB" && s.timeline.durationFrames == 120,
              "top \(s.timeline.clips(inLane: vTop).map { [$0.start, $0.length] }) lanes \(s.timeline.lanes.map(\.name))")
        guard let tbVid = tbV?.id, let laneTB = aTB else { return finish(folder, checks, nil) }
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, checks, nil) }
        // 위 레인 TB 클립 누르고 ⌘K(70) → 오른쪽 조각 Delete → 위 [30,70) 원본 0–39. ⇧Delete는 아래 레인 TA가 걸쳐 거부
        func clipPoint(_ id: UUID) -> NSPoint {
            guard let c = s.timeline.clip(id), let r = tv.laneRect(c.lane) else { return .zero }
            return tv.convert(NSPoint(x: tv.x(c.start) + CGFloat(c.length) * tv.pixelsPerFrame / 2, y: r.midY), to: nil)
        }
        await LaneSelfTest.mouse(.leftMouseDown, clipPoint(tbVid), w); await LaneSelfTest.mouse(.leftMouseUp, clipPoint(tbVid), w)
        s.seek(to: 70)
        await LaneSelfTest.key(40, "k", [.command], w)
        let right = s.timeline.clips(inLane: vTop).first { $0.start == 70 }?.id
        if let right { s.select(right) }
        await LaneSelfTest.key(51, "\u{7f}", [], w)
        let leftTB = s.timeline.clips(inLane: vTop).first?.id
        check("edit.splitDeleteUpperLane", s.timeline.clips(inLane: vTop).map { [$0.start, $0.sourceIn, $0.length] } == [[30, 0, 40]]
              && s.timeline.clips(inLane: laneTB).map { [$0.start, $0.length] } == [[30, 40]] && s.timeline.clips(inLane: v1).map(\.length) == [120],
              "top \(s.timeline.clips(inLane: vTop).map { [$0.start, $0.sourceIn, $0.length] })")
        if let leftTB { s.select(leftTB) }
        let beforeRipple = s.timeline
        await LaneSelfTest.key(51, "\u{7f}", [.shift], w)
        check("edit.rippleRejectedAcrossLanes", s.timeline == beforeRipple && (s.statusMessage ?? "").contains("리플"), s.statusMessage ?? "")

        // 4. 소리 파일: 레인 아래 빈 곳에 WAV → 파일 이름의 새 레인 [10,70). 같은 레인 75에 AIFF [75,120). AAC를 영상 레인에 → 거부
        tv.drop(wav.id, at: NSPoint(x: tv.x(10), y: tv.lanesBottom + 25))
        await LaneSelfTest.settle()
        let laneW = s.timeline.lanes.last { $0.kind == .audio }
        tv.drop(aif.id, at: lanePoint(laneW?.id ?? UUID(), frame: 75))
        await LaneSelfTest.settle()
        check("drop.audioNewLaneAndChosenLane", laneW?.name == "aud-wav48s" && laneW.map { s.timeline.clips(inLane: $0.id).map { [$0.start, $0.length] } } == [[10, 60], [75, 45]]
              && s.timeline.durationFrames == 120, "\(s.timeline.lanes.map(\.name))")
        let beforeBad = s.timeline
        tv.drop(aac.id, at: lanePoint(v1, frame: 0))
        await LaneSelfTest.settle()
        check("drop.audioOnVideoLaneRejected", s.timeline == beforeBad && (s.statusMessage ?? "").contains("오디오 레인"), s.statusMessage ?? "")
        guard let laneWid = laneW?.id else { return finish(folder, checks, nil) }
        // 5. 음소거(레인 머리 메뉴), 음량 50%(정보 패널 슬라이더를 놓을 때와 같은 동작). 각각 한 단계.
        let dM = s.history.undoDepth
        let muted = headerItem(laneTB, "음소거")
        s.setLaneVolume(laneWid, 50)
        check("lane.muteAndVolume", muted && s.timeline.laneInfo(laneTB)?.muted == true && s.timeline.laneInfo(laneWid)?.volumePercent == 50 && s.history.undoDepth == dM + 2 && s.isDirty)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        let mixApplied = s.player.currentItem?.audioMix?.inputParameters.count ?? 0
        check("preview.audioMixApplied", mixApplied >= 1 && s.currentPlan?.audioMix != nil, "params \(mixApplied)")

        // 6. ALAC를 빈 곳에 → 새 레인 [80,110). 그 클립을 위아래로 끌어 음소거한 "otf-TB" 레인으로(빈 [80,110)) — 한 단계, Esc 취소 먼저
        tv.drop(alac.id, at: NSPoint(x: tv.x(80), y: tv.lanesBottom + 25))
        await LaneSelfTest.settle()
        guard let laneL = s.timeline.lanes.last(where: { $0.kind == .audio })?.id, let lClip = s.timeline.clips(inLane: laneL).first?.id, laneL != laneWid else {
            check("drop.alacNewLane", false); return finish(folder, checks, nil)
        }
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, checks, nil) }
        // 아래 레인이 보이게 세로로 스크롤(레인 머리도 함께 움직인다)
        if let a = tv.laneRect(laneTB), let b = tv.laneRect(laneL) { tv.scrollToVisible(NSRect(x: tv.x(70), y: a.minY - 4, width: 10, height: b.maxY - a.minY + 8)) }
        await LaneSelfTest.settle()
        let headerFollows = abs(header.rowRect(laneL).midY - (tv.convert(NSPoint(x: 0, y: tv.laneRect(laneL)?.midY ?? 0), to: header).y)) < 1
        let p0 = clipPoint(lClip)
        let target = tv.convert(NSPoint(x: tv.convert(p0, from: nil).x, y: tv.laneRect(laneTB)?.midY ?? 0), to: nil)
        let dD = s.history.undoDepth
        await LaneSelfTest.mouse(.leftMouseDown, p0, w); await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p0.x + 6, y: p0.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p0.x, y: target.y), w)
        await LaneSelfTest.key(53, "\u{1b}", [], w)
        let escOK = s.timeline.clip(lClip)?.lane == laneL && s.gestureBase == nil
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: p0.x, y: target.y), w)
        // 겹치는 레인(WAV [10,70)·AIFF [75,120))으로는 거부(빨강)
        let pW = tv.convert(NSPoint(x: tv.convert(p0, from: nil).x, y: tv.laneRect(laneWid)?.midY ?? 0), to: nil)
        await LaneSelfTest.mouse(.leftMouseDown, p0, w); await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p0.x + 6, y: p0.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p0.x, y: pW.y), w)
        let red = s.freeMoveProposal?.ok == false
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: p0.x, y: pW.y), w)
        let rejected = s.timeline.clip(lClip)?.lane == laneL && s.history.undoDepth == dD
        await LaneSelfTest.mouse(.leftMouseDown, p0, w); await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p0.x + 6, y: p0.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p0.x, y: target.y), w)
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: p0.x, y: target.y), w)
        check("drag.audioClipToOtherLane", headerFollows && escOK && red && rejected && s.timeline.clip(lClip)?.lane == laneTB && s.timeline.clip(lClip)?.start == 80 && s.history.undoDepth == dD + 1,
              "esc \(escOK) red \(red) rejected \(rejected) headerFollows \(headerFollows) scrolled \(container.scrollView.contentView.bounds.minY) lane \(s.timeline.clip(lClip)?.lane.flatMap { s.timeline.laneInfo($0)?.name } ?? "nil")")
        // 빈 레인 삭제(확인 없음)
        let removedEmpty = headerItem(laneL, "레인 삭제")
        await LaneSelfTest.settle()
        check("lane.deleteEmptyNoPrompt", removedEmpty && s.timeline.laneInfo(laneL) == nil && !s.alerts.isShowing)

        // 7. 연결된 쌍 레인 옮기기(정보 패널과 같은 동작): 소리를 TA가 있는 원본소리 레인으로 → 겹쳐 거부, 아무것도 바뀌지 않음
        if let leftTB { s.select(leftTB) }
        let beforeRel = s.timeline
        s.relocateSelection(lane: nil, partnerLane: a1)
        check("relocate.linkedPairAtomicReject", s.timeline == beforeRel && (s.statusMessage ?? "").contains("겹칩니다"), s.statusMessage ?? "")

        // 8. 클립이 있는 레인 삭제: 확인 → 취소(그대로) → 다시 → 삭제(한 단계), ⌘Z 되살림, ⌘⇧Z 다시 삭제
        _ = LaneSelfTest.menuItem("오디오 레인 추가")
        await LaneSelfTest.settle()
        guard let laneC = s.timeline.lanes.last(where: { $0.kind == .audio })?.id else { return finish(folder, checks, nil) }
        tv.drop(aac.id, at: lanePoint(laneC, frame: 0))
        await LaneSelfTest.settle()
        let withC = s.timeline, dC = s.history.undoDepth
        _ = headerItem(laneC, "레인 삭제")
        _ = await LaneSelfTest.waitUntil(3) { s.alerts.isShowing }
        let prompted = s.alert?.title == "레인을 삭제할까요?"
        s.alerts.pressButton(1)
        _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing }
        let cancelKept = s.timeline == withC
        _ = headerItem(laneC, "레인 삭제")
        _ = await LaneSelfTest.waitUntil(3) { s.alerts.isShowing }
        s.alerts.pressButton(0)
        _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing }
        let deleted = s.timeline.laneInfo(laneC) == nil && s.history.undoDepth == dC + 1
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, checks, nil) }
        await LaneSelfTest.key(6, "z", [.command], w)
        let restored = s.timeline == withC
        await LaneSelfTest.key(6, "z", [.command, .shift], w)
        check("lane.deleteNonemptyConfirmUndo", prompted && cancelKept && deleted && restored && s.timeline.laneInfo(laneC) == nil,
              "prompted \(prompted) cancel \(cancelKept) deleted \(deleted) restored \(restored)")

        // 9. 저장(형식 2) → 새 프로젝트 → 다시 열기: 레인·순서·음소거·음량·소리 파일 미디어 모두 같음
        let edited = s.timeline
        let proj = out.appendingPathComponent("multilane.ontheframe")
        let saved = s.writeProject(to: proj)
        let doc = (try? Data(contentsOf: proj)).flatMap { try? ProjectFile.decode($0) }
        check("project.saveV2", saved && !s.isDirty && doc?.document.version == ProjectFile.currentVersion && s.recentProjects.first?.path == proj.standardizedFileURL.path)
        s.resetProject()
        let reopened = await s.openProject(at: proj)
        check("project.reopenV2", reopened && s.timeline == edited && s.missingMedia.isEmpty && !s.isDirty && s.timeline.laneInfo(laneTB)?.muted == true
              && s.timeline.laneInfo(laneWid)?.volumePercent == 50, "missing \(s.missingMedia.count)")
        // 원본 보호: 소리 원본 위치로 프로젝트 저장·내보내기 거부
        let wavURL = src.appendingPathComponent("aud-wav48s.wav")
        check("protect.projectOverAudioSource", s.protectedProjectDestination(wavURL) != nil)
        s.startExport(.fromSavePanel(wavURL))
        _ = await LaneSelfTest.waitUntil(30) { s.exportPhase == .idle && s.alerts.isShowing }
        check("protect.exportOverAudioSource", s.alert?.title == "내보내기 실패", "\(s.alert?.title ?? "none"): \(s.alert?.message ?? "") showing \(s.alerts.isShowing) queued \(s.alerts.queuedCount)")
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }

        check("sources.unchanged", fingerprint() == before)
        // 10. 찾을 수 없는 소리 원본: AIFF를 다른 이름으로 복사하고 원래 파일을 지운 뒤 다시 열기(북마크는 옮긴 파일을 따라가므로 지운다)
        //     → 원본 없음·내보내기 막힘 → 복사본으로 재연결(실행 취소 한 단계) → 원래 자리에 복사본을 되돌린다(이 검사 폴더의 생성 fixture만)
        let aifURL = src.appendingPathComponent("aud-aiff441m.aiff"), moved = folder.appendingPathComponent("moved-aiff441m.aiff")
        try? FileManager.default.copyItem(at: aifURL, to: moved)
        try? FileManager.default.removeItem(at: aifURL)
        s.resetProject()
        _ = await s.openProject(at: proj)
        _ = await LaneSelfTest.waitUntil(5) { s.alerts.isShowing }
        let missingShown = s.missingMedia.keys.contains(aif.id) && s.exportBlockReason != nil && !s.canExport && s.missingUsedMedia == [aif.id]
        let missingDetail = "keys \(s.missingMedia.count) used \(s.missingUsedMedia.count) block \(s.exportBlockReason != nil) can \(s.canExport)"
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        let relinked = await s.relinkMedia(aif.id, to: moved)
        check("missing.audioRelink", missingShown && relinked && s.missingMedia.isEmpty && s.exportBlockReason == nil && s.timeline.clips(inLane: laneWid).count == 2,
              "shown \(missingShown) [\(missingDetail)] relinked \(relinked) missing \(s.missingMedia.count) block \(s.exportBlockReason ?? "nil")")
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        try? FileManager.default.copyItem(at: moved, to: aifURL)   // 마지막 내보내기용으로 원래 경로에 되돌림

        // 11. 형식 1 파일(A-013 모양, 손으로 씀) 열기 → 레인 2개·첫 레인 클립, 다시 저장하면 형식 2
        let v1File = out.appendingPathComponent("legacy-v1.ontheframe")
        let mid = UUID(), link = UUID()
        let v1json = """
        {"format":"dev.ontheframe.project","version":1,"projectID":"\(UUID())","settings":{"width":1920,"height":1080,"fps":30},"durationFrames":130,
         "lanes":[{"id":"\(Lane.videoID)","kind":"video","name":"예전 영상"},{"id":"\(Lane.audioID)","kind":"audio","name":"예전 소리"}],
         "media":[{"ref":{"id":"\(mid)","name":"otf-TA.mp4","path":"\(src.appendingPathComponent("otf-TA.mp4").path)","frameCount":120,"hasAudio":true,"size":1,"modifiedNs":1,"codec":"avc1","width":1920,"height":1080}}],
         "videoClips":[{"id":"\(UUID())","mediaID":"\(mid)","start":0,"sourceIn":0,"length":120,"link":"\(link)"}],
         "audioClips":[{"id":"\(UUID())","mediaID":"\(mid)","start":0,"sourceIn":0,"length":120,"link":"\(link)"}]}
        """
        try? Data(v1json.utf8).write(to: v1File)
        s.resetProject()
        let v1Opened = await s.openProject(at: v1File)
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        let v1T = s.timeline
        let v1Resaved = s.writeProject(to: out.appendingPathComponent("legacy-resaved.ontheframe"))
        let re = (try? Data(contentsOf: out.appendingPathComponent("legacy-resaved.ontheframe"))).flatMap { try? ProjectFile.decode($0) }
        check("project.openV1", v1Opened && v1T.lanes.map(\.name) == ["예전 영상", "예전 소리"] && v1T.clips.first?.lane == Lane.videoID && v1T.durationFrames == 130
              && s.missingMedia.isEmpty && v1T.media.count == 1 && v1Resaved && re?.document.version == ProjectFile.currentVersion && re?.timeline == v1T, "lanes \(v1T.lanes.map(\.name))")

        // 12. 편집한 프로젝트를 다시 열어 내보내기 → otf-dev verify-multilane
        s.resetProject()
        _ = await s.openProject(at: proj)
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        let final = s.timeline
        let dest = out.appendingPathComponent("multilane.mp4")
        s.startExport(.fromSavePanel(dest))
        _ = await LaneSelfTest.waitUntil(120) { s.exportPhase == .idle && s.alerts.isShowing }
        check("export.multilane", s.alert?.title == "내보내기 완료" && FileManager.default.fileExists(atPath: dest.path), s.alert?.message ?? "")
        while s.alerts.isShowing { s.alerts.pressButton(1); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        let names = Dictionary(uniqueKeysWithValues: final.media.map { ($0.id, $0.name) })
        let manifest = Manifest(exportFile: "out/multilane.mp4", durationFrames: final.durationFrames, lanes: final.lanes.map { l in
            Manifest.LaneRef(kind: l.kind.rawValue, name: l.name, muted: l.muted, volumePercent: l.volumePercent,
                             clips: final.clips(inLane: l.id).map { .init(file: names[$0.mediaID] ?? "?", start: $0.start, sourceIn: $0.sourceIn, length: $0.length) })
        })
        finish(folder, checks, manifest)
    }

    static func finish(_ folder: URL, _ checks: [Check], _ m: Manifest?) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: LaneSelfTest.direct ? "앱을 활성화할 수 없어(다른 앱이 앞에 있음) 마우스는 보기에 직접, 키는 같은 저장소 동작·텍스트 칸 명령으로 보냄"
                                                                 : "합성 이벤트를 앱 이벤트 큐로 보냄(KeyRouting 경로 포함)")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let m, let d = try? enc.encode(m) { try? d.write(to: folder.appendingPathComponent("multilane-manifest.json")) }
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("multilane-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
