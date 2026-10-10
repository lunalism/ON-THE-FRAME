import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// 비디오 "운반" 트랙용 작은 검은 영상(160×90, 30fps, 10 s, H.264). 합성기는 이 트랙의 픽셀을 쓰지 않고,
/// 재생기가 비디오 트랙에 실제 미디어가 있다고 보게 하는 시간 축 역할만 한다.
/// 인코더 출력이 실행마다 비트 단위로 같다는 보장이 없으므로, 없을 때만 만들고 해시를 기록한다.
public enum CarrierVideo {
    public static let width = 160, height = 90

    /// 파일이 없으면 만든다(기존 파일은 덮어쓰지 않음). 실험 소유 임시 이름에 쓴 뒤 RENAME_EXCL로 옮긴다.
    public static func ensure(at url: URL) async throws -> (created: Bool, sha256: String) {
        if FileManager.default.fileExists(atPath: url.path) { return (false, try Hashing.sha256(file: url)) }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".e1-carrier-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw E1Error.writer(writer.error?.localizedDescription ?? "carrier startWriting") }
        writer.startSession(atSourceTime: .zero)
        for n in 0..<Spec.frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw E1Error.writer("carrier pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let b = pb else { throw E1Error.writer("carrier buffer") }
            PixelFill.black(b)
            guard adaptor.append(b, withPresentationTime: Spec.frameTime(n)) else { throw E1Error.writer("carrier append") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw E1Error.writer("carrier finish \(writer.status.rawValue)") }
        try OutputGuard.promote(tmp, to: url)
        return (true, try Hashing.sha256(file: url))
    }
}

enum PixelFill {
    static func black(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt32.self)
        let n = CVPixelBufferGetDataSize(pb) / 4
        for i in 0..<n { base[i] = 0xFF00_0000 }   // BGRA little-endian: A=255, RGB=0
    }
}
