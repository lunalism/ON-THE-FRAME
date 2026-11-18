import AppKit
import SwiftUI
import OnTheFrameEngine

enum SpectrumColorTarget: String { case inside, outside }

/// One bounded, target-bound color interaction. The Timeline remains authoritative.
@MainActor final class SpectrumColorEditing {
    struct State {
        let token: UUID, target: SpectrumColorTarget, id: UUID, project: UUID
        let session: Int, revision: Int, eventRevision: Int, base: Timeline
        var generation: Int, last: Timeline
    }
    private(set) var state: State?
    var token: UUID? { state?.token }
    func retire() { state = nil }
    func begin(_ store: ProjectStore, token: UUID, target: SpectrumColorTarget, id: UUID) {
        state = State(token: token, target: target, id: id, project: store.projectID,
            session: store.projectSession, revision: store.spectrumSelectionRevision,
            eventRevision: store.spectrumColorEventRevision, base: store.timeline,
            generation: store.generation, last: store.timeline)
        store.spectrumLiveSession = ProjectStore.SpectrumLiveSession(id: id, project: store.projectSession,
            revision: store.spectrumSelectionRevision, kind: "native-color", base: store.timeline, colorToken: token)
    }
    func isCurrent(_ store: ProjectStore, token: UUID) -> Bool {
        guard let s = state else { return false }
        return s.token == token && store.spectrumLiveSession?.colorToken == token &&
            s.project == store.projectID && s.session == store.projectSession &&
            s.revision == store.spectrumSelectionRevision && store.selection == s.id &&
            s.generation == store.generation && s.last == store.timeline
    }
    func update(_ store: ProjectStore, token: UUID, target: SpectrumColorTarget, rgb: SpectrumItemStyle.RGB) -> Bool {
        guard let s = state, s.target == target, rgb.isValid, isCurrent(store, token: token),
              s.eventRevision == store.spectrumColorEventRevision,
              let item = store.timeline.spectrum(s.id) else { return false }
        var next = item.style
        if target == .inside {
            guard rgb != next.insideRGB else { return true }
            // Freeze the old inherited Outside only when Inside really changes.
            if next.outsideRGB == nil { next.outsideRGB = next.resolvedOutsideRGB }
            next.red = rgb.red; next.green = rgb.green; next.blue = rgb.blue
        } else {
            guard rgb != next.resolvedOutsideRGB else { return true }
            next.outsideRGB = rgb
        }
        guard store.updateSpectrumLiveStyle(s.id, style: next, project: s.session,
            revision: s.revision, expectedGeneration: s.generation, kind: "native-color") else { return false }
        state?.generation = store.generation; state?.last = store.timeline
        return true
    }
}

extension ProjectStore {
    var spectrumColorEditToken: UUID? { spectrumColorEditing.token }
    @discardableResult
    func updateSpectrumColorEdit(_ token: UUID, target: SpectrumColorTarget, rgb: SpectrumItemStyle.RGB) -> Bool {
        spectrumColorEditing.update(self, token: token, target: target, rgb: rgb)
    }
    func finishSpectrumColorEdit(_ token: UUID) {
        guard spectrumColorEditing.token == token, spectrumLiveSession?.colorToken == token else { return }
        finishSpectrumLiveSession()
    }
}

/// Native activation is the ownership boundary; a color action never acquires a session.
struct SpectrumColorWell: NSViewRepresentable {
    let store: ProjectStore, id: UUID, target: SpectrumColorTarget
    let project: Int, revision: Int
    let color: Color
    let canBegin: () -> Bool
    let accepted: () -> Void
    let invalid: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> SpectrumNativeColorWell {
        SpectrumNativeColorWell(frame: NSRect(x: 0, y: 0, width: 72, height: 23))
    }
    func updateNSView(_ view: SpectrumNativeColorWell, context: Context) {
        view.configure(store: store, id: id, target: target, project: project, revision: revision,
            color: NSColor(color), enabled: enabled, canBegin: canBegin, accepted: accepted, invalid: invalid)
    }
    static func dismantleNSView(_ view: SpectrumNativeColorWell, coordinator: ()) { view.detach() }
}

@MainActor final class SpectrumNativeColorWell: NSColorWell {
    private weak var store: ProjectStore?
    private var item = UUID(), project = -1, revision = -1
    private(set) var colorTarget = SpectrumColorTarget.inside
    private(set) var ownerToken: UUID?
    private var observations: [NSObjectProtocol] = []
    private var escapeMonitor: Any?
    private var configuring = false, detached = false
    private var canBegin: () -> Bool = { false }
    private var accepted: () -> Void = {}
    private var invalid: () -> Void = {}
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        colorWellStyle = .default; supportsAlpha = false
        target = self; action = #selector(colorChanged(_:))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(store: ProjectStore, id: UUID, target: SpectrumColorTarget, project: Int, revision: Int,
                   color: NSColor, enabled: Bool, canBegin: @escaping () -> Bool,
                   accepted: @escaping () -> Void, invalid: @escaping () -> Void) {
        if self.store !== store || item != id || colorTarget != target || self.project != project || self.revision != revision {
            deactivate()
        }
        self.store = store; item = id; colorTarget = target; self.project = project; self.revision = revision
        self.canBegin = canBegin; self.accepted = accepted; self.invalid = invalid; isEnabled = enabled
        if let token = ownerToken, !store.spectrumColorEditing.isCurrent(store, token: token) { deactivate() }
        if !enabled { deactivate() }
        configuring = true; self.color = color; configuring = false
        setAccessibilityLabel(target == .inside ? "Inside Color" : "Outside Color")
        setAccessibilityIdentifier("spectrum.color." + target.rawValue)
    }
    override func activate(_ exclusive: Bool) {
        guard !detached, isEnabled, window != nil, superview != nil, let store else { return }
        window?.makeFirstResponder(nil)
        guard canBegin() else { return }
        if let token = ownerToken, store.spectrumColorEditing.isCurrent(store, token: token) {
            super.activate(true); return
        }
        let token = UUID()
        guard store.beginSpectrumColorEdit(token, target: colorTarget, id: item,
            project: project, revision: revision, expectedGeneration: store.generation) else { return }
        ownerToken = token
        NSColorPanel.shared.isContinuous = true
        super.activate(true)
        observeOwner()
    }
    override func deactivate() {
        if let token = ownerToken { store?.finishSpectrumColorEdit(token) }
        retireNativeOwner()
        super.deactivate()
    }
    @objc private func colorChanged(_ sender: Any?) {
        guard !configuring, isActive, let token = ownerToken, let store else { return }
        guard let rgb = SpectrumPickerRGB.channels(color) else { invalid(); return }
        let value = SpectrumItemStyle.RGB(red: rgb.0, green: rgb.1, blue: rgb.2)
        if store.updateSpectrumColorEdit(token, target: colorTarget, rgb: value) { accepted() }
    }
    private func observeOwner() {
        retireObservers()
        guard let observedToken = ownerToken else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            observations.append(center.addObserver(forName: name, object: NSColorPanel.shared, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.deactivateIfOwned(observedToken) }
            })
        }
        observations.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deactivateIfOwned(observedToken) }
        })
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { () -> NSEvent? in
                guard event.keyCode == 53, event.window === NSColorPanel.shared,
                      let self, self.isActive, self.ownerToken == observedToken, let store = self.store,
                      store.cancelSpectrumColorEdit(observedToken) else { return event }
                self.retireNativeOwner(); self.superDeactivate()
                self.accepted()
                return nil
            }
        }
    }
    private func deactivateIfOwned(_ token: UUID) { if ownerToken == token { deactivate() } }
    private func superDeactivate() { super.deactivate() }
    private func retireObservers() {
        observations.forEach { NotificationCenter.default.removeObserver($0) }; observations = []
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
    }
    private func retireNativeOwner() { ownerToken = nil; retireObservers() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { deactivate() }
    }
    func detach() { deactivate(); detached = true; target = nil; action = nil; store = nil }
}
