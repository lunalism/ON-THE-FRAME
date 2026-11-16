import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import QuartzCore
import XCTest

/// H.264 내보내기 경계 판정 방법 바로잡기(2026-10-21, docs/SUBTITLE-DESIGN.md §23, 실험 — 채택 아님). 선택 실행(OTF_SB=1).
/// 판정 계약(§23.1, 평가 전에 정함): 정확한 PTS·화면 코드 + 짝 내보내기(S = 전부, C_X = X만 뺌) + 글자 모양 대응 통계
/// g = mean_K(d) − mean_O(d), d = 채널 최대 |Δ|(색 가정 없음). 문턱 τ = max(1, 2 × null 최대), null = 경계 ±2 밖 숨김 프레임의 g.
/// 민감도: 테스트 안에서만 자막 시각을 바꾼 변형(끝 늦음, 시작 이름, 약한 잔상 k)을 만들어 같은 계약으로 잰다. 무채색 시험 자막(gray) 포함.
/// 기존 네 자막의 구간·위치·애니메이션과 내보내기 설정은 바꾸지 않는다.
/// 결과 파일: .build/test-work/sb-detector/ (H.264는 남기고 ProRes 대조는 잰 뒤 지운다). §22 재현 파일(sb-residue/)은 읽기만 한다.
extension SubtitleApproachBTests {
    /// 무채색 시험 자막(테스트 전용): 매 프레임 바뀌는 잡음 무늬(y 450–900) 위, 다른 자막 사각형과 겹치지 않음
    static let grayCaption = Caption(name: "gray", text: "Gray 회색 グレー 0123", font: font, size: 48, rgba: (0.5, 0.5, 0.5, 1), align: .left,
                                     origin: CGPoint(x: 1200, y: 470), width: 650, start: 35, end: 80)

    /// 불투명도 계단: from 프레임부터 opacity(그 전은 0). 기본 [(start, 1), (end, 0)]은 `overlay`와 같은 키 프레임이다.
    struct Step { let from: Int; let opacity: Float }
    static func defaultSteps(_ c: Caption) -> [Step] { [Step(from: c.start, opacity: 1), Step(from: c.end, opacity: 0)] }
    static func steppedOverlay(_ items: [(Raster, [Step])], size: CGSize, durationFrames: Int) -> CALayer {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        let d = Double(durationFrames) / 30
        for (r, steps) in items {
            let l = CALayer()
            l.contents = r.image
            l.contentsScale = 1
            l.contentsGravity = .resize
            l.frame = CGRect(x: r.rect.minX, y: size.height - r.rect.maxY, width: r.rect.width, height: r.rect.height)
            l.opacity = 0
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.calculationMode = .discrete
            a.values = [Float(0)] + steps.map(\.opacity)
            a.keyTimes = [0] + steps.map { NSNumber(value: (Double($0.from) - epsilonFrames) / 30 / d) } + [1]
            a.beginTime = AVCoreAnimationBeginTimeAtZero
            a.duration = d
            a.isRemovedOnCompletion = false
            a.fillMode = .both
            l.add(a, forKey: "visibility")
            root.addSublayer(l)
        }
        return root
    }

    /// 판정 영역: 자막 사각형 +4, 글자 자리 K(알파 ≥ 128), 글자 밖 O(알파 0이고 2화소 안에 알파 > 0 없음)
    struct Region {
        let name: String, x0: Int, y0: Int, w: Int, h: Int
        let k: [Int], o: [Int]
    }
    static func region(_ r: Raster) -> Region {
        let x0 = max(0, Int(r.rect.minX) - 4), y0 = max(0, Int(r.rect.minY) - 4)
        let w = min(1920, Int(r.rect.maxX) + 4) - x0, h = min(1080, Int(r.rect.maxY) + 4) - y0
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

    /// 디코딩 결과: 프레임별 PTS, 화면 코드 일치, 영역 잘라 낸 BGRA
    struct Decoded { var pts: [Int: CMTime] = [:]; var codeOK: [Int: Bool] = [:]; var crops: [Int: [String: [UInt8]]] = [:] }
    static func decodeCrops(_ url: URL, regions: [Region], expected: [ExportJudge.Expected]) async throws -> Decoded {
        let a = AVURLAsset(url: url)
        let t = try await a.loadTracks(withMediaType: .video).first!
        let r = try AVAssetReader(asset: a)
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        r.add(o); r.startReading()
        var out = Decoded()
        while let sb = o.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb), n = Int((pts.seconds * 30).rounded())
            out.pts[n] = pts
            if n < expected.count { out.codeOK[n] = ExportJudge.matches(E2Metrics.measure(pb), expected[n]) }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
            var crops: [String: [UInt8]] = [:]
            for g in regions {
                var c = [UInt8](repeating: 0, count: g.w * g.h * 4)
                c.withUnsafeMutableBufferPointer { p in for y in 0..<g.h { memcpy(p.baseAddress! + y * g.w * 4, base + (g.y0 + y) * bpr + g.x0 * 4, g.w * 4) } }
                crops[g.name] = c
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            out.crops[n] = crops
        }
        r.cancelReading()
        return out
    }

    /// g = mean_K(d) − mean_O(d), d = max(|ΔB|, |ΔG|, |ΔR|). 기존 T1 수(K 중 |ΔY| > 40)도 함께.
    static func glyphStat(_ a: [UInt8], _ b: [UInt8], _ g: Region) -> (g: Double, k: Double, o: Double, t1: Int) {
        func d(_ i: Int) -> Int { max(abs(Int(a[i * 4]) - Int(b[i * 4])), abs(Int(a[i * 4 + 1]) - Int(b[i * 4 + 1])), abs(Int(a[i * 4 + 2]) - Int(b[i * 4 + 2]))) }
        func y(_ p: [UInt8], _ i: Int) -> Double { 0.2126 * Double(p[i * 4 + 2]) + 0.7152 * Double(p[i * 4 + 1]) + 0.0722 * Double(p[i * 4]) }
        let km = Double(g.k.reduce(0) { $0 + d($1) }) / Double(g.k.count), om = Double(g.o.reduce(0) { $0 + d($1) }) / Double(g.o.count)
        return (km - om, km, om, g.k.filter { abs(y(a, $0) - y(b, $0)) > 40 }.count)
    }

    /// 계약의 문턱과 보임 기준(같은 짝 S − C_X의 null 프레임·안쪽 프레임에서)
    struct Calib { let tau: Double, full: Double, nullMax: Double, nullFrames: Int }
    static func calibrate(_ s: Decoded, _ c: Decoded, _ g: Region, _ cap: Caption, frames: Int) -> Calib {
        var null: [Double] = [], inner: [Double] = []
        for n in 0..<frames {
            guard let a = s.crops[n]?[g.name], let b = c.crops[n]?[g.name] else { continue }
            let v = glyphStat(a, b, g).g
            if (n < cap.start - 2 || n > cap.end + 2) { null.append(v) }
            if n >= cap.start + 2 && n < cap.end - 2 { inner.append(v) }
        }
        let nm = null.max() ?? .infinity
        let sorted = inner.sorted()
        return Calib(tau: max(1.0, 2 * nm), full: sorted.isEmpty ? .nan : sorted[sorted.count / 2], nullMax: nm, nullFrames: null.count)
    }
    /// 판정: 판정 불가(PTS·코드) / 숨김 / 보임 / 부분
    static func classify(_ s: Decoded, _ c: Decoded, _ g: Region, frame n: Int, _ cal: Calib) -> (verdict: String, g: Double, t1: Int) {
        let exact = CMTime(value: CMTimeValue(n), timescale: 30)
        for x in [s, c] {
            guard let p = x.pts[n], CMTimeCompare(p, exact) == 0, x.codeOK[n] == true else { return ("unevaluable", .nan, -1) }
        }
        guard let a = s.crops[n]?[g.name], let b = c.crops[n]?[g.name] else { return ("unevaluable", .nan, -1) }
        let st = glyphStat(a, b, g)
        let v = st.g <= cal.tau ? "off" : (st.g >= 0.5 * cal.full ? "on" : "partial")
        return (v, st.g, st.t1)
    }

    func testApproachBBoundaryDetector() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, ta, expected) = try await plan()
        let size = p.videoComposition.renderSize, frames = p.durationFrames
        let caps = Self.captions + [Self.grayCaption]
        let rs = caps.map(Self.raster)
        let gr = rs.last!
        for r in rs.dropLast() { XCTAssertFalse(r.rect.insetBy(dx: -6, dy: -6).intersects(gr.rect), "gray must not overlap \(r.caption.name)") }
        let regions = rs.map(Self.region)
        func reg(_ name: String) -> Region { regions.first { $0.name == name }! }
        for g in regions { note("region \(g.name): origin (\(g.x0),\(g.y0)) \(g.w)x\(g.h) K \(g.k.count) O \(g.o.count)") }

        let keep = ExportEndToEndTests.root.appendingPathComponent("sb-detector")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        func steps(_ mutate: [String: [Step]]) -> [(Raster, [Step])] { rs.map { ($0, mutate[$0.caption.name] ?? Self.defaultSteps($0.caption)) } }
        func vc(_ items: [(Raster, [Step])]) -> AVVideoComposition {
            SubtitleABComparisonTests.tool(p.videoComposition, overlay: Self.steppedOverlay(items, size: size, durationFrames: frames))
        }
        func h264(_ tag: String, _ v: AVVideoComposition) async throws -> URL {
            let dest = keep.appendingPathComponent("h264-\(tag).mp4")
            try? FileManager.default.removeItem(at: dest)   // 이 테스트가 만든 이전 출력만(sb-detector 디렉터리)
            let outcome = await ExportService.export(withVideoComposition(p, v), to: .fromSavePanel(dest), sources: [ta]) { _ in }
            XCTAssertEqual(outcome, .completed(dest), tag)
            return dest
        }
        func prores(_ tag: String, _ v: AVVideoComposition) async throws -> URL {
            let dest = keep.appendingPathComponent("prores-\(tag).mov")
            try? FileManager.default.removeItem(at: dest)
            let s = AVAssetExportSession(asset: p.composition, presetName: AVAssetExportPresetAppleProRes4444LPCM)!
            s.videoComposition = v; s.audioMix = p.audioMix; s.shouldOptimizeForNetworkUse = false
            try await s.export(to: dest, as: .mov)
            return dest
        }
        let ks: [(String, Float)] = [("1of2", 0.5), ("1of4", 0.25), ("1of8", 0.125), ("1of16", 0.0625), ("1of32", 0.03125), ("1of64", 0.015625)]
        func mutations(_ c: Caption) -> [(String, [Step])] {
            [("late-end", [Step(from: c.start, opacity: 1), Step(from: c.end + 1, opacity: 0)]),
             ("early-start", [Step(from: c.start - 1, opacity: 1), Step(from: c.end, opacity: 0)])]
            + ks.map { k in ("faint-\(k.0)", [Step(from: c.start, opacity: 1), Step(from: c.end, opacity: k.1), Step(from: c.end + 2, opacity: 0)]) }
        }
        let targets = ["ja-center", "gray"]
        var allPass = true
        var summary: [String] = []

        // 1. 자막 없는 짝과 §22 재현 파일(읽기만)
        let residue = ExportEndToEndTests.root.appendingPathComponent("sb-residue")
        let rBase = residue.appendingPathComponent("h264-base.mp4"), rEmpty = residue.appendingPathComponent("h264-empty-tool.mp4")
        let rAll = residue.appendingPathComponent("h264-all.mp4"), rNoJa = residue.appendingPathComponent("h264-no-ja.mp4")
        for u in [rBase, rEmpty, rAll, rNoJa] { XCTAssertTrue(FileManager.default.fileExists(atPath: u.path), "§22 reproduction file missing: \(u.lastPathComponent) (run testApproachBJapaneseResidueDiagnostics)") }
        let allBytes = (try? FileManager.default.attributesOfItem(atPath: rAll.path))?[.size] as? UInt64
        note("§22 reproduction h264-all.mp4 bytes \(allBytes.map(String.init) ?? "missing") (first failing run 5378961)")
        let dBase = try await Self.decodeCrops(rBase, regions: regions, expected: expected)
        let dEmpty = try await Self.decodeCrops(rEmpty, regions: regions, expected: expected)

        // 2. H.264 올바른 5자막 내보내기와 X만 뺀 짝
        let dAll = try await Self.decodeCrops(try await h264("all5", vc(steps([:]))), regions: regions, expected: expected)
        var dNo: [String: Decoded] = [:], cal: [String: Calib] = [:]
        for r in rs {
            let u = try await h264("no-\(r.caption.name)", vc(steps([:]).filter { $0.0.caption.name != r.caption.name }))
            dNo[r.caption.name] = try await Self.decodeCrops(u, regions: [reg(r.caption.name)], expected: expected)
        }

        // 3. 올바른 내보내기: 모든 자막의 경계 + 자막 없는 짝
        var rows: [String] = []
        for r in rs {
            let g = reg(r.caption.name), c = r.caption
            let k = Self.calibrate(dAll, dNo[c.name]!, g, c, frames: frames)
            cal[c.name] = k
            var cells: [String] = []
            for n in [c.start - 1, c.start, c.end - 1, c.end, c.end + 1] where n >= 0 && n < frames {
                let want = Self.expectedVisible(c, frame: n) ? "on" : "off"
                let v = Self.classify(dAll, dNo[c.name]!, g, frame: n, k)
                if v.verdict != want { allPass = false }
                cells.append(String(format: "f%d %@(want %@) g %.2f T1 %d", n, v.verdict, want, v.g, v.t1))
            }
            // 자막 없는 짝(빈 도구 − 기준) 모든 프레임
            var freeMax = -Double.infinity, freeAt = -1, freeOver = 0
            for n in 0..<frames {
                guard let a = dEmpty.crops[n]?[g.name], let b = dBase.crops[n]?[g.name] else { continue }
                let v = Self.glyphStat(a, b, g).g
                if v > freeMax { freeMax = v; freeAt = n }
                if v > k.tau { freeOver += 1 }
            }
            if freeOver > 0 { allPass = false }
            rows.append(String(format: "%@: tau %.2f (null max %.2f over %d frames) full %.2f | %@ | subtitle-free pair g max %.2f at f%d, frames over tau %d",
                               c.name, k.tau, k.nullMax, k.nullFrames, k.full, cells.joined(separator: "; "), freeMax, freeAt, freeOver))
        }
        note("H.264 correct 5-caption export (S = all5, C = no-X):\n  " + rows.joined(separator: "\n  "))

        // 4. §22 재현 4자막 H.264(ja-center, 같은 계약, 짝 = 일본어만 뺌)
        let jaCap = Self.captions.first { $0.name == "ja-center" }!
        let d4 = try await Self.decodeCrops(rAll, regions: [reg("ja-center")], expected: expected)
        let d4no = try await Self.decodeCrops(rNoJa, regions: [reg("ja-center")], expected: expected)
        let k4 = Self.calibrate(d4, d4no, reg("ja-center"), jaCap, frames: frames)
        var r4: [String] = []
        for n in [24, 25, 54, 55, 56] {
            let v = Self.classify(d4, d4no, reg("ja-center"), frame: n, k4)
            let want = Self.expectedVisible(jaCap, frame: n) ? "on" : "off"
            if v.verdict != want { allPass = false }
            r4.append(String(format: "f%d %@(want %@) g %.2f T1 %d", n, v.verdict, want, v.g, v.t1))
        }
        // 같은 영역의 기존 정의(전부 − 기준) T1 수: 재현 확인
        let t1old = dBase.crops[55]?["ja-center"].flatMap { b in d4.crops[55]?["ja-center"].map { Self.glyphStat($0, b, reg("ja-center")).t1 } } ?? -1
        note(String(format: "§22 reproduction (4 captions) ja-center: tau %.2f (null max %.2f, %d frames) full %.2f | %@ | old T1 all−base f55 %d (§22: 10)",
                    k4.tau, k4.nullMax, k4.nullFrames, k4.full, r4.joined(separator: "; "), t1old))

        // 5. H.264 변형(테스트 안에서만): 같은 τ·보임 기준(올바른 짝에서 정한 것)으로 판정
        var mutRows: [String] = []
        var limit: [String: String] = [:]
        for name in targets {
            let c = rs.first { $0.caption.name == name }!.caption, g = reg(name), k = cal[name]!
            for (tag, st) in mutations(c) {
                let u = try await h264("\(name)-\(tag)", vc(steps([name: st])))
                let d = try await Self.decodeCrops(u, regions: [g], expected: expected)
                let probe = tag == "early-start" ? c.start - 1 : c.end
                let v = Self.classify(d, dNo[name]!, g, frame: probe, k)
                let next = tag.hasPrefix("faint") ? Self.classify(d, dNo[name]!, g, frame: c.end + 1, k) : nil
                let detected = v.verdict != "off"
                if !tag.hasPrefix("faint") && !(v.verdict == "on") { allPass = false }
                if tag.hasPrefix("faint") && detected { limit[name] = String(tag.dropFirst(6)) }
                mutRows.append(String(format: "%@ %@: f%d %@ g %.2f (tau %.2f, 0.5·full %.2f) T1 %d", name, tag, probe, v.verdict, v.g, k.tau, 0.5 * k.full, v.t1)
                               + (next.map { String(format: " | f%d %@ g %.2f", c.end + 1, $0.verdict, $0.g) } ?? "")
                               + (detected ? " → DETECTED" : " → missed"))
            }
        }
        note("H.264 mutations (only in this test):\n  " + mutRows.joined(separator: "\n  "))
        summary.append("H.264 faint detection limit (smallest k detected, ladder 1of2…1of64): " + targets.map { "\($0) \(limit[$0] ?? "none")" }.joined(separator: ", "))

        // 6. ProRes 4444 대조(정답 아님): 같은 짝·같은 계약. 잰 뒤 지운다.
        var pr: [String] = []
        for name in targets {
            let c = rs.first { $0.caption.name == name }!.caption, g = reg(name)
            let uS = try await prores("all5", vc(steps([:]))), uC = try await prores("no-\(name)", vc(steps([:]).filter { $0.0.caption.name != name }))
            let s = try await Self.decodeCrops(uS, regions: [g], expected: expected), cN = try await Self.decodeCrops(uC, regions: [g], expected: expected)
            try? FileManager.default.removeItem(at: uS); try? FileManager.default.removeItem(at: uC)
            let k = Self.calibrate(s, cN, g, c, frames: frames)
            var cells: [String] = []
            for n in [c.start - 1, c.start, c.end - 1, c.end, c.end + 1] {
                let v = Self.classify(s, cN, g, frame: n, k)
                cells.append(String(format: "f%d %@ g %.2f", n, v.verdict, v.g))
            }
            var lim = "none"
            for (tag, st) in mutations(c) {
                let u = try await prores("\(name)-\(tag)", vc(steps([name: st])))
                let d = try await Self.decodeCrops(u, regions: [g], expected: expected)
                try? FileManager.default.removeItem(at: u)
                let probe = tag == "early-start" ? c.start - 1 : c.end
                let v = Self.classify(d, cN, g, frame: probe, k)
                if tag.hasPrefix("faint") && v.verdict != "off" { lim = String(tag.dropFirst(6)) }
                cells.append(String(format: "%@ f%d %@ g %.2f", tag, probe, v.verdict, v.g))
            }
            pr.append(String(format: "%@: tau %.2f (null max %.2f) full %.2f | ", name, k.tau, k.nullMax, k.full) + cells.joined(separator: "; ") + " | faint limit \(lim)")
        }
        note("ProRes 4444 control (not ground truth; same contract):\n  " + pr.joined(separator: "\n  "))

        summary.append("acceptance (correct boundaries, §22 f55 off, subtitle-free pair under tau, late/early detected): \(allPass ? "PASS" : "FAIL")")
        note("summary:\n  " + summary.joined(separator: "\n  "))
        XCTAssertTrue(allPass, "detector contract acceptance failed; see diagnostics/sb-testApproachBBoundaryDetector.txt")
    }

    /// §23 계약이 받아들임에 실패한 두 곳의 원인 진단(OTF_SB=1). 새 내보내기 없이 sb-detector/·sb-residue/ 파일만 읽는다. 판정 계약·문턱은 바꾸지 않는다.
    /// 1) gray 시작−1(f34)이 "부분": 글자 모양인가, 어느 프레임 종류(I/P/B, 디코딩 순서)인가
    /// 2) mixed-right 자막 없는 짝의 g > τ: K와 O가 배경의 다른 무늬(잡음 띠 y 450–900 안/밖)에 놓인 영향인가
    func testApproachBBoundaryDetectorFailureDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (_, _, expected) = try await plan()
        let rs = (Self.captions + [Self.grayCaption]).map(Self.raster)
        let regions = rs.map(Self.region)
        func reg(_ name: String) -> Region { regions.first { $0.name == name }! }
        let det = ExportEndToEndTests.root.appendingPathComponent("sb-detector"), res = ExportEndToEndTests.root.appendingPathComponent("sb-residue")

        // 프레임 종류와 디코딩 순서(압축 표본의 부착 정보)
        func frameTypes(_ url: URL) async throws -> [Int: String] {
            let a = AVURLAsset(url: url)
            let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: nil)
            r.add(o); r.startReading()
            var out: [Int: String] = [:], order = 0
            while let sb = o.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                guard pts.isValid, CMSampleBufferGetNumSamples(sb) > 0 else { continue }
                let n = Int((pts.seconds * 30).rounded())
                let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first ?? [:]
                let notSync = att[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
                let dependedOn = att[kCMSampleAttachmentKey_IsDependedOnByOthers] as? Bool
                out[n] = "\(notSync ? (dependedOn == false ? "nonref" : "ref") : "SYNC")#\(order)"
                order += 1
            }
            return out
        }
        let all5 = det.appendingPathComponent("h264-all5.mp4")
        let ft = try await frameTypes(all5)
        let show = [5, 8, 9, 10, 11, 30, 33, 34, 35, 36, 38, 39, 40, 41, 54, 55, 56, 70, 71, 72, 79, 80, 81]
        note("h264-all5 frame kind#decode-order (SYNC = key frame; ref/nonref = depended on by others or not): " + show.map { "f\($0) \(ft[$0] ?? "?")" }.joined(separator: ", "))
        let ftNo = try await frameTypes(det.appendingPathComponent("h264-no-gray.mp4"))
        note("h264-no-gray frame kind: " + [33, 34, 35, 36].map { "f\($0) \(ftNo[$0] ?? "?")" }.joined(separator: ", "))

        // 1) 시작−1 프레임의 K·O 평균과 글자 모양 그림(|d|×16)
        var rows: [String] = []
        let pairs: [(String, Int)] = [("gray", 33), ("gray", 34), ("gray", 35), ("ko-left", 9), ("mixed-right", 39), ("overlap-yellow", 29), ("ja-center", 24)]
        var decS: [String: Decoded] = [:], decC: [String: Decoded] = [:]
        for name in Set(pairs.map(\.0)) {
            decS[name] = try await Self.decodeCrops(all5, regions: [reg(name)], expected: expected)
            decC[name] = try await Self.decodeCrops(det.appendingPathComponent("h264-no-\(name).mp4"), regions: [reg(name)], expected: expected)
        }
        func png(_ url: URL, _ a: [UInt8], _ b: [UInt8], _ g: Region, gain: Int) throws {
            let ctx = CGContext(data: nil, width: g.w, height: g.h * 2, bitsPerComponent: 8, bytesPerRow: g.w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            let kset = Set(g.k)
            for i in 0..<(g.w * g.h) {
                let d = max(abs(Int(a[i * 4]) - Int(b[i * 4])), abs(Int(a[i * 4 + 1]) - Int(b[i * 4 + 1])), abs(Int(a[i * 4 + 2]) - Int(b[i * 4 + 2])))
                p[i] = UInt8(min(255, d * gain))                     // 위: |d|×gain
                p[g.w * g.h + i] = kset.contains(i) ? 255 : 0        // 아래: 글자 자리 K
            }
            let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        }
        for (name, n) in pairs {
            let g = reg(name)
            guard let a = decS[name]?.crops[n]?[name], let b = decC[name]?.crops[n]?[name] else { continue }
            let st = Self.glyphStat(a, b, g)
            // 글자 모양 대응: K 화소 d와 알파의 상관(영역 전체)
            var xs: [Double] = [], ys: [Double] = []
            let kset = Set(g.k)
            for i in 0..<(g.w * g.h) {
                xs.append(Double(max(abs(Int(a[i * 4]) - Int(b[i * 4])), abs(Int(a[i * 4 + 1]) - Int(b[i * 4 + 1])), abs(Int(a[i * 4 + 2]) - Int(b[i * 4 + 2])))))
                ys.append(kset.contains(i) ? 1 : 0)
            }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for i in 0..<xs.count { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx); syy += (ys[i] - my) * (ys[i] - my) }
            rows.append(String(format: "%@ f%d (%@): g %.2f K mean %.2f O mean %.2f corr(d, K) %.3f", name, n, ft[n] ?? "?", st.g, st.k, st.o, sxy / sqrt(sxx * syy)))
            if (name == "gray" && n == 34) || (name == "ko-left" && n == 9) || (name == "mixed-right" && n == 39) {
                try png(det.appendingPathComponent("diag-\(name)-f\(n)-d16.png"), a, b, g, gain: 16)
            }
        }
        note("start−1 frames, S = all5 vs C = no-X (H.264):\n  " + rows.joined(separator: "\n  "))

        // 2) mixed-right 자막 없는 짝: K·O를 잡음 띠 안(y < 900)과 밖으로 나눔
        let dB = try await Self.decodeCrops(res.appendingPathComponent("h264-base.mp4"), regions: [reg("mixed-right")], expected: expected)
        let dE = try await Self.decodeCrops(res.appendingPathComponent("h264-empty-tool.mp4"), regions: [reg("mixed-right")], expected: expected)
        let g = reg("mixed-right")
        func split(_ idx: [Int]) -> (Int, Int) { (idx.filter { g.y0 + $0 / g.w < 900 }.count, idx.filter { g.y0 + $0 / g.w >= 900 }.count) }
        let (kIn, kOut) = split(g.k), (oIn, oOut) = split(g.o)
        var mr: [String] = []
        for n in [70, 71, 72, 73, 74, 116] {
            guard let a = dE.crops[n]?["mixed-right"], let b = dB.crops[n]?["mixed-right"] else { continue }
            func mean(_ idx: [Int]) -> Double {
                idx.isEmpty ? .nan : Double(idx.reduce(0) { $0 + max(abs(Int(a[$1 * 4]) - Int(b[$1 * 4])), abs(Int(a[$1 * 4 + 1]) - Int(b[$1 * 4 + 1])), abs(Int(a[$1 * 4 + 2]) - Int(b[$1 * 4 + 2]))) }) / Double(idx.count)
            }
            let st = Self.glyphStat(a, b, g)
            mr.append(String(format: "f%d g %.2f | K in-noise %.2f out %.2f | O in-noise %.2f out %.2f", n, st.g,
                             mean(g.k.filter { g.y0 + $0 / g.w < 900 }), mean(g.k.filter { g.y0 + $0 / g.w >= 900 }),
                             mean(g.o.filter { g.y0 + $0 / g.w < 900 }), mean(g.o.filter { g.y0 + $0 / g.w >= 900 })))
        }
        note("mixed-right subtitle-free pair (empty-tool vs base); K in noise band \(kIn) out \(kOut), O in \(oIn) out \(oOut):\n  " + mr.joined(separator: "\n  "))
    }
}
