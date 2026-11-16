import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import VideoToolbox
import XCTest

/// 내보내기 경로 원인 가르기(2026-10-22, docs/SUBTITLE-DESIGN.md §34, 실험 — 채택 아님). 선택 실행(OTF_SB=1). 새 내보내기 없음.
/// 인코딩 전 화소를 원본 고유 4:2:0 평면(420v)으로 읽어 원본 디코딩 평면과 비교한다:
/// P1 기본 합성기, P2a A 합성기(리더가 4:2:0으로 바꿈), P2b A 합성기 BGRA → VTPixelTransferSession, P3 원본 BGRA → 같은 변환(합성기 없음).
/// 참고로 디코딩한 내보내기 셋(기준, A-empty, B-empty)도 같은 평면 지표로 잰다. 인코더 구성(avcC, 표본 구조)도 비교한다.
extension SubtitleApproachBTests {
    struct Planes { var y: [UInt8]; var c: [UInt8] }   // y 1920×1080, c = CbCr 섞임 960×540×2
    static let w = 1920, h = 1080, cw = 960, ch = 540
    static func planes(_ pb: CVPixelBuffer) -> Planes {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var y = [UInt8](repeating: 0, count: w * h), c = [UInt8](repeating: 0, count: cw * ch * 2)
        let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        y.withUnsafeMutableBufferPointer { p in for r in 0..<h { memcpy(p.baseAddress! + r * w, yb + r * ybpr, w) } }
        c.withUnsafeMutableBufferPointer { p in for r in 0..<ch { memcpy(p.baseAddress! + r * cw * 2, cb + r * cbpr, cw * 2) } }
        return Planes(y: y, c: c)
    }
    static func attachmentsSummary(_ pb: CVPixelBuffer) -> String {
        let f = CVPixelBufferGetPixelFormatType(pb)
        let fs = String(format: "%c%c%c%c", (f >> 24) & 255, (f >> 16) & 255, (f >> 8) & 255, f & 255)
        let keys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey, kCVImageBufferChromaLocationTopFieldKey]
        return "\(fs) " + keys.map { k in "\((k as String).replacingOccurrences(of: "CVImageBuffer", with: "").replacingOccurrences(of: "Key", with: ""))=\(CVBufferCopyAttachment(pb, k, nil).map { "\($0)" } ?? "none")" }.joined(separator: " ")
    }

    func testApproachBExportPathCause() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let (p, _, _) = try await plan()
        let root = ExportEndToEndTests.root
        let src = fixtures.appendingPathComponent("otf-TA.mp4")
        var exports = [("export baseline", root.appendingPathComponent("sb-residue/h264-base.mp4")),
                       ("export A-empty", root.appendingPathComponent("owner-quality/h264-A-empty.mp4")),
                       ("export B-empty", root.appendingPathComponent("sb-residue/h264-empty-tool.mp4"))]
        // OTF_SB_PATHCAUSE=exports: 인코딩 전 경로(P1–P3)를 건너뛰고, §35의 4:2:0 복사 합성기 내보내기(있으면)를 같은 지표에 더한다
        let exportsOnly = ProcessInfo.processInfo.environment["OTF_SB_PATHCAUSE"] == "exports"
        let p420 = root.appendingPathComponent("path-cause/h264-P420-empty.mp4")
        if FileManager.default.fileExists(atPath: p420.path) { exports.append(("export P420-empty", p420)) }
        let v420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        // 읽기 도우미: 표본마다 (프레임, 버퍼)
        func trackReader(_ u: URL, format: OSType) async throws -> (AVAssetReader, AVAssetReaderOutput) {
            let a = AVURLAsset(url: u)
            let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
            r.add(o); return (r, o)
        }
        func compositionReader(_ vc: AVVideoComposition, format: OSType) async throws -> (AVAssetReader, AVAssetReaderOutput) {
            let r = try AVAssetReader(asset: p.composition)
            let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
            o.videoComposition = vc
            r.add(o); return (r, o)
        }
        func each(_ ro: (AVAssetReader, AVAssetReaderOutput), _ body: (Int, CMTime, CVPixelBuffer) throws -> Void) rethrows {
            ro.0.startReading()
            while let sb = ro.1.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                try body(Int((pts.seconds * 30).rounded()), pts, pb)
            }
            ro.0.cancelReading()
        }
        // VTPixelTransferSession: BGRA → 420v, 대상 709
        var vt: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &vt)
        let session = vt!
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        func toV420(_ bgra: CVPixelBuffer) -> CVPixelBuffer {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, Self.w, Self.h, v420, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
            let st = VTPixelTransferSessionTransferImage(session, from: bgra, to: out!)
            XCTAssertEqual(st, noErr)
            return out!
        }

        // P0: 원본 디코딩 4:2:0
        var ref: [Int: Planes] = [:]
        var info: [String] = []
        each(try await trackReader(src, format: v420)) { n, _, pb in
            if n == 0 { info.append("P0 source decode: \(Self.attachmentsSummary(pb))") }
            ref[n] = Self.planes(pb)
        }
        XCTAssertEqual(ref.count, 120)

        // 지표: 전체와 잡음 띠(밝기 x 300–1800, y 480–880 = 색차 x 150–900, y 240–440)
        struct Stat { var yDiff = 0, yAbs = 0, yN = 0, cbAbs = 0, crAbs = 0, cbSigned = 0, crSigned = 0, cN = 0, flick = 0, flickN = 0, frames = 0, ptsBad = 0
                      var bCbAbs = 0, bCrAbs = 0, bN = 0, bFlick = 0, bFlickN = 0 }
        func measure(_ label: String, _ body: ((Int, CMTime, CVPixelBuffer) throws -> Void) throws -> Void) rethrows -> String {
            var s = Stat()
            var prev: [Int16] = []
            try body { n, pts, pb420 in
                guard let r = ref[n] else { return }
                if CMTimeCompare(pts, CMTime(value: CMTimeValue(n), timescale: 30)) != 0 { s.ptsBad += 1 }
                if n == 0 { info.append("\(label) frame 0 buffer: \(Self.attachmentsSummary(pb420))") }
                let q = Self.planes(pb420)
                s.frames += 1
                for i in stride(from: 0, to: q.y.count, by: 2) { let d = Int(q.y[i]) - Int(r.y[i]); if d != 0 { s.yDiff += 1 }; s.yAbs += abs(d); s.yN += 1 }
                var err = [Int16](repeating: 0, count: q.c.count)
                for i in 0..<q.c.count {
                    let d = Int(q.c[i]) - Int(r.c[i]); err[i] = Int16(d)
                    if i & 1 == 0 { s.cbAbs += abs(d); s.cbSigned += d } else { s.crAbs += abs(d); s.crSigned += d }
                    let x = (i / 2) % Self.cw, y = (i / 2) / Self.cw
                    let band = x >= 150 && x < 900 && y >= 240 && y < 440
                    if band { if i & 1 == 0 { s.bCbAbs += abs(d) } else { s.bCrAbs += abs(d) }; if i & 1 == 0 { s.bN += 1 } }
                    if !prev.isEmpty { let f = abs(Int(d) - Int(prev[i])); s.flick += f; s.flickN += 1; if band { s.bFlick += f; s.bFlickN += 1 } }
                }
                s.cN += q.c.count / 2
                prev = err
            }
            let cn = Double(max(1, s.cN)), bn = Double(max(1, s.bN))
            return String(format: "%@: frames %d PTS≠n/30 %d | Y (2-px sampled) differing %.2f%% mean|ΔY| %.3f | Cb |Δ| %.3f signed %+.3f, Cr |Δ| %.3f signed %+.3f, chroma error flicker %.3f | noise band Cb |Δ| %.3f Cr |Δ| %.3f flicker %.3f",
                          label, s.frames, s.ptsBad, 100 * Double(s.yDiff) / Double(max(1, s.yN)), Double(s.yAbs) / Double(max(1, s.yN)),
                          Double(s.cbAbs) / cn, Double(s.cbSigned) / cn, Double(s.crAbs) / cn, Double(s.crSigned) / cn, Double(s.flick) / Double(max(1, s.flickN)),
                          Double(s.bCbAbs) / bn, Double(s.bCrAbs) / bn, Double(s.bFlick) / Double(max(1, s.bFlickN)))
        }
        var rows: [String] = []
        let vcA = try ExperimentalComposition.videoComposition(from: p.videoComposition)
        if !exportsOnly {
        rows.append(try await { () async throws -> String in let ro = try await compositionReader(p.videoComposition, format: v420); return try measure("P1 default compositor (reader 420v)") { try each(ro, $0) } }())
        rows.append(try await { () async throws -> String in let ro = try await compositionReader(vcA, format: v420); return try measure("P2a A compositor (reader 420v)") { try each(ro, $0) } }())
        rows.append(try await { () async throws -> String in
            let ro = try await compositionReader(vcA, format: kCVPixelFormatType_32BGRA)
            return try measure("P2b A compositor BGRA → VT 420v") { cb in try each(ro) { n, pts, pb in if n == 0 { info.append("P2b A compositor BGRA frame 0: \(Self.attachmentsSummary(pb))") }; try cb(n, pts, toV420(pb)) } }
        }())
        rows.append(try await { () async throws -> String in
            let ro = try await trackReader(src, format: kCVPixelFormatType_32BGRA)
            return try measure("P3 source BGRA → VT 420v (no compositor)") { cb in try each(ro) { n, pts, pb in if n == 0 { info.append("P3 source BGRA frame 0: \(Self.attachmentsSummary(pb))") }; try cb(n, pts, toV420(pb)) } }
        }())
        }
        for (label, u) in exports {
            rows.append(try await { () async throws -> String in let ro = try await trackReader(u, format: v420); return try measure("\(label) (decoded 420v)") { try each(ro, $0) } }())
        }
        VTPixelTransferSessionInvalidate(session)
        note("buffer formats and color attachments:\n  " + info.joined(separator: "\n  "))
        note("vs source decode in native 4:2:0 planes (8-bit codes; chroma error flicker = mean |e(n) − e(n−1)| over Cb and Cr samples):\n  " + rows.joined(separator: "\n  "))

        // 인코더 구성: avcC, 표본 크기·종류 순서
        var enc: [String] = []
        var seqs: [String: [(Int, Int, Bool)]] = [:]
        var avcc: [String: Data] = [:]
        for (label, u) in exports {
            let a = AVURLAsset(url: u)
            let t = try await a.loadTracks(withMediaType: .video).first!
            let fd = try await t.load(.formatDescriptions).first!
            let atoms = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            let d = atoms?["avcC"] as? Data ?? Data()
            avcc[label] = d
            let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
            r.add(o); r.startReading()
            var seq: [(Int, Int, Bool)] = []
            while let sb = o.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                guard pts.isValid, CMSampleBufferGetNumSamples(sb) > 0 else { continue }
                let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first ?? [:]
                seq.append((Int((pts.seconds * 30).rounded()), CMSampleBufferGetTotalSampleSize(sb), (att[kCMSampleAttachmentKey_IsDependedOnByOthers] as? Bool) ?? true))
            }
            seqs[label] = seq
            let bytes = [UInt8](d)
            enc.append(String(format: "%@: avcC %d bytes profile_idc %d compat 0x%02x level_idc %d | samples %d total %d bytes | decode-order PTS first 8 %@",
                              label, bytes.count, bytes.count > 3 ? Int(bytes[1]) : -1, bytes.count > 3 ? Int(bytes[2]) : -1, bytes.count > 3 ? Int(bytes[3]) : -1,
                              seq.count, seq.reduce(0) { $0 + $1.1 }, "\(seq.prefix(8).map(\.0))"))
        }
        let b0 = exports[0].0
        for (label, _) in exports.dropFirst() {
            let same = avcc[label] == avcc[b0]
            let orderSame = seqs[label]!.map(\.0) == seqs[b0]!.map(\.0) && seqs[label]!.map(\.2) == seqs[b0]!.map(\.2)
            let sizes = zip(seqs[label]!, seqs[b0]!).map { Double($0.1) / Double(max(1, $1.1)) }
            enc.append(String(format: "%@ vs %@: avcC identical %@ | decode order and reference flags identical %@ | per-sample size ratio min %.3f median %.3f max %.3f",
                              label, b0, same ? "yes" : "NO", orderSame ? "yes" : "NO", sizes.min() ?? 0, sizes.sorted()[sizes.count / 2], sizes.max() ?? 0))
        }
        note("encoder configuration:\n  " + enc.joined(separator: "\n  "))
    }
}
