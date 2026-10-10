import AppKit
import SwiftUI

@main
struct OnTheFrameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = ProjectStore.shared

    var body: some Scene {
        Window("ON THE FRAME", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("가져오기…") { store.presentImportPanel() }.keyboardShortcut("i")
                Button("내보내기…") { store.presentExportPanel() }.keyboardShortcut("e").disabled(!store.canExport)
            }
            // 단축키는 Premiere 방식 기본값(D-019, 완전 호환 아님). 키 입력은 KeyRouting이 실제 상태로 판단해 처리하고,
            // 메뉴는 표시·마우스 선택용이다(SwiftUI 메뉴 항목 상태는 메뉴를 열 때만 갱신되어 키 등가물로는 믿을 수 없었다).
            // 수정 키 없는 키(Space, ←/→, Home/End, Delete)는 메뉴 키 등가물로 두지 않고 제목에 키를 적는다.
            CommandGroup(replacing: .undoRedo) {
                Button("실행 취소") { store.menuUndo() }.keyboardShortcut("z").disabled(!store.undoMenuEnabled)
                Button("다시 실행") { store.menuRedo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.redoMenuEnabled)
            }
            CommandMenu("타임라인") {
                Button("재생 헤드에서 자르기") { store.menuSplit() }.keyboardShortcut("k").disabled(!store.canSplit)
                // 일반 삭제는 빈틈을 남기고, 리플 삭제는 뒤 클립을 당긴다(D-020, ON THE FRAME 기본값)
                Button("선택한 클립 삭제(빈틈 남김)  Delete") { store.deleteSelection(ripple: false) }
                    .disabled(store.selection == nil || !store.editorFocused || store.gestureBase != nil)
                Button("선택한 클립 리플 삭제  ⇧Delete") { store.deleteSelection(ripple: true) }
                    .disabled(store.selection == nil || !store.editorFocused || store.gestureBase != nil)
            }
            CommandMenu("재생") {
                Button(store.isPlaying ? "일시정지  Space" : "재생  Space") { store.togglePlay() }.disabled(!store.canPlay)
                Button("이전 프레임  ←") { store.step(-1) }.disabled(store.timeline.isEmpty)
                Button("다음 프레임  →") { store.step(1) }.disabled(store.timeline.isEmpty)
                Button("처음으로  Home") { store.pauseForEdit(); store.seek(to: 0) }.disabled(store.timeline.isEmpty)
                Button("끝으로  End") { store.pauseForEdit(); store.seek(to: store.durationFrames) }.disabled(store.timeline.isEmpty)
            }
        }
    }
}

/// Finder·`open -a`로 열린 파일 처리. Debug 빌드에서는 숨은 자체 검사(-OTFSelfTest, 개발 검증용) 진입점도 둔다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        ProjectStore.shared.ensureEditorVisible()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-OTFPreviewTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await PreviewSelfTest.run(folder: folder) }
            return
        }
        if let i = args.firstIndex(of: "-OTFCloseTest"), i + 1 < args.count, let folder = urls.first(where: { $0.hasDirectoryPath }) {
            let mode = args[i + 1]
            Task { await CloseSelfTest.run(folder: folder, mode: mode) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-OTFLayerDiag"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await LayerDiagSelfTest.run(folder: folder) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-OTFVisualTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await VisualSelfTest.run(folder: folder) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-OTFShortcutTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await ShortcutSelfTest.run(folder: folder) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-OTFSelfTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await SelfTest.run(folder: folder) }
            return
        }
        #endif
        ProjectStore.shared.importFiles(urls.filter { !$0.hasDirectoryPath })
    }
    /// Dock 아이콘을 눌렀는데 보이는 창이 없으면 편집기 창을 다시 보인다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { ProjectStore.shared.ensureEditorVisible() }
        return false
    }

    /// 마지막 창이 닫히면 끝낸다. 단, 사용자가 닫은 경우(확인했거나 확인이 필요 없던 닫기)만. 실행 직후 창 복원 과정에서
    /// 창이 잠깐 닫히는 경우에는 끝내지 않는다(자체 검사에서 실행 0.3초 만에 끝난 기록).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { ProjectStore.shared.editorClosedByUser }
    /// 종료: 편집 작업이 있으면 버릴지 묻는다(취소가 기본). 이번 종료 요청은 바로 취소하고(terminateCancel) 확인을 띄운다.
    /// terminateLater로 기다리면 AppKit의 중첩 실행 루프에서 주 actor 작업이 돌지 않아(자체 검사로 확인), 내보내기 취소·정리를
    /// 기다리는 동안 멈출 수 있기 때문이다. 버리기를 고르면 진행 중인 내보내기를 취소하고 임시 파일을 정리한 뒤 다시 종료한다
    /// (그때는 확정 상태라 바로 끝남, 대상 파일은 만들지 않음). 이미 확인이 떠 있으면 새 확인을 만들지 않는다.
    /// 시스템 로그아웃·종료 중이면 앱이 그 과정을 한 번 취소하게 된다(저장하지 않은 작업이 있을 때의 안전한 방향).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let s = ProjectStore.shared
        if s.canCloseWithoutPrompt, s.exportPhase == .idle { return .terminateNow }
        s.requestDiscard(.quit, proceed: { DispatchQueue.main.async { NSApp.terminate(nil) } }, cancel: {})
        return .terminateCancel
    }
}
