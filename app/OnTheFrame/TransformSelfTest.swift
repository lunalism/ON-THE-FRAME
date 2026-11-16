#if DEBUG
import AppKit
import OnTheFrameEngine

/// 영상 크기·위치 자체 검사(A-015, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFTransformTest`.
/// 프리뷰 편집 테두리(PreviewOverlayView)에 합성 마우스·키 이벤트를 보내 옮기기·모서리 크기 조절·Esc를 보고, 정보 패널과 같은 저장소 동작,
/// 자르기·실행 취소·저장·다시 열기를 본다. 마지막 내보내기는 transform-manifest.json으로 남겨 `otf-dev verify-overlay`가 격자로 판정한다.
/// 보기 → 출력 좌표 기대값은 보기 크기에서 직접 계산한다(배율 k = min(폭/1920, 높이/1080), 가운데 맞춤 여백).
@MainActor
enum TransformSelfTest {
    typealias Check = LaneSelfTest.Check
    struct Layer: Codable { let file: String; let start: Int; let length: Int; let scalePermille: Int; let offsetX: Int; let offsetY: Int }
    struct Manifest: Codable { let exportFile: String; let durationFrames: Int; let frames: [Int]; let layers: [Layer] }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        let src = folder.appendingPathComponent("sources"), out = folder.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { check("setup.window", false); return finish(folder, checks, nil) }
        w.makeKeyAndOrderFront(nil)
        if !(await LaneSelfTest.regainFocus(w)) { LaneSelfTest.direct = true }
        s.importFiles(["plate-blue-1920x1080.mp4", "plate-red-640x480.mp4"].map { src.appendingPathComponent($0) })
        _ = await LaneSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 2 }
        let by = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.name, $0) })
        guard let blue = by["plate-blue-1920x1080.mp4"], let red = by["plate-red-640x480.mp4"],
              let container = LaneSelfTest.find(TimelineContainerView.self, w.contentView) else { check("setup", false); return finish(folder, checks, nil) }
        let tv = container.timelineView
        s.addToTimeline(blue.id)
        _ = LaneSelfTest.menuItem("영상 레인 추가")
        await LaneSelfTest.settle()
        // 새 영상 레인은 맨 위(V2, 2026-10-11 배치: 경계에서 바깥쪽)
        guard let top = s.timeline.lanes(.video).first?.id, top != Lane.videoID else { return finish(folder, checks, nil) }
        tv.drop(red.id, at: NSPoint(x: tv.x(0), y: tv.laneRect(top)?.midY ?? 0))
        await LaneSelfTest.settle()
        guard let rid = s.timeline.clips(inLane: top).first?.id else { check("setup.redOnTop", false); return finish(folder, checks, nil) }
        s.select(rid); s.seek(to: 30)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        await LaneSelfTest.settle()
        guard let ov = LaneSelfTest.find(PreviewOverlayView.self, w.contentView) else { check("setup.overlay", false); return finish(folder, checks, nil) }
        // 보기 → 출력 좌표(독립 계산)
        func area() -> (x: CGFloat, y: CGFloat, k: CGFloat) {
            let b = ov.bounds, k = min(b.width / 1920, b.height / 1080)
            return ((b.width - 1920 * k) / 2, (b.height - 1080 * k) / 2, k)
        }
        func viewPoint(_ cx: CGFloat, _ cy: CGFloat) -> NSPoint { let a = area(); return ov.convert(NSPoint(x: a.x + cx * a.k, y: a.y + cy * a.k), to: nil) }
        func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1.01) -> Bool { abs(a - b) <= tol }
        let a0 = area()
        check("overlay.identityRect", ov.state.clipID == rid && ov.state.rect.map { near($0.minX, 240) && near($0.maxX, 1680) && near($0.minY, 0) && near($0.maxY, 1080) } == true
              && (a0.x > 1 || a0.y > 1), "rect \(ov.state.rect.map { "\($0)" } ?? "nil") view \(ov.bounds.size) letterbox \(a0)")

        // 1. 정보 패널 값(크기 40%) → 한 단계, 테두리 576×432 가운데
        let d0 = s.history.undoDepth
        s.setTransform(rid, ClipTransform(scalePermille: 400, offsetX: 0, offsetY: 0))
        await LaneSelfTest.settle()
        check("inspector.scale", s.timeline.clip(rid)?.transform == ClipTransform(scalePermille: 400, offsetX: 0, offsetY: 0) && s.history.undoDepth == d0 + 1
              && ov.state.rect.map { near($0.minX, 672) && near($0.minY, 324) && near($0.width, 576) && near($0.height, 432) } == true, "\(ov.state.rect.map { "\($0)" } ?? "nil")")
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, checks, nil) }

        // 2. 안쪽 끌기: 보기에서 (+120, +60)pt → 출력 (+120/k, +60/k) 픽셀
        let k = area().k
        let p0 = viewPoint(960, 540), dx: CGFloat = 120, dy: CGFloat = 60
        let p1 = NSPoint(x: p0.x + dx, y: p0.y - dy)   // 창 좌표는 아래가 −Y(보기는 뒤집힘)
        let d1 = s.history.undoDepth
        await LaneSelfTest.mouse(.leftMouseDown, p0, w); await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p0.x + 10, y: p0.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, p1, w); await LaneSelfTest.mouse(.leftMouseUp, p1, w)
        // 2026-10-11: 끌기 값은 소수(저장 격자 0.001 px)라 포인터 이동을 그대로 따른다(이전에는 정수 픽셀로 반올림)
        let ex = Double(dx / k), ey = Double(dy / k)
        let mv = s.timeline.clip(rid)?.effectiveTransform
        check("drag.move", mv.map { abs($0.x - ex) <= 0.001 && abs($0.y - ey) <= 0.001 && $0.scaleMicro == 400_000 } == true && s.history.undoDepth == d1 + 1,
              "got \(mv.map { "\($0)" } ?? "nil") expected (\(ex), \(ey)) k \(k)")

        // 3. 끌기 중 Esc: 끌기 전으로, 기록 없음
        let beforeEsc = s.timeline, d2 = s.history.undoDepth
        let q0 = viewPoint(960 + CGFloat(mv?.x ?? 0), 540 + CGFloat(mv?.y ?? 0))
        await LaneSelfTest.mouse(.leftMouseDown, q0, w); await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: q0.x + 80, y: q0.y), w)
        let moving = s.gestureTimeline != nil && s.gestureTimeline != beforeEsc && s.timeline == beforeEsc   // 끌기 중 값은 기록 밖(놓을 때 한 단계)
        if LaneSelfTest.direct { ov.cancelOperation(nil) } else { await LaneSelfTest.key(53, "\u{1b}", [], w) }
        let escOK = s.timeline == beforeEsc && s.gestureBase == nil
        await LaneSelfTest.mouse(.leftMouseUp, NSPoint(x: q0.x + 80, y: q0.y), w)
        check("drag.escRestores", moving && escOK && s.timeline == beforeEsc && s.history.undoDepth == d2, "moving \(moving) esc \(escOK)")

        // 4. 오른쪽 아래 모서리 끌기(+90pt 오른쪽): 왼쪽 위 모서리 고정, 비율 4:3 유지, 한 단계
        guard let r0 = ov.state.rect else { return finish(folder, checks, nil) }
        let c0 = viewPoint(r0.maxX, r0.maxY), c1 = NSPoint(x: c0.x + 90, y: c0.y)
        let d3 = s.history.undoDepth
        let cHit = w.contentView.flatMap { cv in cv.hitTest(cv.superview?.convert(c0, from: nil) ?? c0) }.map { "\(type(of: $0))" } ?? "nil"
        await LaneSelfTest.mouse(.leftMouseDown, c0, w)
        let cBegan = s.gestureBase != nil; await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: c0.x + 5, y: c0.y), w)
        await LaneSelfTest.mouse(.leftMouseDragged, c1, w); await LaneSelfTest.mouse(.leftMouseUp, c1, w)
        let r1 = ov.state.rect
        // 기대: 너비 = r0.width + 90/k(가로가 더 크게 늘었으므로 가로 기준), 높이 = 너비 × 3/4
        let ew = r0.width + 90 / k
        // 2026-10-11: 소수 크기·위치라 반대 모서리는 0.01 px 안에서 고정, 너비는 포인터 이동 그대로(0.01 px), 비율 4:3(1e-6)
        check("drag.cornerResize", r1.map { near($0.minX, r0.minX, 0.01) && near($0.minY, r0.minY, 0.01) && near($0.width, ew, 0.01) && abs($0.width / $0.height - 4.0 / 3.0) < 1e-6 } == true
              && s.history.undoDepth == d3 + 1, "r0 \(r0) r1 \(r1.map { "\($0)" } ?? "nil") expected width \(ew) hit \(cHit) began \(cBegan) depth \(s.history.undoDepth - d3) handle \(ov.handleRect(.bottomRight).map { "\($0)" } ?? "nil") c0view \(ov.convert(c0, from: nil))")

        // 5. 정보 패널 값으로 판정용 위치(40%, +400, +200) → 실행 취소·다시 실행
        s.setTransform(rid, ClipTransform(scalePermille: 400, offsetX: 400, offsetY: 200))
        let set = s.timeline.clip(rid)?.transform
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, checks, nil) }
        await LaneSelfTest.key(6, "z", [.command], w)
        let undone = s.timeline.clip(rid)?.transform
        await LaneSelfTest.key(6, "z", [.command, .shift], w)
        check("undoRedo", set == ClipTransform(scalePermille: 400, offsetX: 400, offsetY: 200) && undone != set && s.timeline.clip(rid)?.transform == set)
        // 소리 클립(파랑 판에는 소리 없음)이 아닌 영상만: 소리 클립에 변형을 줄 수 없음은 엔진 검사

        // 6. 자르기(⌘K @45): 두 조각 모두 같은 변형
        s.select(rid); s.seek(to: 45)
        await LaneSelfTest.key(40, "k", [.command], w)
        let pieces = s.timeline.clips(inLane: top)
        check("split.keepsTransform", pieces.count == 2 && pieces.allSatisfy { $0.transform == set }, "\(pieces.map { $0.transform.map { "\($0)" } ?? "nil" })")

        // 7. 저장 → 다시 열기: 변형 그대로
        let edited = s.timeline
        let proj = out.appendingPathComponent("transform.ontheframe")
        let saved = s.writeProject(to: proj)
        s.resetProject()
        let reopened = await s.openProject(at: proj)
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        check("project.reopen", saved && reopened && s.timeline == edited && s.timeline.clips(inLane: top).allSatisfy { $0.transform == set })

        // 8. 테두리를 띄운 채 내보내기(편집 테두리는 내보내기에 들어가지 않음 → otf-dev verify-overlay 격자 판정)
        if let first = s.timeline.clips(inLane: top).first { s.select(first.id) }
        s.seek(to: 30)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        await LaneSelfTest.settle()
        check("overlay.shownDuringExport", ov.state.rect != nil)
        let dest = out.appendingPathComponent("overlay.mp4")
        s.startExport(.fromSavePanel(dest))
        _ = await LaneSelfTest.waitUntil(120) { s.exportPhase == .idle && s.alerts.isShowing }
        check("export", s.alert?.title == "내보내기 완료", s.alert?.message ?? "")
        while s.alerts.isShowing { s.alerts.pressButton(1); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        let m = Manifest(exportFile: "out/overlay.mp4", durationFrames: s.timeline.durationFrames, frames: [10, 30, 60, 89],
                         layers: [Layer(file: "plate-red-640x480.mp4", start: 0, length: 90, scalePermille: 400, offsetX: 400, offsetY: 200),
                                  Layer(file: "plate-blue-1920x1080.mp4", start: 0, length: 90, scalePermille: 1000, offsetX: 0, offsetY: 0)])
        finish(folder, checks, m)
    }

    static func finish(_ folder: URL, _ checks: [Check], _ m: Manifest?) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: LaneSelfTest.direct ? "앱을 활성화할 수 없어 마우스는 보기에 직접, 키는 같은 저장소 동작으로 보냄" : "합성 이벤트를 앱 이벤트 큐로 보냄")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let m, let d = try? enc.encode(m) { try? d.write(to: folder.appendingPathComponent("transform-manifest.json")) }
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("transform-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
