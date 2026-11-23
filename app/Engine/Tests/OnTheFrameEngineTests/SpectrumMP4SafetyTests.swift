import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import XCTest
import os

/// SP-EXPORT-E4a: 거부·취소·실패에서 대상과 임시 폴더, 원본이 안전한가. 공개 내보내기의 차단이 그대로인가.
final class SpectrumMP4SafetyTests: SpectrumMP4TestCase {
    override class func tearDown() { if keptDir == nil { try? FileManager.default.removeItem(at: root) }; runs = [:] }
    final class Gate: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (reached: false, fired: false))
        let threshold: Double
        init(_ t: Double) { threshold = t }
        func report(_ p: Double) { if p >= threshold { lock.withLock { $0.reached = true } } }
        var reached: Bool { lock.withLock { $0.reached } }
        /// 처음 한 번만 true
        func fireOnce() -> Bool { lock.withLock { s in if s.reached && !s.fired { s.fired = true; return true }; return false } }
    }
    func scene(source: MediaAsset? = nil) async throws -> (Timeline, [UUID: MediaAsset], Fx.Media) {
        let m = try await media(), src = source ?? m.tone
        let b = try Fx.base(m, source: src)
        let t = try b.timeline.addingSpectrum(lane: b.low, at: 0, length: 60, sourceKey: b.key, style: Fx.style(.digital))
        return (t, [m.video.id: m.video, src.id: src], m)
    }
    func destination(_ name: String) throws -> URL {
        let d = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("out.mp4")
    }
    func assertNothingLeft(_ dest: URL, _ temp: SubtitlePumpFixture.TempBox, tempExpected: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path), [], "대상 폴더가 비어 있다", file: file, line: line)
        if tempExpected {
            let made = try XCTUnwrap(temp.url, "임시 폴더를 만들었다", file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: made.path), "임시 폴더를 지웠다", file: file, line: line)
        } else { XCTAssertNil(temp.url, "임시 폴더를 만들기 전에 멈췄다", file: file, line: line) }
    }
    func message(_ outcome: ExportOutcome) -> String { if case .failed(.export(let s)) = outcome { return s }; return "" }

    // H. 소스를 고르지 않은 스펙트럼: 대상·임시 폴더를 건드리기 전에 거부, 이유를 알려 준다
    func testInvalidSourceIsRejectedBeforeAnyOutput() async throws {
        let m = try await media()
        let b = try Fx.base(m, source: m.tone)
        let t = try b.timeline.addingSpectrum(lane: b.low, at: 0, length: 30, sourceKey: nil)
        let dest = try destination("unset"), temp = SubtitlePumpFixture.TempBox()
        let outcome = await ExportService.exportSpectrumTimeline(t, media: [m.video.id: m.video, m.tone.id: m.tone], enabled: true, to: .fromSavePanel(dest),
                                                                 limits: Fx.limits, options: .init(onTempDirectory: { temp.set($0) }))
        XCTAssertTrue(message(outcome).contains("소스를 고르지"), "\(outcome)")
        try assertNothingLeft(dest, temp, tempExpected: false)
    }
    // 공개 차단은 그대로: 보통 내보내기는 스펙트럼이 든 구성을 거부하고, 내부 진입점도 켜지 않으면 거부한다
    func testPublicExportStillRejectsSpectrum() async throws {
        let (t, media, _) = try await scene()
        let dest = try destination("public-guard"), temp = SubtitlePumpFixture.TempBox()
        let plan = try await CompositionPlanner.plan(t, media: media)
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: Array(media.values), options: .init(onTempDirectory: { temp.set($0) })) { _ in }
        XCTAssertTrue(message(outcome).contains("스펙트럼을 아직 내보내지 못합니다"), "\(outcome)")
        let off = await ExportService.exportSpectrumTimeline(t, media: media, enabled: false, to: .fromSavePanel(dest), limits: Fx.limits)
        guard case .failed = off else { return XCTFail("\(off)") }
        try assertNothingLeft(dest, temp, tempExpected: false)
    }
    // I. 확인하지 않은 기존 대상은 그대로
    func testUnconfirmedExistingDestinationIsPreserved() async throws {
        let (t, media, _) = try await scene()
        let dest = try destination("existing"), bytes = Data("keep".utf8)
        try bytes.write(to: dest)
        let outcome = await ExportService.exportSpectrumTimeline(t, media: media, enabled: true,
            to: ExportDestination(url: dest, confirmedReplace: false, identityAtConfirmation: nil), limits: Fx.limits)
        XCTAssertEqual(outcome, .failed(.destinationExistsUnconfirmed))
        XCTAssertEqual(try Data(contentsOf: dest), bytes)
    }
    // J. 내보내는 도중 취소: 대상 없음, 임시 폴더 삭제, 완료를 알리지 않음
    func testCancellationLeavesNoOutput() async throws {
        let (t, media, _) = try await scene()
        let dest = try destination("cancel"), temp = SubtitlePumpFixture.TempBox(), gate = Gate(0.15)
        let progress = OSAllocatedUnfairLock(initialState: [Double]())
        let task = Task {
            await ExportService.exportSpectrumTimeline(t, media: media, enabled: true, to: .fromSavePanel(dest), limits: Fx.limits,
                                                       options: .init(onTempDirectory: { temp.set($0) }),
                                                       progress: { p in gate.report(p); progress.withLock { $0.append(p) } })
        }
        let deadline = Date().addingTimeInterval(120)
        while !gate.reached, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(gate.reached, "쓰기가 진행 중일 때 취소한다")
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(progress.withLock { $0.contains(1) }, "완료(1.0)를 알리지 않는다")
        try assertNothingLeft(dest, temp, tempExpected: true)
    }
    // K. 내보내는 도중 원본이 바뀜: 멈추고, 이유를 알려 주고, 남기지 않는다
    func testChangedSourceStopsAndCleansUp() async throws {
        let changing = dir.appendingPathComponent("sources-changing/tone.wav")
        try FileManager.default.createDirectory(at: changing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SpectrumTimelineFixture.writeWAV(changing, seconds: 2, channels: 2, SpectrumTimelineFixture.tone(440))
        let source = try await MediaProbe.inspect(changing)
        let (t, media, _) = try await scene(source: source)
        let dest = try destination("changed"), temp = SubtitlePumpFixture.TempBox(), gate = Gate(0.2)
        let outcome = await ExportService.exportSpectrumTimeline(t, media: media, enabled: true, to: .fromSavePanel(dest), limits: Fx.limits,
                                                                 options: .init(onTempDirectory: { temp.set($0) }), progress: { p in
            gate.report(p)
            if gate.fireOnce() { try? SpectrumTimelineFixture.writeWAV(changing, seconds: 1, channels: 2, SpectrumTimelineFixture.tone(880)) }
        })
        XCTAssertTrue(gate.reached)
        XCTAssertTrue(message(outcome).contains("바뀌었"), "\(outcome)")
        try assertNothingLeft(dest, temp, tempExpected: true)
    }
    // 프레임 메모리 예산을 넘음: 층을 빼지 않고 멈추며 남기지 않는다
    func testExceededFrameBudgetStopsAndCleansUp() async throws {
        let (t, media, _) = try await scene()
        let dest = try destination("budget"), temp = SubtitlePumpFixture.TempBox()
        let tight = SpectrumTimelineExportLimits(stepTimeout: 30, jobTimeout: 300, frameMemoryBudgetBytes: 9 << 20)
        let outcome = await ExportService.exportSpectrumTimeline(t, media: media, enabled: true, to: .fromSavePanel(dest), limits: tight,
                                                                 options: .init(onTempDirectory: { temp.set($0) }))
        XCTAssertTrue(message(outcome).contains("메모리"), "\(outcome)")
        try assertNothingLeft(dest, temp, tempExpected: true)
    }
}
