import Foundation
import ImageIO
import CoreGraphics
import CryptoKit
import Compression
import zlib

/// Internal experimental foundation; intentionally disconnected from MediaProbe and app import.
struct StillImageDescriptor: Sendable,Equatable {
    enum Encoding:String,Sendable {case jpeg,png}
    let contractVersion:Int
    let encoding:Encoding
    let width:Int,height:Int,orientation:Int,displayWidth:Int,displayHeight:Int
    let componentBitDepth:Int,encodedSampleBitDepth:Int,colorModel:String
    let profileName:String?,profileSHA256:String?,profileDisposition:String
    let alphaCapability:Bool
    let identity:FileIdentity
}

enum StillImageProbeError:Error,Equatable,LocalizedError {
    case unreadable,invalidSignature,typeMismatch,multiImage,orientation,dimensions
    case unsupportedDepth,unsupportedColor,unsupportedProfile,animated,malformed,resourceLimit,changed
    case dimensionLimit(width:Int,height:Int,maxDimension:Int,maxPixels:Int)

    var errorDescription:String? {
        switch self {
        case .unreadable: return "이미지 원본을 읽을 수 없습니다. 파일이 존재하는지와 읽기 권한을 확인하세요."
        case .invalidSignature: return "JPEG 또는 PNG 이미지로 확인되지 않는 파일입니다."
        case .typeMismatch: return "파일 확장자와 실제 이미지 형식이 일치하지 않습니다."
        case .multiImage: return "주 이미지가 여러 개이거나 지원하지 않는 MPF 이미지 구성이 있습니다. 한 장의 JPEG·PNG와 확인된 보조 gain map만 지원합니다."
        case .orientation: return "이미지의 회전 방향 정보를 해석할 수 없습니다."
        case .dimensions: return "이미지의 가로·세로 크기를 확인할 수 없습니다."
        case .unsupportedDepth: return "현재 지원하지 않는 이미지 비트 깊이입니다. JPEG는 8비트, PNG는 8비트 또는 1·2·4비트 색인 형식만 지원합니다."
        case .unsupportedColor: return "현재 지원하지 않는 이미지 색상 모델입니다. RGB·회색조·색인 색상만 지원합니다."
        case .unsupportedProfile: return "이미지의 색상 정보가 현재 검증된 sRGB·Display P3 프로필 범위를 벗어납니다."
        case .animated: return "움직이는 PNG(APNG)는 아직 지원하지 않습니다. 정지 이미지만 가져올 수 있습니다."
        case .malformed: return "이미지 데이터를 끝까지 해석하지 못했습니다. 파일 구조나 데이터가 올바른지 확인하세요."
        case .resourceLimit: return "파일 크기 또는 이미지 처리 자원 한도를 초과했습니다. 이미지 파일은 최대 8 MiB까지 지원합니다."
        case .changed: return "검사 중 이미지 원본이 변경되었습니다. 변경이 끝난 뒤 다시 가져오세요."
        case .dimensionLimit(let width,let height,let maxDimension,let maxPixels):
            return "이미지 크기 \(width)×\(height) px가 지원 범위를 초과했습니다. 가로·세로는 각각 최대 \(maxDimension) px, 전체는 최대 \(maxPixels)픽셀입니다."
        }
    }
}

enum StillImageProbe {
    /// IMG-HR-01 provisional bounds. The 24-byte/pixel estimate is accounting,
    /// not an RSS guarantee or a decoder sandbox. Full primary validation is serial.
    struct Limits:Sendable,Equatable {
        var fileBytes=8*1024*1024,maxDimension=4096,maxPixels=16_777_216,estimatedDecodeBytes=384*1024*1024
    }
    struct Metadata:Sendable {
        let descriptor:StillImageDescriptor
        let encodedSHA256:String
        fileprivate let data:Data,url:URL,limits:Limits
    }
    struct Validation:Sendable {
        let descriptor:StillImageDescriptor
        let normalizedWidth:Int,normalizedHeight:Int,normalizedRGBABytes:Int
        let hasTransparentPixels:Bool
    }
    static let validationProxyMaxDimension=2048
    /// The original descriptor remains full resolution. Only transient normalized
    /// validation/Preview pixels are downsampled; no replacement source is written.
    static func proxySize(for descriptor:StillImageDescriptor,maxDimension:Int)->(width:Int,height:Int) {
        let w=descriptor.displayWidth,h=descriptor.displayHeight
        let scale=min(1,Double(max(1,maxDimension))/Double(max(w,h)))
        return (max(1,Int((Double(w)*scale).rounded())),max(1,Int((Double(h)*scale).rounded())))
    }
    /// Never expand/apply a gain map in the SDR pipeline. Inspection uses no
    /// auxiliary-data pixel API; one ImageIO-exposed primary at index zero only.
    static var sdrDecodeOptions:[CFString:Any] {
        var options:[CFString:Any]=[kCGImageSourceShouldCache:false,kCGImageSourceShouldAllowFloat:false]
        if #available(macOS 14.0, *){options[kCGImageSourceDecodeRequest]=kCGImageSourceDecodeToSDR}
        if #available(macOS 15.0, *){options[kCGImageSourceGenerateImageSpecificLumaScaling]=false}
        return options
    }
    private static func admittedICC(_ data:Data)throws->String {
        guard data.count<=1_048_576,let space=CGColorSpace(iccData:data as CFData) else{throw StillImageProbeError.unsupportedProfile}
        for (name,disposition) in [(CGColorSpace.sRGB,"embedded-sRGB-ICC"),(CGColorSpace.displayP3,"embedded-Display-P3-ICC")] {
            guard let standard=CGColorSpace(name:name) else{continue}
            if let reference=standard.copyICCData(),data==(reference as Data){return disposition}
            // ImageIO/CoreGraphics recognizes the ICC as the named system color
            // space; a profile-name substring alone never admits an arbitrary ICC.
            if space.model == .rgb,let actual=space.name,let known=standard.name,(actual as String)==(known as String){return disposition}
        }
        throw StillImageProbeError.unsupportedProfile
    }
    static func pixelAdmission(width:Int,height:Int,limits:Limits)throws->Int {
        guard width>0,height>0 else{throw StillImageProbeError.dimensions}
        let (pixels,overflow)=width.multipliedReportingOverflow(by:height)
        guard !overflow else{throw StillImageProbeError.resourceLimit}
        guard width<=limits.maxDimension,height<=limits.maxDimension,pixels<=limits.maxPixels else{
            throw StillImageProbeError.dimensionLimit(width:width,height:height,maxDimension:limits.maxDimension,maxPixels:limits.maxPixels)
        }
        let (estimate,o)=pixels.multipliedReportingOverflow(by:24)
        guard !o,estimate<=limits.estimatedDecodeBytes else{throw StillImageProbeError.resourceLimit}
        return pixels
    }
    static func crc(_ bytes:Data)->UInt32 {
        bytes.withUnsafeBytes { raw in
            let buffer=raw.bindMemory(to:UInt8.self)
            var value:uLong=0
            var offset=0
            // Bound each C length even when this helper is called outside file admission.
            while offset<buffer.count {
                let count=min(65_536,buffer.count-offset)
                value=zlib.crc32(value,buffer.baseAddress!.advanced(by:offset),uInt(count))
                offset+=count
            }
            return UInt32(truncatingIfNeeded:value)
        }
    }
    static func adler(_ bytes:UnsafeBufferPointer<UInt8>)->UInt32 {
        var value:uLong=1
        var offset=0
        while offset<bytes.count {
            let count=min(65_536,bytes.count-offset)
            value=zlib.adler32(value,bytes.baseAddress!.advanced(by:offset),uInt(count))
            offset+=count
        }
        return UInt32(truncatingIfNeeded:value)
    }
    /// A deliberately small MPF admission rule, not a general MPO/auxiliary decoder.
    /// ImageIO may expose only one frame even for an unsupported MPF sequence.
    private static func admitMPF(_ payload:Data,tiffFileOffset:Int,file:Data,limits:Limits)throws {
        guard payload.count>=12 else{throw StillImageProbeError.malformed}
        let t=payload.subdata(in:4..<payload.count),little=t.starts(with:[73,73])
        guard little || t.starts(with:[77,77]) else{throw StillImageProbeError.malformed}
        func read(_ offset:Int,_ count:Int)throws->Int {
            guard offset>=0,count>0,offset<=t.count-count else{throw StillImageProbeError.malformed}
            let bytes=t[offset..<offset+count]
            return (little ? Array(bytes.reversed()):Array(bytes)).reduce(0){($0<<8)|Int($1)}
        }
        guard try read(2,2)==42 else{throw StillImageProbeError.malformed}
        let ifd=try read(4,4),tags=try read(ifd,2)
        guard tags<=64 else{throw StillImageProbeError.resourceLimit}
        var imageCount:Int?,entriesOffset:Int?,entriesBytes:Int?
        for index in 0..<tags {
            let entry=ifd+2+index*12,tag=try read(entry,2)
            if tag==0xb001 {
                guard imageCount==nil,try read(entry+2,2)==4,try read(entry+4,4)==1 else{throw StillImageProbeError.malformed}
                imageCount=try read(entry+8,4)
            }else if tag==0xb002 {
                guard entriesOffset==nil,try read(entry+2,2)==7 else{throw StillImageProbeError.malformed}
                entriesBytes=try read(entry+4,4);entriesOffset=try read(entry+8,4)
            }
        }
        guard let count=imageCount,let offset=entriesOffset,let bytes=entriesBytes,count>0 else{throw StillImageProbeError.malformed}
        guard count<=2 else{throw StillImageProbeError.multiImage}
        guard bytes==count*16,offset<=t.count-bytes else{throw StillImageProbeError.malformed}
        var previousEnd=0
        for index in 0..<count {
            let entry=offset+index*16,attributes=try read(entry,4),length=try read(entry+4,4),relative=try read(entry+8,4)
            let start=index==0 ? 0:tiffFileOffset+relative
            guard length>=4,start>=0,start<=file.count-length,start>=previousEnd,
                  file[start]==0xff,file[start+1]==0xd8,
                  file[start+length-2]==0xff,file[start+length-1]==0xd9 else{throw StillImageProbeError.malformed}
            guard (attributes>>24)&7==0 else{throw StillImageProbeError.multiImage}
            let type=attributes&0x00ffffff
            if index==0 {
                guard relative==0,type==0x030000 else{throw StillImageProbeError.multiImage}
            }else {
                guard [0,0x050000].contains(type),try hasKnownGainMapHeader(file,start:start,length:length,limits:limits) else{throw StillImageProbeError.multiImage}
            }
            previousEnd=start+length
        }
        guard previousEnd==file.count else{throw StillImageProbeError.malformed}
    }
    /// Inspect only bounded JPEG headers. Never request auxiliary ImageIO pixel data.
    private static func hasKnownGainMapHeader(_ file:Data,start:Int,length:Int,limits:Limits)throws->Bool {
        let end=start+length,headerEnd=min(end,start+65_536)
        var k=start+2,known=false,validSize=false
        while k+1<headerEnd {
            guard file[k]==0xff else{throw StillImageProbeError.malformed}
            while k<headerEnd && file[k]==0xff{k+=1}
            guard k<headerEnd else{throw StillImageProbeError.malformed}
            let marker=file[k];k+=1
            if marker==0xda{return known && validSize}
            if marker==0xd9{throw StillImageProbeError.malformed}
            guard k+2<=headerEnd else{throw StillImageProbeError.malformed}
            let n=Int(file[k])*256+Int(file[k+1])
            guard n>=2,n<=headerEnd-k else{throw StillImageProbeError.malformed}
            let segment=file.subdata(in:k+2..<k+n)
            if marker==0xe1,segment.starts(with:Data("http://ns.adobe.com/xap/1.0/\0".utf8)) {
                known = known || (segment.range(of:Data("http://ns.adobe.com/hdr-gain-map/1.0/".utf8)) != nil &&
                    segment.range(of:Data("urn:com:apple:photo:2020:aux:hdrgainmap".utf8)) != nil)
            }
            if [0xc0,0xc1,0xc2].contains(marker) {
                guard segment.count>=6,segment[0]==8 else{throw StillImageProbeError.malformed}
                _ = try pixelAdmission(width:Int(segment[3])*256+Int(segment[4]),height:Int(segment[1])*256+Int(segment[2]),limits:limits)
                validSize=true
            }
            k+=n
        }
        return false
    }
    static func inspect(_ url:URL,limits:Limits=Limits())throws->Metadata {
        try Task.checkCancellation()
        guard url.isFileURL,limits.fileBytes>0,limits.fileBytes<64*1024*1024,let identity=FileIdentity.of(url) else{throw StillImageProbeError.unreadable}
        guard identity.size>0,identity.size<=limits.fileBytes else{throw StillImageProbeError.resourceLimit}
        let handle:FileHandle
        do{handle=try FileHandle(forReadingFrom:url)}catch{throw StillImageProbeError.unreadable}
        defer{try? handle.close()}
        let data:Data
        do{data=try handle.read(upToCount:limits.fileBytes+1) ?? Data()}catch{throw StillImageProbeError.unreadable}
        guard data.count<=limits.fileBytes else{throw StillImageProbeError.resourceLimit}
        try Task.checkCancellation()
        let encoding:StillImageDescriptor.Encoding
        var alpha=false,depth=8,icc:Data?,indexed=false,explicitSRGB=false
        var standardChromaticities=false,standardGamma=false
        var iccParts=[Int:Data](),iccCount:Int?,exifOrientation:Int?
        if data.starts(with:[137,80,78,71,13,10,26,10]) {
            encoding = .png;var k=8,header=false,end=false,idat=false
            func u32(_ offset:Int)->UInt32 {data[offset..<offset+4].reduce(0){($0<<8)|UInt32($1)}}
            while k+12<=data.count {
                let n=Int(u32(k));guard n<=data.count-k-12 else{throw StillImageProbeError.malformed}
                let tag=String(bytes:data[k+4..<k+8],encoding:.ascii) ?? ""
                guard crc(data.subdata(in:k+4..<k+8+n))==u32(k+8+n) else{throw StillImageProbeError.malformed}
                if !header && tag != "IHDR"{throw StillImageProbeError.malformed}
                if ["acTL","fcTL","fdAT"].contains(tag){throw StillImageProbeError.animated}
                if ["cICP","mDCv","cLLi"].contains(tag){throw StillImageProbeError.unsupportedProfile}
                if tag=="IHDR" {
                    guard !header,n==13 else{throw StillImageProbeError.malformed};header=true
                    _ = try pixelAdmission(width:Int(u32(k+8)),height:Int(u32(k+12)),limits:limits)
                    depth=Int(data[k+16]);let color=data[k+17]
                    guard [0,2,3,4,6].contains(color) else{throw StillImageProbeError.unsupportedColor}
                    guard (color==3 && [1,2,4,8].contains(depth)) || depth==8 else{throw StillImageProbeError.unsupportedDepth}
                    alpha = color==4 || color==6;indexed = color==3
                }
                if tag=="tRNS"{alpha=true}
                if tag=="sRGB"{guard n==1,data[k+8]<=3 else{throw StillImageProbeError.unsupportedProfile};explicitSRGB=true}
                // Bound ICC inflate separately; only recognized sRGB/Display P3 is admitted.
                if tag=="iCCP" {
                    let payload=data.subdata(in:k+8..<k+8+n)
                    guard icc==nil,let zero=payload.firstIndex(of:0),zero>0,zero<=79,zero+4<payload.count,payload[zero+1]==0 else{throw StillImageProbeError.unsupportedProfile}
                    let compressed=payload.subdata(in:zero+2..<payload.count)
                    guard compressed.count>6 else{throw StillImageProbeError.unsupportedProfile}
                    var decoded=[UInt8](repeating:0,count:1_048_576)
                    let count=decoded.withUnsafeMutableBufferPointer{dest in compressed.withUnsafeBytes{src in compression_decode_buffer(dest.baseAddress!,dest.count,src.baseAddress!.assumingMemoryBound(to:UInt8.self)+2,src.count-6,nil,COMPRESSION_ZLIB)}}
                    guard count>0,count<decoded.count,(Int(compressed[0])*256+Int(compressed[1]))%31==0 else{throw StillImageProbeError.unsupportedProfile}
                    var a:UInt32=1,b:UInt32=0;for byte in decoded.prefix(count){a=(a+UInt32(byte))%65521;b=(b+a)%65521}
                    guard compressed.suffix(4).reduce(UInt32(0),{($0<<8)|UInt32($1)})==(b<<16)|a else{throw StillImageProbeError.unsupportedProfile}
                    icc=Data(decoded.prefix(count))
                }
                if tag=="gAMA" {
                    guard !standardGamma,n==4,u32(k+8)==45455 else{throw StillImageProbeError.unsupportedProfile}
                    standardGamma=true
                }
                if tag=="cHRM" {
                    // PNG's standard sRGB white point and primaries, not arbitrary RGB profiles.
                    // https://www.w3.org/TR/png-3/#11sRGB (gAMA/cHRM values for sRGB).
                    let srgb: [UInt32] = [31270,32900,64000,33000,30000,60000,15000,6000]
                    guard !standardChromaticities,!idat,n==32,
                          (0..<8).map({u32(k+8+$0*4)})==srgb else{throw StillImageProbeError.unsupportedProfile}
                    standardChromaticities=true
                }
                if tag=="IDAT"{idat=true}
                k+=n+12
                if tag=="IEND"{guard n==0,k==data.count else{throw StillImageProbeError.malformed};end=true;break}
            }
            guard header,end,idat else{throw StillImageProbeError.malformed}
        } else if data.starts(with:[255,216,255]) {
            encoding = .jpeg
            guard data.count>=4,data.suffix(2)==Data([255,217]) else{throw StillImageProbeError.malformed}
            // Bounded pre-SOS segment validation, EXIF orientation and segmented ICC.
            var k=2
            var mpf:(Data,Int)?
            while k+1<data.count {
                guard data[k]==255 else{throw StillImageProbeError.malformed}
                while k<data.count && data[k]==255{k+=1}
                guard k<data.count else{throw StillImageProbeError.malformed};let marker=data[k];k+=1
                if marker==0xda || marker==0xd9{break}
                guard k+2<=data.count else{throw StillImageProbeError.malformed}
                let n=Int(data[k])*256+Int(data[k+1]);guard n>=2,n<=data.count-k else{throw StillImageProbeError.malformed}
                let payload=data.subdata(in:k+2..<k+n)
                if marker==0xe1 && payload.starts(with:Data("Exif\0\0".utf8)) {
                    let t=payload.subdata(in:6..<payload.count)
                    guard t.count>=8 else{throw StillImageProbeError.malformed}
                    let little=t.starts(with:[73,73]);guard little || t.starts(with:[77,77]) else{throw StillImageProbeError.malformed}
                    func read(_ offset:Int,_ count:Int)throws->Int {
                        guard offset>=0,offset<=t.count-count else{throw StillImageProbeError.malformed}
                        let bytes=t[offset..<offset+count];return (little ? Array(bytes.reversed()):Array(bytes)).reduce(0){($0<<8)|Int($1)}
                    }
                    guard try read(2,2)==42 else{throw StillImageProbeError.malformed}
                    let start=try read(4,4),entries=try read(start,2)
                    guard entries<=1024 else{throw StillImageProbeError.resourceLimit}
                    for i in 0..<entries {
                        let entry=start+2+i*12
                        if try read(entry,2)==0x112 {
                            guard try read(entry+2,2)==3,try read(entry+4,4)==1 else{throw StillImageProbeError.orientation}
                            let o=try read(entry+8,2);guard (1...8).contains(o),exifOrientation==nil || exifOrientation==o else{throw StillImageProbeError.orientation};exifOrientation=o
                        }
                    }
                }
                // MPF may carry a thumbnail/gain map. It is not another user-visible
                // frame merely by existing. ImageIO's primary count is checked below;
                // auxiliary pixels are neither decoded nor applied here.
                if marker==0xe2 && payload.starts(with:Data("MPF\0".utf8)) {
                    guard mpf==nil else{throw StillImageProbeError.malformed}
                    mpf=(payload,k+6)
                }
                if [0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf].contains(marker) {
                    guard payload.count>=6 else{throw StillImageProbeError.malformed}
                    let h=Int(payload[1])*256+Int(payload[2]),w=Int(payload[3])*256+Int(payload[4])
                    // A zero SOF height can be supplied by DNL later; retain the existing
                    // ImageIO admission path for those files rather than inventing a size.
                    if w>0,h>0{_ = try pixelAdmission(width:w,height:h,limits:limits)}
                }
                if marker==0xe2 && payload.starts(with:Data("ICC_PROFILE\0".utf8)) {
                    guard payload.count>=14 else{throw StillImageProbeError.unsupportedProfile}
                    let index=Int(payload[12]),count=Int(payload[13])
                    guard index>0,index<=count,count<=64,iccParts[index]==nil,iccCount==nil || iccCount==count else{throw StillImageProbeError.unsupportedProfile}
                    iccCount=count;iccParts[index]=payload.subdata(in:14..<payload.count)
                }
                k+=n
            }
            if let (payload,offset)=mpf{try admitMPF(payload,tiffFileOffset:offset,file:data,limits:limits)}
        } else{throw StillImageProbeError.invalidSignature}
        if let count=iccCount {guard iccParts.count==count else{throw StillImageProbeError.unsupportedProfile};icc=Data();for i in 1...count{icc!.append(iccParts[i]!)}}
        let embeddedProfile=try icc.map(admittedICC)
        // Chromaticities alone do not establish the transfer function.
        guard !standardChromaticities || standardGamma || explicitSRGB || icc != nil else{throw StillImageProbeError.unsupportedProfile}
        let ext=url.pathExtension.lowercased()
        guard (encoding == .png && ext=="png") || (encoding == .jpeg && ["jpg","jpeg"].contains(ext)) else{throw StillImageProbeError.typeMismatch}
        guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary) else{throw StillImageProbeError.malformed}
        let imageCount=CGImageSourceGetCount(source)
        guard imageCount>0 else{throw StillImageProbeError.malformed}
        guard imageCount==1 else{throw StillImageProbeError.multiImage}
        guard (CGImageSourceGetType(source) as String?)==(encoding == .png ? "public.png":"public.jpeg"),
            let p=CGImageSourceCopyPropertiesAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary) as? [String:Any],
            let w=p[kCGImagePropertyPixelWidth as String] as? Int,let h=p[kCGImagePropertyPixelHeight as String] as? Int else{throw StillImageProbeError.malformed}
        _ = try pixelAdmission(width:w,height:h,limits:limits)
        let orientation=exifOrientation ?? (p[kCGImagePropertyOrientation as String] as? Int ?? 1)
        guard (1...8).contains(orientation) else{throw StillImageProbeError.orientation}
        let model=p[kCGImagePropertyColorModel as String] as? String ?? "unknown"
        guard ["RGB","Gray","Indexed"].contains(model) else{throw StillImageProbeError.unsupportedColor}
        if encoding == .jpeg{depth=p[kCGImagePropertyDepth as String] as? Int ?? 0;guard depth==8 else{throw StillImageProbeError.unsupportedDepth}}
        let profile=p[kCGImagePropertyProfileName as String] as? String
        guard icc != nil || profile==nil || profile!.localizedCaseInsensitiveContains("srgb") else{throw StillImageProbeError.unsupportedProfile}
        guard FileIdentity.of(url)==identity else{throw StillImageProbeError.changed}
        let d=StillImageDescriptor(contractVersion:1,encoding:encoding,width:w,height:h,orientation:orientation,displayWidth:orientation>=5 ? h:w,displayHeight:orientation>=5 ? w:h,componentBitDepth:indexed ? 8:depth,encodedSampleBitDepth:depth,colorModel:model,profileName:profile,profileSHA256:icc.map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()},profileDisposition:embeddedProfile ?? (explicitSRGB ? "explicit-sRGB":"assumed-sRGB"),alphaCapability:alpha || (p[kCGImagePropertyHasAlpha as String] as? Bool ?? false),identity:identity)
        return Metadata(descriptor:d,encodedSHA256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),data:data,url:url,limits:limits)
    }
    /// Required PNG pixel-stream integrity only; ImageIO may recover damaged IDAT silently.
    /// Metadata already admitted the immutable encoded snapshot and dimensions.
    @inline(never) private static func validatePNGImageData(_ m:Metadata)throws {
        guard m.descriptor.encoding == .png else{return}
        let data=m.data,w=m.descriptor.width,h=m.descriptor.height
        func u32(_ k:Int)->Int{data[k..<k+4].reduce(0){($0<<8)|Int($1)}}
        let channels:[UInt8:Int]=[0:1,2:3,3:1,4:2,6:4]
        guard data.count>=33,let c=channels[data[25]],data[28]<=1 else{throw StillImageProbeError.malformed}
        let bits=c*Int(data[24]);var rowBytes=[Int]()
        let passes = data[28]==0 ? [(0,0,1,1)]:[(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)]
        for (x,y,dx,dy) in passes where w>x && h>y {
            let pw=(w-x+dx-1)/dx,ph=(h-y+dy-1)/dy
            rowBytes.append(contentsOf:repeatElement((pw*bits+7)/8,count:ph))
        }
        let expected=rowBytes.reduce(0){$0+$1+1}
        guard expected>0,expected<m.limits.estimatedDecodeBytes else{throw StillImageProbeError.resourceLimit}
        var compressed=Data(),k=8,seen=false,closed=false
        while k+12<=data.count {
            try Task.checkCancellation()
            let n=u32(k);guard n<=data.count-k-12 else{throw StillImageProbeError.malformed}
            if data[k+4..<k+8]==Data("IDAT".utf8) {
                guard !closed else{throw StillImageProbeError.malformed};seen=true;compressed.append(data[k+8..<k+8+n])
            }else if seen{closed=true}
            k+=n+12
        }
        guard compressed.count>6,compressed[0]&15==8,compressed[0]>>4<=7,
              (Int(compressed[0])*256+Int(compressed[1]))%31==0,compressed[1]&32==0 else{throw StillImageProbeError.malformed}
        var stream=z_stream()
        let initialization=inflateInit_(&stream,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))
        guard initialization==Z_OK else{throw StillImageProbeError.resourceLimit}
        defer{inflateEnd(&stream)}
        // Full zlib framing validates Adler-32 and exposes the exact unused input.
        // Both input and output are offered in bounded increments for cancellation.
        var output=[UInt8](repeating:0,count:expected+1),written=0
        try compressed.withUnsafeBytes{source in
            try output.withUnsafeMutableBufferPointer{dest in
                var offered=0
                while true {
                    try Task.checkCancellation()
                    if stream.avail_in==0 && offered<source.count {
                        let n=min(4096,source.count-offered)
                        stream.next_in=UnsafeMutablePointer(mutating:source.baseAddress!.assumingMemoryBound(to:UInt8.self)+offered)
                        stream.avail_in=uInt(n);offered+=n
                    }
                    let produced=Int(stream.total_out)
                    guard produced<dest.count else{throw StillImageProbeError.malformed}
                    stream.next_out=dest.baseAddress!+produced
                    stream.avail_out=uInt(min(4096,dest.count-produced))
                    let previousInput=stream.total_in,previousOutput=stream.total_out
                    let status=inflate(&stream,Z_NO_FLUSH)
                    if status==Z_STREAM_END {
                        guard offered==source.count,stream.avail_in==0,
                              stream.total_in==source.count else{throw StillImageProbeError.malformed}
                        written=Int(stream.total_out);break
                    }
                    if status==Z_MEM_ERROR{throw StillImageProbeError.resourceLimit}
                    guard status==Z_OK,
                          stream.total_in>previousInput || stream.total_out>previousOutput else{throw StillImageProbeError.malformed}
                }
            }
        }
        guard written==expected else{throw StillImageProbeError.malformed}
        let actualChecksum=output.withUnsafeBufferPointer { bytes in
            adler(UnsafeBufferPointer(start:bytes.baseAddress,count:written))
        }
        let checksum=compressed.suffix(4).reduce(UInt32(0)){($0<<8)|UInt32($1)}
        guard checksum==actualChecksum else{throw StillImageProbeError.malformed}
        var offset=0
        for n in rowBytes {guard output[offset]<=4 else{throw StillImageProbeError.malformed};offset+=n+1}
        try Task.checkCancellation()
    }
    /// Caller owns file-access/security scope through both phases. Metadata is not import approval.
    static let validator=Validator()
    actor Validator {
        private struct Key:Equatable {
            let url:String,identity:FileIdentity,encodedSHA256:String,limits:Limits
        }
        private struct Entry {let key:Key,value:Validation}
        private var recent=[Entry]()
        private var fullDecodes=0,proxyDecodes=0,cacheHits=0
        struct Diagnostics:Sendable {
            let fullDecodes:Int,proxyDecodes:Int,cacheHits:Int,cachedResults:Int
            let retainedDecodedBytes:Int
        }
        func diagnostics()->Diagnostics {
            .init(fullDecodes:fullDecodes,proxyDecodes:proxyDecodes,cacheHits:cacheHits,cachedResults:recent.count,retainedDecodedBytes:0)
        }
        /// Serial synchronous decode section; hook is an internal deterministic cancellation/identity seam.
        func validate(_ m:Metadata,beforeDecode:@Sendable ()async throws->Void = {})async throws->Validation {
            try await beforeDecode();try Task.checkCancellation()
            guard FileIdentity.of(m.url)==m.descriptor.identity else{throw StillImageProbeError.changed}
            let key=Key(url:m.url.standardizedFileURL.path,identity:m.descriptor.identity,encodedSHA256:m.encodedSHA256,limits:m.limits)
            // A fresh inspect still reads/checks immutable encoded bytes on every request.
            // Cache only the small completed validation result, never source/full pixels.
            recent.removeAll{$0.key.url==key.url && $0.key != key}
            if let index=recent.firstIndex(where:{$0.key==key}) {
                let entry=recent.remove(at:index);recent.append(entry);cacheHits+=1
                try Task.checkCancellation()
                return entry.value
            }
            try StillImageProbe.validatePNGImageData(m)
            fullDecodes+=1
            // Keep full primary validation, but end its source/cache/image ownership
            // before creating the oriented proxy and RGBA conversion buffers.
            try autoreleasepool {
                var options=StillImageProbe.sdrDecodeOptions
                options[kCGImageSourceShouldCacheImmediately]=true
                guard let source=CGImageSourceCreateWithData(m.data as CFData,StillImageProbe.sdrDecodeOptions as CFDictionary),
                      CGImageSourceGetCount(source)==1,
                      let image=CGImageSourceCreateImageAtIndex(source,0,options as CFDictionary),
                      image.width==m.descriptor.width,image.height==m.descriptor.height,
                      CGImageSourceGetStatus(source) == .statusComplete,CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else{throw StillImageProbeError.malformed}
                guard image.bitsPerComponent==8,!image.bitmapInfo.contains(.floatComponents),let color=image.colorSpace,[CGColorSpaceModel.rgb,.monochrome,.indexed].contains(color.model) else{throw StillImageProbeError.unsupportedColor}
            }
            try Task.checkCancellation()
            guard FileIdentity.of(m.url)==m.descriptor.identity else{throw StillImageProbeError.changed}
            proxyDecodes+=1
            let result=try autoreleasepool {try normalizedProxy(m)}
            try Task.checkCancellation();guard FileIdentity.of(m.url)==m.descriptor.identity else{throw StillImageProbeError.changed}
            recent.append(.init(key:key,value:result))
            if recent.count>8{recent.removeFirst(recent.count-8)}
            return result
        }
        private func normalizedProxy(_ m:Metadata)throws->Validation {
            let expected=StillImageProbe.proxySize(for:m.descriptor,maxDimension:StillImageProbe.validationProxyMaxDimension)
            var options=StillImageProbe.sdrDecodeOptions
            options[kCGImageSourceCreateThumbnailFromImageAlways]=true
            options[kCGImageSourceCreateThumbnailWithTransform]=true
            options[kCGImageSourceThumbnailMaxPixelSize]=StillImageProbe.validationProxyMaxDimension
            guard let source=CGImageSourceCreateWithData(m.data as CFData,StillImageProbe.sdrDecodeOptions as CFDictionary),
                let transformed=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary),
                transformed.width>0,transformed.height>0,
                max(transformed.width,transformed.height)<=StillImageProbe.validationProxyMaxDimension,
                abs(transformed.width-expected.width)<=1,abs(transformed.height-expected.height)<=1,
                let sRGB=CGColorSpace(name:CGColorSpace.sRGB),let c=CGContext(data:nil,width:transformed.width,height:transformed.height,bitsPerComponent:8,bytesPerRow:transformed.width*4,space:sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let address=c.data else{throw StillImageProbeError.resourceLimit}
            c.interpolationQuality = .none;c.draw(transformed,in:CGRect(x:0,y:0,width:transformed.width,height:transformed.height))
            let bytes=address.assumingMemoryBound(to:UInt8.self);var transparent=false
            for k in stride(from:3,to:transformed.width*transformed.height*4,by:4){if bytes[k]<255{transparent=true;break}}
            return Validation(descriptor:m.descriptor,normalizedWidth:transformed.width,normalizedHeight:transformed.height,normalizedRGBABytes:transformed.width*transformed.height*4,hasTransparentPixels:transparent)
        }
    }
}
