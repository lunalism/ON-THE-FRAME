import AppKit
import SwiftUI

/// 음량 슬라이더(2026-10-11, 0–100 정수). 끌기 한 번 = 놓을 때 한 번 onCommit(한 단계), 끌기 중 Esc는 시작 값으로 되돌리고 기록하지 않는다.
/// SwiftUI Slider는 끌기를 자체 추적 고리로 처리해 끌기 중 키(Esc)를 받지 못하므로 AppKit 보기로 만든다.
/// 끌기 중 값은 onLive로만 알린다(편집 기록·프리뷰는 놓을 때 바뀐다). 손쉬운 사용 증가·감소는 1씩 한 단계다.
struct GainSlider: NSViewRepresentable {
    let value: Int
    let axLabel: String
    var onLive: (Int?) -> Void = { _ in }
    let onCommit: (Int) -> Void
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> GainSliderView { GainSliderView() }
    func updateNSView(_ v: GainSliderView, context: Context) {
        v.onLive = onLive; v.onCommit = onCommit
        v.isEnabled = enabled
        v.setAccessibilityLabel(axLabel)
        if !v.isDragging, v.value != value { v.value = value; v.needsDisplay = true }
    }
}

final class GainSliderView: NSView {
    var value = 100
    var isEnabled = true { didSet { if oldValue != isEnabled { needsDisplay = true } } }
    var onLive: (Int?) -> Void = { _ in }
    var onCommit: (Int) -> Void = { _ in }
    /// 끌기 시작 값(끌기 중이 아니면 nil). Esc로 취소하면 놓을 때까지 cancelled.
    private var start: Int?
    private var cancelled = false
    var isDragging: Bool { start != nil || cancelled }
    private let knob: CGFloat = 12

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }
    private var trackRect: NSRect { NSRect(x: knob / 2, y: bounds.midY - 2, width: max(1, bounds.width - knob), height: 4) }
    func value(atX x: CGFloat) -> Int { Int((max(0, min(1, (x - trackRect.minX) / trackRect.width)) * 100).rounded()) }

    override func draw(_ dirtyRect: NSRect) {
        let t = trackRect, a: CGFloat = isEnabled ? 1 : 0.4
        NSColor.tertiaryLabelColor.withAlphaComponent(0.5 * a).setFill()
        NSBezierPath(roundedRect: t, xRadius: 2, yRadius: 2).fill()
        let fx = t.minX + t.width * CGFloat(value) / 100
        NSColor.controlAccentColor.withAlphaComponent(a).setFill()
        NSBezierPath(roundedRect: NSRect(x: t.minX, y: t.minY, width: fx - t.minX, height: t.height), xRadius: 2, yRadius: 2).fill()
        let k = NSRect(x: fx - knob / 2, y: bounds.midY - knob / 2, width: knob, height: knob)
        NSColor.white.withAlphaComponent(a).setFill()
        let kp = NSBezierPath(ovalIn: k.insetBy(dx: 0.5, dy: 0.5)); kp.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(a).setStroke(); kp.lineWidth = 0.5; kp.stroke()
        if window?.firstResponder === self, isEnabled {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let f = NSBezierPath(ovalIn: k.insetBy(dx: -1.5, dy: -1.5)); f.lineWidth = 2; f.stroke()
        }
    }

    override func mouseDown(with e: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        start = value; cancelled = false
        set(value(atX: convert(e.locationInWindow, from: nil).x))
    }
    override func mouseDragged(with e: NSEvent) {
        guard start != nil, !cancelled else { return }
        set(value(atX: convert(e.locationInWindow, from: nil).x))
    }
    override func mouseUp(with e: NSEvent) {
        defer { start = nil; cancelled = false; onLive(nil) }
        guard let s = start, !cancelled else { return }
        if value != s { onCommit(value) }
    }
    private func set(_ v: Int) { guard v != value else { return }; value = v; needsDisplay = true; onLive(v) }
    /// 끌기 중 Esc: 시작 값으로(기록 없음). 끌기 중이 아니면 위로 넘긴다.
    override func cancelOperation(_ sender: Any?) {
        guard let s = start, !cancelled else { super.cancelOperation(sender); return }
        cancelled = true; start = nil
        value = s; needsDisplay = true; onLive(nil)
    }
    /// ←/→·Space 등 편집기 단축키는 그대로 편집기가 받는다(KeyRouting). 여기서는 Esc만 본다.
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { cancelOperation(nil); return }
        super.keyDown(with: e)
    }
    private func nudge(_ d: Int) {
        let v = max(0, min(100, value + d))
        guard v != value else { return }
        value = v; needsDisplay = true; onCommit(v)
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    // 손쉬운 사용: 슬라이더(값 0–100, 증가·감소 = 1씩 한 단계)
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 100) }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformIncrement() -> Bool { nudge(1); return true }
    override func accessibilityPerformDecrement() -> Bool { nudge(-1); return true }
}
