import CoreGraphics
import Foundation

/// 스펙트럼 한 층을 4:2:0 발자국으로 바꾸는 데 드는 메모리의 보수적 계산(SP-EXPORT-E3, 2026-11-23).
/// 수치는 SubtitleFootprint.init과 SpectrumFrameRenderer.ownedCopy의 실제 할당에서 가져왔다. 모든 계산은 넘치면 nil이다.
///
/// 그림 하나(놓는 사각형 w × h, 화소 A = w·h, 색차 표본 C):
/// - 그림: bytesPerRow · h(ownedCopy가 새로 할당한 Data). 발자국을 만들 때 `dataProvider.data`가 같은 크기를 한 번 더 복사할 수 있다.
/// - 만드는 동안: [Double] 넷(A, AY, ACb, ACr) = 4 · 8 · A.
/// - 밝기 배열 셋(yIdx Int32, ya Float, yaSub Float) = 원소당 12바이트, 원소 수 = 칠한 화소 수 P(알파 > 0, ≤ A).
/// - 색차 배열 넷(cIdx Int32, cWA·cWACb·cWACr Float) = 원소당 16바이트, 원소 수 ≤ min(C, 2P)
///   (칠한 화소 하나는 가로 탭 (−1, 0, +1) 때문에 색차 칸을 많아야 둘 건드린다).
/// - P는 그림을 한 번 훑어 센다(paintedPixels). 세지 않았으면 P = A로 본다(가장 나쁜 경우).
/// - 밝기·색차 배열은 append로 자란다. Swift 배열은 용량을 두 배로 늘리므로 남는 용량은 원소 수의 2배 미만,
///   늘리는 순간에는 옛 버퍼와 새 버퍼가 함께 있어 원소 수의 3배까지다.
/// 이 값은 이 공급기가 직접 만드는 버퍼의 상한이다. AVFoundation의 디코더·인코더·화소 버퍼 풀, 프로세스 전체 메모리는 포함하지 않는다.
enum SpectrumFootprintCost {
    static func mul(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b, a >= 0, b >= 0 else { return nil }
        let (v, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? nil : v
    }
    static func add(_ xs: Int?...) -> Int? {
        var total = 0
        for x in xs {
            guard let x, x >= 0 else { return nil }
            let (v, overflow) = total.addingReportingOverflow(x)
            if overflow { return nil }
            total = v
        }
        return total
    }
    static let doubleArrays = 4, lumaElementBytes = MemoryLayout<Int32>.stride + 2 * MemoryLayout<Float>.stride
    static let chromaElementBytes = MemoryLayout<Int32>.stride + 3 * MemoryLayout<Float>.stride
    /// 렌더러가 돌려줄 수 있는 가장 큰 그림(출력 화면 전체, 화소당 4바이트). 그리기 전의 검사에 쓴다.
    static var maxImageBytes: Int { SubtitleFootprint.w * SubtitleFootprint.h * 4 }
    static func imageBytes(bytesPerRow: Int, height: Int) -> Int? { mul(bytesPerRow, height) }
    static func imageBytes(_ image: CGImage) -> Int? { imageBytes(bytesPerRow: image.bytesPerRow, height: image.height) }
    /// SubtitleFootprint.init이 도는 색차 격자의 칸 수(같은 식: 열 k0…k1, 행 j0…j1). 화면 밖이면 0.
    static func chromaSamples(x0: Int, y0: Int, width iw: Int, height ih: Int) -> Int? {
        let bound = 1 << 30   // 이 안에서는 아래 덧셈이 넘치지 않는다
        guard iw >= 0, ih >= 0, iw <= bound, ih <= bound, x0.magnitude <= UInt(bound), y0.magnitude <= UInt(bound) else { return nil }
        let k0 = max(0, (x0 - 1) / 2 - 1), k1 = min(SubtitleFootprint.cw - 1, (x0 + iw + 1) / 2 + 1)
        let j0 = max(0, y0 / 2 - 1), j1 = min(SubtitleFootprint.ch - 1, (y0 + ih) / 2 + 1)
        guard k0 <= k1, j0 <= j1 else { return 0 }
        return mul(k1 - k0 + 1, j1 - j0 + 1)
    }
    /// 칠한 화소 수(알파 > 0 — SubtitleFootprint.init이 밝기 원소를 만드는 조건과 같다). 그림 바이트를 읽지 못하면 nil.
    static func paintedPixels(_ image: CGImage) -> Int? {
        guard image.bitsPerPixel == 32, let data = image.dataProvider?.data as Data? else { return nil }
        let w = image.width, h = image.height, bpr = image.bytesPerRow
        guard let need = imageBytes(bytesPerRow: bpr, height: h), data.count >= need, mul(w, 4).map({ $0 <= bpr }) == true else { return nil }
        var n = 0
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<h { let row = y * bpr; for x in 0..<w where p[row + x * 4 + 3] > 0 { n += 1 } }
        }
        return n
    }
    /// (밝기 원소 수, 색차 원소 수)의 상한. painted가 nil이면 모든 화소를 칠했다고 본다.
    static func elements(x0: Int, y0: Int, width: Int, height: Int, painted: Int?) -> (luma: Int, chroma: Int)? {
        guard let a = mul(width, height), let c = chromaSamples(x0: x0, y0: y0, width: width, height: height) else { return nil }
        if let painted, painted < 0 { return nil }
        let p = min(painted ?? a, a)
        return (p, min(c, mul(p, 2) ?? c))
    }
    /// 발자국 하나가 남기는 바이트의 상한(배열 용량 기준: 원소 수의 2배 미만)
    static func retainedBound(x0: Int, y0: Int, width: Int, height: Int, painted: Int? = nil) -> Int? {
        guard let e = elements(x0: x0, y0: y0, width: width, height: height, painted: painted) else { return nil }
        return add(mul(mul(e.luma, lumaElementBytes), 2), mul(mul(e.chroma, chromaElementBytes), 2))
    }
    /// 발자국 하나를 만드는 동안 함께 살아 있는 바이트의 상한(그림, 그 복사, Double 배열, 자라는 밝기·색차 배열)
    static func constructionPeak(imageBytes: Int?, x0: Int, y0: Int, width: Int, height: Int, painted: Int? = nil) -> Int? {
        guard let e = elements(x0: x0, y0: y0, width: width, height: height, painted: painted) else { return nil }
        return add(imageBytes, imageBytes, mul(mul(mul(width, height), MemoryLayout<Double>.stride), doubleArrays),
                   mul(mul(e.luma, lumaElementBytes), 3), mul(mul(e.chroma, chromaElementBytes), 3))
    }
    static func constructionPeak(_ r: SpectrumRenderedFrame, painted: Int? = nil) -> Int? {
        constructionPeak(imageBytes: imageBytes(r.image), x0: Int(r.drawRect.minX), y0: Int(r.drawRect.minY), width: r.image.width, height: r.image.height,
                         painted: painted)
    }
}

extension SubtitleFootprint {
    /// 이 발자국이 붙잡고 있는 배열 바이트(용량 기준 — 실제 할당)
    var retainedBytes: Int {
        (yIdx.capacity + cIdx.capacity) * MemoryLayout<Int32>.stride
            + (ya.capacity + yaSub.capacity + cWA.capacity + cWACb.capacity + cWACr.capacity) * MemoryLayout<Float>.stride
    }
}

/// 프레임 하나의 메모리 장부: 지금 붙잡고 있는 양(retained)에 곧 필요한 양(transient)을 더한 값이 한도를 넘으면 할당하기 전에 거부한다.
/// peak는 그 프레임에서 허락한 동시 사용량의 최대다(누적 합이 아니다).
struct SpectrumFrameBudget: Equatable, Sendable {
    let limit: Int
    private(set) var retained = 0, peak = 0
    init(limit: Int) { self.limit = limit }
    /// 곧 할당할 양을 허락받는다(붙잡는 양은 바꾸지 않는다)
    mutating func admit(transient: Int?) throws {
        guard let need = SpectrumFootprintCost.add(retained, transient), need <= limit else {
            throw SpectrumTimelineExportError.frameMemoryBudgetExceeded(required: SpectrumFootprintCost.add(retained, transient) ?? Int.max, limit: limit)
        }
        peak = max(peak, need)
    }
    /// 만든 것을 프레임이 끝날 때까지 붙잡는다
    mutating func retain(_ bytes: Int?) throws {
        guard let total = SpectrumFootprintCost.add(retained, bytes), total <= limit else {
            throw SpectrumTimelineExportError.frameMemoryBudgetExceeded(required: SpectrumFootprintCost.add(retained, bytes) ?? Int.max, limit: limit)
        }
        retained = total; peak = max(peak, total)
    }
}

/// 마지막 프레임의 장부 요약(시험·진단용). 계산한 상한이며 프로세스 메모리 측정이 아니다.
struct SpectrumFrameMemoryReport: Equatable, Sendable {
    var layers = 0, retainedBytes = 0, peakBytes = 0
}
