import XCTest
import AVFoundation
@testable import OnTheFrameEngine

/// Admission gate before product integration: stretching real carrier samples must
/// preserve native frame identity beyond the original six-frame fixture.
final class CarrierDurationTests: XCTestCase {
    @MainActor func testScaledCarrierAtImageInsertionDuration() async throws {
        guard let path=ProcessInfo.processInfo.environment["OTF_CARRIER_DURATION_RUN"],
              let source=ProcessInfo.processInfo.environment["OTF_CLOCK_SOURCE"] else {
            throw XCTSkip("explicit disposable carrier-duration opt-in")
        }
        let root=URL(fileURLWithPath:path)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let original=try await ClockCarrierCompatibilityTests.plan(source:URL(fileURLWithPath:source),run:root.appendingPathComponent("source"),mixed:false)
        let comp=try XCTUnwrap(original.asset.mutableCopy() as? AVMutableComposition)
        let end=150
        comp.scaleTimeRange(CMTimeRange(start:.zero,duration:CMTime(value:6,timescale:30)),toDuration:CMTime(value:Int64(end),timescale:30))
        let seed=try XCTUnwrap(original.vc.instructions.first as? ClockCarrierInstruction)
        var instructions=[ClockCarrierInstruction]()
        for frame in 0..<end {
            instructions.append(ClockCarrierInstruction(frame:frame,phase:frame>=1 && frame<149 ? 1:0,carrier:seed.carrier,bottom:nil,top:nil,gpu:seed.gpu,black:seed.black,log:seed.log))
        }
        let vc=try XCTUnwrap(original.vc.mutableCopy() as? AVMutableVideoComposition)
        vc.instructions=instructions
        let item=AVPlayerItem(asset:comp);item.videoComposition=vc
        let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:IBContract.format]);item.add(output)
        let player=AVPlayer(playerItem:item);player.isMuted=true;player.actionAtItemEnd = .pause
        defer { player.pause();item.cancelPendingSeeks();item.remove(output);player.replaceCurrentItem(with:nil) }
        var rows=[[String:Any]]()
        func write() throws {try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("duration-observations.json"))}
        try await ClockCarrierCompatibilityTests.wait(5){item.status != .unknown}
        guard item.status == .readyToPlay else {throw item.error ?? IBContract.error("duration carrier item not ready")}
        XCTAssertEqual(CMTimeCompare(comp.duration,CMTime(value:150,timescale:30)),0)
        for frame in [0,1,6,75,148,149,7] {
            try await ClockCarrierCompatibilityTests.seek(player,frame)
            let time=CMTime(value:Int64(frame),timescale:30)
            var pb:CVPixelBuffer?,shown=CMTime.invalid
            do { try await ClockCarrierCompatibilityTests.wait(5){pb=output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&shown);return pb != nil} }
            catch {rows.append(["frame":frame,"error":String(describing:error),"itemTime":player.currentTime().seconds,"status":item.status.rawValue,"events":seed.log.snapshot]);try write();throw error}
            let hash=try QA01.sha(QA01.active(XCTUnwrap(pb)))
            let expected=try XCTUnwrap(original.expected[frame>=1 && frame<149 ? 1:0])
            rows.append(["frame":frame,"requestedPTS":time.seconds,"displayPTS":shown.seconds,"hash":hash,"expectedHash":expected,"itemTime":player.currentTime().seconds,"duration":comp.duration.seconds,"events":seed.log.snapshot]);try write()
            XCTAssertEqual(CMTimeCompare(shown,time),0,"native carrier output PTS at frame \(frame)")
            XCTAssertEqual(hash,expected,"native carrier frame identity at frame \(frame)")
        }
        try await ClockCarrierCompatibilityTests.seek(player,145)
        player.play()
        try await ClockCarrierCompatibilityTests.wait(5){player.currentTime().seconds>=149.0/30}
        player.pause()
        XCTAssertEqual(item.status,.readyToPlay)
        XCTAssertEqual(seed.gpu.leases.counts.active,0)
        XCTAssertEqual(seed.gpu.leases.counts.pending,0)
        rows.append(["playToEnd":true,"currentTime":player.currentTime().seconds,"active":seed.gpu.leases.counts.active,"pending":seed.gpu.leases.counts.pending]);try write()
    }
}
