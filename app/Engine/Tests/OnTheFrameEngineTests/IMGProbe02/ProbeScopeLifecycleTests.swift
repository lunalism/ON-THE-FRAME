import XCTest
@testable import OnTheFrameEngine

final class ProbeScopeLifecycleTests:XCTestCase {
    var url:URL!
    override func setUpWithError()throws {
        guard let p=ProcessInfo.processInfo.environment["OTF_PROBE02_FIXTURE"] else{throw XCTSkip("scope lifecycle opt-in")};url=URL(fileURLWithPath:p)
    }
    func testSuccessFailureDeniedAndRepeatedOwnership()async throws {
        let s=ProbeScopeSession(),c=ProbeScopeCounts(),u=url!
        for _ in 0..<3{_ = try await s.run(u,begin:{c.acquired();return true},end:{c.released()})}
        XCTAssertEqual(c.snapshot["starts"],3);XCTAssertEqual(c.snapshot["ends"],3);XCTAssertEqual(c.snapshot["active"],0)
        do{_ = try await s.run(u,begin:{false},end:{XCTFail("release without ownership")});XCTFail("denial accepted")}catch ProbeScopeFailure.denied{}
        let invalid=u.deletingLastPathComponent().appendingPathComponent("invalid.png")
        do{_ = try await s.run(invalid,begin:{c.acquired();return true},end:{c.released()});XCTFail("invalid accepted")}catch{}
        XCTAssertEqual(c.snapshot["starts"],4);XCTAssertEqual(c.snapshot["ends"],4);XCTAssertEqual(c.snapshot["active"],0)
        let published=await s.count();XCTAssertEqual(published,3)
    }
    func testCancellationRetainsScopeUntilDecodeGateReturns()async throws {
        let s=ProbeScopeSession(),c=ProbeScopeCounts(),gate=ProbeScopeGate(),u=url!
        let t=Task{try await s.run(u,begin:{c.acquired();return true},end:{c.released()},beforeDecode:{await gate.pause()})}
        await gate.waitForEntry();t.cancel();XCTAssertEqual(c.snapshot["active"],1);XCTAssertEqual(c.snapshot["ends"],0)
        await gate.open();do{_ = try await t.value;XCTFail("cancel accepted")}catch is CancellationError{}
        XCTAssertEqual(c.snapshot["active"],0);XCTAssertEqual(c.snapshot["ends"],1)
    }
    func testReplacementCannotPublishOrReleaseEarly()async throws {
        let s=ProbeScopeSession(),c=ProbeScopeCounts(),gate=ProbeScopeGate(),u=url!
        let t=Task{try await s.run(u,begin:{c.acquired();return true},end:{c.released()},beforeDecode:{await gate.pause()})}
        await gate.waitForEntry();await s.replace();XCTAssertEqual(c.snapshot["active"],1);await gate.open()
        do{_ = try await t.value;XCTFail("stale result published")}catch ProbeScopeFailure.stale{}
        let published=await s.count();XCTAssertEqual(published,0);XCTAssertEqual(c.snapshot["ends"],1);XCTAssertEqual(c.snapshot["active"],0)
    }
    func testActualDecoderFailureAfterMetadataReleasesScope()async throws {
        let source=try Data(contentsOf:url);var data=source.prefix(8),k=8
        func u32(_ offset:Int)->Int {source[offset..<offset+4].reduce(0){($0<<8)|Int($1)}}
        func be(_ n:UInt32)->Data{Data([UInt8(n>>24),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)])}
        while k+12<=source.count {
            let n=u32(k),tag=source.subdata(in:k+4..<k+8)
            if tag==Data("IDAT".utf8) {let payload=Data([0x78,0x01,0x00]);data += be(UInt32(payload.count))+tag+payload+be(StillImageProbe.crc(tag+payload))}
            else{data += source[k..<k+n+12]};k+=n+12
        }
        let bad=url.deletingLastPathComponent().appendingPathComponent("decode-invalid.png")
        guard !FileManager.default.fileExists(atPath:bad.path) else{throw ProbeScopeFailure.denied};try data.write(to:bad)
        _ = try StillImageProbe.inspect(bad) // Must pass metadata: failure is in actual ImageIO decode.
        let session=ProbeScopeSession(),counter=ProbeScopeCounts()
        do{_ = try await session.run(bad,begin:{counter.acquired();return true},end:{counter.released()});XCTFail("bad compressed pixels accepted")}catch StillImageProbeError.malformed{}
        XCTAssertEqual(counter.snapshot["starts"],1);XCTAssertEqual(counter.snapshot["ends"],1);XCTAssertEqual(counter.snapshot["active"],0)
    }
    func testInputReplacementReleasesOnIdentityFailure()async throws {
        guard let p=ProcessInfo.processInfo.environment["OTF_PROBE02_OUTPUT"] else{throw XCTSkip("fresh output required")}
        let dir=URL(fileURLWithPath:p);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let copy=dir.appendingPathComponent("replace.png");guard !FileManager.default.fileExists(atPath:copy.path) else{throw ProbeScopeFailure.denied};try FileManager.default.copyItem(at:url,to:copy)
        let s=ProbeScopeSession(),c=ProbeScopeCounts()
        do{_ = try await s.run(copy,begin:{c.acquired();return true},end:{c.released()},beforeDecode:{try Data([1,2,3]).write(to:copy,options:.atomic)});XCTFail("replaced file accepted")}catch StillImageProbeError.changed{}
        XCTAssertEqual(c.snapshot["ends"],1);XCTAssertEqual(c.snapshot["active"],0)
    }
}
