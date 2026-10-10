// E1-a 헤드리스 FHD 실험 실행기.
// 사용: experiments/e1-fhd 디렉터리에서 `.build/release/e1 all` (또는 `fixtures`)
import AVFoundation
import CoreMedia
import E1Core
import E1Expect
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 경로와 예산

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
      root.lastPathComponent == "e1-fhd" else {
    FileHandle.standardError.write("experiments/e1-fhd 디렉터리에서 실행해야 한다\n".data(using: .utf8)!)
    exit(2)
}
let artifacts = root.appendingPathComponent("artifacts")
let fixturesDir = artifacts.appendingPathComponent("fixtures")
let cacheDir = artifacts.appendingPathComponent("cache")
let framesDir = artifacts.appendingPathComponent("frames")
let runsDir = artifacts.appendingPathComponent("runs")
let resultsDir = root.appendingPathComponent("results")
let budgetBytes: UInt64 = 2 << 30            // 실험 소유 산출물(artifacts + .build) 상한 2 GiB
let budgetMargin: UInt64 = 128 << 20         // 내보내기 1회 여유분

func rel(_ u: URL) -> String {
    let p = u.standardizedFileURL.path, r = root.standardizedFileURL.path + "/"
    return p.hasPrefix(r) ? String(p.dropFirst(r.count)) : p
}

func artifactUsage() -> [String: UInt64] {
    [
        "artifacts/fixtures": DiskUsage.allocatedBytes(fixturesDir),
        "artifacts/cache": DiskUsage.allocatedBytes(cacheDir),
        "artifacts/frames": DiskUsage.allocatedBytes(framesDir),
        "artifacts/runs": DiskUsage.allocatedBytes(runsDir),
        ".build": DiskUsage.allocatedBytes(root.appendingPathComponent(".build")),
    ]
}

func checkBudget() throws {
    let used = artifactUsage().values.reduce(0, +)
    if used + budgetMargin > budgetBytes {
        throw E1Error.budgetExceeded("experiment-owned artifacts \(used) bytes + margin would exceed 2 GiB; stopping")
    }
}

// MARK: - 보고

final class Report {
    var checks: [[String: Any]] = []
    var sections: [String: Any] = [:]

    func check(_ id: String, _ name: String, pass: Bool?, _ detail: [String: Any] = [:]) {
        var d = detail
        d["id"] = id; d["name"] = name
        d["result"] = pass.map { $0 ? "PASS" : "FAIL" } ?? "RECORD"
        checks.append(d)
        let tag = pass.map { $0 ? "PASS" : "FAIL" } ?? "REC "
        let brief = detail.filter { !($0.value is [Any]) && !($0.value is [String: Any]) }
            .sorted { $0.key < $1.key }.prefix(6).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[\(tag)] \(id) \(name)  \(brief)")
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

func encodable<T: Encodable>(_ v: T) -> Any {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) ?? "\(v)"
}

// MARK: - fixture

struct Fixtures { let s: SourceRef; let u: SourceRef; let probe: SourceRef; let carrier: URL; let carrierSha: String }

func ensureFixtures(_ report: Report) async throws -> Fixtures {
    try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
    var refs: [String: SourceRef] = [:]
    var manifest: [[String: Any]] = []
    let items: [(String, AudioFixtureSpec)] = [
        ("S-selected.wav", .selected), ("U-unrelated.wav", .unrelated), ("S-rename-probe.wav", .selected),
    ]
    for (file, spec) in items {
        let url = fixturesDir.appendingPathComponent(file)
        let data = spec.wavData()
        let generated = Hashing.sha256(data)
        var created = false
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .withoutOverwriting)   // 기존 파일은 덮어쓰지 않는다
            created = true
        }
        let onDisk = try Hashing.sha256(file: url)
        refs[file] = SourceRef(id: onDisk, path: url.path)
        manifest.append(["file": rel(url), "sha256": onDisk, "regeneratedSha256": generated,
                         "createdThisRun": created, "bytes": data.count, "spec": encodable(spec)])
        report.check("F-\(file)", "fixture 재현성(재생성 해시 = 디스크 해시)", pass: onDisk == generated,
                     ["sha256": String(onDisk.prefix(16)), "created": created])
    }
    // 합성기 composition의 비디오 운반 트랙용 영상. 인코더 출력의 비트 재현성은 보장되지 않으므로 없을 때만 만들고 해시를 기록한다.
    let carrier = fixturesDir.appendingPathComponent("carrier-160x90-10s.mov")
    let cr = try await CarrierVideo.ensure(at: carrier)
    manifest.append(["file": rel(carrier), "sha256": cr.sha256, "createdThisRun": cr.created,
                     "spec": "H.264 \(CarrierVideo.width)x\(CarrierVideo.height), 300 frames at n/30, black"])
    report.sections["fixtures"] = manifest
    return Fixtures(s: refs["S-selected.wav"]!, u: refs["U-unrelated.wav"]!, probe: refs["S-rename-probe.wav"]!,
                    carrier: carrier, carrierSha: cr.sha256)
}

func state(_ c: CaseExpect, _ fx: Fixtures, withU: Bool, selected: SourceRef? = nil) -> TimelineState {
    TimelineState(
        selected: ClipPlacement(source: selected ?? fx.s, sourceIn: CMTime(value: c.sIn, timescale: 1),
                                duration: CMTime(value: c.dur, timescale: 1), timelineStart: CMTime(value: c.tStart, timescale: 1)),
        unrelated: withU ? ClipPlacement(source: fx.u, sourceIn: .zero, duration: Spec.duration, timelineStart: .zero) : nil)
}

func frames(in span: (Double, Double), startPad: Double, endPad: Double) -> [Int] {
    Expect.frames(in: span, startPad: startPad, endPad: endPad)
}

func argmax(_ v: [Float]) -> Int { v.indices.max { v[$0] < v[$1] }! }
func argmaxI(_ v: [Int]) -> Int { v.indices.max { v[$0] < v[$1] }! }

func savePNG(_ pb: CVPixelBuffer, _ url: URL) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Spec.width, height: Spec.height, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
          let img = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

// MARK: - 렌더링(합성 단계) 검사 — TECHNOLOGY-EVALUATION §6.4.1

func renderChecks(_ report: Report, _ fx: Fixtures, _ sCache: SpectrumCache) async throws {
    let c1 = Expect.cases[0]
    let layout = FrameRenderer.captionLayout()
    report.sections["captionLayout"] = [
        "font": layout.fontPostScriptName, "runFonts": layout.runFonts, "glyphCount": layout.glyphCount,
        "missingGlyphs": layout.missingGlyphs,
        "inkRectTopLeft": [layout.inkRectTopLeft.minX, layout.inkRectTopLeft.minY, layout.inkRectTopLeft.width, layout.inkRectTopLeft.height],
        "pixelFormat": "32BGRA premultipliedFirst byteOrder32Little", "colorSpace": "sRGB (context); buffers untagged",
    ]

    // R0 원본 식별: 다른 원본의 캐시로는 렌더러를 만들 수 없어야 한다
    let (uCache, _) = try await SpectrumAnalyzer.analyzeSelectedSource(fx.u, cacheDir: cacheDir)
    var rejected = false
    do { _ = try FrameRenderer(state: state(c1, fx, withU: false), spectrum: uCache) } catch { rejected = true }
    report.check("R0", "선택 소스 식별: 다른 원본(U)의 분석 캐시 연결 거부", pass: rejected)

    // R1 결정성
    let st4 = state(Expect.cases[3], fx, withU: true)
    let rA = try FrameRenderer(state: st4, spectrum: sCache)
    let rB = try FrameRenderer(state: st4, spectrum: sCache)
    let testFrames = [0, 59, 60, 105, 106, 120, 180, 239, 240, 299]
    var mismatches: [String] = []
    var hashes: [String: String] = [:]
    for n in testFrames {
        let b1 = try FrameRenderer.makeBuffer(), b2 = try FrameRenderer.makeBuffer(), b3 = try FrameRenderer.makeBuffer()
        try rA.render(frame: n, into: b1)
        try rA.render(frame: n, into: b2)
        try rB.render(frame: n, into: b3)
        // 다른 스레드: 그 스레드에서 버퍼를 만들고 0xAB로 채운 뒤 렌더링해 해시만 돌려받는다(버퍼 공유 없음)
        let otherThreadHash: String = await withCheckedContinuation { k in
            DispatchQueue.global(qos: .utility).async {
                guard let b4 = try? FrameRenderer.makeBuffer() else { k.resume(returning: "alloc-failed"); return }
                PixelCompare.fill(b4, byte: 0xAB)
                if (try? rB.render(frame: n, into: b4)) == nil { k.resume(returning: "render-failed"); return }
                k.resume(returning: PixelCompare.sha256(b4))
            }
        }
        let h = PixelCompare.sha256(b1)
        hashes["\(n)"] = h
        for (name, b) in [("repeat", b2), ("newInstance", b3)] where !PixelCompare.equal(b1, b) {
            mismatches.append("frame \(n) \(name)")
        }
        if otherThreadHash != h { mismatches.append("frame \(n) otherThread+dirtyBuffer") }
    }
    report.check("R1", "결정적 렌더링(반복·새 인스턴스·다른 스레드·더러운 버퍼, 비트 단위)", pass: mismatches.isEmpty,
                 ["frames": testFrames, "mismatches": mismatches])
    report.sections["renderHashesCase4WithU"] = hashes

    // R2 자막 위치 / R4 표시 경계
    let r1 = try FrameRenderer(state: state(c1, fx, withU: false), spectrum: sCache)
    let withCap = try FrameRenderer.makeBuffer(), noCap = try FrameRenderer.makeBuffer()
    try r1.render(frame: 120, into: withCap)
    try r1.render(frame: 120, into: noCap, options: RenderOptions(caption: false))
    savePNG(withCap, framesDir.appendingPathComponent("render-c1-f120.png"))
    let box = PixelCompare.diffBox(withCap, noCap)
    let ink = layout.inkRectTopLeft
    var edgeErr: [Double] = []
    if let b = box {
        edgeErr = [b.minX - ink.minX.rounded(.down), b.minY - ink.minY.rounded(.down),
                   b.maxX - ink.maxX.rounded(.up), b.maxY - ink.maxY.rounded(.up)]
    }
    report.check("R2", "자막 경계 상자 vs 레이아웃 기대 사각형(각 변 ±1px)", pass: box != nil && edgeErr.allSatisfy { abs($0) <= 1 },
                 ["diffBox": box.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [], "edgeErrorPx(minX,minY,maxX,maxY)": edgeErr])
    report.check("R3", "글리프 누락 없음(.notdef 0개), 실행 폰트 기록", pass: layout.missingGlyphs == 0,
                 ["runFonts": layout.runFonts, "fallbackRuns": layout.runFonts.filter { $0 != layout.fontPostScriptName }])
    var boundary: [String: Bool] = [:]
    for n in [59, 60, 239, 240] {
        let a = try FrameRenderer.makeBuffer(), b = try FrameRenderer.makeBuffer()
        try r1.render(frame: n, into: a)
        try r1.render(frame: n, into: b, options: RenderOptions(caption: false))
        boundary["\(n)"] = PixelCompare.diffBox(a, b) != nil
    }
    let shownAll = (0..<Spec.frameCount).filter { r1.captionVisible(frame: $0) }
    report.check("R4", "자막 표시 경계 [2.0s, 8.0s): 59✗ 60✓ 239✓ 240✗, 전체 60…239",
                 pass: boundary == ["59": false, "60": true, "239": true, "240": false] &&
                     shownAll.first == Expect.captionFirstFrame && shownAll.last == Expect.captionLastFrame && shownAll.count == 180,
                 ["pixelDiffShown": boundary])

    // R5~R10 케이스별
    let pb = try FrameRenderer.makeBuffer()
    var mappingBands: [String: [[Float]]] = [:]
    for c in Expect.cases {
        let rU = try FrameRenderer(state: state(c, fx, withU: true), spectrum: sCache)
        let rN = try FrameRenderer(state: state(c, fx, withU: false), spectrum: sCache)
        let bandsU = (0..<Spec.frameCount).map { rU.bands(forFrame: $0) }
        let bandsN = (0..<Spec.frameCount).map { rN.bands(forFrame: $0) }

        // R5 톤 → 기대 밴드 최대
        var toneFail: [String] = []
        var toneN = 0
        for t in c.tones {
            for n in frames(in: (t.start, t.end), startPad: 0.2, endPad: 0.1) {
                toneN += 1
                let m = argmax(bandsU[n]); if m != t.band { toneFail.append("f\(n): band \(m) != \(t.band)") }
            }
        }
        report.check("R5-\(c.id)", "톤 구간에서 기대 밴드가 최대(독립 표)", pass: toneFail.isEmpty && toneN > 0,
                     ["framesChecked": toneN, "failures": Array(toneFail.prefix(5))])

        // R6 막대 그리기(렌더 버퍼 측정 vs 밴드 값으로 계산한 높이)
        var maxBarErr = 0
        for n in stride(from: 0, to: Spec.frameCount, by: 5) {
            let info = try rU.render(frame: n, into: pb)
            let m = FrameMetrics.measure(pb, captionRect: ink.insetBy(dx: -2, dy: -2))
            if m.code != n { maxBarErr = 999 }
            for k in 0..<Spec.bandCount { maxBarErr = max(maxBarErr, abs(m.barHeights[k] - info.barHeights[k])) }
        }
        report.check("R6-\(c.id)", "그려진 막대 높이 = round(값×480) (±1px), 프레임 코드 일치", pass: maxBarErr <= 1,
                     ["maxErrorPx": maxBarErr, "framesSampled": 60])

        // R7 격리: U 유무에 따른 밴드 값
        let diffFrames = (0..<Spec.frameCount).filter { bandsU[$0] != bandsN[$0] }
        report.check("R7-\(c.id)", "격리: U 추가 전후 밴드 값 수치 동일(300프레임)", pass: diffFrames.isEmpty,
                     ["differingFrames": diffFrames.count])

        // R9 무음/부재 구간: 창 길이(85.3ms) 이후 모든 밴드 0
        var quietFail = 0, quietN = 0
        for q in c.quiet {
            for n in frames(in: q, startPad: q.0 == 0 ? 0 : 0.1, endPad: 0) {
                quietN += 1; if bandsU[n].contains(where: { $0 != 0 }) { quietFail += 1 }
            }
        }
        report.check("R9-\(c.id)", "무음·부재 구간에서 모든 밴드 = 0", pass: quietFail == 0 && quietN > 0,
                     ["framesChecked": quietN, "nonZeroFrames": quietFail])

        // R10 클릭 반응 시점(렌더 단계): n_exp = floor(t·30) + 1 (후행 창)
        var timing: [[String: Any]] = []
        var timingOK = true
        for t in c.clicks {
            let base = Int((t * 30).rounded(.down))
            let nExp = base + 1
            let nObs = (max(0, base - 3)...min(Spec.frameCount - 1, base + 6)).first { n in Expect.highBands.contains { bandsU[n][$0] > 0.1 } }
            let d = nObs.map { $0 - nExp }
            if d == nil || abs(d!) > 1 { timingOK = false }
            timing.append(["tExp": t, "nExp": nExp, "nObs": nObs ?? -1])
        }
        // U 클릭은 S 무음 구간에서 고역 막대를 움직이지 않아야 한다
        var uLeak = 0, uChecked = 0
        for u in Expect.uClicks {
            for n in (Int(u * 30) + 1)...(Int(u * 30) + 3) where c.quiet.contains(where: { Double(n) / 30 >= $0.0 + 0.1 && Double(n) / 30 < $0.1 }) {
                uChecked += 1; if Expect.highBands.contains(where: { bandsU[n][$0] != 0 }) { uLeak += 1 }
            }
        }
        report.check("R10-\(c.id)", "클릭 반응 |n_obs − n_exp| ≤ 1 (렌더 단계), U 클릭 무반응", pass: timingOK && uLeak == 0,
                     ["clicks": timing, "uClickFramesChecked": uChecked, "uLeakFrames": uLeak])

        let (f6, f7) = c.framesForSource6and7
        mappingBands[c.id] = [bandsU[f6], bandsU[f7]]
    }
    // R8 트림·오프셋 대응: 같은 원본 시각(6.0 s, 7.0 s)의 밴드 값이 모든 케이스에서 같다
    let ref = mappingBands[Expect.cases[0].id]!
    let same = mappingBands.values.allSatisfy { $0 == ref }
    let nonzero = ref.allSatisfy { $0.contains { $0 > 0.5 } }
    report.check("R8", "트림·오프셋 대응: 원본 6.0/7.0 s 프레임(180/210, 30/60, 240/270, 90/120) 밴드 동일", pass: same && nonzero,
                 ["band14AtSource6": ref[0][14]])

    // R7b 민감도 대조: 타임라인 믹스(S+U)를 분석하면 U가 스펙트럼에 섞인다(선택 소스 경로는 그렇지 않음)
    let comp = try await Exporter.buildAudioComposition(state(c1, fx, withU: true))
    let (mixCache, _) = try SpectrumAnalyzer.analyze(asset: comp, tracks: comp.tracks(withMediaType: .audio),
                                                     timeRange: CMTimeRange(start: .zero, duration: Spec.duration), sourceID: "timeline-mix-contrast")
    let sel = try FrameRenderer(state: state(c1, fx, withU: true), spectrum: sCache)
    // 비교 구간: c1의 S 무음 구간(8.1~10 s). 이 구간에서 U는 계속 소리를 낸다.
    let quietFrames = frames(in: c1.quiet[0], startPad: 0.1, endPad: 0)
    let mixU = quietFrames.map { n in mixCache.bands(atSourceTime: Spec.frameTime(n)).map { $0[$0.startIndex + Expect.uBand] } ?? 0 }
    let selAll = quietFrames.flatMap { sel.bands(forFrame: $0) }
    report.check("R7b", "대조: S 무음 구간에서 타임라인 믹스 분석은 U(밴드 25)를 보이고, 선택 소스 경로는 모든 밴드 0",
                 pass: !quietFrames.isEmpty && (mixU.min() ?? 0) > 0.5 && selAll.allSatisfy { $0 == 0 },
                 ["frames": quietFrames.count, "mixBand25Min": Double(mixU.min() ?? 0), "selectedMax": Double(selAll.max() ?? 0)])

    // 시각 확인용 PNG (클릭 반응 프레임)
    let rc = try FrameRenderer(state: state(c1, fx, withU: true), spectrum: sCache)
    try rc.render(frame: 106, into: pb); savePNG(pb, framesDir.appendingPathComponent("render-c1-f106-click.png"))
    try rc.render(frame: 30, into: pb); savePNG(pb, framesDir.appendingPathComponent("render-c1-f030-tone135.png"))
}

// MARK: - 내보내기(통합 단계) 검사 — §6.4.2, §6.4.3

func onset(_ d: DecodedExport, near t: Double) -> Double? {
    let first = d.audioFirstPTS.isNumeric ? d.audioFirstPTS.seconds : 0
    let a = max(1, Int(((t - 0.1) - first) * 48_000)), b = min(d.mono.count, Int(((t + 0.1) - first) * 48_000))
    guard a < b else { return nil }
    for i in a..<b where abs(d.mono[i] - d.mono[i - 1]) > 0.3 { return first + Double(i) / 48_000 }
    return nil
}

/// Hann 창 단일 주파수 진폭 추정(구현의 FFT와 별개)
func toneAmp(_ d: DecodedExport, _ span: (Double, Double), _ hz: Double) -> Double {
    let first = d.audioFirstPTS.isNumeric ? d.audioFirstPTS.seconds : 0
    let a = max(0, Int((span.0 - first) * 48_000)), b = min(d.mono.count, Int((span.1 - first) * 48_000))
    guard b - a > 100 else { return 0 }
    var re = 0.0, im = 0.0, ws = 0.0
    let n = b - a
    for i in 0..<n {
        let w = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(n)))
        let ph = 2 * Double.pi * hz * Double(a + i) / 48_000
        let x = Double(d.mono[a + i]) * w
        re += x * cos(ph); im -= x * sin(ph); ws += w
    }
    return 2 * sqrt(re * re + im * im) / ws
}

struct ExportOutcome { let report: ExportReport; let decoded: DecodedExport?; let clickTimes: [Double?] }

func exportAndVerify(_ r: Report, _ fx: Fixtures, _ sCache: SpectrumCache, _ c: CaseExpect, withU: Bool, codec: ExportAudioCodec,
                     dest: URL, tag: String, path: VideoPath = .directWriter) async throws -> ExportOutcome {
    try checkBudget()
    let st = state(c, fx, withU: withU)
    let renderer = try FrameRenderer(state: st, spectrum: sCache)
    let seen = Locked<(Int, Bool)?>(nil)
    let control = ExportControl(onVideoAppended: { n, total in
        if n == total / 2 {
            seen.set((OutputGuard.leftovers(in: dest.deletingLastPathComponent()).count, FileManager.default.fileExists(atPath: dest.path)))
        }
    })
    let rep = await Exporter.run(ExportJob(state: st, destination: dest, codec: codec, videoPath: path,
                                           videoCarrier: path == .sharedCompositor ? fx.carrier : nil), renderer: renderer, control: control)
    let id = "X-\(tag)"
    r.check("\(id)-export", "내보내기 완료·승격", pass: rep.outcome == .completed && rep.promoted && rep.tempDirRemoved,
            ["wallS": rep.wallSeconds, "peakFootprintMiB": Double(rep.peakFootprintBytes) / 1_048_576,
             "startFootprintMiB": Double(rep.startFootprintBytes) / 1_048_576, "distinctPoolBuffers": rep.distinctPoolBuffers, "bytes": rep.outputBytes,
             "videoReadyCallbacks": rep.videoReadyCallbacks, "audioReadyCallbacks": rep.audioReadyCallbacks,
             "maxAudioBufferFrames": rep.maxAudioBufferFrames, "progressMonotonic": rep.progressMonotonic,
             "finalProgress": rep.finalProgress, "finishWritingMs": rep.finishWritingMs, "videoPath": rep.videoPath.rawValue,
             "duringExport": seen.get().map { ["tempDirsDuringExport": $0.0, "destExistsDuringExport": $0.1] } ?? [:],
             "error": rep.error ?? "-"])
    guard rep.outcome == .completed else { return ExportOutcome(report: rep, decoded: nil, clickTimes: []) }

    let layout = FrameRenderer.captionLayout()
    let d = try await Decoder.decode(dest, captionRect: layout.inkRectTopLeft.insetBy(dx: -2, dy: -2), reference: renderer)

    // X1 프레임 수, PTS, 프레임 코드
    let ptsOK = d.frames.enumerated().allSatisfy { $0.element.pts == Spec.frameTime($0.offset) }
    let codeBad = d.frames.enumerated().filter { $0.element.metrics.code != $0.offset }.count
    r.check("\(id)-frames", "프레임 수 300, PTS = n/30 정확, 프레임 코드 = n", pass: d.frames.count == 300 && ptsOK && codeBad == 0,
            ["frames": d.frames.count, "ptsExact": ptsOK, "codeMismatches": codeBad,
             "videoTrackRange": [d.videoTrackRange.start.seconds, d.videoTrackRange.duration.seconds], "videoFormat": d.videoFormat])

    // X3 자막 경계
    let shown = d.frames.indices.filter { d.frames[$0].metrics.captionPixels > 300 }
    let contiguous = shown.count == (shown.last ?? -1) - (shown.first ?? 0) + 1
    r.check("\(id)-caption", "디코딩 자막 첫/마지막 표시 프레임 = 60/239", pass: shown.first == 60 && shown.last == 239 && contiguous,
            ["first": shown.first ?? -1, "last": shown.last ?? -1, "count": shown.count])

    // X4 톤 / X5 무음 (디코딩 막대)
    var toneFail = 0, toneN = 0
    for t in c.tones { for n in frames(in: (t.start, t.end), startPad: 0.2, endPad: 0.1) {
        toneN += 1; if argmaxI(d.frames[n].metrics.barHeights) != t.band { toneFail += 1 }
    } }
    var quietMax = 0, quietN = 0
    for q in c.quiet { for n in frames(in: q, startPad: q.0 == 0 ? 0 : 0.1, endPad: 0) {
        quietN += 1; quietMax = max(quietMax, d.frames[n].metrics.barHeights.max()!)
    } }
    r.check("\(id)-spectrum", "디코딩 막대: 톤 구간 기대 밴드 최대, 무음 구간 막대 ≤ 3px", pass: toneFail == 0 && toneN > 0 && quietMax <= 3,
            ["toneFrames": toneN, "toneFail": toneFail, "quietFrames": quietN, "quietMaxBarPx": quietMax])

    // 렌더 기준과 디코딩 막대 높이 차이(허용치 기록), PSNR(진단)
    var barErr = 0
    for (n, f) in d.frames.enumerated() {
        let exp = renderer.bands(forFrame: n).map(Spec.barHeight(forValue:))
        for k in 0..<Spec.bandCount { barErr = max(barErr, abs(exp[k] - f.metrics.barHeights[k])) }
    }
    let ps = d.frames.compactMap { $0.psnr }
    r.check("\(id)-bars-psnr", "디코딩 막대 높이 − 렌더 막대 높이 최대 오차, PSNR(진단)", pass: nil,
            ["maxBarErrPx": barErr, "psnrMinDb": ps.min() ?? 0, "psnrMeanDb": ps.reduce(0, +) / Double(max(1, ps.count))])

    // X6/X7 클릭: 오디오 onset t_a, 스펙트럼 반응 n_obs
    var clickRows: [[String: Any]] = []
    var timingOK = true
    var tas: [Double?] = []
    for t in c.clicks {
        let ta = onset(d, near: t)
        tas.append(ta)
        let base = Int(((ta ?? t) * 30).rounded(.down))
        let nExp = base + 1
        let nObs = (max(0, base - 3)...min(299, base + 6)).first { n in Expect.highBands.contains { d.frames[n].metrics.barHeights[$0] >= 48 } }
        let delta = nObs.map { $0 - nExp }
        if ta == nil || delta == nil || abs(delta!) > 1 { timingOK = false }
        clickRows.append(["tExp": t, "tA": ta ?? -1, "tA_minus_tExp_ms": ta.map { ($0 - t) * 1000 } ?? -1,
                          "nExp": nExp, "nObs": nObs ?? -1, "delta": delta ?? 99])
    }
    r.check("\(id)-sync", "스펙트럼 반응 |n_obs − n_exp| ≤ 1 (n_exp = floor(t_a·30)+1)", pass: timingOK, ["clicks": clickRows])

    // X8 오디오 배치: 톤 진폭(독립 추정)
    var audioFail: [String] = []
    for t in c.tones {
        let span = (t.start + 0.1, t.end - 0.1)
        for hz in Expect.sHz {
            let a = toneAmp(d, span, hz)
            if hz == t.hz ? a < 0.15 : a > 0.01 { audioFail.append("\(t.start)-\(t.end)s \(Int(hz))Hz amp \(String(format: "%.4f", a))") }
        }
    }
    for q in c.quiet {
        let span = (q.0 + 0.1, q.1 - 0.1)
        for hz in Expect.sHz where toneAmp(d, span, hz) > 0.01 { audioFail.append("quiet \(q.0)-\(q.1)s \(Int(hz))Hz") }
    }
    let uAmp = toneAmp(d, (0.5, 9.5), Expect.uHz)
    if withU ? uAmp < 0.1 : uAmp > 0.01 { audioFail.append("U 4700Hz amp \(uAmp)") }
    r.check("\(id)-audio", "내보낸 오디오: 기대 톤 존재·비기대 톤 부재, U 포함 여부", pass: audioFail.isEmpty,
            ["failures": audioFail, "u4700Amp": uAmp, "audioFrames": d.audioFrames, "audioFirstPTS": d.audioFirstPTS.seconds,
             "primingTrimFrames": d.audioPrimingTrimFrames ?? -1, "audioFormat": d.audioFormat,
             "audioTrackRange": [d.audioTrackRange.start.seconds, d.audioTrackRange.duration.seconds]])
    return ExportOutcome(report: rep, decoded: d, clickTimes: tas)
}

// MARK: - 합성기 경로 (E1-b) — 오프라인 reader로 합성기 출력 확인

/// 직접 렌더 참조 해시(프레임 0…299)
func referenceHashes(_ renderer: FrameRenderer) throws -> [String] {
    let b = try FrameRenderer.makeBuffer()
    return try (0..<Spec.frameCount).map { n in try renderer.render(frame: n, into: b); return PixelCompare.sha256(b) }
}

func compositorOfflineChecks(_ r: Report, _ fx: Fixtures, _ sCache: SpectrumCache) async throws {
    for c in Expect.cases {
        let st = state(c, fx, withU: true)
        let renderer = try FrameRenderer(state: st, spectrum: sCache)
        let ref = try referenceHashes(renderer)
        let log = CompositorLog(hashOutputs: true)
        let bundle = try await CompositionBuilder.build(st, renderer: renderer, log: log, videoCarrier: fx.carrier)
        let reader = try AVAssetReader(asset: bundle.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: Spec.duration)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: bundle.composition.tracks(withMediaType: .video),
                                                      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = bundle.videoComposition
        out.alwaysCopiesSampleData = false
        reader.add(out)
        let t0 = Clock.now()
        guard reader.startReading() else { throw E1Error.reader(reader.error?.localizedDescription ?? "start") }
        var n = 0, ptsBad = 0, readerHashBad = 0
        var formats = Set<String>()
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            if CMSampleBufferGetPresentationTimeStamp(sb) != Spec.frameTime(n) { ptsBad += 1 }
            formats.insert("\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) \(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA ? "BGRA" : "other")")
            if n < ref.count, PixelCompare.sha256(pb) != ref[n] { readerHashBad += 1 }
            n += 1
        }
        let ms = Double(Clock.now() - t0) / 1e6
        let snap = log.snapshot()
        // 내보내기 범위 [0, 10 s) 안의 요청이므로 끝 프레임 유지(P-007)가 적용되면 안 된다(renderedFrame = frame)
        let compHashBad = snap.entries.filter { $0.frame >= ref.count || $0.renderedFrame != $0.frame || $0.hash != ref[$0.frame] }.count
        let inexact = snap.entries.filter { !$0.exactFrameTime }.count
        let framesSeen = Set(snap.entries.map { $0.frame })
        r.check("C1-\(c.id)", "합성기 출력(오프라인 AVAssetReaderVideoCompositionOutput): 300프레임, PTS n/30, 합성기 출력·reader 출력 모두 직접 렌더와 비트 동일",
                pass: reader.status == .completed && n == 300 && ptsBad == 0 && readerHashBad == 0 && compHashBad == 0
                    && inexact == 0 && framesSeen == Set(0..<300) && snap.errors.isEmpty,
                ["readerFrames": n, "ptsMismatch": ptsBad, "readerHashMismatch": readerHashBad, "compositorRequests": snap.entries.count,
                 "compositorHashMismatch": compHashBad, "inexactTimes": inexact, "maxInFlight": snap.maxInFlight,
                 "errors": snap.errors, "renderContextNotes": snap.renderContexts, "outputFormats": Array(formats), "wallMs": ms,
                 "renderMsMax": snap.entries.map { $0.renderMs }.max() ?? 0])
    }
}

/// 경로 B(공유 합성기) 검사: 오프라인 합성기 출력(C1), 경로 B 내보내기 5개, 경로 A와의 디코딩 비교(AB1)
func pathBChecks(_ r: Report, _ fx: Fixtures, _ sCache: SpectrumCache, outDir: URL, pathADecoded: [String: DecodedExport]) async throws {
    // 경로 B: 같은 합성기(AVVideoComposition + E1Compositor)를 AVAssetReaderVideoCompositionOutput으로 돌려 내보내기
    try await compositorOfflineChecks(r, fx, sCache)
    var abRows: [[String: Any]] = []
    var abAllEqual = true
    let bJobs: [(CaseExpect, ExportAudioCodec)] = Expect.cases.map { ($0, .aac) } + [(Expect.cases[0], .lpcm)]
    for (c, codec) in bJobs {
        let ext = codec == .aac ? "mp4" : "mov"
        let b = try await exportAndVerify(r, fx, sCache, c, withU: true, codec: codec,
                                          dest: outDir.appendingPathComponent("\(c.id)-withU-\(codec.rawValue)-pathB.\(ext)"),
                                          tag: "\(c.id)-B-\(codec.rawValue)", path: .sharedCompositor)
        if let a = pathADecoded["\(c.id)-\(codec.rawValue)"], let bd = b.decoded {
            let nA = a.frames.count, nB = bd.frames.count
            let eq = zip(a.frames, bd.frames).filter { $0.0.hash != nil && $0.0.hash == $0.1.hash }.count
            let audioEq = a.mono == bd.mono
            if !(nA == nB && eq == nA && audioEq) { abAllEqual = false }
            abRows.append(["job": "\(c.id)-\(codec.rawValue)", "framesA": nA, "framesB": nB, "decodedFrameHashEqual": eq,
                           "decodedAudioEqual": audioEq, "bytesA": a.fileBytes, "bytesB": bd.fileBytes])
        } else { abAllEqual = false }
    }
    r.check("AB1", "경로 A(직접 writer) vs 경로 B(공유 합성기) 디코딩 결과: 프레임별 디코딩 BGRA 해시와 오디오 샘플 동일", pass: abAllEqual,
            ["rows": abRows])

}

// MARK: - 취소·실패·출력 보호 — §6.4.4

func protectionChecks(_ r: Report, _ fx: Fixtures, _ sCache: SpectrumCache, runDir: URL, cancelReps: Int) async throws {
    let c1 = Expect.cases[0]
    let out = runDir.appendingPathComponent("protect")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let sentinel = out.appendingPathComponent("existing-destination.mp4")
    try Data("E1 existing destination sentinel — must never change\n".utf8).write(to: sentinel, options: .withoutOverwriting)
    let sentinelHash = try Hashing.sha256(file: sentinel)
    let renderer = try FrameRenderer(state: state(c1, fx, withU: true), spectrum: sCache)

    // P1 취소 (진행률 50%에서 다른 스레드가 cancel)
    var cancelRows: [[String: Any]] = []
    var cancelOK = true
    for i in 1...cancelReps {
        try checkBudget()
        let dest = out.appendingPathComponent("cancel-\(i).mp4")
        // 훅은 비디오 큐에서 불린다. 취소는 다른 스레드(global 큐)에서 요청한다.
        let target = Locked<ExportControl?>(nil)
        let issued = Locked(false)
        let control = ExportControl(onVideoAppended: { n, total in
            if n == total / 2 && !issued.update({ v in defer { v = true }; return v }) {
                DispatchQueue.global().async { target.get()?.cancel() }
            }
        })
        target.set(control)
        let rep = await Exporter.run(ExportJob(state: renderer.state, destination: dest, codec: .aac), renderer: renderer, control: control)
        let framesAfter = rep.videoFramesAppended
        try await Task.sleep(nanoseconds: 200_000_000)
        let left = OutputGuard.leftovers(in: out)
        let ok = rep.outcome == .cancelled && !FileManager.default.fileExists(atPath: dest.path) && left.isEmpty && rep.tempDirRemoved
            && rep.framesAtStop == framesAfter
        cancelOK = cancelOK && ok
        cancelRows.append(["rep": i, "outcome": rep.outcome.rawValue, "framesAtStop": rep.framesAtStop ?? -1,
                           "tAckMs": rep.tAckMs ?? -1, "tWorkersStoppedMs": rep.tWorkersStoppedMs ?? -1,
                           "tStopMs": rep.tStopMs ?? -1, "tCleanupMs": rep.tCleanupMs ?? -1,
                           "destExists": FileManager.default.fileExists(atPath: dest.path), "leftoverTemp": left.count])
    }
    r.check("P1", "취소(50%): 최종 파일 없음, 임시 정리, 중지 후 추가 쓰기 없음", pass: cancelOK, ["runs": cancelRows])

    // P2 주입 실패
    do {
        let dest = out.appendingPathComponent("inject-fail.mp4")
        let control = ExportControl(injectFailureAtFrame: 100)
        let rep = await Exporter.run(ExportJob(state: renderer.state, destination: dest, codec: .aac), renderer: renderer, control: control)
        r.check("P2", "렌더 중 실패 주입(프레임 100): 실패 보고, 최종 파일 없음, 임시 정리",
                pass: rep.outcome == .failed && rep.errorKind == "injectedFailure" && !FileManager.default.fileExists(atPath: dest.path)
                    && rep.tempDirRemoved && OutputGuard.leftovers(in: out).isEmpty,
                ["error": rep.error ?? "-", "framesAppended": rep.videoFramesAppended])
    }

    // P3 쓰기 불가 디렉터리
    do {
        let ro = out.appendingPathComponent("readonly-dir")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        chmod(ro.path, 0o555)
        defer { chmod(ro.path, 0o755) }
        let dest = ro.appendingPathComponent("out.mp4")
        let rep = await Exporter.run(ExportJob(state: renderer.state, destination: dest, codec: .aac), renderer: renderer, control: ExportControl())
        r.check("P3", "쓰기 불가 디렉터리: 시작 전 거부, 임시 미생성", pass: rep.outcome == .failed && rep.errorKind == "destinationParentNotWritable"
                    && !rep.tempDirCreated && !FileManager.default.fileExists(atPath: dest.path),
                ["error": rep.error ?? "-"])
    }

    // P4 원본 없음
    do {
        let missing = SourceRef(id: fx.s.id, path: fixturesDir.appendingPathComponent("does-not-exist.wav").path)
        let st = state(c1, fx, withU: true, selected: missing)
        let rr = try FrameRenderer(state: st, spectrum: sCache)
        let dest = out.appendingPathComponent("missing-source.mp4")
        let rep = await Exporter.run(ExportJob(state: st, destination: dest, codec: .aac), renderer: rr, control: ExportControl())
        r.check("P4", "원본 없음: 실패 보고, 임시 미생성", pass: rep.outcome == .failed && rep.errorKind == "invalidSource" && !rep.tempDirCreated,
                ["error": rep.error ?? "-"])
    }

    // P5 내보내기 중 원본 이름 변경 (전용 probe 사본 사용, 끝나면 원래 이름으로 복구)
    do {
        let st = state(c1, fx, withU: true, selected: fx.probe)
        let rr = try FrameRenderer(state: st, spectrum: sCache)
        let dest = out.appendingPathComponent("rename-probe.mp4")
        let renamed = URL(fileURLWithPath: fx.probe.path + ".renamed-during-export")
        let renameErr = Locked("none")
        let probeURL = fx.probe.url
        let control = ExportControl(onVideoAppended: { n, _ in
            if n == 60 { do { try FileManager.default.moveItem(at: probeURL, to: renamed) } catch { renameErr.set("\(error)") } }
        })
        let rep = await Exporter.run(ExportJob(state: st, destination: dest, codec: .aac), renderer: rr, control: control)
        if FileManager.default.fileExists(atPath: renamed.path) { try FileManager.default.moveItem(at: renamed, to: fx.probe.url) }
        let probeHash = try Hashing.sha256(file: fx.probe.url)
        r.check("P5", "내보내기 중 원본 이름 변경(관찰): 결과 기록, 원본 복구·해시 불변", pass: probeHash == fx.probe.id
                    && OutputGuard.leftovers(in: out).isEmpty,
                ["outcome": rep.outcome.rawValue, "error": rep.error ?? "-", "renameError": renameErr.get(),
                 "destExists": FileManager.default.fileExists(atPath: dest.path)])
    }

    // P6 대상 = 기존 파일 / P7 대상 = 원본
    do {
        let rep = await Exporter.run(ExportJob(state: renderer.state, destination: sentinel, codec: .aac), renderer: renderer, control: ExportControl())
        let sentinelNow = try Hashing.sha256(file: sentinel)
        r.check("P6", "대상 충돌(기존 파일): 시작 전 거부, 기존 파일 해시 불변",
                pass: rep.outcome == .failed && rep.errorKind == "destinationExists" && !rep.tempDirCreated
                    && sentinelNow == sentinelHash, ["error": rep.error ?? "-"])
        let rep2 = await Exporter.run(ExportJob(state: renderer.state, destination: fx.s.url, codec: .aac), renderer: renderer, control: ExportControl())
        let sNow = try Hashing.sha256(file: fx.s.url)
        r.check("P7", "대상 = 원본 경로: 시작 전 거부, 원본 해시 불변",
                pass: rep2.outcome == .failed && rep2.errorKind == "destinationIsSource" && !rep2.tempDirCreated
                    && sNow == fx.s.id, ["error": rep2.error ?? "-"])
    }

    // P8 내보내기 중 대상 경로에 파일이 생김 → 승격 시 덮어쓰지 않고 실패
    do {
        let dest = out.appendingPathComponent("conflict-during-export.mp4")
        let control = ExportControl(onVideoAppended: { n, _ in
            if n == 150 { try? Data("E1 conflicting file created during export\n".utf8).write(to: dest, options: .withoutOverwriting) }
        })
        let rep = await Exporter.run(ExportJob(state: renderer.state, destination: dest, codec: .aac), renderer: renderer, control: control)
        let content = (try? String(contentsOf: dest, encoding: .utf8)) ?? ""
        r.check("P8", "내보내기 중 대상 충돌: 승격 거부(RENAME_EXCL), 충돌 파일 보존, 임시 정리",
                pass: rep.outcome == .failed && rep.errorKind == "promotionConflict" && content.hasPrefix("E1 conflicting")
                    && rep.tempDirRemoved && OutputGuard.leftovers(in: out).isEmpty, ["error": rep.error ?? "-"])
    }
    let sentinelEnd = try Hashing.sha256(file: sentinel)
    r.check("P9", "기존 대상 sentinel 해시 불변(전체 보호 검사 후)", pass: sentinelEnd == sentinelHash,
            ["sha256": String(sentinelHash.prefix(16))])
}

// MARK: - 실행

/// 동기 함수로 분리(비동기 문맥에서 NSEnumerator 반복을 피한다)
func findLeftovers(_ dir: URL) -> [String] {
    var out: [String] = []
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return out }
    while let u = e.nextObject() as? URL { if u.lastPathComponent.hasPrefix(OwnedTempDir.prefix) { out.append(rel(u)) } }
    return out
}

func runAll(timingReps: Int, cancelReps: Int) async throws {
    let r = Report()
    let started = Date()
    let runID = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
    let runDir = runsDir.appendingPathComponent(runID)
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
    r.sections["build"] = ["sourceTree": BuildIdentity.sourceTree(root: root), "executable": BuildIdentity.executable()]
    r.sections["run"] = ["id": runID, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                         "cpuCount": ProcessInfo.processInfo.processorCount, "startFootprintMiB": Double(Memory.physFootprint()) / 1_048_576,
                         "spectrumParams": encodable(SpectrumParams())]
    try checkBudget()
    r.sections["usageBefore"] = artifactUsage()

    let fx = try await ensureFixtures(r)
    let sourcesBefore = [fx.s.id, fx.u.id, fx.probe.id]

    // 분석: 캐시 경로 + 캐시 없이 직접 분석 → 동일성
    let (sCache, cacheStats) = try await SpectrumAnalyzer.analyzeSelectedSource(fx.s, cacheDir: cacheDir)
    let sAsset = AVURLAsset(url: fx.s.url)
    let (fresh, freshStats) = try SpectrumAnalyzer.analyze(asset: sAsset, tracks: try await sAsset.loadTracks(withMediaType: .audio),
                                                           timeRange: nil, sourceID: fx.s.id)
    r.check("A1", "선택 소스 청크 분석: 캐시 = 직접 분석, hop 수 = 20s×120+1", pass: fresh.values == sCache.values && fresh.hopCount == 2401,
            ["fromCache": cacheStats.fromCache, "hops": fresh.hopCount, "sampleBuffers": freshStats.sampleBuffers,
             "maxBufferFrames": freshStats.maxBufferFrames, "totalFrames": freshStats.totalFrames,
             "ptsContiguous": freshStats.ptsContiguous, "wallS": freshStats.wallSeconds])

    try await renderChecks(r, fx, sCache)

    // 내보내기: 케이스 1~4 × (AAC .mp4, LPCM .mov), 모두 U 포함. 격리 비교용으로 c1 AAC U 없음.
    let outDir = runDir.appendingPathComponent("exports")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var timings: [Double] = []
    var footprints: [Double] = []
    var startFootprints: [Double] = []
    var poolCounts: [Int] = []
    var aacVsLpcm: [[String: Any]] = []
    var c1WithU: DecodedExport?
    var pathADecoded: [String: DecodedExport] = [:]
    for c in Expect.cases {
        let aac = try await exportAndVerify(r, fx, sCache, c, withU: true, codec: .aac,
                                            dest: outDir.appendingPathComponent("\(c.id)-withU-aac.mp4"), tag: "\(c.id)-aac")
        let lpcm = try await exportAndVerify(r, fx, sCache, c, withU: true, codec: .lpcm,
                                             dest: outDir.appendingPathComponent("\(c.id)-withU-lpcm.mov"), tag: "\(c.id)-lpcm")
        pathADecoded["\(c.id)-aac"] = aac.decoded
        if c.id == Expect.cases[0].id { pathADecoded["\(c.id)-lpcm"] = lpcm.decoded }
        if c.id == Expect.cases[0].id { c1WithU = aac.decoded; timings.append(aac.report.wallSeconds); footprints.append(Double(aac.report.peakFootprintBytes) / 1_048_576)
            startFootprints.append(Double(aac.report.startFootprintBytes) / 1_048_576); poolCounts.append(aac.report.distinctPoolBuffers) }
        for (i, t) in c.clicks.enumerated() {
            let a: Double? = aac.clickTimes.count > i ? aac.clickTimes[i] : nil
            let l: Double? = lpcm.clickTimes.count > i ? lpcm.clickTimes[i] : nil
            var row: [String: Any] = ["case": c.id, "tExp": t]
            row["tA_aac"] = a ?? -1.0
            row["tA_lpcm"] = l ?? -1.0
            if let a, let l { row["aacMinusLpcmMs"] = (a - l) * 1000 } else { row["aacMinusLpcmMs"] = -999.0 }
            if let l { row["lpcmMinusExpMs"] = (l - t) * 1000 } else { row["lpcmMinusExpMs"] = -999.0 }
            aacVsLpcm.append(row)
        }
    }
    let lpcmExact = aacVsLpcm.allSatisfy { abs(($0["lpcmMinusExpMs"] as? Double) ?? 999) < 0.03 }
    r.check("T1", "LPCM 대조: 클릭 onset = 기대 시각(±1샘플), AAC − LPCM 차이 기록", pass: lpcmExact, ["rows": aacVsLpcm])

    // 격리(내보내기): c1 U 없음 vs U 있음 디코딩 막대
    let noU = try await exportAndVerify(r, fx, sCache, Expect.cases[0], withU: false, codec: .aac,
                                        dest: outDir.appendingPathComponent("c1-baseline-noU-aac.mp4"), tag: "c1-noU-aac")
    if let a = c1WithU, let b = noU.decoded {
        var maxDiff = 0
        for n in 0..<min(a.frames.count, b.frames.count) {
            for k in 0..<Spec.bandCount { maxDiff = max(maxDiff, abs(a.frames[n].metrics.barHeights[k] - b.frames[n].metrics.barHeights[k])) }
        }
        r.check("X-isolation", "격리(내보내기): U 유무에 따른 디코딩 막대 높이 차이", pass: maxDiff <= 2, ["maxDiffPx": maxDiff])
    }

    try await pathBChecks(r, fx, sCache, outDir: outDir, pathADecoded: pathADecoded)

    // 반복 시간 측정 (c1 AAC, 기록만)
    let rendererC1 = try FrameRenderer(state: state(Expect.cases[0], fx, withU: true), spectrum: sCache)
    for i in 2...max(2, timingReps) where timingReps >= 2 {
        try checkBudget()
        let rep = await Exporter.run(ExportJob(state: rendererC1.state, destination: outDir.appendingPathComponent("timing-\(i).mp4"), codec: .aac),
                                     renderer: rendererC1, control: ExportControl())
        timings.append(rep.wallSeconds); footprints.append(Double(rep.peakFootprintBytes) / 1_048_576)
        startFootprints.append(Double(rep.startFootprintBytes) / 1_048_576); poolCounts.append(rep.distinctPoolBuffers)
    }
    r.check("M1", "c1 AAC 10초 내보내기 벽시계 시간·최대 footprint (기록만, 기준 없음)", pass: nil,
            ["wallS": timings, "peakFootprintMiB": footprints, "startFootprintMiB": startFootprints, "distinctPoolBuffers": poolCounts])

    try await protectionChecks(r, fx, sCache, runDir: runDir, cancelReps: cancelReps)

    // 원본·누수 최종 확인
    let after = [try Hashing.sha256(file: fx.s.url), try Hashing.sha256(file: fx.u.url), try Hashing.sha256(file: fx.probe.url)]
    r.check("P10", "원본 fixture 해시 불변(S, U, probe)", pass: after == sourcesBefore)
    let leftovers = findLeftovers(runDir)
    r.check("P11", "실행 디렉터리 전체에 남은 실험 임시 디렉터리 없음", pass: leftovers.isEmpty, ["leftovers": leftovers])

    let usage = artifactUsage()
    r.sections["usageAfter"] = usage
    r.sections["runDirBytes"] = DiskUsage.allocatedBytes(runDir)
    r.sections["processPeakFootprintNowMiB"] = Double(Memory.physFootprint()) / 1_048_576
    r.sections["wallSecondsTotal"] = Date().timeIntervalSince(started)

    let pass = r.checks.filter { ($0["result"] as? String) == "PASS" }.count
    let fail = r.checks.filter { ($0["result"] as? String) == "FAIL" }
    let rec = r.checks.filter { ($0["result"] as? String) == "RECORD" }.count
    r.sections["summary"] = ["pass": pass, "fail": fail.count, "record": rec, "failedIDs": fail.map { $0["id"] as! String }]
    let json: [String: Any] = sanitize(["sections": r.sections, "checks": r.checks]) as! [String: Any]
    try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
    let resultURL = resultsDir.appendingPathComponent("e1-run-\(runID).json")
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: resultURL)
    print("\nPASS \(pass)  FAIL \(fail.count)  RECORD \(rec)   failed: \(fail.map { $0["id"] as! String })")
    print("artifact usage: \(usage.mapValues { String(format: "%.1f MiB", Double($0) / 1_048_576) })")
    print("results: \(rel(resultURL))  run dir: \(rel(runDir))")
}

/// 합성기 경로 변경에 영향받는 검사만 다시 실행한다(C1, 경로 B 내보내기, AB1).
/// 경로 A는 바뀌지 않았으므로 지정한 이전 실행의 경로 A 출력 파일을 디코딩해 비교한다.
func runCompositorOnly(pathARun: String) async throws {
    let r = Report()
    let started = Date()
    let runID = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
    let runDir = runsDir.appendingPathComponent(runID)
    let outDir = runDir.appendingPathComponent("exports")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    r.sections["build"] = ["sourceTree": BuildIdentity.sourceTree(root: root), "executable": BuildIdentity.executable()]
    r.sections["run"] = ["id": runID, "mode": "compositor-only", "pathARun": pathARun, "os": ProcessInfo.processInfo.operatingSystemVersionString]
    try checkBudget()
    let fx = try await ensureFixtures(r)
    let before = [fx.s.id, fx.u.id, fx.carrierSha]
    let (sCache, _) = try await SpectrumAnalyzer.analyzeSelectedSource(fx.s, cacheDir: cacheDir)
    let aDir = runsDir.appendingPathComponent(pathARun).appendingPathComponent("exports")
    let layout = FrameRenderer.captionLayout()
    var pathADecoded: [String: DecodedExport] = [:]
    for (key, file) in Expect.cases.map({ ("\($0.id)-aac", "\($0.id)-withU-aac.mp4") }) + [("c1-baseline-lpcm", "c1-baseline-withU-lpcm.mov")] {
        let url = aDir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw E1Error.invalidSource("missing path A output \(rel(url))") }
        pathADecoded[key] = try await Decoder.decode(url, captionRect: layout.inkRectTopLeft.insetBy(dx: -2, dy: -2), reference: nil)
    }
    try await pathBChecks(r, fx, sCache, outDir: outDir, pathADecoded: pathADecoded)
    let after = [try Hashing.sha256(file: fx.s.url), try Hashing.sha256(file: fx.u.url), try Hashing.sha256(file: fx.carrier)]
    r.check("P10b", "원본 fixture·운반 영상 해시 불변(S, U, carrier)", pass: after == before)
    let leftovers = findLeftovers(runDir)
    r.check("P11b", "실행 디렉터리에 남은 실험 임시 디렉터리 없음", pass: leftovers.isEmpty, ["leftovers": leftovers])
    r.sections["usageAfter"] = artifactUsage()
    r.sections["wallSecondsTotal"] = Date().timeIntervalSince(started)
    let pass = r.checks.filter { ($0["result"] as? String) == "PASS" }.count
    let fail = r.checks.filter { ($0["result"] as? String) == "FAIL" }
    let rec = r.checks.filter { ($0["result"] as? String) == "RECORD" }.count
    r.sections["summary"] = ["pass": pass, "fail": fail.count, "record": rec, "failedIDs": fail.map { $0["id"] as! String }]
    let url = resultsDir.appendingPathComponent("e1-compositor-\(runID).json")
    try JSONSerialization.data(withJSONObject: sanitize(["sections": r.sections, "checks": r.checks]), options: [.prettyPrinted, .sortedKeys]).write(to: url)
    print("\nPASS \(pass)  FAIL \(fail.count)  RECORD \(rec)   failed: \(fail.map { $0["id"] as! String })")
    print("results: \(rel(url))  run dir: \(rel(runDir))")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "all" {
case "fixtures":
    let r = Report()
    _ = try await ensureFixtures(r)
case "all":
    func intArg(_ name: String, _ def: Int) -> Int {
        if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) { return v }
        return def
    }
    do { try await runAll(timingReps: intArg("--timing-reps", 3), cancelReps: intArg("--cancel-reps", 3)) }
    catch { print("ABORTED: \(error)"); exit(1) }
case "compositor":
    guard let i = args.firstIndex(of: "--path-a-run"), i + 1 < args.count else { print("usage: e1 compositor --path-a-run <run id>"); exit(2) }
    do { try await runCompositorOnly(pathARun: args[i + 1]) } catch { print("ABORTED: \(error)"); exit(1) }
default:
    print("usage: e1 [all [--timing-reps N] [--cancel-reps N] | fixtures | compositor --path-a-run <run id>]")
    exit(2)
}
