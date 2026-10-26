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
        // 준비 조건(T-H1): 위 두 레인 편집이 실패했으면 강제 풀기로 멈추지 않고 실패로 남기고 끝낸다(뒤 검사는 이 레인들에 기댄다)
        guard t1.laneInfo(sl)?.kind == .spectrum, let sub = t1.lanes.first(where: { $0.kind == .subtitle })?.id else {
            return finish(folder, checks + [Check(name: "lane.setup", pass: false, detail: "kinds \(t1.lanes.map(\.kind.rawValue)) status \(s.statusMessage ?? "")")])
        }
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

        // 6. 스펙트럼 항목: 그려짐. 누르면 고름(2B-2 — 2A에서는 고르지 않았다), 4 pt 아래 끌기·자르기 도구로 옮기거나 자르지 않음(옮기기는 2C-1 — 12절)
        let spID = UUID()
        s.commit({ try $0.addingSpectrum(lane: sl, at: 10, length: 50, sourceKey: $0.clip(a0)?.lineageKey, id: spID) }, focus: nil)
        await LaneSelfTest.settle()
        let t2 = s.timeline
        // 준비 조건(T-H1): 스펙트럼을 넣지 못했으면(편집 실패는 상태 줄만 남김) 아래 t2의 첫 항목 첨자에서 멈추지 않고 실패로 끝낸다
        guard let sp0 = t2.spectra.first, t2.spectra.count == 1 else {
            return finish(folder, checks + [Check(name: "item.setup", pass: false, detail: "spectra \(t2.spectra.count) status \(s.statusMessage ?? "")")])
        }
        let onItem = viewPoint(sl, frame: 35), offItem = viewPoint(sl, frame: 90)
        let pOn = pixel(onItem), pOff = pixel(offItem)
        check("item.drawnReadOnly", t2.spectrumSourceState(sp0) == .ok && !near(pOn, pOff) && tv.clipHit(onItem) == nil,
              "on \(rgb(pOn)) off \(rgb(pOff))")
        // 검토용 그림(레인 머리 + 타임라인, cacheDisplay — 화면 표시가 아님). KEEP=1이면 실행 폴더에 남는다.
        if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
            container.cacheDisplay(in: container.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("timeline-spectrum.png"))
        }
        let dI = s.history.undoDepth
        await click(onItem)
        await LaneSelfTest.mouse(.leftMouseDown, win(onItem), w)
        await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: onItem.x + 3, y: onItem.y)), w)   // 4 pt 아래: 옮기지 않음
        await LaneSelfTest.mouse(.leftMouseUp, win(NSPoint(x: onItem.x + 3, y: onItem.y)), w)
        s.setTool(.cut); await click(onItem); s.setTool(.selection)
        check("item.selectableNoEditBelowThreshold", s.selection == spID && s.timeline == t2 && s.history.undoDepth == dI && s.gestureBase == nil,
              "selection \(String(describing: s.selection)) depth \(s.history.undoDepth - dI)")
        // 스펙트럼이 있는 레인은 지우지 않음(2A: 스펙트럼 삭제 UI 없음)
        s.requestRemoveLane(sl); await LaneSelfTest.settle()
        check("item.laneNotRemovable", t2.laneInfo(sl).map { !s.canRemoveLane($0) } == true && s.timeline == t2 && !s.alerts.isShowing && (s.statusMessage ?? "").contains("스펙트럼"),
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
        // 2B-1(2026-10-26): 1단계의 임시 열기 거부를 뺐다 — 저장한 형식 8 파일이 열리고 같은 타임라인(스펙트럼 레인·항목·소스 키), 저장 상태, 파일 그대로
        let before = s.timeline
        let opened = await s.openProject(at: proj)
        let openAlert = s.alert?.message
        await dismiss()
        check("open.savedSpectrumProject", saved && ver == 8 && opened && openAlert == nil && s.timeline == before && s.timeline.spectrum(spID)?.sourceKey == sp0.sourceKey
              && !s.isDirty && s.history.undoDepth == 0 && s.projectURL == proj.standardizedFileURL && (try? Data(contentsOf: proj)) == bytes,
              "saved \(saved) version \(ver ?? -1) opened \(opened) alert '\(openAlert ?? "")'")

        // 8. 빈 스펙트럼 레인은 지울 수 있음(확인 없이 한 단계, 실행 취소로 되돌림) — 항목은 엔진 편집으로 먼저 뺀다
        s.commit({ try $0.liftingSpectrum(spID) }, focus: nil)
        let t3 = s.timeline, dR = s.history.undoDepth
        s.requestRemoveLane(sl); await LaneSelfTest.settle()
        let removed = s.timeline.laneInfo(sl) == nil && !s.alerts.isShowing && s.history.undoDepth == dR + 1
        s.undo(); await LaneSelfTest.settle()
        check("empty.laneRemovableUndo", t3.spectra.isEmpty && removed && s.timeline == t3, "removed \(removed)")

        // 9. 2B-1 열기·왕복(2026-10-26): 상태 A–F, 저장·다시 열기 반복, 이전 형식, 잘못된 파일, 실패한 저장, 취소, 원본 파일 없음.
        //    모두 실행 폴더 안 일회용 파일(생성 fixture otf-TA와 그 사본). 저장은 보통 저장 경로(writeProject), 열기는 openProject.
        let ta = folder.appendingPathComponent("sources/otf-TA.mp4")
        let fm = FileManager.default
        // 9a. 상태 A–E가 든 프로젝트: 빈 스펙트럼 레인, 소스 정상 2(그중 하나는 바꾼 모양), 고르지 않음, 지워진 소스, 스펙트럼 레인 3개·항목 4개 + 계보·자막(효과)
        let pR = out.appendingPathComponent("rich.ontheframe")
        guard let rich = await makeProject(s, file: pR, media: ta, build: richTimeline) else { return finish(folder, checks + [Check(name: "persist.setup", pass: false, detail: s.statusMessage ?? "")]) }
        let richBytes = try? Data(contentsOf: pR)
        let richDoc = richBytes.flatMap { try? ProjectFile.decode($0) }
        check("persist.richSaved", richDoc?.document.version == 8 && richDoc?.timeline == rich && Self.states(rich) == Self.richStates,
              "version \(richDoc?.document.version ?? -1) states \(Self.states(rich))")
        s.resetProject()
        let o1 = await s.openProject(at: pR)
        let o1Alert = s.alert?.message; await dismiss()
        let r1 = s.timeline
        let lineageOK = { (t: Timeline) in t.audioClips.filter { $0.origin != nil }.count == 2 && Set(t.audioClips.map(\.lineageKey)).count == 1 }
        check("open.richRestored", o1 && o1Alert == nil && r1 == rich && Self.states(r1) == Self.richStates && r1.spectra.map(\.sourceKey) == rich.spectra.map(\.sourceKey)
              && r1.spectra.map(\.style) == rich.spectra.map(\.style) && r1.lanes == rich.lanes && lineageOK(r1) && !s.isDirty && s.missingMedia.isEmpty && s.history.undoDepth == 0,
              "opened \(o1) alert '\(o1Alert ?? "")' states \(Self.states(r1))")
        // 연 뒤: 항목을 누르면 고르기만(2B-2), 4 pt 아래 끌기는 아무것도 바꾸지 않고(옮기기는 12절), 항목이 든 레인은 지우지 않음(Delete 삭제는 10절)
        await LaneSelfTest.settle()
        guard let item = r1.spectra.first else { return finish(folder, checks) }   // 열지 못했으면 위 검사가 실패로 남는다
        let itemLane = item.lane
        let onR = viewPoint(itemLane, frame: item.start + item.length / 2)
        await click(onR)
        await LaneSelfTest.mouse(.leftMouseDown, win(onR), w)
        await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: onR.x + 3, y: onR.y)), w)
        await LaneSelfTest.mouse(.leftMouseUp, win(NSPoint(x: onR.x + 3, y: onR.y)), w)
        s.requestRemoveLane(itemLane); await LaneSelfTest.settle()
        check("open.selectNoEditBelowThreshold", tv.clipHit(onR) == nil && s.selection == item.id && s.timeline == rich && s.history.undoDepth == 0 && !s.alerts.isShowing
              && s.timeline.laneInfo(itemLane) != nil, "selection \(String(describing: s.selection)) depth \(s.history.undoDepth)")
        // 9b. 다시 저장(같은 위치, ⌘S가 부르는 writeProject) → 같은 문서. 바이트가 같은지도 본다(북마크를 다시 만들어 다를 수 있음 — 기록만)
        let resaved = s.writeProject(to: pR)
        let resavedBytes = try? Data(contentsOf: pR)
        let resavedDoc = resavedBytes.flatMap { try? ProjectFile.decode($0) }
        check("persist.resaveSameDocument", resaved && resavedDoc?.timeline == rich && resavedDoc?.document.version == 8 && resavedDoc?.document.projectID == richDoc?.document.projectID
              && resavedDoc?.document.spectra == richDoc?.document.spectra && !s.isDirty, "bytesIdentical \(resavedBytes == richBytes)")
        // 같은 위치·같은 내용의 다시 저장은 바이트도 같다(이 Mac에서 북마크가 같게 다시 만들어짐 — 3회 실행에서 같음을 본 뒤 검사로 둠)
        check("persist.resaveIdenticalBytes", resavedBytes != nil && resavedBytes == richBytes, "\(resavedBytes?.count ?? -1) vs \(richBytes?.count ?? -1) bytes")
        // 9c. 저장 → 다른 프로젝트로 바꿈 → 다시 열기, 두 번
        var cycle: [String] = []
        for i in 1...2 {
            let next = out.appendingPathComponent("rich-\(i).ontheframe")
            let w1 = s.writeProject(to: next)
            s.resetProject()
            let o = await s.openProject(at: next); await dismiss()
            cycle.append("\(i):\(w1 && o && s.timeline == rich && !s.isDirty && s.projectURL == next.standardizedFileURL)")
        }
        check("persist.repeatedSaveReopen", cycle == ["1:true", "2:true"], cycle.joined(separator: " "))
        // 9d. 실패한 저장은 대상 파일·저장하지 않은 상태 그대로(안전 저장 계약)
        let pR2 = out.appendingPathComponent("rich-2.ontheframe")
        let h2 = try? Data(contentsOf: pR2)
        s.renameLane(itemLane, to: "바꾼 이름")
        s.saveFailureForTest = true
        let failed = s.writeProject(to: pR2)
        let failMsg = s.alert?.message ?? ""; await dismiss()
        check("persist.failedSaveKeepsFile", !failed && (try? Data(contentsOf: pR2)) == h2 && s.isDirty && failMsg.contains("그대로"), failMsg)
        s.undo()
        // 9e. 내보내기는 계속 거부: 이미 있는 대상 파일을 바꾸지 않음
        let destR = out.appendingPathComponent("rich.mp4"), keep = Data("keep".utf8)
        try? keep.write(to: destR)
        s.startExport(.fromSavePanel(destR))
        _ = await LaneSelfTest.waitUntil(60) { s.exportPhase == .idle && s.alerts.isShowing }
        let exR = s.alert?.title == "내보내기 실패" && (s.alert?.message ?? "").contains("스펙트럼")
        await dismiss()
        check("export.refusedKeepsExisting", exR && (try? Data(contentsOf: destR)) == keep && s.timeline == rich)
        // 9f. 이전 형식 5/6/7: 열고 다시 저장해도 형식이 올라가지 않음(스펙트럼·계보 없음)
        var legacy: [String] = [], legacyTimeline: Timeline?
        for (v, build) in [(5, Self.plainTimeline), (6, Self.subtitleTimeline), (7, Self.effectTimeline)] as [(Int, (Timeline, UUID) throws -> Timeline)] {
            let p = out.appendingPathComponent("legacy-v\(v).ontheframe")
            guard let lt = await makeProject(s, file: p, media: ta, build: build) else { legacy.append("\(v):setup"); continue }
            let v0 = (try? Data(contentsOf: p)).flatMap { try? ProjectFile.decode($0).document.version }
            s.resetProject()
            let o = await s.openProject(at: p); await dismiss()
            let same = o && s.timeline == lt && !s.isDirty
            let p2 = out.appendingPathComponent("legacy-v\(v)-resaved.ontheframe")
            let v1 = s.writeProject(to: p2) ? (try? Data(contentsOf: p2)).flatMap { try? ProjectFile.decode($0).document.version } : nil
            legacy.append("\(v):\(v0 == v && same && v1 == v)")
            legacyTimeline = s.timeline
        }
        check("compat.legacy567", legacy == ["5:true", "6:true", "7:true"], legacy.joined(separator: " "))
        // 9g. 잘못된·지원하지 않는 파일: 형식 7로 적은 스펙트럼 값, 형식 9, 스펙트럼이 영상 레인에, 잘못된 모양 → 열지 않음, 현재 프로젝트·파일 그대로
        var bad: [String] = []
        for (name, edit) in [("v7", { (o: inout [String: Any]) in o["version"] = 7 }),
                             ("v9", { (o: inout [String: Any]) in o["version"] = 9 }),
                             ("laneKind", { (o: inout [String: Any]) in
                                 var sp = o["spectra"] as? [[String: Any]] ?? []; if !sp.isEmpty { sp[0]["lane"] = Lane.videoID.uuidString }; o["spectra"] = sp }),
                             ("style", { (o: inout [String: Any]) in
                                 var sp = o["spectra"] as? [[String: Any]] ?? []
                                 if !sp.isEmpty, var st = sp[0]["style"] as? [String: Any] { st["bands"] = 0; sp[0]["style"] = st }; o["spectra"] = sp })]
                as [(String, (inout [String: Any]) -> Void)] {
            let p = out.appendingPathComponent("bad-\(name).ontheframe")
            guard var o = richBytes.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { bad.append("\(name):setup"); continue }
            edit(&o)
            try? JSONSerialization.data(withJSONObject: o).write(to: p)
            let b0 = try? Data(contentsOf: p), cur = s.timeline, curURL = s.projectURL
            let ok = await s.openProject(at: p)
            let msg = s.alert?.message ?? ""; await dismiss()
            let expect = name == "v9" ? "더 새로운 버전" : "올바르지 않"
            bad.append("\(name):\(!ok && msg.contains(expect) && s.timeline == cur && s.projectURL == curURL && (try? Data(contentsOf: p)) == b0)")
        }
        check("compat.rejectsInvalid", bad == ["v7:true", "v9:true", "laneKind:true", "style:true"], bad.joined(separator: " "))
        // 9h. 스펙트럼 프로젝트 열기를 원본 확인 중에 취소: 현재 프로젝트 그대로, 늦은 결과 없음. 그 뒤 다른 열기는 정상(늦은 완료가 덮지 않음)
        let cur = s.timeline, curURL = s.projectURL
        s.probeDelayForTest = 1_500_000_000
        let openTask = Task { await s.openProject(at: pR2) }
        _ = await LaneSelfTest.waitUntil(5) { s.openProgress != nil }
        s.cancelOpen()
        let cancelledResult = await openTask.value
        s.probeDelayForTest = 0
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let keptAfterCancel = !cancelledResult && s.timeline == cur && s.projectURL == curURL && legacyTimeline == cur
        let reopenAfter = await s.openProject(at: pR); await dismiss()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        check("session.cancelAndLaterOpen", keptAfterCancel && reopenAfter && s.timeline == rich && s.projectURL == pR.standardizedFileURL,
              "cancelled \(!cancelledResult) kept \(keptAfterCancel) reopened \(reopenAfter)")
        // 9i. 상태 F: 소스는 정상인데 원본 파일이 없음 — 열리고 소스 키·상태 그대로, missingMedia에 따로, 내보내기 막힘
        let copyURL = folder.appendingPathComponent("sources/otf-TA-copy.mp4")
        try? fm.removeItem(at: copyURL); try? fm.copyItem(at: ta, to: copyURL)
        let pM = out.appendingPathComponent("missing-media.ontheframe")
        let mt = await makeProject(s, file: pM, media: copyURL, build: Self.missingMediaTimeline)
        try? fm.removeItem(at: copyURL)
        s.resetProject()
        let oM = await s.openProject(at: pM)
        let mAlert = s.alert?.title; await dismiss()
        let tM = s.timeline, mid = tM.spectra.first.flatMap { tM.spectrumMediaID($0) }
        check("open.missingMediaKeepsSource", mt != nil && oM && mAlert == "찾을 수 없는 원본 미디어가 있습니다" && tM == mt && tM.spectra.first.map { tM.spectrumSourceState($0) } == .ok
              && mid.map { s.missingMedia[$0] != nil } == true && !s.canExport && !s.isDirty, "alert '\(mAlert ?? "")' missing \(s.missingMedia.count)")

        // 10. 2B-2(2026-10-26): 소리 클립 문맥 메뉴로 만들기(Debug), 누르면 고르기, Delete 삭제·실행 취소, 명령 보호, 저장·다시 열기, 내보내기
        //     fixture: V1·A1에 쌍 둘(첫 쌍을 60에서 잘라 소리 조각 둘이 같은 계보), 둘째 쌍을 0에 붙여 넣은 복사본(V2·A2, 독립 계보)
        let p10 = out.appendingPathComponent("create.ontheframe")
        guard let base10 = await makeProject(s, file: p10, media: ta, build: Self.createBaseTimeline) else {
            return finish(folder, checks + [Check(name: "create.setup", pass: false, detail: s.statusMessage ?? "")])
        }
        await LaneSelfTest.settle()
        func audio(_ t: Timeline, _ lane: UUID) -> [Clip] { t.audioClips.filter { $0.lane == lane }.sorted { $0.start < $1.start } }
        let a2 = base10.lanes(.audio).first { $0.id != Lane.audioID }?.id ?? Lane.audioID
        let a1c = audio(base10, Lane.audioID), cpc = audio(base10, a2)
        guard a1c.count == 3, cpc.count == 1 else { return finish(folder, checks + [Check(name: "create.fixture", pass: false, detail: "A1 \(a1c.count) A2 \(cpc.count)")]) }
        let f1 = a1c[0], f2 = a1c[1], g2 = a1c[2], cp = cpc[0]
        check("create.fixture", f1.lineageKey == f2.lineageKey && Set([f1.lineageKey, g2.lineageKey, cp.lineageKey]).count == 3 && base10.spectra.isEmpty
              && base10.lanes(.spectrum).isEmpty && a2 != Lane.audioID, "A1 \(a1c.map { "\($0.start)-\($0.end)" }) A2 \(cpc.map { "\($0.start)-\($0.end)" })")
        func center(_ c: Clip) -> NSPoint { viewPoint(c.lane ?? Lane.audioID, frame: c.start + c.length / 2) }
        /// 실제 문맥 메뉴(보기의 menu(for:) — 오른쪽 누름과 같은 경로)와 그 안의 "스펙트럼 추가"
        func contextMenu(at p: NSPoint) -> (NSMenu, NSMenuItem?)? {
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: win(p), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1), let m = tv.menu(for: e) else { return nil }
            return (m, m.items.first { $0.title == "스펙트럼 추가" })
        }
        func perform(_ m: NSMenu, _ it: NSMenuItem) async { m.performActionForItem(at: m.index(of: it)); await LaneSelfTest.settle() }
        // 10a. 누른 조각(f2)으로 만들기: 메뉴를 연 뒤 다른 클립을 골라도 누른 클립을 쓴다. 구간 = 누른 조각(계보 전체 범위 아님), 소스 = 그 계보, 새 레인과 한 단계
        let d10 = s.history.undoDepth
        let menuF2 = contextMenu(at: center(f2))
        s.select(g2.id)
        if let mt = menuF2, let it = mt.1 { await perform(mt.0, it) }
        let tA = s.timeline, made = tA.spectra.first
        check("create.targetIdentity", menuF2?.1 != nil && tA.spectra.count == 1 && made?.start == f2.start && made?.length == f2.length && made?.sourceKey == f2.lineageKey
              && tA.spectrumSource(key: f2.lineageKey)?.range != made.map { $0.start..<$0.end } && tA.lanes(.spectrum).count == 1 && s.history.undoDepth == d10 + 1
              && s.selection == made?.id && tA.clips == base10.clips && tA.audioClips == base10.audioClips,
              "item \(made.map { "\($0.start)-\($0.end)" } ?? "none") lineageRange \(tA.spectrumSource(key: f2.lineageKey)?.range.description ?? "-")")
        // 영상 클립·스펙트럼 항목에는 "스펙트럼 추가"가 없음
        let vMenu = contextMenu(at: viewPoint(Lane.videoID, frame: 30))
        let spPoint = made.map { viewPoint($0.lane, frame: $0.start + 5) } ?? .zero
        check("create.onlyAudioTargets", vMenu != nil && vMenu?.1 == nil && contextMenu(at: spPoint) == nil)
        // 10b. 만들기 실행 취소 → 레인까지 없어짐, 다시 실행 → 같은 ID로 되살아나고 고름
        s.undo(); let undone10 = s.timeline == base10 && s.selection == nil
        s.redo(); let redone10 = s.timeline == tA && s.selection == made?.id
        check("create.undoRedo", undone10 && redone10, "undo \(undone10) redo \(redone10)")
        // 10c. 같은 계보의 다른 조각(f1): 겹치지 않는 기존 스펙트럼 레인을 다시 씀
        if let mt = contextMenu(at: center(f1)), let it = mt.1 { await perform(mt.0, it) }
        let tB = s.timeline, sp1 = made?.lane ?? UUID(), madeF1 = tB.spectra.first { $0.start == f1.start }
        check("create.reuseLane", tB.spectra.count == 2 && tB.lanes(.spectrum).count == 1 && madeF1?.lane == sp1 && madeF1?.sourceKey == f1.lineageKey && madeF1?.length == f1.length)
        // 10d. 복사본(A2, 독립 계보, 0–120): SP1과 겹쳐 새 스펙트럼 레인, 소스는 복사본의 계보
        if let mt = contextMenu(at: center(cp)), let it = mt.1 { await perform(mt.0, it) }
        let tC = s.timeline, madeCp = tC.spectra.first { $0.sourceKey == cp.lineageKey }
        check("create.copiedIndependentNewLane", tC.spectra.count == 3 && tC.lanes(.spectrum).count == 2 && madeCp != nil && madeCp?.lane != sp1
              && madeCp?.start == cp.start && madeCp?.length == cp.length && madeCp?.sourceKey != f1.lineageKey, "lanes \(tC.lanes(.spectrum).count)")
        // 10e. 다른 오디오 레인의 클립(g2, A1 120–240): 경계에서 가까운 SP1에 들어감
        if let mt = contextMenu(at: center(g2)), let it = mt.1 { await perform(mt.0, it) }
        let tD = s.timeline, madeG2 = tD.spectra.first { $0.sourceKey == g2.lineageKey }
        check("create.boundaryLaneFirst", tD.spectra.count == 4 && tD.lanes(.spectrum).count == 2 && madeG2?.lane == sp1 && madeG2?.start == g2.start)
        // 10f. 늦은 메뉴: 끌기 중·클립을 지운 뒤·프로젝트를 바꾼 뒤에는 아무것도 하지 않음(현재 프로젝트 그대로)
        let staleMenu = contextMenu(at: center(g2))
        s.beginGesture(select: f1.id)
        let duringDrag = contextMenu(at: center(f1)) == nil
        if let mt = staleMenu, let it = mt.1 { await perform(mt.0, it) }
        let noneDuringDrag = s.gestureBase != nil && s.timeline == tD   // 끌기 중 메뉴 동작은 아무것도 넣지 않음
        s.cancelGesture(); await LaneSelfTest.settle()
        let afterDrag = s.timeline == tD
        let delMenu = contextMenu(at: center(g2))
        s.commit({ try $0.lifting(clip: g2.id) }, focus: nil)
        let tDel = s.timeline
        if let mt = delMenu, let it = mt.1 { await perform(mt.0, it) }
        let afterDeleted = s.timeline == tDel
        s.undo()
        let p10b = out.appendingPathComponent("create-4.ontheframe")
        let saved4 = s.writeProject(to: p10b)
        let projMenu = contextMenu(at: center(f1))
        let reopened4 = await s.openProject(at: p10b); await dismiss()
        let r4 = s.timeline
        if let mt = projMenu, let it = mt.1 { await perform(mt.0, it) }
        check("create.staleTargets", duringDrag && noneDuringDrag && afterDrag && afterDeleted && saved4 && reopened4 && s.timeline == r4 && r4 == tD
              && (s.statusMessage ?? "").contains("추가하지 않았습니다"), "drag \(duringDrag)/\(afterDrag) deleted \(afterDeleted) project \(s.timeline == r4)")
        // 실패한 만들기(영상 클립 ID)는 타임라인 그대로
        s.addSpectrum(fromAudioClip: base10.clips[0].id, session: s.projectSession)
        check("create.invalidTargetNoChange", s.timeline == tD && s.history.undoDepth == 0)
        // 10g. 저장·다시 열기: 만든 스펙트럼의 ID·소스 키·구간·모양·레인 그대로(위 r4 — 형식 8)
        let v4 = (try? Data(contentsOf: p10b)).flatMap { try? ProjectFile.decode($0).document.version }
        check("create.persisted", v4 == 8 && r4.spectra.map(\.id) == tD.spectra.map(\.id) && r4.spectra.map(\.sourceKey) == tD.spectra.map(\.sourceKey)
              && r4.spectra.map(\.style) == tD.spectra.map(\.style) && r4.spectra.map(\.lane) == tD.spectra.map(\.lane) && r4.audioClips == tD.audioClips && r4.clips == tD.clips)
        // 10h. 고르기: 누름 판정 경계(이어 붙은 두 항목의 경계는 오른쪽), 빈 곳·끝 밖은 없음, 고른 그림, 바꿔 고르기, ⌘-클릭은 보통 고르기, 끌기·자르기 도구는 바꾸지 않음
        await LaneSelfTest.settle()
        guard let i0 = r4.spectra.first(where: { $0.lane == sp1 && $0.start == 0 }), let i60 = r4.spectra.first(where: { $0.lane == sp1 && $0.start == 60 }),
              let i120 = r4.spectra.first(where: { $0.lane == sp1 && $0.start == 120 }), let iCp = r4.spectra.first(where: { $0.lane != sp1 }) else {
            return finish(folder, checks + [Check(name: "select.setup", pass: false, detail: Self.states(r4))])
        }
        let ySp1 = tv.laneRect(sp1)?.midY ?? 0, ySp2 = tv.laneRect(iCp.lane)?.midY ?? 0
        let hits = [tv.spectrumHit(NSPoint(x: tv.x(0) + 1, y: ySp1)) == i0.id, tv.spectrumHit(NSPoint(x: tv.x(60) - 1, y: ySp1)) == i0.id,
                    tv.spectrumHit(NSPoint(x: tv.x(60) + 1, y: ySp1)) == i60.id, tv.spectrumHit(NSPoint(x: tv.x(240) - 1, y: ySp1)) == i120.id,
                    tv.spectrumHit(NSPoint(x: tv.x(240) + 2, y: ySp1)) == nil, tv.spectrumHit(NSPoint(x: tv.x(130), y: ySp2)) == nil,
                    tv.spectrumHit(NSPoint(x: tv.x(30), y: ySp2)) == iCp.id, tv.clipHit(NSPoint(x: tv.x(30), y: ySp1)) == nil,
                    tv.spectrumHit(NSPoint(x: tv.x(30), y: tv.laneRect(Lane.audioID)?.midY ?? 0)) == nil]
        check("select.hitBoundaries", hits.allSatisfy { $0 }, hits.map { $0 ? "1" : "0" }.joined())
        let pI = viewPoint(sp1, frame: 30)
        let pxBefore = pixel(pI)
        await click(pI)
        let pxAfter = pixel(pI)
        check("select.clickAndVisual", s.selection == i0.id && s.selectedIDs == [i0.id] && !near(pxBefore, pxAfter) && s.inspectedLane?.id == sp1 && s.timeline == r4,
              "before \(rgb(pxBefore)) after \(rgb(pxAfter))")
        await LaneSelfTest.mouse(.leftMouseDown, win(viewPoint(sp1, frame: 90)), w, mods: [.command]); await LaneSelfTest.mouse(.leftMouseUp, win(viewPoint(sp1, frame: 90)), w, mods: [.command])
        let cmdClick = s.selection == i60.id && s.linkCandidate == nil
        let pD = viewPoint(sp1, frame: 150)
        await LaneSelfTest.mouse(.leftMouseDown, win(pD), w)
        await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: pD.x + 3, y: pD.y)), w)   // 4 pt 아래(2C-1부터 넘기면 옮김 — 12절)
        await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: pD.x + 3, y: pD.y - 2)), w)
        await LaneSelfTest.mouse(.leftMouseUp, win(NSPoint(x: pD.x + 3, y: pD.y - 2)), w)
        let dragNoEdit = s.selection == i120.id && s.timeline == r4 && s.gestureBase == nil && s.history.undoDepth == 0
        let edgeP = NSPoint(x: tv.x(120) + 2, y: ySp1)   // 항목 시작 가장자리: 2C-1까지는 본문처럼 옮겼고, 2C-2부터 트림 — 시작만 오른쪽으로, 끝 그대로(13절)
        await LaneSelfTest.mouse(.leftMouseDown, win(edgeP), w)
        await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: edgeP.x + 40, y: edgeP.y)), w)
        await LaneSelfTest.mouse(.leftMouseUp, win(NSPoint(x: edgeP.x + 40, y: edgeP.y)), w)
        let movedEdge = s.timeline.spectrum(i120.id)
        let edgeTrims = movedEdge?.end == i120.end && (movedEdge?.start ?? 0) > i120.start && movedEdge?.sourceKey == i120.sourceKey && s.gestureBase == nil && s.history.undoDepth == 1
        s.undo()
        let edgeUndone = s.timeline == r4 && s.history.undoDepth == 0
        s.setTool(.cut); await click(pI); s.setTool(.selection)
        let cutNoEdit = s.timeline == r4 && s.history.undoDepth == 0
        await click(viewPoint(iCp.lane, frame: 200))   // SP2의 빈 곳 → 선택 해제
        let cleared = s.selection == nil
        check("select.replaceSubThresholdEdgeTrimsNoCut", cmdClick && dragNoEdit && edgeTrims && edgeUndone && cutNoEdit && cleared,
              "cmd \(cmdClick) drag \(dragNoEdit) edge \(edgeTrims)/\(edgeUndone) \(movedEdge.map { "\($0.start)+\($0.length)" } ?? "-") cut \(cutNoEdit) cleared \(cleared)")
        // 10i. 명령 보호(이벤트 경로): 스펙트럼을 고른 채 ⌘K·⌘C·⇧Delete는 아무것도 바꾸지 않고 안내, ⌘V는 보통 붙여넣기, ←·→는 재생 헤드만, V·C 도구 그대로
        _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv)
        s.select(base10.clips.first { $0.start == 0 && $0.lane == Lane.videoID }?.id); s.copySelection()
        let cbBefore = s.clipClipboard
        await click(pI)
        await LaneSelfTest.key(40, "k", [.command], w)
        let kOK = s.timeline == r4 && s.statusMessage == ProjectStore.spectrumEditUnsupported
        s.statusMessage = nil
        await LaneSelfTest.key(8, "c", [.command], w)
        let cOK = s.clipClipboard == cbBefore && s.statusMessage == ProjectStore.spectrumEditUnsupported && s.timeline == r4
        await LaneSelfTest.key(51, "\u{7f}", [.shift], w)
        let rippleOK = s.timeline == r4 && (s.statusMessage ?? "").contains("리플")
        s.seek(to: 100)
        await LaneSelfTest.key(124, "\u{F703}", [], w); await LaneSelfTest.key(123, "\u{F702}", [], w); await LaneSelfTest.key(123, "\u{F702}", [], w)
        let arrowsOK = s.playhead == 99 && s.timeline == r4 && s.selection == i0.id
        await LaneSelfTest.key(8, "c", [], w); let toolC = s.tool == .cut
        await LaneSelfTest.key(9, "v", [], w); let toolV = s.tool == .selection
        s.moveLane(sp1, by: -1); let laneMoveKeeps = s.selection == i0.id; s.undo()
        s.select(i0.id)
        s.seek(to: 200)
        await LaneSelfTest.key(9, "v", [.command], w)
        let pasted = s.timeline.clips.count == r4.clips.count + 1 && s.timeline.spectra == r4.spectra && s.selection != i0.id
        s.undo()
        check("route.protectedCommands", kOK && cOK && rippleOK && arrowsOK && toolC && toolV && laneMoveKeeps && pasted && s.timeline == r4,
              "K \(kOK) C \(cOK) ripple \(rippleOK) arrows \(arrowsOK) tools \(toolC)/\(toolV) laneMove \(laneMoveKeeps) paste \(pasted)")
        // 10j. Delete: 고른 스펙트럼만 지움(한 단계), ⌘Z = 같은 ID·값으로 되살아남, ⇧⌘Z = 다시 지움. 다른 스펙트럼·클립·자막 그대로, 레인은 남음
        await click(viewPoint(sp1, frame: 90))
        let dDel = s.history.undoDepth
        await LaneSelfTest.key(51, "\u{7f}", [], w)
        let tAfterDel = s.timeline
        let delOK = (try? r4.liftingSpectrum(i60.id)) == tAfterDel && s.selection == nil && s.history.undoDepth == dDel + 1 && tAfterDel.lanes == r4.lanes
        await LaneSelfTest.key(6, "z", [.command], w)
        let undoOK = s.timeline == r4 && s.timeline.spectrum(i60.id) == i60
        await LaneSelfTest.key(6, "z", [.command, .shift], w)
        let redoOK = s.timeline == tAfterDel
        check("delete.undoRedo", delOK && undoOK && redoOK, "delete \(delOK) undo \(undoOK) redo \(redoOK)")
        // 10k. 삭제 뒤 저장·다시 열기(두 번), 스펙트럼이 남아 있으면 내보내기 거부(이미 있는 대상 그대로), 모두 지우면 스펙트럼 거부가 없어져 내보내기 완료
        let p10c = out.appendingPathComponent("create-3.ontheframe")
        var delCycle: [Bool] = []
        for _ in 0..<2 {
            let wr = s.writeProject(to: p10c); s.resetProject()
            let o = await s.openProject(at: p10c); await dismiss()
            delCycle.append(wr && o && s.timeline == tAfterDel && s.timeline.spectrum(i60.id) == nil && !s.isDirty)
        }
        let dest10 = out.appendingPathComponent("create.mp4"), keep10 = Data("keep".utf8)
        try? keep10.write(to: dest10)
        s.startExport(.fromSavePanel(dest10))
        _ = await LaneSelfTest.waitUntil(60) { s.exportPhase == .idle && s.alerts.isShowing }
        let refused10 = s.alert?.title == "내보내기 실패" && (s.alert?.message ?? "").contains("스펙트럼") && (try? Data(contentsOf: dest10)) == keep10
        await dismiss()
        for sp in s.timeline.spectra { s.select(sp.id); s.deleteSelection() }
        let allGone = s.timeline.spectra.isEmpty && s.timeline.lanes(.spectrum).count == 2 && s.timeline.audioClips == tAfterDel.audioClips && s.timeline.clips == tAfterDel.clips
        let pEmpty = out.appendingPathComponent("create-empty.ontheframe")
        let vEmpty = s.writeProject(to: pEmpty) ? (try? Data(contentsOf: pEmpty)).flatMap { try? ProjectFile.decode($0).document.version } : nil
        let dest10b = out.appendingPathComponent("create-nospectrum.mp4")
        s.startExport(.fromSavePanel(dest10b))
        _ = await LaneSelfTest.waitUntil(120) { s.exportPhase == .idle && s.alerts.isShowing }
        let exported10 = s.alert?.title == "내보내기 완료" && fm.fileExists(atPath: dest10b.path)
        let exportMsg10 = s.alert?.message ?? ""
        await dismiss()
        check("delete.persistAndExportGuard", delCycle == [true, true] && refused10 && allGone && vEmpty == 8 && exported10,
              "cycle \(delCycle) refused \(refused10) allGone \(allGone) version \(vEmpty ?? -1) exported \(exported10) '\(exportMsg10.prefix(80))'")
        // 프로젝트를 바꾸면 고른 스펙트럼이 풀림
        s.undo(); s.select(s.timeline.spectra.first?.id)
        let selectedBefore = s.selectedSpectrum != nil
        s.resetProject()
        check("select.clearedOnProjectReplace", selectedBefore && s.selection == nil && s.selectedSpectrum == nil)

        do {   // 11절 이름 범위(앞 절의 이름과 겹치지 않게)
            // 11. 2B-3(2026-10-26): 클립 조정 패널 소스 목록(값 = 계보 키), 소스 경고(패널·타임라인), 소스 바꾸기·실행 취소, 늦은 값, 저장·다시 열기.
            //     fixture: otf-TA 쌍(60에서 자름 — 조각 2), otf-TB 쌍, TB 쌍의 복사본 둘(V2·A2, V3·A3 — 같은 파일·같은 구간, 독립 계보), WAV 소리 파일,
            //     오디오 레인 이름을 모두 같게, 스펙트럼 레인에 항목 둘(첫 복사본 소스, WAV 소스).
            let wav = folder.appendingPathComponent("sources/aud-wav48s.wav"), tbURL = folder.appendingPathComponent("sources/otf-TB.mp4")
            let p11 = out.appendingPathComponent("sources.ontheframe")
            guard let base11 = await makeProjectMulti(s, file: p11, media: [ta, tbURL, wav], build: Self.sourceTimeline) else {
                return finish(folder, checks + [Check(name: "source.setup", pass: false, detail: s.statusMessage ?? "")])
            }
            EditorLayout.shared.leftTab = .adjust
            await LaneSelfTest.settle()
            let srcs = base11.spectrumSources()
            let opts = s.spectrumSourceOptions()
            let sp11 = base11.spectra.sorted { $0.start < $1.start }
            guard srcs.count == 5, sp11.count == 2, let sA = sp11.first, let sW = sp11.last, let kA = sA.sourceKey, let kW = sW.sourceKey else {
                return finish(folder, checks + [Check(name: "source.fixture", pass: false, detail: "sources \(srcs.count) spectra \(sp11.count)")])
            }
            func mediaName(_ src: SpectrumSource) -> String { base11.media.first { $0.id == src.mediaID }?.name ?? "" }
            let tbSrcs = srcs.filter { mediaName($0) == "otf-TB.mp4" }, taSrc = srcs.first { mediaName($0) == "otf-TA.mp4" }
            let laneNames = base11.lanes(.audio).map(\.name)
            check("source.listing", opts.map(\.key) == srcs.map(\.key) && Set(opts.map(\.label)).count == opts.count && tbSrcs.count == 3
                  && Set(tbSrcs.map(\.range)).count < 3 && Set(laneNames).count == 1 && laneNames.count >= 3
                  && (opts.first { $0.key == taSrc?.key }?.label.hasSuffix("· 조각 2개") ?? false) && kA != kW,
                  opts.map(\.label).joined(separator: " | "))
            check("source.disambiguator", ProjectStore.disambiguated(["a", "b", "a", "a"]) == ["a", "b", "a (2)", "a (3)"])
            // 패널: 실제 팝업(SwiftUI Picker = NSPopUpButton)과 경고(접근성 라벨), 타임라인 경고 표시(화소)
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            func sourcePopup() -> NSPopUpButton? {
                all(w.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.itemTitles.first == "(고르지 않음)" }
            }
            /// 접근성 트리의 글자(PanelSelfTest와 같은 방식 — 새 API 라벨·값과 이전 속성 API의 제목·값·설명). 고를 수 있는 SwiftUI 글은 여기에 보인다.
            func axTexts(_ e: Any, depth: Int = 0) -> [String] {
                guard depth < 60, let o = e as? NSObject else { return [] }
                var out: [String] = [], kids: [Any] = []
                if let p = o as? NSAccessibilityProtocol {
                    if let l = p.accessibilityLabel(), !l.isEmpty { out.append(l) }
                    if let v = p.accessibilityValue() as? String, !v.isEmpty { out.append(v) }
                    kids = p.accessibilityChildren() ?? []
                }
                for a in [NSAccessibility.Attribute.title, .value, .description] {
                    if let v = o.accessibilityAttributeValue(a) as? String, !v.isEmpty { out.append(v) }
                }
                if kids.isEmpty, let c = o.accessibilityAttributeValue(.children) as? [Any] { kids = c }
                for c in kids { out += axTexts(c, depth: depth + 1) }
                return out
            }
            /// 패널에 보이는 스펙트럼 소스 경고 글(경고 문구 넷 중 화면에 있는 것, 중복 없이 문구 차례)
            func panelWarnings() -> [String] {
                let texts = Set(axTexts(w.contentView!))
                let sp = s.selectedSpectrum
                let known = sp.map { s.spectrumWarnings($0).map { s.spectrumWarningText($0) } } ?? []
                // 지금 상태의 경고 글 중 화면에 있는 것 + 지금 상태가 아닌 경고 종류의 글이 화면에 남아 있으면 그 머리말(잘못 보임을 잡음)
                let prefixes = ["소스를 고르지 않았습니다", "소스 오디오가 타임라인에 없습니다", "소스의 원본 파일을 찾을 수 없습니다", "같은 소스의 조각이 같은 시각에 겹칩니다"]
                let shownKnown = known.filter { k in texts.contains { $0.hasPrefix(k) } }
                let stray = prefixes.filter { p in !known.contains { $0.hasPrefix(p) } && texts.contains { $0.hasPrefix(p) } }
                return shownKnown + stray
            }
            func choose(_ title: String) async -> Bool {
                guard let p = sourcePopup(), let i = p.itemArray.firstIndex(where: { $0.title == title }) else { return false }
                p.menu?.performActionForItem(at: i); await LaneSelfTest.settle(); return true
            }
            func indicator(_ sp: SpectrumItem) -> NSColor? {
                let r = TimelineNSView.spectrumWarningRect(tv.spectrumRect(sp))
                return pixel(NSPoint(x: r.midX, y: r.midY))
            }
            func reddish(_ c: NSColor?) -> Bool { c.map { $0.redComponent > 0.7 && $0.greenComponent < 0.45 } ?? false }
            func orangeish(_ c: NSColor?) -> Bool { c.map { $0.redComponent > 0.75 && $0.greenComponent > 0.4 && $0.greenComponent < 0.75 && $0.blueComponent < 0.35 } ?? false }
            let label = { (k: UUID?) in s.spectrumSourceOptions().first { $0.key == k }?.label }
            await click(viewPoint(sA.lane, frame: sA.start + 5))
            _ = await LaneSelfTest.waitUntil(3) { sourcePopup() != nil }
            let pop0 = sourcePopup()
            check("dropdown.initial", s.selection == sA.id && pop0 != nil && pop0?.itemTitles == ["(고르지 않음)"] + opts.map(\.label) && pop0?.titleOfSelectedItem == label(kA)
                  && panelWarnings().isEmpty && !reddish(indicator(sA)) && !orangeish(indicator(sA)) && s.timeline == base11 && s.history.undoDepth == 0,
                  "selected '\(pop0?.titleOfSelectedItem ?? "-")' items \(pop0?.itemTitles.count ?? 0) warnings \(panelWarnings()) ind \(rgb(indicator(sA)))")
            // 바꾸기(같은 파일의 다른 복사본) = 한 단계, 다른 값 그대로 / 같은 값 = 기록 없음 / 실행 취소·다시 실행이 팝업에도
            let kOther = tbSrcs.map(\.key).first { $0 != kA } ?? kA
            let d11 = s.history.undoDepth
            let ch1 = await choose(label(kOther) ?? "")
            let afterCh = s.timeline.spectrum(sA.id)
            let changedOK = ch1 && afterCh?.sourceKey == kOther && afterCh.map { $0.with(sourceKey: .some(kA)) } == sA && s.history.undoDepth == d11 + 1
                && s.timeline.spectrum(sW.id) == sW && s.timeline.audioClips == base11.audioClips && s.timeline.clips == base11.clips
            let same = await choose(label(kOther) ?? "")
            let noop = same && s.history.undoDepth == d11 + 1
            s.undo(); await LaneSelfTest.settle()
            let undoOK = s.timeline.spectrum(sA.id)?.sourceKey == kA && sourcePopup()?.titleOfSelectedItem == label(kA) && s.selection == sA.id
            s.redo(); await LaneSelfTest.settle()
            let redoOK = s.timeline.spectrum(sA.id)?.sourceKey == kOther && sourcePopup()?.titleOfSelectedItem == label(kOther)
            check("dropdown.changeUndoRedo", changedOK && noop && undoOK && redoOK, "change \(changedOK) noop \(noop) undo \(undoOK) redo \(redoOK)")
            // 고르지 않음 = nil(의도), 패널·타임라인 경고(주황)
            let un = await choose("(고르지 않음)")
            let spUn = s.timeline.spectrum(sA.id)   // T-H1: 없으면 실패(강제 풀기 없음 — 없을 때 `?.sourceKey == nil`은 참이라 보호가 되지 않았다)
            let unOK = un && spUn != nil && spUn?.sourceKey == nil && spUn.map { s.spectrumWarnings($0) } == [.unset]
                && panelWarnings() == [s.spectrumWarningText(.unset)] && spUn.map { orangeish(indicator($0)) } == true && sourcePopup()?.titleOfSelectedItem == "(고르지 않음)"
            check("status.unassigned", unOK, "item \(spUn == nil ? "missing" : "ok") warnings \(panelWarnings()) ind \(spUn.map { rgb(indicator($0)) } ?? "-")")
            // 지워진 소스: 그 계보의 클립을 모두 지우면 "(없음 — 지워진 소스)"가 선택된 채 꺼지고 경고, 키는 그대로. 실행 취소로 되살아남.
            _ = await choose(label(kA) ?? "")
            let tBeforeLift = s.timeline
            let liftIDs = tBeforeLift.audioClips.filter { $0.lineageKey == kA }.map(\.id)
            for id in liftIDs { s.commit({ try $0.lifting(clip: id) }, focus: nil) }
            s.select(sA.id)
            await LaneSelfTest.settle()
            let shown = await LaneSelfTest.waitUntil(3) { sourcePopup()?.titleOfSelectedItem == "(없음 — 지워진 소스)" }
            let stateAfterLift = s.timeline.spectrum(sA.id).map { s.timeline.spectrumSourceState($0) }
            let pm = sourcePopup()
            let unavailableItem = pm?.itemArray.first { $0.title == "(없음 — 지워진 소스)" }
            let missingOK = s.timeline.spectrum(sA.id)?.sourceKey == kA && shown && pm?.titleOfSelectedItem == "(없음 — 지워진 소스)" && unavailableItem != nil
                && s.timeline.spectrum(sA.id).map { s.spectrumWarnings($0) } == [.missingSource] && panelWarnings() == [s.spectrumWarningText(.missingSource)]
                && s.timeline.spectrum(sA.id).map { reddish(indicator($0)) } == true && !(pm?.itemTitles.contains(label(kA) ?? "#") ?? true)
            let missingDetail = "sel '\(pm?.titleOfSelectedItem ?? "-")' state \(String(describing: stateAfterLift)) warnings \(panelWarnings()) ind \(s.timeline.spectrum(sA.id).map { rgb(indicator($0)) } ?? "-")"
            // "(없음 — 지워진 소스)"를 다시 고르거나 목록에 없는 키를 넣어도 아무것도 바꾸지 않음
            let tMissing = s.timeline, dM = s.history.undoDepth
            if let pm, let i = pm.itemArray.firstIndex(where: { $0.title == "(없음 — 지워진 소스)" }) { pm.menu?.performActionForItem(at: i); await LaneSelfTest.settle() }
            s.setSpectrumSource(sA.id, key: UUID(), from: kA, project: s.projectSession)
            let invalidOK = s.timeline == tMissing && s.history.undoDepth == dM && s.statusMessage == EditError.spectrumUnknownSource.description
            for _ in liftIDs { s.undo() }
            s.select(sA.id); await LaneSelfTest.settle()
            let restoredOK = s.timeline == tBeforeLift && sourcePopup()?.titleOfSelectedItem == label(kA) && panelWarnings().isEmpty
            check("status.missingSourceUndo", missingOK && invalidOK && restoredOK, "missing \(missingOK) invalid \(invalidOK) restored \(restoredOK) " + missingDetail)
            // 같은 계보의 조각 겹침(TA 계보의 오른쪽 조각을 새 오디오 레인 30으로): 경고(빨강), 겹친 구간·레인. 실행 취소로 사라짐
            let laneX = UUID()
            _ = await choose(label(taSrc?.key) ?? "")
            let taPieces = s.timeline.audioClips.filter { $0.lineageKey == taSrc?.key }.sorted { $0.start < $1.start }
            let tBeforeOv = s.timeline
            if taPieces.count == 2 {
                s.commit({ try $0.addingLane(.audio, name: "겹침", id: laneX).unlinking(clip: taPieces[1].id).relocating(clip: taPieces[1].id, toStart: 30, lane: laneX) }, focus: nil)
            }
            s.select(sA.id); await LaneSelfTest.settle()
            let spOv = s.timeline.spectrum(sA.id)   // T-H1: 없으면 실패(강제 풀기 없음)
            let ov = spOv.map { s.spectrumWarnings($0) } ?? []
            let ovOK: Bool = { if case .overlap(let o)? = ov.first, ov.count == 1, o.first?.range == 30..<60 { return true }; return false }()
            let ovPanel = panelWarnings().count == 1 && (panelWarnings().first ?? "").contains("겹칩니다") && spOv.map { reddish(indicator($0)) } == true
            s.undo(); s.select(sA.id); await LaneSelfTest.settle()
            check("status.overlap", spOv != nil && ovOK && ovPanel && s.timeline == tBeforeOv && panelWarnings().isEmpty, "item \(spOv == nil ? "missing" : "ok") \(ov) panel \(panelWarnings())")
            // 11e. 늦은 값: 그린 뒤 다른 값이 된 경우(from), 다른 스펙트럼을 고른 뒤, 지운 뒤, 끌기 중, 프로젝트를 바꾼 뒤의 옛 팝업 → 아무것도 바꾸지 않음
            let cur = s.timeline, proj = s.projectSession, curKey = s.timeline.spectrum(sA.id)?.sourceKey
            s.setSpectrumSource(sA.id, key: kOther, from: kOther == curKey ? kA : kOther, project: proj)   // 보인 값이 지금 값과 다름
            let staleFrom = s.timeline == cur
            s.select(sW.id)
            s.setSpectrumSource(sA.id, key: kOther, from: curKey, project: proj)                         // 고른 것이 아님
            let notSelected = s.timeline == cur
            s.select(sA.id)
            s.beginGesture(select: base11.clips[0].id)
            s.setSpectrumSource(sA.id, key: kOther, from: curKey, project: proj)
            let duringGesture = s.timeline.spectrum(sA.id)?.sourceKey == curKey
            s.cancelGesture(); await LaneSelfTest.settle()
            let oldPopup = sourcePopup(), oldIndex = oldPopup?.itemArray.firstIndex { $0.title == label(kOther) }
            let saved11 = s.writeProject(to: p11)
            let reopened11 = await s.openProject(at: p11); await dismiss()
            let r11 = s.timeline
            // 옛 팝업(옛 회차의 값을 들고 있음)을 새 프로젝트에서 누름 → 넣지 않음. 새 회차에서 같은 ID를 골라도 옛 회차 값은 넣지 않음
            if let oldPopup, let oldIndex, oldPopup.numberOfItems > oldIndex { oldPopup.menu?.performActionForItem(at: oldIndex) }
            await LaneSelfTest.settle()
            s.select(sA.id)
            let kNew = r11.spectrumSources().map(\.key).first { $0 != r11.spectrum(sA.id)?.sourceKey && $0 != kOther } ?? kW   // 지금 값과 다른 소스
            s.setSpectrumSource(sA.id, key: kNew, from: r11.spectrum(sA.id)?.sourceKey, project: proj)   // 옛 회차 — 보인 값·고른 것은 맞음
            await LaneSelfTest.settle()
            let oldProject = s.timeline == r11 && s.history.undoDepth == 0 && kNew != r11.spectrum(sA.id)?.sourceKey
            s.commit({ try $0.liftingSpectrum(sA.id) }, focus: nil)
            s.setSpectrumSource(sA.id, key: kOther, from: curKey, project: s.projectSession)
            let afterDelete = s.timeline.spectrum(sA.id) == nil && s.history.undoDepth == 1
            s.undo()
            check("safety.staleValues", staleFrom && notSelected && duringGesture && saved11 && reopened11 && oldProject && afterDelete && r11 == cur,
                  "from \(staleFrom) sel \(notSelected) gesture \(duringGesture) project \(oldProject) deleted \(afterDelete)")
            // 11f. 저장·다시 열기: 바꾼 소스·고르지 않음·지워진 소스가 그대로(ID·구간·모양·계보 같음), 팝업도 같은 항목
            s.select(sA.id); await LaneSelfTest.settle()
            _ = await choose(label(kOther) ?? "")
            s.select(sW.id); await LaneSelfTest.settle()
            _ = await choose("(고르지 않음)")
            let tP = s.timeline
            let pP = out.appendingPathComponent("sources-2.ontheframe")
            let wP = s.writeProject(to: pP); s.resetProject()
            let oP = await s.openProject(at: pP); await dismiss()
            s.select(sA.id); await LaneSelfTest.settle()
            let popA = sourcePopup()?.titleOfSelectedItem
            s.select(sW.id); await LaneSelfTest.settle()
            let popW = sourcePopup()?.titleOfSelectedItem
            let vP = (try? Data(contentsOf: pP)).flatMap { try? ProjectFile.decode($0).document.version }
            check("persist.sourceAssignment", wP && oP && vP == 8 && s.timeline == tP && s.timeline.spectrum(sA.id)?.sourceKey == kOther && s.timeline.spectrum(sW.id)?.sourceKey == nil
                  && popA == label(kOther) && popW == "(고르지 않음)" && s.timeline.audioClips.map(\.lineageKey) == tP.audioClips.map(\.lineageKey),
                  "popA '\(popA ?? "-")' popW '\(popW ?? "-")'")
            // 11g. 원본 파일 없음(2B-1 missing-media.ontheframe): 소스는 정상·키 그대로, 패널 경고는 "원본 파일" — 지워진 소스와 다름, 타임라인 빨강
            s.resetProject()
            _ = await s.openProject(at: pM); await dismiss()
            let spM = s.timeline.spectra.first
            if let spM { s.select(spM.id) }
            await LaneSelfTest.settle()
            let mw = spM.map { s.spectrumWarnings($0) } ?? []
            let mediaOK: Bool = { if case .missingMedia? = mw.first, mw.count == 1 { return true }; return false }()
            check("status.missingMediaDistinct", spM.map { s.timeline.spectrumSourceState($0) } == .ok && mediaOK && panelWarnings().count == 1 && (panelWarnings().first ?? "").contains("원본 파일")
                  && !(panelWarnings().first ?? "").contains("타임라인에 없습니다") && spM.map { reddish(indicator($0)) } == true && sourcePopup()?.titleOfSelectedItem == label(spM?.sourceKey)
                  && s.timeline == mt, "warnings \(mw) panel \(panelWarnings())")
        }
        do {   // 12절 이름 범위
            // 12. 2C-1(2026-10-26): 스펙트럼 끌어 옮기기 — 기존 누름 대기(4 pt)·끌기(beginGesture → updateFreeMove → commitGesture/cancelGesture) 그대로.
            //     fixture(moveTimeline): V1·A1 TA 쌍 0–120(60에서 자름 — 계보 하나), 자막 150–170, 스펙트럼 레인 둘: L1에 m1 [10,40)(소스 = 그 계보, 아날로그·위쪽),
            //     m2 [100,130)(고르지 않음), L2에 m3 [0,20)(소스 = 그 계보). 실제 보기에 합성 마우스·키 이벤트.
            EditorLayout.shared.leftTab = .media
            let p12 = out.appendingPathComponent("move.ontheframe")
            guard let b12 = await makeProject(s, file: p12, media: ta, build: Self.moveTimeline) else {
                return finish(folder, checks + [Check(name: "move.setup", pass: false, detail: s.statusMessage ?? "")])
            }
            _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv)
            await LaneSelfTest.settle()
            guard let m1 = b12.spectra.first(where: { $0.start == 10 }), let m2 = b12.spectra.first(where: { $0.start == 100 }),
                  let m3 = b12.spectra.first(where: { $0.lane != m1.lane }), m2.lane == m1.lane else {
                return finish(folder, checks + [Check(name: "move.fixture", pass: false, detail: Self.states(b12))])
            }
            let L1 = m1.lane, L2 = m3.lane, ppf = tv.pixelsPerFrame
            /// 내용 비교: 스펙트럼이 아닌 것(영상·소리·자막·레인·미디어)이 base와 같은가
            func othersSame(_ t: Timeline, _ b: Timeline) -> Bool { t.clips == b.clips && t.audioClips == b.audioClips && t.subtitles == b.subtitles && t.lanes == b.lanes && t.media == b.media }
            /// 항목 m을 (프레임 f, 레인 l)에서 잡아 (프레임 f2, 레인 l2)까지 끈다 — 단계 나눠 여러 끌기 이벤트, up이면 놓는다
            func drag(_ f: Int, _ l: UUID, to f2: Int, _ l2: UUID? = nil, steps: Int = 3, up: Bool = true, toY: CGFloat? = nil) async {
                let p0 = viewPoint(l, frame: f), p1 = NSPoint(x: tv.x(f2), y: toY ?? viewPoint(l2 ?? l, frame: f2).y)
                await LaneSelfTest.mouse(.leftMouseDown, win(p0), w)
                for i in 1...steps {
                    let k = CGFloat(i) / CGFloat(steps)
                    await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: p0.x + (p1.x - p0.x) * k, y: p0.y + (p1.y - p0.y) * k)), w)
                }
                if up { await LaneSelfTest.mouse(.leftMouseUp, win(p1), w) }
                await LaneSelfTest.settle()
            }
            func up(_ f: Int, _ l: UUID) async { await LaneSelfTest.mouse(.leftMouseUp, win(viewPoint(l, frame: f)), w); await LaneSelfTest.settle() }
            func item(_ id: UUID) -> SpectrumItem? { s.timeline.spectrum(id) }

            // 12a. 누름만: 고르기, 바뀌지 않음, 기록 없음
            let d0 = s.history.undoDepth
            await click(viewPoint(L1, frame: 25))
            check("move.clickSelectsNoEdit", s.selection == m1.id && s.timeline == b12 && s.history.undoDepth == d0 && s.gestureBase == nil)
            // 12b. 같은 레인 옮기기(여러 끌기 이벤트 → 한 단계): 시작만, ID·소스·모양·길이·다른 내용 그대로, 고른 채
            await drag(25, L1, to: 175, steps: 4)
            let a = item(m1.id), tA = s.timeline
            check("move.sameLane", a?.start == 160 && a?.lane == L1 && a?.length == m1.length && a?.sourceKey == m1.sourceKey && a?.style == m1.style
                  && othersSame(tA, b12) && tA.spectrum(m2.id) == m2 && tA.spectrum(m3.id) == m3 && s.history.undoDepth == d0 + 1 && s.selection == m1.id
                  && s.gestureBase == nil && s.isDirty, "item \(a.map { "\($0.start)@\($0.lane == L1 ? "L1" : "?")" } ?? "-") depth \(s.history.undoDepth - d0) ppf \(ppf)")
            // 12c. 실행 취소 → 처음 자리, 다시 실행 → 옮긴 자리(선택은 그 스펙트럼)
            s.undo(); let undoneA = s.timeline == b12 && s.selection == m1.id
            s.redo(); let redoneA = s.timeline == tA && s.selection == m1.id
            check("move.undoRedo", undoneA && redoneA, "undo \(undoneA) redo \(redoneA)")
            // 12d. 다른 스펙트럼 레인으로(같은 시각) → 레인만 바뀜, 한 단계
            await drag(175, L1, to: 175, L2)
            let tB = s.timeline
            check("move.crossLane", item(m1.id)?.lane == L2 && item(m1.id)?.start == 160 && item(m1.id)?.style == m1.style && othersSame(tB, b12)
                  && s.history.undoDepth == d0 + 2, "lane \(item(m1.id)?.lane == L2 ? "L2" : "?") start \(item(m1.id)?.start ?? -1)")
            // 12e. 다른 종류 레인(V1) 위로 끌면: 원래 스펙트럼 레인(끌기 시작 때 L2)에 두고 시각만, 새 레인 없음
            await drag(175, L2, to: 205, Lane.videoID)
            check("move.overNonSpectrumLaneKeepsLane", item(m1.id)?.lane == L2 && item(m1.id)?.start == 190 && s.timeline.lanes == b12.lanes && othersSame(s.timeline, b12),
                  "lane \(item(m1.id)?.lane == L2 ? "L2" : "?") start \(item(m1.id)?.start ?? -1)")
            s.undo(); s.undo(); let backToA = s.timeline == tA
            // 12f. 끝을 넘어 옮기기: 타임라인 길이가 늘어남(m3 L2 0–20 → 200–220). 이전 길이 190 = 12b에서 m1을 160–190으로 옮겨 늘어난 길이
            //      (실행 취소는 그 단계의 타임라인을 길이째 되살린다 — fixture 처음 길이 170이 아님)
            let dur0 = s.timeline.durationFrames
            await drag(10, L2, to: 210)
            check("move.pastEndExtends", backToA && dur0 == 190 && b12.durationFrames == 170 && item(m3.id)?.start == 200 && s.timeline.durationFrames == 220 && othersSame(s.timeline, b12),
                  "back \(backToA) dur \(dur0) → \(s.timeline.durationFrames) start \(item(m3.id)?.start ?? -1)")
            s.undo()
            // 12g. 0 앞으로: m1(L1 160–190)을 시작이 −15가 될 만큼 끌면 0에서 멈춤(음수 시작 없음)
            await drag(175, L1, to: 0)
            check("move.clampsAtZero", item(m1.id)?.start == 0 && item(m1.id)?.length == m1.length && s.history.undoDepth == d0 + 2, "start \(item(m1.id)?.start ?? -1)")
            s.undo()
            let tC = s.timeline
            // 12h. 겹침: 끄는 동안 제안이 거부(빨간 상자, 타임라인 그대로), 놓으면 바뀌지 않음·기록 없음·안내, 겹친 항목 그대로
            let redAt = viewPoint(L1, frame: 135), pxNo = pixel(redAt), dC = s.history.undoDepth   // 제안 상자 안·m2 밖(붙을 곳에서 10프레임 떨어진 자리)
            await drag(170, L1, to: 120, up: false)   // m1 160–190 → 110–140, m2 100–130과 겹침
            let duringOK = s.freeMoveProposal?.ok == false && s.gestureBase != nil && s.timeline == tC
            tv.display()
            let pxRed = pixel(redAt)
            let redder = { (c: NSColor?) in c.map { $0.redComponent - $0.greenComponent } ?? 0 }
            await up(120, L1)
            check("move.overlapRejected", duringOK && redder(pxRed) > redder(pxNo) + 0.08 && s.timeline == tC && s.history.undoDepth == dC && s.gestureBase == nil
                  && s.statusMessage == ProjectStore.spectrumMoveOverlap && s.timeline.spectrum(m2.id) == m2,
                  "during \(duringOK) px \(rgb(pxNo)) → \(rgb(pxRed)) status '\(s.statusMessage ?? "")'")
            // 12i. 붙음: 끝 59 → 60(잘린 소리 조각 경계, 스펙트럼 전용 대상), 안내선. Esc로 취소
            let thrF = Double(TimelineNSView.snapDistance / ppf)
            await drag(175, L1, to: 44, up: false)   // m1 160–190 → 29–59, 끝이 60(소리 조각 경계)에 붙어 30–60
            let snapped = item(m1.id)?.start == 30 && s.snapGuide == 60
            await LaneSelfTest.key(53, "\u{1b}", [], w); await LaneSelfTest.settle()
            await up(59, L1)
            check("move.snapToSourceBoundary", snapped && s.timeline == tC && s.gestureBase == nil && s.snapGuide == nil && s.history.undoDepth == dC,
                  "start \(item(m1.id)?.start ?? -1) guide \(String(describing: s.snapGuide)) threshold \(thrF)")
            // 12j. Esc: 옮긴 상태에서 취소 → 처음 그대로, 기록 없음. 그 뒤 늦은 끌기·놓기는 아무것도 하지 않음
            await drag(175, L1, to: 230, up: false)
            let movedBeforeEsc = item(m1.id)?.start == 215
            await LaneSelfTest.key(53, "\u{1b}", [], w); await LaneSelfTest.settle()
            let afterEsc = s.timeline == tC && s.gestureBase == nil
            await LaneSelfTest.mouse(.leftMouseDragged, win(viewPoint(L1, frame: 250)), w); await up(250, L1)
            check("cancel.escape", movedBeforeEsc && afterEsc && s.timeline == tC && s.history.undoDepth == dC, "moved \(movedBeforeEsc) esc \(afterEsc)")
            // 12k. 초점 잃음(편집기 창 키 상태 잃음 — ⌘Tab과 같은 길): 취소, 늦은 놓기는 확정하지 않음
            await drag(175, L1, to: 230, up: false)
            let movedBeforeResign = item(m1.id)?.start == 215
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w); await LaneSelfTest.settle()
            let afterResign = s.timeline == tC && s.gestureBase == nil
            await up(230, L1)
            _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv)
            check("cancel.focusLoss", movedBeforeResign && afterResign && s.timeline == tC && s.history.undoDepth == dC, "moved \(movedBeforeResign) resign \(afterResign)")
            // 12l. 알림 시트(모달): 끄는 중 알림이 뜨면 끌기가 취소되고, 놓기·닫기 뒤에도 바뀌지 않음
            await drag(175, L1, to: 230, up: false)
            let movedBeforeAlert = item(m1.id)?.start == 215
            s.presentAlert(ProjectStore.AlertInfo(title: "검사 알림", message: "스펙트럼 옮기기 중 알림"))
            let sheet = await LaneSelfTest.waitUntil(3) { s.alerts.isShowing && w.attachedSheet != nil }
            await LaneSelfTest.settle()
            let afterAlert = s.timeline == tC && s.gestureBase == nil
            await up(230, L1)
            await dismiss()
            _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv)
            check("cancel.modalAlert", movedBeforeAlert && sheet && afterAlert && s.timeline == tC && s.history.undoDepth == dC,
                  "moved \(movedBeforeAlert) sheet \(sheet) cancelled \(afterAlert) gesture \(s.gestureBase != nil)")
            // 12m. 도구: 끄는 중 자르기 도구로 바꾸기는 거부(끌기 그대로 확정). 누름 대기 뒤 도구를 바꾸면 이어진 끌기는 옮기지 않음
            await drag(175, L1, to: 230, up: false)
            let toolRefused = !s.setTool(.cut) && s.tool == .selection
            await up(230, L1)
            let committedWithTool = item(m1.id)?.start == 215 && s.history.undoDepth == dC + 1
            s.undo()
            await LaneSelfTest.mouse(.leftMouseDown, win(viewPoint(L1, frame: 175)), w)
            let switched = s.setTool(.cut)
            await LaneSelfTest.mouse(.leftMouseDragged, win(viewPoint(L1, frame: 230)), w); await up(230, L1)
            s.setTool(.selection)
            check("cancel.toolSwitch", toolRefused && committedWithTool && switched && s.timeline == tC && s.history.undoDepth == dC && s.gestureBase == nil,
                  "refused \(toolRefused) committed \(committedWithTool) switched \(switched)")
            // 12n. 끄는 중 새 누름(놓기를 받지 못한 끌기): 취소하고 섞어 확정하지 않음. 두 번 놓기·늦은 끌기도 한 번만
            await drag(175, L1, to: 230, up: false)
            await LaneSelfTest.mouse(.leftMouseDown, win(viewPoint(L2, frame: 300)), w)   // 빈 곳 새 누름
            let afterNewPress = s.timeline == tC && s.gestureBase == nil
            await up(300, L2)
            await drag(175, L1, to: 230)
            let once = s.history.undoDepth
            await up(230, L1); await LaneSelfTest.mouse(.leftMouseDragged, win(viewPoint(L1, frame: 260)), w); await up(260, L1)
            check("cancel.newPressAndDuplicateUp", afterNewPress && once == dC + 1 && s.history.undoDepth == once && item(m1.id)?.start == 215,
                  "newPress \(afterNewPress) depth \(once - dC)/\(s.history.undoDepth - dC) start \(item(m1.id)?.start ?? -1)")
            s.undo()
            // 12o. 제자리로 돌아온 끌기: 기록 없음, 저장 상태 그대로
            let dirtyBefore = s.isDirty
            await LaneSelfTest.mouse(.leftMouseDown, win(viewPoint(L1, frame: 175)), w)
            await LaneSelfTest.mouse(.leftMouseDragged, win(viewPoint(L1, frame: 215)), w)
            await LaneSelfTest.mouse(.leftMouseDragged, win(viewPoint(L1, frame: 175)), w); await up(175, L1)
            check("move.noOpNoHistory", s.timeline == tC && s.history.undoDepth == dC && s.isDirty == dirtyBefore)
            // 12p. 끄는 중 프로젝트 교체: 끌기 취소, 새 프로젝트를 바꾸지 않고 옛 선택 없음
            await drag(175, L1, to: 230, up: false)
            s.resetProject(); await LaneSelfTest.settle()
            let fresh = s.timeline
            await LaneSelfTest.mouse(.leftMouseDragged, win(viewPoint(L1, frame: 260)), w); await up(260, L1)
            check("cancel.projectReplace", s.gestureBase == nil && s.timeline == fresh && fresh.spectra.isEmpty && s.history.undoDepth == 0 && s.selection == nil)
            // 12q. 저장·다시 열기: 옮긴 레인·시각·ID·소스·모양 그대로(형식 8), 실행 취소·다시 실행 뒤 저장
            let o12 = await s.openProject(at: p12); await dismiss()
            _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv); await LaneSelfTest.settle()
            // 연 직후에는 창 키 상태가 늦게 바뀔 수 있다(그 알림은 D-031대로 끌기를 취소함 — 제품 동작): 키 창이 안정된 뒤 끈다. 다시 실패하면 아래 detail로 원인을 가른다.
            let keyStable = await LaneSelfTest.waitUntil(3) { w.isKeyWindow && NSApp.isActive }
            await LaneSelfTest.settle()
            let int0 = s.interruptCountForTest
            await click(viewPoint(L1, frame: 25))
            await drag(25, L1, to: 175, L2)
            let movedQ = s.timeline.spectrum(m1.id)?.start == 160, intQ = s.interruptCountForTest - int0, keyQ = w.isKeyWindow
            s.undo(); s.redo()
            let tS = s.timeline
            let p12b = out.appendingPathComponent("move-2.ontheframe")
            let w12 = s.writeProject(to: p12b); s.resetProject()
            let r12 = await s.openProject(at: p12b); await dismiss()
            let v12 = (try? Data(contentsOf: p12b)).flatMap { try? ProjectFile.decode($0).document.version }
            let rm = s.timeline.spectrum(m1.id)
            check("move.persisted", o12 && w12 && r12 && v12 == 8 && s.timeline == tS && rm?.lane == L2 && rm?.start == 160 && rm?.sourceKey == m1.sourceKey && rm?.style == m1.style
                  && othersSame(s.timeline, b12) && s.timeline.spectrumSourceState(rm ?? m1) == .ok,
                  "lane \(rm?.lane == L2) start \(rm?.start ?? -1) version \(v12 ?? -1) moved \(movedQ) keyStable \(keyStable) key \(keyQ) interrupts \(intQ)")
            // 12r. 옮긴 뒤에도 소스 상태·경고·내보내기 막음 그대로: m1은 소스 범위(0–120) 밖이어도 정상(무음 — 2C 결정 1), 경고 없음,
            //      m2는 고르지 않음 경고, 스펙트럼이 있어 내보내기 막음(엔진 판정 m2 하나 + 계획 거부는 10절)
            // 12s. Debug 끌기 진단 기록(2026-10-26): 대상 종류(스펙트럼·영상 클립·자막), 확정(바뀜 여부)·취소 줄, 줄 끝의 기록 깊이.
            //      스펙트럼 옮기기 → Esc 취소 → 제자리 끌기(바뀜 없음) → 영상 클립 옮기기 → 자막 옮기기(클립·자막은 실행 취소로 되돌림)
            do {
                // 다시 연 직후: 키 창·보기 그리기 상태가 안정된 뒤(12q와 같은 대기 — 스펙트럼 누름 판정은 보기의 그리기 상태를 쓴다)
                _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv)
                _ = await LaneSelfTest.waitUntil(3) { w.isKeyWindow && NSApp.isActive && tv.spectrumHit(viewPoint(L2, frame: 175)) == m1.id }
                await LaneSelfTest.settle()
                let hitReady = tv.spectrumHit(viewPoint(L2, frame: 175)) == m1.id
                s.traceLinesForTest = []
                let dq = s.history.undoDepth
                let stl = s.timeline.lanes(.subtitle).first?.id ?? Lane.videoID
                await drag(175, L2, to: 215)                                                   // m1 L2 160 → 200
                await drag(215, L2, to: 245, up: false); await LaneSelfTest.key(53, "\u{1b}", [], w); await up(245, L2)
                await LaneSelfTest.mouse(.leftMouseDown, win(viewPoint(L2, frame: 215)), w)
                await LaneSelfTest.mouse(.leftMouseDragged, win(viewPoint(L2, frame: 255)), w)
                await LaneSelfTest.mouse(.leftMouseDragged, win(viewPoint(L2, frame: 215)), w); await up(215, L2)
                await drag(30, Lane.videoID, to: 230); s.undo()                              // 영상 클립 0–60 → 200–260
                await drag(160, stl, to: 260); s.undo()                                       // 자막 150–170 → 250–270
                let tl = s.traceLinesForTest
                func depthOf(_ l: String) -> Int { l.components(separatedBy: " depth=").last.flatMap { Int($0) } ?? -1 }
                let targets = tl.compactMap { l in l.hasPrefix("dbg begin kind=timeline target=") ? l.components(separatedBy: "target=").last?.components(separatedBy: " ").first : nil }
                let ends = tl.compactMap { l -> String? in
                    if l.hasPrefix("dbg committed changed=") { return "commit:\(l.contains("changed=true"))@\(depthOf(l) - dq)" }
                    if l.hasPrefix("dbg cancelled ") { return "cancel@\(depthOf(l) - dq)" }
                    return nil
                }
                check("diag.traceTargetsCommitCancel", hitReady && targets == ["spectrum", "spectrum", "spectrum", "videoClip", "subtitle"]
                      && ends == ["commit:true@1", "cancel@1", "commit:false@1", "commit:true@2", "commit:true@2"] && s.history.undoDepth == dq + 1
                      && !tl.joined().contains(".mp4") && !tl.joined().contains(m1.id.uuidString),
                      "hitReady \(hitReady) targets \(targets) ends \(ends)")
                s.undo()
            }
            let w2 = s.timeline.spectrum(m2.id).map { s.spectrumWarnings($0) } ?? []
            check("move.guardsIntact", rm.map { s.spectrumWarnings($0) } == [] && w2 == [.unset]
                  && s.timeline.spectrumExportBlockers().map(\.spectrumID) == [m2.id], "m1 \(rm.map { s.spectrumWarnings($0) } ?? []) m2 \(w2)")
        }
        do {   // 13절 이름 범위
            // 13. 2C-2(2026-10-26): 스펙트럼 가장자리 트림 — 기존 트림 끌기(누름 = beginGesture → updateTrim → commitGesture/cancelGesture), 엔진 trimmingSpectrum.
            //     fixture(trimTimeline): TA 쌍을 60에서 잘라 연결을 풀고 소리 조각을 따로 옮김 — 계보 하나의 조각이 A1 [30,90)·A2 [120,180)(빈틈 90–120),
            //     영상 0–120 그대로, 자막 150–170. 스펙트럼 레인 둘: L1에 t1 [40,80)(그 계보)·t4 [80,81)(1프레임, 그 계보)·t2 [100,130)(고르지 않음),
            //     L2에 t3 [0,20)(그 계보 — 조각이 없는 구간뿐). 실제 보기에 합성 마우스·키 이벤트.
            EditorLayout.shared.leftTab = .adjust
            let p13 = out.appendingPathComponent("trim.ontheframe")
            guard let b13 = await makeProject(s, file: p13, media: ta, build: Self.trimTimeline) else {
                return finish(folder, checks + [Check(name: "trim.setup", pass: false, detail: s.statusMessage ?? "")])
            }
            _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv)
            _ = await LaneSelfTest.waitUntil(3) { w.isKeyWindow && NSApp.isActive }
            await LaneSelfTest.settle()
            let sp13 = b13.spectra.sorted { ($0.lane.uuidString, $0.start) < ($1.lane.uuidString, $1.start) }
            guard let t1 = b13.spectra.first(where: { $0.start == 40 }), let t4 = b13.spectra.first(where: { $0.start == 80 }),
                  let t2 = b13.spectra.first(where: { $0.start == 100 }), let t3 = b13.spectra.first(where: { $0.lane != t1.lane }),
                  t4.lane == t1.lane, t2.lane == t1.lane, let key = t1.sourceKey, sp13.count == 4 else {
                return finish(folder, checks + [Check(name: "trim.fixture", pass: false, detail: Self.states(b13))])
            }
            let L1 = t1.lane, L2 = t3.lane, ppf = tv.pixelsPerFrame
            func othersSame(_ t: Timeline, _ b: Timeline) -> Bool { t.clips == b.clips && t.audioClips == b.audioClips && t.subtitles == b.subtitles && t.lanes == b.lanes && t.media == b.media }
            func item(_ id: UUID) -> SpectrumItem? { s.timeline.spectrum(id) }
            /// 같은 ID·레인·소스·모양이고 구간만 [a, b)인가
            func only(_ id: UUID, _ orig: SpectrumItem, _ a: Int, _ b: Int) -> Bool { item(id) == orig.with(start: a, length: b - a) }
            func ly(_ l: UUID) -> CGFloat { tv.laneRect(l)?.midY ?? 0 }
            /// 레인 l의 보기 x0을 눌러 x1까지(단계 나눠) 끈다. up이면 놓는다.
            func trimDrag(_ l: UUID, _ x0: CGFloat, to x1: CGFloat, steps: Int = 3, up: Bool = true) async {
                await LaneSelfTest.mouse(.leftMouseDown, win(NSPoint(x: x0, y: ly(l))), w)
                for i in 1...steps { await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: x0 + (x1 - x0) * CGFloat(i) / CGFloat(steps), y: ly(l))), w) }
                if up { await LaneSelfTest.mouse(.leftMouseUp, win(NSPoint(x: x1, y: ly(l))), w) }
                await LaneSelfTest.settle()
            }
            func upAt(_ l: UUID, _ px: CGFloat) async { await LaneSelfTest.mouse(.leftMouseUp, win(NSPoint(x: px, y: ly(l))), w); await LaneSelfTest.settle() }
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            /// 접근성 트리의 글자(11절과 같은 방식) — 고를 수 있는 SwiftUI 글이 여기에 보인다
            func axTexts(_ e: Any, depth: Int = 0) -> [String] {
                guard depth < 60, let o = e as? NSObject else { return [] }
                var out: [String] = [], kids: [Any] = []
                if let p = o as? NSAccessibilityProtocol {
                    if let l = p.accessibilityLabel(), !l.isEmpty { out.append(l) }
                    if let v = p.accessibilityValue() as? String, !v.isEmpty { out.append(v) }
                    kids = p.accessibilityChildren() ?? []
                }
                for a in [NSAccessibility.Attribute.title, .value, .description] {
                    if let v = o.accessibilityAttributeValue(a) as? String, !v.isEmpty { out.append(v) }
                }
                if kids.isEmpty, let c = o.accessibilityAttributeValue(.children) as? [Any] { kids = c }
                for c in kids { out += axTexts(c, depth: depth + 1) }
                return out
            }
            let coveragePrefix = "선택한 오디오 소스가 없는 구간("
            func panelCoverage() -> [String] { Array(Set(axTexts(w.contentView!).filter { $0.hasPrefix(coveragePrefix) })) }

            // 13a. 가장자리 판정: 시작·끝·본문, 이어 붙은 경계(오른쪽 항목의 시작), 1프레임 항목의 두 가장자리와 바깥 1 pt, 빈 곳, clipHit에는 없음
            func tgt(_ px: CGFloat, _ l: UUID) -> String {
                guard let (id, e) = tv.spectrumTarget(NSPoint(x: px, y: ly(l))) else { return "-" }
                let n = id == t1.id ? "t1" : id == t4.id ? "t4" : id == t2.id ? "t2" : id == t3.id ? "t3" : "?"
                return n + (e == .start ? "<" : e == .end ? ">" : "")
            }
            let hitSeq = [tgt(tv.x(40) + 1, L1), tgt(tv.x(60), L1), tgt(tv.x(80) - 1, L1), tgt(tv.x(80), L1), tgt(tv.x(80) + 0.3, L1), tgt(tv.x(81) - 0.3, L1),
                          tgt(tv.x(81) + 0.5, L1), tgt(tv.x(81) + 3, L1), tgt(tv.x(40) - 0.5, L1), tgt(tv.x(130) + 0.5, L1), tgt(tv.x(10), L2)]
            let hitExpect = ["t1<", "t1", "t1>", "t4<", "t4<", "t4>", "t4>", "-", "t1<", "t2>", "t3"]
            check("trim.edgeTargets", hitSeq == hitExpect && tv.clipHit(NSPoint(x: tv.x(40) + 1, y: ly(L1))) == nil && ppf >= 0.9,
                  "\(hitSeq) ppf \(ppf)")
            // 자르기 도구: 가장자리·본문을 눌러도 스펙트럼을 자르거나 트림하지 않음(clipHit 밖)
            let d0 = s.history.undoDepth
            s.setTool(.cut)
            await trimDrag(L1, tv.x(40) + 1, to: tv.x(30) + 1); await click(NSPoint(x: tv.x(60), y: ly(L1)))
            s.setTool(.selection)
            check("trim.cutToolNoSplitNoTrim", s.timeline == b13 && s.history.undoDepth == d0 && s.gestureBase == nil)
            // 13b. 왼쪽 트림(시작 40 → 30): 한 단계, 끝·ID·레인·소스·모양 그대로, 소리·영상·자막·다른 스펙트럼 그대로, 고른 채, 덮인 구간이라 무음 안내 없음
            s.statusMessage = nil
            await trimDrag(L1, tv.x(40) + 1, to: tv.x(30) + 1, steps: 4)
            let tA = s.timeline
            check("trim.left", only(t1.id, t1, 30, 80) && othersSame(tA, b13) && tA.spectrum(t2.id) == t2 && tA.spectrum(t3.id) == t3 && tA.spectrum(t4.id) == t4
                  && s.history.undoDepth == d0 + 1 && s.selection == t1.id && s.gestureBase == nil && s.isDirty && s.statusMessage == nil,
                  "t1 \(item(t1.id).map { "\($0.start)..<\($0.end)" } ?? "-") depth \(s.history.undoDepth - d0) status '\(s.statusMessage ?? "")'")
            // 13c. 실행 취소·다시 실행: 구간이 정확히 돌아옴
            s.undo(); let undone = s.timeline == b13 && s.selection == t1.id
            s.redo(); let redone = s.timeline == tA && s.selection == t1.id
            check("trim.undoRedo", undone && redone, "undo \(undone) redo \(redone)")
            // 13d. 오른쪽 트림(끝 80 → 60, 줄이기)
            await trimDrag(L1, tv.x(80) - 1, to: tv.x(60) - 1)
            check("trim.right", only(t1.id, t1, 30, 60) && othersSame(s.timeline, b13) && s.timeline.spectrum(t4.id) == t4 && s.history.undoDepth == d0 + 2,
                  "t1 \(item(t1.id).map { "\($0.start)..<\($0.end)" } ?? "-")")
            // 13e. 소스 밖으로 늘이기(시작 30 → 10): 받아들임(구간을 소스에 맞춰 자르지 않음), 소스 그대로·정상·경고 없음, 무음 안내(상태 줄·패널), 소리 클립 그대로
            await trimDrag(L1, tv.x(30) + 1, to: tv.x(10) + 1)
            let tE = s.timeline
            _ = await LaneSelfTest.waitUntil(3) { !panelCoverage().isEmpty }
            let cov = s.timeline.spectrum(t1.id).map { s.spectrumUncoveredRanges($0) } ?? []
            check("trim.extendBeforeSourceSilent", only(t1.id, t1, 10, 60) && cov == [10..<30] && item(t1.id).map { s.timeline.spectrumSourceState($0) } == .ok
                  && item(t1.id).map { s.spectrumWarnings($0) } == [] && s.statusMessage == ProjectStore.spectrumSilenceNotice && panelCoverage().count == 1
                  && s.timeline.audioClips == b13.audioClips && s.history.undoDepth == d0 + 3,
                  "cov \(cov) status '\(s.statusMessage ?? "")' panel \(panelCoverage())")
            // 13f. 최소 1프레임: 시작을 끝 너머로 → [59,60), 끝을 시작 앞으로 → [10,11). 각각 실행 취소
            await trimDrag(L1, tv.x(10) + 1, to: tv.x(200))
            let minStart = only(t1.id, t1, 59, 60); s.undo()
            await trimDrag(L1, tv.x(60) - 1, to: tv.x(0) - 30)
            let minEnd = only(t1.id, t1, 10, 11); s.undo()
            check("trim.minimumOneFrame", minStart && minEnd && s.timeline == tE && s.history.undoDepth == d0 + 3, "start \(minStart) end \(minEnd)")
            // 13g. 0 경계: 시작을 0 앞으로 끌면 0에서 멈춤(음수 시작 없음)
            await trimDrag(L1, tv.x(10) + 1, to: tv.x(0) - 40)
            let zero = only(t1.id, t1, 0, 60); s.undo()
            check("trim.clampsAtZero", zero && s.timeline == tE, "t1 \(item(t1.id).map { "\($0.start)..<\($0.end)" } ?? "-")")
            // 13h. 같은 레인 겹침(끝 60 → 85, t4 [80,81)과 겹침): 끄는 중 거부 제안(빨간 상자, 타임라인 그대로), 놓으면 바뀌지 않음·기록 없음·스펙트럼 트림 겹침 문구,
            //      소스 조각 겹침 경고와 다름(t1 경고 없음), 옮기기 문구와 다름. 옮기지 않음.
            let redAt = NSPoint(x: tv.x(83), y: ly(L1)), pxNo = pixel(redAt), dE = s.history.undoDepth
            await trimDrag(L1, tv.x(60) - 1, to: tv.x(85) - 1, up: false)
            let rej = s.spectrumTrimRejected
            let duringOK = rej?.id == t1.id && rej?.range == 10..<85 && s.timeline == tE && s.gestureBase != nil
            tv.display()
            let pxRed = pixel(redAt)
            let redder = { (c: NSColor?) in c.map { $0.redComponent - $0.greenComponent } ?? 0 }
            await upAt(L1, tv.x(85) - 1)
            check("trim.overlapRejected", duringOK && redder(pxRed) > redder(pxNo) + 0.08 && s.timeline == tE && s.history.undoDepth == dE && s.gestureBase == nil
                  && s.spectrumTrimRejected == nil && s.statusMessage == ProjectStore.spectrumTrimOverlap && s.statusMessage != ProjectStore.spectrumMoveOverlap
                  && s.timeline.spectrum(t4.id) == t4 && item(t1.id).map { s.spectrumWarnings($0) } == [],
                  "during \(duringOK) rej \(rej.map { "\($0.range)" } ?? "-") px \(rgb(pxNo)) → \(rgb(pxRed)) status '\(s.statusMessage ?? "")'")
            // 13i. 다른 레인(L2) t3의 끝 20 → 200: 조각이 없는 앞(0–30)·조각 사이 빈틈(90–120, A1·A2)·뒤(180–200)가 무음 구간. 소스는 정상(없음 아님)
            await trimDrag(L2, tv.x(20) - 1, to: tv.x(200) - 1)
            let tI = s.timeline
            let cov3 = item(t3.id).map { s.spectrumUncoveredRanges($0) } ?? []
            check("trim.extendAcrossGapsAndLanes", only(t3.id, t3, 0, 200) && cov3 == [0..<30, 90..<120, 180..<200] && item(t3.id).map { tI.spectrumSourceState($0) } == .ok
                  && item(t3.id).map { s.spectrumWarnings($0) } == [] && s.statusMessage == ProjectStore.spectrumSilenceNotice && tI.durationFrames == 200
                  && othersSame(tI, b13) && tI.spectrum(t1.id) == tE.spectrum(t1.id) && s.history.undoDepth == dE + 1,
                  "cov \(cov3) dur \(tI.durationFrames)")
            // 13j. 바뀌지 않은 트림: 누르고 놓기, 끌었다 제자리로 → 기록 없음, 저장 상태 그대로
            let dI = s.history.undoDepth, dirtyI = s.isDirty
            await trimDrag(L1, tv.x(10) + 1, to: tv.x(10) + 1, steps: 1)
            await LaneSelfTest.mouse(.leftMouseDown, win(NSPoint(x: tv.x(60) - 1, y: ly(L1))), w)
            await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: tv.x(70) - 1, y: ly(L1))), w)
            await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: tv.x(60) - 1, y: ly(L1))), w); await upAt(L1, tv.x(60) - 1)
            check("trim.noOpNoHistory", s.timeline == tI && s.history.undoDepth == dI && s.isDirty == dirtyI && s.gestureBase == nil)
            // 13k. 취소(모두 tI에서, 기록 없음): Esc·초점 잃음·알림 시트·끄는 중 새 누름, 그 뒤 늦은 끌기·놓기는 아무것도 하지 않음
            func trimming() async -> Bool { await trimDrag(L1, tv.x(10) + 1, to: tv.x(5) + 1, up: false); return only(t1.id, t1, 5, 60) && s.gestureBase != nil }
            let e1 = await trimming()
            await LaneSelfTest.key(53, "\u{1b}", [], w); await LaneSelfTest.settle()
            let e2 = s.timeline == tI && s.gestureBase == nil
            await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: tv.x(2), y: ly(L1))), w); await upAt(L1, tv.x(2))
            check("trim.cancelEscape", e1 && e2 && s.timeline == tI && s.history.undoDepth == dI, "trimming \(e1) esc \(e2)")
            let f1 = await trimming()
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w); await LaneSelfTest.settle()
            let f2 = s.timeline == tI && s.gestureBase == nil
            await upAt(L1, tv.x(5) + 1)
            _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv)
            check("trim.cancelFocusLoss", f1 && f2 && s.timeline == tI && s.history.undoDepth == dI, "trimming \(f1) resign \(f2)")
            let m1 = await trimming()
            s.presentAlert(ProjectStore.AlertInfo(title: "검사 알림", message: "스펙트럼 트림 중 알림"))
            let sheet = await LaneSelfTest.waitUntil(3) { s.alerts.isShowing && w.attachedSheet != nil }
            await LaneSelfTest.settle()
            let m2 = s.timeline == tI && s.gestureBase == nil
            await upAt(L1, tv.x(5) + 1)
            await dismiss()
            _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv)
            check("trim.cancelModalAlert", m1 && sheet && m2 && s.timeline == tI && s.history.undoDepth == dI, "trimming \(m1) sheet \(sheet) cancelled \(m2)")
            let n1 = await trimming()
            await LaneSelfTest.mouse(.leftMouseDown, win(viewPoint(L2, frame: 300)), w)   // 빈 곳 새 누름
            let n2 = s.timeline == tI && s.gestureBase == nil
            await LaneSelfTest.mouse(.leftMouseUp, win(viewPoint(L2, frame: 300)), w); await LaneSelfTest.settle()
            check("trim.cancelNewPress", n1 && n2 && s.timeline == tI && s.history.undoDepth == dI, "trimming \(n1) newPress \(n2)")
            // 끄는 중 자르기 도구로 바꾸기 거부(트림 그대로 확정 → 실행 취소), 두 번 놓기·늦은 끌기는 한 단계만
            let o1 = await trimming()
            let refused = !s.setTool(.cut) && s.tool == .selection
            await upAt(L1, tv.x(5) + 1)
            let once = s.history.undoDepth
            await upAt(L1, tv.x(5) + 1); await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: tv.x(1), y: ly(L1))), w); await upAt(L1, tv.x(1))
            check("trim.toolSwitchRefusedAndDuplicateUp", o1 && refused && once == dI + 1 && s.history.undoDepth == once && only(t1.id, t1, 5, 60),
                  "trimming \(o1) refused \(refused) depth \(once - dI)/\(s.history.undoDepth - dI)")
            s.undo()
            // 13l. 끄는 중 프로젝트 교체: 끌기 취소, 새 프로젝트 그대로·옛 선택 없음, 늦은 끌기·놓기 아무것도 하지 않음
            let pr = await trimming()
            s.resetProject(); await LaneSelfTest.settle()
            let fresh = s.timeline
            await LaneSelfTest.mouse(.leftMouseDragged, win(NSPoint(x: tv.x(1), y: ly(L1))), w); await upAt(L1, tv.x(1))
            check("trim.cancelProjectReplace", pr && s.gestureBase == nil && s.timeline == fresh && fresh.spectra.isEmpty && s.history.undoDepth == 0 && s.selection == nil)
            // 13m. 저장·다시 열기(일회용 파일): 트림한 구간(위 tI — 처음 파일 trim.ontheframe 위에 다시 만들지 않음) 다른 이름으로 저장 → 그 파일을 다시 열기 →
            //      같은 ID·레인·소스·모양·구간, 소리 클립 그대로, 형식 8. 그 파일에서 다시 트림 → ⌘S(같은 경로에 보통 저장) → 같은 파일을 다시 열기.
            let o13 = await s.openProject(at: p13); await dismiss()
            _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv)
            _ = await LaneSelfTest.waitUntil(3) { w.isKeyWindow && NSApp.isActive && tv.spectrumHit(NSPoint(x: tv.x(60), y: ly(L1))) == t1.id }
            await LaneSelfTest.settle()
            let reopenedBase = s.timeline == b13
            await trimDrag(L1, tv.x(40) + 1, to: tv.x(10) + 1)
            await trimDrag(L2, tv.x(20) - 1, to: tv.x(200) - 1)
            let tS = s.timeline
            let p13b = out.appendingPathComponent("trim-saved-as.ontheframe")
            let w13 = s.writeProject(to: p13b); s.resetProject()
            let r13 = await s.openProject(at: p13b); await dismiss()
            let v13 = (try? Data(contentsOf: p13b)).flatMap { try? ProjectFile.decode($0).document.version }
            let saveAsOK = o13 && reopenedBase && w13 && r13 && v13 == 8 && s.timeline == tS && only(t1.id, t1, 10, 80) && only(t3.id, t3, 0, 200)
                && s.timeline.audioClips == b13.audioClips && s.timeline.lanes == b13.lanes && s.projectURL == p13b
            _ = await LaneSelfTest.regainFocus(w); w.makeFirstResponder(tv)
            _ = await LaneSelfTest.waitUntil(3) { w.isKeyWindow && NSApp.isActive && tv.spectrumHit(NSPoint(x: tv.x(60), y: ly(L1))) == t1.id }
            await LaneSelfTest.settle()
            await trimDrag(L1, tv.x(80) - 1, to: tv.x(70) - 1)   // 끝 80 → 70
            let tN = s.timeline
            var saved = false
            s.saveProject { saved = $0 }
            let cleanAfterSave = !s.isDirty
            s.resetProject()
            let rN = await s.openProject(at: p13b); await dismiss()
            let vN = (try? Data(contentsOf: p13b)).flatMap { try? ProjectFile.decode($0).document.version }
            let saveOK = saved && cleanAfterSave && rN && vN == 8 && s.timeline == tN && only(t1.id, t1, 10, 70) && only(t3.id, t3, 0, 200)
                && s.timeline.audioClips == b13.audioClips && item(t1.id)?.sourceKey == key
            check("trim.persisted", saveAsOK && saveOK, "saveAs \(saveAsOK) (open \(o13) base \(reopenedBase) version \(v13 ?? -1)) save \(saveOK) (saved \(saved) clean \(cleanAfterSave) version \(vN ?? -1))")
            // 13n. 경고·내보내기 막음 그대로: t1·t3 경고 없음(소스 정상, 무음 구간은 경고가 아님), t2 고르지 않음, 엔진 막음 판정 t2 하나, 내보내기는 대상 파일 전 거부
            let dest13 = out.appendingPathComponent("trim.mp4"), keep13 = Data("keep".utf8)
            try? keep13.write(to: dest13)
            s.startExport(.fromSavePanel(dest13))
            _ = await LaneSelfTest.waitUntil(60) { s.exportPhase == .idle && s.alerts.isShowing }
            let refused13 = s.alert?.title == "내보내기 실패" && (s.alert?.message ?? "").contains("스펙트럼") && (try? Data(contentsOf: dest13)) == keep13
            await dismiss()
            check("trim.guardsIntact", item(t1.id).map { s.spectrumWarnings($0) } == [] && item(t3.id).map { s.spectrumWarnings($0) } == []
                  && item(t2.id).map { s.spectrumWarnings($0) } == [.unset] && s.timeline.spectrumExportBlockers().map(\.spectrumID) == [t2.id] && refused13,
                  "blockers \(s.timeline.spectrumExportBlockers().count) refused \(refused13)")
            // 13o. 무음 구간 계산(순수 — 엔진 편집으로 만든 변형, 앱 계산 spectrumUncoveredRanges): 조각 합집합(묶음 범위가 아님), 레인 무관, 서로 다른 상태 구별
            func cv(_ a: Int, _ b: Int, _ t: Timeline = b13, key k: UUID? = key) -> [Range<Int>] {
                ProjectStore.spectrumUncoveredRanges(SpectrumItem(lane: L1, start: a, length: b - a, sourceKey: k), in: t)
            }
            let pieces = b13.audioClips.filter { $0.lineageKey == key }.sorted { $0.start < $1.start }
            let overlapT = pieces.count == 2 ? try? b13.relocating(clip: pieces[1].id, toStart: 60) : nil       // A2 조각 60–120: A1 30–90과 60–90에서 겹침
            let deletedT = pieces.count == 2 ? try? b13.lifting(clip: pieces[0].id).lifting(clip: pieces[1].id) : nil
            let probe = SpectrumItem(lane: L1, start: 0, length: 200, sourceKey: key)
            let mediaID = pieces.first?.mediaID ?? UUID()
            let missingW = ProjectStore.spectrumWarnings(probe, in: b13, missing: [mediaID])
            let cases: [(String, Bool)] = [
                ("full", cv(40, 80) == [] && cv(120, 180) == []),
                ("before", cv(10, 50) == [10..<30]),
                ("after", cv(150, 200) == [180..<200]),
                ("gapBetweenLanes", cv(60, 150) == [90..<120]),
                ("all", cv(0, 200) == [0..<30, 90..<120, 180..<200]),
                ("insideGapOnly", cv(95, 115) == [95..<115]),
                ("edgesTouch", cv(90, 120) == [90..<120] && cv(89, 121) == [90..<120]),
                ("overlapCountsCovered", overlapT.map { cv(20, 130, $0) == [20..<30, 120..<130] && !$0.spectrumOverlaps(key: key).isEmpty } == true),
                ("unset", cv(0, 200, key: nil) == []),
                ("deletedSource", deletedT.map { cv(0, 200, $0) == [] && $0.spectrumSourceState(probe) == .missing && ProjectStore.spectrumWarnings(probe, in: $0, missing: []) == [.missingSource] } == true),
                ("missingMediaStillComputed", cv(0, 200) == [0..<30, 90..<120, 180..<200] && missingW.contains { if case .missingMedia = $0 { return true }; return false }
                    && !missingW.contains(.missingSource)),
            ]
            check("coverage.cases", cases.allSatisfy(\.1), cases.filter { !$0.1 }.map(\.0).joined(separator: ","))
        }
        EditorLayout.shared.leftTab = .media
        finish(folder, checks)
    }
    /// 2C-1 옮기기 fixture: V1·A1 TA 쌍 0–120(60에서 자름 — 소리 조각 둘이 같은 계보), 자막 150–170, 스펙트럼 레인 둘: 첫 레인 [10,40)(그 계보, 아날로그·위쪽)·
    /// [100,130)(고르지 않음), 둘째 레인 [0,20)(그 계보)
    static func moveTimeline(_ base: Timeline, _ m: UUID) throws -> Timeline {
        let c = UUID(), sp1 = UUID(), sp2 = UUID(), st = UUID()
        var x = try base.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: c)
        x = try x.splitting(clip: c, atFrame: 60)
        guard let key = x.audioClips.first?.lineageKey else { throw EditError.badIndex }
        x = try x.addingLane(.subtitle, name: "자막", id: st, outward: true).addingSubtitle(lane: st, at: 150, length: 20, text: "자막")
        x = try x.addingLane(.spectrum, name: "스펙트럼", id: sp1, outward: true).addingLane(.spectrum, name: "스펙트럼", id: sp2, outward: true)
        var analog = SpectrumItemStyle.provisionalDefault; analog.mode = .analog; analog.sides = .above
        x = try x.addingSpectrum(lane: sp1, at: 10, length: 30, sourceKey: key, style: analog)
        x = try x.addingSpectrum(lane: sp1, at: 100, length: 30, sourceKey: nil)
        return try x.addingSpectrum(lane: sp2, at: 0, length: 20, sourceKey: key)
    }

    /// 2C-2 트림 fixture: TA 쌍을 60에서 잘라 두 조각의 연결을 풀고 소리 조각을 따로 옮김 — 같은 계보가 A1 [30,90)·A2(새 오디오 레인) [120,180),
    /// 영상 [0,60)·[60,120) 그대로, 자막 150–170. 스펙트럼 레인 둘: 첫 레인 [40,80)(그 계보)·[80,81)(1프레임, 그 계보)·[100,130)(고르지 않음), 둘째 레인 [0,20)(그 계보)
    static func trimTimeline(_ base: Timeline, _ m: UUID) throws -> Timeline {
        let c = UUID(), a2 = UUID(), st = UUID(), sp1 = UUID(), sp2 = UUID()
        var x = try base.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: c)
        x = try x.splitting(clip: c, atFrame: 60)
        let pieces = x.audioClips.sorted { $0.start < $1.start }
        guard pieces.count == 2, Set(pieces.map(\.lineageKey)).count == 1 else { throw EditError.badIndex }
        let key = pieces[0].lineageKey
        x = try x.unlinking(clip: pieces[0].id).unlinking(clip: pieces[1].id)
        x = try x.addingLane(.audio, name: "오디오", id: a2, outward: true)
        x = try x.relocating(clip: pieces[1].id, toStart: 120, lane: a2).relocating(clip: pieces[0].id, toStart: 30)
        x = try x.addingLane(.subtitle, name: "자막", id: st, outward: true).addingSubtitle(lane: st, at: 150, length: 20, text: "자막")
        x = try x.addingLane(.spectrum, name: "스펙트럼", id: sp1, outward: true).addingLane(.spectrum, name: "스펙트럼", id: sp2, outward: true)
        x = try x.addingSpectrum(lane: sp1, at: 40, length: 40, sourceKey: key)
        x = try x.addingSpectrum(lane: sp1, at: 80, length: 1, sourceKey: key)
        x = try x.addingSpectrum(lane: sp1, at: 100, length: 30, sourceKey: nil)
        return try x.addingSpectrum(lane: sp2, at: 0, length: 20, sourceKey: key)
    }

    /// 여러 미디어로 프로젝트 만들기(2B-3): 이름으로 미디어 ID를 찾아 build에 넘긴다(가져온 차례와 무관).
    static func makeProjectMulti(_ s: ProjectStore, file: URL, media: [URL], build: (Timeline, [UUID]) throws -> Timeline) async -> Timeline? {
        s.resetProject()
        s.importFiles(media)
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == media.count && s.importing == 0 }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        let ids = media.compactMap { u in s.assets.first { $0.name == u.lastPathComponent }?.id }
        guard ids.count == media.count, let t = try? build(s.timeline, ids) else { return nil }
        s.loadTimelineForTest(t)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        return s.writeProject(to: file) ? s.timeline : nil
    }
    /// 2B-3 소스 fixture(media = [TA, TB, WAV]): V1·A1에 TA 쌍(0–120, 60에서 자름 — 조각 2)·TB 쌍(120–210), TB 쌍의 복사본 둘을 0에(V2·A2, V3·A3 —
    /// 같은 파일·같은 구간·독립 계보), WAV를 A1 210에. 오디오 레인 이름을 모두 "소리"로. 스펙트럼 레인에 [0,60) 소스 = 첫 복사본, [210,300) 소스 = WAV.
    static func sourceTimeline(_ base: Timeline, _ m: [UUID]) throws -> Timeline {
        let ta = UUID(), tb = UUID(), sp = UUID()
        var x = try base.appending(media: m[0], videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: ta)
        x = try x.appending(media: m[1], videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: tb)
        x = try x.splitting(clip: ta, atFrame: 60)
        let cb = try x.copying(clip: tb)
        x = try x.pasting(cb, at: 0, newLaneName: { $0 == .video ? "영상" : "오디오" }).timeline
        let firstCopy = x.audioClips.first { $0.start == 0 && $0.mediaID == m[1] }
        x = try x.pasting(cb, at: 0, newLaneName: { $0 == .video ? "영상" : "오디오" }).timeline
        x = try x.placing(media: m[2], at: 210, videoLane: nil, audioLane: Lane.audioID)
        for l in x.lanes(.audio) { x = try x.renamingLane(l.id, to: "소리") }
        guard let c = firstCopy, let w = x.audioClips.first(where: { $0.mediaID == m[2] }) else { throw EditError.badIndex }
        x = try x.addingLane(.spectrum, name: "스펙트럼", id: sp, outward: true)
        x = try x.addingSpectrum(lane: sp, at: 0, length: 60, sourceKey: c.lineageKey)
        return try x.addingSpectrum(lane: sp, at: 210, length: 90, sourceKey: w.lineageKey)
    }

    /// 2B-2 만들기 fixture: V1·A1에 쌍 둘(0–120, 120–240), 첫 쌍을 60에서 자름(소리 조각 둘 = 같은 계보), 둘째 쌍을 0에 붙여 넣은 복사본(V2·A2, 독립 계보)
    static func createBaseTimeline(_ base: Timeline, _ m: UUID) throws -> Timeline {
        let c1 = UUID(), c2 = UUID()
        var x = try base.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: c1)
        x = try x.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: c2)
        x = try x.splitting(clip: c1, atFrame: 60)
        return try x.pasting(try x.copying(clip: c2), at: 0, newLaneName: { $0 == .video ? "영상" : "오디오" }).timeline
    }

    static func dismiss() async {
        let s = ProjectStore.shared
        while s.alerts.isShowing { s.alerts.pressButton(s.alerts.currentButtons.count > 1 ? 1 : 0); _ = await LaneSelfTest.waitUntil(5) { !s.alerts.isShowing } }
    }

    // MARK: 2B-1 fixture(자체 검사·소유자 확인 공용, 2026-10-26) — 생성 fixture 미디어 하나로 엔진 편집

    /// 빈 프로젝트로 바꾸고 media를 가져와 build로 만든 타임라인을 실행 취소 기록 없이 넣은 뒤 보통 저장 경로로 file에 저장한다. 저장한 타임라인(실패하면 nil).
    static func makeProject(_ s: ProjectStore, file: URL, media: URL, build: (Timeline, UUID) throws -> Timeline) async -> Timeline? {
        s.resetProject()
        s.importFiles([media])
        _ = await LaneSelfTest.waitUntil(30) { s.assets.count == 1 && s.importing == 0 }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        guard let m = s.assets.first, let t = try? build(s.timeline, m.id) else { return nil }
        s.loadTimelineForTest(t)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        return s.writeProject(to: file) ? s.timeline : nil
    }
    /// 스펙트럼 상태 A–E(2B-1): 레인 위에서부터 자막(외곽선 효과) · 빈 스펙트럼 · 스펙트럼 B · 스펙트럼 A · V1 · A1.
    /// 첫 클립 쌍을 60에서 잘라 소리 조각 둘이 같은 계보(P-S1), 둘째 쌍은 스펙트럼 소스로 둔 뒤 지움(지워진 소스 — 빈틈으로 남음).
    /// 스펙트럼 A: 0–120 소스 정상(잘린 계보), 130–200 소스 없음. 스펙트럼 B: 10–70 소스 정상·바꾼 모양(아날로그·위·주황·32밴드·오프셋 40), 205–240 고르지 않음.
    static func richTimeline(_ base: Timeline, _ m: UUID) throws -> Timeline {
        let c1 = UUID(), c2 = UUID()
        var x = try base.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: c1)
        x = try x.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: c2)
        x = try x.splitting(clip: c1, atFrame: 60)
        let pieces = x.audioClips.filter { $0.start < 120 }
        guard pieces.count == 2, Set(pieces.map(\.lineageKey)).count == 1, let l2 = x.audioClips.first(where: { $0.start >= 120 })?.lineageKey else { throw EditError.badIndex }
        let l1 = pieces[0].lineageKey
        let sub = UUID(), spA = UUID(), spB = UUID(), spE = UUID()
        var subStyle = SubtitleStyle.default; subStyle.outline = .default
        x = try x.addingLane(.subtitle, name: "자막", id: sub, outward: true)
        x = try x.addingSubtitle(lane: sub, at: 0, length: 90, text: "스펙트럼 프로젝트 (2B-1)", style: subStyle)
        x = try x.addingLane(.spectrum, name: "스펙트럼 A", id: spA, outward: true)
        x = try x.addingLane(.spectrum, name: "스펙트럼 B", id: spB, outward: true)
        x = try x.addingLane(.spectrum, name: "빈 스펙트럼", id: spE, outward: true)
        x = try x.addingSpectrum(lane: spA, at: 0, length: 120, sourceKey: l1)
        x = try x.addingSpectrum(lane: spA, at: 130, length: 70, sourceKey: l2)
        var st = SpectrumItemStyle.provisionalDefault
        st.mode = .analog; st.sides = .above; st.green = 120; st.blue = 40; st.bands = 32; st.offsetMs = 40
        x = try x.addingSpectrum(lane: spB, at: 10, length: 60, sourceKey: l1, style: st)
        x = try x.addingSpectrum(lane: spB, at: 205, length: 35, sourceKey: nil)
        return try x.lifting(clip: c2)
    }
    /// 상태 F(2B-1): 소스가 정상인 스펙트럼 하나(이 미디어를 지우면 원본 파일 없음)
    static func missingMediaTimeline(_ base: Timeline, _ m: UUID) throws -> Timeline {
        let sp = UUID()
        let x = try base.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: UUID())
            .addingLane(.spectrum, name: "스펙트럼", id: sp, outward: true)
        guard let key = x.audioClips.first?.lineageKey else { throw EditError.badIndex }   // T-H1: 소리 클립이 없으면 만들기 실패(try?가 받음 — 첨자 함정은 받지 못함)
        return try x.addingSpectrum(lane: sp, at: 0, length: 120, sourceKey: key)
    }
    /// 이전 형식 fixture: 5(클립만), 6(자막), 7(켜진 자막 효과) — 계보·스펙트럼 없음
    static func plainTimeline(_ base: Timeline, _ m: UUID) throws -> Timeline {
        try base.appending(media: m, videoLane: Lane.videoID, audioLane: Lane.audioID, clipID: UUID())
    }
    static func subtitleTimeline(_ base: Timeline, _ m: UUID) throws -> Timeline {
        let sub = UUID()
        return try plainTimeline(base, m).addingLane(.subtitle, name: "자막", id: sub, outward: true).addingSubtitle(lane: sub, at: 0, length: 60, text: "형식 6")
    }
    static func effectTimeline(_ base: Timeline, _ m: UUID) throws -> Timeline {
        let sub = UUID()
        var style = SubtitleStyle.default; style.outline = .default
        return try plainTimeline(base, m).addingLane(.subtitle, name: "자막", id: sub, outward: true).addingSubtitle(lane: sub, at: 0, length: 60, text: "형식 7", style: style)
    }
    /// 상태 요약: 스펙트럼 레인(라벨=항목 수, 위에서부터) | 항목(시작:상태, 시작 순)
    static func states(_ t: Timeline) -> String {
        let lanes = t.lanes(.spectrum).map { "\(t.laneLabel($0.id))=\(t.spectra(inLane: $0.id).count)" }.joined(separator: ",")
        let items = t.spectra.sorted { $0.start < $1.start }.map { "\($0.start):\(t.spectrumSourceState($0))" }.joined(separator: ",")
        return lanes + " | " + items
    }
    static let richStates = "SP3=0,SP2=2,SP1=2 | 0:ok,10:ok,130:missing,205:unset"

    /// 소유자 확인용 저장 파일 만들기(2B-1, Debug 전용, `scripts/spectrum-project-manual.sh`의 `-OTFMakeSpectrumProjects`): 실행 폴더에 rich.ontheframe(A–E)와
    /// missing-media.ontheframe(F — 스크립트가 미디어 사본을 지움)를 보통 저장 경로로 쓰고 끝낸다. 결과 <폴더>/spectrum-projects-made.txt.
    static func makeManualProjects(folder: URL) async {
        let s = ProjectStore.shared
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        let rich = await makeProject(s, file: folder.appendingPathComponent("rich.ontheframe"), media: folder.appendingPathComponent("sources/otf-TA.mp4"), build: richTimeline)
        let miss = await makeProject(s, file: folder.appendingPathComponent("missing-media.ontheframe"),
                                     media: folder.appendingPathComponent("sources/otf-TA-copy.mp4"), build: missingMediaTimeline)
        let ok = rich.map { states($0) == richStates } == true && miss != nil
        try? (ok ? "ok" : "failed").write(to: folder.appendingPathComponent("spectrum-projects-made.txt"), atomically: true, encoding: .utf8)
        s.resetProject()
        s.discardConfirmedForTest()
        NSApp.terminate(nil)
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
