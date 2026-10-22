import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 자막 내보내기(구조 R, ExportService, 2026-10-22, docs/SUBTITLE-DESIGN.md §43). 같은 계획을 자막 없이 내보낸 결과(지금까지의 세션 경로)와 견준다.
/// 확인: 모든 프레임의 원본·빈틈(ExportJudge), 표본 수·길이 1/30, 자막 경계(반복 프레임·빈틈·끝), 소리 내용(기존 허용치), 색(값 ±2), 진행률·취소·실패·출력 보호.
final class SubtitleExportTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var out: URL!
    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        out = ExportEndToEndTests.root.appendingPathComponent("subexp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: out) }

    func asset(_ f: String) async throws -> MediaAsset { try await MediaProbe.inspect(fixtures.appendingPathComponent(f)) }
    func export(_ p: PlannedComposition, _ name: String, sources: [MediaAsset], options: ExportService.Options = .init()) async -> (ExportOutcome, URL, [Double]) {
        let dest = out.appendingPathComponent(name)
        final class Box: @unchecked Sendable { var v: [Double] = []; let l = NSLock() }
        let box = Box()
        let o = await ExportService.export(p, to: .fromSavePanel(dest), sources: sources, options: options) { v in box.l.withLock { box.v.append(v) } }
        return (o, dest, box.v)
    }
    static func planes(_ u: URL, _ frames: Set<Int>) async throws -> [Int: (y: [UInt8], c: [UInt8])] {
        let a = AVURLAsset(url: u); let r = try AVAssetReader(asset: a)
        let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        r.add(o); r.startReading()
        var out: [Int: (y: [UInt8], c: [UInt8])] = [:]
        while let sb = o.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let k = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded()); guard frames.contains(k) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            var y = [UInt8](repeating: 0, count: 1920 * 1080), c = [UInt8](repeating: 0, count: 1920 * 540)
            let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<1080 { for x in 0..<1920 { y[row * 1920 + x] = yb[row * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + x] } }
            for row in 0..<540 { for x in 0..<1920 { c[row * 1920 + x] = cb[row * CVPixelBufferGetBytesPerRowOfPlane(pb, 1) + x] } }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            out[k] = (y, c)
        }
        return out
    }
    static func samples(_ u: URL) async throws -> (count: Int, allOneFrame: Bool) {
        let a = AVURLAsset(url: u); let t = try await a.loadTracks(withMediaType: .video).first!
        let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil); r.add(o); r.startReading()
        var c = 0, ok = true
        while let sb = o.copyNextSampleBuffer() { guard CMSampleBufferGetNumSamples(sb) > 0 else { continue }; c += 1; if CMTimeCompare(CMSampleBufferGetDuration(sb), CMTime(value: 1, timescale: 30)) != 0 { ok = false } }
        return (c, ok)
    }
    /// 자막 경계(§17 T1 정의): 자막 없는 내보내기 대비 |ΔY| > 40인 글자 화소(알파 ≥ 128)가 25% 이상이면 보임, 0이면 숨김
    func checkBoundaries(_ subs: [SubtitleItem], r: URL, plain: URL, n: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let frames = Set(subs.flatMap { [$0.start - 1, $0.start, $0.end - 1, $0.end] }.filter { $0 >= 0 && $0 < n })
        let a = try await Self.planes(r, frames), b = try await Self.planes(plain, frames)
        for s in subs {
            let ras = SubtitleRenderer.shared.raster(s), img = ras.image, bpr = img.bytesPerRow, data = img.dataProvider!.data! as Data
            for k in [s.start - 1, s.start, s.end - 1, s.end] where k >= 0 && k < n {
                var need = 0, ink = 0
                data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                    for y in 0..<img.height { for x in 0..<img.width where p[y * bpr + x * 4 + 3] >= 128 {
                        let fx = Int(ras.rect.minX) + x, fy = Int(ras.rect.minY) + y
                        guard fx >= 0, fx < 1920, fy >= 0, fy < 1080 else { continue }
                        need += 1; if abs(Int(a[k]!.y[fy * 1920 + fx]) - Int(b[k]!.y[fy * 1920 + fx])) > 40 { ink += 1 }
                    } }
                }
                let want = s.visible(atFrame: k)
                XCTAssertEqual(want ? Double(ink) >= 0.25 * Double(need) : ink == 0, true, "\(s.text) f\(k) ink \(ink)/\(need) expected \(want)", file: file, line: line)
            }
        }
    }
    /// 소리를 자막 없는 내보내기와 견줌: 트랙 하나·2채널, 표본 수 같음, onset ±16, 프레임 RMS 차이 ≤ 0.02(AudioMixExportTests의 진폭 허용치)
    func checkAudio(_ r: URL, _ plain: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let x = try await AudioMixExportTests.decodeMP4(r), y = try await AudioMixExportTests.decodeMP4(plain)
        XCTAssertEqual(x.audioTracks, 1, file: file, line: line); XCTAssertEqual(x.channels, 2, file: file, line: line)
        XCTAssertEqual(x.pcm.l.count, y.pcm.l.count, "audio length", file: file, line: line)
        let on = (E2Decoder.onsets(x.pcm.l), E2Decoder.onsets(y.pcm.l))
        XCTAssertTrue(on.0.count == on.1.count && zip(on.0, on.1).allSatisfy { abs($0 - $1) <= 16 }, "onsets \(on.0) vs \(on.1)", file: file, line: line)
        var env = 0.0
        for f in 0..<(min(x.pcm.l.count, y.pcm.l.count) / 1_600) { for (p, q) in [(x.pcm.l, y.pcm.l), (x.pcm.r, y.pcm.r)] { env = max(env, abs(AudioMixExportTests.rms(p, from: f, to: f + 1) - AudioMixExportTests.rms(q, from: f, to: f + 1))) } }
        XCTAssertLessThanOrEqual(env, 0.02, "per-frame RMS difference", file: file, line: line)
    }

    /// 섞인 fps·빈틈(앞·가운데)·끝 소리만(검정)·자막 경계가 반복 프레임·빈틈·정확한 끝에 걸친 타임라인
    func testMixedFpsGapsAndEndThroughR() async throws {
        let files = ["otf-F23976.mp4", "otf-N2997.mp4", "otf-A.mp4"]
        var ms: [MediaAsset] = []; for f in files { ms.append(try await asset(f)) }
        let wav = try await asset(AudioFixture.wav.file)
        var t = Timeline()
        for m in ms + [wav] { t = t.registering(m) }
        t = try t.placing(media: ms[0].id, at: 10, videoLane: Lane.videoID, audioLane: Lane.audioID)          // 앞 빈틈 10
        let e0 = t.occupiedEnd(lane: Lane.videoID)
        t = try t.placing(media: ms[1].id, at: e0, videoLane: Lane.videoID, audioLane: Lane.audioID)
        let e1 = t.occupiedEnd(lane: Lane.videoID)
        t = try t.placing(media: ms[2].id, at: e1 + 15, videoLane: Lane.videoID, audioLane: Lane.audioID)    // 가운데 빈틈 15
        let e2 = t.occupiedEnd(lane: Lane.videoID)
        let a2 = UUID(), s1 = UUID()
        t = try t.addingLane(.audio, name: "W", id: a2).placing(media: wav.id, at: e2 - 20, videoLane: nil, audioLane: a2)   // 끝은 소리만
        t = try t.addingLane(.subtitle, name: "자막", id: s1, outward: true)
        let n0 = t.durationFrames
        t = try t.addingSubtitle(lane: s1, at: 5, length: 10, text: "앞 빈틈에서 시작")                 // [5,15)
        t = try t.addingSubtitle(lane: s1, at: 51, length: 30, text: "반복 프레임 경계 23.976")         // 23.976 원본 구간
        t = try t.addingSubtitle(lane: s1, at: e1 + 3, length: 9, text: "가운데 빈틈 안")
        var st = SubtitleStyle.default; st.red = 255; st.green = 230; st.blue = 30; st.yMilli = 300_000
        t = try t.addingSubtitle(lane: s1, at: n0 - 20, length: 50, text: "영상 끝을 넘음", style: st)  // 끝을 넘어 길이 늘림
        XCTAssertEqual(t.durationFrames, n0 + 30)
        let media = Dictionary(uniqueKeysWithValues: (ms + [wav]).map { ($0.id, $0) })
        let p = try await CompositionPlanner.plan(t, media: media)
        var plainPlan = p; plainPlan.subtitles = []
        let (po, plain, _) = await export(plainPlan, "plain.mp4", sources: ms + [wav])
        let (ro, r, prog) = await export(p, "subs.mp4", sources: ms + [wav])
        XCTAssertEqual(po, .completed(plain)); XCTAssertEqual(ro, .completed(r))
        // 진행률: 줄어들지 않음, [0, 0.99], 마지막 1.0
        XCTAssertEqual(prog.last, 1.0); XCTAssertTrue(zip(prog, prog.dropFirst()).allSatisfy { $0 <= $1 }); XCTAssertTrue(prog.dropLast().allSatisfy { $0 <= 0.99 })
        let refs = t.clips(inLane: Lane.videoID).map { c in ExportJudge.ClipRef(file: files[ms.firstIndex { $0.id == c.mediaID }!], start: c.start, sourceIn: c.sourceIn, length: c.length) }
        for u in [plain, r] {
            let v = try await ExportJudge.judge(u, clips: refs, durationFrames: p.durationFrames, checkAudio: false)
            XCTAssertTrue(v.pass, "\(u.lastPathComponent) judge mismatched \(v.mismatchedFrames.prefix(6)) frames \(v.frames)/\(v.expectedFrames)")
        }
        let sp = try await Self.samples(r)
        XCTAssertEqual(sp.count, p.durationFrames); XCTAssertTrue(sp.allOneFrame)
        try await checkBoundaries(p.subtitles, r: r, plain: plain, n: p.durationFrames)
        try await checkAudio(r, plain)
    }

    /// 두 레인(기본 합성기 출력이 BGRA인 경우), 자막이 위 레이어가 들어오는 프레임을 걸침
    func testMultilayerThroughR() async throws {
        let ta = try await asset("otf-TA.mp4"), b = try await asset("otf-B.mp4")
        let top = UUID(), s1 = UUID(), a2 = UUID()
        var t = try Timeline().registering(ta).registering(b).inserting(media: ta.id).addingLane(.video, name: "P", id: top, outward: true).addingLane(.audio, name: "B", id: a2)
        t = try t.placing(media: b.id, at: 60, videoLane: top, audioLane: a2)
        t = try t.settingTransform(clip: t.clips(inLane: top)[0].id, ClipTransform(scale: 0.4, x: 500, y: 250))
        t = try t.addingLane(.subtitle, name: "자막", id: s1, outward: true).addingSubtitle(lane: s1, at: 40, length: 60, text: "Mixed 한국어 English 日本語\n둘째 줄")
        let p = try await CompositionPlanner.plan(t, media: [ta.id: ta, b.id: b])
        var plainPlan = p; plainPlan.subtitles = []
        let (po, plain, _) = await export(plainPlan, "plain.mp4", sources: [ta, b])
        let (ro, r, _) = await export(p, "subs.mp4", sources: [ta, b])
        XCTAssertEqual(po, .completed(plain)); XCTAssertEqual(ro, .completed(r))
        let v = try await ExportJudge.judge(r, clips: [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 120)], durationFrames: p.durationFrames, checkAudio: false)
        XCTAssertTrue(v.pass, "judge \(v.mismatchedFrames.prefix(6))")
        try await checkBoundaries(p.subtitles, r: r, plain: plain, n: p.durationFrames)
        try await checkAudio(r, plain)
        // 자막 밖 영상: 프레임 20(자막 없음)의 가운데 값이 세션 경로와 ±2 안(색 경로 같음, §42)
        let a = try await Self.planes(r, [20, 70]), c = try await Self.planes(plain, [20, 70])
        for k in [20, 70] { for i in [540 * 1920 + 300, 900 * 1920 + 1700] { XCTAssertLessThanOrEqual(abs(Int(a[k]!.y[i]) - Int(c[k]!.y[i])), 2, "f\(k) Y at \(i)") } }
    }

    /// 소리 내용: AudioMixExportTests 배치(파란 판 + WAV 두 번 + AIFF, 겹침·빈틈)를 자막과 함께 R로 내보내 같은 판정(진폭 ±0.02, 무음, onset ±16)
    func testAudioMixThroughR() async throws {
        let plate = try await asset(PlateFixture.blue.file), w = try await asset(AudioFixture.wav.file), f = try await asset(AudioFixture.aiff.file)
        let a2 = UUID(), s1 = UUID()
        var t = Timeline(clips: [Clip(mediaID: plate.id, start: 0, sourceIn: 0, length: 90)],
                         audioClips: [Clip(mediaID: w.id, start: 0, sourceIn: 0, length: 60, lane: Lane.audioID), Clip(mediaID: w.id, start: 75, sourceIn: 0, length: 15, lane: Lane.audioID),
                                      Clip(mediaID: f.id, start: 20, sourceIn: 3, length: 40, lane: a2)],
                         lanes: [Lane(id: s1, kind: .subtitle, name: "자막")] + Lane.defaults + [Lane(id: a2, kind: .audio, name: "둘째")])
        for m in [plate, w, f] { t = t.registering(m) }
        t = try t.addingSubtitle(lane: s1, at: 30, length: 30, text: "소리 확인")
        let p = try await CompositionPlanner.plan(t, media: [plate.id: plate, w.id: w, f.id: f])
        let (ro, r, _) = await export(p, "subs.mp4", sources: [plate, w, f])
        XCTAssertEqual(ro, .completed(r))
        let d = try await AudioMixExportTests.decodeMP4(r)
        XCTAssertEqual(d.audioTracks, 1); XCTAssertEqual(d.channels, 2)
        AudioMixExportTests().judge(d.pcm, AudioMixExportTests.expect(gain: 100, muted: false), "R export", onsetTolerance: 16)
    }

    /// 색: 태그 있는 601 원본과 태그 없는 SD+HD 두 레이어에서, 자막 밖 값이 세션 경로와 ±2 안(R이 지금 내보내기의 색 처리를 그대로 따름, §42)
    func testColorMatchesSessionPath() async throws {
        let dir = out!
        var srcs: [String: MediaAsset] = [:]
        for s in [SubtitleColorFixtures.Src(name: "sd-601", w: 640, h: 480, tag: "601"), .init(name: "sd-untagged", w: 640, h: 480, tag: nil), .init(name: "hd-untagged", w: 1280, h: 720, tag: nil)] {
            let u = dir.appendingPathComponent("src-\(s.name).mp4"); try await SubtitleColorFixtures.write(s, to: u); srcs[s.name] = try await MediaProbe.inspect(u)
        }
        for (label, bottom, topName) in [("sd-601", "sd-601", nil), ("sd+hd untagged", "sd-untagged", "hd-untagged")] as [(String, String, String?)] {
            let mb = srcs[bottom]!, s1 = UUID()
            var t = try Timeline().registering(mb).inserting(media: mb.id)
            var media = [mb.id: mb], used = [mb]
            if let topName { let mt = srcs[topName]!, lane = UUID()
                t = try t.registering(mt).addingLane(.video, name: "P", id: lane, outward: true).placing(media: mt.id, at: 0, videoLane: lane, audioLane: nil)
                t = try t.settingTransform(clip: t.clips(inLane: lane)[0].id, ClipTransform(scale: 0.5, x: 0, y: 0)); media[mt.id] = mt; used.append(mt) }
            t = try t.addingLane(.subtitle, name: "자막", id: s1, outward: true).addingSubtitle(lane: s1, at: 0, length: 30, text: "색")
            let p = try await CompositionPlanner.plan(t, media: media)
            var plainPlan = p; plainPlan.subtitles = []
            let (po, plain, _) = await export(plainPlan, "plain-\(bottom).mp4", sources: used)
            let (ro, r, _) = await export(p, "subs-\(bottom).mp4", sources: used)
            XCTAssertEqual(po, .completed(plain)); XCTAssertEqual(ro, .completed(r))
            let a = try await Self.planes(r, [10]), b = try await Self.planes(plain, [10])
            for (x, y) in [(300, 400), (960, 540)] {   // 아래 판, 위 판(자막 밖)
                XCTAssertLessThanOrEqual(abs(Int(a[10]!.y[y * 1920 + x]) - Int(b[10]!.y[y * 1920 + x])), 2, "\(label) Y (\(x),\(y))")
                for ch in 0..<2 { XCTAssertLessThanOrEqual(abs(Int(a[10]!.c[(y / 2) * 1920 + (x / 2) * 2 + ch]) - Int(b[10]!.c[(y / 2) * 1920 + (x / 2) * 2 + ch])), 2, "\(label) C (\(x),\(y))") }
            }
            let tags = try await SubtitleColorFixtures.fileTags(r)
            XCTAssertTrue(tags.contains("matrix=ITU_R_709_2"), tags)
        }
    }

    /// 생애: 취소(작업 취소)·실패 주입은 기존 대상을 바꾸지 않고 임시 디렉터리를 지운다. 확인하지 않은 기존 대상은 거부.
    func testLifecycleCancelFailureAndDestinationProtection() async throws {
        let ta = try await asset("otf-TA.mp4"), s1 = UUID()
        var t = try Timeline().registering(ta).inserting(media: ta.id)
        t = try t.addingLane(.subtitle, name: "자막", id: s1, outward: true).addingSubtitle(lane: s1, at: 10, length: 60, text: "생애")
        let p = try await CompositionPlanner.plan(t, media: [ta.id: ta])
        let dest = out.appendingPathComponent("existing.mp4")
        let original = Data("기존 파일".utf8)
        // 실패 주입(진행률 0.5)
        try original.write(to: dest)
        final class TempBox: @unchecked Sendable { var url: URL?; let l = NSLock() }
        let tb = TempBox()
        var opt = ExportService.Options(failAfterFraction: 0.5)
        opt.onTempDirectory = { u in tb.l.withLock { tb.url = u } }
        let fo = await ExportService.export(p, to: .fromSavePanel(dest), sources: [ta], options: opt) { _ in }
        XCTAssertEqual(fo, .failed(.injected))
        XCTAssertEqual(try Data(contentsOf: dest), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tb.url!.path))
        // 취소: 진행률이 0.2를 넘으면 작업 취소
        final class Flag: @unchecked Sendable { var task: Task<ExportOutcome, Never>?; let l = NSLock() }
        let fl = Flag()
        var opt2 = ExportService.Options(); opt2.onTempDirectory = { u in tb.l.withLock { tb.url = u } }
        let task = Task { await ExportService.export(p, to: .fromSavePanel(dest), sources: [ta], options: opt2) { v in if v > 0.2 { fl.l.withLock { fl.task?.cancel() } } } }
        fl.l.withLock { fl.task = task }
        let co = await task.value
        XCTAssertEqual(co, .cancelled)
        XCTAssertEqual(try Data(contentsOf: dest), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tb.url!.path))
        // 확인하지 않은 기존 대상은 쓰지 않음
        let unconfirmed = ExportDestination(url: dest, confirmedReplace: false, identityAtConfirmation: nil)
        let uo = await ExportService.export(p, to: unconfirmed, sources: [ta]) { _ in }
        XCTAssertEqual(uo, .failed(.destinationExistsUnconfirmed))
        XCTAssertEqual(try Data(contentsOf: dest), original)
        // 대치를 확인한 기존 대상은 성공했을 때만 바뀐다
        let so = await ExportService.export(p, to: .fromSavePanel(dest), sources: [ta]) { _ in }
        XCTAssertEqual(so, .completed(dest))
        XCTAssertNotEqual(try Data(contentsOf: dest), original)
    }

    /// 그리지 못하는 자막(2026-10-23): 대상 파일·임시 디렉터리를 건드리기 전에 거부, 빈 자막은 거부 사유가 아님
    func testUnrenderableSubtitleRejectedBeforeDestination() async throws {
        let ta = try await asset("otf-TA.mp4"), s1 = UUID()
        var st = SubtitleStyle.default; st.red = 3; st.green = 141; st.blue = 59   // 이 시험만의 모양(캐시 처음)
        var t = try Timeline().registering(ta).inserting(media: ta.id)
        t = try t.addingLane(.subtitle, name: "자막", id: s1, outward: true)
            .addingSubtitle(lane: s1, at: 10, length: 30, text: "그릴 수 없음", style: st)
            .addingSubtitle(lane: s1, at: 50, length: 30, text: "", style: st)
        let p = try await CompositionPlanner.plan(t, media: [ta.id: ta])
        XCTAssertEqual(p.subtitles.count, 1)   // 빈 자막은 그릴 목록에 없음
        let dest = out.appendingPathComponent("unrenderable.mp4")
        let original = Data("기존 파일".utf8); try original.write(to: dest)
        SubtitleRenderer.maxBitmapBytesForTest = 1_000
        defer { SubtitleRenderer.maxBitmapBytesForTest = Int.max }
        final class TempBox: @unchecked Sendable { var url: URL?; let l = NSLock() }
        let tb = TempBox()
        var opt = ExportService.Options(); opt.onTempDirectory = { u in tb.l.withLock { tb.url = u } }
        let o = await ExportService.export(p, to: .fromSavePanel(dest), sources: [ta], options: opt) { _ in }
        guard case .failed(.export(let msg)) = o else { return XCTFail("\(o)") }
        XCTAssertTrue(msg.contains("자막을 그릴 수 없어"))
        XCTAssertEqual(try Data(contentsOf: dest), original)   // 대상 그대로
        XCTAssertNil(tb.url)                                    // 임시 디렉터리도 만들지 않음
        XCTAssertNotNil(ExportService.unrenderableSubtitle(p))
    }
}
