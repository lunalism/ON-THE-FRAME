import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// 합성기 호출 기록. 프리뷰 세션·내보내기마다 하나씩 만든다.
/// 안전성(@unchecked Sendable의 근거): 가변 저장 상태는 모두 `lock`을 잡은 상태에서만 읽고 쓴다.
/// `hashOutputs`는 let이다. AVFoundation이 합성기를 여러 스레드에서 호출하므로 잠금이 필요하다.
public final class CompositorLog: @unchecked Sendable {
    public struct Entry: Sendable, Codable {
        public let timeValue: Int64
        public let timescale: Int32
        /// 합성 시각에 해당하는 프레임 번호(타임라인 끝 시각이면 마지막 유효 프레임 + 1)
        public let frame: Int
        /// 실제로 렌더한 프레임 번호. 끝 시각 요청은 마지막 유효 프레임을 유지한다(P-007)
        public let renderedFrame: Int
        public let exactFrameTime: Bool
        public let renderMs: Double
        public let hash: String?
        public let finishedUptimeNs: UInt64
    }
    public struct Snapshot: Sendable {
        public let entries: [Entry]
        public let cancelled: Int
        public let errors: [String]
        public let renderContexts: [String]
        public let maxInFlight: Int
        public let cancelAllCalls: Int
    }

    public let hashOutputs: Bool
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var cancelled = 0
    private var errors: [String] = []
    private var contexts: [String] = []
    private var inFlight = 0
    private var maxInFlight = 0
    private var cancelAllCalls = 0

    public init(hashOutputs: Bool) { self.hashOutputs = hashOutputs }

    func began() { lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock() }
    func ended() { lock.lock(); inFlight -= 1; lock.unlock() }
    func record(_ e: Entry) { lock.lock(); entries.append(e); lock.unlock() }
    func recordCancelled() { lock.lock(); cancelled += 1; lock.unlock() }
    func recordError(_ s: String) { lock.lock(); errors.append(s); lock.unlock() }
    func recordContext(_ s: String) { lock.lock(); contexts.append(s); lock.unlock() }
    func recordCancelAll() { lock.lock(); cancelAllCalls += 1; lock.unlock() }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(entries: entries, cancelled: cancelled, errors: errors, renderContexts: contexts,
                        maxInFlight: maxInFlight, cancelAllCalls: cancelAllCalls)
    }
    public func reset() {
        lock.lock(); entries = []; cancelled = 0; errors = []; maxInFlight = inFlight; cancelAllCalls = 0; lock.unlock()
    }
}

/// 합성 명령. 렌더러(불변, Sendable)와 기록 객체를 운반한다. 모든 저장 속성이 let이다.
/// 안전성(@unchecked Sendable의 근거): NSObject 하위 클래스라 컴파일러가 확인하지 못하지만, 상태는 생성 후
/// 바뀌지 않고 참조하는 객체(FrameRenderer, CompositorLog)는 스레드 안전하다.
public final class E1Instruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    /// 같은 입력이라도 시각마다 결과가 다르다(스펙트럼·자막·프레임 코드). false면 엔진이 프레임을 재사용할 수 있다.
    public let containsTweening = true
    /// 소스 비디오 프레임이 필요 없다(모든 픽셀을 렌더러가 만든다).
    public let requiredSourceTrackIDs: [NSValue]? = []
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public let renderer: FrameRenderer
    public let log: CompositorLog
    /// 타임라인 프레임 격자에서 유도한 마지막 유효 프레임(FrameGrid). 그 뒤 시각의 요청은 이 프레임을 렌더한다.
    public let lastValidFrame: Int

    public init(timeRange: CMTimeRange, renderer: FrameRenderer, log: CompositorLog, lastValidFrame: Int) {
        self.timeRange = timeRange; self.renderer = renderer; self.log = log; self.lastValidFrame = lastValidFrame
    }
}

/// AVPlayer·AVAssetReader용 사용자 정의 합성기. E1-a의 FrameRenderer를 그대로 호출한다.
/// 안전성(@unchecked Sendable의 근거):
/// - `renderContext`와 `generation`은 `lock` 안에서만 접근한다.
/// - 요청 처리는 직렬 `queue`에서만 한다. 요청 객체는 그 블록 하나에만 넘기고, 끝내는 호출(finish…)도 그 블록에서 한 번만 한다.
/// - 출력 버퍼는 렌더 컨텍스트 풀에서 요청마다 새로 받아 finish 뒤에는 건드리지 않는다.
public final class E1Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    public let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
    ]
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]

    private let queue = DispatchQueue(label: "e1.compositor")
    private let lock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?
    private var generation = 0

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.lock(); renderContext = newRenderContext; lock.unlock()
        // 기록은 instruction의 log로만 가능하므로 다음 요청에서 기록한다.
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock(); let gen = generation; lock.unlock()
        let box = RequestBox(request)
        queue.async { [self] in
            let r = box.request
            guard let instr = r.videoCompositionInstruction as? E1Instruction else {
                r.finish(with: E1Error.render("unexpected instruction")); return
            }
            instr.log.began(); defer { instr.log.ended() }
            lock.lock(); let current = generation; let ctx = renderContext; lock.unlock()
            if current != gen { instr.log.recordCancelled(); r.finishCancelledRequest(); return }
            guard let ctx else { instr.log.recordError("no render context"); r.finish(with: E1Error.render("no render context")); return }
            let size = ctx.size
            if Int(size.width) != Spec.width || Int(size.height) != Spec.height || ctx.renderScale != 1 {
                instr.log.recordContext("size \(size.width)x\(size.height) scale \(ctx.renderScale)")
            }
            guard let pb = ctx.newPixelBuffer() else {
                instr.log.recordError("newPixelBuffer nil"); r.finish(with: E1Error.render("newPixelBuffer nil")); return
            }
            let t = r.compositionTime
            let (n, exact) = Self.frameIndex(t)
            let shown = Self.contentFrame(n, lastValid: instr.lastValidFrame)
            let t0 = Clock.now()
            do { try instr.renderer.render(frame: shown, into: pb) } catch {
                instr.log.recordError("render \(error)"); r.finish(with: error); return
            }
            let ms = Double(Clock.now() - t0) / 1e6
            let h = instr.log.hashOutputs ? PixelCompare.sha256(pb) : nil
            r.finish(withComposedVideoFrame: pb)
            instr.log.record(.init(timeValue: t.value, timescale: t.timescale, frame: n, renderedFrame: shown, exactFrameTime: exact,
                                   renderMs: ms, hash: h, finishedUptimeNs: Clock.now()))
        }
    }

    /// 문서: 대기 중인 요청을 모두 취소하거나 끝낼 때까지 블록해야 한다.
    /// 세대 번호를 올린 뒤 직렬 큐를 비울 때까지 기다린다. 대기 중이던 블록은 세대가 달라 finishCancelledRequest를 호출한다.
    public func cancelAllPendingVideoCompositionRequests() {
        lock.lock(); generation += 1; lock.unlock()
        queue.sync {}
    }

    /// 프레임 번호 → 렌더할 프레임. 타임라인 끝(마지막 유효 프레임 뒤) 요청은 마지막 유효 프레임을 유지하고(P-007),
    /// 0 이전은 0으로 둔다. 상태 없는 순수 함수다(명령의 불변 값만 사용).
    public static func contentFrame(_ n: Int, lastValid: Int) -> Int { min(max(n, 0), lastValid) }

    /// 합성 시각 → 프레임 번호(가장 가까운 n/30). exact는 시각이 정확히 n/30인지.
    public static func frameIndex(_ t: CMTime) -> (Int, Bool) {
        let v = Int64(t.value) * 30, ts = Int64(t.timescale)
        let n = Int((2 * v + ts) / (2 * ts))
        return (n, v % ts == 0)
    }
}

/// 요청 객체를 직렬 큐의 블록 하나로 넘기기 위한 상자.
/// 안전성: 넘긴 뒤에는 그 블록에서만 사용한다(소유권 이전). AVFoundation 문서는 startRequest 반환 뒤
/// 요청을 보관했다가 나중에 끝내도 된다고 명시한다(AVVideoCompositing.h, startVideoCompositionRequest:).
struct RequestBox: @unchecked Sendable {
    let request: AVAsynchronousVideoCompositionRequest
    init(_ r: AVAsynchronousVideoCompositionRequest) { request = r }
}

/// 프리뷰·합성기 내보내기에 쓰는 composition 구성.
public struct CompositionBundle: @unchecked Sendable {
    // 안전성: 생성 후 변경하지 않는 불변 사본(AVComposition, AVVideoComposition)만 담는다.
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition?
    public let selectedTrackID: CMPersistentTrackID
    public let videoTrackID: CMPersistentTrackID?
}

public enum CompositionBuilder {
    /// 오디오 트랙(선택 소스 S, 무관 U)과, 합성기를 쓸 때는 비디오 트랙을 만든다.
    ///
    /// 비디오 트랙은 운반용 영상(CarrierVideo)의 실제 샘플로 채운다. 합성기는 이 픽셀을 쓰지 않는다.
    /// 2026-10-09 진단(results/e1b-diagnose-2026-10-09T142137Z.json): 빈 트랙에 insertEmptyTimeRange만 하면
    /// 트랙의 segment가 0개·format description 없음·시간 범위 NaN이 되고, AVPlayerLayer는 readyForDisplay가
    /// 되지 않아 화면이 검게 남았다(비디오 출력 없이는 합성기 요청도 0회). 오류는 보고되지 않았다.
    /// AVAssetReaderVideoCompositionOutput과 AVPlayerItemVideoOutput은 그 상태에서도 프레임을 받았다.
    /// allowEmptyVideoTrackForDiagnosis: 그 실패 구성을 진단에서 재현할 때만 true.
    public static func build(_ state: TimelineState, renderer: FrameRenderer?, log: CompositorLog?,
                             videoCarrier: URL?, allowEmptyVideoTrackForDiagnosis: Bool = false) async throws -> CompositionBundle {
        let frameDuration = CMTime(value: 1, timescale: Spec.fps)
        // 빈 타임라인은 명시적으로 거부한다: 유효 프레임이 없어 끝 프레임 유지 규칙을 적용할 수 없다.
        guard let lastValid = state.lastValidFrame(frameDuration: frameDuration) else {
            throw E1Error.invalidSource("empty timeline: duration \(state.duration.seconds) s has no valid video frame")
        }
        let comp = AVMutableComposition()
        var selectedID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        for (i, p) in ([state.selected] + (state.unrelated.map { [$0] } ?? [])).enumerated() {
            guard FileManager.default.isReadableFile(atPath: p.source.path) else { throw E1Error.invalidSource("not readable: \(p.source.path)") }
            let asset = AVURLAsset(url: p.source.url)
            guard let src = try await asset.loadTracks(withMediaType: .audio).first else { throw E1Error.invalidSource("no audio track: \(p.source.path)") }
            guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw E1Error.invalidSource("addMutableTrack failed")
            }
            if p.timelineStart > .zero { t.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: p.timelineStart)) }
            try t.insertTimeRange(CMTimeRange(start: p.sourceIn, duration: p.duration), of: src, at: p.timelineStart)
            if i == 0 { selectedID = t.trackID }
        }
        var videoID: CMPersistentTrackID?
        var vc: AVVideoComposition?
        if let renderer, let log {
            guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw E1Error.render("add video track failed")
            }
            if videoCarrier == nil && !allowEmptyVideoTrackForDiagnosis {
                throw E1Error.invalidSource("video carrier required for compositor compositions")
            }
            if let carrier = videoCarrier {
                let ca = AVURLAsset(url: carrier)
                guard let src = try await ca.loadTracks(withMediaType: .video).first else { throw E1Error.invalidSource("carrier has no video") }
                try vt.insertTimeRange(CMTimeRange(start: .zero, duration: state.duration), of: src, at: .zero)
            } else {
                vt.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: state.duration))
            }
            videoID = vt.trackID
            let m = AVMutableVideoComposition()
            m.customVideoCompositorClass = E1Compositor.self
            m.frameDuration = frameDuration
            m.renderSize = CGSize(width: Spec.width, height: Spec.height)
            m.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
            m.instructions = [E1Instruction(timeRange: CMTimeRange(start: .zero, duration: state.duration), renderer: renderer, log: log,
                                           lastValidFrame: lastValid)]
            vc = (m.copy() as! AVVideoComposition)
        }
        return CompositionBundle(composition: comp.copy() as! AVComposition, videoComposition: vc,
                                 selectedTrackID: selectedID, videoTrackID: videoID)
    }
}
