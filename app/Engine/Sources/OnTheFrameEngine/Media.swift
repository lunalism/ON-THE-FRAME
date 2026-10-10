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
    /// 같은 검사 결과에 프로젝트의 미디어 id를 붙인다(프로젝트를 다시 열 때 저장된 id를 유지, A-013)
    public func withID(_ newID: UUID) -> MediaAsset {
        MediaAsset(id: newID, url: url, name: name, frameCount: frameCount, timing: timing, naturalSize: naturalSize, displaySize: displaySize,
                   preferredTransform: preferredTransform, hasAudio: hasAudio, codec: codec, identity: identity)
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
        case .audioCodec(let c): return "오디오 형식(\(c))을 M1에서 확인하지 않았습니다. AAC만 지원합니다."
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

    public static func inspect(_ url: URL, settings: RenderSettings = .m1) async throws -> MediaAsset {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videos: [AVAssetTrack], audios: [AVAssetTrack]
        do {
            videos = try await asset.loadTracks(withMediaType: .video)
            audios = try await asset.loadTracks(withMediaType: .audio)
        } catch { throw ProbeError.unreadable(error.localizedDescription) }
        guard let v = videos.first else { throw ProbeError.noVideo }
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
        let timing = try scanTiming(asset: asset, track: v, duration: range.duration)
        // 원본 길이 안에 들어가는 타임라인 프레임 수(정확한 정수 계산, 내림)
        let d = range.duration
        guard d.isNumeric, d.timescale > 0 else { throw ProbeError.unreadable("duration") }
        let frames = Int((Int64(d.value) * Int64(settings.fps)) / Int64(d.timescale))
        guard frames >= 1 else { throw ProbeError.variableTiming("타임라인 1프레임보다 짧음") }
        let attrs = FileIdentity.of(url)
        guard let identity = attrs else { throw ProbeError.unreadable("stat") }
        return MediaAsset(id: UUID(), url: url, name: url.lastPathComponent, frameCount: frames, timing: timing, naturalSize: natural,
                          displaySize: CGSize(width: dw, height: dh), preferredTransform: transform, hasAudio: !audios.isEmpty,
                          codec: codec, identity: identity)
    }

    static func fourCC(_ v: UInt32) -> String {
        String(bytes: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? "\(v)"
    }

    /// 압축 샘플의 표시 시각을 모아 정렬하고 간격을 정확한 유리수로 비교한다(고정·가변 판정).
    /// 같은 표시 시각의 샘플(간격 0)과 1~240 fps 밖의 평균 프레임레이트는 거부한다.
    static func scanTiming(asset: AVAsset, track: AVAssetTrack, duration: CMTime) throws -> SourceTiming {
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
            if n == 1 { pts.append(CMSampleBufferGetPresentationTimeStamp(sb)); continue }
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: n)
            var got = 0
            CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: n, arrayToFill: &timing, entriesNeededOut: &got)
            pts.append(contentsOf: timing.prefix(got).map(\.presentationTimeStamp))
        }
        if reader.status == .failed { throw ProbeError.unreadable(reader.error?.localizedDescription ?? "reader failed") }
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
