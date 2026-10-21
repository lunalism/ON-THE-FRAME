import AVFoundation
import CoreImage
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 자막 S1b(2026-10-12): 기본 합성기와의 차이를 좁히거나 특성을 잰다(docs/SUBTITLE-DESIGN.md §15). 계약(§13)은 그대로다.
extension CompositorEquivalenceTests {
    /// 한 videoComposition의 첫 오프라인 표본(BGRA)
    func firstFrame(_ comp: AVComposition, _ vc: AVVideoComposition) async throws -> FrameCompare.Frame {
        let (r, o) = try await Self.reader(comp, vc)
        defer { r.cancelReading() }
        guard let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { throw ProbeFailure("no frame \(String(describing: r.error))") }
        return FrameCompare.copy(pb)
    }
    static func luma(_ f: FrameCompare.Frame, _ x: Int, _ y: Int) -> Double {
        let i = (y * f.width + x) * 4
        return 0.2126 * Double(f.bgra[i + 2]) + 0.7152 * Double(f.bgra[i + 1]) + 0.0722 * Double(f.bgra[i])
    }
    /// 줄(가로 y 또는 세로 x)에서 밝기가 mid를 지나는 곳(선형 보간, 화소 경계 좌표: 화소 k는 [k, k+1))
    static func crossings(_ f: FrameCompare.Frame, row y: Int? = nil, column x: Int? = nil, mid: Double) -> [Double] {
        let n = y != nil ? f.width : f.height
        let v = (0..<n).map { k in y != nil ? luma(f, k, y!) : luma(f, x!, k) }
        var out: [Double] = []
        for k in 0..<(n - 1) where (v[k] - mid) * (v[k + 1] - mid) < 0 { out.append(Double(k) + 0.5 + (mid - v[k]) / (v[k + 1] - v[k])) }
        return out
    }

    /// 경계 규칙 측정: 판 하나(초록 1280×720 맞춤 1920×1080, 파랑 위) 또는 회전 표식 원본(검정 위)의 네 가장자리를 여러 배율·이동에서 잰다.
    /// 손 계산 사각형과 비교해 기본 합성기의 규칙을 찾고, 실험 합성기(경계 보정 끔·켬)를 같은 방법으로 잰다.
    /// 계약: 실험 합성기(기본 선택 = 경계 보정 켬)의 가장자리가 기본과 같아야 한다(측정법 정밀도 0.15 px, TransformTests와 같음).
    func testS1bFractionalGeometrySweep() async throws {
        let g = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.green.file))
        let b = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.blue.file))
        let rot = try await MediaProbe.inspect(try await Self.makeRotatedMarker(out))
        struct Case { let name: String; let rotated: Bool; let scale: Double; let x: Double; let y: Double }
        var cases: [Case] = []
        for x in [400.0, 400.25, 400.5, 400.75, 401.0, -300.3, -300.5, -300.7] { cases.append(.init(name: "g s0.4005 x\(x) y-200.25", rotated: false, scale: 0.4005, x: x, y: -200.25)) }
        for y in [150.5, 150.75, -99.4] { cases.append(.init(name: "g s0.4005 x400 y\(y)", rotated: false, scale: 0.4005, x: 400, y: y)) }
        for s in [0.3333, 0.75] { cases.append(.init(name: "g s\(s) x10.3 y7.7", rotated: false, scale: s, x: 10.3, y: 7.7)) }
        cases.append(.init(name: "rot s0.5 x10.3 y7.7", rotated: true, scale: 0.5, x: 10.3, y: 7.7))
        cases.append(.init(name: "rot s0.4005 x-300.5 y150.5", rotated: true, scale: 0.4005, x: -300.5, y: 150.5))
        let gm = (0.2126 * 40 + 0.7152 * 200 + 0.0722 * 60 + 0.2126 * 40 + 0.7152 * 60 + 0.0722 * 220) / 2   // 초록·파랑 밝기 가운데
        var rows: [String] = [], ruleMatches = 0, ruleTotal = 0, contractBad: [String] = []
        for c in cases {
            let top = UUID()
            var t: Timeline
            let media: [UUID: MediaAsset]
            let (w, h): (Double, Double)
            if c.rotated {
                t = try Timeline().registering(rot).inserting(media: rot.id)
                t = try t.settingTransform(clip: t.clips[0].id, ClipTransform(scale: c.scale, x: c.x, y: c.y))
                media = [rot.id: rot]; (w, h) = (607.5 * c.scale, 1080 * c.scale)
            } else {
                t = try Timeline().registering(b).registering(g).inserting(media: b.id).addingLane(.video, name: "G", id: top, outward: true)
                t = try t.placing(media: g.id, at: 0, videoLane: top, audioLane: nil)
                t = try t.settingTransform(clip: t.clips(inLane: top)[0].id, ClipTransform(scale: c.scale, x: c.x, y: c.y))
                media = [g.id: g, b.id: b]; (w, h) = (1920 * c.scale, 1080 * c.scale)
            }
            let cx = 960 + c.x, cy = 540 + c.y
            let hand = [cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2]   // 왼·오·위·아래
            // 화소 가운데 포함 규칙: 왼·위 = floor(e + 0.5), 오·아래 = ceil(e − 0.5)
            let centerRule = [(hand[0] + 0.5).rounded(.down), (hand[1] - 0.5).rounded(.up), (hand[2] + 0.5).rounded(.down), (hand[3] - 0.5).rounded(.up)]
            let plan = try await CompositionPlanner.plan(t, media: media)
            let mid = c.rotated ? 30.0 : gm
            let rowY = Int(cy.rounded()), colX = Int((c.rotated ? cx + w / 4 : cx).rounded())   // 회전 표식: 오른쪽 위가 흰색이라 세로줄은 오른쪽 절반 안(위 가장자리 흰색, 아래 회색)
            func measure(_ f: FrameCompare.Frame) -> [Double] {
                let hz = Self.crossings(f, row: rowY, mid: mid), vt = Self.crossings(f, column: colX, mid: mid)
                guard hz.count >= 2, vt.count >= 2 else { return [] }
                return [hz.first!, hz.last!, vt.first!, vt.last!]
            }
            let d = measure(try await firstFrame(plan.composition, plan.videoComposition))
            let off = measure(try await firstFrame(plan.composition, try ExperimentalComposition.videoComposition(from: plan.videoComposition, options: .init(snapEdges: false))))
            let on = measure(try await firstFrame(plan.composition, try ExperimentalComposition.videoComposition(from: plan.videoComposition)))
            func f(_ v: [Double]) -> String { v.isEmpty ? "unmeasured" : v.map { String(format: "%.3f", $0) }.joined(separator: " ") }
            rows.append("\(c.name): hand \(f(hand)) | center-rule \(f(centerRule)) | default \(f(d)) | exp(snap off) \(f(off)) | exp(snap on) \(f(on))")
            if d.count == 4 { for k in 0..<4 { ruleTotal += 1; if abs(d[k] - centerRule[k]) <= 0.15 { ruleMatches += 1 } } }
            if d.count == 4, on.count == 4 { for k in 0..<4 where abs(d[k] - on[k]) > 0.15 { contractBad.append("\(c.name) edge \(k): default \(d[k]) experimental \(on[k])") } }
            else { contractBad.append("\(c.name): unmeasured default \(d.count) experimental \(on.count)") }
        }
        note("geometry sweep (left right top bottom):\n  " + rows.joined(separator: "\n  "))
        note("default edges matching the pixel-center rule within 0.15 px: \(ruleMatches)/\(ruleTotal)")
        note("contract (experimental with snap on vs default, 0.15 px): \(contractBad.isEmpty ? "all edges match" : "\(contractBad.count) differ: \(contractBad.prefix(8))")")
        XCTAssertTrue(contractBad.isEmpty, "\(contractBad.prefix(8))")
    }

    /// 먼 가장자리(원본 마지막 행) 문턱 측정(선택 실행 진단, OTF_S1B_DIAG=1): 초록 판 75%(행당 1.125 px)를 세로로 u만큼 옮겨,
    /// 아래 경계 화소(952)의 가운데가 원본 행 좌표 719.5 + δ(δ = 0.5 − u/1.125)에 오게 한다. 화소 가운데 포함 규칙이면 δ < 0.5에서 늘 그린다.
    /// 위 경계(화소 142 가운데 = 원본 −u/1.125)도 함께 적는다. 판정 없이 기록만 한다.
    func testS1bFarEdgeThresholdDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_S1B_DIAG"] == "1", "진단 실행은 OTF_S1B_DIAG=1일 때만")
        let g = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.green.file))
        let b = try await MediaProbe.inspect(fixtures.appendingPathComponent(PlateFixture.blue.file))
        let gm = (0.2126 * 40 + 0.7152 * 200 + 0.0722 * 60 + 0.2126 * 40 + 0.7152 * 60 + 0.0722 * 220) / 2
        var rows: [String] = []
        for k in 0...10 {
            let delta = 0.05 * Double(k)             // 0 … 0.5
            let u = (0.5 - delta) * 1.125
            let top = UUID()
            var t = try Timeline().registering(b).registering(g).inserting(media: b.id).addingLane(.video, name: "G", id: top, outward: true)
            t = try t.placing(media: g.id, at: 0, videoLane: top, audioLane: nil)
            // 위 가장자리 = 142.5 + u → 가운데 y = 142.5 + u + 405 = 540 + y
            t = try t.settingTransform(clip: t.clips(inLane: top)[0].id, ClipTransform(scale: 0.75, x: 10.3, y: 142.5 + u + 405 - 540))
            let plan = try await CompositionPlanner.plan(t, media: [g.id: g, b.id: b])
            let f = try await firstFrame(plan.composition, plan.videoComposition)
            let vt = Self.crossings(f, column: 970, mid: gm)
            rows.append(String(format: "delta %.2f (bottom pixel 952 center at source row %.3f, top pixel 142 center at %.3f): default top %@ bottom %@",
                               delta, 719.5 + delta, -u / 1.125, vt.first.map { String(format: "%.3f", $0) } ?? "-", vt.last.map { String(format: "%.3f", $0) } ?? "-"))
        }
        note("far-edge threshold (scale 0.75, rows):\n  " + rows.joined(separator: "\n  "))
    }

    /// 보간 비교(선택 실행 진단, OTF_S1B_DIAG=1): 세밀한 무늬 원본(1280×720: 1·2·4 px 줄무늬, 바둑판, 기울기, 평평한 색 칸)을
    /// 확대(맞춤 1.5배)·축소(40.05%, 소수 이동)·축소(1920×1080 무늬 75%)로 놓고, 기본 합성기와 실험 합성기(보간 4가지, 경계 보정 켬)를
    /// 같은 오프라인 리더 버퍼로 비교한다. 평평한 곳(기본 출력에서 이웃 2화소 밝기 폭 ≤ 2)과 세부가 있는 곳을 나눠 잰다. 출력 버퍼 색 첨부도 적는다.
    func testS1bInterpolationDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_S1B_DIAG"] == "1", "진단 실행은 OTF_S1B_DIAG=1일 때만")
        func pattern(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (UInt8, UInt8, UInt8) {
            let q = x * 4 / w, r = y * 3 / h        // 4×3 칸
            switch (q, r) {
            case (0, 0): return x % 2 == 0 ? (230, 230, 230) : (20, 20, 20)                 // 1 px 세로 줄무늬
            case (1, 0): return (x / 2) % 2 == 0 ? (230, 40, 40) : (40, 40, 230)          // 2 px 색 줄무늬
            case (2, 0): return (y / 4) % 2 == 0 ? (240, 240, 40) : (20, 20, 120)         // 4 px 가로 줄무늬
            case (3, 0): return ((x / 8) + (y / 8)) % 2 == 0 ? (250, 250, 250) : (0, 0, 0) // 8 px 바둑판
            case (0, 1): let v = UInt8(x * 255 / max(1, w / 4)); return (v, v, v)          // 가로 기울기
            case (1, 1): return (200, 60, 60)                                             // 평평한 색
            case (2, 1): return (60, 180, 90)
            case (3, 1): return (50, 70, 200)
            case (0, 2): return ((x + y) / 3) % 2 == 0 ? (220, 220, 220) : (30, 30, 30)    // 대각선 줄무늬
            case (1, 2): return (128, 128, 128)
            case (2, 2): let v = UInt8(y * 255 / h); return (255 - v, v, 128)              // 세로 색 기울기
            default: return (x * y) % 7 == 0 ? (255, 255, 255) : (10, 10, 10)             // 불규칙 점
            }
        }
        let small = out.appendingPathComponent("pattern-1280.mp4"), large = out.appendingPathComponent("pattern-1920.mp4")
        try await Self.writePattern(small, w: 1280, h: 720, frames: 2) { pattern($0, $1, 1280, 720) }
        try await Self.writePattern(large, w: 1920, h: 1080, frames: 2) { pattern($0, $1, 1920, 1080) }
        let ps = try await MediaProbe.inspect(small), pl = try await MediaProbe.inspect(large)
        struct Case { let name: String; let m: MediaAsset; let x: ClipTransform? }
        let cases = [Case(name: "up 1.5x (1280 fit)", m: ps, x: nil),
                     Case(name: "down 0.4005 x400.5 y-200.25 (1280)", m: ps, x: ClipTransform(scale: 0.4005, x: 400.5, y: -200.25)),
                     Case(name: "down 0.75 x10.3 y7.7 (1920)", m: pl, x: ClipTransform(scale: 0.75, x: 10.3, y: 7.7))]
        var rows: [String] = [], meta: [String] = []
        for c in cases {
            var t = try Timeline().registering(c.m).inserting(media: c.m.id)
            if let x = c.x { t = try t.settingTransform(clip: t.clips[0].id, x) }
            let plan = try await CompositionPlanner.plan(t, media: [c.m.id: c.m])
            let (dr, dout) = try await Self.reader(plan.composition, plan.videoComposition)
            guard let dsb = dout.copyNextSampleBuffer(), let dpb = CMSampleBufferGetImageBuffer(dsb) else { XCTFail("default frame"); continue }
            let d = FrameCompare.copy(dpb)
            if meta.isEmpty { meta.append("default output attachments: \(Self.colorTags(dpb)) format \(CVPixelBufferGetPixelFormatType(dpb))") }
            dr.cancelReading()
            for sampling in ExperimentalCompositorOptions.Sampling.allCases {
                let vc = try ExperimentalComposition.videoComposition(from: plan.videoComposition, options: .init(snapEdges: true, sampling: sampling))
                let (er, eout) = try await Self.reader(plan.composition, vc)
                guard let esb = eout.copyNextSampleBuffer(), let epb = CMSampleBufferGetImageBuffer(esb) else { XCTFail("experimental frame"); continue }
                let e = FrameCompare.copy(epb)
                if meta.count == 1 { meta.append("experimental output attachments: \(Self.colorTags(epb)) format \(CVPixelBufferGetPixelFormatType(epb))") }
                er.cancelReading()
                rows.append("\(c.name) \(sampling.rawValue): " + Self.regionStats(d, e))
            }
        }
        // 표본 좌표 가설: linear에 출력 공간 이동(반·4분의 1 화소)을 주고 같은 비교를 한다(확대·축소 각 하나)
        for c in [cases[0], cases[2]] {
            var t = try Timeline().registering(c.m).inserting(media: c.m.id)
            if let x = c.x { t = try t.settingTransform(clip: t.clips[0].id, x) }
            let plan = try await CompositionPlanner.plan(t, media: [c.m.id: c.m])
            let d = try await firstFrame(plan.composition, plan.videoComposition)
            for (dx, dy) in [(-0.5, -0.5), (-0.25, -0.25), (0.25, 0.25), (0.5, 0.5), (-0.5, 0), (0, -0.5), (0.5, 0), (0, 0.5)] {
                let vc = try ExperimentalComposition.videoComposition(from: plan.videoComposition, options: .init(testSampleOffset: CGPoint(x: dx, y: dy)))
                let e = try await firstFrame(plan.composition, vc)
                rows.append("\(c.name) linear offset (\(dx), \(dy)): " + Self.regionStats(d, e))
            }
        }
        note("interpolation (default vs experimental, offline reader buffers, 2-px sampled):\n  " + rows.joined(separator: "\n  "))
        note("color metadata: \(meta)")
    }
    static func colorTags(_ pb: CVPixelBuffer) -> String {
        let keys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
        return keys.map { k in "\(k)=\(CVBufferCopyAttachment(pb, k, nil).map { "\($0)" } ?? "none")" }.joined(separator: ", ")
    }
    /// 평평한 곳(기본 출력에서 상하좌우 2화소 밝기 폭 ≤ 2, 검정 바깥 제외)과 세부가 있는 곳의 차이
    static func regionStats(_ a: FrameCompare.Frame, _ b: FrameCompare.Frame) -> String {
        var fMax = 0, fSum = 0.0, fN = 0, dMax = 0, dSE = 0.0, dN = 0, fBig = 0
        for y in stride(from: 2, to: a.height - 2, by: 2) { for x in stride(from: 2, to: a.width - 2, by: 2) {
            let i = (y * a.width + x) * 4
            let l0 = luma(a, x, y)
            if l0 < 1 && luma(b, x, y) < 1 { continue }   // 둘 다 검정 바깥
            let flat = abs(luma(a, x - 2, y) - l0) <= 2 && abs(luma(a, x + 2, y) - l0) <= 2 && abs(luma(a, x, y - 2) - l0) <= 2 && abs(luma(a, x, y + 2) - l0) <= 2
            var d = 0, se = 0.0
            for c in 0..<3 { let e = abs(Int(a.bgra[i + c]) - Int(b.bgra[i + c])); d = max(d, e); se += Double(e * e) }
            if flat { fMax = max(fMax, d); fSum += Double(d); fN += 1; if d > 3 { fBig += 1 } } else { dMax = max(dMax, d); dSE += se; dN += 1 }
        } }
        let dPSNR = dSE == 0 ? Double.infinity : 10 * log10(255 * 255 / (dSE / Double(max(1, dN * 3))))
        return String(format: "flat n %d max %d mean %.2f (>3: %d) | detail n %d max %d PSNR %.2f dB", fN, fMax, fSum / Double(max(1, fN)), fBig, dN, dMax, dPSNR)
    }

    /// 640×360 원본 + 90° 회전 표시, 원본 왼쪽 위 1/4 흰색(235)·나머지 회색(60). 30프레임.
    static func makeRotatedMarker(_ dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("rot90-marker-\(UUID().uuidString.prefix(6)).mp4")
        try await writePattern(url, w: 640, h: 360, frames: 30, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)) { x, y in
            let v: UInt8 = (x < 320 && y < 180) ? 235 : 60; return (v, v, v)
        }
        return url
    }
    /// 생성 원본(H.264): 화소 함수 (x, y) → (R, G, B)
    static func writePattern(_ url: URL, w: Int, h: Int, frames: Int, transform: CGAffineTransform = .identity, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) async throws {
        let wr = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        i.transform = transform
        i.expectsMediaDataInRealTime = false
        wr.add(i)
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                                                         kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard wr.startWriting() else { throw ProbeFailure("writer") }
        wr.startSession(atSourceTime: .zero)
        var pix = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let (r, g, b) = pixel(x, y); let o = (y * w + x) * 4; pix[o] = b; pix[o + 1] = g; pix[o + 2] = r; pix[o + 3] = 255 } }
        for k in 0..<frames {
            while !i.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            guard let buf = pb else { throw ProbeFailure("buffer") }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(buf)
            pix.withUnsafeBufferPointer { p in for y in 0..<h { memcpy(base + y * bpr, p.baseAddress! + y * w * 4, w * 4) } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            guard ad.append(buf, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: 30)) else { throw ProbeFailure("append") }
        }
        i.markAsFinished(); wr.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 30)); await wr.finishWriting()
        guard wr.status == .completed else { throw ProbeFailure("finish \(String(describing: wr.error))") }
    }
}

// MARK: - S1b: E2 조건(새 프로세스 첫 재생)과 취소

/// 직접 프로토콜 검사용 요청: 끝난 방식을 센다(정확히 한 번이어야 한다).
final class FakeCompositionRequest: ExperimentalCompositionRequest, @unchecked Sendable {
    let compositionTime: CMTime
    let experimentalInstruction: ExperimentalInstruction?
    let source: CVPixelBuffer?
    private let lock = NSLock()
    private(set) var finished = 0, cancelled = 0, failed = 0
    private(set) var output: CVPixelBuffer?
    init(time: CMTime, instruction: ExperimentalInstruction?, source: CVPixelBuffer?) {
        compositionTime = time; experimentalInstruction = instruction; self.source = source
    }
    func sourceFrame(byTrackID trackID: CMPersistentTrackID) -> CVPixelBuffer? { source }
    func finish(withComposedVideoFrame composedVideoFrame: CVPixelBuffer) { lock.lock(); finished += 1; output = composedVideoFrame; lock.unlock() }
    func finish(with error: any Error) { lock.lock(); failed += 1; lock.unlock() }
    func finishCancelledRequest() { lock.lock(); cancelled += 1; lock.unlock() }
    var ends: Int { lock.lock(); defer { lock.unlock() }; return finished + cancelled + failed }
}

extension CompositorEquivalenceTests {
    /// 직접 프로토콜 검사(AVFoundation 없이 합성기의 요청 처리만): 그리는 중 취소 → 그 요청과 대기 요청은 결과 없이 취소로 끝나고,
    /// 모든 요청은 정확히 한 번 끝나며, 취소 뒤 새 요청은 올바른 화면으로 성공한다. 지시가 없는 요청은 오류로 끝난다.
    func testS1bDirectCancellationProtocol() async throws {
        let comp = ExperimentalCompositor()
        comp.testRenderSize = CGSize(width: 64, height: 36)
        let log = ExperimentalCompositorLog()
        let ins = ExperimentalInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 100, timescale: 30)),
                                          layers: [.init(trackID: 1, transform: .identity)], options: .init(), log: log)
        func solid(_ v: UInt8) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            CVPixelBufferLockBaseAddress(pb!, []); memset(CVPixelBufferGetBaseAddress(pb!), Int32(v), CVPixelBufferGetDataSize(pb!)); CVPixelBufferUnlockBaseAddress(pb!, [])
            return pb!
        }
        let began = DispatchSemaphore(value: 0)
        comp.testDidBeginRender = { _ in began.signal() }
        ExperimentalCompositor.testRenderDelayMicroseconds = 50_000
        defer { ExperimentalCompositor.testRenderDelayMicroseconds = 0 }
        let first = (0..<8).map { FakeCompositionRequest(time: CMTime(value: CMTimeValue($0), timescale: 30), instruction: ins, source: solid(100)) }
        first.forEach { comp.start($0) }
        // 첫 요청이 그리기 시작한 뒤(지연 중) 취소
        XCTAssertEqual(began.wait(timeout: .now() + 2), .success)
        comp.cancelAllPendingVideoCompositionRequests()
        comp.testDidBeginRender = nil
        ExperimentalCompositor.testRenderDelayMicroseconds = 0
        let later = (0..<3).map { FakeCompositionRequest(time: CMTime(value: CMTimeValue(20 + $0), timescale: 30), instruction: ins, source: solid(200)) }
        later.forEach { comp.start($0) }
        let noInstruction = FakeCompositionRequest(time: .zero, instruction: nil, source: nil)
        comp.start(noInstruction)
        let deadline = Date().addingTimeInterval(5)
        while (first + later + [noInstruction]).contains(where: { $0.ends == 0 }), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)   // 두 번 끝나는지 볼 여유
        let firstOutcomes = first.map { "\($0.finished)/\($0.cancelled)/\($0.failed)" }
        note("direct protocol: first batch (finished/cancelled/failed) \(firstOutcomes); later \(later.map { "\($0.finished)/\($0.cancelled)/\($0.failed)" }); no-instruction \(noInstruction.finished)/\(noInstruction.cancelled)/\(noInstruction.failed); log started \(log.snapshot.started) outcomes \(log.snapshot.outcomes.map(\.rawValue))")
        XCTAssertTrue(first.allSatisfy { $0.ends == 1 && $0.cancelled == 1 && $0.output == nil }, "first batch \(firstOutcomes)")
        XCTAssertTrue(later.allSatisfy { $0.ends == 1 && $0.finished == 1 }, "later batch")
        for r in later {
            guard let o = r.output else { continue }
            CVPixelBufferLockBaseAddress(o, .readOnly)
            let p = CVPixelBufferGetBaseAddress(o)!.assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual([p[0], p[1], p[2]], [200, 200, 200], "later output is the new source")
            CVPixelBufferUnlockBaseAddress(o, .readOnly)
        }
        XCTAssertEqual(noInstruction.ends, 1); XCTAssertEqual(noInstruction.failed, 1)
    }

    /// AVFoundation이 부르는 취소(선택 실행 진단, OTF_S1B_DIAG=1): 그리기를 느리게(30 ms) 한 실험 합성기로 재생하면서 정확 탐색을 연달아 보낸다.
    /// 취소 호출 수, 요청마다 끝난 방식(정확히 한 번), 마지막 탐색 프레임의 화면 코드를 적는다.
    @MainActor func testS1bObservedCancellationDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_S1B_DIAG"] == "1", "진단 실행은 OTF_S1B_DIAG=1일 때만")
        let ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        let tb = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TB.mp4"))
        let t = try Timeline().registering(ta).registering(tb).inserting(media: ta.id).inserting(media: tb.id)
        let plan = try await CompositionPlanner.plan(t, media: [ta.id: ta, tb.id: tb])
        let log = ExperimentalCompositorLog()
        let cplan = try custom(plan, log)
        let calls = CallCounter()
        ExperimentalCompositor.cancelObserver = { calls.add() }
        ExperimentalCompositor.testRenderDelayMicroseconds = 30_000
        defer { ExperimentalCompositor.cancelObserver = nil; ExperimentalCompositor.testRenderDelayMicroseconds = 0 }
        let item = AVPlayerItem(asset: cplan.composition)
        item.videoComposition = cplan.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        let deadline = Date().addingTimeInterval(10)
        while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        player.play()
        for k in 0..<12 {
            try await Task.sleep(nanoseconds: 120_000_000)
            player.seek(to: CMTime(value: CMTimeValue((k * 53) % 200), timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
        player.pause()
        ExperimentalCompositor.testRenderDelayMicroseconds = 0
        let last = 77, tm = CMTime(value: CMTimeValue(last), timescale: 30)
        _ = await player.seek(to: tm, toleranceBefore: .zero, toleranceAfter: .zero)
        var got = "none"
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if output.hasNewPixelBuffer(forItemTime: tm) {
                var shown = CMTime.invalid
                if let pb = output.copyPixelBuffer(forItemTime: tm, itemTimeForDisplay: &shown), abs((shown - tm).seconds) < 0.0005 { got = ExportJudge.label(E2Metrics.measure(pb)); break }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        player.replaceCurrentItem(with: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        let s = log.snapshot
        let f = s.outcomes.filter { $0 == .finished }.count, c = s.outcomes.filter { $0 == .cancelled }.count, e = s.outcomes.filter { $0 == .failed }.count
        let (expected, _) = try ExportJudge.expectations([.init(file: "otf-TA.mp4", sourceIn: 0, length: 120), .init(file: "otf-TB.mp4", sourceIn: 0, length: 120)])
        note("observed cancellation: cancelAll calls \(calls.value) | requests started \(s.started) finished \(f) cancelled \(c) failed \(e) | final seek \(last) got \(got) expected \(expected[last].label)")
        XCTAssertEqual(s.started, f + c + e, "every request ends exactly once")
        XCTAssertGreaterThan(calls.value, 0, "AVFoundation called cancelAll")
        XCTAssertEqual(got, expected[last].label)
        checkSources(log, "observed cancellation")
    }

    /// E2 조건(선택 실행 진단, OTF_S1B_PLAY=experimental|default): 새 프로세스에서 처음으로 재생(시작부터 보통 속도)하며 표시되는 프레임마다
    /// 화면 코드를 표시 시각의 기대값과 비교한다. 섞인 fps 타임라인(A-010)을 쓴다. 실험 합성기면 받은 원본 프레임 시각도 본다.
    /// 반드시 프로세스마다 한 번만(swift test --filter 이 테스트) 돌린다: "첫 재생" 조건.
    @MainActor func testS1bFreshProcessFirstPlayback() async throws {
        let mode = ProcessInfo.processInfo.environment["OTF_S1B_PLAY"] ?? ""
        try XCTSkipUnless(mode == "experimental" || mode == "default", "진단 실행은 OTF_S1B_PLAY=experimental|default일 때만")
        func ins(_ f: TimedFixture) async throws -> MediaAsset { try await MediaProbe.inspect(fixtures.appendingPathComponent(f.file)) }
        let n = try await ins(.ntsc), p = try await ins(.pal), v = try await ins(.vfr), f = try await ins(.film), h = try await ins(.high)
        let names = [n.id: TimedFixture.ntsc.file, p.id: TimedFixture.pal.file, v.id: TimedFixture.vfr.file, f.id: TimedFixture.film.file, h.id: TimedFixture.high.file]
        var t = Timeline().registering(n).registering(p).registering(v).registering(f).registering(h)
        t = try t.inserting(media: p.id).inserting(media: n.id).inserting(media: v.id).inserting(media: f.id).inserting(media: h.id)
        let refs = t.clips.map { ExportJudge.ClipRef(file: names[$0.mediaID]!, start: $0.start, sourceIn: $0.sourceIn, length: $0.length) }
        let (expected, _) = try ExportJudge.expectations(refs, durationFrames: t.durationFrames)
        let plan = try await CompositionPlanner.plan(t, media: [n.id: n, p.id: p, v.id: v, f.id: f, h.id: h])
        let log = ExperimentalCompositorLog()
        let use = mode == "experimental" ? try custom(plan, log) : plan
        let item = AVPlayerItem(asset: use.composition)
        item.videoComposition = use.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        let deadline = Date().addingTimeInterval(10)
        while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        player.play()
        var seen: [(Int, String, Bool)] = [], firstShown: [String] = [], endHold: [String] = []
        let stop = Date().addingTimeInterval(Double(t.durationFrames) / 30 + 1)
        while Date() < stop {
            let it = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: it) {
                var shown = CMTime.invalid
                if let pb = output.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: &shown), shown.isNumeric {
                    let k = Int((shown.seconds * 30).rounded())
                    let m = E2Metrics.measure(pb)
                    // 끝(표시 시각 ≥ 타임라인 길이): 재생이 끝에 닿아 남아 보이는 화면. 타임라인 프레임이 아니므로 판정하지 않고 따로 적는다
                    if k >= expected.count { endHold.append("\(k):\(ExportJudge.label(m))"); continue }
                    let ok = k >= 0 && ExportJudge.matches(m, expected[k])
                    seen.append((k, ExportJudge.label(m), ok))
                    if firstShown.count < 5 { firstShown.append("\(k):\(ExportJudge.label(m))\(ok ? "" : "≠\(k < expected.count && k >= 0 ? expected[k].label : "?")")") }
                }
            }
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        player.pause(); player.replaceCurrentItem(with: nil)
        let bad = seen.filter { !$0.2 }
        let firstRequests = log.snapshot.entries.prefix(5).map { String(format: "%.4f", $0.time.seconds) }
        note("fresh-process first playback (\(mode)): shown \(seen.count) of \(t.durationFrames) frames, end-hold \(Array(Set(endHold)).sorted()) | mismatched \(bad.count) \(bad.prefix(5).map { "\($0.0):\($0.1)≠\($0.0 < expected.count && $0.0 >= 0 ? expected[$0.0].label : "?")" }) | first shown \(firstShown)" + (mode == "experimental" ? " | first requests \(firstRequests)" : ""))
        XCTAssertTrue(bad.isEmpty, "mismatched frames \(bad.prefix(5))")
        if mode == "experimental" { checkSources(log, "first playback") }
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
