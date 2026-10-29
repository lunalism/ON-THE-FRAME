import AVFoundation
import Foundation
import XCTest
@testable import OnTheFrameEngine

/// Offline admission driver, NOT AVVideoCompositing callback/decode/presentation emulation.
final class IBSustainedInputs: @unchecked Sendable {
    let bottom:[Int:CVPixelBuffer],top:[Int:CVPixelBuffer],png:CGImage,image:IBImage,transfer:IBTransfer,expected:[Int:String]
    init(_ bottom:[Int:CVPixelBuffer],_ top:[Int:CVPixelBuffer],_ png:CGImage,_ image:IBImage,_ transfer:IBTransfer,_ expected:[Int:String]) {
        self.bottom=bottom;self.top=top;self.png=png;self.image=image;self.transfer=transfer;self.expected=expected
    }
}
struct IBSustainedFrame {
    let id:UInt64,phase:Int,rawHash:String,representative:Data?,spans:[[String:Any]],renderStart:UInt64,ready:UInt64
    let pts:CMTime
    let renderBegin:UInt64,renderEnd:UInt64
}

final class IBSustainedRun: @unchecked Sendable {
    let mode:String,inputs:IBSustainedInputs,root:URL,diag:IBDiagnostics
    let control=DispatchQueue(label:"img-b-perf04.arrivals",qos:.userInitiated)
    let workers=DispatchQueue(label:"img-b-perf04.workers",attributes:.concurrent)
    let done=DispatchSemaphore(value:0),renderer=IB420Compositor(),representatives:Set<Int>=[0,1,2,3,4,88,89]
    lazy var admission=IBAdmission<IBSustainedFrame>(pendingLimit:4,pendingTimeout:90,executor:{[workers] work in workers.async(execute:DispatchWorkItem(block:work))})
    let start:UInt64
    var submitted=0,terminals=0,next=0,stopped=false,signaled=false
    var counts=[Int:Int](),ids=[Int:UInt64](),rows=[[String:Any]](),errors=[String](),events=[String:[String:Any]](),rss=[[String:Any]](),samples=[Int:Data]()
    var lastSnapshot:[String:Any]=[:]
    var pacedPlan:IBPacedArrivalPlan?
    init(mode:String,inputs:IBSustainedInputs,root:URL,diag:IBDiagnostics) {
        self.mode=mode;self.inputs=inputs;self.root=root;self.diag=diag
        start=DispatchTime.now().uptimeNanoseconds+50_000_000 // explicit scheduling lead; excluded from run wall
    }
    func nominal(_ n:Int)->UInt64 { start+UInt64(n)*1_000_000_000/30 }
    func deadline(_ n:Int)->UInt64 { start+UInt64(n+1)*1_000_000_000/30 }
    func begin() {
        _ = admission // create scheduler before concurrently scheduled work
        if mode=="offline" {
            control.asyncAfter(deadline:DispatchTime(uptimeNanoseconds:start)) { [self] in for _ in 0..<6 {supplyOffline()} }
        } else if mode=="paced-perf05-strict" {
            let plan=IBPacedArrivalPlan(queue:control,start:start,strategy:"strict-absolute") {[weak self] n,_ in guard let self,self.stopped==false else{return};self.submit(n)}
            pacedPlan=plan;plan.begin()
        } else {
            for n in 0..<90 {control.asyncAfter(deadline:DispatchTime(uptimeNanoseconds:nominal(n))) { [self] in if !stopped {submit(n)} }}
        }
    }
    func supplyOffline() {guard !stopped,next<90 else{return};let n=next;next+=1;submit(n)}
    func sourceID(_ pb:CVPixelBuffer)throws->Int {
        try IBContract.validate(pb);CVPixelBufferLockBaseAddress(pb,.readOnly);defer{CVPixelBufferUnlockBaseAddress(pb,.readOnly)}
        let p=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb,0)).assumingMemoryBound(to:UInt8.self),s=CVPixelBufferGetBytesPerRowOfPlane(pb,0)
        var id=0;for bit in 0..<3 {if p[40*s+40+bit*48]>128 {id |= 1<<bit}};return id
    }
    func frame(_ n:Int,_ phase:Int,_ lease:IBLease)throws->IBSustainedFrame {
        if lease.isCancelled {throw IBContract.error("PERF04 unexpected cancellation",code:200)}
        let probe=IBPerfProbe(),begin=DispatchTime.now().uptimeNanoseconds
        let bottom=try XCTUnwrap(inputs.bottom[phase]),top=inputs.top[phase]
        probe.mark("A-cached-source-acquisition")
        for pb in [bottom]+(top.map{[$0]} ?? []) {
            guard try sourceID(pb)==phase,let t=ExperimentalCompositor.movieTime(pb),t.isNumeric,CMTimeCompare(t,CMTime(value:Int64(phase),timescale:30))==0 else {throw IBContract.error("PERF04 source ID/time",code:200)}
        }
        probe.mark("source-validation")
        var out:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,1920,1080,IBContract.format,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&out)==kCVReturnSuccess,let out else{throw IBContract.error("PERF04 output allocation",code:300)}
        let ins=IBInstruction(frame:phase,bottom:11,top:12,png:inputs.image,transfer:inputs.transfer,log:IBLog())
        probe.mark("F-allocation-and-test-instruction")
        let renderingStart=DispatchTime.now().uptimeNanoseconds
        try renderer.render(bottom:bottom,top:top,out:out,ins:ins,deadline:Date().addingTimeInterval(30))
        let renderingEnd=DispatchTime.now().uptimeNanoseconds
        probe.mark("CDE-and-pixel-writes");IBContract.tag(out)
        let raw=try QA01.active(out),hash=QA01.sha(raw)
        guard hash==inputs.expected[phase] else {try raw.write(to:root.appendingPathComponent("FIRST-RAW-MISMATCH-\(n).bin"));throw IBContract.error("PERF04 output hash frame\(n) phase\(phase)",code:200)}
        var description:CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:out,formatDescriptionOut:&description)==noErr,let description else {throw IBContract.error("PERF04 format description",code:200)}
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),presentationTimeStamp:CMTime(value:Int64(n),timescale:30),decodeTimeStamp:.invalid),sample:CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:out,formatDescription:description,sampleTiming:&timing,sampleBufferOut:&sample)==noErr,let sample else {throw IBContract.error("PERF04 output sample",code:200)}
        let pts=CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric,CMTimeCompare(pts,CMTime(value:Int64(n),timescale:30))==0,!lease.isCancelled else{throw IBContract.error("PERF04 output PTS/cancellation",code:200)}
        probe.mark("tag-hash-and-test-sample-wrapper")
        return IBSustainedFrame(id:lease.id,phase:phase,rawHash:hash,representative:representatives.contains(n) ? raw:nil,spans:probe.rows,renderStart:begin,ready:DispatchTime.now().uptimeNanoseconds,pts:pts,renderBegin:renderingStart,renderEnd:renderingEnd)
    }
    func submit(_ n:Int) {
        guard !stopped else{return}
        let arrival=DispatchTime.now().uptimeNanoseconds,phase=n%4+1;submitted+=1
        let id=admission.submit(tag:"position\(n)-phase\(phase)",work:{[self] lease in
            do{return .success(try frame(n,phase,lease))}catch{return .failure(error)}
        },completion:{[self] result in
            let completion=DispatchTime.now().uptimeNanoseconds,snapshot=admission.snapshot
            control.async{[self] in handle(n,phase,arrival,completion,snapshot,result)}
        })
        ids[n]=id
    }
    func handle(_ n:Int,_ phase:Int,_ arrival:UInt64,_ completion:UInt64,_ snapshot:[String:Any],_ result:IBTerminal<IBSustainedFrame>) {
        terminals+=1;counts[n,default:0]+=1;lastSnapshot=snapshot
        let published=DispatchTime.now().uptimeNanoseconds,memory=diag.rss()
        rss.append(["timeNs":published,"rssBytes":memory,"terminalCount":terminals])
        for e in snapshot["events"] as? [[String:Any]] ?? [] {if let id=e["id"] as? UInt64,let event=e["event"] as? String {events["\(id)-\(event)"]=e}}
        var row:[String:Any]=["position":n,"phase":phase,"logicalPTS":"\(n)/30","sourcePTS":"\(phase)/30","scheduledArrivalNs":nominal(n),"arrivalNs":arrival,"completionNs":completion,"publishedNs":published,"deadlineNs":deadline(n),"schedulerID":ids[n] ?? 0]
        switch result {
        case .success(let frame):
            row["terminal"]="success";row["rawSHA256"]=frame.rawHash;row["workerEntryNs"]=frame.renderStart;row["readyNs"]=frame.ready;row["spans"]=frame.spans;row["samplePTS"]="\(frame.pts.value)/\(frame.pts.timescale)"
            row["renderingStartNs"]=frame.renderBegin;row["renderingCompleteNs"]=frame.renderEnd
            if let data=frame.representative {samples[n]=data}
            if frame.id != ids[n] || frame.phase != phase {errors.append("stale logical request/result \(n)")}
        case .failure(let e):row["terminal"]="failure";row["error"]=String(describing:e);errors.append("frame\(n): \(e)")
        case .cancelled:row["terminal"]="cancelled";errors.append("unexpected cancelled frame\(n)")
        }
        rows.append(row)
        if counts[n] != 1 {errors.append("duplicate terminal \(n)")}
        if (snapshot["overflowCount"] as? Int ?? 0)>0 {errors.append("pending overflow")}
        if memory>1_073_741_824 {errors.append("RSS resource limit")}
        if !errors.isEmpty && !stopped {stopped=true;admission.cancelAll()}
        if mode=="offline" && !stopped {supplyOffline()}
        if (terminals==90 || (stopped && terminals==submitted)) && !signaled {signaled=true;done.signal()}
    }
    func wait()->Bool {done.wait(timeout:.now()+30) == .success}
    func report()->[String:Any] {
        control.sync {
            let final=DispatchTime.now().uptimeNanoseconds
            return ["mode":mode,"plannedPositions":90,"nominalIntervalSeconds":3,"startNs":start,"collectedAtNs":final,"submitted":submitted,"terminals":terminals,"rows":rows.sorted{($0["position"] as? Int ?? 0)<($1["position"] as? Int ?? 0)},"completionCounts":counts.map{["position":$0.key,"count":$0.value]},"schedulerEvents":events.values.sorted{($0["monotonicNs"] as? UInt64 ?? 0)<($1["monotonicNs"] as? UInt64 ?? 0)},"lastScheduler":lastSnapshot,"rss":rss,"errors":errors,"stopTriggered":stopped,
                "deadlineContract":"fixed before run: output n/30, nominal arrival t0+n/30, publication deadline t0+(n+1)/30; completion callback and serial diagnostic publication separately recorded; offline deadlines informational only",
                "driver":"offline IBAdmission<frame> using unchanged policy and unchanged compositor.render; repeated cached original decoded frames1...4/static PNG; NOT real AVVideoCompositing callbacks or sustained source decoding", "arrivalClock":mode=="paced-perf05-strict" ? "strict absolute one-shot/zero requested leeway":"original asyncAfter or offline producer" ]
        }
    }
}
