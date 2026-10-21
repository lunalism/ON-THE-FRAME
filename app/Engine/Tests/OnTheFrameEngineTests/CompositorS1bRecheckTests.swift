import AVFoundation
import CoreImage
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import VideoToolbox
import XCTest

/// 자막 S1b 재검토(2026-10-21, docs/SUBTITLE-DESIGN.md §16): 경계 규칙을 여러 배율·방향에서 가설별로 재고, 크기 조절 차이를 밝기·색차·가장자리로 나누며,
/// E2 실패 조건(4K, 재정렬 원본, 준비 → 500 ms → 0으로 정확 탐색 → 재생)에 맞춘 새 프로세스 첫 재생을 돈다. 계약(§13)은 그대로다.
extension CompositorEquivalenceTests {
    // MARK: 경계 문턱(기본 실행)

    /// 한 줄(가로: 출력 행 row, 세로: 출력 열 column)에서 원본 좌표 규칙으로 그려지는 화소 범위 → 가장자리(화소 경계 좌표).
    /// 규칙: 화소 가운데를 원본 좌표 (u, v)로 되돌려 0 ≤ u < W − farU, 0 ≤ v < H − farV이면 그린다.
    static func ruleEdges(_ t: CGAffineTransform, w: Double, h: Double, row: Int? = nil, column: Int? = nil, farU: Double, farV: Double) -> [Double] {
        let inv = t.inverted(), n = row != nil ? 1920 : 1080
        var first: Int?, last: Int?
        for p in 0..<n {
            let pt = row != nil ? CGPoint(x: Double(p) + 0.5, y: Double(row!) + 0.5) : CGPoint(x: Double(column!) + 0.5, y: Double(p) + 0.5)
            let s = pt.applying(inv)
            if s.x >= -1e-6, s.x < w - farU - 1e-6, s.y >= -1e-6, s.y < h - farV - 1e-6 { if first == nil { first = p }; last = p }
        }
        guard let first, let last else { return [] }
        return [Double(first), Double(last + 1)]
    }
    /// 한 줄에서 기하 포함(문턱 0) 화소 가운데 중 원본 먼 쪽 가장자리에 가장 가까운 것의 거리(원본 화소)
    static func farMargin(_ t: CGAffineTransform, w: Double, h: Double, row: Int? = nil, column: Int? = nil) -> Double {
        let inv = t.inverted(), n = row != nil ? 1920 : 1080
        var best = Double.infinity
        for p in 0..<n {
            let pt = row != nil ? CGPoint(x: Double(p) + 0.5, y: Double(row!) + 0.5) : CGPoint(x: Double(column!) + 0.5, y: Double(p) + 0.5)
            let s = pt.applying(inv)
            guard s.x >= -1e-6, s.x < w - 1e-6, s.y >= -1e-6, s.y < h - 1e-6 else { continue }
            // 줄을 따라 바뀌는 원본 축만 본다
            let along = row != nil ? (abs(t.a) > 1e-9 ? w - s.x : h - s.y) : (abs(t.d) > 1e-9 ? h - s.y : w - s.x)
            best = min(best, along)
        }
        return best
    }

    /// 경계 문턱 재측정: 먼 쪽 가장자리 여유 δ(줄 위 마지막 화소 가운데 ↔ 원본 끝, 원본 화소)를 0.1–0.4로 맞춘 경우들에서
    /// 기본 합성기의 네 가장자리를 재고 가설(원본 문턱 0·0.125·0.25·0.375, 출력 문턱 0.25 px)과 맞춘다.
    /// - 판 3배율(원본 화소당 0.60·1.125·1.35 출력 화소) × δ 4가지, 회전·뒤집기 표식 원본 4방향 × δ 2가지
    /// 계약(단언): 실험 합성기(기본 선택)의 가장자리가 기본과 같고(0.15 px), 표식 원본의 방향(흰 사분면 위치)이 같다.
    func testS1bEdgeThresholdAcrossScalesAndOrientations() async throws {
        let g = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.green.file))
        let b = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.blue.file))
        let orient: [(String, CGAffineTransform)] = [
            ("rot90", CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)),
            ("rot180", CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 640, ty: 360)),
            ("rot270", CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 640)),
            ("mirrorX", CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 640, ty: 0)),
        ]
        var markers: [String: MediaAsset] = [:]
        for (name, t) in orient { markers[name] = try await MediaProbe.inspect(try await Self.makeMarker(out, name: name, transform: t)) }
        struct Case { let name: String; let media: MediaAsset; let plate: Bool; let scale: Double; let delta: Double }
        var cases: [Case] = []
        for s in [0.4005, 0.75, 0.9] { for d in [0.1, 0.2, 0.3, 0.4] { cases.append(.init(name: "plate s\(s) δ\(d)", media: g, plate: true, scale: s, delta: d)) } }
        for (name, _) in orient { for d in [0.15, 0.35] { cases.append(.init(name: "\(name) s0.5 δ\(d)", media: markers[name]!, plate: false, scale: 0.5, delta: d)) } }
        let gm = (0.2126 * 40 + 0.7152 * 200 + 0.0722 * 60 + 0.2126 * 40 + 0.7152 * 60 + 0.0722 * 220) / 2
        let hyps: [(String, (Double) -> Double)] = [("src0", { _ in 0 }), ("src0.125", { _ in 0.125 }), ("src0.25", { _ in 0.25 }), ("src0.375", { _ in 0.375 }), ("out0.25", { 0.25 / $0 })]
        var hypHits = [Int](repeating: 0, count: hyps.count), total = 0
        var rows: [String] = [], bad: [String] = []
        let render = CGSize(width: 1920, height: 1080)
        for c in cases {
            let w = Double(c.media.naturalSize.width), h = Double(c.media.naturalSize.height)
            // δ를 맞출 이동 찾기(0.01 px 간격): 가로 줄은 x, 세로 줄은 y만 영향
            func transform(_ x: Double, _ y: Double) -> CGAffineTransform { CompositionPlanner.layerTransform(c.media, ClipTransform(scale: c.scale, x: x, y: y), render: render) }
            let k0 = transform(0, 0), r0 = CGRect(x: 0, y: 0, width: w, height: h).applying(k0)
            let row = Int(r0.midY + r0.height / 4), col = Int(r0.midX + r0.width / 4)
            var bx = 0.0, by = 0.0, ex = Double.infinity, ey = Double.infinity
            for j in 0..<100 {
                let o = 3.3 + Double(j) * 0.01
                let mx = Self.farMargin(transform(o, 0), w: w, h: h, row: row), my = Self.farMargin(transform(0, o), w: w, h: h, column: col)
                if abs(mx - c.delta) < ex { ex = abs(mx - c.delta); bx = o }
                if abs(my - c.delta) < ey { ey = abs(my - c.delta); by = o }
            }
            let t = transform(bx, by)
            let k = sqrt(abs(t.a * t.d - t.b * t.c))   // 원본 화소당 출력 화소
            var timeline: Timeline, media: [UUID: MediaAsset]
            if c.plate {
                let top = UUID()
                timeline = try Timeline().registering(b).registering(g).inserting(media: b.id).addingLane(.video, name: "G", id: top, outward: true)
                timeline = try timeline.placing(media: g.id, at: 0, videoLane: top, audioLane: nil)
                timeline = try timeline.settingTransform(clip: timeline.clips(inLane: top)[0].id, ClipTransform(scale: c.scale, x: bx, y: by))
                media = [g.id: g, b.id: b]
            } else {
                timeline = try Timeline().registering(c.media).inserting(media: c.media.id)
                timeline = try timeline.settingTransform(clip: timeline.clips[0].id, ClipTransform(scale: c.scale, x: bx, y: by))
                media = [c.media.id: c.media]
            }
            let plan = try await CompositionPlanner.plan(timeline, media: media)
            let mid = c.plate ? gm : 30.0
            // 판: 초록·파랑 밝기 가운데를 지나는 곳. 표식(검정 위): 그려진 화소 범위(밝기 > 8) — 원본 가장자리 줄이 어두우면(아래 기록)
            // 가운데 지남이 화소 안쪽에 떨어지므로, 가설(어느 화소를 그리는가)과 맞추려면 그려진 범위를 본다.
            func measure(_ f: FrameCompare.Frame) -> [Double] {
                if !c.plate {
                    let hx = (0..<1920).filter { Self.luma(f, $0, row) > 8 }, vy = (0..<1080).filter { Self.luma(f, col, $0) > 8 }
                    guard let a = hx.first, let b = hx.last, let u = vy.first, let v = vy.last else { return [] }
                    return [Double(a), Double(b + 1), Double(u), Double(v + 1)]
                }
                let hz = Self.crossings(f, row: row, mid: mid), vt = Self.crossings(f, column: col, mid: mid)
                guard hz.count >= 2, vt.count >= 2 else { return [] }
                return [hz.first!, hz.last!, vt.first!, vt.last!]
            }
            let df = try await firstFrame(plan.composition, plan.videoComposition)
            let ef = try await firstFrame(plan.composition, try ExperimentalComposition.videoComposition(from: plan.videoComposition))
            let d = measure(df), e = measure(ef)
            var hypStr: [String] = []
            for (i, hy) in hyps.enumerated() {
                let th = hy.1(k)
                let p = Self.ruleEdges(t, w: w, h: h, row: row, farU: th, farV: th) + Self.ruleEdges(t, w: w, h: h, column: col, farU: th, farV: th)
                let hit = d.count == 4 && p.count == 4 && (0..<4).allSatisfy { abs(d[$0] - p[$0]) <= 0.15 }
                if hit { hypHits[i] += 1 }
                hypStr.append("\(hy.0)\(hit ? "✓" : "✗")")
            }
            total += 1
            func f(_ v: [Double]) -> String { v.isEmpty ? "unmeasured" : v.map { String(format: "%.3f", $0) }.joined(separator: " ") }
            var orientNote = ""
            if !c.plate {
                // 방향: 표식 사각형 네 사분면 가운데의 밝기(흰 235 / 회색 60) — 기본·실험·손 계산(원본 왼쪽 위 사분면이 흰색)
                let r = CGRect(x: 0, y: 0, width: w, height: h).applying(t)
                let q = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { CGPoint(x: r.minX + r.width * $0.0, y: r.minY + r.height * $0.1) }
                func pat(_ fr: FrameCompare.Frame) -> String { q.map { Self.luma(fr, Int($0.x), Int($0.y)) > 150 ? "W" : "g" }.joined() }
                let white = CGPoint(x: w / 4, y: h / 4).applying(t)
                let hand = q.map { abs($0.x - white.x) < r.width / 4 && abs($0.y - white.y) < r.height / 4 ? "W" : "g" }.joined()
                // 가장자리 화소 밝기(기본·실험, 가로 줄 첫·끝 화소, 세로 줄 첫·끝 화소)와 원본 디코딩 가장자리 줄 평균 밝기(행 0, 끝 행, 열 0, 끝 열)
                func edgePix(_ fr: FrameCompare.Frame) -> String {
                    guard d.count == 4 else { return "-" }
                    return [Self.luma(fr, Int(d[0]), row), Self.luma(fr, Int(d[1]) - 1, row), Self.luma(fr, col, Int(d[2])), Self.luma(fr, col, Int(d[3]) - 1)]
                        .map { String(format: "%.0f", $0) }.joined(separator: "/")
                }
                orientNote = " | quadrants(TL TR BL BR) hand \(hand) default \(pat(df)) experimental \(pat(ef)) | edge pixel luma default \(edgePix(df)) experimental \(edgePix(ef)) | source edge lines \(try await Self.sourceEdgeLines(c.media))"
                if pat(df) != pat(ef) || pat(df) != hand { bad.append("\(c.name) orientation default \(pat(df)) experimental \(pat(ef)) hand \(hand)") }
            }
            rows.append(String(format: "%@ (k %.4f, x %.2f y %.2f, δ row %.3f col %.3f): default %@ | experimental %@ | %@",
                               c.name, k, bx, by, Self.farMargin(t, w: w, h: h, row: row), Self.farMargin(t, w: w, h: h, column: col),
                               f(d), f(e), hypStr.joined(separator: " ")) + orientNote)
            if d.count == 4, e.count == 4 { for i in 0..<4 where abs(d[i] - e[i]) > 0.15 { bad.append("\(c.name) edge \(i): default \(d[i]) experimental \(e[i])") } }
            else { bad.append("\(c.name): unmeasured default \(d.count) experimental \(e.count)") }
        }
        note("edge threshold sweep (left right top bottom):\n  " + rows.joined(separator: "\n  "))
        note("hypotheses matching all four default edges: " + zip(hyps, hypHits).map { "\($0.0.0) \($0.1)/\(total)" }.joined(separator: ", "))
        note("contract (experimental vs default): \(bad.isEmpty ? "all edges and orientations match" : "\(bad.count) differ: \(bad.prefix(8))")")
        XCTAssertTrue(bad.isEmpty, "\(bad.prefix(8))")
    }

    /// 원본 첫 프레임(디코딩, BGRA)의 가장자리 줄 평균 밝기: 행 0 / 끝 행 / 열 0 / 끝 열 (회전 전 원본 좌표)
    static func sourceEdgeLines(_ m: MediaAsset) async throws -> String {
        let asset = AVURLAsset(url: m.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return "-" }
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        r.add(o)
        guard r.startReading(), let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return "-" }
        defer { r.cancelReading() }
        let f = FrameCompare.copy(pb)
        func mean(_ pts: [(Int, Int)]) -> String { String(format: "%.0f", pts.map { luma(f, $0.0, $0.1) }.reduce(0, +) / Double(pts.count)) }
        return [mean((0..<f.width).map { ($0, 0) }), mean((0..<f.width).map { ($0, f.height - 1) }),
                mean((0..<f.height).map { (0, $0) }), mean((0..<f.height).map { (f.width - 1, $0) })].joined(separator: "/")
    }

    /// 표식 원본(640×360, 원본 왼쪽 위 1/4 흰색 235·나머지 회색 60), 표시 변형 transform. 30프레임.
    static func makeMarker(_ dir: URL, name: String, transform: CGAffineTransform) async throws -> URL {
        let url = dir.appendingPathComponent("marker-\(name)-\(UUID().uuidString.prefix(6)).mp4")
        try await writePattern(url, w: 640, h: 360, frames: 30, transform: transform) { x, y in
            let v: UInt8 = (x < 320 && y < 180) ? 235 : 60; return (v, v, v)
        }
        return url
    }

    // MARK: 크기 조절 차이 나누기(선택 실행 진단)

    /// 밝기(Y)·색차(Cb, Cr) 차이를 레이어 안쪽(평평·세부)과 레이어 가장자리 띠(3 px)로 나눈다. BT.709 계수, 2화소 간격 표본.
    static func splitStats(_ a: FrameCompare.Frame, _ b: FrameCompare.Frame, layer: CGRect) -> String {
        struct Acc { var n = 0, yMax = 0.0, ySum = 0.0, ySE = 0.0, cMax = 0.0, cSum = 0.0
            mutating func add(_ dy: Double, _ dc: Double) { n += 1; yMax = max(yMax, abs(dy)); ySum += abs(dy); ySE += dy * dy; cMax = max(cMax, dc); cSum += dc }
            var s: String { n == 0 ? "n 0" : String(format: "n %d Y max %.1f mean %.2f PSNR %.1f dB | C max %.1f mean %.2f", n, yMax, ySum / Double(n),
                                                     ySE == 0 ? 99 : 10 * log10(255 * 255 / (ySE / Double(n))), cMax, cSum / Double(n)) }
        }
        func ycc(_ f: FrameCompare.Frame, _ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * f.width + x) * 4
            let r = Double(f.bgra[i + 2]), g = Double(f.bgra[i + 1]), bl = Double(f.bgra[i])
            let yy = 0.2126 * r + 0.7152 * g + 0.0722 * bl
            return (yy, (bl - yy) / 1.8556, (r - yy) / 1.5748)
        }
        var flat = Acc(), detail = Acc(), band = Acc(), outside = Acc()
        let inner = layer.insetBy(dx: 3, dy: 3), outer = layer.insetBy(dx: -3, dy: -3)
        for y in stride(from: 2, to: a.height - 2, by: 2) { for x in stride(from: 2, to: a.width - 2, by: 2) {
            let (ya, ba, ra) = ycc(a, x, y), (yb, bb, rb) = ycc(b, x, y)
            let dy = ya - yb, dc = max(abs(ba - bb), abs(ra - rb))
            let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
            if inner.contains(p) {
                let l0 = ya
                let isFlat = [(x - 2, y), (x + 2, y), (x, y - 2), (x, y + 2)].allSatisfy { abs(ycc(a, $0.0, $0.1).0 - l0) <= 2 }
                if isFlat { flat.add(dy, dc) } else { detail.add(dy, dc) }
            } else if outer.contains(p) { band.add(dy, dc) } else { outside.add(dy, dc) }
        } }
        return "interior flat [\(flat.s)] | interior detail [\(detail.s)] | layer-edge band [\(band.s)] | outside [\(outside.s)]"
    }

    /// 크기 조절 차이 나누기(선택 실행 진단, OTF_S1B_DIAG=1):
    /// - 무늬 두 가지: 회색만(색차 일정, 밝기 필터 모양만 남김) / 색 무늬(S1b와 같은 칸 구성)
    /// - 경우 셋: 확대 1.5배 화면 가득(1280×720), 축소 0.75 정수 사각형(1920×1080), 축소 40.05% 소수 위치(1280×720)
    /// - 조건 둘: 그대로 / 두 videoComposition 모두 출력 색 속성을 BT.709로 고정(출력 버퍼 색 첨부를 맞춘 비교)
    /// - 정수 사각형 두 경우는 원본 프레임을 VTPixelTransferSession으로 그 크기 BGRA로 바꿔 놓은 참조와도 비교한다(기본 합성기의 크기 조절 경로 가설)
    /// 같은 오프라인 리더(BGRA)로 첫 표본을 읽고, 표본 시각·출력 색 첨부를 함께 적는다. 판정 없이 기록만 한다.
    func testS1bResamplingSeparationDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_S1B_DIAG"] == "1", "진단 실행은 OTF_S1B_DIAG=1일 때만")
        func gray(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (UInt8, UInt8, UInt8) {
            let q = x * 4 / w, r = y * 2 / h
            let v: UInt8
            switch (q, r) {
            case (0, 0): v = x % 2 == 0 ? 220 : 30
            case (1, 0): v = (x / 2) % 2 == 0 ? 200 : 50
            case (2, 0): v = (y / 3) % 2 == 0 ? 230 : 20
            case (3, 0): v = ((x / 8) + (y / 8)) % 2 == 0 ? 235 : 16
            case (0, 1): v = UInt8(16 + (x % (w / 4)) * 219 / (w / 4))
            case (1, 1): v = ((x + y) / 3) % 2 == 0 ? 210 : 40
            case (2, 1): v = 128
            default: v = (x * y) % 7 == 0 ? 235 : 16
            }
            return (v, v, v)
        }
        func color(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (UInt8, UInt8, UInt8) {
            let q = x * 4 / w, r = y * 2 / h
            switch (q, r) {
            case (0, 0): return (x / 2) % 2 == 0 ? (230, 40, 40) : (40, 40, 230)
            case (1, 0): return (y / 4) % 2 == 0 ? (240, 240, 40) : (20, 20, 120)
            case (2, 0): return (x % 2 == 0) ? (60, 200, 60) : (200, 60, 200)
            case (3, 0): return (200, 60, 60)
            case (0, 1): let v = UInt8(y * 255 / h); return (255 - v, v, 128)
            case (1, 1): return ((x / 6) + (y / 6)) % 2 == 0 ? (250, 120, 0) : (0, 120, 250)
            case (2, 1): return (60, 180, 90)
            default: return (50, 70, 200)
            }
        }
        var rows: [String] = []
        for (pname, pix) in [("gray", gray), ("color", color)] as [(String, (Int, Int, Int, Int) -> (UInt8, UInt8, UInt8))] {
            // 제품은 긴 변 1920을 넘는 원본을 받지 않으므로(M1 범위) 축소는 1920×1080 원본에 배율 0.75(정수 사각형 240,135 1440×810)로 만든다
            let s1 = out.appendingPathComponent("rs-\(pname)-1280.mp4"), s2 = out.appendingPathComponent("rs-\(pname)-1920.mp4")
            try await Self.writePattern(s1, w: 1280, h: 720, frames: 2) { pix($0, $1, 1280, 720) }
            try await Self.writePattern(s2, w: 1920, h: 1080, frames: 2) { pix($0, $1, 1920, 1080) }
            let m1 = try await MediaProbe.inspect(s1), m2 = try await MediaProbe.inspect(s2)
            let cases: [(String, MediaAsset, ClipTransform?, URL, CGRect?)] = [
                ("up1.5 full", m1, nil, s1, CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                ("down0.75 integer rect", m2, ClipTransform(scale: 0.75, x: 0, y: 0), s2, CGRect(x: 240, y: 135, width: 1440, height: 810)),
                ("down0.4005 x400.5 y-200.25", m1, ClipTransform(scale: 0.4005, x: 400.5, y: -200.25), s1, nil)]
            for (cname, m, x, url, vtRect) in cases {
                var t = try Timeline().registering(m).inserting(media: m.id)
                if let x { t = try t.settingTransform(clip: t.clips[0].id, x) }
                let plan = try await CompositionPlanner.plan(t, media: [m.id: m])
                let layer = CompositionPlanner.displayRect(m, t.clips[0].effectiveTransform, render: CGSize(width: 1920, height: 1080))
                for pinned in [false, true] {
                    func pin(_ vc: AVVideoComposition) -> AVVideoComposition {
                        guard pinned else { return vc }
                        let mv = vc.mutableCopy() as! AVMutableVideoComposition
                        mv.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2; mv.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2; mv.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
                        return mv.copy() as! AVVideoComposition
                    }
                    let (dr, dout) = try await Self.reader(plan.composition, pin(plan.videoComposition))
                    let (er, eout) = try await Self.reader(plan.composition, pin(try ExperimentalComposition.videoComposition(from: plan.videoComposition)))
                    guard let dsb = dout.copyNextSampleBuffer(), let dpb = CMSampleBufferGetImageBuffer(dsb),
                          let esb = eout.copyNextSampleBuffer(), let epb = CMSampleBufferGetImageBuffer(esb) else { XCTFail("frames \(cname)"); continue }
                    let d = FrameCompare.copy(dpb), e = FrameCompare.copy(epb)
                    let tag = "\(pname) \(cname) \(pinned ? "pinned709" : "as-is")"
                    rows.append("\(tag) pts default \(CMSampleBufferGetPresentationTimeStamp(dsb).seconds) experimental \(CMSampleBufferGetPresentationTimeStamp(esb).seconds) | attachments default [\(Self.colorTags(dpb))] experimental [\(Self.colorTags(epb))]")
                    rows.append("\(tag) default vs experimental: " + Self.splitStats(d, e, layer: layer))
                    if !pinned {
                        // 색차 가설: 원본을 YCbCr로 받는 실험 합성기
                        let (yr, yout) = try await Self.reader(plan.composition, try ExperimentalComposition.videoComposition(from: plan.videoComposition, options: .init(ycbcrSources: true)))
                        if let ysb = yout.copyNextSampleBuffer(), let ypb = CMSampleBufferGetImageBuffer(ysb) {
                            rows.append("\(tag) default vs experimental(YCbCr sources): " + Self.splitStats(d, FrameCompare.copy(ypb), layer: layer))
                        } else { rows.append("\(tag) experimental(YCbCr sources): no frame \(String(describing: yr.error))") }
                        yr.cancelReading()
                    }
                    if let vtRect, !pinned {
                        for mode in [nil, kVTDownsamplingMode_Average] as [CFString?] {
                            guard let v = try await Self.vtReference(url, mode: mode, rect: vtRect) else { rows.append("\(tag) VT reference: unavailable"); continue }
                            let mname = mode == nil ? "VT default" : "VT average"
                            rows.append("\(tag) default vs \(mname): " + Self.splitStats(d, v, layer: layer))
                            rows.append("\(tag) experimental vs \(mname): " + Self.splitStats(e, v, layer: layer))
                        }
                    }
                    dr.cancelReading(); er.cancelReading()
                }
            }
        }
        // SD 원본(640×480 빨강 판, 색 첨부 없음 → 기본 합성기가 SMPTE-C/601로 내는 것을 S1b에서 관찰): 그대로 / 709 고정에서 출력 색 첨부와 판 안쪽 색
        let red = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.red43.file))
        let rt = try Timeline().registering(red).inserting(media: red.id)
        let rplan = try await CompositionPlanner.plan(rt, media: [red.id: red])
        for pinned in [false, true] {
            func pin(_ vc: AVVideoComposition) -> AVVideoComposition {
                guard pinned else { return vc }
                let mv = vc.mutableCopy() as! AVMutableVideoComposition
                mv.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2; mv.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2; mv.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
                return mv.copy() as! AVVideoComposition
            }
            var cells: [String] = []
            for (which, vc) in [("default", pin(rplan.videoComposition)), ("experimental", pin(try ExperimentalComposition.videoComposition(from: rplan.videoComposition)))] {
                let (r, o) = try await Self.reader(rplan.composition, vc)
                guard let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { cells.append("\(which) no frame"); continue }
                let f = FrameCompare.copy(pb), i = (540 * f.width + 960) * 4
                cells.append("\(which) centre BGR [\(f.bgra[i]),\(f.bgra[i + 1]),\(f.bgra[i + 2])] attachments [\(Self.colorTags(pb))]")
                r.cancelReading()
            }
            rows.append("SD red plate 640x480 (source tags \(red.url.lastPathComponent)) \(pinned ? "pinned709" : "as-is"): " + cells.joined(separator: " | ") + " | plate value RGB (220,40,40)")
        }
        // 섞인 색 공간: 아래 SD 빨강 판(화면 가득) + 위 HD 초록 판(40.05%). 오프라인 버퍼(색 첨부 포함)와, 두 합성기로 각각 내보낸 H.264를 디코딩한 값
        let gp = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.green.file))
        let topLane = UUID()
        var mt = try Timeline().registering(red).registering(gp).inserting(media: red.id).addingLane(.video, name: "G", id: topLane, outward: true)
        mt = try mt.placing(media: gp.id, at: 0, videoLane: topLane, audioLane: nil)
        mt = try mt.settingTransform(clip: mt.clips(inLane: topLane)[0].id, ClipTransform(scale: 0.4005, x: 0, y: 0))
        let mplan = try await CompositionPlanner.plan(mt, media: [red.id: red, gp.id: gp])
        func px(_ f: FrameCompare.Frame, _ x: Int, _ y: Int) -> String { let i = (y * f.width + x) * 4; return "[\(f.bgra[i]),\(f.bgra[i + 1]),\(f.bgra[i + 2])]" }
        var mcells: [String] = []
        for (which, vc) in [("default", mplan.videoComposition), ("experimental", try ExperimentalComposition.videoComposition(from: mplan.videoComposition))] {
            let (r, o) = try await Self.reader(mplan.composition, vc)
            if let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
                let f = FrameCompare.copy(pb)
                mcells.append("\(which) offline green \(px(f, 960, 540)) red \(px(f, 400, 100)) attachments [\(Self.colorTags(pb))]")
            }
            r.cancelReading()
        }
        let (de, ee) = try await exportBoth(mplan, sources: [red, gp], frames: [0, 45], tag: "mixed-color")
        for (which, fr) in [("default", de), ("experimental", ee)] {
            if let f = fr[45] { mcells.append("\(which) export frame 45 green \(px(f, 960, 540)) red \(px(f, 400, 100))") }
        }
        rows.append("mixed SD bottom + HD top (plate values BGR green [60,200,40] red [40,40,220]): " + mcells.joined(separator: " | "))
        note("resampling separation (offline reader BGRA buffers, 2-px sampled, Y/C = BT.709 from RGB):\n  " + rows.joined(separator: "\n  "))
    }

    /// 원본 첫 프레임(420v로 디코딩) → VTPixelTransferSession → rect 크기 BGRA(출력 색 첨부 BT.709) → 검정 1920×1080의 rect(정수)에 놓음
    static func vtReference(_ url: URL, mode: CFString?, rect: CGRect) async throws -> FrameCompare.Frame? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        r.add(o)
        guard r.startReading(), let sb = o.copyNextSampleBuffer(), let src = CMSampleBufferGetImageBuffer(sb) else { return nil }
        defer { r.cancelReading() }
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else { return nil }
        defer { VTPixelTransferSessionInvalidate(session) }
        if let mode { VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DownsamplingMode, value: mode) }
        var dst: CVPixelBuffer?, full: CVPixelBuffer?
        let rw = Int(rect.width), rh = Int(rect.height), rx = Int(rect.minX), ry = Int(rect.minY)
        CVPixelBufferCreate(nil, rw, rh, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &dst)
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &full)
        guard let dst, let full else { return nil }
        ExperimentalCompositor.tagBT709(dst)
        guard VTPixelTransferSessionTransferImage(session, from: src, to: dst) == noErr else { return nil }
        CVPixelBufferLockBaseAddress(full, []); CVPixelBufferLockBaseAddress(dst, .readOnly)
        let fb = CVPixelBufferGetBaseAddress(full)!.assumingMemoryBound(to: UInt8.self), fr = CVPixelBufferGetBytesPerRow(full)
        let db = CVPixelBufferGetBaseAddress(dst)!.assumingMemoryBound(to: UInt8.self), dr = CVPixelBufferGetBytesPerRow(dst)
        for y in 0..<1080 { for x in 0..<1920 { let i = y * fr + x * 4; fb[i] = 0; fb[i + 1] = 0; fb[i + 2] = 0; fb[i + 3] = 255 } }
        for y in 0..<rh { memcpy(fb + (ry + y) * fr + rx * 4, db + y * dr, rw * 4) }
        CVPixelBufferUnlockBaseAddress(dst, .readOnly); CVPixelBufferUnlockBaseAddress(full, [])
        return FrameCompare.copy(full)
    }

    // MARK: E2 실패 조건에 맞춘 새 프로세스 첫 재생(선택 실행 진단)

    /// E2 조건(OTF_S1B_E2=experimental|experimental-track|default): E2의 4K 재정렬 원본(src-A/B/C-3840x2160-30p-v2, 실험 산출물 그대로 읽기만),
    /// E2 편집 순서(10 s, 컷 3개), 클립 소리·음악 트랙, 렌더 3840×2160, 프레임 타이밍 frameDuration(실험 합성기 설계 그대로) 또는 원본 트랙(experimental-track).
    /// 순서는 E2 diag-fresh와 같다: 준비 → 500 ms → 0으로 정확 탐색 → 재생(끝까지). 창(AVPlayerLayer)은 없다(E2와 다름).
    /// 기록: 준비 직후 항목 시각, 요청 차례(앞 30), 요청마다 받은 원본 movie time = 요청 시각인지(원본이 30 fps CFR이라 같아야 함),
    /// 비디오 출력이 내준 프레임의 원본 코드(E2Metrics) = 편집 순서 기대값인지. 프로세스마다 한 번만 돌린다.
    @MainActor func testS1bE2MatchedFirstPlayback() async throws {
        let mode = ProcessInfo.processInfo.environment["OTF_S1B_E2"] ?? ""
        try XCTSkipUnless(["experimental", "experimental-track", "default"].contains(mode), "진단 실행은 OTF_S1B_E2=experimental|experimental-track|default일 때만")
        Spec4K.configure(.uhd)
        defer { Spec4K.configure(.fhd) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let e2fx = repo.appendingPathComponent("experiments/e2-4k/artifacts/fixtures")
        var urls: [String: URL] = [:]
        for s in SourceVideoSpec.all {
            let u = e2fx.appendingPathComponent(s.fileName)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: u.path), "E2 fixture \(s.fileName) 없음(만들지 않음)")
            urls[s.key] = u
        }
        let music = e2fx.appendingPathComponent(MusicFixture.fileName)
        let tl = try EditTimeline.e2Experiment()
        let comp = AVMutableComposition()
        let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let mt = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        var assets: [AVURLAsset] = []
        for s in tl.segments {
            let a = AVURLAsset(url: urls[s.source]!); assets.append(a)
            let v = try await a.loadTracks(withMediaType: .video).first!, au = try await a.loadTracks(withMediaType: .audio).first!
            let range = CMTimeRange(start: Spec4K.frameTime(s.sourceIn), duration: Spec4K.frameTime(s.length))
            try vt.insertTimeRange(range, of: v, at: Spec4K.frameTime(s.start))
            try ct.insertTimeRange(range, of: au, at: Spec4K.frameTime(s.start))
        }
        let ma = AVURLAsset(url: music); assets.append(ma)
        let placement = MusicPlacement.e2, mStart = CMTime(value: CMTimeValue(placement.timelineStartMs), timescale: 1000)
        mt.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: mStart))
        try mt.insertTimeRange(CMTimeRange(start: CMTime(value: CMTimeValue(placement.sourceInMs), timescale: 1000), duration: CMTime(value: CMTimeValue(placement.durationMs), timescale: 1000)),
                               of: try await ma.loadTracks(withMediaType: .audio).first!, at: mStart)
        let frozen = comp.copy() as! AVComposition
        let base = AVMutableVideoComposition()
        base.renderSize = CGSize(width: 3840, height: 2160); base.frameDuration = Spec4K.frameDuration
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: tl.duration)
        ins.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: frozen.track(withTrackID: vt.trackID)!)
        li.setTransform(.identity, at: .zero)
        ins.layerInstructions = [li]
        base.instructions = [ins]
        let log = ExperimentalCompositorLog()
        var vc: AVVideoComposition = base.copy() as! AVVideoComposition
        if mode != "default" {
            vc = try ExperimentalComposition.videoComposition(from: vc, diagnostics: log)
            if mode == "experimental-track" {
                let mv = vc.mutableCopy() as! AVMutableVideoComposition
                mv.sourceTrackIDForFrameTiming = vt.trackID
                vc = mv.copy() as! AVVideoComposition
            }
        }
        let item = AVPlayerItem(asset: frozen)
        item.videoComposition = vc
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        let deadline = Date().addingTimeInterval(15)
        while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        let readyTime = item.currentTime()
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        let frames = Int((tl.duration.seconds * 30).rounded())
        var shown: [(Int, String, Bool)] = [], endHold: Set<String> = []
        let stop = Date().addingTimeInterval(tl.duration.seconds + 1.5)
        while Date() < stop {
            let it = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: it) {
                var disp = CMTime.invalid
                if let pb = output.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: &disp), disp.isNumeric, let m = E2Metrics.measure(pb) {
                    let k = Int((disp.seconds * 30).rounded())
                    let got = "\(m.sourceKey)\(m.sourceFrame)"
                    if k >= frames { endHold.insert("\(k):\(got)"); continue }
                    let want = tl.sourceFrame(at: k).map { "\($0.source)\($0.frame)" } ?? "?"
                    shown.append((k, got + (got == want ? "" : "≠\(want)"), got == want))
                }
            }
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        player.pause(); player.replaceCurrentItem(with: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        let bad = shown.filter { !$0.2 }
        var summary = "E2-matched first playback (\(mode)): ready item time \(readyTime.value)/\(readyTime.timescale) | shown \(shown.count) of \(frames) mismatched \(bad.count) \(bad.prefix(5).map { "\($0.0):\($0.1)" }) | first shown \(shown.prefix(4).map { "\($0.0):\($0.1)" }) | end hold \(endHold.sorted())"
        if mode != "default" {
            let s = log.snapshot
            let reqFrames = s.entries.map { Int(($0.time.seconds * 30).rounded()) }
            let firstSet = Set(reqFrames.filter { $0 < 30 })
            let missingFirst30 = (0..<30).filter { !firstSet.contains($0) }
            var stale: [String] = []
            for e in s.entries { for src in e.sources { if let mt = src.movieTime, abs((mt - e.time).seconds) > 0.0005 { stale.append(String(format: "t%d got %.4f", Int((e.time.seconds * 30).rounded()), mt.seconds)) } } }
            let t0 = s.entries.first?.received ?? 0
            let timing = s.entries.prefix(6).map { String(format: "t%d recv %.0f ms render %.0f ms", Int(($0.time.seconds * 30).rounded()), ($0.received - t0) * 1000, ($0.rendered - $0.received) * 1000) }
            let slow = s.entries.map { $0.rendered - $0.received }.sorted()
            summary += " | first requests \(timing) | request→rendered median \(String(format: "%.1f", slow[slow.count / 2] * 1000)) ms max \(String(format: "%.1f", (slow.last ?? 0) * 1000)) ms"
            summary += " | requests \(s.entries.count) first order \(reqFrames.prefix(8)) missing in first 30 \(missingFirst30) | source movie time ≠ request time \(stale.count) \(stale.prefix(5)) | outcomes finished \(s.outcomes.filter { $0 == .finished }.count) cancelled \(s.outcomes.filter { $0 == .cancelled }.count) failed \(s.outcomes.filter { $0 == .failed }.count) | cancelAll observed via cancelled outcomes only"
            XCTAssertTrue(stale.isEmpty, "stale source frames \(stale.prefix(5))")
            checkSources(log, "E2-matched \(mode)")
        }
        note(summary)
        withExtendedLifetime(assets) {}
        XCTAssertTrue(bad.isEmpty, "mismatched shown frames \(bad.prefix(5))")
    }
}
