#if DEBUG
import AppKit
import OnTheFrameEngine

/// 타임라인 클립 복사·붙여넣기 자체 검사(2026-10-11, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFCopyPasteTest`.
/// 실제 키 이벤트(⌘C·⌘V, 앱 이벤트 큐)와 편집 메뉴 항목, 실행 취소·다시 실행, 새 프로젝트로 바꾸기를 지난다. 생성 fixture(otf-TA)만.
/// 텍스트 입력 초점은 라우터 판단(이벤트를 넘기는가)과 타임라인 불변으로 본다. 시스템 클립보드를 바꾸지 않으려고 텍스트 칸에 실제 ⌘C·⌘V를 보내지 않는다.
/// 결과는 <폴더>/copypaste-result.json.
@MainActor
enum CopyPasteSelfTest {
    typealias Check = LaneSelfTest.Check

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { return finish(folder, [Check(name: "setup.window", pass: false, detail: "")]) }
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, [LaneSelfTest.lostFocus("setup")]) }
        func cmd(_ code: UInt16, _ ch: String) async { w.makeFirstResponder(nil); await LaneSelfTest.key(code, ch, [.command], w) }

        // 준비: 영상+소리 클립(120) → 소리 페이드 인 30·음량 70, 영상 변형 → 10에서 자르기 → 오른쪽 조각 선택(페이드 offset 10)
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        guard let asset = s.assets.first else { return finish(folder, [Check(name: "setup.import", pass: false, detail: "")]) }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        s.addToTimeline(asset.id)
        guard let v0 = s.timeline.clips.first?.id, let a0 = s.timeline.audioClips.first?.id else { return finish(folder, [Check(name: "setup.place", pass: false, detail: "")]) }
        s.setClipAudio(a0, volumePercent: 70, fadeInFrames: 30)
        s.setTransform(v0, ClipTransform(scalePermille: 500, offsetX: 100, offsetY: -50))
        s.select(v0); s.seek(to: 10); s.splitAtPlayhead()
        guard let right = s.timeline.clips.first(where: { $0.start == 10 }), let rightAudio = s.timeline.partner(of: right.id) else {
            return finish(folder, [Check(name: "setup.split", pass: false, detail: "")])
        }
        s.select(right.id)
        await LaneSelfTest.settle()

        // 1. 선택 없음 ⌘C: 아무것도 복사하지 않음
        s.select(nil)
        await cmd(8, "c")
        check("copy.noSelectionNoop", s.clipClipboard == nil, s.statusMessage ?? "")

        // 2. ⌘C(실제 키): 프로젝트·기록 그대로, 클립보드 = 고른 클립과 연결된 짝
        s.select(right.id)
        let t0 = s.timeline, depth0 = s.history.undoDepth, dirty0 = s.isDirty
        await cmd(8, "c")
        let cb = s.clipClipboard
        check("copy.nonMutating", s.timeline == t0 && s.history.undoDepth == depth0 && s.isDirty == dirty0, "depth \(s.history.undoDepth - depth0)")
        check("copy.takesLinkedPair", cb?.content.video.map(\.id) == [right.id] && cb?.content.audio.map(\.id) == [rightAudio.id] && cb?.project == s.projectID,
              "\(cb?.content.all.count ?? 0) clips")

        // 3. ⌘V(실제 키) 재생 헤드(타임라인 끝, 재생 헤드는 끝을 넘지 않는다): 한 단계, 새 ID·새 연결, 속성 그대로, 붙여 넣은 클립 선택
        s.seek(to: s.durationFrames)
        let p1 = s.playhead
        await cmd(9, "v")
        let t1 = s.timeline
        let nv = t1.clips.first { $0.start == p1 }, na = nv.flatMap { t1.partner(of: $0.id) }
        check("paste.atPlayheadOneStep", p1 == 120 && nv != nil && na?.start == p1 && s.history.undoDepth == depth0 + 1 && s.selection == nv?.id,
              "video \(nv.map { "\($0.start)" } ?? "nil") audio \(na.map { "\($0.start)" } ?? "nil") depth \(s.history.undoDepth - depth0) selection ok \(s.selection == nv?.id)")
        if let nv, let na {
            check("paste.propertiesPreserved", nv.sourceIn == right.sourceIn && nv.length == right.length && nv.transform == right.transform && na.audio == rightAudio.audio
                  && na.effectiveAudio.fadeIn == ClipAudio.Fade(length: 30, offset: 10) && nv.lane == right.lane && na.lane == rightAudio.lane,
                  "fadeIn \(na.effectiveAudio.fadeIn) volume \(na.effectiveAudio.volumePercent)")
            check("paste.freshIdentities", nv.id != right.id && na.id != rightAudio.id && nv.link != nil && nv.link != right.link && t1.partner(of: right.id)?.id == rightAudio.id
                  && t1.clip(right.id) == right && t1.clip(rightAudio.id) == rightAudio)
        }

        // 4. 같은 곳에 다시 ⌘V: 겹쳐서 새 영상·오디오 레인(같은 한 단계). 실행 취소 → 레인까지 원래대로, 다시 실행 → 같은 상태
        await cmd(9, "v")
        let t2 = s.timeline
        check("paste.overlapCreatesLanesOneStep", t2.lanes.count == t1.lanes.count + 2 && s.history.undoDepth == depth0 + 2 && t2.clips(inLane: Lane.videoID) == t1.clips(inLane: Lane.videoID),
              "lanes \(t1.lanes.count)→\(t2.lanes.count)")
        await cmd(6, "z")
        let undone = s.timeline
        await LaneSelfTest.key(6, "z", [.command, .shift], w)
        check("paste.undoRedoAtomic", undone == t1 && s.timeline == t2, "undo ok \(undone == t1) redo ok \(s.timeline == t2)")

        // 5. 편집 메뉴 "붙여넣기"(마우스 선택과 같은 경로)
        s.seek(to: s.durationFrames)
        let p3 = s.playhead
        w.makeFirstResponder(nil); await LaneSelfTest.settle()
        let menuOK = LaneSelfTest.menuItem("붙여넣기")
        await LaneSelfTest.settle()
        check("menu.pasteItem", menuOK && s.timeline.clips.contains { $0.start == p3 && $0.id != right.id } && s.history.undoDepth == depth0 + 3, "menu \(menuOK)")

        // 6. 텍스트 입력 초점: ⌘C·⌘V는 편집기가 처리하지 않고 넘긴다(텍스트 복사·붙여넣기), 타임라인·클립보드 그대로
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        w.contentView?.addSubview(field)
        w.makeFirstResponder(field)
        await LaneSelfTest.settle()
        let tText = s.timeline, cbText = s.clipClipboard
        func passes(_ code: UInt16, _ ch: String) -> Bool {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                           context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) else { return false }
            return KeyRouting.handle(e, store: s) != nil
        }
        check("text.copyPastePassThrough", KeyRouting.isTextInput(w.firstResponder) && passes(8, "c") && passes(9, "v") && passes(8, "ㅊ") && !KeyRouting.menuTargetsEditor(s)
              && s.timeline == tText && s.clipClipboard == cbText)
        w.makeFirstResponder(nil); field.removeFromSuperview(); await LaneSelfTest.settle()

        // 7. 한글 2벌식 모양(ㅊ·ㅍ)도 키 코드로 같은 동작
        s.select(right.id); s.seek(to: s.durationFrames)
        let p4 = s.playhead
        await cmd(8, "ㅊ"); await cmd(9, "ㅍ")
        check("korean.copyPaste", s.timeline.clips.contains { $0.start == p4 } && s.history.undoDepth == depth0 + 4)

        // 8. 프로젝트를 바꾸면 클립보드를 비운다. 새 프로젝트에서 ⌘V는 아무것도 바꾸지 않는다
        _ = LaneSelfTest.menuItem("새 프로젝트")
        if await LaneSelfTest.waitUntil(5, { s.alerts.isShowing }) { try? await Task.sleep(nanoseconds: 300_000_000); s.alerts.pressButton(2) }   // 저장 안 함
        _ = await LaneSelfTest.waitUntil(5) { s.timeline.isEmpty && !s.isDirty && !s.alerts.isShowing }
        let tNew = s.timeline
        await cmd(9, "v")
        check("replace.clearsClipboard", s.clipClipboard == nil && s.timeline == tNew && s.history.undoDepth == 0 && !s.isDirty, s.statusMessage ?? "")
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true, detail: "키는 앱 이벤트 큐(postEvent), 메뉴는 NSMenu.performActionForItem")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("copypaste-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
