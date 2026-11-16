import AppKit
import Foundation
import ImageIO
@testable import OnTheFrameEngine

@main struct ImageImportAppTests {
    struct Failure: Error { let message: String }
    static func check(_ b: @autoclosure () throws -> Bool, _ s: String) throws { if try !b() { throw Failure(message:s) } }
    static func fixture(_ root:URL,_ name:String,alpha:Bool=false,width:Int=3) throws -> URL {
        let u=root.appendingPathComponent(name)
        let c=CGContext(data:nil,width:width,height:2,bitsPerComponent:8,bytesPerRow:width*4,
                        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:alpha ? CGImageAlphaInfo.premultipliedLast.rawValue:CGImageAlphaInfo.noneSkipLast.rawValue)!
        let d=CGImageDestinationCreateWithURL(u as CFURL,(name.hasSuffix("jpg") ? "public.jpeg":"public.png") as CFString,1,nil)!
        CGImageDestinationAddImage(d,c.makeImage()!,nil);try check(CGImageDestinationFinalize(d),"fixture")
        return u
    }
    @MainActor static func main() async {
        do {
            _ = NSApplication.shared
            try check(Thread.isMainThread && EditorLayout.shared.suiteName != nil,"isolated AppKit")
            let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let jpg=try fixture(root,"good.jpg"),png=try fixture(root,"opaque.png"),alpha=try fixture(root,"alpha.png",alpha:true)
            let store=ProjectStore()
            if !CommandLine.arguments.contains("-OTFEnableImageImport") {
                try check(!ProjectStore.imageImportEnabled,"default gate")
                let old=store.timeline;let ok=await store.importStillImage(at:jpg)
                try check(!ok && store.timeline==old && !store.imageImportBusy,"mutation gate")
                print("GATE DISABLED: 1 PASS, 0 FAIL, 0 SKIP");exit(0)
            }
            try check(ProjectStore.imageImportEnabled,"explicit gate")
            var starts=0,stops=0
            store.persistenceScopeStartForTest={_ in starts += 1;return true}
            store.persistenceScopeStopForTest={_ in stops += 1}
            store.imageImportBookmarkForTest={try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)}
            let original=try Data(contentsOf:jpg)
            for (i,u) in [jpg,png,alpha].enumerated() {
                let ok=await store.importStillImage(at:u,atFrame:i*150)
                try check(ok,"JPEG/opaque/alpha import")
            }
            let t=store.timeline,refs=ProjectPersistence.references(t)
            try check(refs.count==3 && refs.allSatisfy{$0.kind == .stillImage && $0.temporal == nil},"image sum type")
            try check(t.mediaFrames.isEmpty && t.audioClips.isEmpty && t.clips.allSatisfy{$0.length==150 && $0.sourceIn==0},"image timing")
            try check(Set(t.clips.map(\.id)).count==3 && Set(refs.map(\.id)).count==3 && starts-stops==3,"IDs and scope transfer")
            try check(store.currentPlan == nil && store.player.currentItem == nil && store.exportBlockReason != nil,"safe preview/export")
            try check(TimelineDrawState(store:store).names[refs[0].id] != nil,"image clip name in actual timeline UI")
            print("PASS 1 JPEG/opaque/alpha actual app insertion and render fence")

            let old=store.timeline;let conflict=await store.importStillImage(at:jpg,atFrame:0)
            try check(!conflict && store.timeline==old && starts-stops==3,"atomic overlap failure")
            let repeatOK=await store.importStillImage(at:jpg,atFrame:450)
            try check(repeatOK && Set(ProjectPersistence.references(store.timeline).map(\.id)).count==4,"repeated import IDs")
            print("PASS 2 overlap transaction and repeated import")

            store.undo();try check(store.timeline==old,"undo complete media+clip transaction")
            let save=root.appendingPathComponent("undo.ontheframe")
            try check(store.writeProject(to:save),"save after undo without orphan sidecars")
            store.redo();try check(store.timeline.clips.count==4,"redo")
            try check(store.writeProject(to:root.appendingPathComponent("image.ontheframe")),"format9 save")
            let loaded=try ProjectPersistence.decode(Data(contentsOf:root.appendingPathComponent("image.ontheframe")))
            try check(loaded.version==9 && loaded.timeline.clips==store.timeline.clips && loaded.media.allSatisfy{$0.bookmark != nil},"format9 readiness")
            let cid=store.timeline.clips[0].id
            store.commit({try $0.splitting(clip:cid,atFrame:30)},focus:nil)
            try check(store.timeline.clips.count==5 && store.timeline.clips.allSatisfy{$0.sourceIn==0},"ordinary image editing")
            store.undo();try check(store.timeline.clips.count==4,"edit undo")
            store.commit({try $0.trimming(clip:cid,sourceIn:0,length:1)},focus:cid)
            try check(store.timeline.clip(cid)?.length==1,"minimum trim")
            store.undo()
            store.commit({try $0.relocating(clip:cid,toStart:600)},focus:cid)
            try check(store.timeline.clip(cid)?.start==600,"ordinary move")
            store.undo()
            store.selection=cid;store.copySelection();store.seek(to:600);store.pasteAtPlayhead()
            try check(store.timeline.clips.count==5 && Set(store.timeline.clips.map(\.id)).count==5,"copy/paste unique clips")
            store.undo()
            store.commit({try $0.rippleDeleting(clip:cid)},focus:nil)
            try check(store.timeline.clips.count==3 && store.timeline.clips[0].start==0,"ripple image delete")
            store.undo()
            print("PASS 3 undo/redo, split/trim/move/copy/ripple, save after undo and format9")

            let invalid=root.appendingPathComponent("bad.png");try Data([137,80,78,71,13,10,26,10]).write(to:invalid)
            let huge=try fixture(root,"dimension.png",width:2049)
            let large=root.appendingPathComponent("limit.png");FileManager.default.createFile(atPath:large.path,contents:Data());let file=try FileHandle(forWritingTo:large);try file.truncate(atOffset:8*1024*1024+1);try file.close()
            let stable=store.timeline,active=starts-stops
            for u in [invalid,huge,large] { let ok=await store.importStillImage(at:u);try check(!ok && store.timeline==stable && starts-stops==active,"invalid/limits rollback") }
            store.imageImportBookmarkForTest={_ in throw Failure(message:"authorization failed")}
            let unauthorized=await store.importStillImage(at:jpg,atFrame:600);try check(!unauthorized && store.timeline==stable && starts-stops==active,"bookmark failure rollback")
            store.imageImportBookmarkForTest={try $0.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)}
            print("PASS 4 corruption, limits and authorization failure")

            store.imageImportBeforeProbeForTest={store.cancelImageImport()}
            let beforeCancel=await store.importStillImage(at:jpg);try check(!beforeCancel && store.timeline==stable && starts-stops==active,"cancel before probe")
            store.imageImportBeforeProbeForTest=nil
            store.imageImportDidValidateForTest={
                try check(starts-stops==active+1,"scope held during async transaction")
                let concurrent=await store.importStillImage(at:png);try check(!concurrent,"one import at a time")
                store.cancelImageImport()
            }
            let cancelled=await store.importStillImage(at:jpg);try check(!cancelled && store.timeline==stable && starts-stops==active,"cancel pending validated result")
            store.imageImportDidValidateForTest=nil
            try check(!store.imageImportBusy && store.statusMessage?.contains("취소했습니다") == true,"completed cancellation status")
            let task=Task { @MainActor in withUnsafeCurrentTask{$0?.cancel()};return await store.importStillImage(at:jpg) }
            let preCancelled=await task.value;try check(!preCancelled && store.timeline==stable,"pre-cancelled task")
            print("PASS 5 cancellation, access lifetime and concurrency")

            store.imageImportDidValidateForTest={store.resetProject()}
            let stale=await store.importStillImage(at:jpg);try check(!stale && store.timeline.isEmpty && ProjectPersistence.references(store.timeline).isEmpty && starts==stops,"project replacement drains old and pending leases")
            store.imageImportDidValidateForTest=nil
            try check(try Data(contentsOf:jpg)==original,"source unchanged")
            print("PASS 6 stale session and source preservation; active scopes zero (injected)")
            let legacy=URL(fileURLWithPath:ProcessInfo.processInfo.environment["OTF_IMPORT_LEGACY_FIXTURES"]!)
            store.importFiles([legacy.appendingPathComponent("otf-A.mp4"),legacy.appendingPathComponent("aud-wav48s.wav")])
            for _ in 0..<500 {
                if store.importProgress == nil { break }
                try await Task.sleep(nanoseconds:20_000_000)
            }
            try check(store.assets.count==2 && store.timeline.media.count==2 && store.timeline.mediaFrames.count==2,"unchanged video/audio import")
            try check(store.timeline.media.contains{$0.hasVideo} && store.timeline.media.contains{!$0.hasVideo && $0.hasAudio},"temporal semantics")
            print("PASS 7 existing video/audio import with disposable copies; no export")
            print("IMAGE IMPORT: 7 PASS, 0 FAIL, 0 SKIP");exit(0)
        } catch {print("IMAGE IMPORT FAIL: \(error)");exit(1)}
    }
}
