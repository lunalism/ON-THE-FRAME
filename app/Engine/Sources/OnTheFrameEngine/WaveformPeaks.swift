import Accelerate
import AVFoundation
import Foundation

// WAVEFORM-01 (2026-11-22): display peaks of a source's real decoded audio for timeline audio clips.
// Decoding reuses the Spectrum PCM path (SpectrumFileSource: AVAssetReader, PTS-placed Float32 at 48 kHz, mono/stereo,
// cancellation per buffer). Channels are never mixed. Values are display-only (no audio change, nothing saved).
// Timing uses the Spectrum frame ↔ sample rule (SpectrumFrameMap), so the waveform and the Spectrum/preview use the
// same source position for a clip frame.

/// Min/max peak envelope per channel. Level 0 has one bucket per `baseBucketSamples`; each further level merges
/// `levelFactor` buckets of the previous one (for zoomed-out drawing). Amplitudes are stored as Int8 (−127…127 = −1…1,
/// nearest; exact silence stays 0). Level-0 buckets are 200 samples (1/8 of a 30 fps timeline frame at 48 kHz), so timeline
/// frame edges fall exactly on bucket edges; a stereo 3-hour source then needs about 10 MB for level 0.
public struct WaveformPeaks: Sendable, Equatable {
    public static let baseBucketSamples = 200
    public static let levelFactor = 16
    /// Level-0 buckets per channel before the bucket size doubles (bounds memory for very long sources).
    public static let maxBaseBuckets = 4_000_000

    struct Level: Sendable, Equatable {
        let bucket: Int
        let mins: [[Int8]], maxs: [[Int8]]   // [channel][bucket]
    }

    public let sampleRate: Int, channelCount: Int
    /// Decoded source length in samples (the envelope covers [0, sampleCount)).
    public let sampleCount: Int
    let levels: [Level]

    public var bucketSamples: Int { levels[0].bucket }
    public var levelCount: Int { levels.count }
    /// Stored bytes (all levels, all channels).
    public var byteCount: Int {
        var n = 0
        for level in levels { for ch in level.mins { n += 2 * ch.count } }   // mins + maxs
        return n
    }

    public static func bucketSamples(forSampleCount n: Int) -> Int {
        var b = baseBucketSamples
        while (n + b - 1) / b > maxBaseBuckets { b *= 2 }
        return b
    }
    static func quantize(_ v: Float) -> Int8 { Int8((max(-1, min(1, v)) * 127).rounded()) }
    static func amplitude(_ q: Int8) -> Float { Float(q) / 127 }

    // MARK: Timing (same rule as Spectrum: sample(k) = k · rate / fps at integer frames)

    /// Source sample at a (fractional) source frame position, rounded down. At integer frames this equals
    /// `SpectrumFrameMap.sample(atFrame:fps:rate:)` for rates that are a multiple of the fps.
    public static func sample(atSourceFrame k: Double, fps: Int = 30, rate: Int) -> Int {
        Int((k * Double(rate) / Double(fps)).rounded(.down))
    }
    /// Source samples shown for the timeline span [f0, f1) (fractional frames) of a clip placed at `start` with
    /// `sourceIn` and `length`. The span is clipped to the clip; nil when nothing of the clip lies in it.
    public static func sourceSamples(clipStart start: Int, sourceIn: Int, length: Int, timeline f0: Double, _ f1: Double,
                                     fps: Int = 30, rate: Int) -> Range<Int>? {
        let a = max(f0, Double(start)), b = min(f1, Double(start + length))
        guard b > a else { return nil }
        let s0 = sample(atSourceFrame: Double(sourceIn) + (a - Double(start)), fps: fps, rate: rate)
        let s1 = sample(atSourceFrame: Double(sourceIn) + (b - Double(start)), fps: fps, rate: rate)
        return s0 ..< max(s0 + 1, s1)
    }

    // MARK: Query

    /// Min/max amplitude (−1…1) of `channel` over source samples `r`, exact at level-0 bucket resolution: whole coarser
    /// buckets are used where they fit inside the range and finer ones at its edges (so a zoomed-out column never shows
    /// peaks from outside its own span). nil when the range lies outside the decoded source.
    public func envelope(channel: Int, samples r: Range<Int>) -> (min: Float, max: Float)? {
        guard (0..<channelCount).contains(channel) else { return nil }
        let lo = max(0, r.lowerBound), hi = min(sampleCount, r.upperBound)
        guard hi > lo else { return nil }
        let base = levels[0].bucket
        let b1 = min(levels[0].mins[channel].count, (hi + base - 1) / base)
        var i = lo / base
        guard b1 > i else { return nil }
        var mn = Int8.max, mx = Int8.min
        while i < b1 {
            // the coarsest level whose bucket starts at i and ends inside the range
            var j = 0, width = 1
            while j + 1 < levels.count, i % (width * Self.levelFactor) == 0, i + width * Self.levelFactor <= b1 { j += 1; width *= Self.levelFactor }
            let k = i / width
            mn = min(mn, levels[j].mins[channel][k]); mx = max(mx, levels[j].maxs[channel][k])
            i += width
        }
        return (Self.amplitude(mn), Self.amplitude(mx))
    }

    // MARK: Building

    /// Accumulates decoded samples in order. `append` takes per-channel samples starting at source sample `at`
    /// (consecutive calls must continue where the previous one ended); samples at or beyond `sampleCount` are ignored.
    public struct Builder {
        public let sampleRate: Int, channelCount: Int, sampleCount: Int, bucket: Int
        private var mins: [[Int8]], maxs: [[Int8]]
        private var curMin: [Float], curMax: [Float]
        private var position = 0, curBucket = 0, curHas = false

        public init(sampleRate: Int, channelCount: Int, sampleCount: Int) {
            precondition(channelCount > 0 && sampleCount >= 0 && sampleRate > 0)
            self.sampleRate = sampleRate; self.channelCount = channelCount; self.sampleCount = sampleCount
            bucket = WaveformPeaks.bucketSamples(forSampleCount: sampleCount)
            let n = (sampleCount + bucket - 1) / bucket
            mins = [[Int8]](repeating: [Int8](repeating: 0, count: n), count: channelCount)
            maxs = mins
            curMin = [Float](repeating: .infinity, count: channelCount)
            curMax = [Float](repeating: -.infinity, count: channelCount)
        }

        public mutating func append(_ channels: [[Float]], at start: Int) {
            precondition(channels.count == channelCount && start == position, "waveform input must be contiguous")
            let n = channels.first?.count ?? 0
            let end = min(start + n, sampleCount)
            var p = start
            while p < end {
                let b = p / bucket
                let q = min((b + 1) * bucket, end)
                if b != curBucket { flush(); curBucket = b }
                for c in 0..<channelCount {
                    channels[c].withUnsafeBufferPointer { buf in
                        var lo: Float = 0, hi: Float = 0
                        let base = buf.baseAddress! + (p - start)
                        vDSP_minv(base, 1, &lo, vDSP_Length(q - p))
                        vDSP_maxv(base, 1, &hi, vDSP_Length(q - p))
                        curMin[c] = min(curMin[c], lo); curMax[c] = max(curMax[c], hi)
                    }
                }
                curHas = true
                p = q
            }
            position = start + n
        }

        private mutating func flush() {
            guard curHas else { return }
            for c in 0..<channelCount {
                mins[c][curBucket] = WaveformPeaks.quantize(curMin[c]); maxs[c][curBucket] = WaveformPeaks.quantize(curMax[c])
                curMin[c] = .infinity; curMax[c] = -.infinity
            }
            curHas = false
        }

        /// Level 0 plus merged levels while a level still has more than one bucket. Unfilled buckets stay 0 (silence).
        public mutating func finish() -> WaveformPeaks {
            flush()
            var levels = [Level(bucket: bucket, mins: mins, maxs: maxs)]
            while let last = levels.last, last.mins[0].count > 1 {
                let f = WaveformPeaks.levelFactor, n = (last.mins[0].count + f - 1) / f
                let mn = last.mins.map { ch in (0..<n).map { i in ch[(i * f)..<min(ch.count, (i + 1) * f)].min()! } }
                let mx = last.maxs.map { ch in (0..<n).map { i in ch[(i * f)..<min(ch.count, (i + 1) * f)].max()! } }
                levels.append(Level(bucket: last.bucket * f, mins: mn, maxs: mx))
            }
            return WaveformPeaks(sampleRate: sampleRate, channelCount: channelCount, sampleCount: sampleCount, levels: levels)
        }
    }

    /// Builds peaks from a PCM provider (chunks in order, cancellable between and inside chunks).
    public static func build(provider: SpectrumPCMProvider, sampleCount: Int) async throws -> WaveformPeaks {
        var b = Builder(sampleRate: provider.sampleRate, channelCount: provider.channelCount, sampleCount: sampleCount)
        var c = 0
        while c * provider.chunkSamples < sampleCount {
            if Task.isCancelled { throw SpectrumAnalysisError.cancelled }
            let data = try await provider.decodeChunk(c)
            guard data.count == provider.channelCount, data.allSatisfy({ $0.count == provider.chunkSamples }) else {
                throw SpectrumAnalysisError.decodeFailed("waveform chunk shape")
            }
            b.append(data, at: c * provider.chunkSamples)
            c += 1
        }
        if Task.isCancelled { throw SpectrumAnalysisError.cancelled }
        return b.finish()
    }

    /// Opens `url` with the Spectrum file source (48 kHz, mono or stereo; other channel counts are unsupported) and
    /// decodes the whole audio track. The caller must hold file access (security scope), as for Spectrum.
    public static func analyze(url: URL, mediaID: UUID? = nil) async throws -> WaveformPeaks {
        let source = try await SpectrumFileSource.open(url: url, mediaID: mediaID)
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first else { throw SpectrumAnalysisError.noAudioTrack }
        let range = try await track.load(.timeRange)
        // PTS-based, the same time base the decoder places samples on: sample 0 is the playback reference start
        // (SourceTimeOrigin), so the decoded length is counted from there. Unchanged when that start is zero.
        let end = CMTimeGetSeconds(source.timeOrigin == .zero ? range.end : CMTimeSubtract(range.end, source.timeOrigin))
        guard end.isFinite, end > 0, end < 24 * 3600 else { throw SpectrumAnalysisError.decodeFailed("audio duration \(end)") }
        return try await build(provider: source, sampleCount: Int((end * Double(source.sampleRate)).rounded(.up)))
    }
}
