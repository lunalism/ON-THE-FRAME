#if DEBUG
import AppKit
import OnTheFrameEngine

/// LANE-SCROLL-CLIP-FIX-01 자체 검사(Debug 전용, 일반 화면에 없음). `open -n -W -a OnTheFrame.app <폴더> --args -OTFLayoutSuite <이름> -OTFLaneHeaderClipTest`.
/// 결과: <폴더>/lane-header-clip-result.json. 진입 인수는 두 레인 fixture 목록에 없으므로 실제 여섯 레인 새 프로젝트로 시작한다.
/// 세로 스크롤 위치(위·가운데·아래·걸친 줄)마다 레인 머리 줄과 타임라인 레인의 세로 맞춤, 머리의 잘라내기, 보이는 레인 영역 밖의
/// 누르기·문맥 메뉴, 이름 칸의 잘라내기, 창 크기 바꾸기를 본다. 스크롤이 생기도록 빈 오디오 레인을 더하고 끝에 실행 취소로 되돌린다.
/// 합성 호출(스크롤 위치 지정, 보기 메서드·hitTest 직접 호출, 그린 화면 비교)이며 실제 트랙패드 스크롤 확인이 아니다.
@MainActor
enum LaneHeaderClipSelfTest {
    typealias Check = LaneSelfTest.Check

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") {
            checks.append(Check(name: n, pass: p, detail: d)); print(p ? "PASS" : "FAIL", "[clip]", n, d); fflush(stdout)
        }
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow, let cv = w.contentView, let c = LaneSelfTest.find(TimelineContainerView.self, cv) else {
            check("setup.window", false); return finish(folder, checks)
        }
        w.makeKeyAndOrderFront(nil)
        await LaneSelfTest.settle()
        let header = c.header, tv = c.timelineView, sv = c.scrollView, clip = sv.contentView
        let labels = s.timeline.lanes.map { s.timeline.laneLabel($0.id) }.joined(separator: " ")
        check("setup.sixLaneProductionStart", s.timeline.lanes == Lane.newProjectDefaults && s.history.undoDepth == 0, labels)
        check("header.clipsToBoundsAndEditorClip",
              header.clipsToBounds && header.editorClip.clipsToBounds && header.editorClip.frame == header.laneViewport
              && header.laneViewport.minY == TimelineNSView.rulerHeight && header.laneViewport.maxY == header.bounds.maxY,
              "viewport \(header.laneViewport) bounds \(header.bounds)")

        // A small window plus extra empty lanes guarantees a vertical scroll range (same as a user adding lanes).
        let originalFrame = w.frame
        w.setFrame(NSRect(x: originalFrame.minX, y: originalFrame.maxY - 640, width: max(900, originalFrame.width), height: 640), display: true)
        await LaneSelfTest.settle()
        var added = 0
        while tv.frame.height <= clip.bounds.height + 200 && added < 8 { s.addLane(.audio); added += 1; await LaneSelfTest.settle() }
        let maxY = max(0, tv.frame.height - clip.bounds.height)
        check("setup.verticalScrollRange", maxY > 150, "doc \(Int(tv.frame.height)) visible \(Int(clip.bounds.height)) added \(added)")

        func scroll(_ y: CGFloat) async {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), max(0, tv.frame.height - clip.bounds.height))))
            sv.reflectScrolledClipView(clip)
            await LaneSelfTest.settle()
        }
        /// Every header row is on the same window y as its timeline lane, and the header offset equals the scroll origin.
        func aligned() -> (Bool, String) {
            var worst: CGFloat = 0
            for l in s.timeline.lanes {
                guard let r = tv.laneRect(l.id) else { return (false, "no rect \(l.name)") }
                let contentY = tv.convert(NSPoint(x: 0, y: r.midY), to: header).y
                worst = max(worst, abs(header.rowRect(l.id).midY - contentY))
            }
            return (worst < 0.5 && header.verticalOffset == clip.bounds.minY, "worst \(worst) offset \(header.verticalOffset) clip \(clip.bounds.minY)")
        }
        /// Pixels of the window just above the timeline container, over the header column (toolbar row). Drawing that escaped
        /// the header (the defect) changes this band when rows are scrolled above the viewport.
        func bandAbove() -> Data? {
            let f = c.convert(c.bounds, to: cv)
            let band = cv.isFlipped ? NSRect(x: f.minX, y: max(0, f.minY - 40), width: LaneHeaderView.width, height: min(40, f.minY))
                                    : NSRect(x: f.minX, y: f.maxY, width: LaneHeaderView.width, height: min(40, cv.bounds.maxY - f.maxY))
            guard band.height >= 4, let rep = cv.bitmapImageRepForCachingDisplay(in: band) else { return nil }
            cv.cacheDisplay(in: band, to: rep)
            return rep.tiffRepresentation
        }

        // 1. Top / middle / bottom scroll positions.
        await scroll(0)
        let topBand = bandAbove()
        var a = aligned(); check("scroll.top.aligned", a.0, a.1)
        await scroll(maxY / 2)
        a = aligned(); check("scroll.middle.aligned", a.0, a.1)
        await scroll(maxY)
        a = aligned(); check("scroll.bottom.aligned", a.0, a.1)
        let v3 = Lane.videoV3ID
        check("scroll.bottom.upperRowsOutsideViewport", header.rowRect(v3).maxY <= header.laneViewport.minY, "V3 row \(header.rowRect(v3))")
        let bottomBand = bandAbove()
        check("clip.noDrawingAboveTimeline", topBand != nil && topBand == bottomBand, topBand == nil ? "band unavailable" : "band equal \(topBand == bottomBand)")

        // 2. Partially visible rows at the top (under the ruler strip) and at the bottom edge.
        let v2 = Lane.videoV2ID
        if let r = tv.laneRect(v2) {
            await scroll(r.minY + r.height / 2 - TimelineNSView.rulerHeight)
            let row = header.rowRect(v2)
            let straddles = row.minY < header.laneViewport.minY && row.maxY > header.laneViewport.minY
            check("partial.top.rowStraddlesRuler", straddles, "row \(row)")
            check("partial.top.hitOnlyVisiblePart",
                  header.lane(at: NSPoint(x: 50, y: header.laneViewport.minY - 2)) == nil && header.lane(at: NSPoint(x: 50, y: header.laneViewport.minY + 2))?.id == v2)
            a = aligned(); check("partial.top.aligned", a.0, a.1)
        } else { check("partial.top.setup", false) }
        let bottomEdge = header.laneViewport.maxY
        if let l = s.timeline.lanes.first(where: { header.rowRect($0.id).minY < bottomEdge && header.rowRect($0.id).maxY > bottomEdge }) {
            check("partial.bottom.hitOnlyVisiblePart",
                  header.lane(at: NSPoint(x: 50, y: bottomEdge - 2))?.id == l.id && header.lane(at: NSPoint(x: 50, y: bottomEdge + 2)) == nil, l.name)
        } else {
            check("partial.bottom.hitOnlyVisiblePart", header.lane(at: NSPoint(x: 50, y: bottomEdge + 2)) == nil, "no row straddles the bottom edge at this offset")
        }

        // 3. Hit-testing outside the lane viewport (scrolled to the bottom: V3/V2 rows lie above the viewport).
        await scroll(maxY)
        s.selectLane(nil)
        let aboveHeader = header.convert(NSPoint(x: 50, y: -10), to: nil)
        let hitAbove = cv.hitTest(cv.superview?.convert(aboveHeader, from: nil) ?? aboveHeader)
        check("hit.aboveTimelineNotHeader", hitAbove.map { !$0.isDescendant(of: header) } ?? true, "\(String(describing: hitAbove.map { type(of: $0) }))")
        check("hit.outsideViewportNoLane",
              header.lane(at: NSPoint(x: 50, y: -10)) == nil && header.lane(at: NSPoint(x: 50, y: TimelineNSView.rulerHeight / 2)) == nil
              && header.lane(at: NSPoint(x: 50, y: header.bounds.maxY + 5)) == nil)
        func rightClick(_ p: NSPoint) -> NSMenu? {
            let wp = header.convert(p, to: nil)
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
            return header.menu(for: e)
        }
        let rulerMenu = rightClick(NSPoint(x: 50, y: TimelineNSView.rulerHeight / 2))
        check("menu.rulerStripHasNoLaneItems", rulerMenu.map { !$0.items.contains { $0.title == "레인 이름 바꾸기…" } } == true && s.selectedLane == nil,
              rulerMenu?.items.map(\.title).joined(separator: ",") ?? "nil")
        // Visible rows keep selection, context menu and click behavior; the editor clip does not take header clicks.
        if let visible = s.timeline.lanes.first(where: { header.laneViewport.contains(NSPoint(x: 50, y: header.rowRect($0.id).midY)) }) {
            let p = NSPoint(x: 50, y: header.rowRect(visible.id).midY)
            let hit = header.hitTest(header.convert(p, to: header.superview))
            check("hit.visibleRowReachesHeader", hit === header, "\(String(describing: hit.map { type(of: $0) }))")
            let m = rightClick(p)
            check("menu.visibleRowSelectsLane", m?.items.contains { $0.title == "레인 이름 바꾸기…" } == true && s.selectedLane == visible.id, visible.name)
            s.selectLane(nil)
            if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: header.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { header.mouseDown(with: e) }
            check("click.visibleRowSelectsLane", s.selectedLane == visible.id, visible.name)
            s.selectLane(nil)
        } else { check("hit.visibleRowSetup", false) }

        // 4. Rename field follows scrolling and is clipped to the lane viewport.
        await scroll(0)
        header.beginRename(v3)
        let inClip = header.editor?.superview === header.editorClip
        await scroll(maxY)
        let ef = header.editor?.frame ?? .zero
        let rulerWindowPoint = header.convert(NSPoint(x: 50, y: TimelineNSView.rulerHeight / 2), to: nil)
        let hitRuler = cv.hitTest(cv.superview?.convert(rulerWindowPoint, from: nil) ?? rulerWindowPoint)
        check("rename.fieldClippedWhenScrolledOut", inClip && ef.maxY <= 0 && hitRuler !== header.editor && !(hitRuler?.isDescendant(of: header.editorClip) ?? false),
              "field \(ef)")
        header.finish(commit: false)
        check("rename.cancelLeavesName", header.editor == nil && s.timeline.laneInfo(v3)?.name == "영상")

        // 5. Window resizing while scrolled to the bottom (clip origin clamps).
        await scroll(maxY)
        let small = w.frame
        w.setFrame(NSRect(x: small.minX, y: small.minY - 160, width: small.width, height: small.height + 160), display: true)
        await LaneSelfTest.settle()
        a = aligned(); check("resize.taller.aligned", a.0 && header.editorClip.frame == header.laneViewport, a.1)
        w.setFrame(small, display: true)
        await LaneSelfTest.settle()
        a = aligned(); check("resize.shorter.aligned", a.0 && header.editorClip.frame == header.laneViewport, a.1)

        // Cleanup: undo the added lanes, restore the window.
        for _ in 0..<added { s.undo() }
        await LaneSelfTest.settle()
        check("cleanup.sixLanes", s.timeline.lanes == Lane.newProjectDefaults)
        w.setFrame(originalFrame, display: true)
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("lane-header-clip-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
