import AppKit
import Foundation
import OnTheFrameEngine

@main struct GateDisabledAppTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        guard CommandLine.arguments.contains("-OTFEnableImageImport"),
              !ProjectStore.imageImportEnabled, EditorLayout.shared.suiteName != nil else { exit(1) }
        let store=ProjectStore(), before=store.timeline
        var scopeCalls=0
        store.persistenceScopeStartForTest={_ in scopeCalls += 1;return true}
        let url=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("must-not-read.png")
        store.presentStillImageImportPanel() // Must return before creating any native panel.
        store.requestStillImageImport(url)
        let ok=await store.importStillImage(at:url)
        guard !ok, store.timeline==before, !store.imageImportBusy, scopeCalls==0,
              NSApp.modalWindow == nil else { exit(1) }
        print("COMPILED GATE DISABLED: 1 PASS, 0 FAIL, 0 SKIP (runtime opt-in cannot bypass)")
        exit(0)
    }
}
