import XCTest
import ImageIO
import CoreGraphics
@testable import OnTheFrameEngine

enum ImageModelFixture {
    typealias M = StillImageProjectModel
    static func image(_ ext: String = "png", width: Int = 2, height: Int = 3, orientation: Int = 1) async throws -> M.ValidatedImage {
        let parent=ProcessInfo.processInfo.environment["OTF_MODEL03_RUN"].map {URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory.appendingPathComponent("otf-model03")
        let dir=parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let url=dir.appendingPathComponent("generated."+ext)
        let context=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,(ext == "png" ? "public.png":"public.jpeg") as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),[kCGImagePropertyOrientation:orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try await M.ValidatedImage.inspect(url)
    }
    static func base() -> M.Project {
        M.Project(.init(format:ProjectFile.format,version:5,projectID:UUID(),settings:.init(width:1920,height:1080,fps:30),durationFrames:300,lanes:Lane.defaults,media:[],videoClips:[],audioClips:[],subtitles:nil,spectra:nil))
    }
    static func project(_ source: M.ValidatedImage) throws -> M.Project {
        var p=base();let ref=M.MediaReference.stillImage(.init(validated:source))
        p.media=[.init(ref:ref,relativePath:nil,bookmark:Data([1,2]))]
        p.videoClips=[try M.insertingImage(media:ref,at:0,lane:Lane.videoID)]
        p.videoClips[0]=p.videoClips[0].with(transform:.some(ClipTransform(scaleMicro:700000,offsetXMilli:1200,offsetYMilli:-500)))
        try p.validate();return p
    }
    static func temporal(video: Bool = true) -> MediaRef {
        MediaRef(id:UUID(),name:video ? "video":"audio",path:"/generated/temporal",frameCount:300,hasAudio:true,size:100,modifiedNs:42,codec:video ? "h264":"pcm",width:video ? 1920:0,height:video ? 1080:0,hasVideo:video,sampleRate:video ? nil:48000,sampleCount:video ? nil:480000,channels:video ? nil:2)
    }
}

final class StillImageProjectModelTests: XCTestCase {
    typealias M = StillImageProjectModel
    func testCancelledValidationCannotCreateRelinkCapability() async throws {
        let source=try await ImageModelFixture.image()
        let canceled=Task { () -> Bool in
            withUnsafeCurrentTask {$0?.cancel()}
            do {_ = try await M.ValidatedImage.inspect(source.url);return false}
            catch is CancellationError {return true}
            catch {return false}
        }
        let rejected=await canceled.value
        XCTAssertTrue(rejected)
    }
    func testKindsAndValidatedPayload() async throws {
        let source=try await ImageModelFixture.image(),r=M.MediaReference.stillImage(.init(validated:source))
        XCTAssertEqual(r.kind,.stillImage);XCTAssertNil(r.temporal);XCTAssertFalse(r.hasVideoTrack);XCTAssertTrue(r.hasVisualContent);XCTAssertFalse(r.hasAudio)
        XCTAssertEqual(r.still!.image,M.ImageInfo(source.descriptor))
        let v=M.MediaReference.video(ImageModelFixture.temporal()),a=M.MediaReference.audio(ImageModelFixture.temporal(video:false))
        XCTAssertTrue(v.hasVideoTrack);XCTAssertTrue(v.hasAudio);XCTAssertFalse(a.hasVisualContent);XCTAssertTrue(a.hasAudio)
    }
    func testInsertionMinimumOverflowAndLane() async throws {
        let p=try ImageModelFixture.project(await ImageModelFixture.image()),r=p.media[0].ref
        XCTAssertEqual(p.videoClips[0].length,150)
        XCTAssertThrowsError(try M.insertingImage(media:r,at:0,lane:Lane.audioID))
        XCTAssertEqual(try M.insertingImage(media:r,at:10,lane:Lane.videoID,length:1).length,1)
        for n in [0,-1,Int.max] {XCTAssertThrowsError(try M.insertingImage(media:r,at:1,lane:Lane.videoID,length:n))}
        for start in [-1,Int.max,Timeline.maxFrames] {XCTAssertThrowsError(try M.insertingImage(media:r,at:start,lane:Lane.videoID,length:1))}
        let wrong=Clip(mediaID:r.id,start:0,sourceIn:0,length:1,lane:Lane.audioID)
        XCTAssertThrowsError(try M.validateImageClip(wrong,media:r,lanes:p.lanes))
        XCTAssertThrowsError(try M.validateImageClip(Clip(mediaID:r.id,start:0,sourceIn:1,length:1,lane:Lane.videoID),media:r,lanes:p.lanes))
    }
    func testMoveTrimSplitAndCopyProjection() async throws {
        let p=try ImageModelFixture.project(await ImageModelFixture.image()),c=p.videoClips[0],r=p.media[0].ref
        let moved=try M.boundaries(c,media:r,start:20,length:c.length,lanes:p.lanes)
        XCTAssertEqual(moved.id,c.id);XCTAssertEqual(moved.sourceIn,0)
        let trimmed=try M.boundaries(moved,media:r,start:30,length:20,lanes:p.lanes)
        let parts=try M.split(trimmed,media:r,at:40,lanes:p.lanes)
        XCTAssertNotEqual(parts.0.id,parts.1.id);XCTAssertNotEqual(parts.0.id,c.id)
        XCTAssertEqual([parts.0.sourceIn,parts.1.sourceIn],[0,0]);XCTAssertEqual(parts.1.mediaID,r.id)
        let copy=try M.copy(c,media:r,at:150,lanes:p.lanes)
        XCTAssertNotEqual(copy.id,c.id);XCTAssertEqual(copy.mediaID,c.mediaID)
        XCTAssertThrowsError(try M.split(c,media:r,at:c.start,lanes:p.lanes))
    }
    func testDocumentOverlapReferencesLineageAndDuration() async throws {
        let p=try ImageModelFixture.project(await ImageModelFixture.image()),r=p.media[0].ref,c=p.videoClips[0]
        func reject(_ change:(inout M.Project)->Void) {var q=p;change(&q);XCTAssertThrowsError(try q.validate())}
        reject {$0.videoClips.append(c)}
        reject {$0.videoClips.append(Clip(mediaID:r.id,start:100,sourceIn:0,length:20,lane:Lane.videoID))}
        reject {$0.media.append($0.media[0])}
        reject {$0.videoClips=[Clip(mediaID:UUID(),start:0,sourceIn:0,length:1,lane:Lane.videoID)]}
        for key in ["link","origin","audio"] {
            reject {$0.videoClips=[Clip(mediaID:r.id,start:0,sourceIn:0,length:1,link:key == "link" ? UUID():nil,lane:Lane.videoID,audio:key == "audio" ? ClipAudio(volumePercent:50):nil,origin:key == "origin" ? UUID():nil)]}
        }
        reject {$0.audioClips=[Clip(mediaID:r.id,start:0,sourceIn:0,length:1,lane:Lane.audioID)]}
        let spec=UUID();reject {$0.lanes.insert(Lane(id:spec,kind:.spectrum,name:"SP"),at:0);$0.spectra=[SpectrumItem(lane:spec,start:0,length:1,sourceKey:c.id)]}
        reject {$0.durationFrames=1}
        var deleted=p;deleted.videoClips=[];try deleted.validate();XCTAssertEqual(deleted.durationFrames,p.durationFrames)
        var stacked=p;let lane=UUID();stacked.lanes.insert(Lane(id:lane,kind:.video,name:"V2"),at:0)
        stacked.videoClips.append(Clip(mediaID:r.id,start:0,sourceIn:0,length:150,lane:lane));try stacked.validate()
        var reversed=p;reversed.lanes.reverse();XCTAssertThrowsError(try reversed.validate())
    }
    func testRelinkEncodingsNotificationAndFileIdentity() async throws {
        for first in ["png","jpg"] {
            let p=try ImageModelFixture.project(await ImageModelFixture.image(first))
            let originalURL=URL(fileURLWithPath:p.media[0].ref.path),originalBytes=try Data(contentsOf:originalURL)
            for second in ["png","jpg"] {
                let replacement=try await ImageModelFixture.image(second)
                let (q,change)=try M.relink(p,mediaID:p.media[0].ref.id,to:replacement)
                XCTAssertEqual(q.videoClips,p.videoClips);XCTAssertEqual(q.media[0].ref.id,p.media[0].ref.id)
                XCTAssertFalse(change.requiresNotification);XCTAssertNil(q.media[0].bookmark)
            }
            let replacement=try await ImageModelFixture.image("jpg",width:3,height:2,orientation:6)
            let (q,change)=try M.relink(p,mediaID:p.media[0].ref.id,to:replacement)
            XCTAssertTrue(change.requiresNotification);XCTAssertEqual(q.videoClips,p.videoClips)
            var temporal=p;temporal.videoClips=[];let r=ImageModelFixture.temporal();temporal.media=[.init(ref:.video(r),relativePath:nil,bookmark:nil)]
            XCTAssertThrowsError(try M.relink(temporal,mediaID:r.id,to:replacement))
            try Data([1]).write(to:replacement.url,options:.atomic)
            XCTAssertThrowsError(try M.relink(p,mediaID:p.media[0].ref.id,to:replacement))
            XCTAssertEqual(try Data(contentsOf:originalURL),originalBytes)
        }
    }
}
