#if DEBUG
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import OnTheFrameEngine

/// SP-EXPORT-E4d(2026-11-23): 프리뷰가 실제로 올린 스펙트럼·자막 층의 그림과, 같은 타임라인을 제품 쓰기 경로로 내보낸 MP4의
/// 디코딩한 프레임을 견준다. 비교 범위는 "프리뷰의 스펙트럼·자막 층 대 인코딩된 내보내기"다 — 프리뷰의 영상(AVPlayerLayer)은
/// 읽을 수 없으므로 합성된 프리뷰 화면 전체의 비교가 아니다. 프리뷰는 멈춘(탐색) 경로만 본다. 재생 경로는 보지 않는다.
/// 실행: `open -n -a OnTheFrame.app <폴더> --args -OTFSpectrumParityTest`(Debug 전용, 명시적 실행 인수로만).
/// <폴더>/sources에 생성 재료 gray.mov(2 s 회색 영상과 소리), tone-1s.wav(1 s 440 Hz)가 있어야 한다.
/// 내보내기는 엔진의 DEBUG 전용 내부 진입점(ExportService.exportSpectrumTimeline)을 쓴다. 공개 내보내기 차단은 그대로다.
/// 결과는 <폴더>/spectrum-parity-result.json, 증거는 <폴더>/preview/*.png, <폴더>/out/parity.mp4, <폴더>/spectrum-parity-evidence.json.
@MainActor
enum SpectrumParitySelfTest {
    typealias Check = LaneSelfTest.Check
    /// 1 스펙트럼 전, 2 스펙트럼(무음: 0높이 점)만, 3 스펙트럼(막대)만, 4 스펙트럼과 자막, 5 스펙트럼 뒤
    static let frames = [5, 20, 34, 38, 50]
    static let spectrumRange = 15..<45, subtitleRange = 36..<42, toneStart = 30
    /// 시험용 한도(E4-a와 같음). 제품 값이 아니다.
    static let limits = SpectrumTimelineExportLimits(stepTimeout: 30, jobTimeout: 300, frameMemoryBudgetBytes: 128 << 20)
    static let w = 1920, h = 1080, margin = 3
    /// 허용 오차(8비트 값): 층 안쪽은 밝기·색차 ±24, 비어 있는 곳은 ±16. 첫 실행 전에 고른 값이며 실제 차이는 증거에 적는다.
    static let layerTolerance = 24, clearTolerance = 16, changed = 48

    /// 프리뷰 층 하나에서 읽은 것. 화소는 미리 곱한 BGRA(행 채움 없이), rect는 출력 화면 좌표(위 왼쪽 원점).
    struct Captured {
        let kind: String, id: UUID, x: Int, y: Int, width: Int, height: Int, opacity: Float, bytes: [UInt8]
        func alpha(_ px: Int, _ py: Int) -> UInt8 {
            let lx = px - x, ly = py - y
            guard lx >= 0, lx < width, ly >= 0, ly < height else { return 0 }
            return bytes[(ly * width + lx) * 4 + 3]
        }
        /// 알파가 0보다 큰 화소가 하나라도 있는 행의 수(칠해진 높이). 자른 그림의 높이(height)에는 앤티에일리어싱 여백이 든다.
        var paintedRows: Int { (0..<height).filter { row in (0..<width).contains { bytes[(row * width + $0) * 4 + 3] > 0 } }.count }
        /// 그 화소의 색을 BT.709 영상 범위 Y'CbCr로(알파가 0이 아닌 곳만 부른다)
        func ycc(_ px: Int, _ py: Int) -> (Double, Double, Double) {
            let o = ((py - y) * width + (px - x)) * 4, a = Double(bytes[o + 3])
            let b = Double(bytes[o]) / a, g = Double(bytes[o + 1]) / a, r = Double(bytes[o + 2]) / a
            let yp = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return (16 + 219 * yp, 128 + 224 * (b - yp) / 1.8556, 128 + 224 * (r - yp) / 1.5748)
        }
    }
    struct Planes { let y: [UInt8], c: [UInt8] }
    struct Tally: Codable { var total = 0, within = 0, sumY = 0, sumC = 0, maxY = 0, maxC = 0
        var fraction: Double { total == 0 ? 0 : Double(within) / Double(total) } }
    struct FrameEvidence: Codable {
        var frame = 0, previewLayers: [String] = [], rects: [[Int]] = [], opacities: [Float] = []
        var layerTallies: [Tally] = [], overlap = Tally(), clear = Tally()
        var previewBounds: [Int] = [], exportBounds: [Int] = [], exportChanged = 0
    }

    @MainActor final class Report {
        let s: ProjectStore, folder: URL
        var checks: [Check] = [], evidence: [FrameEvidence] = [], notes: [String: String] = [:]
        init(s: ProjectStore, folder: URL) { self.s = s; self.folder = folder }
        func check(_ name: String, _ pass: Bool, _ detail: String = "") { checks.append(Check(name: name, pass: pass, detail: detail)) }
        func finish() {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            struct Evidence: Codable { let scope: String; let frames: [FrameEvidence]; let notes: [String: String] }
            let scope = "Preview Spectrum overlay and subtitle layers (paused path) versus encoded Export. Not full composited Preview parity."
            if let data = try? encoder.encode(Evidence(scope: scope, frames: evidence, notes: notes)) {
                try? data.write(to: folder.appendingPathComponent("spectrum-parity-evidence.json"))
            }
            if let data = try? encoder.encode(checks) { try? data.write(to: folder.appendingPathComponent("spectrum-parity-result.json")) }
            s.discardConfirmedForTest(); NSApp.terminate(nil)
        }
    }

    /// compositor: "builtin"(기본, 지금과 같음) 또는 "corrected"(SP-EXPORT-E4D-INTEGRATION-PILOT-45 DEBUG 시범 —
    /// 프리뷰 항목과 내보내기 계획의 영상 합성만 실험 합성기 fullRectangle로 바꾼다). 단정과 허용 오차는 두 방식이 같다.
    /// corrected일 때만 결과에 `pilot.correctedCompositorInstalled` 행이 하나 더 있다(55행 → 56행).
    static func run(folder: URL, compositor: String = "builtin") async {
        let s = ProjectStore.shared, report = Report(s: s, folder: folder)
        let corrected = compositor == "corrected"
        report.notes["compositor"] = compositor
        var swapped = 0, swapFailures: [String] = []
        if corrected {
            s.itemCreatedHookForTest = { item, _ in
                guard let base = item.videoComposition else { return }
                do { item.videoComposition = try ExperimentalComposition.videoComposition(from: base, options: .init(edgeCoverage: .fullRectangle)); swapped += 1 }
                catch { swapFailures.append("\(error)") }
            }
        }
        defer { s.itemCreatedHookForTest = nil }
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil && s.previewHost?.window != nil }
        guard let view = s.previewHost, let window = s.editorWindow else { report.check("setup.view", false); report.finish(); return }
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
        do {
            let scene = try await prepare(report, view: view)
            var captures: [Int: [Captured]] = [:]
            for k in frames { captures[k] = try await capture(k, scene: scene, report: report) }
            if corrected {
                report.check("pilot.correctedCompositorInstalled", swapped > 0 && swapFailures.isEmpty && s.player.currentItem?.videoComposition?.customVideoCompositorClass != nil,
                             "preview items switched \(swapped), failures \(swapFailures)")
            }
            guard let planes = try await export(scene: scene, report: report, compositor: corrected ? .init(edgeCoverage: .fullRectangle) : nil) else { report.finish(); return }
            if let reference = planes[frames[0]] {
                let source = try await sourceLevels(report.folder.appendingPathComponent("sources/gray.mov"), frame: frames[0])
                judgeBackground(reference, source: source, report)
            }
            compare(captures, planes, report)
        } catch { report.check("fixture.orExecution", false, "\(error)") }
        report.finish()
    }

    // MARK: 장면

    struct Scene { let view: PlayerNSView, low: UUID, high: UUID, subtitle: UUID, timeline: Timeline }
    static func style(red: Int, green: Int, blue: Int, lowerBy: Int) -> SpectrumItemStyle {
        var s = SpectrumItemStyle.provisionalDefault
        s.mode = .digital; s.maxHeightMilli = 200_000; s.thicknessMilli = 16_000; s.red = red; s.green = green; s.blue = blue
        s.startYMilli += lowerBy * 1000; s.endYMilli += lowerBy * 1000
        return s
    }
    /// 영상과 그 소리 [0, 60), 둘째 소리 레인의 1 s 소리 [30, 60), 스펙트럼 둘 [15, 45)(노랑, 32 px 아래의 흰색), 자막 [36, 42)
    static func prepare(_ report: Report, view: PlayerNSView) async throws -> Scene {
        let s = report.s
        let video = try await MediaProbe.inspect(report.folder.appendingPathComponent("sources/gray.mov"))
        let tone = try await MediaProbe.inspect(report.folder.appendingPathComponent("sources/tone-1s.wav"))
        let wavLane = UUID(), clip = UUID(), lowLane = UUID(), highLane = UUID(), low = UUID(), high = UUID(), subLane = UUID(), sub = UUID()
        var subtitleStyle = SubtitleStyle.default
        subtitleStyle.sizeTenths = 720; subtitleStyle.xMilli = 960_000; subtitleStyle.yMilli = 565_000
        var t = try Timeline().registering(video).registering(tone)
            .addingLane(.audio, name: "WAV", id: wavLane)
            .placing(media: video.id, at: 0, videoLane: Lane.videoID, audioLane: Lane.audioID)
            .placing(media: tone.id, at: toneStart, videoLane: nil, audioLane: wavLane, clipID: clip)
        guard let key = t.clip(clip)?.lineageKey else { throw NSError(domain: "fixture.audio", code: 1) }
        let length = spectrumRange.count
        t = try t.addingLane(.spectrum, name: "SP low", id: lowLane, outward: true)
            .addingSpectrum(lane: lowLane, at: spectrumRange.lowerBound, length: length, sourceKey: key, style: style(red: 255, green: 255, blue: 0, lowerBy: 0), id: low)
            .addingLane(.spectrum, name: "SP high", id: highLane, outward: true)
            .addingSpectrum(lane: highLane, at: spectrumRange.lowerBound, length: length, sourceKey: key, style: style(red: 255, green: 255, blue: 255, lowerBy: 32), id: high)
            .addingLane(.subtitle, name: "S", id: subLane, outward: true)
            .addingSubtitle(lane: subLane, at: subtitleRange.lowerBound, length: subtitleRange.count, text: "ON THE FRAME", style: subtitleStyle, id: sub)
        s.assetCache[video.url.standardizedFileURL.path] = video
        s.assetCache[tone.url.standardizedFileURL.path] = tone
        s.loadTimelineForTest(t)
        let applied = await LaneSelfTest.waitUntil(15) { s.appliedGeneration == s.generation && s.player.currentItem != nil }
        report.check("setup.timeline", applied && s.timeline == t && t.isValid && t.durationFrames == 60, "duration \(t.durationFrames)")
        report.notes["canvas"] = "view \(view.bounds.size) spectrumCanvas bounds \(view.spectrumCanvas.bounds.size) position \(view.spectrumCanvas.position) scale \(view.spectrumCanvas.affineTransform().a)"
        return Scene(view: view, low: low, high: high, subtitle: sub, timeline: t)
    }

    // MARK: 프리뷰에서 읽기

    /// 재생 헤드를 프레임 k에 두고, 프리뷰가 그 프레임의 묶음을 다 올렸을 때(관찰할 수 있는 조건) 층의 그림과 자리를 읽는다
    static func capture(_ k: Int, scene: Scene, report: Report) async throws -> [Captured] {
        let s = report.s, overlay = scene.view.spectrumOverlay
        let expected = scene.timeline.spectra.reversed().filter { $0.visible(atFrame: k) }.map(\.id)
        s.seek(to: k)
        let ready = await LaneSelfTest.waitUntil(15) {
            s.appliedGeneration == s.generation && !s.isPlaying && overlay.confirmedFrame == k &&
            CMTimeCompare(s.player.currentTime(), CMTime(value: Int64(k), timescale: 30)) == 0 &&
            (expected.isEmpty ? overlay.layers.isEmpty : overlay.presentedFrameForTest == k && overlay.layers.count == expected.count)
        }
        report.check("frame\(k).previewReady", ready, "confirmed \(String(describing: overlay.confirmedFrame)) presented \(String(describing: overlay.presentedFrameForTest)) layers \(overlay.layers.count)")
        guard ready else { return [] }
        // 그리는 차례는 캔버스의 실제 하위 층 차례(아래부터)
        let order = (scene.view.spectrumCanvas.sublayers ?? []).compactMap { layer in overlay.layers.first { $0.value === layer }?.key }
        report.check("frame\(k).previewLayerOrder", order == expected, "canvas \(order.map { $0 == scene.low ? "low" : "high" })")
        var out: [Captured] = []
        for id in order {
            guard let layer = overlay.layers[id], let c = captured("spectrum", id, layer, opacity: layer.opacity) else {
                report.check("frame\(k).previewImage", false, "spectrum layer without a readable image"); continue
            }
            out.append(c)
        }
        // 자막: 프리뷰의 자막 층(시간에 묶인 불투명도). 보이는 것만 담는다.
        let subtitleShown = subtitleRange.contains(k)
        if subtitleShown { _ = await LaneSelfTest.waitUntil(5) { scene.view.subtitleLayerForTest(scene.subtitle)?.contents != nil } }
        let layer = scene.view.subtitleLayerForTest(scene.subtitle)
        let opacity = layer?.presentation()?.opacity ?? layer?.opacity ?? 0
        report.check("frame\(k).previewSubtitleVisibility", (opacity > 0.5) == subtitleShown, "presentation opacity \(opacity), model \(subtitleShown)")
        if opacity > 0.5, let layer, !layer.isHidden, let c = captured("subtitle", scene.subtitle, layer, opacity: opacity) { out.append(c) }
        let host = scene.view.layer?.sublayers ?? []
        if let a = host.firstIndex(where: { $0 === scene.view.spectrumCanvas }), let b = host.firstIndex(where: { $0 === scene.view.subtitleSync?.superlayer }) {
            report.check("frame\(k).previewSubtitleAboveSpectrum", b > a, "sublayer index spectrum \(a) subtitle host \(b)")
        }
        for (i, c) in out.enumerated() { save(c, report.folder.appendingPathComponent("preview/frame-\(k)-\(i)-\(c.kind).png")) }
        return out
    }
    /// 층의 실제 내용(CGImage)과 자리. 그림 한 화소가 출력 화면 한 화소여야 한다(자른 그림을 그 사각형에 놓는다).
    static func captured(_ kind: String, _ id: UUID, _ layer: CALayer, opacity: Float) -> Captured? {
        guard let content = layer.contents, CFGetTypeID(content as CFTypeRef) == CGImage.typeID else { return nil }
        let image = content as! CGImage, f = layer.frame
        guard image.bitsPerPixel == 32, Int(f.width.rounded()) == image.width, Int(f.height.rounded()) == image.height,
              let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for row in 0..<image.height { for i in 0..<(image.width * 4) { bytes[row * image.width * 4 + i] = p[row * image.bytesPerRow + i] } }
        // 층 좌표는 아래가 원점(PausedSpectrumOverlay.layerRect, 자막도 같다) → 출력 화면의 위 왼쪽 원점으로
        return Captured(kind: kind, id: id, x: Int(f.minX.rounded()), y: h - Int(f.maxY.rounded()), width: image.width, height: image.height,
                        opacity: opacity, bytes: bytes)
    }
    static func save(_ c: Captured, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: Data(c.bytes) as CFData),
              let image = CGImage(width: c.width, height: c.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: c.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
    }

    // MARK: 내보내기와 디코딩

    /// 같은 타임라인을 DEBUG 전용 내부 진입점으로 내보낸다. 대상은 이 실행 폴더의 새 파일이고 덮어쓰기를 확인하지 않은 대상이다
    /// (파일이 이미 있으면 보통 규칙대로 거부된다).
    static func export(scene: Scene, report: Report, compositor: ExperimentalCompositorOptions? = nil) async throws -> [Int: Planes]? {
        let s = report.s, out = report.folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = out.appendingPathComponent("parity.mp4")
        report.check("export.sameTimeline", s.timeline == scene.timeline && s.spectrumExportBlockReason != nil,
                     "public block reason present \(s.spectrumExportBlockReason != nil)")
        let destination = ExportDestination(url: file, confirmedReplace: false, identityAtConfirmation: nil)
        let outcome = await ExportService.exportSpectrumTimeline(s.timeline, media: s.mediaByID, enabled: true, to: destination, limits: limits,
                                                                 experimentalCompositor: compositor)
        let completed: Bool
        if case .completed = outcome { completed = true } else { completed = false }
        report.check("export.completed", completed, "\(outcome)")
        guard completed else { return nil }
        let planes = try await decode(file)
        report.check("export.decodedFrames", frames.allSatisfy { planes[$0] != nil }, "decoded \(planes.keys.sorted())")
        return frames.allSatisfy { planes[$0] != nil } ? planes : nil
    }
    static func decode(_ url: URL) async throws -> [Int: Planes] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [:] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "parity reader", code: 1) }
        var out: [Int: Planes] = [:]
        while let sample = output.copyNextSampleBuffer() {
            let k = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 30).rounded())
            guard frames.contains(k), let pb = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetWidth(pb) == w, CVPixelBufferGetHeight(pb) == h else { continue }
            out[k] = planes(pb)
        }
        return out
    }
    static func planes(_ pb: CVPixelBuffer) -> Planes {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var y = [UInt8](repeating: 0, count: w * h), c = [UInt8](repeating: 0, count: w * h / 2)
        let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        y.withUnsafeMutableBytes { d in for row in 0..<h { memcpy(d.baseAddress! + row * w, yb + row * ybpr, w) } }
        c.withUnsafeMutableBytes { d in for row in 0..<(h / 2) { memcpy(d.baseAddress! + row * w, cb + row * cbpr, w) } }
        return Planes(y: y, c: c)
    }

    // MARK: 비교

    /// 화소마다 맨 위의 불투명한 층(없으면 -1, 반투명이 걸치면 -2)
    static func owners(_ layers: [Captured]) -> [Int8] {
        var owner = [Int8](repeating: -1, count: w * h)
        for (i, c) in layers.enumerated() {
            for ly in 0..<c.height { for lx in 0..<c.width {
                let a = c.bytes[(ly * c.width + lx) * 4 + 3]
                let px = c.x + lx, py = c.y + ly
                guard a > 0, px >= 0, px < w, py >= 0, py < h else { continue }
                owner[py * w + px] = a > 200 ? Int8(i) : -2   // 위 층이 나중에 쓴다
            } }
        }
        return owner
    }
    static func uniform(_ owner: [Int8], _ x: Int, _ y: Int) -> Bool {
        guard x >= margin, x < w - margin, y >= margin, y < h - margin else { return false }
        let v = owner[y * w + x]
        for dy in -margin...margin { for dx in -margin...margin where owner[(y + dy) * w + x + dx] != v { return false } }
        return true
    }
    static func add(_ t: inout Tally, _ dy: Int, _ dc: Int, tolerance: Int) {
        t.total += 1; t.sumY += dy; t.sumC += dc; t.maxY = max(t.maxY, dy); t.maxC = max(t.maxC, dc)
        if dy <= tolerance && dc <= tolerance { t.within += 1 }
    }
    static func describe(_ t: Tally) -> String {
        t.total == 0 ? "no pixels" : String(format: "%d/%d within, mean dY %.1f dC %.1f, max dY %d dC %d", t.within, t.total,
                                            Double(t.sumY) / Double(t.total), Double(t.sumC) / Double(t.total), t.maxY, t.maxC)
    }
    /// 프레임 하나: 프리뷰 층의 안쪽 화소는 그 층의 색으로, 층이 없는 곳은 스펙트럼 전 프레임과 같게 인코딩됐는가. 테두리도 본다.
    static func measure(_ k: Int, _ layers: [Captured], _ p: Planes, background: Planes) -> FrameEvidence {
        var e = FrameEvidence(frame: k)
        e.previewLayers = layers.map(\.kind); e.rects = layers.map { [$0.x, $0.y, $0.width, $0.height] }; e.opacities = layers.map(\.opacity)
        e.layerTallies = layers.map { _ in Tally() }
        let owner = owners(layers)
        var pb = [Int.max, Int.max, Int.min, Int.min], xb = pb
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x, ci = (y / 2) * w + 2 * (x / 2), o = owner[i]
            let dy = abs(Int(p.y[i]) - Int(background.y[i]))
            let dc = max(abs(Int(p.c[ci]) - Int(background.c[ci])), abs(Int(p.c[ci + 1]) - Int(background.c[ci + 1])))
            if dy > changed || dc > changed { e.exportChanged += 1; xb = [min(xb[0], x), min(xb[1], y), max(xb[2], x), max(xb[3], y)] }
            if o != -1 { pb = [min(pb[0], x), min(pb[1], y), max(pb[2], x), max(pb[3], y)] }
            if o >= 0 {
                guard uniform(owner, x, y) else { continue }
                let (ey, ecb, ecr) = layers[Int(o)].ycc(x, y)
                let ly = abs(Int(p.y[i]) - Int(ey.rounded())), lc = max(abs(Int(p.c[ci]) - Int(ecb.rounded())), abs(Int(p.c[ci + 1]) - Int(ecr.rounded())))
                add(&e.layerTallies[Int(o)], ly, lc, tolerance: layerTolerance)
                if (0..<Int(o)).contains(where: { layers[$0].alpha(x, y) > 200 }) { add(&e.overlap, ly, lc, tolerance: layerTolerance) }
            } else if o == -1, x % 4 == 0, y % 4 == 0, uniform(owner, x, y) {
                add(&e.clear, dy, dc, tolerance: clearTolerance)
            }
        } }
        e.previewBounds = pb[0] == Int.max ? [] : pb; e.exportBounds = xb[0] == Int.max ? [] : xb
        return e
    }
    /// 원본 영상의 프레임 k(타임라인 프레임 k와 같은 원본 프레임)의 밝기·색차 범위. 내보낸 프레임과 무관하게 원본에서 직접 읽는다.
    static func sourceLevels(_ url: URL, frame k: Int) async throws -> (y: ClosedRange<Int>, c: ClosedRange<Int>)? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "parity source reader", code: 1) }
        while let sample = output.copyNextSampleBuffer() {
            guard Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 30).rounded()) == k, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
            let sw = CVPixelBufferGetWidth(pb), sh = CVPixelBufferGetHeight(pb)
            let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let yp = yb.assumingMemoryBound(to: UInt8.self), cp = cb.assumingMemoryBound(to: UInt8.self)
            var yLow = 255, yHigh = 0, cLow = 255, cHigh = 0
            for row in 0..<sh { for x in 0..<sw { let v = Int(yp[row * ybpr + x]); yLow = min(yLow, v); yHigh = max(yHigh, v) } }
            for row in 0..<(sh / 2) { for x in 0..<(sw / 2 * 2) { let v = Int(cp[row * cbpr + x]); cLow = min(cLow, v); cHigh = max(cHigh, v) } }
            return (yLow...yHigh, cLow...cHigh)
        }
        return nil
    }
    /// 독립 기준(프레임끼리의 비교가 아니다): 기준 프레임의 모든 화소 — 끝 행·열 포함 — 가 원본 영상의 밝기·색차로 인코딩됐는가.
    /// 생성 재료는 화면 전체를 덮는 단색 무채색 영상이어야 한다(무채색이라 원본의 색 행렬 추정과 무관하다).
    static func judgeBackground(_ p: Planes, source: (y: ClosedRange<Int>, c: ClosedRange<Int>)?, _ report: Report) {
        guard let source, source.y.count <= 3, source.c.lowerBound >= 126, source.c.upperBound <= 130 else {
            report.check("export.backgroundMatchesSource", false, "source frame unreadable or not a uniform achromatic plate: \(String(describing: source))"); return
        }
        var off = 0, x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x, ci = (y / 2) * w + 2 * (x / 2)
            let luma = Int(p.y[i]), cLow = Int(min(p.c[ci], p.c[ci + 1])), cHigh = Int(max(p.c[ci], p.c[ci + 1]))
            let dy = max(source.y.lowerBound - luma, luma - source.y.upperBound)
            let dc = max(source.c.lowerBound - cLow, cHigh - source.c.upperBound)
            if dy > clearTolerance || dc > clearTolerance { off += 1; x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
        } }
        report.check("export.backgroundMatchesSource", off == 0,
                     "source luma \(source.y) chroma \(source.c); frame \(frames[0]) pixels beyond ±\(clearTolerance): \(off)" + (off > 0 ? ", within x \(x0)...\(x1) y \(y0)...\(y1)" : ""))
    }
    static func compare(_ captures: [Int: [Captured]], _ planes: [Int: Planes], _ report: Report) {
        guard let background = planes[frames[0]] else { return }
        // 기준 프레임(스펙트럼 전)은 단색 영상이어야 한다 — 그 뒤 프레임의 "바뀐 화소"를 이 프레임과 견준다
        let low = background.y.min() ?? 0, high = background.y.max() ?? 255
        report.check("export.referenceFrameUniform", Int(high) - Int(low) <= clearTolerance, "frame \(frames[0]) luma \(low)...\(high)")
        for k in frames {
            guard let layers = captures[k], let p = planes[k] else { report.check("frame\(k).compared", false, "missing capture or frame"); continue }
            let e = measure(k, layers, p, background: background)
            report.evidence.append(e)
            judge(e, layers, report)
        }
    }
    static func judge(_ e: FrameEvidence, _ layers: [Captured], _ report: Report) {
        let k = e.frame, spectra = layers.filter { $0.kind == "spectrum" }
        let expectSpectrum = spectrumRange.contains(k), expectSubtitle = subtitleRange.contains(k)
        report.check("frame\(k).visibilityTiming", spectra.count == (expectSpectrum ? 2 : 0) && (e.exportChanged > 0) == !layers.isEmpty,
                     "preview layers \(e.previewLayers), export pixels changed from frame \(frames[0]): \(e.exportChanged)")
        report.check("frame\(k).transparentBackground", e.clear.total > 1000 && e.clear.fraction >= 0.99, describe(e.clear))
        guard !layers.isEmpty else { return }
        let near = e.previewBounds.count == 4 && e.exportBounds.count == 4 && zip(e.previewBounds, e.exportBounds).allSatisfy { abs($0 - $1) <= 8 }
        report.check("frame\(k).bounds", near, "preview \(e.previewBounds) export \(e.exportBounds)")
        for (i, c) in layers.enumerated() {
            let t = e.layerTallies[i]
            report.check("frame\(k).layer\(i).\(c.kind)Color", t.total >= 500 && t.fraction >= 0.98, "rect \(e.rects[i]) opacity \(c.opacity): \(describe(t))")
        }
        report.check("frame\(k).layersOpaque", layers.allSatisfy { $0.opacity == 1 }, "\(e.opacities)")
        if k == 20 {   // 무음: 두 층 모두 두께(16 px)만큼의 점 줄. 칠해진 행 수로 본다(자른 그림의 높이는 증거로만 적는다)
            report.check("frame\(k).zeroHeightDots", spectra.count == 2 && spectra.allSatisfy { abs($0.paintedRows - 16) <= 1 },
                         "painted rows \(spectra.map(\.paintedRows)), cropped heights \(spectra.map(\.height))")
        }
        if k == 34 || k == 38 {   // 막대: 겹친 곳은 위 층의 색
            report.check("frame\(k).overlapOrder", e.overlap.total >= 500 && e.overlap.fraction >= 0.98, describe(e.overlap))
            report.check("frame\(k).barsTallerThanDots", spectra.allSatisfy { $0.height > 32 }, "heights \(spectra.map(\.height))")
        }
        if expectSubtitle {
            let covers = layers.last?.kind == "subtitle" && spectra.contains { s in
                guard let sub = layers.last else { return false }
                return sub.x < s.x + s.width && s.x < sub.x + sub.width && sub.y < s.y + s.height && s.y < sub.y + sub.height
            }
            report.check("frame\(k).subtitleOverSpectrum", covers, "subtitle is the top captured layer and its rect meets a spectrum rect")
        }
    }
}
#endif
