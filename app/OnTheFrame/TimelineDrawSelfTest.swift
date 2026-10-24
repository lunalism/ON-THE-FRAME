#if DEBUG
import AppKit
import OnTheFrameEngine

/// 타임라인 그리기 범위 자체 검사(Debug 전용, 2026-10-23). `open -g -n -W -a OnTheFrame.app <폴더> --args -OTFTimelineDrawTest`.
/// 보이는 영역만 그리는 그림이 이전처럼 전체를 돌며 그린 그림과 보이는 영역에서 화소까지 같은지 본다:
/// 여러 확대·스크롤 위치(클립·자막·빈틈이 왼쪽·오른쪽 가장자리에 걸침, 끝), 창 크기 바꿈, 고르기·자르기 도구,
/// 빈틈 빗금·자막(빈 자막 포함)·두 영상 레인·소리 선·페이드·음소거 레인. 입력 이벤트·초점을 쓰지 않는다. 결과는 <폴더>/timeline-draw-result.json.
@MainActor
enum TimelineDrawSelfTest {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)) }
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { check("setup.window", false); return finish(folder, checks) }
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 1 }
        guard let mid = s.assets.first?.id else { check("setup.import", false); return finish(folder, checks) }
        // 타임라인: 연결된 쌍 40개(몇 개는 들어내 빈틈), 위 영상 레인에 몇 개, 자막 30개(빈 자막 하나), 소리 음량·페이드, 위 오디오 레인 음소거
        var selectID: UUID?
        s.commit({ t0 in
            var t = t0
            let v = t.lanes(.video).first!.id, a = t.lanes(.audio).first!.id
            for _ in 0..<40 { t = try t.appending(media: mid, videoLane: v, audioLane: a) }
            let vc = t.clips(inLane: v)
            for k in stride(from: 3, to: 40, by: 7) { t = try t.lifting(clip: vc[k].id) }   // 들어내면 목록이 줄므로 ID를 먼저 모은다
            let v2 = UUID(), a2 = UUID()
            t = try t.addingLane(.video, name: "V2", id: v2, outward: true).addingLane(.audio, name: "A2", id: a2, outward: true)
            for _ in 0..<3 { t = try t.appending(media: mid, videoLane: v2, audioLane: a2) }   // 위 영상 레인(겹친 영상) + 그 소리
            t = try t.addingSubtitleCreatingLane(at: 0, text: "첫 자막", style: .default, id: UUID(), newLaneName: "자막")
            let sl = t.lanes(.subtitle).first!.id
            for k in 1..<30 { t = try t.addingSubtitle(lane: sl, at: k * 150, length: 90, text: k == 5 ? "" : "자막 \(k)\n둘째 줄", style: .default, id: UUID()) }
            let ac = t.clips(inLane: a)
            t = try t.settingClipAudio(clip: ac[1].id, volumePercent: 60, fadeInFrames: 20, fadeOutFrames: 30)
            t = try t.settingLaneAudio(a2, muted: true)
            selectID = t.clips(inLane: v)[12].id
            return t
        }, focus: nil)
        if let id = selectID { s.select(id) }
        _ = await LaneSelfTest.waitUntil(30) { s.appliedGeneration == s.generation }
        await LaneSelfTest.settle()
        guard let tv = LaneSelfTest.find(TimelineNSView.self, w.contentView) else { check("setup.view", false); return finish(folder, checks) }
        guard s.timeline.isValid, s.timeline.clips.count > 30, s.timeline.subtitles.count == 30 else {
            check("setup.timeline", false, "clips \(s.timeline.clips.count) subs \(s.timeline.subtitles.count) status \(s.statusMessage ?? "")"); return finish(folder, checks)
        }

        func render() -> Data? {
            let vr = tv.visibleRect
            guard !vr.isEmpty, let rep = tv.bitmapImageRepForCachingDisplay(in: vr) else { return nil }
            tv.cacheDisplay(in: vr, to: rep)
            return rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) }
        }
        func compare(_ name: String) {
            let culled = render()
            tv.fullDrawForTest = true
            let full = render()
            tv.fullDrawForTest = false
            let differ = zip(culled ?? Data(), full ?? Data()).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
            check("draw.\(name)", culled != nil && culled == full, "visible \(Int(tv.visibleRect.minX))…\(Int(tv.visibleRect.maxX)) bytes \(culled?.count ?? -1) differ \(differ)")
        }
        func scroll(toX x: CGFloat) async {
            tv.scroll(NSPoint(x: max(0, x), y: tv.visibleRect.minY))
            await LaneSelfTest.settle()
        }
        for tool in [ProjectStore.EditTool.selection, .cut] {
            s.setTool(tool)
            for zoom in [2.0, 0.6, 9.0] {
                s.timelineZoom = zoom
                await LaneSelfTest.settle()
                let vw = tv.visibleRect.width
                let clips = s.timeline.clips.sorted { $0.start < $1.start }, subs = s.timeline.subtitles
                let gaps = s.timeline.gaps(inLane: s.timeline.baseLane(.video)!.id)
                var spots: [(String, CGFloat)] = [("start", 0), ("middle", tv.bounds.width / 2 - vw / 2), ("end", tv.bounds.width)]
                if clips.count > 14 {
                    spots.append(("clipLeftEdge", tv.x(clips[14].start) + 10))             // 클립이 왼쪽 가장자리에 걸침
                    spots.append(("clipRightEdge", tv.x(clips[14].end) - vw + 10))         // 클립 끝이 오른쪽 가장자리 밖
                }
                if subs.count > 10 { spots.append(("subtitleLeftEdge", tv.x(subs[10].start) + 5)) }
                if let g = gaps.first { spots.append(("gapLeftEdge", tv.x(g.lowerBound) + 20)); spots.append(("gapRightEdge", tv.x(g.upperBound) - vw + 3)) }
                spots.append(("overscanBoundary", tv.x(clips[min(20, clips.count - 1)].end) + TimelineNSView.drawOverscan - 1))
                for (name, x) in spots {
                    await scroll(toX: x)
                    compare("\(tool).zoom\(zoom).\(name)")
                }
            }
        }
        s.setTool(.selection); s.timelineZoom = 2; await LaneSelfTest.settle()
        // 창 크기 바꿈 뒤(보이는 영역 폭이 바뀜)
        let size0 = w.frame.size
        w.setContentSize(NSSize(width: 1100, height: 700)); await LaneSelfTest.settle()
        await scroll(toX: tv.x(s.timeline.clips.sorted { $0.start < $1.start }[10].start) + 7)
        compare("resized.narrow")
        w.setContentSize(NSSize(width: 1600, height: 900)); await LaneSelfTest.settle()
        compare("resized.wide")
        w.setFrame(NSRect(origin: w.frame.origin, size: size0), display: true)
        // 재생 헤드가 보이는 영역 안: 그림 같음(재생 헤드는 줄이지 않고 그대로 그림)
        s.seek(to: tv.frame(atX: tv.visibleRect.midX)); await LaneSelfTest.settle()
        compare("playheadVisible")

        // 가로 확대 기준(2026-10-24, 소유자 요청): 슬라이더와 같은 값(store.timelineZoom)을 바꾼다. 재생 헤드가 보이면 그 시각을 보이는 영역의 같은 자리에,
        // 밖이면 보이는 영역 가운데 시각을 가운데에 둔다. 처음·끝에서는 스크롤 범위 안. 재생 헤드·클립·선택·재생 상태·레인 높이는 그대로.
        s.timelineZoom = 2; await LaneSelfTest.settle()
        let t0 = s.timeline, sel0 = s.selection, h0 = tv.bounds.height
        func zoom(_ z: Double) async { s.timelineZoom = z; await LaneSelfTest.settle() }
        func scroll(originX x: CGFloat) async { tv.scroll(NSPoint(x: max(0, x), y: tv.visibleRect.minY)); await LaneSelfTest.settle() }
        func phX() -> CGFloat { tv.x(s.playhead) - tv.visibleRect.minX }
        func maxOrigin() -> CGFloat { max(0, tv.bounds.width - tv.visibleRect.width) }
        let zMid = s.timeline.durationFrames / 2
        for (name, frac) in [("left", 0.1), ("middle", 0.5), ("right", 0.9)] {
            await zoom(2); s.seek(to: zMid); await LaneSelfTest.settle()
            let want = CGFloat(frac) * tv.visibleRect.width
            await scroll(originX: tv.x(zMid) - want)
            let start = phX()
            var worst: CGFloat = 0, log: [String] = []
            for z in [4.0, 9.0, 12.0, 1.0, 0.5, 2.0] {
                await zoom(z)
                let clamped = tv.visibleRect.minX <= 0.5 || tv.visibleRect.minX >= maxOrigin() - 0.5
                if !clamped { worst = max(worst, abs(phX() - start)) }
                log.append("\(z):\(Int(phX()))\(clamped ? "c" : "")")
            }
            check("zoom.playhead.\(name)", worst <= 1 && s.playhead == zMid, "start \(Int(start)) worst \(worst) \(log.joined(separator: " "))")
        }
        // 처음: 재생 헤드 0 → 스크롤 0 그대로(왼쪽 끝 맞춤)
        await zoom(2); s.seek(to: 0); await scroll(originX: 0)
        var startOK = true
        for z in [6.0, 0.4, 12.0, 2.0] { await zoom(z); startOK = startOK && tv.visibleRect.minX < 0.5 && abs(phX() - TimelineNSView.inset) < 0.5 }
        check("zoom.boundary.start", startOK && s.playhead == 0, "origin \(tv.visibleRect.minX) phX \(phX())")
        // 끝: 끝 근처 재생 헤드, 스크롤 끝 → 확대해도 그 자리, 크게 줄이면 스크롤 범위 안(끝)으로 맞춤, 재생 헤드는 보임
        let end = s.timeline.durationFrames - 3
        await zoom(2); s.seek(to: end); await scroll(originX: maxOrigin())
        let endStart = phX()
        await zoom(5)
        let endIn = abs(phX() - endStart) <= 1 || tv.visibleRect.minX >= maxOrigin() - 0.5
        await zoom(0.2)
        let endOut = tv.visibleRect.minX <= maxOrigin() + 0.5 && tv.visibleRect.minX >= -0.5 && phX() >= 0 && phX() <= tv.visibleRect.width
        check("zoom.boundary.end", endIn && endOut && s.playhead == end, "in \(endIn) out \(endOut) origin \(Int(tv.visibleRect.minX)) max \(Int(maxOrigin())) phX \(Int(phX()))")
        // 손으로 스크롤해 재생 헤드가 밖: 보이는 영역 가운데 시각이 가운데에 남고 재생 헤드로 뛰지 않음
        await zoom(2); s.seek(to: zMid); await LaneSelfTest.settle()
        await scroll(originX: tv.x(zMid) + 2500)   // 재생 헤드는 왼쪽 밖
        let cFrame = Double((tv.visibleRect.midX - TimelineNSView.inset) / tv.pixelsPerFrame)
        var offOK = true, offLog: [String] = []
        for z in [4.0, 1.0, 8.0] {
            await zoom(z)
            let c = Double((tv.visibleRect.midX - TimelineNSView.inset) / tv.pixelsPerFrame)
            let phVisible = phX() >= 0 && phX() <= tv.visibleRect.width
            let clamped = tv.visibleRect.minX <= 0.5 || tv.visibleRect.minX >= maxOrigin() - 0.5
            offOK = offOK && (clamped || abs(c - cFrame) * Double(tv.pixelsPerFrame) <= 1) && !phVisible
            offLog.append("\(z):c\(String(format: "%.1f", c)) ph\(phVisible ? "visible" : "off")")
        }
        check("zoom.offscreenKeepsCenter", offOK, "center0 \(String(format: "%.1f", cFrame)) \(offLog.joined(separator: " "))")
        // 슬라이더를 이어서 많이 움직인 뒤 처음 배율로: 흔들림(밀림) 없음
        await zoom(2); s.seek(to: zMid); await LaneSelfTest.settle()
        await scroll(originX: tv.x(zMid) - 0.37 * tv.visibleRect.width)
        let o0 = tv.visibleRect.minX, p0 = phX()
        var x: UInt64 = 0x2545F4914F6CDD1D
        for _ in 0..<60 { x ^= x << 13; x ^= x >> 7; x ^= x << 17; s.timelineZoom = 0.6 + Double(x % 1000) / 1000 * 11; await LaneSelfTest.settle() }
        await zoom(2)
        check("zoom.repeatedNoDrift", abs(tv.visibleRect.minX - o0) <= 1 && abs(phX() - p0) <= 1, "origin \(o0) → \(tv.visibleRect.minX), phX \(p0) → \(phX())")
        // Codex 검토: 밖에서 확대 → (스크롤 없이) 보이는 곳을 눌러 재생 헤드를 옮김 → 다시 확대: 이제 보이는 재생 헤드가 그 자리에 남는다
        await zoom(2); s.seek(to: zMid); await LaneSelfTest.settle()
        await scroll(originX: tv.x(zMid) + 2500)
        await zoom(3)                                           // 가운데 기준(재생 헤드 밖)
        let clickF = tv.frame(atX: tv.visibleRect.minX + tv.visibleRect.width * 0.2)
        s.seek(to: clickF); await LaneSelfTest.settle()         // 보이는 곳(가운데 아님)으로 재생 헤드
        let beforeX = phX()
        await zoom(6)
        check("zoom.offscreenThenVisiblePlayhead", abs(phX() - beforeX) <= 1 && s.playhead == clickF, "phX \(beforeX) → \(phX())")
        // 확대 사이에 창 크기를 바꿈: 새 보이는 폭에서 재생 헤드 자리를 지킨다(예전 기준을 다시 쓰지 않음)
        if let w = s.editorWindow {
            let size0 = w.frame.size
            await zoom(2); s.seek(to: zMid); await LaneSelfTest.settle()
            await scroll(originX: tv.x(zMid) - 0.6 * tv.visibleRect.width)
            await zoom(4)
            w.setContentSize(NSSize(width: size0.width - 260, height: size0.height)); await LaneSelfTest.settle()
            let bx = phX(), inView = bx >= 0 && bx <= tv.visibleRect.width
            await zoom(8)
            check("zoom.afterWindowResize", inView && abs(phX() - bx) <= 1, "phX \(bx) → \(phX()) width \(Int(tv.visibleRect.width))")
            w.setFrame(NSRect(origin: w.frame.origin, size: size0), display: true); await LaneSelfTest.settle()
        }
        // 바뀌지 않는 것, 그리고 보이는 영역만 그린 그림 = 전체 그림(확대·스크롤 뒤)
        check("zoom.invariants", s.timeline == t0 && s.selection == sel0 && !s.isPlaying && tv.bounds.height == h0, "")
        await zoom(7); compare("afterZoom.in")
        await zoom(0.5); compare("afterZoom.out")
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        if let d = try? JSONEncoder().encode(checks) { try? d.write(to: folder.appendingPathComponent("timeline-draw-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
