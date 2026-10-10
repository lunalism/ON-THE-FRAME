// 표시 경계 회귀 검사: 소유자 관찰 창과 같은 창 구성(AVPlayerView)에서, 그 뷰가 쓰는 AVPlayerLayer가
// 표시 준비가 되었는지와 일시정지 중 표시 중인 픽셀 버퍼가 기대 프레임인지 확인한다.
// 증거 경계: AVPlayerLayer의 표시 버퍼까지다. 창 서버 합성, 화면 크기 조정, 디스플레이 색 관리를 거친
// 실제 화면 픽셀은 캡처하지 않는다(화면 기록 권한 필요).
import AppKit
import AVFoundation
import AVKit
import CoreMedia
import E1Core
import E1Expect
import Foundation
import QuartzCore

@MainActor
final class PresentApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let code = await runPresentChecks(negativeControl: CommandLine.arguments.contains("--negative-control"))
            NSApp.terminate(nil)
            exit(code)
        }
    }
}

/// 일시정지 상태에서 레이어가 표시하는 버퍼가 시각 프레임 n의 기대 내용(Expect.contentFrame(n))이 될 때까지 기다린다(최대 timeoutMs).
@MainActor
func waitDisplayed(_ layer: AVPlayerLayer, frame n: Int, reference: [String], captionRect: CGRect, timeoutMs: Int) async -> [String: Any] {
    let content = Expect.contentFrame(forTimeIndex: n)
    let t0 = CACurrentMediaTime()
    var last: [String: Any] = ["displayedPixelBuffer": "nil"]
    while (CACurrentMediaTime() - t0) * 1000 < Double(timeoutMs) {
        if let pb = layer.displayedPixelBuffer() {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), fmt = CVPixelBufferGetPixelFormatType(pb)
            last = ["displayedPixelBuffer": "present", "width": w, "height": h, "pixelFormat": fmt == kCVPixelFormatType_32BGRA ? "BGRA" : String(fmt)]
            if w == Spec.width, h == Spec.height, fmt == kCVPixelFormatType_32BGRA {
                let m = FrameMetrics.measure(pb, captionRect: captionRect)
                last["frameCode"] = m.code
                last["hashMatchesReference"] = n < reference.count && PixelCompare.sha256(pb) == reference[n]
                last["captionShown"] = m.captionPixels > 300
                last["maxBarPx"] = m.barHeights.max() ?? -1
                if m.code == content { last["waitMs"] = (CACurrentMediaTime() - t0) * 1000; return last }
            }
        }
        await sleepMs(10)
    }
    last["waitMs"] = (CACurrentMediaTime() - t0) * 1000
    last["timedOut"] = true
    return last
}

@MainActor
/// negativeControl: 수정 전 구성(빈 비디오 트랙)을 c1로 재현해 이 검사가 검은 화면을 실제로 잡는지 확인한다.
/// 이때 L1이 실패해야 정상이며, 결과는 "L0-negative-control"(실패를 검출하면 PASS)로 기록한다.
func runPresentChecks(negativeControl: Bool) async -> Int32 {
    let r = Report()
    let started = Date()
    let runID = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
    r.sections["build"] = ["sourceTree": BuildIdentity.sourceTree(root: root), "executable": BuildIdentity.executable()]
    r.sections["run"] = ["id": runID, "os": ProcessInfo.processInfo.operatingSystemVersionString, "volume": 0,
                         "window": "AVPlayerView (makePreviewWindow, window 모드와 같은 코드)",
                         "evidenceBoundary": "AVPlayerLayer.isReadyForDisplay와 일시정지 중 displayedPixelBuffer. 실제 화면 픽셀 아님",
                         "negativeControl": negativeControl]
    do {
        let env = try await loadEnv()
        r.sections["fixtures"] = env.fixtureCheck
        let captionRect = FrameRenderer.captionLayout().inkRectTopLeft.insetBy(dx: -2, dy: -2)
        for c in negativeControl ? [Expect.cases[0]] : Expect.cases {
            // window 모드와 같은 구성: 비디오 출력 부착, 같은 Harness, 같은 창 생성 함수
            let h = try await Harness.make(c, env: env, muted: true, diagnosticEmptyVideoTrack: negativeControl)
            let (w, pv, _) = makePreviewWindow(h, c)
            await sleepMs(300)
            guard let layer = findPlayerLayer(pv.layer, player: h.player) else {
                r.check("L1-\(c.id)", "AVPlayerView의 AVPlayerLayer 표시 경계", pass: false, ["error": "AVPlayerLayer not found in AVPlayerView layer tree"])
                w.close(); h.player.replaceCurrentItem(with: nil); continue
            }
            // 재생 중 표시 준비 상태 표본(2초)
            h.player.play()
            var ready: [Bool] = []
            for _ in 0..<20 { await sleepMs(100); ready.append(layer.isReadyForDisplay) }
            h.player.pause()
            // 일시정지 정확 탐색: 배경·자막 경계 양쪽·막대(톤 구간)·끝 근처·뒤로
            var rows: [[String: Any]] = []
            var ok = ready.last == true
            // 끝 시각 300은 마지막 유효 프레임 299를 보여야 한다(P-007). 끝에서 프레임 단위로 두 번 뒤로(창의 ←와 같은 API).
            let moves: [(Move, Int)] = [30, 59, 60, 120, 180, 239, 240, 299, 300].map { (.seek(CMTime(value: Int64($0), timescale: 30)), $0) }
                + [(.step(-1), 299), (.step(-1), 298), (.seek(CMTime(value: 45, timescale: 30)), 45)]
            for (move, n) in moves {
                var stepped: CMTime?
                switch move {
                case .seek(let t): await h.seekExact(t)
                case .step(let k): stepped = await stepAndWait(h, k)
                }
                var row = await waitDisplayed(layer, frame: n, reference: h.reference, captionRect: captionRect, timeoutMs: 1500)
                row["target"] = n
                if let s = stepped { row["move"] = "step"; row["playerTimeIndex"] = E1Compositor.frameIndex(s).0 }
                let content = Expect.contentFrame(forTimeIndex: n)
                let expectCaption = (Expect.captionFirstFrame...Expect.captionLastFrame).contains(content)
                var good = (row["frameCode"] as? Int) == content && (row["hashMatchesReference"] as? Bool) == true
                    && (row["captionShown"] as? Bool) == expectCaption
                if let s = stepped, E1Compositor.frameIndex(s).0 != n { good = false }
                row["ok"] = good
                if !good { ok = false }
                rows.append(row)
            }
            // 끝까지 재생: 9.5 s부터 재생해 끝에서 멈추면(기본 actionAtItemEnd = pause) 레이어가 마지막 유효 프레임을 보여야 한다.
            // 이어서 처음부터 다시 재생해 1 s 뒤 멈추면 그 시각의 프레임을 보여야 한다(끝 화면 잔상 없음).
            var playRows: [[String: Any]] = []
            if !negativeControl {
                await h.seekExact(CMTime(value: 285, timescale: 30))
                h.player.play()
                let t0 = CACurrentMediaTime()
                while h.player.rate != 0 && CACurrentMediaTime() - t0 < 3 { await sleepMs(10) }
                let endIdx = E1Compositor.frameIndex(h.player.currentTime())
                var endRow = await waitDisplayed(layer, frame: endIdx.0, reference: h.reference, captionRect: captionRect, timeoutMs: 1500)
                endRow["phase"] = "played to end"; endRow["playerTimeIndex"] = endIdx.0; endRow["exactTime"] = endIdx.1
                let endGood = endIdx.0 == Spec.frameCount && (endRow["frameCode"] as? Int) == Expect.lastValidFrame
                    && (endRow["hashMatchesReference"] as? Bool) == true
                endRow["ok"] = endGood; if !endGood { ok = false }
                playRows.append(endRow)
                await h.seekExact(.zero)
                h.player.play()
                await sleepMs(1000)
                h.player.pause()
                await sleepMs(100)
                // 정지 시각이 n/30 사이이면 그 시각을 포함하는 프레임(내림)이 표시된다. frameIndex(반올림)를 쓰면 안 된다.
                // 기록(2026-10-10 …000303Z): 반올림으로 기대값을 잡아 c1·c4에서 검사 자체가 틀렸다.
                let reT = h.player.currentTime()
                let reN = Int((reT.seconds * Double(Spec.fps)).rounded(.down))
                var reRow = await waitDisplayed(layer, frame: reN, reference: h.reference, captionRect: captionRect, timeoutMs: 1500)
                reRow["phase"] = "replay from start, paused after 1 s"; reRow["playerTimeIndex"] = reN; reRow["playerSeconds"] = reT.seconds
                let reGood = reN > 0 && reN < Expect.lastValidFrame && (reRow["frameCode"] as? Int) == reN
                    && (reRow["hashMatchesReference"] as? Bool) == true
                reRow["ok"] = reGood; if !reGood { ok = false }
                playRows.append(reRow)
            }
            let fmt = rows.first?["pixelFormat"] as? String ?? "-"
            if negativeControl {
                r.check("L0-negative-control", "대조: 수정 전 구성(빈 비디오 트랙)에서 같은 검사가 실패를 검출", pass: !ok,
                        ["readyForDisplaySamples": ready, "seeks": rows, "compositorRequests": h.log.snapshot().entries.count])
                w.close(); h.player.replaceCurrentItem(with: nil); continue
            }
            r.check("L1-\(c.id)", "AVPlayerView 안 AVPlayerLayer: 재생 중 표시 준비 = true, 일시정지 탐색·끝·끝에서 프레임 단위 뒤로의 표시 버퍼 = 기대 내용(끝 시각은 마지막 유효 프레임), 끝까지 재생 후 정지 화면과 처음부터 다시 재생",
                    pass: ok, ["readyForDisplaySamples": ready, "displayedFormat": fmt, "playToEndAndReplay": playRows,
                               "videoRect": [layer.videoRect.origin.x, layer.videoRect.origin.y, layer.videoRect.width, layer.videoRect.height],
                               "layerBounds": [layer.bounds.width, layer.bounds.height], "seeks": rows,
                               "compositorRequests": h.log.snapshot().entries.count, "compositorErrors": h.log.snapshot().errors])
            w.close()
            h.player.replaceCurrentItem(with: nil)
        }
    } catch {
        r.check("ABORT", "실행 중단", pass: false, ["error": "\(error)"])
    }
    r.sections["wallSecondsTotal"] = Date().timeIntervalSince(started)
    let pass = r.checks.filter { ($0["result"] as? String) == "PASS" }.count
    let fail = r.checks.filter { ($0["result"] as? String) == "FAIL" }
    r.sections["summary"] = ["pass": pass, "fail": fail.count, "failedIDs": fail.map { $0["id"] as! String }]
    let url = resultsDir.appendingPathComponent("e1b-present\(negativeControl ? "-negative" : "")-\(runID).json")
    if let data = try? JSONSerialization.data(withJSONObject: sanitize(["sections": r.sections, "checks": r.checks]), options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url)
    }
    print("\nPASS \(pass)  FAIL \(fail.count)   failed: \(fail.map { $0["id"] as! String })")
    print("results: results/\(url.lastPathComponent)")
    return fail.isEmpty ? 0 : 1
}
