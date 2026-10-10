import CoreMedia
import Foundation

/// E2 실험 설정. 실험용 값이며 제품 포맷 한계·사양이 아니다(O-03, O-04, O-05).
public enum Spec4K {
    // 출력·소스 영상
    public static let width = 3840
    public static let height = 2160
    public static let fps: Int32 = 30
    public static let frameDuration = CMTime(value: 1, timescale: 30)
    public static let sampleRate = 48_000

    // 인코딩(실험용)
    public static let sourceVideoBitRate = 30_000_000
    public static let exportVideoBitRate = 40_000_000
    public static let aacBitRate = 192_000

    /// 프레임 n의 시각(정수 유리수)
    public static func frameTime(_ n: Int) -> CMTime { CMTime(value: CMTimeValue(n), timescale: fps) }

    // MARK: 소스 영상 배치(위쪽-왼쪽 원점, 픽셀). 소스 fixture가 그린다.
    public static let cellSize = 96, cellPitch = 112, cellLeft = 80
    public static let sourceIDRowY = 200          // 소스 ID 8비트
    public static let sourceIDBits = 8
    public static let sourceFrameRowY = 340       // 소스 프레임 번호 16비트
    public static let codeBits = 16
    public static let boxY = 600, boxSize = 160, boxStep = 24, boxTravel = 2800
    public static let boxScanY = 680
    public static let gridPitch = 240, gridLine = 4
    /// 소스 배경 색 측정 위치(막대·격자·코드와 겹치지 않는 곳)
    public static let bgPatch = CGRect(x: 184, y: 1484, width: 32, height: 32)

    /// 이동 상자의 왼쪽 x(소스 프레임 f)
    public static func boxX(_ f: Int) -> Int { cellLeft + (f * boxStep) % boxTravel }

    // MARK: 합성기 오버레이(타임라인 프레임 코드, 스펙트럼, 자막)
    public static let timelineCodeRowY = 40
    public static let bandCount = 32
    public static let barsLeft = 320, barSlot = 100, barInset = 14, barWidth = 72
    public static let barBaselineY = 1780, barMaxHeight = 960
    public static let captionTop = 1850, captionBottom = 2060
    public static let captionBaselineY = 2000
    public static let captionFontName = "AppleSDGothicNeo-Bold"
    public static let captionFontSize: CGFloat = 96
    public static let captionMarginX = 160

    public static func barLeft(_ band: Int) -> Int { barsLeft + band * barSlot + barInset }
    public static func barHeight(forValue v: Float) -> Int {
        Int((Double(max(0, min(1, v))) * Double(barMaxHeight)).rounded(.toNearestOrEven))
    }
    /// 자막 측정 영역(정렬별 화면 3등분)
    public static func captionRect(_ alignment: CaptionAlignment) -> CGRect {
        let third = width / 3
        let x = alignment == .left ? 0 : alignment == .center ? third : 2 * third
        return CGRect(x: x, y: captionTop, width: third, height: captionBottom - captionTop)
    }

    // 색 (R, G, B)
    public static let codeOn: (UInt8, UInt8, UInt8) = (235, 235, 235)
    public static let codeOff: (UInt8, UInt8, UInt8) = (0, 0, 0)
    public static let barColor: (UInt8, UInt8, UInt8) = (64, 200, 255)
}

public enum CaptionAlignment: String, Codable, Sendable { case left, center, right }
