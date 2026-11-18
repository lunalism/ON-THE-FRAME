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
        XCTAssertEqual(ProjectFile.currentVersion,11)
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
    func changingAppearance(_ raw: [String:Any], _ value: Any?) -> [String:Any] {
        var raw = raw, spectra = raw["spectra"] as! [[String:Any]], style = spectra[0]["style"] as! [String:Any]
        style["appearance"] = value; spectra[0]["style"] = style; raw["spectra"] = spectra
        return raw
    }
    func testReactionValuesSurviveAppearanceFormat11MixedRoundTrip() async throws {
        for image in [false, true] {
            let baseline = try await reactionProject(image: image)
            for value in [0, 1, 99, 100, 101, 199, 200] {
                var p = baseline
                var updatedStyle = p.spectra![0].style; updatedStyle.reactionPercent = value
                p.spectra![0] = p.spectra![0].with(style: updatedStyle)
                let encoded = try C.encode(p), raw = try json(p)
                XCTAssertEqual(raw["version"] as? Int, 11)
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
                XCTAssertEqual(project.version, 11)
                XCTAssertEqual(project.timeline.spectra[0].style.reactionPercent, value)
                let destination = URL(fileURLWithPath: "/generated/reaction.ontheframe")
                let saved = try ProjectPersistence.encode(project, at: destination)
                XCTAssertEqual(try ProjectPersistence.decode(saved).timeline, project.timeline)
                let projection = try ProjectFile.decode(JSONEncoder().encode(p.temporalDocument()))
                XCTAssertEqual(projection.document.version, 11)
                XCTAssertEqual(projection.timeline.spectra, p.spectra!)
                if !image { XCTAssertEqual(try ProjectFile.decode(encoded).timeline.spectra, p.spectra!) }
            }
        }
    }
    func testReactionLegacyDefaultWithoutSourceRewrite() async throws {
        for image in [false, true] {
            let p = try await reactionProject(image: image)
            var raw = changingReaction(try json(p), nil)
            raw = changingAppearance(raw, nil)
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
            XCTAssertEqual(try ProjectPersistence.decode(upgraded).version, 11)
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
            for version in [12, 13, Int.max] {
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

extension StillImageProjectCodecTests {
    func testAppearanceFormat11RoundTripAndLegacyFormat10Migration() async throws {
        for image in [false, true] {
            var p = try await reactionProject(image: image)
            var style = p.spectra![0].style
            style.red = 12; style.green = 34; style.blue = 56; style.alpha = 173
            style.reactionPercent = 150; style.windowMs = 300; style.offsetMs = -500
            style.outsideRGB = .init(red: 17, green: 31, blue: 47)
            p.spectra![0] = p.spectra![0].with(style: style)
            let encoded = try C.encode(p), raw = try json(p)
            XCTAssertEqual(raw["version"] as? Int, 11)
            let round = try C.decode(encoded)
            XCTAssertEqual(round, p)
            XCTAssertEqual(try C.encode(round), encoded)
            let state = try OperationalProjectAdapter.decode(encoded)
            XCTAssertEqual(state.timeline.spectra[0].style, style)
            XCTAssertEqual(state.locations, try OperationalProjectAdapter.restore(p).locations)
            var legacy = changingAppearance(raw, nil); legacy["version"] = 10
            let legacyBytes = try data(legacy)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-legacy-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("legacy.ontheframe")
            try legacyBytes.write(to: url, options: .withoutOverwriting)
            let old = try ProjectPersistence.decode(Data(contentsOf: url))
            let migrated = old.timeline.spectra[0].style
            XCTAssertEqual(old.version, 10)
            XCTAssertEqual(migrated.insideRGB, .init(red: 12, green: 34, blue: 56))
            XCTAssertEqual(migrated.resolvedOutsideRGB, migrated.insideRGB)
            XCTAssertEqual(migrated.alpha, 173)
            XCTAssertEqual(migrated.reactionPercent, 150, "Format 11 support must not reset existing Format 10 strength")
            XCTAssertEqual(migrated.windowMs, 300); XCTAssertEqual(migrated.offsetMs, -500)
            XCTAssertEqual(migrated.thicknessMilli, 3125); XCTAssertEqual(migrated.startXMilli, 320123)
            let upgraded = try ProjectPersistence.encode(old, at: url)
            XCTAssertEqual(try ProjectPersistence.decode(upgraded).version, 11)
            XCTAssertEqual(try ProjectPersistence.decode(upgraded).timeline, old.timeline)
            XCTAssertEqual(try Data(contentsOf: url), legacyBytes, "Opening/encoding does not rewrite the source project")
            if !image { XCTAssertEqual(try ProjectFile.decode(legacyBytes).timeline, old.timeline) }
        }
    }

    func testAppearanceV1RejectsMalformedAndUnsupportedNestedData() async throws {
        func color(_ red: Any, _ green: Any, _ blue: Any) -> [String:Any] { ["red": red, "green": green, "blue": blue] }
        func envelope(_ version: Any, _ outside: Any) -> [String:Any] { ["contractVersion": version, "outsideRGB": outside] }
        let rgb = color(17, 31, 47)
        var alpha = color(0, 0, 0); alpha["alpha"] = 255
        var hue = envelope(1, rgb); hue["hueSweepDegrees"] = 0
        var softness = envelope(1, rgb); softness["softnessPercent"] = 0
        var inside = envelope(1, rgb); inside["insideRGB"] = rgb
        let invalid: [Any?] = [
            nil, NSNull(), [Any](), "appearance",
            envelope(0, rgb), envelope(2, rgb), envelope(3, rgb), envelope(true, rgb),
            ["contractVersion": 1], ["outsideRGB": rgb],
            envelope(1, NSNull()), envelope(1, color(-1, 0, 0)), envelope(1, color(256, 0, 0)),
            envelope(1, color(0.5, 0, 0)), envelope(1, color(true, 0, 0)),
            envelope(1, alpha), hue, softness, inside
        ]
        for image in [false, true] {
            let project = try await reactionProject(image: image)
            let raw = try json(project)
            for appearance in invalid {
                let bytes = try data(changingAppearance(raw, appearance))
                XCTAssertThrowsError(try C.decode(bytes))
                XCTAssertThrowsError(try ProjectPersistence.decode(bytes))
                if !image { XCTAssertThrowsError(try ProjectFile.decode(bytes)) }
            }
        }
        var style = SpectrumItemStyle.provisionalDefault
        style.outsideRGB = .init(red: 17, green: 31, blue: 47)
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as! [String:Any]
        for appearance in invalid.dropFirst() {
            var raw = original; raw["appearance"] = appearance
            XCTAssertThrowsError(try JSONDecoder().decode(SpectrumItemStyle.self, from: data(raw)))
        }
    }

    func testAppearanceStrictIntegerTokensDuplicatesAndEscapedKeys() async throws {
        var p = try await reactionProject()
        var style = p.spectra![0].style; style.outsideRGB = .init(red: 17, green: 31, blue: 47)
        p.spectra![0] = p.spectra![0].with(style: style)
        let text = String(decoding: try C.encode(p), as: UTF8.self)
        for token in ["17.0", "1.7e1", "-0", "true", "\"17\"", "999999999999999999999999999999999"] {
            let changed = text.replacingOccurrences(of: "\"red\" : 17", with: "\"red\" : " + token)
            XCTAssertNotEqual(changed, text)
            XCTAssertThrowsError(try C.decode(Data(changed.utf8)))
        }
        for replacement in ["\"contractVersion\" : 1.0", "\"contractVersion\" : 1, \"contractVersion\" : 1"] {
            let changed = text.replacingOccurrences(of: "\"contractVersion\" : 1", with: replacement)
            XCTAssertNotEqual(changed, text)
            XCTAssertThrowsError(try C.decode(Data(changed.utf8)))
        }
        let duplicate = text.replacingOccurrences(of: "\"red\" : 17", with: "\"red\" : 17, \"red\" : 17")
        XCTAssertThrowsError(try C.decode(Data(duplicate.utf8)))
        let escaped = text.replacingOccurrences(of: "\"appearance\"", with: "\"\\u0061ppearance\"")
        XCTAssertEqual(try C.decode(Data(escaped.utf8)), p)
    }

    func testAppearanceCannotBeInjectedIntoLegacyPathsAndOldReadersReject11() async throws {
        let appearance: [String:Any] = ["contractVersion": 1, "outsideRGB": ["red": 17, "green": 31, "blue": 47]]
        for image in [false, true] {
            let p = try await reactionProject(image: image)
            for version in (image ? [9, 10] : [8, 10]) {
                var legacy = changingAppearance(try json(p), nil); legacy["version"] = version
                if version < 10 { legacy = changingReaction(legacy, nil) }
                XCTAssertNoThrow(try C.decode(data(legacy)), "A genuine legacy file still opens")
                let injected = try data(changingAppearance(legacy, appearance))
                XCTAssertThrowsError(try C.decode(injected))
                XCTAssertThrowsError(try ProjectPersistence.decode(injected))
                if !image { XCTAssertThrowsError(try ProjectFile.decode(injected)) }
            }
        }
        let empty = try ProjectFile.encode(Timeline(), projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        for version in 1...10 {
            var raw = try JSONSerialization.jsonObject(with: empty) as! [String:Any]
            raw["version"] = version; raw["appearance"] = appearance
            let bytes = try data(raw)
            XCTAssertThrowsError(try ProjectPersistence.decode(bytes))
            XCTAssertThrowsError(try C.decode(bytes))
            XCTAssertThrowsError(try ProjectFile.decode(bytes))
        }
        // Freeze only the previous reader's actual header admission boundary,
        // not an unexecuted old-app UI/save implementation.
        struct PreviousHeader: Decodable { let format: String; let version: Int }
        func previousBoundary(_ bytes: Data) throws {
            let header = try JSONDecoder().decode(PreviousHeader.self, from: bytes)
            if header.format == ProjectFile.format, header.version > 10 { throw ProjectPersistence.Failure.futureVersion(header.version) }
        }
        var p = try await reactionProject()
        XCTAssertThrowsError(try previousBoundary(C.encode(p)))
        p.spectra = nil
        XCTAssertEqual(try C.version(for: p), 8, "Empty Spectrum lane/lineage keeps its established format")
        let image = try await reactionProject(image: true)
        var without = image; without.spectra = nil
        XCTAssertEqual(try C.version(for: without), 9)
    }
}

extension StillImageProjectCodecTests {
    // Keep wire spellings (including duplicate keys and integer lexemes) intact.
    // The fixture is independent of the project encoder and needs no media access.
    private func spectrumJSON(version: Int, image: Bool, styleFields: [String]) -> String {
        let media = image ? """
            {"ref":{"kind":"stillImage","id":"00000000-0000-4000-8000-000000000006",
            "name":"테스트.png","path":"/generated/image.png","size":120,"modifiedNs":42,
            "image":{"contractVersion":1,"encoding":"png","width":2,"height":3,"orientation":1,
            "componentBitDepth":8,"encodedSampleBitDepth":8,"colorModel":"RGB",
            "profileDisposition":"assumed-sRGB","alphaCapability":false}}}
            """ : ""
        let extra = styleFields.map { "," + $0 }.joined()
        return """
            {"format":"dev.ontheframe.project","version":\(version),"projectID":"00000000-0000-4000-8000-000000000001",
            "settings":{"width":1920,"height":1080,"fps":30},"durationFrames":100,"lanes":[
            {"id":"00000000-0000-4000-8000-000000000002","kind":"spectrum","name":"색상 🎵"},
            {"id":"00000000-0000-4000-8000-000000000003","kind":"video","name":"V"},
            {"id":"00000000-0000-4000-8000-000000000004","kind":"audio","name":"A"}],
            "media":[\(media)],"videoClips":[],"audioClips":[],"spectra":[{
            "id":"00000000-0000-4000-8000-000000000005","lane":"00000000-0000-4000-8000-000000000002",
            "start":0,"length":100,"style":{"mode":"digital","sides":"mirrored","startXMilli":320123,
            "startYMilli":540000,"endXMilli":1728000,"endYMilli":540000,"maxHeightMilli":480000,
            "thicknessMilli":3125,"red":12,"green":34,"blue":56,"alpha":173,"bands":64,"lowHz":20,
            "highHz":2000,"windowMs":300,"offsetMs":-500,"floorDB":-60\(extra)}}]}
            """
    }

    private var appearanceField: String {
        #""appearance":{"contractVersion":1,"outsideRGB":{"red":17,"green":31,"blue":47}}"#
    }

    private func encodedFixtures(_ json: String) throws -> [(name: String, bytes: Data)] {
        let encodings: [(String, String.Encoding, [UInt8])] = [
            ("UTF-8", .utf8, [0xEF, 0xBB, 0xBF]),
            ("UTF-16LE", .utf16LittleEndian, [0xFF, 0xFE]),
            ("UTF-16BE", .utf16BigEndian, [0xFE, 0xFF]),
            ("UTF-32LE", .utf32LittleEndian, [0xFF, 0xFE, 0x00, 0x00]),
            ("UTF-32BE", .utf32BigEndian, [0x00, 0x00, 0xFE, 0xFF])
        ]
        var fixtures: [(String, Data)] = []
        for (name, encoding, mark) in encodings {
            let bytes = try XCTUnwrap(json.data(using: encoding))
            fixtures.append((name, bytes))
            if encoding != .utf32LittleEndian {
                fixtures.append((name + " BOM", Data(mark) + bytes))
            }
        }
        return fixtures
    }

    func testUTF32LEWithBOMFollowsFoundationHeaderAdmission() throws {
        struct Header: Decodable { let format: String; let version: Int }
        func bytes(_ fields: [String]) throws -> Data {
            let json = spectrumJSON(version: 8, image: false, styleFields: fields)
            return Data([0xFF, 0xFE, 0x00, 0x00]) + (try XCTUnwrap(json.data(using: .utf32LittleEndian)))
        }
        let singleColor = try bytes([])
        if let header = try? JSONDecoder().decode(Header.self, from: singleColor) {
            XCTAssertEqual(header.format, ProjectFile.format)
            XCTAssertEqual(header.version, 8)
            let raw = try ProjectFile.decode(singleColor)
            let app = try ProjectPersistence.decode(singleColor)
            XCTAssertEqual(app.version, 8)
            XCTAssertEqual(raw.timeline.spectra, app.timeline.spectra)
            let style = try XCTUnwrap(app.timeline.spectra.first?.style)
            XCTAssertEqual(style.resolvedOutsideRGB, style.insideRGB)
        } else {
            XCTAssertThrowsError(try ProjectFile.decode(singleColor))
            XCTAssertThrowsError(try ProjectPersistence.decode(singleColor))
        }
        let forbidden = try bytes([appearanceField])
        XCTAssertThrowsError(try ProjectFile.decode(forbidden))
        XCTAssertThrowsError(try ProjectPersistence.decode(forbidden))
    }

    func testSpectrumColorAndReactionRoundTripAcrossJSONEncodings() throws {
        for image in [false, true] {
            for version in [image ? 9 : 8, 10, 11] {
                var fields: [String] = []
                if version >= 10 { fields.append(#""reactionPercent":150"#) }
                if version == 11 { fields.append(appearanceField) }
                let json = spectrumJSON(version: version, image: image, styleFields: fields)
                for (encoding, bytes) in try encodedFixtures(json) {
                    let label = "Format \(version), \(encoding), image \(image)"
                    let opened = try ProjectPersistence.decode(bytes)
                    let style = try XCTUnwrap(opened.timeline.spectra.first?.style, label)
                    XCTAssertEqual(opened.version, version, label)
                    XCTAssertEqual(opened.timeline.lanes.first?.name, "색상 🎵", label)
                    XCTAssertEqual(style.insideRGB, .init(red: 12, green: 34, blue: 56), label)
                    XCTAssertEqual(style.resolvedOutsideRGB, version == 11 ? .init(red: 17, green: 31, blue: 47) : style.insideRGB, label)
                    XCTAssertEqual(style.alpha, 173, label)
                    XCTAssertEqual(style.thicknessMilli, 3125, label)
                    XCTAssertEqual(style.startXMilli, 320123, label)
                    XCTAssertEqual(style.reactionPercent, version >= 10 ? 150 : 100, label)
                    if image {
                        XCTAssertThrowsError(try ProjectFile.decode(bytes), label)
                    } else {
                        XCTAssertEqual(try ProjectFile.decode(bytes).timeline.spectra, opened.timeline.spectra, label)
                    }
                    let saved = try ProjectPersistence.encode(opened, at: URL(fileURLWithPath: "/generated/colors.ontheframe"))
                    let reopened = try ProjectPersistence.decode(saved)
                    XCTAssertEqual(reopened.version, 11, label)
                    XCTAssertEqual(reopened.timeline, opened.timeline, label)
                }
            }
        }
    }

    func testForbiddenAndMalformedSpectrumFieldsAcrossJSONEncodings() throws {
        let reaction = #""reactionPercent":150"#
        let badAppearance = [
            appearanceField.replacingOccurrences(of: #""contractVersion":1"#, with: #""contractVersion":2"#),
            appearanceField.replacingOccurrences(of: #""red":17"#, with: #""red":17,"extra":0"#),
            appearanceField.replacingOccurrences(of: #""red":17"#, with: #""red":17,"\u0072ed":17"#),
            appearanceField.replacingOccurrences(of: #""red":17"#, with: #""red":17.0"#),
            appearanceField.replacingOccurrences(of: #""red":17"#, with: #""red":256"#)
        ]
        for image in [false, true] {
            let legacy = image ? 9 : 8
            var invalid: [(Int, [String])] = [
                (legacy, [appearanceField]), (legacy, [reaction]), (10, [reaction, appearanceField]),
                (10, [#""reactionPercent":150.0"#]), (11, [reaction, reaction, appearanceField]),
                (11, [reaction, appearanceField, appearanceField])
            ]
            invalid += badAppearance.map { (11, [reaction, $0]) }
            for (version, fields) in invalid {
                let json = spectrumJSON(version: version, image: image, styleFields: fields)
                for (encoding, bytes) in try encodedFixtures(json) {
                    let label = "Format \(version), \(encoding), image \(image), \(fields)"
                    XCTAssertThrowsError(try ProjectPersistence.decode(bytes), label)
                    if !image { XCTAssertThrowsError(try ProjectFile.decode(bytes), label) }
                }
            }
        }
    }
}
