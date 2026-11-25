import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// SP-EXPORT-E4D-G1 (full Preview parity, phase 1): generated fixtures for the DEBUG full Preview versus Export comparison.
/// Generated only by `otf-dev parity-fixtures <dir>` (gate G2). Nothing here runs in the app or in `ensureAll`.
///
/// Every video draws the frame code in source-normalised cells (the E2 FHD layout scaled to the source size: cells 48/1920 wide,
/// pitch 56/1920, left 40/1920; source-ID row at y 100/1080 with 8 bits, frame row at y 170/1080 with 16 bits; bit 1 = white, 0 = black).
/// The app side (`FullPreviewParityLayout`) repeats these constants; the layout version is `ParityFixtures.layoutVersion`.
/// Colours below are the RGB values written into the BGRA buffers. They are NOT the ground truth: the parity code always measures the
/// decoded source file and the declared metadata of the written track.
public enum ParityFixtures {
    public static let layoutVersion = 1
    public static let fps: Int32 = 30

    /// Colour declaration written into the track (nil = untagged: no colour properties).
    public struct Tagging: Sendable {
        public let primaries: String, transfer: String, matrix: String
        public static let bt709 = Tagging(primaries: AVVideoColorPrimaries_ITU_R_709_2, transfer: AVVideoTransferFunction_ITU_R_709_2, matrix: AVVideoYCbCrMatrix_ITU_R_709_2)
        public static let bt601 = Tagging(primaries: AVVideoColorPrimaries_SMPTE_C, transfer: AVVideoTransferFunction_ITU_R_709_2, matrix: AVVideoYCbCrMatrix_ITU_R_601_4)
    }
    public enum Content: Sendable { case patches, resolution, uniform(UInt8, UInt8, UInt8) }
    public struct Spec: Sendable {
        public let file: String, width: Int, height: Int, sourceID: Int, frames: Int, tagging: Tagging?, content: Content
    }
    public static let calibration = Spec(file: "otf-CAL.mp4", width: 1920, height: 1080, sourceID: 0xC1, frames: 30, tagging: .bt709, content: .patches)
    public static let resampling = Spec(file: "otf-RES.mp4", width: 1920, height: 1080, sourceID: 0xC2, frames: 30, tagging: .bt709, content: .resolution)
    /// otf-PAR: additional fixture (otf-TA stays unchanged). Uniform background for overlay validation and Spectrum/subtitle
    /// visibility; frame-coded for identity. Used with `toneFile` (440 Hz) as the Spectrum source.
    public static let scene = Spec(file: "otf-PAR.mp4", width: 1920, height: 1080, sourceID: 0xC3, frames: 120, tagging: .bt709, content: .uniform(80, 80, 80))
    public static let sdUntagged = Spec(file: "otf-SDU.mp4", width: 640, height: 480, sourceID: 0xD1, frames: 30, tagging: nil, content: .patches)
    public static let sd601 = Spec(file: "otf-SD601.mp4", width: 640, height: 480, sourceID: 0xD2, frames: 30, tagging: .bt601, content: .patches)
    public static let hd709 = Spec(file: "otf-HD709.mp4", width: 1920, height: 1080, sourceID: 0xD3, frames: 30, tagging: .bt709, content: .patches)
    public static let hdUntagged = Spec(file: "otf-HDU.mp4", width: 1920, height: 1080, sourceID: 0xD4, frames: 30, tagging: nil, content: .patches)
    public static let videos = [calibration, resampling, scene, sdUntagged, sd601, hd709, hdUntagged]
    public static let toneFile = "otf-tone-5s.wav"

    /// 24 patch colours (RGB 0…255): 11 grey steps, six 75 % primaries/secondaries, seven mid tones. Index order is fixed;
    /// the app side splits it into 16 training and 8 validation patches.
    public static let patchRGB: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (25, 25, 25), (51, 51, 51), (76, 76, 76), (102, 102, 102), (127, 127, 127),
        (153, 153, 153), (178, 178, 178), (204, 204, 204), (229, 229, 229), (255, 255, 255),
        (191, 0, 0), (0, 191, 0), (0, 0, 191), (0, 191, 191), (191, 0, 191), (191, 191, 0),
        (194, 150, 130), (115, 82, 68), (98, 122, 157), (87, 108, 67), (214, 126, 44), (94, 60, 108), (157, 188, 64)]
    /// Patch grid in source-normalised coordinates: 6 columns × 4 rows, cell (240 + 240c, 320 + 180r) of a 1920×1080 frame, 160×140.
    public static func patchRect(_ i: Int, width w: Int, height h: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        let c = i % 6, r = i / 6
        let x0 = Double(240 + 240 * c) / 1920, y0 = Double(320 + 180 * r) / 1080
        return (Int((x0 * Double(w)).rounded()), Int((y0 * Double(h)).rounded()), Int((160.0 / 1920 * Double(w)).rounded()), Int((140.0 / 1080 * Double(h)).rounded()))
    }

    /// Writes all parity fixtures into dir (existing files are kept). Returns the file names.
    @discardableResult
    public static func ensureAll(in dir: URL) async throws -> [String] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for spec in videos { try await DevFixtures.ensure(dir, spec.file) { try await write(spec, to: $0) } }
        try await DevFixtures.ensure(dir, toneFile) { try writeTone($0, seconds: 5, hz: 440, amplitude: 0.25) }
        return videos.map(\.file) + [toneFile]
    }

    // MARK: drawing (BGRA, top-left origin)

    struct Canvas {
        let w: Int, h: Int
        var px: [UInt8]
        init(w: Int, h: Int, fill: (UInt8, UInt8, UInt8)) {
            self.w = w; self.h = h
            px = [UInt8](repeating: 255, count: w * h * 4)
            rect(0, 0, w, h, fill)
        }
        mutating func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ c: (UInt8, UInt8, UInt8)) {
            let x0 = max(0, x), y0 = max(0, y), x1 = min(w, x + rw), y1 = min(h, y + rh)
            guard x0 < x1, y0 < y1 else { return }
            for yy in y0..<y1 { for xx in x0..<x1 { set(xx, yy, c) } }
        }
        mutating func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
            let o = (y * w + x) * 4
            px[o] = c.2; px[o + 1] = c.1; px[o + 2] = c.0; px[o + 3] = 255
        }
    }

    /// Frame code: 8-bit source ID and 16-bit frame number, most significant bit first.
    static func drawCode(_ c: inout Canvas, sourceID: Int, frame: Int) {
        func cell(_ bit: Int, _ row: Double, _ on: Bool) {
            let x = Int(((40.0 + Double(bit) * 56) / 1920 * Double(c.w)).rounded()), y = Int((row / 1080 * Double(c.h)).rounded())
            let cw = Int((48.0 / 1920 * Double(c.w)).rounded()), ch = Int((48.0 / 1080 * Double(c.h)).rounded())
            c.rect(x, y, cw, ch, on ? (255, 255, 255) : (0, 0, 0))
        }
        for b in 0..<8 { cell(b, 100, (sourceID >> (7 - b)) & 1 == 1) }
        for b in 0..<16 { cell(b, 170, (frame >> (15 - b)) & 1 == 1) }
    }

    static func drawPatches(_ c: inout Canvas) {
        for (i, rgb) in patchRGB.enumerated() { let r = patchRect(i, width: c.w, height: c.h); c.rect(r.x, r.y, r.w, r.h, rgb) }
    }

    /// Resampling patterns, each drawn twice (training region on the left half, validation region on the right half, shifted by one pixel).
    /// Rows (1920×1080 coordinates): 1-px vertical lines at phases 0–3; 1-px horizontal lines; 1/2/3-px checkerboards; vertical and
    /// horizontal step edges; 1-px dots; a horizontal ramp. Region rectangles are listed in `resolutionRegions`.
    static func drawResolution(_ c: inout Canvas) {
        for (index, region) in resolutionRegions.enumerated() {
            let shift = region.validation ? 1 : 0
            let x0 = region.x + shift, y0 = region.y
            switch region.kind {
            case "vlines":
                for x in stride(from: x0 + index % 4, to: region.x + region.w, by: 8) { c.rect(x, y0, 1, region.h, (255, 255, 255)) }
            case "hlines":
                for y in stride(from: y0 + index % 4, to: region.y + region.h, by: 8) { c.rect(x0, y, region.w - shift, 1, (255, 255, 255)) }
            case "checker1", "checker2", "checker3":
                let s = Int(String(region.kind.last!))!
                for y in y0..<(region.y + region.h) { for x in x0..<(region.x + region.w) where ((x - x0) / s + (y - y0) / s) % 2 == 0 { c.set(x, y, (255, 255, 255)) } }
            case "vedge":
                c.rect(x0 + region.w / 2, y0, region.w / 2 - shift, region.h, (255, 255, 255))
            case "hedge":
                c.rect(x0, y0 + region.h / 2, region.w - shift, region.h / 2, (255, 255, 255))
            case "dots":
                for y in stride(from: y0 + 2, to: region.y + region.h, by: 6) { for x in stride(from: x0 + 2, to: region.x + region.w, by: 6) { c.set(x, y, (255, 255, 255)) } }
            default:   // "ramp"
                for x in x0..<(region.x + region.w) {
                    let v = UInt8(max(0, min(255, (x - x0) * 255 / max(1, region.w - 1))))
                    c.rect(x, y0, 1, region.h, (v, v, v))
                }
            }
        }
    }
    public struct Region: Sendable { public let kind: String, x: Int, y: Int, w: Int, h: Int, validation: Bool }
    /// Training regions are on the left (x 80…880), validation regions on the right (x 1040…1840); each 800×64 in rows from y 300.
    public static let resolutionRegions: [Region] = {
        let kinds = ["vlines", "hlines", "checker1", "checker2", "checker3", "vedge", "hedge", "dots", "ramp"]
        var out: [Region] = []
        for (row, k) in kinds.enumerated() {
            let y = 300 + row * 80
            out.append(Region(kind: k, x: 80, y: y, w: 800, h: 64, validation: false))
            out.append(Region(kind: k, x: 1040, y: y, w: 800, h: 64, validation: true))
        }
        return out
    }()

    // MARK: writing

    static func write(_ spec: Spec, to url: URL) async throws {
        let wr = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height,
                                       AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: spec.width * spec.height * 12, AVVideoAllowFrameReorderingKey: false]]
        if let t = spec.tagging {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: t.primaries, AVVideoTransferFunctionKey: t.transfer, AVVideoYCbCrMatrixKey: t.matrix]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        wr.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height])
        guard wr.startWriting() else { throw ParityFixtureError.writer(wr.error?.localizedDescription ?? "start") }
        wr.startSession(atSourceTime: .zero)
        var base: Canvas
        switch spec.content {
        case .patches: base = Canvas(w: spec.width, h: spec.height, fill: (60, 60, 60)); drawPatches(&base)
        case .resolution: base = Canvas(w: spec.width, h: spec.height, fill: (0, 0, 0)); drawResolution(&base)
        case .uniform(let r, let g, let b): base = Canvas(w: spec.width, h: spec.height, fill: (r, g, b))
        }
        for f in 0..<spec.frames {
            var c = base
            drawCode(&c, sourceID: spec.sourceID, frame: f)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            let pb = try pixelBuffer(c, tagging: spec.tagging)
            guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps)) else {
                throw ParityFixtureError.writer(wr.error?.localizedDescription ?? "append")
            }
        }
        input.markAsFinished()
        wr.endSession(atSourceTime: CMTime(value: CMTimeValue(spec.frames), timescale: fps))
        await wr.finishWriting()
        guard wr.status == .completed else { throw ParityFixtureError.writer(wr.error?.localizedDescription ?? "finish") }
    }

    static func pixelBuffer(_ c: Canvas, tagging: Tagging?) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, c.w, c.h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        guard let pb = out else { throw ParityFixtureError.writer("pixel buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        if let base = CVPixelBufferGetBaseAddress(pb) {
            c.px.withUnsafeBytes { src in
                for y in 0..<c.h { memcpy(base + y * bpr, src.baseAddress! + y * c.w * 4, c.w * 4) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if let t = tagging {   // the encoder converts BGRA → Y'CbCr with the declared matrix
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, t.primaries as CFString, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, t.transfer as CFString, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, t.matrix as CFString, .shouldPropagate)
        }
        return pb
    }

    /// 48 kHz stereo 16-bit PCM WAV sine (Spectrum source for the overlay scenarios).
    static func writeTone(_ url: URL, seconds: Int, hz: Double, amplitude: Double) throws {
        let rate = 48_000, frames = rate * seconds, channels = 2
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let payload = frames * channels * 2
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + payload)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(payload))
        for i in 0..<frames {
            let s = Int16((sin(2 * Double.pi * hz * Double(i) / Double(rate)) * amplitude * 32767).rounded())
            for _ in 0..<channels { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        }
        try data.write(to: url)
    }

    enum ParityFixtureError: Error { case writer(String) }
}
