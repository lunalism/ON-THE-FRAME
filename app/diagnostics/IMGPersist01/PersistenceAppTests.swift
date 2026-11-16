import AppKit
import ImageIO
@testable import OnTheFrameEngine

@main struct PersistenceAppTests {
    struct TestFailure: Error { let message: String }
    @MainActor static func main() async {
        do {
            guard Thread.isMainThread else { throw TestFailure(message:"not main thread") }
            _ = NSApplication.shared
            try check(EditorLayout.shared.suiteName != nil,"preferences must be isolated")
            try await run(URL(fileURLWithPath:CommandLine.arguments[1]))
            print("APP PERSISTENCE: 10 PASS, 0 FAIL, 0 SKIP");exit(0)
        } catch { print("APP PERSISTENCE FAIL: \(error)");exit(1) }
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false { throw TestFailure(message:message) }
    }
    static func image(_ root: URL, jpeg: Bool = false) async throws -> StillImageProjectModel.ValidatedImage {
        let dir=root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let url=dir.appendingPathComponent(jpeg ? "image.jpg":"image.png")
        let context=CGContext(data:nil,width:2,height:3,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest=CGImageDestinationCreateWithURL(url as CFURL,(jpeg ? "public.jpeg":"public.png") as CFString,1,nil)!
        CGImageDestinationAddImage(dest,context.makeImage()!,nil)
        try check(CGImageDestinationFinalize(dest),"generated fixture")
        return try await StillImageProjectModel.ValidatedImage.inspect(url)
    }
    @MainActor static func run(_ root: URL) async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=try await image(root), second=try await image(root,jpeg:true), imageID=UUID(), unusedID=UUID()
        let video=MediaRef(id:UUID(),name:"missing video",path:root.appendingPathComponent("missing.mov").path,frameCount:300,hasAudio:true,size:100,modifiedNs:1,codec:"h264",width:1920,height:1080)
        let audio=MediaRef(id:UUID(),name:"missing audio",path:root.appendingPathComponent("missing.wav").path,frameCount:300,hasAudio:true,size:100,modifiedNs:1,codec:"pcm",width:0,height:0,hasVideo:false,sampleRate:48000,sampleCount:480000,channels:2)
        var t=Timeline(media:[video,audio],mediaFrames:[video.id:300,audio.id:300],mediaHasAudio:[video.id:true,audio.id:true])
        let upper=UUID(), a2=UUID(), sub=UUID(), spec=UUID()
        t=try t.registeringImage(source,id:imageID).registeringImage(second,id:unusedID)
            .addingLane(.video,name:"upper",id:upper,outward:true).addingLane(.audio,name:"A2",id:a2,outward:true)
            .placingImage(media:imageID,at:0,lane:upper)
            .placing(media:video.id,at:0,videoLane:Lane.videoID,audioLane:Lane.audioID)
            .placing(media:audio.id,at:0,videoLane:nil,audioLane:a2)
        let key=t.audioClips.first{$0.mediaID == audio.id}!.id
        t=try t.splitting(clip:key,atFrame:30).addingLane(.subtitle,name:"sub",id:sub).addingLane(.spectrum,name:"sp",id:spec)
        var style=SubtitleStyle.default;style.outline = .default
        t=try t.addingSubtitle(lane:sub,at:0,length:20,text:"persistence",style:style)
            .addingSpectrum(lane:spec,at:0,length:100,sourceKey:key)
        let pid=UUID(), fixture=root.appendingPathComponent("input.ontheframe")
        let bm1=try source.url.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
        let bm2=try second.url.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
        let project=try ProjectPersistence.make(timeline:t,projectID:pid,bookmarks:[imageID:bm1,unusedID:bm2])
        _ = try ProjectPersistence.write(project,to:fixture)
        let store=ProjectStore()
        let opened=await store.openProject(at:fixture)
        try check(opened && store.projectID == pid && store.timeline.clips == t.clips,"real format9 open")
        try check(store.timeline.audioClips == t.audioClips && store.timeline.subtitles == t.subtitles && store.timeline.spectra == t.spectra,"mixed content")
        try check(store.player.currentItem == nil && store.currentPlan == nil && store.exportBlockReason != nil,"image project must not render old content")
        print("PASS 1 actual format9 open, mixed lineage, used/unused image references")

        let saved=root.appendingPathComponent("first-save.ontheframe")
        try check(store.writeProject(to:saved),"real first save")
        let first=try Data(contentsOf:saved)
        try check((try JSONSerialization.jsonObject(with:first) as! [String:Any])["version"] as? Int == 9,"format9 writer")
        var saveResult:Bool?
        store.saveProject { saveResult=$0 }
        try check(saveResult == true && store.projectURL == saved,"normal saveProject route")
        let reread=try ProjectPersistence.decode(Data(contentsOf:saved))
        try check(reread.projectID == pid && reread.timeline.clips == t.clips,"replacement identity")
        print("PASS 2 real first-save and normal replacement-save entry")

        let subfolder=root.appendingPathComponent("save-as")
        try FileManager.default.createDirectory(at:subfolder,withIntermediateDirectories:true)
        let saveAs=subfolder.appendingPathComponent("new.ontheframe")
        try check(store.writeProject(to:saveAs),"Save As destination")
        let asProject=try ProjectPersistence.decode(Data(contentsOf:saveAs))
        let record=asProject.media.first{$0.id == imageID}!
        let relative=try unwrap(record.relativePath,"relative path")
        try check(saveAs.deletingLastPathComponent().appendingPathComponent(relative).standardizedFileURL == source.url.standardizedFileURL,"Save As relative source")
        try check(record.bookmark != nil,"bookmark retained")
        print("PASS 3 Save As relative paths and bookmarks")

        let oldBytes=try Data(contentsOf:saveAs),oldTimeline=store.timeline,oldID=store.projectID,oldSaved=store.savedTimeline,oldBookmarks=store.bookmarks
        store.persistenceBeforeCommitForTest={throw TestFailure(message:"injected precommit failure")}
        try check(!store.writeProject(to:saveAs),"injected save must fail")
        try check(try Data(contentsOf:saveAs) == oldBytes,"replacement failure preserves bytes")
        try check(store.timeline == oldTimeline && store.projectID == oldID && store.savedTimeline == oldSaved && store.bookmarks == oldBookmarks,"save failure preserves app state")
        let absent=root.appendingPathComponent("failed-first.ontheframe")
        try check(!store.writeProject(to:absent) && !FileManager.default.fileExists(atPath:absent.path),"failed first save")
        store.persistenceBeforeCommitForTest=nil
        print("PASS 4 app precommit failures preserve destination and state")

        store.persistenceBeforeCommitForTest={withUnsafeCurrentTask{$0?.cancel()}}
        let cancelSave=Task { @MainActor in store.writeProject(to:saveAs) }
        let cancelledSave=await cancelSave.value
        let afterCancel=try Data(contentsOf:saveAs)
        try check(!cancelledSave && afterCancel == oldBytes,"cancelled app save")
        store.persistenceBeforeCommitForTest=nil
        print("PASS 5 cancelled app save before commit")

        for kind in ["corrupt","future","invalid"] {
            let url=root.appendingPathComponent(kind+".ontheframe")
            var raw=try JSONSerialization.jsonObject(with:first) as! [String:Any]
            if kind == "future" {raw["version"]=10}
            if kind == "invalid" {raw["media"]=[]}
            try (kind == "corrupt" ? Data("bad".utf8):JSONSerialization.data(withJSONObject:raw)).write(to:url)
            let ok=await store.openProject(at:url)
            try check(!ok && store.timeline == oldTimeline && store.projectID == oldID && store.savedTimeline == oldSaved,"failed open preserves active project")
        }
        print("PASS 6 corrupt, invalid and future-version open preserves active project")

        // Deterministic lease accounting around the real production scope call sites.
        // These hooks simulate acquired scopes, not an OS sandbox permission grant.
        store.stopAllScopes()
        var active:[String:Int]=[:], starts=0, stops=0, badStop=false
        store.persistenceBookmarkForTest={data in
            if data == bm1 {return source.url}
            if data == bm2 {return second.url}
            throw ProjectPersistence.Failure.invalid("injected invalid bookmark")
        }
        store.persistenceScopeStartForTest={url in active[url.path,default:0]+=1;starts+=1;return true}
        store.persistenceScopeStopForTest={url in
            if (active[url.path] ?? 0) <= 0 {badStop=true}
            active[url.path,default:0]-=1;stops+=1
        }
        let scopeOpen=await store.openProject(at:fixture)
        try check(scopeOpen && starts > 1,"scope acquisition exercised: opened=\(scopeOpen) starts=\(starts)")
        let stableActive=active.values.reduce(0,+)
        try check(stableActive == store.scopedURLs.count,"transferred scope ownership")
        store.persistenceCandidateForTest={_ in throw TestFailure(message:"candidate failure")}
        let failedCandidate=await store.openProject(at:fixture)
        try check(!failedCandidate && active.values.reduce(0,+) == stableActive,"failure scope cleanup")
        store.persistenceCandidateForTest={_ in store.cancelOpen()}
        let cancelOpen=await store.openProject(at:fixture)
        try check(!cancelOpen && active.values.reduce(0,+) == stableActive,"cancel scope cleanup")
        store.persistenceCandidateForTest=nil
        store.persistenceBookmarkForTest={_ in throw ProjectPersistence.Failure.invalid("fatal resolver injection")}
        let failedBookmark=await store.openProject(at:fixture)
        try check(!failedBookmark && active.values.reduce(0,+) == stableActive && store.projectID == pid,"fatal bookmark failure preserves active project/scopes")
        store.persistenceBookmarkForTest={data in data == bm1 ? source.url : second.url}
        store.resetProject()
        let emptyID=store.projectID
        store.persistenceCandidateForTest={_ in store.resetProject()}
        let stale=await store.openProject(at:fixture)
        try check(!stale && store.projectID != emptyID && store.timeline == Timeline(),"session replacement with equal empty Timeline rejects stale open")
        store.persistenceCandidateForTest=nil
        store.stopAllScopes()
        try check(active.values.reduce(0,+) == 0 && starts == stops && !badStop,"final scope drain")
        store.persistenceScopeStartForTest=nil;store.persistenceScopeStopForTest=nil;store.persistenceBookmarkForTest=nil
        print("PASS 7 scope acquire/transfer/release on success, failure, cancellation (injected leases)")

        var model=try OperationalProjectAdapter.model(project.state)
        for i in model.media.indices where model.media[i].ref.kind == .stillImage {
            let ref=model.media[i].ref.still!
            model.media[i].ref = .stillImage(.init(id:ref.id,name:ref.name,path:root.appendingPathComponent("absent-"+ref.id.uuidString).path,size:ref.size,modifiedNs:ref.modifiedNs,image:ref.image))
            model.media[i].relativePath="offline/"+ref.id.uuidString;model.media[i].bookmark=nil
        }
        let missing=root.appendingPathComponent("missing.ontheframe")
        try StillImageProjectCodec.encode(model).write(to:missing)
        let missingOpen=await store.openProject(at:missing)
        try check(missingOpen && store.timeline.clips == t.clips && store.missingMedia[imageID] != nil && store.missingMedia[unusedID] != nil,"missing images restore")
        try check(store.timeline.mediaCatalog.compactMap(\.still).allSatisfy{$0.validationState == .unverified},"no manufactured validation")
        let round=root.appendingPathComponent("missing-round.ontheframe")
        try check(store.writeProject(to:round),"missing source save")
        let savedMissing=try ProjectPersistence.decode(Data(contentsOf:round))
        try check(savedMissing.media.first{$0.id == imageID}?.relativePath == "offline/"+imageID.uuidString,"unavailable relative hint preserved")
        let roundOpen=await store.openProject(at:round)
        try check(roundOpen && store.projectID == pid && store.timeline.clips == t.clips,"missing repeated open identity")
        let unusedOnly=try ProjectPersistence.make(timeline:Timeline().registeringImage(second,id:unusedID),projectID:UUID())
        let unusedFile=root.appendingPathComponent("unused-only.ontheframe")
        _ = try ProjectPersistence.write(unusedOnly,to:unusedFile)
        let unusedOpen=await store.openProject(at:unusedFile)
        try check(unusedOpen && store.timeline.isEmpty && store.timeline.mediaCatalog.count == 1 && store.player.currentItem == nil,"unused-only image reference remains gated")
        try check(store.writeProject(to:unusedFile),"unused-only save")
        try check(try ProjectPersistence.decode(Data(contentsOf:unusedFile)).version == 9,"unused-only must write 9")
        print("PASS 8 missing used/unused images and repeated save/open")

        let export=root.appendingPathComponent("must-not-exist.mp4")
        store.play()
        try check(!store.isPlaying,"unsupported preview must not play")
        store.startExport(.fromSavePanel(export))
        try check(!FileManager.default.fileExists(atPath:export.path) && store.player.currentItem == nil && store.currentPlan == nil,"export/preview blocked")
        do {_ = try await CompositionPlanner.plan(store.timeline,media:[:]);throw TestFailure(message:"direct planner admitted image")}
        catch is ProductionContent.Unsupported {}
        print("PASS 9 app and direct preview/export gate remains effective")

        for version in 1...8 {
            let id=UUID(), base=ProjectFile.Document(format:ProjectFile.format,version:version,projectID:id,settings:.init(width:1920,height:1080,fps:30),durationFrames:30,lanes:Lane.defaults,media:[],videoClips:[],audioClips:[],subtitles:nil,spectra:nil)
            let file=root.appendingPathComponent("legacy-\(version).ontheframe")
            try JSONEncoder().encode(base).write(to:file)
            let ok=await store.openProject(at:file)
            try check(ok && store.projectID == id && store.timeline.durationFrames == 30,"legacy app open \(version)")
            try check(store.writeProject(to:file),"legacy app save")
            try check(try ProjectFile.decode(Data(contentsOf:file)).document.version == 5,"image-free conditional writer")
        }
        for version in 5...8 {
            var lanes=Lane.defaults, subtitles:[SubtitleItem]?=nil, spectra:[SpectrumItem]?=nil
            let sub=UUID(), spec=UUID()
            if version>=6 {lanes.insert(Lane(id:sub,kind:.subtitle,name:"legacy sub"),at:0)}
            if version==7 {
                var style=SubtitleStyle.default;style.outline = .default
                subtitles=[SubtitleItem(lane:sub,start:0,length:10,text:"legacy effect",style:style)]
            }
            if version==8 {lanes.insert(Lane(id:spec,kind:.spectrum,name:"legacy spectrum"),at:1);spectra=[SpectrumItem(lane:spec,start:0,length:10,sourceKey:nil)]}
            let doc=ProjectFile.Document(format:ProjectFile.format,version:version,projectID:UUID(),settings:.init(width:1920,height:1080,fps:30),durationFrames:30,lanes:lanes,media:[],videoClips:[],audioClips:[],subtitles:subtitles,spectra:spectra)
            let file=root.appendingPathComponent("conditional-\(version).ontheframe")
            try JSONEncoder().encode(doc).write(to:file)
            let ok=await store.openProject(at:file)
            try check(ok && store.timeline.subtitles == (subtitles ?? []) && store.timeline.spectra == (spectra ?? []),"conditional app open")
            try check(store.writeProject(to:file),"conditional app save")
            try check(try ProjectFile.decode(Data(contentsOf:file)).document.version == version,"conditional writer \(version)")
        }
        store.stopAllScopes()
        print("PASS 10 legacy 1–8 app open and conditional format5–8 saves")
    }
    static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {throw TestFailure(message:message)};return value
    }
}
