#if DEBUG
import AppKit
import AVFoundation
import ImageIO
import OnTheFrameEngine

/// Normal signed-app entry/transaction smoke, generated sources and explicit suite only.
/// No Open/Save panel automation. Not part of public feature availability.
@MainActor
enum ImageExportSelfTest {
    static func run(folder: URL) async {
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
