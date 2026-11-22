import Foundation
@testable import OnTheFrameEngine
import XCTest

/// ON-THE-FRAME-DEFAULT-LANES-01: 새 프로젝트의 빈 영상 레인 둘(V1 위)과 빈 오디오 레인 둘(A1 아래).
/// 새 레인은 보통 레인이어야 하고(놓기·옮기기·삭제·실행 취소·저장), 기존 파일·사용자가 만든 빈 레인은 그대로여야 한다.
/// 기대값은 손으로 쓴 숫자·ID다.
final class DefaultLanesTests: XCTestCase {
    let ma = UUID(), mc = UUID(), mw = UUID()
    let v3 = Lane.videoV3ID, v2 = Lane.videoV2ID, v1 = Lane.videoID, a1 = Lane.audioID, a2 = Lane.audioA2ID, a3 = Lane.audioA3ID

    func ref(_ id: UUID, _ name: String, frames: Int, audio: Bool = true, video: Bool = true) -> MediaRef {
        MediaRef(id: id, name: name, path: "/media/\(name)", frameCount: frames, hasAudio: audio, size: 1, modifiedNs: 2, codec: video ? "avc1" : "lpcm",
                 width: video ? 1920 : 0, height: video ? 1080 : 0, hasVideo: video, sampleRate: video ? nil : 48_000, sampleCount: video ? nil : 96_000,
                 channels: video ? nil : 2)
    }
    /// 새 프로젝트 레인에 미디어 A(100프레임, 소리 있음), C(30, 소리 없음), W(소리 파일 60)를 등록한 상태(가져오기와 같은 모양)
    func project(lanes: [Lane] = Lane.newProjectDefaults) -> Timeline {
        let refs = [ref(ma, "a.mp4", frames: 100), ref(mc, "c.mp4", frames: 30, audio: false), ref(mw, "w.wav", frames: 60, video: false)]
        return Timeline(lanes: lanes, media: refs, mediaFrames: [ma: 100, mc: 30, mw: 60], mediaHasAudio: [ma: true, mc: false, mw: true])
    }
    func rows(_ t: Timeline, _ lane: UUID) -> [[Int]] { t.clips(inLane: lane).map { [$0.start, $0.sourceIn, $0.length] } }
    func labels(_ t: Timeline) -> [String] { t.lanes.map { t.laneLabel($0.id) } }
    func roundTrip(_ t: Timeline) throws -> (Timeline, ProjectFile.Document) {
        try ProjectFile.decode(ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil))
    }

    // MARK: 새 프로젝트 기본값

    func testNewProjectHasFourUsableEmptyLanesAroundTheOriginalPair() {
        let t = Timeline.newProject()
        XCTAssertEqual(t.lanes.map(\.id), [v3, v2, v1, a1, a2, a3])
        XCTAssertEqual(t.lanes.map(\.kind), [.video, .video, .video, .audio, .audio, .audio])
        XCTAssertEqual(t.lanes.map(\.name), ["영상", "영상", "원본소스", "원본소리", "오디오", "오디오"])
        XCTAssertEqual(labels(t), ["V3", "V2", "V1", "A1", "A2", "A3"])
        XCTAssertEqual(Set(t.lanes.map(\.id)).count, 6)
        XCTAssertTrue(t.lanes.allSatisfy { !$0.muted && $0.volumePercent == 100 })
        // 기존 기본 레인(V1·A1)이 경계 쪽 기본 레인으로 남는다(+ 단추·레인 없는 클립의 대상이 바뀌지 않음)
        XCTAssertEqual(t.baseLane(.video)?.id, v1); XCTAssertEqual(t.baseLane(.audio)?.id, a1)
        XCTAssertEqual(t.pairedLane(of: v2)?.id, a2); XCTAssertEqual(t.pairedLane(of: v3)?.id, a3)
        XCTAssertTrue(t.isValid); XCTAssertTrue(t.isEmpty); XCTAssertEqual(t.durationFrames, 0)
        for l in [v3, v2, a2, a3] { XCTAssertTrue(t.clips(inLane: l).isEmpty); XCTAssertEqual(t.occupiedEnd(lane: l), 0) }
        // 같은 시작 상태(고정 ID): 새 프로젝트를 두 번 만들어도 같다(저장하지 않은 변경으로 보이지 않음)
        XCTAssertEqual(Timeline.newProject(), Timeline.newProject())
    }

    func testEngineDefaultTimelineIsUnchanged() {
        // 이전 기본값(엔진 Timeline()·Lane.defaults)은 그대로 두 레인이다(이전 검사·형식 1 읽기 호환)
        XCTAssertEqual(Timeline().lanes, Lane.defaults)
        XCTAssertEqual(Lane.defaults.map(\.id), [v1, a1])
        XCTAssertEqual(Lane.defaults.map(\.name), ["원본소스", "원본소리"])
        XCTAssertEqual(Array(Lane.newProjectDefaults[2...3]), Lane.defaults)
    }

    // MARK: 미디어 넣기

    func testPlacingAndAppendingMediaIntoDefaultLanes() throws {
        let vid = UUID(), aud = UUID(), still = UUID(), wav = UUID()
        var t = try project().placing(media: ma, at: 10, videoLane: v2, audioLane: a2, clipID: vid, audioClipID: aud)
        XCTAssertEqual(rows(t, v2), [[10, 0, 100]]); XCTAssertEqual(rows(t, a2), [[10, 0, 100]])
        XCTAssertEqual(t.partner(of: vid)?.id, aud)
        t = try t.placing(media: mc, at: 0, videoLane: v3, audioLane: nil, clipID: still)   // 소리 없는 영상: 영상 레인만
        XCTAssertEqual(rows(t, v3), [[0, 0, 30]]); XCTAssertNil(t.partner(of: still))
        t = try t.placing(media: mw, at: 5, videoLane: nil, audioLane: a3, clipID: wav)       // 소리 파일
        XCTAssertEqual(rows(t, a3), [[5, 0, 60]])
        XCTAssertTrue(rows(t, v1).isEmpty); XCTAssertTrue(rows(t, a1).isEmpty)
        XCTAssertEqual(t.durationFrames, 110); XCTAssertTrue(t.isValid)
        XCTAssertEqual(t.lanes.map(\.id), [v3, v2, v1, a1, a2, a3])   // 레인을 더하거나 빼지 않는다
        // 겹치면 거부(다른 레인과 같은 규칙)
        XCTAssertThrowsError(try t.placing(media: mc, at: 20, videoLane: v2, audioLane: nil)) { XCTAssertEqual($0 as? EditError, .overlap) }
        // 잘못된 종류의 레인
        XCTAssertThrowsError(try t.placing(media: mw, at: 200, videoLane: nil, audioLane: v3)) { XCTAssertEqual($0 as? EditError, .laneKindMismatch) }
        // + 단추와 같은 추가: 고른 기본 레인 쌍의 끝 뒤
        let next = try t.appending(media: ma, videoLane: v2, audioLane: a2, clipID: UUID())
        XCTAssertEqual(rows(next, v2), [[10, 0, 100], [110, 0, 100]]); XCTAssertEqual(rows(next, a2), [[10, 0, 100], [110, 0, 100]])
        // 레인을 고르지 않은 추가는 이전처럼 V1·A1에(기본 레인 = baseLane)
        let base = try project().appending(media: ma, videoLane: project().baseLane(.video)?.id, audioLane: project().baseLane(.audio)?.id)
        XCTAssertEqual(rows(base, v1), [[0, 0, 100]]); XCTAssertEqual(rows(base, a1), [[0, 0, 100]])
        XCTAssertTrue(rows(base, v2).isEmpty && rows(base, v3).isEmpty && rows(base, a2).isEmpty && rows(base, a3).isEmpty)
    }

    // MARK: 옮기기·삭제·실행 취소

    func testMovingDeletingAndUndoRedoInDefaultLanes() throws {
        let vid = UUID(), aud = UUID(), other = UUID()
        var h = EditHistory(project())
        let start = h.timeline
        h.apply(try h.timeline.placing(media: ma, at: 0, videoLane: v1, audioLane: a1, clipID: vid, audioClipID: aud), focus: vid)
        h.apply(try h.timeline.placing(media: mc, at: 120, videoLane: v1, audioLane: nil, clipID: other), focus: other)
        // V1·A1의 연결된 쌍을 V3·A3으로 옮기고 위치도 바꾼다(한 단계, 다른 클립은 그대로)
        h.apply(try h.timeline.relocating(clip: vid, toStart: 40, lane: v3, partnerLane: a3), focus: vid)
        XCTAssertEqual(rows(h.timeline, v3), [[40, 0, 100]]); XCTAssertEqual(rows(h.timeline, a3), [[40, 0, 100]])
        XCTAssertEqual(rows(h.timeline, v1), [[120, 0, 30]]); XCTAssertTrue(rows(h.timeline, a1).isEmpty)
        XCTAssertEqual(h.timeline.partner(of: vid)?.id, aud)
        XCTAssertEqual(h.timeline.clip(vid)?.lane, v3); XCTAssertEqual(h.timeline.clip(aud)?.lane, a3)
        // 같은 쌍을 V2·A2로(빈 기본 레인 사이 옮기기)
        h.apply(try h.timeline.relocating(clip: aud, lane: a2, partnerLane: v2), focus: aud)
        XCTAssertEqual(rows(h.timeline, v2), [[40, 0, 100]]); XCTAssertEqual(rows(h.timeline, a2), [[40, 0, 100]])
        XCTAssertTrue(rows(h.timeline, v3).isEmpty && rows(h.timeline, a3).isEmpty)
        let moved = h.timeline
        // 일반 삭제(빈틈 남김): 쌍이 함께 지워지고 레인 여섯은 그대로, 길이도 그대로
        h.apply(try h.timeline.lifting(clip: vid), focus: nil)
        XCTAssertNil(h.timeline.clip(vid)); XCTAssertNil(h.timeline.clip(aud))
        XCTAssertEqual(h.timeline.lanes.map(\.id), [v3, v2, v1, a1, a2, a3])
        XCTAssertEqual(h.timeline.durationFrames, moved.durationFrames)
        let deleted = h.timeline
        XCTAssertEqual(h.undoDepth, 5)
        h.undo(); XCTAssertEqual(h.timeline, moved)
        for _ in 0..<4 { h.undo() }
        XCTAssertEqual(h.timeline, start); XCTAssertFalse(h.canUndo)
        for _ in 0..<5 { h.redo() }
        XCTAssertEqual(h.timeline, deleted)
        // 레인 번호는 위치에서 나오며 편집으로 바뀌지 않는다
        XCTAssertEqual(labels(h.timeline), ["V3", "V2", "V1", "A1", "A2", "A3"])
    }

    func testOverwritePasteAndSnappingWithDefaultLanes() throws {
        let vid = UUID(), aud = UUID(), still = UUID()
        let t = try project().placing(media: ma, at: 0, videoLane: v2, audioLane: a2, clipID: vid, audioClipID: aud)
            .placing(media: mc, at: 0, videoLane: v3, audioLane: nil, clipID: still)
        // 덮어쓰기 붙여넣기: 원래 레인(V2·A2)에 붙고 새 레인을 만들지 않는다
        let r = try t.pastingOverwrite(t.copying(clip: vid), at: 50, newLaneName: { _ in "x" })
        XCTAssertTrue(r.createdLanes.isEmpty)
        XCTAssertEqual(r.timeline.lanes.map(\.id), [v3, v2, v1, a1, a2, a3])
        XCTAssertEqual(rows(r.timeline, v2), [[0, 0, 50], [50, 0, 100]]); XCTAssertEqual(rows(r.timeline, a2), [[0, 0, 50], [50, 0, 100]])
        XCTAssertTrue(r.timeline.isValid)
        // 붙음: 빈 레인은 붙을 곳을 더하지 않는다. 같은 클립 배치를 빈 레인 없는 세 레인 타임라인에 두어도 결과가 같다.
        let compact = [Lane(id: v3, kind: .video, name: "영상"), Lane(id: v1, kind: .video, name: "원본소스"), Lane(id: a1, kind: .audio, name: "원본소리")]
        let noEmpty = try project(lanes: compact).placing(media: ma, at: 0, videoLane: v1, audioLane: a1, clipID: vid, audioClipID: aud)
            .placing(media: mc, at: 0, videoLane: v3, audioLane: nil, clipID: still)
        for raw in [27.6, 31.2, -3.0, 99.0] {
            let a = t.snappedDelta(clip: still, delta: raw, threshold: 4), b = noEmpty.snappedDelta(clip: still, delta: raw, threshold: 4)
            XCTAssertEqual(a.delta, b.delta, "raw \(raw)"); XCTAssertEqual(a.snap, b.snap, "raw \(raw)")
        }
        XCTAssertEqual(t.snappedDelta(clip: still, delta: 68.5, threshold: 4).snap, 100)   // 끝(30) + 68.5 → 다른 레인 클립 끝 100에 붙음
    }

    func testWaveformSourceRangeDoesNotDependOnLane() throws {
        // 파형은 클립(원본·구간) 단위로 그린다. 기본 오디오 레인(A2·A3)의 클립도 A1과 같은 원본 범위를 쓴다.
        let onA1 = try project().placing(media: mw, at: 12, videoLane: nil, audioLane: a1, clipID: UUID()).audioClips[0]
        let onA3 = try project().placing(media: mw, at: 12, videoLane: nil, audioLane: a3, clipID: UUID()).audioClips[0]
        let r1 = WaveformPeaks.sourceSamples(clipStart: onA1.start, sourceIn: onA1.sourceIn, length: onA1.length, timeline: 0, 40, rate: 48_000)
        let r3 = WaveformPeaks.sourceSamples(clipStart: onA3.start, sourceIn: onA3.sourceIn, length: onA3.length, timeline: 0, 40, rate: 48_000)
        XCTAssertEqual(r1, 0..<44_800); XCTAssertEqual(r3, r1)
    }

    // MARK: 저장·다시 열기와 기존 파일

    func testNewProjectSaveReopenKeepsLanesWithoutFormatChange() throws {
        let (empty, doc0) = try roundTrip(Timeline.newProject())
        XCTAssertEqual(empty, Timeline.newProject())
        // 두 레인 프로젝트와 같은 형식 판(레인 수만 다르다 — 형식 2부터 허용된 모양)
        XCTAssertEqual(doc0.version, ProjectFile.version(for: Timeline()))
        XCTAssertEqual(doc0.version, ProjectFile.subtitleFreeVersion)
        let vid = UUID()
        let t = try project().placing(media: ma, at: 15, videoLane: v3, audioLane: a2, clipID: vid)
            .renamingLane(v2, to: "자막 배경").settingLaneAudio(a3, muted: true, volumePercent: 40)
        let (back, doc) = try roundTrip(t)
        XCTAssertEqual(back, t); XCTAssertEqual(doc.version, ProjectFile.subtitleFreeVersion)
        XCTAssertEqual(back.lanes.map(\.id), [v3, v2, v1, a1, a2, a3]); XCTAssertEqual(labels(back), ["V3", "V2", "V1", "A1", "A2", "A3"])
        XCTAssertEqual(back.laneInfo(v2)?.name, "자막 배경"); XCTAssertEqual(back.laneInfo(a3).map { [$0.muted ? 1 : 0, $0.volumePercent] }, [1, 40])
        XCTAssertEqual(back.clip(vid)?.lane, v3); XCTAssertEqual(back.partner(of: vid)?.lane, a2)
        XCTAssertTrue(back.clips(inLane: v1).isEmpty && back.clips(inLane: a3).isEmpty)   // 빈 레인도 그대로 돌아온다
    }

    /// DEFAULT-LANES-REVIEW-02: 저장 형식 판은 내용으로만 정해진다(레인 수와 무관). 빈 여섯 레인은 형식 5, 자막 레인이 있으면 6,
    /// 스펙트럼 레인이 있으면 8 — 같은 내용의 두 레인 타임라인과 늘 같은 판이고, 다시 읽으면 같은 타임라인이다(낮추거나 버리는 값 없음).
    func testSaveFormatFollowsContentNotLaneCount() throws {
        let sub = UUID(), spec = UUID()
        let six = Timeline.newProject(), two = Timeline()
        let sixSub = try six.addingLane(.subtitle, name: "자막", id: sub, outward: true)
        let twoSub = try two.addingLane(.subtitle, name: "자막", id: sub, outward: true)
        let sixSpec = try sixSub.addingLane(.spectrum, name: "스펙트럼", id: spec, outward: true)
        let twoSpec = try twoSub.addingLane(.spectrum, name: "스펙트럼", id: spec, outward: true)
        for (s, t, expected) in [(six, two, ProjectFile.subtitleFreeVersion), (sixSub, twoSub, ProjectFile.subtitleVersion), (sixSpec, twoSpec, ProjectFile.spectrumVersion)] {
            XCTAssertEqual(ProjectFile.version(for: s), expected); XCTAssertEqual(ProjectFile.version(for: s), ProjectFile.version(for: t))
            let (back, doc) = try roundTrip(s)
            XCTAssertEqual(doc.version, expected); XCTAssertEqual(back, s); XCTAssertEqual(back.lanes.map(\.id), s.lanes.map(\.id))
        }
        // 자막·스펙트럼 레인은 기본 빈 영상 레인 위에 놓이고(순서 자막 → 스펙트럼 → 영상 → 오디오) 영상 번호는 그대로다
        XCTAssertEqual(sixSpec.lanes.map(\.id), [sub, spec, v3, v2, v1, a1, a2, a3])
        XCTAssertEqual(labels(sixSpec), ["S1", "SP1", "V3", "V2", "V1", "A1", "A2", "A3"])
        XCTAssertTrue(sixSpec.isValid)
        // 새 바깥쪽 영상 레인은 자막·스펙트럼 아래, V3 위(새 V4)
        let v4 = UUID()
        let more = try sixSpec.addingLane(.video, name: "영상", id: v4, outward: true)
        XCTAssertEqual(more.lanes.map(\.id), [sub, spec, v4, v3, v2, v1, a1, a2, a3]); XCTAssertEqual(more.laneLabel(v4), "V4")
    }

    func testExistingProjectsOpenWithTheirSavedLanesOnly() throws {
        // 형식 1(두 레인) 파일: 읽어도 레인을 더하지 않고, 다시 저장해도 두 레인 그대로
        let pid = UUID(), link = UUID(), vc = UUID(), ac = UUID()
        let json = """
        {"format":"dev.ontheframe.project","version":1,"projectID":"\(pid)","settings":{"width":1920,"height":1080,"fps":30},"durationFrames":100,
         "lanes":[{"id":"\(v1)","kind":"video","name":"인터뷰"},{"id":"\(a1)","kind":"audio","name":"현장음"}],
         "media":[{"ref":{"id":"\(ma)","name":"a.mp4","path":"/media/a.mp4","frameCount":100,"hasAudio":true,"size":1,"modifiedNs":2,"codec":"avc1","width":1920,"height":1080}}],
         "videoClips":[{"id":"\(vc)","mediaID":"\(ma)","start":0,"sourceIn":0,"length":100,"link":"\(link)"}],
         "audioClips":[{"id":"\(ac)","mediaID":"\(ma)","start":0,"sourceIn":0,"length":100,"link":"\(link)"}]}
        """
        let (old, _) = try ProjectFile.decode(Data(json.utf8))
        XCTAssertEqual(old.lanes.map(\.id), [v1, a1]); XCTAssertEqual(old.lanes.map(\.name), ["인터뷰", "현장음"])
        let (again, _) = try roundTrip(old)
        XCTAssertEqual(again, old)
        // 사용자가 만든 배치(빈 레인 포함, 기본 ID와 다른 ID·순서): 그대로 읽고, 새 기본 레인 ID를 넣지 않는다
        let x1 = UUID(), x2 = UUID(), y1 = UUID()
        let custom = try Timeline(lanes: Lane.defaults).addingLane(.video, name: "빈 위", id: x1, outward: true)
            .addingLane(.video, name: "빈 아래", id: x2).movingLane(x2, by: -1)
            .addingLane(.audio, name: "빈 음악", id: y1, outward: true)
        let (reopened, _) = try roundTrip(custom)
        XCTAssertEqual(reopened, custom)
        XCTAssertEqual(reopened.lanes.map(\.id), custom.lanes.map(\.id))
        XCTAssertTrue(Set(reopened.lanes.map(\.id)).isDisjoint(with: [v2, v3, a2, a3]))
    }

    // MARK: 사용자가 만든 빈 레인 보존(정확한 개수를 강제하지 않음)

    func testManuallyCreatedEmptyLanesArePreservedAndNothingIsReplenished() throws {
        let extraV = UUID(), extraA = UUID(), vid = UUID()
        var h = EditHistory(project())
        h.apply(try h.timeline.addingLane(.video, name: "영상", id: extraV, outward: true), focus: nil)   // 새 V4(빈)
        h.apply(try h.timeline.addingLane(.audio, name: "오디오", id: extraA, outward: true), focus: nil) // 새 A4(빈)
        XCTAssertEqual(h.timeline.lanes.map(\.id), [extraV, v3, v2, v1, a1, a2, a3, extraA])
        XCTAssertEqual(labels(h.timeline), ["V4", "V3", "V2", "V1", "A1", "A2", "A3", "A4"])
        // 빈 레인이 넷보다 많아도 편집이 지우지 않는다
        h.apply(try h.timeline.placing(media: ma, at: 0, videoLane: v2, audioLane: a2, clipID: vid), focus: vid)
        h.apply(try h.timeline.relocating(clip: vid, toStart: 30), focus: vid)
        h.apply(try h.timeline.rippleDeleting(clip: vid), focus: nil)
        XCTAssertEqual(h.timeline.lanes.map(\.id), [extraV, v3, v2, v1, a1, a2, a3, extraA])
        let (back, _) = try roundTrip(h.timeline)
        XCTAssertEqual(back.lanes.map(\.id), [extraV, v3, v2, v1, a1, a2, a3, extraA])
        // 기본 빈 레인도 보통 레인처럼 지울 수 있고, 지운 뒤 다시 채우지 않는다(자동 보충 없음)
        h.apply(try h.timeline.removingLane(v3), focus: nil)
        h.apply(try h.timeline.removingLane(a3), focus: nil)
        XCTAssertEqual(h.timeline.lanes.map(\.id), [extraV, v2, v1, a1, a2, extraA])
        XCTAssertEqual(labels(h.timeline), ["V3", "V2", "V1", "A1", "A2", "A3"])
        XCTAssertTrue(h.timeline.isValid)
        h.undo(); h.undo()
        XCTAssertEqual(h.timeline.lanes.map(\.id), [extraV, v3, v2, v1, a1, a2, a3, extraA])
        // 순서 바꾸기도 보통 레인과 같다(같은 종류 안에서)
        let reordered = try h.timeline.movingLane(v3, by: 1)
        XCTAssertEqual(reordered.lanes.map(\.id), [extraV, v2, v3, v1, a1, a2, a3, extraA])
    }
}
