// E1-b 실제 AVPlayer 프리뷰 실험 실행기.
// 사용(experiments/e1-fhd 디렉터리에서, 먼저 `.build/release/e1 fixtures`):
//   .build/release/e1preview auto                     자동 검사(음소거, 창 없음) → results/e1b-preview-<시각>.json
//   .build/release/e1preview window --case c1-baseline 소유자 관찰용 창(AVPlayerView, 소리 켬)
import AppKit
import AVFoundation
import AVKit
import CoreMedia
import E1Core
import E1Expect
import Foundation
import QuartzCore

// MARK: - 경로·환경

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
      root.lastPathComponent == "e1-fhd" else {
    FileHandle.standardError.write("experiments/e1-fhd 디렉터리에서 실행해야 한다\n".data(using: .utf8)!)
    exit(2)
}
let artifacts = root.appendingPathComponent("artifacts")
let fixturesDir = artifacts.appendingPathComponent("fixtures")
let cacheDir = artifacts.appendingPathComponent("cache")
let resultsDir = root.appendingPathComponent("results")

struct Env: Sendable {
    let s: SourceRef
    let u: SourceRef
    let sCache: SpectrumCache
    let fixtureCheck: [String: String]
    /// 비디오 운반 트랙용 영상(없으면 생성). 합성기 composition의 비디오 트랙을 실제 샘플로 채운다.
    let carrier: URL
}

/// fixture는 e1이 만든 것을 쓴다. 디스크 해시가 정의에서 다시 만든 바이트의 해시와 같아야 한다.
func loadEnv() async throws -> Env {
    var refs: [String: SourceRef] = [:]
    var check: [String: String] = [:]
    for (file, spec) in [("S-selected.wav", AudioFixtureSpec.selected), ("U-unrelated.wav", AudioFixtureSpec.unrelated)] {
        let url = fixturesDir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw E1Error.invalidSource("missing \(file); run `e1 fixtures` first") }
        let disk = try Hashing.sha256(file: url)
        guard disk == Hashing.sha256(spec.wavData()) else { throw E1Error.invalidSource("\(file) hash differs from its definition") }
        refs[file] = SourceRef(id: disk, path: url.path)
        check[file] = disk
    }
    let (cache, _) = try await SpectrumAnalyzer.analyzeSelectedSource(refs["S-selected.wav"]!, cacheDir: cacheDir)
    let carrier = fixturesDir.appendingPathComponent("carrier-160x90-10s.mov")
    let c = try await CarrierVideo.ensure(at: carrier)
    check["carrier-160x90-10s.mov"] = c.sha256 + (c.created ? " (created this run)" : "")
    return Env(s: refs["S-selected.wav"]!, u: refs["U-unrelated.wav"]!, sCache: cache, fixtureCheck: check, carrier: carrier)
}

func timeline(_ c: CaseExpect, _ env: Env) -> TimelineState {
    TimelineState(
        selected: ClipPlacement(source: env.s, sourceIn: CMTime(value: c.sIn, timescale: 1), duration: CMTime(value: c.dur, timescale: 1),
                                timelineStart: CMTime(value: c.tStart, timescale: 1)),
        unrelated: ClipPlacement(source: env.u, sourceIn: .zero, duration: Spec.duration, timelineStart: .zero))
}

/// 시각 프레임 번호 0…300에서 보여야 할 내용의 직접 렌더 해시. 인덱스 n은 합성·표시 시각 n/30이고,
/// 값은 독립 기대값 Expect.contentFrame(n)을 렌더러로 직접 그린 해시다. 300은 끝 시각 t = 10.0 s이며
/// 끝 프레임 유지(P-007)에 따라 내용은 마지막 유효 프레임 299다(내보내기에는 시각 300 프레임이 없음).
func referenceHashes(_ renderer: FrameRenderer) throws -> [String] {
    let b = try FrameRenderer.makeBuffer()
    return try (0...Spec.frameCount).map { n in
        try renderer.render(frame: Expect.contentFrame(forTimeIndex: n), into: b); return PixelCompare.sha256(b)
    }
}

func sleepMs(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }

// MARK: - 프리뷰 세션 (AVPlayer + 사용자 정의 합성기)

/// 한 케이스의 실제 재생 세션. 프리렌더된 내보내기 파일이 아니라 composition을 재생한다.
@MainActor
final class Harness {
    let c: CaseExpect
    let renderer: FrameRenderer
    let reference: [String]
    let log: CompositorLog
    let tap: AudioTapRecorder
    let item: AVPlayerItem
    let player: AVPlayer
    let capture: FrameCapture
    let composition: AVComposition

    init(c: CaseExpect, renderer: FrameRenderer, reference: [String], log: CompositorLog, tap: AudioTapRecorder,
         item: AVPlayerItem, player: AVPlayer, capture: FrameCapture, composition: AVComposition) {
        self.c = c; self.renderer = renderer; self.reference = reference; self.log = log; self.tap = tap
        self.item = item; self.player = player; self.capture = capture; self.composition = composition
    }

    /// diagnosticEmptyVideoTrack: 검은 화면 원인(빈 비디오 트랙)을 진단에서 재현할 때만 true.
    static func make(_ c: CaseExpect, env: Env, muted: Bool, diagnosticEmptyVideoTrack: Bool = false,
                     attachVideoOutput: Bool = true) async throws -> Harness {
        let renderer = try FrameRenderer(state: timeline(c, env), spectrum: env.sCache)
        let reference = try referenceHashes(renderer)
        let log = CompositorLog(hashOutputs: true)
        let bundle = try await CompositionBuilder.build(renderer.state, renderer: renderer, log: log,
                                                        videoCarrier: diagnosticEmptyVideoTrack ? nil : env.carrier,
                                                        allowEmptyVideoTrackForDiagnosis: diagnosticEmptyVideoTrack)
        let item = AVPlayerItem(asset: bundle.composition)
        item.videoComposition = bundle.videoComposition
        // 선택 소스 트랙에만 탭을 붙인다(무관 트랙 U는 관찰하지 않음)
        let tap = AudioTapRecorder()
        if let sTrack = bundle.composition.tracks.first(where: { $0.trackID == bundle.selectedTrackID }) {
            let params = AVMutableAudioMixInputParameters(track: sTrack)
            params.audioTapProcessor = try tap.makeTap()
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        if attachVideoOutput { item.add(output) }
        let player = AVPlayer(playerItem: item)
        // 무음 처리는 isMuted가 아니라 volume = 0으로 한다. 관찰(2026-10-09): isMuted = true일 때 선택 소스 트랙의
        // MTAudioProcessingTap(PreEffects)이 처음 버퍼링된 구간 이후 0만 받았다. volume = 0에서는 전체 샘플을 받았다.
        if muted { player.volume = 0 }
        player.automaticallyWaitsToMinimizeStalling = false
        let capture = FrameCapture(output: output, reference: reference,
                                   captionRect: FrameRenderer.captionLayout().inkRectTopLeft.insetBy(dx: -2, dy: -2))
        let h = Harness(c: c, renderer: renderer, reference: reference, log: log, tap: tap, item: item, player: player,
                        capture: capture, composition: bundle.composition)
        try await h.waitReady()
        return h
    }

    func waitReady() async throws {
        for _ in 0..<1000 {
            if item.status == .readyToPlay { return }
            if item.status == .failed { throw E1Error.render("item failed: \(item.error?.localizedDescription ?? "-")") }
            await sleepMs(10)
        }
        throw E1Error.render("item not ready in 10 s")
    }

    @discardableResult
    func seekExact(_ t: CMTime) async -> Bool {
        await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var now: Double { player.currentTime().seconds }

    /// 0부터 끝까지 재생하며 전달 프레임·합성기 요청·탭 onset을 모은다.
    func playThrough(timeoutS: Double = 15) async -> (wallS: Double, reachedEnd: Bool) {
        await seekExact(.zero)
        capture.reset(); tap.reset(); log.reset()
        capture.start()
        let t0 = CACurrentMediaTime()
        player.play()
        var reached = false
        while CACurrentMediaTime() - t0 < timeoutS {
            if now >= 10.0 - 1e-6 || item.currentTime() >= item.duration { reached = true; break }
            await sleepMs(5)
        }
        let wall = CACurrentMediaTime() - t0
        await sleepMs(300)
        capture.stop()
        player.pause()
        return (wall, reached)
    }
}

// MARK: - 판정 (독립 기대값 표 사용)

func highBar(_ d: FrameCapture.Delivered) -> Int { Expect.highBands.map { d.barHeights.indices.contains($0) ? d.barHeights[$0] : 0 }.max() ?? 0 }

/// 재생 중 전달된 프레임과 탭 기록을 독립 기대값으로 판정한다.
func judgePlayback(_ c: CaseExpect, _ delivered: [FrameCapture.Delivered], _ tap: AudioTapRecorder.Snapshot,
                   _ comp: CompositorLog.Snapshot, reference: [String]) -> (Bool, [String: Any]) {
    let endFrames = delivered.filter { $0.frame == Spec.frameCount }          // t = 10.0 s (타임라인 끝)
    let endComp = comp.entries.filter { $0.frame == Spec.frameCount }
    let byFrame = Dictionary(delivered.map { ($0.frame, $0) }, uniquingKeysWith: { a, _ in a })
    let unique = Set(delivered.map { $0.frame })
    let inRange = unique.filter { (0..<Spec.frameCount).contains($0) }
    let missing = (0..<Spec.frameCount).filter { !unique.contains($0) }
    let hashBad = delivered.filter { !$0.hashMatchesReference }
    let codeBad = delivered.filter { $0.code != Expect.contentFrame(forTimeIndex: $0.frame) }.count
    let inexact = delivered.filter { !$0.exact }.count
    let formatBad = delivered.filter { !($0.width == Spec.width && $0.height == Spec.height && $0.bgra) }.count
    let captionBad = delivered.filter { d in
        (d.captionPixels > 300) != (Expect.captionFirstFrame...Expect.captionLastFrame).contains(Expect.contentFrame(forTimeIndex: d.frame))
    }.count
    var toneBad = 0, toneN = 0, quietBad = 0, quietN = 0
    for t in c.tones { for n in Expect.frames(in: (t.start, t.end), startPad: 0.2, endPad: 0.1) {
        guard let d = byFrame[n] else { continue }
        toneN += 1
        if d.barHeights.indices.max(by: { d.barHeights[$0] < d.barHeights[$1] }) != t.band { toneBad += 1 }
    } }
    for q in c.quiet { for n in Expect.frames(in: q, startPad: q.0 == 0 ? 0 : 0.1, endPad: 0) {
        guard let d = byFrame[n] else { continue }
        quietN += 1; if (d.barHeights.max() ?? 0) > 0 { quietBad += 1 }
    } }
    var clicks: [[String: Any]] = []
    var clickFail = 0
    for t in c.clicks {
        let nExp = Expect.clickResponseFrame(t)
        let status: String
        if let a = byFrame[nExp - 1], let b = byFrame[nExp] {
            status = highBar(a) < 48 && highBar(b) >= 48 ? "pass" : "fail"
            if status == "fail" { clickFail += 1 }
        } else { status = "notDelivered" }
        // 재생 파이프라인 오디오: 기대 클릭 시각과 탭 onset의 차이(샘플)
        let match = tap.onsets.map { ($0.itemSeconds - t) * 48_000 }.min(by: { abs($0) < abs($1) })
        clicks.append(["tExp": t, "nExp": nExp, "video": status, "tapNearestDeltaSamples": match ?? 99999])
    }
    let tapMatched = c.clicks.allSatisfy { t in tap.onsets.contains { abs($0.itemSeconds - t) * 48_000 < 0.5 } }
    let tapExtra = tap.onsets.filter { o in !c.clicks.contains { abs(o.itemSeconds - $0) * 48_000 < 0.5 } }.map { $0.itemSeconds }
    let compHashBad = comp.entries.filter {
        $0.frame < 0 || $0.frame >= reference.count || $0.renderedFrame != Expect.contentFrame(forTimeIndex: $0.frame) || $0.hash != reference[$0.frame]
    }.count
    let compInexact = comp.entries.filter { !$0.exactFrameTime }.count
    let pass = hashBad.isEmpty && codeBad == 0 && inexact == 0 && formatBad == 0 && captionBad == 0 && toneBad == 0 && quietBad == 0
        && clickFail == 0 && tapMatched && tapExtra.isEmpty && compHashBad == 0 && comp.errors.isEmpty && compInexact == 0
    // 전달 간격(표시 시각 기준)과 폴링 지연(폴링한 item 시각 − 표시 시각)
    let sorted = delivered.sorted { $0.displaySeconds < $1.displaySeconds }
    let lateness = delivered.map { ($0.polledItemSeconds - $0.displaySeconds) * 1000 }
    return (pass, [
        "endFrameDelivered": endFrames.count,
        "endFrameShowsLastValid": endFrames.allSatisfy { $0.hashMatchesReference && $0.code == Expect.lastValidFrame },
        "endFrameCompositorRequests": endComp.count, "endFrameCompositorRendered": Array(Set(endComp.map { $0.renderedFrame })).sorted(),
        "delivered": delivered.count, "uniqueFrames": inRange.count, "duplicates": delivered.count - unique.count,
        "missingFrames": missing.count, "missingSample": Array(missing.prefix(20)),
        "firstFrame": sorted.first?.frame ?? -1, "lastFrame": sorted.last?.frame ?? -1,
        "hashMismatch": hashBad.count, "hashMismatchFrames": Array(hashBad.prefix(10).map { $0.frame }),
        "codeMismatch": codeBad, "inexactDisplayTimes": inexact, "formatMismatch": formatBad,
        "captionMismatch": captionBad, "toneFramesChecked": toneN, "toneMismatch": toneBad, "quietFramesChecked": quietN, "quietNonZero": quietBad,
        "clicks": clicks, "tapAllExpectedClicksExact": tapMatched, "tapExtraOnsets": tapExtra,
        "tapProcessCalls": tap.processCalls, "tapFrames": tap.frames, "tapDiscontinuities": tap.discontinuities, "tapFormat": tap.format,
        "compositorRequests": comp.entries.count, "compositorHashMismatch": compHashBad, "compositorInexact": compInexact,
        "compositorCancelled": comp.cancelled, "compositorErrors": comp.errors, "compositorMaxInFlight": comp.maxInFlight,
        "compositorRenderMsMax": comp.entries.map { $0.renderMs }.max() ?? 0,
        "renderContextNotes": comp.renderContexts,
        "pollLatenessMsMax": lateness.max() ?? 0, "pollLatenessMsMean": lateness.isEmpty ? 0 : lateness.reduce(0, +) / Double(lateness.count),
    ])
}

// MARK: - 자동 검사

final class Report {
    var checks: [[String: Any]] = []
    var sections: [String: Any] = [:]
    func check(_ id: String, _ name: String, pass: Bool?, _ detail: [String: Any] = [:]) {
        var d = detail; d["id"] = id; d["name"] = name; d["result"] = pass.map { $0 ? "PASS" : "FAIL" } ?? "RECORD"
        checks.append(d)
        let brief = detail.filter { !($0.value is [Any]) && !($0.value is [String: Any]) }
            .sorted { $0.key < $1.key }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[\(pass.map { $0 ? "PASS" : "FAIL" } ?? "REC ")] \(id) \(name)  \(brief)")
    }
}

func sanitize(_ v: Any) -> Any {
    switch v {
    case let d as Double: return d.isFinite ? (d * 1e4).rounded() / 1e4 : String(d)
    case let f as Float: return sanitize(Double(f))
    case let a as [Any]: return a.map(sanitize)
    case let m as [String: Any]: return m.mapValues(sanitize)
    default: return v
    }
}

func mib(_ b: UInt64) -> Double { Double(b) / 1_048_576 }

/// 일시정지 상태의 위치 이동: 정확 탐색 또는 프레임 단위 이동(AVPlayerItem.step, 창의 ←/→와 같은 API)
enum Move { case seek(CMTime), step(Int) }

/// 프레임 단위 이동 후 플레이어 시각이 바뀔 때까지 기다린다(최대 1.5 s). 바뀐 시각을 돌려준다.
@MainActor
func stepAndWait(_ h: Harness, _ count: Int) async -> CMTime {
    let before = h.player.currentTime()
    h.item.step(byCount: count)
    for _ in 0..<300 {
        let now = h.player.currentTime()
        if now != before { await sleepMs(20); return h.player.currentTime() }
        await sleepMs(5)
    }
    return h.player.currentTime()
}

@MainActor
func seekChecks(_ r: Report, _ h: Harness) async {
    // 일시정지 상태 탐색: 앞으로, 뒤로, 자막 경계 양쪽, 끝 근처, 끝, 끝에서 한 프레임씩 뒤로, 다시 끝, 처음.
    // 기대값은 시각 프레임 번호이며, 보여야 할 내용은 Expect.contentFrame(끝 시각 300 → 299, P-007).
    let plan: [(String, Move, Int)] = [
        ("start", .seek(CMTime(value: 0, timescale: 30)), 0),
        ("forward 0→7.0s", .seek(CMTime(value: 210, timescale: 30)), 210),
        ("backward 7.0→2.0s", .seek(CMTime(value: 60, timescale: 30)), 60),
        ("caption-before 59", .seek(CMTime(value: 59, timescale: 30)), 59),
        ("caption-last 239", .seek(CMTime(value: 239, timescale: 30)), 239),
        ("caption-after 240", .seek(CMTime(value: 240, timescale: 30)), 240),
        ("near-end 299", .seek(CMTime(value: 299, timescale: 30)), 299),
        ("backward far 1.0s", .seek(CMTime(value: 30, timescale: 30)), 30),
        ("near-end 9.9s", .seek(CMTime(value: 297, timescale: 30)), 297),
        ("end 10.0s", .seek(CMTime(value: 300, timescale: 30)), 300),
        ("step back from end", .step(-1), 299),
        ("step back again", .step(-1), 298),
        ("end again", .seek(CMTime(value: 300, timescale: 30)), 300),
        ("back to 0", .seek(CMTime(value: 0, timescale: 30)), 0),
    ]
    h.player.pause()
    var rows: [[String: Any]] = []
    var ok = true
    for (name, move, e) in plan {
        let t0 = CACurrentMediaTime()
        var finished = true
        var t: CMTime
        switch move {
        case .seek(let target): finished = await h.seekExact(target); t = target
        case .step(let n): t = await stepAndWait(h, n)
        }
        let seekMs = (CACurrentMediaTime() - t0) * 1000
        let d = await h.capture.fetch(at: t, timeoutMs: 1500)
        let fetchMs = (CACurrentMediaTime() - t0) * 1000
        let content = Expect.contentFrame(forTimeIndex: e)
        var row: [String: Any] = ["seek": name, "target": t.seconds, "expectTimeIndex": e, "expectContent": content,
                                  "finished": finished, "seekMs": seekMs, "frameReadyMs": fetchMs, "playerTime": h.now]
        if let d {
            row["displayed"] = d.frame; row["displaySeconds"] = d.displaySeconds; row["hashMatch"] = d.hashMatchesReference
            row["code"] = d.code; row["caption"] = d.captionPixels > 300; row["maxBarPx"] = d.barHeights.max() ?? -1
            let good = finished && d.frame == e && d.code == content && d.hashMatchesReference
                && (d.captionPixels > 300) == (Expect.captionFirstFrame...Expect.captionLastFrame).contains(content)
            row["ok"] = good; if !good { ok = false }
        } else {
            row["displayed"] = "none"; row["ok"] = false; ok = false
        }
        rows.append(row)
    }
    r.check("S1-\(h.c.id)", "일시정지 탐색(앞·뒤·자막 경계·끝·끝에서 프레임 단위 뒤로): 표시용 전달 프레임 = 목표, 내용 = 직접 렌더와 비트 동일(끝 시각은 마지막 유효 프레임 유지, 잔상 없음)",
            pass: ok, ["seeks": rows])
}

@MainActor
func runAuto() async -> Int32 {
    let r = Report()
    let started = Date()
    let runID = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
    r.sections["build"] = ["sourceTree": BuildIdentity.sourceTree(root: root), "executable": BuildIdentity.executable()]
    r.sections["run"] = ["id": runID, "os": ProcessInfo.processInfo.operatingSystemVersionString, "muted": true, "window": false,
                         "startFootprintMiB": mib(Memory.physFootprint())]
    do {
        let env = try await loadEnv()
        r.sections["fixtures"] = env.fixtureCheck
        var footprints: [[String: Any]] = []

        for c in Expect.cases {
            let h = try await Harness.make(c, env: env, muted: true)
            // P: 0→끝 재생
            let fp0 = Memory.physFootprint()
            let (wall, reached) = await h.playThrough()
            let (pass, detail) = judgePlayback(c, h.capture.snapshot(), h.tap.snapshot(), h.log.snapshot(), reference: h.reference)
            var d = detail; d["wallS"] = wall; d["reachedEnd"] = reached; d["playerEndTime"] = h.now
            r.check("V1-\(c.id)", "실제 재생(AVPlayer+합성기, 음소거): 전달 프레임·합성기 출력이 직접 렌더와 비트 동일, 독립 기대값(자막·톤·무음·클릭), 탭 onset = 기대 클릭",
                    pass: pass && reached, d)
            footprints.append(["case": c.id, "beforeMiB": mib(fp0), "afterMiB": mib(Memory.physFootprint())])
            await seekChecks(r, h)
            if c.id == Expect.cases[0].id { await playbackControlChecks(r, h) }
            h.player.replaceCurrentItem(with: nil)
        }
        r.sections["footprintPerCase"] = footprints
    } catch {
        r.check("ABORT", "실행 중단", pass: false, ["error": "\(error)"])
    }
    r.sections["endFootprintMiB"] = mib(Memory.physFootprint())
    r.sections["wallSecondsTotal"] = Date().timeIntervalSince(started)
    let pass = r.checks.filter { ($0["result"] as? String) == "PASS" }.count
    let fail = r.checks.filter { ($0["result"] as? String) == "FAIL" }
    let rec = r.checks.filter { ($0["result"] as? String) == "RECORD" }.count
    r.sections["summary"] = ["pass": pass, "fail": fail.count, "record": rec, "failedIDs": fail.map { $0["id"] as! String }]
    do {
        try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let url = resultsDir.appendingPathComponent("e1b-preview-\(runID).json")
        let json = sanitize(["sections": r.sections, "checks": r.checks]) as! [String: Any]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("\nPASS \(pass)  FAIL \(fail.count)  RECORD \(rec)   failed: \(fail.map { $0["id"] as! String })")
        print("results: results/\(url.lastPathComponent)")
    } catch { print("write failed: \(error)") }
    return fail.isEmpty ? 0 : 1
}

/// 재생/일시정지, 재생 중 탐색(앞·뒤·끝 근처), 반복 재생과 자원 사용
@MainActor
func playbackControlChecks(_ r: Report, _ h: Harness) async {
    // 재생/일시정지
    await h.seekExact(.zero)
    h.capture.reset(); h.capture.start()
    h.player.play()
    while h.now < 2.0 { await sleepMs(5) }
    h.player.pause()
    let pausedHost = CACurrentMediaTime()
    let t1 = h.now
    await sleepMs(500)
    let t2 = h.now
    await sleepMs(500)
    let t2b = h.now
    let afterPause = h.capture.snapshot().filter { $0.hostSeconds > pausedHost + 0.1 && $0.displaySeconds > t1 + 1.0 / 30 + 1e-9 }.count
    let resumeHost = CACurrentMediaTime()
    h.player.play()
    await sleepMs(1000)
    h.player.pause()
    let t3 = h.now
    let resumeWall = CACurrentMediaTime() - resumeHost
    h.capture.stop()
    let pauseFrames = h.capture.snapshot()
    // 판정 허용치(실험용): 일시정지 직후 플레이어 시각이 1프레임(1/30 s) 미만으로 정착하는 것은 허용하고 값을 기록한다.
    r.check("C-pause", "재생/일시정지: 일시정지 중 시간이 1프레임 미만으로만 변하고 새 프레임 없음, 재개 후 진행",
            pass: abs(t2 - t1) < 1.0 / 30 && t2 == t2b && afterPause == 0 && t3 - t2 > 0.8 && pauseFrames.allSatisfy { $0.hashMatchesReference },
            ["pausedAt": t1, "after500ms": t2, "after1000ms": t2b, "settleMs": (t2 - t1) * 1000,
             "framesAfterPause": afterPause, "resumedFor": resumeWall, "advanced": t3 - t2,
             "deliveredHashMismatch": pauseFrames.filter { !$0.hashMatchesReference }.count])

    // 재생 중 탐색: 1 s에서 6.0 s로(앞), 1 s 뒤 1.0 s로(뒤), 1 s 뒤 9.5 s로(끝 근처) 후 끝까지
    await h.seekExact(.zero)
    h.capture.reset(); h.tap.reset(); h.capture.start()
    h.player.play()
    while h.now < 1.0 { await sleepMs(5) }
    var seeks: [(String, Double, Double, Double)] = []   // name, target, startHost, doneHost
    for (name, target, dwellMs) in [("fwd→6.0", 6.0, 1000), ("back→1.0", 1.0, 1000), ("end→9.5", 9.5, 1500)] {
        let s0 = CACurrentMediaTime()
        await h.seekExact(CMTime(value: Int64(target * 30), timescale: 30))
        let s1 = CACurrentMediaTime()
        seeks.append((name, target, s0, s1))
        await sleepMs(dwellMs)
    }
    h.capture.stop(); h.player.pause()
    let all = h.capture.snapshot()
    var rows: [[String: Any]] = []
    var ok = all.allSatisfy { $0.hashMatchesReference && $0.code == Expect.contentFrame(forTimeIndex: $0.frame) }
    for (i, s) in seeks.enumerated() {
        let nextStart = i + 1 < seeks.count ? seeks[i + 1].2 : Double.infinity
        let after = all.filter { $0.hostSeconds > s.3 && $0.hostSeconds < nextStart }
        let stale = after.filter { $0.displaySeconds < s.1 - 1e-9 }
        let first = after.min { $0.hostSeconds < $1.hostSeconds }
        if !stale.isEmpty || after.isEmpty { ok = false }
        rows.append(["seek": s.0, "target": s.1, "seekMs": (s.3 - s.2) * 1000, "framesAfter": after.count, "staleFrames": stale.count,
                     "firstFrameLatencyMs": first.map { ($0.hostSeconds - s.3) * 1000 } ?? -1,
                     "firstFrameAfter": first?.frame ?? -1, "lastFrameAfter": after.map { $0.frame }.max() ?? -1])
    }
    let reachedEnd = (all.map { $0.frame }.max() ?? 0) >= 299
    let tapAfterFwd = h.tap.snapshot().onsets.map { $0.itemSeconds }
    r.check("C-seek-playing", "재생 중 탐색(앞·뒤·끝 근처): 탐색 완료 후 이전 위치 프레임 없음, 모든 전달 프레임 비트 동일, 끝 프레임 299 도달",
            pass: ok && reachedEnd, ["seeks": rows, "deliveredTotal": all.count, "maxFrame": all.map { $0.frame }.max() ?? -1,
                                     "tapOnsetsSeconds": tapAfterFwd])

    // 반복 재생 3회: 매회 끝에서 멈춘 상태(끝 프레임 유지)에서 처음부터 다시 재생한다. 자원 사용 기록.
    var reps: [[String: Any]] = []
    var repOK = true
    for i in 1...3 {
        let before = Memory.physFootprint()
        let startedAt = h.now
        let (wall, reached) = await h.playThrough()
        let (pass, d) = judgePlayback(h.c, h.capture.snapshot(), h.tap.snapshot(), h.log.snapshot(), reference: h.reference)
        let first = d["firstFrame"] as? Int ?? -1
        let endOK = d["endFrameShowsLastValid"] as? Bool ?? false
        repOK = repOK && pass && reached && first == 0 && endOK
        reps.append(["rep": i, "pass": pass, "playerTimeBefore": startedAt, "firstFrame": first, "endFrameShowsLastValid": endOK,
                     "endFrameDelivered": d["endFrameDelivered"] ?? 0,
                     "wallS": wall, "delivered": d["delivered"] ?? 0, "missing": d["missingFrames"] ?? 0,
                     "compositorRequests": d["compositorRequests"] ?? 0, "beforeMiB": mib(before), "afterMiB": mib(Memory.physFootprint())])
    }
    r.check("C-repeat", "끝에서 처음부터 다시 재생 3회: 매회 판정 통과, 첫 전달 프레임 0, 끝 시각 프레임 = 마지막 유효 프레임. footprint 기록(기준 없음)",
            pass: repOK, ["reps": reps])
}

// MARK: - 소유자 관찰용 창

/// 소유자 관찰 창과 표시 경계 검사가 함께 쓰는 창 구성(AVPlayerView, inline 컨트롤).
@MainActor
func makePreviewWindow(_ h: Harness, _ c: CaseExpect) -> (NSWindow, AVPlayerView, NSTextField) {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                     backing: .buffered, defer: false)
    w.title = "E1 Preview — \(c.id) (실험용, 제품 UI 아님)"
    w.isReleasedWhenClosed = false
    let pv = AVPlayerView(frame: w.contentLayoutRect)
    pv.autoresizingMask = [.width, .height]
    pv.controlsStyle = .inline
    pv.showsFrameSteppingButtons = true
    pv.player = h.player
    let l = NSTextField(labelWithString: "")
    l.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
    l.textColor = .white; l.backgroundColor = NSColor.black.withAlphaComponent(0.6); l.drawsBackground = true
    l.frame = NSRect(x: 12, y: 12, width: 560, height: 22)
    pv.contentOverlayView?.addSubview(l)
    w.contentView = pv
    w.center(); w.makeKeyAndOrderFront(nil)
    w.orderFrontRegardless()
    return (w, pv, l)
}

/// AVPlayerView의 레이어 트리에서 이 플레이어를 표시하는 AVPlayerLayer를 찾는다.
/// AVPlayerView 내부 구조는 공개 API가 아니므로, 못 찾으면 nil이다(그 경우 표시 경계를 관찰하지 못한 것으로 기록).
@MainActor
func findPlayerLayer(_ layer: CALayer?, player: AVPlayer) -> AVPlayerLayer? {
    guard let layer else { return nil }
    if let pl = layer as? AVPlayerLayer, pl.player === player { return pl }
    for sub in layer.sublayers ?? [] { if let f = findPlayerLayer(sub, player: player) { return f } }
    return nil
}

@MainActor
final class WindowApp: NSObject, NSApplicationDelegate {
    let caseID: String
    let muted: Bool
    let smokeSeconds: Double?
    var window: NSWindow?
    var harness: Harness?
    var label: NSTextField?
    var playerView: AVPlayerView?
    var observer: Any?
    let started = Date()

    init(caseID: String, muted: Bool, smokeSeconds: Double?) { self.caseID = caseID; self.muted = muted; self.smokeSeconds = smokeSeconds }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let sub = NSMenu(); sub.addItem(withTitle: "Quit E1 Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = sub; NSApp.mainMenu = menu
        Task { @MainActor in
            do {
                guard let c = Expect.caseByID(caseID) else { throw E1Error.invalidSource("unknown case \(caseID)") }
                let env = try await loadEnv()
                let h = try await Harness.make(c, env: env, muted: muted)
                harness = h
                let (w, pv, l) = makePreviewWindow(h, c)
                label = l
                playerView = pv
                NSApp.activate(ignoringOtherApps: true)
                window = w
                observer = h.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
                    MainActor.assumeIsolated {
                        let n = Int((t.seconds * 30).rounded(.down))
                        self.label?.stringValue = String(format: "%@  t=%.4f s  frame≈%d  (플레이어 시각 기준)", c.id, t.seconds, n)
                    }
                }
                h.capture.start()
                print("window ready: case \(c.id), muted=\(muted). Space=재생/일시정지, ←/→=프레임 이동, ⌘Q=종료")
                if let s = smokeSeconds {
                    h.player.play()
                    try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
                    NSApp.terminate(nil)
                }
            } catch {
                print("window setup failed: \(error)")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 창 세션 동안 표시용으로 전달된 프레임 요약을 남긴다(화면 모습 자체의 증거는 아님).
    func applicationWillTerminate(_ notification: Notification) {
        guard let h = harness else { return }
        h.capture.stop()
        let delivered = h.capture.snapshot()
        let comp = h.log.snapshot()
        let pl = findPlayerLayer(playerView?.layer, player: h.player)
        let summary: [String: Any] = [
            "playerLayerFound": pl != nil, "layerReadyForDisplayAtQuit": pl?.isReadyForDisplay ?? false,
            "case": h.c.id, "muted": muted, "smokeSeconds": smokeSeconds ?? -1, "sessionSeconds": Date().timeIntervalSince(started),
            "build": ["sourceTree": (BuildIdentity.sourceTree(root: root)["treeSha256"] as? String) ?? "-", "executable": BuildIdentity.executable()],
            "delivered": delivered.count, "uniqueFrames": Set(delivered.map { $0.frame }).count,
            "deliveredHashMismatch": delivered.filter { !$0.hashMatchesReference }.count,
            "deliveredCodeMismatch": delivered.filter { $0.code != Expect.contentFrame(forTimeIndex: $0.frame) }.count,
            "endTimeDelivered": delivered.filter { $0.frame == Spec.frameCount }.count,
            "endTimeShowsLastValid": delivered.filter { $0.frame == Spec.frameCount }.allSatisfy { $0.code == Expect.lastValidFrame && $0.hashMatchesReference },
            "compositorRequests": comp.entries.count,
            "compositorHashMismatch": comp.entries.filter {
                $0.frame < 0 || $0.frame >= h.reference.count || $0.renderedFrame != Expect.contentFrame(forTimeIndex: $0.frame) || $0.hash != h.reference[$0.frame]
            }.count,
            "compositorErrors": comp.errors, "tapOnsets": h.tap.snapshot().onsets.map { $0.itemSeconds },
            "note": "delivered/compositor 값은 AVPlayerItemVideoOutput 경로 기록이며 화면 표시의 증거가 아니다. layerReadyForDisplayAtQuit는 AVPlayerView 안 AVPlayerLayer의 준비 상태다. 실제 화면 모습은 소유자 관찰로만 확인한다.",
        ]
        let id = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
        let url = resultsDir.appendingPathComponent("e1b-window-\(h.c.id)-\(id).json")
        if let data = try? JSONSerialization.data(withJSONObject: sanitize(summary), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
            print("window session summary: results/\(url.lastPathComponent)")
        }
    }
}

// MARK: - 진입점

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return nil
}
switch args.count > 1 ? args[1] : "" {
case "auto":
    Task { @MainActor in exit(await runAuto()) }
    dispatchMain()
case "present":
    let app = NSApplication.shared
    let delegate = PresentApp()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
case "frames":
    let app = NSApplication.shared
    let delegate = FramesApp()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
case "diagnose":
    let app = NSApplication.shared
    let delegate = DiagnoseApp()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
case "window":
    let app = NSApplication.shared
    let delegate = WindowApp(caseID: argValue("--case") ?? "c1-baseline", muted: args.contains("--muted"),
                             smokeSeconds: argValue("--smoke").flatMap(Double.init))
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
default:
    print("usage: e1preview auto | present | frames | diagnose | e1preview window [--case c1-baseline|c2-trim|c3-offset|c4-trim-offset] [--muted] [--smoke SECONDS]")
    exit(2)
}
