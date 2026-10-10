import AppKit
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
    var projectName = "제목 없음"
    private(set) var assets: [MediaAsset] = []
    private(set) var history = EditHistory()
    var timeline: Timeline { history.timeline }
    var selection: UUID?
    private(set) var playhead = 0              // 0…durationFrames(끝 위치 포함)
    private(set) var isPlaying = false
    var statusMessage: String?
    /// 표시 중인 알림(관찰·검사용 사본). 실제 표시는 AlertPresenter(AppKit 시트)가 맡고,
    /// 표시 중인 알림은 바꾸거나 코드로 닫지 않는다(2026-10-10 충돌 대응, app/README.md 충돌 기록).
    private(set) var alert: AlertInfo?
    let alerts = AlertPresenter()
    private(set) var importing = 0

    struct AlertInfo: Identifiable {
        let id = UUID(); let title: String; let message: String; var revealURL: URL? = nil
        /// 지정하면 이 단추들과 처리기를 쓴다(buttons[0]이 기본 단추)
        var buttons: [String]? = nil; var destructiveIndex: Int? = nil; var bringToFront = false; var onButton: (@MainActor (Int) -> Void)? = nil
    }

    enum ExportPhase: Equatable { case idle, running(Double) }
    private(set) var exportPhase: ExportPhase = .idle
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
    /// 이동 드래그 중 끼워 넣을 자리(표시용)
    private(set) var moveInsertionIndex: Int?

    init() {
        player.actionAtItemEnd = .pause
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
    var canExport: Bool { !timeline.isEmpty && exportPhase == .idle }

    // MARK: 가져오기

    /// 한 번에 고른 파일 묶음을 검사한다(파일별 병렬). 거부 이유는 묶음이 끝난 뒤 알림 하나로 보인다.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing += urls.count
        let s = settings
        Task {
            var rejected: [String] = []
            await withTaskGroup(of: (Int, URL, Result<MediaAsset, Error>).self) { g in
                for (i, url) in urls.enumerated() {
                    g.addTask { do { return (i, url, .success(try await MediaProbe.inspect(url, settings: s))) } catch { return (i, url, .failure(error)) } }
                }
                var results: [(Int, URL, Result<MediaAsset, Error>)] = []
                for await r in g { results.append(r); importing -= 1 }
                for (_, url, r) in results.sorted(by: { $0.0 < $1.0 }) {   // 고른 순서대로 목록에 넣는다
                    switch r {
                    case .success(let a):
                        if assets.contains(where: { $0.identity.sameFile(as: a.identity) }) {
                            statusMessage = "이미 가져온 파일입니다: \(url.lastPathComponent)"; continue
                        }
                        assets.append(a)
                        history.replaceWithoutUndo(timeline.registering(a))
                        Self.log.info("imported media frames=\(a.frameCount)")
                    case .failure(let e):
                        rejected.append("\(url.lastPathComponent): \((e as? ProbeError)?.description ?? e.localizedDescription)")
                    }
                }
            }
            if !rejected.isEmpty { presentAlert(AlertInfo(title: Self.rejectTitle, message: rejected.joined(separator: "\n\n"))) }
        }
    }
    static let rejectTitle = "가져올 수 없는 파일"

    /// 알림 표시: 떠 있는 알림이 있으면 대기열에 넣고, 사용자가 닫은 뒤 차례로 띄운다.
    func presentAlert(_ a: AlertInfo) {
        let buttons = a.buttons ?? (a.revealURL == nil ? ["확인"] : ["Finder에서 보기", "닫기"])
        let req = AlertPresenter.Request(title: a.title, message: a.message, buttons: buttons, destructiveIndex: a.destructiveIndex, bringToFront: a.bringToFront) { [weak self] i in
            if a.buttons == nil, i == 0, let u = a.revealURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            self?.shownAlerts.removeFirst()
            self?.alert = self?.shownAlerts.first
            a.onButton?(i)
        }
        shownAlerts.append(a)
        if alert == nil { alert = a }
        alerts.enqueue(req)
    }
    /// 표시 중·대기 중 알림 사본(순서대로). 첫 항목이 화면에 떠 있는 알림이다.
    private var shownAlerts: [AlertInfo] = []

    func presentImportPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.movie]
        p.message = "가져올 영상 파일을 고르세요(M1: 30 fps H.264·HEVC, 10분 이하)."
        if p.runModal() == .OK { importFiles(p.urls) }
    }

    // MARK: 편집(실행 취소 대상)

    private func commit(_ make: (Timeline) throws -> Timeline, focus: UUID?, select: UUID? = nil) {
        pauseForEdit()
        do {
            let t = try make(timeline)
            history.apply(t, focus: focus)
            selection = select ?? focus
            statusMessage = nil
            timelineChanged()
        } catch let e as EditError {
            statusMessage = e.description
        } catch { statusMessage = error.localizedDescription }
    }

    func addToTimeline(_ mediaID: UUID, at index: Int? = nil) {
        let cid = UUID()
        commit({ try $0.inserting(media: mediaID, at: index, clipID: cid) }, focus: cid)
    }

    /// 분할: 선택한 클립(없으면 재생 헤드 아래 클립)을 재생 헤드에서 나눈다. 클립 내부에서만.
    func splitAtPlayhead() {
        let target = selection ?? timeline.clipIndex(atFrame: playhead).map { timeline.clips[$0].id }
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
        selection = f.flatMap { timeline.index(of: $0) != nil ? $0 : nil }
        timelineChanged()
    }
    func redo() {
        guard history.canRedo else { return }
        pauseForEdit()
        let f = history.redo()
        selection = f.flatMap { timeline.index(of: $0) != nil ? $0 : nil }
        timelineChanged()
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
        let t = (try? (edge == .start ? base.trimmingStart(clip: id, by: delta) : base.trimmingEnd(clip: id, by: delta))) ?? base
        history.updateGesture(t, focus: id)
    }
    func updateMove(_ id: UUID, toIndex: Int) {
        guard let base = gestureBase else { return }
        moveInsertionIndex = toIndex
        history.updateGesture((try? base.moving(clip: id, toIndex: toIndex)) ?? base, focus: id)
    }
    func commitGesture() {
        guard gestureBase != nil else { return }
        history.commitGesture(); gestureBase = nil; moveInsertionIndex = nil
        timelineChanged()
    }
    func cancelGesture() {
        guard gestureBase != nil else { return }
        history.cancelGesture(); gestureBase = nil; moveInsertionIndex = nil
        timelineChanged()
    }

    // MARK: 프리뷰

    /// 타임라인이 바뀌면: 재생 헤드를 새 길이 안으로, composition을 비동기로 다시 만들고 오래된 결과는 버린다.
    func timelineChanged() {
        playhead = min(playhead, timeline.durationFrames)
        generation += 1
        let g = generation, snap = timeline, media = mediaByID, s = settings
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

    func startExport(_ d: ExportDestination) {
        let snap = timeline, media = mediaByID, s = settings, sources = assets, options = exportOptions
        exportPhase = .running(0)
        #if DEBUG
        exportProgressLog = []
        #endif
        exportTask = Task {
            let outcome: ExportOutcome
            do {
                let plan = try await CompositionPlanner.plan(snap, media: media, settings: s)   // 시작 시점 스냅샷
                outcome = await ExportService.export(plan, to: d, sources: sources, options: options) { p in
                    await MainActor.run { ProjectStore.shared.reportExportProgress(p) }   // 순서대로 전달
                }
            } catch { outcome = .failed(.export("\(error)")) }
            exportPhase = .idle
            exportTask = nil
            switch outcome {
            case .completed(let u): presentAlert(AlertInfo(title: "내보내기 완료", message: u.lastPathComponent, revealURL: u))
            case .cancelled: statusMessage = "내보내기를 취소했습니다. 대상 파일은 만들지 않았습니다."
            case .failed(let f): presentAlert(AlertInfo(title: "내보내기 실패", message: f.description))
            }
        }
    }
    func cancelExport() { exportTask?.cancel() }

    // MARK: 닫기·종료 보호(저장 기능은 M1 범위 밖)

    enum CloseIntent { case window, quit }
    /// 버리면 잃는 편집 작업이 있는가: 가져온 영상이나 타임라인(길이 > 0)이 있으면. 내보낸 파일은 편집 가능한 프로젝트가 아니다.
    var hasUnsavedWork: Bool { !assets.isEmpty || timeline.durationFrames > 0 }
    /// 사용자가 "버리고 닫기/종료"를 고른 뒤(이 실행이 끝날 때까지 유지)
    @ObservationIgnored private(set) var discardConfirmed = false
    /// 닫기 확인이 떠 있거나 대기 중(같은 확인을 겹쳐 띄우지 않음)
    @ObservationIgnored private(set) var closePromptPending = false
    @ObservationIgnored private var closeGuard: WindowCloseGuard?

    /// 확인 없이 닫을 수 있는가
    var canCloseWithoutPrompt: Bool { discardConfirmed || (!hasUnsavedWork && exportPhase == .idle) }

    /// 닫기·종료 요청. 확인이 필요하면 대기열 알림(취소가 기본)을 띄운다. proceed는 버리기를 확정했고 진행 중인 내보내기가
    /// 취소·정리된 뒤 불린다. cancel은 취소했거나 이미 같은 확인이 떠 있을 때 불린다.
    func requestDiscard(_ intent: CloseIntent, proceed: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void) {
        if canCloseWithoutPrompt { finishDiscard(proceed); return }
        if closePromptPending { cancel(); return }
        closePromptPending = true
        pauseForEdit()
        var msg = "ON THE FRAME은 아직 프로젝트를 저장할 수 없습니다. \(intent == .quit ? "종료하면" : "창을 닫으면") 가져온 영상 목록과 타임라인 편집 내용이 사라지고 되돌릴 수 없습니다.\n\n내보낸 영상 파일은 편집할 수 있는 프로젝트가 아니므로, 나중에 다시 열어 편집을 이어 갈 수 없습니다. 원본 파일과 이미 내보낸 파일은 그대로 남습니다."
        if exportPhase != .idle { msg += "\n\n진행 중인 내보내기는 취소되고 임시 파일은 정리됩니다. 대상 파일은 만들어지지 않습니다." }
        presentAlert(AlertInfo(title: intent == .quit ? "편집 내용을 버리고 종료할까요?" : "편집 내용을 버리고 창을 닫을까요?",
                               message: msg, buttons: ["취소", intent == .quit ? "버리고 종료" : "버리고 닫기"], destructiveIndex: 1, bringToFront: true,
                               onButton: { [weak self] i in
            guard let self else { return }
            self.closePromptPending = false
            if i == 1 { self.discardConfirmed = true; self.finishDiscard(proceed) } else { cancel() }
        }))
    }
    /// 진행 중인 내보내기가 있으면 취소하고 정리(임시 디렉터리 삭제)가 끝난 뒤 proceed
    private func finishDiscard(_ proceed: @escaping @MainActor () -> Void) {
        guard exportPhase != .idle else { proceed(); return }
        cancelExport()
        Task { @MainActor in
            while self.exportPhase != .idle { try? await Task.sleep(nanoseconds: 20_000_000) }
            proceed()
        }
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
            if ok { editorClosedByUser = true }
            return ok
        }
        requestDiscard(.window, proceed: { [weak w] in w?.performClose(nil) }, cancel: {})
        return false
    }
    #if DEBUG
    /// 자체 검사 전용: 검사 끝에 앱을 끝낼 때 확인 없이 끝낸다
    func discardConfirmedForTest() { discardConfirmed = true }
    var closeGuardInstalled: Bool { editorWindow?.delegate === closeGuard && closeGuard != nil }
    #endif

    /// 진행률 반영(ExportService가 순서대로 부른다). 값을 고치지 않고 그대로 보인다.
    private func reportExportProgress(_ p: Double) {
        guard case .running = exportPhase else { return }
        exportPhase = .running(p)
        #if DEBUG
        exportProgressLog.append(p)
        #endif
    }
    #if DEBUG
    /// 자체 검사 전용: 현재 내보내기에서 받은 진행률 순서
    var exportProgressLog: [Double] = []
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
}
