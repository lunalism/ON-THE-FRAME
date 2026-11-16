import XCTest
@testable import OnTheFrameEngine

final class ProductionContentSafetyTests: XCTestCase {
    func testLegacyAdapterAndWriterAreIdentical() throws {
        let t = Timeline(), id = UUID()
        let content = ProductionContent(t)
        XCTAssertEqual(try content.supportedTimeline(), t)
        XCTAssertEqual(try ProjectFile.encode(content, projectID:id, settings:.m1, bookmarks:[:], projectURL:nil),
                       try ProjectFile.encode(t, projectID:id, settings:.m1, bookmarks:[:], projectURL:nil))
        XCTAssertEqual(try CompositionPlanner.layeredSegments(content, media:[:], render:CGSize(width:1920,height:1080)), [])
        XCTAssertEqual(try CompositionPlanner.layerStack(content, from:0, to:1, media:[:], render:CGSize(width:1920,height:1080)), [])
    }
    func testUsedAndUnusedImagesRejectSaveBeforeDestinationWrite() async throws {
        var p = try ImageModelFixture.project(await ImageModelFixture.image())
        for used in [true,false] {
            if !used { p.videoClips = [] }
            let content = try ProductionContent(isolated:p)
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let original = Data("existing disposable destination".utf8)
            try original.write(to:dest,options:.withoutOverwriting)
            defer { try? FileManager.default.removeItem(at:dest) }
            XCTAssertThrowsError(try ProjectFile.encode(content, projectID:p.projectID, settings:.m1, bookmarks:[:], projectURL:dest).write(to:dest)) { error in
                XCTAssertEqual(error as? ProductionContent.Unsupported,.stillImages([p.media[0].ref.id]))
            }
            XCTAssertEqual(try Data(contentsOf:dest),original)
        }
    }
    func testPlannerRejectsCompleteCatalogBeforeSelectionAndLookup() async throws {
        var p = try ImageModelFixture.project(await ImageModelFixture.image())
        // Add a full-canvas temporal clip above the image; missing assets must not win.
        let upper = Lane(id:UUID(),kind:.video,name:"upper",muted:false,volumePercent:100)
        p.lanes.insert(upper,at:0)
        let video = ImageModelFixture.temporal()
        p.media.append(.init(ref:.video(video),relativePath:nil,bookmark:nil))
        p.videoClips.append(Clip(mediaID:video.id,start:0,sourceIn:0,length:150,lane:upper.id))
        let used = try ProductionContent(isolated:p)
        for unused in [false,true] {
            if unused { p.videoClips=[] }
            let content = unused ? try ProductionContent(isolated:p) : used
            do { _ = try await CompositionPlanner.plan(content,media:[:]); XCTFail("admitted") }
            catch { XCTAssertTrue(error is ProductionContent.Unsupported) }
            XCTAssertThrowsError(try CompositionPlanner.layeredSegments(content,media:[:],render:CGSize(width:1920,height:1080))) { XCTAssertTrue($0 is ProductionContent.Unsupported) }
            XCTAssertThrowsError(try CompositionPlanner.layerStack(content,lanes:[],from:500,to:501,media:[:],render:CGSize(width:1920,height:1080))) { XCTAssertTrue($0 is ProductionContent.Unsupported) }
        }
    }
    func testImageFreeIsolatedAdapterAndNormalReaderRemainLegacy() throws {
        let p = ImageModelFixture.base(), content = try ProductionContent(isolated:p)
        XCTAssertEqual(try content.supportedTimeline().durationFrames,p.durationFrames)
        var doc = p.temporalDocument(); doc.version=9
        XCTAssertThrowsError(try ProjectFile.decode(JSONEncoder().encode(doc))) { XCTAssertEqual($0 as? ProjectFile.LoadError,.newerVersion(9)) }
    }
}
