import Foundation
@testable import OnTheFrameEngine
import XCTest

/// SP-EXPORT-E3: 내보내지 못하는 이유의 분류와 한국어 글. 판정은 기존 규칙(Timeline.spectrumExportBlockers) 그대로다.
final class SpectrumExportEligibilityTests: SpectrumTimelineTestCase {
    typealias Issue = SpectrumExportIssue
    // 11. 타임라인에서 아는 이유: 고르지 않음, 소스 없음, 겹침
    func testBlockersBecomeStructuredIssues() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let unset = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 30, sourceKey: nil)
        XCTAssertEqual(Issue.blocking(unset), [.unsetSource(lane: unset.laneLabel(sc.low), range: 0..<30)])
        let ok = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 120, sourceKey: sc.key)
        XCTAssertEqual(Issue.blocking(ok), [], "정상 타임라인에는 이유가 없다")
        let missing = try ok.lifting(clip: sc.clip)
        XCTAssertEqual(Issue.blocking(missing), [.missingSource(lane: missing.laneLabel(sc.low), range: 0..<120)])
        let (l, r) = (UUID(), UUID()), a2 = UUID()
        let overlap = try ok.splitting(clip: sc.clip, atFrame: 60, newIDs: (l, r)).addingLane(.audio, name: "A2", id: a2).relocating(clip: r, toStart: 30, lane: a2)
        XCTAssertEqual(Issue.blocking(overlap), [.overlappingSource(lane: overlap.laneLabel(sc.low), range: 0..<120, overlaps: [30..<60])])
        XCTAssertFalse(unset.laneLabel(sc.low).isEmpty)
    }
    // 11. 공급기의 오류에서: 만들 때의 거부, 원본 없음, 원본 바뀜, 한도, 취소
    func testProviderErrorsBecomeIssues() async throws {
        let m = try await media("a.wav", Fx.tone(440))
        let sc = try scene(m)
        let t = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 30, sourceKey: sc.key)
        let id = t.spectra[0].id, lane = t.laneLabel(sc.low)
        let unset = try sc.timeline.addingSpectrum(lane: sc.low, at: 0, length: 30, sourceKey: nil)
        XCTAssertThrowsError(try provider(unset, [m])) { XCTAssertEqual(Issue.issues(for: $0, timeline: unset), [.unsetSource(lane: lane, range: 0..<30)]) }
        XCTAssertThrowsError(try provider(t, [])) { XCTAssertEqual(Issue.issues(for: $0, timeline: t), [.originalUnavailable(lane: lane)]) }
        XCTAssertEqual(Issue.issues(for: SpectrumTimelineExportError.sourceChanged, timeline: t), [.originalChanged])
        XCTAssertEqual(Issue.issues(for: SpectrumTimelineExportError.frameMemoryBudgetExceeded(required: 9, limit: 1), timeline: t), [.resourceLimit])
        XCTAssertEqual(Issue.issues(for: SpectrumTimelineExportError.pcmBudgetExceeded(bytes: 9), timeline: t), [.resourceLimit])
        XCTAssertEqual(Issue.issues(for: SpectrumTimelineExportError.frameState(spectrum: id, frame: 3, state: .unset), timeline: t), [.unsetSource(lane: lane, range: 0..<30)])
        XCTAssertEqual(Issue.issues(for: SpectrumTimelineExportError.closed, timeline: t), [.internalFailure])
        XCTAssertEqual(Issue.issues(for: CancellationError(), timeline: t), [], "취소는 이유가 아니다")
        XCTAssertEqual(Issue.issues(for: SpectrumAnalysisError.cancelled, timeline: t), [])
        XCTAssertEqual(Issue.issues(for: SpectrumAnalysisError.decodeFailed("x"), timeline: t), [.internalFailure])
    }
    // 12. 한국어 글: 어느 스펙트럼인지(레인·시각), 무엇이 문제인지, 무엇을 하면 되는지. 원시 오류를 싣지 않는다
    func testKoreanMessagesNameTheSpectrumAndTheRemedy() {
        let unset = Issue.unsetSource(lane: "SP1", range: 0..<150).message
        XCTAssertTrue(unset.contains("SP1") && unset.contains("0:00~0:05") && unset.contains("소스를 고르") && unset.contains("내보낼 수 없습니다"), unset)
        let missing = Issue.missingSource(lane: "SP2", range: 1800..<1950).message
        XCTAssertTrue(missing.contains("SP2") && missing.contains("1:00~1:05") && missing.contains("타임라인에 없") && missing.contains("삭제"), missing)
        let overlap = Issue.overlappingSource(lane: "SP1", range: 0..<120, overlaps: [30..<60]).message
        XCTAssertTrue(overlap.contains("겹쳐") && overlap.contains("0:01~0:02") && overlap.contains("옮기"), overlap)
        let unavailable = Issue.originalUnavailable(lane: "SP1").message
        XCTAssertTrue(unavailable.contains("SP1") && unavailable.contains("원본") && unavailable.contains("다시 연결"), unavailable)
        XCTAssertTrue(Issue.originalChanged.message.contains("바뀌었"))
        XCTAssertTrue(Issue.resourceLimit.message.contains("메모리") && Issue.resourceLimit.message.contains("줄여"))
        let all: [Issue] = [.unsetSource(lane: "", range: 0..<1), .missingSource(lane: "SP1", range: 0..<1), .overlappingSource(lane: "SP1", range: 0..<1, overlaps: []),
                            .originalUnavailable(lane: ""), .originalChanged, .resourceLimit, .internalFailure]
        for issue in all {
            let text = issue.message
            XCTAssertFalse(text.isEmpty); XCTAssertTrue(text.hasSuffix("."), text)
            XCTAssertFalse(text.contains("Internal") || text.contains("Error") || text.contains("()"), "원시 오류나 빈 괄호가 없다: \(text)")
        }
        XCTAssertEqual(Issue.clock(0), "0:00"); XCTAssertEqual(Issue.clock(29), "0:00"); XCTAssertEqual(Issue.clock(1830), "1:01"); XCTAssertEqual(Issue.span(90..<3600), "0:03~2:00")
    }
}
