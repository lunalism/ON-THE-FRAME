import AVFoundation
import CoreVideo
import Foundation
import os

/// 자막이 있는 내보내기(2026-10-22, 구조 R, docs/SUBTITLE-DESIGN.md §41–§43). 자막이 없는 프로젝트는 지금까지의 내보내기 세션 경로를 그대로 쓴다.
/// 경로: 기본 합성기(계획의 videoComposition 그대로) 리더 → 타임라인 30 fps 격자의 모든 프레임으로 펼치기 → 자막 발자국 안만 4:2:0으로 합성 → AVAssetWriter.
/// - 리더 출력: 420v, 색 공간 709 선언(AVVideoColorPropertiesKey). 지금 내보내기 세션과 같은 값이 나온다(태그 있는 601·709·태그 없는 원본,
///   한 레이어·두 레이어에서 ±1 코드 안, §42). 지금 내보내기처럼 값은 기본 합성기가 낸 그대로이고 출력은 709로 태그한다.
///   (지금 내보내기는 진짜 601로 태그된 원본을 709로 변환하지 않는다 — 두 경로가 같게 그렇다. §42의 알려진 제품 문제.)
/// - 펼치기: 프레임 k에는 PTS ≤ k/30(유리수 비교)인 마지막 리더 표본을 쓴다. 리더는 바뀌지 않은 프레임(원본 반복·빈틈 검정 이어짐)을
///   다시 내지 않고 표본 길이도 비어 있다(§40). 빈틈 시작에는 검정 표본이 오므로 앞 그림을 빈틈 위로 늘리지 않는다.
/// - 자막이 없는 프레임은 리더 버퍼를 그대로 다시 넣는다(같은 객체, 바꾸지 않음). 자막이 있는 프레임은 쓰기 풀의 새 버퍼에 복사한 뒤 그린다.
/// - 쓰기 설정(제품 출력 정책: 1920×1080, 30 fps, SDR, H.264/AAC MP4): H.264 High(레벨 자동), 평균 10 Mb/s, 키 프레임 최대 간격 30프레임(1초),
///   709 태그. AAC 48 kHz 스테레오 192 kb/s. 지금 내보내기 세션의 프리셋은 비트율을 문서로 밝히지 않아 같게 맞출 수 없다(의도한 차이, 보고함).
enum SubtitleExporter {
    static let log = Logger(subsystem: "dev.ontheframe.app", category: "subtitle-export")
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    nonisolated(unsafe) static let color709: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    nonisolated(unsafe) static let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                          AVVideoMaxKeyFrameIntervalKey: 30, AVVideoExpectedSourceFrameRateKey: 30, AVVideoAllowFrameReorderingKey: true],
        AVVideoColorPropertiesKey: color709]
    nonisolated(unsafe) static let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
    nonisolated(unsafe) static let pcmSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                             AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]

    struct Injected: Error {}

    /// 쓰기. 취소는 작업(Task) 취소, 결과는 성공 또는 오류(CancellationError·Injected·그 밖)다. tempFile만 만든다.
    static func encode(_ p: PlannedComposition, to tempFile: URL, failAfterFraction: Double?, progress: @escaping @Sendable (Double) async -> Void) async throws {
        let n = p.durationFrames
        let footprints = p.subtitles.map { SubtitleFootprint($0, SubtitleRenderer.shared.raster($0)) }
        let reader = try AVAssetReader(asset: p.composition)
        var vs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        vs[AVVideoColorPropertiesKey] = color709
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: vs)
        vOut.videoComposition = p.videoComposition; vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        var aOut: AVAssetReaderAudioMixOutput?
        let aTracks = try await p.composition.loadTracks(withMediaType: .audio)
        if p.hasAudio, !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: pcmSettings)
            o.audioMix = p.audioMix; o.alwaysCopiesSampleData = false
            reader.add(o); aOut = o
        }
        let writer = try AVAssetWriter(outputURL: tempFile, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings); vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()])
        writer.add(vIn)
        let aIn = aOut.map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) }
        if let aIn { aIn.expectsMediaDataInRealTime = false; writer.add(aIn) }
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "SubtitleExporter", code: 1) }
        guard writer.startWriting() else { reader.cancelReading(); throw writer.error ?? NSError(domain: "SubtitleExporter", code: 2) }
        writer.startSession(atSourceTime: .zero)

        let pump = Pump(n: n)
        let io = IO(reader: reader, vOut: vOut, vIn: vIn, adaptor: adaptor, aOut: aOut, aIn: aIn)
        let watcher = Task {   // 진행률: 쓴 프레임 수 / 전체 × 0.99(줄어들지 않게)
            var last = -1
            while !Task.isCancelled {
                let k = pump.written
                if k != last { last = k; await progress(Double(k) / Double(max(1, n)) * ExportService.encodingProgressCap) }
                if let f = failAfterFraction, Double(k) / Double(max(1, n)) >= f { pump.fail(Injected()) }
                if pump.finished { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                group.enter()
                io.vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "dev.ontheframe.subtitle-export.video")) {
                    pump.videoStep(io, footprints) { group.leave() }
                }
                if io.aIn != nil {
                    group.enter()
                    io.aIn!.requestMediaDataWhenReady(on: DispatchQueue(label: "dev.ontheframe.subtitle-export.audio")) {
                        pump.audioStep(io) { group.leave() }
                    }
                }
                group.notify(queue: DispatchQueue(label: "dev.ontheframe.subtitle-export.done")) { cont.resume() }
            }
        } onCancel: { pump.cancel() }
        pump.markFinished()
        watcher.cancel(); _ = await watcher.value
        if let e = pump.error {
            writer.cancelWriting(); reader.cancelReading()
            throw e
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? NSError(domain: "SubtitleExporter", code: 3) }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(n), timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "SubtitleExporter", code: 4) }
        log.info("subtitle export wrote \(n) frames, reader samples \(pump.readerSamples)")
    }

    /// 안전성(@unchecked Sendable): 각 입력은 자기 직렬 큐에서만 쓴다. 설정은 시작 전에 끝난다.
    struct IO: @unchecked Sendable {
        let reader: AVAssetReader, vOut: AVAssetReaderVideoCompositionOutput, vIn: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
        let aOut: AVAssetReaderAudioMixOutput?, aIn: AVAssetWriterInput?
    }

    /// 쓰기 상태(잠금으로 보호). 영상 단계는 영상 큐에서만, 소리 단계는 소리 큐에서만 부른다.
    final class Pump: @unchecked Sendable {
        let n: Int
        private let lock = NSLock()
        private var _error: Error?, _written = 0, _finished = false
        var readerSamples = 0
        private var k = 0, current: CVPixelBuffer?, next: (CMTime, CVPixelBuffer)?, primed = false, videoDone = false, audioDone = false
        init(n: Int) { self.n = n }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
        var written: Int { lock.lock(); defer { lock.unlock() }; return _written }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
        func markFinished() { lock.lock(); _finished = true; lock.unlock() }
        func fail(_ e: Error) { lock.lock(); if _error == nil { _error = e }; lock.unlock() }
        func cancel() { fail(CancellationError()) }

        private func nextSample(_ io: IO) -> (CMTime, CVPixelBuffer)? {
            while let sb = io.vOut.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                readerSamples += 1
                return (CMSampleBufferGetPresentationTimeStamp(sb), pb)
            }
            return nil
        }
        func videoStep(_ io: IO, _ footprints: [SubtitleFootprint], done: () -> Void) {
            func finish() { if !videoDone { videoDone = true; io.vIn.markAsFinished(); done() } }
            if !primed { primed = true; next = nextSample(io) }
            while io.vIn.isReadyForMoreMediaData && !videoDone {
                if error != nil { finish(); return }
                if k >= n { finish(); return }
                let t = CMTime(value: CMTimeValue(k), timescale: 30)
                while let s = next, CMTimeCompare(s.0, t) <= 0 { current = s.1; next = nextSample(io) }
                guard let src = current else { fail(ExportFailure.export("영상 프레임 \(k)을 만들지 못했습니다(합성 출력 없음).")); finish(); return }
                guard CVPixelBufferGetPixelFormatType(src) == SubtitleExporter.pixelFormat, CVPixelBufferGetWidth(src) == 1920, CVPixelBufferGetHeight(src) == 1080 else {
                    fail(ExportFailure.export("합성 출력 형식이 예상과 다릅니다(프레임 \(k)).")); finish(); return
                }
                var out = src
                let vis = footprints.filter { $0.visible(k) }
                if !vis.isEmpty {
                    var o: CVPixelBuffer?
                    guard let pool = io.adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &o) == kCVReturnSuccess, let ob = o,
                          CVPixelBufferGetPixelFormatType(ob) == SubtitleExporter.pixelFormat else { fail(ExportFailure.export("자막 프레임 버퍼를 만들지 못했습니다.")); finish(); return }
                    SubtitleFootprint.copyPlanes(src, ob)
                    CVPixelBufferLockBaseAddress(ob, [])
                    for f in vis { f.composite(ob) }
                    CVPixelBufferUnlockBaseAddress(ob, [])
                    CVBufferPropagateAttachments(src, ob)
                    out = ob
                }
                // 출력 태그는 709(쓰기 설정)다. 버퍼 첨부도 709로 맞춰 쓰기 쪽이 다른 행렬로 바꾸지 않게 한다(값은 그대로, §42).
                CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                if !io.adaptor.append(out, withPresentationTime: t) { fail(ExportFailure.export("프레임 \(k)을 쓰지 못했습니다.")); finish(); return }
                k += 1
                lock.lock(); _written = k; lock.unlock()
            }
        }
        func audioStep(_ io: IO, done: () -> Void) {
            func finish() { if !audioDone { audioDone = true; io.aIn!.markAsFinished(); done() } }
            while io.aIn!.isReadyForMoreMediaData && !audioDone {
                if error != nil { finish(); return }
                guard let sb = io.aOut!.copyNextSampleBuffer() else { finish(); return }
                if !io.aIn!.append(sb) { fail(ExportFailure.export("소리를 쓰지 못했습니다.")); finish(); return }
            }
        }
    }
}

/// 자막 한 항목의 4:2:0 합성 발자국(709 계수, 비디오 범위, 색차 위치 Left). 영상 표본은 RGB로 바꾸지 않는다(§36·§37).
/// 미리 곱한 래스터 값에서 바로: a·Y_sub = 16a + 219·Y′(R_p, G_p, B_p), a·C_sub = 128a + 224·(B_p − Y′_p)/1.8556 등(알파 한 번, §37.4).
/// Y_out = Y·(1 − a) + a·Y_sub. 색차는 열 2k−1, 2k, 2k+1(1/4, 1/2, 1/4) × 행 2j, 2j+1(1/2씩)의 알파 가중으로 섞는다.
/// 발자국 밖(밝기: a > 0이 아닌 화소, 색차: 6위치 모두 a = 0)은 쓰지 않는다. 화면 밖 부분은 버린다.
struct SubtitleFootprint: Sendable {
    let start: Int, end: Int
    let yIdx: [Int32], ya: [Float], yaSub: [Float]
    let cIdx: [Int32], cWA: [Float], cWACb: [Float], cWACr: [Float]
    static let w = 1920, h = 1080, cw = 960, ch = 540, kr = 0.2126, kb = 0.0722

    init(_ item: SubtitleItem, _ r: SubtitleRaster) {
        start = item.start; end = item.end
        let img = r.image, iw = img.width, ih = img.height, bpr = img.bytesPerRow
        let x0 = Int(r.rect.minX), y0 = Int(r.rect.minY)
        let data = img.dataProvider!.data! as Data
        // 사각형 안 지역 배열(화면 밖은 0)
        var A = [Double](repeating: 0, count: iw * ih), AY = A, ACb = A, ACr = A
        var yIdx: [Int32] = [], ya: [Float] = [], yaSub: [Float] = []
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<ih { for x in 0..<iw {
                let fx = x0 + x, fy = y0 + y
                guard fx >= 0, fx < Self.w, fy >= 0, fy < Self.h else { continue }
                let o = y * bpr + x * 4
                guard p[o + 3] > 0 else { continue }
                let a = Double(p[o + 3]) / 255, rp = Double(p[o + 2]) / 255, gp = Double(p[o + 1]) / 255, bp = Double(p[o]) / 255
                let yp = Self.kr * rp + (1 - Self.kr - Self.kb) * gp + Self.kb * bp
                let i = y * iw + x
                A[i] = a; AY[i] = 16 * a + 219 * yp
                ACb[i] = 128 * a + 224 * (bp - yp) / (2 * (1 - Self.kb)); ACr[i] = 128 * a + 224 * (rp - yp) / (2 * (1 - Self.kr))
                yIdx.append(Int32(fy * Self.w + fx)); ya.append(Float(a)); yaSub.append(Float(AY[i]))
            } }
        }
        var cIdx: [Int32] = [], cWA: [Float] = [], cWACb: [Float] = [], cWACr: [Float] = []
        let k0 = max(0, (x0 - 1) / 2 - 1), k1 = min(Self.cw - 1, (x0 + iw + 1) / 2 + 1), j0 = max(0, y0 / 2 - 1), j1 = min(Self.ch - 1, (y0 + ih) / 2 + 1)
        if k0 <= k1 && j0 <= j1 {
            for j in j0...j1 { for k in k0...k1 {
                var swa = 0.0, scb = 0.0, scr = 0.0, any = false
                for (dx, wx) in [(-1, 0.25), (0, 0.5), (1, 0.25)] { for dy in 0...1 {
                    let x = 2 * k + dx - x0, y = 2 * j + dy - y0
                    guard x >= 0, x < iw, y >= 0, y < ih, 2 * k + dx >= 0, 2 * k + dx < Self.w else { continue }
                    let i = y * iw + x; guard A[i] > 0 else { continue }
                    any = true; swa += wx * 0.5 * A[i]; scb += wx * 0.5 * ACb[i]; scr += wx * 0.5 * ACr[i]
                } }
                if any { cIdx.append(Int32(j * Self.cw + k)); cWA.append(Float(swa)); cWACb.append(Float(scb)); cWACr.append(Float(scr)) }
            } }
        }
        self.yIdx = yIdx; self.ya = ya; self.yaSub = yaSub; self.cIdx = cIdx; self.cWA = cWA; self.cWACb = cWACb; self.cWACr = cWACr
    }
    func visible(_ k: Int) -> Bool { k >= start && k < end }
    /// 잠근 420v 버퍼에 쓴다
    func composite(_ out: CVPixelBuffer) {
        let y = CVPixelBufferGetBaseAddressOfPlane(out, 0)!.assumingMemoryBound(to: UInt8.self), ybpr = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
        let c = CVPixelBufferGetBaseAddressOfPlane(out, 1)!.assumingMemoryBound(to: UInt8.self), cbpr = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
        @inline(__always) func clamp(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        for t in 0..<yIdx.count {
            let i = Int(yIdx[t]), q = y + (i / Self.w) * ybpr + i % Self.w
            q.pointee = clamp(Float(q.pointee) * (1 - ya[t]) + yaSub[t])
        }
        for t in 0..<cIdx.count {
            let i = Int(cIdx[t]), q = c + (i / Self.cw) * cbpr + 2 * (i % Self.cw)
            q[0] = clamp(Float(q[0]) * (1 - cWA[t]) + cWACb[t]); q[1] = clamp(Float(q[1]) * (1 - cWA[t]) + cWACr[t])
        }
    }
    /// 420v 활성 바이트 복사(행 끝 채움 제외)
    static func copyPlanes(_ src: CVPixelBuffer, _ dst: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        for plane in 0..<2 {
            let sb = CVPixelBufferGetBaseAddressOfPlane(src, plane)!, db = CVPixelBufferGetBaseAddressOfPlane(dst, plane)!
            let sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, plane), dbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            let bytes = CVPixelBufferGetWidthOfPlane(src, plane) * (plane == 0 ? 1 : 2)
            for r in 0..<CVPixelBufferGetHeightOfPlane(src, plane) { memcpy(db + r * dbpr, sb + r * sbpr, bytes) }
        }
        CVPixelBufferUnlockBaseAddress(dst, []); CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }
}
