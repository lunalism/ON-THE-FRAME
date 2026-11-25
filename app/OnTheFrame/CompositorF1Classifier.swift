#if DEBUG
import Foundation

/// SP-EXPORT-E4D-F1-CLASSIFIER-66 (DEBUG only): classifies whether timeline frame 1 was seen in the F1 window capture.
/// Foundation only, so the same source can be replayed offline against a saved `f1-capture.json`.
///
/// The playback window is bounded by the run's own clock markers (`F1.clock`: seek to 0, play, pause), never by source frame numbers:
/// it starts at the seek-to-0 call (frame 26, shown before it, is excluded) and ends at pause or play + `analysisSpan`, whichever is first.
/// (The previous classifier started at play − 100 ms, so frame 26, still shown just after the seek, became the "first frame ≥ 2".)
///
/// Verdicts: OBSERVED (a confident frame 1 from the expected source after the post-seek frame 0), NOT OBSERVED WITH ADEQUATE EVIDENCE
/// (0 → ≥2 with every sample between readable and every interval shorter than one source frame), otherwise INCONCLUSIVE / ERROR.
/// It never returns a PASS. Not seeing frame 1 is not proof that it was never composited for less than one sample interval, and it
/// is window-server evidence, not panel evidence. A missing compositor request is not used here.
enum F1CaptureClassifier {
    struct Sample: Sendable {
        let seq: Int
        let status: String          // complete, idle, blank, suspended, started, stopped, unknown(n)
        let time: Double            // display time when present, else callback arrival (mach host clock, seconds)
        let confident: Bool         // geometry ok, known source ID, read margin >= 40 (set by CompositorWindowCapture)
        let sourceID: Int?
        let sourceFrame: Int?
    }
    struct Markers: Sendable { let seekZero: Double; let play: Double; let pause: Double }
    enum Verdict: String, Codable, Sendable {
        case observed = "OBSERVED", notObserved = "NOT OBSERVED WITH ADEQUATE EVIDENCE", inconclusive = "INCONCLUSIVE", error = "ERROR"
    }
    struct Result: Codable, Sendable {
        let verdict: Verdict
        let reason: String
        let windowStart: Double?, windowEnd: Double?
        let samplesInWindow: Int
        let statusCounts: [String: Int]
        let completeInWindow: Int, confidentInWindow: Int
        let firstPostSeekZeroMs: Double?     // all *Ms values: milliseconds from the play call
        let lastZeroMs: Double?
        let firstAdvanceMs: Double?, firstAdvanceFrame: Int?
        let frameOneMs: Double?
        let zeroToAdvanceGapMs: Double?
        let maxIntervalMs: Double?           // largest interval between consecutive samples from the post-seek frame 0 to the advance
        let sequence: String                 // de-duplicated confident frames in the window, "frame@ms"
    }

    static let expectedSourceID = 0x33        // otf-TA, the first clip of the F1 timeline (its frames 0…119 cover the window)
    static let sourceFrameSeconds = 1.0 / 30.0
    static let analysisSpan = 1.0             // seconds after play

    static func classify(samples all: [Sample], markers: Markers?, captureError: String?, readyAt: Double?) -> Result {
        var start: Double?, end: Double?, window: [Sample] = []
        var firstZero: Sample?, lastZero: Sample?, advance: Sample?, one: Sample?, gap: Double?, maxInterval: Double?
        func ms(_ t: Double?) -> Double? { guard let t, let m = markers else { return nil }; return ((t - m.play) * 1000 * 10).rounded() / 10 }
        func result(_ v: Verdict, _ reason: String) -> Result {
            let complete = window.filter { $0.status == "complete" }
            var seqText: [String] = [], last: Int?
            for s in complete where s.confident { if let f = s.sourceFrame, f != last { seqText.append("\(f)@\(ms(s.time).map { String(format: "%+.1f", $0) } ?? "?")"); last = f } }
            return Result(verdict: v, reason: reason, windowStart: start, windowEnd: end, samplesInWindow: window.count,
                          statusCounts: Dictionary(grouping: window, by: \.status).mapValues(\.count),
                          completeInWindow: complete.count, confidentInWindow: complete.filter(\.confident).count,
                          firstPostSeekZeroMs: ms(firstZero?.time), lastZeroMs: ms(lastZero?.time), firstAdvanceMs: ms(advance?.time),
                          firstAdvanceFrame: advance?.sourceFrame, frameOneMs: ms(one?.time), zeroToAdvanceGapMs: gap.map { ($0 * 1000 * 10).rounded() / 10 },
                          maxIntervalMs: maxInterval.map { ($0 * 1000 * 10).rounded() / 10 }, sequence: seqText.prefix(24).joined(separator: " "))
        }
        // Markers: present, finite and ordered (seek to 0 ≤ play ≤ pause). Boundaries are never guessed from frame numbers.
        guard let m = markers, m.seekZero.isFinite, m.play.isFinite, m.pause.isFinite, m.seekZero <= m.play, m.play <= m.pause else {
            return result(.inconclusive, "playback markers missing or out of order")
        }
        start = m.seekZero; end = min(m.pause, m.play + analysisSpan)
        if let captureError { return result(.error, "capture error: \(captureError)") }
        if all.contains(where: { ($0.status == "stopped" || $0.status == "suspended") && $0.time >= (readyAt ?? m.seekZero) && $0.time <= m.pause }) {
            return result(.error, "capture stopped or suspended before pause")
        }
        let ordered = all.sorted { $0.seq < $1.seq }
        window = ordered.filter { $0.time >= m.seekZero && $0.time <= end! }
        if window.isEmpty { return result(.inconclusive, "no capture samples between the seek to 0 and the window end") }
        for i in 1..<max(1, window.count) where window[i].time < window[i - 1].time {
            return result(.inconclusive, "capture timestamps are not monotonic in the window (seq \(window[i - 1].seq) → \(window[i].seq))")
        }
        let readable = { (s: Sample) in s.status == "complete" && s.confident }
        guard let z = window.first(where: { readable($0) && $0.sourceFrame == 0 && $0.sourceID == expectedSourceID }) else {
            return result(.inconclusive, "no readable post-seek frame 0 from the expected source")
        }
        firstZero = z
        let post = window.filter { $0.time >= z.time }
        if let other = post.first(where: { readable($0) && $0.sourceID != expectedSourceID }) {
            return result(.inconclusive, "unexpected source ID \(other.sourceID.map { String(format: "0x%02X", $0) } ?? "nil") at seq \(other.seq)")
        }
        if let o = post.first(where: { readable($0) && $0.sourceFrame == 1 }) { one = o; return result(.observed, "frame 1 read at seq \(o.seq)") }
        guard let a = post.first(where: { readable($0) && ($0.sourceFrame ?? -1) >= 2 }) else {
            let ended = (ordered.last?.time ?? -.infinity) < end! - sourceFrameSeconds
            return result(.inconclusive, ended ? "capture ended before the window end without a readable frame ≥ 2" : "no readable frame ≥ 2 after the post-seek frame 0 in the window")
        }
        advance = a
        if a.time < m.play { return result(.inconclusive, "the frame advanced before the play call (seq \(a.seq))") }
        let lead = post.filter { $0.time < a.time }
        if let odd = lead.first(where: { readable($0) && $0.sourceFrame != 0 }) {
            return result(.inconclusive, "readable frame \(odd.sourceFrame ?? -1) between the post-seek frame 0 and the advance (seq \(odd.seq))")
        }
        if let u = lead.first(where: { $0.status == "complete" && !$0.confident }) {
            return result(.inconclusive, "unreadable complete sample before the advance (seq \(u.seq)); frame 1 could be hidden there")
        }
        if let u = lead.first(where: { $0.status != "complete" && $0.status != "idle" }) {
            return result(.inconclusive, "sample with status \(u.status) before the advance (seq \(u.seq))")
        }
        // Frame 0 was last seen at the last readable frame-0 sample or a later idle sample (idle = no new image, so still frame 0).
        guard let lz = lead.last(where: { readable($0) && $0.sourceFrame == 0 }) else { return result(.inconclusive, "no readable frame 0 before the advance") }
        lastZero = lz
        let stillZero = lead.last { $0.time >= lz.time && ($0.status == "idle" || readable($0)) } ?? lz
        gap = a.time - stillZero.time
        let span = post.filter { $0.time <= a.time }
        maxInterval = zip(span, span.dropFirst()).map { $1.time - $0.time }.max() ?? 0
        if gap! >= sourceFrameSeconds || maxInterval! >= sourceFrameSeconds {
            return result(.inconclusive, String(format: "coverage inadequate: last frame 0 → first frame %d gap %.1f ms, largest interval %.1f ms (one source frame %.1f ms)",
                                                 a.sourceFrame ?? -1, gap! * 1000, maxInterval! * 1000, sourceFrameSeconds * 1000))
        }
        return result(.notObserved, String(format: "frame 0 → frame %d with no frame 1; gap %.1f ms, largest interval %.1f ms, all samples between readable",
                                           a.sourceFrame ?? -1, gap! * 1000, maxInterval! * 1000))
    }
}
#endif
