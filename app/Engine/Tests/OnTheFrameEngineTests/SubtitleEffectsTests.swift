import CoreGraphics
import CoreText
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// 자막 효과(외곽선·그림자·배경, 2026-10-23, D-040, docs/SUBTITLE-DESIGN.md §48): 모델·형식 7·그림.
/// 그림 판정은 미리 곱한 BGRA(premultipliedFirst, little-endian) 그림의 화소를 직접 읽는다.
final class SubtitleEffectsTests: XCTestCase {
    let m = UUID()

    /// 그림의 출력 좌표 (x, y) 화소(B, G, R, A — 미리 곱함). 그림 밖이면 nil.
    func px(_ r: SubtitleRaster, _ x: CGFloat, _ y: CGFloat) -> (b: Int, g: Int, r: Int, a: Int)? {
        let ix = Int((x - r.rect.minX).rounded(.down)), iy = Int((y - r.rect.minY).rounded(.down))
        let img = r.fullImage
        guard ix >= 0, iy >= 0, ix < img.width, iy < img.height else { return nil }
        let d = img.dataProvider!.data! as Data, o = iy * img.bytesPerRow + ix * 4
        return (Int(d[o]), Int(d[o + 1]), Int(d[o + 2]), Int(d[o + 3]))
    }
    func bytes(_ i: CGImage) -> [UInt8] { [UInt8](i.dataProvider!.data! as Data) }
    /// 가운데 행에서 글자 잉크(채움 알파 fillA ± 3)의 왼쪽·오른쪽 끝(출력 x). textBounds는 조판 폭이라 글리프 잉크보다 넓을 수 있다.
    /// 판정: 채움 화소인가(기본: 알파가 fillA ± 3). 그림자도 불투명하면 색으로 가려야 한다(fillRed).
    func inkSpan(_ r: SubtitleRaster, fillA: Int, fillRed: Int? = nil) -> (minX: CGFloat, maxX: CGFloat) {
        let y = r.textBounds.midY
        func isFill(_ p: (b: Int, g: Int, r: Int, a: Int)) -> Bool { abs(p.a - fillA) <= 3 && (fillRed.map { abs(p.r - $0) <= 3 } ?? true) }
        var lo = r.textBounds.midX, hi = r.textBounds.midX
        while let p = px(r, lo - 1, y), isFill(p) { lo -= 1 }
        while let p = px(r, hi + 1, y), isFill(p) { hi += 1 }
        return (lo, hi)
    }
    func near(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01 }
    /// 이 시험만의 모양(캐시 처음)
    func base(_ tag: Int) -> SubtitleStyle { var s = SubtitleStyle.default; s.red = 250; s.green = 250 - tag % 50; s.blue = 250; return s }

    func testEffectsOffReproducesPreviousRendering() {
        let plain = base(1)
        var disabled = plain
        var o = SubtitleOutline.default; o.enabled = false; disabled.outline = o
        var sh = SubtitleShadow.default; sh.enabled = false; disabled.shadow = sh
        var bg = SubtitleBackground.default; bg.enabled = false; disabled.background = bg
        XCTAssertFalse(disabled.hasEnabledEffects); XCTAssertTrue(disabled.isValid)
        for text in ["가나다 English", "두 줄\n둘째 줄", (1...40).map(String.init).joined(separator: "\n")] {   // 보통 글·키 큰 글
            let a = SubtitleRenderer.shared.raster(text: text, style: plain), b = SubtitleRenderer.shared.raster(text: text, style: disabled)
            XCTAssertEqual(a.rect, b.rect); XCTAssertEqual(a.textBounds, b.textBounds); XCTAssertEqual(a.hitRect, a.textBounds)
            XCTAssertEqual(bytes(a.image), bytes(b.image), text); XCTAssertEqual(a.drawRect, b.drawRect, text)
        }
    }

    func testFormatSevenOnlyWhenEnabledAndRoundTrip() throws {
        let s1 = UUID(), id = UUID()
        var t = Timeline(mediaFrames: [m: 300], mediaHasAudio: [m: false])
        t = try t.inserting(media: m)
        var st = SubtitleStyle.default
        var o = SubtitleOutline.default; o.enabled = false; st.outline = o   // 꺼진 설정만
        t = try t.addingSubtitleCreatingLane(at: 10, text: "효과", style: st, id: id, newLaneID: s1, newLaneName: "자막")
        func doc(_ t: Timeline) throws -> Data {
            let ref = MediaRef(id: m, name: "a.mp4", path: "/tmp/a.mp4", frameCount: 300, hasAudio: false, size: 1, modifiedNs: 1, codec: "avc1", width: 1920, height: 1080)
            let tt = Timeline(clips: t.clips, audioClips: t.audioClips, subtitles: t.subtitles, lanes: t.lanes, media: [ref], mediaFrames: t.mediaFrames,
                              mediaHasAudio: t.mediaHasAudio, mediaHasVideo: [m: true], durationFrames: t.durationFrames)
            return try ProjectFile.encode(tt, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        }
        func version(_ d: Data) throws -> Int { (try JSONSerialization.jsonObject(with: d) as! [String: Any])["version"] as! Int }
        // 꺼진 설정만: 형식 6, 다시 읽으면 꺼진 설정 그대로
        let d6 = try doc(t)
        XCTAssertEqual(try version(d6), 6)
        XCTAssertEqual(try ProjectFile.decode(d6).timeline.subtitle(id)?.style.outline, o)
        // 켜면: 형식 7, 모든 효과 값 그대로
        var on = st; on.outline = .default; on.shadow = .default; on.background = .default
        on.shadow!.offsetXTenths = -35; on.background!.alpha = 77
        let t7 = try t.settingSubtitleStyle(id, on)
        let d7 = try doc(t7)
        XCTAssertEqual(try version(d7), 7)
        XCTAssertEqual(try ProjectFile.decode(d7).timeline.subtitle(id)?.style, on)
        // 복사·붙여넣기에서도 효과 그대로
        let clip = try t7.copying(subtitle: id)
        XCTAssertEqual(clip.subtitles.first?.style, on)
        // 형식 6 파일에 켜진 효과 → 잘못된 파일, 더 새 형식은 열지 않음
        var j = try JSONSerialization.jsonObject(with: d7) as! [String: Any]
        j["version"] = 6
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: j))) { XCTAssertEqual($0 as? ProjectFile.LoadError, .invalid("자막 효과")) }
        j["version"] = 8
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: j))) { XCTAssertEqual($0 as? ProjectFile.LoadError, .newerVersion(8)) }
        // 범위 밖 값은 거부(형식 7)
        j["version"] = 7
        for (key, field, bad) in [("outline", "widthTenths", 0), ("outline", "widthTenths", 201), ("shadow", "offsetXTenths", 1001), ("shadow", "blurTenths", 501),
                                  ("background", "padYTenths", 2001), ("background", "alpha", 256), ("background", "radiusTenths", -1)] {
            var jj = j
            var subs = jj["subtitles"] as! [[String: Any]]
            var style = subs[0]["style"] as! [String: Any]
            var e = style[key] as! [String: Any]; e[field] = bad; style[key] = e; subs[0]["style"] = style; jj["subtitles"] = subs
            XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: jj)), "\(key).\(field)=\(bad)")
        }
        // 효과 키가 없는 이전 문서(형식 6)는 효과 없음으로 읽힘
        let plainT = try t.settingSubtitleStyle(id, .default)
        XCTAssertNil(try ProjectFile.decode(try doc(plainT)).timeline.subtitle(id)?.style.outline)
    }

    func testBoundsExpandWithoutMovingText() {
        let plain = base(2)
        let p = SubtitleRenderer.shared.raster(text: "가나다", style: plain)
        var ol = plain; ol.outline = .default; ol.outline!.widthTenths = 50   // 5 px
        let o = SubtitleRenderer.shared.raster(text: "가나다", style: ol)
        XCTAssertEqual(o.textBounds, p.textBounds)                            // 글자 자리는 그대로(기준점·줄바꿈·줄 간격)
        XCTAssertLessThanOrEqual(o.rect.minY, p.textBounds.minY - 5); XCTAssertGreaterThanOrEqual(o.rect.maxY, p.textBounds.maxY + 5)
        // 누름 = 글자(잉크 포함) + 외곽선 + 획 가장자리 1 px(2026-10-23 검토 고침): 글자 + 5 px를 덮고, 글자 + 5 + 1 + 잉크 넘침 여유 3 px 안
        XCTAssertTrue(o.hitRect.insetBy(dx: -0.01, dy: -0.01).contains(p.textBounds.insetBy(dx: -5, dy: -5)), "\(o.hitRect)")
        XCTAssertTrue(p.textBounds.insetBy(dx: -9, dy: -9).contains(o.hitRect), "\(o.hitRect)")
        var bg = plain; bg.background = .default
        let b = SubtitleRenderer.shared.raster(text: "가나다", style: bg)
        XCTAssertTrue(near(b.hitRect, p.textBounds.insetBy(dx: -16, dy: -10)), "\(b.hitRect)")   // 누름 = 글자 + 배경 여백
        XCTAssertLessThanOrEqual(b.rect.minX, p.textBounds.minX - 16)
        // 그림자는 누름에 넣지 않고, 그림 범위는 거리·흐림만큼(양·음 방향)
        for (dx, dy) in [(80, 60), (-80, -60)] {
            var sh = plain; sh.shadow = .default; sh.shadow!.offsetXTenths = dx * 10; sh.shadow!.offsetYTenths = dy * 10
            let s = SubtitleRenderer.shared.raster(text: "가나다", style: sh)
            XCTAssertTrue(near(s.hitRect, p.textBounds))
            if dx > 0 { XCTAssertGreaterThanOrEqual(s.rect.maxX, p.textBounds.maxX + 80 + 6); XCTAssertGreaterThanOrEqual(s.rect.maxY, p.textBounds.maxY + 60 + 6) }
            else { XCTAssertLessThanOrEqual(s.rect.minX, p.textBounds.minX - 80 - 6); XCTAssertLessThanOrEqual(s.rect.minY, p.textBounds.minY - 60 - 6) }
        }
    }

    /// 알파: 배경 50%는 한 번만(투명 위 알파 128), 반투명 채움은 외곽선 위에 섞이지 않고 채움 알파 그대로(외곽선이 비치지 않음)
    func testAlphaAppliedOnce() {
        var st = base(3); st.sizeTenths = 2000; st.red = 255; st.green = 0; st.blue = 0; st.alpha = 128   // 반투명 빨강
        st.outline = .default; st.outline!.widthTenths = 80                                             // 불투명 검정 8 px
        let r = SubtitleRenderer.shared.raster(text: "■", style: st)
        let c = px(r, r.textBounds.midX, r.textBounds.midY)!                                            // 글자 안쪽 가운데
        XCTAssertEqual(c.a, 128, accuracy: 2); XCTAssertEqual(c.r, 128, accuracy: 2); XCTAssertEqual(c.g, 0, accuracy: 1)
        let ink = inkSpan(r, fillA: 128)
        let edge = px(r, ink.minX - 4, r.textBounds.midY)!                                              // 잉크 바깥 외곽선 띠(8 px 안)
        XCTAssertEqual(edge.a, 255, accuracy: 2); XCTAssertLessThan(edge.r, 5)
        XCTAssertEqual(px(r, ink.minX - 12, r.textBounds.midY)?.a ?? 0, 0)                               // 외곽선 밖은 투명
        var bgOnly = base(4); bgOnly.background = .default; bgOnly.background!.padXTenths = 400
        let b = SubtitleRenderer.shared.raster(text: "가", style: bgOnly)
        let pad = px(b, b.textBounds.minX - 20, b.textBounds.midY)!                                     // 배경 여백(글자 밖)
        XCTAssertEqual(pad.a, 128, accuracy: 1); XCTAssertEqual(pad.r, 0); XCTAssertEqual(pad.g, 0); XCTAssertEqual(pad.b, 0)
    }

    /// 그림자: 글자 실루엣의 것(양·음 거리), 배경 상자에는 붙지 않음
    func testShadowDirectionAndSilhouetteOnly() {
        for (dx, sign) in [(20, 1.0), (-20, -1.0)] {
            var st = base(5 + dx); st.sizeTenths = 2000
            st.shadow = SubtitleShadow(enabled: true, red: 0, green: 0, blue: 0, alpha: 255, offsetXTenths: dx * 10, offsetYTenths: 0, blurTenths: 0)
            let r = SubtitleRenderer.shared.raster(text: "■", style: st)
            let ink = inkSpan(r, fillA: 255, fillRed: 250)   // 흰 채움(빨강 250) — 검정 그림자와 구별
            let side = sign > 0 ? ink.maxX + 10 : ink.minX - 10      // 잉크 끝에서 거리 안쪽(20 px 그림자)
            let other = sign > 0 ? ink.minX - 10 : ink.maxX + 10
            XCTAssertGreaterThan(px(r, side, r.textBounds.midY)?.a ?? 0, 200, "dx \(dx)")
            XCTAssertEqual(px(r, other, r.textBounds.midY)?.a ?? 0, 0, "dx \(dx)")
        }
        // 배경 + 그림자: 배경 상자 바깥(그림자 거리 쪽)에 상자 모양 그림자가 없다 — 글자에서 먼 상자 모서리 바깥은 투명
        var st = base(9); st.sizeTenths = 600
        st.background = .default; st.background!.padXTenths = 600; st.background!.alpha = 255
        st.shadow = SubtitleShadow(enabled: true, red: 0, green: 0, blue: 0, alpha: 255, offsetXTenths: 300, offsetYTenths: 300, blurTenths: 0)
        let r = SubtitleRenderer.shared.raster(text: "가", style: st)
        let boxRight = r.textBounds.maxX + 60, boxBottom = r.textBounds.maxY + 10
        // 상자 오른쪽 아래 모서리 바로 바깥(+거리 안): 상자의 그림자라면 칠해져 있었을 자리
        XCTAssertEqual(px(r, boxRight + 15, boxBottom + 15)?.a ?? 0, 0)
    }

    /// 화면 가장자리: 그림자·배경이 화면 밖으로 나가도 그림·발자국이 만들어지고(잘림은 쓰는 쪽), 키 큰 글 띠는 전체 그림의 같은 줄과 같다
    func testEdgeAndTallTextWithEffects() throws {
        var st = base(10)
        st.outline = .default; st.shadow = .default; st.background = .default
        st.xMilli = 0; st.alignment = .left; st.yMilli = 40_000   // 왼쪽 위 가장자리
        let edge = SubtitleRenderer.shared.raster(text: "가장자리", style: st)
        XCTAssertLessThan(edge.rect.minX, 0); XCTAssertLessThan(edge.rect.minY, 0); XCTAssertFalse(edge.failed)
        let item = SubtitleItem(id: UUID(), lane: UUID(), start: 0, length: 1, text: "가장자리", style: st)
        _ = SubtitleFootprint(item, edge)   // 화면 밖 부분은 버림(멈추지 않음)
        // 키 큰 글 + 효과: 띠 = 전체 그림의 같은 줄(그림자가 띠 밖 줄에서 들어오는 것 포함)
        var tall = base(11); tall.sizeTenths = 1200
        tall.outline = .default; tall.shadow = .default; tall.shadow!.offsetYTenths = 300; tall.shadow!.blurTenths = 120; tall.background = .default
        let text = (1...20).map { "줄 \($0) 효과" }.joined(separator: "\n")
        let band = SubtitleRenderer.shared.raster(text: text, style: tall)
        XCTAssertFalse(band.failed); XCTAssertTrue(band.clipped); XCTAssertEqual(Int(band.rect.minY), 0)
        let l = SubtitleRenderer.layout(text: text, style: tall)
        let full = try XCTUnwrap(SubtitleRenderer.bitmap(Int(l.ext.width), Int(l.ext.height)))
        full.translateBy(x: -l.ext.minX, y: -l.ext.minY)
        SubtitleRenderer.drawContent(full, fill: try XCTUnwrap(l.frame), outline: l.outlineFrame, style: l.style, tight: l.tight)
        let fullImg = try XCTUnwrap(full.makeImage())
        let (logical, _) = SubtitleRenderer.geometry(l, style: tall)
        let fullRect = SubtitleRenderer.toOutput(l.ext, logical: logical, h: l.height)
        XCTAssertEqual(band.rect.minX, fullRect.minX); XCTAssertEqual(band.fullImage.width, fullImg.width)
        let off = Int(band.rect.minY - fullRect.minY)
        let bandImg = band.fullImage
        let fb = bytes(fullImg), bb = bytes(bandImg)
        var differ = 0, ink = 0
        for y in 0..<bandImg.height {
            for x in stride(from: 0, to: bandImg.width * 4, by: 4) {
                let a = Int(bb[y * bandImg.bytesPerRow + x + 3]), b = Int(fb[(y + off) * fullImg.bytesPerRow + x + 3])
                if abs(a - b) > 1 { differ += 1 }; if a > 0 { ink += 1 }
            }
        }
        XCTAssertEqual(differ, 0); XCTAssertGreaterThan(ink, 1000)
    }

    /// 빈 글자·공백뿐: 효과가 켜져도 그림은 비어 있다(그릴 목록에서도 빠짐)
    func testEmptyTextStaysEmptyWithEffects() throws {
        var st = base(12); st.outline = .default; st.shadow = .default; st.background = .default
        let r = SubtitleRenderer.shared.raster(text: "   ", style: st)
        XCTAssertTrue(bytes(r.image).enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 0 })
        let s1 = UUID()
        var t = Timeline(mediaFrames: [m: 300], mediaHasAudio: [m: false])
        t = try t.inserting(media: m).addingSubtitleCreatingLane(at: 0, text: "", style: st, id: UUID(), newLaneID: s1, newLaneName: "자막")
        XCTAssertTrue(t.renderedSubtitles.isEmpty)
    }

    /// 그림을 만들지 못함(효과로 커진 그림 포함): failed
    func testResourceFailureWithEffects() {
        SubtitleRenderer.maxBitmapBytesForTest = 1_000
        defer { SubtitleRenderer.maxBitmapBytesForTest = Int.max }
        var st = base(13); st.outline = .default; st.shadow = .default; st.background = .default
        XCTAssertTrue(SubtitleRenderer.shared.raster(text: "실패", style: st).failed)
    }

    // MARK: 메모리 보유(2026-10-23 검토: 측정한 낭비를 고친 것의 회귀 시험)

    /// 캐시(2026-10-23 §49): 가장 오래 안 쓴 것부터 하나씩 버리는 바이트 상한(64 MiB) + 개수 상한.
    /// - 상한 안의 묶음은 두 번째 차례에 다시 그리지 않는다(예전 전체 비움 예산은 묶음이 예산보다 크면 매번 다시 그렸다 — §48.6).
    /// - 상한보다 큰 묶음을 넣어도 붙잡는 바이트는 상한 안이다(메모리 상한).
    /// - 자주 쓰는 항목은 다른 항목이 계속 들어와도 남는다(전체 비움이 아님).
    func testRasterCacheIsByteBoundedLRU() {
        let r = SubtitleRenderer()
        func item(_ i: Int, _ text: String = "두 줄 자막\n둘째 줄입니다") -> SubtitleItem {
            var s = SubtitleStyle.default; s.background = .default; s.green = i % 256; s.blue = i / 256 + 1
            return SubtitleItem(id: UUID(), lane: UUID(), start: i * 10, length: 10, text: text, style: s)
        }
        // 1) 상한 안의 묶음(40개)
        let small = (0..<40).map { item($0) }
        for it in small { _ = r.raster(it) }
        let n1 = r.renderCount
        for it in small { _ = r.raster(it) }
        XCTAssertEqual(r.renderCount, n1, "상한 안 묶음은 다시 그리지 않음")
        XCTAssertLessThan(r.cachedImageBytes, SubtitleRenderer.cacheByteBudget)
        // 2) 상한보다 큰 흐름(600개, 자르기 전 크기로 약 500 MB): 붙잡는 바이트는 상한 안, 개수도 512 안
        let hot = item(10_000, "자주 쓰는 자막")
        var streamed = 0
        for i in 0..<600 {
            let x = r.raster(item(1000 + i)); streamed += Int(x.rect.width * x.rect.height) * 4
            if i % 10 == 0 { _ = r.raster(hot) }   // 3) 자주 쓰는 항목
            XCTAssertLessThanOrEqual(r.cachedImageBytes, SubtitleRenderer.cacheByteBudget + 8 << 20)
        }
        XCTAssertGreaterThan(streamed, SubtitleRenderer.cacheByteBudget * 4, "흐름이 상한보다 충분히 크다")
        XCTAssertLessThanOrEqual(r.cachedImageBytes, SubtitleRenderer.cacheByteBudget)
        let n2 = r.renderCount
        _ = r.raster(hot)
        XCTAssertEqual(r.renderCount, n2, "자주 쓰는 항목은 남아 있다")
        // 키 큰 글 띠(한 장 수 MB)도 상한 안
        var tall = SubtitleStyle.default; tall.sizeTenths = 1200; tall.background = .default
        for i in 0..<40 { var s = tall; s.green = i; _ = r.raster(SubtitleItem(id: UUID(), lane: UUID(), start: i, length: 1, text: (1...12).map(String.init).joined(separator: "\n"), style: s)) }
        XCTAssertLessThanOrEqual(r.cachedImageBytes, SubtitleRenderer.cacheByteBudget)
        r.removeAll(); XCTAssertEqual(r.cachedImageBytes, 0)
    }

    /// 내보내기 발자국 창: 보이는 자막만 들고(고치기 전에는 효과 자막 200개를 내보내기 내내 약 118 MB 보유 — 측정), 겹칠 때 그리기 순서 그대로
    func testFootprintWindowHoldsOnlyVisibleInDrawOrder() {
        let lane = UUID()
        var st = SubtitleStyle.default; st.background = .default
        let seq = (0..<200).map { SubtitleItem(id: UUID(), lane: lane, start: $0 * 10, length: 10, text: "자막 \($0)", style: st) }
        let w = FootprintWindow(seq)
        for k in 0..<2000 { XCTAssertEqual(w.visible(at: k).map(\.start), [k / 10 * 10]) }
        XCTAssertEqual(w.peak, 1)
        // 겹침: 입력 차례(그리기 순서: 아래 레인 먼저)를 지킨다 — 시작이 늦은 항목이 앞 차례여도
        let a = SubtitleItem(id: UUID(), lane: lane, start: 5, length: 20, text: "아래", style: st)
        let b = SubtitleItem(id: UUID(), lane: UUID(), start: 0, length: 30, text: "위", style: st)
        let w2 = FootprintWindow([a, b])
        XCTAssertEqual(w2.visible(at: 0).map(\.start), [0])
        XCTAssertEqual(w2.visible(at: 10).map(\.start), [5, 0])   // a(차례 0) 먼저, b(차례 1) 위
        XCTAssertEqual(w2.visible(at: 25).map(\.start), [0])
        XCTAssertEqual(w2.visible(at: 30).map(\.start), [])
    }

    /// 2026-10-23 검토: 효과 범위가 줄 사각형만 보고 잉크(왼쪽 맞춤 "j"의 왼쪽 갈고리 등)와 획 가장자리 앤티에일리어싱을 빼서
    /// 외곽선이 그림 왼쪽 끝에서 잘렸다(측정: 왼쪽 끝 알파 255). 큰 흐림 그림자도 가장자리에 닿지 않는지 함께 본다.
    func testEffectExtentCoversInkAndShadowTails() {
        func edgeAlpha(_ img: CGImage) -> Int {
            let d = CFDataGetBytePtr(img.dataProvider!.data!)!, bpr = img.bytesPerRow, w = img.width, h = img.height
            var m = 0
            for y in 0..<h { m = max(m, Int(d[y * bpr + 3]), Int(d[y * bpr + (w - 1) * 4 + 3])) }
            for x in 0..<w { m = max(m, Int(d[x * 4 + 3]), Int(d[(h - 1) * bpr + x * 4 + 3])) }
            return m
        }
        var a = SubtitleStyle.default; a.alignment = .left; a.outline = .default; a.outline!.widthTenths = 200
        XCTAssertEqual(edgeAlpha(SubtitleRenderer.shared.raster(text: "jjj fff", style: a).fullImage), 0, "왼쪽 맞춤 j + 외곽선 20 px")
        var o = SubtitleStyle.default; o.outline = .default
        XCTAssertEqual(edgeAlpha(SubtitleRenderer.shared.raster(text: "ÅÉÎ jgy", style: o).fullImage), 0, "위·아래로 넘는 글자 + 외곽선")
        for (dx, dy) in [(0, 0), (1000, 1000), (-1000, -1000)] {
            var s = SubtitleStyle.default; s.shadow = .default; s.shadow!.blurTenths = SubtitleShadow.blurRange.upperBound; s.shadow!.alpha = 255
            s.shadow!.offsetXTenths = dx; s.shadow!.offsetYTenths = dy; s.alignment = .left
            XCTAssertEqual(edgeAlpha(SubtitleRenderer.shared.raster(text: "그림자 Shadow", style: s).fullImage), 0, "흐림 50 px 거리 \(dx), \(dy)")
        }
    }

    /// 그림 자르기(2026-10-23, 자막 그림 메모리): 칠한 부분만 잘라 낸 그림을 rect 크기로 되돌리면 자르기 전 그림과 바이트까지 같고,
    /// drawRect는 rect 안이며 16 화소 격자에 맞고, 그림 바이트가 줄어든다. 효과·정렬·화면 가장자리·키 큰 글(띠)·공백뿐·대체 글꼴을 본다.
    func testTightCropKeepsEveryDrawnPixel() {
        var cases: [(String, String, SubtitleStyle)] = []
        let d = SubtitleStyle.default
        cases.append(("plain", "두 줄 자막\n둘째 줄입니다", d))
        for al in [SubtitleStyle.Alignment.left, .right] { var s = d; s.alignment = al; cases.append(("align \(al)", "jjj fff 가나", s)) }
        var fx = d; fx.outline = .default; fx.shadow = .default; fx.background = .default; cases.append(("effects", "효과 Effects\n둘째", fx))
        var neg = fx; neg.shadow!.offsetXTenths = -400; neg.shadow!.offsetYTenths = -300; neg.shadow!.blurTenths = 200; cases.append(("shadow -", "그림자", neg))
        var edge = fx; edge.xMilli = 20_000; edge.yMilli = 60_000; cases.append(("edge", "가장자리 밖으로 나가는 글", edge))
        var tall = fx; tall.sizeTenths = 1200; cases.append(("tall band", (1...12).map(String.init).joined(separator: "\n"), tall))
        cases.append(("spaces", "   ", d))
        cases.append(("fallback", "日本語 한국어 ✓", d))
        var shrunk = 0, total = 0
        for (name, text, st) in cases {
            let cropped = SubtitleRenderer().raster(text: text, style: st)
            SubtitleRenderer.tightCropForTest = false
            let full = SubtitleRenderer().raster(text: text, style: st)
            SubtitleRenderer.tightCropForTest = true
            XCTAssertEqual(cropped.rect, full.rect, name); XCTAssertEqual(full.drawRect, full.rect, name)
            XCTAssertTrue(cropped.rect.contains(cropped.drawRect), name)
            XCTAssertEqual(Int(cropped.drawRect.minX - cropped.rect.minX) % 16, 0, name); XCTAssertEqual(Int(cropped.drawRect.minY - cropped.rect.minY) % 16, 0, name)
            XCTAssertEqual(bytes(cropped.fullImage), bytes(full.image), name)
            XCTAssertEqual(cropped.textBounds, full.textBounds, name); XCTAssertEqual(cropped.hitRect, full.hitRect, name)
            shrunk += cropped.image.bytesPerRow * cropped.image.height; total += full.image.bytesPerRow * full.image.height
        }
        XCTAssertLessThan(Double(shrunk), Double(total) * 0.6, "잘라 낸 그림이 확실히 작다 \(shrunk)/\(total)")
    }
}
