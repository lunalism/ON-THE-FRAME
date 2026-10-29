import XCTest
import ImageIO
import CoreGraphics
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
        let unsupported=try jpeg("p3.jpg",orientation:1,space:CGColorSpace(name:CGColorSpace.displayP3));XCTAssertThrowsError(try StillImageProbe.inspect(unsupported))
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
        let large=try jpeg("maximum.jpg",orientation:1,width:2048,height:2048),m=try StillImageProbe.inspect(large),v=try await StillImageProbe.validator.validate(m)
        XCTAssertEqual(v.normalizedRGBABytes,16_777_216)
        print("STILLPROBE max-admitted2048x2048 RGBA bytes=\(v.normalizedRGBABytes) RSS=\(IBDiagnostics(root:root).rss())")
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
