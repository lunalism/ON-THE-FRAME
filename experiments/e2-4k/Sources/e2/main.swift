// E2 헤드리스 실행기: fixture 생성·검증, 편집 타임라인, 오프라인 합성기, 4K 내보내기 + 디코딩 검증, 출력 보호·취소·실패.
// 사용(experiments/e2-4k 디렉터리에서):
//   .build/release/e2 fixtures     fixture만 만들고 검증
//   .build/release/e2 all          전체 검사 → results/e2-run-<UTC 시각>.json, 출력은 artifacts/runs/<UTC 시각>/
import AVFoundation
import CoreMedia
import E1Core
import E2Core
import E2Expect
import E2Judge
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard ["fixtures", "all", "inspect"].contains(mode) else {
    print("usage: e2 fixtures | all | inspect   (experiments/e2-4k 디렉터리에서)"); exit(2)
}

/// 진단: 소스 인코딩 구조(PTS/DTS, 동기 샘플)와 composition 구간 대응
func inspectChecks(_ r: Report, _ env: E2Env) async throws {
    for spec in SourceVideoSpec.all {
        let rep = try await EncodingInspector.inspect(env.sources[spec.key]!, around: [0, 20, 30, 31, 32, 90, 91, 92, 150, 151, 152])
        // 같은 디코딩 검증(코드·상자·배경·클릭)도 비교 fixture에 적용한다
        _ = rep
        r.check("I-src-\(spec.key)", "소스 \(spec.key) 압축 샘플 구조(재정렬 샘플 수, 동기 샘플 위치, 시간 단위)", pass: nil, ["report": rep])
    }
    let b = try await env.makeBundle(log: E2Log(fingerprints: false))
    r.check("I-comp", "composition 비디오 트랙 구간 대응과 합성 명령 범위·프레임 간격", pass: nil,
            ["segments": EncodingInspector.segments(b.composition, trackID: b.videoTrackID),
             "frameDuration": "\(b.videoComposition.frameDuration.value)/\(b.videoComposition.frameDuration.timescale)",
             "instructions": b.videoComposition.instructions.map { "\($0.timeRange.start.value)/\($0.timeRange.start.timescale) +\($0.timeRange.duration.value)/\($0.timeRange.duration.timescale)" },
             "videoTrackID": b.videoTrackID])
}

func mib(_ b: UInt64) -> Double { Double(b) / 1_048_576 }
func loadAvg() -> [Double] { var l = [Double](repeating: -1, count: 3); _ = getloadavg(&l, 3); return l }

// MARK: - 소스 fixture 검증(디코딩)

func verifySources(_ r: Report, _ env: E2Env) async throws {
    for spec in SourceVideoSpec.all {
        let url = env.sources[spec.key]!
        let d = try await E2Decoder.decode(url)
        var bad: [String] = []
        for (i, f) in d.frames.enumerated() {
            guard let m = f.metrics else { bad.append("\(i) unmeasurable"); continue }
            if CMTime(value: f.ptsValue, timescale: f.ptsTimescale) != Spec4K.frameTime(i) { bad.append("\(i) pts") }
            if m.sourceID != spec.idCode || m.sourceFrame != i { bad.append("\(i) code \(m.sourceID)/\(m.sourceFrame)") }
            if abs(m.boxX - Spec4K.boxX(i)) > Judge.boxTolerance { bad.append("\(i) box \(m.boxX)") }
            if zip(m.background, spec.background).contains(where: { abs($0 - Int($1)) > 12 }) { bad.append("\(i) bg \(m.background)") }
        }
        let on = E2Decoder.onsets(d.mono)
        let want = spec.clipAudio.clickStartSamples
        let deltas = want.map { e in on.map { $0 - e }.min { abs($0) < abs($1) } ?? Int.max }
        let audioOK = deltas.allSatisfy { abs($0) <= Judge.onsetTolerance } && on.count == want.count
        r.check("F-src-\(spec.key)", "소스 영상 \(spec.key)(H.264 4K 30p + AAC): 디코딩 프레임 수·PTS·소스 ID·프레임 번호·이동 상자·배경, 오디오 클릭 위치",
                pass: d.frames.count == spec.frames && bad.isEmpty && audioOK,
                ["frames": d.frames.count, "expectedFrames": spec.frames, "issues": Array(bad.prefix(10)), "format": d.videoFormat,
                 "audioFormat": d.audioFormat, "fileMiB": mib(d.fileBytes), "clickDeltasSamples": deltas, "onsets": on.count,
                 "audioSamples": d.mono.count, "decodeSeconds": d.wallSeconds])
    }
}

// MARK: - 편집 타임라인

func timelineChecks(_ r: Report, _ env: E2Env) async {
    let t = env.timeline
    let segs = t.segments
    let match = segs.count == Expect2.segments.count && zip(segs, Expect2.segments).allSatisfy {
        $0.start == $1.start && $0.start + $0.length == $1.end && $0.source == $1.source && $0.sourceIn == $1.sourceIn
    }
    let boundaries = Expect2.boundaryFrames.map { (n, s, f) -> [String: Any] in
        let got = t.sourceFrame(at: n)
        return ["frame": n, "expected": "\(s)\(f)", "model": got.map { "\($0.source)\($0.frame)" } ?? "nil", "ok": got?.source == s && got?.frame == f]
    }
    r.check("T1", "편집 모델(붙이기·트림·분할·트림·이동): 결과 구간과 컷 경계의 소스 대응 = 독립 기대값, 길이 300, 마지막 유효 프레임 299",
            pass: match && boundaries.allSatisfy { $0["ok"] as? Bool == true } && t.durationFrames == 300 && t.lastValidFrame == 299,
            ["editLog": t.log, "segments": segs.map { "[\($0.start), \($0.start + $0.length)) \($0.clip) \($0.source)@\($0.sourceIn)" },
             "boundaries": boundaries, "lastValidFrame": t.lastValidFrame ?? -1])
    // 잘못된 편집과 빈 타임라인은 거부
    var rejects: [String: String] = [:]
    var x = env.timeline
    do { try x.trim(0, sourceIn: 200, length: 100); rejects["trim beyond source"] = "accepted" } catch { rejects["trim beyond source"] = "\(error)" }
    do { try x.split(atTimelineFrame: 90, names: ("x", "y")); rejects["split at cut"] = "accepted" } catch { rejects["split at cut"] = "\(error)" }
    do { try x.trim(0, sourceIn: 0, length: 0); rejects["zero length"] = "accepted" } catch { rejects["zero length"] = "\(error)" }
    let empty = EditTimeline(sourceLengths: ["A": 240])
    do { _ = try await env.makeBundle(log: E2Log(fingerprints: false), timeline: empty); rejects["empty timeline build"] = "accepted" }
    catch { rejects["empty timeline build"] = "\(error)" }
    r.check("T2", "잘못된 편집(소스 밖 트림, 컷 위치 분할, 길이 0)과 빈 타임라인 composition 구성은 거부",
            pass: !rejects.values.contains("accepted"), ["rejections": rejects])
}

// MARK: - 오프라인 합성기(내보내기와 같은 읽기 경로, 무손실 출력 측정)

func offlineCompositor(_ r: Report, _ env: E2Env) async throws -> [String] {
    let log = E2Log(fingerprints: true)
    let b = try await env.makeBundle(log: log)
    let reader = try AVAssetReader(asset: b.composition)
    reader.timeRange = CMTimeRange(start: .zero, duration: Spec4K.frameTime(300))
    let out = AVAssetReaderVideoCompositionOutput(videoTracks: b.composition.tracks(withMediaType: .video),
                                                  videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    out.videoComposition = b.videoComposition
    out.alwaysCopiesSampleData = false
    reader.add(out)
    guard reader.startReading() else { throw E1Error.reader("offline: \(reader.error?.localizedDescription ?? "-")") }
    let t0 = Clock.now()
    var byFrame: [Int: E2Metrics] = [:]
    var issues: [String] = []
    var n = 0, ptsBad = 0
    var fingerprints: [String] = []
    while let sb = out.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        if CMSampleBufferGetPresentationTimeStamp(sb) != Spec4K.frameTime(n) { ptsBad += 1 }
        let m = E2Metrics.measure(pb)
        byFrame[n] = m
        issues += Judge.frameIssues(timeIndex: n, m).map { "\(n): \($0)" }
        fingerprints.append(Fingerprint.sampled(pb))
        n += 1
    }
    let wall = Double(Clock.now() - t0) / 1e9
    let snap = log.snapshot()
    let (specOK, specDetail) = Judge.spectrum(byFrame)
    r.check("C1", "오프라인 합성기(AVAssetReaderVideoCompositionOutput, 내보내기와 같은 읽기 경로): 300프레임, PTS n/30, 프레임마다 타임라인 코드·소스 ID·소스 프레임·이동 상자·자막 = 독립 기대값",
            pass: reader.status == .completed && n == 300 && ptsBad == 0 && issues.isEmpty && snap.errors.isEmpty
                && !snap.entries.contains { $0.sourceFrameNil || $0.usedHeld },
            ["frames": n, "ptsMismatch": ptsBad, "issues": Array(issues.prefix(20)), "compositorRequests": snap.entries.count,
             "frameTiming": b.videoComposition.sourceTrackIDForFrameTiming == b.videoTrackID ? "source video track" : "frameDuration",
             "staleSourceFrames": snap.entries.filter { $0.sourceTimeMatches == false }.map { $0.frame },
             "sourceMovieTimeMissing": snap.entries.filter { $0.sourceTimeMatches == nil && !$0.usedHeld }.count,
             "compositorErrors": snap.errors, "maxInFlight": snap.maxInFlight, "wallSeconds": wall, "fps": Double(n) / wall,
             "copyMs": stats(snap.entries.map { $0.copyMs }), "overlayMs": stats(snap.entries.map { $0.overlayMs })])
    r.check("C2", "선택 오디오 스펙트럼(오프라인 합성기 출력): 톤 구간 최대 밴드, 무음 구간 막대 0, 클립 오디오 밴드(23·25·27) 0, 클릭 반응 프레임",
            pass: specOK, specDetail)
    let hm = E2Metrics.measure(b.held.buffer)
    r.check("H1", "끝 유지용 보관 프레임 = 마지막 유효 프레임 299의 소스(B 209)",
            pass: hm?.sourceID == Expect2.sourceIDs["B"] && hm?.sourceFrame == 209,
            ["heldTimelineFrame": b.held.timelineFrame, "sourceID": hm?.sourceID ?? -1, "sourceFrame": hm?.sourceFrame ?? -1])
    // 대조: 클립 오디오 트랙만 분석하면 클립 밴드가 반응한다(격리 검사가 차이를 잡을 수 있다는 근거)
    if let ct = b.composition.track(withTrackID: b.clipAudioTrackID) {
        let (cache, _) = try SpectrumAnalyzer.analyze(asset: b.composition, tracks: [ct], timeRange: nil, sourceID: "clip-audio-control")
        func band(_ s: Double, _ k: Int) -> Float { cache.bands(atSourceTime: CMTime(seconds: s, preferredTimescale: 600)).map { $0[$0.startIndex + k] } ?? -1 }
        let probes: [[String: Any]] = [(1.5, 23, "A"), (4.5, 27, "C"), (7.0, 25, "B.1"), (9.0, 25, "B.2")].map {
            ["t": $0.0, "band": $0.1, "clip": $0.2, "value": band($0.0, $0.1)]
        }
        r.check("C2-control", "대조: 클립 오디오 트랙을 분석하면 해당 클립 밴드(23·25·27)가 0보다 크다(선택 오디오만 쓰지 않으면 격리 검사가 실패해야 함)",
                pass: probes.allSatisfy { ($0["value"] as? Float ?? 0) > 0.3 }, ["probes": probes])
    }
    return fingerprints
}

// MARK: - 내보내기 + 디코딩 검증

func exportAndVerify(_ r: Report, _ env: E2Env, runDir: URL) async throws {
    let log = E2Log(fingerprints: false)
    let b = try await env.makeBundle(log: log)
    let dest = runDir.appendingPathComponent("e2-export.mp4")
    let ctl = ExportControl()
    let load0 = loadAvg()
    let rep = await E2Exporter.run(bundle: b, destination: dest, protectedSources: env.protectedSources, frames: 300,
                                   control: ctl, experimentsDir: env.experimentsDir)
    let snap = log.snapshot()
    r.check("X1", "4K 내보내기(합성기 경로, H.264 + AAC): 완료, 승격, 임시 디렉터리 정리",
            pass: rep.outcome == "completed" && rep.promoted && rep.tempDirRemoved && snap.errors.isEmpty,
            ["report": rep, "loadAvgBefore": load0, "loadAvgAfter": loadAvg(), "compositorRequests": snap.entries.count,
             "staleSourceFrames": snap.entries.filter { $0.sourceTimeMatches == false }.map { $0.frame },
             "sourceMovieTimeMissing": snap.entries.filter { $0.sourceTimeMatches == nil && !$0.usedHeld }.count,
             "compositorErrors": snap.errors, "copyMs": stats(snap.entries.map { $0.copyMs }), "overlayMs": stats(snap.entries.map { $0.overlayMs }),
             "realtimeFactor": rep.encodeSeconds > 0 ? 10.0 / rep.encodeSeconds : 0])
    guard rep.outcome == "completed" else { return }
    let d = try await E2Decoder.decode(dest)
    var ptsBad = 0
    var byFrame: [Int: E2Metrics] = [:]
    var issues: [String] = []
    for (i, f) in d.frames.enumerated() {
        if CMTime(value: f.ptsValue, timescale: f.ptsTimescale) != Spec4K.frameTime(i) { ptsBad += 1 }
        byFrame[i] = f.metrics
        issues += Judge.frameIssues(timeIndex: i, f.metrics).map { "\(i): \($0)" }
    }
    r.check("X2", "디코딩한 내보내기: 300프레임, PTS n/30, 비디오 10 s, 3840×2160 H.264, 프레임마다 소스 ID·소스 프레임·타임라인 코드·이동 상자·자막 = 독립 기대값(컷 경계 포함)",
            pass: d.frames.count == 300 && ptsBad == 0 && d.videoTrackRange.duration == Spec4K.frameTime(300)
                && d.videoFormat["dimensions"] == "3840x2160" && d.videoFormat["codec"] == "avc1" && issues.isEmpty,
            ["frames": d.frames.count, "ptsMismatch": ptsBad, "videoRange": [d.videoTrackRange.start.seconds, d.videoTrackRange.duration.seconds],
             "audioRange": [d.audioTrackRange.start.seconds, d.audioTrackRange.duration.seconds], "format": d.videoFormat,
             "audioFormat": d.audioFormat, "issues": Array(issues.prefix(20)), "fileMiB": mib(d.fileBytes), "decodeSeconds": d.wallSeconds,
             "boundaries": Expect2.boundaryFrames.map { (n, s, f) -> [String: Any] in
                 let m = byFrame[n]; return ["frame": n, "expected": "\(s)\(f)", "decoded": m.map { "\($0.sourceKey)\($0.sourceFrame)" } ?? "nil"] }])
    let (specOK, specDetail) = Judge.spectrum(byFrame)
    r.check("X3", "디코딩한 내보내기의 스펙트럼: 선택 오디오 톤·무음·클릭 반응, 클립 오디오 밴드 0", pass: specOK, specDetail)
    let onsets = E2Decoder.onsets(d.mono)
    let (audioOK, audioDetail) = Judge.audio(onsets: onsets)
    var ad = audioDetail
    ad["decodedSamples"] = d.mono.count
    ad["expectedSamples"] = Expect2.audioSamples
    r.check("X4", "디코딩한 내보내기 오디오: 음악 클릭 3개와 편집 뒤 남은 클립 오디오 클릭 10개가 기대 타임라인 위치(±1 ms), 잘려 나간 클릭 없음",
            pass: audioOK, ad)
}

// MARK: - 출력 보호, 취소, 실패(합성기 경로)

func protectionChecks(_ r: Report, _ env: E2Env, runDir: URL) async throws {
    let before = try env.protectedSources.map { try Hashing.sha256(file: $0) }
    func bundle() async throws -> E2Bundle { try await env.makeBundle(log: E2Log(fingerprints: false)) }
    func run(_ name: String, injectAt: Int? = nil, hook: (@Sendable (Int, ExportControl) -> Void)? = nil, dest: URL) async throws -> (E2ExportReport, ExportControl) {
        let box = Locked<ExportControl?>(nil)
        var appended: (@Sendable (Int, Int) -> Void)?
        if let h = hook { appended = { @Sendable n, _ in if let c = box.get() { h(n, c) } } }
        let ctl = ExportControl(injectFailureAtFrame: injectAt, onVideoAppended: appended)
        box.set(ctl)
        let rep = await E2Exporter.run(bundle: try await bundle(), destination: dest, protectedSources: env.protectedSources, frames: 300,
                                       control: ctl, experimentsDir: env.experimentsDir)
        return (rep, ctl)
    }
    let exists = { (u: URL) in FileManager.default.fileExists(atPath: u.path) }

    // 취소: 60프레임을 넣은 직후 취소
    let dCancel = runDir.appendingPathComponent("cancel.mp4")
    let (rc, _) = try await run("cancel", hook: { n, c in if n == 60 { c.cancel() } }, dest: dCancel)
    r.check("P1", "취소(60프레임 뒤): cancelled, 대상 없음, 임시 디렉터리 삭제, 정지 시간 기록",
            pass: rc.outcome == "cancelled" && !exists(dCancel) && rc.tempDirCreated && rc.tempDirRemoved, ["report": rc])
    // 실패 주입: 90번째 프레임 직전
    let dFail = runDir.appendingPathComponent("fail.mp4")
    let (rf, _) = try await run("fail", injectAt: 90, dest: dFail)
    r.check("P2", "실패 주입(프레임 90): failed(injectedFailure), 대상 없음, 임시 디렉터리 삭제",
            pass: rf.outcome == "failed" && rf.errorKind == "injectedFailure" && !exists(dFail) && rf.tempDirRemoved, ["report": rf])
    // 기존 대상 보존
    let dExist = runDir.appendingPathComponent("existing.mp4")
    try Data("existing output — must survive\n".utf8).write(to: dExist)
    let h0 = try Hashing.sha256(file: dExist)
    let (re, _) = try await run("exists", dest: dExist)
    let h1 = try Hashing.sha256(file: dExist)
    r.check("P3", "기존 대상: 시작 전 거부(destinationExists), 기존 파일 해시 그대로, 임시 디렉터리 만들지 않음",
            pass: re.outcome == "failed" && re.errorKind == "destinationExists" && h1 == h0 && !re.tempDirCreated, ["report": re])
    // 실행 중 대상이 생김: 승격이 덮어쓰지 않음
    let dRace = runDir.appendingPathComponent("race.mp4")
    let raceBytes = Data("appeared during export — must survive\n".utf8)
    let (rr, _) = try await run("race", hook: { n, _ in if n == 150 { try? raceBytes.write(to: dRace) } }, dest: dRace)
    let raceSurvived = (try? Data(contentsOf: dRace)) == raceBytes
    r.check("P4", "실행 중 대상 생성: 승격 거부(promotionConflict, RENAME_EXCL), 그 파일 그대로, 임시 디렉터리 삭제",
            pass: rr.outcome == "failed" && rr.errorKind == "promotionConflict" && raceSurvived && rr.tempDirRemoved, ["report": rr, "fileSurvived": raceSurvived])
    // 원본 경로를 대상으로
    let (rs, _) = try await run("source", dest: env.sources["A"]!)
    r.check("P5", "원본을 대상으로 지정: 거부(destinationIsSource)", pass: rs.outcome == "failed" && rs.errorKind == "destinationIsSource", ["report": rs])
    let after = try env.protectedSources.map { try Hashing.sha256(file: $0) }
    let leftovers = OutputGuard.leftovers(in: runDir) + OutputGuard.leftovers(in: env.fixtures)
    r.check("P6", "보호 검사 뒤: 원본(소스 영상 3개·음악) 해시 그대로, 실험 임시 디렉터리 남지 않음",
            pass: before == after && leftovers.isEmpty, ["sources": Dictionary(uniqueKeysWithValues: zip(env.protectedSources.map { $0.lastPathComponent }, after)),
                                                       "leftovers": leftovers])
}

// MARK: - 실행

let r = Report()
let id = runID()
let started = Date()
do {
    let usage0 = OwnedBudget.usage(experimentsDir: root.deletingLastPathComponent())
    r.sections["budgetBefore"] = usage0.mapValues { mib($0) }
    try OwnedBudget.check(experimentsDir: root.deletingLastPathComponent(), adding: 256 << 20)
    // inspect --no-reorder: 진단용 비교 fixture(재정렬 끔)를 만들거나 검사한다. 원래 v2 fixture는 바꾸지 않는다.
    let env = try await E2Env.load(root: root, allowFrameReordering: !(mode == "inspect" && CommandLine.arguments.contains("--no-reorder")))
    r.sections["build"] = env.buildIdentity()
    r.sections["run"] = ["id": id, "mode": mode, "os": ProcessInfo.processInfo.operatingSystemVersionString, "loadAvgStart": loadAvg(),
                         "settings": "3840x2160 30p SDR H.264/AAC, timeline 10 s, generated fixtures (experimental, not product limits)"]
    r.sections["fixtures"] = env.fixtureInfo
    if mode == "inspect" { try await inspectChecks(r, env); try await verifySources(r, env) } else { try await verifySources(r, env) }
    if mode == "all" {
        await timelineChecks(r, env)
        _ = try await offlineCompositor(r, env)
        let runDir = env.artifacts.appendingPathComponent("runs").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try await exportAndVerify(r, env, runDir: runDir)
        try await protectionChecks(r, env, runDir: runDir)
        r.sections["runDir"] = "artifacts/runs/\(id)"
    }
} catch {
    r.check("ABORT", "실행 중단", pass: false, ["error": "\(error)"])
}
r.sections["budgetAfter"] = OwnedBudget.usage(experimentsDir: root.deletingLastPathComponent()).mapValues { mib($0) }
r.sections["budgetTotalMiB"] = mib(OwnedBudget.total(experimentsDir: root.deletingLastPathComponent()))
r.sections["peakFootprintMiBAtEnd"] = mib(Memory.physFootprint())
r.sections["wallSecondsTotal"] = Date().timeIntervalSince(started)
let url = root.appendingPathComponent("results").appendingPathComponent("e2-\(mode == "all" ? "run" : mode)\(CommandLine.arguments.contains("--no-reorder") ? "-noreorder" : "")-\(id).json")
do { try r.write(to: url); print("results: results/\(url.lastPathComponent)") } catch { print("write failed: \(error)") }
exit(r.summary.fail.isEmpty ? 0 : 1)
