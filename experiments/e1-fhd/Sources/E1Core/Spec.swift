import CoreMedia
import Foundation

/// E1-a fixture 설정. 실험용 값이며 제품 한계·사양이 아니다(O-03, O-04, O-05).
public enum Spec {
    // 출력
    public static let width = 1920
    public static let height = 1080
    public static let fps: Int32 = 30
    public static let frameCount = 300                       // 10초
    public static let duration = CMTime(value: 10, timescale: 1)

    // 오디오
    public static let sampleRate = 48_000
    public static let channels = 2

    // 스펙트럼 분석 (실험 변수, 결과에 기록)
    public static let fftLog2n = 12
    public static let fftSize = 4096                          // 85.33 ms
    public static let hop = 400                               // 1/120 s
    public static let hopsPerSecond = 120
    public static let bandCount = 32
    public static let bandLowHz = 40.0
    public static let bandHighHz = 16_000.0
    public static let dbFloor = -80.0

    // 화면 배치 (위쪽-왼쪽 원점, 픽셀)
    public static let barsLeft = 160
    public static let barSlot = 50
    public static let barInset = 7
    public static let barWidth = 36
    public static let barBaselineY = 880                      // 막대는 [880 - h, 880) 행을 채운다
    public static let barMaxHeight = 480
    public static let captionBaselineY = 1000
    public static let captionFontName = "AppleSDGothicNeo-Bold"
    public static let captionFontSize: CGFloat = 64
    public static let captionText = "온더프레임 테스트 — 가나다 ABC 123"
    public static let captionStart = CMTime(value: 2, timescale: 1)
    public static let captionEnd = CMTime(value: 8, timescale: 1)  // 반열린 구간 [2, 8)
    public static let codeX = 40, codeY = 40, codeCell = 40, codePitch = 48, codeBits = 16
    public static let gridPitch = 120, gridLine = 2

    // 색 (R, G, B)
    public static let bgColor: (UInt8, UInt8, UInt8) = (18, 20, 28)
    public static let gridColor: (UInt8, UInt8, UInt8) = (38, 42, 56)
    public static let barColor: (UInt8, UInt8, UInt8) = (64, 200, 255)
    public static let codeOn: (UInt8, UInt8, UInt8) = (235, 235, 235)
    public static let codeOff: (UInt8, UInt8, UInt8) = (0, 0, 0)

    // 인코딩 (실험용)
    public static let videoBitRate = 12_000_000
    public static let aacBitRate = 192_000

    /// 프레임 n의 시각. 부동소수점 초를 쓰지 않는다.
    public static func frameTime(_ n: Int) -> CMTime { CMTime(value: CMTimeValue(n), timescale: fps) }

    public static func barLeft(_ band: Int) -> Int { barsLeft + band * barSlot + barInset }
    public static func barHeight(forValue v: Float) -> Int {
        Int((Double(max(0, min(1, v))) * Double(barMaxHeight)).rounded(.toNearestOrEven))
    }
}
