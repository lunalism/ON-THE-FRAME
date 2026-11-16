import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 여러 오디오 레인의 내보내기 믹스(2026-10-11 결함 수정): 소리가 있으면 MP4에 섞인 소리 트랙이 정확히 하나여야 한다.
/// 두 원본을 동시에 울리게 놓고, 디코딩한 MP4의 그 한 트랙에서 두 음높이(440 Hz WAV·1000 Hz AIFF)와 클릭을 각각 찾는다.
/// 기대값은 fixture를 쓸 때 정한 진폭(0.2)·음높이·클릭 표본과 손으로 쓴 배치에서 계산한다(구현의 믹스 설정을 보지 않음).
/// 배치: 영상 V1 파란 판 [0,90). A1 WAV(48 kHz 스테레오) @0 원본 0 길이 60, 다시 @75 원본 0 길이 15. A2 AIFF(44.1 kHz 모노) @20 원본 3 길이 40.
/// 겹침 [20,60), WAV만 [0,20)·[75,90), 두 레인 모두 빈틈 [60,75).
final class AudioMixExportTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var out: URL!
    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        out = ExportEndToEndTests.root.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: out) }

    struct Stereo { var l: [Float] = []; var r: [Float] = [] }
    struct Decoded { let audioTracks: Int; let channels: Int; let pcm: Stereo }

    /// MP4의 소리 트랙 수와, (하나일 때) 그 트랙을 48 kHz 스테레오 float로 채널별로 읽은 값. 여러 트랙을 섞어 읽지 않는다.
    static func decodeMP4(_ url: URL) async throws -> Decoded {
        let a = AVURLAsset(url: url)
        let tracks = try await a.loadTracks(withMediaType: .audio)
        guard tracks.count == 1 else { return Decoded(audioTracks: tracks.count, channels: 0, pcm: Stereo()) }
        let ch = try await tracks[0].load(.formatDescriptions).first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }.map { Int($0.mChannelsPerFrame) } ?? 0
        let r = try AVAssetReader(asset: a)
        let o = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: pcmSettings)
        r.add(o)
        return Decoded(audioTracks: 1, channels: ch, pcm: try read(r, o))
    }
    /// 프리뷰가 재생하는 것: 같은 composition의 모든 소리 트랙을 같은 오디오 믹스로 섞어 읽음(AVPlayerItem과 같은 입력)
    static func decodePreview(_ p: PlannedComposition) async throws -> Stereo {
        let r = try AVAssetReader(asset: p.composition)
        let o = AVAssetReaderAudioMixOutput(audioTracks: try await p.composition.loadTracks(withMediaType: .audio), audioSettings: pcmSettings)
        o.audioMix = p.audioMix
        r.add(o)
        return try read(r, o)
    }
    static let pcmSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                             AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
    static func read(_ r: AVAssetReader, _ o: AVAssetReaderOutput) throws -> Stereo {
        guard r.startReading() else { throw ProbeFailure("audio reader") }
        var s = Stereo()
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            var i = 0
            while i + 1 < n { s.l.append(chunk[i]); s.r.append(chunk[i + 1]); i += 2 }
        }
        guard r.status != .failed else { throw ProbeFailure(r.error?.localizedDescription ?? "audio read") }
        return s
    }
    static func rms(_ x: [Float], from f0: Int, to f1: Int) -> Double {
        let lo = max(0, f0 * 1_600), hi = min(x.count, f1 * 1_600)
        guard hi > lo else { return 0 }
        return (x[lo..<hi].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(hi - lo)).squareRoot()
    }

    struct Setup { let t: Timeline; let media: [UUID: MediaAsset]; let a2: UUID; let sources: [MediaAsset] }
    func setup(gain: Int = 100, muted: Bool = false) async throws -> Setup {
        let plate = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.blue.file))
        let w = try await MediaProbe.inspect(fixtures.appendingPathComponent(AudioFixture.wav.file))
        let f = try await MediaProbe.inspect(fixtures.appendingPathComponent(AudioFixture.aiff.file))
        let a2 = UUID()
        var t = Timeline(clips: [Clip(mediaID: plate.id, start: 0, sourceIn: 0, length: 90)],
                         audioClips: [Clip(mediaID: w.id, start: 0, sourceIn: 0, length: 60, lane: Lane.audioID),
                                      Clip(mediaID: w.id, start: 75, sourceIn: 0, length: 15, lane: Lane.audioID),
                                      Clip(mediaID: f.id, start: 20, sourceIn: 3, length: 40, lane: a2)],
                         lanes: Lane.defaults + [Lane(id: a2, kind: .audio, name: "둘째", muted: muted, volumePercent: gain)])
        for m in [plate, w, f] { t = t.registering(m) }
        XCTAssertTrue(t.isValid)
        XCTAssertEqual(t.clips(inLane: Lane.audioID).map { [$0.start, $0.sourceIn, $0.length] }, [[0, 0, 60], [75, 0, 15]])
        XCTAssertEqual(t.clips(inLane: a2).map { [$0.start, $0.sourceIn, $0.length] }, [[20, 3, 40]])
        XCTAssertEqual(t.durationFrames, 90)
        return Setup(t: t, media: [plate.id: plate, w.id: w, f.id: f], a2: a2, sources: [plate, w, f])
    }

    /// 손 계산 기대값. 클릭: WAV 12345·60000 표본(@0) → 12345·60000, 둘째 WAV @75 원본 [0,0.5 s)의 12345 → 120000 + 12345 = 132345. AIFF 33333/44100 s = 0.755850 s, 원본 시작 3/30 s, @20 →
    /// 20/30 + 0.655850 = 1.322517 s → 63481. 음 진폭(사인 진폭, fixture 0.2): 각 원본을 채널마다 원래 크기 × 레인 음량
    /// (스테레오 WAV는 두 채널에 같은 신호, 모노 AIFF는 두 채널에 같게). 정규화·리미터 없음 → 섞어도 각 음의 진폭은 그대로.
    struct Expect { let wav: Double; let aiff: Double; let onsets: [Int] }
    static func expect(gain: Int, muted: Bool) -> Expect {
        let a = muted ? 0 : AudioFixture.toneAmplitude * Double(gain) / 100
        let on = muted || gain == 0 ? [12_345, 60_000, 132_345] : [12_345, 60_000, 63_481, 132_345]
        return Expect(wav: AudioFixture.toneAmplitude, aiff: a, onsets: on)
    }

    func judge(_ s: Stereo, _ e: Expect, _ label: String, onsetTolerance: Int) {
        func amp(_ x: [Float], _ hz: Double, _ f0: Int, _ f1: Int) -> Double { MultiLaneJudge.toneAmplitude(x, hz: hz, from: f0 * 1_600, to: f1 * 1_600) }
        for (name, x) in [("L", s.l), ("R", s.r)] {
            XCTAssertGreaterThanOrEqual(x.count, 89 * 1_600, "\(label) \(name) length \(x.count)")
            // 동시에: 겹침 [23,57)에서 두 음이 함께
            let wOver = amp(x, 440, 23, 57), fOver = amp(x, 1_000, 23, 57)
            // WAV만 [3,17)·[78,89): AIFF 음 없음. 두 레인 빈틈 [61,74): 무음
            let wOnly = amp(x, 440, 3, 17), fBefore = amp(x, 1_000, 3, 17), gap = Self.rms(x, from: 61, to: 74)
            let wTail = amp(x, 440, 78, 89), fTail = amp(x, 1_000, 78, 89)
            XCTAssertEqual(wTail, e.wav, accuracy: 0.02, "\(label) \(name) WAV after gap")
            XCTAssertLessThan(fTail, 0.005, "\(label) \(name) AIFF after its end")
            print(String(format: "%@ %@: W440 겹침 %.4f 단독 %.4f, F1000 겹침 %.4f 앞 %.5f, 빈틈 rms %.5f", label, name, wOver, wOnly, fOver, fBefore, gap))
            XCTAssertEqual(wOver, e.wav, accuracy: 0.02, "\(label) \(name) WAV in overlap")
            XCTAssertEqual(wOnly, e.wav, accuracy: 0.02, "\(label) \(name) WAV alone")
            if e.aiff == 0 { XCTAssertLessThan(fOver, 0.005, "\(label) \(name) muted AIFF") }
            else { XCTAssertEqual(fOver, e.aiff, accuracy: 0.02, "\(label) \(name) AIFF in overlap") }
            XCTAssertLessThan(fBefore, 0.005, "\(label) \(name) AIFF before its start")
            XCTAssertLessThan(gap, 0.002, "\(label) \(name) gap")
            let on = E2Decoder.onsets(x)
            XCTAssertEqual(on.count, e.onsets.count, "\(label) \(name) onsets \(on) vs \(e.onsets)")
            XCTAssertTrue(zip(on, e.onsets).allSatisfy { abs($0 - $1) <= onsetTolerance }, "\(label) \(name) onsets \(on) vs \(e.onsets)")
        }
    }

    func exportAndJudge(_ st: Setup, gain: Int, muted: Bool, name: String) async throws {
        let plan = try await CompositionPlanner.plan(st.t, media: st.media)
        let e = Self.expect(gain: gain, muted: muted)
        let dest = out.appendingPathComponent("\(name).mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: st.sources) { _ in }
        XCTAssertEqual(outcome, .completed(dest), name)
        let d = try await Self.decodeMP4(dest)
        XCTAssertEqual(d.audioTracks, 1, "\(name): MP4 audio tracks")
        XCTAssertEqual(d.channels, 2, "\(name): channels")
        judge(d.pcm, e, "\(name) export", onsetTolerance: 16)                   // AAC: ±1/3 ms
        judge(try await Self.decodePreview(plan), e, "\(name) preview", onsetTolerance: 4)
    }

    func testUnityGainBothSourcesInOneTrack() async throws {
        let st = try await setup()
        try await exportAndJudge(st, gain: 100, muted: false, name: "unity")
        // 음성 대조: 오디오 믹스를 떼면(결함 당시 상태) 이 판정이 실패해야 한다 — 소리 트랙이 둘
        let plan = try await CompositionPlanner.plan(st.t, media: st.media)
        let bare = PlannedComposition(composition: plan.composition, videoComposition: plan.videoComposition, durationFrames: plan.durationFrames,
                                      settings: plan.settings, hasAudio: plan.hasAudio, audioMix: nil, hasVideo: plan.hasVideo, assets: plan.assets)
        let dest = out.appendingPathComponent("bare.mp4")
        let outcome = await ExportService.export(bare, to: .fromSavePanel(dest), sources: st.sources) { _ in }
        XCTAssertNotEqual(outcome, .completed(dest), "export without mix must not be promoted")
        print("unity without audio mix: \(outcome)")
    }

    func testAdjustedGain() async throws {
        try await exportAndJudge(try await setup(gain: 40), gain: 40, muted: false, name: "gain40")
    }

    func testMutedLane() async throws {
        try await exportAndJudge(try await setup(muted: true), gain: 100, muted: true, name: "muted")
        // 모든 오디오 레인을 음소거하면 소리 트랙이 없다
        var st = try await setup(muted: true)
        st = Setup(t: try st.t.settingLaneAudio(Lane.audioID, muted: true), media: st.media, a2: st.a2, sources: st.sources)
        let plan = try await CompositionPlanner.plan(st.t, media: st.media)
        let dest = out.appendingPathComponent("silent.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: st.sources) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let silentTracks = try await AVURLAsset(url: dest).loadTracks(withMediaType: .audio).count
        XCTAssertEqual(silentTracks, 0)
    }

    func testSaveReopenKeepsMix() async throws {
        let st = try await setup(gain: 40)
        let data = try ProjectFile.encode(st.t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: out.appendingPathComponent("p.ontheframe"))
        let (back, _) = try ProjectFile.decode(data)
        XCTAssertEqual(back.laneInfo(st.a2)?.volumePercent, 40)
        XCTAssertEqual(back.clips(inLane: st.a2).map { [$0.start, $0.sourceIn, $0.length] }, [[20, 3, 40]])
        try await exportAndJudge(Setup(t: back, media: st.media, a2: st.a2, sources: st.sources), gain: 40, muted: false, name: "reopened")
    }

    /// 앱 자체 검사(verify-editfix)와 같은 배치: A1에 TB 원본 소리 [0,90)(440 Hz 0.1), A2에 WAV [0,60)(440 Hz 0.2), 모두 100%.
    /// 같은 음높이라 판정은 위상까지 더한 기대값(둘 다 위상 0 → 0.3)을 쓴다. 음성 대조: 믹스 없이 바로 쓴 파일(소리 트랙 2개,
    /// 첫 트랙만 들림)은 판정이 실패한다.
    func testJudgeSeesBothSamePitchSources() async throws {
        let tb = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TB.mp4"))
        let w = try await MediaProbe.inspect(fixtures.appendingPathComponent(AudioFixture.wav.file))
        let a2 = UUID()
        var t = Timeline().registering(tb).registering(w)
        t = try t.addingLane(.audio, name: "둘째", id: a2, outward: true)
        t = try t.placing(media: tb.id, at: 0, videoLane: Lane.videoID, audioLane: Lane.audioID)
        t = try t.placing(media: w.id, at: 0, videoLane: nil, audioLane: a2)
        typealias J = MultiLaneJudge
        let m = J.Manifest(exportFile: "", durationFrames: 90, lanes: [
            J.LaneRef(kind: "video", name: "V1", muted: false, volumePercent: 100, clips: [.init(file: "otf-TB.mp4", start: 0, sourceIn: 0, length: 90)]),
            J.LaneRef(kind: "audio", name: "A1", muted: false, volumePercent: 100, clips: [.init(file: "otf-TB.mp4", start: 0, sourceIn: 0, length: 90)]),
            J.LaneRef(kind: "audio", name: "A2", muted: false, volumePercent: 100, clips: [.init(file: AudioFixture.wav.file, start: 0, sourceIn: 0, length: 60)])])
        // 손 계산: [0,60) 두 원본 0.1 + 0.2 = 0.3, [60,90) TB만 0.1. 클릭: TB 10·45·70 프레임 × 1600, WAV 12345·60000
        XCTAssertEqual(J.expectedTones(m).map { [$0.from, $0.to] }, [[3, 57], [63, 87]])
        XCTAssertEqual(J.expectedTones(m).map(\.amplitude)[0], 0.3, accuracy: 1e-9)
        XCTAssertEqual(J.expectedTones(m).map(\.amplitude)[1], 0.1, accuracy: 1e-9)
        XCTAssertEqual(J.expectedOnsets(m), [12_345, 16_000, 60_000, 72_000, 112_000])
        let plan = try await CompositionPlanner.plan(t, media: [tb.id: tb, w.id: w])
        let dest = out.appendingPathComponent("same-pitch.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [tb, w]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let r = try await J.judge(dest, m)
        print("same-pitch judge: tracks \(r.audioTracks) tones \(r.tones.map { String(format: "%.4f/%.3f", $0.measured, $0.expected) }) onsets \(r.measuredOnsets)")
        XCTAssertTrue(r.pass, "\(r.tones) \(r.measuredOnsets) tracks \(r.audioTracks)")
        XCTAssertEqual(r.audioTracks, 1)

        // 음성 대조: 같은 composition을 오디오 믹스 없이 AVAssetExportSession으로 바로 쓴다(검증·승격을 거치지 않은 결함 당시 출력)
        let raw = out.appendingPathComponent("raw-nomix.mp4")
        let session = try XCTUnwrap(AVAssetExportSession(asset: plan.composition, presetName: AVAssetExportPreset1920x1080))
        session.videoComposition = plan.videoComposition
        try await session.export(to: raw, as: .mp4)
        let rr = try await J.judge(raw, m)
        print("no-mix judge: tracks \(rr.audioTracks) tones \(rr.tones.map { String(format: "%.4f/%.3f", $0.measured, $0.expected) }) onsets \(rr.measuredOnsets)")
        XCTAssertEqual(rr.audioTracks, 2)
        XCTAssertFalse(rr.pass)
        XCTAssertFalse(rr.tones.allSatisfy(\.pass))   // 트랙 수와 별개로, 첫 트랙만으로는 진폭도 틀린다
    }
}
