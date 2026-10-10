import Accelerate
import AVFoundation
import CoreMedia
import Foundation

public struct SpectrumParams: Codable, Equatable, Sendable {
    public var fftSize = Spec.fftSize
    public var hop = Spec.hop
    public var sampleRate = Spec.sampleRate
    public var bandCount = Spec.bandCount
    public var bandLowHz = Spec.bandLowHz
    public var bandHighHz = Spec.bandHighHz
    public var dbFloor = Spec.dbFloor
    public var window = "hann(periodic)"
    /// 분석 창 [s − fftSize, s): 시각 s 이전 샘플만 본다(인과적). 실험 변수.
    public var windowAlignment = "trailing"
    /// 스테레오 처리(O-12 미결정): 실험에서는 (L+R)/2로 고정. 제품 결정 아님.
    public var channelMix = "mean(L,R)"
    /// 밴드 값 = 밴드 내 최대 bin 진폭(dB)을 [dbFloor, 0] → [0, 1]로 선형 대응
    public var bandValue = "max-bin-amplitude-dB-linear"
    public init() {}
}

/// 한 창의 FFT → 32밴드 값. 창 단위 계산만 하며 상태는 버퍼 재사용뿐이다.
public final class SpectrumKernel {
    public let params: SpectrumParams
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let hann: [Float]
    private var windowed: [Float]
    private var real: [Float], imag: [Float], mags: [Float]
    private let bandBins: [ClosedRange<Int>]

    public init(params: SpectrumParams = SpectrumParams()) {
        self.params = params
        let n = params.fftSize
        fft = vDSP.FFT(log2n: vDSP_Length(Int(log2(Double(n)))), radix: .radix2, ofType: DSPSplitComplex.self)!
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2); imag = real; mags = real
        let binHz = Double(params.sampleRate) / Double(n)
        let ratio = params.bandHighHz / params.bandLowHz
        bandBins = (0..<params.bandCount).map { b in
            let lo = params.bandLowHz * pow(ratio, Double(b) / Double(params.bandCount))
            let hi = params.bandLowHz * pow(ratio, Double(b + 1) / Double(params.bandCount))
            let kLo = max(1, Int((lo / binHz).rounded(.up)))
            let kHi = min(n / 2 - 1, Int((hi / binHz).rounded(.up)) - 1)
            if kLo <= kHi { return kLo...kHi }
            let c = Int((sqrt(lo * hi) / binHz).rounded())
            return c...c
        }
    }

    public var bandBinRanges: [ClosedRange<Int>] { bandBins }

    /// samples: 시간 순서의 모노 샘플 fftSize개. out: bandCount개.
    public func process(_ samples: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let n = params.fftSize
        windowed.withUnsafeMutableBufferPointer { w in
            vDSP_vmul(samples, 1, hann, 1, w.baseAddress!, 1, vDSP_Length(n))
        }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                mags.withUnsafeMutableBufferPointer { m in
                    vDSP_zvabs(&split, 1, m.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }
        // zrip 출력은 2·X_k. Hann 창에서 진폭 A인 사인의 |X_k| = A·N/4 → A = mag / (N/2).
        let norm = 2 / Float(n)
        let floor = params.dbFloor
        for (b, r) in bandBins.enumerated() {
            var peak: Float = 0
            for k in r where mags[k] > peak { peak = mags[k] }
            let amp = Double(peak * norm)
            let db = amp > 0 ? 20 * log10(amp) : -Double.infinity
            out[b] = Float(max(0, min(1, (db - floor) / -floor)))
        }
    }
}

/// 원본 시간 기준 스펙트럼 캐시. 인덱스 i = 창 끝 시각 i·hop / sampleRate.
/// 생성 후 바뀌지 않는다(모든 저장 속성 let) — 컴파일러가 확인하는 Sendable.
public final class SpectrumCache: Sendable {
    public let sourceID: String
    public let params: SpectrumParams
    public let values: [Float]       // hopCount × bandCount
    public let hopCount: Int

    public init(sourceID: String, params: SpectrumParams, values: [Float]) {
        self.sourceID = sourceID; self.params = params; self.values = values
        hopCount = values.count / params.bandCount
    }

    /// 원본 시각 s(정수 유리수 연산) → 창 인덱스 floor(s · sampleRate / hop). 원본 끝을 넘으면 nil.
    public func hopIndex(atSourceTime s: CMTime) -> Int? {
        guard s.isNumeric, s.value >= 0 else { return nil }
        let hopsPerSec = Int64(params.sampleRate / params.hop)
        let i = Int((Int64(s.value) * hopsPerSec) / Int64(s.timescale))
        return i < hopCount ? i : nil
    }

    public func bands(atSourceTime s: CMTime) -> ArraySlice<Float>? {
        guard let i = hopIndex(atSourceTime: s) else { return nil }
        let b = params.bandCount
        return values[(i * b)..<((i + 1) * b)]
    }
}

public struct AnalysisStats: Codable {
    public var sampleBuffers = 0
    public var maxBufferFrames = 0
    public var totalFrames = 0
    public var firstPTSSeconds: Double? = nil
    public var ptsContiguous = true
    public var hops = 0
    public var wallSeconds = 0.0
    public var peakFootprintBytes: UInt64 = 0
    public var fromCache = false
}

public enum SpectrumAnalyzer {
    /// 오디오 트랙들을 청크 단위로 읽어 분석한다. 메모리에는 창 1개 분량의 링 버퍼와
    /// 리더가 넘겨준 버퍼 1개만 둔다. 선택 소스 분석에서는 tracks에 S의 트랙만 넘긴다.
    public static func analyze(asset: AVAsset, tracks: [AVAssetTrack], timeRange: CMTimeRange?,
                               sourceID: String, params: SpectrumParams = SpectrumParams()) throws -> (SpectrumCache, AnalysisStats) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var stats = AnalysisStats()
        let reader = try AVAssetReader(asset: asset)
        if let r = timeRange { reader.timeRange = r }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: params.sampleRate, AVNumberOfChannelsKey: 2,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw E1Error.reader(reader.error?.localizedDescription ?? "startReading failed") }

        let n = params.fftSize, hop = params.hop
        let kernel = SpectrumKernel(params: params)
        var ring = [Float](repeating: 0, count: n)
        var linear = [Float](repeating: 0, count: n)
        var pos = 0, total = 0
        var values: [Float] = []
        var bandOut = [Float](repeating: 0, count: params.bandCount)
        var scratch: [Float] = []
        var expectedNextPTS: CMTime?

        func emit() {
            for j in 0..<n { linear[j] = ring[(pos + j) & (n - 1)] }
            linear.withUnsafeBufferPointer { l in bandOut.withUnsafeMutableBufferPointer { kernel.process(l.baseAddress!, into: $0.baseAddress!) } }
            values.append(contentsOf: bandOut)
            stats.hops += 1
        }
        emit()  // i = 0: 창이 시각 0에서 끝남 → 모두 0

        while let sb = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sb)
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if stats.firstPTSSeconds == nil { stats.firstPTSSeconds = pts.seconds }
            if let e = expectedNextPTS, pts != e { stats.ptsContiguous = false }
            expectedNextPTS = pts + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(params.sampleRate))
            stats.sampleBuffers += 1
            stats.maxBufferFrames = max(stats.maxBufferFrames, frames)
            let count = copyFloats(sb, into: &scratch)
            var i = 0
            while i + 1 < count {
                ring[pos] = 0.5 * (scratch[i] + scratch[i + 1])
                pos = (pos + 1) & (n - 1)
                total += 1
                if total % hop == 0 { emit() }
                i += 2
            }
            stats.peakFootprintBytes = max(stats.peakFootprintBytes, Memory.physFootprint())
        }
        if reader.status == .failed { throw E1Error.reader(reader.error?.localizedDescription ?? "reader failed") }
        stats.totalFrames = total
        stats.wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        return (SpectrumCache(sourceID: sourceID, params: params, values: values), stats)
    }

    /// 선택 소스 원본 파일 전체를 분석한다(원본 시간 기준). 디스크 캐시가 같은 원본·파라미터면 재사용.
    public static func analyzeSelectedSource(_ source: SourceRef, cacheDir: URL, params: SpectrumParams = SpectrumParams()) async throws -> (SpectrumCache, AnalysisStats) {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let paramsData = try JSONEncoder.sorted.encode(params)
        let key = "spectrum-\(source.id.prefix(16))-\(Hashing.sha256(paramsData).prefix(12))"
        let binURL = cacheDir.appendingPathComponent(key + ".f32")
        let metaURL = cacheDir.appendingPathComponent(key + ".json")
        if let meta = try? Data(contentsOf: metaURL),
           let m = try? JSONDecoder().decode(CacheMeta.self, from: meta),
           m.sourceID == source.id, m.params == params,
           let raw = try? Data(contentsOf: binURL), raw.count == m.count * 4 {
            let values = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            var st = AnalysisStats(); st.fromCache = true; st.hops = values.count / params.bandCount
            return (SpectrumCache(sourceID: source.id, params: params, values: values), st)
        }
        let asset = AVURLAsset(url: source.url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1 else { throw E1Error.invalidSource("expected 1 audio track in \(source.path), got \(tracks.count)") }
        let (cache, stats) = try analyze(asset: asset, tracks: tracks, timeRange: nil, sourceID: source.id, params: params)
        let raw = cache.values.withUnsafeBufferPointer { Data(buffer: $0) }
        try raw.write(to: binURL, options: .atomic)
        try JSONEncoder.sorted.encode(CacheMeta(sourceID: source.id, params: params, count: cache.values.count)).write(to: metaURL, options: .atomic)
        return (cache, stats)
    }

    struct CacheMeta: Codable { let sourceID: String; let params: SpectrumParams; let count: Int }
}

/// 인터리브 float32 샘플 버퍼를 scratch로 복사. scratch는 가장 큰 버퍼 크기까지만 자란다.
func copyFloats(_ sb: CMSampleBuffer, into buf: inout [Float]) -> Int {
    guard let bb = CMSampleBufferGetDataBuffer(sb) else { return 0 }
    let len = CMBlockBufferGetDataLength(bb)
    let n = len / 4
    if buf.count < n { buf = [Float](repeating: 0, count: n) }
    _ = buf.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
    return n
}

extension JSONEncoder {
    public static var sorted: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]; return e
    }
}
