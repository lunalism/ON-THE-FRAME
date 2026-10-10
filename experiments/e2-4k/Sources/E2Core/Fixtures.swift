import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import E1Core
import Foundation

// MARK: - 합성 오디오(48 kHz, 모든 시각은 샘플 인덱스)

public struct ToneSpan: Codable, Sendable {
    public let startSample: Int, endSample: Int, hz: Double, amplitude: Double
    public init(_ startSample: Int, _ endSample: Int, hz: Double, amplitude: Double) {
        self.startSample = startSample; self.endSample = endSample; self.hz = hz; self.amplitude = amplitude
    }
}

public struct AudioSynth: Codable, Sendable {
    public let lengthSamples: Int
    public let tones: [ToneSpan]
    public let clickStartSamples: [Int]
    public let clickSeed: UInt64
    public static let clickLength = 96, clickAmplitude = 0.8, fadeSamples = 240

    public init(lengthSamples: Int, tones: [ToneSpan], clickStartSamples: [Int], clickSeed: UInt64) {
        self.lengthSamples = lengthSamples; self.tones = tones; self.clickStartSamples = clickStartSamples; self.clickSeed = clickSeed
    }

    func burst() -> [Double] {
        var state = clickSeed
        var out = [Double](repeating: 0, count: Self.clickLength)
        for i in 0..<Self.clickLength {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out[i] = (Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF) * 2 - 1) * Self.clickAmplitude
        }
        out[0] = Self.clickAmplitude   // 시작 샘플을 명확히 해 onset 측정을 쉽게 한다
        return out
    }

    /// 모노 샘플(L=R로 쓴다)
    public func samples() -> [Float] {
        let b = burst()
        var out = [Float](repeating: 0, count: lengthSamples)
        for i in 0..<lengthSamples {
            var x = 0.0
            for t in tones where i >= t.startSample && i < t.endSample {
                let k = i - t.startSample, edge = min(k, t.endSample - 1 - i)
                let g = edge < Self.fadeSamples ? 0.5 * (1 - cos(Double.pi * Double(edge) / Double(Self.fadeSamples))) : 1
                x += t.amplitude * g * sin(2 * Double.pi * t.hz * Double(k) / 48_000)
            }
            for c in clickStartSamples where i >= c && i < c + Self.clickLength { x += b[i - c] }
            out[i] = Float(max(-1, min(1, x)))
        }
        return out
    }

    /// WAV(LPCM s16le 48 kHz 스테레오, L=R) 바이트. 변환기·디더 개입 없음.
    public func wavData() -> Data {
        let s = samples()
        let dataBytes = s.count * 4
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        for x in s {
            let v = Int16((Double(x) * 32767).rounded()).littleEndian
            withUnsafeBytes(of: v) { d.append(contentsOf: $0); d.append(contentsOf: $0) }
        }
        return d
    }
}

// MARK: - 선택 오디오(음악) M

public enum MusicFixture {
    /// 선택 소스 M(12초, WAV). 톤 250 Hz [2, 5) s, 1500 Hz [6, 9) s. 클릭(원본 시각, 프레임 중간):
    /// 61/60, 211/60, 451/60, 571/60, 691/60 s. 타임라인에는 [2, 11) s 구간만 1.0 s부터 놓인다.
    public static let synth = AudioSynth(
        lengthSamples: 12 * 48_000,
        tones: [ToneSpan(2 * 48_000, 5 * 48_000, hz: 250, amplitude: 0.25),
                ToneSpan(6 * 48_000, 9 * 48_000, hz: 1500, amplitude: 0.25)],
        clickStartSamples: [48_800, 168_800, 360_800, 456_800, 552_800],
        clickSeed: 0x2E25E1EC)
    public static let fileName = "M-music.wav"
}

// MARK: - 소스 영상 A, B, C

public struct SourceVideoSpec: Codable, Sendable {
    public let key: String            // "A", "B", "C"
    public let idCode: Int            // 화면에 그리는 8비트 소스 ID
    public let background: [UInt8]   // R, G, B
    public let frames: Int
    public let clipAudio: AudioSynth  // 이 소스 영상에 들어 있는 오디오(무관 클립 오디오)

    /// v2: 질감 영역 추가(2026-10-10). 단색만 있던 첫 버전은 4K 30 Mbps 설정에서도 약 0.45 MiB로 압축되어
    /// 디코딩·인코딩 측정이 비현실적으로 쉬웠다. 첫 버전 파일은 지우지 않고 다른 이름으로 남는다.
    public var fileName: String { "src-\(key)-3840x2160-30p-v2.mp4" }
    /// 진단용 비교 fixture(같은 화면·오디오, 프레임 재정렬 끔). 원래 v2 파일은 바꾸지 않는다.
    public var noReorderFileName: String { "src-\(key)-3840x2160-30p-v2-noreorder.mp4" }
    /// 질감 영역(위쪽-왼쪽 원점): 측정 위치(코드 행, 이동 상자 행, 배경 측정 위치, 자막 띠)를 피한다.
    public static let textureRect = CGRect(x: 400, y: 900, width: 3400, height: 900)
    public var gridColor: [UInt8] { background.map { UInt8(min(255, Int($0) + 40)) } }

    public static let a = SourceVideoSpec(key: "A", idCode: 0x2D, background: [110, 40, 40], frames: 240,
        clipAudio: AudioSynth(lengthSamples: 8 * 48_000, tones: [ToneSpan(0, 8 * 48_000, hz: 3500, amplitude: 0.1)],
                              clickStartSamples: (0..<8).map { 12_000 + 48_000 * $0 }, clickSeed: 0xA11CE))
    public static let b = SourceVideoSpec(key: "B", idCode: 0x5A, background: [40, 100, 50], frames: 240,
        clipAudio: AudioSynth(lengthSamples: 8 * 48_000, tones: [ToneSpan(0, 8 * 48_000, hz: 5000, amplitude: 0.1)],
                              clickStartSamples: (0..<8).map { 4_800 + 48_000 * $0 }, clickSeed: 0xB0B))
    public static let c = SourceVideoSpec(key: "C", idCode: 0xB4, background: [40, 50, 120], frames: 180,
        clipAudio: AudioSynth(lengthSamples: 6 * 48_000, tones: [ToneSpan(0, 6 * 48_000, hz: 7000, amplitude: 0.1)],
                              clickStartSamples: (0..<6).map { 28_800 + 48_000 * $0 }, clickSeed: 0xC0C0A))
    public static let all = [a, b, c]
    public static func byKey(_ k: String) -> SourceVideoSpec? { all.first { $0.key == k } }

    /// 소스 프레임 f를 BGRA 4K 버퍼에 그린다(결정적, 상태 없음).
    public func draw(frame f: Int, into pb: CVPixelBuffer) throws {
        try withContext(pb) { ctx in
            let H = Spec4K.height
            func fill(_ x: Int, _ yTop: Int, _ w: Int, _ h: Int, _ c: [UInt8]) {
                ctx.setFillColor(red: CGFloat(c[0]) / 255, green: CGFloat(c[1]) / 255, blue: CGFloat(c[2]) / 255, alpha: 1)
                ctx.fill(CGRect(x: x, y: H - yTop - h, width: w, height: h))
            }
            let on: [UInt8] = [Spec4K.codeOn.0, Spec4K.codeOn.1, Spec4K.codeOn.2], off: [UInt8] = [0, 0, 0]
            fill(0, 0, Spec4K.width, H, background)
            for x in stride(from: Spec4K.gridPitch, to: Spec4K.width, by: Spec4K.gridPitch) { fill(x, 0, Spec4K.gridLine, H, gridColor) }
            for y in stride(from: Spec4K.gridPitch, to: H, by: Spec4K.gridPitch) { fill(0, y, Spec4K.width, Spec4K.gridLine, gridColor) }
            for b in 0..<Spec4K.sourceIDBits {
                let bit = (idCode >> (Spec4K.sourceIDBits - 1 - b)) & 1 == 1
                fill(Spec4K.cellLeft + b * Spec4K.cellPitch, Spec4K.sourceIDRowY, Spec4K.cellSize, Spec4K.cellSize, bit ? on : off)
            }
            for b in 0..<Spec4K.codeBits {
                let bit = (f >> (Spec4K.codeBits - 1 - b)) & 1 == 1
                fill(Spec4K.cellLeft + b * Spec4K.cellPitch, Spec4K.sourceFrameRowY, Spec4K.cellSize, Spec4K.cellSize, bit ? on : off)
            }
            fill(Spec4K.boxX(f), Spec4K.boxY, Spec4K.boxSize, Spec4K.boxSize, on)
            drawTexture(ctx, frame: f)
            // 사람이 보는 표시(측정에는 쓰지 않음): 큰 소스 글자와 "A  f=123"
            ctx.setShouldAntialias(true)
            drawText(ctx, key, size: 480, x: 3200, baselineFromTop: 780)
            drawText(ctx, "\(key)  f=\(f)", size: 120, x: 2000, baselineFromTop: 320)
        }
    }

    /// 프레임마다 위치가 크게 바뀌는 잡음 타일(256×256, 소스별 시드). R·B 채널만 흔들고 G는 배경값(≤ 100)으로 둔다.
    /// 그래서 막대 색(G > 120)·자막·상자(최소 채널 > 200) 측정에 걸리지 않는다.
    func drawTexture(_ ctx: CGContext, frame f: Int) {
        let n = 256
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        var s = UInt64(idCode) &* 0x9E3779B97F4A7C15 &+ UInt64(f) &* 0xBF58476D1CE4E5B9
        for i in 0..<(n * n) {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let a = Int((s >> 33) & 0x7F) - 64, b = Int((s >> 41) & 0x7F) - 64
            bytes[i * 4] = UInt8(max(0, min(255, Int(background[0]) + a)))
            bytes[i * 4 + 1] = background[1]
            bytes[i * 4 + 2] = UInt8(max(0, min(255, Int(background[2]) + b)))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        let r = Self.textureRect
        let cg = CGRect(x: r.minX, y: CGFloat(Spec4K.height) - r.maxY, width: r.width, height: r.height)
        ctx.saveGState()
        ctx.clip(to: cg)
        ctx.interpolationQuality = .none
        let ox = (f * 97) % n, oy = (f * 61) % n
        for x in stride(from: Int(cg.minX) - ox, to: Int(cg.maxX), by: n) {
            for y in stride(from: Int(cg.minY) - oy, to: Int(cg.maxY), by: n) { ctx.draw(img, in: CGRect(x: x, y: y, width: n, height: n)) }
        }
        ctx.restoreGState()
    }

    func drawText(_ ctx: CGContext, _ s: String, size: CGFloat, x: Int, baselineFromTop y: Int) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: Spec4K.height - y)
        CTLineDraw(line, ctx)
    }
}

/// BGRA 4K 버퍼에 CGContext를 만들어 그린다.
public func withContext(_ pb: CVPixelBuffer, _ body: (CGContext) throws -> Void) throws {
    guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
          CVPixelBufferGetWidth(pb) == Spec4K.width, CVPixelBufferGetHeight(pb) == Spec4K.height else {
        throw E1Error.render("unexpected pixel buffer \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
    }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let base = CVPixelBufferGetBaseAddress(pb),
          let ctx = CGContext(data: base, width: Spec4K.width, height: Spec4K.height, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw E1Error.render("CGContext creation failed") }
    ctx.setShouldAntialias(false)
    try body(ctx)
}

public func makeBuffer4K() throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    let st = CVPixelBufferCreate(nil, Spec4K.width, Spec4K.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    guard st == kCVReturnSuccess, let b = pb else { throw E1Error.render("CVPixelBufferCreate \(st)") }
    return b
}

// MARK: - fixture 생성(없을 때만)

/// 안전성(@unchecked Sendable, 큐 한정): 비디오 멤버는 비디오 큐에서만, 오디오 멤버는 오디오 큐에서만 쓴다.
struct FixtureWriterBox: @unchecked Sendable {
    let vIn: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let aIn: AVAssetWriterInput
}

public enum SourceFixtures {
    /// 소스 영상이 없으면 임시 이름으로 쓰고 RENAME_EXCL로 배치한다. 인코더 출력은 비트 재현이 보장되지 않으므로
    /// 있으면 다시 만들지 않고 해시만 기록한다.
    public static func ensure(_ spec: SourceVideoSpec, in dir: URL, allowFrameReordering: Bool = true) async throws -> (url: URL, created: Bool, sha256: String, seconds: Double) {
        let url = dir.appendingPathComponent(allowFrameReordering ? spec.fileName : spec.noReorderFileName)
        if FileManager.default.fileExists(atPath: url.path) { return (url, false, try Hashing.sha256(file: url), 0) }
        let t0 = Clock.now()
        let temp = dir.appendingPathComponent(".e2-src-\(UUID().uuidString).mp4")
        do {
            try await write(spec, to: temp, allowFrameReordering: allowFrameReordering)
            try OutputGuard.promote(temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return (url, true, try Hashing.sha256(file: url), Double(Clock.now() - t0) / 1e9)
    }

    public static func ensureMusic(in dir: URL) throws -> (url: URL, created: Bool, sha256: String) {
        let url = dir.appendingPathComponent(MusicFixture.fileName)
        let data = MusicFixture.synth.wavData()
        let want = Hashing.sha256(data)
        if FileManager.default.fileExists(atPath: url.path) {
            let disk = try Hashing.sha256(file: url)
            guard disk == want else { throw E1Error.invalidSource("\(MusicFixture.fileName) hash differs from its definition") }
            return (url, false, disk)
        }
        let temp = dir.appendingPathComponent(".e2-music-\(UUID().uuidString).wav")
        try data.write(to: temp)
        do { try OutputGuard.promote(temp, to: url) } catch { try? FileManager.default.removeItem(at: temp); throw error }
        return (url, true, want)
    }

    static func write(_ spec: SourceVideoSpec, to url: URL, allowFrameReordering: Bool = true) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Spec4K.width, AVVideoHeightKey: Spec4K.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Spec4K.sourceVideoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30, AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoAllowFrameReorderingKey: allowFrameReordering,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Spec4K.width, kCVPixelBufferHeightKey as String: Spec4K.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        ])
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: Spec4K.aacBitRate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        aIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn), writer.canAdd(aIn) else { throw E1Error.writer("fixture: cannot add inputs") }
        writer.add(vIn); writer.add(aIn)
        guard writer.startWriting() else { throw E1Error.writer(writer.error?.localizedDescription ?? "fixture startWriting") }
        writer.startSession(atSourceTime: .zero)

        let mono = spec.clipAudio.samples()
        let box = FixtureWriterBox(vIn: vIn, adaptor: adaptor, aIn: aIn)
        let failure = Locked<String?>(nil)
        let vNext = Locked(0), aNext = Locked(0)
        let group = DispatchGroup()
        group.enter(); group.enter()
        let vq = DispatchQueue(label: "e2.fixture.video"), aq = DispatchQueue(label: "e2.fixture.audio")
        let vDone = Locked(false), aDone = Locked(false)
        box.vIn.requestMediaDataWhenReady(on: vq) {
            if vDone.get() { return }
            while box.vIn.isReadyForMoreMediaData {
                let f = vNext.get()
                if f >= spec.frames || failure.get() != nil { vDone.set(true); box.vIn.markAsFinished(); group.leave(); return }
                var out: CVPixelBuffer?
                guard let pool = box.adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else {
                    failure.set("pool"); continue
                }
                do { try spec.draw(frame: f, into: pb) } catch { failure.set("\(error)"); continue }
                if !box.adaptor.append(pb, withPresentationTime: Spec4K.frameTime(f)) { failure.set("append video \(f)"); continue }
                vNext.set(f + 1)
            }
        }
        box.aIn.requestMediaDataWhenReady(on: aq) {
            if aDone.get() { return }
            while box.aIn.isReadyForMoreMediaData {
                let s = aNext.get()
                if s >= mono.count || failure.get() != nil { aDone.set(true); box.aIn.markAsFinished(); group.leave(); return }
                let n = min(1024, mono.count - s)
                do {
                    let sb = try pcmSampleBuffer(Array(mono[s..<(s + n)]), startSample: s)
                    if !box.aIn.append(sb) { failure.set("append audio \(s)"); continue }
                } catch { failure.set("\(error)"); continue }
                aNext.set(s + n)
            }
        }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { k.resume() } }
        if let f = failure.get() { writer.cancelWriting(); throw E1Error.writer("fixture \(spec.key): \(f)") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw E1Error.writer("fixture \(spec.key) status \(writer.status.rawValue) \(writer.error?.localizedDescription ?? "")") }
    }

    /// 모노 float 샘플 → 스테레오(L=R) float32 인터리브 CMSampleBuffer
    static func pcmSampleBuffer(_ mono: [Float], startSample: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else {
            throw E1Error.writer("audio format")
        }
        var stereo = [Float](repeating: 0, count: mono.count * 2)
        for i in 0..<mono.count { stereo[2 * i] = mono[i]; stereo[2 * i + 1] = mono[i] }
        let bytes = stereo.count * 4
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &bb) == noErr, let bb else { throw E1Error.writer("block buffer") }
        let st = stereo.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) }
        guard st == noErr else { throw E1Error.writer("block copy \(st)") }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: fmt,
                                                                   sampleCount: mono.count,
                                                                   presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: 48_000),
                                                                   packetDescriptions: nil, sampleBufferOut: &sb) == noErr, let sb else {
            throw E1Error.writer("audio sample buffer")
        }
        return sb
    }
}
