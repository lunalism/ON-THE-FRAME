import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E2 회귀: 여러 발자국을 받도록 바꾼 쓰기 펌프가 자막이 있는 보통 프로젝트를 전과 같이 내보내는가.
/// 제품 경로(ExportService.export)만 쓴다. 스펙트럼은 없다(공급기 nil — 공개 스펙트럼 내보내기는 계속 막혀 있다).
/// 화소는 H.264로 다시 인코딩된 것이므로 바이트 비교가 아니라 문턱값과 위치 허용 오차로 본다(SubtitlePumpFixture의 설명).
final class SubtitlePumpExportTests: XCTestCase {
    typealias Fx = SubtitlePumpFixture
    /// OTF_SUBTITLE_PUMP_DIR이 있으면 그 폴더에 쓰고 지우지 않는다(감독 실행: 외부 볼륨에 두고 증거를 남긴다). 없으면 임시 폴더에 쓰고 지운다.
    static let keptDir = ProcessInfo.processInfo.environment["OTF_SUBTITLE_PUMP_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let dir = keptDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("otf-subpump-\(UUID().uuidString)", isDirectory: true)
    override class func tearDown() { if keptDir == nil { try? FileManager.default.removeItem(at: dir) }; Fx.cached = nil }
    func exported() async throws -> Fx.Exported {
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        return try await Fx.exported(in: Self.dir)
    }

    // 내보내기가 끝났고, 자막이 있는 구성이라 쓰기 펌프 경로였으며, 파일·원본·임시 폴더가 기대대로다
    func testExportCompletesAndLeavesOnlyTheOutput() async throws {
        let x = try await exported()
        XCTAssertEqual(x.outcome, .completed(x.output))
        XCTAssertEqual(x.planSubtitles, 1, "자막이 있는 구성 → SubtitleExporter 경로")
        XCTAssertTrue(FileManager.default.fileExists(atPath: x.output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: x.output.deletingLastPathComponent().path), ["subtitle.mp4"], "대상 옆에 다른 파일이 없다")
        let temp = try XCTUnwrap(x.tempDirectory, "내보내기가 임시 폴더를 만들었다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "임시 폴더를 지웠다")
        XCTAssertEqual(try Fx.sha(x.source), x.sourceHash, "원본은 그대로")
        XCTAssertTrue(x.timelineUnchanged)
    }
    // 디코딩한 결과: 1920×1080, 영상 트랙 하나, 프레임 0…59가 한 번씩
    func testOutputHasEveryFrameAtFullSize() async throws {
        let x = try await exported()
        XCTAssertEqual(x.videoTracks, 1); XCTAssertEqual(x.width, 1920); XCTAssertEqual(x.height, 1080)
        XCTAssertEqual(x.durationFrames, Fx.frames)
        XCTAssertEqual(x.stats.keys.sorted(), Array(0..<Fx.frames), "모든 프레임을 디코딩했다")
    }
    // 자막은 [20, 40)에만 보인다
    func testSubtitleAppearsOnlyInItsInterval() async throws {
        let x = try await exported()
        for k in 0..<Fx.frames {
            let s = try XCTUnwrap(x.stats[k], "frame \(k)")
            if (Fx.subtitleStart..<Fx.subtitleEnd).contains(k) {
                XCTAssertGreaterThanOrEqual(s.brightInside, x.expected.opaque / 2, "frame \(k): 글자의 밝은 화소(기대 불투명 \(x.expected.opaque))")
                XCTAssertLessThanOrEqual(s.bright, x.expected.anyAlpha * 6 / 5, "frame \(k): 글자보다 넓게 밝지 않다")
            } else {
                XCTAssertEqual(s.bright, 0, "frame \(k): 자막 구간 밖에는 밝은 화소가 없다")
            }
            XCTAssertEqual(s.hotOutside, 0, "frame \(k): 자막 사각형(±\(Fx.margin)px) 밖은 배경 그대로")
        }
    }
    // 위치와 색: 밝은 화소의 테두리가 자막 그림의 글자 테두리와 맞고(±6 px), 색차는 무채색(흰색)이다
    func testSubtitlePositionAndColorArePreserved() async throws {
        let x = try await exported(), b = x.expected.bounds
        XCTAssertLessThan(abs(x.expected.rect.midY - 300), 80, "설정한 세로 위치(y 300) 근처에 그렸다: \(x.expected.rect)")
        for k in [Fx.subtitleStart, 30, Fx.subtitleEnd - 1] {
            let s = try XCTUnwrap(x.stats[k])
            guard s.bright > 0 else { XCTFail("frame \(k): 자막이 없다"); continue }
            XCTAssertEqual(Double(s.minX), b.minX, accuracy: 6, "frame \(k) 왼쪽"); XCTAssertEqual(Double(s.maxX), b.maxX - 1, accuracy: 6, "frame \(k) 오른쪽")
            XCTAssertEqual(Double(s.minY), b.minY, accuracy: 6, "frame \(k) 위"); XCTAssertEqual(Double(s.maxY), b.maxY - 1, accuracy: 6, "frame \(k) 아래")
            XCTAssertEqual(s.bright, s.brightInside, "frame \(k): 밝은 화소는 모두 자막 사각형 안")
            XCTAssertEqual(s.meanCb, 128, accuracy: 10, "frame \(k) Cb"); XCTAssertEqual(s.meanCr, 128, accuracy: 10, "frame \(k) Cr")
        }
    }
    // 소리: 섞인 트랙 하나, 원본의 1.0 s 소리가 그 시각에 있다(AAC를 다시 인코딩하므로 ±2048표본)
    func testAudioTrackIsPreserved() async throws {
        let x = try await exported()
        XCTAssertEqual(x.audioTracks, 1)
        XCTAssertEqual(x.audioOnsets.count, 1, "\(x.audioOnsets)")
        XCTAssertEqual(x.audioOnsets.first ?? -1, SourceTimeFixture.burstStart, accuracy: 2_048)
    }
    // 대치를 확인하지 않은 기존 파일은 그대로 둔다
    func testUnconfirmedExistingDestinationIsPreserved() async throws {
        let x = try await exported()
        let existing = Self.dir.appendingPathComponent("existing.mp4"), bytes = Data("keep".utf8)
        try bytes.write(to: existing)
        let m = try await MediaProbe.inspect(x.source)
        let plan = try await CompositionPlanner.plan(try Fx.timeline(m).0, media: [m.id: m])
        let outcome = await ExportService.export(plan, to: ExportDestination(url: existing, confirmedReplace: false, identityAtConfirmation: nil), sources: [m]) { _ in }
        XCTAssertEqual(outcome, .failed(.destinationExistsUnconfirmed))
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
    }
    // 쓰는 도중의 실패(시험용 주입): 대상 파일을 만들지 않고 임시 폴더를 지운다
    func testFailureDuringWritingLeavesNoOutput() async throws {
        let x = try await exported()
        let dest = Self.dir.appendingPathComponent("failed/never.mp4")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let m = try await MediaProbe.inspect(x.source)
        let plan = try await CompositionPlanner.plan(try Fx.timeline(m).0, media: [m.id: m])
        let temp = Fx.TempBox()
        let options = ExportService.Options(failAfterFraction: 0.3, onTempDirectory: { temp.set($0) })
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [m], options: options) { _ in }
        XCTAssertEqual(outcome, .failed(.injected))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path), [])
        let made = try XCTUnwrap(temp.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path))
    }
}
