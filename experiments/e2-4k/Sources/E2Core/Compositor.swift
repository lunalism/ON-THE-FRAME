import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import CryptoKit
import E1Core
import Foundation
import IOSurface

// MARK: - 오버레이(타임라인 프레임 코드, 선택 오디오 스펙트럼, 자막)

public struct OverlayInfo: Sendable {
    public let frame: Int
    public let barHeights: [Int]
    public let captions: [Bool]   // TimedCaption 순서
}

/// 합성기가 소스 프레임 위에 그리는 것. 저장 상태는 모두 불변(let)이다.
/// 스펙트럼은 선택 오디오(음악) 캐시만 쓴다. 클립 오디오는 이 객체에 전달되지 않는다.
public final class Overlay: Sendable {
    public let spectrum: SpectrumCache
    public let music: MusicPlacement
    public let captions: [TimedCaption]

    public init(spectrum: SpectrumCache, music: MusicPlacement, captions: [TimedCaption]) {
        self.spectrum = spectrum; self.music = music; self.captions = captions
    }

    public func bands(frame n: Int) -> [Float] {
        if let s = music.sourceTime(frame: n), let b = spectrum.bands(atSourceTime: s) { return Array(b) }
        return [Float](repeating: 0, count: Spec4K.bandCount)
    }

    public func captionsShown(frame n: Int) -> [Bool] { captions.map { n >= $0.startFrame && n < $0.endFrame } }

    @discardableResult
    public func draw(frame n: Int, ctx: CGContext) -> OverlayInfo {
        let H = Spec4K.height
        func fill(_ x: Int, _ yTop: Int, _ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8), alpha: CGFloat = 1) {
            ctx.setFillColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: alpha)
            ctx.fill(CGRect(x: x, y: H - yTop - h, width: w, height: h))
        }
        ctx.setShouldAntialias(false)
        for b in 0..<Spec4K.codeBits {
            let on = (n >> (Spec4K.codeBits - 1 - b)) & 1 == 1
            fill(Spec4K.cellLeft + b * Spec4K.cellPitch, Spec4K.timelineCodeRowY, Spec4K.cellSize, Spec4K.cellSize, on ? Spec4K.codeOn : Spec4K.codeOff)
        }
        let heights = bands(frame: n).map(Spec4K.barHeight(forValue:))
        for (k, h) in heights.enumerated() where h > 0 {
            fill(Spec4K.barLeft(k), Spec4K.barBaselineY - h, Spec4K.barWidth, h, Spec4K.barColor)
        }
        let shown = captionsShown(frame: n)
        for (c, on) in zip(captions, shown) where on {
            let (line, width) = Self.line(c.text)
            let w = Int(width.rounded())
            let x: Int
            switch c.alignment {
            case .left: x = Spec4K.captionMarginX
            case .center: x = (Spec4K.width - w) / 2
            case .right: x = Spec4K.width - Spec4K.captionMarginX - w
            }
            let pad = 24 / Spec4K.layout.divisor, vpad = 12 / Spec4K.layout.divisor
            fill(x - pad, Spec4K.captionTop + vpad, w + 2 * pad, Spec4K.captionBottom - Spec4K.captionTop - 2 * vpad, (0, 0, 0), alpha: 0.6)
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(false)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: x, y: H - Spec4K.captionBaselineY)
            CTLineDraw(line, ctx)
            ctx.setShouldAntialias(false)
        }
        return OverlayInfo(frame: n, barHeights: heights, captions: shown)
    }

    /// CTLine은 호출마다 새로 만든다(스레드 간 공유하지 않음).
    static func line(_ s: String) -> (CTLine, Double) {
        let font = CTFontCreateWithName(Spec4K.captionFontName as CFString, Spec4K.captionFontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        return (line, CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

// MARK: - 합성기 기록

public final class E2Log: @unchecked Sendable {
    public struct Entry: Sendable, Codable {
        public let timeValue: Int64       // 합성 시각(원래 값)
        public let timescale: Int32
        public let frame: Int            // 합성 시각의 프레임 번호(가장 가까운 n/30)
        public let content: Int          // 그린 타임라인 프레임(끝 유지 적용)
        public let exact: Bool
        public let usedHeld: Bool        // 끝 유지용 보관 프레임을 썼는가
        public let sourceFrameNil: Bool  // 요청에 소스 프레임이 없었는가
        public let copyMs: Double
        public let overlayMs: Double
        public let fingerprint: String?
        public let finishedUptimeNs: UInt64
        /// 진단(diagnoseSource일 때만): 합성기가 받은 소스 버퍼의 화면 코드(독립 디코딩 값)와 IOSurface ID
        public var receivedSourceID: Int? = nil
        public var receivedSourceFrame: Int? = nil
        public var sourceSurfaceID: UInt32? = nil
        /// 소스 버퍼의 kCVBufferMovieTimeKey 첨부(value/timescale). 헤더 문서상 "대체로" 제공되는 값이다.
        public var sourceMovieTime: String? = nil
        /// 소스 버퍼의 movie time = 요청 시각인가. 첨부가 없거나 끝 유지 보관 프레임이면 nil(판단 불가).
        /// false = 합성기가 다른 시각의 소스 프레임을 받았다(2026-10-10 결함: 직전 요청의 버퍼가 다시 전달됨).
        public var sourceTimeMatches: Bool? = nil
        /// 요청 순서(startRequest 호출 순, 1부터)와 시작 시각. 완료 순서는 기록 순서(entries 배열 순서)다.
        public var seq: Int = 0
        public var startedUptimeNs: UInt64 = 0
    }
    public struct Snapshot: Sendable { public let entries: [Entry]; public let errors: [String]; public let cancelled: Int; public let maxInFlight: Int }
    // 안전성: 가변 상태는 lock 안에서만 접근한다.
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var errors: [String] = []
    private var cancelled = 0, inFlight = 0, maxInFlight = 0
    private var seqCounter = 0
    private var events: [String] = []
    public let fingerprints: Bool
    /// 진단용: 받은 소스 프레임의 코드를 읽어 기록한다(요청마다 수 ms 추가).
    public let diagnoseSource: Bool
    /// 진단용: 처음 본 소스 버퍼의 첨부(attachment) 키
    private var _sourceAttachmentKeys: [String] = []
    public init(fingerprints: Bool, diagnoseSource: Bool = false) { self.fingerprints = fingerprints; self.diagnoseSource = diagnoseSource }
    func noteAttachments(_ keys: [String]) { lock.lock(); if _sourceAttachmentKeys.isEmpty { _sourceAttachmentKeys = keys }; lock.unlock() }
    public var sourceAttachmentKeys: [String] { lock.lock(); defer { lock.unlock() }; return _sourceAttachmentKeys }
    func began() { lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock() }
    /// startRequest 호출 순서 번호(reset과 무관하게 계속 증가)
    func nextSeq() -> Int { lock.lock(); defer { lock.unlock() }; seqCounter += 1; return seqCounter }
    /// 진단 사건(취소 요청, 렌더 컨텍스트 변경, 시험 표시)
    public func event(_ s: String) { lock.lock(); events.append("\(Clock.now() / 1_000_000) ms: \(s)"); lock.unlock() }
    public var eventLog: [String] { lock.lock(); defer { lock.unlock() }; return events }
    func ended() { lock.lock(); inFlight -= 1; lock.unlock() }
    func record(_ e: Entry) { lock.lock(); entries.append(e); lock.unlock() }
    func error(_ s: String) { lock.lock(); errors.append(s); lock.unlock() }
    func cancel() { lock.lock(); cancelled += 1; lock.unlock() }
    public func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return Snapshot(entries: entries, errors: errors, cancelled: cancelled, maxInFlight: maxInFlight) }
    public func reset() { lock.lock(); entries = []; errors = []; cancelled = 0; maxInFlight = inFlight; lock.unlock() }
}

/// 끝 유지용으로 미리 디코딩해 둔 마지막 유효 프레임의 소스 이미지.
/// 안전성(@unchecked Sendable): 생성 후 픽셀을 바꾸지 않고 읽기 전용으로만 쓴다.
public final class HeldFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public let timelineFrame: Int
    init(buffer: CVPixelBuffer, timelineFrame: Int) { self.buffer = buffer; self.timelineFrame = timelineFrame }
}

// MARK: - 합성 명령과 합성기

/// 안전성(@unchecked Sendable): 모든 저장 속성이 let이고, 참조하는 객체(Overlay, E2Log, HeldFrame)는 스레드 안전하다.
public final class E2Instruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public let videoTrackID: CMPersistentTrackID
    public let overlay: Overlay
    public let log: E2Log
    public let lastValidFrame: Int
    public let held: HeldFrame

    init(timeRange: CMTimeRange, videoTrackID: CMPersistentTrackID, overlay: Overlay, log: E2Log, lastValidFrame: Int, held: HeldFrame) {
        self.timeRange = timeRange; self.videoTrackID = videoTrackID; self.overlay = overlay; self.log = log
        self.lastValidFrame = lastValidFrame; self.held = held
        requiredSourceTrackIDs = [NSNumber(value: videoTrackID)]
    }
}

struct E2RequestBox: @unchecked Sendable { let request: AVAsynchronousVideoCompositionRequest }

/// 실제 소스 영상 프레임(디코딩된 BGRA)을 출력 버퍼에 복사하고 그 위에 오버레이를 그린다.
/// 안전성(@unchecked Sendable): renderContext·generation은 lock 안에서만, 요청 처리는 직렬 queue에서만 한다(E1과 같은 규칙).
public final class E2Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    public let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]
    private let queue = DispatchQueue(label: "e2.compositor")
    private let lock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?
    private var generation = 0
    /// 진단 사건을 남길 기록(첫 요청에서 명령으로부터 얻는다). lock 안에서만 접근한다.
    private var eventLog: E2Log?

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.lock(); renderContext = newRenderContext; let l = eventLog; lock.unlock()
        l?.event("renderContextChanged \(newRenderContext.size.width)x\(newRenderContext.size.height)")
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let startedAt = Clock.now()
        let insLog = (request.videoCompositionInstruction as? E2Instruction)?.log
        let seq = insLog?.nextSeq() ?? 0
        lock.lock(); let gen = generation; if eventLog == nil { eventLog = insLog }; lock.unlock()
        let box = E2RequestBox(request: request)
        queue.async { [self] in
            let r = box.request
            guard let ins = r.videoCompositionInstruction as? E2Instruction else { r.finish(with: E1Error.render("unexpected instruction")); return }
            ins.log.began(); defer { ins.log.ended() }
            lock.lock(); let current = generation; let ctx = renderContext; lock.unlock()
            if current != gen { ins.log.cancel(); ins.log.event("cancelled seq \(seq) t \(r.compositionTime.value)/\(r.compositionTime.timescale)"); r.finishCancelledRequest(); return }
            guard let ctx, let out = ctx.newPixelBuffer() else { ins.log.error("no render context/buffer"); r.finish(with: E1Error.render("no buffer")); return }
            let (n, exact) = Self.frameIndex(r.compositionTime)
            let content = min(max(n, 0), ins.lastValidFrame)
            let src = r.sourceFrame(byTrackID: ins.videoTrackID)
            let useHeld = n > ins.lastValidFrame
            guard let image = useHeld ? ins.held.buffer : src else {
                ins.log.error("source frame nil at frame \(n)"); r.finish(with: E1Error.render("source frame nil at \(n)")); return
            }
            let t0 = Clock.now()
            do {
                try Self.copy(image, into: out)
                let t1 = Clock.now()
                try withContext(out) { _ = ins.overlay.draw(frame: content, ctx: $0) }
                let t2 = Clock.now()
                let fp = ins.log.fingerprints ? Fingerprint.sampled(out) : nil
                var e = E2Log.Entry(timeValue: r.compositionTime.value, timescale: r.compositionTime.timescale, frame: n, content: content, exact: exact,
                                    usedHeld: useHeld, sourceFrameNil: src == nil, copyMs: Clock.ms(t0, t1), overlayMs: Clock.ms(t1, t2),
                                    fingerprint: fp, finishedUptimeNs: 0)
                if ins.log.diagnoseSource {
                    let m = E2Metrics.measure(image)
                    e.receivedSourceID = m?.sourceID; e.receivedSourceFrame = m?.sourceFrame
                    if let s = CVPixelBufferGetIOSurface(image) { e.sourceSurfaceID = IOSurfaceGetID(s.takeUnretainedValue()) }
                    if let a = CVBufferCopyAttachments(image, .shouldPropagate) as? [String: Any] { ins.log.noteAttachments(a.keys.sorted()) }
                }
                // 소스 프레임 시각 검사(항상): 결함을 덮지 않고 기록한다. 받은 이미지를 바꾸거나 버리지 않는다.
                if !useHeld, let mt = SourceMovieTime.read(image) {
                    e.sourceMovieTime = "\(mt.value)/\(mt.timescale)"
                    // 허용 0.1 ms(2026-10-10, E3): 서로 다른 시간 단위 사이의 반올림 차이(예: 359980/600과 599966666667/1e9,
                    // 둘 다 599.9667 s)를 불일치로 잘못 세지 않게 한다. 프레임 간격(33.3 ms)보다 훨씬 작다.
                    let diff = CMTimeAbsoluteValue(CMTimeSubtract(mt, r.compositionTime))
                    let matches = diff <= CMTime(value: 1, timescale: 10_000)
                    e.sourceTimeMatches = matches
                    if !matches { ins.log.error("stale source frame: request \(r.compositionTime.value)/\(r.compositionTime.timescale) got movie time \(mt.value)/\(mt.timescale)") }
                }
                r.finish(withComposedVideoFrame: out)
                ins.log.record(E2Log.Entry(timeValue: e.timeValue, timescale: e.timescale, frame: e.frame, content: e.content, exact: e.exact,
                                           usedHeld: e.usedHeld, sourceFrameNil: e.sourceFrameNil, copyMs: e.copyMs, overlayMs: e.overlayMs,
                                           fingerprint: e.fingerprint, finishedUptimeNs: Clock.now(), receivedSourceID: e.receivedSourceID,
                                           receivedSourceFrame: e.receivedSourceFrame, sourceSurfaceID: e.sourceSurfaceID,
                                           sourceMovieTime: e.sourceMovieTime, sourceTimeMatches: e.sourceTimeMatches,
                                           seq: seq, startedUptimeNs: startedAt))
            } catch {
                ins.log.error("\(error)"); r.finish(with: error)
            }
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        lock.lock(); generation += 1; let l = eventLog; lock.unlock()
        l?.event("cancelAllPendingVideoCompositionRequests")
        queue.sync {}
    }

    public static func frameIndex(_ t: CMTime) -> (Int, Bool) {
        let v = Int64(t.value) * Int64(Spec4K.fps), ts = Int64(t.timescale)
        return (Int((2 * v + ts) / (2 * ts)), v % ts == 0)
    }

    /// 같은 크기 BGRA 버퍼의 보이는 영역을 행 단위로 복사한다.
    static func copy(_ src: CVPixelBuffer, into dst: CVPixelBuffer) throws {
        guard CVPixelBufferGetWidth(src) == Spec4K.width, CVPixelBufferGetHeight(src) == Spec4K.height,
              CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA else {
            throw E1Error.render("source frame \(CVPixelBufferGetWidth(src))x\(CVPixelBufferGetHeight(src)) fmt \(CVPixelBufferGetPixelFormatType(src))")
        }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
        let s = CVPixelBufferGetBaseAddress(src)!, d = CVPixelBufferGetBaseAddress(dst)!
        let sb = CVPixelBufferGetBytesPerRow(src), db = CVPixelBufferGetBytesPerRow(dst), row = Spec4K.width * 4
        if sb == db && sb == row { memcpy(d, s, row * Spec4K.height); return }
        for y in 0..<Spec4K.height { memcpy(d + y * db, s + y * sb, row) }
    }
}

/// 소스 버퍼의 kCVBufferMovieTimeKey 첨부 읽기(없으면 nil)
public enum SourceMovieTime {
    public static func read(_ pb: CVPixelBuffer) -> CMTime? {
        guard let a = CVBufferCopyAttachment(pb, kCVBufferMovieTimeKey, nil) as? [String: Any],
              let v = (a[kCVBufferTimeValueKey as String] as? NSNumber)?.int64Value,
              let ts = (a[kCVBufferTimeScaleKey as String] as? NSNumber)?.int32Value, ts > 0 else { return nil }
        return CMTime(value: v, timescale: ts)
    }
}

/// 4행마다 1행(보이는 바이트만)의 SHA-256. 전체 해시보다 싸서 재생 중에도 쓸 수 있다. 표본 지문이며 전체 동일성 증명이 아니다.
public enum Fingerprint {
    public static func sampled(_ pb: CVPixelBuffer, rowStep: Int = 4) -> String {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!, bpr = CVPixelBufferGetBytesPerRow(pb)
        var hasher = SHA256()
        for y in stride(from: 0, to: h, by: rowStep) { hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * bpr, count: w * 4)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - composition

/// 안전성(@unchecked Sendable): 생성 후 바꾸지 않는 불변 사본만 담는다.
public struct E2Bundle: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let videoTrackID: CMPersistentTrackID
    public let clipAudioTrackID: CMPersistentTrackID
    public let musicTrackID: CMPersistentTrackID
    public let lastValidFrame: Int
    public let held: HeldFrame
}

public enum E2CompositionBuilder {
    /// 비디오 트랙 1개(편집 구간을 순서대로), 클립 오디오 트랙 1개(같은 구간), 선택 오디오(음악) 트랙 1개.
    /// 프리뷰와 내보내기가 이 함수 하나로 같은 해석을 쓴다.
    /// frameTimingFromSourceTrack: 프레임 타이밍을 비디오 트랙의 샘플에서 얻는다(기본, 2026-10-10 수정).
    /// false는 수정 전 구성(frameDuration 기반)으로, 결함 재현 진단에만 쓴다.
    public static func build(timeline: EditTimeline, sources: [String: URL], music: URL, placement: MusicPlacement,
                             overlay: Overlay, log: E2Log, frameTimingFromSourceTrack: Bool = true) async throws -> E2Bundle {
        guard let last = timeline.lastValidFrame else { throw E1Error.invalidSource("empty timeline: no valid video frame") }
        let comp = AVMutableComposition()
        guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let mt = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw E1Error.render("addMutableTrack failed")
        }
        // 트랙만 보관하면 소유 asset이 해제되어 삽입이 -12780으로 실패한다(2026-10-10 관찰). asset도 함께 보관한다.
        var cache: [String: (AVAssetTrack, AVAssetTrack)] = [:]
        var assets: [AVURLAsset] = []
        for s in timeline.segments {
            if cache[s.source] == nil {
                guard let url = sources[s.source] else { throw E1Error.invalidSource("no file for source \(s.source)") }
                let a = AVURLAsset(url: url)
                assets.append(a)
                guard let v = try await a.loadTracks(withMediaType: .video).first,
                      let au = try await a.loadTracks(withMediaType: .audio).first else { throw E1Error.invalidSource("source \(s.source) tracks") }
                cache[s.source] = (v, au)
            }
            let (v, au) = cache[s.source]!
            let range = CMTimeRange(start: Spec4K.frameTime(s.sourceIn), duration: Spec4K.frameTime(s.length))
            do { try vt.insertTimeRange(range, of: v, at: Spec4K.frameTime(s.start)) } catch { throw E1Error.render("insert video \(s.clip): \(error)") }
            do { try ct.insertTimeRange(range, of: au, at: Spec4K.frameTime(s.start)) } catch { throw E1Error.render("insert clip audio \(s.clip): \(error)") }
        }
        let ma = AVURLAsset(url: music)
        assets.append(ma)
        guard let m = try await ma.loadTracks(withMediaType: .audio).first else { throw E1Error.invalidSource("music track") }
        let mStart = CMTime(value: CMTimeValue(placement.timelineStartMs), timescale: 1000)
        if mStart > .zero { mt.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: mStart)) }
        try mt.insertTimeRange(CMTimeRange(start: CMTime(value: CMTimeValue(placement.sourceInMs), timescale: 1000),
                                           duration: CMTime(value: CMTimeValue(placement.durationMs), timescale: 1000)), of: m, at: mStart)
        let frozen = comp.copy() as! AVComposition
        withExtendedLifetime(assets) {}
        let held: HeldFrame
        do { held = try await decodeHeld(frozen, videoTrackID: vt.trackID, frame: last) } catch { throw E1Error.render("held frame: \(error)") }
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = E2Compositor.self
        vc.frameDuration = Spec4K.frameDuration
        vc.renderSize = CGSize(width: Spec4K.width, height: Spec4K.height)
        // 수정(2026-10-10): 프레임 타이밍을 비디오 트랙 샘플에서 얻는다(AVVideoComposition.h: "frame timing for the video
        // composition is derived from the source asset's track ... If an empty edit is encountered ... up to frameDuration").
        // 수정 전(kCMPersistentTrackID_Invalid, frameDuration 기반)에는 재생을 b프레임에서 시작하면 2프레임 뒤 요청이
        // 직전 요청과 같은 소스 버퍼(같은 IOSurface, 같은 movie time)를 받았다(results/e2-diag-source-*). 소스가 30 fps CFR이고
        // 타임라인 격자와 같으므로 출력 시각은 그대로 n/30이다. 가변·다른 프레임레이트 소스에서는 출력 시각이 소스를 따르므로
        // 제품에서는 별도 결정이 필요하다.
        vc.sourceTrackIDForFrameTiming = frameTimingFromSourceTrack ? vt.trackID : kCMPersistentTrackID_Invalid
        vc.instructions = [E2Instruction(timeRange: CMTimeRange(start: .zero, duration: timeline.duration), videoTrackID: vt.trackID,
                                         overlay: overlay, log: log, lastValidFrame: last, held: held)]
        return E2Bundle(composition: frozen, videoComposition: vc.copy() as! AVVideoComposition, videoTrackID: vt.trackID,
                        clipAudioTrackID: ct.trackID, musicTrackID: mt.trackID, lastValidFrame: last, held: held)
    }

    /// 마지막 유효 프레임의 소스 이미지를 composition 비디오 트랙에서 디코딩해 보관한다(끝 유지용).
    static func decodeHeld(_ comp: AVComposition, videoTrackID: CMPersistentTrackID, frame: Int) async throws -> HeldFrame {
        guard let track = comp.track(withTrackID: videoTrackID) else { throw E1Error.render("held: no video track") }
        let reader = try AVAssetReader(asset: comp)
        reader.timeRange = CMTimeRange(start: Spec4K.frameTime(frame), duration: Spec4K.frameDuration)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = true
        reader.add(out)
        guard reader.startReading() else { throw E1Error.reader("held: \(reader.error?.localizedDescription ?? "-")") }
        var found: CVPixelBuffer?
        while let sb = out.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if let pb = CMSampleBufferGetImageBuffer(sb), pts <= Spec4K.frameTime(frame) { found = pb }
        }
        reader.cancelReading()
        guard let src = found else { throw E1Error.render("held: frame \(frame) not decoded") }
        let copy = try makeBuffer4K()
        try E2Compositor.copy(src, into: copy)
        return HeldFrame(buffer: copy, timelineFrame: frame)
    }
}
