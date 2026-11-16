import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 스펙트럼 분석 시제품 검사(2026-10-24, OTF_SPECTRUM_PROTO=1일 때만). 기존 생성 fixture(aud-wav48s 440 Hz, aud-steady48s 1000 Hz, aud-aac48s 2500 Hz + 클릭)를 쓰고,
/// 반대 위상 스테레오만 임시 폴더에 작게 만든다.
final class SpectrumAnalysisPrototypeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SPECTRUM_PROTO"] == "1", "스펙트럼 시제품 검사는 OTF_SPECTRUM_PROTO=1일 때만")
    }
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    func piece(_ len: Int, audio: ClipAudio = .default, lane: Double = 1, start: Int = 0, sourceIn: Int = 0) -> ProtoPiece {
        ProtoPiece(start: start, length: len, sourceIn: sourceIn, audio: audio, laneGain: lane)
    }
    func expectedValue(amplitude a: Double, extraDB: Double = 0) -> Float { Float((20 * log10(a) + extraDB + 60) / 60) }

    func testExactFrameSampleMapping() {
        XCTAssertEqual(ProtoFrameMap.sample(atFrame: 7, fps: 30, rate: 48_000), 11_200)          // 1600/프레임은 48 kHz·30 fps에서만
        XCTAssertEqual(ProtoFrameMap.sample(atFrame: 7, fps: 30, rate: 44_100), 10_290)          // 1470/프레임
        XCTAssertEqual(ProtoFrameMap.sample(atFrame: 1, fps: 24, rate: 44_100), 1_838)           // 1837.5 → 절반 올림
        XCTAssertEqual(ProtoFrameMap.sample(atFrame: 3, fps: 24, rate: 44_100), 5_513)           // 5512.5 → 5513
        for k in [0, 1, 29, 30, 107_999] { XCTAssertEqual(ProtoFrameMap.frame(containingSample: ProtoFrameMap.sample(atFrame: k, fps: 30, rate: 48_000), fps: 30, rate: 48_000), k) }
    }

    func testToneAndSilence() throws {
        let a = ProtoAnalyzer(source: ProtoPCMSource(url: fixtures.appendingPathComponent("aud-wav48s.wav")))
        let v = try a.bands(frame: 30, pieces: [piece(100)])   // 표본 48000 근처(클릭 12345·60000에서 멂)
        let peak = v.indices.max { v[$0] < v[$1] }!
        print("PROTO tone440 peak band \(peak) (expected \(a.bandIndex(ofHz: 440))) value \(v[peak]) expected \(expectedValue(amplitude: 0.2))")
        XCTAssertEqual(peak, a.bandIndex(ofHz: 440))
        XCTAssertEqual(v[peak], expectedValue(amplitude: 0.2), accuracy: 0.02)
        XCTAssertEqual(try a.bands(frame: 90, pieces: [piece(100)]).max()!, 0, "파일 끝 뒤(표본 144000 > 96000)는 무음")
        XCTAssertEqual(try a.bands(frame: 30, pieces: []).max()!, 0, "조각 없음(유효·무음)")
    }

    func testOppositePhaseAndOneSidedStereo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otf-spectrum-proto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ r: (Float) -> Float) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                                                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
            let n = 48_000, buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { let x = Float(0.2 * sin(2 * Double.pi * 1000 * Double(i) / 48_000)); buf.floatChannelData![0][i] = x; buf.floatChannelData![1][i] = r(x) }
            try f.write(from: buf)
            return url
        }
        let opp = ProtoAnalyzer(source: ProtoPCMSource(url: try write("opp.wav") { -$0 }))
        let e = try opp.bands(frame: 15, pieces: [piece(30)]), avg = try opp.bands(frame: 15, pieces: [piece(30)], combine: .averagePCM)
        print("PROTO opposite-phase energy max \(e.max()!) averagePCM max \(avg.max()!)")
        XCTAssertEqual(e.max()!, expectedValue(amplitude: 0.2), accuracy: 0.02, "에너지 결합: 반대 위상도 한 채널과 같은 크기")
        XCTAssertLessThan(avg.max()!, 0.05, "L/R 평균 뒤 FFT는 상쇄(실험 방식의 위험)")
        let one = ProtoAnalyzer(source: ProtoPCMSource(url: try write("left.wav") { _ in 0 }))
        let o = try one.bands(frame: 15, pieces: [piece(30)])
        XCTAssertEqual(o.max()!, expectedValue(amplitude: 0.2, extraDB: -3.0103), accuracy: 0.02, "한쪽만: −3 dB(채널 에너지 평균)")
    }

    func testGainFadeMuteAtSampleStage() throws {
        let a = ProtoAnalyzer(source: ProtoPCMSource(url: fixtures.appendingPathComponent("aud-steady48s.wav")))
        let base = try a.bands(frame: 60, pieces: [piece(150)])
        let k = a.bandIndex(ofHz: 1000)
        XCTAssertEqual(base[k], expectedValue(amplitude: 0.2), accuracy: 0.02)
        let half = try a.bands(frame: 60, pieces: [piece(150, audio: ClipAudio(volumePercent: 50))])
        XCTAssertEqual(half[k] - base[k], Float(-6.0206 / 60), accuracy: 0.003, "클립 음량 50%")
        XCTAssertEqual(try a.bands(frame: 60, pieces: [piece(150, audio: ClipAudio(muted: true))]).max()!, 0, "클립 음소거")
        XCTAssertEqual(try a.bands(frame: 60, pieces: [piece(150, lane: 0)]).max()!, 0, "레인 음소거(이득 0)")
        let lane = try a.bands(frame: 60, pieces: [piece(150, lane: 0.5)])
        XCTAssertEqual(lane[k] - base[k], Float(-6.0206 / 60), accuracy: 0.003, "레인 음량 50%")
        // 페이드 인 60프레임: 프레임 30 중심 이득 0.5(창 안에서 0.489…0.511로 바뀜 — 표본마다 곱함)
        let fade = try a.bands(frame: 30, pieces: [piece(150, audio: ClipAudio(fadeIn: .init(length: 60)))])
        print("PROTO fade-in mid Δ \(fade[k] - base[k]) expected \(-6.0206 / 60)")
        XCTAssertEqual(fade[k] - base[k], Float(-6.0206 / 60), accuracy: 0.005)
        // 페이드 시작 가장자리(프레임 0, 창 앞 절반은 클립 밖 = 0): 막대 높이에 이득을 곱하는 방식과 다름을 기록
        let edge = try a.bands(frame: 1, pieces: [piece(150, audio: ClipAudio(fadeIn: .init(length: 60)))])
        let g1 = 1.0 / 60
        print("PROTO fade edge frame1 value \(edge[k]) vs base×gain-in-dB \(base[k] + Float(20 * log10(g1) / 60))")
    }

    func testSeekOrderAndChunkBoundaryDeterminism() throws {
        let url = fixtures.appendingPathComponent("aud-steady48s.wav")
        let small = ProtoPCMSource(url: url, chunk: 24_000, margin: 4_800)   // 0.5초 덩어리(경계를 많이 지나게)
        let seq = ProtoAnalyzer(source: small, cacheChunks: 2)
        let frames = Array(0..<180)
        let p = [piece(180)]
        let a = try frames.map { try seq.bands(frame: $0, pieces: p) }
        var rng = SystemRandomNumberGenerator()
        let shuffled = frames.shuffled(using: &rng)
        let rnd = ProtoAnalyzer(source: ProtoPCMSource(url: url, chunk: 24_000, margin: 4_800), cacheChunks: 2)
        var b = [[Float]](repeating: [], count: frames.count)
        for f in shuffled { b[f] = try rnd.bands(frame: f, pieces: p) }
        XCTAssertEqual(a, b, "탐색 순서와 무관하게 같은 값(캐시 2개로 덩어리를 자주 다시 읽음)")
        let whole = ProtoAnalyzer(source: ProtoPCMSource(url: url, chunk: 400_000, margin: 0))
        let c = try frames.map { try whole.bands(frame: $0, pieces: p) }
        XCTAssertEqual(a, c, "덩어리 경계를 지나는 창도 한 번에 읽은 것과 같음(WAV)")
        print("PROTO decodes seq \(small.decodes) shuffled \(rnd.source.decodes) whole \(whole.source.decodes)")
    }

    /// AAC: 앞부분(인코더 준비 표본) 처리와 덩어리 디코딩 경계. 기대: 클릭이 원본 표본 20000에 오고, 덩어리로 읽어도 한 번에 읽은 것과 같음.
    func testAACPrimingAndChunkBoundaries() throws {
        let fx = AudioFixture.aac, url = fixtures.appendingPathComponent(fx.file)
        let full = try ProtoPCMSource(url: url, chunk: 200_000, margin: 0).decodeRange(0, 200_000, keep: 0 ..< fx.lengthSamples)[0]
        let orig = fx.samples()
        // 클릭 시작: 음(진폭 0.2)보다 큰 첫 표본(문턱 0.4) — 원본과 같은 문턱으로 비교(AAC는 묶음을 앞뒤로 번지게 할 수 있음)
        func clickAt(_ x: [Float]) -> Int { (19_000..<21_000).first { abs(x[$0]) > 0.4 } ?? -1 }
        // 원본과 상관이 가장 큰 어긋남(±2000 표본): 앞부분 처리 확인
        func bestLag(_ x: [Float]) -> Int {
            (-2000...2000).max { l1, l2 in
                func c(_ l: Int) -> Float { stride(from: 5000, to: 70_000, by: 7).reduce(Float(0)) { $0 + orig[$1] * x[$1 + l] } }
                return c(l1) < c(l2)
            }!
        }
        let lag = bestLag(full), click = clickAt(full)
        let src = ProtoPCMSource(url: url, chunk: 12_000, margin: 2_400)
        var chunked = [Float](repeating: 0, count: fx.lengthSamples)
        for c in 0..<((fx.lengthSamples + 11_999) / 12_000) { let d = try src.decode(chunkIndex: c)[0]; for i in 0..<12_000 where c * 12_000 + i < chunked.count { chunked[c * 12_000 + i] = d[i] } }
        var maxDiff: Float = 0, worstAt = 0
        for i in 0..<fx.lengthSamples { let d = abs(chunked[i] - full[i]); if d > maxDiff { maxDiff = d; worstAt = i } }
        print("PROTO AAC lag \(lag) click onset \(click) (orig \(clickAt(orig))) chunked-vs-full maxDiff \(maxDiff) at \(worstAt) firstPTS offsets \(src.firstPTSOffsets)")
        XCTAssertEqual(lag, 0, "AAC 앞부분 처리: 원본과 표본 어긋남 0")
        XCTAssertEqual(click, clickAt(orig), accuracy: 32, "클릭 시작이 원본과 같은 자리(AAC 번짐 여유 32표본)")
        XCTAssertLessThan(maxDiff, 1e-3, "덩어리로 읽어도 한 번에 읽은 것과 같아야 함")
    }
}
