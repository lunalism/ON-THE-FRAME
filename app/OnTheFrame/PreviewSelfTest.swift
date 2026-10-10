#if DEBUG
import AppKit
import AVFoundation
import OnTheFrameEngine

/// 편집 뒤 프리뷰 갱신 자체 검사(완료 기준 4, Debug 전용, 일반 화면에 없음).
/// `open -n -W -a OnTheFrame.app <폴더> --args -OTFPreviewTest`. 내보내기는 하지 않는다.
/// 실제 앱 경로(ProjectStore 편집 → timelineChanged → 프리뷰 AVPlayer 항목 교체)를 쓰고, 고정 재생 헤드(프레임 100)에서
/// 프리뷰 항목의 프레임을 비디오 출력(AVPlayerItemVideoOutput)으로 받아 <폴더>/preview/에 BGRA로 저장한다.
/// 판정은 앱 밖의 `otf-dev verify-preview`가 화면 코드(원본 ID·원본 프레임) 또는 검정으로 하고, 기대값은 아래에 손으로 적었다.
@MainActor
enum PreviewSelfTest {
    struct Step: Codable { let name: String; let file: String?; let expected: String; let playhead: Int; let generation: Int; let applied: Int }
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }
    struct Manifest: Codable { let width: Int; let height: Int; var steps: [Step]; var checks: [Check] }

    static let P = 100

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        let src = folder.appendingPathComponent("sources"), out = folder.appendingPathComponent("preview")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var m = Manifest(width: 1920, height: 1080, steps: [], checks: [])
        func check(_ n: String, _ p: Bool, _ d: String = "") { m.checks.append(Check(name: n, pass: p, detail: d)) }

        s.importFiles([src.appendingPathComponent("otf-A.mp4"), src.appendingPathComponent("otf-B.mp4")])
        _ = await waitUntil(30) { s.assets.count == 2 && s.importing == 0 }
        guard let a = s.assets.first(where: { $0.name == "otf-A.mp4" }), let b = s.assets.first(where: { $0.name == "otf-B.mp4" }) else {
            check("setup.import", false); return finish(folder, m)
        }
        // A(120)@0, B(90)@120, 재생 헤드 100
        s.addToTimeline(a.id); s.addToTimeline(b.id)
        s.seek(to: P)
        let output = Output()

        /// 현재 상태가 적용되기를 기다려 프레임 P를 저장하고 기대값을 기록한다
        func capture(_ name: String, _ expected: String) async {
            let ready = await waitUntil(20) { s.appliedGeneration == s.generation && s.player.currentItem?.status == .readyToPlay }
            let file = ready ? await output.grab(s, frame: P, to: out.appendingPathComponent("\(m.steps.count)-\(name).bgra")) : nil
            m.steps.append(Step(name: name, file: file?.lastPathComponent, expected: expected, playhead: s.playhead,
                                generation: s.generation, applied: s.appliedGeneration))
        }
        let A = { (f: Int) in String(format: "id%02X#%d", 0x2D, f) }

        await capture("initial", A(100))
        let aClip = s.timeline.clips[0].id
        s.selection = aClip; s.splitAtPlayhead()                              // A[0,100)@0, A[100,120)@100, B@120
        await capture("split", A(100))
        let L = s.timeline.clips[0].id, R = s.timeline.clips[1].id, B = s.timeline.clips[2].id
        s.beginGesture(select: R); s.updateTrim(R, edge: .start, delta: 5); s.commitGesture()   // R = A[105,120)@100
        await capture("trimStart", A(105))
        s.beginGesture(select: B); s.updateMove(B, toIndex: 0); s.commitGesture()               // B@0, L@90, R@190
        await capture("move", A(10))
        s.selection = L; s.deleteSelection(ripple: false)                      // 빈틈 [90,190)
        await capture("normalDelete", "black")
        s.undo(); await capture("undoDelete", A(10))
        s.redo(); await capture("redoDelete", "black")
        s.undo(); await capture("undoAgain", A(10))
        s.selection = B; s.deleteSelection(ripple: true)                       // L@0, R@100
        await capture("rippleDelete", A(105))
        s.undo(); await capture("undoRipple", A(10))
        s.redo(); await capture("redoRipple", A(105))

        // 빠른 연속 편집: 같은 차례에서 여러 편집을 하고, 앞 세대의 재구성을 일부러 늦게 끝나게 한다.
        // 늦게 끝난 오래된 결과가 마지막 타임라인을 덮으면 안 된다.
        let dropped0 = s.staleRebuildsDropped
        s.testRebuildDelay = [s.generation + 1: 800_000_000, s.generation + 2: 400_000_000]
        s.undo(); s.redo(); s.undo()                                           // 마지막: rippleDelete 전(L@90, R@190 → A#10)
        await capture("rapidBurst1", A(10))
        let dropped1 = s.staleRebuildsDropped
        s.selection = L
        s.testRebuildDelay = [s.generation + 2: 800_000_000]
        s.deleteSelection(ripple: false); s.undo(); s.redo()                   // 마지막: 빈틈 → 검정
        await capture("rapidBurst2", "black")
        _ = dropped1
        let itemBefore = s.player.currentItem                                  // 늦은 오래된 결과가 도착하기 전의 프리뷰 항목
        _ = await waitUntil(3) { s.staleRebuildsDropped >= dropped0 + 4 }       // 늦춘 오래된 결과가 모두 도착해 버려질 때까지
        await capture("afterLateStale", "black")
        check("lateStale.itemNotReplaced", s.player.currentItem === itemBefore)
        s.testRebuildDelay = [:]
        check("stale.dropped", s.staleRebuildsDropped - dropped0 >= 4, "dropped \(s.staleRebuildsDropped - dropped0)")
        check("playhead.fixed", m.steps.allSatisfy { $0.playhead == P }, m.steps.map { "\($0.name)=\($0.playhead)" }.joined(separator: ","))
        check("applied.latest", m.steps.allSatisfy { $0.applied == $0.generation })
        check("frames.captured", m.steps.allSatisfy { $0.file != nil })
        finish(folder, m)
    }

    /// 현재 프리뷰 항목에 비디오 출력을 붙여 정확히 frame 시각의 새 버퍼를 받는다.
    @MainActor final class Output {
        private var attached: (AVPlayerItem, AVPlayerItemVideoOutput)?
        func grab(_ s: ProjectStore, frame: Int, to url: URL) async -> URL? {
            guard let item = s.player.currentItem else { return nil }
            if attached?.0 !== item {
                let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(o); attached = (item, o)
            }
            let o = attached!.1, t = s.settings.time(frame)
            await s.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            let start = Date(), end = start.addingTimeInterval(3)
            while Date() < end {
                // 같은 항목·같은 시각을 다시 읽을 때는 새 버퍼가 없다. 1초 뒤에는 현재 버퍼를 표시 시각을 확인해 읽는다.
                if o.hasNewPixelBuffer(forItemTime: t) || Date().timeIntervalSince(start) > 1 {
                    var shown = CMTime.invalid
                    if let pb = o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown), shown.isNumeric, abs((shown - t).seconds) < 0.0005 {
                        CVPixelBufferLockBaseAddress(pb, .readOnly)
                        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
                        var d = Data(count: w * h * 4)
                        d.withUnsafeMutableBytes { dst in
                            let base = CVPixelBufferGetBaseAddress(pb)!
                            for y in 0..<h { memcpy(dst.baseAddress! + y * w * 4, base + y * bpr, w * 4) }
                        }
                        return (try? d.write(to: url)) != nil ? url : nil
                    }
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return nil
        }
    }

    private static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    private static func finish(_ folder: URL, _ m: Manifest) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(m) { try? d.write(to: folder.appendingPathComponent("preview-manifest.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
