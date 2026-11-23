#if DEBUG
import AppKit
import OnTheFrameEngine

/// SpectrumPublicSelfTest 1–8절: 만들기 입구 두 곳과 그 뒤의 기존 편집 경로(14개 검사). 절마다 작은 함수 하나(컴파일 메모리 — SpectrumPublicSelfTest.swift 머리글).
/// 차례와 상태는 SpectrumPublicSelfTest.runSections와 Context가 잇는다.
extension SpectrumPublicSelfTest {
    /// 1. 보통 UI 만들기 ①: 소리 클립 문맥 메뉴. 구간 = 누른 조각, 소스 = 그 계보, 한 단계, 만든 것을 고름, 소리·영상 클립은 그대로
    static func checkCreateFromMenu(_ c: Context) async -> Bool {
        let s = c.s, base: Timeline = c.base, f2: Clip = c.f2
        let d0 = s.history.undoDepth
        if let mt = c.contextMenu(at: c.center(f2)), let it = mt.1 {
            mt.0.performActionForItem(at: mt.0.index(of: it))
            await LaneSelfTest.settle()
        }
        let t1 = s.timeline
        guard let made = t1.spectra.first, t1.spectra.count == 1 else {
            return c.stop("create.menu", "spectra \(t1.spectra.count) status \(s.statusMessage ?? "")")
        }
        c.made = made
        let shape = made.start == f2.start && made.length == f2.length && made.sourceKey == f2.lineageKey && made.style == .provisionalDefault
        let state = s.selection == made.id && s.history.undoDepth == d0 + 1 && t1.lanes(.spectrum).count == 1
        let untouched = t1.clips == base.clips && t1.audioClips == base.audioClips
        c.check("create.menu", shape && state && untouched, "item \(made.start)-\(made.end)")
        return true
    }

    /// 2. 보통 UI 만들기 ②: 클립 조정 패널 단추의 명령. 영상 클립을 골라도 연결된 소리가 대상(패널이 쓰는 audioTargetClip), 구간·소스 = 그 소리 클립.
    /// 이어서 만들기 실행 취소·다시 실행, 늦은 회차(다른 프로젝트에서 만든 단추·메뉴)는 아무것도 넣지 않음.
    static func checkCreateFromPanelCommand(_ c: Context) async {
        let s = c.s, base: Timeline = c.base, g2: Clip = c.g2, made: SpectrumItem = c.made, f1: Clip = c.f1
        let d1 = s.history.undoDepth   // 메뉴로 만든 뒤(= 처음 깊이 + 1)
        let t1 = s.timeline
        let v120 = base.clips.first { $0.lane == Lane.videoID && $0.start == g2.start }
        s.select(v120?.id)
        let target = s.audioTargetClip
        if let target { s.addSpectrum(fromAudioClip: target.id, session: s.projectSession) }
        await LaneSelfTest.settle()
        let t2 = s.timeline
        let madeG = t2.spectra.first { $0.id != made.id }
        c.t2 = t2; c.madeG = madeG
        let shape = target?.id == g2.id && t2.spectra.count == 2 && madeG?.start == g2.start && madeG?.length == g2.length && madeG?.sourceKey == g2.lineageKey
        let state = s.selection == madeG?.id && s.history.undoDepth == d1 + 1 && t2.audioClips == base.audioClips
        c.check("create.panelCommand", shape && state, "target \(target.map { "\($0.start)-\($0.end)" } ?? "none") spectra \(t2.spectra.count)")
        s.undo(); let undoneCreate = s.timeline == t1
        s.redo(); let redoneCreate = s.timeline == t2
        c.check("create.undoRedo", undoneCreate && redoneCreate, "undo \(undoneCreate) redo \(redoneCreate)")
        s.addSpectrum(fromAudioClip: f1.id, session: s.projectSession - 1)
        c.check("create.staleSessionNoChange", s.timeline == t2 && (s.statusMessage ?? "").contains("추가하지 않았습니다"))
    }

    /// 3. 오디오 소스 고르기: 목록 = 계보마다 하나, 다른 계보로 바꾸기(한 단계), 모르는 키 거부, 고르지 않음, 실행 취소. 소스를 바꿔도 구간·모양·소리 클립은 그대로.
    static func checkSourceSelection(_ c: Context) {
        let s = c.s, base: Timeline = c.base, made: SpectrumItem = c.made, t2: Timeline = c.t2
        let f1: Clip = c.f1, f2: Clip = c.f2, g2: Clip = c.g2, cp: Clip = c.cp
        s.select(made.id)
        let options = s.spectrumSourceOptions().map(\.key)
        let dS = s.history.undoDepth
        s.setSpectrumSource(made.id, key: cp.lineageKey, from: f2.lineageKey, project: s.projectSession)
        let changed = s.timeline.spectrum(made.id)?.sourceKey == cp.lineageKey && s.history.undoDepth == dS + 1
        let tS = s.timeline
        s.setSpectrumSource(made.id, key: UUID(), from: cp.lineageKey, project: s.projectSession)
        let unknownRejected = s.timeline == tS
        s.setSpectrumSource(made.id, key: nil, from: cp.lineageKey, project: s.projectSession)
        let unsetItem = s.timeline.spectrum(made.id)
        let unsetWarning = unsetItem.map { s.spectrumWarnings($0) == [.unset] } == true
        let unset = unsetItem?.sourceKey == nil && unsetWarning
        s.undo(); s.undo()
        let sourceUndone = s.timeline == t2
        s.redo()
        let sourceRedone = s.timeline == tS
        let optionsOK = Set(options) == Set([f1.lineageKey, g2.lineageKey, cp.lineageKey])
        c.check("source.select", optionsOK && changed && unknownRejected && unset && sourceUndone && sourceRedone,
                "options \(options.count) changed \(changed) unknown \(unknownRejected) unset \(unset) undo \(sourceUndone) redo \(sourceRedone)")
        let afterSource = s.timeline.spectrum(made.id)
        let timingKept = afterSource?.start == made.start && afterSource?.length == made.length && afterSource?.style == made.style
        c.check("source.keepsTiming", timingKept && s.timeline.audioClips == base.audioClips)
    }

    /// 4. 지원하는 모양 값 바꾸기(기존 setSpectrumStyle): 한 단계, 범위 밖은 거부, Softness는 건드리지 않음
    static func checkStyleEdit(_ c: Context) async -> Bool {
        let s = c.s, made: SpectrumItem = c.made
        s.select(made.id)
        await LaneSelfTest.settle()
        guard let before = s.timeline.spectrum(made.id) else { return c.stop("style.setup") }
        var style = before.style
        style.mode = .analog; style.sides = .above; style.bands = 32; style.reactionPercent = 150
        style.red = 255; style.green = 128; style.blue = 0; style.startXMilli = 300_000; style.maxHeightMilli = 240_000
        let dY = s.history.undoDepth
        let applyError = s.setSpectrumStyle(made.id, style: style, from: before.style, project: s.projectSession,
                                            selectionRevision: s.spectrumSelectionRevision, generation: s.generation)
        await LaneSelfTest.settle()
        let styled = s.timeline.spectrum(made.id)
        let tY = s.timeline
        var bad = style; bad.reactionPercent = 201
        let badError = s.setSpectrumStyle(made.id, style: bad, from: style, project: s.projectSession,
                                          selectionRevision: s.spectrumSelectionRevision, generation: s.generation)
        let badRejected = badError != nil && s.timeline == tY
        s.undo(); let styleUndone = s.timeline.spectrum(made.id)?.style == before.style
        s.redo(); let styleRedone = s.timeline == tY
        c.style = style; c.tY = tY
        let applied = applyError == nil && styled?.style == style && styled?.style.softnessPercent == before.style.softnessPercent
        let othersKept = styled?.start == before.start && styled?.sourceKey == before.sourceKey && s.history.undoDepth == dY + 1
        c.check("style.edit", applied && othersKept && badRejected && styleUndone && styleRedone,
                "apply \(applyError ?? "ok") bad \(badError ?? "accepted") undo \(styleUndone) redo \(styleRedone)")
        return true
    }

    /// 5. 타임라인 시작·길이(기존 엔진 편집, 저장소의 보통 편집 경로): 옮기기·트림은 소스·모양·소리 클립을 바꾸지 않는다. 겹치는 자리로는 옮기지 않는다.
    static func checkPlacementAndDuration(_ c: Context) {
        let s = c.s, base: Timeline = c.base, made: SpectrumItem = c.made, cp: Clip = c.cp, tY: Timeline = c.tY, style: SpectrumItemStyle = c.style
        let dP = s.history.undoDepth
        s.commit({ try $0.trimmingSpectrum(made.id, start: made.start, end: made.start + 30) }, focus: made.id)   // 길이 60 → 30(같은 레인의 다음 스펙트럼과 겹치지 않게 먼저 줄임)
        let trimmed = s.timeline.spectrum(made.id)
        s.commit({ try $0.relocatingSpectrum(made.id, toStart: made.start + 15) }, focus: made.id)
        let moved = s.timeline.spectrum(made.id)
        let tP = s.timeline
        c.tP = tP
        let timing = trimmed?.start == made.start && trimmed?.length == 30 && moved?.start == made.start + 15 && moved?.length == 30
        let kept = moved?.sourceKey == cp.lineageKey && moved?.style == style && tP.audioClips == base.audioClips && tP.clips == base.clips
        let placed = timing && kept && s.history.undoDepth == dP + 2
        s.undo(); s.undo(); let placeUndone = s.timeline == tY
        s.redo(); s.redo(); let placeRedone = s.timeline == tP
        c.check("timeline.placementAndDuration", placed && placeUndone && placeRedone,
                "trimmed \(trimmed.map { "\($0.start)-\($0.end)" } ?? "-") moved \(moved.map { "\($0.start)-\($0.end)" } ?? "-")")
        // 겹치는 자리로는 옮기지 않음(같은 레인의 다른 스펙트럼). 그 스펙트럼이 같은 레인에 없으면 검사할 수 없으므로 건너뛰지 않고 실패로 적는다.
        if let other = c.madeG, other.lane == made.lane {
            s.commit({ try $0.relocatingSpectrum(made.id, toStart: other.start) }, focus: made.id)
            c.check("timeline.overlapRejected", s.timeline == tP, s.statusMessage ?? "")
        } else {
            c.check("timeline.overlapRejected", false, "준비 실패: 같은 레인에 다른 스펙트럼이 없음")
        }
    }

    /// 6. 저장·다시 열기(기존 형식·기존 스펙트럼 직렬화): ID·레인·구간·소스 키·모양 그대로. 스펙트럼 항목이 있는 저장은 형식 11.
    static func checkSaveReopen(_ c: Context) async {
        let s = c.s, tP: Timeline = c.tP
        let file = c.out.appendingPathComponent("public-saved.ontheframe")
        let saved = s.writeProject(to: file)
        let version = c.fileVersion(file)
        let reopened = await s.openProject(at: file)
        await dismiss()
        await LaneSelfTest.settle()
        let r = s.timeline
        c.r = r
        let spectraSame = r.spectra == tP.spectra && r.lanes(.spectrum).map(\.id) == tP.lanes(.spectrum).map(\.id)
        let clipsSame = r.audioClips == tP.audioClips && r.clips == tP.clips
        c.check("persist.saveReopen", saved && reopened && spectraSame && clipsSame, "saved \(saved) reopened \(reopened) version \(version.map(String.init) ?? "-")")
        c.check("persist.existingSpectrumFormat", version == 11 && ProjectFile.version(for: tP) == 11, "version \(version.map(String.init) ?? "-") expected 11(스펙트럼 항목이 있는 저장)")
    }

    /// 7. 고르기·삭제: 누르면 고름, Delete(일반 삭제)는 그 스펙트럼만 지우고 레인·소리 클립은 그대로, 실행 취소로 같은 ID가 돌아옴. 리플 삭제는 하지 않음
    static func checkSelectAndDelete(_ c: Context) async -> Bool {
        let s = c.s, r: Timeline = c.r, made: SpectrumItem = c.made, tv = c.tv
        guard let keep = r.spectra.first(where: { $0.id == made.id }) else { return c.stop("delete.setup") }
        let pItem = NSPoint(x: tv.x(keep.start + keep.length / 2), y: tv.laneRect(keep.lane)?.midY ?? 0)
        s.select(nil)
        await LaneSelfTest.mouse(.leftMouseDown, c.win(pItem), c.w)
        await LaneSelfTest.mouse(.leftMouseUp, c.win(pItem), c.w)
        await LaneSelfTest.settle()
        let clickedSelects = LaneSelfTest.direct ? true : s.selection == keep.id
        if s.selection != keep.id { s.select(keep.id) }
        let hit = tv.spectrumHit(pItem) == keep.id
        s.deleteSelection(ripple: true)
        let rippleRefused = s.timeline == r
        let dD = s.history.undoDepth
        s.deleteSelection()
        let tDel = s.timeline
        let gone = tDel.spectrum(keep.id) == nil && tDel.spectra.count == r.spectra.count - 1 && tDel.lanes(.spectrum).count == r.lanes(.spectrum).count
        let restKept = tDel.audioClips == r.audioClips && tDel.clips == r.clips && s.history.undoDepth == dD + 1 && s.selection == nil
        let deleted = gone && restKept
        s.undo(); let deleteUndone = s.timeline == r
        s.redo(); let deleteRedone = s.timeline == tDel
        s.undo()
        c.check("select.clickAndHit", clickedSelects && hit, LaneSelfTest.direct ? "직접 경로(합성 누름 미검사)" : "click \(clickedSelects) hit \(hit)")
        c.check("delete.liftOnly", rippleRefused && deleted && deleteUndone && deleteRedone, "ripple \(rippleRefused) deleted \(deleted) undo \(deleteUndone) redo \(deleteRedone)")
        return true
    }

    /// 8. 소스 없음: 소스 계보의 소리 클립을 모두 지우면 경고만 바뀌고 소스 키·다른 스펙트럼은 그대로(다른 소스로 바꾸지 않음), 실행 취소로 되살아남
    static func checkMissingSource(_ c: Context) -> Bool {
        let s = c.s, r: Timeline = c.r, made: SpectrumItem = c.made, cp: Clip = c.cp
        guard s.timeline == r, let src = r.spectrum(made.id), src.sourceKey == cp.lineageKey else { return c.stop("missing.setup") }
        let okBefore = r.spectrumSourceState(src) == .ok && !s.spectrumWarnings(src).contains(.missingSource)
        s.commit({ try $0.lifting(clip: cp.id) }, focus: nil)
        let tM = s.timeline, orphan = tM.spectrum(made.id)
        let stateMissing = orphan.map { tM.spectrumSourceState($0) == .missing && s.spectrumWarnings($0) == [.missingSource] } == true
        let itemKept = orphan?.sourceKey == cp.lineageKey && orphan?.start == src.start && orphan?.length == src.length && orphan?.style == src.style
        let othersBefore = r.spectra.filter { $0.id != made.id }
        let othersAfter = tM.spectra.filter { $0.id != made.id }
        let notOffered = !s.spectrumSourceOptions().map(\.key).contains(cp.lineageKey)
        let noUncoveredNote = orphan.map { s.spectrumUncoveredRanges($0).isEmpty } == true
        let missing = stateMissing && itemKept && othersAfter == othersBefore && notOffered && noUncoveredNote
        s.undo()
        let restored = s.timeline == r && s.timeline.spectrum(made.id).map { s.timeline.spectrumSourceState($0) == .ok } == true
        c.check("missing.sourceHandledSafely", okBefore && missing && restored, "before \(okBefore) missing \(missing) restored \(restored)")
        return true
    }
}
#endif
