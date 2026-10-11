import AppKit
import Observation

/// 창·편집기 배치(A-012).
/// - 처음 실행(저장된 위치 없음): 바깥 창을 대상 화면의 쓸 수 있는 영역(메뉴 막대·Dock 제외, visibleFrame, 논리 포인트) 너비·높이의 70%로,
///   그 영역 가운데에 둔다. 최소 크기가 들어가면 최소 크기 이상, 쓸 수 있는 영역을 넘지 않는다.
/// - 다음 실행: 마지막 보통 창 위치·크기(전체 화면·확대 아님)를 되살린다. 쓸 수 있는 화면 밖이면 크기를 줄이고 안으로 옮긴다.
/// - 편집기 나눔 비율: 위 패널 70% · 타임라인 30%(툴바와 나눔선 두께 제외), 위 패널은 목록 20% · 프리뷰 60% · 정보 20%.
///   나눔선을 끌어 바꾼 비율을 기억한다.
/// 저장소는 UserDefaults다. 자체 검사는 `-OTFLayoutSuite <이름>`으로 따로 둔 저장소를 써서 사용자의 저장값을 건드리지 않는다.
@MainActor
@Observable
final class EditorLayout {
    static let shared = EditorLayout()
    /// 기본 배치: 위 패널 70%·타임라인 30%, 위 패널은 목록 15%·프리뷰 70%·정보 15%(2026-10-10 조정, 이전 20/60/20).
    /// 이미 저장된 비율은 사용자가 "기본 배치로 재설정"을 고를 때까지 그대로 쓴다.
    static let defaultUpper = 0.7, defaultMedia = 0.15, defaultInspector = 0.15
    /// 패널 최소 크기(포인트). 공간이 모자라면 각 패널 안에서 스크롤한다.
    static let minMedia: CGFloat = 160, minPreview: CGFloat = 320, minInspector: CGFloat = 180, minUpper: CGFloat = 240, minTimeline: CGFloat = 150
    static let divider: CGFloat = 1
    /// 편집기 내용 최소 크기(창 최소 크기의 기준)
    static let minContent = NSSize(width: minMedia + minPreview + minInspector + 2 * divider + 40, height: minUpper + minTimeline + divider + 40)

    var upperFraction: Double
    var mediaFraction: Double
    var inspectorFraction: Double
    /// 목록·정보 패널 접힘(접어도 비율은 그대로 두어, 펼치면 이전 너비로 돌아온다)
    var mediaCollapsed: Bool
    var inspectorCollapsed: Bool
    /// 왼쪽 패널 탭(2026-10-11): 미디어 목록 / 클립 조정. 사용자가 고른 탭을 기억하고, 클립을 골라도 바꾸지 않는다.
    enum LeftTab: String { case media, adjust }
    var leftTab: LeftTab { didSet { defaults.set(leftTab.rawValue, forKey: Self.leftTabKey) } }
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let suiteName: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private(set) var restoredFrom: String = "none"
    @ObservationIgnored private weak var window: NSWindow?
    /// 마지막으로 그린 내용 크기와 나눔(자체 검사용 기록)
    @ObservationIgnored var lastContentSize: CGSize = .zero
    @ObservationIgnored var lastSplit: Split?

    static let frameKey = "editor.windowFrame", upperKey = "editor.split.upper", mediaKey = "editor.split.media", inspectorKey = "editor.split.inspector"
    static let mediaCollapsedKey = "editor.split.mediaCollapsed", inspectorCollapsedKey = "editor.split.inspectorCollapsed"
    static let leftTabKey = "editor.leftTab"

    init() {
        #if DEBUG
        // 자체 검사 전용: 사용자 저장값을 건드리지 않게 따로 둔 저장소(Release에는 없음)
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-OTFLayoutSuite"), i + 1 < args.count, let d = UserDefaults(suiteName: args[i + 1]) {
            defaults = d; suiteName = args[i + 1]
        } else { defaults = .standard; suiteName = nil }
        #else
        defaults = .standard; suiteName = nil
        #endif
        let d = defaults
        func load(_ k: String, _ v: Double) -> Double { let x = d.double(forKey: k); return x > 0 && x < 1 ? x : v }
        upperFraction = load(Self.upperKey, Self.defaultUpper)
        mediaFraction = load(Self.mediaKey, Self.defaultMedia)
        inspectorFraction = load(Self.inspectorKey, Self.defaultInspector)
        mediaCollapsed = d.bool(forKey: Self.mediaCollapsedKey)
        inspectorCollapsed = d.bool(forKey: Self.inspectorCollapsedKey)
        leftTab = d.string(forKey: Self.leftTabKey).flatMap(LeftTab.init(rawValue:)) ?? .media
    }

    func saveFractions() {
        defaults.set(upperFraction, forKey: Self.upperKey)
        defaults.set(mediaFraction, forKey: Self.mediaKey)
        defaults.set(inspectorFraction, forKey: Self.inspectorKey)
        defaults.set(mediaCollapsed, forKey: Self.mediaCollapsedKey)
        defaults.set(inspectorCollapsed, forKey: Self.inspectorCollapsedKey)
    }
    func toggleMedia() { mediaCollapsed.toggle(); saveFractions() }
    func toggleInspector() { inspectorCollapsed.toggle(); saveFractions() }
    /// 기본 배치로 재설정: 비율 70/30·15/70/15, 양쪽 패널 펼침. 창 위치·크기는 바꾸지 않는다.
    func resetToDefault() {
        upperFraction = Self.defaultUpper; mediaFraction = Self.defaultMedia; inspectorFraction = Self.defaultInspector
        mediaCollapsed = false; inspectorCollapsed = false
        saveFractions()
    }

    // MARK: 창

    /// 편집기 창이 붙을 때 한 번: 최소 크기 조정, 처음 크기 또는 되살린 크기, 이후 변경 저장
    func attach(_ w: NSWindow) {
        guard window !== w else { return }
        window = w
        let target = Self.frame(saved: defaults.string(forKey: Self.frameKey).map(NSRectFromString), window: w, screens: NSScreen.screens,
                                fallback: w.screen ?? NSScreen.main)
        restoredFrom = target.source
        apply(target.rect, to: w)
        // SwiftUI가 창을 처음 배치하면서 크기를 다시 정할 수 있어 다음 차례에 한 번 더 적용한다
        DispatchQueue.main.async { [weak self, weak w] in
            MainActor.assumeIsolated {
                guard let self, let w else { return }
                self.apply(target.rect, to: w)
                self.observe(w)
            }
        }
    }

    private func apply(_ r: NSRect, to w: NSWindow) {
        if let vf = (w.screen ?? NSScreen.main)?.visibleFrame {
            // 작은 화면: 최소 크기가 쓸 수 있는 영역을 넘지 않게 줄인다
            let chrome = w.frame.height - w.contentLayoutRect.height
            w.contentMinSize = NSSize(width: min(Self.minContent.width, vf.width), height: min(Self.minContent.height, vf.height - chrome))
        }
        w.setFrame(r, display: true)
    }

    private func observe(_ w: NSWindow) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: w, queue: .main) { [weak self, weak w] _ in
                MainActor.assumeIsolated { if let w { self?.saveFrame(w) } }
            }
        }
    }

    /// 보통 창(전체 화면·확대 아님)의 위치·크기를 저장한다
    func saveFrame(_ w: NSWindow) {
        guard !w.styleMask.contains(.fullScreen), !w.isZoomed else { return }
        defaults.set(NSStringFromRect(w.frame), forKey: Self.frameKey)
    }

    /// 창 위치 결정(순수 계산, 검사 가능): 저장값이 있으면 가장 많이 겹치는 화면의 쓸 수 있는 영역 안으로 맞추고, 없으면 70% 가운데.
    static func frame(saved: NSRect?, window w: NSWindow, screens: [NSScreen], fallback: NSScreen?) -> (rect: NSRect, source: String) {
        let minFrame = w.frameRect(forContentRect: NSRect(origin: .zero, size: minContent)).size
        if let s = saved, s.width > 0, s.height > 0 {
            let best = screens.max { $0.visibleFrame.intersection(s).area < $1.visibleFrame.intersection(s).area }
            let vf = (best.flatMap { $0.visibleFrame.intersection(s).area > 0 ? $0 : nil } ?? fallback ?? best)?.visibleFrame ?? s
            return (fit(s, in: vf), vf.intersection(s) == s ? "restored" : "restored-adjusted")
        }
        guard let vf = fallback?.visibleFrame else { return (w.frame, "unchanged") }
        let size = NSSize(width: min(vf.width, max(minFrame.width, (vf.width * 0.7).rounded())),
                          height: min(vf.height, max(minFrame.height, (vf.height * 0.7).rounded())))
        return (NSRect(x: (vf.midX - size.width / 2).rounded(), y: (vf.midY - size.height / 2).rounded(), width: size.width, height: size.height), "initial-70")
    }
    /// r을 vf 안으로(크기는 vf를 넘지 않게, 위치는 안쪽으로)
    static func fit(_ r: NSRect, in vf: NSRect) -> NSRect {
        let w = min(r.width, vf.width), h = min(r.height, vf.height)
        let x = min(max(r.minX, vf.minX), vf.maxX - w), y = min(max(r.minY, vf.minY), vf.maxY - h)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: 나눔 계산

    struct Split: Equatable { var media: CGFloat; var preview: CGFloat; var inspector: CGFloat; var upper: CGFloat; var timeline: CGFloat }
    /// 내용 크기 → 패널 크기(나눔선 두께 제외한 비율, 최소 크기 지킴). 접힌 패널은 0이고 그 나눔선도 없으며, 남는 폭은 프리뷰가 쓴다.
    /// 비율의 기준 폭은 접힘과 무관하게 (너비 − 나눔선 2개)라, 펼치면 접기 전 너비로 돌아온다(창 크기가 같으면).
    func split(for size: CGSize) -> Split {
        let d = Self.divider
        let availH = max(0, size.height - d)
        let upper = min(max(availH * upperFraction, Self.minUpper), max(Self.minUpper, availH - Self.minTimeline))
        let availW = max(0, size.width - 2 * d)
        var m = mediaCollapsed ? 0 : max(Self.minMedia, availW * mediaFraction), i = inspectorCollapsed ? 0 : max(Self.minInspector, availW * inspectorFraction)
        let over = Self.minPreview - (availW - m - i)
        if over > 0 {   // 프리뷰 최소 폭을 지키도록 양옆을 비율대로 줄인다(각 최소 폭까지)
            let rm = mediaCollapsed ? 0 : m - Self.minMedia, ri = inspectorCollapsed ? 0 : i - Self.minInspector
            let room = rm + ri
            if room > 0 { let k = min(1, over / room); m -= rm * k; i -= ri * k }
        }
        m = m.rounded(); i = i.rounded()
        let u = upper.rounded()
        let freedDividers = CGFloat((mediaCollapsed ? 1 : 0) + (inspectorCollapsed ? 1 : 0)) * d
        return Split(media: m, preview: max(0, availW + freedDividers - m - i), inspector: i, upper: u, timeline: max(0, availH - u))
    }
}

private extension NSRect { var area: CGFloat { isNull ? 0 : width * height } }
