import XCTest
import Metal
import AVFoundation

final class SustainedLeaseTests:XCTestCase {
    func testBounded90()async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_GPU02B_RUN"],let fixture=ProcessInfo.processInfo.environment["OTF_IMG_GPU01_FIXTURES"] else{throw XCTSkip("GPU02B opt-in")}
        let run=URL(fileURLWithPath:path).standardizedFileURL
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // #file is in app/Engine/Tests/.../IMBGPU01: six parents reach repository.
        guard let managed=ProcessInfo.processInfo.environment["OTF_GPU02BR_MANAGED"] else{throw IBContract.error("managed root required",code:300)}
        let baselineBuild=try GMArtifactBoundary.allocated([managed])
        func account()throws {
            let build=try GMArtifactBoundary.allocated([managed])
            _ = try GMArtifactBoundary.check(root:run,parent:repo.appendingPathComponent("app/selftest-work"),extra:max(0,build-baselineBuild)+131072,combined:{try GMArtifactBoundary.allocated([repo.path,managed])})
        }
        try account()
        let root=run.appendingPathComponent("sustained")
        guard !FileManager.default.fileExists(atPath:root.path) else{throw IBContract.error("fresh sustained subroot required",code:300)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let diag=IBDiagnostics(root:root)
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("results.json").path) else{throw IBContract.error("fresh GPU02B evidence required",code:300)}
        let dir=URL(fileURLWithPath:fixture),urls=["bottom.mov","top.mov","middle.png"].map{dir.appendingPathComponent($0)}
        guard try IBReference.digest(urls)=="26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1" else{throw IBContract.error("fixture digest",code:200)}
        let prep=IBPerfClock.now(process:true),png=try IBReference.loadPNG(urls[2]),transfer=try IBTransfer(),cpu=IB420Compositor()
        var bottom=[Int:CVPixelBuffer](),top=[Int:CVPixelBuffer](),hashes=[Int:String]()
        for phase in 1...4 {
            bottom[phase]=try await IBReference.read(AVURLAsset(url:urls[0]),frame:phase,format:IBContract.format)
            if phase==2 || phase==3 {top[phase]=try await IBReference.read(AVURLAsset(url:urls[1]),frame:phase,format:IBContract.format)}
            let out=try GMNV12.allocate(),ins=IBInstruction(frame:phase,bottom:11,top:12,png:png.1,transfer:transfer,log:IBLog())
            try cpu.render(bottom:bottom[phase]!,top:top[phase],out:out,ins:ins,deadline:Date().addingTimeInterval(10));IBContract.tag(out);hashes[phase]=QA01.sha(try QA01.active(out))
            let helper=ImageAware420GateTests();helper.root=root;helper.base=root;helper.diagnostics=diag
            try await helper.checkQuality(out,dir:dir,frame:phase,png:png.0,label:"CPU-reference")
        }
        let setup=IBPerfClock.now(process:true),gpu=try GMNV12(image:png.1,transfer:transfer)
        try diag.note("plan",["positions":90,"PTS":"n/30","sourcePhase":"[1,2,3,4][n%4]; all90 image-active; sourcePTS=phase/30 validated by reader","decodedCacheActiveBytes":6*3_110_400,"sourceAndCPUReferencePrep":IBPerfClock.span(prep,setup),"GPUSetup":gpu.setup,"planSHA256":QA01.sha(Data((0..<90).map{"\($0)/30->\(1+$0%4)/30"}.joined(separator:"\n").utf8))])
        func render(_ n:Int,_ intended:UInt64,_ arrival:UInt64)throws->[String:Any] {
            try autoreleasepool {
                let phase=1+n%4,start=DispatchTime.now().uptimeNanoseconds
                let result=try gpu.render(bottom:bottom[phase]!,top:top[phase],phase:phase)
                guard QA01.sha(try QA01.active(result.0))==hashes[phase] else{throw IBContract.error("90frame raw mismatch",code:200)}
                let complete=DispatchTime.now().uptimeNanoseconds
                guard gpu.leases.counts.active==0,gpu.leases.counts.pending==0 else{throw IBContract.error("90frame lease drain",code:200)}
                return ["position":n,"PTSValue":n,"PTSTimescale":30,"phase":phase,"intendedNs":intended,"actualSubmissionNs":arrival,"startNs":start,"clientCompletionNs":complete,"deadlineNs":intended+1_000_000_000/30,"rawHash":hashes[phase]!,"timing":result.1,"postDrainActive":0,"postDrainPending":0,"rss":diag.rss()]
            }
        }
        try account()
        var offline=[[String:Any]]();let begin=DispatchTime.now().uptimeNanoseconds
        for n in 0..<90 {let now=DispatchTime.now().uptimeNanoseconds;offline.append(try render(n,now,now))}
        try diag.note("offline-PASS",["rows":offline,"elapsedSeconds":Double(DispatchTime.now().uptimeNanoseconds-begin)/1e9,"activeHigh":gpu.leases.highActive,"pendingHigh":gpu.leases.highPending,"deviceAllocatedAfterDrain":gpu.device.currentAllocatedSize])
        try account()
        // One mixed generation scenario: two submitted event-blocked commands plus four pending.
        let book=GMLeaseBook(),event=try XCTUnwrap(gpu.device.makeSharedEvent()),done=DispatchGroup(),counter=NSLock();var terminals=[GMLeaseBook.State](),tickets=[GMLeaseBook.Ticket]()
        for i in 0..<6 {
            let buffer=try XCTUnwrap(gpu.device.makeBuffer(length:4096,options:.storageModeShared))
            let t=try XCTUnwrap(book.admit([buffer,event]){s in counter.lock();terminals.append(s);counter.unlock()});tickets.append(t)
            if i<2 {let cmd=try XCTUnwrap(gpu.queue.makeCommandBuffer());t.resources.append(cmd);cmd.encodeWaitForEvent(event,value:1);let blit=try XCTUnwrap(cmd.makeBlitCommandEncoder());blit.fill(buffer:buffer,range:0..<4096,value:17);blit.endEncoding();done.enter();cmd.addCompletedHandler{c in book.observedCompletion(t,failed:c.status != .completed);done.leave()};XCTAssertTrue(book.submit(t));cmd.commit()}
        }
        book.replaceGeneration();XCTAssertEqual(book.counts.active,2);XCTAssertEqual(book.counts.pending,0);XCTAssertTrue(tickets.prefix(2).allSatisfy{!$0.resources.isEmpty});event.signaledValue=1
        guard done.wait(timeout:.now()+10) == .success else{book.quarantineUnobserved();throw IBContract.error("mixed drain timeout",code:300)}
        guard terminals.count==6,terminals.allSatisfy({$0 == .canceled}),book.counts.active==0,tickets.allSatisfy({$0.resources.isEmpty}) else{throw IBContract.error("mixed generation failure",code:200)}
        try diag.note("mixed-generation-PASS",["canceled":6,"published":0,"activeHigh":book.highActive,"pendingHigh":book.highPending,"postDrainActive":book.counts.active,"postDrainPending":book.counts.pending])
        let lock=NSLock(),finished=DispatchSemaphore(value:0),worker=DispatchQueue(label:"GPU02B.worker"),producer=DispatchQueue(label:"GPU02B.strict")
        var paced=[[String:Any]](),failure:Error?,outstanding=0,high=0
        let t0=DispatchTime.now().uptimeNanoseconds+100_000_000
        let driver=IBPacedArrivalPlan(queue:producer,start:t0,strategy:"strict") {n,arrival in
            lock.lock();if outstanding>=5 {failure=IBContract.error("bounded pending overflow",code:200);lock.unlock();finished.signal();return};outstanding+=1;high=max(high,outstanding);lock.unlock()
            worker.async {
                do {let row=try render(n,t0+UInt64(n)*1_000_000_000/30,arrival);lock.lock();paced.append(row);outstanding-=1;let last=paced.count==90;lock.unlock();if last{finished.signal()}}
                catch{lock.lock();failure=error;lock.unlock();finished.signal()}
            }
        }
        driver.begin();guard finished.wait(timeout:.now()+10) == .success else{driver.cancel();throw IBContract.error("paced timeout",code:300)};driver.cancel();worker.sync{}
        if let failure{throw failure};guard paced.count==90,Set(paced.compactMap{$0["position"] as? Int}).count==90 else{throw IBContract.error("missing/duplicate",code:200)}
        try account()
        let fidelity=IBPacedFidelity.summary(paced),misses=paced.filter{($0["clientCompletionNs"] as! UInt64)>($0["deadlineNs"] as! UInt64)}
        try diag.note("paced-result",["rows":paced,"driver":fidelity,"misses":misses.count,"activeHigh":gpu.leases.highActive,"pendingWorkerHigh":max(0,high-1),"postDrainActive":gpu.leases.counts.active,"postDrainPending":gpu.leases.counts.pending,"deviceAllocatedAfterDrain":gpu.device.currentAllocatedSize,"elapsedSeconds":Double((paced.last!["clientCompletionNs"] as! UInt64)-t0)/1e9])
    }
}
