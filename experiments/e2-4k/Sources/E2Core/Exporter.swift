import AVFoundation
import CoreMedia
import CoreVideo
import E1Core
import Foundation
import IOSurface

/// E2 내보내기 보고(기록용)
public struct E2ExportReport: Codable, Sendable {
    public var outcome = "idle"
    public var error: String?
    public var errorKind: String?
    public var promoted = false
    public var tempDirCreated = false
    public var tempDirRemoved = false
    public var videoFramesAppended = 0
    public var audioFramesAppended = 0
    public var wallSeconds = 0.0
    public var encodeSeconds = 0.0
    public var finishWritingMs = 0.0
    public var startFootprintMiB = 0.0
    public var peakFootprintMiB = 0.0
    public var distinctPixelBuffers = 0
    public var outputBytes: UInt64 = 0
    public var tAckMs: Double?
    public var tWorkersStoppedMs: Double?
    public var tStopMs: Double?
    public var tCleanupMs: Double?
    public var framesAtStop: Int?
    public init() {}
}

/// 안전성(@unchecked Sendable, 큐 한정): 비디오 멤버는 비디오 큐에서만, 오디오 멤버는 오디오 큐에서만 쓴다(E1 QueueConfined와 같은 규칙).
struct E2Confined: @unchecked Sendable {
    let vIn: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let vOut: AVAssetReaderVideoCompositionOutput
    let aIn: AVAssetWriterInput
    let mixOut: AVAssetReaderAudioMixOutput
}

/// 공급 블록 사이 공유 카운터. 안전성: 가변 상태는 lock 안에서만 접근한다.
final class E2Counters: @unchecked Sendable {
    private let lock = NSLock()
    var frames = 0, audioFrames = 0, peak: UInt64 = 0
    var vDone = false, aDone = false
    var stoppedAt: UInt64?
    var surfaces = Set<UInt32>()
    func with<T>(_ f: (E2Counters) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(self) }
}

/// 합성기 기반 내보내기(프리뷰와 같은 composition·videoComposition을 AVAssetReaderVideoCompositionOutput으로 읽음).
/// 출력 보호·임시 출력·배타적 승격·취소·실패 처리는 E1과 같은 규칙(OutputGuard, ExportControl)을 재사용한다.
public enum E2Exporter {
    public static func run(bundle: E2Bundle, destination: URL, protectedSources: [URL], frames total: Int,
                           control: ExportControl, experimentsDir: URL, plannedBytes: UInt64 = 128 << 20) async -> E2ExportReport {
        var rep = E2ExportReport()
        let t0 = Clock.now()
        rep.startFootprintMiB = Double(Memory.physFootprint()) / 1_048_576
        var temp: OwnedTempDir?
        control.enter(.preparing)
        do {
            try OutputGuard.preflight(destination: destination, sources: protectedSources)
            try OwnedBudget.check(experimentsDir: experimentsDir, adding: plannedBytes)
            if control.isCancelling { throw Cancel() }
            temp = try OutputGuard.makeTempDir(for: destination)
            rep.tempDirCreated = true
            let tempFile = temp!.url.appendingPathComponent("output.mp4")
            control.enter(.running)
            let e0 = Clock.now()
            try await encode(bundle: bundle, tempFile: tempFile, total: total, control: control, rep: &rep)
            rep.encodeSeconds = Double(Clock.now() - e0) / 1e9
            if control.isCancelling { throw Cancel() }
            try await verify(tempFile, frames: total)
            if control.isCancelling { throw Cancel() }
            try OutputGuard.promote(tempFile, to: destination)
            rep.promoted = true
            rep.tempDirRemoved = OutputGuard.cleanup(temp!)
            rep.outputBytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? UInt64) ?? 0
            rep.outcome = "completed"
            control.finish(.completed)
        } catch {
            let cancelled = error is Cancel || control.isCancelling
            let c0 = Clock.now()
            if let t = temp { rep.tempDirRemoved = OutputGuard.cleanup(t) }
            let c1 = Clock.now()
            if cancelled {
                rep.outcome = "cancelled"; control.finish(.cancelled)
                if rep.tStopMs != nil { rep.tCleanupMs = Clock.ms(c0, c1) }
            } else {
                let e = control.failure ?? error
                rep.outcome = "failed"; rep.error = "\(e)"; rep.errorKind = (e as? E1Error)?.kind ?? String(describing: type(of: e))
                control.finish(.failed)
            }
        }
        rep.peakFootprintMiB = max(rep.peakFootprintMiB, Double(Memory.physFootprint()) / 1_048_576)
        rep.wallSeconds = Double(Clock.now() - t0) / 1e9
        return rep
    }

    struct Cancel: Error {}

    static func encode(bundle: E2Bundle, tempFile: URL, total: Int, control: ExportControl, rep: inout E2ExportReport) async throws {
        let comp = bundle.composition
        let reader = try AVAssetReader(asset: comp)
        reader.timeRange = CMTimeRange(start: .zero, duration: Spec4K.frameTime(total))
        let mixOut = AVAssetReaderAudioMixOutput(audioTracks: comp.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        mixOut.alwaysCopiesSampleData = false
        reader.add(mixOut)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: comp.tracks(withMediaType: .video),
                                                       videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = bundle.videoComposition
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)

        let writer = try AVAssetWriter(outputURL: tempFile, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Spec4K.width, AVVideoHeightKey: Spec4K.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Spec4K.exportVideoBitRate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30, AVVideoExpectedSourceFrameRateKey: 30,
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
        ])
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: Spec4K.aacBitRate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        aIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn), writer.canAdd(aIn) else { throw E1Error.writer("cannot add inputs") }
        writer.add(vIn); writer.add(aIn)
        guard writer.startWriting() else { throw E1Error.writer(writer.error?.localizedDescription ?? "startWriting failed") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw E1Error.reader(reader.error?.localizedDescription ?? "startReading failed") }

        let c = E2Confined(vIn: vIn, adaptor: adaptor, vOut: vOut, aIn: aIn, mixOut: mixOut)
        let p = E2Counters()
        let group = DispatchGroup()
        group.enter(); group.enter()
        @Sendable func endVideo() { c.vIn.markAsFinished(); p.with { $0.vDone = true; if $0.aDone { $0.stoppedAt = Clock.now() } }; group.leave() }
        @Sendable func endAudio() { c.aIn.markAsFinished(); p.with { $0.aDone = true; if $0.vDone { $0.stoppedAt = Clock.now() } }; group.leave() }
        c.vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "e2.export.video")) {
            if p.with({ $0.vDone }) { return }
            while c.vIn.isReadyForMoreMediaData {
                if control.shouldStop { endVideo(); return }
                let n = p.with { $0.frames }
                if let f = control.injectFailureAtFrame, n == f { control.fail(E1Error.injectedFailure(f)); endVideo(); return }
                guard let sb = c.vOut.copyNextSampleBuffer() else { endVideo(); return }
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { control.fail(E1Error.reader("no image buffer")); endVideo(); return }
                if let s = CVPixelBufferGetIOSurface(pb) { let id = IOSurfaceGetID(s.takeUnretainedValue()); p.with { _ = $0.surfaces.insert(id) } }
                if !c.adaptor.append(pb, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sb)) {
                    control.fail(E1Error.writer("append video failed at frame \(n)")); endVideo(); return
                }
                let fp = Memory.physFootprint()
                p.with { $0.frames += 1; $0.peak = max($0.peak, fp) }
                control.onVideoAppended?(n + 1, total)
            }
        }
        c.aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "e2.export.audio")) {
            if p.with({ $0.aDone }) { return }
            while c.aIn.isReadyForMoreMediaData {
                if control.shouldStop { endAudio(); return }
                guard let sb = c.mixOut.copyNextSampleBuffer() else { endAudio(); return }
                let n = CMSampleBufferGetNumSamples(sb)
                if !c.aIn.append(sb) { control.fail(E1Error.writer("append audio failed")); endAudio(); return }
                p.with { $0.audioFrames += n }
            }
        }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { k.resume() } }
        p.with { s in
            rep.videoFramesAppended = s.frames; rep.audioFramesAppended = s.audioFrames
            rep.peakFootprintMiB = Double(s.peak) / 1_048_576; rep.distinctPixelBuffers = s.surfaces.count
        }
        let stoppedAt = p.with { $0.stoppedAt }
        if control.shouldStop {
            reader.cancelReading()
            writer.cancelWriting()
            let stopped = Clock.now()
            if control.isCancelling, let req = control.cancelRequestedAt {
                rep.tAckMs = control.cancelAckAt.map { Clock.ms(req, $0) }
                rep.tWorkersStoppedMs = stoppedAt.map { Clock.ms(req, $0) }
                rep.tStopMs = Clock.ms(req, stopped)
                rep.framesAtStop = rep.videoFramesAppended
                throw Cancel()
            }
            throw control.failure ?? E1Error.writer("stopped")
        }
        if reader.status == .failed { throw E1Error.reader(reader.error?.localizedDescription ?? "reader failed") }
        let f0 = Clock.now()
        await writer.finishWriting()
        rep.finishWritingMs = Double(Clock.now() - f0) / 1e6
        guard writer.status == .completed else { throw E1Error.writer("finishWriting \(writer.status.rawValue) \(writer.error?.localizedDescription ?? "-")") }
    }

    /// 승격 전 검증: 트랙 수와 비디오 길이
    static func verify(_ url: URL, frames: Int) async throws {
        let a = AVURLAsset(url: url)
        let v = try await a.loadTracks(withMediaType: .video), au = try await a.loadTracks(withMediaType: .audio)
        guard v.count == 1, au.count == 1 else { throw E1Error.verificationFailed("tracks v=\(v.count) a=\(au.count)") }
        let r = try await v[0].load(.timeRange)
        guard r.duration == Spec4K.frameTime(frames) else { throw E1Error.verificationFailed("video duration \(r.duration.seconds)") }
    }
}
