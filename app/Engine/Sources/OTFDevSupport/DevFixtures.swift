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
        // A-010: 30 fps가 아닌 판독 가능 원본(화면 코드·클릭), 그리고 여전히 거부되는 입력
        for fx in TimedFixture.all { try await ensure(dir, fx.file) { try await writeTimed(fx, to: $0) } }
        try await ensure(dir, "reject-prores.mov") { try await writeVideo($0, type: .mov, w: 320, h: 240, pts: thirty, codec: .proRes422) }
        try await ensure(dir, "reject-500fps.mp4") { try await writeVideo($0, type: .mp4, w: 320, h: 240, pts: (0..<40).map { CMTime(value: CMTimeValue($0), timescale: 500) }) }
        try await ensure(dir, "reject-2video.mov") { try await writeVideo($0, type: .mov, w: 320, h: 240, pts: thirty, tracks: 2) }
        try await ensure(dir, "reject-audio-only.m4a") { try await writeAudioOnly($0) }
        try await ensure(dir, "otf-hevc.mp4") { try await writeVideo($0, type: .mp4, w: 1280, h: 720, pts: thirty, codec: .hevc) }
        try await ensure(dir, "reject-uhd.mp4") { try await writeVideo($0, type: .mp4, w: 3840, h: 2160, pts: Array(thirty.prefix(5))) }
        return all
    }
    public static let all = ["otf-A.mp4", "otf-B.mp4", "otf-TA.mp4", "otf-TB.mp4", "otf-rot90.mp4", "otf-hevc.mp4"] + TimedFixture.all.map(\.file)
        + ["reject-prores.mov", "reject-500fps.mp4", "reject-2video.mov", "reject-audio-only.m4a", "reject-uhd.mp4"]
    /// 거부 fixture → 기대 거부 종류(ProbeError.kind). 25 fps·가변 간격 원본은 A-010부터 받는다(TimedFixture).
    public static let rejects: [String: String] = ["reject-prores.mov": "unsupportedCodec", "reject-500fps.mp4": "frameRate",
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

    /// 판독 가능한 시각 지정 원본: 프레임 f를 fx.pts[f]에 그리고(원본 ID·프레임 코드), 같은 길이의 AAC 소리에 클릭을 넣는다.
    /// 프레임 재정렬(B 프레임)을 켜 실제 파일처럼 표시·디코딩 순서가 다르게 한다.
    static func writeTimed(_ fx: TimedFixture, to url: URL) async throws {
        Spec4K.configure(.fhd)
        let wr = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mov" ? .mov : .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: fx.codec, AVVideoWidthKey: Spec4K.width, AVVideoHeightKey: Spec4K.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Spec4K.sourceVideoBitRate, AVVideoAllowFrameReorderingKey: true],
        ])
        vIn.mediaTimeScale = fx.timescale
        vIn.expectsMediaDataInRealTime = false
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Spec4K.width,
            kCVPixelBufferHeightKey as String: Spec4K.height, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()])
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
        aIn.expectsMediaDataInRealTime = false
        wr.add(vIn); wr.add(aIn)
        guard wr.startWriting() else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "writer") }
        wr.startSession(atSourceTime: .zero)
        let mono = fx.spec.clipAudio.samples()
        var f = 0, s = 0
        // 두 입력을 시각 순서로 번갈아 채운다(한쪽만 채우면 작성기가 다른 쪽을 기다리며 멈출 수 있다)
        while f < fx.pts.count || s < mono.count {
            let vt = f < fx.pts.count ? fx.pts[f].seconds : .infinity, atime = s < mono.count ? Double(s) / Double(sampleRate) : .infinity
            // 시각상 먼저인 쪽을 채우되, 그쪽이 아직 받지 않으면 다른 쪽을 채운다(작성기가 교차 배치를 위해 한쪽을 막을 수 있음)
            if f < fx.pts.count, vIn.isReadyForMoreMediaData, vt <= atime || !aIn.isReadyForMoreMediaData || s >= mono.count {
                guard let pool = ad.pixelBufferPool else { throw E1Error.verificationFailed("pool") }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pb else { throw E1Error.verificationFailed("pixel buffer") }
                try fx.spec.draw(frame: f, into: pb)
                guard ad.append(pb, withPresentationTime: fx.pts[f]) else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "append \(f)") }
                f += 1
                if f == fx.pts.count { vIn.markAsFinished() }
            } else if s < mono.count, aIn.isReadyForMoreMediaData {
                let n = min(1024, mono.count - s)
                guard aIn.append(try pcm(Array(mono[s..<(s + n)]), start: s)) else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "audio") }
                s += n
                if s == mono.count { aIn.markAsFinished() }
            } else { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        wr.endSession(atSourceTime: fx.end)
        await wr.finishWriting()
        guard wr.status == .completed else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "finish") }
    }

    /// 진단용: 같은 정의의 시각 지정 원본을 지정한 위치에 새로 쓴다(A-010 프레임 0 조사, "막 만든 fixture" 조건 재현)
    public static func writeTimedForDiagnostics(_ fx: TimedFixture, to url: URL) async throws { try await writeTimed(fx, to: url) }

    /// 모노 float → 스테레오 float32 PCM 샘플 버퍼
    static func pcm(_ mono: [Float], start: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var st = [Float](repeating: 0, count: mono.count * 2)
        for i in mono.indices { st[2 * i] = mono[i]; st[2 * i + 1] = mono[i] }
        let bytes = st.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block, let fmt else { throw E1Error.verificationFailed("pcm") }
        _ = st.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: mono.count,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        guard let sb else { throw E1Error.verificationFailed("pcm buffer") }
        return sb
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
            guard let spec = DevFixtures.readable[c.file] ?? TimedFixture.byFile[c.file]?.spec else { throw E1Error.verificationFailed("unknown fixture \(c.file)") }
            let st = c.start ?? cursor
            guard st >= cursor else { throw E1Error.verificationFailed("overlap at \(st)") }
            placed.append((c, st, spec)); cursor = st + c.length
        }
        let total = max(durationFrames ?? 0, cursor)
        var ex = [Expected](repeating: .gap, count: total)
        for (c, st, spec) in placed {
            let fx = TimedFixture.byFile[c.file]
            for k in 0..<c.length { ex[st + k] = .source(id: spec.idCode, frame: fx?.frame(atTimelineUnits: c.sourceIn + k) ?? c.sourceIn + k) }
        }
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
                case (.source(let a, let fa), .source(let b, let fb)): change = a != b || (fb != fa + 1 && fb != fa)   // 같은 원본 프레임 유지(30 fps 아닌 원본)는 경계가 아님
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
        // 클릭: 원본 시각(샘플) s가 클립의 원본 구간 [sourceIn, sourceIn + length)/30 s 안이면 타임라인 st/30 + (s − sourceIn/30)에 있어야 한다
        let spf = DevFixtures.samplesPerFrame
        for (c, st, spec) in placed {
            let clicks = TimedFixture.byFile[c.file]?.clickSamples ?? DevFixtures.clickFrames[spec.key]!.map { $0 * spf }
            for s in clicks where s >= c.sourceIn * spf && s < (c.sourceIn + c.length) * spf { onsets.append(st * spf + s - c.sourceIn * spf) }
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

/// 30 fps가 아닌 판독 가능 원본(A-010). 원본 프레임 f는 pts[f]에 표시된다(작성한 값 그대로 = 독립 기대값).
/// 클릭은 원본 시각(48 kHz 샘플 위치)으로 둔다.
public struct TimedFixture: Sendable {
    public let file: String
    public let spec: SourceVideoSpec
    public let pts: [CMTime]
    public let end: CMTime
    public let timescale: CMTimeScale
    public let codec: AVVideoCodecType
    public var clickSamples: [Int] { spec.clipAudio.clickStartSamples }

    static func make(_ key: String, file: String, id: Int, bg: [UInt8], pts: [CMTime], end: CMTime, timescale: CMTimeScale,
                     clicks: [Int], seed: UInt64, codec: AVVideoCodecType = .h264) -> TimedFixture {
        let n = Int((end.seconds * Double(DevFixtures.sampleRate)).rounded(.up))
        let spec = SourceVideoSpec(key: key, idCode: id, background: bg, frames: pts.count,
                                   clipAudio: AudioSynth(lengthSamples: n, tones: [], clickStartSamples: clicks, clickSeed: seed), fileStem: file)
        return TimedFixture(file: file, spec: spec, pts: pts, end: end, timescale: timescale, codec: codec)
    }
    static func cfr(_ n: Int, _ v: Int64, _ ts: Int32) -> ([CMTime], CMTime) {
        ((0..<n).map { CMTime(value: CMTimeValue(Int64($0) * v), timescale: ts) }, CMTime(value: CMTimeValue(Int64(n) * v), timescale: ts))
    }
    /// 29.97 fps(30000/1001), 120프레임 ≈ 4.004 s
    public static let ntsc: TimedFixture = { let (p, e) = cfr(120, 1001, 30000)
        return make("N", file: "otf-N2997.mp4", id: 0x4E, bg: [90, 60, 120], pts: p, end: e, timescale: 30000, clicks: [16_016, 56_056, 96_096, 152_152], seed: 41) }()
    /// 25 fps, 100프레임 = 4 s
    public static let pal: TimedFixture = { let (p, e) = cfr(100, 24, 600)
        return make("P", file: "otf-P25.mp4", id: 0x71, bg: [60, 110, 110], pts: p, end: e, timescale: 600, clicks: [9_600, 48_000, 105_600, 172_800], seed: 43) }()
    /// 가변 간격: 1/60·1/30·1/20·1/24·1/15 s가 섞이고, 프레임 50 뒤에 0.3 s 멈춤. 90프레임.
    /// 끝: AVAssetWriter는 마지막 샘플 길이를 endSession이 아니라 직전 간격으로 정한다(2026-10-10 확인: 트랙 길이 2405/600 s).
    /// 그래서 끝 시각도 마지막 PTS + 직전 간격으로 정의한다(파일에 실제로 쓰이는 값).
    public static let vfr: TimedFixture = {
        let cycle: [Int64] = [10, 20, 30, 25, 40]
        var p: [Int64] = [], t: Int64 = 0
        for k in 0..<90 { p.append(t); t += k == 50 ? 180 : cycle[k % cycle.count] }
        let end = p[89] + (p[89] - p[88])
        return make("V", file: "otf-VFR.mp4", id: 0x96, bg: [120, 100, 40], pts: p.map { CMTime(value: CMTimeValue($0), timescale: 600) },
                    end: CMTime(value: CMTimeValue(end), timescale: 600), timescale: 600, clicks: [14_400, 62_400, 110_400, 158_400], seed: 47) }()
    /// 23.976 fps(24000/1001), 48프레임 ≈ 2.002 s
    public static let film: TimedFixture = { let (p, e) = cfr(48, 1001, 24000)
        return make("F", file: "otf-F23976.mp4", id: 0xA5, bg: [100, 70, 50], pts: p, end: e, timescale: 24000, clicks: [24_000], seed: 53) }()
    /// 59.94 fps(60000/1001), HEVC MOV, 120프레임 ≈ 2.002 s
    public static let high: TimedFixture = { let (p, e) = cfr(120, 1001, 60000)
        return make("H", file: "otf-H5994.mov", id: 0xC3, bg: [50, 80, 130], pts: p, end: e, timescale: 60000, clicks: [36_000], seed: 59, codec: .hevc) }()
    public static let all = [ntsc, pal, vfr, film, high]
    public static let byFile: [String: TimedFixture] = Dictionary(uniqueKeysWithValues: all.map { ($0.file, $0) })

    /// 원본 시각 q/30 s(트랙 시작 기준)에 표시 중인 원본 프레임: PTS ≤ q/30인 마지막 프레임(정확한 정수 비교)
    public func frame(atTimelineUnits q: Int) -> Int {
        var best = 0
        for (f, t) in pts.enumerated() where Int64(t.value) * 30 <= Int64(q) * Int64(t.timescale) { best = f }
        return best
    }
}
