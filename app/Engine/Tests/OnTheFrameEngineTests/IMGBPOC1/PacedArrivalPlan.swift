import Foundation

/// Bounded measurement producer. Uses the same monotonic clock as IBPerfClock/admission.
/// No spinning, rendering, input decoding, or repeating relative-deadline accumulation.
final class IBPacedArrivalPlan: @unchecked Sendable {
    let queue:DispatchQueue,start:UInt64,strategy:String,receive:(Int,UInt64)->Void
    private var timer:DispatchSourceTimer?,next=0,stopped=false
    init(queue:DispatchQueue,start:UInt64,strategy:String,receive:@escaping(Int,UInt64)->Void) {
        self.queue=queue;self.start=start;self.strategy=strategy;self.receive=receive
    }
    func target(_ n:Int)->UInt64 {start+UInt64(n)*1_000_000_000/30}
    func begin() {
        if strategy=="legacy-asyncAfter" {
            for n in 0..<90 {queue.asyncAfter(deadline:DispatchTime(uptimeNanoseconds:target(n))) {[self] in
                if !stopped {receive(n,DispatchTime.now().uptimeNanoseconds)}
            }}
        } else {
            queue.async {[self] in
                let source=DispatchSource.makeTimerSource(flags:.strict,queue:queue);timer=source
                source.setEventHandler {[weak self] in self?.fire()}
                source.schedule(deadline:DispatchTime(uptimeNanoseconds:target(0)),leeway:.nanoseconds(0));source.resume()
            }
        }
    }
    private func fire() {
        guard !stopped,next<90 else{return}
        let n=next;next+=1;receive(n,DispatchTime.now().uptimeNanoseconds)
        if next==90 {timer?.cancel();timer=nil}
        else {timer?.schedule(deadline:DispatchTime(uptimeNanoseconds:target(next)),leeway:.nanoseconds(0))}
    }
    func cancel() {queue.async{[self] in stopped=true;timer?.cancel();timer=nil}}
}

enum IBPacedFidelity {
    static let criteria:[String:Any] = ["p95PositiveLatenessNs":1_000_000,"maximumPositiveLatenessNs":2_000_000,
        "maximumEarlyNs":100_000,"missedOneIntervalWindows":0,"absoluteFinalJitterNs":2_000_000,"absoluteDriftFromFirstNs":2_000_000,
        "presentationDeadlineSlackNs":0,"meaning":"arrival suitability only; unchanged fixed33.333ms presentation budget"]
    static func summary(_ records:[[String:Any]]) -> [String:Any] {
        let jitters=records.compactMap{r -> Double? in guard let intended=r["intendedNs"] as? UInt64,let actual=r["actualSubmissionNs"] as? UInt64 else{return nil};return Double(Int64(actual)-Int64(intended))}
        guard jitters.count==90,Set(records.compactMap{$0["position"] as? Int}).count==90 else{return ["fidelityValidated":false,"error":"missing/duplicate/invalid calibration positions"]}
        let late=jitters.map{max(0,$0)}.sorted(),early=max(0,-(jitters.min() ?? 0)),p95=late[Int(ceil(Double(late.count)*0.95))-1],maximum=late.last ?? 0
        let final=jitters.last!,drift=final-jitters.first!,windows=late.filter{$0>=1_000_000_000/30}.count
        let valid=p95<=1_000_000 && maximum<=2_000_000 && early<=100_000 && windows==0 && abs(final)<=2_000_000 && abs(drift)<=2_000_000
        return ["n":90,"fidelityValidated":valid,"lateArrivalsAboveZero":late.filter{$0>0}.count,"medianPositiveLatenessNs":(late[44]+late[45])/2,"p95PositiveLatenessNs":p95,"maximumPositiveLatenessNs":maximum,"maximumEarlyNs":early,"missedOneIntervalWindows":windows,"finalJitterNs":final,"driftFromFirstNs":drift,"criteria":criteria]
    }
}
