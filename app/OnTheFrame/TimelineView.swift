import AppKit
import OnTheFrameEngine
import SwiftUI

/// 아래 영역: 상태 줄·확대 조절 + AppKit 타임라인(눈금자, 영상 트랙 1개, 재생 헤드).
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
    var playhead: Int
    var insertion: Int?
    @MainActor init(store: ProjectStore) {
        timeline = store.timeline
        names = Dictionary(uniqueKeysWithValues: store.assets.map { ($0.id, $0.name) })
        selection = store.selection
        playhead = store.playhead
        insertion = store.moveInsertionIndex
    }
}

struct TimelineRepresentable: NSViewRepresentable {
    let store: ProjectStore
    let state: TimelineDrawState
    let pixelsPerFrame: Double

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = false
        sv.drawsBackground = true
        sv.backgroundColor = .underPageBackgroundColor
        let v = TimelineNSView(store: store)
        sv.documentView = v
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let v = sv.documentView as? TimelineNSView else { return }
        v.state = state
        v.pixelsPerFrame = CGFloat(pixelsPerFrame)
        let w = max(sv.contentSize.width, TimelineNSView.inset * 2 + CGFloat(state.timeline.durationFrames) * v.pixelsPerFrame + 200)
        v.setFrameSize(NSSize(width: w, height: max(sv.contentSize.height, TimelineNSView.trackY + TimelineNSView.trackHeight + 12)))
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
    }
}

final class TimelineNSView: NSView {
    static let inset: CGFloat = 12, rulerHeight: CGFloat = 24, trackY: CGFloat = 34, trackHeight: CGFloat = 64, edgeGrab: CGFloat = 6
    let store: ProjectStore
    var state: TimelineDrawState?
    var pixelsPerFrame: CGFloat = 2

    private enum Drag { case none, scrub, pending(UUID, NSPoint), move(UUID), trim(UUID, ProjectStore.TrimEdge, CGFloat) }
    private var drag: Drag = .none

    init(store: ProjectStore) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func x(_ frame: Int) -> CGFloat { Self.inset + CGFloat(frame) * pixelsPerFrame }
    private func frame(atX px: CGFloat) -> Int { Int(((px - Self.inset) / pixelsPerFrame).rounded()) }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        guard let st = state else { return }
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        drawRuler(st)
        // 빈틈(D-020): 영상 검정·소리 없음 구간. 어두운 빗금으로 클립과 구별해 보인다.
        for g in st.timeline.gaps {
            let r = NSRect(x: x(g.lowerBound), y: Self.trackY, width: CGFloat(g.count) * pixelsPerFrame, height: Self.trackHeight)
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
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
                NSString(string: "빈틈").draw(at: NSPoint(x: r.minX + 6, y: r.minY + 6), withAttributes: attrs)
            }
        }
        // 타임라인 끝(길이)
        if st.timeline.durationFrames > 0 {
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: x(st.timeline.durationFrames) - 0.5, y: Self.trackY - 6, width: 1, height: Self.trackHeight + 12).fill()
        }
        let starts = st.timeline.starts
        for (i, c) in st.timeline.clips.enumerated() {
            let r = NSRect(x: x(starts[i]), y: Self.trackY, width: max(1, CGFloat(c.length) * pixelsPerFrame), height: Self.trackHeight)
            let selected = c.id == st.selection
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.55) : NSColor.systemTeal.withAlphaComponent(0.35)).setFill()
            path.fill()
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = selected ? 2 : 1
            path.stroke()
            if r.width > 24 {
                let name = st.names[c.mediaID] ?? ""
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
                NSString(string: name).draw(with: NSRect(x: r.minX + 6, y: r.minY + 6, width: r.width - 12, height: 16),
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            }
            if selected {   // 트림 손잡이
                NSColor.controlAccentColor.setFill()
                NSRect(x: r.minX, y: r.minY + 8, width: 3, height: r.height - 16).fill()
                NSRect(x: r.maxX - 3, y: r.minY + 8, width: 3, height: r.height - 16).fill()
            }
        }
        if let ins = st.insertion, case .move = drag, let base = store.gestureBase {
            let bx = x(ins < base.clips.count ? base.starts[ins] : base.durationFrames)
            NSColor.systemYellow.setFill()
            NSRect(x: bx - 1.5, y: Self.trackY - 4, width: 3, height: Self.trackHeight + 8).fill()
        }
        let ph = x(min(st.playhead, st.timeline.durationFrames))
        NSColor.systemRed.setFill()
        NSRect(x: ph - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: ph - 5, y: 0)); tri.line(to: NSPoint(x: ph + 5, y: 0)); tri.line(to: NSPoint(x: ph, y: 7)); tri.close()
        tri.fill()
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

    private func clipHit(_ p: NSPoint) -> (UUID, ProjectStore.TrimEdge?)? {
        guard let st = state, p.y >= Self.trackY, p.y <= Self.trackY + Self.trackHeight else { return nil }
        let starts = st.timeline.starts
        for (i, c) in st.timeline.clips.enumerated() {
            let x0 = x(starts[i]), x1 = x(starts[i] + c.length)
            guard p.x >= x0 - 1, p.x <= x1 + 1 else { continue }
            let grab = min(Self.edgeGrab, (x1 - x0) / 3)
            if p.x <= x0 + grab { return (c.id, .start) }
            if p.x >= x1 - grab { return (c.id, .end) }
            return (c.id, nil)
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if p.y < Self.trackY {
            store.pauseForEdit(); drag = .scrub; store.seek(to: frame(atX: p.x)); return
        }
        if let (id, edge) = clipHit(p) {
            if let edge {
                store.beginGesture(select: id)
                drag = .trim(id, edge, p.x)
            } else {
                store.pauseForEdit()
                store.selection = id
                drag = .pending(id, p)
            }
        } else {
            store.selection = nil; drag = .none
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
            drag = .move(id)
            store.updateMove(id, toIndex: insertionIndex(p.x))
        case .move(let id):
            store.updateMove(id, toIndex: insertionIndex(p.x))
        case .trim(let id, let edge, let x0):
            let d = Int(((p.x - x0) / pixelsPerFrame).rounded())
            store.updateTrim(id, edge: edge, delta: d)
        case .none:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        switch drag {
        case .move, .trim: store.commitGesture()
        default: break
        }
        drag = .none
    }

    /// 드래그 중 Esc: 드래그 전 상태로 되돌린다(기록 없음).
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { cancelOperation(nil); return }
        // 보조 처리 층: 로컬 감시를 지나지 않고 전달된 편집기 단축키(KeyRouting 설명 참조)
        if KeyRouting.route(e, layer: "timelineKeyDown", store: store) { return }
        super.keyDown(with: e)
    }
    override func cancelOperation(_ sender: Any?) {
        switch drag {
        case .move, .trim: store.cancelGesture(); drag = .none
        default: break
        }
    }

    /// 드래그 시작 시점 타임라인에서 끼워 넣을 자리(클립 가운데를 기준으로)
    private func insertionIndex(_ px: CGFloat) -> Int {
        guard let base = store.gestureBase ?? state?.timeline else { return 0 }
        let f = CGFloat(frame(atX: px))
        let starts = base.starts
        return base.clips.indices.filter { CGFloat(starts[$0]) + CGFloat(base.clips[$0].length) / 2 < f }.count
    }

    override func resetCursorRects() {
        guard let st = state, let sel = st.selection, let i = st.timeline.index(of: sel) else { return }
        let s = st.timeline.starts[i], c = st.timeline.clips[i]
        addCursorRect(NSRect(x: x(s) - 2, y: Self.trackY, width: Self.edgeGrab + 2, height: Self.trackHeight), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: x(s + c.length) - Self.edgeGrab, y: Self.trackY, width: Self.edgeGrab + 2, height: Self.trackHeight), cursor: .resizeLeftRight)
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
