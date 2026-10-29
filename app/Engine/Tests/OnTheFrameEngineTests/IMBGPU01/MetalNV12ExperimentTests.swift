import XCTest
import AVFoundation
import CoreGraphics
import ImageIO

final class MetalNV12ExperimentTests:XCTestCase {
    var root:URL!,diag:IBDiagnostics!
    override func setUp() async throws {
        guard let p=ProcessInfo.processInfo.environment["OTF_IMG_GPU01_RUN"] else{throw XCTSkip("IMG-GPU-01 explicit opt-in")}
        let base=URL(fileURLWithPath:p).standardizedFileURL
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard base.path.hasPrefix(repo.appendingPathComponent("selftest-work").path+"/"),_isReleaseAssertConfiguration() else{throw IBContract.error("GPU01 Release/disposable root required",code:300)}
        root=base.appendingPathComponent("bounded");guard !FileManager.default.fileExists(atPath:root.path) else{throw IBContract.error("GPU01 fresh run required",code:300)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);diag=IBDiagnostics(root:root)
    }
    func note(_ n:String,_ v:[String:Any])throws{try diag.note(n,v)}
    func cpu(_ bottom:CVPixelBuffer,_ top:CVPixelBuffer?,_ phase:Int,_ image:IBImage,_ transfer:IBTransfer,_ renderer:IB420Compositor)throws->(CVPixelBuffer,[String:Any]) {
        let start=IBPerfClock.now(process:true),ins=IBInstruction(frame:phase,bottom:11,top:12,png:image,transfer:transfer,log:IBLog()),out=try GMNV12.allocate()
        try renderer.render(bottom:bottom,top:top,out:out,ins:ins,deadline:Date().addingTimeInterval(10));IBContract.tag(out)
        return(out,IBPerfClock.span(start,IBPerfClock.now(process:true)))
    }
    func raw(_ a:CVPixelBuffer,_ b:CVPixelBuffer)throws->[String:Any] {
        let x=[UInt8](try QA01.active(a)),y=[UInt8](try QA01.active(b));guard x.count==y.count else{throw IBContract.error("GPU01 raw extent",code:200)}
        var maxima=[0,0,0],counts=[0,0,0],first=[[Int]](repeating:[],count:3)
        for k in x.indices {let c=k<1920*1080 ? 0:1+(k-1920*1080)%2,d=abs(Int(x[k])-Int(y[k]));maxima[c]=max(maxima[c],d);if d>0 {counts[c]+=1;if first[c].isEmpty{first[c]=[k,Int(x[k]),Int(y[k])]}}}
        return ["Y-Cb-CrMaximum":maxima,"Y-Cb-CrDifferentCount":counts,"firstOffsetCPU-GPU":first,"CPUHash":QA01.sha(Data(x)),"GPUHash":QA01.sha(Data(y)),"note":"at most one code may differ at Float/UNORM rounding; independent RGB quality must also pass"]
    }
    func sourceID(_ pb:CVPixelBuffer,_ frame:Int)throws {
        try IBContract.validate(pb);CVPixelBufferLockBaseAddress(pb,.readOnly);defer{CVPixelBufferUnlockBaseAddress(pb,.readOnly)}
        let ptr=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,0)).assumingMemoryBound(to:UInt8.self),s=CVPixelBufferGetBytesPerRowOfPlane(pb,0);var id=0
        for bit in 0..<3 {if ptr[40*s+40+bit*48]>128{id |= 1<<bit}}
        guard id==frame else{throw IBContract.error("GPU01 source identity",code:200)}
    }
    func correctness(_ bottom:CVPixelBuffer,_ top:CVPixelBuffer?,_ phase:Int,_ image:IBImage,_ png:CGImage,_ transfer:IBTransfer,_ renderer:IB420Compositor,_ gpu:GMNV12,_ dir:URL,_ label:String)async throws->String {
        try sourceID(bottom,phase);if let top{try sourceID(top,phase)}
        let a=try cpu(bottom,top,phase,image,transfer,renderer),b=try gpu.render(bottom:bottom,top:top,phase:phase)
        let rawStats=try raw(a.0,b.0);try note(label+"-raw",rawStats)
        let cpuRGB=try IBCanonicalNV12.bytes(a.0),gpuRGB=try IBCanonicalNV12.bytes(b.0),difference=try IBReference.stats(gpuRGB,cpuRGB)
        try note(label+"-canonical-CPU-GPU",difference)
        let maxes=rawStats["Y-Cb-CrMaximum"] as? [Int] ?? [999]
        guard maxes.max()!<=1,(difference["maximum"] as? Int ?? 999)<=3,difference["qualityPass"] as? Bool==true else{
            try QA01.active(b.0).write(to:root.appendingPathComponent(label+"-FIRST-FAIL.420v"));throw IBContract.error("GPU01 material CPU/GPU mismatch",code:400)
        }
        let helper=ImageAware420GateTests();helper.root=root;helper.base=root;helper.diagnostics=diag
        try await helper.geometry(b.0,topURL:dir.appendingPathComponent("top.mov"),frame:phase)
        // Unchanged independent decoded BGRA+ICC/CG source-over and sampled420 QA02 references.
        try await helper.checkQuality(b.0,dir:dir,frame:phase,png:png,label:label)
        // Canonical CPU/GPU edge-region statistics are separate from raw and independent quality.
        var edges=[String:Any]()
        for (name,rect) in [("PNG640",CGRect(x:636,y:0,width:8,height:1080)),("PNG1280",CGRect(x:1276,y:0,width:8,height:1080)),("top960",CGRect(x:956,y:540,width:8,height:540)),("top540",CGRect(x:960,y:536,width:960,height:8))] {
            edges[name]=try QA01.stats(gpuRGB,cpuRGB,width:1920,height:1080,region:rect)
        }
        try note(label+"-correctness-PASS",["phase":phase,"expectedPTS":"\(phase)/30","PTSAuthority":"existing reader verifies exact sample PTS; GPU output is direct-buffer plus phase sidecar, no AV callback","CPUFirstUse":a.1,"GPUFirstUse":b.1,"edgesCPU-GPU":edges])
        return try XCTUnwrap(rawStats["GPUHash"] as? String)
    }
    func testBoundedMetalNV12()async throws {
        do {
            guard let path=ProcessInfo.processInfo.environment["OTF_IMG_GPU01_FIXTURES"] else{throw IBContract.error("GPU01 fixed fixtures required",code:300)}
            let dir=URL(fileURLWithPath:path),urls=["bottom.mov","top.mov","middle.png"].map{dir.appendingPathComponent($0)}
            guard try IBReference.digest(urls)=="26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1" else{throw IBContract.error("GPU01 fixed digest",code:200)}
            let prep=IBPerfClock.now(process:true),transfer=try IBTransfer(),png=try IBReference.loadPNG(urls[2]),prepared=IBPerfClock.now(process:true)
            var rgba=[UInt8](repeating:0,count:1920*1080*4)
            for k in stride(from:0,to:rgba.count,by:4){rgba[k]=100;rgba[k+1]=25;rgba[k+2]=13;rgba[k+3]=128}
            let minURL=root.appendingPathComponent("minimum-50alpha.png");try IBReference.save(IBReference.image(rgba),to:minURL)
            guard let src=CGImageSourceCreateWithURL(minURL as CFURL,nil),let decoded=CGImageSourceCreateImageAtIndex(src,0,nil) else{throw IBContract.error("GPU01 min PNG decode",code:300)}
            let minBytes=try IBReference.bytes(decoded);guard stride(from:3,to:minBytes.count,by:4).allSatisfy({minBytes[$0]==128}) else{throw IBContract.error("GPU01 minimum alpha",code:200)}
            let minPNG=try IBReference.image(minBytes),minimum=IBImage(rgba:minBytes),minimumPrepared=IBPerfClock.now(process:true)
            let b1=try await IBReference.read(AVURLAsset(url:urls[0]),frame:1,format:IBContract.format),decodedAt=IBPerfClock.now(process:true)
            let initCPU=IBPerfClock.now(process:true),renderer=IB420Compositor(),afterCPU=IBPerfClock.now(process:true),minimumGPU=try GMNV12(image:minimum,transfer:transfer)
            try note("preparation",["LUTAndExistingPNG":IBPerfClock.span(prep,prepared),"minimumPNGGenerateWriteDecode":IBPerfClock.span(prepared,minimumPrepared),"minimumSourceDecode":IBPerfClock.span(minimumPrepared,decodedAt),"CPUConstructor":IBPerfClock.span(initCPU,afterCPU),"minimumPNGHash":QA01.sha(try Data(contentsOf:minURL)),"minimumGPUSetup":minimumGPU.setup,"scope":"Metal only, no CPU fallback; minimum before expanded; no performance interpretation before correctness","thresholds":"PSNR>=40dB, flat<=3, exact geometry and sourcePTS, material discrepancy stop"])
            _ = try await correctness(b1,nil,1,minimum,minPNG,transfer,renderer,minimumGPU,dir,"minimum")
            try note("minimum-gate-PASS",["next":"existing six-frame correctness only"])
            let gpu=try GMNV12(image:png.1,transfer:transfer);try note("expanded-GPU-setup",gpu.setup)
            var bottom=[Int:CVPixelBuffer](),top=[Int:CVPixelBuffer](),expected=[Int:String](),decodeRows=[[String:Any]]()
            for phase in 0..<6 {
                let start=IBPerfClock.now(process:true);bottom[phase]=try await IBReference.read(AVURLAsset(url:urls[0]),frame:phase,format:IBContract.format)
                if phase==2 || phase==3{top[phase]=try await IBReference.read(AVURLAsset(url:urls[1]),frame:phase,format:IBContract.format)}
                decodeRows.append(["phase":phase,"decode":IBPerfClock.span(start,IBPerfClock.now(process:true))])
                expected[phase]=try await correctness(XCTUnwrap(bottom[phase]),top[phase],phase,png.1,png.0,transfer,renderer,gpu,dir,"expanded\(phase)")
            }
            try note("six-frame-gate-PASS",["decode":decodeRows,"outputHashes":expected.map{["phase":$0.key,"SHA256":$0.value]},"performance":"only now allowed"])
            var pairs=[[String:Any]]()
            for repetition in 0..<3 {for phase in 0..<6 {
                let b=try XCTUnwrap(bottom[phase]),t=top[phase],candidateFirst=(repetition+phase)%2 != 0
                let c:(CVPixelBuffer,[String:Any]),g:(CVPixelBuffer,[String:Any])
                if candidateFirst{g=try gpu.render(bottom:b,top:t,phase:phase);c=try cpu(b,t,phase,png.1,transfer,renderer)}else{c=try cpu(b,t,phase,png.1,transfer,renderer);g=try gpu.render(bottom:b,top:t,phase:phase)}
                let verify=try raw(c.0,g.0);guard verify["GPUHash"] as? String==expected[phase],(verify["Y-Cb-CrMaximum"] as? [Int])?.max() ?? 999<=1 else{throw IBContract.error("GPU01 benchmark output/stale failure",code:200)}
                pairs.append(["repetition":repetition,"phase":phase,"GPUFirst":candidateFirst,"CPUFull":c.1,"GPU":g.1,"raw":verify])
            }}
            try note("matched-performance-complete",["pairs":pairs,"matching":"same cached decoded NV12, originalPNG/LUT; fresh same allocation attributes;3x6 AB/BA; output hashes enabled outside timer","boundary":"full=instruction/output allocation or CVMetal plane mapping, encode/submit, completion wait, NV12 delivery. Excludes separately reported source/PNG preparation, pipeline setup and post-delivery QA. GPUSeconds not end-to-end.","cold":"first-use timings recorded during correctness with fresh output/views and GPU instance; includes possible cache warming; no OS cache flush/clean-cold claim","P95":"withheld per image-active workload n12, copy n6" ])
        } catch {
            try? note("FIRST-FAIL-STOP",["error":String(describing:error),"policy":"no alternate path, no correctness retry or implementation tuning"])
            throw error
        }
    }
    func testDecodeToDeliveryAfterCorrectness()async throws {
        guard let proof=ProcessInfo.processInfo.environment["OTF_IMG_GPU01_CORRECTNESS"],let fixtures=ProcessInfo.processInfo.environment["OTF_IMG_GPU01_FIXTURES"] else{throw IBContract.error("GPU01 decode benchmark prerequisites",code:300)}
        let evidence=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:proof))) as? [[String:Any]] ?? []
        guard evidence.contains(where:{$0["name"] as? String=="six-frame-gate-PASS"}),evidence.last?["name"] as? String=="matched-performance-complete" else{throw IBContract.error("GPU01 prior correctness not passed",code:300)}
        let dir=URL(fileURLWithPath:fixtures),urls=["bottom.mov","top.mov","middle.png"].map{dir.appendingPathComponent($0)}
        guard try IBReference.digest(urls)=="26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1" else{throw IBContract.error("GPU01 decode fixture digest",code:200)}
        var hashes=[Int:String]()
        for row in evidence where (row["name"] as? String)?.hasPrefix("expanded")==true && (row["name"] as? String)?.hasSuffix("-raw")==true {
            let name=row["name"] as! String,phase=Int(name.replacingOccurrences(of:"expanded",with:"").replacingOccurrences(of:"-raw",with:""))!
            hashes[phase]=(row["fields"] as? [String:Any])?["GPUHash"] as? String
        }
        guard hashes.count==6 else{throw IBContract.error("GPU01 six verified hashes required",code:300)}
        let prepared=IBPerfClock.now(process:true),png=try IBReference.loadPNG(urls[2]),transfer=try IBTransfer(),cpuRenderer=IB420Compositor(),gpu=try GMNV12(image:png.1,transfer:transfer)
        try note("static-preparation",["all":IBPerfClock.span(prepared,IBPerfClock.now(process:true)),"GPUSetup":gpu.setup,"scope":"shared static PNG/LUT, pipeline prepared once; fresh AVURLAsset and Reader each measured frame; no OS cache flush"])
        func frame(_ phase:Int,_ useGPU:Bool)async throws->(CVPixelBuffer,[String:Any]) {
            let start=IBPerfClock.now(process:true)
            let bottom=try await IBReference.read(AVURLAsset(url:urls[0]),frame:phase,format:IBContract.format)
            let top:CVPixelBuffer? = (phase==2 || phase==3) ? try await IBReference.read(AVURLAsset(url:urls[1]),frame:phase,format:IBContract.format):nil
            try sourceID(bottom,phase);if let top{try sourceID(top,phase)}
            let decoded=IBPerfClock.now(process:true),result:(CVPixelBuffer,[String:Any])
            if useGPU {result=try gpu.render(bottom:bottom,top:top,phase:phase)}else{result=try cpu(bottom,top,phase,png.1,transfer,cpuRenderer)}
            return(result.0,["decodeAndSourceValidation":IBPerfClock.span(start,decoded),"render":result.1,"decodeToDelivery":IBPerfClock.span(start,IBPerfClock.now(process:true))])
        }
        var pairs=[[String:Any]]()
        for repetition in 0..<3 {for phase in 0..<6 {
            let gpuFirst=(repetition+phase)%2 != 0,c:(CVPixelBuffer,[String:Any]),g:(CVPixelBuffer,[String:Any])
            if gpuFirst{g=try await frame(phase,true);c=try await frame(phase,false)}else{c=try await frame(phase,false);g=try await frame(phase,true)}
            let verify=try raw(c.0,g.0)
            guard verify["GPUHash"] as? String==hashes[phase],(verify["Y-Cb-CrMaximum"] as? [Int])?.max() ?? 999<=1 else{throw IBContract.error("GPU01 decode benchmark correctness/stale stop",code:200)}
            pairs.append(["phase":phase,"repetition":repetition,"GPUFirst":gpuFirst,"CPU":c.1,"GPU":g.1,"raw":verify])
            try note("decode-pair-\(repetition)-\(phase)",["CPUFull":c.1["decodeToDelivery"]!,"GPUFull":g.1["decodeToDelivery"]!])
        }}
        try note("decode-to-delivery-complete",["pairs":pairs,"scope":"fresh source readers/decode and identity validation through completed output delivery; static PNG/LUT/pipeline prepared; post-delivery raw hash outside timer; no playback/encoder; AB/BA3x6","P95":"withheld n12 image-active and n6 copy" ])
    }
}
