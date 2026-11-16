import Foundation
@testable import OnTheFrameEngine
import XCTest

/// 복사·붙여넣기(2026-10-11). 기대값은 손으로 쓴 숫자다.
final class ClipboardTests: XCTestCase {
    let ma = UUID(), mw = UUID(), mx = UUID()
    let v1 = Lane.videoID, a1 = Lane.audioID
    func ref(_ id: UUID, _ name: String, frames: Int, video: Bool = true) -> MediaRef {
        MediaRef(id: id, name: name, path: "/media/\(name)", frameCount: frames, hasAudio: true, size: 1, modifiedNs: 2, codec: video ? "avc1" : "lpcm",
                 width: video ? 1920 : 0, height: video ? 1080 : 0, hasVideo: video)
    }
    /// A(영상+소리 100)를 V1·A1의 0에, W(소리 파일 60)는 등록만
    func base() throws -> Timeline {
        let t = Timeline(media: [ref(ma, "a.mp4", frames: 100), ref(mw, "w.wav", frames: 60, video: false)], mediaFrames: [ma: 100, mw: 60],
                         mediaHasAudio: [ma: true, mw: true])
        return try t.placing(media: ma, at: 0, videoLane: v1, audioLane: a1)
    }
    func rows(_ t: Timeline, _ lane: UUID) -> [[Int]] { t.clips(inLane: lane).sorted { $0.start < $1.start }.map { [$0.start, $0.sourceIn, $0.length] } }
    func name(_ k: LaneKind) -> String { k == .video ? "영상" : "오디오" }

    func testCopyIsNonMutatingAndTakesLinkedPair() throws {
        let t = try base()
        let before = t
        let c = try t.copying(clip: t.clips[0].id)
        XCTAssertEqual(t, before)
        XCTAssertEqual(c.video.map(\.id), [t.clips[0].id]); XCTAssertEqual(c.audio.map(\.id), [t.audioClips[0].id])
        XCTAssertThrowsError(try t.copying(clip: UUID())) { XCTAssertEqual($0 as? EditError, .unknownClip) }
    }

    /// 자른 페이드 조각(offset 있음)·변형·음량을 그대로, 새 ID·새 연결 ID, 원래 클립은 그대로
    func testPastePreservesPropertiesSplitFadeAndFreshIdentities() throws {
        var t = try base()
        let vid = t.clips[0].id, aid = t.audioClips[0].id
        t = try t.settingTransform(clip: vid, ClipTransform(scalePermille: 500, offsetX: 100, offsetY: -50))
        t = try t.settingClipAudio(clip: aid, volumePercent: 70, muted: false, fadeInFrames: 30, fadeOutFrames: 20)
        let rv = UUID()
        t = try t.splitting(clip: vid, atFrame: 10, newIDs: (UUID(), rv))   // 오른쪽 조각(영상 rv와 그 짝 소리): 원본 10…100, 페이드 인 offset 10
        let ra = t.partner(of: rv)!.id
        let right = t.clip(ra)!
        XCTAssertEqual(right.effectiveAudio.fadeIn, ClipAudio.Fade(length: 30, offset: 10))
        let before = t
        let c = try t.copying(clip: rv)
        let r = try t.pasting(c, at: 200, newLaneName: name)
        let p = r.timeline
        XCTAssertTrue(r.createdLanes.isEmpty)
        let nv = p.clip(r.ids[rv]!)!, na = p.clip(r.ids[ra]!)!
        XCTAssertEqual([nv.start, nv.sourceIn, nv.length], [200, 10, 90]); XCTAssertEqual([na.start, na.sourceIn, na.length], [200, 10, 90])
        XCTAssertEqual(nv.lane, v1); XCTAssertEqual(na.lane, a1)
        XCTAssertEqual(nv.transform, before.clip(rv)!.transform); XCTAssertEqual(na.audio, right.audio)
        for f in [0.0, 5, 19.5, 60, 80, 89] {   // 들리는 모양 그대로(자른 페이드 이어짐 포함)
            XCTAssertEqual(na.effectiveAudio.envelope(at: f, length: na.length), right.effectiveAudio.envelope(at: f, length: right.length), accuracy: 1e-12)
        }
        XCTAssertNotEqual(nv.id, rv); XCTAssertNotEqual(na.id, ra)
        XCTAssertNotNil(nv.link); XCTAssertEqual(nv.link, na.link); XCTAssertNotEqual(nv.link, before.clip(rv)!.link)
        XCTAssertEqual(p.partner(of: nv.id)?.id, na.id); XCTAssertEqual(p.partner(of: rv)?.id, ra, "원래 쌍은 그대로 서로 연결")
        for c in before.clips + before.audioClips { XCTAssertEqual(p.clip(c.id), c, "원래 클립은 그대로") }
        XCTAssertEqual(p.durationFrames, 290)
        // 원래와 복제는 따로 편집된다
        let edited = try p.settingClipAudio(clip: na.id, volumePercent: 10)
        XCTAssertEqual(edited.clip(ra), p.clip(ra))
    }

    /// 겹치면 기존 클립을 덮지 않고 다음 레인 → 새 레인(같은 편집). 빈 레인이 있으면 새로 만들지 않는다.
    func testOverlapUsesNextLaneOrCreatesLaneAtomically() throws {
        let t = try base()
        let c = try t.copying(clip: t.clips[0].id)
        let r = try t.pasting(c, at: 50, newLaneName: name)
        XCTAssertEqual(r.createdLanes.count, 2)
        let nv = r.timeline.clip(r.ids[t.clips[0].id]!)!, na = r.timeline.clip(r.ids[t.audioClips[0].id]!)!
        XCTAssertTrue(r.createdLanes.contains(nv.lane!)); XCTAssertTrue(r.createdLanes.contains(na.lane!))
        XCTAssertEqual(r.timeline.laneInfo(nv.lane!)?.kind, .video); XCTAssertEqual(r.timeline.laneInfo(na.lane!)?.kind, .audio)
        XCTAssertEqual(rows(r.timeline, v1), [[0, 0, 100]]); XCTAssertEqual(rows(r.timeline, a1), [[0, 0, 100]])
        XCTAssertEqual(r.timeline.lanes.count, 4); XCTAssertEqual(r.timeline.durationFrames, 150)
        // 빈 V2·A2가 있으면 그 레인을 쓴다
        let v2 = UUID(), a2 = UUID()
        let t2 = try t.addingLane(.video, name: "영상", id: v2, outward: true).addingLane(.audio, name: "오디오", id: a2, outward: true)
        let r2 = try t2.pasting(c, at: 50, newLaneName: name)
        XCTAssertTrue(r2.createdLanes.isEmpty)
        XCTAssertEqual(rows(r2.timeline, v2), [[50, 0, 100]]); XCTAssertEqual(rows(r2.timeline, a2), [[50, 0, 100]])
        // 실행 취소·다시 실행은 레인 생성까지 한 단계
        var h = EditHistory(t)
        h.apply(r.timeline, focus: nv.id)
        XCTAssertEqual(h.undoDepth, 1)
        h.undo(); XCTAssertEqual(h.timeline, t); XCTAssertEqual(h.timeline.lanes.count, 2)
        h.redo(); XCTAssertEqual(h.timeline, r.timeline)
    }

    /// 묶음 안의 상대 위치(어긋난 연결 쌍)를 지키고 가장 이른 시작을 붙여 넣는 곳에 둔다
    func testRelativeOffsetsAnchoredAtEarliestStart() throws {
        var t = try base()
        let vid = t.clips[0].id, aid = t.audioClips[0].id
        t = try t.unlinking(clip: vid)
        t = try t.relocating(clip: aid, toStart: 7)
        t = try t.trimmingEnd(clip: aid, by: -7)   // 소리 7…100, 원본 0…93
        t = try t.linking(vid, aid)
        let r = try t.pasting(try t.copying(clip: vid), at: 300, newLaneName: name)
        let nv = r.timeline.clip(r.ids[vid]!)!, na = r.timeline.clip(r.ids[aid]!)!
        XCTAssertEqual([nv.start, na.start], [300, 307]); XCTAssertEqual(r.timeline.syncOffset(of: nv.id), t.syncOffset(of: vid))
    }

    func testAudioOnlyClipAndInvalidPastesLeaveTimelineUnchanged() throws {
        var t = try base()
        t = try t.placing(media: mw, at: 120, videoLane: nil, audioLane: a1)
        let w = t.audioClips.first { $0.mediaID == mw }!
        let c = try t.copying(clip: w.id)
        XCTAssertTrue(c.video.isEmpty); XCTAssertEqual(c.audio.count, 1)
        let r = try t.pasting(c, at: 200, newLaneName: name)
        XCTAssertEqual(rows(r.timeline, a1).last, [200, 0, 60]); XCTAssertEqual(r.timeline.clips, t.clips)
        XCTAssertThrowsError(try t.pasting(ClipboardContent(video: [], audio: []), at: 0, newLaneName: name)) { XCTAssertEqual($0 as? EditError, .clipboardEmpty) }
        // 다른 프로젝트의 미디어 ID·원본 범위를 넘는 클립은 거부(일부만 넣지 않음)
        let foreign = Clip(mediaID: mx, start: 0, sourceIn: 0, length: 10, lane: v1)
        XCTAssertThrowsError(try t.pasting(ClipboardContent(video: [foreign], audio: c.audio), at: 0, newLaneName: name)) { XCTAssertEqual($0 as? EditError, .clipboardMismatch) }
        let tooLong = Clip(mediaID: mw, start: 0, sourceIn: 50, length: 20, lane: a1)
        XCTAssertThrowsError(try t.pasting(ClipboardContent(video: [], audio: [tooLong]), at: 0, newLaneName: name)) { XCTAssertEqual($0 as? EditError, .clipboardMismatch) }
        XCTAssertThrowsError(try t.pasting(c, at: -1, newLaneName: name)) { XCTAssertEqual($0 as? EditError, .badIndex) }
    }
}
