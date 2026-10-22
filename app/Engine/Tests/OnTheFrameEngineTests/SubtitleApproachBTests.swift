import AppKit
import AVFoundation
import CoreText
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import QuartzCore
import XCTest

/// 자막 방식 B 실험(2026-10-21, docs/SUBTITLE-DESIGN.md §17, 실험 — 채택 아님): 기본 합성기를 그대로 두고 Core Animation 층으로 글자를 얹는다.
/// - 내보내기: 계획의 기본 합성기 videoComposition 복사본 + `animationTool`(AVVideoCompositionCoreAnimationTool, AVAssetExportSession 경로)
/// - 프리뷰: 같은 계획의 videoComposition 그대로 + `AVSynchronizedLayer(playerItem:)` 아래 같은 층 구성
/// 앱·엔진 코드는 바꾸지 않는다. 모두 선택 실행(OTF_SB=1, 새 프로세스 첫 재생은 OTF_SB_FRESH=1)이다.
/// 측정 기록: .build/test-work/diagnostics/sb-*.txt
final class SubtitleApproachBTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var out: URL!
    var report: [String] = []
    func note(_ s: String) { report.append(s); print("SB \(s)") }
    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        out = ExportEndToEndTests.root.appendingPathComponent("sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: out)
        let dir = ExportEndToEndTests.root.appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (name.components(separatedBy: " ").last ?? "x").trimmingCharacters(in: CharacterSet(charactersIn: "]"))
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("sb-\(name).txt"), atomically: true, encoding: .utf8)
    }

    // MARK: 공유: 글자 사양 → 그림 → 층

    struct Caption {
        let name: String, text: String, font: String, size: CGFloat
        let rgba: (CGFloat, CGFloat, CGFloat, CGFloat)
        let align: CTTextAlignment
        let origin: CGPoint      // 상자 왼쪽 위(출력 화소, 왼쪽 위 원점)
        let width: CGFloat
        let start: Int, end: Int // 프레임 [start, end)
    }
    struct Raster {
        let caption: Caption
        let image: CGImage
        let rect: CGRect         // 출력 화소, 왼쪽 위 원점
        let alpha: [UInt8]       // 행 0 = 위
        let lines: Int
        let fonts: [String]
    }
    static let font = "AppleSDGothicNeo-Bold"
    /// 차례 = 쌓음(뒤가 위). 화면 코드 칸(x < 940, y 100–220)과 상자 줄(y 280–400)을 피한다.
    /// 단 ja-center는 배경의 프레임 번호 글자("f=NN", 매 프레임 바뀜) 위에 겹친다. H.264에서 그 자리의 차이가 T1 글자 화소로 잡힌다(docs/SUBTITLE-DESIGN.md §22).
    static let captions: [Caption] = [
        Caption(name: "ko-left", text: "안녕하세요, 온더프레임 자막 실험입니다.", font: font, size: 48, rgba: (1, 1, 1, 1), align: .left,
                origin: CGPoint(x: 240, y: 560), width: 900, start: 10, end: 40),
        Caption(name: "ja-center", text: "こんにちは、字幕のテストです。", font: font, size: 44, rgba: (0.6, 0.9, 1, 1), align: .center,
                origin: CGPoint(x: 1100, y: 120), width: 700, start: 25, end: 55),
        Caption(name: "mixed-right", text: "Mixed 한국어 English 日本語\nThe second line wraps when it is longer than the box width.", font: font, size: 40,
                rgba: (1, 1, 1, 1), align: .right, origin: CGPoint(x: 900, y: 800), width: 900, start: 40, end: 70),
        Caption(name: "overlap-yellow", text: "OVERLAP 겹침", font: font, size: 56, rgba: (1, 0.9, 0.1, 1), align: .center,
                origin: CGPoint(x: 420, y: 545), width: 600, start: 30, end: 45),
    ]
    static let epsilonFrames = 0.001

    static func raster(_ c: Caption) -> Raster {
        let ctFont = CTFontCreateWithName(c.font as CFString, c.size, nil)
        var align = c.align
        let style = withUnsafeBytes(of: &align) { p in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: p.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let color = CGColor(srgbRed: c.rgba.0, green: c.rgba.1, blue: c.rgba.2, alpha: c.rgba.3)
        let attr = NSAttributedString(string: c.text, attributes: [kCTFontAttributeName as NSAttributedString.Key: ctFont,
                                                                    kCTForegroundColorAttributeName as NSAttributedString.Key: color,
                                                                    kCTParagraphStyleAttributeName as NSAttributedString.Key: style])
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil, CGSize(width: c.width, height: .greatestFiniteMagnitude), nil)
        let w = Int(c.width), h = Int(fit.height.rounded(.up)) + 2
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var fonts = Set<String>()
        for l in lines { for r in CTLineGetGlyphRuns(l) as! [CTRun] {
            if let f = (CTRunGetAttributes(r) as NSDictionary)[kCTFontAttributeName] { fonts.insert(CTFontCopyPostScriptName(f as! CTFont) as String) }
        } }
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { alpha[y * w + x] = data[y * w * 4 + x * 4 + 3] } }   // CGContext 메모리의 행 0 = 위
        return Raster(caption: c, image: ctx.makeImage()!, rect: CGRect(x: c.origin.x, y: c.origin.y, width: CGFloat(w), height: CGFloat(h)),
                      alpha: alpha, lines: lines.count, fonts: fonts.sorted())
    }

    /// 자막 층 구성(내보내기·프리뷰 같은 함수). 층 좌표는 macOS 기본(왼쪽 아래 원점)이므로 y를 뒤집는다.
    static func overlay(_ rs: [Raster], size: CGSize, durationFrames: Int) -> (root: CALayer, layers: [String: CALayer]) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        var named: [String: CALayer] = [:]
        let d = Double(durationFrames) / 30
        for r in rs {
            let l = CALayer()
            l.contents = r.image
            l.contentsScale = 1
            l.contentsGravity = .resize
            l.frame = CGRect(x: r.rect.minX, y: size.height - r.rect.maxY, width: r.rect.width, height: r.rect.height)
            l.opacity = 0
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.calculationMode = .discrete
            a.values = [0, 1, 0]
            a.keyTimes = [0, NSNumber(value: (Double(r.caption.start) - epsilonFrames) / 30 / d), NSNumber(value: (Double(r.caption.end) - epsilonFrames) / 30 / d), 1]
            a.beginTime = AVCoreAnimationBeginTimeAtZero
            a.duration = d
            a.isRemovedOnCompletion = false
            a.fillMode = .both
            l.add(a, forKey: "visibility")
            root.addSublayer(l)
            named[r.caption.name] = l
        }
        return (root, named)
    }
    static func expectedVisible(_ c: Caption, frame n: Int) -> Bool { n >= c.start && n < c.end }

    func plan() async throws -> (PlannedComposition, MediaAsset, [ExportJudge.Expected]) {
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        let t = try Timeline().registering(ta).inserting(media: ta.id)
        let p = try await CompositionPlanner.plan(t, media: [ta.id: ta])
        let (expected, _) = try ExportJudge.expectations([.init(file: "otf-TA.mp4", sourceIn: 0, length: t.durationFrames)], durationFrames: t.durationFrames)
        return (p, ta, expected)
    }
    func withVideoComposition(_ p: PlannedComposition, _ vc: AVVideoComposition) -> PlannedComposition {
        PlannedComposition(composition: p.composition, videoComposition: vc, durationFrames: p.durationFrames, settings: p.settings, hasAudio: p.hasAudio,
                           audioMix: p.audioMix, hasVideo: p.hasVideo, assets: p.assets)
    }

    // MARK: 내보내기(T1, V1, V2, A1–A4)

    static func luma(_ f: FrameCompare.Frame, _ x: Int, _ y: Int) -> Double {
        let i = (y * f.width + x) * 4
        return 0.2126 * Double(f.bgra[i + 2]) + 0.7152 * Double(f.bgra[i + 1]) + 0.0722 * Double(f.bgra[i])
    }
    /// 글자 화소: 기준(글자 없음) 대비 밝기 차 > 40
    static func ink(_ a: FrameCompare.Frame, _ base: FrameCompare.Frame, _ x: Int, _ y: Int) -> Bool { abs(luma(a, x, y) - luma(base, x, y)) > 40 }
    static func inkCount(_ r: Raster, _ a: FrameCompare.Frame?, _ base: FrameCompare.Frame, excluding others: [CGRect]) -> Int {
        guard let a else { return -1 }
        var n = 0
        for y in 0..<Int(r.rect.height) { for x in 0..<Int(r.rect.width) where r.alpha[y * Int(r.rect.width) + x] >= 128 {
            let px = Int(r.rect.minX) + x, py = Int(r.rect.minY) + y
            if others.contains(where: { $0.contains(CGPoint(x: Double(px) + 0.5, y: Double(py) + 0.5)) }) { continue }
            if ink(a, base, px, py) { n += 1 }
        } }
        return n
    }

    func testApproachBExport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, ta, expected) = try await plan()
        let rs = Self.captions.map(Self.raster)
        for r in rs { note("raster \(r.caption.name): rect \(r.rect) lines \(r.lines) fonts \(r.fonts)") }
        let size = p.videoComposition.renderSize
        XCTAssertNil(p.videoComposition.customVideoCompositorClass, "plan uses the built-in compositor")

        // 기준 내보내기 두 번(인코더 재현성), 빈 도구 하나(도구만의 영향), 자막 내보내기 하나
        func export(_ tag: String, _ vc: AVVideoComposition) async throws -> (URL, Double, UInt64) {
            let dest = out.appendingPathComponent("\(tag).mp4")
            let t0 = Date()
            let outcome = await ExportService.export(withVideoComposition(p, vc), to: .fromSavePanel(dest), sources: [ta]) { _ in }
            XCTAssertEqual(outcome, .completed(dest), tag)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? UInt64) ?? 0
            return (dest, Date().timeIntervalSince(t0), bytes)
        }
        func tool(_ overlayRoot: CALayer?) -> AVVideoComposition {
            let parent = CALayer(), video = CALayer()
            parent.frame = CGRect(origin: .zero, size: size); video.frame = parent.frame
            parent.addSublayer(video)
            if let overlayRoot { parent.addSublayer(overlayRoot) }
            let vc = p.videoComposition.mutableCopy() as! AVMutableVideoComposition
            vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayers: [video], in: parent)
            return vc.copy() as! AVVideoComposition
        }
        let base1 = try await export("base1", p.videoComposition)
        let base2 = try await export("base2", p.videoComposition)
        let empty = try await export("emptytool", tool(nil))
        let subs = try await export("subtitles", tool(Self.overlay(rs, size: size, durationFrames: p.durationFrames).root))
        note(String(format: "export seconds/bytes: base1 %.2f %llu, base2 %.2f %llu, empty tool %.2f %llu, subtitles %.2f %llu (%d frames)",
                    base1.1, base1.2, base2.1, base2.2, empty.1, empty.2, subs.1, subs.2, p.durationFrames))

        // V1: 자막 내보내기 모든 프레임의 화면 코드
        let v = try await ExportJudge.judge(subs.0, clips: [.init(file: "otf-TA.mp4", sourceIn: 0, length: p.durationFrames)], durationFrames: p.durationFrames, checkAudio: false)
        note("V1 subtitles export judge pass \(v.pass) frames \(v.frames) mismatched \(v.mismatchedFrames.prefix(10))")
        XCTAssertTrue(v.pass, "V1 \(v)")

        var probe = Set<Int>()
        for c in Self.captions { for n in [c.start - 1, c.start, c.start + 1, c.end - 1, c.end, c.end + 1] where n >= 0 && n < p.durationFrames { probe.insert(n) } }
        probe.formUnion([0, 15, 34, 42, 50, 60])
        let b1 = try await FrameCompare.decode(base1.0, frames: probe), b2 = try await FrameCompare.decode(base2.0, frames: probe)
        let et = try await FrameCompare.decode(empty.0, frames: probe), sb = try await FrameCompare.decode(subs.0, frames: probe)

        // T1 경계
        var t1Bad: [String] = []
        var t1Rows: [String] = []
        for r in rs {
            for n in [r.caption.start - 1, r.caption.start, r.caption.start + 1, r.caption.end - 1, r.caption.end, r.caption.end + 1] where n >= 0 && n < p.durationFrames {
                guard let s = sb[n], let b = b1[n] else { t1Bad.append("\(r.caption.name) \(n) undecoded"); continue }
                // 이 자막의 알파 ≥ 0.5 화소만 센다. 그 프레임에 보이는(기대) 다른 자막의 사각형 +2 안 화소는 뺀다(첫 실행에서 겹친 자막의 글자를 이 자막으로 센 측정 잘못을 고침)
                let others = rs.filter { $0.caption.name != r.caption.name && Self.expectedVisible($0.caption, frame: n) }.map { $0.rect.insetBy(dx: -2, dy: -2) }
                var count = 0, need = 0, maxDiff = 0.0
                for y in 0..<Int(r.rect.height) { for x in 0..<Int(r.rect.width) where r.alpha[y * Int(r.rect.width) + x] >= 128 {
                    let px = Int(r.rect.minX) + x, py = Int(r.rect.minY) + y
                    if others.contains(where: { $0.contains(CGPoint(x: Double(px) + 0.5, y: Double(py) + 0.5)) }) { continue }
                    need += 1
                    if Self.ink(s, b, px, py) { count += 1; maxDiff = max(maxDiff, abs(Self.luma(s, px, py) - Self.luma(b, px, py))) }
                } }
                let want = Self.expectedVisible(r.caption, frame: n)
                let got = Double(count) >= 0.25 * Double(need) ? true : (count == 0 ? false : nil)
                t1Rows.append("\(r.caption.name) f\(n) ink \(count)/\(need) expected \(want ? "on" : "off")" + (count > 0 && !want ? String(format: " (max luma diff %.0f; same pixels in empty-tool export vs base: %d)", maxDiff, Self.inkCount(r, et[n], b, excluding: others)) : ""))
                // 겹친 다른 자막이 같은 화소를 덮는 경우(노란 자막 아래 한국어)는 알파 기준으로 센 화소 일부가 다른 글자일 수 있어 기록으로 본다
                if got != want { t1Bad.append("\(r.caption.name) f\(n) ink \(count)/\(need) expected \(want)") }
            }
        }
        note("T1 export boundaries:\n  " + t1Rows.joined(separator: "\n  "))
        note("T1 \(t1Bad.isEmpty ? "pass" : "FAIL \(t1Bad)")")
        XCTAssertTrue(t1Bad.isEmpty, "T1 \(t1Bad)")

        // V2 영상 화소(자막 사각형 +4 밖): 기준 두 번, 빈 도구 대 기준, 자막 대 기준
        func outsideStats(_ a: [Int: FrameCompare.Frame], _ b: [Int: FrameCompare.Frame]) -> String {
            let keep = rs.map { $0.rect.insetBy(dx: -4, dy: -4) }
            var n = 0, sum = [0.0, 0.0, 0.0], flatMax = 0, maxAll = 0, nonzero = 0
            for f in probe.sorted() { guard let x = a[f], let y = b[f] else { continue }
                for py in stride(from: 2, to: x.height - 2, by: 2) { for px in stride(from: 2, to: x.width - 2, by: 2) {
                    let pt = CGPoint(x: Double(px) + 0.5, y: Double(py) + 0.5)
                    if keep.contains(where: { $0.contains(pt) }) { continue }
                    let i = (py * x.width + px) * 4
                    var dmax = 0
                    for c in 0..<3 { let d = Int(x.bgra[i + c]) - Int(y.bgra[i + c]); sum[c] += Double(d); dmax = max(dmax, abs(d)) }
                    n += 1; maxAll = max(maxAll, dmax); if dmax > 0 { nonzero += 1 }
                    let l0 = Self.luma(y, px, py)
                    if [(px - 2, py), (px + 2, py), (px, py - 2), (px, py + 2)].allSatisfy({ abs(Self.luma(y, $0.0, $0.1) - l0) <= 2 }) { flatMax = max(flatMax, dmax) }
                } }
            }
            return String(format: "n %d nonzero %d max %d flat max %d mean signed B %.3f G %.3f R %.3f", n, nonzero, maxAll, flatMax, sum[0] / Double(max(1, n)), sum[1] / Double(max(1, n)), sum[2] / Double(max(1, n)))
        }
        let v2base = outsideStats(b2, b1), v2empty = outsideStats(et, b1), v2subs = outsideStats(sb, b1)
        // V2 진단: 빈 도구 대 기준의 프레임별 차이(차이 > 8 화소 수, 최대와 그 위치)
        var v2rows: [String] = []
        for f in probe.sorted() { guard let x = et[f], let y = b1[f] else { continue }
            var big = 0, mx = 0, at = (0, 0), sumAbs = 0.0, n = 0
            for py in stride(from: 0, to: x.height, by: 2) { for px in stride(from: 0, to: x.width, by: 2) {
                let i = (py * x.width + px) * 4
                var d = 0; for c in 0..<3 { d = max(d, abs(Int(x.bgra[i + c]) - Int(y.bgra[i + c]))) }
                sumAbs += Double(d); n += 1; if d > 8 { big += 1 }; if d > mx { mx = d; at = (px, py) }
            } }
            v2rows.append(String(format: "f%d mean|d| %.3f >8: %d max %d at (%d,%d)", f, sumAbs / Double(n), big, mx, at.0, at.1))
        }
        note("V2 empty tool vs base1 per frame:\n  " + v2rows.joined(separator: "\n  "))
        // 내보내기 전(인코딩 전) 버퍼를 오프라인 리더로 얻을 수 있는가(문서는 animationTool을 AVAssetExportSession용으로만 적는다)
        do {
            let r = try AVAssetReader(asset: p.composition)
            let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            o.videoComposition = tool(nil)
            r.add(o)
            let started = r.startReading()
            let sbuf = started ? o.copyNextSampleBuffer() : nil
            note("offline reader with animationTool: started \(started) first sample \(sbuf != nil) status \(r.status.rawValue) error \(String(describing: r.error))")
            r.cancelReading()
        } catch { note("offline reader with animationTool: threw \(error)") }
        note("V2 outside caption rects (2-px sampled, probe frames \(probe.count)): base2 vs base1 [\(v2base)] | empty tool vs base1 [\(v2empty)] | subtitles vs base1 [\(v2subs)]")

        // A1 위치·방향, A2 줄바꿈, A4 잘림: 혼자 보이는 프레임에서
        var aRows: [String] = [], aBad: [String] = []
        // 혼자 보이는 프레임(노란 자막은 40–44에서만 혼자다. 첫 실행은 34를 써서 한국어 글자를 함께 셌다)
        let solo: [String: Int] = ["ko-left": 15, "ja-center": 50, "mixed-right": 60, "overlap-yellow": 42]
        for r in rs {
            guard let n = solo[r.caption.name], let s = sb[n], let b = b1[n] else { continue }
            let w = Int(r.rect.width), h = Int(r.rect.height), x0 = Int(r.rect.minX), y0 = Int(r.rect.minY)
            var inter = 0, union = 0, eb = [Int.max, Int.max, Int.min, Int.min], gb = [Int.max, Int.max, Int.min, Int.min]
            var rowsWithInk = [Bool](repeating: false, count: h)
            for y in 0..<h { for x in 0..<w {
                let e = r.alpha[y * w + x] >= 128, g = Self.ink(s, b, x0 + x, y0 + y)
                // 노란 자막이 덮는 한국어 자리는 A1에서 빼지 않는다: 프레임 15에는 노란 자막이 없다
                if e || g { union += 1 }; if e && g { inter += 1 }
                if e { eb = [min(eb[0], x), min(eb[1], y), max(eb[2], x), max(eb[3], y)] }
                if g { gb = [min(gb[0], x), min(gb[1], y), max(gb[2], x), max(gb[3], y)]; rowsWithInk[y] = true }
            } }
            var bands = 0, inBand = false
            for y in 0..<h { if rowsWithInk[y] && !inBand { bands += 1 }; inBand = rowsWithInk[y] }
            // 잘림: 사각형 +2 밖의 글자 화소(사각형 +12 띠 안에서 찾음)
            var outside = 0
            for y in max(0, y0 - 12)..<min(1080, y0 + h + 12) { for x in max(0, x0 - 12)..<min(1920, x0 + w + 12) {
                if r.rect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { continue }
                if Self.ink(s, b, x, y) { outside += 1 }
            } }
            let iou = Double(inter) / Double(max(1, union))
            let bboxOK = (0..<4).allSatisfy { abs(eb[$0] - gb[$0]) <= 1 }
            aRows.append(String(format: "%@ f%d: expected bbox %@ got %@ IoU %.3f | ink row bands %d (CoreText lines %d) | ink outside rect+2: %d",
                                r.caption.name, n, "\(eb)", "\(gb)", iou, bands, r.lines, outside))
            if !bboxOK || iou < 0.85 { aBad.append("A1 \(r.caption.name)") }
            if bands != r.lines { aBad.append("A2 \(r.caption.name) bands \(bands) lines \(r.lines)") }
            if outside != 0 { aBad.append("A4 \(r.caption.name) \(outside)") }
        }
        // A3 쌓음: 노란 자막 알파 ≥ 0.9이고 한국어 자막 알파 ≥ 0.9인 곳(프레임 34, 둘 다 보임)
        let ko = rs[0], ye = rs[3]
        var both = 0, yellow = 0, white = 0
        if let s = sb[34] {
            for y in Int(ye.rect.minY)..<Int(ye.rect.maxY) { for x in Int(ye.rect.minX)..<Int(ye.rect.maxX) {
                let yi = (y - Int(ye.rect.minY)) * Int(ye.rect.width) + (x - Int(ye.rect.minX))
                guard ye.alpha[yi] >= 230, ko.rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) else { continue }
                let ki = (y - Int(ko.rect.minY)) * Int(ko.rect.width) + (x - Int(ko.rect.minX))
                guard ko.alpha[ki] >= 230 else { continue }
                both += 1
                let i = (y * s.width + x) * 4
                let (bb, gg, rr) = (Int(s.bgra[i]), Int(s.bgra[i + 1]), Int(s.bgra[i + 2]))
                if rr > 150 && gg > 150 && bb < 100 { yellow += 1 } else if min(rr, gg, bb) > 200 { white += 1 }
            } }
        }
        aRows.append("A3 overlap pixels (both alpha ≥ 0.9) \(both): yellow \(yellow) white \(white)")
        if both == 0 || yellow * 10 < both * 9 { aBad.append("A3 yellow \(yellow)/\(both)") }
        note("appearance (export):\n  " + aRows.joined(separator: "\n  "))
        note("A1–A4 \(aBad.isEmpty ? "pass" : "FAIL \(aBad)")")
        XCTAssertTrue(aBad.isEmpty, "\(aBad)")
    }

    /// 인코딩 전 비교(진단, OTF_SB=1): 오프라인 리더(AVAssetReaderVideoCompositionOutput)에 animationTool을 붙여 인코딩 전 버퍼를 읽는다.
    /// 공식 문서는 animationTool을 AVAssetExportSession용으로만 적는다(이 경로는 문서에 없는 동작이며, 내보내기 세션 안의 그리기와 같다는 증명이 아니다).
    /// 기본(도구 없음)·빈 도구·자막 도구 120프레임을 나란히 읽어 자막 사각형 밖 차이, 경계(T1 정의), 모양(A1·A2·A4)을 잰다.
    func testApproachBPreEncodeDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, _, expected) = try await plan()
        let rs = Self.captions.map(Self.raster)
        let size = p.videoComposition.renderSize
        func tool(_ overlayRoot: CALayer?) -> AVVideoComposition {
            let parent = CALayer(), video = CALayer()
            parent.frame = CGRect(origin: .zero, size: size); video.frame = parent.frame
            parent.addSublayer(video)
            if let overlayRoot { parent.addSublayer(overlayRoot) }
            let vc = p.videoComposition.mutableCopy() as! AVMutableVideoComposition
            vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayers: [video], in: parent)
            return vc.copy() as! AVVideoComposition
        }
        func reader(_ vc: AVVideoComposition) async throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
            let r = try AVAssetReader(asset: p.composition)
            let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            o.videoComposition = vc; o.alwaysCopiesSampleData = false
            r.add(o); XCTAssertTrue(r.startReading())
            return (r, o)
        }
        let (rb, ob) = try await reader(p.videoComposition), (re, oe) = try await reader(tool(nil))
        let (rs2, os) = try await reader(tool(Self.overlay(rs, size: size, durationFrames: p.durationFrames).root))
        var frames = 0, emptyIdentical = 0, outsideIdentical = 0, outsideMax = 0, codeBad: [String] = [], tagRows = Set<String>()
        var t1Bad: [String] = [], t1Rows: [String] = [], aRows: [String] = [], aBad: [String] = []
        let solo: [String: Int] = ["ko-left": 15, "ja-center": 50, "mixed-right": 60, "overlap-yellow": 42]
        let keep = rs.map { $0.rect.insetBy(dx: -4, dy: -4) }
        while let sb = ob.copyNextSampleBuffer(), let se = oe.copyNextSampleBuffer(), let ss = os.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sb), let pe = CMSampleBufferGetImageBuffer(se), let ps = CMSampleBufferGetImageBuffer(ss) {
            let n = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded())
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sb), CMSampleBufferGetPresentationTimeStamp(ss))
            frames += 1
            tagRows.insert("base [\(CompositorEquivalenceTests.colorTags(pb))] tool [\(CompositorEquivalenceTests.colorTags(ps))] formats \(CVPixelBufferGetPixelFormatType(pb))/\(CVPixelBufferGetPixelFormatType(ps))")
            let b = FrameCompare.copy(pb), e = FrameCompare.copy(pe), s = FrameCompare.copy(ps)
            if b.bgra == e.bgra { emptyIdentical += 1 } else {
                var mx = 0; for i in stride(from: 0, to: b.bgra.count, by: 4) { for c in 0..<3 { mx = max(mx, abs(Int(b.bgra[i + c]) - Int(e.bgra[i + c]))) } }
                if emptyIdentical == frames - 1 { note("pre-encode empty tool differs from base at frame \(n): max \(mx)") }
            }
            if n < expected.count, !ExportJudge.matches(E2Metrics.measure(ps), expected[n]) { codeBad.append("\(n)") }
            var same = true
            for y in 0..<s.height { for x in 0..<s.width where !keep.contains(where: { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }) {
                let i = (y * s.width + x) * 4
                for c in 0..<3 { let d = abs(Int(s.bgra[i + c]) - Int(b.bgra[i + c])); if d > 0 { same = false; outsideMax = max(outsideMax, d) } }
            } }
            if same { outsideIdentical += 1 }
            for r in rs {
                let c = r.caption
                let others = rs.filter { $0.caption.name != c.name && Self.expectedVisible($0.caption, frame: n) }.map { $0.rect.insetBy(dx: -2, dy: -2) }
                if [c.start - 1, c.start, c.start + 1, c.end - 1, c.end, c.end + 1].contains(n) {
                    var count = 0, need = 0
                    for y in 0..<Int(r.rect.height) { for x in 0..<Int(r.rect.width) where r.alpha[y * Int(r.rect.width) + x] >= 128 {
                        let px = Int(r.rect.minX) + x, py = Int(r.rect.minY) + y
                        if others.contains(where: { $0.contains(CGPoint(x: Double(px) + 0.5, y: Double(py) + 0.5)) }) { continue }
                        need += 1; if Self.ink(s, b, px, py) { count += 1 }
                    } }
                    let want = Self.expectedVisible(c, frame: n)
                    let got: Bool? = Double(count) >= 0.25 * Double(need) ? true : (count == 0 ? false : nil)
                    t1Rows.append("\(c.name) f\(n) ink \(count)/\(need) expected \(want ? "on" : "off")")
                    if got != want { t1Bad.append("\(c.name) f\(n) \(count)/\(need)") }
                }
                if solo[c.name] == n {
                    let w = Int(r.rect.width), h = Int(r.rect.height), x0 = Int(r.rect.minX), y0 = Int(r.rect.minY)
                    var inter = 0, union = 0, eb = [Int.max, Int.max, Int.min, Int.min], gb = [Int.max, Int.max, Int.min, Int.min], rows = [Bool](repeating: false, count: h)
                    var maxAbsInside = 0.0, sumAbsInside = 0.0, nIn = 0
                    for y in 0..<h { for x in 0..<w {
                        let ex = r.alpha[y * w + x] >= 128, g = Self.ink(s, b, x0 + x, y0 + y)
                        if ex || g { union += 1 }; if ex && g { inter += 1 }
                        if ex { eb = [min(eb[0], x), min(eb[1], y), max(eb[2], x), max(eb[3], y)] }
                        if g { gb = [min(gb[0], x), min(gb[1], y), max(gb[2], x), max(gb[3], y)]; rows[y] = true }
                        // 화소 단위 그림 비교: 기대 = 기준 위에 그림을 sRGB 값 그대로 알파 합성(색 관리 없음 가정)
                        let a = Double(r.alpha[y * w + x]) / 255
                        let i = ((y0 + y) * s.width + x0 + x) * 4
                        let fg = [r.caption.rgba.2, r.caption.rgba.1, r.caption.rgba.0].map { Double($0) * 255 }   // B G R
                        for k in 0..<3 { let want = fg[k] * a + Double(b.bgra[i + k]) * (1 - a); let d = abs(want - Double(s.bgra[i + k])); maxAbsInside = max(maxAbsInside, d); sumAbsInside += d; nIn += 1 }
                    } }
                    var bands = 0, inBand = false
                    for y in 0..<h { if rows[y] && !inBand { bands += 1 }; inBand = rows[y] }
                    var outside = 0
                    for y in max(0, y0 - 12)..<min(1080, y0 + h + 12) { for x in max(0, x0 - 12)..<min(1920, x0 + w + 12) {
                        if r.rect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { continue }
                        if Self.ink(s, b, x, y) { outside += 1 }
                    } }
                    let iou = Double(inter) / Double(max(1, union))
                    aRows.append(String(format: "%@ f%d: expected bbox %@ got %@ IoU %.3f | bands %d (lines %d) | outside rect+2 %d | raster vs expected alpha-over composite: max %.1f mean %.2f",
                                        c.name, n, "\(eb)", "\(gb)", iou, bands, r.lines, outside, maxAbsInside, sumAbsInside / Double(max(1, nIn))))
                    if !(0..<4).allSatisfy({ abs(eb[$0] - gb[$0]) <= 1 }) || iou < 0.85 { aBad.append("A1 \(c.name)") }
                    if bands != r.lines { aBad.append("A2 \(c.name)") }
                    if outside != 0 { aBad.append("A4 \(c.name)") }
                }
            }
        }
        rb.cancelReading(); re.cancelReading(); rs2.cancelReading()
        note("pre-encode frames \(frames) | empty tool bit-identical to base \(emptyIdentical)/\(frames) | subtitles: outside caption rects+4 bit-identical \(outsideIdentical)/\(frames) (max diff \(outsideMax)) | codes mismatched \(codeBad)")
        note("pre-encode buffer tags: \(tagRows.sorted())")
        note("pre-encode T1:\n  " + t1Rows.joined(separator: "\n  "))
        note("pre-encode T1 \(t1Bad.isEmpty ? "pass" : "FAIL \(t1Bad)")")
        note("pre-encode appearance:\n  " + aRows.joined(separator: "\n  "))
        note("pre-encode A1/A2/A4 \(aBad.isEmpty ? "pass" : "FAIL \(aBad)")")
    }

    /// 색 진단(OTF_SB=1): 빈 도구가 영상 값을 어떻게 바꾸는가. 인코딩 전 프레임 0·60의 평평한 곳에서 채널별 평균 차이를 밝기 구간별로,
    /// 그리고 기본·빈 도구로 내보낸 파일의 영상 형식 색 태그를 적는다.
    func testApproachBColorDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, ta, _) = try await plan()
        let size = p.videoComposition.renderSize
        let parent = CALayer(), video = CALayer()
        parent.frame = CGRect(origin: .zero, size: size); video.frame = parent.frame; parent.addSublayer(video)
        let mv = p.videoComposition.mutableCopy() as! AVMutableVideoComposition
        mv.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayers: [video], in: parent)
        let toolVC = mv.copy() as! AVVideoComposition
        func first(_ vc: AVVideoComposition, at n: Int) async throws -> FrameCompare.Frame {
            let r = try AVAssetReader(asset: p.composition)
            r.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(n), timescale: 30), duration: CMTime(value: 1, timescale: 30))
            let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            o.videoComposition = vc; r.add(o); XCTAssertTrue(r.startReading())
            defer { r.cancelReading() }
            guard let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { throw ProbeFailure("no frame") }
            return FrameCompare.copy(pb)
        }
        var rows: [String] = []
        for n in [0, 60] {
            let b = try await first(p.videoComposition, at: n), t = try await first(toolVC, at: n)
            var bins = [[Double]](repeating: [0, 0, 0, 0], count: 8)   // 밝기 구간별 (n, dB, dG, dR)
            var samples: [String] = []
            for y in stride(from: 4, to: b.height - 4, by: 3) { for x in stride(from: 4, to: b.width - 4, by: 3) {
                let l0 = Self.luma(b, x, y)
                guard [(x - 2, y), (x + 2, y), (x, y - 2), (x, y + 2)].allSatisfy({ abs(Self.luma(b, $0.0, $0.1) - l0) <= 1 }) else { continue }
                let i = (y * b.width + x) * 4, k = min(7, Int(l0 / 32))
                bins[k][0] += 1; for c in 0..<3 { bins[k][c + 1] += Double(Int(t.bgra[i + c]) - Int(b.bgra[i + c])) }
                if samples.count < 6, (x * 7 + y * 13) % 997 == 0 { samples.append("(\(x),\(y)) base BGR [\(b.bgra[i]),\(b.bgra[i + 1]),\(b.bgra[i + 2])] tool [\(t.bgra[i]),\(t.bgra[i + 1]),\(t.bgra[i + 2])]") }
            } }
            let binStr = bins.enumerated().filter { $0.element[0] > 0 }.map { String(format: "Y%d–%d n%.0f dB %+.2f dG %+.2f dR %+.2f", $0.offset * 32, $0.offset * 32 + 31, $0.element[0], $0.element[1] / $0.element[0], $0.element[2] / $0.element[0], $0.element[3] / $0.element[0]) }
            rows.append("frame \(n) flat-pixel mean (tool − base) by base luma: " + binStr.joined(separator: " | "))
            rows.append("frame \(n) samples: " + samples.joined(separator: " ; "))
        }
        // 내보낸 파일의 색 태그와, 디코딩한 두 파일의 같은 통계
        func binStats(_ b: FrameCompare.Frame, _ t: FrameCompare.Frame) -> String {
            var bins = [[Double]](repeating: [0, 0, 0, 0], count: 8)
            for y in stride(from: 4, to: b.height - 4, by: 3) { for x in stride(from: 4, to: b.width - 4, by: 3) {
                let l0 = Self.luma(b, x, y)
                guard [(x - 2, y), (x + 2, y), (x, y - 2), (x, y + 2)].allSatisfy({ abs(Self.luma(b, $0.0, $0.1) - l0) <= 1 }) else { continue }
                let i = (y * b.width + x) * 4, k = min(7, Int(l0 / 32))
                bins[k][0] += 1; for c in 0..<3 { bins[k][c + 1] += Double(Int(t.bgra[i + c]) - Int(b.bgra[i + c])) }
            } }
            let i = (4 * b.width + 1132) * 4
            return bins.enumerated().filter { $0.element[0] > 0 }.map { String(format: "Y%d–%d n%.0f dB %+.2f dG %+.2f dR %+.2f", $0.offset * 32, $0.offset * 32 + 31, $0.element[0], $0.element[1] / $0.element[0], $0.element[2] / $0.element[0], $0.element[3] / $0.element[0]) }.joined(separator: " | ")
                + " | (1132,4) base [\(b.bgra[i]),\(b.bgra[i + 1]),\(b.bgra[i + 2])] tool [\(t.bgra[i]),\(t.bgra[i + 1]),\(t.bgra[i + 2])]"
        }
        var decoded: [[Int: FrameCompare.Frame]] = []
        for (tag, vc) in [("base", p.videoComposition), ("empty-tool", toolVC)] {
            let dest = out.appendingPathComponent("color-\(tag).mp4")
            let outcome = await ExportService.export(withVideoComposition(p, vc), to: .fromSavePanel(dest), sources: [ta]) { _ in }
            XCTAssertEqual(outcome, .completed(dest))
            let track = try await AVURLAsset(url: dest).loadTracks(withMediaType: .video).first!
            let fd = try await track.load(.formatDescriptions).first!
            let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
            let keys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey].map { $0 as String }
            rows.append("exported \(tag) video format tags: " + keys.map { "\($0)=\(ext[$0].map { "\($0)" } ?? "none")" }.joined(separator: ", "))
            decoded.append(try await FrameCompare.decode(dest, frames: [0, 60]))
        }
        for n in [0, 60] { if let b = decoded[0][n], let t = decoded[1][n] { rows.append("decoded export frame \(n) flat-pixel mean (tool − base): " + binStats(b, t)) } }
        // 인코딩 오차 나누기: 각 내보내기(디코딩)를 도구 없는 인코딩 전 프레임(문서화된 리더 경로)과 비교. 두 내보내기가 원본에 같은 만큼 가까우면
        // 둘 사이의 큰 차이는 인코딩 결과가 달라진 것이다(어느 쪽이 덜 정확한 것이 아님)
        func psnr(_ a: FrameCompare.Frame, _ b: FrameCompare.Frame) -> String {
            var se = 0.0, n = 0, mx = 0
            for i in stride(from: 0, to: a.bgra.count, by: 8) { for c in 0..<3 { let d = Int(a.bgra[i + c]) - Int(b.bgra[i + c]); se += Double(d * d); n += 1; mx = max(mx, abs(d)) } }
            return String(format: "PSNR %.2f dB max %d", 10 * log10(255 * 255 / max(1e-9, se / Double(n))), mx)
        }
        for n in [0, 60] {
            let src = try await first(p.videoComposition, at: n)
            guard let b = decoded[0][n], let t = decoded[1][n] else { continue }
            rows.append("frame \(n) vs pre-encode source (no tool): base export \(psnr(b, src)) | empty-tool export \(psnr(t, src)) | base vs empty-tool export \(psnr(b, t))")
        }
        note("color diagnostics:\n  " + rows.joined(separator: "\n  "))
    }

    // MARK: 프리뷰(T2, T3, V1, P1)

    struct PreviewRig {
        let player: AVPlayer, item: AVPlayerItem, output: AVPlayerItemVideoOutput
        let sync: AVSynchronizedLayer, layers: [String: CALayer], host: CALayer
        let window: NSWindow
    }
    @MainActor func rig(_ p: PlannedComposition, _ rs: [Raster]) async throws -> PreviewRig {
        let item = AVPlayerItem(asset: p.composition)
        item.videoComposition = p.videoComposition   // 기본 합성기 그대로(animationTool 없음)
        item.audioMix = p.audioMix
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        // 실험 전용 작은 창(480×270): 층이 그리기 문맥에 붙어야 presentation 상태가 생긴다(창 없이 돌린 첫 실행은 nil).
        // 영상은 AVPlayerLayer로 같은 창에 보이고, 자막 층 트리는 1920×1080 좌표 그대로 1/4로 줄여 보인다.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 480, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "ON THE FRAME approach B experiment"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 270))
        view.wantsLayer = true
        window.contentView = view
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = view.bounds
        view.layer!.addSublayer(playerLayer)
        let host = CALayer()
        host.anchorPoint = .zero
        host.bounds = CGRect(origin: .zero, size: p.videoComposition.renderSize)
        host.position = .zero
        host.setAffineTransform(CGAffineTransform(scaleX: 0.25, y: 0.25))
        view.layer!.addSublayer(host)
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(10)
        while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        // 동기 층은 항목이 readyToPlay가 된 뒤 묶는다(준비 전에 묶으면 묶이지 않은 채 남는 일이 있었다, docs/SUBTITLE-DESIGN.md §21)
        let sync = AVSynchronizedLayer(playerItem: item)
        sync.frame = host.bounds
        let (root, layers) = Self.overlay(rs, size: host.bounds.size, durationFrames: p.durationFrames)
        sync.addSublayer(root)
        host.addSublayer(sync)
        CATransaction.flush()
        try await Task.sleep(nanoseconds: 100_000_000)
        return PreviewRig(player: player, item: item, output: output, sync: sync, layers: layers, host: host, window: window)
    }
    @MainActor static func visible(_ l: CALayer) -> Bool? { l.presentation().map { $0.opacity > 0.5 } }

    @MainActor func testApproachBPreview() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, _, expected) = try await plan()
        let rs = Self.captions.map(Self.raster)
        let r = try await rig(p, rs)

        // P1: 층 표시 상태(위치·크기·내용 그림)가 내보내기용 구성과 같은가
        let (exportRoot, exportLayers) = Self.overlay(rs, size: p.videoComposition.renderSize, durationFrames: p.durationFrames)
        _ = exportRoot
        var p1: [String] = []
        for c in Self.captions {
            let a = r.layers[c.name]!, b = exportLayers[c.name]!
            let pa = a.presentation()
            let same = a.frame == b.frame && (a.contents as! CGImage) === (b.contents as! CGImage) && pa.map { $0.frame == a.frame } ?? false
            p1.append("\(c.name) frame \(a.frame) presentation frame \(pa.map { "\($0.frame)" } ?? "nil") same-as-export \(same)")
        }
        note("P1 preview layer state:\n  " + p1.joined(separator: "\n  "))

        // T2: 멈춤 상태로 정확 탐색 → 표시 상태. 순서: 탐색들 → 재생 0.5 s → 멈춤 → 탐색들 다시
        func seekCheck(_ label: String) async throws -> [String] {
            var bad: [String] = []
            var frames = Set<Int>()
            for c in Self.captions { for n in [c.start - 1, c.start, c.start + 1, c.end - 1, c.end, c.end + 1] where n >= 0 && n < p.durationFrames { frames.insert(n) } }
            for n in frames.sorted() {
                let t = CMTime(value: CMTimeValue(n), timescale: 30)
                _ = await r.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                try await Task.sleep(nanoseconds: 30_000_000)
                for c in Self.captions {
                    let got = Self.visible(r.layers[c.name]!)
                    if got != Self.expectedVisible(c, frame: n) { bad.append("\(label) f\(n) \(c.name) got \(String(describing: got)) item \(r.item.currentTime().seconds)") }
                }
            }
            note("T2 \(label): \(frames.count) frames × \(Self.captions.count) captions, mismatches \(bad.count) \(bad.prefix(6))")
            return bad
        }
        // 진단: 탐색 뒤 동기 층 시간 상태(프로세스 안에서 보이는 값)
        for n in [15, 50] {
            _ = await r.player.seek(to: CMTime(value: CMTimeValue(n), timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero)
            try await Task.sleep(nanoseconds: 50_000_000)
            let l = r.layers["ko-left"]!, now = CACurrentMediaTime()
            note(String(format: "timing f%d: item %.4f | sync speed %.2f timeOffset %.4f beginTime %.4f | sync presentation speed %@ timeOffset %@ | layer local time (model) %.4f (presentation) %@ | animation keys %@ | model opacity %.1f presentation opacity %@",
                        n, r.item.currentTime().seconds, r.sync.speed, r.sync.timeOffset, r.sync.beginTime,
                        r.sync.presentation().map { String(format: "%.2f", $0.speed) } ?? "nil", r.sync.presentation().map { String(format: "%.4f", $0.timeOffset) } ?? "nil",
                        l.convertTime(now, from: nil), l.presentation().map { String(format: "%.4f", $0.convertTime(now, from: nil)) } ?? "nil",
                        "\(l.animationKeys() ?? [])", l.opacity, l.presentation().map { String(format: "%.2f", $0.opacity) } ?? "nil"))
        }
        var t2 = try await seekCheck("paused seeks")

        // T3: 0부터 재생, 표본(항목 시각, 불투명도)과 비디오 출력 프레임 코드(V1)
        _ = await r.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        r.player.play()
        var samples = 0, nearBoundary = 0, t3Bad: [String] = [], v1Bad: [String] = [], shown = Set<Int>()
        func sample(until stop: Date) async throws {
            while Date() < stop {
                let it = r.item.currentTime().seconds
                for c in Self.captions {
                    guard let got = Self.visible(r.layers[c.name]!) else { continue }
                    samples += 1
                    let s = (Double(c.start) - Self.epsilonFrames) / 30, e = (Double(c.end) - Self.epsilonFrames) / 30
                    if min(abs(it - s), abs(it - e)) < 0.002 { nearBoundary += 1; continue }
                    let want = it >= s && it < e
                    if got != want { t3Bad.append(String(format: "%@ item %.4f got %@", c.name, it, got ? "on" : "off")) }
                }
                let ot = r.output.itemTime(forHostTime: CACurrentMediaTime())
                if r.output.hasNewPixelBuffer(forItemTime: ot) {
                    var disp = CMTime.invalid
                    if let pb = r.output.copyPixelBuffer(forItemTime: ot, itemTimeForDisplay: &disp), disp.isNumeric {
                        let k = Int((disp.seconds * 30).rounded())
                        if k < expected.count { shown.insert(k); if !ExportJudge.matches(E2Metrics.measure(pb), expected[k]) { v1Bad.append("\(k)") } }
                    }
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        try await sample(until: Date().addingTimeInterval(1.2))
        r.player.pause()
        let pausedAt = r.item.currentTime()
        try await Task.sleep(nanoseconds: 100_000_000)
        let pausedFrame = pausedAt.seconds * 30
        var pauseRow: [String] = []
        for c in Self.captions {
            let s = (Double(c.start) - Self.epsilonFrames), e = (Double(c.end) - Self.epsilonFrames)
            let want = pausedFrame >= s && pausedFrame < e
            let got = Self.visible(r.layers[c.name]!)
            pauseRow.append("\(c.name) \(String(describing: got))")
            if got != want { t3Bad.append("paused \(String(format: "%.3f", pausedFrame)) \(c.name) got \(String(describing: got))") }
        }
        note(String(format: "pause at frame %.3f: ", pausedFrame) + pauseRow.joined(separator: ", "))
        // 탐색 뒤 재개
        t2 += try await seekCheck("after pause")
        _ = await r.player.seek(to: CMTime(value: 20, timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero)
        r.player.play()
        try await sample(until: Date().addingTimeInterval(Double(p.durationFrames - 20) / 30 + 0.3))
        r.player.pause()
        note("T3 playback samples \(samples) (within 2 ms of a boundary, recorded only: \(nearBoundary)) mismatches \(t3Bad.count) \(t3Bad.prefix(6))")
        note("V1 preview video output: distinct frames shown \(shown.count) code mismatches \(v1Bad.count) \(v1Bad.prefix(6))")
        r.player.replaceCurrentItem(with: nil)
        r.window.orderOut(nil)
        // T2·T3는 판정하지 않는다(기록만). presentation 값은 화면 표시의 증거가 아니다.
        // 기록이 엇갈린다: 앞선 실행은 자막 층 지역 시각 4.0(항목 시각을 따르지 않음)을 적었고, 같은 날 16:37 실행은 0.5·1.667(따름, T2 불일치 0)을 적었다.
        // 그리고 소유자 화면(2026-10-21)에서는 프로세스 안 상태가 보임인 프레임 54에서도 자막이 보이지 않았다(docs/SUBTITLE-DESIGN.md §20).
        note("T2/T3 not judged: in-process presentation state is not on-screen evidence (owner screenshots show captions absent where in-process state says visible)")
        _ = t2
        XCTAssertTrue(v1Bad.isEmpty, "V1 preview \(v1Bad.prefix(6))")
    }

    /// T4(새 프로세스마다 한 번, OTF_SB_FRESH=1): 자막 층을 붙인 플레이어로 준비 → 500 ms → 0으로 정확 탐색 → 재생.
    /// 비디오 출력이 낸 앞 프레임들과 그 코드를 판정하고, 자막 층 presentation 상태의 어긋남은 기록만 한다(측정 경로가 유효하지 않음).
    @MainActor func testApproachBFreshFirstPlayback() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB_FRESH"] == "1", "새 프로세스 실행은 OTF_SB_FRESH=1일 때만")
        let (p, _, expected) = try await plan()
        let rs = Self.captions.map(Self.raster)
        let r = try await rig(p, rs)
        let ready = r.item.currentTime()
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = await r.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        r.player.play()
        var order: [Int] = [], bad: [String] = [], overlayBad: [String] = []
        let stop = Date().addingTimeInterval(2.0)
        while Date() < stop {
            let ot = r.output.itemTime(forHostTime: CACurrentMediaTime())
            if r.output.hasNewPixelBuffer(forItemTime: ot) {
                var disp = CMTime.invalid
                if let pb = r.output.copyPixelBuffer(forItemTime: ot, itemTimeForDisplay: &disp), disp.isNumeric {
                    let k = Int((disp.seconds * 30).rounded())
                    order.append(k)
                    if k < expected.count, !ExportJudge.matches(E2Metrics.measure(pb), expected[k]) { bad.append("\(k)") }
                }
            }
            let it = r.item.currentTime().seconds * 30
            for c in Self.captions {
                let s = Double(c.start) - Self.epsilonFrames, e = Double(c.end) - Self.epsilonFrames
                if min(abs(it - s), abs(it - e)) < 0.06 { continue }   // 2 ms(0.06프레임) 안은 기록만
                if let got = Self.visible(r.layers[c.name]!), got != (it >= s && it < e) { overlayBad.append(String(format: "%@ %.3f", c.name, it)) }
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        r.player.pause(); r.player.replaceCurrentItem(with: nil); r.window.orderOut(nil)
        let firstFour = (0..<4).filter { !order.contains($0) }
        note("T4 fresh first playback: ready item time \(ready.value)/\(ready.timescale) | delivered order \(order.prefix(10)) | missing among 0–3 \(firstFour) | code mismatches \(bad.count) | overlay mismatches \(overlayBad.count) \(overlayBad.prefix(4))")
        XCTAssertTrue(firstFour.isEmpty, "startup frames missing \(firstFour)")
        XCTAssertTrue(bad.isEmpty)
        // 자막 층 상태는 기록만(프로세스 안 presentation이 항목 시각을 따르지 않음, testApproachBPreview 기록)
    }
}
