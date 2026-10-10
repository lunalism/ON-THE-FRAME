#if DEBUG
import AppKit
import AVFoundation
import CoreImage
import OnTheFrameEngine

/// A-010 프리뷰 프레임 0 불일치 진단(Debug 전용, 일반 화면에 없음). `open -n -W -a OnTheFrame.app <폴더> --args -OTFLayerDiag`.
/// 원래 실패한 섞인 타임라인을 앱에 올리고(일반 재구성 경로: 새 AVPlayerItem → 교체 → 재생 헤드 0 정밀 탐색), 첫 탐색이 끝난 뒤
/// 정해진 시간(1.5초) 동안 두 가지를 따로 기록한다.
/// - 비디오 출력(AVPlayerItemVideoOutput, 새 항목에 교체 전 붙임): 시각 0의 새 버퍼마다(처음 것 포함, 버리지 않음)
/// - 앱 화면 레이어(AVPlayerLayer.displayedPixelBuffer, 일시정지 상태에서만): 표시 버퍼가 바뀔 때마다
/// 프레임은 <폴더>/layerdiag/에 BGRA로 두고 `otf-dev verify-layer`가 화면 코드로 판정한다. 제품 동작에는 지연을 넣지 않는다.
@MainActor
enum LayerDiagSelfTest {
    struct Entry: Codable { let cycle: Int; let kind: String; let tMs: Int; let displayTime: String?; let file: String; let fingerprint: UInt64; let readyForDisplay: Bool? }
    struct Manifest: Codable { var entries: [Entry]; var notes: [String] }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        let src = folder.appendingPathComponent("sources"), out = folder.appendingPathComponent("layerdiag")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var m = Manifest(entries: [], notes: [])
        NSApp.activate()
        _ = await waitUntil(5) { s.editorWindow != nil }
        s.editorWindow?.makeKeyAndOrderFront(nil)
        let files = ["otf-N2997.mp4", "otf-P25.mp4", "otf-VFR.mp4", "otf-F23976.mp4", "otf-H5994.mov"]
        s.importFiles(files.map { src.appendingPathComponent($0) })
        _ = await waitUntil(60) { s.assets.count == 5 && s.importing == 0 }
        let by = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.name, $0) })
        guard files.allSatisfy({ by[$0] != nil }) else { m.notes.append("import failed"); return finish(folder, m) }
        let n = by["otf-N2997.mp4"]!, p = by["otf-P25.mp4"]!, v = by["otf-VFR.mp4"]!, f = by["otf-F23976.mp4"]!, h = by["otf-H5994.mov"]!
        // 원래 실패한 테스트와 같은 편집
        var t = Timeline().registering(n).registering(p).registering(v).registering(f).registering(h)
        do {
            t = try t.inserting(media: p.id).inserting(media: n.id).inserting(media: v.id).inserting(media: f.id).inserting(media: h.id)
            t = try t.trimmingStart(clip: t.clips[0].id, by: 13)
            t = try t.trimmingEnd(clip: t.clips[0].id, by: -20)
            t = try t.splitting(clip: t.clips[1].id, atFrame: t.clips[1].start + 45)
            t = try t.trimmingStart(clip: t.clips[2].id, by: 7)
            t = try t.splitting(clip: t.clips[3].id, atFrame: t.clips[3].start + 66)
            t = try t.moving(clip: t.clips[4].id, toIndex: 1)
            t = try t.trimmingStart(clip: t.clips[6].id, by: 9)
            t = try t.lifting(clip: t.clips[6].id)
        } catch { m.notes.append("timeline \(error)"); return finish(folder, m) }
        guard let layer = findPlayerLayer(s.editorWindow?.contentView) else { m.notes.append("no player layer"); return finish(folder, m) }
        let zero = CMTime(value: 0, timescale: 30)
        let ci = CIContext()

        for cycle in 0..<3 {
            var attached: (AVPlayerItem, AVPlayerItemVideoOutput)?
            s.itemCreatedHookForTest = { item, _ in
                let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(o); attached = (item, o)
            }
            s.seek(to: 0)
            s.loadTimelineForTest(t)   // 새 항목 → 교체 → 재생 헤드 0 정밀 탐색(일반 경로)
            let applied = await waitUntil(20) { s.appliedGeneration == s.generation && attached != nil && s.player.currentItem === attached?.0 }
            s.itemCreatedHookForTest = nil
            guard applied, let (_, o) = attached else { m.notes.append("cycle \(cycle) not applied"); continue }
            let start = Date()
            var lastLayerFP: UInt64? = nil, k = 0
            while Date().timeIntervalSince(start) < 1.5 {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if o.hasNewPixelBuffer(forItemTime: zero) {
                    var shown = CMTime.invalid
                    if let pb = o.copyPixelBuffer(forItemTime: zero, itemTimeForDisplay: &shown), let (file, fp) = save(pb, ci, out, "c\(cycle)-out-\(k)") {
                        m.entries.append(Entry(cycle: cycle, kind: "output", tMs: ms, displayTime: shown.isNumeric ? "\(shown.value)/\(shown.timescale)" : "invalid",
                                               file: file, fingerprint: fp, readyForDisplay: nil)); k += 1
                    }
                }
                if let pb = layer.displayedPixelBuffer() {
                    let fp = quickFP(pb)
                    if fp != lastLayerFP, let (file, sfp) = save(pb, ci, out, "c\(cycle)-layer-\(k)") {
                        lastLayerFP = fp
                        m.entries.append(Entry(cycle: cycle, kind: "layer", tMs: ms, displayTime: nil, file: file, fingerprint: sfp, readyForDisplay: layer.isReadyForDisplay)); k += 1
                    }
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if !m.entries.contains(where: { $0.cycle == cycle && $0.kind == "layer" }) { m.notes.append("cycle \(cycle): layer displayedPixelBuffer nil") }
        }
        finish(folder, m)
    }

    static func findPlayerLayer(_ v: NSView?) -> AVPlayerLayer? {
        guard let v else { return nil }
        if let p = v as? PlayerNSView { return p.playerLayer }
        for sub in v.subviews { if let l = findPlayerLayer(sub) { return l } }
        return nil
    }
    static func quickFP(_ pb: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var x: UInt64 = 0xcbf29ce484222325
        let planes = max(1, CVPixelBufferGetPlaneCount(pb))
        for pl in 0..<planes {
            let isPlanar = CVPixelBufferGetPlaneCount(pb) > 0
            guard let base = (isPlanar ? CVPixelBufferGetBaseAddressOfPlane(pb, pl) : CVPixelBufferGetBaseAddress(pb))?.assumingMemoryBound(to: UInt8.self) else { continue }
            let h = isPlanar ? CVPixelBufferGetHeightOfPlane(pb, pl) : CVPixelBufferGetHeight(pb)
            let bpr = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(pb, pl) : CVPixelBufferGetBytesPerRow(pb)
            for y in stride(from: 0, to: h, by: 16) { for c in stride(from: 0, to: bpr, by: 64) { x = (x ^ UInt64(base[y * bpr + c])) &* 0x100000001b3 } }
        }
        return x
    }
    /// 1920×1080 BGRA로 바꿔(필요하면 Core Image) 원시 파일로 둔다
    static func save(_ pb: CVPixelBuffer, _ ci: CIContext, _ dir: URL, _ name: String) -> (String, UInt64)? {
        var dst: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &dst)
        guard let dst else { return nil }
        var img = CIImage(cvPixelBuffer: pb)
        let sx = 1920 / img.extent.width, sy = 1080 / img.extent.height
        if abs(sx - 1) > 1e-6 || abs(sy - 1) > 1e-6 { img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy)) }
        ci.render(img, to: dst)
        CVPixelBufferLockBaseAddress(dst, .readOnly); defer { CVPixelBufferUnlockBaseAddress(dst, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(dst), base = CVPixelBufferGetBaseAddress(dst)!
        var d = Data(count: 1920 * 1080 * 4)
        d.withUnsafeMutableBytes { m in for y in 0..<1080 { memcpy(m.baseAddress! + y * 1920 * 4, base + y * bpr, 1920 * 4) } }
        let file = name + ".bgra"
        guard (try? d.write(to: dir.appendingPathComponent(file))) != nil else { return nil }
        return (file, quickFP(pb))
    }
    static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 5_000_000) }
        return cond()
    }
    static func finish(_ folder: URL, _ m: Manifest) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(m) { try? d.write(to: folder.appendingPathComponent("layer-manifest.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
