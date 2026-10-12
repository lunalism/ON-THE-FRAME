import AppKit
import UniformTypeIdentifiers
import AVFoundation
import IOKit.pwr_mgt
import Observation
import OnTheFrameEngine
import os

/// 앱 상태(M1, 창 하나·메모리 안 프로젝트). 타임라인은 불변 스냅샷이고 편집 기록(EditHistory)이 실행 취소를 맡는다.
/// 편집 → 새 스냅샷 → CompositionPlanner(프리뷰·내보내기 공유) → 프리뷰 항목 교체. 오래된 재구성 결과는 세대 번호로 버린다.
@MainActor
@Observable
final class ProjectStore {
    static let shared = ProjectStore()
    static let log = Logger(subsystem: "dev.ontheframe.app", category: "store")

    let settings = RenderSettings.m1
    /// 쓸 수 있는(찾은) 원본 미디어. 프로젝트의 미디어 목록(timeline.media)과 검사 결과 캐시에서 만든다(refreshAssets).
    var assets: [MediaAsset] = []
    // MARK: 프로젝트(A-013)
    /// 현재 프로젝트 파일 위치(처음 저장 전에는 nil)
    var projectURL: URL?
    var projectID = UUID()
    /// 프로젝트 회차: 프로젝트를 바꿀 때마다(새 프로젝트·열기, 같은 파일을 다시 열어도) 1 는다. 저장된 프로젝트 ID는 같은 프로젝트를 다시 열면 같아서
    /// 확인 요청을 묶는 데 쓰기에 모자라다(CP-02, 2026-10-12).
    @ObservationIgnored private(set) var projectSession = 0
    /// 마지막으로 저장하거나 연 상태. 지금 상태와 다르면 저장하지 않은 변경이 있다(실행 취소로 돌아오면 사라짐).
    var savedTimeline = Timeline()
    var isDirty: Bool { history.timeline != savedTimeline }
    var projectName: String { projectURL?.deletingPathExtension().lastPathComponent ?? "제목 없음" }
    /// 창 제목: 프로젝트 이름과 저장하지 않은 변경 표시
    var windowTitle: String { projectName + (isDirty ? " — 편집됨" : "") }
    /// 찾을 수 없거나 쓸 수 없는 원본 미디어(미디어 id → 이유)
    var missingMedia: [UUID: String] = [:]
    /// 원본 경로(MediaRef.path) → 검사 결과(실제 위치). 재연결 실행 취소·다시 실행이 여기서 원본을 바꿔 낀다.
    @ObservationIgnored var assetCache: [String: MediaAsset] = [:]
    /// 미디어 id → 샌드박스 접근 북마크(저장 파일에 넣음)
    @ObservationIgnored var bookmarks: [UUID: Data] = [:]
    /// 이 프로젝트가 시작한 보안 범위 접근(프로젝트를 바꾸거나 앱을 끝낼 때 모두 멈춘다)
    @ObservationIgnored var scopedURLs: [URL] = []
    var recentProjects: [RecentProject] = []
    #if DEBUG
    /// 자체 검사 전용: 실제 저장 패널을 띄운 뒤 이 위치·이름으로 확인한다
    @ObservationIgnored var savePanelAutoConfirmForTest: (directory: URL, name: String)?
    @ObservationIgnored var autoConfirmTimer: Timer?
    /// 자체 검사 전용: 다음 저장 패널이 확인으로 이 위치를 돌려준 것처럼 한다(패널을 띄우지 않음)
    @ObservationIgnored var savePanelResultForTest: URL?
    /// 자체 검사 전용: 다음 프로젝트 저장을 승격 직전에 실패시킨다
    @ObservationIgnored var saveFailureForTest = false
    #endif
    private(set) var history = EditHistory()
    var timeline: Timeline { history.timeline }
    /// 선택한 클립(주 선택). 연결된 짝도 함께 선택된 것으로 보인다(selectedIDs).
    var selection: UUID? { didSet { if selection == nil || selection == linkCandidate { linkCandidate = nil } } }
    /// ⌘-클릭으로 더한 둘째 클립(연결 후보, 다른 레인). 편집 동작은 주 선택의 묶음에만 적용된다.
    var linkCandidate: UUID?
    /// 화면에 선택으로 보이는 클립: 주 선택의 묶음 + 연결 후보
    var selectedIDs: Set<UUID> {
        var s = Set(selection.map { timeline.group(of: $0).map(\.id) } ?? [])
        if let c = linkCandidate { s.insert(c) }
        return s
    }
    private(set) var playhead = 0              // 0…durationFrames(끝 위치 포함)
    /// 타임라인 확대(프레임당 포인트). 보기를 다시 만들어도 유지한다.
    var timelineZoom: Double = 2
    private(set) var isPlaying = false
    var statusMessage: String?
    /// 표시 중인 알림(관찰·검사용 사본). 실제 표시는 AlertPresenter(AppKit 시트)가 맡고,
    /// 표시 중인 알림은 바꾸거나 코드로 닫지 않는다(2026-10-10 충돌 대응, app/README.md 충돌 기록).
    private(set) var alert: AlertInfo?

    // MARK: 파일 명령 보호(CP-03, 2026-10-12)

    /// 지금 돌고 있는 저장·열기·가져오기·내보내기·재연결 패널 수(runModal 동안 1 이상). 메뉴 사용 가능 상태에 쓴다.
    private(set) var panelsRunning = 0
    /// 앱의 저장·열기 패널을 앱 모달로 돌린다(돌고 있는 동안 파일 명령을 받지 않는다)
    func runPanel(_ p: NSSavePanel) -> NSApplication.ModalResponse {
        panelsRunning += 1
        defer { panelsRunning -= 1 }
        return p.runModal()
    }
    #if DEBUG
    /// 자체 검사 전용: 실제 패널 대신 검사용 창을 같은 방식(패널 수 + 앱 모달)으로 돌린다
    func runModalLikePanelForTest(_ w: NSWindow) {
        panelsRunning += 1
        defer { panelsRunning -= 1 }
        NSApp.runModal(for: w)
    }
    #endif
    /// 사용자가 시작하는 파일 명령(새 프로젝트·열기·최근 프로젝트·가져오기·내보내기·저장·다른 이름으로 저장·재연결)을 지금 받을 수 있는가.
    /// 알림(확인·오류·완료 시트)이 떠 있거나 대기 중, 편집기 창에 시트가 붙어 있음, 앱 모달(저장·열기 패널 등)이 돌고 있으면 받지 않는다.
    /// 그 상태에서 저장·열기 패널을 runModal 하면 패널이 보이지 않고 곧바로 끝나거나(§24), 확인이 떠 있는 동안 프로젝트가 바뀌었다(CP-02의 한 계기).
    /// 창 초점만 잃은 것(다른 앱·다른 창이 앞에 있음)은 막지 않는다. 이어지는 흐름(저장 → 새 프로젝트·열기, 열기 확인 뒤의 열기 패널)은
    /// 이 확인을 거치지 않는 내부 경로라 막히지 않는다.
    var fileCommandsAvailable: Bool {
        alert == nil && panelsRunning == 0 && !alerts.isShowing && editorWindow?.attachedSheet == nil && NSApp.modalWindow == nil
    }
    /// 파일 명령 진입점에서 부른다. 받을 수 없으면 경고음과 상태 문구를 내고 true(아무것도 하지 않음).
    func fileCommandBlocked() -> Bool {
        guard !fileCommandsAvailable else { return false }
        NSSound.beep()
        statusMessage = "확인 창이나 패널이 열려 있는 동안에는 파일 명령을 쓸 수 없습니다. 닫은 뒤 다시 시도하세요."
        Self.trace.info("file command blocked (sheet/alert/modal)")
        return true
    }
    let alerts = AlertPresenter()
    /// 가져오기 진행(표시용). nil이면 진행 중인 가져오기 묶음이 없다.
    /// 가져오기 진행(2026-10-11: 현재 단계·시작 시각 추가 — 첫 파일 확인이 길어도 멈춘 것처럼 보이지 않게). 단계는 진행률이 아니다.
    struct ImportProgress: Equatable { let total: Int; var completed: Int; var currentName: String?; var cancelling = false
                                       var stage: String? = nil; var startedAt: Double = 0
        /// 전체 진행률(2026-10-11): 처리한 파일(받아들임·거부 모두) ÷ 전체. 묶음 반영 전에는 1.0이 되지 않는다
        /// (마지막 파일을 처리해도 (n−1)/n에 머문다). 1.0은 반영에 성공한 뒤의 완료 카드(ImportDone)에서만 보인다.
        /// 파일 하나의 진행률은 믿을 만하게 잴 수 없어(검사 단계만 있고 전체 샘플 수를 모름) 넣지 않는다. 시계로 꾸미지 않는다.
        var fraction: Double { total > 0 ? Double(min(completed, total - 1)) / Double(total) : 0 }
    }
    /// 가져오기 완료(2026-10-11): 묶음을 반영하고 하나 이상 추가했을 때만. 100%를 보이는 유일한 상태다.
    /// 취소·창 닫기·버리기·모두 거부(추가 0)에는 만들지 않는다. 잠깐 보인 뒤 사라지고, 다른 작업이 시작되면 바로 사라진다.
    struct ImportDone: Equatable { let total: Int; let added: Int; let rejected: Int; let skipped: Int; let elapsed: Double }
    private(set) var importDone: ImportDone?
    @ObservationIgnored private var importDoneToken = 0
    static let importDoneSeconds = 1.2
    /// 프로젝트 열기 진행(2026-10-11): 파일 읽기 → 원본 확인(k/n, 현재 원본 이름·검사 단계). 취소하면 현재 프로젝트 그대로.
    struct OpenProgress: Equatable { var stage: String; var completed = 0; var total = 0; var currentName: String?; var cancelling = false; var startedAt: Double = 0 }
    private(set) var openProgress: OpenProgress?
    /// 열기 요청부터 끝(적용·실패·취소)까지(2026-10-11 리뷰): 그동안 가져오기·내보내기를 시작하지 않고 대기열에 둔다.
    /// openProgress는 열기 작업이 실제로 시작될 때에야 생겨, Finder에서 프로젝트와 미디어를 함께 열면 가져오기가 먼저 시작돼 이전 프로젝트에 들어갔다.
    private(set) var openRequested = false
    private func endOpenRequest() { openRequested = false; runNextOp() }
    @ObservationIgnored private var openTask: Task<Void, Never>?
    /// 열기 회차. 취소마다 1 늘고, 이전 회차의 늦은 결과는 버린다.
    @ObservationIgnored private var openEpoch = 0
    #if DEBUG
    /// 자체 검사 전용: 열기·가져오기 패널 대신 고른 파일(메뉴 동작 → 요청 → 확인 → 열기 경로는 그대로)
    @ObservationIgnored var openPanelOverrideForTest: (() -> URL?)?
    @ObservationIgnored var importPanelOverrideForTest: (() -> [URL]?)?
    /// 자체 검사 전용: 내보내기 저장 패널 대신 부른다(패널을 띄우려 했는지만 기록, 내보내기는 시작하지 않음)
    @ObservationIgnored var exportPanelOverrideForTest: (() -> Void)?
    /// 자체 검사 전용: 원본 확인 전에 기다릴 시간(취소 검사가 빨리 끝나는 확인 사이에 끼어들 수 있게. 일반 실행에서는 0)
    @ObservationIgnored var probeDelayForTest: UInt64 = 0
    /// 자체 검사 전용: 실제 저장·열기 패널을 runModal 하기 직전에 넘긴다(패널이 실제로 보이는지 관찰·조작, OpenFlowSelfTest)
    @ObservationIgnored var panelWillRunForTest: ((NSSavePanel) -> Void)?
    #endif
    /// 진단 기록(2026-10-11): 가져오기·열기 단계와 걸린 시간. 경로·파일 이름·북마크는 남기지 않는다(파일 번호만).
    static let trace = Logger(subsystem: "dev.ontheframe.app", category: "trace")
    private(set) var importProgress: ImportProgress?
    /// 아직 결과가 나지 않은 파일 수(진행 중 묶음의 남은 파일 + 대기 중 묶음). 검사·자체 검사용.
    var importing: Int { (importProgress.map { $0.total - $0.completed } ?? 0) + pendingOps.reduce(0) { if case .importFiles(let u) = $1 { return $0 + u.count }; return $0 } }
    /// 가져오기·내보내기는 겹치지 않게 차례로 한다(카드 하나, 같은 미디어 목록을 동시에 바꾸지 않음). 진행 중이면 대기열에 넣는다.
    enum PendingOp { case importFiles([URL]), export(ExportDestination) }
    private(set) var pendingOps: [PendingOp] = []
    @ObservationIgnored private var importTask: Task<Void, Never>?
    /// 가져오기 회차. 취소·버리기마다 1 늘고, 이전 회차의 늦은 결과는 버린다.
    @ObservationIgnored private var importEpoch = 0

    struct AlertInfo: Identifiable {
        let id = UUID(); let title: String; let message: String; var revealURL: URL? = nil
        /// 지정하면 이 단추들과 처리기를 쓴다(buttons[0]이 기본 단추)
        var buttons: [String]? = nil; var destructiveIndex: Int? = nil; var cancelIndex: Int? = nil; var bringToFront = false; var onButton: (@MainActor (Int) -> Void)? = nil
        /// 내보내기 완료(검증·승격 성공 뒤에만): 완료 시트로 보인다(파일 이름, "걸린 시간 MM:SS")
        var completion: (fileName: String, detail: String)? = nil
    }

    enum ExportPhase: Equatable { case idle, running(Double) }
    private(set) var exportPhase: ExportPhase = .idle
    /// 내보내기 시간 표시(단조 시계 ContinuousClock 기준 초). 시스템 시계 변경과 무관하다.
    @ObservationIgnored private let monoClock = ContinuousClock()
    @ObservationIgnored private lazy var monoBase = monoClock.now
    func monoSeconds() -> Double {
        let c = (monoClock.now - monoBase).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
    /// 현재 내보내기의 경과·남은 시간 추정(내보내기마다 새로 시작)
    private(set) var exportEstimator = ExportTimeEstimator()
    private(set) var exportCancelling = false
    /// 마지막으로 끝난 내보내기의 경과 시간(성공·실패·취소 모두, 끝난 시점에 멈춤)
    private(set) var lastExportElapsed: Double?
    private var exportTask: Task<Void, Never>?
    /// 시험용 내보내기 선택 사항(Debug 자체 검사만 바꾼다)
    var exportOptions = ExportService.Options()

    let player = AVPlayer()
    /// 프리뷰 재구성 세대. 편집마다 1 늘고, 마지막 세대의 결과만 적용한다.
    private(set) var generation = 0
    /// 프리뷰에 적용된 세대(재구성·탐색까지 끝난 것)
    private(set) var appliedGeneration = 0
    #if DEBUG
    /// 자체 검사 전용: 세대별 적용 전 지연(오래된 재구성이 늦게 끝나는 경우를 일부러 만든다)
    @ObservationIgnored var testRebuildDelay: [Int: UInt64] = [:]
    /// 자체 검사 전용: 버린 오래된 재구성 수
    private(set) var staleRebuildsDropped = 0
    #endif
    private(set) var currentPlan: PlannedComposition?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var sleepAssertion: IOPMAssertionID = 0
    /// 드래그 시작 시점의 타임라인(트림·이동 미리 보기 계산 기준)
    private(set) var gestureBase: Timeline?
    /// 끼워 넣기 이동이 거부된 이유(놓을 때 상태 줄에 보인다)
    @ObservationIgnored private var moveRejection: EditError?
    /// 이동 드래그 중 끼워 넣을 자리(표시용)
    private(set) var moveInsertionIndex: Int?

    init() {
        player.actionAtItemEnd = .pause
        loadRecents()
        timeObserver = player.addPeriodicTimeObserver(forInterval: settings.frameDuration, queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.playhead = min(self.settings.frame(containing: t), self.timeline.durationFrames)
            }
        }
    }

    // MARK: 단축키 경로(KeyRouting)

    /// 편집기 창(약한 참조, 관찰 대상 아님)
    @ObservationIgnored private(set) weak var editorWindow: NSWindow?
    /// 메뉴 항목 사용 가능 상태용: 편집기 창이 키 창이고 텍스트 입력에 초점이 없는가
    private(set) var editorFocused = false
    @ObservationIgnored private var focusObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var responderKVO: NSKeyValueObservation?
    @ObservationIgnored private var keyMonitor: Any?

    func attachEditorWindow(_ w: NSWindow) {
        guard editorWindow !== w else { return }
        editorWindow = w
        EditorLayout.shared.attach(w)   // 처음 70% 가운데 또는 마지막 보통 창 되살리기(A-012)
        alerts.windowProvider = { [weak self] in self?.editorWindow }
        if wantsEditorVisible { w.makeKeyAndOrderFront(nil) }
        // 창 닫기 보호: SwiftUI의 창 대리자를 감싸 windowShouldClose만 가로채고 나머지는 원래 대리자에 넘긴다
        let g = WindowCloseGuard(original: w.delegate)
        closeGuard = g
        w.delegate = g
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFocus() }
            }
        }
        // 끌기 중단(D-031): 편집기 창이 키 상태를 잃거나 앱이 비활성이 되면 진행 중인 끌기를 취소한다(놓기 이벤트를 받지 못할 수 있으므로).
        // 포인터가 타임라인·창 밖으로 나가는 것만으로는 취소하지 않는다(보통 끌기는 창 밖에서도 놓을 수 있다).
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptGesture(reason: "editorResignKey", clearViewDrags: true) }
        })
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptGesture(reason: "appResignActive", clearViewDrags: true) }
        })
        #if DEBUG
        // 끌기 진단(Debug 전용, CP-01): 앱 활성·편집기 창 키 상태가 돌아온 때와, 왼쪽 버튼을 누른 채 ⌘가 바뀐 때(⌘Tab 전환 화면과 실제 비활성 구분)
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.traceGestureDebug("lifecycle appBecomeActive") }
        })
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.traceGestureDebug("lifecycle editorBecomeKey") }
        })
        if flagsMonitorForDebug == nil {
            flagsMonitorForDebug = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
                let ev = UncheckedEvent(e)
                MainActor.assumeIsolated {
                    let cmd = ev.e.modifierFlags.contains(.command)
                    let s = ProjectStore.shared
                    if cmd != s.commandDownForDebug {
                        s.commandDownForDebug = cmd
                        if (NSEvent.pressedMouseButtons & 1) != 0 { s.traceGestureDebug("key command\(cmd ? "Down" : "Up") whileLeftButtonHeld", event: ev.e) }
                    }
                }
                return e
            }
        }
        #endif
        responderKVO = w.observe(\.firstResponder, options: [.new]) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { ProjectStore.shared.refreshFocus() } }
        }
        if keyMonitor == nil {
            // 1차 처리: 로컬 키 감시(주 스레드에서 불림). 소비했으면 nil. 보조 처리 층은 KeyRouting 설명 참조.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                let ev = UncheckedEvent(e)
                let consumed = MainActor.assumeIsolated {
                    KeyRouting.route(ev.e, layer: "localMonitor", store: ProjectStore.shared)
                }
                return consumed ? nil : e
            }
        }
        refreshFocus()
    }
    func refreshFocus() {
        let f = KeyRouting.editorAcceptsShortcuts(self)
        if f != editorFocused { editorFocused = f }
    }

    var canPlay: Bool { !timeline.isEmpty && player.currentItem != nil }
    var canSplit: Bool { !timeline.isEmpty && editorFocused && alert == nil && gestureBase == nil }

    /// ⌘Z: 편집기에 초점이 있으면 타임라인 실행 취소, 텍스트 입력·다른 창이면 응답자 체인(표준 텍스트 실행 취소)
    func menuUndo() {
        KeyTrace.note("menuAction=undo currentEventCode=\(NSApp.currentEvent?.keyCode ?? 0) type=\(NSApp.currentEvent?.type.rawValue ?? 0)")
        if KeyRouting.menuTargetsEditor(self) { undo() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
    }
    func menuRedo() {
        if KeyRouting.menuTargetsEditor(self) { redo() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
    }
    /// ⌘K: 편집기에 초점이 있을 때만(텍스트 입력·시트·드래그 중에는 하지 않음)
    func menuSplit() {
        KeyTrace.note("menuAction=split currentEventCode=\(NSApp.currentEvent?.keyCode ?? 0) type=\(NSApp.currentEvent?.type.rawValue ?? 0)")
        guard KeyRouting.menuTargetsEditor(self), gestureBase == nil else { return }
        splitAtPlayhead()
    }
    var undoMenuEnabled: Bool { !editorFocused || (history.canUndo && alert == nil) }
    var redoMenuEnabled: Bool { !editorFocused || (history.canRedo && alert == nil) }

    var mediaByID: [UUID: MediaAsset] { Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }) }
    var durationFrames: Int { timeline.durationFrames }
    var canExport: Bool { !timeline.isEmpty && exportPhase == .idle && importProgress == nil && pendingOps.isEmpty && exportBlockReason == nil && openProgress == nil && !openRequested }

    // MARK: 가져오기

    /// 한 번에 고른 파일 묶음을 가져온다(A-011).
    /// - 파일을 고른 순서대로 하나씩 검사하고, 카드에 현재 파일 이름과 끝난 수/전체 수를 보인다. 파일 안의 진행률은 알 수 없어
    ///   막대는 진행률 없는 형태다. 검사가 끝난 파일만 "끝남"으로 센다.
    /// - 묶음 반영: 받은 파일은 묶음이 모두 끝난 뒤 고른 순서대로 한꺼번에 목록에 들어간다. 거부 이유는 알림 하나로 모은다.
    /// - 취소: 남은 파일은 검사하지 않고, 검사 중인 파일은 읽기를 멈춘다. 이번 묶음에서 이미 검사를 마친 파일도 목록에 넣지 않는다
    ///   (묶음 반영 전이므로). 앞서 가져온 영상과 편집은 그대로다. 대기 중인 가져오기 묶음도 함께 버린다.
    /// - 취소·버리기·창 닫기 뒤에 도착한 결과는 회차 번호로 버린다.
    /// - 내보내는 중이면 끝난 뒤 시작한다(대기열).
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !discardConfirmed, !editorClosedByUser else { return }
        pendingOps.append(.importFiles(urls))
        runNextOp()
    }

    /// 대기열에서 다음 작업을 시작한다(가져오기·내보내기 중 하나만 진행).
    private func runNextOp() {
        guard openProgress == nil, !openRequested, importProgress == nil, importTask == nil, exportPhase == .idle, exportTask == nil, !pendingOps.isEmpty else { return }
        clearImportDone()
        switch pendingOps.removeFirst() {
        case .importFiles(let urls): runImport(urls)
        case .export(let d): beginExport(d)
        }
    }

    private func runImport(_ urls: [URL]) {
        let epoch = importEpoch, s = settings, t0 = monoSeconds()
        clearImportDone()
        importProgress = ImportProgress(total: urls.count, completed: 0, currentName: urls.first?.lastPathComponent, startedAt: t0)
        Self.trace.info("import start files=\(urls.count, privacy: .public)")
        importTask = Task { [weak self] in
            var results: [(URL, Result<MediaAsset, Error>)] = []
            for (i, url) in urls.enumerated() {
                guard let self, self.importEpoch == epoch, !Task.isCancelled else { break }
                self.importProgress?.currentName = url.lastPathComponent
                self.importProgress?.stage = nil
                let f0 = self.monoSeconds()
                #if DEBUG
                if self.probeDelayForTest > 0 { try? await Task.sleep(nanoseconds: self.probeDelayForTest) }
                #endif
                let r: Result<MediaAsset, Error>
                do {
                    r = .success(try await MediaProbe.inspect(url, settings: s) { st in
                        Task { @MainActor [weak self] in self?.importStage(epoch: epoch, file: i, st, since: f0) }
                    })
                } catch { r = .failure(error) }
                guard self.importEpoch == epoch, !Task.isCancelled else {   // 취소 뒤 늦게 끝난 검사 결과는 버린다
                    Self.trace.info("import file#\(i + 1, privacy: .public) result dropped (cancelled) after \(self.monoSeconds() - f0, format: .fixed(precision: 3), privacy: .public)s")
                    break
                }
                Self.trace.info("import file#\(i + 1, privacy: .public) \({ if case .success = r { return "ok" } else { return "rejected" } }(), privacy: .public) in \(self.monoSeconds() - f0, format: .fixed(precision: 3), privacy: .public)s")
                results.append((url, r))
                self.importProgress?.completed += 1
            }
            if let self { Self.trace.info("import end epochMatch=\(self.importEpoch == epoch, privacy: .public) results=\(results.count, privacy: .public)/\(urls.count, privacy: .public) total \(self.monoSeconds() - t0, format: .fixed(precision: 3), privacy: .public)s") }
            self?.finishImport(epoch: epoch, total: urls.count, results: results)
        }
    }
    /// 검사 단계(표시·진단). 다른 회차·끝난 가져오기의 늦은 단계 알림은 버린다.
    private func importStage(epoch: Int, file i: Int, _ st: MediaProbe.Stage, since f0: Double) {
        guard epoch == importEpoch, importProgress != nil, importProgress?.completed == i else { return }
        importProgress?.stage = st.label
        if case .scanningFrames(let n) = st, n > 0 { return }   // 중간 개수는 기록하지 않는다
        Self.trace.info("import file#\(i + 1, privacy: .public) stage \(Self.stageName(st), privacy: .public) at \(self.monoSeconds() - f0, format: .fixed(precision: 3), privacy: .public)s")
    }
    static func stageName(_ st: MediaProbe.Stage) -> String {
        switch st { case .opening: return "open"; case .checkingFormat: return "format"; case .scanningFrames(let n): return "scan\(n)"; case .finished: return "done" }
    }

    private func finishImport(epoch: Int, total: Int, results: [(URL, Result<MediaAsset, Error>)]) {
        importTask = nil
        let startedAt = importProgress?.startedAt
        importProgress = nil
        defer { runNextOp() }
        // 취소·버리기·창 닫기 뒤: 아무것도 반영하지 않는다
        guard epoch == importEpoch, results.count == total, !discardConfirmed, !editorClosedByUser else {
            if !discardConfirmed && !editorClosedByUser { statusMessage = "가져오기를 취소했습니다. 이번에 고른 파일은 추가하지 않았습니다." }
            return
        }
        var rejected: [String] = [], added = 0, skipped = 0
        for (url, r) in results {   // 고른 순서대로 목록에 넣는다
            switch r {
            case .success(let a):
                if assets.contains(where: { $0.identity.sameFile(as: a.identity) }) {
                    statusMessage = "이미 가져온 파일입니다: \(url.lastPathComponent)"; skipped += 1; continue
                }
                // 가져오기는 실행 취소로 사라지지 않는다(모든 단계에 등록). 프로젝트 변경이라 저장하지 않은 상태가 된다.
                assetCache[a.url.standardizedFileURL.path] = a
                history.mapAll { $0.registering(a) }
                // 끌기 중이면 저장소의 끌기 시작 상태도 같이(끌기 갱신·놓기가 이 미디어를 지우지 않게, 2026-10-11 리뷰)
                gestureBase = gestureBase?.registering(a); gestureTimeline = gestureTimeline?.registering(a)
                refreshAssets()
                added += 1
                Self.log.info("imported media frames=\(a.frameCount) timing=\(a.timing.detail, privacy: .public)")
            case .failure(let e):
                rejected.append("\(url.lastPathComponent): \((e as? ProbeError)?.description ?? e.localizedDescription)")
            }
        }
        if !rejected.isEmpty { presentAlert(AlertInfo(title: Self.rejectTitle, message: rejected.joined(separator: "\n\n"))) }
        // 반영에 성공하고 하나 이상 추가했을 때만 100% 완료 카드(다음 작업이 대기 중이면 runNextOp가 바로 지운다)
        if added > 0 {
            importDoneToken += 1
            let token = importDoneToken
            importDone = ImportDone(total: total, added: added, rejected: rejected.count, skipped: skipped, elapsed: monoSeconds() - (startedAt ?? monoSeconds()))
            Self.trace.info("import applied added=\(added, privacy: .public) rejected=\(rejected.count, privacy: .public) skipped=\(skipped, privacy: .public)")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.importDoneSeconds * 1_000_000_000))
                if let self, self.importDoneToken == token { self.importDone = nil }
            }
        }
    }
    /// 완료 카드를 지운다(다음 가져오기·내보내기·열기 시작, 버리기).
    func clearImportDone() { importDoneToken += 1; importDone = nil }

    /// 가져오기 취소(진행 중 묶음과 대기 중 가져오기 묶음). 결과는 버리고, 카드는 검사가 멈출 때까지 "취소하는 중"을 보인다.
    func cancelImport() {
        pendingOps.removeAll { if case .importFiles = $0 { return true }; return false }
        guard importTask != nil else { return }
        importEpoch += 1
        importProgress?.cancelling = true
        importTask?.cancel()
    }
    static let rejectTitle = "가져올 수 없는 파일"

    /// 알림 표시: 떠 있는 알림이 있으면 대기열에 넣고, 사용자가 닫은 뒤 차례로 띄운다.
    func presentAlert(_ a: AlertInfo) {
        let buttons = a.buttons ?? (a.revealURL == nil ? ["확인"] : ["Finder에서 보기", "닫기"])
        let req = AlertPresenter.Request(title: a.title, message: a.message, buttons: buttons, destructiveIndex: a.destructiveIndex, cancelIndex: a.cancelIndex, bringToFront: a.bringToFront,
                                         completion: a.completion) { [weak self] i in
            if a.buttons == nil, i == 0, let u = a.revealURL { self?.reveal(u) }
            self?.shownAlerts.removeFirst()
            self?.alert = self?.shownAlerts.first
            a.onButton?(i)
        }
        shownAlerts.append(a)
        if alert == nil { alert = a }
        alerts.enqueue(req)
    }
    private func reveal(_ u: URL) {
        #if DEBUG
        if let h = revealOverrideForTest { h(u); return }   // 자체 검사: Finder 창을 실제로 열지 않고 기록
        #endif
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }
    #if DEBUG
    @ObservationIgnored var revealOverrideForTest: ((URL) -> Void)?
    #endif
    /// 표시 중·대기 중 알림 사본(순서대로). 첫 항목이 화면에 떠 있는 알림이다.
    private var shownAlerts: [AlertInfo] = []

    func presentImportPanel() {
        guard !fileCommandBlocked() else { return }
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.movie, .audio]
        p.message = "가져올 영상 또는 오디오 파일을 선택하세요."   // 지원 형식·제한은 도움말(README)과 거부 알림에 둔다
        #if DEBUG
        if let o = importPanelOverrideForTest { if let urls = o() { importFiles(urls) }; return }
        #endif
        if runPanel(p) == .OK { importFiles(p.urls) }
    }

    // MARK: 편집(실행 취소 대상)

    /// rebuild가 false면 프리뷰 재구성은 부르는 쪽이 맡는다(변형 편집의 정지 화면 경로)
    /// 끌기 중(gestureBase가 있음)에는 아무것도 하지 않는다: 끌기 기준과 기록이 어긋나지 않게 하고, 기록의 끌기 중 확인(precondition)에 닿지 않게 한다
    /// (CP-01, 2026-10-11: 끌기 중 문맥 메뉴·끝나지 않은 끌기에서 부른 편집이 앱을 멈췄다). 끌기는 놓기(한 단계)나 Esc(취소)로만 끝난다.
    private func commit(_ make: (Timeline) throws -> Timeline, focus: UUID?, select: UUID? = nil, rebuild: Bool = true) {
        guard gestureBase == nil else { return }
        pauseForEdit()
        do {
            let t = try make(timeline)
            history.apply(t, focus: focus)
            selection = select ?? focus
            linkCandidate = nil
            statusMessage = nil
            if rebuild { timelineChanged() } else { updateWindowDocumentState() }
        } catch let e as EditError {
            statusMessage = e.description
        } catch { statusMessage = error.localizedDescription }
    }

    /// 목록의 + 단추(2026-10-11): 고른 대상 레인(쌍)의 마지막으로 차지한 끝 뒤에 놓는다(리플 없음, 재생 헤드와 무관).
    /// 대상 레인이 비었으면(빈 타임라인의 첫 추가 포함) 0에서 시작한다. 기존 빈틈은 그대로 둔다.
    func addToTimeline(_ mediaID: UUID) {
        guard let ref = timeline.media.first(where: { $0.id == mediaID }) else { return }
        let d = addDestination(hasVideo: ref.hasVideo, hasAudio: ref.hasAudio)
        let cid = UUID()
        commit({ try $0.appending(media: mediaID, videoLane: d.video, audioLane: d.audio, clipID: cid) }, focus: cid)
    }
    /// + 단추의 대상: 레인 머리에서 고른 레인이 있으면 그 레인과 같은 번호의 짝(V2 ↔ A2, 짝이 없으면 기본 레인), 없으면 V1·A1.
    func addDestination(hasVideo: Bool, hasAudio: Bool) -> (video: UUID?, audio: UUID?) {
        let t = timeline, chosen = selectedLane.flatMap { t.laneInfo($0) }
        var v: UUID? = nil, a: UUID? = nil
        if hasVideo {
            v = chosen?.kind == .video ? chosen?.id : (chosen.flatMap { t.pairedLane(of: $0.id)?.id } ?? t.baseLane(.video)?.id)
        }
        if hasAudio {
            if chosen?.kind == .audio { a = chosen?.id }
            else { a = v.flatMap { t.pairedLane(of: $0)?.id } ?? t.baseLane(.audio)?.id }
        }
        return (v, a)
    }

    /// 분할: 선택한 클립(없으면 재생 헤드 아래 영상, 없으면 소리 클립)을 재생 헤드에서 나눈다. 연결된 짝도 함께.
    func splitAtPlayhead() {
        let target = selection ?? timeline.clipIndex(atFrame: playhead).map { timeline.clips[$0].id }
            ?? timeline.audioClipIndex(atFrame: playhead).map { timeline.audioClips[$0].id }
        guard let id = target else { statusMessage = "나눌 클립이 없습니다."; return }
        let right = UUID()
        commit({ try $0.splitting(clip: id, atFrame: playhead, newIDs: (UUID(), right)) }, focus: right)
    }

    /// 선택한 클립 삭제(D-020). ripple이 false면 빈틈을 남기고(다른 클립 위치·길이 그대로), true면 그 구간을 지우고 뒤를 당긴다.
    func deleteSelection(ripple: Bool = false) {
        guard let id = selection else { return }
        commit({ try ripple ? $0.rippleDeleting(clip: id) : $0.lifting(clip: id) }, focus: nil)
    }

    func undo() {
        guard history.canUndo else { return }
        pauseForEdit()
        let f = history.undo()
        selection = f.flatMap { timeline.clip($0) != nil ? $0 : nil }
        timelineChanged()
    }
    func redo() {
        guard history.canRedo else { return }
        pauseForEdit()
        let f = history.redo()
        selection = f.flatMap { timeline.clip($0) != nil ? $0 : nil }
        timelineChanged()
    }

    // MARK: 연결·레인 이름(A-012)

    /// 클릭 선택. extend(⌘-클릭)이면 다른 레인의 클립을 연결 후보로 더하거나 뺀다.
    func select(_ id: UUID?, extend: Bool = false) {
        guard extend, let id, let sel = selection, sel != id else { selection = id; if id != nil { selectedLane = nil }; return }
        if timeline.group(of: sel).contains(where: { $0.id == id }) { return }
        linkCandidate = linkCandidate == id ? nil : id
    }
    /// 연결 가능: 주 선택과 후보가 연결되지 않은 같은 원본의 영상·소리 클립
    var canLink: Bool {
        guard let a = selection, let b = linkCandidate else { return false }
        return (try? timeline.linking(a, b)) != nil
    }
    var canUnlink: Bool { selection.flatMap { timeline.partner(of: $0) } != nil }
    func linkSelection() {
        guard let a = selection else { return }
        guard let b = linkCandidate else { statusMessage = EditError.linkNeedsPair.description; return }
        commit({ try $0.linking(a, b) }, focus: a)
    }
    func unlinkSelection() {
        guard let a = selection else { return }
        commit({ try $0.unlinking(clip: a) }, focus: a)
    }
    /// 레인 이름 바꾸기(실행 취소 한 단계). 비었거나 같으면 바꾸지 않는다(이전 이름 유지). 바꿨으면 true.
    @discardableResult
    func renameLane(_ id: UUID, to name: String) -> Bool {
        guard gestureBase == nil else { return false }   // 끌기 중에는 기록을 바꾸지 않는다(CP-01)
        let old = timeline.lanes.first { $0.id == id }?.name
        do {
            let t = try timeline.renamingLane(id, to: name)
            guard t.lanes.first(where: { $0.id == id })?.name != old else { return false }
            history.apply(t, focus: selection)
            statusMessage = nil
            return true
        } catch let e as EditError { statusMessage = e.description; return false } catch { return false }
    }

    // MARK: 레인(A-014)

    /// 레인 머리에서 고른 레인(정보 패널에 레인 설정을 보인다). 클립을 고르면 그 클립의 레인을 보인다.
    var selectedLane: UUID?
    /// 정보 패널이 보일 레인: 고른 레인, 없으면 선택한 클립의 레인
    var inspectedLane: Lane? {
        if let l = selectedLane, let lane = timeline.laneInfo(l) { return lane }
        return selection.flatMap { timeline.laneID(of: $0) }.flatMap { timeline.laneInfo($0) }
    }
    func selectLane(_ id: UUID?) { selectedLane = id; if id != nil { selection = nil } }
    /// 레인 편집(실행 취소 한 단계). 편집 중(드래그)에는 하지 않는다.
    private func commitLane(_ make: (Timeline) throws -> Timeline, select lane: UUID? = nil) {
        guard gestureBase == nil else { return }
        pauseForEdit()
        do {
            let t = try make(timeline)
            guard t != timeline else { return }
            history.apply(t, focus: selection)
            if let lane { selectedLane = lane }
            if let l = selectedLane, t.laneInfo(l) == nil { selectedLane = nil }
            if let s = selection, t.clip(s) == nil { selection = nil }
            statusMessage = nil
            timelineChanged()
        } catch let e as EditError { statusMessage = e.description } catch { statusMessage = error.localizedDescription }
    }
    /// 새 레인의 기본 이름: "영상"·"오디오". 번호(V2·A2)는 위치에서 따로 보이므로 이름에 넣지 않는다(순서를 바꿔도 어긋나지 않게).
    func newLaneName(_ kind: LaneKind) -> String { kind == .video ? "영상" : "오디오" }

    // MARK: 복사·붙여넣기(2026-10-11)

    /// 앱 안 클립 클립보드: 복사한 프로젝트 ID, 내용(클립 값), 복사할 때 고른 클립. 시스템 클립보드와 따로다(텍스트 복사·붙여넣기는 그대로).
    /// 프로젝트를 바꾸면(새 프로젝트·열기) 비운다. 다른 프로젝트의 미디어 ID는 쓰지 않는다(붙여넣기 때 이 프로젝트 ID와 미디어로 다시 확인).
    struct ClipClipboard: Equatable { let project: UUID; let content: ClipboardContent; let selected: UUID }
    private(set) var clipClipboard: ClipClipboard?
    var canCopy: Bool { selection.flatMap { timeline.clip($0) } != nil && gestureBase == nil }
    var canPaste: Bool { clipClipboard?.project == projectID && gestureBase == nil && openProgress == nil && !openRequested }
    /// 복사(⌘C): 고른 클립과 연결된 짝. 프로젝트를 바꾸지 않고 실행 취소 기록도 없다.
    func copySelection() {
        guard gestureBase == nil, let id = selection, let c = try? timeline.copying(clip: id) else { statusMessage = "복사할 클립을 먼저 고르세요."; return }
        clipClipboard = ClipClipboard(project: projectID, content: c, selected: id)
        statusMessage = c.all.count > 1 ? "연결된 클립 \(c.all.count)개를 복사했습니다." : "클립을 복사했습니다."
    }
    /// 붙여넣기(⌘V): 재생 헤드에 복사한 묶음의 가장 이른 시작을 둔다. 한 단계(필요한 새 레인 포함). 붙여 넣은 클립(복사할 때 고른 클립의 복제)을 고른다.
    func pasteAtPlayhead() {
        guard gestureBase == nil, openProgress == nil, !openRequested else { return }
        guard let cb = clipClipboard, cb.project == projectID else { statusMessage = EditError.clipboardEmpty.description; return }
        pauseForEdit()
        do {
            let r = try timeline.pasting(cb.content, at: playhead, newLaneName: newLaneName)
            let focus = r.ids[cb.selected]
            history.apply(r.timeline, focus: focus)
            selection = focus
            linkCandidate = nil
            statusMessage = r.createdLanes.isEmpty ? nil : "겹치지 않도록 새 레인 \(r.createdLanes.count)개에 붙여 넣었습니다."
            timelineChanged()
        } catch let e as EditError {
            statusMessage = e.description
        } catch { statusMessage = error.localizedDescription }
    }
    /// 메뉴 "복사하기"·"붙여넣기": 편집기에 초점이 있으면 클립, 텍스트 입력·다른 창이면 응답자 체인(표준 텍스트 복사·붙여넣기)
    func menuCopy() {
        if KeyRouting.menuTargetsEditor(self) { if canCopy { copySelection() } else { NSSound.beep() } }
        else { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
    }
    func menuPaste() {
        if KeyRouting.menuTargetsEditor(self) { if canPaste { pasteAtPlayhead() } else { NSSound.beep(); if clipClipboard == nil { statusMessage = EditError.clipboardEmpty.description } } }
        else { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
    }
    // MARK: 편집 도구(2026-10-11, D-030): 선택(V)·자르기(C)

    /// 타임라인 편집 도구. 앱을 열 때 선택 도구이고, 새 프로젝트·열기에서도 그대로이며 프로젝트 파일에 저장하지 않는다.
    enum EditTool: Equatable { case selection, cut }
    private(set) var tool: EditTool = .selection
    /// 도구 바꾸기(키·툴바·메뉴 모두 이 길). 끌기 중이면 바꾸지 않는다. 재생·재생 헤드·선택·타임라인·기록·저장 상태는 그대로다.
    @discardableResult func setTool(_ t: EditTool) -> Bool {
        guard gestureBase == nil else { return false }
        if tool != t { tool = t }
        return true
    }
    /// 자르기 도구 판정(안내선과 실제 자르기가 같은 판정을 쓴다): 기존 분할 규칙(연결된 짝도 같은 원본 위치)으로 자를 수 있는가
    enum CutCheck: Equatable { case valid, rejected, linkedOutside }
    func cutCheck(_ id: UUID, atFrame f: Int) -> CutCheck {
        do { _ = try timeline.splitting(clip: id, atFrame: f); return .valid }
        catch EditError.linkedSplitOutside { return .linkedOutside }
        catch { return .rejected }
    }
    /// 자르기 도구로 클립을 누름: 재생을 멈추고 누른 클립(과 연결된 짝)을 그 프레임에서 한 번 자른다(기존 commit·분할 경로, 한 단계,
    /// 오른쪽 조각 선택, 재생 헤드 그대로). 경계·클립 밖은 조용히 무시하고, 짝이 그 위치를 덮지 않으면 상태 줄에 이유만 보인다.
    /// 거부되면 타임라인·선택·기록·저장 상태가 그대로다. 끌기 중에는 아무것도 하지 않는다(commit에 닿기 전 국소 보호).
    func cutClip(_ id: UUID, atFrame f: Int) {
        guard gestureBase == nil, timeline.clip(id) != nil else { return }
        pauseForEdit()
        switch cutCheck(id, atFrame: f) {
        case .valid:
            let right = UUID()
            commit({ try $0.splitting(clip: id, atFrame: f, newIDs: (UUID(), right)) }, focus: right)
        case .linkedOutside:
            statusMessage = EditError.linkedSplitOutside.description
        case .rejected:
            break
        }
    }

    /// 레인 추가: 경계에서 바깥쪽 끝(영상은 맨 위 새 Vn, 오디오는 맨 아래 새 An)
    func addLane(_ kind: LaneKind) {
        let id = UUID()
        commitLane({ try $0.addingLane(kind, name: newLaneName(kind), id: id, outward: true) }, select: id)
    }
    /// 영상·소리 레인 쌍 추가(한 단계): 새 영상 레인은 맨 위, 새 오디오 레인은 맨 아래
    func addLanePair() {
        let v = UUID(), a = UUID()
        commitLane({ try $0.addingLane(.video, name: newLaneName(.video), id: v, outward: true)
                          .addingLane(.audio, name: newLaneName(.audio), id: a, outward: true) }, select: v)
    }
    /// 레인 순서(같은 종류 안에서 한 칸). 영상 레인 순서는 겹친 영상 중 무엇이 보이는지를 바꾼다.
    func moveLane(_ id: UUID, by step: Int) { commitLane({ try $0.movingLane(id, by: step) }) }
    func canMoveLane(_ id: UUID, by step: Int) -> Bool {
        guard let i = timeline.lanes.firstIndex(where: { $0.id == id }) else { return false }
        let j = i + step
        return timeline.lanes.indices.contains(j) && timeline.lanes[j].kind == timeline.lanes[i].kind
    }
    /// 레인 삭제. 클립이 있으면 확인한다(레인·클립 삭제와 짝 연결 해제가 한 단계). 그 종류의 마지막 레인은 지우지 않는다.
    func requestRemoveLane(_ id: UUID) {
        guard let lane = timeline.laneInfo(id), gestureBase == nil else { return }
        guard timeline.lanes(lane.kind).count > 1 else { statusMessage = EditError.lastLane.description; return }
        let inLane = timeline.clips(inLane: id)
        let n = inLane.count
        guard n > 0 else { commitLane({ try $0.removingLane(id) }); return }
        let request = LaneRemovalRequest(session: projectSession, lane: id, kind: lane.kind, clipIDs: Set(inLane.map(\.id)))
        let linked = timeline.clips(inLane: id).filter { $0.link != nil }.count
        var msg = "‘\(lane.name)’ 레인과 그 안의 클립 \(n)개를 지웁니다."
        if linked > 0 { msg += " 다른 레인에 있는 연결된 짝 \(linked)개는 지우지 않고 연결만 해제합니다." }
        msg += "\n\n실행 취소(⌘Z)로 되돌릴 수 있습니다. 원본 파일은 그대로입니다."
        presentAlert(AlertInfo(title: "레인을 삭제할까요?", message: msg, buttons: ["레인 삭제", "취소"], destructiveIndex: 0, cancelIndex: 1,
                               onButton: { [weak self] i in if i == 0 { self?.confirmRemoveLane(request) } }))
    }
    /// 레인 삭제 확인이 묶인 대상(CP-02): 확인을 띄운 프로젝트 회차, 레인, 그 종류, 확인 문구에 센 클립들
    struct LaneRemovalRequest: Equatable { let session: Int; let lane: UUID; let kind: LaneKind; let clipIDs: Set<UUID> }
    /// "레인 삭제"를 누른 때: 확인을 띄운 뒤 프로젝트가 바뀌었거나(같은 파일을 다시 연 경우 포함), 레인이 없어졌거나, 그 안의 클립이 확인 문구와
    /// 달라졌거나, 그 종류의 마지막 레인이 되었으면 아무것도 지우지 않는다(기록·저장 상태 그대로, 상태 문구만). 삭제했으면 true.
    @discardableResult
    func confirmRemoveLane(_ r: LaneRemovalRequest) -> Bool {
        guard r.session == projectSession, gestureBase == nil, let lane = timeline.laneInfo(r.lane), lane.kind == r.kind,
              Set(timeline.clips(inLane: r.lane).map(\.id)) == r.clipIDs, timeline.lanes(r.kind).count > 1 else {
            statusMessage = "확인한 뒤 프로젝트나 레인이 바뀌어 레인을 지우지 않았습니다."
            Self.trace.info("lane removal confirmation ignored (stale) sameSession=\(r.session == self.projectSession, privacy: .public)")
            return false
        }
        commitLane({ try $0.removingLane(r.lane) })
        return true
    }
    func setLaneMuted(_ id: UUID, _ muted: Bool) { commitLane({ try $0.settingLaneAudio(id, muted: muted) }) }
    /// 음량(0–100%). 슬라이더는 놓을 때 한 번 부른다(한 단계).
    func setLaneVolume(_ id: UUID, _ percent: Int) { commitLane({ try $0.settingLaneAudio(id, volumePercent: max(0, min(100, percent))) }) }

    // MARK: 소리 클립 음량·음소거·페이드(2026-10-11)

    /// 고른 클립의 소리 대상: 소리 클립이면 그 클립, 영상 클립이면 연결된 소리 클립(없으면 nil)
    var audioTargetClip: Clip? { selection.flatMap { timeline.audioTarget(of: $0) }.flatMap { timeline.clip($0) } }
    /// 소리 클립 설정(한 단계). 다른 클립·레인은 그대로다. 페이드는 프레임(1/30 s), 다른 쪽 페이드와 겹치지 않게 줄인다.
    func setClipAudio(_ id: UUID, volumePercent: Int? = nil, muted: Bool? = nil, fadeInFrames: Int? = nil, fadeOutFrames: Int? = nil) {
        guard gestureBase == nil else { return }
        let before = timeline
        commit({ try $0.settingClipAudio(clip: id, volumePercent: volumePercent.map { max(0, min(100, $0)) }, muted: muted,
                                         fadeInFrames: fadeInFrames.map { max(0, $0) }, fadeOutFrames: fadeOutFrames.map { max(0, $0) }) },
               focus: selection ?? id, rebuild: false)
        if timeline != before { timelineChanged() }
    }
    enum FadeEdge { case fadeIn, fadeOut }
    /// 타임라인 페이드 손잡이 끌기 중(beginGesture → updateFade… → commitGesture 한 단계, Esc는 cancelGesture).
    /// frames는 손잡이 위치에서 잰 페이드 길이(반올림한 프레임)이고 다른 쪽 페이드와 겹치지 않게 줄인다. 선택은 바꾸지 않는다.
    func updateFade(_ id: UUID, edge: FadeEdge, frames: Int) {
        guard let base = gestureBase, let t = try? base.settingClipAudio(clip: id, fadeInFrames: edge == .fadeIn ? max(0, frames) : nil,
                                                                       fadeOutFrames: edge == .fadeOut ? max(0, frames) : nil) else { return }
        history.updateGesture(t, focus: selection ?? id)
    }
    /// 페이드 손잡이 끌기 시작(선택은 그대로: 영상 클립을 골랐으면 연결된 소리의 페이드를 바꾼다)
    func beginFadeGesture() {
        interruptGesture()   // D-031
        pauseForEdit()
        history.beginGesture()
        gestureBase = timeline
        #if DEBUG
        gestureSerialForDebug += 1; traceGestureDebug("begin kind=fade")
        #endif
    }

    /// 끌어 놓기(A-014, 2026-10-11 갱신): 미디어를 고른 레인의 놓은 시각(frame)에 놓는다(한 단계, 리플·끼워 넣기 없음, 겹치면 거부).
    /// - 영상 레인에 영상 파일: 그 레인에. 연결된 소리는 같은 번호의 오디오 레인(V2 → A2)이 그 구간에서 비었으면 거기, 아니면 경계에서 가까운
    ///   빈 오디오 레인, 없으면 파일 이름의 새 오디오 레인(맨 아래)에.
    /// - 오디오 레인에 소리 파일: 그 레인에.
    /// - 레인 아래 빈 곳(lane nil): 파일 이름의 새 레인을 바깥쪽에 만든다. 소리가 있는 영상은 새 영상 레인(맨 위)과 새 오디오 레인(맨 아래)
    ///   쌍, 소리 없는 영상은 영상 레인만, 소리 파일은 오디오 레인만.
    func placeMedia(_ mediaID: UUID, atFrame f: Int, lane: UUID?) {
        guard let ref = timeline.media.first(where: { $0.id == mediaID }), let n = timeline.mediaFrames[mediaID] else { return }
        let name = (ref.name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces).isEmpty ? newLaneName(ref.hasVideo ? .video : .audio)
            : (ref.name as NSString).deletingPathExtension
        let start = max(0, f)
        let kind = lane.flatMap { timeline.laneInfo($0)?.kind }
        if ref.hasVideo {
            if kind == .audio { statusMessage = "영상 파일은 영상 레인에 놓으세요. 소리는 연결된 클립으로 오디오 레인에 함께 들어갑니다."; return }
            let cid = UUID()
            commit({ t in
                var t = t
                var vl = lane, al: UUID? = nil
                if vl == nil {
                    let id = UUID(); t = try t.addingLane(.video, name: name, id: id, outward: true); vl = id
                    if ref.hasAudio { let a = UUID(); t = try t.addingLane(.audio, name: name, id: a, outward: true); al = a }
                } else if ref.hasAudio, let v = vl {
                    al = Self.freeAudioLane(t, pairedWith: v, range: start..<(start + n))
                    if al == nil { let id = UUID(); t = try t.addingLane(.audio, name: name, id: id, outward: true); al = id }
                }
                return try t.placing(media: mediaID, at: start, videoLane: vl, audioLane: al, clipID: cid)
            }, focus: cid)
        } else {
            if kind == .video { statusMessage = "소리 파일은 오디오 레인에 놓거나, 레인 아래 빈 곳에 놓아 새 오디오 레인을 만드세요."; return }
            let cid = UUID()
            commit({ t in
                var t = t
                var al = lane
                if al == nil { let id = UUID(); t = try t.addingLane(.audio, name: name, id: id, outward: true); al = id }
                return try t.placing(media: mediaID, at: start, videoLane: nil, audioLane: al, clipID: cid)
            }, focus: cid)
        }
    }
    /// 연결된 소리를 놓을 오디오 레인: 같은 번호의 짝 레인이 그 구간에서 비었으면 그 레인, 아니면 경계에서 가까운 빈 오디오 레인
    static func freeAudioLane(_ t: Timeline, pairedWith v: UUID, range r: Range<Int>) -> UUID? {
        let free: (Lane) -> Bool = { l in !t.clips(inLane: l.id).contains { $0.start < r.upperBound && r.lowerBound < $0.end } }
        if let p = t.pairedLane(of: v), p.kind == .audio, free(p) { return p.id }
        return t.lanesFromBoundary(.audio).first(where: free)?.id
    }

    /// 선택한 클립(과 연결된 짝)을 다른 레인으로(정보 패널). 위치는 그대로, 겹치면 아무것도 옮기지 않는다(한 단계).
    func relocateSelection(lane: UUID?, partnerLane: UUID?) {
        guard let id = selection, gestureBase == nil else { return }
        commit({ try $0.relocating(clip: id, lane: lane, partnerLane: partnerLane) }, focus: id)
    }

    // MARK: 영상 크기·위치(A-015)

    /// 프리뷰에서 편집할 영상 클립: 선택한 영상 클립(소리 클립을 골랐으면 연결된 영상)이 재생 헤드 위치에 있을 때만.
    var overlayTarget: (clip: Clip, asset: MediaAsset)? {
        guard let sel = selection, let c0 = timeline.clip(sel) else { return nil }
        let c = timeline.lane(of: sel) == .video ? c0 : timeline.partner(of: sel)
        guard let c, timeline.lane(of: c.id) == .video, playhead >= c.start, playhead < c.end, missingMedia[c.mediaID] == nil,
              let a = mediaByID[c.mediaID] else { return nil }
        return (c, a)
    }
    /// 선택한 클립의 영상(정보 패널): 재생 헤드와 무관
    var transformClip: Clip? {
        guard let sel = selection else { return nil }
        if timeline.lane(of: sel) == .video { return timeline.clip(sel) }
        return timeline.partner(of: sel).flatMap { timeline.lane(of: $0.id) == .video ? $0 : nil }
    }
    /// 정보 패널 입력·초기화(한 단계). 범위 밖 값은 범위 안으로 맞춘다.
    /// 프리뷰는 새 상태의 정지 화면(InteractivePreview)을 먼저 띄운 뒤 다시 만들고, 새 항목이 표시될 준비가 되면 정지 화면을 내린다(깜박임 없음).
    func setTransform(_ id: UUID, _ t: ClipTransform?) {
        guard gestureBase == nil, let c = timeline.clip(id), c.transform != t?.clamped.normalized else { return }
        let before = timeline
        commit({ try $0.settingTransform(clip: id, t?.clamped) }, focus: selection ?? id, rebuild: false)
        guard timeline != before else { return }
        if !stillRebuild(from: before) { timelineChanged() }
    }

    // MARK: 프리뷰 끌기의 정지 화면(2026-10-11 깜박임 수정)
    //
    // 원인(코드와 자체 검사로 확인): 끌기 중 마우스가 움직일 때마다 composition을 다시 만들고 AVPlayer 항목을 바꿨다
    // (replaceCurrentItem). 새 항목의 첫 프레임이 준비될 때까지 AVPlayerLayer가 비어 검정이 보였다.
    // 수정: 끌기 중에는 항목을 바꾸지 않고, 재생 헤드 시각의 원본 프레임을 한 번 디코딩해 둔 뒤 같은 쌓음·변형 해석
    // (CompositionPlanner.layeredSegments·layerTransform)으로 겹친 화면을 그려 프리뷰 위 정지 화면 층에 보인다.
    // 놓으면 최종 상태로 한 번 다시 만들고, 새 항목이 표시될 준비가 된 뒤에 정지 화면을 내린다. Esc는 정지 화면만 내린다
    // (항목은 끌기 전 상태 그대로다).

    let interactive = InteractivePreview()
    /// 프리뷰 화면 호스트(PlayerNSView, 약한 참조). 정지 화면 표시·해제를 맡는다.
    @ObservationIgnored weak var previewHost: PlayerNSView?
    /// 정지 화면을 내릴 세대(이 세대 이상의 재구성이 적용되고 표시 준비가 되면 내린다)
    @ObservationIgnored private var stillReleaseGeneration: Int?
    #if DEBUG
    /// 자체 검사 전용: 이전(깜박이는) 경로 — 끌기 중 마우스 이동마다 다시 만든다. 원인 재현에만 쓴다.
    @ObservationIgnored var legacyTransformPreviewForTest = false
    @ObservationIgnored private var pendingPreviewRebuild = false
    /// 자체 검사 전용: 프리뷰 항목 교체 수
    private(set) var itemReplacements = 0
    #endif

    /// 정지 화면 경로를 쓸 수 있으면 시작한다(재생 헤드 아래 영상 원본 프레임을 미리 디코딩)
    private func beginStill(_ base: Timeline) {
        interactive.onItems = { [weak self] items in
            self?.previewHost?.showStage(items)
            #if DEBUG
            if let self, let (id, _) = self.liveTransform ?? self.selection.map({ ($0, ClipTransform.identity) }),
               let t = self.interactive.lastTimeline?.clip(id)?.effectiveTransform {
                PerfProbe.shared.didShow(.init(scale: t.scale, x: t.x, y: t.y))
            }
            #endif
        }
        interactive.begin(base.excludingMedia(missingUsedMedia), frame: min(playhead, max(0, base.durationFrames - 1)), media: mediaByID, settings: settings)
    }
    /// 변형만 바뀐 편집: 새 상태의 정지 화면을 띄우고 그 뒤에 다시 만든다(정지 화면이 뜨기 전에는 항목을 바꾸지 않는다). 할 수 없으면 false.
    private func stillRebuild(from before: Timeline) -> Bool {
        guard previewHost != nil, player.currentItem != nil else { return false }
        beginStill(before)
        let target = timeline
        generation += 1   // 진행 중인 재구성 결과는 버린다(새 상태로 다시 만든다)
        stillRequest += 1
        let request = stillRequest
        interactive.request(target.excludingMedia(missingUsedMedia)) { [weak self] shown in
            // 더 새 정지 화면 요청이 있으면 그쪽이 다시 만든다. 그 밖에는 그사이 타임라인이 바뀌었어도(예: 가져오기 반영) 지금 상태로 다시 만들고
            // 정지 화면을 내린다(generation을 이미 올려 진행 중 재구성을 버렸으므로 건너뛰면 프리뷰가 옛 항목·정지 화면에 남았다, 2026-10-11 리뷰).
            guard let self, request == self.stillRequest else { return }
            if shown || self.timeline != target { self.stillReleaseGeneration = self.generation + 1 }
            self.timelineChanged()
        }
        return true
    }
    @ObservationIgnored private var stillRequest = 0
    /// 재구성이 적용된 뒤: 정지 화면을 내릴 차례면 새 항목이 표시될 준비가 됐을 때 내린다
    private func releaseStillIfDue(_ g: Int, item: AVPlayerItem) {
        guard let r = stillReleaseGeneration, g >= r else { return }
        stillReleaseGeneration = nil
        interactive.end()
        previewHost?.releaseStill(when: item)
    }
    /// 정지 화면을 바로 내린다(Esc·프로젝트 교체: 항목은 이미 맞는 상태)
    private func dropStill() {
        stillReleaseGeneration = nil
        interactive.end()
        previewHost?.hideStill()
    }

    /// 프리뷰 끌기 중: 끌기 시작 상태에서 변형만 바꾼다(기록은 놓을 때 한 단계, Esc는 시작 상태로).
    /// 프리뷰 항목은 바꾸지 않고 무대 레이어의 변형만 바꾼다. 편집 기록(관찰되는 타임라인)도 놓을 때까지 바꾸지 않는다:
    /// 끌기 중 타임라인을 바꾸면 그것을 읽는 모든 SwiftUI 보기와 타임라인 보기를 매번 다시 계산·그렸다(§19 측정).
    /// 끌기 중 값은 gestureTimeline(관찰 안 함)과 liveTransform(조정 칸 표시용, 관찰)에만 둔다. 호출은 화면 갱신마다 한 번(PreviewOverlayView).
    func updateTransformGesture(_ id: UUID, _ t: ClipTransform) {
        guard let base = gestureBase, let next = try? base.settingTransform(clip: id, t.clamped) else { return }
        #if DEBUG
        if legacyTransformPreviewForTest {
            history.updateGesture(next, focus: selection)
            if appliedGeneration == generation { timelineChanged() } else { pendingPreviewRebuild = true }; return
        }
        #endif
        gestureTimeline = next
        if liveTransform?.clip != id || liveTransform?.transform != t.clamped { liveTransform = (id, t.clamped) }
        interactive.request(next.excludingMedia(missingUsedMedia))
    }
    /// 프리뷰 끌기 중 최신 상태(편집 기록에는 놓을 때 넣는다). 끌기가 아니면 nil.
    @ObservationIgnored private(set) var gestureTimeline: Timeline?
    /// 프리뷰 끌기 중 변형(조정 칸이 끌기 중 값을 보이는 데만 쓴다)
    private(set) var liveTransform: (clip: UUID, transform: ClipTransform)?
    /// 프리뷰 끌기 시작(선택은 그대로 둔다: 소리 클립을 골랐어도 연결된 영상의 변형을 바꾼다)
    func beginTransformGesture() {
        interruptGesture()   // D-031
        pauseForEdit()
        history.beginGesture()
        gestureBase = timeline
        transformGesture = true
        #if DEBUG
        gestureSerialForDebug += 1; traceGestureDebug("begin kind=transform")
        #endif
        #if DEBUG
        if legacyTransformPreviewForTest { return }
        #endif
        if previewHost != nil, player.currentItem != nil { beginStill(timeline) }
    }
    @ObservationIgnored private var transformGesture = false

    // MARK: 드래그 제스처(완료한 드래그 하나 = 한 단계, 취소하면 원래 상태)

    enum TrimEdge { case start, end }
    func beginGesture(select id: UUID) {
        interruptGesture()   // 끝나지 않은 끌기가 남아 있으면 먼저 취소(새 끌기에 섞어 확정하지 않음, D-031)
        pauseForEdit()
        selection = id
        history.beginGesture()
        gestureBase = timeline
        #if DEBUG
        gestureSerialForDebug += 1; traceGestureDebug("begin kind=timeline")
        #endif
    }
    func updateTrim(_ id: UUID, edge: TrimEdge, delta: Int) {
        guard let base = gestureBase else { return }
        do { history.updateGesture(try edge == .start ? base.trimmingStart(clip: id, by: delta) : base.trimmingEnd(clip: id, by: delta), focus: id); moveRejection = nil }
        catch let e as EditError { history.updateGesture(base, focus: id); moveRejection = delta == 0 ? nil : e } catch {}
    }
    /// 끌어 옮기기 미리 보기(2026-10-11: 연결된 쌍·연결되지 않은 클립 모두): 드래그 시작 위치 + delta, lane이 있으면 같은 종류의 그 레인으로.
    /// 연결된 짝은 같은 양만큼 옮기고(상대 위치 그대로) 자기 레인에 둔다. 묶음의 가장 이른 시작이 0보다 앞서지 않게 막는다.
    /// snapFrames > 0이면 0과 다른 클립 경계에 그 거리(프레임) 안에서 붙인다. 리플 없음, 원래 자리는 빈틈.
    /// 겹치면 원래 자리에 두고 제안 위치를 빨갛게 보인다(놓으면 아무것도 옮기지 않음).
    /// delta는 포인터에서 잰 소수 프레임(붙음 거리를 반올림 전 값으로 잰다).
    func updateFreeMove(_ id: UUID, delta: Double, lane: UUID? = nil, snapFrames: Double = 0) {
        guard let base = gestureBase, let c = base.clip(id) else { return }
        let earliest = base.group(of: id).map(\.start).min() ?? c.start
        let (d, snap) = base.snappedDelta(clip: id, delta: max(Double(-earliest), delta), threshold: snapFrames)
        let s = c.start + d
        let l = lane.flatMap { base.laneInfo($0)?.kind == base.lane(of: id) ? $0 : nil } ?? c.lane
        snapGuide = snap
        if let t = try? base.relocating(clip: id, toStart: s, lane: l) {
            freeMoveProposal = (id, s, true, l); history.updateGesture(t, focus: id)
        } else {
            freeMoveProposal = (id, s, false, l); history.updateGesture(base, focus: id)
        }
    }
    /// 끌어 옮기기 중 제안 위치(표시용): (클립, 시작, 놓을 수 있음, 레인)
    private(set) var freeMoveProposal: (id: UUID, start: Int, ok: Bool, lane: UUID?)?
    /// 끌어 옮기기 중 붙은 위치(프레임, 표시용 안내선). 붙지 않았으면 nil.
    private(set) var snapGuide: Int?
    /// 끼워 넣기 이동(리플). 2026-10-11부터 일반 끌기에서는 쓰지 않는다(이전 자체 검사의 저장소 경로로만 남김).
    func updateMove(_ id: UUID, toIndex: Int) {
        guard let base = gestureBase else { return }
        moveInsertionIndex = toIndex
        // 걸친 클립 때문에 거부되면 원래 자리에 둔다(놓을 때 이유를 보인다)
        do { history.updateGesture(try base.moving(clip: id, toIndex: toIndex), focus: id); moveRejection = nil }
        catch let e as EditError { history.updateGesture(base, focus: id); moveRejection = e } catch {}
    }
    /// 끌기 끝(한 단계). 바뀐 것이 없으면 프리뷰를 다시 만들지 않는다(항목을 바꾸지 않아 깜박이지 않음).
    /// 변형 끌기는 정지 화면을 띄운 채 최종 상태로 다시 만들고, 새 항목이 표시될 준비가 되면 정지 화면을 내린다.
    func commitGesture() {
        #if DEBUG
        traceGestureDebug("commit")
        #endif
        guard let base = gestureBase else { return }
        if transformGesture, let g = gestureTimeline { history.updateGesture(g, focus: selection) }   // 마지막(놓은 위치) 값 그대로
        gestureTimeline = nil; liveTransform = nil
        if let p = freeMoveProposal, !p.ok { statusMessage = EditError.overlap.description }
        if let r = moveRejection { statusMessage = r.description; moveRejection = nil }
        history.commitGesture(); gestureBase = nil; moveInsertionIndex = nil; freeMoveProposal = nil; snapGuide = nil
        let wasTransform = transformGesture; transformGesture = false
        #if DEBUG
        if legacyTransformPreviewForTest && wasTransform { pendingPreviewRebuild = false; timelineChanged(); return }
        #endif
        guard timeline != base else { if wasTransform { dropStill() }; updateWindowDocumentState(); return }
        if wasTransform, previewHost?.isShowingStill == true || interactive.isActive {
            stillReleaseGeneration = generation + 1
            interactive.request(timeline.excludingMedia(missingUsedMedia))   // 마지막 위치의 정지 화면(이미 그렸으면 같은 그림)
        }
        timelineChanged()
    }
    /// 끌기 중단(D-031, 2026-10-11): 놓기 이벤트를 받지 못할 수 있는 상황(편집기 창이 키 상태를 잃음, 앱 비활성, 끝나지 않은 끌기 위의 새 누름)에서
    /// 진행 중인 끌기를 Esc와 같이 취소하고(끌기 전 타임라인·기록·저장 상태, 재생은 다시 시작하지 않음), 타임라인·프리뷰 보기의 끌기 상태도 지우게 알린다.
    /// 끌기가 없으면 취소하지 않는다(알림이 여러 번 와도 한 번만 취소). 끝나지 않은 끌기를 다음 끌기와 함께 확정하지 않는다.
    /// clearViewDrags(창·앱 상태 바뀜, 프로젝트 교체): 저장소 끌기가 없어도 보기에 알린다. 타임라인 옮기기는 4 pt를 넘겨 끌 때 저장소 끌기를 시작하므로,
    /// 그 전(누름 대기)에 초점을 잃으면 저장소 끌기가 없다. 그 대기 상태를 지우지 않으면 같은 누름의 늦은 끌기가 새 옮기기를 시작하고 놓기가 확정했다
    /// (2026-10-12 소유자 로그 조사). 끌기 시작 직전의 확인(인자 없음)은 보기에 알리지 않는다(프리뷰는 끌기 상태를 정한 뒤 끌기를 시작한다).
    static let gestureInterruptedNotification = Notification.Name("dev.ontheframe.gestureInterrupted")
    func interruptGesture(reason: String = "staleGesture", clearViewDrags: Bool = false) {
        let active = gestureBase != nil
        #if DEBUG
        traceGestureDebug("interrupt reason=\(reason) hadGesture=\(active) clearViews=\(clearViewDrags)")
        #endif
        guard active || clearViewDrags else { return }
        if active {
            cancelGesture()
            #if DEBUG
            interruptCountForTest += 1
            #endif
        }
        NotificationCenter.default.post(name: Self.gestureInterruptedNotification, object: self)
    }
    #if DEBUG
    /// 끌기 진단(Debug 전용, CP-01 2026-10-12): 끌기 번호·이벤트(종류, 시스템 시각)·저장소 끌기·앱 활성·편집기 창 키·왼쪽 버튼 상태를 `trace`에 남긴다.
    /// 누름·놓기·끌기 시작·확정·취소·중단·창/앱 상태 바뀜에서만 부른다(포인터 움직임마다 남기지 않음). 경로·이름은 남기지 않는다.
    @ObservationIgnored private(set) var gestureSerialForDebug = 0
    @ObservationIgnored private var flagsMonitorForDebug: Any?
    @ObservationIgnored var commandDownForDebug = false
    func traceGestureDebug(_ what: String, event: NSEvent? = nil) {
        let ev = event.map { " ev=\($0.type.rawValue) t=\(String(format: "%.3f", $0.timestamp))" } ?? ""
        let g = gestureBase != nil ? "#\(gestureSerialForDebug)\(transformGesture ? "(transform)" : "")" : "none"
        let line = "dbg \(what)\(ev) gesture=\(g) appActive=\(NSApp.isActive) editorKey=\(editorWindow?.isKeyWindow == true) leftButton=\((NSEvent.pressedMouseButtons & 1) != 0)"
        Self.trace.info("\(line, privacy: .public)")
    }
    @ObservationIgnored var interruptCountForTest = 0
    /// 자체 검사 전용: 프리뷰가 정지 화면(무대)을 보이는 중인가
    var previewHostShowingStillForTest: Bool { previewHost?.isShowingStill == true }
    #endif
    /// 끌기 취소(Esc): 끌기 전 상태로. 끌기 중에는 프리뷰 항목을 바꾸지 않았으므로 다시 만들지 않고 정지 화면만 내린다.
    func cancelGesture() {
        #if DEBUG
        traceGestureDebug("cancel")
        #endif
        guard gestureBase != nil else { return }
        gestureTimeline = nil; liveTransform = nil
        history.cancelGesture(); gestureBase = nil; moveInsertionIndex = nil; freeMoveProposal = nil; snapGuide = nil
        let wasTransform = transformGesture; transformGesture = false
        #if DEBUG
        if legacyTransformPreviewForTest && wasTransform { pendingPreviewRebuild = false; timelineChanged(); return }
        #endif
        if wasTransform { dropStill() }
        updateWindowDocumentState()
    }

    // MARK: 프리뷰

    /// 타임라인이 바뀌면: 재생 헤드를 새 길이 안으로, composition을 비동기로 다시 만들고 오래된 결과는 버린다.
    func timelineChanged() {
        refreshAssets()
        updateWindowDocumentState()
        playhead = min(playhead, timeline.durationFrames)
        generation += 1
        // 찾을 수 없는 원본의 클립은 프리뷰에서 빼고(검정·무음) 화면에 따로 표시한다. 편집 상태는 그대로다.
        let g = generation, snap = timeline.excludingMedia(missingUsedMedia), media = mediaByID, s = settings
        guard !snap.isEmpty else {
            currentPlan = nil
            player.replaceCurrentItem(with: nil)
            appliedGeneration = g
            dropStill()
            return
        }
        Task {
            do {
                let plan = try await CompositionPlanner.plan(snap, media: media, settings: s)
                #if DEBUG
                if let d = self.testRebuildDelay[g] { try? await Task.sleep(nanoseconds: d) }
                #endif
                guard g == self.generation else {
                    Self.log.debug("stale rebuild dropped")
                    #if DEBUG
                    self.staleRebuildsDropped += 1
                    #endif
                    return
                }
                self.currentPlan = plan
                let item = AVPlayerItem(asset: plan.composition)
                if plan.hasVideo { item.videoComposition = plan.videoComposition }   // 소리 파일만 있으면 영상 트랙이 없다(검정)
                item.audioMix = plan.audioMix   // 오디오 레인 음량(A-014, 내보내기와 같은 믹스)
                #if DEBUG
                self.itemCreatedHookForTest?(item, g)   // 진단 전용: 새 항목에 비디오 출력을 붙인다(일반 실행에서는 nil)
                #endif
                self.player.replaceCurrentItem(with: item)
                #if DEBUG
                self.itemReplacements += 1
                #endif
                self.observeEnd(item)
                await self.player.seek(to: s.time(self.playhead), toleranceBefore: .zero, toleranceAfter: .zero)
                if g == self.generation {
                    self.appliedGeneration = g
                    self.releaseStillIfDue(g, item: item)   // 정지 화면은 새 항목이 표시될 준비가 된 뒤에 내린다
                    #if DEBUG
                    if self.pendingPreviewRebuild { self.pendingPreviewRebuild = false; self.timelineChanged() }   // 이전 경로 재현용
                    #endif
                }
            } catch {
                guard g == self.generation else { return }
                self.dropStill()
                self.statusMessage = "프리뷰를 만들지 못했습니다: \(error)"
            }
        }
    }

    private func observeEnd(_ item: AVPlayerItem) {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setPlaying(false)
                self.playhead = self.timeline.durationFrames
            }
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }
    func play() {
        guard !timeline.isEmpty, player.currentItem != nil else { return }
        if playhead >= timeline.durationFrames { seek(to: 0) }
        player.play(); setPlaying(true)
    }
    func pause() {
        player.pause(); setPlaying(false)
        playhead = min(settings.frame(containing: player.currentTime()), timeline.durationFrames)
    }
    func pauseForEdit() { if isPlaying { pause() } }
    func step(_ k: Int) { pauseForEdit(); seek(to: playhead + k) }
    func seek(to frame: Int) {
        let f = max(0, min(frame, timeline.durationFrames))
        playhead = f
        player.seek(to: settings.time(f), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 재생 중에만 디스플레이 유휴 절전을 막는다(E3-1: 디스플레이가 꺼지면 화면 표시가 멈춤).
    private func setPlaying(_ p: Bool) {
        isPlaying = p
        if p, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "ON THE FRAME playback" as CFString, &sleepAssertion)
        } else if !p, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
        }
    }

    // MARK: 내보내기

    func presentExportPanel() {
        guard !fileCommandBlocked() else { return }
        if let r = exportBlockReason { presentAlert(AlertInfo(title: "내보낼 수 없습니다", message: r)); return }
        guard canExport else { return }
        pauseForEdit()
        let p = NSSavePanel()
        p.allowedContentTypes = [.mpeg4Movie]
        p.nameFieldStringValue = projectName + ".mp4"
        p.canCreateDirectories = true
        p.message = "내보낼 위치를 고르세요(1920×1080, 30 fps, H.264/AAC MP4)."
        #if DEBUG
        if let o = exportPanelOverrideForTest { o(); return }   // 자체 검사: 실제 저장 패널을 띄우지 않고 "패널을 띄우려 함"만 기록
        #endif
        guard runPanel(p) == .OK, let url = p.url else { return }
        // 저장 패널이 기존 파일 대치를 확인했으면 그 시점의 파일 식별을 기록한다.
        startExport(ExportDestination.fromSavePanel(url))
    }

    /// 내보내기 시작. 가져오는 중이면 끝난 뒤 시작한다(대기열, 일반 화면에서는 가져오는 동안 내보내기 단추가 꺼져 있다).
    func startExport(_ d: ExportDestination) {
        guard !discardConfirmed, !editorClosedByUser else { return }
        pendingOps.append(.export(d))
        runNextOp()
    }

    /// 실제 내보내기 작업 시작. 경과 시간은 여기서(저장 패널을 닫은 뒤) 재기 시작해 준비·인코딩·검증·승격을 모두 포함하고,
    /// 성공·실패·취소가 끝난 시점에 멈춘다. 내보내기마다 추정을 새로 시작한다.
    private func beginExport(_ d: ExportDestination) {
        let snap = timeline, media = mediaByID, s = settings, sources = assets, options = exportOptions
        exportEstimator.reset(at: monoSeconds())
        exportCancelling = false
        lastExportElapsed = nil
        exportPhase = .running(0)
        #if DEBUG
        exportProgressLog = []
        exportStageLog = [.preparing]
        #endif
        exportTask = Task {
            let outcome: ExportOutcome
            do {
                let plan = try await CompositionPlanner.plan(snap, media: media, settings: s)   // 시작 시점 스냅샷
                if Task.isCancelled { outcome = .cancelled } else {
                    outcome = await ExportService.export(plan, to: d, sources: sources, options: options,
                                                         stage: { st in await MainActor.run { ProjectStore.shared.reportExportStage(st) } }) { p in
                        await MainActor.run { ProjectStore.shared.reportExportProgress(p) }   // 순서대로 전달
                    }
                }
            } catch { outcome = Task.isCancelled ? .cancelled : .failed(.export("\(error)")) }
            let elapsed = exportEstimator.elapsed(at: monoSeconds())
            lastExportElapsed = elapsed
            exportPhase = .idle
            exportCancelling = false
            exportTask = nil
            let took = ClockText.format(elapsed)
            switch outcome {
            case .completed(let u):   // 검증·승격 성공 뒤에만(ExportService). 취소·실패는 완료 시트를 쓰지 않는다.
                presentAlert(AlertInfo(title: "내보내기 완료", message: "\(u.lastPathComponent)\n\n걸린 시간 \(took)", revealURL: u,
                                       completion: (u.lastPathComponent, "걸린 시간 \(took)")))
            case .cancelled: statusMessage = "내보내기를 취소했습니다(경과 \(took)). 대상 파일은 만들지 않았습니다."
            case .failed(let f): presentAlert(AlertInfo(title: "내보내기 실패", message: "\(f.description)\n\n경과 \(took)"))
            }
            runNextOp()
        }
    }
    func cancelExport() {
        pendingOps.removeAll { if case .export = $0 { return true }; return false }
        guard exportTask != nil else { return }
        exportCancelling = true
        exportTask?.cancel()
    }

    /// 단계 반영(ExportService가 순서대로 부른다). 추정 표시용이며 진행률은 바꾸지 않는다.
    private func reportExportStage(_ st: ExportStage) {
        guard case .running = exportPhase else { return }
        exportEstimator.setStage(st)
        #if DEBUG
        exportStageLog.append(st)
        #endif
    }

    // MARK: 닫기·종료 보호(저장 기능은 M1 범위 밖)

    enum CloseIntent { case window, quit, newProject, openProject }
    /// 버리면 잃는 편집 작업이 있는가: 마지막 저장(또는 연) 상태와 다르면(A-013). 내보낸 MP4는 프로젝트 저장이 아니다.
    var hasUnsavedWork: Bool { isDirty }
    /// 사용자가 "버리고 닫기/종료"를 고른 뒤(이 실행이 끝날 때까지 유지)
    @ObservationIgnored private(set) var discardConfirmed = false
    /// 닫기 확인이 떠 있거나 대기 중(같은 확인을 겹쳐 띄우지 않음)
    @ObservationIgnored private(set) var closePromptPending = false
    @ObservationIgnored private var closeGuard: WindowCloseGuard?

    /// 확인 없이 닫을 수 있는가
    var canCloseWithoutPrompt: Bool { discardConfirmed || (!hasUnsavedWork && exportPhase == .idle) }

    /// 저장하지 않은 변경이 있을 때의 확인(A-013): 저장 / 취소 / 저장 안 함. 새 프로젝트·열기·창 닫기·종료가 같은 처리를 쓴다.
    /// - 저장: 저장 패널(처음) 또는 현재 위치에 저장. 저장을 취소했거나 실패하면 이어지는 동작을 하지 않는다.
    /// - 저장 안 함: 변경을 버리고 진행. 취소(Esc): 아무것도 하지 않음.
    /// 창 닫기·종료는 진행 전에 진행 중인 가져오기·내보내기를 취소·정리한다(finishDiscard). proceed는 그 뒤에 불린다.
    func requestDiscard(_ intent: CloseIntent, proceed: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void) {
        let closing = intent == .window || intent == .quit
        let go: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            if closing { self.discardConfirmed = true; self.finishDiscard(proceed) } else { proceed() }
        }
        if closing ? canCloseWithoutPrompt : !isDirty { go(); return }
        if closePromptPending { cancel(); return }
        closePromptPending = true
        pauseForEdit()
        let action: String
        switch intent {
        case .window: action = "창을 닫으면"
        case .quit: action = "종료하면"
        case .newProject: action = "새 프로젝트를 만들면"
        case .openProject: action = "다른 프로젝트를 열면"
        }
        var msg = "‘\(projectName)’에 저장하지 않은 변경 사항이 있습니다. 저장하지 않고 \(action) 마지막 저장 이후의 변경 사항이 사라집니다.\n\n내보낸 MP4는 프로젝트 저장이 아닙니다. 원본 파일과 이미 내보낸 파일은 그대로 남습니다."
        if exportPhase != .idle { msg += "\n\n진행 중인 내보내기는 취소되고 임시 파일은 정리됩니다. 대상 파일은 만들어지지 않습니다." }
        if importProgress != nil || !pendingOps.isEmpty { msg += "\n\n진행 중인 가져오기는 취소되고, 이번에 고른 파일은 추가되지 않습니다." }
        presentAlert(AlertInfo(title: "변경 사항을 저장할까요?", message: msg, buttons: ["저장", "취소", "저장 안 함"], destructiveIndex: 2, cancelIndex: 1, bringToFront: true,
                               onButton: { [weak self] i in
            guard let self else { return }
            self.closePromptPending = false
            // 확인 시트가 완전히 사라진 뒤에 잇는다(2026-10-11 소유자 보고 재현: 시트 끝 처리 안에서 바로 저장·열기 패널을 runModal 하면
            // 패널이 보이지 않은 채 곧바로(약 0.04 s) OK가 아닌 값으로 끝나, "저장"은 저장 취소로, "저장 안 함"은 열기 취소로 처리됐다)
            self.afterSheetSettles({
                switch i {
                case 0: self.saveProject { ok in if ok { go() } else { cancel() } }   // 저장 실패·취소면 진행하지 않음
                case 2: go()
                default: cancel()
                }
            }, abort: {
                // 앞의 시트·패널이 사라지지 않아 다음 패널을 띄울 수 없다: 고른 동작(저장·저장 안 함)을 하지 않고 취소와 같게 멈춘다
                cancel()
                self.statusMessage = "확인 창이 닫히지 않아 작업을 멈췄습니다. 현재 프로젝트와 변경 사항은 그대로입니다."
                self.presentAlert(AlertInfo(title: "작업을 계속할 수 없습니다",
                                            message: "앞의 확인 창이나 패널이 아직 닫히지 않아, 고른 동작(저장·저장 안 함)을 하지 않고 멈췄습니다.\n\n현재 프로젝트와 변경 사항은 그대로입니다. 열려 있는 창을 닫은 뒤 다시 시도하세요."))
            })
        }))
    }
    /// 확인 시트에서 고른 동작을 잇는다(2026-10-11). 편집기 창에 붙은 시트·보이는 시트 창·앱 모달이 모두 없어진 것을 확인한 뒤에만 f를 부른다
    /// (시트 처리기 안이나 다른 시트·패널이 떠 있는 동안 저장·열기 패널을 runModal 하면 패널이 보이지 않고 곧바로 끝났다).
    /// 사라짐은 처음엔 다음 주 대기열 차례에, 그 뒤 20 ms마다 확인한다. promptSettleTimeout 안에 사라지지 않으면 f를 부르지 않고 abort를 부른다
    /// (부르는 쪽이 취소와 같게 멈추고 상태를 푼다). f·abort는 합쳐 한 번만 불린다.
    private func afterSheetSettles(_ f: @escaping @MainActor () -> Void, abort: @escaping @MainActor () -> Void) {
        let deadline = Date().addingTimeInterval(Self.promptSettleTimeout)
        var finished = false, checks = 0
        func busy() -> Bool {
            #if DEBUG
            if promptSettleBlockedForTest { return true }
            #endif
            return editorWindow?.attachedSheet != nil || NSApp.modalWindow != nil || NSApp.windows.contains { $0.isSheet && $0.isVisible }
        }
        func check() {
            guard !finished else { return }
            checks += 1
            if !busy() {
                finished = true
                Self.trace.info("prompt continuation after sheet dismissed (checks \(checks, privacy: .public))")
                f()
            } else if Date() >= deadline {
                finished = true
                Self.trace.error("prompt continuation aborted: sheet or modal still present after \(Self.promptSettleTimeout, privacy: .public)s")
                abort()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { check() } }
            }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { check() } }
    }
    #if DEBUG
    static var promptSettleTimeout: TimeInterval = 2
    /// 자체 검사 전용: 시트·패널이 사라지지 않는 상황을 흉내 낸다(시간 초과 → 중단 경로)
    @ObservationIgnored var promptSettleBlockedForTest = false
    #else
    static let promptSettleTimeout: TimeInterval = 2
    #endif
    /// 진행 중인 내보내기가 있으면 취소하고 정리(임시 디렉터리 삭제)가 끝난 뒤 proceed
    /// 진행 중인 가져오기도 취소하고(늦은 결과는 버림) 검사가 멈춘 뒤 proceed.
    private func finishDiscard(_ proceed: @escaping @MainActor () -> Void) {
        abandonBackgroundWork()
        guard exportPhase != .idle || importTask != nil else { proceed(); return }
        Task { @MainActor in
            while self.exportPhase != .idle || self.importTask != nil { try? await Task.sleep(nanoseconds: 20_000_000) }
            proceed()
        }
    }
    /// 대기 중 작업을 버리고 진행 중인 가져오기·내보내기를 취소한다(버리기·창 닫기)
    private func abandonBackgroundWork() {
        pendingOps.removeAll()
        cancelImport()
        cancelExport()
    }
    /// 창 닫기(닫기 단추, ⌘W, 모두 닫기 — 모두 windowShouldClose를 거친다)
    /// 편집기 창을 화면 앞으로(파일을 열며 실행했거나 Dock 아이콘을 눌렀는데 보이는 창이 없을 때).
    /// 파일을 열며 실행하면 창 복원 상태에 따라 편집기 창이 화면에 나오지 않는 경우를 자체 검사에서 보았다.
    @ObservationIgnored private var wantsEditorVisible = false
    func ensureEditorVisible() {
        wantsEditorVisible = true
        guard let w = editorWindow else { return }   // 아직 없으면 붙을 때(attachEditorWindow) 앞으로
        if w.isMiniaturized { w.deminiaturize(nil) }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    /// 사용자가 편집기 창을 닫았는가(확인했거나 확인이 필요 없던 닫기). 마지막 창 닫힘 뒤 종료 판단에 쓴다.
    @ObservationIgnored private(set) var editorClosedByUser = false

    func windowShouldClose(_ w: NSWindow, original: NSWindowDelegate?) -> Bool {
        if canCloseWithoutPrompt, exportPhase == .idle {
            let ok = original?.windowShouldClose?(w) ?? true
            if ok { editorClosedByUser = true; abandonBackgroundWork() }   // 닫힌 창에 가져오기 결과를 넣지 않는다
            return ok
        }
        requestDiscard(.window, proceed: { [weak w] in w?.performClose(nil) }, cancel: {})
        return false
    }
    #if DEBUG
    /// 자체 검사 전용: 검사 끝에 앱을 끝낼 때 확인 없이 끝낸다
    func discardConfirmedForTest() { discardConfirmed = true }
    /// 자체 검사 전용: 확인 알림 없이 실제 버리기 처리(진행 중 작업 취소·정리 대기)만 한다. 앱을 끝내지 않는다.
    func discardWithoutPromptForTest(_ done: @escaping @MainActor () -> Void) { discardConfirmed = true; finishDiscard(done) }
    var closeGuardInstalled: Bool { editorWindow?.delegate === closeGuard && closeGuard != nil }
    #endif

    /// 진행률 반영(ExportService가 순서대로 부른다). 값을 고치지 않고 그대로 보인다.
    private func reportExportProgress(_ p: Double) {
        guard case .running = exportPhase else { return }
        exportPhase = .running(p)
        exportEstimator.record(progress: p, at: monoSeconds())
        #if DEBUG
        exportProgressLog.append(p)
        #endif
    }
    #if DEBUG
    /// 자체 검사 전용: 현재 내보내기에서 받은 진행률 순서
    var exportProgressLog: [Double] = []
    /// 자체 검사 전용: 현재 내보내기의 단계 순서
    var exportStageLog: [ExportStage] = []
    /// 진단 전용(A-010 프레임 0 조사): 새 프리뷰 항목이 만들어진 직후(교체 전) 불린다
    @ObservationIgnored var itemCreatedHookForTest: ((AVPlayerItem, Int) -> Void)?
    /// 진단 전용: 타임라인을 통째로 바꾼다(편집 기록 없이). 프리뷰 재구성은 일반 경로(timelineChanged)를 그대로 쓴다.
    func loadTimelineForTest(_ t: Timeline) { history.replaceWithoutUndo(t); timelineChanged() }
    /// 자체 검사 전용: 진행 카드 테두리와 편집기 루트 크기(가운데 배치 확인)
    @ObservationIgnored var progressCardFrame: CGRect = .zero   // 화면 갱신을 일으키지 않게 관찰 제외
    @ObservationIgnored var editorRootSize: CGSize = .zero
    #endif
}

/// 안전성(@unchecked Sendable): 주 스레드에서 불리는 로컬 이벤트 감시 안에서만 같은 스레드로 넘긴다.
private struct UncheckedEvent: @unchecked Sendable { let e: NSEvent; init(_ e: NSEvent) { self.e = e } }

/// 창 대리자 감싸기: windowShouldClose만 처리하고 다른 메시지는 원래(SwiftUI) 대리자에 넘긴다.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    init(original: NSWindowDelegate?) { self.original = original }
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        (original?.responds(to: aSelector) ?? false) ? original : nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { ProjectStore.shared.windowShouldClose(sender, original: original) }
    }
    /// 내보내기 완료 시트를 내용 영역 가운데에(다른 시트는 원래 대리자·기본 위치)
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        if let r = MainActor.assumeIsolated({ ProjectStore.shared.alerts.sheetPosition(for: window, sheet: sheet) }) { return r }
        return original?.window?(window, willPositionSheet: sheet, using: rect) ?? rect
    }
}

// MARK: - 프로젝트 저장·열기·최근·재연결(A-013)

/// 최근 프로젝트(앱 설정, 프로젝트 파일 밖). 경로와 앱 범위 보안 북마크.
struct RecentProject: Codable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let bookmark: Data?
}

extension ProjectStore {
    static let projectType = UTType(exportedAs: "dev.ontheframe.project", conformingTo: .json)
    static let recentKey = "recentProjects", recentLimit = 10

    // MARK: 상태

    /// 프로젝트 미디어 목록에서 쓸 수 있는 원본(검사 결과)과 찾을 수 없는 원본을 다시 만든다
    func refreshAssets() {
        var list: [MediaAsset] = [], missing: [UUID: String] = [:]
        for r in timeline.media {
            if let a = assetCache[r.path] { list.append(a.withID(r.id)) } else { missing[r.id] = missingMedia[r.id] ?? "원본 파일을 찾을 수 없습니다." }
        }
        if list != assets { assets = list }
        if missing != missingMedia { missingMedia = missing }
    }
    /// 타임라인 클립이 쓰는 찾을 수 없는 원본
    var missingUsedMedia: Set<UUID> {
        guard !missingMedia.isEmpty else { return [] }
        return Set(missingMedia.keys).intersection((timeline.clips + timeline.audioClips).map(\.mediaID))
    }
    /// 재생 헤드 아래(모든 레인) 클립 중 찾을 수 없는 원본의 이름
    var missingNameAtPlayhead: String? {
        guard !missingMedia.isEmpty else { return nil }
        let ids = (timeline.clips + timeline.audioClips).filter { playhead >= $0.start && playhead < $0.end }.map(\.mediaID)
        return ids.first { missingMedia[$0] != nil }.flatMap { id in timeline.media.first { $0.id == id }?.name }
    }
    /// 내보내기를 할 수 없는 이유(찾을 수 없는 원본, 또는 영상 원본이 하나도 없음)
    var exportBlockReason: String? {
        let names = timeline.media.filter { missingUsedMedia.contains($0.id) }.map(\.name)
        if !names.isEmpty { return "찾을 수 없는 원본 미디어(\(names.joined(separator: ", ")))가 있어 내보낼 수 없습니다. 파일 > 미디어 재연결…로 다시 연결하세요." }
        if !timeline.isEmpty, !timeline.media.contains(where: { $0.hasVideo && missingMedia[$0.id] == nil }) {
            return "영상 원본이 없어 내보낼 수 없습니다(소리 파일만 있음). 출력 영상(1920×1080)의 바탕을 만들 영상 파일을 하나 이상 가져오세요."
        }
        return nil
    }
    func updateWindowDocumentState() {
        guard let w = editorWindow else { return }
        if w.isDocumentEdited != isDirty { w.isDocumentEdited = isDirty }
        if w.representedURL != projectURL { w.representedURL = projectURL }
    }
    /// 프로젝트를 바꿀 수 있는가(가져오기·내보내기 중이면 아니다)
    func projectReplaceBlocked() -> Bool {
        guard openProgress != nil || openRequested || importProgress != nil || !pendingOps.isEmpty || exportPhase != .idle else { return false }
        presentAlert(AlertInfo(title: "프로젝트를 바꿀 수 없습니다",
                               message: openProgress != nil || openRequested ? "다른 프로젝트를 여는 중입니다. 끝나거나 취소한 뒤 다시 시도하세요."
                                                            : "가져오기 또는 내보내기가 진행 중입니다. 끝나거나 취소한 뒤 다시 시도하세요."))
        return true
    }
    func stopAllScopes() {
        for u in scopedURLs { u.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }

    // MARK: 새 프로젝트

    func requestNewProject() {
        guard !fileCommandBlocked(), !projectReplaceBlocked() else { return }
        requestDiscard(.newProject, proceed: { [weak self] in self?.resetProject() }, cancel: {})
    }
    /// 빈 프로젝트로(창 배치·최근 목록은 그대로)
    func resetProject() {
        stopAllScopes()
        replaceProject(timeline: Timeline(), url: nil, id: UUID(), cache: [:], bookmarks: [:], missing: [:])
    }
    private func replaceProject(timeline t: Timeline, url: URL?, id: UUID, cache: [String: MediaAsset], bookmarks bm: [UUID: Data], missing: [UUID: String]) {
        pauseForEdit()
        interruptGesture(reason: "replaceProject", clearViewDrags: true)   // 끌기 중이면 취소하고 보기의 끌기 상태(옮기기 누름 대기 포함)도 지운다(D-031)
        dropStill()
        history = EditHistory(t)
        savedTimeline = t
        projectURL = url; projectID = id
        projectSession += 1   // 같은 프로젝트를 다시 열어도 새 회차(그 전 회차에 묶인 확인은 동작하지 않음, CP-02)
        clipClipboard = nil   // 복사한 클립은 그 프로젝트에만(다른 프로젝트 미디어·권한을 다루지 않는다)
        assetCache = cache; bookmarks = bm; missingMedia = missing
        selection = nil; linkCandidate = nil; selectedLane = nil; statusMessage = nil
        seek(to: 0)
        timelineChanged()
    }

    // MARK: 저장

    /// 프로젝트 저장. 위치가 없거나 saveAs면 저장 패널. done(true)는 저장에 성공했을 때.
    /// 주의(2026-10-10 저장 실패 원인): `done?(writeProject(to: u))`처럼 쓰면 done이 nil일 때(메뉴·⌘S) Swift 선택적 호출이
    /// 인자 계산까지 건너뛰어 writeProject가 불리지 않는다. 결과를 먼저 계산한 뒤 done에 넘긴다.
    /// 사용자가 시작한 저장(메뉴·⌘S·⇧⌘S, done 없음)은 시트·알림·패널 중이면 하지 않는다(CP-03). done이 있는 호출은 확인 시트가 사라진 뒤 잇는
    /// 내부 흐름(저장 → 새 프로젝트·열기·닫기·종료)이라 막지 않는다.
    func saveProject(saveAs: Bool = false, done: (@MainActor (Bool) -> Void)? = nil) {
        if done == nil, fileCommandBlocked() { return }
        SaveTrace.note("saveProject saveAs=\(saveAs) hasURL=\(projectURL != nil) dirty=\(isDirty)")
        if let u = projectURL, !saveAs {
            let ok = writeProject(to: u)
            done?(ok)
            return
        }
        let p = NSSavePanel()
        p.allowedContentTypes = [Self.projectType]
        p.nameFieldStringValue = projectName + "." + ProjectFile.fileExtension
        p.canCreateDirectories = true
        p.message = "프로젝트를 저장할 위치를 고르세요. 원본 미디어는 복사하지 않고 위치만 기록합니다."
        #if DEBUG
        if let auto = savePanelAutoConfirmForTest {
            // 자체 검사: 실제 패널이 떠 있는 동안(모달 패널 실행 루프 모드) 위치·이름을 정하고 확인 단추(ok:)를 누른다.
            // 주 대기열 블록은 runModal 동안 돌지 않아 패널이 닫힌 뒤에 ok:를 불러 예외가 났다(진단 실행에서 확인).
            var step = 0
            let t = Timer(timeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard p.isVisible, step < 4 else { return }
                    step += 1
                    if step == 2 { p.directoryURL = auto.directory; p.nameFieldStringValue = auto.name }
                    if step == 4 { SaveTrace.note("autoConfirm ok:"); p.ok(nil) }
                }
            }
            RunLoop.main.add(t, forMode: .modalPanel)
            autoConfirmTimer = t
        }
        #endif
        var resp: NSApplication.ModalResponse
        var chosen: URL?
        #if DEBUG
        if let injected = savePanelResultForTest {   // 자체 검사: 패널이 "확인 + 이 위치"를 돌려준 것과 같게(패널 뒤 경로 회귀)
            savePanelResultForTest = nil; resp = .OK; chosen = injected
        } else { panelWillRunForTest?(p); resp = runPanel(p); chosen = p.url }
        autoConfirmTimer?.invalidate(); autoConfirmTimer = nil
        #else
        resp = runPanel(p); chosen = p.url
        #endif
        SaveTrace.note("panel response=\(resp.rawValue) url=\(chosen?.path ?? "nil")")
        guard resp == .OK else {
            statusMessage = "프로젝트 저장을 취소했습니다. 저장하지 않은 변경 사항은 그대로입니다."
            done?(false); return
        }
        guard let u = chosen else {
            presentAlert(AlertInfo(title: "프로젝트를 저장하지 못했습니다", message: "저장 패널이 위치를 돌려주지 않았습니다. 다시 저장해 보세요. 편집 내용은 그대로입니다."))
            done?(false); return
        }
        let ok = writeProject(to: u)
        done?(ok)
    }

    /// 프로젝트 파일 쓰기: 원본 미디어 보호 → 북마크 → 임시 위치에 쓰기 → 원자적으로 옮기기. 실패하면 이전 파일·상태 그대로.
    @discardableResult
    func writeProject(to url: URL) -> Bool {
        let dest = url.standardizedFileURL
        SaveTrace.note("writeProject dest=\(dest.path)")
        if let reason = protectedProjectDestination(dest) {
            SaveTrace.note("protected: \(reason)")
            presentAlert(AlertInfo(title: "프로젝트를 저장할 수 없습니다", message: reason)); return false
        }
        for a in assets {
            if let b = try? a.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) { bookmarks[a.id] = b }
        }
        let fm = FileManager.default
        do {
            let data = try ProjectFile.encode(timeline, projectID: projectID, settings: settings, bookmarks: bookmarks, projectURL: dest)
            SaveTrace.note("encoded bytes=\(data.count)")
            let tmpDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true)
            SaveTrace.note("tmpDir=\(tmpDir.path)")
            defer { try? fm.removeItem(at: tmpDir) }
            let tmp = tmpDir.appendingPathComponent(dest.lastPathComponent)
            try data.write(to: tmp, options: .withoutOverwriting)
            SaveTrace.note("tmp written exists=\(fm.fileExists(atPath: tmp.path))")
            // 확인: 옮기기 전에 임시 파일을 다시 읽어 같은 프로젝트인지 본다(잘못 쓴 파일이 이전 프로젝트 파일을 바꾸지 않게)
            let (bt, bdoc) = try ProjectFile.decode(try Data(contentsOf: tmp), settings: settings)
            guard bt == timeline, bdoc.projectID == projectID else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "쓴 파일을 다시 읽었더니 내용이 다릅니다."])
            }
            #if DEBUG
            if saveFailureForTest { saveFailureForTest = false; throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "시험용 저장 실패"]) }
            #endif
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp, backupItemName: nil, options: [])
            } else if renamex_np(tmp.path, dest.path, UInt32(RENAME_EXCL)) != 0 {
                let e = errno
                SaveTrace.note("renamex_np errno=\(e)")
                if e == EXDEV { try fm.moveItem(at: tmp, to: dest) } else { throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO) }
            }
            // 옮긴 뒤: 대상에 같은 크기의 파일이 있어야 저장된 것으로 한다
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -1
            SaveTrace.note("promoted destSize=\(size) expected=\(data.count)")
            guard size == data.count else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "저장 위치에서 파일을 확인할 수 없습니다."])
            }
        } catch {
            SaveTrace.note("error: \(error) — alert queued; presenter showing=\(alerts.isShowing) queued=\(alerts.queuedCount)")
            let what = (error as? ProjectFile.LoadError)?.description ?? error.localizedDescription
            presentAlert(AlertInfo(title: "프로젝트를 저장하지 못했습니다",
                                   message: "\(dest.lastPathComponent): \(what)\n\n편집 내용은 저장하지 않은 상태로 그대로 있습니다. 다른 위치를 골라 다시 저장해 보세요."))
            statusMessage = "프로젝트를 저장하지 못했습니다: \(what)"
            return false
        }
        projectURL = dest
        savedTimeline = timeline
        addRecent(dest)
        updateWindowDocumentState()
        statusMessage = "프로젝트를 저장했습니다: \(dest.lastPathComponent)"
        return true
    }
    /// 가져온 원본 미디어(같은 경로·심볼릭 링크·하드 링크)에는 프로젝트를 저장하지 않는다
    func protectedProjectDestination(_ dest: URL) -> String? {
        let d = dest.resolvingSymlinksInPath().path
        let did = FileIdentity.of(dest)
        let paths = assets.map { $0.url.standardizedFileURL } + timeline.media.map { URL(fileURLWithPath: $0.path) }
        for u in paths {
            if u.resolvingSymlinksInPath().path == d { return "‘\(u.lastPathComponent)’은(는) 프로젝트가 쓰는 원본 미디어입니다. 원본을 덮어쓰지 않도록 다른 이름을 고르세요." }
            if let did, let sid = FileIdentity.of(u), did.sameFile(as: sid) { return "고른 파일이 원본 미디어 ‘\(u.lastPathComponent)’와 같은 파일(링크)입니다. 다른 이름을 고르세요." }
        }
        return nil
    }

    // MARK: 열기

    /// 프로젝트 열기(메뉴·최근·Finder). url이 nil이면 열기 패널. 가져오기·내보내기 중이면 거절, 저장하지 않은 변경은 확인.
    func requestOpenProject(_ url: URL?, scoped: Bool = false) {
        guard !fileCommandBlocked(), !projectReplaceBlocked() else { if scoped { url?.stopAccessingSecurityScopedResource() }; return }
        Self.trace.info("open requested fromRecent=\(url != nil, privacy: .public)")
        openRequested = true
        requestDiscard(.openProject, proceed: { [weak self] in
            guard let self else { return }
            var target = url
            if target == nil {
                #if DEBUG
                if let o = self.openPanelOverrideForTest { target = o(); Self.trace.info("open panel (test override) chosen=\(target != nil, privacy: .public)") }
                #endif
                if target == nil, !self.openPanelOverridden {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [Self.projectType]
                    p.allowsMultipleSelection = false
                    p.message = "열 프로젝트(.ontheframe)를 선택하세요."
                    #if DEBUG
                    self.panelWillRunForTest?(p)
                    #endif
                    let r = self.runPanel(p)
                    Self.trace.info("open panel response=\(r.rawValue, privacy: .public)")
                    // 취소·실패면 target이 nil로 남아 아래에서 열기 요청을 끝낸다. 2026-10-11 결함: 여기서 바로 return해
                    // openRequested가 남았고, 그 뒤 모든 열기·새 프로젝트가 "프로젝트를 바꿀 수 없습니다"로 거부되고 가져오기·내보내기가 대기열에 멈췄다.
                    if r == .OK, let u = p.url { target = u }
                }
            }
            guard let target else {
                Self.trace.info("open ended without a file (panel cancelled)")
                self.endOpenRequest(); return
            }
            self.openTask = Task { @MainActor in
                let ok = await self.openProject(at: target)
                if scoped, !ok { target.stopAccessingSecurityScopedResource() }
                if scoped, ok { self.scopedURLs.append(target) }   // 최근 목록 북마크로 연 프로젝트 파일: 프로젝트가 바뀔 때 멈춘다
                self.openTask = nil
                self.endOpenRequest()
            }
        }, cancel: { [weak self] in
            Self.trace.info("open cancelled at unsaved-changes prompt")
            self?.endOpenRequest()
            if scoped { url?.stopAccessingSecurityScopedResource() }
        })
    }
    #if DEBUG
    private var openPanelOverridden: Bool { openPanelOverrideForTest != nil }
    #else
    private var openPanelOverridden: Bool { false }
    #endif
    /// 프로젝트 열기 취소(원본 확인 중): 현재 프로젝트는 그대로, 늦게 끝난 확인 결과는 버린다
    func cancelOpen() {
        guard openProgress != nil else { return }
        openEpoch += 1
        openProgress?.cancelling = true
        openTask?.cancel()
        Self.trace.info("open cancel requested")
    }

    /// 전체를 읽고 검사한 뒤에만 현재 프로젝트를 바꾼다. 실패하면 알림만(현재 상태 그대로). 성공하면 true.
    /// 2026-10-11: 파일 읽기는 주 스레드 밖에서, 원본 확인은 진행 카드(단계·경과·취소)와 함께. 단계와 걸린 시간을 진단 기록에 남긴다(경로 없음).
    @discardableResult
    func openProject(at url: URL) async -> Bool {
        guard openProgress == nil else { return false }
        openEpoch += 1
        let epoch = openEpoch, t0 = monoSeconds(), s = settings, before = timeline
        clearImportDone()
        openProgress = OpenProgress(stage: "프로젝트 파일 읽는 중", startedAt: t0)
        defer { openProgress = nil }   // 성공·실패·취소 모두(열기는 한 번에 하나: projectReplaceBlocked)
        func cancelled() -> Bool { epoch != openEpoch || Task.isCancelled }
        func abandon(_ scopes: [URL]) -> Bool {
            for u in scopes { u.stopAccessingSecurityScopedResource() }
            statusMessage = "프로젝트 열기를 취소했습니다. 현재 프로젝트는 그대로입니다."
            Self.trace.info("open abandoned (cancelled) after \(self.monoSeconds() - t0, format: .fixed(precision: 3), privacy: .public)s")
            return false
        }
        func fail(_ msg: String, _ stage: String) -> Bool {
            Self.trace.info("open failed at \(stage, privacy: .public) after \(self.monoSeconds() - t0, format: .fixed(precision: 3), privacy: .public)s")
            presentAlert(AlertInfo(title: "프로젝트를 열 수 없습니다", message: "\(url.lastPathComponent): \(msg)\n\n현재 프로젝트는 그대로입니다."))
            return false
        }
        Self.trace.info("open read start")
        let data: Data, decoded: (timeline: Timeline, document: ProjectFile.Document)
        do { data = try await Task.detached { try Data(contentsOf: url) }.value } catch { return fail(error.localizedDescription, "read") }
        if cancelled() { return abandon([]) }
        Self.trace.info("open read bytes=\(data.count, privacy: .public) at \(self.monoSeconds() - t0, format: .fixed(precision: 3), privacy: .public)s")
        do { decoded = try ProjectFile.decode(data, settings: s) } catch let e as ProjectFile.LoadError {
            return fail(e.description, "decode")
        } catch { return fail(error.localizedDescription, "decode") }
        Self.trace.info("open decoded version=\(decoded.document.version, privacy: .public) media=\(decoded.document.media.count, privacy: .public) clips=\(decoded.document.videoClips.count + decoded.document.audioClips.count, privacy: .public) at \(self.monoSeconds() - t0, format: .fixed(precision: 3), privacy: .public)s")
        openProgress?.total = decoded.document.media.count
        openProgress?.stage = "원본 미디어 확인 중"
        // 원본 미디어 찾기(북마크 → 프로젝트 기준 상대 경로 → 절대 경로). 찾지 못해도 편집 구조는 연다.
        var t = decoded.timeline
        var cache: [String: MediaAsset] = [:], bm: [UUID: Data] = [:], missing: [UUID: String] = [:], scopes: [URL] = []
        let dir = url.deletingLastPathComponent()
        for (i, e) in decoded.document.media.enumerated() {
            if cancelled() { return abandon(scopes) }
            openProgress?.completed = i; openProgress?.currentName = e.ref.name; openProgress?.stage = "원본 미디어 확인 중"
            let m0 = monoSeconds()
            #if DEBUG
            if probeDelayForTest > 0 { try? await Task.sleep(nanoseconds: probeDelayForTest) }
            #endif
            if let b = e.bookmark { bm[e.ref.id] = b }
            var candidates: [(URL, Bool)] = []
            if let b = e.bookmark {
                var stale = false
                if let u = try? URL(resolvingBookmarkData: b, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    candidates.append((u, u.startAccessingSecurityScopedResource()))   // 오래된 북마크는 다음 저장 때 새로 만든다
                }
            }
            if let rel = e.relativePath { candidates.append((dir.appendingPathComponent(rel).standardizedFileURL, false)) }
            candidates.append((URL(fileURLWithPath: e.ref.path), false))
            var reason = "원본 파일을 찾을 수 없습니다(이동·삭제됐거나 접근 권한이 없음)."
            var found = false
            for (k, (u, started)) in candidates.enumerated() {
                guard !found, !cancelled(), FileManager.default.isReadableFile(atPath: u.path), let a = try? await MediaProbe.inspect(u, settings: s, stage: { st in
                    Task { @MainActor [weak self] in
                        guard let self, epoch == self.openEpoch, self.openProgress?.completed == i else { return }
                        self.openProgress?.stage = "원본 미디어 확인 중 · " + st.label
                    }
                }) else {
                    if started { u.stopAccessingSecurityScopedResource() }; continue
                }
                Self.trace.info("open media#\(i + 1, privacy: .public) candidate\(k + 1, privacy: .public) inspected")
                let asset = a.withID(e.ref.id)
                var ref = MediaRef(asset); ref.path = e.ref.path   // 저장된 경로를 키로 쓴다(실제 위치는 검사 결과에)
                do {
                    t = try t.relinking(media: e.ref.id, to: ref)
                    cache[e.ref.path] = asset
                    if started { scopes.append(u) }
                    found = true
                } catch let err as EditError {
                    reason = "원본이 바뀌어 쓸 수 없습니다: \(err.description)"
                    if started { u.stopAccessingSecurityScopedResource() }
                } catch { if started { u.stopAccessingSecurityScopedResource() } }
            }
            if !found { missing[e.ref.id] = reason }
            Self.trace.info("open media#\(i + 1, privacy: .public) \(found ? "found" : "missing", privacy: .public) in \(self.monoSeconds() - m0, format: .fixed(precision: 3), privacy: .public)s")
        }
        if cancelled() { return abandon(scopes) }
        // 여는 동안 현재 프로젝트를 편집했으면 바꾸지 않는다(확인 없이 그 편집을 버리지 않게, 2026-10-11 리뷰)
        if gestureBase != nil || timeline != before {
            for u in scopes { u.stopAccessingSecurityScopedResource() }
            Self.trace.info("open abandoned (edited during open)")
            presentAlert(AlertInfo(title: "프로젝트를 열지 않았습니다", message: "여는 동안 현재 프로젝트가 바뀌었습니다. 변경 사항을 지키려고 \(url.lastPathComponent)을(를) 열지 않았습니다.\n\n현재 프로젝트는 그대로입니다. 다시 열어 주세요."))
            return false
        }
        stopAllScopes()
        scopedURLs = scopes
        replaceProject(timeline: t, url: url.standardizedFileURL, id: decoded.document.projectID, cache: cache, bookmarks: bm, missing: missing)
        addRecent(url.standardizedFileURL)
        Self.trace.info("open applied missing=\(missing.count, privacy: .public) total \(self.monoSeconds() - t0, format: .fixed(precision: 3), privacy: .public)s")
        if !missing.isEmpty {
            let names = t.media.filter { missing[$0.id] != nil }.map(\.name)
            presentAlert(AlertInfo(title: "찾을 수 없는 원본 미디어가 있습니다",
                                   message: "\(names.joined(separator: ", "))\n\n편집 내용은 그대로 열었습니다. 이 원본을 쓰는 구간은 프리뷰에서 비어 보이고, 내보내기는 다시 연결할 때까지 할 수 없습니다. 파일 > 미디어 재연결…을 쓰세요."))
        }
        return true
    }

    // MARK: 최근 프로젝트

    func loadRecents() {
        let d = EditorLayout.shared.defaults
        if let data = d.data(forKey: Self.recentKey), let list = try? JSONDecoder().decode([RecentProject].self, from: data) { recentProjects = list }
    }
    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentProjects) { EditorLayout.shared.defaults.set(data, forKey: Self.recentKey) }
    }
    /// 성공적으로 열거나 저장한 프로젝트만(맨 앞, 중복 없음, 최대 10개)
    func addRecent(_ url: URL) {
        let b = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let item = RecentProject(path: url.standardizedFileURL.path, name: url.deletingPathExtension().lastPathComponent, bookmark: b)
        recentProjects = Array(([item] + recentProjects.filter { $0.path != item.path }).prefix(Self.recentLimit))
        saveRecents()
    }
    /// 목록만 지운다(프로젝트 파일은 그대로)
    func clearRecents() { recentProjects = []; saveRecents() }
    func openRecent(_ r: RecentProject) {
        guard !fileCommandBlocked() else { return }
        var stale = false
        if let b = r.bookmark, let u = try? URL(resolvingBookmarkData: b, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
           u.startAccessingSecurityScopedResource() {
            guard FileManager.default.isReadableFile(atPath: u.path) else {
                u.stopAccessingSecurityScopedResource(); recentUnavailable(r); return
            }
            requestOpenProject(u, scoped: true)
        } else if FileManager.default.isReadableFile(atPath: r.path) {
            requestOpenProject(URL(fileURLWithPath: r.path))
        } else { recentUnavailable(r) }
    }
    private func recentUnavailable(_ r: RecentProject) {
        presentAlert(AlertInfo(title: "최근 프로젝트를 열 수 없습니다",
                               message: "‘\(r.name)’을(를) 찾을 수 없거나 접근 권한이 없습니다. 이동·삭제됐을 수 있습니다. 프로젝트 열기…로 다시 고르거나 최근 프로젝트 > 목록 지우기로 정리하세요."))
    }

    // MARK: 미디어 재연결

    /// 찾을 수 없는 원본 하나를 고른 파일로 다시 연결한다(실행 취소 한 단계). 모든 원본 구간이 새 파일 안에 있어야 한다(클립을 줄이지 않음).
    func relinkMedia(_ id: UUID) {
        guard !fileCommandBlocked(), let r = timeline.media.first(where: { $0.id == id }) else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .audio]
        p.allowsMultipleSelection = false
        p.message = "‘\(r.name)’ 대신 쓸 파일을 고르세요(같은 원본, 길이 \(store_tc(r.frameCount)) 이상)."
        p.directoryURL = URL(fileURLWithPath: r.path).deletingLastPathComponent()
        guard runPanel(p) == .OK, let u = p.url else { return }
        Task { @MainActor in await self.relinkMedia(id, to: u) }
    }
    private func store_tc(_ f: Int) -> String { settings.timecode(f) }
    /// 재연결 실행(검사 → 실행 취소 가능한 변경). 성공하면 true.
    @discardableResult
    func relinkMedia(_ id: UUID, to url: URL) async -> Bool {
        let project = projectID
        do {
            let a = try await MediaProbe.inspect(url, settings: settings).withID(id)
            // 검사 중 시작한 끌기가 끝날 때까지 기다린다(끌기 중 기록 변경은 precondition 실패, 2026-10-11 리뷰). 그사이 프로젝트가 바뀌면 그만둔다.
            while gestureBase != nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard projectID == project, openProgress == nil else { statusMessage = "프로젝트가 바뀌어 다시 연결하지 않았습니다."; return false }
            let t = try timeline.relinking(media: id, to: MediaRef(a))
            assetCache[a.url.standardizedFileURL.path] = a
            missingMedia[id] = nil
            history.apply(t, focus: selection)
            timelineChanged()
            statusMessage = "‘\(url.lastPathComponent)’로 다시 연결했습니다."
            return true
        } catch let e as EditError {
            presentAlert(AlertInfo(title: "다시 연결할 수 없습니다", message: e.description)); return false
        } catch let e as ProbeError {
            presentAlert(AlertInfo(title: "다시 연결할 수 없습니다", message: e.description)); return false
        } catch {
            presentAlert(AlertInfo(title: "다시 연결할 수 없습니다", message: error.localizedDescription)); return false
        }
    }
    func relinkFirstMissing() {
        if let id = timeline.media.first(where: { missingMedia[$0.id] != nil })?.id { relinkMedia(id) }
    }
}
