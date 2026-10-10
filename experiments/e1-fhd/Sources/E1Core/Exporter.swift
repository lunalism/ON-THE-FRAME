import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface

public enum ExportAudioCodec: String, Codable, Sendable { case aac, lpcm }

/// 비디오 프레임 공급 경로.
/// - directWriter (경로 A, E1-a): 비디오 공급 블록이 FrameRenderer를 직접 호출해 writer 풀 버퍼에 그린다.
/// - sharedCompositor (경로 B, E1-b): 프리뷰와 같은 AVVideoComposition + E1Compositor를
///   AVAssetReaderVideoCompositionOutput으로 돌려 나온 프레임을 writer에 넣는다.
public enum VideoPath: String, Codable, Sendable { case directWriter, sharedCompositor }

public enum ExportState: String, Codable, Sendable { case idle, preparing, running, cancelling, cancelled, failed, completed }

/// 내보내기 제어. cancel()은 어느 스레드에서든 호출할 수 있다.
/// 안전성(@unchecked Sendable의 근거): 가변 상태(_state, _failure, 취소 시각)는 모두 `lock` 안에서만
/// 접근한다. 테스트 훅과 실패 주입 값은 생성 시 정해지는 let이며 훅은 @Sendable이다.
public final class ExportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: ExportState = .idle
    private var _failure: Error?
    private var _cancelRequestedAt: UInt64?
    private var _cancelAckAt: UInt64?
    /// 테스트용: 이 프레임을 공급하기 직전에 실패를 주입한다.
    public let injectFailureAtFrame: Int?
    /// 테스트용 훅: 비디오 프레임을 append한 직후 비디오 큐에서 호출된다(frames appended, expected total).
    public let onVideoAppended: (@Sendable (Int, Int) -> Void)?

    public init(injectFailureAtFrame: Int? = nil, onVideoAppended: (@Sendable (Int, Int) -> Void)? = nil) {
        self.injectFailureAtFrame = injectFailureAtFrame
        self.onVideoAppended = onVideoAppended
    }

    public var state: ExportState { lock.lock(); defer { lock.unlock() }; return _state }
    public var cancelRequestedAt: UInt64? { lock.lock(); defer { lock.unlock() }; return _cancelRequestedAt }
    public var cancelAckAt: UInt64? { lock.lock(); defer { lock.unlock() }; return _cancelAckAt }

    // 아래 상태 전환·실패 기록 메서드는 E2 내보내기(experiments/e2-4k)가 같은 취소·실패 규칙을 쓰도록 public이다.
    /// 진행 상태로 전환. 이미 취소 요청이 들어왔으면 cancelling을 유지한다.
    public func enter(_ s: ExportState) { lock.lock(); if _state != .cancelling { _state = s }; lock.unlock() }
    public func finish(_ s: ExportState) { lock.lock(); _state = s; lock.unlock() }

    /// 취소 요청(준비·실행 중 모두 유효). 확인(acknowledgement)은 상태가 cancelling으로 바뀐 시점이다.
    public func cancel() {
        let t = Clock.now()
        lock.lock()
        if _state == .idle || _state == .preparing || _state == .running {
            _cancelRequestedAt = t
            _state = .cancelling
            _cancelAckAt = Clock.now()
        }
        lock.unlock()
    }

    public func fail(_ e: Error) { lock.lock(); if _failure == nil { _failure = e }; lock.unlock() }
    public var failure: Error? { lock.lock(); defer { lock.unlock() }; return _failure }
    public var isCancelling: Bool { lock.lock(); defer { lock.unlock() }; return _state == .cancelling }
    public var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return _state == .cancelling || _failure != nil }
}

public struct ExportJob: Sendable {
    public let state: TimelineState
    public let destination: URL
    public let codec: ExportAudioCodec
    public let videoPath: VideoPath
    /// 경로 B의 비디오 운반 트랙(CompositionBuilder 참고). 원본처럼 보호 대상에 포함한다.
    public let videoCarrier: URL?
    public init(state: TimelineState, destination: URL, codec: ExportAudioCodec, videoPath: VideoPath = .directWriter, videoCarrier: URL? = nil) {
        self.state = state; self.destination = destination; self.codec = codec; self.videoPath = videoPath; self.videoCarrier = videoCarrier
    }
    public var fileType: AVFileType { codec == .aac ? .mp4 : .mov }
}

public struct ExportReport: Codable, Sendable {
    public var videoPath: VideoPath = .directWriter
    public var outcome: ExportState = .idle
    public var error: String?
    public var errorKind: String?
    public var destination: String = ""
    public var promoted = false
    public var tempDirCreated = false
    public var tempDirRemoved = false
    public var videoFramesAppended = 0
    public var audioFramesAppended = 0
    public var videoReadyCallbacks = 0
    public var audioReadyCallbacks = 0
    public var maxAudioBufferFrames = 0
    /// 시작부터 finishWriting(비동기) 완료, 검증, 승격, 임시 정리까지
    public var wallSeconds = 0.0
    /// finishWriting(비동기) 완료까지 걸린 시간
    public var finishWritingMs = 0.0
    public var peakFootprintBytes: UInt64 = 0
    public var startFootprintBytes: UInt64 = 0
    /// 서로 다른 픽셀 버퍼(IOSurface) 수 = 실제로 순환한 프레임 버퍼 수
    public var distinctPoolBuffers = 0
    public var outputBytes: UInt64 = 0
    public var progressMonotonic = true
    public var finalProgress = 0.0
    // 취소 시간 (ms)
    public var tAckMs: Double?
    public var tWorkersStoppedMs: Double?   // 취소 요청 → 두 입력 공급 블록이 모두 끝남
    public var tStopMs: Double?             // 취소 요청 → reader/writer 취소 완료(cancelWriting 반환)
    public var tCleanupMs: Double?          // 작업 종료 → 임시 디렉터리 삭제 확인
    public var framesAtStop: Int?
    public var framesAfterStopCheck: Int?
}

/// 공급 블록 사이에서 공유하는 카운터.
/// 안전성(@unchecked Sendable의 근거): 모든 가변 저장 상태는 `lock` 안에서만 접근한다(`withLock`).
final class PipelineCounters: @unchecked Sendable {
    private let lock = NSLock()
    var frames = 0, audioFrames = 0, vCalls = 0, aCalls = 0, maxAudioBuf = 0
    var peak: UInt64 = 0, lastProgress = 0.0, monotonic = true
    var vDone = false, aDone = false
    var workersStoppedAt: UInt64?
    var surfaces = Set<UInt32>()
    func withLock<T>(_ f: (PipelineCounters) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(self) }
}

/// 공급 블록에 넘기는 AVFoundation 객체 묶음.
/// 안전성(@unchecked Sendable의 근거, 큐 한정): 비디오 멤버(vIn, adaptor, vOut)는 비디오 직렬 큐의 블록에서만,
/// 오디오 멤버(aIn, mixOut)는 오디오 직렬 큐의 블록에서만 사용한다. 메인 작업은 블록 시작 전과
/// 두 블록이 모두 끝난 뒤(DispatchGroup 완료 이후)에만 reader·writer를 다룬다. 블록 안에서는 reader·writer를
/// 건드리지 않는다(상태·오류 확인은 합류 뒤에 한다).
struct QueueConfined: @unchecked Sendable {
    let vIn: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let vOut: AVAssetReaderVideoCompositionOutput?
    let aIn: AVAssetWriterInput
    let mixOut: AVAssetReaderAudioMixOutput
}

/// 헤드리스 내보내기: 비디오(경로 A 또는 B) + 오디오 믹스(선택 소스 + 무관 트랙) → 임시 파일 → 검증 → 승격.
/// 비디오는 writer 입력이 준비됐을 때만 1프레임씩 공급한다(back-pressure).
public enum Exporter {
    public static func run(_ job: ExportJob, renderer: FrameRenderer, control: ExportControl) async -> ExportReport {
        var rep = ExportReport()
        rep.videoPath = job.videoPath
        rep.destination = job.destination.path
        let t0 = Clock.now()
        var temp: OwnedTempDir?
        rep.startFootprintBytes = Memory.physFootprint()
        control.enter(.preparing)

        var sources = [job.state.selected.source.url]
        if let u = job.state.unrelated { sources.append(u.source.url) }
        if let c = job.videoCarrier { sources.append(c) }

        do {
            try OutputGuard.preflight(destination: job.destination, sources: sources)
            let log = CompositorLog(hashOutputs: false)
            let bundle = try await CompositionBuilder.build(job.state, renderer: job.videoPath == .sharedCompositor ? renderer : nil,
                                                            log: job.videoPath == .sharedCompositor ? log : nil,
                                                            videoCarrier: job.videoPath == .sharedCompositor ? job.videoCarrier : nil)
            if control.isCancelling { throw CancelSignal() }
            temp = try OutputGuard.makeTempDir(for: job.destination)
            rep.tempDirCreated = true
            let tempFile = temp!.url.appendingPathComponent("output." + (job.codec == .aac ? "mp4" : "mov"))
            control.enter(.running)
            try await encode(job: job, bundle: bundle, tempFile: tempFile, renderer: renderer, control: control, rep: &rep)

            if control.isCancelling { throw CancelSignal() }
            try await verifyTemp(tempFile)
            if control.isCancelling { throw CancelSignal() }
            try OutputGuard.promote(tempFile, to: job.destination)
            rep.promoted = true
            rep.tempDirRemoved = OutputGuard.cleanup(temp!)
            rep.outputBytes = (try? FileManager.default.attributesOfItem(atPath: job.destination.path)[.size] as? UInt64) ?? 0
            rep.outcome = .completed
            control.finish(.completed)
        } catch {
            let cancelled = error is CancelSignal || control.isCancelling
            let cleanStart = Clock.now()
            if let t = temp { rep.tempDirRemoved = OutputGuard.cleanup(t) }
            let cleanEnd = Clock.now()
            if cancelled {
                rep.outcome = .cancelled
                control.finish(.cancelled)
                if rep.tStopMs != nil { rep.tCleanupMs = Clock.ms(cleanStart, cleanEnd) }
            } else {
                rep.outcome = .failed
                let e = control.failure ?? error
                rep.error = "\(e)"
                rep.errorKind = (e as? E1Error)?.kind ?? String(describing: type(of: e))
                control.finish(.failed)
            }
        }
        rep.peakFootprintBytes = max(rep.peakFootprintBytes, Memory.physFootprint())
        rep.wallSeconds = Double(Clock.now() - t0) / 1e9
        return rep
    }

    struct CancelSignal: Error {}

    /// E1-a 호환: 오디오만 있는 composition
    public static func buildAudioComposition(_ state: TimelineState) async throws -> AVComposition {
        try await CompositionBuilder.build(state, renderer: nil, log: nil, videoCarrier: nil).composition
    }

    static func videoSettings() -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Spec.width, AVVideoHeightKey: Spec.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Spec.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    static func audioSettings(_ codec: ExportAudioCodec) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        switch codec {
        case .aac:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Spec.sampleRate, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: Spec.aacBitRate, AVChannelLayoutKey: layoutData]
        case .lpcm:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Spec.sampleRate, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false, AVChannelLayoutKey: layoutData]
        }
    }

    static func readerAudioSettings() -> [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        AVSampleRateKey: Spec.sampleRate, AVNumberOfChannelsKey: 2,
    ] }

    static func encode(job: ExportJob, bundle: CompositionBundle, tempFile: URL, renderer: FrameRenderer,
                       control: ExportControl, rep: inout ExportReport) async throws {
        let composition = bundle.composition
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: job.state.duration)
        let mixOut = AVAssetReaderAudioMixOutput(audioTracks: composition.tracks(withMediaType: .audio), audioSettings: readerAudioSettings())
        mixOut.alwaysCopiesSampleData = false
        reader.add(mixOut)
        var vOut: AVAssetReaderVideoCompositionOutput?
        if job.videoPath == .sharedCompositor {
            guard let vc = bundle.videoComposition else { throw E1Error.render("missing video composition") }
            let o = AVAssetReaderVideoCompositionOutput(videoTracks: composition.tracks(withMediaType: .video), videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            o.videoComposition = vc
            o.alwaysCopiesSampleData = false
            reader.add(o)
            vOut = o
        }

        let writer = try AVAssetWriter(outputURL: tempFile, fileType: job.fileType)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Spec.width, kCVPixelBufferHeightKey as String: Spec.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        ])
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings(job.codec))
        aIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn), writer.canAdd(aIn) else { throw E1Error.writer("cannot add inputs") }
        writer.add(vIn); writer.add(aIn)

        guard writer.startWriting() else { throw E1Error.writer(writer.error?.localizedDescription ?? "startWriting failed") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw E1Error.reader(reader.error?.localizedDescription ?? "startReading failed")
        }

        let total = Spec.frameCount
        let path = job.videoPath
        let c = QueueConfined(vIn: vIn, adaptor: adaptor, vOut: vOut, aIn: aIn, mixOut: mixOut)
        let p = PipelineCounters()
        let vq = DispatchQueue(label: "e1.video"), aq = DispatchQueue(label: "e1.audio")
        let group = DispatchGroup()
        group.enter(); group.enter()
        // 정상 종료든 중단이든 자기 입력을 finished로 표시한다. 중단 시에도 이렇게 해야
        // writer의 인터리빙 대기 때문에 다른 입력의 공급 블록이 다시 호출되지 않는 일을 막는다.
        @Sendable func endVideo() {
            c.vIn.markAsFinished()
            p.withLock { $0.vDone = true; if $0.aDone { $0.workersStoppedAt = Clock.now() } }
            group.leave()
        }
        @Sendable func endAudio() {
            c.aIn.markAsFinished()
            p.withLock { $0.aDone = true; if $0.vDone { $0.workersStoppedAt = Clock.now() } }
            group.leave()
        }

        c.vIn.requestMediaDataWhenReady(on: vq) {
            if p.withLock({ $0.vDone }) { return }
            p.withLock { $0.vCalls += 1 }
            while c.vIn.isReadyForMoreMediaData {
                if control.shouldStop { endVideo(); return }
                let n = p.withLock { $0.frames }
                if let f = control.injectFailureAtFrame, n == f { control.fail(E1Error.injectedFailure(f)); endVideo(); return }
                let pb: CVPixelBuffer
                let pts: CMTime
                switch path {
                case .directWriter:
                    if n >= total { endVideo(); return }
                    guard let pool = c.adaptor.pixelBufferPool else { control.fail(E1Error.writer("no pixel buffer pool")); endVideo(); return }
                    var out: CVPixelBuffer?
                    let st = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                    guard st == kCVReturnSuccess, let b = out else { control.fail(E1Error.writer("pool buffer \(st)")); endVideo(); return }
                    do { try renderer.render(frame: n, into: b) } catch { control.fail(error); endVideo(); return }
                    pb = b; pts = Spec.frameTime(n)
                case .sharedCompositor:
                    // nil이면 출력이 끝났거나 reader가 실패한 것. 구분은 합류 뒤 reader.status로 한다.
                    guard let sb = c.vOut!.copyNextSampleBuffer() else { endVideo(); return }
                    guard let b = CMSampleBufferGetImageBuffer(sb) else { control.fail(E1Error.reader("no image buffer")); endVideo(); return }
                    pb = b; pts = CMSampleBufferGetPresentationTimeStamp(sb)
                }
                if let sfc = CVPixelBufferGetIOSurface(pb) {
                    let id = IOSurfaceGetID(sfc.takeUnretainedValue())
                    p.withLock { _ = $0.surfaces.insert(id) }
                }
                if !c.adaptor.append(pb, withPresentationTime: pts) {
                    control.fail(E1Error.writer("append video failed at frame \(n)")); endVideo(); return
                }
                let fp = Memory.physFootprint()
                p.withLock {
                    $0.frames += 1
                    let pr = Double($0.frames) / Double(total)
                    if pr < $0.lastProgress { $0.monotonic = false }
                    $0.lastProgress = pr
                    $0.peak = max($0.peak, fp)
                }
                control.onVideoAppended?(n + 1, total)
            }
        }
        c.aIn.requestMediaDataWhenReady(on: aq) {
            if p.withLock({ $0.aDone }) { return }
            p.withLock { $0.aCalls += 1 }
            while c.aIn.isReadyForMoreMediaData {
                if control.shouldStop { endAudio(); return }
                guard let sb = c.mixOut.copyNextSampleBuffer() else { endAudio(); return }
                let frames = CMSampleBufferGetNumSamples(sb)
                if !c.aIn.append(sb) { control.fail(E1Error.writer("append audio failed")); endAudio(); return }
                p.withLock { $0.audioFrames += frames; $0.maxAudioBuf = max($0.maxAudioBuf, frames) }
            }
        }

        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { k.resume() } }

        // 여기부터 두 공급 블록은 끝났다(group 완료가 happens-before를 보장). reader·writer를 다시 다룰 수 있다.
        p.withLock { s in
            rep.videoFramesAppended = s.frames
            rep.audioFramesAppended = s.audioFrames
            rep.videoReadyCallbacks = s.vCalls
            rep.audioReadyCallbacks = s.aCalls
            rep.maxAudioBufferFrames = s.maxAudioBuf
            rep.peakFootprintBytes = s.peak
            rep.progressMonotonic = s.monotonic
            rep.finalProgress = s.lastProgress
            rep.distinctPoolBuffers = s.surfaces.count
        }
        let workersStoppedAt = p.withLock { $0.workersStoppedAt }

        if control.shouldStop {
            reader.cancelReading()
            writer.cancelWriting()   // 문서: 쓰기 중 만든 출력 파일을 삭제하고, 끝날 때까지 블록한다
            let stopped = Clock.now()
            if control.isCancelling, let req = control.cancelRequestedAt {
                rep.tAckMs = control.cancelAckAt.map { Clock.ms(req, $0) }
                rep.tWorkersStoppedMs = workersStoppedAt.map { Clock.ms(req, $0) }
                rep.tStopMs = Clock.ms(req, stopped)
                rep.framesAtStop = rep.videoFramesAppended
                rep.framesAfterStopCheck = p.withLock { $0.frames }
                throw CancelSignal()
            }
            let f = control.failure.map { "\($0)" } ?? "stopped"
            if let we = writer.error { throw E1Error.writer("\(f); writer.error=\(we.localizedDescription)") }
            throw control.failure ?? E1Error.writer(f)
        }
        if reader.status == .failed { throw E1Error.reader(reader.error?.localizedDescription ?? "reader failed") }
        let fw0 = Clock.now()
        await writer.finishWriting()
        rep.finishWritingMs = Double(Clock.now() - fw0) / 1e6
        rep.peakFootprintBytes = max(rep.peakFootprintBytes, Memory.physFootprint())
        guard writer.status == .completed else {
            throw E1Error.writer("finishWriting status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "-")")
        }
    }

    /// 승격 전 검증: 다시 열어 트랙과 길이를 확인한다.
    static func verifyTemp(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let v = try await asset.loadTracks(withMediaType: .video)
        let a = try await asset.loadTracks(withMediaType: .audio)
        guard v.count == 1, a.count == 1 else { throw E1Error.verificationFailed("tracks v=\(v.count) a=\(a.count)") }
        let vr = try await v[0].load(.timeRange)
        guard vr.duration == Spec.duration else {
            throw E1Error.verificationFailed("video duration \(vr.duration.seconds)")
        }
    }
}
