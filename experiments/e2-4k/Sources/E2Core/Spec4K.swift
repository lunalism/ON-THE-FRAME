import CoreMedia
import Foundation

/// 화면 배치 크기. 모든 배치 값은 4K 기준 값을 divisor로 나눈다(4K 값이 모두 짝수라 FHD에서 정확히 반이 된다).
public struct FrameLayout: Sendable, Codable, Equatable {
    public let divisor: Int
    public let sourceVideoBitRate: Int
    public let exportVideoBitRate: Int
    /// E2: 3840×2160
    public static let uhd = FrameLayout(divisor: 1, sourceVideoBitRate: 30_000_000, exportVideoBitRate: 40_000_000)
    /// E3-1: 1920×1080(출력 10 Mbps, EXPERIMENT-PLAN §7.6 가정)
    public static let fhd = FrameLayout(divisor: 2, sourceVideoBitRate: 10_000_000, exportVideoBitRate: 10_000_000)
}

/// E2·E3 실험 설정. 실험용 값이며 제품 포맷 한계·사양이 아니다(O-03, O-04, O-05).
/// 이름은 E2(4K)에서 왔다. 2026-10-10(A-004)부터 배치 값은 프로세스 시작 때 한 번 정하는 `FrameLayout`을 따른다.
/// 기본은 4K(.uhd)이므로 E2의 값은 바뀌지 않는다.
public enum Spec4K {
    // 안전성: 실행기의 첫 줄에서, 다른 작업(스레드·AVFoundation 객체)이 시작되기 전에 한 번만 쓴다. 이후에는 읽기만 한다.
    nonisolated(unsafe) private static var _layout = FrameLayout.uhd
    public static func configure(_ l: FrameLayout) { _layout = l }
    public static var layout: FrameLayout { _layout }
    static var d: Int { _layout.divisor }

    // 출력·소스 영상
    public static var width: Int { 3840 / d }
    public static var height: Int { 2160 / d }
    public static let fps: Int32 = 30
    public static let frameDuration = CMTime(value: 1, timescale: 30)
    public static let sampleRate = 48_000

    // 인코딩(실험용)
    public static var sourceVideoBitRate: Int { _layout.sourceVideoBitRate }
    public static var exportVideoBitRate: Int { _layout.exportVideoBitRate }
    public static let aacBitRate = 192_000

    /// 프레임 n의 시각(정수 유리수)
    public static func frameTime(_ n: Int) -> CMTime { CMTime(value: CMTimeValue(n), timescale: fps) }

    // MARK: 소스 영상 배치(위쪽-왼쪽 원점, 픽셀). 소스 fixture가 그린다.
    public static var cellSize: Int { 96 / d }
    public static var cellPitch: Int { 112 / d }
    public static var cellLeft: Int { 80 / d }
    public static var sourceIDRowY: Int { 200 / d }       // 소스 ID 8비트
    public static let sourceIDBits = 8
    public static var sourceFrameRowY: Int { 340 / d }    // 소스 프레임 번호 16비트
    public static let codeBits = 16
    public static var boxY: Int { 600 / d }
    public static var boxSize: Int { 160 / d }
    public static var boxStep: Int { 24 / d }
    public static var boxTravel: Int { 2800 / d }
    public static var boxScanY: Int { 680 / d }
    public static var gridPitch: Int { 240 / d }
    public static var gridLine: Int { 4 / d }
    /// 소스 배경 색 측정 위치(막대·격자·코드와 겹치지 않는 곳)
    public static var bgPatch: CGRect { CGRect(x: 184 / d, y: 1484 / d, width: 32 / d, height: 32 / d) }
    /// 플래시 띠(소스가 플래시 프레임에만 그림, E3)와 그 측정 위치. 막대 영역 왼쪽, 상자 행 아래.
    public static var flashBandY: Int { 800 / d }
    public static var flashBandHeight: Int { 64 / d }
    public static var flashPatch: CGRect { CGRect(x: 184 / d, y: 816 / d, width: 32 / d, height: 32 / d) }
    /// 코드 칸 밝기를 읽는 가운데 영역 한 변
    public static var codeSample: Int { 24 / d }

    /// 이동 상자의 왼쪽 x(소스 프레임 f)
    public static func boxX(_ f: Int) -> Int { cellLeft + (f * boxStep) % boxTravel }

    // MARK: 합성기 오버레이(타임라인 프레임 코드, 스펙트럼, 자막)
    public static var timelineCodeRowY: Int { 40 / d }
    public static let bandCount = 32
    public static var barsLeft: Int { 320 / d }
    public static var barSlot: Int { 100 / d }
    public static var barInset: Int { 14 / d }
    public static var barWidth: Int { 72 / d }
    public static var barBaselineY: Int { 1780 / d }
    public static var barMaxHeight: Int { 960 / d }
    public static var captionTop: Int { 1850 / d }
    public static var captionBottom: Int { 2060 / d }
    public static var captionBaselineY: Int { 2000 / d }
    public static let captionFontName = "AppleSDGothicNeo-Bold"
    public static var captionFontSize: CGFloat { CGFloat(96 / d) }
    public static var captionMarginX: Int { 160 / d }
    /// 막대 측정: 가운데 열 좌우 표본 거리, 기준선 위 허용 번짐 행 수
    public static var barSideOffset: Int { 16 / d }
    public static var barBaseTolerance: Int { 6 / d }

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
