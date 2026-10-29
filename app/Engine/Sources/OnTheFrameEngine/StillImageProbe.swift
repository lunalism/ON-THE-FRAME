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

enum StillImageProbeError:Error,Equatable {
    case unreadable,invalidSignature,typeMismatch,multiImage,orientation,dimensions
    case unsupportedDepth,unsupportedColor,unsupportedProfile,animated,malformed,resourceLimit,changed
}

enum StillImageProbe {
    /// Provisional admission limits, NOT approved product policy or a decoder sandbox.
    struct Limits:Sendable {
        var fileBytes=8*1024*1024,maxDimension=2048,maxPixels=4_194_304,estimatedDecodeBytes=128*1024*1024
    }
    struct Metadata:Sendable {
        let descriptor:StillImageDescriptor
        fileprivate let data:Data,url:URL,limits:Limits
    }
    struct Validation:Sendable {
        let descriptor:StillImageDescriptor
        let normalizedWidth:Int,normalizedHeight:Int,normalizedRGBABytes:Int
        let hasTransparentPixels:Bool
    }
    static func pixelAdmission(width:Int,height:Int,limits:Limits)throws->Int {
        guard width>0,height>0 else{throw StillImageProbeError.dimensions}
        let (pixels,overflow)=width.multipliedReportingOverflow(by:height)
        guard !overflow,width<=limits.maxDimension,height<=limits.maxDimension,pixels<=limits.maxPixels else{throw StillImageProbeError.resourceLimit}
        let (estimate,o)=pixels.multipliedReportingOverflow(by:24)
        guard !o,estimate<=limits.estimatedDecodeBytes else{throw StillImageProbeError.resourceLimit}
        return pixels
    }
    static func crc(_ bytes:Data)->UInt32 {
        var c:UInt32=0xffffffff
        for b in bytes {c ^= UInt32(b);for _ in 0..<8{c=(c>>1) ^ (c&1==1 ? 0xedb88320:0)}}
        return c ^ 0xffffffff
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
                // Bound ICC inflate separately; only the canonical sRGB profile is admitted.
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
                if tag=="gAMA" {guard n==4,u32(k+8)==45455 else{throw StillImageProbeError.unsupportedProfile}}
                if tag=="cHRM"{throw StillImageProbeError.unsupportedProfile}
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
                if marker==0xe2 && payload.starts(with:Data("MPF\0".utf8)){throw StillImageProbeError.multiImage}
                if marker==0xe2 && payload.starts(with:Data("ICC_PROFILE\0".utf8)) {
                    guard payload.count>=14 else{throw StillImageProbeError.unsupportedProfile}
                    let index=Int(payload[12]),count=Int(payload[13])
                    guard index>0,index<=count,count<=64,iccParts[index]==nil,iccCount==nil || iccCount==count else{throw StillImageProbeError.unsupportedProfile}
                    iccCount=count;iccParts[index]=payload.subdata(in:14..<payload.count)
                }
                k+=n
            }
        } else{throw StillImageProbeError.invalidSignature}
        if let count=iccCount {guard iccParts.count==count else{throw StillImageProbeError.unsupportedProfile};icc=Data();for i in 1...count{icc!.append(iccParts[i]!)}}
        if let icc {
            guard icc.count<=1_048_576,let standard=CGColorSpace(name:CGColorSpace.sRGB),let reference=standard.copyICCData(),icc==(reference as Data),CGColorSpace(iccData:icc as CFData) != nil else{throw StillImageProbeError.unsupportedProfile}
        }
        let ext=url.pathExtension.lowercased()
        guard (encoding == .png && ext=="png") || (encoding == .jpeg && ["jpg","jpeg"].contains(ext)) else{throw StillImageProbeError.typeMismatch}
        guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source)==1 else{throw StillImageProbeError.multiImage}
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
        let d=StillImageDescriptor(contractVersion:1,encoding:encoding,width:w,height:h,orientation:orientation,displayWidth:orientation>=5 ? h:w,displayHeight:orientation>=5 ? w:h,componentBitDepth:indexed ? 8:depth,encodedSampleBitDepth:depth,colorModel:model,profileName:profile,profileSHA256:icc.map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()},profileDisposition:icc != nil ? "embedded-sRGB-ICC":(explicitSRGB ? "explicit-sRGB":"assumed-sRGB"),alphaCapability:alpha || (p[kCGImagePropertyHasAlpha as String] as? Bool ?? false),identity:identity)
        return Metadata(descriptor:d,data:data,url:url,limits:limits)
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
        var a:UInt32=1,b:UInt32=0
        for byte in output.prefix(written){a=(a+UInt32(byte))%65521;b=(b+a)%65521}
        let checksum=compressed.suffix(4).reduce(UInt32(0)){($0<<8)|UInt32($1)}
        guard checksum==((b<<16)|a) else{throw StillImageProbeError.malformed}
        var offset=0
        for n in rowBytes {guard output[offset]<=4 else{throw StillImageProbeError.malformed};offset+=n+1}
        try Task.checkCancellation()
    }
    /// Caller owns file-access/security scope through both phases. Metadata is not import approval.
    static let validator=Validator()
    actor Validator {
        /// Serial synchronous decode section; hook is an internal deterministic cancellation/identity seam.
        func validate(_ m:Metadata,beforeDecode:@Sendable ()async throws->Void = {})async throws->Validation {
            try await beforeDecode();try Task.checkCancellation()
            guard FileIdentity.of(m.url)==m.descriptor.identity else{throw StillImageProbeError.changed}
            try StillImageProbe.validatePNGImageData(m)
            guard let source=CGImageSourceCreateWithData(m.data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true,kCGImageSourceShouldAllowFloat:false] as CFDictionary),
                  CGImageSourceGetStatus(source) == .statusComplete,CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else{throw StillImageProbeError.malformed}
            guard image.bitsPerComponent==8,!image.bitmapInfo.contains(.floatComponents),let color=image.colorSpace,[CGColorSpaceModel.rgb,.monochrome,.indexed].contains(color.model) else{throw StillImageProbeError.unsupportedColor}
            guard let transformed=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(m.descriptor.width,m.descriptor.height)] as CFDictionary),transformed.width==m.descriptor.displayWidth,transformed.height==m.descriptor.displayHeight,
                let sRGB=CGColorSpace(name:CGColorSpace.sRGB),let c=CGContext(data:nil,width:transformed.width,height:transformed.height,bitsPerComponent:8,bytesPerRow:transformed.width*4,space:sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let address=c.data else{throw StillImageProbeError.resourceLimit}
            c.interpolationQuality = .none;c.draw(transformed,in:CGRect(x:0,y:0,width:transformed.width,height:transformed.height))
            let bytes=address.assumingMemoryBound(to:UInt8.self);var transparent=false
            for k in stride(from:3,to:transformed.width*transformed.height*4,by:4){if bytes[k]<255{transparent=true;break}}
            try Task.checkCancellation();guard FileIdentity.of(m.url)==m.descriptor.identity else{throw StillImageProbeError.changed}
            return Validation(descriptor:m.descriptor,normalizedWidth:transformed.width,normalizedHeight:transformed.height,normalizedRGBABytes:transformed.width*transformed.height*4,hasTransparentPixels:transparent)
        }
    }
}
