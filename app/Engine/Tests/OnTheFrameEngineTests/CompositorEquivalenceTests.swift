import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 자막 S1(2026-10-12): 실험 사용자 정의 합성기(`ExperimentalCompositor`) 대 지금 기본 합성기. 비교 계약은 docs/SUBTITLE-DESIGN.md §13.
/// - 정확 항목(단언): 프레임 수·크기, 프레임마다 화면 코드(원본·원본 프레임·검정), 판 색 격자·경계, 받은 원본 프레임이 미래가 아님.
/// - 화소 차이: 기록만 한다(판 안쪽과 경계 근처를 나눠서). 기준을 정하지 않는다.
/// - 같은 실험 합성기의 오프라인·내보내기·프리뷰 일치는 따로 적는다(기본 합성기와의 동등 증명이 아님).
/// 측정 기록: .build/test-work/diagnostics/s1-*.txt
final class CompositorEquivalenceTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var out: URL!
    var report: [String] = []
    func note(_ s: String) { report.append(s); print("S1 \(s)") }

    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        Spec4K.configure(.fhd)
        out = ExportEndToEndTests.root.appendingPathComponent("s1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: out)
        let dir = ExportEndToEndTests.root.appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (name.components(separatedBy: " ").last ?? "x").trimmingCharacters(in: CharacterSet(charactersIn: "]"))
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("s1-\(name).txt"), atomically: true, encoding: .utf8)
    }

    func custom(_ p: PlannedComposition, _ log: ExperimentalCompositorLog, options: ExperimentalCompositorOptions = .init()) throws -> PlannedComposition {
        PlannedComposition(composition: p.composition, videoComposition: try ExperimentalComposition.videoComposition(from: p.videoComposition, options: options, diagnostics: log),
                           durationFrames: p.durationFrames, settings: p.settings, hasAudio: p.hasAudio, audioMix: p.audioMix, hasVideo: p.hasVideo, assets: p.assets)
    }

    // MARK: 화소 비교

    struct PixelStats {
        var frames = 0, bitIdentical = 0
        var maxDiff = 0, interiorMax = 0, edgeMax = 0
        var interiorDiffPixels = 0, edgeDiffPixels = 0, interiorPixels = 0, edgePixels = 0
        var hist = [Int](repeating: 0, count: 5)   // 차이 0, 1, 2–3, 4–15, ≥16 (화소의 채널 최대 차이)
        var minPSNR = Double.infinity, worstFrame = -1
        mutating func add(_ a: CVPixelBuffer, _ b: CVPixelBuffer, frame: Int) {
            CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
            let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
            let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self), pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
            let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
            func luma(_ x: Int, _ y: Int) -> Int { let i = y * ra + x * 4; return (Int(pa[i + 2]) * 54 + Int(pa[i + 1]) * 183 + Int(pa[i]) * 19) >> 8 }
            // 2화소 간격 표본(전 화소의 1/4). 경계: 기본 합성기 화면에서 그 화소와 상하좌우 2화소 이웃의 밝기 폭이 24를 넘는 곳
            var se = 0.0, same = true, n = 0
            for y in stride(from: 2, to: h - 2, by: 2) {
                for x in stride(from: 2, to: w - 2, by: 2) {
                    let ia = y * ra + x * 4, ib = y * rb + x * 4
                    var d = 0
                    for c in 0..<3 { let e = abs(Int(pa[ia + c]) - Int(pb[ib + c])); d = max(d, e); se += Double(e * e) }
                    n += 1
                    let l0 = luma(x, y)
                    let edge = abs(luma(x - 2, y) - l0) > 24 || abs(luma(x + 2, y) - l0) > 24 || abs(luma(x, y - 2) - l0) > 24 || abs(luma(x, y + 2) - l0) > 24
                    if edge { edgePixels += 1; if d > 0 { edgeDiffPixels += 1 }; edgeMax = max(edgeMax, d) }
                    else { interiorPixels += 1; if d > 0 { interiorDiffPixels += 1 }; interiorMax = max(interiorMax, d) }
                    if d > 0 { same = false }
                    hist[d == 0 ? 0 : d == 1 ? 1 : d < 4 ? 2 : d < 16 ? 3 : 4] += 1
                    maxDiff = max(maxDiff, d)
                }
            }
            if same { same = memcmpRows(pa, ra, pb, rb, w: w, h: h) }   // 표본이 같으면 전 화소 비트 비교로 확인
            frames += 1; if same { bitIdentical += 1 }
            let psnr = se == 0 ? Double.infinity : 10 * log10(255.0 * 255.0 / (se / Double(n * 3)))
            if psnr < minPSNR { minPSNR = psnr; worstFrame = frame }
        }
        func memcmpRows(_ pa: UnsafeMutablePointer<UInt8>, _ ra: Int, _ pb: UnsafeMutablePointer<UInt8>, _ rb: Int, w: Int, h: Int) -> Bool {
            for y in 0..<h where memcmp(pa + y * ra, pb + y * rb, w * 4) != 0 {
                // 알파는 보지 않는다: 행이 다르면 BGR만 다시 본다
                for x in 0..<w { let i = y * ra + x * 4, j = y * rb + x * 4; if pa[i] != pb[j] || pa[i + 1] != pb[j + 1] || pa[i + 2] != pb[j + 2] { return false } }
            }
            return true
        }
        var summary: String {
            String(format: "(2-px sampled) frames %d bit-identical(full check) %d | max channel diff %d (interior %d, edge %d) | differing pixels interior %d/%d, edge %d/%d | hist[0,1,2-3,4-15,>=16] %@ | min PSNR %.2f dB at %d",
                   frames, bitIdentical, maxDiff, interiorMax, edgeMax, interiorDiffPixels, interiorPixels, edgeDiffPixels, edgePixels, "\(hist)", minPSNR, worstFrame)
        }
    }

    static func reader(_ comp: AVComposition, _ vc: AVVideoComposition) async throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
        let r = try AVAssetReader(asset: comp)
        let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await comp.loadTracks(withMediaType: .video),
                                                    videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        o.videoComposition = vc
        o.alwaysCopiesSampleData = false
        r.add(o)
        guard r.startReading() else { throw ProbeFailure("reader: \(String(describing: r.error))") }
        return (r, o)
    }

    /// 두 videoComposition을 오프라인으로 같은 차례로 읽어 프레임마다 visit(n, 기본, 실험)을 부른다. 읽은 프레임 수를 돌려준다.
    func lockstep(_ comp: AVComposition, _ a: AVVideoComposition, _ b: AVVideoComposition, visit: @escaping (Int, CVPixelBuffer, CVPixelBuffer) -> Void) async throws -> (Int, Int) {
        let ra = try await Self.reader(comp, a), rb = try await Self.reader(comp, b)
        return drive(ra.0, ra.1, rb.0, rb.1, visit: visit)
    }
    func drive(_ ra: AVAssetReader, _ oa: AVAssetReaderVideoCompositionOutput, _ rb: AVAssetReader, _ ob: AVAssetReaderVideoCompositionOutput,
               visit: (Int, CVPixelBuffer, CVPixelBuffer) -> Void) -> (Int, Int) {
        var na = 0, nb = 0
        while true {
            let sa = oa.copyNextSampleBuffer(), sb = ob.copyNextSampleBuffer()
            if sa != nil { na += 1 }; if sb != nil { nb += 1 }
            guard let sa, let sb, let pa = CMSampleBufferGetImageBuffer(sa), let pb = CMSampleBufferGetImageBuffer(sb) else { break }
            // 오프라인 리더는 내용이 바뀌는 시각의 프레임만 내기도 한다(섞인 fps에서 관찰, 2026-10-12). 프레임 번호는 표시 시각에서 구한다.
            let ta = CMSampleBufferGetPresentationTimeStamp(sa), tb = CMSampleBufferGetPresentationTimeStamp(sb)
            XCTAssertEqual(ta, tb, "sample \(na - 1) time default \(ta.seconds) experimental \(tb.seconds)")
            let n = Int((ta.seconds * 30).rounded())
            XCTAssertLessThan(abs(ta.seconds * 30 - Double(n)), 0.015, "sample \(na - 1) off 1/30 grid: \(ta.seconds)")
            XCTAssertEqual(CVPixelBufferGetWidth(pb), 1920); XCTAssertEqual(CVPixelBufferGetHeight(pb), 1080)
            XCTAssertEqual(CVPixelBufferGetWidth(pa), 1920); XCTAssertEqual(CVPixelBufferGetHeight(pa), 1080)
            visit(n, pa, pb)
        }
        while oa.copyNextSampleBuffer() != nil { na += 1 }
        while ob.copyNextSampleBuffer() != nil { nb += 1 }
        XCTAssertNotEqual(ra.status, .failed, "default reader \(String(describing: ra.error))")
        XCTAssertNotEqual(rb.status, .failed, "experimental reader \(String(describing: rb.error))")
        return (na, nb)
    }

    /// 실험 합성기가 받은 원본 프레임 시각: 출력 시각보다 미래(> 0.1 ms)인 것과 없는 원본을 센다. 늦음(원본 프레임 간격 안)은 정상이다.
    func checkSources(_ log: ExperimentalCompositorLog, _ label: String) {
        let s = log.snapshot
        var future: [String] = [], noTime = 0, maxLag = 0.0, missing = 0
        for e in s.entries {
            if e.sourceMissing { missing += 1 }
            for src in e.sources {
                guard let mt = src.movieTime else { noTime += 1; continue }
                let d = (mt - e.time).seconds
                if d > 0.0001 { future.append(String(format: "t %.4f got %.4f (track %d)", e.time.seconds, mt.seconds, src.trackID)) }
                maxLag = max(maxLag, -d)
            }
        }
        note("\(label) source frames: requests \(s.entries.count) future \(future.count) missing \(missing) no-movie-time \(noTime) max lag \(String(format: "%.4f", maxLag)) s started \(s.started) outcomes finished \(s.outcomes.filter { $0 == .finished }.count) cancelled \(s.outcomes.filter { $0 == .cancelled }.count) failed \(s.outcomes.filter { $0 == .failed }.count) errors \(s.errors.count)")
        XCTAssertTrue(future.isEmpty, "\(label) future source frames: \(future.prefix(5))")
        XCTAssertEqual(missing, 0, "\(label) missing source frames"); XCTAssertTrue(s.errors.isEmpty, "\(label) errors \(s.errors.prefix(3))")
    }

    /// 화면 코드 시나리오: 기본·실험 오프라인 모든 프레임의 코드가 기대값과 같고, 실험 합성기로 내보낸 파일·프리뷰도 같은가
    func codeScenario(_ label: String, _ t: Timeline, media: [UUID: MediaAsset], refs: [ExportJudge.ClipRef], probes: [Int]) async throws {
        let plan = try await CompositionPlanner.plan(t, media: media)
        let log = ExperimentalCompositorLog()
        let cplan = try custom(plan, log)
        let (expected, _) = try ExportJudge.expectations(refs, durationFrames: t.durationFrames)
        var stats = PixelStats(), wrongDefault: [String] = [], wrongCustom: [String] = []
        let (na, nb) = try await lockstep(plan.composition, plan.videoComposition, cplan.videoComposition) { n, a, b in
            let la = ExportJudge.label(E2Metrics.measure(a)), lb = ExportJudge.label(E2Metrics.measure(b))
            if n < expected.count {
                if !ExportJudge.matches(E2Metrics.measure(a), expected[n]) { wrongDefault.append("\(n):\(la)≠\(expected[n].label)") }
                if !ExportJudge.matches(E2Metrics.measure(b), expected[n]) { wrongCustom.append("\(n):\(lb)≠\(expected[n].label)") }
            }
            stats.add(a, b, frame: n)
        }
        note("\(label) offline samples default \(na) experimental \(nb) (timeline \(t.durationFrames) frames; the reader may skip unchanged frames)")
        note("\(label) code mismatches default \(wrongDefault.count) \(wrongDefault.prefix(5)) experimental \(wrongCustom.count) \(wrongCustom.prefix(5))")
        note("\(label) pixels default vs experimental: \(stats.summary)")
        XCTAssertEqual(na, nb); XCTAssertLessThanOrEqual(na, t.durationFrames)
        XCTAssertTrue(wrongCustom.isEmpty, "\(label) experimental codes \(wrongCustom.prefix(10))")
        XCTAssertTrue(wrongDefault.isEmpty, "\(label) default codes \(wrongDefault.prefix(10))")
        checkSources(log, "\(label) offline")

        // 실험 합성기로 내보내기(지금 ExportService 그대로) → 모든 프레임 코드 판정
        let dest = out.appendingPathComponent("\(label).mp4")
        let elog = ExperimentalCompositorLog()
        let outcome = await ExportService.export(try custom(plan, elog), to: .fromSavePanel(dest), sources: Array(media.values)) { _ in }
        XCTAssertEqual(outcome, .completed(dest), "\(label) experimental export")
        if outcome == .completed(dest) {
            let v = try await ExportJudge.judge(dest, clips: refs, durationFrames: t.durationFrames, checkAudio: false)
            note("\(label) experimental export judge pass \(v.pass) frames \(v.frames) mismatched \(v.mismatchedFrames.prefix(10)) gap \(v.gapFrames)")
            XCTAssertTrue(v.pass, "\(label) export \(v)")
            checkSources(elog, "\(label) export")
        }
        // 실험 합성기 프리뷰(AVPlayer, 정확한 탐색)
        let plog = ExperimentalCompositorLog()
        let pv = try await PreviewProbe.frames(try custom(plan, plog), at: probes)
        var pvBad: [String] = []
        for n in probes {
            guard let f = pv[n] else { pvBad.append("\(n):none"); continue }
            if !ExportJudge.matches(E2Metrics.measure(f.pb), expected[n]) { pvBad.append("\(n):\(f.record.labelAtAcquire)≠\(expected[n].label)") }
        }
        note("\(label) experimental preview probes \(probes.count) mismatches \(pvBad)")
        XCTAssertTrue(pvBad.isEmpty, "\(label) preview \(pvBad)")
        checkSources(plog, "\(label) preview")
    }


    /// 내보낸 두 파일의 같은 프레임 비교(2화소 간격 표본): 최대 채널 차이, 차이 분포, PSNR
    static func frameStats(_ a: FrameCompare.Frame, _ b: FrameCompare.Frame) -> (maxDiff: Int, hist: [Int], psnr: Double) {
        var se = 0.0, n = 0, mx = 0, hist = [0, 0, 0, 0, 0]
        for y in stride(from: 0, to: a.height, by: 2) { for x in stride(from: 0, to: a.width, by: 2) {
            let i = (y * a.width + x) * 4
            var d = 0
            for c in 0..<3 { let e = abs(Int(a.bgra[i + c]) - Int(b.bgra[i + c])); d = max(d, e); se += Double(e * e) }
            n += 1; mx = max(mx, d); hist[d == 0 ? 0 : d == 1 ? 1 : d < 4 ? 2 : d < 16 ? 3 : 4] += 1
        } }
        return (mx, hist, se == 0 ? .infinity : 10 * log10(255 * 255 / (se / Double(n * 3))))
    }
    /// 같은 계획을 기본·실험 합성기로 각각 내보내 프레임들을 디코딩한다
    func exportBoth(_ plan: PlannedComposition, sources: [MediaAsset], frames: Set<Int>, tag: String) async throws -> (d: [Int: FrameCompare.Frame], e: [Int: FrameCompare.Frame]) {
        var res: [[Int: FrameCompare.Frame]] = []
        for (which, p) in [("default", plan), ("experimental", try custom(plan, ExperimentalCompositorLog()))] {
            let dest = out.appendingPathComponent("\(tag)-\(which).mp4")
            let outcome = await ExportService.export(p, to: .fromSavePanel(dest), sources: sources) { _ in }
            XCTAssertEqual(outcome, .completed(dest), "\(tag) \(which) export")
            res.append(try await FrameCompare.decode(dest, frames: frames))
        }
        return (res[0], res[1])
    }

    // MARK: 시나리오

    /// A-010 타임라인(29.97·25·가변·23.976·59.94 HEVC, 자르기·트림·옮기기·끝 빈틈)
    func testMixedFrameRates() async throws {
        func ins(_ f: TimedFixture) async throws -> MediaAsset { try await MediaProbe.inspect(fixtures.appendingPathComponent(f.file)) }
        let n = try await ins(.ntsc), p = try await ins(.pal), v = try await ins(.vfr), f = try await ins(.film), h = try await ins(.high)
        let names = [n.id: TimedFixture.ntsc.file, p.id: TimedFixture.pal.file, v.id: TimedFixture.vfr.file, f.id: TimedFixture.film.file, h.id: TimedFixture.high.file]
        var t = Timeline().registering(n).registering(p).registering(v).registering(f).registering(h)
        t = try t.inserting(media: p.id).inserting(media: n.id).inserting(media: v.id).inserting(media: f.id).inserting(media: h.id)
        t = try t.trimmingStart(clip: t.clips[0].id, by: 13).trimmingEnd(clip: t.clips[0].id, by: -20)
        t = try t.splitting(clip: t.clips[1].id, atFrame: t.clips[1].start + 45)
        t = try t.trimmingStart(clip: t.clips[2].id, by: 7)
        t = try t.splitting(clip: t.clips[3].id, atFrame: t.clips[3].start + 66)
        t = try t.moving(clip: t.clips[4].id, toIndex: 1)
        t = try t.trimmingStart(clip: t.clips[6].id, by: 9).lifting(clip: t.clips[6].id)
        let refs = t.clips.map { ExportJudge.ClipRef(file: names[$0.mediaID]!, start: $0.start, sourceIn: $0.sourceIn, length: $0.length) }
        let s = t.clips.map(\.start)
        let probes = Array(Set([0, 30, s[1] - 1, s[1], s[2], s[3], s[4] + 64, s[4] + 65, s[5] - 1, s[5], s[5] + 59, s[5] + 60, t.durationFrames - 1])).sorted()
        try await codeScenario("mixed", t, media: [n.id: n, p.id: p, v.id: v, f.id: f, h.id: h], refs: refs, probes: probes)
    }

    /// 여러 영상 레인(위 레인 [30,70)이 아래를 가림), 위 레인 빈틈, 끝 빈틈 20프레임
    func testLayeredLanesGapsAndTail() async throws {
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        let tb = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TB.mp4"))
        var t = Timeline().registering(ta).registering(tb)
        t = try t.inserting(media: ta.id)
        let top = UUID(), a2 = UUID()
        t = try t.addingLane(.video, name: "위", id: top).movingLane(top, by: -1).addingLane(.audio, name: "B 소리", id: a2)
        t = try t.placing(media: tb.id, at: 20, videoLane: top, audioLane: a2)
        let (l1, mid) = (UUID(), UUID())
        t = try t.splitting(clip: t.clips(inLane: top)[0].id, atFrame: 30, newIDs: (l1, mid)).lifting(clip: l1)
        let (keep, tail) = (UUID(), UUID())
        t = try t.splitting(clip: mid, atFrame: 70, newIDs: (keep, tail)).lifting(clip: tail)
        let (taL, taR) = (UUID(), UUID())
        t = try t.splitting(clip: t.clips(inLane: Lane.videoID)[0].id, atFrame: 100, newIDs: (taL, taR)).lifting(clip: taR)
        XCTAssertEqual(t.durationFrames, 120)
        let refs: [ExportJudge.ClipRef] = [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 30), .init(file: "otf-TB.mp4", start: 30, sourceIn: 10, length: 40),
                                           .init(file: "otf-TA.mp4", start: 70, sourceIn: 70, length: 30)]
        try await codeScenario("layered", t, media: [ta.id: ta, tb.id: tb], refs: refs, probes: [0, 29, 30, 69, 70, 99, 100, 119])
    }

    /// 변형: 판 3장(G 50% 위, R 40% 가운데, B 전체 아래 [0,60)), 격자·경계를 기본 합성기와 비교
    func testTransformsGridAndEdges() async throws {
        var a: [String: MediaAsset] = [:]
        for p in PlateFixture.all { a[p.file] = try await MediaProbe.inspect(fixtures.appendingPathComponent(p.file)) }
        let r = a[PlateFixture.red43.file]!, g = a[PlateFixture.green.file]!, b = a[PlateFixture.blue.file]!
        let lg = UUID(), lr = UUID(), bid = UUID()
        var t = Timeline().registering(b).registering(r).registering(g)
        t = try t.inserting(media: b.id, clipID: bid).trimmingEnd(clip: bid, by: -30)
        t = try t.addingLane(.video, name: "R", id: lr).movingLane(lr, by: -1).addingLane(.video, name: "G", id: lg).movingLane(lg, by: -2)
        t = try t.placing(media: r.id, at: 0, videoLane: lr, audioLane: nil).placing(media: g.id, at: 0, videoLane: lg, audioLane: nil)
        t = try t.settingTransform(clip: t.clips(inLane: lr)[0].id, ClipTransform(scalePermille: 400, offsetX: 400, offsetY: 200))
            .settingTransform(clip: t.clips(inLane: lg)[0].id, ClipTransform(scalePermille: 500, offsetX: 900, offsetY: 400))
        let media = [r.id: r, g.id: g, b.id: b]
        let layers = [OverlayJudge.Layer(file: PlateFixture.green.file, start: 0, length: 90, scalePermille: 500, offsetX: 900, offsetY: 400),
                      OverlayJudge.Layer(file: PlateFixture.red43.file, start: 0, length: 90, scalePermille: 400, offsetX: 400, offsetY: 200),
                      OverlayJudge.Layer(file: PlateFixture.blue.file, start: 0, length: 60, scalePermille: 1000, offsetX: 0, offsetY: 0)]
        let plan = try await CompositionPlanner.plan(t, media: media)
        let log = ExperimentalCompositorLog()
        let cplan = try custom(plan, log)
        var stats = PixelStats(), gridBad: [String] = [], edgeBad: [String] = []
        var colors: [String] = []
        let (na, nb) = try await lockstep(plan.composition, plan.videoComposition, cplan.videoComposition) { n, da, db in
            stats.add(da, db, frame: n)
            let fa = FrameCompare.copy(da), fb = FrameCompare.copy(db)
            if n == 0 || n == 60 {   // 판 안쪽 색(BGR): G 가운데, R 가운데, 왼쪽 위(파랑 또는 검정). 출력 버퍼 색 첨부·형식도 적는다
                colors.append("f\(n) tags default [\(Self.colorTags(da))] fmt \(CVPixelBufferGetPixelFormatType(da)) experimental [\(Self.colorTags(db))] fmt \(CVPixelBufferGetPixelFormatType(db))")
                for (name, x, y) in [("G", 1860, 940), ("R", 1360, 740), ("corner", 100, 100)] {
                    let i = (y * fa.width + x) * 4
                    colors.append("f\(n) \(name) default \(fa.bgra[i..<(i + 3)].map { $0 }) experimental \(fb.bgra[i..<(i + 3)].map { $0 })")
                }
            }
            let ga = OverlayJudge.judgeGrid(fa, frame: n, layers: layers), gb = OverlayJudge.judgeGrid(fb, frame: n, layers: layers)
            if !ga.mismatches.isEmpty || !gb.mismatches.isEmpty { gridBad.append("\(n): default \(ga.mismatches.prefix(3)) experimental \(gb.mismatches.prefix(3))") }
            for y in [300, 540, 700, 1000] {
                let ea = OverlayJudge.horizontalEdges(fa, y: y).map { "\($0.x)\($0.from)>\($0.to)" }, eb = OverlayJudge.horizontalEdges(fb, y: y).map { "\($0.x)\($0.from)>\($0.to)" }
                if ea != eb { edgeBad.append("\(n) y\(y): default \(ea) experimental \(eb)") }
            }
            for x in [500, 960, 1500, 1800] {
                let ea = OverlayJudge.verticalEdges(fa, x: x).map { "\($0.y)\($0.from)>\($0.to)" }, eb = OverlayJudge.verticalEdges(fb, x: x).map { "\($0.y)\($0.from)>\($0.to)" }
                if ea != eb { edgeBad.append("\(n) x\(x): default \(ea) experimental \(eb)") }
            }
        }
        note("transforms offline samples default \(na) experimental \(nb)")
        note("transforms plate colors (offline reader BGRA) \(colors)")
        // 내보낸 파일(H.264)의 같은 자리 색: 기본·실험 합성기로 각각 내보내 디코딩한다(사용자가 보는 결과)
        var exported: [String] = []
        for (which, p) in [("default", plan), ("experimental", try custom(plan, ExperimentalCompositorLog()))] {
            let dest = out.appendingPathComponent("colors-\(which).mp4")
            let outcome = await ExportService.export(p, to: .fromSavePanel(dest), sources: [r, g, b]) { _ in }
            XCTAssertEqual(outcome, .completed(dest))
            let fr = try await FrameCompare.decode(dest, frames: [0, 60])
            for n in [0, 60] {
                guard let f = fr[n] else { continue }
                for (name, x, y) in [("G", 1860, 940), ("R", 1360, 740), ("corner", 100, 100)] {
                    let i = (y * f.width + x) * 4
                    exported.append("\(which) f\(n) \(name) \(f.bgra[i..<(i + 3)].map { $0 })")
                }
            }
        }
        note("transforms plate colors (exported H.264, plate BGR G [60,200,40] R [40,40,220] B [220,60,40]) \(exported)")
        let both = try await exportBoth(plan, sources: [r, g, b], frames: [0, 30, 59, 60, 89], tag: "transforms")
        var expStats: [String] = []
        for n in [0, 30, 59, 60, 89] {
            guard let d = both.d[n], let e = both.e[n] else { expStats.append("\(n): missing"); continue }
            let st = Self.frameStats(d, e)
            let gd = OverlayJudge.judgeGrid(d, frame: n, layers: layers), ge = OverlayJudge.judgeGrid(e, frame: n, layers: layers)
            if !gd.mismatches.isEmpty || !ge.mismatches.isEmpty { gridBad.append("export \(n): default \(gd.mismatches.prefix(3)) experimental \(ge.mismatches.prefix(3))") }
            expStats.append(String(format: "%d: max %d hist %@ PSNR %.2f", n, st.maxDiff, "\(st.hist)", st.psnr))
        }
        note("transforms exported default vs experimental (H.264, 2-px sampled): \(expStats)")
        note("transforms grid mismatches \(gridBad)")
        note("transforms edge differences \(edgeBad.count): \(edgeBad.prefix(8))")
        note("transforms pixels default vs experimental: \(stats.summary)")
        XCTAssertEqual(na, nb)
        XCTAssertTrue(gridBad.isEmpty, "grid \(gridBad)")
        XCTAssertTrue(edgeBad.isEmpty, "edges \(edgeBad.prefix(8))")
        checkSources(log, "transforms offline")
    }

    /// 소수 크기·위치: 기본 합성기는 레이어 경계를 가장 가까운 픽셀 경계로 그린다(TransformTests 관찰). 실험 합성기의 경계를 같은 방법으로 잰다.
    func testFractionalEdges() async throws {
        let g = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.green.file))
        let b = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.blue.file))
        let top = UUID()
        var t = Timeline().registering(b).registering(g)
        t = try t.inserting(media: b.id).addingLane(.video, name: "G", id: top, outward: true)
        t = try t.placing(media: g.id, at: 0, videoLane: top, audioLane: nil)
        let gid = t.clips(inLane: top)[0].id
        func luma(_ r: Double, _ gg: Double, _ bb: Double) -> Double { 0.2126 * r + 0.7152 * gg + 0.0722 * bb }
        let mid = (luma(40, 200, 60) + luma(40, 60, 220)) / 2
        func edges(_ f: FrameCompare.Frame, y: Int) -> [Double] {
            let row = (0..<f.width).map { x -> Double in let i = (y * f.width + x) * 4; return luma(Double(f.bgra[i + 2]), Double(f.bgra[i + 1]), Double(f.bgra[i])) }
            var o: [Double] = []
            for x in 0..<(f.width - 1) where (row[x] - mid) * (row[x + 1] - mid) < 0 { o.append(Double(x) + 0.5 + (mid - row[x]) / (row[x + 1] - row[x])) }
            return o
        }
        for (x, label) in [(400.5, "x400.5"), (401.0, "x401")] {
            let tt = try t.settingTransform(clip: gid, ClipTransform(scale: 0.4005, x: x, y: -200.25))
            let plan = try await CompositionPlanner.plan(tt, media: [g.id: g, b.id: b])
            let cplan = try custom(plan, ExperimentalCompositorLog())
            var ea: [Double] = [], eb: [Double] = [], at = -1
            _ = try await lockstep(plan.composition, plan.videoComposition, cplan.videoComposition) { n, da, db in
                guard at < 0 else { return }   // 첫 표본(판은 움직이지 않음)
                at = n; ea = edges(FrameCompare.copy(da), y: 340); eb = edges(FrameCompare.copy(db), y: 340)
            }
            note("fractional \(label) frame \(at) edges y340 (offline): default \(ea.map { String(format: "%.3f", $0) }) experimental \(eb.map { String(format: "%.3f", $0) })")
            let both = try await exportBoth(plan, sources: [g, b], frames: [30], tag: "fractional-\(label)")
            if let d = both.d[30], let e = both.e[30] {
                let xd = edges(d, y: 340), xe = edges(e, y: 340)
                note("fractional \(label) frame 30 edges y340 (exported): default \(xd.map { String(format: "%.3f", $0) }) experimental \(xe.map { String(format: "%.3f", $0) })")
                if xd.count == 2, xe.count == 2 {
                    XCTAssertEqual(xe[0], xd[0], accuracy: 0.15, "\(label) exported left edge"); XCTAssertEqual(xe[1], xd[1], accuracy: 0.15, "\(label) exported right edge")
                } else { XCTFail("\(label) exported edges \(xd) \(xe)") }
            }
            XCTAssertEqual(ea.count, 2); XCTAssertEqual(eb.count, 2)
            if ea.count == 2, eb.count == 2 {
                // 같은 경계 측정법의 기존 정밀도(TransformTests, 0.15 px)로 같은 픽셀 경계인지 본다
                XCTAssertEqual(eb[0], ea[0], accuracy: 0.15, "\(label) left edge"); XCTAssertEqual(eb[1], ea[1], accuracy: 0.15, "\(label) right edge")
            }
        }
    }

    /// 회전 원본: 기존 otf-rot90은 단색 회색이라 방향을 판정할 수 없다(2026-10-12 첫 실행에서 확인). 그래서 같은 크기·같은 회전 표시(90°)에
    /// 비대칭 표식(원본 왼쪽 위 1/4 흰색, 나머지 어두운 회색)을 넣은 원본을 이 테스트의 일회용 폴더에 만든다.
    /// 손 계산: 원본 (x, y) → 표시 (360 − y, x)이므로 원본 왼쪽 위 사분면은 표시 오른쪽 위 사분면. 맞춤: 360×640 → 607.5×1080, 가운데(x 656.25–1263.75).
    func testRotatedSourceOrientation() async throws {
        let url = out.appendingPathComponent("rot90-marker.mp4")
        let wr = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        i.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        i.expectsMediaDataInRealTime = false
        wr.add(i)
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                                                         kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        XCTAssertTrue(wr.startWriting()); wr.startSession(atSourceTime: .zero)
        for k in 0..<30 {
            while !i.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<360 { for x in 0..<640 { let v: UInt8 = (x < 320 && y < 180) ? 235 : 60; let o = y * bpr + x * 4; base[o] = v; base[o + 1] = v; base[o + 2] = v; base[o + 3] = 255 } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            XCTAssertTrue(ad.append(buf, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: 30)))
        }
        i.markAsFinished(); wr.endSession(atSourceTime: CMTime(value: 30, timescale: 30)); await wr.finishWriting()
        XCTAssertEqual(wr.status, .completed)
        let rot = try await MediaProbe.inspect(url)
        let t = try Timeline().registering(rot).inserting(media: rot.id)
        let plan = try await CompositionPlanner.plan(t, media: [rot.id: rot])
        let log = ExperimentalCompositorLog()
        let cplan = try custom(plan, log)
        /// 밝은 화소(> 150)의 경계 상자: 표시 오른쪽 위 사분면(x 960–1263.75, y 0–540)이어야 한다
        func bright(_ f: FrameCompare.Frame) -> String {
            var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
            for y in stride(from: 0, to: f.height, by: 2) { for x in stride(from: 0, to: f.width, by: 2) where f.bgra[(y * f.width + x) * 4 + 1] > 150 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            } }
            return x1 < 0 ? "none" : "x \(x0)–\(x1) y \(y0)–\(y1)"
        }
        var stats = PixelStats(), boxes: [String] = []
        _ = try await lockstep(plan.composition, plan.videoComposition, cplan.videoComposition) { n, da, db in
            stats.add(da, db, frame: n)
            guard boxes.isEmpty else { return }
            let ba = bright(FrameCompare.copy(da)), bb = bright(FrameCompare.copy(db))
            boxes.append("offline frame \(n) marker default \(ba) experimental \(bb)")
        }
        let both = try await exportBoth(plan, sources: [rot], frames: [15], tag: "rot")
        if let d = both.d[15], let e = both.e[15] {
            boxes.append("exported frame 15 marker default \(bright(d)) experimental \(bright(e))")
            let st = Self.frameStats(d, e)
            boxes.append(String(format: "exported frame 15 default vs experimental max %d hist %@ PSNR %.2f", st.maxDiff, "\(st.hist)", st.psnr))
            XCTAssertEqual(bright(d), bright(e), "marker position default vs experimental")
        }
        note("rotated \(boxes)")
        note("rotated pixels default vs experimental (offline): \(stats.summary)")
        checkSources(log, "rotated offline")
    }

    /// 취소·연속 요청: 프리뷰에서 기다리지 않는 정확 탐색을 연달아 보낸 뒤 마지막 탐색의 프레임이 맞는가
    @MainActor func testSeekBurstCancellation() async throws {
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        let tb = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TB.mp4"))
        let t = try Timeline().registering(ta).registering(tb).inserting(media: ta.id).inserting(media: tb.id)
        let plan = try await CompositionPlanner.plan(t, media: [ta.id: ta, tb.id: tb])
        let log = ExperimentalCompositorLog()
        let cplan = try custom(plan, log)
        let item = AVPlayerItem(asset: cplan.composition)
        item.videoComposition = cplan.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        let deadline = Date().addingTimeInterval(10)
        while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        let (expected, _) = try ExportJudge.expectations([.init(file: "otf-TA.mp4", sourceIn: 0, length: 120), .init(file: "otf-TB.mp4", sourceIn: 0, length: 120)])
        var results: [String] = []
        for round in 0..<3 {
            // 기다리지 않는 탐색 25개(앞의 것은 끊긴다), 마지막만 기다린다
            let burst = (0..<25).map { (round * 37 + $0 * 11) % 240 }
            for n in burst.dropLast() { player.seek(to: CMTime(value: CMTimeValue(n), timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero) { _ in } }
            let last = burst.last!, tm = CMTime(value: CMTimeValue(last), timescale: 30)
            _ = await player.seek(to: tm, toleranceBefore: .zero, toleranceAfter: .zero)
            var got = "none"
            let end = Date().addingTimeInterval(3)
            while Date() < end {
                if output.hasNewPixelBuffer(forItemTime: tm) {
                    var shown = CMTime.invalid
                    if let pb = output.copyPixelBuffer(forItemTime: tm, itemTimeForDisplay: &shown), abs((shown - tm).seconds) < 0.0005 {
                        got = ExportJudge.label(E2Metrics.measure(pb)); break
                    }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            results.append("round \(round) last \(last) got \(got) expected \(expected[last].label)")
            XCTAssertEqual(got, expected[last].label, "burst round \(round)")
        }
        player.replaceCurrentItem(with: nil)
        note("seek burst: \(results)")
        checkSources(log, "seek burst")
    }
}
