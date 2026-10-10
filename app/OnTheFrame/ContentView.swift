import AVFoundation
import OnTheFrameEngine
import SwiftUI
import UniformTypeIdentifiers

/// 화면 배치(M1): 위 툴바(프로젝트 이름·가져오기·내보내기), 왼쪽 영상 목록, 가운데 프리뷰·재생 제어, 오른쪽 선택한 클립 정보, 아래 타임라인.
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
                        MediaListView(store: store).frame(width: sp.media)
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
                Button { layout.toggleMedia() } label: { Label(layout.mediaCollapsed ? "목록 펼치기" : "목록 접기", systemImage: "sidebar.left") }
                    .help(layout.mediaCollapsed ? "영상 목록 펼치기" : "영상 목록 접기")
                Button { layout.toggleInspector() } label: { Label(layout.inspectorCollapsed ? "정보 펼치기" : "정보 접기", systemImage: "sidebar.right") }
                    .help(layout.inspectorCollapsed ? "클립 정보 펼치기" : "클립 정보 접기")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.presentImportPanel() } label: { Label("가져오기", systemImage: "square.and.arrow.down") }
                    .help("영상 파일 가져오기(⌘I)")
                Button { store.presentExportPanel() } label: { Label("내보내기", systemImage: "square.and.arrow.up") }
                    .help("MP4로 내보내기(⌘E)").disabled(!store.canExport)
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
                else if let ip = store.importProgress { ImportProgressCard(progress: ip) { store.cancelImport() } }
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

// MARK: - 왼쪽: 영상 목록

struct MediaListView: View {
    @Bindable var store: ProjectStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("영상").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
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
                            Button("미디어 재연결…") { store.relinkMedia(r.id) }.controlSize(.small)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("찾을 수 없는 원본 \(r.name)")
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 8)
            }
            if store.assets.isEmpty && store.missingMedia.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "film.stack").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("가져온 영상이 없습니다").foregroundStyle(.secondary)
                    Button("영상 가져오기…") { store.presentImportPanel() }
                    Text("파일을 여기로 끌어 놓아도 됩니다.").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                List(store.assets) { a in
                    HStack(spacing: 8) {
                        Image(systemName: "film").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).lineLimit(1).truncationMode(.middle)
                            Text("\(store.settings.timecode(a.frameCount)) · \(Int(a.displaySize.width))×\(Int(a.displaySize.height)) · \(a.timing.label)\(a.hasAudio ? "" : " · 소리 없음")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.addToTimeline(a.id) } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.borderless).help("타임라인 끝에 추가")
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
                PlayerLayerView(player: store.player)
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

/// AVPlayerLayer 호스트(재생 제어는 SwiftUI 쪽에 둔다)
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerNSView { let v = PlayerNSView(); v.playerLayer.player = player; return v }
    func updateNSView(_ v: PlayerNSView, context: Context) { if v.playerLayer.player !== player { v.playerLayer.player = player } }
}
final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}

// MARK: - 오른쪽: 선택한 클립 정보

struct InspectorView: View {
    @Bindable var store: ProjectStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("클립 정보").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let id = store.selection, let c = store.timeline.clip(id), let m = store.mediaByID[c.mediaID], let lane = store.timeline.lane(of: id) {
                    let tc = store.settings.timecode
                    Group {
                        row("원본", m.name)
                        row("레인", store.timeline.laneName(lane) + (lane == .video ? " (영상)" : " (원본 소리)"))
                        row("원본 구간", "\(tc(c.sourceIn)) – \(tc(c.sourceOut))")
                        row("타임라인", "\(tc(c.start)) – \(tc(c.end))")
                        row("길이", tc(c.length))
                        row("원본 크기", "\(Int(m.displaySize.width))×\(Int(m.displaySize.height))")
                        row("원본 프레임레이트", m.timing.label)   // 원본 구간은 원본 시작에서 잰 시각(타임라인 30 fps 단위)
                        row("연결", linkText(id))
                    }
                    if store.linkCandidate != nil {
                        Text(store.canLink ? "⌘-클릭한 클립과 연결할 수 있습니다(타임라인 > 연결)." : "⌘-클릭한 클립과는 연결할 수 없습니다(같은 원본의 연결되지 않은 영상·소리 한 쌍만).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("타임라인에서 클립을 선택하면 정보가 표시됩니다.").foregroundStyle(.secondary).font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
    /// 연결 상태·어긋남(프레임과 초)
    func linkText(_ id: UUID) -> String {
        guard store.timeline.partner(of: id) != nil else {
            return store.timeline.movesFreely(id) ? "연결 안 됨(따로 이동)" : "연결 안 됨(원본에 소리 없음)"
        }
        guard let o = store.timeline.syncOffset(of: id) else { return "연결됨" }
        if o == 0 { return "연결됨 · 동기 맞음" }
        return String(format: "연결됨 · 소리 어긋남 %@%d프레임(%@%.2f초)", o > 0 ? "+" : "−", abs(o), o > 0 ? "+" : "−", Double(abs(o)) / 30)
    }
    func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.callout).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
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
    let progress: Double?
    let timeLine: String?
    let cancelTitle: String
    let cancelling: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(OTFTheme.primaryText).lineLimit(1)
                Spacer(minLength: 8)
                if let percentText {
                    Text(percentText).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(OTFTheme.primaryText)
                }
            }
            ForEach(infoLines, id: \.self) { d in
                Text(d).font(.system(size: 13)).foregroundStyle(OTFTheme.secondaryText).lineLimit(1).truncationMode(.middle).monospacedDigit()
                    .help(d)
            }
            OTFProgressBar(value: progress)
                .accessibilityElement()
                .accessibilityLabel(title)
                .accessibilityValue(percentText ?? "진행률 알 수 없음")
            HStack(spacing: 10) {
                if let timeLine {
                    Text(timeLine).font(.system(size: 13)).monospacedDigit().foregroundStyle(OTFTheme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(cancelling ? "취소하는 중…" : cancelTitle, action: onCancel)
                    .buttonStyle(OTFCardButtonStyle())
                    .disabled(cancelling)
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

/// 가져오기 카드: 현재 파일과 끝난 수/전체 수. 파일 안 진행률은 알 수 없어 진행률 없는 막대.
struct ImportProgressCard: View {
    let progress: ProjectStore.ImportProgress
    let onCancel: () -> Void
    var body: some View {
        var lines = ["\(progress.completed)/\(progress.total)개 확인 완료"]
        if let n = progress.currentName, progress.completed < progress.total, !progress.cancelling { lines.insert(n, at: 0) }
        return TaskProgressCard(title: progress.cancelling ? "가져오기 취소하는 중…" : "영상 가져오는 중…", percentText: nil, infoLines: lines,
                                progress: nil, timeLine: nil, cancelTitle: "취소", cancelling: progress.cancelling, onCancel: onCancel)
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
