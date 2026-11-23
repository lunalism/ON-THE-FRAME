import AppKit
import OnTheFrameEngine
import SwiftUI

/// 아래 영역: 상태 줄·확대 조절 + AppKit 타임라인(왼쪽 고정 레인 머리, 눈금자, 영상 레인들·오디오 레인들, 재생 헤드). A-012, A-014.
struct TimelinePane: View {
    @Bindable var store: ProjectStore

    var body: some View {
        VStack(spacing: 0) {
          // LANE-VERTICAL-ZOOM-01: 레인 영역 위의 줄(툴바·안내 글·구분선)을 한 묶음으로 두고 그 높이를 잰다. 편집기 배치가 이 값으로
          // 레인이 모두 보이는 타임라인 패널 높이를 계산한다(`EditorLayout.timelineChrome`).
          VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("타임라인").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let m = store.statusMessage { Text(m).font(.callout).foregroundStyle(.orange).lineLimit(1) }
                Spacer()
                // TIMELINE-EDITING-01: 스냅(자석). 옮기기·트림이 다른 클립 가장자리와 재생 헤드에 붙는다(화면 8 pt).
                // The binding reads the store and writes through the controlled setter (rejected during a drag).
                Toggle(isOn: Binding(get: { store.snapEnabled }, set: { store.setSnapEnabled($0) })) {
                    Label("스냅", systemImage: "arrow.right.and.line.vertical.and.arrow.left")
                }
                .toggleStyle(.button).labelStyle(.iconOnly)
                .help(store.snapEnabled ? "스냅 켜짐: 옮기기·트림이 다른 클립 가장자리와 재생 헤드에 붙습니다(누르면 끔)"
                                        : "스냅 꺼짐: 옮기기·트림이 프레임 단위로만 움직입니다(누르면 켬)")
                .accessibilityLabel(store.snapEnabled ? "스냅 켜짐" : "스냅 꺼짐")
                .disabled(store.gestureBase != nil)
                Menu {
                    Button("영상·소리 레인 쌍 추가") { store.addLanePair() }
                    Button("영상 레인 추가") { store.addLane(.video) }
                    Button("오디오 레인 추가") { store.addLane(.audio) }
                    Button("자막 레인 추가") { store.addLane(.subtitle) }
                } label: { Label("레인 추가", systemImage: "plus.rectangle.on.rectangle") }
                    .menuStyle(.borderlessButton).fixedSize().help("새 영상 레인은 맨 위(V 번호 증가), 새 오디오 레인은 맨 아래(A 번호 증가), 새 자막 레인은 모든 영상 레인 위(S 번호 증가)에 추가")
                    .disabled(store.gestureBase != nil)
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $store.timelineZoom, in: 0.2...12).frame(width: 120).help("타임라인 확대")
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            if let error = store.imagePreviewError {
                Text(error)
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }
            Divider()
          }
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
              if h > 0, abs(h - EditorLayout.shared.timelineChrome) > 0.5 { EditorLayout.shared.timelineChrome = h }
          }
            ZStack {
                TimelineRepresentable(store: store, state: TimelineDrawState(store: store), pixelsPerFrame: store.timelineZoom,
                                      laneZoomRevision: LaneZoom.shared.revision)
                if store.timeline.isEmpty && store.durationFrames == 0 {
                    Text(store.assets.isEmpty ? "영상·소리 파일을 가져온 뒤 여기로 끌어 놓거나 목록의 + 단추를 누르세요"
                                              : "왼쪽 목록의 미디어를 레인에 끌어 놓거나 + 단추를 누르세요")
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
        }
    }
}

/// 그리기에 필요한 값의 사본(SwiftUI 관찰이 이 값의 변화를 감지한다)
struct TimelineDrawState: Equatable {
    var timeline: Timeline
    var names: [UUID: String]
    var selection: UUID?
    var selected: Set<UUID>
    var candidate: UUID?
    var selectedLane: UUID?
    var playhead: Int
    var proposalStart: Int?, proposalOK: Bool, proposalID: UUID?, proposalLane: UUID?
    /// 끌어 옮기기에서 붙은 위치(안내선)
    var snap: Int?
    /// TIMELINE-UI-POLISH-01: clip edges a Shift playhead snap landed on (vertical ▼/▲ marker pairs)
    var snapMarkers: [ProjectStore.SnapMarker]
    /// WAVEFORM-01: available sources (for waveform lookup) and the waveform result counter (redraw when peaks arrive)
    var media: [UUID: MediaAsset]
    var waveformRevision: Int
    /// 거부된 스펙트럼 트림 제안(2C-2, 같은 레인 겹침 — 빨간 상자): 항목과 제안 구간
    var trimRejectID: UUID?, trimRejectRange: Range<Int>?
    /// 찾을 수 없는 원본(미디어 id)
    var missing: Set<UUID>
    /// 편집 도구(선택·자르기, D-030)
    var tool: ProjectStore.EditTool
    /// 이 Mac에 없는 자막 글꼴(표시)
    var missingFonts: Set<String>
    @MainActor init(store: ProjectStore) {
        timeline = store.timeline
        names = Dictionary(uniqueKeysWithValues: store.assets.map { ($0.id, $0.name) })
        selection = store.selection
        selected = store.selectedIDs
        candidate = store.linkCandidate
        selectedLane = store.selectedLane
        playhead = store.playhead
        snap = store.snapGuide
        snapMarkers = store.snapMarkers
        media = store.mediaByID
        waveformRevision = store.waveforms.revision
        trimRejectID = store.spectrumTrimRejected?.id; trimRejectRange = store.spectrumTrimRejected?.range
        proposalStart = store.freeMoveProposal?.start; proposalOK = store.freeMoveProposal?.ok ?? true; proposalID = store.freeMoveProposal?.id; proposalLane = store.freeMoveProposal?.lane
        missing = Set(store.missingMedia.keys)
        tool = store.tool
        missingFonts = Set(store.missingSubtitleFonts)
        names = Dictionary(uniqueKeysWithValues: ProjectPersistence.references(store.timeline).map { ($0.id, $0.name) })
    }
}

struct TimelineRepresentable: NSViewRepresentable {
    let store: ProjectStore
    let state: TimelineDrawState
    let pixelsPerFrame: Double
    /// LANE-VERTICAL-ZOOM-01: changes whenever a lane height changes, so SwiftUI lays the timeline out again
    let laneZoomRevision: Int

    func makeNSView(context: Context) -> TimelineContainerView { TimelineContainerView(store: store) }
    func updateNSView(_ c: TimelineContainerView, context: Context) {
        let v = c.timelineView, sv = c.scrollView
        v.state = state
        let oldPPF = v.pixelsPerFrame, newPPF = CGFloat(pixelsPerFrame)
        // 가로 확대(2026-10-24, 소유자 요청): 확대 배율이 바뀌면 기준 시각을 보이는 영역의 같은 가로 자리에 둔다(아래 zoomAnchor)
        let anchor = oldPPF != newPPF ? c.zoomAnchor(playhead: state.playhead, oldPPF: oldPPF) : nil
        v.pixelsPerFrame = newPPF
        c.updateAutoFit()   // LANE-VERTICAL-ZOOM-01: lanes may have changed — fit before the document height is set below
        let w = max(sv.contentSize.width, TimelineNSView.inset * 2 + CGFloat(state.timeline.durationFrames) * v.pixelsPerFrame + 200)
        v.setFrameSize(NSSize(width: w, height: max(sv.contentSize.height, TimelineNSView.contentHeight(state.timeline.lanes))))
        if let anchor { c.applyZoomAnchor(anchor, ppf: newPPF) }
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
        c.header.lanes = state.timeline.lanes
        c.header.selectedLane = state.selectedLane
        c.header.needsDisplay = true
        c.header.syncZoomControls()
        c.ruler.needsDisplay = true   // TIMELINE-STICKY-RULER-01: same state, zoom and playhead as the lane content
    }
}

/// 레인 머리(왼쪽 고정, 가로 스크롤과 무관) + 가로로 스크롤하는 타임라인
final class TimelineContainerView: NSView {
    let header: LaneHeaderView
    let scrollView = NSScrollView()
    let timelineView: TimelineNSView
    /// TIMELINE-STICKY-RULER-01: the time ruler stays at the top of the timeline viewport. It is a sibling placed over the top
    /// `rulerHeight` strip of the scroll area (the same strip the lane header keeps free), so vertical scrolling moves only the
    /// lane rows under it. It draws and scrubs through `timelineView` with the lane content's horizontal scroll origin.
    let ruler: TimelineRulerView
    let store: ProjectStore
    init(store: ProjectStore) {
        self.store = store
        header = LaneHeaderView(store: store)
        timelineView = TimelineNSView(store: store)
        ruler = TimelineRulerView(timelineView: timelineView, scrollView: scrollView)
        super.init(frame: .zero)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.documentView = timelineView
        scrollView.scrollerInsets.top = TimelineNSView.rulerHeight   // the vertical scroller starts below the fixed ruler
        addSubview(header); addSubview(scrollView); addSubview(ruler)   // ruler last: above the scroll area
        // 세로 스크롤은 머리와 함께 움직이게 맞춘다(가로 스크롤은 머리에 영향 없음)
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.header.verticalOffset = self.scrollView.contentView.bounds.minY; self.header.needsDisplay = true
                    self.layoutRuler(); self.ruler.needsDisplay = true   // horizontal scroll moves the ruler's ticks; vertical does not move it
                    self.window?.invalidateCursorRects(for: self.timelineView)   // rows moved relative to the fixed ruler strip
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The fixed ruler covers the top strip of the visible lane area (the clip view, so a legacy scroller column is excluded).
    func layoutRuler() {
        let r = convert(scrollView.contentView.frame, from: scrollView)
        let f = NSRect(x: r.minX, y: r.minY, width: r.width, height: min(TimelineNSView.rulerHeight, r.height))
        if ruler.frame != f { ruler.frame = f; ruler.needsDisplay = true }
    }

    // MARK: 가로 확대 기준(2026-10-24, 소유자 요청: 0프레임이 아니라 빨간 재생 헤드를 기준으로 확대)
    //
    // 확대 배율이 바뀌면 기준 시각(프레임, 소수 가능)을 보이는 영역 안 같은 가로 자리(viewX)에 두도록 가로 스크롤을 함께 옮긴다.
    // - 재생 헤드가 보이는 영역 안이면 재생 헤드 시각과 그 자리. 밖이면 보이는 영역 가운데 시각과 가운데(재생 헤드로 뛰지 않음).
    // - 타임라인 처음·끝에서 그 자리를 지킬 수 없으면 스크롤 범위 안으로 맞춘다.
    // - 슬라이더를 이어서 움직이는 동안(그사이 손으로 스크롤하지 않았고 재생 헤드가 그대로면) 처음 잡은 기준을 다시 쓴다:
    //   매번 반올림된 스크롤 위치에서 다시 재면 조금씩 밀린다.
    // 세로 스크롤·레인 높이·클립·선택·재생 상태는 건드리지 않는다.
    struct ZoomAnchor: Equatable { let frame: Double; let viewX: CGFloat; let playhead: Int?; let usePlayhead: Bool }
    private var lastZoomAnchor: ZoomAnchor?
    private var lastZoomOriginX: CGFloat?, lastZoomWidth: CGFloat?
    func zoomAnchor(playhead: Int, oldPPF: CGFloat) -> ZoomAnchor {
        let vis = scrollView.contentView.bounds
        let px = TimelineNSView.inset + CGFloat(playhead) * oldPPF
        let playheadVisible = px >= vis.minX && px <= vis.maxX
        // 이어지는 확대: 마지막으로 맞춘 스크롤·보이는 폭 그대로(손으로 스크롤·창 크기 바꾸지 않음)이고, 기준 종류가 지금도 맞을 때만 다시 쓴다 —
        // 재생 헤드 기준이면 같은 재생 헤드가 여전히 보이고, 가운데 기준이면 재생 헤드가 여전히 밖(Codex 검토: 밖에서 확대한 뒤 보이는 곳을 눌러
        // 재생 헤드를 옮기고 다시 확대하면 예전 가운데 기준을 다시 써서 재생 헤드가 밀렸다)
        if let a = lastZoomAnchor, let x0 = lastZoomOriginX, let w0 = lastZoomWidth, abs(vis.minX - x0) < 0.5, abs(vis.width - w0) < 0.5,
           a.usePlayhead ? (a.playhead == playhead && playheadVisible) : !playheadVisible { return a }
        if playheadVisible {
            return ZoomAnchor(frame: Double(playhead), viewX: px - vis.minX, playhead: playhead, usePlayhead: true)
        }
        return ZoomAnchor(frame: Double((vis.midX - TimelineNSView.inset) / oldPPF), viewX: vis.width / 2, playhead: nil, usePlayhead: false)
    }
    func applyZoomAnchor(_ a: ZoomAnchor, ppf: CGFloat) {
        let clip = scrollView.contentView, vis = clip.bounds
        let maxX = max(0, timelineView.frame.width - vis.width)
        let x = min(max(TimelineNSView.inset + CGFloat(a.frame) * ppf - a.viewX, 0), maxX)
        clip.scroll(to: NSPoint(x: x, y: vis.minY))
        scrollView.reflectScrolledClipView(clip)
        lastZoomAnchor = a; lastZoomOriginX = clip.bounds.minX; lastZoomWidth = clip.bounds.width
    }

    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: LaneHeaderView.width, height: bounds.height)
        scrollView.frame = NSRect(x: LaneHeaderView.width, y: 0, width: max(0, bounds.width - LaneHeaderView.width), height: bounds.height)
        // LANE-SCROLL-CLIP-FIX-01: after a resize the clip view may clamp its scroll origin; keep the header rows on the same y.
        if header.verticalOffset != scrollView.contentView.bounds.minY { header.verticalOffset = scrollView.contentView.bounds.minY; header.needsDisplay = true }
        layoutRuler()
        if updateAutoFit() { refreshLaneGeometry() }   // LANE-VERTICAL-ZOOM-01: the visible lane area may have changed
    }

    // MARK: 처음 맞춤(Auto Fit, LANE-VERTICAL-ZOOM-01)
    //
    // 자동 맞춤 상태(`LaneZoom.autoFit`, 수동 확대 전·"모두 맞춤" 뒤)에서만 한다. 실제로 보이는 레인 영역 높이(스크롤 영역의 clip view)에
    // 모든 레인이 들어가도록 배율을 최소(0.7)…1 사이로 정한다. 최소 배율로도 넘치면 그 배율로 두고 세로 스크롤한다.
    // 타임라인 패널 자체의 높이는 편집기 배치(`EditorLayout.upperHeight`)가 같은 레인 목록으로 정한다.
    // 배치·상태 갱신 안에서 바로 계산하므로(관찰 상태를 바꾸지 않음) 같은 배치 패스에서 레인 머리·내용·문서 높이가 함께 맞는다.
    // 끌기 중에는 하지 않는다(끝난 뒤의 상태 갱신·배치에서 다시 한다).

    /// 보이는 레인 영역 높이(눈금자 띠 포함, 가로 스크롤 막대 제외)
    var visibleLaneHeight: CGFloat { scrollView.contentView.frame.height }
    /// 자동 맞춤 배율을 지금 보이는 영역과 레인 목록으로 다시 정한다. 바뀌었으면 true(호출 쪽이 `refreshLaneGeometry()`로 반영).
    @discardableResult
    func updateAutoFit() -> Bool {
        let zoom = LaneZoom.shared
        guard zoom.autoFit, window != nil, bounds.height > 0, store.gestureBase == nil else { return false }
        return zoom.updateFit(timelineView.lanes, visibleHeight: visibleLaneHeight)
    }
    /// 레인 높이가 바뀐 뒤: 문서 보기 높이·그리기·레인 머리·커서 영역을 새 높이로 맞춘다(클립 시각·가로 좌표는 건드리지 않는다).
    func refreshLaneGeometry() {
        let v = timelineView
        v.setFrameSize(NSSize(width: v.frame.width, height: max(scrollView.contentSize.height, TimelineNSView.contentHeight(v.lanes))))
        v.needsDisplay = true
        header.needsDisplay = true
        header.syncZoomControls()
        window?.invalidateCursorRects(for: v)
    }
}

/// TIMELINE-STICKY-RULER-01: the fixed time ruler above the vertically scrolling lanes. It has no time mapping of its own:
/// drawing calls `TimelineNSView.drawRuler`/`drawPlayhead` translated by the lane content's horizontal scroll origin, and
/// scrubbing converts the pointer through the document view, so ticks, playhead and clips always share one frame ↔ x mapping
/// (horizontal scroll and zoom included). Being opaque and on top, it also keeps clicks, context menus and cursors away from
/// lane rows scrolled under it.
final class TimelineRulerView: NSView {
    unowned let timelineView: TimelineNSView
    unowned let scrollView: NSScrollView
    init(timelineView: TimelineNSView, scrollView: NSScrollView) {
        self.timelineView = timelineView; self.scrollView = scrollView
        super.init(frame: .zero)
        clipsToBounds = true
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// Horizontal scroll origin of the lane content (document x at this view's left edge).
    var contentOffsetX: CGFloat { scrollView.contentView.bounds.minX }
    /// x of a timeline frame in this view: the document mapping minus the horizontal scroll origin.
    func viewX(_ frame: Int) -> CGFloat { timelineView.x(frame) - contentOffsetX }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        guard let st = timelineView.state, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ox = contentOffsetX
        ctx.saveGState()
        ctx.translateBy(x: -ox, y: 0)   // document x coordinates from here on
        let area = NSRect(x: ox, y: 0, width: bounds.width, height: bounds.height).insetBy(dx: -TimelineNSView.drawOverscan, dy: 0)
        timelineView.drawRuler(st, area: area)
        timelineView.drawPlayhead(st, height: bounds.height)
        ctx.restoreGState()
    }

    // Scrubbing: the press starts a ruler scrub in the timeline view; drags and the release continue there (same code as before).
    override func mouseDown(with e: NSEvent) { timelineView.rulerMouseDown(with: e) }
    override func mouseDragged(with e: NSEvent) { timelineView.mouseDragged(with: e) }
    override func mouseUp(with e: NSEvent) { timelineView.mouseUp(with: e) }
    override func scrollWheel(with e: NSEvent) { scrollView.scrollWheel(with: e) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    // Media dropped on the ruler goes to the base lane of its kind, as before (TimelineNSView.drop: "눈금자 위는 기본 레인").
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { timelineView.rulerDraggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { timelineView.rulerDraggingUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { timelineView.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { timelineView.draggingEnded(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { timelineView.rulerPerformDrag(sender) }
}

/// 레인 머리: 레인 이름·종류, 오디오 레인 음소거·음량 표시. 누르면 레인을 고르고(정보 패널에 레인 설정), 두 번 누르거나 문맥 메뉴로 이름을 바꾼다
/// (Return 확정, Esc 취소, 빈 이름은 이전 이름 유지, 실행 취소 한 단계). 문맥 메뉴: 이름 바꾸기·위로·아래로·음소거·삭제·레인 추가(A-014).
/// 편집 중에는 텍스트 칸(필드 편집기)이 첫 응답자라 타임라인 단축키가 입력을 가로채지 않는다(KeyRouting.isTextInput).
final class LaneHeaderView: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 112
    let store: ProjectStore
    var lanes: [Lane] = Lane.defaults
    var selectedLane: UUID?
    /// 이름 바꾸는 칸도 세로 스크롤을 따라간다(2026-10-11 리뷰: 칸이 다른 레인 위에 남았다)
    var verticalOffset: CGFloat = 0 { didSet { if let f = editor, let id = editingLane { f.frame = editorFrameInClip(id) } } }
    private(set) var editor: NSTextField?
    private(set) var editingLane: UUID?
    private var finishing = false
    /// LANE-SCROLL-CLIP-FIX-01: the rename field lives in this lane-area container (below the ruler strip, clipped), so a
    /// field whose row scrolls out is clipped and hit-tested only inside the lane viewport (never over the ruler or outside).
    let editorClip = FlippedClipView()
    /// Clips its subviews and is transparent to hits itself: header clicks, double-clicks and context menus keep reaching
    /// LaneHeaderView; only the rename field (inside the visible lane viewport) can be hit.
    final class FlippedClipView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { let v = super.hitTest(point); return v === self ? nil : v }
    }
    init(store: ProjectStore) {
        self.store = store; super.init(frame: .zero)
        // LANE-SCROLL-CLIP-FIX-01: rows are drawn at (lane y − vertical scroll), so scrolled-out rows lie outside the bounds.
        // Since the macOS 14 SDK NSView.clipsToBounds defaults to false; without this the rows painted over the toolbar,
        // ruler and preview above the timeline (and below it when rubber-banding).
        clipsToBounds = true
        editorClip.clipsToBounds = true
        addSubview(editorClip)
        setUpZoomControls()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    /// The lane viewport in header coordinates: below the ruler strip, inside the bounds (rows outside it are not visible).
    var laneViewport: NSRect { NSRect(x: 0, y: TimelineNSView.rulerHeight, width: bounds.width, height: max(0, bounds.height - TimelineNSView.rulerHeight)) }
    override func layout() {
        super.layout()
        editorClip.frame = laneViewport
        if let f = editor, let id = editingLane { f.frame = editorFrameInClip(id) }
        layoutZoomControls()
    }

    // MARK: 세로 확대 조작(LANE-VERTICAL-ZOOM-01)
    //
    // 레인 머리 맨 위의 고정 띠(눈금자 왼쪽, 높이 24 pt — 세로로 스크롤해도 남는 빈 칸)에 둔다: 축소 · 슬라이더 · 확대 · 모두 맞춤.
    // 대상은 선택으로 정한다(`ProjectStore.verticalZoomTarget`): 선택 없음 = 모든 레인, 레인 선택 = 그 레인, 클립 선택 = 그 클립의 레인.
    // 단추·슬라이더는 단축키와 같은 저장소 함수를 부른다. 초점을 가져가지 않으므로 타임라인 단축키와 글 입력에 영향이 없다.
    let zoomOutButton = NSButton(), zoomInButton = NSButton(), fitButton = NSButton(), zoomSlider = NSSlider()
    private func setUpZoomControls() {
        func configure(_ b: NSButton, symbol: String, fallback: String, label: String, action: Selector) {
            b.isBordered = false
            b.bezelStyle = .regularSquare
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
                b.image = img; b.imagePosition = .imageOnly; b.imageScaling = .scaleProportionallyDown
            } else {
                b.title = fallback; b.font = .systemFont(ofSize: 11, weight: .semibold)
            }
            b.target = self; b.action = action
            b.toolTip = label; b.setAccessibilityLabel(label)
            b.refusesFirstResponder = true
            b.controlSize = .small
            addSubview(b)
        }
        configure(zoomOutButton, symbol: "minus", fallback: "−", label: "레인 세로 축소 (⌥⌘−)", action: #selector(zoomOutPressed(_:)))
        configure(zoomInButton, symbol: "plus", fallback: "+", label: "레인 세로 확대 (⌥⌘=)", action: #selector(zoomInPressed(_:)))
        configure(fitButton, symbol: "arrow.up.and.down.square", fallback: "↕", label: "모든 레인 맞춤(자동 높이로 되돌리기)", action: #selector(fitPressed(_:)))
        zoomSlider.minValue = Double(LaneZoom.minScale); zoomSlider.maxValue = Double(LaneZoom.maxScale)
        zoomSlider.doubleValue = 1
        zoomSlider.isContinuous = true
        zoomSlider.controlSize = .mini
        zoomSlider.target = self; zoomSlider.action = #selector(zoomSliderChanged(_:))
        zoomSlider.refusesFirstResponder = true
        zoomSlider.setAccessibilityLabel("레인 세로 확대 배율")
        addSubview(zoomSlider)
        syncZoomControls()
    }
    /// 고정 띠 안의 자리(레인 머리 폭 112 pt 기준): 축소 3–21 · 슬라이더 23–69 · 확대 71–89 · 맞춤 91–109
    private func layoutZoomControls() {
        let h = TimelineNSView.rulerHeight - 1, side: CGFloat = 18, y = ((h - side) / 2).rounded()
        zoomOutButton.frame = NSRect(x: 3, y: y, width: side, height: side)
        zoomSlider.frame = NSRect(x: 23, y: ((h - 16) / 2).rounded(), width: max(0, bounds.width - 66), height: 16)
        zoomInButton.frame = NSRect(x: bounds.width - 41, y: y, width: side, height: side)
        fitButton.frame = NSRect(x: bounds.width - 21, y: y, width: side, height: side)
    }
    /// 조작의 값·사용 가능 상태·도움말을 지금 대상과 배율에 맞춘다(선택·레인·배율이 바뀔 때마다)
    func syncZoomControls() {
        let zoom = LaneZoom.shared, target = store.verticalZoomTarget
        let scale = zoom.scale(of: target, lanes: lanes)
        if abs(CGFloat(zoomSlider.doubleValue) - scale) > 0.0005 { zoomSlider.doubleValue = Double(scale) }
        let idle = store.gestureBase == nil
        zoomOutButton.isEnabled = idle && scale > LaneZoom.minScale + 0.0005
        zoomInButton.isEnabled = idle && scale < LaneZoom.maxScale - 0.0005
        zoomSlider.isEnabled = idle
        fitButton.isEnabled = idle
        let name: String
        switch target {
        case .all: name = "모든 레인"
        case .lane(let id): name = (lanes.first { $0.id == id }.map { "\(Timeline(lanes: lanes).laneLabel($0.id)) 레인" }) ?? "모든 레인"
        }
        zoomSlider.toolTip = "세로 확대: \(name) \(Int((scale * 100).rounded()))%" + (zoom.autoFit ? " (자동 맞춤)" : "")
    }
    @objc private func zoomOutPressed(_ sender: Any?) { store.verticalZoom(step: -1) }
    @objc private func zoomInPressed(_ sender: Any?) { store.verticalZoom(step: 1) }
    @objc private func fitPressed(_ sender: Any?) { store.fitAllLanes() }
    @objc private func zoomSliderChanged(_ sender: Any?) { store.setVerticalZoom(CGFloat(zoomSlider.doubleValue)) }

    func rowRect(_ id: UUID) -> NSRect {
        let r = TimelineNSView.layout(lanes).first { $0.lane.id == id }?.rect ?? .zero
        return NSRect(x: 0, y: r.minY - verticalOffset, width: bounds.width, height: r.height)
    }
    /// 그 종류의 첫 레인 줄(이전 자체 검사 호환)
    func rowRect(_ kind: LaneKind) -> NSRect { lanes.first { $0.kind == kind }.map { rowRect($0.id) } ?? .zero }
    /// Lane under a header point — only inside the visible lane viewport (not under the ruler strip or outside the bounds),
    /// so clicks and context menus cannot reach a row that is scrolled out of view (LANE-SCROLL-CLIP-FIX-01).
    func lane(at p: NSPoint) -> Lane? {
        guard laneViewport.contains(p) else { return nil }
        return lanes.first { rowRect($0.id).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        let numbering = Timeline(lanes: lanes)   // 번호(V1·A1…)는 레인 배열에서 계산한다(가운데 경계에서 바깥쪽)
        for l in lanes where l.id != editingLane {
            let r = rowRect(l.id)
            let selected = l.id == selectedLane
            TimelineNSView.color(l.kind).withAlphaComponent(selected ? 0.32 : 0.12).setFill()
            let bg = NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 2), xRadius: 4, yRadius: 4)
            bg.fill()
            if selected { NSColor.controlAccentColor.setStroke(); bg.lineWidth = 1.5; bg.stroke() }
            // 번호 표(위치에서 정함, 이름과 따로)
            let badge = NSRect(x: r.minX + 8, y: r.midY - 8, width: 24, height: 16)
            TimelineNSView.color(l.kind).withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            let label = NSString(string: numbering.laneLabel(l.id))
            let battrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
            let lsz = label.size(withAttributes: battrs)
            label.draw(at: NSPoint(x: badge.midX - lsz.width / 2, y: badge.midY - lsz.height / 2), withAttributes: battrs)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                        .foregroundColor: l.muted ? NSColor.secondaryLabelColor : NSColor.labelColor]
            let hasSub = l.kind == .audio && (l.muted || l.volumePercent != 100) && r.height >= 34
            NSString(string: l.name).draw(with: NSRect(x: r.minX + 38, y: r.midY - (hasSub ? 14 : 8), width: r.width - 44, height: 16),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            if hasSub {
                let sub = l.muted ? "음소거" : "음량 \(l.volumePercent)%"
                NSString(string: sub).draw(at: NSPoint(x: r.minX + 38, y: r.midY + 2),
                                           withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: l.muted ? NSColor.systemOrange : NSColor.secondaryLabelColor])
            }
        }
        if let by = TimelineNSView.boundaryY(lanes) { TimelineNSView.drawBoundary(y: by - verticalOffset, from: 0, to: bounds.width - 1) }
        // 눈금자 줄(세로 스크롤해도 머리 위에 남는다)
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width - 1, height: TimelineNSView.rulerHeight - 1).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: TimelineNSView.rulerHeight - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let l = lane(at: p), p.y >= TimelineNSView.rulerHeight else { return }
        if e.clickCount == 2 { beginRename(l.id) } else { store.selectLane(l.id) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard store.gestureBase == nil else { return nil }   // 끌기 중에는 메뉴를 띄우지 않는다(메뉴가 놓기를 먹어 끌기가 끝나지 않음, CP-01)
        let m = NSMenu()
        m.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ id: UUID?, enabled: Bool = true) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: ""); it.target = self; it.representedObject = id; it.isEnabled = enabled && store.gestureBase == nil
            m.addItem(it)
        }
        if let l = lane(at: convert(event.locationInWindow, from: nil)) {
            store.selectLane(l.id)
            add("레인 이름 바꾸기…", #selector(renameFromMenu(_:)), l.id)
            add("위로", #selector(upFromMenu(_:)), l.id, enabled: store.canMoveLane(l.id, by: -1))
            add("아래로", #selector(downFromMenu(_:)), l.id, enabled: store.canMoveLane(l.id, by: 1))
            if l.kind == .audio { add(l.muted ? "음소거 해제" : "음소거", #selector(muteFromMenu(_:)), l.id) }
            add(l.kind == .spectrum ? "레인 삭제" : "레인 삭제…", #selector(deleteFromMenu(_:)), l.id, enabled: store.canRemoveLane(l))
            m.addItem(.separator())
        }
        add("영상 레인 추가", #selector(addVideoFromMenu(_:)), nil)
        add("오디오 레인 추가", #selector(addAudioFromMenu(_:)), nil)
        add("자막 레인 추가", #selector(addSubtitleFromMenu(_:)), nil)
        return m
    }
    @objc private func renameFromMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { beginRename(id) } }
    @objc private func upFromMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { store.moveLane(id, by: -1) } }
    @objc private func downFromMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { store.moveLane(id, by: 1) } }
    @objc private func muteFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID, let l = store.timeline.laneInfo(id) { store.setLaneMuted(id, !l.muted) }
    }
    @objc private func deleteFromMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { store.requestRemoveLane(id) } }
    @objc private func addVideoFromMenu(_ sender: NSMenuItem) { store.addLane(.video) }
    @objc private func addAudioFromMenu(_ sender: NSMenuItem) { store.addLane(.audio) }
    @objc private func addSubtitleFromMenu(_ sender: NSMenuItem) { store.addLane(.subtitle) }

    func editorFrame(_ id: UUID) -> NSRect { let r = rowRect(id); return r.insetBy(dx: 4, dy: max(2, (r.height - 22) / 2)) }
    /// The same rect in `editorClip` coordinates (the clip starts at the ruler strip's bottom).
    func editorFrameInClip(_ id: UUID) -> NSRect { editorFrame(id).offsetBy(dx: 0, dy: -editorClip.frame.minY) }
    func beginRename(_ id: UUID) {
        guard editor == nil, let l = lanes.first(where: { $0.id == id }), store.gestureBase == nil else { return }
        let f = NSTextField(string: l.name)
        f.font = .systemFont(ofSize: 12, weight: .semibold)
        f.delegate = self
        f.focusRingType = .default
        f.setAccessibilityLabel("레인 이름")
        editorClip.frame = laneViewport
        f.frame = editorFrameInClip(id)
        editorClip.addSubview(f)
        editor = f; editingLane = id; finishing = false
        needsDisplay = true
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }
    /// Return: 확정, Esc: 취소(이전 이름)
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { finish(commit: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { finish(commit: false); return true }
        return false
    }
    /// 다른 곳을 눌러 초점을 잃으면 확정한다
    func controlTextDidEndEditing(_ obj: Notification) { finish(commit: true) }
    func finish(commit: Bool) {
        guard !finishing, let f = editor, let id = editingLane else { return }
        finishing = true
        let text = f.stringValue
        editor = nil; editingLane = nil
        f.removeFromSuperview()
        if commit { store.renameLane(id, to: text) }   // 빈 이름이면 바꾸지 않고 이전 이름 유지(상태 줄에 안내)
        needsDisplay = true
        if let tv = (superview as? TimelineContainerView)?.timelineView { window?.makeFirstResponder(tv) }
    }
}

final class TimelineNSView: NSView {
    static let inset: CGFloat = 12, rulerHeight: CGFloat = 24, edgeGrab: CGFloat = 6
    /// 레인 줄 배치(A-014): 눈금자 아래 위에서부터 레인 순서대로. 영상 레인 54pt, 오디오 레인 40pt, 사이 8pt.
    static let firstLaneY: CGFloat = 30, laneGap: CGFloat = 8, videoHeight: CGFloat = 54, audioHeight: CGFloat = 64, subtitleHeight: CGFloat = 34, spectrumHeight: CGFloat = 34
    /// 마지막 레인 아래 빈 곳(여기에 놓으면 파일 이름의 새 레인)
    static let dropZoneHeight: CGFloat = 44
    /// 영상 레인 묶음과 오디오 레인 묶음 사이 가운데 경계(2026-10-11): 레인 사이보다 넓은 틈과 경계선
    static let boundaryGap: CGFloat = 18
    /// WAVEFORM-01 (owner decision 2026-11-22): audio lanes are 64 pt (was 40) so the clip name keeps a strip of
    /// `waveformLabelStrip` at the top and the stereo waveform halves are drawn below it.
    static let waveformLabelStrip: CGFloat = 20
    /// 끌어 옮기기 붙음 거리(화면 포인트, 확대 배율과 무관)
    static let snapDistance: CGFloat = 8
    static func height(_ k: LaneKind) -> CGFloat {
        switch k { case .video: videoHeight; case .audio: audioHeight; case .subtitle: subtitleHeight; case .spectrum: spectrumHeight }
    }
    /// 레인 종류 색: 영상 청록, 오디오 초록, 자막 보라(2026-10-22), 스펙트럼 분홍(2026-10-25, SP-1A 2A)
    static func color(_ k: LaneKind) -> NSColor {
        switch k { case .video: .systemTeal; case .audio: .systemGreen; case .subtitle: .systemPurple; case .spectrum: .systemPink }
    }
    /// LANE-VERTICAL-ZOOM-01: each lane's height is its kind's base height (`height(_:)`) times the lane's vertical zoom
    /// (`LaneZoom`, UI state). This is the single place lane geometry comes from, so headers, clips, hit-testing, drops,
    /// snap markers and the content height all follow the same effective heights. Gaps and the ruler are not scaled.
    static func layout(_ lanes: [Lane]) -> [(lane: Lane, rect: NSRect)] {
        var y = firstLaneY
        let zoom = LaneZoom.shared
        return lanes.enumerated().map { i, l in
            let boundaryNext = l.kind == .video && i + 1 < lanes.count && lanes[i + 1].kind == .audio
            let h = zoom.height(l)
            defer { y += h + (boundaryNext ? boundaryGap : laneGap) }
            return (l, NSRect(x: 0, y: y, width: 0, height: h))
        }
    }
    /// 가운데 경계선 위치(V1 아래와 A1 위의 가운데)
    static func boundaryY(_ lanes: [Lane]) -> CGFloat? {
        let l = layout(lanes)
        guard let v = l.last(where: { $0.lane.kind == .video }), let a = l.first(where: { $0.lane.kind == .audio }) else { return nil }
        return (v.rect.maxY + a.rect.minY) / 2
    }
    static func drawBoundary(y: CGFloat, from x0: CGFloat, to x1: CGFloat) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.7).setFill()
        NSRect(x: x0, y: y - 1, width: max(0, x1 - x0), height: 2).fill()
    }
    static func contentHeight(_ lanes: [Lane]) -> CGFloat { (layout(lanes).last?.rect.maxY ?? firstLaneY) + 12 + dropZoneHeight }
    /// 기본 레인 2개(영상 1·오디오 1)일 때의 위치(이전 자체 검사 호환)
    static let videoY: CGFloat = firstLaneY, audioY: CGFloat = firstLaneY + videoHeight + boundaryGap
    static let trackY = videoY, trackHeight = videoHeight
    static func laneRect(_ k: LaneKind) -> NSRect {
        k == .video ? NSRect(x: 0, y: videoY, width: 0, height: videoHeight) : NSRect(x: 0, y: audioY, width: 0, height: audioHeight)
    }
    let store: ProjectStore
    var state: TimelineDrawState? { didSet { refreshCutHover() } }
    var pixelsPerFrame: CGFloat = 2
    /// 미디어를 끌고 있는 중(빈 곳 안내 표시)과 놓일 위치(보기 좌표)
    private var dropHover = false
    private var dropPoint: NSPoint?

    private enum Drag { case none, scrub, pending(UUID, NSPoint), free(UUID, CGFloat), trim(UUID, ProjectStore.TrimEdge, CGFloat),
                        fade(UUID, ProjectStore.FadeEdge, CGFloat) }
    private var drag: Drag = .none

    init(store: ProjectStore) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes([.string])
        NotificationCenter.default.addObserver(self, selector: #selector(gestureInterrupted), name: ProjectStore.gestureInterruptedNotification, object: nil)
    }
    /// 끌기 중단(D-031): 저장소가 끌기를 취소했으면 이 보기의 끌기 상태도 지운다(뒤늦게 온 끌기·놓기 이벤트가 아무것도 하지 않게).
    /// 저장소 끌기가 없어도(창·앱 상태 바뀜) 옮기기 누름 대기를 지운다: 같은 누름의 늦은 끌기가 새 옮기기를 시작하지 않게(2026-10-12).
    @objc private func gestureInterrupted() {
        switch drag {
        case .trim, .free, .fade, .pending:
            #if DEBUG
            store.traceGestureDebug("timeline viewDragCleared phase=\(dragNameForTest)")
            #endif
            drag = .none; needsDisplay = true
        default: break
        }
    }
    #if DEBUG
    /// 자체 검사 전용: 보이는 영역 줄이기를 끈다(timeline-draw-test가 전체 그리기와 화소를 비교)
    var fullDrawForTest = false
    /// 자체 검사 전용: 지금 끌기 상태 이름
    var dragNameForTest: String {
        switch drag { case .none: "none"; case .scrub: "scrub"; case .pending: "pending"; case .free: "free"; case .trim: "trim"; case .fade: "fade" }
    }
    #endif
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var lanes: [Lane] { state?.timeline.lanes ?? Lane.defaults }
    func laneRect(_ id: UUID?) -> NSRect? { Self.layout(lanes).first { $0.lane.id == id }?.rect }
    /// y 위치의 레인(레인 사이 틈·경계 틈은 가까운 레인)
    func lane(atY y: CGFloat) -> Lane? {
        let l = Self.layout(lanes)
        guard let first = l.first, let last = l.last, y >= first.rect.minY - Self.laneGap / 2, y <= last.rect.maxY + Self.laneGap / 2 else { return nil }
        func dist(_ r: NSRect) -> CGFloat { y < r.minY ? r.minY - y : (y > r.maxY ? y - r.maxY : 0) }
        return l.min { dist($0.rect) < dist($1.rect) }?.lane
    }
    var lanesBottom: CGFloat { Self.layout(lanes).last?.rect.maxY ?? Self.firstLaneY }
    func x(_ frame: Int) -> CGFloat { Self.inset + CGFloat(frame) * pixelsPerFrame }
    /// 보기 x → 타임라인 프레임(가장 가까운 프레임 경계). 문서 보기 좌표라 가로 스크롤·확대와 무관하게 같은 식이다.
    func frame(atX px: CGFloat) -> Int { Int(((px - Self.inset) / pixelsPerFrame).rounded()) }
    private func rect(_ c: Clip, lane: UUID? = nil, start: Int? = nil) -> NSRect {
        let l = laneRect(lane ?? c.lane) ?? .zero
        return NSRect(x: x(start ?? c.start), y: l.minY, width: max(1, CGFloat(c.length) * pixelsPerFrame), height: l.height)
    }

    // MARK: 그리기

    /// 보이는 영역 밖 여유(pt): 선택 테두리·재생 헤드 삼각형·영역 바로 밖에서 시작하는 글자의 끝을 덮는다
    static let drawOverscan: CGFloat = 32
    /// 그릴 영역(2026-10-23 측정 고침): 재생 중 매 프레임 문서 보기 전체(전체 길이 × 확대)의 항목을 돌며 그려서 클립 500쌍에서 한 번 그리기에 144 ms가 걸렸다.
    /// AppKit이 마지막에 잘라도 글자 배치·빗금·눈금 글자 만들기는 전부 했다. 이제 보이는 영역(+ 여유)에 겹치는 항목만 그린다.
    /// 창 밖(보이는 영역 없음)이면 받은 영역 그대로.
    func drawArea(_ dirtyRect: NSRect) -> NSRect {
        #if DEBUG
        if fullDrawForTest { return bounds }   // 자체 검사: 이전처럼 전체를 돌며 그리기(같은 그림인지 비교)
        #endif
        let v = visibleRect.isEmpty ? dirtyRect : dirtyRect.intersection(visibleRect)
        return v.insetBy(dx: -Self.drawOverscan, dy: 0)
    }
    /// 그릴 영역의 프레임 범위(양 끝 포함, 가장자리에 걸친 항목 포함)
    func frameRange(_ area: NSRect) -> ClosedRange<Int> {
        let lo = Int(((area.minX - Self.inset) / pixelsPerFrame).rounded(.down)), hi = Int(((area.maxX - Self.inset) / pixelsPerFrame).rounded(.up))
        return lo...max(lo, hi)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let st = state else { return }
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        let area = drawArea(dirtyRect), fr = frameRange(area)
        drawRuler(st, area: area)
        let t = st.timeline
        let rows = Self.layout(t.lanes)
        // TIMELINE-UI-POLISH-01 (owner request): empty lane regions draw nothing extra (no dark fill, hatch or "빈틈"/"무음" label) —
        // the plain timeline background, like empty subtitle/Spectrum lanes. Gaps themselves (`Timeline.gaps`) are unchanged.
        let top = rows.first?.rect.minY ?? Self.firstLaneY, bottom = rows.last?.rect.maxY ?? Self.firstLaneY
        if let by = Self.boundaryY(t.lanes) { Self.drawBoundary(y: by, from: 0, to: bounds.width) }
        if t.durationFrames > 0 {   // 타임라인 끝(길이)
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: x(t.durationFrames) - 0.5, y: top - 6, width: 1, height: bottom - top + 12).fill()
        }
        // 보이는 프레임 범위에 걸친 클립·자막만(가장자리에 걸친 항목은 전체 모양 그대로 그려 잘린다). 순서는 그대로.
        for c in t.clips + t.audioClips where c.end >= fr.lowerBound && c.start <= fr.upperBound { drawClip(c, st, area: area) }
        for sub in t.subtitles where sub.end >= fr.lowerBound && sub.start <= fr.upperBound { drawSubtitle(sub, st) }
        for sp in t.spectra where sp.end >= fr.lowerBound && sp.start <= fr.upperBound { drawSpectrum(sp, st) }
        // 음소거한 오디오 레인: 클립 위를 어둡게
        for (l, r) in rows where l.muted && l.kind == .audio {
            NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
            NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height).fill()
        }
        // 끌어 옮기기(묶음 전체): 놓을 수 있으면 원래 자리를 점선으로(클립은 이미 새 자리에 그려짐), 놓을 수 없으면 제안 위치를 빨갛게
        if let id = st.proposalID, let s = st.proposalStart, let base = store.gestureBase, let sub = base.subtitle(id) {   // 자막 옮기기
            if st.proposalOK {
                let p = NSBezierPath(roundedRect: subtitleRect(sub).insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                p.setLineDash([4, 3], count: 2, phase: 0); p.lineWidth = 1
                NSColor.secondaryLabelColor.setStroke(); p.stroke()
            } else {
                let r = subtitleRect(sub, lane: st.proposalLane, start: s)
                NSColor.systemRed.withAlphaComponent(0.25).setFill(); r.fill()
                NSColor.systemRed.setStroke(); let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
            }
        }
        if let id = st.proposalID, let s = st.proposalStart, let base = store.gestureBase, let sp = base.spectrum(id) {   // 스펙트럼 옮기기(2C-1, 자막과 같은 표시)
            if st.proposalOK {
                let p = NSBezierPath(roundedRect: spectrumRect(sp).insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                p.setLineDash([4, 3], count: 2, phase: 0); p.lineWidth = 1
                NSColor.secondaryLabelColor.setStroke(); p.stroke()
            } else {
                let r = spectrumRect(sp, lane: st.proposalLane, start: s)
                NSColor.systemRed.withAlphaComponent(0.25).setFill(); r.fill()
                NSColor.systemRed.setStroke(); let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
            }
        }
        if let id = st.trimRejectID, let r0 = st.trimRejectRange, let base = store.gestureBase, let sp = base.spectrum(id) {   // 스펙트럼 트림 거부(2C-2, 옮기기 거부와 같은 빨간 상자)
            let r = spectrumRect(sp.with(start: r0.lowerBound, length: r0.count))
            NSColor.systemRed.withAlphaComponent(0.25).setFill(); r.fill()
            NSColor.systemRed.setStroke(); let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
        }
        if let id = st.proposalID, let s = st.proposalStart, let base = store.gestureBase, let c = base.clip(id) {
            for m in base.group(of: id) {
                if st.proposalOK {
                    let p = NSBezierPath(roundedRect: rect(m).insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                    p.setLineDash([4, 3], count: 2, phase: 0); p.lineWidth = 1
                    NSColor.secondaryLabelColor.setStroke(); p.stroke()
                } else {
                    let r = rect(m, lane: m.id == id ? st.proposalLane : m.lane, start: m.start + (s - c.start))
                    NSColor.systemRed.withAlphaComponent(0.25).setFill(); r.fill()
                    NSColor.systemRed.setStroke(); let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
                }
            }
        }
        if let f = st.snap {   // 붙은 위치 안내선(0 또는 다른 클립 경계)
            NSColor.systemYellow.setFill()
            NSRect(x: x(f) - 1, y: top - 6, width: 2, height: bottom - top + 12).fill()
            drawSnapMarkers(st, frame: f)
        }
        if dropHover, let dp = dropPoint, let l = lane(atY: dp.y), let r = laneRect(l.id) {   // 놓일 시각(놓은 위치 그대로)
            NSColor.controlAccentColor.setFill()
            NSRect(x: x(max(0, frame(atX: dp.x))) - 1, y: r.minY - 3, width: 2, height: r.height + 6).fill()
        }
        if dropHover {   // 빈 곳에 놓으면 새 레인
            let r = NSRect(x: Self.inset, y: bottom + 10, width: max(0, bounds.width - Self.inset * 2), height: Self.dropZoneHeight - 12)
            let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6); p.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.secondaryLabelColor.setStroke(); p.stroke()
            NSString(string: "여기에 놓으면 파일 이름의 새 레인(영상은 맨 위, 소리는 맨 아래)").draw(at: NSPoint(x: r.minX + 10, y: r.midY - 7),
                                                       withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        }
        if let h = cutHover, st.tool == .cut {   // 자를 위치 안내선(D-030): 대상 클립의 레인과 연결된 짝의 레인에만
            NSColor.controlAccentColor.setFill()
            let lanes = t.subtitle(h.id).map { [$0.lane] } ?? t.group(of: h.id).compactMap(\.lane)
            for l in lanes { if let r = laneRect(l) { NSRect(x: x(h.frame) - 1, y: r.minY - 2, width: 2, height: r.height + 4).fill() } }
        }
        drawPlayhead(st, height: bounds.height)
    }
    /// Playhead line from y 0 down to `height` and its top triangle, in document x coordinates. The fixed ruler
    /// (TIMELINE-STICKY-RULER-01) draws the same shape over its own height so the triangle stays visible while lanes scroll.
    func drawPlayhead(_ st: TimelineDrawState, height: CGFloat) {
        let ph = x(min(st.playhead, st.timeline.durationFrames))
        NSColor.systemRed.setFill()
        NSRect(x: ph - 0.75, y: 0, width: 1.5, height: height).fill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: ph - 5, y: 0)); tri.line(to: NSPoint(x: ph + 5, y: 0)); tri.line(to: NSPoint(x: ph, y: 7)); tri.close()
        tri.fill()
    }

    /// TIMELINE-UI-POLISH-01: marker triangle size (pt). Fits the 8 pt lane gap; drawn only, never hit-tested.
    static let snapMarkerHalfWidth: CGFloat = 4, snapMarkerHeight: CGFloat = 5
    /// Vertical marker pair for each snapped clip edge: ▼ just above the clip's top corner and ▲ just below its bottom
    /// corner, both centred on the edge X and pointing at the clip (same for start and end edges). Markers whose clip was
    /// removed or whose edge is no longer at the snapped frame are skipped.
    static func snapMarkerRects(clip r: NSRect, edgeX ex: CGFloat) -> (above: NSRect, below: NSRect) {
        let w = snapMarkerHalfWidth * 2, h = snapMarkerHeight
        return (NSRect(x: ex - snapMarkerHalfWidth, y: r.minY - h, width: w, height: h), NSRect(x: ex - snapMarkerHalfWidth, y: r.maxY, width: w, height: h))
    }
    func snapMarkerGeometry(_ st: TimelineDrawState, frame f: Int) -> [(marker: ProjectStore.SnapMarker, above: NSRect, below: NSRect)] {
        st.snapMarkers.compactMap { m in
            guard m.frame == f, let c = st.timeline.clip(m.clip), (m.edge == .start ? c.start : c.end) == f else { return nil }
            let r = Self.snapMarkerRects(clip: rect(c), edgeX: x(f))
            return (marker: m, above: r.above, below: r.below)
        }
    }
    private func drawSnapMarkers(_ st: TimelineDrawState, frame f: Int) {
        NSColor.systemYellow.setFill()   // same accent as the snap guide
        for g in snapMarkerGeometry(st, frame: f) {
            let down = NSBezierPath()   // ▼ above the top corner, tip touching the clip
            down.move(to: NSPoint(x: g.above.minX, y: g.above.minY)); down.line(to: NSPoint(x: g.above.maxX, y: g.above.minY))
            down.line(to: NSPoint(x: g.above.midX, y: g.above.maxY)); down.close(); down.fill()
            let up = NSBezierPath()   // ▲ below the bottom corner, tip touching the clip
            up.move(to: NSPoint(x: g.below.minX, y: g.below.maxY)); up.line(to: NSPoint(x: g.below.maxX, y: g.below.maxY))
            up.line(to: NSPoint(x: g.below.midX, y: g.below.minY)); up.close(); up.fill()
        }
    }

    private func drawClip(_ c: Clip, _ st: TimelineDrawState, area: NSRect) {
        let k = st.timeline.lane(of: c.id) ?? .video
        let r = rect(c)
        let selected = st.selected.contains(c.id), candidate = c.id == st.candidate
        let base = k == .video ? NSColor.systemTeal : NSColor.systemGreen
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (selected && !candidate ? NSColor.controlAccentColor.withAlphaComponent(0.5) : base.withAlphaComponent(0.35)).setFill()
        path.fill()
        if candidate { path.setLineDash([4, 3], count: 2, phase: 0) }
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
        if k == .audio, !st.missing.contains(c.mediaID), let a = st.media[c.mediaID] {   // WAVEFORM-01: under labels, envelope and handles
            drawWaveform(c, r, store.waveforms.state(for: a), area: area, clip: path)
        }
        if st.missing.contains(c.mediaID) {   // 찾을 수 없는 원본: 빗금·"원본 없음"(빈틈과 구별)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor.systemOrange.withAlphaComponent(0.35).setStroke()
            let hatch = NSBezierPath(); hatch.lineWidth = 2
            var hx = r.minX - r.height
            while hx < r.maxX { hatch.move(to: NSPoint(x: hx, y: r.minY)); hatch.line(to: NSPoint(x: hx + r.height, y: r.maxY)); hx += 10 }
            hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()
            if r.width > 70 {
                NSString(string: "원본 없음").draw(at: NSPoint(x: r.minX + 6, y: r.maxY - 16), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemOrange])
            }
        }
        var labelX = r.minX + 6
        if c.link != nil, r.width > 20, let img = NSImage(systemSymbolName: "link", accessibilityDescription: "연결됨") {
            img.draw(in: NSRect(x: r.minX + 5, y: r.minY + 5, width: 11, height: 11)); labelX += 14
        }
        if r.width > 30 {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
            NSString(string: (k == .audio ? "♪ " : "") + (st.names[c.mediaID] ?? "")).draw(with: NSRect(x: labelX, y: r.minY + 4, width: max(0, r.maxX - labelX - 6), height: 16),
                                                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        // 동기 어긋남 표시(연결된 쌍이 어긋났을 때 두 클립 모두): 소리가 영상보다 늦으면 +
        if let o = st.timeline.syncOffset(of: c.id), o != 0 {
            let text = NSString(string: (o > 0 ? "+" : "−") + "\(abs(o))f")
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
            let sz = text.size(withAttributes: attrs)
            let b = NSRect(x: max(r.minX + 4, r.maxX - sz.width - 12), y: r.maxY - sz.height - 6, width: sz.width + 8, height: sz.height + 2)
            NSColor.systemRed.setFill(); NSBezierPath(roundedRect: b, xRadius: b.height / 2, yRadius: b.height / 2).fill()
            text.draw(at: NSPoint(x: b.minX + 4, y: b.minY + 1), withAttributes: attrs)
        }
        if k == .audio { drawAudioEnvelope(c, r, st) }
        if c.id == st.selection || (selected && !candidate && st.selection.map { st.timeline.group(of: $0).contains { $0.id == c.id } } == true) {   // 트림 손잡이
            NSColor.controlAccentColor.setFill()
            NSRect(x: r.minX, y: r.minY + 6, width: 3, height: r.height - 12).fill()
            NSRect(x: r.maxX - 3, y: r.minY + 6, width: 3, height: r.height - 12).fill()
        }
    }

    func subtitleRect(_ s: SubtitleItem, lane: UUID? = nil, start: Int? = nil) -> NSRect {
        let l = laneRect(lane ?? s.lane) ?? .zero
        return NSRect(x: x(start ?? s.start), y: l.minY, width: max(1, CGFloat(s.length) * pixelsPerFrame), height: l.height)
    }
    /// 자막 항목(2026-10-22): 보라 상자 + 첫 줄 글자. 고르면 강조와 양쪽 트림 손잡이(선택 도구).
    private func drawSubtitle(_ s: SubtitleItem, _ st: TimelineDrawState) {
        let r = subtitleRect(s)
        let selected = st.selection == s.id
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.5) : NSColor.systemPurple.withAlphaComponent(0.35)).setFill()
        path.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
        if r.width > 24 {
            // 빈 자막(D-037): 화면 표시만 "빈 자막"(저장 글자 아님), 흐린 기울임
            let line = s.isBlank ? "빈 자막" : (s.text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "")
            let attrs: [NSAttributedString.Key: Any] = s.isBlank
                ? [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 11), toHaveTrait: .italicFontMask), .foregroundColor: NSColor.secondaryLabelColor]
                : [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
            NSString(string: "T  " + line).draw(with: NSRect(x: r.minX + 6, y: r.minY + 4, width: max(0, r.width - 12), height: 16),
                                               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        if !s.isBlank, r.width > 20 {   // 그리기 상태: 그리지 못함(빨강)·화면 밖(주황) 표시(2026-10-23)
            let rs = SubtitleRenderer.shared.raster(s)
            if rs.failed || rs.clipped, let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: rs.failed ? "그릴 수 없음" : "화면 밖") {
                let tinted = img.withSymbolConfiguration(.init(paletteColors: [rs.failed ? .systemRed : .systemOrange])) ?? img
                tinted.draw(in: NSRect(x: r.maxX - 26, y: r.minY + 3, width: 11, height: 11))
            }
        }
        if st.missingFonts.contains(s.style.fontName), r.width > 14 {   // 없는 글꼴 표시
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.maxX - 12, y: r.minY + 4, width: 7, height: 7)).fill()
        }
        if selected, st.tool == .selection {
            NSColor.controlAccentColor.setFill()
            NSRect(x: r.minX, y: r.minY + 6, width: 3, height: r.height - 12).fill()
            NSRect(x: r.maxX - 3, y: r.minY + 6, width: 3, height: r.height - 12).fill()
        }
    }

    /// 스펙트럼 항목의 경고 표시 자리(오른쪽 위)
    static func spectrumWarningRect(_ r: NSRect) -> NSRect { NSRect(x: r.maxX - 15, y: r.minY + 3, width: 11, height: 11) }
    /// 스펙트럼 상자. lane·start를 주면 그 자리(옮기기 제안 표시, 2C-1)
    func spectrumRect(_ s: SpectrumItem, lane: UUID? = nil, start: Int? = nil) -> NSRect {
        let l = laneRect(lane ?? s.lane) ?? .zero
        return NSRect(x: x(start ?? s.start), y: l.minY, width: max(1, CGFloat(s.length) * pixelsPerFrame), height: l.height)
    }
    /// 스펙트럼 누름 판정(SP-1A 2B-2 고르기, 2C-1 옮기기, 2C-2 트림): clipHit(자르기 도구·문맥 메뉴·클립 명령이 쓰는 판정)과 따로 둬 클립 메뉴·자르기에 닿지 않는다.
    /// 항목: 그린 상자 [x(start), x(end))가 먼저(이어 붙은 두 항목의 경계는 오른쪽 항목), 없으면 바깥 1 pt 안의 가장 가까운 항목(clipHit과 같은 여유 —
    /// 아주 짧은 항목도 잡힘, 같은 거리면 오른쪽). 가장자리: clipHit과 같은 규칙(안쪽 edgeGrab, 짧으면 폭의 1/3) — 시작 쪽 먼저.
    func spectrumTarget(_ p: NSPoint) -> (UUID, ProjectStore.TrimEdge?)? {
        guard let st = state else { return nil }
        for (lane, l) in Self.layout(st.timeline.lanes) where lane.kind == .spectrum && p.y >= l.minY && p.y <= l.maxY {
            let items = st.timeline.spectra(inLane: lane.id)
            func dist(_ s: SpectrumItem) -> CGFloat { p.x < x(s.start) ? x(s.start) - p.x : max(0, p.x - x(s.end)) }
            guard let s = items.first(where: { p.x >= x($0.start) && p.x < x($0.end) })
                    ?? items.filter({ dist($0) <= 1 }).min(by: { (dist($0), -$0.start) < (dist($1), -$1.start) }) else { return nil }
            let x0 = x(s.start), x1 = x(s.end), grab = min(Self.edgeGrab, (x1 - x0) / 3)
            if p.x <= x0 + grab { return (s.id, .start) }
            if p.x >= x1 - grab { return (s.id, .end) }
            return (s.id, nil)
        }
        return nil
    }
    func spectrumHit(_ p: NSPoint) -> UUID? { spectrumTarget(p)?.0 }
    /// 스펙트럼 항목(2026-10-25, SP-1A 2A): 분홍 점선 상자와 소스 상태 글자. 누름 판정(clipHit)에 넣지 않아
    /// 자르기는 없다(SP-1A 밖). 2C-1부터 선택 도구로 끌어 옮기고(spectrumTarget → 누름 대기), 2C-2부터 가장자리를 끌어 트림한다(고르면 트림 손잡이·커서). 2B-2부터 누르면 고르고(spectrumHit) 고른 항목은 강조색 실선으로 그린다. 스펙트럼이 든 프로젝트를 열면 보인다(2B-1). 소스는 정상인데 그 원본 파일을 찾지 못했으면 "원본 파일 없음"을 덧붙인다
    /// (엔진의 "소스 없음" = 그 계보의 소리 조각이 없음과 다른 상태).
    private func drawSpectrum(_ s: SpectrumItem, _ st: TimelineDrawState) {
        let r = spectrumRect(s)
        let selected = st.selection == s.id
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.45) : NSColor.systemPink.withAlphaComponent(0.22)).setFill(); path.fill()
        if !selected { path.setLineDash([4, 3], count: 2, phase: 0) }
        path.lineWidth = selected ? 2 : 1
        (selected ? NSColor.controlAccentColor : NSColor.systemPink.withAlphaComponent(0.8)).setStroke(); path.stroke()
        if selected, st.tool == .selection {   // 트림 손잡이(2C-2, 자막과 같음)
            NSColor.controlAccentColor.setFill()
            NSRect(x: r.minX, y: r.minY + 6, width: 3, height: r.height - 12).fill()
            NSRect(x: r.maxX - 3, y: r.minY + 6, width: 3, height: r.height - 12).fill()
        }
        // 소스 경고 표시(2B-3): 고르지 않음 주황, 소스 없음·원본 파일 없음·겹침 빨강. 그리기만(누름 판정·끌기와 무관).
        let warnings = ProjectStore.spectrumWarnings(s, in: st.timeline, missing: st.missing)
        if let w = warnings.first, r.width > 14, let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "스펙트럼 소스 경고") {
            let tinted = img.withSymbolConfiguration(.init(paletteColors: [w == .unset ? .systemOrange : .systemRed])) ?? img
            tinted.draw(in: Self.spectrumWarningRect(r))
        }
        guard r.width > 24 else { return }
        let source: String
        switch st.timeline.spectrumSourceState(s) {
        case .unset: source = "소스 고르지 않음"
        case .missing: source = "소스 없음"
        case .ok:
            let m = st.timeline.spectrumMediaID(s)
            source = (m.flatMap { st.names[$0] } ?? "소스") + (m.map { st.missing.contains($0) } == true ? " · 원본 파일 없음" : "")
                + (warnings.contains { if case .overlap = $0 { return true }; return false } ? " · 조각 겹침" : "")
        }
        NSString(string: "≋  스펙트럼 · " + source).draw(with: NSRect(x: r.minX + 6, y: r.minY + 4, width: max(0, r.width - 12), height: 16),
                                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                     attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
    }

    // MARK: 소리 클립 음량·페이드(2026-10-11)

    /// 음량 선이 오가는 높이: 클립 아래(0%)에서 위 여백(100%)까지
    /// WAVEFORM-01 colors: the clip's own green, darker on light backgrounds and lighter on dark ones (clip colors unchanged).
    static let waveformFill = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.systemGreen.blended(withFraction: 0.55, of: .white)!.withAlphaComponent(0.92)
                                                         : NSColor.systemGreen.blended(withFraction: 0.45, of: .black)!.withAlphaComponent(0.85)
    }
    /// Pixel columns of a clip's waveform: for each column [x, x + step) of `visible` ∩ clip, the source sample range it
    /// shows (Spectrum's mapping: sourceIn + timeline offset at 30 fps from file time 0, the peaks' rate; equals playback when the
    /// reference track starts at time 0 — a later track start is an open limitation). Testable, no drawing.
    func waveformColumns(_ c: Clip, rate: Int, visible: NSRect, step: CGFloat = 1) -> [(x: CGFloat, samples: Range<Int>)] {
        let r = rect(c)
        let x0 = max(r.minX, visible.minX).rounded(.down), x1 = min(r.maxX, visible.maxX)
        guard x1 > x0 else { return [] }
        var out: [(x: CGFloat, samples: Range<Int>)] = []
        out.reserveCapacity(Int((x1 - x0) / step) + 1)
        var px = x0
        while px < x1 {
            let f0 = Double((px - Self.inset) / pixelsPerFrame), f1 = Double((min(px + step, x1) - Self.inset) / pixelsPerFrame)
            if let s = WaveformPeaks.sourceSamples(clipStart: c.start, sourceIn: c.sourceIn, length: c.length, timeline: f0, f1, rate: rate) {
                out.append((px, s))
            }
            px += step
        }
        return out
    }
    /// Filled min/max waveform inside an audio clip: stereo = left in the upper half and right in the lower half with a
    /// separator; mono = full height. Silence draws a thin centre line. Pending analysis draws a dashed centre line;
    /// an unavailable source draws nothing. Only the visible part is drawn.
    private func drawWaveform(_ c: Clip, _ r: NSRect, _ state: WaveformStore.State, area: NSRect, clip: NSBezierPath) {
        // below the clip-name strip (label at minY + 4, 16 pt tall); full height only if a lane is ever too short for it
        let strip = r.height >= Self.waveformLabelStrip + 24 ? Self.waveformLabelStrip : 2
        let inner = NSRect(x: r.minX + 1, y: r.minY + strip, width: r.width - 2, height: r.height - strip - 2)
        guard inner.height > 4, inner.width > 1 else { return }
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let visible = inner.intersection(area)
        // A redraw area that misses this clip gives the null rect (infinite origin): drawing a line there raises in NSBezierPath.
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        switch state {
        case .unavailable:
            return
        case .pending:
            let line = NSBezierPath(); line.lineWidth = 1; line.setLineDash([3, 3], count: 2, phase: 0)
            line.move(to: NSPoint(x: visible.minX, y: inner.midY)); line.line(to: NSPoint(x: visible.maxX, y: inner.midY))
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke(); line.stroke()
        case .ready(let peaks):
            let n = min(peaks.channelCount, 2)
            let laneH = inner.height / CGFloat(n)
            let cols = waveformColumns(c, rate: peaks.sampleRate, visible: visible)
            for ch in 0..<n {
                let band = NSRect(x: inner.minX, y: inner.minY + CGFloat(ch) * laneH, width: inner.width, height: laneH)
                let mid = band.midY, half = band.height / 2 - 0.5
                var tops: [NSPoint] = [], bottoms: [NSPoint] = []
                tops.reserveCapacity(cols.count * 2); bottoms.reserveCapacity(cols.count * 2)
                for col in cols {
                    guard let e = peaks.envelope(channel: ch, samples: col.samples) else { continue }
                    // flipped view: positive amplitude is drawn upward (smaller y)
                    let top = mid - CGFloat(e.max) * half, bottom = mid - CGFloat(e.min) * half
                    tops.append(NSPoint(x: col.x, y: top)); tops.append(NSPoint(x: col.x + 1, y: top))
                    bottoms.append(NSPoint(x: col.x, y: bottom)); bottoms.append(NSPoint(x: col.x + 1, y: bottom))
                }
                NSColor.labelColor.withAlphaComponent(0.25).setFill()   // centre (silence) line
                NSRect(x: visible.minX, y: mid - 0.25, width: visible.width, height: 0.5).fill()
                if let first = tops.first {
                    let shape = NSBezierPath(); shape.move(to: first)
                    tops.dropFirst().forEach { shape.line(to: $0) }
                    bottoms.reversed().forEach { shape.line(to: $0) }
                    shape.close()
                    Self.waveformFill.setFill(); shape.fill()
                }
                if n == 2, ch == 0 {   // separation between the left (upper) and right (lower) halves
                    NSColor.separatorColor.setFill()
                    NSRect(x: visible.minX, y: band.maxY - 0.5, width: visible.width, height: 1).fill()
                }
            }
        }
    }
    private func envelopeY(_ g: Double, _ r: NSRect) -> CGFloat { r.maxY - 4 - CGFloat(g) * (r.height - 12) }
    /// 소리 클립 위: 클립 음량 × 페이드 모양의 선(레인 음량 제외), 줄어든 부분은 어둡게, 클립 음소거·음량 표시,
    /// 고른 소리 클립(연결된 쌍의 소리 포함)에는 페이드 손잡이(위쪽 모서리, 페이드 끝 위치).
    private func drawAudioEnvelope(_ c: Clip, _ r: NSRect, _ st: TimelineDrawState) {
        let a = c.effectiveAudio
        let pts = a.breakpoints(length: c.length).map { b in
            NSPoint(x: x(c.start + b), y: envelopeY(a.gain * a.envelope(at: Double(b), length: c.length), r))
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).addClip()
        let shade = NSBezierPath()
        shade.move(to: NSPoint(x: r.minX, y: r.minY)); pts.forEach { shade.line(to: $0) }; shade.line(to: NSPoint(x: r.maxX, y: r.minY)); shade.close()
        NSColor.black.withAlphaComponent(0.28).setFill(); shade.fill()
        let line = NSBezierPath(); line.lineWidth = 1.5
        if let f = pts.first { line.move(to: f); pts.dropFirst().forEach { line.line(to: $0) } }
        NSColor.systemYellow.withAlphaComponent(0.9).setStroke(); line.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let tag = a.muted ? "클립 음소거" : (a.volumePercent != 100 ? "클립 \(a.volumePercent)%" : nil)
        if let tag, r.width > 60 {
            NSString(string: tag).draw(at: NSPoint(x: r.minX + 6, y: r.maxY - 15), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                                                                    .foregroundColor: a.muted ? NSColor.systemOrange : NSColor.labelColor])
        }
        if fadeHandleClips(st).contains(c.id) {
            for e in [ProjectStore.FadeEdge.fadeIn, .fadeOut] {
                let h = fadeHandleRect(c, e, r)
                let p = NSBezierPath(rect: h); NSColor.white.setFill(); p.fill()
                NSColor.systemYellow.setStroke(); p.lineWidth = 1.5; p.stroke()
            }
            if case .fade(let id, let e, _) = drag, id == c.id {   // 끌기 중 길이 표시
                let f = e == .fadeIn ? a.fadeIn.visible(in: c.length) : a.fadeOut.visible(in: c.length)
                let text = NSString(string: (e == .fadeIn ? "페이드 인 " : "페이드 아웃 ") + FadeText.seconds(f) + "초")
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
                let sz = text.size(withAttributes: attrs), h = fadeHandleRect(c, e, r)
                let b = NSRect(x: min(max(r.minX, h.midX - sz.width / 2 - 4), max(r.minX, r.maxX - sz.width - 8)), y: r.minY - sz.height - 4, width: sz.width + 8, height: sz.height + 2)
                NSColor.black.withAlphaComponent(0.75).setFill(); NSBezierPath(roundedRect: b, xRadius: 3, yRadius: 3).fill()
                text.draw(at: NSPoint(x: b.minX + 4, y: b.minY + 1), withAttributes: attrs)
            }
        }
    }
    /// 페이드 손잡이를 보일 소리 클립: 고른 클립의 묶음(연결된 쌍이면 소리 쪽) 가운데 소리 클립
    func fadeHandleClips(_ st: TimelineDrawState) -> Set<UUID> {
        guard st.tool == .selection, let sel = st.selection else { return [] }   // 자르기 도구에서는 손잡이 없음(페이드 끌기 안 함)
        return Set(st.timeline.group(of: sel).filter { st.timeline.lane(of: $0.id) == .audio }.map(\.id))
    }
    /// 손잡이 사각형(8×8): 페이드 인은 페이드 끝, 페이드 아웃은 페이드 시작 위치의 클립 위쪽
    func fadeHandleRect(_ c: Clip, _ e: ProjectStore.FadeEdge, _ r: NSRect) -> NSRect {
        let a = c.effectiveAudio
        let cx = min(max(fadeHandleX(c, e), r.minX + 4), r.maxX - 4)
        return NSRect(x: cx - 4, y: r.minY + 2, width: 8, height: 8)
    }
    /// 페이드 끝(인)·시작(아웃)의 실제 x. 손잡이는 클립 안쪽 4pt로 당겨 그리지만, 잡은 곳의 거리는 이 값에서 잰다
    /// (당긴 가운데에서 재면 손잡이를 잡고 조금만 움직여도 페이드가 4pt만큼 생겼다, 2026-10-11 리뷰).
    func fadeHandleX(_ c: Clip, _ e: ProjectStore.FadeEdge) -> CGFloat {
        let a = c.effectiveAudio
        return e == .fadeIn ? x(c.start + a.fadeIn.visible(in: c.length)) : x(c.end - a.fadeOut.visible(in: c.length))
    }
    /// 페이드 손잡이 누름(손잡이 둘레 6pt). 두 손잡이가 겹치면 포인터에 가까운 쪽.
    func fadeHandleHit(_ p: NSPoint) -> (UUID, ProjectStore.FadeEdge, CGFloat)? {
        guard let st = state else { return nil }
        var best: (UUID, ProjectStore.FadeEdge, CGFloat, CGFloat)?
        for id in fadeHandleClips(st) {
            guard let c = st.timeline.clip(id) else { continue }
            let r = rect(c)
            for e in [ProjectStore.FadeEdge.fadeIn, .fadeOut] {
                let h = fadeHandleRect(c, e, r).insetBy(dx: -6, dy: -5)
                guard h.contains(p) else { continue }
                let d = abs(p.x - h.midX)
                if best == nil || d < best!.3 { best = (id, e, p.x - fadeHandleX(c, e), d) }
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    /// Also called by the fixed `TimelineRulerView` (TIMELINE-STICKY-RULER-01) with the context translated to document x.
    func drawRuler(_ st: TimelineDrawState, area: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight).fill()
        let fps = Int(store.settings.fps)
        // 눈금 간격: 라벨이 70px 이상 떨어지도록 초 단위 선택
        let candidates = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let stepSec = candidates.first { CGFloat($0 * fps) * pixelsPerFrame >= 70 } ?? 600
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let lastFrame = min(frame(atX: bounds.width), frame(atX: area.maxX) + 1)
        // 그릴 영역 왼쪽 밖 70pt(눈금 글자 폭)부터의 눈금만(위치는 0에서 같은 간격 그대로)
        let step = stepSec * fps
        var f = max(0, frame(atX: area.minX - 70) / step * step)
        NSColor.tertiaryLabelColor.setFill()
        while f <= lastFrame {
            let px = x(f)
            NSRect(x: px, y: Self.rulerHeight - 8, width: 1, height: 8).fill()
            let s = f / fps
            NSString(string: String(format: "%d:%02d", s / 60, s % 60)).draw(at: NSPoint(x: px + 3, y: 4), withAttributes: attrs)
            f += stepSec * fps
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: Self.rulerHeight - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: 마우스

    func clipHit(_ p: NSPoint) -> (UUID, ProjectStore.TrimEdge?)? {
        guard let st = state else { return nil }
        for (lane, l) in Self.layout(st.timeline.lanes) {
            guard p.y >= l.minY, p.y <= l.maxY else { continue }
            for s in st.timeline.subtitles(inLane: lane.id) {   // 자막(2026-10-22): 클립과 같은 누름 판정
                let x0 = x(s.start), x1 = x(s.end)
                guard p.x >= x0 - 1, p.x <= x1 + 1 else { continue }
                let grab = min(Self.edgeGrab, (x1 - x0) / 3)
                if p.x <= x0 + grab { return (s.id, .start) }
                if p.x >= x1 - grab { return (s.id, .end) }
                return (s.id, nil)
            }
            for c in st.timeline.clips(inLane: lane.id) {
                let x0 = x(c.start), x1 = x(c.end)
                guard p.x >= x0 - 1, p.x <= x1 + 1 else { continue }
                let grab = min(Self.edgeGrab, (x1 - x0) / 3)
                if p.x <= x0 + grab { return (c.id, .start) }
                if p.x >= x1 - grab { return (c.id, .end) }
                return (c.id, nil)
            }
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) {
        #if DEBUG
        defer { store.traceGestureDebug("timeline mouseDown phase=\(dragNameForTest)", event: e) }
        #endif
        window?.makeFirstResponder(self)
        // 새 왼쪽 누름이 왔는데 끌기가 남아 있으면 그 끌기는 놓기를 받지 못한 것이다: 취소한다(D-031, 다음 끌기와 함께 확정하지 않음)
        if store.gestureBase != nil { store.interruptGesture() }
        let p = convert(e.locationInWindow, from: nil)
        if p.y < Self.firstLaneY {
            beginScrub(p, shift: e.modifierFlags.contains(.shift)); return
        }
        if store.tool == .cut {
            // 자르기 도구(D-030): 수정 키 없는 왼쪽 누름이 클립 본문에 있으면 그 프레임에서 한 번 자른다. 이어지는 끌기는 무시한다
            // (옮기기·트림·페이드·연속 자르기 없음). 빈 곳·수정 키 누름은 아무것도 하지 않는다(선택 그대로).
            drag = .none
            guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, let (id, f) = cutTarget(p) else { return }
            store.cutClip(id, atFrame: f)
            return
        }
        if store.tool == .text {
            // 텍스트 도구(§44 정정): 타임라인을 눌러 자막을 만들지 않는다. 자막을 누르면 고르기만 하고, 끌기는 하지 않는다.
            // 만들기·글 쓰기는 프리뷰 화면에서(또는 타임라인 > 자막 추가).
            drag = .none
            guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return }
            if let (id, _) = clipHit(p), store.timeline.subtitle(id) != nil { store.pauseForEdit(); store.select(id); return }
            store.statusMessage = "텍스트 도구: 프리뷰 화면을 누르면 그 자리에 자막을 만듭니다."
            return
        }
        if store.gestureBase == nil, let (id, edge, grab) = fadeHandleHit(p) {   // 페이드 손잡이(트림·옮기기보다 먼저)
            store.beginFadeGesture()
            drag = .fade(id, edge, grab)
            needsDisplay = true
            return
        }
        if let (id, edge) = clipHit(p) {
            if e.modifierFlags.contains(.command) { store.select(id, extend: true); drag = .none; return }   // 연결 후보
            if let edge {
                store.beginGesture(select: id)
                drag = .trim(id, edge, p.x)
            } else {
                store.pauseForEdit()
                store.select(id)
                drag = .pending(id, p)
            }
        } else if let (sid, edge) = spectrumTarget(p) {
            // 스펙트럼(SP-1A 2B-2 고르기, 2C-1 옮기기, 2C-2 트림 — 선택 도구만, 자르기·텍스트 도구는 위에서 이미 끝남). 가장자리는 클립·자막과 같이
            // 누르는 순간 트림 끌기(beginGesture → updateTrim → commitGesture/cancelGesture). 본문은 누르면 고르고, 4 pt를 넘겨 끌면 누름 대기 → 옮기기.
            // ⌘-클릭은 보통 고르기이고 끌기를 시작하지 않는다(클립 ⌘-클릭과 같음).
            if e.modifierFlags.contains(.command) { store.pauseForEdit(); store.select(sid); drag = .none }
            else if let edge { store.beginGesture(select: sid); drag = .trim(sid, edge, p.x) }
            else { store.pauseForEdit(); store.select(sid); drag = .pending(sid, p) }
        } else {
            store.select(nil); store.selectLane(nil); drag = .none
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        autoscroll(with: e)
        switch drag {
        case .scrub:
            scrub(p, shift: e.modifierFlags.contains(.shift))
        case .pending(let id, let p0):
            // 일반 끌기 = 옮기기(2026-10-11): 연결된 쌍·연결되지 않은 클립 모두 위치(와 같은 종류 레인)만 바꾼다. 리플·끼워 넣기 없음.
            guard abs(p.x - p0.x) > 4 || abs(p.y - p0.y) > 4 else { return }
            guard store.tool == .selection else { drag = .none; return }   // 누른 뒤 도구가 바뀌었으면 옮기지 않는다
            // 누른 클립이 없어졌거나 선택이 바뀌었으면 옮기지 않는다(CP-08: 저장소가 편집 명령 전에 대기를 지우지만, 다른 길로 바뀐 경우의 마지막 확인)
            guard store.timeline.clip(id) != nil || store.timeline.subtitle(id) != nil || store.timeline.spectrum(id) != nil, store.selection == id else { drag = .none; return }
            store.beginGesture(select: id)
            drag = .free(id, p0.x)
            #if DEBUG
            store.traceGestureDebug("timeline moveStartsFromPress", event: e)
            #endif
            updateDragMove(id, p, from: p0.x)
        case .free(let id, let x0):
            updateDragMove(id, p, from: x0)
        case .trim(let id, let edge, let x0):
            // Same screen distance as moving (8 pt / zoom); the store applies the snap only when the magnet is on.
            let raw = Double((p.x - x0) / pixelsPerFrame)
            store.updateTrim(id, edge: edge, delta: Int(raw.rounded()), rawDelta: raw, snapFrames: Double(Self.snapDistance / pixelsPerFrame))
        case .fade(let id, let edge, let grab):
            // 손잡이를 잡은 곳 그대로(누른 곳과 손잡이 가운데의 거리를 뺀다): 페이드 인은 클립 시작에서, 페이드 아웃은 클립 끝에서 잰 프레임
            guard let c = store.gestureBase?.clip(id) else { return }
            let hx = p.x - grab
            let f = edge == .fadeIn ? (hx - x(c.start)) / pixelsPerFrame : (x(c.end) - hx) / pixelsPerFrame
            store.updateFade(id, edge: edge, frames: Int(max(0, f).rounded()))
        case .none:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        #if DEBUG
        store.traceGestureDebug("timeline mouseUp phase=\(dragNameForTest)", event: e)
        #endif
        switch drag {
        case .trim, .free, .fade: store.commitGesture()
        case .scrub: store.endScrub()
        default: break
        }
        drag = .none
        needsDisplay = true
    }
    /// Last pointer position of a ruler scrub, so pressing or releasing Shift without moving re-evaluates the snap (TIMELINE-UI-POLISH-01).
    private var lastScrubPoint: NSPoint?
    override func flagsChanged(with e: NSEvent) {
        if case .scrub = drag, let p = lastScrubPoint { scrub(p, shift: e.modifierFlags.contains(.shift)) }
        super.flagsChanged(with: e)
    }
    private func beginScrub(_ p: NSPoint, shift: Bool) { store.pauseForEdit(); drag = .scrub; scrub(p, shift: shift) }
    /// TIMELINE-STICKY-RULER-01: a press on the fixed ruler. Same steps as a press in the document's ruler area; only the
    /// pointer's document x is used, so the vertical scroll position does not matter. Drags and the release are forwarded
    /// to `mouseDragged`/`mouseUp` by the ruler view; Shift changes and Esc arrive here as first responder.
    func rulerMouseDown(with e: NSEvent) {
        #if DEBUG
        defer { store.traceGestureDebug("timeline rulerMouseDown phase=\(dragNameForTest)", event: e) }
        #endif
        window?.makeFirstResponder(self)
        if store.gestureBase != nil { store.interruptGesture() }
        beginScrub(convert(e.locationInWindow, from: nil), shift: e.modifierFlags.contains(.shift))
    }
    /// Ruler scrub (TIMELINE-OVERWRITE-PASTE-01): the same frame as `frame(atX:)`; Shift + magnet snaps to clip boundaries (8 pt).
    private func scrub(_ p: NSPoint, shift: Bool) {
        lastScrubPoint = p
        store.scrubPlayhead(raw: Double((p.x - Self.inset) / pixelsPerFrame), snapFrames: Double(Self.snapDistance / pixelsPerFrame), shift: shift)
    }
    /// 끌어 옮기기 갱신: 문서 보기 좌표의 가로 거리 → 프레임(확대 배율), 붙음 거리는 화면 8pt를 프레임으로 바꾼다
    private func updateDragMove(_ id: UUID, _ p: NSPoint, from x0: CGFloat) {
        store.updateFreeMove(id, delta: Double((p.x - x0) / pixelsPerFrame), lane: lane(atY: p.y)?.id,
                             snapFrames: Double(Self.snapDistance / pixelsPerFrame))
    }

    /// 클립 문맥 메뉴: 연결 해제·연결·자르기·삭제(대상과 범위를 제목에 보인다)
    override func menu(for event: NSEvent) -> NSMenu? {
        // 끌기 중에는 메뉴를 띄우지 않는다(CP-01, 2026-10-11): 메뉴 추적이 왼쪽 놓기를 먹어 끌기가 끝나지 않았고,
        // 끌기 중에 켜져 있던 "연결 해제"가 편집 기록의 끌기 중 확인에서 앱을 멈췄다.
        guard store.gestureBase == nil else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        guard let (id, _) = clipHit(p) else { return nil }
        if !store.selectedIDs.contains(id) { store.select(id) }
        let linked = store.timeline.partner(of: store.selection ?? id) != nil
        let m = NSMenu()
        func add(_ title: String, _ enabled: Bool, _ action: Selector) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: ""); it.target = self; it.isEnabled = enabled; m.addItem(it)
        }
        m.autoenablesItems = false
        add("연결 해제(영상·소리 따로 편집)", store.canUnlink && store.gestureBase == nil, #selector(menuUnlink))
        add("연결(⌘-클릭한 클립과)", store.canLink && store.gestureBase == nil, #selector(menuLink))
        m.addItem(.separator())
        add(linked ? "재생 헤드에서 자르기(연결된 쌍)" : "재생 헤드에서 자르기", store.gestureBase == nil, #selector(menuSplit))
        add(linked ? "삭제 — 빈틈 남김(연결된 쌍)" : "삭제 — 빈틈 남김", store.gestureBase == nil, #selector(menuLift))
        add(linked ? "리플 삭제(연결된 쌍, 모든 레인)" : "리플 삭제(모든 레인)", store.gestureBase == nil, #selector(menuRipple))
        // 스펙트럼 추가(SP-1A 2B-2. SP-PUBLIC-01 2026-11-23부터 Debug·Release 공통): 누른 것이 소리 클립일 때만. 누른 클립과 메뉴를 만든 때의 프로젝트 회차를 항목에 묶는다.
        if store.timeline.audioClips.contains(where: { $0.id == id }) {
            m.addItem(.separator())
            let it = NSMenuItem(title: "스펙트럼 추가", action: #selector(menuAddSpectrum(_:)), keyEquivalent: "")
            it.target = self; it.isEnabled = store.gestureBase == nil
            it.representedObject = SpectrumMenuTarget(clip: id, session: store.projectSession)
            m.addItem(it)
        }
        return m
    }
    final class SpectrumMenuTarget: NSObject { let clip: UUID, session: Int; init(clip: UUID, session: Int) { self.clip = clip; self.session = session } }
    @objc func menuAddSpectrum(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? SpectrumMenuTarget else { return }
        store.addSpectrum(fromAudioClip: t.clip, session: t.session)
    }
    @objc private func menuUnlink() { store.unlinkSelection() }
    @objc private func menuLink() { store.linkSelection() }
    @objc private func menuSplit() { store.splitAtPlayhead() }
    @objc private func menuLift() { store.deleteSelection(ripple: false) }
    @objc private func menuRipple() { store.deleteSelection(ripple: true) }

    /// 드래그 중 Esc: 드래그 전 상태로 되돌린다(기록 없음).
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { cancelOperation(nil); return }
        // 보조 처리 층: 로컬 감시를 지나지 않고 전달된 편집기 단축키(KeyRouting 설명 참조)
        if KeyRouting.route(e, layer: "timelineKeyDown", store: store) { return }
        super.keyDown(with: e)
    }
    override func cancelOperation(_ sender: Any?) {
        switch drag {
        case .trim, .free, .fade: store.cancelGesture(); drag = .none; needsDisplay = true
        case .scrub: store.endScrub(); drag = .none; needsDisplay = true   // TIMELINE-UI-POLISH-01: Esc ends the scrub (playhead stays) and clears its guide/markers
        default: break
        }
    }


    // MARK: 자르기 도구(D-030)

    /// 자르기 대상: 레인 영역의 클립 본문(가장자리 포함, 트림·페이드로 보지 않음)과 포인터의 가장 가까운 프레임. 안내선과 실제 자르기가 같은 변환을 쓴다.
    func cutTarget(_ p: NSPoint) -> (UUID, Int)? {
        guard p.y >= Self.firstLaneY, let (id, _) = clipHit(p) else { return nil }
        return (id, frame(atX: p.x))
    }
    /// 안내선(보이는 것은 자를 수 있는 위치뿐): 클립과 프레임. 포인터가 나가거나 도구가 바뀌거나 대상이 자를 수 없게 되면 nil.
    private(set) var cutHover: (id: UUID, frame: Int)?
    private var hoverPoint: NSPoint?
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a); hoverArea = a
    }
    override func mouseMoved(with e: NSEvent) { hoverPoint = convert(e.locationInWindow, from: nil); refreshCutHover() }
    override func mouseExited(with e: NSEvent) { hoverPoint = nil; refreshCutHover() }
    /// 안내선 다시 판정(포인터 이동·상태 변화 때). 자를 수 없는 위치(경계·클립 밖·짝이 덮지 않음)는 보이지 않는다.
    func refreshCutHover() {
        var next: (id: UUID, frame: Int)?
        if state?.tool == .cut, store.gestureBase == nil, let p = hoverPoint, let (id, f) = cutTarget(p), store.cutCheck(id, atFrame: f) == .valid { next = (id, f) }
        if next?.id != cutHover?.id || next?.frame != cutHover?.frame { cutHover = next; needsDisplay = true }
    }
    /// 가위 커서(SF Symbol). 만들 수 없으면 십자 커서.
    static let cutCursor: NSCursor = {
        guard let img = NSImage(systemSymbolName: "scissors", accessibilityDescription: "자르기")?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) else { return .crosshair }
        return NSCursor(image: img, hotSpot: NSPoint(x: img.size.width / 2, y: img.size.height / 2))
    }()

    /// TIMELINE-STICKY-RULER-01: the visible lane area in document coordinates — the visible rect without the top strip that the
    /// fixed ruler covers. Cursor rects are limited to it so a clip scrolled under the ruler does not change the pointer there.
    var laneVisibleRect: NSRect {
        var v = visibleRect
        guard !v.isEmpty else { return v }
        let cut = min(Self.rulerHeight, v.height)
        v.origin.y += cut; v.size.height -= cut
        return v
    }
    override func resetCursorRects() {
        let lanesVisible = laneVisibleRect
        // 보이는 부분만: 화면 밖 클립의 교집합은 null 사각형(원점 무한)이라 그대로 넣으면 AppKit 예외로 앱이 멈췄다(2026-10-23 검증 중 발견, 자르기 도구 + 화면 밖 항목)
        func add(_ r: NSRect, _ cursor: NSCursor) { let v = r.intersection(lanesVisible); if !v.isEmpty { addCursorRect(v, cursor: cursor) } }
        if let st = state, st.tool == .cut {   // 자르기 도구: 클립 본문 위에서 가위 커서(트림·페이드 커서 없음)
            for c in st.timeline.clips + st.timeline.audioClips { add(rect(c), Self.cutCursor) }
            for sub in st.timeline.subtitles { add(subtitleRect(sub), Self.cutCursor) }
            return
        }
        if let st = state, st.tool == .text { _ = st; return }   // 텍스트 도구: 타임라인에서는 고르기만(트림·옮기기 커서 없음)
        guard let st = state, let sel = st.selection else { return }
        for id in fadeHandleClips(st) {   // 페이드 손잡이(트림 커서보다 위)
            guard let c = st.timeline.clip(id) else { continue }
            for e in [ProjectStore.FadeEdge.fadeIn, .fadeOut] { add(fadeHandleRect(c, e, rect(c)).insetBy(dx: -6, dy: -5), .crosshair) }
        }
        for r in st.timeline.group(of: sel).map({ rect($0) }) + (st.timeline.subtitle(sel).map { [subtitleRect($0)] } ?? [])
                    + (st.timeline.spectrum(sel).map { [spectrumRect($0)] } ?? []) {   // 스펙트럼 트림 커서(2C-2)
            add(NSRect(x: r.minX - 2, y: r.minY, width: Self.edgeGrab + 2, height: r.height), .resizeLeftRight)
            add(NSRect(x: r.maxX - Self.edgeGrab, y: r.minY, width: Self.edgeGrab + 2, height: r.height), .resizeLeftRight)
        }
    }

    // MARK: 미디어 목록에서 끌어 놓기(A-014: 레인과 위치를 고른다)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = mediaID(sender) != nil
        setHover(ok); dropPoint = ok ? convert(sender.draggingLocation, from: nil) : nil; needsDisplay = true
        return ok ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { setHover(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setHover(false) }
    private func setHover(_ h: Bool) { if !h { dropPoint = nil }; if dropHover != h { dropHover = h; needsDisplay = true } }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHover(false)
        guard let id = mediaID(sender) else { return false }
        drop(id, windowPoint: sender.draggingLocation)
        return true
    }
    /// TIMELINE-STICKY-RULER-01: media dragged over / dropped on the fixed ruler. The time is the pointer's document x; the y is
    /// the ruler (0), so the drop goes to the base lane of the media's kind as a drop on the ruler always did, whatever the
    /// vertical scroll position (never to a lane row hidden under the ruler).
    func rulerDraggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = mediaID(sender) != nil
        setHover(ok); dropPoint = ok ? NSPoint(x: convert(sender.draggingLocation, from: nil).x, y: 0) : nil; needsDisplay = true
        return ok ? .copy : []
    }
    func rulerPerformDrag(_ sender: NSDraggingInfo) -> Bool {
        setHover(false)
        guard let id = mediaID(sender) else { return false }
        drop(id, at: NSPoint(x: convert(sender.draggingLocation, from: nil).x, y: 0))
        return true
    }
    /// 창 좌표의 놓은 위치(NSDraggingInfo.draggingLocation) → 문서 보기 좌표(가로·세로 스크롤 반영) → 레인·프레임
    func drop(_ id: UUID, windowPoint: NSPoint) { drop(id, at: convert(windowPoint, from: nil)) }
    /// 놓은 위치 해석(2026-10-11): 시각은 놓은 x 그대로(문서 보기 좌표 → 프레임, 끼워 넣기 없음).
    /// 레인 위는 그 레인, 눈금자 위는 그 종류의 기본 레인(V1·A1), 레인 아래 빈 곳은 바깥쪽 새 레인.
    func drop(_ id: UUID, at p: NSPoint) {
        let target: UUID?
        if p.y < Self.firstLaneY {
            let video = store.timeline.media.first { $0.id == id }?.hasVideo ?? true
            target = store.timeline.baseLane(video ? .video : .audio)?.id
        }
        else if p.y > lanesBottom + Self.laneGap / 2 { target = nil }
        else { target = lane(atY: p.y)?.id }
        store.placeMedia(id, atFrame: frame(atX: p.x), lane: target)
    }
    private func mediaID(_ s: NSDraggingInfo) -> UUID? {
        guard let str = s.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: str),
              store.assets.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}
