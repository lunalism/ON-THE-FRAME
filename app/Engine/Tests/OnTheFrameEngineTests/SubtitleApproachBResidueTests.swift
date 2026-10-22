import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import QuartzCore
import XCTest

/// 일본어 자막 끝 프레임 55 잔상 조사(2026-10-21, docs/SUBTITLE-DESIGN.md §22, 실험 — 채택 아님). 선택 실행(OTF_SB=1).
/// §17의 처음 재현 조건 그대로(otf-TA 단독, 자막 네 개, 제품 H.264 ExportService)에서, 일본어 자막만 뺀 내보내기와 일본어만 넣은 내보내기를 함께 만들어
/// 프레임 52–58의 일본어 사각형을 비교한다. 대조로 ProRes 4444(같은 구성)를 쓴다(§18.5의 색 경로 차이가 있다).
/// 자막 구간·애니메이션·판정 기준(T1: 알파 ≥ 0.5 화소 중 기준 대비 밝기 차 > 40인 화소 수)은 바꾸지 않는다.
/// 결과 파일: .build/test-work/sb-residue/ (H.264와 비교 그림은 남기고 ProRes는 측정 뒤 지운다)
extension SubtitleApproachBTests {
    /// 표시 시각(PTS)과 함께 디코딩(BGRA). 키 = round(PTS × 30)
    static func decodeWithPTS(_ url: URL, frames: ClosedRange<Int>) async throws -> [Int: (pts: CMTime, frame: FrameCompare.Frame)] {
        let a = AVURLAsset(url: url)
        let t = try await a.loadTracks(withMediaType: .video).first!
        let r = try AVAssetReader(asset: a)
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        r.add(o); r.startReading()
        var out: [Int: (CMTime, FrameCompare.Frame)] = [:]
        while let sb = o.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb), n = Int((pts.seconds * 30).rounded())
            if frames.contains(n) { out[n] = (pts, FrameCompare.copy(pb)) }
            if n > frames.upperBound { break }
        }
        r.cancelReading()
        return out.mapValues { (pts: $0.0, frame: $0.1) }
    }

    func testApproachBJapaneseResidueDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, ta, expected) = try await plan()
        let rs = Self.captions.map(Self.raster)
        let size = p.videoComposition.renderSize
        let keep = ExportEndToEndTests.root.appendingPathComponent("sb-residue")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        func tool(_ subset: [Raster]?) -> AVVideoComposition {
            SubtitleABComparisonTests.tool(p.videoComposition, overlay: subset.map { Self.overlay($0, size: size, durationFrames: p.durationFrames).root })
        }
        let ja = rs.first { $0.caption.name == "ja-center" }!
        let variants: [(String, AVVideoComposition)] = [
            ("base", p.videoComposition), ("empty-tool", tool(nil)), ("all", tool(rs)),
            ("no-ja", tool(rs.filter { $0.caption.name != "ja-center" })), ("ja-only", tool([ja])),
        ]
        var files: [String: URL] = [:]
        for (tag, vc) in variants {
            let dest = keep.appendingPathComponent("h264-\(tag).mp4")
            try? FileManager.default.removeItem(at: dest)   // 이 테스트가 만든 이전 출력만(sb-residue 디렉터리)
            let outcome = await ExportService.export(withVideoComposition(p, vc), to: .fromSavePanel(dest), sources: [ta]) { _ in }
            XCTAssertEqual(outcome, .completed(dest), tag)
            files["h264-\(tag)"] = dest
        }
        for tag in ["base", "all", "no-ja"] {
            let dest = keep.appendingPathComponent("prores-\(tag).mov")
            try? FileManager.default.removeItem(at: dest)
            let s = AVAssetExportSession(asset: p.composition, presetName: AVAssetExportPresetAppleProRes4444LPCM)!
            s.videoComposition = variants.first { $0.0 == tag }!.1; s.audioMix = p.audioMix; s.shouldOptimizeForNetworkUse = false
            try await s.export(to: dest, as: .mov)
            files["prores-\(tag)"] = dest
        }
        var meta: [String] = []
        for k in files.keys.sorted() { meta.append("\(k): \(try await SubtitleABComparisonTests.describe(files[k]!))") }
        note("outputs (same plan as testApproachBExport: otf-TA only, 4 captions; ja-center [25, 55)):\n  " + meta.joined(separator: "\n  "))

        // 1. 출력별 크기가 처음 실패 기록과 같은 구성인가(처음: base 5165819, subtitles 5378961 바이트)
        let bytes = files.mapValues { ((try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? UInt64) ?? 0 }
        note("bytes: " + bytes.keys.sorted().map { "\($0) \(bytes[$0]!)" }.joined(separator: ", ") + " | first failing run recorded base 5165819, subtitles 5378961")

        // 2. 디코딩: PTS와 화면 코드
        var dec: [String: [Int: (pts: CMTime, frame: FrameCompare.Frame)]] = [:]
        for (k, u) in files { dec[k] = try await Self.decodeWithPTS(u, frames: 52...58) }
        var ptsRows: [String] = []
        for k in dec.keys.sorted() {
            ptsRows.append("\(k): " + (52...58).map { n in
                guard let d = dec[k]![n] else { return "\(n):missing" }
                let ok = ExportJudge.matches(E2Metrics.measure(Self.pixelBuffer(d.frame)), expected[n])
                return "\(n):\(d.pts.value)/\(d.pts.timescale)\(ok ? "" : " CODE≠")"
            }.joined(separator: " "))
        }
        note("decoded PTS (frame:value/timescale) and screen code vs expected:\n  " + ptsRows.joined(separator: "\n  "))

        // 3. 일본어 사각형: T1 정의 그대로(알파 ≥ 128, 다른 보이는 자막 사각형 +2 제외, 밝기 차 > 40)
        func inkPixels(_ a: FrameCompare.Frame, _ b: FrameCompare.Frame, frame n: Int) -> [(x: Int, y: Int, alpha: UInt8, d: Double)] {
            let others = rs.filter { $0.caption.name != "ja-center" && Self.expectedVisible($0.caption, frame: n) }.map { $0.rect.insetBy(dx: -2, dy: -2) }
            var out: [(Int, Int, UInt8, Double)] = []
            let w = Int(ja.rect.width)
            for y in 0..<Int(ja.rect.height) { for x in 0..<w where ja.alpha[y * w + x] >= 128 {
                let px = Int(ja.rect.minX) + x, py = Int(ja.rect.minY) + y
                if others.contains(where: { $0.contains(CGPoint(x: Double(px) + 0.5, y: Double(py) + 0.5)) }) { continue }
                let d = Self.luma(a, px, py) - Self.luma(b, px, py)
                if abs(d) > 40 { out.append((px, py, ja.alpha[y * w + x], d)) }
            } }
            return out
        }
        /// 사각형 전체(알파 무관)의 밝기 차 통계: 글자 자리(알파 ≥ 128)와 그 밖으로 나눔
        func rectStats(_ a: FrameCompare.Frame, _ b: FrameCompare.Frame) -> String {
            var gN = 0, gSum = 0.0, gSigned = 0.0, gMax = 0.0, oN = 0, oSum = 0.0, oMax = 0.0
            let w = Int(ja.rect.width)
            for y in 0..<Int(ja.rect.height) { for x in 0..<w {
                let px = Int(ja.rect.minX) + x, py = Int(ja.rect.minY) + y
                let d = Self.luma(a, px, py) - Self.luma(b, px, py)
                if ja.alpha[y * w + x] >= 128 { gN += 1; gSum += abs(d); gSigned += d; gMax = max(gMax, abs(d)) } else { oN += 1; oSum += abs(d); oMax = max(oMax, abs(d)) }
            } }
            return String(format: "glyph px mean|dY| %.2f signed %+.2f max %.0f | non-glyph mean|dY| %.2f max %.0f", gSum / Double(gN), gSigned / Double(gN), gMax, oSum / Double(oN), oMax)
        }
        var rows: [String] = []
        for enc in ["h264", "prores"] {
            for n in 52...58 {
                guard let base = dec["\(enc)-base"]?[n]?.frame, let all = dec["\(enc)-all"]?[n]?.frame, let noJa = dec["\(enc)-no-ja"]?[n]?.frame else { continue }
                let want = Self.expectedVisible(ja.caption, frame: n) ? "on" : "off"
                var cells = ["all−base \(inkPixels(all, base, frame: n).count)", "no-ja−base \(inkPixels(noJa, base, frame: n).count)", "all−no-ja \(inkPixels(all, noJa, frame: n).count)"]
                if enc == "h264", let e = dec["h264-empty-tool"]?[n]?.frame, let j = dec["h264-ja-only"]?[n]?.frame {
                    cells += ["empty-tool−base \(inkPixels(e, base, frame: n).count)", "ja-only−empty-tool \(inkPixels(j, e, frame: n).count)"]
                }
                rows.append("\(enc) f\(n) (expected \(want)) ink of \(ja.alpha.filter { $0 >= 128 }.count): " + cells.joined(separator: ", ")
                            + " | all vs no-ja [\(rectStats(all, noJa))] | all vs base [\(rectStats(all, base))]")
            }
        }
        note("ja-center rect, T1 ink definition (alpha ≥ 128, |dY| > 40):\n  " + rows.joined(separator: "\n  "))

        // 4. 프레임 55의 잔상 화소 하나하나(H.264 all − base): 위치, 알파, 밝기(all/base/no-ja), all의 RGB, 프레임 54의 같은 화소
        if let a55 = dec["h264-all"]?[55]?.frame, let b55 = dec["h264-base"]?[55]?.frame, let n55 = dec["h264-no-ja"]?[55]?.frame,
           let a54 = dec["h264-all"]?[54]?.frame, let b54 = dec["h264-base"]?[54]?.frame {
            let px = inkPixels(a55, b55, frame: 55)
            func rgb(_ f: FrameCompare.Frame, _ x: Int, _ y: Int) -> String { let i = (y * f.width + x) * 4; return "(\(f.bgra[i + 2]),\(f.bgra[i + 1]),\(f.bgra[i]))" }
            let detail = px.map { q in String(format: "(%d,%d) alpha %d | Y all %.0f base %.0f no-ja %.0f | all RGB %@ base RGB %@ | f54 Y all %.0f base %.0f",
                                                q.x, q.y, Int(q.alpha), Self.luma(a55, q.x, q.y), Self.luma(b55, q.x, q.y), Self.luma(n55, q.x, q.y),
                                                rgb(a55, q.x, q.y), rgb(b55, q.x, q.y), Self.luma(a54, q.x, q.y), Self.luma(b54, q.x, q.y)) }
            note("h264 f55 residue pixels (all − base, T1 definition) \(px.count); caption colour RGB (153,230,255):\n  " + detail.joined(separator: "\n  "))
            // 비교 그림: 일본어 사각형(1:1)과 첫 잔상 화소 둘레 ×6, 차이 ×8(같은 인코딩의 base 대비)
            let c = px.first.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: ja.rect.midX, y: ja.rect.midY)
            let zoom = CGRect(x: max(0, Int(c.x) - 30), y: max(0, Int(c.y) - 17), width: 60, height: 34)
            let panels = [
                SubtitleABComparisonTests.Panel(title: "ja rect 1:1", crop: ja.rect.insetBy(dx: -10, dy: -10), zoom: 1, diff: false),
                SubtitleABComparisonTests.Panel(title: "ja rect |d|x8 vs base", crop: ja.rect.insetBy(dx: -10, dy: -10), zoom: 1, diff: true),
                SubtitleABComparisonTests.Panel(title: "residue x6", crop: zoom, zoom: 6, diff: false),
                SubtitleABComparisonTests.Panel(title: "residue |d|x8 x6", crop: zoom, zoom: 6, diff: true),
            ]
            for n in [54, 55, 56] {
                guard let b = dec["h264-base"]?[n]?.frame else { continue }
                let rowsS: [(String, FrameCompare.Frame)] = ["base", "empty-tool", "no-ja", "ja-only", "all"].compactMap { t in dec["h264-\(t)"]?[n].map { ("h264 \(t)", $0.frame) } }
                try SubtitleABComparisonTests.sheet(keep.appendingPathComponent("sheet-ja-f\(n).png"), title: "frame \(n) — h264, diff vs h264 base (ja-center [25, 55))", rows: rowsS, ref: b, panels: panels)
            }
            note("sheets: sb-residue/sheet-ja-f54.png, -f55.png, -f56.png (residue zoom centred on \(c))")
        }
        // ProRes는 크다(각 약 175 MB). 측정만 하고 지운다(같은 명령으로 다시 만든다).
        for k in files.keys where k.hasPrefix("prores") { try? FileManager.default.removeItem(at: files[k]!) }
    }

    /// FrameCompare.Frame → CVPixelBuffer(BGRA), 화면 코드 측정용
    static func pixelBuffer(_ f: FrameCompare.Frame) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, f.width, f.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb!)
        f.bgra.withUnsafeBufferPointer { p in for y in 0..<f.height { memcpy(base + y * bpr, p.baseAddress! + y * f.width * 4, f.width * 4) } }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        return pb!
    }
}
