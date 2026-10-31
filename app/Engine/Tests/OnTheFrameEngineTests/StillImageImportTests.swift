import XCTest
import Foundation
import ImageIO
@testable import OnTheFrameEngine

final class StillImageImportTests: XCTestCase {
    func testProbeToAtomicOperationalInsertion() async throws {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["OTF_MODEL03_RUN"]!).appendingPathComponent("public-import")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let u=root.appendingPathComponent("source.png")
        let c=CGContext(data:nil,width:2,height:3,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let d=CGImageDestinationCreateWithURL(u as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(d,c.makeImage()!,nil);XCTAssertTrue(CGImageDestinationFinalize(d))
        let bytes=try Data(contentsOf:u), image=try await StillImageImport.prepare(u), before=Timeline(),mid=UUID(),cid=UUID()
        let t=try StillImageImport.inserting(image,into:before,at:0,lane:Lane.videoID,mediaID:mid,clipID:cid)
        XCTAssertTrue(before.mediaCatalog.isEmpty)
        XCTAssertEqual(t.stillImageIDs,[mid]);XCTAssertTrue(t.mediaFrames.isEmpty);XCTAssertTrue(t.audioClips.isEmpty)
        XCTAssertEqual(t.clips.first?.id,cid);XCTAssertEqual(t.clips.first?.sourceIn,0);XCTAssertEqual(t.clips.first?.length,150)
        XCTAssertThrowsError(try StillImageImport.inserting(image,into:t,at:0,lane:Lane.videoID,mediaID:UUID(),clipID:UUID()))
        XCTAssertEqual(t.mediaCatalog.count,1)
        XCTAssertThrowsError(try StillImageImport.inserting(image,into:before,at:0,lane:Lane.audioID,mediaID:UUID(),clipID:UUID()))
        let doc=try ProjectPersistence.make(timeline:t,projectID:UUID())
        XCTAssertEqual(try ProjectPersistence.decode(ProjectPersistence.encode(doc,at:root.appendingPathComponent("project.ontheframe"))).version,9)
        XCTAssertEqual(try Data(contentsOf:u),bytes)
        try Data("replaced".utf8).write(to:u)
        XCTAssertThrowsError(try StillImageImport.inserting(image,into:before,at:0,lane:Lane.videoID,mediaID:UUID(),clipID:UUID()))
    }
    func testCancellationPropagatesThroughBridge() async throws {
        let work=Task { () throws -> StillImageImport.Prepared in
            withUnsafeCurrentTask{$0?.cancel()}
            return try await StillImageImport.prepare(URL(fileURLWithPath:"/nonexistent-generated-image.png"))
        }
        do { _ = try await work.value;XCTFail("cancelled preparation accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
