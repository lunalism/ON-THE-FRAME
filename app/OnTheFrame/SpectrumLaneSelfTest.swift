#if DEBUG
import AppKit
import OnTheFrameEngine

/// 스펙트럼 레인 타임라인 표시 자체 검사(2026-10-25, SP-1A 2A, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFSpectrumLaneTest`.
/// 앱에는 아직 스펙트럼 레인·스펙트럼을 만드는 명령이 없고 스펙트럼이 든 프로젝트를 열지 않으므로, 엔진 편집(addingLane(.spectrum)·addingSpectrum)을
/// 저장소의 보통 편집 경로(commit)로 넣고 실제 보기(TimelineNSView·LaneHeaderView)·합성 마우스·키 이벤트로 본다. 생성 fixture(otf-TA)만.
/// 화소 검사는 보기의 그림(cacheDisplay)을 읽는 것이며 화면 표시를 눈으로 본 것이 아니다. 결과는 <폴더>/spectrum-lane-result.json.
@MainActor
enum SpectrumLaneSelfTest {
    typealias Check = LaneSelfTest.Check

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { return finish(folder, [Check(name: "setup.window", pass: false, detail: "")]) }
        _ = await LaneSelfTest.regainFocus(w)
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        guard let asset = s.assets.first else { return finish(folder, [Check(name: "setup.import", pass: false, detail: "")]) }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        s.addToTimeline(asset.id)
        _ = await LaneSelfTest.waitUntil(10) { s.canPlay }
        guard let container = LaneSelfTest.find(TimelineContainerView.self, w.contentView), let v0 = s.timeline.clips.first?.id,
              let a0 = s.timeline.audioClips.first?.id else { return finish(folder, [Check(name: "setup.timeline", pass: false, detail: "")]) }
        let tv = container.timelineView, header = container.header
        await LaneSelfTest.settle()
        func viewPoint(_ lane: UUID, frame: Int) -> NSPoint { NSPoint(x: tv.x(frame), y: tv.laneRect(lane)?.midY ?? 0) }
        func win(_ p: NSPoint) -> NSPoint { tv.convert(p, to: nil) }
        func click(_ p: NSPoint, mods: NSEvent.ModifierFlags = []) async {
            await LaneSelfTest.mouse(.leftMouseDown, win(p), w, mods: mods); await LaneSelfTest.mouse(.leftMouseUp, win(p), w, mods: mods)
        }
        /// 보기 그림의 한 점 색(보기 좌표, cacheDisplay — 화면 표시가 아님)
        func pixel(_ p: NSPoint) -> NSColor? {
            let r = NSRect(x: p.x.rounded(.down), y: p.y.rounded(.down), width: 2, height: 2)
            guard let rep = tv.bitmapImageRepForCachingDisplay(in: r) else { return nil }
            tv.cacheDisplay(in: r, to: rep)
            return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
        }
        func rgb(_ c: NSColor?) -> String { c.map { String(format: "%.3f,%.3f,%.3f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "nil" }
        func near(_ a: NSColor?, _ b: NSColor?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02
        }

        // 1. 스펙트럼 없는 기본 배치: 레인 순서·위치(이전 상수와 같음), 레인 머리와 타임라인의 줄이 같은 자리
        let t0 = s.timeline
        let baseRows = TimelineNSView.layout(t0.lanes).map { [$0.rect.minY, $0.rect.height] }
        check("baseline.noSpectrumLayout", t0.lanes.map(\.kind) == [.video, .audio] && tv.laneRect(Lane.videoID)?.minY == TimelineNSView.videoY
              && tv.laneRect(Lane.audioID)?.minY == TimelineNSView.audioY && !t0.needsSpectrumFormat, "rows \(baseRows)")

        // 2. 자막 레인 + 스펙트럼 레인(엔진 편집, 한 단계씩): 순서 자막 → 스펙트럼 → 영상 → 오디오, 라벨 SP1, 높이·색, 머리 줄 = 타임라인 줄
        let d0 = s.history.undoDepth
        s.addLane(.subtitle)
        let sl = UUID()
        s.commit({ try $0.addingLane(.spectrum, name: s.newLaneName(.spectrum), id: sl, outward: true) }, focus: nil)
        await LaneSelfTest.settle()
        let t1 = s.timeline
        let rows = TimelineNSView.layout(t1.lanes)
        let ys = rows.map(\.rect.minY)
        check("lane.order", t1.lanes.map(\.kind) == [.subtitle, .spectrum, .video, .audio] && t1.isValid && s.history.undoDepth == d0 + 2,
              "kinds \(t1.lanes.map(\.kind.rawValue))")
        check("lane.labelNameKind", t1.laneLabel(sl) == "SP1" && t1.laneInfo(sl)?.name == "스펙트럼" && ProjectStore.laneKindName(.spectrum) == "스펙트럼 레인",
              "label \(t1.laneLabel(sl)) name \(t1.laneInfo(sl)?.name ?? "")")
        check("lane.heightAndDistinctColor", tv.laneRect(sl)?.height == TimelineNSView.spectrumHeight
              && Set([LaneKind.video, .audio, .subtitle, .spectrum].map { TimelineNSView.color($0) }).count == 4, "height \(tv.laneRect(sl)?.height ?? -1)")
        let headerMatches = t1.lanes.allSatisfy { l in
            let hr = header.rowRect(l.id), tr = tv.laneRect(l.id) ?? .zero
            return abs(hr.minY + header.verticalOffset - tr.minY) < 0.5 && abs(hr.height - tr.height) < 0.5
        }
        check("layout.monotonicAndHeaderAligned", zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 } && headerMatches
              && tv.frame.height >= TimelineNSView.contentHeight(t1.lanes) - 0.5, "ys \(ys)")
        // 영상·소리 클립: 가로 위치는 그대로, 세로는 새 레인만큼 아래(그린 자리 = 누름 판정 자리)
        let vMid = viewPoint(Lane.videoID, frame: 60), aMid = viewPoint(Lane.audioID, frame: 60)
        check("layout.clipsHitWhereDrawn", tv.clipHit(vMid)?.0 == v0 && tv.clipHit(aMid)?.0 == a0 && s.timeline.clip(v0)?.start == 0
              && (tv.laneRect(Lane.videoID)?.minY ?? 0) > (tv.laneRect(sl)?.maxY ?? .infinity), "video \(tv.laneRect(Lane.videoID) ?? .zero)")

        // 3. 빈 스펙트럼 레인: 누를 항목 없음, 빈틈·무음 빗금 없음(빈 자막 레인과 같은 배경), 영상 빈틈과 다름
        let empty = viewPoint(sl, frame: 60)
        let sub = t1.lanes.first { $0.kind == .subtitle }!.id
        check("empty.noHit", tv.clipHit(empty) == nil)
        let pSpec = pixel(empty), pSub = pixel(viewPoint(sub, frame: 60))
        check("empty.noGapHatch", near(pSpec, pSub), "spectrum \(rgb(pSpec)) subtitle \(rgb(pSub))")
        // 누르면 선택이 풀리고(빈 곳과 같음) 편집 기록·타임라인 그대로, 끌기도 아무것도 바꾸지 않음
        s.select(v0)
        let dE = s.history.undoDepth
        await click(empty)
        await LaneSelfTest.mouse(.leftMouseDown, win(empty), w)
        await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: empty.x + 40, y: empty.y)), w)
        await LaneSelfTest.mouse(.leftMouseUp, win(NSPoint(x: empty.x + 40, y: empty.y)), w)
        check("empty.clickAndDragNoEdit", s.selection == nil && s.timeline == t1 && s.history.undoDepth == dE && s.gestureBase == nil,
              "selection \(String(describing: s.selection)) depth \(s.history.undoDepth - dE)")
        // 레인 머리 누름: 레인 고르기(기존 동작) — 정보 패널 레인
        await LaneSelfTest.mouse(.leftMouseDown, header.convert(NSPoint(x: 50, y: header.rowRect(sl).midY), to: nil), w)
        await LaneSelfTest.mouse(.leftMouseUp, header.convert(NSPoint(x: 50, y: header.rowRect(sl).midY), to: nil), w)
        check("header.selectsLane", s.selectedLane == sl && s.selection == nil && s.inspectedLane?.kind == .spectrum && s.timeline == t1)
        // 미디어를 스펙트럼 레인에 놓으면 아무것도 바뀌지 않음(종류가 다른 레인)
        tv.drop(asset.id, at: viewPoint(sl, frame: 200))
        await LaneSelfTest.settle()
        check("empty.dropMediaRejected", s.timeline == t1 && s.history.undoDepth == dE, s.statusMessage ?? "")

        // 4. 확대·스크롤·재생 헤드: 가로 대응은 레인과 무관, 확대 뒤에도 그린 자리 = 누름 판정
        let ppf0 = tv.pixelsPerFrame
        s.seek(to: 45)
        s.timelineZoom = 6
        await LaneSelfTest.settle()
        let zoomOK = tv.pixelsPerFrame == 6 && tv.frame(atX: tv.x(45)) == 45 && tv.clipHit(viewPoint(Lane.videoID, frame: 90))?.0 == v0
            && tv.clipHit(viewPoint(sl, frame: 90)) == nil
        let phX = tv.x(s.playhead)
        tv.scroll(NSPoint(x: max(0, phX - 100), y: 0)); await LaneSelfTest.settle()
        let rowsAfter = TimelineNSView.layout(s.timeline.lanes).map(\.rect.minY)
        check("zoomScroll.playheadAligned", zoomOK && rowsAfter == ys && s.playhead == 45 && abs(tv.x(s.playhead) - phX) < 0.01,
              "ppf \(ppf0)→\(tv.pixelsPerFrame) playheadX \(phX)")
        s.timelineZoom = Double(ppf0); await LaneSelfTest.settle()
        tv.scroll(.zero); await LaneSelfTest.settle()

        // 5. 단축키(기존 그대로): 고른 것 없이 ⌘K는 재생 헤드 아래 영상을 자름 → ⌘Z, 자르기·선택 도구 키, Delete는 레인을 고른 상태에서 아무것도 안 함
        _ = await LaneSelfTest.regainFocus(w)
        w.makeFirstResponder(tv)
        s.selectLane(sl)
        await LaneSelfTest.key(51, "\u{7f}", [], w)
        let afterDelete = s.timeline == t1
        s.select(nil); s.selectLane(nil); s.seek(to: 30)
        await LaneSelfTest.key(40, "k", [.command], w)
        let split = s.timeline.clips.count == 2 && s.timeline.lanes == t1.lanes
        await LaneSelfTest.key(6, "z", [.command], w)
        let undone = s.timeline == t1
        await LaneSelfTest.key(8, "c", [], w); let cutTool = s.tool == .cut
        await LaneSelfTest.key(9, "v", [], w); let selTool = s.tool == .selection
        check("shortcuts.unchanged", afterDelete && split && undone && cutTool && selTool, "delete \(afterDelete) split \(split) undo \(undone) C \(cutTool) V \(selTool)")

        // 6. 스펙트럼 항목(읽기 전용 표시): 그려짐, 누름·끌기·자르기 도구로 고르거나 바꾸지 않음
        let spID = UUID()
        s.commit({ try $0.addingSpectrum(lane: sl, at: 10, length: 50, sourceKey: $0.clip(a0)?.lineageKey, id: spID) }, focus: nil)
        await LaneSelfTest.settle()
        let t2 = s.timeline
        let onItem = viewPoint(sl, frame: 35), offItem = viewPoint(sl, frame: 90)
        let pOn = pixel(onItem), pOff = pixel(offItem)
        check("item.drawnReadOnly", t2.spectra.count == 1 && t2.spectrumSourceState(t2.spectra[0]) == .ok && !near(pOn, pOff) && tv.clipHit(onItem) == nil,
              "on \(rgb(pOn)) off \(rgb(pOff))")
        // 검토용 그림(레인 머리 + 타임라인, cacheDisplay — 화면 표시가 아님). KEEP=1이면 실행 폴더에 남는다.
        if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
            container.cacheDisplay(in: container.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("timeline-spectrum.png"))
        }
        let dI = s.history.undoDepth
        await click(onItem)
        await LaneSelfTest.mouse(.leftMouseDown, win(onItem), w)
        await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: onItem.x + 60, y: onItem.y)), w)
        await LaneSelfTest.mouse(.leftMouseUp, win(NSPoint(x: onItem.x + 60, y: onItem.y)), w)
        s.setTool(.cut); await click(onItem); s.setTool(.selection)
        check("item.notSelectableOrEditable", s.selection == nil && s.timeline == t2 && s.history.undoDepth == dI && s.gestureBase == nil,
              "selection \(String(describing: s.selection)) depth \(s.history.undoDepth - dI)")
        // 스펙트럼이 있는 레인은 지우지 않음(2A: 스펙트럼 삭제 UI 없음)
        s.requestRemoveLane(sl); await LaneSelfTest.settle()
        check("item.laneNotRemovable", !s.canRemoveLane(t2.laneInfo(sl)!) && s.timeline == t2 && !s.alerts.isShowing && (s.statusMessage ?? "").contains("스펙트럼"),
              s.statusMessage ?? "")

        // 7. 안전 장치: 스펙트럼이 든 계획은 내보내지 않음(대상 없음), 스펙트럼이 든 프로젝트는 열지 않음(파일 그대로)
        let out = folder.appendingPathComponent("out"); try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let dest = out.appendingPathComponent("spectrum.mp4")
        s.startExport(.fromSavePanel(dest))
        _ = await LaneSelfTest.waitUntil(60) { s.exportPhase == .idle && s.alerts.isShowing }
        let exportMsg = s.alert?.message ?? ""
        let exportRefused = s.alert?.title == "내보내기 실패" && exportMsg.contains("스펙트럼") && !FileManager.default.fileExists(atPath: dest.path)
        if s.alerts.isShowing { s.alerts.pressButton(0) }
        _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing }
        check("guard.exportRefused", exportRefused, String(exportMsg.prefix(120)))
        let proj = out.appendingPathComponent("spectrum.ontheframe")
        let saved = s.writeProject(to: proj)
        let bytes = try? Data(contentsOf: proj)
        let ver = bytes.flatMap { try? ProjectFile.decode($0).document.version }
        let before = s.timeline
        let opened = await s.openProject(at: proj)
        let openMsg = s.alert?.message ?? ""
        if s.alerts.isShowing { s.alerts.pressButton(0) }
        _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing }
        check("guard.openRefused", saved && ver == 8 && !opened && openMsg.contains("스펙트럼") && s.timeline == before && (try? Data(contentsOf: proj)) == bytes,
              "saved \(saved) version \(ver ?? -1) opened \(opened)")

        // 8. 빈 스펙트럼 레인은 지울 수 있음(확인 없이 한 단계, 실행 취소로 되돌림) — 항목은 엔진 편집으로 먼저 뺀다
        s.commit({ try $0.liftingSpectrum(spID) }, focus: nil)
        let t3 = s.timeline, dR = s.history.undoDepth
        s.requestRemoveLane(sl); await LaneSelfTest.settle()
        let removed = s.timeline.laneInfo(sl) == nil && !s.alerts.isShowing && s.history.undoDepth == dR + 1
        s.undo(); await LaneSelfTest.settle()
        check("empty.laneRemovableUndo", t3.spectra.isEmpty && removed && s.timeline == t3, "removed \(removed)")
        finish(folder, checks)
    }

    /// 소유자 화면 확인용 수동 모드(2026-10-26, SP-1A 2A, Debug 전용): `scripts/spectrum-lane-manual.sh`(`-OTFSpectrumLaneManual`).
    /// 일회용 폴더의 생성 fixture(otf-TA)로 메모리 안 타임라인을 엔진 편집으로 만들어 실행 취소 기록 없이 넣고(loadTimelineForTest) 창을 열어 둔다.
    /// 저장·내보내기·열기는 하지 않는다. 레인: 자막 → 스펙트럼(빈 레인) → 스펙트럼(항목 셋) → 영상 → 오디오.
    /// 항목: 소스 있음(첫 소리 클립), 소스 없음(두 번째 소리 클립을 소스로 둔 뒤 그 클립을 지움 — 빈틈으로 남음), 소스 고르지 않음.
    /// 만든 상태는 <폴더>/spectrum-lane-manual.json에 적는다(소유자 관찰이 아님). 창을 닫을 때 저장 질문 없이 닫힌다.
    static func runManual(folder: URL) async {
        let s = ProjectStore.shared
        func write(_ info: [String: String]) {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(info) { try? d.write(to: folder.appendingPathComponent("spectrum-lane-manual.json")) }
        }
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        guard let m = s.assets.first else { return write(["setup": "import failed"]) }
        let c1 = UUID(), c2 = UUID(), subL = UUID(), sp1 = UUID(), sp2 = UUID()
        let t: Timeline
        do {
            var x = try s.timeline.appending(media: m.id, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: c1)
            x = try x.appending(media: m.id, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: c2)
            let a = x.audioClips.sorted { $0.start < $1.start }
            guard a.count == 2 else { return write(["setup": "audio clips \(a.count)"]) }
            x = try x.addingLane(.subtitle, name: s.newLaneName(.subtitle), id: subL, outward: true)
            x = try x.addingSubtitle(lane: subL, at: 0, length: 90, text: "자막 확인 (SP-1A 2A)")
            x = try x.addingLane(.spectrum, name: "스펙트럼 항목", id: sp1, outward: true)
            x = try x.addingLane(.spectrum, name: "빈 스펙트럼", id: sp2, outward: true)
            x = try x.addingSpectrum(lane: sp1, at: 0, length: a[0].length, sourceKey: a[0].lineageKey)
            x = try x.addingSpectrum(lane: sp1, at: a[1].start + 10, length: 70, sourceKey: a[1].lineageKey)
            x = try x.addingSpectrum(lane: sp1, at: a[1].start + 85, length: 35, sourceKey: nil)
            t = try x.lifting(clip: c2)
        } catch { return write(["setup": "edit failed: \(error)"]) }
        s.loadTimelineForTest(t)
        _ = await LaneSelfTest.waitUntil(10) { s.canPlay }
        s.discardConfirmedForTest()   // 일회용 fixture: 창을 닫거나 끝낼 때 저장 질문 없이 닫힘
        let states = t.spectra.sorted { $0.start < $1.start }.map { "\(t.laneLabel($0.lane)) \($0.start)..<\($0.end) \(t.spectrumSourceState($0))" }
        write(["setup": "ok",
               "lanes": t.lanes.map { "\(t.laneLabel($0.id)) \($0.kind.rawValue) \($0.name)" }.joined(separator: " | "),
               "spectra": states.joined(separator: " | "),
               "subtitles": "\(t.subtitles.count)", "videoClips": "\(t.clips.count)", "audioClips": "\(t.audioClips.count)",
               "durationFrames": "\(t.durationFrames)", "needsSpectrumFormat": "\(t.needsSpectrumFormat)",
               "exportBlockers": "\(t.spectrumExportBlockers().count)", "undoDepth": "\(s.history.undoDepth)"])
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: LaneSelfTest.direct ? "앱을 활성화할 수 없어 직접 경로(KeyRouting 미검사)" : "합성 이벤트를 앱 이벤트 큐로 보냄")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("spectrum-lane-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
