import XCTest
@testable import OnTheFrameEngine

final class OperationalProjectAdapterTests: XCTestCase {
    typealias A = OperationalProjectAdapter
    typealias M = StillImageProjectModel
    func temporalState() throws -> A.State {
        let ref = ImageModelFixture.temporal()
        let t = Timeline(media:[ref],mediaFrames:[ref.id:ref.frameCount],mediaHasAudio:[ref.id:ref.hasAudio])
        return try A.State(timeline:t,projectID:UUID(),locations:[ref.id:.init(relativePath:"../old/video.mov",bookmark:Data([1,2,3]))])
    }
    func mixed() async throws -> A.State {
        let video=ImageModelFixture.temporal(), audio=ImageModelFixture.temporal(video:false)
        var t=Timeline(media:[video,audio],mediaFrames:[video.id:300,audio.id:300],mediaHasAudio:[video.id:true,audio.id:true])
        let image=UUID(), unused=UUID(), upper=UUID(), audioLane=UUID(), subLane=UUID(), specLane=UUID()
        t=try t.registeringImage(await ImageModelFixture.image(),id:image)
            .registeringImage(await ImageModelFixture.image("jpg"),id:unused)
            .addingLane(.video,name:"upper",id:upper,outward:true)
            .addingLane(.audio,name:"audio",id:audioLane,outward:true)
        t=try t.placingImage(media:image,at:0,lane:upper)
        let original=t.clips[0].id
        t=try t.splitting(clip:original,atFrame:50)
        t=try t.trimmingEnd(clip:t.clips[1].id,by:-10)
        let first=t.clips[0].id
        t=try t.settingTransform(clip:first,.init(scaleMicro:500000,offsetXMilli:1200,offsetYMilli:-400))
        t=try t.pasting(t.copying(clip:first),at:200,newLaneName:{_ in "copy"}).timeline
        t=try t.placing(media:video.id,at:400,videoLane:Lane.videoID,audioLane:Lane.audioID)
        t=try t.placing(media:audio.id,at:0,videoLane:nil,audioLane:audioLane)
        let audioClip=t.audioClips.first{$0.mediaID == audio.id}!.id
        t=try t.settingClipAudio(clip:audioClip,volumePercent:50,fadeInFrames:10)
        t=try t.splitting(clip:audioClip,atFrame:30)
        t=try t.addingLane(.subtitle,name:"sub",id:subLane).addingLane(.spectrum,name:"spectrum",id:specLane)
        var style=SubtitleStyle.default;style.outline = .default;style.shadow = .default;style.background = .default
        t=try t.addingSubtitle(lane:subLane,at:10,length:50,text:"adapter",style:style)
        t=try t.addingSpectrum(lane:specLane,at:0,length:200,sourceKey:audioClip)
        let locations=Dictionary(uniqueKeysWithValues:t.mediaCatalog.map {($0.id,A.Location(relativePath:"../sources/"+$0.id.uuidString,bookmark:Data([3,2,1])))})
        return try A.State(timeline:t,projectID:UUID(),locations:locations)
    }
    func invalid(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) { XCTAssertTrue($0 is A.Failure,file:file,line:line) }
    }
    func testImageFreeStoredRelativeHintRoundTrip() throws {
        let before=try temporalState(),after=try A.decode(A.encode(before))
        XCTAssertEqual(after.locations,before.locations)
    }
    func testMixedRoundTripPreservesEveryPortableField() async throws {
        let before=try await mixed(), model=try A.model(before), data=try A.encode(before)
        let after=try A.decode(data), round=try A.model(after)
        XCTAssertEqual(model,round)
        XCTAssertEqual(before.projectID,after.projectID);XCTAssertEqual(before.settings,after.settings)
        XCTAssertEqual(before.timeline.clips,after.timeline.clips);XCTAssertEqual(before.timeline.audioClips,after.timeline.audioClips)
        XCTAssertEqual(before.timeline.subtitles,after.timeline.subtitles);XCTAssertEqual(before.timeline.spectra,after.timeline.spectra)
        XCTAssertEqual(before.timeline.lanes,after.timeline.lanes);XCTAssertEqual(before.timeline.durationFrames,after.timeline.durationFrames)
        XCTAssertEqual(before.timeline.mediaCatalog.map(\.id),after.timeline.mediaCatalog.map(\.id))
        XCTAssertEqual(before.locations,after.locations)
        XCTAssertTrue(after.timeline.isValid)
        for r in after.timeline.mediaCatalog where r.kind == .stillImage {
            XCTAssertNil(r.sourceFrames);XCTAssertNil(r.still?.descriptor)
            XCTAssertEqual(r.still?.validationState,.unverified)
        }
        XCTAssertThrowsError(try ProjectFile.decode(data)) {XCTAssertEqual($0 as? ProjectFile.LoadError,.newerVersion(9))}
        XCTAssertThrowsError(try ProjectFile.encode(after.timeline,projectID:after.projectID,settings:.m1,bookmarks:[:],projectURL:nil)) {XCTAssertTrue($0 is ProductionContent.Unsupported)}
        XCTAssertThrowsError(try CompositionPlanner.layerStack(after.timeline,lanes:[],from:0,to:1,media:[:],render:CGSize(width:1920,height:1080))) {XCTAssertTrue($0 is ProductionContent.Unsupported)}
    }
    func testMissingUsedAndUnusedReferencesRemainValidButUnverified() async throws {
        var p=try A.model(await mixed())
        for i in p.media.indices {
            if let r=p.media[i].ref.still {
                let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("absent.png").path
                XCTAssertFalse(FileManager.default.fileExists(atPath:path))
                p.media[i].ref = .stillImage(.init(id:r.id,name:"retained custom name",path:path,size:r.size,modifiedNs:r.modifiedNs,image:r.image))
            }
        }
        let encoded=try StillImageProjectCodec.encode(p),state=try A.decode(encoded)
        XCTAssertEqual(try A.model(state),p)
        XCTAssertEqual(state.timeline.stillImageIDs.count,2)
        XCTAssertTrue(state.timeline.mediaCatalog.compactMap(\.still).allSatisfy{$0.validationState == .unverified && $0.descriptor == nil})
        let id=state.timeline.stillImageIDs.first!
        do {_ = try await A.revalidate(state,mediaID:id);XCTFail("missing source validated")}
        catch {XCTAssertEqual(error as? A.Failure,.sourceUnavailable(id))}
        XCTAssertEqual(try A.model(state),p)
    }
    func testAtomicInvalidModelsAndReferences() async throws {
        let state=try await mixed(), p=try A.model(state), before=state
        var cases:[M.Project]=[]
        var bad=p;bad.media.append(p.media[0]);cases.append(bad)
        bad=p;bad.videoClips.append(p.videoClips[0]);cases.append(bad)
        bad=p;bad.media.removeAll{$0.ref.id == p.videoClips[0].mediaID};cases.append(bad)
        bad=p;bad.videoClips[0]=bad.videoClips[0].with(sourceIn:1);cases.append(bad)
        bad=p;bad.videoClips[0]=bad.videoClips[0].with(start:Int.max,length:1);cases.append(bad)
        bad=p;bad.lanes.append(p.lanes[0]);cases.append(bad)
        bad=p;bad.audioClips.append(p.videoClips[0].with(id:UUID(),lane:.some(Lane.audioID)));cases.append(bad)
        bad=p;bad.videoClips.append(p.videoClips[0].with(id:UUID()));cases.append(bad)
        bad=p;bad.settings.fps=60;cases.append(bad)
        bad=p;bad.spectra=[bad.spectra![0].with(sourceKey:.some(p.media.first{$0.ref.kind == .stillImage}!.ref.id))];cases.append(bad)
        for candidate in cases {invalid {_ = try A.restore(candidate)};XCTAssertEqual(state,before)}
        let unknown=UUID()
        invalid {_ = try A.State(timeline:state.timeline,projectID:state.projectID,locations:[unknown:.init(bookmark:Data([1]))])}
        let orphan=Timeline(mediaFrames:[UUID():100])
        invalid {_ = try A.State(timeline:orphan,projectID:UUID())}
    }
    func testInvalidDescriptorAndCorruptEncodedContentRejectAtomically() async throws {
        let state=try await mixed(), data=try A.encode(state)
        let original=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        for variant in ["orientation","kind","frameCount","dangling","unknown"] {
            var raw=original, media=raw["media"] as! [[String:Any]]
            let i=media.firstIndex{($0["ref"] as? [String:Any])?["kind"] as? String == "stillImage"}!
            var ref=media[i]["ref"] as! [String:Any]
            if variant == "orientation" {var info=ref["image"] as! [String:Any];info["orientation"]=9;ref["image"]=info}
            if variant == "kind" {ref["kind"]="unknown"}
            if variant == "frameCount" {ref["frameCount"]=150}
            if variant == "dangling" {ref["id"]=UUID().uuidString}
            if variant == "unknown" {raw["unsupportedField"]=true}
            media[i]["ref"]=ref;raw["media"]=media
            invalid {_ = try A.decode(JSONSerialization.data(withJSONObject:raw))}
        }
        invalid {_ = try A.decode(Data("corrupt".utf8))}
        XCTAssertEqual(try A.model(state),try A.model(A.decode(data)))
    }
    func testSaveAsAndBookmarkSemantics() async throws {
        let state=try await mixed(), dest=URL(fileURLWithPath:"/generated/projects/save-as.ontheframe")
        let after=try A.decode(A.encode(state,projectURL:dest))
        for r in state.timeline.mediaCatalog {
            let path=r.temporal?.path ?? r.still!.reference.path
            XCTAssertEqual(after.locations[r.id]?.bookmark,state.locations[r.id]?.bookmark)
            XCTAssertEqual(after.locations[r.id]?.relativePath,ProjectFile.relative(URL(fileURLWithPath:path),from:dest.deletingLastPathComponent()))
        }
        XCTAssertEqual(after.timeline.clips,state.timeline.clips)
    }
    func testRevalidationAndCrossFormatRelinkPreserveClipIdentity() async throws {
        let source=try await ImageModelFixture.image(),id=UUID()
        let t=try Timeline().registeringImage(source,id:id).inserting(media:id)
        let state=try A.State(timeline:t,projectID:UUID(),locations:[id:.init(relativePath:"old",bookmark:Data([7]))])
        let restored=try A.decode(A.encode(state)),validated=try await A.revalidate(restored,mediaID:id)
        XCTAssertEqual(validated.timeline.mediaCatalog.first?.still?.validationState,.probeValidated)
        XCTAssertEqual(validated.timeline.mediaCatalog.first?.still?.descriptor?.identity,source.descriptor.identity)
        let replacement=try await ImageModelFixture.image("jpg",width:4,height:5,orientation:6)
        let (linked,change)=try A.relink(restored,mediaID:id,to:replacement)
        XCTAssertTrue(change.requiresNotification);XCTAssertEqual(change.before,M.ImageInfo(source.descriptor))
        XCTAssertEqual(change.after,M.ImageInfo(replacement.descriptor))
        XCTAssertEqual(linked.timeline.clips,state.timeline.clips)
        XCTAssertEqual(linked.timeline.mediaCatalog.first?.id,id)
        XCTAssertEqual(linked.timeline.mediaCatalog.first?.still?.reference.image.encoding,.jpeg)
        XCTAssertEqual(linked.locations[id],A.Location())
        XCTAssertEqual(linked.timeline.mediaCatalog.first?.still?.validationState,.probeValidated)
        let png=try await ImageModelFixture.image()
        let (back,_)=try A.relink(linked,mediaID:id,to:png)
        XCTAssertEqual(back.timeline.clips,state.timeline.clips)
        XCTAssertEqual(back.timeline.mediaCatalog.first?.still?.reference.image.encoding,.png)
        invalid {_ = try A.restore(A.model(state),validatedImages:[UUID():source])}
        invalid {_ = try A.restore(A.model(state),validatedImages:[id:replacement])}
    }
    func testLegacyHeaderCannotReinterpretDeclaredImagesAsVideo() async throws {
        let state=try await mixed()
        var raw=try JSONSerialization.jsonObject(with:A.encode(state)) as! [String:Any]
        raw["version"]=8
        var entries=raw["media"] as! [[String:Any]]
        for i in entries.indices {
            var ref=entries[i]["ref"] as! [String:Any]
            if ref["kind"] as? String == "stillImage" {
                ref["frameCount"]=150;ref["hasAudio"]=false;ref["hasVideo"]=true
                ref["codec"]="png";ref["width"]=2;ref["height"]=3
            } else {ref.removeValue(forKey:"kind")}
            entries[i]["ref"]=ref
        }
        raw["media"]=entries
        invalid {_ = try A.decode(JSONSerialization.data(withJSONObject:raw))}
    }
    func testLegacyOneThroughEightAndConditionalWriter() throws {
        let initial=try temporalState(), model=try A.model(initial)
        for version in 1...8 {
            var raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(model.temporalDocument())) as! [String:Any]
            raw["version"]=version
            raw["durationFrames"]=60
            raw["videoClips"]=[["id":UUID().uuidString,"mediaID":model.media[0].ref.id.uuidString,"start":0,"sourceIn":3,"length":20]]
            if version == 1 { raw["lanes"] = (raw["lanes"] as! [[String:Any]]).reversed().map{$0} }
            if version == 3 {
                var clips=raw["videoClips"] as! [[String:Any]]
                clips[0]["transform"]=["scalePermille":500,"offsetX":10,"offsetY":20];raw["videoClips"]=clips
            }
            let data=try JSONSerialization.data(withJSONObject:raw),expected=try ProjectFile.decode(data)
            let restored=try A.decode(data)
            XCTAssertEqual(restored.timeline,expected.timeline)
            XCTAssertEqual(restored.projectID,expected.document.projectID)
            XCTAssertEqual(restored.locations[model.media[0].ref.id]?.bookmark,Data([1,2,3]))
        }
        for version in 5...8 {
            var p=model
            p.durationFrames=300
            if version>=6 {p.lanes.insert(Lane(id:UUID(),kind:.subtitle,name:"sub"),at:0)}
            if version==7 {var style=SubtitleStyle.default;style.outline = .default;p.subtitles=[SubtitleItem(lane:p.lanes[0].id,start:0,length:10,text:"effect",style:style)]}
            if version==8 {p.lanes.insert(Lane(id:UUID(),kind:.spectrum,name:"spectrum"),at:1)}
            let state=try A.restore(p),data=try A.encode(state)
            XCTAssertEqual(try ProjectFile.decode(data).document.version,version)
            XCTAssertEqual(try A.model(A.decode(data)),try A.model(state))
        }
    }
}
