import AVFoundation
import OnTheFrameEngine
import SwiftUI
import UniformTypeIdentifiers

/// 화면 배치: 위 툴바(프로젝트 이름·가져오기·내보내기), 왼쪽 패널(탭: 미디어 목록 / 클립 조정), 가운데 프리뷰·재생 제어,
/// 오른쪽 선택한 클립 정보(읽기 전용), 아래 타임라인. 편집할 수 있는 값은 왼쪽 "클립 조정" 탭과 레인 머리 메뉴에만 둔다(2026-10-11).
struct ContentView: View {
    @Bindable var store: ProjectStore
    @Bindable var layout = EditorLayout.shared

    var body: some View {
        // 편집기 배치(A-012): 위 패널 70% · 타임라인 30%, 위는 목록 20% · 프리뷰 60% · 정보 20%(나눔선 두께 제외).
        // 나눔선을 끌면 비율을 바꾸고 기억한다(EditorLayout). 패널은 최소 크기를 지키고 안에서 스크롤한다.
        GeometryReader { g in
            let sp = layout.split(for: g.size)
            let availW = max(1, g.size.width - 2 * EditorLayout.divider), availH = max(1, g.size.height - EditorLayout.divider)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if !layout.mediaCollapsed {
                        LeftPanel(store: store, layout: layout).frame(width: sp.media)
                        SplitDivider(axis: .vertical, help: "목록 너비") { start, d in
                            let w = min(max(start * availW + d, EditorLayout.minMedia), availW - sp.inspector - EditorLayout.minPreview)
                            layout.mediaFraction = Double(w / availW)
                        } begin: { layout.mediaFraction } end: { layout.saveFractions() }
                    }
                    PreviewPane(store: store).frame(width: sp.preview)
                    if !layout.inspectorCollapsed {
                        SplitDivider(axis: .vertical, help: "정보 너비") { start, d in
                            let w = min(max(start * availW - d, EditorLayout.minInspector), availW - sp.media - EditorLayout.minPreview)
                            layout.inspectorFraction = Double(w / availW)
                        } begin: { layout.inspectorFraction } end: { layout.saveFractions() }
                        InspectorView(store: store).frame(width: sp.inspector)
                    }
                }
                .frame(height: sp.upper)
                SplitDivider(axis: .horizontal, help: "타임라인 높이") { start, d in
                    let h = min(max(start * availH + d, EditorLayout.minUpper), availH - EditorLayout.minTimeline)
                    layout.upperFraction = Double(h / availH)
                } begin: { layout.upperFraction } end: { layout.saveFractions() }
                TimelinePane(store: store).frame(height: sp.timeline)
            }
            .onAppear { layout.lastContentSize = g.size; layout.lastSplit = sp }
            .onChange(of: sp) { _, v in layout.lastContentSize = g.size; layout.lastSplit = v }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(store.projectName + (store.isDirty ? " •" : "")).font(.headline).padding(.horizontal, 6)
                    .help(store.isDirty ? "저장하지 않은 변경 사항이 있습니다" : (store.projectURL?.path ?? "아직 저장하지 않은 프로젝트"))
            }
            // 목록·정보 패널 접기/펼치기(펼치면 이전 너비, 남는 폭은 프리뷰가 쓴다)
            ToolbarItemGroup(placement: .navigation) {
                Button { layout.toggleMedia() } label: { Label(layout.mediaCollapsed ? "왼쪽 패널 펼치기" : "왼쪽 패널 접기", systemImage: "sidebar.left") }
                    .help(layout.mediaCollapsed ? "미디어·클립 조정 패널 펼치기" : "미디어·클립 조정 패널 접기")
                Button { layout.toggleInspector() } label: { Label(layout.inspectorCollapsed ? "정보 펼치기" : "정보 접기", systemImage: "sidebar.right") }
                    .help(layout.inspectorCollapsed ? "클립 정보 펼치기" : "클립 정보 접기")
            }
            // 편집 도구(D-030): 선택(V)·자르기(C). 도구만 바꾼다(끌기 중에는 바꾸지 않음).
            ToolbarItem(placement: .principal) {
                Picker("편집 도구", selection: Binding(get: { store.tool }, set: { store.setTool($0) })) {
                    Label("선택 도구", systemImage: "cursorarrow").tag(ProjectStore.EditTool.selection).help("선택 도구 (V)")
                    Label("자르기 도구", systemImage: "scissors").tag(ProjectStore.EditTool.cut).help("자르기 도구 (C): 클립을 누른 위치에서 자르기")
                    Label("텍스트 도구", systemImage: "textformat").tag(ProjectStore.EditTool.text).help("텍스트 도구 (T): 프리뷰 화면을 눌러 그 자리에 자막 만들기·고치기")
                }
                .pickerStyle(.segmented).labelStyle(.iconOnly).fixedSize()
                .help("편집 도구: 선택 (V) · 자르기 (C) · 텍스트 (T)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.presentImportPanel() } label: { Label("가져오기", systemImage: "square.and.arrow.down") }.disabled(!store.fileCommandsAvailable)
                    .help("영상·소리 파일 가져오기(⌘I)")
                Button { store.presentExportPanel() } label: { Label("내보내기", systemImage: "square.and.arrow.up") }
                    .help("MP4로 내보내기(⌘E)").disabled(!store.canExport || !store.fileCommandsAvailable)
            }
        }
        .navigationTitle(store.windowTitle)
        .onChange(of: store.isDirty) { _, _ in store.updateWindowDocumentState() }
        .background(WindowAccessor { store.attachEditorWindow($0) })
        // 가져오기·내보내기 진행은 창을 막지 않는 카드로 보인다(A-011). 두 작업은 차례로만 진행하므로 카드는 하나다.
        // 내보내기는 시작 시점 스냅샷이므로 편집을 계속해도 결과가 바뀌지 않는다.
        // 카드는 편집기 루트 겹침의 가운데(창 크기를 바꿔도 가운데). 겹침은 카드 크기만 차지해 카드만 포인터를 받는다.
        .overlay(alignment: .center) {
            Group {
                if store.exportPhase != .idle { ExportProgressCard(store: store) }
                else if let ip = store.importProgress { ImportProgressCard(store: store, progress: ip) { store.cancelImport() } }
                else if let op = store.openProgress { OpenProgressCard(store: store, progress: op) { store.cancelOpen() } }
                else if let d = store.importDone { ImportDoneCard(done: d) }
            }
            #if DEBUG
            .background(GeometryReader { g in Color.clear.preference(key: CardFrameKey.self, value: g.frame(in: .named("editorRoot"))) })
            #endif
            .padding(.horizontal, 24)   // 좁은 창에서도 양옆 여백
        }
        .coordinateSpace(name: "editorRoot")
        #if DEBUG
        .background(GeometryReader { g in Color.clear.onAppear { store.editorRootSize = g.size }.onChange(of: g.size) { _, v in store.editorRootSize = v } })
        .onPreferenceChange(CardFrameKey.self) { f in store.progressCardFrame = f }
        #endif
        // 알림은 AlertPresenter가 AppKit 시트로 띄운다(SwiftUI .alert 다리를 쓰지 않음, AlertPresenter.swift 참조).
        .onAppear { store.alerts.windowAvailable() }
    }
}

/// 편집기 창을 store에 알린다(단축키 경로가 키 창·시트·첫 응답자를 판단하는 데 쓴다).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> AccessorView { AccessorView(onWindow: onWindow) }
    func updateNSView(_ v: AccessorView, context: Context) {}
    final class AccessorView: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let w = window { onWindow(w) } }
        /// 보조 처리 층: 창이 키 등가물(⌘ 조합)을 보기 계층에 물을 때(주 메뉴보다 먼저). 로컬 감시가 이미 처리했으면 여기 오지 않는다.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command), KeyRouting.route(event, layer: "performKeyEquivalent", store: ProjectStore.shared) { return true }
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// 끌 수 있는 나눔선(1 pt 선 + 넓은 잡는 영역, 크기 조절 커서). change(시작 비율, 끈 거리).
struct SplitDivider: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    let help: String
    let change: (CGFloat, CGFloat) -> Void
    let begin: () -> Double
    let end: () -> Void
    @State private var start: CGFloat?
    init(axis: Axis, help: String, change: @escaping (CGFloat, CGFloat) -> Void, begin: @escaping () -> Double, end: @escaping () -> Void) {
        self.axis = axis; self.help = help; self.change = change; self.begin = begin; self.end = end
    }
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor))
            .frame(width: axis == .vertical ? EditorLayout.divider : nil, height: axis == .horizontal ? EditorLayout.divider : nil)
            .overlay {
                Color.clear
                    .frame(width: axis == .vertical ? 9 : nil, height: axis == .horizontal ? 9 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            if start == nil { start = CGFloat(begin()) }
                            change(start!, axis == .vertical ? v.translation.width : v.translation.height)
                        }
                        .onEnded { _ in start = nil; end() })
                    .help(help)
            }
            .zIndex(1)
            .accessibilityLabel(help)
    }
}

// MARK: - 왼쪽: 탭(미디어 목록 / 클립 조정)

/// 왼쪽 패널(2026-10-11): 맨 위 탭으로 미디어 목록과 클립 조정을 바꾼다. 고른 탭은 EditorLayout이 기억하고, 클립을 골라도 탭을 바꾸지 않는다.
struct LeftPanel: View {
    @Bindable var store: ProjectStore
    @Bindable var layout: EditorLayout
    var body: some View {
        VStack(spacing: 0) {
            Picker("왼쪽 패널", selection: $layout.leftTab) {
                Text("미디어").tag(EditorLayout.LeftTab.media)
                Text("클립 조정").tag(EditorLayout.LeftTab.adjust)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .accessibilityLabel("왼쪽 패널 탭")
            Divider()
            switch layout.leftTab {
            case .media: MediaListView(store: store)
            case .adjust: AdjustmentsView(store: store)
            }
        }
    }
}

struct MediaListView: View {
    @Bindable var store: ProjectStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 찾을 수 없는 원본(A-013): 따로 보이고 재연결을 권한다
            if !store.missingMedia.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.timeline.media.filter { store.missingMedia[$0.id] != nil }) { r in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).lineLimit(1).truncationMode(.middle)
                                Text(store.missingMedia[r.id] ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("미디어 재연결…") { store.relinkMedia(r.id) }.controlSize(.small).disabled(!store.fileCommandsAvailable)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("찾을 수 없는 원본 \(r.name)")
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 8).padding(.top, 6)
            }
            if store.assets.isEmpty && store.missingMedia.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "film.stack").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("가져온 미디어가 없습니다").foregroundStyle(.secondary)
                    Button("영상·소리 가져오기…") { store.presentImportPanel() }.disabled(!store.fileCommandsAvailable)
                    Text("파일을 여기로 끌어 놓아도 됩니다.").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                List(store.assets) { a in
                    HStack(spacing: 8) {
                        Image(systemName: a.hasVideo ? "film" : "waveform").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).lineLimit(1).truncationMode(.middle)
                            Text(a.hasVideo ? "\(store.settings.timecode(a.frameCount)) · \(Int(a.displaySize.width))×\(Int(a.displaySize.height)) · \(a.timing.label)\(a.hasAudio ? "" : " · 소리 없음")"
                                 : "\(AudioFormatText.duration(a)) · \(AudioFormatText.describe(a))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.addToTimeline(a.id) } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.borderless).help(a.hasVideo ? "V1·A1(또는 고른 레인 쌍)의 마지막 클립 뒤에 추가 — 비었으면 0에서 시작" : "A1(또는 고른 오디오 레인)의 마지막 클립 뒤에 추가 — 비었으면 0에서 시작")
                    }
                    .draggable(a.id.uuidString)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in store.importFiles(urls); return true }
    }
}

// MARK: - 가운데: 프리뷰와 재생 제어

struct PreviewPane: View {
    @Bindable var store: ProjectStore
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerLayerView(store: store)
                // 편집 테두리(A-015): 화면 위 보기일 뿐 내보내기에는 들어가지 않는다
                PreviewOverlay(store: store, state: PreviewOverlay.state(store))
                // 자막 만들기·고르기·옮기기·글 편집(§44): 텍스트 도구·자막 위·편집 중에만 누름을 받고, 그 밖은 아래로 넘긴다
                SubtitlePreview(store: store, state: SubtitlePreview.state(store))
                // 찾을 수 없는 원본을 쓰는 구간: 의도한 빈틈과 구별해 알린다(A-013)
                if let name = store.missingNameAtPlayhead {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(.orange)
                        Text("원본 미디어를 찾을 수 없는 구간입니다").foregroundStyle(.white)
                        Text("\(name) — 파일 > 미디어 재연결…").font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
                if store.timeline.isEmpty && store.durationFrames == 0 {   // 빈틈만 남은 타임라인은 검정(안내 없음)
                    VStack(spacing: 6) {
                        Image(systemName: "play.rectangle").font(.system(size: 34)).foregroundStyle(.white.opacity(0.35))
                        Text("영상을 가져와 타임라인에 놓으면 여기에서 재생됩니다").foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            HStack(spacing: 14) {
                Button { store.step(-1) } label: { Image(systemName: "backward.frame.fill") }.help("이전 프레임(←)")
                Button { store.togglePlay() } label: { Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }.help("재생/일시정지(Space)")
                Button { store.step(1) } label: { Image(systemName: "forward.frame.fill") }.help("다음 프레임(→)")
                Text("\(store.settings.timecode(store.playhead)) / \(store.settings.timecode(store.durationFrames))")
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(store.timeline.isEmpty)
            .padding(8)
        }
    }
}

/// AVPlayerLayer 호스트(재생 제어는 SwiftUI 쪽에 둔다). 저장소의 프리뷰 화면 호스트로 등록한다(정지 화면).
struct PlayerLayerView: NSViewRepresentable {
    let store: ProjectStore
    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView(); v.playerLayer.player = store.player; store.previewHost = v; store.refreshPreviewSubtitles(); return v
    }
    func updateNSView(_ v: PlayerNSView, context: Context) {
        if v.playerLayer.player !== store.player { v.playerLayer.player = store.player }
        if store.previewHost !== v { store.previewHost = v; store.refreshPreviewSubtitles() }
    }
}
/// 프리뷰 화면: AVPlayerLayer 위에 끌기 무대(2026-10-11). 무대는 프리뷰 끌기 중 겹친 화면(InteractivePreview의 레이어 목록)을 보이고,
/// 새 프리뷰 항목이 표시될 준비가 되면(isReadyForDisplay) 내린다. 그동안 마지막으로 보인 화면을 유지해 검정이 비치지 않는다.
/// - 무대 구성: 검정 바탕 위에 출력 화면 크기(1920×1080)의 캔버스 레이어를 AVPlayerLayer의 resizeAspect와 같은 사각형에 맞춰 놓고
///   (배율 k = min(보기 너비/1920, 보기 높이/1080), 가운데), 캔버스 밖은 자른다(화면 밖으로 나간 부분은 내보내기에서도 잘림).
///   원본 프레임마다 CALayer 하나(내용 = 디코딩한 프레임, 끌기 중 바꾸지 않음)를 아래 레이어부터 쌓고 변형만 바꾼다.
///   그래서 끌기 중에는 GPU가 합성하고, 프레임마다 그림을 새로 만들거나 색을 다시 바꾸지 않는다.
/// - 레이어 변형: 레이어 안(왼쪽 아래 원점, 위 +Y) → 원본 픽셀(왼쪽 위 원점) → CompositionPlanner.layerTransform(출력, 아래 +Y)
///   → 캔버스(왼쪽 아래 원점). 암시적 애니메이션은 끈다.
final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    let stageLayer = CALayer()
    let canvas = CALayer()
    private var clipLayers: [UUID: CALayer] = [:]
    var renderSize = CGSize(width: 1920, height: 1080)
    private var readyKVO: NSKeyValueObservation?
    /// 이 항목이 표시될 준비가 되면 무대를 내린다
    private var releaseItem: AVPlayerItem?
    var isShowingStill: Bool { !stageLayer.isHidden }
    static let noActions: [String: CAAction] = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull(),
                                                "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(), "anchorPoint": NSNull()]
    #if DEBUG
    /// 자체 검사 전용: 무대 표시(목록 적용)·해제 수
    private(set) var stillShows = 0, stillReleases = 0
    #endif
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        stageLayer.backgroundColor = NSColor.black.cgColor
        stageLayer.isHidden = true
        stageLayer.actions = Self.noActions
        canvas.anchorPoint = .zero
        canvas.masksToBounds = true
        canvas.backgroundColor = NSColor.black.cgColor
        canvas.actions = Self.noActions
        stageLayer.addSublayer(canvas)
        layer?.addSublayer(stageLayer)
        subtitleHost.actions = Self.noActions
        layer?.addSublayer(subtitleHost)
        readyKVO = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.checkRelease() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds; stageLayer.frame = bounds
        let k = min(bounds.width / renderSize.width, bounds.height / renderSize.height)
        canvas.bounds = CGRect(origin: .zero, size: renderSize)
        canvas.position = CGPoint(x: (bounds.width - renderSize.width * k) / 2, y: (bounds.height - renderSize.height * k) / 2)
        canvas.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
        subtitleHost.frame = bounds
        if let sync = subtitleSync { sync.frame = subtitleHost.bounds; fit(subtitleCanvas, in: sync.bounds.size) }
        CATransaction.commit()
    }
    /// 출력 화면(1920×1080) 캔버스를 보기 안 resizeAspect 사각형에 맞춘다(무대 캔버스와 같은 식)
    private func fit(_ c: CALayer, in size: CGSize) {
        let k = min(size.width / renderSize.width, size.height / renderSize.height)
        c.bounds = CGRect(origin: .zero, size: renderSize)
        c.position = CGPoint(x: (size.width - renderSize.width * k) / 2, y: (size.height - renderSize.height * k) / 2)
        c.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
    }

    // MARK: 자막 층(2026-10-22, docs/SUBTITLE-DESIGN.md §43)
    //
    // 프리뷰 항목 시각에 묶인 AVSynchronizedLayer 안에 자막마다 CALayer 하나(내용 = 내보내기와 같은 SubtitleRenderer 그림, 같은 출력 사각형).
    // 불투명도 기본 0, [시작, 끝) 초 구간에만 1인 애니메이션으로 보인다(재생·멈춤·탐색 모두 항목 시각을 따른다).
    // 묶기는 항목이 readyToPlay가 된 뒤에 한다: 준비 전에 묶으면 묶이지 않은 채 남는 경우가 있었다(§21).
    // 타임라인 끝에서 끝나는 자막은 끝 위치(마지막 프레임 유지, D-018)에서도 보이도록 한 프레임 더 둔다.
    // 위 레인이 아래 레인 위에 그린다(그리기 순서 = 내보내기와 같음). 무대(정지 화면) 위에 둔다.
    let subtitleHost = CALayer()
    private(set) var subtitleSync: AVSynchronizedLayer?
    let subtitleCanvas = CALayer()
    /// 자막 ID → 층(편집 중 숨김·끌기 중 위치 바꿈, §44)
    private var subtitleLayers: [UUID: CALayer] = [:]
    /// 프리뷰 위에서 글을 고치는 자막: 그림을 숨긴다(편집 칸과 두 번 보이지 않게). 확정·취소하면 다시 보인다.
    var editingSubtitle: UUID? {
        didSet {
            guard oldValue != editingSubtitle else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (id, l) in subtitleLayers { l.isHidden = id == editingSubtitle }
            CATransaction.commit()
        }
    }
    /// 끌기 중 자막 하나의 그림·위치만 바꾼다(동기 층은 그대로). 놓거나 취소하면 저장소가 층 전체를 다시 넣는다.
    func moveSubtitleLayer(_ s: SubtitleItem) {
        guard let l = subtitleLayers[s.id] else { return }
        let r = SubtitleRenderer.shared.raster(s)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.contents = r.image
        l.frame = CGRect(x: r.rect.minX, y: renderSize.height - r.rect.maxY, width: r.rect.width, height: r.rect.height)
        CATransaction.commit()
    }
    private var subtitleKVO: NSKeyValueObservation?
    private var pendingSubtitleItem: AVPlayerItem?
    #if DEBUG
    /// 자체 검사 전용: 자막 층 상태(묶인 항목, 층 수)
    var subtitleBoundItem: AVPlayerItem? { subtitleSync?.playerItem }
    var subtitleLayerCount: Int { subtitleCanvas.sublayers?.count ?? 0 }
    func subtitleLayerForTest(_ id: UUID) -> CALayer? { subtitleLayers[id] }
    #endif
    func setSubtitles(_ items: [SubtitleItem], durationFrames: Int, fps: Double, item: AVPlayerItem?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        subtitleKVO = nil; pendingSubtitleItem = nil
        subtitleSync?.removeFromSuperlayer(); subtitleSync = nil
        subtitleCanvas.removeFromSuperlayer(); subtitleCanvas.sublayers = nil; subtitleLayers = [:]
        guard let item, !items.isEmpty else { return }
        let sync = AVSynchronizedLayer()
        sync.actions = Self.noActions
        sync.frame = subtitleHost.bounds
        subtitleCanvas.anchorPoint = .zero
        subtitleCanvas.masksToBounds = true
        subtitleCanvas.actions = Self.noActions
        fit(subtitleCanvas, in: sync.bounds.size)
        let h = renderSize.height
        var layers: [CALayer] = []
        for s in items {
            let r = SubtitleRenderer.shared.raster(s)
            let l = CALayer()
            l.actions = Self.noActions
            l.contents = r.image
            l.magnificationFilter = .linear; l.minificationFilter = .trilinear
            l.frame = CGRect(x: r.rect.minX, y: h - r.rect.maxY, width: r.rect.width, height: r.rect.height)   // 출력(위 원점) → 캔버스(아래 원점)
            l.opacity = 0
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 1
            a.beginTime = s.start == 0 ? AVCoreAnimationBeginTimeAtZero : Double(s.start) / fps
            // 끝 시각에 정확히 멈추면 애니메이션 끝이 포함되어 보였다(자체 검사: 프레임 [30,120)이 120에서 보임). 끝을 0.1 ms 당겨 반 열린 구간으로 맞춘다.
            a.duration = Double(s.length + (s.end == durationFrames ? 1 : 0)) / fps - 0.0001
            a.isRemovedOnCompletion = false
            a.fillMode = .removed
            l.add(a, forKey: "visible")
            l.isHidden = s.id == editingSubtitle
            subtitleLayers[s.id] = l
            layers.append(l)
        }
        subtitleCanvas.sublayers = layers
        sync.addSublayer(subtitleCanvas)
        subtitleHost.addSublayer(sync)
        subtitleSync = sync
        pendingSubtitleItem = item
        if item.status == .readyToPlay { bindPendingSubtitles(); return }
        subtitleKVO = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.bindPendingSubtitles() }
        }
    }
    /// 기다리던 항목이 준비되면 지금 자막 층에 묶는다(그사이 자막 층이 바뀌었으면 새 층의 항목을 본다)
    private func bindPendingSubtitles() {
        guard let it = pendingSubtitleItem, it.status == .readyToPlay, let sync = subtitleSync, sync.playerItem == nil else { return }
        sync.playerItem = it
        pendingSubtitleItem = nil; subtitleKVO = nil
    }
    /// 레이어 목록을 무대에 보인다(아래 먼저). 같은 클립의 레이어는 다시 쓰고 내용은 바뀐 때만 넣는다.
    func showStage(_ items: [InteractivePreview.DrawItem]) {
        releaseItem = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let h = renderSize.height
        var order: [CALayer] = []
        for it in items {
            let l = clipLayers[it.clipID] ?? {
                let n = CALayer(); n.anchorPoint = .zero; n.position = .zero; n.actions = Self.noActions
                n.magnificationFilter = .linear; n.minificationFilter = .trilinear
                clipLayers[it.clipID] = n; return n
            }()
            if l.contents as! CGImage? !== it.image { l.contents = it.image }
            l.bounds = CGRect(origin: .zero, size: it.size)
            let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: it.size.height)   // 레이어 안(위 +Y) → 원본 픽셀(아래 +Y)
            let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)               // 출력(아래 +Y) → 캔버스(위 +Y)
            l.setAffineTransform(flipIn.concatenating(it.transform).concatenating(flipOut))
            l.isHidden = false
            order.append(l)
        }
        let current = canvas.sublayers ?? []
        if current.count != order.count || !zip(current, order).allSatisfy({ $0 === $1 }) { canvas.sublayers = order }
        let shown = Set(items.map(\.clipID))
        for (id, _) in clipLayers where !shown.contains(id) { clipLayers[id] = nil }
        stageLayer.isHidden = false
        CATransaction.commit()
        #if DEBUG
        stillShows += 1
        #endif
    }
    func hideStill() {
        releaseItem = nil
        guard !stageLayer.isHidden else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stageLayer.isHidden = true; canvas.sublayers = nil; clipLayers = [:]
        CATransaction.commit()
        #if DEBUG
        stillReleases += 1
        #endif
    }
    /// 이 항목이 현재 항목이고 표시될 준비가 되면 내린다(이미 준비됐으면 바로)
    func releaseStill(when item: AVPlayerItem) {
        guard isShowingStill else { return }
        releaseItem = item
        checkRelease()
    }
    private func checkRelease() {
        guard let it = releaseItem, playerLayer.player?.currentItem === it, playerLayer.isReadyForDisplay else { return }
        hideStill()
    }
    #if DEBUG
    /// 자체 검사 전용: 무대 캔버스를 출력 크기(1920×1080, 첫 줄이 위)로 그린 그림. 화면에 보이는 것과 같은 레이어·변형을 Core Animation이 그린다.
    func stageSnapshot() -> CGImage? {
        guard isShowingStill else { return nil }
        let w = Int(renderSize.width), h = Int(renderSize.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        canvas.render(in: ctx)
        return ctx.makeImage()
    }
    #endif
}

// MARK: - 오른쪽: 선택한 클립·레인 정보(읽기 전용)

/// 소리 파일 형식 표시(A-014)
enum AudioFormatText {
    static func describe(_ a: MediaAsset) -> String {
        let codec: String
        switch a.codec { case "lpcm": codec = "PCM"; case "aac ": codec = "AAC"; case "alac": codec = "ALAC"; case ".mp3": codec = "MP3"; default: codec = a.codec.trimmingCharacters(in: .whitespaces) }
        let rate = a.audioSampleRate.map { $0 % 1000 == 0 ? "\($0 / 1000) kHz" : String(format: "%.1f kHz", Double($0) / 1000) } ?? "?"
        let ch = a.audioChannels == 1 ? "모노" : (a.audioChannels == 2 ? "스테레오" : "\(a.audioChannels ?? 0)채널")
        return "\(codec) · \(rate) · \(ch)"
    }
    /// 정확한 길이(표본 수 기준, 소수 셋째 자리 초)
    static func duration(_ a: MediaAsset) -> String {
        guard let n = a.audioSampleCount, let r = a.audioSampleRate, r > 0 else { return "?" }
        let s = Double(n) / Double(r)
        return String(format: "%d:%06.3f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// 오른쪽 "클립 정보"(2026-10-11부터 읽기 전용): 원본 이름·종류·해상도·프레임레이트·원본/타임라인 구간·길이·레인·연결/동기·화면 크기·위치.
/// 레인 머리를 고르면 레인 정보. 값을 바꾸는 칸은 왼쪽 "클립 조정" 탭과 레인 머리 메뉴에만 있다(같은 값을 두 곳에서 편집하지 않음).
struct InspectorView: View {
    @Bindable var store: ProjectStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("클립 정보").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let s = store.selectedSubtitle {
                    let tc = store.settings.timecode
                    row("종류", "자막")
                    row("글자", s.isBlank ? "(빈 자막 — 프리뷰·내보내기에 그리지 않음)" : s.text)
                    row("타임라인 구간", "\(tc(s.start)) – \(tc(s.end))")
                    row("길이", tc(s.length))
                    row("레인", laneText(s.lane))
                    row("글꼴", s.style.fontName + (SubtitleRenderer.fontAvailable(s.style.fontName) ? "" : " — 이 Mac에 없음(시스템 글꼴로 그림)"))
                    row("크기·위치", "\(NumberText.trim(s.style.size, 1)) pt · X \(NumberText.trim(s.style.x, 3)) · Y \(NumberText.trim(s.style.y, 3))")
                } else if let id = store.selection, let c = store.timeline.clip(id), let m = store.mediaByID[c.mediaID], let kind = store.timeline.lane(of: id) {
                    let tc = store.settings.timecode
                    Group {
                        row("원본", m.name)
                        row("종류", kind == .video ? "영상 클립" : (m.hasVideo ? "소리 클립(영상 파일의 소리)" : "소리 클립(소리 파일)"))
                        if m.hasVideo {
                            row("해상도", "\(Int(m.displaySize.width))×\(Int(m.displaySize.height))")
                            row("프레임레이트", m.timing.label)
                        } else {
                            row("소리 형식", AudioFormatText.describe(m))
                            row("원본 길이", AudioFormatText.duration(m))
                        }
                        row("원본 구간", "\(tc(c.sourceIn)) – \(tc(c.sourceOut))")   // 원본 시작에서 잰 시각(타임라인 30 fps 단위)
                        row("타임라인 구간", "\(tc(c.start)) – \(tc(c.end))")
                        row("길이", tc(c.length))
                        row("레인", laneText(c.lane))
                        row("연결", Self.linkText(store.timeline, id))
                        if let p = store.timeline.partner(of: id) { row(kind == .video ? "연결된 소리 레인" : "연결된 영상 레인", laneText(p.lane)) }
                        if let vc = store.transformClip { row(kind == .video ? "화면 크기·위치" : "연결된 영상의 크기·위치", Self.transformText(vc.effectiveTransform)) }
                        if let ac = store.audioTargetClip {
                            row(kind == .audio ? "클립 소리" : "연결된 소리 클립의 소리", Self.clipAudioText(ac.effectiveAudio, length: ac.length))
                        }
                    }
                    if store.linkCandidate != nil {
                        Text(store.canLink ? "⌘-클릭한 클립과 연결할 수 있습니다(타임라인 > 연결)." : "⌘-클릭한 클립과는 연결할 수 없습니다(같은 원본의 연결되지 않은 영상·소리 한 쌍만).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let l = store.inspectedLane {
                    row("레인", "\(store.timeline.laneLabel(l.id)) · \(l.name)")
                    row("종류", l.kind == .video ? "영상 레인(위 레인이 아래 레인을 가림)" : (l.kind == .audio ? "오디오 레인(음소거하지 않은 레인을 모두 더함)" : "자막 레인(모든 영상 위)"))
                    if l.kind == .audio { row("소리", l.muted ? "음소거" : "음량 \(l.volumePercent)%") }
                    if l.kind == .subtitle { row("자막", "\(store.timeline.subtitles(inLane: l.id).count)개") }
                    else { row("클립", "\(store.timeline.clips(inLane: l.id).count)개") }
                    Text("번호(V1·A1…)는 가운데 경계에서 센 위치이고 이름과 따로입니다. 이름·순서·음량은 왼쪽 \"클립 조정\" 탭이나 레인 머리 메뉴에서 바꿉니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("타임라인에서 클립이나 레인 머리를 선택하면 정보가 표시됩니다.").foregroundStyle(.secondary).font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
    func laneText(_ id: UUID?) -> String {
        guard let id, let l = store.timeline.laneInfo(id) else { return "—" }
        return "\(store.timeline.laneLabel(id)) · \(l.name)" + (l.kind == .audio && l.muted ? " (음소거)" : "")
    }
    /// 연결 상태·어긋남(프레임과 초)
    static func linkText(_ t: Timeline, _ id: UUID) -> String {
        guard t.partner(of: id) != nil else {
            guard let c = t.clip(id) else { return "연결 안 됨" }
            if t.mediaHasVideo[c.mediaID] == false { return "연결 안 됨(소리 파일)" }
            return t.mediaHasAudio[c.mediaID] == true ? "연결 안 됨(따로 이동)" : "연결 안 됨(원본에 소리 없음)"
        }
        guard let o = t.syncOffset(of: id) else { return "연결됨" }
        if o == 0 { return "연결됨 · 동기 맞음" }
        return String(format: "연결됨 · 소리 어긋남 %@%d프레임(%@%.2f초)", o > 0 ? "+" : "−", abs(o), o > 0 ? "+" : "−", Double(abs(o)) / 30)
    }
    /// 클립 음량·음소거·페이드(초, 보이는 길이). 자른 조각의 부분 페이드는 시작·끝 음량을 덧붙인다.
    static func clipAudioText(_ a: ClipAudio, length l: Int) -> String {
        var parts = [a.muted ? "클립 음소거" : "클립 음량 \(a.volumePercent)%"]
        let fi = a.fadeIn.visible(in: l), fo = a.fadeOut.visible(in: l)
        parts.append(fi == 0 ? "페이드 인 없음" : "페이드 인 \(FadeText.seconds(fi))초" + (a.fadeIn.offset > 0 ? "(\(Int((a.fadeIn.edgeGain * 100).rounded()))%부터)" : ""))
        parts.append(fo == 0 ? "페이드 아웃 없음" : "페이드 아웃 \(FadeText.seconds(fo))초" + (a.fadeOut.offset > 0 ? "(\(Int((a.fadeOut.edgeGain * 100).rounded()))%까지)" : ""))
        return parts.joined(separator: " · ")
    }
    static func transformText(_ t: ClipTransform) -> String {
        t.isIdentity ? "기본(100%, 가운데)" : "\(NumberText.trim(t.percent, 4))% · X \(NumberText.trim(t.x, 3)) · Y \(NumberText.trim(t.y, 3))"
    }
    func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.callout).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}

/// 페이드 길이 표시: 프레임(1/30 s) → 초(소수 둘째 자리, 끝 0 지움)
enum FadeText {
    static func seconds(_ frames: Int) -> String { NumberText.trim(Double(frames) / 30, 2) }
}

/// 소수 표시: 끝의 0을 지운 고정 소수(예: 68.9322, 181.235, 0)
enum NumberText {
    static func trim(_ v: Double, _ digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s == "-0" ? "0" : s
    }
}

// MARK: - 왼쪽 "클립 조정" 탭

/// 고른 클립(또는 레인 머리)에 맞는 편집 칸(2026-10-11): 영상 크기·위치·초기화, 소리 레인 음량·음소거, 대상 레인, 레인 이름·순서·삭제.
/// 좁은 패널에서 읽히도록 세로로 쌓고 스크롤한다. 끌기 중에는 칸을 잠근다(끌기 값은 보이기만 함).
struct AdjustmentsView: View {
    @Bindable var store: ProjectStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let s = store.selectedSubtitle {
                    target(icon: "captions.bubble", title: s.isBlank ? "빈 자막" : (s.text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "자막"),
                           subtitle: "자막 · \(laneText(s.lane))")
                    SubtitleAdjustView(store: store, item: s)
                } else if let id = store.selection, let c = store.timeline.clip(id), let kind = store.timeline.lane(of: id) {
                    target(icon: kind == .video ? "film" : "waveform", title: store.mediaByID[c.mediaID]?.name ?? "클립",
                           subtitle: "\(kind == .video ? "영상 클립" : "소리 클립") · \(laneText(c.lane))")
                    if let vc = store.transformClip {
                        AdjustSection(title: kind == .video ? "화면 크기·위치" : "연결된 영상의 크기·위치") { TransformAdjust(store: store, clip: vc) }
                    }
                    if let ac = store.audioTargetClip {
                        AdjustSection(title: kind == .audio ? "이 클립만 — 클립 소리" : "연결된 소리 클립만 — 클립 소리") {
                            ClipAudioAdjust(store: store, clip: ac, lane: ac.lane.flatMap { store.timeline.laneInfo($0) }, laneText: laneText(ac.lane))
                        }
                    }
                    AdjustSection(title: "레인") { LaneDestinationAdjust(store: store, id: id, clip: c) }
                } else if let l = store.selectedLane.flatMap({ store.timeline.laneInfo($0) }) {
                    target(icon: l.kind == .video ? "rectangle.stack" : (l.kind == .audio ? "speaker.wave.2" : "captions.bubble"), title: l.name,
                           subtitle: "\(store.timeline.laneLabel(l.id)) · \(l.kind == .video ? "영상 레인" : (l.kind == .audio ? "오디오 레인" : "자막 레인"))")
                    AdjustSection(title: "레인 설정") { LaneSettingsAdjust(store: store, lane: l) }
                    if l.kind == .audio { AdjustSection(title: "레인 전체 — \(store.timeline.laneLabel(l.id))의 모든 클립") { AudioLaneAdjust(store: store, lane: l) } }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text("조정할 클립이 없습니다").foregroundStyle(.secondary)
                        Text("타임라인에서 클립을 고르면 화면 크기·위치, 그 클립의 음량·페이드, 레인을 여기에서 바꿀 수 있습니다. 레인 머리를 고르면 레인 이름·순서와 레인 전체 음량을 바꿉니다.")
                            .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }
    func target(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.middle).help(title).textSelection(.enabled)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
        }
    }
    func laneText(_ id: UUID?) -> String {
        guard let id, let l = store.timeline.laneInfo(id) else { return "—" }
        return "\(store.timeline.laneLabel(id)) · \(l.name)"
    }
}

/// 조정 묶음 제목 + 내용
struct AdjustSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(2)
            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 화면 크기·위치(A-015, 2026-10-11 소수 값). 크기 %(100 = 기본 맞춤, 소수 넷째 자리), X·Y(출력 화면 픽셀, 화면 가운데 기준, 오른쪽·아래가 +,
/// 소수 셋째 자리). 값을 입력하고 Return(또는 칸을 벗어남)이면 한 단계로 기록한다. 범위 밖 값은 범위 안으로 맞춘다.
/// 프리뷰 끌기 중에는 끌기 값을 보인다(칸은 잠김).
struct TransformAdjust: View {
    @Bindable var store: ProjectStore
    let clip: Clip
    @State private var scale: Double = 100
    @State private var x: Double = 0
    @State private var y: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("크기") {
                TextField("크기", value: $scale, format: .number.precision(.fractionLength(0...4)).grouping(.never)).onSubmit(apply)
                    .accessibilityLabel("크기 퍼센트")
                Text("%").font(.caption)
                Stepper("", onIncrement: { scale += 5; apply() }, onDecrement: { scale -= 5; apply() }).labelsHidden().accessibilityLabel("크기 5%씩")
            }
            row("X") {
                TextField("X", value: $x, format: .number.precision(.fractionLength(0...3)).grouping(.never)).onSubmit(apply).accessibilityLabel("가로 위치 픽셀")
                Text("px").font(.caption)
            }
            row("Y") {
                TextField("Y", value: $y, format: .number.precision(.fractionLength(0...3)).grouping(.never)).onSubmit(apply).accessibilityLabel("세로 위치 픽셀")
                Text("px").font(.caption)
            }
            Button("크기·위치 초기화") { store.setTransform(clip.id, nil) }.controlSize(.small).disabled(clip.transform == nil)
            Text("100%는 화면에 맞춘 원래 크기, X·Y는 화면 가운데에서 옮긴 출력 픽셀입니다. 프리뷰에서 테두리 안을 끌면 옮기고, 모서리를 끌면 비율을 유지해 크기를 바꿉니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
        .disabled(store.gestureBase != nil)
        .onAppear(perform: sync)
        .onChange(of: clip) { _, _ in sync() }
        .onChange(of: store.liveTransform?.transform) { _, _ in sync() }
    }
    func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 4) { Text(label).font(.caption).frame(width: 24, alignment: .leading); c() }
    }
    func sync() {
        let t = store.liveTransform.flatMap { $0.clip == clip.id ? $0.transform : nil } ?? clip.effectiveTransform
        scale = t.percent; x = t.x; y = t.y
    }
    func apply() {
        store.setTransform(clip.id, ClipTransform(scale: scale / 100, x: x, y: y).clamped)
        sync()
    }
}

/// 오디오 레인 음소거·음량(A-014). 음량은 0–100%, 슬라이더를 놓을 때(또는 숫자 칸에서 Return) 한 단계로 기록한다. 레인 전체에 적용된다
/// (2026-10-11부터 레인 머리를 골랐을 때만 보인다. 클립을 고르면 클립 음량·페이드가 보인다).
/// 정규화·리미터가 없어 여러 레인의 합이 크면 내보낸 소리가 잘릴 수 있다.
struct AudioLaneAdjust: View {
    @Bindable var store: ProjectStore
    let lane: Lane
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("레인 음소거", isOn: Binding(get: { lane.muted }, set: { store.setLaneMuted(lane.id, $0) }))
                .toggleStyle(.checkbox).accessibilityLabel("레인 음소거")
            VolumeRow(label: "레인 음량", value: lane.volumePercent, axLabel: "레인 음량") { store.setLaneVolume(lane.id, $0) }
                .id(lane.id)   // 다른 레인을 고르면 입력 중이던 숫자를 버린다(다음 레인에 적용되지 않게)
                .disabled(lane.muted)
            Text("이 레인의 모든 클립에 곱해집니다(클립마다 음량은 클립을 골라 따로 바꿉니다). 0%는 무음, 100%는 원래 크기이며, 자동으로 줄이지 않으므로 여러 레인의 합이 크면 소리가 잘릴 수 있습니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(store.gestureBase != nil)
    }
}

/// 음량 한 줄: 이름 + 슬라이더(끌기 한 번 = 한 단계, 끌기 중 Esc는 시작 값으로) + 숫자 칸(Return = 한 단계) + %.
/// 슬라이더는 AppKit 보기(GainSlider)라 끌기 중 Esc를 받는다(SwiftUI Slider는 끌기 중 키를 받지 못해 되돌릴 수 없었다).
struct VolumeRow: View {
    let label: String
    let value: Int
    let axLabel: String
    let commit: (Int) -> Void
    @State private var live: Int?
    @State private var text = 100
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).fixedSize()
            // 끌기가 끝나거나 Esc로 취소되면 숫자 칸을 저장된 값으로 되돌린다(놓아서 바뀐 값은 onChange(of: value)가 다시 맞춘다)
            GainSlider(value: value, axLabel: axLabel, onLive: { live = $0; text = $0 ?? value }, onCommit: commit)
                .frame(minWidth: 50, maxWidth: .infinity, minHeight: 18, maxHeight: 18)
            TextField(label, value: $text, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).font(.caption).monospacedDigit().frame(width: 40)
                .onSubmit { let v = max(0, min(100, text)); text = v; if v != value { commit(v) } }
                .accessibilityLabel("\(axLabel) 퍼센트")
            Text("%").font(.caption)
        }
        .onAppear { text = value }
        .onChange(of: value) { _, v in if live == nil { text = v } }
    }
}

/// 소리 클립 음량·음소거·페이드(2026-10-11). 이 클립에만 적용된다(같은 레인의 다른 클립·레인 음량은 그대로).
/// 페이드 길이는 초(1/30 s 격자로 맞춤), Return을 누르면 한 단계(누르지 않고 다른 곳을 고르면 입력은 버린다). 다른 쪽 페이드와 겹치지 않게 줄인다.
struct ClipAudioAdjust: View {
    @Bindable var store: ProjectStore
    let clip: Clip
    let lane: Lane?
    let laneText: String
    @State private var fadeIn: Double = 0
    @State private var fadeOut: Double = 0
    var body: some View {
        let a = clip.effectiveAudio
        VStack(alignment: .leading, spacing: 6) {
            Toggle("클립 음소거", isOn: Binding(get: { a.muted }, set: { store.setClipAudio(clip.id, muted: $0) }))
                .toggleStyle(.checkbox).accessibilityLabel("클립 음소거")
            VolumeRow(label: "클립 음량", value: a.volumePercent, axLabel: "클립 음량") { store.setClipAudio(clip.id, volumePercent: $0) }
                .id(clip.id)   // 다른 클립을 고르면 입력 중이던 숫자를 버린다(다음 클립에 적용되지 않게)
                .disabled(a.muted)
            fadeRow("페이드 인", $fadeIn, partial: a.fadeIn.offset > 0 ? "자른 조각: 원래 페이드의 뒷부분(\(Int((a.fadeIn.edgeGain * 100).rounded()))%에서 시작)" : nil) {
                if let f = frames(fadeIn) { store.setClipAudio(clip.id, fadeInFrames: f) }
            }
            fadeRow("페이드 아웃", $fadeOut, partial: a.fadeOut.offset > 0 ? "자른 조각: 원래 페이드의 앞부분(\(Int((a.fadeOut.edgeGain * 100).rounded()))%까지)" : nil) {
                if let f = frames(fadeOut) { store.setClipAudio(clip.id, fadeOutFrames: f) }
            }
            Text("클립 길이 \(FadeText.seconds(clip.length))초. 두 페이드는 겹치지 않게 줄어듭니다. 타임라인에서 소리 클립 위쪽 모서리의 손잡이를 끌어도 됩니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("레인 전체: \(laneText)" + (lane.map { $0.muted ? " — 음소거" : " — 음량 \($0.volumePercent)%" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let l = lane { Button("레인 조정…") { store.selectLane(l.id) }.controlSize(.small).help("레인 머리를 골라 레인 전체 음량·음소거를 바꿉니다") }
            }
            Text("실제 크기 = 클립 음량 × 레인 음량 × 페이드").font(.caption2).foregroundStyle(.tertiary)
        }
        .textFieldStyle(.roundedBorder)
        .disabled(store.gestureBase != nil)
        .onAppear(perform: sync)
        .onChange(of: clip) { _, _ in sync() }
    }
    func fadeRow(_ label: String, _ v: Binding<Double>, partial: String?, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.caption).frame(width: 58, alignment: .leading)
                TextField(label, value: v, format: .number.precision(.fractionLength(0...2)).grouping(.never)).onSubmit { apply(); sync() }
                    .accessibilityLabel("\(label) 초")
                Text("초").font(.caption)
            }
            if let partial { Text(partial).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    /// 초 → 프레임(2026-10-23 전체 검토): 숫자가 아니거나 무한이면 거부(nil, 칸은 sync로 되돌림 — 이전에는 0이 되어 페이드가 지워졌다),
    /// 30을 곱하기 전에 넉넉한 범위(0…2⁴⁰)로 맞춘다(이전: "1e308"에 멈춤). 클립 길이·다른 페이드에 맞추는 것은 지금처럼 모델(settingClipAudio)이 한다.
    func frames(_ sec: Double) -> Int? { NumericInput.scaledInt(sec, scale: 30, range: 0...(1 << 40)) }
    func sync() {
        let a = clip.effectiveAudio
        fadeIn = Double(a.fadeIn.visible(in: clip.length)) / 30; fadeOut = Double(a.fadeOut.visible(in: clip.length)) / 30
    }
}

/// 대상 레인(A-014): 클립(과 연결된 짝)의 레인. 위치는 그대로이고, 어느 쪽이든 겹치면 아무것도 옮기지 않는다.
struct LaneDestinationAdjust: View {
    @Bindable var store: ProjectStore
    let id: UUID
    let clip: Clip
    var body: some View {
        let t = store.timeline
        let kind = t.lane(of: id) ?? .video
        VStack(alignment: .leading, spacing: 6) {
            Text(kind == .video ? "이 영상 클립의 레인" : "이 소리 클립의 레인").font(.caption).foregroundStyle(.secondary)
            Picker("클립 레인", selection: Binding(get: { clip.lane ?? UUID() }, set: { store.relocateSelection(lane: $0, partnerLane: nil) })) {
                ForEach(t.lanesFromBoundary(kind)) { Text("\(t.laneLabel($0.id)) · \($0.name)").tag($0.id) }
            }
            .labelsHidden().controlSize(.small).accessibilityLabel("클립 레인")
            if let p = t.partner(of: id), let pk = t.lane(of: p.id) {
                Text(pk == .audio ? "연결된 소리의 레인" : "연결된 영상의 레인").font(.caption).foregroundStyle(.secondary)
                Picker("짝", selection: Binding(get: { p.lane ?? UUID() }, set: { store.relocateSelection(lane: nil, partnerLane: $0) })) {
                    ForEach(t.lanesFromBoundary(pk)) { Text("\(t.laneLabel($0.id)) · \($0.name)").tag($0.id) }
                }
                .labelsHidden().controlSize(.small).accessibilityLabel("연결된 짝의 레인")
            }
            Text("시각은 그대로입니다. 대상 레인에서 겹치면 옮기지 않습니다.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(store.gestureBase != nil)
    }
}

/// 레인 이름·순서·삭제(A-014). 이름은 Return을 누르면 한 단계로 바꾸고(누르지 않고 다른 곳을 고르면 입력은 버린다), 비우면 이전 이름을 유지한다.
struct LaneSettingsAdjust: View {
    @Bindable var store: ProjectStore
    let lane: Lane
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("이름").font(.caption).frame(width: 28, alignment: .leading)
                TextField("레인 이름", text: $name).textFieldStyle(.roundedBorder).onSubmit(commitName).accessibilityLabel("레인 이름")
            }
            HStack(spacing: 6) {
                Button { store.moveLane(lane.id, by: -1) } label: { Image(systemName: "arrow.up") }.help("레인을 위로").disabled(!store.canMoveLane(lane.id, by: -1))
                    .accessibilityLabel("레인을 위로")
                Button { store.moveLane(lane.id, by: 1) } label: { Image(systemName: "arrow.down") }.help("레인을 아래로").disabled(!store.canMoveLane(lane.id, by: 1))
                    .accessibilityLabel("레인을 아래로")
                Spacer(minLength: 4)
                Button("삭제…", role: .destructive) { store.requestRemoveLane(lane.id) }.disabled(lane.kind != .subtitle && store.timeline.lanes(lane.kind).count < 2)
            }
            .controlSize(.small)
            Text(lane.kind == .video ? "위 레인이 아래 레인을 가립니다." : (lane.kind == .audio ? "음소거하지 않은 오디오 레인을 모두 더합니다." : "자막은 모든 영상 위에 그리고, 위 자막 레인이 아래 자막 레인 위에 그립니다."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(store.gestureBase != nil)
        .onAppear { name = lane.name }
        .onChange(of: lane) { _, l in name = l.name }
    }
    func commitName() {
        if name != lane.name, !store.renameLane(lane.id, to: name) { name = lane.name }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = lane.name }
    }
}

// MARK: - 가져오기·내보내기 진행 카드

/// 진행 카드·완료 시트 공용 색(A-011 시각 조정). 영상 위·밝은/어두운 모양 어디서나 읽히도록 불투명 남색과 고정 글자색을 쓴다.
enum OTFTheme {
    static let navy = Color(red: 0x17 / 255, green: 0x23 / 255, blue: 0x34 / 255)          // #172334
    static let primaryText = Color.white
    static let secondaryText = Color(red: 0xCB / 255, green: 0xD5 / 255, blue: 0xE1 / 255)  // #CBD5E1
    static let accent = Color(red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255)         // #38BDF8 청록·파랑 채움
    static let track = Color(red: 0x0B / 255, green: 0x12 / 255, blue: 0x1C / 255)          // 어두운 막대 바탕
    static let border = Color.white.opacity(0.14)
    static let buttonFill = Color(red: 0x33 / 255, green: 0x41 / 255, blue: 0x55 / 255)     // #334155
    static let cornerRadius: CGFloat = 12
}

/// 진행 막대: 진행률이 있으면 채움, 없으면(nil) 움직이는 구간(꾸민 백분율 없음).
struct OTFProgressBar: View {
    let value: Double?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(OTFTheme.track).overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                if let v = value {
                    Capsule().fill(OTFTheme.accent).frame(width: max(0, min(1, v)) * g.size.width)
                } else {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        let w = g.size.width * 0.3
                        Capsule().fill(OTFTheme.accent).frame(width: w).offset(x: (g.size.width + w) * t - w)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 8)
    }
}

/// 작은 회전 표시(2026-10-11, 가져오기 현재 파일): 순수 SwiftUI 호(시스템 ProgressView는 화면 밖 그림에 빈 표시로 나와 자체 검사로 볼 수 없었다).
/// 돌아가는 것은 "진행 중"을 뜻할 뿐 진행률이 아니다.
struct OTFSpinner: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let a = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
            Circle().trim(from: 0, to: 0.72).stroke(OTFTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(a))
        }
        .frame(width: 12, height: 12)
    }
}

/// 취소 단추: 보이는 바탕·흰 글자·키보드 초점 표시(전체 키보드 접근에서 Tab으로 올 때)
struct OTFCardButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, primary: primary) }
    struct StyledLabel: View {
        let configuration: Configuration
        let primary: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primary ? Color(red: 0x08 / 255, green: 0x1A / 255, blue: 0x2B / 255) : OTFTheme.primaryText)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(primary ? OTFTheme.accent : OTFTheme.buttonFill)
                    .brightness(configuration.isPressed ? -0.08 : 0))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? OTFTheme.accent : Color.white.opacity(0.18), lineWidth: focused ? 2 : 1))
                .opacity(enabled ? 1 : 0.6)
        }
    }
}

/// 진행 카드(가져오기·내보내기 공용 모양). 작업 상태는 각 작업이 따로 가진다.
/// 순서: 제목·백분율 → 파일 이름·개수(있으면) → 진행 막대 → 경과·남은 시간(있으면) → 취소.
/// 편집기 루트 겹침의 가운데에 놓고, 카드 자체만 포인터를 받는다(편집기를 어둡게 하거나 막지 않음).
struct TaskProgressCard: View {
    let title: String
    let percentText: String?
    let infoLines: [String]
    /// 현재 항목(파일 이름 등)과 그 옆의 회전 표시(2026-10-11, 가져오기): 막대의 전체 진행률과 따로, 항목 하나의 진행률을 모를 때.
    var activity: String? = nil
    let progress: Double?
    let timeLine: String?
    /// nil이면 취소 단추 없음(끝난 상태 카드)
    let cancelTitle: String?
    let cancelling: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if progress == nil {   // 길이를 모르는 작업: 막대 대신 회전 표시(채워진 비율처럼 보이지 않게)
                    ProgressView().progressViewStyle(.circular).controlSize(.small).tint(OTFTheme.accent)
                        .accessibilityLabel("진행 중(진행률 알 수 없음)")
                }
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(OTFTheme.primaryText).lineLimit(1)
                Spacer(minLength: 8)
                if let percentText {
                    Text(percentText).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(OTFTheme.primaryText)
                }
            }
            if let activity {
                HStack(spacing: 7) {
                    OTFSpinner().accessibilityLabel("현재 파일 확인 중(파일 진행률 알 수 없음)")
                    Text(activity).font(.system(size: 13)).foregroundStyle(OTFTheme.primaryText).lineLimit(1).truncationMode(.middle).help(activity)
                }
            }
            ForEach(infoLines, id: \.self) { d in
                Text(d).font(.system(size: 13)).foregroundStyle(OTFTheme.secondaryText).lineLimit(1).truncationMode(.middle).monospacedDigit()
                    .help(d)
            }
            if let progress {
                OTFProgressBar(value: progress)
                    .accessibilityElement()
                    .accessibilityLabel(title)
                    .accessibilityValue(percentText ?? "")
            }
            HStack(spacing: 10) {
                if let timeLine {
                    Text(timeLine).font(.system(size: 13)).monospacedDigit().foregroundStyle(OTFTheme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let cancelTitle {
                    Button(cancelling ? "취소하는 중…" : cancelTitle, action: onCancel)
                        .buttonStyle(OTFCardButtonStyle())
                        .disabled(cancelling)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(minWidth: 0, idealWidth: 440, maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: OTFTheme.cornerRadius).fill(OTFTheme.navy))
        .overlay(RoundedRectangle(cornerRadius: OTFTheme.cornerRadius).stroke(OTFTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// 가져오기 카드(2026-10-11 갱신): 막대는 묶음 전체 진행률(처리한 파일 ÷ 전체, 받아들임·거부 모두, 반영 전에는 100% 아님).
/// 파일 하나의 진행률은 잴 수 없어 현재 파일 이름 옆에 회전 표시를 따로 둔다(막대에 움직이는 조각·꾸민 백분율 없음).
/// 처리한 수/전체 수, 경과 시간·현재 단계. 1초마다 경과 시간을 다시 그린다(단조 시계, 진행률에는 쓰지 않음).
struct ImportProgressCard: View {
    @Bindable var store: ProjectStore
    let progress: ProjectStore.ImportProgress
    let onCancel: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let f = progress.fraction
            let current = progress.completed < progress.total && !progress.cancelling ? progress.currentName : nil
            let stage = progress.cancelling ? "취소하는 중" : (progress.stage ?? "확인 준비 중")
            return TaskProgressCard(title: progress.cancelling ? "가져오기 취소하는 중…" : "미디어 가져오는 중…", percentText: ImportProgressCard.percent(f),
                                    infoLines: ["\(progress.completed)/\(progress.total)개 처리"], activity: current,
                                    progress: f, timeLine: ClockText.elapsed(store.monoSeconds() - progress.startedAt) + " · " + stage,
                                    cancelTitle: "취소", cancelling: progress.cancelling, onCancel: onCancel)
        }
    }
    /// 내림한 백분율(반올림으로 100%를 미리 보이지 않게)
    static func percent(_ f: Double) -> String { "\(Int((max(0, min(1, f)) * 100).rounded(.down)))%" }
}

/// 가져오기 완료 카드(2026-10-11): 묶음을 반영하고 하나 이상 추가한 뒤에만 100%. 잠깐 보인 뒤 사라진다(취소 단추 없음).
struct ImportDoneCard: View {
    let done: ProjectStore.ImportDone
    var body: some View {
        var parts = ["추가 \(done.added)개"]
        if done.rejected > 0 { parts.append("가져올 수 없음 \(done.rejected)개") }
        if done.skipped > 0 { parts.append("이미 있음 \(done.skipped)개") }
        return TaskProgressCard(title: "가져오기 완료", percentText: "100%", infoLines: ["\(done.total)/\(done.total)개 처리 · " + parts.joined(separator: " · ")],
                                progress: 1, timeLine: ClockText.elapsed(done.elapsed), cancelTitle: nil, cancelling: false, onCancel: {})
    }
}

/// 프로젝트 열기 카드(2026-10-11): 파일 읽기 → 원본 미디어 확인(k/n, 현재 원본 이름, 검사 단계), 경과 시간, 취소(현재 프로젝트 그대로).
struct OpenProgressCard: View {
    @Bindable var store: ProjectStore
    let progress: ProjectStore.OpenProgress
    let onCancel: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            var lines: [String] = []
            if progress.total > 0 { lines.append("원본 \(progress.completed)/\(progress.total)개 확인 완료") }
            if let n = progress.currentName, !progress.cancelling { lines.insert(n, at: 0) }
            return TaskProgressCard(title: progress.cancelling ? "열기 취소하는 중…" : "프로젝트 여는 중…", percentText: nil, infoLines: lines,
                                    progress: nil, timeLine: ClockText.elapsed(store.monoSeconds() - progress.startedAt) + " · " + (progress.cancelling ? "취소하는 중" : progress.stage),
                                    cancelTitle: "취소", cancelling: progress.cancelling, onCancel: onCancel)
        }
    }
}

/// 내보내기 카드: 진행률(1.0은 검증·승격 성공 뒤에만), 경과 시간, 남은 시간 추정. 1초마다 다시 그린다(단조 시계).
struct ExportProgressCard: View {
    @Bindable var store: ProjectStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = store.monoSeconds()
            let p: Double = { if case .running(let v) = store.exportPhase { return v }; return 0 }()
            TaskProgressCard(title: store.exportCancelling ? "내보내기 취소하는 중…" : "내보내는 중", percentText: String(format: "%.0f%%", (p * 100).rounded(.down)),
                             infoLines: [], progress: p,
                             timeLine: ClockText.elapsed(store.exportEstimator.elapsed(at: now)) + " · "
                                + (store.exportCancelling ? "취소 중" : ClockText.remaining(store.exportEstimator.remaining(at: now))),
                             cancelTitle: "취소", cancelling: store.exportCancelling) { store.cancelExport() }
        }
    }
}

#if DEBUG
/// 자체 검사 전용: 카드 테두리(편집기 루트 좌표)
struct CardFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let n = nextValue(); if n != .zero { value = n } }
}
#endif
