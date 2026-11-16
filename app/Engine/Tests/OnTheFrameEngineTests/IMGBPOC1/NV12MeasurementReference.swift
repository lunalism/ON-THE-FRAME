import AVFoundation
import CoreGraphics
import CoreImage
import VideoToolbox
import IOSurface
import CryptoKit
import XCTest

enum QA01 {
    static func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func active(_ pb: CVPixelBuffer) throws -> Data {
        CVPixelBufferLockBaseAddress(pb,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
        var bytes = Data()
        for p in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,p)).assumingMemoryBound(to:UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb,p),width = CVPixelBufferGetWidthOfPlane(pb,p)*(p==0 ? 1:2)
            for y in 0..<CVPixelBufferGetHeightOfPlane(pb,p) { bytes.append(base+y*stride,count:width) }
        }
        return bytes
    }
    static func profile(_ pb: CVPixelBuffer) throws -> CGColorSpace {
        guard let a = CVBufferCopyAttachments(pb,.shouldPropagate),let p = CVImageBufferCreateColorSpaceFromAttachments(a) else { throw IBContract.error("QA01 source ICC missing",code:300) }
        return p.takeRetainedValue()
    }
    static func metadata(_ pb: CVPixelBuffer,allocation: String) throws -> [String:Any] {
        let width = CVPixelBufferGetWidth(pb),height = CVPixelBufferGetHeight(pb)
        guard CVPixelBufferGetPixelFormatType(pb)==IBContract.format,CVPixelBufferGetPlaneCount(pb)==2,
              width>0,height>0,width<=1920,height<=1080,width%2==0,height%2==0 else { throw IBContract.error("QA01 input format/extent",code:300) }
        CVPixelBufferLockBaseAddress(pb,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
        var planes: [[String:Any]] = []
        let bufferBase = CVPixelBufferGetBaseAddress(pb)
        for i in 0..<2 {
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,i)).assumingMemoryBound(to:UInt8.self)
            let rows = CVPixelBufferGetHeightOfPlane(pb,i),cols = CVPixelBufferGetWidthOfPlane(pb,i)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb,i),n = cols*(i==0 ? 1:2)
            guard stride>=n else { throw IBContract.error("QA01 row bounds",code:300) }
            var pixels = Data(),padding = Data()
            for row in 0..<rows {
                pixels.append(address+row*stride,count:n)
                if stride>n { padding.append(address+row*stride+n,count:stride-n) }
            }
            let offset: Any = bufferBase.map { Int(bitPattern:address)-Int(bitPattern:$0) } ?? "separate-or-unavailable-base"
            planes.append(["index":i,"width":cols,"height":rows,"bytesPerRow":stride,"activeBytesPerRow":n,
                "activeBytes":pixels.count,"activeSHA256":sha(pixels),"rowPaddingBytes":padding.count,"rowPaddingSHA256":sha(padding),"relativeBaseOffset":offset])
        }
        var left=0,right=0,top=0,bottom=0
        CVPixelBufferGetExtendedPixels(pb,&left,&right,&top,&bottom)
        let space = try profile(pb)
        var surface: [String:Any] = ["present":false]
        if let unmanaged = CVPixelBufferGetIOSurface(pb) {
            let s = unmanaged.takeUnretainedValue()
            var p: [[String:Int]] = []
            for i in 0..<IOSurfaceGetPlaneCount(s) { p.append(["width":IOSurfaceGetWidthOfPlane(s,i),"height":IOSurfaceGetHeightOfPlane(s,i),"bytesPerRow":IOSurfaceGetBytesPerRowOfPlane(s,i)]) }
            surface = ["present":true,"width":IOSurfaceGetWidth(s),"height":IOSurfaceGetHeight(s),"bytesPerRow":IOSurfaceGetBytesPerRow(s),"allocatedBytes":IOSurfaceGetAllocSize(s),"planes":p]
        }
        let keys: [(String,CFString)] = [("primaries",kCVImageBufferColorPrimariesKey),("transfer",kCVImageBufferTransferFunctionKey),
            ("matrix",kCVImageBufferYCbCrMatrixKey),("chromaTop",kCVImageBufferChromaLocationTopFieldKey),
            ("chromaBottom",kCVImageBufferChromaLocationBottomFieldKey),("cleanAperture",kCVImageBufferCleanApertureKey),
            ("pixelAspect",kCVImageBufferPixelAspectRatioKey),("CGColorSpace",kCVImageBufferCGColorSpaceKey),
            ("gamma",kCVImageBufferGammaLevelKey),("chromaSubsampling",kCVImageBufferChromaSubsamplingKey),
            ("displayDimensions",kCVImageBufferDisplayDimensionsKey)]
        var named: [String:String] = [:]
        for (name,key) in keys { named[name] = String(describing:CVBufferCopyAttachment(pb,key,nil)) }
        return ["allocation":allocation,"pixelFormat":CVPixelBufferGetPixelFormatType(pb),"formatName":"420v","range":"video: nominalY16...235,CbCr16...240,zero128",
            "width":width,"height":height,"dataSize":CVPixelBufferGetDataSize(pb),"planes":planes,"IOSurface":surface,
            "extendedPixels":[left,right,top,bottom],"namedAttachments":named,"sourceICC":String(describing:space),
            "sourceICCSHA256":space.copyICCData().map { sha($0 as Data) } ?? "none",
            "attachedICCSHA256":(CVBufferCopyAttachment(pb,kCVImageBufferICCProfileKey,nil) as? Data).map(sha) ?? "absent",
            "propagating":String(describing:CVBufferCopyAttachments(pb,.shouldPropagate)),
            "nonPropagating":String(describing:CVBufferCopyAttachments(pb,.shouldNotPropagate)),
            "orientation":"no transform applied; all tested source has full-frame identity orientation; recorded attachment dictionaries remain authoritative",
            "imageExtent":[0,0,width,height]]
    }
    static func clone(_ pb: CVPixelBuffer,surface: Bool,allAttachments: Bool = true) throws -> CVPixelBuffer {
        var copy: CVPixelBuffer?
        let attrs: [String:Any]? = surface ? [kCVPixelBufferIOSurfacePropertiesKey as String:[:]] : nil
        guard CVPixelBufferCreate(nil,CVPixelBufferGetWidth(pb),CVPixelBufferGetHeight(pb),IBContract.format,attrs as CFDictionary?,&copy)==kCVReturnSuccess,let copy else { throw IBContract.error("QA01 allocation",code:300) }
        do {
            CVPixelBufferLockBaseAddress(pb,.readOnly);CVPixelBufferLockBaseAddress(copy,[])
            defer { CVPixelBufferUnlockBaseAddress(copy,[]);CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
            for i in 0..<2 {
                let s = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,i)),d = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(copy,i))
                let ss = CVPixelBufferGetBytesPerRowOfPlane(pb,i),ds = CVPixelBufferGetBytesPerRowOfPlane(copy,i)
                let rows = CVPixelBufferGetHeightOfPlane(pb,i),bytes = CVPixelBufferGetWidthOfPlane(pb,i)*(i==0 ? 1:2)
                for row in 0..<rows { memset(d+row*ds,i==0 ? 16:128,ds);memcpy(d+row*ds,s+row*ss,bytes) }
            }
        }
        CVBufferPropagateAttachments(pb,copy)
        if allAttachments,let non = CVBufferCopyAttachments(pb,.shouldNotPropagate) { CVBufferSetAttachments(copy,non,.shouldNotPropagate) }
        return copy
    }
    static func attachmentEquality(_ a: CVPixelBuffer,_ b: CVPixelBuffer) -> [String:Bool] {
        func equal(_ mode: CVAttachmentMode) -> Bool {
            let x = CVBufferCopyAttachments(a,mode),y = CVBufferCopyAttachments(b,mode)
            if x==nil && y==nil { return true };guard let x,let y else { return false };return CFEqual(x,y)
        }
        return ["propagatingEqual":equal(.shouldPropagate),"nonPropagatingEqual":equal(.shouldNotPropagate)]
    }
    struct VTCapture { let raw: [UInt8],srgb: [UInt8],info: [String:Any] }
    static func vt(_ pb: CVPixelBuffer) throws -> VTCapture {
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pb,options:nil,imageOut:&image)
        guard status==noErr,let image,image.bitsPerComponent==8,image.bitsPerPixel==32,
              let source = image.dataProvider?.data else { throw IBContract.error("QA01 VT RGB representation unsupported \(status)",code:300) }
        let data = source as Data,w = image.width,h = image.height,stride = image.bytesPerRow
        guard data.count>=stride*h else { throw IBContract.error("QA01 CG data bounds",code:300) }
        let little = (image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue)==CGBitmapInfo.byteOrder32Little.rawValue
        let first = [CGImageAlphaInfo.first,.premultipliedFirst,.noneSkipFirst].contains(image.alphaInfo)
        let last = [CGImageAlphaInfo.last,.premultipliedLast,.noneSkipLast].contains(image.alphaInfo)
        guard first || last else { throw IBContract.error("QA01 unsupported alpha layout",code:300) }
        var raw = [UInt8](repeating:255,count:w*h*4)
        data.withUnsafeBytes { source in
            let p = source.bindMemory(to:UInt8.self)
            for y in 0..<h { for x in 0..<w {
                let a = y*stride+x*4,k = (y*w+x)*4
                let indices = first ? (little ? (2,1,0):(1,2,3)) : (little ? (3,2,1):(0,1,2))
                raw[k]=p[a+indices.0];raw[k+1]=p[a+indices.1];raw[k+2]=p[a+indices.2]
            } }
        }
        let normalized = try IBReference.bytes(image)
        let info: [String:Any] = ["call":"VTCreateCGImageFromCVPixelBuffer(options:nil)","status":status,"width":w,"height":h,
            "bpc":image.bitsPerComponent,"bpp":image.bitsPerPixel,"bytesPerRow":stride,"bitmapInfo":image.bitmapInfo.rawValue,"alphaInfo":image.alphaInfo.rawValue,
            "sourceColorSpace":String(describing:image.colorSpace),"outputColorSpace":"sRGB RGBA8 CGContext, relativeColorimetric/default draw; unchanged legacy normalization",
            "outputICCSHA256":image.colorSpace?.copyICCData().map { sha($0 as Data) } ?? "none"]
        return VTCapture(raw:raw,srgb:normalized,info:info)
    }
    struct Samples {
        let w: Int,h: Int,y: [UInt8],uv: [UInt8],space: CGColorSpace
        init(_ pb: CVPixelBuffer) throws {
            w=CVPixelBufferGetWidth(pb);h=CVPixelBufferGetHeight(pb);space=try QA01.profile(pb)
            guard w>0,h>0,w%2==0,h%2==0,CVPixelBufferGetPixelFormatType(pb)==IBContract.format else { throw IBContract.error("QA01 samples format",code:300) }
            for key in [kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey,kCVImageBufferYCbCrMatrixKey,kCVImageBufferChromaLocationTopFieldKey] {
                guard let value=CVBufferCopyAttachment(pb,key,nil) as? String,value==IBContract.attachments[key as String] as? String else { throw IBContract.error("QA01 declared709/Left contract",code:300) }
            }
            let d = try QA01.active(pb);let bytes = [UInt8](d)
            guard bytes.count==w*h*3/2 else { throw IBContract.error("QA01 samples bounds") }
            y=Array(bytes[0..<w*h]);uv=Array(bytes[w*h..<bytes.count])
        }
        /// Declared Left siting: chroma centers (2i+0.5,2j+1.0), luma centers (x+0.5,y+0.5).
        func chroma(_ x: Int,_ y: Int) -> (Double,Double) {
            let fx=Double(x)/2,fy=Double(y)/2-0.25,ix=Int(floor(fx)),iy=Int(floor(fy)),dx=fx-Double(ix),dy=fy-Double(iy)
            func value(_ xx: Int,_ yy: Int,_ c: Int) -> Double { Double(uv[max(0,min(h/2-1,yy))*w+max(0,min(w/2-1,xx))*2+c]) }
            func sample(_ c: Int) -> Double { value(ix,iy,c)*(1-dx)*(1-dy)+value(ix+1,iy,c)*dx*(1-dy)+value(ix,iy+1,c)*(1-dx)*dy+value(ix+1,iy+1,c)*dx*dy }
            return (sample(0),sample(1))
        }
        func rgb709(_ x: Int,_ yy: Int) -> (Double,Double,Double) {
            let c=chroma(x,yy),l=Double(Int(y[yy*w+x])-16)/219,u=(c.0-128)/224,v=(c.1-128)/224
            return (l+1.5748*v,l-0.187324*u-0.468124*v,l+1.8556*u)
        }
    }
    static func explicit(_ pb: CVPixelBuffer) throws -> [UInt8] {
        let source = try Samples(pb)
        var rgba=[Float](repeating:1,count:source.w*source.h*4)
        for y in 0..<source.h { for x in 0..<source.w {
            let rgb=source.rgb709(x,y),k=(y*source.w+x)*4
            rgba[k]=Float(max(0,min(1,rgb.0)));rgba[k+1]=Float(max(0,min(1,rgb.1)));rgba[k+2]=Float(max(0,min(1,rgb.2)))
        } }
        let data=rgba.withUnsafeBytes { Data($0) }
        guard let provider=CGDataProvider(data:data as CFData),let image=CGImage(width:source.w,height:source.h,bitsPerComponent:32,bitsPerPixel:128,
            bytesPerRow:source.w*16,space:source.space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric) else { throw IBContract.error("QA01 float reference unavailable",code:300) }
        return try IBReference.bytes(image)
    }
    static func colorExpected(_ rgb: (Double,Double,Double),profile: CGColorSpace) throws -> [UInt8] {
        let c=try IBReference.context(1,1)
        guard let color=CGColor(colorSpace:profile,components:[CGFloat(max(0,min(1,rgb.0))),CGFloat(max(0,min(1,rgb.1))),CGFloat(max(0,min(1,rgb.2))),1]) else { throw IBContract.error("QA01 hand CGColor") }
        c.setFillColor(color);c.fill(CGRect(x:0,y:0,width:1,height:1))
        let image=try XCTUnwrap(c.makeImage());return try IBReference.bytes(image)
    }
    static func controlledCI(_ pb: CVPixelBuffer) throws -> [UInt8] {
        let w=CVPixelBufferGetWidth(pb),h=CVPixelBufferGetHeight(pb),source=try profile(pb)
        let output=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),linear=try XCTUnwrap(CGColorSpace(name:CGColorSpace.extendedLinearSRGB))
        let context=CIContext(options:[.useSoftwareRenderer:true,.workingColorSpace:linear,.outputColorSpace:output,.cacheIntermediates:false])
        let image=CIImage(cvPixelBuffer:pb,options:[.colorSpace:source])
        guard image.extent==CGRect(x:0,y:0,width:w,height:h) else { throw IBContract.error("QA01 CI extent",code:300) }
        var result=[UInt8](repeating:0,count:w*h*4)
        result.withUnsafeMutableBytes { data in
            if let base=data.baseAddress { context.render(image,toBitmap:base,rowBytes:w*4,bounds:image.extent,format:.RGBA8,colorSpace:output) }
        }
        return result
    }
    static func stats(_ a: [UInt8],_ b: [UInt8],width: Int,height: Int,region: CGRect? = nil) throws -> [String:Any] {
        guard a.count==b.count,a.count==width*height*4 else { throw IBContract.error("QA01 comparison bounds") }
        let rect=region ?? CGRect(x:0,y:0,width:width,height:height)
        guard rect.minX>=0,rect.minY>=0,rect.maxX<=CGFloat(width),rect.maxY<=CGFloat(height),rect.width>0,rect.height>0 else { throw IBContract.error("QA01 ROI") }
        var sum=0.0,maximum=0,worst=[Int(rect.minX),Int(rect.minY),0],different=0,hist=[Int](repeating:0,count:256)
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
            let k=(y*width+x)*4;var pixel=0
            for c in 0..<3 { let d=abs(Int(a[k+c])-Int(b[k+c]));sum+=Double(d*d);hist[d]+=1;pixel=max(pixel,d);if d>maximum { maximum=d;worst=[x,y,c] } }
            if pixel>0 { different+=1 }
        } }
        let n=Int(rect.width*rect.height)*3;var p99=0,cumulative=0
        for i in 0..<256 { cumulative+=hist[i];if cumulative>=n*99/100 { p99=i;break } }
        let k=(worst[1]*width+worst[0])*4
        return ["maximum":maximum,"p99":p99,"differentPixels":different,"psnr":sum==0 ? 999:10*log10(65025/(sum/Double(n))),
            "worstXYC":worst,"actual":Array(a[k..<k+4]),"reference":Array(b[k..<k+4])]
    }
    static func synthetic(_ pattern: String) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil,16,16,IBContract.format,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pb)==kCVReturnSuccess,let pb else { throw IBContract.error("QA01 synthetic IOSurface",code:300) }
        CVPixelBufferLockBaseAddress(pb,[])
        do {
            defer { CVPixelBufferUnlockBaseAddress(pb,[]) }
            let y=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,0)).assumingMemoryBound(to:UInt8.self),uv=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,1)).assumingMemoryBound(to:UInt8.self)
            let ys=CVPixelBufferGetBytesPerRowOfPlane(pb,0),cs=CVPixelBufferGetBytesPerRowOfPlane(pb,1)
            for row in 0..<16 {
                memset(y+row*ys,16,ys)
                for x in 0..<16 {
                    let value:Int
                    if pattern=="patches" { value=row<8 ? (x<8 ? 16:235):(x<8 ? 126:63) }
                    else if pattern.hasPrefix("luma") { value=x >= (pattern=="luma-odd7" ? 7:8) ? 235:16 }
                    else { value=126 }
                    y[row*ys+x]=UInt8(value)
                }
            }
            for row in 0..<8 {
                memset(uv+row*cs,128,cs)
                for x in 0..<8 {
                    var u=128,v=128
                    if pattern=="patches",row>=4,x>=4 { u=102;v=240 }
                    if pattern=="chroma-x8" { u=x<4 ? 96:160;v=x<4 ? 160:96 }
                    if pattern=="chroma-y8" { u=row<4 ? 96:160;v=row<4 ? 160:96 }
                    uv[row*cs+x*2]=UInt8(u);uv[row*cs+x*2+1]=UInt8(v)
                }
            }
        }
        IBContract.tag(pb)
        CVBufferSetAttachment(pb,kCVImageBufferCGColorSpaceKey,try IBContract.profile(),.shouldPropagate)
        CVBufferSetAttachment(pb,kCVImageBufferCleanApertureKey,["Width":16,"Height":16,"HorizontalOffset":0,"VerticalOffset":0] as CFDictionary,.shouldPropagate)
        CVBufferSetAttachment(pb,kCVImageBufferPixelAspectRatioKey,["HorizontalSpacing":1,"VerticalSpacing":1] as CFDictionary,.shouldPropagate)
        return pb
    }
}
