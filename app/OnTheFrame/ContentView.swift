import AVFoundation
import OnTheFrameEngine
import SwiftUI
import UniformTypeIdentifiers

/// 화면 배치(M1): 위 툴바(프로젝트 이름·가져오기·내보내기), 왼쪽 영상 목록, 가운데 프리뷰·재생 제어, 오른쪽 선택한 클립 정보, 아래 타임라인.
struct ContentView: View {
    @Bindable var store: ProjectStore

    var body: some View {
        VSplitView {
            HSplitView {
                MediaListView(store: store).frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                PreviewPane(store: store).frame(minWidth: 480)
                InspectorView(store: store).frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            }
            .frame(minHeight: 360)
            TimelinePane(store: store).frame(minHeight: 180, idealHeight: 220)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(store.projectName).font(.headline).padding(.horizontal, 6)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.presentImportPanel() } label: { Label("가져오기", systemImage: "square.and.arrow.down") }
                    .help("영상 파일 가져오기(⌘I)")
                Button { store.presentExportPanel() } label: { Label("내보내기", systemImage: "square.and.arrow.up") }
                    .help("MP4로 내보내기(⌘E)").disabled(!store.canExport)
            }
        }
        .navigationTitle("ON THE FRAME")
        .background(WindowAccessor { store.attachEditorWindow($0) })
        // 내보내기 진행은 창을 막지 않는 카드로 보인다(내보내기는 시작 시점 스냅샷이므로 편집을 계속해도 결과가 바뀌지 않는다).
        .overlay(alignment: .top) { if store.exportPhase != .idle { ExportProgressCard(store: store).padding(.top, 10) } }
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

// MARK: - 왼쪽: 영상 목록

struct MediaListView: View {
    @Bindable var store: ProjectStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("영상").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            if store.assets.isEmpty {
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
                            Text("\(store.settings.timecode(a.frameCount)) · \(Int(a.displaySize.width))×\(Int(a.displaySize.height))\(a.hasAudio ? "" : " · 소리 없음")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.addToTimeline(a.id) } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.borderless).help("타임라인 끝에 추가")
                    }
                    .draggable(a.id.uuidString)
                }
            }
            if store.importing > 0 { ProgressView("확인 중…").controlSize(.small).padding(8) }
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
        VStack(alignment: .leading, spacing: 10) {
            Text("클립 정보").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let id = store.selection, let i = store.timeline.index(of: id), let m = store.mediaByID[store.timeline.clips[i].mediaID] {
                let c = store.timeline.clips[i], s = store.timeline.starts[i], tc = store.settings.timecode
                Group {
                    row("원본", m.name)
                    row("원본 구간", "\(tc(c.sourceIn)) – \(tc(c.sourceOut))")
                    row("타임라인", "\(tc(s)) – \(tc(s + c.length))")
                    row("길이", tc(c.length))
                    row("원본 크기", "\(Int(m.displaySize.width))×\(Int(m.displaySize.height))")
                    row("소리", m.hasAudio ? "있음(영상에 연결)" : "없음")
                }
            } else {
                Text("타임라인에서 클립을 선택하면 정보가 표시됩니다.").foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
        }
        .padding(12)
    }
    func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.callout).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}

// MARK: - 내보내기 진행

struct ExportProgressCard: View {
    @Bindable var store: ProjectStore
    var body: some View {
        HStack(spacing: 12) {
            Text("내보내는 중").font(.callout.weight(.medium))
            if case .running(let p) = store.exportPhase {
                ProgressView(value: p).frame(width: 200)
                Text(String(format: "%3.0f%%", p * 100)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Button("취소") { store.cancelExport() }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
    }
}
