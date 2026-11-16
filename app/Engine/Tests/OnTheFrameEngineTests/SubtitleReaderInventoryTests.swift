import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 구조 R 리더 출력 호환 목록(2026-10-22, docs/SUBTITLE-DESIGN.md §40, 새 내보내기 없음). 선택 실행(OTF_SB=1).
/// 이미 있는 생성 fixture(다시 만들지 않음)로 지금 계획기가 만드는 타임라인마다, 원본 트랙 메타데이터와
/// 기본 합성기 리더 출력(요청 없음 / 420v 요청)의 실제 형식·평면·첨부·PTS를 기록한다. 화면 코드가 있는 원본은 원본 프레임도 확인한다.
extension SubtitleApproachBTests {
    func testApproachBReaderOutputInventory() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        let fx = ExportEndToEndTests.root.appendingPathComponent("fixtures")
        func url(_ f: String) throws -> URL {
            let u = fx.appendingPathComponent(f)
            guard FileManager.default.fileExists(atPath: u.path) else { throw XCTSkip("fixture \(f) missing (not regenerated)") }
            return u
        }
        func fourCC(_ f: OSType) -> String { String(format: "%c%c%c%c", (f >> 24) & 255, (f >> 16) & 255, (f >> 8) & 255, f & 255) }
        func ext(_ fd: CMFormatDescription) -> String {
            let e = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
            let keys: [(String, String)] = [("prim", kCVImageBufferColorPrimariesKey as String), ("xfer", kCVImageBufferTransferFunctionKey as String), ("matrix", kCVImageBufferYCbCrMatrixKey as String),
                                            ("fullRange", kCMFormatDescriptionExtension_FullRangeVideo as String), ("chromaLoc", kCVImageBufferChromaLocationTopFieldKey as String),
                                            ("depth", kCMFormatDescriptionExtension_Depth as String), ("bpc", kCMFormatDescriptionExtension_BitsPerComponent as String)]
            return keys.map { "\($0.0)=\(e[$0.1].map { "\($0)" } ?? "none")" }.joined(separator: " ")
        }
        func attach(_ pb: CVPixelBuffer) -> String {
            let keys: [(String, CFString)] = [("prim", kCVImageBufferColorPrimariesKey), ("xfer", kCVImageBufferTransferFunctionKey), ("matrix", kCVImageBufferYCbCrMatrixKey),
                                              ("chromaTop", kCVImageBufferChromaLocationTopFieldKey), ("chromaBottom", kCVImageBufferChromaLocationBottomFieldKey)]
            return keys.map { "\($0.0)=\(CVBufferCopyAttachment(pb, $0.1, nil).map { "\($0)" } ?? "none")" }.joined(separator: " ")
        }
        func layout(_ pb: CVPixelBuffer) -> String {
            let n = CVPixelBufferGetPlaneCount(pb)
            let planes = (0..<max(1, n)).map { i in n == 0 ? "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) bpr \(CVPixelBufferGetBytesPerRow(pb))"
                : "\(CVPixelBufferGetWidthOfPlane(pb, i))x\(CVPixelBufferGetHeightOfPlane(pb, i)) bpr \(CVPixelBufferGetBytesPerRowOfPlane(pb, i))" }
            return "\(fourCC(CVPixelBufferGetPixelFormatType(pb))) planes \(n) [\(planes.joined(separator: "; "))]"
        }

        struct Case { let name: String; let files: [String]; let build: ([String: MediaAsset]) throws -> Timeline; let coded: Bool }
        let cases: [Case] = [
            Case(name: "control: otf-TA H.264 1080p identity", files: ["otf-TA.mp4"], build: { m in try Timeline().registering(m["otf-TA.mp4"]!).inserting(media: m["otf-TA.mp4"]!.id) }, coded: true),
            Case(name: "SD plate 640x480 (fit to 1080)", files: ["plate-red-640x480.mp4"], build: { m in try Timeline().registering(m["plate-red-640x480.mp4"]!).inserting(media: m["plate-red-640x480.mp4"]!.id) }, coded: false),
            Case(name: "HEVC 1280x720 (scaled 1.5)", files: ["otf-hevc.mp4"], build: { m in try Timeline().registering(m["otf-hevc.mp4"]!).inserting(media: m["otf-hevc.mp4"]!.id) }, coded: false),
            Case(name: "HEVC 59.94 fps .mov (timed fixture)", files: ["otf-H5994.mov"], build: { m in try Timeline().registering(m["otf-H5994.mov"]!).inserting(media: m["otf-H5994.mov"]!.id) }, coded: true),
            Case(name: "rotated 90° 640x360", files: ["otf-rot90.mp4"], build: { m in try Timeline().registering(m["otf-rot90.mp4"]!).inserting(media: m["otf-rot90.mp4"]!.id) }, coded: false),
            Case(name: "mixed fps sequence 23.976 → 29.97 → 25 → VFR", files: ["otf-F23976.mp4", "otf-N2997.mp4", "otf-P25.mp4", "otf-VFR.mp4"], build: { m in
                var t = Timeline()
                for f in ["otf-F23976.mp4", "otf-N2997.mp4", "otf-P25.mp4", "otf-VFR.mp4"] { t = try t.registering(m[f]!).inserting(media: m[f]!.id) }
                return t }, coded: true),
            Case(name: "gap: otf-A, 15-frame gap, otf-B", files: ["otf-A.mp4", "otf-B.mp4"], build: { m in
                var t = try Timeline().registering(m["otf-A.mp4"]!).registering(m["otf-B.mp4"]!).inserting(media: m["otf-A.mp4"]!.id)
                t = try t.placing(media: m["otf-B.mp4"]!.id, at: t.durationFrames + 15, videoLane: Lane.videoID, audioLane: Lane.audioID)
                return t }, coded: true),
            Case(name: "mixed color: SD plate bottom + HD plate top (scale 0.5)", files: ["plate-red-640x480.mp4", "plate-green-1280x720.mp4"], build: { m in
                let top = UUID()
                var t = try Timeline().registering(m["plate-red-640x480.mp4"]!).registering(m["plate-green-1280x720.mp4"]!).inserting(media: m["plate-red-640x480.mp4"]!.id)
                    .addingLane(.video, name: "P", id: top, outward: true)
                t = try t.placing(media: m["plate-green-1280x720.mp4"]!.id, at: 0, videoLane: top, audioLane: nil)
                return try t.settingTransform(clip: t.clips(inLane: top)[0].id, ClipTransform(scale: 0.5, x: 0, y: 0)) }, coded: false),
            Case(name: "§18 two-layer: otf-TA + 1280x720 pattern (0.9 px/px at 720.25, 410.5)", files: ["otf-TA.mp4", "../ab-compare/fixture-pattern-1280x720-120f.mp4"], build: { m in
                let ta = m["otf-TA.mp4"]!, pat = m["../ab-compare/fixture-pattern-1280x720-120f.mp4"]!
                let render = CGSize(width: 1920, height: 1080)
                let r0 = CompositionPlanner.displayRect(pat, ClipTransform(scale: 0.6, x: 0, y: 0), render: render)
                let xf = ClipTransform(scale: 0.6, x: SubtitleABComparisonTests.layerOrigin.x - r0.minX, y: SubtitleABComparisonTests.layerOrigin.y - r0.minY)
                let top = UUID()
                var t = try Timeline().registering(ta).registering(pat).inserting(media: ta.id).addingLane(.video, name: "P", id: top, outward: true)
                t = try t.placing(media: pat.id, at: 0, videoLane: top, audioLane: nil)
                return try t.settingTransform(clip: t.clips(inLane: top)[0].id, xf) }, coded: true),
        ]

        for c in cases {
            var media: [String: MediaAsset] = [:]
            var srcRows: [String] = []
            for f in c.files {
                let u = try url(f)
                let m = try await MediaProbe.inspect(u); media[f] = m
                let tr = try await AVURLAsset(url: u).loadTracks(withMediaType: .video).first!
                let fd = try await tr.load(.formatDescriptions).first!, d = CMVideoFormatDescriptionGetDimensions(fd)
                let tf = try await tr.load(.preferredTransform)
                srcRows.append("\(f): \(fourCC(CMFormatDescriptionGetMediaSubType(fd))) \(d.width)x\(d.height) transform \(tf == .identity ? "identity" : "\(tf)") fps \(try await tr.load(.nominalFrameRate)) | \(ext(fd))")
            }
            let t = try c.build(media)
            let byID = Dictionary(uniqueKeysWithValues: media.values.map { ($0.id, $0) })
            let p = try await CompositionPlanner.plan(t, media: byID)
            let n = p.durationFrames
            // 표본 프레임: 처음·끝·경계(화면 코드가 있으면 기대 경계)
            var expected: [ExportJudge.Expected]? = nil
            var sample: Set<Int> = [0, 1, n / 2, n - 1]
            if c.coded {
                let fileOf = Dictionary(uniqueKeysWithValues: media.map { ($0.value.id, $0.key) })
                let refs = t.clips(inLane: Lane.videoID).map { ExportJudge.ClipRef(file: fileOf[$0.mediaID]!, start: $0.start, sourceIn: $0.sourceIn, length: $0.length) }
                let (ex, _) = try ExportJudge.expectations(refs, durationFrames: n)
                expected = ex
                sample.formUnion(ExportJudge.boundaryFrames(ex))
            }
            // 리더: 요청 없음(합성기 기본) / 420v 요청 / (화면 코드) BGRA
            var durations: [(Int, CMTime)] = []
            func readAll(_ settings: [String: Any]?, _ body: (Int, CMTime, CVPixelBuffer) -> Void) async throws -> AVAssetReader.Status {
                durations = []
                let r = try AVAssetReader(asset: p.composition)
                let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await p.composition.loadTracks(withMediaType: .video), videoSettings: settings)
                o.videoComposition = p.videoComposition; o.alwaysCopiesSampleData = false
                r.add(o); r.startReading()
                while let sb = o.copyNextSampleBuffer() {
                    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                    durations.append((Int((pts.seconds * 30).rounded()), CMSampleBufferGetDuration(sb)))
                    body(Int((pts.seconds * 30).rounded()), pts, pb)
                }
                return r.status
            }
            var rows: [String] = []
            for (label, settings) in [("default (videoSettings nil)", nil), ("420v requested", [kCVPixelBufferPixelFormatTypeKey as String: Passthrough420Compositor.format] as [String: Any])] as [(String, [String: Any]?)] {
                var frames = 0, ptsBad = 0, dims = Set<String>(), formats = Set<String>(), attachSeen: [String: [Int]] = [:], sampled: [String] = [], gapY: [String] = []
                let status = try await readAll(settings) { k, pts, pb in
                    frames += 1
                    if CMTimeCompare(pts, CMTime(value: CMTimeValue(k), timescale: 30)) != 0 { ptsBad += 1 }
                    dims.insert("\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"); formats.insert(layout(pb))
                    attachSeen[attach(pb), default: []].append(k)
                    if sample.contains(k) { sampled.append("f\(k)") }
                    if let ex = expected, k < ex.count, case .gap = ex[k], CVPixelBufferGetPixelFormatType(pb) == Passthrough420Compositor.format, gapY.count < 2 {
                        CVPixelBufferLockBaseAddress(pb, .readOnly)
                        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
                        gapY.append("gap f\(k) Y[540,960]=\(y[540 * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + 960]) CbCr[270,480]=\(c[270 * CVPixelBufferGetBytesPerRowOfPlane(pb, 1) + 960]),\(c[270 * CVPixelBufferGetBytesPerRowOfPlane(pb, 1) + 961])")
                        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                    }
                }
                let oneFrame = CMTime(value: 1, timescale: 30)
                let long = durations.filter { CMTimeCompare($0.1, oneFrame) != 0 }
                let covered = durations.reduce(0.0) { $0 + $1.1.seconds * 30 }
                let durRow = String(format: "sample durations ≠ 1/30: %d (sum of all durations %.3f frames)", long.count, covered) + (long.isEmpty ? "" : " e.g. " + long.prefix(6).map { "f\($0.0) dur \($0.1.value)/\($0.1.timescale) (\(String(format: "%.2f", $0.1.seconds * 30)) frames)" }.joined(separator: ", "))
                let attachRows = attachSeen.map { a, ks in "\(a) → frames \(ks.min()!)–\(ks.max()!) (\(ks.count))" }.sorted()
                rows.append("\(label): status \(status.rawValue) samples \(frames) for \(n) timeline frames, PTS≠n/30 \(ptsBad), \(durRow) | dims \(dims) | formats \(formats) | attachments: \(attachRows.joined(separator: " ;; "))" + (gapY.isEmpty ? "" : " | \(gapY.joined(separator: ", "))"))
            }
            var idRow = "source identity: not verifiable (no screen code in this fixture)"
            if let ex = expected {
                var checked = 0, bad: [Int] = []
                _ = try await readAll([kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]) { k, _, pb in
                    guard sample.contains(k), k < ex.count else { return }
                    checked += 1
                    if !ExportJudge.matches(E2Metrics.measure(pb), ex[k]) { bad.append(k) }
                }
                idRow = "source identity (screen code, BGRA read, sampled frames incl. boundaries): checked \(checked) mismatched \(bad)"
            }
            note("CASE \(c.name)\n  plan: frames \(n) render \(p.videoComposition.renderSize) instructions \(p.videoComposition.instructions.count) | sample frames \(sample.sorted())\n  source tracks:\n    " + srcRows.joined(separator: "\n    ") + "\n  composed (default compositor reader):\n    " + rows.joined(separator: "\n    ") + "\n  " + idRow)
        }
    }
}
