import Accelerate
import AVFoundation
import Foundation

// 스펙트럼 분석(SP-0 (3), 2026-10-24, docs/SPECTRUM-DESIGN.md §2·§4·§11): 타임라인 프레임 k의 밴드 값을 결정적으로 계산한다.
// 앱에 연결하지 않았다(프리뷰·내보내기·저장 형식·스펙트럼 모델 없음). 시제품(Tests/…/SpectrumPrototype)에서 검증한 규칙을 옮겼고,
// 시제품 가정(채널 수가 덩어리마다 달라질 수 있음, 표본마다 사전·LRU 조회, 겹친 조각을 말없이 첫 것으로 고름, 매번 asset 다시 열기)은 고쳤다.

/// 프레임 ↔ 분석 표본: 프로젝트 fps와 표본율로 정수 계산. sample(k) = ⌊(2·k·R + fps) / (2·fps)⌋(절반 올림), 음수에도 내림 나눗셈.
public enum SpectrumFrameMap {
    public static func sample(atFrame k: Int, fps: Int, rate: Int) -> Int {
        floorDiv(2 * Int64(k) * Int64(rate) + Int64(fps), 2 * Int64(fps))
    }
    public static func frame(containingSample n: Int, fps: Int, rate: Int) -> Int { floorDiv(Int64(n) * Int64(fps), Int64(rate)) }
    static func floorDiv(_ a: Int64, _ b: Int64) -> Int { let q = a / b; return Int((a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q) }
}

/// 분석 설정(정수, 결정적). 결과 캐시 열쇠의 일부다.
public struct SpectrumAnalysisSettings: Hashable, Sendable {
    /// 분석 길이(창, ms), 분석 중심 오프셋(ms, + = 뒤의 소리), 로그 밴드 수와 범위(Hz), dB 바닥(0~1로 늘리는 아래 끝)
    public var windowMs: Int, offsetMs: Int, bands: Int, lowHz: Int, highHz: Int, floorDB: Int
    public init(windowMs: Int = 90, offsetMs: Int = 0, bands: Int = 64, lowHz: Int = 20, highHz: Int = 2000, floorDB: Int = -60) {
        self.windowMs = windowMs; self.offsetMs = offsetMs; self.bands = bands; self.lowHz = lowHz; self.highHz = highHz; self.floorDB = floorDB
    }
    /// 표본율 rate에서 쓸 수 있는지(창 2표본 이상·1초 이하, 밴드 1~1024, 0 < 낮은 끝 < 높은 끝 ≤ 나이퀴스트, 바닥 < 0)
    public func validationError(rate: Int) -> String? {
        guard (8_000...384_000).contains(rate) else { return "rate \(rate)" }   // 아래 곱셈이 넘치지 않는 범위
        if windowMs < 1 || windowMs > 1000 || windowMs * rate / 1000 < 2 { return "windowMs \(windowMs)" }
        if bands < 1 || bands > 1024 { return "bands \(bands)" }
        if lowHz <= 0 || highHz <= lowHz || highHz > rate / 2 { return "frequency range \(lowHz)–\(highHz) at \(rate) Hz" }
        if floorDB >= 0 { return "floorDB \(floorDB)" }
        if offsetMs.magnitude > 10_000 { return "offsetMs \(offsetMs)" }
        return nil
    }
    func windowSamples(rate: Int) -> Int { windowMs * rate / 1000 }
    func offsetSamples(rate: Int) -> Int { offsetMs * rate / 1000 }
}

/// 한 소스 조각(타임라인 프레임): 그 자리를 덮는 소리 클립의 원본 시작·소리 설정과 레인 이득. 이득은 표본마다 곱한다(페이드가 창 안에서 바뀜).
/// 어떤 클립이 그 스펙트럼의 소스인지(계보 규칙)는 정하지 않는다 — 부르는 쪽이 고른 조각을 받는다.
public struct SpectrumSourcePiece: Sendable, Equatable {
    public let start: Int, length: Int, sourceIn: Int
    public let audio: ClipAudio
    /// 레인 배율(음소거면 0, 아니면 음량 % / 100)
    public let laneGain: Double
    public var end: Int { start + length }
    public init(start: Int, length: Int, sourceIn: Int, audio: ClipAudio = .default, laneGain: Double = 1) {
        self.start = start; self.length = length; self.sourceIn = sourceIn; self.audio = audio; self.laneGain = laneGain
    }
    /// 소리 클립과 그 레인에서: 믹스와 같은 이득 규칙(CompositionPlanner.gain(of:lane:atFrame:) = 레인 % × 클립 음량 × 페이드 모양)
    public init(clip c: Clip, lane: Lane) {
        self.init(start: c.start, length: c.length, sourceIn: c.sourceIn, audio: c.effectiveAudio, laneGain: lane.muted ? 0 : Double(lane.volumePercent) / 100)
    }
    /// 타임라인 프레임 f(소수)의 배율 — 조각 밖은 부르지 않는다
    func gain(atFrame f: Double) -> Double { laneGain * audio.gain * audio.envelope(at: f - Double(start), length: length) }
}

/// 분석 원본 표본을 주는 쪽. 덩어리 c = 원본 표본 [c·chunkSamples, (c+1)·chunkSamples), 채널별, 길이 chunkSamples, 파일 밖은 0.
/// decodeChunk는 디코딩 동안 그 작업을 붙잡는다(파일 원본은 리더 차례 읽기) — UI 스레드에서 기다리지 않는다(SpectrumAnalysisScheduler가 분리된 작업에서 부르고 동시 수를 묶음).
public protocol SpectrumPCMProvider: Sendable {
    /// 원본·표본율·덩어리 격자를 모두 담은 정체(캐시 열쇠). 다른 파일·재연결·다른 격자면 달라야 한다.
    var identity: SpectrumSourceIdentity { get }
    var sampleRate: Int { get }
    var channelCount: Int { get }
    var chunkSamples: Int { get }
    func decodeChunk(_ index: Int) async throws -> [[Float]]
}

public struct SpectrumSourceIdentity: Hashable, Sendable {
    public let key: String
    public init(_ key: String) { self.key = key }
}

public enum SpectrumAnalysisError: Error, Equatable, Sendable {
    /// 부른 쪽이 취소함
    case cancelled
    /// 기다리는 요청 상한을 넘어 버림(재생 헤드에서 가장 먼 것)
    case dropped
    /// 세션을 무효로 함(프로젝트 바꿈 등)
    case invalidated
    case invalidSettings(String)
    /// 프레임·fps·조각 값이 범위 밖(넘침 방지 — 아래 SpectrumAnalysis.requestError)
    case invalidRequest(String)
    /// 모노·스테레오만(제품 가져오기 규칙 MediaProbe와 같음)
    case unsupportedChannelCount(Int)
    /// 창 범위에서 조각이 겹침 — 고르지 않는다(겹침 규칙은 제품 결정 D-S8)
    case overlappingPieces
    case noAudioTrack
    case decodeFailed(String)
}

/// 파일 원본(AVAssetReader). 고정 격자 덩어리마다 새 리더로 [앞 여유, 뒤 여유]를 붙여 읽고 가운데만 쓴다 — 같은 덩어리는 늘 같은 범위로 디코딩한다.
/// 리더가 표본율을 sampleRate로 바꾼다. asset은 열 때 한 번 만들고, 트랙은 디코딩마다 그 asset에서 다시 얻는다(AVAssetTrack은 SDK에서 Sendable로
/// 표시되지 않아 공유 상태로 두지 않음). 부르는 쪽이 파일 접근(보안 범위)을 쥐고 있어야 한다.
public final class SpectrumFileSource: SpectrumPCMProvider {
    public let url: URL, identity: SpectrumSourceIdentity, sampleRate: Int, channelCount: Int, chunkSamples: Int, marginSamples: Int
    private let asset: AVURLAsset
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    /// 디코딩한 덩어리 수(진단·시험용)
    public var decodeCount: Int { counter.withLock { $0 } }

    private init(url: URL, identity: SpectrumSourceIdentity, sampleRate: Int, channelCount: Int, chunkSamples: Int, marginSamples: Int, asset: AVURLAsset) {
        self.url = url; self.identity = identity; self.sampleRate = sampleRate; self.channelCount = channelCount
        self.chunkSamples = chunkSamples; self.marginSamples = marginSamples; self.asset = asset
    }
    /// mediaID: 같은 경로라도 다른 미디어 항목이면 열쇠를 나눈다. 정체에는 경로·크기·수정 시각·표본율·격자가 들어간다(파일이 바뀌면 다른 열쇠).
    public static func open(url: URL, mediaID: UUID? = nil, sampleRate: Int = 48_000, chunkSamples: Int = 8 * 48_000, marginSamples: Int = 48_000) async throws -> SpectrumFileSource {
        precondition((8_000...384_000).contains(sampleRate) && chunkSamples > 0 && chunkSamples <= 1 << 26 && marginSamples >= 0 && marginSamples <= 1 << 26)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw SpectrumAnalysisError.noAudioTrack }
        let fd = try await track.load(.formatDescriptions).first
        guard let fd, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee, asbd.mChannelsPerFrame > 0 else {
            throw SpectrumAnalysisError.decodeFailed("no audio format")
        }
        guard (1...2).contains(Int(asbd.mChannelsPerFrame)) else { throw SpectrumAnalysisError.unsupportedChannelCount(Int(asbd.mChannelsPerFrame)) }
        // 정체는 연 때의 파일 상태다(그 뒤 파일이 바뀌면 다시 열어야 함). 크기·수정 시각을 못 읽으면 이 열기에만 쓰는 값을 붙여 다른 열기와 나누지 않는다.
        let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = rv.flatMap { v in v.fileSize.flatMap { n in v.contentModificationDate.map { "\(n)|\($0.timeIntervalSinceReferenceDate)" } } } ?? "unknown-\(UUID().uuidString)"
        let id = SpectrumSourceIdentity([mediaID?.uuidString ?? "-", url.standardizedFileURL.path, stamp,
                                         "\(sampleRate)", "\(chunkSamples)", "\(marginSamples)"].joined(separator: "|"))
        return SpectrumFileSource(url: url, identity: id, sampleRate: sampleRate, channelCount: Int(asbd.mChannelsPerFrame),
                                  chunkSamples: chunkSamples, marginSamples: marginSamples, asset: asset)
    }
    public func decodeChunk(_ c: Int) async throws -> [[Float]] {
        try await decodeRange(c * chunkSamples - marginSamples, (c + 1) * chunkSamples + marginSamples, keep: c * chunkSamples ..< (c + 1) * chunkSamples)
    }
    /// 원본 표본 [a, b)를 읽어 keep 범위만 채널별로 돌려준다(그 밖·파일 밖은 0)
    func decodeRange(_ a0: Int, _ b: Int, keep: Range<Int>) async throws -> [[Float]] {
        counter.withLock { $0 += 1 }
        let a = max(0, a0)
        guard b > a else { return [[Float]](repeating: [Float](repeating: 0, count: keep.count), count: channelCount) }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw SpectrumAnalysisError.noAudioTrack }
        return try read(track, a, b, keep: keep)
    }
    private func read(_ track: AVAssetTrack, _ a: Int, _ b: Int, keep: Range<Int>) throws -> [[Float]] {
        var chans = [[Float]](repeating: [Float](repeating: 0, count: keep.count), count: channelCount)
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw SpectrumAnalysisError.decodeFailed("\(error)") }
        reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(a), timescale: CMTimeScale(sampleRate)),
                                       end: CMTime(value: CMTimeValue(b), timescale: CMTimeScale(sampleRate)))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVLinearPCMBitDepthKey: 32,
                                                                         AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw SpectrumAnalysisError.decodeFailed("\(reader.error.map { "\($0)" } ?? "startReading")") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while let sb = out.copyNextSampleBuffer() {
            if Task.isCancelled { throw SpectrumAnalysisError.cancelled }   // 일정이 세션을 무효로 하면 작업을 취소한다 — 버퍼마다 확인
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0, let fmt = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { continue }
            let ch = Int(asbd.mChannelsPerFrame)
            guard ch == channelCount else { throw SpectrumAnalysisError.decodeFailed("channel count \(ch) ≠ \(channelCount)") }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let start = Int(CMTimeConvertScale(pts, timescale: CMTimeScale(sampleRate), method: .roundHalfAwayFromZero).value)   // 큰 시간 척도에서도 넘치지 않게
            let lo = max(start, keep.lowerBound), hi = min(start + n, keep.upperBound)
            guard lo < hi else { continue }
            var abl = AudioBufferList(), blk: CMBlockBuffer?
            let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
                                                                             blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blk)
            guard st == noErr, let p = abl.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { throw SpectrumAnalysisError.decodeFailed("buffer list \(st)") }
            for c in 0..<ch {
                chans[c].withUnsafeMutableBufferPointer { d in
                    for s in lo..<hi { d[s - keep.lowerBound] = p[(s - start) * ch + c] }
                }
            }
        }
        if reader.status == .failed { throw SpectrumAnalysisError.decodeFailed("\(reader.error.map { "\($0)" } ?? "reader failed")") }
        return chans
    }
}

/// 분석 계산(순수 함수 — 같은 입력이면 같은 값). 창 조립·FFT·밴드.
public enum SpectrumAnalysis {
    /// 넘침 없이 계산할 수 있는 범위(2·k·R이 Int64 안: |프레임·조각 위치| ≤ 2⁴⁰, 표본율 8 k~384 kHz, fps 1~1000, 레인 배율 유한·0 이상)
    public static let frameLimit = 1 << 40
    public static func requestError(frame k: Int, pieces: [SpectrumSourcePiece], fps: Int, rate: Int, settings: SpectrumAnalysisSettings) -> SpectrumAnalysisError? {
        if let e = settings.validationError(rate: rate) { return .invalidSettings(e) }
        guard (1...1000).contains(fps) else { return .invalidRequest("fps \(fps)") }
        guard (8_000...384_000).contains(rate) else { return .invalidRequest("rate \(rate)") }
        let lim = UInt(frameLimit)   // magnitude: abs(Int.min)는 넘쳐 멈추므로 쓰지 않음
        guard k.magnitude <= lim else { return .invalidRequest("frame \(k)") }
        for p in pieces {
            guard p.start.magnitude <= lim, (0...frameLimit).contains(p.length), p.sourceIn.magnitude <= lim, p.laneGain.isFinite, p.laneGain >= 0 else {
                return .invalidRequest("piece \(p.start)+\(p.length) in \(p.sourceIn)")
            }
        }
        return nil
    }
    /// 프레임 k의 창(타임라인 표본 [중심 − N/2, 중심 − N/2 + N), 중심 = sample(k) + 오프셋)
    static func window(frame k: Int, fps: Int, rate: Int, settings: SpectrumAnalysisSettings) -> Range<Int> {
        let n = settings.windowSamples(rate: rate)
        let w0 = SpectrumFrameMap.sample(atFrame: k, fps: fps, rate: rate) + settings.offsetSamples(rate: rate) - n / 2
        return w0 ..< w0 + n
    }
    /// 창과 겹치는 조각(시작 순). 그 안에서 두 조각이 표본 범위로 겹치면 오류(고르지 않음).
    static func windowPieces(_ pieces: [SpectrumSourcePiece], window w: Range<Int>, fps: Int, rate: Int) throws -> [SpectrumSourcePiece] {
        let xs = pieces.filter { p in
            p.length > 0 && SpectrumFrameMap.sample(atFrame: p.start, fps: fps, rate: rate) < w.upperBound && SpectrumFrameMap.sample(atFrame: p.end, fps: fps, rate: rate) > w.lowerBound
        }.sorted { $0.start < $1.start }
        for (a, b) in zip(xs, xs.dropFirst()) where SpectrumFrameMap.sample(atFrame: b.start, fps: fps, rate: rate) < SpectrumFrameMap.sample(atFrame: a.end, fps: fps, rate: rate) {
            throw SpectrumAnalysisError.overlappingPieces
        }
        return xs
    }
    /// 조각마다 창이 읽는 원본 표본 범위
    static func sourceSpans(_ pieces: [SpectrumSourcePiece], window w: Range<Int>, fps: Int, rate: Int) -> [(piece: SpectrumSourcePiece, timeline: Range<Int>, sourceStart: Int)] {
        pieces.compactMap { p in
            let ps = SpectrumFrameMap.sample(atFrame: p.start, fps: fps, rate: rate), pe = SpectrumFrameMap.sample(atFrame: p.end, fps: fps, rate: rate)
            let lo = max(w.lowerBound, ps), hi = min(w.upperBound, pe)
            guard lo < hi else { return nil }
            return (p, lo ..< hi, lo - ps + SpectrumFrameMap.sample(atFrame: p.sourceIn, fps: fps, rate: rate))
        }
    }
    /// 프레임 k의 창이 읽는 원본 덩어리(오름차순, 중복 없음)
    public static func chunks(frame k: Int, pieces: [SpectrumSourcePiece], fps: Int, rate: Int, settings: SpectrumAnalysisSettings, chunkSamples: Int) throws -> [Int] {
        if let e = requestError(frame: k, pieces: pieces, fps: fps, rate: rate, settings: settings) { throw e }
        let w = window(frame: k, fps: fps, rate: rate, settings: settings)
        return chunks(spans: sourceSpans(try windowPieces(pieces, window: w, fps: fps, rate: rate), window: w, fps: fps, rate: rate), chunkSamples: chunkSamples)
    }
    static func chunks(spans: [(piece: SpectrumSourcePiece, timeline: Range<Int>, sourceStart: Int)], chunkSamples: Int) -> [Int] {
        var set = Set<Int>()
        for s in spans {
            let a = s.sourceStart, b = s.sourceStart + s.timeline.count - 1
            for c in SpectrumFrameMap.floorDiv(Int64(a), Int64(chunkSamples))...SpectrumFrameMap.floorDiv(Int64(b), Int64(chunkSamples)) { set.insert(c) }
        }
        return set.sorted()
    }

    /// 타임라인 프레임 k의 밴드 값(0…1, settings.bands개). chunk(c)는 decodeChunk(c)와 같은 모양의 덩어리를 준다(없으면 nil → 오류).
    /// 각 창 표본 = 그 자리를 덮는 조각의 원본 표본 × 그 표본 시각의 이득, 덮는 조각이 없으면 0. 채널마다 파워 스펙트럼 → 채널 평균 → 제곱근.
    public static func bands(frame k: Int, pieces: [SpectrumSourcePiece], fps: Int, rate: Int, channelCount: Int, chunkSamples: Int,
                             settings: SpectrumAnalysisSettings, chunk: (Int) -> [[Float]]?) throws -> [Float] {
        if let e = requestError(frame: k, pieces: pieces, fps: fps, rate: rate, settings: settings) { throw e }
        guard (1...2).contains(channelCount), chunkSamples > 0 else { throw SpectrumAnalysisError.unsupportedChannelCount(channelCount) }
        let w = window(frame: k, fps: fps, rate: rate, settings: settings), n = w.count
        let spans = sourceSpans(try windowPieces(pieces, window: w, fps: fps, rate: rate), window: w, fps: fps, rate: rate)
        guard !spans.isEmpty else { return [Float](repeating: 0, count: settings.bands) }
        var chans = [[Float]](repeating: [Float](repeating: 0, count: n), count: channelCount)
        for s in spans {   // 덩어리 구간마다 이어서 복사(표본마다 같은 이득 식)
            var ts = s.timeline.lowerBound
            while ts < s.timeline.upperBound {
                let src = s.sourceStart + (ts - s.timeline.lowerBound)
                let c = SpectrumFrameMap.floorDiv(Int64(src), Int64(chunkSamples)), i0 = src - c * chunkSamples
                let count = min(s.timeline.upperBound - ts, chunkSamples - i0)
                guard let d = chunk(c), d.count == channelCount, d.allSatisfy({ $0.count == chunkSamples }) else { throw SpectrumAnalysisError.decodeFailed("chunk \(c) missing") }
                for q in 0..<count {
                    let t = ts + q, g = Float(s.piece.gain(atFrame: Double(t) * Double(fps) / Double(rate)))
                    for ch in 0..<channelCount { chans[ch][t - w.lowerBound] = d[ch][i0 + q] * g }
                }
                ts += count
            }
        }
        let fft = SpectrumFFT(n: n)
        var power = [Float](repeating: 0, count: fft.m / 2)
        for x in chans { vDSP.add(power, fft.powerSpectrum(x), result: &power) }
        vDSP.divide(power, Float(channelCount), result: &power)   // 채널 에너지 평균: L = R이면 한 채널과 같고, 한쪽만 있으면 −3 dB, 반대 위상도 사라지지 않음
        return bandValues(power.map { $0.squareRoot() }, rate: rate, m: fft.m, settings: settings)
    }
    /// 로그 밴드: 경계 f_i = lo·(hi/lo)^(i/B), 값 = 경계 안 칸의 최댓값, 칸이 없는 좁은 밴드는 가운데 주파수에서 이웃 칸 선형 보간. dB 바닥 ~ 0 dB → 0~1.
    static func bandValues(_ amp: [Float], rate: Int, m: Int, settings: SpectrumAnalysisSettings) -> [Float] {
        let df = Float(rate) / Float(m), lo = Float(settings.lowHz), hi = Float(settings.highHz), B = settings.bands, floor = Float(settings.floorDB)
        return (0..<B).map { b in
            let e0 = lo * pow(hi / lo, Float(b) / Float(B)), e1 = lo * pow(hi / lo, Float(b + 1) / Float(B))
            let i0 = Int(ceil(e0 / df)), i1 = Int(Foundation.floor(e1 / df))
            var a: Float
            if i0 <= i1, i1 < amp.count { a = amp[i0...i1].max()! }
            else {
                let fc = (e0 * e1).squareRoot() / df, j = Int(fc), t = fc - Float(j)
                a = j + 1 < amp.count ? amp[j] * (1 - t) + amp[j + 1] * t : 0
            }
            let db = 20 * log10(max(a, 1e-12))
            return min(1, max(0, (db - floor) / -floor))
        }
    }
    /// f Hz가 드는 밴드 번호(시험·표시용)
    public static func bandIndex(ofHz f: Double, settings: SpectrumAnalysisSettings) -> Int {
        Int(Foundation.floor(Double(settings.bands) * log(f / Double(settings.lowHz)) / log(Double(settings.highHz) / Double(settings.lowHz))))
    }
}

/// 창 길이 n(Hann) + 0 채워 2의 거듭제곱 m의 실수 FFT. 부르는 작업마다 새로 만든다(설정 객체를 작업 사이에 나누지 않음).
final class SpectrumFFT {
    let n: Int, m: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float], norm: Float
    init(n: Int) {
        self.n = n
        var l = 1; while (1 << l) < n { l += 1 }
        m = 1 << l
        fft = vDSP.FFT(log2n: vDSP_Length(l), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let sw = window.reduce(0, +)
        norm = 1 / (sw * sw)   // vDSP 실수 FFT 출력은 2배 크기 → |X|/Σw가 진폭 A 사인에서 A(시제품과 같은 정규화)
    }
    /// 진폭 스펙트럼의 제곱(m/2칸)
    func powerSpectrum(_ x: [Float]) -> [Float] {
        var buf = [Float](repeating: 0, count: m)
        for i in 0..<n { buf[i] = x[i] * window[i] }
        var re = [Float](repeating: 0, count: m / 2), im = re, out = re
        let half = m / 2
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            buf.withUnsafeBufferPointer { b in b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(half)) } }
            fft.forward(input: sc, output: &sc)
            vDSP_zvmags(&sc, 1, &out, 1, vDSP_Length(half))
        } }
        return out.map { $0 * norm }
    }
}
