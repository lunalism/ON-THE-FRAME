#if DEBUG
import AppKit
import SwiftUI
import OnTheFrameEngine

/// Task-owned windows/local synthetic events only. No owner store, global input,
/// media mutation, native save panels or system pasteboard changes.
@MainActor enum SpectrumNumericScrubSelfTest {
    typealias Check = LaneSelfTest.Check
    private struct Failure: Error { let message: String }
    private static let analysisProperties: [SpectrumNumericProperty] = [.lowHz, .highHz, .bands, .windowMs, .offsetMs]
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
            case .lowHz: draft.lowHz = text
            case .highHz: draft.highHz = text
            case .bands: draft.bands = text
            case .windowMs: draft.windowMs = text
            case .offsetMs: draft.offsetMs = text
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
            check(property.rawValue + ".malformed start", property.candidate(start: Int.min, displacement: -10) == nil &&
                  property.candidate(start: Int.max, displacement: 10) == nil, "no overflowing candidate addition")
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
        for property in analysisProperties {
            for value in ["1.5", "20.0", "1e2", "", "-", "+", String(Int.max), String(Int.min), String(Int.max) + "0"] {
                var draft = SpectrumStyleDraft(legacy)
                switch property {
                case .lowHz: draft.lowHz = value
                case .highHz: draft.highHz = value
                case .windowMs: draft.windowMs = value
                case .offsetMs: draft.offsetMs = value
                default: draft.bands = value
                }
                check(property.rawValue + ".invalid text " + value, (try? draft.style(from: legacy)) == nil, "")
            }
        }
        check("frequency equal rejected", SpectrumNumericProperty.lowHz.applying(legacy.highHz, to: legacy) == nil &&
              SpectrumNumericProperty.highHz.applying(legacy.lowHz, to: legacy) == nil, "")
        check("frequency effective bounds", SpectrumNumericProperty.lowHz.effectiveRange(in: legacy) == 1...1999 &&
              SpectrumNumericProperty.highHz.effectiveRange(in: legacy) == 21...24000, "48 kHz product contract")
        for value in [1, 1024] {
            check("bands boundary \(value)", SpectrumNumericProperty.bands.applying(value, to: legacy)?.bands == value, "")
        }
        check("bands zero rejected", SpectrumNumericProperty.bands.applying(0, to: legacy) == nil, "")
        for value in [1, 1000] {
            check("window boundary \(value)", SpectrumNumericProperty.windowMs.applying(value, to: legacy)?.windowMs == value, "")
        }
        for value in [-10000, 0, 10000] {
            check("offset boundary \(value)", SpectrumNumericProperty.offsetMs.applying(value, to: legacy)?.offsetMs == value, "")
        }
        var invalidStyle = legacy; invalidStyle.offsetMs = Int.min
        check("unchanged field rejects invalid offset style", SpectrumNumericProperty.bands.applying(legacy.bands, to: invalidStyle) == nil, "")
        invalidStyle = legacy; invalidStyle.windowMs = 0
        check("unchanged field rejects invalid window style", SpectrumNumericProperty.bands.applying(legacy.bands, to: invalidStyle) == nil, "")
        var pair = SpectrumStyleDraft(legacy); pair.lowHz = "22000"; pair.highHz = "24000"
        let atomic = try? pair.style(from: legacy)
        check("frequency pair atomic valid", atomic?.lowHz == 22000 && atomic?.highHz == 24000 &&
              atomic?.thicknessMilli == legacy.thicknessMilli && atomic?.maxHeightMilli == legacy.maxHeightMilli, "")
        pair.highHz = "24001"
        check("Nyquist exceeded rejected", (try? pair.style(from: legacy)) == nil, "")
        var malformed = legacy; malformed.highHz = Int.min; malformed.lowHz = Int.max
        check("malformed peer no range overflow", SpectrumNumericProperty.lowHz.effectiveRange(in: malformed) == nil &&
              SpectrumNumericProperty.highHz.effectiveRange(in: malformed) == nil, "")
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
        for property in [SpectrumNumericProperty.thickness] + analysisProperties {
          for mode in ["net-zero", "escape", "deactivate", "window", "remove", "vertical"] {
            let x = try Context(property, legacy); defer { x.close() }
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
            check(property.rawValue + "." + mode + ".exact restoration no history", x.store.timeline == x.initial && !x.store.isDirty &&
                x.store.history.undoDepth == 0 && x.store.spectrumNumericScrubToken == nil, "")
          }
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

    private static func timingNativeText(_ check: (String, Bool, String) -> Void) async throws {
        var legacy = SpectrumItemStyle.provisionalDefault
        legacy.offsetMs = -125; legacy.thicknessMilli = 3125; legacy.maxHeightMilli = 480250
        for property in [SpectrumNumericProperty.windowMs, .offsetMs] {
            let x = try Context(property, legacy); defer { x.close() }
            x.mouse(.leftMouseDown, dispatch: true); x.mouse(.leftMouseUp, dispatch: true)
            await settle()
            guard let editor = x.control.field.currentEditor() as? NSTextView else {
                throw Failure(message: property.rawValue + " timing native editor")
            }
            for invalid in ["", "-", "+", "1.5", "1e2", String(Int.min), String(Int.max) + "0"] {
                editor.insertText(invalid, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                check(property.rawValue + ".native invalid Return " + invalid,
                    x.store.timeline == x.initial && !x.store.isDirty && x.store.history.undoDepth == 0, "draft rejected atomically")
            }
            let first = property == .offsetMs ? -250 : 92
            let second = property == .offsetMs ? -375 : 93
            editor.insertText(String(first), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            check(property.rawValue + ".native Return exact", x.style == property.applying(first, to: legacy) &&
                x.store.history.undoDepth == 1, "signed integer and untouched legacy milli fields")
            editor.insertText(String(second), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            await settle()
            let final = x.store.timeline
            check(property.rawValue + ".native Tab exact", x.style == property.applying(second, to: legacy) &&
                x.store.history.undoDepth == 2 && x.next.currentEditor() != nil, "native focus transition")
            windowFocusAway(x); x.store.undo(); x.store.undo()
            check(property.rawValue + ".negative base Undo restored", x.store.timeline == x.initial &&
                x.style.offsetMs == -125 && !x.store.isDirty, "")
            x.store.redo(); x.store.redo()
            check(property.rawValue + ".native Redo exact", x.store.timeline == final && x.store.isDirty, "")
        }
        for property in [SpectrumNumericProperty.windowMs, .offsetMs] {
            for boundary in [property.range.lowerBound, property.range.upperBound] {
                let x = try Context(property, legacy); defer { x.close() }
                x.mouse(.leftMouseDown, dispatch: true); x.mouse(.leftMouseUp, dispatch: true)
                await settle()
                guard let editor = x.control.field.currentEditor() as? NSTextView else {
                    throw Failure(message: property.rawValue + " boundary native editor")
                }
                editor.insertText(String(boundary), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                check(property.rawValue + ".native boundary \(boundary)",
                    x.style == property.applying(boundary, to: legacy) && x.store.history.undoDepth == 1, "")
                windowFocusAway(x); x.store.undo()
                check(property.rawValue + ".boundary Undo exact \(boundary)", x.store.timeline == x.initial && !x.store.isDirty, "")
            }
        }
    }

    private static func analysisOwnership(_ check: (String, Bool, String) -> Void) throws {
        for property in analysisProperties {
            let x = try Context(property, .provisionalDefault); defer { x.close() }
            x.mouse(.leftMouseDown); x.mouse(.leftMouseDragged, 4 + 2 * property.pointsPerStep)
            guard let old = x.store.spectrumNumericScrubToken else { throw Failure(message: "analysis ownership initial token") }
            x.store.select(nil); let selected = x.store.timeline, depth = x.store.history.undoDepth
            x.control.cancelTracking(); x.store.cancelSpectrumNumericScrub(old); x.mouse(.leftMouseUp, 600)
            check(property.rawValue + ".selection retires ownership", x.store.timeline == selected &&
                x.store.history.undoDepth == depth && x.store.spectrumNumericScrubToken == nil, "")
            x.store.select(x.id)
            let newer = UUID()
            guard x.store.beginSpectrumNumericScrub(newer, id: x.id, property: property, project: x.store.projectSession,
                revision: x.store.spectrumSelectionRevision, expectedGeneration: x.store.generation),
                x.store.updateSpectrumNumericScrub(newer, value: property.displayed(x.style) + 1) == .accepted else {
                throw Failure(message: "analysis ownership replacement token")
            }
            let current = x.store.timeline
            x.store.finishSpectrumNumericScrub(old); x.store.cancelSpectrumNumericScrub(old)
            NotificationCenter.default.post(name: NSColorPanel.willCloseNotification, object: NSColorPanel.shared)
            check(property.rawValue + ".old callback and color cannot retire newer", x.store.spectrumNumericScrubToken == newer &&
                x.store.timeline == current && x.store.history.undoDepth == depth, "")
            x.store.resetProject(); let empty = x.store.timeline
            x.store.cancelSpectrumNumericScrub(newer); x.store.finishSpectrumNumericScrub(newer); x.mouse(.leftMouseUp, 600)
            check(property.rawValue + ".project retires ownership", x.store.timeline == empty && empty.isEmpty &&
                x.store.history.undoDepth == 0 && !x.store.isDirty, "")
        }
    }

    private static func analysisEditing(_ folder: URL, _ check: (String, Bool, String) -> Void) async throws {
        var legacy = SpectrumItemStyle.provisionalDefault
        legacy.startXMilli = 192125; legacy.maxHeightMilli = 480250; legacy.thicknessMilli = 3125
        legacy.offsetMs = -125
        for property in analysisProperties {
            let x = try Context(property, legacy); defer { x.close() }
            let start = property.displayed(legacy), value = start + 2
            x.mouse(.leftMouseDown, dispatch: true); x.mouse(.leftMouseUp, dispatch: true)
            await settle()
            guard let editor = x.control.field.currentEditor() as? NSTextView else {
                throw Failure(message: property.rawValue + " click did not enter native editor")
            }
            editor.insertText(String(value), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            check(property.rawValue + ".native draft only", x.style == legacy && !x.store.isDirty, "")
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            check(property.rawValue + ".native integer commit", property.displayed(x.style) == value && x.store.history.undoDepth == 1, "")
            windowFocusAway(x); x.store.undo()
            check(property.rawValue + ".native undo exact milli", x.style == legacy && !x.store.isDirty, "")

            // Explicit Apply and live publication must share the same narrow capability set.
            let candidate = property.applying(value, to: legacy)!
            let error = x.store.setSpectrumStyle(x.id, style: candidate, from: legacy, project: x.store.projectSession,
                selectionRevision: x.store.spectrumSelectionRevision, generation: x.store.generation)
            check(property.rawValue + ".explicit Apply allowed", error == nil && x.style == candidate, "")
            x.store.undo()
            for restricted in ["floor", "alpha"] {
                var denied = legacy
                switch restricted {
                case "floor": denied.floorDB -= 1
                default: denied.alpha -= 1
                }
                let before = x.store.timeline, depth = x.store.history.undoDepth
                let explicit = x.store.setSpectrumStyle(x.id, style: denied, from: legacy, project: x.store.projectSession,
                    selectionRevision: x.store.spectrumSelectionRevision, generation: x.store.generation)
                let live = x.store.updateSpectrumLiveStyle(x.id, style: denied, project: x.store.projectSession,
                    revision: x.store.spectrumSelectionRevision, expectedGeneration: x.store.generation, kind: "numeric")
                check(property.rawValue + ".restricted " + restricted, explicit != nil && !live &&
                    x.store.timeline == before && x.store.history.undoDepth == depth, "both allowlists")
            }
            if property == .windowMs || property == .offsetMs {
                let invalidValues = [property.range.lowerBound - 1, property.range.upperBound + 1, Int.min, Int.max]
                for value in invalidValues {
                    var denied = legacy
                    if property == .windowMs { denied.windowMs = value } else { denied.offsetMs = value }
                    let before = x.store.timeline, depth = x.store.history.undoDepth
                    let explicit = x.store.setSpectrumStyle(x.id, style: denied, from: legacy, project: x.store.projectSession,
                        selectionRevision: x.store.spectrumSelectionRevision, generation: x.store.generation)
                    let live = x.store.updateSpectrumLiveStyle(x.id, style: denied, project: x.store.projectSession,
                        revision: x.store.spectrumSelectionRevision, expectedGeneration: x.store.generation, kind: "numeric")
                    check(property.rawValue + ".invalid entire style \(value)", explicit != nil && !live &&
                        x.store.timeline == before && x.store.history.undoDepth == depth, "reject before timeline timing helpers")
                }
            }
            x.mouse(.leftMouseDown); x.mouse(.leftMouseDragged, 4 + 2 * property.pointsPerStep)
            let saved = x.store.timeline
            let url = folder.appendingPathComponent(property.rawValue + "-active-save.ontheframe")
            // Existing menu save path, with a task-owned destination and no panel.
            x.store.projectURL = url
            x.store.saveProject()
            check(property.rawValue + ".active save finalizes once", x.store.spectrumNumericScrubToken == nil &&
                  x.store.history.undoDepth == 1 && !x.store.isDirty && x.store.timeline == saved, "")
            x.mouse(.leftMouseUp, 600)
            let decoded = try ProjectPersistence.decode(Data(contentsOf: url))
            check(property.rawValue + ".Format10 saved", decoded.version == 10 && decoded.timeline.spectrum(x.id)?.style == candidate, "")
            x.store.undo()
            check(property.rawValue + ".undo after save dirty", x.style == legacy && x.store.isDirty, "")
            x.store.redo()
            check(property.rawValue + ".redo saved clean", x.store.timeline == saved && !x.store.isDirty, "")
            let reopened = ProjectStore()
            let opened = await reopened.openProject(at: url)
            check(property.rawValue + ".app reopen", opened && reopened.timeline.spectrum(x.id)?.style == candidate && !reopened.isDirty, "")
            if property == .offsetMs {
                check("negative offset saved and reopened", candidate.offsetMs < 0 &&
                    decoded.timeline.spectrum(x.id)?.style.offsetMs == candidate.offsetMs &&
                    reopened.timeline.spectrum(x.id)?.style.offsetMs == candidate.offsetMs, "unchanged milli geometry retained")
            }
            reopened.resetProject()
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            // Corrupt only the selected style in an isolated in-memory document.
            if var spectra = json["spectra"] as? [[String: Any]], !spectra.isEmpty,
               let originalStyle = spectra[0]["style"] as? [String: Any] {
                var style = originalStyle
                style["lowHz"] = 2000; style["highHz"] = 20
                spectra[0]["style"] = style; json["spectra"] = spectra
                let corrupt = try JSONSerialization.data(withJSONObject: json)
                check(property.rawValue + ".malformed project rejected", (try? ProjectPersistence.decode(corrupt)) == nil, "")
                if property == .windowMs || property == .offsetMs {
                    for value in [property.range.lowerBound - 1, property.range.upperBound + 1, Int.min, Int.max] {
                        var invalid = originalStyle; invalid[property.rawValue] = value
                        spectra[0]["style"] = invalid; json["spectra"] = spectra
                        let malformed = try JSONSerialization.data(withJSONObject: json)
                        check(property.rawValue + ".malformed timing project \(value)",
                            (try? ProjectPersistence.decode(malformed)) == nil, "no invalid timing reaches overlap helpers")
                    }
                }
            } else { check(property.rawValue + ".malformed project fixture located", false, "unexpected Format10 structure") }
        }
        for property in [SpectrumNumericProperty.lowHz, .highHz] {
            var close = legacy; close.lowHz = 100; close.highHz = 103
            let x = try Context(property, close); defer { x.close() }
            let sign: CGFloat = property == .lowHz ? 1 : -1
            x.mouse(.leftMouseDown); x.mouse(.leftMouseDragged, sign * 5)
            let last = x.store.timeline
            x.mouse(.leftMouseDragged, sign * 50)
            check(property.rawValue + ".cross holds last valid", x.rejected > 0 && x.store.timeline == last &&
                  x.store.history.undoDepth == 0, "opposite frequency unchanged")
            x.mouse(.leftMouseDragged, sign * 6)
            check(property.rawValue + ".cross returns valid", property.displayed(x.style) == property.displayed(close) + Int(sign) * 2, "")
            x.control.cancelOperation(nil)
            check(property.rawValue + ".cross Escape exact", x.store.timeline == x.initial && !x.store.isDirty && x.store.history.undoDepth == 0, "")
        }
    }

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
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        catch { check("fresh evidence directory", false, String(describing: error)); return checks }
        policies(check)
        do {
            try gestures(check); try isolation(check); try analysisOwnership(check)
            try await nativeText(check); try await timingNativeText(check); try await analysisEditing(folder, check)
        }
        catch { check("native checks completed", false, String(describing: error)) }
        do {
            try JSONEncoder().encode(checks).write(to: folder.appendingPathComponent("numeric-scrub-checks.json"), options: .withoutOverwriting)
        } catch { check("evidence written", false, String(describing: error)) }
        return checks
    }
}
#endif
