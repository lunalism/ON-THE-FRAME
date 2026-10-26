import CoreGraphics
import Darwin
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// 공개 그리기 입구 SpectrumFrameRenderer(2026-10-26, SP-1A 3A-1 — docs/SPECTRUM-DESIGN.md §15.12).
/// 같은 입력에서 내부 SpectrumCanvas.render와 바이트가 같은지, 돌려준 프레임의 버퍼가 뒤의 그리기와 무관한지 본다. 모양 값은 시험 설정이다(D-S5).
final class SpectrumFrameRendererTests: XCTestCase {
    static let modes: [SpectrumItemStyle.Mode] = [.digital, .analog]
    static let sides: [SpectrumItemStyle.Sides] = [.above, .mirrored, .below]

    func style(_ m: SpectrumItemStyle.Mode, _ s: SpectrumItemStyle.Sides, bands: Int, start: (Int, Int) = (192_000, 540_000), end: (Int, Int) = (1_728_000, 540_000),
               maxHeight: Int = 480_000, thickness: Int = 3_000, rgba: (Int, Int, Int, Int) = (255, 255, 255, 255)) -> SpectrumItemStyle {
        var x = SpectrumItemStyle.provisionalDefault
        x.mode = m; x.sides = s; x.bands = bands
        x.startXMilli = start.0; x.startYMilli = start.1; x.endXMilli = end.0; x.endYMilli = end.1
        x.maxHeightMilli = maxHeight; x.thicknessMilli = thickness
        (x.red, x.green, x.blue, x.alpha) = rgba
        return x
    }
    /// 고정 씨앗 값(0~1)
    static func values(_ n: Int, seed: UInt64) -> [Float] {
        var g = seed
        return (0..<n).map { _ in g = g &* 6364136223846793005 &+ 1442695040888963407; return Float(g >> 40) / Float(1 << 24) }
    }
    static func bytes(_ i: CGImage) -> [UInt8] {
        let d = i.dataProvider!.data!
        return withExtendedLifetime(d) { [UInt8](UnsafeBufferPointer(start: CFDataGetBytePtr(d), count: CFDataGetLength(d))) }
    }
    /// 공개 결과와 내부 결과가 같은가(둘 다 nil, 또는 배치·바이트·놓을 사각형이 같음). 다르면 설명.
    static func difference(_ a: SpectrumRenderedFrame?, _ b: SpectrumFrameRaster?) -> String? {
        switch (a, b) {
        case (nil, nil): return nil
        case let (a?, b?):
            let x = a.image, y = b.image
            if (x.width, x.height, x.bytesPerRow, x.bitsPerPixel, x.bitsPerComponent) != (y.width, y.height, y.bytesPerRow, y.bitsPerPixel, y.bitsPerComponent) { return "layout" }
            if x.bitmapInfo != y.bitmapInfo || x.colorSpace?.name != y.colorSpace?.name { return "format" }
            if a.drawRect != b.drawRect { return "drawRect \(a.drawRect) vs \(b.drawRect)" }
            if a.canvasWidth != Int(b.canvas.width) || a.canvasHeight != Int(b.canvas.height) { return "canvas" }
            let p = bytes(x), q = bytes(y)
            if p != q { return "bytes differ at \(zip(p, q).filter { $0 != $1 }.count) of \(p.count)" }
            return nil
        default: return "nil mismatch \(a == nil) \(b == nil)"
        }
    }
    /// 공개 프레임에서 칠한 화소가 모두 그리기 범위(bounds)·캔버스 안인가 — 밖은 투명
    static func paintedOutside(_ f: SpectrumRenderedFrame, bounds: CGRect) -> Int {
        let px = bytes(f.image), bpr = f.image.bytesPerRow
        var n = 0
        for y in 0..<f.image.height {
            for x in 0..<f.image.width {
                let o = y * bpr + x * 4
                guard px[o] | px[o + 1] | px[o + 2] | px[o + 3] != 0 else { continue }
                let c = CGPoint(x: f.drawRect.minX + CGFloat(x) + 0.5, y: f.drawRect.minY + CGFloat(y) + 0.5)
                if !bounds.contains(c) || c.x >= CGFloat(f.canvasWidth) || c.y >= CGFloat(f.canvasHeight) { n += 1 }
            }
        }
        return n
    }

    /// 여섯 조합 × (모두 0, 무작위, 모두 1) × 밴드 1·64·1024, 1080p: 내부 그리기와 바이트가 같다. 범위 밖 투명.
    func testMatchesInternalRendererBytes() throws {
        let pub = try SpectrumFrameRenderer(width: 1920, height: 1080), ref = try SpectrumCanvas(width: 1920, height: 1080)
        var cases = 0, nils = 0
        for m in Self.modes { for s in Self.sides { for n in [1, 64, 1024] {
            for (name, v) in [("zero", [Float](repeating: 0, count: n)), ("rand", Self.values(n, seed: UInt64(n) &* 31 &+ 7)), ("one", [Float](repeating: 1, count: n))] {
                let st = style(m, s, bands: n)
                XCTAssertTrue(st.isValid, "\(m) \(s) \(n)")
                let a = try pub.render(bands: v, style: st), b = try ref.render(v, style: st.renderStyle)
                XCTAssertNil(Self.difference(a, b), "\(m) \(s) bands \(n) \(name)")
                if let a, let b { XCTAssertEqual(Self.paintedOutside(a, bounds: b.bounds), 0, "\(m) \(s) \(n) \(name) outside") }
                XCTAssertEqual(ref.paintedPixels(outside: b?.bounds ?? .null), 0, "internal canvas outside \(m) \(s) \(n) \(name)")
                if a == nil { nils += 1 }
                cases += 1
            }
        } } }
        XCTAssertEqual(cases, 54)
        XCTAssertEqual(nils, 9, "디지털 모두 0만 nil(위·거울·아래 × 밴드 1·64·1024)")
    }

    /// 가장자리 잘림·캔버스 전체 덮음·다른 캔버스 크기(16×16, 4K)·색: 내부와 같은 바이트, 범위 밖 투명
    func testClippingFullCoverAndCanvasSizes() throws {
        let v64 = Self.values(64, seed: 99), v1024 = [Float](repeating: 1, count: 1024)
        let cases: [(String, Int, Int, SpectrumItemStyle, [Float])] = [
            ("off left/right, near top", 1920, 1080, style(.analog, .mirrored, bands: 64, start: (-500_000, 20_000), end: (2_400_000, 20_000), maxHeight: 300_000, thickness: 12_000), v64),
            ("off bottom", 1920, 1080, style(.digital, .below, bands: 64, start: (0, 1_070_000), end: (1_920_000, 1_070_000), maxHeight: 200_000, thickness: 20_000), v64),
            ("diagonal", 1920, 1080, style(.digital, .above, bands: 64, start: (100_000, 1_000_000), end: (1_800_000, 100_000), thickness: 8_000, rgba: (10, 200, 40, 128)), v64),
            ("full cover", 1920, 1080, style(.digital, .mirrored, bands: 1024, start: (0, 540_000), end: (1_920_000, 540_000), maxHeight: 1_080_000, thickness: 64_000), v1024),
            ("tiny canvas", 16, 16, style(.analog, .above, bands: 64), v64),
            ("4K", 3840, 2160, style(.digital, .mirrored, bands: 64, rgba: (255, 0, 0, 200)), v64),
        ]
        for (name, w, h, st, v) in cases {
            let pub = try SpectrumFrameRenderer(width: w, height: h), ref = try SpectrumCanvas(width: w, height: h)
            let a = try pub.render(bands: v, style: st), b = try ref.render(v, style: st.renderStyle)
            XCTAssertNotNil(a, name)
            XCTAssertNil(Self.difference(a, b), name)
            if let a, let b {
                XCTAssertTrue(CGRect(x: 0, y: 0, width: w, height: h).contains(a.drawRect), "\(name) drawRect \(a.drawRect)")
                XCTAssertEqual(Self.paintedOutside(a, bounds: b.bounds), 0, name)
            }
            XCTAssertEqual(ref.paintedPixels(outside: b?.bounds ?? .null), 0, name)
            if name == "full cover" { XCTAssertEqual(a?.drawRect, CGRect(x: 0, y: 0, width: 1920, height: 1080), "전체 덮음 — 내부는 다시 쓰는 캔버스의 makeImage 경로") }
        }
    }

    /// 같은 입력을 되풀이하면 같은 바이트(A, B, A), 앞 프레임을 들고 있어도 바뀌지 않는다 — 잘라 낸 경로와 캔버스 전체 경로 둘 다
    func testReturnedFramesAreIndependentOfLaterRenders() throws {
        let r = try SpectrumFrameRenderer(width: 1920, height: 1080)
        let full = style(.digital, .mirrored, bands: 1024, start: (0, 540_000), end: (1_920_000, 540_000), maxHeight: 1_080_000, thickness: 64_000)
        let fullV = [Float](repeating: 1, count: 1024)
        let crop = style(.analog, .above, bands: 64), cropV = Self.values(64, seed: 5)
        let a = try XCTUnwrap(r.render(bands: fullV, style: full)), aBytes = Self.bytes(a.image)
        let b = try XCTUnwrap(r.render(bands: cropV, style: crop)), bBytes = Self.bytes(b.image)
        // 캔버스를 비우는 그리기(디지털 모두 0 → nil)와 다른 모양들을 여러 번
        XCTAssertNil(try r.render(bands: [Float](repeating: 0, count: 64), style: style(.digital, .mirrored, bands: 64)))
        for k in 0..<20 { _ = try r.render(bands: Self.values(64, seed: UInt64(k)), style: style(k % 2 == 0 ? .digital : .analog, .mirrored, bands: 64, rgba: (k * 10, 0, 255, 255))) }
        XCTAssertEqual(Self.bytes(a.image), aBytes, "전체 덮음 프레임이 뒤 그리기 뒤에도 그대로")
        XCTAssertEqual(Self.bytes(b.image), bBytes, "잘라 낸 프레임이 뒤 그리기 뒤에도 그대로")
        XCTAssertTrue(aBytes.contains { $0 != 0 })
        let a2 = try XCTUnwrap(r.render(bands: fullV, style: full)), b2 = try XCTUnwrap(r.render(bands: cropV, style: crop))
        XCTAssertEqual(Self.bytes(a2.image), aBytes); XCTAssertEqual(Self.bytes(b2.image), bBytes)
        XCTAssertEqual(a2.drawRect, a.drawRect); XCTAssertEqual(b2.drawRect, b.drawRect)
        // 두 프레임의 버퍼는 서로 다른 메모리: 각 이미지의 공급자 데이터가 다른 주소(공급자는 우리가 만든 불변 Data를 감쌈)
        // 같은 이미지에서 두 번 읽은 주소가 같아야 이 비교가 뜻이 있다(공급자가 읽을 때마다 복사하지 않고 그 Data를 돌려줌)
        XCTAssertEqual(CFDataGetBytePtr(a.image.dataProvider!.data!), CFDataGetBytePtr(a.image.dataProvider!.data!), "공급자 데이터 = 그 이미지의 버퍼")
        XCTAssertNotEqual(CFDataGetBytePtr(a.image.dataProvider!.data!), CFDataGetBytePtr(a2.image.dataProvider!.data!))
        XCTAssertNotEqual(CFDataGetBytePtr(a.image.dataProvider!.data!), CFDataGetBytePtr(b.image.dataProvider!.data!))
        // 다른 스레드에서 읽어도 같다(Sendable 값)
        let done = expectation(description: "other thread")
        let sent = a
        DispatchQueue.global().async { XCTAssertEqual(Self.bytes(sent.image), aBytes); done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    /// 복사 장치 자체(2026-10-26 고침 뒤 — 이미지 공급자가 아니라 원본 메모리에서 rect를 행마다 복사): 바뀔 수 있는 버퍼를 복사 없이 감싼 원본 이미지는
    /// 버퍼를 바꾸면 따라 바뀌지만(위험이 실제로 있음), ownedCopy 결과는 그대로다. 원점이 (0,0)이 아닌 rect·행 간격 > 폭에서 화소마다 다른 값으로 원점·간격을 본다.
    /// 위 독립성 시험은 이 OS에서 복사를 빼도 통과했다(음성 대조, §15.12) — 그래서 장치를 따로 본다.
    func testOwnedCopyDetachesFromMutableSource() throws {
        let w = 32, h = 8, bpr = w * 4
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bpr * h, alignment: 16)
        defer { buf.deallocate() }
        for i in 0..<(bpr * h) { buf.storeBytes(of: UInt8(truncatingIfNeeded: i &* 7 &+ 3), toByteOffset: i, as: UInt8.self) }
        let provider = try XCTUnwrap(CGDataProvider(dataInfo: nil, data: buf, size: bpr * h, releaseData: { _, _, _ in }))
        let src = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let rect = CGRect(x: 5, y: 3, width: 10, height: 4)
        let copy = try SpectrumFrameRenderer.ownedCopy(UnsafeRawPointer(buf), bytesPerRow: bpr, rect: rect)
        var expected: [UInt8] = []
        for y in 3..<7 { for x in 5..<15 { for c in 0..<4 { expected.append(UInt8(truncatingIfNeeded: (y * bpr + x * 4 + c) &* 7 &+ 3)) } } }
        let before = Self.bytes(copy)
        XCTAssertEqual(before, expected, "원점·행 간격·채널 순서 그대로")
        XCTAssertEqual(copy.width, 10); XCTAssertEqual(copy.height, 4); XCTAssertEqual(copy.bytesPerRow, 40)
        XCTAssertEqual(copy.bitmapInfo, src.bitmapInfo); XCTAssertEqual(copy.colorSpace?.name, src.colorSpace?.name)
        memset(buf, 0xA0, bpr * h)
        XCTAssertEqual(Self.bytes(src).first, 0xA0, "복사 없이 감싼 원본은 버퍼 변경을 본다")
        XCTAssertEqual(Self.bytes(copy), before, "복사본은 그대로")
        XCTAssertThrowsError(try SpectrumFrameRenderer.ownedCopy(UnsafeRawPointer(buf), bytesPerRow: bpr, rect: CGRect(x: 30, y: 0, width: 4, height: 1)), "행 밖 rect 거부")
    }

    /// 비트맵 할당 실패 대체 경로(2026-10-26 검토 지적): tightCrop가 자른 비트맵을 얻지 못하면 다시 쓰는 캔버스의 makeImage().cropping(행 띠)을 돌려준다.
    /// SubtitleRenderer.maxBitmapBytesForTest로 그 분기를 강제하고(들어갔는지 내부 래스터 모양으로 확인), 공개 결과가 화소까지 맞거나 명시적으로 실패하는지 본다.
    /// 성공했는데 화소가 틀리면(투명 포함) 실패. 기준은 보통 경로로 같은 입력을 그린 내부 캔버스 화소(직접 메모리 읽기 — CGImage 공급자에 기대지 않음).
    func testAllocationFallbackIsPixelCorrectOrFailsExplicitly() throws {
        // 원점에서 먼 곳(행 약 700–900, 열 약 192–1728)의 알아볼 수 있는 색 막대
        let st = style(.digital, .mirrored, bands: 64, start: (192_000, 800_000), end: (1_728_000, 800_000), maxHeight: 90_000, thickness: 6_000, rgba: (255, 64, 16, 255))
        let v = Self.values(64, seed: 42)
        let ref = try SpectrumCanvas(width: 1920, height: 1080)
        let normal = try XCTUnwrap(ref.render(v, style: st.renderStyle))
        XCTAssertGreaterThan(normal.drawRect.minX, 0, "보통 경로는 좁게 자름")
        XCTAssertEqual(ref.paintedPixels(outside: normal.drawRect), 0)
        func refPixel(_ x: Int, _ y: Int) -> UInt32 { ref.pixel(x: x, y: y) }
        var refPainted = 0
        for y in 0..<1080 { for x in 0..<1920 where refPixel(x, y) != 0 { refPainted += 1 } }
        XCTAssertGreaterThan(refPainted, 2_000, "기준 그림이 충분히 칠해짐")

        let r = try SpectrumFrameRenderer(width: 1920, height: 1080)
        let kept = try XCTUnwrap(r.render(bands: v, style: st)), keptBytes = Self.bytes(kept.image)
        XCTAssertNil(Self.difference(kept, normal), "보통 경로 = 내부 그리기")

        SubtitleRenderer.maxBitmapBytesForTest = 1_000
        var outcome = "not run"
        do {
            defer { SubtitleRenderer.maxBitmapBytesForTest = Int.max }
            // 분기에 들어갔는가: 내부 래스터가 전체 폭 행 띠(보통 경로의 좁은 자름이 아님)
            let probe = try SpectrumCanvas(width: 1920, height: 1080)
            let fb = try XCTUnwrap(probe.render(v, style: st.renderStyle))
            XCTAssertEqual(fb.drawRect.minX, 0); XCTAssertEqual(fb.drawRect.width, 1920); XCTAssertEqual(fb.image.width, 1920)
            XCTAssertGreaterThan(fb.drawRect.minY, 0, "자른 원점이 (0,0)이 아님"); XCTAssertLessThan(fb.image.height, 1080)
            if let d = fb.image.dataProvider?.data {
                print("SPECTRUM fallback internal image: \(fb.image.width)x\(fb.image.height) bpr \(fb.image.bytesPerRow) providerBytes \(CFDataGetLength(d)) (rows×bpr \(fb.image.height * fb.image.bytesPerRow)) drawRect \(fb.drawRect)")
            }
            do {
                let f = try XCTUnwrap(r.render(bands: v, style: st))
                let px = Self.bytes(f.image), bpr = f.image.bytesPerRow
                var wrong = 0, painted = 0
                for y in 0..<f.image.height {
                    for x in 0..<f.image.width {
                        let o = y * bpr + x * 4
                        let got = UInt32(px[o]) | UInt32(px[o + 1]) << 8 | UInt32(px[o + 2]) << 16 | UInt32(px[o + 3]) << 24
                        if got != refPixel(Int(f.drawRect.minX) + x, Int(f.drawRect.minY) + y) { wrong += 1 }
                        if got != 0 { painted += 1 }
                    }
                }
                outcome = "returned \(f.image.width)x\(f.image.height) at \(f.drawRect), wrong \(wrong), painted \(painted)/\(refPainted)"
                XCTAssertEqual(wrong, 0, "성공한 결과의 화소가 기준과 같아야 함")
                XCTAssertEqual(painted, refPainted, "칠한 화소를 모두 담음(투명 결과는 실패)")
            } catch let e as SpectrumRenderError {
                outcome = "threw \(e)"
            }
        }
        print("SPECTRUM fallback facade outcome: \(outcome)")
        XCTAssertEqual(SubtitleRenderer.maxBitmapBytesForTest, Int.max, "시험 장치 되돌림")
        XCTAssertEqual(Self.bytes(kept.image), keptBytes, "앞 프레임 그대로")
        let after = try r.render(bands: v, style: st)
        XCTAssertNil(Self.difference(after, normal), "대체 경로 뒤 다음 그리기 = 보통 경로")
    }

    /// 빈 결과의 실제 뜻: 그릴 범위가 없으면 nil, 범위는 있으나 칠한 화소가 없으면 투명 1×1(내부 의미 그대로)
    func testEmptyResultSemantics() throws {
        let r = try SpectrumFrameRenderer(width: 1920, height: 1080), ref = try SpectrumCanvas(width: 1920, height: 1080)
        let v = Self.values(64, seed: 3)
        // 범위 없음: 디지털 모두 0, 캔버스 밖 전체
        XCTAssertNil(try r.render(bands: [Float](repeating: 0, count: 64), style: style(.digital, .above, bands: 64)))
        let off = style(.analog, .above, bands: 64, start: (0, -5_000_000), end: (1_920_000, -5_000_000))
        XCTAssertNil(try r.render(bands: v, style: off)); XCTAssertNil(try ref.render(v, style: off.renderStyle))
        // 범위는 있으나 칠한 화소 없음: 알파 0
        let clear = style(.digital, .mirrored, bands: 64, rgba: (255, 255, 255, 0))
        let a = try XCTUnwrap(r.render(bands: v, style: clear))
        XCTAssertEqual(a.image.width, 1); XCTAssertEqual(a.image.height, 1); XCTAssertEqual(a.drawRect.size, CGSize(width: 1, height: 1))
        XCTAssertTrue(Self.bytes(a.image).prefix(4).allSatisfy { $0 == 0 }, "투명")
        XCTAssertNil(Self.difference(a, try ref.render(v, style: clear.renderStyle)))
        // 아날로그 밴드 1개(점 하나 경로): 내부와 같은 결과(관찰값 기록)
        let one = try r.render(bands: [0.5], style: style(.analog, .above, bands: 1))
        XCTAssertNil(Self.difference(one, try ref.render([0.5], style: style(.analog, .above, bands: 1).renderStyle)))
        print("SPECTRUM empty semantics: analog 1 band → \(one.map { "\($0.image.width)x\($0.image.height) at \($0.drawRect)" } ?? "nil")")
    }

    /// 잘못된 입력은 그리기 전에 던지고, 앞 프레임·다음 그리기에 흔적이 없다
    func testInvalidInputLeavesNoPartialResult() throws {
        let r = try SpectrumFrameRenderer(width: 1920, height: 1080)
        let st = style(.digital, .mirrored, bands: 64), v = Self.values(64, seed: 11)
        let a = try XCTUnwrap(r.render(bands: v, style: st)), aBytes = Self.bytes(a.image)
        var bad = st; bad.thicknessMilli = 0
        var badColor = st; badColor.red = 300
        var noBands = st; noBands.bands = 0
        var tooMany = st; tooMany.bands = 1025
        let attempts: [(String, [Float], SpectrumItemStyle)] = [
            ("count mismatch", Self.values(63, seed: 1), st), ("NaN", [Float.nan] + v.dropFirst(), st), ("> 1", [1.5] + v.dropFirst(), st), ("< 0", [-0.1] + v.dropFirst(), st),
            ("thickness 0", v, bad), ("color 300", v, badColor), ("bands 0", [], noBands), ("bands 1025", [Float](repeating: 0.5, count: 1025), tooMany),
        ]
        for (name, values, s) in attempts {
            XCTAssertThrowsError(try r.render(bands: values, style: s), name) { XCTAssertTrue($0 is SpectrumRenderError, name) }
        }
        XCTAssertEqual(Self.bytes(a.image), aBytes, "앞 프레임 그대로")
        let next = try r.render(bands: v, style: st), fresh = try SpectrumCanvas(width: 1920, height: 1080).render(v, style: st.renderStyle)
        XCTAssertNil(Self.difference(next, fresh), "실패 뒤 다음 그리기 = 새 캔버스 그리기")
        for (w, h) in [(15, 1080), (1920, 2161), (3841, 16), (0, 0)] {
            XCTAssertThrowsError(try SpectrumFrameRenderer(width: w, height: h), "\(w)x\(h)")
        }
    }

    /// 되풀이 그리기가 데이터를 쌓지 않는다: 그리기 하나 = 캔버스 하나, 놓으면 0개로 돌아감, 2000번 그려도 발자국이 크게 늘지 않음
    func testRepeatedRenderingRetainsNothing() throws {
        let before = SpectrumCanvas.liveCount
        var r: SpectrumFrameRenderer? = try SpectrumFrameRenderer(width: 1920, height: 1080)
        XCTAssertEqual(SpectrumCanvas.liveCount, before + 1)
        let st = style(.digital, .mirrored, bands: 64)   // 프레임마다 약 1536×976 BGRA ≈ 6 MB — 쌓이면 2000번에 수 GB
        for k in 0..<100 { autoreleasepool { _ = try? r!.render(bands: Self.values(64, seed: UInt64(k)), style: st) } }
        let m0 = Self.footprintMB()
        for k in 0..<2000 { autoreleasepool { _ = try? r!.render(bands: Self.values(64, seed: UInt64(k)), style: st) } }
        let m1 = Self.footprintMB()
        XCTAssertEqual(SpectrumCanvas.liveCount, before + 1, "되풀이해도 캔버스 하나")
        XCTAssertLessThan(m1 - m0, 64, "발자국 \(m0) → \(m1) MB")
        print("SPECTRUM facade repeat: footprint MB \(String(format: "%.1f", m0)) → \(String(format: "%.1f", m1)) after 2000 renders")
        r = nil
        XCTAssertEqual(SpectrumCanvas.liveCount, before, "놓으면 캔버스 없음")
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
