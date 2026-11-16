import Foundation
@testable import OnTheFrameEngine
import XCTest

/// 2026-10-23 전체 검토: 숫자 칸 변환이 큰 값·숫자 아님에서 멈추지 않고, 범위 안 정수가 되거나 거부된다.
final class NumericInputTests: XCTestCase {
    func testRejectsNonFiniteAndClampsBeforeConversion() {
        let size = 80...3000   // 자막 크기(0.1 pt)
        for bad in [Double.nan, .infinity, -.infinity, .signalingNaN] { XCTAssertNil(NumericInput.scaledInt(bad, scale: 10, range: size), "\(bad)") }
        XCTAssertEqual(NumericInput.scaledInt(1e308, scale: 10, range: size), 3000)        // 곱하면 무한이 되는 값
        XCTAssertEqual(NumericInput.scaledInt(-1e308, scale: 10, range: size), 80)
        XCTAssertEqual(NumericInput.scaledInt(.greatestFiniteMagnitude, scale: 1000, range: 0...1_920_000), 1_920_000)
        XCTAssertEqual(NumericInput.scaledInt(1e20, scale: 30, range: 0...300), 300)         // 정수 범위를 넘는 곱
        XCTAssertEqual(NumericInput.scaledInt(-5, scale: 30, range: 0...300), 0)
        // 보통 소수·반올림·경계
        XCTAssertEqual(NumericInput.scaledInt(48, scale: 10, range: size), 480)
        XCTAssertEqual(NumericInput.scaledInt(12.34, scale: 10, range: size), 123)
        XCTAssertEqual(NumericInput.scaledInt(12.35, scale: 10, range: size), 124)
        XCTAssertEqual(NumericInput.scaledInt(8, scale: 10, range: size), 80)
        XCTAssertEqual(NumericInput.scaledInt(300, scale: 10, range: size), 3000)
        XCTAssertEqual(NumericInput.scaledInt(7.99, scale: 10, range: size), 80)
        XCTAssertEqual(NumericInput.scaledInt(300.04, scale: 10, range: size), 3000)
        XCTAssertEqual(NumericInput.scaledInt(-12.5, scale: 10, range: -1000...1000), -125)
        // 불투명도는 이전 식(% × 255 / 100)을 그대로 쓰고 입력만 맞춘다: 50% → 128(× 2.55로 곱하면 127이 되어 이전과 달라짐)
        XCTAssertEqual(NumericInput.clamped(50, 0, 100).map { Int(($0 * 255 / 100).rounded()) }, 128)
        XCTAssertEqual(NumericInput.clamped(1e308, 0, 100), 100); XCTAssertEqual(NumericInput.clamped(-3, 0, 100), 0)
        XCTAssertNil(NumericInput.clamped(.nan, 0, 100)); XCTAssertNil(NumericInput.clamped(-.infinity, 0, 100))
        XCTAssertEqual(NumericInput.scaledInt(1.5, scale: 30, range: 0...300), 45)             // 페이드 1.5초 → 45프레임
        // 정수 끝 범위도 멈추지 않음
        XCTAssertEqual(NumericInput.scaledInt(1e300, scale: 1, range: Int.min...Int.max), Int.max)
        XCTAssertEqual(NumericInput.scaledInt(-1e300, scale: 1, range: Int.min...Int.max), Int.min)
        XCTAssertNil(NumericInput.scaledInt(1, scale: 0, range: 0...10))
        // 글자 읽기
        XCTAssertEqual(NumericInput.number(" 12.5 "), 12.5)
        for t in ["nan", "inf", "-inf", "", "abc", "1e400"] { XCTAssertNil(NumericInput.number(t), t) }
    }
}
