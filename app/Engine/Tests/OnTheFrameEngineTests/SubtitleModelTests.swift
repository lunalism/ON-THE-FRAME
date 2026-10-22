import CoreVideo
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// 자막 모델·편집·형식 6·그리기(2026-10-22, docs/SUBTITLE-DESIGN.md §43). 기대값은 손 계산이다.
final class SubtitleModelTests: XCTestCase {
    let m = UUID(), m2 = UUID()
    /// 영상 A [0,100) + 연결 소리, 자막 레인 S1
    func base() throws -> (Timeline, UUID) {
        let s1 = UUID()
        var t = Timeline(mediaFrames: [m: 300, m2: 300], mediaHasAudio: [m: true, m2: false])
        t = try t.inserting(media: m)                      // [0, 300)
        t = try t.trimming(clip: t.clips[0].id, sourceIn: 0, length: 100)
        t = try t.addingLane(.subtitle, name: "자막", id: s1, outward: true)
        return (t, s1)
    }

    func testLaneOrderLabelsAndValidity() throws {
        var (t, s1) = try base()
        XCTAssertEqual(t.lanes.map(\.kind), [.subtitle, .video, .audio])
        XCTAssertEqual(t.laneLabel(s1), "S1")
        let s2 = UUID()
        t = try t.addingLane(.subtitle, name: "위", id: s2, outward: true)
        XCTAssertEqual(t.lanes.map(\.id).prefix(2), [s2, s1])
        XCTAssertEqual(t.laneLabel(s2), "S2"); XCTAssertEqual(t.laneLabel(s1), "S1")
        XCTAssertNil(t.pairedLane(of: s1))
        // 자막 레인이 영상 레인 아래에 있으면 잘못된 타임라인
        let bad = Timeline(clips: t.clips, audioClips: t.audioClips, lanes: [t.lanes[2], t.lanes[0], t.lanes[1], t.lanes[3]], mediaFrames: t.mediaFrames)
        XCTAssertFalse(bad.isValid)
        // 자막 레인은 마지막 하나도 지울 수 있다(0개 허용), 영상·오디오는 그대로
        t = try t.removingLane(s2).removingLane(s1)
        XCTAssertTrue(t.lanes(.subtitle).isEmpty); XCTAssertTrue(t.isValid)
    }

    func testAddDefaultLengthClampAndNoRoom() throws {
        var (t, s1) = try base()
        t = try t.addingSubtitle(lane: s1, at: 10, text: "가")
        XCTAssertEqual(t.subtitles.map { [$0.start, $0.length] }, [[10, 90]])
        // 다음 자막에 닿으면 그 앞까지: [120, 200) 뒤 [110, …) → 길이 10
        t = try t.addingSubtitle(lane: s1, at: 120, length: 80, text: "나")
        t = try t.addingSubtitle(lane: s1, at: 110, text: "다")
        XCTAssertEqual(t.subtitles(inLane: s1).map { [$0.start, $0.length] }, [[10, 90], [110, 10], [120, 80]])
        XCTAssertThrowsError(try t.addingSubtitle(lane: s1, at: 50, text: "x")) { XCTAssertEqual($0 as? EditError, .subtitleNoRoom) }
        // 영상 끝을 넘으면 길이가 늘어난다(영상은 100까지)
        XCTAssertEqual(t.durationFrames, 200)
        // 영상 레인에는 넣지 않는다. 빈 글자는 된다(빈 자막, D-037)
        XCTAssertThrowsError(try t.addingSubtitle(lane: Lane.videoID, at: 300, text: "x")) { XCTAssertEqual($0 as? EditError, .laneKindMismatch) }
        let blank = try t.addingSubtitle(lane: s1, at: 300, text: "")
        XCTAssertTrue(blank.isValid); XCTAssertEqual(blank.durationFrames, 390); XCTAssertEqual(blank.subtitles.filter(\.isBlank).count, 1)
    }

    func testEditsTextStyleMoveTrimSplitDelete() throws {
        var (t, s1) = try base()
        let a = UUID()
        t = try t.addingSubtitle(lane: s1, at: 10, length: 30, text: "가", id: a)
        XCTAssertEqual(try t.settingSubtitleText(a, " \n ").subtitle(a)?.text, " \n ")   // 빈 글자도 그대로 저장(D-037)
        t = try t.settingSubtitleText(a, "안녕\n두 줄")
        var st = SubtitleStyle.default; st.sizeTenths = 600; st.red = 10; st.alignment = .left; st.xMilli = 100_000
        t = try t.settingSubtitleStyle(a, st)
        st.sizeTenths = 5; XCTAssertThrowsError(try t.settingSubtitleStyle(a, st)) { XCTAssertEqual($0 as? EditError, .subtitleStyleRange) }
        // 옮기기·트림(리플 없음): 다른 항목은 그대로
        let before = t.clips
        t = try t.relocatingSubtitle(a, toStart: 50)
        XCTAssertEqual(t.subtitle(a)?.start, 50); XCTAssertEqual(t.clips, before)
        t = try t.trimmingSubtitle(a, start: 40, end: 100)
        XCTAssertEqual([t.subtitle(a)!.start, t.subtitle(a)!.end], [40, 100])
        XCTAssertThrowsError(try t.trimmingSubtitle(a, start: 40, end: 40)) { XCTAssertEqual($0 as? EditError, .tooShort) }
        // 자르기: 두 조각 같은 글자·모양
        let (l, r) = (UUID(), UUID())
        t = try t.splittingSubtitle(a, atFrame: 70, newIDs: (l, r))
        XCTAssertEqual(t.subtitle(l).map { [$0.start, $0.end] }, [40, 70]); XCTAssertEqual(t.subtitle(r).map { [$0.start, $0.end] }, [70, 100])
        XCTAssertEqual(t.subtitle(l)?.text, "안녕\n두 줄"); XCTAssertEqual(t.subtitle(r)?.style, st.with(size: 600))
        XCTAssertThrowsError(try t.splittingSubtitle(l, atFrame: 40)) { XCTAssertEqual($0 as? EditError, .splitAtBoundary) }
        // 일반 삭제: 길이·다른 항목 그대로
        let d0 = t.durationFrames
        t = try t.liftingSubtitle(l)
        XCTAssertNil(t.subtitle(l)); XCTAssertEqual(t.durationFrames, d0)
        XCTAssertEqual(t.gaps(inLane: s1), [0..<70])
    }

    func testRippleEditsShiftSubtitlesAndRejectCrossing() throws {
        var (t, s1) = try base()
        // 영상 둘째 클립 [100, 160), 자막 [120, 130)(둘째 클립 위), [170, 180)(뒤)
        t = try t.placing(media: m2, at: 100, videoLane: Lane.videoID, audioLane: nil)
        let v2 = t.clips(inLane: Lane.videoID)[1].id
        t = try t.trimming(clip: v2, sourceIn: 0, length: 60)
        let (x, y) = (UUID(), UUID())
        t = try t.addingSubtitle(lane: s1, at: 170, length: 10, text: "뒤", id: y)
        // 리플 삭제 v2 [100,160) 뒤 자막 [170,180) → [110,120)
        let r = try t.rippleDeleting(clip: v2)
        XCTAssertEqual(r.subtitle(y).map { [$0.start, $0.end] }, [110, 120])
        // 걸친 자막이 있으면 리플 삭제 거부
        t = try t.addingSubtitle(lane: s1, at: 150, length: 15, text: "걸침", id: x)
        XCTAssertThrowsError(try t.rippleDeleting(clip: v2)) { XCTAssertEqual($0 as? EditError, .crossingContent) }
        // 리플 트림(늘림)이 뒤 자막도 민다: v2 끝 160 → 170(+10), 걸친 자막 [150,165)이 있어 거부
        XCTAssertThrowsError(try t.trimmingEnd(clip: v2, by: 10)) { XCTAssertEqual($0 as? EditError, .crossingContent) }
        t = try t.liftingSubtitle(x)
        let tr = try t.trimmingEnd(clip: v2, by: 10)
        XCTAssertEqual(tr.subtitle(y).map { [$0.start, $0.end] }, [180, 190])
        // 자막 리플 삭제: [170,180) 닫음 — 그 구간에 다른 내용 없음
        let rd = try t.rippleDeletingSubtitle(y)
        XCTAssertNil(rd.subtitle(y)); XCTAssertEqual(rd.durationFrames, t.durationFrames - 10)
    }

    func testCopyPasteSubtitleLaneChoice() throws {
        var (t, s1) = try base()
        let a = UUID()
        t = try t.addingSubtitle(lane: s1, at: 0, length: 20, text: "복사", id: a)
        let c = try t.copying(subtitle: a)
        // 빈 곳: 같은 레인
        let p1 = try t.pasting(c, at: 40, newLaneName: { _ in "자막" })
        XCTAssertEqual(p1.timeline.subtitles(inLane: s1).count, 2); XCTAssertTrue(p1.createdLanes.isEmpty)
        let nid = p1.ids[a]!
        XCTAssertNotEqual(nid, a); XCTAssertEqual(p1.timeline.subtitle(nid)?.text, "복사")
        // 겹치면 새 자막 레인(맨 위)
        let p2 = try t.pasting(c, at: 10, newLaneName: { _ in "자막" })
        XCTAssertEqual(p2.createdLanes.count, 1); XCTAssertEqual(p2.timeline.lanes.first?.id, p2.createdLanes[0])
        // 자막 레인이 없는 프로젝트에 붙이면 새 자막 레인
        let other = try Timeline(mediaFrames: [m: 300], mediaHasAudio: [m: true]).inserting(media: m)
        let p3 = try other.pasting(c, at: 5, newLaneName: { _ in "자막" })
        XCTAssertEqual(p3.timeline.lanes(.subtitle).count, 1); XCTAssertEqual(p3.timeline.subtitles.first?.start, 5)
    }

    func testCheckpointFixesCP10CP11() throws {
        // CP-10: 당기는 리플 트림이 다른 레인에서 닫히는 구간 안에 끝나는 클립과 부딪히면 crossingContent
        let lanes = [Lane(id: Lane.videoID, kind: .video, name: "V"), Lane(id: Lane.audioID, kind: .audio, name: "A")]
        let v = UUID(), a1 = UUID(), a2 = UUID()
        let t = Timeline(clips: [Clip(id: v, mediaID: m2, start: 0, sourceIn: 0, length: 100)],
                         audioClips: [Clip(id: a1, mediaID: m, start: 0, sourceIn: 0, length: 95), Clip(id: a2, mediaID: m, start: 100, sourceIn: 0, length: 50)],
                         lanes: lanes, mediaFrames: [m: 300, m2: 300], mediaHasAudio: [m: true])
        XCTAssertThrowsError(try t.trimmingEnd(clip: v, by: -10)) { XCTAssertEqual($0 as? EditError, .crossingContent) }
        // 부딪히지 않으면 이전처럼 허용(뒤 내용이 없는 레인)
        XCTAssertNoThrow(try t.trimmingEnd(clip: v, by: -3))
        // CP-11: 다른 미디어의 연결 쌍, ID 중복, 등록되지 않은 미디어는 잘못된 타임라인
        let L = UUID()
        XCTAssertFalse(Timeline(clips: [Clip(mediaID: m2, start: 0, sourceIn: 0, length: 10, link: L)], audioClips: [Clip(mediaID: m, start: 0, sourceIn: 0, length: 10, link: L)],
                                mediaFrames: [m: 300, m2: 300]).isValid)
        let dup = UUID()
        XCTAssertFalse(Timeline(clips: [Clip(id: dup, mediaID: m2, start: 0, sourceIn: 0, length: 10)], audioClips: [Clip(id: dup, mediaID: m, start: 0, sourceIn: 0, length: 10)],
                                mediaFrames: [m: 300, m2: 300]).isValid)
        XCTAssertFalse(Timeline(clips: [Clip(mediaID: UUID(), start: 0, sourceIn: 0, length: 10)], mediaFrames: [m: 300]).isValid)
    }

    // MARK: 형식 6

    func doc(_ t: Timeline) throws -> Data {
        let refs = [MediaRef(id: m, name: "a.mp4", path: "/tmp/a.mp4", frameCount: 300, hasAudio: true, size: 1, modifiedNs: 1, codec: "avc1", width: 1920, height: 1080),
                    MediaRef(id: m2, name: "b.mp4", path: "/tmp/b.mp4", frameCount: 300, hasAudio: false, size: 1, modifiedNs: 1, codec: "avc1", width: 1920, height: 1080)]
        let tt = Timeline(clips: t.clips, audioClips: t.audioClips, subtitles: t.subtitles, lanes: t.lanes, media: refs, mediaFrames: t.mediaFrames,
                          mediaHasAudio: [m: true, m2: false], durationFrames: t.durationFrames)
        return try ProjectFile.encode(tt, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
    }
    func version(_ d: Data) throws -> Int { (try JSONSerialization.jsonObject(with: d) as! [String: Any])["version"] as! Int }

    func testFormatVersionRoundTripAndRejects() throws {
        var (t, s1) = try base()
        // 자막 레인이 없으면 형식 5(키 없음), 있으면 6
        let plain = Timeline(clips: t.clips, audioClips: t.audioClips, lanes: t.lanes.filter { $0.kind != .subtitle }, mediaFrames: t.mediaFrames, mediaHasAudio: t.mediaHasAudio)
        let d5 = try doc(plain)
        XCTAssertEqual(try version(d5), 5); XCTAssertNil((try JSONSerialization.jsonObject(with: d5) as! [String: Any])["subtitles"])
        XCTAssertEqual(try version(try doc(t)), 6)   // 빈 자막 레인만 있어도 6(레인을 버리지 않음)
        var st = SubtitleStyle.default; st.alignment = .right; st.red = 1; st.green = 2; st.blue = 3; st.alpha = 200; st.xMilli = 1_234_567; st.yMilli = 1_000_001
        t = try t.addingSubtitle(lane: s1, at: 7, length: 33, text: "한국어 English 日本語\n둘째 줄", style: st)
        let d6 = try doc(t)
        let back = try ProjectFile.decode(d6).timeline
        XCTAssertEqual(back.subtitles, t.subtitles); XCTAssertEqual(back.lanes, t.lanes); XCTAssertEqual(back.durationFrames, t.durationFrames)
        // 형식 5 이하에 자막 레인·자막이 있으면 거부
        var j = try JSONSerialization.jsonObject(with: d6) as! [String: Any]
        j["version"] = 5
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: j))) { XCTAssertEqual($0 as? ProjectFile.LoadError, .invalid("레인")) }
        // 더 새 형식은 열지 않음
        j["version"] = 7
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: j))) { XCTAssertEqual($0 as? ProjectFile.LoadError, .newerVersion(7)) }
        // 손댄 파일: 영상 레인에 있는 자막, 빈 글자여도 잘못된 모양
        var bad = try JSONSerialization.jsonObject(with: d6) as! [String: Any]
        var subs = bad["subtitles"] as! [[String: Any]]
        subs[0]["lane"] = Lane.videoID.uuidString
        bad["subtitles"] = subs
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: bad))) { XCTAssertEqual($0 as? ProjectFile.LoadError, .invalid("자막")) }
        subs[0]["lane"] = s1.uuidString; subs[0]["text"] = ""; bad["subtitles"] = subs
        XCTAssertEqual(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: bad)).timeline.subtitles.first?.text, "")   // 빈 글자는 읽는다(D-037)
        var style = subs[0]["style"] as! [String: Any]; style["sizeTenths"] = 5; subs[0]["style"] = style; bad["subtitles"] = subs
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: bad))) { XCTAssertEqual($0 as? ProjectFile.LoadError, .invalid("자막")) }   // 빈 글자가 잘못된 모양을 가리지 않음
        style["sizeTenths"] = 480; subs[0]["style"] = style; subs[0]["length"] = 0; bad["subtitles"] = subs
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: bad))) { XCTAssertEqual($0 as? ProjectFile.LoadError, .invalid("자막")) }   // 잘못된 시각도
    }

    // MARK: 그리기

    func testRendererDeterministicAnchorAndMissingFont() throws {
        let r1 = SubtitleRenderer.render(text: "안녕 Hello", style: .default), r2 = SubtitleRenderer.render(text: "안녕 Hello", style: .default)
        XCTAssertEqual(r1.rect, r2.rect)
        XCTAssertEqual(r1.image.dataProvider?.data as Data?, r2.image.dataProvider?.data as Data?)
        // 기본: 가운데 정렬 → 상자 가운데 x = 960, 아래 끝 y = 990, 폭 = 1920 − 2·96
        XCTAssertEqual(r1.rect.midX, 960); XCTAssertEqual(r1.rect.maxY, 990); XCTAssertEqual(r1.rect.width, 1728)
        XCTAssertFalse(r1.missingFont); XCTAssertEqual(r1.fontUsed, SubtitleStyle.defaultFontName)
        var st = SubtitleStyle.default; st.alignment = .left; st.xMilli = 200_000
        XCTAssertEqual(SubtitleRenderer.render(text: "a", style: st).rect.minX, 200)
        st.alignment = .right; st.xMilli = 1_800_000
        XCTAssertEqual(SubtitleRenderer.render(text: "a", style: st).rect.maxX, 1800)
        // 없는 글꼴: 저장 이름은 그대로(모양 값), 그림은 대체 글꼴, 표시
        st = .default; st.fontName = "NoSuchFont-ONTHEFRAME"
        let r3 = SubtitleRenderer.render(text: "대체", style: st)
        XCTAssertTrue(r3.missingFont); XCTAssertNotEqual(r3.fontUsed, st.fontName); XCTAssertFalse(SubtitleRenderer.fontAvailable(st.fontName))
        // 두 줄
        XCTAssertEqual(SubtitleRenderer.render(text: "첫 줄\n둘째 줄", style: .default).lines, 2)
    }

    /// 4:2:0 발자국 합성: 발자국 밖 표본은 바뀌지 않고, 안쪽(알파 1) 밝기는 반올림한 709 Y_sub와 같다(직접 단언)
    func testFootprintPreservesOutsideAndInteriorLuma() throws {
        let item = SubtitleItem(lane: UUID(), start: 0, length: 1, text: "자막 Test", style: .default)
        let r = SubtitleRenderer.shared.raster(item)
        let f = SubtitleFootprint(item, r)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt8.self), c = CVPixelBufferGetBaseAddressOfPlane(pb!, 1)!.assumingMemoryBound(to: UInt8.self)
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb!, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb!, 1)
        for row in 0..<1080 { for x in 0..<1920 { y[row * ybpr + x] = UInt8((x * 7 + row * 3) % 200 + 20) } }
        for row in 0..<540 { for x in 0..<1920 { c[row * cbpr + x] = UInt8((x * 5 + row) % 180 + 30) } }
        var before = [UInt8](repeating: 0, count: 1920 * 1080), cBefore = [UInt8](repeating: 0, count: 1920 * 540)
        for row in 0..<1080 { for x in 0..<1920 { before[row * 1920 + x] = y[row * ybpr + x] } }
        for row in 0..<540 { for x in 0..<1920 { cBefore[row * 1920 + x] = c[row * cbpr + x] } }
        f.composite(pb!)
        let yIn = Set(f.yIdx.map(Int.init)), cIn = Set(f.cIdx.map(Int.init))
        var outside = 0, interiorWrong = 0, changed = 0
        for row in 0..<1080 { for x in 0..<1920 { let i = row * 1920 + x; if y[row * ybpr + x] != before[i] { changed += 1; if !yIn.contains(i) { outside += 1 } } } }
        for row in 0..<540 { for x in 0..<1920 { if c[row * cbpr + x] != cBefore[row * 1920 + x], !cIn.contains(row * 960 + x / 2) { outside += 1 } } }
        for t in 0..<f.yIdx.count where f.ya[t] == 1 { let i = Int(f.yIdx[t]); if y[(i / 1920) * ybpr + i % 1920] != UInt8(max(0, min(255, f.yaSub[t].rounded()))) { interiorWrong += 1 } }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        XCTAssertGreaterThan(changed, 1000); XCTAssertEqual(outside, 0); XCTAssertEqual(interiorWrong, 0)
        // 흰 글자 안쪽은 Y 235(709 비디오 범위 흰색)
        XCTAssertTrue(zip(f.ya, f.yaSub).contains { $0.0 == 1 && abs($0.1 - 235) < 0.001 })
    }
}

private extension SubtitleStyle { func with(size: Int) -> SubtitleStyle { var s = self; s.sizeTenths = size; return s } }
