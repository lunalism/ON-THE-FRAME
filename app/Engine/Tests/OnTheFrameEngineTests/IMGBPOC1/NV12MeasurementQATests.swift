import XCTest
import AVFoundation
import CoreGraphics
import CoreImage
import IOSurface

final class NV12MeasurementQATests: XCTestCase {
    var root: URL!,diagnostics: IBDiagnostics!
    override func setUp() async throws {
        guard let run=ProcessInfo.processInfo.environment["OTF_IMG_B_QA01_RUN"] else { throw XCTSkip("IMG-B-QA-01 explicit diagnostic opt-in") }
        let base=URL(fileURLWithPath:run).standardizedFileURL
        let allowed=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path+"/"
        guard base.path.hasPrefix(allowed) else { throw IBContract.error("QA01 disposable root",code:300) }
        let method=name.components(separatedBy:" ").last?.replacingOccurrences(of:"]",with:"") ?? "unknown"
        root=base.appendingPathComponent(method)
        guard !FileManager.default.fileExists(atPath:root.path) else { throw IBContract.error("QA01 fresh output required",code:300) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);diagnostics=IBDiagnostics(root:root)
    }
    func note(_ name: String,_ fields: [String:Any]) throws { try diagnostics.note(name,fields) }
    func point(_ rgb: [UInt8],_ x: Int,_ y: Int,_ w: Int) -> [UInt8] { let k=(y*w+x)*4;return Array(rgb[k..<k+4]) }
    func contract() throws {
        try note("premeasurement-contract",[
            "A":"unchanged VTCreateCGImageFromCVPixelBuffer(options:nil) on IOSurface input, then legacy sRGB CGContext normalization",
            "B":"same conversion on ordinary CVPixelBuffer with active bytes and propagating/nonpropagating attachments copied",
            "C":"independent BT709 limited matrix; Left centers(2i+0.5,2j+1); bilinear chroma with edge clamp; full-resolution Y; float709 RGB then actual source ICC to sRGB8",
            "Cquantization":"matrix uses Double; clamp RGB to0...1; store Float32; ColorSync quantizes final sRGB RGBA8; no nominal RGB retagging",
            "D":"CIImage sourceICC explicit; CIContext software requested, extendedLinearSRGB working, sRGB output, RGBA8/cacheIntermediates false",
            "policy":"C fixed before data; not selected by highest PSNR; no production or accepted sampling-policy amendment; no Gate2 reclassification",
            "bounds":"5 small16x16 patterns then one retained frame2 in separate test; no export/AVPlayer;512MiB/1GiB/20GiB"])
    }
    @discardableResult func matrix(_ a: CVPixelBuffer,_ b: CVPixelBuffer,label: String) throws -> [String:Any] {
        let w=CVPixelBufferGetWidth(a),h=CVPixelBufferGetHeight(a),aa=try QA01.active(a),bb=try QA01.active(b)
        guard aa==bb else { throw IBContract.error("QA01 active byte inequality",code:200) }
        let equal=QA01.attachmentEquality(a,b)
        guard equal["propagatingEqual"]==true,equal["nonPropagatingEqual"]==true else { throw IBContract.error("QA01 metadata inequality",code:200) }
        let va=try QA01.vt(a),vb=try QA01.vt(b),ca=try QA01.explicit(a),cb=try QA01.explicit(b)
        let da=try QA01.controlledCI(a),db=try QA01.controlledCI(b)
        let comparisons: [String:Any]=[
            "VT-raw-beforeICC-A-vs-B":try QA01.stats(va.raw,vb.raw,width:w,height:h),
            "VT-sRGB-A-vs-B":try QA01.stats(va.srgb,vb.srgb,width:w,height:h),
            "C-A-vs-C-B":try QA01.stats(ca,cb,width:w,height:h),"D-A-vs-D-B":try QA01.stats(da,db,width:w,height:h),
            "VT-A-vs-C":try QA01.stats(va.srgb,ca,width:w,height:h),"VT-B-vs-C":try QA01.stats(vb.srgb,ca,width:w,height:h),
            "D-A-vs-C":try QA01.stats(da,ca,width:w,height:h),"D-B-vs-C":try QA01.stats(db,ca,width:w,height:h)]
        try note(label+"-matrix",["width":w,"height":h,"activeBytes":aa.count,"activeSHA256":QA01.sha(aa),"attachmentEquality":equal,
            "inputA":try QA01.metadata(a,allocation:"IOSurface or retained decode as recorded"),"inputB":try QA01.metadata(b,allocation:"CVPixelBufferCreate ordinary,nil attrs; all image attachments copied"),
            "VT-A":va.info,"VT-B":vb.info,"comparisons":comparisons])
        XCTAssertEqual(ca,cb,"explicit conversion must not depend on backing")
        for (name,pixels) in [("A",va.srgb),("B",vb.srgb),("C",ca),("D",da)] {
            try IBReference.save(IBReference.image(pixels,width:w,height:h),to:root.appendingPathComponent(label+"-"+name+".png"))
        }
        if w==16 {
            let coords=[(2,2),(10,2),(2,10),(10,10),(6,7),(7,7),(8,7),(9,7),(7,8)]
            try note(label+"-probes",["pixels":coords.map { x,y -> [String:Any] in
                ["xy":[x,y],"Araw":point(va.raw,x,y,w),"Braw":point(vb.raw,x,y,w),"A":point(va.srgb,x,y,w),"B":point(vb.srgb,x,y,w),"C":point(ca,x,y,w),"D":point(da,x,y,w)]
            }])
        } else {
            let areas=[("PNG-x640",CGRect(x:636,y:0,width:8,height:1080)),("prior-worst",CGRect(x:1276,y:536,width:8,height:8)),("top-edge",CGRect(x:960,y:536,width:960,height:8))]
            for (name,rect) in areas { try note(label+"-"+name,["VTrawAB":try QA01.stats(va.raw,vb.raw,width:w,height:h,region:rect),
                "VTsRGBAB":try QA01.stats(va.srgb,vb.srgb,width:w,height:h,region:rect),"A-vs-C":try QA01.stats(va.srgb,ca,width:w,height:h,region:rect),
                "B-vs-C":try QA01.stats(vb.srgb,ca,width:w,height:h,region:rect),"D-vs-C":try QA01.stats(da,ca,width:w,height:h,region:rect)]) }
            try note(label+"-worst-probe",["xy":[1279,539],"Araw":point(va.raw,1279,539,w),"Braw":point(vb.raw,1279,539,w),
                "A":point(va.srgb,1279,539,w),"B":point(vb.srgb,1279,539,w),"C":point(ca,1279,539,w),"D":point(da,1279,539,w)])
        }
        return comparisons
    }
    func testIndependentSyntheticControls() throws {
        try contract()
        for pattern in ["patches","luma-even8","luma-odd7","chroma-x8","chroma-y8"] {
            let a=try QA01.synthetic(pattern),b=try QA01.clone(a,surface:false),samples=try QA01.Samples(a)
            let rgb=try QA01.explicit(a)
            if pattern=="patches" {
                XCTAssertEqual(point(rgb,2,2,16),[0,0,0,255]);XCTAssertEqual(point(rgb,10,2,16),[255,255,255,255])
                let m=samples.rgb709(2,10);XCTAssertEqual(m.0,110.0/219,accuracy:1e-12);XCTAssertEqual(m.1,110.0/219,accuracy:1e-12);XCTAssertEqual(m.2,110.0/219,accuracy:1e-12)
                let r=samples.rgb709(10,10)
                // Hand values from Y63,Cb102,Cr240, not from candidate renderer code.
                XCTAssertEqual(r.0,1.0020118721461186,accuracy:1e-9)
                XCTAssertEqual(r.1,0.0022928364318330063,accuracy:1e-6)
                XCTAssertEqual(r.2,-0.0007702707110241458,accuracy:1e-6)
                let grayExpected=try QA01.colorExpected((110.0/219,110.0/219,110.0/219),profile:samples.space)
                let redExpected=try QA01.colorExpected((1,0.0022928364318330063,0),profile:samples.space)
                for c in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(point(rgb,2,10,16)[c])-Int(grayExpected[c])),1)
                    XCTAssertLessThanOrEqual(abs(Int(point(rgb,10,10,16)[c])-Int(redExpected[c])),1) }
                try note("hand-expected",["black":[0,0,0],"white":[255,255,255],"midgray709":110.0/219,"midgray-sRGB":grayExpected,
                    "saturatedRed709":[r.0,r.1,r.2],"red-sRGB":redExpected,"rounding":"final8bit ColorSync; independent CGColor-fill comparison<=1 quantization code"])
            }
            if pattern.hasPrefix("luma") {
                let edge=pattern=="luma-odd7" ? 7:8
                XCTAssertEqual(point(rgb,edge-1,4,16),[0,0,0,255]);XCTAssertEqual(point(rgb,edge,4,16),[255,255,255,255])
            }
            if pattern=="chroma-x8" { let uv=samples.chroma(7,4);XCTAssertEqual(uv.0,128);XCTAssertEqual(uv.1,128) }
            if pattern=="chroma-y8" {
                let odd=samples.chroma(4,7),even=samples.chroma(4,8)
                XCTAssertEqual(odd.0,112);XCTAssertEqual(odd.1,144);XCTAssertEqual(even.0,144);XCTAssertEqual(even.1,112)
            }
            _=try matrix(a,b,label:pattern)
        }
        try note("controls-complete",["patterns":5,"status":"control results recorded; no product measurement-path approval or Gate2 reclassification"])
    }
    func testRetainedFrameRepresentationMatrix() async throws {
        try contract()
        guard let source=ProcessInfo.processInfo.environment["OTF_IMG_B_QA01_MP4"],let dump=ProcessInfo.processInfo.environment["OTF_IMG_B_QA01_DUMP"] else { throw IBContract.error("QA01 retained inputs required",code:300) }
        let mp4=URL(fileURLWithPath:source),oldDump=URL(fileURLWithPath:dump)
        let before=try IBReference.digest([mp4,oldDump])
        let a=try await IBReference.read(AVURLAsset(url:mp4),frame:2,format:IBContract.format)
        let oldBytes=try Data(contentsOf:oldDump),newBytes=try QA01.active(a)
        try note("historical-equivalence",["originalCVPixelBufferObjectRetained":false,"newDiagnosticInput":"new AVAssetReader decode of retained MP4 frame2; not the original object",
            "PTS":"2/30","historicalActiveSHA256":QA01.sha(oldBytes),"newActiveSHA256":QA01.sha(newBytes),"activeByteEquality":oldBytes==newBytes,
            "historicalLayoutLimit":"prior report did not preserve complete strides/padding/surface dimensions; new values are recorded separately"])
        guard oldBytes==newBytes else { throw IBContract.error("QA01 historical decoded bytes did not match; do not relabel as reproduction",code:300) }
        let historicalB=try QA01.clone(a,surface:false,allAttachments:false)
        let oldEquality=QA01.attachmentEquality(a,historicalB)
        try note("historical-clone-recipe",["allocation":"ordinary CVPixelBufferCreate nil attrs; propagating only, same as old helper","equality":oldEquality])
        let b: CVPixelBuffer
        if oldEquality.values.allSatisfy({$0}) { b=historicalB }
        else {
            let va=try QA01.vt(a),vo=try QA01.vt(historicalB)
            try note("historical-clone-nonpropagating-difference",["metadata":try QA01.metadata(historicalB,allocation:"old propagating-only clone"),
                "oldRecipeSRGB":try QA01.stats(va.srgb,vo.srgb,width:1920,height:1080)])
            b=try QA01.clone(a,surface:false,allAttachments:true)
        }
        let comparisons=try matrix(a,b,label:"retained-frame2")
        let capturedA=try QA01.vt(a),capturedB=try QA01.vt(b)
        let legacyA=try IBReference.bytes(IBReference.managed(a)),legacyB=try IBReference.bytes(IBReference.managed(b))
        try note("legacy-path-alias-check",["A":try QA01.stats(legacyA,capturedA.srgb,width:1920,height:1080),
            "B":try QA01.stats(legacyB,capturedB.srgb,width:1920,height:1080)])
        guard try IBReference.digest([mp4,oldDump])==before else { throw IBContract.error("QA01 retained evidence changed",code:200) }
        let raw=comparisons["VT-raw-beforeICC-A-vs-B"] as? [String:Any] ?? [:]
        let srgb=comparisons["VT-sRGB-A-vs-B"] as? [String:Any] ?? [:]
        let defect=(srgb["maximum"] as? Int ?? 0)>3
        try note("decision",["status":defect ? "MEASUREMENT DEFECT CONFIRMED":"INCONCLUSIVE",
            "firstConfirmedDivergence":(raw["maximum"] as? Int ?? 0)>0 ? "VT CGImage RGB code values before legacy ICC normalization":"not isolated before normalization",
            "scope":"existing options:nil path is representation-dependent under equivalent active bytes/declared image metadata; not a claim of VideoToolbox API-spec violation",
            "Gate2AVPLAYER":"PASS preserved","Gate2EXPORT":"QUALITY FAIL preserved","originalFrame3PSNR":39.97634349053969,"originalFrame4Flat":4,
            "originalBoundary":106,"originalCloneDifference":101,"exports":0,"AVPlayerExecutions":0,"existingHelpersModified":false,
            "correctedGate2Metrics":"not run; C/D diagnostic comparisons are separately versioned, not replacement acceptance scores"])
    }
}
