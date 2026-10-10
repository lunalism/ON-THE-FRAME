import CoreMedia
import E1Core
import XCTest

final class TimelineTests: XCTestCase {
    let src = SourceRef(id: "x", path: "/nonexistent")

    func testHalfOpenMapping() {
        let p = ClipPlacement(source: src, sourceIn: CMTime(value: 5, timescale: 1), duration: CMTime(value: 8, timescale: 1),
                              timelineStart: CMTime(value: 2, timescale: 1))
        XCTAssertNil(p.sourceTime(atTimeline: CMTime(value: 59, timescale: 30)))           // 1.9667 s
        XCTAssertEqual(p.sourceTime(atTimeline: CMTime(value: 60, timescale: 30)), CMTime(value: 5, timescale: 1))
        XCTAssertEqual(p.sourceTime(atTimeline: CMTime(value: 299, timescale: 30)), CMTime(value: 389, timescale: 30))
        XCTAssertNil(p.sourceTime(atTimeline: CMTime(value: 10, timescale: 1)))             // 끝은 제외
    }
}

final class SpectrumKernelTests: XCTestCase {
    /// 밴드 중앙 근처 사인(진폭 0.25)은 기대 밴드가 최대이고 값이 20·log10(0.25) dB에 대응해야 한다.
    func testSineAmplitudeAndBand() {
        let k = SpectrumKernel()
        for (hz, band) in [(135.0, 6), (600.0, 14), (2700.0, 22), (4700.0, 25)] {
            let x = (0..<4096).map { Float(0.25 * sin(2 * Double.pi * hz * Double($0) / 48_000)) }
            var out = [Float](repeating: 0, count: 32)
            x.withUnsafeBufferPointer { xp in out.withUnsafeMutableBufferPointer { k.process(xp.baseAddress!, into: $0.baseAddress!) } }
            XCTAssertEqual(out.indices.max { out[$0] < out[$1] }, band, "\(hz) Hz")
            let expected = Float((20 * log10(0.25) + 80) / 80)   // 0.8495
            XCTAssertEqual(out[band], expected, accuracy: 0.02, "\(hz) Hz")
        }
    }

    func testSilenceIsZero() {
        let k = SpectrumKernel()
        let x = [Float](repeating: 0, count: 4096)
        var out = [Float](repeating: 1, count: 32)
        x.withUnsafeBufferPointer { xp in out.withUnsafeMutableBufferPointer { k.process(xp.baseAddress!, into: $0.baseAddress!) } }
        XCTAssertEqual(out, [Float](repeating: 0, count: 32))
    }

    func testCacheIndexUsesRationalTime() {
        let cache = SpectrumCache(sourceID: "x", params: SpectrumParams(), values: [Float](repeating: 0, count: 32 * 2401))
        XCTAssertEqual(cache.hopIndex(atSourceTime: CMTime(value: 1, timescale: 30)), 4)
        XCTAssertEqual(cache.hopIndex(atSourceTime: CMTime(value: 20, timescale: 1)), 2400)
        XCTAssertNil(cache.hopIndex(atSourceTime: CMTime(value: 601, timescale: 30)))
    }
}

final class OutputGuardTests: XCTestCase {
    func testRejectsExistingAndSourceAndPromotesExclusively() throws {
        // 데이터 볼륨의 실험 산출물 디렉터리 안에서만 작업한다
        let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = pkg.appendingPathComponent("artifacts/unit-tests/e1-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.wav"); try Data("s".utf8).write(to: src)
        let existing = dir.appendingPathComponent("exists.mp4"); try Data("e".utf8).write(to: existing)
        XCTAssertThrowsError(try OutputGuard.preflight(destination: src, sources: [src]))
        XCTAssertThrowsError(try OutputGuard.preflight(destination: existing, sources: [src]))
        let dest = dir.appendingPathComponent("new.mp4")
        XCTAssertNoThrow(try OutputGuard.preflight(destination: dest, sources: [src]))
        let tmp = try OutputGuard.makeTempDir(for: dest)
        let f = tmp.url.appendingPathComponent("o.mp4"); try Data("t".utf8).write(to: f)
        XCTAssertThrowsError(try OutputGuard.promote(f, to: existing))            // 덮어쓰지 않음
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "e")
        XCTAssertNoThrow(try OutputGuard.promote(f, to: dest))
        XCTAssertTrue(OutputGuard.cleanup(tmp))
        XCTAssertTrue(OutputGuard.leftovers(in: dir).isEmpty)
    }
}

final class CompositorTimeTests: XCTestCase {
    func testFrameIndexRoundsAndFlagsExactness() {
        XCTAssertTrue(E1Compositor.frameIndex(CMTime(value: 60, timescale: 30)) == (60, true))
        XCTAssertTrue(E1Compositor.frameIndex(CMTime(value: 4000, timescale: 600)) == (200, true))      // 600 시간축
        XCTAssertTrue(E1Compositor.frameIndex(CMTime(value: 300, timescale: 30)) == (300, true))        // 끝 시각 t = 10 s
        let r = E1Compositor.frameIndex(CMTime(value: 100_001, timescale: 48_000))                       // 2.0833 s
        XCTAssertEqual(r.0, 63); XCTAssertFalse(r.1)
    }
}

final class EndFrameTests: XCTestCase {
    let fd = CMTime(value: 1, timescale: 30)

    func testLastValidFrameFromGrid() {
        XCTAssertEqual(FrameGrid.lastValidFrame(duration: CMTime(value: 10, timescale: 1), frameDuration: fd), 299)
        XCTAssertEqual(FrameGrid.lastValidFrame(duration: CMTime(value: 1, timescale: 30), frameDuration: fd), 0)
        XCTAssertEqual(FrameGrid.lastValidFrame(duration: CMTime(value: 1, timescale: 1000), frameDuration: fd), 0)     // 1 ms: 프레임 0만
        XCTAssertEqual(FrameGrid.lastValidFrame(duration: CMTime(value: 601, timescale: 60), frameDuration: fd), 300)   // 10.0167 s: 300 시작 < 끝
        XCTAssertEqual(FrameGrid.lastValidFrame(duration: CMTime(value: 6000, timescale: 600), frameDuration: fd), 299) // 다른 시간축
        XCTAssertNil(FrameGrid.lastValidFrame(duration: .zero, frameDuration: fd))
        XCTAssertNil(FrameGrid.lastValidFrame(duration: CMTime(value: -1, timescale: 30), frameDuration: fd))
        XCTAssertNil(FrameGrid.lastValidFrame(duration: .invalid, frameDuration: fd))
    }

    func testContentFrameHoldsLastValid() {
        XCTAssertEqual(E1Compositor.contentFrame(0, lastValid: 299), 0)
        XCTAssertEqual(E1Compositor.contentFrame(299, lastValid: 299), 299)
        XCTAssertEqual(E1Compositor.contentFrame(300, lastValid: 299), 299)
        XCTAssertEqual(E1Compositor.contentFrame(-1, lastValid: 299), 0)
    }

    func testEmptyTimelineRejected() async {
        let ref = SourceRef(id: "x", path: "/nonexistent")
        let clip = ClipPlacement(source: ref, sourceIn: .zero, duration: .zero, timelineStart: .zero)
        let state = TimelineState(selected: clip, unrelated: nil, duration: .zero)
        do {
            _ = try await CompositionBuilder.build(state, renderer: nil, log: nil, videoCarrier: nil)
            XCTFail("empty timeline must be rejected")
        } catch {
            XCTAssertTrue("\(error)".contains("empty timeline"), "\(error)")
        }
    }
}
