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

/// 가져온 영상(M1: 영상만). id는 가져올 때마다 새로 만든다. 원본 파일은 읽기만 한다.
public struct MediaAsset: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let frameCount: Int          // 타임라인 fps(30) 프레임 수
    public let naturalSize: CGSize
    public let displaySize: CGSize      // 회전 반영
    public let preferredTransform: CGAffineTransform
    public let hasAudio: Bool
    public let codec: String
    public let identity: FileIdentity
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
        case .frameRate(let s): return "프레임레이트가 30 fps가 아닙니다(\(s)). M1 타임라인은 30 fps이며 변환하지 않습니다."
        case .variableTiming(let s): return "프레임 간격이 일정하지 않습니다(\(s)). 가변 프레임레이트는 M1에서 지원하지 않습니다."
        case .editList(let s): return "파일 안에 편집 목록이 있습니다(\(s)). M1에서 확인하지 않은 구조입니다."
        case .tooLong(let s, let l): return String(format: "길이 %.0f초가 M1에서 확인한 범위(%.0f초)를 넘습니다.", s, l)
        case .orientation: return "회전 정보가 90도 단위가 아닙니다."
        case .dimensions(let w, let h): return "화면 크기 \(w)×\(h)가 M1에서 확인한 범위(긴 변 1920·짧은 변 1080 이하)를 벗어납니다. 4K 원본은 아직 지원하지 않습니다."
        case .audioCodec(let c): return "오디오 형식(\(c))을 M1에서 확인하지 않았습니다. AAC만 지원합니다."
        }
    }
}

/// M1 입력 범위(검증한 것만 받는다):
/// - 영상 트랙 1개(H.264 avc1 또는 HEVC hvc1·hev1), 오디오 트랙 0~1개(AAC만)
/// - 정확히 30 fps 고정 간격: nominalFrameRate·minFrameDuration과, 모든 압축 샘플의 표시 시각 간격을 확인한다(가변 간격 거부)
/// - 영상 트랙의 편집 목록은 비어 있지 않은 구간 1개(속도 변화 없음)만
/// - 길이 10분 이하(잠정 상한, E3-1에서 다른 경로로 확인한 길이), 회전은 90도 단위, 표시 크기 16 px 이상·긴 변 1920·짧은 변 1080 이하
///   (4K 원본은 앱 경로에서 확인하지 않았으므로 거부)
/// 거부한 파일은 변환하지 않는다(자동 트랜스코딩 없음).
public enum MediaProbe {
    public static let maxSeconds = 600.0

    public static func inspect(_ url: URL, settings: RenderSettings = .m1) async throws -> MediaAsset {
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

        let (nominal, minDur, segments, natural, transform, range) = try await v.load(.nominalFrameRate, .minFrameDuration, .segments, .naturalSize, .preferredTransform, .timeRange)
        guard abs(Double(nominal) - Double(settings.fps)) < 0.01 else { throw ProbeError.frameRate(String(format: "%.3f fps", nominal)) }
        guard minDur.isNumeric, abs(minDur.seconds - settings.frameDuration.seconds) < 1e-6 else {
            throw ProbeError.variableTiming("최소 프레임 간격 \(minDur.value)/\(minDur.timescale)")
        }
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

        // 모든 압축 샘플의 표시 시각 간격 확인(디코딩 없음)
        let frames = try scanTiming(asset: asset, track: v, settings: settings)
        let attrs = FileIdentity.of(url)
        guard let identity = attrs else { throw ProbeError.unreadable("stat") }
        return MediaAsset(id: UUID(), url: url, name: url.lastPathComponent, frameCount: frames, naturalSize: natural,
                          displaySize: CGSize(width: dw, height: dh), preferredTransform: transform, hasAudio: !audios.isEmpty,
                          codec: codec, identity: identity)
    }

    static func fourCC(_ v: UInt32) -> String {
        String(bytes: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? "\(v)"
    }

    /// 압축 샘플의 표시 시각을 모아 정렬하고, 모든 간격이 1/fps인지 본다. 프레임 수를 돌려준다.
    static func scanTiming(asset: AVAsset, track: AVAssetTrack, settings: RenderSettings) throws -> Int {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw ProbeError.unreadable(error.localizedDescription) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw ProbeError.unreadable(reader.error?.localizedDescription ?? "reader") }
        var pts: [Double] = []
        while let sb = out.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0 else { continue }
            if n == 1 { pts.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds); continue }
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: n)
            var got = 0
            CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: n, arrayToFill: &timing, entriesNeededOut: &got)
            pts.append(contentsOf: timing.prefix(got).map { $0.presentationTimeStamp.seconds })
        }
        if reader.status == .failed { throw ProbeError.unreadable(reader.error?.localizedDescription ?? "reader failed") }
        guard pts.count >= 1 else { throw ProbeError.noVideo }
        pts.sort()
        let step = settings.frameDuration.seconds
        for i in 1..<max(1, pts.count) {
            let d = pts[i] - pts[i - 1]
            if abs(d - step) > 1e-4 { throw ProbeError.variableTiming(String(format: "샘플 %d 간격 %.4f s", i, d)) }
        }
        return pts.count
    }
}
