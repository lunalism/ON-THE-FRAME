import AVFoundation
import CryptoKit
import CoreMedia
import CoreVideo
import Foundation

/// 내보낸 파일 디코딩 결과. 프레임은 측정값만 남기고 픽셀은 보관하지 않는다.
public struct DecodedVideoFrame: Sendable {
    public let pts: CMTime
    public let metrics: FrameMetrics
    public let psnr: Double?
    /// 디코딩된 BGRA 프레임의 SHA-256(요청 시). 두 내보내기 경로의 디코딩 결과 비교용
    public let hash: String?
}

public struct DecodedExport: Sendable {
    public var frames: [DecodedVideoFrame] = []
    public var videoTrackRange: CMTimeRange = .zero
    public var audioTrackRange: CMTimeRange = .zero
    public var videoFormat: [String: String] = [:]
    public var audioFormat: String = ""
    public var audioFirstPTS: CMTime = .invalid
    public var audioPrimingTrimFrames: Double?   // 첫 버퍼의 TrimDurationAtStart(있으면)
    public var mono: [Float] = []                // (L+R)/2, 48 kHz
    public var audioFrames = 0
    public var fileBytes: UInt64 = 0
    public var wallSeconds = 0.0
}

public enum Decoder {
    /// reference: 같은 프레임 번호의 렌더 결과(PSNR 진단용). nil이면 PSNR 생략.
    public static func decode(_ url: URL, captionRect: CGRect, reference: FrameRenderer?, hashFrames: Bool = true) async throws -> DecodedExport {
        let t0 = Clock.now()
        var out = DecodedExport()
        out.fileBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let asset = AVURLAsset(url: url)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first,
              let at = try await asset.loadTracks(withMediaType: .audio).first else {
            throw E1Error.verificationFailed("missing tracks")
        }
        out.videoTrackRange = try await vt.load(.timeRange)
        out.audioTrackRange = try await at.load(.timeRange)
        if let fd = try await vt.load(.formatDescriptions).first {
            let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
            for k in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
                out.videoFormat[k as String] = (ext[k as String] as? String) ?? "-"
            }
            let st = CMFormatDescriptionGetMediaSubType(fd)
            out.videoFormat["codec"] = fourCC(st)
            let d = CMVideoFormatDescriptionGetDimensions(fd)
            out.videoFormat["dimensions"] = "\(d.width)x\(d.height)"
        }
        if let fd = try await at.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            out.audioFormat = "\(fourCC(asbd.mFormatID)) \(asbd.mSampleRate)Hz ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel)"
        }

        // 비디오
        let vr = try AVAssetReader(asset: asset)
        let vo = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vo.alwaysCopiesSampleData = false
        vr.add(vo)
        guard vr.startReading() else { throw E1Error.reader(vr.error?.localizedDescription ?? "video read") }
        let ref = reference == nil ? nil : try FrameRenderer.makeBuffer()
        var index = 0
        while let sb = vo.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let m = FrameMetrics.measure(pb, captionRect: captionRect)
            var psnr: Double?
            if let r = reference, let rb = ref {
                try r.render(frame: index, into: rb)
                psnr = PSNR.compute(pb, rb)
            }
            out.frames.append(DecodedVideoFrame(pts: CMSampleBufferGetPresentationTimeStamp(sb), metrics: m, psnr: psnr,
                                                hash: hashFrames ? PixelCompare.sha256(pb) : nil))
            index += 1
        }
        if vr.status == .failed { throw E1Error.reader(vr.error?.localizedDescription ?? "video read failed") }

        // 오디오
        let ar = try AVAssetReader(asset: asset)
        let ao = AVAssetReaderTrackOutput(track: at, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        ao.alwaysCopiesSampleData = false
        ar.add(ao)
        guard ar.startReading() else { throw E1Error.reader(ar.error?.localizedDescription ?? "audio read") }
        var scratch: [Float] = []
        var first = true
        while let sb = ao.copyNextSampleBuffer() {
            if first {
                out.audioFirstPTS = CMSampleBufferGetPresentationTimeStamp(sb)
                if let trim = CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) {
                    out.audioPrimingTrimFrames = CMTimeMakeFromDictionary((trim as! CFDictionary)).seconds * 48_000
                }
                first = false
            }
            let n = copyFloats(sb, into: &scratch)
            var i = 0
            while i + 1 < n { out.mono.append(0.5 * (scratch[i] + scratch[i + 1])); i += 2 }
        }
        if ar.status == .failed { throw E1Error.reader(ar.error?.localizedDescription ?? "audio read failed") }
        out.audioFrames = out.mono.count
        out.wallSeconds = Double(Clock.now() - t0) / 1e9
        return out
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }
}

public enum PSNR {
    /// BGR 채널 전체 프레임 PSNR(dB). 진단 지표일 뿐 판정 기준이 아니다.
    public static func compute(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
        var se: UInt64 = 0
        for y in 0..<Spec.height {
            let la = pa + y * ra, lb = pb + y * rb
            for x in 0..<Spec.width {
                for c in 0..<3 {
                    let d = Int(la[x * 4 + c]) - Int(lb[x * 4 + c])
                    se += UInt64(d * d)
                }
            }
        }
        let mse = Double(se) / Double(Spec.width * Spec.height * 3)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }
}

/// 버퍼의 보이는 영역(행 패딩 제외) 바이트 비교·해시
public enum PixelCompare {
    public static func equal(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool { diffBox(a, b) == nil }

    /// 다른 픽셀의 경계 상자(위쪽-왼쪽 원점). 같으면 nil.
    public static func diffBox(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt32.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt32.self)
        let ra = CVPixelBufferGetBytesPerRow(a) / 4, rb = CVPixelBufferGetBytesPerRow(b) / 4
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<Spec.height {
            for x in 0..<Spec.width where pa[y * ra + x] != pb[y * rb + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 보이는 영역(1920×1080×4 바이트, 행 패딩 제외)의 SHA-256. 크기·포맷이 다르면 "size:..." 문자열.
    public static func sha256(_ pb: CVPixelBuffer) -> String {
        guard CVPixelBufferGetWidth(pb) == Spec.width, CVPixelBufferGetHeight(pb) == Spec.height,
              CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else {
            return "size:\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) fmt:\(CVPixelBufferGetPixelFormatType(pb))"
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var h = SHA256()
        for y in 0..<Spec.height { h.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * bpr, count: Spec.width * 4)) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 버퍼 전체(패딩 포함)를 바이트 값으로 채운다(더러운 버퍼 재사용 검사용).
    public static func fill(_ pb: CVPixelBuffer, byte: UInt8) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        memset(CVPixelBufferGetBaseAddress(pb)!, Int32(byte), CVPixelBufferGetDataSize(pb))
    }
}
