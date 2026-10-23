import Foundation

/// 입력 칸의 소수 → 저장 정수(2026-10-23 전체 검토). 곱하거나 반올림하거나 정수로 바꾸기 전에 소수 공간에서 범위로 맞춘다.
/// 이전에는 곱한 뒤 정수로 바꾸고 나서 맞춰서 "1e308"·"nan" 같은 입력에 앱이 멈췄다(Int(Double)은 범위 밖·숫자 아님에서 멈춘다).
public enum NumericInput {
    /// value × scale을 반올림한 range 안 정수. 숫자가 아니거나 무한이면 nil(입력 거부, 칸은 지금 값으로 되돌린다).
    public static func scaledInt(_ value: Double, scale: Double, range: ClosedRange<Int>) -> Int? {
        guard value.isFinite, scale.isFinite, scale > 0 else { return nil }
        let v = min(max(value, Double(range.lowerBound) / scale), Double(range.upperBound) / scale)
        let r = (v * scale).rounded()
        // Double(Int.max)는 2⁶³으로 올라가므로 경계는 비교로만 쓰고, 그 안쪽 값만 Int로 바꾼다
        if r <= Double(range.lowerBound) { return range.lowerBound }
        if r >= Double(range.upperBound) { return range.upperBound }
        return Int(r)
    }
    /// 범위로 맞춘 소수(숫자가 아니거나 무한이면 nil). 이미 쓰던 식(예: 불투명도 % × 255 / 100)을 그대로 두고 그 입력만 안전하게 할 때.
    public static func clamped(_ value: Double, _ lo: Double, _ hi: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(value, lo), hi)
    }
    /// 칸 글자 → 소수(앞뒤 공백 무시). 숫자가 아니거나 무한이면 nil.
    public static func number(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
        return v
    }
}
