import AppKit
import SwiftUI
import OnTheFrameEngine

/// Inspector policy only. Stored milli precision and renderer/model ranges are unchanged.
enum SpectrumNumericProperty: String, CaseIterable {
    case startX, startY, endX, endY, height, thickness, reaction, lowHz, highHz, bands, windowMs, offsetMs
    case hueInterpolationDegrees
    var title: String {
        switch self {
        case .startX: "시작 X"
        case .startY: "시작 Y"
        case .endX: "끝 X"
        case .endY: "끝 Y"
        case .height: "최대 높이"
        case .thickness: "두께"
        case .reaction: "반응 강도 (%)"
        case .lowHz: "시작 주파수 (Hz)"
        case .highHz: "끝 주파수 (Hz)"
        case .bands: "주파수 밴드 수"
        case .windowMs: "분석 창 길이 (ms)"
        case .offsetMs: "오디오 오프셋 (ms)"
        case .hueInterpolationDegrees: "색조 보간 (°)"
        }
    }
    var range: ClosedRange<Int> {
        switch self {
        case .startX, .startY, .endX, .endY: -10_000...10_000
        case .height: 0...1080
        case .thickness: 1...64
        case .reaction: 0...200
        case .lowHz: 1...23_999
        case .highHz: 2...24_000
        case .bands: 1...1024
        case .windowMs: 1...1000
        case .offsetMs: -10_000...10_000
        case .hueInterpolationDegrees: 0...360
        }
    }
    /// Frequency bounds depend on the other current value; never adjust that value.
    func effectiveRange(in style: SpectrumItemStyle) -> ClosedRange<Int>? {
        switch self {
        case .lowHz:
            guard (2...24_000).contains(style.highHz) else { return nil }
            return 1...(style.highHz - 1)
        case .highHz:
            guard (1...23_999).contains(style.lowHz) else { return nil }
            return (style.lowHz + 1)...24_000
        default: return range
        }
    }
    var pointsPerStep: CGFloat {
        switch self {
        case .thickness: 6
        case .reaction, .windowMs: 2
        case .bands: 4
        default: 1
        }
    }
    func displayed(_ style: SpectrumItemStyle) -> Int {
        let raw: Int
        switch self {
        case .startX: raw = style.startXMilli
        case .startY: raw = style.startYMilli
        case .endX: raw = style.endXMilli
        case .endY: raw = style.endYMilli
        case .height: raw = style.maxHeightMilli
        case .thickness: raw = style.thicknessMilli
        case .reaction: return style.reactionPercent
        case .lowHz: return style.lowHz
        case .highHz: return style.highHz
        case .bands: return style.bands
        case .windowMs: return style.windowMs
        case .offsetMs: return style.offsetMs
        case .hueInterpolationDegrees: return style.hueInterpolationDegrees
        }
        return SpectrumStyleDraft.wholePixels(raw)
    }
    func applying(_ value: Int, to original: SpectrumItemStyle) -> SpectrumItemStyle? {
        guard let bounds = effectiveRange(in: original), bounds.contains(value) else { return nil }
        // Returning to the original displayed integer restores the exact original.
        if value == displayed(original) { return original.isValid ? original : nil }
        var result = original
        switch self {
        case .startX: result.startXMilli = value * 1000
        case .startY: result.startYMilli = value * 1000
        case .endX: result.endXMilli = value * 1000
        case .endY: result.endYMilli = value * 1000
        case .height: result.maxHeightMilli = value * 1000
        case .thickness: result.thicknessMilli = value * 1000
        case .reaction: result.reactionPercent = value
        case .lowHz: result.lowHz = value
        case .highHz: result.highHz = value
        case .bands: result.bands = value
        case .windowMs: result.windowMs = value
        case .offsetMs: result.offsetMs = value
        case .hueInterpolationDegrees: result.hueInterpolationDegrees = value
        }
        return result.isValid ? result : nil
    }
    func candidate(start: Int, displacement: CGFloat) -> Int? {
        guard range.contains(start), displacement.isFinite else { return nil }
        let distance = max(0, abs(displacement) - SpectrumNumericControl.threshold)
        let sign: CGFloat = displacement < 0 ? -1 : 1
        // Bound before converting to Int, including hostile synthetic event coordinates.
        let steps = min(CGFloat(range.upperBound - range.lowerBound), distance / pointsPerStep)
        return min(range.upperBound, max(range.lowerBound, start + Int(sign * steps)))
    }
}

enum SpectrumNumericScrubUpdate { case accepted, rejected, obsolete }

/// The existing numeric value is both the native text field and the drag target.
struct SpectrumNumericField: NSViewRepresentable {
    let property: SpectrumNumericProperty
    @Binding var text: String
    @Binding var focus: String?
    let store: ProjectStore
    let commit: () -> Void
    let begin: (UUID) -> Bool
    let update: (UUID, Int) -> SpectrumNumericScrubUpdate
    let finish: (UUID) -> Void
    let cancel: (UUID) -> Void
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> SpectrumNumericControl { SpectrumNumericControl() }
    func updateNSView(_ view: SpectrumNumericControl, context: Context) {
        view.configure(property: property, text: text, focused: focus == property.rawValue,
            enabled: enabled, store: store, changeText: { text = $0 },
            focusChanged: { active in
                if active { focus = property.rawValue }
                else if focus == property.rawValue { focus = nil }
            }, commit: commit, begin: begin, update: update, finish: finish, cancel: cancel)
    }
    static func dismantleNSView(_ view: SpectrumNumericControl, coordinator: ()) { view.detach() }
}

@MainActor
final class SpectrumNumericControl: NSView, NSTextFieldDelegate {
    nonisolated static let threshold: CGFloat = 4
    enum Tracking { case idle, pressed, dragging, cancelled }
    let field = NSTextField()
    private(set) var tracking = Tracking.idle
    private(set) var property = SpectrumNumericProperty.startX
    private var token: UUID?
    private var origin = NSPoint.zero
    private var startValue = 0
    private var lastCandidate: Int?
    private var pressContext: (Int, UUID?, Int, Int)?
    private var editing = false
    private var detaching = false
    private weak var store: ProjectStore?
    private var observations: [SpectrumWindowObservation] = []
    private var changeText: (String) -> Void = { _ in }
    private var focusChanged: (Bool) -> Void = { _ in }
    private var commit: () -> Void = {}
    private var begin: (UUID) -> Bool = { _ in false }
    private var update: (UUID, Int) -> SpectrumNumericScrubUpdate = { _, _ in .obsolete }
    private var finish: (UUID) -> Void = { _ in }
    private var cancel: (UUID) -> Void = { _ in }
    private var enabled = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isEditable = true; field.isSelectable = true; field.isBezeled = true
        field.bezelStyle = .roundedBezel; field.controlSize = .small
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right; field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor), field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor), field.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 72, height: field.intrinsicContentSize.height) }
    override var acceptsFirstResponder: Bool { enabled }
    override var canBecomeKeyView: Bool { false } // Only the native field participates in Tab order.
    override func resignFirstResponder() -> Bool { cancelTracking(); return true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return !editing && hit != nil ? self : hit
    }

    func configure(property: SpectrumNumericProperty, text: String, focused: Bool, enabled: Bool,
                   store: ProjectStore, changeText: @escaping (String) -> Void,
                   focusChanged: @escaping (Bool) -> Void, commit: @escaping () -> Void,
                   begin: @escaping (UUID) -> Bool, update: @escaping (UUID, Int) -> SpectrumNumericScrubUpdate,
                   finish: @escaping (UUID) -> Void, cancel: @escaping (UUID) -> Void) {
        if self.store !== store { observations.removeAll() }
        self.property = property; self.enabled = enabled; self.store = store
        self.changeText = changeText; self.focusChanged = focusChanged; self.commit = commit
        self.begin = begin; self.update = update; self.finish = finish; self.cancel = cancel
        field.isEnabled = enabled
        field.setAccessibilityLabel("스펙트럼 " + property.title)
        field.setAccessibilityIdentifier("spectrum.numeric." + property.rawValue)
        field.setAccessibilityHelp("좌우로 끌어 정수 조정. 클릭하여 입력. 끌기 중 Escape로 취소.")
        if tracking == .pressed, !pressIsCurrent { cancelTracking() }
        if let token, tracking == .dragging, store.spectrumNumericScrubToken != token { cancelTracking() }
        if !enabled { cancelTracking() }
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText() { editor.string = text }
        }
        if editing && !focused { window?.makeFirstResponder(nil) }
        if observations.isEmpty, window != nil { observeInterruptions() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observations.removeAll()
        if window == nil { cancelTracking() } else { observeInterruptions() }
    }
    private func observeInterruptions() {
        guard observations.isEmpty, let window else { return }
        let center = NotificationCenter.default
        for (name, object) in [(NSApplication.didResignActiveNotification, nil as AnyObject?),
                               (NSWindow.didResignKeyNotification, window as AnyObject?),
                               (ProjectStore.gestureInterruptedNotification, store as AnyObject?)] {
            observations.append(SpectrumWindowObservation(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelTracking() }
            }))
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled, !editing, event.type == .leftMouseDown else { return }
        cancelTracking()
        window?.makeFirstResponder(self)
        origin = event.locationInWindow; token = UUID(); lastCandidate = nil; tracking = .pressed
        if let store { pressContext = (store.projectSession, store.selection, store.spectrumSelectionRevision, store.generation) }
    }
    private var pressIsCurrent: Bool {
        guard let store, let context = pressContext else { return false }
        return context.0 == store.projectSession && context.1 == store.selection &&
            context.2 == store.spectrumSelectionRevision && context.3 == store.generation
    }
    override func mouseDragged(with event: NSEvent) {
        guard let token, tracking == .pressed || tracking == .dragging else { return }
        let dx = event.locationInWindow.x - origin.x, dy = event.locationInWindow.y - origin.y
        guard dx.isFinite, dy.isFinite else { cancelTracking(); return }
        if tracking == .pressed {
            guard pressIsCurrent else { cancelTracking(); return }
            if abs(dy) > Self.threshold && abs(dy) > abs(dx) { cancelTracking(); return }
            guard abs(dx) > Self.threshold else { return }
            guard let current = store?.selectedSpectrum else { cancelTracking(); return }
            startValue = property.displayed(current.style)
            tracking = .dragging
            guard begin(token), tracking == .dragging else { cancel(token); cancelTracking(); return }
        }
        guard let value = property.candidate(start: startValue, displacement: dx), value != lastCandidate else { return }
        lastCandidate = value
        if update(token, value) == .obsolete { cancelTracking() }
    }
    override func mouseUp(with event: NSEvent) {
        let old = tracking, owner = token
        tracking = .idle; token = nil; lastCandidate = nil
        if old == .dragging, let owner { finish(owner) }
        else if old == .pressed, enabled, bounds.contains(convert(event.locationInWindow, from: nil)) { enterTextEditing() }
    }
    func cancelTracking() {
        guard tracking == .pressed || tracking == .dragging else { return }
        let owner = token
        tracking = .cancelled; token = nil; lastCandidate = nil
        if let owner { cancel(owner) }
    }
    override func cancelOperation(_ sender: Any?) {
        if tracking == .pressed || tracking == .dragging { cancelTracking() }
        else { super.cancelOperation(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        if event.keyCode == 48 {
            cancelTracking()
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(field) }
            else { window?.selectNextKeyView(field) }
            return
        }
        if tracking == .idle, event.keyCode == 36 || event.keyCode == 76 { enterTextEditing(); return }
        super.keyDown(with: event)
    }
    private func enterTextEditing() {
        guard enabled, !detaching else { return }
        editing = true; focusChanged(true)
        field.selectText(nil)
    }
    func controlTextDidBeginEditing(_ notification: Notification) { editing = true; focusChanged(true) }
    func controlTextDidChange(_ notification: Notification) { changeText(field.stringValue) }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard !detaching else { return }
        changeText(field.stringValue); commit(); editing = false; focusChanged(false)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            changeText(field.stringValue); commit(); return true
        }
        return false // Tab/Shift-Tab, text selection, clipboard and text Undo belong to AppKit.
    }
    func detach() {
        cancelTracking(); detaching = true; observations.removeAll()
        _ = field.abortEditing(); field.delegate = nil
    }
}
