import CoreGraphics
import Foundation
import os

// 스펙트럼 프레임 조율(2026-10-26, SP-1A 3A-2 — docs/SPECTRUM-DESIGN.md §15.13). 앱·프리뷰 층·디스플레이 링크·내보내기에 연결하지 않았다.
// 타임라인 프레임 + 스펙트럼 항목 → (계보·조각·설정은 기존 엔진 함수 그대로) → SpectrumAnalysisScheduler의 밴드 → SpectrumFrameRenderer(3A-1)의 그린 프레임.
// - 상태는 모두 전용 직렬 큐(queue) 안에서만 바뀐다. 일정의 완료 처리기도 그 큐에서 불리고(callbackQueue = queue), 그리기도 그 큐에서 한다.
//   디코딩·FFT는 일정의 전용 작업자에서 돈다. 주 스레드에서 하는 일은 없다(공개 메서드는 번호를 받고 큐에 넣기만 함).
// - 오래된 결과 막기: 요청마다 정확한 입력(Plan — 프로젝트 회차·항목·프레임·모양·원본 위치·그 계보의 모든 조각)을 쥔다.
//   update는 지금 상태로 다시 계산한 Plan이 다른 요청만 superseded로 끝내고 일정 요청을 취소한다(관계없는 요청은 건드리지 않음).
//   완료 때 다시 같은 비교를 해 다르면 superseded — 취소가 늦거나 실패해도 오래된 값을 ready로 알리지 않는다.
// - 원본 열기: opener(기본 SpectrumFileSource.open)를 원본 위치(미디어 ID·경로·FileIdentity)마다 한 번. 재연결로 위치가 바뀌면 다른 열쇠다.
//   보안 범위 접근은 시작·멈추지 않는다 — 앱이 프로젝트 동안 쥔 접근(ProjectStore.scopedURLs·가져오기 패널 권한) 안의 MediaAsset만 넘긴다.
//   북마크·경로를 저장하지 않고 원본 파일을 쓰지 않는다(읽기만).

/// 한 프레임 요청의 결과. 요청마다 정확히 한 번 deliveryQueue에서 알린다.
public enum SpectrumFrameOutcome: Sendable {
    /// 밴드 값과 그린 프레임. frame이 nil이면 그릴 범위가 없다(디지털에서 모두 0 — 소스 조각이 없는 곳의 무음 포함). 프레임 화소는 그 값만 가진 버퍼(3A-1).
    case ready(bands: [Float], frame: SpectrumRenderedFrame?)
    /// 그 프레임에 스펙트럼이 보이지 않음 / 그 항목이 타임라인에 없음
    case notVisible, itemMissing
    /// 소스 고르지 않음 / 지워진 소스 / 같은 계보 조각 겹침(D-S8 — 분석하지 않음)
    case unsetSource, missingSource, overlap
    /// 소스 원본 미디어가 넘겨받은 목록에 없음(앱이 찾지 못함 또는 접근 없음)
    case mediaUnavailable(UUID)
    /// 결과 전에 입력(프로젝트·항목·소스·조각·설정·원본 위치)이 바뀌었다 — 지금 프레임의 값이 아니다. 필요하면 다시 요청한다.
    case superseded
    /// 부른 쪽이 취소함
    case cancelled
    /// 일정 상한(기다리는 작업·호출 수)으로 버림 — 다시 요청할 수 있음
    case dropped
    case failed(SpectrumFrameFailure)
}

public enum SpectrumFrameFailure: Error, Equatable, Sendable {
    /// 원본 열기 실패(소리 트랙 없음·채널 수·읽기 오류 등). 같은 원본 위치는 이 프로젝트 회차 동안 다시 열지 않는다(재연결·resetProject 뒤에 다시).
    case source(SpectrumAnalysisError)
    case analysis(SpectrumAnalysisError)
    case render(SpectrumRenderError)
}

public struct SpectrumFrameTicket: Hashable, Sendable { let raw: UInt64 }

public final class SpectrumFrameCoordinator: @unchecked Sendable {   // 가변 상태는 모두 queue 안에서만(아래 주석)
    public typealias SourceOpener = @Sendable (MediaAsset) async throws -> any SpectrumPCMProvider
    public typealias Completion = @Sendable (SpectrumFrameOutcome) -> Void
    /// 기본 원본 열기: 미디어 파일을 AVFoundation으로 읽는다(48 kHz, 덩어리 8초) — 부르는 쪽이 파일 접근을 쥐고 있어야 한다
    public static let fileOpener: SourceOpener = { a in try await SpectrumFileSource.open(url: a.url, mediaID: a.id) }

    let scheduler: SpectrumAnalysisScheduler
    private let queue = DispatchQueue(label: "dev.ontheframe.spectrum.coordinator", qos: .userInitiated)
    private let deliveryQueue: DispatchQueue
    private let opener: SourceOpener
    private let fps: Int
    private let nextTicket = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// 원본 위치: 같은 미디어 ID라도 재연결로 경로·파일이 바뀌면 다른 열쇠
    struct SourceKey: Hashable {
        let mediaID: UUID, path: String, device: Int64, inode: UInt64, size: Int64, modifiedNs: Int64
        init(_ a: MediaAsset) {
            mediaID = a.id; path = a.url.standardizedFileURL.path
            device = a.identity.device; inode = a.identity.inode; size = a.identity.size; modifiedNs = a.identity.modifiedNs
        }
    }
    enum SourceState { case opening, ready(any SpectrumPCMProvider), failed(SpectrumAnalysisError) }
    /// 결과를 정하는 입력 전부(이것이 같으면 그 밴드·그림은 지금 프레임의 값이다)
    struct Plan: Equatable {
        let epoch: Int, item: UUID, frame: Int
        let style: SpectrumItemStyle
        let source: SourceKey
        let pieces: [SpectrumSourcePiece]
    }
    enum Resolution: Equatable {
        case plan(Plan)
        case outcome(Kind)
        enum Kind: Equatable { case notVisible, itemMissing, unsetSource, missingSource, overlap, mediaUnavailable(UUID) }
    }
    struct Waiting {
        let item: UUID, frame: Int, width: Int, height: Int, priority: Int
        let completion: Completion
        var plan: Plan?
        var schedulerID: SpectrumRequestID?
    }

    // MARK: queue 안에서만
    private var epoch = 0
    private var timeline = Timeline()
    private var media: [UUID: MediaAsset] = [:]
    private var sources: [SourceKey: SourceState] = [:]
    private var waiting: [UInt64: Waiting] = [:]
    private var renderer: SpectrumFrameRenderer?
    /// 시험용(만든 직후에만 바꿈): false면 update가 입력이 바뀐 요청을 미리 끝내지 않는다 — 완료 때 비교만으로 막는지 본다
    var supersedeOnUpdate = true

    /// 타임라인 프레임 격자(2026-10-27, §15.13.1): 30 fps뿐이다 — 클립·스펙트럼 프레임, MediaProbe의 소리 프레임 수, ProjectFile 렌더 설정(.m1만),
    /// Timeline.spectrumFrameState·spectrumAnalysisReach의 겹침 여유가 모두 30 fps다. 다른 fps는 지원하지 않는다(요구 없음).
    static let timelineFPS = 30
    /// settings.fps는 timelineFPS(30)여야 한다. 다르면 모든 요청을 원본을 열지 않고 failed(.analysis(.invalidRequest))로 끝낸다
    /// (30 fps 프레임을 다른 fps로 잘못 읽어 그럴듯한 틀린 값을 내지 않게). 크기(width·height)는 쓰지 않는다 — 캔버스는 요청마다. 완료는 deliveryQueue에서.
    public init(settings: RenderSettings = .m1, limits: SpectrumSchedulerLimits = .init(), deliveryQueue: DispatchQueue, opener: @escaping SourceOpener = SpectrumFrameCoordinator.fileOpener) {
        fps = Int(settings.fps); self.deliveryQueue = deliveryQueue; self.opener = opener
        scheduler = SpectrumAnalysisScheduler(limits: limits, callbackQueue: queue)
    }

    // MARK: 공개 API(어느 스레드에서나 — 큐에 넣고 바로 돌아옴, 같은 스레드에서 부른 차례대로 처리)

    /// 지금 타임라인과 쓸 수 있는 원본 미디어(앱이 찾고 접근을 쥔 것)를 알린다. 입력이 바뀐 요청만 superseded로 끝내고(일정 작업 취소),
    /// 위치가 바뀌거나 없어진 원본은 놓는다(재연결). 원본을 열려고 기다리던 요청은 새 상태로 다시 정한다.
    public func update(timeline t: Timeline, media assets: [MediaAsset]) {
        queue.async { [self] in
            timeline = t
            media = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let live = Set(media.values.map(SourceKey.init))
            for k in sources.keys where !live.contains(k) { sources[k] = nil }
            for (raw, w) in waiting {
                guard let p = w.plan else { continue }
                if resolve(w.item, w.frame) == .plan(p) || (w.schedulerID != nil && !supersedeOnUpdate) { continue }
                if let id = w.schedulerID { finish(raw, .superseded); scheduler.cancel(id) }
                else { waiting[raw]?.plan = nil; start(raw) }   // 원본 열기를 기다리던 요청: 지금 상태로 다시
            }
        }
    }
    /// 프로젝트 교체(새 프로젝트·열기): 회차를 올리고, 끝나지 않은 요청을 모두 superseded로 끝내고, 원본·일정 캐시·그리기 캔버스를 놓는다.
    /// 그 뒤 update로 새 프로젝트를 알린다.
    public func resetProject() {
        queue.async { [self] in
            epoch += 1
            timeline = Timeline(); media = [:]; sources = [:]; renderer = nil
            for raw in Array(waiting.keys) { finish(raw, .superseded) }
            scheduler.invalidateSession()   // 일정이 남은 호출을 invalidated로 끝내도 이미 끝낸 요청이라 무시된다
        }
    }
    /// 그 스펙트럼의 타임라인 프레임 n을 canvasWidth × canvasHeight 캔버스에 그린 결과를 요청한다. priority: 작을수록 먼저(일정에 넘김).
    @discardableResult
    public func request(spectrum id: UUID, frame n: Int, canvasWidth: Int, canvasHeight: Int, priority: Int = 0,
                        completion: @escaping Completion) -> SpectrumFrameTicket {
        let raw = nextTicket.withLock { $0 += 1; return $0 }
        queue.async { [self] in
            waiting[raw] = Waiting(item: id, frame: n, width: canvasWidth, height: canvasHeight, priority: priority, completion: completion)
            start(raw)
        }
        return SpectrumFrameTicket(raw: raw)
    }
    /// 그 요청을 취소한다(이미 끝났으면 아무 일 없음). cancelled로 한 번 알린다.
    public func cancel(_ t: SpectrumFrameTicket) {
        queue.async { [self] in
            guard let id = waiting[t.raw]?.schedulerID ?? nil else { finish(t.raw, .cancelled); return }
            finish(t.raw, .cancelled); scheduler.cancel(id)
        }
    }

    // MARK: 안쪽(queue)

    /// 지금 상태에서 그 항목·프레임의 입력. 판정은 엔진 함수 그대로(spectrumFrameState·spectrumMediaID·spectrumPieces).
    func resolve(_ id: UUID, _ n: Int) -> Resolution {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let s = timeline.spectrum(id) else { return .outcome(.itemMissing) }
        switch timeline.spectrumFrameState(s, atFrame: n) {
        case .notVisible: return .outcome(.notVisible)
        case .unset: return .outcome(.unsetSource)
        case .missing: return .outcome(.missingSource)
        case .overlap: return .outcome(.overlap)
        case .ok: break
        }
        guard let mid = timeline.spectrumMediaID(s) else { return .outcome(.missingSource) }
        guard let a = media[mid] else { return .outcome(.mediaUnavailable(mid)) }
        return .plan(Plan(epoch: epoch, item: id, frame: n, style: s.style, source: SourceKey(a), pieces: timeline.spectrumPieces(s)))
    }
    private func start(_ raw: UInt64) {
        guard let w = waiting[raw] else { return }
        guard fps == Self.timelineFPS else { return finish(raw, .failed(.analysis(.invalidRequest("fps \(fps) — timeline grid is \(Self.timelineFPS) fps")))) }
        let p: Plan
        switch resolve(w.item, w.frame) {
        case let .outcome(k): return finish(raw, Self.outcome(k))
        case let .plan(x): p = x
        }
        waiting[raw]?.plan = p
        switch sources[p.source] {
        case let .ready(provider)?: schedule(raw, p, provider)
        case let .failed(e)?: finish(raw, .failed(.source(e)))
        case .opening?: break   // opened가 이어 받는다
        case nil:
            guard let a = media[p.source.mediaID] else { return finish(raw, .mediaUnavailable(p.source.mediaID)) }
            sources[p.source] = .opening
            let open = opener, e = epoch, key = p.source
            Task.detached(priority: .userInitiated) { [weak self] in
                let r: Result<any SpectrumPCMProvider, SpectrumAnalysisError>
                do { r = .success(try await open(a)) } catch let x as SpectrumAnalysisError { r = .failure(x) } catch { r = .failure(.decodeFailed("\(error)")) }
                guard let me = self else { return }
                me.queue.async { me.opened(key, epoch: e, r) }
            }
        }
    }
    private func opened(_ key: SourceKey, epoch e: Int, _ r: Result<any SpectrumPCMProvider, SpectrumAnalysisError>) {
        guard e == epoch, case .opening? = sources[key] else { return }   // 회차가 바뀌었거나 재연결로 놓은 원본: 버림
        switch r {
        case let .success(p): sources[key] = .ready(p)
        case let .failure(x): sources[key] = .failed(x)
        }
        for (raw, w) in waiting where w.schedulerID == nil && w.plan?.source == key {
            switch r {
            case let .success(p): schedule(raw, w.plan!, p)
            case let .failure(x): finish(raw, .failed(.source(x)))
            }
        }
    }
    private func schedule(_ raw: UInt64, _ p: Plan, _ provider: any SpectrumPCMProvider) {
        guard let w = waiting[raw] else { return }
        let r = SpectrumFrameRequest(frame: p.frame, fps: fps, settings: p.style.analysisSettings, pieces: p.pieces)
        // 완료는 이 큐에서 비동기로 온다(일정의 deliver) — 아래에서 schedulerID를 넣은 뒤에 처리된다
        let id = scheduler.request(r, from: provider, priority: w.priority) { [weak self] res in self?.analyzed(raw, p, res) }
        waiting[raw]?.schedulerID = id
    }
    private func analyzed(_ raw: UInt64, _ p: Plan, _ r: Result<[Float], SpectrumAnalysisError>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let w = waiting[raw] else { return }   // 이미 끝남(취소·교체)
        guard p.epoch == epoch, resolve(w.item, w.frame) == .plan(p) else { return finish(raw, .superseded) }
        switch r {
        case let .success(bands):
            do {
                if renderer?.width != w.width || renderer?.height != w.height { renderer = nil; renderer = try SpectrumFrameRenderer(width: w.width, height: w.height) }
                let f = try renderer!.render(bands: bands, style: p.style)
                finish(raw, .ready(bands: bands, frame: f))
            } catch let e as SpectrumRenderError { finish(raw, .failed(.render(e))) } catch { finish(raw, .failed(.render(.invalidCanvas("\(error)")))) }
        case .failure(.overlappingPieces): finish(raw, .overlap)
        case .failure(.dropped): finish(raw, .dropped)
        case .failure(.cancelled), .failure(.invalidated): finish(raw, .superseded)
        case let .failure(e): finish(raw, .failed(.analysis(e)))
        }
    }
    /// 정확히 한 번: 기다림에서 빼고 deliveryQueue에서 알린다
    private func finish(_ raw: UInt64, _ o: SpectrumFrameOutcome) {
        guard let w = waiting.removeValue(forKey: raw) else { return }
        deliveryQueue.async { w.completion(o) }
    }
    static func outcome(_ k: Resolution.Kind) -> SpectrumFrameOutcome {
        switch k {
        case .notVisible: return .notVisible
        case .itemMissing: return .itemMissing
        case .unsetSource: return .unsetSource
        case .missingSource: return .missingSource
        case .overlap: return .overlap
        case let .mediaUnavailable(id): return .mediaUnavailable(id)
        }
    }

    /// 진단·시험용(queue에서 읽음): 끝나지 않은 요청 수, 원본 상태 수, 프로젝트 회차
    var diagnostics: (waiting: Int, sources: Int, epoch: Int, hasRenderer: Bool) { queue.sync { (waiting.count, sources.count, epoch, renderer != nil) } }
}
