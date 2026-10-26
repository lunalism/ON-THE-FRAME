import AVFoundation
import CoreGraphics
import Darwin
import Foundation
@testable import OnTheFrameEngine
import os
import XCTest

/// 스펙트럼 조율 기준 측정(SP-1A 3A-2, 2026-10-26 — docs/SPECTRUM-DESIGN.md §15.13). OTF_SPECTRUM_COORD_BENCH=1일 때만 돈다(기본 실행에서 건너뜀).
/// 일회용 생성 WAV(24초, 48 kHz 스테레오, 사인 넷 + 약한 잡음)를 시험 작업 폴더에 만들고 끝나면 지운다. 실제 SpectrumFileSource 디코딩.
/// 조건: 캔버스 1920×1080·3840×2160 × 모양 A(잠정 기본 — 64밴드 거울 디지털, 최대 높이 480)·B(큰 모양 — 256밴드, 전체 폭, 최대 높이 540, 두께 6).
/// 기록일 뿐 기준이 아니다. CA commit·디스플레이 링크 프레임 놓침은 이 headless 측정에 없다(3B/3C).
final class SpectrumCoordinatorBench: XCTestCase {
    static let frames = 300

    static func pct(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "n=0" }
        let s = xs.sorted()
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        return String(format: "n=%d p50 %.3f p95 %.3f max %.3f ms", s.count, q(0.5), q(0.95), s.last!)
    }
    static func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1e6 }
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    static func writeWAV(_ url: URL, seconds: Int) throws {
        let rate = 48_000.0, n = Int(rate) * seconds
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                                             AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        var g: UInt64 = 12345
        for i in 0..<n {
            let t = Double(i) / rate
            g = g &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Double(g >> 40) / Double(1 << 24) - 0.5) * 0.02
            let x = 0.15 * sin(2 * .pi * 110 * t) + 0.1 * sin(2 * .pi * 440 * t) + 0.08 * sin(2 * .pi * 1000 * t * (1 + 0.1 * sin(t))) + 0.05 * sin(2 * .pi * 1800 * t) + noise
            buf.floatChannelData![0][i] = Float(x); buf.floatChannelData![1][i] = Float(x * 0.9)
        }
        try f.write(from: buf)
    }
    static let styleA = SpectrumItemStyle.provisionalDefault
    static var styleB: SpectrumItemStyle {
        var s = SpectrumItemStyle.provisionalDefault
        s.bands = 256; s.startXMilli = 0; s.endXMilli = 1_920_000; s.maxHeightMilli = 540_000; s.thicknessMilli = 6_000
        return s
    }

    func testCoordinatorBaseline() async throws {
        guard ProcessInfo.processInfo.environment["OTF_SPECTRUM_COORD_BENCH"] == "1" else { throw XCTSkip("OTF_SPECTRUM_COORD_BENCH=1일 때만") }
        #if DEBUG
        print("SPECTRUM COORD BENCH build: DEBUG (최적화 안 됨)")
        #else
        print("SPECTRUM COORD BENCH build: optimized")
        #endif
        let dir = ExportEndToEndTests.root.appendingPathComponent("coord-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = dir.appendingPathComponent("bench24s.wav")
        try Self.writeWAV(wavURL, seconds: 24)
        let asset = try await MediaProbe.inspect(wavURL)
        let deliveries = DispatchQueue(label: "bench.delivery")
        let m0 = Self.footprintMB()
        print("SPECTRUM COORD BENCH fixture: 24 s 48 kHz stereo WAV \(try FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] ?? 0) bytes, frames per condition \(Self.frames), footprint start \(String(format: "%.1f", m0)) MB")

        // 구성 요소: 디코딩·분석(실제 파일)
        let src = try await SpectrumFileSource.open(url: wavURL, mediaID: asset.id)
        var decodeMs: [Double] = [], chunks: [Int: [[Float]]] = [:]
        for c in 0..<3 { let a = Self.now; chunks[c] = try await src.decodeChunk(c); decodeMs.append(Self.ms(a, Self.now)) }
        print("SPECTRUM COORD BENCH decode chunk (8 s + 1 s margins): \(Self.pct(decodeMs))")
        let piece = [SpectrumSourcePiece(start: 0, length: 720, sourceIn: 0)]
        var bandsByStyle: [Int: [[Float]]] = [:]
        for st in [Self.styleA, Self.styleB] {
            var t: [Double] = [], out: [[Float]] = []
            for k in 0..<Self.frames {
                let a = Self.now
                let b = try SpectrumAnalysis.bands(frame: k, pieces: piece, fps: 30, rate: 48_000, channelCount: 2, chunkSamples: src.chunkSamples, settings: st.analysisSettings) { chunks[$0] }
                t.append(Self.ms(a, Self.now)); out.append(b)
            }
            bandsByStyle[st.bands] = out
            print("SPECTRUM COORD BENCH analysis \(st.bands) bands (pure, predecoded): \(Self.pct(t))")
        }
        // 구성 요소: 그리기(내부 캔버스) vs 공개 입구(그리기 + 소유 복사)
        for (w, h) in [(1920, 1080), (3840, 2160)] {
            for (name, st) in [("A", Self.styleA), ("B", Self.styleB)] {
                let canvas = try SpectrumCanvas(width: w, height: h), facade = try SpectrumFrameRenderer(width: w, height: h)
                var ti: [Double] = [], tf: [Double] = [], bytes: [Double] = []
                for b in bandsByStyle[st.bands]! {
                    var a = Self.now; _ = try canvas.render(b, style: st.renderStyle); ti.append(Self.ms(a, Self.now))
                    a = Self.now; let f = try facade.render(bands: b, style: st); tf.append(Self.ms(a, Self.now))
                    bytes.append(Double((f?.image.bytesPerRow ?? 0) * (f?.image.height ?? 0)))
                }
                print("SPECTRUM COORD BENCH render \(w)x\(h) \(name) internal: \(Self.pct(ti)) | facade(+copy): \(Self.pct(tf)) | owned bytes/frame mean \(String(format: "%.2f", bytes.reduce(0, +) / Double(bytes.count) / 1_048_576)) MB max \(String(format: "%.2f", (bytes.max() ?? 0) / 1_048_576)) MB")
            }
        }

        // 조율 전체(실제 opener·일정·그리기·전달)
        var t = Timeline().registering(asset)
        let clip = UUID(), lane = UUID(), sidA = UUID(), sidB = UUID()
        t = try t.placing(media: asset.id, at: 0, videoLane: nil, audioLane: Lane.audioID, clipID: clip)
        let key = t.clip(clip)!.lineageKey, laneB = UUID()
        t = try t.addingLane(.spectrum, name: "SP", id: lane).addingSpectrum(lane: lane, at: 0, length: 720, sourceKey: key, style: Self.styleA, id: sidA)
        t = try t.addingLane(.spectrum, name: "SPB", id: laneB).addingSpectrum(lane: laneB, at: 0, length: 720, sourceKey: key, style: Self.styleB, id: sidB)
        var peak = m0
        for (w, h) in [(1920, 1080), (3840, 2160)] {
            for (name, sid) in [("A", sidA), ("B", sidB)] {
                let c = SpectrumFrameCoordinator(deliveryQueue: deliveries)
                c.update(timeline: t, media: [asset])
                func one(_ k: Int) async -> (Double, String) {
                    let a = Self.now
                    let o = await withCheckedContinuation { (x: CheckedContinuation<SpectrumFrameOutcome, Never>) in
                        c.request(spectrum: sid, frame: k, canvasWidth: w, canvasHeight: h) { x.resume(returning: $0) }
                    }
                    let d = Self.ms(a, Self.now)
                    if case .ready = o { return (d, "ready") }
                    return (d, SpectrumFrameCoordinatorTests.name(o))
                }
                var cold: [Double] = [], warm: [Double] = [], bad = 0
                for k in 0..<Self.frames { let (d, s) = await one(k); cold.append(d); if s != "ready" { bad += 1 } }
                peak = max(peak, Self.footprintMB())
                for k in 0..<Self.frames { let (d, s) = await one(k); warm.append(d); if s != "ready" { bad += 1 } }
                let st = c.scheduler.statistics
                print("SPECTRUM COORD BENCH e2e \(w)x\(h) \(name) cold(sequential, first incl. open): \(Self.pct(cold)) first \(String(format: "%.2f", cold[0])) ms | warm(band cache): \(Self.pct(warm)) | not ready \(bad) | decodes \(st.decodes) analyses \(st.analyses)")
                peak = max(peak, Self.footprintMB())
                // 시간 맞춘 부하(새 조율, 차가운 캐시): 30 Hz는 틱마다 프레임 하나, 60 Hz는 프레임마다 두 번. 늦음 = 다음 틱 전에 오지 않음.
                for hz in [30, 60] {
                    let c2 = SpectrumFrameCoordinator(deliveryQueue: deliveries)
                    c2.update(timeline: t, media: [asset])
                    let ticks = 10 * hz, period = 1_000_000_000 / UInt64(hz)
                    let lat = OSAllocatedUnfairLock(initialState: [Double]()), outs = OSAllocatedUnfairLock(initialState: [String: Int]())
                    let start = Self.now
                    for i in 0..<ticks {
                        let target = start + UInt64(i) * period
                        let nowNs = Self.now
                        if target > nowNs { try await Task.sleep(nanoseconds: target - nowNs) }
                        let k = i * 30 / hz, a = Self.now
                        c2.request(spectrum: sid, frame: k, canvasWidth: w, canvasHeight: h) { o in
                            let d = Self.ms(a, Self.now)
                            lat.withLock { $0.append(d) }
                            let s: String = { if case .ready = o { return "ready" }; return SpectrumFrameCoordinatorTests.name(o) }()
                            outs.withLock { $0[s, default: 0] += 1 }
                        }
                    }
                    let end = Date().addingTimeInterval(20)
                    while lat.withLock({ $0.count }) < ticks, Date() < end { try await Task.sleep(nanoseconds: 2_000_000) }
                    let l = lat.withLock { $0 }, late = l.filter { $0 > Double(period) / 1e6 }.count
                    print("SPECTRUM COORD BENCH paced \(hz) Hz \(w)x\(h) \(name): \(Self.pct(l)) | later than one tick \(late)/\(l.count) | outcomes \(outs.withLock { $0 })")
                    peak = max(peak, Self.footprintMB())
                }
            }
        }
        print("SPECTRUM COORD BENCH footprint MB start \(String(format: "%.1f", m0)) peak(sampled) \(String(format: "%.1f", peak)) end \(String(format: "%.1f", Self.footprintMB()))")
    }
}
