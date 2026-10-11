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
        // A-014: 소리 파일(WAV·AIFF·AAC·ALAC). MP3는 이 Mac에서 만들 수 없어 생성 검증하지 않는다.
        for fx in AudioFixture.all + [AudioFixture.steady] { try await ensure(dir, fx.file) { try fx.write(to: $0) } }
        // A-015: 단색 판(크기·위치 판정용)
        for fx in PlateFixture.all { try await ensure(dir, fx.file) { try await fx.write(to: $0) } }
        try await ensure(dir, "reject-prores.mov") { try await writeVideo($0, type: .mov, w: 320, h: 240, pts: thirty, codec: .proRes422) }
        try await ensure(dir, "reject-500fps.mp4") { try await writeVideo($0, type: .mp4, w: 320, h: 240, pts: (0..<40).map { CMTime(value: CMTimeValue($0), timescale: 500) }) }
        try await ensure(dir, "reject-2video.mov") { try await writeVideo($0, type: .mov, w: 320, h: 240, pts: thirty, tracks: 2) }
        try await ensure(dir, "reject-audio-only.m4a") { try await writeAudioOnly($0) }   // A-014부터 받는 소리 파일(AAC)
        try await ensure(dir, "reject-4ch.wav") { try writeFourChannelWAV($0) }
        try await ensure(dir, "otf-hevc.mp4") { try await writeVideo($0, type: .mp4, w: 1280, h: 720, pts: thirty, codec: .hevc) }
        try await ensure(dir, "reject-uhd.mp4") { try await writeVideo($0, type: .mp4, w: 3840, h: 2160, pts: Array(thirty.prefix(5))) }
        return all
    }
    public static let all = ["otf-A.mp4", "otf-B.mp4", "otf-TA.mp4", "otf-TB.mp4", "otf-rot90.mp4", "otf-hevc.mp4"] + TimedFixture.all.map(\.file)
        + ["reject-prores.mov", "reject-500fps.mp4", "reject-2video.mov", "reject-audio-only.m4a", "reject-uhd.mp4", "reject-4ch.wav"]
    /// 거부 fixture → 기대 거부 종류(ProbeError.kind). 25 fps·가변 간격 원본은 A-010부터 받는다(TimedFixture).
    public static let rejects: [String: String] = ["reject-prores.mov": "unsupportedCodec", "reject-500fps.mp4": "frameRate",
                                                   "reject-2video.mov": "multipleVideoTracks", "reject-4ch.wav": "audioChannels",
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

    /// 4채널 16비트 PCM WAV 0.2초(A-014: 모노·스테레오만 받으므로 거부 대상). 머리글을 직접 쓴다.
    static func writeFourChannelWAV(_ url: URL) throws {
        let ch = 4, rate = 48_000, frames = 9_600, bytes = frames * ch * 2
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + bytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(ch); u32(rate); u32(rate * ch * 2); u16(ch * 2); u16(16)
        d.append(Data("data".utf8)); u32(bytes); d.append(Data(count: bytes))
        try d.write(to: url)
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

    /// audioClips: 원본 소리 레인 클립(A-012). nil이면 영상 클립과 같은 위치(연결된 쌍, 이전 판정과 같음).
    /// checkAudio false: 영상만 판정(소리는 호출 쪽이 따로 판정, A-014 여러 오디오 레인)
    public static func judge(_ url: URL, clips: [ClipRef], audioClips: [ClipRef]? = nil, durationFrames: Int? = nil, toneCheck: Bool = false,
                             checkAudio: Bool = true) async throws -> Verdict {
        Spec4K.configure(.fhd)
        let d = try await E2Decoder.decode(url)
        let (expected, videoPlaced) = try expectations(clips, durationFrames: durationFrames)
        // 소리 판정은 소리 레인 배치로(기본: 영상과 같은 배치)
        let placed = try audioClips.map { try expectations($0, durationFrames: durationFrames).placed } ?? videoPlaced
        var audioCovered = [Bool](repeating: false, count: expected.count)
        for (c, st, _) in placed { for k in st..<min(st + c.length, audioCovered.count) { audioCovered[k] = true } }
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
        if !checkAudio { onsetOK = true }
        if !onsetOK { notes.append("onsets differ") }
        var gapMax: Double? = nil, clipMin: Double? = nil
        if toneCheck && checkAudio {
            let spf = DevFixtures.samplesPerFrame
            func rms(_ a: Int, _ b: Int) -> Double? {
                let lo = max(0, a), hi = min(d.mono.count, b)
                guard hi - lo > spf else { return nil }
                var acc = 0.0
                for i in lo..<hi { acc += Double(d.mono[i]) * Double(d.mono[i]) }
                return (acc / Double(hi - lo)).squareRoot()
            }
            var runs: [(gap: Bool, a: Int, b: Int)] = []   // 프레임 구간(소리 레인 기준)
            for n in expected.indices {
                let g = !audioCovered[n]
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

/// 소리 파일 fixture(A-014). 표본율·채널·길이(표본)·음높이·클릭 위치(이 파일의 표본 위치)를 쓸 때 정하므로 기대값은 이 상수에서 직접 계산한다.
/// 음: 진폭 0.2 사인(앞뒤 240표본 페이드), 클릭: AudioSynth와 같은 96표본 잡음 버스트(첫 표본 0.8). 왼쪽·오른쪽 같은 값.
public struct AudioFixture: Sendable {
    public enum Kind: Sendable { case wav, aiff, aac, alac }
    public let file: String
    public let kind: Kind
    public let sampleRate: Int
    public let channels: Int
    public let lengthSamples: Int
    public let toneHz: Double
    public let clicks: [Int]
    public static let toneAmplitude = 0.2

    public static let wav = AudioFixture(file: "aud-wav48s.wav", kind: .wav, sampleRate: 48_000, channels: 2, lengthSamples: 96_000, toneHz: 440, clicks: [12_345, 60_000])
    public static let aiff = AudioFixture(file: "aud-aiff441m.aiff", kind: .aiff, sampleRate: 44_100, channels: 1, lengthSamples: 66_000, toneHz: 1_000, clicks: [33_333])
    public static let aac = AudioFixture(file: "aud-aac48s.m4a", kind: .aac, sampleRate: 48_000, channels: 2, lengthSamples: 76_800, toneHz: 2_500, clicks: [20_000])
    public static let alac = AudioFixture(file: "aud-alac441s.m4a", kind: .alac, sampleRate: 44_100, channels: 2, lengthSamples: 44_100, toneHz: 700, clicks: [])
    public static let all = [wav, aiff, aac, alac]
    /// 클립 음량·페이드 판정용(2026-10-11): 48 kHz 스테레오 WAV 6초, 1000 Hz 사인 진폭 0.2, 클릭 없음(끝 5 ms만 부드럽게). `all`에는 넣지 않는다.
    public static let steady = AudioFixture(file: "aud-steady48s.wav", kind: .wav, sampleRate: 48_000, channels: 2, lengthSamples: 288_000, toneHz: 1_000, clicks: [])
    public static let byFile = Dictionary(uniqueKeysWithValues: all.map { ($0.file, $0) })

    /// 편집 격자 길이: 길이(초)를 1/30 s로 올림(손 계산과 같은 식)
    public var expectedFrames: Int { (lengthSamples * 30 + sampleRate - 1) / sampleRate }
    public var expectedCodec: String {
        switch kind { case .wav, .aiff: return "lpcm"; case .aac: return "aac "; case .alac: return "alac" }
    }

    public func samples() -> [Float] {
        let clicks = AudioSynth(lengthSamples: lengthSamples, tones: [], clickStartSamples: clicks, clickSeed: UInt64(lengthSamples)).samples()
        let fade = Double(AudioSynth.fadeSamples)
        return (0..<lengthSamples).map { i in
            let edge = Double(min(i, lengthSamples - 1 - i))
            let g = edge < fade ? 0.5 * (1 - cos(Double.pi * edge / fade)) : 1
            let x = Double(clicks[i]) + Self.toneAmplitude * g * sin(2 * Double.pi * toneHz * Double(i) / Double(sampleRate))
            return Float(max(-1, min(1, x)))
        }
    }

    public func write(to url: URL) throws {
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        switch kind {
        case .wav: settings.merge([AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]) { $1 }
        case .aiff: settings.merge([AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]) { $1 }
        case .aac: settings.merge([AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 192_000]) { $1 }
        case .alac: settings.merge([AVFormatIDKey: kAudioFormatAppleLossless, AVEncoderBitDepthHintKey: 16]) { $1 }
        }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(lengthSamples)) else { throw E1Error.verificationFailed("audio format \(file)") }
        let x = samples()
        buf.frameLength = AVAudioFrameCount(lengthSamples)
        for c in 0..<channels { x.withUnsafeBufferPointer { buf.floatChannelData![c].update(from: $0.baseAddress!, count: lengthSamples) } }
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try f.write(from: buf)
    }

    /// 타임라인에 놓은 소리 클립(start, sourceIn: 1/30 s 단위)의 클릭이 48 kHz 내보내기에서 나타날 표본 위치.
    /// 원본 시각 = 클릭 표본 / 표본율(프레임으로 반올림하지 않음). 원본 구간 [sourceIn, sourceIn + length)/30 s 안의 클릭만.
    public func expectedOnsets48k(start: Int, sourceIn: Int, length: Int) -> [Int] {
        clicks.compactMap { c in
            let t = Double(c) / Double(sampleRate)
            guard t >= Double(sourceIn) / 30, t < Double(sourceIn + length) / 30 else { return nil }
            return Int(((Double(start) / 30 + t - Double(sourceIn) / 30) * 48_000).rounded())
        }
    }
}

/// 여러 레인 내보내기 판정(A-014, otf-dev verify-multilane). 엔진의 보이는 조각 계산을 쓰지 않고, 레인 배치에서 프레임마다 직접 셈한다.
/// - 영상: 각 프레임에 클립이 있는 가장 위 영상 레인의 원본 프레임, 없으면 검정(ExportJudge, 소리 판정 제외).
/// - 소리: 음소거하지 않은 오디오 레인 클립의 클릭(원본 표본 위치에서 계산)만 있어야 한다(±16표본, 50 ms 안 겹침은 하나로).
///   소리 파일 fixture의 음 진폭 = 0.2 × 레인 음량(같은 음높이의 다른 소리가 겹치지 않는 구간만), 음소거 레인의 음은 0.01 미만.
public enum MultiLaneJudge {
    public struct LaneClip: Codable, Sendable {
        public let file: String; public let start: Int; public let sourceIn: Int; public let length: Int
        public init(file: String, start: Int, sourceIn: Int, length: Int) { self.file = file; self.start = start; self.sourceIn = sourceIn; self.length = length }
    }
    public struct LaneRef: Codable, Sendable {
        public let kind: String; public let name: String; public let muted: Bool; public let volumePercent: Int; public let clips: [LaneClip]
        public init(kind: String, name: String, muted: Bool, volumePercent: Int, clips: [LaneClip]) {
            self.kind = kind; self.name = name; self.muted = muted; self.volumePercent = volumePercent; self.clips = clips
        }
    }
    public struct Manifest: Codable, Sendable {
        public let exportFile: String; public let durationFrames: Int; public let lanes: [LaneRef]
        public init(exportFile: String, durationFrames: Int, lanes: [LaneRef]) { self.exportFile = exportFile; self.durationFrames = durationFrames; self.lanes = lanes }
    }
    public struct ToneResult: Codable, Sendable { public let file: String; public let lane: String; public let expected: Double; public let measured: Double; public let pass: Bool }
    public struct Result: Codable, Sendable {
        public let pass: Bool; public let video: ExportJudge.Verdict; public let expectedOnsets: [Int]; public let measuredOnsets: [Int]; public let maxOnsetError: Int?
        public let tones: [ToneResult]
        /// 내보낸 MP4의 소리 트랙 수(들리는 소리가 있으면 섞인 트랙 하나여야 한다)
        public let audioTracks: Int
    }

    /// 프레임마다 가장 위 영상 레인 → 같은 원본이 이어지는 구간으로 묶은 ClipRef(독립 계산)
    public static func expectedVideo(_ m: Manifest) -> [ExportJudge.ClipRef] {
        var out: [ExportJudge.ClipRef] = []
        for n in 0..<m.durationFrames {
            var hit: (String, Int)? = nil
            for l in m.lanes where l.kind == "video" {
                if let c = l.clips.first(where: { n >= $0.start && n < $0.start + $0.length }) { hit = (c.file, c.sourceIn + n - c.start); break }
            }
            guard let (f, src) = hit else { continue }
            if let last = out.last, last.file == f, (last.start ?? 0) + last.length == n, last.sourceIn + last.length == src {
                out[out.count - 1] = ExportJudge.ClipRef(file: f, start: last.start, sourceIn: last.sourceIn, length: last.length + 1)
            } else { out.append(ExportJudge.ClipRef(file: f, start: n, sourceIn: src, length: 1)) }
        }
        return out
    }
    /// 원본 파일의 클릭(원본 시각, 초)과 음높이
    static func source(_ file: String) -> (clicks: [Double], hz: Double?, amplitude: Double, isAudioFile: Bool) {
        if let a = AudioFixture.byFile[file] { return (a.clicks.map { Double($0) / Double(a.sampleRate) }, a.toneHz, AudioFixture.toneAmplitude, true) }
        if let v = DevFixtures.readable[file] {
            return (DevFixtures.clickFrames[v.key]!.map { Double($0) / 30 }, v.clipAudio.tones.first?.hz, v.clipAudio.tones.first?.amplitude ?? 0, false)
        }
        return ([], nil, 0, false)
    }
    public static func expectedOnsets(_ m: Manifest) -> [Int] {
        var all: [Int] = []
        for l in m.lanes where l.kind == "audio" && !l.muted && l.volumePercent > 0 {
            for c in l.clips {
                for t in source(c.file).clicks where t >= Double(c.sourceIn) / 30 && t < Double(c.sourceIn + c.length) / 30 {
                    all.append(Int(((Double(c.start) / 30 + t - Double(c.sourceIn) / 30) * 48_000).rounded()))
                }
            }
        }
        var out: [Int] = []
        for x in all.sorted() where out.last.map({ x - $0 > 2400 }) ?? true { out.append(x) }   // 감지기의 50 ms 안 겹침과 같게
        return out
    }
    public static func judge(_ url: URL, _ m: Manifest) async throws -> Result {
        let video = try await ExportJudge.judge(url, clips: expectedVideo(m), durationFrames: m.durationFrames, checkAudio: false)
        let audioTracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count
        let d = try await E2Decoder.decode(url)   // 첫 소리 트랙만 읽는다(여러 트랙을 섞지 않음 — 흔한 재생기와 같음)
        let expected = expectedOnsets(m), measured = E2Decoder.onsets(d.mono)
        var onsetOK = expected.count == measured.count, maxErr: Int? = nil
        if onsetOK { let e = zip(measured, expected).map { abs($0 - $1) }; maxErr = e.max(); onsetOK = e.allSatisfy { $0 <= 16 } }
        let tones = expectedTones(m).map { t in
            let measuredAmp = toneAmplitude(d.mono, hz: t.hz, from: t.from * 1_600, to: t.to * 1_600)
            return ToneResult(file: t.files, lane: t.lanes, expected: t.amplitude, measured: measuredAmp,
                              pass: t.amplitude < 0.005 ? measuredAmp < 0.01 : abs(measuredAmp - t.amplitude) <= 0.03)
        }
        let audible = !expected.isEmpty || tones.contains { $0.expected > 0 }
        return Result(pass: video.pass && onsetOK && tones.allSatisfy(\.pass) && audioTracks == (audible ? 1 : audioTracks), video: video,
                      expectedOnsets: expected, measuredOnsets: measured, maxOnsetError: maxErr, tones: tones, audioTracks: audioTracks)
    }
    public struct ExpectedTone: Sendable { public let hz: Double; public let from: Int; public let to: Int; public let amplitude: Double; public let files: String; public let lanes: String }
    /// 음 진폭 기대값(독립 계산): 음높이마다 클립 경계로 나눈 구간(앞뒤 3프레임 제외, 8프레임 넘는 구간만)에서, 그 구간을 덮는
    /// 들리는 클립들의 사인을 위상까지 더한 크기. 원본 음은 원본 표본 0에서 sin 위상 0으로 시작하므로, 타임라인 표본 n에서의 위상은
    /// 2π·hz·(n/48000 − start/30 + sourceIn/30)이다. 음량은 레인 음량, 음소거는 0(정규화·리미터 없음 — 그냥 더함).
    /// 음소거한 레인의 클립도 구간을 만들어 그 음이 없는지 본다.
    public static func expectedTones(_ m: Manifest) -> [ExpectedTone] {
        struct Placed { let lane: LaneRef; let clip: LaneClip; let hz: Double; let amp: Double }
        var placed: [Placed] = []
        for l in m.lanes where l.kind == "audio" {
            for c in l.clips { let s = source(c.file); if let hz = s.hz { placed.append(Placed(lane: l, clip: c, hz: hz, amp: s.amplitude)) } }
        }
        var out: [ExpectedTone] = []
        for hz in Set(placed.map(\.hz)).sorted() {
            let same = placed.filter { $0.hz == hz }
            let edges = Set(same.flatMap { [$0.clip.start, $0.clip.start + $0.clip.length] }).sorted()
            for (s0, s1) in zip(edges, edges.dropFirst()) where s1 - s0 > 8 {
                let covering = same.filter { $0.clip.start <= s0 && $0.clip.start + $0.clip.length >= s1 }
                guard !covering.isEmpty else { continue }
                var re = 0.0, im = 0.0
                for p in covering where !p.lane.muted {
                    let g = p.amp * Double(p.lane.volumePercent) / 100
                    let ph = 2 * Double.pi * hz * Double(p.clip.sourceIn - p.clip.start) / 30
                    re += g * cos(ph); im += g * sin(ph)
                }
                out.append(ExpectedTone(hz: hz, from: s0 + 3, to: s1 - 3, amplitude: (re * re + im * im).squareRoot(),
                                        files: covering.map(\.clip.file).joined(separator: "+"), lanes: covering.map(\.lane.name).joined(separator: "+")))
            }
        }
        return out
    }
    public static func toneAmplitude(_ x: [Float], hz: Double, from: Int, to: Int) -> Double {
        let lo = max(0, from), hi = min(x.count, to)
        guard hi > lo else { return 0 }
        var i = 0.0, q = 0.0
        for n in lo..<hi { let ph = 2 * Double.pi * hz * Double(n) / 48_000; i += Double(x[n]) * cos(ph); q += Double(x[n]) * sin(ph) }
        return 2 * (i * i + q * q).squareRoot() / Double(hi - lo)
    }
}

/// 단색 판 영상(A-015, 크기·위치 판정용). 3초(90프레임) 30 fps H.264, 소리 없음. 색과 크기를 쓸 때 정하므로 기대 사각형은
/// 이 상수에서 손으로 계산한다(OverlayJudge.expectedRect). 4:3 판은 기본 맞춤에서 좌우 여백이 생긴다.
public struct PlateFixture: Sendable {
    public let file: String
    public let width: Int, height: Int
    public let rgb: (UInt8, UInt8, UInt8)
    public let name: String
    public static let red43 = PlateFixture(file: "plate-red-640x480.mp4", width: 640, height: 480, rgb: (220, 40, 40), name: "red")
    public static let blue = PlateFixture(file: "plate-blue-1920x1080.mp4", width: 1920, height: 1080, rgb: (40, 60, 220), name: "blue")
    public static let green = PlateFixture(file: "plate-green-1280x720.mp4", width: 1280, height: 720, rgb: (40, 200, 60), name: "green")
    public static let all = [red43, blue, green]
    public static let byFile = Dictionary(uniqueKeysWithValues: all.map { ($0.file, $0) })
    public static let frames = 90

    public func write(to url: URL) async throws {
        let wr = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        i.expectsMediaDataInRealTime = false
        wr.add(i)
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard wr.startWriting() else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "writer") }
        wr.startSession(atSourceTime: .zero)
        for k in 0..<Self.frames {
            while !i.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            guard let pb else { throw E1Error.verificationFailed("pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            let bpr = CVPixelBufferGetBytesPerRow(pb), base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height { for x in 0..<width { let o = y * bpr + x * 4; base[o] = rgb.2; base[o + 1] = rgb.1; base[o + 2] = rgb.0; base[o + 3] = 255 } }
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: 30)) else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "append") }
        }
        i.markAsFinished()
        wr.endSession(atSourceTime: CMTime(value: CMTimeValue(Self.frames), timescale: 30))
        await wr.finishWriting()
        guard wr.status == .completed else { throw E1Error.verificationFailed(wr.error?.localizedDescription ?? "finish") }
    }
}

/// 겹친 영상의 크기·위치 판정(A-015). 엔진의 변형 계산을 쓰지 않고 좌표계 정의(app/README §17)에서 직접 계산한다.
public enum OverlayJudge {
    /// 출력 화면(1920×1080, 왼쪽 위 원점, 아래가 +Y)에서 판의 사각형: 기본 맞춤 배율 f = min(1920/w, 1080/h),
    /// 크기 w·f·s × h·f·s, 가운데 (960 + offsetX, 540 + offsetY). 화면 밖은 자르기 전 값.
    public static func expectedRect(_ p: PlateFixture, scalePermille: Int, offsetX: Int, offsetY: Int) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        let f = min(1920 / Double(p.width), 1080 / Double(p.height)), s = Double(scalePermille) / 1000
        let w = Double(p.width) * f * s, h = Double(p.height) * f * s
        let cx = 960 + Double(offsetX), cy = 540 + Double(offsetY)
        return (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
    }
    /// 화소 분류: 가장 가까운 판 색(거리 60 이하) 또는 검정(모두 30 이하), 아니면 "?"
    public static func classify(_ f: FrameCompare.Frame, _ x: Int, _ y: Int) -> String {
        guard x >= 0, y >= 0, x < f.width, y < f.height else { return "out" }
        let i = (y * f.width + x) * 4
        let b = Double(f.bgra[i]), g = Double(f.bgra[i + 1]), r = Double(f.bgra[i + 2])
        if r <= 30 && g <= 30 && b <= 30 { return "black" }
        var best = ("?", 1e9)
        for p in PlateFixture.all {
            let d = ((r - Double(p.rgb.0)) * (r - Double(p.rgb.0)) + (g - Double(p.rgb.1)) * (g - Double(p.rgb.1)) + (b - Double(p.rgb.2)) * (b - Double(p.rgb.2))).squareRoot()
            if d < best.1 { best = (p.name, d) }
        }
        return best.1 <= 60 ? best.0 : "?"
    }
    /// 가로줄 y에서 분류가 바뀌는 x(바뀐 뒤 첫 화소). 경계의 섞인 화소("?")는 건너뛴다.
    public static func horizontalEdges(_ f: FrameCompare.Frame, y: Int) -> [(x: Int, from: String, to: String)] {
        var out: [(Int, String, String)] = []
        var last = classify(f, 0, y)
        for x in 1..<f.width {
            let c = classify(f, x, y)
            if c == "?" { continue }
            if c != last { out.append((x, last, c)); last = c }
        }
        return out
    }
    /// 겹친 판 레이어(위 → 아래)의 격자 판정(otf-dev verify-overlay). 각 표본점의 기대 색: 그 프레임에 있는 위 레이어부터,
    /// 점이 기대 사각형 안(가장자리에서 margin 넘게 안쪽)이면 그 판 색, 가장자리 margin 안이면 건너뜀, 아무 레이어에도 없으면 검정.
    public struct Layer: Codable, Sendable {
        public let file: String; public let start: Int; public let length: Int; public let scalePermille: Int; public let offsetX: Int; public let offsetY: Int
        public init(file: String, start: Int, length: Int, scalePermille: Int, offsetX: Int, offsetY: Int) {
            self.file = file; self.start = start; self.length = length; self.scalePermille = scalePermille; self.offsetX = offsetX; self.offsetY = offsetY
        }
    }
    public struct GridResult: Codable, Sendable { public let frame: Int; public let checked: Int; public let mismatches: [String] }
    public static func judgeGrid(_ f: FrameCompare.Frame, frame: Int, layers: [Layer], step: Int = 40, margin: Double = 4) -> GridResult {
        var checked = 0, bad: [String] = []
        for y in stride(from: step / 2, to: 1080, by: step) {
            for x in stride(from: step / 2, to: 1920, by: step) {
                var expected: String? = "black"
                for l in layers where frame >= l.start && frame < l.start + l.length {
                    guard let p = PlateFixture.byFile[l.file] else { expected = nil; break }
                    let r = expectedRect(p, scalePermille: l.scalePermille, offsetX: l.offsetX, offsetY: l.offsetY)
                    let px = Double(x), py = Double(y)
                    let inside = px > r.x0 + margin && px < r.x1 - margin && py > r.y0 + margin && py < r.y1 - margin
                    let near = px >= r.x0 - margin && px <= r.x1 + margin && py >= r.y0 - margin && py <= r.y1 + margin
                    if inside { expected = p.name; break }
                    if near { expected = nil; break }   // 가장자리(섞인 화소)
                }
                guard let e = expected else { continue }
                checked += 1
                let m = classify(f, x, y)
                if m != e { bad.append("(\(x),\(y)) \(e)≠\(m)") }
            }
        }
        return GridResult(frame: frame, checked: checked, mismatches: bad)
    }
    public static func verticalEdges(_ f: FrameCompare.Frame, x: Int) -> [(y: Int, from: String, to: String)] {
        var out: [(Int, String, String)] = []
        var last = classify(f, x, 0)
        for y in 1..<f.height {
            let c = classify(f, x, y)
            if c == "?" { continue }
            if c != last { out.append((y, last, c)); last = c }
        }
        return out
    }
}
