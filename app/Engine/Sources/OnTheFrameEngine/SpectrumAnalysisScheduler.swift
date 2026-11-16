import Foundation
import os

// 스펙트럼 분석 일정(SP-0 (3), 2026-10-24, docs/SPECTRUM-DESIGN.md §4·§11). 앱에 연결하지 않았다.
// - 요청 단위: (원본, 프레임, fps, 설정, 창에 드는 조각) → 밴드 값. 같은 열쇠의 요청은 한 작업으로 합친다.
// - 디코딩 단위: (원본, 덩어리) — 여러 작업·여러 스펙트럼이 나눠 쓴다(같은 덩어리는 세션마다 한 번만 진행).
// - 상한: 기다리는 작업 수(넘치면 우선순위 값이 가장 큰 것을 버림), 동시 작업 수(디코딩 + 분석), 덩어리 캐시 바이트, 밴드 캐시 항목 수.
// - 모든 요청은 정확히 한 번 끝난다(결과·취소·버림·무효·오류) — 완료 처리기는 callbackQueue에서 부른다.
// - 세션 무효: 기다림을 모두 끝내고(invalidated) 캐시를 비운다. 그 전에 시작한 작업은 끝나도 알리지 않고 캐시에 넣지 않는다.
// - 작업 실행: 전용 작업자(SpectrumWorkExecutor — 자기 디스패치 큐)에서 돈다. 디코딩은 리더를 차례로 읽으며 스레드를 막으므로 Swift 협력 스레드에서 돌리지 않는다.
//   동시 수는 active로 묶인다(무효로 한 세션의 남은 작업도 끝날 때까지 센다 — 상한은 세션을 넘어 유지). 무효로 할 때 진행 중 디코딩 작업을 취소한다.
// - 메모리: 상한은 캐시(덩어리 바이트·밴드 항목)와 개수(기다리는 작업·기다리는 호출·동시 작업)에 건다. 전체 메모리 상한이 아니다 — statistics의
//   retainedChunkReferences(작업이 쥔 덩어리 참조, 캐시에서 밀려난 것 포함)·retiredActive(무효 세션의 남은 작업)를 함께 본다.
// 시제품(SpectrumSchedulerPrototypeTests.ProtoAnalysisScheduler)과 다른 점: 진행 중 디코딩을 세션별로 구분한다 — 시제품은 세션을 바꾼 뒤 같은 덩어리를
// 다시 요청하면 이전 세션의 진행 중 디코딩을 기다리다 그 결과가 버려져 영영 끝나지 않았다. 디코딩 실패는 오류로 알린다(취소와 구분).

public struct SpectrumFrameRequest: Sendable {
    public let frame: Int, fps: Int
    public let settings: SpectrumAnalysisSettings
    /// 그 스펙트럼의 소스 조각(창 밖 조각은 열쇠에 들지 않는다)
    public let pieces: [SpectrumSourcePiece]
    public init(frame: Int, fps: Int, settings: SpectrumAnalysisSettings = .init(), pieces: [SpectrumSourcePiece]) {
        self.frame = frame; self.fps = fps; self.settings = settings; self.pieces = pieces
    }
}

public struct SpectrumRequestID: Hashable, Sendable { let raw: UInt64 }

public struct SpectrumSchedulerLimits: Sendable {
    /// maxWaiters: 끝나지 않은 호출 수(같은 작업에 합쳐진 호출 포함). 넘치면 새 호출을 바로 .dropped로 끝낸다.
    /// chunkCacheBytes: 캐시 상한(가장 최근 덩어리 하나는 남김) — 작업이 쥔 덩어리는 따로(statistics).
    public var maxPending: Int, maxConcurrent: Int, chunkCacheBytes: Int, bandCacheEntries: Int, maxWaiters: Int
    public init(maxPending: Int = 8, maxConcurrent: Int = 2, chunkCacheBytes: Int = 32 << 20, bandCacheEntries: Int = 600, maxWaiters: Int = 256) {
        precondition(maxPending >= 1 && maxConcurrent >= 1 && chunkCacheBytes >= 0 && bandCacheEntries >= 0 && maxWaiters >= 1)
        self.maxPending = maxPending; self.maxConcurrent = maxConcurrent; self.chunkCacheBytes = chunkCacheBytes; self.bandCacheEntries = bandCacheEntries
        self.maxWaiters = maxWaiters
    }
}

/// 스펙트럼 디코딩·FFT 전용 작업 실행기: 작업을 자기 동시 디스패치 큐의 스레드에서 돌린다(Swift 협력 스레드를 막지 않음).
/// 동시에 도는 작업 수는 실행기가 아니라 SpectrumAnalysisScheduler가 묶는다(maxConcurrent).
final class SpectrumWorkExecutor: TaskExecutor {
    static let label = "dev.ontheframe.spectrum.worker"
    private let queue = DispatchQueue(label: SpectrumWorkExecutor.label, qos: .userInitiated, attributes: .concurrent)
    func enqueue(_ job: consuming ExecutorJob) {
        let j = UnownedJob(job), me = asUnownedTaskExecutor()
        queue.async { j.runSynchronously(on: me) }
    }
}

/// 기록(시험·진단). 센 것: 덩어리 캐시 PCM 바이트, 작업 수. 세지 않은 것: 기다리는 작업이 쥔 덩어리(캐시에서 밀려난 뒤에도 그 작업이 끝날 때까지 남음),
/// AVFoundation 내부 버퍼, 완료 처리기가 쥔 결과.
public struct SpectrumSchedulerStatistics: Sendable, Equatable {
    public var decodes = 0, analyses = 0, staleDecodes = 0, staleAnalyses = 0, dropped = 0, cancelled = 0, invalidated = 0, failed = 0
    public var peakPending = 0, peakActive = 0, peakChunkCacheBytes = 0, peakWaiters = 0
    public var chunkCacheBytes = 0, chunkCacheEntries = 0, bandCacheEntries = 0, pendingJobs = 0, runningJobs = 0, waiters = 0, active = 0
    /// 무효로 한 세션의 아직 끝나지 않은 작업(active에 포함)
    public var retiredActive = 0
    /// 기다리는·도는 작업이 쥔 덩어리 참조 수와 그 바이트 합(같은 배열을 여러 작업이 쥐면 겹쳐 셈 — 위쪽 어림). 무효 세션의 도는 분석이 쥔 것은 세지 않음.
    public var retainedChunkReferences = 0, retainedChunkBytesUpperBound = 0
}

public final class SpectrumAnalysisScheduler: Sendable {
    public typealias Completion = @Sendable (Result<[Float], SpectrumAnalysisError>) -> Void
    public let limits: SpectrumSchedulerLimits
    private let callbackQueue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let executor = SpectrumWorkExecutor()

    public init(limits: SpectrumSchedulerLimits = .init(), callbackQueue: DispatchQueue = DispatchQueue(label: "dev.ontheframe.spectrum.callback")) {
        self.limits = limits; self.callbackQueue = callbackQueue
    }

    // MARK: 상태(모두 state 잠금 안에서만)
    struct PieceKey: Hashable {
        let start: Int, length: Int, sourceIn: Int, volume: Int, muted: Bool, fadeIn: [Int], fadeOut: [Int], laneGain: UInt64
        init(_ p: SpectrumSourcePiece) {
            start = p.start; length = p.length; sourceIn = p.sourceIn; volume = p.audio.volumePercent; muted = p.audio.muted
            fadeIn = [p.audio.fadeIn.length, p.audio.fadeIn.offset]; fadeOut = [p.audio.fadeOut.length, p.audio.fadeOut.offset]; laneGain = p.laneGain.bitPattern
        }
    }
    /// 결과를 정하는 것 전부: 원본 정체(파일·표본율·격자 포함), 프레임, fps, 설정, 창에 드는 조각(위치·원본 시작·음량·페이드·음소거·레인 이득)
    struct BandKey: Hashable { let source: SpectrumSourceIdentity; let frame: Int, fps: Int; let settings: SpectrumAnalysisSettings; let pieces: [PieceKey] }
    struct ChunkKey: Hashable { let source: SpectrumSourceIdentity; let index: Int }
    struct InFlight: Hashable { let session: Int; let chunk: ChunkKey }
    struct Job {
        let key: BandKey, seq: UInt64, session: Int
        let provider: any SpectrumPCMProvider
        let pieces: [SpectrumSourcePiece], needed: [Int]
        var priority: Int
        var have: [Int: [[Float]]] = [:]
        var running = false
        var waiters: Set<UInt64> = []
    }
    struct Waiter { let key: BandKey; let completion: Completion }
    struct State {
        var session = 0, nextID: UInt64 = 0, nextSeq: UInt64 = 0
        /// 진행 중 디코딩 작업 손잡이(무효로 할 때 취소), 도는 분석(seq → 세션)
        var decodeTasks: [InFlight: Task<Void, Never>] = [:], runningAnalyses: [UInt64: Int] = [:]
        var jobs: [BandKey: Job] = [:]
        var waiters: [UInt64: Waiter] = [:]
        var inFlight: Set<InFlight> = []
        var chunkCache: [ChunkKey: [[Float]]] = [:], chunkLRU: [ChunkKey] = [], chunkBytes = 0
        var bandCache: [BandKey: [Float]] = [:], bandLRU: [BandKey] = []
        var active = 0
        var stats = SpectrumSchedulerStatistics()
        var pendingCount: Int { jobs.values.filter { !$0.running }.count }
    }
    typealias Delivery = (Completion, Result<[Float], SpectrumAnalysisError>)
    enum Start { case decode(any SpectrumPCMProvider, ChunkKey, Int), analyze(Job) }

    static func bytes(_ d: [[Float]]) -> Int { d.reduce(0) { $0 + $1.count * MemoryLayout<Float>.size } }
    static func key(_ r: SpectrumFrameRequest, _ p: any SpectrumPCMProvider) throws -> (BandKey, [SpectrumSourcePiece], [Int]) {
        if let e = SpectrumAnalysis.requestError(frame: r.frame, pieces: r.pieces, fps: r.fps, rate: p.sampleRate, settings: r.settings) { throw e }
        guard (1...2).contains(p.channelCount), p.chunkSamples > 0 else { throw SpectrumAnalysisError.unsupportedChannelCount(p.channelCount) }
        let w = SpectrumAnalysis.window(frame: r.frame, fps: r.fps, rate: p.sampleRate, settings: r.settings)
        let pieces = try SpectrumAnalysis.windowPieces(r.pieces, window: w, fps: r.fps, rate: p.sampleRate)
        let needed = SpectrumAnalysis.chunks(spans: SpectrumAnalysis.sourceSpans(pieces, window: w, fps: r.fps, rate: p.sampleRate), chunkSamples: p.chunkSamples)
        return (BandKey(source: p.identity, frame: r.frame, fps: r.fps, settings: r.settings, pieces: pieces.map(PieceKey.init)), pieces, needed)
    }

    // MARK: 공개 API
    /// 프레임 밴드 값을 요청한다. priority: 작을수록 먼저(예: 재생 헤드와의 거리). 완료 처리기는 정확히 한 번 callbackQueue에서 불린다.
    @discardableResult
    public func request(_ r: SpectrumFrameRequest, from provider: any SpectrumPCMProvider, priority: Int = 0, completion: @escaping Completion) -> SpectrumRequestID {
        let prepared: (BandKey, [SpectrumSourcePiece], [Int])?, early: SpectrumAnalysisError?
        do { prepared = try Self.key(r, provider); early = nil } catch let e as SpectrumAnalysisError { prepared = nil; early = e } catch { prepared = nil; early = .invalidSettings("\(error)") }
        let (id, out): (SpectrumRequestID, [Delivery]) = state.withLock { s in
            s.nextID += 1
            let id = SpectrumRequestID(raw: s.nextID)
            guard let (key, pieces, needed) = prepared else { s.stats.failed += 1; return (id, [(completion, .failure(early ?? .invalidSettings("request")))]) }
            if let v = s.bandCache[key] { Self.touch(&s.bandLRU, key); return (id, [(completion, .success(v))]) }
            guard s.waiters.count < limits.maxWaiters else { s.stats.dropped += 1; return (id, [(completion, .failure(.dropped))]) }
            var out: [Delivery] = []
            s.waiters[id.raw] = Waiter(key: key, completion: completion)
            if var j = s.jobs[key] {
                j.waiters.insert(id.raw); j.priority = min(j.priority, priority); s.jobs[key] = j
            } else {
                s.nextSeq += 1
                var j = Job(key: key, seq: s.nextSeq, session: s.session, provider: provider, pieces: pieces, needed: needed, priority: priority)
                j.waiters.insert(id.raw)
                s.jobs[key] = j
                while s.pendingCount > limits.maxPending {   // 가장 늦게 할 것(우선순위 값 큼, 같으면 나중 요청)을 버린다
                    guard let worst = s.jobs.values.filter({ !$0.running }).max(by: { ($0.priority, $0.seq) < ($1.priority, $1.seq) }) else { break }
                    out += Self.settle(&s, worst.key, .failure(.dropped)); s.stats.dropped += worst.waiters.count
                }
            }
            s.stats.peakPending = max(s.stats.peakPending, s.pendingCount); s.stats.peakWaiters = max(s.stats.peakWaiters, s.waiters.count)
            return (id, out)
        }
        deliver(out)
        pump()
        return id
    }
    /// 그 요청을 취소한다(이미 끝났으면 아무 일 없음). 그 작업을 기다리는 쪽이 더 없고 아직 시작하지 않았으면 작업을 버려 쥔 덩어리를 놓는다.
    public func cancel(_ id: SpectrumRequestID) {
        let out: [Delivery] = state.withLock { s in
            guard let w = s.waiters.removeValue(forKey: id.raw) else { return [] }
            s.stats.cancelled += 1
            if var j = s.jobs[w.key] {
                j.waiters.remove(id.raw)
                if j.waiters.isEmpty, !j.running { s.jobs[w.key] = nil } else { s.jobs[w.key] = j }
            }
            return [(w.completion, .failure(.cancelled))]
        }
        deliver(out)
    }
    /// 캐시에 있으면 그 값(디스플레이 링크 같은 곳에서 기다리지 않고 볼 때). 없거나 요청이 잘못되면 nil.
    public func cachedBands(_ r: SpectrumFrameRequest, from provider: any SpectrumPCMProvider) -> [Float]? {
        guard let (key, _, _) = try? Self.key(r, provider) else { return nil }
        return state.withLock { s in
            guard let v = s.bandCache[key] else { return nil }
            Self.touch(&s.bandLRU, key); return v
        }
    }
    /// async 형태. 작업(Task)이 취소되면 그 요청을 취소하고 CancellationError가 아니라 SpectrumAnalysisError.cancelled를 던진다.
    public func bands(_ r: SpectrumFrameRequest, from provider: any SpectrumPCMProvider, priority: Int = 0) async throws -> [Float] {
        let handle = OSAllocatedUnfairLock<(id: SpectrumRequestID?, cancelled: Bool)>(initialState: (nil, false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<[Float], Error>) in
                let id = request(r, from: provider, priority: priority) { k.resume(with: $0.mapError { $0 as Error }) }
                let cancelNow = handle.withLock { h in h.id = id; return h.cancelled }
                if cancelNow { cancel(id) }
            }
        } onCancel: {
            let id: SpectrumRequestID? = handle.withLock { h in h.cancelled = true; return h.id }
            if let id { cancel(id) }
        }
    }
    /// 세션 무효(프로젝트 바꿈·원본 재연결 등): 기다리는 요청을 모두 invalidated로 끝내고 캐시를 비운다. 진행 중 디코딩 작업은 취소하고,
    /// 끝나도(취소를 보지 않는 원본이라도) 알리지 않고 캐시에 넣지 않는다. 그 작업들은 끝날 때까지 동시 수에 든다.
    public func invalidateSession() {
        let (out, tasks): ([Delivery], [Task<Void, Never>]) = state.withLock { s in
            s.session += 1
            let tasks = Array(s.decodeTasks.values)
            let all = s.waiters.values.map { ($0.completion, Result<[Float], SpectrumAnalysisError>.failure(.invalidated)) }
            s.stats.invalidated += all.count
            s.waiters = [:]; s.jobs = [:]
            s.chunkCache = [:]; s.chunkLRU = []; s.chunkBytes = 0
            s.bandCache = [:]; s.bandLRU = []
            return (all, tasks)
        }
        tasks.forEach { $0.cancel() }
        deliver(out)
    }
    public var statistics: SpectrumSchedulerStatistics {
        state.withLock { s in
            var x = s.stats
            x.chunkCacheBytes = s.chunkBytes; x.chunkCacheEntries = s.chunkCache.count; x.bandCacheEntries = s.bandCache.count
            x.pendingJobs = s.pendingCount; x.runningJobs = s.jobs.values.filter(\.running).count; x.waiters = s.waiters.count; x.active = s.active
            x.retiredActive = s.inFlight.filter { $0.session != s.session }.count + s.runningAnalyses.values.filter { $0 != s.session }.count
            x.retainedChunkReferences = s.jobs.values.reduce(0) { $0 + $1.have.count }
            x.retainedChunkBytesUpperBound = s.jobs.values.reduce(0) { $0 + $1.have.values.reduce(0) { $0 + Self.bytes($1) } }
            return x
        }
    }

    // MARK: 안쪽
    static func touch<K: Hashable>(_ lru: inout [K], _ k: K) { if let i = lru.firstIndex(of: k) { lru.remove(at: i) }; lru.append(k) }
    /// 그 작업을 없애고 기다리는 쪽 모두에 r을 알린다(잠금 안)
    static func settle(_ s: inout State, _ key: BandKey, _ r: Result<[Float], SpectrumAnalysisError>) -> [Delivery] {
        guard let j = s.jobs.removeValue(forKey: key) else { return [] }
        return j.waiters.compactMap { s.waiters.removeValue(forKey: $0).map { ($0.completion, r) } }
    }
    private func deliver(_ xs: [Delivery]) { for (c, r) in xs { callbackQueue.async { c(r) } } }

    /// 빈 자리만큼 일을 시작한다: 우선순위 순으로, 덩어리가 다 있는 작업은 분석, 아니면 아직 진행 중이 아닌 빠진 덩어리를 디코딩.
    private func pump() {
        let starts: [Start] = state.withLock { s in
            var starts: [Start] = []
            let order = s.jobs.values.filter { !$0.running && $0.session == s.session }.sorted { ($0.priority, $0.seq) < ($1.priority, $1.seq) }.map(\.key)
            for key in order {
                guard s.active < limits.maxConcurrent else { break }
                guard var j = s.jobs[key] else { continue }
                for c in j.needed where j.have[c] == nil {
                    let ck = ChunkKey(source: j.key.source, index: c)
                    if let d = s.chunkCache[ck] { j.have[c] = d; Self.touch(&s.chunkLRU, ck) }
                }
                let missing = j.needed.filter { j.have[$0] == nil }
                if missing.isEmpty {
                    j.running = true; s.active += 1; s.runningAnalyses[j.seq] = j.session; starts.append(.analyze(j))
                } else {
                    for c in missing where s.active < limits.maxConcurrent {
                        let f = InFlight(session: s.session, chunk: ChunkKey(source: j.key.source, index: c))
                        guard !s.inFlight.contains(f) else { continue }
                        s.inFlight.insert(f); s.active += 1; starts.append(.decode(j.provider, f.chunk, s.session))
                    }
                }
                s.jobs[key] = j
            }
            s.stats.peakActive = max(s.stats.peakActive, s.active)
            return starts
        }
        for st in starts {   // 전용 작업자에서(UI·협력 스레드 아님). 동시 수는 active로 묶인다.
            switch st {
            case let .decode(p, ck, session):
                let t = Task(executorPreference: executor, priority: .userInitiated) { await self.runDecode(p, ck, session) }
                let f = InFlight(session: session, chunk: ck)
                let cancelNow: Bool = state.withLock { s in   // 이미 끝났으면 넣지 않음, 그 사이 무효가 됐으면 바로 취소
                    guard s.inFlight.contains(f) else { return false }
                    if f.session != s.session { return true }
                    s.decodeTasks[f] = t; return false
                }
                if cancelNow { t.cancel() }
            case let .analyze(j): Task(executorPreference: executor, priority: .userInitiated) { self.runAnalysis(j) }
            }
        }
    }
    private func runDecode(_ p: any SpectrumPCMProvider, _ ck: ChunkKey, _ session: Int) async {
        let r: Result<[[Float]], SpectrumAnalysisError>
        do {
            let d = try await p.decodeChunk(ck.index)
            r = d.count == p.channelCount && d.allSatisfy({ $0.count == p.chunkSamples }) ? .success(d) : .failure(.decodeFailed("chunk shape"))
        } catch let e as SpectrumAnalysisError { r = .failure(e) } catch { r = .failure(.decodeFailed("\(error)")) }
        let out: [Delivery] = state.withLock { s in
            s.active -= 1; s.stats.decodes += 1
            s.inFlight.remove(InFlight(session: session, chunk: ck)); s.decodeTasks[InFlight(session: session, chunk: ck)] = nil
            guard session == s.session else { s.stats.staleDecodes += 1; return [] }   // 다른 세션: 캐시에 넣지 않고 알리지 않음
            let waiting = s.jobs.values.filter { !$0.running && $0.key.source == ck.source && $0.needed.contains(ck.index) }.map(\.key)
            switch r {
            case let .success(d):
                s.chunkCache[ck] = d; Self.touch(&s.chunkLRU, ck); s.chunkBytes += Self.bytes(d)
                while s.chunkBytes > limits.chunkCacheBytes, s.chunkLRU.count > 1 {
                    let old = s.chunkLRU.removeFirst(); s.chunkBytes -= Self.bytes(s.chunkCache.removeValue(forKey: old) ?? [])
                }
                s.stats.peakChunkCacheBytes = max(s.stats.peakChunkCacheBytes, s.chunkBytes)
                for k in waiting { s.jobs[k]?.have[ck.index] = d }   // 캐시에서 밀려나도 그 작업은 쥐고 간다
                return []
            case let .failure(e):
                s.stats.failed += waiting.reduce(0) { $0 + (s.jobs[$1]?.waiters.count ?? 0) }
                return waiting.flatMap { Self.settle(&s, $0, .failure(e)) }
            }
        }
        deliver(out)
        pump()
    }
    private func runAnalysis(_ j: Job) {
        let r: Result<[Float], SpectrumAnalysisError>
        do {
            r = .success(try SpectrumAnalysis.bands(frame: j.key.frame, pieces: j.pieces, fps: j.key.fps, rate: j.provider.sampleRate, channelCount: j.provider.channelCount,
                                                    chunkSamples: j.provider.chunkSamples, settings: j.key.settings) { j.have[$0] })
        } catch let e as SpectrumAnalysisError { r = .failure(e) } catch { r = .failure(.decodeFailed("\(error)")) }
        let out: [Delivery] = state.withLock { s in
            s.active -= 1; s.stats.analyses += 1; s.runningAnalyses[j.seq] = nil
            guard j.session == s.session, s.jobs[j.key]?.seq == j.seq else { s.stats.staleAnalyses += 1; return [] }
            if case let .success(v) = r, limits.bandCacheEntries > 0 {
                s.bandCache[j.key] = v; Self.touch(&s.bandLRU, j.key)
                while s.bandLRU.count > limits.bandCacheEntries { s.bandCache[s.bandLRU.removeFirst()] = nil }
            }
            if case .failure = r { s.stats.failed += s.jobs[j.key]?.waiters.count ?? 0 }
            return Self.settle(&s, j.key, r)
        }
        deliver(out)
        pump()
    }
}
