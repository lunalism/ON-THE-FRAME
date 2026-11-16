import AVFoundation
import CoreGraphics
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 스펙트럼 내보내기 점검(2026-10-25, docs/SPECTRUM-DESIGN.md §12). 시험 설정의 그리기(모양·방향·색)는 제품 결정이 아니다.
/// 소스는 명시한 한 조각(aud-wav48s 클립: 타임라인 20에서 시작, 원본 10프레임 잘라 냄, 길이 50)뿐이다 — 계보·겹침 규칙(D-S8)은 정하지 않는다.
final class SpectrumExportCheckpointTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var out: URL!
    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        out = ExportEndToEndTests.root.appendingPathComponent("spectrum-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: out) }

    static let baseline: CGFloat = 880, maxHeight: CGFloat = 160
    /// 시험 설정(제품 기본값 아님, D-S5): 기준선 y 880, x 192–1728, 최대 높이 160, 두께 6, 흰색
    func style(_ m: SpectrumStyle.Mode, _ s: SpectrumStyle.Sides) -> SpectrumStyle {
        SpectrumStyle(start: CGPoint(x: 192, y: Self.baseline), end: CGPoint(x: 1728, y: Self.baseline), maxHeight: Double(Self.maxHeight), thickness: 6, mode: m, sides: s)
    }
    /// 그리기 코드와 따로 쓴 기대 기하(1080p): 밴드 i의 x = 192 + 1536·(i + 0.5)/64, 높이 = 값 × 160, 위 = y 감소
    static func expectedX(_ i: Int) -> Int { Int((192 + 1536 * (Double(i) + 0.5) / 64).rounded()) }
    static func expectedH(_ v: Float) -> Int { Int((Double(v) * Double(maxHeight)).rounded()) }
    /// 기대 기하와 어긋난 곳(설명 목록). painted(x, y): 그 화소가 칠해졌는가(캔버스 알파 또는 인코딩 전 밝기 증가).
    /// 디지털: 기대 x 열에서 기준선 위·아래로 이어 칠한 길이 = 기대 높이 ±4(두께/2 + 1) 또는 0. 아날로그: 기대 점(기준선 ∓ 높이)이 칠해짐, 반대쪽 같은 높이는 비어 있음.
    static func geometryFailures(_ v: [Float], mode: SpectrumStyle.Mode, sides: SpectrumStyle.Sides, bands: [Int], painted: (Int, Int) -> Bool) -> [String] {
        let base = Int(baseline), up = sides != .below, down = sides != .above
        var f: [String] = []
        for i in bands {
            let x = expectedX(i), h = expectedH(v[i])
            switch mode {
            case .digital:
                let top = (1...(Int(maxHeight) + 10)).prefix { painted(x, base - $0) }.count, bot = (1...(Int(maxHeight) + 10)).prefix { painted(x, base + $0) }.count
                if abs(top - (up ? h : 0)) > (up ? 4 : 0) { f.append("band \(i) up run \(top) vs \(up ? h : 0)") }
                if abs(bot - (down ? h : 0)) > (down ? 4 : 0) { f.append("band \(i) down run \(bot) vs \(down ? h : 0)") }
            case .analog:
                guard h > 8 else { continue }   // 기준선 근처는 두 방향이 겹쳐 가를 수 없음
                if painted(x, base - h) != up { f.append("band \(i) point above \(painted(x, base - h))") }
                if painted(x, base + h) != down { f.append("band \(i) point below \(painted(x, base + h))") }
            }
        }
        return f
    }
    let settings = SpectrumAnalysisSettings(windowMs: 90, offsetMs: 0, bands: 64, lowHz: 20, highHz: 2000, floorDB: -60)

    struct Fixture { let plan: PlannedComposition; let sources: [MediaAsset]; let piece: SpectrumSourcePiece; let source: SpectrumFileSource; let subtitle: SubtitleItem? }
    /// otf-TA 영상 120프레임 + aud-wav48s 소리 클립(20에서, 원본 10부터, 50프레임). 자막(선택): 40–60프레임, 불투명 빨간 배경 상자가 스펙트럼 기준선(y 880)에 걸침.
    func fixture(subtitle: Bool) async throws -> Fixture {
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        let w = try await MediaProbe.inspect(fixtures.appendingPathComponent(AudioFixture.wav.file))
        let clip = Clip(mediaID: w.id, start: 20, sourceIn: 10, length: 50, lane: Lane.audioID)
        var t = Timeline(clips: [Clip(mediaID: ta.id, start: 0, sourceIn: 0, length: 120)], audioClips: [clip], lanes: Lane.defaults)
        for a in [ta, w] { t = t.registering(a) }
        var item: SubtitleItem?
        if subtitle {
            var st = SubtitleStyle.default
            st.yMilli = 920_000
            st.background = SubtitleBackground(enabled: true, red: 255, green: 0, blue: 0, alpha: 255, padXTenths: 200, padYTenths: 300, radiusTenths: 0)
            let sl = UUID()
            t = try t.addingLane(.subtitle, name: "S", id: sl, outward: true).addingSubtitle(lane: sl, at: 40, length: 20, text: "가나다라마바사아자차카타파하", style: st)
            item = t.renderedSubtitles.first
        }
        XCTAssertTrue(t.isValid)
        let plan = try await CompositionPlanner.plan(t, media: [ta.id: ta, w.id: w])
        let lane = t.lanes.first { $0.id == Lane.audioID }!
        let src = try await SpectrumFileSource.open(url: w.url, mediaID: w.id)
        return Fixture(plan: plan, sources: [ta, w], piece: SpectrumSourcePiece(clip: clip, lane: lane), source: src, subtitle: item)
    }
    func direct(_ f: Fixture, _ k: Int) async throws -> [Float] {
        var d: [Int: [[Float]]] = [:]
        for c in try SpectrumAnalysis.chunks(frame: k, pieces: [f.piece], fps: 30, rate: 48_000, settings: settings, chunkSamples: f.source.chunkSamples) { d[c] = try await f.source.decodeChunk(c) }
        return try SpectrumAnalysis.bands(frame: k, pieces: [f.piece], fps: 30, rate: 48_000, channelCount: f.source.channelCount, chunkSamples: f.source.chunkSamples, settings: settings) { d[$0] }
    }
    var band440: Int { SpectrumAnalysis.bandIndex(ofHz: 440, settings: settings) }
    var bandHigh: Int { SpectrumAnalysis.bandIndex(ofHz: 1800, settings: settings) }

    /// 분석(제품 엔진)의 옮긴·자른 소스 대응: 음·무음·소리 사건. 클릭 원본 표본 12345는 잘라 낸 부분(원본 10프레임 = 16000표본 앞)이라 없고,
    /// 60000은 타임라인 표본 20·1600 + (60000 − 16000) = 76000 → 프레임 47·48의 창에 든다.
    func testMovedTrimmedSourceToneSilenceAndEvent() async throws {
        let f = try await fixture(subtitle: false)
        let s = SpectrumAnalysisScheduler()
        func b(_ k: Int) async throws -> [Float] { try await s.bands(SpectrumFrameRequest(frame: k, fps: 30, settings: settings, pieces: [f.piece]), from: f.source) }
        for k in [0, 10, 18, 72, 100, 119] { let v = try await b(k); XCTAssertEqual(v.max()!, 0, "무음(클립 밖) frame \(k)") }
        let tone = try await b(35)
        XCTAssertEqual(tone.indices.max { tone[$0] < tone[$1] }!, band440)
        XCTAssertEqual(tone[band440], Float((20 * log10(0.2) + 60) / 60), accuracy: 0.02)
        let h45 = try await b(45)[bandHigh], h47 = try await b(47)[bandHigh], h48 = try await b(48)[bandHigh], h22 = try await b(22)[bandHigh]
        print("SPECTRUM checkpoint click band: f22 \(h22) f45 \(h45) f47 \(h47) f48 \(h48)")
        XCTAssertGreaterThan(h48, h45 + 0.15); XCTAssertGreaterThan(h47, h45 + 0.1)
        XCTAssertLessThan(h22, h45 + 0.05, "잘라 낸 클릭(원본 12345)은 보이지 않음")
        for k in [30, 47, 60] { let v = try await b(k); let d = try await direct(f, k); XCTAssertEqual(v, d, "일정 = 바로 계산 frame \(k)") }
    }

    /// 여섯 조합(디지털·아날로그 × 위·거울·아래)의 기하: 그리기 코드와 따로 쓴 기대 기하로 확인. 칠한 화소는 미리 계산한 범위 안.
    /// 음성 대조: 방향을 뒤집은 것·높이 0.8배·x 12 px 옮김·기준선 10 px 옮김을 그려 같은 확인이 실패하는지 본다(확인이 틀린 기하를 놓치지 않음).
    func testSixStyleDirectionGeometry() throws {
        let canvas = try SpectrumCanvas(width: 1920, height: 1080)
        let v: [Float] = (0..<64).map { i in i % 8 == 0 ? 0 : (i % 3 == 0 ? 0.9 : 0.35) }
        let bands = [1, 3, 9, 12, 21, 33, 45]
        func painted(_ x: Int, _ y: Int) -> Bool { canvas.pixel(x: x, y: y) != 0 }
        for m in [SpectrumStyle.Mode.digital, .analog] { for sd in [SpectrumStyle.Sides.above, .mirrored, .below] {
            let st = style(m, sd)
            let r = try XCTUnwrap(try canvas.render(v, style: st), "\(m) \(sd)")
            XCTAssertEqual(canvas.paintedPixels(outside: r.bounds), 0, "범위 밖 칠함 \(m) \(sd)")
            XCTAssertEqual(Self.geometryFailures(v, mode: m, sides: sd, bands: bands, painted: painted), [], "\(m) \(sd)")
            var flipped = st; flipped.sides = sd == .above ? .below : (sd == .below ? .above : .above)
            var short = st; short.maxHeight *= 0.8
            var shifted = st; shifted.start.x += 12; shifted.end.x += 12
            var lowered = st; lowered.start.y += 10; lowered.end.y += 10
            for (name, bad) in [("flipped", flipped), ("amplitude 0.8", short), ("x +12", shifted), ("baseline +10", lowered)] {
                _ = try canvas.render(v, style: bad)
                XCTAssertFalse(Self.geometryFailures(v, mode: m, sides: sd, bands: bands, painted: painted).isEmpty, "음성 대조 \(name)를 \(m) \(sd) 확인이 잡아야 함")
            }
        } }
        // 모두 0인 밴드: 디지털은 그리지 않음, 아날로그는 기준선 선 하나(시제품 그리기 규칙 그대로 — 제품 결정 아님)
        let zero = [Float](repeating: 0, count: 64)
        XCTAssertNil(try canvas.render(zero, style: style(.digital, .mirrored)))
        let az = try XCTUnwrap(try canvas.render(zero, style: style(.analog, .mirrored)))
        XCTAssertLessThanOrEqual(az.bounds.height, 10)
    }

    /// 엔진 그리기 = 시제품 그리기(같은 입력 → 같은 바이트, 전체 캔버스), 1080p·4K
    func testEngineRendererMatchesPrototypeBytes() throws {
        var rng = SystemRandomNumberGenerator()
        for (w, h) in [(1920, 1080), (3840, 2160)] {
            let canvas = try SpectrumCanvas(width: w, height: h)
            for m in [SpectrumStyle.Mode.digital, .analog] { for sd in [SpectrumStyle.Sides.above, .mirrored, .below] {
                let v = (0..<64).map { _ in Float.random(in: 0...1, using: &rng) }
                let st = style(m, sd)
                var ps = ProtoSpectrumStyle(); ps.start = st.start; ps.end = st.end; ps.maxHeight = CGFloat(st.maxHeight); ps.thickness = CGFloat(st.thickness)
                ps.mode = m == .digital ? .digital : .analog; ps.sides = sd == .above ? .above : (sd == .mirrored ? .mirrored : .below)
                let proto = ProtoSpectrumRenderer.render(v, style: ps, canvas: CGSize(width: w, height: h))
                _ = try canvas.render(v, style: st)
                let pp = proto.data!.assumingMemoryBound(to: UInt32.self)
                var diff = 0
                for y in 0..<h { for x in 0..<w where pp[y * w + x] != canvas.pixel(x: x, y: y) { diff += 1 } }
                XCTAssertEqual(diff, 0, "\(w)x\(h) \(m) \(sd)")
            } }
        }
    }

    /// 잘못된 입력은 그리지 않고 오류(캔버스 크기·모양·값)
    func testRendererRejectsInvalidInput() throws {
        XCTAssertThrowsError(try SpectrumCanvas(width: 7680, height: 4320)); XCTAssertThrowsError(try SpectrumCanvas(width: 0, height: 1080))
        let c = try SpectrumCanvas(width: 1920, height: 1080), ok = style(.digital, .above)
        var bad = ok; bad.thickness = 0; XCTAssertThrowsError(try c.render([0.5], style: bad))
        bad = ok; bad.end = bad.start; XCTAssertThrowsError(try c.render([0.5], style: bad))
        bad = ok; bad.red = 2; XCTAssertThrowsError(try c.render([0.5], style: bad))
        bad = ok; bad.maxHeight = .nan; XCTAssertThrowsError(try c.render([0.5], style: bad))
        XCTAssertThrowsError(try c.render([], style: ok)); XCTAssertThrowsError(try c.render([.nan], style: ok)); XCTAssertThrowsError(try c.render([1.5], style: ok))
        XCTAssertThrowsError(try c.render([Float](repeating: 0.1, count: 1025), style: ok))
    }

    /// 앞서 본 "범위만 그린 작은 문맥 ≠ 전체 캔버스 그림"(≤ 7/255)의 성질을 잰다 — 이 점검은 그 최적화를 쓰지 않는다. 같다고 주장하지 않는다.
    func testBoundedContextDifferencesAreRecordedNotAssumed() {
        let canvas = CGSize(width: 1920, height: 1080)
        var rng = SystemRandomNumberGenerator()
        var cases = 0, differ = 0, maxD = 0, edgeOnly = 0, translatedDiffer = 0
        for m in [ProtoSpectrumStyle.Mode.digital, .analog] { for sd in [ProtoSpectrumStyle.Sides.above, .mirrored, .below] { for _ in 0..<3 {
            var st = ProtoSpectrumStyle(); st.start = CGPoint(x: 192, y: Self.baseline); st.end = CGPoint(x: 1728, y: Self.baseline)
            st.maxHeight = Self.maxHeight; st.thickness = 6; st.mode = m; st.sides = sd
            let v = (0..<64).map { _ in Float.random(in: 0...1, using: &rng) }
            let full = ProtoSpectrumRenderer.render(v, style: st, canvas: canvas)
            guard let b = ProtoSpectrumRenderer.renderBounded(v, style: st, canvas: canvas) else { continue }
            // 같은 원점 이동을 전체 크기 문맥에 한 것(문맥 크기만 같고 원점은 범위와 같음) — 차이가 원점 때문인지 문맥 크기 때문인지 가르기
            let moved = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            moved.translateBy(x: 0, y: 1080); moved.scaleBy(x: 1, y: -1); moved.translateBy(x: -b.rect.minX, y: -b.rect.minY)
            ProtoSpectrumRenderer.draw(v, style: st, canvas: canvas, into: moved)
            let fp = full.data!.assumingMemoryBound(to: UInt8.self), mp = moved.data!.assumingMemoryBound(to: UInt8.self)
            let bd = b.image.dataProvider!.data! as Data, bbpr = b.image.bytesPerRow
            var caseDiff = 0, caseEdge = true, caseMoved = 0
            bd.withUnsafeBytes { (bp: UnsafeRawBufferPointer) in
                for y in 0..<b.image.height { for x in 0..<b.image.width { for ch in 0..<4 {
                    let fy = Int(b.rect.minY) + y, fx = Int(b.rect.minX) + x
                    let a = Int(fp[(fy * 1920 + fx) * 4 + ch]), c = Int(bp[y * bbpr + x * 4 + ch]), mv = Int(mp[(y * 1920 + x) * 4 + ch])
                    if a != c { caseDiff += 1; maxD = max(maxD, abs(a - c)); if fp[(fy * 1920 + fx) * 4 + 3] == 255 && bp[y * bbpr + x * 4 + 3] == 255 { caseEdge = false } }
                    if mv != c { caseMoved += 1 }
                } } }
            }
            cases += 1; differ += caseDiff; if caseEdge { edgeOnly += 1 }; translatedDiffer += caseMoved
        } } }
        print("SPECTRUM bounded-vs-full: cases \(cases) differing bytes \(differ) max \(maxD) cases-with-edge-only-differences \(edgeOnly) bounded-vs-full-size-same-origin differing bytes \(translatedDiffer)")
        XCTAssertGreaterThan(cases, 0)
    }

    /// 상한 있는 실행(느림 재발 대비): 120 s를 넘으면 취소하고 단계 기록과 함께 실패
    func boundedExport(_ f: Fixture, _ st: SpectrumStyle, to d: ExportDestination, options: ExportService.Options = .init(), capture: Set<Int> = [],
                       scheduler: SpectrumAnalysisScheduler = SpectrumAnalysisScheduler(), limit: Double = 120) async -> (ExportOutcome, SpectrumCheckpointExport.Stats, [SpectrumCheckpointExport.Captured]) {
        let sp = SpectrumCheckpointExport.Spectrum(source: f.source, pieces: [f.piece], settings: settings, style: st)
        let plan = f.plan, sources = f.sources
        let task = Task { await SpectrumCheckpointExport.export(plan, spectrum: sp, to: d, sources: sources, options: options, capture: capture, scheduler: scheduler) }
        let dog = Task { try await Task.sleep(nanoseconds: UInt64(limit * 1e9)); task.cancel(); print("SPECTRUM checkpoint export exceeded \(limit) s — cancelled") }
        let r = await task.value
        dog.cancel()
        print("SPECTRUM checkpoint stages: \(r.1.stages)")
        return r
    }
    static func barRun(_ s: [UInt8], _ p: [UInt8], x: Int, from y0: Int, step: Int, max n: Int) -> Int {
        (0..<n).prefix { d in let y = y0 + step * d; return y >= 0 && y < 1080 && Int(s[y * 1920 + x]) - Int(p[y * 1920 + x]) > 40 }.count
    }

    /// 실제 인코딩·디코딩(디지털 거울 + 자막 위): 인코딩 전 확인과 인코딩 뒤 차이를 따로 본다. 비교 기준은 같은 계획의 제품 구조 R 출력(스펙트럼 없음).
    func testDigitalMirroredExportWithSubtitleAbove() async throws {
        let f = try await fixture(subtitle: true)
        let dest = out.appendingPathComponent("spectrum-digital.mp4"), plainURL = out.appendingPathComponent("plain.mp4")
        let frames: Set<Int> = [5, 35, 45, 47, 48, 50, 100]
        let sched = SpectrumAnalysisScheduler()
        let (o, stats, cap) = await boundedExport(f, style(.digital, .mirrored), to: .fromSavePanel(dest), capture: frames, scheduler: sched)
        XCTAssertEqual(o, .completed(dest))
        try await SubtitleExporter.encode(f.plan, to: plainURL, failAfterFraction: nil) { _ in }
        print(String(format: "SPECTRUM checkpoint digital: frames %d spectrumFrames %d per-frame wait %.2f render %.2f composite %.2f ms, total %.0f ms, peakAhead %d, footprint MB before %.1f peak %.1f after %.1f",
                     stats.frames, stats.wroteSpectrumFrames, stats.waitMs / Double(max(1, stats.frames)), stats.renderMs / Double(max(1, stats.frames)),
                     stats.compositeMs / Double(max(1, stats.frames)), stats.totalMs, stats.peakAhead, stats.footprintBeforeMB, stats.footprintPeakMB, stats.footprintAfterMB))
        XCTAssertEqual(stats.frames, 120); XCTAssertLessThanOrEqual(stats.peakAhead, 16)
        // 인코딩 전
        let raster = try XCTUnwrap(f.subtitle.map { SubtitleRenderer.shared.raster($0) })
        let subRect = raster.drawRect.insetBy(dx: -2, dy: -2)
        XCTAssertEqual(Set(cap.map(\.k)), frames)
        for c in cap {
            let d = try await direct(f, c.k)
            XCTAssertEqual(c.bands, d, "내보내기 분석 = 바로 계산 frame \(c.k)")
            XCTAssertEqual(c.paintedOutsideBounds, 0)
            let subVisible = (40..<60).contains(c.k)
            if d.max()! == 0 && !subVisible { XCTAssertTrue(c.out.y == c.src.y && c.out.c == c.src.c, "무음 프레임은 영상 그대로 frame \(c.k)") }
            let region = (c.spectrumBounds.isNull ? CGRect.null : c.spectrumBounds.insetBy(dx: -2, dy: -2)).union(subVisible ? subRect : .null)
            var outside = 0
            for y in 0..<1080 { for x in 0..<1920 where !region.contains(CGPoint(x: x, y: y)) { if c.out.y[y * 1920 + x] != c.src.y[y * 1920 + x] { outside += 1 } } }
            for j in 0..<540 { for k in 0..<960 where !region.contains(CGPoint(x: 2 * k, y: 2 * j)) {
                if c.out.c[j * 1920 + 2 * k] != c.src.c[j * 1920 + 2 * k] || c.out.c[j * 1920 + 2 * k + 1] != c.src.c[j * 1920 + 2 * k + 1] { outside += 1 } } }
            XCTAssertEqual(outside, 0, "그림 범위 밖 4:2:0 값 그대로 frame \(c.k)")
        }
        // 자막이 스펙트럼 위: 자막 래스터가 불투명(알파 255)인 화소는 스펙트럼이 그 자리를 칠했어도 자막 값 그대로(인코딩 전)
        let c50 = try XCTUnwrap(cap.first { $0.k == 50 })
        let canvas = try SpectrumCanvas(width: 1920, height: 1080)
        _ = try canvas.render(c50.bands, style: style(.digital, .mirrored))
        let img = raster.image, idata = img.dataProvider!.data! as Data, ibpr = img.bytesPerRow
        var both = 0, wrong = 0
        idata.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<img.height { for x in 0..<img.width {
                let fx = Int(raster.drawRect.minX) + x, fy = Int(raster.drawRect.minY) + y, o = y * ibpr + x * 4
                guard fx >= 0, fx < 1920, fy >= 0, fy < 1080, p[o + 3] == 255, canvas.pixel(x: fx, y: fy) != 0 else { continue }
                both += 1
                let yp = 0.2126 * Double(p[o + 2]) / 255 + 0.7152 * Double(p[o + 1]) / 255 + 0.0722 * Double(p[o]) / 255
                if abs(Int(c50.out.y[fy * 1920 + fx]) - Int((16 + 219 * yp).rounded())) > 1 { wrong += 1 }
            } }
        }
        print("SPECTRUM checkpoint subtitle-over-spectrum: opaque subtitle pixels also painted by spectrum \(both), wrong \(wrong)")
        XCTAssertGreaterThan(both, 100, "점검이 의미 있으려면 자막 불투명 화소와 스펙트럼이 겹쳐야 함")
        XCTAssertEqual(wrong, 0, "겹친 곳은 자막 값(자막이 스펙트럼 위)")
        // 인코딩 전 기하(따로 쓴 기대 기하, 출력 버퍼의 밝기 증가로): 자막이 없는 프레임만(자막 상자가 기준선 열을 덮음)
        for c in cap where !(40..<60).contains(c.k) {
            XCTAssertEqual(Self.geometryFailures(c.bands, mode: .digital, sides: .mirrored, bands: [band440, bandHigh, 20, 30],
                                                 painted: { x, y in Int(c.out.y[y * 1920 + x]) - Int(c.src.y[y * 1920 + x]) > 40 }), [], "인코딩 전 기하 frame \(c.k)")
        }
        // 인코딩 뒤: 막대 길이(밴드 열)와 프레임 시점, 스펙트럼 밖 차이(손실 인코딩)
        let a = try await SubtitleExportTests.planes(plainURL, frames), b = try await SubtitleExportTests.planes(dest, frames)
        let base = Int(Self.baseline)
        var lens: [String] = []
        for k in [35, 45, 47, 48] {   // 자막이 보이는 45–48은 440 Hz 열(x ≈ 1212)을 자막 상자가 덮어 기준과 같으므로 높은 밴드만
            let c = cap.first { $0.k == k }!
            for i in (k == 35 ? [band440, bandHigh] : [bandHigh]) {
                let x = Self.expectedX(i), h = Self.expectedH(c.bands[i])
                let up = Self.barRun(b[k]!.y, a[k]!.y, x: x, from: base - 1, step: -1, max: 200), down = Self.barRun(b[k]!.y, a[k]!.y, x: x, from: base + 1, step: 1, max: 200)
                lens.append("f\(k) b\(i) exp \(h) up \(up) down \(down)")
                XCTAssertEqual(up, h, accuracy: 8, "디코딩 막대(위) f\(k) b\(i)"); XCTAssertEqual(down, h, accuracy: 8, "디코딩 막대(아래) f\(k) b\(i)")
            }
        }
        print("SPECTRUM checkpoint decoded bars: \(lens)")
        let xh = Self.expectedX(bandHigh)
        XCTAssertGreaterThan(Self.barRun(b[48]!.y, a[48]!.y, x: xh, from: base - 1, step: -1, max: 200), Self.barRun(b[45]!.y, a[45]!.y, x: xh, from: base - 1, step: -1, max: 200) + 20,
                             "디코딩 출력에서도 소리 사건 프레임(48)의 높은 밴드가 더 김(프레임 시점)")
        for k in [5, 100] {   // 무음 프레임: 스펙트럼 영역에 막대 없음(기준과 차이 작음)
            var mx = 0; for y in 700..<1060 { for x in 150..<1770 { mx = max(mx, abs(Int(b[k]!.y[y * 1920 + x]) - Int(a[k]!.y[y * 1920 + x]))) } }
            print("SPECTRUM checkpoint silent frame \(k) max |ΔY| in spectrum area \(mx)")
            XCTAssertLessThan(mx, 40, "무음 frame \(k)")
        }
        let union = cap.map(\.spectrumBounds).filter { !$0.isNull }.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -16, dy: -16)
        var sumOut = 0, cnt = 0, maxOut = 0, big = 0
        for k in frames { for y in stride(from: 0, to: 1080, by: 2) { for x in stride(from: 0, to: 1920, by: 2) where !union.contains(CGPoint(x: x, y: y)) && !subRect.insetBy(dx: -16, dy: -16).contains(CGPoint(x: x, y: y)) {
            let dd = abs(Int(a[k]!.y[y * 1920 + x]) - Int(b[k]!.y[y * 1920 + x])); sumOut += dd; cnt += 1; maxOut = max(maxOut, dd); if dd > 3 { big += 1 }
        } } }
        let meanOut = Double(sumOut) / Double(max(1, cnt))
        print(String(format: "SPECTRUM checkpoint encoded outside spectrum/subtitle (+16 px): mean |ΔY| %.4f max %d share >3 %.4f%%", meanOut, maxOut, Double(big) / Double(max(1, cnt)) * 100))
        XCTAssertLessThan(meanOut, 1.0, "손실 인코딩 차이는 작아야 함(기록값은 문서)")
        // 소리: 같은 소리 경로 — 스펙트럼 출력 = 기준 출력, 클릭(76000) 자리
        let da = try await E2Decoder.decode(plainURL), db = try await E2Decoder.decode(dest)
        XCTAssertEqual(da.mono.count, db.mono.count)
        let maxA = zip(da.mono, db.mono).map { abs($0 - $1) }.max() ?? 1
        let on = E2Decoder.onsets(db.mono)
        print("SPECTRUM checkpoint audio: samples \(db.mono.count) max |Δ| vs plain \(maxA) onsets \(on)")
        XCTAssertLessThanOrEqual(maxA, 1e-6, "소리는 기준 구조 R 출력과 같음")
        XCTAssertEqual(on.count, 1); XCTAssertEqual(on.first ?? 0, 76_000, accuracy: 16)
        XCTAssertEqual(sched.statistics.waiters, 0)
    }

    /// 실제 인코딩·디코딩(아날로그 위, 자막 없음): 디코딩 꺾은선 자리 = 기준선 − 높이, 프레임 시점
    func testAnalogAboveExport() async throws {
        let f = try await fixture(subtitle: false)
        let dest = out.appendingPathComponent("spectrum-analog.mp4"), plainURL = out.appendingPathComponent("plain.mp4")
        let frames: Set<Int> = [35, 45, 48]
        let (o, stats, cap) = await boundedExport(f, style(.analog, .above), to: .fromSavePanel(dest), capture: frames)
        XCTAssertEqual(o, .completed(dest))
        print(String(format: "SPECTRUM checkpoint analog: total %.0f ms footprint MB peak %.1f", stats.totalMs, stats.footprintPeakMB))
        try await SubtitleExporter.encode(f.plan, to: plainURL, failAfterFraction: nil) { _ in }
        let a = try await SubtitleExportTests.planes(plainURL, frames), b = try await SubtitleExportTests.planes(dest, frames)
        let base = Int(Self.baseline)
        for c in cap {   // 인코딩 전 기하(따로 쓴 기대 기하) — 무게 중심 일치만으로는 틀린 기하를 못 잡으므로 먼저 본다
            XCTAssertEqual(Self.geometryFailures(c.bands, mode: .analog, sides: .above, bands: [band440, bandHigh, 30, 40],
                                                 painted: { x, y in Int(c.out.y[y * 1920 + x]) - Int(c.src.y[y * 1920 + x]) > 40 }), [], "인코딩 전 기하 frame \(c.k)")
        }
        // 꺾은선 자리: 열마다 밝기 증가의 무게 중심(행). 인코딩 전(캡처한 출력 − 원본)과 디코딩(스펙트럼 출력 − 기준 출력)을 비교한다 —
        // 뾰족한 꼭짓점에서는 두 선분이 겹쳐 "가장 많이 다른 행"이 꼭짓점이 아니므로(첫 실행에서 관찰) 그 방식은 쓰지 않는다. 기하 자체는 testSixStyleDirectionGeometry가 본다.
        func centroid(_ s: [UInt8], _ r: [UInt8], _ x: Int, minDelta: Int) -> Double? {
            var w = 0.0, m = 0.0
            for y in (base - 200)...(base + 10) { let d = Int(s[y * 1920 + x]) - Int(r[y * 1920 + x]); if d > minDelta { w += Double(d); m += Double(d) * Double(y) } }
            return w > 0 ? m / w : nil
        }
        var rows: [String] = []
        for k in frames.sorted() {
            let c = cap.first { $0.k == k }!
            XCTAssertEqual(c.paintedOutsideBounds, 0)
            for i in [band440, bandHigh, 30, 50] {
                let x = Self.expectedX(i), h = Self.expectedH(c.bands[i])
                let pre = centroid(c.out.y, c.src.y, x, minDelta: 0), dec = centroid(b[k]!.y, a[k]!.y, x, minDelta: 20)
                rows.append("f\(k) b\(i) band-point y \(base - h) pre \(pre.map { String(format: "%.1f", $0) } ?? "-") decoded \(dec.map { String(format: "%.1f", $0) } ?? "-")")
                guard let pre, let dec else { XCTFail("열 \(x) f\(k)에서 선을 못 찾음"); continue }
                XCTAssertEqual(dec, pre, accuracy: 2, "디코딩 꺾은선 자리 = 인코딩 전 자리(±2 px) f\(k) b\(i)")
            }
        }
        // 프레임 시점: 소리 사건(48)에서 높은 밴드 열의 선이 기준선보다 위로 감(45는 기준선)
        let xh = Self.expectedX(bandHigh)
        let c45 = centroid(b[45]!.y, a[45]!.y, xh, minDelta: 20) ?? 0, c48 = centroid(b[48]!.y, a[48]!.y, xh, minDelta: 20) ?? 0
        XCTAssertLessThan(c48, c45 - 15, "디코딩 출력에서 프레임 48의 높은 밴드 선이 더 높음")
        print("SPECTRUM checkpoint analog decoded: \(rows)")
    }

    /// 기존 대상 보호·실패·취소 정리: 확인하지 않은 기존 파일은 건드리지 않음, 실패 주입은 기존 파일 그대로·임시 폴더 지움, 취소는 대상 없음·임시 폴더 지움, 분석 대기 없음
    func testDestinationProtectionFailureAndCancellationCleanup() async throws {
        let f = try await fixture(subtitle: false)
        let st = style(.digital, .above)
        // 1) 확인하지 않은 기존 대상
        let existing = out.appendingPathComponent("existing.mp4")
        try Data("keep me".utf8).write(to: existing)
        let temps = TempLog()
        let (o1, _, _) = await boundedExport(f, st, to: ExportDestination(url: existing, confirmedReplace: false, identityAtConfirmation: nil),
                                             options: .init(onTempDirectory: { temps.add($0) }))
        XCTAssertEqual(o1, .failed(.destinationExistsUnconfirmed))
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep me".utf8)); XCTAssertTrue(temps.all.isEmpty, "임시 폴더를 만들기 전에 거부")
        // 2) 대치를 확인한 기존 대상 + 실패 주입(30%) → 기존 파일 그대로, 임시 폴더 지움
        let s2 = SpectrumAnalysisScheduler()
        let (o2, st2, _) = await boundedExport(f, st, to: .fromSavePanel(existing), options: .init(failAfterFraction: 0.3, onTempDirectory: { temps.add($0) }), scheduler: s2)
        XCTAssertEqual(o2, .failed(.injected)); XCTAssertLessThan(st2.frames, 120)
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep me".utf8))
        XCTAssertTrue(temps.all.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "임시 폴더 지움")
        // 3) 취소 → 대상 없음, 임시 폴더 지움, 분석 일정에 남은 기다림 없음
        let fresh = out.appendingPathComponent("cancelled.mp4")
        let s3 = SpectrumAnalysisScheduler()
        let sp = SpectrumCheckpointExport.Spectrum(source: f.source, pieces: [f.piece], settings: settings, style: st)
        let plan = f.plan, sources = f.sources
        let task = Task { await SpectrumCheckpointExport.export(plan, spectrum: sp, to: .fromSavePanel(fresh), sources: sources, options: .init(onTempDirectory: { temps.add($0) }), scheduler: s3) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let (o3, st3, _) = await task.value
        print("SPECTRUM checkpoint cancel: outcome \(o3) frames \(st3.frames) stages \(st3.stages)")
        XCTAssertEqual(o3, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(temps.all.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        for _ in 0..<200 where s3.statistics.active > 0 || s3.statistics.waiters > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(s3.statistics.waiters, 0); XCTAssertEqual(s3.statistics.active, 0)
        // 그리기 캔버스(8 MB)는 실패·취소한 내보내기에서도 놓인다
        for _ in 0..<200 where SpectrumCanvas.liveCount > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(SpectrumCanvas.liveCount, 0, "남은 캔버스 없음")
    }
    final class TempLog: @unchecked Sendable {   // 안전성: 잠금으로 보호
        private let l = NSLock(); private var xs: [URL] = []
        func add(_ u: URL) { l.lock(); xs.append(u); l.unlock() }
        var all: [URL] { l.lock(); defer { l.unlock() }; return xs }
    }
}
