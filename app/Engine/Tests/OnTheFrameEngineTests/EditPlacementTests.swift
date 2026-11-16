import Foundation
@testable import OnTheFrameEngine
import XCTest

/// 2026-10-11 소유자 보고 수정: 추가(+) 위치, 끌어 옮기기(연결된 쌍 포함, 리플 없음, 원자적 거부), 붙음, 가운데 경계 레인 배치·번호.
/// 기대값은 손으로 쓴 숫자다.
final class EditPlacementTests: XCTestCase {
    let ma = UUID(), mb = UUID(), mc = UUID(), mw = UUID()
    func ref(_ id: UUID, _ name: String, frames: Int, audio: Bool = true, video: Bool = true) -> MediaRef {
        MediaRef(id: id, name: name, path: "/media/\(name)", frameCount: frames, hasAudio: audio, size: 1, modifiedNs: 2, codec: video ? "avc1" : "lpcm",
                 width: video ? 1920 : 0, height: video ? 1080 : 0, hasVideo: video)
    }
    /// A(100, 소리 있음), B(60, 소리 있음), C(30, 소리 없음), W(소리 파일 60)
    func base() -> Timeline {
        let refs = [ref(ma, "a.mp4", frames: 100), ref(mb, "b.mp4", frames: 60), ref(mc, "c.mp4", frames: 30, audio: false), ref(mw, "w.wav", frames: 60, video: false)]
        return Timeline(media: refs, mediaFrames: [ma: 100, mb: 60, mc: 30, mw: 60], mediaHasAudio: [ma: true, mb: true, mc: false, mw: true])
    }
    func rows(_ t: Timeline, _ lane: UUID) -> [[Int]] { t.clips(inLane: lane).map { [$0.start, $0.length] } }
    let v1 = Lane.videoID, a1 = Lane.audioID

    // MARK: 추가

    /// 빈 타임라인의 첫 추가는 0. 일반 삭제로 길이만 남은 빈 타임라인도 0(이전에는 남은 길이 끝 = 2:22 같은 앞 빈틈이 생겼다).
    func testFirstAppendStartsAtZeroEvenWithRetainedDuration() throws {
        let t0 = try base().appending(media: ma, videoLane: v1, audioLane: a1)
        XCTAssertEqual(rows(t0, v1), [[0, 100]]); XCTAssertEqual(rows(t0, a1), [[0, 100]])
        // 이전 동작 재현: 일반 삭제 뒤 길이 100이 남은 상태에서 끝에 리플 삽입하면 100에서 시작했다
        let lifted = try t0.lifting(clip: t0.clips[0].id)
        XCTAssertTrue(lifted.isEmpty); XCTAssertEqual(lifted.durationFrames, 100)
        XCTAssertEqual(try lifted.inserting(media: mb).clips.map(\.start), [100])
        // 새 추가: 0
        let t1 = try lifted.appending(media: mb, videoLane: v1, audioLane: a1)
        XCTAssertEqual(rows(t1, v1), [[0, 60]]); XCTAssertEqual(rows(t1, a1), [[0, 60]])
        XCTAssertEqual(t1.durationFrames, 100)   // 길이는 줄이지 않는다(일반 삭제 규칙 그대로)
    }

    /// 채운 타임라인: 고른 레인 쌍의 마지막 끝 뒤. 다른 레인이 더 길어도 그 끝을 쓰지 않는다. 기존 빈틈은 그대로.
    func testAppendAfterChosenPairEndKeepsGapsAndIgnoresOtherLanes() throws {
        let v2 = UUID(), a2 = UUID()
        var t = try base().addingLane(.video, name: "영상", id: v2, outward: true).addingLane(.audio, name: "오디오", id: a2, outward: true)
        t = try t.placing(media: ma, at: 20, videoLane: v1, audioLane: a1)          // 의도한 앞 빈틈 [0,20)
        t = try t.placing(media: mw, at: 150, videoLane: nil, audioLane: a2)        // 다른 레인이 210까지
        let t2 = try t.appending(media: mb, videoLane: v1, audioLane: a1)
        XCTAssertEqual(rows(t2, v1), [[20, 100], [120, 60]]); XCTAssertEqual(rows(t2, a1), [[20, 100], [120, 60]])
        XCTAssertEqual(t2.gaps(inLane: v1).first, 0..<20)
        XCTAssertEqual(rows(t2, a2), [[150, 60]])
        // 소리 없는 영상: 영상 레인만. 소리 파일: 오디오 레인만
        let t3 = try t2.appending(media: mc, videoLane: v1, audioLane: a1)
        XCTAssertEqual(rows(t3, v1).last, [180, 30]); XCTAssertEqual(rows(t3, a1).count, 2)
        let t4 = try t3.appending(media: mw, videoLane: nil, audioLane: a1)
        XCTAssertEqual(rows(t4, a1).last, [180, 60]); XCTAssertEqual(rows(t4, v1).count, 3)
        // 고른 쌍 V2/A2: A2의 끝(210) 뒤
        let t5 = try t4.appending(media: mb, videoLane: v2, audioLane: a2)
        XCTAssertEqual(rows(t5, v2), [[210, 60]]); XCTAssertEqual(rows(t5, a2), [[150, 60], [210, 60]])
        // 쌍의 한쪽만 더 길면 그 끝(어느 레인에서도 겹치지 않음)
        var u = try base().appending(media: ma, videoLane: v1, audioLane: a1)
        u = try u.unlinking(clip: u.clips[0].id).relocating(clip: u.audioClips[0].id, toStart: 30)   // 소리 [30,130)
        XCTAssertEqual(try u.appending(media: mb, videoLane: v1, audioLane: a1).clips.map(\.start), [0, 130])
    }

    // MARK: 끌어 옮기기(옮기기, 리플 없음)

    /// 연결된 쌍을 왼쪽·오른쪽·빈틈·0으로. 다른 클립·다른 레인은 움직이지 않고, 원래 자리는 빈틈이 된다.
    func testLinkedPairMovesLeftRightIntoGapAndToZeroWithoutRipple() throws {
        let a2 = UUID()
        var t = try base().addingLane(.audio, name: "효과", id: a2, outward: true)
        t = try t.placing(media: ma, at: 82, videoLane: v1, audioLane: a1)          // 앞 빈틈 82프레임(2:22)
        t = try t.placing(media: mb, at: 200, videoLane: v1, audioLane: a1)
        t = try t.placing(media: mw, at: 0, videoLane: nil, audioLane: a2)
        let pA = t.clips(inLane: v1)[0].id
        // 0으로(앞 빈틈 닫기): 짝도 같이, 뒤의 B와 다른 레인 W는 그대로
        let z = try t.relocating(clip: pA, toStart: 0)
        XCTAssertEqual(rows(z, v1), [[0, 100], [200, 60]]); XCTAssertEqual(rows(z, a1), [[0, 100], [200, 60]]); XCTAssertEqual(rows(z, a2), [[0, 60]])
        XCTAssertEqual(z.syncOffset(of: pA), 0); XCTAssertEqual(z.durationFrames, t.durationFrames)
        // 오른쪽 빈틈 [182,200) 안쪽으로 조금: [90,190)은 B [200,260)과 겹치지 않음
        XCTAssertEqual(rows(try t.relocating(clip: pA, toStart: 90), v1), [[90, 100], [200, 60]])
        // B를 A 앞 빈틈 [0,82)에 다 들어가게(60 ≤ 82)
        let pB = t.clips(inLane: v1)[1].id
        let g = try t.relocating(clip: pB, toStart: 10)
        XCTAssertEqual(rows(g, v1), [[10, 60], [82, 100]]); XCTAssertEqual(rows(g, a1), [[10, 60], [82, 100]])
        // 소리 레인에서 짝을 잡아도 묶음이 함께
        let viaAudio = try t.relocating(clip: t.partner(of: pA)!.id, toStart: 0)
        XCTAssertEqual(viaAudio, z)
    }

    /// 대상이 어느 레인에서든 겹치면 묶음 전체를 거부(일부만 옮기지 않음). 어긋난 쌍은 상대 위치 그대로 옮긴다.
    func testOverlapAnywhereRejectsWholeMoveAndOffsetIsPreserved() throws {
        var t = try base().placing(media: ma, at: 0, videoLane: v1, audioLane: a1)
        t = try t.placing(media: mb, at: 150, videoLane: v1, audioLane: a1)
        let pA = t.clips(inLane: v1)[0].id
        // 영상은 비었지만 소리만 겹치게: B의 소리를 떼어 [100,160)으로
        let bA = t.partner(of: t.clips(inLane: v1)[1].id)!.id
        t = try t.unlinking(clip: bA).relocating(clip: bA, toStart: 100)
        XCTAssertThrowsError(try t.relocating(clip: pA, toStart: 40)) { XCTAssertEqual($0 as? EditError, .overlap) }   // 소리 [40,140)이 [100,160)과 겹침
        // 어긋난 쌍(소리 +5): 상대 위치 유지
        var u = try base().placing(media: ma, at: 50, videoLane: v1, audioLane: a1)
        let v = u.clips[0].id, a = u.audioClips[0].id
        u = try u.unlinking(clip: v).relocating(clip: a, toStart: 55).linking(v, a)
        XCTAssertEqual(u.syncOffset(of: v), 5)
        let m = try u.relocating(clip: v, toStart: 0)
        XCTAssertEqual(m.clip(v)?.start, 0); XCTAssertEqual(m.clip(a)?.start, 5); XCTAssertEqual(m.syncOffset(of: v), 5)
        // 짝이 0보다 앞서는 위치는 거부(묶음 전체)
        var w = try base().placing(media: ma, at: 50, videoLane: v1, audioLane: a1)
        let wv = w.clips[0].id, wa = w.audioClips[0].id
        w = try w.unlinking(clip: wv).relocating(clip: wa, toStart: 40).linking(wv, wa)
        XCTAssertThrowsError(try w.relocating(clip: wv, toStart: 5)) { XCTAssertEqual($0 as? EditError, .badIndex) }
    }

    /// 붙음: 0과 다른 클립 경계, 거리 안에서만, 묶음의 가장 이른 시작이 0보다 앞서지 않게
    func testSnapToZeroAndClipBoundaries() throws {
        var t = try base().placing(media: ma, at: 82, videoLane: v1, audioLane: a1)
        t = try t.placing(media: mb, at: 300, videoLane: v1, audioLane: a1)
        let pA = t.clips(inLane: v1)[0].id
        // A 시작 82를 −79만큼(→3): 0에서 3프레임, 거리 4면 0에 붙음
        XCTAssertEqual(t.snappedDelta(clip: pA, delta: -79, threshold: 4).delta, -82)
        XCTAssertEqual(t.snappedDelta(clip: pA, delta: -79, threshold: 4).snap, 0)
        // 거리 2면 붙지 않음
        XCTAssertEqual(t.snappedDelta(clip: pA, delta: -79, threshold: 2).delta, -79)
        XCTAssertNil(t.snappedDelta(clip: pA, delta: -79, threshold: 2).snap)
        // A 끝(182)을 B 시작(300) 가까이: +116 → 끝 298, 거리 4 안 → +118로 붙음(끝 = 300)
        XCTAssertEqual(t.snappedDelta(clip: pA, delta: 116, threshold: 4).delta, 118)
        XCTAssertEqual(t.snappedDelta(clip: pA, delta: 116, threshold: 4).snap, 300)
        // 자기 묶음 경계에는 붙지 않는다(짝 소리 [82,182)는 대상 아님)
        XCTAssertEqual(t.snappedDelta(clip: pA, delta: 1, threshold: 4).delta, 1)
        // 거리는 반올림 전 값: 확대 9(붙음 8pt = 0.89프레임)에서 포인터가 0에서 5pt(0.56프레임)면 붙는다(반올림한 1프레임으로 재면 붙지 않았다)
        XCTAssertEqual(t.snappedDelta(clip: pA, delta: -82 + 5.0 / 9, threshold: 8.0 / 9).snap, 0)
        XCTAssertEqual(t.snappedDelta(clip: pA, delta: -82 + 9.0 / 9, threshold: 8.0 / 9).delta, -81)
    }

    // MARK: 가운데 경계 배치

    /// 새 영상 레인은 맨 위(V2, V3…), 새 오디오 레인은 맨 아래(A2, A3…). 번호는 경계에서 바깥쪽, 이름과 따로.
    func testOutwardLaneArrangementAndNumbering() throws {
        let v2 = UUID(), a2 = UUID(), v3 = UUID()
        let t = try base().addingLane(.video, name: "영상", id: v2, outward: true).addingLane(.audio, name: "오디오", id: a2, outward: true)
            .addingLane(.video, name: "영상", id: v3, outward: true)
        XCTAssertEqual(t.lanes.map(\.id), [v3, v2, v1, a1, a2])   // 화면 위 → 아래
        XCTAssertEqual(t.lanes.map { t.laneLabel($0.id) }, ["V3", "V2", "V1", "A1", "A2"])
        XCTAssertEqual(t.baseLane(.video)?.id, v1); XCTAssertEqual(t.baseLane(.audio)?.id, a1)
        XCTAssertEqual(t.pairedLane(of: v2)?.id, a2); XCTAssertEqual(t.pairedLane(of: a1)?.id, v1); XCTAssertNil(t.pairedLane(of: v3))
        XCTAssertTrue(t.isValid)
        // 위 영상 레인이 쌓음 우선순위: V2의 클립이 V1 위
        var u = try t.placing(media: ma, at: 0, videoLane: v1, audioLane: a1).placing(media: mc, at: 10, videoLane: v2, audioLane: nil)
        XCTAssertEqual(u.visibleVideoSegments().map(\.mediaID), [ma, mc, ma])
        // 이름 바꾸기는 번호를 바꾸지 않는다
        u = try u.renamingLane(v2, to: "자막 배경")
        XCTAssertEqual(u.laneLabel(v2), "V2")
    }

    /// 이전 파일(A-014: 영상 레인을 아래에 추가하던 배열)을 열면 배열 순서·쌓음 우선순위·ID가 그대로이고, 번호만 경계 기준으로 보인다.
    func testExistingLaneOrderPreservedOnSaveAndReopen() throws {
        let vLow = UUID()
        var t = try base().addingLane(.video, name: "영상 2", id: vLow)   // 이전 기본: 영상 묶음 아래(경계 쪽)
        t = try t.placing(media: ma, at: 0, videoLane: v1, audioLane: a1).placing(media: mc, at: 10, videoLane: vLow, audioLane: nil)
        XCTAssertEqual(t.lanes.map(\.id), [v1, vLow, a1])
        XCTAssertEqual(t.laneLabel(vLow), "V1"); XCTAssertEqual(t.laneLabel(v1), "V2")   // 경계 바로 위가 V1
        XCTAssertEqual(t.visibleVideoSegments().map(\.mediaID), [ma])                    // 위 레인(원본소스)이 계속 위
        let data = try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        let back = try ProjectFile.decode(data).timeline
        XCTAssertEqual(back, t)
        XCTAssertEqual(back.lanes.map(\.id), [v1, vLow, a1])
        XCTAssertEqual(back.lanes.map { back.laneLabel($0.id) }, ["V2", "V1", "A1"])
    }
}
