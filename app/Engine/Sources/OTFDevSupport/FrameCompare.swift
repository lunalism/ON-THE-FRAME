import AVFoundation
import CoreVideo
import Foundation

/// 프리뷰 프레임(무압축)과 내보낸 H.264를 디코딩한 프레임의 화소 비교(PSNR).
/// 같은 프레임인지는 화면의 원본 코드·검정 판정(ExportJudge)으로 정확히 본다. 여기서는 그 위에 화면 전체가
/// 손실 압축 오차 범위 안에서 같은지(위치·크기·색 변환이 같은지)를 본다. 비트 단위 같음은 요구하지 않는다.
public enum FrameCompare {
    /// BGRA 화소 사본(고정 크기)
    public struct Frame: Sendable {
        public let width: Int, height: Int
        public let bgra: [UInt8]
    }

    public static func copy(_ pb: CVPixelBuffer) -> Frame {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { dst in
            for y in 0..<h { memcpy(dst.baseAddress! + y * w * 4, base + y * bpr, w * 4) }
        }
        return Frame(width: w, height: h, bgra: out)
    }

    /// 내보낸 파일에서 지정한 프레임 번호의 화소를 읽는다(BGRA)
    public static func decode(_ url: URL, frames wanted: Set<Int>) async throws -> [Int: Frame] {
        let asset = AVURLAsset(url: url)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else { return [:] }
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        o.alwaysCopiesSampleData = false
        r.add(o)
        guard r.startReading() else { return [:] }
        var out: [Int: Frame] = [:], n = 0
        while let sb = o.copyNextSampleBuffer() {
            if wanted.contains(n), let pb = CMSampleBufferGetImageBuffer(sb) { out[n] = copy(pb) }
            n += 1
            if out.count == wanted.count { r.cancelReading(); break }
        }
        return out
    }

    /// RGB PSNR(dB). 2화소 간격 표본. 완전히 같으면 +∞. 크기가 다르면 0.
    public static func psnr(_ a: Frame, _ b: Frame, step: Int = 2) -> Double {
        guard a.width == b.width, a.height == b.height else { return 0 }
        var se = 0.0, n = 0
        a.bgra.withUnsafeBufferPointer { pa in
            b.bgra.withUnsafeBufferPointer { pb in
                var y = 0
                while y < a.height {
                    var x = 0
                    while x < a.width {
                        let i = (y * a.width + x) * 4
                        for c in 0..<3 { let d = Double(pa[i + c]) - Double(pb[i + c]); se += d * d }
                        n += 3; x += step
                    }
                    y += step
                }
            }
        }
        let mse = se / Double(max(n, 1))
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// 블록 평균 PSNR(dB): block×block 화소 평균(RGB)끼리 비교. 압축 잡음은 평균에서 줄고, 위치·크기·색 변환 오류는 남는다.
    public static func blockPSNR(_ a: Frame, _ b: Frame, block: Int = 16) -> Double {
        guard a.width == b.width, a.height == b.height else { return 0 }
        let bw = a.width / block, bh = a.height / block
        var se = 0.0
        func means(_ f: Frame) -> [Double] {
            var m = [Double](repeating: 0, count: bw * bh * 3)
            f.bgra.withUnsafeBufferPointer { p in
                for by in 0..<bh { for bx in 0..<bw {
                    var acc = (0.0, 0.0, 0.0)
                    for y in (by * block)..<((by + 1) * block) { for x in (bx * block)..<((bx + 1) * block) {
                        let i = (y * f.width + x) * 4
                        acc.0 += Double(p[i]); acc.1 += Double(p[i + 1]); acc.2 += Double(p[i + 2])
                    } }
                    let k = Double(block * block), j = (by * bw + bx) * 3
                    m[j] = acc.0 / k; m[j + 1] = acc.1 / k; m[j + 2] = acc.2 / k
                } }
            }
            return m
        }
        let ma = means(a), mb = means(b)
        for i in ma.indices { let d = ma[i] - mb[i]; se += d * d }
        let mse = se / Double(ma.count)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// 대조용: 가로로 dx화소 민 사본(빈 곳은 검정)
    public static func shifted(_ f: Frame, dx: Int) -> Frame {
        var out = [UInt8](repeating: 0, count: f.bgra.count)
        for y in 0..<f.height { for x in 0..<f.width where x - dx >= 0 && x - dx < f.width {
            let s = (y * f.width + x - dx) * 4, d = (y * f.width + x) * 4
            out[d] = f.bgra[s]; out[d + 1] = f.bgra[s + 1]; out[d + 2] = f.bgra[s + 2]; out[d + 3] = f.bgra[s + 3]
        } }
        return Frame(width: f.width, height: f.height, bgra: out)
    }
    /// 대조용: R과 B를 바꾼 사본(색 채널 순서 오류)
    public static func swappedRB(_ f: Frame) -> Frame {
        var out = f.bgra
        var i = 0
        while i < out.count { out.swapAt(i, i + 2); i += 4 }
        return Frame(width: f.width, height: f.height, bgra: out)
    }
}
