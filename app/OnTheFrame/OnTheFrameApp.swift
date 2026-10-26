import AppKit
import OnTheFrameEngine
import SwiftUI

@main
struct OnTheFrameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = ProjectStore.shared

    var body: some Scene {
        Window("ON THE FRAME", id: "main") {
            ContentView(store: store)
                // 최소 크기는 패널 최소 크기에서 정한다(EditorLayout). 작은 화면에서는 EditorLayout이 창 최소 크기를 쓸 수 있는 영역에 맞춰 줄인다.
                .frame(minWidth: EditorLayout.minContent.width, minHeight: EditorLayout.minContent.height)
        }
        // 창 위치·크기는 EditorLayout이 처음 70% 가운데 / 마지막 보통 창 되살리기로 직접 관리한다(SwiftUI 창 복원과 겹치지 않게 끔)
        .restorationBehavior(.disabled)
        .commands {
            // 파일(A-013): 프로젝트 하나를 편집기 창 하나에서. 새로 만들기·열기·최근·Finder 열기는 같은 저장하지 않은 변경 처리를 거친다.
            // 알림·시트·패널이 떠 있는 동안 파일 명령은 꺼진다(CP-03, fileCommandsAvailable). 저장소 함수도 같은 확인으로 막는다.
            CommandGroup(replacing: .newItem) {
                Button("새 프로젝트") { store.requestNewProject() }.keyboardShortcut("n").disabled(!store.fileCommandsAvailable)
                Button("프로젝트 열기…") { store.requestOpenProject(nil) }.keyboardShortcut("o").disabled(!store.fileCommandsAvailable)
                Menu("최근 프로젝트") {
                    ForEach(store.recentProjects) { r in Button(r.name) { store.openRecent(r) }.disabled(!store.fileCommandsAvailable) }
                    if !store.recentProjects.isEmpty { Divider() }
                    Button("목록 지우기") { store.clearRecents() }.disabled(store.recentProjects.isEmpty)
                }
                Divider()
                Button("가져오기…") { store.presentImportPanel() }.keyboardShortcut("i").disabled(!store.fileCommandsAvailable)
                Button("내보내기…") { store.presentExportPanel() }.keyboardShortcut("e")
                    .disabled(!store.fileCommandsAvailable || (!store.canExport && store.exportBlockReason == nil))
                Button("미디어 재연결…") { store.relinkFirstMissing() }.disabled(!store.fileCommandsAvailable || store.missingMedia.isEmpty)
            }
            CommandGroup(replacing: .saveItem) {
                Button("프로젝트 저장") { store.saveProject() }.keyboardShortcut("s").disabled(!store.fileCommandsAvailable)
                Button("다른 이름으로 저장…") { store.saveProject(saveAs: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!store.fileCommandsAvailable)
            }
            // 단축키는 흔히 쓰는 기본값(D-019·D-027, 완전 호환을 주장하지 않음). 키 입력은 KeyRouting이 실제 상태로 판단해 처리하고,
            // 메뉴는 표시·마우스 선택용이다(SwiftUI 메뉴 항목 상태는 메뉴를 열 때만 갱신되어 키 등가물로는 믿을 수 없었다).
            // 수정 키 없는 키(Space, ←/→, Home/End, Delete)는 메뉴 키 등가물로 두지 않고 제목에 키를 적는다.
            CommandGroup(replacing: .undoRedo) {
                Button("실행 취소") { store.menuUndo() }.keyboardShortcut("z").disabled(!store.undoMenuEnabled)
                Button("다시 실행") { store.menuRedo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.redoMenuEnabled)
            }
            // 편집 > 복사하기·붙여넣기(2026-10-11): 편집기에 초점이 있으면 타임라인 클립(앱 안 클립보드), 텍스트 입력 중이면 표준 텍스트 동작.
            // 키 입력은 KeyRouting이 판단한다(텍스트 입력 중에는 이 메뉴 키 등가물 → 응답자 체인). 텍스트에서 늘 쓰도록 항목을 끄지 않는다.
            // 오려두기·모두 선택·붙여넣고 스타일 맞추기는 텍스트 전용(타임라인 잘라내기는 없음): 편집기 초점이면 경고음만(CP-07, 2026-10-22).
            // 삭제: 텍스트 입력 중이면 표준 텍스트 삭제, 편집기 초점이면 고른 클립·자막 삭제(빈틈 남김, Delete 키와 같음).
            CommandGroup(replacing: .pasteboard) {
                Button("오려두기") { store.menuTextOnly(#selector(NSText.cut(_:))) }.keyboardShortcut("x")
                Button("복사하기") { store.menuCopy() }.keyboardShortcut("c")
                Button("붙여넣기") { store.menuPaste() }.keyboardShortcut("v")
                Button("붙여넣고 스타일 맞추기") { store.menuTextOnly(#selector(NSTextView.pasteAsPlainText(_:))) }.keyboardShortcut("v", modifiers: [.command, .option, .shift])
                Button("삭제") { store.menuDelete() }
                Button("모두 선택") { store.menuTextOnly(#selector(NSText.selectAll(_:))) }.keyboardShortcut("a")
            }
            CommandMenu("타임라인") {
                // 편집 도구(D-030): 체크 표시는 지금 도구. 수정 키 없는 V·C는 메뉴 키 등가물로 두지 않고 제목에만 적는다(키는 KeyRouting).
                Picker("편집 도구", selection: Binding(get: { store.tool }, set: { store.setTool($0) })) {
                    Text("선택 도구  V").tag(ProjectStore.EditTool.selection)
                    Text("자르기 도구  C").tag(ProjectStore.EditTool.cut)
                    Text("텍스트 도구  T").tag(ProjectStore.EditTool.text)
                }
                .pickerStyle(.inline).labelsHidden().disabled(store.gestureBase != nil)
                Divider()
                Button("재생 헤드에서 자르기") { store.menuSplit() }.keyboardShortcut("k").disabled(!store.canSplit)
                // 일반 삭제는 빈틈을 남기고, 리플 삭제는 뒤 클립을 당긴다(D-020, ON THE FRAME 기본값)
                Button("선택한 클립 삭제(빈틈 남김)  Delete") { store.deleteSelection(ripple: false) }
                    .disabled(store.selection == nil || !store.editorFocused || store.gestureBase != nil)
                Button("선택한 클립 리플 삭제  ⇧Delete") { store.deleteSelection(ripple: true) }
                    .disabled(store.selection == nil || !store.editorFocused || store.gestureBase != nil)
                Divider()
                // 연결(A-012): 연결된 영상·소리는 함께 선택·편집된다. 연결 해제 뒤 따로 옮기거나 다듬을 수 있다.
                Button("연결 해제(영상·소리 따로 편집)") { store.unlinkSelection() }.disabled(!store.canUnlink || store.gestureBase != nil)
                Button("연결(⌘-클릭한 클립과)") { store.linkSelection() }.disabled(!store.canLink || store.gestureBase != nil)
                Divider()
                // 레인(A-014): 추가·순서·삭제는 레인 머리 문맥 메뉴와 정보 패널에도 있다. 새 영상 레인은 맨 위, 새 오디오 레인은 맨 아래(가운데 경계에서 바깥쪽)
                Button("영상·소리 레인 쌍 추가") { store.addLanePair() }.disabled(store.gestureBase != nil)
                Button("영상 레인 추가") { store.addLane(.video) }.disabled(store.gestureBase != nil)
                Button("오디오 레인 추가") { store.addLane(.audio) }.disabled(store.gestureBase != nil)
                Button("자막 레인 추가") { store.addLane(.subtitle) }.disabled(store.gestureBase != nil)
                Divider()
                // 자막(2026-10-22): 재생 헤드에 기본 길이(3초) 자막. 기본 단축키 없음. 자막 레인이 없으면 S1을 함께 만든다.
                Button("자막 추가") { store.addSubtitleAtPlayhead() }.disabled(store.gestureBase != nil || !store.fileCommandsAvailable)
            }
            // 보기: 패널 접기·펼치기와 기본 배치(창 위치·크기는 바꾸지 않음)
            CommandGroup(before: .toolbar) {
                Button(EditorLayout.shared.mediaCollapsed ? "왼쪽 패널 펼치기" : "왼쪽 패널 접기") { EditorLayout.shared.toggleMedia() }
                Button(EditorLayout.shared.inspectorCollapsed ? "클립 정보 펼치기" : "클립 정보 접기") { EditorLayout.shared.toggleInspector() }
                Button("기본 배치로 재설정") { EditorLayout.shared.resetToDefault() }
                Divider()
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
    #if DEBUG
    /// 배치 자체 검사 준비(창이 붙기 전): 따로 둔 저장소를 비우거나(-OTFLayoutReset) 화면 밖 저장값을 넣는다(-OTFLayoutInject x,y,w,h)
    func applicationWillFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        // CP-04 수동 확인(2026-10-12): 명시적으로 줄 때만 재연결 확인을 늦춘다. 검사 도우미는 준비된 fixture가 의도대로 되는지 스스로 본다.
        if let k = args.firstIndex(of: "-OTFManualRelinkDelay"), k + 1 < args.count, let sec = Double(args[k + 1]), sec > 0 {
            ProjectStore.shared.relinkDelayForTest = UInt64(min(sec, 120) * 1e9)
        }
        if let k = args.firstIndex(of: "-OTFManualRelinkCheck"), k + 1 < args.count {
            let replacement = URL(fileURLWithPath: args[k + 1])
            Task { await RelinkGuardSelfTest.manualFixtureCheck(replacement: replacement) }
        }
        guard let i = args.firstIndex(of: "-OTFLayoutSuite"), i + 1 < args.count, let d = UserDefaults(suiteName: args[i + 1]) else { return }
        if args.contains("-OTFLayoutReset") { d.removePersistentDomain(forName: args[i + 1]); ProjectStore.shared.recentProjects = [] }   // 이미 읽어 둔 최근 목록도 비운다
        if let j = args.firstIndex(of: "-OTFLayoutInject"), j + 1 < args.count {
            let n = args[j + 1].split(separator: ",").compactMap { Double($0) }
            if n.count == 4 { d.set(NSStringFromRect(NSRect(x: n[0], y: n[1], width: n[2], height: n[3])), forKey: EditorLayout.frameKey) }
        }
    }
    #endif
    /// 종료 때 이 프로젝트가 시작한 보안 범위 접근을 멈춘다
    func applicationWillTerminate(_ notification: Notification) { ProjectStore.shared.stopAllScopes() }
    func application(_ application: NSApplication, open urls: [URL]) {
        ProjectStore.shared.ensureEditorVisible()
        // Finder에서 연 프로젝트 파일(A-013): 같은 저장하지 않은 변경 처리. 여러 개면 첫 파일만(창 하나에 프로젝트 하나).
        let projects = urls.filter { $0.pathExtension.lowercased() == ProjectFile.fileExtension }
        if let p = projects.first {
            ProjectStore.shared.requestOpenProject(p)
            if projects.count > 1 { ProjectStore.shared.statusMessage = "프로젝트는 한 번에 하나만 엽니다: \(p.lastPathComponent)" }
            let rest = urls.filter { $0.pathExtension.lowercased() != ProjectFile.fileExtension && !$0.hasDirectoryPath }
            if !rest.isEmpty { ProjectStore.shared.importFiles(rest) }
            return
        }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-OTFForceDirect") { LaneSelfTest.direct = true }   // 자체 검사를 직접 경로로(앱이 앞에 오지 못할 때의 경로를 재현)
        if args.contains("-OTFSavePanelTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await SavePanelSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFProjectTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await ProjectSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFGestureSwitchExperiment"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await GestureSwitchExperiment.run(folder: folder) }
            return
        }
        if args.contains("-OTFGestureGuardTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await GestureGuardSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFMakeManualRelinkFixture"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await RelinkGuardSelfTest.makeManualFixture(folder: folder) }
            return
        }
        if args.contains("-OTFPendingPressTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await PendingPressSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFRelinkGuardTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await RelinkGuardSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFFileGuardTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await FileGuardSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFColorLayoutTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await ColorLayoutSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFSubtitleTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await SubtitleSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFToolTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await ToolSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFCopyPasteTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await CopyPasteSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFOpenFlowTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await OpenFlowSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFOpenImportTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await OpenImportSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFClipAudioTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await ClipAudioSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFPanelTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await PanelSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFSpectrumPreviewTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await SpectrumPreviewExperiment.run(folder: folder) }
            return
        }
        if args.contains("-OTFSpectrumPauseReconcile"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await SpectrumPreviewExperiment.runPauseReconcile(folder: folder) }
            return
        }
        if args.contains("-OTFRealMediaCheck"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            let media = urls.first { !$0.hasDirectoryPath }
            Task { await SpectrumPreviewExperiment.runRealCheck(folder: folder, media: media) }
            return
        }
        if args.contains("-OTFSpectrumPausePhase"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await SpectrumPreviewExperiment.runPausePhase(folder: folder) }
            return
        }
        if args.contains("-OTFSpectrumPauseProbe"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await SpectrumPreviewExperiment.runPauseProbe(folder: folder) }
            return
        }
        if args.contains("-OTFSpectrumMarkerGeometry"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await SpectrumPreviewExperiment.runGeometry(folder: folder) }
            return
        }
        if args.contains("-OTFSpectrumPreviewManual"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            let media = urls.first { !$0.hasDirectoryPath }   // 함께 연 실제 미디어(있으면, 읽기만)
            Task { await SpectrumPreviewExperiment.runManual(folder: folder, media: media) }
            return
        }
        if args.contains("-OTFSubtitleWindowTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await SubtitleWindowSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFTimelineDrawTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await TimelineDrawSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFTransformPerfTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await TransformPerfSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFEditFixTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await EditFixSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFTransformTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await TransformSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFMultiLaneTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await MultiLaneSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFLaneTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {
            Task { await LaneSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFSpectrumLaneTest"), let folder = urls.first(where: { $0.hasDirectoryPath }) {   // SP-1A 2A(2026-10-25)
            Task { await SpectrumLaneSelfTest.run(folder: folder) }
            return
        }
        if args.contains("-OTFSpectrumLaneManual"), let folder = urls.first(where: { $0.hasDirectoryPath }) {   // SP-1A 2A 소유자 화면 확인(2026-10-26)
            Task { await SpectrumLaneSelfTest.runManual(folder: folder) }
            return
        }
        if args.contains("-OTFMakeSpectrumProjects"), let folder = urls.first(where: { $0.hasDirectoryPath }) {   // SP-1A 2B-1 소유자 확인 파일(2026-10-26)
            Task { await SpectrumLaneSelfTest.makeManualProjects(folder: folder) }
            return
        }
        if let i = args.firstIndex(of: "-OTFLayoutTest"), i + 1 < args.count, let folder = urls.first(where: { $0.hasDirectoryPath }) {
            let phase = args[i + 1]
            Task { await LayoutSelfTest.run(folder: folder, phase: phase) }
            return
        }
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
        s.commitInlineEditIfAny()   // 프리뷰 위 글 편집을 확정한 뒤 저장 확인을 판단한다(§44)
        if s.canCloseWithoutPrompt, s.exportPhase == .idle { return .terminateNow }
        s.requestDiscard(.quit, proceed: { DispatchQueue.main.async { NSApp.terminate(nil) } }, cancel: {})
        return .terminateCancel
    }
}
