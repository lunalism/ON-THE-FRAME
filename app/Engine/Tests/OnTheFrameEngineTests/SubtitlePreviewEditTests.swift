import CoreGraphics
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// 프리뷰에서 자막 만들기·고르기에 쓰는 순수 계산(2026-10-22, docs/SUBTITLE-DESIGN.md §44): 보기 ↔ 출력 좌표(여백·크기 바뀜),
/// 누른 자리에 첫 줄 놓기, 보이는 자막 누름 판정, 새 자막 레인 고르기(시작 프레임을 옮기지 않음). 기대값은 손 계산이다.
final class SubtitlePreviewEditTests: XCTestCase {
    let m = UUID()

    func testMappingLetterboxAndResize() {
        // 넓은 보기: 좌우 여백. 1000×400 → k = min(1000/1920, 400/1080) = 0.37037…, 영상 폭 711.1, x 여백 144.4
        let wide = PreviewMapping(viewSize: CGSize(width: 1000, height: 400))
        let k = 400.0 / 1080
        XCTAssertEqual(wide.scale, k, accuracy: 1e-9)
        XCTAssertEqual(wide.videoRect.minX, (1000 - 1920 * k) / 2, accuracy: 1e-9)
        XCTAssertEqual(wide.videoRect.minY, 0, accuracy: 1e-9)
        XCTAssertNil(wide.output(CGPoint(x: 100, y: 200)))                    // 왼쪽 여백
        XCTAssertNil(wide.output(CGPoint(x: 900, y: 200)))                    // 오른쪽 여백
        let c = wide.output(CGPoint(x: 500, y: 200))!                          // 가운데
        XCTAssertEqual(c.x, 960, accuracy: 1e-6); XCTAssertEqual(c.y, 540, accuracy: 1e-6)
        // 높은 보기: 위아래 여백. 400×1000 → k = 400/1920, 영상 높이 225, y 여백 387.5
        let tall = PreviewMapping(viewSize: CGSize(width: 400, height: 1000))
        XCTAssertEqual(tall.videoRect.minY, 387.5, accuracy: 1e-9)
        XCTAssertNil(tall.output(CGPoint(x: 200, y: 100)))
        XCTAssertNil(tall.output(CGPoint(x: 200, y: 900)))
        let tl = tall.output(CGPoint(x: 0, y: 387.5))!
        XCTAssertEqual(tl.x, 0, accuracy: 1e-9); XCTAssertEqual(tl.y, 0, accuracy: 1e-9)
        // 왕복(크기가 바뀌어도 같은 출력 점)
        for size in [CGSize(width: 960, height: 540), CGSize(width: 1234, height: 377), CGSize(width: 333, height: 777)] {
            let mp = PreviewMapping(viewSize: size)
            let o = CGPoint(x: 1300.25, y: 812.5)
            let back = mp.output(mp.view(o))!
            XCTAssertEqual(back.x, o.x, accuracy: 1e-6); XCTAssertEqual(back.y, o.y, accuracy: 1e-6)
        }
        XCTAssertNil(PreviewMapping(viewSize: .zero).output(.zero))
    }

    func testAnchorPutsFirstLineAtClick() {
        // 가운데 정렬 기본 모양: 누른 점 = 첫 줄 글자 사각형의 가로 가운데, 세로는 한 줄 상자 가운데(±줄 높이의 작은 몫)
        for p in [CGPoint(x: 700, y: 300), CGPoint(x: 1500, y: 800), CGPoint(x: 960, y: 540)] {
            let st = SubtitleRenderer.anchored(.default, firstLineAt: p)
            XCTAssertTrue(st.isValid)
            let r = SubtitleRenderer.shared.raster(text: "가나다", style: st)
            XCTAssertEqual(Double(r.textBounds.midX), Double(p.x), accuracy: 2, "가로 \(p)")
            XCTAssertEqual(Double(r.textBounds.midY), Double(p.y), accuracy: 0.2 * SubtitleRenderer.lineHeight(for: st), "세로 \(p)")
            XCTAssertEqual(r.lines, 1)
        }
        // 왼쪽·오른쪽 정렬: 누른 x가 글자 왼쪽 끝·오른쪽 끝
        var l = SubtitleStyle.default; l.alignment = .left
        let rl = SubtitleRenderer.shared.raster(text: "가나다", style: SubtitleRenderer.anchored(l, firstLineAt: CGPoint(x: 300, y: 500)))
        XCTAssertEqual(Double(rl.textBounds.minX), 300, accuracy: 2)
        var rr = SubtitleStyle.default; rr.alignment = .right
        let rrr = SubtitleRenderer.shared.raster(text: "가나다", style: SubtitleRenderer.anchored(rr, firstLineAt: CGPoint(x: 1600, y: 500)))
        XCTAssertEqual(Double(rrr.textBounds.maxX), 1600, accuracy: 2)
        // 아래 끝 근처: 화면 안으로 맞춤(기준점 ≤ 1080)
        let low = SubtitleRenderer.anchored(.default, firstLineAt: CGPoint(x: 960, y: 1075))
        XCTAssertEqual(low.yMilli, 1_080_000); XCTAssertTrue(low.isValid)
    }

    func testHitTestVisibleOnlyAndTopLaneFirst() throws {
        let s1 = UUID(), s2 = UUID(), a = UUID(), b = UUID()
        var t = Timeline(mediaFrames: [m: 300], mediaHasAudio: [m: false])
        t = try t.inserting(media: m)
        t = try t.addingLane(.subtitle, name: "아래", id: s1, outward: true).addingLane(.subtitle, name: "위", id: s2, outward: true)
        let st = SubtitleRenderer.anchored(.default, firstLineAt: CGPoint(x: 960, y: 900))
        t = try t.addingSubtitle(lane: s1, at: 10, length: 20, text: "아래 자막", style: st, id: a)
        t = try t.addingSubtitle(lane: s2, at: 20, length: 20, text: "위 자막", style: st, id: b)
        let center = CGPoint(x: 960, y: 900)
        XCTAssertEqual(t.subtitleHit(atFrame: 15, output: center)?.id, a)
        XCTAssertEqual(t.subtitleHit(atFrame: 25, output: center)?.id, b)          // 둘 다 보임: 위 레인
        XCTAssertNil(t.subtitleHit(atFrame: 9, output: center))                     // 아직 안 보임
        XCTAssertNil(t.subtitleHit(atFrame: 40, output: center))                    // 끝 = 안 보임(반 열린)
        XCTAssertEqual(t.subtitleHit(atFrame: 39, output: center)?.id, b)
        XCTAssertNil(t.subtitleHit(atFrame: 15, output: CGPoint(x: 960, y: 300)))   // 글자 밖
        XCTAssertNil(t.subtitleHit(atFrame: 15, output: CGPoint(x: 150, y: 900)))   // 줄바꿈 폭 안이지만 글자 밖
    }

    func testLaneChoiceKeepsStartAndCreatesLaneWhenNeeded() throws {
        let s1 = UUID(), x = UUID()
        var t = Timeline(mediaFrames: [m: 300], mediaHasAudio: [m: false])
        t = try t.inserting(media: m)
        // 자막 레인 없음 → 새 레인(한 결과에 레인 + 자막)
        let first = UUID(), l1 = UUID()
        XCTAssertNil(t.subtitleLaneForNew(at: 30))
        let t1 = try t.addingSubtitleCreatingLane(at: 30, text: "가", style: .default, id: first, newLaneID: l1, newLaneName: "자막")
        XCTAssertEqual(t1.lanes(.subtitle).map(\.id), [l1]); XCTAssertEqual(t1.subtitle(first)?.start, 30); XCTAssertEqual(t1.subtitle(first)?.length, 90)
        // 같은 시작(겹침) → 기존 레인을 쓰지 않고 바깥쪽 새 레인, 시작 그대로
        let second = UUID(), l2 = UUID()
        XCTAssertNil(t1.subtitleLaneForNew(at: 60))
        let t2 = try t1.addingSubtitleCreatingLane(at: 60, text: "나", style: .default, id: second, newLaneID: l2, newLaneName: "자막")
        XCTAssertEqual(t2.subtitle(second)?.start, 60); XCTAssertEqual(t2.subtitle(second)?.lane, l2)
        XCTAssertEqual(t2.lanes(.subtitle).map(\.id), [l2, l1])                     // 새 레인은 바깥쪽(위, S2)
        // 앞쪽 빈 곳: S1(경계 쪽)을 먼저 쓰고, 다음 자막에 닿으면 길이만 줄인다
        let third = UUID()
        XCTAssertEqual(t2.subtitleLaneForNew(at: 0), l1)
        let t3 = try t2.addingSubtitleCreatingLane(at: 0, text: "다", style: .default, id: third, newLaneName: "자막")
        XCTAssertEqual(t3.subtitle(third).map { [$0.start, $0.length] }, [0, 30]); XCTAssertEqual(t3.lanes(.subtitle).count, 2)
        // 고른 레인이 비어 있으면 그 레인
        XCTAssertEqual(t2.subtitleLaneForNew(at: 200, preferred: l2), l2)
        // 끝 위치(타임라인 길이)에서 시작: 길이가 늘어남
        let t4 = try t3.addingSubtitleCreatingLane(at: t3.durationFrames, text: "라", style: .default, id: x, newLaneName: "자막")
        XCTAssertEqual(t4.durationFrames, t3.durationFrames + 90)
        _ = s1
    }

    // MARK: 2026-10-23: 빈 자막·끝 줄바꿈·위치만 바뀜

    func testBlankItemsAreDocumentItemsButNotRendered() throws {
        let s1 = UUID(), blank = UUID(), seen = UUID(), spaces = UUID()
        var t = Timeline(mediaFrames: [m: 300], mediaHasAudio: [m: false])
        t = try t.inserting(media: m)
        t = try t.addingSubtitleCreatingLane(at: 10, text: "", style: .default, id: blank, newLaneID: s1, newLaneName: "자막")
        t = try t.addingSubtitle(lane: s1, at: 200, text: "보임", id: seen)
        t = try t.addingSubtitle(lane: s1, at: 120, length: 10, text: " \n ", id: spaces)
        XCTAssertTrue(t.isValid)
        XCTAssertEqual(Set(t.subtitles.map(\.id)), [blank, seen, spaces])
        XCTAssertEqual(t.renderedSubtitles.map(\.id), [seen])                 // 프리뷰·내보내기에 그리는 것
        XCTAssertEqual(t.subtitles(atFrame: 15).map(\.id), [blank])           // 타임라인·누름 판정에는 있다
        // 빈 자막 누름 판정: 글자 하나 × 한 줄 상자(기준점 가운데)
        let cb = SubtitleRenderer.caretBounds(.default)
        XCTAssertEqual(Double(cb.midX), 960, accuracy: 0.01); XCTAssertEqual(Double(cb.width), 48, accuracy: 0.01)
        XCTAssertEqual(Double(cb.maxY), 990 - Double(SubtitleRenderer.pad(for: .default)), accuracy: 0.01)
        XCTAssertEqual(t.subtitleHit(atFrame: 15, output: CGPoint(x: 960, y: cb.midY))?.id, blank)
        XCTAssertNil(t.subtitleHit(atFrame: 15, output: CGPoint(x: 700, y: cb.midY)))
        // 빈 자막이 든 형식 6 저장·다시 열기(글자 "" 그대로, 위치·레인 그대로)
        let ref = MediaRef(id: m, name: "a.mp4", path: "/tmp/a.mp4", frameCount: 300, hasAudio: false, size: 1, modifiedNs: 1, codec: "avc1", width: 1920, height: 1080)
        let tt = Timeline(clips: t.clips, audioClips: t.audioClips, subtitles: t.subtitles, lanes: t.lanes, media: [ref], mediaFrames: t.mediaFrames,
                          mediaHasAudio: t.mediaHasAudio, mediaHasVideo: [m: true], durationFrames: t.durationFrames)
        let data = try ProjectFile.encode(tt, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        let back = try ProjectFile.decode(data).timeline
        XCTAssertEqual(back.subtitles.sorted { $0.start < $1.start }, t.subtitles.sorted { $0.start < $1.start })
        XCTAssertEqual(back.subtitle(blank)?.text, "")
    }

    func testTrailingNewlineKeepsEmptyLineInRender() {
        let st = SubtitleRenderer.anchored(.default, firstLineAt: CGPoint(x: 960, y: 900))
        let one = SubtitleRenderer.shared.raster(text: "가나다", style: st)
        let trailing = SubtitleRenderer.shared.raster(text: "가나다\n", style: st)
        let two = SubtitleRenderer.shared.raster(text: "가나다\n라", style: st)
        XCTAssertEqual(one.lines, 1); XCTAssertEqual(trailing.lines, 2); XCTAssertEqual(two.lines, 2)
        XCTAssertEqual(trailing.rect.height, two.rect.height)                  // 빈 끝 줄도 한 줄 높이
        // 글자 "가나다"는 끝 줄바꿈이 있으면 한 줄 위(편집 칸과 같음), 다음 줄을 쳐도 그 자리 그대로(움직임 없음)
        let line = Double(two.textBounds.maxY - two.textBounds.minY) / 2
        XCTAssertEqual(Double(trailing.textBounds.minY), Double(one.textBounds.minY) - line, accuracy: 2)
        XCTAssertEqual(Double(trailing.textBounds.minY), Double(two.textBounds.minY), accuracy: 0.5)
        XCTAssertEqual(trailing.fallbackFonts, one.fallbackFonts)               // 붙인 폭 없는 공백은 글꼴 기록에 넣지 않음
    }

    func testPositionOnlyChangeReusesRaster() {
        var st = SubtitleStyle.default; st.red = 17   // 이 시험만의 모양(캐시 처음)
        let r0 = SubtitleRenderer.shared.raster(text: "옮기기", style: st)
        let n0 = SubtitleRenderer.shared.renderCount
        for i in 1...50 {
            var moved = st; moved.xMilli += i * 3_217; moved.yMilli -= i * 1_111
            let r = SubtitleRenderer.shared.raster(text: "옮기기", style: moved)
            XCTAssertTrue(r.image === r0.image)
            // 사각형은 예전 식(기준점에서 계산 후 반올림)
            XCTAssertEqual(Double(r.rect.minX), (moved.x - Double(r.rect.width) / 2).rounded())
            XCTAssertEqual(Double(r.rect.minY), (moved.y - Double(r.rect.height)).rounded())
            XCTAssertEqual(Double(r.textBounds.width), Double(r0.textBounds.width), accuracy: 1e-9)
        }
        XCTAssertEqual(SubtitleRenderer.shared.renderCount, n0)                // 위치만 바뀌면 다시 그리지 않음
        // 기록(판정 아님): 캐시가 위치까지 키로 쓰던 때는 끌기 이벤트마다 이만큼 다시 조판·그렸다
        let t0 = Date()
        for i in 0..<20 { var mv = st; mv.xMilli += i; _ = SubtitleRenderer.render(text: "옮기기\n두 줄 자막", style: mv) }
        print(String(format: "RECORD 자막 한 번 다시 그리기(캐시 없음, 디버그 빌드) 평균 %.2f ms", Date().timeIntervalSince(t0) * 1000 / 20))
        var recolor = st; recolor.red = 18
        _ = SubtitleRenderer.shared.raster(text: "옮기기", style: recolor)
        XCTAssertEqual(SubtitleRenderer.shared.renderCount, n0 + 1)            // 색이 바뀌면 다시 그림
    }

    // MARK: 코드 리뷰 고침(2026-10-23)

    /// 키 큰 글(2026-10-23): 상자가 화면보다 높으면 화면 안 띠만 그린다. 글을 자르지 않고, 띠는 전체 그림의 같은 줄과 화소가 같다.
    func testTallTextRendersVisibleBandWithoutTruncation() throws {
        var st = SubtitleStyle.default; st.sizeTenths = 1200; st.blue = 17   // 120 pt, 이 시험만의 모양
        let text = (1...20).map { "줄 \($0) 긴 자막" }.joined(separator: "\n")
        let r = SubtitleRenderer.shared.raster(text: text, style: st)
        XCTAssertFalse(r.failed); XCTAssertTrue(r.clipped)
        XCTAssertEqual(r.lines, 20)                                               // 모든 줄을 조판(자르지 않음)
        XCTAssertLessThanOrEqual(r.image.height, SubtitleStyle.outputHeight)        // 그림은 화면 높이 이하
        XCTAssertEqual(Int(r.rect.minY), 0); XCTAssertEqual(Int(r.rect.maxY), Int((st.y - 0).rounded()))   // 띠 = [0, 기준점) — 아래 끝 기준
        XCTAssertEqual(r.fullImage.width, Int(r.rect.width)); XCTAssertEqual(r.fullImage.height, Int(r.rect.height))
        XCTAssertTrue(r.rect.contains(r.drawRect)); XCTAssertEqual(r.image.width, Int(r.drawRect.width)); XCTAssertEqual(r.image.height, Int(r.drawRect.height))
        // 띠 = 전체 그림(직접 그림)의 같은 줄
        let l = SubtitleRenderer.layout(text: text, style: st)
        XCTAssertNil(l.image); let frame = try XCTUnwrap(l.frame)
        let full = try XCTUnwrap(SubtitleRenderer.bitmap(l.width, l.height)); CTFrameDraw(frame, full)
        let fullImg = try XCTUnwrap(full.makeImage())
        let (fullRect, _) = SubtitleRenderer.geometry(l, style: st)
        let rowOffset = Int(r.rect.minY - fullRect.minY)
        func bytes(_ img: CGImage) -> [UInt8] { let d = img.dataProvider!.data! as Data; return [UInt8](d) }
        let rImg = r.fullImage   // 잘라 낸 그림을 띠 크기로 되돌려 비교(2026-10-23)
        let fb = bytes(fullImg), bb = bytes(rImg), bpr = rImg.bytesPerRow, fbpr = fullImg.bytesPerRow
        var differ = 0, ink = 0
        for y in 0..<rImg.height {
            for x in stride(from: 0, to: rImg.width * 4, by: 4) {
                let a = bb[y * bpr + x + 3], b = fb[(y + rowOffset) * fbpr + x + 3]
                if a != b { differ += 1 }; if a > 0 { ink += 1 }
            }
        }
        XCTAssertEqual(differ, 0); XCTAssertGreaterThan(ink, 1000)                 // 글자가 실제로 그려짐
        // 위치를 옮기면 그 자리의 띠(화면 안이면 더 많은 줄)
        var low = st; low.yMilli = 1_080_000
        XCTAssertEqual(Int(SubtitleRenderer.shared.raster(text: text, style: low).rect.maxY), 1080)
    }

    /// 그리지 못함(그림을 만들지 못함): failed로 알린다. 빈 자막은 그릴 것이 없어 내보내기 판정에 들지 않는다(renderedSubtitles).
    func testRenderFailureIsFlaggedNotSilent() {
        SubtitleRenderer.maxBitmapBytesForTest = 1_000
        defer { SubtitleRenderer.maxBitmapBytesForTest = Int.max }
        var st = SubtitleStyle.default; st.green = 77   // 이 시험만의 모양(캐시 처음)
        let r = SubtitleRenderer.shared.raster(text: "실패할 글", style: st)
        XCTAssertTrue(r.failed); XCTAssertEqual(r.image.height, 1); XCTAssertEqual(Int(r.rect.height), 1)
        XCTAssertGreaterThan(r.textBounds.width, 0)                                // 글자 사각형(누름·선택)은 그대로
        var tall = st; tall.sizeTenths = 1200
        let t = SubtitleRenderer.shared.raster(text: (1...20).map(String.init).joined(separator: "\n"), style: tall)
        XCTAssertTrue(t.failed)                                                   // 띠 그림도 상한을 따른다
    }

    func testDecodeRejectsOverflowingSubtitleLength() throws {
        let s1 = UUID()
        var t = Timeline(mediaFrames: [m: 300], mediaHasAudio: [m: false])
        t = try t.inserting(media: m)
        t = try t.addingSubtitleCreatingLane(at: 1, text: "가", style: .default, id: UUID(), newLaneID: s1, newLaneName: "자막")
        let ref = MediaRef(id: m, name: "a.mp4", path: "/tmp/a.mp4", frameCount: 300, hasAudio: false, size: 1, modifiedNs: 1, codec: "avc1", width: 1920, height: 1080)
        let tt = Timeline(clips: t.clips, audioClips: t.audioClips, subtitles: t.subtitles, lanes: t.lanes, media: [ref], mediaFrames: t.mediaFrames,
                          mediaHasAudio: t.mediaHasAudio, mediaHasVideo: [m: true], durationFrames: t.durationFrames)
        var j = try JSONSerialization.jsonObject(with: try ProjectFile.encode(tt, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)) as! [String: Any]
        var subs = j["subtitles"] as! [[String: Any]]
        subs[0]["length"] = Int.max; j["subtitles"] = subs
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: j))) { XCTAssertEqual($0 as? ProjectFile.LoadError, .invalid("자막")) }
    }
}
