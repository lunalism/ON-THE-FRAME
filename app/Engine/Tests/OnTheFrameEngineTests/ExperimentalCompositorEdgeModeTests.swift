import AVFoundation
import Foundation
import ImageIO
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E4D-COMPOSITOR-PROTOTYPE-33(2026-11-24): 같은 계획(CompositionPlanner.plan)을 세 가지로 그려 견준다.
/// - default: 계획의 기본 합성기(제품이 쓰는 것)
/// - historical: 실험 합성기, 먼 쪽 가장자리 0.25 규칙(S1b 기준선, 기본 선택값)
/// - corrected: 실험 합성기, `edgeCoverage: .fullRectangle`(실험 — 앱과 계획의 제품 선택은 쓰지 않는다)
/// 모두 내보내기와 같은 리더 설정(420v, 709 색 속성)으로 읽고 MP4를 만들지 않는다.
/// 이 파일의 시험은 준비만 된 것이며, 실행하기 전에는 통과·실패를 주장하지 않는다.
final class ExperimentalCompositorEdgeModeTests: XCTestCase {
    typealias Edge = CompositionEdgeCoverageTests
    /// LocalizedError: 시험 실행기가 던져진 오류의 글을 그대로 적게 한다(2026-11-24: 글 없이 "Failure error 1"로만 남았다)
    struct Failure: Error, CustomStringConvertible, LocalizedError { let description: String; init(_ d: String) { description = d }
        var errorDescription: String? { description } }
    enum Renderer: String, CaseIterable { case defaultCompositor = "default", historical, corrected }
    static let dir = Edge.dir
    /// 밝기·색차 허용 차(8비트): S1b 재검토가 잰 밝기 보간 차이의 상한(2)
    static let tolerance = 2

    struct Planes { let w: Int, h: Int, y: [UInt8], c: [UInt8]
        func luma(_ x: Int, _ yy: Int) -> Int { Int(y[yy * w + x]) }
        func chroma(_ x: Int, _ yy: Int) -> (cb: Int, cr: Int) { let o = (yy / 2) * w + 2 * (x / 2); return (Int(c[o]), Int(c[o + 1])) } }

    static func videoComposition(_ plan: PlannedComposition, _ renderer: Renderer, log: ExperimentalCompositorLog? = nil) throws -> AVVideoComposition {
        switch renderer {
        case .defaultCompositor: return plan.videoComposition
        case .historical: return try ExperimentalComposition.videoComposition(from: plan.videoComposition, options: .init(), diagnostics: log)
        case .corrected: return try ExperimentalComposition.videoComposition(from: plan.videoComposition, options: .init(edgeCoverage: .fullRectangle), diagnostics: log)
        }
    }
    /// 프레임 k를 내보내기와 같은 리더 설정으로 읽는다(행 끝 채움 제외)
    static func frame(_ plan: PlannedComposition, _ renderer: Renderer, _ k: Int) async throws -> Planes {
        let reader = try AVAssetReader(asset: plan.composition)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat]
        settings[AVVideoColorPropertiesKey] = SubtitleExporter.color709
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await plan.composition.loadTracks(withMediaType: .video), videoSettings: settings)
        output.videoComposition = try videoComposition(plan, renderer)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure("reader start (\(renderer.rawValue))") }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            guard Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 30).rounded()) == k, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard CVPixelBufferGetPixelFormatType(pb) == SubtitleExporter.pixelFormat else { throw Failure("pixel format (\(renderer.rawValue))") }
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { throw Failure("planes") }
            let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            var y = [UInt8](repeating: 0, count: w * h), c = [UInt8](repeating: 0, count: w * (h / 2))
            y.withUnsafeMutableBytes { d in for row in 0..<h { memcpy(d.baseAddress! + row * w, yb + row * ybpr, w) } }
            c.withUnsafeMutableBytes { d in for row in 0..<(h / 2) { memcpy(d.baseAddress! + row * w, cb + row * cbpr, w) } }
            return Planes(w: w, h: h, y: y, c: c)
        }
        throw Failure("frame \(k) not produced (\(renderer.rawValue))")
    }

    /// 프레임 여러 개를 한 번에 읽는다. 리더가 실제로 낸 프레임 번호 전체도 돌려준다(빈 구간·경계에서 프레임이 나오는지 보기 위함).
    /// keepAll에 든 프레임 번호는 wanted에 없어도 담는다(빈 구간에서 리더가 실제로 낸 프레임을 모두 보기 위함).
    static func frames(_ plan: PlannedComposition, _ renderer: Renderer, _ wanted: Set<Int>, keepAll: Set<Int> = []) async throws -> (kept: [Int: Planes], produced: [Int]) {
        let reader = try AVAssetReader(asset: plan.composition)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat]
        settings[AVVideoColorPropertiesKey] = SubtitleExporter.color709
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await plan.composition.loadTracks(withMediaType: .video), videoSettings: settings)
        output.videoComposition = try videoComposition(plan, renderer)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure("reader start (\(renderer.rawValue)): \(String(describing: reader.error))") }
        defer { reader.cancelReading() }
        var kept: [Int: Planes] = [:], produced: [Int] = []
        while let sample = output.copyNextSampleBuffer() {
            let k = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 30).rounded())
            produced.append(k)
            guard wanted.contains(k) || keepAll.contains(k), kept[k] == nil, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard CVPixelBufferGetPixelFormatType(pb) == SubtitleExporter.pixelFormat else { throw Failure("pixel format at frame \(k) (\(renderer.rawValue))") }
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { throw Failure("planes at frame \(k)") }
            let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            var y = [UInt8](repeating: 0, count: w * h), c = [UInt8](repeating: 0, count: w * (h / 2))
            y.withUnsafeMutableBytes { d in for row in 0..<h { memcpy(d.baseAddress! + row * w, yb + row * ybpr, w) } }
            c.withUnsafeMutableBytes { d in for row in 0..<(h / 2) { memcpy(d.baseAddress! + row * w, cb + row * cbpr, w) } }
            kept[k] = Planes(w: w, h: h, y: y, c: c)
        }
        if reader.status == .failed { throw Failure("reader failed (\(renderer.rawValue)) after \(produced.count) frames: \(String(describing: reader.error))") }
        return (kept, produced)
    }
    /// 무늬 영상의 프레임 번호 칸(사각형 위쪽의 여덟 칸)을 읽는다
    static func identity(_ f: Planes, x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
        var n = 0
        let bw = (x1 - x0) / 8, y = y0 + (y1 - y0) / 16
        for i in 0..<8 where f.luma(x0 + i * bw + bw / 2, y) > 140 { n |= 1 << i }
        return n
    }
    /// 여러 프레임의 같은 부분을 가로로 나란히 붙인 PNG(BT.709 영상 범위 → RGB, 사이에 흰 줄 6화소). 눈으로 견주기 위한 증거다.
    static func saveSideBySide(_ parts: [Planes], x: Int, y: Int, width: Int, height: Int, to url: URL) {
        guard !parts.isEmpty, width > 0, height > 0, !FileManager.default.fileExists(atPath: url.path) else { return }
        let gap = 6, total = parts.count * width + (parts.count - 1) * gap
        var rgb = [UInt8](repeating: 255, count: total * height * 4)
        for (i, f) in parts.enumerated() {
            for row in 0..<height { for col in 0..<width {
                let px = min(f.w - 1, max(0, x + col)), py = min(f.h - 1, max(0, y + row)), c = f.chroma(px, py)
                let yy = (Double(f.luma(px, py)) - 16) * 255 / 219, cb = (Double(c.cb) - 128) * 255 / 224, cr = (Double(c.cr) - 128) * 255 / 224
                let o = (row * total + i * (width + gap) + col) * 4
                rgb[o] = UInt8(max(0, min(255, yy + 1.5748 * cr))); rgb[o + 1] = UInt8(max(0, min(255, yy - 0.1873 * cb - 0.4681 * cr))); rgb[o + 2] = UInt8(max(0, min(255, yy + 1.8556 * cb)))
            } }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let provider = CGDataProvider(data: Data(rgb) as CFData),
              let image = CGImage(width: total, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: total * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
    }

    /// 단색 H.264 영상(소리 없음, 30 fps 30프레임). 색이 있는 판은 이 파일에서만 쓴다.
    static func colorPlate(_ width: Int, _ height: Int, blue: UInt8, green: UInt8, red: UInt8, frames: Int = 30) async throws -> MediaAsset {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("plate-\(width)x\(height)-\(blue)-\(green)-\(red)-\(frames)f.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            guard writer.canAdd(input) else { throw Failure("video input") }
            writer.add(input)
            guard writer.startWriting() else { throw Failure("writer start: \(String(describing: writer.error))") }
            writer.startSession(atSourceTime: .zero)
            for f in 0..<frames {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                var made: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let pb = made else { throw Failure("pixel buffer") }
                CVPixelBufferLockBaseAddress(pb, [])
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    let p = base.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
                    for row in 0..<height { for x in 0..<width { let o = row * bpr + x * 4; p[o] = blue; p[o + 1] = green; p[o + 2] = red; p[o + 3] = 255 } }
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30)) else { throw Failure("video append") }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw Failure("writer finish: \(String(describing: writer.error))") }
        }
        return try await MediaProbe.inspect(url)
    }

    struct Coverage { var right = 0, bottom = 0, left = 0, top = 0, inside = 0, outside = 0
        var text: String { "uncovered right \(right) bottom \(bottom) left \(left) top \(top), inside total \(inside), drawn outside \(outside)" } }
    /// 기대 사각형 안에서 원본 밝기(±Edge.tolerance)가 아닌 화소와, 사각형 밖에서 검정이 아닌 화소
    static func coverage(_ f: Planes, x0: Int, y0: Int, x1: Int, y1: Int, source: Int) -> Coverage {
        var c = Coverage()
        func miss(_ x: Int, _ y: Int) -> Bool { abs(f.luma(x, y) - source) > Edge.tolerance }
        for y in y0..<y1 { if miss(x1 - 1, y) { c.right += 1 }; if miss(x0, y) { c.left += 1 } }
        for x in x0..<x1 { if miss(x, y1 - 1) { c.bottom += 1 }; if miss(x, y0) { c.top += 1 } }
        for y in y0..<y1 { for x in x0..<x1 where miss(x, y) { c.inside += 1 } }
        for y in 0..<f.h { for x in 0..<f.w where (x < x0 || x >= x1 || y < y0 || y >= y1) && f.luma(x, y) > Edge.black { c.outside += 1 } }
        return c
    }

    /// 한 구성을 세 가지로 그려, 고친 방식은 기대 사각형을 끝 행·열까지 덮고 밖에 그리지 않는지 본다. 다른 둘의 측정값은 기록한다.
    func compare(_ width: Int, _ height: Int, scale: Double = 1, x: Double = 0, y: Double = 0, file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = try await Edge.plate(width, height)
        let clip = UUID()
        var timeline = try Timeline().registering(asset).inserting(media: asset.id, clipID: clip)
        let transform = ClipTransform(scale: scale, x: x, y: y)
        if transform != .identity { timeline = try timeline.settingTransform(clip: clip, transform) }
        let rect = Edge.expectedRect(width: width, height: height, scale: scale, x: x, y: y)
        let x0 = Int(rect.minX.rounded()), y0 = Int(rect.minY.rounded()), x1 = Int(rect.maxX.rounded()), y1 = Int(rect.maxY.rounded())
        let label = "\(width)x\(height) scale \(scale) offset (\(x), \(y)) → x \(x0)..<\(x1) y \(y0)..<\(y1)"
        let plan = try await CompositionPlanner.plan(timeline, media: [asset.id: asset])
        let source = try await Edge.sourceLuma(asset, frame: 5)
        var frames: [Renderer: Planes] = [:]
        for r in Renderer.allCases {
            let f = try await Self.frame(plan, r, 5)
            XCTAssertEqual(f.w, 1920, file: file, line: line); XCTAssertEqual(f.h, 1080, file: file, line: line)
            frames[r] = f
            print("EDGE-MODE \(label) | \(r.rawValue): \(Self.coverage(f, x0: x0, y0: y0, x1: x1, y1: y1, source: source).text)")
        }
        guard let corrected = frames[.corrected], let base = frames[.defaultCompositor] else { return }
        let c = Self.coverage(corrected, x0: x0, y0: y0, x1: x1, y1: y1, source: source)
        XCTAssertEqual(c.right, 0, "\(label): 고친 방식의 오른쪽 끝 열", file: file, line: line)
        XCTAssertEqual(c.bottom, 0, "\(label): 고친 방식의 아래 끝 행", file: file, line: line)
        XCTAssertEqual(c.left, 0, "\(label): 고친 방식의 왼쪽 끝 열", file: file, line: line)
        XCTAssertEqual(c.top, 0, "\(label): 고친 방식의 위 끝 행", file: file, line: line)
        XCTAssertEqual(c.inside, 0, "\(label): 고친 방식의 기대 사각형 안", file: file, line: line)
        XCTAssertEqual(c.outside, 0, "\(label): 고친 방식이 사각형 밖에 그린 화소", file: file, line: line)
        // 안쪽 색: 기본 합성기가 그린 화소(끝 열·행 제외)와 밝기·색차가 허용 차 안에서 같다
        var worstY = 0, worstC = 0
        for py in stride(from: y0, to: y1 - 1, by: 1) { for px in stride(from: x0, to: x1 - 1, by: 1) {
            worstY = max(worstY, abs(corrected.luma(px, py) - base.luma(px, py)))
            let a = corrected.chroma(px, py), b = base.chroma(px, py)
            worstC = max(worstC, abs(a.cb - b.cb), abs(a.cr - b.cr))
        } }
        XCTAssertLessThanOrEqual(worstY, Self.tolerance, "\(label): 기본 합성기와의 안쪽 밝기 차이", file: file, line: line)
        XCTAssertLessThanOrEqual(worstC, Self.tolerance, "\(label): 기본 합성기와의 안쪽 색차 차이", file: file, line: line)
    }

    func testCorrectedModeCoversSmallSourceScaledToFullFrame() async throws { try await compare(320, 180) }
    func testCorrectedModeKeepsNativeSizeSource() async throws { try await compare(1920, 1080) }
    func testCorrectedModeKeepsModeratelyScaledSource() async throws { try await compare(1280, 720) }
    func testCorrectedModeCoversLetterboxedSourceAndLeavesBarsBlack() async throws { try await compare(640, 480) }
    func testCorrectedModeCoversTranslatedScaledLayer() async throws { try await compare(320, 180, scale: 0.5, x: 100, y: 50) }

    /// 색 표기가 없는 SD 색 판(640×480, 2.25배): 고친 방식의 가운데 색이 기본 합성기와 같은가. 엄격하게 본다(허용 차를 넓히지 않는다).
    /// 2026-11-24 메모리 측정에서는 Core Image 경로가 달랐다(기본 [83,110,206] 대 [69,119,207]). 실험 합성기로는 아직 실행하지 않았다.
    func testUntaggedSDColorMatchesDefaultCompositor() async throws {
        let asset = try await Self.colorPlate(640, 480, blue: 40, green: 40, red: 220)
        let timeline = try Timeline().registering(asset).inserting(media: asset.id)
        let plan = try await CompositionPlanner.plan(timeline, media: [asset.id: asset])
        var values: [Renderer: (Int, Int, Int)] = [:]
        for r in Renderer.allCases {
            let f = try await Self.frame(plan, r, 5), c = f.chroma(960, 540)
            values[r] = (f.luma(960, 540), c.cb, c.cr)
            print("EDGE-MODE SD colour | \(r.rawValue): Y \(f.luma(960, 540)) Cb \(c.cb) Cr \(c.cr)")
        }
        guard let base = values[.defaultCompositor], let corrected = values[.corrected] else { return XCTFail("frames") }
        XCTAssertLessThanOrEqual(abs(corrected.0 - base.0), Self.tolerance, "Y: default \(base) corrected \(corrected)")
        XCTAssertLessThanOrEqual(abs(corrected.1 - base.1), Self.tolerance, "Cb: default \(base) corrected \(corrected)")
        XCTAssertLessThanOrEqual(abs(corrected.2 - base.2), Self.tolerance, "Cr: default \(base) corrected \(corrected)")
    }

    /// 겹친 두 영상 레인, 빈 구간, 클립 경계, 쌓는 차례, 원본 시각(SP-EXPORT-E4D-GATE-CLOSURE-39에서 다시 쓰고 REAL-PREVIEW-GATE-40에서 빈 구간 판정을 바로잡음).
    /// 타임라인: [0,10) 영상 없음 · [10,20) 큰 무늬만 · [20,40) 큰 무늬 위에 작은 무늬(3배 확대, 옮김) · [40,50) 작은 무늬만 · [50,60) 영상 없음 · [60,90) 큰 무늬.
    /// 무늬의 프레임 번호 칸으로 어느 원본 프레임이 보이는지 읽는다(큰 무늬는 타임라인 프레임 − 10 또는 − 60, 작은 무늬는 − 20).
    /// 빈 구간(2026-11-24 실행에서 확인): 리더는 30 fps 격자의 모든 자리에 표본을 내지 않는다 — 영상이 없는 구간에서는 프레임이 드물게 나온다.
    /// 그래서 빈 구간의 자리 k는 "k 이전에 리더가 낸 마지막 프레임"으로 본다(내보내기 펌프가 프레임을 격자에 펼치는 것과 같은 규칙).
    /// 그 프레임은 반드시 그 빈 구간 안에서 나온 것이어야 하고(앞 구간의 색 있는 프레임이 남아 있으면 안 된다) 검정이어야 한다.
    func testOverlappingLanesGapsBoundariesOrderAndTiming() async throws {
        let wide = try await Self.patternMovie(1920, 1080), small = try await Self.patternMovie(480, 270)
        let transform = ClipTransform(scale: 0.75, x: 100, y: 60)
        let rect = Edge.expectedRect(width: 480, height: 270, scale: 0.75, x: 100, y: 60)
        let x0 = Int(rect.minX.rounded()), y0 = Int(rect.minY.rounded()), x1 = Int(rect.maxX.rounded()), y1 = Int(rect.maxY.rounded())
        let wanted: Set<Int> = [10, 15, 19, 20, 30, 39, 40, 45, 49, 60, 75, 89]
        let gaps = [0..<10, 50..<60]
        let gapFrames = Set(gaps.flatMap { Array($0) })
        // 작은 무늬가 위에 보이는 레인 배치를 기본 합성기로 고른다(프레임 30에서 작은 무늬의 번호 10이 읽힌다)
        var chosen: PlannedComposition?
        for smallOnSecond in [false, true] {
            let second = UUID(), smallClip = UUID()
            let wideLane = smallOnSecond ? Lane.videoID : second, smallLane = smallOnSecond ? second : Lane.videoID
            var t = try Timeline().registering(wide).registering(small).addingLane(.video, name: "V2", id: second)
            t = try t.placing(media: wide.id, at: 10, videoLane: wideLane, audioLane: nil)
            t = try t.placing(media: small.id, at: 20, videoLane: smallLane, audioLane: nil, clipID: smallClip)
            t = try t.placing(media: wide.id, at: 60, videoLane: wideLane, audioLane: nil)
            t = try t.settingTransform(clip: smallClip, transform)
            let plan = try await CompositionPlanner.plan(t, media: [wide.id: wide, small.id: small])
            let structure = plan.videoComposition.instructions.compactMap { $0 as? AVVideoCompositionInstruction }
                .map { "\(Int(($0.timeRange.start.seconds * 30).rounded()))+\(Int(($0.timeRange.duration.seconds * 30).rounded())):\($0.layerInstructions.count)" }
            print("LANES plan (small on second lane \(smallOnSecond)): duration \(plan.durationFrames) frames, instructions start+length:layers \(structure)")
            do {
                let probe = try await Self.frames(plan, .defaultCompositor, [30])
                print("LANES probe default: produced \(probe.produced.count) frames, small number at frame 30: \(probe.kept[30].map { Self.identity($0, x0: x0, y0: y0, x1: x1, y1: y1) } ?? -1)")
                if let f = probe.kept[30], Self.identity(f, x0: x0, y0: y0, x1: x1, y1: y1) == 10 { chosen = plan; break }
            } catch { print("LANES probe default failed: \(error)") }
        }
        guard let plan = chosen else { return XCTFail("재료: 작은 무늬가 위에 보이는 레인 배치를 찾지 못했다(위 LANES 줄 참고)") }
        XCTAssertEqual(plan.durationFrames, 90)
        for r in Renderer.allCases {
            let got: (kept: [Int: Planes], produced: [Int])
            do { got = try await Self.frames(plan, r, wanted, keepAll: gapFrames) } catch { XCTFail("\(r.rawValue): 읽기 오류 — \(error)"); continue }
            let missing = wanted.filter { got.kept[$0] == nil }.sorted()
            print("LANES \(r.rawValue): reader emitted \(got.produced.count) of 90 grid positions; inside the empty intervals it emitted \(got.produced.filter { gapFrames.contains($0) }); wanted video frames missing \(missing)")
            XCTAssertEqual(missing, [], "\(r.rawValue): 영상이 있는 자리에서 읽히지 않은 프레임")
            func wideNumber(_ k: Int) -> Int? { got.kept[k].map { Self.identity($0, x0: 0, y0: 0, x1: 1920, y1: 1080) } }
            func smallNumber(_ k: Int) -> Int? { got.kept[k].map { Self.identity($0, x0: x0, y0: y0, x1: x1, y1: y1) } }
            func bright(_ f: Planes, outsideSmallOnly: Bool) -> Int {
                var n = 0
                for py in 0..<f.h { for px in 0..<f.w where f.luma(px, py) > Edge.black && !(outsideSmallOnly && px >= x0 && px < x1 && py >= y0 && py < y1) { n += 1 } }
                return n
            }
            // 영상이 없는 구간: 그 자리에 보이는 것은 그 구간 안에서 리더가 낸 마지막 프레임이고, 검정이어야 한다
            for gap in gaps {
                let emitted = got.produced.filter { gap.contains($0) }.sorted()
                XCTAssertFalse(emitted.isEmpty, "\(r.rawValue) 빈 구간 \(gap): 리더가 이 구간 안에서 프레임을 하나도 내지 않았다(앞 구간의 프레임이 남는다)")
                for k in emitted { if let f = got.kept[k] { XCTAssertEqual(bright(f, outsideSmallOnly: false), 0, "\(r.rawValue) 빈 구간 \(gap): 리더가 낸 프레임 \(k)는 검정") } }
                for k in [gap.lowerBound + 5, gap.upperBound - 1] {
                    guard let held = got.produced.filter({ $0 <= k }).max() else { XCTFail("\(r.rawValue) 자리 \(k): 그 이전에 나온 프레임이 없다"); continue }
                    XCTAssertTrue(gap.contains(held), "\(r.rawValue) 자리 \(k): 보이는 프레임 \(held)이 빈 구간 \(gap) 밖에서 나온 것이다")
                }
            }
            // 큰 무늬만 보이는 구간과 그 경계(원본 프레임 = 타임라인 프레임 − 10, 둘째 배치는 − 60)
            for (k, number) in [(10, 0), (15, 5), (19, 9), (60, 0), (75, 15), (89, 29)] { if let seen = wideNumber(k) { XCTAssertEqual(seen, number, "\(r.rawValue) 프레임 \(k): 큰 무늬의 원본 프레임") } }
            // 겹친 구간: 두 원본의 시각이 모두 맞고, 작은 무늬가 위에 있다(그 칸이 읽힌다)
            for (k, w, s) in [(20, 10, 0), (30, 20, 10), (39, 29, 19)] {
                if let seen = wideNumber(k) { XCTAssertEqual(seen, w, "\(r.rawValue) 프레임 \(k): 큰 무늬의 원본 프레임") }
                if let seen = smallNumber(k) { XCTAssertEqual(seen, s, "\(r.rawValue) 프레임 \(k): 위에 놓인 작은 무늬의 원본 프레임") }
            }
            // 작은 무늬만 보이는 구간과 끝 경계: 작은 무늬 밖은 검정
            for (k, s) in [(40, 20), (45, 25), (49, 29)] {
                if let seen = smallNumber(k) { XCTAssertEqual(seen, s, "\(r.rawValue) 프레임 \(k): 작은 무늬의 원본 프레임") }
                if let f = got.kept[k] { XCTAssertEqual(bright(f, outsideSmallOnly: true), 0, "\(r.rawValue) 프레임 \(k): 작은 무늬 밖은 검정") }
            }
            // 작은 무늬(3배 확대)의 먼 쪽 가장자리: 검정 배경 위인 프레임 45에서 본다. 고친 방식은 끝까지 덮어야 한다. 다른 방식은 적기만 한다.
            if let f = got.kept[45] {
                let right = (y0..<y1).filter { f.luma(x1 - 1, $0) <= Edge.black }.count, bottom = (x0..<x1).filter { f.luma($0, y1 - 1) <= Edge.black }.count
                print("LANES \(r.rawValue): frame 45 small rect x \(x0)..<\(x1) y \(y0)..<\(y1) uncovered right \(right)/\(y1 - y0) bottom \(bottom)/\(x1 - x0)")
                if r == .corrected { XCTAssertEqual(right, 0, "고친 방식: 오른쪽 끝 열"); XCTAssertEqual(bottom, 0, "고친 방식: 아래 끝 행") }
            }
        }
    }

    // MARK: GATE 2 — 층 수에 따른 색·보간(SP-EXPORT-E4D-COMPOSITOR-GATE-38)

    /// 무늬가 있는 H.264 영상(소리 없음, 30 fps 30프레임): 색 기울기, 프레임 번호 칸, 1·2·4화소 바둑판(여러 색), 움직이는 막대와 대각선. 어두운 화소가 없다.
    static func patternMovie(_ width: Int, _ height: Int) async throws -> MediaAsset {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pattern-\(width)x\(height).mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            guard writer.canAdd(input) else { throw Failure("video input") }
            writer.add(input)
            guard writer.startWriting() else { throw Failure("writer start: \(String(describing: writer.error))") }
            writer.startSession(atSourceTime: .zero)
            let w = width, h = height, band = h / 8, block = w / 8
            for n in 0..<30 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                var made: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let pb = made else { throw Failure("pixel buffer") }
                CVPixelBufferLockBaseAddress(pb, [])
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    let p = base.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
                    for y in 0..<h { for x in 0..<w {
                        var r = 60 + 150 * x / w, g = 60 + 150 * y / h, b = 120
                        if y < band { let bit = (n >> min(7, x / block)) & 1; r = bit == 1 ? 235 : 90; g = r; b = r }
                        else if y >= h / 4 && y < h / 2 {
                            if x >= w / 8 && x < 3 * w / 8 { if (x + y) % 2 == 0 { r = 200; g = 60; b = 60 } else { r = 60; g = 200; b = 60 } }
                            else if x >= 3 * w / 8 && x < 5 * w / 8 { if ((x / 2) + (y / 2)) % 2 == 0 { r = 60; g = 60; b = 220 } else { r = 220; g = 220; b = 60 } }
                            else if x >= 5 * w / 8 && x < 7 * w / 8 { let v = ((x / 4) + (y / 4)) % 2 == 0 ? 80 : 220; r = v; g = v; b = v }
                        } else if y >= h / 2 && y < 3 * h / 4 { let x0 = (n * 7) % (w - 16); if x >= x0 && x < x0 + 8 { r = 240; g = 240; b = 80 } }
                        else if y >= 3 * h / 4 { if (x + y + n) % 16 < 2 { r = 235; g = 235; b = 235 } }
                        let o = y * bpr + x * 4
                        p[o] = UInt8(b); p[o + 1] = UInt8(g); p[o + 2] = UInt8(r); p[o + 3] = 255
                    } }
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: 30)) else { throw Failure("video append") }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw Failure("writer finish: \(String(describing: writer.error))") }
        }
        return try await MediaProbe.inspect(url)
    }

    struct Diff { var n = 0, maxY = 0, maxC = 0, sumY = 0, sumC = 0, over = 0
        var text: String { n == 0 ? "no pixels" : String(format: "Y max %d mean %.2f, chroma max %d mean %.2f, beyond %d: %.2f%% of %d px", maxY, Double(sumY) / Double(n), maxC, Double(sumC) / Double(n), ExperimentalCompositorEdgeModeTests.tolerance, 100 * Double(over) / Double(n), n) } }
    /// 두 프레임의 차이: 사각형과 화면이 겹치는 곳에서 가장자리 2화소를 뺀 안쪽(사각형의 마지막 열·행은 늘 빠진다)
    static func diff(_ a: Planes, _ b: Planes, x0: Int, y0: Int, x1: Int, y1: Int) -> Diff {
        var d = Diff()
        for y in max(0, y0 + 2)..<max(0, min(1080, y1 - 2)) { for x in max(0, x0 + 2)..<max(0, min(1920, x1 - 2)) {
            let dy = abs(a.luma(x, y) - b.luma(x, y)), ca = a.chroma(x, y), cb = b.chroma(x, y)
            let dc = max(abs(ca.cb - cb.cb), abs(ca.cr - cb.cr))
            d.n += 1; d.sumY += dy; d.sumC += dc; d.maxY = max(d.maxY, dy); d.maxC = max(d.maxC, dc)
            if dy > tolerance || dc > tolerance { d.over += 1 }
        } }
        return d
    }
    /// 사각형의 마지막 열·행(화면 안에 있을 때)에서 검정에 가까운 화소 수. 재료에는 어두운 화소가 없다.
    static func farEdges(_ f: Planes, x0: Int, y0: Int, x1: Int, y1: Int) -> String {
        var text = ""
        if x1 <= 1920 { text += "right uncovered \((max(0, y0)..<min(1080, y1)).filter { f.luma(x1 - 1, $0) <= Edge.black }.count)/\(min(1080, y1) - max(0, y0))" } else { text += "right edge off canvas" }
        if y1 <= 1080 { text += ", bottom uncovered \((max(0, x0)..<min(1920, x1)).filter { f.luma($0, y1 - 1) <= Edge.black }.count)/\(min(1920, x1) - max(0, x0))" } else { text += ", bottom edge off canvas" }
        return text
    }
    static func timeline(clip: MediaAsset, transform: ClipTransform, backdrop: MediaAsset?, clipOnSecondLane: Bool) throws -> Timeline {
        let second = UUID(), clipID = UUID()
        var t = Timeline().registering(clip)
        if let backdrop {
            t = try t.registering(backdrop).addingLane(.video, name: "V2", id: second)
            // 소리가 있는 영상은 소리 레인도 주어야 한다(Timeline.placing은 없으면 laneKindMismatch를 던진다 — 2026-11-24 실제 영상에서 확인)
            t = try t.placing(media: clip.id, at: 0, videoLane: clipOnSecondLane ? second : Lane.videoID, audioLane: clip.hasAudio ? Lane.audioID : nil, clipID: clipID)
            t = try t.placing(media: backdrop.id, at: 0, videoLane: clipOnSecondLane ? Lane.videoID : second, audioLane: nil)
        } else {
            t = try t.inserting(media: clip.id, clipID: clipID)
        }
        if transform != .identity { t = try t.settingTransform(clip: clipID, transform) }
        return t
    }

    /// 측정 전용(판정은 재료 확인뿐): 같은 클립을 (가) 기본 합성기·영상 층 하나, (나) 기본 합성기·겹친 두 층, (다) 실험 합성기 fullRectangle로 그려
    /// 밝기·색차 차이와 먼 쪽 가장자리를 적는다. 두 레인 타임라인에서 아래 판은 프레임 [0, 15)에만 있다 — 프레임 5는 겹침, 프레임 20은 겹치지 않음.
    /// 어느 쪽이 옳은 색인지 정하지 않는다. 한 층 기준과 여러 층 기준을 따로 남긴다.
    func testLayerCountColourAndInterpolationMeasurements() async throws {
        let sd = try await Self.colorPlate(640, 480, blue: 40, green: 40, red: 220)
        let hd = try await Self.patternMovie(1920, 1080), low = try await Self.patternMovie(480, 270)
        let backdrop = try await Self.colorPlate(1920, 1080, blue: 180, green: 180, red: 180, frames: 15)
        let cases: [(String, MediaAsset, ClipTransform)] = [
            ("untagged SD colour 640x480, fit 2.25x", sd, .identity),
            ("pattern 1920x1080, native 1x, offset", hd, ClipTransform(scale: 1, x: 100, y: 60)),
            ("pattern 480x270, upscaled 3x, offset", low, ClipTransform(scale: 0.75, x: 100, y: 60)),
            ("pattern 1920x1080, downscaled 0.5x, offset", hd, ClipTransform(scale: 0.5, x: 100, y: 60)),
        ]
        for (label, asset, transform) in cases {
            let size = asset.naturalSize
            let rect = Edge.expectedRect(width: Int(size.width), height: Int(size.height), scale: transform.scale, x: transform.x, y: transform.y)
            let x0 = Int(rect.minX.rounded()), y0 = Int(rect.minY.rounded()), x1 = Int(rect.maxX.rounded()), y1 = Int(rect.maxY.rounded())
            let cx = min(1900, max(20, (x0 + x1) / 2)), cy = min(1060, max(20, (y0 + y1) / 2))
            let onePlan = try await CompositionPlanner.plan(try Self.timeline(clip: asset, transform: transform, backdrop: nil, clipOnSecondLane: false), media: [asset.id: asset])
            let one5 = try await Self.frame(onePlan, .defaultCompositor, 5), one20 = try await Self.frame(onePlan, .defaultCompositor, 20)
            // 두 레인: 클립이 위에 보이는 레인 배치를 고른다(기본 합성기의 가운데 화소가 한 층 결과와 가깝다)
            var twoPlan: PlannedComposition?
            for second in [true, false] {
                let plan = try await CompositionPlanner.plan(try Self.timeline(clip: asset, transform: transform, backdrop: backdrop, clipOnSecondLane: second),
                                                             media: [asset.id: asset, backdrop.id: backdrop])
                let probe = try await Self.frame(plan, .defaultCompositor, 5)
                if abs(probe.luma(cx, cy) - one5.luma(cx, cy)) <= 24 { twoPlan = plan; break }
            }
            guard let twoPlan else { XCTFail("\(label): 재료 — 두 레인에서 클립이 위에 보이지 않는다"); continue }
            let layers5 = twoPlan.videoComposition.instructions.compactMap { $0 as? AVVideoCompositionInstruction }.map { "\($0.timeRange.start.seconds)s:\($0.layerInstructions.count)" }
            let two5 = try await Self.frame(twoPlan, .defaultCompositor, 5), two20 = try await Self.frame(twoPlan, .defaultCompositor, 20)
            let cOne5 = try await Self.frame(onePlan, .corrected, 5), cTwo5 = try await Self.frame(twoPlan, .corrected, 5), cTwo20 = try await Self.frame(twoPlan, .corrected, 20)
            func d(_ a: Planes, _ b: Planes) -> String { Self.diff(a, b, x0: x0, y0: y0, x1: x1, y1: y1).text }
            func centre(_ f: Planes) -> String { let c = f.chroma(cx, cy); return "[\(f.luma(cx, cy)), \(c.cb), \(c.cr)]" }
            print("GATE2 \(label) | rect x \(x0)..<\(x1) y \(y0)..<\(y1) | two-lane instructions (start:layers) \(layers5)")
            print("GATE2 \(label) | centre YCbCr: builtin 1-layer \(centre(one5)), builtin 2-layer \(centre(two5)), builtin 2-lane no-overlap(f20) \(centre(two20)) vs 1-layer(f20) \(centre(one20)), experimental 1-layer \(centre(cOne5)), experimental 2-layer \(centre(cTwo5))")
            print("GATE2 \(label) | builtin 2-layer overlap vs builtin 1-layer (frame 5): \(d(two5, one5))")
            print("GATE2 \(label) | builtin 2-lane timeline without overlap vs builtin 1-layer (frame 20): \(d(two20, one20))")
            print("GATE2 \(label) | experimental 1-layer vs builtin 1-layer (frame 5): \(d(cOne5, one5))")
            print("GATE2 \(label) | experimental 1-layer vs builtin 2-layer overlap (frame 5): \(d(cOne5, two5))")
            print("GATE2 \(label) | experimental 2-layer overlap vs builtin 2-layer overlap (frame 5): \(d(cTwo5, two5))")
            print("GATE2 \(label) | experimental 2-layer overlap vs experimental 1-layer (frame 5): \(d(cTwo5, cOne5))")
            print("GATE2 \(label) | experimental 2-lane without overlap vs builtin 1-layer (frame 20): \(d(cTwo20, one20))")
            if let folder = ProcessInfo.processInfo.environment["OTF_EDGE_PNG_DIR"] {
                // 같은 원본·같은 프레임(5)·같은 자리: 왼쪽부터 기본 1레인, 기본 2레인, 실험 합성기
                let name = label.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "_")
                let dir = URL(fileURLWithPath: folder, isDirectory: true)
                let w = x1 - x0, h = y1 - y0
                Self.saveSideBySide([one5, two5, cOne5], x: max(0, min(1920 - 600, x0 + w / 8)), y: max(0, min(1080 - 320, y0 + h / 4)), width: 600, height: 320,
                                    to: dir.appendingPathComponent("\(name)--detail--builtin1-builtin2-experimental.png"))
                Self.saveSideBySide([one5, two5, cOne5], x: max(0, min(1920, x1) - 300), y: max(0, min(1080, y1) - 220), width: 300, height: 220,
                                    to: dir.appendingPathComponent("\(name)--far-corner--builtin1-builtin2-experimental.png"))
            }
            print("GATE2 \(label) | far edges (frame 5): builtin 1-layer \(Self.farEdges(one5, x0: x0, y0: y0, x1: x1, y1: y1)) | builtin 2-layer \(Self.farEdges(two5, x0: x0, y0: y0, x1: x1, y1: y1)) | experimental 1-layer \(Self.farEdges(cOne5, x0: x0, y0: y0, x1: x1, y1: y1)) | experimental 2-layer \(Self.farEdges(cTwo5, x0: x0, y0: y0, x1: x1, y1: y1))")
        }
    }

    // MARK: 색차 충실도(SP-EXPORT-E4D-CHROMA-FIDELITY-43, 측정 전용)

    /// 낮은 주파수 색 무늬(소리 없음, 30 fps 30프레임, 정지 그림): 위 1/4은 8화소 색 바둑판(왼쪽 파랑·노랑, 오른쪽 빨강·초록),
    /// 다음 1/4은 32화소 색 띠, 아래 절반은 부드러운 색 기울기. 어두운 화소가 없다.
    static func softPatternMovie(_ width: Int, _ height: Int) async throws -> MediaAsset {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("soft-pattern-\(width)x\(height).mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            guard writer.canAdd(input) else { throw Failure("video input") }
            writer.add(input)
            guard writer.startWriting() else { throw Failure("writer start: \(String(describing: writer.error))") }
            writer.startSession(atSourceTime: .zero)
            let w = width, h = height
            let bars: [(Int, Int, Int)] = [(220, 60, 60), (60, 200, 60), (60, 60, 220), (220, 220, 60), (60, 200, 200), (200, 60, 200)]
            for n in 0..<30 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                var made: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let pb = made else { throw Failure("pixel buffer") }
                CVPixelBufferLockBaseAddress(pb, [])
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    let p = base.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
                    for y in 0..<h { for x in 0..<w {
                        var r = 40 + 180 * x / w, g = 40 + 180 * y / h, b = 220 - 160 * x / w
                        if y < h / 4 {
                            let odd = ((x / 8) + (y / 8)) % 2 == 0
                            if x < w / 2 { if odd { r = 60; g = 60; b = 220 } else { r = 220; g = 220; b = 60 } }
                            else if odd { r = 200; g = 60; b = 60 } else { r = 60; g = 200; b = 60 }
                        } else if y < h / 2 {
                            let c = bars[(x / 32) % bars.count]; r = c.0; g = c.1; b = c.2
                        }
                        let o = y * bpr + x * 4
                        p[o] = UInt8(b); p[o + 1] = UInt8(g); p[o + 2] = UInt8(r); p[o + 3] = 255
                    } }
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: 30)) else { throw Failure("video append") }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw Failure("writer finish: \(String(describing: writer.error))") }
        }
        return try await MediaProbe.inspect(url)
    }
    /// 원본 파일의 프레임 k(420v, 행 끝 채움 제외) — 합성 결과와 무관한 독립 기준
    static func sourcePlanes(_ asset: MediaAsset, frame k: Int) async throws -> Planes {
        let av = AVURLAsset(url: asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw Failure("source track") }
        let reader = try AVAssetReader(asset: av)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure("source reader start") }
        defer { reader.cancelReading() }
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard index == k, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { throw Failure("source planes") }
            let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let cw = (w / 2) * 2
            var y = [UInt8](repeating: 0, count: w * h), c = [UInt8](repeating: 0, count: w * (h / 2))
            y.withUnsafeMutableBytes { d in for row in 0..<h { memcpy(d.baseAddress! + row * w, yb + row * ybpr, w) } }
            c.withUnsafeMutableBytes { d in for row in 0..<(h / 2) { memcpy(d.baseAddress! + row * w, cb + row * cbpr, cw) } }
            return Planes(w: w, h: h, y: y, c: c)
        }
        throw Failure("source frame \(k) not produced")
    }
    struct BlockError { var n = 0, sumY = 0.0, sumC = 0.0, maxY = 0.0, maxC = 0.0, reason = ""
        var text: String { n == 0 ? "NOT COMPARABLE (\(reason.isEmpty ? "no block fits" : reason))" : String(format: "block means vs source: Y mean %.2f max %.1f, chroma mean %.2f max %.1f (%d blocks)", sumY / Double(n), maxY, sumC / Double(n), maxC, n) } }
    /// 평균 색이 보존되는가(기본 합성기와 무관한 기준): 원본의 16×16 블록(원본 색차 격자에 맞춘 것)마다 그 평균(Y, Cb, Cr)을,
    /// 그 블록이 변형으로 놓이는 출력 사각형의 평균과 견준다. 출력 사각형은 명시적 변환 x = x0 + sx·s, y = y0 + sy·s로 구한다.
    /// 출력 사각형이 정수 화소가 아니면 공정하게 견줄 수 없어 견주지 않는다(이유를 적는다). 출력 색차는 4:2:0 표본마다 사각형과 겹치는
    /// 넓이로 가중 평균한다 — 사각형이 홀수 행·열에서 시작해도 된다(첫 판은 짝수 정렬을 요구해 3배·y0 195에서 블록을 하나도 얻지 못했다).
    /// 값은 색 행렬 변환 없이 Y·Cb·Cr 그대로 견주므로, 601로 추정되는 SD 원본에서는 색 해석 차이가 섞인다(그 경우는 따로 적는다).
    static func blockMeanError(_ out: Planes, source: Planes, x0: Int, y0: Int, x1: Int, y1: Int, scale s: Double) -> BlockError {
        var e = BlockError()
        let size = 16, span = Double(size) * s
        guard span >= 4, abs(span - span.rounded()) < 0.001 else { e.reason = "a 16-pixel source block maps to \(span) output pixels at scale \(s)"; return e }
        let o = Int(span.rounded())
        var sy = size
        while sy + 2 * size <= source.h {
            var sx = size
            while sx + 2 * size <= source.w {
                defer { sx += size }
                let fx = Double(x0) + Double(sx) * s, fy = Double(y0) + Double(sy) * s
                guard abs(fx - fx.rounded()) < 0.001, abs(fy - fy.rounded()) < 0.001 else { e.reason = "block origin maps to a fractional output position"; continue }
                let ox = Int(fx.rounded()), oy = Int(fy.rounded())
                guard ox >= 0, oy >= 0, ox + o <= min(x1 - 1, out.w), oy + o <= min(y1 - 1, out.h) else { continue }   // 화면 밖과 사각형의 마지막 열·행은 뺀다
                // 원본 블록 평균(색차 표본은 블록 안에 온전히 든다: sx, sy, size 모두 짝수)
                var ys = 0, cbs = 0, crs = 0
                for y in sy..<(sy + size) { for x in sx..<(sx + size) { ys += source.luma(x, y) } }
                for y in stride(from: sy, to: sy + size, by: 2) { for x in stride(from: sx, to: sx + size, by: 2) { let c = source.chroma(x, y); cbs += c.cb; crs += c.cr } }
                let srcY = Double(ys) / Double(size * size), srcCb = Double(cbs) / Double(size * size / 4), srcCr = Double(crs) / Double(size * size / 4)
                // 출력 평균: 밝기는 사각형 그대로, 색차는 표본의 2×2 자리와 사각형이 겹치는 넓이로 가중
                var oys = 0
                for y in oy..<(oy + o) { for x in ox..<(ox + o) { oys += out.luma(x, y) } }
                var wsum = 0.0, ocb = 0.0, ocr = 0.0
                for cy in (oy / 2)...((oy + o - 1) / 2) { for cx in (ox / 2)...((ox + o - 1) / 2) {
                    let wx = Double(min(2 * cx + 2, ox + o) - max(2 * cx, ox)), wy = Double(min(2 * cy + 2, oy + o) - max(2 * cy, oy))
                    guard wx > 0, wy > 0 else { continue }
                    let c = out.chroma(2 * cx, 2 * cy), wgt = wx * wy
                    wsum += wgt; ocb += wgt * Double(c.cb); ocr += wgt * Double(c.cr)
                } }
                guard wsum > 0 else { continue }
                let dy = abs(Double(oys) / Double(o * o) - srcY), dc = max(abs(ocb / wsum - srcCb), abs(ocr / wsum - srcCr))
                e.n += 1; e.sumY += dy; e.sumC += dc; e.maxY = max(e.maxY, dy); e.maxC = max(e.maxC, dc)
            }
            sy += size
        }
        return e
    }

    /// 측정 전용: 높은 주파수 무늬·낮은 주파수 무늬·SD 색 판(그리고 OTF_EDGE_REAL_MEDIA가 가리키는 격리된 영상이 있으면 그것)을
    /// 제 크기·0.5배·3배로 놓고, 기본 합성기 한 레인(A)·두 레인(B)·실험 합성기 fullRectangle(C)을 서로, 그리고 원본의 블록 평균과 견준다.
    /// 어느 결과가 옳은지 정하지 않는다. 판정은 재료 확인뿐이다.
    func testChromaFidelityMeasurements() async throws {
        let hard = try await Self.patternMovie(1920, 1080), hardLow = try await Self.patternMovie(480, 270)
        let soft = try await Self.softPatternMovie(1920, 1080), softLow = try await Self.softPatternMovie(480, 270)
        let sd = try await Self.colorPlate(640, 480, blue: 40, green: 40, red: 220)
        let backdrop = try await Self.colorPlate(1920, 1080, blue: 180, green: 180, red: 180, frames: 15)
        let cases: [(String, MediaAsset, ClipTransform, Double?)] = [
            ("hard pattern 1080p native 1x", hard, ClipTransform(scale: 1, x: 100, y: 60), 1),
            ("hard pattern 1080p down 0.5x", hard, ClipTransform(scale: 0.5, x: 100, y: 60), 0.5),
            ("hard pattern 480x270 up 3x", hardLow, ClipTransform(scale: 0.75, x: 100, y: 60), 3),
            ("soft pattern 1080p native 1x", soft, ClipTransform(scale: 1, x: 100, y: 60), 1),
            ("soft pattern 1080p down 0.5x", soft, ClipTransform(scale: 0.5, x: 100, y: 60), 0.5),
            ("soft pattern 480x270 up 3x", softLow, ClipTransform(scale: 0.75, x: 100, y: 60), 3),
            ("untagged SD colour 640x480 2.25x", sd, .identity, nil),
        ]
        for (label, asset, transform, blockScale) in cases {
            let size = asset.displaySize
            let rect = Edge.expectedRect(width: Int(size.width), height: Int(size.height), scale: transform.scale, x: transform.x, y: transform.y)
            let x0 = Int(rect.minX.rounded()), y0 = Int(rect.minY.rounded()), x1 = Int(rect.maxX.rounded()), y1 = Int(rect.maxY.rounded())
            let cx = min(1900, max(20, (x0 + x1) / 2)), cy = min(1060, max(20, (y0 + y1) / 2))
            do {
                let onePlan = try await CompositionPlanner.plan(try Self.timeline(clip: asset, transform: transform, backdrop: nil, clipOnSecondLane: false), media: [asset.id: asset])
                let a = try await Self.frame(onePlan, .defaultCompositor, 5), c = try await Self.frame(onePlan, .corrected, 5)
                var b: Planes?
                for second in [true, false] {
                    let plan = try await CompositionPlanner.plan(try Self.timeline(clip: asset, transform: transform, backdrop: backdrop, clipOnSecondLane: second),
                                                                 media: [asset.id: asset, backdrop.id: backdrop])
                    let probe = try await Self.frame(plan, .defaultCompositor, 5)
                    if abs(probe.luma(cx, cy) - a.luma(cx, cy)) <= 24 { b = probe; break }
                }
                func d(_ p: Planes, _ q: Planes) -> String { Self.diff(p, q, x0: x0, y0: y0, x1: x1, y1: y1).text }
                print("CHROMA \(label) | rect x \(x0)..<\(x1) y \(y0)..<\(y1) | C vs A: \(d(c, a))")
                if let b { print("CHROMA \(label) | C vs B: \(d(c, b))"); print("CHROMA \(label) | B vs A: \(d(b, a))") } else { print("CHROMA \(label) | B not available (clip not visible on top in a two-lane plan)") }
                if let s = blockScale {
                    let source = try await Self.sourcePlanes(asset, frame: 5)
                    print("CHROMA \(label) | A \(Self.blockMeanError(a, source: source, x0: x0, y0: y0, x1: x1, y1: y1, scale: s).text)")
                    if let b { print("CHROMA \(label) | B \(Self.blockMeanError(b, source: source, x0: x0, y0: y0, x1: x1, y1: y1, scale: s).text)") }
                    print("CHROMA \(label) | C \(Self.blockMeanError(c, source: source, x0: x0, y0: y0, x1: x1, y1: y1, scale: s).text)")
                }
                if let folder = ProcessInfo.processInfo.environment["OTF_EDGE_PNG_DIR"] {
                    let name = "chroma--" + label.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "_")
                    Self.saveSideBySide(b.map { [a, $0, c] } ?? [a, c], x: max(0, min(1920 - 600, x0 + (x1 - x0) / 8)), y: max(0, min(1080 - 320, y0 + (y1 - y0) / 16)), width: 600, height: 320,
                                        to: URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("\(name)--A-B-C.png"))
                }
            } catch { XCTFail("\(label): \(error)") }
        }
    }

    // MARK: 실제 영상 충실도(SP-EXPORT-E4D-REAL-MEDIA-FIDELITY-44, 측정 전용)

    static func copyPlanes(_ pb: CVPixelBuffer) throws -> Planes {
        guard CVPixelBufferGetPixelFormatType(pb) == SubtitleExporter.pixelFormat else { throw Failure("pixel format") }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { throw Failure("planes") }
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1), cw = (w / 2) * 2
        var y = [UInt8](repeating: 0, count: w * h), c = [UInt8](repeating: 0, count: w * (h / 2))
        y.withUnsafeMutableBytes { d in for row in 0..<h { memcpy(d.baseAddress! + row * w, yb + row * ybpr, w) } }
        c.withUnsafeMutableBytes { d in for row in 0..<(h / 2) { memcpy(d.baseAddress! + row * w, cb + row * cbpr, cw) } }
        return Planes(w: w, h: h, y: y, c: c)
    }
    /// 타임라인 프레임 k 하나를 읽는다(리더의 읽는 구간을 그 프레임에서 시작하게 해 앞부분을 디코딩하지 않는다). 받은 표본의 시각도 돌려준다.
    static func frameAt(_ plan: PlannedComposition, _ renderer: Renderer, _ k: Int) async throws -> (planes: Planes, pts: CMTime) {
        let reader = try AVAssetReader(asset: plan.composition)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat]
        settings[AVVideoColorPropertiesKey] = SubtitleExporter.color709
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await plan.composition.loadTracks(withMediaType: .video), videoSettings: settings)
        output.videoComposition = try videoComposition(plan, renderer)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(k), timescale: 30), duration: CMTime(value: 4, timescale: 30))
        guard reader.startReading() else { throw Failure("reader start (\(renderer.rawValue)) at frame \(k): \(String(describing: reader.error))") }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard Int((pts.seconds * 30).rounded()) == k, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            return (try copyPlanes(pb), pts)
        }
        throw Failure("frame \(k) not produced (\(renderer.rawValue)): \(String(describing: reader.error))")
    }
    /// 타임라인 프레임 k에 보이는 원본 프레임: 표시 시각이 (트랙 시작 + k/30 s) 이하인 마지막 원본 표본. 합성과 무관하게 원본에서 직접 읽는다.
    static func sourcePlanes(_ asset: MediaAsset, timelineFrame k: Int) async throws -> (planes: Planes, pts: CMTime, trackStart: CMTime) {
        let av = AVURLAsset(url: asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw Failure("source track") }
        let range = try await track.load(.timeRange)
        let wanted = range.start + CMTime(value: CMTimeValue(k), timescale: 30)
        let reader = try AVAssetReader(asset: av)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat])
        reader.add(output)
        let from = CMTimeMaximum(range.start, wanted - CMTime(value: 1, timescale: 1))
        reader.timeRange = CMTimeRange(start: from, duration: CMTime(value: 2, timescale: 1))
        guard reader.startReading() else { throw reader.error ?? Failure("source reader start") }
        defer { reader.cancelReading() }
        var best: (Planes, CMTime)?
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if CMTimeCompare(pts, wanted + CMTime(value: 1, timescale: 600)) > 0 { break }
            if let pb = CMSampleBufferGetImageBuffer(sample) { best = (try copyPlanes(pb), pts) }
        }
        guard let best else { throw Failure("source frame for timeline frame \(k) not produced") }
        return (best.0, best.1, range.start)
    }
    /// 선명도 대용 값: 사각형 안(화면 안, 가장자리 2화소 제외)의 평균 밝기 기울기와 평균 색차 기울기(가로·세로 이웃 차이)
    static func gradientEnergy(_ f: Planes, x0: Int, y0: Int, x1: Int, y1: Int) -> String {
        var gy = 0, gc = 0, n = 0
        for y in max(2, y0 + 2)..<max(2, min(f.h - 2, y1 - 2)) { for x in max(2, x0 + 2)..<max(2, min(f.w - 2, x1 - 2)) {
            gy += abs(f.luma(x + 1, y) - f.luma(x, y)) + abs(f.luma(x, y + 1) - f.luma(x, y))
            if x % 2 == 0 && y % 2 == 0 {
                let c = f.chroma(x, y), cr = f.chroma(x + 2, y), cd = f.chroma(x, y + 2)
                gc += abs(cr.cb - c.cb) + abs(cr.cr - c.cr) + abs(cd.cb - c.cb) + abs(cd.cr - c.cr)
            }
            n += 1
        } }
        return n == 0 ? "no pixels" : String(format: "luma gradient %.3f, chroma gradient %.3f", Double(gy) / Double(n), Double(gc) / Double(max(1, n / 4)))
    }
    static func rgb(_ f: Planes, _ x: Int, _ y: Int) -> String {
        let c = f.chroma(x, y)
        let yy = (Double(f.luma(x, y)) - 16) * 255 / 219, cb = (Double(c.cb) - 128) * 255 / 224, cr = (Double(c.cr) - 128) * 255 / 224
        func q(_ v: Double) -> Int { Int(max(0, min(255, v.rounded()))) }
        return "(\(q(yy + 1.5748 * cr)),\(q(yy - 0.1873 * cb - 0.4681 * cr)),\(q(yy + 1.8556 * cb)))"
    }

    /// 측정 전용(OTF_EDGE_REAL_MEDIA가 가리키는 격리된 실제 영상이 있을 때만): 같은 영상·같은 타임라인 프레임을
    /// 기본 합성기 한 레인(A)·두 레인(B)·실험 합성기 fullRectangle(C)로 그려 서로, 그리고 원본의 블록 평균과 견준다.
    /// 제 크기(위치만 옮김)와 0.5배. 원본이 1920×1080이면 확대 경우는 없다(지원하지 않는 해상도를 만들지 않는다).
    /// 어느 결과가 옳은지 정하지 않는다. 판정은 재료와 읽기의 성공뿐이다.
    func testRealMediaFidelityMeasurements() async throws {
        guard let path = ProcessInfo.processInfo.environment["OTF_EDGE_REAL_MEDIA"] else { throw XCTSkip("OTF_EDGE_REAL_MEDIA가 없으면 실행하지 않는다") }
        let asset = try await MediaProbe.inspect(URL(fileURLWithPath: path))
        let backdrop = try await Self.colorPlate(1920, 1080, blue: 180, green: 180, red: 180, frames: 15)
        let fit = min(1920 / asset.displaySize.width, 1080 / asset.displaySize.height)
        print("REAL source: \(Int(asset.naturalSize.width))x\(Int(asset.naturalSize.height)) codec \(asset.codec) timeline frames \(asset.frameCount) has audio \(asset.hasAudio) fit scale \(fit)")
        XCTAssertGreaterThan(asset.frameCount, 300, "실제 영상의 길이")
        let times = [5, 600, 2400, 4500, 7200].filter { $0 < asset.frameCount - 10 }
        let pngDir = ProcessInfo.processInfo.environment["OTF_EDGE_PNG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for (label, transform) in [("native size, offset", ClipTransform(scale: 1, x: 100, y: 60)), ("half size", ClipTransform(scale: 0.5, x: 100, y: 60))] {
            let size = asset.displaySize
            let rect = Edge.expectedRect(width: Int(size.width), height: Int(size.height), scale: transform.scale, x: transform.x, y: transform.y)
            let x0 = Int(rect.minX.rounded()), y0 = Int(rect.minY.rounded()), x1 = Int(rect.maxX.rounded()), y1 = Int(rect.maxY.rounded())
            let cx = min(1900, max(20, (x0 + x1) / 2)), cy = min(1060, max(20, (y0 + y1) / 2))
            let s = fit * transform.scale
            do {
                let onePlan = try await CompositionPlanner.plan(try Self.timeline(clip: asset, transform: transform, backdrop: nil, clipOnSecondLane: false), media: [asset.id: asset])
                var twoPlan: PlannedComposition?
                let probeA = try await Self.frameAt(onePlan, .defaultCompositor, 5).planes
                for second in [true, false] {
                    let plan = try await CompositionPlanner.plan(try Self.timeline(clip: asset, transform: transform, backdrop: backdrop, clipOnSecondLane: second),
                                                                 media: [asset.id: asset, backdrop.id: backdrop])
                    let probe = try await Self.frameAt(plan, .defaultCompositor, 5).planes
                    if abs(probe.luma(cx, cy) - probeA.luma(cx, cy)) <= 24 && abs(probe.luma(x0 + 40, y0 + 40) - probeA.luma(x0 + 40, y0 + 40)) <= 24 { twoPlan = plan; break }
                }
                print("REAL \(label) | rect x \(x0)..<\(x1) y \(y0)..<\(y1) effective scale \(s) | two-lane plan \(twoPlan == nil ? "NOT AVAILABLE" : "ok, video tracks \(twoPlan!.composition.tracks(withMediaType: .video).count)")")
                for k in times {
                    let a = try await Self.frameAt(onePlan, .defaultCompositor, k), c = try await Self.frameAt(onePlan, .corrected, k)
                    var b: (planes: Planes, pts: CMTime)?
                    if let twoPlan { b = try await Self.frameAt(twoPlan, .defaultCompositor, k) }
                    let source = try await Self.sourcePlanes(asset, timelineFrame: k)
                    func d(_ p: Planes, _ q: Planes) -> String { Self.diff(p, q, x0: x0, y0: y0, x1: x1, y1: y1).text }
                    let tag = "REAL \(label) frame \(k)"
                    print("\(tag) | composed pts A \(a.pts.value)/\(a.pts.timescale) C \(c.pts.value)/\(c.pts.timescale)\(b.map { " B \($0.pts.value)/\($0.pts.timescale)" } ?? "") | source sample pts \(source.pts.value)/\(source.pts.timescale) (track start \(source.trackStart.seconds))")
                    print("\(tag) | C vs A: \(d(c.planes, a.planes))")
                    if let b { print("\(tag) | C vs B: \(d(c.planes, b.planes))"); print("\(tag) | B vs A: \(d(b.planes, a.planes))") }
                    print("\(tag) | A \(Self.blockMeanError(a.planes, source: source.planes, x0: x0, y0: y0, x1: x1, y1: y1, scale: s).text)")
                    if let b { print("\(tag) | B \(Self.blockMeanError(b.planes, source: source.planes, x0: x0, y0: y0, x1: x1, y1: y1, scale: s).text)") }
                    print("\(tag) | C \(Self.blockMeanError(c.planes, source: source.planes, x0: x0, y0: y0, x1: x1, y1: y1, scale: s).text)")
                    print("\(tag) | sharpness A \(Self.gradientEnergy(a.planes, x0: x0, y0: y0, x1: x1, y1: y1))\(b.map { " | B \(Self.gradientEnergy($0.planes, x0: x0, y0: y0, x1: x1, y1: y1))" } ?? "") | C \(Self.gradientEnergy(c.planes, x0: x0, y0: y0, x1: x1, y1: y1))")
                    let points = [(cx, cy), (x0 + (x1 - x0) / 4, y0 + (y1 - y0) / 4), (min(1900, x0 + 3 * (x1 - x0) / 4), min(1060, y0 + 3 * (y1 - y0) / 4))]
                    print("\(tag) | RGB at \(points.map { "(\($0.0),\($0.1))" }): A \(points.map { Self.rgb(a.planes, $0.0, $0.1) })\(b.map { p in " B \(points.map { Self.rgb(p.planes, $0.0, $0.1) })" } ?? "") C \(points.map { Self.rgb(c.planes, $0.0, $0.1) })")
                    // 먼 쪽 가장자리(사각형이 화면 안에 있을 때): 안쪽 이웃은 밝은데 끝 줄만 검정에 가까운 화소 수, 그리고 사각형 밖에 그린 화소
                    if x1 <= 1920, y1 <= 1080 {
                        func uncovered(_ f: Planes) -> String {
                            let right = (y0..<y1).filter { f.luma(x1 - 1, $0) <= Edge.black && f.luma(x1 - 3, $0) > Edge.black + 8 }.count
                            let bottom = (x0..<x1).filter { f.luma($0, y1 - 1) <= Edge.black && f.luma($0, y1 - 3) > Edge.black + 8 }.count
                            var outside = 0
                            for py in 0..<f.h { for px in 0..<f.w where (px < x0 || px >= x1 || py < y0 || py >= y1) && f.luma(px, py) > Edge.black { outside += 1 } }
                            return "right \(right)/\(y1 - y0) bottom \(bottom)/\(x1 - x0) outside \(outside)"
                        }
                        print("\(tag) | far edges uncovered: A \(uncovered(a.planes)) | C \(uncovered(c.planes))")
                    } else {
                        print("\(tag) | far edges off canvas (not measured)")
                    }
                    if let pngDir {
                        let name = "real--" + label.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ",", with: "") + "--frame\(k)"
                        let parts = b.map { [a.planes, $0.planes, c.planes] } ?? [a.planes, c.planes]
                        Self.saveSideBySide(parts, x: max(0, min(1920 - 600, cx - 300)), y: max(0, min(1080 - 320, cy - 160)), width: 600, height: 320,
                                            to: pngDir.appendingPathComponent("\(name)--centre--\(b == nil ? "A-C" : "A-B-C").png"))
                        Self.saveSideBySide(parts, x: max(0, min(1920, x1) - 300), y: max(0, min(1080, y1) - 220), width: 300, height: 220,
                                            to: pngDir.appendingPathComponent("\(name)--far-corner--\(b == nil ? "A-C" : "A-B-C").png"))
                    }
                }
            } catch { XCTFail("\(label): \(error)") }
        }
    }

    // MARK: GATE 1 — 첫 재생 프레임

    /// 선택 실행 진단(OTF_EDGE_FIRST_FRAME=default|historical|corrected, 새 프로세스마다 한 번): 준비 → 500 ms → 0으로 정확 탐색 → 바로 재생.
    /// OTF_EDGE_FIRST_FRAME_SOURCE가 있으면 그 영상 파일(예: 4K 생성 fixture, 읽기만)을 제 크기 한 층으로 놓고, 없으면 1920×1080 생성 판을 계획으로 놓는다.
    /// 실험 합성기 방식에서는 프레임마다 가른다: 표시를 관찰함 / 그렸으나 표시를 관찰하지 못함 / 요청은 왔으나 취소됨 / 요청이 오지 않음.
    /// 표시 관찰은 3 ms 간격 폴링이라 "관찰하지 못함"은 표시되지 않았다는 증거가 아니다(그렇게 적는다). 기본 합성기에는 요청 기록이 없어 관찰만 적는다.
    /// 창(AVPlayerLayer)이 없는 조건이며 앱의 프리뷰 표시를 증명하지 않는다. 요청이 오지 않았거나 취소된 프레임은 실패로 본다.
    @MainActor func testFirstSeekThenFirstPlaybackRequestClassification() async throws {
        let environment = ProcessInfo.processInfo.environment
        let mode = environment["OTF_EDGE_FIRST_FRAME"] ?? ""
        try XCTSkipUnless(["default", "historical", "corrected"].contains(mode), "진단 실행은 OTF_EDGE_FIRST_FRAME=default|historical|corrected일 때만")
        var keep: [Any] = []
        let composition: AVAsset, base: AVVideoComposition, frames: Int, what: String
        if let folder = environment["OTF_EDGE_FIRST_FRAME_E2"] {
            // S1b 재검토(§16.4)의 구성을 실험 패키지 없이 다시 만든다: E2 편집 순서(EditTimeline.e2Experiment — A[30,+90) C[20,+90) B[0,+60) B[150,+60), 300프레임),
            // 4K 재정렬 원본 세 개, 클립 소리 트랙과 음악 트랙(원본 2 s부터 9 s를 타임라인 1 s에), 렌더 3840×2160, 한 층·변형 없음. 원본은 읽기만 한다.
            let base0 = URL(fileURLWithPath: folder, isDirectory: true)
            func source(_ name: String) -> AVURLAsset { let a = AVURLAsset(url: base0.appendingPathComponent(name)); keep.append(a); return a }
            let a = source("src-A-3840x2160-30p-v2.mp4"), b = source("src-B-3840x2160-30p-v2.mp4"), c = source("src-C-3840x2160-30p-v2.mp4"), music = source("M-music.wav")
            let comp = AVMutableComposition()
            guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let mt = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return XCTFail("composition tracks") }
            func time(_ f: Int) -> CMTime { CMTime(value: CMTimeValue(f), timescale: 30) }
            var at = 0
            for (asset, sourceIn, length) in [(a, 30, 90), (c, 20, 90), (b, 0, 60), (b, 150, 60)] {
                guard let v = try await asset.loadTracks(withMediaType: .video).first else { return XCTFail("E2 fixture without video") }
                let range = CMTimeRange(start: time(sourceIn), duration: time(length))
                try vt.insertTimeRange(range, of: v, at: time(at))
                if let sound = try await asset.loadTracks(withMediaType: .audio).first { try ct.insertTimeRange(range, of: sound, at: time(at)) }
                at += length
            }
            mt.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 1000, timescale: 1000)))
            if let m = try await music.loadTracks(withMediaType: .audio).first {
                try mt.insertTimeRange(CMTimeRange(start: CMTime(value: 2000, timescale: 1000), duration: CMTime(value: 9000, timescale: 1000)), of: m, at: CMTime(value: 1000, timescale: 1000))
            }
            let frozen = comp.copy() as! AVComposition
            guard let track = frozen.track(withTrackID: vt.trackID) else { return XCTFail("frozen track") }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(.identity, at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: time(at))
            instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            instruction.layerInstructions = [layer]
            let vc = AVMutableVideoComposition()
            vc.renderSize = CGSize(width: 3840, height: 2160); vc.frameDuration = CMTime(value: 1, timescale: 30); vc.instructions = [instruction]
            composition = frozen; base = vc.copy() as! AVVideoComposition; frames = at
            what = "E2 edit order A,C,B,B (300 frames), 4K reordered sources, clip audio + music, audio tracks \(frozen.tracks(withMediaType: .audio).count)"
        } else if let path = environment["OTF_EDGE_FIRST_FRAME_SOURCE"] {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path)); keep.append(asset)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { return XCTFail("no video track in \(path)") }
            let (natural, range) = try await video.load(.naturalSize, .timeRange)
            let duration = CMTimeMinimum(range.duration, CMTime(value: 4, timescale: 1))
            let comp = AVMutableComposition()
            guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return XCTFail("composition track") }
            try vt.insertTimeRange(CMTimeRange(start: range.start, duration: duration), of: video, at: .zero)
            if let audio = try await asset.loadTracks(withMediaType: .audio).first, let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? at.insertTimeRange(CMTimeRange(start: range.start, duration: duration), of: audio, at: .zero)
            }
            let frozen = comp.copy() as! AVComposition
            guard let track = frozen.track(withTrackID: vt.trackID) else { return XCTFail("frozen track") }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(.identity, at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            instruction.layerInstructions = [layer]
            let vc = AVMutableVideoComposition()
            vc.renderSize = natural; vc.frameDuration = CMTime(value: 1, timescale: 30); vc.instructions = [instruction]
            composition = frozen; base = vc.copy() as! AVVideoComposition; frames = Int((duration.seconds * 30).rounded())
            what = "\((path as NSString).lastPathComponent) \(Int(natural.width))x\(Int(natural.height)), direct single layer"
        } else {
            let asset = try await Edge.plate(1920, 1080)
            let plan = try await CompositionPlanner.plan(try Timeline().registering(asset).inserting(media: asset.id), media: [asset.id: asset])
            keep.append(plan)
            composition = plan.composition; base = plan.videoComposition; frames = plan.durationFrames; what = "generated 1920x1080 plate through CompositionPlanner"
        }
        let log = ExperimentalCompositorLog()
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = mode == "default" ? base
            : try ExperimentalComposition.videoComposition(from: base, options: mode == "corrected" ? .init(edgeCoverage: .fullRectangle) : .init(), diagnostics: log)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        let deadline = Date().addingTimeInterval(15)
        while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        let readyTime = item.currentTime()
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        func frameNumber(_ t: CMTime) -> Int { Int((t.seconds * 30).rounded()) }
        let beforePlay = log.receivedTimes.map(frameNumber)
        let playAt = CACurrentMediaTime()
        player.play()
        var observed: [(frame: Int, ms: Double)] = []
        let stop = Date().addingTimeInterval(min(Double(frames) / 30, 3) + 1.0)
        while Date() < stop {
            let t = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: t) {
                var display = CMTime.invalid
                if output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &display) != nil, display.isNumeric {
                    observed.append((frameNumber(display), (CACurrentMediaTime() - playAt) * 1000))
                }
            }
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        player.pause(); player.replaceCurrentItem(with: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        let seen = Set(observed.map(\.frame))
        let last = min(frames, 30) - 1   // 판정 범위: 프레임 1…last−1(프레임 0은 탐색이 그리고, 끝은 끝에 닿는 동작이 섞인다)
        let firstObserved = observed.prefix(12).map { "\($0.frame)@\(String(format: "%.0f", $0.ms))ms" }
        var summary = "FIRST-FRAME (\(mode)) \(what) | ready item time \(readyTime.value)/\(readyTime.timescale) | first observed frames after play \(firstObserved) | frames 1..<\(last) not observed by polling \((1..<last).filter { !seen.contains($0) })"
        if mode != "default" {
            let received = log.receivedTimes.map(frameNumber), outcomes = log.requestOutcomes
            let entries = log.snapshot.entries
            let t0 = entries.first?.received ?? playAt
            let timing = entries.prefix(8).map { String(format: "t%d recv %.0f ms render %.1f ms", frameNumber($0.time), ($0.received - t0) * 1000, ($0.rendered - $0.received) * 1000) }
            var neverRequested: [Int] = [], cancelled: [Int] = [], producedUnobserved: [Int] = [], presented: [Int] = []
            for k in 1..<last {
                let finished = outcomes.contains { frameNumber($0.time) == k && $0.outcome == .finished }
                let wasCancelled = outcomes.contains { frameNumber($0.time) == k && $0.outcome == .cancelled }
                if seen.contains(k) { presented.append(k) }
                else if finished { producedUnobserved.append(k) }
                else if wasCancelled { cancelled.append(k) }
                else if !received.contains(k) { neverRequested.append(k) }
                else { producedUnobserved.append(k) }
            }
            summary += " | requests before play \(beforePlay) | request order (first 14) \(received.prefix(14)) | first requests \(timing) | observed presented \(presented.count) | NEVER REQUESTED \(neverRequested) | REQUESTED BUT CANCELLED \(cancelled) | produced (or pending) but not observed \(producedUnobserved) | outcomes finished \(outcomes.filter { $0.outcome == .finished }.count) cancelled \(outcomes.filter { $0.outcome == .cancelled }.count) failed \(outcomes.filter { $0.outcome == .failed }.count)"
            print(summary)
            XCTAssertEqual(neverRequested, [], "재생 시작 뒤 요청되지 않은 프레임")
            XCTAssertEqual(cancelled, [], "재생 시작 뒤 요청됐으나 취소된 프레임")
            XCTAssertEqual(outcomes.filter { $0.outcome == .failed }.count, 0, "실패로 끝난 요청")
        } else {
            print(summary)
        }
        withExtendedLifetime(keep) {}
    }
}
