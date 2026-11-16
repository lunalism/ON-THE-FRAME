import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport

/// 제품 시험(SubtitleExportTests)이 쓰는 색 태그 생성 원본·태그 읽기(2026-10-23). 조사 시험 SubtitleColorPolicyTests(선택 실행)의 같은 도우미를
/// 그대로 옮겨 적은 것이다 — 조사 시험 파일은 기록으로 바꾸지 않고 두고, 제품 시험이 조사 시험 파일 없이도 빌드되게 한다.
enum SubtitleColorFixtures {
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
}
