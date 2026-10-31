import XCTest
import Metal
import AVFoundation

final class GenerationRecoveryTests:XCTestCase {
    /// Bounded event trace; completion callbacks never mutate IBDiagnostics concurrently.
    final class Trace: @unchecked Sendable {
        private let lock=NSLock()
        private var rows=[[String:Any]]()
        func add(_ event:String,_ fields:[String:Any]=[:]) {
            lock.lock();defer{lock.unlock()}
            var row=fields;row["event"]=event;row["order"]=rows.count+1;row["ns"]=DispatchTime.now().uptimeNanoseconds
            rows.append(row)
        }
        var snapshot:[[String:Any]] {lock.lock();defer{lock.unlock()};return rows}
    }
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
        let trace=Trace()
        func commandState(_ command:MTLCommandBuffer)->[String:Any] {
            let error=command.error as NSError?
            return ["status":command.status.rawValue,"errorDomain":error?.domain ?? "none","errorCode":error?.code ?? 0,"errorDescription":error?.localizedDescription ?? "none"]
        }
        var oldTerminals=[GMLeaseBook.State](),publications=[String](),drained=false
        let old=try XCTUnwrap(gpu.leases.admit([oldCommand,oldQueue,event,buffer]){s in
            oldTerminals.append(s);if s == .completed{publications.append("old")}
            trace.add("old-client-terminal",["requestID":1,"generation":0,"terminal":s.rawValue,"publishedOld":s == .completed])
        })
        trace.add("old-lease-acquired",["requestID":old.id,"generation":old.generation,"resources":old.resources.count,"active":gpu.leases.counts.active,"pending":gpu.leases.counts.pending])
        oldCommand.encodeWaitForEvent(event,value:1)
        let blit=try XCTUnwrap(oldCommand.makeBlitCommandEncoder());blit.fill(buffer:buffer,range:0..<4096,value:71);blit.endEncoding()
        oldCommand.addCompletedHandler{c in
            trace.add("old-GPU-completion-observed",["requestID":old.id,"generation":old.generation,"command":commandState(c),"activeBefore":gpu.leases.counts.active])
            gpu.leases.observedCompletion(old,failed:c.status != .completed)
            trace.add("old-lease-retired",["requestID":old.id,"generation":old.generation,"retired":old.retired,"resources":old.resources.count,"active":gpu.leases.counts.active,"pending":gpu.leases.counts.pending])
            finished.signal()
        }
        defer{if !drained{event.signaledValue=1;_ = finished.wait(timeout:.now()+10)}}
        guard gpu.leases.submit(old) else{throw IBContract.error("old admission",code:200)};oldCommand.commit()
        guard oldCommand.status != .completed,event.signaledValue==0 else{throw IBContract.error("old operation completed before cancellation",code:200)}
        trace.add("old-submitted",["requestID":old.id,"generation":old.generation,"command":commandState(oldCommand),"eventValue":event.signaledValue])
        gpu.leases.replaceGeneration()
        trace.add("generation-replaced",["oldRequestID":old.id,"oldGeneration":old.generation,"newGeneration":1,"state":old.state.rawValue,"terminal":old.terminal?.rawValue ?? "none","resources":old.resources.count,"active":gpu.leases.counts.active,"pending":gpu.leases.counts.pending])
        guard oldTerminals==[.canceled],old.generation==0,!old.resources.isEmpty,gpu.leases.counts.active==1 else{throw IBContract.error("old invalidation/retention",code:200)}
        try diag.note("old-canceled-retained",["requestID":old.id,"generation":old.generation,"terminalCount":oldTerminals.count,"active":gpu.leases.counts.active,"status":oldCommand.status.rawValue,"eventValue":event.signaledValue])
        // Exactly ONE image-aware new-generation request, through unchanged GMNV12.render admission.
        trace.add("new-render-start",["expectedRequestID":2,"expectedGeneration":1,"oldCommand":commandState(oldCommand)])
        let result=try gpu.render(bottom:bottom,top:top,phase:2)
        trace.add("new-render-complete",["requestID":result.1["requestID"] ?? -1,"generation":result.1["generationID"] ?? -1,"active":gpu.leases.counts.active,"pending":gpu.leases.counts.pending,"oldCommand":commandState(oldCommand),"oldResources":old.resources.count])
        guard oldCommand.status != .completed,gpu.leases.counts.active==1,gpu.leases.highActive==2,!old.resources.isEmpty else{throw IBContract.error("new admission or old lifetime",code:200)}
        let actual=try QA01.active(result.0),baseline=try QA01.active(cpu)
        guard actual==baseline,QA01.sha(actual)==expected,result.1["outputPTS"] as? String=="2/30 (test sidecar; not AV callback)" else{throw IBContract.error("new output identity/PTS/raw",code:200)}
        guard result.1["requestID"] as? Int==2,result.1["generationID"] as? Int==1 else{throw IBContract.error("new request/generation identity",code:200)}
        publications.append("new-generation1-request2")
        trace.add("new-client-publication",["requestID":2,"generation":1,"frame":2,"expectedHash":expected,"actualHash":QA01.sha(actual),"published":publications])
        // The old command has already remained in flight through actual new-generation
        // admission, rendering, identity verification and publication. Release its event
        // now; CPU color/quality analysis is not part of GPU lease lifetime validation.
        trace.add("release-old-GPU-event",["oldCommand":commandState(oldCommand)])
        event.signaledValue=1
        guard finished.wait(timeout:.now()+10) == .success else{gpu.leases.quarantineUnobserved();throw IBContract.error("old completion timeout",code:300)};drained=true
        // Freeze every original predicate at the original observation point before logging.
        let status=oldCommand.status,terminals=oldTerminals,published=publications,retired=old.retired,remaining=old.resources.count,counts=gpu.leases.counts,byte=buffer.contents().load(as:UInt8.self)
        let predicates:[String:Bool] = ["A_commandCompleted":status == .completed,"A_exactlyOneCancelledTerminal":terminals == [.canceled],"B_onlyNewGenerationPublished":published == ["new-generation1-request2"],"C_oldRetired":retired,"C_resourcesEmpty":remaining==0,"C_activeZero":counts.active==0,"C_pendingZero":counts.pending==0,"A_GPUWriteVisible":byte==71]
        trace.add("final-guard",["requestID":old.id,"generation":old.generation,"command":commandState(oldCommand),"capturedStatus":status.rawValue,"terminals":terminals.map(\.rawValue),"published":published,"retired":retired,"resources":remaining,"active":counts.active,"pending":counts.pending,"expectedByte":71,"actualByte":Int(byte),"predicates":predicates])
        try diag.note("generation-predicate-trace",["events":trace.snapshot,"predicates":predicates,"failedPredicates":predicates.filter{!$0.value}.map(\.key).sorted()])
        guard status == .completed,terminals==[.canceled],published==["new-generation1-request2"],retired,remaining==0,counts.active==0,counts.pending==0,byte==71 else{throw IBContract.error("late completion/stale/drain",code:200)}
        let rgb=try IBReference.stats(IBCanonicalNV12.bytes(result.0),IBCanonicalNV12.bytes(cpu))
        guard rgb["maximum"] as? Int==0 else{throw IBContract.error("new canonical RGB",code:400)}
        trace.add("quality-check-start",["oldCommand":commandState(oldCommand)])
        let helper=ImageAware420GateTests();helper.root=root;helper.base=run;helper.diagnostics=diag
        try await helper.geometry(result.0,topURL:urls[1],frame:2)
        try await helper.checkQuality(result.0,dir:dir,frame:2,png:png.0,label:"new-generation")
        trace.add("quality-check-finish",["oldCommand":commandState(oldCommand),"active":gpu.leases.counts.active,"pending":gpu.leases.counts.pending])
        try diag.note("generation-event-order",["events":trace.snapshot])
        try diag.note("generation-recovery-PASS",["oldRequestID":old.id,"oldGeneration":old.generation,"newGeneration":1,"newRequestID":2,"identityAuthority":"book begins empty; old ticket1; render creates its sole ticket2 after replaceGeneration; no synthetic client completion injected","newClientPublications":publications,"oldTerminalCount":oldTerminals.count,"oldCommandStatus":oldCommand.status.rawValue,"oldGPUSeconds":oldCommand.gpuEndTime-oldCommand.gpuStartTime,"newFrame":2,"intendedPTS":"2/30","rawSHA256":QA01.sha(actual),"rawY-Cb-CrMaximum":[0,0,0],"canonicalCPU-GPUMaximum":rgb["maximum"]!,"newTiming":result.1,"activeHigh":gpu.leases.highActive,"pendingHigh":gpu.leases.highPending,"postDrainActive":gpu.leases.counts.active,"postDrainPending":gpu.leases.counts.pending,"oldResourcesAfterDrain":old.resources.count,"GPUAllocatedAfterDrain":gpu.device.currentAllocatedSize])
        try account()
    }
}
