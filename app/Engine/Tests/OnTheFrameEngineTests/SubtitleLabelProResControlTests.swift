import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import QuartzCore
import XCTest

/// 보류 "f=NN" 프레임 85의 ProRes 대조 한 쌍(2026-10-21, docs/SUBTITLE-DESIGN.md §25, 실험 — 채택 아님). 선택 실행(OTF_SB=1).
/// §24 보류 검증과 같은 구성(기존 네 자막 + 보류 여섯 자막, 기본 계단)에서 ho-label-color만 뺀 짝을 ProRes 4444로 한 번 만든다.
/// 판정기를 쓰거나 고치지 않는다: PTS·화면 코드를 확인하고, 기존 글자 모양과 마스크 없는 차이 그림으로 프레임 85를 본다.
/// ProRes는 정답이 아니고 H.264와 같은 경로가 아니다(§18.5 색 경로 차이). 리더 + animationTool 경로는 쓰지 않는다.
/// 결과 파일: .build/test-work/sb-local/prores-label-*.png (ProRes 파일은 잰 뒤 지운다)
extension SubtitleApproachBTests {
    func testApproachBLabelFrame85ProResControl() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, _, expected) = try await plan()
        let size = p.videoComposition.renderSize, frames = p.durationFrames
        let rs = (Self.captions + Self.heldOutCaptions).map(Self.raster)
        let target = "ho-label-color"
        let lr = rs.first { $0.caption.name == target }!
        let g = Self.localRegion(lr)
        let keep = ExportEndToEndTests.root.appendingPathComponent("sb-local")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        func prores(_ tag: String, _ items: [(Raster, [Step])]) async throws -> URL {
            let dest = keep.appendingPathComponent("prores-\(tag).mov")
            try? FileManager.default.removeItem(at: dest)
            let s = AVAssetExportSession(asset: p.composition, presetName: AVAssetExportPresetAppleProRes4444LPCM)!
            s.videoComposition = SubtitleABComparisonTests.tool(p.videoComposition, overlay: Self.steppedOverlay(items, size: size, durationFrames: frames))
            s.audioMix = p.audioMix; s.shouldOptimizeForNetworkUse = false
            try await s.export(to: dest, as: .mov)
            return dest
        }
        let all = rs.map { ($0, Self.defaultSteps($0.caption)) }
        let uS = try await prores("all10", all), uC = try await prores("no-\(target)", all.filter { $0.0.caption.name != target })
        note("outputs:\n  all10: \(try await SubtitleABComparisonTests.describe(uS))\n  no-\(target): \(try await SubtitleABComparisonTests.describe(uC))")
        let probe = 83...87
        let s = try await Self.decodeWithPTS(uS, frames: probe), c = try await Self.decodeWithPTS(uC, frames: probe)
        try? FileManager.default.removeItem(at: uS); try? FileManager.default.removeItem(at: uC)   // 약 175 MB씩, 같은 테스트로 다시 만든다

        // PTS와 화면 코드
        var ptsRows: [String] = []
        for (tag, d) in [("all10", s), ("no-\(target)", c)] {
            ptsRows.append("\(tag): " + probe.map { n in
                guard let f = d[n] else { return "\(n):missing" }
                let exact = CMTimeCompare(f.pts, CMTime(value: CMTimeValue(n), timescale: 30)) == 0
                let code = ExportJudge.matches(E2Metrics.measure(Self.pixelBuffer(f.frame)), expected[n])
                return "\(n):\(f.pts.value)/\(f.pts.timescale)\(exact ? "" : " PTS≠")\(code ? "" : " CODE≠")"
            }.joined(separator: " "))
        }
        note("decoded PTS and screen code:\n  " + ptsRows.joined(separator: "\n  "))

        // 프레임별 차이: 전체 프레임(마스크 없음)과 자막 영역(사각형 +12, 글자 자리 K / 그 밖)
        let kset = Set(g.k)
        var rows: [String] = []
        for n in probe {
            guard let a = s[n]?.frame, let b = c[n]?.frame else { continue }
            var nz = 0, mx = 0, bbox = [Int.max, Int.max, Int.min, Int.min], sumY = 0.0, nzOutside = 0
            for y in 0..<a.height { for x in 0..<a.width {
                let i = (y * a.width + x) * 4
                let d = max(abs(Int(a.bgra[i]) - Int(b.bgra[i])), abs(Int(a.bgra[i + 1]) - Int(b.bgra[i + 1])), abs(Int(a.bgra[i + 2]) - Int(b.bgra[i + 2])))
                if d > 0 {
                    nz += 1; mx = max(mx, d); bbox = [min(bbox[0], x), min(bbox[1], y), max(bbox[2], x), max(bbox[3], y)]
                    if !lr.rect.insetBy(dx: -12, dy: -12).contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { nzOutside += 1 }
                }
                sumY += Self.luma(a, x, y) - Self.luma(b, x, y)
            } }
            var kN = 0, kSum = 0, kNZ = 0, oN = 0, oSum = 0, oNZ = 0, kMax = 0, oMax = 0
            for yy in 0..<g.h { for xx in 0..<g.w {
                let x = g.x0 + xx, y = g.y0 + yy, i = (y * a.width + x) * 4
                let d = max(abs(Int(a.bgra[i]) - Int(b.bgra[i])), abs(Int(a.bgra[i + 1]) - Int(b.bgra[i + 1])), abs(Int(a.bgra[i + 2]) - Int(b.bgra[i + 2])))
                if kset.contains(yy * g.w + xx) { kN += 1; kSum += d; kMax = max(kMax, d); if d > 0 { kNZ += 1 } }
                else { oN += 1; oSum += d; oMax = max(oMax, d); if d > 0 { oNZ += 1 } }
            } }
            let want = Self.expectedVisible(lr.caption, frame: n) ? "on" : "off"
            rows.append(String(format: "f%d (expected %@): full frame nonzero %d max %d bbox %@ nonzero outside rect+12 %d mean signed dY %.4f | region glyph K: nonzero %d/%d mean %.3f max %d | region non-glyph: nonzero %d/%d mean %.3f max %d",
                               n, want, nz, mx, nz > 0 ? "\(bbox)" : "-", nzOutside, sumY / Double(a.width * a.height), kNZ, kN, Double(kSum) / Double(kN), kMax, oNZ, oN, Double(oSum) / Double(oN), oMax))
        }
        note("ProRes all10 − no-\(target) (d = max channel |Δ|):\n  " + rows.joined(separator: "\n  "))

        // 그림: 프레임 84(보임, 대조)와 85. 행 = all10 원본, no-X 원본, |d|×16(마스크 없음), 글자 자리
        for n in [84, 85] {
            guard let a = s[n]?.frame, let b = c[n]?.frame else { continue }
            let w = g.w, h = g.h
            let ctx = CGContext(data: nil, width: w, height: h * 4, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
            for yy in 0..<h { for xx in 0..<w {
                let i = ((g.y0 + yy) * a.width + g.x0 + xx) * 4
                let d = max(abs(Int(a.bgra[i]) - Int(b.bgra[i])), abs(Int(a.bgra[i + 1]) - Int(b.bgra[i + 1])), abs(Int(a.bgra[i + 2]) - Int(b.bgra[i + 2])))
                let dv = UInt8(min(255, d * 16)), kv: UInt8 = kset.contains(yy * w + xx) ? 255 : 0
                for (row, v) in [(0, [a.bgra[i], a.bgra[i + 1], a.bgra[i + 2]]), (1, [b.bgra[i], b.bgra[i + 1], b.bgra[i + 2]]), (2, [dv, dv, dv]), (3, [kv, kv, kv])] {
                    let o = ((row * h + yy) * w + xx) * 4
                    px[o] = v[0]; px[o + 1] = v[1]; px[o + 2] = v[2]; px[o + 3] = 255
                }
            } }
            let url = keep.appendingPathComponent("prores-label-color-f\(n).png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        }
        note("sheets: sb-local/prores-label-color-f84.png, -f85.png (rows: all10, no-\(target), |d|x16 unmasked, glyph K); H.264 counterpart: sb-local/heldout-label-color-f85.png")
    }
}
