#if DEBUG
import AppKit
import SwiftUI
import OnTheFrameEngine

/// Task-owned windows/local synthetic events only. No owner store, global input,
/// media mutation, native save panels or system pasteboard changes.
@MainActor enum SpectrumNumericScrubSelfTest {
    typealias Check = LaneSelfTest.Check
    private struct Failure: Error { let message: String }
    private static func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }
    private static func fixture(_ style: SpectrumItemStyle) throws -> Timeline {
        let lane = UUID()
        return try Timeline().addingLane(.spectrum, name: "Numeric test", id: lane)
            .addingSpectrum(lane: lane, at: 0, length: 300, sourceKey: nil, style: style)
    }
    @MainActor private final class Context {
        let store = ProjectStore()
        let control = SpectrumNumericControl(frame: NSRect(x: 20, y: 30, width: 140, height: 24))
        let next = NSTextField(frame: NSRect(x: 190, y: 30, width: 100, height: 24))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let property: SpectrumNumericProperty
        let initial: Timeline
        let id: UUID
        var text = "", focus = false, commits = 0, accepted = 0, rejected = 0
        init(_ property: SpectrumNumericProperty, _ style: SpectrumItemStyle) throws {
            self.property = property
            initial = try fixture(style); id = initial.spectra[0].id
            store.loadTimelineForTest(initial); store.savedTimeline = initial; store.select(id)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(control); window.contentView?.addSubview(next)
            control.field.nextKeyView = next; next.nextKeyView = control.field
            store.attachEditorWindow(window)
            sync(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(control)
        }
        var style: SpectrumItemStyle { store.timeline.spectrum(id)!.style }
        var basePoint: NSPoint { control.convert(NSPoint(x: 70, y: 12), to: nil) }
        func sync() {
            text = String(property.displayed(style))
            configure()
        }
        func configure() {
            control.configure(property: property, text: text, focused: focus, enabled: true, store: store,
                changeText: { [weak self] in self?.text = $0 }, focusChanged: { [weak self] in self?.focus = $0 },
                commit: { [weak self] in self?.commitText() }, begin: { [weak self] token in
                    guard let self else { return false }
                    return store.beginSpectrumNumericScrub(token, id: id, property: property, project: store.projectSession,
                        revision: store.spectrumSelectionRevision, expectedGeneration: store.generation)
                }, update: { [weak self] token, value in
                    guard let self else { return .obsolete }
                    let result = store.updateSpectrumNumericScrub(token, value: value)
                    if result == .accepted { accepted += 1; sync() }
                    if result == .rejected { rejected += 1 }
                    return result
                }, finish: { [weak self] token in self?.store.finishSpectrumNumericScrub(token); self?.sync() },
                cancel: { [weak self] token in
                    guard let self else { return }
                    store.cancelSpectrumNumericScrub(token)
                    if store.timeline.spectrum(id) != nil { sync() }
                })
        }
        func commitText() {
            commits += 1
            var draft = SpectrumStyleDraft(style)
            switch property {
            case .startX: draft.startX = text
            case .startY: draft.startY = text
            case .endX: draft.endX = text
            case .endY: draft.endY = text
            case .height: draft.height = text
            case .thickness: draft.thickness = text
            case .reaction: draft.reaction = text
            }
            guard let value = try? draft.style(from: style) else { return }
            _ = store.updateSpectrumLiveStyle(id, style: value, project: store.projectSession,
                revision: store.spectrumSelectionRevision, expectedGeneration: store.generation, kind: "numeric")
            sync()
        }
        func mouse(_ type: NSEvent.EventType, _ dx: CGFloat = 0, _ dy: CGFloat = 0, dispatch: Bool = false) {
            let point = NSPoint(x: basePoint.x + dx, y: basePoint.y + dy)
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            if dispatch { window.sendEvent(event); return }
            switch type {
            case .leftMouseDown: control.mouseDown(with: event)
            case .leftMouseDragged: control.mouseDragged(with: event)
            case .leftMouseUp: control.mouseUp(with: event)
            default: break
            }
        }
        func close() { control.detach(); window.makeFirstResponder(nil); store.resetProject(); window.close() }
    }

    private static func policies(_ check: (String, Bool, String) -> Void) {
        var legacy = SpectrumItemStyle.provisionalDefault
        legacy.thicknessMilli = 3125; legacy.startXMilli = -1500; legacy.maxHeightMilli = 400125; legacy.alpha = 192
        for property in SpectrumNumericProperty.allCases {
            let start = property.displayed(legacy), sensitivity = property.pointsPerStep
            check(property.rawValue + ".threshold", property.candidate(start: start, displacement: 4) == start, "")
            check(property.rawValue + ".right", property.candidate(start: start, displacement: 4 + sensitivity) == start + 1, "")
            check(property.rawValue + ".left", property.candidate(start: start, displacement: -4 - sensitivity) == start - 1, "")
            check(property.rawValue + ".substep", property.candidate(start: start, displacement: 4 + sensitivity * 0.9) == start, "")
            check(property.rawValue + ".bounds", property.candidate(start: start, displacement: 1e100) == property.range.upperBound &&
                  property.candidate(start: start, displacement: -1e100) == property.range.lowerBound, "")
            check(property.rawValue + ".nonfinite", property.candidate(start: start, displacement: .infinity) == nil, "")
            check(property.rawValue + ".original", property.applying(start, to: legacy) == legacy, "")
            check(property.rawValue + ".outOfRange", property.applying(property.range.upperBound + 1, to: legacy) == nil, "")
        }
        var minimum = legacy; minimum.thicknessMilli = 500
        check("half pixel legacy", SpectrumNumericProperty.thickness.applying(1, to: minimum) == minimum, "")
        var short = legacy; short.startXMilli = 0; short.startYMilli = 0; short.endXMilli = 1000; short.endYMilli = 0
        check("minimum endpoint distance", SpectrumNumericProperty.startX.applying(1, to: short) == nil, "")
        for value in ["3.125", "3.0", "nan", "Infinity", "1e2", "", "999999999999999999999999"] {
            var draft = SpectrumStyleDraft(legacy); draft.thickness = value
            check("invalid text " + value, (try? draft.style(from: legacy)) == nil, "")
        }
    }

    private static func gestures(_ check: (String, Bool, String) -> Void) throws {
        var legacy = SpectrumItemStyle.provisionalDefault; legacy.thicknessMilli = 3125; legacy.alpha = 192
        for property in SpectrumNumericProperty.allCases {
            let x = try Context(property, legacy); defer { x.close() }
            let before = x.initial, generation = x.store.generation, value = property.displayed(legacy)
            let dx = 4 + property.pointsPerStep
            x.mouse(.leftMouseDown)
            check(property.rawValue + ".down no mutation", x.store.timeline == before && !x.store.isDirty &&
                x.store.spectrumNumericScrubToken == nil && x.store.history.undoDepth == 0, "")
            x.mouse(.leftMouseDragged, 4)
            check(property.rawValue + ".four points", x.store.timeline == before && x.store.spectrumNumericScrubToken == nil, "")
            x.mouse(.leftMouseDragged, dx)
            check(property.rawValue + ".live", property.displayed(x.style) == value + 1 && x.store.history.undoDepth == 0 &&
                x.store.generation > generation && x.store.isDirty && x.accepted > 0, "")
            x.mouse(.leftMouseDragged, -dx)
            check(property.rawValue + ".reverse", property.displayed(x.style) == value - 1 && x.store.history.undoDepth == 0, "")
            let final = x.store.timeline
            x.mouse(.leftMouseUp, 600)
            check(property.rawValue + ".outside release one undo", x.store.timeline == final && x.store.history.undoDepth == 1 &&
                  x.store.spectrumNumericScrubToken == nil, "")
            x.store.undo()
            check(property.rawValue + ".undo exact", x.store.timeline == before && !x.store.isDirty, "")
            x.store.redo()
            check(property.rawValue + ".redo exact", x.store.timeline == final, "")
        }
        for mode in ["net-zero", "escape", "deactivate", "window", "remove", "vertical"] {
            let x = try Context(.thickness, legacy); defer { x.close() }
            x.mouse(.leftMouseDown)
            if mode == "vertical" { x.mouse(.leftMouseDragged, 2, 20) }
            else { x.mouse(.leftMouseDragged, 10) }
            switch mode {
            case "net-zero": x.mouse(.leftMouseDragged, 0)
            case "escape": x.control.cancelOperation(nil)
            case "deactivate": NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            case "window": NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: x.window)
            case "remove": x.control.removeFromSuperview()
            default: break
            }
            x.mouse(.leftMouseUp, 500)
            x.mouse(.leftMouseDragged, 30); x.mouse(.leftMouseUp, 30)
            check(mode + ".exact restoration no history", x.store.timeline == x.initial && !x.store.isDirty &&
                x.store.history.undoDepth == 0 && x.store.spectrumNumericScrubToken == nil, "")
        }
        let x = try Context(.thickness, legacy); defer { x.close() }
        x.mouse(.leftMouseDown, dispatch: true); x.mouse(.leftMouseDragged, 10, dispatch: true)
        x.mouse(.leftMouseUp, 600, dispatch: true)
        check("NSWindow outside release", x.store.history.undoDepth == 1 && x.store.spectrumNumericScrubToken == nil, "local synthetic dispatch")
        x.store.undo(); let token = UUID()
        _ = x.store.beginSpectrumNumericScrub(token, id: x.id, property: .thickness, project: x.store.projectSession,
            revision: x.store.spectrumSelectionRevision, expectedGeneration: x.store.generation)
        _ = x.store.updateSpectrumNumericScrub(token, value: 5); x.store.cancelSpectrumNumericScrub(token)
        check("cancel preserves redo", x.store.timeline == x.initial && x.store.history.canRedo && x.store.history.undoDepth == 0, "")
    }

    private static func isolation(_ check: (String, Bool, String) -> Void) throws {
        let x = try Context(.thickness, .provisionalDefault); defer { x.close() }
        // Install the real color observers, then return to the same model with no Undo.
        var colorSetup = x.style; colorSetup.red = 24
        _ = x.store.updateSpectrumLiveStyle(x.id, style: colorSetup, project: x.store.projectSession,
            revision: x.store.spectrumSelectionRevision, expectedGeneration: x.store.generation, kind: "color")
        _ = x.store.updateSpectrumLiveStyle(x.id, style: .provisionalDefault, project: x.store.projectSession,
            revision: x.store.spectrumSelectionRevision, expectedGeneration: x.store.generation, kind: "color")
        x.store.finishSpectrumLiveSession()
        x.mouse(.leftMouseDown); x.mouse(.leftMouseDragged, 10)
        let old = x.store.spectrumNumericScrubToken!
        x.store.select(nil); let selected = x.store.timeline
        x.control.cancelTracking(); x.store.cancelSpectrumNumericScrub(old); x.store.finishSpectrumNumericScrub(old)
        check("selection retires token", x.store.timeline == selected && x.store.history.undoDepth == 1, "")
        x.store.select(x.id); let newer = UUID()
        _ = x.store.beginSpectrumNumericScrub(newer, id: x.id, property: .reaction, project: x.store.projectSession,
            revision: x.store.spectrumSelectionRevision, expectedGeneration: x.store.generation)
        _ = x.store.updateSpectrumNumericScrub(newer, value: 120)
        x.store.finishSpectrumNumericScrub(old); x.store.cancelSpectrumNumericScrub(old)
        check("old callbacks cannot finish newer", x.store.spectrumNumericScrubToken == newer && x.store.history.undoDepth == 1, "")
        NotificationCenter.default.post(name: NSColorPanel.willCloseNotification, object: NSColorPanel.shared)
        check("color notification cannot finish scrub", x.store.spectrumNumericScrubToken == newer, "")
        x.store.finishSpectrumNumericScrub(newer)
        let dirtyBase = x.store.timeline, dirtyDepth = x.store.history.undoDepth
        x.mouse(.leftMouseDown); x.mouse(.leftMouseDragged, 10); x.control.cancelOperation(nil)
        check("cancel preserves already dirty state", x.store.timeline == dirtyBase && x.store.isDirty &&
              x.store.history.undoDepth == dirtyDepth, "")
        var slider = x.style; slider.thicknessMilli = 6000
        let beforeSlider = x.store.history.undoDepth
        _ = x.store.updateSpectrumLiveStyle(x.id, style: slider, project: x.store.projectSession,
            revision: x.store.spectrumSelectionRevision, expectedGeneration: x.store.generation, kind: "thickness-slider")
        x.store.finishSpectrumLiveSession()
        check("slider isolated undo", x.store.history.undoDepth == beforeSlider + 1 && x.style.thicknessMilli == 6000, "")
        var color = x.style; color.red = 24
        let depth = x.store.history.undoDepth
        _ = x.store.updateSpectrumLiveStyle(x.id, style: color, project: x.store.projectSession,
            revision: x.store.spectrumSelectionRevision, expectedGeneration: x.store.generation, kind: "color")
        NotificationCenter.default.post(name: NSColorPanel.willCloseNotification, object: NSColorPanel.shared)
        check("color close still one undo", x.store.history.undoDepth == depth + 1 && x.store.spectrumLiveSession == nil, "")
        x.mouse(.leftMouseDown); x.mouse(.leftMouseDragged, 10)
        let projectToken = x.store.spectrumNumericScrubToken!
        x.store.resetProject(); let replacement = x.store.timeline
        x.store.cancelSpectrumNumericScrub(projectToken); x.mouse(.leftMouseUp, 200)
        check("project replacement rejects old events", x.store.timeline == replacement && x.store.timeline.isEmpty &&
              x.store.history.undoDepth == 0 && !x.store.isDirty, "")
    }

    private static func nativeText(_ check: (String, Bool, String) -> Void) async throws {
        var legacy = SpectrumItemStyle.provisionalDefault; legacy.thicknessMilli = 500
        let x = try Context(.thickness, legacy); defer { x.close() }
        x.mouse(.leftMouseDown, dispatch: true); x.mouse(.leftMouseUp, dispatch: true)
        await settle()
        guard let editor = x.control.field.currentEditor() as? NSTextView else { throw Failure(message: "click did not enter field editor") }
        check("click selects full native value", editor.string == "1" && editor.selectedRange() == NSRange(location: 0, length: 1), "")
        check("click preserves half pixel", x.style.thicknessMilli == 500 && !x.store.isDirty && x.store.history.undoDepth == 0, "")
        editor.insertText("4", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        check("typing remains draft", x.style.thicknessMilli == 500 && !x.store.isDirty, "")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check("native Return commit", x.style.thicknessMilli == 4000 && x.store.history.undoDepth == 1, "")
        editor.selectAll(nil); editor.insertText("5", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        await settle()
        check("native Tab commits and moves", x.style.thicknessMilli == 5000 && x.store.history.undoDepth == 2 && x.next.currentEditor() != nil, "")
        if let nextEditor = x.next.currentEditor() as? NSTextView { nextEditor.doCommand(by: #selector(NSResponder.insertBacktab(_:))) }
        await settle()
        check("native Shift Tab returns", x.control.field.currentEditor() != nil, "")
        windowFocusAway(x)
        check("focus no-op does not dirty history", x.store.history.undoDepth == 2, "")
        x.text = "3.125"; x.commitText()
        check("native invalid numeric rejected", x.style.thicknessMilli == 5000 && x.store.history.undoDepth == 2, "")
        check("accessibility identity and value", x.control.field.accessibilityIdentifier() == "spectrum.numeric.thickness" &&
              x.control.field.accessibilityLabel() == "스펙트럼 두께", "")
    }
    private static func windowFocusAway(_ x: Context) { x.window.makeFirstResponder(nil) }

    static func run(folder: URL) async -> [Check] {
        var checks: [Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") { checks.append(Check(name: name, pass: pass, detail: detail)) }
        let owners = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && ($0.bundleIdentifier?.hasPrefix("dev.ontheframe.") ?? false)
        }
        guard owners.isEmpty, EditorLayout.shared.suiteName != nil,
              !FileManager.default.fileExists(atPath: folder.path) else {
            check("isolated invocation", false, "requires no owner app, isolated layout suite and fresh folder"); return checks
        }
        NSApp.activate()
        let activationDeadline = ProcessInfo.processInfo.systemUptime + 3
        while !NSApp.isActive, ProcessInfo.processInfo.systemUptime < activationDeadline { await settle() }
        guard NSApp.isActive else { check("native activation precondition", false, "task process must have an active AppKit event loop"); return checks }
        policies(check)
        do { try gestures(check); try isolation(check); try await nativeText(check) }
        catch { check("native checks completed", false, String(describing: error)) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try JSONEncoder().encode(checks).write(to: folder.appendingPathComponent("numeric-scrub-checks.json"), options: .withoutOverwriting)
        } catch { check("evidence written", false, String(describing: error)) }
        return checks
    }
}
#endif
