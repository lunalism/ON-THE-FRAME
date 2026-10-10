import AVFoundation
import CoreMedia
import CoreVideo
import E1Core
import Foundation

/// 4K BGRA 프레임 측정(합성기 출력, 비디오 출력 전달 버퍼, 레이어 표시 버퍼, 디코딩한 내보내기 모두에 사용).
/// 압축 손실을 견디도록 코드 칸은 가운데 24×24 평균 밝기로 읽는다.
public struct E2Metrics: Codable, Sendable, Equatable {
    public let timelineCode: Int
    public let sourceID: Int
    public let sourceFrame: Int
    public let boxX: Int             // 이동 상자 왼쪽 x(없으면 −1)
    public let captionPixels: [Int]  // 왼쪽·가운데·오른쪽 영역의 흰 픽셀 수(2픽셀 간격 표본)
    public let barHeights: [Int]
    public let background: [Int]     // 배경 측정 위치의 평균 R, G, B

    public static let sourceKeyByID: [Int: String] = Dictionary(uniqueKeysWithValues: SourceVideoSpec.all.map { ($0.idCode, $0.key) })
    public var sourceKey: String { Self.sourceKeyByID[sourceID] ?? "?\(sourceID)" }
    /// 자막 표시 판정용 실험 문턱(흰 픽셀 표본 수). 제품 기준 아님.
    public static let captionThreshold = 1_000
    public var captionShown: [Bool] { captionPixels.map { $0 > Self.captionThreshold } }

    public static func measure(_ pb: CVPixelBuffer) -> E2Metrics? {
        guard CVPixelBufferGetWidth(pb) == Spec4K.width, CVPixelBufferGetHeight(pb) == Spec4K.height,
              CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        @inline(__always) func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = base + y * bpr + x * 4
            return (Int(p[2]), Int(p[1]), Int(p[0]))
        }
        func mean(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> (Int, Int, Int) {
            var r = 0, g = 0, b = 0
            for y in y0..<(y0 + h) { for x in x0..<(x0 + w) { let c = px(x, y); r += c.0; g += c.1; b += c.2 } }
            let n = w * h
            return (r / n, g / n, b / n)
        }
        func code(rowY: Int, bits: Int) -> Int {
            var v = 0
            for b in 0..<bits {
                let x = Spec4K.cellLeft + b * Spec4K.cellPitch + (Spec4K.cellSize - 24) / 2
                let c = mean(x, rowY + (Spec4K.cellSize - 24) / 2, 24, 24)
                v = (v << 1) | ((c.0 + c.1 + c.2) / 3 > 128 ? 1 : 0)
            }
            return v
        }
        var boxX = -1
        for x in 0..<Spec4K.width { let c = px(x, Spec4K.boxScanY); if min(c.0, c.1, c.2) > 200 { boxX = x; break } }
        var caps: [Int] = []
        for a in [CaptionAlignment.left, .center, .right] {
            let r = Spec4K.captionRect(a)
            var n = 0
            for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 2) {
                for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 2) { let c = px(x, y); if min(c.0, c.1, c.2) > 200 { n += 1 } }
            }
            caps.append(n)
        }
        // 막대 높이: 막대 가운데 열과 좌우 ±16 px 열 중 2개 이상이 막대 색이면 그 행을 막대로 본다.
        // 기준선 바로 위 최대 6행은 압축으로 번질 수 있어(질감 영역과 맞닿음) 그 안에서 막대 행이 시작하면 기준선부터 센다.
        // 기록(2026-10-10 …003456Z·…003600Z): 단일 열·기준선 행부터 세던 방식은 디코딩한 내보내기의 프레임 62·63에서 막대 9를 0으로 쟀다.
        var heights: [Int] = []
        let top = Spec4K.barBaselineY - Spec4K.barMaxHeight - 4
        for k in 0..<Spec4K.bandCount {
            let xc = Spec4K.barLeft(k) + Spec4K.barWidth / 2
            func barRow(_ y: Int) -> Bool {
                var n = 0
                for x in [xc - 16, xc, xc + 16] { let c = px(x, y); if c.1 > 120 && c.2 > 150 && c.0 < 160 { n += 1 } }
                return n >= 2
            }
            var start = -1
            for y in stride(from: Spec4K.barBaselineY - 1, through: Spec4K.barBaselineY - 6, by: -1) where barRow(y) { start = y; break }
            var h = 0
            if start >= 0 {
                var y = start
                while y >= top && barRow(y) { y -= 1 }
                h = Spec4K.barBaselineY - 1 - y
            }
            heights.append(h)
        }
        let bg = mean(Int(Spec4K.bgPatch.minX), Int(Spec4K.bgPatch.minY), Int(Spec4K.bgPatch.width), Int(Spec4K.bgPatch.height))
        return E2Metrics(timelineCode: code(rowY: Spec4K.timelineCodeRowY, bits: Spec4K.codeBits),
                         sourceID: code(rowY: Spec4K.sourceIDRowY, bits: Spec4K.sourceIDBits),
                         sourceFrame: code(rowY: Spec4K.sourceFrameRowY, bits: Spec4K.codeBits),
                         boxX: boxX, captionPixels: caps, barHeights: heights, background: [bg.0, bg.1, bg.2])
    }
}

// MARK: - 내보낸 파일 디코딩

public struct E2DecodedFrame: Codable, Sendable {
    public let ptsValue: Int64
    public let ptsTimescale: Int32
    public let metrics: E2Metrics?
}

public struct E2Decoded: Sendable {
    public var frames: [E2DecodedFrame] = []
    public var videoTrackRange: CMTimeRange = .zero
    public var audioTrackRange: CMTimeRange = .zero
    public var videoFormat: [String: String] = [:]
    public var audioFormat = ""
    public var mono: [Float] = []
    public var fileBytes: UInt64 = 0
    public var wallSeconds = 0.0
}

public enum E2Decoder {
    public static func decode(_ url: URL) async throws -> E2Decoded {
        let t0 = Clock.now()
        var out = E2Decoded()
        out.fileBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let asset = AVURLAsset(url: url)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first,
              let at = try await asset.loadTracks(withMediaType: .audio).first else { throw E1Error.verificationFailed("missing tracks") }
        out.videoTrackRange = try await vt.load(.timeRange)
        out.audioTrackRange = try await at.load(.timeRange)
        if let fd = try await vt.load(.formatDescriptions).first {
            let d = CMVideoFormatDescriptionGetDimensions(fd)
            out.videoFormat["dimensions"] = "\(d.width)x\(d.height)"
            out.videoFormat["codec"] = fourCC(CMFormatDescriptionGetMediaSubType(fd))
            let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
            for k in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
                out.videoFormat[k as String] = (ext[k as String] as? String) ?? "-"
            }
        }
        if let fd = try await at.load(.formatDescriptions).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            out.audioFormat = "\(fourCC(asbd.mFormatID)) \(asbd.mSampleRate)Hz ch=\(asbd.mChannelsPerFrame)"
        }
        let vr = try AVAssetReader(asset: asset)
        let vo = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vo.alwaysCopiesSampleData = false
        vr.add(vo)
        guard vr.startReading() else { throw E1Error.reader(vr.error?.localizedDescription ?? "video read") }
        while let sb = vo.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            out.frames.append(E2DecodedFrame(ptsValue: pts.value, ptsTimescale: pts.timescale, metrics: E2Metrics.measure(pb)))
        }
        if vr.status == .failed { throw E1Error.reader(vr.error?.localizedDescription ?? "video read failed") }
        out.mono = try decodeMono(asset: asset, track: at)
        out.wallSeconds = Double(Clock.now() - t0) / 1e9
        return out
    }

    /// 오디오 트랙을 48 kHz 스테레오 float로 읽어 (L+R)/2
    public static func decodeMono(asset: AVAsset, track: AVAssetTrack) throws -> [Float] {
        let ar = try AVAssetReader(asset: asset)
        let ao = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        ao.alwaysCopiesSampleData = false
        ar.add(ao)
        guard ar.startReading() else { throw E1Error.reader(ar.error?.localizedDescription ?? "audio read") }
        var mono: [Float] = []
        var scratch: [Float] = []
        while let sb = ao.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb), n = len / 4
            if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
            _ = scratch.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            var i = 0
            while i + 1 < n { mono.append(0.5 * (scratch[i] + scratch[i + 1])); i += 2 }
        }
        if ar.status == .failed { throw E1Error.reader(ar.error?.localizedDescription ?? "audio read failed") }
        return mono
    }

    /// 클릭 onset(샘플): 인접 샘플 차이 > 0.3, 50 ms 안의 연속 검출은 하나로 본다(E1과 같은 규칙).
    public static func onsets(_ x: [Float]) -> [Int] {
        var out: [Int] = []
        var last = -1_000_000
        for i in 1..<max(1, x.count) where abs(x[i] - x[i - 1]) > 0.3 {
            if i - last > 2400 { out.append(i); last = i }
        }
        return out
    }

    static func fourCC(_ v: UInt32) -> String {
        String(bytes: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? "\(v)"
    }
}

// MARK: - 실험 소유 산출물 예산

public enum OwnedBudget {
    public static let limitBytes: UInt64 = 2 << 30
    /// 두 실험(E1, E2)의 artifacts/와 .build/ 합계
    public static func usage(experimentsDir: URL) -> [String: UInt64] {
        var d: [String: UInt64] = [:]
        for e in ["e1-fhd", "e2-4k"] { for s in ["artifacts", ".build"] {
            d["\(e)/\(s)"] = DiskUsage.allocatedBytes(experimentsDir.appendingPathComponent(e).appendingPathComponent(s))
        } }
        return d
    }
    public static func total(experimentsDir: URL) -> UInt64 { usage(experimentsDir: experimentsDir).values.reduce(0, +) }
    /// 예상 추가량을 더해도 한도 안인지. 넘으면 budgetExceeded.
    public static func check(experimentsDir: URL, adding: UInt64) throws {
        let t = total(experimentsDir: experimentsDir)
        if t + adding > limitBytes {
            throw E1Error.budgetExceeded("owned \(t >> 20) MiB + planned \(adding >> 20) MiB > \(limitBytes >> 20) MiB")
        }
    }
}
