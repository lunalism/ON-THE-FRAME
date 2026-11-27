import CoreImage
import CoreVideo
import Foundation

/// SP-EXPORT-E4D-COLOR-S1-126 — EXPERIMENTAL, NOT CONNECTED. Nothing in Preview, Export, SubtitleExport or CompositionPlanner calls this.
///
/// Source-aware SDR normalization to a BT.709-tagged 1920×1080 420v buffer, using the Core Image configuration measured in tasks
/// 122–124 ("Case B"):
/// - source colour space = `CVImageBufferCreateColorSpaceFromAttachments` of the DECLARED source tags (track declaration, not monitor ICC)
/// - destination colour space = the same API applied to BT.709 tags (Apple "HDTV" profile)
/// - working space = extended linear sRGB (BT.709 primaries, D65, linear); scaling, layer mixing and overlay source-over happen there
/// - render with an explicit destination colour space; the destination buffer carries BT.709 primaries/transfer/matrix attachments
///
/// Transfer semantics (EXPERIMENTAL, owner decision D2 open): both Apple video profiles use a γ ≈ 1.961 curve, so this follows Apple's
/// video viewing convention. It is NOT the formal BT.709 OETF; strict-OETF interoperability has not been validated.
/// Supported declarations (S1 only): 8-bit video range; primaries BT.709 / SMPTE-C / EBU 3213; transfer BT.709; matrix BT.709 / BT.601.
/// Missing, ambiguous, conflicting or full-range declarations are rejected — no declaration is invented.
struct SourceColorDeclaration: Hashable, Sendable {
    enum Primaries: String, Sendable { case bt709 = "ITU_R_709_2", smpteC = "SMPTE_C", ebu3213 = "EBU_3213" }
    enum Transfer: String, Sendable { case bt709 = "ITU_R_709_2" }
    enum Matrix: String, Sendable { case bt709 = "ITU_R_709_2", bt601 = "ITU_R_601_4" }
    let primaries: Primaries
    let transfer: Transfer
    let matrix: Matrix

    /// From a track's explicit format-description declaration. `fullRange` must be explicitly `false`.
    static func fromTrack(primaries: String?, transfer: String?, matrix: String?, fullRange: Bool?) throws -> SourceColorDeclaration {
        guard let primaries else { throw SourceColorNormalizerError.missingDeclaration("primaries") }
        guard let transfer else { throw SourceColorNormalizerError.missingDeclaration("transfer") }
        guard let matrix else { throw SourceColorNormalizerError.missingDeclaration("matrix") }
        guard let fullRange else { throw SourceColorNormalizerError.missingDeclaration("range") }
        if fullRange { throw SourceColorNormalizerError.fullRangeUnsupported }
        guard let p = Primaries(rawValue: primaries) else { throw SourceColorNormalizerError.unsupportedDeclaration("primaries \(primaries)") }
        guard let t = Transfer(rawValue: transfer) else { throw SourceColorNormalizerError.unsupportedDeclaration("transfer \(transfer)") }
        guard let m = Matrix(rawValue: matrix) else { throw SourceColorNormalizerError.unsupportedDeclaration("matrix \(matrix)") }
        return SourceColorDeclaration(primaries: p, transfer: t, matrix: m)
    }

    var attachments: [String: String] {
        [kCVImageBufferColorPrimariesKey as String: primaries.rawValue, kCVImageBufferTransferFunctionKey as String: transfer.rawValue,
         kCVImageBufferYCbCrMatrixKey as String: matrix.rawValue]
    }
    static let bt709 = SourceColorDeclaration(primaries: .bt709, transfer: .bt709, matrix: .bt709)
}

enum SourceColorNormalizerError: Error, Equatable {
    case missingDeclaration(String)
    case unsupportedDeclaration(String)
    case fullRangeUnsupported
    case conflictingBufferMatrix(declared: String, buffer: String)
    case unsupportedPixelFormat(OSType)
    case colorSpaceUnavailable(String)
    case invalidLayer(String)
    case bufferAllocationFailed
}

/// One opaque video layer: a decoded 420v source frame, its declaration, its placement in output pixels (top-left origin, like
/// CompositionPlanner.layerTransform) and an opacity in [0, 1] (1 = source-over, otherwise a linear mix inside the layer's extent).
struct NormalizerLayer {
    let pixelBuffer: CVPixelBuffer
    let declaration: SourceColorDeclaration
    let transform: CGAffineTransform
    let opacity: Double
}

/// Premultiplied 8-bit RGBA raster in sRGB (the form produced by the subtitle/Spectrum renderers). Memory row 0 is the TOP row
/// (verified by readback in task 124). Composited source-over in the linear working space (owner decision D3 open).
struct PremultipliedSRGBOverlay {
    let data: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

struct NormalizationDiagnostics: Equatable, Sendable {
    let layerDeclarations: [SourceColorDeclaration]
    let sourceColorSpaces: [String]
    let destinationColorSpace: String
    let workingColorSpace: String
    let transferConvention: String
    let outputAttachments: [String: String]
    let overlayComposited: Bool
}

final class SourceColorNormalizer {
    static let outputWidth = 1920, outputHeight = 1080
    static let transferConvention = "EXPERIMENTAL: Apple video convention (Composite NTSC / HDTV profiles, gamma ≈ 1.961); not the formal BT.709 OETF"
    private let context: CIContext
    private let workingSpace: CGColorSpace
    let destinationSpace: CGColorSpace
    private var spaces: [SourceColorDeclaration: CGColorSpace] = [:]

    init() throws {
        guard let w = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw SourceColorNormalizerError.colorSpaceUnavailable("extendedLinearSRGB") }
        workingSpace = w
        context = CIContext(options: [.workingColorSpace: w, .cacheIntermediates: false])
        destinationSpace = try Self.makeSpace(.bt709)
    }

    private static func makeSpace(_ d: SourceColorDeclaration) throws -> CGColorSpace {
        guard let cs = CVImageBufferCreateColorSpaceFromAttachments(d.attachments as CFDictionary)?.takeRetainedValue() else {
            throw SourceColorNormalizerError.colorSpaceUnavailable("\(d)")
        }
        return cs
    }

    func colorSpace(for d: SourceColorDeclaration) throws -> CGColorSpace {
        if let cs = spaces[d] { return cs }
        let cs = try Self.makeSpace(d); spaces[d] = cs; return cs
    }

    /// Renders layers (bottom first) over black, then the optional overlay, into `destination` (or a new 1920×1080 420v IOSurface buffer).
    func render(layers: [NormalizerLayer], overlay: PremultipliedSRGBOverlay? = nil, into destination: CVPixelBuffer? = nil) throws -> (CVPixelBuffer, NormalizationDiagnostics) {
        let w = Self.outputWidth, h = Self.outputHeight, full = CGRect(x: 0, y: 0, width: w, height: h)
        var image = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: full)
        var names: [String] = []
        for layer in layers {
            let pb = layer.pixelBuffer
            guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
                throw SourceColorNormalizerError.unsupportedPixelFormat(CVPixelBufferGetPixelFormatType(pb))
            }
            guard layer.opacity >= 0, layer.opacity <= 1 else { throw SourceColorNormalizerError.invalidLayer("opacity \(layer.opacity)") }
            // Core Image decodes Y'CbCr with the buffer's matrix attachment; it must agree with the declaration (never rewritten here).
            var mode = CVAttachmentMode.shouldPropagate
            let bufferMatrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, &mode) as? String
            guard bufferMatrix == layer.declaration.matrix.rawValue else {
                throw SourceColorNormalizerError.conflictingBufferMatrix(declared: layer.declaration.matrix.rawValue, buffer: bufferMatrix ?? "missing")
            }
            let space = try colorSpace(for: layer.declaration)
            names.append("\(space)")
            // CompositionPlanner transforms use a top-left origin; Core Image uses bottom-left: flip, transform, flip back.
            let srcH = CGFloat(CVPixelBufferGetHeight(pb))
            let toTopLeft = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -srcH)
            let toBottomLeft = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(h))
            let placed = CIImage(cvPixelBuffer: pb, options: [.colorSpace: space])
                .transformed(by: toTopLeft.concatenating(layer.transform).concatenating(toBottomLeft))
            if layer.opacity >= 1 { image = placed.composited(over: image) }
            else if layer.opacity > 0 {
                let mixed = image.cropped(to: placed.extent).applyingFilter("CIDissolveTransition",
                                                                            parameters: ["inputTargetImage": placed, "inputTime": layer.opacity])
                image = mixed.cropped(to: placed.extent).composited(over: image)
            }
        }
        var overlayDone = false
        if let o = overlay {
            guard o.width == w, o.height == h, o.bytesPerRow >= w * 4, o.data.count >= o.bytesPerRow * h else {
                throw SourceColorNormalizerError.invalidLayer("overlay size \(o.width)x\(o.height)")
            }
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw SourceColorNormalizerError.colorSpaceUnavailable("sRGB") }
            let ov = CIImage(bitmapData: o.data, bytesPerRow: o.bytesPerRow, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: srgb)
            image = ov.composited(over: image); overlayDone = true
        }
        let out: CVPixelBuffer
        if let destination {
            guard CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  CVPixelBufferGetWidth(destination) == w, CVPixelBufferGetHeight(destination) == h else {
                throw SourceColorNormalizerError.unsupportedPixelFormat(CVPixelBufferGetPixelFormatType(destination))
            }
            out = destination
        } else {
            var pb: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      [kCVPixelBufferIOSurfacePropertiesKey: [String: Int]()] as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
                throw SourceColorNormalizerError.bufferAllocationFailed
            }
            out = pb
        }
        for (k, v) in SourceColorDeclaration.bt709.attachments { CVBufferSetAttachment(out, k as CFString, v as CFString, .shouldPropagate) }
        context.render(image, to: out, bounds: full, colorSpace: destinationSpace)
        let diag = NormalizationDiagnostics(layerDeclarations: layers.map(\.declaration), sourceColorSpaces: names, destinationColorSpace: "\(destinationSpace)",
                                            workingColorSpace: "\(workingSpace)", transferConvention: Self.transferConvention,
                                            outputAttachments: SourceColorDeclaration.bt709.attachments, overlayComposited: overlayDone)
        return (out, diag)
    }
}
