// E3-1 헤드리스 실행기(실험 코드, 제품 코드 아님).
// 사용(experiments/e3-fhd-10min 디렉터리에서):
//   .build/release/e3 fixtures   fixture 생성(없을 때만)·검증 → results/e3-fixtures-<시각>.json
//   .build/release/e3 all        전체: fixture, 타임라인, 오프라인 합성기 18 000프레임, 10분 내보내기(보관) + 스트리밍 디코딩 검증,
//                                대표 취소·실패·출력 보호, 단계별 메모리 → results/e3-run-<시각>.json, artifacts/runs/<시각>/
import AVFoundation
import CoreMedia
import E1Core
import E2Core
import E2Judge
import E3Core
import E3Expect
import E3Judge
import Foundation

Spec4K.configure(.fhd)   // 다른 작업보다 먼저: 1920×1080 배치(E2Core 공유 코드)

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard ["fixtures", "all", "diag-iso", "reverify", "boundary-check"].contains(mode), root.lastPathComponent == "e3-fhd-10min" else {
    print("usage: e3 fixtures | all   (experiments/e3-fhd-10min 디렉터리에서)"); exit(2)
}
func mib(_ b: UInt64) -> Double { (Double(b) / 1_048_576 * 10).rounded() / 10 }
func say(_ s: String) { print("[\(ISO8601DateFormatter().string(from: Date()))] \(s)"); fflush(stdout) }

let r = Report()
let id = runID()
let monitor = ResourceMonitor(experimentsDir: root.deletingLastPathComponent())
let runDir = root.appendingPathComponent("artifacts/runs/\(id)")
var stoppedAt: String?
var correctness: [String: Bool] = [:]

@MainActor
func stopped(_ where_: String) -> Bool {
    if let s = monitor.stopReason { if stoppedAt == nil { stoppedAt = "\(where_): \(s)"; say("STOP \(stoppedAt!)") }; return true }
    return false
}

// MARK: - 소스 fixture 검증

@MainActor
func verifySources(_ env: E3Env) async throws {
    for spec in E3Spec.sources {
        var bad: [String] = []
        let info = try await StreamVerifier.run(env.sources[spec.key]!) { i, m in
            guard let m else { bad.append("\(i) unmeasurable"); return }
            if m.sourceID != spec.idCode || m.sourceFrame != i { bad.append("\(i) code \(m.sourceID)/\(m.sourceFrame)") }
            if abs(m.boxX - Spec4K.boxX(i)) > Judge3.boxTolerance { bad.append("\(i) box \(m.boxX)") }
            if m.flashOn != spec.isFlash(i) { bad.append("\(i) flash \(m.flash)") }
            if zip(m.background, spec.background).contains(where: { abs($0 - Int($1)) > 12 }) { bad.append("\(i) bg \(m.background)") }
        }
        let want = spec.clipAudio.clickStartSamples
        let deltas = want.map { e in info.onsets.map { $0 - e }.min { abs($0) < abs($1) } ?? Int.max }
        let ok = info.frames == spec.frames && info.ptsMismatch == 0 && bad.isEmpty && info.onsets.count == want.count && deltas.allSatisfy { abs($0) <= 48 }
        correctness["F-src-\(spec.key)"] = ok
        r.check("F-src-\(spec.key)", "소스 \(spec.key)(FHD H.264 + AAC, 600프레임): 프레임 수·PTS·소스 ID·프레임 번호·상자·플래시(15, 315)·배경, 클릭 위치",
                pass: ok, ["frames": info.frames, "ptsMismatch": info.ptsMismatch, "issues": Array(bad.prefix(10)), "format": info.format,
                           "clickDeltas": deltas, "onsets": info.onsets.count, "decodeSeconds": info.seconds])
    }
}

// MARK: - 타임라인

@MainActor
func timelineCheck(_ env: E3Env) {
    let t = env.timeline
    var bad: [String] = []
    for n in 0..<Expect3.frameCount {
        let a = t.sourceFrame(at: n), e = Expect3.source(at: n)
        if a?.source != e?.0 || a?.frame != e?.1 { if bad.count < 10 { bad.append("\(n): model \(a.map { "\($0.source)\($0.frame)" } ?? "nil") want \(e.map { "\($0.0)\($0.1)" } ?? "nil")") } }
    }
    let starts = t.segments.map { $0.start }.dropFirst()
    let ok = bad.isEmpty && t.durationFrames == 18_000 && t.lastValidFrame == 17_999 && t.segments.count == 41 && Array(starts) == Expect3.cutStarts
    correctness["T1"] = ok
    r.check("T1", "편집 모델로 만든 10분 타임라인(클립 41개): 18 000프레임 전부의 소스 대응·컷 위치 40곳 = 독립 기대값, 마지막 유효 프레임 17 999",
            pass: ok, ["mismatch": bad, "segments": t.segments.count, "durationFrames": t.durationFrames, "lastValidFrame": t.lastValidFrame ?? -1,
                       "editOps": t.log.count])
}

// MARK: - 오프라인 합성기(내보내기와 같은 읽기 경로)

@MainActor
func offline(_ env: E3Env) async throws {
    monitor.enter("offline-compositor", limitSeconds: 600)
    let log = E2Log(fingerprints: false, diagnoseSource: true)
    let b = try await env.makeBundle(log: log)
    let reader = try AVAssetReader(asset: b.composition)
    reader.timeRange = CMTimeRange(start: .zero, duration: Spec4K.frameTime(Expect3.frameCount))
    let out = AVAssetReaderVideoCompositionOutput(videoTracks: b.composition.tracks(withMediaType: .video),
                                                  videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    out.videoComposition = b.videoComposition
    out.alwaysCopiesSampleData = false
    reader.add(out)
    guard reader.startReading() else { throw E1Error.reader("offline: \(reader.error?.localizedDescription ?? "-")") }
    let tally = FrameTally()
    var n = 0, ptsBad = 0
    var fps = ""
    fps.reserveCapacity(18_000 * 65)
    let t0 = Clock.now()
    while let sb = out.copyNextSampleBuffer() {
        if stopped("offline") { reader.cancelReading(); break }
        autoreleasepool {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            if CMSampleBufferGetPresentationTimeStamp(sb) != Spec4K.frameTime(n) { ptsBad += 1 }
            tally.add(n, E2Metrics.measure(pb))
            fps += Fingerprint.sampled(pb) + "\n"
            n += 1
        }
    }
    let wall = Double(Clock.now() - t0) / 1e9
    try? fps.write(to: runDir.appendingPathComponent("offline-fingerprints.txt"), atomically: true, encoding: .utf8)
    let snap = log.snapshot()
    let timeBad = snap.entries.filter { $0.sourceTimeMatches == false }
    let pixBad = snap.entries.filter { e in
        guard let sid = e.receivedSourceID, let (src, f) = Expect3.source(at: e.content) else { return false }
        return E2Metrics.sourceKeyByID[sid] != src || e.receivedSourceFrame != f
    }
    let ok = reader.status == .completed && n == Expect3.frameCount && ptsBad == 0 && tally.bad == 0 && timeBad.isEmpty && pixBad.isEmpty && snap.errors.isEmpty
    correctness["C1"] = ok
    r.check("C1", "오프라인 합성기 18 000프레임: PTS n/30, 프레임마다 타임라인 코드·소스·소스 프레임·상자·자막·플래시 = 기대값(컷 경계 포함), 받은 소스의 시각·픽셀 불일치 0",
            pass: ok, ["frames": n, "ptsMismatch": ptsBad, "frameMismatch": tally.bad, "issues": tally.issues, "cutIssues": tally.cutIssues,
                       "sourceTimeMismatch": timeBad.prefix(10).map { "\($0.frame)" }, "sourcePixelMismatch": pixBad.prefix(10).map { "\($0.frame)" },
                       "sourceMovieTimeMissing": snap.entries.filter { $0.sourceTimeMatches == nil && !$0.usedHeld }.count,
                       "compositorErrors": Array(snap.errors.prefix(10)), "wallSeconds": wall, "fps": Double(n) / max(wall, 0.001),
                       "copyMs": stats(snap.entries.map { $0.copyMs }), "overlayMs": stats(snap.entries.map { $0.overlayMs }),
                       "fingerprints": "artifacts/runs/\(id)/offline-fingerprints.txt"])
    let (sok, sd) = tally.spectrum()
    correctness["C2"] = sok
    r.check("C2", "오프라인 합성기 스펙트럼: 분별 톤 밴드, 무음 구간 막대 0, 클립 오디오 밴드 0, 음악 클릭 11개 반응", pass: sok, sd)
    let hm = E2Metrics.measure(b.held.buffer)
    let hok = hm?.sourceID == Expect3.sourceIDs["B"] && hm?.sourceFrame == 359
    correctness["H1"] = hok
    r.check("H1", "끝 유지용 보관 프레임 = 마지막 유효 프레임 17 999의 소스(B 359)", pass: hok,
            ["heldTimelineFrame": b.held.timelineFrame, "sourceID": hm?.sourceID ?? -1, "sourceFrame": hm?.sourceFrame ?? -1])
}

// MARK: - 10분 내보내기(보관) + 스트리밍 검증

@MainActor
func exportMain(_ env: E3Env) async throws -> URL? {
    monitor.enter("export", limitSeconds: 900)
    monitor.rebase()
    let log = E2Log(fingerprints: false)
    let b = try await env.makeBundle(log: log)
    let dest = runDir.appendingPathComponent("e3-export-10min-1920x1080.mp4")
    let ctl = ExportControl()
    monitor.setOnStop { _ in ctl.cancel() }
    let w0 = workloadSnapshot()
    let rep = await E2Exporter.run(bundle: b, destination: dest, protectedSources: env.protectedSources, frames: Expect3.frameCount,
                                   control: ctl, experimentsDir: env.experimentsDir, plannedBytes: 900 << 20)
    monitor.setOnStop(nil)
    let snap = log.snapshot()
    let timeBad = snap.entries.filter { $0.sourceTimeMatches == false }.count
    let ok = rep.outcome == "completed" && rep.promoted && rep.tempDirRemoved && snap.errors.isEmpty
    correctness["X1"] = ok
    r.check("X1", "10분 내보내기(합성기 경로, H.264 10 Mbps + AAC): 완료, 승격, 임시 정리, 합성기 오류(소스 시각 불일치 포함) 0. 파일은 보관",
            pass: ok, ["report": rep, "workloadBefore": w0, "loadAvgAfter": loadAvg(), "compositorRequests": snap.entries.count,
                       "sourceTimeMismatch": timeBad, "compositorErrors": Array(snap.errors.prefix(10)),
                       "realtimeFactor": rep.encodeSeconds > 0 ? 600 / rep.encodeSeconds : 0,
                       "copyMs": stats(snap.entries.map { $0.copyMs }), "overlayMs": stats(snap.entries.map { $0.overlayMs }),
                       "retainedPath": rep.outcome == "completed" ? "experiments/e3-fhd-10min/artifacts/runs/\(id)/\(dest.lastPathComponent)" : "-"])
    return rep.outcome == "completed" ? dest : nil
}

@MainActor
func verifyExport(_ url: URL) async throws {
    monitor.enter("export-decode-verify", limitSeconds: 600)
    let tally = FrameTally()
    let info = try await StreamVerifier.run(url) { n, m in tally.add(n, m) }
    let ok2 = info.frames == Expect3.frameCount && info.ptsMismatch == 0 && info.videoRange.duration == Spec4K.frameTime(Expect3.frameCount)
        && info.format["dimensions"] == "1920x1080" && info.format["codec"] == "avc1" && tally.bad == 0
    correctness["X2"] = ok2
    r.check("X2", "디코딩한 10분 내보내기(스트리밍): 18 000프레임, PTS n/30, 비디오 600 s, 1920×1080 avc1, 프레임마다 소스·소스 프레임·타임라인 코드·상자·자막·플래시 = 기대값(컷 경계 40곳 포함)",
            pass: ok2, ["frames": info.frames, "ptsMismatch": info.ptsMismatch, "frameMismatch": tally.bad, "issues": tally.issues, "cutIssues": tally.cutIssues,
                        "videoRange": [info.videoRange.start.seconds, info.videoRange.duration.seconds],
                        "audioRange": [info.audioRange.start.seconds, info.audioRange.duration.seconds], "format": info.format,
                        "fileMiB": mib(UInt64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0)), "verifySeconds": info.seconds])
    let (sok, sd) = tally.spectrum()
    correctness["X3"] = sok
    r.check("X3", "디코딩한 내보내기 스펙트럼: 분별 톤 밴드, 무음, 클립 밴드 0, 음악 클릭 반응", pass: sok, sd)
    let (fok, fd) = tally.flashDrift()
    let (aok, ad) = AudioJudge3.run(onsets: info.onsets)
    var dd = ad; dd["videoFlash"] = fd; dd["decodedAudioSamples"] = info.audioSamples; dd["expectedAudioSamples"] = Expect3.audioSamples
    correctness["X4"] = fok && aok
    r.check("X4", "10분 동기 드리프트: 영상 플래시 n_obs − n_exp(분별), 음악 클릭 11개·클립 클릭(플래시마다) 샘플 차이 ±48 이내, 추가 onset 0",
            pass: fok && aok, dd)
}

// MARK: - 출력 보호(대표 경우)

@MainActor
func protection(_ env: E3Env) async throws {
    monitor.enter("protection", limitSeconds: 600)
    let before = try env.protectedSources.map { try Hashing.sha256(file: $0) }
    func run(_ dest: URL, injectAt: Int? = nil, cancelAt: Int? = nil, planned: UInt64) async throws -> E2ExportReport {
        let box = Locked<ExportControl?>(nil)
        var hook: (@Sendable (Int, Int) -> Void)?
        if let c = cancelAt { hook = { @Sendable n, _ in if n == c { box.get()?.cancel() } } }
        let ctl = ExportControl(injectFailureAtFrame: injectAt, onVideoAppended: hook)
        box.set(ctl)
        monitor.setOnStop { _ in ctl.cancel() }
        defer { monitor.setOnStop(nil) }
        return await E2Exporter.run(bundle: try await env.makeBundle(log: E2Log(fingerprints: false)), destination: dest,
                                    protectedSources: env.protectedSources, frames: Expect3.frameCount, control: ctl,
                                    experimentsDir: env.experimentsDir, plannedBytes: planned)
    }
    let ex = { (u: URL) in FileManager.default.fileExists(atPath: u.path) }
    for (pid, frac, frame) in [("P1", "5%", 900), ("P2", "50%", 9_000)] {
        if stopped(pid) { return }
        let d = runDir.appendingPathComponent("cancel-\(frame).mp4")
        let rep = try await run(d, cancelAt: frame, planned: UInt64(frame) * 6_000)
        let ok = rep.outcome == "cancelled" && !ex(d) && rep.tempDirCreated && rep.tempDirRemoved
        correctness[pid] = ok
        r.check(pid, "취소(진행률 \(frac), \(frame)프레임 뒤): cancelled, 대상 없음, 임시 디렉터리 삭제, 정지·정리 시간 기록", pass: ok, ["report": rep])
    }
    if stopped("P3") { return }
    let dF = runDir.appendingPathComponent("fail-4500.mp4")
    let rf = try await run(dF, injectAt: 4_500, planned: 4_500 * 6_000)
    let okF = rf.outcome == "failed" && rf.errorKind == "injectedFailure" && !ex(dF) && rf.tempDirRemoved
    correctness["P3"] = okF
    r.check("P3", "실패 주입(진행률 25%, 프레임 4 500): failed(injectedFailure), 대상 없음, 임시 디렉터리 삭제", pass: okF, ["report": rf])
    let dE = runDir.appendingPathComponent("existing.mp4")
    try Data("existing output — must survive\n".utf8).write(to: dE)
    let h0 = try Hashing.sha256(file: dE)
    let re = try await run(dE, planned: 0)
    let h1 = try Hashing.sha256(file: dE)
    let okE = re.outcome == "failed" && re.errorKind == "destinationExists" && h0 == h1 && !re.tempDirCreated
    correctness["P4"] = okE
    r.check("P4", "기존 대상: 시작 전 거부, 기존 파일 해시 그대로, 임시 디렉터리 만들지 않음", pass: okE, ["report": re])
    let after = try env.protectedSources.map { try Hashing.sha256(file: $0) }
    let left = OutputGuard.leftovers(in: runDir) + OutputGuard.leftovers(in: env.fixtures)
    let okS = before == after && left.isEmpty
    correctness["P5"] = okS
    r.check("P5", "보호 검사 뒤: 원본(소스 3개·음악) 해시 그대로, 실험 소유 임시 디렉터리 남지 않음", pass: okS,
            ["sources": Dictionary(uniqueKeysWithValues: zip(env.protectedSources.map { $0.lastPathComponent }, after)), "leftovers": left])
}

// MARK: - 실행

let started = Date()
monitor.start()
monitor.enter("load", limitSeconds: 900)
r.sections["run"] = ["id": id, "mode": mode, "os": ProcessInfo.processInfo.operatingSystemVersionString, "workloadStart": workloadSnapshot(),
                     "settings": "1920x1080 30p SDR H.264/AAC, timeline 600 s, generated short sources repeated (experimental, not product limits)"]
r.sections["budgetBefore"] = OwnedBudget.usage(experimentsDir: root.deletingLastPathComponent()).mapValues { mib($0) }
do {
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    // 예약: all = 10분 출력(약 0.75 GB) + 취소 중 임시(최대 약 0.45 GB). 다른 모드는 새 미디어를 만들지 않는다.
    try OwnedBudget.check(experimentsDir: root.deletingLastPathComponent(), adding: mode == "all" ? 1_250 << 20 : 64 << 20)
    say("load env (fixtures, analysis)")
    let env = try await E3Env.load(root: root) { say($0) }
    r.sections["build"] = env.buildIdentity()
    r.sections["fixtures"] = env.fixtureInfo
    monitor.enter("verify-sources", limitSeconds: 300)
    say("verify sources"); try await verifySources(env)
    if mode == "diag-iso" {
        // 진단: 격리 실패 프레임에서 선택 오디오(음악 파일만 분석한 캐시)의 밴드 값. 클립 오디오는 이 캐시에 들어가지 않는다.
        var rows: [String] = []
        for n in [14_459, 14_460, 14_461, 14_462, 14_463, 14_465, 15_899, 15_900, 15_901, 15_902, 15_904, 3_000] {
            if let st = E3Spec.placement.sourceTime(frame: n), let b = env.spectrum.bands(atSourceTime: st) {
                let v = (21...27).map { String(format: "%d:%.3f", $0, b[b.startIndex + $0]) }.joined(separator: " ")
                rows.append("frame \(n) source \(String(format: "%.4f", st.seconds)) s  \(v)")
            }
        }
        r.check("D-iso", "격리 실패 프레임의 선택 오디오(음악만) 분석 캐시 밴드 21~27 값", pass: nil, ["rows": rows])
    }
    if mode == "boundary-check" {
        // 격리 검사에서 뺀 선택 톤 시작·끝 구간(Expect3.toneBoundaryFrames)을 따로 판정한다.
        // 기준: 선택 오디오만 분석한 캐시에서 구한 32개 막대 높이(인접 밴드 번짐 포함). 대조: 실제 섞인 오디오(음악 + 클립)를 분석한 값.
        guard let i = CommandLine.arguments.firstIndex(of: "--run"), CommandLine.arguments.count > i + 1 else { throw E1Error.invalidSource("boundary-check needs --run <id>") }
        let rid = CommandLine.arguments[i + 1]
        let exportURL = root.appendingPathComponent("artifacts/runs/\(rid)/e3-export-10min-1920x1080.mp4")
        let frames = Expect3.toneBoundaryFrames
        let fset = Set(frames)
        func refHeights(_ cache: SpectrumCache, _ t: CMTime?) -> [Int] {
            guard let t, let b = cache.bands(atSourceTime: t) else { return [Int](repeating: 0, count: Spec4K.bandCount) }
            return b.map { Spec4K.barHeight(forValue: $0) }
        }
        let selRef = Dictionary(uniqueKeysWithValues: frames.map { ($0, refHeights(env.spectrum, E3Spec.placement.sourceTime(frame: $0))) })
        // 대조: composition의 오디오 트랙 전부(음악 + 클립)를 같은 분석기로 분석. 시각은 타임라인 시각.
        let log = E2Log(fingerprints: false)
        let b = try await env.makeBundle(log: log)
        let (mix, _) = try SpectrumAnalyzer.analyze(asset: b.composition, tracks: b.composition.tracks(withMediaType: .audio),
                                                   timeRange: CMTimeRange(start: .zero, duration: Spec4K.frameTime(Expect3.frameCount)), sourceID: "mix-control")
        let mixRef = Dictionary(uniqueKeysWithValues: frames.map { ($0, refHeights(mix, Spec4K.frameTime($0))) })
        // 구간별로 짧게 읽는다(무손실 오프라인 합성기, 보관 출력 디코딩)
        let exportAsset = AVURLAsset(url: exportURL)
        guard let exportTrack = try await exportAsset.loadTracks(withMediaType: .video).first else { throw E1Error.invalidSource("export has no video") }
        func readFrames(asset: AVAsset, composition: Bool) throws -> [Int: [Int]] {
            var out: [Int: [Int]] = [:]
            var runs: [(Int, Int)] = []
            for n in frames.sorted() { if let l = runs.last, l.1 + 1 == n { runs[runs.count - 1].1 = n } else { runs.append((n, n)) } }
            for (a, z) in runs {
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: Spec4K.frameTime(a), duration: Spec4K.frameTime(z - a + 1))
                let output: AVAssetReaderOutput
                if composition {
                    let o = AVAssetReaderVideoCompositionOutput(videoTracks: b.composition.tracks(withMediaType: .video),
                                                                 videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    o.videoComposition = b.videoComposition; output = o
                } else {
                    output = AVAssetReaderTrackOutput(track: exportTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                }
                reader.add(output)
                guard reader.startReading() else { throw E1Error.reader("boundary read") }
                while let sb = output.copyNextSampleBuffer() {
                    let n = E2Compositor.frameIndex(CMSampleBufferGetPresentationTimeStamp(sb)).0
                    if fset.contains(n), let pb = CMSampleBufferGetImageBuffer(sb), let m = E2Metrics.measure(pb) { out[n] = m.barHeights }
                }
            }
            return out
        }
        let offline = try readFrames(asset: b.composition, composition: true)
        let decoded = try readFrames(asset: exportAsset, composition: false)
        func compare(_ got: [Int: [Int]], tol: Int) -> (bad: [String], maxDiff: Int, n: Int) {
            var bad: [String] = [], md = 0
            for n in frames { guard let g = got[n], let e = selRef[n] else { bad.append("\(n): missing"); continue }
                let d = zip(g, e).map { abs($0 - $1) }.max() ?? 0; md = max(md, d)
                if d > tol, bad.count < 20 { bad.append("\(n): max diff \(d) (got \(g[20...24]) ref \(e[20...24]))") } }
            return (bad, md, got.count)
        }
        let co = compare(offline, tol: 1), cd = compare(decoded, tol: 3)
        // 대조 감도: 섞인 오디오 기준은 클립 밴드(23·25·27)가 0보다 커서, 측정값이 그것과 같다면(오염) 판정이 달라진다.
        let ctrl = frames.map { n -> (Int, Int, Int) in
            let clipMix = Expect3.clipBands.map { mixRef[n]![$0] }.max() ?? 0
            let clipSel = Expect3.clipBands.map { selRef[n]![$0] }.max() ?? 0
            let clipGot = Expect3.clipBands.map { decoded[n]?[$0] ?? -1 }.max() ?? -1
            return (clipMix, clipSel, clipGot)
        }
        let sensitive = ctrl.filter { $0.0 > $0.1 + 3 }.count
        let leakFrames = frames.filter { (selRef[$0].map { r in Expect3.clipBands.contains { r[$0] > 0 } } ?? false) }
        let ok = co.bad.isEmpty && cd.bad.isEmpty && co.n == frames.count && cd.n == frames.count && sensitive == frames.count
        correctness["B1"] = ok
        r.check("B1", "선택 톤 시작·끝 구간(격리 검사에서 뺀 \(frames.count)프레임): 32개 막대 = 선택 오디오만의 기준 높이(번짐 포함, 무손실 ±1 px, 디코딩 ±3 px). 대조: 섞인 오디오 기준은 모든 프레임에서 클립 밴드가 기준보다 커서 오염을 구별한다",
                pass: ok, ["frames": frames.count, "offlineMaxDiffPx": co.maxDiff, "offlineIssues": co.bad, "decodedMaxDiffPx": cd.maxDiff, "decodedIssues": cd.bad,
                           "framesWithSelectedSourceLeakIntoClipBands": leakFrames, "controlSensitiveFrames": sensitive,
                           "controlSample": ctrl.prefix(6).map { "mix clip \($0.0) px, selected-only \($0.1) px, decoded \($0.2) px" },
                           "retainedExport": "artifacts/runs/\(rid)/\(exportURL.lastPathComponent)"])
    }
    if mode == "reverify" {
        // 이미 보관한 10분 내보내기를 다시 검증한다(새 내보내기·보호 검사 없음). 오프라인 합성기도 다시 돈다.
        guard let i = CommandLine.arguments.firstIndex(of: "--run"), CommandLine.arguments.count > i + 1 else { throw E1Error.invalidSource("reverify needs --run <id>") }
        let rid = CommandLine.arguments[i + 1]
        let u = root.appendingPathComponent("artifacts/runs/\(rid)/e3-export-10min-1920x1080.mp4")
        r.sections["reverifiedExport"] = ["run": rid, "path": "experiments/e3-fhd-10min/artifacts/runs/\(rid)/\(u.lastPathComponent)",
                                          "sha256": (try? Hashing.sha256(file: u)) ?? "missing"]
        timelineCheck(env)
        if !stopped("before offline") { say("offline compositor"); try await offline(env) }
        if !stopped("before verify") { say("verify retained export"); try await verifyExport(u) }
    }
    if mode == "all" {
        timelineCheck(env)
        if !stopped("before offline") { say("offline compositor"); try await offline(env) }
        var exported: URL?
        if !stopped("before export") { say("export 10 min"); exported = try await exportMain(env) }
        if let u = exported, !stopped("before verify") { say("verify export"); try await verifyExport(u) }
        if !stopped("before protection") { say("protection"); try await protection(env) }
    }
} catch {
    r.check("ABORT", "실행 중단", pass: false, ["error": "\(error)"])
    stoppedAt = stoppedAt ?? "error: \(error)"
}
monitor.enter("cleanup", limitSeconds: 120)
try? await Task.sleep(nanoseconds: 10_000_000_000)
monitor.stopSampling()
monitor.writeCSV(to: runDir.appendingPathComponent("memory-e3.csv"))
r.sections["memory"] = monitor.summary()
r.sections["memoryCSV"] = "artifacts/runs/\(id)/memory-e3.csv"
r.sections["budgetAfter"] = OwnedBudget.usage(experimentsDir: root.deletingLastPathComponent()).mapValues { mib($0) }
r.sections["budgetTotalMiB"] = mib(OwnedBudget.total(experimentsDir: root.deletingLastPathComponent()))
r.sections["workloadEnd"] = workloadSnapshot()
r.sections["wallSecondsTotal"] = Date().timeIntervalSince(started)
let execution = stoppedAt == nil ? "complete" : "stopped (\(stoppedAt!))"
let correctnessFailed = correctness.filter { !$0.value }.map { $0.key }.sorted()
r.sections["status"] = ["execution": execution, "correctnessChecks": correctness.count, "correctnessFailed": correctnessFailed,
                        "correctnessPassed": correctnessFailed.isEmpty && stoppedAt == nil,
                        "note": "실행 완료와 정확도 통과는 별개다. 성능 값은 기준 없는 기록이다."]
let url = root.appendingPathComponent("results").appendingPathComponent("e3-\(mode == "all" ? "run" : mode)-\(id).json")
do { try r.write(to: url); say("results: results/\(url.lastPathComponent)  execution: \(execution)  correctness failed: \(correctnessFailed)") } catch { print("write failed \(error)") }
exit(r.summary.fail.isEmpty && stoppedAt == nil ? 0 : 1)
