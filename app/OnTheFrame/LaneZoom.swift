import AppKit
import Observation
import OnTheFrameEngine

/// LANE-VERTICAL-ZOOM-01: 타임라인 레인 높이(세로 확대)와 처음 맞춤(Auto Fit)의 화면 상태.
///
/// 레인 높이는 **화면 표시 상태**다. 프로젝트 파일에 저장하지 않고, 편집 실행 취소·다시 실행에 들어가지 않으며, 클립 시각·원본 위치·
/// 재생·Spectrum 동기에 영향을 주지 않는다. 앱을 다시 실행하거나 새 프로젝트를 만들거나 프로젝트를 열면 자동 맞춤 상태로 돌아간다(`reset()`).
///
/// 한 레인의 실제 높이 = 종류별 기본 높이 × 배율(읽을 수 있는 최소 `minScale` ~ 최대 `maxScale`), 포인트 단위로 반올림.
/// - 자동 맞춤(`autoFit`, 처음 상태): 배율은 `fitScale` 하나(보이는 타임라인 영역에 모든 레인이 들어가도록 `minScale`…1 사이). 기본 높이보다
///   키우지 않는다. 최소 배율로도 다 들어가지 않으면 최소 배율로 두고 세로 스크롤한다.
/// - 수동 확대(확대 단추·슬라이더·단축키를 쓰면): 전체 배율 `globalScale` × 레인별 배율 `laneFactor`. 창 크기나 선택이 바뀌어도 그대로다.
///   전체 확대는 레인별 배율을 건드리지 않으므로 레인 사이의 상대 높이가 유지된다.
/// - 모두 맞춤(`fitAll()`): 수동 값을 지우고 자동 맞춤으로 돌아간다(선택과 무관).
///
/// 모든 레인 위치 계산은 `TimelineNSView.layout(_:)`이 이 값을 읽어 한 곳에서 한다(레인 머리·클립·누름 판정·끌어 놓기·스냅 표시 공통).
@MainActor
@Observable
final class LaneZoom {
    static let shared = LaneZoom()

    /// 배율 한도: 0.7이면 영상 38 pt·오디오 45 pt(이름 줄 20 pt + 파형 25 pt)·자막/스펙트럼 24 pt, 3이면 영상 162 pt·오디오 192 pt.
    static let minScale: CGFloat = 0.7, maxScale: CGFloat = 3
    /// 단추·단축키 한 번의 배율
    static let step: CGFloat = 1.25
    /// 자동 맞춤에서 마지막 레인 아래에 남기는 여백(pt)
    static let fitBottomMargin: CGFloat = 8

    /// 확대 대상: 모든 레인 또는 한 레인
    enum Target: Equatable { case all, lane(UUID) }

    private(set) var autoFit = true
    /// 자동 맞춤 배율. 타임라인 보기가 배치 중에 바로 정하므로 SwiftUI 관찰 대상이 아니다(바뀌면 그 보기가 직접 다시 그린다).
    @ObservationIgnored private(set) var fitScale: CGFloat = 1
    private(set) var globalScale: CGFloat = 1
    private(set) var laneFactor: [UUID: CGFloat] = [:]
    /// 높이가 바뀔 때마다 늘어난다(SwiftUI가 타임라인을 다시 배치하게 하는 값)
    private(set) var revision = 0

    static func clamp(_ s: CGFloat) -> CGFloat { min(max(s, minScale), maxScale) }

    /// 레인의 실제 배율(한도 안)
    func scale(_ lane: Lane) -> CGFloat {
        autoFit ? Self.clamp(fitScale) : Self.clamp(globalScale * (laneFactor[lane.id] ?? 1))
    }
    /// 레인의 실제 높이(pt, 반올림)
    func height(_ lane: Lane) -> CGFloat { (TimelineNSView.height(lane.kind) * scale(lane)).rounded() }
    /// 대상의 지금 배율(슬라이더 값): 모든 레인이면 전체 배율, 한 레인이면 그 레인의 실제 배율
    func scale(of target: Target, lanes: [Lane]) -> CGFloat {
        switch target {
        case .all: return autoFit ? Self.clamp(fitScale) : Self.clamp(globalScale)
        case .lane(let id): return lanes.first { $0.id == id }.map { scale($0) } ?? (autoFit ? Self.clamp(fitScale) : Self.clamp(globalScale))
        }
    }

    // MARK: 수동 확대(단추·슬라이더·단축키가 모두 이 함수를 쓴다)

    /// 대상의 배율을 정한다. 처음 수동으로 바꾸면 자동 맞춤에서 나온다(그때의 맞춤 배율이 전체 배율이 되어 높이가 이어진다).
    /// 바뀌었으면 true.
    @discardableResult
    func setScale(_ value: CGFloat, target: Target, lanes: [Lane]) -> Bool {
        let before = lanes.map { height($0) }
        let wasAuto = autoFit
        if autoFit { globalScale = Self.clamp(fitScale); laneFactor = [:]; autoFit = false }
        let v = Self.clamp(value)
        switch target {
        case .all:
            globalScale = v
        case .lane(let id):
            guard lanes.contains(where: { $0.id == id }) else { break }
            laneFactor[id] = v / globalScale
        }
        let changed = lanes.map { height($0) } != before
        if changed || wasAuto { revision &+= 1 }
        return changed
    }
    /// 한 단계 확대(`direction` > 0) 또는 축소. 바뀌었으면 true(한도에 닿아 있으면 false).
    @discardableResult
    func stepZoom(_ direction: Int, target: Target, lanes: [Lane]) -> Bool {
        let current = scale(of: target, lanes: lanes)
        return setScale(direction > 0 ? current * Self.step : current / Self.step, target: target, lanes: lanes)
    }
    /// 모두 맞춤: 수동 값을 지우고 자동 맞춤으로. 맞춤 배율은 타임라인 보기가 지금 보이는 영역으로 다시 계산한다.
    func fitAll() {
        autoFit = true; globalScale = 1; laneFactor = [:]
        revision &+= 1
    }
    /// 새 프로젝트·프로젝트 열기: 처음 상태(자동 맞춤)
    func reset() {
        autoFit = true; fitScale = 1; globalScale = 1; laneFactor = [:]
        revision &+= 1
    }

    // MARK: 자동 맞춤 계산

    /// 레인 사이 틈과 눈금자 아래 시작 위치 등 배율과 무관한 높이 + 아래 여백
    static func fixedHeight(_ lanes: [Lane]) -> CGFloat {
        var gaps: CGFloat = 0
        for (i, l) in lanes.enumerated() where i + 1 < lanes.count {
            gaps += l.kind == .video && lanes[i + 1].kind == .audio ? TimelineNSView.boundaryGap : TimelineNSView.laneGap
        }
        return TimelineNSView.firstLaneY + gaps + fitBottomMargin
    }
    static func baseHeightSum(_ lanes: [Lane]) -> CGFloat { lanes.reduce(0) { $0 + TimelineNSView.height($1.kind) } }
    /// 모든 레인이 한 배율일 때 필요한 보이는 높이(눈금자부터 마지막 레인 아래 여백까지)
    static func neededHeight(_ lanes: [Lane], scale: CGFloat) -> CGFloat {
        fixedHeight(lanes) + lanes.reduce(0) { $0 + (TimelineNSView.height($1.kind) * scale).rounded() }
    }
    /// 보이는 높이에 모든 레인이 들어가는 배율(`minScale`…1). 레인이 없으면 1.
    static func fitScale(_ lanes: [Lane], visibleHeight: CGFloat) -> CGFloat {
        let sum = baseHeightSum(lanes)
        guard sum > 0 else { return 1 }
        var s = min(1, max(minScale, (visibleHeight - fixedHeight(lanes)) / sum))
        // 반올림으로 넘치면 조금씩 줄인다(최소 배율까지)
        while s > minScale, neededHeight(lanes, scale: s) > visibleHeight { s = max(minScale, s - 0.005) }
        return s
    }
    /// 자동 맞춤 배율 갱신(자동 맞춤일 때만). 바뀌었으면 true. 관찰 상태를 바꾸지 않으므로 보기 배치 중에 불러도 된다
    /// (호출한 타임라인 보기가 문서 높이·그리기를 직접 맞춘다).
    @discardableResult
    func updateFit(_ lanes: [Lane], visibleHeight: CGFloat) -> Bool {
        guard autoFit, visibleHeight > 0 else { return false }
        let s = Self.fitScale(lanes, visibleHeight: visibleHeight)
        guard abs(s - fitScale) > 0.0001 else { return false }
        fitScale = s
        return true
    }
}

// MARK: 저장소 쪽 진입점(레인 머리의 단추·슬라이더, 단축키, 메뉴가 모두 이 함수들을 쓴다)

extension ProjectStore {
    /// 세로 확대 대상(LANE-VERTICAL-ZOOM-01): 고른 클립·자막·스펙트럼이 있으면 그것이 놓인 레인, 아니면 레인 머리에서 고른 레인,
    /// 둘 다 없으면 모든 레인. 지워진 항목이나 레인을 가리키는 남은 선택 값은 무시한다(그 경우 다음 조건으로 넘어간다).
    var verticalZoomTarget: LaneZoom.Target {
        if let sel = selection,
           let lane = timeline.laneID(of: sel) ?? timeline.subtitle(sel)?.lane ?? timeline.spectrum(sel)?.lane,
           timeline.laneInfo(lane) != nil { return .lane(lane) }
        if let l = selectedLane, timeline.laneInfo(l) != nil { return .lane(l) }
        return .all
    }
    /// 한 단계 세로 확대(+1)·축소(−1). 끌기 중에는 하지 않는다. 높이가 바뀌었으면 true.
    @discardableResult
    func verticalZoom(step: Int) -> Bool {
        guard gestureBase == nil else { return false }
        return LaneZoom.shared.stepZoom(step, target: verticalZoomTarget, lanes: timeline.lanes)
    }
    /// 지금 대상의 세로 배율을 정한다(슬라이더). 끌기 중에는 하지 않는다.
    @discardableResult
    func setVerticalZoom(_ scale: CGFloat) -> Bool {
        guard gestureBase == nil else { return false }
        return LaneZoom.shared.setScale(scale, target: verticalZoomTarget, lanes: timeline.lanes)
    }
    /// 모두 맞춤: 선택과 무관하게 모든 레인을 자동 높이로 되돌린다.
    func fitAllLanes() {
        guard gestureBase == nil else { return }
        LaneZoom.shared.fitAll()
    }
}
