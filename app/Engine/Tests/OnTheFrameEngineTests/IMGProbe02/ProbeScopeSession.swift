import Foundation
#if !SCOPE_HARNESS
@testable import OnTheFrameEngine
#endif

enum ProbeScopeFailure:Error {case denied,stale}
/// Caller-side diagnostic adapter. Probe itself never owns sandbox scope.
actor ProbeScopeSession {
    private var generation=0,published=0
    func replace(){generation+=1}
    func count()->Int{published}
    func run(_ url:URL,begin:@Sendable()throws->Bool,end:@Sendable()->Void,beforeDecode:@Sendable()async throws->Void = {})async throws->StillImageProbe.Validation {
        let epoch=generation
        guard try begin() else{throw ProbeScopeFailure.denied}
        defer{end()}
        let metadata=try StillImageProbe.inspect(url)
        let result=try await StillImageProbe.validator.validate(metadata,beforeDecode:beforeDecode)
        try Task.checkCancellation()
        guard generation==epoch else{throw ProbeScopeFailure.stale}
        published+=1;return result
    }
}
/// A deterministic async handoff: enter -> observe -> resume, without sleeping.
actor ProbeScopeGate {
    private var entered=false,opened=false
    private var entryWaiter:CheckedContinuation<Void,Never>?,resumeWaiter:CheckedContinuation<Void,Never>?
    func pause()async{entered=true;entryWaiter?.resume();entryWaiter=nil;if !opened{await withCheckedContinuation{resumeWaiter=$0}}}
    func waitForEntry()async{if !entered{await withCheckedContinuation{entryWaiter=$0}}}
    func open(){opened=true;resumeWaiter?.resume();resumeWaiter=nil}
}
final class ProbeScopeCounts:@unchecked Sendable {
    private let lock=NSLock()
    private var starts=0,ends=0,active=0,high=0
    func acquired(){lock.lock();starts+=1;active+=1;high=max(high,active);lock.unlock()}
    func released(){lock.lock();ends+=1;active-=1;lock.unlock()}
    var snapshot:[String:Int]{lock.lock();defer{lock.unlock()};return["starts":starts,"ends":ends,"active":active,"high":high]}
}
