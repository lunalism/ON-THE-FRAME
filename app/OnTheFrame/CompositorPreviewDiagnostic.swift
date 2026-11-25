#if DEBUG
import AppKit
import AVFoundation
@testable import OnTheFrameEngine

/// SP-EXPORT-E4D-REAL-PREVIEW-GATE-40(2026-11-24): 실험 합성기의 첫 재생 프레임 요청을 실제 앱의 프리뷰 창에서 보는 진단(Debug 전용).
/// 명시적 실행 인수로만 돈다: `open -n -a OnTheFrame.app <폴더> --args -OTFCompositorPreviewDiagnostic default|historical|corrected`.
/// `-OTFCompositorDiagVideoOutput`을 더하면 AVPlayerItemVideoOutput을 붙여 "표시할 수 있게 된 프레임"의 시각을 적는다(재생 일정에 영향을 줄 수 있어 선택 사항).
/// <폴더>/sources에 E2 실험의 생성 4K 원본 세 개(src-A/B/C-3840x2160-30p-v2.mp4)와 M-music.wav의 사본이 있어야 한다(읽기만 한다).
/// 이 진단만 앱의 플레이어에 자기 항목을 넣는다. 보통 프리뷰·내보내기·계획의 선택은 바꾸지 않으며 프로젝트를 저장하지 않는다.
/// 구성(S1b 재검토 §16.4와 2026-11-24 헤드리스 재현과 같음): E2 편집 순서 A[30,+90) C[20,+90) B[0,+60) B[150,+60)(300프레임), 클립 소리와 음악 두 소리 트랙,
/// 렌더 3840×2160, 한 층·변형 없음. 준비 → 500 ms → 0으로 정확 탐색 → 바로 재생. 플레이어의 시각·버퍼·탐색 정책은 바꾸지 않는다.
/// 결과: <폴더>/compositor-preview-result.json. 화면에 실제로 그려졌는지는 이 진단이 증명하지 않는다(AVPlayerLayer의 화소는 읽을 수 없다).
@MainActor
enum CompositorPreviewDiagnostic {
    struct Event: Codable { let name: String; let ms: Double; let detail: String }
    struct Tick: Codable { let ms: Double; let itemFrame: Double; let rate: Float; let timebaseRate: Double; let status: Int }
    struct Result: Codable {
        var mode = "", videoOutputAttached = false, error = ""
        var readyItemTime = "", layerReadyForDisplay = false, windowVisible = false
        var events: [Event] = [], ticks: [Tick] = []
        var requestOrder: [Int] = [], finishedFrames: [Int] = [], cancelledFrames: [Int] = [], failedRequests = 0
        var firstRequests: [String] = []
        var videoOutputFrames: [String] = []
        var frame2 = "", frame2Basis = ""
        var limits = "Request receipt, cancellation and completion are direct compositor records. Video-output times show frames made available, not frames drawn by AVPlayerLayer. No screen capture is made."
    }

    /// 표시 주기마다 플레이어 상태를 적는다(최대 240개 — 한없이 쌓지 않는다)
    final class Sampler: NSObject {
        let player: AVPlayer, output: AVPlayerItemVideoOutput?, start: CFTimeInterval
        var ticks: [Tick] = [], frames: [(frame: Int, ms: Double)] = []
        init(player: AVPlayer, output: AVPlayerItemVideoOutput?, start: CFTimeInterval) { self.player = player; self.output = output; self.start = start }
        @objc func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime(), ms = (now - start) * 1000
            if ticks.count < 240, let item = player.currentItem {
                ticks.append(Tick(ms: ms, itemFrame: item.currentTime().seconds * 30, rate: player.rate,
                                  timebaseRate: item.timebase.map { CMTimebaseGetRate($0) } ?? -1, status: player.timeControlStatus.rawValue))
            }
            guard let output, frames.count < 240 else { return }
            let t = output.itemTime(forHostTime: now)
            if output.hasNewPixelBuffer(forItemTime: t) {
                var display = CMTime.invalid
                if output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &display) != nil, display.isNumeric { frames.append((Int((display.seconds * 30).rounded()), ms)) }
            }
        }
    }

    static func run(folder: URL, mode: String, videoOutput: Bool) async {
        let s = ProjectStore.shared
        var result = Result()
        result.mode = mode; result.videoOutputAttached = videoOutput
        func finish() {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result) { try? data.write(to: folder.appendingPathComponent("compositor-preview-result.json")) }
            s.discardConfirmedForTest(); NSApp.terminate(nil)
        }
        guard ["default", "historical", "corrected"].contains(mode) else { result.error = "unknown mode \(mode)"; finish(); return }
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil && s.previewHost?.window != nil }
        guard let view = s.previewHost, let window = s.editorWindow else { result.error = "no preview window"; finish(); return }
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
        let began = CACurrentMediaTime()
        func mark(_ name: String, _ detail: String = "") { result.events.append(Event(name: name, ms: (CACurrentMediaTime() - began) * 1000, detail: detail)) }
        do {
            let sources = folder.appendingPathComponent("sources")
            func asset(_ name: String) -> AVURLAsset { AVURLAsset(url: sources.appendingPathComponent(name)) }
            let a = asset("src-A-3840x2160-30p-v2.mp4"), b = asset("src-B-3840x2160-30p-v2.mp4"), c = asset("src-C-3840x2160-30p-v2.mp4"), music = asset("M-music.wav")
            let comp = AVMutableComposition()
            guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let mt = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { result.error = "composition tracks"; finish(); return }
            func time(_ f: Int) -> CMTime { CMTime(value: CMTimeValue(f), timescale: 30) }
            var at = 0
            for (source, sourceIn, length) in [(a, 30, 90), (c, 20, 90), (b, 0, 60), (b, 150, 60)] {
                guard let v = try await source.loadTracks(withMediaType: .video).first else { result.error = "fixture without video"; finish(); return }
                let range = CMTimeRange(start: time(sourceIn), duration: time(length))
                try vt.insertTimeRange(range, of: v, at: time(at))
                if let sound = try await source.loadTracks(withMediaType: .audio).first { try ct.insertTimeRange(range, of: sound, at: time(at)) }
                at += length
            }
            mt.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 1000, timescale: 1000)))
            if let m = try await music.loadTracks(withMediaType: .audio).first {
                try mt.insertTimeRange(CMTimeRange(start: CMTime(value: 2000, timescale: 1000), duration: CMTime(value: 9000, timescale: 1000)), of: m, at: CMTime(value: 1000, timescale: 1000))
            }
            let frozen = comp.copy() as! AVComposition
            guard let track = frozen.track(withTrackID: vt.trackID) else { result.error = "frozen track"; finish(); return }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(.identity, at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: time(at))
            instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            instruction.layerInstructions = [layer]
            let base = AVMutableVideoComposition()
            base.renderSize = CGSize(width: 3840, height: 2160); base.frameDuration = CMTime(value: 1, timescale: 30); base.instructions = [instruction]
            let log = ExperimentalCompositorLog()
            let composition: AVVideoComposition = mode == "default" ? base.copy() as! AVVideoComposition
                : try ExperimentalComposition.videoComposition(from: base, options: mode == "corrected" ? .init(edgeCoverage: .fullRectangle) : .init(), diagnostics: log)
            let item = AVPlayerItem(asset: frozen)
            mark("playerItemCreated", "segments 4, audio tracks \(frozen.tracks(withMediaType: .audio).count), duration frames \(at)")
            item.videoComposition = composition
            mark("videoCompositionInstalled", mode == "default" ? "built-in compositor" : "ExperimentalCompositor \(mode)")
            var output: AVPlayerItemVideoOutput?
            if videoOutput {
                let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(o); output = o
                mark("videoOutputAttached")
            }
            let player = s.player
            player.replaceCurrentItem(with: item)
            mark("itemInstalledInPreviewPlayer")
            let ready = await LaneSelfTest.waitUntil(15) { item.status == .readyToPlay }
            let readyTime = item.currentTime()
            result.readyItemTime = "\(readyTime.value)/\(readyTime.timescale)"
            mark("readyToPlay", "ready \(ready) item time \(result.readyItemTime)")
            guard ready else { result.error = "item not ready: \(String(describing: item.error))"; player.replaceCurrentItem(with: nil); finish(); return }
            _ = await LaneSelfTest.waitUntil(2) { view.playerLayer.isReadyForDisplay }
            result.layerReadyForDisplay = view.playerLayer.isReadyForDisplay
            result.windowVisible = window.isVisible && window.occlusionState.contains(.visible)
            try await Task.sleep(nanoseconds: 500_000_000)
            let sampler = Sampler(player: player, output: output, start: began)
            let link = view.displayLink(target: sampler, selector: #selector(Sampler.tick(_:)))
            link.add(to: .main, forMode: .common)
            mark("seekRequested", "to 0, tolerance zero")
            let finished = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            mark("seekCompleted", "finished \(finished) item time \(item.currentTime().seconds)")
            player.play()
            mark("playCalled", "rate \(player.rate)")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            player.pause()
            mark("paused", "item frame \(item.currentTime().seconds * 30)")
            link.invalidate()
            player.replaceCurrentItem(with: nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            func frameNumber(_ t: CMTime) -> Int { Int((t.seconds * 30).rounded()) }
            result.ticks = sampler.ticks
            result.videoOutputFrames = sampler.frames.prefix(40).map { "\($0.frame)@\(String(format: "%.0f", $0.ms))ms" }
            let available = Set(sampler.frames.map(\.frame))
            if mode == "default" {
                result.frame2 = !videoOutput ? "Inconclusive" : (available.contains(2) ? "Available but not observed on screen" : "Inconclusive")
                result.frame2Basis = videoOutput ? "built-in compositor has no request record; video output \(available.contains(2) ? "delivered" : "did not deliver within sampling") frame 2" : "built-in compositor has no request record and no video output was attached"
            } else {
                let outcomes = log.requestOutcomes
                result.requestOrder = Array(log.receivedTimes.map(frameNumber).prefix(40))
                result.finishedFrames = Array(outcomes.filter { $0.outcome == .finished }.map { frameNumber($0.time) }.prefix(60))
                result.cancelledFrames = outcomes.filter { $0.outcome == .cancelled }.map { frameNumber($0.time) }
                result.failedRequests = outcomes.filter { $0.outcome == .failed }.count
                let entries = log.snapshot.entries
                result.firstRequests = entries.prefix(10).map { String(format: "t%d received %.0f ms rendered in %.1f ms", frameNumber($0.time), ($0.received - began) * 1000, ($0.rendered - $0.received) * 1000) }
                let requested = log.receivedTimes.map(frameNumber).contains(2)
                let done = outcomes.contains { frameNumber($0.time) == 2 && $0.outcome == .finished }
                let cancelled = outcomes.contains { frameNumber($0.time) == 2 && $0.outcome == .cancelled }
                if !requested { result.frame2 = "Not requested"; result.frame2Basis = "no compositor request for frame 2 in the request record" }
                else if !done && cancelled { result.frame2 = "Requested and cancelled"; result.frame2Basis = "request record" }
                else if done && videoOutput && !available.contains(2) { result.frame2 = "Rendered but not made available for display"; result.frame2Basis = "completed request; video output did not deliver frame 2 within display-rate sampling (a sampling miss cannot be excluded)" }
                else if done && videoOutput { result.frame2 = "Available but not observed on screen"; result.frame2Basis = "completed request and video output delivery; no screen evidence is collected" }
                else if done { result.frame2 = "Inconclusive"; result.frame2Basis = "request completed; no video output attached and no screen evidence" }
                else { result.frame2 = "Inconclusive"; result.frame2Basis = "requested, neither completed nor cancelled within the observation" }
            }
            withExtendedLifetime([a, b, c, music]) {}
        } catch { result.error = "\(error)" }
        finish()
    }
}
#endif
