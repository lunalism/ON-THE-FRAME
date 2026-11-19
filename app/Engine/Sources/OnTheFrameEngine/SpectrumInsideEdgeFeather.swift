import Accelerate
import CoreGraphics

/// Experimental inward feather on the shared, premultiplied Spectrum raster.
/// The mask represents geometry at full opacity, including overlaps, independently of the item's alpha.
///
/// DIGITAL-FEATHER-OPT-A01: bit-exact sparse visiting. Every value written is produced by the original
/// scalar expression (or is the exact constant that expression yields); only provable no-op visits are skipped:
/// - Forward: a zero-coverage pixel always becomes `Float(0) / 255 - 0.5 == -0.5` and reads no neighbour,
///   so the row is pre-filled with -0.5 and only nonzero-coverage pixels run the original code, in ascending x.
///   A full pixel's reads (x-1 in this row, the previous row) therefore see exactly the original values.
/// - Reverse: only `line[x] > 0.5` pixels change. Zero (-0.5) and partial (<= 254/255 - 0.5 < 0.5) forward
///   values never qualify, and the pass only lowers values, so only full-coverage pixels are visited, in
///   descending x. Skipped pixels keep the same values the original reads from them.
/// - Attenuation: the original skips `pixel[3] == 0`; each output pixel is touched once and reads only itself,
///   so only nonzero output-alpha pixels are visited (output alpha, not mask coverage), in ascending x.
/// The reported scratch payload (mask + distance buffer) is unchanged; the per-row index scratch is not part of it.
struct SpectrumInsideEdgeFeather {
    #if DEBUG
    let timing: SpectrumRequestTiming?
    #endif

    func apply(percent: Int, bands: [Float], style: SpectrumStyle, canvas: CGSize,
                      bounds: CGRect, into output: CGContext) throws -> Int {
        #if DEBUG
        let maskStart = timing?.rasterClock()
        #endif
        let strength = Float(percent) / 100
        let radius = strength * Float(min(style.thickness / 2, 4) * canvas.height / 1080)
        let halo = Int(radius.rounded(.up)) + 1
        // Draw the *unclipped* geometry beyond every canvas edge. Clipping before measuring
        // distance would turn the canvas border into a false contour of a crossing stroke.
        let region = bounds.insetBy(dx: -CGFloat(halo), dy: -CGFloat(halo))
        let width = Int(region.width), height = Int(region.height)
        let rowBytes = ((width + 63) / 64) * 64
        guard let mask = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let maskData = mask.data else {
            #if DEBUG
            timing?.recordRasterTime(.coverageMask, since: maskStart)
            #endif
            throw SpectrumRenderError.invalidCanvas("feather coverage mask")
        }
        memset(maskData, 0, rowBytes * height)
        mask.translateBy(x: -region.minX, y: region.maxY)
        mask.scaleBy(x: 1, y: -1)
        var opaque = style
        opaque.red = 1
        opaque.green = 1
        opaque.blue = 1
        opaque.alpha = 1
        SpectrumGeometry.draw(bands, style: opaque, canvas: canvas, into: mask)

        #if DEBUG
        timing?.recordRasterTime(.coverageMask, since: maskStart)
        // Scratch preparation belongs to the first forward sweep. Commit the
        // three accumulated durations once; the interleaved rows stay in-place.
        var forwardStart = timing?.rasterClock()
        var forwardNS: UInt64 = 0, reverseNS: UInt64 = 0, attenuationNS: UInt64 = 0
        #endif
        let coverage = maskData.assumingMemoryBound(to: UInt8.self)
        let pixels = output.data!.assumingMemoryBound(to: UInt8.self)
        let stripHeight = 64
        let pitch = width + 2  // one sentinel on each side
        let scratchRows = min(height, stripHeight + 2 * halo) + 2
        let distance = UnsafeMutableBufferPointer<Float>.allocate(capacity: pitch * scratchRows)
        distance.initialize(repeating: radius)
        defer { distance.deallocate() }
        let first = distance.baseAddress!
        let diagonal = Float(2).squareRoot()
        let boundsWidth = Int(bounds.width)

        withExtendedLifetime(mask) {
            Self.withPositionScratch(span: max(width, boundsWidth) + 1) { positions in
                for start in stride(from: 0, to: Int(bounds.height), by: stripHeight) {
                    let count = min(stripHeight, Int(bounds.height) - start)
                    // region has a halo on all sides; these rows include both neighboring strips.
                    let rows = count + 2 * halo
                    first.update(repeating: radius, count: pitch)
                    (first + (rows + 1) * pitch).update(repeating: radius, count: pitch)
                    for y in 0..<rows {
                        let src = coverage + (start + y) * rowBytes
                        let line = first + (y + 1) * pitch + 1
                        let prev = line - pitch
                        // Zero coverage: the original writes Float(0) / 255 - 0.5, exactly -0.5.
                        line.update(repeating: -0.5, count: width)
                        var next = positions.select(src, stride: 1, count: width, fullOnly: false)
                        while next.pointee < Float(width) {
                            let x = Int(next.pointee)
                            next += 1
                            // A partially covered pixel seeds a subpixel edge; a hard axis-aligned
                            // step lies halfway between its last empty and first full pixel centers.
                            if src[x] < 255 {
                                line[x] = Float(src[x]) / 255 - 0.5
                            } else {
                                let axial = min(line[x - 1], prev[x]) + 1
                                let corner = min(prev[x - 1], prev[x + 1]) + diagonal
                                line[x] = min(radius, axial, corner)
                            }
                        }
                    }
                    #if DEBUG
                    if let forwardStart, let timing { forwardNS += timing.rasterClock() - forwardStart }
                    #endif
                    // The reverse sweep completes an eight-neighbor approximation to Euclidean
                    // distance. No point farther away than radius affects the candidate curve.
                    for y in stride(from: rows - 1, through: halo, by: -1) {
                        let line = first + (y + 1) * pitch + 1
                        #if DEBUG
                        let reverseStart = timing?.rasterClock()
                        #endif
                        let next = line + pitch
                        // Only full-coverage pixels can hold a forward value above 0.5.
                        let full = positions.select(coverage + (start + y) * rowBytes, stride: 1, count: width, fullOnly: true)
                        var fullCount = 0
                        while full[fullCount] < Float(width) { fullCount += 1 }
                        for i in stride(from: fullCount - 1, through: 0, by: -1) {
                            let x = Int(full[i])
                            guard line[x] > 0.5 else { continue }
                            let axial = min(line[x + 1], next[x]) + 1
                            let corner = min(next[x - 1], next[x + 1]) + diagonal
                            line[x] = min(line[x], axial, corner)
                        }
                        #if DEBUG
                        let split = timing?.rasterClock()
                        if let reverseStart, let split { reverseNS += split - reverseStart }
                        #endif
                        guard y < halo + count else { continue }
                        let outputY = Int(region.minY) + start + y
                        let row = pixels + outputY * output.bytesPerRow + Int(bounds.minX) * 4
                        // Only nonzero output alpha is attenuated (mask coverage may differ from it).
                        var visible = positions.select(row + 3, stride: 4, count: boundsWidth, fullOnly: false)
                        while visible.pointee < Float(boundsWidth) {
                            let x = Int(visible.pointee)
                            visible += 1
                            let pixel = row + x * 4
                            let d = line[x + halo]
                            guard pixel[3] != 0, d < radius else { continue }
                            let t = max(0, d / radius)
                            let smooth = t * t * (3 - 2 * t)
                            let k = 1 - strength * 0.5 * (1 - smooth)
                            // Apply the same factor once to all four already-premultiplied bytes.
                            for component in 0..<4 {
                                pixel[component] = UInt8((Float(pixel[component]) * k).rounded())
                            }
                        }
                        #if DEBUG
                        if let split, let timing { attenuationNS += timing.rasterClock() - split }
                        #endif
                    }
                    #if DEBUG
                    forwardStart = timing?.rasterClock()
                    #endif
                }
            }
        }
        #if DEBUG
        timing?.add(.distanceForward, nanoseconds: forwardNS)
        timing?.add(.distanceReverse, nanoseconds: reverseNS)
        timing?.add(.attenuation, nanoseconds: attenuationNS)
        #endif
        return rowBytes * height + distance.count * MemoryLayout<Float>.stride
    }

    /// Ascending x positions of nonzero (or exactly 255) bytes, terminated by `count`.
    /// Float holds every position exactly (count <= 3840 + 2 * halo < 2^24).
    private struct PositionScratch {
        let ramp: UnsafeMutablePointer<Float>, values: UnsafeMutablePointer<Float>, selected: UnsafeMutablePointer<Float>

        func select(_ bytes: UnsafePointer<UInt8>, stride: Int, count: Int, fullOnly: Bool) -> UnsafePointer<Float> {
            vDSP_vfltu8(bytes, vDSP_Stride(stride), values, 1, vDSP_Length(count))
            if fullOnly {
                // vthres keeps values >= 255 and zero-fills the rest: nonzero exactly where the byte is 255.
                var full: Float = 255
                vDSP_vthres(values, 1, &full, values, 1, vDSP_Length(count))
            }
            values[count] = 1   // end marker: selected[...] ends with ramp[count] == count
            vDSP_vcmprs(ramp, 1, values, 1, selected, 1, vDSP_Length(count + 1))
            return UnsafePointer(selected)
        }
    }

    private static func withPositionScratch(span: Int, _ body: (PositionScratch) -> Void) {
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 3 * span) { scratch in
            let ramp = scratch.baseAddress!
            var zero: Float = 0, one: Float = 1
            vDSP_vramp(&zero, &one, ramp, 1, vDSP_Length(span))
            body(PositionScratch(ramp: ramp, values: ramp + span, selected: ramp + 2 * span))
        }
    }
}
