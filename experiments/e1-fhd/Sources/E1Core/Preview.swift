import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MediaToolbox
import QuartzCore

// MARK: - 재생 중 오디오 관찰 (MTAudioProcessingTap)

/// 선택 소스 트랙에 붙여 재생 파이프라인이 처리하는 샘플에서 클릭 onset을 기록한다.
/// 기록 시각은 탭이 받은 asset(=composition) 시간 범위로 계산한다. 이것은 "재생 파이프라인이 그 시각의
/// 샘플을 처리했다"는 증거이며, 스피커에서 실제로 들린 시각(출력 지연 포함)은 아니다.
/// 안전성(@unchecked Sendable의 근거): 가변 상태는 모두 `lock` 안에서만 접근한다. 탭 콜백은 오디오 처리
/// 스레드에서 오고, 읽기는 다른 스레드에서 한다.
public final class AudioTapRecorder: @unchecked Sendable {
    public struct Onset: Sendable, Codable { public let itemSeconds: Double; public let hostSeconds: Double }
    public struct Snapshot: Sendable {
        public let onsets: [Onset]
        public let processCalls: Int
        public let frames: Int
        public let discontinuities: Int
        public let format: String
    }
    private let lock = NSLock()
    private var onsets: [Onset] = []
    private var processCalls = 0
    private var frames = 0
    private var discontinuities = 0
    private var format = "-"
    private var floatNonInterleaved = false
    private var floatInterleaved = false
    private var prev: Float = 0
    private var nextStart: Int64 = -1
    private var lastOnsetSample: Int64 = -1_000_000

    public init() {}

    public func reset() {
        lock.lock(); onsets = []; processCalls = 0; frames = 0; discontinuities = 0; nextStart = -1; lastOnsetSample = -1_000_000; lock.unlock()
    }
    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(onsets: onsets, processCalls: processCalls, frames: frames, discontinuities: discontinuities, format: format)
    }

    fileprivate func prepare(_ asbd: AudioStreamBasicDescription) {
        lock.lock(); defer { lock.unlock() }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInt = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        floatNonInterleaved = isFloat && nonInt && asbd.mBitsPerChannel == 32
        floatInterleaved = isFloat && !nonInt && asbd.mBitsPerChannel == 32
        format = "rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) float=\(isFloat) nonInterleaved=\(nonInt)"
    }

    fileprivate func process(_ abl: UnsafeMutablePointer<AudioBufferList>, frameCount: Int, range: CMTimeRange) {
        let host = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        processCalls += 1
        guard frameCount > 0, range.start.isNumeric, floatNonInterleaved || floatInterleaved else { return }
        let list = UnsafeMutableAudioBufferListPointer(abl)
        guard let data = list.first?.mData else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let stride = floatInterleaved ? Int(list.first!.mNumberChannels) : 1
        // 시작 샘플(48 kHz 기준)
        let start = Int64((Double(range.start.value) * 48_000 / Double(range.start.timescale)).rounded())
        if start != nextStart {
            discontinuities += 1
            prev = samples[0]   // 불연속(시작·탐색) 지점에서 거짓 onset을 막는다
        }
        for i in 0..<frameCount {
            let x = samples[i * stride]
            if abs(x - prev) > 0.3 {
                let s = start + Int64(i)
                if s - lastOnsetSample > 2400 {      // 50 ms 안의 연속 검출은 같은 클릭
                    onsets.append(Onset(itemSeconds: Double(s) / 48_000, hostSeconds: host))
                    lastOnsetSample = s
                }
            }
            prev = x
        }
        frames += frameCount
        nextStart = start + Int64(frameCount)
    }

    /// 탭 생성. 기록 객체는 탭이 살아 있는 동안 유지된다(passRetained, finalize에서 release).
    public func makeTap() throws -> MTAudioProcessingTap {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<AudioTapRecorder>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<AudioTapRecorder>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferList, numberFramesOut, flagsOut in
                var range = CMTimeRange()
                let st = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, &range, numberFramesOut)
                guard st == noErr else { return }
                Unmanaged<AudioTapRecorder>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(bufferList, frameCount: Int(numberFramesOut.pointee), range: range)
            })
        var tap: MTAudioProcessingTap?
        let st = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard st == noErr, let t = tap else {
            Unmanaged.passUnretained(self).release()
            throw E1Error.render("MTAudioProcessingTapCreate \(st)")
        }
        return t
    }
}

// MARK: - 프리젠테이션용으로 전달된 프레임 관찰 (AVPlayerItemVideoOutput)

/// AVPlayerItemVideoOutput에서 프레임을 받아 기록한다. 이것은 "재생 파이프라인이 표시용으로 내준 프레임"이며
/// AVPlayerLayer가 화면에 그린 결과(실제 화면 모습)는 아니다.
/// 안전성(@unchecked Sendable의 근거): `output`과 `timer`는 직렬 `queue`의 블록에서만 사용한다.
/// 기록(`records`)은 `lock` 안에서만 접근한다. reference·captionRect는 let.
public final class FrameCapture: @unchecked Sendable {
    public struct Delivered: Sendable, Codable {
        public let displayValue: Int64
        public let displayTimescale: Int32
        public let frame: Int
        public let exact: Bool
        public let hashMatchesReference: Bool
        public let code: Int
        public let captionPixels: Int
        public let barHeights: [Int]
        public let polledItemSeconds: Double
        public let hostSeconds: Double
        public let width: Int
        public let height: Int
        public let bgra: Bool
        public var displaySeconds: Double { Double(displayValue) / Double(displayTimescale) }
    }

    private let output: AVPlayerItemVideoOutput
    private let queue = DispatchQueue(label: "e1.capture")
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var records: [Delivered] = []
    /// 폴링 간격 기록(queue에서만 접근): 폴러 자체가 늦어 프레임을 못 받은 구간을 구분하기 위함
    private var lastPollHost: Double = 0
    private var pollCount = 0
    private var gaps: [PollGap] = []
    public struct PollGap: Sendable, Codable { public let fromHost: Double; public let toHost: Double; public var ms: Double { (toHost - fromHost) * 1000 } }
    public let reference: [String]
    public let captionRect: CGRect

    public init(output: AVPlayerItemVideoOutput, reference: [String], captionRect: CGRect) {
        self.output = output; self.reference = reference; self.captionRect = captionRect
    }

    public func start(intervalMs: Int = 4) {
        queue.sync {
            lastPollHost = 0   // 정지~시작 사이는 간격으로 세지 않는다
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(intervalMs), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.pollNow() }
            t.resume()
            timer = t
        }
    }
    public func stop() { queue.sync { timer?.cancel(); timer = nil } }
    public func reset() {
        lock.lock(); records = []; lock.unlock()
        queue.sync { lastPollHost = 0; pollCount = 0; gaps = [] }
    }
    /// 폴링 횟수와 20 ms를 넘은 폴링 간격(타이머 4 ms 기준)
    public func pollStats() -> (count: Int, gaps: [PollGap]) { queue.sync { (pollCount, gaps) } }
    public func snapshot() -> [Delivered] { lock.lock(); defer { lock.unlock() }; return records }

    /// queue에서만 호출
    private func pollNow() {
        let host = CACurrentMediaTime()
        if lastPollHost > 0, host - lastPollHost > 0.020 { gaps.append(PollGap(fromHost: lastPollHost, toHost: host)) }
        lastPollHost = host; pollCount += 1
        let it = output.itemTime(forHostTime: host)
        if output.hasNewPixelBuffer(forItemTime: it) { _ = grab(it, host: host) }
    }

    /// queue에서만 호출
    private func grab(_ it: CMTime, host: Double) -> Delivered? {
        var disp = CMTime.invalid
        guard let pb = output.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: &disp), disp.isNumeric else { return nil }
        let (n, exact) = E1Compositor.frameIndex(disp)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bgra = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA
        let sizeOK = w == Spec.width && h == Spec.height && bgra
        let hash = sizeOK ? PixelCompare.sha256(pb) : ""
        let m = sizeOK ? FrameMetrics.measure(pb, captionRect: captionRect) : FrameMetrics(code: -1, captionPixels: -1, barHeights: [])
        let d = Delivered(displayValue: disp.value, displayTimescale: disp.timescale, frame: n, exact: exact,
                          hashMatchesReference: n >= 0 && n < reference.count && hash == reference[n],
                          code: m.code, captionPixels: m.captionPixels, barHeights: m.barHeights,
                          polledItemSeconds: it.seconds, hostSeconds: host, width: w, height: h, bgra: bgra)
        lock.lock(); records.append(d); lock.unlock()
        return d
    }

    /// 일시정지 상태 등에서 특정 시각의 새 프레임을 기다린다(최대 timeoutMs). 없으면 nil.
    public func fetch(at t: CMTime, timeoutMs: Int) async -> Delivered? {
        await withCheckedContinuation { (k: CheckedContinuation<Delivered?, Never>) in
            queue.async { [self] in
                let deadline = CACurrentMediaTime() + Double(timeoutMs) / 1000
                while CACurrentMediaTime() < deadline {
                    if output.hasNewPixelBuffer(forItemTime: t), let d = grab(t, host: CACurrentMediaTime()) {
                        k.resume(returning: d); return
                    }
                    usleep(5_000)
                }
                k.resume(returning: nil)
            }
        }
    }
}
