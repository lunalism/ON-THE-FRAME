import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
import E1Core
import E2Core
import E2Judge
import Foundation

// MARK: - fixture 정의(실험용)

public enum E3Spec {
    public static let sourceFrames = 600   // 20 s
    static func clip(_ hz: Double, seed: UInt64) -> AudioSynth {
        AudioSynth(lengthSamples: 20 * 48_000, tones: [ToneSpan(0, 20 * 48_000, hz: hz, amplitude: 0.1)],
                   clickStartSamples: [24_800, 504_800], clickSeed: seed)   // 소스 프레임 15·315의 중간 시각
    }
    /// 소스 A·B·C: E2와 같은 ID·배경·화면 요소에 플래시(f mod 300 = 15)를 더한 FHD 20 s
    public static let sources: [SourceVideoSpec] = [
        SourceVideoSpec(key: "A", idCode: 0x2D, background: [110, 40, 40], frames: sourceFrames, clipAudio: clip(3500, seed: 0xA11CE),
                        fileStem: "e3-src-A-1920x1080-30p", flashPeriod: 300, flashPhase: 15),
        SourceVideoSpec(key: "B", idCode: 0x5A, background: [40, 100, 50], frames: sourceFrames, clipAudio: clip(5000, seed: 0xB0B),
                        fileStem: "e3-src-B-1920x1080-30p", flashPeriod: 300, flashPhase: 15),
        SourceVideoSpec(key: "C", idCode: 0xB4, background: [40, 50, 120], frames: sourceFrames, clipAudio: clip(7000, seed: 0xC0C0A),
                        fileStem: "e3-src-C-1920x1080-30p", flashPeriod: 300, flashPhase: 15),
    ]
    /// 선택 오디오 M(610 s): 분 m의 톤은 원본 [60m + 1.5, 60m + 49.5) s(타임라인 +0.5 s), 클릭은 원본 60m + 39.5 + 1/60 s와 598.3167 s
    public static let musicHz: [Double] = [135, 196, 286, 415, 604, 879, 1278, 1858, 2702, 729]
    public static let music = AudioSynth(
        lengthSamples: 610 * 48_000,
        tones: (0..<10).map { m in ToneSpan(2_880_000 * m + 72_000, 2_880_000 * m + 2_376_000, hz: musicHz[m], amplitude: 0.25) },
        clickStartSamples: (0..<10).map { 2_880_000 * $0 + 1_896_800 } + [28_719_200],
        clickSeed: 0xE3E3E3)
    public static let musicFile = "e3-M-music-610s.wav"
    public static let placement = MusicPlacement(sourceInMs: 0, durationMs: 599_500, timelineStartMs: 500)

    /// 자막 20개: 30 s마다, 정렬 순환. 마지막은 [590, 599.5) s
    public static var captions: [TimedCaption] {
        let al: [CaptionAlignment] = [.left, .center, .right]
        return (0..<19).map { k in TimedCaption(text: String(format: "자막 %02d", k + 1), startFrame: 900 * k + 150, endFrame: 900 * k + 600, alignment: al[k % 3]) }
            + [TimedCaption(text: "자막 20 — 끝", startFrame: 17_700, endFrame: 17_985, alignment: .center)]
    }

    /// 편집 모델로 만든 10분 타임라인(붙이기 → 트림, 클립 41개)
    public static func timeline() throws -> EditTimeline {
        var t = EditTimeline(sourceLengths: ["A": sourceFrames, "B": sourceFrames, "C": sourceFrames])
        let keys = ["A", "B", "C"]
        for k in 0..<39 {
            try t.append(source: keys[k % 3], name: String(format: "k%02d", k))
            try t.trim(k, sourceIn: 30 * (k % 5), length: 450)
        }
        try t.append(source: "A", name: "k39a"); try t.trim(39, sourceIn: 120, length: 390)
        try t.append(source: "B", name: "k39b"); try t.trim(40, sourceIn: 300, length: 60)
        return t
    }
}

// MARK: - 실행 환경

public struct E3Env: Sendable {
    public let root: URL, experimentsDir: URL, artifacts: URL, fixtures: URL, cacheDir: URL, resultsDir: URL
    public let sources: [String: URL]
    public let musicURL: URL
    public let hashes: [String: String]
    public let spectrum: SpectrumCache
    public let timeline: EditTimeline
    public let fixtureInfo: [String: String]

    public static func load(root: URL, log: (String) -> Void = { _ in }) async throws -> E3Env {
        guard root.lastPathComponent == "e3-fhd-10min" else { throw E1Error.invalidSource("run from experiments/e3-fhd-10min") }
        let artifacts = root.appendingPathComponent("artifacts"), fixtures = artifacts.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        var info: [String: String] = [:], urls: [String: URL] = [:], hashes: [String: String] = [:]
        for spec in E3Spec.sources {
            log("fixture \(spec.fileName)")
            let r = try await SourceFixtures.ensure(spec, in: fixtures)
            urls[spec.key] = r.url; hashes[spec.fileName] = r.sha256
            info[spec.fileName] = r.sha256 + (r.created ? String(format: " (created this run, %.1f s)", r.seconds) : "")
        }
        let mURL = fixtures.appendingPathComponent(E3Spec.musicFile)
        let want = try musicDefinitionHash()
        if FileManager.default.fileExists(atPath: mURL.path) {
            let disk = try Hashing.sha256(file: mURL)
            guard disk == want else { throw E1Error.invalidSource("\(E3Spec.musicFile) hash differs from its definition") }
            info[E3Spec.musicFile] = disk
        } else {
            log("fixture \(E3Spec.musicFile) (streaming write)")
            let temp = fixtures.appendingPathComponent(".e3-music-\(UUID().uuidString).wav")
            let h = try E3Spec.music.writeWAVStreaming(to: temp)
            guard h == want else { try? FileManager.default.removeItem(at: temp); throw E1Error.invalidSource("music streaming hash mismatch") }
            do { try OutputGuard.promote(temp, to: mURL) } catch { try? FileManager.default.removeItem(at: temp); throw error }
            info[E3Spec.musicFile] = h + " (created this run)"
        }
        hashes[E3Spec.musicFile] = want
        log("spectrum analysis")
        let (cache, _) = try await SpectrumAnalyzer.analyzeSelectedSource(SourceRef(id: want, path: mURL.path), cacheDir: artifacts.appendingPathComponent("cache"))
        return E3Env(root: root, experimentsDir: root.deletingLastPathComponent(), artifacts: artifacts, fixtures: fixtures,
                     cacheDir: artifacts.appendingPathComponent("cache"), resultsDir: root.appendingPathComponent("results"),
                     sources: urls, musicURL: mURL, hashes: hashes, spectrum: cache, timeline: try E3Spec.timeline(), fixtureInfo: info)
    }

    /// 정의에서 WAV 바이트를 다시 만들며 해시만 계산(파일을 쓰지 않음, 1 s 단위 스트리밍)
    static func musicDefinitionHash() throws -> String {
        let s = E3Spec.music
        var hasher = SHA256()
        let dataBytes = s.lengthSamples * 4
        var head = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { head.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { head.append(contentsOf: $0) } }
        head.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); head.append(contentsOf: Array("WAVE".utf8))
        head.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
        head.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        hasher.update(data: head)
        let b = s.clickBurst()
        var i = 0
        while i < s.lengthSamples {
            let n = min(48_000, s.lengthSamples - i)
            var chunk = Data(capacity: n * 4)
            for j in i..<(i + n) {
                let v = Int16((Double(s.sample(j, burst: b)) * 32767).rounded()).littleEndian
                withUnsafeBytes(of: v) { chunk.append(contentsOf: $0); chunk.append(contentsOf: $0) }
            }
            hasher.update(data: chunk)
            i += n
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public var protectedSources: [URL] { Array(sources.values) + [musicURL] }

    public func makeBundle(log: E2Log) async throws -> E2Bundle {
        let overlay = Overlay(spectrum: spectrum, music: E3Spec.placement, captions: E3Spec.captions)
        return try await E2CompositionBuilder.build(timeline: timeline, sources: sources, music: musicURL, placement: E3Spec.placement,
                                                    overlay: overlay, log: log)
    }

    public func buildIdentity() -> [String: Any] {
        ["e3SourceTree": BuildIdentity.sourceTree(root: root),
         "e2SourceTree": BuildIdentity.sourceTree(root: experimentsDir.appendingPathComponent("e2-4k")),
         "e1SourceTree": BuildIdentity.sourceTree(root: experimentsDir.appendingPathComponent("e1-fhd")),
         "executable": BuildIdentity.executable()]
    }
}

// MARK: - 자원 감시(메모리·디스크) — 실험 중지 조건 포함

/// 1 s마다 phys_footprint, RSS, 데이터 볼륨 여유, 열 상태를 기록하고, 5 s마다 E3 artifacts 크기를 잰다.
/// 중지 조건(실험 안전 장치일 뿐, 제품 기준 아님): footprint > 8 GiB, 여유 < 6 GiB, 실험 소유 합계 > 4 GiB, 단계 시간 한도 초과.
/// 안전성(@unchecked Sendable): 가변 상태는 모두 lock 안에서만 접근하고, 타이머는 직렬 queue에서 돈다.
public final class ResourceMonitor: @unchecked Sendable {
    public struct Sample: Sendable { public let t: Double; public let phase: String; public let footprint: UInt64; public let rss: UInt64; public let free: UInt64; public let thermal: Int }
    public static let footprintLimit: UInt64 = 8 << 30
    public static let freeSpaceFloor: UInt64 = 6 << 30
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "e3.monitor")
    private var timer: DispatchSourceTimer?
    private var samples: [Sample] = []
    private var phase = "start", phaseStart = 0.0, phaseLimit = Double.infinity
    private var phases: [(String, Double, Double)] = []   // 이름, 시작, 끝
    private var stop: String?
    private var ownedBase: UInt64 = 0, e3Base: UInt64 = 0, e3Now: UInt64 = 0, maxOwned: UInt64 = 0, minFree: UInt64 = .max
    private var onStop: (@Sendable (String) -> Void)?
    private var tick = 0
    let t0 = CACurrentMediaTime()
    let experimentsDir: URL, e3Artifacts: URL

    public init(experimentsDir: URL) {
        self.experimentsDir = experimentsDir
        e3Artifacts = experimentsDir.appendingPathComponent("e3-fhd-10min").appendingPathComponent("artifacts")
    }

    public func start() {
        rebase()
        queue.sync {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .seconds(1))
            t.setEventHandler { [weak self] in self?.sample() }
            t.resume(); timer = t
        }
    }
    public func stopSampling() { queue.sync { timer?.cancel(); timer = nil } }

    /// 단계 전환. limitSeconds는 단계 시간 한도(계획 추정의 2배).
    public func enter(_ name: String, limitSeconds: Double = .infinity) {
        let now = CACurrentMediaTime() - t0
        lock.lock()
        if let i = phases.indices.last, phases[i].2 < 0 { phases[i].2 = now }
        phases.append((name, now, -1)); phase = name; phaseStart = now; phaseLimit = limitSeconds
        lock.unlock()
    }
    /// 실험 소유 합계를 다시 잰다(단계 경계에서. .build 열거가 무거워 매초 하지 않음)
    public func rebase() {
        let owned = OwnedBudget.total(experimentsDir: experimentsDir), e3 = DiskUsage.allocatedBytes(e3Artifacts)
        lock.lock(); ownedBase = owned; e3Base = e3; e3Now = e3; maxOwned = max(maxOwned, owned); lock.unlock()
    }
    public func setOnStop(_ f: (@Sendable (String) -> Void)?) { lock.lock(); onStop = f; lock.unlock() }
    public var stopReason: String? { lock.lock(); defer { lock.unlock() }; return stop }
    public func clearPhaseLimitStop() { lock.lock(); if stop?.hasPrefix("phase time") == true { stop = nil }; lock.unlock() }

    func sample() {
        let now = CACurrentMediaTime() - t0
        let fp = Memory.physFootprint(), rss = Self.residentSize()
        var st = statfs()
        let free: UInt64 = statfs(experimentsDir.path, &st) == 0 ? UInt64(st.f_bavail) * UInt64(st.f_bsize) : 0
        tick += 1
        let e3: UInt64? = tick % 5 == 0 ? DiskUsage.allocatedBytes(e3Artifacts) : nil
        lock.lock()
        if let e3 { e3Now = e3 }
        let owned = ownedBase &+ (e3Now > e3Base ? e3Now - e3Base : 0)
        maxOwned = max(maxOwned, owned); minFree = min(minFree, free)
        samples.append(Sample(t: now, phase: phase, footprint: fp, rss: rss, free: free, thermal: ProcessInfo.processInfo.thermalState.rawValue))
        var reason: String?
        if stop == nil {
            if fp > Self.footprintLimit { reason = "footprint \(fp >> 20) MiB > \(Self.footprintLimit >> 20) MiB" }
            else if free < Self.freeSpaceFloor { reason = "free space \(free >> 20) MiB < \(Self.freeSpaceFloor >> 20) MiB" }
            else if owned > OwnedBudget.limitBytes { reason = "owned \(owned >> 20) MiB > \(OwnedBudget.limitBytes >> 20) MiB" }
            else if now - phaseStart > phaseLimit { reason = "phase time: \(phase) exceeded \(Int(phaseLimit)) s" }
            stop = reason
        }
        let cb = reason != nil ? onStop : nil
        lock.unlock()
        if let r = reason { cb?(r) }
    }

    static func residentSize() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    /// 단계별 요약: 시작·끝·최소·최대·중앙값(MiB), 60 s 이상 단계의 선형 기울기(MiB/분), 처음·마지막 2분 중앙값
    public func summary() -> [String: Any] {
        lock.lock(); let ss = samples; var ph = phases; let mo = maxOwned, mf = minFree, sr = stop; lock.unlock()
        if let i = ph.indices.last, ph[i].2 < 0 { ph[i].2 = ss.last?.t ?? 0 }
        func mib(_ b: UInt64) -> Double { (Double(b) / 1_048_576 * 10).rounded() / 10 }
        var out: [[String: Any]] = []
        for (name, a, b) in ph {
            let s = ss.filter { $0.phase == name && $0.t >= a && $0.t <= b + 0.5 }
            guard !s.isEmpty else { out.append(["phase": name, "seconds": b - a, "samples": 0]); continue }
            let fp = s.map { Double($0.footprint) / 1_048_576 }, rs = s.map { Double($0.rss) / 1_048_576 }
            func med(_ x: [Double]) -> Double { let y = x.sorted(); return y[y.count / 2] }
            var row: [String: Any] = ["phase": name, "seconds": (b - a).rounded(), "samples": s.count,
                                      "footprintMiB": ["start": fp.first!, "end": fp.last!, "min": fp.min()!, "max": fp.max()!, "median": med(fp)].mapValues { ($0 * 10).rounded() / 10 },
                                      "rssMiB": ["start": rs.first!, "end": rs.last!, "max": rs.max()!].mapValues { ($0 * 10).rounded() / 10 },
                                      "thermalMax": s.map { $0.thermal }.max()!, "freeMiBMin": mib(s.map { $0.free }.min()!)]
            if b - a >= 60, s.count >= 30 {
                let xs = s.map { $0.t / 60 }, mx = xs.reduce(0, +) / Double(xs.count), my = fp.reduce(0, +) / Double(fp.count)
                let num = zip(xs, fp).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }, den = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
                row["footprintSlopeMiBPerMin"] = den > 0 ? (num / den * 100).rounded() / 100 : 0
                let first = s.filter { $0.t < a + 120 }.map { Double($0.footprint) / 1_048_576 }
                let last = s.filter { $0.t > b - 120 }.map { Double($0.footprint) / 1_048_576 }
                if !first.isEmpty, !last.isEmpty { row["footprintFirst2MinMedian"] = (med(first) * 10).rounded() / 10; row["footprintLast2MinMedian"] = (med(last) * 10).rounded() / 10 }
            }
            out.append(row)
        }
        return ["phases": out, "maxOwnedMiB": mib(mo), "minFreeMiB": mib(mf), "stopReason": sr ?? "none",
                "limits": ["footprintMiB": Self.footprintLimit >> 20, "freeFloorMiB": Self.freeSpaceFloor >> 20, "ownedLimitMiB": OwnedBudget.limitBytes >> 20]]
    }

    /// 표본 전체를 CSV로(artifacts에만 둔다)
    public func writeCSV(to url: URL) {
        lock.lock(); let ss = samples; lock.unlock()
        var s = "t_s,phase,footprint_mib,rss_mib,free_mib,thermal\n"
        for x in ss { s += String(format: "%.1f,%@,%.1f,%.1f,%.0f,%d\n", x.t, x.phase, Double(x.footprint) / 1_048_576, Double(x.rss) / 1_048_576, Double(x.free) / 1_048_576, x.thermal) }
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - 내보낸 파일의 스트리밍 검증

public struct StreamedExportInfo: Sendable {
    public var frames = 0
    public var ptsMismatch = 0
    public var videoRange: CMTimeRange = .zero, audioRange: CMTimeRange = .zero
    public var format: [String: String] = [:]
    public var audioSamples = 0
    public var onsets: [Int] = []
    public var seconds = 0.0
}

public enum StreamVerifier {
    /// 비디오는 프레임마다 측정해 onFrame으로 넘기고 버린다. 오디오는 (L+R)/2를 흘리며 onset만 남긴다(전체 PCM을 보관하지 않음).
    /// 실행기(main actor)에서만 부른다. onFrame은 같은 actor에서 동기로 호출된다.
    @MainActor
    public static func run(_ url: URL, onFrame: (Int, E2Metrics?) -> Void) async throws -> StreamedExportInfo {
        let t0 = Clock.now()
        var info = StreamedExportInfo()
        let asset = AVURLAsset(url: url)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first, let at = try await asset.loadTracks(withMediaType: .audio).first else {
            throw E1Error.verificationFailed("missing tracks")
        }
        info.videoRange = try await vt.load(.timeRange); info.audioRange = try await at.load(.timeRange)
        if let fd = try await vt.load(.formatDescriptions).first {
            let d = CMVideoFormatDescriptionGetDimensions(fd); info.format["dimensions"] = "\(d.width)x\(d.height)"
            let st = CMFormatDescriptionGetMediaSubType(fd)
            info.format["codec"] = String(bytes: [UInt8((st >> 24) & 0xFF), UInt8((st >> 16) & 0xFF), UInt8((st >> 8) & 0xFF), UInt8(st & 0xFF)], encoding: .ascii) ?? "?"
        }
        let vr = try AVAssetReader(asset: asset)
        let vo = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vo.alwaysCopiesSampleData = false
        vr.add(vo)
        guard vr.startReading() else { throw E1Error.reader(vr.error?.localizedDescription ?? "video") }
        while let sb = vo.copyNextSampleBuffer() {
            autoreleasepool {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
                if CMSampleBufferGetPresentationTimeStamp(sb) != Spec4K.frameTime(info.frames) { info.ptsMismatch += 1 }
                onFrame(info.frames, E2Metrics.measure(pb))
                info.frames += 1
            }
        }
        if vr.status == .failed { throw E1Error.reader(vr.error?.localizedDescription ?? "video failed") }
        let ar = try AVAssetReader(asset: asset)
        let ao = AVAssetReaderTrackOutput(track: at, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        ao.alwaysCopiesSampleData = false
        ar.add(ao)
        guard ar.startReading() else { throw E1Error.reader(ar.error?.localizedDescription ?? "audio") }
        var prev: Float = 0, idx = 0, last = -1_000_000
        var scratch: [Float] = []
        while let sb = ao.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb), n = len / 4
            if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
            _ = scratch.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            var i = 0
            while i + 1 < n {
                let x = 0.5 * (scratch[i] + scratch[i + 1])
                if idx > 0, abs(x - prev) > 0.3, idx - last > 2400 { info.onsets.append(idx); last = idx }
                prev = x; idx += 1; i += 2
            }
        }
        if ar.status == .failed { throw E1Error.reader(ar.error?.localizedDescription ?? "audio failed") }
        info.audioSamples = idx
        info.seconds = Double(Clock.now() - t0) / 1e9
        return info
    }
}

public func loadAvg() -> [Double] { var l = [Double](repeating: -1, count: 3); _ = getloadavg(&l, 3); return l }

/// 작업 부하 기록(읽기만): 부하 평균, CPU 상위 5개 프로세스, 전원 상태, 열 상태
public func workloadSnapshot() -> [String: Any] {
    func run(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "-" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
    let top = run("/bin/ps", ["-Ao", "pcpu=,comm="]).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .sorted { (Double($0.split(separator: " ").first ?? "0") ?? 0) > (Double($1.split(separator: " ").first ?? "0") ?? 0) }
        .prefix(5).map { s -> String in
            // 경로는 마지막 구성 요소만 남긴다(개인 경로를 결과에 남기지 않음)
            let parts = s.split(separator: " ", maxSplits: 1); guard parts.count == 2 else { return s }
            return "\(parts[0]) \((String(parts[1]) as NSString).lastPathComponent)"
        }
    let power = run("/usr/bin/pmset", ["-g", "batt"]).split(separator: "\n").first.map(String.init) ?? "-"
    return ["loadAvg": loadAvg(), "topCPU": Array(top), "power": power, "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
}
