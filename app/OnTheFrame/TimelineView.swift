import AppKit
import OnTheFrameEngine
import SwiftUI

/// 아래 영역: 상태 줄·확대 조절 + AppKit 타임라인(왼쪽 고정 레인 머리, 눈금자, 영상 레인들·오디오 레인들, 재생 헤드). A-012, A-014.
struct TimelinePane: View {
    @Bindable var store: ProjectStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("타임라인").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let m = store.statusMessage { Text(m).font(.callout).foregroundStyle(.orange).lineLimit(1) }
                Spacer()
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
            Divider()
            ZStack {
                TimelineRepresentable(store: store, state: TimelineDrawState(store: store), pixelsPerFrame: store.timelineZoom)
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
        proposalStart = store.freeMoveProposal?.start; proposalOK = store.freeMoveProposal?.ok ?? true; proposalID = store.freeMoveProposal?.id; proposalLane = store.freeMoveProposal?.lane
        missing = Set(store.missingMedia.keys)
        tool = store.tool
        missingFonts = Set(store.missingSubtitleFonts)
        names = Dictionary(uniqueKeysWithValues: store.timeline.media.map { ($0.id, $0.name) })
    }
}

struct TimelineRepresentable: NSViewRepresentable {
    let store: ProjectStore
    let state: TimelineDrawState
    let pixelsPerFrame: Double

    func makeNSView(context: Context) -> TimelineContainerView { TimelineContainerView(store: store) }
    func updateNSView(_ c: TimelineContainerView, context: Context) {
        let v = c.timelineView, sv = c.scrollView
        v.state = state
        let oldPPF = v.pixelsPerFrame, newPPF = CGFloat(pixelsPerFrame)
        // 가로 확대(2026-10-24, 소유자 요청): 확대 배율이 바뀌면 기준 시각을 보이는 영역의 같은 가로 자리에 둔다(아래 zoomAnchor)
        let anchor = oldPPF != newPPF ? c.zoomAnchor(playhead: state.playhead, oldPPF: oldPPF) : nil
        v.pixelsPerFrame = newPPF
        let w = max(sv.contentSize.width, TimelineNSView.inset * 2 + CGFloat(state.timeline.durationFrames) * v.pixelsPerFrame + 200)
        v.setFrameSize(NSSize(width: w, height: max(sv.contentSize.height, TimelineNSView.contentHeight(state.timeline.lanes))))
        if let anchor { c.applyZoomAnchor(anchor, ppf: newPPF) }
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
        c.header.lanes = state.timeline.lanes
        c.header.selectedLane = state.selectedLane
        c.header.needsDisplay = true
    }
}

/// 레인 머리(왼쪽 고정, 가로 스크롤과 무관) + 가로로 스크롤하는 타임라인
final class TimelineContainerView: NSView {
    let header: LaneHeaderView
    let scrollView = NSScrollView()
    let timelineView: TimelineNSView
    init(store: ProjectStore) {
        header = LaneHeaderView(store: store)
        timelineView = TimelineNSView(store: store)
        super.init(frame: .zero)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.documentView = timelineView
        addSubview(header); addSubview(scrollView)
        // 세로 스크롤은 머리와 함께 움직이게 맞춘다(가로 스크롤은 머리에 영향 없음)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.header.verticalOffset = self.scrollView.contentView.bounds.minY; self.header.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

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
    }
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
    var verticalOffset: CGFloat = 0 { didSet { if let f = editor, let id = editingLane { f.frame = editorFrame(id) } } }
    private(set) var editor: NSTextField?
    private(set) var editingLane: UUID?
    private var finishing = false
    init(store: ProjectStore) { self.store = store; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func rowRect(_ id: UUID) -> NSRect {
        let r = TimelineNSView.layout(lanes).first { $0.lane.id == id }?.rect ?? .zero
        return NSRect(x: 0, y: r.minY - verticalOffset, width: bounds.width, height: r.height)
    }
    /// 그 종류의 첫 레인 줄(이전 자체 검사 호환)
    func rowRect(_ kind: LaneKind) -> NSRect { lanes.first { $0.kind == kind }.map { rowRect($0.id) } ?? .zero }
    func lane(at p: NSPoint) -> Lane? { lanes.first { rowRect($0.id).contains(p) } }

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
            add("레인 삭제…", #selector(deleteFromMenu(_:)), l.id, enabled: store.canRemoveLane(l))
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
    func beginRename(_ id: UUID) {
        guard editor == nil, let l = lanes.first(where: { $0.id == id }), store.gestureBase == nil else { return }
        let f = NSTextField(string: l.name)
        f.font = .systemFont(ofSize: 12, weight: .semibold)
        f.delegate = self
        f.focusRingType = .default
        f.setAccessibilityLabel("레인 이름")
        f.frame = editorFrame(id)
        addSubview(f)
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
    static let firstLaneY: CGFloat = 30, laneGap: CGFloat = 8, videoHeight: CGFloat = 54, audioHeight: CGFloat = 40, subtitleHeight: CGFloat = 34, spectrumHeight: CGFloat = 34
    /// 마지막 레인 아래 빈 곳(여기에 놓으면 파일 이름의 새 레인)
    static let dropZoneHeight: CGFloat = 44
    /// 영상 레인 묶음과 오디오 레인 묶음 사이 가운데 경계(2026-10-11): 레인 사이보다 넓은 틈과 경계선
    static let boundaryGap: CGFloat = 18
    /// 끌어 옮기기 붙음 거리(화면 포인트, 확대 배율과 무관)
    static let snapDistance: CGFloat = 8
    static func height(_ k: LaneKind) -> CGFloat {
        switch k { case .video: videoHeight; case .audio: audioHeight; case .subtitle: subtitleHeight; case .spectrum: spectrumHeight }
    }
    /// 레인 종류 색: 영상 청록, 오디오 초록, 자막 보라(2026-10-22), 스펙트럼 분홍(2026-10-25, SP-1A 2A)
    static func color(_ k: LaneKind) -> NSColor {
        switch k { case .video: .systemTeal; case .audio: .systemGreen; case .subtitle: .systemPurple; case .spectrum: .systemPink }
    }
    static func layout(_ lanes: [Lane]) -> [(lane: Lane, rect: NSRect)] {
        var y = firstLaneY
        return lanes.enumerated().map { i, l in
            let boundaryNext = l.kind == .video && i + 1 < lanes.count && lanes[i + 1].kind == .audio
            defer { y += height(l.kind) + (boundaryNext ? boundaryGap : laneGap) }
            return (l, NSRect(x: 0, y: y, width: 0, height: height(l.kind)))
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
        for (l, r) in rows where l.kind == .video || l.kind == .audio {   // 자막·스펙트럼 레인의 빈 곳은 빈틈이 아니다(그 항목 없음)
            for g in t.gaps(inLane: l.id) where g.upperBound >= fr.lowerBound && g.lowerBound <= fr.upperBound {
                drawGap(NSRect(x: x(g.lowerBound), y: r.minY, width: CGFloat(g.count) * pixelsPerFrame, height: r.height), label: l.kind == .video ? "빈틈" : "무음", area: area)
            }
        }
        let top = rows.first?.rect.minY ?? Self.firstLaneY, bottom = rows.last?.rect.maxY ?? Self.firstLaneY
        if let by = Self.boundaryY(t.lanes) { Self.drawBoundary(y: by, from: 0, to: bounds.width) }
        if t.durationFrames > 0 {   // 타임라인 끝(길이)
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: x(t.durationFrames) - 0.5, y: top - 6, width: 1, height: bottom - top + 12).fill()
        }
        // 보이는 프레임 범위에 걸친 클립·자막만(가장자리에 걸친 항목은 전체 모양 그대로 그려 잘린다). 순서는 그대로.
        for c in t.clips + t.audioClips where c.end >= fr.lowerBound && c.start <= fr.upperBound { drawClip(c, st) }
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
        let ph = x(min(st.playhead, t.durationFrames))
        NSColor.systemRed.setFill()
        NSRect(x: ph - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: ph - 5, y: 0)); tri.line(to: NSPoint(x: ph + 5, y: 0)); tri.line(to: NSPoint(x: ph, y: 7)); tri.close()
        tri.fill()
    }

    private func drawGap(_ r: NSRect, label: String, area: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        let shown = r.intersection(area)
        if !shown.isEmpty { NSColor.black.withAlphaComponent(0.55).setFill(); shown.fill() }
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
        let hatch = NSBezierPath(); hatch.lineWidth = 1
        // 빗금은 그릴 영역에 닿는 줄만(위치는 빈틈 시작 기준 8pt 간격 그대로 — 스크롤해도 무늬가 움직이지 않음)
        let start = r.minX - r.height, skip = max(0, ((area.minX - r.height - start) / 8).rounded(.down))
        var hx = start + skip * 8
        let end = min(r.maxX, area.maxX)
        while hx < end { hatch.move(to: NSPoint(x: hx, y: r.maxY)); hatch.line(to: NSPoint(x: hx + r.height, y: r.minY)); hx += 8 }
        hatch.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if r.width > 40, r.minX + 6 < area.maxX, r.minX + 60 > area.minX {
            NSString(string: label).draw(at: NSPoint(x: r.minX + 6, y: r.minY + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    private func drawClip(_ c: Clip, _ st: TimelineDrawState) {
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

    func spectrumRect(_ s: SpectrumItem) -> NSRect {
        let l = laneRect(s.lane) ?? .zero
        return NSRect(x: x(s.start), y: l.minY, width: max(1, CGFloat(s.length) * pixelsPerFrame), height: l.height)
    }
    /// 스펙트럼 항목(2026-10-25, SP-1A 2A): 읽기 전용 표시 — 분홍 점선 상자와 소스 상태 글자. 누름 판정(clipHit)·커서·끌기에 넣지 않아
    /// 고르거나 옮길 수 없다(편집 UI는 2B·2C). 지금 앱은 스펙트럼이 든 프로젝트를 열지 않으므로 Debug 자체 검사에서만 보인다.
    private func drawSpectrum(_ s: SpectrumItem, _ st: TimelineDrawState) {
        let r = spectrumRect(s)
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.systemPink.withAlphaComponent(0.22).setFill(); path.fill()
        path.setLineDash([4, 3], count: 2, phase: 0); path.lineWidth = 1
        NSColor.systemPink.withAlphaComponent(0.8).setStroke(); path.stroke()
        guard r.width > 24 else { return }
        let source: String
        switch st.timeline.spectrumSourceState(s) {
        case .unset: source = "소스 고르지 않음"
        case .missing: source = "소스 없음"
        case .ok: source = st.timeline.spectrumMediaID(s).flatMap { st.names[$0] } ?? "소스"
        }
        NSString(string: "≋  스펙트럼 · " + source).draw(with: NSRect(x: r.minX + 6, y: r.minY + 4, width: max(0, r.width - 12), height: 16),
                                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                     attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
    }

    // MARK: 소리 클립 음량·페이드(2026-10-11)

    /// 음량 선이 오가는 높이: 클립 아래(0%)에서 위 여백(100%)까지
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

    private func drawRuler(_ st: TimelineDrawState, area: NSRect) {
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
            store.pauseForEdit(); drag = .scrub; store.seek(to: frame(atX: p.x)); return
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
        } else {
            store.select(nil); store.selectLane(nil); drag = .none
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        autoscroll(with: e)
        switch drag {
        case .scrub:
            store.seek(to: frame(atX: p.x))
        case .pending(let id, let p0):
            // 일반 끌기 = 옮기기(2026-10-11): 연결된 쌍·연결되지 않은 클립 모두 위치(와 같은 종류 레인)만 바꾼다. 리플·끼워 넣기 없음.
            guard abs(p.x - p0.x) > 4 || abs(p.y - p0.y) > 4 else { return }
            guard store.tool == .selection else { drag = .none; return }   // 누른 뒤 도구가 바뀌었으면 옮기지 않는다
            // 누른 클립이 없어졌거나 선택이 바뀌었으면 옮기지 않는다(CP-08: 저장소가 편집 명령 전에 대기를 지우지만, 다른 길로 바뀐 경우의 마지막 확인)
            guard store.timeline.clip(id) != nil || store.timeline.subtitle(id) != nil, store.selection == id else { drag = .none; return }
            store.beginGesture(select: id)
            drag = .free(id, p0.x)
            #if DEBUG
            store.traceGestureDebug("timeline moveStartsFromPress", event: e)
            #endif
            updateDragMove(id, p, from: p0.x)
        case .free(let id, let x0):
            updateDragMove(id, p, from: x0)
        case .trim(let id, let edge, let x0):
            let d = Int(((p.x - x0) / pixelsPerFrame).rounded())
            store.updateTrim(id, edge: edge, delta: d)
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
        default: break
        }
        drag = .none
        needsDisplay = true
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
        return m
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

    override func resetCursorRects() {
        if let st = state, st.tool == .cut {   // 자르기 도구: 클립 본문 위에서 가위 커서(트림·페이드 커서 없음)
            // 보이는 부분만: 화면 밖 클립의 교집합은 null 사각형(원점 무한)이라 그대로 넣으면 AppKit 예외로 앱이 멈췄다(2026-10-23 검증 중 발견, 자르기 도구 + 화면 밖 항목)
            func add(_ r: NSRect) { let v = r.intersection(visibleRect); if !v.isEmpty { addCursorRect(v, cursor: Self.cutCursor) } }
            for c in st.timeline.clips + st.timeline.audioClips { add(rect(c)) }
            for sub in st.timeline.subtitles { add(subtitleRect(sub)) }
            return
        }
        if let st = state, st.tool == .text { _ = st; return }   // 텍스트 도구: 타임라인에서는 고르기만(트림·옮기기 커서 없음)
        guard let st = state, let sel = st.selection else { return }
        for id in fadeHandleClips(st) {   // 페이드 손잡이(트림 커서보다 위)
            guard let c = st.timeline.clip(id) else { continue }
            for e in [ProjectStore.FadeEdge.fadeIn, .fadeOut] { addCursorRect(fadeHandleRect(c, e, rect(c)).insetBy(dx: -6, dy: -5), cursor: .crosshair) }
        }
        for r in st.timeline.group(of: sel).map({ rect($0) }) + (st.timeline.subtitle(sel).map { [subtitleRect($0)] } ?? []) {
            addCursorRect(NSRect(x: r.minX - 2, y: r.minY, width: Self.edgeGrab + 2, height: r.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: r.maxX - Self.edgeGrab, y: r.minY, width: Self.edgeGrab + 2, height: r.height), cursor: .resizeLeftRight)
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
