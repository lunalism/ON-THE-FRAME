import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 자막 내보내기(구조 R) 색 정책 조사(2026-10-22, docs/SUBTITLE-DESIGN.md §42). 선택 실행(OTF_SB=1).
/// 태그를 명시한 생성 원본(SD 640×480·HD 1280×720 × 601·709·태그 없음, 단색 판 (220, 40, 40))을 임시 폴더에 만들고,
/// 지금 제품 내보내기(ExportService)·기본 합성기 리더 출력·리더 → 쓰기(값 그대로, 태그 여러 정책)의 디코딩 색과 태그를 견준다.
/// 결과로 "변환인가, 다시 달기인가"를 가른다. 생성물은 일회용 폴더에만 둔다.
final class SubtitleColorPolicyTests: XCTestCase {
    struct Src { let name: String; let w: Int; let h: Int; let tag: String? }   // tag: "601" / "709" / nil
    static let plate: (UInt8, UInt8, UInt8) = (220, 40, 40)

    static func write(_ s: Src, to url: URL) async throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: s.w, AVVideoHeightKey: s.h]
        if let tag = s.tag {
            settings[AVVideoColorPropertiesKey] = tag == "601"
                ? [AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4]
                : [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                                                         kCVPixelBufferWidthKey as String: s.w, kCVPixelBufferHeightKey as String: s.h])
        w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
        for f in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let b = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb!)
            for y in 0..<s.h { for x in 0..<s.w { let o = y * bpr + x * 4; b[o] = plate.2; b[o + 1] = plate.1; b[o + 2] = plate.0; b[o + 3] = 255 } }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            // 원본 BGRA의 색 공간: sRGB로 둔다(쓰기 쪽 변환 기준). 태그 없는 원본도 같다.
            CVBufferSetAttachment(pb!, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
            ad.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished(); await w.finishWriting()
        guard w.status == .completed else { throw NSError(domain: "write", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(String(describing: w.error))"]) }
    }
    /// 파일 디코딩: 420v 값·태그와, 태그를 따르는 BGRA 변환 색(가운데)
    static func sample(_ url: URL, frame: Int = 10) async throws -> String {
        let a = AVURLAsset(url: url); let t = try await a.loadTracks(withMediaType: .video).first!
        func read(_ fmt: OSType) async throws -> CVPixelBuffer? {
            let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: fmt])
            r.add(o); r.startReading()
            while let sb = o.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb), Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded()) == frame { return pb } }
            return nil
        }
        guard let y = try await read(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), let c = try await read(kCVPixelFormatType_32BGRA) else { return "missing" }
        return describe(y: y, bgra: c)
    }
    static func describe(y: CVPixelBuffer, bgra: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(y, .readOnly); CVPixelBufferLockBaseAddress(bgra, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(y, .readOnly); CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        let w = CVPixelBufferGetWidth(y), h = CVPixelBufferGetHeight(y), cx = w / 2, cy = h / 2
        let yp = CVPixelBufferGetBaseAddressOfPlane(y, 0)!.assumingMemoryBound(to: UInt8.self), cp = CVPixelBufferGetBaseAddressOfPlane(y, 1)!.assumingMemoryBound(to: UInt8.self)
        let Y = yp[cy * CVPixelBufferGetBytesPerRowOfPlane(y, 0) + cx], ci = (cy / 2) * CVPixelBufferGetBytesPerRowOfPlane(y, 1) + (cx / 2) * 2
        let b = CVPixelBufferGetBaseAddress(bgra)!.assumingMemoryBound(to: UInt8.self), o = cy * CVPixelBufferGetBytesPerRow(bgra) + cx * 4
        let m = CVBufferCopyAttachment(y, kCVImageBufferYCbCrMatrixKey, nil).map { "\($0)" } ?? "none"
        let p = CVBufferCopyAttachment(y, kCVImageBufferColorPrimariesKey, nil).map { "\($0)" } ?? "none"
        return "YCbCr (\(Y), \(cp[ci]), \(cp[ci + 1])) tags matrix=\(m) prim=\(p) → tag-aware RGB (\(b[o + 2]), \(b[o + 1]), \(b[o]))"
    }
    static func fileTags(_ url: URL) async throws -> String {
        let a = AVURLAsset(url: url); let t = try await a.loadTracks(withMediaType: .video).first!
        let fd = try await t.load(.formatDescriptions).first!, e = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        return "file tags prim=\(e[kCVImageBufferColorPrimariesKey as String].map { "\($0)" } ?? "none") matrix=\(e[kCVImageBufferYCbCrMatrixKey as String].map { "\($0)" } ?? "none")"
    }

    func testColorPolicyTaggedSources() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let dir = ExportEndToEndTests.root.appendingPathComponent("color-policy")
        try? FileManager.default.removeItem(at: dir)   // 이 테스트가 만든 일회용 폴더만
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let srcs = [Src(name: "sd-601", w: 640, h: 480, tag: "601"), Src(name: "sd-709", w: 640, h: 480, tag: "709"), Src(name: "sd-untagged", w: 640, h: 480, tag: nil),
                    Src(name: "hd-601", w: 1280, h: 720, tag: "601"), Src(name: "hd-709", w: 1280, h: 720, tag: "709"), Src(name: "hd-untagged", w: 1280, h: 720, tag: nil)]
        var rows: [String] = []
        for s in srcs {
            let u = dir.appendingPathComponent("src-\(s.name).mp4")
            try await Self.write(s, to: u)
            let m = try await MediaProbe.inspect(u)
            let t = try Timeline().registering(m).inserting(media: m.id)
            let p = try await CompositionPlanner.plan(t, media: [m.id: m])
            // 1. 지금 제품 내보내기
            let pURL = dir.appendingPathComponent("product-\(s.name).mp4")
            let po = await ExportService.export(p, to: .fromSavePanel(pURL), sources: [m]) { _ in }
            XCTAssertEqual(po, .completed(pURL))
            // 2. 기본 합성기 리더 출력(420v·BGRA, 같은 프레임)
            func readerPB(_ fmt: OSType) async throws -> CVPixelBuffer? {
                let r = try AVAssetReader(asset: p.composition)
                let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: fmt])
                o.videoComposition = p.videoComposition; r.add(o); r.startReading()
                while let sb = o.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb), Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded()) == 10 { return pb } }
                return nil
            }
            let ry = try await readerPB(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), rb = try await readerPB(kCVPixelFormatType_32BGRA)
            rows.append("\(s.name) (\(s.w)x\(s.h), written tag \(s.tag ?? "none"))\n    source file: \(try await Self.fileTags(u)) | decoded \(try await Self.sample(u))"
                        + "\n    default-compositor reader: \(ry.flatMap { y in rb.map { Self.describe(y: y, bgra: $0) } } ?? "missing")"
                        + "\n    product export: \(try await Self.fileTags(pURL)) | decoded \(try await Self.sample(pURL))")
        }
        note("intended plate RGB (220, 40, 40). For each source: tags and values at the frame centre.\n  " + rows.joined(separator: "\n  "))

        // 리더 → 쓰기(RPrototype, 값 그대로 + 709 태그)가 제품과 같은 화소를 내는가: 한 레이어(601 태그 SD)와 두 레이어(기본 출력 BGRA)
        func pixel(_ u: URL, _ x: Int, _ y: Int) async throws -> String {
            let a = AVURLAsset(url: u); let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            r.add(o); r.startReading()
            while let sb = o.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb), Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded()) == 10 else { continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
                let ci = (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(pb, 1) + (x / 2) * 2
                return "(\(yp[y * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + x]), \(cp[ci]), \(cp[ci + 1]))"
            }
            return "missing"
        }
        var cmp: [String] = []
        for (label, bottom, top) in [("one layer sd-601", "sd-601", nil), ("two layers sd-601 + hd-709 (scale 0.5)", "sd-601", "hd-709"), ("two layers hd-709 + sd-601 (scale 0.5)", "hd-709", "sd-601"),
                                     ("two layers sd-untagged + hd-untagged", "sd-untagged", "hd-untagged")] as [(String, String, String?)] {
            let mb = try await MediaProbe.inspect(dir.appendingPathComponent("src-\(bottom).mp4"))
            var t = try Timeline().registering(mb).inserting(media: mb.id)
            var media = [mb.id: mb], srcs = [mb]
            if let top {
                let mt = try await MediaProbe.inspect(dir.appendingPathComponent("src-\(top).mp4"))
                let lane = UUID()
                t = try t.registering(mt).addingLane(.video, name: "P", id: lane, outward: true).placing(media: mt.id, at: 0, videoLane: lane, audioLane: nil)
                t = try t.settingTransform(clip: t.clips(inLane: lane)[0].id, ClipTransform(scale: 0.5, x: 0, y: 0))
                media[mt.id] = mt; srcs.append(mt)
            }
            let p = try await CompositionPlanner.plan(t, media: media)
            let pu = dir.appendingPathComponent("cmp-product-\(cmp.count).mp4"), ru = dir.appendingPathComponent("cmp-r-\(cmp.count).mp4")
            _ = await ExportService.export(p, to: .fromSavePanel(pu), sources: srcs) { _ in }
            let (ro, _) = await RPrototype.export(p, subtitles: [], to: ru)
            XCTAssertEqual(ro, .completed)
            let r7 = dir.appendingPathComponent("cmp-r709-\(cmp.count).mp4")
            var h = RPrototype.Hooks(); h.readerColor709 = true
            let (ro7, _) = await RPrototype.export(p, subtitles: [], to: r7, hooks: h)
            XCTAssertEqual(ro7, .completed)
            // 아래 판(가장자리 쪽 x 300, y 540)과 위 판(가운데 960, 540) 값
            cmp.append("\(label): product bottom \(try await pixel(pu, 300, 540)) top \(try await pixel(pu, 960, 540)) \(try await Self.fileTags(pu)) | R bottom \(try await pixel(ru, 300, 540)) top \(try await pixel(ru, 960, 540)) | R(reader 709) bottom \(try await pixel(r7, 300, 540)) top \(try await pixel(r7, 960, 540))")
        }
        note("decoded YCbCr (frame 10) — product export vs reader→writer (values as composed, 709 tag):\n  " + cmp.joined(separator: "\n  "))
    }
    var report: [String] = []
    func note(_ s: String) { report.append(s); print("CP \(s)") }
    override func tearDown() async throws {
        let d = ExportEndToEndTests.root.appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? report.joined(separator: "\n").write(to: d.appendingPathComponent("color-policy.txt"), atomically: true, encoding: .utf8)
    }
}
