// 스펙트럼 타당성 검사 시제품(2026-10-24, docs/SPECTRUM-DESIGN.md §9) — 제품 코드가 아니다.
// 엔진 시험 대상과 앱 Debug 실험(app/OnTheFrame/SpectrumProto/의 기호 링크, -OTFSpectrumPreviewTest)이 같은 원본을 쓴다. Debug에서만 컴파일된다
// (release 설정 측정은 -Xswiftc -DOTF_PROTO_RELEASE). 공개 엔진 API만 쓴다.
#if DEBUG || OTF_PROTO_RELEASE
import Accelerate
import AVFoundation
import Foundation
import OnTheFrameEngine

/// 프레임 ↔ 표본: 프로젝트 fps와 표본율로 정수 계산(반올림은 절반 올림). 48 kHz·30 fps에서만 1600/프레임으로 나누어떨어진다.
enum ProtoFrameMap {
    static func sample(atFrame k: Int, fps: Int, rate: Int) -> Int { (2 * k * rate + fps) / (2 * fps) }
    static func frame(containingSample n: Int, fps: Int, rate: Int) -> Int { Int((Int64(n) * Int64(fps)).quotientAndFloor(Int64(rate))) }
}
private extension Int64 { func quotientAndFloor(_ d: Int64) -> Int64 { let q = self / d; return (self % d != 0 && (self < 0) != (d < 0)) ? q - 1 : q } }

/// 원본 표본 덩어리 읽기: 원본 시각을 고정 격자(chunk 표본)로 나누고, 덩어리마다 새 리더로 [앞 여유, 뒤 여유]를 붙여 읽은 뒤 가운데만 쓴다.
/// 같은 덩어리는 늘 같은 범위로 디코딩한다(결정성). 결과: 채널별 Float 배열(덩어리 길이, 파일 밖은 0).
final class ProtoPCMSource: @unchecked Sendable {
    let url: URL, rate: Int, chunk: Int, margin: Int
    private(set) var decodes = 0
    private(set) var firstPTSOffsets: [Int] = []   // 요청 시작 대비 첫 버퍼 PTS(표본) — 기록
    init(url: URL, rate: Int = 48_000, chunk: Int = 8 * 48_000, margin: Int = 48_000) { self.url = url; self.rate = rate; self.chunk = chunk; self.margin = margin }
    func decode(chunkIndex c: Int) throws -> [[Float]] { try decodeRange(c * chunk - margin, (c + 1) * chunk + margin, keep: c * chunk ..< (c + 1) * chunk) }
    /// [a, b) 표본을 읽어 keep 범위만 돌려줌(채널별)
    func decodeRange(_ a0: Int, _ b: Int, keep: Range<Int>) throws -> [[Float]] {
        decodes += 1
        let a = max(0, a0)
        let asset = AVURLAsset(url: url)
        let track = try sync { try await asset.loadTracks(withMediaType: .audio).first }
        guard let track else { return [[Float](repeating: 0, count: keep.count)] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(a), timescale: CMTimeScale(rate)), end: CMTime(value: CMTimeValue(b), timescale: CMTimeScale(rate)))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVLinearPCMBitDepthKey: 32,
                                                                         AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "proto", code: 1) }
        var chans: [[Float]] = []
        var first = true
        while let sb = out.copyNextSampleBuffer() {
            guard let fmt = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { continue }
            let ch = Int(asbd.mChannelsPerFrame), n = CMSampleBufferGetNumSamples(sb)
            if chans.isEmpty { chans = Array(repeating: [Float](repeating: 0, count: keep.count), count: ch) }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let start = Int((pts.value * CMTimeValue(rate) + CMTimeValue(pts.timescale) / 2) / CMTimeValue(pts.timescale))
            if first { firstPTSOffsets.append(start - a); first = false }
            var abl = AudioBufferList(), blk: CMBlockBuffer?
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
                                                                    blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blk)
            guard let p = abl.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<n {
                let s = start + i
                guard keep.contains(s) else { continue }
                for c in 0..<ch { chans[c][s - keep.lowerBound] = p[i * ch + c] }
            }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "proto", code: 2) }
        return chans.isEmpty ? [[Float](repeating: 0, count: keep.count)] : chans
    }
    private func sync<T>(_ f: @escaping () async throws -> T) throws -> T {
        nonisolated(unsafe) var r: Result<T, Error>?
        let sem = DispatchSemaphore(value: 0)
        Task { do { r = .success(try await f()) } catch { r = .failure(error) }; sem.signal() }
        sem.wait()
        return try r!.get()
    }
}

/// 분석 매개변수(정수, 결정적)
struct ProtoSpectrumParams: Hashable {
    var windowMs = 90, offsetMs = 0, bands = 64, fLo = 20, fHi = 2000, floorDB = -60
}

/// 한 스펙트럼 조각(색인 결과) + 그 클립의 소리 설정 + 레인 이득 — 이득은 표본마다(페이드가 창 안에서 바뀜)
struct ProtoPiece {
    let start: Int, length: Int, sourceIn: Int
    let audio: ClipAudio
    let laneGain: Double
    var end: Int { start + length }
}

/// 분석기: 같은 입력(조각, 매개변수, 프레임) → 같은 값. 덩어리 캐시는 바이트 상한 LRU(시제품: 단순).
final class ProtoAnalyzer: @unchecked Sendable {
    let source: ProtoPCMSource, fps: Int, params: ProtoSpectrumParams
    let n: Int, m: Int, log2m: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var cache: [Int: [[Float]]] = [:], order: [Int] = []
    let cacheChunks: Int
    var cachedBytes: Int { cache.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count * 4 } } }
    init(source: ProtoPCMSource, fps: Int = 30, params: ProtoSpectrumParams = .init(), cacheChunks: Int = 4) {
        self.source = source; self.fps = fps; self.params = params; self.cacheChunks = cacheChunks
        n = params.windowMs * source.rate / 1000
        var l = 1; while (1 << l) < n { l += 1 }
        log2m = l; m = 1 << l
        fft = vDSP.FFT(log2n: vDSP_Length(l), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    }
    func chunkData(_ c: Int) throws -> [[Float]] {
        if let d = cache[c] { order.removeAll { $0 == c }; order.append(c); return d }
        let d = try source.decode(chunkIndex: c)
        cache[c] = d; order.append(c)
        while order.count > cacheChunks { cache[order.removeFirst()] = nil }
        return d
    }
    /// 원본 표본 s의 채널 값들(파일 밖·덩어리 밖은 0)
    func samples(_ s: Int) throws -> [Float] {
        guard s >= 0 else { return [0] }
        let c = s / source.chunk, d = try chunkData(c)
        return d.map { $0[s - c * source.chunk] }
    }
    /// 타임라인 프레임 k의 밴드 값(0…1). 창은 타임라인 표본 [중심 − N/2, 중심 − N/2 + N), 각 표본은 그 자리를 덮는 조각의 원본 표본 × 이득.
    /// pieces: 그 창 범위의 조각(색인이 줌, 겹침 없음 가정 — 겹침은 색인에서 걸러짐). combine: 채널 결합 방식(시험 비교용).
    enum Combine { case energy, averagePCM }
    func bands(frame k: Int, pieces: [ProtoPiece], combine: Combine = .energy) throws -> [Float] {
        let rate = source.rate
        let center = ProtoFrameMap.sample(atFrame: k, fps: fps, rate: rate) + params.offsetMs * rate / 1000
        let w0 = center - n / 2
        var chans: [[Float]] = []
        for i in 0..<n {
            let ts = w0 + i   // 타임라인 표본
            var v: [Float] = []
            if let p = pieces.first(where: { ProtoFrameMap.sample(atFrame: $0.start, fps: fps, rate: rate) <= ts && ts < ProtoFrameMap.sample(atFrame: $0.end, fps: fps, rate: rate) }) {
                let srcSample = ts - ProtoFrameMap.sample(atFrame: p.start, fps: fps, rate: rate) + ProtoFrameMap.sample(atFrame: p.sourceIn, fps: fps, rate: rate)
                let tClip = Double(ts) * Double(fps) / Double(rate) - Double(p.start)   // 클립 시작에서 잰 프레임(소수)
                let g = Float(p.laneGain * p.audio.gain * p.audio.envelope(at: tClip, length: p.length))
                v = try samples(srcSample).map { $0 * g }
            }
            if chans.isEmpty, !v.isEmpty { chans = Array(repeating: [Float](repeating: 0, count: n), count: v.count) }
            for c in 0..<min(chans.count, v.count) { chans[c][i] = v[c] }
        }
        if chans.isEmpty { return [Float](repeating: 0, count: params.bands) }
        // 채널 결합
        var power = [Float](repeating: 0, count: m / 2)
        let inputs: [[Float]]
        switch combine {
        case .energy: inputs = chans
        case .averagePCM: inputs = [zip(chans[0], chans.count > 1 ? chans[1] : chans[0]).map { ($0 + $1) / 2 }]
        }
        for x in inputs { vDSP.add(power, powerSpectrum(x), result: &power) }
        vDSP.divide(power, Float(inputs.count), result: &power)   // 채널 에너지 평균: L = R이면 한 채널과 같고, 한쪽만 있으면 −3 dB
        let amp = power.map { sqrt($0) }
        return bandValues(amp)
    }
    /// 진폭 스펙트럼의 제곱(창 정규화: 진폭 A 사인 → 칸 값 A)
    func powerSpectrum(_ x: [Float]) -> [Float] {
        var buf = [Float](repeating: 0, count: m)
        for i in 0..<n { buf[i] = x[i] * window[i] }
        var re = [Float](repeating: 0, count: m / 2), im = re
        var out = [Float](repeating: 0, count: m / 2)
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            buf.withUnsafeBufferPointer { b in b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: m / 2) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(m / 2)) } }
            fft.forward(input: sc, output: &sc)
            vDSP_zvmags(&sc, 1, &out, 1, vDSP_Length(m / 2))
        } }
        // vDSP 실수 FFT 출력은 2배 크기(Apple 데이터 묶음 문서), 진폭 정규화: |X|·(2/2)/Σw → 제곱
        let sw = window.reduce(0, +)
        let k = Float(1) / (sw * sw)
        return out.map { $0 * k }
    }
    func bandValues(_ amp: [Float]) -> [Float] {
        let rate = Float(source.rate), df = rate / Float(m)
        let lo = Float(params.fLo), hi = Float(params.fHi), B = params.bands
        return (0..<B).map { b in
            let e0 = lo * pow(hi / lo, Float(b) / Float(B)), e1 = lo * pow(hi / lo, Float(b + 1) / Float(B))
            let i0 = Int(ceil(e0 / df)), i1 = Int(floor(e1 / df))
            var a: Float
            if i0 <= i1, i1 < amp.count { a = amp[i0...i1].max()! }
            else {   // 칸이 없는 좁은 밴드: 가운데 주파수에서 이웃 칸 선형 보간
                let fc = sqrt(e0 * e1) / df, j = Int(fc), t = fc - Float(j)
                a = j + 1 < amp.count ? amp[j] * (1 - t) + amp[j + 1] * t : 0
            }
            let db = 20 * log10(max(a, 1e-12))
            return min(1, max(0, (db - Float(params.floorDB)) / Float(-params.floorDB)))
        }
    }
    func bandIndex(ofHz f: Float) -> Int { Int(floor(Float(params.bands) * log(f / Float(params.fLo)) / log(Float(params.fHi) / Float(params.fLo)))) }
}
#endif
