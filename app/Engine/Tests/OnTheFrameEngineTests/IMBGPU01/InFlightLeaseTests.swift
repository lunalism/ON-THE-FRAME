import XCTest
import Metal
import AVFoundation

final class InFlightLeaseTests:XCTestCase {
    override func setUpWithError()throws{guard ProcessInfo.processInfo.environment["OTF_GPU02A"]=="1" else{throw XCTSkip("GPU02A explicit opt-in")}}
    final class Payload {}
    func testDeterministicTransitions()throws {
        for reason in [GMLeaseBook.State.completed,.canceled,.timedOut,.failed] {
            let b=GMLeaseBook();var terminal=[GMLeaseBook.State]();var payload:Payload?=Payload();weak var weakPayload=payload
            let t=try XCTUnwrap(b.admit([payload!]){terminal.append($0)});payload=nil
            XCTAssertTrue(b.submit(t));if reason != .completed{b.terminate(t,reason)}
            XCTAssertNotNil(weakPayload);XCTAssertEqual(b.counts.active,1)
            b.observedCompletion(t,failed:reason == .failed);b.observedCompletion(t);b.terminate(t,.timedOut)
            XCTAssertNil(weakPayload);XCTAssertEqual(terminal,[reason]);XCTAssertTrue(t.retired);XCTAssertEqual(b.counts.active,0)
        }
        for reason in [GMLeaseBook.State.canceled,.failed] {
            let b=GMLeaseBook();var n=0;let t=try XCTUnwrap(b.admit([Payload()]){_ in n+=1});b.terminate(t,reason);XCTAssertFalse(b.submit(t));XCTAssertEqual(n,1);XCTAssertEqual(b.counts.active,0)
        }
    }
    func testCapacityPendingGenerationAndQuarantine()throws {
        let b=GMLeaseBook();var n=0;let ts=try (0..<6).map{_ in try XCTUnwrap(b.admit([Payload()]){_ in n+=1})}
        XCTAssertNil(b.admit([]){_ in XCTFail("overflow notification")});XCTAssertEqual(b.counts.active,2);XCTAssertEqual(b.counts.pending,4)
        XCTAssertTrue(b.submit(ts[0]));XCTAssertTrue(b.submit(ts[1]));b.terminate(ts[2],.canceled);XCTAssertTrue(ts[2].resources.isEmpty)
        b.replaceGeneration();XCTAssertEqual(n,6);XCTAssertEqual(b.counts.active,2);XCTAssertEqual(b.counts.pending,0)
        b.observedCompletion(ts[0]);b.observedCompletion(ts[1]);XCTAssertEqual(n,6);XCTAssertEqual(b.counts.active,0)
        let q=try XCTUnwrap(b.admit([Payload()]){_ in n+=1});XCTAssertTrue(b.submit(q));b.quarantineUnobserved();XCTAssertNil(b.admit([]){_ in});XCTAssertEqual(b.counts.active,1);XCTAssertFalse(q.resources.isEmpty);b.observedCompletion(q);XCTAssertTrue(q.resources.isEmpty)
    }
    func testCompletionTimeoutRaceAndReentrantCallback()throws {
        for _ in 0..<32 {
            let b=GMLeaseBook(),counter=NSLock();var count=0
            let t=try XCTUnwrap(b.admit([Payload()]){_ in counter.lock();count+=1;counter.unlock();_ = b.counts})
            XCTAssertTrue(b.submit(t));DispatchQueue.concurrentPerform(iterations:3){i in if i==0{b.terminate(t,.timedOut)}else{b.observedCompletion(t)}}
            XCTAssertEqual(count,1);XCTAssertEqual(b.counts.active,0);XCTAssertTrue(t.resources.isEmpty)
        }
    }
    func testRealMetalNormalAndControlledLateCompletion()throws {
        guard let d=MTLCreateSystemDefaultDevice(),let queue=d.makeCommandQueue(),let event=d.makeSharedEvent() else{throw XCTSkip("Metal/shared event unavailable")}
        for cancel in [false,true] {
            let book=GMLeaseBook(),done=DispatchSemaphore(value:0);var states=[GMLeaseBook.State]()
            let command=try XCTUnwrap(queue.makeCommandBuffer()),buffer=try XCTUnwrap(d.makeBuffer(length:4096,options:.storageModeShared))
            let pb=try GMNV12.allocate();IBContract.tag(pb)
            let ticket=try XCTUnwrap(book.admit([command,buffer,pb,queue,event]){states.append($0)})
            command.encodeWaitForEvent(event,value:cancel ? 2:1)
            let blit=try XCTUnwrap(command.makeBlitCommandEncoder());blit.fill(buffer:buffer,range:0..<4096,value:93);blit.endEncoding()
            command.addCompletedHandler{cmd in book.observedCompletion(ticket,failed:cmd.status != .completed);done.signal()}
            XCTAssertTrue(book.submit(ticket));command.commit()
            if cancel{book.terminate(ticket,.canceled);XCTAssertEqual(states,[.canceled]);XCTAssertFalse(ticket.resources.isEmpty);XCTAssertEqual(book.counts.active,1)}
            event.signaledValue=cancel ? 2:1
            XCTAssertEqual(done.wait(timeout:.now()+10),.success);XCTAssertEqual(command.status,.completed)
            XCTAssertEqual(states,[cancel ? .canceled:.completed]);XCTAssertEqual(book.counts.active,0);XCTAssertTrue(ticket.resources.isEmpty);XCTAssertEqual(buffer.contents().load(as:UInt8.self),93)
            print("GPU02A real completed cancel=\(cancel) gpuSeconds=\(command.gpuEndTime-command.gpuStartTime)")
        }
    }
}
