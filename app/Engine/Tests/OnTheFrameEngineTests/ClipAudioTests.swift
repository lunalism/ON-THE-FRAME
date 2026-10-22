import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 소리 클립 음량·음소거·페이드(2026-10-11). 기대값은 구현 함수를 쓰지 않고 손으로 쓴 구간식에서 계산한다
/// (선형 진폭 페이드: 페이드 인 F 프레임이면 클립 시작에서 t 프레임 지난 곳 t/F, 페이드 아웃 G 프레임이면 끝까지 r 프레임 남은 곳 r/G).
/// 소리 판정은 클릭 없는 1000 Hz 사인(진폭 0.2) WAV를 원본 위치 = 타임라인 위치로 놓아 위상이 이어지게 하고,
/// 48표본(1 ms = 한 주기) 창의 사인 진폭으로 잰다.
final class ClipAudioTests: XCTestCase {
    let m = UUID()
    func base(_ len: Int = 90, audio: ClipAudio? = nil, id: UUID = UUID()) -> (Timeline, UUID) {
        (Timeline(audioClips: [Clip(id: id, mediaID: m, start: 0, sourceIn: 0, length: len, lane: Lane.audioID, audio: audio)], mediaFrames: [m: 1_000],
                  mediaHasAudio: [m: true]), id)
    }
    func gain(_ t: Timeline, atFrame f: Double, lane: UUID = Lane.audioID) -> Double {
        let l = t.laneInfo(lane)!
        return t.clips(inLane: lane).map { CompositionPlanner.gain(of: $0, lane: l, atFrame: f) }.reduce(0, +)
    }

    // MARK: 모델

    func testDefaultsAndPiecesAreIndependent() throws {
        let (t0, id) = base()
        XCTAssertEqual(t0.audioClips[0].effectiveAudio, ClipAudio(volumePercent: 100, muted: false, fadeIn: .none, fadeOut: .none))
        let r = UUID()
        let t1 = try t0.splitting(clip: id, atFrame: 45, newIDs: (UUID(), r))
        let left = t1.audioClips.first { $0.id != r }!.id
        let t2 = try t1.settingClipAudio(clip: r, volumePercent: 40)
        XCTAssertEqual(t2.clip(r)?.effectiveAudio.volumePercent, 40)
        XCTAssertEqual(t2.clip(left), t1.clip(left), "다른 조각은 그대로")
        let t3 = try t2.settingClipAudio(clip: left, muted: true)
        XCTAssertEqual(t3.clip(r), t2.clip(r))
        XCTAssertEqual(gain(t3, atFrame: 10), 0); XCTAssertEqual(gain(t3, atFrame: 60), 0.4, accuracy: 1e-12)
        XCTAssertEqual(t3.lanes, t0.lanes, "레인 음량·음소거는 그대로")
        XCTAssertThrowsError(try t3.settingClipAudio(clip: r, volumePercent: 101)) { XCTAssertEqual($0 as? EditError, .volumeRange) }
    }

    func testCombinedGainAndBothMuteScopes() throws {
        var (t, id) = base()
        t = try t.settingLaneAudio(Lane.audioID, volumePercent: 80)
        t = try t.settingClipAudio(clip: id, volumePercent: 50, fadeInFrames: 30, fadeOutFrames: 20)
        // 손 계산: 0.8 × 0.5 = 0.4. 페이드 인 [0,30), 페이드 아웃 [70,90)
        for (f, e) in [(0.0, 0.0), (15, 0.2), (29.25, 0.4 * 29.25 / 30), (30, 0.4), (50, 0.4), (70, 0.4), (80, 0.2), (89.5, 0.4 * 0.5 / 20), (90, 0)] {
            XCTAssertEqual(gain(t, atFrame: f), e, accuracy: 1e-12, "frame \(f)")
        }
        XCTAssertEqual(gain(try t.settingClipAudio(clip: id, muted: true), atFrame: 50), 0)
        XCTAssertEqual(gain(try t.settingLaneAudio(Lane.audioID, muted: true), atFrame: 50), 0)
        // 두 범위는 따로: 레인 음소거를 풀어도 클립 음소거는 남는다
        let both = try t.settingClipAudio(clip: id, muted: true).settingLaneAudio(Lane.audioID, muted: true).settingLaneAudio(Lane.audioID, muted: false)
        XCTAssertEqual(gain(both, atFrame: 50), 0)
        XCTAssertEqual(both.clip(id)?.effectiveAudio.muted, true)
    }

    /// 자르기: 페이드 안·밖 어디서 잘라도 두 조각의 소리 모양이 원래 모양과 같다(새 페이드 없음, 페이드 복사 없음)
    func testSplitPreservesEnvelopeInsideAndOutsideFades() throws {
        let L = 90, F = 40, G = 30
        func hand(_ f: Double) -> Double { 0.6 * min(1, f / Double(F)) * min(1, (Double(L) - f) / Double(G)) }
        var (t0, id) = base(L)
        t0 = try t0.settingClipAudio(clip: id, volumePercent: 60, fadeInFrames: F, fadeOutFrames: G)
        for k in 1..<L {
            let r = UUID()
            let t = try t0.splitting(clip: id, atFrame: k, newIDs: (UUID(), r))
            XCTAssertTrue(t.isValid, "split \(k)")
            for q in 0..<(L * 4) { let f = Double(q) / 4; XCTAssertEqual(gain(t, atFrame: f), hand(f), accuracy: 1e-12, "split \(k) frame \(f)") }
            let left = t.audioClips.first { $0.id != r }!.effectiveAudio, right = t.clip(r)!.effectiveAudio
            if k >= F { XCTAssertEqual(right.fadeIn, .none, "split \(k) after fade-in: no new fade-in") }
            if k <= L - G { XCTAssertEqual(left.fadeOut, .none, "split \(k) before fade-out: no new fade-out") }
            XCTAssertEqual(left.volumePercent, 60); XCTAssertEqual(right.volumePercent, 60)
        }
        // 페이드 안에서 두 번 자르기
        let r1 = UUID(), r2 = UUID(), mid = UUID()
        let t2 = try t0.splitting(clip: id, atFrame: 10, newIDs: (UUID(), r1)).splitting(clip: r1, atFrame: 25, newIDs: (UUID(), r2))
            .splitting(clip: r2, atFrame: 80, newIDs: (mid, UUID()))
        for q in 0..<(L * 4) { let f = Double(q) / 4; XCTAssertEqual(gain(t2, atFrame: f), hand(f), accuracy: 1e-12, "3 splits frame \(f)") }
        XCTAssertEqual(t2.clip(mid)?.effectiveAudio.fadeIn, ClipAudio.Fade(length: 40, offset: 25))
    }

    /// 트림: 페이드는 자기 가장자리에 붙어 따라가고 길이는 그대로, 짧아져 겹치면 페이드 인을 두고 페이드 아웃을 남은 길이로 줄인다
    func testTrimKeepsFadesAttachedAndClamps() throws {
        var (t, id) = base(90)
        t = try t.settingClipAudio(clip: id, fadeInFrames: 40, fadeOutFrames: 30)
        let a = try t.trimmingStart(clip: id, by: 10)
        XCTAssertEqual(a.clip(id)?.length, 80)
        XCTAssertEqual(a.clip(id)?.effectiveAudio.fadeIn, .init(length: 40)); XCTAssertEqual(a.clip(id)?.effectiveAudio.fadeOut, .init(length: 30))
        let b = try t.trimmingEnd(clip: id, by: -40)   // 길이 50: 페이드 인 40, 페이드 아웃 10
        XCTAssertEqual(b.clip(id)?.effectiveAudio.fadeIn, .init(length: 40)); XCTAssertEqual(b.clip(id)?.effectiveAudio.fadeOut, .init(length: 10))
        XCTAssertTrue(b.isValid)
        let c = try t.trimmingEnd(clip: id, by: -85)   // 길이 5: 페이드 인이 클립 전체(보이는 5), 페이드 아웃 없음
        XCTAssertEqual(c.clip(id)?.effectiveAudio.fadeOut, ClipAudio.Fade.none)
        XCTAssertEqual(gain(c, atFrame: 4), 4.0 / 40, accuracy: 1e-12)
        // 페이드 안에서 자른 왼쪽 조각을 다시 늘리면 원래 경사가 이어진다
        let r = UUID()
        let s = try t.splitting(clip: id, atFrame: 20, newIDs: (UUID(), r))
        let l = s.audioClips.first { $0.id != r }!.id
        let s2 = try s.lifting(clip: r).trimmingEnd(clip: l, by: 10)
        XCTAssertEqual(gain(s2, atFrame: 25), 25.0 / 40, accuracy: 1e-12)
        // 입력 제한: 다른 쪽 페이드와 겹치지 않게 줄인다
        let d = try t.settingClipAudio(clip: id, fadeInFrames: 100)
        XCTAssertEqual(d.clip(id)?.effectiveAudio.fadeIn, .init(length: 60))
        XCTAssertEqual(try d.settingClipAudio(clip: id, fadeOutFrames: 50).clip(id)?.effectiveAudio.fadeOut, .init(length: 30))
        XCTAssertEqual(try d.settingClipAudio(clip: id, fadeInFrames: 0).clip(id)?.effectiveAudio.fadeIn, ClipAudio.Fade.none)
    }

    func testLinkedPairMoveUndoRedo() throws {
        let v = UUID(), a = UUID(), other = UUID(), link = UUID()
        let t0 = Timeline(clips: [Clip(id: v, mediaID: m, start: 0, sourceIn: 0, length: 60, link: link)],
                          audioClips: [Clip(id: a, mediaID: m, start: 0, sourceIn: 0, length: 60, link: link),
                                       Clip(id: other, mediaID: m, start: 70, sourceIn: 0, length: 20)],
                          mediaFrames: [m: 1_000], mediaHasAudio: [m: true])
        XCTAssertEqual(t0.audioTarget(of: v), a)
        let t1 = try t0.settingClipAudio(clip: v, volumePercent: 30, fadeOutFrames: 12)
        XCTAssertEqual(t1.clip(a)?.effectiveAudio, ClipAudio(volumePercent: 30, fadeOut: .init(length: 12)))
        XCTAssertNil(t1.clip(v)?.audio); XCTAssertEqual(t1.clip(other), t0.clip(other))
        let moved = try t1.relocating(clip: v, toStart: 100)
        XCTAssertEqual(moved.clip(a)?.audio, t1.clip(a)?.audio)
        XCTAssertEqual(moved.clip(a)?.start, 100)
        var h = EditHistory(t0)
        h.apply(t1, focus: v); h.apply(moved, focus: v)
        h.undo(); XCTAssertEqual(h.timeline, t1)
        h.undo(); XCTAssertEqual(h.timeline, t0)
        h.redo(); h.redo(); XCTAssertEqual(h.timeline, moved)
        // 소리 없는 영상 클립만이면 거부
        let lone = Timeline(clips: [Clip(id: v, mediaID: m, start: 0, sourceIn: 0, length: 10)], mediaFrames: [m: 100])
        XCTAssertThrowsError(try lone.settingClipAudio(clip: v, volumePercent: 10)) { XCTAssertEqual($0 as? EditError, .audioNotAudioClip) }
    }

    func testProjectRoundTripAndOlderFiles() throws {
        let ref = MediaRef(id: m, name: "s.wav", path: "/tmp/s.wav", frameCount: 1_000, hasAudio: true, size: 1, modifiedNs: 1, codec: "lpcm", width: 0, height: 0,
                           hasVideo: false, sampleRate: 48_000, sampleCount: 1, channels: 2)
        let a = UUID(), b = UUID()
        var t = Timeline(audioClips: [Clip(id: a, mediaID: m, start: 0, sourceIn: 0, length: 90, lane: Lane.audioID),
                                      Clip(id: b, mediaID: m, start: 90, sourceIn: 90, length: 30, lane: Lane.audioID)], media: [ref],
                         mediaFrames: [m: 1_000], mediaHasAudio: [m: true], mediaHasVideo: [m: false])
        t = try t.settingLaneAudio(Lane.audioID, volumePercent: 70)
        let r = UUID()
        t = try t.settingClipAudio(clip: a, volumePercent: 55, muted: true, fadeInFrames: 40).splitting(clip: a, atFrame: 15, newIDs: (UUID(), r))
        let data = try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        let (back, doc) = try ProjectFile.decode(data)
        // 자막이 없는 프로젝트는 형식 5로 쓴다(2026-10-22 형식 6 도입 뒤에도, 이전 앱 호환). 읽을 수 있는 최신 형식은 6이다.
        XCTAssertEqual(doc.version, 5); XCTAssertEqual(ProjectFile.subtitleFreeVersion, 5); XCTAssertEqual(ProjectFile.currentVersion, 6)
        XCTAssertEqual(back, t)
        XCTAssertEqual(back.clip(r)?.effectiveAudio, ClipAudio(volumePercent: 55, muted: true, fadeIn: .init(length: 40, offset: 15)))
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json.components(separatedBy: "\"audio\" :").count - 1, 2, "기본값 클립(b)에는 audio를 쓰지 않는다")
        // 형식 4 파일(클립 audio 없음): 기본 클립 값, 레인 음량 그대로
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["version"] = 4
        obj["audioClips"] = (obj["audioClips"] as! [[String: Any]]).map { var c = $0; c.removeValue(forKey: "audio"); return c }
        let (old, _) = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj))
        XCTAssertTrue(old.audioClips.allSatisfy { $0.audio == nil })
        XCTAssertEqual(old.laneInfo(Lane.audioID)?.volumePercent, 70)
        // 잘못된 값: 겹치는 페이드·영상 클립의 audio
        obj["version"] = 5
        obj["audioClips"] = [[ "id": UUID().uuidString, "mediaID": m.uuidString, "start": 0, "sourceIn": 0, "length": 10, "lane": Lane.audioID.uuidString,
                               "audio": ["volumePercent": 100, "muted": false, "fadeIn": ["length": 6, "offset": 0], "fadeOut": ["length": 6, "offset": 0]]] as [String: Any]]
        XCTAssertThrowsError(try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj)))
    }

    /// 이전 파일(모든 클립 기본값): 트랙 나눔 없음, 음량은 레인 음량 그대로(이전 구성과 같음). 끊어지는 맞닿은 클립만 트랙을 번갈아 쓴다.
    func testDefaultClipsKeepPreviousMixStructure() throws {
        let lane = Lane(id: Lane.audioID, kind: .audio, name: "A1", volumePercent: 70)
        let cs = [Clip(mediaID: m, start: 0, sourceIn: 0, length: 30), Clip(mediaID: m, start: 30, sourceIn: 30, length: 30), Clip(mediaID: m, start: 80, sourceIn: 0, length: 10)]
        XCTAssertEqual(CompositionPlanner.volumeTracks(cs, lane: lane).count, 1)
        XCTAssertTrue(CompositionPlanner.volumeRamps(cs, lane: lane).allSatisfy { $0.from == 0.7 && $0.to == 0.7 })
        let changed = [cs[0], cs[1].with(audio: .some(ClipAudio(volumePercent: 50))), cs[2]]
        XCTAssertEqual(CompositionPlanner.volumeTracks(changed, lane: lane).map { $0.map(\.start) }, [[0], [30, 80]])   // 80은 맞닿지 않아 현재 트랙에 남는다(무음 구간에서 값을 옮김)
    }

    // MARK: 프리뷰·내보내기 소리

    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    func steady() async throws -> MediaAsset {
        try await DevFixtures.ensureAll(in: fixtures)
        return try await MediaProbe.inspect(fixtures.appendingPathComponent(AudioFixture.steady.file))
    }
    static func amp(_ x: [Float], at n: Int, half: Int = 24) -> Double { MultiLaneJudge.toneAmplitude(x, hz: 1_000, from: n - half, to: n + half) }

    /// 배치(원본 위치 = 타임라인 위치):
    /// - A1(레인 80%): [0,90) 페이드 인 30을 45에서 자름 → 오른쪽 조각 [45,90) 음량 50%·페이드 아웃 15.
    /// - A2(레인 음소거): [0,60) — 들리지 않아야 한다.
    /// - A3(레인 50%): [100,160) 클립 음량 60%, [160,180) 클립 음소거.
    /// 손 계산 진폭(0.2 × 배율): [0,30) 0.16·f/30, [30,45) 0.16, [45,75) 0.08, [75,90) 0.08·(90−f)/15, [90,100) 0, [100,160) 0.06, [160,180) 0.
    func expected(_ f: Double) -> Double {
        switch f {
        case ..<30: return 0.16 * f / 30
        case ..<45: return 0.16
        case ..<75: return 0.08
        case ..<90: return 0.08 * (90 - f) / 15
        case 100..<160: return 0.06
        default: return 0
        }
    }
    func layout(_ s: MediaAsset) throws -> Timeline {
        let x = UUID(), a2 = UUID(), a3 = UUID(), right = UUID(), m3 = UUID()
        var t = Timeline(audioClips: [Clip(id: x, mediaID: s.id, start: 0, sourceIn: 0, length: 90, lane: Lane.audioID),
                                      Clip(mediaID: s.id, start: 0, sourceIn: 0, length: 60, lane: a2),
                                      Clip(mediaID: s.id, start: 100, sourceIn: 100, length: 60, lane: a3, audio: ClipAudio(volumePercent: 60)),
                                      Clip(id: m3, mediaID: s.id, start: 160, sourceIn: 160, length: 20, lane: a3)],
                         lanes: [Lane.defaults[0], Lane(id: Lane.audioID, kind: .audio, name: "A1", volumePercent: 80),
                                 Lane(id: a2, kind: .audio, name: "A2", muted: true), Lane(id: a3, kind: .audio, name: "A3", volumePercent: 50)]).registering(s)
        t = try t.settingClipAudio(clip: x, fadeInFrames: 30).splitting(clip: x, atFrame: 45, newIDs: (UUID(), right))
        t = try t.settingClipAudio(clip: right, volumePercent: 50, fadeOutFrames: 15).settingClipAudio(clip: m3, muted: true)
        XCTAssertTrue(t.isValid)
        return t
    }
    func judge(_ x: [Float], _ label: String, half: Int, tol: Double, avoid: Int) {
        XCTAssertGreaterThanOrEqual(x.count, 180 * 1_600 - 2, label)
        var worst = 0.0
        for n in stride(from: half, to: 180 * 1_600 - half, by: 200) {
            // 경계(계단) 근처 창은 건너뛴다(그 자리는 아래 표본 단위 검사가 본다)
            if [0, 45, 90, 100, 160].contains(where: { abs(n - $0 * 1_600) < avoid }) { continue }
            let e = 0.2 * expected(Double(n) / 1_600) / 0.2
            let d = abs(Self.amp(x, at: n, half: half) - e)
            worst = max(worst, d)
            if d > tol { XCTFail(String(format: "%@ sample %d (frame %.2f): %.5f vs %.5f", label, n, Double(n) / 1_600, Self.amp(x, at: n, half: half), e)); return }
        }
        print(String(format: "%@: worst envelope error %.5f", label, worst))
    }

    func testPreviewAndExportFollowHandEnvelope() async throws {
        let s = try await steady()
        let t = try layout(s)
        let plan = try await CompositionPlanner.plan(t, media: [s.id: s])
        // 프리뷰 입력(같은 composition·오디오 믹스, 무손실 PCM)
        let pv = try await AudioMixExportTests.decodePreview(plan)
        for (name, x) in [("preview L", pv.l), ("preview R", pv.r)] { judge(x, name, half: 24, tol: 0.002, avoid: 48) }
        // 자른 곳(45프레임 = 72000표본): 앞 96표본은 0.16, 바로 다음 표본부터 0.08 이하(표본 단위 계단, 경사·틈 없음)
        let before = pv.l[(72_000 - 96)..<72_000].map { abs($0) }.max()!, after = pv.l[72_000..<(72_000 + 96)].map { abs($0) }.max()!
        print("cut 72000: before peak \(before) after peak \(after)")
        XCTAssertEqual(Double(before), 0.16, accuracy: 0.002); XCTAssertEqual(Double(after), 0.08, accuracy: 0.002)
        XCTAssertEqual(Self.amp(pv.l, at: 72_000 - 24), 0.16, accuracy: 0.002); XCTAssertEqual(Self.amp(pv.l, at: 72_000 + 24), 0.08, accuracy: 0.002)
        // 끝(90프레임 = 144000): 페이드 아웃이 0으로 끝나 그 뒤 무음, 음소거 클립 [160,180)·음소거 레인도 무음
        XCTAssertLessThan(pv.l[144_000..<160_000].map { abs($0) }.max()!, 0.0005)
        XCTAssertLessThan(pv.l[(160 * 1_600)..<(180 * 1_600 - 10)].map { abs($0) }.max()!, 0.0005)
        // 내보내기: 섞인 소리 트랙 하나, AAC라 넓은 창·허용 오차
        let out = ExportEndToEndTests.root.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let dest = out.appendingPathComponent("clipaudio.mp4")
        // 영상이 없는 타임라인은 내보낼 수 없으므로 검정 판 영상 레인을 더한다(소리 판정과 무관)
        let plate = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.blue.file))
        let tv = try t.registering(plate).placing(media: plate.id, at: 0, videoLane: Lane.videoID, audioLane: nil)
            .placing(media: plate.id, at: 90, videoLane: Lane.videoID, audioLane: nil)
        let vplan = try await CompositionPlanner.plan(tv, media: [s.id: s, plate.id: plate])
        let outcome = await ExportService.export(vplan, to: .fromSavePanel(dest), sources: [s, plate]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let d = try await AudioMixExportTests.decodeMP4(dest)
        XCTAssertEqual(d.audioTracks, 1)
        for (name, x) in [("export L", d.pcm.l), ("export R", d.pcm.r)] { judge(x, name, half: 240, tol: 0.006, avoid: 600) }
        XCTAssertEqual(Self.amp(d.pcm.l, at: 72_000 - 600, half: 240), 0.16, accuracy: 0.006)
        XCTAssertEqual(Self.amp(d.pcm.l, at: 72_000 + 600, half: 240), 0.08, accuracy: 0.006)
        // 저장·다시 열기 뒤 같은 소리(같은 오디오 믹스 경사)
        let (back, _) = try ProjectFile.decode(try ProjectFile.encode(tv, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil))
        let bplan = try await CompositionPlanner.plan(back, media: [s.id: s, plate.id: plate])
        // 저장·다시 열기에 관계된 값은 정확히 같아야 한다(타임라인, 레인별 음량 경사·소리 트랙 나눔, 계획의 트랙·구간·믹스 경사).
        XCTAssertEqual(back, tv, "reopened timeline identical")
        for lane in tv.lanes where lane.kind == .audio {
            let bl = back.laneInfo(lane.id)
            XCTAssertEqual(bl, lane, "reopened lane \(lane.name)")
            XCTAssertEqual(bl.map { CompositionPlanner.volumeRamps(back.clips(inLane: lane.id), lane: $0) },
                           CompositionPlanner.volumeRamps(tv.clips(inLane: lane.id), lane: lane), "reopened ramps \(lane.name)")
            XCTAssertEqual(bl.map { CompositionPlanner.volumeTracks(back.clips(inLane: lane.id), lane: $0) },
                           CompositionPlanner.volumeTracks(tv.clips(inLane: lane.id), lane: lane), "reopened audio tracks \(lane.name)")
        }
        let vsig = try await Self.planSignature(vplan), bsig = try await Self.planSignature(bplan)
        XCTAssertFalse(vsig.isEmpty)
        XCTAssertEqual(bsig, vsig, "reopened plan identical")
        // 소리: 따로 읽은 AVFoundation 믹스 출력은 같은 계획에서도 마지막 자리(최대 2⁻²⁶)가 갈린다(app/README §33, P-012 채택).
        // 비트 단위 대신 두 채널 모두 표본 수 같음·유한값·표본마다 차이 ≤ 1×10⁻⁶.
        let bp = try await AudioMixExportTests.decodePreview(bplan)
        let vp = try await AudioMixExportTests.decodePreview(vplan)
        if let m = Self.outputMismatch(bp, vp) { XCTFail("reopened mix: \(m)") }
    }

    /// 다시 열기 비교의 소리 허용 오차(P-012, 2026-10-12): 관찰한 최대 차이 1.49×10⁻⁸의 약 67배, 이 테스트의 가장 작은 회귀(한 표본 어긋남 ≈ 0.02,
    /// 음량 1% ≈ 1.6×10⁻³, 페이드 한 프레임 ≈ 0.005)보다 수천 배 작다. 다른 소리 단언에는 쓰지 않는다.
    static let reopenTolerance: Float = 1e-6
    /// 두 출력의 표본 비교: 채널마다 표본 수가 같고, 유한값이고, 표본마다 |a − b| ≤ tol. 맞으면 nil, 아니면 채널·첫 위치·최대 오차를 적은 설명.
    static func outputMismatch(_ a: AudioMixExportTests.Stereo, _ b: AudioMixExportTests.Stereo, tolerance tol: Float = reopenTolerance) -> String? {
        var problems: [String] = []
        for (name, x, y) in [("L", a.l, b.l), ("R", a.r, b.r)] {
            guard x.count == y.count else { problems.append("\(name) sample count \(x.count) vs \(y.count)"); continue }
            if let i = x.indices.first(where: { !x[$0].isFinite || !y[$0].isFinite }) { problems.append("\(name) non-finite at \(i): \(x[i]) vs \(y[i])"); continue }
            var worst: Float = 0, worstAt = -1, firstBad = -1, bad = 0
            for i in x.indices {
                let e = abs(x[i] - y[i])
                if e > worst { worst = e; worstAt = i }
                if e > tol { bad += 1; if firstBad < 0 { firstBad = i } }
            }
            if bad > 0 { problems.append("\(name) \(bad) samples over \(tol), first at \(firstBad), max error \(worst) at \(worstAt)") }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }
    /// 계획의 소리 구성(저장·다시 열기에 관계된 값만): 소리 트랙 차례마다 구간(타임라인 시각·길이·원본 시각, 원본 파일 이름, 빈 구간)과
    /// 그 트랙의 믹스 음량 경사(시각·길이·시작·끝 음량의 비트). 트랙 ID 같은 프레임워크 값은 차례로 바꿔 쓴다.
    static func planSignature(_ p: PlannedComposition) async throws -> [String] {
        func t(_ x: CMTime) -> String { "\(x.value)/\(x.timescale)" }
        let tracks = try await p.composition.loadTracks(withMediaType: .audio)
        var out: [String] = []
        for (k, tr) in tracks.enumerated() {
            for sg in try await tr.load(.segments) {
                let m = sg.timeMapping
                out.append("track\(k) \(sg.isEmpty ? "empty" : ((sg as? AVCompositionTrackSegment)?.sourceURL?.lastPathComponent ?? "?")) at \(t(m.target.start))+\(t(m.target.duration)) from \(t(m.source.start))")
            }
            guard let ip = p.audioMix?.inputParameters.first(where: { $0.trackID == tr.trackID }) else { out.append("track\(k) no mix"); continue }
            var at = CMTime.zero
            let end = p.composition.duration
            while at < end {
                var a: Float = 0, b: Float = 0, r = CMTimeRange.invalid
                if ip.getVolumeRamp(for: at, startVolume: &a, endVolume: &b, timeRange: &r), r.isValid, r.end > at {
                    out.append("track\(k) ramp \(t(r.start))+\(t(r.duration)) \(a.bitPattern)->\(b.bitPattern)")
                    at = r.end
                } else { at = at + CMTime(value: 1, timescale: 30) }
            }
        }
        return out
    }

    /// 다시 열기 비교(위 테스트)가 실제 회귀를 놓치지 않는지(P-012): 손댄 계획·출력은 모두 거부되어야 한다.
    /// - 출력: 한 표본 어긋남, 오른쪽 채널만 1% 음량
    /// - 타임라인: 레인 음량 1%(80 → 79), 페이드 아웃 한 프레임(15 → 16), 클립 한 프레임 늦게
    /// - 저장 파일: 레인 음량 값을 바꾼 프로젝트 파일 → 타임라인·계획 비교가 거부
    func testReopenComparisonRejectsMutations() async throws {
        let s = try await steady()
        let t = try layout(s)
        let media = [s.id: s]
        let plan = try await CompositionPlanner.plan(t, media: media)
        let ref = try await AudioMixExportTests.decodePreview(plan)
        let sig = try await Self.planSignature(plan)
        // 같은 계획을 다시 읽은 출력은 받아들인다(허용 오차 안)
        let again = try await AudioMixExportTests.decodePreview(plan)
        XCTAssertNil(Self.outputMismatch(again, ref), "same plan accepted")
        // 출력 손대기
        var shifted = ref
        shifted.l = [0] + ref.l.dropLast(); shifted.r = [0] + ref.r.dropLast()
        XCTAssertNotNil(Self.outputMismatch(shifted, ref), "one-sample shift rejected")
        var rGain = ref
        rGain.r = ref.r.map { $0 * 0.99 }
        let rMsg = Self.outputMismatch(rGain, ref)
        XCTAssertTrue(rMsg?.hasPrefix("R ") == true, "right-only 1% gain rejected on R: \(rMsg ?? "nil")")
        var shorter = ref
        shorter.r.removeLast()
        XCTAssertNotNil(Self.outputMismatch(shorter, ref), "sample count mismatch rejected")
        var nan = ref
        nan.l[1_000] = .nan
        XCTAssertTrue(Self.outputMismatch(nan, ref)?.contains("non-finite") == true, "non-finite rejected")
        // 타임라인 손대기: 계획 비교와 소리 비교가 모두 거부
        let right = t.audioClips.first { $0.lane == Lane.audioID && $0.start == 45 }!.id
        var lanes = t.lanes
        let a1 = lanes.firstIndex { $0.id == Lane.audioID }!
        lanes[a1].volumePercent = 79
        let gain79 = Timeline(clips: t.clips, audioClips: t.audioClips, lanes: lanes).registering(s)
        let fade16 = try t.settingClipAudio(clip: right, fadeOutFrames: 16)
        let late = try t.relocating(clip: right, toStart: 46)
        XCTAssertTrue(gain79.isValid)
        for (name, m) in [("lane gain 1%", gain79), ("fade-out one frame", fade16), ("clip one frame later", late)] {
            XCTAssertNotEqual(m, t, name)
            let mp = try await CompositionPlanner.plan(m, media: media)
            let msig = try await Self.planSignature(mp)
            XCTAssertNotEqual(msig, sig, "\(name): plan signature differs")
            let out = try await AudioMixExportTests.decodePreview(mp)
            let msg = Self.outputMismatch(out, ref)
            XCTAssertNotNil(msg, "\(name): output rejected")
            print("mutation \(name): \(msg ?? "accepted")")
        }
        // 저장 파일 손대기: 레인 음량(80)을 79로 바꾼 파일을 읽으면 타임라인·계획 비교가 거부
        let data = try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        let json = String(decoding: data, as: UTF8.self)
        let key = json.contains("\"volumePercent\":80") ? "\"volumePercent\":80" : "\"volumePercent\" : 80"
        XCTAssertEqual(json.components(separatedBy: key).count - 1, 1, "one lane at 80%")
        let (bad, _) = try ProjectFile.decode(Data(json.replacingOccurrences(of: key, with: key.replacingOccurrences(of: "80", with: "79")).utf8))
        XCTAssertNotEqual(bad, t, "mutated file: timeline differs")
        let badSig = try await Self.planSignature(try await CompositionPlanner.plan(bad, media: media))
        XCTAssertNotEqual(badSig, sig, "mutated file: plan signature differs")
        let (good, _) = try ProjectFile.decode(data)
        XCTAssertEqual(good, t)
        let goodSig = try await Self.planSignature(try await CompositionPlanner.plan(good, media: media))
        XCTAssertEqual(goodSig, sig, "unmutated file: plan signature same")
    }

    /// 채널별 판정(P-012): 왼쪽·오른쪽 내용이 다른 생성 WAV(왼쪽 1000 Hz 0.2, 오른쪽 500 Hz 0.1)를 페이드가 있는 클립으로 실제 계획·믹스를 거쳐 읽는다.
    /// 그 출력에서 채널을 바꾸거나 한 채널만 손대면 비교가 그 채널을 지목해 거부해야 한다. (steady fixture는 두 채널이 같아 이것을 보일 수 없다.)
    func testReopenComparisonDetectsChannelDefects() async throws {
        let dir = ExportEndToEndTests.root.appendingPathComponent("chan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lr-distinct.wav")
        let n = 96_000
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            buf.floatChannelData![0][i] = Float(0.2 * sin(2 * Double.pi * 1_000 * Double(i) / 48_000))
            buf.floatChannelData![1][i] = Float(0.1 * sin(2 * Double.pi * 500 * Double(i) / 48_000))
        }
        do {
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                                              AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            try f.write(from: buf)
        }
        let m = try await MediaProbe.inspect(url)
        let id = UUID()
        var t = Timeline(audioClips: [Clip(id: id, mediaID: m.id, start: 0, sourceIn: 0, length: 60, lane: Lane.audioID)]).registering(m)
        t = try t.settingClipAudio(clip: id, fadeInFrames: 10, fadeOutFrames: 10)
        let plan = try await CompositionPlanner.plan(t, media: [m.id: m])
        let ref = try await AudioMixExportTests.decodePreview(plan)
        let lAmp = MultiLaneJudge.toneAmplitude(ref.l, hz: 1_000, from: 48_000 - 480, to: 48_000 + 480)
        let rAmp = MultiLaneJudge.toneAmplitude(ref.r, hz: 500, from: 48_000 - 480, to: 48_000 + 480)
        XCTAssertEqual(lAmp, 0.2, accuracy: 0.01, "left carries 1000 Hz")
        XCTAssertEqual(rAmp, 0.1, accuracy: 0.01, "right carries 500 Hz")
        let again = try await AudioMixExportTests.decodePreview(plan)
        XCTAssertNil(Self.outputMismatch(again, ref), "same plan accepted")
        var swapped = ref
        swapped.l = ref.r; swapped.r = ref.l
        let sm = Self.outputMismatch(swapped, ref)
        XCTAssertTrue(sm?.contains("L ") == true && sm?.contains("R ") == true, "channel swap rejected on both channels: \(sm ?? "nil")")
        var lOnly = ref
        lOnly.l = ref.l.map { $0 * 0.99 }
        let lm = Self.outputMismatch(lOnly, ref)
        XCTAssertTrue(lm?.hasPrefix("L ") == true && lm?.contains("R ") == false, "left-only 1% gain names L only: \(lm ?? "nil")")
        var rOnly = ref
        rOnly.r = ref.r.map { $0 * 0.99 }
        let rm = Self.outputMismatch(rOnly, ref)
        XCTAssertTrue(rm?.hasPrefix("R ") == true, "right-only 1% gain names R only: \(rm ?? "nil")")
    }

    /// 자르기 전·뒤 소리가 표본 단위로 같다(페이드 안 자르기 두 곳, 트림·옮기기 뒤 설정 유지)
    func testSplitAudioIdenticalToUnsplit() async throws {
        let s = try await steady()
        let id = UUID()
        var t = Timeline(audioClips: [Clip(id: id, mediaID: s.id, start: 0, sourceIn: 0, length: 90, lane: Lane.audioID)]).registering(s)
        t = try t.settingClipAudio(clip: id, volumePercent: 70, fadeInFrames: 60, fadeOutFrames: 20)
        let r0 = UUID(), r = UUID()
        let split = try t.splitting(clip: id, atFrame: 30, newIDs: (UUID(), r0)).splitting(clip: r0, atFrame: 80, newIDs: (r, UUID()))
        XCTAssertEqual(split.audioClips.count, 3)
        let a = try await AudioMixExportTests.decodePreview(try await CompositionPlanner.plan(t, media: [s.id: s]))
        let b = try await AudioMixExportTests.decodePreview(try await CompositionPlanner.plan(split, media: [s.id: s]))
        XCTAssertEqual(a.l.count, b.l.count)
        let diff = zip(a.l, b.l).map { abs($0 - $1) }.max() ?? 1
        print("split vs unsplit max sample diff \(diff)")
        XCTAssertLessThan(diff, 1e-4)
        // 손 계산: 0.2 × 0.7 × min(1, f/60) × min(1, (90 − f)/20)
        for f in [15.0, 29.5, 30.5, 45, 70, 79.5, 80.5, 85] {
            XCTAssertEqual(Self.amp(b.l, at: Int(f * 1_600)), 0.14 * min(1, f / 60) * min(1, (90 - f) / 20), accuracy: 0.002, "frame \(f)")
        }
        // 옮기기: 같은 모양이 옮긴 위치에서
        let moved = try split.relocating(clip: r, toStart: 120)
        let c = try await AudioMixExportTests.decodePreview(try await CompositionPlanner.plan(moved, media: [s.id: s]))
        let rc = moved.clip(r)!   // 원래 [30,80), 이제 [120,170), 원본 위치 그대로(위상은 원본 기준이라 진폭만 본다)
        XCTAssertEqual(rc.effectiveAudio.fadeIn, .init(length: 60, offset: 30))
        XCTAssertEqual(Self.amp(c.l, at: Int(130.0 * 1_600)), 0.14 * 40 / 60, accuracy: 0.002)
    }
}
