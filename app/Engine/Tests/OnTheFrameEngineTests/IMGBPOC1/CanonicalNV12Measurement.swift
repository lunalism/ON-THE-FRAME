import AVFoundation
import CoreGraphics
import CryptoKit
import XCTest

/// qa02-left-linear-icc-v1: measurement only. Not a product reconstruction policy.
enum IBCanonicalNV12 {
    static let version = "qa02-left-linear-icc-v1"
    struct Planes {
        let w:Int,h:Int,y:[UInt8],uv:[UInt8],profile:CGColorSpace
        init(_ pb:CVPixelBuffer) throws {
            w=CVPixelBufferGetWidth(pb);h=CVPixelBufferGetHeight(pb)
            guard CVPixelBufferGetPixelFormatType(pb)==IBContract.format,CVPixelBufferGetPlaneCount(pb)==2,
                  w>0,h>0,w<=1920,h<=1080,w%2==0,h%2==0,
                  CVPixelBufferGetWidthOfPlane(pb,0)==w,CVPixelBufferGetHeightOfPlane(pb,0)==h,
                  CVPixelBufferGetWidthOfPlane(pb,1)==w/2,CVPixelBufferGetHeightOfPlane(pb,1)==h/2 else { throw IBContract.error("canonical unsupported420v extent",code:300) }
            for key in [kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey,kCVImageBufferYCbCrMatrixKey,kCVImageBufferChromaLocationTopFieldKey] {
                guard let v=CVBufferCopyAttachment(pb,key,nil) as? String,v==IBContract.attachments[key as String] as? String else { throw IBContract.error("canonical709/Left declaration",code:300) }
            }
            if let v=CVBufferCopyAttachment(pb,kCVImageBufferChromaLocationBottomFieldKey,nil) as? String,v != kCVImageBufferChromaLocation_Left as String { throw IBContract.error("canonical bottom siting",code:300) }
            if let v=CVBufferCopyAttachment(pb,kCVImageBufferFieldCountKey,nil) as? NSNumber,v.intValue != 1 { throw IBContract.error("canonical interlace unsupported",code:300) }
            if let a=CVBufferCopyAttachment(pb,kCVImageBufferCleanApertureKey,nil) as? [String:Any] {
                guard (a["Width"] as? NSNumber)?.doubleValue==Double(w),(a["Height"] as? NSNumber)?.doubleValue==Double(h),
                      (a["HorizontalOffset"] as? NSNumber)?.doubleValue==0,(a["VerticalOffset"] as? NSNumber)?.doubleValue==0 else { throw IBContract.error("canonical nonfull aperture",code:300) }
            }
            if let a=CVBufferCopyAttachment(pb,kCVImageBufferPixelAspectRatioKey,nil) as? [String:Any] {
                guard let x=a["HorizontalSpacing"] as? NSNumber,let y=a["VerticalSpacing"] as? NSNumber,x.doubleValue>0,x==y else { throw IBContract.error("canonical nonsquare aspect",code:300) }
            }
            guard let a=CVBufferCopyAttachments(pb,.shouldPropagate),let s=CVImageBufferCreateColorSpaceFromAttachments(a) else { throw IBContract.error("canonical source ICC",code:300) }
            profile=s.takeRetainedValue()
            guard profile.copyICCData()==(try IBContract.profile()).copyICCData() else { throw IBContract.error("canonical unsupported ICC",code:300) }
            CVPixelBufferLockBaseAddress(pb,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
            var arrays=[[UInt8]]()
            for i in 0..<2 {
                let rows=i==0 ? h:h/2,stride=CVPixelBufferGetBytesPerRowOfPlane(pb,i)
                guard stride>=w,let address=CVPixelBufferGetBaseAddressOfPlane(pb,i) else { throw IBContract.error("canonical plane bounds",code:300) }
                let p=address.assumingMemoryBound(to:UInt8.self);var plane=[UInt8]();plane.reserveCapacity(rows*w)
                for row in 0..<rows { plane.append(contentsOf:UnsafeBufferPointer(start:p+row*stride,count:w)) }
                arrays.append(plane)
            }
            y=arrays[0];uv=arrays[1]
        }
        /// Integer polyphase weights: x even(2,0),odd(1,1); y even prev/current(1,3),odd current/next(3,1).
        func chroma(_ x:Int,_ yy:Int,_ component:Int)->Double {
            let i=x/2,j=yy/2,x0=i,x1=min(w/2-1,i+1),y0=yy%2==0 ? max(0,j-1):j,y1=yy%2==0 ? j:min(h/2-1,j+1)
            let a=x%2==0 ? 2:1,b=2-a,c=yy%2==0 ? 1:3,d=4-c
            let sum=Int(uv[y0*w+x0*2+component])*a*c+Int(uv[y0*w+x1*2+component])*b*c
                + Int(uv[y1*w+x0*2+component])*a*d+Int(uv[y1*w+x1*2+component])*b*d
            return Double(sum)/8
        }
        func rgb(_ x:Int,_ yy:Int)->(Double,Double,Double) {
            let l=Double(Int(y[yy*w+x])-16)/219,cb=(chroma(x,yy,0)-128)/224,cr=(chroma(x,yy,1)-128)/224
            let r=l+2*(1-0.2126)*cr,b=l+2*(1-0.0722)*cb,g=(l-0.2126*r-0.0722*b)/0.7152
            return (r,g,b)
        }
    }
    static func bytes(_ pb:CVPixelBuffer) throws -> [UInt8] {
        let p=try Planes(pb);var f=[Float](repeating:1,count:p.w*p.h*4)
        for yy in 0..<p.h { for x in 0..<p.w {
            let c=p.rgb(x,yy),k=(yy*p.w+x)*4
            f[k]=Float(max(0,min(1,c.0)));f[k+1]=Float(max(0,min(1,c.1)));f[k+2]=Float(max(0,min(1,c.2)))
        } }
        let data=f.withUnsafeBytes { Data($0) }
        guard let provider=CGDataProvider(data:data as CFData),let image=CGImage(width:p.w,height:p.h,bitsPerComponent:32,bitsPerPixel:128,bytesPerRow:p.w*16,space:p.profile,
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.floatComponents.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric),
              let srgb=CGColorSpace(name:CGColorSpace.sRGB),let c=CGContext(data:nil,width:p.w,height:p.h,bitsPerComponent:8,bytesPerRow:p.w*4,space:srgb,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let out=c.data else { throw IBContract.error("canonical float ICC conversion",code:300) }
        c.setRenderingIntent(.relativeColorimetric);c.interpolationQuality = .none;c.draw(image,in:CGRect(x:0,y:0,width:p.w,height:p.h))
        return Array(UnsafeBufferPointer(start:out.assumingMemoryBound(to:UInt8.self),count:p.w*p.h*4))
    }
}
