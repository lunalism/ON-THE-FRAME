import CoreMedia
import OnTheFrameEngine
import XCTest

/// 타임라인 편집 규칙과 실행 취소 기록(M1 모델)
final class TimelineTests: XCTestCase {
    let ma = UUID(), mb = UUID()
    var base: Timeline { Timeline(mediaFrames: [ma: 100, mb: 60]) }

    func twoClips() throws -> Timeline { try base.inserting(media: ma).inserting(media: mb) }

    func testInsertAndLookup() throws {
        let t = try twoClips()
        XCTAssertEqual(t.durationFrames, 160)
        XCTAssertEqual(t.starts, [0, 100])
        XCTAssertEqual(t.lastValidFrame, 159)
        XCTAssertEqual(t.source(atFrame: 99)?.frame, 99)
        XCTAssertEqual(t.source(atFrame: 100)?.mediaID, mb)
        XCTAssertNil(t.source(atFrame: 160))
        XCTAssertThrowsError(try base.inserting(media: UUID())) { XCTAssertEqual($0 as? EditError, .unknownMedia) }
    }

    func testSplitOnlyInsideClip() throws {
        let t = try twoClips(), id = t.clips[0].id
        for at in [0, 100, 160, -1] {
            XCTAssertThrowsError(try t.splitting(clip: id, atFrame: at)) { XCTAssertEqual($0 as? EditError, .splitAtBoundary) }
        }
        let s = try t.splitting(clip: id, atFrame: 1)
        XCTAssertEqual(s.clips.map(\.length), [1, 99, 60])
        XCTAssertEqual(s.clips[1].sourceIn, 1)
        XCTAssertEqual(s.durationFrames, t.durationFrames)
        let s2 = try t.splitting(clip: id, atFrame: 99)
        XCTAssertEqual(s2.clips.map(\.length), [99, 1, 60])
        // 나눈 뒤에도 모든 타임라인 프레임의 원본이 그대로
        for n in 0..<t.durationFrames { XCTAssertEqual(s.source(atFrame: n)?.frame, t.source(atFrame: n)?.frame) }
    }

    func testTrimClampsToSourceAndOneFrame() throws {
        let t = try twoClips(), id = t.clips[0].id
        XCTAssertEqual(try t.trimmingStart(clip: id, by: 500).clips[0].length, 1)       // 최소 1프레임
        XCTAssertEqual(try t.trimmingStart(clip: id, by: -10).clips[0].sourceIn, 0)     // 원본 앞을 넘지 않음
        XCTAssertEqual(try t.trimmingEnd(clip: id, by: 10).clips[0].length, 100)        // 원본 끝을 넘지 않음
        XCTAssertEqual(try t.trimmingEnd(clip: id, by: -500).clips[0].length, 1)
        let r = try t.trimmingStart(clip: id, by: 30)
        XCTAssertEqual(r.clips[0].sourceIn, 30); XCTAssertEqual(r.clips[0].length, 70)
        XCTAssertEqual(r.starts, [0, 70])                                                // 리플
        let back = try r.trimmingStart(clip: id, by: -10)
        XCTAssertEqual(back.clips[0].sourceIn, 20)
        XCTAssertThrowsError(try t.trimming(clip: id, sourceIn: 0, length: 0)) { XCTAssertEqual($0 as? EditError, .tooShort) }
        XCTAssertThrowsError(try t.trimming(clip: id, sourceIn: 50, length: 51)) { XCTAssertEqual($0 as? EditError, .outOfSource) }
        XCTAssertThrowsError(try t.trimming(clip: id, sourceIn: -1, length: 5)) { XCTAssertEqual($0 as? EditError, .outOfSource) }
    }

    func testMoveByInsertionAndRippleDelete() throws {
        let t = try base.inserting(media: ma).inserting(media: mb).inserting(media: ma)
        let ids = t.clips.map(\.id)
        XCTAssertEqual(try t.moving(clip: ids[0], toIndex: 3).clips.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(try t.moving(clip: ids[2], toIndex: 0).clips.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(try t.moving(clip: ids[1], toIndex: 1).clips.map(\.id), ids)      // 제자리
        XCTAssertEqual(try t.moving(clip: ids[1], toIndex: 2).clips.map(\.id), ids)
        XCTAssertThrowsError(try t.moving(clip: ids[0], toIndex: 4))
        let d = try t.rippleDeleting(clip: ids[1])
        XCTAssertEqual(d.starts, [0, 100]); XCTAssertEqual(d.durationFrames, 200)
    }

    func testHistoryUndoRedoAndGestures() throws {
        var h = EditHistory(base)
        let t1 = try h.timeline.inserting(media: ma)
        h.apply(t1, focus: t1.clips[0].id)
        let id = t1.clips[0].id
        let t2 = try t1.splitting(clip: id, atFrame: 40)
        h.apply(t2, focus: t2.clips[1].id)
        XCTAssertEqual(h.undoDepth, 2)
        // 드래그: 여러 번 갱신해도 완료하면 한 단계
        h.beginGesture()
        for d in 1...10 { h.updateGesture(try t2.trimmingEnd(clip: t2.clips[1].id, by: -d), focus: t2.clips[1].id) }
        XCTAssertFalse(h.canUndo)                         // 드래그 중에는 실행 취소 불가
        h.commitGesture()
        XCTAssertEqual(h.undoDepth, 3)
        XCTAssertEqual(h.timeline.durationFrames, 90)
        // 취소한 드래그는 원래 상태, 기록 없음
        let before = h.timeline
        h.beginGesture(); h.updateGesture(try before.lifting(clip: before.clips[0].id), focus: nil); h.cancelGesture()
        XCTAssertEqual(h.timeline, before); XCTAssertEqual(h.undoDepth, 3)
        // 아무 변화 없는 드래그도 기록 없음
        h.beginGesture(); h.updateGesture(before, focus: nil); h.commitGesture()
        XCTAssertEqual(h.undoDepth, 3)
        XCTAssertEqual(h.undo(), t2.clips[1].id)
        XCTAssertEqual(h.timeline, t2)
        h.undo(); XCTAssertEqual(h.timeline, t1)
        h.redo(); XCTAssertEqual(h.timeline, t2)
        // 새 편집은 다시 실행 기록을 지운다
        h.apply(try t2.lifting(clip: t2.clips[0].id), focus: nil)
        XCTAssertFalse(h.canRedo)
        while h.canUndo { h.undo() }
        XCTAssertEqual(h.timeline, base)
    }

    // MARK: 빈틈과 일반·리플 삭제(D-020)

    /// A(100) B(60) A(100) — 시작 0, 100, 160, 길이 260
    func threeClips() throws -> Timeline { try base.inserting(media: ma).inserting(media: mb).inserting(media: ma) }

    func testEmptyProjectHasZeroDuration() {
        XCTAssertEqual(base.durationFrames, 0); XCTAssertTrue(base.gaps.isEmpty); XCTAssertNil(base.lastValidFrame)
    }

    func testLiftMiddleFirstLastAndOnlyKeepPositionsAndDuration() throws {
        let t = try threeClips(), ids = t.clips.map(\.id)
        XCTAssertEqual(t.starts, [0, 100, 160]); XCTAssertEqual(t.durationFrames, 260)
        let mid = try t.lifting(clip: ids[1])
        XCTAssertEqual(mid.clips.map(\.id), [ids[0], ids[2]]); XCTAssertEqual(mid.starts, [0, 160])
        XCTAssertEqual(mid.durationFrames, 260); XCTAssertEqual(mid.gaps, [100..<160]); XCTAssertTrue(mid.isValid)
        XCTAssertNil(mid.source(atFrame: 130)); XCTAssertEqual(mid.source(atFrame: 160)?.frame, 0)
        let first = try t.lifting(clip: ids[0])
        XCTAssertEqual(first.starts, [100, 160]); XCTAssertEqual(first.durationFrames, 260); XCTAssertEqual(first.gaps, [0..<100])
        let last = try t.lifting(clip: ids[2])
        XCTAssertEqual(last.starts, [0, 100]); XCTAssertEqual(last.durationFrames, 260); XCTAssertEqual(last.gaps, [160..<260])
        XCTAssertEqual(last.lastValidFrame, 259)                         // 끝 프레임은 빈틈(검정 유지)
        let only = try base.inserting(media: ma)
        let onlyLifted = try only.lifting(clip: only.clips[0].id)
        XCTAssertTrue(onlyLifted.isEmpty); XCTAssertEqual(onlyLifted.durationFrames, 100); XCTAssertEqual(onlyLifted.gaps, [0..<100])
        // 원본 구간·클립 id는 그대로
        XCTAssertEqual(mid.clips[1], t.clips[2])
    }

    func testRippleDeleteShiftsLaterAndShortens() throws {
        let t = try threeClips(), ids = t.clips.map(\.id)
        let r = try t.rippleDeleting(clip: ids[1])
        XCTAssertEqual(r.starts, [0, 100]); XCTAssertEqual(r.durationFrames, 200); XCTAssertTrue(r.gaps.isEmpty)
        XCTAssertEqual(r.clips[1].sourceIn, t.clips[2].sourceIn); XCTAssertEqual(r.clips[1].id, ids[2])
        // 빈틈이 있을 때: 앞쪽 빈틈은 그대로, 뒤 클립과 그 사이 빈틈은 함께 당겨진다
        let g = try t.lifting(clip: ids[0])                              // 빈틈 [0,100), B@100, A@160
        let rg = try g.rippleDeleting(clip: ids[1])
        XCTAssertEqual(rg.starts, [100]); XCTAssertEqual(rg.durationFrames, 200); XCTAssertEqual(rg.gaps, [0..<100])
        // 마지막·유일한 클립 리플 삭제: 길이가 그만큼 줄어든다
        let only = try base.inserting(media: mb)
        XCTAssertEqual(try only.rippleDeleting(clip: only.clips[0].id).durationFrames, 0)
        let trailing = try t.lifting(clip: ids[1]).rippleDeleting(clip: ids[2])   // A@0, 빈틈 [100,160)
        XCTAssertEqual(trailing.durationFrames, 160); XCTAssertEqual(trailing.gaps, [100..<160])
    }

    func testUndoRedoRestoresExactGapsInOneStep() throws {
        let t = try threeClips()
        var h = EditHistory(t)
        let lifted = try t.lifting(clip: t.clips[1].id)
        h.apply(lifted, focus: nil)
        let rippled = try lifted.rippleDeleting(clip: lifted.clips[0].id)  // 빈틈 [0,60), A@60
        h.apply(rippled, focus: nil)
        XCTAssertEqual(h.undoDepth, 2)
        h.undo(); XCTAssertEqual(h.timeline, lifted); XCTAssertEqual(h.timeline.gaps, [100..<160])
        h.undo(); XCTAssertEqual(h.timeline, t); XCTAssertEqual(h.timeline.durationFrames, 260)
        h.redo(); XCTAssertEqual(h.timeline.starts, lifted.starts); XCTAssertEqual(h.timeline.durationFrames, 260)
        h.redo(); XCTAssertEqual(h.timeline, rippled); XCTAssertEqual(rippled.gaps, [0..<60]); XCTAssertEqual(rippled.durationFrames, 160)
    }

    func testOperationsAdjacentToGaps() throws {
        let t = try threeClips(), ids = t.clips.map(\.id)
        let g = try t.lifting(clip: ids[1])                              // A@0(100), 빈틈 [100,160), A@160(100)
        // 자르기: 빈틈·빈틈 가장자리·클립 경계에서는 거부, 클립 안에서만
        XCTAssertThrowsError(try g.splitting(clip: ids[0], atFrame: 130)) { XCTAssertEqual($0 as? EditError, .splitAtBoundary) }
        XCTAssertThrowsError(try g.splitting(clip: ids[0], atFrame: 100)) { XCTAssertEqual($0 as? EditError, .splitAtBoundary) }
        XCTAssertThrowsError(try g.splitting(clip: ids[2], atFrame: 160)) { XCTAssertEqual($0 as? EditError, .splitAtBoundary) }
        XCTAssertNil(g.clipIndex(atFrame: 130))
        let sp = try g.splitting(clip: ids[2], atFrame: 161)
        XCTAssertEqual(sp.starts, [0, 160, 161]); XCTAssertEqual(sp.gaps, [100..<160]); XCTAssertEqual(sp.durationFrames, 260)
        // 삽입: 빈틈 뒤 클립의 시작에 끼우면 빈틈은 그 앞에 남고 뒤가 밀린다. 끝에 추가하면 끝 빈틈 뒤에 붙는다.
        let ins = try g.inserting(media: mb, at: 1)
        XCTAssertEqual(ins.starts, [0, 160, 220]); XCTAssertEqual(ins.gaps, [100..<160]); XCTAssertEqual(ins.durationFrames, 320)
        let tail = try t.lifting(clip: ids[2])                           // 끝 빈틈 [160,260)
        let app = try tail.inserting(media: mb)
        XCTAssertEqual(app.starts, [0, 100, 260]); XCTAssertEqual(app.gaps, [160..<260]); XCTAssertEqual(app.durationFrames, 320)
        // 트림(리플): 빈틈 앞 클립 끝을 줄이면 빈틈은 유지되고 뒤 클립이 당겨진다
        let tr = try g.trimmingEnd(clip: ids[0], by: -30)
        XCTAssertEqual(tr.starts, [0, 130]); XCTAssertEqual(tr.gaps, [70..<130]); XCTAssertEqual(tr.durationFrames, 230)
        let ts = try g.trimmingStart(clip: ids[2], by: 10)               // 시작 위치 고정, 원본 앞을 자름
        XCTAssertEqual(ts.starts, [0, 160]); XCTAssertEqual(ts.clips[1].sourceIn, 10); XCTAssertEqual(ts.durationFrames, 250)
        // 이동: 원래 구간을 닫고(리플) 대상 지점에 끼운다. 다른 빈틈은 유지. 제자리 이동은 그대로.
        let mv = try g.moving(clip: ids[2], toIndex: 0)                  // A'@0, A@100, 빈틈 [200,260)
        XCTAssertEqual(mv.clips.map(\.id), [ids[2], ids[0]]); XCTAssertEqual(mv.starts, [0, 100]); XCTAssertEqual(mv.gaps, [200..<260])
        XCTAssertEqual(mv.durationFrames, 260)
        XCTAssertEqual(try g.moving(clip: ids[0], toIndex: 1), g)
        // 모든 결과는 겹침 없음·원본 범위 안
        for x in [g, sp, ins, app, tr, ts, mv] { XCTAssertTrue(x.isValid) }
    }

    func testRenderSettingsFrameMath() {
        let s = RenderSettings.m1
        XCTAssertEqual(s.frame(containing: CMTime(value: 1001, timescale: 30000)), 1)
        XCTAssertEqual(s.frame(containing: CMTime(value: 999, timescale: 30000)), 0)
        XCTAssertEqual(s.nearestFrame(CMTime(value: 999, timescale: 30000)), 1)
        XCTAssertEqual(s.timecode(30 * 3661 + 7), "01:01:01:07")
    }

    func testFitTransformRotationAndLetterbox() {
        let render = CGSize(width: 1920, height: 1080)
        // 90도 회전한 640×360 → 표시 360×640, 높이에 맞춰 가운데
        let t = CompositionPlanner.fitTransform(natural: CGSize(width: 640, height: 360),
                                                preferred: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0), render: render)
        let r = CGRect(x: 0, y: 0, width: 640, height: 360).applying(t)
        XCTAssertEqual(r.height, 1080, accuracy: 0.01); XCTAssertEqual(r.width, 607.5, accuracy: 0.01)
        XCTAssertEqual(r.midX, 960, accuracy: 0.01); XCTAssertEqual(r.minY, 0, accuracy: 0.01)
        // 4:3 → 좌우 여백
        let u = CGRect(x: 0, y: 0, width: 640, height: 480).applying(CompositionPlanner.fitTransform(natural: CGSize(width: 640, height: 480), preferred: .identity, render: render))
        XCTAssertEqual(u.minX, 240, accuracy: 0.01); XCTAssertEqual(u.width, 1440, accuracy: 0.01)
    }
}
