import Accelerate
import AVFoundation
import CoreText
import E2Core
import Foundation
import ImageIO
@testable import OnTheFrameEngine
import OTFDevSupport
import QuartzCore
import XCTest

/// 자막 방식 A·B 짝 비교(2026-10-21, docs/SUBTITLE-DESIGN.md §18, 실험 — 채택 아님). 선택 실행(OTF_AB=1).
/// 고정 행렬 하나: 같은 계획(otf-TA 아래 + 생성 색 무늬 위, 배율 0.9 소수 위치)을
/// 기준(기본 합성기)·A(실험 합성기, 글자 없음)·B 빈 도구·B 글자로 그리고, 각각 제품 H.264(AVAssetExportPreset1920x1080, .mp4)와
/// 대조 ProRes 4444(AVAssetExportPresetAppleProRes4444LPCM, .mov — 무손실 아님, 고품질 중간 형식)로 내보낸다.
/// 모든 비교는 같은 참조(기본 합성기의 인코딩 전 버퍼, 문서화된 AVAssetReaderVideoCompositionOutput 경로), 같은 프레임, 같은 영역, 같은 지표를 쓴다.
/// 결과 파일·비교 그림: .build/test-work/ab-compare/ (지우지 않음), 기록: .build/test-work/diagnostics/ab-*.txt
final class SubtitleABComparisonTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    static let keep = ExportEndToEndTests.root.appendingPathComponent("ab-compare")
    var report: [String] = []
    func note(_ s: String) { report.append(s); print("AB \(s)") }
    override func tearDown() async throws {
        let dir = ExportEndToEndTests.root.appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (name.components(separatedBy: " ").last ?? "x").trimmingCharacters(in: CharacterSet(charactersIn: "]"))
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("ab-\(name).txt"), atomically: true, encoding: .utf8)
        try? report.joined(separator: "\n").write(to: Self.keep.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: fixture

    /// 1280×720 색 무늬(S1b 색 무늬와 같은 칸 구성, 위 셋째 칸은 1화소 바둑판): 위 줄 = 세부 셋 + 평평 하나, 아래 줄 = 기울기·6화소 바둑판·평평 둘
    static func pattern(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        switch (x / 320, y / 360) {
        case (0, 0): return x % 2 == 0 ? (230, 40, 40) : (40, 40, 230)
        case (1, 0): return (y / 2) % 2 == 0 ? (240, 240, 40) : (20, 20, 120)
        case (2, 0): return (x + y) % 2 == 0 ? (60, 200, 60) : (200, 60, 200)
        case (3, 0): return (200, 60, 60)
        case (0, 1): let v = UInt8((y - 360) * 255 / 359); return (255 - v, v, 128)
        case (1, 1): return ((x / 6) + (y / 6)) % 2 == 0 ? (250, 120, 0) : (0, 120, 250)
        case (2, 1): return (60, 180, 90)
        default: return (50, 70, 200)
        }
    }
    /// 위 레이어 왼쪽 위 목표(소수 위치). 배율 0.6 × 맞춤 1.5 = 원본 화소당 0.9 출력 화소 → 1152×648
    static let layerOrigin = CGPoint(x: 720.25, y: 410.5)

    struct Setup {
        let plan: PlannedComposition, sources: [MediaAsset], layer: CGRect
        let expected: [ExportJudge.Expected], rasters: [SubtitleApproachBTests.Raster], textMask: [CGRect]
    }
    func setup() async throws -> Setup {
        try await DevFixtures.ensureAll(in: fixtures)
        try FileManager.default.createDirectory(at: Self.keep, withIntermediateDirectories: true)
        let patURL = Self.keep.appendingPathComponent("fixture-pattern-1280x720-120f.mp4")
        if !FileManager.default.fileExists(atPath: patURL.path) {
            try await CompositorEquivalenceTests.writePattern(patURL, w: 1280, h: 720, frames: 120) { Self.pattern($0, $1) }
        }
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        let pat = try await MediaProbe.inspect(patURL)
        let render = CGSize(width: 1920, height: 1080)
        let r0 = CompositionPlanner.displayRect(pat, ClipTransform(scale: 0.6, x: 0, y: 0), render: render)
        let xf = ClipTransform(scale: 0.6, x: Self.layerOrigin.x - r0.minX, y: Self.layerOrigin.y - r0.minY)
        let layer = CompositionPlanner.displayRect(pat, xf, render: render)
        XCTAssertEqual(layer.minX, Self.layerOrigin.x, accuracy: 0.001); XCTAssertEqual(layer.minY, Self.layerOrigin.y, accuracy: 0.001)
        let top = UUID()
        var t = try Timeline().registering(ta).registering(pat).inserting(media: ta.id).addingLane(.video, name: "P", id: top, outward: true)
        t = try t.placing(media: pat.id, at: 0, videoLane: top, audioLane: nil)
        t = try t.settingTransform(clip: t.clips(inLane: top)[0].id, xf)
        let p = try await CompositionPlanner.plan(t, media: [ta.id: ta, pat.id: pat])
        let (expected, _) = try ExportJudge.expectations([.init(file: "otf-TA.mp4", sourceIn: 0, length: 120)], durationFrames: p.durationFrames)
        let rs = SubtitleApproachBTests.captions.map(SubtitleApproachBTests.raster)
        return Setup(plan: p, sources: [ta, pat], layer: layer, expected: expected, rasters: rs, textMask: rs.map { $0.rect.insetBy(dx: -8, dy: -8) })
    }
    func with(_ p: PlannedComposition, _ vc: AVVideoComposition) -> PlannedComposition {
        PlannedComposition(composition: p.composition, videoComposition: vc, durationFrames: p.durationFrames, settings: p.settings, hasAudio: p.hasAudio,
                           audioMix: p.audioMix, hasVideo: p.hasVideo, assets: p.assets)
    }
    static func tool(_ base: AVVideoComposition, overlay: CALayer?) -> AVVideoComposition {
        let size = base.renderSize
        let parent = CALayer(), video = CALayer()
        parent.frame = CGRect(origin: .zero, size: size); video.frame = parent.frame
        parent.addSublayer(video)
        if let overlay { parent.addSublayer(overlay) }
        let vc = base.mutableCopy() as! AVMutableVideoComposition
        vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayers: [video], in: parent)
        return vc.copy() as! AVVideoComposition
    }

    // MARK: 출력 정보

    static func fourCC(_ v: FourCharCode) -> String { String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .ascii) ?? "\(v)" }
    static func describe(_ url: URL) async throws -> String {
        let a = AVURLAsset(url: url)
        guard let t = try await a.loadTracks(withMediaType: .video).first else { return "no video" }
        let fd = try await t.load(.formatDescriptions).first!
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let keys = [kCVImageBufferColorPrimariesKey as String, kCVImageBufferTransferFunctionKey as String, kCVImageBufferYCbCrMatrixKey as String,
                    kCMFormatDescriptionExtension_FullRangeVideo as String, kCMFormatDescriptionExtension_Depth as String, kCMFormatDescriptionExtension_BitsPerComponent as String]
        let tags = keys.map { k in "\(k.replacingOccurrences(of: "CVImageBuffer", with: "").replacingOccurrences(of: "Key", with: ""))=\(ext[k].map { "\($0)" } ?? "none")" }.joined(separator: " ")
        let fps = try await t.load(.nominalFrameRate), mfd = try await t.load(.minFrameDuration), rate = try await t.load(.estimatedDataRate)
        let r = try AVAssetReader(asset: a)
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
        r.add(o); r.startReading()
        var n = 0, sync: [Int] = []
        while let sb = o.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sb) > 0 else { continue }
            let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
            if !((att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false) { sync.append(Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded())) }
            n += 1
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
        return String(format: "%@ %dx%d fps %.3f minFrameDuration %d/%d samples %d sync frames %@ data rate %.1f Mb/s size %.1f MB | %@",
                      fourCC(CMFormatDescriptionGetMediaSubType(fd)), Int(dims.width), Int(dims.height), fps, Int(mfd.value), Int(mfd.timescale), n, "\(sync.sorted())",
                      rate / 1e6, Double(bytes) / 1e6, tags)
    }

    // MARK: 지표

    /// 영역(참조 프레임에서 정함, 모든 비교에 같은 것): 0 글자 사각형 +8(영상 비교에서 뺌), 1 위 레이어 가장자리 ±4, 2 평평, 3 세부, 4 그 밖.
    /// 평평 = 참조의 9×9 창 안에서 B·G·R 각각 (최대 − 최소) ≤ 1(가장자리·세부에서 4화소 넘게 떨어진 곳만 남음). 세부 = 그 창에서 한 채널이라도 ≥ 32.
    static let regionNames = ["text", "layer-edge±4", "flat", "detail", "other"]
    static func regions(_ ref: FrameCompare.Frame, layer: CGRect, text: [CGRect]) -> [UInt8] {
        let w = ref.width, h = ref.height
        var src = ref.bgra, mx = [UInt8](repeating: 0, count: w * h * 4), mn = mx
        src.withUnsafeMutableBytes { s in
            var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            mx.withUnsafeMutableBytes { d in
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                precondition(vImageMax_ARGB8888(&sb, &db, nil, 0, 0, 9, 9, vImage_Flags(kvImageNoFlags)) == kvImageNoError)
            }
            mn.withUnsafeMutableBytes { d in
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                precondition(vImageMin_ARGB8888(&sb, &db, nil, 0, 0, 9, 9, vImage_Flags(kvImageNoFlags)) == kvImageNoError)
            }
        }
        let outer = layer.insetBy(dx: -4, dy: -4), inner = layer.insetBy(dx: 4, dy: 4)
        var out = [UInt8](repeating: 4, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), k = y * w + x
            if text.contains(where: { $0.contains(p) }) { out[k] = 0; continue }
            if outer.contains(p) && !inner.contains(p) { out[k] = 1; continue }
            let i = k * 4
            let r = max(Int(mx[i]) - Int(mn[i]), Int(mx[i + 1]) - Int(mn[i + 1]), Int(mx[i + 2]) - Int(mn[i + 2]))
            out[k] = r <= 1 ? 2 : (r >= 32 ? 3 : 4)
        } }
        return out
    }

    /// 차이 정의(8비트 디코딩 BGRA 값, 채널 0–255): ΔRGB = 채널별 차이. Y′ = 0.2126R′ + 0.7152G′ + 0.0722B′(BT.709 계수, 디코딩된 R′G′B′ 값에서 계산),
    /// Cb = (B′ − Y′)/1.8556, Cr = (R′ − Y′)/1.5748(같은 8비트 단위, 부호화된 YCbCr 평면을 직접 읽은 값이 아님). PSNR = 10·log10(255²/MSE).
    struct Acc {
        var n = 0, rgbAbs = 0.0, rgbSE = 0.0, rgbMax = 0, ySigned = 0.0, yAbs = 0.0, ySE = 0.0, yMax = 0.0, cbAbs = 0.0, cbMax = 0.0, crAbs = 0.0, crMax = 0.0
        @inline(__always) mutating func add(_ db: Int, _ dg: Int, _ dr: Int) {
            n += 1
            rgbAbs += Double(abs(db) + abs(dg) + abs(dr)); rgbSE += Double(db * db + dg * dg + dr * dr); rgbMax = max(rgbMax, abs(db), abs(dg), abs(dr))
            let dy = 0.2126 * Double(dr) + 0.7152 * Double(dg) + 0.0722 * Double(db)
            let dcb = (Double(db) - dy) / 1.8556, dcr = (Double(dr) - dy) / 1.5748
            ySigned += dy; yAbs += abs(dy); ySE += dy * dy; yMax = max(yMax, abs(dy))
            cbAbs += abs(dcb); cbMax = max(cbMax, abs(dcb)); crAbs += abs(dcr); crMax = max(crMax, abs(dcr))
        }
        static func psnr(_ se: Double, _ n: Double) -> String { se == 0 ? "inf" : String(format: "%.1f", 10 * log10(255 * 255 / (se / n))) }
        var s: String {
            guard n > 0 else { return "n 0" }
            let d = Double(n)
            return String(format: "n %d | RGB mean %.2f max %d PSNR %@ | Y' signed %+.2f mean %.2f max %.1f PSNR %@ | Cb mean %.2f max %.1f | Cr mean %.2f max %.1f",
                          n, rgbAbs / (3 * d), rgbMax, Self.psnr(rgbSE, 3 * d), ySigned / d, yAbs / d, yMax, Self.psnr(ySE, d), cbAbs / d, cbMax, crAbs / d, crMax)
        }
    }
    /// a − ref, 영역별(전 화소). 영역 0(글자)은 세지 않는다.
    static func compare(_ a: FrameCompare.Frame, _ ref: FrameCompare.Frame, regions: [UInt8], into acc: inout [Acc]) {
        a.bgra.withUnsafeBufferPointer { pa in ref.bgra.withUnsafeBufferPointer { pr in regions.withUnsafeBufferPointer { rg in
            for k in 0..<rg.count {
                let g = Int(rg[k]); if g == 0 { continue }
                let i = k * 4
                acc[g].add(Int(pa[i]) - Int(pr[i]), Int(pa[i + 1]) - Int(pr[i + 1]), Int(pa[i + 2]) - Int(pr[i + 2]))
            }
        } } }
    }

    // MARK: 비교 그림

    static func image(_ f: FrameCompare.Frame, crop c: CGRect) -> CGImage {
        let x0 = Int(c.minX), y0 = Int(c.minY), w = Int(c.width), h = Int(c.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { for k in 0..<4 { data[(y * w + x) * 4 + k] = f.bgra[((y0 + y) * f.width + x0 + x) * 4 + k] } } }
        return cg(data, w, h)
    }
    /// 차이 그림: 화소마다 max|ΔRGB| × 8(255에서 자름), 회색
    static func diffImage(_ f: FrameCompare.Frame, _ ref: FrameCompare.Frame, crop c: CGRect) -> CGImage {
        let x0 = Int(c.minX), y0 = Int(c.minY), w = Int(c.width), h = Int(c.height)
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = ((y0 + y) * f.width + x0 + x) * 4
            let d = (0..<3).map { abs(Int(f.bgra[i + $0]) - Int(ref.bgra[i + $0])) }.max()!
            let v = UInt8(min(255, d * 8)); for k in 0..<3 { data[(y * w + x) * 4 + k] = v }
        } }
        return cg(data, w, h)
    }
    static func cg(_ data: [UInt8], _ w: Int, _ h: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    struct Panel { let title: String; let crop: CGRect; let zoom: Int; let diff: Bool }
    /// 행 = 변형, 열 = 자르기(1:1 또는 최근접 확대). 모든 행이 같은 자르기·같은 배율·같은 색 공간 표시(sRGB 태그, 값 그대로)다.
    static func sheet(_ url: URL, title: String, rows: [(String, FrameCompare.Frame)], ref: FrameCompare.Frame, panels: [Panel]) throws {
        let labelW = 190, head = 46, gap = 8
        let cellW = panels.map { Int($0.crop.width) * $0.zoom }, cellH = panels.map { Int($0.crop.height) * $0.zoom }.max()!
        let W = labelW + cellW.reduce(0, +) + gap * panels.count, H = head + rows.count * (cellH + gap)
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .none
        func text(_ s: String, _ x: Int, _ yTop: Int, size: CGFloat = 12) {
            let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
            let a = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.95, alpha: 1)])
            ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(H - yTop) - size)
            CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
        }
        text(title, 8, 6, size: 13)
        var x = labelW
        for (j, p) in panels.enumerated() {
            text(p.title, x, 26, size: 11)
            for (i, row) in rows.enumerated() {
                let img = p.diff ? diffImage(row.1, ref, crop: p.crop) : image(row.1, crop: p.crop)
                let y = head + i * (cellH + gap)
                ctx.draw(img, in: CGRect(x: x, y: H - y - Int(p.crop.height) * p.zoom, width: cellW[j], height: Int(p.crop.height) * p.zoom))
                if j == 0 { text(row.0, 8, y + 4) }
            }
            x += cellW[j] + gap
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw ProbeFailure("png \(url.lastPathComponent)") }
    }

    // MARK: 고정 비교 행렬

    func testMatchedComparison() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_AB"] == "1", "실험 실행은 OTF_AB=1일 때만")
        let s = try await setup()
        let p = s.plan
        let base = p.videoComposition
        XCTAssertNil(base.customVideoCompositorClass, "plan uses the built-in compositor")
        let a = try ExperimentalComposition.videoComposition(from: base)
        let bEmpty = Self.tool(base, overlay: nil)
        let bText = Self.tool(base, overlay: SubtitleApproachBTests.overlay(s.rasters, size: base.renderSize, durationFrames: p.durationFrames).root)
        note("plan: render \(base.renderSize) frameDuration \(base.frameDuration.value)/\(base.frameDuration.timescale) frames \(p.durationFrames) | top layer rect \(s.layer) (0.9 output px per source px) | requested color properties: base \(String(describing: base.colorPrimaries))/\(String(describing: base.colorTransferFunction))/\(String(describing: base.colorYCbCrMatrix)), A \(String(describing: a.colorPrimaries)), B empty \(String(describing: bEmpty.colorPrimaries)), B text \(String(describing: bText.colorPrimaries))")
        let variants: [(String, AVVideoComposition)] = [("base", base), ("A", a), ("B-empty", bEmpty), ("B-text", bText)]

        // 내보내기: H.264(제품 경로 ExportService) + 기준 반복 1회, ProRes 4444(같은 세션 설정, 대조)
        var files: [String: URL] = [:]
        for (tag, vc) in variants + [("base-repeat", base)] {
            let dest = Self.keep.appendingPathComponent("h264-\(tag).mp4")
            try? FileManager.default.removeItem(at: dest)   // 이 테스트가 만든 이전 출력만(ab-compare 디렉터리)
            let t0 = Date()
            let outcome = await ExportService.export(with(p, vc), to: .fromSavePanel(dest), sources: s.sources) { _ in }
            XCTAssertEqual(outcome, .completed(dest), tag)
            files["h264-\(tag)"] = dest
            note(String(format: "export h264-%@ %.2f s", tag, Date().timeIntervalSince(t0)))
        }
        for (tag, vc) in variants {
            let dest = Self.keep.appendingPathComponent("prores-\(tag).mov")
            try? FileManager.default.removeItem(at: dest)
            guard let session = AVAssetExportSession(asset: p.composition, presetName: AVAssetExportPresetAppleProRes4444LPCM) else { XCTFail("ProRes session"); continue }
            session.videoComposition = vc; session.audioMix = p.audioMix; session.shouldOptimizeForNetworkUse = false
            let t0 = Date()
            try await session.export(to: dest, as: .mov)
            files["prores-\(tag)"] = dest
            note(String(format: "export prores-%@ %.2f s", tag, Date().timeIntervalSince(t0)))
        }
        var meta: [String] = []
        for k in files.keys.sorted() { meta.append("\(k): \(try await Self.describe(files[k]!))") }
        note("output metadata (requested: H.264 = ExportService preset 1920x1080 .mp4; ProRes = preset ProRes4444LPCM .mov; same videoComposition renderSize/frameDuration/color properties per variant):\n  " + meta.joined(separator: "\n  "))

        // V1: H.264 각 변형의 모든 프레임 화면 코드
        for (tag, _) in variants {
            let v = try await ExportJudge.judge(files["h264-\(tag)"]!, clips: [.init(file: "otf-TA.mp4", sourceIn: 0, length: p.durationFrames)], durationFrames: p.durationFrames, checkAudio: false)
            note("V1 h264-\(tag): pass \(v.pass) frames \(v.frames) mismatched \(v.mismatchedFrames.prefix(6))")
        }

        // 프레임: 지표용 + 자막 경계(T1 재측정)
        let probes = [0, 15, 30, 42, 50, 59, 60, 89, 119]
        var bounds = Set<Int>()
        for c in SubtitleApproachBTests.captions { for n in [c.start - 1, c.start, c.start + 1, c.end - 1, c.end, c.end + 1] where n >= 0 && n < p.durationFrames { bounds.insert(n) } }
        let want = Set(probes).union(bounds)
        var dec: [String: [Int: FrameCompare.Frame]] = [:]
        for (k, url) in files { dec[k] = try await FrameCompare.decode(url, frames: k.hasSuffix("base") || k.hasSuffix("B-text") ? want : Set(probes)) }

        // 인코딩 전 버퍼: 기준(참조), A(문서화된 경로: 리더 + 사용자 정의 합성기), B 빈 도구(문서에 없는 경로: 리더 + animationTool, 진단만)
        func preEncode(_ vc: AVVideoComposition) async throws -> ([Int: FrameCompare.Frame], String) {
            let (r, o) = try await CompositorEquivalenceTests.reader(p.composition, vc)
            defer { r.cancelReading() }
            var out: [Int: FrameCompare.Frame] = [:], tags = "", fmt = ""
            while let sb = o.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let n = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded())
                if tags.isEmpty { tags = CompositorEquivalenceTests.colorTags(pb); fmt = Self.fourCC(CVPixelBufferGetPixelFormatType(pb)) }
                if want.contains(n) { out[n] = FrameCompare.copy(pb) }
                if n >= want.max()! { break }
            }
            return (out, "\(fmt) [\(tags)]")
        }
        let (ref, refTags) = try await preEncode(base)
        let (preA, preATags) = try await preEncode(a)
        let (preB, preBTags) = try await preEncode(bEmpty)
        note("pre-encode buffers (reader BGRA): reference(base) \(refTags) | A \(preATags) | B-empty (undocumented reader+animationTool, diagnostic only) \(preBTags)")

        // 영역(참조에서, 프레임마다)
        var reg: [Int: [UInt8]] = [:]
        var regCounts = [Int](repeating: 0, count: 5)
        for n in probes { let r = Self.regions(ref[n]!, layer: s.layer, text: s.textMask); reg[n] = r; for g in r { regCounts[Int(g)] += 1 } }
        note("regions over \(probes.count) probe frames (pixels): " + zip(Self.regionNames, regCounts).map { "\($0.0) \($0.1)" }.joined(separator: ", ")
             + " | flat = reference 9×9 window per-channel range ≤ 1; detail = range ≥ 32; text rects +8 excluded from video comparison")
        // 평평 영역 검증: 평평으로 표시된 화소의 참조 3×3 이웃 최대 채널 차이(0–1이어야 함)
        var flatCheck = 0
        for n in probes { let r = ref[n]!, g = reg[n]!
            for y in 1..<(r.height - 1) { for x in 1..<(r.width - 1) where g[y * r.width + x] == 2 {
                let i = (y * r.width + x) * 4
                for (dx, dy) in [(1, 0), (0, 1)] { let j = ((y + dy) * r.width + x + dx) * 4; for c in 0..<3 { flatCheck = max(flatCheck, abs(Int(r.bgra[i + c]) - Int(r.bgra[j + c]))) } }
            } }
        }
        note("flat mask check: max neighbour channel step inside flat pixels \(flatCheck)")

        // 영상 비교(모두 참조 대비, 같은 프레임·영역·지표)
        let rows: [(String, [Int: FrameCompare.Frame])] = [
            ("pre-encode A (documented reader path)", preA),
            ("pre-encode B-empty (undocumented reader+tool, diagnostic)", preB),
            ("h264 base", dec["h264-base"]!), ("h264 base-repeat", dec["h264-base-repeat"]!), ("h264 A", dec["h264-A"]!),
            ("h264 B-empty", dec["h264-B-empty"]!), ("h264 B-text (outside text)", dec["h264-B-text"]!),
            ("prores base", dec["prores-base"]!), ("prores A", dec["prores-A"]!), ("prores B-empty", dec["prores-B-empty"]!), ("prores B-text (outside text)", dec["prores-B-text"]!),
        ]
        var table: [String] = [], perFrame: [String] = []
        for (label, fr) in rows {
            var acc = [Acc](repeating: Acc(), count: 5), all = Acc(), pf: [String] = []
            for n in probes { guard let f = fr[n] else { pf.append("f\(n) missing"); continue }
                var one = [Acc](repeating: Acc(), count: 5)
                Self.compare(f, ref[n]!, regions: reg[n]!, into: &one)
                var frameAll = Acc()
                for g in 1..<5 { acc[g] = Self.merge(acc[g], one[g]); frameAll = Self.merge(frameAll, one[g]) }
                all = Self.merge(all, frameAll)
                pf.append(String(format: "f%d %@", n, Acc.psnr(frameAll.rgbSE, 3 * Double(frameAll.n))))
            }
            table.append("\(label) vs reference:\n    all outside text [\(all.s)]" + (1..<5).map { "\n    \(Self.regionNames[$0]) [\(acc[$0].s)]" }.joined())
            perFrame.append("\(label): RGB PSNR outside text per frame " + pf.joined(separator: " "))
        }
        note("matched video comparison (reference = pre-encode base buffer; probe frames \(probes)):\n  " + table.joined(separator: "\n  "))
        note("per-frame:\n  " + perFrame.joined(separator: "\n  "))

        // 같은 인코딩 안 직접 짝(참조 없이): 기준 반복, B 빈 도구 대 기준, A 대 기준
        var pairs: [String] = []
        for (label, x, y) in [("h264 base-repeat vs h264 base", "h264-base-repeat", "h264-base"), ("h264 B-empty vs h264 base", "h264-B-empty", "h264-base"),
                              ("h264 A vs h264 base", "h264-A", "h264-base"), ("prores B-empty vs prores base", "prores-B-empty", "prores-base"),
                              ("prores A vs prores base", "prores-A", "prores-base"), ("h264 B-text vs h264 B-empty (outside text)", "h264-B-text", "h264-B-empty"),
                              ("prores B-text vs prores B-empty (outside text)", "prores-B-text", "prores-B-empty")] {
            var all = Acc(), acc = [Acc](repeating: Acc(), count: 5)
            for n in probes { guard let f = dec[x]![n], let g = dec[y]![n] else { continue }
                var one = [Acc](repeating: Acc(), count: 5); Self.compare(f, g, regions: reg[n]!, into: &one)
                for k in 1..<5 { all = Self.merge(all, one[k]); acc[k] = Self.merge(acc[k], one[k]) }
            }
            pairs.append("\(label):\n    all outside text [\(all.s)]" + (1..<5).map { "\n    \(Self.regionNames[$0]) [\(acc[$0].s)]" }.joined())
        }
        note("direct pairs (same regions):\n  " + pairs.joined(separator: "\n  "))

        // A 레이어 가장자리 진단(인코딩 전, 프레임 15): 가장자리 근처 열·행마다 max|ΔRGB|(글자 사각형 +8 제외, 가장자리 끝 10화소 제외)
        let L0 = s.layer
        if let fa = preA[15], let fr = ref[15] {
            func line(_ k: Int, vertical: Bool) -> String {
                var mx = 0, sum = 0, n = 0
                let span = vertical ? (Int(L0.minY) + 10)..<(Int(L0.maxY) - 10) : (Int(L0.minX) + 10)..<(Int(L0.maxX) - 10)
                for t in span {
                    let x = vertical ? k : t, y = vertical ? t : k
                    if s.textMask.contains(where: { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }) { continue }
                    let i = (y * fa.width + x) * 4
                    let d = (0..<3).map { abs(Int(fa.bgra[i + $0]) - Int(fr.bgra[i + $0])) }.max()!
                    mx = max(mx, d); sum += d; n += 1
                }
                return "\(k):\(mx)/\(n > 0 ? sum / n : 0)"
            }
            let left = (716...724).map { line($0, vertical: true) }, right = (1868...1876).map { line($0, vertical: true) }
            let topR = (406...414).map { line($0, vertical: false) }, bottom = (1054...1062).map { line($0, vertical: false) }
            note("A layer-edge diagnostic (pre-encode f15, layer \(L0), entries column-or-row:max/mean |ΔRGB|): left \(left) | right \(right) | top \(topR) | bottom \(bottom)")
        }

        // 글자 모양(B 글자만 — A 실험 합성기는 글자를 그리지 않는다): 혼자 보이는 프레임에서 기대 = 참조 위에 그림을 sRGB 값 그대로 알파 합성(색 관리 없음 가정)
        let solo: [String: Int] = ["ko-left": 15, "ja-center": 50, "mixed-right": 60, "overlap-yellow": 42]
        var textRows: [String] = []
        for (label, fr) in [("h264 B-text", dec["h264-B-text"]!), ("prores B-text", dec["prores-B-text"]!)] {
            for r in s.rasters { guard let n = solo[r.caption.name], let f = fr[n], let b = ref[n] else { continue }
                var core = Acc(), rim = Acc(), inter = 0, union = 0
                let w = Int(r.rect.width), h = Int(r.rect.height), x0 = Int(r.rect.minX), y0 = Int(r.rect.minY)
                let fg = [r.caption.rgba.2, r.caption.rgba.1, r.caption.rgba.0].map { Double($0) * 255 }
                for y in 0..<h { for x in 0..<w {
                    let al = Double(r.alpha[y * w + x]) / 255, i = ((y0 + y) * f.width + x0 + x) * 4
                    var d = [0, 0, 0]
                    for k in 0..<3 { d[k] = Int(Double(f.bgra[i + k]) - (fg[k] * al + Double(b.bgra[i + k]) * (1 - al))) }
                    if al >= 0.5 { core.add(d[0], d[1], d[2]) } else if al > 0 { rim.add(d[0], d[1], d[2]) }
                    let e = al >= 0.5, g = SubtitleApproachBTests.ink(f, b, x0 + x, y0 + y)
                    if e || g { union += 1 }; if e && g { inter += 1 }
                } }
                textRows.append(String(format: "%@ %@ f%d: ink IoU %.3f | glyph core (alpha ≥ 0.5) [%@] | glyph rim (0 < alpha < 0.5) [%@]",
                                       label, r.caption.name, n, Double(inter) / Double(max(1, union)), core.s, rim.s))
            }
        }
        note("text appearance (B only; expected = reference + raster alpha-over in sRGB values):\n  " + textRows.joined(separator: "\n  "))

        // T1 경계 재측정: H.264와 ProRes 각각 같은 인코딩의 기준과 비교(기준·정의 그대로)
        for enc in ["h264", "prores"] {
            var bad: [String] = []
            let sb = dec["\(enc)-B-text"]!, bb = dec["\(enc)-base"]!
            for r in s.rasters { let c = r.caption
                for n in [c.start - 1, c.start, c.start + 1, c.end - 1, c.end, c.end + 1] where n >= 0 && n < p.durationFrames {
                    guard let f = sb[n], let b = bb[n] else { bad.append("\(c.name) f\(n) undecoded"); continue }
                    let others = s.rasters.filter { $0.caption.name != c.name && SubtitleApproachBTests.expectedVisible($0.caption, frame: n) }.map { $0.rect.insetBy(dx: -2, dy: -2) }
                    var count = 0, need = 0
                    for y in 0..<Int(r.rect.height) { for x in 0..<Int(r.rect.width) where r.alpha[y * Int(r.rect.width) + x] >= 128 {
                        let px = Int(r.rect.minX) + x, py = Int(r.rect.minY) + y
                        if others.contains(where: { $0.contains(CGPoint(x: Double(px) + 0.5, y: Double(py) + 0.5)) }) { continue }
                        need += 1; if SubtitleApproachBTests.ink(f, b, px, py) { count += 1 }
                    } }
                    let wantOn = SubtitleApproachBTests.expectedVisible(c, frame: n)
                    let got: Bool? = Double(count) >= 0.25 * Double(need) ? true : (count == 0 ? false : nil)
                    if got != wantOn { bad.append("\(c.name) f\(n) ink \(count)/\(need) expected \(wantOn ? "on" : "off")") }
                }
            }
            note("T1 \(enc) B-text vs \(enc) base: \(bad.isEmpty ? "pass" : "FAIL \(bad)")")
        }

        // 비교 그림: 프레임 0(키 프레임)·50(일본어 자막과 두 줄 자막이 보임). 행: 참조, 기준, A, B 빈 도구, B 글자(같은 인코딩)
        let L = s.layer
        let panels = [
            Panel(title: "frame code 1:1", crop: CGRect(x: 40, y: 100, width: 240, height: 135), zoom: 1, diff: false),
            Panel(title: "layer corner+stripes 1:1", crop: CGRect(x: Int(L.minX) - 30, y: Int(L.minY) - 20, width: 240, height: 135), zoom: 1, diff: false),
            Panel(title: "1-px checker 1:1", crop: CGRect(x: 1380, y: 480, width: 240, height: 135), zoom: 1, diff: false),
            Panel(title: "checker x4", crop: CGRect(x: 1440, y: 520, width: 60, height: 34), zoom: 4, diff: false),
            Panel(title: "checker |d|x8 vs ref", crop: CGRect(x: 1380, y: 480, width: 240, height: 135), zoom: 1, diff: true),
            Panel(title: "flat red 1:1", crop: CGRect(x: 1600, y: 450, width: 240, height: 135), zoom: 1, diff: false),
            Panel(title: "flat red |d|x8 vs ref", crop: CGRect(x: 1600, y: 450, width: 240, height: 135), zoom: 1, diff: true),
            Panel(title: "ja text 1:1", crop: CGRect(x: 1250, y: 120, width: 240, height: 135), zoom: 1, diff: false),
            Panel(title: "ja text x4", crop: CGRect(x: 1330, y: 150, width: 60, height: 34), zoom: 4, diff: false),
        ]
        var sheets: [String] = []
        for n in [0, 50] { for enc in ["h264", "prores"] {
            let url = Self.keep.appendingPathComponent("sheet-\(enc)-f\(n).png")
            let rowsS: [(String, FrameCompare.Frame)] = [("reference (pre-enc base)", ref[n]!)] + ["base", "A", "B-empty", "B-text"].map { ("\(enc) \($0)", dec["\(enc)-\($0)"]![n]!) }
            try Self.sheet(url, title: "frame \(n) — \(enc) outputs vs pre-encode reference (same crops, same scale, values shown as sRGB)", rows: rowsS, ref: ref[n]!, panels: panels)
            sheets.append(url.lastPathComponent)
        } }
        note("contact sheets: \(sheets) in \(Self.keep.lastPathComponent)/ (crops: \(panels.map { "\($0.title) \($0.crop)" }))")
    }

    static func merge(_ a: Acc, _ b: Acc) -> Acc {
        var r = a
        r.n += b.n; r.rgbAbs += b.rgbAbs; r.rgbSE += b.rgbSE; r.rgbMax = max(r.rgbMax, b.rgbMax)
        r.ySigned += b.ySigned; r.yAbs += b.yAbs; r.ySE += b.ySE; r.yMax = max(r.yMax, b.yMax)
        r.cbAbs += b.cbAbs; r.cbMax = max(r.cbMax, b.cbMax); r.crAbs += b.crAbs; r.crMax = max(r.crMax, b.crMax)
        return r
    }
}
