#if DEBUG
import AppKit
import AVFoundation
import ImageIO
import CryptoKit
@testable import OnTheFrameEngine

/// Normal signed-app entry/transaction smoke, generated sources and explicit suite only.
/// No Open/Save panel automation. Not part of public feature availability.
@MainActor
enum ImageExportSelfTest {
    static func run(folder: URL) async {
        if ProcessInfo.processInfo.arguments.contains("-OTFImageExportSafety") { await runSafety(folder:folder); return }
        var rows = [String:Bool]()
        let store = ProjectStore.shared
        do {
            guard EditorLayout.shared.suiteName != nil else { throw CocoaError(.fileReadNoPermission) }
            let root = folder.appendingPathComponent("image-export-" + UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let image = root.appendingPathComponent("generated.png")
            guard let space = CGColorSpace(name:CGColorSpace.sRGB),
                  let context = CGContext(data:nil,width:64,height:36,bitsPerComponent:8,bytesPerRow:256,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
                  let destination = CGImageDestinationCreateWithURL(image as CFURL,"public.png" as CFString,1,nil) else { throw CocoaError(.fileWriteUnknown) }
            context.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:64,height:36))
            CGImageDestinationAddImage(destination,context.makeImage()!,nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            let old = store.timeline
            let imported = await store.importStillImage(at:image)
            if !ProjectStore.imageImportEnabled {
                rows["runtime-off mutation rejected"] = !imported && store.timeline == old
                let forbidden = root.appendingPathComponent("must-not-exist.mp4")
                let outcome = await ExportService.exportImages(old,media:[:],enabled:ProjectStore.imageImportEnabled,to:.fromSavePanel(forbidden)){_ in}
                if case .failed = outcome { rows["runtime-off engine export rejected"] = !FileManager.default.fileExists(atPath:forbidden.path) }
                else { rows["runtime-off engine export rejected"] = false }
            } else {
                rows["normal import"] = imported && store.timeline.clips.first?.length == 150
                rows["export eligibility"] = store.canExport && store.exportBlockReason == nil
                let snapshot = store.timeline, output = root.appendingPathComponent("normal-app.mp4")
                store.startExport(.fromSavePanel(output))
                let until = Date().addingTimeInterval(30)
                while store.exportPhase != .idle && Date() < until { try await Task.sleep(nanoseconds:20_000_000) }
                rows["transaction complete"] = store.exportPhase == .idle && FileManager.default.fileExists(atPath:output.path)
                rows["project unchanged"] = store.timeline == snapshot
                rows["progress completed once"] = store.exportProgressLog.filter{$0 == 1}.count == 1
                let media = try await MediaProbe.inspect(output)
                rows["actual MP4 profile"] = media.frameCount == 150 && media.codec == "avc1" && !media.hasAudio && media.displaySize == CGSize(width:1920,height:1080)
                store.stopAllScopes()
                rows["session scopes retired"] = store.scopedURLs.isEmpty
            }
            let result:[String:Any] = ["gate":ProjectStore.imageImportEnabled,"checks":rows,"pass":!rows.isEmpty && rows.values.allSatisfy{$0},"nativePanelTested":false,"outputRoot":root.lastPathComponent]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("image-export-result.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject:["pass":false,"checks":rows,"error":String(describing:error)],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("image-export-result.json"))
        }
        // Only this explicitly launched disposable test app exits, not owner instances.
        // AppKit refuses terminate while our export-completion sheet is attached.
        // Close only that test-owned completion sheet; never accept a native panel.
        let completionShown = store.alerts.currentSheet != nil && store.alert?.title == "내보내기 완료"
        if completionShown { store.alerts.pressButton(1) }
        let until = Date().addingTimeInterval(3)
        while (store.alerts.isShowing || store.editorWindow?.attachedSheet != nil), Date() < until {
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        let ready = !store.alerts.isShowing && store.editorWindow?.attachedSheet == nil
        try? JSONSerialization.data(withJSONObject:["completionSheetObserved":completionShown,"readyToTerminate":ready],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("image-export-retirement.json"))
        guard ready else { return }
        store.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif

#if DEBUG
extension ImageExportSelfTest {
    /// Explicit disposable signed-app validation; uses existing production fault hooks only.
    final class SafetyObservation: @unchecked Sendable {
        let lock = NSLock()
        var temporary: URL?
        var promotionReached = false
        var faultError: String?
    }
    static func runSafety(folder: URL) async {
        let store = ProjectStore.shared
        var cases = [[String:Any]]()
        func hash(_ u:URL) throws -> String { SHA256.hash(data:try Data(contentsOf:u)).map{String(format:"%02x",$0)}.joined() }
        func dismiss() async {
            if store.alerts.currentSheet != nil { store.alerts.pressButton(1) }
            else if store.alerts.current != nil { store.alerts.pressButton(0) }
            let end = Date().addingTimeInterval(3)
            while store.alerts.isShowing && Date()<end { try? await Task.sleep(nanoseconds:10_000_000) }
        }
        do {
            guard EditorLayout.shared.suiteName != nil, ProjectStore.imageImportEnabled else { throw CocoaError(.fileReadNoPermission) }
            let root = folder.appendingPathComponent("safety-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
            // Caller supplies only a copied generated PNG and a copied generated valid MP4.
            var image = folder.appendingPathComponent("generated.png")
            let sentinel = folder.appendingPathComponent("sentinel.mp4")
            let scopedProject = folder.appendingPathComponent("scoped-project.ontheframe")
            if FileManager.default.fileExists(atPath:scopedProject.path) {
                guard await store.openProject(at:scopedProject), store.missingMedia.isEmpty,
                      let record=store.timeline.mediaCatalog.first?.still?.reference else { throw CocoaError(.fileReadCorruptFile) }
                image=URL(fileURLWithPath:record.path)
            } else {
                guard await store.importStillImage(at:image) else { throw CocoaError(.fileReadCorruptFile) }
            }
            let sourceHash = try hash(image), sentinelHash = try hash(sentinel)
            let original = store.timeline, project = store.projectID, scopeCount = store.scopedURLs.count
            for mode in ["encoding-cancel","writing-failure","writer-init-failure","precommit-cancel","publication-failure","replacement-success"] {
                let dir=root.appendingPathComponent(mode)
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
                let dest=dir.appendingPathComponent("existing.mp4")
                try FileManager.default.copyItem(at:sentinel,to:dest)
                let before=try hash(dest), obs=SafetyObservation()
                var options=ExportService.Options()
                options.onTempDirectory={ u in
                    obs.lock.withLock { obs.temporary=u }
                    if mode == "writer-init-failure" {
                        do { try FileManager.default.createDirectory(at:u.appendingPathComponent("output.mp4"),withIntermediateDirectories:false) }
                        catch { obs.lock.withLock { obs.faultError=String(describing:error) } }
                    }
                }
                if mode == "writing-failure" { options.failAfterFraction=0.1 }
                options.beforePromotion={
                    obs.lock.withLock { obs.promotionReached=true }
                    if mode == "precommit-cancel" { withUnsafeCurrentTask { $0?.cancel() } }
                    if mode == "publication-failure", let temp=obs.lock.withLock({obs.temporary}) {
                        do { try FileManager.default.moveItem(at:temp.appendingPathComponent("output.mp4"),to:dir.appendingPathComponent("retained-unpublished.mp4")) }
                        catch { obs.lock.withLock { obs.faultError=String(describing:error) } }
                    }
                }
                store.exportOptions=options
                store.statusMessage=nil
                store.startExport(.fromSavePanel(dest))
                let started=Date(), deadline=started.addingTimeInterval(30)
                var cancelAt:Double?, cancellingObserved=false, replacementBlocked=false, ticks=0
                while store.exportPhase != .idle && Date()<deadline {
                    if mode == "encoding-cancel", cancelAt == nil,
                       let p=store.exportProgressLog.last, p>0.1, p<0.99 {
                        cancelAt=p;store.cancelExport();cancellingObserved=store.exportCancelling
                        store.requestNewProject()
                        replacementBlocked=store.projectID == project && store.timeline == original && store.alert?.title == "프로젝트를 바꿀 수 없습니다"
                    }
                    ticks += 1
                    try await Task.sleep(nanoseconds:5_000_000)
                }
                guard store.exportPhase == .idle else { store.cancelExport(); throw CocoaError(.userCancelled) }
                let drainDeadline=Date().addingTimeInterval(5)
                while (ImagePreviewCompositor.admission.outstanding != 0 || ImagePreviewMetal.ownership.counts.active != 0), Date()<drainDeadline {
                    try await Task.sleep(nanoseconds:5_000_000)
                }
                let gpu=ImagePreviewMetal.ownership.counts, outstanding=ImagePreviewCompositor.admission.outstanding
                let progress=store.exportProgressLog, after=try hash(dest)
                let success=mode == "replacement-success", cancelled=mode.hasSuffix("cancel")
                let alertTitle=store.alert?.title ?? "", status=store.statusMessage ?? ""
                let temp=obs.lock.withLock{obs.temporary}
                var checks:[String:Bool]=[
                    "destination":success ? after != before : after == before,
                    "baseline":before == sentinelHash,
                    "source":try hash(image) == sourceHash,
                    "project":store.timeline == original && store.projectID == project,
                    "sessionScopesRetained":store.scopedURLs.count == scopeCount,
                    "observedGPUDrain":outstanding == 0 && gpu.active == 0 && gpu.resources == 0,
                    "progressMonotonic":zip(progress,progress.dropFirst()).allSatisfy{$0 <= $1},
                    "progressFinite":progress.allSatisfy{$0.isFinite && $0>=0 && $0<=1},
                    "completion":success ? progress.filter{$0==1}.count == 1 : !progress.contains(1),
                    "tempRetired":temp != nil && !FileManager.default.fileExists(atPath:temp!.path),
                    "faultExecuted":obs.lock.withLock{obs.faultError == nil},
                    "outcome":success ? alertTitle == "내보내기 완료" : (cancelled ? status.contains("취소했습니다") : alertTitle == "내보내기 실패")]
                if mode == "encoding-cancel" { checks["actualEncodingCancellation"]=cancelAt != nil && cancellingObserved; checks["newSessionBlockedDuringExport"]=replacementBlocked }
                if mode == "writing-failure" { checks["encodingAdvanced"]=(progress.max() ?? 0)>0 }
                if mode == "precommit-cancel" || mode == "publication-failure" { checks["promotionReached"]=obs.lock.withLock{obs.promotionReached} }
                if success { let a=try await MediaProbe.inspect(dest);checks["validMP4"]=a.frameCount==150 && a.codec=="avc1" }
                let row:[String:Any] = ["mode":mode,"checks":checks,"pass":checks.values.allSatisfy{$0},"beforeSHA256":before,"afterSHA256":after,"progress":progress,"cancelAt":cancelAt as Any? ?? NSNull(),"cancellingObserved":cancellingObserved,"mainActorTicks":ticks,"seconds":Date().timeIntervalSince(started),"alert":alertTitle,"status":status,"scopeCount":store.scopedURLs.count,"gpuActive":gpu.active,"gpuResources":gpu.resources,"admissionOutstanding":outstanding,"temporary":temp?.path ?? "","promotionReached":obs.lock.withLock{obs.promotionReached}]
                cases.append(row)
                try JSONSerialization.data(withJSONObject:cases,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("safety-cases.json"))
                await dismiss()
                // Stop immediately on any destination protection or other assertion failure.
                guard checks.values.allSatisfy({$0}) else { throw CocoaError(.validationMissingMandatoryProperty) }
            }
            store.exportOptions = .init()
            var postDrainSessionStable = false
            if FileManager.default.fileExists(atPath:scopedProject.path) {
                store.requestNewProject()
                let newID=store.projectID, newTimeline=store.timeline, newStatus=store.statusMessage
                try await Task.sleep(nanoseconds:200_000_000)
                postDrainSessionStable=newID != project && store.projectID == newID && store.timeline == newTimeline && store.statusMessage == newStatus && store.exportPhase == .idle && store.alert == nil
                guard postDrainSessionStable else { throw CocoaError(.validationMissingMandatoryProperty) }
            }
            // Session scopes intentionally remain owned while the project stays open.
            // This explicit teardown is not evidence of per-export OS scope counts.
            store.stopAllScopes()
            try JSONSerialization.data(withJSONObject:["pass":true,"cases":cases.count,"sessionScopesAfterExplicitTeardown":store.scopedURLs.count,"nativePanelsTested":false,"gpuDrainMeasured":true,"initialSessionScopes":scopeCount,"postDrainSessionStable":postDrainSessionStable],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("safety-result.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject:["pass":false,"error":String(describing:error),"completedCases":cases.count],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("safety-result.json"))
        }
        await dismiss()
        guard store.exportPhase == .idle, !store.alerts.isShowing else { return }
        store.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
