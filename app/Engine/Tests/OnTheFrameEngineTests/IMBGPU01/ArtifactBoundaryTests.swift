import XCTest

final class ArtifactBoundaryTests:XCTestCase {
    func testExplicitNonDirectoryParentURLRepresentation()throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_GPU02BR_ACCOUNTING"] else{throw XCTSkip("accounting opt-in")}
        let parent=URL(fileURLWithPath:path+"-hint",isDirectory:false)
        let root=parent.appendingPathComponent("current",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        XCTAssertNotEqual(root.deletingLastPathComponent(),parent)
        XCTAssertEqual(root.deletingLastPathComponent().pathComponents,parent.pathComponents)
        XCTAssertNoThrow(try GMArtifactBoundary.check(root:root,parent:parent,combined:{0}))
    }
    func testSevenAccountingConditions()throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_GPU02BR_ACCOUNTING"] else{throw XCTSkip("accounting opt-in")}
        let parent=URL(fileURLWithPath:path),fm=FileManager.default
        try fm.createDirectory(at:parent,withIntermediateDirectories:true)
        let old=parent.appendingPathComponent("old"),run=parent.appendingPathComponent("current")
        try fm.createDirectory(at:old,withIntermediateDirectories:true);try fm.createDirectory(at:run,withIntermediateDirectories:true)
        try Data(repeating:1,count:128).write(to:old.appendingPathComponent("older"));try Data([1]).write(to:run.appendingPathComponent("new"))
        let bytes=try GMArtifactBoundary.check(root:run,parent:parent,combined:{0});XCTAssertGreaterThan(bytes,0)
        XCTAssertNoThrow(try GMArtifactBoundary.check(root:run,parent:parent,newLimit:bytes,combined:{0}))
        XCTAssertThrowsError(try GMArtifactBoundary.check(root:run,parent:parent,newLimit:bytes-1,combined:{0}))
        XCTAssertThrowsError(try GMArtifactBoundary.check(root:run,parent:parent,combinedLimit:4,combined:{5}))
        XCTAssertThrowsError(try GMArtifactBoundary.check(root:parent,parent:parent,combined:{0}))
        XCTAssertThrowsError(try GMArtifactBoundary.check(root:parent.appendingPathComponent("missing"),parent:parent,combined:{0}))
        try fm.createSymbolicLink(atPath:run.appendingPathComponent("escape").path,withDestinationPath:old.path)
        XCTAssertThrowsError(try GMArtifactBoundary.check(root:run,parent:parent,combined:{0}))
        XCTAssertThrowsError(try GMArtifactBoundary.check(root:parent.appendingPathComponent("x/../current"),parent:parent,combined:{0}))
        print("GPU02BR accounting A-G PASS; old128 bytes excluded from new; injected limits; no large dummy")
    }
}
