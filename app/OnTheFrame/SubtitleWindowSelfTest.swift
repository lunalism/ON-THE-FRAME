#if DEBUG
import AppKit
import OnTheFrameEngine

/// 자막 그림 시간 창 자체 검사(Debug 전용, 2026-10-23, docs/SUBTITLE-DESIGN.md §49). `open -g -n -W -a OnTheFrame.app <폴더> --args -OTFSubtitleWindowTest`.
/// 프리뷰 자막 층(동기 층 안 캔버스)의 표시 상태 트리(presentation)를 1920×1080 그림으로 그려(render(in:)) 그 프레임에 보여야 할 자막을
/// SubtitleRenderer 그림으로 직접 겹쳐 그린 기대 그림과 화소로 비교한다. 화면 캡처가 아니다(화면 기록 권한 없음): CA가 합성할 층 트리의 그림이다.
/// 경우: 처음·차례 재생 뒤·먼 탐색·되감기·자막 경계 프레임 한 칸씩·창보다 긴 자막 한가운데·처음으로 다시·겹친 자막·효과,
/// 미리 그리는 중 글 고치기(늦은 결과 거름), 모양 조정 미리 보기(창이 덮어쓰지 않음), 그림을 가진 층 수 상한, 프로젝트 바꿈.
/// 입력 이벤트·초점을 쓰지 않는다. 결과는 <폴더>/subtitle-window-result.json.
@MainActor
enum SubtitleWindowSelfTest {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)) }
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        s.importFiles([folder.appendingPathComponent("sources/otf-TA.mp4")])
        _ = await LaneSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 1 }
        guard let mid = s.assets.first?.id else { return finish(folder, [Check(name: "setup.import", pass: false, detail: "")]) }
        // 자막 150개(S1: 45프레임 간격·길이 40, 5개마다 효과), S2: 10개마다 두 자막에 걸친 겹친 자막, S3: 창(약 11초)보다 긴 자막 하나(1200프레임)
        let count = 150, spacing = 45
        var longID = UUID(), editID = UUID()
        s.commit({ t0 in
            var t = t0
            let v = t.lanes(.video).first!.id, a = t.lanes(.audio).first!.id
            for _ in 0..<((count * spacing) / 120 + 2) { t = try t.appending(media: mid, videoLane: v, audioLane: a) }
            let s1 = UUID(); t = try t.addingLane(.subtitle, name: "S1", id: s1, outward: true)
            var fx = SubtitleStyle.default; fx.outline = .default; fx.shadow = .default; fx.background = .default
            for k in 0..<count {
                let id = UUID(); if k == 120 { editID = id }
                t = try t.addingSubtitle(lane: s1, at: k * spacing, length: 40, text: "자막 \(k)번 문장입니다\n둘째 줄 \(k)", style: k % 5 == 0 ? fx : .default, id: id)
            }
            let s2 = UUID(); t = try t.addingLane(.subtitle, name: "S2", id: s2, outward: true)
            var top = SubtitleStyle.default; top.yMilli = 200_000; top.background = .default
            for k in stride(from: 0, to: count, by: 10) { t = try t.addingSubtitle(lane: s2, at: k * spacing + 20, length: 80, text: "겹침 \(k)", style: top, id: UUID()) }
            let s3 = UUID(); t = try t.addingLane(.subtitle, name: "S3", id: s3, outward: true)
            var mid3 = SubtitleStyle.default; mid3.yMilli = 540_000; mid3.outline = .default
            longID = UUID(); t = try t.addingSubtitle(lane: s3, at: 2000, length: 1200, text: "창보다 긴 자막", style: mid3, id: longID)
            return t
        }, focus: nil)
        _ = await LaneSelfTest.waitUntil(60) { s.appliedGeneration == s.generation }
        await LaneSelfTest.settle()
        guard let host = s.previewHost, s.timeline.subtitles.count == count + count / 10 + 1 else {
            return finish(folder, [Check(name: "setup.timeline", pass: false, detail: "subs \(s.timeline.subtitles.count) status \(s.statusMessage ?? "")")])
        }
        _ = await LaneSelfTest.waitUntil(10) { host.subtitleBoundItem != nil }
        // 타임라인 끝에서 끝나는 자막(S3 레인, 마지막 30프레임)
        let finalID = UUID()
        let dur0 = s.timeline.durationFrames
        if let s3 = s.timeline.subtitle(longID)?.lane {
            s.commit({ try $0.addingSubtitle(lane: s3, at: dur0 - 30, length: 30, text: "마지막 자막", style: .default, id: finalID) }, focus: nil)
            _ = await LaneSelfTest.waitUntil(30) { s.appliedGeneration == s.generation }
            await LaneSelfTest.settle()
            _ = await LaneSelfTest.waitUntil(10) { host.subtitleBoundItem != nil }
        }

        /// 표시 상태 트리 그림(캔버스 좌표 = 출력 1920×1080, 아래 왼쪽 원점)
        func presented() -> [UInt8]? {
            guard let canvas = host.subtitleCanvas.presentation() else { return nil }
            let ctx = bitmap()
            canvas.render(in: ctx)
            return bytes(ctx)
        }
        /// 기대 그림: 그 프레임에 보이는 자막을 그리기 순서(프리뷰 층 순서 = renderedSubtitles 순서)대로, 그 자막의 그림(styleOverride가 있으면 그 모양)
        func expected(_ f: Int, styleOverride: (UUID, SubtitleStyle)? = nil) -> [UInt8] {
            let ctx = bitmap()
            for it0 in s.timeline.renderedSubtitles where it0.visible(atFrame: f) || (it0.end == s.timeline.durationFrames && f == it0.end) {
                var it = it0; if let (id, st) = styleOverride, id == it.id { it = it.with(style: st) }
                let r = SubtitleRenderer.shared.raster(it)
                ctx.draw(r.image, in: CGRect(x: r.drawRect.minX, y: 1080 - r.drawRect.maxY, width: r.drawRect.width, height: r.drawRect.height))
            }
            return bytes(ctx)
        }
        func bitmap() -> CGContext {
            CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        }
        func bytes(_ c: CGContext) -> [UInt8] { Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: 1920 * 1080 * 4)) }
        /// 비교: 화소 차이 > 2인 바이트 수(그림자·가장자리 보간 여유), 기대 그림의 칠한 화소 수
        /// immediate: 탐색한 같은 차례에 그 프레임에 보일 자막 층이 모두 그림을 가졌는지(내부 상태) 보고, 그림 비교는 플레이어 시각이
        /// 그 프레임에 닿자마자 한다(더 기다리지 않음). 탐색은 비동기라 탐색을 부른 직후의 표시 상태는 아직 이전 시각이다.
        func compare(_ name: String, _ f: Int, immediate: Bool = false, styleOverride: (UUID, SubtitleStyle)? = nil) async {
            if immediate {
                let vis = s.timeline.renderedSubtitles.filter { $0.visible(atFrame: f) }
                let missing = vis.filter { host.subtitleLayerForTest($0.id)?.contents == nil }.count
                check("state.\(name)", missing == 0, "visible \(vis.count) without contents \(missing)")
                let prev = lastFrame
                _ = await LaneSelfTest.waitUntil(3) { s.settings.frame(containing: s.player.currentTime()) == f }
                if let got = presented() {   // 진단: 시각이 닿은 직후의 표시 상태가 이전 프레임 그림인가
                    let old = expected(prev)
                    let d = stride(from: 3, to: old.count, by: 4).reduce(0) { $0 + (abs(Int(got[$1]) - Int(old[$1])) > 2 ? 1 : 0) }
                    check("diag.\(name).atTimeMatchesPreviousFrame", true, "differ vs previous frame \(prev): \(d)")
                }
                try? await Task.sleep(nanoseconds: 50_000_000)   // 화면 갱신 두세 번(표시 상태 시각이 따라오게), 쉼 기다림 없음
            } else { await LaneSelfTest.settle(); try? await Task.sleep(nanoseconds: 150_000_000) }
            guard let got = presented() else { check("image.\(name)", false, "no presentation"); return }
            let want = expected(f, styleOverride: styleOverride)
            var differ = 0, ink = 0
            for i in stride(from: 3, to: want.count, by: 4) {
                if want[i] > 0 { ink += 1 }
                if abs(Int(got[i]) - Int(want[i])) > 2 || abs(Int(got[i - 1]) - Int(want[i - 1])) > 2 { differ += 1 }
            }
            let vis = s.timeline.renderedSubtitles.filter { $0.visible(atFrame: f) }.count
            lastFrame = f
            check("image.\(name)", differ <= 4 && (vis == 0 || ink > 500),
                  "frame \(f) visible \(vis) ink \(ink) differ \(differ) resident \(host.residentSubtitleCount)")
        }
        var lastFrame = 0
        let subs = s.timeline.renderedSubtitles.sorted { $0.start < $1.start }
        // 1. 처음
        s.seek(to: 10); await compare("start", 10)
        // 2. 차례 재생 2초 뒤 멈춤(미리 준비한 그림이 들어갔는가)
        s.seek(to: 0); await LaneSelfTest.settle()
        s.play(); try? await Task.sleep(nanoseconds: 2_000_000_000); s.pause(); await LaneSelfTest.settle()
        await compare("afterPlayback", s.playhead)
        // 3. 먼 탐색(같은 차례 = 바로, 그리고 자리 잡은 뒤), 4. 되감기
        let far = subs[110].start + 5
        s.seek(to: far); await compare("farSeek.immediate", far, immediate: true); await compare("farSeek", far)
        let back = subs[20].start + 3
        s.seek(to: back); await compare("reverseSeek.immediate", back, immediate: true); await compare("reverseSeek", back)
        // 5. 경계 한 칸씩(시작 − 1, 시작, 끝 − 1, 끝)
        let b = subs[60]
        for f in [b.start - 1, b.start, b.end - 1, b.end] { s.seek(to: f); await compare("step.\(f - b.start)", f) }
        // 5b. 차가운 캐시에서 멈춘 채 한 칸씩(Codex 검토 2026-10-24: 뒤에서 그리는 동안 한 칸 넘기면 보일 자막 층에 그림이 없었다).
        //     캐시를 비우고 앞 자막 시작 1칸 전으로 건너뛴 뒤(그 자막은 아직 그림 없음, 뒤에서 그리는 일이 있음) 앞으로 한 칸 → 같은 차례에 그림, 화면 그림도 같음.
        //     뒤로도: 끝 다음 칸에서 끝 − 1로 한 칸(끝은 제외, 끝 − 1은 보임).
        for (i, k) in [75, 90, 105].enumerated() {
            let t = subs[k]
            SubtitleRenderer.shared.removeAll()
            s.seek(to: t.start - 1)
            let coldBefore = host.subtitleLayerForTest(t.id)?.contents == nil
            let pending = host.subtitleRasterPending
            s.seek(to: t.start)   // 한 칸 앞으로(건너뛰기 아님)
            check("stepForward.cold.\(i).state", host.subtitleLayerForTest(t.id)?.contents != nil,
                  "cold before \(coldBefore) raster pending \(pending)")
            await compare("stepForward.cold.\(i)", t.start)
            SubtitleRenderer.shared.removeAll()
            s.seek(to: t.end + 200); await LaneSelfTest.settle()   // 창 밖으로(그림 놓음) 갔다가
            s.seek(to: t.end)                                      // 끝 칸(보이지 않음)으로 건너뛰고
            s.seek(to: t.end - 1)                                  // 뒤로 한 칸(보임)
            check("stepBackward.cold.\(i).state", host.subtitleLayerForTest(t.id)?.contents != nil, "")
            await compare("stepBackward.cold.\(i)", t.end - 1)
            s.seek(to: t.end); await compare("exclusiveEnd.\(i)", t.end)
        }
        // 5c. 차가운 캐시에서 겹친 자막(아래·위 레인 둘 다 보이는 프레임)으로 먼 탐색
        if let o = s.timeline.renderedSubtitles.first(where: { $0.style.yMilli == 200_000 && $0.start > 3000 }) {
            SubtitleRenderer.shared.removeAll()
            s.seek(to: o.start + 10)
            let vis = s.timeline.renderedSubtitles.filter { $0.visible(atFrame: o.start + 10) }
            check("overlapSeek.cold.state", vis.count >= 2 && vis.allSatisfy { host.subtitleLayerForTest($0.id)?.contents != nil }, "visible \(vis.count)")
            await compare("overlapSeek.cold", o.start + 10)
        }
        // 5d. 타임라인 끝에서 끝나는 자막: 마지막 두 프레임(끝 − 1, 끝 = 마지막 유지 프레임)에 보임, 차가운 캐시에서 건너뛰고 한 칸씩
        if let fin = s.timeline.subtitle(finalID) {
            let d = s.timeline.durationFrames
            check("final.setup", fin.end == d, "end \(fin.end) duration \(d)")
            SubtitleRenderer.shared.removeAll()
            s.seek(to: d - 3); await LaneSelfTest.settle()
            SubtitleRenderer.shared.removeAll()
            s.seek(to: d - 2); s.seek(to: d - 1)
            check("final.stepToLast.state", host.subtitleLayerForTest(fin.id)?.contents != nil, "")
            await compare("final.frameMinus1", d - 1)
            s.seek(to: d)
            check("final.endFrame.state", host.subtitleLayerForTest(fin.id)?.contents != nil, "")
            await compare("final.endFrame", d)
            SubtitleRenderer.shared.removeAll()
            s.seek(to: 100); await LaneSelfTest.settle()
            s.seek(to: d)   // 먼 곳에서 끝 프레임으로 건너뜀
            check("final.seekToEnd.state", host.subtitleLayerForTest(fin.id)?.contents != nil, "")
            await compare("final.seekToEnd", d)
        }
        // 5e. 먼 탐색 중 이전 프레임 자막 유지(Codex 검토 2026-10-24): 멈춘 채 자막 위에서 먼 곳으로 탐색하면, 탐색이 끝날 때까지 화면은 이전 프레임이므로
        //     그 자막 층의 그림을 놓지 않는다(같은 차례 상태). 탐색이 끝나면 창 밖이 된 그 그림을 놓는다.
        do {
            let a = subs[40]
            s.seek(to: a.start + 5); await LaneSelfTest.settle()
            let had = host.subtitleLayerForTest(a.id)?.contents != nil
            s.seek(to: subs[140].start + 5)   // 먼 곳(이전 자막은 창 밖)
            let keptWhilePending = host.subtitleLayerForTest(a.id)?.contents != nil
            _ = await LaneSelfTest.waitUntil(3) { s.settings.frame(containing: s.player.currentTime()) == subs[140].start + 5 }
            await LaneSelfTest.settle(); try? await Task.sleep(nanoseconds: 200_000_000)
            let releasedAfter = host.subtitleLayerForTest(a.id)?.contents == nil
            check("seekHold.outgoingKeptUntilSeekEnds", had && keptWhilePending && releasedAfter, "had \(had) kept \(keptWhilePending) released after \(releasedAfter)")
            await compare("seekHold.destination", subs[140].start + 5)
        }
        // 5f. 빠르게 훑기 경쟁(Codex 검토): 탐색 A가 끝났는데 알림이 늦게 처리되는 사이 B, C가 요청되면 A 프레임(화면에 나와 있을 수 있음)과
        //     이전 프레임의 자막을 지켜야 하고, 늦은 A 알림이 유지를 풀면 안 된다. A·B·C는 실제로 요청하고(플레이어는 A·B를 취소할 수 있음),
        //     "A가 끝났고 그 알림이 B·C 뒤에 처리됨"은 실제 플레이어로 만들 수 없어 그 알림 하나만 직접 호출로 흉내 낸다.
        do {
            let p0 = subs[44], a = subs[48], b = subs[100], c = subs[146]
            s.seek(to: p0.start + 5); await LaneSelfTest.settle()
            s.seek(to: a.start + 5); let tokenA = s.seekToken   // 탐색 A(같은 차례에 A 자막 채움)
            s.seek(to: b.start + 5)                              // A 알림 전에 B
            s.seek(to: c.start + 5)                              // 그리고 C
            let keptA1 = host.subtitleLayerForTest(a.id)?.contents != nil, keptP1 = host.subtitleLayerForTest(p0.id)?.contents != nil
            host.subtitleSeekFinished(token: tokenA, frame: a.start + 5, finished: true)   // 늦게 처리되는 A의 성공 알림(흉내)
            let keptA2 = host.subtitleLayerForTest(a.id)?.contents != nil
            let held = host.seekHeldCount
            _ = await LaneSelfTest.waitUntil(3) { s.settings.frame(containing: s.player.currentTime()) == c.start + 5 }
            await LaneSelfTest.settle(); try? await Task.sleep(nanoseconds: 200_000_000)
            let released = host.subtitleLayerForTest(a.id)?.contents == nil && host.subtitleLayerForTest(p0.id)?.contents == nil && host.seekHeldCount == 0
            check("seekHold.staleCompletionKeepsShownFrames", keptA1 && keptP1 && keptA2 && held <= 8 && released,
                  "after C: keptA \(keptA1) keptPrev \(keptP1); after stale A: keptA \(keptA2) held \(held); released after latest \(released)")
            await compare("seekHold.staleCompletionDestination", c.start + 5)
        }
        // 5g. 재생 중 멈칫해 건너뛴 갱신(탐색 없음, Codex 검토): 유지를 만들지 않고, 지나간 자막 그림은 창 밖이면 놓는다.
        //     재생 헤드 갱신을 직접 호출로 흉내 낸다(실제 재생에서 멈칫을 만들 수 없음).
        do {
            s.seek(to: subs[10].start + 2); await LaneSelfTest.settle()
            var maxHeld = 0, maxRes = 0
            var f = subs[10].start + 2
            for _ in 0..<80 { f += 7; host.subtitlePlayheadMoved(to: f); maxHeld = max(maxHeld, host.seekHeldCount); maxRes = max(maxRes, host.residentSubtitleCount) }
            let early = host.subtitleLayerForTest(subs[10].id)?.contents == nil
            check("playbackSkips.noHold", maxHeld == 0 && maxRes <= 30 && early, "max held \(maxHeld) max resident \(maxRes) early released \(early)")
            s.seek(to: f); await LaneSelfTest.settle()
        }
        // 6. 창보다 긴 자막 한가운데(시작이 창 밖)
        if let long = s.timeline.subtitle(longID) { s.seek(to: long.start + 900); await compare("longSubtitleMiddle.immediate", long.start + 900, immediate: true); await compare("longSubtitleMiddle", long.start + 900) }
        // 7. 처음으로 다시(재생 다시 시작)
        s.seek(to: 0); s.play(); try? await Task.sleep(nanoseconds: 500_000_000); s.pause(); await compare("restart", s.playhead)
        // 8. 미리 그리는 중 글 고치기: 먼 곳으로 가서 창 안 앞 자막이 뒤에서 그려지는 동안 그 자막 글을 바꾸고 그리로 간다 → 새 글
        if let e = s.timeline.subtitle(editID) {
            SubtitleRenderer.shared.removeAll()
            s.seek(to: e.start - 200)
            let pendingSeen = host.subtitleRasterPending
            s.setSubtitleText(editID, "고친 글 \(e.start)")
            s.seek(to: e.start + 5); await compare("editDuringPrefetch", e.start + 5)
            check("editDuringPrefetch.newText", s.timeline.subtitle(editID)?.text == "고친 글 \(e.start)", "prefetch pending at edit \(pendingSeen)")
        }
        // 9. 모양 조정 미리 보기: 창이 덮어쓰지 않음(한 칸 옮겨도 미리 보기 그대로), 끝내면 저장한 모양
        let sv = subs[70]
        s.seek(to: sv.start + 2); await LaneSelfTest.settle()
        s.select(sv.id)
        var preview = sv.style; preview.red = 10; preview.green = 200; preview.blue = 30
        s.styleEditChange(sv.id, project: s.projectSession) { $0.red = 10; $0.green = 200; $0.blue = 30 }
        s.seek(to: sv.start + 3)
        await compare("styleSessionPreview", sv.start + 3, styleOverride: (sv.id, preview))
        s.finishColorSession(); _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        await compare("styleSessionCommitted", sv.start + 3)
        s.undo(); _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        // 10. 그림을 가진 층 수 상한(창 안 자막 수 정도), 반복 탐색 뒤
        var maxResident = 0
        for i in 0..<120 { s.seek(to: (i * 1777) % max(1, s.timeline.durationFrames)); if i % 10 == 0 { await LaneSelfTest.settle() }; maxResident = max(maxResident, host.residentSubtitleCount) }
        await LaneSelfTest.settle()
        check("resident.bounded", maxResident <= 30 && host.residentSubtitleCount <= 30, "max \(maxResident) now \(host.residentSubtitleCount) of \(host.subtitleLayerCount) layers")
        check("cache.bounded", SubtitleRenderer.shared.cachedImageBytes <= SubtitleRenderer.cacheByteBudget, "\(SubtitleRenderer.shared.cachedImageBytes)")
        // 11. 프로젝트 바꿈: 층·그림 없음, 캐시 비움. 뒤에서 그리는 일이 남은 채 바꾸면 그 결과는 새 프로젝트에 들어가지 않는다.
        SubtitleRenderer.shared.removeAll()
        s.seek(to: subs[30].start - 100)   // 창 안 앞 자막을 뒤에서 그리게
        let pendingAtSwitch = host.subtitleRasterPending
        s.discardConfirmedForTest(); s.resetProject(); await LaneSelfTest.settle(); try? await Task.sleep(nanoseconds: 300_000_000)
        check("projectSwitch.staleRasterDropped", host.subtitleLayerCount == 0 && host.residentSubtitleCount == 0, "pending at switch \(pendingAtSwitch)")
        // 캐시: 바꿀 때 비우지만, 바뀐 직후 이전 상태로 한 번 더 그려지는 경우가 있어(측정 약 0.3 MB) 작은 여유를 둔다
        check("projectSwitch.released", host.subtitleLayerCount == 0 && host.residentSubtitleCount == 0 && SubtitleRenderer.shared.cachedImageBytes <= 2 << 20,
              "layers \(host.subtitleLayerCount) resident \(host.residentSubtitleCount) cache \(SubtitleRenderer.shared.cachedImageBytes)")
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        if let d = try? JSONEncoder().encode(checks) { try? d.write(to: folder.appendingPathComponent("subtitle-window-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
