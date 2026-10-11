import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 여러 레인 편집 모델(A-014): 레인 추가·이름·순서·삭제, 레인 사이 겹침, 연결된 쌍의 레인 옮기기(원자적), 모든 레인에 걸친 리플 거부,
/// 가장 위 영상 레인이 보이는 조각, 오디오 레인 음소거·음량, 프로젝트 형식 1 읽기·형식 2 왕복. 기대값은 손으로 쓴 숫자다.
final class MultiLaneModelTests: XCTestCase {
    let ma = UUID(), mb = UUID(), mc = UUID(), mw = UUID()
    func ref(_ id: UUID, _ name: String, frames: Int, audio: Bool = true, video: Bool = true) -> MediaRef {
        MediaRef(id: id, name: name, path: "/media/\(name)", frameCount: frames, hasAudio: audio, size: 1, modifiedNs: 2, codec: video ? "avc1" : "lpcm",
                 width: video ? 1920 : 0, height: video ? 1080 : 0, hasVideo: video, sampleRate: video ? nil : 48_000, sampleCount: video ? nil : 96_000,
                 channels: video ? nil : 2)
    }
    /// A(100프레임, 소리 있음), B(60, 소리 있음), C(30, 소리 없음), W(소리 파일 60)
    func base() -> Timeline {
        let refs = [ref(ma, "a.mp4", frames: 100), ref(mb, "b.mp4", frames: 60), ref(mc, "c.mp4", frames: 30, audio: false), ref(mw, "w.wav", frames: 60, video: false)]
        return Timeline(media: refs, mediaFrames: [ma: 100, mb: 60, mc: 30, mw: 60], mediaHasAudio: [ma: true, mb: true, mc: false, mw: true])
    }
    func rows(_ t: Timeline, _ lane: UUID) -> [[Int]] { t.clips(inLane: lane).map { [$0.start, $0.sourceIn, $0.length] } }
    func err(_ e: Error) -> OnTheFrameEngine.EditError? { e as? OnTheFrameEngine.EditError }

    func testLaneCRUDOrderAndUndo() throws {
        var h = EditHistory(base())
        let v2 = UUID(), a2 = UUID(), a3 = UUID()
        h.apply(try h.timeline.addingLane(.video, name: "영상 2", id: v2), focus: nil)
        h.apply(try h.timeline.addingLane(.audio, name: "효과음", id: a2), focus: nil)
        h.apply(try h.timeline.addingLane(.audio, name: "배경음", id: a3), focus: nil)
        // 영상 레인은 영상 묶음 끝(오디오 레인 위), 오디오 레인은 맨 끝에 붙는다
        XCTAssertEqual(h.timeline.lanes.map(\.id), [Lane.videoID, v2, Lane.audioID, a2, a3])
        XCTAssertThrowsError(try h.timeline.addingLane(.audio, name: "   ")) { XCTAssertEqual(self.err($0), .emptyName) }
        // 순서: 같은 종류 안에서만. 영상 레인을 오디오 레인 아래로 내릴 수 없다
        h.apply(try h.timeline.movingLane(v2, by: -1), focus: nil)
        XCTAssertEqual(h.timeline.lanes.map(\.id), [v2, Lane.videoID, Lane.audioID, a2, a3])
        XCTAssertEqual(try h.timeline.movingLane(Lane.videoID, by: 1), h.timeline)
        h.apply(try h.timeline.movingLane(a3, by: -1), focus: nil)
        XCTAssertEqual(h.timeline.lanes.map(\.id), [v2, Lane.videoID, Lane.audioID, a3, a2])
        h.apply(try h.timeline.renamingLane(a3, to: "  내레이션 "), focus: nil)
        XCTAssertEqual(h.timeline.laneInfo(a3)?.name, "내레이션")
        // 음소거·음량(0–100 정수)
        h.apply(try h.timeline.settingLaneAudio(a2, muted: true, volumePercent: 35), focus: nil)
        XCTAssertEqual(h.timeline.laneInfo(a2).map { [$0.muted ? 1 : 0, $0.volumePercent] }, [1, 35])
        XCTAssertThrowsError(try h.timeline.settingLaneAudio(a2, volumePercent: 101)) { XCTAssertEqual(self.err($0), .volumeRange) }
        XCTAssertThrowsError(try h.timeline.settingLaneAudio(a2, volumePercent: -1))
        XCTAssertThrowsError(try h.timeline.settingLaneAudio(v2, muted: true)) { XCTAssertEqual(self.err($0), .laneKindMismatch) }
        // 그 종류의 마지막 레인은 지우지 않는다
        h.apply(try h.timeline.removingLane(v2), focus: nil)
        XCTAssertThrowsError(try h.timeline.removingLane(Lane.videoID)) { XCTAssertEqual(self.err($0), .lastLane) }
        XCTAssertTrue(h.timeline.isValid)
        // 8단계(추가 3, 순서 2, 이름 1, 음소거·음량 1, 삭제 1): 실행 취소 8번이면 처음 상태, 다시 실행 8번이면 마지막 상태
        let last = h.timeline
        XCTAssertEqual(h.undoDepth, 8)
        for _ in 0..<8 { h.undo() }
        XCTAssertEqual(h.timeline, base()); XCTAssertFalse(h.canUndo)
        for _ in 0..<8 { h.redo() }
        XCTAssertEqual(h.timeline, last)
        XCTAssertEqual(h.timeline.lanes.map(\.id), [Lane.videoID, Lane.audioID, a3, a2])
    }

    /// 레인 사이 겹침은 되고 같은 레인 안 겹침은 거부. 다른 종류 레인으로 옮기기도 거부.
    func testCrossLaneOverlapAllowedSameLaneRejected() throws {
        let v2 = UUID(), a2 = UUID()
        var t = try base().addingLane(.video, name: "V2", id: v2).addingLane(.audio, name: "A2", id: a2)
        t = try t.inserting(media: ma)                                              // V1 [0,100) + 연결 소리 A1 [0,100)
        t = try t.placing(media: mb, at: 20, videoLane: v2, audioLane: a2)          // V2 [20,80) + A2 [20,80): 다른 레인과 겹침 허용
        XCTAssertEqual(rows(t, Lane.videoID), [[0, 0, 100]]); XCTAssertEqual(rows(t, v2), [[20, 0, 60]])
        XCTAssertEqual(rows(t, Lane.audioID), [[0, 0, 100]]); XCTAssertEqual(rows(t, a2), [[20, 0, 60]])
        XCTAssertEqual(t.durationFrames, 100); XCTAssertTrue(t.isValid)
        let bv = t.clips(inLane: v2)[0].id
        XCTAssertEqual(t.partner(of: bv)?.lane, a2)
        // 같은 레인 겹침: 영상만 겹쳐도 거부(소리도 놓이지 않음)
        XCTAssertThrowsError(try t.placing(media: mb, at: 50, videoLane: Lane.videoID, audioLane: a2)) { XCTAssertEqual(self.err($0), .overlap) }
        XCTAssertThrowsError(try t.placing(media: mb, at: 79, videoLane: v2, audioLane: Lane.audioID))   // V2 [79,139)가 [20,80)과 1프레임 겹침
        let t2 = try t.placing(media: mb, at: 80, videoLane: v2, audioLane: a2)        // 바로 뒤: 허용, 길이 140
        XCTAssertEqual(rows(t2, v2), [[20, 0, 60], [80, 0, 60]]); XCTAssertEqual(t2.durationFrames, 140)
        // 소리 파일: 소리 클립만, 고른 오디오 레인
        XCTAssertThrowsError(try t.placing(media: mw, at: 5, videoLane: nil, audioLane: Lane.audioID)) { XCTAssertEqual(self.err($0), .overlap) }
        let t3 = try t.placing(media: mw, at: 80, videoLane: nil, audioLane: a2)
        XCTAssertEqual(rows(t3, a2), [[20, 0, 60], [80, 0, 60]]); XCTAssertEqual(t3.clips.count, t.clips.count)
        XCTAssertNil(t3.clips(inLane: a2)[1].link)
        XCTAssertThrowsError(try t.placing(media: mw, at: 80, videoLane: nil, audioLane: v2)) { XCTAssertEqual(self.err($0), .laneKindMismatch) }
        // 다른 종류 레인으로 옮기기 거부
        XCTAssertThrowsError(try t.relocating(clip: bv, lane: Lane.audioID)) { XCTAssertEqual(self.err($0), .laneKindMismatch) }
    }

    /// 연결된 쌍을 다른 레인으로: 두 대상이 모두 맞아야 하고, 하나라도 겹치면 아무것도 바뀌지 않는다.
    func testLinkedRelocationIsAtomic() throws {
        let v2 = UUID(), a2 = UUID()
        var t = try base().addingLane(.video, name: "V2", id: v2).addingLane(.audio, name: "A2", id: a2)
        t = try t.inserting(media: ma)                                              // V1/A1 [0,100)
        t = try t.placing(media: mb, at: 120, videoLane: v2, audioLane: a2)         // V2/A2 [120,180)
        t = try t.placing(media: mw, at: 0, videoLane: nil, audioLane: a2)          // A2 [0,60) 소리 파일
        let bv = t.clips(inLane: v2)[0].id, ba = try XCTUnwrap(t.partner(of: bv)).id
        let before = t
        // 소리 쪽 대상(A2 [30,90))이 W와 겹침 → 거부, 영상도 그대로
        XCTAssertThrowsError(try t.relocating(clip: bv, toStart: 30)) { XCTAssertEqual(self.err($0), .overlap) }
        // 소리를 A1로 바꾸면 A1 [0,100)과 겹침 → 거부
        XCTAssertThrowsError(try t.relocating(clip: bv, toStart: 30, partnerLane: Lane.audioID)) { XCTAssertEqual(self.err($0), .overlap) }
        // 짝의 대상 레인 종류가 틀리면 거부
        XCTAssertThrowsError(try t.relocating(clip: bv, toStart: 100, lane: Lane.videoID, partnerLane: v2)) { XCTAssertEqual(self.err($0), .laneKindMismatch) }
        XCTAssertEqual(t, before)
        // 둘 다 맞는 대상: V1·A1 [100,160)
        let moved = try t.relocating(clip: bv, toStart: 100, lane: Lane.videoID, partnerLane: Lane.audioID)
        XCTAssertEqual(rows(moved, Lane.videoID), [[0, 0, 100], [100, 0, 60]]); XCTAssertEqual(rows(moved, v2), [])
        XCTAssertEqual(rows(moved, Lane.audioID), [[0, 0, 100], [100, 0, 60]]); XCTAssertEqual(rows(moved, a2), [[0, 0, 60]])
        XCTAssertEqual(moved.partner(of: bv)?.id, ba); XCTAssertEqual(moved.syncOffset(of: bv), 0)
        XCTAssertEqual(moved.durationFrames, 180)                                   // 일반 옮기기는 길이를 줄이지 않음(빈틈)
        // 소리 클립을 대상으로 해도 같은 결과(대상 = 소리, 짝 = 영상)
        let movedByAudio = try t.relocating(clip: ba, toStart: 100, lane: Lane.audioID, partnerLane: Lane.videoID)
        XCTAssertEqual(rows(movedByAudio, Lane.videoID), rows(moved, Lane.videoID)); XCTAssertEqual(rows(movedByAudio, Lane.audioID), rows(moved, Lane.audioID))
        // 한 번의 끌기 = 한 단계, Esc = 끌기 전으로
        var h = EditHistory(t)
        h.beginGesture()
        h.updateGesture(try t.relocating(clip: bv, toStart: 140), focus: bv)
        h.updateGesture(moved, focus: bv)
        h.cancelGesture()
        XCTAssertEqual(h.timeline, t); XCTAssertFalse(h.canUndo)
        h.beginGesture(); h.updateGesture(try t.relocating(clip: bv, toStart: 140), focus: bv); h.updateGesture(moved, focus: bv); h.commitGesture()
        XCTAssertEqual(h.undoDepth, 1); h.undo(); XCTAssertEqual(h.timeline, t)
    }

    /// 리플 삭제·리플 트림·삽입은 모든 레인에 적용되고, 묶음이 아닌 클립이 (어느 레인이든) 걸치면 거부한다.
    func testRippleAcrossLanesRejectsCrossing() throws {
        let v2 = UUID()
        var t = try base().addingLane(.video, name: "V2", id: v2)
        t = try t.inserting(media: ma).inserting(media: mc)                          // V1: A [0,100), C [100,130); A1: A [0,100)
        t = try t.placing(media: mc, at: 40, videoLane: v2, audioLane: nil)          // V2 [40,70)
        t = try t.placing(media: mc, at: 140, videoLane: v2, audioLane: nil)         // V2 [140,170), 길이 170
        let c1 = t.clips(inLane: Lane.videoID)[1].id, v2a = t.clips(inLane: v2)[0].id
        // V2 [40,70) 리플 삭제: A 쌍이 걸침 → 거부. 일반 삭제는 됨(빈틈)
        XCTAssertThrowsError(try t.rippleDeleting(clip: v2a)) { XCTAssertEqual(self.err($0), .crossingContent) }
        XCTAssertEqual(try t.lifting(clip: v2a).durationFrames, 170)
        // V2 [40,70) 끝 트림: 끝 지점 70에 A가 걸침 → 거부
        XCTAssertThrowsError(try t.trimmingEnd(clip: v2a, by: -10)) { XCTAssertEqual(self.err($0), .crossingContent) }
        // C [100,130) 끝 트림 −10: 걸침 없음 → V2 [140,170)이 [130,160)으로 당겨짐(다른 레인에도 리플)
        let trimmed = try t.trimmingEnd(clip: c1, by: -10)
        XCTAssertEqual(rows(trimmed, Lane.videoID), [[0, 0, 100], [100, 0, 20]]); XCTAssertEqual(rows(trimmed, v2), [[40, 0, 30], [130, 0, 30]])
        XCTAssertEqual(trimmed.durationFrames, 160)
        // C 리플 삭제: 뒤의 V2 클립도 30 당김
        let rippled = try t.rippleDeleting(clip: c1)
        XCTAssertEqual(rows(rippled, v2), [[40, 0, 30], [110, 0, 30]]); XCTAssertEqual(rippled.durationFrames, 140)
        // 삽입(지점 100 = C 시작): 걸침 없음 → 다른 레인 뒤쪽도 밀림
        let ins = try t.inserting(media: mc, at: 1)
        XCTAssertEqual(rows(ins, Lane.videoID), [[0, 0, 100], [100, 0, 30], [130, 0, 30]]); XCTAssertEqual(rows(ins, v2), [[40, 0, 30], [170, 0, 30]])
        // V2에 지점 100을 걸치는 클립이 있으면 삽입 거부
        let crossing = try t.lifting(clip: v2a).placing(media: mc, at: 90, videoLane: v2, audioLane: nil)
        XCTAssertThrowsError(try crossing.inserting(media: mc, at: 1)) { XCTAssertEqual(self.err($0), .crossingContent) }
    }

    /// 레인 삭제: 레인과 클립을 지우고, 짝을 잃은 클립은 연결만 풀린다(한 단계).
    func testRemovingNonemptyLaneUnlinksSurvivingPartners() throws {
        let v2 = UUID(), a2 = UUID()
        var t = try base().addingLane(.video, name: "V2", id: v2).addingLane(.audio, name: "A2", id: a2)
        t = try t.inserting(media: ma).placing(media: mb, at: 10, videoLane: v2, audioLane: a2)
        let bv = t.clips(inLane: v2)[0].id, ba = try XCTUnwrap(t.partner(of: bv)).id
        var h = EditHistory(t)
        h.apply(try t.removingLane(v2), focus: nil)
        let r = h.timeline
        XCTAssertNil(r.laneInfo(v2)); XCTAssertNil(r.clip(bv))
        XCTAssertEqual(r.clip(ba)?.lane, a2); XCTAssertNil(r.clip(ba)?.link)        // 남은 소리: 같은 위치, 연결 없음
        XCTAssertEqual(rows(r, a2), [[10, 0, 60]])
        XCTAssertNotNil(r.partner(of: r.clips[0].id))                               // 다른 쌍은 그대로
        XCTAssertEqual(r.durationFrames, 100); XCTAssertTrue(r.isValid)
        h.undo(); XCTAssertEqual(h.timeline, t)
    }

    /// 보이는 영상: 각 시각에 클립이 있는 가장 위 영상 레인. 순서를 바꾸면 결과가 바뀐다.
    func testVisibleSegmentsTopLaneWins() throws {
        let top = Lane(id: UUID(), kind: .video, name: "위")
        let lanes = [top, Lane.defaults[0], Lane.defaults[1]]
        let t = Timeline(clips: [Clip(mediaID: ma, start: 0, sourceIn: 0, length: 100, lane: Lane.videoID),
                                 Clip(mediaID: mb, start: 30, sourceIn: 10, length: 40, lane: top.id),
                                 Clip(mediaID: mb, start: 110, sourceIn: 0, length: 20, lane: top.id)],
                         lanes: lanes, media: base().media, mediaFrames: base().mediaFrames, durationFrames: 140)
        XCTAssertTrue(t.isValid)
        func seg(_ t: Timeline) -> [[String]] { t.visibleVideoSegments().map { [$0.mediaID == ma ? "A" : "B", "\($0.start)", "\($0.sourceIn)", "\($0.length)"] } }
        // 손 계산: A 0–29, B(원본 10–49) 30–69, A(원본 70–99) 70–99, 검정 100–109, B 110–129, 검정 130–139
        XCTAssertEqual(seg(t), [["A", "0", "0", "30"], ["B", "30", "10", "40"], ["A", "70", "70", "30"], ["B", "110", "0", "20"]])
        let swapped = try t.movingLane(top.id, by: 1)
        XCTAssertEqual(seg(swapped), [["A", "0", "0", "100"], ["B", "110", "0", "20"]])
        XCTAssertEqual(t.source(atFrame: 35)?.frame, 15); XCTAssertEqual(swapped.source(atFrame: 35)?.frame, 35)
        XCTAssertNil(t.source(atFrame: 105))
    }

    /// 형식 1 파일(A-013에서 저장한 모양을 손으로 씀)을 읽으면 아무것도 잃지 않고, 다시 저장하면 형식 2로 같은 내용이다.
    func testReadsVersion1AndRoundTripsVersion2() throws {
        let pid = UUID(), link = UUID(), v1 = UUID(), a1 = UUID(), a2 = UUID()
        let json = """
        {"format":"dev.ontheframe.project","version":1,"projectID":"\(pid)","settings":{"width":1920,"height":1080,"fps":30},"durationFrames":130,
         "lanes":[{"id":"\(Lane.videoID)","kind":"video","name":"인터뷰"},{"id":"\(Lane.audioID)","kind":"audio","name":"현장음"}],
         "media":[{"ref":{"id":"\(ma)","name":"a.mp4","path":"/media/a.mp4","frameCount":100,"hasAudio":true,"size":1,"modifiedNs":2,"codec":"avc1","width":1920,"height":1080},
                   "relativePath":"../a.mp4","bookmark":"AQID"}],
         "videoClips":[{"id":"\(v1)","mediaID":"\(ma)","start":0,"sourceIn":0,"length":100,"link":"\(link)"}],
         "audioClips":[{"id":"\(a1)","mediaID":"\(ma)","start":0,"sourceIn":0,"length":100,"link":"\(link)"},
                       {"id":"\(a2)","mediaID":"\(ma)","start":110,"sourceIn":10,"length":20}]}
        """
        let (t, doc) = try ProjectFile.decode(Data(json.utf8))
        XCTAssertEqual(doc.version, 1)
        XCTAssertEqual(t.lanes.map(\.name), ["인터뷰", "현장음"]); XCTAssertEqual(t.lanes.map(\.id), [Lane.videoID, Lane.audioID])
        XCTAssertEqual(t.lanes.map(\.volumePercent), [100, 100]); XCTAssertEqual(t.lanes.map(\.muted), [false, false])
        XCTAssertEqual(t.clips.map(\.lane), [Lane.videoID]); XCTAssertEqual(t.audioClips.map(\.lane), [Lane.audioID, Lane.audioID])
        XCTAssertEqual(t.clips.map { [$0.start, $0.sourceIn, $0.length] }, [[0, 0, 100]])
        XCTAssertEqual(t.audioClips.map { [$0.start, $0.sourceIn, $0.length] }, [[0, 0, 100], [110, 10, 20]])
        XCTAssertEqual(t.partner(of: v1)?.id, a1); XCTAssertNil(t.clip(a2)?.link)
        XCTAssertEqual(t.durationFrames, 130); XCTAssertEqual(t.media.first?.hasVideo, true); XCTAssertEqual(doc.media.first?.bookmark, Data([1, 2, 3]))
        XCTAssertEqual(t.audioGaps, [100..<110])
        // 다시 저장 → 형식 2 → 같은 타임라인
        let again = try ProjectFile.encode(t, projectID: pid, settings: .m1, bookmarks: [ma: Data([1, 2, 3])], projectURL: nil)
        let (back, doc2) = try ProjectFile.decode(again)
        XCTAssertEqual(doc2.version, ProjectFile.currentVersion); XCTAssertEqual(back, t)
    }

    func testVersion2RoundTripWithLanesAudioMediaAndValidation() throws {
        let v2 = UUID(), a2 = UUID(), a3 = UUID()
        var t = try base().addingLane(.video, name: "자막 배경", id: v2).movingLane(v2, by: -1)
            .addingLane(.audio, name: "음악", id: a2).addingLane(.audio, name: "효과", id: a3)
        t = try t.inserting(media: ma).placing(media: mb, at: 30, videoLane: Lane.videoID, audioLane: a3)   // 삽입은 첫(가장 위) 영상 레인 v2로
            .placing(media: mw, at: 15, videoLane: nil, audioLane: a2)
            .settingLaneAudio(a2, volumePercent: 40).settingLaneAudio(a3, muted: true)
        let data = try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        let (back, doc) = try ProjectFile.decode(data)
        XCTAssertEqual(back, t); XCTAssertEqual(doc.version, ProjectFile.currentVersion)
        XCTAssertEqual(back.lanes.map(\.id), [v2, Lane.videoID, Lane.audioID, a2, a3])
        XCTAssertEqual(back.laneInfo(a2)?.volumePercent, 40); XCTAssertEqual(back.laneInfo(a3)?.muted, true)
        let w = try XCTUnwrap(back.media.first { $0.id == mw })
        XCTAssertEqual([w.hasVideo ? 1 : 0, w.sampleRate ?? 0, Int(w.sampleCount ?? 0), w.channels ?? 0], [0, 48_000, 96_000, 2])
        // 잘못된 형식 2: 음량 범위 밖, 영상 레인을 가리키는 소리 클립, 영상 없는 미디어를 쓰는 영상 클립
        func mutate(_ f: (inout [String: Any]) -> Void) throws -> Data {
            var o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); f(&o)
            return try JSONSerialization.data(withJSONObject: o)
        }
        let loud = try mutate { o in var ls = o["lanes"] as! [[String: Any]]; ls[3]["volumePercent"] = 150; o["lanes"] = ls }
        XCTAssertThrowsError(try ProjectFile.decode(loud))
        let wrongLane = try mutate { o in var cs = o["audioClips"] as! [[String: Any]]; cs[0]["lane"] = v2.uuidString; o["audioClips"] = cs }
        XCTAssertThrowsError(try ProjectFile.decode(wrongLane))
        let videoFromAudio = try mutate { o in var cs = o["videoClips"] as! [[String: Any]]; cs[0]["mediaID"] = self.mw.uuidString; cs[0]["length"] = 10; o["videoClips"] = cs }
        XCTAssertThrowsError(try ProjectFile.decode(videoFromAudio))
        let noVideoLane = try mutate { o in var ls = o["lanes"] as! [[String: Any]]; ls.removeAll { $0["kind"] as? String == "video" }; o["lanes"] = ls
            o["videoClips"] = [[String: Any]]() }
        XCTAssertThrowsError(try ProjectFile.decode(noVideoLane))
        // 대조: 손대지 않은 JSON 다시 직렬화는 읽힌다(위 실패가 직렬화 탓이 아님)
        XCTAssertNoThrow(try ProjectFile.decode(try mutate { _ in }))
    }
}

/// 여러 레인 내보내기·프리뷰(A-014): 영상 레인 겹침(가장 위 레인), 소리 파일(WAV·AIFF·AAC·ALAC)의 표본 단위 위치, 레인 음소거·음량.
/// 기대값: 영상은 fixture 화면 코드(ExportJudge, 손으로 쓴 배치), 소리는 fixture를 쓸 때 정한 클릭 표본 위치·음높이·진폭에서 계산.
final class MultiLaneExportTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var out: URL!
    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        out = ExportEndToEndTests.root.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: out) }

    func testAudioFileProbe() async throws {
        for fx in AudioFixture.all {
            let a = try await MediaProbe.inspect(fixtures.appendingPathComponent(fx.file))
            XCTAssertFalse(a.hasVideo, fx.file); XCTAssertTrue(a.hasAudio, fx.file)
            XCTAssertEqual(a.codec, fx.expectedCodec, fx.file)
            XCTAssertEqual(a.audioSampleRate, fx.sampleRate, fx.file); XCTAssertEqual(a.audioChannels, fx.channels, fx.file)
            XCTAssertEqual(a.audioSampleCount, Int64(fx.lengthSamples), fx.file)
            XCTAssertEqual(a.frameCount, fx.expectedFrames, fx.file)
            let r = MediaRef(a); XCTAssertFalse(r.hasVideo); XCTAssertEqual(r.sampleCount, Int64(fx.lengthSamples))
        }
        // 손 계산: 66000/44100 s = 1.4966 s → 44.9 → 45프레임, 96000/48000 = 2 s → 60, 76800/48000 = 1.6 s → 48, 44100/44100 → 30
        XCTAssertEqual(AudioFixture.all.map(\.expectedFrames), [60, 45, 48, 30])
        await XCTAssertThrowsErrorAsync(try await MediaProbe.inspect(fixtures.appendingPathComponent("reject-4ch.wav")))
    }

    /// 영상 레인 2개: 위 레인 TB(원본 10–49) @30–69, 아래 레인 TA @0–99, 100–119는 두 레인 모두 비어 검정.
    /// 편집 API(놓기·자르기·일반 삭제·레인 순서)로 만든다. 음성 대조: 아래 레인만 보인다는 기대는 실패, 레인 순서를 바꾸면 그 기대가 통과.
    func testLayeredVideoExportAndPreview() async throws {
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        let tb = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TB.mp4"))
        var t = Timeline().registering(ta).registering(tb)
        t = try t.inserting(media: ta.id)                                                     // V1/A1 [0,120)
        let top = UUID(), a2 = UUID()
        t = try t.addingLane(.video, name: "위", id: top).movingLane(top, by: -1).addingLane(.audio, name: "B 소리", id: a2)
        t = try t.placing(media: tb.id, at: 20, videoLane: top, audioLane: a2)               // 위 [20,110) 원본 0
        let (l1, mid) = (UUID(), UUID())
        t = try t.splitting(clip: t.clips(inLane: top)[0].id, atFrame: 30, newIDs: (l1, mid)).lifting(clip: l1)
        let (keep, tail) = (UUID(), UUID())
        t = try t.splitting(clip: mid, atFrame: 70, newIDs: (keep, tail)).lifting(clip: tail)  // 위 [30,70) 원본 10
        XCTAssertThrowsError(try t.rippleDeleting(clip: keep))                                // 아래 레인 TA가 걸침
        let (taL, taR) = (UUID(), UUID())
        t = try t.splitting(clip: t.clips(inLane: Lane.videoID)[0].id, atFrame: 100, newIDs: (taL, taR)).lifting(clip: taR)
        t = try t.settingLaneAudio(a2, muted: true)
        XCTAssertEqual(t.durationFrames, 120); XCTAssertTrue(t.isValid)

        let layered: [ExportJudge.ClipRef] = [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 30), .init(file: "otf-TB.mp4", start: 30, sourceIn: 10, length: 40),
                                              .init(file: "otf-TA.mp4", start: 70, sourceIn: 70, length: 30)]
        let lowerOnly: [ExportJudge.ClipRef] = [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 100)]
        let audio: [ExportJudge.ClipRef] = [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 100)]
        let media = [ta.id: ta, tb.id: tb]
        let plan = try await CompositionPlanner.plan(t, media: media)
        XCTAssertNotNil(plan.audioMix)   // 소리가 있으면 늘 믹스(내보내기는 섞인 소리 트랙 하나, 2026-10-11)
        let dest = out.appendingPathComponent("layered.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [ta, tb]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let v = try await ExportJudge.judge(dest, clips: layered, audioClips: audio, durationFrames: 120, toneCheck: true)
        XCTAssertTrue(v.pass, "\(v)")
        XCTAssertEqual(v.gapFrames, 20)
        let wrong = try await ExportJudge.judge(dest, clips: lowerOnly, audioClips: audio, durationFrames: 120, toneCheck: true)
        XCTAssertFalse(wrong.pass)
        // 프리뷰(같은 composition) 경계 프레임
        let (expected, _) = try ExportJudge.expectations(layered, durationFrames: 120)
        let probe = [0, 29, 30, 69, 70, 99, 100, 119]
        let preview = try await PreviewProbe.frames(plan, at: probe)
        let exportPixels = try await FrameCompare.decode(dest, frames: Set(probe))
        let cmp = PreviewExportCompare.check(preview: preview, export: exportPixels, expected: expected, probes: probe)
        XCTAssertTrue(cmp.failures.isEmpty, cmp.failures.joined(separator: "; "))

        // 레인 순서 바꾸기: TA가 위 → TB는 가려진다
        let swapped = try t.movingLane(top, by: 1)
        let plan2 = try await CompositionPlanner.plan(swapped, media: media)
        let dest2 = out.appendingPathComponent("swapped.mp4")
        let outcome2 = await ExportService.export(plan2, to: .fromSavePanel(dest2), sources: [ta, tb]) { _ in }
        XCTAssertEqual(outcome2, .completed(dest2))
        let v2 = try await ExportJudge.judge(dest2, clips: lowerOnly, audioClips: audio, durationFrames: 120, toneCheck: true)
        XCTAssertTrue(v2.pass, "\(v2)")
        let wrong2 = try await ExportJudge.judge(dest2, clips: layered, audioClips: audio, durationFrames: 120, toneCheck: true)
        XCTAssertFalse(wrong2.pass)
    }

    /// 오디오 레인 4개 + 영상 레인 1개(TA 영상만):
    /// A1: WAV(48k 스테레오) @10 원본 0 길이 60. A2: AIFF(44.1k 모노) @40 원본 3 길이 42. A3(음소거): AAC @0 길이 48. A4(음량 50%): ALAC @70 길이 30.
    func testAudioLanesMixMuteVolumeExportAndPreview() async throws {
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        var assets: [String: MediaAsset] = [:]
        for fx in AudioFixture.all { assets[fx.file] = try await MediaProbe.inspect(fixtures.appendingPathComponent(fx.file)) }
        let w = assets[AudioFixture.wav.file]!, f = assets[AudioFixture.aiff.file]!, c = assets[AudioFixture.aac.file]!, l = assets[AudioFixture.alac.file]!
        let a2 = UUID(), a3 = UUID(), a4 = UUID()
        var t = Timeline(clips: [Clip(mediaID: ta.id, start: 0, sourceIn: 0, length: 120)],
                         audioClips: [Clip(mediaID: f.id, start: 40, sourceIn: 3, length: 42, lane: a2), Clip(mediaID: c.id, start: 0, sourceIn: 0, length: 48, lane: a3),
                                      Clip(mediaID: l.id, start: 70, sourceIn: 0, length: 30, lane: a4)],
                         lanes: Lane.defaults + [Lane(id: a2, kind: .audio, name: "A2"), Lane(id: a3, kind: .audio, name: "A3", muted: true),
                                                 Lane(id: a4, kind: .audio, name: "A4", volumePercent: 50)])
        for a in [ta, w, f, c, l] { t = t.registering(a) }
        t = try t.placing(media: w.id, at: 10, videoLane: nil, audioLane: Lane.audioID)
        XCTAssertTrue(t.isValid); XCTAssertEqual(t.durationFrames, 120)
        let media = Dictionary(uniqueKeysWithValues: [ta, w, f, c, l].map { ($0.id, $0) })
        let plan = try await CompositionPlanner.plan(t, media: media)
        XCTAssertNotNil(plan.audioMix)
        let dest = out.appendingPathComponent("mix.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [ta, w, f, c, l]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let d = try await E2Decoder.decode(dest)
        XCTAssertEqual(d.frames.count, 120)

        // 클릭 위치(48 kHz 표본): 원본 시각 = 클릭 표본/표본율(프레임 반올림 없음). 손 계산:
        // W 12345 → 10/30 s + 12345/48000 s = 16000 + 12345 = 28345, W 60000 → 76000,
        // F 33333/44100 s = 0.755850 s, 원본 시작 3/30 = 0.1 s → 40/30 + 0.655850 = 1.989184 s → 95481. 음소거한 C 20000은 없어야 한다.
        let expected = AudioFixture.wav.expectedOnsets48k(start: 10, sourceIn: 0, length: 60) + AudioFixture.aiff.expectedOnsets48k(start: 40, sourceIn: 3, length: 42)
        XCTAssertEqual(expected, [28_345, 76_000, 95_481])
        let measured = E2Decoder.onsets(d.mono)
        XCTAssertEqual(measured.count, 3, "onsets \(measured)")
        // AAC 내보내기: ±16표본(1/3 ms). 이전 판정의 ±96보다 좁혀, 빈 편집·표본율 섞임 때 관찰한 −17~−79표본 앞당김을 잡는다.
        XCTAssertTrue(zip(measured, expected).allSatisfy { abs($0 - $1) <= 16 }, "export onsets \(measured) vs \(expected)")
        print("mix export onset errors: \(zip(measured, expected).map { $0 - $1 })")
        // 음성 대조: 프레임으로 반올림한 위치(F 클릭을 원본 프레임 22로)는 측정값과 멀다
        let frameRounded = (40 - 3 + 33_333 * 30 / 44_100) * 1_600
        XCTAssertEqual(frameRounded, 94_400)
        XCTAssertFalse(measured.contains { abs($0 - frameRounded) <= 96 })

        // 음높이별 진폭(사인 진폭 단위, fixture 0.2)
        let spf = 1_600
        func amp(_ x: [Float], _ hz: Double, _ f0: Int, _ f1: Int) -> Double { Self.toneAmplitude(x, hz: hz, from: f0 * spf, to: f1 * spf) }
        let wAmp = amp(d.mono, 440, 15, 65), fAmp = amp(d.mono, 1_000, 45, 80), cAmp = amp(d.mono, 2_500, 5, 40), lAmp = amp(d.mono, 700, 75, 95)
        print(String(format: "mix export: W440 %.4f F1000 %.4f C2500(muted) %.4f L700(50%%) %.4f, onsets %@", wAmp, fAmp, cAmp, lAmp, "\(measured)"))
        XCTAssertEqual(wAmp, 0.2, accuracy: 0.03)
        XCTAssertGreaterThan(fAmp, 0.08)
        XCTAssertLessThan(cAmp, 0.01)
        XCTAssertEqual(lAmp, 0.1, accuracy: 0.02)

        // 프리뷰 경로(같은 composition + 오디오 믹스): 같은 클릭 위치, 같은 음소거·음량
        let pm = try await LaneExportTests.compositionMono(plan)
        let pOnsets = E2Decoder.onsets(pm)
        // composition(무손실 읽기)은 표본 단위: ±4표본(빈 편집을 쓰던 때는 44.1 kHz 원본이 −79표본 앞당겨졌다 — CompositionPlanner 무음 채우기 참고)
        XCTAssertEqual(pOnsets.count, 3); XCTAssertTrue(zip(pOnsets, expected).allSatisfy { abs($0 - $1) <= 4 }, "composition onsets \(pOnsets)")
        print("mix composition onset errors: \(zip(pOnsets, expected).map { $0 - $1 })")
        // (이 읽기 도구는 스테레오를 모노 1채널로 섞을 때 L+R에 0.707을 곱해 스테레오 원본 진폭이 √2배로 읽힌다. 그래서 절대값이 아닌 비율로 본다.)
        let pL = amp(pm, 700, 75, 95), pC = amp(pm, 2_500, 5, 40)
        XCTAssertLessThan(pC, 0.005)
        // 대조: 음소거를 풀고 음량을 100%로 하면 C가 들리고 L이 두 배
        let loud = try t.settingLaneAudio(a3, muted: false).settingLaneAudio(a4, volumePercent: 100)
        let planLoud = try await CompositionPlanner.plan(loud, media: media)
        XCTAssertNotNil(planLoud.audioMix)   // 모두 100%여도 믹스를 붙인다(2026-10-11)
        let lm = try await LaneExportTests.compositionMono(planLoud)
        let lC = amp(lm, 2_500, 5, 40), lL = amp(lm, 700, 75, 95)
        XCTAssertGreaterThan(lC, 0.15)
        XCTAssertEqual(pL / lL, 0.5, accuracy: 0.02)
        XCTAssertEqual(lAmp / (lL / 2.0.squareRoot()), 0.5, accuracy: 0.05)            // 내보내기 50% ÷ 프리뷰 100%(같은 단위로 환산)
        print(String(format: "mix composition: L700 50%% %.4f / 100%% %.4f, C2500 muted %.5f / unmuted %.4f", pL, lL, pC, lC))

        // 앱 자체 검사가 쓰는 독립 판정(MultiLaneJudge)도 같은 내보내기를 통과시키고, 틀린 레인 설정은 실패시킨다(판정 도구의 음성 대조)
        typealias J = MultiLaneJudge
        func lane(_ kind: String, _ name: String, muted: Bool = false, vol: Int = 100, _ clips: [J.LaneClip]) -> J.LaneRef {
            J.LaneRef(kind: kind, name: name, muted: muted, volumePercent: vol, clips: clips)
        }
        let right = J.Manifest(exportFile: "mix.mp4", durationFrames: 120, lanes: [
            lane("video", "V", [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 120)]),
            lane("audio", "A1", [.init(file: AudioFixture.wav.file, start: 10, sourceIn: 0, length: 60)]),
            lane("audio", "A2", [.init(file: AudioFixture.aiff.file, start: 40, sourceIn: 3, length: 42)]),
            lane("audio", "A3", muted: true, [.init(file: AudioFixture.aac.file, start: 0, sourceIn: 0, length: 48)]),
            lane("audio", "A4", vol: 50, [.init(file: AudioFixture.alac.file, start: 70, sourceIn: 0, length: 30)])])
        let ok = try await J.judge(dest, right)
        XCTAssertTrue(ok.pass, "\(ok.tones) \(ok.measuredOnsets)")
        var lanes = right.lanes; lanes[4] = lane("audio", "A4", [.init(file: AudioFixture.alac.file, start: 70, sourceIn: 0, length: 30)])   // 음량 100%라고 주장
        do { let r = try await J.judge(dest, J.Manifest(exportFile: "", durationFrames: 120, lanes: lanes)); XCTAssertFalse(r.pass) }
        lanes = right.lanes; lanes[3] = lane("audio", "A3", [.init(file: AudioFixture.aac.file, start: 0, sourceIn: 0, length: 48)])      // 음소거 안 했다고 주장
        do { let r = try await J.judge(dest, J.Manifest(exportFile: "", durationFrames: 120, lanes: lanes)); XCTAssertFalse(r.pass) }
        lanes = right.lanes; lanes.insert(lane("video", "Top", [.init(file: "otf-TB.mp4", start: 30, sourceIn: 0, length: 40)]), at: 0)  // 위 레인이 있다고 주장
        do { let r = try await J.judge(dest, J.Manifest(exportFile: "", durationFrames: 120, lanes: lanes)); XCTAssertFalse(r.pass) }
    }

    /// 사인 진폭 추정: 구간 [from, to) 표본과 cos·sin의 상관(창 없음, 구간이 수십 주기라 누설이 작다)
    static func toneAmplitude(_ x: [Float], hz: Double, from: Int, to: Int) -> Double {
        let lo = max(0, from), hi = min(x.count, to)
        guard hi > lo else { return 0 }
        var i = 0.0, q = 0.0
        for n in lo..<hi {
            let ph = 2 * Double.pi * hz * Double(n) / 48_000
            i += Double(x[n]) * cos(ph); q += Double(x[n]) * sin(ph)
        }
        return 2 * (i * i + q * q).squareRoot() / Double(hi - lo)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ e: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await e(); XCTFail("no error", file: file, line: line) } catch {}
}
