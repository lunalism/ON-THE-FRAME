import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import QuartzCore
import XCTest

/// 도구를 붙인 내보내기의 화질 차이 조사(2026-10-21, docs/SUBTITLE-DESIGN.md §31, 실험 — 채택 아님). 선택 실행(OTF_SB=1).
/// 새 내보내기 없이 기준(sb-residue/h264-base.mp4)과 B-empty(sb-residue/h264-empty-tool.mp4)를 원본 fixture(otf-TA.mp4) 디코딩과 나란히 읽어,
/// 영역별로 밝기·색차 오차, 오차의 프레임 간 흔들림(아른거림), 위치 어긋남, 선명도를 잰다. 구성(설정)도 함께 적는다.
/// 참조 = 원본 fixture 디코딩(타임라인이 원본 그대로 1920×1080 한 개라 기본 합성기 출력과 같은 그림을 기대하지만, 이 테스트에서 따로 증명하지 않는다).
extension SubtitleApproachBTests {
    func testApproachBToolQualityInspection() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, _, _) = try await plan()
        let root = ExportEndToEndTests.root
        let src = fixtures.appendingPathComponent("otf-TA.mp4")
        // OTF_SB_INSPECT=A이면 B-empty 자리에 §33의 A-empty(owner-quality/h264-A-empty.mp4)를 같은 지표로 잰다(표의 "B-empty" 열 = 그 파일)
        let alt = ProcessInfo.processInfo.environment["OTF_SB_INSPECT"] == "A"
        let files = [("source", src), ("baseline", root.appendingPathComponent("sb-residue/h264-base.mp4")),
                     (alt ? "A-empty" : "B-empty", root.appendingPathComponent(alt ? "owner-quality/h264-A-empty.mp4" : "sb-residue/h264-empty-tool.mp4"))]
        note("compared file (third column): \(files[2].0) \(files[2].1.lastPathComponent)")

        // 1. 구성: 기준 videoComposition과 도구 붙인 복사본
        let base = p.videoComposition
        let tooled = SubtitleABComparisonTests.tool(base, overlay: nil)
        func props(_ v: AVVideoComposition) -> String {
            "renderSize \(v.renderSize) frameDuration \(v.frameDuration.value)/\(v.frameDuration.timescale) renderScale \(v.renderScale) primaries \(v.colorPrimaries ?? "nil") transfer \(v.colorTransferFunction ?? "nil") matrix \(v.colorYCbCrMatrix ?? "nil") customCompositor \(v.customVideoCompositorClass.map { "\($0)" } ?? "nil") instructions \(v.instructions.count) frameTimingTrack \(v.sourceTrackIDForFrameTiming) animationTool \(v.animationTool == nil ? "nil" : "set")"
        }
        note("composition baseline: \(props(base))\ncomposition B-empty:  \(props(tooled))")
        let parent = CALayer(), video = CALayer()
        parent.frame = CGRect(origin: .zero, size: base.renderSize); video.frame = parent.frame; parent.addSublayer(video)
        note("tool layers (as built by SubtitleABComparisonTests.tool): parent frame \(parent.frame) bounds \(parent.bounds) contentsScale \(parent.contentsScale) geometryFlipped \(parent.isGeometryFlipped) | video frame \(video.frame) contentsScale \(video.contentsScale) gravity \(video.contentsGravity.rawValue) anchor \(video.anchorPoint)")
        for (tag, u) in files { note("\(tag): \(try await SubtitleABComparisonTests.describe(u))") }

        // 2. 세 파일을 같은 순서로 읽는다(PTS 확인)
        var readers: [(AVAssetReader, AVAssetReaderTrackOutput)] = []
        for (_, u) in files {
            let a = AVURLAsset(url: u)
            let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            r.add(o); r.startReading(); readers.append((r, o))
        }
        struct R { let name: String; let rect: (x0: Int, y0: Int, x1: Int, y1: Int) }
        let regions = [R(name: "flat (between grid lines)", rect: (1330, 975, 1430, 1070)), R(name: "noise band", rect: (300, 480, 1800, 880)),
                       R(name: "code boxes/edges", rect: (30, 90, 940, 230)), R(name: "whole frame", rect: (0, 0, 1920, 1080))]
        // 영역 × 파일(기준, B-empty): 오차 누적
        struct Acc { var n = 0.0, sqY = 0.0, sY = 0.0, aCb = 0.0, aCr = 0.0, flick = 0.0, flickN = 0.0, motion = 0.0, flickC = 0.0 }
        var acc = [[Acc]](repeating: [Acc](repeating: Acc(), count: 3), count: regions.count)   // [region][0 source motion,1 base,2 empty]
        var prevErr: [[[Float]]] = Array(repeating: Array(repeating: [], count: 3), count: regions.count)
        var prevErrC: [[[Float]]] = Array(repeating: Array(repeating: [], count: 3), count: regions.count)   // 색차 오차(Cb, Cr 번갈아)
        var perFrame: [String] = []
        var spatial: [String] = []
        var frame = 0
        func ycc(_ b: UnsafePointer<UInt8>, _ i: Int) -> (Float, Float, Float) {
            let B = Float(b[i]), G = Float(b[i + 1]), Rr = Float(b[i + 2])
            let y = 0.2126 * Rr + 0.7152 * G + 0.0722 * B
            return (y, (B - y) / 1.8556, (Rr - y) / 1.5748)
        }
        while true {
            var pbs: [CVPixelBuffer] = [], ptsOK = true
            for (k, (_, o)) in readers.enumerated() {
                guard let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { break }
                if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), CMTime(value: CMTimeValue(frame), timescale: 30)) != 0 { ptsOK = false; note("PTS mismatch file \(k) frame \(frame)") }
                pbs.append(pb)
            }
            guard pbs.count == 3 else { break }
            XCTAssertTrue(ptsOK)
            for pb in pbs { CVPixelBufferLockBaseAddress(pb, .readOnly) }
            let bp = pbs.map { UnsafePointer(CVPixelBufferGetBaseAddress($0)!.assumingMemoryBound(to: UInt8.self)) }, bpr = pbs.map(CVPixelBufferGetBytesPerRow)
            var rowPSNR: [String] = []
            for (ri, r) in regions.enumerated() {
                let step = ri == 3 ? 2 : 1
                var errs: [[Float]] = [[], [], []], errsC: [[Float]] = [[], [], []]
                var srcPrev = prevErr[ri][0]
                var srcNow: [Float] = []
                var sq = [0.0, 0.0, 0.0]; var cnt = 0.0
                for y in stride(from: r.rect.y0, to: r.rect.y1, by: step) { for x in stride(from: r.rect.x0, to: r.rect.x1, by: step) {
                    let s = ycc(bp[0], y * bpr[0] + x * 4)
                    srcNow.append(s.0)
                    cnt += 1
                    for f in 1...2 {
                        let e = ycc(bp[f], y * bpr[f] + x * 4)
                        let dy = e.0 - s.0
                        errs[f].append(dy); errsC[f].append(e.1 - s.1); errsC[f].append(e.2 - s.2)
                        acc[ri][f].sqY += Double(dy * dy); acc[ri][f].sY += Double(dy)
                        acc[ri][f].aCb += Double(abs(e.1 - s.1)); acc[ri][f].aCr += Double(abs(e.2 - s.2))
                        sq[f] += Double(dy * dy)
                    }
                } }
                for f in 1...2 {
                    acc[ri][f].n += cnt
                    if !prevErr[ri][f].isEmpty {
                        var s = 0.0; for i in 0..<errs[f].count { s += Double(abs(errs[f][i] - prevErr[ri][f][i])) }
                        acc[ri][f].flick += s; acc[ri][f].flickN += cnt
                        var c = 0.0; for i in 0..<errsC[f].count { c += Double(abs(errsC[f][i] - prevErrC[ri][f][i])) }
                        acc[ri][f].flickC += c / 2
                    }
                    prevErr[ri][f] = errs[f]; prevErrC[ri][f] = errsC[f]
                }
                if !srcPrev.isEmpty { var s = 0.0; for i in 0..<srcNow.count { s += Double(abs(srcNow[i] - srcPrev[i])) }; acc[ri][0].motion += s; acc[ri][0].flickN += cnt }
                srcPrev = srcNow; prevErr[ri][0] = srcNow
                rowPSNR.append(String(format: "%@ base %.1f B %.1f", String(r.name.prefix(5)), 10 * log10(65025 / max(1e-9, sq[1] / cnt)), 10 * log10(65025 / max(1e-9, sq[2] / cnt))))
            }
            if [0, 1, 2, 3, 30, 31, 32, 60, 61, 90, 118].contains(frame) { perFrame.append("f\(frame): " + rowPSNR.joined(separator: " | ")) }
            // 위치 어긋남·선명도(잡음 띠 가운데 400×200)
            if [2, 31, 60, 61].contains(frame) {
                let x0 = 700, y0 = 580, w = 400, h = 200
                func Y(_ f: Int, _ x: Int, _ y: Int) -> Float { ycc(bp[f], y * bpr[f] + x * 4).0 }
                var cells: [String] = []
                for f in 1...2 {
                    var best = (0, 0, Double.infinity), at0 = 0.0
                    for dy in -2...2 { for dx in -2...2 {
                        var s = 0.0
                        for y in stride(from: y0, to: y0 + h, by: 2) { for x in stride(from: x0, to: x0 + w, by: 2) { let d = Double(Y(f, x + dx, y + dy) - Y(0, x, y)); s += d * d } }
                        if s < best.2 { best = (dx, dy, s) }; if dx == 0 && dy == 0 { at0 = s }
                    } }
                    var lapE = 0.0, lapS = 0.0
                    for y in (y0 + 1)..<(y0 + h - 1) { for x in (x0 + 1)..<(x0 + w - 1) {
                        func lap(_ g: Int) -> Double { Double(4 * Y(g, x, y) - Y(g, x - 1, y) - Y(g, x + 1, y) - Y(g, x, y - 1) - Y(g, x, y + 1)) }
                        let a = lap(f), b = lap(0); lapE += a * a; lapS += b * b
                    } }
                    cells.append(String(format: "%@: best shift (%d,%d) MSE %.1f vs at (0,0) %.1f | Laplacian energy / source %.3f", f == 1 ? "base" : "B-empty", best.0, best.1, best.2 / Double(w * h / 4), at0 / Double(w * h / 4), lapE / lapS))
                }
                spatial.append("f\(frame): " + cells.joined(separator: " ; "))
            }
            for pb in pbs { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            frame += 1
        }
        note("frames read: \(frame) (PTS = n/30 checked for all three)")
        note("per-frame Y PSNR vs source (dB):\n  " + perFrame.joined(separator: "\n  "))
        var rows: [String] = []
        for (ri, r) in regions.enumerated() {
            let a1 = acc[ri][1], a2 = acc[ri][2], m = acc[ri][0]
            rows.append(String(format: "%@: source temporal |ΔY| %.3f | baseline: Y PSNR %.2f dB, signed ΔY %+.3f, |ΔCb| %.3f |ΔCr| %.3f, error flicker Y %.3f C %.3f | B-empty: Y PSNR %.2f dB, signed ΔY %+.3f, |ΔCb| %.3f |ΔCr| %.3f, error flicker Y %.3f C %.3f",
                               r.name, m.motion / max(1, m.flickN),
                               10 * log10(65025 / (a1.sqY / a1.n)), a1.sY / a1.n, a1.aCb / a1.n, a1.aCr / a1.n, a1.flick / max(1, a1.flickN), a1.flickC / max(1, a1.flickN),
                               10 * log10(65025 / (a2.sqY / a2.n)), a2.sY / a2.n, a2.aCb / a2.n, a2.aCr / a2.n, a2.flick / max(1, a2.flickN), a2.flickC / max(1, a2.flickN)))
        }
        note("all frames vs source decode (Y′CbCr from decoded RGB, BT.709 coefficients; error flicker = mean |e(n) − e(n−1)| of the luma (Y) and chroma (C, mean of Cb and Cr) error):\n  " + rows.joined(separator: "\n  "))
        note("geometry/sharpness in noise band (x 700–1100, y 580–780):\n  " + spatial.joined(separator: "\n  "))
    }
}
