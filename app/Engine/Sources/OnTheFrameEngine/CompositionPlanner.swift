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
    let assets: [AVURLAsset]
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
/// 빈틈(D-020): 영상·소리 트랙 모두 빈 구간을 넣고, 그 구간의 영상 지시는 레이어 없이 검정 배경이다(소리 없음).
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
        guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PlanError.insertFailed("addMutableTrack")
        }
        var loaded: [UUID: (AVURLAsset, AVAssetTrack, AVAssetTrack?, CMTimeRange, CMTimeRange?)] = [:]
        var keep: [AVURLAsset] = []
        var instructions: [AVVideoCompositionInstruction] = []
        var anyAudio = false
        var cursor = 0
        func gap(_ from: Int, _ to: Int) {
            guard to > from else { return }
            let r = CMTimeRange(start: settings.time(from), duration: settings.time(to - from))
            vt.insertEmptyTimeRange(r)
            at.insertEmptyTimeRange(r)
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = r
            ins.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ins.layerInstructions = []
            instructions.append(ins)
        }
        for c in t.clips {
            gap(cursor, c.start)
            cursor = c.end
            guard let m = media[c.mediaID] else { throw PlanError.missingMedia(c.mediaID) }
            if loaded[c.mediaID] == nil {
                let a = AVURLAsset(url: m.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                keep.append(a)
                guard let v = try await a.loadTracks(withMediaType: .video).first else { throw PlanError.insertFailed("no video in \(m.name)") }
                let au = try await a.loadTracks(withMediaType: .audio).first
                let vr = try await v.load(.timeRange)
                let ar = try await au?.load(.timeRange)
                loaded[c.mediaID] = (a, v, au, vr, ar)
            }
            let (_, v, au, vr, ar) = loaded[c.mediaID]!
            let at0 = settings.time(c.start)
            let src = CMTimeRange(start: vr.start + settings.time(c.sourceIn), duration: settings.time(c.length))
            do { try vt.insertTimeRange(src, of: v, at: at0) } catch { throw PlanError.insertFailed("video \(m.name): \(error.localizedDescription)") }
            // 연결된 소리: 원본 오디오가 덮는 부분만 넣고 나머지는 빈 구간
            let target = CMTimeRange(start: at0, duration: src.duration)
            if let au, let ar {
                let inter = src.intersection(ar)
                if inter.duration > .zero {
                    let lead = inter.start - src.start
                    if lead > .zero { at.insertEmptyTimeRange(CMTimeRange(start: at0, duration: lead)) }
                    do { try at.insertTimeRange(inter, of: au, at: at0 + lead) } catch { throw PlanError.insertFailed("audio \(m.name): \(error.localizedDescription)") }
                    let tail = src.end - inter.end
                    if tail > .zero { at.insertEmptyTimeRange(CMTimeRange(start: at0 + lead + inter.duration, duration: tail)) }
                    anyAudio = true
                } else { at.insertEmptyTimeRange(target) }
            } else { at.insertEmptyTimeRange(target) }
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = target
            ins.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
            li.setTransform(fitTransform(natural: m.naturalSize, preferred: m.preferredTransform, render: settings.renderSize), at: at0)
            ins.layerInstructions = [li]
            instructions.append(ins)
        }
        if t.durationFrames > cursor, let first = t.clips.first, let (_, v, _, vr, _) = loaded[first.mediaID], let n = media[first.mediaID]?.frameCount {
            let r = CMTimeRange(start: settings.time(cursor), duration: settings.time(t.durationFrames - cursor))
            var at = cursor
            while at < t.durationFrames {
                let k = min(n, t.durationFrames - at)
                do { try vt.insertTimeRange(CMTimeRange(start: vr.start, duration: settings.time(k)), of: v, at: settings.time(at)) }
                catch { throw PlanError.insertFailed("trailing gap: \(error.localizedDescription)") }
                at += k
            }
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = r
            ins.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ins.layerInstructions = []
            instructions.append(ins)
        }
        if !anyAudio { comp.removeTrack(at) }
        let vc = AVMutableVideoComposition()
        vc.renderSize = settings.renderSize
        vc.frameDuration = settings.frameDuration
        vc.instructions = instructions
        return PlannedComposition(composition: comp.copy() as! AVComposition, videoComposition: vc.copy() as! AVVideoComposition,
                                  durationFrames: t.durationFrames, settings: settings, hasAudio: anyAudio, assets: keep)
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
