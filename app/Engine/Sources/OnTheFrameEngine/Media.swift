import AVFoundation
import CoreMedia
import Darwin
import Foundation

/// 파일 식별(장치·inode·크기·수정 시각). 원본 보호와 "확인 뒤 대상이 바뀌었는가" 판단에 쓴다.
public struct FileIdentity: Sendable, Equatable, Codable {
    public let device: Int64, inode: UInt64, size: Int64, modifiedNs: Int64
    public static func of(_ url: URL) -> FileIdentity? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return FileIdentity(device: Int64(st.st_dev), inode: UInt64(st.st_ino), size: Int64(st.st_size),
                            modifiedNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec))
    }
    /// 같은 파일인가(장치·inode). 크기·시각은 비교하지 않는다.
    public func sameFile(as o: FileIdentity) -> Bool { device == o.device && inode == o.inode }
}

/// 원본 영상의 표시 시각 분석 결과(A-010). 압축 샘플의 표시 시각(PTS)을 정확한 유리수로 비교한다.
public struct SourceTiming: Sendable, Equatable {
    /// 영상 샘플(원본 프레임) 수
    public let sampleCount: Int
    /// 모든 간격이 정확히 같은가(고정 프레임레이트). 아니면 가변(VFR). 간격이 1틱씩 흔들리는 실제 파일은 가변으로 표시될 수 있다
    /// (표시용 판정일 뿐 시각 대응 동작은 같다).
    public let isVariable: Bool
    /// 고정일 때 한 프레임 길이(유리수 value/timescale). 가변이면 nil.
    public let frameDurationValue: Int64?
    public let frameDurationTimescale: Int32?
    /// 평균 프레임레이트(샘플 수 / 트랙 길이)
    public let averageFPS: Double
    /// 가장 짧은·긴 간격(초)
    public let minInterval: Double, maxInterval: Double

    /// 사용자에게 보이는 짧은 표시(예: "29.97 fps", "25 fps", "가변 평균 29.4 fps")
    public var label: String {
        if sampleCount <= 1 { return "단일 프레임" }   // 간격이 없어 고정·가변을 말할 수 없다
        if !isVariable, let v = frameDurationValue, let ts = frameDurationTimescale, v > 0 {
            let fps = Double(ts) / Double(v)
            let r = fps.rounded()
            return abs(fps - r) < 1e-9 ? String(format: "%.0f fps", r) : String(format: "%.3f", fps).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression) + " fps"
        }
        return String(format: "가변 평균 %.1f fps", averageFPS)
    }
    /// 기록용 정확한 표시(예: "30000/1001 fps CFR", "VFR avg 29.40 interval 16.7–300.0 ms")
    public var detail: String {
        if sampleCount <= 1 { return "single frame" }
        if !isVariable, let v = frameDurationValue, let ts = frameDurationTimescale {
            let g = gcd(Int64(ts), v)
            return "\(Int64(ts) / g)/\(v / g) fps CFR"
        }
        return String(format: "VFR avg %.2f fps interval %.1f–%.1f ms", averageFPS, minInterval * 1000, maxInterval * 1000)
    }
}

func gcd(_ a: Int64, _ b: Int64) -> Int64 { var (x, y) = (abs(a), abs(b)); while y != 0 { (x, y) = (y, x % y) }; return max(x, 1) }

/// 가져온 영상. id는 가져올 때마다 새로 만든다. 원본 파일은 읽기만 한다.
/// 원본 프레임레이트와 타임라인(30 fps)은 따로다(A-010): frameCount는 원본 길이 안에 들어가는 타임라인 프레임 수이고,
/// 클립의 원본 위치는 원본 트랙 시작에서 잰 타임라인 프레임(1/30 s) 단위 시각이다. 각 타임라인 프레임에는 그 시각에
/// 표시 중인 원본 프레임(PTS ≤ 시각인 마지막 프레임)이 나온다(프레임 보간·속도 변경 없음).
public struct MediaAsset: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let frameCount: Int          // 원본 길이 안의 타임라인(30 fps) 프레임 수(내림)
    public let timing: SourceTiming
    public let naturalSize: CGSize
    public let displaySize: CGSize      // 회전 반영
    public let preferredTransform: CGAffineTransform
    public let hasAudio: Bool
    public let codec: String
    public let identity: FileIdentity
    /// A-014: 영상 트랙이 있는가(소리 파일은 false)와 소리 파일의 정확한 길이(표본율·표본 수)·채널 수·소리 형식
    public var hasVideo: Bool = true
    public var audioSampleRate: Int? = nil
    public var audioSampleCount: Int64? = nil
    public var audioChannels: Int? = nil
    /// 같은 검사 결과에 프로젝트의 미디어 id를 붙인다(프로젝트를 다시 열 때 저장된 id를 유지, A-013)
    public func withID(_ newID: UUID) -> MediaAsset {
        MediaAsset(id: newID, url: url, name: name, frameCount: frameCount, timing: timing, naturalSize: naturalSize, displaySize: displaySize,
                   preferredTransform: preferredTransform, hasAudio: hasAudio, codec: codec, identity: identity,
                   hasVideo: hasVideo, audioSampleRate: audioSampleRate, audioSampleCount: audioSampleCount, audioChannels: audioChannels)
    }
}

public enum ProbeError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case noVideo
    case multipleVideoTracks(Int)
    case multipleAudioTracks(Int)
    case unsupportedCodec(String)
    case frameRate(String)
    case variableTiming(String)
    case editList(String)
    case tooLong(seconds: Double, limit: Double)
    case orientation
    case dimensions(Int, Int)
    case audioCodec(String)
    /// 소리 파일(A-014): 채널 수·표본율이 범위 밖
    case audioChannels(Int)
    case audioSampleRate(Double)

    /// 기록·검사용 종류 이름
    public var kind: String {
        switch self {
        case .unreadable: return "unreadable"
        case .noVideo: return "noVideo"
        case .multipleVideoTracks: return "multipleVideoTracks"
        case .multipleAudioTracks: return "multipleAudioTracks"
        case .unsupportedCodec: return "unsupportedCodec"
        case .frameRate: return "frameRate"
        case .variableTiming: return "variableTiming"
        case .editList: return "editList"
        case .tooLong: return "tooLong"
        case .orientation: return "orientation"
        case .dimensions: return "dimensions"
        case .audioCodec: return "audioCodec"
        case .audioChannels: return "audioChannels"
        case .audioSampleRate: return "audioSampleRate"
        }
    }

    /// 사용자에게 보이는 이유(한국어)
    public var description: String {
        switch self {
        case .unreadable(let s): return "파일을 읽을 수 없습니다(\(s))."
        case .noVideo: return "영상 트랙이 없습니다. M1은 영상 파일만 가져옵니다."
        case .multipleVideoTracks(let n): return "영상 트랙이 \(n)개입니다. M1은 영상 트랙 1개인 파일만 지원합니다."
        case .multipleAudioTracks(let n): return "오디오 트랙이 \(n)개입니다. M1은 오디오 트랙 0~1개인 파일만 지원합니다."
        case .unsupportedCodec(let c): return "영상 코덱(\(c))을 M1에서 확인하지 않았습니다. H.264·HEVC만 지원합니다."
        case .frameRate(let s): return "프레임레이트(\(s))가 지원 범위(1~240 fps)를 벗어납니다."
        case .variableTiming(let s): return "프레임 표시 시각을 해석할 수 없습니다(\(s))."
        case .editList(let s): return "파일 안에 편집 목록이 있습니다(\(s)). M1에서 확인하지 않은 구조입니다."
        case .tooLong(let s, let l): return String(format: "길이 %.0f초가 M1에서 확인한 범위(%.0f초)를 넘습니다.", s, l)
        case .orientation: return "회전 정보가 90도 단위가 아닙니다."
        case .dimensions(let w, let h): return "화면 크기 \(w)×\(h)가 M1에서 확인한 범위(긴 변 1920·짧은 변 1080 이하)를 벗어납니다. 4K 원본은 아직 지원하지 않습니다."
        case .audioCodec(let c): return "소리 형식(\(c))을 지원하지 않습니다. 영상 파일의 소리는 AAC, 소리 파일은 PCM(WAV·AIFF)·MP3·AAC·ALAC만 받습니다."
        case .audioChannels(let n): return "소리 채널이 \(n)개입니다. 모노·스테레오만 받습니다."
        case .audioSampleRate(let r): return String(format: "표본율 %.0f Hz는 지원 범위(8–192 kHz) 밖입니다.", r)
        }
    }
}

/// 입력 범위(검증한 것만 받는다, A-010에서 프레임레이트 확장):
/// - 영상 트랙 1개(H.264 avc1 또는 HEVC hvc1·hev1), 오디오 트랙 0~1개(AAC만). 컨테이너는 AVFoundation이 여는 MP4·MOV·M4V
/// - 프레임레이트: 모든 압축 샘플의 표시 시각을 정확한 유리수로 모아 정렬한다. 고정(29.97 = 30000/1001, 25 등)과 가변 모두 받는다.
///   같은 표시 시각의 샘플이 있거나 평균 프레임레이트가 1~240 fps 밖이면 거부한다. 타임라인은 30 fps 그대로다(변환 없음, 위 MediaAsset 참고).
/// - 영상 트랙의 편집 목록은 비어 있지 않은 구간 1개(속도 변화 없음)만
/// - 길이 10분 이하(잠정 상한, E3-1에서 다른 경로로 확인한 길이), 회전은 90도 단위, 표시 크기 16 px 이상·긴 변 1920·짧은 변 1080 이하
///   (4K 원본은 앱 경로에서 확인하지 않았으므로 거부)
/// 거부한 파일은 변환하지 않는다(자동 트랜스코딩 없음).
public enum MediaProbe {
    public static let maxSeconds = 600.0

    /// 검사 단계(2026-10-11 진단·진행 표시): 파일 열기(트랙 불러오기) → 형식 확인 → 프레임 표시 시각 확인(읽은 샘플 수) → 끝.
    /// 진행률이 아니다(전체 샘플 수는 다 읽기 전에는 모른다). 경로는 담지 않는다.
    public enum Stage: Sendable, Equatable {
        case opening, checkingFormat, scanningFrames(Int), finished
        public var label: String {
            switch self {
            case .opening: return "파일 여는 중"
            case .checkingFormat: return "형식 확인 중"
            case .scanningFrames(let n): return n == 0 ? "프레임 시각 확인 중" : "프레임 시각 확인 중 · \(n.formatted())프레임"
            case .finished: return "확인 끝"
            }
        }
    }
    public typealias StageHandler = @Sendable (Stage) -> Void

    public static func inspect(_ url: URL, settings: RenderSettings = .m1, stage: StageHandler? = nil) async throws -> MediaAsset {
        try Task.checkCancellation()
        stage?(.opening)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videos: [AVAssetTrack], audios: [AVAssetTrack]
        do {
            videos = try await asset.loadTracks(withMediaType: .video)
            audios = try await asset.loadTracks(withMediaType: .audio)
        } catch { throw ProbeError.unreadable(error.localizedDescription) }
        try Task.checkCancellation()
        stage?(.checkingFormat)
        // A-014: 영상 트랙이 없으면 소리 파일로 검사한다
        guard let v = videos.first else { let a = try await inspectAudio(url, asset: asset, audios: audios); stage?(.finished); return a }
        guard videos.count == 1 else { throw ProbeError.multipleVideoTracks(videos.count) }
        guard audios.count <= 1 else { throw ProbeError.multipleAudioTracks(audios.count) }

        let fds = try await v.load(.formatDescriptions)
        let sub = fds.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let codec = fourCC(sub)
        guard ["avc1", "hvc1", "hev1"].contains(codec) else { throw ProbeError.unsupportedCodec(codec) }

        let (segments, natural, transform, range) = try await v.load(.segments, .naturalSize, .preferredTransform, .timeRange)
        let real = segments.filter { !$0.isEmpty }
        guard real.count == 1, segments.count == 1,
              real[0].timeMapping.source.duration == real[0].timeMapping.target.duration else {
            throw ProbeError.editList("구간 \(segments.count)개")
        }
        guard range.duration.seconds <= maxSeconds + 1e-6 else { throw ProbeError.tooLong(seconds: range.duration.seconds, limit: maxSeconds) }

        // 회전: 90도 단위만(a, b, c, d가 0 또는 ±1)
        let t = transform
        let isRot = [t.a, t.b, t.c, t.d].allSatisfy { abs($0) < 1e-6 || abs(abs($0) - 1) < 1e-6 } && abs(t.a * t.d - t.b * t.c) > 0.5
        guard isRot else { throw ProbeError.orientation }
        let disp = CGRect(origin: .zero, size: natural).applying(t).size
        let dw = Int(abs(disp.width).rounded()), dh = Int(abs(disp.height).rounded())
        guard min(dw, dh) >= 16, max(dw, dh) <= 1920, min(dw, dh) <= 1080 else { throw ProbeError.dimensions(dw, dh) }
        if let au = audios.first {
            let afd = try await au.load(.formatDescriptions).first
            let fmt = afd.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mFormatID } ?? 0
            guard fmt == kAudioFormatMPEG4AAC else { throw ProbeError.audioCodec(fourCC(fmt)) }
        }

        // 모든 압축 샘플의 표시 시각 분석(디코딩 없음)
        try Task.checkCancellation()
        stage?(.scanningFrames(0))
        let timing: SourceTiming
        if let pts = cursorTimes(v, source: real[0].timeMapping.source) {
            timing = try analyzeTiming(pts, duration: range.duration)
        } else {
            timing = try scanTiming(asset: asset, track: v, duration: range.duration) { stage?(.scanningFrames($0)) }
        }
        // 원본 길이 안에 들어가는 타임라인 프레임 수(정확한 정수 계산, 내림)
        let d = range.duration
        guard d.isNumeric, d.timescale > 0 else { throw ProbeError.unreadable("duration") }
        let frames = Int((Int64(d.value) * Int64(settings.fps)) / Int64(d.timescale))
        guard frames >= 1 else { throw ProbeError.variableTiming("타임라인 1프레임보다 짧음") }
        let attrs = FileIdentity.of(url)
        guard let identity = attrs else { throw ProbeError.unreadable("stat") }
        stage?(.finished)
        return MediaAsset(id: UUID(), url: url, name: url.lastPathComponent, frameCount: frames, timing: timing, naturalSize: natural,
                          displaySize: CGSize(width: dw, height: dh), preferredTransform: transform, hasAudio: !audios.isEmpty,
                          codec: codec, identity: identity)
    }

    /// 소리 파일(A-014): 소리 트랙 1개, PCM(WAV·AIFF)·MP3·AAC·ALAC, 모노·스테레오, 8–192 kHz, 10분 이하.
    /// 길이는 정확한 표본 수·표본율로 기록하고, 편집 격자 길이(frameCount)는 1/30 s로 올림한다(끝을 잘라 내지 않음).
    static func inspectAudio(_ url: URL, asset: AVURLAsset, audios: [AVAssetTrack]) async throws -> MediaAsset {
        guard let au = audios.first else { throw ProbeError.noVideo }
        guard audios.count == 1 else { throw ProbeError.multipleAudioTracks(audios.count) }
        let (fds, range) = try await au.load(.formatDescriptions, .timeRange)
        guard let asbd = fds.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else { throw ProbeError.unreadable("audio format") }
        let allowed: [AudioFormatID] = [kAudioFormatLinearPCM, kAudioFormatMPEGLayer3, kAudioFormatMPEG4AAC, kAudioFormatAppleLossless]
        guard allowed.contains(asbd.mFormatID) else { throw ProbeError.audioCodec(fourCC(asbd.mFormatID)) }
        guard (1...2).contains(Int(asbd.mChannelsPerFrame)) else { throw ProbeError.audioChannels(Int(asbd.mChannelsPerFrame)) }
        guard (8_000...192_000).contains(asbd.mSampleRate) else { throw ProbeError.audioSampleRate(asbd.mSampleRate) }
        let d = range.duration
        guard d.isNumeric, d.timescale > 0, d.value > 0 else { throw ProbeError.unreadable("duration") }
        guard d.seconds <= maxSeconds + 1e-6 else { throw ProbeError.tooLong(seconds: d.seconds, limit: maxSeconds) }
        let rate = Int64(asbd.mSampleRate.rounded())
        let samples = (Int64(d.value) * rate + Int64(d.timescale) / 2) / Int64(d.timescale)
        let frames = Int((Int64(d.value) * 30 + Int64(d.timescale) - 1) / Int64(d.timescale))   // 올림
        guard let identity = FileIdentity.of(url) else { throw ProbeError.unreadable("stat") }
        let timing = SourceTiming(sampleCount: 0, isVariable: false, frameDurationValue: nil, frameDurationTimescale: nil, averageFPS: 0, minInterval: 0, maxInterval: 0)
        return MediaAsset(id: UUID(), url: url, name: url.lastPathComponent, frameCount: frames, timing: timing, naturalSize: .zero, displaySize: .zero,
                          preferredTransform: .identity, hasAudio: true, codec: fourCC(asbd.mFormatID), identity: identity,
                          hasVideo: false, audioSampleRate: Int(rate), audioSampleCount: samples, audioChannels: Int(asbd.mChannelsPerFrame))
    }

    static func fourCC(_ v: UInt32) -> String {
        String(bytes: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? "\(v)"
    }

    /// 압축 샘플의 표시 시각을 모아 정렬하고 간격을 정확한 유리수로 비교한다(고정·가변 판정).
    /// 같은 표시 시각의 샘플(간격 0)과 1~240 fps 밖의 평균 프레임레이트는 거부한다.
    /// 표시 시각 모으기(2026-10-11 가져오기 멈춤 수정): 샘플 커서로 샘플 표(트랙의 미디어 시각)를 걸어가며 표시 시각만 모은다(샘플 데이터를 읽지 않음).
    /// 이 Mac에서 3분 1080p MP4(5 400샘플): AVAssetReader로 압축 샘플을 모두 읽으면 47–66 s, 샘플 커서는 0.001 s였고 모은 시각은 같았다.
    /// 편집 목록 구간(source, 미디어 시각) 안의 샘플만 센다(읽기 출력과 같은 범위). 커서를 줄 수 없는 트랙이면 nil(읽기로 되돌아감).
    static func cursorTimes(_ track: AVAssetTrack, source: CMTimeRange) -> [CMTime]? {
        guard track.canProvideSampleCursors, let c = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        var pts: [CMTime] = []
        repeat {
            let t = c.presentationTimeStamp
            if !source.isValid || source.duration == .zero || (CMTimeCompare(t, source.start) >= 0 && CMTimeCompare(t, source.end) < 0) { pts.append(t) }
            if pts.count % 4096 == 0, Task.isCancelled { return nil }
        } while c.stepInDecodeOrder(byCount: 1) == 1
        return pts.isEmpty ? nil : pts
    }

    /// progress: 읽은 샘플 수(약 300개마다, 진단·진행 표시용). 샘플 커서를 쓸 수 없을 때만 쓴다.
    static func scanTiming(asset: AVAsset, track: AVAssetTrack, duration: CMTime, progress: ((Int) -> Void)? = nil) throws -> SourceTiming {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw ProbeError.unreadable(error.localizedDescription) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw ProbeError.unreadable(reader.error?.localizedDescription ?? "reader") }
        var pts: [CMTime] = []
        while let sb = out.copyNextSampleBuffer() {
            // 협조적 취소: 가져오기를 취소하면 남은 샘플을 읽지 않고 읽기를 멈춘다(읽기 자원 해제)
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0 else { continue }
            if n == 1 { pts.append(CMSampleBufferGetPresentationTimeStamp(sb)); if pts.count % 300 == 0 { progress?(pts.count) }; continue }
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: n)
            var got = 0
            CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: n, arrayToFill: &timing, entriesNeededOut: &got)
            pts.append(contentsOf: timing.prefix(got).map(\.presentationTimeStamp))
            if pts.count / 300 != (pts.count - got) / 300 { progress?(pts.count) }
        }
        if reader.status == .failed { throw ProbeError.unreadable(reader.error?.localizedDescription ?? "reader failed") }
        return try analyzeTiming(pts, duration: duration)
    }

    /// 모은 표시 시각 → 고정·가변 판정(같은 시각 거부, 평균 1–240 fps 밖 거부)
    static func analyzeTiming(_ unsorted: [CMTime], duration: CMTime) throws -> SourceTiming {
        var pts = unsorted
        guard !pts.isEmpty else { throw ProbeError.noVideo }
        guard pts.allSatisfy(\.isNumeric) else { throw ProbeError.variableTiming("숫자가 아닌 표시 시각") }
        pts.sort { CMTimeCompare($0, $1) < 0 }
        var intervals: [CMTime] = []
        for i in 1..<max(1, pts.count) {
            let d = CMTimeSubtract(pts[i], pts[i - 1])
            guard CMTimeCompare(d, .zero) > 0 else { throw ProbeError.variableTiming(String(format: "샘플 %d이 앞 샘플과 같은 표시 시각", i)) }
            intervals.append(d)
        }
        let secs = duration.seconds
        let avg = secs > 0 ? Double(pts.count) / secs : 0
        guard avg >= 1, avg <= 240 else { throw ProbeError.frameRate(String(format: "평균 %.3f fps", avg)) }
        let isVar = intervals.contains { CMTimeCompare($0, intervals[0]) != 0 }
        let fd: CMTime? = (!isVar && !intervals.isEmpty) ? intervals[0] : nil
        let iv = intervals.map(\.seconds)
        return SourceTiming(sampleCount: pts.count, isVariable: isVar, frameDurationValue: fd.map { Int64($0.value) },
                            frameDurationTimescale: fd.map(\.timescale), averageFPS: avg,
                            minInterval: iv.min() ?? secs, maxInterval: iv.max() ?? secs)
    }
}

/// Engine-only catalog payload. Still sources have no temporal payload or video track.
enum OperationalMedia: Equatable, Sendable {
    enum Kind { case video, audio, stillImage }
    struct StillSource: Equatable, Sendable {
        let reference: StillImageProjectModel.ImageReference
        enum ValidationState { case unverified, probeValidated }
        /// A portable snapshot never manufactures a runtime validation or file identity.
        let validated: StillImageProjectModel.ValidatedImage?
        var descriptor: StillImageDescriptor? { validated?.descriptor }
        var validationState: ValidationState { validated == nil ? .unverified : .probeValidated }
        init(_ source: StillImageProjectModel.ValidatedImage, id: UUID) {
            reference = .init(id:id,validated:source); validated = source
        }
        init(persisted reference: StillImageProjectModel.ImageReference,
             validated source: StillImageProjectModel.ValidatedImage? = nil) throws {
            try reference.validate()
            if let source {
                try StillImageProjectModel.require(reference.path == source.url.standardizedFileURL.path &&
                    reference.image == .init(source.descriptor) && reference.size == source.descriptor.identity.size &&
                    reference.modifiedNs == source.descriptor.identity.modifiedNs, "validation does not match persisted image")
                guard FileIdentity.of(source.url) == source.descriptor.identity else { throw StillImageProbeError.changed }
            }
            self.reference = reference; validated = source
        }
        static func == (a: Self, b: Self) -> Bool {
            a.reference == b.reference && a.descriptor == b.descriptor && a.validated?.url == b.validated?.url
        }
    }
    case temporal(MediaRef)
    case stillImage(StillSource)
    var temporal: MediaRef? { if case .temporal(let r)=self { return r }; return nil }
    var still: StillSource? { if case .stillImage(let r)=self { return r }; return nil }
    var id: UUID { switch self { case .temporal(let r): return r.id; case .stillImage(let r): return r.reference.id } }
    var kind: Kind { switch self { case .temporal(let r): return r.hasVideo ? .video : .audio; case .stillImage: return .stillImage } }
    var hasVideoTrack: Bool { kind == .video }
    var hasVisualContent: Bool { kind != .audio }
    var hasAudio: Bool { temporal?.hasAudio ?? false }
    var sourceFrames: Int? { temporal?.frameCount }
}
