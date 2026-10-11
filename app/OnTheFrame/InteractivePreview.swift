import AVFoundation
import CoreGraphics
import OnTheFrameEngine

/// 프리뷰 끌기 중 겹친 화면(2026-10-11 깜박임 수정, 같은 날 부드러움 개선). 끌기를 시작할 때 재생 헤드 시각에 보일 수 있는 영상 원본 프레임
/// (모든 영상 레인에서 그 시각을 덮는 클립)을 한 번 디코딩해 두고, 변형이 바뀔 때마다 프리뷰·내보내기와 같은 해석으로 레이어 목록을 만든다.
/// - 쌓음: CompositionPlanner.layeredSegments(위 레인부터, 화면 전체를 덮는 클립에서 멈춤). 변형: CompositionPlanner.layerTransform.
/// - 그리기: 이 목록을 프리뷰 화면 호스트(PlayerNSView)의 레이어 무대로 넘긴다. 무대는 원본 프레임마다 CALayer 하나를 두고
///   변형만 바꾼다(GPU 합성). 이전 방식(1920×1080을 매번 Core Graphics로 그리고 그 그림을 레이어 내용으로 넘김)은
///   그리기 12–15 ms와 주 스레드의 색 변환(그림마다)이 끌기를 끊기게 했다(app/README.md §19).
/// - 원본 프레임 시각: 영상 트랙 시작 + (sourceIn + 재생 헤드 − start)/30 s, 허용 오차 0(composition과 같은 규칙).
/// - 요청은 마지막 것만 쓴다. 프레임 디코딩이 끝나기 전 요청은 끝난 뒤 가장 새 것 하나를 보인다. end() 뒤 결과는 버린다.
/// 이 화면은 편집 중 표시용일 뿐 composition·내보내기에 들어가지 않는다.
@MainActor
final class InteractivePreview {
    struct Key: Hashable { let media: UUID; let frame: Int }
    /// 무대 레이어 하나(아래 레이어가 먼저). transform: 원본 픽셀(왼쪽 위 원점, 아래 +Y) → 출력 화면 좌표(같은 방향).
    struct DrawItem { let clipID: UUID; let image: CGImage; let transform: CGAffineTransform; let size: CGSize }

    private var cache: [Key: CGImage] = [:]
    private var media: [UUID: MediaAsset] = [:]
    private var settings = RenderSettings.m1
    private var frame = 0
    private var prefetch: Task<Void, Never>?
    private var ready = false
    private var wanted: (timeline: Timeline, done: ((Bool) -> Void)?)?
    /// 회차: begin·end마다 1 늘고, 이전 회차의 결과는 버린다
    private(set) var token = 0
    /// 새 레이어 목록을 보일 때(주 스레드, 동기)
    var onItems: (([DrawItem]) -> Void)?
    private(set) var isActive = false
    #if DEBUG
    /// 자체 검사 전용: 보인 수, 마지막으로 보인 타임라인, 마지막 목록 만들기·무대 적용 시간(ms)
    private(set) var renderCount = 0
    private(set) var lastTimeline: Timeline?
    private(set) var lastApplyMs: Double = 0
    #endif

    /// 끌기 시작: 재생 헤드 프레임 f에서 보일 수 있는 원본 프레임을 미리 디코딩한다(이미 있는 것은 다시 하지 않음)
    func begin(_ base: Timeline, frame f: Int, media m: [UUID: MediaAsset], settings s: RenderSettings) {
        token += 1
        finishWanted(false)
        if f != frame || m != media { cache.removeAll() }
        frame = f; media = m; settings = s; isActive = true
        let needed = Array(Set(base.clips.filter { $0.start <= f && f < $0.end }.map { Key(media: $0.mediaID, frame: $0.sourceIn + f - $0.start) }))
            .filter { cache[$0] == nil }
        let tok = token
        ready = needed.isEmpty
        guard !ready else { prefetch = nil; return }
        prefetch = Task { [weak self] in
            for k in needed {
                guard let a = m[k.media] else { continue }
                let img = try? await Self.decode(a, frame: k.frame, settings: s)
                guard let self, self.token == tok else { return }
                if let img { self.cache[k] = img }
            }
            guard let self, self.token == tok else { return }
            self.ready = true
            if let w = self.wanted { self.wanted = nil; let ok = self.show(w.timeline); w.done?(ok) }   // done이 없어도 보인다
        }
    }
    /// 타임라인 t의 겹친 화면을 보인다(프레임이 준비됐으면 바로). done(true)는 보였을 때, done(false)는 보이지 못했거나 더 새 요청·end()로 버렸을 때.
    func request(_ t: Timeline, done: ((Bool) -> Void)? = nil) {
        guard isActive else { done?(false); return }
        finishWanted(false)
        if ready { let ok = show(t); done?(ok) } else { wanted = (t, done) }   // done이 없어도 보인다(선택적 호출 인자는 계산되지 않음)
    }
    /// 끝: 대기 중 요청을 버린다(디코딩해 둔 프레임은 같은 재생 헤드의 다음 끌기에 다시 쓴다)
    func end() {
        token += 1
        isActive = false
        finishWanted(false)
    }
    private func finishWanted(_ ok: Bool) { let d = wanted?.done; wanted = nil; d?(ok) }

    private func show(_ t: Timeline) -> Bool {
        #if DEBUG
        let t0 = DispatchTime.now().uptimeNanoseconds
        #endif
        guard let items = drawList(t) else { return false }
        #if DEBUG
        lastTimeline = t
        #endif
        onItems?(items)
        #if DEBUG
        renderCount += 1
        lastApplyMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        PerfProbe.shared.rendered(ms: lastApplyMs)
        #endif
        return true
    }

    /// 재생 헤드 프레임의 레이어(아래 먼저). 필요한 원본 프레임이 없으면 nil. 영상이 없는 시각이면 빈 목록(검정).
    func drawList(_ t: Timeline) -> [DrawItem]? {
        let size = settings.renderSize
        // 재생 헤드 한 프레임의 쌓음(layeredSegments와 같은 규칙, 전체 타임라인을 나누지 않음)
        guard let stack = try? CompositionPlanner.layerStack(t, from: frame, to: frame + 1, media: media, render: size) else { return nil }
        var items: [DrawItem] = []
        for c in stack.reversed() {
            guard let m = media[c.mediaID], let img = cache[Key(media: c.mediaID, frame: c.sourceIn + frame - c.start)] else { return nil }
            items.append(DrawItem(clipID: c.id, image: img, transform: CompositionPlanner.layerTransform(m, c.effectiveTransform, render: size), size: m.naturalSize))
        }
        return items
    }

    /// 원본 프레임 하나(회전 적용 전, 원본 크기). 시각 규칙은 CompositionPlanner와 같다.
    nonisolated static func decode(_ a: MediaAsset, frame: Int, settings: RenderSettings) async throws -> CGImage {
        let asset = AVURLAsset(url: a.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw PlanError.missingMedia(a.id) }
        let vr = try await v.load(.timeRange)
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = false
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        return try await g.image(at: vr.start + settings.time(frame)).image
    }
}
