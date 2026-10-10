import AVFoundation
import CoreMedia
import E1Core
import E2Core
import Foundation
import OnTheFrameEngine

/// 앱 검증용 생성 fixture(외부 미디어 없음). 판독 가능한 원본 A·B는 E2/E3 생성기(SourceVideoSpec, FHD 배치)를 쓴다.
/// 각 화면에는 원본 ID와 원본 프레임 번호가 코드 칸으로 그려지고, 소리에는 알려진 원본 프레임에 클릭이 있다.
public enum DevFixtures {
    public static let sampleRate = 48_000
    public static let samplesPerFrame = 1_600

    /// 원본 클릭 위치(원본 프레임). 편집 경계에서 3프레임 넘게 떨어지도록 골랐다(selftest·테스트 편집 기준).
    public static let clickFrames: [String: [Int]] = ["A": [8, 30, 62, 75, 96], "B": [4, 26, 40, 70, 84],
                                                      "TA": [30, 50, 75, 100], "TB": [10, 45, 70]]
    public static let a = spec("A", id: 0x2D, bg: [110, 40, 40], frames: 120, seed: 11)
    public static let b = spec("B", id: 0x5A, bg: [40, 100, 50], frames: 90, seed: 23)
    /// 빈틈 검증용(D-020): 클릭과 함께 440 Hz 연속음(진폭 0.1)이 처음부터 끝까지 있어 빈틈의 무음을 판정할 수 있다.
    public static let toneA = spec("TA", id: 0x33, bg: [120, 90, 30], frames: 120, seed: 31, tone: true)
    public static let toneB = spec("TB", id: 0xCC, bg: [30, 90, 120], frames: 90, seed: 37, tone: true)
    public static let readable: [String: SourceVideoSpec] = ["otf-A.mp4": a, "otf-B.mp4": b, "otf-TA.mp4": toneA, "otf-TB.mp4": toneB]
    public static let toneAmplitude = 0.1

    static func spec(_ k: String, id: Int, bg: [UInt8], frames: Int, seed: UInt64, tone: Bool = false) -> SourceVideoSpec {
        let n = frames * samplesPerFrame
        return SourceVideoSpec(key: k, idCode: id, background: bg, frames: frames,
                               clipAudio: AudioSynth(lengthSamples: n, tones: tone ? [ToneSpan(0, n, hz: 440, amplitude: toneAmplitude)] : [],
                                                     clickStartSamples: clickFrames[k]!.map { $0 * samplesPerFrame }, clickSeed: seed),
                               fileStem: "otf-\(k)")
    }

    /// dir에 fixture를 만든다(있으면 그대로 둔다). 돌려주는 값: 파일 이름 목록.
    @discardableResult
    public static func ensureAll(in dir: URL) async throws -> [String] {
        Spec4K.configure(.fhd)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await SourceFixtures.ensure(a, in: dir)
        _ = try await SourceFixtures.ensure(b, in: dir)
        _ = try await SourceFixtures.ensure(toneA, in: dir)
        _ = try await SourceFixtures.ensure(toneB, in: dir)
        let thirty = (0..<30).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        try await ensure(dir, "otf-rot90.mp4") { try await writeVideo($0, type: .mp4, w: 640, h: 360, pts: thirty,
                                                                      transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)) }
        try await ensure(dir, "reject-25fps.mp4") { try await writeVideo($0, type: .mp4, w: 320, h: 240, pts: (0..<25).map { CMTime(value: CMTimeValue($0), timescale: 25) }) }
        // 평균 30 fps(공칭 30)이지만 간격이 1/60·1/20으로 섞인 가변 간격
        var vfr: [CMTime] = [], t = 0
        for k in 0..<60 { vfr.append(CMTime(value: CMTimeValue(t), timescale: 60)); t += (k % 10 == 4) ? 1 : (k % 10 == 5 ? 3 : 2) }
        try await ensure(dir, "reject-vfr.mp4") { try await writeVideo($0, type: .mp4, w: 320, h: 240, pts: vfr) }
        try await ensure(dir, "reject-2video.mov") { try await writeVideo($0, type: .mov, w: 320, h: 240, pts: thirty, tracks: 2) }
        try await ensure(dir, "reject-audio-only.m4a") { try await writeAudioOnly($0) }
        try await ensure(dir, "otf-hevc.mp4") { try await writeVideo($0, type: .mp4, w: 1280, h: 720, pts: thirty, codec: .hevc) }
        try await ensure(dir, "reject-uhd.mp4") { try await writeVideo($0, type: .mp4, w: 3840, h: 2160, pts: Array(thirty.prefix(5))) }
        return all
    }
    public static let all = ["otf-A.mp4", "otf-B.mp4", "otf-TA.mp4", "otf-TB.mp4", "otf-rot90.mp4", "otf-hevc.mp4",
                             "reject-25fps.mp4", "reject-vfr.mp4", "reject-2video.mov", "reject-audio-only.m4a", "reject-uhd.mp4"]
    /// 거부 fixture → 기대 거부 종류(ProbeError.kind)
    public static let rejects: [String: String] = ["reject-25fps.mp4": "frameRate", "reject-vfr.mp4": "variableTiming",
                                                   "reject-2video.mov": "multipleVideoTracks", "reject-audio-only.m4a": "noVideo",
                                                   "reject-uhd.mp4": "dimensions"]

    static func ensure(_ dir: URL, _ name: String, _ write: (URL) async throws -> Void) async throws {
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return }
        let temp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)-\(name)")
        do { try await write(temp) } catch { try? FileManager.default.removeItem(at: temp); throw error }
        try FileManager.default.moveItem(at: temp, to: url)
    }

    /// 단색(프레임마다 밝기 변화) H.264 영상. tracks=2면 같은 내용의 영상 트랙 두 개.
    static func writeVideo(_ url: URL, type: AVFileType, w: Int, h: Int, pts: [CMTime], transform: CGAffineTransform = .identity, tracks: Int = 1,
                           codec: AVVideoCodecType = .h264) async throws {
        let wr = try AVAssetWriter(outputURL: url, fileType: type)
        var ins: [(AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)] = []
        for _ in 0..<tracks {
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h])
            i.transform = transform
            i.expectsMediaDataInRealTime = false
            wr.add(i)
            ins.append((i, AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])))
        }
        guard wr.startWriting() else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "writer") }
        wr.startSession(atSourceTime: .zero)
        for (k, t) in pts.enumerated() {
            for (i, ad) in ins {
                while !i.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
                guard let pb else { throw E1Error.verificationFailed("pixel buffer") }
                CVPixelBufferLockBaseAddress(pb, [])
                memset(CVPixelBufferGetBaseAddress(pb), Int32(40 + (k * 5) % 180), CVPixelBufferGetDataSize(pb))
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard ad.append(pb, withPresentationTime: t) else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "append") }
            }
        }
        let end = (pts.last ?? .zero) + CMTime(value: 1, timescale: 30)
        ins.forEach { $0.0.markAsFinished() }
        wr.endSession(atSourceTime: end)
        await wr.finishWriting()
        guard wr.status == .completed else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "finish") }
    }

    /// 영상 없는 AAC 1초
    static func writeAudioOnly(_ url: URL) async throws {
        let wr = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        wr.add(i)
        guard wr.startWriting() else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "writer") }
        wr.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let n = 4_800
        for chunk in 0..<10 {
            while !i.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var samples = [Float](repeating: 0, count: n * 2)
            for k in 0..<n { let v = Float(sin(Double(chunk * n + k) * 2 * .pi * 440 / Double(sampleRate)) * 0.2); samples[2 * k] = v; samples[2 * k + 1] = v }
            var block: CMBlockBuffer?
            let bytes = samples.count * 4
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            guard let block else { throw E1Error.verificationFailed("block") }
            _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt!, sampleCount: n,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(chunk * n), timescale: CMTimeScale(sampleRate)),
                                                                 packetDescriptions: nil, sampleBufferOut: &sb)
            guard let sb, i.append(sb) else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "audio append") }
        }
        i.markAsFinished()
        await wr.finishWriting()
        guard wr.status == .completed else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "finish") }
    }
}

/// 내보낸 파일(또는 프리뷰 프레임) 판정. 타임라인 프레임마다 기대값을 만든다: 클립이면 (원본 ID, 원본 프레임), 빈틈이면 검정.
/// - 영상: 모든 출력 프레임을 디코딩해 화면의 원본 ID·원본 프레임 코드(또는 검정)를 비교한다. 구간 경계(클립↔클립, 클립↔빈틈)
///   앞뒤 프레임과 마지막 프레임을 따로 기록한다.
/// - 소리: 클릭 onset이 유지된 클립의 (바뀌지 않은) 타임라인 위치에 있는지 본다. 연속음 fixture면 빈틈의 무음과
///   클립 구간의 소리 있음을 RMS로 본다(경계 양쪽 1프레임은 AAC 경계 번짐 때문에 뺀다).
public enum ExportJudge {
    /// start가 nil이면 앞 클립 바로 뒤(빈틈 없음)로 본다.
    public struct ClipRef: Codable, Sendable {
        public let file: String; public let start: Int?; public let sourceIn: Int; public let length: Int
        public init(file: String, start: Int? = nil, sourceIn: Int, length: Int) {
            self.file = file; self.start = start; self.sourceIn = sourceIn; self.length = length
        }
    }
    public enum Expected: Equatable, Sendable {
        case source(id: Int, frame: Int), gap
        public var label: String { if case .source(let i, let f) = self { return String(format: "id%02X#%d", i, f) }; return "black" }
    }
    public struct BoundaryFrame: Codable, Sendable { public let frame: Int; public let expected: String; public let measured: String; public let pass: Bool }
    public struct Verdict: Codable, Sendable {
        public let pass: Bool
        public let frames: Int, expectedFrames: Int
        public let dimensions: String, codec: String, audioFormat: String
        public let mismatchedFrames: [Int]
        public let gapFrames: Int
        public let boundaries: [BoundaryFrame]
        public let expectedOnsets: [Int], measuredOnsets: [Int], maxOnsetErrorSamples: Int?
        public let gapRMSMax: Double?, clipRMSMin: Double?
        public let notes: [String]
    }

    /// 배경 측정 위치가 검정인가(빈틈)
    public static func isBlack(_ m: E2Metrics?) -> Bool { guard let m else { return false }; return (m.background.max() ?? 255) <= 20 }
    public static func matches(_ m: E2Metrics?, _ e: Expected) -> Bool {
        switch e {
        case .gap: return isBlack(m)
        case .source(let id, let f): return m?.sourceID == id && m?.sourceFrame == f && !isBlack(m)
        }
    }
    public static func label(_ m: E2Metrics?) -> String {
        guard let m else { return "unreadable" }
        return isBlack(m) ? "black" : String(format: "id%02X#%d", m.sourceID, m.sourceFrame)
    }

    /// 타임라인 프레임별 기대값과 배치된 클립(시작 프레임)
    public static func expectations(_ clips: [ClipRef], durationFrames: Int? = nil) throws -> (frames: [Expected], placed: [(ClipRef, Int, SourceVideoSpec)]) {
        var placed: [(ClipRef, Int, SourceVideoSpec)] = []
        var cursor = 0
        for c in clips {
            guard let spec = DevFixtures.readable[c.file] else { throw E1Error.verificationFailed("unknown fixture \(c.file)") }
            let st = c.start ?? cursor
            guard st >= cursor else { throw E1Error.verificationFailed("overlap at \(st)") }
            placed.append((c, st, spec)); cursor = st + c.length
        }
        let total = max(durationFrames ?? 0, cursor)
        var ex = [Expected](repeating: .gap, count: total)
        for (c, st, spec) in placed { for k in 0..<c.length { ex[st + k] = .source(id: spec.idCode, frame: c.sourceIn + k) } }
        return (ex, placed)
    }
    /// 경계 앞뒤 프레임과 마지막 프레임
    public static func boundaryFrames(_ ex: [Expected]) -> [Int] {
        var out: Set<Int> = []
        if ex.count > 1 {
            for n in 1..<ex.count {
                let change: Bool
                switch (ex[n - 1], ex[n]) {
                case (.gap, .gap): change = false
                case (.source(let a, let fa), .source(let b, let fb)): change = a != b || fb != fa + 1
                default: change = true
                }
                if change { out.insert(n - 1); out.insert(n) }
            }
        }
        if let last = ex.indices.last { out.insert(last) }
        return out.sorted()
    }

    public static func judge(_ url: URL, clips: [ClipRef], durationFrames: Int? = nil, toneCheck: Bool = false) async throws -> Verdict {
        Spec4K.configure(.fhd)
        let d = try await E2Decoder.decode(url)
        let (expected, placed) = try expectations(clips, durationFrames: durationFrames)
        var onsets: [Int] = [], notes: [String] = []
        for (c, st, spec) in placed {
            for f in DevFixtures.clickFrames[spec.key]! where f >= c.sourceIn && f < c.sourceIn + c.length {
                onsets.append((st + f - c.sourceIn) * DevFixtures.samplesPerFrame)
            }
        }
        onsets.sort()
        var mismatched: [Int] = []
        for (n, e) in expected.enumerated() where !matches(n < d.frames.count ? d.frames[n].metrics : nil, e) { mismatched.append(n) }
        for (n, f) in d.frames.enumerated() where abs(CMTime(value: f.ptsValue, timescale: f.ptsTimescale).seconds - Double(n) / 30) > 0.0005 {
            notes.append("pts \(n) = \(f.ptsValue)/\(f.ptsTimescale)"); break
        }
        let bounds = boundaryFrames(expected).map { n -> BoundaryFrame in
            let m = n < d.frames.count ? d.frames[n].metrics : nil
            return BoundaryFrame(frame: n, expected: expected[n].label, measured: label(m), pass: matches(m, expected[n]))
        }
        let measured = E2Decoder.onsets(d.mono)
        var maxErr: Int? = nil
        var onsetOK = measured.count == onsets.count
        if onsetOK { let errs = zip(measured, onsets).map { abs($0 - $1) }; maxErr = errs.max(); onsetOK = errs.allSatisfy { $0 <= 96 } }
        if !onsetOK { notes.append("onsets differ") }
        var gapMax: Double? = nil, clipMin: Double? = nil
        if toneCheck {
            let spf = DevFixtures.samplesPerFrame
            func rms(_ a: Int, _ b: Int) -> Double? {
                let lo = max(0, a), hi = min(d.mono.count, b)
                guard hi - lo > spf else { return nil }
                var acc = 0.0
                for i in lo..<hi { acc += Double(d.mono[i]) * Double(d.mono[i]) }
                return (acc / Double(hi - lo)).squareRoot()
            }
            var runs: [(gap: Bool, a: Int, b: Int)] = []   // 프레임 구간
            for (n, e) in expected.enumerated() {
                let g = e == .gap
                if let l = runs.last, l.gap == g, l.b == n { runs[runs.count - 1].b = n + 1 } else { runs.append((g, n, n + 1)) }
            }
            for r in runs {
                guard let v = rms((r.a + 1) * spf, (r.b - 1) * spf) else { continue }
                if r.gap { gapMax = max(gapMax ?? 0, v) } else { clipMin = min(clipMin ?? 1, v) }
            }
            if let g = gapMax, g > 0.003 { notes.append(String(format: "gap not silent rms %.4f", g)) }
            if let c = clipMin, c < 0.03 { notes.append(String(format: "clip audio missing rms %.4f", c)) }
        }
        let pass = d.frames.count == expected.count && mismatched.isEmpty && bounds.allSatisfy(\.pass) && onsetOK && notes.isEmpty
            && d.videoFormat["dimensions"] == "1920x1080" && d.videoFormat["codec"] == "avc1"
        return Verdict(pass: pass, frames: d.frames.count, expectedFrames: expected.count, dimensions: d.videoFormat["dimensions"] ?? "?",
                       codec: d.videoFormat["codec"] ?? "?", audioFormat: d.audioFormat, mismatchedFrames: Array(mismatched.prefix(50)),
                       gapFrames: expected.filter { $0 == .gap }.count, boundaries: bounds,
                       expectedOnsets: onsets, measuredOnsets: measured, maxOnsetErrorSamples: maxErr,
                       gapRMSMax: gapMax, clipRMSMin: clipMin, notes: notes)
    }
}
