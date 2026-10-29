import XCTest
import AVFoundation
import CoreGraphics

final class CanonicalNV12QATests:XCTestCase {
    var root:URL!,diag:IBDiagnostics!
    override func setUp() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG_B_QA02_RUN"] else { throw XCTSkip("IMG-B-QA-02 explicit opt-in") }
        let base=URL(fileURLWithPath:path).standardizedFileURL
        let allowed=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path+"/"
        guard base.path.hasPrefix(allowed) else { throw IBContract.error("QA02 isolated root",code:300) }
        root=base.appendingPathComponent(name.components(separatedBy:" ").last?.replacingOccurrences(of:"]",with:"") ?? "unknown")
        guard !FileManager.default.fileExists(atPath:root.path) else { throw IBContract.error("QA02 fresh root required",code:300) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);diag=IBDiagnostics(root:root)
    }
    func note(_ name:String,_ data:[String:Any]) throws { try diag.note(name,data) }
    func contract() throws {
        try note("contract-before-measurement",["version":IBCanonicalNV12.version,"range":"420v/Y16...235/CbCr16...240,128zero",
            "color":"709 primaries/transfer/matrix; actual supported HDTV ICC to sRGB, relativeColorimetric",
            "sampling":"Left centers(2i+.5,2j+1); separable linear, edge clamp; raw top-left full extent; opaque",
            "rounding":"Double matrix; RGB clamp0...1; Float32 storage; final ColorSync RGBA8 quantization only",
            "authority":"Left positions are SDK-defined; linear kernel is a declared reproducible diagnostic choice, not a mandated709 filter/product-policy amendment",
            "thresholds":"unchanged PSNR>=40,flat<=3,structural constraints; no score-based path selection"])
    }
    // Deterministic source codes. The scalar oracle below sums analytic triangular basis functions,
    // independently of the canonical helper's integer polyphase implementation.
    func code(_ pattern:String,_ x:Int,_ y:Int,_ plane:Int)->Int {
        if pattern=="primaries" {
            let patches=[[63,102,240],[173,42,26],[32,240,118],[235,128,128]]
            return patches[min(3,x/(plane==0 ? 4:2))][plane]
        }
        if plane==0 {
            switch pattern {
            case "neutrals": return [16,235,126,63][min(3,x/4)]
            case "luma-even": return x<8 ? 16:235
            case "luma-odd": return x<7 ? 16:235
            case "fine-luma": return x==7 || y==9 ? 235:16
            default: return 126
            }
        }
        if pattern=="chroma-x" { return plane==1 ? (x<4 ? 96:160):(x<4 ? 160:96) }
        if pattern=="chroma-y" { return plane==1 ? (y<4 ? 96:160):(y<4 ? 160:96) }
        if pattern=="fine-chroma",x==3,y==3 { return plane==1 ? 32:224 }
        return 128
    }
    func fixture(_ pattern:String) throws -> CVPixelBuffer {
        let pb=try QA01.synthetic("chroma-x8") // allocation only; all active samples replaced here
        CVPixelBufferLockBaseAddress(pb,[])
        do {
            defer { CVPixelBufferUnlockBaseAddress(pb,[]) }
            for plane in 0..<2 {
                let p=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,plane)).assumingMemoryBound(to:UInt8.self),s=CVPixelBufferGetBytesPerRowOfPlane(pb,plane)
                for y in 0..<(plane==0 ? 16:8) { for x in 0..<(plane==0 ? 16:8) {
                    if plane==0 { p[y*s+x]=UInt8(code(pattern,x,y,0)) }
                    else { p[y*s+x*2]=UInt8(code(pattern,x,y,1));p[y*s+x*2+1]=UInt8(code(pattern,x,y,2)) }
                } }
            }
        }
        return pb
    }
    func oracleChroma(_ pattern:String,_ x:Int,_ y:Int,_ channel:Int)->Double {
        // Extend sample lattice by repeating edge values, then integrate local triangle weights.
        let xx=Double(x)/2,yy=(Double(y)-0.5)/2
        var sum=0.0
        for j in -1...8 { for i in -1...8 {
            let weight=max(0,1-abs(xx-Double(i)))*max(0,1-abs(yy-Double(j)))
            sum += weight*Double(code(pattern,max(0,min(7,i)),max(0,min(7,j)),channel))
        } }
        return sum
    }
    func oracleRGB(_ pattern:String,_ x:Int,_ y:Int)->(Double,Double,Double) {
        let l=Double(code(pattern,x,y,0)-16)/219,cb=(oracleChroma(pattern,x,y,1)-128)/224,cr=(oracleChroma(pattern,x,y,2)-128)/224
        return (l+1.5748*cr,l-0.1873242729306488*cb-0.46812427293064884*cr,l+1.8556*cb)
    }
    func testAnalyticalReferenceAndBacking() throws {
        try contract()
        var largestOracle=0
        for pattern in ["neutrals","primaries","luma-even","luma-odd","chroma-x","chroma-y","fine-luma","fine-chroma"] {
            let a=try fixture(pattern),b=try QA01.clone(a,surface:false),p=try IBCanonicalNV12.Planes(a)
            XCTAssertEqual(try QA01.active(a),try QA01.active(b));XCTAssertTrue(QA01.attachmentEquality(a,b).values.allSatisfy{$0})
            let ca=try IBCanonicalNV12.bytes(a),cb=try IBCanonicalNV12.bytes(b)
            XCTAssertEqual(ca,cb)
            var expected=[UInt8]();var cache=[String:[UInt8]]()
            for y in 0..<16 { for x in 0..<16 {
                let o=oracleRGB(pattern,x,y),c=p.rgb(x,y)
                XCTAssertEqual(c.0,o.0,accuracy:1e-12);XCTAssertEqual(c.1,o.1,accuracy:1e-12);XCTAssertEqual(c.2,o.2,accuracy:1e-12)
                let key="\(o.0),\(o.1),\(o.2)"
                if cache[key]==nil { cache[key]=try QA01.colorExpected(o,profile:p.profile) }
                expected += cache[key]!
            } }
            let os=try QA01.stats(ca,expected,width:16,height:16);let maximum=os["maximum"] as? Int ?? 999
            largestOracle=max(largestOracle,maximum);XCTAssertLessThanOrEqual(maximum,1,"Float image vs independent CGColor ICC quantization")
            let ciA=try QA01.controlledCI(a),ciB=try QA01.controlledCI(b),vtA=try QA01.vt(a),vtB=try QA01.vt(b)
            try note(pattern,["canonical-vs-analyticalTrianglePlusCGColor":os,"canonicalBacking":try QA01.stats(ca,cb,width:16,height:16),
                "CI-vs-canonical":try QA01.stats(ciA,ca,width:16,height:16),"CIBacking":try QA01.stats(ciA,ciB,width:16,height:16),
                "VTsurface-vs-canonical":try QA01.stats(vtA.srgb,ca,width:16,height:16),"VTordinary-vs-canonical":try QA01.stats(vtB.srgb,ca,width:16,height:16),
                "VTBacking":try QA01.stats(vtA.srgb,vtB.srgb,width:16,height:16),"A":try QA01.metadata(a,allocation:"new16x16 IOSurface deterministic codes"),"B":try QA01.metadata(b,allocation:"ordinary clone")])
        }
        // Independent hand values and phase checks, including clamped saturated primaries.
        let p=try IBCanonicalNV12.Planes(fixture("primaries"))
        let r=p.rgb(0,4);XCTAssertEqual(r.0,1.0020118721461186,accuracy:1e-12)
        let primaryBytes=try IBCanonicalNV12.bytes(fixture("primaries"))
        var points=[[String:Any]]()
        for (x,color) in [(0,[255,0,0]),(4,[0,255,0]),(8,[0,0,255]),(12,[255,255,255])] {
            let actual=Array(primaryBytes[(4*16+x)*4..<(4*16+x)*4+3])
            for c in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(actual[c])-color[c]),4,"8bit709 primary code approximation") }
            points.append(["xy":[x,4],"actual":actual,"idealPrimary":color])
        }
        let xp=try IBCanonicalNV12.Planes(fixture("chroma-x")),yp=try IBCanonicalNV12.Planes(fixture("chroma-y"))
        XCTAssertEqual(xp.chroma(7,4,0),128);XCTAssertEqual(yp.chroma(4,7,0),112);XCTAssertEqual(yp.chroma(4,8,0),144)
        try note("validation-complete",["patterns":8,"allPixelsArithmeticTolerance":1e-12,"ICCOracleMaximum":largestOracle,"backingMaximum":0,"primaryProbes":points,
            "scope":"canonical validated for declared narrow diagnostic contract; CI/VT agreement not assumed; helper not yet changed during initial validation"])
    }
    func testCorrectedHelperRegressionAndRejections() async throws {
        try contract()
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG_B_QA02_MP4"] else { throw IBContract.error("QA02 retained MP4 required",code:300) }
        let pb=try await IBReference.read(AVURLAsset(url:URL(fileURLWithPath:path)),frame:2,format:IBContract.format),copy=try QA01.clone(pb,surface:false)
        let a=try IBCanonicalNV12.bytes(pb),b=try IBReference.bytes(IBReference.managed(pb)),c=try IBReference.bytes(IBReference.managed(copy))
        XCTAssertEqual(a,b);XCTAssertEqual(b,c)
        let vtA=try QA01.vt(pb),vtB=try QA01.vt(copy)
        try note("corrected-helper-frame2",["canonical-vs-helper":try QA01.stats(a,b,width:1920,height:1080),"helperBacking":try QA01.stats(b,c,width:1920,height:1080),
            "retainedLegacyVTBacking":try QA01.stats(vtA.srgb,vtB.srgb,width:1920,height:1080),"inputA":try QA01.metadata(pb,allocation:"retained decode"),"inputB":try QA01.metadata(copy,allocation:"ordinary clone")])
        for kind in ["matrix","siting","aperture","fractional-aperture","interlace","aspect"] {
            let p=try fixture("neutrals")
            switch kind {
            case "matrix":CVBufferSetAttachment(p,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_601_4,.shouldPropagate)
            case "siting":CVBufferSetAttachment(p,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center,.shouldPropagate)
            case "aperture":CVBufferSetAttachment(p,kCVImageBufferCleanApertureKey,["Width":14,"Height":16,"HorizontalOffset":0,"VerticalOffset":0] as CFDictionary,.shouldPropagate)
            case "fractional-aperture":CVBufferSetAttachment(p,kCVImageBufferCleanApertureKey,["Width":16.5,"Height":16,"HorizontalOffset":0,"VerticalOffset":0] as CFDictionary,.shouldPropagate)
            case "interlace":CVBufferSetAttachment(p,kCVImageBufferFieldCountKey,2 as CFNumber,.shouldPropagate)
            default:CVBufferSetAttachment(p,kCVImageBufferPixelAspectRatioKey,["HorizontalSpacing":2,"VerticalSpacing":1] as CFDictionary,.shouldPropagate)
            }
            XCTAssertThrowsError(try IBCanonicalNV12.bytes(p));try note("rejected-"+kind,["expected":"unsupported metadata rejected"])
        }
        XCTAssertFalse(CMTime.invalid.isNumeric);XCTAssertFalse(CMTime.indefinite.isNumeric)
        XCTAssertTrue(diag.safe(Double.infinity) is String);XCTAssertTrue(diag.safe(Double.nan) is String)
    }
}
