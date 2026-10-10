// E2 4K 컷 편집 프리뷰 실행기(실험용 최소 창, 제품 UI 아님).
// 사용(experiments/e2-4k 디렉터리에서, 먼저 `.build/release/e2 fixtures` 또는 `e2 all`):
//   .build/release/e2preview auto              자동 검사(창이 잠깐 뜸, volume 0) → results/e2-preview-<시각>.json
//   .build/release/e2preview window [--muted]  소유자 관찰용 창(AVPlayerView, 소리 켬)
// 층 구분: 합성기 요청(E2Log) / 비디오 출력 전달 버퍼(AVPlayerItemVideoOutput) / AVPlayerLayer 표시 버퍼(일시정지 중) / 실제 화면(소유자 관찰).
import AppKit
import AVFoundation
import AVKit
import CoreMedia
import E1Core
import E2Core
import E2Expect
import E2Judge
import Foundation
import QuartzCore

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func sleepMs(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
func mib(_ b: UInt64) -> Double { Double(b) / 1_048_576 }
func loadAvg() -> [Double] { var l = [Double](repeating: -1, count: 3); _ = getloadavg(&l, 3); return l }
/// 정지 시각 t를 포함하는 프레임(내림)
func floorIndex(_ t: CMTime) -> Int { Int((t.seconds * 30 + 1e-9).rounded(.down)) }

// MARK: - 비디오 출력 전달 버퍼 관찰

/// 안전성(@unchecked Sendable): output·timer·폴링 상태는 직렬 queue에서만, records는 lock 안에서만 접근한다.
final class Capture: @unchecked Sendable {
    struct Delivered: Sendable { let timeIndex: Int; let exact: Bool; let metrics: E2Metrics?; let host: Double; let polledItem: Double }
    let output: AVPlayerItemVideoOutput
    private let queue = DispatchQueue(label: "e2.capture")
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var records: [Delivered] = []
    private var lastPoll = 0.0
    private var gaps: [Double] = []
    init(output: AVPlayerItemVideoOutput) { self.output = output }

    func start() {
        queue.sync {
            lastPoll = 0
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume(); timer = t
        }
    }
    func stop() { queue.sync { timer?.cancel(); timer = nil } }
    func reset() { lock.lock(); records = []; lock.unlock(); queue.sync { gaps = []; lastPoll = 0 } }
    func snapshot() -> [Delivered] { lock.lock(); defer { lock.unlock() }; return records }
    func pollGaps() -> [Double] { queue.sync { gaps } }

    private func poll() {
        let host = CACurrentMediaTime()
        if lastPoll > 0, host - lastPoll > 0.020 { gaps.append((host - lastPoll) * 1000) }
        lastPoll = host
        let it = output.itemTime(forHostTime: host)
        if output.hasNewPixelBuffer(forItemTime: it) { _ = grab(it, host: host) }
    }
    private func grab(_ it: CMTime, host: Double) -> Delivered? {
        var disp = CMTime.invalid
        guard let pb = output.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: &disp), disp.isNumeric else { return nil }
        let (n, exact) = E2Compositor.frameIndex(disp)
        let d = Delivered(timeIndex: n, exact: exact, metrics: E2Metrics.measure(pb), host: host, polledItem: it.seconds)
        lock.lock(); records.append(d); lock.unlock()
        return d
    }
    /// 일시정지 상태에서 시각 t의 새 프레임을 기다린다.
    func fetch(at t: CMTime, timeoutMs: Int) async -> Delivered? {
        await withCheckedContinuation { (k: CheckedContinuation<Delivered?, Never>) in
            queue.async { [self] in
                let deadline = CACurrentMediaTime() + Double(timeoutMs) / 1000
                while CACurrentMediaTime() < deadline {
                    if output.hasNewPixelBuffer(forItemTime: t), let d = grab(t, host: CACurrentMediaTime()) { k.resume(returning: d); return }
                    usleep(4_000)
                }
                k.resume(returning: nil)
            }
        }
    }
}

// MARK: - 재생 구성

/// 재생 구성 선택(진단 비교용). 기본값이 지금까지의 구성이다.
struct HarnessOptions {
    var allowFrameReordering = true          // false: 재정렬 끈 비교 fixture
    var waitsToMinimizeStalling = false      // AVPlayer.automaticallyWaitsToMinimizeStalling
    var timingFromSourceTrack = true         // 수정된 구성(기본). false = 수정 전 frameDuration 타이밍(결함 재현용, --frame-duration-timing)
    var seekingWaitsForComposition = false   // AVPlayerItem.seekingWaitsForVideoCompositionRendering
    var diagnoseSource = false
    var label: String {
        [allowFrameReordering ? "reorder" : "noreorder", waitsToMinimizeStalling ? "waits" : nil, timingFromSourceTrack ? "timingTrack" : "frameDurationTiming",
         seekingWaitsForComposition ? "seekingWaits" : nil].compactMap { $0 }.joined(separator: "+")
    }
    static func parse(_ a: [String]) -> HarnessOptions {
        var o = HarnessOptions()
        o.allowFrameReordering = !a.contains("--no-reorder"); o.waitsToMinimizeStalling = a.contains("--waits")
        o.timingFromSourceTrack = !a.contains("--frame-duration-timing"); o.seekingWaitsForComposition = a.contains("--seeking-waits")
        return o
    }
}

@MainActor
final class Harness {
    let env: E2Env
    let bundle: E2Bundle
    let log: E2Log
    let item: AVPlayerItem
    let player: AVPlayer
    let capture: Capture

    init(env: E2Env, bundle: E2Bundle, log: E2Log, muted: Bool, options: HarnessOptions = HarnessOptions()) {
        self.env = env; self.bundle = bundle; self.log = log
        item = AVPlayerItem(asset: bundle.composition)
        item.videoComposition = bundle.videoComposition   // 프레임 타이밍 선택은 composition 구성(공유 함수)에서 한다
        item.seekingWaitsForVideoCompositionRendering = options.seekingWaitsForComposition
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = options.waitsToMinimizeStalling
        if muted { player.volume = 0 }
        capture = Capture(output: out)
    }

    static func make(muted: Bool, options: HarnessOptions = HarnessOptions()) async throws -> Harness {
        let env = try await E2Env.load(root: root, allowFrameReordering: options.allowFrameReordering)
        let log = E2Log(fingerprints: true, diagnoseSource: options.diagnoseSource)
        let h = Harness(env: env, bundle: try await env.makeBundle(log: log, frameTimingFromSourceTrack: options.timingFromSourceTrack),
                        log: log, muted: muted, options: options)
        for _ in 0..<1000 {
            if h.item.status == .readyToPlay { return h }
            if h.item.status == .failed { throw E1Error.render("item failed: \(h.item.error?.localizedDescription ?? "-")") }
            await sleepMs(10)
        }
        throw E1Error.render("item not ready")
    }

    @discardableResult func seekExact(_ t: CMTime) async -> Bool { await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) }
    var now: CMTime { player.currentTime() }

    func stepAndWait(_ k: Int) async -> CMTime {
        let before = now
        item.step(byCount: k)
        for _ in 0..<300 { if now != before { await sleepMs(20); return now }; await sleepMs(5) }
        return now
    }
}

@MainActor
func makeWindow(_ h: Harness) -> (NSWindow, AVPlayerView, NSTextField) {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                     backing: .buffered, defer: false)
    w.title = "E2 Preview — 4K 컷 편집 (실험용, 제품 UI 아님)"
    w.isReleasedWhenClosed = false
    let pv = AVPlayerView(frame: w.contentLayoutRect)
    pv.autoresizingMask = [.width, .height]
    pv.controlsStyle = .inline
    pv.showsFrameSteppingButtons = true
    pv.player = h.player
    let l = NSTextField(labelWithString: "")
    l.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
    l.textColor = .white; l.backgroundColor = NSColor.black.withAlphaComponent(0.6); l.drawsBackground = true
    l.frame = NSRect(x: 12, y: 12, width: 640, height: 22)
    pv.contentOverlayView?.addSubview(l)
    w.contentView = pv
    w.center(); w.makeKeyAndOrderFront(nil); w.orderFrontRegardless()
    return (w, pv, l)
}

/// AVPlayerView 레이어 트리에서 이 플레이어의 AVPlayerLayer를 찾는다(비공개 구조라 못 찾으면 nil).
@MainActor
func findPlayerLayer(_ layer: CALayer?, player: AVPlayer) -> AVPlayerLayer? {
    guard let layer else { return nil }
    if let pl = layer as? AVPlayerLayer, pl.player === player { return pl }
    for s in layer.sublayers ?? [] { if let f = findPlayerLayer(s, player: player) { return f } }
    return nil
}

/// 일시정지 중 레이어 표시 버퍼가 시각 프레임 n의 기대 내용이 될 때까지 기다린다.
@MainActor
func layerShows(_ layer: AVPlayerLayer, timeIndex n: Int, timeoutMs: Int) async -> (issues: [String], ms: Double, metrics: E2Metrics?) {
    let t0 = CACurrentMediaTime()
    var last: E2Metrics?
    while (CACurrentMediaTime() - t0) * 1000 < Double(timeoutMs) {
        if let pb = layer.displayedPixelBuffer(), let m = E2Metrics.measure(pb) {
            last = m
            if m.timelineCode == Expect2.contentFrame(n) { return (Judge.frameIssues(timeIndex: n, m), (CACurrentMediaTime() - t0) * 1000, m) }
        }
        await sleepMs(5)
    }
    return (["timeout; last \(last.map { "\($0.timelineCode)/\($0.sourceKey)\($0.sourceFrame)" } ?? "nil")"], (CACurrentMediaTime() - t0) * 1000, last)
}

// MARK: - 자동 검사

@MainActor
func playThrough(_ h: Harness) async -> (wall: Double, reached: Bool) {
    await h.seekExact(.zero)
    h.capture.reset(); h.log.reset(); h.capture.start()
    let t0 = CACurrentMediaTime()
    h.player.play()
    var reached = false
    while CACurrentMediaTime() - t0 < 15 {
        if h.now >= h.item.duration { reached = true; break }
        await sleepMs(5)
    }
    let wall = CACurrentMediaTime() - t0
    await sleepMs(300)
    h.capture.stop(); h.player.pause()
    return (wall, reached)
}

@MainActor
func playbackCheck(_ r: Report, _ h: Harness, rep: Int) async -> [Int: String] {
    let fp0 = Memory.physFootprint()
    let load0 = loadAvg()
    let (wall, reached) = await playThrough(h)
    let del = h.capture.snapshot(), snap = h.log.snapshot()
    var issues: [String] = []
    var byFrame: [Int: E2Metrics] = [:]
    for d in del {
        issues += Judge.frameIssues(timeIndex: d.timeIndex, d.metrics).map { "\(d.timeIndex): \($0)" }
        if d.timeIndex < 300, let m = d.metrics { byFrame[d.timeIndex] = m }
    }
    let requested = Set(snap.entries.map { $0.frame }.filter { $0 >= 0 && $0 < 300 })
    let delivered = Set(del.map { $0.timeIndex }.filter { $0 >= 0 && $0 < 300 })
    let notRequested = (0..<300).filter { !requested.contains($0) }
    let requestedNotDelivered = (0..<300).filter { requested.contains($0) && !delivered.contains($0) }
    let end = del.filter { $0.timeIndex == 300 }
    let (specOK, specDetail) = Judge.spectrum(byFrame)
    let gaps = h.capture.pollGaps()
    r.check("V1-\(rep)", "재생 0→끝(4K, volume 0, 창 부착): 비디오 출력 전달 프레임마다 타임라인·소스·소스 프레임·상자·자막 = 독립 기대값, 끝 시각 프레임 = 299 유지, 합성기 오류 0. 누락 개수는 기록(기준 없음)",
            pass: issues.isEmpty && reached && snap.errors.isEmpty && end.allSatisfy { $0.metrics?.timelineCode == 299 },
            ["wallSeconds": wall, "reachedEnd": reached, "issues": Array(issues.prefix(20)), "compositorRequests": snap.entries.count,
             "requestedUnique": requested.count, "notRequested": notRequested.count, "notRequestedFrames": Array(notRequested.prefix(30)),
             "delivered": del.count, "deliveredUnique": delivered.count,
             "requestedButNotDelivered": requestedNotDelivered.count, "requestedButNotDeliveredFrames": Array(requestedNotDelivered.prefix(30)),
             "inexactRequests": snap.entries.filter { !$0.exact }.map { "\($0.frame)@\($0.timeValue)/\($0.timescale)" },
             "staleSourceFrames": snap.entries.filter { $0.sourceTimeMatches == false }.map { $0.frame },
             "staleSourceDetail": snap.entries.filter { $0.sourceTimeMatches == false }.map { "request \($0.timeValue)/\($0.timescale) movieTime \($0.sourceMovieTime ?? "-")" },
             "firstRequests": snap.entries.prefix(6).map { "\($0.frame)@\($0.timeValue)/\($0.timescale) mt \($0.sourceMovieTime ?? "-")" },
             "sourceMovieTimeMissing": snap.entries.filter { $0.sourceTimeMatches == nil && !$0.usedHeld }.count,
             "duplicateRequestFrames": Dictionary(grouping: snap.entries, by: { $0.frame }).filter { $0.value.count > 1 }.keys.sorted(),
             "endTimeDelivered": end.count, "endUsedHeld": snap.entries.filter { $0.usedHeld }.count,
             "sourceFrameNilRequests": snap.entries.filter { $0.sourceFrameNil }.map { $0.frame },
             "copyMs": stats(snap.entries.map { $0.copyMs }), "overlayMs": stats(snap.entries.map { $0.overlayMs }),
             "maxInFlight": snap.maxInFlight, "pollGapsOver20ms": gaps.count, "pollGapMaxMs": gaps.max() ?? 0,
             "pollLatenessMs": stats(del.map { ($0.polledItem - Double($0.timeIndex) / 30) * 1000 }),
             "footprintMiB": [mib(fp0), mib(Memory.physFootprint())], "loadAvgBefore": load0, "loadAvgAfter": loadAvg()])
    r.check("V2-\(rep)", "재생 중 전달 프레임의 스펙트럼: 선택 오디오 톤·무음·클릭 반응, 클립 오디오 밴드 0(전달된 프레임만 판정)", pass: specOK, specDetail)
    var fps: [Int: String] = [:]
    for e in snap.entries where e.frame >= 0 && e.frame < 300 { if let f = e.fingerprint { fps[e.frame] = f } }
    return fps
}

@MainActor
func seekChecks(_ r: Report, _ h: Harness, layer: AVPlayerLayer?) async {
    enum Move { case seek(Int), step(Int) }
    let plan: [(String, Move, Int)] = [
        ("start", .seek(0), 0), ("A last 89", .seek(89), 89), ("C first 90", .seek(90), 90), ("C last 179", .seek(179), 179),
        ("B.1 first 180", .seek(180), 180), ("B.1 last 239", .seek(239), 239), ("B.2 first 240", .seek(240), 240),
        ("back across cut → 45", .seek(45), 45), ("forward far → 270", .seek(270), 270), ("near end 299", .seek(299), 299),
        ("end 300", .seek(300), 300), ("step back", .step(-1), 299), ("step back", .step(-1), 298), ("back to 0", .seek(0), 0),
    ]
    h.player.pause()
    h.capture.reset()
    var rows: [[String: Any]] = []
    var ok = layer != nil
    for (name, move, n) in plan {
        let t0 = CACurrentMediaTime()
        var t = Spec4K.frameTime(n)
        var finished = true
        switch move {
        case .seek: finished = await h.seekExact(t)
        case .step(let k): t = await h.stepAndWait(k)
        }
        let seekMs = (CACurrentMediaTime() - t0) * 1000
        let d = await h.capture.fetch(at: t, timeoutMs: 2000)
        let outMs = (CACurrentMediaTime() - t0) * 1000
        // 정확 탐색·프레임 이동 뒤의 플레이어 시각은 프레임 시각이어야 하므로 가장 가까운 프레임으로 비교한다.
        // 기록(…004002Z): 내림을 쓰면 프레임 이동 뒤 시각(298/30보다 아주 조금 작음)이 297로 읽혀 검사가 틀렸다.
        let playerIdx = E2Compositor.frameIndex(t).0
        var row: [String: Any] = ["move": name, "target": n, "playerTimeIndex": playerIdx, "playerSeconds": t.seconds, "finished": finished, "seekMs": seekMs, "outputReadyMs": outMs]
        let outIssues = d == nil ? ["no delivered frame"] : Judge.frameIssues(timeIndex: n, d!.metrics)
        row["output"] = d?.metrics.map { "\($0.timelineCode) \($0.sourceKey)\($0.sourceFrame)" } ?? "none"
        row["outputIssues"] = outIssues
        if let layer {
            let (li, lms, lm) = await layerShows(layer, timeIndex: n, timeoutMs: 2000)
            row["layer"] = lm.map { "\($0.timelineCode) \($0.sourceKey)\($0.sourceFrame)" } ?? "none"
            row["layerIssues"] = li
            row["layerReadyAfterOutputMs"] = lms
            if !li.isEmpty { ok = false }
        }
        if !outIssues.isEmpty || !finished || playerIdx != n { ok = false }
        rows.append(row)
    }
    r.check("S1", "일시정지 탐색(컷 경계 양쪽 89/90·179/180·239/240, 앞뒤로 크게, 끝 299·300, 끝에서 프레임 단위로 두 번 뒤로): 비디오 출력과 AVPlayerLayer 표시 버퍼가 모두 기대 소스·프레임(끝 시각은 299 유지)",
            pass: ok, ["playerLayerFound": layer != nil, "moves": rows,
                       "seekMs": stats(rows.map { $0["seekMs"] as! Double }), "outputReadyMs": stats(rows.map { $0["outputReadyMs"] as! Double })])
}

@MainActor
func endAndReplay(_ r: Report, _ h: Harness, layer: AVPlayerLayer?) async {
    guard let layer else { r.check("E1", "끝까지 재생·다시 재생(레이어)", pass: false, ["error": "AVPlayerLayer not found"]); return }
    await h.seekExact(Spec4K.frameTime(285))
    h.player.play()
    let t0 = CACurrentMediaTime()
    while h.player.rate != 0 && CACurrentMediaTime() - t0 < 3 { await sleepMs(10) }
    let endIdx = E2Compositor.frameIndex(h.now).0
    let (ei, _, em) = await layerShows(layer, timeIndex: endIdx, timeoutMs: 2000)
    await h.seekExact(.zero)
    h.capture.reset(); h.capture.start()
    let replayHost = CACurrentMediaTime()
    h.player.play()
    await sleepMs(1000)
    h.player.pause()
    await sleepMs(100)
    h.capture.stop()
    // n/30 사이에서 멈춘 경우 레이어는 그 시각의 프레임 또는 다음 프레임을 보여 줄 수 있다(기록 …004002Z: 시각 내림 24, 표시 25).
    // 판정: 표시 프레임의 타임라인 코드가 정지 시각 ±1 프레임 안이고, 그 코드에 대해 내용이 기대값과 같다(끝 화면 잔상이 아님).
    let reN = floorIndex(h.now)
    // 정지 뒤 레이어 표시 버퍼가 새 프레임으로 바뀔 때까지 최대 2 s 기다린다(2026-10-10 수정: 200 ms 뒤 한 번만 읽던 방식은
    // …025328Z에서 끝 화면 299를 읽었다. 같은 재생의 비디오 출력은 0부터 정상이었다). 2 s 뒤에도 정지 시각 ±1이 아니면 실패다.
    var rm: E2Metrics?
    let w0 = CACurrentMediaTime()
    while CACurrentMediaTime() - w0 < 2 {
        rm = layer.displayedPixelBuffer().flatMap { E2Metrics.measure($0) }
        if let m = rm, abs(m.timelineCode - reN) <= 1 { break }
        await sleepMs(20)
    }
    let layerWaitMs = (CACurrentMediaTime() - w0) * 1000
    var ri: [String] = []
    if let m = rm {
        if abs(m.timelineCode - reN) > 1 { ri.append("layer timeline \(m.timelineCode) not within ±1 of paused \(reN)") }
        ri += Judge.frameIssues(timeIndex: m.timelineCode, m)
    } else { ri.append("no displayed buffer") }
    let replayDel = h.capture.snapshot().filter { $0.host >= replayHost }
    let firstAfter = replayDel.min { $0.host < $1.host }
    r.check("E1", "끝까지 재생 후 정지 화면(레이어) = 299(B 209) 유지, 처음부터 다시 재생: 첫 전달 프레임 0, 1 s 뒤 정지 화면 = 그 시각 프레임(끝 화면 잔상 없음)",
            pass: endIdx == 300 && ei.isEmpty && ri.isEmpty && reN > 0 && firstAfter?.timeIndex == 0
                && replayDel.allSatisfy { Judge.frameIssues(timeIndex: $0.timeIndex, $0.metrics).isEmpty },
            ["endTimeIndex": endIdx, "endLayer": em.map { "\($0.timelineCode) \($0.sourceKey)\($0.sourceFrame)" } ?? "nil", "endIssues": ei,
             "replayLayerWaitMs": layerWaitMs, "replayPausedAt": reN, "replayLayer": rm.map { "\($0.timelineCode) \($0.sourceKey)\($0.sourceFrame)" } ?? "nil", "replayIssues": ri,
             "replayFirstDelivered": firstAfter?.timeIndex ?? -1, "replayDelivered": replayDel.count])
}

@MainActor
func seekWhilePlaying(_ r: Report, _ h: Harness) async {
    await h.seekExact(Spec4K.frameTime(60))
    h.capture.reset(); h.capture.start()
    h.player.play()
    await sleepMs(800)
    var seeks: [(String, Int, Double, Double)] = []
    for (name, target, dwell) in [("→ 177 (cut 180 직전)", 177, 1000), ("→ 85 (뒤로, cut 90 직전)", 85, 1000), ("→ 236 (cut 240 직전)", 236, 1000), ("→ 290 (끝 근처)", 290, 1200)] {
        let s0 = CACurrentMediaTime()
        await h.seekExact(Spec4K.frameTime(target))
        seeks.append((name, target, s0, CACurrentMediaTime()))
        await sleepMs(dwell)
    }
    h.capture.stop(); h.player.pause()
    let all = h.capture.snapshot()
    var ok = true
    var rows: [[String: Any]] = []
    for (i, s) in seeks.enumerated() {
        let next = i + 1 < seeks.count ? seeks[i + 1].2 : .infinity
        let after = all.filter { $0.host > s.3 && $0.host < next }
        let stale = after.filter { $0.timeIndex < s.1 }
        let wrong = after.filter { !Judge.frameIssues(timeIndex: $0.timeIndex, $0.metrics).isEmpty }
        let first = after.min { $0.host < $1.host }
        if !stale.isEmpty || !wrong.isEmpty || after.isEmpty { ok = false }
        rows.append(["seek": s.0, "target": s.1, "seekMs": (s.3 - s.2) * 1000, "framesAfter": after.count, "stale": stale.count,
                     "wrongContent": wrong.count, "firstFrame": first?.timeIndex ?? -1,
                     "firstFrameLatencyMs": first.map { ($0.host - s.3) * 1000 } ?? -1])
    }
    r.check("S2", "재생 중 탐색(컷 직전으로 앞·뒤, 끝 근처): 탐색 완료 뒤 이전 위치 프레임 없음, 전달 프레임 내용 = 기대값. 첫 프레임까지 시간 기록",
            pass: ok, ["seeks": rows])
}

/// 프리뷰 합성기 출력과 오프라인(내보내기와 같은 읽기 경로) 합성기 출력의 표본 지문 비교
@MainActor
func offlineMatch(_ r: Report, _ h: Harness, playback: [Int: String]) async {
    do {
        let log = E2Log(fingerprints: true)
        let b = try await h.env.makeBundle(log: log)
        let reader = try AVAssetReader(asset: b.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: Spec4K.frameTime(300))
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: b.composition.tracks(withMediaType: .video),
                                                      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = b.videoComposition
        reader.add(out)
        guard reader.startReading() else { throw E1Error.reader("offline") }
        var offline: [Int: String] = [:]
        var n = 0
        while let sb = out.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sb) { offline[n] = Fingerprint.sampled(pb) }
            n += 1
        }
        let common = Set(playback.keys).intersection(offline.keys).sorted()
        let differ = common.filter { playback[$0] != offline[$0] }
        r.check("O1", "같은 타임라인 해석: 재생 중 합성기 출력과 오프라인 합성기 출력(내보내기와 같은 읽기 경로)의 표본 지문(4행마다 1행 SHA-256)이 같은 프레임에서 일치",
                pass: !common.isEmpty && differ.isEmpty,
                ["framesCompared": common.count, "differ": differ.count, "differFrames": Array(differ.prefix(20)), "offlineFrames": n])
    } catch { r.check("O1", "같은 타임라인 해석(지문 비교)", pass: false, ["error": "\(error)"]) }
}

@MainActor
final class AutoApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let r = Report()
            let id = runID()
            let started = Date()
            do {
                let h = try await Harness.make(muted: true)
                r.sections["build"] = h.env.buildIdentity()
                r.sections["run"] = ["id": id, "os": ProcessInfo.processInfo.operatingSystemVersionString, "volume": 0, "loadAvgStart": loadAvg(),
                                     "window": "AVPlayerView 1280×760 (window 모드와 같은 구성)", "startFootprintMiB": mib(Memory.physFootprint())]
                r.sections["fixtures"] = h.env.fixtureInfo
                let (w, pv, _) = makeWindow(h)
                await sleepMs(500)
                let layer = findPlayerLayer(pv.layer, player: h.player)
                var fps: [Int: String] = [:]
                for i in 1...2 { fps = await playbackCheck(r, h, rep: i) }
                await seekChecks(r, h, layer: layer)
                await endAndReplay(r, h, layer: layer)
                await seekWhilePlaying(r, h)
                await offlineMatch(r, h, playback: fps)
                r.sections["endFootprintMiB"] = mib(Memory.physFootprint())
                w.close()
                h.player.replaceCurrentItem(with: nil)
            } catch { r.check("ABORT", "실행 중단", pass: false, ["error": "\(error)"]) }
            r.sections["wallSecondsTotal"] = Date().timeIntervalSince(started)
            let url = root.appendingPathComponent("results").appendingPathComponent("e2-preview-\(id).json")
            do { try r.write(to: url); print("results: results/\(url.lastPathComponent)") } catch { print("write failed \(error)") }
            exit(r.summary.fail.isEmpty ? 0 : 1)   // terminate를 먼저 부르면 종료 코드가 항상 0이 된다(…004002Z)
        }
    }
}

// MARK: - 진단: 탐색 직후 재생 시작에서 소스 프레임 어긋남

/// 탐색 뒤 바로 재생할 때 시작 부근 프레임의 소스가 기대와 다른지 조건별로 본다(각 조건 3회).
@MainActor
final class DiagApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let r = Report()
            let id = runID()
            do {
                let h = try await Harness.make(muted: true)
                r.sections["build"] = h.env.buildIdentity()
                r.sections["run"] = ["id": id, "loadAvgStart": loadAvg(), "window": "AVPlayerView 1280×760"]
                let (w, _, _) = makeWindow(h)
                await sleepMs(500)
                // (이름, 시작 전 위치, 탐색 목표, 탐색 뒤 대기 ms)
                // 대기 ms가 −1이면 player.preroll(atRate: 1) 완료 뒤 재생
                let variants: [(String, Int, Int, Int)] = [
                    ("end→90 즉시 재생(C 시작)", 300, 90, 0), ("end→240 즉시 재생(B.2 시작)", 300, 240, 0),
                    ("end→0 preroll 뒤 재생", 300, 0, -1),
                    ("end→0 즉시 재생", 300, 0, 0), ("end→0 500 ms 뒤 재생", 300, 0, 500), ("150→0 즉시 재생", 150, 0, 0),
                    ("0→0 즉시 재생(같은 위치)", 0, 0, 0), ("end→60 즉시 재생", 300, 60, 0), ("end→180 즉시 재생(B.1 시작)", 300, 180, 0),
                ]
                for (name, from, to, waitMs) in variants {
                    var rows: [[String: Any]] = []
                    for _ in 0..<3 {
                        await h.seekExact(Spec4K.frameTime(from)); await sleepMs(300)
                        await h.seekExact(Spec4K.frameTime(to))
                        if waitMs > 0 { await sleepMs(waitMs) }
                        if waitMs < 0 { _ = await h.player.preroll(atRate: 1) }
                        h.capture.reset(); h.log.reset(); h.capture.start()
                        h.player.play()
                        await sleepMs(700)
                        h.player.pause(); h.capture.stop()
                        let del = h.capture.snapshot().filter { $0.timeIndex >= to && $0.timeIndex < to + 15 }
                        let bad = del.filter { !Judge.frameIssues(timeIndex: $0.timeIndex, $0.metrics).isEmpty }
                            .map { "t\($0.timeIndex)→\($0.metrics.map { "\($0.sourceKey)\($0.sourceFrame)" } ?? "?")" }
                        rows.append(["delivered": del.count, "wrong": bad, "requests": h.log.snapshot().entries.prefix(6).map { "\($0.frame)" }])
                    }
                    let wrongRuns = rows.filter { !($0["wrong"] as! [String]).isEmpty }.count
                    r.check("D-\(name)", "탐색 뒤 재생 시작 \(name): 시작 15프레임의 전달 내용 = 기대값(3회 중 어긋난 횟수 기록)", pass: nil,
                            ["runs": rows, "runsWithWrongSource": wrongRuns])
                }
                w.close()
            } catch { r.check("ABORT", "실행 중단", pass: false, ["error": "\(error)"]) }
            let url = root.appendingPathComponent("results").appendingPathComponent("e2-diag-start-\(id).json")
            try? r.write(to: url)
            print("results: results/\(url.lastPathComponent)")
            exit(0)
        }
    }
}

// MARK: - 진단: 합성기가 받은 소스 프레임(층별)

/// 시작 위치별로: 요청 시각, 독립 기대 소스·소스 프레임, 합성기가 받은 소스 버퍼의 코드(소스 픽셀에서 디코딩), IOSurface ID,
/// 비디오 출력이 돌려준 프레임의 소스 코드를 기록한다. 오버레이(타임라인 코드)로 소스 정확성을 추론하지 않는다.
@MainActor
final class DiagSourceApp: NSObject, NSApplicationDelegate {
    let options: HarnessOptions
    let reps: Int
    init(options: HarnessOptions, reps: Int) { self.options = options; self.reps = reps }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let r = Report()
            let id = runID()
            do {
                var o = options; o.diagnoseSource = true
                let h = try await Harness.make(muted: true, options: o)
                r.sections["build"] = h.env.buildIdentity()
                r.sections["run"] = ["id": id, "options": o.label, "loadAvgStart": loadAvg(), "window": "AVPlayerView 1280×760", "repsPerStart": reps,
                                     "playerWaitsToMinimizeStalling": h.player.automaticallyWaitsToMinimizeStalling,
                                     "sourceTrackIDForFrameTiming": h.item.videoComposition?.sourceTrackIDForFrameTiming ?? -1,
                                     "seekingWaitsForVideoCompositionRendering": h.item.seekingWaitsForVideoCompositionRendering]
                r.sections["fixtures"] = h.env.fixtureInfo
                let (w, _, _) = makeWindow(h)
                await sleepMs(500)
                // (이름, 시작 타임라인 프레임) — 실패 보고 위치 A30·A90·B150, 대조 B0(파일 시작)·C20(키프레임 아님)
                let starts: [(String, Int)] = [("A30", 0), ("A90", 60), ("B150", 240), ("B0", 180), ("C20", 90)]
                var total = 0, mismatchRuns = 0
                for (name, start) in starts {
                    var runs: [[String: Any]] = []
                    for _ in 0..<reps {
                        await h.seekExact(Spec4K.frameTime(300)); await sleepMs(200)
                        await h.seekExact(Spec4K.frameTime(start))
                        h.capture.reset(); h.log.reset(); h.capture.start()
                        h.player.play()
                        await sleepMs(700)
                        h.player.pause(); h.capture.stop()
                        let entries = h.log.snapshot().entries.filter { $0.frame >= start && $0.frame < start + 12 }
                        var rows: [String] = []
                        var bad: [String] = []
                        for e in entries {
                            guard let (src, f) = Expect2.source(at: e.content) else { continue }
                            let got = e.receivedSourceID.flatMap { E2Metrics.sourceKeyByID[$0] } ?? "?"
                            let gf = e.receivedSourceFrame ?? -1
                            let ok = got == src && gf == f
                            rows.append("t\(e.frame)@\(e.timeValue)/\(e.timescale) want \(src)\(f) got \(got)\(gf) sfc \(e.sourceSurfaceID ?? 0) mt \(e.sourceMovieTime ?? "-")\(ok ? "" : " ✗")")
                            if !ok { bad.append("t\(e.frame): \(got)\(gf) != \(src)\(f)") }
                        }
                        let out = h.capture.snapshot().filter { $0.timeIndex >= start && $0.timeIndex < start + 12 }
                        let outBad = out.filter { !Judge.frameIssues(timeIndex: $0.timeIndex, $0.metrics).isEmpty }
                            .map { "t\($0.timeIndex): \($0.metrics.map { "\($0.sourceKey)\($0.sourceFrame)" } ?? "?")" }
                        total += 1
                        if !bad.isEmpty || !outBad.isEmpty { mismatchRuns += 1 }
                        runs.append(["compositorReceived": rows, "compositorMismatch": bad, "videoOutputMismatch": outBad, "videoOutputFrames": out.count])
                    }
                    let n = runs.filter { !($0["compositorMismatch"] as! [String]).isEmpty || !($0["videoOutputMismatch"] as! [String]).isEmpty }.count
                    r.check("DS-\(name)", "시작 \(name)(타임라인 \(start)) \(o.label): 합성기가 받은 소스 = 기대 소스(\(reps)회 중 어긋난 횟수)", pass: nil,
                            ["runsWithMismatch": n, "runs": runs])
                }
                r.sections["sourceBufferAttachmentKeys"] = h.log.sourceAttachmentKeys
                r.sections["summary2"] = ["runs": total, "runsWithMismatch": mismatchRuns]
                w.close()
            } catch { r.check("ABORT", "실행 중단", pass: false, ["error": "\(error)"]) }
            let url = root.appendingPathComponent("results").appendingPathComponent("e2-diag-source-\(options.label)-\(id).json")
            try? r.write(to: url)
            print("results: results/\(url.lastPathComponent)")
            exit(0)
        }
    }
}

// MARK: - 진단: 새 프로세스의 첫 재생(auto V1-1과 같은 순서) + 같은 프로세스의 다시 재생(대조)

/// auto의 첫 재생과 같은 순서(로드 → 창 → 500 ms → 0으로 정확 탐색 → 재생)를 따르되, 합성기 기록을 지우지 않고
/// 첫 요청부터 순서·시각·받은 소스(시각 첨부, 진단 시 소스 픽셀 코드)·취소를 모두 남긴다. 이어서 같은 프로세스에서
/// 0으로 탐색 후 다시 재생(대조)한다. 각 재생은 1.2 s로 짧게 한다.
@MainActor
final class DiagFreshApp: NSObject, NSApplicationDelegate {
    let options: HarnessOptions
    init(options: HarnessOptions) { self.options = options }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let t0 = Clock.now()
            let mediaT0 = CACurrentMediaTime()
            func ms(_ ns: UInt64) -> Double { Double(Int64(ns) - Int64(t0)) / 1e6 }
            let r = Report()
            let id = runID()
            do {
                let h = try await Harness.make(muted: true, options: options)
                h.log.event("harness ready (item readyToPlay), player time \(h.now.value)/\(h.now.timescale) rate \(h.player.rate)")
                r.sections["build"] = h.env.buildIdentity()
                r.sections["fixtures"] = h.env.fixtureInfo
                r.sections["run"] = ["id": id, "options": options.label, "diagnoseSourcePixels": options.diagnoseSource, "loadAvgStart": loadAvg(),
                                     "frameTiming": h.item.videoComposition?.sourceTrackIDForFrameTiming == h.bundle.videoTrackID ? "video track" : "frameDuration",
                                     "videoTrackID": h.bundle.videoTrackID, "waitsToMinimizeStalling": h.player.automaticallyWaitsToMinimizeStalling]
                let (w, pv, _) = makeWindow(h)
                h.log.event("window shown, player time \(h.now.value)/\(h.now.timescale) rate \(h.player.rate)")
                await sleepMs(250)
                h.log.event("after 250 ms, player time \(h.now.value)/\(h.now.timescale) rate \(h.player.rate) timeControl \(h.player.timeControlStatus.rawValue)")
                await sleepMs(250)
                let layer = findPlayerLayer(pv.layer, player: h.player)
                h.log.event("layer found \(layer != nil), readyForDisplay \(layer?.isReadyForDisplay ?? false)")
                var phases: [[String: Any]] = []
                for phase in ["first", "warm-replay"] {
                    h.log.event("\(phase): seekExact(0) begin, player time \(h.now.value)/\(h.now.timescale)")
                    let fin = await h.seekExact(.zero)
                    h.log.event("\(phase): seekExact(0) done finished=\(fin)")
                    let mark = h.log.snapshot().entries.count
                    h.capture.reset(); h.capture.start()
                    h.log.event("\(phase): play")
                    let playNs = Clock.now()
                    h.player.play()
                    await sleepMs(1200)
                    h.player.pause()
                    h.log.event("\(phase): pause at \(h.now.value)/\(h.now.timescale)")
                    h.capture.stop()
                    let all = h.log.snapshot().entries
                    let after = Array(all[mark...])
                    let window = 0..<30
                    let requested = Set(after.map { $0.frame })
                    let notRequested = window.filter { !requested.contains($0) && $0 <= (after.map { $0.frame }.max() ?? -1) }
                    var pixelBad: [String] = [], timeBad: [String] = []
                    for e in after {
                        if let sid = e.receivedSourceID, let (src, f) = Expect2.source(at: e.content),
                           E2Metrics.sourceKeyByID[sid] != src || e.receivedSourceFrame != f {
                            pixelBad.append("seq \(e.seq) t\(e.frame): got \(E2Metrics.sourceKeyByID[sid] ?? "?")\(e.receivedSourceFrame ?? -1) want \(src)\(f)")
                        }
                        if e.sourceTimeMatches == false { timeBad.append("seq \(e.seq) t\(e.frame): movie \(e.sourceMovieTime ?? "-") request \(e.timeValue)/\(e.timescale)") }
                    }
                    let completionOrder = after.map { $0.seq }
                    let outOfOrder = zip(completionOrder, completionOrder.dropFirst()).filter { $0 > $1 }.count
                    let del = h.capture.snapshot()
                    let delBad = del.filter { !Judge.frameIssues(timeIndex: $0.timeIndex, $0.metrics).isEmpty }
                        .map { "t\($0.timeIndex): \($0.metrics.map { "\($0.sourceKey)\($0.sourceFrame)" } ?? "?") at \(String(format: "%.1f", ($0.host - mediaT0) * 1000)) ms" }
                    phases.append([
                        "phase": phase, "playAtMs": ms(playNs), "requestsAfterSeek": after.count,
                        "requests": after.prefix(40).map { e -> String in
                            var s = "seq \(e.seq) t\(e.frame)@\(e.timeValue)/\(e.timescale) start \(String(format: "%.1f", ms(e.startedUptimeNs))) done \(String(format: "%.1f", ms(e.finishedUptimeNs))) mt \(e.sourceMovieTime ?? "-")"
                            if let sid = e.receivedSourceID { s += " px \(E2Metrics.sourceKeyByID[sid] ?? "?")\(e.receivedSourceFrame ?? -1)" }
                            if let (src, f) = Expect2.source(at: e.content) { s += " want \(src)\(f)" }
                            return s
                        },
                        "notRequestedWithinFirst30": notRequested, "pixelMismatch": pixelBad, "timeMismatch": timeBad, "completionOutOfOrder": outOfOrder,
                        "maxInFlight": h.log.snapshot().maxInFlight,
                        "deliveredFirst": del.prefix(12).map { "t\($0.timeIndex) \($0.metrics.map { "\($0.sourceKey)\($0.sourceFrame)" } ?? "?") at \(String(format: "%.1f", ($0.host - mediaT0) * 1000)) ms" },
                        "deliveredMismatch": delBad, "pollGapsOver20ms": h.capture.pollGaps().map { String(format: "%.1f", $0) },
                    ])
                }
                r.sections["events"] = h.log.eventLog
                r.sections["preSeekRequests"] = h.log.snapshot().entries.prefix(6).map { "seq \($0.seq) t\($0.frame) mt \($0.sourceMovieTime ?? "-")" }
                r.sections["phases"] = phases
                let firstBad = phases.first.map { !($0["pixelMismatch"] as! [String]).isEmpty || !($0["timeMismatch"] as! [String]).isEmpty || !($0["deliveredMismatch"] as! [String]).isEmpty || !($0["notRequestedWithinFirst30"] as! [Int]).isEmpty } ?? true
                let warmBad = phases.last.map { !($0["pixelMismatch"] as! [String]).isEmpty || !($0["timeMismatch"] as! [String]).isEmpty || !($0["deliveredMismatch"] as! [String]).isEmpty || !($0["notRequestedWithinFirst30"] as! [Int]).isEmpty } ?? true
                r.check("DF-first", "새 프로세스 첫 재생(\(options.label)): 첫 30프레임 요청 누락·받은 소스 시각 불일치·소스 픽셀 불일치·전달 불일치 없음", pass: nil, ["anomaly": firstBad])
                r.check("DF-warm", "같은 프로세스 다시 재생(대조)", pass: nil, ["anomaly": warmBad])
                w.close()
            } catch { r.check("ABORT", "실행 중단", pass: false, ["error": "\(error)"]) }
            let url = root.appendingPathComponent("results").appendingPathComponent("e2-diag-fresh-\(options.diagnoseSource ? "px" : "nopx")-\(id).json")
            try? r.write(to: url)
            print("results: results/\(url.lastPathComponent)")
            exit(0)
        }
    }
}

// MARK: - 소유자 관찰 창

@MainActor
final class WindowApp: NSObject, NSApplicationDelegate {
    let muted: Bool
    let smokeSeconds: Double?
    var harness: Harness?
    var window: NSWindow?
    var label: NSTextField?
    var playerView: AVPlayerView?
    var observer: Any?
    let started = Date()
    init(muted: Bool, smokeSeconds: Double?) { self.muted = muted; self.smokeSeconds = smokeSeconds }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let sub = NSMenu(); sub.addItem(withTitle: "Quit E2 Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = sub; NSApp.mainMenu = menu
        Task { @MainActor in
            do {
                let h = try await Harness.make(muted: muted)
                harness = h
                let (w, pv, l) = makeWindow(h)
                window = w; playerView = pv; label = l
                NSApp.activate(ignoringOtherApps: true)
                observer = h.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
                    MainActor.assumeIsolated {
                        let n = floorIndex(t)
                        let seg = Expect2.source(at: min(n, 299)).map { "\($0.0) \($0.1)" } ?? "-"
                        self.label?.stringValue = String(format: "t=%.3f s  frame≈%d  기대 소스 %@  (플레이어 시각 기준)", t.seconds, n, seg)
                    }
                }
                h.capture.start()
                print("window ready (muted=\(muted)). Space=재생/일시정지, ←/→=프레임 이동, ⌘Q=종료")
                if let s = smokeSeconds {   // 실행 확인용: s초 재생 뒤 종료
                    h.player.play()
                    await sleepMs(Int(s * 1000))
                    NSApp.terminate(nil)
                }
            } catch { print("window setup failed: \(error)"); NSApp.terminate(nil) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        guard let h = harness else { return }
        h.capture.stop()
        let del = h.capture.snapshot(), snap = h.log.snapshot()
        let wrong = del.filter { !Judge.frameIssues(timeIndex: $0.timeIndex, $0.metrics).isEmpty }
        let pl = findPlayerLayer(playerView?.layer, player: h.player)
        let r = Report()
        r.sections["build"] = h.env.buildIdentity()
        r.sections["session"] = ["muted": muted, "sessionSeconds": Date().timeIntervalSince(started), "delivered": del.count,
                                 "deliveredUnique": Set(del.map { $0.timeIndex }).count, "deliveredWrongContent": wrong.count,
                                 "endTimeDelivered": del.filter { $0.timeIndex == 300 }.count, "compositorRequests": snap.entries.count,
                                 "compositorErrors": snap.errors, "playerLayerFound": pl != nil, "layerReadyAtQuit": pl?.isReadyForDisplay ?? false,
                                 "note": "비디오 출력 경로와 합성기 기록이다. 실제 화면 모습은 소유자 관찰로만 확인한다."]
        let url = root.appendingPathComponent("results").appendingPathComponent("e2-window-\(runID()).json")
        try? r.write(to: url)
        print("window session summary: results/\(url.lastPathComponent)")
    }
}

// MARK: - 진입점

guard root.lastPathComponent == "e2-4k" else { print("experiments/e2-4k 디렉터리에서 실행해야 한다"); exit(2) }
let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.regular)
switch args.count > 1 ? args[1] : "" {
case "auto":
    let d = AutoApp(); app.delegate = d; app.run()
case "diag-source":
    let reps = args.firstIndex(of: "--reps").flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil } ?? 3
    let d = DiagSourceApp(options: HarnessOptions.parse(args), reps: reps); app.delegate = d; app.run()
case "diag-fresh":
    var o = HarnessOptions.parse(args); o.diagnoseSource = args.contains("--pixels")
    let d = DiagFreshApp(options: o); app.delegate = d; app.run()
case "diag-start":
    let d = DiagApp(); app.delegate = d; app.run()
case "window":
    let smoke = args.firstIndex(of: "--smoke").flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]) : nil }
    let d = WindowApp(muted: args.contains("--muted"), smokeSeconds: smoke); app.delegate = d; app.run()
default:
    print("usage: e2preview auto | diag-start | window [--muted] [--smoke SECONDS]"); exit(2)
}
