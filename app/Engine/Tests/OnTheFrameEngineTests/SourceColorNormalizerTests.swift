import AVFoundation
import CoreVideo
import IOSurface
import XCTest
@testable import OnTheFrameEngine

/// SP-EXPORT-E4D-COLOR-S1-126: tests for the EXPERIMENTAL, unconnected SourceColorNormalizer.
/// Fixture tests run only with OTF_IND_FIXTURES = folder containing the task-117 independent fixtures (SD601.mp4, SD709.mp4);
/// measurements are written to OTF_S1_OUT when set. No tolerance is introduced: I709 must be code-exact (as measured in tasks 122–124);
/// I601 / MIXED / overlay are judged by model DISCRIMINATION (the expected model must be the nearest candidate) and residuals are recorded.
final class SourceColorNormalizerTests: XCTestCase {
    // Task 117 reference codes (code space, video range), patches 0, 5, 10, 11–16.
    static let ref601: [Int: [Double]] = [0: [16, 128, 128], 5: [125, 128, 128], 10: [235, 128, 128], 11: [65, 100, 212], 12: [112, 72, 58],
                                          13: [35, 212, 114], 14: [131, 156, 44], 15: [84, 184, 198], 16: [161, 44, 142]]
    static let ref709: [Int: [Double]] = [0: [16, 128, 128], 5: [125, 128, 128], 10: [235, 128, 128], 11: [51, 109, 212], 12: [133, 63, 52],
                                          13: [28, 212, 120], 14: [145, 147, 44], 15: [63, 193, 204], 16: [168, 44, 136]]
    static let patches = [0, 5, 10, 11, 12, 13, 14, 15, 16]
    static let fit = CGAffineTransform(scaleX: 2.25, y: 2.25).concatenating(CGAffineTransform(translationX: 240, y: 0))   // top-left origin
    static var record: [String: Any] = [:]

    // MARK: fixtures
    struct Source { let frames: [Int: CVPixelBuffer]; let declaration: SourceColorDeclaration; let allPTSExact: Bool; let trackTags: [String: String] }
    func fixtureDir() throws -> URL {
        guard let p = ProcessInfo.processInfo.environment["OTF_IND_FIXTURES"] else { throw XCTSkip("OTF_IND_FIXTURES not set (task-117 fixtures)") }
        return URL(fileURLWithPath: p, isDirectory: true)
    }
    func load(_ name: String) throws -> Source {
        let asset = AVURLAsset(url: try fixtureDir().appendingPathComponent(name))
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let desc = try XCTUnwrap(track.formatDescriptions.first.map { $0 as! CMFormatDescription })
        let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] ?? [:]
        let p = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String, t = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let m = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String, fr = ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool
        let decl = try SourceColorDeclaration.fromTrack(primaries: p, transfer: t, matrix: m, fullRange: fr)
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(o); XCTAssertTrue(reader.startReading())
        var frames: [Int: CVPixelBuffer] = [:], exact = true
        while let sb = o.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb), k = Int((pts.seconds * 30).rounded())
            if pts.value * 30 != CMTimeValue(k) * CMTimeValue(pts.timescale) { exact = false }
            if let pb = CMSampleBufferGetImageBuffer(sb) { frames[k] = pb }
        }
        return Source(frames: frames, declaration: decl, allPTSExact: exact, trackTags: ["p": p ?? "-", "t": t ?? "-", "m": m ?? "-", "range": "\(fr.map { "\($0)" } ?? "-")"])
    }

    // MARK: measurement
    func roi(_ i: Int) -> (Int, Int, Int, Int) {
        let c = i % 6, r = i / 6
        let x = (Double(240 + 240 * c) / 1920 * 640).rounded(), y = (Double(320 + 180 * r) / 1080 * 480).rounded(), w = (160.0 / 1920 * 640).rounded(), h = (140.0 / 1080 * 480).rounded()
        return (Int(ceil(240 + 2.25 * (x + w / 4) + 2)), Int(floor(240 + 2.25 * (x + 3 * w / 4) - 2)), Int(ceil(2.25 * (y + h / 4) + 2)), Int(floor(2.25 * (y + 3 * h / 4) - 2)))
    }
    func mean(_ pb: CVPixelBuffer, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> (v: [Double], sd: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        var s = [0.0, 0.0, 0.0], ss = [0.0, 0.0, 0.0], n = [0.0, 0.0]
        for y in y0..<y1 { for x in x0..<x1 { let v = Double(yb[y * ybpr + x]); s[0] += v; ss[0] += v * v; n[0] += 1 } }
        for y in ((y0 + 1) / 2)..<(y1 / 2) { for x in ((x0 + 1) / 2)..<(x1 / 2) {
            let b = Double(cb[y * cbpr + 2 * x]), r = Double(cb[y * cbpr + 2 * x + 1]); s[1] += b; ss[1] += b * b; s[2] += r; ss[2] += r * r; n[1] += 1 } }
        let m = [s[0] / n[0], s[1] / n[1], s[2] / n[1]]
        let sd = [ss[0] / n[0] - m[0] * m[0], ss[1] / n[1] - m[1] * m[1], ss[2] / n[1] - m[2] * m[2]].map { max(0, $0).squareRoot() }.max()!
        return (m, sd)
    }
    func patchMeans(_ pb: CVPixelBuffer) -> [Int: [Double]] {
        var r: [Int: [Double]] = [:]
        for i in Self.patches { let (x0, x1, y0, y1) = roi(i); r[i] = mean(pb, x0, x1, y0, y1).v }
        return r
    }
    func lumaAt(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> Int {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        return Int(CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)[y * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + x])
    }
    func frameCode(_ pb: CVPixelBuffer) -> (id: Int, frame: Int, margin: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        func bits(_ row: Double, _ count: Int) -> (Int, Int) {
            var v = 0, margin = Int.max
            for b in 0..<count {
                let cx = 240 + (40.0 + Double(b) * 56 + 24) / 1920 * 1440, cy = row + 24
                var s = 0.0, n = 0.0
                for y in Int((cy - 7.2).rounded())...Int((cy + 7.2).rounded()) { for x in Int((cx - 7.2).rounded())...Int((cx + 7.2).rounded()) { s += Double(yb[y * ybpr + x]); n += 1 } }
                let m = (s / n - 16) * 255 / 219; margin = min(margin, Int(abs(m - 128).rounded())); v = (v << 1) | (m > 128 ? 1 : 0)
            }
            return (v, margin)
        }
        let (i, m1) = bits(100, 8), (f, m2) = bits(170, 16)
        return (i, f, min(m1, m2))
    }

    // MARK: independent models (no Core Image)
    static let G = 1.9609375
    static func inv(_ m: [[Double]]) -> [[Double]] {
        let (a, b, c, d, e, f, g, h, i) = (m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2])
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det], [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
                [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
    }
    static func mv(_ m: [[Double]], _ v: [Double]) -> [Double] { (0..<3).map { r in (0..<3).reduce(0) { $0 + m[r][$1] * v[$1] } } }
    static func mm(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] { (0..<3).map { r in (0..<3).map { c in (0..<3).reduce(0) { $0 + a[r][$1] * b[$1][c] } } } }
    static func r2x(_ p: [(Double, Double)]) -> [[Double]] {
        let cols = p.map { [$0.0 / $0.1, 1, (1 - $0.0 - $0.1) / $0.1] }, M = (0..<3).map { r in (0..<3).map { cols[$0][r] } }
        let s = mv(inv(M), [0.3127 / 0.3290, 1, (1 - 0.3127 - 0.3290) / 0.3290]); return (0..<3).map { r in (0..<3).map { M[r][$0] * s[$0] } }
    }
    static let c2709 = mm(inv(r2x([(0.640, 0.330), (0.300, 0.600), (0.150, 0.060)])), r2x([(0.630, 0.340), (0.310, 0.595), (0.155, 0.070)]))
    static let ident: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    static func clip(_ v: Double) -> Double { min(1, max(0, v)) }
    static func ycc2rgb(_ c: [Double], _ kr: Double, _ kb: Double) -> [Double] {
        let y = (c[0] - 16) / 219, pb = (c[1] - 128) / 224, pr = (c[2] - 128) / 224, r = y + 2 * (1 - kr) * pr, b = y + 2 * (1 - kb) * pb
        return [clip(r), clip((y - kr * r - kb * b) / (1 - kr - kb)), clip(b)]
    }
    static func rgb2ycc(_ p: [Double], _ kr: Double, _ kb: Double) -> [Double] {
        let y = kr * p[0] + (1 - kr - kb) * p[1] + kb * p[2]
        return [(16 + 219 * y).rounded(), (128 + 224 * (p[2] - y) / (2 * (1 - kb))).rounded(), (128 + 224 * (p[0] - y) / (2 * (1 - kr))).rounded()]
    }
    static func oetf(_ l: Double) -> Double { l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099 }
    static func oetfInv(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45) }
    static func linear(_ c: [Double], src601: Bool) -> [Double] {   // source code → linear BT.709 RGB (γ1.9609375 decode)
        let rgb = src601 ? ycc2rgb(c, 0.299, 0.114) : ycc2rgb(c, 0.2126, 0.0722)
        return mv(src601 ? c2709 : ident, rgb.map { pow($0, G) })
    }
    static func encode709(_ lin: [Double]) -> [Double] { rgb2ycc(lin.map { pow(clip($0), 1 / G) }, 0.2126, 0.0722) }
    static func candidates601(_ c: [Double]) -> [String: [Double]] {
        let rgb = ycc2rgb(c, 0.299, 0.114)
        return ["A_601_preserved": c, "B_full_gamma1961": encode709(linear(c, src601: true)),
                "B_full_oetf709": rgb2ycc(mv(c2709, rgb.map { pow($0, G) }).map { oetf(clip($0)) }, 0.2126, 0.0722),
                "C_matrix_only": rgb2ycc(rgb, 0.2126, 0.0722), "D_primaries_only": rgb2ycc(mv(c2709, rgb.map { pow($0, G) }).map { pow(clip($0), 1 / G) }, 0.299, 0.114)]
    }
    static func dist(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot() }
    static func srgbEOTF(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    override class func tearDown() {
        if let p = ProcessInfo.processInfo.environment["OTF_S1_OUT"], let d = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: p).appendingPathComponent("s1-measurements.json"))
        }
        super.tearDown()
    }

    // MARK: tests
    func testDeclarationParsingRejectsMissingAmbiguousAndFullRange() throws {
        XCTAssertEqual(try SourceColorDeclaration.fromTrack(primaries: "SMPTE_C", transfer: "ITU_R_709_2", matrix: "ITU_R_601_4", fullRange: false),
                       SourceColorDeclaration(primaries: .smpteC, transfer: .bt709, matrix: .bt601))
        XCTAssertThrowsError(try SourceColorDeclaration.fromTrack(primaries: nil, transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: false)) {
            XCTAssertEqual($0 as? SourceColorNormalizerError, .missingDeclaration("primaries")) }
        XCTAssertThrowsError(try SourceColorDeclaration.fromTrack(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: nil)) {
            XCTAssertEqual($0 as? SourceColorNormalizerError, .missingDeclaration("range")) }
        XCTAssertThrowsError(try SourceColorDeclaration.fromTrack(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: true)) {
            XCTAssertEqual($0 as? SourceColorNormalizerError, .fullRangeUnsupported) }
        XCTAssertThrowsError(try SourceColorDeclaration.fromTrack(primaries: "ITU_R_2020", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: false)) {
            XCTAssertEqual($0 as? SourceColorNormalizerError, .unsupportedDeclaration("primaries ITU_R_2020")) }
        XCTAssertThrowsError(try SourceColorDeclaration.fromTrack(primaries: "ITU_R_709_2", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_709_2", fullRange: false)) {
            XCTAssertEqual($0 as? SourceColorNormalizerError, .unsupportedDeclaration("transfer SMPTE_ST_2084_PQ")) }
    }

    func testConflictingBufferMatrixIsRejected() throws {
        let s = try load("SD601.mp4"); let n = try SourceColorNormalizer()
        XCTAssertThrowsError(try n.render(layers: [NormalizerLayer(pixelBuffer: s.frames[5]!, declaration: .bt709, transform: Self.fit, opacity: 1)])) {
            XCTAssertEqual($0 as? SourceColorNormalizerError, .conflictingBufferMatrix(declared: "ITU_R_709_2", buffer: "ITU_R_601_4")) }
    }

    func testI601ConversionAndI709Identity() throws {
        let s601 = try load("SD601.mp4"), s709 = try load("SD709.mp4"), n = try SourceColorNormalizer()
        XCTAssertEqual(s601.declaration, SourceColorDeclaration(primaries: .smpteC, transfer: .bt709, matrix: .bt601))
        XCTAssertEqual(s709.declaration, .bt709)
        XCTAssertTrue(s601.allPTSExact); XCTAssertTrue(s709.allPTSExact); XCTAssertEqual(s601.frames.count, 30); XCTAssertEqual(s709.frames.count, 30)
        var rec: [String: Any] = ["trackTags601": s601.trackTags, "trackTags709": s709.trackTags]
        // Task 127: model CONSISTENCY (per patch, γ1.961 must be at the minimum distance; ties allowed) is separate from model
        // DISCRIMINATION (aggregate over the predeclared set patches 11–16 × frames 5, 15). No tolerance; no Dictionary-order dependence.
        let model = "B_full_gamma1961"
        var aggregate: [String: Double] = [:], uniqueWins: [String: Int] = [:], nonDiscriminating: [String] = []
        for k in [5, 15] {
            let (o601, d601) = try n.render(layers: [NormalizerLayer(pixelBuffer: s601.frames[k]!, declaration: s601.declaration, transform: Self.fit, opacity: 1)])
            let (o709, _) = try n.render(layers: [NormalizerLayer(pixelBuffer: s709.frames[k]!, declaration: s709.declaration, transform: Self.fit, opacity: 1)])
            // identity, metadata, range, geometry
            XCTAssertEqual(frameCode(o601).id, 0xE1); XCTAssertEqual(frameCode(o601).frame, k)
            XCTAssertEqual(frameCode(o709).id, 0xE2); XCTAssertEqual(frameCode(o709).frame, k)
            for (key, v) in SourceColorDeclaration.bt709.attachments {
                var mode = CVAttachmentMode.shouldPropagate
                XCTAssertEqual(CVBufferCopyAttachment(o601, key as CFString, &mode) as? String, v)
            }
            XCTAssertTrue(d601.transferConvention.hasPrefix("EXPERIMENTAL"))
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(o601), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            XCTAssertEqual(lumaAt(o601, 236, 540), 16); XCTAssertEqual(lumaAt(o601, 244, 540), 68)        // pillarbox black | source background
            XCTAssertEqual(lumaAt(o601, 1683, 540), 16); XCTAssertEqual(lumaAt(o601, 1675, 540), 68)
            let p601 = patchMeans(o601), p709 = patchMeans(o709)
            // I709: code-exact identity (tasks 122–124 measured exact)
            for i in Self.patches { XCTAssertEqual(p709[i]!, Self.ref709[i]!, "I709 patch \(i) frame \(k)") }
            // I601: gray preserved exactly; saturated patches nearest to the γ1.961 full-conversion model
            for i in [0, 5, 10] { XCTAssertEqual(p601[i]!, Self.ref601[i]!, "I601 gray \(i) frame \(k)") }
            var rows: [String: Any] = [:]
            for i in Self.patches {
                let cands = Self.candidates601(Self.ref601[i]!)
                let d = cands.mapValues { Self.dist(p601[i]!, $0) }
                let minDist = d.values.min()!
                let tied = d.filter { $0.value == minDist }.keys.sorted()
                let consistent = d[model]! == minDist
                var status = "GRAY(not in discrimination set)"
                if i >= 11 {
                    XCTAssertTrue(consistent, "I601 patch \(i) frame \(k): γ1.961 distance \(d[model]!) > minimum \(minDist) held by \(tied)")
                    status = !consistent ? "INCONSISTENT" : (tied.count > 1 ? "NON-DISCRIMINATING(tie)" : "UNIQUE")
                    if tied.count > 1 { nonDiscriminating.append("frame\(k)/patch\(i): \(tied)") }
                    for (name, v) in d {
                        aggregate[name, default: 0] += v
                        if name != model { uniqueWins[name, default: 0] += d[model]! < v ? 1 : 0 }
                    }
                }
                rows["\(i)"] = ["out": p601[i]!, "model_gamma1961": cands[model]!, "residual": zip(p601[i]!, cands[model]!).map { $0 - $1 },
                                "predictions": cands, "distances": d, "minDistance": minDist, "tiedAtMinimum": tied, "consistent": consistent, "status": status]
            }
            rec["frame\(k)"] = ["I601": rows, "I709": p709.mapValues { $0 }.reduce(into: [String: [Double]]()) { $0["\($1.key)"] = $1.value }]
        }
        // Aggregate discrimination: γ1.961 total strictly below every alternative AND at least one patch favouring γ1.961 uniquely
        // against each alternative. Anything else is INCONCLUSIVE (fails; never reported as PASS).
        let alternatives = aggregate.keys.filter { $0 != model }.sorted()
        let notBeaten = alternatives.filter { !(aggregate[model]! < aggregate[$0]!) || (uniqueWins[$0] ?? 0) == 0 }
        let verdict = notBeaten.isEmpty ? "IDENTIFIED(gamma1961 within the experimental candidate set; D2 open)" : "INCONCLUSIVE vs \(notBeaten)"
        XCTAssertTrue(notBeaten.isEmpty, "I601 model discrimination \(verdict): aggregate \(aggregate) uniqueWins \(uniqueWins)")
        rec["discrimination"] = ["set": "patches 11-16 x frames 5,15", "aggregateDistance": aggregate, "patchesFavouringGamma1961Uniquely": uniqueWins,
                                 "nonDiscriminatingPatches": nonDiscriminating, "verdict": verdict,
                                 "note": "a tie is non-discriminating, not evidence that gamma1961 and strict BT.709 OETF are equivalent; not an output colour policy"]
        Self.record["I601_I709"] = rec
    }

    func testMixedSourcesNormalizedBeforeLinearBlend() throws {
        let s601 = try load("SD601.mp4"), s709 = try load("SD709.mp4"), n = try SourceColorNormalizer()
        let (a, _) = try n.render(layers: [NormalizerLayer(pixelBuffer: s601.frames[5]!, declaration: s601.declaration, transform: Self.fit, opacity: 1)])
        let (b, _) = try n.render(layers: [NormalizerLayer(pixelBuffer: s709.frames[15]!, declaration: s709.declaration, transform: Self.fit, opacity: 1)])
        let (c, diag) = try n.render(layers: [NormalizerLayer(pixelBuffer: s601.frames[25]!, declaration: s601.declaration, transform: Self.fit, opacity: 1),
                                              NormalizerLayer(pixelBuffer: s709.frames[25]!, declaration: s709.declaration, transform: Self.fit, opacity: 0.5)])
        XCTAssertEqual(frameCode(a).id, 0xE1); XCTAssertEqual(frameCode(a).frame, 5); XCTAssertEqual(frameCode(b).id, 0xE2); XCTAssertEqual(frameCode(b).frame, 15)
        XCTAssertEqual(diag.layerDeclarations.count, 2)
        let pa = patchMeans(a), pb = patchMeans(b), pc = patchMeans(c)
        for i in Self.patches { XCTAssertEqual(pb[i]!, Self.ref709[i]!, "MIXED 709 section patch \(i)") }
        var rows: [String: Any] = [:]
        for i in Self.patches {
            let lin = zip(Self.linear(Self.ref601[i]!, src601: true), Self.linear(Self.ref709[i]!, src601: false)).map { 0.5 * $0 + 0.5 * $1 }
            let linRef = Self.encode709(lin)
            let encMix = zip(Self.encode709(Self.linear(Self.ref601[i]!, src601: true)), Self.ref709[i]!).map { (($0 + $1) / 2).rounded() }
            let dl = Self.dist(pc[i]!, linRef), de = Self.dist(pc[i]!, encMix)
            if i >= 11 && linRef != encMix { XCTAssertLessThan(dl, de, "overlap patch \(i): linear \(linRef) encoded \(encMix) out \(pc[i]!)") }
            rows["\(i)"] = ["section601": pa[i]!, "overlap": pc[i]!, "linearRef": linRef, "encodedMix": encMix, "distLinear": dl, "distEncoded": de]
        }
        Self.record["MIXED"] = rows
    }

    func testPremultipliedSRGBOverlayLinearSourceOver() throws {
        let s709 = try load("SD709.mp4"), n = try SourceColorNormalizer()
        let w = 1920, h = 1080
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        func square(_ x0: Int, _ px: [UInt8]) { for y in 236..<296 { for x in x0..<(x0 + 100) { let o = (y * w + x) * 4; for c in 0..<4 { bytes[o + c] = px[c] } } } }
        square(400, [0, 0, 0, 0]); square(600, [255, 40, 40, 255]); square(800, [20, 60, 128, 128])
        let layer = NormalizerLayer(pixelBuffer: s709.frames[15]!, declaration: s709.declaration, transform: Self.fit, opacity: 1)
        let (base, _) = try n.render(layers: [layer])
        let (with, diag) = try n.render(layers: [layer], overlay: PremultipliedSRGBOverlay(data: Data(bytes), width: w, height: h, bytesPerRow: w * 4))
        XCTAssertTrue(diag.overlayComposited)
        XCTAssertEqual(patchMeans(base), patchMeans(with)); XCTAssertEqual(frameCode(with).frame, 15)
        var rows: [String: Any] = [:]
        for (name, x0, prem, a) in [("T", 400, [0.0, 0, 0], 0.0), ("O", 600, [255.0, 40, 40], 1.0), ("P", 800, [20.0, 60, 128], 128.0 / 255)] {
            let bg = mean(base, x0 + 10, x0 + 90, 246, 286).v, out = mean(with, x0 + 10, x0 + 90, 246, 286)
            var linRef = bg, encRef = bg
            if a > 0 {
                let bgl = Self.ycc2rgb(bg, 0.2126, 0.0722).map { pow($0, Self.G) }, ovl = prem.map { Self.srgbEOTF($0 / 255 / a) }
                linRef = Self.rgb2ycc(zip(ovl, bgl).map { pow(Self.clip(a * $0 + (1 - a) * $1), 1 / Self.G) }, 0.2126, 0.0722)
                let p = prem.map { $0 / 255 }, y = 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]
                encRef = [(16 * a + 219 * y + (1 - a) * bg[0]).rounded(), (128 * a + 224 * (p[2] - y) / 1.8556 + (1 - a) * bg[1]).rounded(),
                          (128 * a + 224 * (p[0] - y) / 1.5748 + (1 - a) * bg[2]).rounded()]
                XCTAssertNotEqual(out.v, bg, "\(name) overlay not rendered")
                XCTAssertLessThan(Self.dist(out.v, linRef), Self.dist(out.v, encRef), "\(name): linear \(linRef) encoded \(encRef) out \(out.v)")
            } else { XCTAssertEqual(out.v, bg, "transparent region changed") }
            rows[name] = ["background": bg, "out": out.v, "sd": out.sd, "linearRef": linRef, "encodedRef": encRef]
        }
        Self.record["OVERLAY"] = rows
    }

    func testBufferReuseAndStableMemoryOver30Frames() throws {
        let s601 = try load("SD601.mp4"), n = try SourceColorNormalizer()
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferWidthKey: 1920,
                                           kCVPixelBufferHeightKey: 1080, kCVPixelBufferIOSurfacePropertiesKey: [String: Int]()] as CFDictionary, &pool)
        let p = try XCTUnwrap(pool)
        func rss() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_maxrss) / 1048576 }
        var surfaces = Set<UInt32>(), times: [Double] = []
        let r0 = rss()
        for k in 0..<30 {
            try autoreleasepool {
                var pb: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, p, &pb), kCVReturnSuccess)
                let t = CACurrentMediaTime()
                let (o, _) = try n.render(layers: [NormalizerLayer(pixelBuffer: s601.frames[k]!, declaration: s601.declaration, transform: Self.fit, opacity: 1)], into: pb!)
                times.append((CACurrentMediaTime() - t) * 1000)
                XCTAssertEqual(frameCode(o).frame, k)
                if let s = CVPixelBufferGetIOSurface(o)?.takeUnretainedValue() { surfaces.insert(IOSurfaceGetID(s)) }
            }
        }
        Self.record["LIFECYCLE"] = ["distinctPoolSurfaces": surfaces.count, "rssBeforeMB": r0, "rssAfterMB": rss(), "renderMs": times]
    }
}
