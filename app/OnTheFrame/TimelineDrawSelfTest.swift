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
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        if let d = try? JSONEncoder().encode(checks) { try? d.write(to: folder.appendingPathComponent("timeline-draw-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
