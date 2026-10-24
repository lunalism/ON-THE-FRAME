import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 스펙트럼 분석(제품 엔진, SP-0 (3)) — 시제품 분석 검사(SpectrumAnalysisPrototypeTests, OTF_SPECTRUM_PROTO=1)를 기본 실행 검사로 옮김.
/// 기존 생성 fixture(aud-wav48s 440 Hz, aud-steady48s 1000 Hz, aud-aac48s 2500 Hz + 클릭)를 쓰고, 반대 위상 스테레오만 임시 폴더에 작게 만든다.
/// AAC 결과는 이 fixture·이 OS의 인코더·디코더에 한한다.
final class SpectrumAnalysisTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    override func setUp() async throws { try await DevFixtures.ensureAll(in: fixtures) }

    func piece(_ len: Int, audio: ClipAudio = .default, lane: Double = 1, start: Int = 0, sourceIn: Int = 0) -> SpectrumSourcePiece {
        SpectrumSourcePiece(start: start, length: len, sourceIn: sourceIn, audio: audio, laneGain: lane)
    }
    func expectedValue(amplitude a: Double, extraDB: Double = 0) -> Float { Float((20 * log10(a) + extraDB + 60) / 60) }
    /// 창이 읽는 덩어리만 디코딩해 바로 계산(일정 없이)
    func bands(_ src: SpectrumFileSource, frame k: Int, pieces: [SpectrumSourcePiece], settings: SpectrumAnalysisSettings = .init(), fps: Int = 30) async throws -> [Float] {
        var d: [Int: [[Float]]] = [:]
        for c in try SpectrumAnalysis.chunks(frame: k, pieces: pieces, fps: fps, rate: src.sampleRate, settings: settings, chunkSamples: src.chunkSamples) { d[c] = try await src.decodeChunk(c) }
        return try SpectrumAnalysis.bands(frame: k, pieces: pieces, fps: fps, rate: src.sampleRate, channelCount: src.channelCount, chunkSamples: src.chunkSamples, settings: settings) { d[$0] }
    }
    func open(_ name: String, chunk: Int = 8 * 48_000, margin: Int = 48_000) async throws -> SpectrumFileSource {
        try await SpectrumFileSource.open(url: fixtures.appendingPathComponent(name), chunkSamples: chunk, marginSamples: margin)
    }
    var band440: Int { SpectrumAnalysis.bandIndex(ofHz: 440, settings: .init()) }
    var band1000: Int { SpectrumAnalysis.bandIndex(ofHz: 1000, settings: .init()) }

    func testExactFrameSampleMapping() {
        XCTAssertEqual(SpectrumFrameMap.sample(atFrame: 7, fps: 30, rate: 48_000), 11_200)   // 1600/프레임은 48 kHz·30 fps에서만
        XCTAssertEqual(SpectrumFrameMap.sample(atFrame: 7, fps: 30, rate: 44_100), 10_290)   // 1470/프레임
        XCTAssertEqual(SpectrumFrameMap.sample(atFrame: 1, fps: 24, rate: 44_100), 1_838)    // 1837.5 → 절반 올림
        XCTAssertEqual(SpectrumFrameMap.sample(atFrame: 3, fps: 24, rate: 44_100), 5_513)
        XCTAssertEqual(SpectrumFrameMap.sample(atFrame: -1, fps: 24, rate: 44_100), -1_837)  // −1837.5 → 절반 올림(내림 나눗셈)
        XCTAssertEqual(SpectrumFrameMap.frame(containingSample: -1, fps: 30, rate: 48_000), -1)
        for k in [0, 1, 29, 30, 107_999] {
            XCTAssertEqual(SpectrumFrameMap.frame(containingSample: SpectrumFrameMap.sample(atFrame: k, fps: 30, rate: 48_000), fps: 30, rate: 48_000), k)
        }
    }

    func testToneAndSilence() async throws {
        let src = try await open("aud-wav48s.wav")
        XCTAssertEqual(src.channelCount, AudioFixture.wav.channels)
        let v = try await bands(src, frame: 30, pieces: [piece(100)])   // 표본 48000 근처(클릭 12345·60000에서 멂)
        let peak = v.indices.max { v[$0] < v[$1] }!
        XCTAssertEqual(peak, band440)
        XCTAssertEqual(v[peak], expectedValue(amplitude: 0.2), accuracy: 0.02)
        let after = try await bands(src, frame: 90, pieces: [piece(100)])
        XCTAssertEqual(after.max()!, 0, "파일 끝 뒤(표본 144000 > 96000)는 무음")
        let none = try await bands(src, frame: 30, pieces: [])
        XCTAssertEqual(none.max()!, 0, "조각 없음(유효·무음)")
        XCTAssertEqual(none.count, SpectrumAnalysisSettings().bands)
    }

    func testOppositePhaseAndOneSidedStereo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otf-spectrum-\(UUID().uuidString)")
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
        let opp = try await SpectrumFileSource.open(url: try write("opp.wav") { -$0 })
        let e = try await bands(opp, frame: 15, pieces: [piece(30)])
        XCTAssertEqual(e[band1000], expectedValue(amplitude: 0.2), accuracy: 0.02, "에너지 결합: 반대 위상도 한 채널과 같은 크기")
        let one = try await SpectrumFileSource.open(url: try write("left.wav") { _ in 0 })
        let o = try await bands(one, frame: 15, pieces: [piece(30)])
        XCTAssertEqual(o[band1000], expectedValue(amplitude: 0.2, extraDB: -3.0103), accuracy: 0.02, "한쪽만: −3 dB(채널 에너지 평균)")
    }

    func testGainFadeMuteAtSampleStage() async throws {
        let src = try await open("aud-steady48s.wav"), k = band1000
        let base = try await bands(src, frame: 60, pieces: [piece(150)])
        XCTAssertEqual(base[k], expectedValue(amplitude: 0.2), accuracy: 0.02)
        let half = try await bands(src, frame: 60, pieces: [piece(150, audio: ClipAudio(volumePercent: 50))])
        XCTAssertEqual(half[k] - base[k], Float(-6.0206 / 60), accuracy: 0.003, "클립 음량 50%")
        let clipMuted = try await bands(src, frame: 60, pieces: [piece(150, audio: ClipAudio(muted: true))])
        XCTAssertEqual(clipMuted.max()!, 0, "클립 음소거")
        let laneMuted = try await bands(src, frame: 60, pieces: [piece(150, lane: 0)])
        XCTAssertEqual(laneMuted.max()!, 0, "레인 음소거(이득 0)")
        let lane = try await bands(src, frame: 60, pieces: [piece(150, lane: 0.5)])
        XCTAssertEqual(lane[k] - base[k], Float(-6.0206 / 60), accuracy: 0.003, "레인 음량 50%")
        let fade = try await bands(src, frame: 30, pieces: [piece(150, audio: ClipAudio(fadeIn: .init(length: 60)))])
        XCTAssertEqual(fade[k] - base[k], Float(-6.0206 / 60), accuracy: 0.005, "페이드 인 가운데(창 안에서 표본마다 이득)")
        let fadeOut = try await bands(src, frame: 120, pieces: [piece(150, audio: ClipAudio(fadeOut: .init(length: 60)))])
        XCTAssertEqual(fadeOut[k] - base[k], Float(-6.0206 / 60), accuracy: 0.005, "페이드 아웃 가운데")
    }

    /// 조각 이득 = 믹스 규칙(CompositionPlanner.gain(of:lane:atFrame:))과 같은 식 — 클립·레인에서 만든 조각
    func testPieceFromClipUsesMixGainRule() {
        let lane = Lane(id: UUID(), kind: .audio, name: "A", muted: false, volumePercent: 70)
        let clip = Clip(mediaID: UUID(), start: 40, sourceIn: 12, length: 90, lane: lane.id,
                        audio: ClipAudio(volumePercent: 80, fadeIn: .init(length: 20, offset: 5), fadeOut: .init(length: 30)))
        let p = SpectrumSourcePiece(clip: clip, lane: lane)
        XCTAssertEqual([p.start, p.length, p.sourceIn], [40, 90, 12])
        for f in stride(from: 40.0, to: 130.0, by: 0.37) { XCTAssertEqual(p.gain(atFrame: f), CompositionPlanner.gain(of: clip, lane: lane, atFrame: f), accuracy: 1e-12) }
        var muted = lane; muted.muted = true
        XCTAssertEqual(SpectrumSourcePiece(clip: clip, lane: muted).gain(atFrame: 80), 0)
    }

    /// 자른 곳: 창이 이웃한 두 조각(원본이 이어짐)을 지나도 한 조각과 같은 값(비트 단위)
    func testWindowAcrossCutMatchesUncutPiece() async throws {
        let src = try await open("aud-steady48s.wav")
        let whole = try await bands(src, frame: 50, pieces: [piece(100)])
        let cut = try await bands(src, frame: 50, pieces: [piece(50, start: 0, sourceIn: 0), piece(50, start: 50, sourceIn: 50)])
        XCTAssertEqual(whole, cut)
    }

    func testOverlappingPiecesAndInvalidSettingsAreRejected() async throws {
        let src = try await open("aud-steady48s.wav")
        do { _ = try await bands(src, frame: 50, pieces: [piece(60, start: 0), piece(60, start: 40, sourceIn: 40)]); XCTFail("overlap accepted") }
        catch { XCTAssertEqual(error as? SpectrumAnalysisError, .overlappingPieces) }
        // 창 밖에서만 겹치면 이 프레임은 계산한다(겹침 판정은 그 프레임의 창에 드는 조각만)
        XCTAssertNoThrow(try SpectrumAnalysis.chunks(frame: 5, pieces: [piece(20), piece(60, start: 100), piece(60, start: 120, sourceIn: 120)], fps: 30, rate: 48_000,
                                                     settings: .init(), chunkSamples: src.chunkSamples))
        for bad in [SpectrumAnalysisSettings(windowMs: 0), SpectrumAnalysisSettings(bands: 0), SpectrumAnalysisSettings(lowHz: 0), SpectrumAnalysisSettings(highHz: 30_000),
                    SpectrumAnalysisSettings(floorDB: 0)] {
            XCTAssertNotNil(bad.validationError(rate: 48_000))
            do { _ = try await bands(src, frame: 10, pieces: [piece(30)], settings: bad); XCTFail("invalid settings accepted") }
            catch { guard case .invalidSettings = error as? SpectrumAnalysisError else { return XCTFail("\(error)") } }
        }
    }

    func testSeekOrderAndChunkBoundaryDeterminism() async throws {
        let small = try await open("aud-steady48s.wav", chunk: 24_000, margin: 4_800)   // 0.5초 덩어리(경계를 많이 지나게)
        let whole = try await open("aud-steady48s.wav", chunk: 400_000, margin: 0)
        let frames = Array(0..<180), p = [piece(180)]
        var a: [[Float]] = []
        for f in frames { a.append(try await bands(small, frame: f, pieces: p)) }
        var b = [[Float]](repeating: [], count: frames.count)
        for f in frames.shuffled() { b[f] = try await bands(small, frame: f, pieces: p) }
        XCTAssertEqual(a, b, "탐색 순서와 무관하게 같은 값")
        var c: [[Float]] = []
        for f in frames { c.append(try await bands(whole, frame: f, pieces: p)) }
        XCTAssertEqual(a, c, "덩어리 경계를 지나는 창도 한 번에 읽은 것과 같음(WAV)")
        XCTAssertNotEqual(small.identity, whole.identity, "다른 덩어리 격자는 다른 원본 정체(캐시를 나눔)")
    }

    /// AAC(이 fixture·이 OS): 앞부분(인코더 준비 표본) 처리와 덩어리 디코딩 경계. 클릭이 원본 자리에 오고, 덩어리로 읽어도 한 번에 읽은 것과 같다.
    func testAACPrimingAndChunkBoundaries() async throws {
        let fx = AudioFixture.aac, url = fixtures.appendingPathComponent(fx.file)
        let full = try await SpectrumFileSource.open(url: url, chunkSamples: 200_000, marginSamples: 0).decodeRange(0, 200_000, keep: 0 ..< fx.lengthSamples)[0]
        let orig = fx.samples()
        func clickAt(_ x: [Float]) -> Int { (19_000..<21_000).first { abs(x[$0]) > 0.4 } ?? -1 }
        func bestLag(_ x: [Float]) -> Int {
            (-2000...2000).max { l1, l2 in
                func c(_ l: Int) -> Float { stride(from: 5000, to: 70_000, by: 7).reduce(Float(0)) { $0 + orig[$1] * x[$1 + l] } }
                return c(l1) < c(l2)
            }!
        }
        XCTAssertEqual(bestLag(full), 0, "AAC 앞부분 처리: 원본과 표본 어긋남 0")
        XCTAssertEqual(clickAt(full), clickAt(orig), accuracy: 32, "클릭 시작이 원본과 같은 자리(AAC 번짐 여유 32표본)")
        let src = try await SpectrumFileSource.open(url: url, chunkSamples: 12_000, marginSamples: 2_400)
        var chunked = [Float](repeating: 0, count: fx.lengthSamples)
        for c in 0..<((fx.lengthSamples + 11_999) / 12_000) {
            let d = try await src.decodeChunk(c)[0]
            for i in 0..<12_000 where c * 12_000 + i < chunked.count { chunked[c * 12_000 + i] = d[i] }
        }
        let maxDiff = zip(chunked, full).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(maxDiff, 1e-3, "덩어리로 읽어도 한 번에 읽은 것과 같아야 함")
    }

    /// 파일 끝을 넘는 덩어리(이 fixture·이 OS): 리더가 실패하지 않고 0을 준다 — 끝 뒤 프레임은 무음
    func testChunksPastEndOfFileAreSilent() async throws {
        let wav = try await open("aud-wav48s.wav", chunk: 24_000, margin: 4_800)   // 96000표본: 덩어리 3이 끝, 4부터 밖
        let last = try await wav.decodeChunk(3)
        XCTAssertGreaterThan(last[0].map(abs).max()!, 0.1)
        for c in [4, 5, 1000] { let d = try await wav.decodeChunk(c); XCTAssertEqual(d.count, 2); XCTAssertEqual(d.flatMap { $0 }.map(abs).max()!, 0) }
        let aac = try await open("aud-aac48s.m4a", chunk: 24_000, margin: 4_800)   // 76800표본
        for c in [4, 50] { let d = try await aac.decodeChunk(c); XCTAssertEqual(d.flatMap { $0 }.map(abs).max()!, 0) }
    }

    /// 모노·스테레오만(제품 가져오기 규칙과 같음): 4채널 fixture는 열 때 거부
    func testMoreThanTwoChannelsAreRejected() async throws {
        do { _ = try await open("reject-4ch.wav"); XCTFail("4ch accepted") }
        catch { XCTAssertEqual(error as? SpectrumAnalysisError, .unsupportedChannelCount(4)) }
    }

    /// 44.1 kHz ALAC → 48 kHz 분석(리더 재표본화, 이 fixture·이 OS만): 700 Hz 밴드·크기, 같은 덩어리 재디코딩은 같은 값.
    /// 덩어리로 읽은 것 = 한 번에 읽은 것(이 fixture·이 OS에서 관찰 차이 0 — 다른 파일·인코더·표본율은 확인 안 함, 문서 §11.1).
    func testResampled44kALACToneAndRepeatDeterminism() async throws {
        let fx = AudioFixture.alac
        let src = try await open(fx.file, chunk: 12_000, margin: 2_400)
        XCTAssertEqual(src.sampleRate, 48_000)
        let k = SpectrumAnalysis.bandIndex(ofHz: fx.toneHz, settings: .init())
        let v = try await bands(src, frame: 15, pieces: [piece(30)])
        XCTAssertEqual(v.indices.max { v[$0] < v[$1] }!, k)
        XCTAssertEqual(v[k], expectedValue(amplitude: AudioFixture.toneAmplitude), accuracy: 0.02)
        let a = try await src.decodeChunk(2), b = try await src.decodeChunk(2)
        XCTAssertEqual(a, b, "같은 덩어리 = 같은 표본")
        let whole = try await SpectrumFileSource.open(url: fixtures.appendingPathComponent(fx.file), chunkSamples: 96_000, marginSamples: 0).decodeChunk(0)[0]
        var chunked = [Float](repeating: 0, count: 48_000)
        for c in 0..<4 { let d = try await src.decodeChunk(c)[0]; for i in 0..<12_000 { chunked[c * 12_000 + i] = d[i] } }
        let diff = (0..<47_000).map { abs(chunked[$0] - whole[$0]) }
        let worst = diff.indices.max { diff[$0] < diff[$1] }!
        XCTAssertLessThanOrEqual(diff[worst], 1e-6, "이 fixture·이 OS에서 덩어리 경계가 재표본화 값을 바꾸지 않음(2026-10-24 관찰 0)")
        print("SPECTRUM alac441 resampled: chunked-vs-whole max diff \(diff[worst]) at \(worst) (chunk 12000), mean \(diff.reduce(0, +) / Float(diff.count)), tone band \(v[k])")
    }
}
