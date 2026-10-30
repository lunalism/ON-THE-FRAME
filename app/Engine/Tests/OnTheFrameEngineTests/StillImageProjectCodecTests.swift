import XCTest
@testable import OnTheFrameEngine

final class StillImageProjectCodecTests: XCTestCase {
    typealias M = StillImageProjectModel
    typealias C = StillImageProjectCodec
    func json(_ p: M.Project) throws -> [String:Any] {try JSONSerialization.jsonObject(with:C.encode(p)) as! [String:Any]}
    func data(_ value:[String:Any]) throws -> Data {try JSONSerialization.data(withJSONObject:value)}
    func testUsedUnusedImagesAndProductionBoundary() async throws {
        let p=try ImageModelFixture.project(await ImageModelFixture.image())
        XCTAssertEqual(try C.version(for:p),9)
        let encoded=try C.encode(p),decoded=try C.decode(encoded)
        XCTAssertEqual(decoded,p);XCTAssertEqual(try C.encode(decoded),encoded)
        XCTAssertThrowsError(try ProjectFile.decode(encoded)) {XCTAssertEqual($0 as? ProjectFile.LoadError,.newerVersion(9))}
        XCTAssertEqual(ProjectFile.currentVersion,8)
        var unused=p;unused.videoClips=[];XCTAssertEqual(try C.version(for:unused),9)
        XCTAssertEqual(try C.decode(C.encode(unused)),unused)
        let raw=try json(p),ref=(raw["media"] as! [[String:Any]])[0]["ref"] as! [String:Any]
        XCTAssertEqual(ref["kind"] as? String,"stillImage")
        for key in ["frameCount","duration","timing","sampleRate","sampleCount","channels","hasAudio","hasVideo"] {XCTAssertNil(ref[key])}
        let text=String(decoding:encoded,as:UTF8.self)
        for key in ["inode","device","normalizedRGBABytes","texture","scope"] {XCTAssertFalse(text.contains("\""+key+"\""))}
    }
    func testImageFreeConditionalWriterMatchesExisting() throws {
        for version in 5...8 {
            var p=ImageModelFixture.base()
            if version>=6 {
                let lane=UUID();p.lanes.insert(.init(id:lane,kind:.subtitle,name:"S"),at:0)
                var style=SubtitleStyle.default;if version>=7 {style.outline = .default}
                p.subtitles=[SubtitleItem(lane:lane,start:0,length:10,text:"test",style:style)]
            }
            if version==8 {p.lanes.insert(.init(id:UUID(),kind:.spectrum,name:"SP"),at:1)}
            XCTAssertEqual(try C.version(for:p),version)
            let encoded=try C.encode(p),decoded=try ProjectFile.decode(encoded)
            XCTAssertEqual(decoded.document.version,version)
            XCTAssertEqual(encoded,try ProjectFile.encode(decoded.timeline,projectID:p.projectID,settings:.m1,bookmarks:[:],projectURL:nil))
            XCTAssertEqual(try C.decode(encoded),M.Project(decoded.document))
        }
    }
    func testLegacyOneThroughEightMeaningAndTransforms() throws {
        for version in 1...8 {
            var p=ImageModelFixture.base();let ref=ImageModelFixture.temporal()
            p.media=[.init(ref:.video(ref),relativePath:"../video.mov",bookmark:Data([1]))]
            p.videoClips=[Clip(mediaID:ref.id,start:0,sourceIn:3,length:20,lane:Lane.videoID)]
            var raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p.temporalDocument())) as! [String:Any]
            raw["version"]=version
            if version>=3 {
                var cs=raw["videoClips"] as! [[String:Any]]
                cs[0]["transform"]=version==3 ? ["scalePermille":500,"offsetX":10,"offsetY":20]:["scaleMicro":500000,"offsetXMilli":10000,"offsetYMilli":20000]
                raw["videoClips"]=cs
            }
            if version==1 {var ms=raw["media"] as! [[String:Any]],r=ms[0]["ref"] as! [String:Any];r.removeValue(forKey:"hasVideo");ms[0]["ref"]=r;raw["media"]=ms}
            let input=try data(raw),legacy=try ProjectFile.decode(input),isolated=try C.decode(input)
            XCTAssertEqual(isolated,M.Project(legacy.document))
            let back=try C.decode(C.encode(isolated))
            XCTAssertEqual(back.videoClips,isolated.videoClips);XCTAssertEqual(back.projectID,isolated.projectID)
            XCTAssertEqual(back.media.map { $0.ref },isolated.media.map { $0.ref })
        }
    }
    func testMixedProjectPreservesEffectsAudioLineageAndSpectrum() async throws {
        var p=try ImageModelFixture.project(await ImageModelFixture.image())
        let video=ImageModelFixture.temporal(),audio=ImageModelFixture.temporal(video:false),origin=UUID()
        p.media += [.init(ref:.video(video),relativePath:nil,bookmark:nil),.init(ref:.audio(audio),relativePath:nil,bookmark:nil)]
        p.videoClips.append(Clip(mediaID:video.id,start:150,sourceIn:5,length:40,lane:Lane.videoID,transform:ClipTransform(scaleMicro:500000,offsetXMilli:1200,offsetYMilli:0)))
        p.audioClips=[Clip(mediaID:audio.id,start:10,sourceIn:3,length:100,lane:Lane.audioID,audio:ClipAudio(volumePercent:50,fadeIn:.init(length:5)),origin:origin)]
        let sub=UUID(),spec=UUID();p.lanes.insert(contentsOf:[Lane(id:sub,kind:.subtitle,name:"S"),Lane(id:spec,kind:.spectrum,name:"SP")],at:0)
        var style=SubtitleStyle.default;style.outline = .default;style.shadow = .default;style.background = .default
        p.subtitles=[SubtitleItem(lane:sub,start:1,length:30,text:"preserve",style:style)]
        p.spectra=[SpectrumItem(lane:spec,start:0,length:200,sourceKey:origin)]
        XCTAssertEqual(try C.decode(C.encode(p)),p)
        var coincident=p
        coincident.audioClips=[p.audioClips[0].with(origin:.some(p.media[0].ref.id))]
        coincident.spectra=[SpectrumItem(lane:spec,start:0,length:200,sourceKey:p.media[0].ref.id)]
        XCTAssertEqual(try C.decode(C.encode(coincident)),coincident) // Audio lineage, not the coincident image UUID.
        var overlap=p;overlap.videoClips[1]=overlap.videoClips[1].with(start:140)
        XCTAssertThrowsError(try C.encode(overlap))
        var raw=try json(p),subs=raw["subtitles"] as! [[String:Any]],rawStyle=subs[0]["style"] as! [String:Any]
        rawStyle["futureEffect"]=["enabled":true];subs[0]["style"]=rawStyle;raw["subtitles"]=subs
        XCTAssertThrowsError(try C.decode(data(raw)))
    }
    func testMalformedKindPayloadAndForbiddenTemporalFields() async throws {
        let p=try ImageModelFixture.project(await ImageModelFixture.image()),original=try json(p)
        func rejectRef(_ edit:(inout [String:Any])->Void) throws {
            var raw=original,media=raw["media"] as! [[String:Any]],ref=media[0]["ref"] as! [String:Any]
            edit(&ref);media[0]["ref"]=ref;raw["media"]=media
            XCTAssertThrowsError(try C.decode(data(raw)))
        }
        try rejectRef {$0["kind"]="unknown"};try rejectRef {$0.removeValue(forKey:"kind")};try rejectRef {$0.removeValue(forKey:"image")}
        for key in ["frameCount","duration","timing","sampleRate","sampleCount","channels","hasAudio","hasVideo"] {try rejectRef {$0[key]=0}}
        for key in ["frameCount","duration","timing","sampleCount","identity","cache"] {
            try rejectRef {r in var info=r["image"] as! [String:Any];info[key]=0;r["image"]=info}
        }
        for (key,value) in [("width",0),("height",Int.max),("orientation",9),("contractVersion",2)] {
            try rejectRef {r in var info=r["image"] as! [String:Any];info[key]=value;r["image"]=info}
        }
        try rejectRef {$0["kind"]="video"}
        XCTAssertEqual(try C.decode(data(original)),p) // Failures never mutate the caller's project.
    }
    func testMalformedClipsIDsLanesAndUnknownEffects() async throws {
        let p=try ImageModelFixture.project(await ImageModelFixture.image()),original=try json(p)
        func rejectClip(_ edit:(inout [String:Any])->Void) throws {
            var raw=original,clips=raw["videoClips"] as! [[String:Any]];edit(&clips[0]);raw["videoClips"]=clips
            XCTAssertThrowsError(try C.decode(data(raw)))
        }
        for (key,value) in [("sourceIn",1),("length",0),("length",-1),("start",Int.max),("length",Int.max)] {try rejectClip {$0[key]=value}}
        try rejectClip {$0.removeValue(forKey:"length")}
        try rejectClip {$0["mediaID"]=UUID().uuidString};try rejectClip {$0["lane"]=Lane.audioID.uuidString}
        try rejectClip {$0["mediaID"]=(p.media[0].ref.id.uuidString.lowercased());$0["origin"]=$0["id"]} // Reject even the value Clip would normalize away.
        try rejectClip {$0["link"]=UUID().uuidString}
        try rejectClip {$0["audio"]=["volumePercent":100,"muted":false,"fadeIn":["length":0,"offset":0],"fadeOut":["length":0,"offset":0]]}
        try rejectClip {$0["futureEffect"]=["enabled":true]}
        var raw=original;raw["videoClips"]=(raw["videoClips"] as! [[String:Any]])+(raw["videoClips"] as! [[String:Any]])
        XCTAssertThrowsError(try C.decode(data(raw)))
        raw=original;raw["media"]=(raw["media"] as! [[String:Any]])+(raw["media"] as! [[String:Any]])
        XCTAssertThrowsError(try C.decode(data(raw)))
        XCTAssertEqual(try C.decode(data(original)),p)
    }
    func testMissingMediaAndSaveAsRelativePaths() async throws {
        var p=try ImageModelFixture.project(await ImageModelFixture.image())
        let old=p.media[0].ref.still!
        p.media[0].ref = .stillImage(.init(id:old.id,name:old.name,path:"/generated/media/photo.png",size:old.size,modifiedNs:old.modifiedNs,image:old.image))
        p.media[0].relativePath="../old/photo.png"
        XCTAssertEqual(try C.decode(C.encode(p)),p) // No filesystem probe during project decode.
        let url=URL(fileURLWithPath:"/generated/projects/new.ontheframe")
        let back=try C.decode(C.encode(p,projectURL:url))
        XCTAssertEqual(back.media[0].relativePath,"../media/photo.png")
        XCTAssertEqual(back.media[0].bookmark,p.media[0].bookmark);XCTAssertEqual(back.videoClips,p.videoClips)
    }
}
