import AppKit
import UniformTypeIdentifiers

@MainActor final class ScopeHarnessDelegate:NSObject,NSApplicationDelegate {
    func log(_ name:String,_ values:[String:Any]=[:]) {let d=try! JSONSerialization.data(withJSONObject:["case":name,"values":values],options:.sortedKeys);print(String(data:d,encoding:.utf8)!);fflush(stdout)}
    func panel(_ expected:URL,title:String)->URL? {
        let p=NSOpenPanel();p.title=title;p.allowedContentTypes=[.png,.jpeg];p.allowsMultipleSelection=false;p.directoryURL=expected.deletingLastPathComponent()
        guard p.runModal() == .OK else{log("panel-canceled");return nil}
        guard let u=p.url,u.standardizedFileURL.path==expected.standardizedFileURL.path else{log("unexpected-selection-rejected-without-reading");return nil};return u
    }
    func applicationDidFinishLaunching(_ notification:Notification){
        NSApp.activate(ignoringOtherApps:true)
        Task {await run();NSApp.terminate(nil)}
    }
    func run()async {
        guard CommandLine.arguments.count==2 else{log("missing-generated-fixture-path");return}
        let expected=URL(fileURLWithPath:CommandLine.arguments[1])
        log("preselection-read",["readable":(try? Data(contentsOf:expected)) != nil,"contract":"must select only generated fixtures"])
        guard let u=panel(expected,title:"IMG-PROBE-02: Select generated good.png") else{return}
        let s=ProbeScopeSession(),c=ProbeScopeCounts()
        let begin:@Sendable()->Bool={let ok=u.startAccessingSecurityScopedResource();if ok{c.acquired()};return ok}
        let end:@Sendable()->Void={u.stopAccessingSecurityScopedResource();c.released()}
        do {
            for _ in 0..<3 {_ = try await s.run(u,begin:begin,end:end)}
            log("actual-success-repeat",c.snapshot)
            let gate=ProbeScopeGate(),cancel=Task{try await s.run(u,begin:begin,end:end,beforeDecode:{await gate.pause()})}
            await gate.waitForEntry();cancel.cancel();log("actual-cancel-still-owned",c.snapshot);await gate.open()
            do{_ = try await cancel.value;log("FAIL-cancel-published");return}catch is CancellationError{}
            log("actual-cancel-drained",c.snapshot)
            let replacement=ProbeScopeGate(),stale=Task{try await s.run(u,begin:begin,end:end,beforeDecode:{await replacement.pause()})}
            await replacement.waitForEntry();await s.replace();log("actual-replaced-still-owned",c.snapshot);await replacement.open()
            do{_ = try await stale.value;log("FAIL-stale-published");return}catch ProbeScopeFailure.stale{}
            log("actual-replaced-drained",c.snapshot)
            guard c.snapshot["starts"]==5,c.snapshot["ends"]==5,c.snapshot["active"]==0 else{log("FAIL-ownership-counts");return}
            for (filename,shouldSucceed) in [("good.jpg",true),("decode-invalid.png",false)] {
                let expectedCase=expected.deletingLastPathComponent().appendingPathComponent(filename)
                guard let selected=panel(expectedCase,title:"IMG-PROBE-04: Select generated \(filename)") else{return}
                let counts=ProbeScopeCounts()
                do {
                    _ = try await s.run(selected,begin:{let ok=selected.startAccessingSecurityScopedResource();if ok{counts.acquired()};return ok},end:{selected.stopAccessingSecurityScopedResource();counts.released()})
                    guard shouldSucceed else{log("FAIL-corrupt-accepted");return}
                    log("actual-JPEG-success",counts.snapshot)
                }catch StillImageProbeError.malformed {
                    guard !shouldSucceed else{log("FAIL-valid-JPEG-rejected");return}
                    log("actual-corrupt-required-data-rejected",counts.snapshot)
                }catch{log("FAIL-unexpected-case-error",["error":String(describing:error)]);return}
                guard counts.snapshot["starts"]==1,counts.snapshot["ends"]==1,counts.snapshot["active"]==0 else{log("FAIL-extra-case-scope");return}
            }
            let invalid=expected.deletingLastPathComponent().appendingPathComponent("invalid.png")
            guard let bad=panel(invalid,title:"IMG-PROBE-02: Select generated invalid.png") else{return}
            let invalidCounts=ProbeScopeCounts()
            do{_ = try await s.run(bad,begin:{let ok=bad.startAccessingSecurityScopedResource();if ok{invalidCounts.acquired()};return ok},end:{bad.stopAccessingSecurityScopedResource();invalidCounts.released()});log("FAIL-invalid-accepted");return}catch{log("actual-invalid-rejected",["error":String(describing:error),"counts":invalidCounts.snapshot])}
            guard invalidCounts.snapshot["starts"]==1,invalidCounts.snapshot["ends"]==1,invalidCounts.snapshot["active"]==0 else{log("FAIL-invalid-ownership");return}
            let p=NSOpenPanel();p.title="IMG-PROBE-02: Cancel this panel";p.allowedContentTypes=[.png];p.directoryURL=expected.deletingLastPathComponent()
            guard p.runModal() == .cancel else{log("cancel-panel-not-canceled");return}
            log("ACTUAL-SANDBOX-LIFECYCLE-PASS",["scopeCounts":c.snapshot,"invalidCounts":invalidCounts.snapshot,"selectionCancelStarts":0,"published":await s.count(),"ownerManual":"not performed; diagnostic automation only"])
        }catch{log("ACTUAL-SANDBOX-PARTIAL",["error":String(describing:error),"scopeCounts":c.snapshot])}
    }
}
@main struct ScopeHarnessMain {
    @MainActor static func main(){let app=NSApplication.shared,delegate=ScopeHarnessDelegate();app.setActivationPolicy(.regular);app.delegate=delegate;withExtendedLifetime(delegate){app.run()}}
}
