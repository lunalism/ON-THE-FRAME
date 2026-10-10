// E3-1 프리뷰 실행기(실험용 최소 창, 제품 UI 아님).
// 사용(experiments/e3-fhd-10min 디렉터리에서, 먼저 `e3 all`):
//   .build/release/e3preview auto     창 부착 10분 재생(새 프로세스 첫 재생), 1분 구간 반복, 탐색, 끝 유지·다시 재생, 지문 비교
//   .build/release/e3preview window   소유자 확인 창(소리 켬). --muted
// 층 구분: 합성기 요청(E2Log, 요청마다 받은 소스의 시각·픽셀 검사) / 비디오 출력 전달 버퍼 / 관찰기 폴링 간격 / AVPlayerLayer(일시정지 중).
import AppKit
import AVFoundation
import AVKit
import CoreMedia
import E1Core
import E2Core
import E2Judge
import E3Core
import E3Expect
import E3Judge
import Foundation
import IOKit.pwr_mgt
import QuartzCore

Spec4K.configure(.fhd)

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func sleepMs(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
func say(_ s: String) { print("[\(ISO8601DateFormatter().string(from: Date()))] \(s)"); fflush(stdout) }
func floorIndex(_ t: CMTime) -> Int { Int((t.seconds * 30 + 1e-9).rounded(.down)) }

// MARK: - 전달 버퍼 관찰(스트리밍 판정)

/// 안전성(@unchecked Sendable): output·timer·tally·폴링 상태는 직렬 queue에서만 접근한다.
final class Capture3: @unchecked Sendable {
    struct Delivered: Sendable { let n: Int; let metrics: E2Metrics?; let host: Double }
    let output: AVPlayerItemVideoOutput
    private let queue = DispatchQueue(label: "e3.capture")
    private var timer: DispatchSourceTimer?
    private var tally = FrameTally()
    private var delivered = 0, wrong = 0
    private var wrongList: [String] = []
    private var deliveredSet = Set<Int>()
    private var gaps: [Double] = []
    private var lastPoll = 0.0
    private var recent: [Delivered] = []   // 탐색 판정용(최근 것만)
    init(output: AVPlayerItemVideoOutput) { self.output = output }

    func start() { queue.sync { lastPoll = 0; let t = DispatchSource.makeTimerSource(queue: queue); t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1)); t.setEventHandler { [weak self] in self?.poll() }; t.resume(); timer = t } }
    func stop() { queue.sync { timer?.cancel(); timer = nil } }
    func reset() { queue.sync { tally = FrameTally(); delivered = 0; wrong = 0; wrongList = []; deliveredSet = []; gaps = []; lastPoll = 0; recent = [] } }
    func result() -> (tally: FrameTally, delivered: Int, unique: Int, wrong: Int, wrongList: [String], gaps: [Double], set: Set<Int>) {
        queue.sync { (tally, delivered, deliveredSet.count, wrong, wrongList, gaps, deliveredSet) }
    }
    func recentDeliveries() -> [Delivered] { queue.sync { recent } }

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
        let n = E2Compositor.frameIndex(disp).0
        let m = E2Metrics.measure(pb)
        tally.add(n, m)
        delivered += 1; deliveredSet.insert(n)
        let iss = Judge3.frameIssues(timeIndex: n, m)
        if !iss.isEmpty { wrong += 1; if wrongList.count < 30 { wrongList.append("\(n): " + iss.joined(separator: "; ")) } }
        let d = Delivered(n: n, metrics: m, host: host)
        recent.append(d); if recent.count > 400 { recent.removeFirst(recent.count - 400) }
        return d
    }
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

@MainActor
final class Harness {
    let env: E3Env, bundle: E2Bundle, log: E2Log, item: AVPlayerItem, player: AVPlayer, capture: Capture3
    init(env: E3Env, bundle: E2Bundle, log: E2Log, muted: Bool) {
        self.env = env; self.bundle = bundle; self.log = log
        item = AVPlayerItem(asset: bundle.composition)
        item.videoComposition = bundle.videoComposition
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        if muted { player.volume = 0 }
        capture = Capture3(output: out)
    }
    static func make(muted: Bool) async throws -> Harness {
        let env = try await E3Env.load(root: root)
        let log = E2Log(fingerprints: true, diagnoseSource: true)
        let h = Harness(env: env, bundle: try await env.makeBundle(log: log), log: log, muted: muted)
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
        let before = now; item.step(byCount: k)
        for _ in 0..<300 { if now != before { await sleepMs(20); return now }; await sleepMs(5) }
        return now
    }
}

@MainActor
func makeWindow(_ h: Harness, title: String) -> (NSWindow, AVPlayerView, NSTextField) {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    w.title = title; w.isReleasedWhenClosed = false
    let pv = AVPlayerView(frame: w.contentLayoutRect)
    pv.autoresizingMask = [.width, .height]; pv.controlsStyle = .inline; pv.showsFrameSteppingButtons = true; pv.player = h.player
    let l = NSTextField(labelWithString: "")
    l.font = .monospacedSystemFont(ofSize: 14, weight: .medium); l.textColor = .white
    l.backgroundColor = NSColor.black.withAlphaComponent(0.6); l.drawsBackground = true
    l.frame = NSRect(x: 12, y: 12, width: 700, height: 22)
    pv.contentOverlayView?.addSubview(l)
    w.contentView = pv; w.center(); w.makeKeyAndOrderFront(nil); w.orderFrontRegardless()
    return (w, pv, l)
}

@MainActor
func findPlayerLayer(_ layer: CALayer?, player: AVPlayer) -> AVPlayerLayer? {
    guard let layer else { return nil }
    if let pl = layer as? AVPlayerLayer, pl.player === player { return pl }
    for s in layer.sublayers ?? [] { if let f = findPlayerLayer(s, player: player) { return f } }
    return nil
}

@MainActor
func layerShows(_ layer: AVPlayerLayer, timeIndex n: Int, timeoutMs: Int) async -> (issues: [String], ms: Double, desc: String) {
    let t0 = CACurrentMediaTime()
    var last = "nil"
    while (CACurrentMediaTime() - t0) * 1000 < Double(timeoutMs) {
        if let pb = layer.displayedPixelBuffer(), let m = E2Metrics.measure(pb) {
            last = "\(m.timelineCode) \(m.sourceKey)\(m.sourceFrame)"
            if m.timelineCode == Expect3.contentFrame(n) { return (Judge3.frameIssues(timeIndex: n, m), (CACurrentMediaTime() - t0) * 1000, last) }
        }
        await sleepMs(5)
    }
    return (["timeout; last \(last)"], (CACurrentMediaTime() - t0) * 1000, last)
}

/// 합성기 기록의 새 항목에서 받은 소스의 시각·픽셀 불일치를 찾는다(E2 결함 재발 감시)
@MainActor
final class MismatchWatch {
    var checkedUpTo = 0
    var found: [String] = []
    var evidence: [String] = []
    func scan(_ log: E2Log) -> Bool {
        let es = log.snapshot().entries
        guard checkedUpTo < es.count else { return false }
        for (i, e) in es[checkedUpTo...].enumerated() {
            var why: [String] = []
            if e.sourceTimeMatches == false { why.append("time movie \(e.sourceMovieTime ?? "-") request \(e.timeValue)/\(e.timescale)") }
            if let sid = e.receivedSourceID, let (src, f) = Expect3.source(at: e.content), E2Metrics.sourceKeyByID[sid] != src || e.receivedSourceFrame != f {
                why.append("pixel got \(E2Metrics.sourceKeyByID[sid] ?? "?")\(e.receivedSourceFrame ?? -1) want \(src)\(f)")
            }
            if !why.isEmpty {
                found.append("seq \(e.seq) t\(e.frame): " + why.joined(separator: "; "))
                let j = checkedUpTo + i
                evidence = es[max(0, j - 6)..<min(es.count, j + 6)].map { x in
                    "seq \(x.seq) t\(x.frame)@\(x.timeValue)/\(x.timescale) mt \(x.sourceMovieTime ?? "-") px \(x.receivedSourceID.flatMap { E2Metrics.sourceKeyByID[$0] } ?? "?")\(x.receivedSourceFrame ?? -1) sfc \(x.sourceSurfaceID ?? 0)"
                }
            }
        }
        checkedUpTo = es.count
        return !found.isEmpty
    }
}

// MARK: - 자동 실행

@MainActor
final class AutoApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { Task { @MainActor in await self.run() } }

    /// 실행 동안 이 프로세스만의 디스플레이 유휴 절전 방지 assertion(동영상 재생기와 같은 방식, 종료 시 해제). 전역 설정을 바꾸지 않는다.
    /// 기록(…023534Z): 이 장치 없이 실행했을 때 11:37:53에 디스플레이가 꺼졌고, 그 뒤 AVPlayerLayer 표시 버퍼가 프레임 4065에 멈춰
    /// 일시정지 탐색·끝 유지의 레이어 검사가 실패했다(비디오 출력 경로는 정상).
    var displayAssertion: IOPMAssertionID = 0
    func holdDisplayAwake() -> Bool {
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "E3-1 preview experiment (AVPlayerLayer must stay presented)" as CFString, &displayAssertion) == kIOReturnSuccess
    }

    func run() async {
        let r = Report(), id = runID()
        let monitor = ResourceMonitor(experimentsDir: root.deletingLastPathComponent())
        let runDir = root.appendingPathComponent("artifacts/runs/preview-\(id)")
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        var correctness: [String: Bool] = [:]
        var stoppedAt: String?
        func stopped(_ w: String) -> Bool { if let s = monitor.stopReason { if stoppedAt == nil { stoppedAt = "\(w): \(s)"; say("STOP \(stoppedAt!)") }; return true }; return false }
        let held = holdDisplayAwake()
        defer { if held { IOPMAssertionRelease(displayAssertion) } }
        monitor.start(); monitor.enter("load", limitSeconds: 600)
        r.sections["run"] = ["id": id, "os": ProcessInfo.processInfo.operatingSystemVersionString, "volume": 0, "workloadStart": workloadSnapshot(),
                             "window": "AVPlayerView 1280×760", "sourcePixelDiagnosis": "every compositor request",
                             "displaySleepAssertion": held ? "held by this process" : "failed"]
        let started = Date()
        do {
            say("load")
            let h = try await Harness.make(muted: true)
            r.sections["build"] = h.env.buildIdentity(); r.sections["fixtures"] = h.env.fixtureInfo
            let (w, pv, _) = makeWindow(h, title: "E3-1 Preview — 10분 FHD (실험용, 제품 UI 아님)")
            await sleepMs(500)
            let layer = findPlayerLayer(pv.layer, player: h.player)
            let watch = MismatchWatch()

            // 1) 새 프로세스 첫 재생 = 10분 전체 재생(기록을 지우지 않음)
            if !stopped("playback") {
                say("full playback")
                monitor.enter("playback-warmup", limitSeconds: 120)
                await h.seekExact(.zero)
                h.capture.reset(); h.capture.start()
                let mark = h.log.snapshot().entries.count
                let t0 = CACurrentMediaTime()
                h.player.play()
                var steady = false, stoppedOnMismatch = false, reached = false
                while CACurrentMediaTime() - t0 < 640 {
                    await sleepMs(500)
                    if !steady && CACurrentMediaTime() - t0 > 30 { monitor.enter("playback-steady", limitSeconds: 700); steady = true }
                    if watch.scan(h.log) { h.player.pause(); stoppedOnMismatch = true; say("source-frame mismatch: stop playback case"); break }
                    if h.player.rate == 0 && CACurrentMediaTime() - t0 > 5 { reached = h.now >= h.item.duration; break }
                    if stopped("playback") { h.player.pause(); break }
                }
                let wall = CACurrentMediaTime() - t0
                await sleepMs(300); h.capture.stop()
                let cap = h.capture.result()
                let all = h.log.snapshot().entries
                let after = Array(all[mark...])
                let requested = Set(after.map { $0.frame }.filter { $0 >= 0 && $0 < Expect3.frameCount })
                let maxReq = after.map { $0.frame }.max() ?? -1
                let notRequested = (0...min(maxReq, Expect3.lastValidFrame)).filter { !requested.contains($0) }
                let reqNotDel = requested.filter { !cap.set.contains($0) }.sorted()
                let (sok, sd) = cap.tally.spectrum(), (fok, fd) = cap.tally.flashDrift()
                let ok = !stoppedOnMismatch && reached && cap.wrong == 0 && watch.found.isEmpty && h.log.snapshot().errors.filter { !$0.hasPrefix("stale") }.isEmpty
                correctness["V1"] = ok; correctness["V2"] = sok && fok
                r.check("V1", "10분 재생(새 프로세스 첫 재생, 창 부착, volume 0): 전달 프레임마다 기대값, 합성기가 받은 소스의 시각·픽셀 불일치 0, 끝까지 도달. 누락 개수는 기록",
                        pass: ok, ["wallSeconds": wall, "reachedEnd": reached, "stoppedOnSourceMismatch": stoppedOnMismatch,
                                   "sourceMismatch": watch.found, "mismatchEvidence": watch.evidence,
                                   "compositorRequests": after.count, "requestedUnique": requested.count, "notRequested": notRequested.count,
                                   "notRequestedSample": Array(notRequested.prefix(30)), "delivered": cap.delivered, "deliveredUnique": cap.unique,
                                   "requestedButNotDelivered": reqNotDel.count, "requestedButNotDeliveredSample": Array(reqNotDel.prefix(30)),
                                   "deliveredWrong": cap.wrong, "deliveredWrongSample": cap.wrongList,
                                   "pollGapsOver20ms": cap.gaps.count, "pollGapMaxMs": cap.gaps.max() ?? 0,
                                   "firstRequests": after.prefix(6).map { "seq \($0.seq) t\($0.frame) mt \($0.sourceMovieTime ?? "-")" },
                                   "copyMs": stats(after.map { $0.copyMs }), "overlayMs": stats(after.map { $0.overlayMs }),
                                   "loadAvgAfter": loadAvg()])
                r.check("V2", "재생 중 전달 프레임의 스펙트럼·플래시 위치(전달된 프레임만 판정)", pass: sok && fok, ["spectrum": sd, "flash": fd])
                // 지문 비교용(내용 프레임 → 지문)
                var fps: [Int: String] = [:]
                for e in after where e.content >= 0 && e.content < Expect3.frameCount { if let f = e.fingerprint { fps[e.content] = f } }
                // 같은 E3 소스 트리의 e3 all 결과에서 오프라인 지문을 찾는다
                let tree = ((r.sections["build"] as? [String: Any])?["e3SourceTree"] as? [String: Any])?["treeSha256"] as? String ?? "-"
                var offlinePath: String?
                if let files = try? FileManager.default.contentsOfDirectory(atPath: h.env.resultsDir.path) {
                    for f in files.filter({ $0.hasPrefix("e3-run-") || $0.hasPrefix("e3-reverify-") }).sorted(by: { $0.suffix(22) < $1.suffix(22) }).reversed() {
                        guard let d = try? Data(contentsOf: h.env.resultsDir.appendingPathComponent(f)),
                              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let b = (j["sections"] as? [String: Any])?["build"] as? [String: Any],
                              (b["e3SourceTree"] as? [String: Any])?["treeSha256"] as? String == tree,
                              let checks = j["checks"] as? [[String: Any]],
                              let p = checks.first(where: { $0["id"] as? String == "C1" })?["fingerprints"] as? String else { continue }
                        offlinePath = p; break
                    }
                }
                if let p = offlinePath, let txt = try? String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) {
                    let off = txt.split(separator: "\n").map(String.init)
                    let common = fps.keys.filter { $0 < off.count }.sorted()
                    let differ = common.filter { fps[$0] != off[$0] }
                    correctness["O1"] = !common.isEmpty && differ.isEmpty
                    r.check("O1", "같은 타임라인 해석: 재생 중 합성기 출력과 오프라인 합성기 출력(e3 all, 같은 소스 트리)의 표본 지문 일치", pass: !common.isEmpty && differ.isEmpty,
                            ["framesCompared": common.count, "differ": differ.count, "differSample": Array(differ.prefix(20)), "offline": p])
                } else {
                    r.check("O1", "같은 타임라인 해석(지문 비교)", pass: nil, ["note": "같은 E3 소스 트리의 e3 all 오프라인 지문이 없어 비교하지 못함"])
                }
            }

            // 2) 같은 1분 구간(120~180 s) 두 번 재생: 메모리 평탄 여부
            for rep in 1...2 where !stopped("repeat") {
                say("repeat minute \(rep)")
                monitor.enter("repeat-minute-\(rep)", limitSeconds: 150)
                await h.seekExact(Spec4K.frameTime(3_600))
                h.capture.reset(); h.capture.start()
                h.player.play()
                var mism = false
                for _ in 0..<120 { await sleepMs(500); if watch.scan(h.log) { mism = true; break }; if stopped("repeat") { break } }
                h.player.pause(); h.capture.stop()
                let cap = h.capture.result()
                let ok = !mism && cap.wrong == 0
                correctness["R\(rep)"] = ok
                r.check("R\(rep)", "1분 구간(120~180 s) 재생 \(rep)회째: 전달 프레임 기대값, 소스 불일치 0(메모리 평탄 여부는 기록)", pass: ok,
                        ["delivered": cap.delivered, "deliveredWrong": cap.wrong, "deliveredWrongSample": cap.wrongList, "sourceMismatch": watch.found,
                         "stoppedOnSourceMismatch": mism])
            }

            // 3) 일시정지 탐색: 가운데 컷, 끝 직전 컷, 끝 1 s 전, 마지막 프레임, 끝, 끝에서 ← 두 번, 처음
            if !stopped("seeks") {
                say("paused seeks")
                monitor.enter("seeks", limitSeconds: 180)
                enum Move { case seek(Int), step(Int) }
                let plan: [(String, Move, Int)] = [("cut 8999", .seek(8_999), 8_999), ("cut 9000", .seek(9_000), 9_000), ("last cut 17939", .seek(17_939), 17_939),
                                                   ("last cut 17940", .seek(17_940), 17_940), ("end-1s 17970", .seek(17_970), 17_970), ("last 17999", .seek(17_999), 17_999),
                                                   ("end 18000", .seek(18_000), 18_000), ("step back", .step(-1), 17_999), ("step back", .step(-1), 17_998),
                                                   ("back to 0", .seek(0), 0)]
                h.player.pause(); h.capture.reset()
                var rows: [[String: Any]] = [], ok = layer != nil
                for (name, move, n) in plan {
                    let t0 = CACurrentMediaTime()
                    var t = Spec4K.frameTime(n), fin = true
                    switch move { case .seek: fin = await h.seekExact(t); case .step(let k): t = await h.stepAndWait(k) }
                    let seekMs = (CACurrentMediaTime() - t0) * 1000
                    let d = await h.capture.fetch(at: t, timeoutMs: 2000)
                    let outMs = (CACurrentMediaTime() - t0) * 1000
                    let oi = d == nil ? ["no delivered frame"] : Judge3.frameIssues(timeIndex: n, d!.metrics)
                    var row: [String: Any] = ["move": name, "target": n, "playerTimeIndex": E2Compositor.frameIndex(t).0, "finished": fin,
                                              "seekMs": seekMs, "outputReadyMs": outMs, "outputIssues": oi]
                    if let layer { let (li, lms, ld) = await layerShows(layer, timeIndex: n, timeoutMs: 2000); row["layer"] = ld; row["layerIssues"] = li; row["layerAfterOutputMs"] = lms; if !li.isEmpty { ok = false } }
                    if !oi.isEmpty || !fin || E2Compositor.frameIndex(t).0 != n { ok = false }
                    rows.append(row)
                }
                correctness["S1"] = ok
                r.check("S1", "일시정지 탐색(가운데 컷, 끝 직전 컷, 끝 1 s 전, 17 999, 18 000, 끝에서 ← 두 번, 0): 비디오 출력과 AVPlayerLayer 표시 버퍼가 기대값(끝은 17 999 유지)",
                        pass: ok, ["playerLayerFound": layer != nil, "moves": rows, "seekMs": stats(rows.map { $0["seekMs"] as! Double }),
                                   "outputReadyMs": stats(rows.map { $0["outputReadyMs"] as! Double })])
            }

            // 4) 끝 근처 재생 중 탐색 → 끝까지 재생 후 유지 → 처음부터 다시 재생
            if !stopped("end"), let layer {
                say("end hold and replay")
                monitor.enter("end-and-replay", limitSeconds: 120)
                await h.seekExact(Spec4K.frameTime(17_700))
                h.capture.reset(); h.capture.start()
                h.player.play(); await sleepMs(1000)
                let s1 = CACurrentMediaTime(); await h.seekExact(Spec4K.frameTime(17_930)); let s1d = CACurrentMediaTime()
                await sleepMs(1000)
                let s2 = CACurrentMediaTime(); await h.seekExact(Spec4K.frameTime(17_990)); let s2d = CACurrentMediaTime()
                let te = CACurrentMediaTime()
                while h.player.rate != 0 && CACurrentMediaTime() - te < 5 { await sleepMs(10) }
                let endIdx = E2Compositor.frameIndex(h.now).0
                let (ei, _, ed) = await layerShows(layer, timeIndex: endIdx, timeoutMs: 2000)
                let recent = h.capture.recentDeliveries()
                let stale1 = recent.filter { $0.host > s1d && $0.host < s2 && $0.n < 17_930 }.count
                let stale2 = recent.filter { $0.host > s2d && $0.n < 17_990 }.count
                let first1 = recent.filter { $0.host > s1d }.min { $0.host < $1.host }, first2 = recent.filter { $0.host > s2d }.min { $0.host < $1.host }
                await h.seekExact(.zero); h.capture.reset()
                let rh = CACurrentMediaTime(); h.player.play(); await sleepMs(1000); h.player.pause(); await sleepMs(200); h.capture.stop()
                let reN = floorIndex(h.now)
                // 정지 뒤 레이어 표시 버퍼가 바뀔 때까지 최대 2 s(E2와 같은 2026-10-10 수정)
                var rm: E2Metrics?
                let w0 = CACurrentMediaTime()
                while CACurrentMediaTime() - w0 < 2 {
                    rm = layer.displayedPixelBuffer().flatMap { E2Metrics.measure($0) }
                    if let m = rm, abs(m.timelineCode - reN) <= 1 { break }
                    await sleepMs(20)
                }
                let layerWaitMs = (CACurrentMediaTime() - w0) * 1000
                var ri: [String] = []
                if let m = rm { if abs(m.timelineCode - reN) > 1 { ri.append("layer \(m.timelineCode) vs paused \(reN)") }; ri += Judge3.frameIssues(timeIndex: m.timelineCode, m) } else { ri.append("no layer buffer") }
                let rd = h.capture.recentDeliveries().filter { $0.host >= rh }
                let firstRe = rd.min { $0.host < $1.host }
                let wrongRe = rd.filter { !Judge3.frameIssues(timeIndex: $0.n, $0.metrics).isEmpty }.count
                let mism = watch.scan(h.log)
                let ok = endIdx == Expect3.frameCount && ei.isEmpty && stale1 == 0 && stale2 == 0 && ri.isEmpty && firstRe?.n == 0 && wrongRe == 0 && !mism
                correctness["E1"] = ok
                r.check("E1", "끝 근처 재생 중 탐색(17 930, 17 990, 이전 위치 프레임 없음) → 끝까지 재생 후 레이어 = 17 999 유지 → 처음부터 다시 재생(첫 전달 0, 정지 화면 = 그 시각)",
                        pass: ok, ["endTimeIndex": endIdx, "endLayer": ed, "endIssues": ei, "staleAfterSeek1": stale1, "staleAfterSeek2": stale2,
                                   "firstAfterSeek1": first1.map { "\($0.n) +\(Int(($0.host - s1d) * 1000)) ms" } ?? "-",
                                   "firstAfterSeek2": first2.map { "\($0.n) +\(Int(($0.host - s2d) * 1000)) ms" } ?? "-",
                                   "seekWhilePlayingMs": [(s1d - s1) * 1000, (s2d - s2) * 1000],
                                   "replayLayerWaitMs": layerWaitMs, "replayPausedAt": reN, "replayLayer": rm.map { "\($0.timelineCode) \($0.sourceKey)\($0.sourceFrame)" } ?? "nil",
                                   "replayIssues": ri, "replayFirstDelivered": firstRe?.n ?? -1, "replayWrong": wrongRe, "sourceMismatch": watch.found])
            }
            r.sections["compositorErrors"] = Array(h.log.snapshot().errors.prefix(20))
            r.sections["compositorEvents"] = Array(h.log.eventLog.prefix(40))
            w.close(); h.player.replaceCurrentItem(with: nil)
        } catch {
            r.check("ABORT", "실행 중단", pass: false, ["error": "\(error)"]); stoppedAt = stoppedAt ?? "error: \(error)"
        }
        monitor.enter("cleanup", limitSeconds: 120)   // 객체 해제 뒤 10 s
        await sleepMs(10_000)
        monitor.stopSampling()
        monitor.writeCSV(to: runDir.appendingPathComponent("memory-e3preview.csv"))
        r.sections["memory"] = monitor.summary()
        r.sections["memoryCSV"] = "artifacts/runs/preview-\(id)/memory-e3preview.csv"
        r.sections["workloadEnd"] = workloadSnapshot()
        r.sections["wallSecondsTotal"] = Date().timeIntervalSince(started)
        let failed = correctness.filter { !$0.value }.map { $0.key }.sorted()
        let execution = stoppedAt == nil ? "complete" : "stopped (\(stoppedAt!))"
        r.sections["status"] = ["execution": execution, "correctnessChecks": correctness.count, "correctnessFailed": failed,
                                "correctnessPassed": failed.isEmpty && stoppedAt == nil, "note": "실행 완료와 정확도 통과는 별개다. 성능 값은 기준 없는 기록이다."]
        let url = root.appendingPathComponent("results").appendingPathComponent("e3-preview-\(id).json")
        do { try r.write(to: url); say("results: results/\(url.lastPathComponent)  execution: \(execution)  correctness failed: \(failed)") } catch { print("write failed \(error)") }
        exit(r.summary.fail.isEmpty && stoppedAt == nil ? 0 : 1)
    }
}

// MARK: - 소유자 확인 창

@MainActor
final class WindowApp: NSObject, NSApplicationDelegate {
    let muted: Bool
    var harness: Harness?, window: NSWindow?, label: NSTextField?, observer: Any?
    init(muted: Bool) { self.muted = muted }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let sub = NSMenu(); sub.addItem(withTitle: "Quit E3 Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = sub; NSApp.mainMenu = menu
        Task { @MainActor in
            do {
                let h = try await Harness.make(muted: muted); harness = h
                let (w, _, l) = makeWindow(h, title: "E3-1 Preview — 10분 FHD (실험용, 제품 UI 아님)"); window = w; label = l
                NSApp.activate(ignoringOtherApps: true)
                observer = h.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
                    MainActor.assumeIsolated {
                        let n = floorIndex(t), c = min(n, Expect3.lastValidFrame)
                        let s = Expect3.source(at: c).map { "\($0.0) f=\($0.1)" } ?? "-"
                        self.label?.stringValue = String(format: "t=%.3f s  frame≈%d  기대 소스 %@  (플레이어 시각 기준)", t.seconds, n, s)
                    }
                }
                print("window ready (muted=\(muted)). Space=재생/일시정지, ←/→=프레임 이동, ⌘Q=종료")
            } catch { print("window setup failed: \(error)"); NSApp.terminate(nil) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

guard root.lastPathComponent == "e3-fhd-10min" else { print("experiments/e3-fhd-10min 디렉터리에서 실행해야 한다"); exit(2) }
let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.regular)
switch args.count > 1 ? args[1] : "" {
case "auto": let d = AutoApp(); app.delegate = d; app.run()
case "window": let d = WindowApp(muted: args.contains("--muted")); app.delegate = d; app.run()
default: print("usage: e3preview auto | window [--muted]"); exit(2)
}
