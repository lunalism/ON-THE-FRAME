import AVFoundation
import CoreVideo
import Foundation
@testable import OnTheFrameEngine

/// E1(2026-11-23) 시험 재료: 알려진 파일 시각에 1 kHz 소리가 시작하는 생성 파일과, 재생·분석 두 경로에서 그 시작 위치를 찾는 도구.
/// 생성 파일만 쓰고 시험마다 새 임시 폴더에 쓴다.
enum SourceTimeFixture {
    static let rate = 48_000
    /// 소리 시작(파일 시각 1.0 s)과 길이(0.2 s), 진폭
    static let burstStart = 48_000, burstLength = 9_600, amplitude = 0.6
    struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    /// 파일 표본 i의 값
    static func value(_ i: Int) -> Double {
        guard (burstStart ..< burstStart + burstLength).contains(i) else { return 0 }
        return amplitude * sin(2 * Double.pi * 1_000 * Double(i - burstStart) / Double(rate))
    }
    /// 16비트 모노 표본 [start, start + count)를 파일 시각 그대로의 표시 시각으로 담은 버퍼
    static func buffer(start: Int, count: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1,
            mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        let data = (0..<count).map { Int16((value(start + $0) * 32_767).rounded()) }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block)
        guard let fd, let block else { throw Failure("audio buffer") }
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)), packetDescriptions: nil, sampleBufferOut: &sb)
        guard let sb else { throw Failure("sample buffer") }
        return sb
    }
    static let lpcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    static let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]

    /// 소리는 파일 시각 [audioStart, 2 s), 영상(있으면)은 [0, 2 s). 쓰기 세션은 0에서 시작하므로 늦게 시작하는 소리 앞은 빈 구간이 된다.
    static func write(_ url: URL, type: AVFileType, audio settings: [String: Any], audioStart: Int, video: Bool) async throws {
        let w = try AVAssetWriter(outputURL: url, fileType: type)
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        w.add(aIn)
        let frames = video ? try VideoFrames(w) : nil
        guard w.startWriting() else { throw Failure("writer start: \(String(describing: w.error))") }
        w.startSession(atSourceTime: .zero)
        var s = audioStart
        while s < 2 * rate {
            let n = min(4_800, 2 * rate - s)
            while !aIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard aIn.append(try buffer(start: s, count: n)) else { throw Failure("audio append: \(String(describing: w.error))") }
            s += n
        }
        aIn.markAsFinished()
        try await frames?.append(count: 60)
        await w.finishWriting()
        guard w.status == .completed else { throw Failure("writer finish: \(String(describing: w.error))") }
    }
    /// 320×180 H.264, 30 fps 단색 프레임
    final class VideoFrames {
        let input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
        init(_ w: AVAssetWriter) throws {
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
            guard w.canAdd(input) else { throw Failure("video input") }
            w.add(input)
        }
        func append(count: Int) async throws {
            for f in 0..<count {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                var pb: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { throw Failure("pixel buffer") }
                CVPixelBufferLockBaseAddress(pb, [])
                memset(CVPixelBufferGetBaseAddress(pb), 64, CVPixelBufferGetDataSize(pb))
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30)) else { throw Failure("video append") }
            }
            input.markAsFinished()
        }
    }

    /// 소리가 시작하는 표본 번호들(조용하다가 |값| > 0.25가 되는 곳. 한 번 찾으면 0.3 s 동안은 다시 세지 않는다)
    static func onsets(_ x: [Float], offset: Int = 0) -> [Int] {
        var out: [Int] = [], quietUntil = 0
        for (i, v) in x.enumerated() where i >= quietUntil && abs(v) > 0.25 { out.append(offset + i); quietUntil = i + 14_400 }
        return out
    }
    /// 재생이 내는 소리: 계획한 composition의 모든 소리 트랙을 같은 오디오 믹스로 읽은 왼쪽 채널(48 kHz)
    static func playback(_ p: PlannedComposition) async throws -> [Float] {
        let r = try AVAssetReader(asset: p.composition)
        let o = AVAssetReaderAudioMixOutput(audioTracks: try await p.composition.loadTracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        o.audioMix = p.audioMix
        r.add(o)
        guard r.startReading() else { throw Failure("playback reader: \(String(describing: r.error))") }
        var left: [Float] = []
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            for i in stride(from: 0, to: n - 1, by: 2) { left.append(chunk[i]) }
        }
        guard r.status != .failed else { throw Failure("playback read: \(String(describing: r.error))") }
        return left
    }
    /// 분석이 읽는 소리: 조각마다 Spectrum과 같은 표본 대응(sourceSpans)으로 원본을 읽어, 타임라인 표본 번호로 본 시작 위치
    static func analysisOnsets(_ pieces: [SpectrumSourcePiece], source: SpectrumFileSource, timelineFrames: Int) async throws -> [Int] {
        let window = 0 ..< SpectrumFrameMap.sample(atFrame: timelineFrames, fps: 30, rate: rate)
        var out: [Int] = []
        for span in SpectrumAnalysis.sourceSpans(pieces, window: window, fps: 30, rate: rate) {
            let r = span.sourceStart ..< span.sourceStart + span.timeline.count
            let pcm = try await source.decodeRange(r.lowerBound, r.upperBound, keep: r)
            out += onsets(pcm[0], offset: span.timeline.lowerBound)
        }
        return out.sorted()
    }
}
