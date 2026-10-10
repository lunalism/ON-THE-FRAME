// 검은 프리뷰 진단: 실제 창 안의 AVPlayerLayer가 무엇을 표시하는지 변형별로 기록한다.
import AppKit
import AVFoundation
import CoreMedia
import E1Core
import E1Expect
import Foundation
import QuartzCore

/// 창에 붙인 AVPlayerLayer. 표시 경계에서 관찰할 수 있는 값(isReadyForDisplay, videoRect,
/// 일시정지 중 displayedPixelBuffer)을 읽는다. 화면 캡처는 하지 않는다.
@MainActor
final class LayerProbe {
    let window: NSWindow
    let layer: AVPlayerLayer

    init(player: AVPlayer, title: String) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 960, height: 540), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.darkGray.cgColor
        layer = AVPlayerLayer(player: player)
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspect
        layer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        view.layer?.addSublayer(layer)
        window.contentView = view
        window.orderFrontRegardless()
    }

    func close() { layer.player = nil; window.orderOut(nil); window.close() }

    /// 일시정지 중 레이어가 표시하는 버퍼를 기대 프레임과 비교한다.
    func displayed(expectFrame n: Int, reference: [String], captionRect: CGRect) -> [String: Any] {
        guard let pb = layer.displayedPixelBuffer() else { return ["displayedPixelBuffer": "nil"] }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        var d: [String: Any] = ["displayedPixelBuffer": "present", "width": w, "height": h,
                                "pixelFormat": fmt == kCVPixelFormatType_32BGRA ? "BGRA" : String(fmt)]
        if w == Spec.width && h == Spec.height && fmt == kCVPixelFormatType_32BGRA {
            let m = FrameMetrics.measure(pb, captionRect: captionRect)
            d["hashMatchesReference"] = PixelCompare.sha256(pb) == reference[n]
            d["frameCode"] = m.code
            d["captionPixels"] = m.captionPixels
            d["maxBarPx"] = m.barHeights.max() ?? -1
        }
        return d
    }
}

@MainActor
final class DiagnoseApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await runDiagnose()
            NSApp.terminate(nil)
        }
    }
}

@MainActor
func trackInfo(_ item: AVPlayerItem) async -> [[String: Any]] {
    var rows: [[String: Any]] = []
    for t in item.tracks {
        guard let at = t.assetTrack else { rows.append(["assetTrack": "nil"]); continue }
        let fds = (try? await at.load(.formatDescriptions)) ?? []
        let segs = (try? await at.load(.segments)) ?? []
        let range = (try? await at.load(.timeRange)) ?? .zero
        rows.append(["mediaType": at.mediaType.rawValue, "itemTrackEnabled": t.isEnabled, "formatDescriptions": fds.count,
                     "segments": segs.count, "emptySegments": segs.filter { $0.isEmpty }.count,
                     "timeRange": [range.start.seconds, range.duration.seconds]])
    }
    return rows
}

/// 변형: 현재 구성(빈 비디오 트랙, 비디오 출력 있음/없음), 운반 비디오 트랙 구성.
@MainActor
func runDiagnose() async {
    let started = Date()
    let runID = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
    var out: [String: Any] = ["build": ["sourceTree": BuildIdentity.sourceTree(root: root), "executable": BuildIdentity.executable()],
                              "os": ProcessInfo.processInfo.operatingSystemVersionString]
    var variants: [[String: Any]] = []
    do {
        let env = try await loadEnv()
        out["fixtures"] = env.fixtureCheck
        let c = Expect.caseByID("c1-baseline")!
        let captionRect = FrameRenderer.captionLayout().inkRectTopLeft.insetBy(dx: -2, dy: -2)
        for (name, useCarrier, withOutput) in [("empty-track+videoOutput", false, true), ("empty-track-noOutput", false, false),
                                               ("carrier-track+videoOutput", true, true)] {
            let h = try await Harness.make(c, env: env, muted: true, diagnosticEmptyVideoTrack: !useCarrier, attachVideoOutput: withOutput)
            let probe = LayerProbe(player: h.player, title: "E1 diagnose — \(name)")
            var v: [String: Any] = ["variant": name, "tracks": await trackInfo(h.item),
                                    "presentationSize": [h.item.presentationSize.width, h.item.presentationSize.height]]
            // AVComposition은 트랙 속성을 동기적으로 읽을 수 있다
            v["visualTracks"] = h.composition.tracks.filter { $0.hasMediaCharacteristic(.visual) }.count
            // 2.5 s 재생하며 isReadyForDisplay 표본
            var ready: [Bool] = []
            h.player.play()
            for _ in 0..<25 { await sleepMs(100); ready.append(probe.layer.isReadyForDisplay) }
            h.player.pause()
            v["readyForDisplayDuringPlay"] = ready
            // 프레임 120(4.0 s, 자막 표시 구간)으로 정확 탐색 후 레이어가 표시하는 버퍼
            await h.seekExact(CMTime(value: 120, timescale: 30))
            await sleepMs(600)
            v["readyForDisplayAfterSeek"] = probe.layer.isReadyForDisplay
            v["videoRect"] = [probe.layer.videoRect.origin.x, probe.layer.videoRect.origin.y, probe.layer.videoRect.width, probe.layer.videoRect.height]
            v["layerDisplayedAt120"] = probe.displayed(expectFrame: 120, reference: h.reference, captionRect: captionRect)
            v["itemStatus"] = h.item.status.rawValue
            v["itemError"] = h.item.error.map { "\($0)" } ?? "-"
            v["errorLogEvents"] = h.item.errorLog()?.events.map { "\($0.errorDomain) \($0.errorStatusCode) \($0.errorComment ?? "")" } ?? []
            v["compositorRequests"] = h.log.snapshot().entries.count
            v["compositorErrors"] = h.log.snapshot().errors
            print("[diag] \(name): ready=\(v["readyForDisplayAfterSeek"] ?? "-") presentation=\(v["presentationSize"] ?? "-") layer=\(v["layerDisplayedAt120"] ?? "-") compositor=\(v["compositorRequests"] ?? 0)")
            variants.append(v)
            probe.close()
            h.player.replaceCurrentItem(with: nil)
        }
    } catch {
        out["error"] = "\(error)"
        print("[diag] error: \(error)")
    }
    out["variants"] = variants
    out["wallSeconds"] = Date().timeIntervalSince(started)
    let url = resultsDir.appendingPathComponent("e1b-diagnose-\(runID).json")
    if let data = try? JSONSerialization.data(withJSONObject: sanitize(out), options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url)
        print("[diag] results/\(url.lastPathComponent)")
    }
}
