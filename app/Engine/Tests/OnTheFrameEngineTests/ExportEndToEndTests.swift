import AVFoundation
import E2Core
import Foundation
import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 생성 fixture로 가져오기 → 편집 → 내보내기 → 디코딩 판정(편집 경계 프레임, 연결된 소리), 그리고 출력 보호.
/// 비샌드박스 프로세스에서의 엔진 검증이다. 샌드박스 앱 검증은 app/scripts/selftest.sh(앱 자체 검사)가 맡는다.
/// 작업 디렉터리: app/.build/test-work(Git 무시). fixture는 재사용하고 출력은 테스트마다 지운다.
final class ExportEndToEndTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../.build/test-work").standardizedFileURL
    var fixtures: URL { Self.root.appendingPathComponent("fixtures") }
    var out: URL!

    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        out = Self.root.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: out) }

    func load() async throws -> (MediaAsset, MediaAsset) {
        (try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-A.mp4")), try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-B.mp4")))
    }

    func testProbeAcceptsAndRejects() async throws {
        let (a, b) = try await load()
        XCTAssertEqual(a.frameCount, 120); XCTAssertEqual(b.frameCount, 90)
        XCTAssertTrue(a.hasAudio); XCTAssertEqual(a.displaySize, CGSize(width: 1920, height: 1080))
        let r = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-rot90.mp4"))
        XCTAssertEqual(r.displaySize, CGSize(width: 360, height: 640)); XCTAssertFalse(r.hasAudio)
        for (n, kind) in DevFixtures.rejects.sorted(by: { $0.key < $1.key }) {
            do { _ = try await MediaProbe.inspect(fixtures.appendingPathComponent(n)); XCTFail("\(n) accepted") }
            catch let e as ProbeError { XCTAssertEqual(e.kind, kind, "\(n): \(e)") }
        }
    }

    /// 빈틈(D-020): 앞·중간·끝 빈틈이 있는 타임라인을 일반 삭제로 만들고, 내보낸 파일과 프리뷰 경로(같은 composition을
    /// AVPlayerItem으로 재생)의 프레임을 비교한다. 빈틈은 검정·무음, 유지된 클립은 바뀌지 않은 위치에서 원본 프레임·클릭이 맞아야 한다.
    func testGapsRenderBlackAndSilentInExportAndPreview() async throws {
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        let tb = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TB.mp4"))
        var t = Timeline().registering(ta).registering(tb)
        t = try t.inserting(media: ta.id).inserting(media: tb.id).inserting(media: ta.id)   // TA@0, TB@120, TA@210
        t = try t.splitting(clip: t.clips[0].id, atFrame: 20)
        t = try t.lifting(clip: t.clips[0].id)                           // 빈틈 [0,20)
        let thirdID = t.clips[2].id, thirdStart = t.clips[2].start
        t = try t.lifting(clip: t.clips[1].id)                           // 빈틈 [120,210)
        XCTAssertEqual(t.start(of: thirdID), thirdStart)                 // 남은 클립 위치 그대로
        t = try t.trimmingEnd(clip: thirdID, by: -60)                    // TA[0,60)@210, 길이 270
        t = try t.inserting(media: tb.id)
        t = try t.lifting(clip: t.clips.last!.id)                        // 끝 빈틈 [270,360)
        XCTAssertEqual(t.durationFrames, 360); XCTAssertEqual(t.gaps, [0..<20, 120..<210, 270..<360]); XCTAssertTrue(t.isValid)

        let plan = try await CompositionPlanner.plan(t, media: [ta.id: ta, tb.id: tb])
        XCTAssertEqual(plan.settings.nearestFrame(plan.composition.duration), 360)
        // 소리 트랙: 빈틈 구간은 빈 세그먼트이거나(앞·중간) 트랙이 이미 끝남(끝 빈틈) — 둘 다 무음
        let at = try await plan.composition.loadTracks(withMediaType: .audio).first
        let segs = try await at?.load(.segments) ?? []
        for g in t.gaps {
            let mid = plan.settings.time((g.lowerBound + g.upperBound) / 2)
            XCTAssertTrue(segs.first { $0.timeMapping.target.containsTime(mid) }?.isEmpty ?? true, "audio not empty in gap \(g)")
        }
        let dest = out.appendingPathComponent("gaps.mp4")
        let r = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [ta, tb]) { _ in }
        XCTAssertEqual(r, .completed(dest))
        let names = [ta.id: "otf-TA.mp4", tb.id: "otf-TB.mp4"]
        let refs = t.clips.map { ExportJudge.ClipRef(file: names[$0.mediaID]!, start: $0.start, sourceIn: $0.sourceIn, length: $0.length) }
        let v = try await ExportJudge.judge(dest, clips: refs, durationFrames: t.durationFrames, toneCheck: true)
        XCTAssertTrue(v.pass, "\(v)")
        XCTAssertEqual(v.gapFrames, 200); XCTAssertEqual(v.expectedOnsets, [30, 50, 75, 100, 240, 260].map { $0 * 1600 })
        XCTAssertEqual(v.boundaries.last?.frame, 359); XCTAssertEqual(v.boundaries.last?.measured, "black")   // 끝 빈틈: 검정 유지
        print("gap export: gapRMSMax \(v.gapRMSMax ?? -1) clipRMSMin \(v.clipRMSMin ?? -1) onset max err \(v.maxOnsetErrorSamples ?? -1)")

        // 프리뷰 경로: 같은 PlannedComposition을 AVPlayerItem으로(앱 프리뷰와 같은 구성) 탐색해 프레임을 읽는다
        let (expected, _) = try ExportJudge.expectations(refs, durationFrames: t.durationFrames)
        let probe = [0, 10, 19, 20, 21, 70, 119, 120, 165, 209, 210, 211, 269, 270, 300, 359]
        let preview = try await PreviewProbe.frames(plan, at: probe)
        Spec4K.configure(.fhd)
        let decoded = try await E2Decoder.decode(dest)
        XCTAssertEqual(Set(preview.keys), Set(probe), "preview frames missing")
        for n in probe {
            let pm = preview[n].flatMap { E2Metrics.measure($0.pb) }
            XCTAssertTrue(ExportJudge.matches(pm, expected[n]), "preview \(n): expected \(expected[n].label) got \(ExportJudge.label(pm))")
            XCTAssertEqual(ExportJudge.label(pm), ExportJudge.label(decoded.frames[n].metrics), "preview≠export at \(n)")
        }
        // 화소 비교(완료 기준 3의 M1 방법, 허용치 근거는 PreviewExportCompare 참조)
        let exportPixels = try await FrameCompare.decode(dest, frames: Set(probe))
        let cmp = PreviewExportCompare.check(preview: preview, export: exportPixels, expected: expected, probes: probe)
        XCTAssertTrue(cmp.failures.isEmpty, cmp.failures.joined(separator: "; "))
        // 음성 대조: 인접 프레임(같은 원본), 클립 대 검정은 허용치 아래여야 한다(비교가 실제로 구별함)
        var gc: [String] = []
        for (x, y) in [(20, 21), (210, 211), (119, 120), (269, 270), (209, 210)] {
            let v = FrameCompare.blockPSNR(FrameCompare.copy(preview[x]!.pb), exportPixels[y]!)
            XCTAssertLessThan(v, PreviewExportCompare.minBlockPSNR, "control \(x) vs \(y) = \(v)")
            gc.append(String(format: "%dv%d %.1f", x, y, v))
        }
        print("gap controls: " + gc.joined(separator: ", "))
        print("preview/export PSNR: \(cmp.summary)")
        // 음성 대조: 빈틈 위치를 1프레임 어긋나게 기대하면 실패해야 한다
        var shifted = refs; shifted[0] = .init(file: refs[0].file, start: refs[0].start! + 1, sourceIn: refs[0].sourceIn, length: refs[0].length - 1)
        let neg = try await ExportJudge.judge(dest, clips: shifted, durationFrames: t.durationFrames, toneCheck: true)
        XCTAssertFalse(neg.pass)
    }

    /// HEVC 원본(1280×720, 소리 없음)도 가져와 내보낼 수 있고, 출력은 1920×1080 H.264이며 프레임 수가 같다.
    func testHEVCSourceExports() async throws {
        let h = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-hevc.mp4"))
        XCTAssertEqual(h.codec, "hvc1"); XCTAssertEqual(h.frameCount, 30); XCTAssertFalse(h.hasAudio)
        var t = try Timeline().registering(h).inserting(media: h.id)
        t = try t.splitting(clip: t.clips[0].id, atFrame: 12)
        t = try t.moving(clip: t.clips[1].id, toIndex: 0)
        let plan = try await CompositionPlanner.plan(t, media: [h.id: h])
        XCTAssertFalse(plan.hasAudio)
        let dest = out.appendingPathComponent("hevc.mp4")
        let r = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [h]) { _ in }
        XCTAssertEqual(r, .completed(dest))
        let m = try await MediaProbe.inspect(dest)
        XCTAssertEqual(m.frameCount, 30); XCTAssertEqual(m.codec, "avc1"); XCTAssertEqual(m.displaySize, CGSize(width: 1920, height: 1080))
    }

    /// 나누기·트림·이동·삭제한 타임라인을 내보내고 모든 프레임과 경계 앞뒤를 디코딩해 확인한다.
    func testEditedExportMatchesTimelineAtCuts() async throws {
        let (a, b) = try await load()
        var t = Timeline().registering(a).registering(b)
        t = try t.inserting(media: a.id).inserting(media: b.id)
        t = try t.splitting(clip: t.clips[0].id, atFrame: 50)            // A0-50, A50-120, B
        t = try t.trimmingEnd(clip: t.clips[0].id, by: -12)              // A0-38
        t = try t.trimmingStart(clip: t.clips[2].id, by: 15)             // B15-90
        t = try t.moving(clip: t.clips[2].id, toIndex: 0)                // B15-90, A0-38, A50-120
        t = try t.trimmingEnd(clip: t.clips[2].id, by: -21)              // A50-99
        let plan = try await CompositionPlanner.plan(t, media: [a.id: a, b.id: b])
        let dest = out.appendingPathComponent("edited.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [a, b]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let names = [a.id: "otf-A.mp4", b.id: "otf-B.mp4"]
        let v = try await ExportJudge.judge(dest, clips: t.clips.map { .init(file: names[$0.mediaID]!, sourceIn: $0.sourceIn, length: $0.length) })
        XCTAssertTrue(v.pass, "\(v)")
        XCTAssertEqual(v.frames, 75 + 38 + 49)
        XCTAssertEqual(v.boundaries.map(\.frame), [74, 75, 112, 113, 161])   // 경계 2곳의 앞뒤와 마지막 프레임
        // 프리뷰 경로(같은 composition을 AVPlayerItem으로) 대 내보내기: 클립↔클립 경계와 끝 프레임
        let refs = t.clips.map { ExportJudge.ClipRef(file: names[$0.mediaID]!, start: $0.start, sourceIn: $0.sourceIn, length: $0.length) }
        let (expected, _) = try ExportJudge.expectations(refs, durationFrames: t.durationFrames)
        let probe = [0, 40, 74, 75, 76, 112, 113, 140, 161]
        let preview = try await PreviewProbe.frames(plan, at: probe)
        let exportPixels = try await FrameCompare.decode(dest, frames: Set(probe))
        let cmp = PreviewExportCompare.check(preview: preview, export: exportPixels, expected: expected, probes: probe)
        XCTAssertTrue(cmp.failures.isEmpty, cmp.failures.joined(separator: "; "))
        print("cut preview/export PSNR: \(cmp.summary)")
        // 대조: 인접 프레임, 다른 원본(컷), 8화소 밀림, R·B 바뀜은 허용치 아래여야 한다(비교가 실제로 구별함)
        let p40 = FrameCompare.copy(preview[40]!.pb), e40 = exportPixels[40]!
        let controls: [(String, Double)] = [
            ("75v76", FrameCompare.blockPSNR(FrameCompare.copy(preview[75]!.pb), exportPixels[76]!)),
            ("74v75", FrameCompare.blockPSNR(FrameCompare.copy(preview[74]!.pb), exportPixels[75]!)),
            ("shift8", FrameCompare.blockPSNR(p40, FrameCompare.shifted(e40, dx: 8))),
            ("swapRB", FrameCompare.blockPSNR(p40, FrameCompare.swappedRB(e40)))]
        for (name, v) in controls { XCTAssertLessThan(v, PreviewExportCompare.minBlockPSNR, "control \(name) = \(v)") }
        print("cut controls: " + controls.map { String(format: "%@ %.1f", $0.0, $0.1) }.joined(separator: ", "))
        // 음성 대조: 한 클립의 원본 시작을 1프레임 어긋나게 기대하면 판정이 실패해야 한다(판정이 무조건 통과하지 않음)
        var shifted = t.clips.map { ExportJudge.ClipRef(file: names[$0.mediaID]!, sourceIn: $0.sourceIn, length: $0.length) }
        shifted[1] = .init(file: shifted[1].file, sourceIn: shifted[1].sourceIn + 1, length: shifted[1].length)
        let neg = try await ExportJudge.judge(dest, clips: shifted)
        XCTAssertFalse(neg.pass)
        XCTAssertEqual(neg.mismatchedFrames.count, 38)
    }

    func testCancelAndFailureLeaveNoDestinationAndCleanTemp() async throws {
        let (a, b) = try await load()
        var t = Timeline().registering(a).registering(b)
        t = try t.inserting(media: a.id).inserting(media: b.id).inserting(media: a.id)
        let plan = try await CompositionPlanner.plan(t, media: [a.id: a, b.id: b])
        let temps = TempRecorder()
        // 실패 주입
        let f = out.appendingPathComponent("fail.mp4")
        let r1 = await ExportService.export(plan, to: .fromSavePanel(f), sources: [a, b],
                                            options: .init(failAfterFraction: 0.2, onTempDirectory: { temps.add($0) })) { _ in }
        XCTAssertEqual(r1, .failed(.injected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        // 취소(작업 취소)
        let c = out.appendingPathComponent("cancel.mp4")
        let started = expectation(description: "progress")
        let once = OnceFlag()
        let task = Task { await ExportService.export(plan, to: .fromSavePanel(c), sources: [a, b], options: .init(onTempDirectory: { temps.add($0) })) { p in
            if p > 0.05, once.set() { started.fulfill() } } }
        await fulfillment(of: [started], timeout: 60)
        task.cancel()
        let r2 = await task.value
        XCTAssertEqual(r2, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.path))
        XCTAssertEqual(temps.all.count, 2)
        for d in temps.all { XCTAssertFalse(FileManager.default.fileExists(atPath: d.path), "temp left") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    /// 진행률(완료 기준 5): 한 내보내기 안에서 유한·[0,1]·줄어들지 않음. 1.0은 검증·승격 성공 뒤 한 번만.
    /// 실패 주입·취소·승격 실패(대상이 그 사이 생김)는 완료로 보고하지 않고 1.0에 닿지 않는다.
    func testExportProgressIsBoundedMonotonicAndCompletionOnlyOnSuccess() async throws {
        let (a, b) = try await load()
        let t = try Timeline().registering(a).registering(b).inserting(media: a.id).inserting(media: b.id)
        let plan = try await CompositionPlanner.plan(t, media: [a.id: a, b.id: b])
        func check(_ v: [Double], _ name: String) {
            XCTAssertTrue(v.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(name) range \(v)")
            XCTAssertTrue(zip(v, v.dropFirst()).allSatisfy { $0 <= $1 }, "\(name) decreasing \(v)")
        }
        // 성공
        let ok = ProgressLog()
        let dest = out.appendingPathComponent("ok.mp4")
        let r1 = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [a, b]) { ok.add($0) }
        XCTAssertEqual(r1, .completed(dest))
        let v1 = ok.values
        check(v1, "success")
        XCTAssertGreaterThan(v1.count, 2)
        XCTAssertEqual(v1.last, 1); XCTAssertEqual(v1.filter { $0 == 1 }.count, 1)
        XCTAssertTrue(v1.dropLast().allSatisfy { $0 <= ExportService.encodingProgressCap })
        // 실패 주입
        let fl = ProgressLog()
        let r2 = await ExportService.export(plan, to: .fromSavePanel(out.appendingPathComponent("f.mp4")), sources: [a, b],
                                            options: .init(failAfterFraction: 0.3)) { fl.add($0) }
        XCTAssertEqual(r2, .failed(.injected)); check(fl.values, "fail"); XCTAssertLessThan(fl.values.max() ?? 0, 1)
        // 승격 실패: 인코딩·검증은 끝났지만 대상이 그 사이 생김 → 완료 아님, 1.0 없음
        let ap = out.appendingPathComponent("appeared.mp4")
        let pl = ProgressLog()
        let r3 = await ExportService.export(plan, to: .fromSavePanel(ap), sources: [a, b],
                                            options: .init(beforePromotion: { try? Data("x".utf8).write(to: ap) })) { pl.add($0) }
        XCTAssertEqual(r3, .failed(.destinationAppeared)); check(pl.values, "promotion"); XCTAssertLessThan(pl.values.max() ?? 0, 1)
        // 취소
        let cl = ProgressLog()
        let started = expectation(description: "progress")
        let once = OnceFlag()
        let task = Task { await ExportService.export(plan, to: .fromSavePanel(self.out.appendingPathComponent("c.mp4")), sources: [a, b]) { p in
            cl.add(p); if p > 0.05, once.set() { started.fulfill() } } }
        await fulfillment(of: [started], timeout: 60)
        task.cancel()
        let r4 = await task.value
        XCTAssertEqual(r4, .cancelled); check(cl.values, "cancel"); XCTAssertLessThan(cl.values.max() ?? 0, 1)
    }

    /// 원본 보호, 확인하지 않은 기존 파일, 확인 뒤 변경, 내보내는 동안 생긴 파일, 확인한 대치
    func testDestinationProtection() async throws {
        let (a, b) = try await load()
        var t = try Timeline().registering(a).registering(b).inserting(media: b.id)
        t = try t.trimming(clip: t.clips[0].id, sourceIn: 10, length: 10)
        let plan = try await CompositionPlanner.plan(t, media: [a.id: a, b.id: b])
        func run(_ d: ExportDestination, _ o: ExportService.Options = .init()) async -> ExportOutcome {
            await ExportService.export(plan, to: d, sources: [a, b], options: o) { _ in }
        }
        let srcHash = try Data(contentsOf: a.url)
        // 원본 경로(대치 확인이 있어도), 하드 링크(같은 inode)
        let r1 = await run(.fromSavePanel(a.url))
        XCTAssertEqual(r1, .failed(.destinationIsSource))
        let link = out.appendingPathComponent("link.mp4")
        XCTAssertEqual(Darwin.link(a.url.path, link.path), 0)
        let r2 = await run(.fromSavePanel(link))
        XCTAssertEqual(r2, .failed(.destinationIsSource))
        try FileManager.default.removeItem(at: link)
        XCTAssertEqual(try Data(contentsOf: a.url), srcHash)
        // 확인하지 않은 기존 파일
        let ex = out.appendingPathComponent("existing.mp4")
        try Data("keep".utf8).write(to: ex)
        let r3 = await run(ExportDestination(url: ex, confirmedReplace: false, identityAtConfirmation: nil))
        XCTAssertEqual(r3, .failed(.destinationExistsUnconfirmed))
        // 확인한 뒤 바뀜(승격 직전)
        let d = ExportDestination.fromSavePanel(ex)
        let r4 = await run(d, .init(beforePromotion: { try? Data("changed-later".utf8).write(to: ex) }))
        XCTAssertEqual(r4, .failed(.destinationChangedAfterConfirmation))
        XCTAssertEqual(try String(contentsOf: ex, encoding: .utf8), "changed-later")
        // 새 대상이 내보내는 동안 생김
        let ap = out.appendingPathComponent("appeared.mp4")
        let r5 = await run(.fromSavePanel(ap), .init(beforePromotion: { try? Data("other".utf8).write(to: ap) }))
        XCTAssertEqual(r5, .failed(.destinationAppeared))
        XCTAssertEqual(try String(contentsOf: ap, encoding: .utf8), "other")
        // 확인한 대치
        let r6 = await run(.fromSavePanel(ex))
        XCTAssertEqual(r6, .completed(ex))
        let m = try await MediaProbe.inspect(ex)
        XCTAssertEqual(m.frameCount, 10)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)), ["existing.mp4", "appeared.mp4"])
    }
}

final class TempRecorder: @unchecked Sendable {   // 안전성: 잠금으로만 접근
    private let lock = NSLock(); private var urls: [URL] = []
    func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}
final class OnceFlag: @unchecked Sendable {      // 안전성: 잠금으로만 접근
    private let lock = NSLock(); private var done = false
    func set() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// 프리뷰 경로 프레임 읽기: AVPlayer + AVPlayerItem(composition, videoComposition) + AVPlayerItemVideoOutput.
/// 앱 프리뷰(ProjectStore)와 같은 PlannedComposition을 쓴다. 정지 상태에서 정확히 탐색한 뒤 그 시각의 프레임을 꺼낸다.
struct ProbeFailure: Error { let message: String; init(_ m: String) { message = m } }

@MainActor
enum PreviewProbe {
    struct Frame: @unchecked Sendable { let pb: CVPixelBuffer }   // 안전성: 읽기 전용으로만 쓴다
    static func frames(_ p: PlannedComposition, at frames: [Int]) async throws -> [Int: Frame] {
        let item = AVPlayerItem(asset: p.composition)
        item.videoComposition = p.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        let deadline = Date().addingTimeInterval(10)
        while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard item.status == .readyToPlay else { throw ProbeFailure("preview item not ready: \(String(describing: item.error))") }
        var out: [Int: Frame] = [:]
        for n in frames {
            let t = p.settings.time(n)
            await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            let end = Date().addingTimeInterval(3)
            // 탐색 뒤 그 시각의 새 버퍼만 받는다(이전 탐색의 버퍼를 받지 않도록 표시 시각을 확인)
            while Date() < end {
                if output.hasNewPixelBuffer(forItemTime: t) {
                    var shown = CMTime.invalid
                    if let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown),
                       shown.isNumeric, abs((shown - t).seconds) < 0.0005 { out[n] = Frame(pb: pb); break }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        player.replaceCurrentItem(with: nil)
        return out
    }
}

final class ProgressLog: @unchecked Sendable {   // 안전성: 잠금으로만 접근
    private let lock = NSLock(); private var v: [Double] = []
    func add(_ x: Double) { lock.lock(); v.append(x); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return v }
}

/// 프리뷰 대 내보내기 비교(완료 기준 3, M1 방법).
/// 1. 같은 프레임인지: 두 쪽 모두 화면의 원본 ID·원본 프레임 코드(또는 검정) 판정이 기대값과 같아야 한다(정확히 같음).
/// 2. 화면 전체가 같은지: 16×16 블록 평균 RGB의 PSNR. 프리뷰는 무압축, 내보내기는 H.264 손실 압축이라 비트 단위 같음은
///    요구하지 않는다. 블록 평균은 압축 잡음을 줄이고 위치·크기·색 변환 오류는 남긴다.
///    측정(2026-10-10, 생성 fixture, 1920×1080, AVAssetExportPreset1920x1080):
///    - 전체 해상도 PSNR(2화소 간격)은 같은 프레임 24.5–40.4 dB(컷 직후 프레임이 가장 낮음), 인접 프레임 22.2–24.4 dB로
///      겹쳐 쓸 수 없었다(처음 정한 26 dB가 컷 직후 같은 프레임에서 실패). 기록만 한다.
///    - 블록 평균 PSNR: 같은 프레임 41.2–52.8 dB(빈틈 검정 포함 더 높음), 인접 프레임 29.5, 컷 너머 다른 원본 12.7,
///      8화소 밀림 28.1, 2화소 밀림 37.9, R·B 바뀜 29.7 dB.
///    → 블록 평균 PSNR ≥ 38 dB(관측 같은 프레임 최솟값보다 3.2 dB 낮음). 인접 프레임·밀림 8화소·색 채널 오류·검정 대 클립은
///      이보다 낮아 걸러진다(대조로 확인). 2화소 밀림(37.9)은 경계에 있다. 이 값은 이 fixture·인코딩 설정의 근거이며 일반 화질 기준이 아니다.
enum PreviewExportCompare {
    static let minBlockPSNR = 38.0
    struct Result { var failures: [String] = []; var summary = "" }

    static func check(preview: [Int: PreviewProbe.Frame], export: [Int: FrameCompare.Frame], expected: [ExportJudge.Expected], probes: [Int]) -> Result {
        var r = Result(), parts: [String] = []
        for n in probes {
            guard let p = preview[n], let e = export[n] else { r.failures.append("missing \(n)"); continue }
            let pf = FrameCompare.copy(p.pb)
            let pm = E2Metrics.measure(p.pb)
            if !ExportJudge.matches(pm, expected[n]) { r.failures.append("preview \(n) \(ExportJudge.label(pm)) != \(expected[n].label)") }
            let block = FrameCompare.blockPSNR(pf, e), full = FrameCompare.psnr(pf, e)
            if !(block >= minBlockPSNR) { r.failures.append(String(format: "block psnr %d = %.1f < %.0f", n, block, minBlockPSNR)) }
            parts.append(String(format: "%d:%.1f/%.1f", n, block, full))
        }
        r.summary = "block/full " + parts.joined(separator: " ")
        return r
    }
}
