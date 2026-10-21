import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import QuartzCore

/// 자막 S1·S1b 실험(2026-10-12, docs/SUBTITLE-DESIGN.md §8·§13·§14·§15): 지금 기본 합성기와 같은 영상을 내는 사용자 정의 합성기.
/// **앱은 쓰지 않는다.** 기본 합성 경로(`CompositionPlanner.plan`)는 그대로이고, 이 파일은 테스트에서만 부른다.
/// 구성: `CompositionPlanner.plan`이 만든 기본 videoComposition의 지시(구간·레이어 트랙·변형·검정 배경)를 그대로 옮겨
/// 사용자 정의 지시로 바꾼다(`videoComposition(from:)`). 합성기는 원본 프레임을 받아 같은 변형으로 아래 레이어부터 쌓는다(Core Image).
/// 자막은 아직 그리지 않는다.
public enum ExperimentalComposition {
    /// 기본 videoComposition → 같은 구간·레이어·변형의 사용자 정의 videoComposition. 렌더 크기·프레임 간격은 그대로다.
    /// sourceTrackIDForFrameTiming은 두지 않는다: 섞인 fps 원본에서 출력 시각이 원본 표본을 따르면 안 된다(출력은 frameDuration 1/30 s 격자).
    public static func videoComposition(from base: AVVideoComposition, options: ExperimentalCompositorOptions = .init(),
                                        diagnostics: ExperimentalCompositorLog? = nil) throws -> AVVideoComposition {
        var out: [ExperimentalInstruction] = []
        for case let ins as AVVideoCompositionInstruction in base.instructions {
            var layers: [ExperimentalInstruction.Layer] = []
            for li in ins.layerInstructions {
                var start = CGAffineTransform.identity, end = CGAffineTransform.identity, range = CMTimeRange.invalid
                let ramp = li.getTransformRamp(for: ins.timeRange.start, start: &start, end: &end, timeRange: &range)
                // 지금 계획은 레이어마다 변형 하나(경사 없음)다. 경사가 있으면 이 실험의 범위 밖이라 실패로 알린다(숨기지 않음).
                if ramp, range.isValid, start != end { throw ExperimentalCompositorError.unsupported("transform ramp at \(ins.timeRange.start.seconds)") }
                // 경계 보정은 축 정렬 변형(배율·이동·90° 단위 회전·뒤집기)에서만 쟀다. 기울어진 변형은 잘못 자를 수 있어 실패로 알린다(숨기지 않음).
                if options.snapEdges, !ExperimentalCompositor.isAxisAligned(start) { throw ExperimentalCompositorError.unsupported("non-axis-aligned transform \(start)") }
                layers.append(.init(trackID: li.trackID, transform: start))
            }
            out.append(ExperimentalInstruction(timeRange: ins.timeRange, layers: layers, options: options, log: diagnostics))
        }
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = options.ycbcrSources ? ExperimentalCompositorYCbCrSources.self : ExperimentalCompositor.self
        vc.renderSize = base.renderSize
        vc.frameDuration = base.frameDuration
        vc.instructions = out
        return vc.copy() as! AVVideoComposition
    }
}

/// 그리기 선택(S1b 비교용). 기본값은 S1b 측정에 근거한 값이다(docs/SUBTITLE-DESIGN.md §15).
public struct ExperimentalCompositorOptions: Sendable, Equatable {
    /// 레이어 가장자리: 변형된 원본 사각형의 각 가장자리를 화소 가운데 포함 규칙(가장 가까운 화소 경계)으로 자른다.
    /// 안쪽 표본 위치(배치·배율·회전)는 바꾸지 않는다(변형 전체를 반올림하지 않음). false면 Core Image 기본(소수 가장자리 섞임).
    public var snapEdges: Bool
    public enum Sampling: String, Sendable, CaseIterable { case linear, nearest, lanczos, bicubic }
    public var sampling: Sampling
    /// 검사 전용(S1b 표본 좌표 가설): 표본 위치만 출력 공간(왼쪽 위 원점, 화소)에서 이만큼 옮긴다. 가장자리 자르기는 옮기지 않는다. 기본 0.
    public var testSampleOffset: CGPoint
    /// 검사 전용(S1b 재검토 색차 가설): 원본 프레임을 BGRA 대신 YCbCr 4:2:0(디코더 형식)으로 받아 Core Image가 RGB로 바꾸게 한다. 기본 false.
    public var ycbcrSources: Bool
    public init(snapEdges: Bool = true, sampling: Sampling = .linear, testSampleOffset: CGPoint = .zero, ycbcrSources: Bool = false) {
        self.snapEdges = snapEdges; self.sampling = sampling; self.testSampleOffset = testSampleOffset; self.ycbcrSources = ycbcrSources
    }
}

public enum ExperimentalCompositorError: Error, CustomStringConvertible {
    case unsupported(String), render(String)
    public var description: String {
        switch self { case .unsupported(let s): return "experimental compositor: unsupported \(s)"; case .render(let s): return "experimental compositor: \(s)" }
    }
}

/// 지시 하나: 구간, 레이어(위 레이어가 먼저, 기본 합성기와 같은 차례), 배경은 늘 불투명 검정.
public final class ExperimentalInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public struct Layer: Sendable { public let trackID: CMPersistentTrackID; public let transform: CGAffineTransform }
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = false
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID = kCMPersistentTrackID_Invalid
    public let layers: [Layer]
    public let options: ExperimentalCompositorOptions
    let log: ExperimentalCompositorLog?
    init(timeRange: CMTimeRange, layers: [Layer], options: ExperimentalCompositorOptions, log: ExperimentalCompositorLog?) {
        self.timeRange = timeRange; self.layers = layers; self.options = options; self.log = log
        requiredSourceTrackIDs = layers.isEmpty ? nil : layers.map { NSNumber(value: $0.trackID) }
    }
}

/// 진단 기록(테스트용). 잠금 안에서만 바꾼다.
/// - entries: 그린 요청마다 출력 시각과 레이어별 받은 원본 프레임 시각(kCVBufferMovieTimeKey)
/// - outcomes: 받은 요청마다 끝난 방식(성공·취소·오류). 요청 하나는 정확히 한 번 끝나야 한다.
public final class ExperimentalCompositorLog: @unchecked Sendable {
    public struct Entry: Sendable {
        public let time: CMTime
        public let sources: [(trackID: CMPersistentTrackID, movieTime: CMTime?)]
        public let sourceMissing: Bool
        /// 요청을 받은 때와 그리기를 마친 때(호스트 시각, 초). 시작 차례·지연 진단용
        public var received: Double = 0, rendered: Double = 0
    }
    public enum Outcome: String, Sendable { case finished, cancelled, failed }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var started = 0, outcomes: [Outcome] = [], cancelCalls = 0, errors: [String] = []
    public init() {}
    func add(_ e: Entry) { lock.lock(); entries.append(e); lock.unlock() }
    func start() { lock.lock(); started += 1; lock.unlock() }
    func end(_ o: Outcome) { lock.lock(); outcomes.append(o); lock.unlock() }
    func cancelAll() { lock.lock(); cancelCalls += 1; lock.unlock() }
    func error(_ s: String) { lock.lock(); errors.append(s); lock.unlock() }
    public var snapshot: (entries: [Entry], started: Int, outcomes: [Outcome], cancelCalls: Int, errors: [String]) {
        lock.lock(); defer { lock.unlock() }; return (entries, started, outcomes, cancelCalls, errors)
    }
    public var cancelled: Int { snapshot.outcomes.filter { $0 == .cancelled }.count }
}

/// 합성 요청(직접 프로토콜 검사를 위해 추상화). AVFoundation 요청은 아래 확장으로 그대로 맞는다.
public protocol ExperimentalCompositionRequest: AnyObject {
    var compositionTime: CMTime { get }
    var experimentalInstruction: ExperimentalInstruction? { get }
    func sourceFrame(byTrackID trackID: CMPersistentTrackID) -> CVPixelBuffer?
    func finish(withComposedVideoFrame composedVideoFrame: CVPixelBuffer)
    func finish(with error: any Error)
    func finishCancelledRequest()
}
extension AVAsynchronousVideoCompositionRequest: ExperimentalCompositionRequest {
    public var experimentalInstruction: ExperimentalInstruction? { videoCompositionInstruction as? ExperimentalInstruction }
}

struct ExperimentalRequestBox: @unchecked Sendable { let request: any ExperimentalCompositionRequest }

/// 사용자 정의 합성기. 원본·출력 모두 BGRA. 요청은 직렬 queue에서 처리한다.
/// 취소(`cancelAllPendingVideoCompositionRequests`): 세대를 올린다. 그 전에 받은 요청은 그리기 전이면 그리지 않고, 그린 뒤라도 내보내기 전에
/// 세대를 다시 보아 취소로 끝낸다(취소된 작업이 늦은 결과를 내지 않음). 요청은 정확히 한 번 끝난다(성공·취소·오류).
/// 그리기(Core Image, 색 관리 끔): 출력 = 불투명 검정 위에 아래 레이어부터 원본 이미지를 레이어 변형으로 옮겨 겹친다(원본은 불투명).
/// 좌표: AVFoundation 레이어 변형은 왼쪽 위 원점(+Y 아래), Core Image는 왼쪽 아래 원점이므로 원본·출력 높이로 뒤집어 같은 변형을 쓴다.
/// 출력 버퍼의 색 첨부(원색·전달 함수·YCbCr 행렬)는 위 레이어 원본에서 옮긴다(내보내기 인코더가 같은 변환을 쓰게).
public class ExperimentalCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    public var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]] }
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]
    private let queue = DispatchQueue(label: "dev.ontheframe.experimental-compositor")
    private let lock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?
    private var generation = 0
    private let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    /// 검사 전용: 렌더 컨텍스트 없이 쓸 출력 버퍼 크기(직접 프로토콜 검사)와, 그리기마다 넣을 지연(취소 경합을 만들기 위함, 마이크로초).
    public var testRenderSize: CGSize?
    nonisolated(unsafe) public static var testRenderDelayMicroseconds: UInt32 = 0
    /// 검사 전용: 그리기를 시작했다는 신호(지연 중 취소를 정확히 넣기 위함)
    public var testDidBeginRender: (@Sendable (CMTime) -> Void)?

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.lock(); renderContext = newRenderContext; lock.unlock()
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) { start(request) }

    public func start(_ request: any ExperimentalCompositionRequest) {
        lock.lock(); let gen = generation; lock.unlock()
        let received = CACurrentMediaTime()
        request.experimentalInstruction?.log?.start()
        let box = ExperimentalRequestBox(request: request)
        queue.async { [self] in process(box.request, generation: gen, received: received) }
    }

    private func newBuffer() -> (CVPixelBuffer, CGSize)? {
        lock.lock(); let ctx = renderContext; let testSize = testRenderSize; lock.unlock()
        if let ctx, let b = ctx.newPixelBuffer() { return (b, ctx.size) }
        guard let s = testSize else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(s.width), Int(s.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        return pb.map { ($0, s) }
    }
    private func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == gen }

    private func process(_ r: any ExperimentalCompositionRequest, generation gen: Int, received: Double = 0) {
        guard let ins = r.experimentalInstruction else {
            r.finish(with: ExperimentalCompositorError.render("unexpected instruction")); return
        }
        let log = ins.log
        if !current(gen) { log?.end(.cancelled); r.finishCancelledRequest(); return }
        guard let (out, size) = newBuffer() else { log?.error("no buffer"); log?.end(.failed); r.finish(with: ExperimentalCompositorError.render("no buffer")); return }
        testDidBeginRender?(r.compositionTime)
        if Self.testRenderDelayMicroseconds > 0 { usleep(Self.testRenderDelayMicroseconds) }
        var image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: CGRect(origin: .zero, size: size))
        var sources: [(CMPersistentTrackID, CMTime?)] = [], missing = false
        var top: CVPixelBuffer?
        // 위 레이어가 먼저이므로 거꾸로(아래부터) 겹친다
        for l in ins.layers.reversed() {
            guard let src = r.sourceFrame(byTrackID: l.trackID) else { missing = true; sources.append((l.trackID, nil)); continue }
            sources.append((l.trackID, Self.movieTime(src)))
            top = src
            image = Self.layerImage(src, l.transform, outSize: size, options: ins.options).composited(over: image)
        }
        if missing { log?.error("source frame nil at \(r.compositionTime.seconds)") }
        if let top { CVBufferPropagateAttachments(top, out) } else { Self.tagBT709(out) }
        ci.render(image.cropped(to: CGRect(origin: .zero, size: size)), to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
        var entry = ExperimentalCompositorLog.Entry(time: r.compositionTime, sources: sources.reversed(), sourceMissing: missing)
        entry.received = received; entry.rendered = CACurrentMediaTime()
        log?.add(entry)
        // 그리는 동안 취소되었으면 결과를 내지 않는다
        if !current(gen) { log?.end(.cancelled); r.finishCancelledRequest(); return }
        log?.end(.finished)
        r.finish(withComposedVideoFrame: out)
    }

    /// 먼 쪽 가장자리 문턱(원본 화소 단위, S1b 측정: 0.20에서 그림·0.25에서 안 그림)
    static let farEdgeInset: CGFloat = 0.25
    static func isAxisAligned(_ t: CGAffineTransform) -> Bool {
        (abs(t.b) < 1e-9 && abs(t.c) < 1e-9) || (abs(t.a) < 1e-9 && abs(t.d) < 1e-9)
    }
    /// 원본 버퍼 → 출력 좌표(Core Image, 왼쪽 아래 원점)의 레이어 이미지
    static func layerImage(_ src: CVPixelBuffer, _ t: CGAffineTransform, outSize size: CGSize, options o: ExperimentalCompositorOptions) -> CIImage {
        let w = CGFloat(CVPixelBufferGetWidth(src)), h = CGFloat(CVPixelBufferGetHeight(src))
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        var img = CIImage(cvPixelBuffer: src)
        if o.snapEdges { img = img.clampedToExtent() }   // 가장자리 화소를 넘어선 표본도 원본 가장자리 값(안쪽 섞임 없이 자르기 위함)
        var m = flipSource.concatenating(t).concatenating(flipOut)
        switch o.sampling {
        case .linear: break
        case .nearest: img = img.samplingNearest()
        case .lanczos, .bicubic:
            // 균일 배율 s를 먼저 원본 공간에서 고급 보간으로 하고, 남은 회전·이동(배율 1)은 선형으로 한다
            let s = sqrt(abs(t.a * t.d - t.b * t.c))
            if abs(s - 1) > 1e-9 {
                let f = CIFilter(name: o.sampling == .lanczos ? "CILanczosScaleTransform" : "CIBicubicScaleTransform")!
                f.setValue(img, forKey: kCIInputImageKey); f.setValue(s, forKey: kCIInputScaleKey); f.setValue(1.0, forKey: kCIInputAspectRatioKey)
                img = f.outputImage!
                m = CGAffineTransform(scaleX: 1 / s, y: 1 / s).concatenating(m)
            }
        }
        if o.testSampleOffset != .zero { m = m.concatenating(CGAffineTransform(translationX: o.testSampleOffset.x, y: -o.testSampleOffset.y)) }
        img = img.transformed(by: m)
        if o.snapEdges {
            // 기본 합성기 측정(S1b, docs/SUBTITLE-DESIGN.md §15, 경험 규칙·문서로 확인하지 않음): 출력 화소는 그 가운데가 원본 좌표
            // [0, 크기 − 0.25) 안에 들 때만 그려진다(먼 쪽 가장자리 문턱 0.25, 가까운 쪽 0). 축 정렬 변형(배율·이동·90° 회전)이므로
            // 그 원본 구간을 변형한 사각형에 화소 가운데 포함 규칙을 쓴다: 왼쪽·위 = floor(e + 0.5), 오른쪽·아래 = ceil(e − 0.5).
            let r = CGRect(x: 0, y: 0, width: w - Self.farEdgeInset, height: h - Self.farEdgeInset).applying(t)
            let x0 = (r.minX + 0.5).rounded(.down), y0 = (r.minY + 0.5).rounded(.down)
            let x1 = (r.maxX - 0.5).rounded(.up), y1 = (r.maxY - 0.5).rounded(.up)
            let snapped = CGRect(x: x0, y: size.height - y1, width: max(0, x1 - x0), height: max(0, y1 - y0))
            img = img.cropped(to: snapped)
        }
        return img
    }

    public func cancelAllPendingVideoCompositionRequests() {
        lock.lock(); generation += 1; lock.unlock()
        // 기록은 지시에 붙어 있어 여기서는 알 수 없다: 다음 요청이 지시의 기록으로 센다(cancelCalls는 AVFoundation 관찰 검사에서 따로 센다)
        Self.cancelObserver?()
        queue.sync {}
    }
    /// 검사 전용: 취소 호출 관찰
    nonisolated(unsafe) public static var cancelObserver: (@Sendable () -> Void)?

    static func movieTime(_ pb: CVPixelBuffer) -> CMTime? {
        guard let a = CVBufferCopyAttachment(pb, kCVBufferMovieTimeKey, nil) as? [String: Any],
              let v = (a[kCVBufferTimeValueKey as String] as? NSNumber)?.int64Value,
              let ts = (a[kCVBufferTimeScaleKey as String] as? NSNumber)?.int32Value, ts > 0 else { return nil }
        return CMTime(value: v, timescale: ts)
    }
    static func tagBT709(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}

/// 검사 전용(S1b 재검토): 원본을 YCbCr 4:2:0(비디오 범위·전체 범위)으로 받는 같은 합성기. 그리기·취소는 그대로다.
public final class ExperimentalCompositorYCbCrSources: ExperimentalCompositor, @unchecked Sendable {
    override public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]]
    }
}
