import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 4:2:0 그대로 복사하는 실험 합성기(2026-10-22, docs/SUBTITLE-DESIGN.md §35, 원인 확인 실험 — 구조 승인 아님). 선택 실행(OTF_SB=1).
/// 원본을 420v로 받아 render context 420v 버퍼에 평면을 그대로 복사하고 색 첨부를 옮긴다. BGRA로 대신하지 않는다(형식이 다르면 오류로 끝낸다).
/// 받는 구성: 지시 하나, 레이어 하나, 항등 변형, 원본 크기 = 렌더 크기(배율·여러 레이어·자막 없음). 그 밖은 거부한다.
final class Passthrough420Instruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid   // 프레임워크 통과(합성기 건너뜀)를 쓰지 않는다: 이 합성기가 직접 복사한다
    let trackID: CMPersistentTrackID
    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID) {
        self.timeRange = timeRange; self.trackID = trackID; requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

final class Passthrough420Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: [Self.format]] }
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]
    private let lock = NSLock()
    private var context: AVVideoCompositionRenderContext?
    private let queue = DispatchQueue(label: "dev.ontheframe.passthrough420")

    /// 진단 기록(실제로 받은·낸 형식)
    struct Log { var requests = 0, finished = 0, errors: [String] = [], sourceFormats = Set<OSType>(), outputFormats = Set<OSType>(), movieTimeMismatch = 0, movieTimeMissing = 0, movieTimeSamples: [String] = [] }
    nonisolated(unsafe) static var log = Log()
    static let logLock = NSLock()
    static func resetLog() { logLock.lock(); log = Log(); logLock.unlock() }
    static func record(_ f: (inout Log) -> Void) { logLock.lock(); f(&log); logLock.unlock() }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { lock.lock(); context = newRenderContext; lock.unlock() }
    func cancelAllPendingVideoCompositionRequests() {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        Self.record { $0.requests += 1 }
        let box = RequestBox(r: request)
        queue.async { [self] in process(box.r) }
    }
    struct RequestBox: @unchecked Sendable { let r: AVAsynchronousVideoCompositionRequest }
    private func fail(_ r: AVAsynchronousVideoCompositionRequest, _ msg: String) {
        Self.record { $0.errors.append(msg) }
        r.finish(with: NSError(domain: "Passthrough420", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]))
    }
    private func process(_ r: AVAsynchronousVideoCompositionRequest) {
        guard let ins = r.videoCompositionInstruction as? Passthrough420Instruction else { fail(r, "unexpected instruction"); return }
        guard let src = r.sourceFrame(byTrackID: ins.trackID) else { fail(r, "no source frame at \(r.compositionTime.seconds)"); return }
        let sf = CVPixelBufferGetPixelFormatType(src)
        Self.record { $0.sourceFormats.insert(sf) }
        guard sf == Self.format else { fail(r, "source format \(sf) is not 420v"); return }
        lock.lock(); let ctx = context; lock.unlock()
        guard let ctx, let out = ctx.newPixelBuffer() else { fail(r, "no render context buffer"); return }
        let of = CVPixelBufferGetPixelFormatType(out)
        Self.record { $0.outputFormats.insert(of) }
        guard of == Self.format else { fail(r, "render context format \(of) is not 420v"); return }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        guard w == CVPixelBufferGetWidth(out), h == CVPixelBufferGetHeight(out), CVPixelBufferGetPlaneCount(src) == 2, CVPixelBufferGetPlaneCount(out) == 2 else {
            fail(r, "size/plane mismatch src \(w)x\(h) out \(CVPixelBufferGetWidth(out))x\(CVPixelBufferGetHeight(out))"); return
        }
        // 원본 프레임 선택 확인: 항등 단일 원본(시작 0)이므로 원본 movie time = 합성 시각
        if let mt = ExperimentalCompositor.movieTime(src) {   // 첨부는 kCVBufferTimeValueKey·TimeScaleKey 사전(CMTime 사전이 아님)
            if CMTimeCompare(mt, r.compositionTime) != 0 { Self.record { $0.movieTimeMismatch += 1 } }
            Self.record { l in if l.movieTimeSamples.count < 4 { l.movieTimeSamples.append("comp \(r.compositionTime.value)/\(r.compositionTime.timescale) movie \(mt.value)/\(mt.timescale) (\(String(format: "%.4f", mt.seconds - r.compositionTime.seconds)) s)") } }
        } else { Self.record { $0.movieTimeMissing += 1 } }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(out, [])
        for plane in 0..<2 {   // 활성 영역만(행 끝 채움 바이트 제외): Y w바이트 × h행, CbCr w바이트 × h/2행
            let sb = CVPixelBufferGetBaseAddressOfPlane(src, plane)!, ob = CVPixelBufferGetBaseAddressOfPlane(out, plane)!
            let sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, plane), obpr = CVPixelBufferGetBytesPerRowOfPlane(out, plane)
            let rows = CVPixelBufferGetHeightOfPlane(src, plane), bytes = CVPixelBufferGetWidthOfPlane(src, plane) * (plane == 0 ? 1 : 2)
            for y in 0..<rows { memcpy(ob + y * obpr, sb + y * sbpr, bytes) }
        }
        CVPixelBufferUnlockBaseAddress(out, []); CVPixelBufferUnlockBaseAddress(src, .readOnly)
        CVBufferPropagateAttachments(src, out)   // 원색·전달·행렬·색차 위치 등
        r.finish(withComposedVideoFrame: out)
        Self.record { $0.finished += 1 }
    }

    /// 기본 videoComposition → 이 합성기의 videoComposition. 받지 않는 구성은 오류로 알린다.
    static func composition(from base: AVVideoComposition, sourceSize: CGSize, sourceTransform: CGAffineTransform) throws -> AVVideoComposition {
        struct Unsupported: Error, CustomStringConvertible { let description: String }
        guard base.instructions.count == 1, let ins = base.instructions[0] as? AVVideoCompositionInstruction else { throw Unsupported(description: "instructions \(base.instructions.count)") }
        guard ins.layerInstructions.count == 1, let li = ins.layerInstructions.first else { throw Unsupported(description: "layers \(ins.layerInstructions.count)") }
        var t0 = CGAffineTransform.identity, t1 = CGAffineTransform.identity, range = CMTimeRange.invalid
        _ = li.getTransformRamp(for: ins.timeRange.start, start: &t0, end: &t1, timeRange: &range)
        guard t0 == .identity, t1 == .identity || !range.isValid else { throw Unsupported(description: "layer transform \(t0)") }
        guard sourceSize == base.renderSize, sourceTransform == .identity else { throw Unsupported(description: "source \(sourceSize) transform \(sourceTransform) vs render \(base.renderSize)") }
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = Passthrough420Compositor.self
        vc.renderSize = base.renderSize
        vc.frameDuration = base.frameDuration
        vc.instructions = [Passthrough420Instruction(timeRange: ins.timeRange, trackID: li.trackID)]
        return vc.copy() as! AVVideoComposition
    }
}

extension SubtitleApproachBTests {
    func testApproachBPassthrough420Export() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, ta, expected) = try await plan()
        let src = fixtures.appendingPathComponent("otf-TA.mp4")
        let st = try await AVURLAsset(url: src).loadTracks(withMediaType: .video).first!
        let size = try await st.load(.naturalSize), tf = try await st.load(.preferredTransform)
        let vc = try Passthrough420Compositor.composition(from: p.videoComposition, sourceSize: size, sourceTransform: tf)
        note("plan: renderSize \(p.videoComposition.renderSize) frames \(p.durationFrames) | source \(size) transform identity \(tf == .identity) | composition: \(vc.customVideoCompositorClass.map { "\($0)" } ?? "nil") instructions \(vc.instructions.count)")
        func fmt(_ f: OSType) -> String { String(format: "%c%c%c%c", (f >> 24) & 255, (f >> 16) & 255, (f >> 8) & 255, f & 255) }
        func logLine(_ tag: String) -> String {
            Self.logLockedCopy { l in "\(tag): requests \(l.requests) finished \(l.finished) errors \(l.errors.prefix(3)) | source formats \(l.sourceFormats.map(fmt)) | render-context formats \(l.outputFormats.map(fmt)) | source movie time ≠ composition time \(l.movieTimeMismatch), missing \(l.movieTimeMissing), samples \(l.movieTimeSamples)" }
        }

        // 1. 인코딩 전: 리더(420v 요청)로 합성기 출력을 읽어 원본 디코딩 평면과 활성 바이트 비교
        var ref: [Int: Planes] = [:]
        do {
            let a = AVURLAsset(url: src)
            let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
            r.add(o); r.startReading()
            while let sb = o.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb) { ref[Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded())] = Self.planes(pb) } }
        }
        Passthrough420Compositor.resetLog()
        let r = try AVAssetReader(asset: p.composition)
        let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
        o.videoComposition = vc
        r.add(o); r.startReading()
        var frames = 0, ptsBad = 0, yDiff = 0, cDiff = 0, readerFormats = Set<OSType>(), attach = ""
        var seen = Set<Int>()
        while let sb = o.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb), n = Int((pts.seconds * 30).rounded())
            if CMTimeCompare(pts, CMTime(value: CMTimeValue(n), timescale: 30)) != 0 { ptsBad += 1 }
            readerFormats.insert(CVPixelBufferGetPixelFormatType(pb)); seen.insert(n); frames += 1
            if n == 0 { attach = Self.attachmentsSummary(pb) }
            guard let q = ref[n] else { continue }
            let got = Self.planes(pb)
            for i in 0..<got.y.count where got.y[i] != q.y[i] { yDiff += 1 }
            for i in 0..<got.c.count where got.c[i] != q.c[i] { cDiff += 1 }
        }
        XCTAssertEqual(r.status, .completed, "\(String(describing: r.error))")
        note("pre-encode (reader, 420v requested): frames \(frames) distinct \(seen.count) range \(seen.min() ?? -1)–\(seen.max() ?? -1) PTS≠n/30 \(ptsBad) | reader buffer formats \(readerFormats.map(fmt)) | frame 0 \(attach) | active bytes differing from source decode: Y \(yDiff) / \(frames * 1920 * 1080), CbCr \(cDiff) / \(frames * 960 * 540 * 2)")
        note(logLine("compositor during reader"))

        // 2. 내보내기 한 번(제품 ExportService 설정 그대로)
        Passthrough420Compositor.resetLog()
        let keep = ExportEndToEndTests.root.appendingPathComponent("path-cause")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        let dest = keep.appendingPathComponent("h264-P420-empty.mp4")
        try? FileManager.default.removeItem(at: dest)   // 이 테스트가 만든 이전 출력만
        let outcome = await ExportService.export(withVideoComposition(p, vc), to: .fromSavePanel(dest), sources: [ta]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        note(logLine("compositor during export"))
        let v = try await ExportJudge.judge(dest, clips: [.init(file: "otf-TA.mp4", sourceIn: 0, length: p.durationFrames)], durationFrames: p.durationFrames, checkAudio: false)
        note("export: \(try await SubtitleABComparisonTests.describe(dest)) | screen code vs otf-TA timeline: pass \(v.pass) frames \(v.frames)")
        XCTAssertTrue(v.pass)
        _ = expected
    }
    static func logLockedCopy(_ f: (Passthrough420Compositor.Log) -> String) -> String {
        Passthrough420Compositor.logLock.lock(); defer { Passthrough420Compositor.logLock.unlock() }
        return f(Passthrough420Compositor.log)
    }
}
