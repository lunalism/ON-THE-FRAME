import Foundation
@testable import OnTheFrameEngine
import XCTest

/// 영상·원본 소리 레인 모델(A-012). 기대값은 손으로 유도한 (시작, 원본 시작, 길이) 표다.
/// 미디어: A 100프레임(소리 있음), B 60프레임(소리 있음), S 40프레임(소리 없음).
final class LaneTimelineTests: XCTestCase {
    let ma = UUID(), mb = UUID(), ms = UUID()
    var base: Timeline { Timeline(mediaFrames: [ma: 100, mb: 60, ms: 40], mediaHasAudio: [ma: true, mb: true, ms: false]) }
    func row(_ cs: [Clip]) -> [[Int]] { cs.map { [$0.start, $0.sourceIn, $0.length] } }

    /// A, B를 넣고 S를 넣은 타임라인: 영상 A@0 B@100 S@160, 소리 A@0 B@100(연결)
    func abs3() throws -> (Timeline, vA: UUID, aA: UUID, vB: UUID, aB: UUID, vS: UUID) {
        let vA = UUID(), aA = UUID(), vB = UUID(), aB = UUID(), vS = UUID()
        let t = try base.inserting(media: ma, clipID: vA, audioClipID: aA).inserting(media: mb, clipID: vB, audioClipID: aB).inserting(media: ms, clipID: vS)
        return (t, vA, aA, vB, aB, vS)
    }

    func testInsertCreatesLinkedPairsAndSilentVideoOnly() throws {
        let (t, vA, aA, vB, aB, vS) = try abs3()
        XCTAssertEqual(row(t.clips), [[0, 0, 100], [100, 0, 60], [160, 0, 40]])
        XCTAssertEqual(row(t.audioClips), [[0, 0, 100], [100, 0, 60]])
        XCTAssertEqual(t.durationFrames, 200)
        XCTAssertNotNil(t.clip(vA)?.link); XCTAssertEqual(t.clip(vA)?.link, t.clip(aA)?.link)
        XCTAssertNotEqual(t.clip(vA)?.link, t.clip(vB)?.link); XCTAssertEqual(t.clip(vB)?.link, t.clip(aB)?.link)
        XCTAssertNil(t.clip(vS)?.link); XCTAssertNil(t.partner(of: vS))
        XCTAssertEqual(Set(t.group(of: aA).map(\.id)), [vA, aA])        // 소리를 골라도 쌍이 함께
        XCTAssertEqual(t.syncOffset(of: vA), 0)
        XCTAssertEqual(t.lanes.map(\.name), ["원본소스", "원본소리"])
        XCTAssertEqual(t.lanes.map(\.id), [Lane.videoID, Lane.audioID])
        XCTAssertTrue(t.isValid)
        XCTAssertFalse(t.movesFreely(vA)); XCTAssertFalse(t.movesFreely(vS))   // 연결된 쌍·소리 없는 영상은 끼워 넣기 이동
    }

    func testLinkedSplitTrimDeleteMoveKeepSync() throws {
        let (t0, vA, aA, vB, _, _) = try abs3()
        // 소리 클립을 대상으로 나눠도 쌍이 같은 위치에서 나뉜다
        let (l, r) = (UUID(), UUID())
        let t1 = try t0.splitting(clip: aA, atFrame: 30, newIDs: (l, r))
        XCTAssertEqual(row(t1.clips), [[0, 0, 30], [30, 30, 70], [100, 0, 60], [160, 0, 40]])
        XCTAssertEqual(row(t1.audioClips), [[0, 0, 30], [30, 30, 70], [100, 0, 60]])
        XCTAssertEqual(t1.clip(l)?.link, t0.clip(vA)?.link)              // 왼쪽 쌍은 원래 연결
        XCTAssertEqual(t1.syncOffset(of: r), 0); XCTAssertNotEqual(t1.clip(r)?.link, t1.clip(l)?.link)
        // 쌍 트림(끝 −10): 두 레인 모두 줄고 뒤(B, S)가 두 레인에서 당겨진다
        let t2 = try t1.trimmingEnd(clip: r, by: -10)
        XCTAssertEqual(row(t2.clips), [[0, 0, 30], [30, 30, 60], [90, 0, 60], [150, 0, 40]])
        XCTAssertEqual(row(t2.audioClips), [[0, 0, 30], [30, 30, 60], [90, 0, 60]])
        XCTAssertEqual(t2.durationFrames, 190)
        // 쌍 앞 트림(+5): 시작 고정, 원본 시작 35, 길이 55, 뒤 −5
        let t3 = try t2.trimmingStart(clip: r, by: 5)
        XCTAssertEqual(row(t3.audioClips), [[0, 0, 30], [30, 35, 55], [85, 0, 60]])
        XCTAssertEqual(t3.syncOffset(of: r), 0)
        // 일반 삭제(쌍): 두 레인 빈틈, 길이 그대로
        let t4 = try t3.lifting(clip: vB)
        XCTAssertEqual(row(t4.clips), [[0, 0, 30], [30, 35, 55], [145, 0, 40]]); XCTAssertEqual(row(t4.audioClips), [[0, 0, 30], [30, 35, 55]])
        XCTAssertEqual(t4.durationFrames, 185); XCTAssertEqual(t4.audioGaps, [85..<185])
        // 리플 삭제(쌍): 두 레인에서 [30, 85) 닫음
        let t5 = try t3.rippleDeleting(clip: r)
        XCTAssertEqual(row(t5.clips), [[0, 0, 30], [30, 0, 60], [90, 0, 40]]); XCTAssertEqual(row(t5.audioClips), [[0, 0, 30], [30, 0, 60]])
        XCTAssertEqual(t5.durationFrames, 130)
        // 끼워 넣기 이동(쌍 B를 맨 앞으로): 두 레인 함께
        let t6 = try t3.moving(clip: vB, toIndex: 0)
        XCTAssertEqual(row(t6.clips), [[0, 0, 60], [60, 0, 30], [90, 35, 55], [145, 0, 40]])
        XCTAssertEqual(row(t6.audioClips), [[0, 0, 60], [60, 0, 30], [90, 35, 55]])
        XCTAssertTrue([t1, t2, t3, t4, t5, t6].allSatisfy(\.isValid))
    }

    func testUnlinkFreeMoveIntoGapRejectsOverlapAndRelinkKeepsOffset() throws {
        let (t0, vA, aA, vB, _, _) = try abs3()
        let t1 = try t0.lifting(clip: vB)                                  // B 쌍 일반 삭제 → 두 레인 [100,160) 빈틈
        let t2 = try t1.unlinking(clip: aA)
        XCTAssertNil(t2.clip(aA)?.link); XCTAssertNil(t2.clip(vA)?.link)
        XCTAssertEqual(row(t2.clips), row(t1.clips)); XCTAssertEqual(row(t2.audioClips), row(t1.audioClips))   // 위치 그대로
        XCTAssertTrue(t2.movesFreely(aA)); XCTAssertTrue(t2.movesFreely(vA))
        // 소리만 +15(빈틈으로 들어감), 원래 자리 [0,15)는 빈틈
        let t3 = try t2.movingFree(clip: aA, toStart: 15)
        XCTAssertEqual(row(t3.audioClips), [[15, 0, 100]]); XCTAssertEqual(t3.audioGaps, [0..<15, 115..<200])
        XCTAssertEqual(row(t3.clips), row(t2.clips)); XCTAssertEqual(t3.durationFrames, 200)
        // 영상 레인에서 영상 A를 S와 겹치게 옮기면 거부(덮어쓰지 않음)
        XCTAssertThrowsError(try t3.movingFree(clip: vA, toStart: 120)) { XCTAssertEqual($0 as? EditError, .overlap) }
        // 끝 너머로 옮기면 길이가 늘어난다
        let t4 = try t3.movingFree(clip: aA, toStart: 210)
        XCTAssertEqual(t4.durationFrames, 310)
        // 다시 연결: 위치·원본 구간 그대로, 어긋남 +15
        let t5 = try t3.linking(vA, aA)
        XCTAssertEqual(row(t5.audioClips), [[15, 0, 100]]); XCTAssertEqual(t5.syncOffset(of: vA), 15); XCTAssertEqual(t5.syncOffset(of: aA), 15)
        // 어긋난 쌍을 영상 기준 프레임 50에서 나누면 소리는 같은 원본 위치(50 + 15 = 65)에서 나뉜다
        let t6 = try t5.splitting(clip: vA, atFrame: 50)
        XCTAssertEqual(row(t6.clips.prefix(2).map { $0 }), [[0, 0, 50], [50, 50, 50]])
        XCTAssertEqual(row(t6.audioClips), [[15, 0, 50], [65, 50, 50]])
        XCTAssertTrue(t6.audioClips.allSatisfy { t6.syncOffset(of: $0.id) == 15 })
        // 짝이 그 원본 위치를 덮지 않으면 거부: 소리가 원본 [40,100)만 쓰는 쌍에서 영상 프레임 10(원본 10)
        let L = UUID(), v1 = UUID(), a1 = UUID()
        let partial = Timeline(clips: [Clip(id: v1, mediaID: ma, start: 0, sourceIn: 0, length: 100, link: L)],
                               audioClips: [Clip(id: a1, mediaID: ma, start: 40, sourceIn: 40, length: 60, link: L)],
                               mediaFrames: [ma: 100], mediaHasAudio: [ma: true])
        XCTAssertTrue(partial.isValid); XCTAssertEqual(partial.syncOffset(of: v1), 0)
        XCTAssertThrowsError(try partial.splitting(clip: v1, atFrame: 10)) { XCTAssertEqual($0 as? EditError, .linkedSplitOutside) }
        XCTAssertNoThrow(try partial.splitting(clip: v1, atFrame: 50))
        // 연결 규칙
        XCTAssertThrowsError(try t5.linking(vA, aA)) { XCTAssertEqual($0 as? EditError, .alreadyLinked) }
        let (u, _, aA2, vB2, _, _) = try abs3()
        let u1 = try u.unlinking(clip: vB2).unlinking(clip: aA2)
        XCTAssertThrowsError(try u1.linking(vB2, aA2)) { XCTAssertEqual($0 as? EditError, .linkDifferentMedia) }
        XCTAssertThrowsError(try u1.linking(vB2, vB2)) { XCTAssertEqual($0 as? EditError, .linkNeedsPair) }
    }

    func testRippleRejectsCrossingContentAndNormalDeletePreserves() throws {
        let (t0, vA, aA, _, _, _) = try abs3()
        let t1 = try t0.unlinking(clip: aA)
        let t2 = try t1.lifting(clip: t1.clips[1].id)                      // B 쌍 지움 → [100,160) 빈틈
        let t3 = try t2.movingFree(clip: aA, toStart: 15)                  // 소리 A [15,115)
        // 영상 A 리플 삭제: 구간 [0,100)에 소리 A가 걸침 → 거부, 원래 그대로
        XCTAssertThrowsError(try t3.rippleDeleting(clip: vA)) { XCTAssertEqual($0 as? EditError, .crossingContent) }
        // 일반 삭제는 된다(다른 위치·길이 그대로)
        let t4 = try t3.lifting(clip: vA)
        XCTAssertEqual(row(t4.audioClips), [[15, 0, 100]]); XCTAssertEqual(t4.durationFrames, 200)
        // 영상 A 앞 트림: 리플 지점(100)에 소리 A [15,115)가 걸침 → 거부
        XCTAssertThrowsError(try t3.trimmingEnd(clip: vA, by: -10)) { XCTAssertEqual($0 as? EditError, .crossingContent) }
        // 삽입 지점(영상 S 시작 160)에는 걸친 것이 없어 된다. 영상 A 시작(0)도 된다. 소리가 걸친 지점(100)은 거부.
        XCTAssertNoThrow(try t3.inserting(media: mb, at: 1))
        let t5 = try t3.movingFree(clip: aA, toStart: 120)                // 소리 [120,220): 영상 S 시작(160)에 걸침
        XCTAssertThrowsError(try t5.inserting(media: mb, at: 1)) { XCTAssertEqual($0 as? EditError, .crossingContent) }
        XCTAssertTrue([t3, t4, t5].allSatisfy(\.isValid))
    }

    func testUndoRedoRestoresLanesLinksPositionsAndNames() throws {
        let (t0, _, aA, _, _, _) = try abs3()
        var h = EditHistory(t0)
        let t1 = try t0.unlinking(clip: aA); h.apply(t1, focus: aA)
        let t2 = try t1.movingFree(clip: aA, toStart: 210); h.apply(t2, focus: aA)
        let t3 = try t2.renamingLane(Lane.videoID, to: "  인터뷰 영상 "); h.apply(t3, focus: nil)
        XCTAssertEqual(t3.lanes[0].name, "인터뷰 영상"); XCTAssertEqual(t3.lanes[0].id, Lane.videoID)
        XCTAssertThrowsError(try t3.renamingLane(Lane.audioID, to: "   ")) { XCTAssertEqual($0 as? EditError, .emptyName) }
        h.undo(); XCTAssertEqual(h.timeline, t2)                            // 이름 한 단계
        h.undo(); XCTAssertEqual(h.timeline, t1)
        h.undo(); XCTAssertEqual(h.timeline, t0)                            // 연결·위치·길이 모두
        h.redo(); h.redo(); h.redo(); XCTAssertEqual(h.timeline, t3)
        // 드래그 하나 = 한 단계, 취소하면 원래대로
        h.beginGesture(); h.updateGesture(try t3.movingFree(clip: aA, toStart: 220), focus: aA); h.updateGesture(try t3.movingFree(clip: aA, toStart: 230), focus: aA)
        h.cancelGesture(); XCTAssertEqual(h.timeline, t3)
        h.beginGesture(); h.updateGesture(try t3.movingFree(clip: aA, toStart: 230), focus: aA); h.commitGesture()
        XCTAssertEqual(h.undoDepth, 4); h.undo(); XCTAssertEqual(h.timeline, t3)
    }

    /// 2026-10-23 전체 검토: 자막 레인이 있을 때 바깥쪽 새 영상 레인(영상 레인 추가·레인 쌍·새 레인에 놓기·새 레인이 필요한 붙여넣기)이
    /// 자막 레인 위(0번)에 들어가 순서가 깨지고 "겹칩니다"로 거부되었다(재현). 이제 영상 묶음 맨 위 = 자막 레인 바로 아래.
    func testOutwardVideoLaneGoesBelowSubtitleLanes() throws {
        let m = UUID()
        var t = Timeline(mediaFrames: [m: 300], mediaHasAudio: [m: true])
        t = try t.inserting(media: m)
        let s1 = UUID(), s2 = UUID()
        t = try t.addingSubtitleCreatingLane(at: 0, text: "가", style: .default, id: UUID(), newLaneID: s1, newLaneName: "S1")
        t = try t.addingLane(.subtitle, name: "S2", id: s2, outward: true)
        let kinds = { (t: Timeline) in t.lanes.map(\.kind) }
        XCTAssertEqual(kinds(t), [.subtitle, .subtitle, .video, .audio])
        // 영상 레인 하나
        let v2 = UUID()
        let a = try t.addingLane(.video, name: "V2", id: v2, outward: true)
        XCTAssertEqual(kinds(a), [.subtitle, .subtitle, .video, .video, .audio]); XCTAssertEqual(a.lanes[2].id, v2); XCTAssertTrue(a.isValid)
        XCTAssertEqual(a.lanes.filter { $0.kind == .subtitle }.map(\.id), [s2, s1])               // 자막 레인 순서 그대로
        XCTAssertEqual(a.lanes(.video).last?.id, Lane.videoID)                                     // 기본 영상 레인(V1)은 경계 쪽 그대로
        // 레인 쌍(영상 위쪽 끝·소리 아래쪽 끝)
        let pv = UUID(), pa = UUID()
        let b = try a.addingLane(.video, name: "V3", id: pv, outward: true).addingLane(.audio, name: "A2", id: pa, outward: true)
        XCTAssertEqual(kinds(b), [.subtitle, .subtitle, .video, .video, .video, .audio, .audio]); XCTAssertEqual(b.lanes[2].id, pv); XCTAssertEqual(b.lanes.last?.id, pa)
        XCTAssertTrue(b.isValid)
        // 새 레인이 필요한 붙여넣기(같은 자리에 연결된 짝 → 겹치므로 새 영상·소리 레인)
        let cid = t.clips[0].id
        let r = try t.pasting(try t.copying(clip: cid), at: 0, newLaneName: { $0 == .video ? "V새" : "A새" })
        XCTAssertEqual(r.createdLanes.count, 2); XCTAssertTrue(r.timeline.isValid)
        XCTAssertEqual(kinds(r.timeline), [.subtitle, .subtitle, .video, .video, .audio, .audio])
        XCTAssertEqual(r.timeline.lanes[2].id, r.createdLanes.first { r.timeline.laneInfo($0)?.kind == .video })
        XCTAssertEqual(r.timeline.clips.count, 2); XCTAssertEqual(r.timeline.subtitles.count, 1)
        // 자막 레인이 없으면 이전과 같다(맨 위)
        var plain = Timeline(mediaFrames: [m: 300], mediaHasAudio: [m: true]); plain = try plain.inserting(media: m)
        XCTAssertEqual(try plain.addingLane(.video, name: "V2", id: v2, outward: true).lanes.first?.id, v2)
        // 새 자막 레인은 여전히 맨 위
        XCTAssertEqual(try a.addingLane(.subtitle, name: "S3", id: UUID(), outward: true).lanes.first?.kind, .subtitle)
    }
}
