#if DEBUG
import AppKit
import OnTheFrameEngine

/// 변형 끌기 측정 기록(Debug 전용). 프리뷰 테두리 끌기의 포인터 처리 시간, 화면에 보인 끌기 그림의 갱신 시각·값, 주 실행 루프의 바쁜 시간을 모은다.
/// 기록은 측정 자체 검사(TransformPerfSelfTest)가 켰을 때만 한다.
@MainActor
final class PerfProbe {
    static let shared = PerfProbe()
    struct Value: Codable, Equatable { let scale: Double; let x: Double; let y: Double }
    struct Event: Codable { let t: Double; let handlerMs: Double; let value: Value }
    struct Shown: Codable { let t: Double; let value: Value }
    var enabled = false
    private(set) var events: [Event] = []
    private(set) var shown: [Shown] = []
    private(set) var busy: [(start: Double, ms: Double)] = []
    private(set) var renderMs: [Double] = []
    private var observer: CFRunLoopObserver?
    private var wake: Double?
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    func start() {
        events = []; shown = []; busy = []; renderMs = []; enabled = true
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, act in
            MainActor.assumeIsolated {
                let p = PerfProbe.shared
                if act == .afterWaiting { p.wake = Self.now() }
                else if let w = p.wake { p.busy.append((w, Self.now() - w)); p.wake = nil }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
    }
    func stop() {
        enabled = false
        if let o = observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
        observer = nil
    }
    func dragged(start: Double, value: Value) {
        guard enabled else { return }
        events.append(Event(t: start, handlerMs: Self.now() - start, value: value))
    }
    func didShow(_ v: Value) { guard enabled else { return }; shown.append(Shown(t: Self.now(), value: v)) }
    func rendered(ms: Double) { guard enabled else { return }; renderMs.append(ms) }
}

/// 변형 끌기 측정 자체 검사. `open -n -W -a OnTheFrame.app <폴더> --args -OTFTransformPerfTest`. 결과는 <폴더>/perf-result.json.
/// 배치: V1 otf-TA(1920×1080), V2 otf-TB(1920×1080, 50%). TB를 고르고 재생 헤드 30. 프리뷰 테두리에
/// (1) 오른쪽 아래 손잡이 크기 조절, (2) 안쪽 옮기기를 각각 포인터 100번(약 8 ms 간격, 2 pt씩) 보낸다.
/// 잰 것: 포인터 처리 시간, 보인 끌기 그림 갱신 수·간격·포인터에서 화면까지 지연, 주 실행 루프 바쁜 시간(한 번 16.7 ms 넘은 수),
/// 화면 갱신 사이 크기(테두리 너비)의 가장 큰 한 번 변화. 합성 이벤트 측정이며 실제 손 끌기의 부드러움을 대신하지 않는다.
@MainActor
enum TransformPerfSelfTest {
    typealias Check = LaneSelfTest.Check
    struct Stats: Codable {
        let scenario: String
        let events: Int, durationMs: Double
        let handlerMeanMs: Double, handlerMaxMs: Double
        let busyFraction: Double, busyMaxMs: Double, busyOver16: Int
        let shownUpdates: Int, shownIntervalMeanMs: Double, shownIntervalMaxMs: Double
        let latencyMeanMs: Double, latencyMaxMs: Double, unmatchedShown: Int
        let renderMeanMs: Double, renderMaxMs: Double, renders: Int
        let maxWidthJumpPt: Double, pointerWidthStepPt: Double
        let finalValue: PerfProbe.Value?, lastPointerValue: PerfProbe.Value?
    }
    struct Result: Codable { let mode: String; let stats: [Stats]; let checks: [Check] }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)) }
        let src = folder.appendingPathComponent("sources")
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { return finish(folder, [], [Check(name: "setup.window", pass: false, detail: "")]) }
        w.makeKeyAndOrderFront(nil)
        if !(await LaneSelfTest.regainFocus(w)) { LaneSelfTest.direct = true }
        s.importFiles(["otf-TA.mp4", "otf-TB.mp4"].map { src.appendingPathComponent($0) })
        _ = await LaneSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 2 }
        let by = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.name, $0) })
        guard let ta = by["otf-TA.mp4"], let tb = by["otf-TB.mp4"], let ov = LaneSelfTest.find(PreviewOverlayView.self, w.contentView) else {
            return finish(folder, [], [Check(name: "setup", pass: false, detail: "")])
        }
        s.addToTimeline(ta.id)
        s.addLanePair()
        guard let top = s.timeline.lanes(.video).first?.id, top != Lane.videoID, let topA = s.timeline.lanes(.audio).last?.id else {
            return finish(folder, [], [Check(name: "setup.lane", pass: false, detail: "")])
        }
        s.placeMedia(tb.id, atFrame: 0, lane: top)
        _ = topA
        guard let tid = s.timeline.clips(inLane: top).first?.id else { return finish(folder, [], [Check(name: "setup.top", pass: false, detail: "")]) }
        s.select(tid); s.seek(to: 30)
        s.setTransform(tid, ClipTransform(scalePermille: 500, offsetX: 0, offsetY: 0))
        _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation && !(s.previewHost?.isShowingStill ?? true) }
        await LaneSelfTest.settle()
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, [], [Check(name: "focus", pass: false, detail: "")]) }

        var stats: [Stats] = []
        // 테두리 너비(보기 pt) — 화면 갱신 사이 변화의 기준
        func widthPt(_ v: PerfProbe.Value) -> Double { 1920 * v.scale * Double(ov.videoArea.k) }
        func value(_ t: ClipTransform) -> PerfProbe.Value { PerfProbe.Value(scale: t.scale, x: t.x, y: t.y) }

        for scenario in ["resize", "move"] {
            let base = s.timeline, depth = s.history.undoDepth
            let rect = ov.state.rect.map(ov.toView) ?? .zero
            let p0v = scenario == "resize" ? NSPoint(x: rect.maxX, y: rect.maxY) : NSPoint(x: rect.midX, y: rect.midY)
            var p = ov.convert(p0v, to: nil)
            let step = scenario == "resize" ? NSSize(width: 2, height: 0) : NSSize(width: 2, height: 1)
            let ticks0 = ov.ticks
            PerfProbe.shared.start()
            let t0 = PerfProbe.now()
            await post(.leftMouseDown, p, w)
            try? await Task.sleep(nanoseconds: 8_000_000)
            for _ in 0..<100 {
                p = NSPoint(x: p.x + step.width, y: p.y - step.height)   // 창 좌표는 위 +Y
                await post(.leftMouseDragged, p, w)
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
            // 마지막 포인터 값이 화면에 보일 시간
            try? await Task.sleep(nanoseconds: 100_000_000)
            let t1 = PerfProbe.now()
            PerfProbe.shared.stop()
            let probe = PerfProbe.shared
            await post(.leftMouseUp, p, w)
            _ = await LaneSelfTest.waitUntil(10) { s.gestureBase == nil && s.appliedGeneration == s.generation && !(s.previewHost?.isShowingStill ?? false) }
            await LaneSelfTest.settle()
            let final = s.timeline.clip(tid).map { value($0.effectiveTransform) }
            let ev = probe.events, sh = probe.shown
            let busy = probe.busy.filter { $0.start >= t0 && $0.start <= t1 }
            func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }
            let intervals = zip(sh.dropFirst(), sh).map { $0.t - $1.t }
            var lat: [Double] = []; var unmatched = 0
            for x in sh { if let e = ev.last(where: { $0.value == x.value && $0.t <= x.t }) { lat.append(x.t - e.t) } else { unmatched += 1 } }
            let jumps = zip(sh.dropFirst(), sh).map { abs(widthPt($0.value) - widthPt($1.value)) }
            stats.append(Stats(scenario: scenario, events: ev.count, durationMs: t1 - t0,
                               handlerMeanMs: mean(ev.map(\.handlerMs)), handlerMaxMs: ev.map(\.handlerMs).max() ?? 0,
                               busyFraction: busy.map(\.ms).reduce(0, +) / max(1, t1 - t0), busyMaxMs: busy.map(\.ms).max() ?? 0, busyOver16: busy.filter { $0.ms > 16.7 }.count,
                               shownUpdates: sh.count, shownIntervalMeanMs: mean(intervals), shownIntervalMaxMs: intervals.max() ?? 0,
                               latencyMeanMs: mean(lat), latencyMaxMs: lat.max() ?? 0, unmatchedShown: unmatched,
                               renderMeanMs: mean(probe.renderMs), renderMaxMs: probe.renderMs.max() ?? 0, renders: probe.renderMs.count,
                               maxWidthJumpPt: jumps.max() ?? 0, pointerWidthStepPt: scenario == "resize" ? 2 : 0,
                               finalValue: final, lastPointerValue: ev.last?.value))
            check("\(scenario).displayTicks", ov.ticks > ticks0, "ticks \(ov.ticks - ticks0) link \(ov.linkDescription) window \(ov.window != nil) screen \(ov.window?.screen != nil)")
            check("\(scenario).oneUndoStep", s.history.undoDepth == depth + 1 && s.timeline != base, "depth \(s.history.undoDepth - depth)")
            check("\(scenario).finalEqualsLastPointer", final != nil && final == ev.last?.value, "final \(String(describing: final)) last \(String(describing: ev.last?.value))")
            await LaneSelfTest.key(6, "z", [.command], w)
            _ = await LaneSelfTest.waitUntil(10) { s.appliedGeneration == s.generation }
            check("\(scenario).undoRestores", s.timeline == base)
            await LaneSelfTest.settle()
        }
        finish(folder, stats, checks)
    }

    /// 포인터 하나(기다리지 않음): 이벤트 경로는 앱 이벤트 큐로, 직접 경로는 보기에 바로
    static func post(_ t: NSEvent.EventType, _ p: NSPoint, _ w: NSWindow) async {
        guard let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1) else { return }
        if LaneSelfTest.direct, let cv = w.contentView {
            if t == .leftMouseDown { LaneSelfTest.directTarget = cv.hitTest(cv.superview?.convert(p, from: nil) ?? p) }
            let target = LaneSelfTest.directTarget ?? cv
            switch t { case .leftMouseDown: target.mouseDown(with: e); case .leftMouseDragged: target.mouseDragged(with: e); default: target.mouseUp(with: e) }
        } else { NSApp.postEvent(e, atStart: false) }
    }

    static func finish(_ folder: URL, _ stats: [Stats], _ checks: [Check]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let r = Result(mode: LaneSelfTest.direct ? "direct" : "events", stats: stats, checks: checks)
        if let d = try? enc.encode(r) { try? d.write(to: folder.appendingPathComponent("perf-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
