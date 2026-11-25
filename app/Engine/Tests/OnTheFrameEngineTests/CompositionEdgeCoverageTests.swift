import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E4D-EDGE-FIX-PROOF-31: 계획한 composition(CompositionPlanner.plan)을 내보내기와 같은 리더 출력으로 읽었을 때,
/// 영상 층이 덮어야 하는 사각형의 네 변이 모두 원본 화소로 채워지는가. 인코딩 전의 합성 결과를 본다(MP4를 만들지 않는다).
/// 기대 사각형은 이 시험이 따로 계산한다(맞춤: 비율 유지·가운데, 클립 변형: 화면 가운데 기준 크기 뒤 위치).
/// 의도한 여백(레터박스)은 빈 곳이 맞다 — 사각형 밖은 검정이어야 하고, 사각형 안은 끝 행·열까지 원본 값이어야 한다.
/// 2026-11-24 조사(SP-EXPORT-E4D-SCALE-MATRIX-30): 배율이 2배를 넘는 층에서 마지막 열·행이 빈 것이 관찰됐다.
/// 이 시험은 그 동작을 제품 경로에서 확인하려는 것이며, 실행하기 전에는 통과·실패를 주장하지 않는다.
final class CompositionEdgeCoverageTests: XCTestCase {
    /// OTF_EDGE_COVERAGE_DIR이 있으면 그 폴더에 재료를 쓰고 지우지 않는다(감독 실행). 없으면 임시 폴더에 쓰고 지운다.
    static let keptDir = ProcessInfo.processInfo.environment["OTF_EDGE_COVERAGE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let dir = keptDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("otf-edge-\(UUID().uuidString)", isDirectory: true)
    override class func tearDown() { if keptDir == nil { try? FileManager.default.removeItem(at: dir) } }

    struct Failure: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }
    static let render = CGSize(width: 1920, height: 1080)
    /// 원본 값과의 허용 차(8비트 밝기). 합성만 하고 인코딩하지 않으므로 좁게 잡는다.
    static let tolerance = 4
    /// 영상 범위 검정(16)으로 보는 상한
    static let black = 24

    /// 생성 재료: 단색 무채색 H.264 영상(소리 없음), 30 fps 30프레임. 모든 바이트가 64인 BGRA 프레임.
    static func plate(_ width: Int, _ height: Int) async throws -> MediaAsset {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("plate-\(width)x\(height).mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            guard writer.canAdd(input) else { throw Failure("video input") }
            writer.add(input)
            guard writer.startWriting() else { throw Failure("writer start: \(String(describing: writer.error))") }
            writer.startSession(atSourceTime: .zero)
            for f in 0..<30 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                var made: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let pb = made else { throw Failure("pixel buffer") }
                CVPixelBufferLockBaseAddress(pb, [])
                memset(CVPixelBufferGetBaseAddress(pb), 64, CVPixelBufferGetDataSize(pb))
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30)) else { throw Failure("video append") }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw Failure("writer finish: \(String(describing: writer.error))") }
        }
        return try await MediaProbe.inspect(url)
    }

    /// 이 시험이 따로 계산한 기대 사각형(출력 좌표, 위 왼쪽 원점): 비율을 유지해 가운데에 맞춘 뒤, 화면 가운데 기준으로 크기를 바꾸고 옮긴다.
    static func expectedRect(width: Int, height: Int, scale: Double, x: Double, y: Double) -> CGRect {
        let fit = min(render.width / CGFloat(width), render.height / CGFloat(height))
        let w = CGFloat(width) * fit * CGFloat(scale), h = CGFloat(height) * fit * CGFloat(scale)
        return CGRect(x: render.width / 2 + CGFloat(x) - w / 2, y: render.height / 2 + CGFloat(y) - h / 2, width: w, height: h)
    }

    struct Luma { let w: Int, h: Int, y: [UInt8]
        func at(_ x: Int, _ yy: Int) -> Int { Int(y[yy * w + x]) } }

    /// 계획한 composition의 프레임 k를 내보내기와 같은 리더 설정(420v, 709 색 속성, 계획의 videoComposition)으로 읽는다.
    static func composed(_ plan: PlannedComposition, frame k: Int) async throws -> Luma {
        let reader = try AVAssetReader(asset: plan.composition)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat]
        settings[AVVideoColorPropertiesKey] = SubtitleExporter.color709
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await plan.composition.loadTracks(withMediaType: .video), videoSettings: settings)
        output.videoComposition = plan.videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure("reader start") }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            guard Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 30).rounded()) == k, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard CVPixelBufferGetPixelFormatType(pb) == SubtitleExporter.pixelFormat else { throw Failure("pixel format") }
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { throw Failure("luma plane") }
            var y = [UInt8](repeating: 0, count: w * h)
            y.withUnsafeMutableBytes { d in for row in 0..<h { memcpy(d.baseAddress! + row * w, base + row * bpr, w) } }   // 행 끝 채움 제외
            return Luma(w: w, h: h, y: y)
        }
        throw Failure("frame \(k) not produced")
    }
    /// 원본 파일의 프레임 k의 밝기(가운데 화소) — 합성 결과와 무관한 독립 기준
    static func sourceLuma(_ asset: MediaAsset, frame k: Int) async throws -> Int {
        let av = AVURLAsset(url: asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw Failure("source track") }
        let reader = try AVAssetReader(asset: av)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: SubtitleExporter.pixelFormat])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure("source reader start") }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            guard Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 30).rounded()) == k, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { throw Failure("source luma plane") }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            return Int(base.assumingMemoryBound(to: UInt8.self)[(h / 2) * bpr + w / 2])
        }
        throw Failure("source frame \(k) not produced")
    }

    /// 한 구성: 재료 하나를 첫 영상 레인에 놓고(필요하면 클립 변형), 계획을 읽어 기대 사각형의 네 변과 그 바깥을 본다.
    func check(_ width: Int, _ height: Int, scale: Double = 1, x: Double = 0, y: Double = 0, file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = try await Self.plate(width, height)
        let clip = UUID()
        var timeline = try Timeline().registering(asset).inserting(media: asset.id, clipID: clip)
        let transform = ClipTransform(scale: scale, x: x, y: y)
        if transform != .identity { timeline = try timeline.settingTransform(clip: clip, transform) }
        let rect = Self.expectedRect(width: width, height: height, scale: scale, x: x, y: y)
        let x0 = Int(rect.minX.rounded()), y0 = Int(rect.minY.rounded()), x1 = Int(rect.maxX.rounded()), y1 = Int(rect.maxY.rounded())
        let label = "\(width)x\(height) scale \(scale) offset (\(x), \(y)) → x \(x0)..<\(x1) y \(y0)..<\(y1)"
        // 기대 사각형은 정수 화소에 놓이고 화면 안에 있어야 한다(잘린 원본 끝은 이 시험의 대상이 아니다)
        XCTAssertEqual(rect, rect.integral, "\(label): 정수 화소 사각형", file: file, line: line)
        XCTAssertTrue(x0 >= 0 && y0 >= 0 && x1 <= 1920 && y1 <= 1080 && x1 - x0 >= 16 && y1 - y0 >= 16, "\(label): 화면 안", file: file, line: line)
        // 계획이 쓰는 사각형이 이 시험의 계산과 같다(같지 않으면 아래 화소 판정은 의미가 없다)
        let planned = CompositionPlanner.displayRect(asset, transform, render: Self.render)
        XCTAssertEqual(planned.minX, rect.minX, accuracy: 0.001, "\(label): 계획의 사각형", file: file, line: line)
        XCTAssertEqual(planned.minY, rect.minY, accuracy: 0.001, "\(label): 계획의 사각형", file: file, line: line)
        XCTAssertEqual(planned.width, rect.width, accuracy: 0.001, "\(label): 계획의 사각형", file: file, line: line)
        XCTAssertEqual(planned.height, rect.height, accuracy: 0.001, "\(label): 계획의 사각형", file: file, line: line)

        let plan = try await CompositionPlanner.plan(timeline, media: [asset.id: asset])
        let frame = try await Self.composed(plan, frame: 5), source = try await Self.sourceLuma(asset, frame: 5)
        XCTAssertEqual(frame.w, 1920, file: file, line: line); XCTAssertEqual(frame.h, 1080, file: file, line: line)
        guard frame.w == 1920, frame.h == 1080 else { return }
        XCTAssertGreaterThan(source, Self.black + 2 * Self.tolerance, "\(label): 원본은 검정과 구별된다", file: file, line: line)
        func covered(_ px: Int, _ py: Int) -> Bool { abs(frame.at(px, py) - source) <= Self.tolerance }
        // 안쪽 전체(네 변 포함)가 원본 값인가 — 변마다 따로 센다
        let left = (y0..<y1).filter { !covered(x0, $0) }.count, right = (y0..<y1).filter { !covered(x1 - 1, $0) }.count
        let top = (x0..<x1).filter { !covered($0, y0) }.count, bottom = (x0..<x1).filter { !covered($0, y1 - 1) }.count
        XCTAssertEqual(left, 0, "\(label): 왼쪽 끝 열 x=\(x0)에서 원본 값이 아닌 화소(전체 \(y1 - y0))", file: file, line: line)
        XCTAssertEqual(right, 0, "\(label): 오른쪽 끝 열 x=\(x1 - 1)에서 원본 값이 아닌 화소(전체 \(y1 - y0))", file: file, line: line)
        XCTAssertEqual(top, 0, "\(label): 위 끝 행 y=\(y0)에서 원본 값이 아닌 화소(전체 \(x1 - x0))", file: file, line: line)
        XCTAssertEqual(bottom, 0, "\(label): 아래 끝 행 y=\(y1 - 1)에서 원본 값이 아닌 화소(전체 \(x1 - x0))", file: file, line: line)
        var inside = 0
        for py in y0..<y1 { for px in x0..<x1 where !covered(px, py) { inside += 1 } }
        XCTAssertEqual(inside, 0, "\(label): 기대 사각형 안에서 원본 값이 아닌 화소(네 변 포함)", file: file, line: line)
        // 바깥(의도한 여백)은 검정이다 — 사각형 밖으로 칠하지 않았다
        var outside = 0
        for py in 0..<1080 { for px in 0..<1920 where (px < x0 || px >= x1 || py < y0 || py >= y1) && frame.at(px, py) > Self.black { outside += 1 } }
        XCTAssertEqual(outside, 0, "\(label): 기대 사각형 밖에서 검정이 아닌 화소", file: file, line: line)
    }

    // 320×180 → 1920×1080(6배, 화면 전체)
    func testSmallSourceScaledToFullFrameCoversEveryEdge() async throws { try await check(320, 180) }
    // 1920×1080 그대로(1배)
    func testNativeSizeSourceCoversEveryEdge() async throws { try await check(1920, 1080) }
    // 1280×720 → 1920×1080(1.5배)
    func testModeratelyScaledSourceCoversEveryEdge() async throws { try await check(1280, 720) }
    // 640×480 → 1440×1080(2.25배), 좌우 240 px는 의도한 여백
    func testLetterboxedSourceCoversItsRectangleAndLeavesTheBarsBlack() async throws { try await check(640, 480) }
    // 320×180을 맞춘 뒤 절반 크기(실효 3배)로 줄여 오른쪽 100·아래 50 px로 옮긴 층: 네 변이 모두 화면 안쪽에 있다
    func testTranslatedScaledLayerCoversEveryEdge() async throws { try await check(320, 180, scale: 0.5, x: 100, y: 50) }
}
