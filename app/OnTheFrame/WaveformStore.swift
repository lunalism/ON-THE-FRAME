import Foundation
import OnTheFrameEngine

/// WAVEFORM-01: in-memory waveform peaks per audio source for timeline audio clips (imported audio files and the audio of
/// video files). Nothing is written to disk or saved in the project. One analysis runs at a time off the main actor and
/// is cancellable; results are kept within `byteBudget` (least recently drawn sources are dropped and re-analysed when
/// needed). A source is identified by media ID, path and file identity, so a relinked or changed file is analysed again.
@MainActor
@Observable
final class WaveformStore {
    enum State: Equatable {
        case pending
        case ready(WaveformPeaks)
        case unavailable(String)
    }
    struct Key: Hashable {
        let mediaID: UUID, path: String, inode: UInt64, size: Int64, modifiedNs: Int64
        init(_ a: MediaAsset) {
            mediaID = a.id; path = a.url.standardizedFileURL.path
            inode = a.identity.inode; size = a.identity.size; modifiedNs = a.identity.modifiedNs
        }
    }
    typealias Analyzer = @Sendable (URL, UUID) async throws -> WaveformPeaks

    /// Bumped when a result arrives or entries are dropped (the timeline reads it to redraw). The only observed value.
    private(set) var revision = 0
    static let byteBudget = 96 << 20

    @ObservationIgnored private var states: [Key: State] = [:]
    @ObservationIgnored private var lastUse: [Key: UInt64] = [:]
    @ObservationIgnored private var clock: UInt64 = 0
    @ObservationIgnored private var queue: [(key: Key, url: URL)] = []
    @ObservationIgnored private var running: (key: Key, task: Task<Void, Never>)?
    @ObservationIgnored var analyzer: Analyzer = { url, id in try await WaveformPeaks.analyze(url: url, mediaID: id) }
    #if DEBUG
    /// Number of analyses started (tests: the same unchanged source is not analysed again for every redraw).
    @ObservationIgnored private(set) var analysesStartedForTest = 0
    var isIdleForTest: Bool { running == nil && queue.isEmpty }
    #endif

    /// Current state for an audio source; schedules an analysis the first time (or after eviction). Never blocks.
    /// Only call for sources that exist (not missing media); the caller draws a placeholder while pending.
    func state(for a: MediaAsset) -> State {
        let k = Key(a)
        clock &+= 1; lastUse[k] = clock
        if let s = states[k] { return s }
        guard a.hasAudio else { states[k] = .unavailable("no audio"); return states[k]! }
        states[k] = .pending
        queue.append((k, a.url))
        pump()
        return .pending
    }

    /// Keeps only entries of `assets` with an unchanged identity; cancels work for anything else (project change,
    /// removed or relinked media). Called when the project's media list is rebuilt.
    func retain(_ assets: [MediaAsset]) {
        let keep = Set(assets.map(Key.init))
        let drop = states.keys.filter { !keep.contains($0) }
        guard !drop.isEmpty else { return }
        for k in drop { states[k] = nil; lastUse[k] = nil }
        queue.removeAll { !keep.contains($0.key) }
        if let r = running, !keep.contains(r.key) { r.task.cancel(); running = nil }
        revision &+= 1
        pump()
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        guard states[next.key] == .pending else { return pump() }
        let analyzer = self.analyzer, url = next.url, id = next.key.mediaID
        #if DEBUG
        analysesStartedForTest += 1
        #endif
        let task = Task { [weak self] in
            let result: State
            do {
                // The decode runs detached (off the main actor); cancelling this task cancels it (checked per audio buffer).
                let work = Task.detached(priority: .utility) { try await analyzer(url, id) }
                let peaks = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                result = .ready(peaks)
            } catch {
                result = .unavailable("\(error)")
            }
            guard !Task.isCancelled else { return }
            self?.finish(next.key, result)
        }
        running = (next.key, task)
    }

    private func finish(_ k: Key, _ result: State) {
        guard running?.key == k else { return }
        running = nil
        if states[k] == .pending { states[k] = result }
        evictOverBudget(keeping: k)
        revision &+= 1
        pump()
    }

    private func evictOverBudget(keeping k: Key) {
        func bytes() -> Int {
            states.values.reduce(0) { (sum: Int, s: State) -> Int in
                if case .ready(let p) = s { return sum + p.byteCount }
                return sum
            }
        }
        var total = bytes()
        while total > Self.byteBudget {
            let ready = states.compactMap { e -> (Key, Int)? in if case .ready(let p) = e.value, e.key != k { return (e.key, p.byteCount) }; return nil }
            guard let victim = ready.min(by: { (lastUse[$0.0] ?? 0) < (lastUse[$1.0] ?? 0) }) else { break }
            states[victim.0] = nil; lastUse[victim.0] = nil; total -= victim.1
        }
    }
}
