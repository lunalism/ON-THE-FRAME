#if DEBUG
import AppKit
import OnTheFrameEngine

/// LANE-VERTICAL-ZOOM-01 자체 검사(Debug 전용, 일반 화면에 없음). `open -n -W -a OnTheFrame.app <폴더> --args -OTFLayoutSuite <이름> -OTFLayoutReset -OTFLaneZoomTest`.
/// 입력: <폴더>/sources/otf-TA.mp4(생성 fixture 사본). 결과: <폴더>/lane-zoom-result.json. 진입 인수는 두 레인 fixture 목록에 없으므로
/// 실제 여섯 레인 새 프로젝트로 시작한다. `-OTFLayoutReset`으로 나눔선이 기본값인 상태에서 시작해야 한다(자동 타임라인 높이 검사).
/// 처음 맞춤(큰 창에서 여섯 레인이 스크롤 없이 보임, 타임라인 패널 높이 배분, 작은 창의 세로 스크롤), 수동 확대 전후의 창 크기 변경,
/// 모두 맞춤, 대상 규칙(선택 없음 = 모든 레인, 레인 = 그 레인, 클립 = 그 클립의 레인), 상대 높이·한도, 단축키와 조작의 같은 결과,
/// 한글 입력 소스·글 칸 초점, 레인 머리와 내용의 정렬, 확대 뒤 누름 판정·스냅 표시·파형 영역·고정 눈금자, 타임라인 데이터 불변을 본다.
/// 검사는 실제 보기의 배치 좌표를 읽는다(배율 계산만 따로 보지 않는다). 합성 호출·합성 이벤트이며 실제 포인터·트랙패드 확인이 아니다.
@MainActor
enum LaneZoomSelfTest {
    typealias Check = LaneSelfTest.Check

    static func run(folder: URL) async {
        let s = ProjectStore.shared, zoom = LaneZoom.shared, L = EditorLayout.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") {
            checks.append(Check(name: n, pass: p, detail: d)); print(p ? "PASS" : "FAIL", "[zoom]", n, d); fflush(stdout)
        }
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow, let cv = w.contentView, let c = LaneSelfTest.find(TimelineContainerView.self, cv) else {
            check("setup.window", false); return finish(folder, checks)
        }
        w.makeKeyAndOrderFront(nil)
        if !(await LaneSelfTest.regainFocus(w)) { LaneSelfTest.direct = true }
        let header = c.header, tv = c.timelineView, sv = c.scrollView, clip = sv.contentView, ruler = c.ruler
        let rulerH = TimelineNSView.rulerHeight
        let v3 = Lane.videoV3ID, v1 = Lane.videoID, a2 = Lane.audioA2ID, a3 = Lane.audioA3ID

        /// Lets the deferred Auto Fit, the editor split and SwiftUI layout settle.
        func settleLayout() async {
            for _ in 0..<3 { await LaneSelfTest.settle() }
            try? await Task.sleep(nanoseconds: 250_000_000)
            for _ in 0..<3 { await LaneSelfTest.settle() }
        }
        func lanes() -> [Lane] { s.timeline.lanes }
        func heights() -> [CGFloat] { lanes().map { tv.laneRect($0.id)?.height ?? -1 } }
        func height(_ id: UUID) -> CGFloat { tv.laneRect(id)?.height ?? -1 }
        func base(_ id: UUID) -> CGFloat { s.timeline.laneInfo(id).map { TimelineNSView.height($0.kind) } ?? -1 }
        func allBase(except: [UUID] = []) -> Bool { lanes().allSatisfy { except.contains($0.id) || height($0.id) == base($0.id) } }
        var lanesBottom: CGFloat { lanes().compactMap { tv.laneRect($0.id)?.maxY }.max() ?? 0 }
        /// All lanes are inside the visible lane area without scrolling.
        func allVisible() -> Bool { clip.bounds.minY == 0 && lanesBottom <= clip.bounds.height + 0.5 }
        func scrollY(_ y: CGFloat) async {
            let maxY = max(0, tv.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY)))
            sv.reflectScrolledClipView(clip)
            await LaneSelfTest.settle()
        }
        func setWindow(height: CGFloat, width: CGFloat? = nil) async {
            let f = w.frame
            w.setFrame(NSRect(x: f.minX, y: f.maxY - height, width: width ?? f.width, height: height), display: true)
            await settleLayout()
        }
        /// Numbers the Auto Fit decision is made from, read from the real layout. `actualChrome` is the measured difference between
        /// the timeline pane and the visible lane area; it must equal the chrome height the layout uses (`L.timelineChrome`).
        func fitNumbers() -> (possible: Bool, availH: CGFloat, actualChrome: CGFloat, maxPane: CGFloat, basePane: CGFloat, text: String) {
            let availH = max(0, L.lastContentSize.height - EditorLayout.divider)
            let actualChrome = (L.lastSplit?.timeline ?? 0) - c.visibleLaneHeight
            let maxPane = EditorLayout.maxAutoTimeline(availH: availH)
            let basePane = availH - L.baseUpper(availH: availH)
            let need = L.timelineNeed(lanes())
            return (maxPane >= need.minimum, availH, actualChrome, maxPane, basePane,
                    "availH \(Int(availH)) chrome \(L.timelineChrome) actualChrome \(actualChrome) maxPane \(Int(maxPane)) basePane \(Int(basePane)) needFull \(Int(need.full)) needMin \(Int(need.minimum)) pane \(Int(L.lastSplit?.timeline ?? 0)) visible \(Int(c.visibleLaneHeight))")
        }
        func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags) async {
            if LaneSelfTest.direct {   // no key focus: the same router decision, called directly
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) { _ = KeyRouting.handle(e, store: s) }
                await LaneSelfTest.settle(); return
            }
            await LaneSelfTest.key(code, chars, mods, w)
        }
        let optCmd: NSEvent.ModifierFlags = [.command, .option]

        // 0. Six-lane production start in automatic fit, default divider, one generated clip pair on V1/A1.
        await settleLayout()
        check("setup.sixLaneProductionStart", lanes() == Lane.newProjectDefaults && zoom.autoFit && L.upperIsDefault && s.verticalZoomTarget == .all,
              "auto \(zoom.autoFit) upperDefault \(L.upperIsDefault) upper \(L.upperFraction)")
        s.importFiles([folder.appendingPathComponent("sources").appendingPathComponent("otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(60) { s.importing == 0 && s.assets.count == 1 }
        guard let asset = s.assets.first else { check("setup.media", false, "no asset"); return finish(folder, checks) }
        s.addToTimeline(asset.id)
        _ = await LaneSelfTest.waitUntil(10) { s.canPlay }
        await settleLayout()
        guard let vClip = s.timeline.clips(inLane: v1).first else { check("setup.media", false, "no clip on V1"); return finish(folder, checks) }
        check("setup.media", s.timeline.durationFrames == 120 && lanes().count == 6, "duration \(s.timeline.durationFrames)")
        s.select(nil); s.selectLane(nil)
        let t0 = s.timeline, depth0 = s.history.undoDepth, dirty0 = s.isDirty

        // 1. Controls live in the header's fixed strip, left of the ruler, without overlapping each other.
        let controls: [NSView] = [header.zoomOutButton, header.zoomSlider, header.zoomInButton, header.fitButton]
        let strip = NSRect(x: 0, y: 0, width: header.bounds.width, height: rulerH)
        var overlap = false
        for i in controls.indices { for j in controls.indices where j > i { if controls[i].frame.intersects(controls[j].frame) { overlap = true } } }
        check("controls.inHeaderStrip", controls.allSatisfy { $0.superview === header && !$0.isHidden && strip.contains($0.frame) && $0.frame.width > 8 }
              && !overlap && ruler.frame.minX >= header.frame.maxX && header.zoomSlider.isEnabled && header.fitButton.isEnabled,
              controls.map { "\(Int($0.frame.minX))-\(Int($0.frame.maxX))" }.joined(separator: " ") + " overlap \(overlap)")

        // 2. Large window: all six lanes fit without scrolling, and the timeline pane got the height from the split.
        let originalFrame = w.frame
        let vf = w.screen?.visibleFrame ?? originalFrame
        await setWindow(height: vf.height, width: min(vf.width, max(1100, originalFrame.width)))
        let big = fitNumbers()
        check("autofit.large.fitPossibleOnThisScreen", big.possible, big.text)
        check("autofit.large.allSixLanesVisible", zoom.autoFit && allVisible()
              && lanes().allSatisfy { height($0.id) <= base($0.id) && height($0.id) >= (base($0.id) * LaneZoom.minScale).rounded() }
              && lanes().allSatisfy { header.laneViewport.contains(NSPoint(x: 50, y: header.rowRect($0.id).midY)) },
              "bottom \(Int(lanesBottom)) visible \(Int(clip.bounds.height)) scrollY \(clip.bounds.minY) fitScale \(zoom.fitScale) heights \(heights().map { Int($0) })")
        if let sp = L.lastSplit {
            let need = LaneZoom.neededHeight(lanes(), scale: zoom.fitScale)
            let minUpperShare: CGFloat = big.availH * (1 - EditorLayout.maxAutoTimelineFraction) - 1
            let paneInRange = sp.timeline <= big.maxPane + 1 && sp.timeline >= big.basePane - 1
            let upperKept = sp.upper >= EditorLayout.minUpper && sp.upper >= minUpperShare
            let lanesFit = c.visibleLaneHeight + 0.5 >= need
            let sumsUp = abs(sp.upper + sp.timeline - big.availH) < 1.5
            let chromeMeasured = abs(big.actualChrome - L.timelineChrome) < 1.5   // the layout sizes the pane from the real viewport
            check("autofit.large.splitAllocation", paneInRange && upperKept && lanesFit && sumsUp && chromeMeasured,
                  "upper \(Int(sp.upper)) timeline \(Int(sp.timeline)) need \(Int(need)) | \(big.text)")
        } else { check("autofit.large.splitAllocation", false, "no split") }
        let largeScale = zoom.fitScale

        // 3. Small window: the lanes cannot fit even at the minimum, so the split stays default and the lanes scroll.
        await setWindow(height: 640)
        let small = fitNumbers()
        await scrollY(.greatestFiniteMagnitude)
        let scrolled = clip.bounds.minY
        await scrollY(0)
        check("autofit.small.fallbackScrolls", !small.possible && zoom.autoFit && abs(zoom.fitScale - LaneZoom.minScale) < 0.0001
              && abs((L.lastSplit?.timeline ?? -1) - small.basePane) < 1.5 && tv.frame.height > clip.bounds.height + 1 && scrolled > 1
              && lanes().allSatisfy { height($0.id) == (base($0.id) * LaneZoom.minScale).rounded() },
              "scrolledTo \(scrolled) doc \(Int(tv.frame.height)) fitScale \(zoom.fitScale) heights \(heights().map { Int($0) }) | \(small.text)")

        // 4. Resizing before any manual zoom: the fit follows the viewport again.
        await setWindow(height: vf.height)
        check("autofit.resizeBeforeManual.refits", zoom.autoFit && allVisible() && abs(zoom.fitScale - largeScale) < 0.0001,
              "fitScale \(zoom.fitScale) large \(largeScale) bottom \(Int(lanesBottom)) visible \(Int(clip.bounds.height))")

        // 5. No selection: global zoom. 150% makes video 81 pt and audio 96 pt; one more step keeps the relative heights.
        s.select(nil); s.selectLane(nil)
        s.setVerticalZoom(1.5)
        await settleLayout()
        check("zoom.global.example150", s.verticalZoomTarget == .all && !zoom.autoFit
              && lanes().allSatisfy { height($0.id) == ($0.kind == .video ? 81 : 96) }, "heights \(heights().map { Int($0) })")
        s.verticalZoom(step: 1)
        await settleLayout()
        let stepped = 1.5 * LaneZoom.step
        check("zoom.global.keepsRelativeHeights", lanes().allSatisfy { height($0.id) == (base($0.id) * stepped).rounded() }
              && abs(height(v1) / height(a2) - base(v1) / base(a2)) < 0.02 && abs(zoom.globalScale - stepped) < 0.0001,
              "heights \(heights().map { Int($0) }) ratio \(height(v1) / height(a2)) base \(base(v1) / base(a2))")

        // 6. Resizing after manual zoom keeps the chosen heights.
        let manualHeights = heights()
        await setWindow(height: 640)
        let afterShrink = heights()
        await setWindow(height: vf.height)
        check("resize.afterManual.heightsKept", afterShrink == manualHeights && heights() == manualHeights && !zoom.autoFit,
              "before \(manualHeights.map { Int($0) }) small \(afterShrink.map { Int($0) }) large \(heights().map { Int($0) })")

        // 7. Selected lane only; other lanes keep their heights.
        s.setVerticalZoom(1)
        s.selectLane(a2)
        let laneTarget = s.verticalZoomTarget
        s.verticalZoom(step: 1)
        await settleLayout()
        check("zoom.selectedLaneOnly", laneTarget == .lane(a2) && height(a2) == 80 && allBase(except: [a2]), "heights \(heights().map { Int($0) })")

        // 8. Selected clip: its owning lane. A lane picked earlier does not stay the target, and A2 keeps its own height.
        s.selectLane(a3)
        s.select(vClip.id)
        let clipTarget = s.verticalZoomTarget
        s.verticalZoom(step: 1)
        await settleLayout()
        check("zoom.selectedClipOwningLane", clipTarget == .lane(v1) && s.selectedLane == nil && height(v1) == (54 * LaneZoom.step).rounded()
              && height(a2) == 80 && allBase(except: [a2, v1]), "target \(clipTarget) heights \(heights().map { Int($0) })")
        s.selectLane(a3)
        let afterLane = (s.selection == nil, s.verticalZoomTarget)
        s.select(nil); s.selectLane(nil)
        check("target.followsSelection", afterLane.0 && afterLane.1 == .lane(a3) && s.verticalZoomTarget == .all,
              "lane \(afterLane.1) cleared \(s.verticalZoomTarget)")

        // 9. Readable minimum and maximum for one lane; the other lanes are untouched.
        s.selectLane(a3)
        let othersBefore = lanes().filter { $0.id != a3 }.map { height($0.id) }
        for _ in 0..<20 { s.verticalZoom(step: -1) }
        let atMin = height(a3), moreOut = s.verticalZoom(step: -1)
        let waveformArea = atMin - TimelineNSView.waveformLabelStrip
        // The lane-height drawing path at the minimum (stereo waveform under the 20 pt label strip) renders.
        await settleLayout()
        let rendered = tv.bitmapImageRepForCachingDisplay(in: tv.visibleRect).map { rep -> Bool in tv.cacheDisplay(in: tv.visibleRect, to: rep); return rep.pixelsWide > 0 } ?? false
        for _ in 0..<20 { s.verticalZoom(step: 1) }
        let atMax = height(a3), moreIn = s.verticalZoom(step: 1)
        await settleLayout()
        check("zoom.limits", atMin == (64 * LaneZoom.minScale).rounded() && !moreOut && atMax == 64 * LaneZoom.maxScale && !moreIn
              && lanes().filter { $0.id != a3 }.map { height($0.id) } == othersBefore, "min \(atMin) max \(atMax) moreOut \(moreOut) moreIn \(moreIn)")
        check("waveform.readableAtMinimum", waveformArea >= 24 && rendered, "audio lane \(atMin) pt, waveform area \(waveformArea) pt, rendered \(rendered)")

        // 10. Header rows and lane content stay aligned at mixed heights, at the top and scrolled to the bottom.
        func aligned() -> (Bool, String) {
            var worst: CGFloat = 0, sameHeights = true
            for l in lanes() {
                guard let r = tv.laneRect(l.id) else { return (false, "no rect \(l.name)") }
                worst = max(worst, abs(header.rowRect(l.id).midY - tv.convert(NSPoint(x: 0, y: r.midY), to: header).y))
                if header.rowRect(l.id).height != r.height { sameHeights = false }
            }
            return (worst < 0.5 && sameHeights && header.verticalOffset == clip.bounds.minY, "worst \(worst) sameHeights \(sameHeights) offset \(header.verticalOffset)")
        }
        await scrollY(0)
        let alignedTop = aligned()
        await scrollY(.greatestFiniteMagnitude)
        let alignedBottom = aligned()
        check("align.headerAndContent", alignedTop.0 && alignedBottom.0 && tv.frame.height >= TimelineNSView.contentHeight(lanes()) - 0.5,
              "top \(alignedTop.1) | bottom \(alignedBottom.1) scrollY \(clip.bounds.minY)")

        // 11. The ruler is still fixed over the top strip while the zoomed lanes scroll.
        let rulerExpected: NSRect = { let r = c.convert(clip.frame, from: sv); return NSRect(x: r.minX, y: r.minY, width: r.width, height: min(rulerH, r.height)) }()
        let rulerMid = ruler.convert(NSPoint(x: ruler.bounds.midX, y: rulerH / 2), to: nil)
        let rulerHit = cv.hitTest(cv.superview?.convert(rulerMid, from: nil) ?? rulerMid)
        check("ruler.fixedAfterZoom", ruler.frame == rulerExpected && rulerHit === ruler && clip.bounds.minY > 0,
              "ruler \(ruler.frame) expected \(rulerExpected) scrollY \(clip.bounds.minY)")

        // 12. Hit-testing after zoom: the clip body in the taller V1 row, nothing in the gap below it, the header row.
        if let r = tv.laneRect(v1) {
            tv.scrollToVisible(NSRect(x: clip.bounds.minX, y: r.minY - 30, width: 10, height: r.height + 40))
            await LaneSelfTest.settle()
            let body = NSPoint(x: tv.x(vClip.start) + CGFloat(vClip.length) * tv.pixelsPerFrame / 2, y: r.maxY - 3)
            let gap = NSPoint(x: body.x, y: r.maxY + 4)
            let row = header.rowRect(v1)
            let rowPoint = NSPoint(x: 50, y: row.midY)
            check("hit.afterZoom", tv.clipHit(body)?.0 == vClip.id && tv.clipHit(gap) == nil && tv.lane(atY: r.midY)?.id == v1
                  && header.laneViewport.contains(rowPoint) && header.lane(at: rowPoint)?.id == v1 && r.height == (54 * LaneZoom.step).rounded(),
                  "V1 rect \(r) row \(row) viewport \(header.laneViewport)")
        } else { check("hit.afterZoom", false, "no V1 rect") }

        // 13. Shift playhead snap: the ▼/▲ markers sit on the zoomed clip rows' top and bottom edges at the snapped frame.
        s.setSnapEnabled(true)
        s.scrubPlayhead(raw: 119.4, snapFrames: 0.8, shift: true)
        let st = TimelineDrawState(store: s)
        let geo = tv.snapMarkerGeometry(st, frame: 120)
        var markersOK = !geo.isEmpty
        for g in geo {
            guard let r = tv.laneRect(g.marker.lane) else { markersOK = false; continue }
            if g.above.maxY != r.minY || g.below.minY != r.maxY || abs(g.above.midX - tv.x(120)) > 0.01 || abs(g.below.midX - tv.x(120)) > 0.01 { markersOK = false }
        }
        let snapped = s.playhead
        s.endScrub()
        check("snap.markersFollowZoom", markersOK && snapped == 120 && geo.count >= 2, "markers \(geo.count) playhead \(snapped)")

        // 14. Keyboard and controls give the same result from the same automatic state.
        s.select(nil); s.selectLane(nil)
        header.fitButton.performClick(nil); await settleLayout()
        header.syncZoomControls()
        header.zoomInButton.performClick(nil); await settleLayout()
        let clickIn = heights()
        header.syncZoomControls()
        header.zoomOutButton.performClick(nil); await settleLayout()
        let clickOut = heights()
        header.fitButton.performClick(nil); await settleLayout()
        let autoHeights = heights()
        await key(24, "=", optCmd)
        let keyIn = heights(), keyManual = !zoom.autoFit
        await key(27, "-", optCmd)
        let keyOut = heights()
        check("keys.sameAsControls", clickIn == keyIn && clickOut == keyOut && keyManual && clickIn != autoHeights && clickIn != clickOut,
              "auto \(autoHeights.map { Int($0) }) click+ \(clickIn.map { Int($0) }) key+ \(keyIn.map { Int($0) }) click− \(clickOut.map { Int($0) }) key− \(keyOut.map { Int($0) }) direct \(LaneSelfTest.direct)")

        // 15. Korean input source (non-Latin characters → key codes), "+" form, and no change to existing shortcuts.
        func cmd(_ code: UInt16, _ ch: String, _ m: NSEvent.ModifierFlags) -> KeyRouting.CommandAction? {
            KeyRouting.commandAction(keyCode: code, charactersIgnoringModifiers: ch, modifiers: m)
        }
        let shiftOptCmd: NSEvent.ModifierFlags = [.command, .option, .shift]
        let expected: [(UInt16, String, NSEvent.ModifierFlags, KeyRouting.CommandAction?)] = [
            (24, "=", optCmd, .verticalZoomIn), (27, "-", optCmd, .verticalZoomOut),          // Latin input source
            (24, "ㅂ", optCmd, .verticalZoomIn), (27, "ㅡ", optCmd, .verticalZoomOut),          // non-Latin characters: key codes
            (24, "+", shiftOptCmd, .verticalZoomIn), (69, "+", optCmd, .verticalZoomIn), (78, "-", optCmd, .verticalZoomOut),
            (24, "=", [.command], nil), (27, "-", [.command], nil), (24, "=", [.option], nil), (9, "v", optCmd, nil),
            (40, "k", [.command], .split), (9, "v", [.command], .paste), (6, "z", [.command], .undo),
        ]
        let wrong = expected.filter { cmd($0.0, $0.1, $0.2) != $0.3 }.map { "\($0.0):\($0.1)" }
        let toolV = KeyRouting.bareKeyAction(keyCode: 9, modifiers: [], isRepeat: false) == .selectionTool
        let toolC = KeyRouting.bareKeyAction(keyCode: 8, modifiers: [], isRepeat: false) == .cutTool
        let toolT = KeyRouting.bareKeyAction(keyCode: 17, modifiers: [], isRepeat: false) == .textTool
        let bareEquals = KeyRouting.bareKeyAction(keyCode: 24, modifiers: [], isRepeat: false) == nil
        check("keys.inputSourcesAndExistingShortcuts", wrong.isEmpty && toolV && toolC && toolT && bareEquals,
              "wrong \(wrong) V \(toolV) C \(toolC) T \(toolT) bare= \(bareEquals)")

        // 16. Text entry: with the lane-name field focused the shortcut does not zoom.
        await scrollY(0)
        let beforeText = heights()
        header.beginRename(v3)
        await LaneSelfTest.settle()
        let editing = KeyRouting.isTextInput(w.firstResponder)
        await key(24, "=", optCmd)
        let duringText = heights()
        header.finish(commit: false)
        await LaneSelfTest.settle()
        check("keys.textFieldFocusSafe", editing && duringText == beforeText && s.timeline.laneInfo(v3)?.name == "영상",
              "editing \(editing) before \(beforeText.map { Int($0) }) during \(duringText.map { Int($0) })")

        // 17. Fit All works with a lane selected and returns every lane to the automatic overview.
        s.selectLane(a2)
        s.verticalZoom(step: 1)
        header.fitButton.performClick(nil)
        await settleLayout()
        check("fitAll.restoresOverview", zoom.autoFit && zoom.laneFactor.isEmpty && s.selectedLane == a2 && allVisible()
              && abs(zoom.fitScale - largeScale) < 0.0001 && Set(lanes().map { height($0.id) / base($0.id) }.map { ($0 * 20).rounded() }).count == 1,
              "fitScale \(zoom.fitScale) heights \(heights().map { Int($0) }) bottom \(Int(lanesBottom)) visible \(Int(clip.bounds.height))")

        // 18. Zoom is presentation state only: timeline data, edit history and the dirty state did not change.
        check("timing.timelineUnchanged", s.timeline == t0 && s.history.undoDepth == depth0 && s.isDirty == dirty0 && s.timeline.durationFrames == 120
              && s.timeline.clip(vClip.id) == vClip, "undoDepth \(s.history.undoDepth) was \(depth0) dirty \(s.isDirty)")

        // 19. A new project returns to the automatic state (lane heights are not saved).
        s.select(nil); s.selectLane(nil)
        s.setVerticalZoom(2)
        let wasManual = !zoom.autoFit
        s.resetProject()
        await settleLayout()
        check("reset.newProjectReturnsToAuto", wasManual && zoom.autoFit && zoom.laneFactor.isEmpty && s.timeline.lanes == Lane.newProjectDefaults && allVisible(),
              "auto \(zoom.autoFit) heights \(heights().map { Int($0) })")

        w.setFrame(originalFrame, display: true)
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("lane-zoom-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
