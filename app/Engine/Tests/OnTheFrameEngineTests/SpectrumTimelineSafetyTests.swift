import AVFoundation
import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E2: 그릴 수 없는 상태의 거부(D-S3·D-S8), 원본 보호, 취소·정리, 한도, 여러 발자국의 합성 차례.
final class SpectrumTimelineSafetyTests: SpectrumTimelineTestCase {
    func rejection(_ t: Timeline, _ assets: [MediaAsset], limits: SpectrumTimelineExportLimits = SpectrumTimelineFixture.limits) -> SpectrumTimelineExportError? {
        do { _ = try SpectrumTimelineFrames(timeline: t, assets: assets, limits: limits); return nil }
        catch { return error as? SpectrumTimelineExportError }
    }
    // I. 소스를 고르지 않음
    func testUnsetSourceIsRejected() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 30, sourceKey: nil)
        guard case .blocked(let blockers)? = rejection(t, [m]) else { return XCTFail("거부해야 한다") }
        XCTAssertEqual(blockers.map(\.reason), [.unsetSource]); XCTAssertEqual(blockers, t.spectrumExportBlockers())
    }
    // I. 고른 소스가 타임라인에서 없어짐
    func testMissingSourceIsRejected() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 30, sourceKey: sc.key).lifting(clip: sc.clip)
        guard case .blocked(let blockers)? = rejection(t, [m]) else { return XCTFail("거부해야 한다") }
        XCTAssertEqual(blockers.map(\.reason), [.missingSource])
    }
    // J. 같은 계보의 조각이 같은 시각에 겹침(D-S8). 동시에 보이는 스펙트럼 둘과는 다른 경우다.
    func testOverlappingLineageIsRejected() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let (l, r) = (UUID(), UUID()), a2 = UUID()
        var t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 120, sourceKey: sc.key).splitting(clip: sc.clip, atFrame: 60, newIDs: (l, r))
        XCTAssertNil(rejection(t, [m]), "나누기만으로는 막지 않는다")
        t = try t.addingLane(.audio, name: "A2", id: a2).relocating(clip: r, toStart: 30, lane: a2)
        guard case .blocked(let blockers)? = rejection(t, [m]) else { return XCTFail("거부해야 한다") }
        guard case .overlappingSource(let overlaps) = try XCTUnwrap(blockers.first).reason else { return XCTFail("\(blockers)") }
        XCTAssertEqual(overlaps.map(\.range), [30..<60])
    }
    // I. 소스 원본이 넘겨받은 목록에 없음 / 파일이 바뀜
    func testUnavailableOrChangedOriginalIsRejected() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 30, sourceKey: sc.key)
        XCTAssertEqual(rejection(t, []), .sourceUnavailable(spectrum: t.spectra[0].id))
        let p = try provider(t, [m])
        _ = try await p.layers(5)
        try Fx.writeWAV(m.url, seconds: 1, channels: 2, Fx.tone(880))   // 같은 경로의 다른 파일
        do { _ = try await p.layers(6); XCTFail("바뀐 원본을 읽으면 안 된다") }
        catch { XCTAssertEqual(error as? SpectrumTimelineExportError, .sourceChanged) }
        XCTAssertThrowsError(try p.validateSources())
        XCTAssertEqual(rejection(t, [m]), .sourceChanged)
    }
    // 한도: 잘못된 시간 값, 소리 상한
    func testLimitsAreValidatedAndEnforced() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 30, sourceKey: sc.key)
        XCTAssertEqual(rejection(t, [m], limits: SpectrumTimelineExportLimits(stepTimeout: 30, jobTimeout: .infinity)), .invalidLimits)
        XCTAssertEqual(rejection(t, [m], limits: SpectrumTimelineExportLimits(stepTimeout: 0, jobTimeout: 10)), .invalidLimits)
        var tiny = Fx.limits; tiny.pcmBudgetBytes = 1_024
        let p = try provider(t, [m], limits: tiny)
        do { _ = try await p.layers(5); XCTFail("상한을 넘겨야 한다") }
        catch { guard case .pcmBudgetExceeded? = error as? SpectrumTimelineExportError else { return XCTFail("\(error)") } }
        let held = await p.retained()
        XCTAssertEqual(held.pcmBytes, 0, "상한을 넘으면 디코딩하지 않는다")
        do { _ = try await provider(t, [m]).layers(t.durationFrames); XCTFail("범위 밖 프레임") }
        catch { XCTAssertEqual(error as? SpectrumTimelineExportError, .frameOutOfRange(t.durationFrames)) }
    }
    // 들고 있는 소리는 지금 프레임이 읽는 덩어리뿐이다(8 s 덩어리 경계를 넘어도 쌓이지 않는다)
    func testDecodedAudioStaysBounded() async throws {
        let m = try await media("long.wav", seconds: 20, Fx.tone(440))
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 600, sourceKey: sc.key)
        let p = try provider(t, [m])
        let chunkBytes = 8 * 48_000 * 2 * MemoryLayout<Float>.stride
        for k in [10, 239, 240, 241, 480, 599] {
            _ = try await p.layers(k)
            let held = await p.retained()
            XCTAssertLessThanOrEqual(held.pcmBytes, 2 * chunkBytes, "frame \(k)")
            XCTAssertEqual(held.openSources, 1)
        }
    }
    // K. 취소와 정리
    func testCancellationAndCloseReleaseResources() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 60, sourceKey: sc.key)
        let p = try provider(t, [m])
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }   // 취소된 뒤에 요청한다(차례를 정해 둠)
            do { _ = try await p.layers(5); return false } catch { return error is CancellationError }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled, "취소한 작업은 프레임을 내지 않는다")
        _ = try await p.layers(6)   // 취소 뒤에도 다음 요청은 정상
        await p.close()
        let held = await p.retained()
        XCTAssertEqual(held.pcmBytes, 0); XCTAssertEqual(held.openSources, 0)
        do { _ = try await p.layers(7); XCTFail("닫은 뒤에는 거부") }
        catch { XCTAssertEqual(error as? SpectrumTimelineExportError, .closed) }
        await p.close()   // 여러 번 닫아도 된다
    }
    // L. 쓰기 펌프와의 계약: 공급기는 ExportFrameOverlay이고, 발자국은 그림이 있는 층마다 하나, 같은 차례
    func testOverlayContract() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 60, sourceKey: sc.key)
            .addingSpectrum(lane: sc.high, at: 0, length: 60, sourceKey: sc.key, style: analog())
        let p = try provider(t, [m])
        let overlay: any ExportFrameOverlay = p
        XCTAssertEqual(overlay.stepTimeout, 30); XCTAssertEqual(overlay.jobTimeout, 600)
        let layers = try await p.layers(30), footprints = try await overlay.prepareFootprints(30)
        XCTAssertEqual(footprints.count, layers.filter { $0.rendered != nil }.count)
        XCTAssertTrue(footprints.allSatisfy { $0.visible(30) && !$0.visible(31) }, "발자국은 그 프레임 것")
    }
    // C. 합성 차례: 뒤에 합성한 발자국이 위에 온다(불투명한 두 색이 겹친 화소)
    func testLaterFootprintIsCompositedOnTop() throws {
        func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) throws -> SpectrumRenderedFrame {
            var px = [UInt8](repeating: 0, count: 16 * 16 * 4)
            for i in 0..<(16 * 16) { px[i * 4] = b; px[i * 4 + 1] = g; px[i * 4 + 2] = r; px[i * 4 + 3] = 255 }
            let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let provider = CGDataProvider(data: Data(px) as CFData),
                  let image = CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw SpectrumTimelineFixture.Failure("image") }
            return SpectrumRenderedFrame(image: image, drawRect: CGRect(x: 64, y: 64, width: 16, height: 16), canvasWidth: 1920, canvasHeight: 1080)
        }
        func luma(_ order: [SpectrumRenderedFrame]) throws -> UInt8 {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0..<1080 { memset(y + row * bpr, 16, 1920) }
            for r in order { SpectrumTimelineFrames.footprint(r, lane: UUID(), frame: 0).composite(buffer) }
            return y[72 * bpr + 72]
        }
        let white = try solid(255, 255, 255), black = try solid(0, 0, 0)
        XCTAssertGreaterThan(try luma([black, white]), 200, "흰색이 위")
        XCTAssertLessThan(try luma([white, black]), 40, "검정이 위")
    }
}
