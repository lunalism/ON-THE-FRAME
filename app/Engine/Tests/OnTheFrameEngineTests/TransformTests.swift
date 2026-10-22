import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 영상 클립 크기·위치(A-015). 기대 사각형은 좌표계 정의에서 손으로 계산한 숫자다(OverlayJudge.expectedRect와도 대조).
final class TransformModelTests: XCTestCase {
    let ma = UUID(), mb = UUID()
    func base() throws -> Timeline {
        let refs = [MediaRef(id: ma, name: "a.mp4", path: "/m/a.mp4", frameCount: 100, hasAudio: true, size: 1, modifiedNs: 1, codec: "avc1", width: 1920, height: 1080),
                    MediaRef(id: mb, name: "b.mp4", path: "/m/b.mp4", frameCount: 60, hasAudio: true, size: 1, modifiedNs: 1, codec: "avc1", width: 640, height: 480)]
        return try Timeline(media: refs, mediaFrames: [ma: 100, mb: 60], mediaHasAudio: [ma: true, mb: true]).inserting(media: ma)
    }
    let t40 = ClipTransform(scalePermille: 400, offsetX: 400, offsetY: -200)

    func testSetValidateAndIdentity() throws {
        let t = try base()
        let v = t.clips[0].id, a = try XCTUnwrap(t.partner(of: v)).id
        let x = try t.settingTransform(clip: v, t40)
        XCTAssertEqual(x.clip(v)?.transform, t40)
        XCTAssertEqual(x.clip(a), t.clip(a))                                          // 연결된 소리: 시각·위치 그대로, 변형 없음
        XCTAssertThrowsError(try t.settingTransform(clip: a, t40)) { XCTAssertEqual($0 as? OnTheFrameEngine.EditError, .transformNotVideo) }
        XCTAssertThrowsError(try t.settingTransform(clip: v, ClipTransform(scalePermille: 5, offsetX: 0, offsetY: 0)))
        XCTAssertThrowsError(try t.settingTransform(clip: v, ClipTransform(scalePermille: 1000, offsetX: 8000, offsetY: 0)))
        XCTAssertNil(try x.settingTransform(clip: v, .identity).clip(v)?.transform)  // 기본값 = 변형 없음
        XCTAssertEqual(try x.settingTransform(clip: v, nil), t)
    }

    func testSplitMoveTrimPreserveAndUndo() throws {
        let b0 = try base(), v = b0.clips[0].id
        let t = try b0.settingTransform(clip: v, t40)
        let (l, r) = (UUID(), UUID())
        let s = try t.splitting(clip: v, atFrame: 40, newIDs: (l, r))
        XCTAssertEqual(s.clip(l)?.transform, t40); XCTAssertEqual(s.clip(r)?.transform, t40)
        XCTAssertTrue(s.audioClips.allSatisfy { $0.transform == nil })
        XCTAssertEqual(s.audioClips.map { [$0.start, $0.sourceIn, $0.length] }, [[0, 0, 40], [40, 40, 60]])   // 소리 시각 그대로
        let v2 = UUID()
        let moved = try s.addingLane(.video, name: "V2", id: v2).relocating(clip: r, lane: nil).unlinking(clip: r).relocating(clip: r, lane: v2)
        XCTAssertEqual(moved.clip(r)?.transform, t40)
        XCTAssertEqual(try s.moving(clip: r, toIndex: 0).clip(r)?.transform, t40)
        XCTAssertEqual(try s.trimmingEnd(clip: r, by: -10).clip(r)?.transform, t40)
        // 끌기 한 번 = 한 단계, Esc = 끌기 전
        var h = EditHistory(t)
        h.beginGesture()
        h.updateGesture(try t.settingTransform(clip: v, ClipTransform(scalePermille: 500, offsetX: 10, offsetY: 10)), focus: v)
        h.updateGesture(try t.settingTransform(clip: v, ClipTransform(scalePermille: 600, offsetX: 20, offsetY: 20)), focus: v)
        h.cancelGesture()
        XCTAssertEqual(h.timeline, t); XCTAssertFalse(h.canUndo)
        h.beginGesture()
        h.updateGesture(try t.settingTransform(clip: v, ClipTransform(scalePermille: 600, offsetX: 20, offsetY: 20)), focus: v)
        h.commitGesture()
        XCTAssertEqual(h.undoDepth, 1); h.undo(); XCTAssertEqual(h.timeline.clip(v)?.transform, t40)
    }

    func testProjectFileTransformsAndOlderFiles() throws {
        let b0 = try base(), v = b0.clips[0].id
        let t = try b0.settingTransform(clip: v, ClipTransform(scalePermille: 1234, offsetX: -567, offsetY: 89))
        let data = try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        let (back, doc) = try ProjectFile.decode(data)
        XCTAssertEqual(doc.version, ProjectFile.subtitleFreeVersion); XCTAssertEqual(back, t)
        XCTAssertEqual(back.clip(v)?.transform, ClipTransform(scalePermille: 1234, offsetX: -567, offsetY: 89))
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: " ", with: "")
        // 형식 4: 정수 격자(백만분율·1/1000 픽셀). 부동소수점을 쓰지 않는다.
        XCTAssertTrue(text.contains("\"scaleMicro\":1234000"), text); XCTAssertTrue(text.contains("\"offsetXMilli\":-567000"), text)
        XCTAssertFalse(text.contains("scalePermille")); XCTAssertFalse(text.contains("1234.")); XCTAssertFalse(text.contains("1.234"))
        // 변형 없는 클립은 키를 쓰지 않는다 → 형식 2 모양 파일(변형 없음)은 기본값으로 열린다
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        o["version"] = 2
        var vc = o["videoClips"] as! [[String: Any]]; vc[0].removeValue(forKey: "transform"); o["videoClips"] = vc
        let (old, _) = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: o))
        XCTAssertNil(old.clip(v)?.transform); XCTAssertEqual(old.clips[0].effectiveTransform, .identity)
        // 소리 클립의 변형, 범위 밖 크기는 거부
        var bad = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var ac = bad["audioClips"] as! [[String: Any]]; ac[0]["transform"] = ["scalePermille": 500, "offsetX": 0, "offsetY": 0]; bad["audioClips"] = ac
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: bad)))
        var big = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var bv = big["videoClips"] as! [[String: Any]]; bv[0]["transform"] = ["scalePermille": 99_999, "offsetX": 0, "offsetY": 0]; big["videoClips"] = bv
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: big)))
    }

    /// 형식 4의 고운 격자: 손잡이 끌기의 소수 값이 그대로 저장·다시 열기되고, 형식 3 파일(천분율·정수 픽셀)은 같은 값으로 열린다.
    func testFinePrecisionRoundTripAndVersion3Files() throws {
        let b0 = try base(), v = b0.clips[0].id
        // 소수 값 → 격자(0.0001%, 0.001 px)로 반올림: 0.6893217 → 689322 백만분율, 181.23456 → 181235, −0.0004 → 0(−0 아님)
        let fine = ClipTransform(scale: 0.6893217, x: 181.23456, y: -0.0004)
        XCTAssertEqual([fine.scaleMicro, fine.offsetXMilli, fine.offsetYMilli], [689_322, 181_235, 0])
        XCTAssertEqual(fine.scale, 0.689322, accuracy: 1e-12); XCTAssertEqual(fine.x, 181.235, accuracy: 1e-12); XCTAssertEqual(fine.percent, 68.9322, accuracy: 1e-9)
        let t = try b0.settingTransform(clip: v, fine)
        let data = try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        let (back, _) = try ProjectFile.decode(data)
        XCTAssertEqual(back.clip(v)?.transform, fine)
        // 형식 3 파일: 같은 프로젝트를 형식 3 키로 바꿔 쓴다
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        o["version"] = 3
        var vc = o["videoClips"] as! [[String: Any]]; vc[0]["transform"] = ["scalePermille": 1234, "offsetX": -567, "offsetY": 89]; o["videoClips"] = vc
        let (old, oldDoc) = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: o))
        XCTAssertEqual(oldDoc.version, 3)
        XCTAssertEqual(old.clip(v)?.transform, ClipTransform(scaleMicro: 1_234_000, offsetXMilli: -567_000, offsetYMilli: 89_000))
        // 다시 저장하면 형식 4(같은 값)
        let re = try ProjectFile.encode(old, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        XCTAssertEqual(try ProjectFile.decode(re).document.version, ProjectFile.subtitleFreeVersion); XCTAssertEqual(try ProjectFile.decode(re).timeline.clip(v)?.transform, old.clip(v)?.transform)
        // 범위: 1%–1000%, 위치 ±7680·±4320 px. 범위 밖 고운 값은 거부, clamped는 맞춤
        XCTAssertFalse(ClipTransform(scale: 10.000001, x: 0, y: 0).isValid); XCTAssertTrue(ClipTransform(scale: 10, x: 7680, y: -4320).isValid)
        XCTAssertEqual(ClipTransform(scale: 0.001, x: 9000, y: 0).clamped, ClipTransform(scaleMicro: 10_000, offsetXMilli: 7_680_000, offsetYMilli: 0))
        var big = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var bv = big["videoClips"] as! [[String: Any]]; bv[0]["transform"] = ["scaleMicro": 10_000_001, "offsetXMilli": 0, "offsetYMilli": 0]; big["videoClips"] = bv
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: big)))
        // 소수 위치는 내보내기 기하에 그대로 들어간다: 640×480 판(맞춤 2.25 → 1440×1080), 50%, +0.5 px → 가운데 960.5, 너비 720
        let plate640 = MediaAsset(id: UUID(), url: URL(fileURLWithPath: "/media/p.mp4"), name: "p.mp4", frameCount: 30,
                                  timing: SourceTiming(sampleCount: 30, isVariable: false, frameDurationValue: 1, frameDurationTimescale: 30, averageFPS: 30, minInterval: 1.0 / 30, maxInterval: 1.0 / 30),
                                  naturalSize: CGSize(width: 640, height: 480), displaySize: CGSize(width: 640, height: 480), preferredTransform: .identity, hasAudio: false, codec: "avc1",
                                  identity: FileIdentity(device: 1, inode: 2, size: 3, modifiedNs: 4))
        let r = CompositionPlanner.displayRect(plate640, ClipTransform(scale: 0.5, x: 0.5, y: -0.25), render: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(r.midX, 960.5, accuracy: 1e-9); XCTAssertEqual(r.midY, 539.75, accuracy: 1e-9); XCTAssertEqual(r.width, 720, accuracy: 1e-9)
    }

    func testExpectedRectHandNumbers() {
        // 손 계산: 640×480 → 맞춤 배율 2.25 → 1440×1080, 40% → 576×432, 가운데 (1360, 740) → x 1072–1648, y 524–956
        let r = OverlayJudge.expectedRect(PlateFixture.red43, scalePermille: 400, offsetX: 400, offsetY: 200)
        XCTAssertEqual([r.x0, r.y0, r.x1, r.y1], [1072, 524, 1648, 956])
        // 1280×720 → 배율 1.5 → 1920×1080, 50% → 960×540, 가운데 (1860, 940) → x 1380–2340, y 670–1210(화면 밖은 잘림)
        let g = OverlayJudge.expectedRect(PlateFixture.green, scalePermille: 500, offsetX: 900, offsetY: 400)
        XCTAssertEqual([g.x0, g.y0, g.x1, g.y1], [1380, 670, 2340, 1210])
    }
}

/// 판 fixture로 겹친 영상의 내보내기·프리뷰를 판정한다. 레인(위→아래): G(초록 16:9, 50%, +900/+400) [0,90), R(빨강 4:3, 40%, +400/+200) [0,90),
/// B(파랑 전체) [0,60). 기대값은 위 손 계산 사각형.
final class TransformExportTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var out: URL!
    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        out = ExportEndToEndTests.root.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: out) }

    func near(_ a: Int, _ b: Int, _ tol: Int = 3) -> Bool { abs(a - b) <= tol }

    /// 한 프레임 판정(내보내기·프리뷰 같은 함수). swapped: G·R 레인 순서를 바꾼 경우
    func judge(_ f: FrameCompare.Frame, frame: Int, swapped: Bool = false, _ label: String) {
        let c = { (x: Int, y: Int) in OverlayJudge.classify(f, x, y) }
        let lower = frame < 60 ? "blue" : "black"
        XCTAssertEqual([f.width, f.height], [1920, 1080], label)
        XCTAssertEqual(c(100, 100), lower, label)                                    // 위 영상 밖: 아래 레인(또는 검정)
        XCTAssertEqual(c(1200, 600), "red", label)
        XCTAssertEqual(c(1500, 800), swapped ? "red" : "green", label)               // 겹친 곳: 위 레인
        XCTAssertEqual(c(1915, 1075), "green", label)                                // 화면 끝까지(잘림)
        XCTAssertEqual(c(1300, 1050), lower, label)                                  // G 왼쪽 아래 밖
        // 빨강 사각형 가장자리(손 계산 x 1072–1648 @ y=600, y 524–956 @ x=1200)
        let h = OverlayJudge.horizontalEdges(f, y: 600).filter { $0.from == "red" || $0.to == "red" }.map(\.x)
        let v = OverlayJudge.verticalEdges(f, x: 1200).filter { $0.from == "red" || $0.to == "red" }.map(\.y)
        XCTAssertEqual(h.count, 2, "\(label) h \(h)"); XCTAssertEqual(v.count, 2, "\(label) v \(v)")
        if h.count == 2, v.count == 2 {
            XCTAssertTrue(near(h[0], 1072) && near(h[1], 1648) && near(v[0], 524) && near(v[1], 956), "\(label) red edges x \(h) y \(v)")
            XCTAssertEqual(Double(h[1] - h[0]) / Double(v[1] - v[0]), 4.0 / 3.0, accuracy: 0.02, label)   // 비율 유지
        }
        // 초록 왼쪽·위 가장자리(x 1380 @ y=1000, y 670 @ x=1800), 오른쪽·아래는 화면 끝
        let gh = OverlayJudge.horizontalEdges(f, y: 1000).filter { $0.to == "green" || $0.from == "green" }.map(\.x)
        let gv = OverlayJudge.verticalEdges(f, x: 1800).filter { $0.to == "green" || $0.from == "green" }.map(\.y)
        XCTAssertTrue(gh.count == 1 && near(gh[0], 1380) && gv.count == 1 && near(gv[0], 670), "\(label) green edges x \(gh) y \(gv)")
    }

    func testScaledUpperLanesExportAndPreview() async throws {
        var a: [String: MediaAsset] = [:]
        for p in PlateFixture.all { a[p.file] = try await MediaProbe.inspect(fixtures.appendingPathComponent(p.file)) }
        let r = a[PlateFixture.red43.file]!, g = a[PlateFixture.green.file]!, b = a[PlateFixture.blue.file]!
        let lg = UUID(), lr = UUID()
        var t = Timeline().registering(b).registering(r).registering(g)
        let bid = UUID()
        t = try t.inserting(media: b.id, clipID: bid).trimmingEnd(clip: bid, by: -30)   // B [0,60)
        t = try t.addingLane(.video, name: "R", id: lr).movingLane(lr, by: -1).addingLane(.video, name: "G", id: lg).movingLane(lg, by: -2)
        t = try t.placing(media: r.id, at: 0, videoLane: lr, audioLane: nil).placing(media: g.id, at: 0, videoLane: lg, audioLane: nil)
        t = try t.settingTransform(clip: t.clips(inLane: lr)[0].id, ClipTransform(scalePermille: 400, offsetX: 400, offsetY: 200))
            .settingTransform(clip: t.clips(inLane: lg)[0].id, ClipTransform(scalePermille: 500, offsetX: 900, offsetY: 400))
        XCTAssertEqual(t.lanes(.video).map(\.name), ["G", "R", "원본소스"]); XCTAssertEqual(t.durationFrames, 90)
        let media = [r.id: r, g.id: g, b.id: b]
        // 쌓음: [0,60) G·R·B(B가 화면을 덮어 멈춤), [60,90) G·R
        let segs = try CompositionPlanner.layeredSegments(t, media: media, render: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(segs.map { [$0.start, $0.end, $0.layers.count] }, [[0, 60, 3], [60, 90, 2]])

        let plan = try await CompositionPlanner.plan(t, media: media)
        let dest = out.appendingPathComponent("overlay.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [r, g, b]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let probes = [5, 30, 75, 89]
        let ex = try await FrameCompare.decode(dest, frames: Set(probes))
        for n in probes { if let f = ex[n] { judge(f, frame: n, "export \(n)") } else { XCTFail("export frame \(n)") } }
        // 격자 판정(앱 자체 검사의 otf-dev verify-overlay와 같은 함수): 40px 격자 전체, 대조로 R 위치를 100px 틀리게 주면 어긋남이 나온다
        let layers = [OverlayJudge.Layer(file: PlateFixture.green.file, start: 0, length: 90, scalePermille: 500, offsetX: 900, offsetY: 400),
                      OverlayJudge.Layer(file: PlateFixture.red43.file, start: 0, length: 90, scalePermille: 400, offsetX: 400, offsetY: 200),
                      OverlayJudge.Layer(file: PlateFixture.blue.file, start: 0, length: 60, scalePermille: 1000, offsetX: 0, offsetY: 0)]
        var wrong = layers; wrong[1] = OverlayJudge.Layer(file: PlateFixture.red43.file, start: 0, length: 90, scalePermille: 400, offsetX: 300, offsetY: 200)
        for n in probes {
            guard let f = ex[n] else { continue }
            let g = OverlayJudge.judgeGrid(f, frame: n, layers: layers)
            XCTAssertTrue(g.mismatches.isEmpty && g.checked > 1000, "grid \(n): \(g.checked) \(g.mismatches.prefix(5))")
            XCTAssertFalse(OverlayJudge.judgeGrid(f, frame: n, layers: wrong).mismatches.isEmpty)
        }
        let pv = try await PreviewProbe.frames(plan, at: probes)
        for n in probes { if let f = pv[n] { judge(FrameCompare.copy(f.pb), frame: n, "preview \(n)") } else { XCTFail("preview frame \(n)") } }
        // 대조: G·R 레인 순서를 바꾸면 겹친 곳이 빨강
        let sw = try t.movingLane(lg, by: 1)
        let pv2 = try await PreviewProbe.frames(try await CompositionPlanner.plan(sw, media: media), at: [30])
        if let f = pv2[30] { judge(FrameCompare.copy(f.pb), frame: 30, swapped: true, "swapped preview") } else { XCTFail("swapped") }
        // 대조: 변형 없는 4:3 R만 B 위에 → 기본 맞춤 x 240–1680, 그 밖(좌우 여백)은 아래 파랑
        let idT = try t.removingLane(lg).settingTransform(clip: t.clips(inLane: lr)[0].id, nil)
        let pv3 = try await PreviewProbe.frames(try await CompositionPlanner.plan(idT, media: media), at: [30])
        if let f = pv3[30].map({ FrameCompare.copy($0.pb) }) {
            let e = OverlayJudge.horizontalEdges(f, y: 540).map(\.x)
            XCTAssertTrue(e.count == 2 && near(e[0], 240) && near(e[1], 1680), "identity edges \(e)")
            XCTAssertEqual(OverlayJudge.classify(f, 100, 540), "blue"); XCTAssertEqual(OverlayJudge.classify(f, 960, 540), "red")
        } else { XCTFail("identity preview") }
    }

    /// 소수 크기·위치(형식 4)가 내보내기·프리뷰 기하에 그대로 들어가는가. 초록 16:9 판(1280×720, 맞춤 1920×1080)을 파랑 위에 40.05%, X +400.5, Y −200.25:
    /// 손 계산 768.96×432.54, 가운데 (1360.5, 339.75) → 왼쪽 경계 x 976.02, 오른쪽 1744.98.
    /// 경계는 행의 밝기(Y = 0.2126R + 0.7152G + 0.0722B)가 두 판 밝기의 가운데를 지나는 곳을 선형 보간으로 잰다(픽셀보다 고운 값).
    /// 밝기를 쓰는 까닭: H.264 4:2:0은 색차를 절반 해상도로 저장해 색만 다른 경계(빨강·파랑)는 2 px 격자로 뭉개진다(이 테스트를 만들며 관찰).
    /// 관찰(이 Mac, 기본 AVFoundation 합성기): 레이어 경계는 가장 가까운 출력 픽셀 경계로 맞춰 그려진다(976.02 → 976, 976.52 → 977,
    /// 1744.98 → 1745, 1745.48 → 1745). 그래서 기대값은 손 계산 경계를 반올림한 값이고, X +0.5 px는 왼쪽 경계만 한 픽셀 옮긴다.
    /// 소수 값이 저장 단계에서 반올림되지 않고 그리기까지 간다는 것을 이 차이로 확인한다(정수로 반올림했다면 400.5와 401은 같은 그림).
    func testFractionalTransformReachesExportAndPreview() async throws {
        let g = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.green.file))
        let b = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.blue.file))
        let top = UUID()
        var t = Timeline().registering(b).registering(g)
        t = try t.inserting(media: b.id).addingLane(.video, name: "G", id: top, outward: true)
        t = try t.placing(media: g.id, at: 0, videoLane: top, audioLane: nil)
        let gid = t.clips(inLane: top)[0].id
        func luma(_ r: Double, _ gg: Double, _ bb: Double) -> Double { 0.2126 * r + 0.7152 * gg + 0.0722 * bb }
        let mid = (luma(40, 200, 60) + luma(40, 60, 220)) / 2
        func edges(_ f: FrameCompare.Frame, y: Int) -> [Double] {
            let row = (0..<f.width).map { x -> Double in let i = (y * f.width + x) * 4; return luma(Double(f.bgra[i + 2]), Double(f.bgra[i + 1]), Double(f.bgra[i])) }
            var out: [Double] = []
            for x in 0..<(f.width - 1) where (row[x] - mid) * (row[x + 1] - mid) < 0 { out.append(Double(x) + 0.5 + (mid - row[x]) / (row[x + 1] - row[x])) }
            return out
        }
        func render(_ x: ClipTransform, _ name: String) async throws -> (export: FrameCompare.Frame, preview: FrameCompare.Frame) {
            let tt = try t.settingTransform(clip: gid, x)
            let plan = try await CompositionPlanner.plan(tt, media: [g.id: g, b.id: b])
            let dest = out.appendingPathComponent(name)
            let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [g, b]) { _ in }
            XCTAssertEqual(outcome, .completed(dest))
            let ex = try await FrameCompare.decode(dest, frames: [30])
            let pv = try await PreviewProbe.frames(plan, at: [30])
            return (try XCTUnwrap(ex[30]), FrameCompare.copy(try XCTUnwrap(pv[30]).pb))
        }
        let a = try await render(ClipTransform(scale: 0.4005, x: 400.5, y: -200.25), "fine.mp4")
        let c = try await render(ClipTransform(scale: 0.4005, x: 401.0, y: -200.25), "fine-shift.mp4")
        let ea = edges(a.export, y: 340), ec = edges(c.export, y: 340), pa = edges(a.preview, y: 340), pc = edges(c.preview, y: 340)
        print("fractional edges: export \(ea) shifted \(ec) preview \(pa) shifted \(pc)")
        XCTAssertEqual(ea.count, 2); XCTAssertEqual(ec.count, 2); XCTAssertEqual(pa.count, 2); XCTAssertEqual(pc.count, 2)
        guard ea.count == 2, ec.count == 2, pa.count == 2, pc.count == 2 else { return }
        // 손 계산 경계: 왼쪽 960 + 400.5 − 384.48 = 976.02, 오른쪽 1744.98 / X +0.5 → 976.52, 1745.48. 그린 경계 = 가장 가까운 픽셀 경계
        for (e, exp, label) in [(ea, [976.0, 1745.0], "export"), (pa, [976.0, 1745.0], "preview"), (ec, [977.0, 1745.0], "export +0.5"), (pc, [977.0, 1745.0], "preview +0.5")] {
            XCTAssertEqual(e[0], exp[0], accuracy: 0.15, label); XCTAssertEqual(e[1], exp[1], accuracy: 0.15, label)
        }
    }
}
