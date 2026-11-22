#if DEBUG
import AppKit
import OnTheFrameEngine

/// TIMELINE-STICKY-RULER-01 자체 검사(Debug 전용, 일반 화면에 없음). `open -n -W -a OnTheFrame.app <폴더> --args -OTFLayoutSuite <이름> -OTFStickyRulerTest`.
/// 입력: <폴더>/sources/otf-TA.mp4(생성 fixture 사본). 결과: <폴더>/sticky-ruler-result.json. 진입 인수는 두 레인 fixture 목록에 없으므로
/// 실제 여섯 레인 새 프로젝트로 시작한다.
/// 시간 눈금자가 세로 스크롤(위·가운데·아래)과 무관하게 타임라인 보이는 영역 맨 위에 고정돼 있는지, 눈금자와 클립이 같은 가로 좌표식을 쓰는지
/// (가로 스크롤·확대), 눈금자 탐색과 Shift 붙기, 창 크기 바꾸기, 눈금자·레인 머리 경계를 본다.
/// 합성 호출(스크롤 위치 지정, 합성 마우스 이벤트, 그린 화면 비교)이며 실제 트랙패드 스크롤 확인이 아니다.
@MainActor
enum StickyRulerSelfTest {
    typealias Check = LaneSelfTest.Check

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") {
            checks.append(Check(name: n, pass: p, detail: d)); print(p ? "PASS" : "FAIL", "[ruler]", n, d); fflush(stdout)
        }
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow, let cv = w.contentView, let c = LaneSelfTest.find(TimelineContainerView.self, cv) else {
            check("setup.window", false); return finish(folder, checks)
        }
        w.makeKeyAndOrderFront(nil)
        if !(await LaneSelfTest.regainFocus(w)) { LaneSelfTest.direct = true }
        await LaneSelfTest.settle()
        let header = c.header, tv = c.timelineView, sv = c.scrollView, clip = sv.contentView, ruler = c.ruler
        let rulerH = TimelineNSView.rulerHeight

        // 0. Six-lane production start, one generated clip pair on V1/A1 [0,120).
        check("setup.sixLaneProductionStart", s.timeline.lanes == Lane.newProjectDefaults,
              s.timeline.lanes.map { s.timeline.laneLabel($0.id) }.joined(separator: " "))
        s.importFiles([folder.appendingPathComponent("sources").appendingPathComponent("otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(60) { s.importing == 0 && s.assets.count == 1 }
        guard let asset = s.assets.first else { check("setup.media", false, "no asset"); return finish(folder, checks) }
        s.addToTimeline(asset.id)
        _ = await LaneSelfTest.waitUntil(10) { s.canPlay }
        await LaneSelfTest.settle()
        let duration = s.timeline.durationFrames
        check("setup.media", duration == 120 && s.timeline.lanes.count == 6, "duration \(duration) lanes \(s.timeline.lanes.count)")
        guard duration == 120 else { return finish(folder, checks) }

        // A small window plus extra empty lanes guarantees a vertical scroll range.
        let originalFrame = w.frame
        w.setFrame(NSRect(x: originalFrame.minX, y: originalFrame.maxY - 640, width: max(900, originalFrame.width), height: 640), display: true)
        await LaneSelfTest.settle()
        var added = 0
        while tv.frame.height <= clip.bounds.height + 200 && added < 8 { s.addLane(.audio); added += 1; await LaneSelfTest.settle() }
        // Horizontal scroll range (STICKY-RULER-TEST-FIX-01): the first run failed because one 120-frame clip at 10 pt per frame
        // (document 24 + 1200 + 200 = 1424 pt) fitted inside a 1680 pt viewport. The timeline is now made long enough for the
        // actual viewport: the same generated clip is appended (the + button path, end to end on V1/A1) until the document at
        // 10 pt per frame is at least 400 pt wider than the visible width. Clip boundaries stay at multiples of 120 frames.
        let ppf: CGFloat = 10, clipFrames: CGFloat = 120, wantedRange: CGFloat = 400
        let fixedWidth = TimelineNSView.inset * 2 + 200   // document width = inset * 2 + duration * ppf + 200 (TimelineRepresentable)
        let visibleWidth = clip.bounds.width
        let clipCount = min(24, max(1, Int(((visibleWidth + wantedRange - fixedWidth) / (clipFrames * ppf)).rounded(.up))))
        for _ in 1..<max(1, clipCount) { s.addToTimeline(asset.id); await LaneSelfTest.settle() }
        _ = await LaneSelfTest.waitUntil(10) { s.timeline.durationFrames == 120 * clipCount && s.canPlay }
        s.timelineZoom = Double(ppf)
        _ = await LaneSelfTest.waitUntil(5) { tv.pixelsPerFrame == ppf }
        await LaneSelfTest.settle()
        var maxY: CGFloat { max(0, tv.frame.height - clip.bounds.height) }
        var maxX: CGFloat { max(0, tv.frame.width - clip.bounds.width) }
        check("setup.scrollRanges", maxY > 150 && maxX > 100 && tv.pixelsPerFrame == 10,
              "doc \(Int(tv.frame.width))x\(Int(tv.frame.height)) visible \(Int(clip.bounds.width))x\(Int(clip.bounds.height)) added \(added) ppf \(tv.pixelsPerFrame)"
              + " clips \(clipCount) duration \(s.timeline.durationFrames) expectedDoc \(Int(fixedWidth + clipFrames * ppf * CGFloat(clipCount))) maxX \(Int(maxX))")

        func scroll(x: CGFloat? = nil, y: CGFloat? = nil) async {
            let nx = min(max(0, x ?? clip.bounds.minX), maxX), ny = min(max(0, y ?? clip.bounds.minY), maxY)
            clip.scroll(to: NSPoint(x: nx, y: ny))
            sv.reflectScrolledClipView(clip)
            await LaneSelfTest.settle()
        }
        /// The strip the ruler must occupy: the top `rulerHeight` of the clip view, in container coordinates.
        func expectedFrame() -> NSRect {
            let r = c.convert(clip.frame, from: sv)
            return NSRect(x: r.minX, y: r.minY, width: r.width, height: min(rulerH, r.height))
        }
        func windowRect() -> NSRect { ruler.convert(ruler.bounds, to: nil) }
        func hit(_ windowPoint: NSPoint) -> NSView? { cv.hitTest(cv.superview?.convert(windowPoint, from: nil) ?? windowPoint) }
        func rulerPoint(_ frame: Int, dx: CGFloat = 0.3) -> NSPoint { ruler.convert(NSPoint(x: ruler.viewX(frame) + dx, y: rulerH / 2), to: nil) }
        /// A frame at a fraction of the visible width (never past frame 110), so its ruler point is inside the ruler.
        func visibleFrame(_ fraction: CGFloat) -> Int { min(110, max(0, tv.frame(atX: clip.bounds.minX + clip.bounds.width * fraction))) }
        /// Ruler x and lane-content x of the same frames are the same window x (one mapping), and the ruler uses the clip's scroll origin.
        func mapping() -> (Bool, String) {
            var worst: CGFloat = 0
            for f in [0, 30, 60, 90, 120] {
                let rx = ruler.convert(NSPoint(x: ruler.viewX(f), y: 0), to: nil).x
                let tx = tv.convert(NSPoint(x: tv.x(f), y: clip.bounds.minY), to: nil).x
                worst = max(worst, abs(rx - tx))
            }
            return (worst < 0.5 && ruler.contentOffsetX == clip.bounds.minX, "worst \(worst) rulerOffset \(ruler.contentOffsetX) clipX \(clip.bounds.minX)")
        }
        /// Fixed at the top strip, fully visible, and the topmost view over that strip.
        func fixed(_ reference: NSRect) -> (Bool, String) {
            let f = ruler.frame, wr = windowRect()
            let mid = ruler.convert(NSPoint(x: ruler.bounds.midX, y: rulerH / 2), to: nil)
            let top = hit(mid)
            let ok = ruler.superview === c && f == expectedFrame() && f.height == rulerH && wr == reference && !ruler.isHidden
                && ruler.visibleRect == ruler.bounds && top === ruler
            return (ok, "frame \(f) window \(wr) hit \(String(describing: top.map { type(of: $0) })) scrollY \(clip.bounds.minY)")
        }
        func scrubClick(_ frame: Int, mods: NSEvent.ModifierFlags = [], dx: CGFloat = 0.3) async {
            let p = rulerPoint(frame, dx: dx)
            await LaneSelfTest.mouse(.leftMouseDown, p, w, mods: mods)
            await LaneSelfTest.mouse(.leftMouseUp, p, w, mods: mods)
        }

        // 1. Layout and boundaries at the top.
        await scroll(x: 0, y: 0)
        let reference = windowRect()
        let headerViewportTop = c.convert(NSPoint(x: 0, y: header.laneViewport.minY), from: header).y
        check("layout.topStripOfLaneArea", ruler.frame == expectedFrame() && ruler.frame.height == rulerH && ruler.clipsToBounds && ruler.isOpaque,
              "ruler \(ruler.frame) expected \(expectedFrame())")
        check("layout.boundaries", ruler.frame.minX >= header.frame.maxX && ruler.frame.maxY == headerViewportTop && ruler.frame.maxX <= c.bounds.maxX,
              "ruler \(ruler.frame) header \(header.frame) headerViewportTop \(headerViewportTop)")

        // 2. Vertical scrolling: top, middle, bottom. The ruler does not move; the mapping holds.
        var r = fixed(reference); var m = mapping()
        check("vscroll.top.rulerFixed", r.0 && m.0, r.1 + " | " + m.1)
        await scroll(y: maxY / 2)
        r = fixed(reference); m = mapping()
        check("vscroll.middle.rulerFixed", r.0 && m.0, r.1 + " | " + m.1)
        await scroll(y: maxY)
        r = fixed(reference); m = mapping()
        check("vscroll.bottom.rulerFixed", r.0 && m.0 && clip.bounds.minY == maxY && maxY > 0, r.1 + " | " + m.1)

        // 3. Scrolled to the bottom: lane rows lie under the ruler strip, but a press there scrubs and selects nothing.
        s.select(nil); s.selectLane(nil)
        let fA = visibleFrame(0.3), fB = visibleFrame(0.6)
        let pA = rulerPoint(fA), pB = rulerPoint(fB)
        let docYUnderRuler = tv.convert(pA, from: nil).y
        await LaneSelfTest.mouse(.leftMouseDown, pA, w)
        let atA = s.playhead
        let scrubbing = tv.dragNameForTest == "scrub"
        await LaneSelfTest.mouse(.leftMouseDragged, pB, w)
        let atB = s.playhead
        await LaneSelfTest.mouse(.leftMouseUp, pB, w)
        check("scrub.bottomScroll.pressAndDrag", fA != fB && atA == fA && atB == fB && scrubbing && tv.dragNameForTest == "none",
              "frames \(fA)→\(fB) playhead \(atA)→\(atB) scrub \(scrubbing) after \(tv.dragNameForTest)")
        check("hit.rowsUnderRulerNotReached", docYUnderRuler > TimelineNSView.firstLaneY && hit(pA) === ruler && s.selection == nil && s.selectedLane == nil,
              "docY \(docYUnderRuler) hit \(String(describing: hit(pA).map { type(of: $0) })) selection \(String(describing: s.selection))")
        let belowRuler = ruler.convert(NSPoint(x: ruler.bounds.midX, y: rulerH + 10), to: nil)
        let headerStrip = header.convert(NSPoint(x: 50, y: rulerH / 2), to: nil)
        check("hit.outsideRulerNotRuler", hit(belowRuler) === tv && hit(headerStrip) !== ruler,
              "below \(String(describing: hit(belowRuler).map { type(of: $0) })) headerStrip \(String(describing: hit(headerStrip).map { type(of: $0) }))")

        // 4. The playhead triangle is drawn in the fixed ruler (the document's own triangle has scrolled away).
        func redAtPlayhead() -> (Bool, String) {
            guard let rep = ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds) else { return (false, "no bitmap") }
            ruler.cacheDisplay(in: ruler.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / max(1, ruler.bounds.width)
            let px = Int((ruler.viewX(s.playhead) * scale).rounded()), py = Int((2 * scale).rounded())
            guard px >= 0, px < rep.pixelsWide, py >= 0, py < rep.pixelsHigh, let col = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { return (false, "pixel \(px),\(py) unavailable") }
            return (col.redComponent > 0.6 && col.greenComponent < 0.5 && col.blueComponent < 0.5,
                    String(format: "pixel %d,%d rgb %.2f %.2f %.2f", px, py, col.redComponent, col.greenComponent, col.blueComponent))
        }
        let red = redAtPlayhead()
        check("draw.playheadInFixedRuler", red.0 && s.playhead == fB, red.1)

        // 5. Horizontal scrolling (still at the bottom): ticks follow the content; scrub and Shift snapping use the same mapping.
        s.setSnapEnabled(true)
        // Really scroll the clip view: frame 120 (the first clip boundary) near the middle, and never less than 120 pt on very wide viewports.
        await scroll(x: max(120, tv.x(120) - clip.bounds.width / 2))
        m = mapping(); r = fixed(reference)
        let fH = visibleFrame(0.4)
        await scrubClick(fH)
        check("hscroll.mappingAndScrub", clip.bounds.minX > 100 && m.0 && r.0 && s.playhead == fH, "\(m.1) frame \(fH) playhead \(s.playhead) | \(r.1)")
        // 6 pt left of the clip end (frame 120) at 10 pt per frame: plain scrub rounds to 119, Shift (magnet on, 8 pt) snaps to 120.
        await scrubClick(120, dx: -6)
        let plain = s.playhead
        let pSnap = rulerPoint(120, dx: -6)
        await LaneSelfTest.mouse(.leftMouseDown, pSnap, w, mods: .shift)
        let snapped = s.playhead, guide = s.snapGuide
        await LaneSelfTest.mouse(.leftMouseUp, pSnap, w, mods: .shift)
        check("scrub.shiftSnapsToClipEnd", plain == 119 && snapped == 120 && guide == 120 && s.snapGuide == nil,
              "plain \(plain) shift \(snapped) guide \(String(describing: guide)) after \(String(describing: s.snapGuide))")

        // 6. Zoom: the ruler follows the new pixels-per-frame.
        s.timelineZoom = 4
        _ = await LaneSelfTest.waitUntil(5) { tv.pixelsPerFrame == 4 }
        await LaneSelfTest.settle()
        m = mapping(); r = fixed(reference)
        let fZ = visibleFrame(0.5)
        await scrubClick(fZ)
        check("zoom.mappingAndScrub", tv.pixelsPerFrame == 4 && m.0 && r.0 && s.playhead == fZ, "\(m.1) ppf \(tv.pixelsPerFrame) frame \(fZ) playhead \(s.playhead)")

        // 7. Same picture as the document's own ruler strip (vertical scroll 0, where that strip is under the fixed ruler).
        s.timelineZoom = 10
        _ = await LaneSelfTest.waitUntil(5) { tv.pixelsPerFrame == 10 }
        await scroll(x: 200, y: 0)
        func bitmap(_ v: NSView, _ rect: NSRect) -> NSBitmapImageRep? {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            v.cacheDisplay(in: rect, to: rep)
            return rep
        }
        let docStrip = NSRect(x: clip.bounds.minX, y: 0, width: ruler.bounds.width, height: rulerH)
        if let a = bitmap(ruler, ruler.bounds), let b = bitmap(tv, docStrip), a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
           let pa = a.bitmapData, let pb = b.bitmapData, a.bytesPerRow == b.bytesPerRow, a.samplesPerPixel == b.samplesPerPixel {
            let spp = a.samplesPerPixel
            var differing = 0
            for y in 0..<a.pixelsHigh {
                for x in 0..<a.pixelsWide {
                    let o = y * a.bytesPerRow + x * spp
                    var d = 0
                    for k in 0..<min(3, spp) { d = max(d, abs(Int(pa[o + k]) - Int(pb[o + k]))) }
                    if d > 16 { differing += 1 }
                }
            }
            let total = a.pixelsWide * a.pixelsHigh
            check("draw.sameAsDocumentRuler", differing * 200 <= total, "differing \(differing) of \(total) pixels (limit 0.5%) scrollX \(clip.bounds.minX)")
        } else {
            check("draw.sameAsDocumentRuler", false, "bitmaps unavailable or different sizes")
        }

        // 8. Window resizing while scrolled to the bottom: the ruler stays the top strip and follows the width.
        await scroll(y: maxY)
        let small = w.frame
        w.setFrame(NSRect(x: small.minX, y: small.minY - 160, width: small.width + 120, height: small.height + 160), display: true)
        await LaneSelfTest.settle()
        m = mapping()
        let bigOK = ruler.frame == expectedFrame() && ruler.frame.height == rulerH && hit(ruler.convert(NSPoint(x: ruler.bounds.midX, y: rulerH / 2), to: nil)) === ruler
        check("resize.larger.rulerFollowsViewport", bigOK && m.0, "ruler \(ruler.frame) expected \(expectedFrame()) | \(m.1)")
        w.setFrame(small, display: true)
        await LaneSelfTest.settle()
        m = mapping(); r = fixed(reference)
        check("resize.restored.rulerFollowsViewport", r.0 && m.0, r.1 + " | " + m.1)

        // 9. Lane headers still line up with the lane rows below the fixed ruler.
        var worst: CGFloat = 0
        for l in s.timeline.lanes {
            guard let lr = tv.laneRect(l.id) else { continue }
            worst = max(worst, abs(header.rowRect(l.id).midY - tv.convert(NSPoint(x: 0, y: lr.midY), to: header).y))
        }
        check("header.rowsStillAligned", worst < 0.5 && header.verticalOffset == clip.bounds.minY, "worst \(worst) offset \(header.verticalOffset)")

        w.setFrame(originalFrame, display: true)
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("sticky-ruler-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
