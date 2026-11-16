import AVFoundation
import CryptoKit
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 소유자 H.264 화질 비교 준비(2026-10-21, docs/SUBTITLE-DESIGN.md §27, 실험 — 채택 아님). 선택 실행(OTF_SB=1).
/// 새 인코딩 없이 기존 제품 H.264 내보내기 두 개를 컨테이너만 이어 붙인다(passthrough): 기준 → B → 기준 → B.
/// - 기준: sb-residue/h264-base.mp4 (계획의 기본 합성기, 도구 없음, 자막 없음)
/// - B: sb-detector/h264-all5.mp4 (같은 계획 + Core Animation 도구, 기존 네 자막 + 테스트 전용 회색 자막)
/// 이어 붙인 파일의 프레임이 원본 디코딩과 같은지 확인하고, 보조 정지 그림을 만든다.
/// 결과 파일: .build/test-work/owner-quality/
extension SubtitleApproachBTests {
    func testApproachBOwnerQualityComparison() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let root = ExportEndToEndTests.root
        let base = root.appendingPathComponent("sb-residue/h264-base.mp4"), b = root.appendingPathComponent("sb-detector/h264-all5.mp4")
        let noGray = root.appendingPathComponent("sb-detector/h264-no-gray.mp4")
        let keep = root.appendingPathComponent("owner-quality")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)

        // 1. 이어 붙이기(재인코딩 없음)
        let order = [base, b, base, b]
        let comp = AVMutableComposition()
        var cursor = CMTime.zero
        var tracks: [AVMediaType: AVMutableCompositionTrack] = [:]
        var segStarts: [CMTime] = []
        for u in order {
            let a = AVURLAsset(url: u)
            let dur = try await a.load(.duration)
            segStarts.append(cursor)
            for t in try await a.load(.tracks) where t.mediaType == .video || t.mediaType == .audio {
                let ct = tracks[t.mediaType] ?? comp.addMutableTrack(withMediaType: t.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
                tracks[t.mediaType] = ct
                try ct.insertTimeRange(try await t.load(.timeRange), of: t, at: cursor)
            }
            cursor = cursor + dur
        }
        let dest = keep.appendingPathComponent("compare-baseline-B-baseline-B.mov")
        try? FileManager.default.removeItem(at: dest)   // 이 테스트가 만든 이전 출력만
        let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
        try await s.export(to: dest, as: .mov)
        note("comparison file: owner-quality/\(dest.lastPathComponent), segments start (s): \(segStarts.map { String(format: "%.3f", $0.seconds) }) total \(String(format: "%.3f", cursor.seconds)) s")
        note("source base: \(try await SubtitleABComparisonTests.describe(base))\nsource B: \(try await SubtitleABComparisonTests.describe(b))\ncomparison: \(try await SubtitleABComparisonTests.describe(dest))")

        // 2. 이어 붙인 파일의 프레임 = 원본 디코딩(같은 디코더, 비트 비교)
        let probe = [0, 33, 34, 35, 60, 119]
        let dBase = try await FrameCompare.decode(base, frames: Set(probe)), dB = try await FrameCompare.decode(b, frames: Set(probe))
        let all = Set((0..<4).flatMap { seg in probe.map { seg * 120 + $0 } })
        let dCat = try await FrameCompare.decode(dest, frames: all)
        var mism: [String] = []
        for seg in 0..<4 { for n in probe {
            let src = (seg % 2 == 0 ? dBase : dB)[n], got = dCat[seg * 120 + n]
            if src == nil || got == nil || src!.bgra != got!.bgra { mism.append("seg\(seg) f\(n)") }
        } }
        note("comparison frames vs source decodes (\(probe.count * 4) frames): \(mism.isEmpty ? "all bit-identical" : "MISMATCH \(mism)")")
        XCTAssertTrue(mism.isEmpty, "\(mism)")

        // 3. 보조 정지 그림
        let rs = (Self.captions + [Self.grayCaption]).map(Self.raster)
        let gr = rs.last!.rect
        let dNo = try await FrameCompare.decode(noGray, frames: [33, 34, 35])
        // 3a. 자막 시작 직전(회색 자막 [35, 80)): 기준 = B에서 회색만 뺀 내보내기
        let around = CGRect(x: Int(gr.minX) - 30, y: Int(gr.minY) - 30, width: 360, height: Int(gr.height) + 60)
        for n in [33, 34, 35] {
            guard let ref = dNo[n], let bb = dB[n], let bs = dBase[n] else { continue }
            try SubtitleABComparisonTests.sheet(keep.appendingPathComponent("still-pre-onset-f\(n).png"),
                title: "frame \(n) (gray caption visible from 35) — diff vs B without gray",
                rows: [("B without gray", ref), ("B (all5)", bb), ("baseline (no tool)", bs)], ref: ref,
                panels: [.init(title: "1:1", crop: around, zoom: 1, diff: false), .init(title: "x3", crop: around.insetBy(dx: 60, dy: 0), zoom: 3, diff: false),
                         .init(title: "|d| x8", crop: around, zoom: 1, diff: true)])
        }
        // 3b. 자막 밖 영상(I프레임 0과 프레임 60): 기준 대 B
        let outside = CGRect(x: 20, y: 80, width: 520, height: 330)   // 화면 코드·움직이는 상자 둘레(자막 없음)
        let noise = CGRect(x: 1300, y: 600, width: 420, height: 180)  // 잡음 무늬(자막 없음)
        for n in [0, 60] {
            guard let bs = dBase[n], let bb = dB[n] else { continue }
            try SubtitleABComparisonTests.sheet(keep.appendingPathComponent("still-outside-f\(n).png"),
                title: "frame \(n) — outside subtitle areas, diff vs baseline", rows: [("baseline (no tool)", bs), ("B (all5)", bb)], ref: bs,
                panels: [.init(title: "code/box 1:1", crop: outside, zoom: 1, diff: false), .init(title: "|d| x8", crop: outside, zoom: 1, diff: true),
                         .init(title: "noise 1:1", crop: noise, zoom: 1, diff: false), .init(title: "|d| x8", crop: noise, zoom: 1, diff: true)])
        }
        note("stills: owner-quality/still-pre-onset-f33/34/35.png, still-outside-f0/f60.png")
    }

    /// 도구만의 비교(§30): 기준(도구 없음, 자막 없음) → B-empty(같은 계획 + 도구, 자막 없음) → 기준 → B-empty. 재인코딩 없음.
    /// 두 원본은 testApproachBJapaneseResidueDiagnostics가 같은 계획(otf-TA 단독, ExportService)으로 만든 것이다(sb-residue/).
    func testApproachBOwnerToolOnlyComparison() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let root = ExportEndToEndTests.root
        let base = root.appendingPathComponent("sb-residue/h264-base.mp4"), empty = root.appendingPathComponent("sb-residue/h264-empty-tool.mp4")
        let keep = root.appendingPathComponent("owner-quality")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        let (p, _, _) = try await plan()

        // 1. 짝 확인: 크기·fps·표본 수·PTS·태그, 오디오, 화면 코드(같은 fixture·타임라인)
        func audioInfo(_ u: URL) async throws -> String {
            let a = AVURLAsset(url: u)
            guard let t = try await a.loadTracks(withMediaType: .audio).first else { return "no audio" }
            let fd = try await t.load(.formatDescriptions).first!
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)!.pointee
            let r = try await t.load(.timeRange)
            return String(format: "audio %@ %.0f Hz ch %d range %.4f+%.4f s", "\(CMFormatDescriptionGetMediaSubType(fd) == kAudioFormatMPEG4AAC ? "AAC" : "other")", asbd.mSampleRate, asbd.mChannelsPerFrame, r.start.seconds, r.duration.seconds)
        }
        for (tag, u) in [("baseline", base), ("B-empty", empty)] {
            let v = try await ExportJudge.judge(u, clips: [.init(file: "otf-TA.mp4", sourceIn: 0, length: p.durationFrames)], durationFrames: p.durationFrames, checkAudio: false)
            note("\(tag) \(u.lastPathComponent): \(try await SubtitleABComparisonTests.describe(u)) | \(try await audioInfo(u)) | screen code vs otf-TA timeline: pass \(v.pass) frames \(v.frames)")
            XCTAssertTrue(v.pass, tag)
        }

        // 2. 이어 붙이기(passthrough, 재인코딩 없음)
        let order = [base, empty, base, empty]
        let comp = AVMutableComposition()
        var cursor = CMTime.zero
        var tracks: [AVMediaType: AVMutableCompositionTrack] = [:]
        for u in order {
            let a = AVURLAsset(url: u)
            for t in try await a.load(.tracks) where t.mediaType == .video || t.mediaType == .audio {
                let ct = tracks[t.mediaType] ?? comp.addMutableTrack(withMediaType: t.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
                tracks[t.mediaType] = ct
                try ct.insertTimeRange(try await t.load(.timeRange), of: t, at: cursor)
            }
            cursor = cursor + (try await a.load(.duration))
        }
        let dest = keep.appendingPathComponent("compare-baseline-Bempty-baseline-Bempty.mov")
        try? FileManager.default.removeItem(at: dest)   // 이 테스트가 만든 이전 출력만
        let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
        try await s.export(to: dest, as: .mov)
        note("comparison: owner-quality/\(dest.lastPathComponent) total \(String(format: "%.3f", cursor.seconds)) s | \(try await SubtitleABComparisonTests.describe(dest)) | \(try await audioInfo(dest))")

        // 3. 모든 프레임: PTS = n/30 연속, 디코딩 화소 = 원본(프레임별 해시)
        func hashes(_ u: URL) async throws -> [(n: Int, exact: Bool, h: UInt64)] {
            let a = AVURLAsset(url: u)
            let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            r.add(o); r.startReading()
            var out: [(Int, Bool, UInt64)] = []
            while let sb = o.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb), n = Int((pts.seconds * 30).rounded())
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let bp = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
                var h: UInt64 = 0xcbf29ce484222325
                for y in 0..<CVPixelBufferGetHeight(pb) { for x in 0..<(CVPixelBufferGetWidth(pb) * 4) { h = (h ^ UInt64(bp[y * bpr + x])) &* 0x100000001b3 } }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                out.append((n, CMTimeCompare(pts, CMTime(value: CMTimeValue(n), timescale: 30)) == 0, h))
            }
            return out.map { (n: $0.0, exact: $0.1, h: $0.2) }
        }
        let hb = try await hashes(base), he = try await hashes(empty), hc = try await hashes(dest)
        let srcB = Dictionary(uniqueKeysWithValues: hb.map { ($0.n, $0.h) }), srcE = Dictionary(uniqueKeysWithValues: he.map { ($0.n, $0.h) })
        var bad: [String] = []
        let ns = hc.map(\.n).sorted()
        if ns != Array(0..<480) { bad.append("frame numbers not 0..<480 (count \(ns.count))") }
        for f in hc {
            if !f.exact { bad.append("f\(f.n) PTS not n/30") }
            let seg = f.n / 120, src = (seg % 2 == 0 ? srcB : srcE)[f.n % 120]
            if src != f.h { bad.append("f\(f.n) pixels differ from source") }
        }
        let differ = (0..<120).filter { srcB[$0] != srcE[$0] }.count
        note("comparison frames: \(hc.count), PTS exact n/30 and decoded pixels identical to the source section: \(bad.isEmpty ? "all" : "FAIL \(bad.prefix(10))") | baseline vs B-empty source frames that differ: \(differ)/120")
        XCTAssertTrue(bad.isEmpty, "\(bad.prefix(10))")
    }

    /// 사용자 정의 합성기만 다른 비교(§33): 기준(기본 합성기) → A-empty(실험 합성기, 기본 선택, 자막 없음) → 기준 → A-empty. 영상 재인코딩 없음.
    /// A-empty는 §30과 같은 계획(otf-TA 단독)을 제품 ExportService로 한 번 내보낸다(owner-quality/h264-A-empty.mp4, 남김).
    func testApproachAOwnerQualityComparison() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let root = ExportEndToEndTests.root
        let keep = root.appendingPathComponent("owner-quality")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        let base = root.appendingPathComponent("sb-residue/h264-base.mp4")
        let (p, ta, _) = try await plan()

        // 1. A-empty 내보내기(제품 설정 그대로, videoComposition만 실험 합성기)
        let vcA = try ExperimentalComposition.videoComposition(from: p.videoComposition)
        note("A-empty composition: customCompositor \(vcA.customVideoCompositorClass.map { "\($0)" } ?? "nil") renderSize \(vcA.renderSize) frameDuration \(vcA.frameDuration.value)/\(vcA.frameDuration.timescale) instructions \(vcA.instructions.count) animationTool \(vcA.animationTool == nil ? "nil" : "set") options \(ExperimentalCompositorOptions())")
        let aURL = keep.appendingPathComponent("h264-A-empty.mp4")
        try? FileManager.default.removeItem(at: aURL)   // 이 테스트가 만든 이전 출력만
        let outcome = await ExportService.export(withVideoComposition(p, vcA), to: .fromSavePanel(aURL), sources: [ta]) { _ in }
        XCTAssertEqual(outcome, .completed(aURL))

        // 2. 짝 확인
        func audioInfo(_ u: URL) async throws -> String {
            let a = AVURLAsset(url: u)
            guard let t = try await a.loadTracks(withMediaType: .audio).first else { return "no audio" }
            let fd = try await t.load(.formatDescriptions).first!
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)!.pointee
            let r = try await t.load(.timeRange)
            return String(format: "audio %@ %.0f Hz ch %d range %.4f+%.4f s", CMFormatDescriptionGetMediaSubType(fd) == kAudioFormatMPEG4AAC ? "AAC" : "other", asbd.mSampleRate, asbd.mChannelsPerFrame, r.start.seconds, r.duration.seconds)
        }
        for (tag, u) in [("baseline", base), ("A-empty", aURL)] {
            let v = try await ExportJudge.judge(u, clips: [.init(file: "otf-TA.mp4", sourceIn: 0, length: p.durationFrames)], durationFrames: p.durationFrames, checkAudio: false)
            note("\(tag) \(u.lastPathComponent): \(try await SubtitleABComparisonTests.describe(u)) | \(try await audioInfo(u)) | screen code vs otf-TA timeline: pass \(v.pass) frames \(v.frames)")
            XCTAssertTrue(v.pass, tag)
        }

        // 3. 이어 붙이기(passthrough)
        let comp = AVMutableComposition()
        var cursor = CMTime.zero
        var tracks: [AVMediaType: AVMutableCompositionTrack] = [:]
        for u in [base, aURL, base, aURL] {
            let a = AVURLAsset(url: u)
            for t in try await a.load(.tracks) where t.mediaType == .video || t.mediaType == .audio {
                let ct = tracks[t.mediaType] ?? comp.addMutableTrack(withMediaType: t.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
                tracks[t.mediaType] = ct
                try ct.insertTimeRange(try await t.load(.timeRange), of: t, at: cursor)
            }
            cursor = cursor + (try await a.load(.duration))
        }
        let dest = keep.appendingPathComponent("compare-baseline-Aempty-baseline-Aempty.mov")
        try? FileManager.default.removeItem(at: dest)
        let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
        try await s.export(to: dest, as: .mov)
        note("comparison: owner-quality/\(dest.lastPathComponent) total \(String(format: "%.3f", cursor.seconds)) s | \(try await SubtitleABComparisonTests.describe(dest)) | \(try await audioInfo(dest))")

        // 4. 모든 프레임: PTS = n/30 연속, 디코딩 화소 = 원본(SHA-256, 행 단위)
        func hashes(_ u: URL) async throws -> [(n: Int, exact: Bool, h: String)] {
            let a = AVURLAsset(url: u)
            let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: try await a.loadTracks(withMediaType: .video).first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            r.add(o); r.startReading()
            var out: [(Int, Bool, String)] = []
            while let sb = o.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb), n = Int((pts.seconds * 30).rounded())
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let bp = CVPixelBufferGetBaseAddress(pb)!, bpr = CVPixelBufferGetBytesPerRow(pb), rowBytes = CVPixelBufferGetWidth(pb) * 4
                var hasher = SHA256()
                for y in 0..<CVPixelBufferGetHeight(pb) { hasher.update(bufferPointer: UnsafeRawBufferPointer(start: bp + y * bpr, count: rowBytes)) }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                out.append((n, CMTimeCompare(pts, CMTime(value: CMTimeValue(n), timescale: 30)) == 0, hasher.finalize().description))
            }
            return out.map { (n: $0.0, exact: $0.1, h: $0.2) }
        }
        let hb = try await hashes(base), ha = try await hashes(aURL), hc = try await hashes(dest)
        let srcB = Dictionary(uniqueKeysWithValues: hb.map { ($0.n, $0.h) }), srcA = Dictionary(uniqueKeysWithValues: ha.map { ($0.n, $0.h) })
        var bad: [String] = []
        if hc.map(\.n).sorted() != Array(0..<480) { bad.append("frame numbers not 0..<480 (count \(hc.count))") }
        for f in hc {
            if !f.exact { bad.append("f\(f.n) PTS not n/30") }
            if (f.n / 120 % 2 == 0 ? srcB : srcA)[f.n % 120] != f.h { bad.append("f\(f.n) pixels differ from source") }
        }
        let differ = (0..<120).filter { srcB[$0] != srcA[$0] }.count
        note("comparison frames: \(hc.count), PTS exact n/30 and decoded pixels identical to the source section: \(bad.isEmpty ? "all" : "FAIL \(bad.prefix(10))") | baseline vs A-empty source frames that differ: \(differ)/120")
        XCTAssertTrue(bad.isEmpty, "\(bad.prefix(10))")
    }
}
