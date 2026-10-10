// 재생 프레임 계수: 이전에 보고된 "건너뛴 프레임"을 층별로 나눠 기록한다.
//   1) 합성기 요청: 합성기가 이 프레임 이미지를 만들었는가(CompositorLog). 요청이 없던 프레임은
//      이 재생 항목의 어떤 소비자(AVPlayerLayer, 비디오 출력)도 가질 수 없다.
//   2) 전달 버퍼: AVPlayerItemVideoOutput 폴러가 받은 프레임(FrameCapture). 폴러가 늦으면(폴링 간격 > 1프레임)
//      출력은 최신 프레임만 주므로, 요청·렌더된 프레임도 관찰에서 빠진다. 이것은 화면 누락이 아니다.
//   3) 표시 프레임: 재생 중 AVPlayerLayer가 실제로 표시한 프레임은 공개 API로 프레임 단위 관찰이 불가능하다.
//      AVFoundation 자체 집계(accessLog numberOfDroppedVideoFrames)와 표시 준비 상태만 참고로 기록한다.
// 창 구성은 window 모드와 같다(makePreviewWindow). 기준(O-09)이 없으므로 개수는 RECORD로만 남긴다.
import AppKit
import AVFoundation
import AVKit
import CoreMedia
import E1Core
import E1Expect
import Foundation
import QuartzCore

@MainActor
final class FramesApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let code = await runFrameAccounting()
            NSApp.terminate(nil)
            exit(code)
        }
    }
}

func loadAverages() -> [Double] {
    var l = [Double](repeating: -1, count: 3)
    _ = getloadavg(&l, 3)
    return l
}

/// 한 번의 0→끝 재생을 층별로 계수한다.
@MainActor
func accountPlayback(_ h: Harness, layer: AVPlayerLayer?) async -> (Bool, [String: Any]) {
    let load0 = loadAverages()
    let (wall, reached) = await h.playThrough()
    let delivered = h.capture.snapshot()
    let comp = h.log.snapshot()
    let polls = h.capture.pollStats()
    let range = 0..<Spec.frameCount
    let requested = Set(comp.entries.map { $0.frame }.filter { range.contains($0) })
    let got = Set(delivered.map { $0.frame }.filter { range.contains($0) })
    // item 시각 → host 시각 변환(재생 속도 1, 전달 표본의 중앙값 오프셋)
    let offsets = delivered.map { $0.hostSeconds - $0.polledItemSeconds }.sorted()
    let offset = offsets.isEmpty ? 0 : offsets[offsets.count / 2]
    let clockOffset = CACurrentMediaTime() - Double(Clock.now()) / 1e9
    let finishHost = Dictionary(comp.entries.map { ($0.frame, Double($0.finishedUptimeNs) / 1e9 + clockOffset) }, uniquingKeysWith: { a, _ in a })
    var notRequested: [Int] = [], observerStall: [Int] = [], outputNotHanded: [Int] = []
    var renderedLate: [Int] = []
    for n in range where !got.contains(n) {
        guard requested.contains(n) else { notRequested.append(n); continue }
        let a = Double(n) / 30 + offset, b = Double(n + 1) / 30 + offset   // 이 프레임이 현재 프레임인 host 구간
        // 그 구간 동안 폴링이 한 번도 없었으면 관찰기(폴러) 지연
        if polls.gaps.contains(where: { $0.fromHost <= a && $0.toHost >= b }) { observerStall.append(n) } else { outputNotHanded.append(n) }
    }
    for n in requested.sorted() {
        if let f = finishHost[n], f > Double(n + 1) / 30 + offset { renderedLate.append(n) }   // 표시 구간이 끝난 뒤 렌더 완료
    }
    let hashBad = delivered.filter { !$0.hashMatchesReference }.count
    let lastEvent = h.item.accessLog()?.events.last
    let load1 = loadAverages()
    return (hashBad == 0 && reached, [
        "wallS": wall, "reachedEnd": reached, "loadAvgBefore": load0, "loadAvgAfter": load1,
        "compositorRequests": comp.entries.count, "requestedUniqueInRange": requested.count,
        "notRequested": notRequested.count, "notRequestedFrames": notRequested,
        "delivered": delivered.count, "deliveredUniqueInRange": got.count, "deliveredHashMismatch": hashBad,
        "missingFromObserver": Spec.frameCount - got.count,
        "missingButRequested_observerStall": observerStall.count, "observerStallFrames": observerStall,
        "missingButRequested_outputNotHanded": outputNotHanded.count, "outputNotHandedFrames": outputNotHanded,
        "renderFinishedAfterDisplayWindow": renderedLate.count, "renderFinishedLateFrames": Array(renderedLate.prefix(20)),
        "compositorRenderMsMax": comp.entries.map { $0.renderMs }.max() ?? 0,
        "compositorMaxInFlight": comp.maxInFlight, "compositorErrors": comp.errors,
        "pollCount": polls.count, "pollGapsOver20ms": polls.gaps.count, "pollGapMsMax": polls.gaps.map { $0.ms }.max() ?? 0,
        "layerReadyForDisplayAfter": layer?.isReadyForDisplay ?? false,
        "accessLogDroppedVideoFrames": lastEvent.map { $0.numberOfDroppedVideoFrames } ?? -1,
        "accessLogEvents": h.item.accessLog()?.events.count ?? 0,
    ])
}

@MainActor
func runFrameAccounting() async -> Int32 {
    let r = Report()
    let started = Date()
    let runID = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
    r.sections["build"] = ["sourceTree": BuildIdentity.sourceTree(root: root), "executable": BuildIdentity.executable()]
    r.sections["run"] = ["id": runID, "os": ProcessInfo.processInfo.operatingSystemVersionString, "volume": 0,
                         "window": "AVPlayerView (makePreviewWindow, window 모드와 같은 코드)", "loadAvgStart": loadAverages(),
                         "evidenceBoundary": "합성기 요청·비디오 출력 전달은 프레임 단위 기록. 재생 중 AVPlayerLayer의 프레임 단위 표시는 관찰 불가(accessLog 집계만 참고)"]
    do {
        let env = try await loadEnv()
        r.sections["fixtures"] = env.fixtureCheck
        for c in Expect.cases {
            let h = try await Harness.make(c, env: env, muted: true)
            let (w, pv, _) = makePreviewWindow(h, c)
            await sleepMs(300)
            let layer = findPlayerLayer(pv.layer, player: h.player)
            var runs: [[String: Any]] = []
            var ok = layer != nil
            for _ in 0..<(c.id == Expect.cases[0].id ? 3 : 1) {
                let (pass, d) = await accountPlayback(h, layer: layer)
                ok = ok && pass
                runs.append(d)
            }
            r.check("F-\(c.id)", "창 부착 재생 프레임 계수(합성기 요청 / 출력 전달 / 관찰기 지연 구분): 전달 프레임 비트 동일·끝 도달만 판정, 개수는 기록",
                    pass: ok, ["playerLayerFound": layer != nil, "runs": runs])
            w.close()
            h.player.replaceCurrentItem(with: nil)
        }
    } catch {
        r.check("ABORT", "실행 중단", pass: false, ["error": "\(error)"])
    }
    r.sections["loadAvgEnd"] = loadAverages()
    r.sections["wallSecondsTotal"] = Date().timeIntervalSince(started)
    let pass = r.checks.filter { ($0["result"] as? String) == "PASS" }.count
    let fail = r.checks.filter { ($0["result"] as? String) == "FAIL" }
    r.sections["summary"] = ["pass": pass, "fail": fail.count, "failedIDs": fail.map { $0["id"] as! String }]
    let url = resultsDir.appendingPathComponent("e1b-frames-\(runID).json")
    if let data = try? JSONSerialization.data(withJSONObject: sanitize(["sections": r.sections, "checks": r.checks]), options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url)
    }
    print("\nPASS \(pass)  FAIL \(fail.count)   failed: \(fail.map { $0["id"] as! String })")
    print("results: results/\(url.lastPathComponent)")
    return fail.isEmpty ? 0 : 1
}
