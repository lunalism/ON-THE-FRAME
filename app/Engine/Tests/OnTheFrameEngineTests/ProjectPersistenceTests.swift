import XCTest
@testable import OnTheFrameEngine

final class ProjectPersistenceTests: XCTestCase {
    func root() throws -> URL {
        let parent=ProcessInfo.processInfo.environment["OTF_MODEL03_RUN"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory
        let root=parent.appendingPathComponent("persist-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    func imageProject(unused: Bool = false) async throws -> ProjectPersistence.Project {
        let source=try await ImageModelFixture.image(), id=UUID()
        var t=try Timeline().registeringImage(source,id:id)
        if !unused { t=try t.inserting(media:id) }
        return try ProjectPersistence.make(timeline:t,projectID:UUID())
    }
    func testFormat9FirstAndReplacementSaveWithStableIdentity() async throws {
        let dir=try root(), dest=dir.appendingPathComponent("project.ontheframe")
        for unused in [false,true] {
            let p=try await imageProject(unused:unused)
            let existing=FileManager.default.fileExists(atPath:dest.path)
            if existing { try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:dest.path) }
            let receipt=try ProjectPersistence.write(p,to:dest)
            XCTAssertNil(receipt.postCommitWarning)
            if existing { XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:dest.path)[.posixPermissions] as? NSNumber)?.intValue,0o600) }
            let bytes=try Data(contentsOf:dest), back=try ProjectPersistence.decode(bytes)
            XCTAssertEqual((try JSONSerialization.jsonObject(with:bytes) as! [String:Any])["version"] as? Int,9)
            XCTAssertEqual(back.projectID,p.projectID);XCTAssertEqual(back.timeline.clips,p.timeline.clips)
            XCTAssertEqual(back.timeline.mediaCatalog.map(\.id),p.timeline.mediaCatalog.map(\.id))
            XCTAssertTrue(back.timeline.mediaCatalog.compactMap(\.still).allSatisfy{$0.validationState == .unverified})
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.path),[dest.lastPathComponent])
        }
    }
    func testPrecommitFailureCancellationAndReplacementFailurePreserveBytes() async throws {
        let p=try await imageProject(),dir=try root(),dest=dir.appendingPathComponent("replace.ontheframe")
        let original=Data("old disposable project".utf8);try original.write(to:dest,options:.withoutOverwriting)
        XCTAssertThrowsError(try ProjectPersistence.write(p,to:dest,beforeCommit:{throw CocoaError(.fileWriteUnknown)}))
        XCTAssertEqual(try Data(contentsOf:dest),original)
        var ops=ProjectPersistence.Operations();ops.commit={_,_,_ in throw POSIXError(.EACCES)}
        XCTAssertThrowsError(try ProjectPersistence.writeCandidate(p,to:dest,operations:ops))
        XCTAssertEqual(try Data(contentsOf:dest),original)
        let task=Task { () -> Bool in
            do {
                _ = try ProjectPersistence.write(p,to:dest,beforeCommit:{ withUnsafeCurrentTask{$0?.cancel()} })
                return false
            } catch { return true }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try Data(contentsOf:dest),original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.path),[dest.lastPathComponent])
        XCTAssertThrowsError(try ProjectPersistence.write(p,to:dir.appendingPathComponent("absent/path.ontheframe")))
    }
    func testPostcommitWarningIsNotReportedAsRollback() async throws {
        let p=try await imageProject(), dest=try root().appendingPathComponent("post.ontheframe")
        try Data("old".utf8).write(to:dest)
        var ops=ProjectPersistence.Operations();ops.afterCommit={throw CocoaError(.fileReadUnknown)}
        let receipt=try ProjectPersistence.writeCandidate(p,to:dest,operations:ops)
        XCTAssertNotNil(receipt.postCommitWarning)
        XCTAssertEqual(try ProjectPersistence.decode(Data(contentsOf:dest)).projectID,p.projectID)
    }
    func testMissingImageInvalidFutureAndRenderingGuards() async throws {
        let p=try await imageProject()
        var model=try OperationalProjectAdapter.model(p.state)
        let old=model.media[0].ref.still!
        model.media[0].ref = .stillImage(.init(id:old.id,name:old.name,path:"/generated/absent-"+UUID().uuidString,size:old.size,modifiedNs:old.modifiedNs,image:old.image))
        let bytes=try StillImageProjectCodec.encode(model)
        let back=try ProjectPersistence.decode(bytes)
        XCTAssertEqual(back.timeline.clips,p.timeline.clips)
        XCTAssertEqual(back.media[0].path,model.media[0].ref.path)
        XCTAssertThrowsError(try CompositionPlanner.layerStack(back.timeline,from:0,to:1,media:[:],render:CGSize(width:1920,height:1080)))
        var raw=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        raw["version"]=10
        XCTAssertThrowsError(try ProjectPersistence.decode(JSONSerialization.data(withJSONObject:raw)))
        raw["version"]=9;raw["media"]=[]
        XCTAssertThrowsError(try ProjectPersistence.decode(JSONSerialization.data(withJSONObject:raw)))
    }
    func testProtectOriginalSourcesAndSaveAsResolvedRelativePaths() async throws {
        let p=try await imageProject(), source=URL(fileURLWithPath:p.media[0].path), original=try Data(contentsOf:source)
        XCTAssertThrowsError(try ProjectPersistence.write(p,to:source))
        XCTAssertEqual(try Data(contentsOf:source),original)
        let dest=source.deletingLastPathComponent().appendingPathComponent("saved.ontheframe")
        let receipt=try ProjectPersistence.write(p,to:dest,resolvedURLs:[p.media[0].id:source])
        XCTAssertEqual(receipt.project.media[0].relativePath,source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf:source),original)
    }
    func testImageValidationAndCrossFormatRelinkFacade() async throws {
        let p=try await imageProject(),url=try root().appendingPathComponent("validation.ontheframe")
        let loaded=try ProjectPersistence.decode(ProjectPersistence.encode(p,at:url))
        let id=loaded.media[0].id
        try await ProjectPersistence.validateImageReference(loaded,mediaID:id,at:URL(fileURLWithPath:loaded.media[0].path))
        XCTAssertEqual(loaded.timeline.mediaCatalog.first?.still?.validationState,.unverified)
        let jpeg=try await ImageModelFixture.image("jpg",width:4,height:5,orientation:6)
        do {try await ProjectPersistence.validateImageReference(loaded,mediaID:id,at:jpeg.url);XCTFail("changed image accepted")}
        catch {if case ProjectPersistence.Failure.sourceChanged(let actual)=error {XCTAssertEqual(actual,id)} else {XCTFail("wrong error \(error)")}}
        let (linked,change)=try await ProjectPersistence.relinkImage(loaded,mediaID:id,to:jpeg.url)
        XCTAssertTrue(change.requiresNotification);XCTAssertEqual(change.newWidth,4)
        XCTAssertEqual(linked.timeline.clips,loaded.timeline.clips)
        XCTAssertEqual(linked.media[0].id,id)
        let png=try await ImageModelFixture.image()
        let (back,_)=try await ProjectPersistence.relinkImage(linked,mediaID:id,to:png.url)
        XCTAssertEqual(back.timeline.clips,loaded.timeline.clips)
    }
    func testLegacyAndConditionalWriterAndMixedData() async throws {
        let suite=OperationalProjectAdapterTests(), state=try await suite.mixed()
        let p=try ProjectPersistence.make(timeline:state.timeline,projectID:state.projectID)
        let dest=try root().appendingPathComponent("mixed.ontheframe")
        let back=try ProjectPersistence.write(p,to:dest).project
        XCTAssertEqual(back.timeline.clips,p.timeline.clips);XCTAssertEqual(back.timeline.audioClips,p.timeline.audioClips)
        XCTAssertEqual(back.timeline.subtitles,p.timeline.subtitles);XCTAssertEqual(back.timeline.spectra,p.timeline.spectra)
        let temporal=try suite.temporalState()
        for version in 1...8 {
            var model=try OperationalProjectAdapter.model(temporal)
            model.durationFrames=30
            var raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(model.temporalDocument())) as! [String:Any];raw["version"]=version
            let data=try JSONSerialization.data(withJSONObject:raw)
            XCTAssertEqual(try ProjectPersistence.decode(data).timeline,try ProjectFile.decode(data).timeline)
        }
        for version in 5...8 {
            var model=try OperationalProjectAdapter.model(temporal);model.durationFrames=300
            if version>=6 {model.lanes.insert(Lane(id:UUID(),kind:.subtitle,name:"sub"),at:0)}
            if version==7 {var style=SubtitleStyle.default;style.outline = .default;model.subtitles=[SubtitleItem(lane:model.lanes[0].id,start:0,length:10,text:"effect",style:style)]}
            if version==8 {model.lanes.insert(Lane(id:UUID(),kind:.spectrum,name:"sp"),at:1)}
            let t=try Timeline.restoring(model), project=try ProjectPersistence.make(timeline:t,projectID:model.projectID)
            let data=try ProjectPersistence.encode(project,at:dest)
            XCTAssertEqual(try ProjectFile.decode(data).document.version,version)
        }
    }
}
