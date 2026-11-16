import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 구조 R 시험 전용 원형(2026-10-22, docs/SUBTITLE-DESIGN.md §41, 채택 아님). 선택 실행(OTF_SB=1).
/// 리더(기본 합성기, 420v 요청) → 30 fps 격자로 프레임 펼치기 → 4:2:0 자막(행렬 709/601, 색차 Left, 미리 곱한 래스터) → AVAssetWriter(H.264/AAC MP4).
/// 임시 위치에 쓰고 성공할 때만 목적지를 바꾼다. 취소·오류 때는 임시 위치를 지우고 목적지를 건드리지 않는다.

/// 행렬(비디오 범위 8비트): Y = 16 + 219·Y′, C = 128 + 224·(B′ − Y′)/(2(1 − Kb)), (R′ − Y′)/(2(1 − Kr))
struct RMatrix: Hashable, Sendable {
    let name: String, kr: Double, kb: Double
    static let bt709 = RMatrix(name: "709", kr: 0.2126, kb: 0.0722), bt601 = RMatrix(name: "601", kr: 0.299, kb: 0.114)
    static func of(_ pb: CVPixelBuffer) -> RMatrix? {
        guard let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String else { return nil }
        if m == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) { return .bt709 }
        if m == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) { return .bt601 }
        return nil
    }
}

/// 자막 하나: 래스터(미리 곱한 sRGB 8비트) + [start, end). 행렬마다 발자국 계수를 한 번 만든다.
final class RSubtitle: @unchecked Sendable {
    struct Compiled { let yIdx: [Int], ya: [Double], yaSub: [Double], cIdx: [Int], cWA: [Double], cWACb: [Double], cWACr: [Double], yMask: [Bool], cMask: [Bool], aYFull: [Int: Double] }
    let name: String, start: Int, end: Int, raster: SubtitleApproachBTests.Raster
    private let px: [(i: Int, a: Double, r: Double, g: Double, b: Double)]
    private var cache: [RMatrix: Compiled] = [:]
    private let lock = NSLock()
    static let w = 1920, h = 1080, cw = 960, ch = 540
    init(_ r: SubtitleApproachBTests.Raster, start: Int, end: Int) {
        name = r.caption.name; self.start = start; self.end = end; raster = r
        let img = r.image, bpr = img.bytesPerRow, data = img.dataProvider!.data! as Data
        let x0 = Int(r.rect.minX), y0 = Int(r.rect.minY)
        precondition(Double(x0) == r.rect.minX && Double(y0) == r.rect.minY && x0 >= 2 && x0 + img.width + 2 <= Self.w && y0 + img.height <= Self.h)
        var out: [(Int, Double, Double, Double, Double)] = []
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<img.height { for x in 0..<img.width {
                let o = y * bpr + x * 4; guard p[o + 3] > 0 else { continue }
                out.append(((y0 + y) * Self.w + x0 + x, Double(p[o + 3]) / 255, Double(p[o + 2]) / 255, Double(p[o + 1]) / 255, Double(p[o]) / 255))
            } }
        }
        px = out.map { (i: $0.0, a: $0.1, r: $0.2, g: $0.3, b: $0.4) }
    }
    func visible(_ k: Int) -> Bool { k >= start && k < end }
    func compiled(_ m: RMatrix) -> Compiled {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[m] { return c }
        var aY = [Int: Double](), aCb = [Int: Double](), aCr = [Int: Double](), A = [Int: Double]()
        var yIdx: [Int] = [], ya: [Double] = [], yaSub: [Double] = [], yMask = [Bool](repeating: false, count: Self.w * Self.h)
        for p in px {   // 미리 곱한 값 그대로: a·Y_sub = 16a + 219·Y′(R_p, G_p, B_p)
            let yp = m.kr * p.r + (1 - m.kr - m.kb) * p.g + m.kb * p.b
            A[p.i] = p.a; aY[p.i] = 16 * p.a + 219 * yp
            aCb[p.i] = 128 * p.a + 224 * (p.b - yp) / (2 * (1 - m.kb)); aCr[p.i] = 128 * p.a + 224 * (p.r - yp) / (2 * (1 - m.kr))
            yIdx.append(p.i); ya.append(p.a); yaSub.append(aY[p.i]!); yMask[p.i] = true
        }
        var cand = Set<Int>()
        for p in px { let x = p.i % Self.w, y = p.i / Self.w; for dk in [-1, 0, 1] { let k = (x + dk) / 2; if (x + dk) >= 0 && k * 2 - 1 <= x && x <= k * 2 + 1 { cand.insert((y / 2) * Self.cw + k) } }; cand.insert((y / 2) * Self.cw + (x + 1) / 2) }
        var cIdx: [Int] = [], cWA: [Double] = [], cWACb: [Double] = [], cWACr: [Double] = [], cMask = [Bool](repeating: false, count: Self.cw * Self.ch)
        for c in cand.sorted() {
            let k = c % Self.cw, j = c / Self.cw
            var swa = 0.0, scb = 0.0, scr = 0.0, any = false
            for (dx, wx) in [(-1, 0.25), (0, 0.5), (1, 0.25)] { for dy in 0...1 {   // 색차 위치 Left: 열 2k−1, 2k, 2k+1 × 행 2j, 2j+1
                let x = 2 * k + dx, y = 2 * j + dy; guard x >= 0, x < Self.w, y < Self.h else { continue }
                let i = y * Self.w + x; guard let a = A[i] else { continue }
                any = true; swa += wx * 0.5 * a; scb += wx * 0.5 * aCb[i]!; scr += wx * 0.5 * aCr[i]!
            } }
            if any { cIdx.append(c); cWA.append(swa); cWACb.append(scb); cWACr.append(scr); cMask[c] = true }
        }
        let comp = Compiled(yIdx: yIdx, ya: ya, yaSub: yaSub, cIdx: cIdx, cWA: cWA, cWACb: cWACb, cWACr: cWACr, yMask: yMask, cMask: cMask, aYFull: aY)
        cache[m] = comp
        return comp
    }
    /// 420v 버퍼(이미 원본을 복사한 것)에 발자국 안만 쓴다
    func composite(_ out: CVPixelBuffer, _ m: RMatrix) {
        let c = compiled(m)
        let y = CVPixelBufferGetBaseAddressOfPlane(out, 0)!.assumingMemoryBound(to: UInt8.self), ybpr = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
        let cp = CVPixelBufferGetBaseAddressOfPlane(out, 1)!.assumingMemoryBound(to: UInt8.self), cbpr = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        for t in 0..<c.yIdx.count { let i = c.yIdx[t], q = y + (i / Self.w) * ybpr + i % Self.w; q.pointee = clamp(Double(q.pointee) * (1 - c.ya[t]) + c.yaSub[t]) }
        for t in 0..<c.cIdx.count {
            let q = cp + (c.cIdx[t] / Self.cw) * cbpr + 2 * (c.cIdx[t] % Self.cw)
            q[0] = clamp(Double(q[0]) * (1 - c.cWA[t]) + c.cWACb[t]); q[1] = clamp(Double(q[1]) * (1 - c.cWA[t]) + c.cWACr[t])
        }
    }
}

enum ROutcome: Equatable { case completed, cancelled, failed(String) }
struct RStats { var readerSamples = 0, offGrid = 0, extraAfterEnd = 0, framesWritten = 0, copies = 0, reused = 0, audioBuffers = 0, retagged = 0
                var matrices: [String: Int] = [:]; var tempDir: URL? }

enum RPrototype {
    /// 실험값(비트율 고정 실험값). 출력 색은 지금 제품 내보내기가 낸 태그(관찰: 모든 경우 709/709/709)와 같게 709로 둔다(§41.2).
    /// 리더 버퍼의 첨부가 601이어도 값은 바꾸지 않고 709로 다시 단다(제품과 같은 결과: 값 그대로 + 709 태그). 자막도 709 계수로 섞는다.
    static let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                          AVVideoExpectedSourceFrameRateKey: 30, AVVideoAllowFrameReorderingKey: true]]
    static let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000]
    struct Hooks: @unchecked Sendable {
        var cancelAt: Int? = nil, failAt: Int? = nil
        /// 리더 출력 색 공간을 709로 선언(AVVideoColorPropertiesKey, §42)
        var readerColor709 = false
        var onFrame: ((Int, CVPixelBuffer, CVPixelBuffer, [RSubtitle], RMatrix?) -> Void)? = nil
    }

    static func export(_ p: PlannedComposition, subtitles: [RSubtitle], to dest: URL, hooks: Hooks = Hooks()) async -> (ROutcome, RStats) {
        var stats = RStats()
        let tempDir: URL
        do { tempDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true) }
        catch { return (.failed("temp: \(error)"), stats) }
        stats.tempDir = tempDir
        let temp = tempDir.appendingPathComponent("output.mp4")
        func cleanup() { try? FileManager.default.removeItem(at: tempDir) }
        let n = p.durationFrames
        do {
            let reader = try AVAssetReader(asset: p.composition)
            var vs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format]
            if hooks.readerColor709 {
                vs[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                 AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
            }
            let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: vs)
            vOut.videoComposition = p.videoComposition; vOut.alwaysCopiesSampleData = false; reader.add(vOut)
            let aTracks = try await p.composition.loadTracks(withMediaType: .audio)
            var aOut: AVAssetReaderAudioMixOutput?
            if !aTracks.isEmpty {
                let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: AudioMixExportTests.pcmSettings)
                o.audioMix = p.audioMix; o.alwaysCopiesSampleData = false; reader.add(o); aOut = o
            }
            let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = false
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings); vIn.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()])
            writer.add(vIn)
            let aIn = aOut.map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) }
            if let aIn { aIn.expectsMediaDataInRealTime = false; writer.add(aIn) }
            guard reader.startReading() else { cleanup(); return (.failed("reader: \(String(describing: reader.error))"), stats) }
            guard writer.startWriting() else { cleanup(); return (.failed("writer: \(String(describing: writer.error))"), stats) }
            writer.startSession(atSourceTime: .zero)

            final class Pump: @unchecked Sendable {
                let lock = NSLock(); var failure: String?; var cancelled = false; var stats = RStats()
                var k = 0; var current: CVPixelBuffer?; var next: (CMTime, CVPixelBuffer)?; var started = false
                func stop() -> Bool { lock.lock(); defer { lock.unlock() }; return failure != nil || cancelled }
                func fail(_ s: String) { lock.lock(); if failure == nil { failure = s }; lock.unlock() }
            }
            struct Box: @unchecked Sendable { let reader: AVAssetReader, vOut: AVAssetReaderVideoCompositionOutput, vIn: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
                                              let aOut: AVAssetReaderAudioMixOutput?, aIn: AVAssetWriterInput? }
            let b = Box(reader: reader, vOut: vOut, vIn: vIn, adaptor: adaptor, aOut: aOut, aIn: aIn)
            let pump = Pump()
            func nextSample() -> (CMTime, CVPixelBuffer)? {
                while let sb = b.vOut.copyNextSampleBuffer() {
                    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                    pump.stats.readerSamples += 1
                    let k = (pts.seconds * 30).rounded()
                    if CMTimeCompare(pts, CMTime(value: CMTimeValue(k), timescale: 30)) != 0 { pump.stats.offGrid += 1 }
                    return (pts, pb)
                }
                return nil
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                group.enter()
                var vDone = false
                b.vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "r.video")) {
                    func finish() { if !vDone { vDone = true; b.vIn.markAsFinished(); group.leave() } }
                    if !pump.started { pump.started = true; pump.next = nextSample() }
                    while b.vIn.isReadyForMoreMediaData && !vDone {
                        if pump.stop() { finish(); return }
                        let k = pump.k
                        if k >= n {   // 끝: 남은 표본(격자 끝 이후)만 센다
                            while let s = pump.next { if CMTimeCompare(s.0, CMTime(value: CMTimeValue(n), timescale: 30)) >= 0 { pump.stats.extraAfterEnd += 1 }; pump.next = nextSample() }
                            finish(); return
                        }
                        if hooks.cancelAt == k { pump.lock.lock(); pump.cancelled = true; pump.lock.unlock(); finish(); return }
                        if hooks.failAt == k { pump.fail("injected failure at frame \(k)"); finish(); return }
                        // 펼치기: PTS ≤ k/30인 마지막 표본(유리수 비교)
                        let t = CMTime(value: CMTimeValue(k), timescale: 30)
                        while let s = pump.next, CMTimeCompare(s.0, t) <= 0 { pump.current = s.1; pump.next = nextSample() }
                        guard let src = pump.current else { pump.fail("no reader image at or before frame \(k)"); finish(); return }
                        guard CVPixelBufferGetPixelFormatType(src) == Passthrough420Compositor.format else { pump.fail("frame \(k): reader format is not 420v"); finish(); return }
                        // 행렬 첨부: 709·601만 받는다(그 밖은 실패). 601이면 값은 그대로 두고 709로 다시 단다(제품 출력과 같게). 같은 버퍼를 다시 쓸 때도 같은 결과(멱등)
                        guard let srcM = RMatrix.of(src) else { pump.fail("frame \(k): unsupported or missing YCbCr matrix"); finish(); return }
                        pump.stats.matrices[srcM.name, default: 0] += 1
                        if srcM != .bt709 {
                            CVBufferSetAttachment(src, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                            CVBufferSetAttachment(src, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                            CVBufferSetAttachment(src, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                            pump.stats.retagged += 1
                        }
                        let vis = subtitles.filter { $0.visible(k) }
                        var out = src
                        var m: RMatrix? = nil
                        if !vis.isEmpty {
                            let mm = RMatrix.bt709   // 출력 행렬
                            let loc = CVBufferCopyAttachment(src, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
                            guard loc == (kCVImageBufferChromaLocation_Left as String) else { pump.fail("frame \(k): chroma location \(loc ?? "none") unsupported"); finish(); return }
                            m = mm
                            var o: CVPixelBuffer?
                            guard let pool = b.adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &o) == kCVReturnSuccess, let ob = o,
                                  CVPixelBufferGetPixelFormatType(ob) == Passthrough420Compositor.format else { pump.fail("frame \(k): no 420v output buffer"); finish(); return }
                            CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(ob, [])
                            for plane in 0..<2 {   // 활성 바이트만(행 끝 채움 제외)
                                let sb = CVPixelBufferGetBaseAddressOfPlane(src, plane)!, obb = CVPixelBufferGetBaseAddressOfPlane(ob, plane)!
                                let sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, plane), obpr = CVPixelBufferGetBytesPerRowOfPlane(ob, plane)
                                let bytes = CVPixelBufferGetWidthOfPlane(src, plane) * (plane == 0 ? 1 : 2)
                                for y in 0..<CVPixelBufferGetHeightOfPlane(src, plane) { memcpy(obb + y * obpr, sb + y * sbpr, bytes) }
                            }
                            for s in vis { s.composite(ob, mm) }
                            CVPixelBufferUnlockBaseAddress(ob, []); CVPixelBufferUnlockBaseAddress(src, .readOnly)
                            CVBufferPropagateAttachments(src, ob)
                            out = ob; pump.stats.copies += 1
                        } else { pump.stats.reused += 1 }
                        hooks.onFrame?(k, src, out, vis, m)
                        if !b.adaptor.append(out, withPresentationTime: t) { pump.fail("append failed at frame \(k)"); finish(); return }
                        pump.stats.framesWritten += 1; pump.k = k + 1
                    }
                }
                if b.aIn != nil {
                    group.enter()
                    var aDone = false
                    b.aIn!.requestMediaDataWhenReady(on: DispatchQueue(label: "r.audio")) {
                        func finish() { if !aDone { aDone = true; b.aIn!.markAsFinished(); group.leave() } }
                        while b.aIn!.isReadyForMoreMediaData && !aDone {
                            if pump.stop() { finish(); return }
                            guard let sb = b.aOut!.copyNextSampleBuffer() else { finish(); return }
                            pump.lock.lock(); pump.stats.audioBuffers += 1; pump.lock.unlock()
                            if !b.aIn!.append(sb) { pump.fail("audio append failed"); finish(); return }
                        }
                    }
                }
                group.notify(queue: DispatchQueue(label: "r.done")) { cont.resume() }
            }
            var s = pump.stats; s.tempDir = tempDir; stats = s
            if pump.cancelled || pump.failure != nil {
                writer.cancelWriting(); reader.cancelReading(); cleanup()
                return (pump.cancelled ? .cancelled : .failed(pump.failure!), stats)
            }
            if reader.status == .failed { writer.cancelWriting(); cleanup(); return (.failed("reader: \(String(describing: reader.error))"), stats) }
            await writer.finishWriting()
            guard writer.status == .completed else { cleanup(); return (.failed("writer: \(String(describing: writer.error))"), stats) }
            if FileManager.default.fileExists(atPath: dest.path) { _ = try FileManager.default.replaceItemAt(dest, withItemAt: temp) }
            else { try FileManager.default.moveItem(at: temp, to: dest) }
            cleanup()
            return (.completed, stats)
        } catch { cleanup(); return (.failed("\(error)"), stats) }
    }
}

extension SubtitleApproachBTests {
    func testApproachBRPrototypeMilestone() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let root = ExportEndToEndTests.root, fx = root.appendingPathComponent("fixtures")
        let dir = root.appendingPathComponent("r-prototype")
        try? FileManager.default.removeItem(at: dir)   // 이 테스트가 만든 일회용 출력만
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func probe(_ f: String) async throws -> MediaAsset {
            let u = f.hasPrefix("../") ? root.appendingPathComponent(String(f.dropFirst(3))) : fx.appendingPathComponent(f)
            guard FileManager.default.fileExists(atPath: u.path) else { throw XCTSkip("fixture \(f) missing (not regenerated)") }
            return try await MediaProbe.inspect(u)
        }
        let ko = Self.raster(Self.captions.first { $0.name == "ko-left" }!), ye = Self.raster(Self.captions.first { $0.name == "overlap-yellow" }!)
        var failures: [String] = []
        func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { failures.append(msg()) } }

        // 리더 표본 시각(빠진 프레임 찾기, 기본 출력 형식 확인)
        func readerScan(_ p: PlannedComposition, native: Bool) async throws -> (pts: [Int], formats: [Int: String]) {
            let r = try AVAssetReader(asset: p.composition)
            let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video),
                                                        videoSettings: native ? nil : [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
            o.videoComposition = p.videoComposition; r.add(o); r.startReading()
            var pts: [Int] = [], formats: [Int: String] = [:]
            while let sb = o.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let k = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded()); pts.append(k)
                let f = CVPixelBufferGetPixelFormatType(pb); formats[k] = String(format: "%c%c%c%c", (f >> 24) & 255, (f >> 16) & 255, (f >> 8) & 255, f & 255)
            }
            return (pts, formats)
        }
        func decodeFrames(_ u: URL, _ frames: Set<Int>) async throws -> [Int: Planes] {
            let a = AVURLAsset(url: u); let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
            r.add(o); r.startReading()
            var out: [Int: Planes] = [:]
            while let sb = o.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb) { let k = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded()); if frames.contains(k) { out[k] = Self.planes(pb) } } }
            return out
        }
        /// 압축 표본 길이(편집 목록 반영)와 개수
        func sampleDurations(_ u: URL) async throws -> (count: Int, allOneFrame: Bool, total: Double) {
            let asset = AVURLAsset(url: u); let t = try await asset.loadTracks(withMediaType: .video).first!
            let r = try AVAssetReader(asset: asset); let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil); r.add(o); r.startReading()
            var c = 0, ok = true, tot = 0.0
            while let sb = o.copyNextSampleBuffer() { guard CMSampleBufferGetNumSamples(sb) > 0 else { continue }; c += 1; let d = CMSampleBufferGetDuration(sb); tot += d.seconds
                if CMTimeCompare(d, CMTime(value: 1, timescale: 30)) != 0 { ok = false } }
            return (c, ok, tot)
        }
        /// 자막 경계 확인(디코딩): 제품 내보내기(자막 없음) 대비 |ΔY| > 40인 글자 화소 비율(§17 T1 정의)
        func boundary(_ s: RSubtitle, _ rDec: [Int: Planes], _ pDec: [Int: Planes], _ n: Int) -> String {
            let r = s.raster, rw = Int(r.rect.width), x0 = Int(r.rect.minX), y0 = Int(r.rect.minY)
            return [s.start - 1, s.start, s.end - 1, s.end].filter { $0 >= 0 && $0 < n }.map { k -> String in
                guard let a = rDec[k], let b = pDec[k] else { return "f\(k) missing" }
                var need = 0, ink = 0
                for i in 0..<(rw * Int(r.rect.height)) where r.alpha[i] >= 128 { let fi = (y0 + i / rw) * 1920 + x0 + i % rw; need += 1; if abs(Int(a.y[fi]) - Int(b.y[fi])) > 40 { ink += 1 } }
                let want = s.visible(k)
                let got = Double(ink) >= 0.25 * Double(need) ? true : (ink == 0 ? false : nil)
                if got != want { failures.append("\(s.name) f\(k) ink \(ink)/\(need) expected \(want)") }
                return "f\(k) \(want ? "on" : "off") ink \(ink)/\(need)"
            }.joined(separator: ", ")
        }
        // 인코딩 전 보존 확인(프레임마다): 자막 없는 프레임은 같은 버퍼, 있는 프레임은 발자국 밖이 같고 안쪽 밝기 = round(a·Y_sub)
        final class PreCheck: @unchecked Sendable { var hiddenNotSame = 0, outside = 0, interiorWrong = 0, visibleFrames = 0 }
        func preHook(_ pc: PreCheck) -> RPrototype.Hooks {
            var h = RPrototype.Hooks()
            h.onFrame = { _, src, out, vis, m in
                if vis.isEmpty { if src !== out { pc.hiddenNotSame += 1 }; return }
                pc.visibleFrames += 1
                let s = Self.planes(src), o = Self.planes(out), cs = vis.map { $0.compiled(m!) }
                for i in 0..<s.y.count where s.y[i] != o.y[i] && !cs.contains(where: { $0.yMask[i] }) { pc.outside += 1 }
                for i in 0..<s.c.count where s.c[i] != o.c[i] && !cs.contains(where: { $0.cMask[i / 2] }) { pc.outside += 1 }
                for (sub, c) in zip(vis, cs) { for (t, i) in c.yIdx.enumerated() where c.ya[t] == 1 && Double(o.y[i]) != c.yaSub[t].rounded() { pc.interiorWrong += 1 }; _ = sub }
            }
            return h
        }

        struct CaseResult { let name: String; let plan: PlannedComposition; let refs: [ExportJudge.ClipRef]?; let subs: [RSubtitle]; let rURL: URL; let pURL: URL }
        var results: [CaseResult] = []
        func runCase(_ name: String, _ t: Timeline, media: [MediaAsset], refs: [ExportJudge.ClipRef]?, subs: (PlannedComposition, [Int]) -> [RSubtitle]) async throws {
            let p = try await CompositionPlanner.plan(t, media: Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) }))
            let scan420 = try await readerScan(p, native: false), scanNative = try await readerScan(p, native: true)
            let present = Set(scan420.pts)
            let s = subs(p, (0..<p.durationFrames).filter { !present.contains($0) })
            let nativeFormats = Dictionary(grouping: scanNative.formats.keys.sorted(), by: { scanNative.formats[$0]! }).mapValues { "\($0.first!)–\($0.last!) (\($0.count))" }
            // 제품 내보내기(비교 기준)와 R 내보내기
            let pURL = dir.appendingPathComponent("product-\(name).mp4"), rURL = dir.appendingPathComponent("r-\(name).mp4")
            let po = await ExportService.export(p, to: .fromSavePanel(pURL), sources: media) { _ in }
            check(po == .completed(pURL), "\(name): product export \(po)")
            let pc = PreCheck()
            let t0 = Date()
            let (ro, st) = await RPrototype.export(p, subtitles: s, to: rURL, hooks: preHook(pc))
            check(ro == .completed, "\(name): R export \(ro)")
            check(pc.hiddenNotSame == 0 && pc.outside == 0 && pc.interiorWrong == 0, "\(name): pre-encode hidden≠same \(pc.hiddenNotSame) outside \(pc.outside) interior \(pc.interiorWrong)")
            check(st.framesWritten == p.durationFrames && st.offGrid == 0 && st.extraAfterEnd == 0, "\(name): written \(st.framesWritten)/\(p.durationFrames) offGrid \(st.offGrid) extra \(st.extraAfterEnd)")
            let rd = try await sampleDurations(rURL), pd = try await sampleDurations(pURL)
            check(rd.count == p.durationFrames && rd.allOneFrame, "\(name): R samples \(rd.count) all 1/30 \(rd.allOneFrame)")
            var line = String(format: "CASE %@: frames %d | reader samples %d (missing frames %d) native formats %@ | R %.2f s written %d copies %d reused %d source matrices %@ retagged %d audio buffers %d | pre-encode: visible frames %d, hidden≠same %d, outside-footprint changed %d, interior wrong %d | samples R %d (all 1/30 %@, total %.4f s) product %d (all 1/30 %@, total %.4f s)",
                              name, p.durationFrames, st.readerSamples, p.durationFrames - present.count, "\(nativeFormats)", Date().timeIntervalSince(t0), st.framesWritten, st.copies, st.reused,
                              "\(st.matrices)", st.retagged, st.audioBuffers, pc.visibleFrames, pc.hiddenNotSame, pc.outside, pc.interiorWrong, rd.count, "\(rd.allOneFrame)", rd.total, pd.count, "\(pd.allOneFrame)", pd.total)
            line += " | R tags: \(try await SubtitleABComparisonTests.describe(rURL).components(separatedBy: "| ").last ?? "") | product tags: \(try await SubtitleABComparisonTests.describe(pURL).components(separatedBy: "| ").last ?? "")"
            if let refs {
                for (tag, u) in [("product", pURL), ("R", rURL)] {
                    let v = try await ExportJudge.judge(u, clips: refs, durationFrames: p.durationFrames, checkAudio: false)
                    check(v.pass, "\(name): \(tag) judge mismatched \(v.mismatchedFrames.prefix(8)) frames \(v.frames) notes \(v.notes)")
                    line += " | \(tag) screen code every frame: pass \(v.pass) frames \(v.frames)/\(v.expectedFrames) gaps \(v.gapFrames) mismatched \(v.mismatchedFrames.prefix(5))"
                }
            }
            let bf = Set(s.flatMap { [$0.start - 1, $0.start, $0.end - 1, $0.end] }.filter { $0 >= 0 && $0 < p.durationFrames })
            let rDec = try await decodeFrames(rURL, bf), pDec = try await decodeFrames(pURL, bf)
            for sub in s { line += " | \(sub.name) [\(sub.start), \(sub.end)) start missing-in-reader \(!present.contains(sub.start)) end missing \(!present.contains(sub.end)): \(boundary(sub, rDec, pDec, p.durationFrames))" }
            if name == "sd601" {   // 태그를 따르는 디코딩(BGRA)으로 판 색과 자막 안쪽 색을 제품과 견줌
                func rgbAt(_ u: URL, _ k: Int, _ pts: [(Int, Int)]) async throws -> [String] {
                    let a = AVURLAsset(url: u); let r = try AVAssetReader(asset: a)
                    let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    r.add(o); r.startReading()
                    while let sb = o.copyNextSampleBuffer() {
                        guard let pb = CMSampleBufferGetImageBuffer(sb), Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded()) == k else { continue }
                        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                        let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
                        return pts.map { (x, y) in "(\(b[y * bpr + x * 4 + 2]), \(b[y * bpr + x * 4 + 1]), \(b[y * bpr + x * 4]))" }
                    }
                    return []
                }
                // 노란 자막 안쪽: 알파 255이고 2화소 안이 모두 255인 첫 화소
                let r = s[0].raster, rw = Int(r.rect.width)
                let inner = (0..<(rw * Int(r.rect.height))).first { i in (-2...2).allSatisfy { dy in (-2...2).allSatisfy { dx in let j = i + dy * rw + dx; return j >= 0 && j < r.alpha.count && r.alpha[j] == 255 } } }!
                let ip = (Int(r.rect.minX) + inner % rw, Int(r.rect.minY) + inner / rw)
                let pr = try await rgbAt(pURL, 35, [(960, 300), ip]), rr = try await rgbAt(rURL, 35, [(960, 300), ip])
                line += " | decoded RGB f35 plate (960,300) / subtitle interior \(ip): product \(pr) R \(rr) (intended plate (220, 40, 40), subtitle (255, 230, 26); product has no subtitle)"
            }
            note(line)
            results.append(CaseResult(name: name, plan: p, refs: refs, subs: s, rURL: rURL, pURL: pURL))
        }

        // 1. 섞인 fps(23.976 → 29.97 → 25 → VFR), 자막 경계를 리더가 표본을 내지 않은 프레임(원본 반복)에 둔다
        let mf = ["otf-F23976.mp4", "otf-N2997.mp4", "otf-P25.mp4", "otf-VFR.mp4"]
        var mm: [MediaAsset] = []; for f in mf { mm.append(try await probe(f)) }
        var tm = Timeline(); for m in mm { tm = try tm.registering(m).inserting(media: m.id) }
        let mRefs = tm.clips(inLane: Lane.videoID).map { c in ExportJudge.ClipRef(file: mf[mm.firstIndex { $0.id == c.mediaID }!], start: c.start, sourceIn: c.sourceIn, length: c.length) }
        try await runCase("mixed-fps", tm, media: mm, refs: mRefs) { _, missing in
            let s1 = missing.first { $0 >= 50 }!, e1 = missing.first { $0 >= s1 + 30 }!
            let s2 = missing.first { $0 >= 250 }!, e2 = missing.first { $0 >= s2 + 20 }!
            return [RSubtitle(ko, start: s1, end: e1), RSubtitle(ye, start: s2, end: e2)]
        }
        // 2. 앞 빈틈 10, otf-A, 빈틈 15, otf-B, 끝은 소리만(WAV)이 영상 뒤로 넘어감 → 끝 검정 빈틈. 자막: 앞 빈틈 → A, 가운데 빈틈 안, 끝까지(정확히 타임라인 끝)
        let a = try await probe("otf-A.mp4"), bb = try await probe("otf-B.mp4"), wav = try await probe(AudioFixture.wav.file)
        var tg = Timeline().registering(a).registering(bb).registering(wav)
        tg = try tg.placing(media: a.id, at: 10, videoLane: Lane.videoID, audioLane: Lane.audioID)
        let aEnd = 10 + tg.clips(inLane: Lane.videoID)[0].length
        tg = try tg.placing(media: bb.id, at: aEnd + 15, videoLane: Lane.videoID, audioLane: Lane.audioID)
        let bEnd = aEnd + 15 + tg.clips(inLane: Lane.videoID).first { $0.mediaID == bb.id }!.length
        let a2 = UUID()
        tg = try tg.addingLane(.audio, name: "W", id: a2)
        tg = try tg.placing(media: wav.id, at: bEnd - 30, videoLane: nil, audioLane: a2)
        let gRefs = [ExportJudge.ClipRef(file: "otf-A.mp4", start: 10, sourceIn: 0, length: aEnd - 10), ExportJudge.ClipRef(file: "otf-B.mp4", start: aEnd + 15, sourceIn: 0, length: bEnd - aEnd - 15)]
        try await runCase("gaps-end", tg, media: [a, bb, wav], refs: gRefs) { p, _ in
            [RSubtitle(ko, start: 5, end: 15), RSubtitle(ye, start: aEnd + 3, end: aEnd + 10), RSubtitle(ko, start: p.durationFrames - 40, end: p.durationFrames)]
        }
        // 3. SD 판(601) 노란 자막
        let sd = try await probe("plate-red-640x480.mp4")
        try await runCase("sd601", try Timeline().registering(sd).inserting(media: sd.id), media: [sd], refs: nil) { _, _ in [RSubtitle(ye, start: 20, end: 50)] }
        // 4. 한 타임라인 안에서 기본 출력 형식이 바뀌는 경우: otf-TA [0,120) + 위 레이어 무늬(§18 변형) [60,180)
        let ta = try await probe("otf-TA.mp4"), pat = try await probe("../ab-compare/fixture-pattern-1280x720-120f.mp4")
        let r0 = CompositionPlanner.displayRect(pat, ClipTransform(scale: 0.6, x: 0, y: 0), render: CGSize(width: 1920, height: 1080))
        let xf = ClipTransform(scale: 0.6, x: SubtitleABComparisonTests.layerOrigin.x - r0.minX, y: SubtitleABComparisonTests.layerOrigin.y - r0.minY)
        let top = UUID()
        var tx = try Timeline().registering(ta).registering(pat).inserting(media: ta.id).addingLane(.video, name: "P", id: top, outward: true)
        tx = try tx.placing(media: pat.id, at: 60, videoLane: top, audioLane: nil)
        tx = try tx.settingTransform(clip: tx.clips(inLane: top)[0].id, xf)
        try await runCase("format-switch", tx, media: [ta, pat], refs: [ExportJudge.ClipRef(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 120)]) { _, _ in [RSubtitle(ko, start: 40, end: 140)] }

        // 5. 소리 내용(기존 판정 그대로): AudioMixExportTests 배치(파란 판 + WAV 두 번 + AIFF, 겹침·빈틈)
        let plate = try await probe(PlateFixture.blue.file), aiff = try await probe(AudioFixture.aiff.file)
        let la2 = UUID()
        var ta3 = Timeline(clips: [Clip(mediaID: plate.id, start: 0, sourceIn: 0, length: 90)],
                           audioClips: [Clip(mediaID: wav.id, start: 0, sourceIn: 0, length: 60, lane: Lane.audioID), Clip(mediaID: wav.id, start: 75, sourceIn: 0, length: 15, lane: Lane.audioID),
                                        Clip(mediaID: aiff.id, start: 20, sourceIn: 3, length: 40, lane: la2)],
                           lanes: Lane.defaults + [Lane(id: la2, kind: .audio, name: "둘째", muted: false, volumePercent: 100)])
        for m in [plate, wav, aiff] { ta3 = ta3.registering(m) }
        let pa = try await CompositionPlanner.plan(ta3, media: [plate.id: plate, wav.id: wav, aiff.id: aiff])
        let raURL = dir.appendingPathComponent("r-audio.mp4"), paURL = dir.appendingPathComponent("product-audio.mp4")
        let pao = await ExportService.export(pa, to: .fromSavePanel(paURL), sources: [plate, wav, aiff]) { _ in }
        let (rao, _) = await RPrototype.export(pa, subtitles: [], to: raURL)
        check(pao == .completed(paURL) && rao == .completed, "audio exports \(pao) \(rao)")
        let e = AudioMixExportTests.expect(gain: 100, muted: false)
        func audioJudge(_ s: AudioMixExportTests.Stereo, _ label: String) -> String {   // AudioMixExportTests.judge와 같은 구간·허용치(내보내기 onset ±16)
            func amp(_ x: [Float], _ hz: Double, _ f0: Int, _ f1: Int) -> Double { MultiLaneJudge.toneAmplitude(x, hz: hz, from: f0 * 1_600, to: f1 * 1_600) }
            var rows: [String] = []
            for (ch, x) in [("L", s.l), ("R", s.r)] {
                let wOver = amp(x, 440, 23, 57), fOver = amp(x, 1_000, 23, 57), wOnly = amp(x, 440, 3, 17), fBefore = amp(x, 1_000, 3, 17)
                let gap = AudioMixExportTests.rms(x, from: 61, to: 74), wTail = amp(x, 440, 78, 89), fTail = amp(x, 1_000, 78, 89), on = E2Decoder.onsets(x)
                check(x.count >= 89 * 1_600, "\(label) \(ch) length \(x.count)")
                check(abs(wTail - e.wav) <= 0.02 && fTail < 0.005 && abs(wOver - e.wav) <= 0.02 && abs(wOnly - e.wav) <= 0.02 && abs(fOver - e.aiff) <= 0.02 && fBefore < 0.005 && gap < 0.002,
                      "\(label) \(ch) tones W over \(wOver) only \(wOnly) tail \(wTail) F over \(fOver) before \(fBefore) tail \(fTail) gap \(gap)")
                check(on.count == e.onsets.count && zip(on, e.onsets).allSatisfy { abs($0 - $1) <= 16 }, "\(label) \(ch) onsets \(on) vs \(e.onsets)")
                rows.append(String(format: "%@: length %d, W440 over %.4f only %.4f tail %.4f, F1000 over %.4f before %.5f tail %.5f, gap rms %.5f, onsets %@", ch, x.count, wOver, wOnly, wTail, fOver, fBefore, fTail, gap, "\(on)"))
            }
            return rows.joined(separator: " ; ")
        }
        let dR = try await AudioMixExportTests.decodeMP4(raURL), dP = try await AudioMixExportTests.decodeMP4(paURL)
        check(dR.audioTracks == 1 && dR.channels == 2, "R audio tracks \(dR.audioTracks) channels \(dR.channels)")
        note("AUDIO (AudioMixExportTests layout, same tolerances): R tracks \(dR.audioTracks) ch \(dR.channels) | \(audioJudge(dR.pcm, "R")) || product tracks \(dP.audioTracks) ch \(dP.channels) | \(audioJudge(dP.pcm, "product"))")
        // 같은 계획의 소리를 제품 내보내기와 견줌(길이, 프레임 단위 RMS 포락, onset): 섞인 fps·빈틈 경우
        for c in results where c.plan.hasAudio {
            let r = try await AudioMixExportTests.decodeMP4(c.rURL), p = try await AudioMixExportTests.decodeMP4(c.pURL)
            var maxEnv = 0.0
            let frames = min(r.pcm.l.count, p.pcm.l.count) / 1_600
            for f in 0..<frames { for (x, y) in [(r.pcm.l, p.pcm.l), (r.pcm.r, p.pcm.r)] { maxEnv = max(maxEnv, abs(AudioMixExportTests.rms(x, from: f, to: f + 1) - AudioMixExportTests.rms(y, from: f, to: f + 1))) } }
            let on = (E2Decoder.onsets(r.pcm.l), E2Decoder.onsets(p.pcm.l))
            let onOK = on.0.count == on.1.count && zip(on.0, on.1).allSatisfy { abs($0 - $1) <= 16 }
            check(r.audioTracks == 1 && r.channels == 2 && onOK && maxEnv <= 0.02, "\(c.name) audio vs product: ch \(r.channels) onsets \(on.0) vs \(on.1) env \(maxEnv)")
            note(String(format: "AUDIO %@ vs product: tracks %d ch %d | samples R %d product %d | onsets R %@ product %@ (±16) | max per-frame RMS difference %.4f (≤ 0.02)", c.name, r.audioTracks, r.channels, r.pcm.l.count, p.pcm.l.count, "\(on.0)", "\(on.1)", maxEnv))
        }

        // 6. 생애: 취소·오류(이미 있는 목적지는 그대로), 성공은 목적지를 바꿈
        let mPlan = results.first { $0.name == "mixed-fps" }!.plan
        for (label, hooks) in [("cancel at 200", RPrototype.Hooks(cancelAt: 200)), ("injected failure at 100", RPrototype.Hooks(failAt: 100))] {
            let dest = dir.appendingPathComponent("existing-\(label.replacingOccurrences(of: " ", with: "-")).mp4")
            let original = Data("existing destination — must survive".utf8)
            try original.write(to: dest)
            let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            let (o, st) = await RPrototype.export(mPlan, subtitles: [], to: dest, hooks: hooks)
            let after = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            let kept = (try? Data(contentsOf: dest)) == original
            let tempGone = st.tempDir.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
            check(o != .completed && kept && tempGone && before == after, "\(label): outcome \(o) kept \(kept) temp removed \(tempGone) dir same \(before == after)")
            note("LIFECYCLE \(label): outcome \(o) | frames written before stop \(st.framesWritten) | existing destination unchanged \(kept) | temp dir removed \(tempGone) | destination folder entries unchanged \(before == after)")
        }
        let dest = dir.appendingPathComponent("existing-success.mp4")
        try Data("old".utf8).write(to: dest)
        let (so, _) = await RPrototype.export(mPlan, subtitles: [], to: dest)
        let replaced = (try? await SubtitleABComparisonTests.describe(dest)) ?? "unreadable"
        check(so == .completed, "success replace \(so)")
        note("LIFECYCLE success over existing destination: outcome \(so) | destination now: \(replaced)")
        try? FileManager.default.removeItem(at: dest)
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasPrefix("existing-") { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }

        note("FAILURES: \(failures.isEmpty ? "none" : failures.joined(separator: " | "))")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
