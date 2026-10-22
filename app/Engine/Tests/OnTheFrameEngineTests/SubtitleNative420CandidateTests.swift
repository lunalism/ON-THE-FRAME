import AVFoundation
import CryptoKit
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 4:2:0 자막 후보의 시각 호환 확인(2026-10-22, docs/SUBTITLE-DESIGN.md §37, 실험 후보 — 구조 채택 아님). 선택 실행(OTF_SB=1).
/// 무채색 ko-left [10, 40)과 유색 overlap-yellow [50, 65)(래스터 그대로, 구간만 옮김)을 미리 곱한 값으로 4:2:0 위에 섞는다(나눗셈 없음).
/// 가정: 래스터의 sRGB 태그 값을 BT.709 R′G′B′로 그대로(색 관리 없음), 감마 값 섞기, 8비트 반올림, 비디오 범위, 색차 위치 Left.
struct N420Layer: @unchecked Sendable {
    let name: String, start: Int, end: Int
    let yIdx: [Int], ya: [Double], yaSub: [Double]                     // 밝기: a, a·Y_sub
    let cIdx: [Int], cWA: [Double], cWACb: [Double], cWACr: [Double]   // 색차: Σw·a, Σw·a·Cb_sub, Σw·a·Cr_sub
    let yMask: [Bool], cMask: [Bool]
    let interior: [Int]                                                // 알파 255이고 2화소 안이 모두 255인 화소
    let intended: (Double, Double, Double)                             // 래스터가 뜻한 색(0–255, 안쪽 화소의 미리 곱한 값 = 그대로)
    let aFull: [Double], aYFull: [Double], aCbFull: [Double], aCrFull: [Double]   // 프레임 좌표 a, a·Y, a·Cb, a·Cr(참조 계산용)
    static let w = 1920, h = 1080, cw = 960, ch = 540

    init(_ r: SubtitleApproachBTests.Raster, start: Int, end: Int) {
        name = r.caption.name; self.start = start; self.end = end
        let img = r.image, rw = img.width, rh = img.height, bpr = img.bytesPerRow
        let data = img.dataProvider!.data! as Data
        let x0 = Int(r.rect.minX), y0 = Int(r.rect.minY)
        precondition(Double(x0) == r.rect.minX && Double(y0) == r.rect.minY && x0 >= 2 && x0 + rw + 2 <= Self.w && y0 + rh <= Self.h)
        var A = [Double](repeating: 0, count: Self.w * Self.h), AY = A, ACb = A, ACr = A
        var yIdx: [Int] = [], ya: [Double] = [], yaSub: [Double] = [], yMask = [Bool](repeating: false, count: Self.w * Self.h)
        var full = Set<Int>(), intended = (0.0, 0.0, 0.0), nInt = 0.0
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<rh { for x in 0..<rw {
                let o = y * bpr + x * 4
                let a8 = p[o + 3]; guard a8 > 0 else { continue }
                let a = Double(a8) / 255, Rp = Double(p[o + 2]) / 255, Gp = Double(p[o + 1]) / 255, Bp = Double(p[o]) / 255   // 미리 곱한 값
                let yp = 0.2126 * Rp + 0.7152 * Gp + 0.0722 * Bp
                let i = (y0 + y) * Self.w + (x0 + x)
                A[i] = a; AY[i] = 16 * a + 219 * yp; ACb[i] = 128 * a + 224 * (Bp - yp) / 1.8556; ACr[i] = 128 * a + 224 * (Rp - yp) / 1.5748
                yIdx.append(i); ya.append(a); yaSub.append(AY[i]); yMask[i] = true
                if a8 == 255 { full.insert(i); intended.0 += Double(p[o + 2]); intended.1 += Double(p[o + 1]); intended.2 += Double(p[o]); nInt += 1 }
            } }
        }
        self.intended = (intended.0 / nInt, intended.1 / nInt, intended.2 / nInt)
        interior = full.filter { i in (-2...2).allSatisfy { dy in (-2...2).allSatisfy { dx in full.contains(i + dy * Self.w + dx) } } }.sorted()
        var cIdx: [Int] = [], cWA: [Double] = [], cWACb: [Double] = [], cWACr: [Double] = [], cMask = [Bool](repeating: false, count: Self.cw * Self.ch)
        for j in max(0, y0 / 2 - 1)...min(Self.ch - 1, (y0 + rh) / 2 + 1) { for k in max(0, x0 / 2 - 1)...min(Self.cw - 1, (x0 + rw) / 2 + 1) {
            var swa = 0.0, scb = 0.0, scr = 0.0, any = false
            for (dx, wx) in [(-1, 0.25), (0, 0.5), (1, 0.25)] { for dy in 0...1 {
                let i = (2 * j + dy) * Self.w + 2 * k + dx; guard A[i] > 0 else { continue }
                any = true; swa += wx * 0.5 * A[i]; scb += wx * 0.5 * ACb[i]; scr += wx * 0.5 * ACr[i]
            } }
            if any { let c = j * Self.cw + k; cIdx.append(c); cWA.append(swa); cWACb.append(scb); cWACr.append(scr); cMask[c] = true }
        } }
        self.yIdx = yIdx; self.ya = ya; self.yaSub = yaSub; self.yMask = yMask; self.cIdx = cIdx; self.cWA = cWA; self.cWACb = cWACb; self.cWACr = cWACr; self.cMask = cMask
        aFull = A; aYFull = AY; aCbFull = ACb; aCrFull = ACr
    }
    func visible(_ n: Int) -> Bool { n >= start && n < end }
    func composite(y: UnsafeMutablePointer<UInt8>, ybpr: Int, c: UnsafeMutablePointer<UInt8>, cbpr: Int) {
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        for t in 0..<yIdx.count { let i = yIdx[t], p = y + (i / Self.w) * ybpr + i % Self.w; p.pointee = clamp(Double(p.pointee) * (1 - ya[t]) + yaSub[t]) }
        for t in 0..<cIdx.count {
            let p = c + (cIdx[t] / Self.cw) * cbpr + 2 * (cIdx[t] % Self.cw)
            p[0] = clamp(Double(p[0]) * (1 - cWA[t]) + cWACb[t]); p[1] = clamp(Double(p[1]) * (1 - cWA[t]) + cWACr[t])
        }
    }
}

final class N420CandidateCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    nonisolated(unsafe) static var layers: [N420Layer] = []
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: [Passthrough420Compositor.format]] }
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]
    private let lock = NSLock()
    private var context: AVVideoCompositionRenderContext?
    private let queue = DispatchQueue(label: "dev.ontheframe.n420candidate")
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { lock.lock(); context = newRenderContext; lock.unlock() }
    func cancelAllPendingVideoCompositionRequests() {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        Passthrough420Compositor.record { $0.requests += 1 }
        let box = Passthrough420Compositor.RequestBox(r: request)
        queue.async { [self] in process(box.r) }
    }
    private func fail(_ r: AVAsynchronousVideoCompositionRequest, _ msg: String) {
        Passthrough420Compositor.record { $0.errors.append(msg) }
        r.finish(with: NSError(domain: "N420Candidate", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]))
    }
    private func process(_ r: AVAsynchronousVideoCompositionRequest) {
        guard let ins = r.videoCompositionInstruction as? Passthrough420Instruction, let src = r.sourceFrame(byTrackID: ins.trackID) else { fail(r, "instruction/source"); return }
        let sf = CVPixelBufferGetPixelFormatType(src); Passthrough420Compositor.record { $0.sourceFormats.insert(sf) }
        lock.lock(); let ctx = context; lock.unlock()
        guard sf == Passthrough420Compositor.format, let ctx, let out = ctx.newPixelBuffer() else { fail(r, "source format or no buffer"); return }
        let of = CVPixelBufferGetPixelFormatType(out); Passthrough420Compositor.record { $0.outputFormats.insert(of) }
        guard of == Passthrough420Compositor.format, CVPixelBufferGetWidth(src) == N420Layer.w, CVPixelBufferGetHeight(src) == N420Layer.h,
              CVPixelBufferGetWidth(out) == N420Layer.w, CVPixelBufferGetHeight(out) == N420Layer.h else { fail(r, "format/size"); return }
        if let mt = ExperimentalCompositor.movieTime(src) { if CMTimeCompare(mt, r.compositionTime) != 0 { Passthrough420Compositor.record { $0.movieTimeMismatch += 1 } } }
        else { Passthrough420Compositor.record { $0.movieTimeMissing += 1 } }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(out, [])
        for plane in 0..<2 {
            let sb = CVPixelBufferGetBaseAddressOfPlane(src, plane)!, ob = CVPixelBufferGetBaseAddressOfPlane(out, plane)!
            let sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, plane), obpr = CVPixelBufferGetBytesPerRowOfPlane(out, plane)
            let bytes = CVPixelBufferGetWidthOfPlane(src, plane) * (plane == 0 ? 1 : 2)
            for y in 0..<CVPixelBufferGetHeightOfPlane(src, plane) { memcpy(ob + y * obpr, sb + y * sbpr, bytes) }
        }
        let n = Int((r.compositionTime.seconds * 30).rounded())
        for l in Self.layers where l.visible(n) {
            l.composite(y: CVPixelBufferGetBaseAddressOfPlane(out, 0)!.assumingMemoryBound(to: UInt8.self), ybpr: CVPixelBufferGetBytesPerRowOfPlane(out, 0),
                        c: CVPixelBufferGetBaseAddressOfPlane(out, 1)!.assumingMemoryBound(to: UInt8.self), cbpr: CVPixelBufferGetBytesPerRowOfPlane(out, 1))
        }
        CVPixelBufferUnlockBaseAddress(out, []); CVPixelBufferUnlockBaseAddress(src, .readOnly)
        CVBufferPropagateAttachments(src, out)
        r.finish(withComposedVideoFrame: out)
        Passthrough420Compositor.record { $0.finished += 1 }
    }
}

extension SubtitleApproachBTests {
    /// 4:2:0 평면 → R′G′B′(0–255), 색차 위치 Left로 올림(짝수 열 같은 자리, 홀수 열 이웃 평균, 두 행이 같은 표본)
    static func upChroma(_ c: [UInt8], _ x: Int, _ y: Int, _ plane: Int) -> Double {
        let j = y / 2, k = x / 2, v0 = Double(c[2 * (j * N420Layer.cw + k) + plane])
        if x % 2 == 0 { return v0 }
        let k1 = min(N420Layer.cw - 1, k + 1); return (v0 + Double(c[2 * (j * N420Layer.cw + k1) + plane])) / 2
    }
    static func toRGB(_ Y: Double, _ Cb: Double, _ Cr: Double) -> (Double, Double, Double) {
        let y = (Y - 16) / 219, cb = (Cb - 128) / 224, cr = (Cr - 128) / 224
        let R = y + 1.5748 * cr, B = y + 1.8556 * cb, G = (y - 0.2126 * R - 0.0722 * B) / 0.7152
        return (R * 255, G * 255, B * 255)
    }
    static func rgbAt(_ p: Planes, _ x: Int, _ y: Int) -> (Double, Double, Double) {
        toRGB(Double(p.y[y * N420Layer.w + x]), upChroma(p.c, x, y, 0), upChroma(p.c, x, y, 1))
    }

    func testApproachBNative420Candidate() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, ta, _) = try await plan()
        let root = ExportEndToEndTests.root, dir = root.appendingPathComponent("native420-candidate")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = fixtures.appendingPathComponent("otf-TA.mp4")
        let st = try await AVURLAsset(url: src).loadTracks(withMediaType: .video).first!
        let vc = (try Passthrough420Compositor.composition(from: p.videoComposition, sourceSize: try await st.load(.naturalSize), sourceTransform: try await st.load(.preferredTransform))).mutableCopy() as! AVMutableVideoComposition
        vc.customVideoCompositorClass = N420CandidateCompositor.self
        let rKo = Self.raster(Self.captions.first { $0.name == "ko-left" }!), rYe = Self.raster(Self.captions.first { $0.name == "overlap-yellow" }!)
        let layers = [N420Layer(rKo, start: 10, end: 40), N420Layer(rYe, start: 50, end: 65)]
        N420CandidateCompositor.layers = layers
        for l in layers { note(String(format: "layer %@ [%d, %d): footprint Y %d CbCr %d | interior %d px | intended interior RGB (%.1f, %.1f, %.1f)", l.name, l.start, l.end, l.yIdx.count, l.cIdx.count, l.interior.count, l.intended.0, l.intended.1, l.intended.2)) }
        func fmt(_ f: OSType) -> String { String(format: "%c%c%c%c", (f >> 24) & 255, (f >> 16) & 255, (f >> 8) & 255, f & 255) }
        func logLine(_ tag: String) -> String { Self.logLockedCopy { l in "\(tag): requests \(l.requests) finished \(l.finished) errors \(l.errors.prefix(3)) | source formats \(l.sourceFormats.map(fmt)) | render-context formats \(l.outputFormats.map(fmt)) | movie time ≠ composition \(l.movieTimeMismatch), missing \(l.movieTimeMissing)" } }
        func decode420(_ u: URL, frames: Set<Int>? = nil) async throws -> [Int: Planes] {
            let a = AVURLAsset(url: u); let rd = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
            rd.add(o); rd.startReading()
            var out: [Int: Planes] = [:]
            while let sb = o.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb) { let n = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded()); if frames?.contains(n) ?? true { out[n] = Self.planes(pb) } } }
            return out
        }
        let ref = try await decode420(src)

        // 1. 인코딩 전
        Passthrough420Compositor.resetLog()
        let rd = try AVAssetReader(asset: p.composition)
        let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
        o.videoComposition = vc; rd.add(o); rd.startReading()
        var frames = 0, ptsBad = 0, formats = Set<OSType>(), seen = Set<Int>(), hiddenChanged = 0, outsideChanged = 0, interiorWrong = 0
        var rows: [String] = [], keep: [Int: Planes] = [:]
        var refErr: [String: (yN: Int, yAbs: Double, yMax: Double, cN: Int, cAbs: Double, cMax: Double)] = [:]
        while let sb = o.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb), n = Int((pts.seconds * 30).rounded())
            if CMTimeCompare(pts, CMTime(value: CMTimeValue(n), timescale: 30)) != 0 { ptsBad += 1 }
            frames += 1; seen.insert(n); formats.insert(CVPixelBufferGetPixelFormatType(pb))
            let q = Self.planes(pb); guard let s = ref[n] else { continue }
            let vis = layers.filter { $0.visible(n) }
            var yIn = 0, yOut = 0, cIn = 0, cOut = 0
            for i in 0..<q.y.count where q.y[i] != s.y[i] { if vis.contains(where: { $0.yMask[i] }) { yIn += 1 } else { yOut += 1 } }
            for i in 0..<q.c.count where q.c[i] != s.c[i] { if vis.contains(where: { $0.cMask[i / 2] }) { cIn += 1 } else { cOut += 1 } }
            if vis.isEmpty { hiddenChanged += yIn + yOut + cIn + cOut } else { outsideChanged += yOut + cOut }
            if [9, 10, 39, 40, 49, 50, 64, 65].contains(n) { rows.append("f\(n) (\(vis.map(\.name))): changed Y in/out \(yIn)/\(yOut), CbCr bytes in/out \(cIn)/\(cOut)") }
            for l in vis {
                // 안쪽: 밝기가 반올림한 Y_sub와 정확히 같아야 한다(알파 1)
                for i in l.interior where Double(q.y[i]) != l.aYFull[i].rounded() { interiorWrong += 1 }
                // 참조와의 차이(밝기 화소마다, 색차는 같은 Left 6위치 가중으로 내린 참조와 표본마다)
                var e = refErr[l.name] ?? (0, 0, 0, 0, 0, 0)
                for t in 0..<l.yIdx.count {
                    let i = l.yIdx[t], rY = Double(s.y[i]) * (1 - l.ya[t]) + l.yaSub[t], d = abs(Double(q.y[i]) - rY)
                    e.yN += 1; e.yAbs += d; e.yMax = max(e.yMax, d)
                }
                for c in l.cIdx {
                    let k = c % N420Layer.cw, j = c / N420Layer.cw
                    for plane in 0..<2 {
                        var refC = 0.0
                        for (dx, wx) in [(-1, 0.25), (0, 0.5), (1, 0.25)] { for dy in 0...1 {
                            let x = 2 * k + dx, y = 2 * j + dy, i = y * N420Layer.w + x, a = l.aFull[i]
                            refC += wx * 0.5 * (Self.upChroma(s.c, x, y, plane) * (1 - a) + (plane == 0 ? l.aCbFull[i] : l.aCrFull[i]))
                        } }
                        let d = abs(Double(q.c[2 * c + plane]) - refC); e.cN += 1; e.cAbs += d; e.cMax = max(e.cMax, d)
                    }
                }
                refErr[l.name] = e
            }
            if [10, 50].contains(n) { keep[n] = q }
        }
        XCTAssertEqual(rd.status, .completed, "\(String(describing: rd.error))")
        note("pre-encode (reader 420v): frames \(frames) distinct \(seen.count) range \(seen.min() ?? -1)–\(seen.max() ?? -1) PTS≠n/30 \(ptsBad) formats \(formats.map(fmt)) | hidden-frame changed samples \(hiddenChanged) | visible-frame changed outside footprint \(outsideChanged) | interior luma ≠ round(Y_sub) \(interiorWrong)\n  " + rows.joined(separator: "\n  "))
        note("vs reference (same color assumptions; luma per pixel, chroma vs reference downsampled with the same Left weights), all visible frames:\n  " + refErr.keys.sorted().map { k in let e = refErr[k]!; return String(format: "%@: luma mean|Δ| %.3f max %.3f (%d samples) | chroma mean|Δ| %.3f max %.3f (%d samples)", k, e.yAbs / Double(e.yN), e.yMax, e.yN, e.cAbs / Double(e.cN), e.cMax, e.cN) }.joined(separator: "\n  "))
        note(logLine("compositor during reader"))
        XCTAssertEqual(hiddenChanged, 0); XCTAssertEqual(outsideChanged, 0); XCTAssertEqual(interiorWrong, 0); XCTAssertEqual(frames, 120); XCTAssertEqual(ptsBad, 0)

        // 2. 가장자리 그림(×6): 원본, 후보, 참조(실수 영역 위에 놓기), |후보 − 참조| RGB 최대 ×16, 발자국
        for (l, n) in zip(layers, [10, 50]) {
            guard let q = keep[n], let s = ref[n] else { continue }
            var bx0 = Int.max, by0 = Int.max, by1 = Int.min
            for i in l.yIdx { bx0 = min(bx0, i % N420Layer.w); by0 = min(by0, i / N420Layer.w); by1 = max(by1, i / N420Layer.w) }
            let crop = (x: bx0 - 6, y: by0 - 6, w: 110, h: by1 - by0 + 13), z = 6, W = 110 * z, H = crop.h * z
            let ctx = CGContext(data: nil, width: W, height: H * 5, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
            func u(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
            for yy in 0..<crop.h { for xx in 0..<crop.w {
                let x = crop.x + xx, y = crop.y + yy, i = y * N420Layer.w + x, a = l.aFull[i]
                let sr = Self.rgbAt(s, x, y), qr = Self.rgbAt(q, x, y)
                let rY = Double(s.y[i]) * (1 - a) + l.aYFull[i]
                let rCb = Self.upChroma(s.c, x, y, 0) * (1 - a) + l.aCbFull[i], rCr = Self.upChroma(s.c, x, y, 1) * (1 - a) + l.aCrFull[i]
                let rr = Self.toRGB(rY, rCb, rCr)
                let d = max(abs(qr.0 - rr.0), abs(qr.1 - rr.1), abs(qr.2 - rr.2)) * 16
                let ci = (y / 2) * N420Layer.cw + x / 2
                let cells: [(Double, Double, Double)] = [sr, qr, rr, (d, d, d), (l.yMask[i] ? 255 : 0, l.cMask[ci] ? 160 : 0, 0)]
                for (row, c) in cells.enumerated() { for sy in 0..<z { for sx in 0..<z {
                    let o = (((row * crop.h + yy) * z + sy) * W + xx * z + sx) * 4
                    px[o] = u(c.2); px[o + 1] = u(c.1); px[o + 2] = u(c.0); px[o + 3] = 255
                } } }
            } }
            let url = dir.appendingPathComponent("edge-\(l.name)-f\(n).png")
            let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
        }
        note("edge sheets: native420-candidate/edge-ko-left-f10.png, edge-overlap-yellow-f50.png (rows: source, candidate, reference, |candidate − reference| RGB max ×16, footprint red = Y / green = CbCr)")

        // 3. 내보내기 한 번
        Passthrough420Compositor.resetLog()
        let dest = dir.appendingPathComponent("h264-native420-candidate.mp4")
        try? FileManager.default.removeItem(at: dest)   // 이 테스트가 만든 이전 출력만
        let outcome = await ExportService.export(withVideoComposition(p, vc), to: .fromSavePanel(dest), sources: [ta]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        note(logLine("compositor during export"))
        let v = try await ExportJudge.judge(dest, clips: [.init(file: "otf-TA.mp4", sourceIn: 0, length: p.durationFrames)], durationFrames: p.durationFrames, checkAudio: false)
        note("export: \(try await SubtitleABComparisonTests.describe(dest)) | screen code pass \(v.pass) frames \(v.frames)")
        XCTAssertTrue(v.pass)

        // 4. 안쪽 색: 래스터가 뜻한 색 대 인코딩 전 후보·디코딩 후보·방식 B H.264(같은 래스터, Core Animation)
        let dExp = try await decode420(dest, frames: [15, 57])
        let dB = try await decode420(root.appendingPathComponent("sb-residue/h264-all.mp4"), frames: [15, 42])   // B: ko-left 혼자 15, 노란 자막 혼자 40–44
        var preQ: [Int: Planes] = [:]
        do {
            let r2 = try AVAssetReader(asset: p.composition)
            let o2 = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
            o2.videoComposition = vc; r2.add(o2); r2.startReading()
            while let sb = o2.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb) { let n = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded()); if [15, 57].contains(n) { preQ[n] = Self.planes(pb) } } }
        }
        func interiorMean(_ pl: Planes?, _ l: N420Layer) -> String {
            guard let pl else { return "missing" }
            var s = (0.0, 0.0, 0.0), mx = 0.0
            for i in l.interior { let c = Self.rgbAt(pl, i % N420Layer.w, i / N420Layer.w); s.0 += c.0; s.1 += c.1; s.2 += c.2
                mx = max(mx, abs(c.0 - l.intended.0), abs(c.1 - l.intended.1), abs(c.2 - l.intended.2)) }
            let n = Double(l.interior.count)
            return String(format: "(%.1f, %.1f, %.1f) Δmean (%+.1f, %+.1f, %+.1f) max|Δ| %.1f", s.0 / n, s.1 / n, s.2 / n, s.0 / n - l.intended.0, s.1 / n - l.intended.1, s.2 / n - l.intended.2, mx)
        }
        note("interior RGB (Left upsample, BT.709 video range) vs intended:\n  " + [
            "ko-left intended (\(layers[0].intended)) | pre-encode f15 \(interiorMean(preQ[15], layers[0])) | export f15 \(interiorMean(dExp[15], layers[0])) | approach B export f15 \(interiorMean(dB[15], layers[0]))",
            "overlap-yellow intended (\(layers[1].intended)) | pre-encode f57 \(interiorMean(preQ[57], layers[1])) | export f57 \(interiorMean(dExp[57], layers[1])) | approach B export f42 \(interiorMean(dB[42], layers[1]))",
        ].joined(separator: "\n  "))

        // 5. 보기용 비교: 기준 → 후보 → 기준 → 후보(재인코딩 없음) + 프레임 보존
        let base = root.appendingPathComponent("sb-residue/h264-base.mp4")
        let comp = AVMutableComposition()
        var cursor = CMTime.zero, tracks: [AVMediaType: AVMutableCompositionTrack] = [:]
        for u in [base, dest, base, dest] {
            let a = AVURLAsset(url: u)
            for t in try await a.load(.tracks) where t.mediaType == .video || t.mediaType == .audio {
                let ct = tracks[t.mediaType] ?? comp.addMutableTrack(withMediaType: t.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
                tracks[t.mediaType] = ct
                try ct.insertTimeRange(try await t.load(.timeRange), of: t, at: cursor)
            }
            cursor = cursor + (try await a.load(.duration))
        }
        let cmp = dir.appendingPathComponent("compare-baseline-candidate-baseline-candidate.mov")
        try? FileManager.default.removeItem(at: cmp)
        let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
        try await s.export(to: cmp, as: .mov)
        func frameHashes(_ u: URL) async throws -> [(n: Int, exact: Bool, h: String)] {
            let a = AVURLAsset(url: u); let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            r.add(o); r.startReading()
            var out: [(Int, Bool, String)] = []
            while let sb = o.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb), n = Int((pts.seconds * 30).rounded())
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let bp = CVPixelBufferGetBaseAddress(pb)!, bpr = CVPixelBufferGetBytesPerRow(pb), rb = CVPixelBufferGetWidth(pb) * 4
                var hs = SHA256(); for y in 0..<CVPixelBufferGetHeight(pb) { hs.update(bufferPointer: UnsafeRawBufferPointer(start: bp + y * bpr, count: rb)) }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                out.append((n, CMTimeCompare(pts, CMTime(value: CMTimeValue(n), timescale: 30)) == 0, hs.finalize().description))
            }
            return out.map { (n: $0.0, exact: $0.1, h: $0.2) }
        }
        let hb = Dictionary(uniqueKeysWithValues: try await frameHashes(base).map { ($0.n, $0.h) }), hd = Dictionary(uniqueKeysWithValues: try await frameHashes(dest).map { ($0.n, $0.h) })
        let hc = try await frameHashes(cmp)
        var bad: [String] = []
        if hc.map(\.n).sorted() != Array(0..<480) { bad.append("frame numbers not 0..<480") }
        for f in hc { if !f.exact { bad.append("f\(f.n) PTS") }; if ((f.n / 120) % 2 == 0 ? hb : hd)[f.n % 120] != f.h { bad.append("f\(f.n) pixels") } }
        let sameAsBase = (0..<120).filter { hb[$0] == hd[$0] }
        note("comparison: native420-candidate/\(cmp.lastPathComponent) \(String(format: "%.3f", cursor.seconds)) s | \(try await SubtitleABComparisonTests.describe(cmp)) | frames PTS n/30 and decoded pixels identical to source section: \(bad.isEmpty ? "all 480" : "FAIL \(bad.prefix(8))") | candidate decoded frames identical to baseline: \(sameAsBase.count) \(sameAsBase)")
        XCTAssertTrue(bad.isEmpty)
        N420CandidateCompositor.layers = []
    }

    /// 알파 독립 확인(§37.4): 균일한 비흰색 자막(노랑 255,230,26)을 알파 0·0.25·0.5·1로 비흑색 배경(갈색 120,90,30) 위에 놓는다.
    /// 기대값은 구현과 다른 길로 계산한다: 배경 Y′CbCr(정수) → R′G′B′ 실수, R′G′B′에서 직선(미리 곱하지 않은) 알파 섞기, 다시 Y′CbCr(비디오 범위).
    /// 구현값은 실제 N420Layer.composite()를 1920×1080 평면에 돌려 얻는다(CG가 저장한 미리 곱한 8비트 래스터를 입력으로).
    func testApproachBNative420AlphaProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let fg = (255.0, 230.0, 26.0), bg = (120.0, 90.0, 30.0)
        func ycc(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {   // 0–255 R′G′B′ → 비디오 범위 Y′CbCr(실수)
            let R = r / 255, G = g / 255, B = b / 255, y = 0.2126 * R + 0.7152 * G + 0.0722 * B
            return (16 + 219 * y, 128 + 224 * (B - y) / 1.8556, 128 + 224 * (R - y) / 1.5748)
        }
        let bgY = ycc(bg.0, bg.1, bg.2), bgI = (bgY.0.rounded(), bgY.1.rounded(), bgY.2.rounded())   // 평면에 넣는 정수 배경
        let bgRGB = Self.toRGB(bgI.0, bgI.1, bgI.2)                                                  // 그 정수 배경의 R′G′B′
        var rows: [String] = []
        var worst = 0.0
        for nominal in [0.0, 0.25, 0.5, 1.0] {
            // 8×8 균일 래스터(CG가 미리 곱해 저장), 프레임 (100, 100)
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: fg.0 / 255, green: fg.1 / 255, blue: fg.2 / 255, alpha: nominal)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
            let stored = (b: px[0], g: px[1], r: px[2], a: px[3])
            let cap = Caption(name: "probe", text: "", font: Self.font, size: 10, rgba: (1, 0.9, 0.1, nominal), align: .left, origin: CGPoint(x: 100, y: 100), width: 8, start: 0, end: 1)
            let r = Raster(caption: cap, image: ctx.makeImage()!, rect: CGRect(x: 100, y: 100, width: 8, height: 8), alpha: [UInt8](repeating: stored.a, count: 64), lines: 1, fonts: [])
            let layer = N420Layer(r, start: 0, end: 1)
            var Y = [UInt8](repeating: UInt8(bgI.0), count: N420Layer.w * N420Layer.h), C = [UInt8](repeating: 0, count: N420Layer.cw * N420Layer.ch * 2)
            for i in 0..<(N420Layer.cw * N420Layer.ch) { C[2 * i] = UInt8(bgI.1); C[2 * i + 1] = UInt8(bgI.2) }
            Y.withUnsafeMutableBufferPointer { yp in C.withUnsafeMutableBufferPointer { cp in
                layer.composite(y: yp.baseAddress!, ybpr: N420Layer.w, c: cp.baseAddress!, cbpr: N420Layer.cw * 2)
            } }
            // 가운데 화소 (104, 104)와, 6개 위치(열 101–103 × 행 102–103)가 모두 래스터 안인 색차 표본 (k 51, j 51)
            let gotY = Double(Y[104 * N420Layer.w + 104]), ci = 51 * N420Layer.cw + 51, gotCb = Double(C[2 * ci]), gotCr = Double(C[2 * ci + 1])
            // 독립 기대값: 실제 저장 알파 A8/255, 직선 색은 뜻한 색(fg) — R′G′B′에서 섞고 Y′CbCr로
            let a = Double(stored.a) / 255
            let mix = (a * fg.0 + (1 - a) * bgRGB.0, a * fg.1 + (1 - a) * bgRGB.1, a * fg.2 + (1 - a) * bgRGB.2)
            let exp = ycc(mix.0, mix.1, mix.2)
            // 참고: 알파를 두 번 곱한 경우(잘못)와 오프셋을 빼먹은 경우(잘못)의 값
            let fgY = ycc(fg.0, fg.1, fg.2)
            let doubleAlpha = (bgI.0 * (1 - a) + a * a * fgY.0, bgI.1 * (1 - a) + a * a * fgY.1, bgI.2 * (1 - a) + a * a * fgY.2)
            let noOffset = (bgI.0 * (1 - a) + a * (fgY.0 - 16), bgI.1 * (1 - a) + a * (fgY.1 - 128), bgI.2 * (1 - a) + a * (fgY.2 - 128))
            let d = max(abs(gotY - exp.0), abs(gotCb - exp.1), abs(gotCr - exp.2))
            worst = max(worst, d)
            rows.append(String(format: "alpha nominal %.2f stored A8 %d (a %.4f), stored premultiplied RGB (%d, %d, %d) | implementation Y %.0f Cb %.0f Cr %.0f | independent Y %.3f Cb %.3f Cr %.3f | max|Δ| %.3f | (wrong double-alpha Y %.2f Cb %.2f Cr %.2f; wrong no-offset Y %.2f Cb %.2f Cr %.2f)",
                               nominal, Int(stored.a), a, Int(stored.r), Int(stored.g), Int(stored.b), gotY, gotCb, gotCr, exp.0, exp.1, exp.2, d,
                               doubleAlpha.0, doubleAlpha.1, doubleAlpha.2, noOffset.0, noOffset.1, noOffset.2))
        }
        note(String(format: "background RGB (%.0f, %.0f, %.0f) → integer Y′CbCr (%.0f, %.0f, %.0f) → R′G′B′ (%.3f, %.3f, %.3f); subtitle straight RGB (%.0f, %.0f, %.0f)\n  ", bg.0, bg.1, bg.2, bgI.0, bgI.1, bgI.2, bgRGB.0, bgRGB.1, bgRGB.2, fg.0, fg.1, fg.2) + rows.joined(separator: "\n  "))
        // 허용: 출력 8비트 반올림(0.5) + CG의 미리 곱한 8비트 저장 반올림(채널당 ≤ 0.5/255, Y′CbCr로 최대 약 0.5) — 이를 넘으면 결함
        XCTAssertLessThanOrEqual(worst, 1.0, "alpha/offset handling deviates from the independent RGB straight-alpha blend")
    }

    /// "TA" 자리 국소 관찰 조사(§37.5): 기존 파일만 읽는다(새 내보내기 없음). 원본·기준·후보·P420(자막 없는 4:2:0 복사)의 표시 프레임 0–119.
    /// 작은 "TA" 표식과 큰 "TA" 글자를 원본 프레임 0의 밝은 화소(Y > 150)로 찾고, 글자(+2 화소 둘레)와 같은 크기의 가까운 배경 상자를 잰다.
    func testApproachBNative420TARegion() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let root = ExportEndToEndTests.root
        let files: [(String, URL)] = [("source", fixtures.appendingPathComponent("otf-TA.mp4")), ("baseline", root.appendingPathComponent("sb-residue/h264-base.mp4")),
                                      ("candidate", root.appendingPathComponent("native420-candidate/h264-native420-candidate.mp4")), ("P420-empty", root.appendingPathComponent("path-cause/h264-P420-empty.mp4"))]
        let W = N420Layer.w
        // 1. 영역 찾기(원본 프레임 0)
        func decodeAll(_ u: URL, _ body: (Int, Planes) -> Void) async throws {
            let a = AVURLAsset(url: u); let rd = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
            rd.add(o); rd.startReading()
            while let sb = o.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb), n = Int((pts.seconds * 30).rounded())
                XCTAssertEqual(CMTimeCompare(pts, CMTime(value: CMTimeValue(n), timescale: 30)), 0)
                body(n, Self.planes(pb))
            }
        }
        var src0: Planes?
        try await decodeAll(files[0].1) { n, p in if n == 0 { src0 = p } }
        func bbox(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> (Int, Int, Int, Int) {
            var b = (Int.max, Int.max, Int.min, Int.min)
            for y in y0..<y1 { for x in x0..<x1 where src0!.y[y * W + x] > 150 { b = (min(b.0, x), min(b.1, y), max(b.2, x), max(b.3, y)) } }
            return b
        }
        let small = bbox(990, 100, 1090, 175), large = bbox(1580, 190, 1910, 420)
        struct Region { let name: String; let glyph: [Int]; let bg: [Int] }
        func region(_ name: String, _ b: (Int, Int, Int, Int), bgDY: Int) -> Region {
            var mask = Set<Int>()
            for y in b.1...b.3 { for x in b.0...b.2 where src0!.y[y * W + x] > 150 { mask.insert(y * W + x) } }
            var g = Set<Int>()   // 글자 + 2화소 둘레
            for i in mask { for dy in -2...2 { for dx in -2...2 { g.insert(i + dy * W + dx) } } }
            let glyph = g.sorted()
            let bg = glyph.map { $0 + bgDY * W }   // 같은 모양을 세로로 옮긴 가까운 배경
            return Region(name: name, glyph: glyph, bg: bg)
        }
        let regions = [region("small TA label", small, bgDY: small.3 - small.1 + 8), region("large TA", large, bgDY: -(large.3 - large.1 + 0) / 2 - 0)]
        // 큰 TA의 배경은 글자 왼쪽 같은 높이로 옮긴다(위·아래는 다른 무늬가 있음)
        let largeBG = regions[1].glyph.map { $0 - (large.2 - large.0 + 20) }
        let regs = [regions[0], Region(name: "large TA", glyph: regions[1].glyph, bg: largeBG)]
        note("small TA bbox (Y>150, source f0) x \(small.0)–\(small.2) y \(small.1)–\(small.3) | large TA bbox x \(large.0)–\(large.2) y \(large.1)–\(large.3)")
        for r in regs { note("\(r.name): glyph+2px \(r.glyph.count) px, background box shifted (min x \(r.bg.map { $0 % W }.min()!) y \(r.bg.map { $0 / W }.min()!)–\(r.bg.map { $0 / W }.max()!)), bright px in background \(r.bg.filter { src0!.y[$0] > 150 }.count)") }
        // 자막 발자국과 겹치는가
        let layers = [N420Layer(Self.raster(Self.captions.first { $0.name == "ko-left" }!), start: 10, end: 40), N420Layer(Self.raster(Self.captions.first { $0.name == "overlap-yellow" }!), start: 50, end: 65)]
        for r in regs { note("\(r.name): intersects subtitle luma footprint \(layers.map { l in r.glyph.filter { l.yMask[$0] }.count + r.bg.filter { l.yMask[$0] }.count })") }

        // 2. 영역의 Y를 프레임마다 모은다
        var data: [String: [Int: [[UInt8]]]] = [:]   // file → frame → [region*2 arrays]
        for (name, u) in files {
            var d: [Int: [[UInt8]]] = [:]
            try await decodeAll(u) { n, p in d[n] = regs.flatMap { r in [r.glyph.map { p.y[$0] }, r.bg.map { p.y[$0] }] } }
            data[name] = d
            XCTAssertEqual(d.count, 120, name)
        }
        func mad(_ a: [UInt8], _ b: [UInt8]) -> Double { Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count) }
        let segs: [(String, ClosedRange<Int>)] = [("0–9", 0...9), ("10–39 ko-left", 10...39), ("40–49", 40...49), ("50–64 yellow", 50...64), ("65–119", 65...119)]
        var rows: [String] = []
        for (ri, r) in regs.enumerated() { for (part, k) in [("glyph", 2 * ri), ("background", 2 * ri + 1)] {
            func seg(_ f: (Int) -> Double, _ range: ClosedRange<Int>) -> Double { let v = range.map(f); return v.reduce(0, +) / Double(v.count) }
            let S = data["source"]!, B = data["baseline"]!, C = data["candidate"]!, P = data["P420-empty"]!
            // 원본 변화, 오차(대 원본), 오차 흔들림, 후보 − 기준
            func srcMotion(_ n: Int) -> Double { n == 0 ? 0 : mad(S[n]![k], S[n - 1]![k]) }
            func err(_ X: [Int: [[UInt8]]], _ n: Int) -> Double { mad(X[n]![k], S[n]![k]) }
            func flick(_ X: [Int: [[UInt8]]], _ n: Int) -> Double {
                guard n > 0 else { return 0 }
                let e1 = zip(X[n]![k], S[n]![k]).map { Int($0) - Int($1) }, e0 = zip(X[n - 1]![k], S[n - 1]![k]).map { Int($0) - Int($1) }
                return Double(zip(e1, e0).reduce(0) { $0 + abs($1.0 - $1.1) }) / Double(e1.count)
            }
            let cells = segs.map { name, rg in String(format: "%@: src motion %.3f | |e| base %.2f cand %.2f P420 %.2f | e-flicker base %.2f cand %.2f | |cand−base| %.2f",
                                                    name, seg(srcMotion, rg), seg({ err(B, $0) }, rg), seg({ err(C, $0) }, rg), seg({ err(P, $0) }, rg),
                                                    seg({ flick(B, $0) }, rg), seg({ flick(C, $0) }, rg), seg({ mad(C[$0]![k], B[$0]![k]) }, rg)) }
            rows.append("\(r.name) \(part):\n    " + cells.joined(separator: "\n    "))
            let pIdent = (0..<120).filter { P[$0]![k] == B[$0]![k] }.count
            let cIdent = (0..<120).filter { C[$0]![k] == B[$0]![k] }.count
            rows.append("    frames where region Y identical to baseline: P420-empty \(pIdent)/120, candidate \(cIdent)/120")
        } }
        note("luma (8-bit codes, mean over region pixels; e = file − source decode; e-flicker = mean |e(n) − e(n−1)|):\n  " + rows.joined(separator: "\n  "))
        // 보이는 화면의 프레임 간 변화 |X(n) − X(n−1)|(작은 TA 글자): 원본·기준·후보, 0.5를 넘는 프레임과 구간 평균
        do {
            let S = data["source"]!, B = data["baseline"]!, C = data["candidate"]!
            func ch(_ X: [Int: [[UInt8]]], _ n: Int) -> Double { mad(X[n]![0], X[n - 1]![0]) }
            var big: [String] = []
            for n in 1..<120 {
                let a = ch(S, n), b = ch(B, n), c = ch(C, n)
                if max(a, b, c) > 0.5 { big.append(String(format: "f%d src %.2f base %.2f cand %.2f", n, a, b, c)) }
            }
            let segAvg = segs.map { name, rg in
                let r = rg.filter { $0 > 0 }
                func avg(_ X: [Int: [[UInt8]]]) -> Double { r.map { ch(X, $0) }.reduce(0, +) / Double(r.count) }
                return String(format: "%@: src %.3f base %.3f cand %.3f", name, avg(S), avg(B), avg(C))
            }
            note("small TA glyph, displayed frame-to-frame change mean|X(n) − X(n−1)|:\n  segments: " + segAvg.joined(separator: " | ") + "\n  frames with any > 0.5: " + big.joined(separator: "; "))
        }

        // 3. 그림: 작은 TA 둘레(×6), 프레임 20·30·37·57, 줄 = 원본·기준·후보·|후보 − 기준|×8
        let dir = root.appendingPathComponent("native420-candidate")
        let cx0 = small.0 - 12, cy0 = small.1 - 10, cw = small.2 - small.0 + 25, chh = small.3 - small.1 + 21, z = 6
        let framesShown = [20, 30, 37, 57]
        var full: [String: [Int: Planes]] = [:]
        for (name, u) in files.prefix(3) { var d: [Int: Planes] = [:]; try await decodeAll(u) { n, p in if framesShown.contains(n) { d[n] = p } }; full[name] = d }
        let Wd = cw * z * framesShown.count + 8 * (framesShown.count - 1), Hd = chh * z * 4 + 8 * 3
        let ctx = CGContext(data: nil, width: Wd, height: Hd, bitsPerComponent: 8, bytesPerRow: Wd * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func u8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        for (col, n) in framesShown.enumerated() {
            guard let s = full["source"]?[n], let b = full["baseline"]?[n], let c = full["candidate"]?[n] else { continue }
            for yy in 0..<chh { for xx in 0..<cw {
                let x = cx0 + xx, y = cy0 + yy
                let d = Double(abs(Int(c.y[y * W + x]) - Int(b.y[y * W + x])) * 8)
                let cells = [Self.rgbAt(s, x, y), Self.rgbAt(b, x, y), Self.rgbAt(c, x, y), (d, d, d)]
                for (row, v) in cells.enumerated() { for sy in 0..<z { for sx in 0..<z {
                    let X = col * (cw * z + 8) + xx * z + sx, Y = row * (chh * z + 8) + yy * z + sy, o = (Y * Wd + X) * 4
                    px[o] = u8(v.2); px[o + 1] = u8(v.1); px[o + 2] = u8(v.0); px[o + 3] = 255
                } } }
            } }
        }
        let url = dir.appendingPathComponent("ta-small-frames-20-30-37-57.png")
        let dd = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dd, ctx.makeImage()!, nil); CGImageDestinationFinalize(dd)
        note("sheet: native420-candidate/ta-small-frames-20-30-37-57.png (columns frames 20, 30, 37, 57; rows source, baseline, candidate, |candidate − baseline| luma ×8)")
    }
}
