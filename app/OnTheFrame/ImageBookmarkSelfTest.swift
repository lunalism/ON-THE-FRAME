#if DEBUG
import AppKit
import AVFoundation
import CryptoKit
@testable import OnTheFrameEngine

/// Explicit signed-app diagnostic; real scope APIs, generated input only, no native panel acceptance.
@MainActor enum ImageBookmarkSelfTest {
    struct Failure: Error { let message: String }
    static func run(folder: URL) async {
        let s=ProjectStore.shared
        var checks=[String:Bool](), events=[[String:Any]](), active=[String:Int]()
        var starts=0,stops=0,badStop=false,recordTermination=false
        func require(_ name:String,_ value:Bool)throws {checks[name]=value;if !value {throw Failure(message:name)}}
        func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
        func count()->Int {active.values.reduce(0,+)}
        func dismiss()async {
            if s.alerts.currentSheet != nil {s.alerts.pressButton(1)}
            else if s.alerts.current != nil {s.alerts.pressButton(0)}
            let deadline=Date().addingTimeInterval(3)
            while (s.alerts.isShowing || s.editorWindow?.attachedSheet != nil),Date()<deadline {try? await Task.sleep(nanoseconds:10_000_000)}
        }
        s.persistenceScopeStartForTest={u in
            let acquired=u.startAccessingSecurityScopedResource()
            if acquired {active[u.path,default:0]+=1;starts+=1}
            events.append(["event":"start","file":u.lastPathComponent,"acquired":acquired,"active":count()])
            return acquired
        }
        s.persistenceScopeStopForTest={u in
            if active[u.path,default:0]<=0 {badStop=true} else {active[u.path,default:0]-=1}
            stops+=1;u.stopAccessingSecurityScopedResource()
            events.append(["event":"stop","file":u.lastPathComponent,"active":count()])
            if recordTermination {
                try? JSONSerialization.data(withJSONObject:["active":count(),"starts":starts,"stops":stops,"badStop":badStop],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("termination-scopes.json"))
            }
        }
        s.persistenceBookmarkForTest={data in
            var stale=false
            do {
                let u=try URL(resolvingBookmarkData:data,options:[.withSecurityScope],relativeTo:nil,bookmarkDataIsStale:&stale)
                events.append(["event":"resolve","file":u.lastPathComponent,"stale":stale,"success":true])
                return u
            } catch {events.append(["event":"resolve","success":false]);throw error}
        }
        var errorText:String?
        do {
            try require("isolated gated instance",EditorLayout.shared.suiteName != nil && ProjectStore.imageImportEnabled)
            let input=folder.appendingPathComponent("input.ontheframe"),bytes=try Data(contentsOf:input)
            let expected=try ProjectPersistence.decode(bytes)
            let opened=await s.openProject(at:input)
            try require("fresh process open",opened && s.missingMedia.isEmpty)
            try require("project UUID",s.projectID==expected.projectID)
            try require("complete timeline",s.timeline==expected.timeline)
            try require("actual acquired session access",count()>0 && count()==s.scopedURLs.count)
            let stable=count(),id=s.projectID,timeline=s.timeline
            for entry in expected.media where entry.kind == .stillImage {
                var stale=false
                guard let bookmark=entry.bookmark else {throw Failure(message:"missing input bookmark")}
                let url=try URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope],relativeTo:nil,bookmarkDataIsStale:&stale)
                try await ProjectPersistence.validateImageReference(expected,mediaID:entry.id,at:url)
                events.append(["event":"fresh full probe","mediaID":entry.id.uuidString,"file":url.lastPathComponent,"pass":true])
            }
            let until=Date().addingTimeInterval(5)
            while s.player.currentItem?.status != .readyToPlay,Date()<until {try await Task.sleep(nanoseconds:20_000_000)}
            try require("native preview item ready",s.player.currentItem?.status == .readyToPlay)
            let round=folder.appendingPathComponent("roundtrip.ontheframe")
            try require("normal app save",s.writeProject(to:round))
            let back=try ProjectPersistence.decode(Data(contentsOf:round))
            try require("saved identities edits and metadata",back.projectID==id && back.timeline==timeline)
            try require("operation local save scopes released",count()==stable)
            let invalid=folder.appendingPathComponent("invalid.ontheframe")
            try Data("invalid generated project".utf8).write(to:invalid,options:.withoutOverwriting)
            let failed=await s.openProject(at:invalid)
            try require("failed open preserves session and access",!failed && s.projectID==id && s.timeline==timeline && count()==stable)
            await dismiss()
            s.persistenceCandidateForTest={_ in s.cancelOpen()}
            let cancelled=await s.openProject(at:input)
            try require("cancelled candidate releases real scopes",!cancelled && count()==stable && s.projectID==id && s.timeline==timeline)
            s.persistenceCandidateForTest=nil
            s.persistenceCandidateForTest={_ in throw Failure(message:"controlled candidate failure")}
            let rejected=await s.openProject(at:input)
            try require("failed candidate releases real scopes",!rejected && count()==stable && s.projectID==id && s.timeline==timeline)
            s.persistenceCandidateForTest=nil;await dismiss()

            let raw=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            for mode in ["missing-bookmark","invalid-bookmark","missing-source"] {
                var d=raw,media=d["media"] as! [[String:Any]]
                for i in media.indices {
                    var ref=media[i]["ref"] as! [String:Any]
                    guard ref["kind"] as? String == "stillImage" else {continue}
                    media[i]["bookmark"]=mode == "invalid-bookmark" ? Data("invalid bookmark".utf8).base64EncodedString():nil
                    // No fake validation: missing source is an explicit absent generated path.
                    if mode == "missing-source" {ref["path"]=folder.appendingPathComponent("absent-"+String(i)+".png").path;media[i]["relativePath"]="absent-"+String(i)+".png"}
                    else {media[i]["relativePath"]=nil}
                    media[i]["ref"]=ref
                }
                d["media"]=media
                let file=folder.appendingPathComponent(mode+".ontheframe")
                try JSONSerialization.data(withJSONObject:d,options:.sortedKeys).write(to:file,options:.withoutOverwriting)
                let ok=await s.openProject(at:file)
                try require(mode+" preserves structure",ok && s.projectID==id && s.timeline.clips==timeline.clips && s.timeline.audioClips==timeline.audioClips && s.timeline.subtitles==timeline.subtitles && s.timeline.mediaCatalog.map(\.id)==timeline.mediaCatalog.map(\.id))
                if mode == "missing-source" {
                    try require("missing images remain unverified",Set(s.missingMedia.keys).isSuperset(of:timeline.stillImageIDs) && s.timeline.mediaCatalog.compactMap(\.still).allSatisfy{$0.validationState == .unverified})
                }
                events.append(["event":mode,"missing":s.missingMedia.count,"owned":s.scopedURLs.count,"active":count()])
                // Availability must remain real AFTER old session scopes were released.
                for entry in expected.media where entry.kind == .stillImage && s.missingMedia[entry.id] == nil {
                    try await ProjectPersistence.validateImageReference(expected,mediaID:entry.id,at:URL(fileURLWithPath:entry.path))
                }
                checks[mode+" post-commit access consistent"]=true
                await dismiss()
                let restored=await s.openProject(at:input)
                try require(mode+" explicit revalidation",restored && s.missingMedia.isEmpty && s.projectID==id && s.timeline.clips==timeline.clips)
                try require(mode+" balanced ownership",count()==s.scopedURLs.count)
            }
            // Move only a new disposable copy; never rename the owner's selected fixture.
            var movedDoc=raw, movedMedia=raw["media"] as! [[String:Any]]
            guard let imageIndex=movedMedia.firstIndex(where:{($0["ref"] as? [String:Any])?["kind"] as? String == "stillImage"}) else {throw Failure(message:"image fixture absent")}
            var copiedRef=movedMedia[imageIndex]["ref"] as! [String:Any]
            let source=URL(fileURLWithPath:copiedRef["path"] as! String)
            let copy=folder.appendingPathComponent("movable-copy."+source.pathExtension), moved=folder.appendingPathComponent("moved-copy."+source.pathExtension)
            try FileManager.default.copyItem(at:source,to:copy)
            let copyBytes=try Data(contentsOf:copy)
            copiedRef["path"]=copy.path;movedMedia[imageIndex]["ref"]=copiedRef;movedMedia[imageIndex]["relativePath"]=nil
            movedMedia[imageIndex]["bookmark"]=try copy.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:nil,relativeTo:nil).base64EncodedString()
            movedDoc["media"]=movedMedia
            let moveProject=folder.appendingPathComponent("move.ontheframe")
            try JSONSerialization.data(withJSONObject:movedDoc).write(to:moveProject,options:.withoutOverwriting)
            try FileManager.default.moveItem(at:copy,to:moved)
            let movedOpen=await s.openProject(at:moveProject)
            try require("moved source preserves document",movedOpen && s.projectID==id && s.timeline.clips==timeline.clips)
            events.append(["event":"moved source","missing":s.missingMedia.count,"active":count()])
            await dismiss()
            movedMedia[imageIndex]["bookmark"]=nil;movedDoc["media"]=movedMedia
            let absentProject=folder.appendingPathComponent("temporarily-missing.ontheframe")
            try JSONSerialization.data(withJSONObject:movedDoc).write(to:absentProject,options:.withoutOverwriting)
            let missingID=UUID(uuidString:copiedRef["id"] as! String)!
            let missingOpen=await s.openProject(at:absentProject)
            try require("temporarily absent copy safely missing",missingOpen && s.missingMedia[missingID] != nil && s.timeline.clips==timeline.clips)
            await dismiss()
            try FileManager.default.moveItem(at:moved,to:copy)
            let returned=await s.openProject(at:absentProject)
            try require("returned source freshly revalidated",returned && s.missingMedia[missingID]==nil && s.projectID==id && s.timeline.clips==timeline.clips)
            try require("moved copy bytes preserved",try Data(contentsOf:copy)==copyBytes)
            // A newer session created while candidate validation is suspended must win.
            s.resetProject();let emptyID=s.projectID
            s.persistenceCandidateForTest={_ in s.resetProject()}
            let stale=await s.openProject(at:input)
            try require("late candidate cannot replace new session",!stale && s.projectID != emptyID && s.timeline==Timeline() && count()==0)
            s.persistenceCandidateForTest=nil;await dismiss()
            s.stopAllScopes()
            let drain=Date().addingTimeInterval(5)
            while (ImagePreviewCompositor.admission.outstanding != 0 || ImagePreviewMetal.ownership.counts.active != 0),Date()<drain {try await Task.sleep(nanoseconds:10_000_000)}
            try require("scope accounting balanced",starts==stops && count()==0 && !badStop && s.scopedURLs.isEmpty)
            try require("observed command resources retired",ImagePreviewCompositor.admission.outstanding==0 && ImagePreviewMetal.ownership.counts.active==0 && ImagePreviewMetal.ownership.counts.resources==0)
            try require("original project bytes preserved",try Data(contentsOf:input)==bytes)
            events.append(["event":"input digest","sha256":digest(bytes)])
            let closingSession=await s.openProject(at:input)
            try require("normal termination starts with owned access",closingSession && count()>0)

        } catch {errorText=String(describing:error)}
        s.persistenceCandidateForTest=nil
        await dismiss();if errorText != nil {s.stopAllScopes()}
        let result:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"checks":checks,"pass":errorText==nil && checks.values.allSatisfy{$0},"error":errorText as Any? ?? NSNull(),"starts":starts,"stops":stops,"active":count(),"badStop":badStop,"events":events,"nativePanelsTested":false]
        try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("bookmark-result.json"))
        s.persistenceBookmarkForTest=nil
        guard !s.alerts.isShowing else {return}
        recordTermination=true
        s.discardConfirmedForTest();NSApp.terminate(nil)
    }
}
#endif
