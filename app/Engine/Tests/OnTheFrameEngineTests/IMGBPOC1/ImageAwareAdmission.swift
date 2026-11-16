import Foundation

enum IBTerminal<Value> { case success(Value), failure(Error), cancelled }

struct IBLease {
    let id: UInt64
    private let check: () -> Bool
    init(id: UInt64,check: @escaping () -> Bool) { self.id = id;self.check = check }
    var isCancelled: Bool { check() }
}

/// Bounded ownership: two active jobs + a finite FIFO. No semaphore/queue.sync in submit/cancel.
/// Completion is linearized by a terminal claim under the state lock; external callbacks run unlocked.
/// Cancellation before that claim wins. A success already committed before cancellation remains success.
final class IBAdmission<Value>: @unchecked Sendable {
    typealias Work = (IBLease) -> IBTerminal<Value>
    typealias Completion = (IBTerminal<Value>) -> Void
    typealias Executor = (@escaping () -> Void) -> Void
    private final class Entry {
        let id: UInt64,generation: UInt64,tag: String
        var work: Work?,completion: Completion?,started = false,timer: DispatchWorkItem?
        init(id: UInt64,generation: UInt64,tag: String,work: @escaping Work,completion: @escaping Completion) {
            self.id = id;self.generation = generation;self.tag = tag;self.work = work;self.completion = completion
        }
    }
    private let lock = NSLock(),executor: Executor
    private let timerQueue = DispatchQueue(label:"dev.ontheframe.img-b.pending-deadline")
    let pendingLimit: Int,pendingTimeout: TimeInterval
    private var generation: UInt64 = 0,nextID: UInt64 = 0
    private var active: [UInt64:Entry] = [:],pending: [Entry] = []
    private var events: [[String:Any]] = []
    private var maxActive = 0,maxPending = 0,terminalCount = 0,overflowCount = 0
    init(pendingLimit: Int = 4,pendingTimeout: TimeInterval = 90,executor: @escaping Executor) {
        self.pendingLimit = max(0,pendingLimit);self.pendingTimeout = pendingTimeout;self.executor = executor
    }
    private func record(_ event: String,_ e: Entry) {
        var row: [String:Any] = ["event":event,"id":e.id,"tag":e.tag,"generation":e.generation,"active":active.count,"pending":pending.count]
        if IBPerfProbe.enabled { row["monotonicNs"] = DispatchTime.now().uptimeNanoseconds }
        events.append(row)
        if events.count>256 { events.removeFirst(events.count-256) }
        maxActive = max(maxActive,active.count);maxPending = max(maxPending,pending.count)
    }
    var snapshot: [String:Any] {
        lock.lock();defer { lock.unlock() }
        return ["active":active.count,"pending":pending.count,"maxActive":maxActive,"maxPending":maxPending,
                "pendingCap":pendingLimit,"terminalCount":terminalCount,"overflowCount":overflowCount,"events":events]
    }
    @discardableResult func submit(tag: String,work: @escaping Work,completion: @escaping Completion) -> UInt64 {
        lock.lock();nextID += 1
        let e = Entry(id:nextID,generation:generation,tag:tag,work:work,completion:completion)
        if active.count<2 {
            active[e.id] = e;record("active",e);lock.unlock();launch(e.id);return e.id
        }
        if pending.count<pendingLimit {
            let requestID = e.id
            let timer = DispatchWorkItem { [weak self] in self?.expirePending(requestID) }
            // Timer captures only id/weak scheduler, not request payload.
            e.timer = timer;pending.append(e);record("pending",e)
            let id = e.id;lock.unlock()
            timerQueue.asyncAfter(deadline:.now()+pendingTimeout,execute:timer)
            return id
        }
        overflowCount += 1;terminalCount += 1;record("overflow-failure",e);lock.unlock()
        e.work = nil;e.completion = nil
        completion(.failure(IBContract.error("bounded pending capacity exceeded",code:300)))
        return e.id
    }
    private func launch(_ id: UInt64) { executor { [weak self] in self?.run(id) } }
    private func cancelled(_ id: UInt64) -> Bool {
        lock.lock();defer { lock.unlock() }
        guard let e = active[id] else { return true };return e.generation != generation
    }
    private func run(_ id: UInt64) {
        lock.lock()
        guard let e = active[id],!e.started,let work = e.work else { lock.unlock();return }
        e.started = true;record("render-start",e)
        let cancel = e.generation != generation;lock.unlock()
        let lease = IBLease(id:id,check:{ [weak self] in self?.cancelled(id) ?? true })
        let result: IBTerminal<Value> = cancel ? .cancelled : work(lease)
        finish(id,result)
    }
    private func finish(_ id: UInt64,_ result: IBTerminal<Value>) {
        lock.lock()
        guard let e = active.removeValue(forKey:id),let completion = e.completion else { lock.unlock();return }
        let terminal: IBTerminal<Value> = e.generation == generation ? result : .cancelled
        terminalCount += 1
        switch terminal { case .success:record("success",e);case .failure:record("failure",e);case .cancelled:record("cancelled",e) }
        var starts: [UInt64] = []
        while active.count<2 && !pending.isEmpty {
            let next = pending.removeFirst();next.timer?.cancel();next.timer = nil
            active[next.id] = next;record("promoted",next);starts.append(next.id)
        }
        lock.unlock()
        e.work = nil;e.completion = nil
        completion(terminal)
        for id in starts { launch(id) }
    }
    func cancelAll() {
        lock.lock();generation += 1
        let cancelled = pending;pending.removeAll()
        for e in cancelled { e.timer?.cancel();e.timer = nil;terminalCount += 1;record("pending-cancelled",e) }
        for e in active.values { record("active-cancel-requested",e) }
        lock.unlock()
        for e in cancelled { let completion = e.completion;e.work = nil;e.completion = nil;completion?(.cancelled) }
        // Active slots remain occupied until workers acknowledge their cancellation.
    }
    /// Exposed to deterministic tests as an explicit deadline event; production timer invokes the same transition.
    func expirePending(_ id: UInt64) {
        lock.lock()
        guard let index = pending.firstIndex(where:{$0.id==id}) else { lock.unlock();return }
        let e = pending.remove(at:index);e.timer?.cancel();e.timer = nil;terminalCount += 1;record("pending-expired",e);lock.unlock()
        let completion = e.completion;e.work = nil;e.completion = nil
        completion?(.failure(IBContract.error("pending request deadline exceeded",code:300)))
    }
}
