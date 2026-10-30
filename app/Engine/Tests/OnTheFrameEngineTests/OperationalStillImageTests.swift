import XCTest
import AVFoundation
@testable import OnTheFrameEngine

final class OperationalStillImageTests: XCTestCase {
    func base() async throws -> (Timeline,UUID) {
        let id=UUID()
        return (try Timeline().registeringImage(await ImageModelFixture.image(),id:id),id)
    }
    func testCatalogIdentityAndNoTemporalFields() async throws {
        let source=try await ImageModelFixture.image(), id=UUID()
        let t=try Timeline().registeringImage(source,id:id)
        let r=try XCTUnwrap(t.mediaCatalog.first)
        XCTAssertEqual(r.kind,.stillImage); XCTAssertNil(r.temporal); XCTAssertNil(r.sourceFrames)
        XCTAssertFalse(r.hasVideoTrack); XCTAssertTrue(r.hasVisualContent); XCTAssertFalse(r.hasAudio)
        XCTAssertEqual(r.still?.descriptor?.identity,source.descriptor.identity)
        XCTAssertEqual(r.still?.reference.id,id); XCTAssertTrue(t.media.isEmpty)
        XCTAssertNil(t.mediaFrames[id]); XCTAssertEqual(t.mediaHasVideo[id],false); XCTAssertEqual(t.mediaHasAudio[id],false)
        XCTAssertTrue(t.isValid)
        XCTAssertThrowsError(try t.registeringImage(source,id:id))
        let temporal=ImageModelFixture.temporal()
        let legacy=Timeline(media:[temporal],mediaFrames:[temporal.id:300])
        XCTAssertThrowsError(try legacy.registeringImage(source,id:temporal.id))
        XCTAssertEqual(legacy.mediaCatalog.first?.kind,.video)
        XCTAssertTrue(legacy.mediaCatalog.first!.hasVideoTrack)
    }
    func testInsertionMinimumLaneAndArithmetic() async throws {
        let (t,id)=try await base(), lane=Lane.videoID
        let inserted=try t.inserting(media:id)
        XCTAssertEqual(inserted.clips[0].length,150); XCTAssertTrue(inserted.audioClips.isEmpty)
        XCTAssertEqual(inserted.clips[0].sourceIn,0); XCTAssertNil(inserted.clips[0].link)
        XCTAssertNil(inserted.source(atFrame:0)); XCTAssertEqual(inserted.durationFrames,150)
        XCTAssertEqual(try t.placingImage(media:id,at:1,lane:lane,length:1).clips[0].length,1)
        for length in [0,-1,Int.max] { XCTAssertThrowsError(try t.placingImage(media:id,at:0,lane:lane,length:length)) }
        for start in [-1,Int.max,Timeline.maxFrames] { XCTAssertThrowsError(try t.placingImage(media:id,at:start,lane:lane)) }
        XCTAssertThrowsError(try t.placingImage(media:id,at:0,lane:Lane.audioID))
        XCTAssertThrowsError(try t.placing(media:id,at:0,videoLane:lane,audioLane:Lane.audioID))
        XCTAssertEqual(try inserted.appending(media:id,videoLane:lane,audioLane:nil).durationFrames,300)
        let full=try t.placingImage(media:id,at:0,lane:lane,length:Timeline.maxFrames)
        XCTAssertThrowsError(try full.inserting(media:id))
        XCTAssertThrowsError(try inserted.relocating(clip:inserted.clips[0].id,toStart:Int.max))
    }
    func testOverlapOrderingAndCatalogSurvivesEdits() async throws {
        let (base,id)=try await base(), upper=UUID()
        let t=try base.addingLane(.video,name:"upper",id:upper,outward:true).placingImage(media:id,at:0,lane:Lane.videoID)
        XCTAssertThrowsError(try t.placingImage(media:id,at:1,lane:Lane.videoID))
        let layered=try t.placingImage(media:id,at:30,lane:upper)
        XCTAssertEqual(layered.clips.first?.lane,upper)
        XCTAssertTrue(layered.visibleVideoSegments().allSatisfy{$0.sourceIn == 0})
        XCTAssertEqual(layered.visibleVideoSegments().map(\.length),[30,150])
        let filtered=layered.excludingMedia([id])
        XCTAssertTrue(filtered.clips.isEmpty); XCTAssertEqual(filtered.stillImageIDs,[id])
        XCTAssertThrowsError(try ProductionContent(filtered).supportedTimeline())
        XCTAssertEqual(try layered.renamingLane(upper,to:"renamed").stillImageIDs,[id])
    }
    func testTrimSplitMoveAndCopy() async throws {
        let (base,id)=try await base(), t=try base.inserting(media:id), clip=t.clips[0]
        let left=try t.trimmingStart(clip:clip.id,by:20)
        XCTAssertEqual(left.clips[0].start,0); XCTAssertEqual(left.clips[0].length,130)
        XCTAssertEqual(left.clips[0].sourceIn,0); XCTAssertEqual(left.durationFrames,130)
        let extended=try left.trimmingStart(clip:clip.id,by:-200).trimmingEnd(clip:clip.id,by:500)
        XCTAssertEqual(extended.clips[0].length,830); XCTAssertEqual(extended.clips[0].sourceIn,0)
        XCTAssertThrowsError(try t.trimming(clip:clip.id,sourceIn:1,length:10))
        XCTAssertThrowsError(try t.trimmingEnd(clip:clip.id,by:Int.max))
        XCTAssertThrowsError(try t.trimmingStart(clip:clip.id,by:Int.min))
        XCTAssertEqual(try t.trimmingEnd(clip:clip.id,by:-1000).clips[0].length,1)
        let split=try t.splitting(clip:clip.id,atFrame:50)
        XCTAssertEqual(split.clips.map(\.length),[50,100]); XCTAssertEqual(split.clips.map(\.sourceIn),[0,0])
        XCTAssertEqual(Set(split.clips.map(\.id)).count,2); XCTAssertFalse(split.clips.contains{$0.id == clip.id})
        XCTAssertTrue(split.clips.allSatisfy{$0.mediaID == id})
        XCTAssertThrowsError(try t.splitting(clip:clip.id,atFrame:50,newIDs:(clip.id,UUID())))
        let moved=try split.moving(clip:split.clips[1].id,toIndex:0)
        XCTAssertEqual(moved.clips.map(\.length),[100,50]); XCTAssertTrue(moved.clips.allSatisfy{$0.sourceIn == 0})
        let free=try t.movingFree(clip:clip.id,toStart:40)
        XCTAssertEqual(free.clips[0].start,40); XCTAssertEqual(free.clips[0].sourceIn,0)
        let content=try XCTUnwrap(t.copying(clip:clip.id))
        let paste=try t.pasting(content,at:160,newLaneName:{_ in "copy"}).timeline
        XCTAssertEqual(paste.clips.count,2); XCTAssertNotEqual(paste.clips[1].id,clip.id)
        XCTAssertEqual(paste.clips[1].mediaID,id); XCTAssertEqual(paste.clips[1].sourceIn,0)
        XCTAssertThrowsError(try t.pasting(content,at:Int.max,newLaneName:{_ in "copy"}))
    }
    func testRippleDeleteUndoRedoAndConflicts() async throws {
        let (base,id)=try await base(), t=try base.inserting(media:id).inserting(media:id)
        let first=t.clips[0].id
        XCTAssertEqual(try t.trimmingEnd(clip:first,by:30).clips.map(\.start),[0,180])
        let deleted=try t.rippleDeleting(clip:first)
        XCTAssertEqual(deleted.clips[0].start,0); XCTAssertEqual(deleted.durationFrames,150)
        let lifted=try t.lifting(clip:first)
        XCTAssertEqual(lifted.clips[0].start,150); XCTAssertEqual(lifted.durationFrames,300)
        var history=EditHistory(t)
        history.apply(deleted,focus:nil)
        _ = history.undo(); XCTAssertEqual(history.timeline,t)
        _ = history.redo(); XCTAssertEqual(history.timeline,deleted)
        XCTAssertEqual(history.timeline.stillImageIDs,[id])
        let upper=UUID()
        let conflict=try t.addingLane(.video,name:"upper",id:upper,outward:true).placingImage(media:id,at:140,lane:upper,length:20)
        XCTAssertThrowsError(try conflict.trimmingEnd(clip:first,by:10))
        XCTAssertThrowsError(try conflict.rippleDeleting(clip:first))
    }
    func testAudioSpectrumAndMalformedImageRejection() async throws {
        let (base,id)=try await base(), t=try base.inserting(media:id), c=t.clips[0]
        XCTAssertThrowsError(try t.settingClipAudio(clip:c.id,volumePercent:50))
        XCTAssertTrue(t.spectrumSources().isEmpty)
        let spec=UUID(), withLane=try t.addingLane(.spectrum,name:"spectrum",id:spec)
        XCTAssertThrowsError(try withLane.addingSpectrum(lane:spec,at:0,length:10,sourceKey:id))
        XCTAssertThrowsError(try withLane.addingSpectrum(lane:spec,at:0,length:10,sourceKey:c.id))
        XCTAssertFalse(t.rebuilt(video:[c.with(sourceIn:1)]).isValid)
        XCTAssertFalse(t.rebuilt(video:[],audio:[c.with(lane:.some(Lane.audioID))]).isValid)
        XCTAssertFalse(t.rebuilt(mediaFrames:[id:150]).isValid)
        XCTAssertFalse(t.rebuilt(mediaHasVideo:[id:true]).isValid)
        let temporal=ImageModelFixture.temporal()
        XCTAssertThrowsError(try t.relinking(media:id,to:temporal))
    }
    func testOperationalOcclusionAndDestinationPreservation() async throws {
        let (base,id)=try await base(), upper=UUID(), videoID=UUID()
        let asset=MediaAsset(id:videoID,url:URL(fileURLWithPath:"/generated/video.mp4"),name:"video",frameCount:300,
            timing:SourceTiming(sampleCount:300,isVariable:false,frameDurationValue:1,frameDurationTimescale:30,averageFPS:30,minInterval:1.0/30,maxInterval:1.0/30),
            naturalSize:CGSize(width:1920,height:1080),displaySize:CGSize(width:1920,height:1080),preferredTransform:.identity,
            hasAudio:false,codec:"avc1",identity:FileIdentity(device:1,inode:1,size:100,modifiedNs:1))
        let t=try base.registering(asset).addingLane(.video,name:"opaque upper",id:upper,outward:true)
            .placingImage(media:id,at:0,lane:Lane.videoID)
            .placing(media:videoID,at:0,videoLane:upper,audioLane:nil)
        let size=CGSize(width:1920,height:1080)
        XCTAssertEqual(CompositionPlanner.displayRect(asset,.identity,render:size),CGRect(origin:.zero,size:size))
        XCTAssertEqual(t.clips.first?.mediaID,videoID)
        XCTAssertEqual(t.mediaCatalog.map(\.id),[id,videoID])
        XCTAssertThrowsError(try CompositionPlanner.layerStack(t,from:0,to:1,media:[videoID:asset],render:size)) { XCTAssertTrue($0 is ProductionContent.Unsupported) }
        XCTAssertThrowsError(try CompositionPlanner.layeredSegments(t,media:[videoID:asset],render:size)) { XCTAssertTrue($0 is ProductionContent.Unsupported) }
        do { _ = try await CompositionPlanner.plan(t,media:[videoID:asset]); XCTFail("occluded image admitted") }
        catch { XCTAssertTrue(error is ProductionContent.Unsupported) }
        let dest=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original=Data("disposable existing project".utf8)
        try original.write(to:dest,options:.withoutOverwriting)
        defer { try? FileManager.default.removeItem(at:dest) }
        XCTAssertThrowsError(try ProjectFile.encode(t,projectID:UUID(),settings:.m1,bookmarks:[:],projectURL:dest).write(to:dest))
        XCTAssertEqual(try Data(contentsOf:dest),original)
    }
    func testRegistrationDetectsChangedGeneratedSource() async throws {
        let source=try await ImageModelFixture.image()
        try Data([0]).write(to:source.url)
        XCTAssertThrowsError(try Timeline().registeringImage(source)) { XCTAssertEqual($0 as? StillImageProbeError,.changed) }
    }
    func testNormalSaveAndPlannerRejectUsedUnusedHiddenImages() async throws {
        let (base,id)=try await base()
        for t in [base, try base.inserting(media:id), try base.inserting(media:id).excludingMedia([id])] {
            XCTAssertThrowsError(try ProjectFile.encode(t,projectID:UUID(),settings:.m1,bookmarks:[:],projectURL:nil)) { XCTAssertTrue($0 is ProductionContent.Unsupported) }
            do { _ = try await CompositionPlanner.plan(t,media:[:]); XCTFail("admitted") }
            catch { XCTAssertTrue(error is ProductionContent.Unsupported) }
            XCTAssertThrowsError(try CompositionPlanner.layeredSegments(t,media:[:],render:CGSize(width:1920,height:1080))) { XCTAssertTrue($0 is ProductionContent.Unsupported) }
            XCTAssertThrowsError(try CompositionPlanner.layerStack(t,lanes:[],from:500,to:501,media:[:],render:CGSize(width:1920,height:1080))) { XCTAssertTrue($0 is ProductionContent.Unsupported) }
        }
    }
}
