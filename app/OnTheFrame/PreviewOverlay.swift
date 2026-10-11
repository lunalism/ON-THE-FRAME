import AppKit
import OnTheFrameEngine
import SwiftUI

/// 프리뷰 위 편집 테두리(A-015). 선택한 영상 클립이 재생 헤드 위치에 있으면 그 영상의 화면 사각형에 테두리와 네 모서리 손잡이를 그린다.
/// 이 보기는 프리뷰 화면 위의 AppKit 보기일 뿐 composition에 들어가지 않으므로 내보내기에는 나오지 않는다.
/// - 좌표: 출력 화면(1920×1080, 왼쪽 위 원점, 아래 +Y)을 프리뷰 영역에 비율 유지로 맞춘 사각형(검은 여백 제외)으로 옮긴다.
///   보기 좌표 p → 출력 좌표 (p − 영역 원점) / 배율. 프리뷰 크기가 바뀌어도 같은 식이다(AVPlayerLayer의 resizeAspect와 같은 맞춤).
/// - 안쪽 끌기: 위치 이동. 모서리 끌기: 반대 모서리를 고정하고 비율을 유지해 크기 조절. 끌기 한 번이 한 단계, Esc는 끌기 전으로.
struct PreviewOverlay: NSViewRepresentable {
    let store: ProjectStore
    let state: State
    struct State: Equatable { var clipID: UUID?; var transform: ClipTransform?; var rect: CGRect? }
    @MainActor static func state(_ s: ProjectStore) -> State {
        guard let (c, a) = s.overlayTarget else { return State(clipID: nil, transform: nil, rect: nil) }
        return State(clipID: c.id, transform: c.transform, rect: CompositionPlanner.displayRect(a, c.effectiveTransform, render: s.settings.renderSize))
    }
    func makeNSView(context: Context) -> PreviewOverlayView { PreviewOverlayView(store: store) }
    func updateNSView(_ v: PreviewOverlayView, context: Context) { v.state = state; v.needsDisplay = true }
}

final class PreviewOverlayView: NSView {
    let store: ProjectStore
    /// 저장소 상태의 테두리(SwiftUI가 넣음). 끌기를 놓은 뒤에는 이 값이 놓은 값으로 바뀔 때까지 끌기 테두리를 그대로 그린다(한 화면이라도 이전 테두리가 보이지 않게).
    var state = PreviewOverlay.State(clipID: nil, transform: nil, rect: nil) { didSet { if case .none = drag { liveRect = nil } } }
    static let handle: CGFloat = 9
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    private enum Drag { case none, move(UUID, ClipTransform, NSPoint), resize(UUID, ClipTransform, Corner, CGRect) }
    private var drag: Drag = .none

    init(store: ProjectStore) {
        self.store = store; super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(gestureInterrupted), name: ProjectStore.gestureInterruptedNotification, object: nil)
    }
    /// 끌기 중단(D-031): 저장소가 끌기를 취소했으면 이 보기의 끌기 상태(대기 값·화면 갱신·테두리)도 지운다
    @objc private func gestureInterrupted() {
        if case .none = drag { return }
        #if DEBUG
        store.traceGestureDebug("preview viewDragCleared")
        #endif
        drag = .none; pending = nil; liveRect = nil; dragAsset = nil
        link?.isPaused = true
        needsDisplay = true
    }
    #if DEBUG
    /// 자체 검사 전용: 끌기 중인가
    var isDraggingForTest: Bool { if case .none = drag { return false }; return true }
    #endif
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var render: CGSize { store.settings.renderSize }
    /// 출력 화면이 보이는 영역(보기 좌표)과 배율
    var videoArea: (rect: CGRect, k: CGFloat) {
        let k = min(bounds.width / render.width, bounds.height / render.height)
        let w = render.width * k, h = render.height * k
        return (CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h), k)
    }
    func toView(_ r: CGRect) -> CGRect {
        let (a, k) = videoArea
        return CGRect(x: a.minX + r.minX * k, y: a.minY + r.minY * k, width: r.width * k, height: r.height * k)
    }
    func toCanvas(_ p: NSPoint) -> CGPoint {
        let (a, k) = videoArea
        return CGPoint(x: (p.x - a.minX) / k, y: (p.y - a.minY) / k)
    }
    func cornerPoint(_ r: CGRect, _ c: Corner) -> CGPoint {
        switch c {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }
    func opposite(_ c: Corner) -> Corner {
        switch c { case .topLeft: return .bottomRight; case .topRight: return .bottomLeft; case .bottomLeft: return .topRight; case .bottomRight: return .topLeft }
    }
    /// 보기 좌표의 손잡이 사각형
    func handleRect(_ c: Corner) -> CGRect? {
        guard let r = currentRect.map(toView) else { return nil }
        let p = cornerPoint(r, c), h = Self.handle
        return CGRect(x: p.x - h / 2, y: p.y - h / 2, width: h, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cr = currentRect else { return }
        let r = toView(cr)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.6).setStroke(); let shadow = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5)); shadow.lineWidth = 1; shadow.stroke()
        NSColor.controlAccentColor.setStroke(); path.stroke()
        for c in Corner.allCases {
            guard let h = handleRect(c) else { continue }
            NSColor.white.setFill(); NSBezierPath(rect: h).fill()
            NSColor.controlAccentColor.setStroke(); let hp = NSBezierPath(rect: h); hp.lineWidth = 1.5; hp.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 테두리 안·손잡이 위만 마우스를 받고, 그 밖은 아래(프리뷰)로 넘긴다
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview, let r = currentRect.map(toView) else { return nil }
        let p = convert(point, from: sv)
        if Corner.allCases.contains(where: { handleRect($0)?.insetBy(dx: -3, dy: -3).contains(p) == true }) || r.contains(p) { return self }
        return nil
    }
    override func resetCursorRects() {
        guard let r = state.rect.map(toView) else { return }
        addCursorRect(r.intersection(bounds), cursor: .openHand)
        for c in Corner.allCases { if let h = handleRect(c) { addCursorRect(h.insetBy(dx: -3, dy: -3), cursor: .crosshair) } }
    }

    // 끌기(2026-10-11 부드러움 개선): 포인터 값은 소수(보기 pt → 출력 픽셀)로 계산하고 저장 격자(0.0001%, 0.001 px, ClipTransform)로만 맞춘다.
    // 포인터 이벤트마다 최신 값만 남기고(pending), 화면 갱신(CADisplayLink)마다 한 번 무대·테두리에 넣는다. 놓을 때는 놓은 위치의 값을 바로 넣고 끝낸다.
    private var link: CADisplayLink?
    private var pending: (id: UUID, transform: ClipTransform)?
    private var dragAsset: MediaAsset?
    /// 끌기 중 테두리(무대에 넣은 값의 화면 사각형). 끌기가 아니면 nil(저장소 상태의 사각형을 그림).
    private var liveRect: CGRect?
    var currentRect: CGRect? { liveRect ?? state.rect }

    override func mouseDown(with e: NSEvent) {
        #if DEBUG
        defer { store.traceGestureDebug("preview mouseDown dragging=\(isDraggingForTest)", event: e) }
        #endif
        if store.gestureBase != nil { store.interruptGesture() }   // 놓기를 받지 못한 끌기가 남아 있으면 취소(D-031)
        guard let id = state.clipID, let cr = state.rect, store.gestureBase == nil else { return }
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        let t0 = state.transform ?? .identity
        if let c = Corner.allCases.first(where: { handleRect($0)?.insetBy(dx: -3, dy: -3).contains(p) == true }) {
            drag = .resize(id, t0, c, cr)
        } else {
            drag = .move(id, t0, p)
        }
        dragAsset = store.overlayTarget?.asset
        store.beginTransformGesture()
    }
    /// 포인터 위치의 변형(끌기 시작 값 기준, 누적 오차 없음)
    private func value(at p: NSPoint) -> (UUID, ClipTransform)? {
        switch drag {
        case .none: return nil
        case .move(let id, let t0, let p0):
            let k = videoArea.k
            return (id, ClipTransform(scale: t0.scale, x: t0.x + Double((p.x - p0.x) / k), y: t0.y + Double((p.y - p0.y) / k)))
        case .resize(let id, let t0, let c, let r0):
            return (id, Self.resized(t0, corner: c, rect0: r0, mouse: toCanvas(p), render: render, opposite: opposite(c), cornerPoint: cornerPoint))
        }
    }
    override func mouseDragged(with e: NSEvent) {
        #if DEBUG
        let probeStart = PerfProbe.now()
        #endif
        guard let v = value(at: convert(e.locationInWindow, from: nil)) else { return }
        pending = v
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
        #if DEBUG
        PerfProbe.shared.dragged(start: probeStart, value: .init(scale: v.1.scale, x: v.1.x, y: v.1.y))
        #endif
    }
    @objc private func tick(_ l: CADisplayLink) {
        #if DEBUG
        ticks += 1
        #endif
        if pending == nil { l.isPaused = true } else { flush() }
    }
    #if DEBUG
    /// 자체 검사 전용: 화면 갱신 호출 수, 끌기 시작 뒤 마지막 flush 경로
    var ticks = 0
    var linkDescription: String { link.map { "paused \($0.isPaused) fps \($0.preferredFrameRateRange)" } ?? "nil" }
    #endif
    /// 남은 최신 값을 무대·테두리에 넣는다
    private func flush() {
        guard let (id, t) = pending else { return }
        pending = nil
        store.updateTransformGesture(id, t)
        liveRect = dragAsset.map { CompositionPlanner.displayRect($0, t.clamped, render: render) }
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { link?.invalidate(); link = nil }
    }
    /// 모서리 크기 조절: 반대 모서리 A 고정, 비율 유지. 100% 크기(W, H)에서 s = max(|M.x − A.x|/W, |M.y − A.y|/H),
    /// 새 가운데 = A + 방향 × (W·s/2, H·s/2), 위치 = 가운데 − 화면 가운데. s는 저장 격자로 맞춘 뒤 가운데를 계산해, 반대 모서리가 0.001 px 안에서 고정된다.
    static func resized(_ t0: ClipTransform, corner c: Corner, rect0 r0: CGRect, mouse m: CGPoint, render: CGSize, opposite: Corner,
                        cornerPoint: (CGRect, Corner) -> CGPoint) -> ClipTransform {
        let a = cornerPoint(r0, opposite), d = cornerPoint(r0, c)
        let w100 = r0.width / t0.scale, h100 = r0.height / t0.scale
        let sx = (d.x >= a.x ? 1.0 : -1.0), sy = (d.y >= a.y ? 1.0 : -1.0)
        var s = max(max(0, (m.x - a.x) * sx) / w100, max(0, (m.y - a.y) * sy) / h100)
        s = min(max(s, Double(ClipTransform.scaleMicroRange.lowerBound) / 1_000_000), Double(ClipTransform.scaleMicroRange.upperBound) / 1_000_000)
        let sq = ClipTransform(scale: s, x: 0, y: 0).scale
        let ws = w100 * sq, hs = h100 * sq
        let cx = a.x + sx * ws / 2, cy = a.y + sy * hs / 2
        return ClipTransform(scale: sq, x: cx - render.width / 2, y: cy - render.height / 2)
    }
    override func mouseUp(with e: NSEvent) {
        #if DEBUG
        store.traceGestureDebug("preview mouseUp dragging=\(isDraggingForTest)", event: e)
        #endif
        if case .none = drag { return }
        if let v = value(at: convert(e.locationInWindow, from: nil)) { pending = v }   // 놓은 위치의 값(마지막 끌기 이벤트 뒤에 움직였어도)
        flush()
        drag = .none; dragAsset = nil
        link?.isPaused = true
        store.commitGesture()
        if store.timeline.clip(state.clipID ?? UUID())?.effectiveTransform == state.transform ?? .identity { liveRect = nil }   // 바뀐 것이 없음
        needsDisplay = true
    }
    /// 끌기 중 Esc: 끌기 전으로(기록 없음)
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { cancelOperation(nil); return }
        super.keyDown(with: e)
    }
    override func cancelOperation(_ sender: Any?) {
        if case .none = drag { return }
        drag = .none; pending = nil; liveRect = nil; dragAsset = nil
        link?.isPaused = true
        store.cancelGesture()
        needsDisplay = true
    }
}
