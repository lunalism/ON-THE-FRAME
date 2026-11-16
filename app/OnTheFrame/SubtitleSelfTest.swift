#if DEBUG && OTF_SUBTITLE_DIAGNOSTICS
import AppKit
import AVFoundation
import OnTheFrameEngine
import SwiftUI

/// 자막 자체 검사(2026-10-22, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFSubtitleTest`.
/// 실제 키·마우스 이벤트(앱 이벤트 큐), 타임라인 메뉴, 글 칸(NSTextView)을 지난다. 생성 fixture(otf-TA)만, 저장은 일회용 폴더에만.
/// - 한국어 입력은 입력 소스를 바꾸지 않고 글 칸의 NSTextInputClient(setMarkedText·insertText)로 흉내 낸다(실제 입력기 조합이 아님).
/// - 프리뷰는 프로세스 안 상태(동기 층의 묶인 항목·층 수·멈춘 시각의 불투명도)만 본다. 화면에 보이는지는 소유자 관찰 몫이다.
/// 결과는 <폴더>/subtitle-result.json.
@MainActor
enum SubtitleSelfTest {
    typealias Check = LaneSelfTest.Check

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { return finish(folder, [Check(name: "setup.window", pass: false, detail: "")]) }
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, [LaneSelfTest.lostFocus("setup")]) }

        // 준비: 영상+소리 클립(120프레임, V1·A1의 0)
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        guard let asset = s.assets.first else { return finish(folder, [Check(name: "setup.import", pass: false, detail: "")]) }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        s.addToTimeline(asset.id)
        await LaneSelfTest.settle()
        guard s.timeline.clips.count == 1, let tv = LaneSelfTest.find(TimelineNSView.self, w.contentView) else {
            return finish(folder, [Check(name: "setup.place", pass: false, detail: "")])
        }
        tv.enclosingScrollView?.contentView.scroll(to: .zero)
        if let sv = tv.enclosingScrollView { sv.reflectScrolledClipView(sv.contentView) }
        await LaneSelfTest.settle()
        let v1 = Lane.videoID

        func pt(_ lane: UUID, _ frame: Int, dx: CGFloat = 0.3) -> NSPoint {
            guard let r = tv.laneRect(lane) else { return .zero }
            return tv.convert(NSPoint(x: tv.x(frame) + dx, y: r.midY), to: nil)
        }
        func key(_ code: UInt16, _ ch: String, _ mods: NSEvent.ModifierFlags = []) async { await LaneSelfTest.key(code, ch, mods, w) }
        func click(_ p: NSPoint) async { await LaneSelfTest.mouse(.leftMouseDown, p, w); await LaneSelfTest.mouse(.leftMouseUp, p, w) }
        func drag(_ a: NSPoint, _ b: NSPoint) async {
            await LaneSelfTest.mouse(.leftMouseDown, a, w)
            let mid = NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            await LaneSelfTest.mouse(.leftMouseDragged, mid, w); await LaneSelfTest.mouse(.leftMouseDragged, b, w)
            await LaneSelfTest.mouse(.leftMouseUp, b, w)
        }
        func focusTimeline() async { w.makeFirstResponder(tv); await LaneSelfTest.settle() }
        func previewSettled() async -> Bool { await LaneSelfTest.waitUntil(20) { s.appliedGeneration == s.generation && s.player.currentItem != nil } }

        guard let pv = LaneSelfTest.find(SubtitlePreviewView.self, w.contentView) else { return finish(folder, [Check(name: "setup.previewView", pass: false, detail: "")]) }
        /// 출력 좌표 → 창 좌표(프리뷰 보기의 실제 영상 사각형, 여백·크기 반영)
        func win(_ o: CGPoint) -> NSPoint { pv.convert(pv.mapping.view(o), to: nil) }
        func ed() -> NSTextView? { pv.editor }
        func type(_ text: String) { ed()?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        func layerHidden(_ id: UUID) -> Bool? { s.previewHost?.subtitleLayerForTest(id)?.isHidden }
        /// 편집 칸 사각형(프리뷰 보기 좌표). 칸은 출력 화면 크기 자르기 보기 안에 있다.
        func edRect() -> CGRect { ed().map { pv.canvasClip.convert($0.frame, to: pv) } ?? .zero }
        /// 편집 칸 글꼴(배율 반영)의 줄 높이·글자 하나 폭(시스템 조판 값)
        func nsLine() -> CGFloat { ed().flatMap { e in e.font.map { e.layoutManager?.defaultLineHeight(for: $0) ?? 0 } } ?? 0 }
        func charW() -> CGFloat { ed()?.font.map { ceil(NSAttributedString(string: "가", attributes: [.font: $0]).size().width) } ?? 0 }
        func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1.01) -> Bool { abs(a - b) <= tol }

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 1. T(키 코드 17)·ㅅ: 도구만 바꾼다. 타임라인·기록·선택 그대로
        await focusTimeline()
        let t0 = s.timeline, d0 = s.history.undoDepth
        await key(17, "t"); let afterT = s.tool
        await key(9, "v")
        await key(17, "ㅅ"); let afterKo = s.tool
        check("tool.tKeySelectsTextOnly", afterT == .text && afterKo == .text && s.timeline == t0 && s.history.undoDepth == d0 && s.timeline.subtitles.isEmpty && s.inlineEdit == nil,
              "t \(afterT) ㅅ \(afterKo) subs \(s.timeline.subtitles.count)")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 2. 정정(§44): 텍스트 도구로 타임라인을 눌러도 자막을 만들지 않는다
        await click(pt(v1, 30))
        check("timeline.textClickDoesNotCreate", s.timeline.subtitles.isEmpty && s.timeline.lanes(.subtitle).isEmpty && s.history.undoDepth == d0 && s.inlineEdit == nil && ed() == nil)

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 3. 좌표: 보기 ↔ 출력이 실제 영상 사각형을 따른다. 검은 여백 누름은 아무것도 하지 않는다
        let m = pv.mapping, vr = m.videoRect
        let bar: NSPoint? = vr.minX > 3 ? NSPoint(x: vr.minX / 2, y: vr.midY) : (vr.minY > 3 ? NSPoint(x: vr.midX, y: vr.minY / 2) : nil)
        if let bar {
            await click(pv.convert(bar, to: nil))
            check("coords.letterboxIgnored", s.inlineEdit == nil && ed() == nil && m.output(bar) == nil, "bar \(bar) video \(vr)")
        } else { check("coords.letterboxIgnored", true, "보기와 영상 비율이 같아 여백 없음(검사 생략) video \(vr) bounds \(pv.bounds)") }

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 4. T로 프리뷰 누름(재생 헤드 30, 출력 (960, 940)): 진짜 3초 빈 자막 + 새 레인 S1이 문서·타임라인에 바로(한 단계), 고름, 그 자리 편집 칸
        s.seek(to: 30); await LaneSelfTest.settle()
        let o1 = CGPoint(x: 960, y: 940)
        await click(win(o1))
        _ = await LaneSelfTest.waitUntil(3) { ed() != nil && w.firstResponder === ed() }
        let lineH = SubtitleRenderer.lineHeight(for: .default) * Double(m.scale)
        let caretView = m.view(o1)
        let edFrame = edRect()
        let made = s.timeline.subtitles.first
        _ = await LaneSelfTest.waitUntil(2) { tv.state?.timeline.subtitles.count == 1 }
        check("create.immediateItemAndLane", made?.text == "" && made?.start == 30 && made?.length == 90 && s.timeline.subtitles.count == 1 && s.timeline.lanes(.subtitle).count == 1
              && s.history.undoDepth == d0 + 1 && s.selection == made?.id && s.inlineEdit?.id == made?.id && tv.state?.timeline.subtitles.count == 1 && ed()?.string == "",
              "subs \(s.timeline.subtitles.map { [$0.start, $0.length] }) lanes \(s.timeline.lanes(.subtitle).count) depth \(s.history.undoDepth - d0) timelineView \(tv.state?.timeline.subtitles.count ?? -1)")
        check("create.inlineEditorAtClick", ed() != nil && w.firstResponder === ed()
              && abs(edFrame.midX - caretView.x) < 2 && abs((edFrame.maxY - lineH / 2) - caretView.y) < lineH * 0.35,
              "frame \(edFrame) click \(caretView) lineH \(lineH)")
        // 점 글자(§44.6): 빈 칸 = 글자 하나 폭 + 캐럿 몫, 한 줄 높이. 출력 화면 자르기 보기 안, 경계도 출력 화면 안
        let line0 = nsLine(), cw0 = charW()
        let outline0 = pv.editorOutline ?? .null
        check("geometry.emptyDraftIsOneCharCaret", near(edFrame.width, cw0 + 2, 1.5) && near(edFrame.height, ceil(line0)) && edFrame.width < m.videoRect.width / 10
              && ed()?.superview === pv.canvasClip && pv.canvasClip.frame == m.videoRect && pv.canvasClip.clipsToBounds && m.videoRect.contains(outline0),
              "frame \(edFrame) charW \(cw0) line \(line0) outline \(outline0) video \(m.videoRect)")
        guard let sid = made?.id, let s1 = s.timeline.lanes(.subtitle).first?.id else { return finish(folder, checks) }
        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 5. Esc: 시작 글자("")로, 자막·레인은 남음(지우지 않음, 기록 그대로). 빈 채로 ⌘Return도 기록 없음
        await key(53, "\u{1b}")
        check("create.escKeepsItemAndLane", ed() == nil && s.inlineEdit == nil && s.timeline.subtitle(sid)?.text == "" && s.timeline.laneInfo(s1) != nil && s.history.undoDepth == d0 + 1,
              "editor \(ed() != nil) subs \(s.timeline.subtitles.count) depth \(s.history.undoDepth - d0)")
        await click(win(o1)); _ = await LaneSelfTest.waitUntil(3) { ed() != nil }   // 빈 자막을 다시 누름: 새로 만들지 않고 고침(빈 자막 누름 상자)
        let reEdit = s.inlineEdit?.id == sid && s.timeline.subtitles.count == 1
        await key(36, "\r", [.command])
        check("create.emptyCommitKeepsItemNoStep", reEdit && ed() == nil && s.timeline.subtitle(sid)?.text == "" && s.history.undoDepth == d0 + 1 && s.timeline.subtitles.count == 1,
              "reEdit \(reEdit) depth \(s.history.undoDepth - d0)")
        // 빈 자막은 그리지 않는다(프리뷰 층 없음), 타임라인 표시는 "빈 자막"(저장 글자 아님)
        _ = await previewSettled()
        check("blank.notRenderedInPreview", s.previewHost?.subtitleLayerForTest(sid) == nil && s.timeline.renderedSubtitles.isEmpty && s.timeline.subtitle(sid)?.isBlank == true)
        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 6a. 만들기 실행 취소 한 번 = 자막과 새 레인 함께 사라짐, 다시 실행 = 되돌아옴
        await focusTimeline()
        await key(6, "z", [.command]); let undone = s.timeline.subtitles.isEmpty && s.timeline.lanes(.subtitle).isEmpty
        await key(6, "z", [.command, .shift]); let redone = s.timeline.subtitle(sid)?.text == "" && s.timeline.laneInfo(s1) != nil && s.timeline.subtitle(sid)?.start == 30
        check("create.undoRemovesItemAndLaneTogether", undone && redone, "undone \(undone) redone \(redone) depth \(s.history.undoDepth) key \(NSApp.keyWindow === w)")
        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 6b. 빈 자막 지우기(Delete, 빈틈 남김: 레인은 남음) → 실행 취소로 되돌림
        s.select(sid); await focusTimeline()
        await key(51, "\u{7f}"); let deleted = s.timeline.subtitle(sid) == nil && s.timeline.laneInfo(s1) != nil
        await key(6, "z", [.command]); let restored = s.timeline.subtitle(sid)?.text == ""
        check("blank.deleteAndUndo", deleted && restored, "deleted \(deleted) restored \(restored)")
        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 6c. 빈 자막이 든 형식 6 저장(일회용 폴더) → 파일을 다시 읽으면 빈 글자 그대로
        let pBlank = folder.appendingPathComponent("blank.ontheframe")
        let okBlank = s.writeProject(to: pBlank)
        let backBlank = (try? Data(contentsOf: pBlank)).flatMap { try? ProjectFile.decode($0) }
        check("blank.saveAndDecode", okBlank && backBlank?.document.version == 6 && backBlank?.timeline.subtitle(sid)?.text == "" && backBlank?.timeline.subtitle(sid)?.start == 30,
              "saved \(okBlank) version \(backBlank?.document.version ?? -1)")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 6. 빈 자막을 T로 눌러 글 입력(한국어 조합 흉내 — 합성 입력, 실제 입력기 아님, 여러 줄) → ⌘Return: 글자 바꿈 한 단계 더
        await key(17, "t")
        await click(win(o1)); _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
        let dType = s.history.undoDepth
        if let e = ed() {
            e.setMarkedText("ㅊ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            e.setMarkedText("첫", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            e.insertText("첫", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        // 조합 흉내 뒤 지우기(합성 입력: 실제 입력기 아님): 글자를 하나 더 넣었다 지우면 칸 폭도 되돌아온다
        let wComposed = edRect().width
        type("가"); await LaneSelfTest.settle(); let wPlus = edRect().width
        ed()?.deleteBackward(nil); await LaneSelfTest.settle()
        check("ime.syntheticComposeDelete", ed()?.string == "첫" && wPlus > wComposed && near(edRect().width, wComposed), "w \(wComposed) +가 \(wPlus) 지움 \(edRect().width) text \(ed()?.string ?? "nil")")
        type(" 줄"); await LaneSelfTest.settle()
        let r1 = edRect(), line = nsLine()
        await key(36, "\r")   // Return = 줄바꿈
        await LaneSelfTest.settle()
        let r2 = edRect(), afterReturn = ed()?.string
        try? await Task.sleep(nanoseconds: 300_000_000)   // 멈춤(소유자 보고: 이때 빈 줄이 하나 더 보였음)
        let r2b = edRect()
        type("둘")
        await LaneSelfTest.settle()
        let r3 = edRect()
        type("째 줄"); await LaneSelfTest.settle()
        let r4 = edRect()
        check("geometry.oneLine", near(r1.height, ceil(line)) && near(r1.midX, caretView.x, 1.5) && r1.width < m.videoRect.width / 3, "r1 \(r1) line \(line)")
        check("geometry.returnAddsExactlyOneLine", afterReturn == "첫 줄\n" && near(r2.height, ceil(2 * line), 1.5) && r2 == r2b && near(r2.maxY, r1.maxY) && near(r2.width, r1.width),
              "r1 \(r1) r2 \(r2) r2pause \(r2b) line \(line) text \(afterReturn.debugDescription)")
        check("geometry.typingIntoNewLineNoJump", near(r3.height, r2.height) && near(r3.minY, r2.minY) && near(r3.maxY, r2.maxY) && near(r4.height, r2.height) && near(r4.midX, caretView.x, 1.5),
              "r2 \(r2) r3 \(r3) r4 \(r4)")
        // 확정 뒤 그림과 맞는가(출력 픽셀): 칸 위 끝 ≈ 글자 사각형 위 끝, 가운데 x 같음. 줄 높이·줄바꿈 폭·기준점 계산이 맞는지
        let edTopOut = (r4.minY - m.videoRect.minY) / m.scale, edMidOut = (r4.midX - m.videoRect.minX) / m.scale
        let whileTyping = s.timeline.subtitle(sid)?.text == "" && s.history.undoDepth == dType
        let beforeCommit = "ed \(ed() != nil) text \(ed()?.string.debugDescription ?? "nil") marked \(ed()?.hasMarkedText() ?? false) responder \(w.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil") key \(NSApp.keyWindow === w) active \(NSApp.isActive) edit \(s.inlineEdit != nil)"
        await key(36, "\r", [.command])
        _ = await LaneSelfTest.waitUntil(2) { s.timeline.subtitle(sid)?.text != "" }
        let afterCommit = "ed \(ed() != nil) responder \(w.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil") edit \(s.inlineEdit != nil) status \(s.statusMessage ?? "nil")"
        let first = s.timeline.subtitle(sid)
        let fb = first.map { SubtitleRenderer.shared.raster($0).textBounds } ?? .zero
        check("edit.typedTextOneMoreStep", whileTyping && s.timeline.subtitles.count == 1 && s.timeline.lanes(.subtitle).count == 1 && first?.text == "첫 줄\n둘째 줄"
              && first?.start == 30 && first?.length == 90 && s.history.undoDepth == dType + 1 && s.selection == sid && ed() == nil && s.inlineEdit == nil,
              "subs \(s.timeline.subtitles.map { [$0.start, $0.length] }) text \(first?.text.debugDescription ?? "nil") depth \(s.history.undoDepth - dType) | before: \(beforeCommit) | after: \(afterCommit)")
        // 아래 끝 기준: 처음 줄이 누른 자리에 놓이고, 줄이 늘면 위로 자란다 → 마지막 줄 가운데가 누른 y
        let lh1 = CGFloat(SubtitleRenderer.lineHeight(for: .default))
        check("geometry.editorMatchesCommittedRender", abs(edTopOut - fb.minY) < 3 && abs(edMidOut - fb.midX) < 2 / m.scale + 1,
              "editor top \(edTopOut) mid \(edMidOut) | rendered \(fb)")
        check("placement.renderedAtClick", abs(fb.midX - o1.x) < 2 && abs((fb.maxY - fb.height / 2 / 2) - o1.y) < lh1 * 0.35 && abs(fb.height - 2 * lh1) < lh1 * 0.3,
              "textBounds \(fb) click \(o1)")
        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 7. 문서 실행 취소(글 편집을 떠난 뒤): 한 번 = 글자만 빈 글자로(자막·레인은 남음), 다시 실행 = 글자
        await focusTimeline()
        await key(6, "z", [.command]); let textUndone = s.timeline.subtitle(sid)?.text == "" && s.timeline.laneInfo(s1) != nil
        await key(6, "z", [.command, .shift]); let textRedone = s.timeline.subtitle(sid)?.text == "첫 줄\n둘째 줄"
        check("edit.undoTextThenRedo", textUndone && textRedone, "undo \(textUndone) redo \(textRedone) key \(NSApp.keyWindow === w)")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 8. 보이는 자막을 T로 누름: 그 자막을 고친다(새로 만들지 않음). 편집 중 그림 숨김, 칸 밖 누름 = 확정, 그림 다시 보임
        _ = await previewSettled()
        await click(win(CGPoint(x: fb.midX, y: fb.midY)))
        _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
        let editingExisting = s.inlineEdit?.existingID == sid && s.timeline.subtitles.count == 1 && ed()?.string == "첫 줄\n둘째 줄"
        let hiddenWhileEditing = layerHidden(sid) == true
        let d1 = s.history.undoDepth
        ed()?.selectAll(nil); type("임시")
        await key(53, "\u{1b}")   // Esc = 편집 전으로
        let escOK = s.timeline.subtitle(sid)?.text == "첫 줄\n둘째 줄" && s.history.undoDepth == d1 && layerHidden(sid) == false && ed() == nil
        await click(win(CGPoint(x: fb.midX, y: fb.midY))); _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
        ed()?.selectAll(nil); type("고침\n둘째 줄")
        await click(win(CGPoint(x: 300, y: 200)))   // 칸 밖(출력 화면 안) 누름: 확정만
        _ = await previewSettled()
        _ = await LaneSelfTest.waitUntil(5) { layerHidden(sid) == false }
        check("existing.tClickEditsNotDuplicate", editingExisting && hiddenWhileEditing, "existing \(editingExisting) hidden \(hiddenWhileEditing)")
        check("existing.escRestores", escOK)
        check("existing.clickOutsideCommits", s.timeline.subtitle(sid)?.text == "고침\n둘째 줄" && s.history.undoDepth == d1 + 1 && s.timeline.subtitles.count == 1 && ed() == nil
              && s.inlineEdit == nil && layerHidden(sid) == false, "count \(s.timeline.subtitles.count) ed \(ed() != nil) edit \(s.inlineEdit != nil) hidden \(String(describing: layerHidden(sid))) text \(s.timeline.subtitle(sid)?.text.debugDescription ?? "nil") depth \(s.history.undoDepth - d1)")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 9. 같은 재생 헤드(30, 기존 자막 [30,120) 안), 글자 밖을 누름: 시작을 옮기지 않고 새 레인 S2에
        let d2 = s.history.undoDepth
        await click(win(CGPoint(x: 960, y: 300))); _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
        type("위 자막"); await key(36, "\r", [.command])
        let upper = s.timeline.subtitles.first { $0.text == "위 자막" }
        check("create.overlapUsesNewLaneSameStart", upper?.start == 30 && upper?.lane != s1 && s.timeline.lanes(.subtitle).count == 2 && s.history.undoDepth == d2 + 2,
              "upper \(upper.map { [$0.start, $0.length] } ?? []) lanes \(s.timeline.lanes(.subtitle).count) depth \(s.history.undoDepth - d2)")
        // (이후 구간을 위해 지운다: 실행 취소 둘 = 글자, 그다음 만들기(레인까지))
        await focusTimeline(); await key(6, "z", [.command]); await key(6, "z", [.command])
        check("create.overlapUndo", s.timeline.lanes(.subtitle).count == 1 && s.timeline.subtitles.count == 1)

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 10. V: 누르면 고름, 끌면 옮김(한 단계). Esc는 끌기 전으로. 끊긴 끌기(초점 잃음)는 취소되고 늦은 이벤트는 아무것도 안 함
        await key(9, "v")
        let st0 = s.timeline.subtitle(sid)!.style, k = m.scale
        let fbNow = SubtitleRenderer.shared.raster(s.timeline.subtitle(sid)!).textBounds
        let grab = win(CGPoint(x: fbNow.midX, y: fbNow.midY))
        let d3 = s.history.undoDepth
        let hitView = pv.superview.flatMap { sv in sv.hitTest(sv.convert(grab, from: nil)) }
        let toolNow = s.tool, sel0 = s.selection
        await LaneSelfTest.mouse(.leftMouseDown, grab, w)
        let selected = s.selection == sid
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: grab.x + 30, y: grab.y - 10), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: grab.x + 60, y: grab.y - 20), w)   // 창 좌표 y − 20 = 화면 아래(출력 y 증가)
        let movingLayer = s.previewHost?.subtitleLayerForTest(sid)?.frame
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: grab.x + 60, y: grab.y - 20), w)
        let st1 = s.timeline.subtitle(sid)!.style
        check("drag.vMovesOneStep", selected && s.history.undoDepth == d3 + 1 && abs(st1.x - (st0.x + 60 / Double(k))) < 1 && abs(st1.y - (st0.y + 20 / Double(k))) < 1
              && st1.fontName == st0.fontName && s.timeline.subtitle(sid)?.start == 30,
              "tool \(toolNow) hitView \(hitView.map { String(describing: Swift.type(of: $0)) } ?? "nil") sel0 \(sel0 == sid) selected \(selected) drag \(pv.dragNameForTest) x \(st0.x)→\(st1.x) y \(st0.y)→\(st1.y) k \(k) depth \(s.history.undoDepth - d3) layer \(movingLayer.map { "\($0)" } ?? "nil")")
        let fb1 = SubtitleRenderer.shared.raster(s.timeline.subtitle(sid)!).textBounds
        let grab1 = win(CGPoint(x: fb1.midX, y: fb1.midY))
        await LaneSelfTest.mouse(.leftMouseDown, grab1, w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: grab1.x - 80, y: grab1.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: grab1.x - 90, y: grab1.y), w)
        await key(53, "\u{1b}")
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: grab1.x - 90, y: grab1.y), w)
        let expectFrame = SubtitleRenderer.shared.raster(s.timeline.subtitle(sid)!).drawRect   // 층은 잘라 낸 그림 자리(drawRect, §49)
        let lf = s.previewHost?.subtitleLayerForTest(sid)?.frame
        check("drag.escCancels", s.timeline.subtitle(sid)?.style == st1 && s.history.undoDepth == d3 + 1 && s.gestureBase == nil
              && lf.map { abs($0.minX - expectFrame.minX) < 0.5 && abs($0.maxY - (1080 - expectFrame.minY)) < 0.5 } == true, "layer \(lf.map { "\($0)" } ?? "nil") expect \(expectFrame)")
        await LaneSelfTest.mouse(.leftMouseDown, grab1, w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: grab1.x + 40, y: grab1.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: grab1.x + 50, y: grab1.y), w)
        s.interruptGesture(reason: "selfTestFocusLoss", clearViewDrags: true)   // 창이 키 상태를 잃은 것과 같은 길(D-031)
        await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: grab1.x + 120, y: grab1.y), w)
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: grab1.x + 120, y: grab1.y), w)
        check("drag.interruptedCancelsAndIgnoresLateEvents", s.timeline.subtitle(sid)?.style == st1 && s.history.undoDepth == d3 + 1 && s.gestureBase == nil && pv.dragNameForTest == "none")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 11. V 두 번 누름: 그 자리에서 고침. 글자를 바꾸지 않고 ⌘Return이면 기록 없음
        let d4 = s.history.undoDepth
        await LaneSelfTest.mouse(.leftMouseDown, grab1, w); await LaneSelfTest.mouse(.leftMouseUp, grab1, w)
        await LaneSelfTest.mouse(.leftMouseDown, grab1, w, clicks: 2); await LaneSelfTest.mouse(.leftMouseUp, grab1, w, clicks: 2)
        _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
        let dbl = s.inlineEdit?.existingID == sid && ed() != nil
        await key(36, "\r", [.command])
        check("doubleClick.editsInPlace", dbl && s.history.undoDepth == d4 && ed() == nil, "editing \(dbl)")
        // 글을 "첫 줄\n둘째 줄"로 되돌림(이후 구간이 이 글자를 쓴다)
        s.setSubtitleText(sid, "첫 줄\n둘째 줄")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 11b. 정렬: 기존 자막을 왼쪽·오른쪽 정렬로 바꾸고 T로 고치면 칸의 왼쪽·오른쪽 끝이 기준점에 붙고, 글이 늘어도 그대로. Esc는 문서 그대로
        await key(17, "t")
        let stKeep = s.timeline.subtitle(sid)!.style
        var alignOK: [String] = []
        for (a, ax) in [(SubtitleStyle.Alignment.left, 300), (.right, 1600)] {
            var st = stKeep; st.alignment = a; st.xMilli = ax * 1000
            s.setSubtitleStyle(sid, st); _ = await previewSettled()
            let tb = SubtitleRenderer.shared.raster(s.timeline.subtitle(sid)!).textBounds
            await click(win(CGPoint(x: tb.midX, y: tb.midY))); _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
            let anchorV = m.view(CGPoint(x: CGFloat(ax), y: 0)).x
            let ra = edRect()
            ed()?.setSelectedRange(NSRange(location: (ed()!.string as NSString).length, length: 0)); type(" 더하기"); await LaneSelfTest.settle()
            let rb = edRect()
            let ok = a == .left ? (near(ra.minX, anchorV) && near(rb.minX, anchorV) && rb.width > ra.width) : (near(ra.maxX, anchorV) && near(rb.maxX, anchorV) && rb.width > ra.width)
            alignOK.append("\(a) \(ok) anchor \(anchorV) \(ra) → \(rb)")
            let dA = s.history.undoDepth
            await key(53, "\u{1b}")
            if s.history.undoDepth != dA || s.timeline.subtitle(sid)?.text != "첫 줄\n둘째 줄" { alignOK.append("esc changed document") }
        }
        s.setSubtitleStyle(sid, stKeep); _ = await previewSettled()
        check("geometry.alignmentAnchorsEdge", alignOK.allSatisfy { $0.contains(" true ") } && alignOK.count == 2, alignOK.joined(separator: " | "))
        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 11c. 출력 화면 가장자리: 왼쪽 끝 근처(가운데 정렬)에 쓰면 칸은 기준점을 지키고 자르기 보기 밖은 보이지 않으며 경계도 출력 화면 안
        await click(win(CGPoint(x: 15, y: 200))); _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
        type("가장자리 글자"); await LaneSelfTest.settle()
        let re = edRect(), oe = pv.editorOutline ?? .null
        check("geometry.canvasEdgeStaysInside", near(re.midX, m.view(CGPoint(x: 15, y: 0)).x, 1.5) && re.minX < m.videoRect.minX && oe.minX >= m.videoRect.minX - 0.01
              && m.videoRect.contains(oe) && ed()?.superview === pv.canvasClip, "editor \(re) outline \(oe) video \(m.videoRect)")
        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 11d. 프리뷰 크기 바꿈: 칸이 같은 출력 기준점·배율을 따른다(편집 중, 글자 그대로)
        let size0 = w.frame.size
        w.setContentSize(NSSize(width: (w.contentView?.frame.width ?? 1200) - 240, height: (w.contentView?.frame.height ?? 800) - 120))
        await LaneSelfTest.settle(); try? await Task.sleep(nanoseconds: 300_000_000)
        let m2 = pv.mapping, rr = edRect()
        let bottomOut = (rr.maxY - m2.videoRect.minY) / m2.scale
        let st15 = SubtitleRenderer.anchored(.default, firstLineAt: CGPoint(x: 15, y: 200))
        let resizeOK = m2.scale != m.scale && near(rr.midX, m2.view(CGPoint(x: 15, y: 0)).x, 1.5) && abs(bottomOut - (st15.y - Double(SubtitleRenderer.pad(for: st15)))) < 2
            && ed()?.string == "가장자리 글자" && near(ed()?.font?.pointSize ?? 0, CGFloat(st15.size) * m2.scale, 0.01) && pv.canvasClip.frame == m2.videoRect
        check("geometry.followsPreviewResize", resizeOK, "k \(m.scale)→\(m2.scale) editor \(rr) bottomOut \(bottomOut)")
        await key(53, "\u{1b}")
        w.setFrame(NSRect(origin: w.frame.origin, size: size0), display: true)
        _ = await LaneSelfTest.waitUntil(3) { abs(pv.mapping.scale - m.scale) < 0.0001 }; await LaneSelfTest.settle()
        check("geometry.resizeRestored", abs(pv.mapping.scale - m.scale) < 0.0001, "k \(pv.mapping.scale) expected \(m.scale)")
        let edgeBlank = s.timeline.subtitles.filter { $0.isBlank && $0.start == 30 && $0.id != sid }
        check("geometry.edgeEscKeepsBlankItem", !s.timeline.subtitles.contains { $0.text == "가장자리 글자" } && ed() == nil && edgeBlank.count == 1)
        for b in edgeBlank { s.select(b.id); s.deleteSelection(ripple: false) }   // 이후 구간을 위해 지움
        await focusTimeline()

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 12. 생애: 글을 쓰는 중 재생 헤드 이동 → 확정(한 단계). 도구 바꿈 → 확정. 프로젝트 교체는 아래 15에서 본다
        await key(17, "t")
        s.seek(to: 125 > s.durationFrames ? s.durationFrames : 125)
        let ph = s.playhead
        await click(win(CGPoint(x: 600, y: 200))); _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
        type("탐색 전 글"); let d5 = s.history.undoDepth
        s.seek(to: 10)
        let seekCommitted = s.timeline.subtitles.contains { $0.text == "탐색 전 글" && $0.start == ph } && s.history.undoDepth == d5 + 1 && ed() == nil
        await click(win(CGPoint(x: 600, y: 200))); _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
        type("도구 전 글")
        s.setTool(.selection)
        let toolCommitted = s.timeline.subtitles.contains { $0.text == "도구 전 글" && $0.start == 10 } && ed() == nil && s.inlineEdit == nil
        check("lifecycle.seekAndToolCommit", seekCommitted && toolCommitted, "seek \(seekCommitted) tool \(toolCommitted)")
        // 이후 구간을 위해 두 개를 지운다
        for sub in s.timeline.subtitles where sub.text == "탐색 전 글" || sub.text == "도구 전 글" { s.select(sub.id); s.deleteSelection(ripple: false) }

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 13. 둘째 자막 [150, 240): 재생 헤드는 타임라인 끝(120) 뒤로 갈 수 없어 초안 시작도 120까지다(맞는 제한).
        //     이후 구간의 배치를 위해 같은 엔진 동작(addingSubtitleCreatingLane)을 저장소 commit으로 직접 쓴다.
        let durNow = s.durationFrames
        let clampID = s.createSubtitleAndEdit(atFrame: durNow + 50, output: CGPoint(x: 960, y: 940))
        let clampOK = clampID.flatMap { s.timeline.subtitle($0)?.start } == durNow
        pv.syncEditor(); await key(53, "\u{1b}")
        if let c = clampID { s.select(c); s.deleteSelection(ripple: false) }
        let id150 = UUID()
        s.commit({ try $0.addingSubtitleCreatingLane(at: 150, text: "둘째 자막", style: SubtitleRenderer.anchored(.default, firstLineAt: CGPoint(x: 960, y: 940)), id: id150, newLaneName: "자막") }, focus: id150)
        check("draft.startClampedToTimelineEnd", clampOK)
        let second = s.timeline.subtitles.first { $0.text == "둘째 자막" }
        check("draft.beyondVideoExtends", second?.start == 150 && second?.length == 90 && second?.lane == s1 && s.timeline.durationFrames >= 240,
              "second \(second.map { [$0.start, $0.length] } ?? []) dur \(s.timeline.durationFrames)")
        await focusTimeline()

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 14. 프리뷰: 동기 층이 지금 항목에 묶이고 자막 수만큼 층. 멈춘 시각의 불투명도 = [시작, 끝)
        _ = await previewSettled()
        let host = s.previewHost
        _ = await LaneSelfTest.waitUntil(10) { host?.subtitleBoundItem != nil && host?.subtitleBoundItem === s.player.currentItem }
        check("preview.layerBound", host?.subtitleBoundItem === s.player.currentItem && host?.subtitleLayerCount == 2, "count \(host?.subtitleLayerCount ?? -1)")
        func opacities(at f: Int) async -> [Float] {
            s.seek(to: f); _ = await LaneSelfTest.waitUntil(3) { s.playhead == f }
            try? await Task.sleep(nanoseconds: 300_000_000)
            CATransaction.flush()
            return (host?.subtitleCanvas.sublayers ?? []).map { $0.presentation()?.opacity ?? -1 }
        }
        // 그리기 순서는 같은 레인 안에서 시작 순: [30,120) → [150,240)
        let o29 = await opacities(at: 29), o30 = await opacities(at: 30), o119 = await opacities(at: 119), o120 = await opacities(at: 120), o200 = await opacities(at: 200)
        check("preview.visibleHalfOpen", o29 == [0, 0] && o30 == [1, 0] && o119 == [1, 0] && o120 == [0, 0] && o200 == [0, 1],
              "29 \(o29) 30 \(o30) 119 \(o119) 120 \(o120) 200 \(o200)")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 15. 모양만 바꿈: 프리뷰 항목을 바꾸지 않고 자막 층만 바꾼다(한 단계)
        let reps = s.itemReplacements, only = s.subtitleOnlyRefreshes, dS4 = s.history.undoDepth
        var st = s.timeline.subtitle(sid)!.style; st.red = 255; st.green = 214; st.blue = 0; st.sizeTenths = 600
        s.setSubtitleStyle(sid, st)
        _ = await previewSettled()
        check("style.oneStepNoItemReplace", s.timeline.subtitle(sid)?.style == st && s.history.undoDepth == dS4 + 1 && s.itemReplacements == reps && s.subtitleOnlyRefreshes == only + 1
              && host?.subtitleBoundItem === s.player.currentItem, "reps \(s.itemReplacements - reps) only \(s.subtitleOnlyRefreshes - only)")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 16. 선택 도구(V): 끝 트림(끌기 한 단계), 옮기기(끌기 한 단계, 겹침 거부)
        await key(9, "v")
        s.select(sid); await LaneSelfTest.settle()
        let dS5 = s.history.undoDepth
        let pTrim = pt(s1, 120, dx: -2)
        let trimDiag = "tool \(s.tool) sel \(s.selection == sid) key \(NSApp.keyWindow === w) active \(NSApp.isActive) hit \(w.contentView?.superview?.hitTest(pTrim).map { String(describing: Swift.type(of: $0)) } ?? "nil") pt \(pTrim) timelineVisible \(tv.visibleRect)"
        await drag(pt(s1, 120, dx: -2), pt(s1, 110, dx: -2))
        let trimmed = s.timeline.subtitle(sid).map { [$0.start, $0.length] }
        await drag(pt(s1, 60), pt(s1, 50))
        let moved = s.timeline.subtitle(sid).map { [$0.start, $0.length] }
        check("gesture.trimAndMove", trimmed == [30, 80] && moved == [20, 80] && s.history.undoDepth == dS5 + 2, "trim \(trimmed ?? []) move \(moved ?? []) depth \(s.history.undoDepth - dS5) | \(trimDiag)")
        await drag(pt(s1, 60), pt(s1, 190))   // [150,240)과 겹침 → 거부(그대로)
        check("gesture.overlapRejected", s.timeline.subtitle(sid).map { [$0.start, $0.length] } == [20, 80] && s.history.undoDepth == dS5 + 2,
              "\(s.timeline.subtitle(sid).map { [$0.start, $0.length] } ?? []) status \(s.statusMessage ?? "nil")")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 17. ⌘K 자르기(고른 자막, 재생 헤드): 두 조각 같은 글자·모양
        s.select(sid); s.seek(to: 60); await focusTimeline()
        await key(40, "k", [.command])
        let pieces = s.timeline.subtitles.filter { $0.text == "첫 줄\n둘째 줄" }.sorted { $0.start < $1.start }
        check("split.commandK", pieces.map { [$0.start, $0.length] } == [[20, 40], [60, 40]] && Set(pieces.map(\.style)).count == 1,
              "\(pieces.map { [$0.start, $0.length] })")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 18. 복사(⌘C)·붙여넣기(⌘V, 재생 헤드 100): 같은 레인
        if let right = pieces.last { s.select(right.id) }
        s.seek(to: 100); await focusTimeline()
        let n0 = s.timeline.subtitles.count
        await key(8, "c", [.command]); await key(9, "v", [.command])
        let pasted = s.selection.flatMap { s.timeline.subtitle($0) }
        check("copyPaste.subtitle", s.timeline.subtitles.count == n0 + 1 && pasted?.start == 100 && pasted?.lane == s1 && pasted?.text == "첫 줄\n둘째 줄",
              "count \(s.timeline.subtitles.count - n0) at \(pasted?.start ?? -1) status \(s.statusMessage ?? "nil")")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 19. Delete(빈틈 남김)·자르기 도구 클릭
        let before13 = s.timeline.subtitles.count
        await key(51, "\u{7f}")
        let afterDelete = s.timeline.subtitles.count
        await key(8, "c")
        await click(pt(s1, 200))
        await key(9, "v")
        let cutPieces = s.timeline.subtitles.filter { $0.start >= 150 }.sorted { $0.start < $1.start }.map { [$0.start, $0.length] }
        check("delete.and.cutTool", afterDelete == before13 - 1 && cutPieces == [[150, 50], [200, 40]], "after \(before13)→\(afterDelete) cut \(cutPieces)")

        // 19b. 끌기 측정(§45.3): 타임라인 자막 옮기기·프리뷰 자막 위치 끌기. 보기의 처리기를 직접 부르고(키 창 초점과 무관) 이벤트마다
        //      주 실행 대기열이 빌 때까지 기다린 시간(ms)과 결정적 수(문서 갱신·모양 칸 다시 계산·글자 다시 그리기·프리뷰 항목 교체)를 잰다.
        //      고친 동작과 이전 동작(legacySubtitleUIForTest)을 같은 빌드에서 견준다. 시간은 이 Mac·이 순간의 기록이며 화면 부드러움의 증명이 아니다.
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)!
        }
        /// 주 대기열 비우기: 표시 이벤트를 앱 대기열 끝에 넣고 그 이벤트가 처리되는 순간 바로 이어간다(폴링 없음 — 이전 20 ms 폴링은 측정 바닥이 되었다)
        func drainMain() async {
            let marker = Int(Date().timeIntervalSince1970 * 1000) & 0x3FFF_FFFF ^ 0x2A5A
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                var mon: Any?
                var resumed = false
                mon = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { e in
                    if e.data1 == marker, !resumed { resumed = true; if let m = mon { NSEvent.removeMonitor(m) }; c.resume() }
                    return e
                }
                if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: marker, data2: 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            CATransaction.flush()
        }
        struct DragStats { var ms: [Double] = []; var bodies = 0, updates = 0, renders = 0, items = 0, depth = 0, events = 0
            var median: Double { ms.sorted()[ms.count / 2] }
            var p95: Double { ms.sorted()[min(ms.count - 1, Int(Double(ms.count) * 0.95))] }
            var text: String { String(format: "ms 중앙 %.2f p95 %.2f 최대 %.2f | 문서 갱신 %d 모양 칸 계산 %d 글자 그리기 %d 항목 교체 %d 기록 +%d (이벤트 %d)",
                                      median, p95, ms.max() ?? 0, updates, bodies, renders, items, depth, events) }
        }
        func measure(_ view: NSView, from p0: NSPoint, _ offsets: [CGVector]) async -> DragStats {
            var st = DragStats()
            let b0 = SubtitleStyleAdjust.bodyCountForTest, u0 = s.subtitleGestureUpdatesForTest, r0 = SubtitleRenderer.shared.renderCount, i0 = s.itemReplacements, d0m = s.history.undoDepth
            view.mouseDown(with: ev(.leftMouseDown, p0)); await drainMain()
            var last = p0
            for o in offsets {
                last = NSPoint(x: p0.x + o.dx, y: p0.y + o.dy)
                let t0 = ProcessInfo.processInfo.systemUptime
                view.mouseDragged(with: ev(.leftMouseDragged, last)); await drainMain()
                st.ms.append((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            }
            st.bodies = SubtitleStyleAdjust.bodyCountForTest - b0; st.updates = s.subtitleGestureUpdatesForTest - u0
            st.renders = SubtitleRenderer.shared.renderCount - r0
            view.mouseUp(with: ev(.leftMouseUp, last)); await drainMain(); _ = await previewSettled()
            st.items = s.itemReplacements - i0; st.depth = s.history.undoDepth - d0m; st.events = offsets.count
            return st
        }
        await key(9, "v"); EditorLayout.shared.leftTab = .adjust
        if let piece = s.timeline.subtitles(inLane: s1).filter({ !$0.isBlank }).min(by: { $0.start < $1.start }) {
            let pid = piece.id
            // 타임라인: 0…−20 pt 톱니(배율 2 pt/프레임 → 0…−10 프레임, 1 pt씩 = 반 프레임씩)
            let saw = (0..<80).map { CGVector(dx: -CGFloat($0 % 21), dy: 0) }
            var tl: [Bool: DragStats] = [:]
            for legacy in [false, true] {
                s.legacySubtitleUIForTest = legacy
                s.select(pid); await LaneSelfTest.settle()
                guard let cur = s.timeline.subtitle(pid) else { break }
                tl[legacy] = await measure(tv, from: pt(s1, cur.start + cur.length / 2), saw)
            }
            s.legacySubtitleUIForTest = false
            let tf = tl[false] ?? DragStats(), tlg = tl[true] ?? DragStats()
            check("perf.timelineDrag", tf.items == 0 && tf.depth == 1 && tf.updates < tf.events && tf.bodies <= 2 && tf.renders == 0 && s.timeline.subtitle(pid).map { $0.start >= 0 } == true,
                  "고침: \(tf.text) || 이전: \(tlg.text)")
            // 프리뷰: 반지름 60 pt 원을 80 이벤트로
            s.seek(to: s.timeline.subtitle(pid)!.start + 2); _ = await previewSettled()
            let circle = (0..<80).map { i -> CGVector in let a = Double(i) / 80 * 2 * .pi; return CGVector(dx: 60 * sin(a), dy: 60 * (1 - cos(a)) / 2) }
            var pvStats: [Bool: DragStats] = [:]
            var consistent = false
            for legacy in [false, true] {
                s.legacySubtitleUIForTest = legacy
                s.select(pid); await LaneSelfTest.settle()
                guard let cur = s.timeline.subtitle(pid) else { break }
                let tb = SubtitleRenderer.shared.hitBounds(cur)
                pvStats[legacy] = await measure(pv, from: win(CGPoint(x: tb.midX, y: tb.midY)), circle)
                if !legacy, let now = s.timeline.subtitle(pid), let lf = s.previewHost?.subtitleLayerForTest(pid)?.frame {
                    let r = SubtitleRenderer.shared.raster(now).drawRect
                    consistent = abs(lf.minX - r.minX) < 0.5 && abs(lf.maxY - (1080 - r.minY)) < 0.5 && s.selectedSubtitle?.style == now.style
                }
            }
            s.legacySubtitleUIForTest = false
            let pf = pvStats[false] ?? DragStats(), pl = pvStats[true] ?? DragStats()
            check("perf.previewDrag", pf.items == 0 && pf.depth == 1 && pf.updates == 0 && pf.renders == 0 && pf.bodies <= 2 && consistent,
                  "고침: \(pf.text) 끝 위치 일치 \(consistent) || 이전: \(pl.text)")
        } else { check("perf.setup", false, "자막 없음") }
        await focusTimeline()

        // 19c. 색 조정 세션(D-039, 저장소 경로를 직접 부름 — 실제 색 패널을 띄우지 않음): 팔레트 20색, 멈춤과 무관한 한 세션 = 한 단계,
        //      닫힘·대상 바꿈 때 한 번, 같은 값으로 돌아오면 기록 없음, ⌘Z는 세션을 끝내고 되돌림, 늦은 값(다른 프로젝트 회차·고르지 않은 자막) 무시
        if let piece = s.timeline.subtitles(inLane: s1).first(where: { !$0.isBlank }) {
            let cid = piece.id
            s.select(cid); await LaneSelfTest.settle(); _ = await previewSettled()
            let base = piece.style, proj = s.projectSession
            let pal = SubtitleStyleAdjust.palette
            check("color.palette20", pal.count == 20 && Set(pal.map(\.name)).count == 20 && Set(pal.map { [$0.r, $0.g, $0.b] }).count == 20
                  && pal.allSatisfy { [$0.r, $0.g, $0.b].allSatisfy { (0...255).contains($0) } }, "\(pal.count)")
            // 팔레트(불투명도 유지) → 2초 넘게 쉼(예전 0.4초 경계보다 김) → 색 패널 값 → 쉼 → HEX·불투명도 칸 값 → 닫힘
            let dC = s.history.undoDepth, iC = s.itemReplacements
            var b0 = base; b0.alpha = 180; s.setSubtitleStyle(cid, b0); let dS = s.history.undoDepth   // 불투명도 유지를 보려고 시작 알파 180
            let pi = (0..<20).first { SubtitleStyleAdjust.presetIndex(b0) != $0 }!   // 지금 색과 다른 팔레트 칸(같으면 변화 없음 = 세션 없음이 맞다)
            let pp = pal[pi]
            s.colorEditChange(cid, red: pp.r, green: pp.g, blue: pp.b, alpha: s.timeline.subtitle(cid)!.style.alpha, project: proj)
            let presetOK = s.colorSession?.current.alpha == 180 && s.colorSession.map { SubtitleStyleAdjust.presetIndex($0.current) } == pi
            try? await Task.sleep(nanoseconds: 2_100_000_000)
            let stillOpen = s.colorSession != nil && s.history.undoDepth == dS
            s.colorEditChange(cid, red: 10, green: 200, blue: 120, alpha: 230, project: proj)   // 색 패널(불투명도 포함)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            s.colorEditChange(cid, red: 0x12, green: 0x34, blue: 0x56, alpha: 230, project: proj)  // HEX 칸
            s.colorEditChange(cid, red: 0x12, green: 0x34, blue: 0x56, alpha: 128, project: proj)  // 불투명도 칸
            let final = s.colorSession?.current
            let during = s.history.undoDepth == dS && s.timeline.subtitle(cid)?.style == b0 && s.itemReplacements == iC
            NotificationCenter.default.post(name: NSColorPanel.willCloseNotification, object: NSColorPanel.shared)
            NotificationCenter.default.post(name: NSColorPanel.willCloseNotification, object: NSColorPanel.shared)   // 겹친 알림
            await LaneSelfTest.settle()
            let oneStep = s.colorSession == nil && s.history.undoDepth == dS + 1 && s.timeline.subtitle(cid)?.style == final
                && final.map { [$0.red, $0.green, $0.blue, $0.alpha] } == [0x12, 0x34, 0x56, 128]
            s.undo()
            let undone = s.timeline.subtitle(cid)?.style == b0
            s.redo()
            let redone = s.timeline.subtitle(cid)?.style == final
            check("color.sessionIgnoresPausesOneStep", presetOK && stillOpen && during && oneStep && undone && redone && s.itemReplacements == iC,
                  "preset \(presetOK) open \(stillOpen) during \(during) one \(oneStep) undo \(undone) redo \(redone) depth \(s.history.undoDepth - dS) items \(s.itemReplacements - iC)")
            // 처음 값으로 돌아와 닫으면 기록 없음
            let dN = s.history.undoDepth, now = s.timeline.subtitle(cid)!.style
            s.colorEditChange(cid, red: 1, green: 2, blue: 3, alpha: now.alpha, project: proj)
            s.colorEditChange(cid, red: now.red, green: now.green, blue: now.blue, alpha: now.alpha, project: proj)
            s.finishColorSession()
            check("color.noOpSessionNoHistory", s.history.undoDepth == dN && s.timeline.subtitle(cid)?.style == now && s.colorSession == nil)
            // 열린 세션에서 ⌘Z(문서 실행 취소): 세션을 끝내고(한 단계) 그 단계를 되돌림 → 처음 RGBA
            s.colorEditChange(cid, red: 250, green: 10, blue: 10, alpha: 255, project: proj)
            s.undo()
            check("color.undoDuringSessionFinishesAndReverts", s.colorSession == nil && s.timeline.subtitle(cid)?.style == now && s.history.undoDepth == dN && s.history.canRedo,
                  "depth \(s.history.undoDepth - dN) style \(s.timeline.subtitle(cid).map { [$0.style.red, $0.style.alpha] } ?? [])")
            s.redo(); s.undo()   // 기록을 처음 상태로
            // 대상 바꿈: 다른 자막을 고르면 한 번 넣고 끝. 그 뒤 옛 자막으로 온 늦은 값은 무시(고른 것이 아님)
            if let other = s.timeline.subtitles.first(where: { $0.id != cid && !$0.isBlank }) {
                let dT = s.history.undoDepth
                s.colorEditChange(cid, red: 5, green: 6, blue: 7, alpha: now.alpha, project: proj)
                s.select(other.id)
                let switched = s.colorSession == nil && s.history.undoDepth == dT + 1 && s.timeline.subtitle(cid)?.style.red == 5
                s.colorEditChange(cid, red: 99, green: 99, blue: 99, alpha: 99, project: proj)   // 늦은 값(옛 자막)
                let staleIgnored = s.colorSession == nil && s.timeline.subtitle(cid)?.style.red == 5
                check("color.targetChangeCommitsOnceStaleIgnored", switched && staleIgnored, "switched \(switched) stale \(staleIgnored)")
                s.undo()
            } else { check("color.targetChangeCommitsOnceStaleIgnored", false, "다른 자막 없음") }
            // 늦은 값(다른 프로젝트 회차)은 무시
            s.select(cid)
            let dP = s.history.undoDepth
            s.colorEditChange(cid, red: 77, green: 77, blue: 77, alpha: 255, project: proj - 1)
            check("color.staleProjectIgnored", s.colorSession == nil && s.history.undoDepth == dP)
            // 대상 지움: 세션 중 지우면 색이 먼저 한 단계로 들어가고 지움이 다음 단계(되돌리면 색까지 그대로)
            s.colorEditChange(cid, red: 33, green: 44, blue: 55, alpha: 255, project: proj)
            s.deleteSelection(ripple: false)
            let delOK = s.timeline.subtitle(cid) == nil && s.history.undoDepth == dP + 2 && s.colorSession == nil
            s.undo()
            let back = s.timeline.subtitle(cid)?.style.red == 33
            s.undo()
            check("color.deleteDuringSession", delOK && back && s.timeline.subtitle(cid)?.style == now, "del \(delOK) back \(back)")
            // 변환: sRGB 그대로, 넓은 색역(Display P3 순수 빨강)은 sRGB로 바꾼 뒤 범위 안
            let srgb = SubtitleStyleAdjust.styled(.default, from: Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 0.5))
            let p3 = SubtitleStyleAdjust.styled(.default, from: Color(.displayP3, red: 1, green: 0, blue: 0, opacity: 1))
            check("color.explicitSRGBConversion", [srgb.red, srgb.green, srgb.blue, srgb.alpha] == [51, 102, 153, 128] && p3.red == 255 && p3.green == 0 && p3.blue == 0 && p3.isValid,
                  "srgb \([srgb.red, srgb.green, srgb.blue, srgb.alpha]) p3 \([p3.red, p3.green, p3.blue, p3.alpha])")
            // 글 편집 중 색 상자로 초점이 가도 글은 확정되고 새 자막은 생기지 않는다
            let nC = s.timeline.subtitles.count
            s.beginInlineEdit(cid); pv.syncEditor(); _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
            let keep = s.timeline.subtitle(cid)!.text
            ed()?.setSelectedRange(NSRange(location: (keep as NSString).length, length: 0)); type("색")
            w.makeFirstResponder(nil)
            await LaneSelfTest.settle()
            s.colorEditChange(cid, red: 1, green: 1, blue: 7, alpha: 255, project: proj); s.finishColorSession()
            check("color.focusToPickerKeepsText", s.timeline.subtitle(cid)?.text == keep + "색" && s.timeline.subtitles.count == nC && s.timeline.subtitle(cid)?.style.blue == 7 && ed() == nil,
                  "text \(s.timeline.subtitle(cid)?.text.debugDescription ?? "nil") count \(s.timeline.subtitles.count - nC)")
            s.setSubtitleText(cid, keep); s.setSubtitleStyle(cid, base)   // 이후 구간(내보내기 밝은 글자 판정)을 위해 되돌림
        } else { check("color.setup", false, "자막 없음") }
        await focusTimeline()

        // 19e. 효과(D-040, 저장소 경로): 켜기·조정은 모양 세션 — 문서 그대로·프리뷰 층만(항목 교체 없음), 쉼과 무관하게 끝날 때 한 단계, 실행 취소로 효과 없음.
        //      형식 7로 저장되고 다시 읽으면 효과 그대로. 빈 자막은 효과가 켜져도 그리지 않음.
        if let piece = s.timeline.subtitles(inLane: s1).first(where: { !$0.isBlank }) {
            let fid = piece.id, proj = s.projectSession
            s.select(fid); s.seek(to: piece.start + 2); _ = await previewSettled()
            let before = s.timeline.subtitle(fid)!.style, dF = s.history.undoDepth, iF = s.itemReplacements
            let layerBefore = s.previewHost?.subtitleLayerForTest(fid)?.frame
            s.styleEditChange(fid, project: proj) { $0.outline = .default }
            s.styleEditChange(fid, project: proj) { $0.shadow = .default }
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // 쉼(세션을 나누지 않음)
            s.styleEditChange(fid, project: proj) { $0.background = .default; $0.background!.alpha = 100 }
            let live = s.previewHost?.subtitleLayerForTest(fid)?.frame
            let during = s.history.undoDepth == dF && s.timeline.subtitle(fid)?.style == before && s.itemReplacements == iF
            // 짧은 가운데 글은 효과가 줄바꿈 폭(1728) 안이라 가로는 같고, 세로는 그림자·외곽선만큼 커진다
            let grew = live.map { lf in layerBefore.map { lf.width >= $0.width && lf.height > $0.height } ?? false } ?? false
            s.finishColorSession(); _ = await previewSettled()
            let after = s.timeline.subtitle(fid)!.style
            let one = s.history.undoDepth == dF + 1 && after.hasEnabledEffects && after.outline == .default && after.background?.alpha == 100 && s.itemReplacements == iF
            let r = SubtitleRenderer.shared.raster(s.timeline.subtitle(fid)!)
            let layerOK = s.previewHost?.subtitleLayerForTest(fid).map { abs($0.frame.width - r.drawRect.width) < 0.5 && abs($0.frame.height - r.drawRect.height) < 0.5 } == true
            let pFx = folder.appendingPathComponent("effects.ontheframe")
            let saved = s.writeProject(to: pFx)
            let doc = (try? Data(contentsOf: pFx)).flatMap { try? ProjectFile.decode($0) }
            let persisted = saved && doc?.document.version == 7 && doc?.timeline.subtitle(fid)?.style == after
            s.undo(); _ = await previewSettled()
            let undone = s.timeline.subtitle(fid)?.style == before && !s.timeline.subtitles.contains { $0.style.hasEnabledEffects }
            check("effects.sessionPreviewOneStepFormat7Undo", during && grew && one && layerOK && persisted && undone,
                  "during \(during) grew \(grew) one \(one) layer \(layerOK) v7 \(persisted) undo \(undone) items \(s.itemReplacements - iF)")
            // 2026-10-23 검토 고침: 없던 효과를 켰다가 그대로 끄면 단계 없음(문서 그대로) / 세션 중 ⌘C는 세션을 먼저 넣어 보이는 모양을 복사
            s.select(fid)
            let d0 = s.history.undoDepth
            s.styleEditChange(fid, project: proj) { if $0.outline == nil { $0.outline = .default }; $0.outline?.enabled = true }
            s.styleEditChange(fid, project: proj) { $0.outline?.enabled = false }
            s.finishColorSession(); _ = await previewSettled()
            check("effects.toggleOnOffNoStep", s.history.undoDepth == d0 && s.timeline.subtitle(fid)?.style == before, "depth +\(s.history.undoDepth - d0)")
            s.styleEditChange(fid, project: proj) { if $0.outline == nil { $0.outline = .default }; $0.outline?.enabled = true }
            s.copySelection()
            let copied = s.clipClipboard?.content.subtitles.first?.style.activeOutline != nil
            check("effects.copyFinishesSession", s.colorSession == nil && copied && s.history.undoDepth == d0 + 1 && s.timeline.subtitle(fid)?.style.activeOutline != nil,
                  "copied \(copied) depth +\(s.history.undoDepth - d0)")
            s.undo(); _ = await previewSettled()
            // 2026-10-23 전체 검토 고침: 세션 중 붙여넣기 — 세션을 먼저 한 단계로 넣고 붙여넣기는 그 다음 단계(실행 취소 한 번 = 붙여넣기만 취소, 모양은 남음)
            s.select(fid); s.copySelection()
            let d1 = s.history.undoDepth, nSubs = s.timeline.subtitles.count
            s.styleEditChange(fid, project: proj) { if $0.outline == nil { $0.outline = .default }; $0.outline?.enabled = true }
            s.pasteAtPlayhead(); _ = await previewSettled()
            let pastedOK = s.colorSession == nil && s.history.undoDepth == d1 + 2 && s.timeline.subtitles.count == nSubs + 1
                && s.timeline.subtitle(fid)?.style.activeOutline != nil
            s.undo(); _ = await previewSettled()
            let undoPaste = s.timeline.subtitles.count == nSubs && s.timeline.subtitle(fid)?.style.activeOutline != nil
            s.undo(); _ = await previewSettled()
            let undoStyle = s.timeline.subtitle(fid)?.style == before
            // 바뀐 것 없는 세션(켰다 끔) + 붙여넣기 = 붙여넣기 한 단계만
            s.select(fid)
            s.styleEditChange(fid, project: proj) { if $0.outline == nil { $0.outline = .default }; $0.outline?.enabled = true }
            s.styleEditChange(fid, project: proj) { $0.outline?.enabled = false }
            s.pasteAtPlayhead(); _ = await previewSettled()
            let noopOK = s.history.undoDepth == d1 + 1 && s.timeline.subtitle(fid)?.style == before
            s.undo(); _ = await previewSettled()
            check("effects.pasteFinishesSessionFirst", pastedOK && undoPaste && undoStyle && noopOK && s.timeline.subtitles.count == nSubs,
                  "paste \(pastedOK) undo1 \(undoPaste) undo2 \(undoStyle) noop \(noopOK)")
            // 2026-10-23 전체 검토 고침: 자막 레인이 있을 때 새 영상 레인(저장소 경로 직접 호출 — 레인 추가·레인 쌍·새 레인에 놓기). 이전에는 모두 "겹칩니다"로 실패.
            if let mid = s.assets.first?.id {
                let lanes0 = s.timeline.lanes, d0 = s.history.undoDepth, nSub = lanes0.filter { $0.kind == .subtitle }.count
                func ordered() -> Bool { let k = s.timeline.lanes.map(\.kind); return k == k.sorted { ($0 == .subtitle ? 0 : $0 == .video ? 1 : 2) < ($1 == .subtitle ? 0 : $1 == .video ? 1 : 2) } && s.timeline.isValid }
                func newIDs() -> Set<UUID> { Set(s.timeline.lanes.map(\.id)).subtracting(lanes0.map(\.id)) }
                s.addLane(.video)
                let one = newIDs(), laneOK = one.count == 1 && s.timeline.lanes[nSub].id == one.first && ordered() && s.history.undoDepth == d0 + 1
                s.addLanePair()
                let pairOK = newIDs().count == 3 && ordered() && s.timeline.lanes.last.map { newIDs().contains($0.id) } == true && s.history.undoDepth == d0 + 2
                s.placeMedia(mid, atFrame: 0, lane: nil)
                let dropOK = newIDs().count >= 4 && ordered() && s.history.undoDepth == d0 + 3 && s.timeline.lanes[nSub].kind == .video && newIDs().contains(s.timeline.lanes[nSub].id)
                for _ in 0..<3 { s.undo() }
                _ = await previewSettled()
                check("lanes.videoLaneWithSubtitleLanes", laneOK && pairOK && dropOK && s.timeline.lanes == lanes0 && s.history.undoDepth == d0,
                      "lane \(laneOK) pair \(pairOK) drop \(dropOK) restored \(s.timeline.lanes == lanes0)")
            } else { check("lanes.videoLaneWithSubtitleLanes", false, "미디어 없음") }
            // 빈 자막 + 효과: 프리뷰 층 없음(그리지 않음)
            if let bid = s.createSubtitleAndEdit(atFrame: 0, output: nil) {
                pv.syncEditor(); await key(53, "\u{1b}")
                s.select(bid); s.styleEditChange(bid, project: proj) { $0.outline = .default; $0.background = .default }; s.finishColorSession()
                _ = await previewSettled()
                check("effects.blankStaysEmpty", s.timeline.subtitle(bid)?.style.hasEnabledEffects == true && s.previewHost?.subtitleLayerForTest(bid) == nil
                      && !s.timeline.renderedSubtitles.contains { $0.id == bid })
                s.select(bid); s.deleteSelection(ripple: false)
            } else { check("effects.blankStaysEmpty", false, "만들기 실패") }
        } else { check("effects.setup", false, "자막 없음") }
        await focusTimeline()

        // 19d. 코드 리뷰 고침: 색 조정 세션 중 프리뷰에서 끌어도 새 색이 남는다(끌기 시작 때 색이 먼저 한 단계, 옮기기가 다음 단계)
        if let piece = s.timeline.subtitles(inLane: s1).first(where: { !$0.isBlank }) {
            let cid = piece.id, proj = s.projectSession
            await key(9, "v"); s.seek(to: piece.start + 2); _ = await previewSettled()
            s.select(cid); await LaneSelfTest.settle()
            let before = s.timeline.subtitle(cid)!.style, dD = s.history.undoDepth
            s.colorEditChange(cid, red: 12, green: 200, blue: 90, alpha: before.alpha, project: proj)
            let tb = SubtitleRenderer.shared.hitBounds(s.timeline.subtitle(cid)!)
            let p0 = win(CGPoint(x: tb.midX, y: tb.midY))
            pv.mouseDown(with: ev(.leftMouseDown, p0)); await drainMain()
            for i in 1...6 { pv.mouseDragged(with: ev(.leftMouseDragged, NSPoint(x: p0.x + CGFloat(i * 5), y: p0.y))); await drainMain() }
            pv.mouseUp(with: ev(.leftMouseUp, NSPoint(x: p0.x + 30, y: p0.y))); await drainMain()
            let after = s.timeline.subtitle(cid)!.style
            let kept = [after.red, after.green, after.blue] == [12, 200, 90] && after.xMilli != before.xMilli && s.history.undoDepth == dD + 2
            s.undo(); let u1 = s.timeline.subtitle(cid)!.style
            s.undo(); let u2 = s.timeline.subtitle(cid)!.style
            check("review.dragAfterColorKeepsColor", kept && [u1.red, u1.green, u1.blue] == [12, 200, 90] && u1.xMilli == before.xMilli && u2 == before,
                  "after \([after.red, after.green, after.blue]) x \(before.xMilli)→\(after.xMilli) depth \(s.history.undoDepth - dD)")
            // 정보 패널 글 칸: 초점을 잃지 않아도 저장 등 앞의 확정 길(commitInlineEditIfAny)에서 들어간다(한 단계)
            EditorLayout.shared.leftTab = .adjust; s.select(cid); await LaneSelfTest.settle()
            func panelEditor() -> NSTextView? { LaneSelfTest.find(SubtitleTextEditor.TextView.self, w.contentView) }
            _ = await LaneSelfTest.waitUntil(3) { panelEditor() != nil }
            if let pe = panelEditor() {
                let keepText = s.timeline.subtitle(cid)!.text, dT = s.history.undoDepth
                w.makeFirstResponder(pe); pe.selectAll(nil); pe.insertText("패널 글", replacementRange: NSRange(location: NSNotFound, length: 0))
                let pending = s.panelTextCommit != nil && s.timeline.subtitle(cid)?.text == keepText
                s.commitInlineEditIfAny()   // 저장·내보내기·닫기·끝내기 앞과 같은 길
                let committed = s.timeline.subtitle(cid)?.text == "패널 글" && s.history.undoDepth == dT + 1 && s.panelTextCommit == nil
                w.makeFirstResponder(nil); await LaneSelfTest.settle()
                let noDouble = s.history.undoDepth == dT + 1
                check("review.panelTextCommittedBySaveHooks", pending && committed && noDouble, "pending \(pending) committed \(committed) once \(noDouble)")
                s.setSubtitleText(cid, keepText)
            } else { check("review.panelTextCommittedBySaveHooks", false, "정보 패널 글 칸 없음") }
            // 긴 글(2026-10-23): 화면보다 높은 자막도 글을 자르지 않고 화면 안 띠를 그리며(빈 그림 아님), 화면 밖 상태로 알린다. 내보내기는 막지 않는다.
            let keepLong = s.timeline.subtitle(cid)!.text
            let tall = (1...60).map { "긴 자막 \($0)" }.joined(separator: "\n")
            s.setSubtitleText(cid, tall); _ = await previewSettled()
            let item = s.timeline.subtitle(cid)!, rr = SubtitleRenderer.shared.raster(item)
            let layer = s.previewHost?.subtitleLayerForTest(cid)
            check("longText.visibleBandNotSilent", item.text == tall && !rr.failed && rr.clipped && rr.lines == 60 && rr.image.height <= 1080
                  && layer != nil && layer!.frame.height == rr.drawRect.height && s.exportBlockReason == nil,
                  "failed \(rr.failed) clipped \(rr.clipped) lines \(rr.lines) band \(rr.rect) draw \(rr.drawRect) layer \(layer.map { "\($0.frame)" } ?? "nil") block \(s.exportBlockReason ?? "nil")")
            s.setSubtitleText(cid, keepLong)
        } else { check("review.setup", false, "자막 없음") }
        await focusTimeline()

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 20. 메뉴 "자막 추가": 재생 헤드·기본 위치에 즉시 만들기(고른 자막 레인, 한 단계) + 편집 칸. Esc면 빈 자막으로 남음(아래 저장·내보내기에서 씀)
        s.select(nil); s.selectLane(s1); s.seek(to: 0)
        let n14 = s.timeline.subtitles.count, d14 = s.history.undoDepth
        let nextIn1 = s.timeline.subtitles(inLane: s1).filter { $0.start > 0 }.map(\.start).min() ?? Int.max
        let free0 = !s.timeline.subtitles(inLane: s1).contains { $0.start <= 0 && 0 < $0.end }
        let expectLen = min(90, nextIn1)
        let menuOK = LaneSelfTest.menuItem("자막 추가"); await LaneSelfTest.settle()
        _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
        let immediate = s.timeline.subtitles.count == n14 + 1 && ed() != nil && s.history.undoDepth == d14 + 1
        await key(53, "\u{1b}")
        let menuBlank = s.selectedSubtitle
        check("menu.addSubtitleImmediate", menuOK && immediate && menuBlank?.start == 0 && (free0 ? menuBlank?.length == expectLen && menuBlank?.lane == s1 : menuBlank?.lane != s1) && menuBlank?.style == .default
              && menuBlank?.text == "" && s.history.undoDepth == d14 + 1 && ed() == nil,
              "menu \(menuOK) immediate \(immediate) sel \(menuBlank.map { [$0.start, $0.length] } ?? []) expect \(expectLen) free \(free0) depth \(s.history.undoDepth - d14)")
        await focusTimeline()

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 21. 저장(형식 6)·다시 열기: 자막·레인 그대로
        let p6 = folder.appendingPathComponent("subtitles.ontheframe")
        let saved = s.timeline
        let ok6 = s.writeProject(to: p6)
        let ver6 = (try? Data(contentsOf: p6)).flatMap { try? ProjectFile.decode($0).document.version }
        s.resetProject(); await LaneSelfTest.settle()
        let opened = await s.openProject(at: p6)
        _ = await LaneSelfTest.waitUntil(10) { s.openProgress == nil }
        check("project.v6SaveReopen", ok6 && opened && ver6 == 6 && s.timeline.subtitles.sorted { $0.start < $1.start } == saved.subtitles.sorted { $0.start < $1.start }
              && s.timeline.lanes == saved.lanes, "saved \(ok6) opened \(opened) version \(ver6 ?? -1)")

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 22. 내보내기(구조 R): 자막 구간 프레임의 아래 가운데에 글자(밝은 화소)가 생긴다. 자막이 없는 프레임은 그대로.
        _ = await previewSettled()
        let out = folder.appendingPathComponent("out"); try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let dest = out.appendingPathComponent("subtitles.mp4")
        s.startExport(.fromSavePanel(dest))
        _ = await LaneSelfTest.waitUntil(120) { s.exportPhase == .idle }
        let exported = s.alert?.title == "내보내기 완료" && FileManager.default.fileExists(atPath: dest.path)
        if s.alerts.isShowing { s.alerts.pressButton(1) }
        _ = await LaneSelfTest.waitUntil(5) { !s.alerts.isShowing }
        var detail = s.alert?.message ?? ""
        var textOK = false
        if exported, let plan = s.currentPlan {
            // 프레임 45: 자막 [20,60)(노랑 60pt) 안. 프레임 110: 자막 없음(붙여 넣은 [100,140)은 지웠다)
            // 글자가 보이는 프레임과 글자 자막이 하나도 안 보이는 프레임(영상 구간 안)을 타임라인에서 고른다
            let vis = s.timeline.renderedSubtitles.first.map { $0.start + min(5, $0.length - 1) } ?? 45
            let region = s.timeline.subtitles(atFrame: vis).first(where: { !$0.isBlank }).map { SubtitleRenderer.shared.raster($0).textBounds.integral } ?? CGRect(x: 480, y: 820, width: 960, height: 180)
            let e = await brightCount(AVURLAsset(url: dest), nil, frame: vis, region: region)
            let ref = await brightCount(plan.composition, plan.videoComposition, frame: vis, region: region)
            let quiet = (0..<120).first { f in !s.timeline.subtitles(atFrame: f).contains { !$0.isBlank } } ?? 110
            let none = !s.timeline.subtitles(atFrame: quiet).contains { !$0.isBlank }
            let e2 = await brightCount(AVURLAsset(url: dest), nil, frame: quiet, region: region)
            let r2 = await brightCount(plan.composition, plan.videoComposition, frame: quiet, region: region)
            textOK = e > ref + 200 && none && abs(e2 - r2) < 50
            detail = "frames \(vis)/\(quiet) region \(region) bright export \(e) plan \(ref) | no-subtitle frame 110 (\(none)): export \(e2) plan \(r2)"
        }
        check("export.subtitleBurnedIn", exported && textOK, detail)
        // 빈 자막은 내보내기에 그리지 않는다: 빈 자막만 보이는 프레임 10의 기본 자리(빈 자막 누름 상자 둘레)가 계획(자막 없음)과 같음
        if exported, let plan = s.currentPlan, let mb = menuBlank {
            // 빈 자막만 보이는 프레임(타임라인에서 찾음)
            let fBlank = (mb.start..<mb.end).first { f in s.timeline.subtitles(atFrame: f).map(\.id) == [mb.id] }
            let region = SubtitleRenderer.caretBounds(mb.style).insetBy(dx: -200, dy: -40).integral
            let e = fBlank == nil ? -1 : await brightCount(AVURLAsset(url: dest), nil, frame: fBlank!, region: region)
            let r = fBlank == nil ? -1 : await brightCount(plan.composition, plan.videoComposition, frame: fBlank!, region: region)
            check("blank.notRenderedInExport", fBlank != nil && e >= 0 && abs(e - r) < 50 && !(plan.subtitles.contains { $0.id == mb.id }),
                  "frame \(fBlank.map(String.init) ?? "없음") export \(e) plan \(r)")
        } else { check("blank.notRenderedInExport", false, "export \(exported) plan \(s.currentPlan != nil) blank \(menuBlank != nil)") }

        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 23. 자막·자막 레인을 모두 지우면 형식 5로 저장(그 밖 데이터 그대로)
        for sub in s.timeline.subtitles { s.select(sub.id); s.deleteSelection(ripple: false) }
        for l in s.timeline.lanes(.subtitle) { s.requestRemoveLane(l.id) }
        await LaneSelfTest.settle()
        let p5 = folder.appendingPathComponent("plain.ontheframe")
        let ok5 = s.writeProject(to: p5)
        let ver5 = (try? Data(contentsOf: p5)).flatMap { try? ProjectFile.decode($0).document.version }
        check("project.subtitleFreeWritesV5", ok5 && ver5 == 5 && s.timeline.lanes(.subtitle).isEmpty && s.timeline.clips.count == 1, "version \(ver5 ?? -1) lanes \(s.timeline.lanes(.subtitle).count)")
        _ = await LaneSelfTest.regainFocus(w)   // 다른 앱이 앞에 오면 이후는 직접 경로(기록: mode.direct)
        // 24. 프로젝트 교체: 남은 초안은 새 프로젝트로 새지 않는다(편집 칸도 지워짐)
        await key(17, "t"); s.seek(to: 20)
        await click(win(CGPoint(x: 960, y: 500))); _ = await LaneSelfTest.waitUntil(3) { ed() != nil }
        type("새면 안 됨")
        let hadDraft = s.inlineEdit != nil
        s.resetProject(); await LaneSelfTest.settle()
        let leaked = s.timeline.subtitles.contains { $0.text == "새면 안 됨" } || s.inlineEdit != nil || ed() != nil || s.history.canUndo
        check("lifecycle.projectReplaceNoLeak", hadDraft && !leaked, "draft \(hadDraft) leaked \(leaked)")
        // 정보 패널 글 칸의 편집이 같은 파일을 다시 연 프로젝트로 새지 않는다(자막 ID가 같아도 회차가 다름)
        s.resetProject(); await LaneSelfTest.settle()
        let lid = s.createSubtitleAndEdit(atFrame: 0, output: nil)
        pv.syncEditor(); ed().map { _ in () }; await key(53, "\u{1b}")
        if let lid {
            s.setSubtitleText(lid, "원래 글")
            let pLeak = folder.appendingPathComponent("leak.ontheframe")
            _ = s.writeProject(to: pLeak)
            EditorLayout.shared.leftTab = .adjust; s.select(lid); await LaneSelfTest.settle()
            _ = await LaneSelfTest.waitUntil(3) { LaneSelfTest.find(SubtitleTextEditor.TextView.self, w.contentView) != nil }
            if let pe = LaneSelfTest.find(SubtitleTextEditor.TextView.self, w.contentView) {
                w.makeFirstResponder(pe); pe.selectAll(nil); pe.insertText("새면 안 됨", replacementRange: NSRange(location: NSNotFound, length: 0))
                let reopened = await s.openProject(at: pLeak)   // 확정 길을 거치지 않는 교체(예: 늦게 온 열기)
                _ = await LaneSelfTest.waitUntil(10) { s.openProgress == nil }
                s.select(lid); await LaneSelfTest.settle()
                w.makeFirstResponder(nil); await LaneSelfTest.settle()
                check("review.panelTextNoLeakAcrossProjects", reopened && s.timeline.subtitle(lid)?.text == "원래 글" && !s.history.canUndo,
                      "opened \(reopened) text \(s.timeline.subtitle(lid)?.text.debugDescription ?? "nil") canUndo \(s.history.canUndo)")
            } else { check("review.panelTextNoLeakAcrossProjects", false, "정보 패널 글 칸 없음") }
        } else { check("review.panelTextNoLeakAcrossProjects", false, "만들기 실패") }
        finish(folder, checks)
    }

    /// 프레임의 region(출력 픽셀, 자막 글자 사각형)에서 밝은 노랑·흰색(R 200 이상, G 180 이상) 화소 수
    static func brightCount(_ asset: AVAsset, _ vc: AVVideoComposition?, frame: Int, region: CGRect) async -> Int {
        let g = AVAssetImageGenerator(asset: asset)
        g.videoComposition = vc
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        guard let img = try? await g.image(at: CMTime(value: CMTimeValue(frame), timescale: 30)).image else { return -1 }
        let wd = 1920, ht = 1080
        guard let ctx = CGContext(data: nil, width: wd, height: ht, bitsPerComponent: 8, bytesPerRow: wd * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: wd, height: ht))
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        var n = 0
        let r = region.intersection(CGRect(x: 0, y: 0, width: wd, height: ht))
        guard !r.isNull, !r.isEmpty else { return -1 }
        for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) {
            let o = (y * wd + x) * 4   // CGContext 메모리는 첫 줄이 위
            if d[o] >= 200 && d[o + 1] >= 180 { n += 1 }
        } }
        return n
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: LaneSelfTest.direct ? "검사 \(LaneSelfTest.directFromCheck)개 뒤부터 앱이 활성 상태를 잃어(다른 앱이 앞) 마우스는 보기에 직접, 키는 같은 저장소 동작·글 칸 명령으로 보냄(그 뒤 KeyRouting·창 이벤트 경로는 검사 안 함)" : "합성 이벤트를 앱 이벤트 큐로 보냄")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("subtitle-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
