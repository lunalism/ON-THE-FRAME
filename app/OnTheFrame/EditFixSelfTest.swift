#if DEBUG
import AppKit
import AVFoundation
import OnTheFrameEngine

/// 2026-10-11 소유자 보고 편집 문제 자체 검사(Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFEditFixTest`.
/// 실제 상호작용 경로를 쓴다: 목록 + 단추와 같은 저장소 동작, 타임라인 보기의 끌어 놓기 해석(창 좌표 → 문서 좌표), 타임라인·프리뷰 테두리에
/// 합성 마우스·키 이벤트, 메뉴 항목. 생성 fixture(otf-TA·otf-TB·aud-wav48s, plate-blue·plate-red)만 쓴다.
/// - A: + 추가 위치(재생 헤드와 무관, 빈 타임라인은 0), 가운데 경계 레인 배치(V2/V1/경계/A1/A2)·실행 취소·저장·다시 열기,
///   확대·스크롤 아래 놓기, 연결된 쌍 끌어 옮기기(왼쪽·오른쪽·빈틈·0, 붙음, 겹침 거부, Esc, 레인 옮기기). 마지막 내보내기는
///   editfix-manifest.json으로 남겨 `otf-dev verify-editfix`가 독립 기대값(가장 위 영상 레인 원본 프레임, 소리 클릭 위치 = 동기)으로 판정한다.
/// - B: 변형 끌기 깜박임. 이전 경로(마우스 이동마다 다시 만들기)로 재현해 빈 화면 표본을 세고, 새 경로에서 같은 끌기의 빈 화면 표본 0,
///   끌기 중 항목 교체 0, 정지 화면이 최종 composition 프레임과 일치(PSNR·색 표본), Esc 복원, 내보내기 프레임 일치를 본다.
@MainActor
enum EditFixSelfTest {
    typealias Check = LaneSelfTest.Check
    struct LaneClipRef: Codable { let file: String; let start: Int; let sourceIn: Int; let length: Int }
    struct LaneRef: Codable { let kind: String; let name: String; let muted: Bool; let volumePercent: Int; let clips: [LaneClipRef] }
    struct Manifest: Codable { let exportFile: String; let durationFrames: Int; let lanes: [LaneRef] }

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
        let files = ["otf-TA.mp4", "otf-TB.mp4", "aud-wav48s.wav"]
        s.importFiles(files.map { src.appendingPathComponent($0) })
        _ = await LaneSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 3 }
        let by = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.name, $0) })
        guard let ta = by["otf-TA.mp4"], let tb = by["otf-TB.mp4"], let wav = by["aud-wav48s.wav"],
              let container = LaneSelfTest.find(TimelineContainerView.self, w.contentView) else { check("setup", false); return finish(folder, checks, nil) }
        let tv = container.timelineView, header = container.header
        let v1 = Lane.videoID, a1 = Lane.audioID
        func rows(_ l: UUID) -> [[Int]] { s.timeline.clips(inLane: l).map { [$0.start, $0.sourceIn, $0.length] } }

        // MARK: A1. + 추가: 빈 타임라인은 재생 헤드와 무관하게 0, 채운 타임라인은 V1·A1의 마지막 끝 뒤
        s.addToTimeline(ta.id)
        check("add.firstAtZero", rows(v1) == [[0, 0, 120]] && rows(a1) == [[0, 0, 120]], "\(rows(v1))")
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, checks, nil) }
        if let c = s.timeline.clips.first { s.select(c.id) }
        s.seek(to: 82)
        await LaneSelfTest.key(51, "\u{7f}", [], w)   // Delete: 빈틈 남김 → 클립 없음, 길이 120 그대로(이전에는 다음 추가가 120에서 시작)
        let liftedEmpty = s.timeline.isEmpty && s.durationFrames == 120 && s.playhead == 82
        s.addToTimeline(tb.id)
        check("add.emptyAfterDeleteStartsAtZero", liftedEmpty && rows(v1) == [[0, 0, 90]] && rows(a1) == [[0, 0, 90]] && s.playhead == 82,
              "lifted \(liftedEmpty) v1 \(rows(v1)) playhead \(s.playhead)")
        s.seek(to: 30)
        s.addToTimeline(ta.id)
        check("add.appendsAfterPairNotPlayhead", rows(v1) == [[0, 0, 90], [90, 0, 120]] && rows(a1) == [[0, 0, 90], [90, 0, 120]], "\(rows(v1))")

        // MARK: A2. 레인 쌍: V2는 V1 위, A2는 A1 아래, 경계는 V1과 A1 사이. 실행 취소 한 단계, 다시 실행은 같은 ID
        let d0 = s.history.undoDepth
        let pairAdded = LaneSelfTest.menuItem("영상·소리 레인 쌍 추가")
        await LaneSelfTest.settle()
        let vl = s.timeline.lanes(.video), al = s.timeline.lanes(.audio)
        guard pairAdded, vl.count == 2, al.count == 2, let v2 = vl.first?.id, let a2 = al.last?.id else {
            check("lanes.pair", false, "\(s.timeline.lanes.map(\.name))"); return finish(folder, checks, nil)
        }
        let ids = s.timeline.lanes.map(\.id)
        let labels = s.timeline.lanes.map { s.timeline.laneLabel($0.id) }
        let r = [v2, v1, a1, a2].compactMap { tv.laneRect($0) }
        let by0 = TimelineNSView.boundaryY(s.timeline.lanes) ?? -1
        let ordered = r.count == 4 && r[0].maxY < r[1].minY && r[1].maxY < by0 && by0 < r[2].minY && r[2].maxY < r[3].minY
        let headerOrdered = header.rowRect(v2).midY < header.rowRect(v1).midY && header.rowRect(v1).midY < header.rowRect(a1).midY
            && header.rowRect(a1).midY < header.rowRect(a2).midY
        check("lanes.pairOutward", ids == [v2, v1, a1, a2] && labels == ["V2", "V1", "A1", "A2"] && ordered && headerOrdered && s.history.undoDepth == d0 + 1,
              "labels \(labels) boundary \(by0) rects \(r.map { "\(Int($0.minY))-\(Int($0.maxY))" })")
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, checks, nil) }
        await LaneSelfTest.key(6, "z", [.command], w)
        let undone = s.timeline.lanes.map(\.id) == [v1, a1]
        await LaneSelfTest.key(6, "z", [.command, .shift], w)
        check("lanes.pairUndoRedo", undone && s.timeline.lanes.map(\.id) == ids, "\(s.timeline.lanes.map(\.name))")
        s.renameLane(v2, to: "위 영상")
        check("lanes.renameKeepsNumber", s.timeline.laneInfo(v2)?.name == "위 영상" && s.timeline.laneLabel(v2) == "V2")

        // MARK: A3. 놓기: 확대 10, 스크롤 0에서 A2의 0에 WAV → 0. 가로 스크롤 뒤 V2의 100에 TB → 100(연결된 소리는 같은 번호의 A2)
        s.timelineZoom = 10
        await LaneSelfTest.settle()
        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY)); container.scrollView.reflectScrolledClipView(clip)
        await LaneSelfTest.settle()
        /// 문서 보기와 무관하게 계산한 창 좌표: 컨테이너 안 x = 레인 머리 폭 + 여백 + 프레임 × 확대 − 가로 스크롤
        func windowPoint(frame f: Int, lane: UUID) -> NSPoint {
            let x = LaneHeaderView.width + TimelineNSView.inset + CGFloat(f) * CGFloat(s.timelineZoom) - clip.bounds.minX
            let y = (tv.laneRect(lane)?.midY ?? 0) - clip.bounds.minY
            return container.convert(NSPoint(x: x, y: y), to: nil)
        }
        tv.drop(wav.id, windowPoint: windowPoint(frame: 0, lane: a2))
        await LaneSelfTest.settle()
        check("drop.zeroAtZoom", rows(a2) == [[0, 0, 60]], "\(rows(a2)) zoom \(s.timelineZoom)")
        clip.scroll(to: NSPoint(x: 400, y: clip.bounds.minY)); container.scrollView.reflectScrolledClipView(clip)
        await LaneSelfTest.settle()
        let scrolledX = clip.bounds.minX
        tv.drop(tb.id, windowPoint: windowPoint(frame: 100, lane: v2))
        await LaneSelfTest.settle()
        let tbPair = s.timeline.clips(inLane: v2).first.flatMap { s.timeline.partner(of: $0.id) }
        check("drop.exactTimeUnderScroll", scrolledX > 100 && rows(v2) == [[100, 0, 90]] && tbPair?.lane == a2 && tbPair?.start == 100,
              "scroll \(scrolledX) v2 \(rows(v2)) partner \(tbPair.map { "\($0.start)" } ?? "nil")")
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, checks, nil) }
        await LaneSelfTest.key(6, "z", [.command], w)   // 이 놓기는 되돌리고 옮기기 검사로
        check("drop.undo", rows(v2).isEmpty && rows(a2) == [[0, 0, 60]])

        // MARK: A4. 끌어 옮기기(가로로 스크롤할 수 있는 확대, 스크롤 150): 연결된 쌍은 함께, 리플 없음, 겹침은 전체 거부, 붙음, Esc, 레인 옮기기
        // 확대는 문서가 보이는 폭보다 넓어지는 값(최소 8)으로 정한다. 넓지 않으면 스크롤 위치가 0으로 돌아가 검사가 무의미하다.
        let need = (clip.bounds.width + 240 - TimelineNSView.inset * 2 - 200) / CGFloat(max(1, s.durationFrames))
        s.timelineZoom = Double(max(8, need.rounded(.up)))
        await LaneSelfTest.settle()
        clip.scroll(to: NSPoint(x: 150, y: clip.bounds.minY)); container.scrollView.reflectScrolledClipView(clip)
        await LaneSelfTest.settle()
        let moveScroll = clip.bounds.minX
        check("move.scrolled", moveScroll == 150, "scroll \(moveScroll) zoom \(s.timelineZoom) doc \(Int(tv.frame.width)) visible \(Int(clip.bounds.width))")
        guard let tbV = s.timeline.clips(inLane: v1).first?.id, let taV = s.timeline.clips(inLane: v1).last?.id,
              let tbA = s.timeline.partner(of: tbV)?.id else { check("move.setup", false); return finish(folder, checks, nil) }
        /// 클립 안의 창 좌표(문서 x는 클립 보이는 부분의 가운데)
        func clipPoint(_ id: UUID) -> NSPoint {
            guard let c = s.timeline.clip(id), let lr = tv.laneRect(c.lane) else { return .zero }
            let x0 = max(tv.x(c.start), clip.bounds.minX + 4), x1 = min(tv.x(c.end), clip.bounds.maxX - 4)
            return tv.convert(NSPoint(x: (x0 + x1) / 2, y: lr.midY), to: nil)
        }
        var dragLog: [String] = []
        func dragBy(_ id: UUID, frames: Int = 0, points: CGFloat? = nil, toLane: UUID? = nil, release: Bool = true) async -> NSPoint {
            let p0 = clipPoint(id)
            let dx = points ?? CGFloat(frames) * tv.pixelsPerFrame   // 보기에 실제로 적용된 확대
            let hit = (w.contentView?.hitTest(w.contentView?.superview?.convert(p0, from: nil) ?? p0)).map { "\(type(of: $0))" } ?? "nil"
            dragLog.append("ppf \(tv.pixelsPerFrame) scroll \(clip.bounds.minX) w \(Int(clip.bounds.width)) p0doc \(Int(tv.convert(p0, from: nil).x)) hit \(hit)")
            let ty = toLane.flatMap { tv.laneRect($0) }.map { tv.convert(NSPoint(x: 0, y: $0.midY), to: nil).y } ?? p0.y
            await LaneSelfTest.mouse(.leftMouseDown, p0, w)
            await LaneSelfTest.mouse(.leftMouseDragged, NSPoint(x: p0.x + (dx >= 0 ? 6 : -6), y: p0.y), w)
            let p1 = NSPoint(x: p0.x + dx, y: ty)
            await LaneSelfTest.mouse(.leftMouseDragged, p1, w)
            if release { await LaneSelfTest.mouse(.leftMouseUp, p1, w) }
            return p1
        }
        let zoomApplied = tv.pixelsPerFrame == CGFloat(s.timelineZoom)
        check("move.zoomApplied", zoomApplied, "view \(tv.pixelsPerFrame) store \(s.timelineZoom)")
        let wavBefore = rows(a2), dm = s.history.undoDepth
        _ = await dragBy(taV, frames: 30)
        check("move.linkedRightNoRipple", rows(v1) == [[0, 0, 90], [120, 0, 120]] && rows(a1) == [[0, 0, 90], [120, 0, 120]] && rows(a2) == wavBefore
              && s.timeline.gaps(inLane: v1).contains(90..<120) && s.history.undoDepth == dm + 1, "scroll \(moveScroll) v1 \(rows(v1)) a1 \(rows(a1)) \(dragLog.last ?? "")")
        _ = await dragBy(tbA, frames: 20)   // 소리 레인의 짝을 잡아도 쌍이 함께
        check("move.linkedFromAudioLane", rows(v1) == [[20, 0, 90], [120, 0, 120]] && rows(a1) == [[20, 0, 90], [120, 0, 120]] && rows(a2) == wavBefore
              && s.timeline.syncOffset(of: tbV) == 0 && s.history.undoDepth == dm + 2, "v1 \(rows(v1)) a1 \(rows(a1)) \(dragLog.last ?? "")")
        let beforeReject = s.timeline
        let pr = await dragBy(taV, frames: -15, release: false)   // [105,225)는 TB [20,110)과 겹침
        let red = s.freeMoveProposal?.ok == false && s.timeline == beforeReject
        await LaneSelfTest.mouse(.leftMouseUp, pr, w)
        check("move.overlapRejectsWholePair", red && s.timeline == beforeReject && s.history.undoDepth == dm + 2 && (s.statusMessage ?? "").contains("겹칩니다"),
              "red \(red) status \(s.statusMessage ?? "")")
        // 놓을 곳: TB 시작이 0에서 5pt 오른쪽(붙음 거리 8pt 안) → 0에 붙음
        let ps = await dragBy(tbV, points: tv.x(0) + 5 - tv.x(20), release: false)
        let snapped = s.snapGuide == 0 && s.timeline.clip(tbV)?.start == 0
        await LaneSelfTest.mouse(.leftMouseUp, ps, w)
        check("move.backToZeroWithSnap", snapped && rows(v1).first == [0, 0, 90] && rows(a1).first == [0, 0, 90] && s.history.undoDepth == dm + 3,
              "snap \(s.snapGuide.map(String.init) ?? "nil") v1 \(rows(v1))")
        let beforeEsc = s.timeline
        let pe = await dragBy(taV, frames: 10, release: false)
        let moving = s.timeline != beforeEsc
        await LaneSelfTest.key(53, "\u{1b}", [], w)
        let escOK = s.timeline == beforeEsc && s.gestureBase == nil
        await LaneSelfTest.mouse(.leftMouseUp, pe, w)
        check("move.escCancels", moving && escOK && s.timeline == beforeEsc && s.history.undoDepth == dm + 3, "moving \(moving) esc \(escOK)")
        _ = await dragBy(taV, frames: 0, toLane: v2)   // 영상만 V2로(짝 소리는 A1 그대로, 시각 그대로)
        check("move.crossLaneKeepsPartnerLane", rows(v2) == [[120, 0, 120]] && rows(a1) == [[0, 0, 90], [120, 0, 120]] && s.timeline.partner(of: taV)?.lane == a1
              && s.history.undoDepth == dm + 4, "v2 \(rows(v2)) v1 \(rows(v1))")
        await LaneSelfTest.key(6, "z", [.command], w)
        let undoOne = rows(v2).isEmpty && rows(v1) == [[0, 0, 90], [120, 0, 120]]
        await LaneSelfTest.key(6, "z", [.command, .shift], w)
        check("move.oneUndoStepPerDrag", undoOne && rows(v2) == [[120, 0, 120]])

        // MARK: A5. 저장 → 다시 열기: 레인 순서·ID·번호·클립·연결 그대로
        let edited = s.timeline
        let proj = out.appendingPathComponent("editfix.ontheframe")
        let saved = s.writeProject(to: proj)
        s.resetProject()
        let reopened = await s.openProject(at: proj)
        while s.alerts.isShowing { s.alerts.pressButton(0); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        check("project.reopenKeepsArrangement", saved && reopened && s.timeline == edited && s.timeline.lanes.map(\.id) == ids
              && s.timeline.lanes.map { s.timeline.laneLabel($0.id) } == ["V2", "V1", "A1", "A2"])

        // MARK: A6. 내보내기(다시 연 프로젝트) → otf-dev verify-editfix
        // 모든 오디오 레인이 100%다(A1: TB·TA 원본 소리, A2: WAV — TB 소리와 [0,60)에서 동시에). 판정은 MP4의 소리 트랙이 하나인지,
        // 그 한 트랙에 두 원본의 클릭과 (위상까지 더한) 440 Hz 진폭이 모두 있는지 본다(2026-10-11 여러 소리 트랙 결함 수정).
        check("export.setupBothSources", rows(a2) == [[0, 0, 60]] && s.timeline.lanes.allSatisfy { !$0.muted && $0.volumePercent == 100 }, "a2 \(rows(a2))")
        let dest = out.appendingPathComponent("editfix.mp4")
        s.startExport(.fromSavePanel(dest))
        _ = await LaneSelfTest.waitUntil(120) { s.exportPhase == .idle && s.alerts.isShowing }
        check("export.A", s.alert?.title == "내보내기 완료", s.alert?.message ?? "")
        while s.alerts.isShowing { s.alerts.pressButton(1); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        let names = Dictionary(uniqueKeysWithValues: s.timeline.media.map { ($0.id, $0.name) })
        let manifest = Manifest(exportFile: "out/editfix.mp4", durationFrames: s.timeline.durationFrames, lanes: s.timeline.lanes.map { l in
            LaneRef(kind: l.kind.rawValue, name: l.name, muted: l.muted, volumePercent: l.volumePercent,
                    clips: s.timeline.clips(inLane: l.id).map { LaneClipRef(file: names[$0.mediaID] ?? "", start: $0.start, sourceIn: $0.sourceIn, length: $0.length) })
        })

        // MARK: B. 변형 끌기 깜박임
        await transformSection(s, w, src: src, out: out, check: check)
        finish(folder, checks, manifest)
    }

    // MARK: - B

    /// 빈 화면 표본: 정지 화면도 없고 AVPlayerLayer도 표시할 준비가 안 된 순간(검정이 비침)
    @MainActor final class Sampler {
        var samples = 0, blanks = 0
        private var timer: Timer?
        func start(_ host: PlayerNSView) {
            samples = 0; blanks = 0
            let t = Timer(timeInterval: 0.004, repeats: true) { [weak self, weak host] _ in
                MainActor.assumeIsolated {
                    guard let self, let host else { return }
                    self.samples += 1
                    if !host.isShowingStill && !(host.playerLayer.isReadyForDisplay && host.playerLayer.player?.currentItem != nil) { self.blanks += 1 }
                }
            }
            RunLoop.main.add(t, forMode: .common); timer = t
        }
        func stop() { timer?.invalidate(); timer = nil }
    }

    static func transformSection(_ s: ProjectStore, _ w: NSWindow, src: URL, out: URL, check: (String, Bool, String) -> Void) async {
        s.resetProject()
        s.importFiles(["plate-blue-1920x1080.mp4", "plate-red-640x480.mp4"].map { src.appendingPathComponent($0) })
        _ = await LaneSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 2 }
        let by = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.name, $0) })
        guard let blue = by["plate-blue-1920x1080.mp4"], let red = by["plate-red-640x480.mp4"],
              let container = LaneSelfTest.find(TimelineContainerView.self, w.contentView),
              let ov = LaneSelfTest.find(PreviewOverlayView.self, w.contentView), let host = s.previewHost else { check("B.setup", false, ""); return }
        let tv = container.timelineView
        s.timelineZoom = 2
        s.addToTimeline(blue.id)
        let menuOK = LaneSelfTest.menuItem("영상 레인 추가")
        await LaneSelfTest.settle()
        guard menuOK, let top = s.timeline.lanes(.video).first?.id, top != Lane.videoID else { check("B.setup.lane", false, "\(s.timeline.lanes.map(\.name))"); return }
        let silentOnly = s.timeline.lanes(.audio).count == 1
        tv.drop(red.id, at: NSPoint(x: tv.x(0), y: tv.laneRect(top)?.midY ?? 0))
        await LaneSelfTest.settle()
        guard let rid = s.timeline.clips(inLane: top).first?.id else { check("B.setup.red", false, ""); return }
        check("B.silentVideoOnlyVideoLane", silentOnly && s.timeline.lanes(.audio).count == 1 && s.timeline.partner(of: rid) == nil && s.timeline.laneLabel(top) == "V2", "")
        s.select(rid); s.seek(to: 30)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation && host.playerLayer.isReadyForDisplay }
        await LaneSelfTest.settle()
        let sampler = Sampler()

        // 정보 패널 값(크기 50%): 정지 화면을 먼저 띄우고 다시 만든 뒤 내린다. 빈 화면 없음, 항목 교체 1
        let rep0 = s.itemReplacements
        sampler.start(host)
        s.setTransform(rid, ClipTransform(scalePermille: 500, offsetX: 0, offsetY: 0))
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation && !host.isShowingStill }
        try? await Task.sleep(nanoseconds: 100_000_000)
        sampler.stop()
        check("B.inspectorNoBlank", sampler.blanks == 0 && s.itemReplacements == rep0 + 1 && !host.isShowingStill && s.timeline.clip(rid)?.transform?.scaleMicro == 500_000,
              "blanks \(sampler.blanks)/\(sampler.samples) replacements \(s.itemReplacements - rep0)")
        guard await LaneSelfTest.regainFocus(w) else { return }

        func area() -> (x: CGFloat, y: CGFloat, k: CGFloat) {
            let b = ov.bounds, k = min(b.width / 1920, b.height / 1080)
            return ((b.width - 1920 * k) / 2, (b.height - 1080 * k) / 2, k)
        }
        func viewPoint(_ cx: CGFloat, _ cy: CGFloat) -> NSPoint { let a = area(); return ov.convert(NSPoint(x: a.x + cx * a.k, y: a.y + cy * a.k), to: nil) }
        /// 테두리 안쪽 끌기(steps번, 매번 dx·dy pt). perStep은 각 이동 뒤 불린다.
        func overlayDrag(steps: Int, dx: CGFloat, dy: CGFloat, release: Bool = true, perStep: (() async -> Void)? = nil) async -> NSPoint {
            let t = s.timeline.clip(rid)?.effectiveTransform ?? .identity
            var p = viewPoint(960 + CGFloat(t.x), 540 + CGFloat(t.y))
            await LaneSelfTest.mouse(.leftMouseDown, p, w)
            for _ in 0..<steps {
                p = NSPoint(x: p.x + dx, y: p.y - dy)
                await LaneSelfTest.mouse(.leftMouseDragged, p, w)
                await perStep?()
            }
            if release { await LaneSelfTest.mouse(.leftMouseUp, p, w) }
            return p
        }

        // 재현: 이전 경로(마우스 이동마다 composition 다시 만들기 + 항목 교체)
        s.legacyTransformPreviewForTest = true
        let repL = s.itemReplacements, dL = s.history.undoDepth
        sampler.start(host)
        _ = await overlayDrag(steps: 8, dx: 12, dy: 4) { try? await Task.sleep(nanoseconds: 60_000_000) }
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
        try? await Task.sleep(nanoseconds: 150_000_000)
        sampler.stop()
        let legacyBlanks = sampler.blanks, legacySamples = sampler.samples, legacyRep = s.itemReplacements - repL
        s.legacyTransformPreviewForTest = false
        check("B.reproduceLegacyFlicker", legacyRep >= 3 && legacyBlanks > 0 && s.history.undoDepth == dL + 1,
              "이전 경로: 항목 교체 \(legacyRep), 빈 화면 표본 \(legacyBlanks)/\(legacySamples)")
        await LaneSelfTest.key(6, "z", [.command], w)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation && host.playerLayer.isReadyForDisplay }
        await LaneSelfTest.settle()

        // 새 경로: 같은 끌기. 끌기 중 항목 교체 0, 정지 화면이 매 이동을 따라감, 빈 화면 0, 놓으면 교체 1 뒤 정지 화면 내림
        let repN = s.itemReplacements, dN = s.history.undoDepth, renders0 = s.interactive.renderCount
        let startT = s.timeline.clip(rid)?.effectiveTransform ?? .identity
        let startP = viewPoint(960 + CGFloat(startT.x), 540 + CGFloat(startT.y))
        let startHit = w.contentView.flatMap { cv in cv.hitTest(cv.superview?.convert(startP, from: nil) ?? startP) }.map { "\(type(of: $0))" } ?? "nil"
        let preState = "sel \(s.selection == rid) ov \(ov.state.clipID == rid) rect \(ov.state.rect.map { "\($0)" } ?? "nil") base \(s.gestureBase != nil) hit \(startHit) key \(NSApp.keyWindow === w) active \(NSApp.isActive)"
        var followed = 0, stillAlways = true
        sampler.start(host)
        let pEnd = await overlayDrag(steps: 8, dx: 12, dy: 4, release: false) {
            let before = s.interactive.renderCount
            _ = await LaneSelfTest.waitUntil(2) { s.interactive.renderCount > before && s.gestureTimeline != nil && s.interactive.lastTimeline == s.gestureTimeline }
            if s.gestureTimeline != nil && s.interactive.lastTimeline == s.gestureTimeline { followed += 1 }
            if !host.isShowingStill { stillAlways = false }
        }
        // 무대 캔버스 = 테두리 보기의 화면 사각형(레터박스 맞춤): 두 보기 모두 프리뷰 영역 전체, 가운데 맞춤 → 크기·가운데가 같아야 한다
        let cf = host.canvas.frame, va = ov.videoArea.rect
        let stageAligned = host.bounds.size == ov.bounds.size && abs(cf.width - va.width) < 0.01 && abs(cf.height - va.height) < 0.01
            && abs(cf.midX - va.midX) < 0.01 && abs(cf.midY - (ov.bounds.height - va.midY)) < 0.01
        let repDuring = s.itemReplacements - repN
        let gestureTimeline = s.gestureTimeline ?? s.timeline
        let historyUntouched = s.timeline != gestureTimeline   // 끌기 중에는 편집 기록(관찰되는 타임라인)을 바꾸지 않는다
        let stillImage = host.stageSnapshot()
        await LaneSelfTest.mouse(.leftMouseUp, pEnd, w)
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation && !host.isShowingStill }
        try? await Task.sleep(nanoseconds: 150_000_000)
        sampler.stop()
        check("B.dragNoBlankNoReplacement", repDuring == 0 && followed == 8 && stillAlways && historyUntouched && sampler.blanks == 0 && s.itemReplacements == repN + 1
              && !host.isShowingStill && s.history.undoDepth == dN + 1 && s.timeline == gestureTimeline,
              "끌기 중 교체 \(repDuring), 따라감 \(followed)/8, 정지 화면 유지 \(stillAlways), 빈 화면 \(sampler.blanks)/\(sampler.samples), 놓은 뒤 교체 \(s.itemReplacements - repN), 그림 \(s.interactive.renderCount - renders0), 마지막 적용 \(String(format: "%.1f", s.interactive.lastApplyMs)) ms, 시작 \(preState)")

        check("B.stageAlignedWithLetterbox", stageAligned, "canvas \(cf) overlay video \(va) host \(host.bounds.size) overlay \(ov.bounds.size)")
        // 정지 화면 = 최종 composition 프레임(같은 쌓음·변형): PSNR과 색 표본(빨강 사각형 안·밖)
        let t = s.timeline.clip(rid)?.effectiveTransform ?? .identity
        var comp: CGImage?
        if let plan = s.currentPlan { comp = await compositionFrame(plan, frame: 30) }
        let rect = CompositionPlanner.displayRect(red, t, render: CGSize(width: 1920, height: 1080))
        let psnrStill = (stillImage != nil && comp != nil) ? psnr(stillImage!, comp!) : 0
        let probes = stillImage.map { img in
            isRed(pixel(img, Int(rect.midX), Int(rect.midY))) && isBlue(pixel(img, Int(max(5, rect.minX - 20)), Int(rect.midY)))
                && isBlue(pixel(img, 5, 5)) == !(rect.minX <= 5 && rect.minY <= 5)
        } ?? false
        // 판정: 색 분류(빨강·파랑·검정) 지도가 같고(경계 거르기 차이만 허용) 채널 차가 작다. PSNR은 기록(색 변환의 고른 차이가 섞임).
        let statsStill = (stillImage != nil && comp != nil) ? diffStats(stillImage!, comp!) : (classMismatch: 1.0, maxDiff: 255, text: "n/a")
        // 왼쪽 경계 픽셀(가운데 줄): 넓이 비율 이상값 = 파랑 × (경계 − 픽셀 왼쪽) + 빨강 × 나머지
        let ex = Int(rect.minX.rounded(.down)), ey = Int(rect.midY), cov = 1 - (rect.minX - Double(ex))
        let ideal = (Int((220 * cov + 40 * (1 - cov)).rounded()), Int((40 * cov + 60 * (1 - cov)).rounded()), Int((40 * cov + 220 * (1 - cov)).rounded()))
        let edgePix = "경계 픽셀 (\(ex), \(ey)) 정지 \(stillImage.map { pixel($0, ex, ey) }.map { "\($0)" } ?? "-") composition \(comp.map { pixel($0, ex, ey) }.map { "\($0)" } ?? "-") 넓이 비율 \(ideal)"
        let edge = (stillImage != nil && comp != nil) ? edgeStats(stillImage!, comp!, rect: rect) : (maxOutsideBand: 255, over16InBand: -1, over16Outside: -1, bandPixels: 0, worst: "n/a")
        // 2026-10-11 부드러움 개선 뒤: 끌기 값이 소수라 사각형 경계가 픽셀 사이에 놓인다(예: x 774.252). 경계 픽셀은 두 그리기(GPU 레이어 무대,
        // AVFoundation 합성기)가 서로 다르게 거른다(경계 픽셀 넓이 비율 이상값에서 각각 반대쪽으로 0.2–0.3 px). 그래서 채널 차 ≤ 16은
        // 경계선에서 1 px 안의 띠를 뺀 곳에서 보고(띠 밖 16 넘는 픽셀 0), 색 분류 지도는 띠를 포함한 전체에서 본다. 띠 안 차이는 기록한다.
        check("B.stillMatchesComposition", probes && statsStill.classMismatch <= 0.002 && edge.maxOutsideBand <= 16 && edge.over16Outside == 0,
              String(format: "분류 불일치 %.4f%%, PSNR %.1f dB, rect %@, probes %@, %@ | 경계 띠 밖 최대 %d, 띠 안 >16 %d/%d, 띠 밖 >16 %d, %@", statsStill.classMismatch * 100, psnrStill, "\(rect)", probes ? "ok" : "MISMATCH", statsStill.text,
                     edge.maxOutsideBand, edge.over16InBand, edge.bandPixels, edge.over16Outside, edge.worst + " " + edgePix))

        // Esc: 끌기 전 변형·화면으로. 항목 교체 없음, 정지 화면 내림
        let beforeEsc = s.timeline, repE = s.itemReplacements, dE = s.history.undoDepth
        let pE = await overlayDrag(steps: 3, dx: 20, dy: 0, release: false) {
            let before = s.interactive.renderCount
            _ = await LaneSelfTest.waitUntil(2) { s.interactive.renderCount > before }
        }
        let movedE = s.gestureTimeline != nil && s.gestureTimeline != beforeEsc && s.timeline == beforeEsc && host.isShowingStill
        if LaneSelfTest.direct { ov.cancelOperation(nil) } else { await LaneSelfTest.key(53, "\u{1b}", [], w) }
        await LaneSelfTest.mouse(.leftMouseUp, pE, w)
        await LaneSelfTest.settle()
        check("B.escRestoresTransformAndPicture", movedE && s.timeline == beforeEsc && !host.isShowingStill && s.itemReplacements == repE
              && s.history.undoDepth == dE && host.playerLayer.isReadyForDisplay, "moved \(movedE) still \(host.isShowingStill) replacements \(s.itemReplacements - repE)")

        // 내보내기 프레임 30 = 프리뷰 composition 프레임 30
        let dest = out.appendingPathComponent("transform.mp4")
        s.startExport(.fromSavePanel(dest))
        _ = await LaneSelfTest.waitUntil(120) { s.exportPhase == .idle && s.alerts.isShowing }
        let exported = s.alert?.title == "내보내기 완료"
        while s.alerts.isShowing { s.alerts.pressButton(1); _ = await LaneSelfTest.waitUntil(3) { !s.alerts.isShowing } }
        var psnrExport = 0.0
        var statsExport: (classMismatch: Double, maxDiff: Int, text: String) = (1, 255, "n/a")
        if exported, let c = comp, let e = await fileFrame(dest, frame: 30) { psnrExport = psnr(e, c); statsExport = diffStats(e, c) }
        // 내보내기는 H.264(4:2:0) 압축이라 채널 차는 보지 않고 색 분류 지도(사각형 위치·크기·쌓음)만 본다
        check("B.exportMatchesPreview", exported && statsExport.classMismatch <= 0.005,
              String(format: "분류 불일치 %.4f%%, PSNR %.1f dB, %@", statsExport.classMismatch * 100, psnrExport, statsExport.text))
    }

    // MARK: - 그림 도우미

    static func compositionFrame(_ plan: PlannedComposition, frame: Int) async -> CGImage? {
        let g = AVAssetImageGenerator(asset: plan.composition)
        g.videoComposition = plan.videoComposition
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        return try? await g.image(at: plan.settings.time(frame)).image
    }
    static func fileFrame(_ url: URL, frame: Int) async -> CGImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        return try? await g.image(at: CMTime(value: CMTimeValue(frame), timescale: 30)).image
    }
    /// 1920×1080 RGBA로 그려 바이트 배열로
    static func rgba(_ img: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 1920 * 1080 * 4)
        buf.withUnsafeMutableBytes { p in
            if let ctx = CGContext(data: p.baseAddress, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            }
        }
        return buf
    }
    static func psnr(_ a: CGImage, _ b: CGImage) -> Double {
        let x = rgba(a), y = rgba(b)
        var se = 0.0, n = 0
        for i in stride(from: 0, to: x.count, by: 4) { for c in 0..<3 { let d = Double(x[i + c]) - Double(y[i + c]); se += d * d; n += 1 } }
        let mse = se / Double(max(1, n))
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
    /// 차이 통계: 채널별 평균 차(부호 있음), 최대 차, 16 넘는 픽셀 비율, 그 픽셀의 경계 상자
    static func diffStats(_ a: CGImage, _ b: CGImage) -> (classMismatch: Double, maxDiff: Int, text: String) {
        let x = rgba(a), y = rgba(b)
        /// 가장 가까운 기준색: 0 검정, 1 빨강 판, 2 파랑 판
        func cls(_ v: [UInt8], _ i: Int) -> Int {
            let ref = [(0, 0, 0), (220, 40, 40), (40, 60, 220)]
            return ref.indices.min { a, b in
                let d = { (r: (Int, Int, Int)) in (Int(v[i]) - r.0) * (Int(v[i]) - r.0) + (Int(v[i + 1]) - r.1) * (Int(v[i + 1]) - r.1) + (Int(v[i + 2]) - r.2) * (Int(v[i + 2]) - r.2) }
                return d(ref[a]) < d(ref[b])
            }!
        }
        var sum = [0.0, 0.0, 0.0], mx = 0, mism = 0
        for i in stride(from: 0, to: x.count, by: 4) {
            var m = 0
            for c in 0..<3 { let d = Int(x[i + c]) - Int(y[i + c]); sum[c] += Double(d); m = max(m, abs(d)) }
            mx = max(mx, m)
            if cls(x, i) != cls(y, i) { mism += 1 }
        }
        let n = Double(x.count / 4)
        return (Double(mism) / n, mx, String(format: "평균 차 (%.1f, %.1f, %.1f) 최대 %d", sum[0] / n, sum[1] / n, sum[2] / n, mx))
    }
    /// 사각형 경계(가장자리 픽셀 띠, 경계선에서 1 px 안)를 뺀 곳의 최대 채널 차와, 띠 안·밖에서 차가 16을 넘는 픽셀 수와 가장 큰 차의 위치
    static func edgeStats(_ a: CGImage, _ b: CGImage, rect r: CGRect) -> (maxOutsideBand: Int, over16InBand: Int, over16Outside: Int, bandPixels: Int, worst: String) {
        let x = rgba(a), y = rgba(b)
        var mx = 0, inBand = 0, outside = 0, band = 0, worst = (0, 0, 0)
        for py in 0..<1080 {
            for px in 0..<1920 {
                let cx = Double(px) + 0.5, cy = Double(py) + 0.5
                let nearX = (abs(cx - r.minX) < 1 || abs(cx - r.maxX) < 1) && cy > r.minY - 1 && cy < r.maxY + 1
                let nearY = (abs(cy - r.minY) < 1 || abs(cy - r.maxY) < 1) && cx > r.minX - 1 && cx < r.maxX + 1
                let i = (py * 1920 + px) * 4
                var m = 0
                for c in 0..<3 { m = max(m, abs(Int(x[i + c]) - Int(y[i + c]))) }
                if m > worst.2 { worst = (px, py, m) }
                if nearX || nearY { band += 1; if m > 16 { inBand += 1 } } else { mx = max(mx, m); if m > 16 { outside += 1 } }
            }
        }
        return (mx, inBand, outside, band, "가장 큰 차 \(worst.2) @(\(worst.0), \(worst.1))")
    }
    /// 출력 좌표(왼쪽 위 원점)의 픽셀
    static func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let b = rgba(img), i = (y * 1920 + x) * 4   // CGContext 바이트 배열의 첫 줄은 그림의 위쪽 줄
        return (Int(b[i]), Int(b[i + 1]), Int(b[i + 2]))
    }
    static func isRed(_ p: (Int, Int, Int)) -> Bool { p.0 > 150 && p.1 < 100 && p.2 < 100 }
    static func isBlue(_ p: (Int, Int, Int)) -> Bool { p.2 > 150 && p.0 < 100 }

    static func finish(_ folder: URL, _ checks: [Check], _ m: Manifest?) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: LaneSelfTest.direct ? "앱을 활성화할 수 없어 마우스는 보기에 직접, 키는 같은 저장소 동작으로 보냄" : "합성 이벤트를 앱 이벤트 큐로 보냄")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let m, let d = try? enc.encode(m) { try? d.write(to: folder.appendingPathComponent("editfix-manifest.json")) }
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("editfix-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
