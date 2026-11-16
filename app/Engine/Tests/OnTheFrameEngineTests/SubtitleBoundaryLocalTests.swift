import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import QuartzCore
import XCTest

/// 지역 대조 경계 판정(2026-10-21, docs/SUBTITLE-DESIGN.md §24, 실험 — 채택 아님). 선택 실행(OTF_SB=1).
/// §23 계약의 글자 밖 비교를 글자 화소마다 가운데를 맞춘 17×17 창(R = 8) 안의 대조 화소로 바꾼다(격자 가정 없음).
/// - 개발: `testApproachBLocalDetectorDevelopment`는 §23 파일(sb-detector/, sb-residue/)만 읽고 τ 규칙의 값을 낸다.
/// - 보류 검증: `testApproachBLocalDetectorHeldOut`는 고정한 τ로 테스트 전용 자리(평평한 배경, 무늬 경계, "f=NN" 글자) 여섯 자막을 한 번 잰다.
/// 기존 네 자막과 제품 내보내기 설정은 바꾸지 않는다. 변형은 이 테스트 안에만 있다.
extension SubtitleApproachBTests {
    static let localR = 8, localMinControl = 16, localMargin = 12
    /// 개발 데이터(§23 파일)로 정한 뒤 보류 검증 전에 고정한 문턱(§24.2). 바꾸지 않는다.
    static let localTau: Double = 1.563

    /// 보류 조건 자막(테스트 전용): 유색은 [60, 85), 무채색은 [90, 112)
    static let heldOutCaptions: [Caption] = [
        Caption(name: "ho-flat-color", text: "평평 Flat 平ら", font: font, size: 44, rgba: (1, 0.55, 0.7, 1), align: .left,
                origin: CGPoint(x: 240, y: 975), width: 560, start: 60, end: 85),
        Caption(name: "ho-flat-achro", text: "Flat 회색 グレー", font: font, size: 44, rgba: (0.5, 0.5, 0.5, 1), align: .left,
                origin: CGPoint(x: 1000, y: 975), width: 560, start: 90, end: 112),
        Caption(name: "ho-edge-color", text: "경계 Edge 境界", font: font, size: 48, rgba: (1, 0.55, 0.7, 1), align: .left,
                origin: CGPoint(x: 240, y: 420), width: 560, start: 60, end: 85),
        Caption(name: "ho-edge-achro", text: "경계 Edge", font: font, size: 48, rgba: (0.5, 0.5, 0.5, 1), align: .left,
                origin: CGPoint(x: 40, y: 650), width: 340, start: 90, end: 112),
        Caption(name: "ho-label-color", text: "라벨 ラベル", font: font, size: 44, rgba: (1, 0.55, 0.7, 1), align: .left,
                origin: CGPoint(x: 1130, y: 108), width: 300, start: 60, end: 85),
        Caption(name: "ho-label-achro", text: "라벨 Label", font: font, size: 44, rgba: (0.5, 0.5, 0.5, 1), align: .left,
                origin: CGPoint(x: 1130, y: 108), width: 300, start: 90, end: 112),
    ]

    /// 영역(사각형 +12). k = 글자 화소(알파 ≥ 128), o = 대조 화소(알파 0, 2화소 안 알파 > 0 없음)
    static func localRegion(_ r: Raster) -> Region {
        let m = localMargin
        let x0 = max(0, Int(r.rect.minX) - m), y0 = max(0, Int(r.rect.minY) - m)
        let w = min(1920, Int(r.rect.maxX) + m) - x0, h = min(1080, Int(r.rect.maxY) + m) - y0
        let rw = Int(r.rect.width), rh = Int(r.rect.height)
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            let ax = x - Int(r.rect.minX), ay = y - Int(r.rect.minY)
            return ax >= 0 && ay >= 0 && ax < rw && ay < rh ? r.alpha[ay * rw + ax] : 0
        }
        var k: [Int] = [], o: [Int] = []
        for y in 0..<h { for x in 0..<w {
            let a = alpha(x0 + x, y0 + y)
            if a >= 128 { k.append(y * w + x); continue }
            var near = false
            for dy in -2...2 where !near { for dx in -2...2 where alpha(x0 + x + dx, y0 + y + dy) > 0 { near = true; break } }
            if !near { o.append(y * w + x) }
        } }
        return Region(name: r.caption.name, x0: x0, y0: y0, w: w, h: h, k: k, o: o)
    }

    struct LocalStat { let g: Double, coverage: Double, meanD: Double, p99: Int, maxD: Int, kMeanD: Double }
    /// g_L = 대조가 충분한(창 안 ≥ 16) 글자 화소의 r_k = d_k − 창 안 대조 평균 d 의 평균. residual이 있으면 r_k를 채운다(그림용, 빼진 화소는 nan).
    static func localStat(_ a: [UInt8], _ b: [UInt8], _ g: Region, residual: UnsafeMutablePointer<Double>? = nil) -> LocalStat {
        let n = g.w * g.h, sw = g.w + 1
        var d = [Int32](repeating: 0, count: n)
        var hist = [Int](repeating: 0, count: 256)
        var total = 0
        for i in 0..<n {
            let v = max(abs(Int(a[i * 4]) - Int(b[i * 4])), abs(Int(a[i * 4 + 1]) - Int(b[i * 4 + 1])), abs(Int(a[i * 4 + 2]) - Int(b[i * 4 + 2])))
            d[i] = Int32(v); hist[v] += 1; total += v
        }
        var ctrl = [Int32](repeating: 0, count: n)
        for i in g.o { ctrl[i] = 1 }
        var sd = [Int64](repeating: 0, count: sw * (g.h + 1)), sc = [Int64](repeating: 0, count: sw * (g.h + 1))
        for y in 0..<g.h { for x in 0..<g.w {
            let i = y * g.w + x, j = (y + 1) * sw + (x + 1)
            sd[j] = Int64(d[i] * ctrl[i]) + sd[j - 1] + sd[j - sw] - sd[j - sw - 1]
            sc[j] = Int64(ctrl[i]) + sc[j - 1] + sc[j - sw] - sc[j - sw - 1]
        } }
        var acc = 0.0, covered = 0, kSum = 0.0
        for i in g.k {
            let x = i % g.w, y = i / g.w
            let xa = max(0, x - localR), xb = min(g.w, x + localR + 1), ya = max(0, y - localR), yb = min(g.h, y + localR + 1)
            let cnt = sc[yb * sw + xb] - sc[ya * sw + xb] - sc[yb * sw + xa] + sc[ya * sw + xa]
            kSum += Double(d[i])
            if cnt >= localMinControl {
                let s = sd[yb * sw + xb] - sd[ya * sw + xb] - sd[yb * sw + xa] + sd[ya * sw + xa]
                let r = Double(d[i]) - Double(s) / Double(cnt)
                acc += r; covered += 1
                residual?[i] = r
            } else { residual?[i] = .nan }
        }
        var c = 0, p99 = 0
        for v in 0..<256 { c += hist[v]; if c * 100 >= n * 99 { p99 = v; break } }
        let maxD = (0..<256).last { hist[$0] > 0 } ?? 0
        return LocalStat(g: covered == 0 ? .nan : acc / Double(covered), coverage: Double(covered) / Double(max(1, g.k.count)),
                         meanD: Double(total) / Double(n), p99: p99, maxD: maxD, kMeanD: kSum / Double(max(1, g.k.count)))
    }

    /// 판정(§24.1): unevaluable / inconclusive / none / bg-only / partial / on
    static func localVerdict(_ s: Decoded, _ c: Decoded, _ g: Region, frame n: Int, tau: Double, full: Double) -> (v: String, st: LocalStat?) {
        let exact = CMTime(value: CMTimeValue(n), timescale: 30)
        for x in [s, c] { guard let p = x.pts[n], CMTimeCompare(p, exact) == 0, x.codeOK[n] == true else { return ("unevaluable", nil) } }
        guard let a = s.crops[n]?[g.name], let b = c.crops[n]?[g.name] else { return ("unevaluable", nil) }
        let st = localStat(a, b, g)
        if st.coverage < 0.5 { return ("inconclusive", st) }
        if st.g <= tau { return (st.maxD == 0 ? "none" : "bg-only", st) }
        return (st.g >= 0.5 * full ? "on" : "partial", st)
    }
    static func isOff(_ v: String) -> Bool { v == "none" || v == "bg-only" }
    static func fmt(_ n: Int, _ r: (v: String, st: LocalStat?)) -> String {
        guard let s = r.st else { return "f\(n) \(r.v)" }
        return String(format: "f%d %@ gL %.2f cov %.2f d mean %.2f p99 %d max %d", n, r.v, s.g, s.coverage, s.meanD, s.p99, s.maxD)
    }
    /// 같은 짝의 null(경계 ±2 밖 숨김 프레임) 최대와 g_full(안쪽 프레임 중앙값)
    static func localCalib(_ s: Decoded, _ c: Decoded, _ g: Region, _ cap: Caption, frames: Int) -> (nullMax: Double, full: Double, minCov: Double) {
        var null: [Double] = [], inner: [Double] = [], minCov = 1.0
        for n in 0..<frames {
            guard let a = s.crops[n]?[g.name], let b = c.crops[n]?[g.name] else { continue }
            let st = localStat(a, b, g)
            minCov = min(minCov, st.coverage)
            if n < cap.start - 2 || n > cap.end + 2 { null.append(st.g) }
            if n >= cap.start + 2 && n < cap.end - 2 { inner.append(st.g) }
        }
        let sorted = inner.sorted()
        return (null.max() ?? .infinity, sorted.isEmpty ? .nan : sorted[sorted.count / 2], minCov)
    }
    /// 그림: 위 |d|×16, 가운데 글자 화소의 양의 r_k ×16(대조 부족 화소는 0으로 그림), 아래 글자 자리
    static func localPNG(_ url: URL, _ a: [UInt8], _ b: [UInt8], _ g: Region) throws {
        var res = [Double](repeating: 0, count: g.w * g.h)
        res.withUnsafeMutableBufferPointer { p in _ = localStat(a, b, g, residual: p.baseAddress!) }
        let ctx = CGContext(data: nil, width: g.w, height: g.h * 3, bitsPerComponent: 8, bytesPerRow: g.w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self), n = g.w * g.h
        let kset = Set(g.k)
        for i in 0..<n {
            let d = max(abs(Int(a[i * 4]) - Int(b[i * 4])), abs(Int(a[i * 4 + 1]) - Int(b[i * 4 + 1])), abs(Int(a[i * 4 + 2]) - Int(b[i * 4 + 2])))
            p[i] = UInt8(min(255, d * 16))
            p[n + i] = kset.contains(i) ? (res[i].isNaN ? 0 : UInt8(min(255, max(0, res[i] * 16)))) : 0
            p[2 * n + i] = kset.contains(i) ? 255 : 0
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    }

    // MARK: 개발(§23 파일만, 새 내보내기 없음)

    func testApproachBLocalDetectorDevelopment() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (_, _, expected) = try await plan()
        let frames = expected.count
        let rs = (Self.captions + [Self.grayCaption]).map(Self.raster)
        let regions = rs.map(Self.localRegion)
        func reg(_ name: String) -> Region { regions.first { $0.name == name }! }
        let det = ExportEndToEndTests.root.appendingPathComponent("sb-detector"), res = ExportEndToEndTests.root.appendingPathComponent("sb-residue")
        let dAll = try await Self.decodeCrops(det.appendingPathComponent("h264-all5.mp4"), regions: regions, expected: expected)
        let dBase = try await Self.decodeCrops(res.appendingPathComponent("h264-base.mp4"), regions: regions, expected: expected)
        let dEmpty = try await Self.decodeCrops(res.appendingPathComponent("h264-empty-tool.mp4"), regions: regions, expected: expected)
        var nullAll = -Double.infinity
        var rows: [String] = [], dNo: [String: Decoded] = [:], cal: [String: (nullMax: Double, full: Double, minCov: Double)] = [:]
        for r in rs {
            let c = r.caption, g = reg(c.name)
            dNo[c.name] = try await Self.decodeCrops(det.appendingPathComponent("h264-no-\(c.name).mp4"), regions: [g], expected: expected)
            let k = Self.localCalib(dAll, dNo[c.name]!, g, c, frames: frames)
            cal[c.name] = k
            var freeMax = -Double.infinity, freeAt = -1
            for n in 0..<frames {
                guard let a = dEmpty.crops[n]?[g.name], let b = dBase.crops[n]?[g.name] else { continue }
                let v = Self.localStat(a, b, g).g
                if v > freeMax { freeMax = v; freeAt = n }
            }
            nullAll = max(nullAll, k.nullMax, freeMax)
            rows.append(String(format: "%@: K %d O %d | null max %.2f full %.2f min coverage %.2f | subtitle-free gL max %.2f at f%d",
                               c.name, g.k.count, g.o.count, k.nullMax, k.full, k.minCov, freeMax, freeAt))
        }
        let tau = max(1.0, 2 * nullAll)
        note("development (§23 files): null and calibration per caption:\n  " + rows.joined(separator: "\n  "))
        note(String(format: "tau rule max(1, 2 × dev null max): dev null max %.3f → tau %.3f", nullAll, tau))

        // 개발 경계·변형(같은 τ 후보로): 보류 전 점검일 뿐 받아들임 판정이 아니다
        var b: [String] = []
        for r in rs {
            let c = r.caption, g = reg(c.name)
            let cells = [c.start - 1, c.start, c.end - 1, c.end, c.end + 1].map { Self.fmt($0, Self.localVerdict(dAll, dNo[c.name]!, g, frame: $0, tau: tau, full: cal[c.name]!.full)) }
            b.append("\(c.name): " + cells.joined(separator: "; "))
        }
        note("development boundaries (clean):\n  " + b.joined(separator: "\n  "))
        var m: [String] = []
        for name in ["ja-center", "gray"] {
            let c = rs.first { $0.caption.name == name }!.caption, g = reg(name)
            for tag in ["late-end", "early-start", "faint-1of2", "faint-1of4", "faint-1of8", "faint-1of16", "faint-1of32", "faint-1of64"] {
                let d = try await Self.decodeCrops(det.appendingPathComponent("h264-\(name)-\(tag).mp4"), regions: [g], expected: expected)
                let probe = tag == "early-start" ? c.start - 1 : c.end
                m.append("\(name) \(tag): " + Self.fmt(probe, Self.localVerdict(d, dNo[name]!, g, frame: probe, tau: tau, full: cal[name]!.full)))
            }
        }
        note("development mutations:\n  " + m.joined(separator: "\n  "))
    }

    // MARK: 보류 검증(고정한 τ, 한 번)

    func testApproachBLocalDetectorHeldOut() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        XCTAssertEqual(Self.localTau, 1.563, "τ is frozen (§24.2)")
        let tau = Self.localTau
        let (p, ta, expected) = try await plan()
        let size = p.videoComposition.renderSize, frames = p.durationFrames
        let rs = (Self.captions + Self.heldOutCaptions).map(Self.raster)
        let held = Set(Self.heldOutCaptions.map(\.name))
        for a in rs where held.contains(a.caption.name) { for b in rs where b.caption.name != a.caption.name {
            let together = max(a.caption.start, b.caption.start) < min(a.caption.end, b.caption.end) + 3
            if together { XCTAssertFalse(a.rect.insetBy(dx: -12, dy: -12).intersects(b.rect), "\(a.caption.name) overlaps \(b.caption.name) while near in time") }
        } }
        let regions = rs.map(Self.localRegion)
        func reg(_ name: String) -> Region { regions.first { $0.name == name }! }
        for g in regions where held.contains(g.name) { note("held-out region \(g.name): origin (\(g.x0),\(g.y0)) \(g.w)x\(g.h) K \(g.k.count) O \(g.o.count)") }

        let keep = ExportEndToEndTests.root.appendingPathComponent("sb-local")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        func steps(_ mutate: [String: [Step]]) -> [(Raster, [Step])] { rs.map { ($0, mutate[$0.caption.name] ?? Self.defaultSteps($0.caption)) } }
        func h264(_ tag: String, _ items: [(Raster, [Step])]) async throws -> URL {
            let dest = keep.appendingPathComponent("h264-\(tag).mp4")
            try? FileManager.default.removeItem(at: dest)   // 이 테스트가 만든 이전 출력만(sb-local 디렉터리)
            let v = SubtitleABComparisonTests.tool(p.videoComposition, overlay: Self.steppedOverlay(items, size: size, durationFrames: frames))
            let outcome = await ExportService.export(withVideoComposition(p, v), to: .fromSavePanel(dest), sources: [ta]) { _ in }
            XCTAssertEqual(outcome, .completed(dest), tag)
            return dest
        }
        var accept: [String] = []   // 받아들임 어긋남

        // 1. 깨끗한 경계: 전부(기존 네 + 보류 여섯) 대 X만 뺀 짝
        let dAll = try await Self.decodeCrops(try await h264("all10", steps([:])), regions: regions, expected: expected)
        var dNo: [String: Decoded] = [:], full: [String: Double] = [:]
        var rows: [String] = []
        for r in rs {
            let c = r.caption, g = reg(c.name)
            dNo[c.name] = try await Self.decodeCrops(try await h264("no-\(c.name)", steps([:]).filter { $0.0.caption.name != c.name }), regions: [g], expected: expected)
            let k = Self.localCalib(dAll, dNo[c.name]!, g, c, frames: frames)
            full[c.name] = k.full
            var cells: [String] = []
            for n in [c.start - 1, c.start, c.end - 1, c.end, c.end + 1] {
                let v = Self.localVerdict(dAll, dNo[c.name]!, g, frame: n, tau: tau, full: k.full)
                let ok = Self.expectedVisible(c, frame: n) ? v.v == "on" : Self.isOff(v.v)
                if !ok { accept.append("clean \(c.name) f\(n) \(v.v)") }
                cells.append(Self.fmt(n, v))
            }
            rows.append(String(format: "%@: null max %.2f (not used for tau) full %.2f min cov %.2f | ", c.name, k.nullMax, k.full, k.minCov) + cells.joined(separator: "; "))
        }
        note("held-out clean boundaries (tau \(tau)):\n  " + rows.joined(separator: "\n  "))

        // 2. 자막 없는 짝(빈 도구 − 기준, §22 파일 읽기만): 보류 영역 모든 프레임
        let res = ExportEndToEndTests.root.appendingPathComponent("sb-residue")
        let heldRegions = regions.filter { held.contains($0.name) }
        let dBase = try await Self.decodeCrops(res.appendingPathComponent("h264-base.mp4"), regions: heldRegions, expected: expected)
        let dEmpty = try await Self.decodeCrops(res.appendingPathComponent("h264-empty-tool.mp4"), regions: heldRegions, expected: expected)
        var free: [String] = []
        for g in heldRegions {
            var mx = -Double.infinity, at = -1, over = 0, dMax = 0
            for n in 0..<frames {
                guard let a = dEmpty.crops[n]?[g.name], let b = dBase.crops[n]?[g.name] else { continue }
                let st = Self.localStat(a, b, g)
                if st.g > mx { mx = st.g; at = n }
                if st.g > tau { over += 1 }
                dMax = max(dMax, st.maxD)
            }
            if over > 0 { accept.append("subtitle-free \(g.name) \(over) frames over tau") }
            free.append(String(format: "%@: gL max %.2f at f%d, frames over tau %d, d max %d", g.name, mx, at, over, dMax))
        }
        note("held-out subtitle-free pair (empty-tool vs base):\n  " + free.joined(separator: "\n  "))

        // 3. 변형(보류 여섯 자막)
        let ks: [(String, Float)] = [("1of2", 0.5), ("1of4", 0.25), ("1of8", 0.125), ("1of16", 0.0625), ("1of32", 0.03125), ("1of64", 0.015625)]
        var mut: [String] = [], limits: [String] = []
        for c in Self.heldOutCaptions {
            let g = reg(c.name)
            var list: [(String, [Step], Int)] = [("late-end", [Step(from: c.start, opacity: 1), Step(from: c.end + 1, opacity: 0)], c.end),
                                                 ("early-start", [Step(from: c.start - 1, opacity: 1), Step(from: c.end, opacity: 0)], c.start - 1)]
            list += ks.map { ("faint-\($0.0)", [Step(from: c.start, opacity: 1), Step(from: c.end, opacity: $0.1), Step(from: c.end + 2, opacity: 0)], c.end) }
            var smallest = "none", ladder: [String] = []
            for (tag, st, probe) in list {
                let d = try await Self.decodeCrops(try await h264("\(c.name)-\(tag)", steps([c.name: st])), regions: [g], expected: expected)
                let v = Self.localVerdict(d, dNo[c.name]!, g, frame: probe, tau: tau, full: full[c.name]!)
                let detected = v.v == "on" || v.v == "partial"
                if (tag == "late-end" || tag == "early-start" || tag == "faint-1of2") && !detected { accept.append("mutation \(c.name) \(tag) \(v.v)") }
                if tag.hasPrefix("faint") { ladder.append("\(tag.dropFirst(6)) \(detected ? "+" : "-")"); if detected { smallest = String(tag.dropFirst(6)) } }
                mut.append("\(c.name) \(tag): " + Self.fmt(probe, v) + (detected ? " → DETECTED" : " → not detected"))
            }
            limits.append("\(c.name): smallest detected \(smallest) [\(ladder.joined(separator: ", "))]")
        }
        note("held-out mutations:\n  " + mut.joined(separator: "\n  "))
        note("held-out faint detection ladder (detected +, not detected -):\n  " + limits.joined(separator: "\n  "))

        // 4. §23 실패 두 곳 다시 보기(고정한 방법, §23 파일 — 개발 데이터라 독립 검증이 아님)
        let det = ExportEndToEndTests.root.appendingPathComponent("sb-detector")
        let dev = (Self.captions + [Self.grayCaption]).map(Self.raster).map(Self.localRegion)
        func dreg(_ name: String) -> Region { dev.first { $0.name == name }! }
        var rv: [String] = []
        for (name, ns) in [("gray", [33, 34, 35]), ("ko-left", [9]), ("mixed-right", [39])] {
            let g = dreg(name)
            let s = try await Self.decodeCrops(det.appendingPathComponent("h264-all5.mp4"), regions: [g], expected: expected)
            let c = try await Self.decodeCrops(det.appendingPathComponent("h264-no-\(name).mp4"), regions: [g], expected: expected)
            let k = Self.localCalib(s, c, g, (Self.captions + [Self.grayCaption]).first { $0.name == name }!, frames: frames)
            for n in ns {
                rv.append("S−C \(name) " + Self.fmt(n, Self.localVerdict(s, c, g, frame: n, tau: tau, full: k.full)))
                if (name == "gray" && n == 34), let a = s.crops[n]?[name], let b = c.crops[n]?[name] { try Self.localPNG(keep.appendingPathComponent("revisit-gray-f34.png"), a, b, g) }
            }
        }
        let gm = dreg("mixed-right")
        let fb = try await Self.decodeCrops(res.appendingPathComponent("h264-base.mp4"), regions: [gm], expected: expected)
        let fe = try await Self.decodeCrops(res.appendingPathComponent("h264-empty-tool.mp4"), regions: [gm], expected: expected)
        for n in [70, 71, 72, 73, 74] {
            guard let a = fe.crops[n]?["mixed-right"], let b = fb.crops[n]?["mixed-right"] else { continue }
            let st = Self.localStat(a, b, gm)
            rv.append(String(format: "subtitle-free mixed-right f%d gL %.2f cov %.2f d mean %.2f p99 %d max %d → %@", n, st.g, st.coverage, st.meanD, st.p99, st.maxD,
                             st.coverage < 0.5 ? "inconclusive" : (st.g > tau ? "glyph-correlated" : "bg-only")))
            if n == 72 { try Self.localPNG(keep.appendingPathComponent("revisit-mixed-right-free-f72.png"), a, b, gm) }
        }
        note("§23 failures revisited with frozen method (development files):\n  " + rv.joined(separator: "\n  "))

        note("held-out acceptance: \(accept.isEmpty ? "PASS" : "FAIL \(accept)")")
        XCTAssertTrue(accept.isEmpty, "held-out acceptance failed: \(accept)")
    }

    /// 그림만 다시 만든다(새 내보내기 없음, 판정·τ 변경 없음): §23 실패 두 곳과 보류 "f=NN" 실패
    func testApproachBLocalDetectorImages() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (_, _, expected) = try await plan()
        let root = ExportEndToEndTests.root
        let det = root.appendingPathComponent("sb-detector"), res = root.appendingPathComponent("sb-residue"), loc = root.appendingPathComponent("sb-local")
        let dev = (Self.captions + [Self.grayCaption]).map(Self.raster).map(Self.localRegion)
        let ho = (Self.captions + Self.heldOutCaptions).map(Self.raster).map(Self.localRegion)
        func pair(_ a: URL, _ b: URL, _ g: Region, _ n: Int, _ out: String) async throws {
            let s = try await Self.decodeCrops(a, regions: [g], expected: expected), c = try await Self.decodeCrops(b, regions: [g], expected: expected)
            guard let x = s.crops[n]?[g.name], let y = c.crops[n]?[g.name] else { return }
            let st = Self.localStat(x, y, g)
            note(String(format: "%@: gL %.2f cov %.2f d mean %.2f p99 %d max %d, glyph-pixel mean d %.2f", out, st.g, st.coverage, st.meanD, st.p99, st.maxD, st.kMeanD))
            try Self.localPNG(loc.appendingPathComponent(out), x, y, g)
        }
        let gray = dev.first { $0.name == "gray" }!, mixed = dev.first { $0.name == "mixed-right" }!
        try await pair(det.appendingPathComponent("h264-all5.mp4"), det.appendingPathComponent("h264-no-gray.mp4"), gray, 34, "revisit-gray-f34.png")
        try await pair(res.appendingPathComponent("h264-empty-tool.mp4"), res.appendingPathComponent("h264-base.mp4"), mixed, 72, "revisit-mixed-right-free-f72.png")
        let lc = ho.first { $0.name == "ho-label-color" }!, la = ho.first { $0.name == "ho-label-achro" }!
        try await pair(loc.appendingPathComponent("h264-all10.mp4"), loc.appendingPathComponent("h264-no-ho-label-color.mp4"), lc, 85, "heldout-label-color-f85.png")
        try await pair(loc.appendingPathComponent("h264-all10.mp4"), loc.appendingPathComponent("h264-no-ho-label-color.mp4"), lc, 70, "heldout-label-color-f70-visible.png")
        try await pair(res.appendingPathComponent("h264-empty-tool.mp4"), res.appendingPathComponent("h264-base.mp4"), lc, 58, "heldout-label-color-free-f58.png")
        try await pair(res.appendingPathComponent("h264-empty-tool.mp4"), res.appendingPathComponent("h264-base.mp4"), la, 58, "heldout-label-achro-free-f58.png")
    }
}
