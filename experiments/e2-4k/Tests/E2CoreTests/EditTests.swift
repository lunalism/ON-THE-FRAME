import CoreMedia
import E1Core
import E2Core
import E2Expect
import XCTest

final class EditTests: XCTestCase {
    func testExperimentEditsMatchIndependentSegments() throws {
        let t = try EditTimeline.e2Experiment()
        XCTAssertEqual(t.segments.count, Expect2.segments.count)
        for (s, e) in zip(t.segments, Expect2.segments) {
            XCTAssertEqual(s.start, e.start); XCTAssertEqual(s.start + s.length, e.end)
            XCTAssertEqual(s.source, e.source); XCTAssertEqual(s.sourceIn, e.sourceIn)
        }
        for (n, src, f) in Expect2.boundaryFrames {
            let g = t.sourceFrame(at: n)
            XCTAssertEqual(g?.source, src, "frame \(n)"); XCTAssertEqual(g?.frame, f, "frame \(n)")
        }
        XCTAssertEqual(t.durationFrames, 300)
        XCTAssertEqual(t.lastValidFrame, Expect2.lastValidFrame)
        XCTAssertNil(t.sourceFrame(at: 300))
    }

    func testInvalidEditsRejected() throws {
        var t = try EditTimeline.e2Experiment()
        XCTAssertThrowsError(try t.trim(0, sourceIn: 200, length: 100))     // A는 240프레임
        XCTAssertThrowsError(try t.trim(0, sourceIn: 0, length: 0))
        XCTAssertThrowsError(try t.split(atTimelineFrame: 90, names: ("x", "y")))  // 컷 위치
        XCTAssertThrowsError(try t.split(atTimelineFrame: 300, names: ("x", "y")))
        XCTAssertThrowsError(try t.move(from: 7, to: 0))
        XCTAssertEqual(t.durationFrames, 300)   // 거부된 편집은 상태를 바꾸지 않는다
    }

    func testSplitThenMoveKeepsSourceMapping() throws {
        var t = EditTimeline(sourceLengths: ["A": 100, "B": 50])
        try t.append(source: "A", name: "A"); try t.append(source: "B", name: "B")
        try t.split(atTimelineFrame: 40, names: ("A.1", "A.2"))
        try t.move(from: 2, to: 0)   // B, A.1, A.2
        XCTAssertEqual(t.sourceFrame(at: 0)?.source, "B")
        XCTAssertEqual(t.sourceFrame(at: 50)?.frame, 0)    // A.1 시작
        XCTAssertEqual(t.sourceFrame(at: 90)?.frame, 40)   // A.2 시작
        XCTAssertEqual(t.lastValidFrame, 149)
    }

    func testEmptyTimelineHasNoLastValidFrame() {
        XCTAssertNil(EditTimeline(sourceLengths: ["A": 10]).lastValidFrame)
    }

    func testMusicPlacementMapping() {
        let m = MusicPlacement.e2
        XCTAssertNil(m.sourceTime(frame: 29))                                   // 0.967 s: 배치 전
        XCTAssertEqual(m.sourceTime(frame: 30), CMTime(value: 2, timescale: 1))  // 1.0 s → 원본 2.0 s
        XCTAssertEqual(m.sourceTime(frame: 299), CMTime(value: 299, timescale: 30) + CMTime(value: 1, timescale: 1))
        XCTAssertNil(m.sourceTime(frame: 300))
    }
}
