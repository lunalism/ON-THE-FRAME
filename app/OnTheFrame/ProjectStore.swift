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
    private(set) var isPlaying = false
    var statusMessage: String?
    /// 표시 중인 알림(관찰·검사용 사본). 실제 표시는 AlertPresenter(AppKit 시트)가 맡고,
    /// 표시 중인 알림은 바꾸거나 코드로 닫지 않는다(2026-10-10 충돌 대응, app/README.md 충돌 기록).
    private(set) var alert: AlertInfo?
    let alerts = AlertPresenter()
    /// 가져오기 진행(표시용). nil이면 진행 중인 가져오기 묶음이 없다.
    struct ImportProgress: Equatable { let total: Int; var completed: Int; var currentName: String?; var cancelling = false }
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
    var canExport: Bool { !timeline.isEmpty && exportPhase == .idle && importProgress == nil && pendingOps.isEmpty && missingUsedMedia.isEmpty }

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
        guard importProgress == nil, importTask == nil, exportPhase == .idle, exportTask == nil, !pendingOps.isEmpty else { return }
        switch pendingOps.removeFirst() {
        case .importFiles(let urls): runImport(urls)
        case .export(let d): beginExport(d)
        }
    }

    private func runImport(_ urls: [URL]) {
        let epoch = importEpoch, s = settings
        importProgress = ImportProgress(total: urls.count, completed: 0, currentName: urls.first?.lastPathComponent)
        importTask = Task { [weak self] in
            var results: [(URL, Result<MediaAsset, Error>)] = []
            for url in urls {
                guard let self, self.importEpoch == epoch, !Task.isCancelled else { break }
                self.importProgress?.currentName = url.lastPathComponent
                let r: Result<MediaAsset, Error>
                do { r = .success(try await MediaProbe.inspect(url, settings: s)) } catch { r = .failure(error) }
                guard self.importEpoch == epoch, !Task.isCancelled else { break }   // 취소 뒤 늦게 끝난 검사 결과는 버린다
                results.append((url, r))
                self.importProgress?.completed += 1
            }
            self?.finishImport(epoch: epoch, total: urls.count, results: results)
        }
    }

    private func finishImport(epoch: Int, total: Int, results: [(URL, Result<MediaAsset, Error>)]) {
        importTask = nil
        importProgress = nil
        defer { runNextOp() }
        // 취소·버리기·창 닫기 뒤: 아무것도 반영하지 않는다
        guard epoch == importEpoch, results.count == total, !discardConfirmed, !editorClosedByUser else {
            if !discardConfirmed && !editorClosedByUser { statusMessage = "가져오기를 취소했습니다. 이번에 고른 파일은 추가하지 않았습니다." }
            return
        }
        var rejected: [String] = []
        for (url, r) in results {   // 고른 순서대로 목록에 넣는다
            switch r {
            case .success(let a):
                if assets.contains(where: { $0.identity.sameFile(as: a.identity) }) {
                    statusMessage = "이미 가져온 파일입니다: \(url.lastPathComponent)"; continue
                }
                // 가져오기는 실행 취소로 사라지지 않는다(모든 단계에 등록). 프로젝트 변경이라 저장하지 않은 상태가 된다.
                assetCache[a.url.standardizedFileURL.path] = a
                history.mapAll { $0.registering(a) }
                refreshAssets()
                Self.log.info("imported media frames=\(a.frameCount) timing=\(a.timing.detail, privacy: .public)")
            case .failure(let e):
                rejected.append("\(url.lastPathComponent): \((e as? ProbeError)?.description ?? e.localizedDescription)")
            }
        }
        if !rejected.isEmpty { presentAlert(AlertInfo(title: Self.rejectTitle, message: rejected.joined(separator: "\n\n"))) }
    }

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
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.movie]
        p.message = "가져올 영상 파일을 고르세요(H.264·HEVC MP4·MOV·M4V, 1920×1080 이하, 10분 이하)."
        if p.runModal() == .OK { importFiles(p.urls) }
    }

    // MARK: 편집(실행 취소 대상)

    private func commit(_ make: (Timeline) throws -> Timeline, focus: UUID?, select: UUID? = nil) {
        pauseForEdit()
        do {
            let t = try make(timeline)
            history.apply(t, focus: focus)
            selection = select ?? focus
            linkCandidate = nil
            statusMessage = nil
            timelineChanged()
        } catch let e as EditError {
            statusMessage = e.description
        } catch { statusMessage = error.localizedDescription }
    }

    /// 영상(+원본에 소리가 있으면 연결된 원본 소리)을 넣는다(A-012)
    func addToTimeline(_ mediaID: UUID, at index: Int? = nil) {
        let cid = UUID()
        commit({ try $0.inserting(media: mediaID, at: index, clipID: cid) }, focus: cid)
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
        guard extend, let id, let sel = selection, sel != id else { selection = id; return }
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
        let old = timeline.lanes.first { $0.id == id }?.name
        do {
            let t = try timeline.renamingLane(id, to: name)
            guard t.lanes.first(where: { $0.id == id })?.name != old else { return false }
            history.apply(t, focus: selection)
            statusMessage = nil
            return true
        } catch let e as EditError { statusMessage = e.description; return false } catch { return false }
    }

    // MARK: 드래그 제스처(완료한 드래그 하나 = 한 단계, 취소하면 원래 상태)

    enum TrimEdge { case start, end }
    func beginGesture(select id: UUID) {
        pauseForEdit()
        selection = id
        history.beginGesture()
        gestureBase = timeline
    }
    func updateTrim(_ id: UUID, edge: TrimEdge, delta: Int) {
        guard let base = gestureBase else { return }
        do { history.updateGesture(try edge == .start ? base.trimmingStart(clip: id, by: delta) : base.trimmingEnd(clip: id, by: delta), focus: id); moveRejection = nil }
        catch let e as EditError { history.updateGesture(base, focus: id); moveRejection = delta == 0 ? nil : e } catch {}
    }
    /// 자유 이동 미리 보기(연결되지 않은 클립): 드래그 시작 위치 + delta. 겹치면 원래 자리에 두고 제안 위치를 빨갛게 보인다.
    func updateFreeMove(_ id: UUID, delta: Int) {
        guard let base = gestureBase, let c = base.clip(id) else { return }
        let s = max(0, c.start + delta)
        if let t = try? base.movingFree(clip: id, toStart: s) {
            freeMoveProposal = (id, s, true); history.updateGesture(t, focus: id)
        } else {
            freeMoveProposal = (id, s, false); history.updateGesture(base, focus: id)
        }
    }
    /// 자유 이동 중 제안 위치(표시용): (클립, 시작, 놓을 수 있음)
    private(set) var freeMoveProposal: (id: UUID, start: Int, ok: Bool)?
    func updateMove(_ id: UUID, toIndex: Int) {
        guard let base = gestureBase else { return }
        moveInsertionIndex = toIndex
        // 걸친 클립 때문에 거부되면 원래 자리에 둔다(놓을 때 이유를 보인다)
        do { history.updateGesture(try base.moving(clip: id, toIndex: toIndex), focus: id); moveRejection = nil }
        catch let e as EditError { history.updateGesture(base, focus: id); moveRejection = e } catch {}
    }
    func commitGesture() {
        guard gestureBase != nil else { return }
        if let p = freeMoveProposal, !p.ok { statusMessage = EditError.overlap.description }
        if let r = moveRejection { statusMessage = r.description; moveRejection = nil }
        history.commitGesture(); gestureBase = nil; moveInsertionIndex = nil; freeMoveProposal = nil
        timelineChanged()
    }
    func cancelGesture() {
        guard gestureBase != nil else { return }
        history.cancelGesture(); gestureBase = nil; moveInsertionIndex = nil; freeMoveProposal = nil
        timelineChanged()
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
                item.videoComposition = plan.videoComposition
                #if DEBUG
                self.itemCreatedHookForTest?(item, g)   // 진단 전용: 새 항목에 비디오 출력을 붙인다(일반 실행에서는 nil)
                #endif
                self.player.replaceCurrentItem(with: item)
                self.observeEnd(item)
                await self.player.seek(to: s.time(self.playhead), toleranceBefore: .zero, toleranceAfter: .zero)
                if g == self.generation { self.appliedGeneration = g }
            } catch {
                guard g == self.generation else { return }
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
        if let r = exportBlockReason { presentAlert(AlertInfo(title: "내보낼 수 없습니다", message: r)); return }
        guard canExport else { return }
        pauseForEdit()
        let p = NSSavePanel()
        p.allowedContentTypes = [.mpeg4Movie]
        p.nameFieldStringValue = projectName + ".mp4"
        p.canCreateDirectories = true
        p.message = "내보낼 위치를 고르세요(1920×1080, 30 fps, H.264/AAC MP4)."
        guard p.runModal() == .OK, let url = p.url else { return }
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
            switch i {
            case 0: self.saveProject { ok in if ok { go() } else { cancel() } }   // 저장 실패·취소면 진행하지 않음
            case 2: go()
            default: cancel()
            }
        }))
    }
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
    /// 재생 헤드 아래(영상·소리) 클립 중 찾을 수 없는 원본의 이름
    var missingNameAtPlayhead: String? {
        guard !missingMedia.isEmpty else { return nil }
        let ids = [timeline.clipIndex(atFrame: playhead).map { timeline.clips[$0].mediaID }, timeline.audioClipIndex(atFrame: playhead).map { timeline.audioClips[$0].mediaID }]
        return ids.compactMap { $0 }.first { missingMedia[$0] != nil }.flatMap { id in timeline.media.first { $0.id == id }?.name }
    }
    /// 내보내기를 할 수 없는 이유(찾을 수 없는 원본)
    var exportBlockReason: String? {
        let names = timeline.media.filter { missingUsedMedia.contains($0.id) }.map(\.name)
        return names.isEmpty ? nil : "찾을 수 없는 원본 미디어(\(names.joined(separator: ", ")))가 있어 내보낼 수 없습니다. 파일 > 미디어 재연결…로 다시 연결하세요."
    }
    func updateWindowDocumentState() {
        guard let w = editorWindow else { return }
        if w.isDocumentEdited != isDirty { w.isDocumentEdited = isDirty }
        if w.representedURL != projectURL { w.representedURL = projectURL }
    }
    /// 프로젝트를 바꿀 수 있는가(가져오기·내보내기 중이면 아니다)
    func projectReplaceBlocked() -> Bool {
        guard importProgress != nil || !pendingOps.isEmpty || exportPhase != .idle else { return false }
        presentAlert(AlertInfo(title: "프로젝트를 바꿀 수 없습니다",
                               message: "가져오기 또는 내보내기가 진행 중입니다. 끝나거나 취소한 뒤 다시 시도하세요."))
        return true
    }
    func stopAllScopes() {
        for u in scopedURLs { u.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }

    // MARK: 새 프로젝트

    func requestNewProject() {
        guard !projectReplaceBlocked() else { return }
        requestDiscard(.newProject, proceed: { [weak self] in self?.resetProject() }, cancel: {})
    }
    /// 빈 프로젝트로(창 배치·최근 목록은 그대로)
    func resetProject() {
        stopAllScopes()
        replaceProject(timeline: Timeline(), url: nil, id: UUID(), cache: [:], bookmarks: [:], missing: [:])
    }
    private func replaceProject(timeline t: Timeline, url: URL?, id: UUID, cache: [String: MediaAsset], bookmarks bm: [UUID: Data], missing: [UUID: String]) {
        pauseForEdit()
        if gestureBase != nil { cancelGesture() }
        history = EditHistory(t)
        savedTimeline = t
        projectURL = url; projectID = id
        assetCache = cache; bookmarks = bm; missingMedia = missing
        selection = nil; linkCandidate = nil; statusMessage = nil
        seek(to: 0)
        timelineChanged()
    }

    // MARK: 저장

    /// 프로젝트 저장. 위치가 없거나 saveAs면 저장 패널. done(true)는 저장에 성공했을 때.
    /// 주의(2026-10-10 저장 실패 원인): `done?(writeProject(to: u))`처럼 쓰면 done이 nil일 때(메뉴·⌘S) Swift 선택적 호출이
    /// 인자 계산까지 건너뛰어 writeProject가 불리지 않는다. 결과를 먼저 계산한 뒤 done에 넘긴다.
    func saveProject(saveAs: Bool = false, done: (@MainActor (Bool) -> Void)? = nil) {
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
        } else { resp = p.runModal(); chosen = p.url }
        autoConfirmTimer?.invalidate(); autoConfirmTimer = nil
        #else
        resp = p.runModal(); chosen = p.url
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
        guard !projectReplaceBlocked() else { if scoped { url?.stopAccessingSecurityScopedResource() }; return }
        requestDiscard(.openProject, proceed: { [weak self] in
            guard let self else { return }
            var target = url
            if target == nil {
                let p = NSOpenPanel()
                p.allowedContentTypes = [Self.projectType]
                p.allowsMultipleSelection = false
                p.message = "열 프로젝트(.ontheframe)를 고르세요."
                guard p.runModal() == .OK, let u = p.url else { return }
                target = u
            }
            guard let target else { return }
            Task { @MainActor in
                let ok = await self.openProject(at: target)
                if scoped, !ok { target.stopAccessingSecurityScopedResource() }
                if scoped, ok { self.scopedURLs.append(target) }   // 최근 목록 북마크로 연 프로젝트 파일: 프로젝트가 바뀔 때 멈춘다
            }
        }, cancel: { if scoped { url?.stopAccessingSecurityScopedResource() } })
    }

    /// 전체를 읽고 검사한 뒤에만 현재 프로젝트를 바꾼다. 실패하면 알림만(현재 상태 그대로). 성공하면 true.
    @discardableResult
    func openProject(at url: URL) async -> Bool {
        let data: Data, decoded: (timeline: Timeline, document: ProjectFile.Document)
        do { data = try Data(contentsOf: url) } catch {
            presentAlert(AlertInfo(title: "프로젝트를 열 수 없습니다", message: "\(url.lastPathComponent): \(error.localizedDescription)")); return false
        }
        do { decoded = try ProjectFile.decode(data, settings: settings) } catch let e as ProjectFile.LoadError {
            presentAlert(AlertInfo(title: "프로젝트를 열 수 없습니다", message: "\(url.lastPathComponent): \(e.description)")); return false
        } catch {
            presentAlert(AlertInfo(title: "프로젝트를 열 수 없습니다", message: error.localizedDescription)); return false
        }
        // 원본 미디어 찾기(북마크 → 프로젝트 기준 상대 경로 → 절대 경로). 찾지 못해도 편집 구조는 연다.
        var t = decoded.timeline
        var cache: [String: MediaAsset] = [:], bm: [UUID: Data] = [:], missing: [UUID: String] = [:], scopes: [URL] = []
        let dir = url.deletingLastPathComponent()
        for e in decoded.document.media {
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
            for (u, started) in candidates {
                guard !found, FileManager.default.isReadableFile(atPath: u.path), let a = try? await MediaProbe.inspect(u, settings: settings) else {
                    if started { u.stopAccessingSecurityScopedResource() }; continue
                }
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
        }
        stopAllScopes()
        scopedURLs = scopes
        replaceProject(timeline: t, url: url.standardizedFileURL, id: decoded.document.projectID, cache: cache, bookmarks: bm, missing: missing)
        addRecent(url.standardizedFileURL)
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
        guard let r = timeline.media.first(where: { $0.id == id }) else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie]
        p.allowsMultipleSelection = false
        p.message = "‘\(r.name)’ 대신 쓸 파일을 고르세요(같은 원본, 길이 \(store_tc(r.frameCount)) 이상)."
        p.directoryURL = URL(fileURLWithPath: r.path).deletingLastPathComponent()
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { @MainActor in await self.relinkMedia(id, to: u) }
    }
    private func store_tc(_ f: Int) -> String { settings.timecode(f) }
    /// 재연결 실행(검사 → 실행 취소 가능한 변경). 성공하면 true.
    @discardableResult
    func relinkMedia(_ id: UUID, to url: URL) async -> Bool {
        do {
            let a = try await MediaProbe.inspect(url, settings: settings).withID(id)
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
