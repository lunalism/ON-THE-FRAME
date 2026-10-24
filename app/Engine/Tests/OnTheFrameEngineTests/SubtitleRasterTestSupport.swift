import CoreGraphics
import Foundation
@testable import OnTheFrameEngine

extension SubtitleRaster {
    /// 시험 전용(2026-10-23): 잘라 낸 그림(drawRect)을 rect 크기의 투명 그림에 다시 놓은 것 — 자르기 전 그림과 화소가 같아야 한다.
    var fullImage: CGImage {
        let w = Int(rect.width), h = Int(rect.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let dst = ctx.data!, ob = ctx.bytesPerRow
        let src = image.dataProvider!.data! as Data, sb = image.bytesPerRow
        let dx = Int(drawRect.minX - rect.minX), dy = Int(drawRect.minY - rect.minY)
        src.withUnsafeBytes { s in
            for r in 0..<image.height where r + dy >= 0 && r + dy < h {
                for c in 0..<image.width where c + dx >= 0 && c + dx < w {
                    memcpy(dst + (r + dy) * ob + (c + dx) * 4, s.baseAddress! + r * sb + c * 4, 4)
                }
            }
        }
        return ctx.makeImage()!
    }
}
