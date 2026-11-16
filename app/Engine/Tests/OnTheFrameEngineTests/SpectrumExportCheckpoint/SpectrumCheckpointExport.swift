import AVFoundation
import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import os

// 스펙트럼 내보내기 점검(2026-10-25, docs/SPECTRUM-DESIGN.md §12) — 시험 대상 안의 따로 둔 내보내기 경로. 제품 내보내기(ExportService·SubtitleExporter)는 바꾸지 않는다.
// 구조 R과 같은 차례: 기본 합성기 리더(420v, 709 선언) → 30 fps 격자로 펼치기 → [스펙트럼 발자국 → 자막 발자국] 4:2:0 합성 → 같은 쓰기 설정.
// 소리는 같은 오디오 믹스 출력을 그대로 쓴다. 분석은 제품 엔진(SpectrumAnalysisScheduler, 내보내기용 별도 인스턴스)만 쓴다.
// 그리기 규칙(모양·방향·색)은 시험 설정이며 제품 결정이 아니다(D-S5·D-S6 미정). 겹침 규칙(D-S8)도 정하지 않는다 — 조각을 명시해서 넘긴다.
//
// 그리기: 엔진 SpectrumCanvas(package API, §13 — 다시 쓰는 1920×1080 전체 캔버스, 범위 행만 tightCrop)를 내보내기마다 하나 만든다.
// 프레임마다 그림·발자국을 쌓지 않는다. 밴드 값은 앞서 가는 생산자가 상한(featureAhead) 안에서만 쌓는다.

enum SpectrumCheckpointExport {
    struct Spectrum {
        let source: any SpectrumPCMProvider
        let pieces: [SpectrumSourcePiece]
        let settings: SpectrumAnalysisSettings
        let style: SpectrumStyle
    }
    /// 시험이 고른 프레임의 인코딩 전 버퍼(복사)와 그 프레임 값
    struct Captured { let k: Int; let bands: [Float]; let src: (y: [UInt8], c: [UInt8]); let out: (y: [UInt8], c: [UInt8]); let spectrumBounds: CGRect; let paintedOutsideBounds: Int }
    struct Stats {
        var frames = 0, wroteSpectrumFrames = 0, peakAhead = 0
        var waitMs = 0.0, renderMs = 0.0, compositeMs = 0.0, totalMs = 0.0
        var footprintBeforeMB = 0.0, footprintPeakMB = 0.0, footprintAfterMB = 0.0
        var stages: [String] = []
    }
    /// 생산자(분석) → 소비자(영상 큐) 사이의 상한 있는 밴드 저장소. 소비자는 영상 쓰기 큐(디스패치)에서 막고 기다린다(협력 스레드가 아님).
    final class BandFeed: Sendable {
        struct S { var bands: [Int: [Float]] = [:]; var error: SpectrumAnalysisError?; var peak = 0 }
        let capacity: Int
        private let s = OSAllocatedUnfairLock(initialState: S())
        private let available = DispatchSemaphore(value: 0)
        init(capacity: Int) { self.capacity = capacity }
        var count: Int { s.withLock { $0.bands.count } }
        var peak: Int { s.withLock { $0.peak } }
        func put(_ k: Int, _ v: [Float]) { s.withLock { $0.bands[k] = v; $0.peak = max($0.peak, $0.bands.count) }; available.signal() }
        func fail(_ e: SpectrumAnalysisError) { s.withLock { if $0.error == nil { $0.error = e } }; available.signal() }
        /// 프레임 k의 값을 꺼낸다(꺼내면 지움). 시간 초과·오류면 nil과 이유.
        func take(_ k: Int, timeout: Double) -> Result<[Float], SpectrumAnalysisError> {
            let end = DispatchTime.now() + timeout
            while true {
                let r: Result<[Float], SpectrumAnalysisError>? = s.withLock { st in
                    if let v = st.bands.removeValue(forKey: k) { return .success(v) }
                    if let e = st.error { return .failure(e) }
                    return nil
                }
                if let r { return r }
                if available.wait(timeout: end) == .timedOut { return .failure(.decodeFailed("band feed timeout at frame \(k)")) }
            }
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    static func planesCopy(_ pb: CVPixelBuffer) -> (y: [UInt8], c: [UInt8]) {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        func plane(_ i: Int, _ w: Int, _ h: Int) -> [UInt8] {
            let b = CVPixelBufferGetBaseAddressOfPlane(pb, i)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, i)
            var o = [UInt8](repeating: 0, count: w * h)
            for r in 0..<h { for x in 0..<w { o[r * w + x] = b[r * bpr + x] } }
            return o
        }
        return (plane(0, 1920, 1080), plane(1, 1920, 540))
    }

    /// 엔진 캔버스로 그 프레임의 스펙트럼 발자국(칠한 곳이 없으면 nil)과 칠할 범위. checkOutside면 범위 밖에 칠한 화소 수(전체 훑기 — 시험이 고른 프레임만).
    static func footprint(_ canvas: SpectrumCanvas, _ v: [Float], style: SpectrumStyle, frame k: Int, checkOutside: Bool) throws -> (SubtitleFootprint?, CGRect, Int) {
        guard let r = try canvas.render(v, style: style) else { return (nil, .null, 0) }
        let outside = checkOutside ? canvas.paintedPixels(outside: r.bounds) : 0
        return (SubtitleFootprint(SubtitleItem(lane: UUID(), start: k, length: 1, text: "spectrum"), r.subtitleRaster), r.bounds, outside)
    }

    /// 출력 보호·임시 파일·검증·승격은 ExportService와 같은 순서(내부 함수 validate·promote 재사용). capture: 인코딩 전 버퍼를 복사할 프레임.
    static func export(_ p: PlannedComposition, spectrum sp: Spectrum, to d: ExportDestination, sources: [MediaAsset], options: ExportService.Options = .init(),
                       capture: Set<Int> = [], featureAhead: Int = 16, scheduler: SpectrumAnalysisScheduler = SpectrumAnalysisScheduler()) async -> (ExportOutcome, Stats, [Captured]) {
        var stats = Stats(); stats.footprintBeforeMB = footprintMB()
        let t0 = Date()
        func mark(_ s: String) { stats.stages.append(String(format: "%.3f s %@", Date().timeIntervalSince(t0), s)) }
        if let f = ExportService.validate(d, sources: sources) { return (.failed(f), stats, []) }
        if let e = sp.style.validationError() { return (.failed(.export("스펙트럼 모양: \(e)")), stats, []) }
        let tempDir: URL
        do { tempDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: d.url, create: true) }
        catch { return (.failed(.tempUnavailable(error.localizedDescription)), stats, []) }
        options.onTempDirectory?(tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let tempFile = tempDir.appendingPathComponent("output.mp4")
        mark("temp")
        let box = Box()
        let result: Result<Void, Error>
        do { try await encode(p, sp, to: tempFile, options: options, capture: capture, featureAhead: featureAhead, scheduler: scheduler, box: box) { mark($0) }; result = .success(()) }
        catch { result = .failure(error) }
        stats.frames = box.pump?.written ?? 0
        stats.wroteSpectrumFrames = box.pump?.spectrumFrames ?? 0
        stats.peakAhead = box.feed?.peak ?? 0
        stats.waitMs = box.pump?.waitMs ?? 0; stats.renderMs = box.pump?.renderMs ?? 0; stats.compositeMs = box.pump?.compositeMs ?? 0
        stats.footprintPeakMB = box.peakMB.withLock { $0 }
        let captured = box.pump?.captured ?? []
        mark("encode end")
        func finish(_ o: ExportOutcome) -> (ExportOutcome, Stats, [Captured]) { stats.totalMs = Date().timeIntervalSince(t0) * 1000; stats.footprintAfterMB = footprintMB(); return (o, stats, captured) }
        switch result {
        case .failure(let e):
            if e is SubtitleExporter.Injected { return finish(.failed(.injected)) }
            if e is CancellationError || Task.isCancelled { return finish(.cancelled) }
            if let f = e as? ExportFailure { return finish(.failed(f)) }
            return finish(.failed(.export("\(e)")))
        case .success: break
        }
        if Task.isCancelled { return finish(.cancelled) }
        do {
            let a = AVURLAsset(url: tempFile)
            let v = try await a.loadTracks(withMediaType: .video)
            guard v.count == 1 else { return finish(.failed(.verification("video tracks \(v.count)"))) }
            let frames = p.settings.nearestFrame(try await v[0].load(.timeRange).duration)
            guard frames == p.durationFrames else { return finish(.failed(.verification("frames \(frames) != \(p.durationFrames)"))) }
            let au = try await a.loadTracks(withMediaType: .audio)
            guard au.count == (p.hasAudio ? 1 : 0) else { return finish(.failed(.verification("audio tracks \(au.count)"))) }
        } catch { return finish(.failed(.verification(error.localizedDescription))) }
        options.beforePromotion?()
        if Task.isCancelled { return finish(.cancelled) }
        let o = ExportService.promote(tempFile, to: d, sources: sources)
        mark("promoted")
        return finish(o)
    }

    final class Box: @unchecked Sendable {   // 안전성: encode가 끝난 뒤에만 읽는다(peakMB는 잠금)
        var pump: Pump?, feed: BandFeed?
        let peakMB = OSAllocatedUnfairLock(initialState: 0.0)
    }

    static func encode(_ p: PlannedComposition, _ sp: Spectrum, to tempFile: URL, options: ExportService.Options, capture: Set<Int>, featureAhead: Int,
                       scheduler: SpectrumAnalysisScheduler, box: Box, mark: @escaping (String) -> Void) async throws {
        let n = p.durationFrames
        let reader = try AVAssetReader(asset: p.composition)
        var vs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat]
        vs[AVVideoColorPropertiesKey] = SubtitleExporter.color709
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: vs)
        vOut.videoComposition = p.videoComposition; vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        var aOut: AVAssetReaderAudioMixOutput?
        let aTracks = try await p.composition.loadTracks(withMediaType: .audio)
        if p.hasAudio, !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: SubtitleExporter.pcmSettings)
            o.audioMix = p.audioMix; o.alwaysCopiesSampleData = false
            reader.add(o); aOut = o
        }
        let writer = try AVAssetWriter(outputURL: tempFile, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: SubtitleExporter.videoSettings); vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()])
        writer.add(vIn)
        let aIn = aOut.map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: SubtitleExporter.audioSettings) }
        if let aIn { aIn.expectsMediaDataInRealTime = false; writer.add(aIn) }
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "SpectrumCheckpoint", code: 1) }
        guard writer.startWriting() else { reader.cancelReading(); throw writer.error ?? NSError(domain: "SpectrumCheckpoint", code: 2) }
        writer.startSession(atSourceTime: .zero)
        mark("reader/writer started")

        let feed = BandFeed(capacity: featureAhead); box.feed = feed
        let source = sp.source, pieces = sp.pieces, settings = sp.settings
        let producer = Task {   // 차례로 분석(제품 일정, 내보내기용 인스턴스) — 소비자보다 featureAhead 프레임까지만 앞선다
            for k in 0..<n {
                while feed.count >= feed.capacity { if Task.isCancelled { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
                do { feed.put(k, try await scheduler.bands(SpectrumFrameRequest(frame: k, fps: 30, settings: settings, pieces: pieces), from: source)) }
                catch let e as SpectrumAnalysisError { feed.fail(e); return } catch { feed.fail(.cancelled); return }
            }
        }
        let canvas: SpectrumCanvas
        do { canvas = try SpectrumCanvas(width: 1920, height: 1080) } catch { producer.cancel(); writer.cancelWriting(); reader.cancelReading(); throw error }
        let pump = Pump(n: n, style: sp.style, feed: feed, capture: capture, canvas: canvas); box.pump = pump
        let footprints = FootprintWindow(p.subtitles)
        let io = SubtitleExporter.IO(reader: reader, vOut: vOut, vIn: vIn, adaptor: adaptor, aOut: aOut, aIn: aIn)
        let peak = box.peakMB
        let watcher = Task {
            while !Task.isCancelled {
                let mb = footprintMB(); peak.withLock { $0 = max($0, mb) }
                let k = pump.written
                if let f = options.failAfterFraction, Double(k) / Double(max(1, n)) >= f { pump.fail(SubtitleExporter.Injected()) }
                if pump.finished { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                group.enter()
                io.vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "dev.ontheframe.spectrum-checkpoint.video")) { pump.videoStep(io, footprints) { group.leave() } }
                if io.aIn != nil {
                    group.enter()
                    io.aIn!.requestMediaDataWhenReady(on: DispatchQueue(label: "dev.ontheframe.spectrum-checkpoint.audio")) { pump.audioStep(io) { group.leave() } }
                }
                group.notify(queue: DispatchQueue(label: "dev.ontheframe.spectrum-checkpoint.done")) { cont.resume() }
            }
        } onCancel: { pump.cancel(); feed.fail(.cancelled) }
        pump.markFinished()
        producer.cancel(); _ = await producer.value
        watcher.cancel(); _ = await watcher.value
        mark("pump done (frames \(pump.written))")
        if let e = pump.error { writer.cancelWriting(); reader.cancelReading(); throw e }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? NSError(domain: "SpectrumCheckpoint", code: 3) }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(n), timescale: 30))
        await writer.finishWriting()
        mark("writer finished")
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "SpectrumCheckpoint", code: 4) }
    }

    /// SubtitleExporter.Pump와 같은 차례에 스펙트럼 발자국을 자막 앞에 더한 것. 영상 단계는 영상 큐에서만, 소리 단계는 소리 큐에서만 부른다.
    final class Pump: @unchecked Sendable {   // 안전성: 아래 잠금 밖 상태는 영상 큐에서만 쓴다(SubtitleExporter.Pump와 같음)
        let n: Int, style: SpectrumStyle, feed: BandFeed, capture: Set<Int>
        private let lock = NSLock()
        private var _error: Error?, _written = 0, _finished = false
        private var k = 0, current: CVPixelBuffer?, next: (CMTime, CVPixelBuffer)?, primed = false, videoDone = false, audioDone = false
        private let canvas: SpectrumCanvas
        var spectrumFrames = 0, waitMs = 0.0, renderMs = 0.0, compositeMs = 0.0, captured: [Captured] = []
        init(n: Int, style: SpectrumStyle, feed: BandFeed, capture: Set<Int>, canvas: SpectrumCanvas) { self.n = n; self.style = style; self.feed = feed; self.capture = capture; self.canvas = canvas }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
        var written: Int { lock.lock(); defer { lock.unlock() }; return _written }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
        func markFinished() { lock.lock(); _finished = true; lock.unlock() }
        func fail(_ e: Error) { lock.lock(); if _error == nil { _error = e }; lock.unlock() }
        func cancel() { fail(CancellationError()) }
        private func nextSample(_ io: SubtitleExporter.IO) -> (CMTime, CVPixelBuffer)? {
            while let sb = io.vOut.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb) { return (CMSampleBufferGetPresentationTimeStamp(sb), pb) } }
            return nil
        }
        func videoStep(_ io: SubtitleExporter.IO, _ footprints: FootprintWindow, done: () -> Void) {
            func finish() { if !videoDone { videoDone = true; io.vIn.markAsFinished(); done() } }
            if !primed { primed = true; next = nextSample(io) }
            while io.vIn.isReadyForMoreMediaData && !videoDone {
                if error != nil { finish(); return }
                if k >= n { finish(); return }
                let t = CMTime(value: CMTimeValue(k), timescale: 30)
                while let s = next, CMTimeCompare(s.0, t) <= 0 { current = s.1; next = nextSample(io) }
                guard let src = current, CVPixelBufferGetPixelFormatType(src) == SubtitleExporter.pixelFormat, CVPixelBufferGetWidth(src) == 1920, CVPixelBufferGetHeight(src) == 1080 else {
                    fail(ExportFailure.export("영상 프레임 \(k) 없음·형식 다름")); finish(); return
                }
                var c0 = Date()
                let bands: [Float]
                switch feed.take(k, timeout: 30) {
                case .success(let v): bands = v
                case .failure(let e): fail(e == .cancelled ? CancellationError() as Error : ExportFailure.export("스펙트럼 분석 실패(프레임 \(k)): \(e)")); finish(); return
                }
                waitMs += Date().timeIntervalSince(c0) * 1000; c0 = Date()
                let cap = capture.contains(k)
                let fp: SubtitleFootprint?, bounds: CGRect, outside: Int
                do { (fp, bounds, outside) = try SpectrumCheckpointExport.footprint(canvas, bands, style: style, frame: k, checkOutside: cap) }
                catch { fail(ExportFailure.export("스펙트럼 그리기 실패(프레임 \(k)): \(error)")); finish(); return }
                renderMs += Date().timeIntervalSince(c0) * 1000; c0 = Date()
                var out = src
                let subs = footprints.visible(at: k)
                if fp != nil || !subs.isEmpty {
                    var o: CVPixelBuffer?
                    guard let pool = io.adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &o) == kCVReturnSuccess, let ob = o else {
                        fail(ExportFailure.export("프레임 버퍼를 만들지 못했습니다.")); finish(); return
                    }
                    SubtitleFootprint.copyPlanes(src, ob)
                    CVPixelBufferLockBaseAddress(ob, [])
                    fp?.composite(ob)              // 영상 < 스펙트럼
                    for f in subs { f.composite(ob) }   // < 자막(그리기 순서)
                    CVPixelBufferUnlockBaseAddress(ob, [])
                    CVBufferPropagateAttachments(src, ob)
                    out = ob
                    if fp != nil { spectrumFrames += 1 }
                }
                compositeMs += Date().timeIntervalSince(c0) * 1000
                if cap { captured.append(Captured(k: k, bands: bands, src: SpectrumCheckpointExport.planesCopy(src), out: SpectrumCheckpointExport.planesCopy(out), spectrumBounds: bounds, paintedOutsideBounds: outside)) }
                CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                if !io.adaptor.append(out, withPresentationTime: t) { fail(ExportFailure.export("프레임 \(k)을 쓰지 못했습니다.")); finish(); return }
                k += 1
                lock.lock(); _written = k; lock.unlock()
            }
        }
        func audioStep(_ io: SubtitleExporter.IO, done: () -> Void) {
            func finish() { if !audioDone { audioDone = true; io.aIn!.markAsFinished(); done() } }
            while io.aIn!.isReadyForMoreMediaData && !audioDone {
                if error != nil { finish(); return }
                guard let sb = io.aOut!.copyNextSampleBuffer() else { finish(); return }
                if !io.aIn!.append(sb) { fail(ExportFailure.export("소리를 쓰지 못했습니다.")); finish(); return }
            }
        }
    }
}
