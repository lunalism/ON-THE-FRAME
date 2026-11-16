import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 리더(기본 합성기, 420v) → AVAssetWriter 가능성 실험(2026-10-22, docs/SUBTITLE-DESIGN.md §39, 자막 없음 — 구조 R 채택 아님). 선택 실행(OTF_SB=1).
/// §18 타임라인(otf-TA 아래 + 1280×720 색 무늬 위, 원본 화소당 0.9 출력 화소, (720.25, 410.5))을 SubtitleABComparisonTests.setup과 같은 코드로 다시 만든다.
/// 쓰기 설정은 문서화된 키로 명시한다(프리셋 내부 설정을 재현한다고 주장하지 않음). 결과: .build/test-work/reader-writer/
extension SubtitleApproachBTests {
    func testApproachBReaderWriterExport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let root = ExportEndToEndTests.root, ab = root.appendingPathComponent("ab-compare")
        let patURL = ab.appendingPathComponent("fixture-pattern-1280x720-120f.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: patURL.path), "§18 pattern fixture missing (not regenerated here)")
        // 1. 계획(SubtitleABComparisonTests.setup과 같은 코드)
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4")), pat = try await MediaProbe.inspect(patURL)
        let render = CGSize(width: 1920, height: 1080)
        let r0 = CompositionPlanner.displayRect(pat, ClipTransform(scale: 0.6, x: 0, y: 0), render: render)
        let xf = ClipTransform(scale: 0.6, x: SubtitleABComparisonTests.layerOrigin.x - r0.minX, y: SubtitleABComparisonTests.layerOrigin.y - r0.minY)
        let layer = CompositionPlanner.displayRect(pat, xf, render: render)
        let top = UUID()
        var t = try Timeline().registering(ta).registering(pat).inserting(media: ta.id).addingLane(.video, name: "P", id: top, outward: true)
        t = try t.placing(media: pat.id, at: 0, videoLane: top, audioLane: nil)
        t = try t.settingTransform(clip: t.clips(inLane: top)[0].id, xf)
        let p = try await CompositionPlanner.plan(t, media: [ta.id: ta, pat.id: pat])
        XCTAssertNil(p.videoComposition.customVideoCompositorClass)
        note("plan: frames \(p.durationFrames) render \(p.videoComposition.renderSize) top layer \(layer) (pattern \(pat.naturalSize) → \(layer.width / 1280) output px per source px) | hasAudio \(p.hasAudio) | videoComposition primaries \(p.videoComposition.colorPrimaries ?? "nil") instructions \(p.videoComposition.instructions.count)")

        // 2. 쓰기 설정(기준의 측정 데이터율을 명시값으로)
        let base = ab.appendingPathComponent("h264-base.mp4")
        let baseAsset = AVURLAsset(url: base)
        let bv = try await baseAsset.loadTracks(withMediaType: .video).first!, ba = try await baseAsset.loadTracks(withMediaType: .audio).first
        let vRate = Int((try await bv.load(.estimatedDataRate)).rounded())
        let aMeasured = Int((try await ba?.load(.estimatedDataRate) ?? 128000).rounded())
        let aRate = [64000, 96000, 128000, 160000, 192000, 256000].min { abs($0 - aMeasured) < abs($1 - aMeasured) }!
        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: vRate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoExpectedSourceFrameRateKey: 30, AVVideoAllowFrameReorderingKey: true],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ]
        let aSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: aRate]
        note("writer settings: video \(vSettings) | audio \(aSettings) | (baseline measured video \(vRate) b/s, audio \(aMeasured) b/s → nearest standard AAC rate \(aRate))")

        // 3. 읽기 → 쓰기(준비될 때만 꺼냄)
        let dir = root.appendingPathComponent("reader-writer")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("h264-reader-writer-empty.mp4")
        try? FileManager.default.removeItem(at: dest)   // 이 테스트가 만든 이전 출력만
        let reader = try AVAssetReader(asset: p.composition)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
        vOut.videoComposition = p.videoComposition; vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        let audioTracks = try await p.composition.loadTracks(withMediaType: .audio)
        var aOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                                                                                           AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
            o.audioMix = p.audioMix; o.alwaysCopiesSampleData = false; reader.add(o); aOut = o
        }
        let writer = try AVAssetWriter(outputURL: dest, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings); vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        let aIn = aOut.map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings) }
        if let aIn { aIn.expectsMediaDataInRealTime = false; writer.add(aIn) }
        XCTAssertTrue(reader.startReading(), "\(String(describing: reader.error))")
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        final class State: @unchecked Sendable {
            let lock = NSLock(); var ref: [Int: Planes] = [:]; var formats = Set<OSType>(); var attach = Set<String>(); var errors: [String] = []
            var videoFrames = 0, audioBuffers = 0, maxInFlight = 0
            func with<T>(_ f: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(self) }
        }
        let st = State()
        struct RW: @unchecked Sendable {   // 아래 펌프 클로저가 쓰는 AVFoundation 객체(각 입력은 자기 직렬 큐에서만 씀)
            let reader: AVAssetReader, writer: AVAssetWriter, vIn: AVAssetWriterInput, vOut: AVAssetReaderVideoCompositionOutput
            let aIn: AVAssetWriterInput?, aOut: AVAssetReaderAudioMixOutput?
        }
        let rw = RW(reader: reader, writer: writer, vIn: vIn, vOut: vOut, aIn: aIn, aOut: aOut)
        let t0 = Date()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            var vDone = false
            rw.vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "rw.video")) {
                while rw.vIn.isReadyForMoreMediaData && !vDone {
                    guard let sb = rw.vOut.copyNextSampleBuffer() else { vDone = true; rw.vIn.markAsFinished(); group.leave(); return }
                    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                    let f = CVPixelBufferGetPixelFormatType(pb), n = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded())
                    let at = Self.attachmentsSummary(pb)
                    st.with { $0.formats.insert(f); $0.attach.insert(at); $0.videoFrames += 1 }
                    guard f == Passthrough420Compositor.format, at.contains("YCbCrMatrix=ITU_R_709_2") else {
                        st.with { $0.errors.append("frame \(n): format \(f) attachments \(at)") }; vDone = true; rw.vIn.markAsFinished(); rw.reader.cancelReading(); group.leave(); return
                    }
                    let planes = Self.planes(pb)
                    st.with { $0.ref[n] = planes }
                    if !rw.vIn.append(sb) { st.with { $0.errors.append("video append failed at \(n): \(String(describing: rw.writer.error))") }; vDone = true; rw.vIn.markAsFinished(); rw.reader.cancelReading(); group.leave(); return }
                }
            }
            if rw.aIn != nil, rw.aOut != nil {
                group.enter()
                var aDone = false
                rw.aIn!.requestMediaDataWhenReady(on: DispatchQueue(label: "rw.audio")) {
                    while rw.aIn!.isReadyForMoreMediaData && !aDone {
                        guard let sb = rw.aOut!.copyNextSampleBuffer() else { aDone = true; rw.aIn!.markAsFinished(); group.leave(); return }
                        st.with { $0.audioBuffers += 1 }
                        if !rw.aIn!.append(sb) { st.with { $0.errors.append("audio append failed: \(String(describing: rw.writer.error))") }; aDone = true; rw.aIn!.markAsFinished(); group.leave(); return }
                    }
                }
            }
            group.notify(queue: DispatchQueue(label: "rw.done")) { cont.resume() }
        }
        await writer.finishWriting()
        let elapsed = Date().timeIntervalSince(t0)
        note(String(format: "write: reader status %d error %@ | writer status %d error %@ | %.2f s | video frames read %d, audio buffers %d | received formats %@ | attachments %@ | errors %@",
                    reader.status.rawValue, String(describing: reader.error), writer.status.rawValue, String(describing: writer.error), elapsed,
                    st.videoFrames, st.audioBuffers, "\(st.formats.map { String(format: "%c%c%c%c", ($0 >> 24) & 255, ($0 >> 16) & 255, ($0 >> 8) & 255, $0 & 255) })", "\(st.attach)", "\(st.errors)"))
        XCTAssertTrue(st.errors.isEmpty); XCTAssertEqual(writer.status, .completed)
        guard st.errors.isEmpty, writer.status == .completed else { return }   // 멈춤 조건: 장애를 적고 멈춘다

        // 4. 출력 확인
        let outAsset = AVURLAsset(url: dest)
        let ov = try await outAsset.loadTracks(withMediaType: .video).first!, oa = try await outAsset.loadTracks(withMediaType: .audio).first
        let segs = try await ov.load(.segments)
        let fd = try await ov.load(.formatDescriptions).first!
        let avcc = ((CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any])?["avcC"] as? Data).map { [UInt8]($0) } ?? []
        let baseFD = try await bv.load(.formatDescriptions).first!
        let baseAvcc = ((CMFormatDescriptionGetExtension(baseFD, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any])?["avcC"] as? Data).map { [UInt8]($0) } ?? []
        let aDesc: String
        if let oa {
            let afd = try await oa.load(.formatDescriptions).first!, asbd = CMAudioFormatDescriptionGetStreamBasicDescription(afd)!.pointee, ar = try await oa.load(.timeRange)
            aDesc = String(format: "audio %@ %.0f Hz ch %d range %.4f+%.4f s rate %.0f b/s", CMFormatDescriptionGetMediaSubType(afd) == kAudioFormatMPEG4AAC ? "AAC" : "other", asbd.mSampleRate, asbd.mChannelsPerFrame, ar.start.seconds, ar.duration.seconds, try await oa.load(.estimatedDataRate))
        } else { aDesc = "NO AUDIO" }
        let baseAR = try await ba?.load(.timeRange)
        note("output: \(try await SubtitleABComparisonTests.describe(dest)) | \(aDesc) | asset duration \(String(format: "%.4f", try await outAsset.load(.duration).seconds)) s | video edit segments \(segs.map { "media \($0.timeMapping.source.start.value)/\($0.timeMapping.source.start.timescale) → track \($0.timeMapping.target.start.value)" }) | avcC \(avcc.count) bytes profile \(avcc.count > 3 ? Int(avcc[1]) : -1) level \(avcc.count > 3 ? Int(avcc[3]) : -1) | baseline avcC profile \(baseAvcc.count > 3 ? Int(baseAvcc[1]) : -1) level \(baseAvcc.count > 3 ? Int(baseAvcc[3]) : -1) identical \(avcc == baseAvcc) | baseline audio range \(baseAR.map { String(format: "%.4f+%.4f", $0.start.seconds, $0.duration.seconds) } ?? "none")")
        let (expected, _) = try ExportJudge.expectations([.init(file: "otf-TA.mp4", sourceIn: 0, length: 120)], durationFrames: p.durationFrames)
        _ = expected
        for (tag, u) in [("baseline", base), ("reader-writer", dest)] {
            let v = try await ExportJudge.judge(u, clips: [.init(file: "otf-TA.mp4", sourceIn: 0, length: p.durationFrames)], durationFrames: p.durationFrames, checkAudio: false)
            note("\(tag): screen code (bottom otf-TA source frame) pass \(v.pass) frames \(v.frames) mismatched \(v.mismatchedFrames.prefix(5))")
            XCTAssertTrue(v.pass, tag)
        }

        // 5. 비교(4:2:0 평면, 참조 = 리더 출력)
        let W = N420Layer.w, cw = N420Layer.cw
        var inY = [Bool](repeating: false, count: W * 1080), outY = inY, inC = [Bool](repeating: false, count: cw * 540), outC = inC
        for y in 0..<1080 { for x in 0..<W {
            if x >= 722 && x <= 1870 && y >= 412 && y <= 1056 { inY[y * W + x] = true }
            if x < 718 || x > 1875 || y < 408 || y > 1061 { outY[y * W + x] = true }
        } }
        for j in 0..<540 { for k in 0..<cw {
            if k >= 362 && k <= 934 && j >= 207 && j <= 527 { inC[j * cw + k] = true }
            if k < 358 || k > 938 || j < 203 || j > 531 { outC[j * cw + k] = true }
        } }
        let ref = st.ref
        XCTAssertEqual(ref.count, 120)
        // 5a. 리더 출력 자체: 위 레이어 밖이 원본 디코딩과 같은가
        var srcDiffY = 0, srcDiffC = 0, srcN = 0
        do {
            let a = AVURLAsset(url: fixtures.appendingPathComponent("otf-TA.mp4")); let rd = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
            rd.add(o); rd.startReading()
            while let sb = o.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb), let r = ref[Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded())] else { continue }
                let s = Self.planes(pb); srcN += 1
                for i in 0..<s.y.count where outY[i] && s.y[i] != r.y[i] { srcDiffY += 1 }
                for i in 0..<s.c.count where outC[i / 2] && s.c[i] != r.c[i] { srcDiffC += 1 }
            }
        }
        note("reader output vs source decode outside the top layer (\(srcN) frames): differing Y \(srcDiffY), CbCr bytes \(srcDiffC)")
        // 5b. 내보내기들 대 참조
        struct Acc { var n = 0, sqY = 0.0, aY = 0.0, aCb = 0.0, aCr = 0.0, cN = 0, fY = 0.0, fYN = 0, fC = 0.0, fCN = 0 }
        var rows: [String] = []
        for (tag, u) in [("baseline (export session)", base), ("reader-writer", dest), ("A (BGRA compositor, export session)", ab.appendingPathComponent("h264-A.mp4")), ("B-empty (tool, export session)", ab.appendingPathComponent("h264-B-empty.mp4"))] {
            var acc = [Acc](repeating: Acc(), count: 3)   // 0 전체, 1 위 레이어 안, 2 위 레이어 밖
            var prevY: [[Int16]] = [[], [], []], prevC: [[Int16]] = [[], [], []]
            let a = AVURLAsset(url: u); let rd = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
            rd.add(o); rd.startReading()
            var frames = 0, ptsBad = 0
            while let sb = o.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb), n = Int((pts.seconds * 30).rounded())
                if CMTimeCompare(pts, CMTime(value: CMTimeValue(n), timescale: 30)) != 0 { ptsBad += 1 }
                guard let r = ref[n] else { continue }
                frames += 1
                let q = Self.planes(pb)
                for reg in 0..<3 {
                    var eY: [Int16] = [], eC: [Int16] = []
                    for i in stride(from: 0, to: q.y.count, by: 2) where reg == 0 || (reg == 1 ? inY[i] : outY[i]) {
                        let d = Int(q.y[i]) - Int(r.y[i]); eY.append(Int16(d)); acc[reg].n += 1; acc[reg].sqY += Double(d * d); acc[reg].aY += Double(abs(d))
                    }
                    for i in 0..<q.c.count where reg == 0 || (reg == 1 ? inC[i / 2] : outC[i / 2]) {
                        let d = Int(q.c[i]) - Int(r.c[i]); eC.append(Int16(d))
                        if i & 1 == 0 { acc[reg].aCb += Double(abs(d)) } else { acc[reg].aCr += Double(abs(d)); acc[reg].cN += 1 }
                    }
                    if !prevY[reg].isEmpty {
                        for i in 0..<eY.count { acc[reg].fY += Double(abs(Int(eY[i]) - Int(prevY[reg][i]))) }; acc[reg].fYN += eY.count
                        for i in 0..<eC.count { acc[reg].fC += Double(abs(Int(eC[i]) - Int(prevC[reg][i]))) }; acc[reg].fCN += eC.count
                    }
                    prevY[reg] = eY; prevC[reg] = eC
                }
            }
            let names = ["whole", "inside top layer", "outside top layer"]
            rows.append("\(tag): frames \(frames) PTS≠n/30 \(ptsBad)\n    " + (0..<3).map { reg in
                let x = acc[reg], mse = x.sqY / Double(max(1, x.n))
                return String(format: "%@: Y mean|Δ| %.3f PSNR %.2f dB | Cb |Δ| %.3f Cr |Δ| %.3f | error flicker Y %.3f C %.3f", names[reg], x.aY / Double(max(1, x.n)), 10 * log10(65025 / max(1e-9, mse)),
                              x.aCb / Double(max(1, x.cN)), x.aCr / Double(max(1, x.cN)), x.fY / Double(max(1, x.fYN)), x.fC / Double(max(1, x.fCN)))
            }.joined(separator: "\n    "))
        }
        note("decoded 420v vs reader reference (pre-encode default compositor; luma 2-px sampled; flicker = mean |e(n) − e(n−1)|):\n  " + rows.joined(separator: "\n  "))
    }
}
