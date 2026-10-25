import AVFoundation
import CoreMedia
import Foundation

/// 프리뷰와 내보내기가 함께 쓰는 composition(한 타임라인 스냅샷에서 만든 불변 사본).
/// 안전성(@unchecked Sendable): 생성 뒤 바꾸지 않는 사본만 담는다. assets는 트랙의 소유 asset이 해제되지 않도록 붙잡아 둔다
/// (E2 기록: 트랙만 보관하면 삽입이 −12780으로 실패).
public struct PlannedComposition: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let durationFrames: Int
    public let settings: RenderSettings
    public let hasAudio: Bool
    /// 오디오 믹스: 소리 트랙마다 레인 음량 × 클립 음량 × 페이드의 음량 경사(100%도 포함, 2026-10-11 클립 음량·페이드). 소리가 있으면 늘 있다. 프리뷰 항목·내보내기 세션에 그대로 붙인다(A-014, 2026-10-11).
    public let audioMix: AVAudioMix?
    /// 영상 트랙이 타임라인 끝까지 있는가(영상이 있는 원본이 하나도 없으면 false: 내보내기 불가)
    public let hasVideo: Bool
    let assets: [AVURLAsset]
    /// 자막(2026-10-22): 그리기 순서(아래 레인 먼저). 비어 있으면 지금까지의 내보내기 세션 경로, 있으면 구조 R(SubtitleExporter)로 내보낸다.
    /// 프리뷰는 composition 위에 같은 그림(SubtitleRenderer)의 층을 얹는다(앱).
    public var subtitles: [SubtitleItem] = []
    /// 스펙트럼(2026-10-25, SP-1A 1단계): 계획에 함께 들고 간다. 내보내기 그리기는 아직 없어 ExportService가 이것이 있으면 대상 파일 전에 거부한다
    /// (조용히 빼고 내보내지 않음). 프리뷰 그리기도 아직 없다(앱은 스펙트럼이 든 프로젝트를 열지 않는다).
    public var spectra: [SpectrumItem] = []
}

public enum PlanError: Error, CustomStringConvertible {
    case emptyTimeline, missingMedia(UUID), insertFailed(String)
    public var description: String {
        switch self {
        case .emptyTimeline: return "타임라인이 비어 있습니다."
        case .missingMedia: return "타임라인의 미디어를 찾을 수 없습니다."
        case .insertFailed(let s): return "composition 구성 실패: \(s)"
        }
    }
}

/// 타임라인 → composition. 프리뷰와 내보내기가 이 함수 하나를 쓴다(E2·E3에서 검증한 "같은 구성 함수" 원칙).
/// 원본 구간은 정확한 유리수 시각(트랙 시작 + sourceIn/30 s, 길이 length/30 s)으로 넣는다. 원본 프레임레이트(29.97·25·가변)와
/// 무관하게 영상·소리가 같은 시각 구간을 쓰므로 소리 동기가 유지되고, 출력 프레임 시각은 videoComposition의 1/30 s다(A-010).
/// 빈틈(D-020): 영상·소리 트랙 모두 빈 구간을 넣고, 그 구간의 영상 지시는 레이어 없이 검정 배경이다(소리 없음).
/// A-012: 영상 트랙은 영상 레인, 소리 트랙은 오디오 레인에서 따로 만든다(레인마다 빈틈이 다를 수 있음).
/// A-014: 영상 레인이 여럿이면 각 시각에 클립이 있는 가장 위 레인만 보인다(A-015부터는 화면 전체를 덮는 가장 위 클립까지 쌓는다).
/// A-015: 클립 크기·위치(ClipTransform)는 레이어 지시의 변형으로 넣고, 쌓음 깊이마다 영상 트랙을 하나 둔다(layeredSegments). 기본 합성기를 쓴다.
/// 사용자 정의 합성기는 쓰지 않는다. 오디오 레인은 레인마다 소리 트랙을 두고 오디오 믹스로 음량을 정한다
/// (2026-10-11부터 레인 음량 × 클립 음량 × 클립 페이드의 선형 경사, volumeRamps).
/// composition 길이는 타임라인 길이(durationFrames)와 같다(앞·중간·끝 빈틈 포함). 클립이 하나도 없으면 만들지 않는다.
/// 끝 빈틈: AVComposition은 트랙 끝의 빈 구간을 길이에 넣지 않는다(검사로 확인: 360프레임 타임라인이 270프레임이 됨).
/// 그래서 끝 빈틈만 영상 트랙을 이미 불러온 원본 구간(프레임 단위 샘플)으로 빈틈 길이만큼 채운다. 그 구간 지시에는 레이어가
/// 없어 화면은 검정 배경만 나온다(채움 프레임은 보이지 않는다). 1프레임을 늘려 채우면 내보내기가 샘플 하나만 만들어
/// 길이가 271프레임으로 줄었다(검사로 확인). 소리 트랙에는 넣지 않는다(무음).
/// M1에는 자막·스펙트럼이 없으므로 AVFoundation 기본 합성기와 레이어 지시(회전 반영, 비율 유지, 검은 여백)를 쓴다.
/// 사용자 정의 합성기(E2Compositor)는 자막·스펙트럼이 들어오는 M2에서 다시 쓴다.
public enum CompositionPlanner {
    public static func plan(_ t: Timeline, media: [UUID: MediaAsset], settings: RenderSettings = .m1) async throws -> PlannedComposition {
        guard !t.isEmpty else { throw PlanError.emptyTimeline }
        let comp = AVMutableComposition()
        guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PlanError.insertFailed("addMutableTrack")
        }
        var loaded: [UUID: (AVURLAsset, AVAssetTrack?, AVAssetTrack?, CMTimeRange?, CMTimeRange?)] = [:]
        var keep: [AVURLAsset] = []
        func load(_ id: UUID) async throws -> (AVURLAsset, AVAssetTrack?, AVAssetTrack?, CMTimeRange?, CMTimeRange?) {
            if let l = loaded[id] { return l }
            guard let m = media[id] else { throw PlanError.missingMedia(id) }
            let a = AVURLAsset(url: m.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            keep.append(a)
            let v = try await a.loadTracks(withMediaType: .video).first
            let au = try await a.loadTracks(withMediaType: .audio).first
            let vr = try await v?.load(.timeRange)
            let ar = try await au?.load(.timeRange)
            let l = (a, v, au, vr, ar)
            loaded[id] = l
            return l
        }
        func blackInstruction(_ r: CMTimeRange) -> AVMutableVideoCompositionInstruction {
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = r
            ins.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ins.layerInstructions = []
            return ins
        }
        var instructions: [AVVideoCompositionInstruction] = []

        // 영상(A-015): 각 시각에 위 레인부터 클립을 쌓고, 출력 화면 전체를 덮는 클립에서 멈춘다(그 아래는 보이지 않으므로 넣지 않음).
        // 쌓은 깊이 d의 클립은 영상 트랙 d에 넣는다. 트랙 0은 늘 가장 위 레이어라, 변형이 없고 16:9 원본이면 A-014의 한 트랙 구성과 같다.
        // 레이어 지시는 위 레이어가 먼저다(AVFoundation 기본 합성기는 첫 레이어를 맨 위에 그린다). 덮이지 않은 곳은 검정 배경이다.
        var tracks: [AVMutableCompositionTrack] = [vt]
        var cursors: [Int] = [0]
        func track(_ d: Int) throws -> AVMutableCompositionTrack {
            while tracks.count <= d {
                guard let n = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw PlanError.insertFailed("addMutableTrack") }
                tracks.append(n); cursors.append(0)
            }
            return tracks[d]
        }
        var cursor = 0
        for seg in try layeredSegments(t, media: media, render: settings.renderSize) {
            let r = CMTimeRange(start: settings.time(seg.start), duration: settings.time(seg.end - seg.start))
            if seg.start > cursor {   // 어느 레인에도 영상이 없는 구간: 빈 구간 + 검정
                let g = CMTimeRange(start: settings.time(cursor), duration: settings.time(seg.start - cursor))
                vt.insertEmptyTimeRange(g); cursors[0] = seg.start
                instructions.append(blackInstruction(g))
            }
            cursor = seg.end
            var layers: [AVVideoCompositionLayerInstruction] = []
            for (d, c) in seg.layers.enumerated() {
                guard let m = media[c.mediaID] else { throw PlanError.missingMedia(c.mediaID) }
                let (_, v, _, vr, _) = try await load(c.mediaID)
                guard let v, let vr else { throw PlanError.insertFailed("no video in \(m.name)") }
                let tr = try track(d)
                if seg.start > cursors[d] { tr.insertEmptyTimeRange(CMTimeRange(start: settings.time(cursors[d]), duration: settings.time(seg.start - cursors[d]))) }
                let src = CMTimeRange(start: vr.start + settings.time(c.sourceIn), duration: r.duration)
                do { try tr.insertTimeRange(src, of: v, at: r.start) } catch { throw PlanError.insertFailed("video \(m.name): \(error.localizedDescription)") }
                cursors[d] = seg.end
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: tr)
                li.setTransform(layerTransform(m, c.effectiveTransform, render: settings.renderSize), at: r.start)
                layers.append(li)
            }
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = r
            ins.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ins.layerInstructions = layers
            instructions.append(ins)
        }
        // 끝 빈틈(영상 클립이 하나도 없으면 전체): 영상이 있는 원본의 프레임 단위 구간으로 채우고 레이어 없는 검정 지시로 가린다
        var hasVideo = cursor >= t.durationFrames
        let fillID = t.clips.first?.mediaID ?? t.media.first(where: { $0.hasVideo && media[$0.id] != nil })?.id
        if t.durationFrames > cursor, let fid = fillID, let n = media[fid]?.frameCount {
            let (_, v, _, vr, _) = try await load(fid)
            if let v, let vr {
                var pos = cursor
                while pos < t.durationFrames {
                    let k = min(n, t.durationFrames - pos)
                    do { try vt.insertTimeRange(CMTimeRange(start: vr.start, duration: settings.time(k)), of: v, at: settings.time(pos)) }
                    catch { throw PlanError.insertFailed("trailing gap: \(error.localizedDescription)") }
                    pos += k
                }
                instructions.append(blackInstruction(CMTimeRange(start: settings.time(cursor), duration: settings.time(t.durationFrames - cursor))))
                hasVideo = true
            }
        }
        if !hasVideo, cursor == 0 { comp.removeTrack(vt) }

        // 오디오 레인(A-014): 음소거하지 않은 레인마다, 그 레인 클립의 원본 (표본율, 채널 수)마다 소리 트랙 하나. 클립은 레인 위치대로,
        // 그 밖의 구간은 같은 표본율·채널 수의 무음 원본으로 채운다(빈 편집을 쓰지 않음). 이 Mac에서 관찰한 것(A-014 기록):
        // 빈 편집 뒤, 또는 다른 표본율 구간 뒤의 44.1 kHz 구간을 48 kHz로 섞어 읽으면 앞 구간 길이에 비례해 앞당겨졌다
        // (빈 편집 80/30 s 뒤 −161표본, 48 kHz 무음 뒤 + 다른 48 kHz 트랙과 섞을 때 −59표본). 같은 표본율 무음으로 채우면 ±1표본이었다.
        // 또 모노 무음 뒤의 스테레오 원본은 내보내기에서 √2배(+3 dB)로 커졌다. 그래서 채널 수도 맞춘다.
        // 원본 시각은 영상과 같은 규칙: 영상 파일은 영상 트랙 시작 + sourceIn/30 s(A-010 동기), 소리 파일은 소리 트랙 시작 + sourceIn/30 s.
        // 여러 트랙은 AVFoundation이 더한다(정규화·리미터 없음, 합이 크면 잘릴 수 있음). 음량은 오디오 믹스의 트랙 음량(그 레인의 모든 트랙에 같게).
        // 소리 트랙이 있으면 늘 오디오 믹스를 붙인다(내보내기 출력은 섞인 소리 트랙 하나).
        var anyAudio = false
        var mixParams: [AVMutableAudioMixInputParameters] = []
        struct AudioShape: Hashable, Comparable {
            let rate: Int, channels: Int
            static func < (a: Self, b: Self) -> Bool { (a.rate, a.channels) < (b.rate, b.channels) }
        }
        var silence: [AudioShape: AVAssetTrack] = [:]
        func fillSilence(_ track: AVMutableCompositionTrack, _ r: CMTimeRange, shape: AudioShape) async throws {
            guard r.duration > .zero else { return }
            if silence[shape] == nil {
                let a = AVURLAsset(url: try SilenceSource.url(rate: shape.rate, channels: shape.channels), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                keep.append(a)
                silence[shape] = try await a.loadTracks(withMediaType: .audio).first
            }
            guard let s = silence[shape] else { throw PlanError.insertFailed("silence \(shape.rate)") }
            var at = r.start
            while at < r.end {
                let d = CMTimeMinimum(SilenceSource.chunk, r.end - at)
                do { try track.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: s, at: at) } catch { throw PlanError.insertFailed("silence: \(error.localizedDescription)") }
                at = at + d
            }
        }
        var shapes: [UUID: AudioShape] = [:]
        func shape(_ id: UUID) async throws -> AudioShape? {
            if let r = shapes[id] { return r }
            guard let au = try await load(id).2,
                  let asbd = try await au.load(.formatDescriptions).first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else { return nil }
            let r = AudioShape(rate: Int(asbd.mSampleRate.rounded()), channels: min(2, max(1, Int(asbd.mChannelsPerFrame))))
            shapes[id] = r
            return r
        }
        for lane in t.lanes(.audio) where !lane.muted {
            var groups: [AudioShape: [Clip]] = [:]
            for c in t.clips(inLane: lane.id) {
                guard let m = media[c.mediaID] else { throw PlanError.missingMedia(c.mediaID) }
                guard let r = try await shape(c.mediaID) else { _ = m; continue }   // 소리 없는 원본: 무음(넣을 것 없음)
                groups[r, default: []].append(c)
            }
            for (r, shaped) in groups.sorted(by: { $0.key < $1.key }) { for clips in volumeTracks(shaped, lane: lane) {
                guard let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw PlanError.insertFailed("audio track") }
                var cursor = CMTime.zero, has = false
                for c in clips {
                    let m = media[c.mediaID]!
                    let (_, _, au, vr, ar) = try await load(c.mediaID)
                    let at0 = settings.time(c.start)
                    try await fillSilence(at, CMTimeRange(start: cursor, end: at0), shape: r)
                    cursor = at0 + settings.time(c.length)
                    guard let au, let ar, let base = (vr ?? ar)?.start else { try await fillSilence(at, CMTimeRange(start: at0, end: cursor), shape: r); continue }
                    let src = CMTimeRange(start: base + settings.time(c.sourceIn), duration: settings.time(c.length))
                    // 원본 소리가 덮는 부분만 넣고 나머지는 무음(소리 파일의 마지막 부분 프레임 포함)
                    let inter = src.intersection(ar)
                    guard inter.duration > .zero else { try await fillSilence(at, CMTimeRange(start: at0, end: cursor), shape: r); continue }
                    let lead = inter.start - src.start
                    try await fillSilence(at, CMTimeRange(start: at0, duration: lead), shape: r)
                    do { try at.insertTimeRange(inter, of: au, at: at0 + lead) } catch { throw PlanError.insertFailed("audio \(m.name): \(error.localizedDescription)") }
                    try await fillSilence(at, CMTimeRange(start: at0 + lead + inter.duration, end: cursor), shape: r)
                    has = true
                }
                if !has { comp.removeTrack(at); continue }
                anyAudio = true
                // 음량이 100%여도 매개변수를 넣는다: 오디오 믹스가 없으면 AVAssetExportSession이 소리 트랙마다 따로(섞지 않고) 써서
                // 흔한 재생기는 첫 트랙만 들린다(2026-10-11 관찰). 믹스가 있으면 모든 트랙을 소리 트랙 하나로 섞는다.
                // 클립 음량·음소거·페이드(2026-10-11): 레인 음량 × 클립 음량 × 페이드 모양을 클립마다 선형 경사로 넣는다(volumeRamps).
                let p = AVMutableAudioMixInputParameters(track: at)
                let ramps = volumeRamps(clips, lane: lane)
                p.setVolume(Float(ramps.first?.from ?? 0), at: .zero)
                for r in ramps {
                    p.setVolumeRamp(fromStartVolume: Float(r.from), toEndVolume: Float(r.to),
                                    timeRange: CMTimeRange(start: settings.time(r.start), duration: settings.time(r.end - r.start)))
                }
                mixParams.append(p)
            } }
        }
        var mix: AVAudioMix? = nil
        if !mixParams.isEmpty { let m = AVMutableAudioMix(); m.inputParameters = mixParams; mix = m.copy() as? AVAudioMix }
        let vc = AVMutableVideoComposition()
        vc.renderSize = settings.renderSize
        vc.frameDuration = settings.frameDuration
        vc.instructions = instructions
        return PlannedComposition(composition: comp.copy() as! AVComposition, videoComposition: vc.copy() as! AVVideoComposition,
                                  durationFrames: t.durationFrames, settings: settings, hasAudio: anyAudio, audioMix: mix, hasVideo: hasVideo, assets: keep,
                                  subtitles: t.renderedSubtitles, spectra: t.spectra)   // 빈 자막은 그리지 않는다(D-037)
    }

    /// 소리 트랙 음량 경사(2026-10-11): 클립마다 페이드 모양의 꺾이는 점 사이를 한 구간으로, 구간 양 끝의 배율
    /// (레인 음량 × 클립 음량 × 페이드 모양, 어느 쪽이든 음소거면 0)을 잇는 선형 경사. 시각은 타임라인 프레임.
    /// 프리뷰와 내보내기가 같은 오디오 믹스를 쓰므로 해석이 같다. 경사 구간은 서로 겹치지 않는다(같은 레인 클립은 겹치지 않음).
    ///
    /// 음량 계단(관찰, 2026-10-11): AVFoundation 오디오 믹스는 한 트랙의 음량이 끊어지는 곳(경사 끝 값 ≠ 다음 경사 시작 값)에서
    /// 그 시각부터 약 512표본(48 kHz에서 10.7 ms) 동안 혼자 선형으로 옮겨 간다. 그래서
    /// - 클립 사이 빈 구간(무음 원본)에는 다음 클립의 시작 값을 미리 둔다(옮겨 가는 동안 소리가 없음). 첫 값도 첫 클립의 시작 값이다.
    /// - 맞닿은 두 클립의 음량이 끊어지면(서로 다른 클립 음량, 음소거 클립, 페이드 끝 값이 다른 곳) 뒤 클립을 다른 소리 트랙에 넣는다
    ///   (volumeTracks, 트랙 둘을 번갈아). 각 트랙에서 끊어짐은 무음 구간에만 생기므로 자른 곳의 계단이 표본 단위로 정확하다.
    public struct VolumeRamp: Sendable, Equatable { public let start: Int; public let end: Int; public let from: Double; public let to: Double }
    public static func volumeRamps(_ clips: [Clip], lane: Lane) -> [VolumeRamp] {
        var out: [VolumeRamp] = []
        for c in clips.sorted(by: { $0.start < $1.start }) {
            let own = clipRamps(c, lane: lane)
            if let last = out.last, let first = own.first, last.end < c.start {   // 빈 구간: 다음 클립 시작 값으로 미리 맞춘다
                out.append(VolumeRamp(start: last.end, end: c.start, from: first.from, to: first.from))
            }
            out += own
        }
        return out
    }
    static func clipRamps(_ c: Clip, lane: Lane) -> [VolumeRamp] {
        let a = c.effectiveAudio, g = (lane.muted ? 0 : Double(lane.volumePercent) / 100) * a.gain
        let b = a.breakpoints(length: c.length)
        return (0..<max(0, b.count - 1)).compactMap { k in
            b[k + 1] > b[k] ? VolumeRamp(start: c.start + b[k], end: c.start + b[k + 1], from: g * a.envelope(at: Double(b[k]), length: c.length),
                                         to: g * a.envelope(at: Double(b[k + 1]), length: c.length)) : nil
        }
    }
    /// 같은 모양(표본율·채널)의 레인 클립을 소리 트랙으로 나눈다: 앞 클립 끝에 맞닿고 음량이 끊어지는 클립은 앞 클립과 다른 트랙(둘을 번갈아),
    /// 그 밖에는 같은 트랙. 끊어짐이 없으면 트랙 하나(이전과 같은 구성).
    public static func volumeTracks(_ clips: [Clip], lane: Lane) -> [[Clip]] {
        var tracks: [[Clip]] = [[], []], cur = 0
        var prev: (end: Int, value: Double)?
        for c in clips.sorted(by: { $0.start < $1.start }) {
            let r = clipRamps(c, lane: lane)
            if let p = prev, p.end == c.start, let f = r.first, abs(f.from - p.value) > 1e-9 { cur ^= 1 }
            tracks[cur].append(c)
            prev = r.last.map { ($0.end, $0.to) }
        }
        return tracks.filter { !$0.isEmpty }
    }
    /// 타임라인 프레임 f(소수 가능)에서 소리 클립 c의 실제 배율(레인 음량·음소거 포함). 검사·표시용으로 volumeRamps와 같은 식이다.
    public static func gain(of c: Clip, lane: Lane, atFrame f: Double) -> Double {
        guard f >= Double(c.start), f < Double(c.end) else { return 0 }
        return (lane.muted ? 0 : Double(lane.volumePercent) / 100) * c.effectiveAudio.gain * c.effectiveAudio.envelope(at: f - Double(c.start), length: c.length)
    }

    /// 클립의 화면 변형(A-015, ClipTransform 좌표계): 기본 맞춤 → 화면 가운데 기준 크기 → 위치. 프리뷰 편집 테두리도 이 값을 쓴다.
    public static func layerTransform(_ m: MediaAsset, _ x: ClipTransform, render: CGSize) -> CGAffineTransform {
        let fit = fitTransform(natural: m.naturalSize, preferred: m.preferredTransform, render: render)
        guard !x.isIdentity else { return fit }
        let cx = render.width / 2, cy = render.height / 2
        return fit.concatenating(CGAffineTransform(translationX: -cx, y: -cy))
            .concatenating(CGAffineTransform(scaleX: x.scale, y: x.scale))
            .concatenating(CGAffineTransform(translationX: cx + x.x, y: cy + x.y))
    }
    /// 출력 화면에서 클립 영상이 차지하는 사각형(화면 밖 포함, 잘리기 전)
    public static func displayRect(_ m: MediaAsset, _ x: ClipTransform, render: CGSize) -> CGRect {
        CGRect(origin: .zero, size: m.naturalSize).applying(layerTransform(m, x, render: render))
    }
    /// 출력 화면 전체를 덮는가(덮으면 그 아래 레인은 보이지 않는다)
    static func covers(_ r: CGRect, _ render: CGSize) -> Bool {
        r.minX <= 0.01 && r.minY <= 0.01 && r.maxX >= render.width - 0.01 && r.maxY >= render.height - 0.01
    }
    /// 겹친 영상 구간(A-015): 클립 경계로 나눈 시간 구간마다 위 레인부터 보이는 클립 조각(원본 위치를 맞춘 Clip)을 쌓는다.
    /// 화면 전체를 덮는 클립에서 멈춘다. 같은 쌓음이 이어지면 한 구간으로 합친다. 아무 레인에도 없으면 구간을 만들지 않는다(빈틈).
    public struct LayeredSegment: Sendable, Equatable { public let start: Int; public let end: Int; public let layers: [Clip] }
    public static func layeredSegments(_ t: Timeline, media: [UUID: MediaAsset], render: CGSize) throws -> [LayeredSegment] {
        var bounds = Set<Int>()
        for c in t.clips { bounds.insert(c.start); bounds.insert(c.end) }
        let b = bounds.sorted()
        let lanes = t.lanes(.video)
        var out: [LayeredSegment] = []
        for k in 0..<max(0, b.count - 1) {
            let lo = b[k], hi = b[k + 1]
            guard hi > lo else { continue }
            let stack = try layerStack(t, lanes: lanes, from: lo, to: hi, media: media, render: render)
                .map { $0.with(start: lo, sourceIn: $0.sourceIn + (lo - $0.start), length: hi - lo) }
            guard !stack.isEmpty else { continue }
            if let last = out.last, last.end == lo, last.layers.map(\.id) == stack.map(\.id) {
                out[out.count - 1] = LayeredSegment(start: last.start, end: hi, layers: last.layers.map { $0.with(length: $0.length + (hi - lo)) })
            } else { out.append(LayeredSegment(start: lo, end: hi, layers: stack)) }
        }
        return out
    }

    /// 시각 구간 [lo, hi)를 모두 덮는 영상 클립의 쌓음(위 레인부터, 화면 전체를 덮는 클립에서 멈춤, 클립은 자르지 않은 원래 값).
    /// layeredSegments와 프리뷰 끌기 화면(재생 헤드 한 프레임)이 같은 규칙을 쓴다.
    public static func layerStack(_ t: Timeline, lanes: [Lane]? = nil, from lo: Int, to hi: Int, media: [UUID: MediaAsset], render: CGSize) throws -> [Clip] {
        var stack: [Clip] = []
        for l in lanes ?? t.lanes(.video) {
            guard let c = t.clips(inLane: l.id).first(where: { $0.start <= lo && hi <= $0.end }) else { continue }
            stack.append(c)
            guard let m = media[c.mediaID] else { throw PlanError.missingMedia(c.mediaID) }
            if covers(displayRect(m, c.effectiveTransform, render: render), render) { break }
        }
        return stack
    }

    /// 회전을 반영하고 비율을 유지해 렌더 크기 가운데에 맞추는 변환
    public static func fitTransform(natural: CGSize, preferred: CGAffineTransform, render: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let base = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let s = min(render.width / rect.width, render.height / rect.height)
        let tx = (render.width - rect.width * s) / 2, ty = (render.height - rect.height * s) / 2
        return base.concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: tx, y: ty))
    }
}

/// 소리 구간 밖을 채우는 무음 원본(A-014): (표본율, 채널 수)마다 16비트 PCM WAV 10초(48 kHz 스테레오면 약 1.9 MB). 임시 폴더에 한 번 만들어 다시 쓴다.
/// 사용자 미디어가 아니며 내보내기 결과에는 무음으로만 들어간다.
public enum SilenceSource {
    static let seconds = 10
    static let chunk = CMTime(value: CMTimeValue(seconds), timescale: 1)
    static let lock = NSLock()
    public static let namePrefix = "OnTheFrame-silence-"
    public static func url(rate: Int, channels ch: Int) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(namePrefix)\(rate)-\(ch)ch-v1.wav")
        let frames = rate * seconds, bytes = frames * ch * 2
        if let n = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int, n == 44 + bytes { return u }
        var d = Data(capacity: 44 + bytes)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + bytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(ch); u32(rate); u32(rate * ch * 2); u16(ch * 2); u16(16)
        d.append(Data("data".utf8)); u32(bytes); d.append(Data(count: bytes))
        try d.write(to: u, options: .atomic)
        return u
    }
}
