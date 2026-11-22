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

        // 4. 같은 곳에 다시 ⌘V(TIMELINE-OVERWRITE-PASTE-01, 소유자 승인 덮어쓰기): 같은 레인의 겹친 구간만 바꾼다 — 앞서 붙여 넣은 쌍이
        //    완전히 덮여 새 쌍으로 바뀌고 새 레인은 없다(같은 한 단계). 실행 취소 → 원래대로, 다시 실행 → 같은 상태
        await cmd(9, "v")
        let t2 = s.timeline
        let nv2 = t2.clips.first { $0.start == p1 }, na2 = nv2.flatMap { t2.partner(of: $0.id) }
        let others1 = t1.clips.filter { $0.id != nv?.id } + t1.audioClips.filter { $0.id != na?.id }
        check("paste.overlapOverwritesSameLanesOneStep", t2.lanes.count == t1.lanes.count && s.history.undoDepth == depth0 + 2 &&
              nv2 != nil && na2?.start == p1 && nv2?.lane == nv?.lane && na2?.lane == na?.lane && nv2?.id != nv?.id &&
              t2.clip(nv?.id ?? UUID()) == nil && t2.clip(na?.id ?? UUID()) == nil && others1.allSatisfy { t2.clip($0.id) == $0 },
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

extension CopyPasteSelfTest {
    /// TIMELINE-EDITING-01: magnetic snapping (move and trim), the magnet toggle and paste at the playhead, on a
    /// project built from real media copies through the app's import and "+" paths:
    ///   V1: MP4 video [0,300)  image [300,450)      A1: MP4 audio [0,300) (linked)  WAV [300,500)
    /// Gestures go through the store's begin/update/commit/cancel paths with the view's zoom-scaled distance
    /// (`TimelineNSView.snapDistance` / pixels per frame). Each check is recorded; later checks still run.
    static func timelineEditingChecks(png: URL, wav: URL, mp4: URL) async -> [Check] {
        var checks: [Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            print(pass ? "PASS" : "FAIL", "[edit]", name, detail.isEmpty ? "" : "(\(detail))")
            fflush(stdout)   // a later crash cannot erase earlier results
            checks.append(Check(name: name, pass: pass, detail: detail))
        }
        let store = ProjectStore.shared
        func wait(_ s: Double, _ c: () -> Bool) async -> Bool { await LaneSelfTest.waitUntil(s, c) }
        func threshold(_ zoom: Double) -> Double { Double(TimelineNSView.snapDistance) / zoom }

        // Setup.
        store.importFiles([png, wav, mp4])
        let imported = await wait(180) {
            store.importProgress == nil && !store.imageImportBusy && store.timeline.media.count >= 2 &&
                ProjectPersistence.references(store.timeline).contains { $0.kind == .stillImage }
        }
        guard imported, let movie = store.timeline.media.first(where: { $0.hasVideo }),
              let sound = store.timeline.media.first(where: { $0.hasAudio && !$0.hasVideo }),
              let imageID = ProjectPersistence.references(store.timeline).first(where: { $0.kind == .stillImage })?.id else {
            check("imported PNG, WAV and MP4 copies", false); return checks
        }
        store.addToTimeline(movie.id)
        guard await wait(10, { store.timeline.clips.contains { $0.mediaID == movie.id } }),
              let mv = store.timeline.clips.first(where: { $0.mediaID == movie.id }) else { check("placed MP4", false); return checks }
        store.commit({ try $0.trimming(clip: mv.id, sourceIn: 0, length: 300) }, focus: nil)
        store.addToTimeline(sound.id)
        guard await wait(10, { store.timeline.audioClips.contains { $0.mediaID == sound.id } }),
              let wc = store.timeline.audioClips.first(where: { $0.mediaID == sound.id }) else { check("placed WAV", false); return checks }
        store.commit({ try $0.trimming(clip: wc.id, sourceIn: 0, length: 200) }, focus: nil)
        store.addToTimeline(imageID)
        _ = await wait(10) { store.timeline.clips.contains { $0.mediaID == imageID } }
        let t0 = store.timeline
        guard let v = t0.clips.first(where: { $0.mediaID == movie.id }), let a = t0.audioClips.first(where: { $0.mediaID == movie.id }),
              let w = t0.audioClips.first(where: { $0.mediaID == sound.id }), let img = t0.clips.first(where: { $0.mediaID == imageID }) else {
            check("layout", false); return checks
        }
        let layoutOK = v.start == 0 && v.end == 300 && a.start == 0 && a.end == 300 && w.start == 300 && w.end == 500 &&
            img.start == 300 && img.end == 450 && v.lane == img.lane && a.lane == w.lane && v.link != nil && v.link == a.link
        check("layout V1 [0,300)+[300,450), A1 [0,300)+[300,500), MP4 pair linked", layoutOK,
              "v \(v.start)..<\(v.end) img \(img.start)..<\(img.end) a \(a.start)..<\(a.end) w \(w.start)..<\(w.end)")
        guard layoutOK else { return checks }
        store.seek(to: 377)
        _ = await wait(5) { store.playhead == 377 }

        func move(_ id: UUID, raw: Double, zoom: Double, commit: Bool = false) -> (start: Int, guide: Int?, timeline: Timeline) {
            store.beginGesture(select: id)
            store.updateFreeMove(id, delta: raw, lane: nil, snapFrames: threshold(zoom))
            let r = (store.timeline.clip(id)?.start ?? -1, store.snapGuide, store.timeline)
            if commit { store.commitGesture() } else { store.cancelGesture() }
            return r
        }
        func trim(_ id: UUID, _ edge: ProjectStore.TrimEdge, raw: Double, zoom: Double, commit: Bool = false) -> (clip: Clip?, guide: Int?, timeline: Timeline) {
            store.beginGesture(select: id)
            store.updateTrim(id, edge: edge, delta: Int(raw.rounded()), rawDelta: raw, snapFrames: threshold(zoom))
            let r = (store.timeline.clip(id), store.snapGuide, store.timeline)
            if commit { store.commitGesture() } else { store.cancelGesture() }
            return r
        }

        // 1. Cross-lane end alignment (image end 450 → WAV end 500 on A1), ON vs OFF.
        store.setSnapEnabled(true)
        let on = move(img.id, raw: 48.7, zoom: 4)
        check("snap ON: image end aligns with the WAV end on another lane", on.start == 350 && on.guide == 500, "start \(on.start), guide \(String(describing: on.guide))")
        store.setSnapEnabled(false)
        let off = move(img.id, raw: 48.7, zoom: 4)
        check("snap OFF: no snapping, nearest frame only", off.start == 349 && off.guide == nil, "start \(off.start)")
        store.setSnapEnabled(true)
        check("unchanged after cancelled gestures", store.timeline == t0)

        // 2. Snap to the playhead (377): start 300 + 76.6 → 377.
        let ph = move(img.id, raw: 76.6, zoom: 4)
        check("clip start snaps to the playhead", ph.start == 377 && ph.guide == 377, "start \(ph.start)")

        // 3. Zoom-independent screen distance: 1.3 frames off snaps at 4 px/frame (2 f) but not at 12 px/frame (0.67 f);
        //    10 frames off snaps at 0.5 px/frame (16 f) but not at 4 px/frame.
        let z12 = move(img.id, raw: 48.7, zoom: 12), z05 = move(img.id, raw: 40, zoom: 0.5), z4far = move(img.id, raw: 40, zoom: 4)
        check("same 8 pt distance at different zoom levels", z12.start == 349 && z12.guide == nil && z05.start == 350 && z05.guide == 500 &&
              z4far.start == 340 && z4far.guide == nil, "z12 \(z12.start) z0.5 \(z05.start) z4 \(z4far.start)")

        // 4. Several nearby targets: playhead 495 and WAV end 500 equidistant from the image end 497.5 → the smaller target, every time.
        store.seek(to: 495); _ = await wait(5) { store.playhead == 495 }
        let ties = (0..<3).map { _ in move(img.id, raw: 47.5, zoom: 2) }
        check("equidistant targets resolve deterministically (smaller target)", ties.allSatisfy { $0.start == 345 && $0.guide == 495 },
              ties.map { "\($0.start)/\(String(describing: $0.guide))" }.joined(separator: ","))
        let nearer = move(img.id, raw: 48.9, zoom: 2)   // end 498.9: 500 is nearer than 495
        check("the nearest target wins", nearer.start == 350 && nearer.guide == 500, "start \(nearer.start)")
        store.seek(to: 377); _ = await wait(5) { store.playhead == 377 }

        // 5. Frame boundaries without a target.
        store.setSnapEnabled(false)
        let r1 = move(img.id, raw: 60.4, zoom: 4), r2 = move(img.id, raw: 60.6, zoom: 4)
        store.setSnapEnabled(true)
        check("frame-accurate rounding without snapping", r1.start == 360 && r2.start == 361, "\(r1.start), \(r2.start)")

        // 6. Trimming: linked MP4 end to the playhead (both members), image end to the WAV end, source bounds, minimum length.
        store.seek(to: 260); _ = await wait(5) { store.playhead == 260 }
        let tv = trim(v.id, .end, raw: -38.6, zoom: 4)
        let pairEnd = tv.timeline.audioClips.first { $0.id == a.id }?.end
        check("trim end snaps to the playhead (linked pair trimmed together)", tv.clip?.end == 260 && pairEnd == 260 && tv.guide == 260,
              "video end \(String(describing: tv.clip?.end)), audio end \(String(describing: pairEnd))")
        let ti = trim(img.id, .end, raw: 48.8, zoom: 4)
        check("image end trim snaps to the WAV end on another lane", ti.clip?.end == 500 && ti.clip?.start == 300 && ti.guide == 500,
              "end \(String(describing: ti.clip?.end))")
        store.seek(to: 285); _ = await wait(5) { store.playhead == 285 }
        let tw = trim(w.id, .start, raw: -20, zoom: 0.5)   // target 285 is 5 frames away, but the WAV source has nothing before 0
        check("trim never extends beyond the source; no guide when the edge cannot land", tw.clip?.start == 300 && tw.clip?.sourceIn == 0 && tw.guide == nil,
              "start \(String(describing: tw.clip?.start)) guide \(String(describing: tw.guide))")
        let tmin = trim(img.id, .end, raw: -400, zoom: 4)
        check("trim keeps at least one frame", (tmin.clip?.length ?? 0) >= 1, "length \(String(describing: tmin.clip?.length))")
        store.setSnapEnabled(false)
        let toff = trim(img.id, .end, raw: 48.8, zoom: 4)
        store.setSnapEnabled(true)
        check("trim with snap OFF moves by whole frames only", toff.clip?.end == 499 && toff.guide == nil, "end \(String(describing: toff.clip?.end))")
        check("no media, lane or unrelated change from snapped edits", store.timeline == t0)

        // 7. Undo/Redo of a snapped move and the magnet locked during a gesture.
        store.seek(to: 377); _ = await wait(5) { store.playhead == 377 }
        let committed = move(img.id, raw: 76.6, zoom: 4, commit: true)
        let afterMove = store.timeline
        store.undo(); let undone = store.timeline == t0
        store.redo(); let redone = store.timeline == afterMove
        check("snapped move commits once and undoes/redoes exactly", committed.start == 377 && undone && redone && afterMove.clip(img.id)?.start == 377)
        store.undo()
        store.beginGesture(select: img.id)
        let rejected = !store.setSnapEnabled(false), unchanged = store.snapEnabled
        store.cancelGesture()
        let acceptedAfter = store.setSnapEnabled(false) && !store.snapEnabled && store.setSnapEnabled(true) && store.snapEnabled
        check("magnet change is rejected during a drag without mutating or crashing; accepted afterwards",
              rejected && unchanged && acceptedAfter, "rejected \(rejected), unchanged \(unchanged), acceptedAfter \(acceptedAfter)")

        // 8. Overwrite paste at the playhead (TIMELINE-OVERWRITE-PASTE-01). The playhead never passes the timeline end
        //    (500 here), so every position below lies inside [0, 500]. Each case is undone back to `t0`.
        func pasteAt(_ frame: Int) async -> (before: Timeline, after: Timeline, status: String?) {
            store.seek(to: frame); _ = await wait(5) { store.playhead == frame }
            let b = store.timeline
            store.pasteAtPlayhead()
            return (b, store.timeline, store.statusMessage)
        }
        func copy(_ id: UUID) { store.select(id); store.copySelection() }
        func untouched(_ before: Timeline, _ after: Timeline, except: Set<UUID>) -> Bool {
            (before.clips + before.audioClips).filter { !except.contains($0.id) }.allSatisfy { after.clip($0.id) == $0 }
        }
        func newClips(_ before: Timeline, _ after: Timeline) -> [Clip] {
            let old = Set((before.clips + before.audioClips).map(\.id))
            return (after.clips + after.audioClips).filter { !old.contains($0.id) }.sorted { $0.start < $1.start }
        }

        // 8a. Empty interval: the image (150) at 450 → [450,600) on V1, nothing replaced, no new lane.
        copy(img.id)
        let e1 = await pasteAt(450)
        let e1New = newClips(e1.before, e1.after)
        check("paste into an empty interval: starts at the playhead, nothing replaced, no new lane",
              e1New.count == 1 && e1New[0].start == 450 && e1New[0].length == 150 && e1New[0].lane == img.lane &&
              untouched(e1.before, e1.after, except: []) && e1.after.lanes == e1.before.lanes,
              e1New.map { "\($0.start)+\($0.length)" }.joined())
        store.undo()
        // 8b. Timeline end: playhead 500 → [500,650), timeline grows, nothing replaced.
        let e2 = await pasteAt(500)
        let e2New = newClips(e2.before, e2.after)
        check("paste at the timeline end (500) extends the timeline", e2New.first?.start == 500 && e2.after.durationFrames == 650 &&
              untouched(e2.before, e2.after, except: []), "duration \(e2.after.durationFrames)")
        store.undo()
        check("paste undo restores the timeline", store.timeline == t0)

        // Unlinked targets: split the image at 330 and the WAV at 320 (two undo steps, removed afterwards).
        store.commit({ try $0.splitting(clip: img.id, atFrame: 330) }, focus: nil)
        store.commit({ try $0.splitting(clip: w.id, atFrame: 320) }, focus: nil)
        let ts = store.timeline
        let imgA = ts.clips.first { $0.mediaID == imageID && $0.start == 300 }, imgB = ts.clips.first { $0.mediaID == imageID && $0.start == 330 }
        let wA = ts.audioClips.first { $0.mediaID == sound.id && $0.start == 300 }, wB = ts.audioClips.first { $0.mediaID == sound.id && $0.start == 320 }
        if let imgA, let imgB, let wA, let wB, wB.sourceIn == 20 {
            // 8c. Middle of one audio clip: WAV piece [300,320) (20 f, sourceIn 0) at 400 inside [320,500) (sourceIn 20).
            copy(wA.id)
            let m = await pasteAt(400)
            let left = m.after.audioClips.first { $0.mediaID == sound.id && $0.start == 320 }
            let right = m.after.audioClips.first { $0.mediaID == sound.id && $0.start == 420 }
            let pasted = m.after.audioClips.first { $0.mediaID == sound.id && $0.start == 400 }
            check("paste over the middle of one clip keeps both sides with exact sourceIn and length",
                  left?.id == wB.id && left?.sourceIn == 20 && left?.length == 80 && right?.sourceIn == 120 && right?.length == 80 &&
                  pasted?.sourceIn == 0 && pasted?.length == 20 && right?.lineageKey == wB.lineageKey &&
                  untouched(m.before, m.after, except: [wB.id]),
                  "left \(String(describing: left.map { "\($0.start)+\($0.length)@\($0.sourceIn)" })) right \(String(describing: right.map { "\($0.start)+\($0.length)@\($0.sourceIn)" }))")
            store.undo(); store.redo()
            let redoneMiddle = store.timeline == m.after
            store.undo()
            check("overwrite paste is one undo step and redoes exactly", redoneMiddle && store.timeline == ts)

            // 8d. Across two clips with partial overlap at both edges: image piece [330,450) (120) at 310 → [310,430).
            copy(imgB.id)
            let x = await pasteAt(310)
            let xa = x.after.clips.first { $0.id == imgA.id }, xb = x.after.clips.first { $0.mediaID == imageID && $0.start == 430 }
            check("paste across two clips trims the left edge and keeps the right remainder", xa?.start == 300 && xa?.length == 10 &&
                  xb?.id == imgB.id && xb?.length == 20 && xb?.sourceIn == 0 && untouched(x.before, x.after, except: [imgA.id, imgB.id]),
                  "left \(String(describing: xa?.length)) right \(String(describing: xb.map { "\($0.start)+\($0.length)" }))")
            store.undo()
            // 8e. Fully covered clip: the same 120 f at 300 → [300,420): [300,330) removed, [330,450) keeps [420,450).
            let f = await pasteAt(300)
            let fRight = f.after.clips.first { $0.mediaID == imageID && $0.start == 420 }
            check("a fully covered clip is removed; the partially covered one keeps its remainder",
                  f.after.clip(imgA.id) == nil && fRight?.id == imgB.id && fRight?.length == 30 && untouched(f.before, f.after, except: [imgA.id, imgB.id]),
                  "status \(f.status ?? "-")")
            store.undo()

            // 8f. Linked pair refused when only one member would change: image piece over the MP4 video middle.
            copy(imgA.id)
            let r = await pasteAt(100)
            check("overwriting one member of a linked pair is refused with no change", r.after == r.before &&
                  r.status == EditError.overwriteBreaksLink.description, "status \(r.status ?? "-")")

            // 8g. Linked pair over linked pair (Snap OFF): the MP4 pair at 100 → [100,400) on V1/A1.
            copy(v.id)
            store.setSnapEnabled(false)
            let lp = await pasteAt(100)
            store.setSnapEnabled(true)
            let ov = lp.after.clips.first { $0.id == v.id }, oa = lp.after.audioClips.first { $0.id == a.id }
            let pv = lp.after.clips.first { $0.mediaID == movie.id && $0.start == 100 }, pa = lp.after.audioClips.first { $0.mediaID == movie.id && $0.start == 100 }
            let imgTail = lp.after.clips.first { $0.mediaID == imageID && $0.start == 400 }
            let wTail = lp.after.audioClips.first { $0.mediaID == sound.id && $0.start == 400 }
            check("linked pair overwrite keeps the original pair linked on [0,100) and places a new linked pair (Snap OFF)",
                  ov?.length == 100 && oa?.length == 100 && ov?.link != nil && ov?.link == oa?.link &&
                  pv?.sourceIn == v.sourceIn && pv?.length == 300 && pa?.length == 300 && pv?.link != nil && pv?.link == pa?.link && pv?.link != v.link &&
                  pv?.lane == v.lane && pa?.lane == a.lane && lp.after.lanes == lp.before.lanes,
                  "orig \(String(describing: ov?.length))/\(String(describing: oa?.length)) new \(String(describing: pv?.start))")
            check("overwrite keeps source offsets of the remaining parts on other clips", imgTail?.sourceIn == 0 && imgTail?.length == 50 &&
                  wTail?.sourceIn == 100 && wTail?.length == 100 && lp.after.isValid,
                  "image tail \(String(describing: imgTail.map { "\($0.start)+\($0.length)" })) wav tail \(String(describing: wTail.map { "\($0.start)+\($0.length)@\($0.sourceIn)" }))")
            store.undo()
            check("linked overwrite undone exactly", store.timeline == ts)
        } else { check("split setup for overwrite cases", false) }
        store.undo(); store.undo()
        check("split setup undone back to the original layout", store.timeline == t0)

        // 8h. Shift + playhead snapping on the ruler (store path used by the ruler view).
        func scrub(_ raw: Double, zoom: Double, shift: Bool) -> (frame: Int, guide: Int?) {
            store.scrubPlayhead(raw: raw, snapFrames: threshold(zoom), shift: shift)
            let r = (store.playhead, store.snapGuide)
            store.endScrub()
            return r
        }
        let sOn = scrub(298.5, zoom: 4, shift: true), sPlain = scrub(298.5, zoom: 4, shift: false), sPlain2 = scrub(123.4, zoom: 4, shift: false)
        store.setSnapEnabled(false)
        let sOff = scrub(298.5, zoom: 4, shift: true)
        store.setSnapEnabled(true)
        check("Shift + magnet snaps the playhead to a clip boundary and shows the guide", sOn.frame == 300 && sOn.guide == 300 && store.snapGuide == nil,
              "\(sOn.frame)/\(String(describing: sOn.guide))")
        check("ordinary scrubbing is unchanged (nearest frame, no guide)", sPlain.frame == 299 && sPlain.guide == nil && sPlain2.frame == 123)
        check("Shift with the magnet off does not snap", sOff.frame == 299 && sOff.guide == nil)
        let sz05 = scrub(290, zoom: 0.5, shift: true), sz12a = scrub(299.5, zoom: 12, shift: true), sz12b = scrub(299.2, zoom: 12, shift: true)
        check("Shift snap uses the same 8 pt distance at different zoom levels", sz05.frame == 300 && sz12a.frame == 300 && sz12b.frame == 299,
              "\(sz05.frame), \(sz12a.frame), \(sz12b.frame)")
        let lane = scrub(498.6, zoom: 4, shift: true)
        check("Shift snap includes boundaries on other lanes (WAV end on A1)", lane.frame == 500 && lane.guide == 500)

        // 8i. TIMELINE-UI-POLISH-01: Shift-snap edge markers (vertical ▼/▲ pair per matching clip edge) and no gap decoration.
        func marked(_ raw: Double, zoom: Double, shift: Bool) -> (frame: Int, guide: Int?, markers: [ProjectStore.SnapMarker]) {
            store.scrubPlayhead(raw: raw, snapFrames: threshold(zoom), shift: shift)
            return (store.playhead, store.snapGuide, store.snapMarkers)
        }
        func ids(_ m: [ProjectStore.SnapMarker]) -> Set<String> { Set(m.map { "\($0.clip.uuidString.prefix(4))\($0.edge == .start ? "s" : "e")" }) }
        func key(_ id: UUID, _ e: ProjectStore.TrimEdge) -> String { "\(id.uuidString.prefix(4))\(e == .start ? "s" : "e")" }
        let mEnd = marked(448.7, zoom: 4, shift: true)
        check("markers: end-edge snap marks only that clip end (image end 450)", mEnd.frame == 450 && mEnd.guide == 450 &&
              mEnd.markers.map(\.clip) == [img.id] && mEnd.markers.first?.edge == .end && mEnd.markers.first?.lane == img.lane,
              "\(mEnd.markers)")
        let mMulti = marked(298.5, zoom: 4, shift: true)
        check("markers: shared frame 300 marks every matching edge on V1 and A1 (start and end), nothing else",
              mMulti.frame == 300 && ids(mMulti.markers) == [key(v.id, .end), key(img.id, .start), key(a.id, .end), key(w.id, .start)] &&
              Set(mMulti.markers.compactMap(\.lane)) == Set([v.lane, a.lane].compactMap { $0 }),
              "\(ids(mMulti.markers))")
        let mStart = marked(1.2, zoom: 4, shift: true)
        check("markers: start-edge snap at 0 marks the MP4 pair starts", mStart.frame == 0 &&
              ids(mStart.markers) == [key(v.id, .start), key(a.id, .start)], "\(ids(mStart.markers))")
        let mRelease = marked(298.5, zoom: 4, shift: false)
        check("markers: releasing Shift clears guide and markers (ordinary scrub frame)", mRelease.frame == 299 && mRelease.guide == nil && mRelease.markers.isEmpty)
        let mAway = marked(380, zoom: 4, shift: true)
        check("markers: no snap within distance → no markers", mAway.frame == 380 && mAway.guide == nil && mAway.markers.isEmpty)
        _ = marked(298.5, zoom: 4, shift: true)
        store.setSnapEnabled(false)
        let offCleared = store.snapMarkers.isEmpty && store.snapGuide == nil
        let mOff = marked(298.5, zoom: 4, shift: true)
        store.setSnapEnabled(true)
        check("markers: turning the magnet off clears them and Shift then adds none", offCleared && mOff.markers.isEmpty && mOff.frame == 299)
        _ = marked(298.5, zoom: 4, shift: true); store.endScrub()
        check("markers: scrub end clears them", store.snapMarkers.isEmpty && store.snapGuide == nil)
        _ = marked(298.5, zoom: 4, shift: true)
        store.beginGesture(select: img.id); let gestureCleared = store.snapMarkers.isEmpty; store.cancelGesture()
        check("markers: a clip drag starting clears them; cancel leaves none and the timeline unchanged",
              gestureCleared && store.snapMarkers.isEmpty && store.timeline == t0)
        let m12 = marked(299.5, zoom: 12, shift: true), m12b = marked(299.2, zoom: 12, shift: true); store.endScrub()
        check("markers: snap choice unchanged at other zoom levels (12×: 299.5 snaps, 299.2 does not)",
              m12.frame == 300 && m12.markers.count == 4 && m12b.frame == 299 && m12b.markers.isEmpty)
        // Geometry on a standalone timeline view: ▼ above the clip top and ▲ below its bottom, centred on the edge X, at any zoom.
        let view = TimelineNSView(store: store)
        _ = marked(298.5, zoom: 4, shift: true)
        let ds = TimelineDrawState(store: store)
        store.endScrub()
        view.state = ds   // lane rects come from the view's own state (otherwise default lanes)
        var geoOK = true, geoDetail = ""
        for zoom in [0.5, 4.0, 12.0] {
            view.pixelsPerFrame = CGFloat(zoom)
            let g = view.snapMarkerGeometry(ds, frame: 300)
            let edgeX = view.x(300)
            let ok = g.count == 4 && g.allSatisfy { e in
                guard let r = view.laneRect(e.marker.lane) else { return false }
                return abs(e.above.midX - edgeX) < 0.01 && abs(e.below.midX - edgeX) < 0.01 &&
                    abs(e.above.maxY - r.minY) < 0.01 && abs(e.below.minY - r.maxY) < 0.01 &&
                    e.above.height <= TimelineNSView.laneGap && e.below.height <= TimelineNSView.laneGap
            }
            if !ok { geoOK = false; geoDetail += "zoom \(zoom): \(g.map { ($0.above, $0.below) }) " }
        }
        check("marker geometry: vertical pair centred on the boundary X, touching clip top/bottom, at 0.5×/4×/12×", geoOK, geoDetail)
        check("marker geometry: markers are drawn only at their own snapped frame", view.snapMarkerGeometry(ds, frame: 299).isEmpty)
        // Gap decoration removed; hit-testing unchanged.
        view.pixelsPerFrame = 2; view.state = TimelineDrawState(store: store); view.fullDrawForTest = true
        view.setFrameSize(NSSize(width: TimelineNSView.inset * 2 + 700 * 2, height: TimelineNSView.contentHeight(store.timeline.lanes)))
        func px(_ p: NSPoint) -> NSColor? {
            let r = NSRect(x: p.x.rounded(.down), y: p.y.rounded(.down), width: 2, height: 2)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: r) else { return nil }
            view.cacheDisplay(in: r, to: rep); return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
        }
        func near(_ p: NSColor?, _ q: NSColor?) -> Bool {
            guard let p, let q else { return false }
            return abs(p.redComponent - q.redComponent) < 0.02 && abs(p.greenComponent - q.greenComponent) < 0.02 && abs(p.blueComponent - q.blueComponent) < 0.02
        }
        let v1Mid = view.laneRect(v.lane)?.midY ?? 0
        // V1 gap [450,500) vs V1 past the timeline end (600): both plain background now (previously dark fill + hatch + "빈틈").
        let gapPx = [455, 470, 490].map { px(NSPoint(x: view.x($0) + 0.5, y: v1Mid)) }, past = px(NSPoint(x: view.x(600), y: v1Mid))
        let clipPx = px(NSPoint(x: view.x(400), y: v1Mid))
        check("empty V1 region draws the plain background (no fill/hatch/label), clips still drawn",
              gapPx.allSatisfy { near($0, past) } && !near(clipPx, past), "gap \(gapPx.map { $0?.description ?? "nil" }) past \(String(describing: past))")
        check("hit-testing unchanged: gap is empty, clip bodies still hit", view.clipHit(NSPoint(x: view.x(475), y: v1Mid)) == nil &&
              view.clipHit(NSPoint(x: view.x(400), y: v1Mid))?.0 == img.id && store.timeline.gaps(inLane: v.lane ?? UUID()).contains(450..<500))
        // 8j. WAVEFORM-01 (separate helper, so its names cannot collide with this function's locals).
        for r in await waveformChecks(store: store, view: view, soundID: sound.id, movieID: movie.id, wav: w, mp4Audio: a) { check(r.name, r.pass, r.detail) }
        // 9. Existing V / C tools.
        let cutOK = store.setTool(.cut) && store.tool == .cut && store.cutCheck(img.id, atFrame: 400) == .valid
        let selOK = store.setTool(.selection) && store.tool == .selection
        check("V/C tools unchanged (C cut check valid inside a clip, back to V)", cutOK && selOK)
        return checks
    }

    /// WAVEFORM-01 checks on the same project: real peaks for the WAV and for the MP4's linked audio, one analysis per
    /// unchanged source, column mapping through a split, drawing, and (on separate stores) cancellation and failure.
    static func waveformChecks(store: ProjectStore, view: TimelineNSView, soundID: UUID, movieID: UUID, wav: Clip, mp4Audio: Clip) async
        -> [(name: String, pass: Bool, detail: String)] {
        var out: [(name: String, pass: Bool, detail: String)] = []
        func add(_ name: String, _ pass: Bool, _ detail: String = "") { out.append((name, pass, detail)) }   // printed once by the caller's check()
        guard let sound = store.mediaByID[soundID], let movie = store.mediaByID[movieID] else { add("waveform: sources available", false); return out }
        _ = store.waveforms.state(for: sound); _ = store.waveforms.state(for: movie)
        func peaks(_ m: MediaAsset) -> WaveformPeaks? { if case .ready(let p) = store.waveforms.state(for: m) { return p }; return nil }
        func short(_ s: WaveformStore.State) -> String {
            switch s {
            case .pending: return "pending"
            case .ready(let p): return "ready \(p.channelCount) ch"
            case .unavailable(let why): return "unavailable \(why)"
            }
        }
        let ready = await LaneSelfTest.waitUntil(120) { peaks(sound) != nil && peaks(movie) != nil }
        guard ready, let ps = peaks(sound), let pm = peaks(movie) else {
            add("waveform: WAV and MP4 audio peaks ready", false, "\(short(store.waveforms.state(for: sound))) / \(short(store.waveforms.state(for: movie)))"); return out
        }
        let wavSeconds = Double(ps.sampleCount) / Double(ps.sampleRate)
        let expected = sound.audioSampleCount.map { Double($0) / Double(sound.audioSampleRate ?? 48_000) } ?? -1
        let loud = ps.envelope(channel: 0, samples: 0..<ps.sampleCount).map { $0.max > 0.01 } ?? false
        add("waveform: WAV peaks are real stereo data of the source length", ps.channelCount == (sound.audioChannels ?? 2) && ps.channelCount == 2 &&
            abs(wavSeconds - expected) < 0.05 && loud, "channels \(ps.channelCount) seconds \(wavSeconds) vs \(expected)")
        let movieLoud = pm.envelope(channel: 0, samples: 0..<pm.sampleCount).map { $0.max > 0.01 } ?? false
        add("waveform: linked MP4 audio clip has its own source peaks", pm.channelCount >= 1 && movieLoud && mp4Audio.mediaID == movieID,
            "channels \(pm.channelCount) samples \(pm.sampleCount)")
        let lr = (0..<ps.channelCount).map { ch in ps.envelope(channel: ch, samples: 0..<ps.sampleCount)?.max ?? -1 }
        add("waveform: stereo channels are kept separately (not mixed)", lr.count == 2 && lr.allSatisfy { $0 >= 0 }, "L/R max \(lr)")
        #if DEBUG
        let started = store.waveforms.analysesStartedForTest
        for _ in 0..<50 { _ = store.waveforms.state(for: sound); _ = store.waveforms.state(for: movie) }
        add("waveform: an unchanged source is analysed once, not per redraw", store.waveforms.analysesStartedForTest == started && store.waveforms.isIdleForTest)
        #endif
        // Column mapping: the WAV clip's columns follow sourceIn + timeline offset at several zoom levels, and a split keeps them.
        let state0 = TimelineDrawState(store: store)
        view.state = state0
        var mapOK = true, mapDetail = ""
        for zoom in [0.5, 2.0, 12.0] {
            view.pixelsPerFrame = CGFloat(zoom)
            let cols = view.waveformColumns(wav, rate: ps.sampleRate, visible: view.bounds.union(NSRect(x: 0, y: 0, width: 100_000, height: 10)))
            let first = cols.first?.samples.lowerBound, expectFirst = wav.sourceIn * 1_600
            let mid = view.x(wav.start + 50)
            let atMid = cols.first { $0.x <= mid && mid < $0.x + 1 }?.samples.lowerBound ?? -1
            let expectMid = WaveformPeaks.sample(atSourceFrame: Double(wav.sourceIn + 50) + Double((mid.rounded(.down) - mid) / CGFloat(zoom)), rate: ps.sampleRate)
            if first != expectFirst || abs(atMid - expectMid) > 1_600 { mapOK = false; mapDetail += "z\(zoom) first \(String(describing: first)) mid \(atMid)/\(expectMid) " }
        }
        add("waveform: columns follow the clip's source window at 0.5×/2×/12× zoom", mapOK, mapDetail)
        view.pixelsPerFrame = 2
        let before = view.waveformColumns(wav, rate: ps.sampleRate, visible: NSRect(x: 0, y: 0, width: 100_000, height: 10))
        store.commit({ try $0.splitting(clip: wav.id, atFrame: wav.start + 70) }, focus: nil)
        let pieces = store.timeline.audioClips.filter { $0.mediaID == soundID }.sorted { $0.start < $1.start }
        let after = pieces.flatMap { view.waveformColumns($0, rate: ps.sampleRate, visible: NSRect(x: 0, y: 0, width: 100_000, height: 10)) }
        let keyed = Dictionary(after.map { ($0.x, $0.samples) }, uniquingKeysWith: { a, _ in a })
        let splitOK = pieces.count == 2 && before.allSatisfy { col in keyed[col.x].map { $0.lowerBound == col.samples.lowerBound } ?? true } &&
            before.filter { keyed[$0.x] != nil }.count >= before.count - 2
        store.undo()
        add("waveform: split pieces show the same source samples at the same timeline position", splitOK && store.timeline.clip(wav.id) == wav,
            "pieces \(pieces.count) columns \(before.count)/\(after.count)")
        // Drawing: the WAV clip draws waveform pixels (compare with the same state without sources).
        view.state = TimelineDrawState(store: store); view.fullDrawForTest = true
        view.setFrameSize(NSSize(width: TimelineNSView.inset * 2 + 700 * 2, height: TimelineNSView.contentHeight(store.timeline.lanes)))
        func column(_ x: CGFloat, _ r: NSRect) -> [NSColor?] {
            stride(from: r.minY + 3, to: r.maxY - 3, by: 1).map { y -> NSColor? in
                let q = NSRect(x: x.rounded(.down), y: y.rounded(.down), width: 1, height: 1)
                guard let rep = view.bitmapImageRepForCachingDisplay(in: q) else { return nil }
                view.cacheDisplay(in: q, to: rep); return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
            }
        }
        let laneR = view.laneRect(wav.lane) ?? .zero
        // the three loudest frames of the clip (left channel), so the check does not depend on a quiet passage
        let loudest = (0..<wav.length).map { f -> (Int, Float) in
            let k = wav.sourceIn + f
            return (f, ps.envelope(channel: 0, samples: (k * 1_600)..<((k + 1) * 1_600))?.max ?? 0)
        }.sorted { $0.1 > $1.1 }.prefix(3)
        let xs = loudest.map { view.x(wav.start + $0.0) + 0.5 }
        let withWave = xs.map { column($0, laneR) }
        var bare = TimelineDrawState(store: store); bare.media = [:]
        view.state = bare
        let without = xs.map { column($0, laneR) }
        view.state = TimelineDrawState(store: store)
        func same(_ p: NSColor?, _ q: NSColor?) -> Bool {
            guard let p, let q else { return false }
            return abs(p.redComponent - q.redComponent) < 0.02 && abs(p.greenComponent - q.greenComponent) < 0.02 && abs(p.blueComponent - q.blueComponent) < 0.02
        }
        let changed = zip(withWave, without).map { a, b in zip(a, b).filter { !same($0, $1) }.count }
        add("waveform: the WAV clip draws a filled waveform (pixels differ from the clip without peaks)", xs.count == 3 && changed.allSatisfy { $0 >= 4 },
            "changed px per column \(changed) at peak \(loudest.map(\.1))")
        // Separate stores: cancellation of a pending analysis and an unreadable source.
        let blocking = WaveformStore()
        blocking.analyzer = { _, _ in
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 5_000_000) }
            throw SpectrumAnalysisError.cancelled
        }
        let pendingFirst = blocking.state(for: sound) == .pending
        blocking.retain([])
        add("waveform: removing a source cancels its pending analysis", pendingFirst && blocking.isIdleForTest && blocking.revision > 0)
        let failing = WaveformStore()
        failing.analyzer = { _, _ in throw SpectrumAnalysisError.noAudioTrack }
        _ = failing.state(for: sound)
        let failed = await LaneSelfTest.waitUntil(5) { if case .unavailable = failing.state(for: sound) { return true }; return false }
        add("waveform: an unreadable source becomes unavailable (no fabricated peaks)", failed)
        return out
    }
}
#endif
