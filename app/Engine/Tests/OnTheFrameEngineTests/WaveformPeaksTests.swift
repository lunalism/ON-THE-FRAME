import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// WAVEFORM-01: peaks come from real decoded samples, per channel, with Spectrum's frame ↔ sample timing.
final class WaveformPeaksTests: XCTestCase {
    /// Deterministic in-memory PCM (48 kHz, fixed chunk grid, zero outside the signal), like SpectrumFileSource.
    final class Provider: SpectrumPCMProvider, @unchecked Sendable {
        let identity = SpectrumSourceIdentity("test-\(UUID().uuidString)")
        let sampleRate = 48_000, chunkSamples: Int, channelCount: Int, length: Int
        let value: @Sendable (_ channel: Int, _ sample: Int) -> Float
        var decoded = 0
        var cancelAfter: Int?
        init(channels: Int, length: Int, chunk: Int = 48_000, value: @escaping @Sendable (Int, Int) -> Float) {
            channelCount = channels; self.length = length; chunkSamples = chunk; self.value = value
        }
        func decodeChunk(_ c: Int) async throws -> [[Float]] {
            decoded += 1
            if let n = cancelAfter, decoded > n { throw SpectrumAnalysisError.cancelled }
            return (0..<channelCount).map { ch in
                (0..<chunkSamples).map { i in let s = c * chunkSamples + i; return s < length ? value(ch, s) : 0 }
            }
        }
    }
    static func sine(_ amp: Float, _ hz: Double) -> @Sendable (Int) -> Float {
        { s in amp * Float(sin(2 * Double.pi * hz * Double(s) / 48_000)) }
    }
    private func q(_ v: Float) -> Float { Float(Int8((v * 127).rounded())) / 127 }

    func testMonoPeaksFollowTheRealAmplitude() async throws {
        let p = Provider(channels: 1, length: 96_000) { _, s in WaveformPeaksTests.sine(0.5, 440)(s) }
        let w = try await WaveformPeaks.build(provider: p, sampleCount: 96_000)
        XCTAssertEqual(w.channelCount, 1)
        XCTAssertEqual(w.bucketSamples, 200)
        XCTAssertEqual(1_600 % w.bucketSamples, 0, "timeline frames (1 600 samples) end on bucket edges")
        let e = try XCTUnwrap(w.envelope(channel: 0, samples: 0..<48_000))
        XCTAssertEqual(e.max, q(0.5), accuracy: 0.01); XCTAssertEqual(e.min, -q(0.5), accuracy: 0.01)
        XCTAssertNil(w.envelope(channel: 1, samples: 0..<10), "mono has no second channel")
    }

    func testStereoChannelsStaySeparateWithTheirOwnAmplitudes() async throws {
        let l = WaveformPeaksTests.sine(0.8, 300), r = WaveformPeaksTests.sine(0.2, 700)
        let p = Provider(channels: 2, length: 48_000 * 3) { ch, s in ch == 0 ? l(s) : r(s) }
        let w = try await WaveformPeaks.build(provider: p, sampleCount: 48_000 * 3)
        let le = try XCTUnwrap(w.envelope(channel: 0, samples: 48_000..<96_000))
        let re = try XCTUnwrap(w.envelope(channel: 1, samples: 48_000..<96_000))
        XCTAssertEqual(le.max, q(0.8), accuracy: 0.01, "left keeps 0.8")
        XCTAssertEqual(re.max, q(0.2), accuracy: 0.01, "right keeps 0.2 (not mixed)")
        XCTAssertEqual(le.min, -q(0.8), accuracy: 0.01); XCTAssertEqual(re.min, -q(0.2), accuracy: 0.01)
    }

    func testSilenceIsExactlyZeroAndOneSidedSignalsStayOneSided() async throws {
        let p = Provider(channels: 2, length: 48_000) { ch, s in ch == 0 ? 0 : (s >= 24_000 ? 0.5 : 0) }
        let w = try await WaveformPeaks.build(provider: p, sampleCount: 48_000)
        let silent = try XCTUnwrap(w.envelope(channel: 0, samples: 0..<48_000))
        XCTAssertEqual(silent.min, 0); XCTAssertEqual(silent.max, 0)
        let before = try XCTUnwrap(w.envelope(channel: 1, samples: 0..<24_000))
        XCTAssertEqual(before.max, 0, "no fabricated values before the signal starts")
        let dc = try XCTUnwrap(w.envelope(channel: 1, samples: 24_064..<48_000))
        XCTAssertEqual(dc.min, q(0.5), accuracy: 0.001); XCTAssertEqual(dc.max, q(0.5), accuracy: 0.001)
    }

    func testFrameToSampleMappingMatchesSpectrumAndSourceOffsets() async throws {
        for k in [0, 1, 29, 30, 31, 900, 9_000] {
            XCTAssertEqual(WaveformPeaks.sample(atSourceFrame: Double(k), rate: 48_000), SpectrumFrameMap.sample(atFrame: k, fps: 30, rate: 48_000))
        }
        // Step at source second 1 (frame 30, sample 48 000): a clip at timeline 100 with sourceIn 20 shows it at timeline 110.
        let p = Provider(channels: 1, length: 48_000 * 4) { _, s in s >= 48_000 ? 1 : 0 }
        let w = try await WaveformPeaks.build(provider: p, sampleCount: 48_000 * 4)
        func shown(_ f: Int) -> Float? {
            WaveformPeaks.sourceSamples(clipStart: 100, sourceIn: 20, length: 60, timeline: Double(f), Double(f + 1), rate: 48_000)
                .flatMap { w.envelope(channel: 0, samples: $0) }?.max
        }
        XCTAssertEqual(shown(109), 0); XCTAssertEqual(shown(110), 1)
        XCTAssertNil(WaveformPeaks.sourceSamples(clipStart: 100, sourceIn: 20, length: 60, timeline: 160, 161, rate: 48_000), "outside the clip")
        XCTAssertNil(WaveformPeaks.sourceSamples(clipStart: 100, sourceIn: 20, length: 60, timeline: 90, 100, rate: 48_000))
        XCTAssertEqual(WaveformPeaks.sourceSamples(clipStart: 100, sourceIn: 20, length: 60, timeline: 99.5, 100.5, rate: 48_000), 32_000..<32_800, "clipped to the clip")
    }

    func testZoomedOutLevelsAgreeWithTheFinestLevel() async throws {
        let p = Provider(channels: 2, length: 48_000 * 20) { ch, s in
            Float(sin(Double(s) * 0.0007)) * (ch == 0 ? 0.9 : 0.3) * (s % 7_919 == 0 ? 1 : 0.6)
        }
        let w = try await WaveformPeaks.build(provider: p, sampleCount: 48_000 * 20)
        XCTAssertGreaterThan(w.levelCount, 2)
        for (a, b) in [(0, 4_096), (12_345, 99_999), (100_000, 900_000), (0, 960_000)] {
            for ch in 0..<2 {
                let coarse = try XCTUnwrap(w.envelope(channel: ch, samples: a..<b))
                var mn: Float = 1, mx: Float = -1
                let bucket = w.bucketSamples
                var s = (a / bucket) * bucket
                while s < b { let e = w.envelope(channel: ch, samples: s..<(s + 1))!; mn = min(mn, e.min); mx = max(mx, e.max); s += bucket }
                XCTAssertEqual(coarse.min, mn, "ch \(ch) [\(a),\(b)) min"); XCTAssertEqual(coarse.max, mx, "ch \(ch) [\(a),\(b)) max")
            }
        }
        XCTAssertNil(w.envelope(channel: 0, samples: (48_000 * 20)..<(48_000 * 21)), "beyond the decoded source")
    }

    func testCancellationAndDecodeFailurePropagate() async throws {
        let p = Provider(channels: 1, length: 48_000 * 10) { _, _ in 0.1 }
        p.cancelAfter = 2
        do { _ = try await WaveformPeaks.build(provider: p, sampleCount: 48_000 * 10); XCTFail("expected cancellation") }
        catch { XCTAssertEqual(error as? SpectrumAnalysisError, .cancelled) }
        let task = Task { try await WaveformPeaks.build(provider: Provider(channels: 1, length: 48_000 * 600) { _, _ in 0.1 }, sampleCount: 48_000 * 600) }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertEqual(error as? SpectrumAnalysisError, .cancelled) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("otf-waveform-missing-\(UUID().uuidString).wav")
        do { _ = try await WaveformPeaks.analyze(url: missing); XCTFail("unreadable source must fail") } catch {}
    }

    func testMemoryStaysBoundedForLongSources() {
        XCTAssertEqual(WaveformPeaks.bucketSamples(forSampleCount: 48_000 * 3600 * 3), 200, "3 h keeps 200-sample buckets")
        let b = WaveformPeaks.bucketSamples(forSampleCount: 48_000 * 3600 * 12)
        XCTAssertGreaterThan(b, 200)
        XCTAssertEqual(1_600 % b, 0, "doubled buckets still end on frame edges")
        XCTAssertLessThanOrEqual((48_000 * 3600 * 12 + b - 1) / b, WaveformPeaks.maxBaseBuckets)
    }

    /// Real decode (AVAssetReader via SpectrumFileSource) of a generated stereo WAV, then split/trim/overwrite-paste
    /// alignment: each edited piece shows exactly the source samples the original clip showed at the same timeline frame.
    func testRealStereoWAVAndEditAlignment() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otf-waveform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lr.wav"), n = 48_000 * 4
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {   // left: 0.6 tone for the first 2 s then silence; right: 0.25 tone throughout
            buf.floatChannelData![0][i] = i < 96_000 ? Float(0.6 * sin(2 * Double.pi * 440 * Double(i) / 48_000)) : 0
            buf.floatChannelData![1][i] = Float(0.25 * sin(2 * Double.pi * 660 * Double(i) / 48_000))
        }
        do {
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                                              AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            try f.write(from: buf)
        }
        let w = try await WaveformPeaks.analyze(url: url)
        XCTAssertEqual(w.channelCount, 2); XCTAssertEqual(w.sampleCount, n)
        let l1 = try XCTUnwrap(w.envelope(channel: 0, samples: 0..<48_000)), l3 = try XCTUnwrap(w.envelope(channel: 0, samples: 120_000..<168_000))
        let r1 = try XCTUnwrap(w.envelope(channel: 1, samples: 0..<48_000)), r3 = try XCTUnwrap(w.envelope(channel: 1, samples: 120_000..<168_000))
        XCTAssertEqual(l1.max, 0.6, accuracy: 0.02); XCTAssertEqual(r1.max, 0.25, accuracy: 0.02)
        XCTAssertEqual(l3.max, 0, accuracy: 0.001, "left is silent after 2 s"); XCTAssertEqual(r3.max, 0.25, accuracy: 0.02, "right continues")

        let m = try await MediaProbe.inspect(url)
        let id = UUID()
        let t0 = Timeline(audioClips: [Clip(id: id, mediaID: m.id, start: 30, sourceIn: 10, length: 90, lane: Lane.audioID)]).registering(m)
        let original = try XCTUnwrap(t0.clip(id))
        func samples(_ c: Clip, _ f: Int) -> Range<Int>? {
            WaveformPeaks.sourceSamples(clipStart: c.start, sourceIn: c.sourceIn, length: c.length, timeline: Double(f), Double(f + 1), rate: w.sampleRate)
        }
        /// Every frame f of a piece shows source frame sourceIn + (f − start) (1 600 samples per frame at 48 kHz / 30 fps).
        func followsSource(_ c: Clip, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
            for f in c.start..<c.end {
                let k = c.sourceIn + (f - c.start)
                XCTAssertEqual(samples(c, f), (k * 1_600)..<((k + 1) * 1_600), "\(label) frame \(f)", file: file, line: line)
            }
        }
        /// Pieces that keep their timeline position (split, overwrite remainder) show what the original showed there.
        func aligned(_ t: Timeline, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
            for c in t.audioClips where c.mediaID == m.id {
                followsSource(c, label, file: file, line: line)
                for f in c.start..<c.end {
                    XCTAssertEqual(samples(c, f), samples(original, f), "\(label) frame \(f)", file: file, line: line)
                }
            }
        }
        followsSource(original, "original")
        aligned(try t0.splitting(clip: id, atFrame: 70), "split")
        // Trim start keeps the clip's start and advances sourceIn: the first frame now shows source frame 10 + 15.
        let ts = try XCTUnwrap(try t0.trimmingStart(clip: id, by: 15).clip(id))
        XCTAssertEqual(ts.start, 30); XCTAssertEqual(ts.sourceIn, 25)
        followsSource(ts, "trim start")
        XCTAssertEqual(samples(ts, 30), samples(original, 45), "trimmed start shows the source formerly at frame 45")
        let te = try XCTUnwrap(try t0.trimmingEnd(clip: id, by: -20).clip(id))
        followsSource(te, "trim end")
        for f in te.start..<te.end { XCTAssertEqual(samples(te, f), samples(original, f), "trim end keeps the remaining frames") }
        // Overwrite paste of a 10-frame copy (source 0…) at 60: the remaining parts keep their original source samples.
        let r = try t0.pastingOverwrite(ClipboardContent(video: [], audio: [Clip(mediaID: m.id, start: 0, sourceIn: 0, length: 10, lane: Lane.audioID)]),
                                        at: 60, newLaneName: { _ in "A" })
        let remaining = Timeline(audioClips: r.timeline.audioClips.filter { !r.ids.values.contains($0.id) }).registering(m)
        aligned(remaining, "overwrite paste remainder")
        let pasted = try XCTUnwrap(r.timeline.audioClips.first { r.ids.values.contains($0.id) })
        XCTAssertEqual(samples(pasted, 60), 0..<1_600, "pasted copy shows its own source start")
        // Moving keeps the source window: the clip moved by +40 shows at f + 40 what it showed at f.
        let moved = try t0.relocating(clip: id, toStart: 70, lane: Lane.audioID)
        let mc = try XCTUnwrap(moved.clip(id))
        for f in original.start..<original.end { XCTAssertEqual(samples(mc, f + 40), samples(original, f)) }
    }
}
