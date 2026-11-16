import XCTest
import ImageIO
import CoreGraphics
import Darwin
@testable import OnTheFrameEngine

final class StillImageProbeTests:XCTestCase {
    var root:URL!
    override func setUpWithError()throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_STILL_PROBE_RUN"] else{throw XCTSkip("probe foundation opt-in")}
        root=URL(fileURLWithPath:path).appendingPathComponent(name.components(separatedBy:" ").last!.replacingOccurrences(of:"]",with:""))
        guard !FileManager.default.fileExists(atPath:root.path) else{throw StillImageProbeError.unreadable}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    func be(_ n:UInt32)->Data{Data([UInt8(n>>24),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)])}
    func testChecksumsMatchIndependentReferenceAcrossBlockBoundaries() {
        func referenceCRC(_ bytes:Data)->UInt32 {
            var value:UInt32=0xffffffff
            for byte in bytes {
                value ^= UInt32(byte)
                for _ in 0..<8 { value=(value>>1) ^ (value&1==1 ? 0xedb88320:0) }
            }
            return value ^ 0xffffffff
        }
        func referenceAdler(_ bytes:Data)->UInt32 {
            var a:UInt32=1,b:UInt32=0
            for byte in bytes { a=(a+UInt32(byte))%65521;b=(b+a)%65521 }
            return (b<<16)|a
        }
        func adler(_ data:Data)->UInt32 {
            data.withUnsafeBytes { StillImageProbe.adler($0.bindMemory(to:UInt8.self)) }
        }
        let standard=Data("123456789".utf8)
        XCTAssertEqual(StillImageProbe.crc(Data()),0)
        XCTAssertEqual(adler(Data()),1)
        XCTAssertEqual(StillImageProbe.crc(standard),0xcbf43926)
        XCTAssertEqual(adler(standard),0x091e01de)
        for length in [0,1,31,4096,65_535,65_536,65_537] {
            let data=Data((0..<length).map { UInt8(truncatingIfNeeded:($0*37)^($0>>3)) })
            XCTAssertEqual(StillImageProbe.crc(data),referenceCRC(data),"CRC length \(length)")
            XCTAssertEqual(adler(data),referenceAdler(data),"Adler length \(length)")
        }
    }
    func testPNGChunkChecksumCorruptionRemainsRejected() throws {
        let valid=try png("valid-crc.png"),original=try Data(contentsOf:valid)
        var corrupt=original
        corrupt[29] ^= 1 // First IHDR CRC byte; keep signature, length, type and pixels intact.
        let invalid=root.appendingPathComponent("invalid-crc.png")
        try corrupt.write(to:invalid)
        XCTAssertThrowsError(try StillImageProbe.inspect(invalid)) {
            XCTAssertEqual($0 as? StillImageProbeError,.malformed)
        }
        XCTAssertEqual(try Data(contentsOf:valid),original)
        XCTAssertEqual(try Data(contentsOf:invalid),corrupt)
    }
    func chunk(_ name:String,_ payload:Data)->Data{let body=Data(name.utf8)+payload;return be(UInt32(payload.count))+body+be(StillImageProbe.crc(body))}
    func png(_ name:String="image.png",color:UInt8=2,depth:UInt8=8,transparent:Bool=false,extra:Data=Data())throws->URL {
        let channels=[0:1,2:3,3:1,4:2,6:4][Int(color)]!,scan=Data([0]+Array(repeating:UInt8(0),count:channels))
        var a:UInt32=1,b:UInt32=0;for v in scan{a=(a+UInt32(v))%65521;b=(b+a)%65521}
        let n=UInt16(scan.count),z=Data([0x78,1,1,UInt8(n&255),UInt8(n>>8),UInt8((~n)&255),UInt8((~n)>>8)])+scan+be((b<<16)|a)
        var data=Data([137,80,78,71,13,10,26,10])+chunk("IHDR",be(1)+be(1)+Data([depth,color,0,0,0]))
        if color==3{data += chunk("PLTE",Data([255,0,0,0,255,0]))}
        if transparent{data += chunk("tRNS",color==3 ? Data([0,255]):Data([0,0,0,0,0,0]))}
        data += extra+chunk("IDAT",z)+chunk("IEND",Data())
        let url=root.appendingPathComponent(name);try data.write(to:url);return url
    }
    func jpeg(_ name:String,orientation:Int,space:CGColorSpace?=nil,width:Int=4,height:Int=2)throws->URL {
        let c=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space ?? CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue));c.setFillColor(CGColor(red:0.7,green:0.2,blue:0.1,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
        let url=root.appendingPathComponent(name),dest=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.jpeg" as CFString,1,nil));CGImageDestinationAddImage(dest,try XCTUnwrap(c.makeImage()),[kCGImagePropertyOrientation:orientation] as CFDictionary);XCTAssertTrue(CGImageDestinationFinalize(dest));return url
    }
    func testPreservedTrailingIDAT()async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_PROBE05_TRAILING"] else{throw XCTSkip("preserved trailing fixture required")}
        let u=URL(fileURLWithPath:path),bytes=try Data(contentsOf:u)
        XCTAssertEqual(QA01.sha(bytes),"a273c7e74ddc9402b3b42c8ec86738b4ea301b2f6a06a2a1ee585de42ef44a09")
        let m=try StillImageProbe.inspect(u)
        do{_ = try await StillImageProbe.validator.validate(m);XCTFail("preserved trailing bytes accepted")}catch StillImageProbeError.malformed{}
        XCTAssertEqual(try Data(contentsOf:u),bytes)
    }
    func testPNGStreamBoundariesAndAdam7()async throws {
        func image(_ name:String,_ chunks:Data,width:Int=1,height:Int=1,interlace:UInt8=0)throws->URL {
            let data=Data([137,80,78,71,13,10,26,10])+chunk("IHDR",be(UInt32(width))+be(UInt32(height))+Data([8,2,0,0,interlace]))+chunks+chunk("IEND",Data())
            let url=root.appendingPathComponent(name);try data.write(to:url);return url
        }
        let z=storedZlib(Data([0,0,0,0])),split=z.count/2
        let consecutive=try image("consecutive.png",chunk("IDAT",z.prefix(split))+chunk("IDAT",z.suffix(z.count-split)))
        _ = try await StillImageProbe.validator.validate(StillImageProbe.inspect(consecutive))
        for (name,chunks) in [
            ("discontinuous.png",chunk("IDAT",z.prefix(split))+chunk("tEXt",Data("note\0x".utf8))+chunk("IDAT",z.suffix(z.count-split))),
            ("trailing-deflate.png",chunk("IDAT",z.dropLast(4)+Data([0])+z.suffix(4))),
            ("after-zlib.png",chunk("IDAT",z+Data([0]))),
            ("unoffered-tail.png",chunk("IDAT",z+Data(repeating:0,count:5000))),
            ("second-zlib.png",chunk("IDAT",z+z)),
            ("trailing-new-IDAT.png",chunk("IDAT",z)+chunk("IDAT",Data([0]))),
            ("extra-output.png",chunk("IDAT",storedZlib(Data([0,0,0,0,0]))))] {
            let u=try image(name,chunks),before=try Data(contentsOf:u),m=try StillImageProbe.inspect(u)
            do{_ = try await StillImageProbe.validator.validate(m);XCTFail("invalid stream accepted: \(name)")}catch StillImageProbeError.malformed{}
            XCTAssertEqual(try Data(contentsOf:u),before)
        }
        let ancillary=try image("post-IDAT-text.png",chunk("IDAT",z)+chunk("tEXt",Data("note\0valid".utf8)))
        _ = try await StillImageProbe.validator.validate(StillImageProbe.inspect(ancillary))
        let incremental=try image("incremental-64.png",chunk("IDAT",storedZlib(Data(repeating:0,count:64*(1+64*3)))),width:64,height:64)
        let incrementalResult=try await StillImageProbe.validator.validate(StillImageProbe.inspect(incremental))
        XCTAssertEqual(incrementalResult.normalizedRGBABytes,64*64*4)
        let huge=root.appendingPathComponent("huge-chunk.png")
        try (Data([137,80,78,71,13,10,26,10])+be(UInt32.max)+Data("IHDR".utf8)+Data(repeating:0,count:16)).write(to:huge)
        XCTAssertThrowsError(try StillImageProbe.inspect(huge))
        for size in [1,9] {
            var rows=Data()
            for (x,y,dx,dy) in [(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)] where size>x && size>y {
                let w=(size-x+dx-1)/dx,h=(size-y+dy-1)/dy
                rows += Data(repeating:0,count:h*(1+w*3))
            }
            let u=try image("adam7-\(size).png",chunk("IDAT",storedZlib(rows)),width:size,height:size,interlace:1)
            let v=try await StillImageProbe.validator.validate(StillImageProbe.inspect(u))
            XCTAssertEqual(v.normalizedRGBABytes,size*size*4)
        }
    }
    func testPreservedCorruptPNG()async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_PROBE03_CORRUPT"] else{throw XCTSkip("preserved fixture required")}
        let url=URL(fileURLWithPath:path),bytes=try Data(contentsOf:url)
        XCTAssertEqual(QA01.sha(bytes),"68859130891b0a84d8bd8ff2e14cfdd6b9461eac0f215e4da86513d7e807d3dd")
        let m=try StillImageProbe.inspect(url)
        if ProcessInfo.processInfo.environment["OTF_PROBE03_REPRODUCE"]=="1" {
            let source=try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData,nil))
            let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
            let result=try await StillImageProbe.validator.validate(m)
            print("PROBE03 REPRODUCED unexpected acceptance; imageExists=\(image != nil) sourceStatus=\(CGImageSourceGetStatus(source).rawValue) frameStatus=\(CGImageSourceGetStatusAtIndex(source,0).rawValue) materializedBytes=\(result.normalizedRGBABytes)")
        }else{
            do{_ = try await StillImageProbe.validator.validate(m);XCTFail("preserved corrupt PNG accepted")}catch StillImageProbeError.malformed{}
        }
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testPNGVariantsAndNoMutation()async throws {
        for (i,c,t) in [(0,UInt8(2),false),(1,UInt8(6),false),(2,UInt8(2),true),(3,UInt8(3),true)] {
            let url=try png("v\(i).png",color:c,transparent:t),before=try Data(contentsOf:url),m=try StillImageProbe.inspect(url),v=try await StillImageProbe.validator.validate(m)
            XCTAssertEqual(v.normalizedRGBABytes,4);XCTAssertEqual(v.hasTransparentPixels,c==6 || t);XCTAssertEqual(m.descriptor.alphaCapability,c==6 || t);XCTAssertEqual(try Data(contentsOf:url),before)
        }
    }
    func testJPEGOrientationsAndProfiles()async throws {
        for o in 1...8 {let url=try jpeg("o\(o).jpg",orientation:o),m=try StillImageProbe.inspect(url),v=try await StillImageProbe.validator.validate(m);XCTAssertEqual(m.descriptor.orientation,o);XCTAssertEqual(v.normalizedWidth,o>=5 ? 2:4);XCTAssertEqual(v.normalizedHeight,o>=5 ? 4:2)}
        let p3=try jpeg("p3.jpg",orientation:1,space:CGColorSpace(name:CGColorSpace.displayP3))
        let metadata=try StillImageProbe.inspect(p3)
        XCTAssertEqual(metadata.descriptor.profileDisposition,"embedded-Display-P3-ICC")
        XCTAssertNotNil(metadata.descriptor.profileSHA256)
        _ = try await StillImageProbe.validator.validate(metadata)
        let unsupported=try jpeg("adobe-rgb.jpg",orientation:1,space:CGColorSpace(name:CGColorSpace.adobeRGB1998))
        XCTAssertThrowsError(try StillImageProbe.inspect(unsupported)) {XCTAssertEqual($0 as? StillImageProbeError,.unsupportedProfile)}
    }
    func jpegSegment(_ marker:UInt8,_ payload:Data)->Data {
        let n=payload.count+2
        return Data([0xff,marker,UInt8(n>>8),UInt8(n&255)])+payload
    }
    func le16(_ n:UInt16)->Data { Data([UInt8(n&255),UInt8(n>>8)]) }
    func le32(_ n:UInt32)->Data { Data([UInt8(n&255),UInt8((n>>8)&255),UInt8((n>>16)&255),UInt8(n>>24)]) }
    func withoutGeneratedExif(_ data:Data)throws->Data {
        var result=Data(data.prefix(2)),k=2
        while k+1<data.count {
            guard data[k]==0xff else{throw StillImageProbeError.malformed}
            let begin=k
            while k<data.count && data[k]==0xff{k+=1}
            guard k<data.count else{throw StillImageProbeError.malformed}
            let marker=data[k];k+=1
            if marker==0xda || marker==0xd9 {result.append(data[begin...]);return result}
            guard k+2<=data.count else{throw StillImageProbeError.malformed}
            let n=Int(data[k])*256+Int(data[k+1])
            guard n>=2,n<=data.count-k else{throw StillImageProbeError.malformed}
            let isExif=marker==0xe1 && data[k+2..<k+n].starts(with:Data("Exif\0\0".utf8))
            if !isExif{result.append(data[begin..<k+n])}
            k+=n
        }
        throw StillImageProbeError.malformed
    }
    func testJPEGWithEmbeddedExifThumbnailRemainsSingleImage() async throws {
        let fullURL=try jpeg("exif-full-generated.jpg",orientation:1)
        let thumbURL=try jpeg("exif-thumb-generated.jpg",orientation:1,width:2,height:1)
        let full=try withoutGeneratedExif(Data(contentsOf:fullURL)),thumb=try Data(contentsOf:thumbURL)
        func entry(_ tag:UInt16,_ type:UInt16,_ value:UInt32)->Data {le16(tag)+le16(type)+le32(1)+le32(value)}
        // TIFF IFD0 has orientation 1 and points to IFD1. IFD1 contains a real
        // separately encoded JPEG thumbnail at offset 92 from the TIFF header.
        var tiff=Data([0x49,0x49,0x2a,0])+le32(8)+le16(1)+entry(0x112,3,1)+le32(26)
        tiff += le16(5)+entry(0x100,4,2)+entry(0x101,4,1)+entry(0x103,3,6)
        tiff += entry(0x201,4,92)+entry(0x202,4,UInt32(thumb.count))+le32(0)
        XCTAssertEqual(tiff.count,92);tiff.append(thumb)
        let bytes=Data(full.prefix(2))+jpegSegment(0xe1,Data("Exif\0\0".utf8)+tiff)+Data(full.dropFirst(2))
        let url=root.appendingPathComponent("with-exif-thumbnail.jpg");try bytes.write(to:url)
        let source=try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData,nil))
        XCTAssertEqual(CGImageSourceGetCount(source),1,"ImageIO excludes embedded thumbnails")
        let metadata=try StillImageProbe.inspect(url),validation=try await StillImageProbe.validator.validate(metadata)
        XCTAssertEqual(metadata.descriptor.width,4);XCTAssertEqual(metadata.descriptor.height,2)
        XCTAssertEqual(validation.normalizedWidth,4);XCTAssertEqual(validation.normalizedHeight,2)
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testJPEGDimensionLimitPrecedesUnsupportedMPF() throws {
        // This is a generated declared-MPF negative control, not a claim of a valid MPO.
        let baseline=try Data(contentsOf:jpeg("size-primary-generated.jpg",orientation:1))
        var oversized=baseline,k=2,changed=false
        while k+1<oversized.count {
            guard oversized[k]==0xff else{throw StillImageProbeError.malformed}
            while k<oversized.count && oversized[k]==0xff{k+=1}
            let marker=oversized[k];k+=1
            if marker==0xda || marker==0xd9{break}
            let n=Int(oversized[k])*256+Int(oversized[k+1])
            if marker==0xc0 || marker==0xc2 {
                oversized[k+3]=0x0f;oversized[k+4]=0xa0 // height 4000
                oversized[k+5]=0x13;oversized[k+6]=0x88 // width 5000, beyond provisional cap
                changed=true;break
            }
            k+=n
        }
        XCTAssertTrue(changed,"generated JPEG must contain a supported SOF")
        let marker=jpegSegment(0xe2,Data("MPF\0".utf8))
        let bytes=Data(oversized.prefix(2))+marker+Data(oversized.dropFirst(2))
        let url=root.appendingPathComponent("oversized-declared-mpf.jpg");try bytes.write(to:url)
        XCTAssertThrowsError(try StillImageProbe.inspect(url)) {
            XCTAssertEqual($0 as? StillImageProbeError,.dimensionLimit(width:5000,height:4000,maxDimension:4096,maxPixels:16_777_216))
            XCTAssertTrue($0.localizedDescription.contains("5000×4000"));XCTAssertTrue($0.localizedDescription.contains("4096"))
        }
        let small=root.appendingPathComponent("small-declared-mpf.jpg")
        try (Data(baseline.prefix(2))+marker+Data(baseline.dropFirst(2))).write(to:small)
        XCTAssertThrowsError(try StillImageProbe.inspect(small)) {XCTAssertEqual($0 as? StillImageProbeError,.malformed)}
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testGeneratedTwoIndependentJPEGMPOIsStillRejected() throws {
        let first=try Data(contentsOf:jpeg("mpo-first-generated.jpg",orientation:1,width:4,height:2))
        let second=try Data(contentsOf:jpeg("mpo-second-generated.jpg",orientation:1,width:6,height:3))
        // Valid MP Index layout: TIFF header 8 + IFD 42 + two 16-byte entries.
        // The second JPEG starts after the first, relative to the MP endian field.
        let app2Bytes=4+4+82,firstBytes=first.count+app2Bytes
        var tiff=Data([0x4d,0x4d,0,0x2a])+be(8)+Data([0,3])
        tiff += Data([0xb0,0,0,7])+be(4)+Data("0100".utf8)
        tiff += Data([0xb0,1,0,4])+be(1)+be(2)
        tiff += Data([0xb0,2,0,7])+be(32)+be(50)+be(0)
        tiff += be(0x20030000)+be(UInt32(firstBytes))+be(0)+Data(repeating:0,count:4)
        tiff += be(0)+be(UInt32(second.count))+be(UInt32(firstBytes-10))+Data(repeating:0,count:4)
        XCTAssertEqual(tiff.count,82)
        let bytes=Data(first.prefix(2))+jpegSegment(0xe2,Data("MPF\0".utf8)+tiff)+Data(first.dropFirst(2))+second
        let url=root.appendingPathComponent("two-independent-generated.jpg");try bytes.write(to:url)
        // Structural rejection is required even when ImageIO hides the second image.
        XCTAssertThrowsError(try StillImageProbe.inspect(url)) {XCTAssertEqual($0 as? StillImageProbeError,.multiImage)}
        XCTAssertEqual(try Data(contentsOf:url),bytes)
        let source=try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData,nil))
        guard CGImageSourceGetCount(source)==2 else{
            print("STILLPROBE unsupported MPF structurally rejected; ImageIO exposes \(CGImageSourceGetCount(source)) primary image(s), so independent second-frame decoding is not verified")
            return
        }
        for (index,width,height) in [(0,4,2),(1,6,3)] {
            let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,index,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary))
            XCTAssertEqual(image.width,width);XCTAssertEqual(image.height,height)
            XCTAssertEqual(CGImageSourceGetStatusAtIndex(source,index),.statusComplete)
        }
    }
    func testMalformedJPEGDoesNotClaimMultipleImages() throws {
        let url=root.appendingPathComponent("no-image-data.jpg"),bytes=Data([0xff,0xd8,0xff,0xd9])
        try bytes.write(to:url)
        XCTAssertThrowsError(try StillImageProbe.inspect(url)) {XCTAssertEqual($0 as? StillImageProbeError,.malformed)}
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testImageFailureCategoriesHaveSpecificKoreanDescriptions() {
        let failures:[StillImageProbeError]=[.unreadable,.invalidSignature,.typeMismatch,.multiImage,.orientation,.dimensions,
            .unsupportedDepth,.unsupportedColor,.unsupportedProfile,.animated,.malformed,.resourceLimit,.changed,
            .dimensionLimit(width:3024,height:4032,maxDimension:2048,maxPixels:4_194_304)]
        let fragments=["읽을 수 없습니다","JPEG 또는 PNG","확장자","MPF 이미지 구성","회전 방향","가로·세로 크기",
                       "비트 깊이","색상 모델","sRGB","APNG","끝까지 해석","자원 한도","원본이 변경","3024×4032"]
        for (failure,fragment) in zip(failures,fragments) {
            XCTAssertTrue(failure.localizedDescription.contains(fragment),"\(failure)")
            XCTAssertFalse(failure.localizedDescription.contains("OnTheFrameEngine.StillImageProbeError"))
        }
        XCTAssertEqual(Set(failures.map(\.localizedDescription)).count,14)
        XCTAssertFalse(StillImageProbeError.multiImage.localizedDescription.contains("사진이 여러 장"))
    }
    func testOwnerJPEGReadOnlyHighResolutionAcceptanceWhenProvided() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_OWNER_JPEG"],
              let expected=ProcessInfo.processInfo.environment["OTF_OWNER_JPEG_SHA256"] else{throw XCTSkip("explicit exact owner JPEG opt-in")}
        let url=URL(fileURLWithPath:path),before=try Data(contentsOf:url)
        guard QA01.sha(before)==expected else{XCTFail("owner JPEG identity mismatch; probe was not run");return}
        let metadata=try StillImageProbe.inspect(url),validator=StillImageProbe.Validator()
        XCTAssertEqual(metadata.descriptor.width,3024);XCTAssertEqual(metadata.descriptor.height,4032)
        XCTAssertEqual(metadata.descriptor.orientation,1)
        XCTAssertEqual(metadata.descriptor.profileDisposition,"embedded-Display-P3-ICC")
        XCTAssertEqual(metadata.descriptor.profileSHA256,"0ff6958f98684c61f6bbdce1368ddeaf3873baf84545baba482e920d92a914c0")
        XCTAssertEqual(metadata.encodedSHA256,expected)
        let first=try await validator.validate(metadata)
        XCTAssertEqual(first.normalizedWidth,1536);XCTAssertEqual(first.normalizedHeight,2048)
        XCTAssertEqual(first.normalizedRGBABytes,12_582_912);XCTAssertFalse(first.hasTransparentPixels)
        _ = try await validator.validate(StillImageProbe.inspect(url))
        let diagnostics=await validator.diagnostics()
        XCTAssertEqual(diagnostics.fullDecodes,1);XCTAssertEqual(diagnostics.proxyDecodes,1)
        XCTAssertEqual(diagnostics.cacheHits,1);XCTAssertEqual(diagnostics.retainedDecodedBytes,0)
        XCTAssertEqual(try Data(contentsOf:url),before)
    }
    func testHighResolutionAlphaPNGAndFiniteSafetyBounds() async throws {
        let width=3072,height=2304,url=root.appendingPathComponent("high-resolution-alpha.png")
        try autoreleasepool {
            let context=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red:0.2,green:0.7,blue:0.4,alpha:0.5));context.fill(CGRect(x:0,y:0,width:width,height:height))
            let writer=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
            CGImageDestinationAddImage(writer,try XCTUnwrap(context.makeImage()),nil);XCTAssertTrue(CGImageDestinationFinalize(writer))
        }
        let before=try Data(contentsOf:url),metadata=try StillImageProbe.inspect(url),validator=StillImageProbe.Validator()
        let result=try await validator.validate(metadata)
        XCTAssertEqual(metadata.descriptor.width,width);XCTAssertEqual(metadata.descriptor.height,height)
        XCTAssertEqual(result.normalizedWidth,2048);XCTAssertEqual(result.normalizedHeight,1536)
        XCTAssertTrue(metadata.descriptor.alphaCapability);XCTAssertTrue(result.hasTransparentPixels)
        XCTAssertEqual(result.normalizedRGBABytes,12_582_912)
        XCTAssertEqual(try Data(contentsOf:url),before)
        let bomb=root.appendingPathComponent("extreme-declared-size.png")
        let bombBytes=Data([137,80,78,71,13,10,26,10])+chunk("IHDR",be(UInt32.max)+be(1)+Data([8,2,0,0,0]))
        try bombBytes.write(to:bomb)
        XCTAssertThrowsError(try StillImageProbe.inspect(bomb)) {XCTAssertEqual($0 as? StillImageProbeError,.dimensionLimit(width:Int(UInt32.max),height:1,maxDimension:4096,maxPixels:16_777_216))}
        let oversized=root.appendingPathComponent("too-many-encoded-bytes.jpg")
        try Data(repeating:0,count:8*1024*1024+1).write(to:oversized)
        XCTAssertThrowsError(try StillImageProbe.inspect(oversized)) {XCTAssertEqual($0 as? StillImageProbeError,.resourceLimit)}
        var constrained=StillImageProbe.Limits();constrained.estimatedDecodeBytes=1024
        XCTAssertThrowsError(try StillImageProbe.inspect(url,limits:constrained)) {XCTAssertEqual($0 as? StillImageProbeError,.resourceLimit)}
        XCTAssertEqual(StillImageProbe.Limits().maxDimension,4096)
        XCTAssertEqual(StillImageProbe.Limits().maxPixels,16_777_216)
        XCTAssertEqual(StillImageProbe.Limits().estimatedDecodeBytes,384*1024*1024)
    }
    func testValidationResultCacheUsesContentLimitsAndBoundedLRU() async throws {
        let validator=StillImageProbe.Validator()
        let url=try png("validation-cache.png",extra:chunk("tEXt",Data("note\0a".utf8)))
        let first=try StillImageProbe.inspect(url)
        _ = try await validator.validate(first)
        _ = try await validator.validate(StillImageProbe.inspect(url))
        var stats=await validator.diagnostics()
        XCTAssertEqual(stats.fullDecodes,1);XCTAssertEqual(stats.proxyDecodes,1);XCTAssertEqual(stats.cacheHits,1)
        // Change valid encoded metadata without changing file size/inode/mtime.
        // A FileIdentity-only cache would miss this content revision.
        var stamp=stat();XCTAssertEqual(stat(url.path,&stamp),0)
        _ = try png("validation-cache.png",extra:chunk("tEXt",Data("note\0b".utf8)))
        let times=[stamp.st_atimespec,stamp.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer{Darwin.utimensat(AT_FDCWD,url.path,$0.baseAddress,0)},0)
        XCTAssertEqual(FileIdentity.of(url),first.descriptor.identity)
        let changed=try StillImageProbe.inspect(url)
        XCTAssertNotEqual(changed.encodedSHA256,first.encodedSHA256)
        _ = try await validator.validate(changed)
        stats=await validator.diagnostics();XCTAssertEqual(stats.fullDecodes,2);XCTAssertEqual(stats.cachedResults,1)
        var alteredLimits=StillImageProbe.Limits();alteredLimits.estimatedDecodeBytes-=1
        _ = try await validator.validate(StillImageProbe.inspect(url,limits:alteredLimits))
        stats=await validator.diagnostics();XCTAssertEqual(stats.fullDecodes,3)
        for index in 0..<9 {_ = try await validator.validate(StillImageProbe.inspect(png("lru-\(index).png")))}
        stats=await validator.diagnostics()
        XCTAssertEqual(stats.cachedResults,8);XCTAssertEqual(stats.retainedDecodedBytes,0)
    }
    func testCachedValidationStillHonorsBeforeDecodeIdentityAndCancellation() async throws {
        let validator=StillImageProbe.Validator(),url=try png("cached-seam.png"),metadata=try StillImageProbe.inspect(url)
        _ = try await validator.validate(metadata)
        let canceled=Task { () throws -> StillImageProbe.Validation in
            withUnsafeCurrentTask{$0?.cancel()}
            return try await validator.validate(metadata)
        }
        do{_ = try await canceled.value;XCTFail("cached validation ignored cancellation")}catch is CancellationError{}
        do {
            _ = try await validator.validate(metadata,beforeDecode:{try Data([1,2,3]).write(to:url,options:.atomic)})
            XCTFail("cached validation bypassed identity seam")
        }catch StillImageProbeError.changed{}
        let stats=await validator.diagnostics();XCTAssertEqual(stats.fullDecodes,1)
    }
    func testUnknownICCIsRejectedDespiteFriendlyProfileKeyword() throws {
        let unknown=try XCTUnwrap(CGColorSpace(name:CGColorSpace.adobeRGB1998)?.copyICCData()) as Data
        // The PNG profile keyword is descriptive metadata, never an authority for
        // admitting the actual ICC's colorimetry as sRGB or Display P3.
        let extra=chunk("iCCP",Data("sRGB Display P3".utf8)+Data([0,0])+storedZlib(unknown))
        let url=try png("profile-name-spoof.png",extra:extra),before=try Data(contentsOf:url)
        XCTAssertThrowsError(try StillImageProbe.inspect(url)) {XCTAssertEqual($0 as? StillImageProbeError,.unsupportedProfile)}
        XCTAssertEqual(try Data(contentsOf:url),before)
    }
    func testStandardSRGBChromaticitiesAndStrictNegativeControls() async throws {
        let values: [UInt32] = [31270,32900,64000,33000,30000,60000,15000,6000]
        let chromaticities = values.reduce(Data()) { $0 + be($1) }
        let gamma = chunk("gAMA",be(45455)), chroma = chunk("cHRM",chromaticities)
        for (name,extra) in [("standard",gamma+chroma),("explicit",chunk("sRGB",Data([0]))+chroma)] {
            let u=try png(name+".png",color:6,extra:extra),before=try Data(contentsOf:u)
            let m=try StillImageProbe.inspect(u),v=try await StillImageProbe.validator.validate(m)
            XCTAssertEqual(m.descriptor.colorModel,"RGB")
            XCTAssertTrue(m.descriptor.alphaCapability);XCTAssertTrue(v.hasTransparentPixels)
            XCTAssertEqual(v.normalizedRGBABytes,4);XCTAssertEqual(try Data(contentsOf:u),before)
        }
        var changed=values;changed[2]+=1
        let invalid:[(String,Data)]=[
            ("other-primaries",gamma+chunk("cHRM",changed.reduce(Data()){$0+be($1)})),
            ("short-chroma",gamma+chunk("cHRM",Data(chromaticities.dropLast()))),
            ("duplicate-chroma",gamma+chroma+chroma),
            ("unknown-transfer",chroma),
            ("other-gamma",chunk("gAMA",be(40000))+chroma),
            ("duplicate-gamma",gamma+gamma+chroma)
        ]
        for (name,extra) in invalid {
            let u=try png(name+".png",extra:extra)
            XCTAssertThrowsError(try StillImageProbe.inspect(u)) { XCTAssertEqual($0 as? StillImageProbeError,.unsupportedProfile) }
        }
    }
    func testOwnerImageReadOnlyWhenProvided() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_OWNER_IMAGE"],
              let expected=ProcessInfo.processInfo.environment["OTF_OWNER_IMAGE_SHA256"] else { throw XCTSkip("explicit owner image opt-in") }
        let u=URL(fileURLWithPath:path),before=try Data(contentsOf:u)
        XCTAssertEqual(QA01.sha(before),expected)
        let m=try StillImageProbe.inspect(u),v=try await StillImageProbe.validator.validate(m)
        let expectedSize=StillImageProbe.proxySize(for:m.descriptor,maxDimension:StillImageProbe.validationProxyMaxDimension)
        XCTAssertLessThanOrEqual(abs(v.normalizedWidth-expectedSize.width),1)
        XCTAssertLessThanOrEqual(abs(v.normalizedHeight-expectedSize.height),1)
        XCTAssertEqual(v.normalizedRGBABytes,v.normalizedWidth*v.normalizedHeight*4)
        XCTAssertEqual(try Data(contentsOf:u),before)
    }
    func storedZlib(_ data:Data)->Data {
        var a:UInt32=1,b:UInt32=0;for v in data{a=(a+UInt32(v))%65521;b=(b+a)%65521}
        let n=UInt16(data.count)
        return Data([0x78,1,1,UInt8(n&255),UInt8(n>>8),UInt8((~n)&255),UInt8((~n)>>8)])+data+be((b<<16)|a)
    }
    func testExplicitICCAndMaximumAdmittedDecode()async throws {
        let icc=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)?.copyICCData()) as Data
        let profilePNG=try png("profile.png",extra:chunk("iCCP",Data("profile".utf8)+Data([0,0])+storedZlib(icc)))
        let metadata=try StillImageProbe.inspect(profilePNG)
        XCTAssertNotNil(metadata.descriptor.profileSHA256);XCTAssertEqual(metadata.descriptor.profileDisposition,"embedded-sRGB-ICC")
        _ = try await StillImageProbe.validator.validate(metadata)
        let absent=try StillImageProbe.inspect(png("absent.png"));XCTAssertNil(absent.descriptor.profileSHA256);XCTAssertEqual(absent.descriptor.profileDisposition,"assumed-sRGB")
        let broken=try png("badICC.png",extra:chunk("iCCP",Data([65,0,0,1,2,3])))
        XCTAssertThrowsError(try StillImageProbe.inspect(broken))
        let large=try jpeg("maximum.jpg",orientation:1,width:4096,height:4096),m=try StillImageProbe.inspect(large),v=try await StillImageProbe.validator.validate(m)
        XCTAssertEqual(v.normalizedRGBABytes,16_777_216)
        XCTAssertEqual(m.descriptor.width,4096);XCTAssertEqual(m.descriptor.height,4096)
        XCTAssertEqual(v.normalizedWidth,2048);XCTAssertEqual(v.normalizedHeight,2048)
        print("STILLPROBE max-admitted4096x4096 validation-proxy RGBA bytes=\(v.normalizedRGBABytes) RSS=\(IBDiagnostics(root:root).rss())")
    }
    func testRequiredStreamIntegrityControls()async throws {
        let valid=try png("control.png"),original=try Data(contentsOf:valid)
        func replaceIDAT(_ payload:Data,_ name:String)throws->URL {
            var out=original.prefix(8),k=8
            while k+12<=original.count {
                let n=original[k..<k+4].reduce(0){($0<<8)|Int($1)},tag=original.subdata(in:k+4..<k+8)
                if tag==Data("IDAT".utf8){out+=chunk("IDAT",payload)}else{out+=original[k..<k+n+12]};k+=n+12
            }
            let u=root.appendingPathComponent(name);try out.write(to:u);return u
        }
        let stream=storedZlib(Data([0,0,0,0]))
        var badChecksum=stream;badChecksum[badChecksum.count-1]^=1
        let cases:[(String,Data)]=[("original-shape.png",Data([0x78,1,0])),("truncated.png",Data(stream.dropLast())),("invalid-block.png",Data([0x78,1,7,0,0,0,1])),("checksum.png",badChecksum),("short-scanline.png",storedZlib(Data([0,0]))),("bad-filter.png",storedZlib(Data([5,0,0,0])))]
        for (name,payload) in cases {
            let u=try replaceIDAT(payload,name),before=try Data(contentsOf:u),m=try StillImageProbe.inspect(u)
            do{_ = try await StillImageProbe.validator.validate(m);XCTFail("required IDAT corruption accepted: \(name)")}catch StillImageProbeError.malformed{}
            XCTAssertEqual(try Data(contentsOf:u),before)
        }
        let text=try png("optional-text.png",extra:chunk("tEXt",Data("note\0not pixel data".utf8)))
        _ = try await StillImageProbe.validator.validate(StillImageProbe.inspect(text))
        _ = try await StillImageProbe.validator.validate(StillImageProbe.inspect(valid))
    }
    func testRejectionsAndAdmission()throws {
        let url=try png(),data=try Data(contentsOf:url),bad=root.appendingPathComponent("bad.png")
        try data.dropLast(3).write(to:bad);XCTAssertThrowsError(try StillImageProbe.inspect(bad))
        try Data([1,2,3]).write(to:bad);XCTAssertThrowsError(try StillImageProbe.inspect(bad))
        let mismatch=root.appendingPathComponent("mismatch.jpg");try data.write(to:mismatch);XCTAssertThrowsError(try StillImageProbe.inspect(mismatch))
        let animation=try png("animated.png",extra:chunk("acTL",be(2)+be(0)));XCTAssertThrowsError(try StillImageProbe.inspect(animation))
        let hdr=try png("hdr.png",extra:chunk("cICP",Data([9,16,0,1])));XCTAssertThrowsError(try StillImageProbe.inspect(hdr))
        let sixteen=try png("sixteen.png",depth:16);XCTAssertThrowsError(try StillImageProbe.inspect(sixteen))
        // The writer retains raw EXIF9 but ImageIO properties normalize it to1: probe must inspect EXIF too.
        let orientation=try jpeg("orientation.jpg",orientation:9);XCTAssertThrowsError(try StillImageProbe.inspect(orientation))
        var limits=StillImageProbe.Limits();limits.fileBytes=1;XCTAssertThrowsError(try StillImageProbe.inspect(url,limits:limits))
        limits=StillImageProbe.Limits();limits.maxPixels=0;XCTAssertThrowsError(try StillImageProbe.pixelAdmission(width:1,height:1,limits:limits))
        XCTAssertThrowsError(try StillImageProbe.pixelAdmission(width:Int.max,height:2,limits:StillImageProbe.Limits()))
        limits=StillImageProbe.Limits();limits.estimatedDecodeBytes=1;XCTAssertThrowsError(try StillImageProbe.pixelAdmission(width:1,height:1,limits:limits))
    }
    func testCancellationAndIdentityChange()async throws {
        let url=try png(),m=try StillImageProbe.inspect(url)
        let t=Task {withUnsafeCurrentTask{$0?.cancel()};return try StillImageProbe.inspect(url)}
        do{_ = try await t.value;XCTFail("canceled inspect accepted")}catch is CancellationError{}catch{XCTFail("wrong error \(error)")}
        do {_ = try await StillImageProbe.validator.validate(m,beforeDecode:{try Data([1,2,3]).write(to:url,options:.atomic)});XCTFail("changed input accepted")}catch StillImageProbeError.changed{}catch{XCTFail("wrong identity error \(error)")}
        let url2=try png("cancel.png"),m2=try StillImageProbe.inspect(url2)
        let v=Task {withUnsafeCurrentTask{$0?.cancel()};return try await StillImageProbe.validator.validate(m2)}
        do{_ = try await v.value;XCTFail("canceled decode accepted")}catch is CancellationError{}catch{XCTFail("wrong cancellation error")}
    }
}
