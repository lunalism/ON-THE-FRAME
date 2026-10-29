import XCTest
import Metal
import AVFoundation

final class GenerationRecoveryTests:XCTestCase {
    func testOneNewGenerationImageRequest()async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_GPU02E_RUN"],let fixture=ProcessInfo.processInfo.environment["OTF_IMG_GPU01_FIXTURES"],let managed=ProcessInfo.processInfo.environment["OTF_GPU02E_MANAGED"] else{throw XCTSkip("GPU02E explicit opt-in")}
        let run=URL(fileURLWithPath:path).standardizedFileURL
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func account()throws{_ = try GMArtifactBoundary.check(root:run,parent:repo.appendingPathComponent("app/selftest-work"),extra:131072,combined:{try GMArtifactBoundary.allocated([repo.path,managed])})}
        try account()
        let root=run.appendingPathComponent("generation")
        guard !FileManager.default.fileExists(atPath:root.path) else{throw IBContract.error("fresh generation output required",code:300)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let diag=IBDiagnostics(root:root),dir=URL(fileURLWithPath:fixture),urls=["bottom.mov","top.mov","middle.png"].map{dir.appendingPathComponent($0)}
        guard try IBReference.digest(urls)=="26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1" else{throw IBContract.error("GPU02E fixtures",code:200)}
        let bottom=try await IBReference.read(AVURLAsset(url:urls[0]),frame:2,format:IBContract.format),top=try await IBReference.read(AVURLAsset(url:urls[1]),frame:2,format:IBContract.format),png=try IBReference.loadPNG(urls[2]),transfer=try IBTransfer(),gpu=try GMNV12(image:png.1,transfer:transfer)
        let cpu=try GMNV12.allocate(),ins=IBInstruction(frame:2,bottom:11,top:12,png:png.1,transfer:transfer,log:IBLog())
        try IB420Compositor().render(bottom:bottom,top:top,out:cpu,ins:ins,deadline:Date().addingTimeInterval(10));IBContract.tag(cpu)
        let expected="4ea33d39d0dd2a84afa24c2559c644c095cdc58f13b2013022008522490ffad2"
        guard QA01.sha(try QA01.active(cpu))==expected else{throw IBContract.error("GPU02E frozen CPU hash",code:200)}
        let oldQueue=try XCTUnwrap(gpu.device.makeCommandQueue()),event=try XCTUnwrap(gpu.device.makeSharedEvent()),oldCommand=try XCTUnwrap(oldQueue.makeCommandBuffer()),buffer=try XCTUnwrap(gpu.device.makeBuffer(length:4096,options:.storageModeShared)),finished=DispatchSemaphore(value:0)
        // A second command queue allows the new image command to finish while the old queue waits.
        // Both requests use the renderer's SAME GMLeaseBook, not a replacement book.
        var oldTerminals=[GMLeaseBook.State](),publications=[String](),drained=false
        let old=try XCTUnwrap(gpu.leases.admit([oldCommand,oldQueue,event,buffer]){s in oldTerminals.append(s);if s == .completed{publications.append("old")}})
        oldCommand.encodeWaitForEvent(event,value:1)
        let blit=try XCTUnwrap(oldCommand.makeBlitCommandEncoder());blit.fill(buffer:buffer,range:0..<4096,value:71);blit.endEncoding()
        oldCommand.addCompletedHandler{c in gpu.leases.observedCompletion(old,failed:c.status != .completed);finished.signal()}
        defer{if !drained{event.signaledValue=1;_ = finished.wait(timeout:.now()+10)}}
        guard gpu.leases.submit(old) else{throw IBContract.error("old admission",code:200)};oldCommand.commit()
        guard oldCommand.status != .completed,event.signaledValue==0 else{throw IBContract.error("old operation completed before cancellation",code:200)}
        gpu.leases.replaceGeneration()
        guard oldTerminals==[.canceled],old.generation==0,!old.resources.isEmpty,gpu.leases.counts.active==1 else{throw IBContract.error("old invalidation/retention",code:200)}
        try diag.note("old-canceled-retained",["requestID":old.id,"generation":old.generation,"terminalCount":oldTerminals.count,"active":gpu.leases.counts.active,"status":oldCommand.status.rawValue,"eventValue":event.signaledValue])
        // Exactly ONE image-aware new-generation request, through unchanged GMNV12.render admission.
        let result=try gpu.render(bottom:bottom,top:top,phase:2)
        guard oldCommand.status != .completed,gpu.leases.counts.active==1,gpu.leases.highActive==2,!old.resources.isEmpty else{throw IBContract.error("new admission or old lifetime",code:200)}
        let actual=try QA01.active(result.0),baseline=try QA01.active(cpu)
        guard actual==baseline,QA01.sha(actual)==expected,result.1["outputPTS"] as? String=="2/30 (test sidecar; not AV callback)" else{throw IBContract.error("new output identity/PTS/raw",code:200)}
        publications.append("new-generation1-request2")
        let rgb=try IBReference.stats(IBCanonicalNV12.bytes(result.0),IBCanonicalNV12.bytes(cpu))
        guard rgb["maximum"] as? Int==0 else{throw IBContract.error("new canonical RGB",code:400)}
        let helper=ImageAware420GateTests();helper.root=root;helper.base=run;helper.diagnostics=diag
        try await helper.geometry(result.0,topURL:urls[1],frame:2)
        try await helper.checkQuality(result.0,dir:dir,frame:2,png:png.0,label:"new-generation")
        event.signaledValue=1
        guard finished.wait(timeout:.now()+10) == .success else{gpu.leases.quarantineUnobserved();throw IBContract.error("old completion timeout",code:300)};drained=true
        guard oldCommand.status == .completed,oldTerminals==[.canceled],publications==["new-generation1-request2"],old.retired,old.resources.isEmpty,gpu.leases.counts.active==0,gpu.leases.counts.pending==0,buffer.contents().load(as:UInt8.self)==71 else{throw IBContract.error("late completion/stale/drain",code:200)}
        try diag.note("generation-recovery-PASS",["oldRequestID":old.id,"oldGeneration":old.generation,"newGeneration":1,"newRequestID":2,"identityAuthority":"book begins empty; old ticket1; render creates its sole ticket2 after replaceGeneration; no synthetic client completion injected","newClientPublications":publications,"oldTerminalCount":oldTerminals.count,"oldCommandStatus":oldCommand.status.rawValue,"oldGPUSeconds":oldCommand.gpuEndTime-oldCommand.gpuStartTime,"newFrame":2,"intendedPTS":"2/30","rawSHA256":QA01.sha(actual),"rawY-Cb-CrMaximum":[0,0,0],"canonicalCPU-GPUMaximum":rgb["maximum"]!,"newTiming":result.1,"activeHigh":gpu.leases.highActive,"pendingHigh":gpu.leases.highPending,"postDrainActive":gpu.leases.counts.active,"postDrainPending":gpu.leases.counts.pending,"oldResourcesAfterDrain":old.resources.count,"GPUAllocatedAfterDrain":gpu.device.currentAllocatedSize])
        try account()
    }
}
