import AppKit
import OnTheFrameEngine
import SwiftUI

/// 아래 영역: 상태 줄·확대 조절 + AppKit 타임라인(왼쪽 고정 레인 머리, 눈금자, 영상 레인·원본 소리 레인, 재생 헤드). A-012.
struct TimelinePane: View {
    @Bindable var store: ProjectStore
    @State private var pixelsPerFrame: Double = 2

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("타임라인").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let m = store.statusMessage { Text(m).font(.callout).foregroundStyle(.orange).lineLimit(1) }
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $pixelsPerFrame, in: 0.2...12).frame(width: 120).help("타임라인 확대")
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            ZStack {
                TimelineRepresentable(store: store, state: TimelineDrawState(store: store), pixelsPerFrame: pixelsPerFrame)
                if store.timeline.isEmpty && store.durationFrames == 0 {
                    Text(store.assets.isEmpty ? "영상을 가져온 뒤 여기로 끌어 놓거나 목록의 + 단추를 누르세요"
                                              : "왼쪽 목록의 영상을 여기로 끌어 놓거나 + 단추를 누르세요")
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
        }
    }
}

/// 그리기에 필요한 값의 사본(SwiftUI 관찰이 이 값의 변화를 감지한다)
struct TimelineDrawState: Equatable {
    var timeline: Timeline
    var names: [UUID: String]
    var selection: UUID?
    var selected: Set<UUID>
    var candidate: UUID?
    var playhead: Int
    var insertion: Int?
    var proposalStart: Int?, proposalOK: Bool, proposalID: UUID?
    @MainActor init(store: ProjectStore) {
        timeline = store.timeline
        names = Dictionary(uniqueKeysWithValues: store.assets.map { ($0.id, $0.name) })
        selection = store.selection
        selected = store.selectedIDs
        candidate = store.linkCandidate
        playhead = store.playhead
        insertion = store.moveInsertionIndex
        proposalStart = store.freeMoveProposal?.start; proposalOK = store.freeMoveProposal?.ok ?? true; proposalID = store.freeMoveProposal?.id
    }
}

struct TimelineRepresentable: NSViewRepresentable {
    let store: ProjectStore
    let state: TimelineDrawState
    let pixelsPerFrame: Double

    func makeNSView(context: Context) -> TimelineContainerView { TimelineContainerView(store: store) }
    func updateNSView(_ c: TimelineContainerView, context: Context) {
        let v = c.timelineView, sv = c.scrollView
        v.state = state
        v.pixelsPerFrame = CGFloat(pixelsPerFrame)
        let w = max(sv.contentSize.width, TimelineNSView.inset * 2 + CGFloat(state.timeline.durationFrames) * v.pixelsPerFrame + 200)
        v.setFrameSize(NSSize(width: w, height: max(sv.contentSize.height, TimelineNSView.contentHeight)))
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
        c.header.lanes = state.timeline.lanes
        c.header.needsDisplay = true
    }
}

/// 레인 머리(왼쪽 고정, 가로 스크롤과 무관) + 가로로 스크롤하는 타임라인
final class TimelineContainerView: NSView {
    let header: LaneHeaderView
    let scrollView = NSScrollView()
    let timelineView: TimelineNSView
    init(store: ProjectStore) {
        header = LaneHeaderView(store: store)
        timelineView = TimelineNSView(store: store)
        super.init(frame: .zero)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.documentView = timelineView
        addSubview(header); addSubview(scrollView)
        // 세로 스크롤은 머리와 함께 움직이게 맞춘다(가로 스크롤은 머리에 영향 없음)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.header.verticalOffset = self.scrollView.contentView.bounds.minY; self.header.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: LaneHeaderView.width, height: bounds.height)
        scrollView.frame = NSRect(x: LaneHeaderView.width, y: 0, width: max(0, bounds.width - LaneHeaderView.width), height: bounds.height)
    }
}

/// 레인 머리: 레인 이름. 두 번 클릭하거나 문맥 메뉴로 이름을 바꾼다(Return 확정, Esc 취소, 빈 이름은 이전 이름 유지, 실행 취소 한 단계).
/// 편집 중에는 텍스트 칸(필드 편집기)이 첫 응답자라 타임라인 단축키가 입력을 가로채지 않는다(KeyRouting.isTextInput).
final class LaneHeaderView: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 112
    let store: ProjectStore
    var lanes: [Lane] = Lane.defaults
    var verticalOffset: CGFloat = 0
    private(set) var editor: NSTextField?
    private(set) var editingLane: UUID?
    private var finishing = false
    init(store: ProjectStore) { self.store = store; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func rowRect(_ kind: LaneKind) -> NSRect {
        let r = TimelineNSView.laneRect(kind)
        return NSRect(x: 0, y: r.minY - verticalOffset, width: bounds.width, height: r.height)
    }
    func lane(at p: NSPoint) -> Lane? { lanes.first { rowRect($0.kind).contains(p) } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: TimelineNSView.rulerHeight - 1, width: bounds.width, height: 1).fill()
        for l in lanes where l.id != editingLane {
            let r = rowRect(l.kind)
            (l.kind == .video ? NSColor.systemTeal : NSColor.systemGreen).withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 2), xRadius: 4, yRadius: 4).fill()
            let icon = NSImage(systemSymbolName: l.kind == .video ? "film" : "waveform", accessibilityDescription: nil)
            icon?.draw(in: NSRect(x: r.minX + 8, y: r.midY - 7, width: 14, height: 14))
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
            NSString(string: l.name).draw(with: NSRect(x: r.minX + 28, y: r.midY - 8, width: r.width - 34, height: 16),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2, let l = lane(at: p) { beginRename(l.id) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let l = lane(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let m = NSMenu()
        let item = NSMenuItem(title: "레인 이름 바꾸기…", action: #selector(renameFromMenu(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = l.id
        m.addItem(item)
        return m
    }
    @objc private func renameFromMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { beginRename(id) } }

    func beginRename(_ id: UUID) {
        guard editor == nil, let l = lanes.first(where: { $0.id == id }), store.gestureBase == nil else { return }
        let f = NSTextField(string: l.name)
        f.font = .systemFont(ofSize: 12, weight: .semibold)
        f.delegate = self
        f.focusRingType = .default
        f.setAccessibilityLabel("레인 이름")
        f.frame = rowRect(l.kind).insetBy(dx: 4, dy: max(2, (rowRect(l.kind).height - 22) / 2))
        addSubview(f)
        editor = f; editingLane = id; finishing = false
        needsDisplay = true
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }
    /// Return: 확정, Esc: 취소(이전 이름)
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { finish(commit: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { finish(commit: false); return true }
        return false
    }
    /// 다른 곳을 눌러 초점을 잃으면 확정한다
    func controlTextDidEndEditing(_ obj: Notification) { finish(commit: true) }
    func finish(commit: Bool) {
        guard !finishing, let f = editor, let id = editingLane else { return }
        finishing = true
        let text = f.stringValue
        editor = nil; editingLane = nil
        f.removeFromSuperview()
        if commit { store.renameLane(id, to: text) }   // 빈 이름이면 바꾸지 않고 이전 이름 유지(상태 줄에 안내)
        needsDisplay = true
        if let tv = (superview as? TimelineContainerView)?.timelineView { window?.makeFirstResponder(tv) }
    }
}

final class TimelineNSView: NSView {
    static let inset: CGFloat = 12, rulerHeight: CGFloat = 24, edgeGrab: CGFloat = 6
    static let videoY: CGFloat = 30, videoHeight: CGFloat = 54, audioY: CGFloat = 92, audioHeight: CGFloat = 40
    static let contentHeight: CGFloat = audioY + audioHeight + 12
    /// 이전 이름(영상 레인), 자체 검사 호환
    static let trackY = videoY, trackHeight = videoHeight
    static func laneRect(_ k: LaneKind) -> NSRect {
        k == .video ? NSRect(x: 0, y: videoY, width: 0, height: videoHeight) : NSRect(x: 0, y: audioY, width: 0, height: audioHeight)
    }
    let store: ProjectStore
    var state: TimelineDrawState?
    var pixelsPerFrame: CGFloat = 2

    private enum Drag { case none, scrub, pending(UUID, NSPoint), move(UUID), free(UUID, CGFloat), trim(UUID, ProjectStore.TrimEdge, CGFloat) }
    private var drag: Drag = .none

    init(store: ProjectStore) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func x(_ frame: Int) -> CGFloat { Self.inset + CGFloat(frame) * pixelsPerFrame }
    private func frame(atX px: CGFloat) -> Int { Int(((px - Self.inset) / pixelsPerFrame).rounded()) }
    private func rect(_ c: Clip, _ k: LaneKind, start: Int? = nil) -> NSRect {
        let l = Self.laneRect(k)
        return NSRect(x: x(start ?? c.start), y: l.minY, width: max(1, CGFloat(c.length) * pixelsPerFrame), height: l.height)
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        guard let st = state else { return }
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        drawRuler(st)
        let t = st.timeline
        for (k, gaps) in [(LaneKind.video, t.gaps), (.audio, t.audioGaps)] {
            let l = Self.laneRect(k)
            for g in gaps { drawGap(NSRect(x: x(g.lowerBound), y: l.minY, width: CGFloat(g.count) * pixelsPerFrame, height: l.height), label: k == .video ? "빈틈" : "무음") }
        }
        if t.durationFrames > 0 {   // 타임라인 끝(길이)
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: x(t.durationFrames) - 0.5, y: Self.videoY - 6, width: 1, height: Self.audioY + Self.audioHeight - Self.videoY + 12).fill()
        }
        for c in t.clips { drawClip(c, .video, st) }
        for c in t.audioClips { drawClip(c, .audio, st) }
        // 자유 이동 제안 위치(놓을 수 없으면 빨강)
        if let id = st.proposalID, let s = st.proposalStart, !st.proposalOK, let base = store.gestureBase, let c = base.clip(id), let k = base.lane(of: id) {
            let r = rect(c, k, start: s)
            NSColor.systemRed.withAlphaComponent(0.25).setFill(); r.fill()
            NSColor.systemRed.setStroke(); let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
        }
        if let ins = st.insertion, case .move = drag, let base = store.gestureBase {   // 끼워 넣을 자리(두 레인)
            let bx = x(ins < base.clips.count ? base.starts[ins] : base.durationFrames)
            NSColor.systemYellow.setFill()
            NSRect(x: bx - 1.5, y: Self.videoY - 4, width: 3, height: Self.audioY + Self.audioHeight - Self.videoY + 8).fill()
        }
        let ph = x(min(st.playhead, t.durationFrames))
        NSColor.systemRed.setFill()
        NSRect(x: ph - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: ph - 5, y: 0)); tri.line(to: NSPoint(x: ph + 5, y: 0)); tri.line(to: NSPoint(x: ph, y: 7)); tri.close()
        tri.fill()
    }

    private func drawGap(_ r: NSRect, label: String) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        NSColor.black.withAlphaComponent(0.55).setFill(); r.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
        let hatch = NSBezierPath(); hatch.lineWidth = 1
        var hx = r.minX - r.height
        while hx < r.maxX { hatch.move(to: NSPoint(x: hx, y: r.maxY)); hatch.line(to: NSPoint(x: hx + r.height, y: r.minY)); hx += 8 }
        hatch.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if r.width > 40 {
            NSString(string: label).draw(at: NSPoint(x: r.minX + 6, y: r.minY + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    private func drawClip(_ c: Clip, _ k: LaneKind, _ st: TimelineDrawState) {
        let r = rect(c, k)
        let selected = st.selected.contains(c.id), candidate = c.id == st.candidate
        let base = k == .video ? NSColor.systemTeal : NSColor.systemGreen
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (selected && !candidate ? NSColor.controlAccentColor.withAlphaComponent(0.5) : base.withAlphaComponent(0.35)).setFill()
        path.fill()
        if candidate { path.setLineDash([4, 3], count: 2, phase: 0) }
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
        var labelX = r.minX + 6
        if c.link != nil, r.width > 20, let img = NSImage(systemSymbolName: "link", accessibilityDescription: "연결됨") {
            img.draw(in: NSRect(x: r.minX + 5, y: r.minY + 5, width: 11, height: 11)); labelX += 14
        }
        if r.width > 30 {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
            NSString(string: (k == .audio ? "♪ " : "") + (st.names[c.mediaID] ?? "")).draw(with: NSRect(x: labelX, y: r.minY + 4, width: max(0, r.maxX - labelX - 6), height: 16),
                                                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        // 동기 어긋남 표시(연결된 쌍이 어긋났을 때 두 클립 모두): 소리가 영상보다 늦으면 +
        if let o = st.timeline.syncOffset(of: c.id), o != 0 {
            let text = NSString(string: (o > 0 ? "+" : "−") + "\(abs(o))f")
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
            let sz = text.size(withAttributes: attrs)
            let b = NSRect(x: max(r.minX + 4, r.maxX - sz.width - 12), y: r.maxY - sz.height - 6, width: sz.width + 8, height: sz.height + 2)
            NSColor.systemRed.setFill(); NSBezierPath(roundedRect: b, xRadius: b.height / 2, yRadius: b.height / 2).fill()
            text.draw(at: NSPoint(x: b.minX + 4, y: b.minY + 1), withAttributes: attrs)
        }
        if c.id == st.selection || (selected && !candidate && st.selection.map { st.timeline.group(of: $0).contains { $0.id == c.id } } == true) {   // 트림 손잡이
            NSColor.controlAccentColor.setFill()
            NSRect(x: r.minX, y: r.minY + 6, width: 3, height: r.height - 12).fill()
            NSRect(x: r.maxX - 3, y: r.minY + 6, width: 3, height: r.height - 12).fill()
        }
    }

    private func drawRuler(_ st: TimelineDrawState) {
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight).fill()
        let fps = Int(store.settings.fps)
        // 눈금 간격: 라벨이 70px 이상 떨어지도록 초 단위 선택
        let candidates = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let stepSec = candidates.first { CGFloat($0 * fps) * pixelsPerFrame >= 70 } ?? 600
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let lastFrame = frame(atX: bounds.width)
        var f = 0
        NSColor.tertiaryLabelColor.setFill()
        while f <= lastFrame {
            let px = x(f)
            NSRect(x: px, y: Self.rulerHeight - 8, width: 1, height: 8).fill()
            let s = f / fps
            NSString(string: String(format: "%d:%02d", s / 60, s % 60)).draw(at: NSPoint(x: px + 3, y: 4), withAttributes: attrs)
            f += stepSec * fps
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: Self.rulerHeight - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: 마우스

    func clipHit(_ p: NSPoint) -> (UUID, ProjectStore.TrimEdge?)? {
        guard let st = state else { return nil }
        for (k, cs) in [(LaneKind.video, st.timeline.clips), (.audio, st.timeline.audioClips)] {
            let l = Self.laneRect(k)
            guard p.y >= l.minY, p.y <= l.maxY else { continue }
            for c in cs {
                let x0 = x(c.start), x1 = x(c.end)
                guard p.x >= x0 - 1, p.x <= x1 + 1 else { continue }
                let grab = min(Self.edgeGrab, (x1 - x0) / 3)
                if p.x <= x0 + grab { return (c.id, .start) }
                if p.x >= x1 - grab { return (c.id, .end) }
                return (c.id, nil)
            }
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if p.y < Self.videoY {
            store.pauseForEdit(); drag = .scrub; store.seek(to: frame(atX: p.x)); return
        }
        if let (id, edge) = clipHit(p) {
            if e.modifierFlags.contains(.command) { store.select(id, extend: true); drag = .none; return }   // 연결 후보
            if let edge {
                store.beginGesture(select: id)
                drag = .trim(id, edge, p.x)
            } else {
                store.pauseForEdit()
                store.select(id)
                drag = .pending(id, p)
            }
        } else {
            store.select(nil); drag = .none
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        autoscroll(with: e)
        switch drag {
        case .scrub:
            store.seek(to: frame(atX: p.x))
        case .pending(let id, let p0):
            guard abs(p.x - p0.x) > 4 else { return }
            store.beginGesture(select: id)
            if store.timeline.movesFreely(id) {   // 연결을 해제한 클립: 같은 레인 안 자유 이동(빈틈에 놓기)
                drag = .free(id, p0.x)
                store.updateFreeMove(id, delta: Int(((p.x - p0.x) / pixelsPerFrame).rounded()))
            } else {
                drag = .move(id)
                store.updateMove(id, toIndex: insertionIndex(p.x))
            }
        case .move(let id):
            store.updateMove(id, toIndex: insertionIndex(p.x))
        case .free(let id, let x0):
            store.updateFreeMove(id, delta: Int(((p.x - x0) / pixelsPerFrame).rounded()))
        case .trim(let id, let edge, let x0):
            let d = Int(((p.x - x0) / pixelsPerFrame).rounded())
            store.updateTrim(id, edge: edge, delta: d)
        case .none:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        switch drag {
        case .move, .trim, .free: store.commitGesture()
        default: break
        }
        drag = .none
    }

    /// 클립 문맥 메뉴: 연결 해제·연결·자르기·삭제(대상과 범위를 제목에 보인다)
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let (id, _) = clipHit(p) else { return nil }
        if !store.selectedIDs.contains(id) { store.select(id) }
        let linked = store.timeline.partner(of: store.selection ?? id) != nil
        let m = NSMenu()
        func add(_ title: String, _ enabled: Bool, _ action: Selector) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: ""); it.target = self; it.isEnabled = enabled; m.addItem(it)
        }
        m.autoenablesItems = false
        add("연결 해제(영상·소리 따로 편집)", store.canUnlink, #selector(menuUnlink))
        add("연결(⌘-클릭한 클립과)", store.canLink, #selector(menuLink))
        m.addItem(.separator())
        add(linked ? "재생 헤드에서 자르기(연결된 쌍)" : "재생 헤드에서 자르기", store.gestureBase == nil, #selector(menuSplit))
        add(linked ? "삭제 — 빈틈 남김(연결된 쌍)" : "삭제 — 빈틈 남김", store.gestureBase == nil, #selector(menuLift))
        add(linked ? "리플 삭제(연결된 쌍, 두 레인)" : "리플 삭제(두 레인)", store.gestureBase == nil, #selector(menuRipple))
        return m
    }
    @objc private func menuUnlink() { store.unlinkSelection() }
    @objc private func menuLink() { store.linkSelection() }
    @objc private func menuSplit() { store.splitAtPlayhead() }
    @objc private func menuLift() { store.deleteSelection(ripple: false) }
    @objc private func menuRipple() { store.deleteSelection(ripple: true) }

    /// 드래그 중 Esc: 드래그 전 상태로 되돌린다(기록 없음).
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { cancelOperation(nil); return }
        // 보조 처리 층: 로컬 감시를 지나지 않고 전달된 편집기 단축키(KeyRouting 설명 참조)
        if KeyRouting.route(e, layer: "timelineKeyDown", store: store) { return }
        super.keyDown(with: e)
    }
    override func cancelOperation(_ sender: Any?) {
        switch drag {
        case .move, .trim, .free: store.cancelGesture(); drag = .none
        default: break
        }
    }

    /// 드래그 시작 시점 타임라인에서 끼워 넣을 자리(영상 레인 클립 가운데를 기준으로)
    private func insertionIndex(_ px: CGFloat) -> Int {
        guard let base = store.gestureBase ?? state?.timeline else { return 0 }
        let f = CGFloat(frame(atX: px))
        return base.clips.filter { CGFloat($0.start) + CGFloat($0.length) / 2 < f }.count
    }

    override func resetCursorRects() {
        guard let st = state, let sel = st.selection else { return }
        for c in st.timeline.group(of: sel) {
            guard let k = st.timeline.lane(of: c.id) else { continue }
            let r = rect(c, k)
            addCursorRect(NSRect(x: r.minX - 2, y: r.minY, width: Self.edgeGrab + 2, height: r.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: r.maxX - Self.edgeGrab, y: r.minY, width: Self.edgeGrab + 2, height: r.height), cursor: .resizeLeftRight)
        }
    }

    // MARK: 영상 목록에서 끌어 놓기

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { mediaID(sender) != nil ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { mediaID(sender) != nil ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = mediaID(sender) else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        store.addToTimeline(id, at: insertionIndex(p.x))
        return true
    }
    private func mediaID(_ s: NSDraggingInfo) -> UUID? {
        guard let str = s.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: str),
              store.assets.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}
