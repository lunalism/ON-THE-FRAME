#if DEBUG
import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import OnTheFrameEngine
import UniformTypeIdentifiers

/// SP-EXPORT-E4D-G1 (DEBUG only): file and media input/output for the full Preview parity. Read-only on sources;
/// writes only inside the run folder (results, generated-fixture evidence). Never writes next to source media.
enum FullPreviewParityIO {
    static func sha256(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "unreadable" }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: colour declarations

    /// Track declaration from the format description. Each property is read on its own; the range is only the explicit
    /// kCMFormatDescriptionExtension_FullRangeVideo value (true or false). Its absence means "range not declared", whatever other
    /// colour metadata exists (G1 correction, owner decision 4).
    static func trackDeclaration(_ track: AVAssetTrack, origin: String) async -> ColorDeclaration {
        var d = ColorDeclaration(primaries: nil, transfer: nil, matrix: nil, fullRange: nil, origin: origin)
        guard let desc = try? await track.load(.formatDescriptions).first else { return d }
        let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] ?? [:]
        d.primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        d.transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        d.matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        if let full = ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool { d.fullRange = full }
        return d
    }
    /// Decoded-buffer attachments (range is not taken from the buffer: the reader is asked for video range).
    static func bufferDeclaration(_ pb: CVPixelBuffer, origin: String) -> ColorDeclaration {
        func att(_ k: CFString) -> String? { CVBufferCopyAttachment(pb, k, nil) as? String }
        return ColorDeclaration(primaries: att(kCVImageBufferColorPrimariesKey), transfer: att(kCVImageBufferTransferFunctionKey),
                                matrix: att(kCVImageBufferYCbCrMatrixKey), fullRange: nil, origin: origin)
    }

    // MARK: decoding

    struct Decoded { var frames: [Int: NativeFrame]; let interpretation: DeclaredInterpretation; let exactTimes: Set<Int> }

    /// Decodes the wanted frame indices (presentation time exactly k/30) as 8-bit Y'CbCr, chroma repeated to full size. The reader
    /// is asked for kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ('420v'); the decoded samples are therefore video range by that
    /// documented pixel format (a conversion property, not a statement about the source's declaration). Each frame carries the
    /// conversion declaration (declared primaries/transfer/matrix + decoded range) or, if those are not all declared, only what is known.
    static func decode(_ url: URL, frames wanted: Set<Int>, origin: String) async throws -> Decoded {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw IOError.noVideo(url.lastPathComponent) }
        let trackDecl = await trackDeclaration(track, origin: "\(origin) track")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? IOError.reader(url.lastPathComponent) }
        var out: [Int: NativeFrame] = [:], exact = Set<Int>()
        var bufferDecl = ColorDeclaration(primaries: nil, transfer: nil, matrix: nil, fullRange: nil, origin: "\(origin) decoded buffer")
        var sawBuffer = false
        while let sample = output.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            if !sawBuffer { bufferDecl = bufferDeclaration(pb, origin: "\(origin) decoded buffer"); sawBuffer = true }
            let k = Int((t.seconds * 30).rounded())
            guard wanted.contains(k), out[k] == nil else { continue }
            if t.value * 30 == CMTimeValue(k) * CMTimeValue(t.timescale) { exact.insert(k) }
            out[k] = planes(pb, declaration: bufferDecl)
        }
        let interp = DeclaredInterpretation.resolve(track: trackDecl, buffer: bufferDecl, decodedFullRange: false, decodedPixelFormat: "420v (requested, video range)")
        // Without a conversion the frame keeps only what the track declares (no decoder-default fill-in); the 420v range is the
        // decoded format's range, recorded as such.
        let colourDecl = interp.conversion ?? ColorDeclaration(primaries: trackDecl.primaries, transfer: trackDecl.transfer, matrix: trackDecl.matrix,
                                                               fullRange: false, origin: "\(origin) decoded 420v (track declaration incomplete; no buffer fill-in)")
        for (k, f) in out { out[k] = NativeFrame(y: f.y, cb: f.cb, cr: f.cr, declaration: colourDecl) }
        return Decoded(frames: out, interpretation: interp, exactTimes: exact)
    }

    static func planes(_ pb: CVPixelBuffer, declaration: ColorDeclaration) -> NativeFrame {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var y = ParityPlane(width: w, height: h), cb = y, cr = y
        guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
              let cbase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else {
            return NativeFrame(y: y, cb: cb, cr: cr, declaration: declaration)
        }
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for row in 0..<h {
            let yr = yb + row * ybpr, cr0 = cbase + (row / 2) * cbpr
            for x in 0..<w {
                let k = row * w + x
                y.data[k] = Float(yr[x])
                cb.data[k] = Float(cr0[(x / 2) * 2]); cr.data[k] = Float(cr0[(x / 2) * 2 + 1])
            }
        }
        return NativeFrame(y: y, cb: cb, cr: cr, declaration: declaration)
    }

    // MARK: plan inspection

    /// Number of layer instructions active at frame k in the plan's video composition (the CompositionPlanner adds only visible layers).
    static func activeLayers(_ plan: PlannedComposition, frame k: Int) -> Int {
        let t = CMTime(value: CMTimeValue(k), timescale: 30)
        for ins in plan.videoComposition.instructions where CMTimeRangeContainsTime(ins.timeRange, time: t) {
            return (ins as? AVVideoCompositionInstruction)?.layerInstructions.count ?? -1
        }
        return 0
    }

    // MARK: evidence (generated fixtures only)

    static func savePNG(_ c: PreviewCrop, _ url: URL) {
        let w = c.r.width, h = c.r.height
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for k in 0..<(w * h) {
            bytes[k * 4] = UInt8(max(0, min(255, c.r.data[k].rounded()))); bytes[k * 4 + 1] = UInt8(max(0, min(255, c.g.data[k].rounded())))
            bytes[k * 4 + 2] = UInt8(max(0, min(255, c.b.data[k].rounded())))
        }
        writePNG(bytes, w: w, h: h, url)
    }
    static func savePNG(_ f: NativeFrame, _ url: URL) {
        guard let m = f.declaration.matrix else { return }
        let w = f.width, h = f.height
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for k in 0..<(w * h) {
            guard let v = ColorMath.rgb(y: Double(f.y.data[k]), cb: Double(f.cb.data[k]), cr: Double(f.cr.data[k]), matrix: m, fullRange: false) else { continue }
            bytes[k * 4] = UInt8((v.r * 255).rounded()); bytes[k * 4 + 1] = UInt8((v.g * 255).rounded()); bytes[k * 4 + 2] = UInt8((v.b * 255).rounded())
        }
        writePNG(bytes, w: w, h: h, url)
    }
    static func writePNG(_ rgba: [UInt8], w: Int, h: Int, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
    }

    /// ROI of one frame for the cross-run conformance (generated fixtures only): planar export Y'CbCr and calibrated preview R'G'B'.
    static func saveROI(folder: URL, frame k: Int, export f: NativeFrame, roi: CGRect, preview: PreviewCrop?) throws -> [String: Int] {
        let x0 = Int(roi.minX.rounded()), y0 = Int(roi.minY.rounded()), w = Int(roi.width.rounded()), h = Int(roi.height.rounded())
        var bytes = [UInt8](repeating: 0, count: 3 * w * h)
        for (p, plane) in [f.y, f.cb, f.cr].enumerated() { for y in 0..<h { for x in 0..<w {
            bytes[p * w * h + y * w + x] = UInt8(max(0, min(255, plane[min(f.width - 1, x0 + x), min(f.height - 1, y0 + y)].rounded())))
        } } }
        try Data(bytes).write(to: folder.appendingPathComponent("roi-\(k)-export.bin"))
        var pw = 0, ph = 0
        if let c = preview {
            let (cx0, cy0) = c.mapping.crop(roi.minX, roi.minY), (cx1, cy1) = c.mapping.crop(roi.maxX, roi.maxY)
            let ix = Int(cx0.rounded(.up)), iy = Int(cy0.rounded(.up))
            pw = max(0, min(c.r.width, Int(cx1.rounded(.down))) - ix); ph = max(0, min(c.r.height, Int(cy1.rounded(.down))) - iy)
            var pbytes = [UInt8](repeating: 0, count: 3 * pw * ph)
            for (p, plane) in [c.r, c.g, c.b].enumerated() { for y in 0..<ph { for x in 0..<pw {
                pbytes[p * pw * ph + y * pw + x] = UInt8(max(0, min(255, plane[ix + x, iy + y].rounded())))
            } } }
            try Data(pbytes).write(to: folder.appendingPathComponent("roi-\(k)-preview.bin"))
        }
        return ["w": w, "h": h, "pw": pw, "ph": ph]
    }
    static func loadROI(folder: URL, frame k: Int, dims: [String: Int]) -> ROIPixels? {
        guard let w = dims["w"], let h = dims["h"], let e = try? Data(contentsOf: folder.appendingPathComponent("roi-\(k)-export.bin")), e.count == 3 * w * h else { return nil }
        let pw = dims["pw"] ?? 0, ph = dims["ph"] ?? 0
        let p = pw > 0 ? (try? Data(contentsOf: folder.appendingPathComponent("roi-\(k)-preview.bin"))).map { [UInt8]($0) } : nil
        return ROIPixels(width: w, height: h, exportYCbCr: [UInt8](e), previewRGB: p, previewWidth: pw, previewHeight: ph)
    }

    enum IOError: Error { case noVideo(String), reader(String) }
}
#endif
