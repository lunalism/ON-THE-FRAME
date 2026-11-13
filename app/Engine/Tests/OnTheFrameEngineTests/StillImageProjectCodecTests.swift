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
        XCTAssertThrowsError(try ProjectFile.decode(encoded)) {XCTAssertEqual($0 as? ProjectFile.LoadError,.unsupportedVersion(9))}
        XCTAssertEqual(ProjectFile.currentVersion,10)
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

extension StillImageProjectCodecTests {
    func reactionProject(image: Bool = false) async throws -> M.Project {
        var p = ImageModelFixture.base()
        if image { p = try await ImageModelFixture.project(ImageModelFixture.image()) }
        let audio = ImageModelFixture.temporal(video: false), origin = UUID(), lane = UUID()
        p.media.append(.init(ref: .audio(audio), relativePath: "selected.wav", bookmark: Data([2, 4, 6])))
        p.audioClips = [Clip(mediaID: audio.id, start: 0, sourceIn: 3, length: 50, lane: Lane.audioID, origin: origin),
                        Clip(mediaID: audio.id, start: 50, sourceIn: 53, length: 50, lane: Lane.audioID, origin: origin)]
        p.lanes.insert(Lane(id: lane, kind: .spectrum, name: "SP"), at: 0)
        var style = SpectrumItemStyle.provisionalDefault
        style.thicknessMilli = 3125; style.startXMilli = 320123; style.alpha = 192
        p.spectra = [SpectrumItem(lane: lane, start: 0, length: 100, sourceKey: origin, style: style)]
        try p.validate()
        return p
    }
    func changingReaction(_ raw: [String:Any], _ value: Any?) -> [String:Any] {
        var raw = raw, spectra = raw["spectra"] as! [[String:Any]], style = spectra[0]["style"] as! [String:Any]
        style["reactionPercent"] = value; spectra[0]["style"] = style; raw["spectra"] = spectra
        return raw
    }
    func testReactionFormat10ValuesAndMixedRoundTrip() async throws {
        for image in [false, true] {
            let baseline = try await reactionProject(image: image)
            for value in [0, 1, 99, 100, 101, 199, 200] {
                var p = baseline
                var updatedStyle = p.spectra![0].style; updatedStyle.reactionPercent = value
                p.spectra![0] = p.spectra![0].with(style: updatedStyle)
                let encoded = try C.encode(p), raw = try json(p)
                XCTAssertEqual(raw["version"] as? Int, 10)
                let style = ((raw["spectra"] as! [[String:Any]])[0]["style"] as! [String:Any])
                XCTAssertEqual(style["reactionPercent"] as? Int, value)
                let back = try C.decode(encoded)
                XCTAssertEqual(back, p)
                XCTAssertEqual(try C.encode(back), encoded)
                XCTAssertEqual(back.spectra![0].style.thicknessMilli, 3125)
                XCTAssertEqual(back.spectra![0].style.startXMilli, 320123)
                XCTAssertEqual(back.spectra![0].style.alpha, 192)
                let state = try OperationalProjectAdapter.restore(back)
                let portable = try OperationalProjectAdapter.decode(OperationalProjectAdapter.encode(state))
                XCTAssertEqual(portable, state)
                let project = try ProjectPersistence.decode(encoded)
                XCTAssertEqual(project.version, 10)
                XCTAssertEqual(project.timeline.spectra[0].style.reactionPercent, value)
                let destination = URL(fileURLWithPath: "/generated/reaction.ontheframe")
                let saved = try ProjectPersistence.encode(project, at: destination)
                XCTAssertEqual(try ProjectPersistence.decode(saved).timeline, project.timeline)
                let projection = try ProjectFile.decode(JSONEncoder().encode(p.temporalDocument()))
                XCTAssertEqual(projection.document.version, 10)
                XCTAssertEqual(projection.timeline.spectra, p.spectra!)
                if !image { XCTAssertEqual(try ProjectFile.decode(encoded).timeline.spectra, p.spectra!) }
            }
        }
    }
    func testReactionLegacyDefaultWithoutSourceRewrite() async throws {
        for image in [false, true] {
            let p = try await reactionProject(image: image)
            var raw = changingReaction(try json(p), nil)
            raw["version"] = image ? 9 : 8
            let legacy = try data(raw), original = legacy
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reaction-legacy-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("legacy.ontheframe")
            try legacy.write(to: url, options: .withoutOverwriting)
            let decoded = try ProjectPersistence.decode(Data(contentsOf: url))
            XCTAssertEqual(decoded.timeline.spectra[0].style.reactionPercent, 100)
            XCTAssertEqual(decoded.timeline.spectra[0], p.spectra![0])
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(try C.decode(legacy), p)
            let upgraded = try ProjectPersistence.encode(decoded, at: url)
            XCTAssertEqual(try ProjectPersistence.decode(upgraded).version, 10)
            XCTAssertEqual(try Data(contentsOf: url), original) // encoding is not saving
            XCTAssertThrowsError(try C.decode(data(changingReaction(raw, 100))))
        }
    }
    func testReactionStrictWireValuesAndUnknownFields() async throws {
        for image in [false, true] {
            let p = try await reactionProject(image: image), raw = try json(p)
            let invalidValues: [Any?] = [nil, NSNull(), "100", -1, 201, 3.5, true]
            for value in invalidValues {
                let malformed = try data(changingReaction(raw, value))
                XCTAssertThrowsError(try C.decode(malformed))
                XCTAssertThrowsError(try ProjectPersistence.decode(malformed))
                if !image { XCTAssertThrowsError(try ProjectFile.decode(malformed)) }
            }
            let text = String(decoding: try C.encode(p), as: UTF8.self)
            for token in ["100.0", "1e2", "9999999999999999999999999999999"] {
                let bad = text.replacingOccurrences(of: "\"reactionPercent\" : 100", with: "\"reactionPercent\" : " + token)
                XCTAssertNotEqual(bad, text)
                XCTAssertThrowsError(try C.decode(Data(bad.utf8)))
            }
            for key in ["futureReaction", "reactionMultiplier"] {
                var changed = raw, spectra = changed["spectra"] as! [[String:Any]], style = spectra[0]["style"] as! [String:Any]
                style[key] = 1; spectra[0]["style"] = style; changed["spectra"] = spectra
                XCTAssertThrowsError(try C.decode(data(changed)))
            }
            var unknown = raw; unknown["futureCapability"] = true
            XCTAssertThrowsError(try C.decode(data(unknown)))
            for version in [11, 12, Int.max] {
                var future = raw; future["version"] = version
                XCTAssertThrowsError(try ProjectPersistence.decode(data(future)))
                XCTAssertThrowsError(try C.decode(data(future)))
            }
        }
    }
    func testReactionModelHistoryAndNoOp() async throws {
        let p = try await reactionProject(), t = try OperationalProjectAdapter.restore(p).timeline
        let item = t.spectra[0]
        var history = EditHistory(t), style = item.style
        for value in [-1, 201] {
            style.reactionPercent = value
            XCTAssertFalse(style.isValid)
            XCTAssertThrowsError(try t.settingSpectrumStyle(item.id, style))
        }
        style = item.style; style.reactionPercent = 199
        let changed = try t.settingSpectrumStyle(item.id, style)
        history.apply(changed, focus: item.id)
        history.undo(); XCTAssertEqual(history.timeline, t)
        history.redo(); XCTAssertEqual(history.timeline, changed)
        XCTAssertEqual(changed.audioClips, t.audioClips)
        XCTAssertEqual(changed.spectra[0].sourceKey, item.sourceKey)
        XCTAssertEqual(try t.settingSpectrumStyle(item.id, item.style), t)
        let without = try changed.liftingSpectrum(item.id)
        XCTAssertEqual(ProjectFile.version(for: without), 8) // empty lane + lineage
    }
    func testReactionOldBoundaryAndFailedSaveProtection() async throws {
        // Exact pre-change ProjectPersistence header/version guard (baseline 8c4e12f).
        // Only this boundary is frozen; no claim of launching the older application.
        struct OldHeader: Decodable { let format: String; let version: Int }
        func oldBoundary(_ bytes: Data) throws {
            let header = try JSONDecoder().decode(OldHeader.self, from: bytes)
            if header.format == ProjectFile.format, header.version > 9 {
                throw ProjectPersistence.Failure.futureVersion(header.version)
            }
            XCTFail("format 10 reached the old edit/save boundary")
        }
        let p = try await reactionProject(), encoded = try C.encode(p)
        XCTAssertThrowsError(try oldBoundary(encoded))
        var invalid = try OperationalProjectAdapter.restore(p).timeline
        var entries = invalid.spectra, badStyle = entries[0].style; badStyle.reactionPercent = 201
        entries[0] = entries[0].with(style: badStyle)
        invalid = invalid.rebuilt(spectra: entries)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reaction-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent("existing.ontheframe"), original = Data("preserve".utf8)
        try original.write(to: destination, options: .withoutOverwriting)
        XCTAssertThrowsError(try ProjectPersistence.make(timeline: invalid, projectID: p.projectID))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }
}
