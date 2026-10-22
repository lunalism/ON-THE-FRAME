import AVFoundation
import CryptoKit
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 4:2:0 위에 자막 하나를 발자국 안에서만 합성(2026-10-22, docs/SUBTITLE-DESIGN.md §36, 시험 전용 가능성 실험 — 구조 채택 아님). 선택 실행(OTF_SB=1).
/// 영상 표본은 RGB로 바꾸지 않는다. 자막 색만 BT.709·비디오 범위 Y′CbCr로 바꿔 위에 놓기(out = src + a(sub − src))로 섞는다.
/// 색차는 위치 Left(가로 2k와 같은 자리, 세로 두 행 사이)에 맞춰 열 2k−1, 2k, 2k+1(1/4, 1/2, 1/4) × 행 2j, 2j+1(1/2씩)의 알파 가중으로 섞는다.
/// 선언 발자국: Y = a > 0 화소, CbCr = 위 6개 위치 중 a > 0이 있는 표본. 그 밖은 원본 그대로여야 한다.
struct Native420Subtitle: @unchecked Sendable {
    let start: Int, end: Int
    let yIdx: [Int], ya: [Double], ySub: [Double]             // 밝기 발자국(프레임 화소 번호)
    let cIdx: [Int], cWA: [Double], cWACb: [Double], cWACr: [Double]   // 색차 발자국(색차 표본 번호), Σw·a, Σw·a·Cb_sub, Σw·a·Cr_sub
    let yMask: [Bool], cMask: [Bool]
    static let w = 1920, h = 1080, cw = 960, ch = 540

    init(_ r: SubtitleApproachBTests.Raster) {
        start = r.caption.start; end = r.caption.end
        let img = r.image, rw = img.width, rh = img.height, bpr = img.bytesPerRow
        let data = img.dataProvider!.data! as Data
        let x0 = Int(r.rect.minX), y0 = Int(r.rect.minY)
        precondition(Double(x0) == r.rect.minX && Double(y0) == r.rect.minY && x0 >= 1 && y0 >= 0 && x0 + rw + 1 <= Self.w && y0 + rh <= Self.h, "integer rect inside frame")
        // 프레임 좌표의 a·Y·Cb·Cr(자막 사각형 밖은 a = 0)
        var A = [Double](repeating: 0, count: Self.w * Self.h), Ys = A, Cbs = A, Crs = A
        var yIdx: [Int] = [], ya: [Double] = [], ySub: [Double] = []
        var yMask = [Bool](repeating: false, count: Self.w * Self.h)
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<rh { for x in 0..<rw {
                let o = y * bpr + x * 4   // 메모리 B, G, R, A(미리 곱함, premultipliedFirst + byteOrder32Little)
                let a8 = Double(p[o + 3]); guard a8 > 0 else { continue }
                let a = a8 / 255
                let R = Double(p[o + 2]) / a8, G = Double(p[o + 1]) / a8, B = Double(p[o]) / a8   // 0–1, 감마 값 그대로(색 관리 없음)
                let yy = 0.2126 * R + 0.7152 * G + 0.0722 * B
                let i = (y0 + y) * Self.w + (x0 + x)
                A[i] = a; Ys[i] = 16 + 219 * yy; Cbs[i] = 128 + 224 * (B - yy) / 1.8556; Crs[i] = 128 + 224 * (R - yy) / 1.5748
                yIdx.append(i); ya.append(a); ySub.append(Ys[i]); yMask[i] = true
            } }
        }
        var cIdx: [Int] = [], cWA: [Double] = [], cWACb: [Double] = [], cWACr: [Double] = []
        var cMask = [Bool](repeating: false, count: Self.cw * Self.ch)
        for j in max(0, y0 / 2 - 1)...min(Self.ch - 1, (y0 + rh) / 2 + 1) { for k in max(0, x0 / 2 - 1)...min(Self.cw - 1, (x0 + rw) / 2 + 1) {
            var swa = 0.0, scb = 0.0, scr = 0.0, any = false
            for (dx, wx) in [(-1, 0.25), (0, 0.5), (1, 0.25)] { for dy in 0...1 {
                let x = 2 * k + dx, y = 2 * j + dy
                guard x >= 0, x < Self.w, y < Self.h else { continue }
                let i = y * Self.w + x, a = A[i]; guard a > 0 else { continue }
                any = true; let wa = wx * 0.5 * a
                swa += wa; scb += wa * Cbs[i]; scr += wa * Crs[i]
            } }
            if any { let c = j * Self.cw + k; cIdx.append(c); cWA.append(swa); cWACb.append(scb); cWACr.append(scr); cMask[c] = true }
        } }
        self.yIdx = yIdx; self.ya = ya; self.ySub = ySub; self.cIdx = cIdx; self.cWA = cWA; self.cWACb = cWACb; self.cWACr = cWACr
        self.yMask = yMask; self.cMask = cMask
    }
    func visible(_ n: Int) -> Bool { n >= start && n < end }
    /// 출력 평면(이미 원본을 복사한 것)에 발자국 안만 쓴다. 색차는 CbCr 섞임(표본 c → 바이트 2c, 2c+1).
    func composite(y: UnsafeMutablePointer<UInt8>, ybpr: Int, c: UnsafeMutablePointer<UInt8>, cbpr: Int) {
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        for t in 0..<yIdx.count {
            let i = yIdx[t], p = y + (i / Self.w) * ybpr + (i % Self.w)
            let s = Double(p.pointee); p.pointee = clamp(s + ya[t] * (ySub[t] - s))
        }
        for t in 0..<cIdx.count {
            let k = cIdx[t] % Self.cw, j = cIdx[t] / Self.cw, p = c + j * cbpr + 2 * k
            let cb = Double(p[0]), cr = Double(p[1])
            p[0] = clamp(cb * (1 - cWA[t]) + cWACb[t]); p[1] = clamp(cr * (1 - cWA[t]) + cWACr[t])
        }
    }
}

final class Native420SubtitleCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    nonisolated(unsafe) static var subtitle: Native420Subtitle?
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: [Passthrough420Compositor.format]] }
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]
    private let lock = NSLock()
    private var context: AVVideoCompositionRenderContext?
    private let queue = DispatchQueue(label: "dev.ontheframe.native420subtitle")
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { lock.lock(); context = newRenderContext; lock.unlock() }
    func cancelAllPendingVideoCompositionRequests() {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        Passthrough420Compositor.record { $0.requests += 1 }
        let box = Passthrough420Compositor.RequestBox(r: request)
        queue.async { [self] in process(box.r) }
    }
    private func fail(_ r: AVAsynchronousVideoCompositionRequest, _ msg: String) {
        Passthrough420Compositor.record { $0.errors.append(msg) }
        r.finish(with: NSError(domain: "Native420Subtitle", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]))
    }
    private func process(_ r: AVAsynchronousVideoCompositionRequest) {
        guard let ins = r.videoCompositionInstruction as? Passthrough420Instruction, let sub = Self.subtitle else { fail(r, "unexpected instruction or no subtitle"); return }
        guard let src = r.sourceFrame(byTrackID: ins.trackID) else { fail(r, "no source frame"); return }
        let sf = CVPixelBufferGetPixelFormatType(src)
        Passthrough420Compositor.record { $0.sourceFormats.insert(sf) }
        guard sf == Passthrough420Compositor.format else { fail(r, "source format \(sf) is not 420v"); return }
        lock.lock(); let ctx = context; lock.unlock()
        guard let ctx, let out = ctx.newPixelBuffer() else { fail(r, "no render context buffer"); return }
        let of = CVPixelBufferGetPixelFormatType(out)
        Passthrough420Compositor.record { $0.outputFormats.insert(of) }
        guard of == Passthrough420Compositor.format, CVPixelBufferGetWidth(src) == Native420Subtitle.w, CVPixelBufferGetHeight(src) == Native420Subtitle.h,
              CVPixelBufferGetWidth(out) == Native420Subtitle.w, CVPixelBufferGetHeight(out) == Native420Subtitle.h else { fail(r, "format/size mismatch"); return }
        if let mt = ExperimentalCompositor.movieTime(src), CMTimeCompare(mt, r.compositionTime) != 0 { Passthrough420Compositor.record { $0.movieTimeMismatch += 1 } }
        else if ExperimentalCompositor.movieTime(src) == nil { Passthrough420Compositor.record { $0.movieTimeMissing += 1 } }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(out, [])
        for plane in 0..<2 {
            let sb = CVPixelBufferGetBaseAddressOfPlane(src, plane)!, ob = CVPixelBufferGetBaseAddressOfPlane(out, plane)!
            let sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, plane), obpr = CVPixelBufferGetBytesPerRowOfPlane(out, plane)
            let rows = CVPixelBufferGetHeightOfPlane(src, plane), bytes = CVPixelBufferGetWidthOfPlane(src, plane) * (plane == 0 ? 1 : 2)
            for y in 0..<rows { memcpy(ob + y * obpr, sb + y * sbpr, bytes) }
        }
        let n = Int((r.compositionTime.seconds * 30).rounded())
        if sub.visible(n) {
            sub.composite(y: CVPixelBufferGetBaseAddressOfPlane(out, 0)!.assumingMemoryBound(to: UInt8.self), ybpr: CVPixelBufferGetBytesPerRowOfPlane(out, 0),
                          c: CVPixelBufferGetBaseAddressOfPlane(out, 1)!.assumingMemoryBound(to: UInt8.self), cbpr: CVPixelBufferGetBytesPerRowOfPlane(out, 1))
        }
        CVPixelBufferUnlockBaseAddress(out, []); CVPixelBufferUnlockBaseAddress(src, .readOnly)
        CVBufferPropagateAttachments(src, out)
        r.finish(withComposedVideoFrame: out)
        Passthrough420Compositor.record { $0.finished += 1 }
    }
}

extension SubtitleApproachBTests {
    func testApproachBNative420SubtitleComposite() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, ta, _) = try await plan()
        let src = fixtures.appendingPathComponent("otf-TA.mp4")
        let st = try await AVURLAsset(url: src).loadTracks(withMediaType: .video).first!
        let base = try Passthrough420Compositor.composition(from: p.videoComposition, sourceSize: try await st.load(.naturalSize), sourceTransform: try await st.load(.preferredTransform))
        let vc = base.mutableCopy() as! AVMutableVideoComposition
        vc.customVideoCompositorClass = Native420SubtitleCompositor.self
        let r = Self.raster(Self.captions.first { $0.name == "overlap-yellow" }!)
        let sub = Native420Subtitle(r)
        Native420SubtitleCompositor.subtitle = sub
        note("subtitle \(r.caption.name) rect \(r.rect) interval [\(sub.start), \(sub.end)) | footprint: Y \(sub.yIdx.count) samples, CbCr \(sub.cIdx.count) samples (of \(Native420Subtitle.w * Native420Subtitle.h) / \(Native420Subtitle.cw * Native420Subtitle.ch))")
        func fmt(_ f: OSType) -> String { String(format: "%c%c%c%c", (f >> 24) & 255, (f >> 16) & 255, (f >> 8) & 255, f & 255) }
        func logLine(_ tag: String) -> String {
            Self.logLockedCopy { l in "\(tag): requests \(l.requests) finished \(l.finished) errors \(l.errors.prefix(3)) | source formats \(l.sourceFormats.map(fmt)) | render-context formats \(l.outputFormats.map(fmt)) | source movie time ≠ composition time \(l.movieTimeMismatch), missing \(l.movieTimeMissing)" }
        }
        // 원본 디코딩 평면
        var ref: [Int: Planes] = [:]
        do {
            let a = AVURLAsset(url: src); let rd = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
            rd.add(o); rd.startReading()
            while let sb = o.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb) { ref[Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded())] = Self.planes(pb) } }
        }

        // 1–4. 인코딩 전(리더 420v)
        Passthrough420Compositor.resetLog()
        let rd = try AVAssetReader(asset: p.composition)
        let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
        o.videoComposition = vc; rd.add(o); rd.startReading()
        var frames = 0, ptsBad = 0, formats = Set<OSType>(), seen = Set<Int>()
        var hiddenChanged = 0, outsideChanged = 0, perFrame: [String] = [], keep: [Int: Planes] = [:]
        var centroid: [String] = []
        while let sb = o.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb), n = Int((pts.seconds * 30).rounded())
            if CMTimeCompare(pts, CMTime(value: CMTimeValue(n), timescale: 30)) != 0 { ptsBad += 1 }
            frames += 1; seen.insert(n); formats.insert(CVPixelBufferGetPixelFormatType(pb))
            let q = Self.planes(pb); guard let s = ref[n] else { continue }
            var yIn = 0, yOut = 0, cIn = 0, cOut = 0
            for i in 0..<q.y.count where q.y[i] != s.y[i] { if sub.yMask[i] { yIn += 1 } else { yOut += 1 } }
            for i in 0..<q.c.count where q.c[i] != s.c[i] { if sub.cMask[i / 2] { cIn += 1 } else { cOut += 1 } }
            if sub.visible(n) { outsideChanged += yOut + cOut } else { hiddenChanged += yIn + yOut + cIn + cOut }
            if [29, 30, 31, 37, 43, 44, 45].contains(n) { perFrame.append("f\(n) (\(sub.visible(n) ? "visible" : "hidden")): changed Y in/out footprint \(yIn)/\(yOut), CbCr bytes in/out \(cIn)/\(cOut)") }
            if [29, 30, 44, 45].contains(n) { keep[n] = q }
            if n == 37 {
                // 무게중심(밝기 화소 좌표): 알파, 밝기 변화, 색차 변화(색차 위치 Left: x = 2k, y = 2j + 0.5)
                var ax = 0.0, ay = 0.0, aw = 0.0
                for t in 0..<sub.yIdx.count { let i = sub.yIdx[t]; ax += sub.ya[t] * Double(i % Native420Subtitle.w); ay += sub.ya[t] * Double(i / Native420Subtitle.w); aw += sub.ya[t] }
                var lx = 0.0, ly = 0.0, lw = 0.0
                for i in sub.yIdx { let d = abs(Double(q.y[i]) - Double(s.y[i])); lx += d * Double(i % Native420Subtitle.w); ly += d * Double(i / Native420Subtitle.w); lw += d }
                var cx = 0.0, cy = 0.0, cwt = 0.0
                for c in sub.cIdx { let d = abs(Double(q.c[2 * c]) - Double(s.c[2 * c])) + abs(Double(q.c[2 * c + 1]) - Double(s.c[2 * c + 1]))
                    cx += d * Double(2 * (c % Native420Subtitle.cw)); cy += d * (Double(2 * (c / Native420Subtitle.cw)) + 0.5); cwt += d }
                centroid.append(String(format: "f37 centroid (luma px): alpha (%.3f, %.3f) | |ΔY| (%.3f, %.3f) | |ΔC| at Left siting (%.3f, %.3f) → chroma − alpha (%+.3f, %+.3f)",
                                       ax / aw, ay / aw, lx / lw, ly / lw, cx / cwt, cy / cwt, cx / cwt - ax / aw, cy / cwt - ay / aw))
            }
        }
        XCTAssertEqual(rd.status, .completed, "\(String(describing: rd.error))")
        note("pre-encode (reader 420v): frames \(frames) distinct \(seen.count) range \(seen.min() ?? -1)–\(seen.max() ?? -1) PTS≠n/30 \(ptsBad) formats \(formats.map(fmt)) | hidden frames: changed samples \(hiddenChanged) | visible frames: changed outside footprint \(outsideChanged)\n  " + perFrame.joined(separator: "\n  ") + "\n  " + centroid.joined(separator: "\n  "))
        note(logLine("compositor during reader"))
        XCTAssertEqual(hiddenChanged, 0); XCTAssertEqual(outsideChanged, 0); XCTAssertEqual(frames, 120); XCTAssertEqual(ptsBad, 0)

        // 그림: 글자 가장자리 ×6(원본, 합성, |ΔY|×4, |ΔC|×4, 발자국), 표시용 RGB는 709 비디오 범위·색차 최근접(그림 전용)
        let dir = ExportEndToEndTests.root.appendingPathComponent("path-cause")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bx0 = Int.max, by0 = Int.max, by1 = Int.min
        for i in sub.yIdx { bx0 = min(bx0, i % Native420Subtitle.w); by0 = min(by0, i / Native420Subtitle.w); by1 = max(by1, i / Native420Subtitle.w) }
        let crop = (x: bx0 - 6, y: by0 - 6, w: 110, h: by1 - by0 + 13), z = 6
        func rgb(_ pl: Planes, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let Y = (Double(pl.y[y * Native420Subtitle.w + x]) - 16) / 219, ci = (y / 2) * Native420Subtitle.cw + x / 2
            let cb = (Double(pl.c[2 * ci]) - 128) / 224, cr = (Double(pl.c[2 * ci + 1]) - 128) / 224
            let R = Y + 1.5748 * cr, B = Y + 1.8556 * cb, G = (Y - 0.2126 * R - 0.0722 * B) / 0.7152
            func u(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            return (u(R), u(G), u(B))
        }
        for n in [30, 44] {
            guard let q = keep[n], let s = ref[n] else { continue }
            let W = crop.w * z, H = crop.h * z, rowsN = 5
            let ctx = CGContext(data: nil, width: W, height: H * rowsN, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
            for yy in 0..<crop.h { for xx in 0..<crop.w {
                let x = crop.x + xx, y = crop.y + yy, i = y * Native420Subtitle.w + x, ci = (y / 2) * Native420Subtitle.cw + x / 2
                let dY = UInt8(min(255, abs(Int(q.y[i]) - Int(s.y[i])) * 4))
                let dC = UInt8(min(255, (abs(Int(q.c[2 * ci]) - Int(s.c[2 * ci])) + abs(Int(q.c[2 * ci + 1]) - Int(s.c[2 * ci + 1]))) * 4))
                let fp: (UInt8, UInt8, UInt8) = (sub.yMask[i] ? 255 : 0, sub.cMask[ci] ? 160 : 0, 0)
                let cells = [rgb(s, x, y), rgb(q, x, y), (dY, dY, dY), (dC, dC, dC), fp]
                for (row, c) in cells.enumerated() { for sy in 0..<z { for sx in 0..<z {
                    let o = (((row * crop.h + yy) * z + sy) * W + xx * z + sx) * 4
                    px[o] = c.2; px[o + 1] = c.1; px[o + 2] = c.0; px[o + 3] = 255
                } } }
            } }
            let url = dir.appendingPathComponent("native420-sub-f\(n)-edge.png")
            let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
        }
        note("edge sheets: path-cause/native420-sub-f30-edge.png, -f44-edge.png (crop x \(crop.x)…\(crop.x + crop.w - 1), y \(crop.y)…\(crop.y + crop.h - 1), ×\(z); rows: source, composite, |ΔY|×4, |ΔCb|+|ΔCr|×4, footprint (red = Y, green = CbCr))")

        // 5. 내보내기 한 번(제품 설정 그대로)
        Passthrough420Compositor.resetLog()
        let dest = dir.appendingPathComponent("h264-native420-sub.mp4")
        try? FileManager.default.removeItem(at: dest)   // 이 테스트가 만든 이전 출력만
        let outcome = await ExportService.export(withVideoComposition(p, vc), to: .fromSavePanel(dest), sources: [ta]) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        note(logLine("compositor during export"))
        let v = try await ExportJudge.judge(dest, clips: [.init(file: "otf-TA.mp4", sourceIn: 0, length: p.durationFrames)], durationFrames: p.durationFrames, checkAudio: false)
        note("export: \(try await SubtitleABComparisonTests.describe(dest)) | screen code pass \(v.pass) frames \(v.frames)")
        // 압축 표본: 기준(sb-residue/h264-base.mp4)과 같은 프레임
        func sampleHashes(_ u: URL) async throws -> [Int: String] {
            let a = AVURLAsset(url: u); let rr = try AVAssetReader(asset: a)
            let tr = try await a.loadTracks(withMediaType: .video).first!
            // 압축 표본의 PTS는 미디어 시각이다. 편집 목록(미디어 40/600 → 트랙 0)만큼 빼서 표시 프레임 번호로 바꾼다(§36.4)
            let mediaStart = try await tr.load(.segments).first?.timeMapping.source.start ?? .zero
            let oo = AVAssetReaderTrackOutput(track: tr, outputSettings: nil); rr.add(oo); rr.startReading()
            var out: [Int: String] = [:]
            while let sb = oo.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sb) > 0, let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
                let len = CMBlockBufferGetDataLength(bb); var d = Data(count: len)
                _ = d.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                out[Int(((CMSampleBufferGetPresentationTimeStamp(sb) - mediaStart).seconds * 30).rounded())] = SHA256.hash(data: d).description
            }
            return out
        }
        let hb = try await sampleHashes(ExportEndToEndTests.root.appendingPathComponent("sb-residue/h264-base.mp4")), hs = try await sampleHashes(dest)
        let same = (0..<120).filter { hb[$0] != nil && hb[$0] == hs[$0] }
        let differ = (0..<120).filter { !same.contains($0) }
        func ranges(_ xs: [Int]) -> String {
            var out: [String] = [], i = 0
            while i < xs.count { var j = i; while j + 1 < xs.count && xs[j + 1] == xs[j] + 1 { j += 1 }; out.append(i == j ? "\(xs[i])" : "\(xs[i])–\(xs[j])"); i = j + 1 }
            return out.joined(separator: ", ")
        }
        note("compressed samples identical to baseline export: \(same.count)/120 [\(ranges(same))] | differing \(differ.count) [\(ranges(differ))]")
        // 기준 내보내기 디코딩(같은 인코딩 경로의 자막 없는 짝)
        var basePl: [Int: Planes] = [:]
        do {
            let ba = AVURLAsset(url: ExportEndToEndTests.root.appendingPathComponent("sb-residue/h264-base.mp4")); let br = try AVAssetReader(asset: ba)
            let bo = AVAssetReaderTrackOutput(track: try await ba.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
            br.add(bo); br.startReading()
            while let sb = bo.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb) { let n = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded()); if [10, 28, 29, 30, 37, 44, 45, 46, 60, 90].contains(n) { basePl[n] = Self.planes(pb) } } }
        }
        // 디코딩: 원본 대비 발자국 밖 차이(인코딩이 바꿀 수 있음)와 보이는 프레임의 글자(기존 A1 정의: |ΔY| > 40 대 알파 ≥ 128)
        let a = AVURLAsset(url: dest); let dr = try AVAssetReader(asset: a)
        let dout = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format])
        dr.add(dout); dr.startReading()
        var dec: [String] = []
        let rw = Int(r.rect.width), rx = Int(r.rect.minX), ry = Int(r.rect.minY)
        while let sb = dout.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let n = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 30).rounded())
            guard [10, 28, 29, 30, 37, 44, 45, 46, 60, 90].contains(n), let s = ref[n] else { continue }
            let q = Self.planes(pb)
            var yOut = 0, cOut = 0, yOutB = 0, cOutB = 0
            for i in 0..<q.y.count where q.y[i] != s.y[i] && !sub.yMask[i] { yOut += 1 }
            for i in 0..<q.c.count where q.c[i] != s.c[i] && !sub.cMask[i / 2] { cOut += 1 }
            if let b = basePl[n] {
                for i in 0..<q.y.count where q.y[i] != b.y[i] && !sub.yMask[i] { yOutB += 1 }
                for i in 0..<q.c.count where q.c[i] != b.c[i] && !sub.cMask[i / 2] { cOutB += 1 }
            }
            var inter = 0, uni = 0
            for i in 0..<(rw * Int(r.rect.height)) {
                let fi = (ry + i / rw) * Native420Subtitle.w + rx + i % rw
                let e = r.alpha[i] >= 128, g = abs(Int(q.y[fi]) - Int(s.y[fi])) > 40
                if e || g { uni += 1 }; if e && g { inter += 1 }
            }
            dec.append(String(format: "f%d (%@): outside footprint differing vs source Y %d CbCr bytes %d | vs baseline export Y %d CbCr bytes %d | glyph IoU(|ΔY|>40 vs alpha≥128, vs source) %.3f", n, sub.visible(n) ? "visible" : "hidden", yOut, cOut, yOutB, cOutB, Double(inter) / Double(max(1, uni))))
        }
        note("decoded export vs source decode (encoding may change samples anywhere):\n  " + dec.sorted().joined(separator: "\n  "))
        Native420SubtitleCompositor.subtitle = nil
    }
}
