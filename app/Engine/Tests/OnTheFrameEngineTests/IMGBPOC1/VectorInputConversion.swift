import AVFoundation
import Foundation

/// OPT01's only vectorized operation: three independent forward709 input channels.
/// No FMA/addingProduct request; green retains its second sequential subtraction.
enum IBVectorInputConversion {
    @inline(__always) static func scalar(_ y:Float,_ cb:Float,_ cr:Float)->SIMD3<Float> {
        SIMD3(y+1.5748*cr,y-0.187324*cb-0.468124*cr,y+1.8556*cb)
    }
    @inline(__always) static func vector(_ y:Float,_ cb:Float,_ cr:Float)->SIMD3<Float> {
        let products=SIMD3<Float>(1.5748,-0.187324,1.8556)*SIMD3<Float>(cr,cb,cb)
        var result=SIMD3<Float>(repeating:y)+products
        result.y = result.y-0.468124*cr
        return result
    }
}

/// Separate experimental pixel function. Baseline file is never changed.
final class IBVectorInputCompositor {
    private struct Planes {
        let y: UnsafeMutablePointer<UInt8>,uv: UnsafeMutablePointer<UInt8>,ys: Int,uvs: Int
        init(_ pb: CVPixelBuffer) throws {
            guard let yy = CVPixelBufferGetBaseAddressOfPlane(pb,0),let cc = CVPixelBufferGetBaseAddressOfPlane(pb,1) else { throw IBContract.error("plane address") }
            y = yy.assumingMemoryBound(to: UInt8.self);uv = cc.assumingMemoryBound(to: UInt8.self)
            ys = CVPixelBufferGetBytesPerRowOfPlane(pb,0);uvs = CVPixelBufferGetBytesPerRowOfPlane(pb,1)
        }
    }
    @inline(__always) private func byte(_ v: Float) -> UInt8 { UInt8(max(0,min(255,v.rounded()))) }
    func render(bottom: CVPixelBuffer,top: CVPixelBuffer?,out: CVPixelBuffer,ins: IBInstruction,deadline: Date) throws {
        guard ins.png.rgba.count == IBContract.w*IBContract.h*4 else { throw IBContract.error("PNG bounds",code: 200) }
        CVPixelBufferLockBaseAddress(bottom,.readOnly);if let top { CVPixelBufferLockBaseAddress(top,.readOnly) };CVPixelBufferLockBaseAddress(out,[])
        defer { CVPixelBufferUnlockBaseAddress(out,[]);if let top { CVPixelBufferUnlockBaseAddress(top,.readOnly) };CVPixelBufferUnlockBaseAddress(bottom,.readOnly) }
        let b = try Planes(bottom),t = try top.map { try Planes($0) },o = try Planes(out)
        let imageActive = ins.frame >= 1 && ins.frame < 5, width = IBContract.w,height = IBContract.h
        // Integer-only gate: top translated (+960,+540), 1:1 pixels. No image-aware visibility culler.
        try ins.png.rgba.withUnsafeBufferPointer { png in
            for y in stride(from: 0,to: height,by: 2) {
                if y % 64 == 0 && Date() > deadline { throw IBContract.error("render time budget",code: 300) }
                for x in stride(from: 0,to: width,by: 2) {
                    if let t,x >= 960,y >= 540 {
                        let sx = x-960,sy = y-540
                        o.y[y*o.ys+x] = t.y[sy*t.ys+sx];o.y[y*o.ys+x+1] = t.y[sy*t.ys+sx+1]
                        o.y[(y+1)*o.ys+x] = t.y[(sy+1)*t.ys+sx];o.y[(y+1)*o.ys+x+1] = t.y[(sy+1)*t.ys+sx+1]
                        o.uv[(y/2)*o.uvs+x] = t.uv[(sy/2)*t.uvs+sx];o.uv[(y/2)*o.uvs+x+1] = t.uv[(sy/2)*t.uvs+sx+1]
                        continue
                    }
                    if !imageActive {
                        o.y[y*o.ys+x] = b.y[y*b.ys+x];o.y[y*o.ys+x+1] = b.y[y*b.ys+x+1]
                        o.y[(y+1)*o.ys+x] = b.y[(y+1)*b.ys+x];o.y[(y+1)*o.ys+x+1] = b.y[(y+1)*b.ys+x+1]
                        o.uv[(y/2)*o.uvs+x] = b.uv[(y/2)*b.uvs+x];o.uv[(y/2)*o.uvs+x+1] = b.uv[(y/2)*b.uvs+x+1]
                        continue
                    }
                    var leftCb: Float = 0,leftCr: Float = 0
                    for dy in 0..<2 { for dx in 0..<2 {
                        let xx = x+dx,yy = y+dy,k = (yy*width+xx)*4
                        let yyv = (Float(b.y[yy*b.ys+xx])-16)/219
                        let cb = (Float(b.uv[(yy/2)*b.uvs+(xx/2)*2])-128)/224
                        let cr = (Float(b.uv[(yy/2)*b.uvs+(xx/2)*2+1])-128)/224
                        let converted = IBVectorInputConversion.vector(yyv,cb,cr)
                        let a = Float(png[k+3])/255,remain = 1-a
                        let r = ins.transfer.convert(Float(png[k])/255 + remain*ins.transfer.convert(converted.x,table: ins.transfer.toSRGB),table: ins.transfer.to709)
                        let g = ins.transfer.convert(Float(png[k+1])/255 + remain*ins.transfer.convert(converted.y,table: ins.transfer.toSRGB),table: ins.transfer.to709)
                        let blue = ins.transfer.convert(Float(png[k+2])/255 + remain*ins.transfer.convert(converted.z,table: ins.transfer.toSRGB),table: ins.transfer.to709)
                        let l = 0.2126*r+0.7152*g+0.0722*blue
                        o.y[yy*o.ys+xx] = byte(16+219*l)
                        if dx == 0 { leftCb += (blue-l)/1.8556;leftCr += (r-l)/1.5748 }
                    } }
                    // Declared Left chroma: first column, mean of the two vertical samples.
                    o.uv[(y/2)*o.uvs+x] = byte(128+112*leftCb)
                    o.uv[(y/2)*o.uvs+x+1] = byte(128+112*leftCr)
                }
            }
        }
    }
}
