import Foundation

/// Experimental ownership adapter: logical termination never retires submitted work.
final class GMLeaseBook {
    enum State:String {case created,admitted,submitted,completed,canceled,failed,timedOut}
    final class Ticket {
        let id:Int,generation:Int
        var state:State = .created
        var terminal:State?,submitted=false,retired=false
        var resources:[Any]
        let notify:(State)->Void
        init(_ id:Int,_ generation:Int,_ resources:[Any],_ notify:@escaping(State)->Void){self.id=id;self.generation=generation;self.resources=resources;self.notify=notify}
    }
    private let lock=NSLock()
    private var active:[Int:Ticket]=[:],pending:[Ticket]=[]
    private var next=0,generation=0,quarantined=false
    private(set) var highActive=0,highPending=0
    func admit(_ resources:[Any],notify:@escaping(State)->Void)->Ticket? {
        lock.lock();defer{lock.unlock()}
        guard !quarantined,active.count<2 || pending.count<4 else{return nil}
        next+=1;let t=Ticket(next,generation,resources,notify)
        if active.count<2 {t.state = .admitted;active[t.id]=t}else{pending.append(t)}
        highActive=max(highActive,active.count);highPending=max(highPending,pending.count);return t
    }
    func submit(_ t:Ticket)->Bool {
        lock.lock();defer{lock.unlock()}
        guard active[t.id] === t,t.terminal==nil,t.state == .admitted,!quarantined else{return false}
        t.submitted=true;t.state = .submitted;return true
    }
    private func retire(_ t:Ticket){
        guard !t.retired else{return};t.retired=true;t.resources=[];active[t.id]=nil;pending.removeAll{$0 === t}
        if !quarantined {while active.count<2 && !pending.isEmpty {let p=pending.removeFirst();p.state = .admitted;active[p.id]=p}}
    }
    func terminate(_ t:Ticket,_ reason:State){
        precondition(reason == .canceled || reason == .timedOut || reason == .failed)
        lock.lock();guard t.terminal==nil,!t.retired else{lock.unlock();return}
        t.terminal=reason;t.state=reason
        if !t.submitted{retire(t)}
        lock.unlock();t.notify(reason)
    }
    /// Called only by a real completion observer, or the deterministic fake driver.
    func observedCompletion(_ t:Ticket,failed:Bool=false){
        lock.lock();guard t.submitted,!t.retired else{lock.unlock();return}
        var notify:State?
        if t.terminal==nil {let s:State=failed ? .failed:(t.generation==generation ? .completed:.canceled);t.terminal=s;t.state=s;notify=s}
        retire(t);lock.unlock();if let notify{t.notify(notify)}
    }
    func replaceGeneration(){
        lock.lock();generation+=1;let all=Array(active.values)+pending;lock.unlock()
        for t in all{terminate(t,.canceled)}
    }
    /// A watchdog cannot assert completion. Quarantine stops admission, retaining running work.
    func quarantineUnobserved(){lock.lock();quarantined=true;let all=Array(active.values)+pending;lock.unlock();for t in all{terminate(t,.timedOut)}}
    var counts:(active:Int,pending:Int,submitted:Int,quarantined:Bool){lock.lock();defer{lock.unlock()};return(active.count,pending.count,active.values.filter{$0.submitted}.count,quarantined)}
}
