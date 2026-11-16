import XCTest
import AVFoundation
import CoreGraphics

final class VectorInputConversionTests:XCTestCase {
    var base:URL!,root:URL!,diag:IBDiagnostics!
    override func setUp() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG_B_OPT01_RUN"] else{throw XCTSkip("IMG-B-OPT-01 explicit opt-in")}
        base=URL(fileURLWithPath:path).standardizedFileURL
        let allowed=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("selftest-work").path+"/"
        guard base.path.hasPrefix(allowed),_isReleaseAssertConfiguration(),!_isDebugAssertConfiguration() else{throw IBContract.error("OPT01 Release/root",code:300)}
        root=base.appendingPathComponent(name.components(separatedBy:" ").last?.replacingOccurrences(of:"]",with:"") ?? "unknown")
        guard !FileManager.default.fileExists(atPath:root.path) else{throw IBContract.error("OPT01 fresh result root",code:300)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);diag=IBDiagnostics(root:root)
    }
    func note(_ n:String,_ f:[String:Any])throws{try diag.note(n,f)}
    func testAllInputCodeTriples()throws{
        try note("arithmetic-before-test",["domain":"all256^3 UInt8 Y/Cb/Cr code triples; original Float normalization","expectation":"identical Float bit patterns of x/y/z; no approximate tolerance","preserved":"sequential green subtraction, clipping/transfer performed later unchanged"])
        let start=IBPerfClock.now(process:true),ys=(0..<256).map{(Float($0)-16)/219},cs=(0..<256).map{(Float($0)-128)/224}
        var source=[SIMD3<Float>](repeating:.zero,count:65_536),scalar=[Float](repeating:0,count:65_536*3),vector=scalar,chunkHashes=[[String:Any]]()
        for y in 0..<256 {
            for cb in 0..<256 {for cr in 0..<256 {source[cb*256+cr]=SIMD3<Float>(ys[y],cs[cb],cs[cr])}}
            scalarLoop(source,&scalar);vectorLoop(source,&vector)
            let aa=scalar.withUnsafeBytes{Data($0)},bb=vector.withUnsafeBytes{Data($0)}
            let ah=QA01.sha(aa),bh=QA01.sha(bb)
            if aa != bb {
                let k=try XCTUnwrap(scalar.indices.first{scalar[$0].bitPattern != vector[$0].bitPattern}),point=k/3,cb=point/256,cr=point%256
                try note("FIRST-ARITHMETIC-FAIL",["codes":[y,cb,cr],"channel":k%3,"scalar":scalar[k],"vector":vector[k],"scalarBits":scalar[k].bitPattern,"vectorBits":vector[k].bitPattern,"scalarChunkSHA256":ah,"vectorChunkSHA256":bh])
                throw IBContract.error("OPT01 input matrix bit identity failed",code:200)
            }
            chunkHashes.append(["Ycode":y,"triples":65_536,"scalarSHA256":ah,"vectorSHA256":bh])
        }
        try note("matrix-correctness-pass",["triples":16_777_216,"channelValues":50_331_648,"materializedOutputBytesCompared":402_653_184,"chunks":chunkHashes,"bitDifferences":0,"accounting":IBPerfClock.span(start,IBPerfClock.now(process:true)),"noPerformanceConclusion":"chunk materialization/hash/verification cost, not throughput benchmark"])
    }

    struct Inputs {
        let dir:URL,urls:[URL],bottom:[Int:CVPixelBuffer],top:[Int:CVPixelBuffer],png:CGImage,image:IBImage,transfer:IBTransfer,expected:[Int:String]
    }
    func inputs()async throws->Inputs {
        guard let path=ProcessInfo.processInfo.environment["OTF_IMG_B_OPT01_FIXTURES"],let reference=ProcessInfo.processInfo.environment["OTF_IMG_B_OPT01_BASELINE"] else{throw IBContract.error("OPT01 existing input paths required",code:300)}
        let dir=URL(fileURLWithPath:path),urls=["bottom.mov","top.mov","middle.png"].map{dir.appendingPathComponent($0)}
        guard try IBReference.digest(urls)=="26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1" else{throw IBContract.error("OPT01 fixture digest",code:200)}
        let png=try IBReference.loadPNG(urls[2]),transfer=try IBTransfer();var bottom=[Int:CVPixelBuffer](),top=[Int:CVPixelBuffer]()
        for phase in 0..<6 {bottom[phase]=try await IBReference.read(AVURLAsset(url:urls[0]),frame:phase,format:IBContract.format);if phase==2 || phase==3 {top[phase]=try await IBReference.read(AVURLAsset(url:urls[1]),frame:phase,format:IBContract.format)}}
        let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:reference))) as? [[String:Any]] ?? [];guard rows.count==6 else{throw IBContract.error("OPT01 Debug hash reference",code:200)}
        var expected=[Int:String]();for r in rows {if let phase=r["frame"] as? Int,let hash=r["SHA256"] as? String {expected[phase]=hash}}
        return Inputs(dir:dir,urls:urls,bottom:bottom,top:top,png:png.0,image:png.1,transfer:transfer,expected:expected)
    }
    func allocate()throws->CVPixelBuffer {
        var pb:CVPixelBuffer?;guard CVPixelBufferCreate(nil,1920,1080,IBContract.format,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pb)==kCVReturnSuccess,let pb else{throw IBContract.error("OPT01 output allocation",code:300)};return pb
    }
    func render(_ x:Inputs,_ phase:Int,_ vector:Bool,_ scalar:IB420Compositor,_ candidate:IBVectorInputCompositor)throws->(CVPixelBuffer,[String:Any],[String:Any]) {
        let instruction=IBInstruction(frame:phase,bottom:11,top:12,png:x.image,transfer:x.transfer,log:IBLog()),start=IBPerfClock.now(),out=try allocate(),pixel=IBPerfClock.now()
        if vector {try candidate.render(bottom:XCTUnwrap(x.bottom[phase]),top:x.top[phase],out:out,ins:instruction,deadline:Date().addingTimeInterval(30))}
        else {try scalar.render(bottom:XCTUnwrap(x.bottom[phase]),top:x.top[phase],out:out,ins:instruction,deadline:Date().addingTimeInterval(30))}
        let pixelTiming=IBPerfClock.span(pixel,IBPerfClock.now());IBContract.tag(out)
        return (out,IBPerfClock.span(start,IBPerfClock.now()),pixelTiming)
    }
    func compare(_ a:CVPixelBuffer,_ b:CVPixelBuffer,_ phase:Int,_ expected:String)throws->[String:Any] {
        let aa=try QA01.active(a),bb=try QA01.active(b)
        if aa != bb || QA01.sha(aa) != expected {
            try aa.write(to:root.appendingPathComponent("FIRST-baseline-phase\(phase).420v"));try bb.write(to:root.appendingPathComponent("FIRST-candidate-phase\(phase).420v"))
            let x=[UInt8](aa),y=[UInt8](bb);var maxes=[0,0,0],counts=[0,0,0],first=[[Int]](repeating:[],count:3)
            for k in x.indices {let c=k<2_073_600 ? 0:1+(k-2_073_600)%2,d=abs(Int(x[k])-Int(y[k]));if d>0 {counts[c]+=1;if first[c].isEmpty {first[c]=[k,Int(x[k]),Int(y[k])]} };maxes[c]=max(maxes[c],d)}
            try note("FIRST-RAW-FAIL",["phase":phase,"perY-Cb-CrMaximum":maxes,"differentBytes":counts,"firstOffsetsAndValues":first,"baselineSHA256":QA01.sha(aa),"candidateSHA256":QA01.sha(bb),"frozenDebugSHA256":expected])
            throw IBContract.error("OPT01 raw bit identity failed",code:200)
        }
        return ["phase":phase,"activeBytes":aa.count,"baselineSHA256":QA01.sha(aa),"candidateSHA256":QA01.sha(bb),"perY-Cb-CrMaximum":[0,0,0],"differentBytes":0]
    }
    func testSixFrameRawAndQA02()async throws{
        let x=try await inputs(),scalar=IB420Compositor(),candidate=IBVectorInputCompositor(),helper=ImageAware420GateTests();helper.root=root;helper.base=base;helper.diagnostics=diag
        for phase in 0..<6 {
            let a=try render(x,phase,false,scalar,candidate).0,b=try render(x,phase,true,scalar,candidate).0
            let raw=try compare(a,b,phase,try XCTUnwrap(x.expected[phase]));try note("raw-phase\(phase)",raw)
            let rgbA=try IBCanonicalNV12.bytes(a),rgbB=try IBCanonicalNV12.bytes(b),rgb=try IBReference.stats(rgbB,rgbA)
            guard rgb["maximum"] as? Int==0 else{throw IBContract.error("OPT01 canonical RGB difference",code:200)}
            try note("canonical-difference-phase\(phase)",rgb)
            try await helper.geometry(b,topURL:x.urls[1],frame:phase)
            try await helper.checkQuality(b,dir:x.dir,frame:phase,png:x.png,label:"vector-quality")
        }
        try note("six-frame-correctness-pass",["frames":6,"rawBitIdentity":true,"RGBMaximum":0,"sourceAndPhase":"frozen decoded0...5; expected PTS checked by existing reader","quality":"unchangedQA02 PSNR>=40/flat<=3; geometry/layer/alpha included","performance":"not interpreted until correctness phase passes"])
    }
    @inline(never) func scalarLoop(_ source:[SIMD3<Float>],_ destination:inout[Float]) {
        source.withUnsafeBufferPointer{s in destination.withUnsafeMutableBufferPointer{d in for i in s.indices {let v=IBVectorInputConversion.scalar(s[i].x,s[i].y,s[i].z);d[i*3]=v.x;d[i*3+1]=v.y;d[i*3+2]=v.z}}}
    }
    @inline(never) func vectorLoop(_ source:[SIMD3<Float>],_ destination:inout[Float]) {
        source.withUnsafeBufferPointer{s in destination.withUnsafeMutableBufferPointer{d in for i in s.indices {let v=IBVectorInputConversion.vector(s[i].x,s[i].y,s[i].z);d[i*3]=v.x;d[i*3+1]=v.y;d[i*3+2]=v.z}}}
    }
    func testMatchedReleasePerformance()async throws{
        guard let evidence=ProcessInfo.processInfo.environment["OTF_IMG_B_OPT01_CORRECTNESS"] else{throw IBContract.error("OPT01 documented correctness required",code:300)}
        let e=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:evidence))) as? [[String:Any]] ?? []
        guard e.last?["name"] as? String=="six-frame-correctness-pass" else{throw IBContract.error("OPT01 correctness prerequisite not passed",code:300)}
        var source=[SIMD3<Float>]();source.reserveCapacity(262_144)
        for i in 0..<262_144 {
            let yCode=(i*13)&255,cbCode=((i>>8)*7+i)&255,crCode=((i>>16)*17+i*11)&255
            let y=(Float(yCode)-16)/219,cb=(Float(cbCode)-128)/224,cr=(Float(crCode)-128)/224
            source.append(SIMD3<Float>(y,cb,cr))
        }
        var destination=[Float](repeating:0,count:source.count*3),micro=[[String:Any]](),hash:String?
        for repetition in 0..<3 {for vector in (repetition%2==0 ? [false,true]:[true,false]) {
            let start=IBPerfClock.now()
            if vector {vectorLoop(source,&destination)}else{scalarLoop(source,&destination)}
            let timing=IBPerfClock.span(start,IBPerfClock.now()),bytes=destination.withUnsafeBytes{Data($0)},digest=QA01.sha(bytes)
            if let hash {guard hash==digest else{throw IBContract.error("OPT01 suboperation output divergence",code:200)}}else{hash=digest}
            micro.append(["repetition":repetition,"candidate":vector,"timing":timing,"samples":source.count,"outputSHA256":digest])
        }}
        try note("suboperation-microbenchmark",["runs":micro,"scope":"forward matrix plus input loads/three output Float stores; no LUT/blend; hashing outside timer; source generation/allocation outside timer","P95":"n3 per implementation, withheld"])
        let x=try await inputs(),scalar=IB420Compositor(),candidate=IBVectorInputCompositor();var pairs=[[String:Any]]()
        for repetition in 0..<3 {for phase in 0..<6 {
            let candidateFirst=(repetition+phase)%2 != 0
            let first=try render(x,phase,candidateFirst,scalar,candidate),second=try render(x,phase,!candidateFirst,scalar,candidate)
            let baseResult=candidateFirst ? second:first,vectorResult=candidateFirst ? first:second
            _ = try compare(baseResult.0,vectorResult.0,phase,try XCTUnwrap(x.expected[phase]))
            pairs.append(["repetition":repetition,"phase":phase,"candidateFirst":candidateFirst,"baselineFull":baseResult.1,"candidateFull":vectorResult.1,"baselinePixel":baseResult.2,"candidatePixel":vectorResult.2])
        }}
        try note("matched-full-frame-performance",["pairs":pairs,"scope":"same cached actual decoded source buffers/staticPNG/LUT/instructions; fresh sameIOSurface allocations; full=allocation+wholeFHD render+tag, excludes output validation/diagnostics; pixel=whole baseline/candidate render function","matching":"3 six-frame paired repetitions, AB/BA alternates; 12image-active each,6no-image each; no OS cache flush or cold claim","deadlineGate":"predeclared>=5% image-active paired median wall improvement and CPU improvement; otherwise no90frame run"])
    }
}
