import CoreMedia
import Foundation

/// 타임라인·출력 설정(M1 기본값, A-005). 실험 설정·제품 정책이 아니다(O-03, O-04 미정).
public struct RenderSettings: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    public var fps: Int32
    public init(width: Int = 1920, height: Int = 1080, fps: Int32 = 30) { self.width = width; self.height = height; self.fps = fps }
    public static let m1 = RenderSettings()
    public var frameDuration: CMTime { CMTime(value: 1, timescale: fps) }
    public var renderSize: CGSize { CGSize(width: width, height: height) }
    public func time(_ frame: Int) -> CMTime { CMTime(value: CMTimeValue(frame), timescale: fps) }
    /// 시각 → 그 시각을 포함하는 프레임(내림)
    public func frame(containing t: CMTime) -> Int {
        guard t.isNumeric else { return 0 }
        return Int((Int64(t.value) * Int64(fps)) / Int64(t.timescale)) - ((Int64(t.value) * Int64(fps)) % Int64(t.timescale) < 0 ? 1 : 0)
    }
    /// 시각 → 가장 가까운 프레임
    public func nearestFrame(_ t: CMTime) -> Int {
        guard t.isNumeric else { return 0 }
        let v = Int64(t.value) * Int64(fps), ts = Int64(t.timescale)
        return Int((2 * v + ts) / (2 * ts))
    }
    /// 타임코드 HH:MM:SS:FF
    public func timecode(_ frame: Int) -> String {
        let f = max(0, frame), fp = Int(fps)
        let s = f / fp
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, f % fp)
    }
}
