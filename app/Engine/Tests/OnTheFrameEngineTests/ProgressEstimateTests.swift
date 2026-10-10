import OnTheFrameEngine
import XCTest

/// 내보내기 경과·남은 시간 추정(A-011). 시각과 진행률을 테스트가 직접 준다(실제 시계·인코딩 없음).
final class ProgressEstimateTests: XCTestCase {
    /// t0부터 dt 간격으로 진행률 표본을 넣는다
    func feed(_ e: inout ExportTimeEstimator, from t0: Double, to t1: Double, dt: Double = 0.1, rate: Double, startP: Double) -> Double {
        var t = t0, p = startP
        while t < t1 - 1e-9 { t += dt; p += rate * dt; e.record(progress: p, at: t) }
        return p
    }
    func approx(_ r: ExportTimeEstimator.Remaining) -> Double? { if case .approx(let s) = r { return s }; return nil }

    func testInitialUnknownThenSteadyEstimate() {
        var e = ExportTimeEstimator()
        e.reset(at: 100)
        XCTAssertEqual(e.remaining(at: 100), .calculating)          // 준비 단계
        e.setStage(.encoding)
        XCTAssertEqual(e.remaining(at: 100.5), .calculating)        // 표본 없음
        // 초당 0.02(약 50초 인코딩). 2초 뒤: 시작 뒤 3초 미만 → 아직 계산 중(진행률 0.04로 나누지 않음)
        var p = feed(&e, from: 100, to: 102, rate: 0.02, startP: 0)
        XCTAssertEqual(e.remaining(at: 102), .calculating)
        p = feed(&e, from: 102, to: 110, rate: 0.02, startP: p)
        let r = approx(e.remaining(at: 110))
        XCTAssertNotNil(r)
        XCTAssertEqual(r ?? 0, (0.99 - p) / 0.02, accuracy: 0.5)     // 약 44.5초
        XCTAssertEqual(e.elapsed(at: 110), 10, accuracy: 1e-9)
    }

    func testNearZeroProgressIsNotDivided() {
        var e = ExportTimeEstimator()
        e.reset(at: 0); e.setStage(.encoding)
        _ = feed(&e, from: 0, to: 20, rate: 0.0005, startP: 0)       // 20초에 0.01: 최소 진행률 미만
        XCTAssertEqual(e.remaining(at: 20), .calculating)
    }

    func testShortFluctuationSmoothedButSustainedSlowdownShows() {
        var e = ExportTimeEstimator()
        e.reset(at: 0); e.setStage(.encoding)
        var p = feed(&e, from: 0, to: 10, rate: 0.02, startP: 0)
        let steady = approx(e.remaining(at: 10))!
        // 짧은 흔들림: 0.5초 동안 4배 빠름 → 창(5초) 평균이라 추정이 크게 흔들리지 않는다
        p = feed(&e, from: 10, to: 10.5, rate: 0.08, startP: p)
        let afterBurst = approx(e.remaining(at: 10.5))!
        XCTAssertLessThan(abs(afterBurst - (0.99 - p) / 0.02) / ((0.99 - p) / 0.02), 0.35, "burst \(afterBurst) steady \(steady)")
        // 계속된 느려짐: 초당 0.005로 6초(창보다 김) → 추정이 새 속도를 따른다
        p = feed(&e, from: 10.5, to: 16.5, rate: 0.005, startP: p)
        let slow = approx(e.remaining(at: 16.5))!
        XCTAssertEqual(slow, (0.99 - p) / 0.005, accuracy: (0.99 - p) / 0.005 * 0.05)
        XCTAssertGreaterThan(slow, steady)
    }

    func testStallFallsBackToCalculatingAndRecovers() {
        var e = ExportTimeEstimator()
        e.reset(at: 0); e.setStage(.encoding)
        var p = feed(&e, from: 0, to: 10, rate: 0.02, startP: 0)
        XCTAssertNotNil(approx(e.remaining(at: 10)))
        // 진행률이 멈춤(같은 값 표본만): 멈춘 지 5초 넘으면 계산 중(0으로 나눈 무한대·고정된 옛 추정을 보이지 않음)
        for k in 1...70 { e.record(progress: p, at: 10 + Double(k) * 0.1) }
        XCTAssertNotEqual(e.remaining(at: 14), .calculating)          // 4초: 아직 추정(늘어남)
        XCTAssertGreaterThan(approx(e.remaining(at: 14)) ?? 0, approx(e.remaining(at: 10)) ?? 0)
        XCTAssertEqual(e.remaining(at: 17), .calculating)
        p = feed(&e, from: 17, to: 23, rate: 0.02, startP: p)          // 다시 진행
        XCTAssertNotNil(approx(e.remaining(at: 23)))
        // 줄어든 값·비유한 값은 표본으로 쓰지 않는다
        let n = e.samples.count
        e.record(progress: p - 0.1, at: 23.1); e.record(progress: .nan, at: 23.2)
        XCTAssertEqual(e.samples.count, n)
    }

    func testFinalizingAndCap() {
        var e = ExportTimeEstimator()
        e.reset(at: 0); e.setStage(.encoding)
        _ = feed(&e, from: 0, to: 10, rate: 0.02, startP: 0)
        e.record(progress: 0.99, at: 10.1)                            // 인코딩 진행률 상한
        XCTAssertEqual(e.remaining(at: 10.2), .finalizing)            // "0초 남음"이 아님
        e.setStage(.finalizing)                                       // 검증·승격
        XCTAssertEqual(e.remaining(at: 12), .finalizing)
        XCTAssertEqual(ClockText.remaining(.finalizing), "마무리 중…")
        XCTAssertEqual(e.progress, 0.99)                              // 추정은 진행률을 올리지 않는다
    }

    func testResetBetweenExports() {
        var e = ExportTimeEstimator()
        e.reset(at: 0); e.setStage(.encoding)
        _ = feed(&e, from: 0, to: 10, rate: 0.05, startP: 0)
        e.setStage(.finalizing)
        e.reset(at: 50)
        XCTAssertEqual(e.stage, .preparing); XCTAssertEqual(e.progress, 0); XCTAssertEqual(e.samples.count, 1)
        XCTAssertEqual(e.elapsed(at: 51), 1, accuracy: 1e-9)
        e.setStage(.encoding)
        XCTAssertEqual(e.remaining(at: 51), .calculating)
    }

    func testClockTextFormatting() {
        XCTAssertEqual(ClockText.elapsed(12.9), "경과 00:12")
        XCTAssertEqual(ClockText.remaining(.approx(seconds: 34.2)), "남은 시간 약 00:35")   // 남은 시간은 올림
        XCTAssertEqual(ClockText.remaining(.approx(seconds: 0.2)), "남은 시간 약 00:01")
        XCTAssertEqual(ClockText.remaining(.calculating), "남은 시간 계산 중…")
        XCTAssertEqual(ClockText.format(59 * 60 + 59), "59:59")
        XCTAssertEqual(ClockText.format(3600), "1:00:00")
        XCTAssertEqual(ClockText.format(3 * 3600 + 5 * 60 + 7), "3:05:07")
        XCTAssertEqual(ClockText.format(-5), "00:00"); XCTAssertEqual(ClockText.format(.infinity), "00:00")
    }
}
