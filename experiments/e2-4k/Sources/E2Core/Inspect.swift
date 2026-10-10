import AVFoundation
import CoreMedia
import E1Core
import Foundation

/// 진단: 인코딩된 비디오 샘플 구조와 composition 구간 대응을 읽는다(디코딩하지 않고 압축 샘플의 타이밍만).
public enum EncodingInspector {
    public struct Sample: Codable, Sendable {
        public let index: Int          // 저장(디코딩) 순서
        public let pts: String         // value/timescale
        public let dts: String
        public let ptsFrame: Int       // PTS의 프레임 번호(30 fps 반올림)
        public let sync: Bool
        public let dependsOnOthers: Bool?
    }
    public struct Report: Codable, Sendable {
        public let file: String
        public let naturalTimeScale: Int32
        public let minFrameDuration: String
        public let sampleCount: Int
        public let reorderedSamples: Int      // DTS != PTS 인 샘플 수
        public let maxPtsMinusDtsFrames: Double
        public let syncFrames: [Int]           // 동기 샘플의 PTS 프레임
        public let codec: String
        public let formatExtensions: [String: String]
        public let firstSamples: [Sample]      // 저장 순서 처음 N개
        public let samplesAround: [String: [Sample]]   // 관심 프레임 주변(저장 순서)
    }

    public static func inspect(_ url: URL, around frames: [Int], first n: Int = 12) async throws -> Report {
        let asset = AVURLAsset(url: url)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else { throw E1Error.invalidSource("no video") }
        let ts = try await vt.load(.naturalTimeScale)
        let mfd = try await vt.load(.minFrameDuration)
        var codec = "-"
        var ext: [String: String] = [:]
        if let fd = try await vt.load(.formatDescriptions).first {
            let st = CMFormatDescriptionGetMediaSubType(fd)
            codec = String(bytes: [UInt8((st >> 24) & 0xFF), UInt8((st >> 16) & 0xFF), UInt8((st >> 8) & 0xFF), UInt8(st & 0xFF)], encoding: .ascii) ?? "\(st)"
            for (k, v) in (CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]) where !(v is Data) && !(v is [String: Any]) {
                ext[k] = "\(v)"
            }
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: vt, outputSettings: nil)   // 압축 샘플 그대로
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw E1Error.reader("inspect: \(reader.error?.localizedDescription ?? "-")") }
        var all: [Sample] = []
        var maxLead = 0.0
        var reordered = 0
        while let sb = out.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sb)
            guard count > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb), dts = CMSampleBufferGetDecodeTimeStamp(sb)
            var sync = true, depends: Bool?
            if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let a = arr.first {
                sync = !((a[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
                depends = a[kCMSampleAttachmentKey_DependsOnOthers] as? Bool
            }
            if dts.isNumeric && pts != dts { reordered += 1; maxLead = max(maxLead, (pts - dts).seconds * 30) }
            all.append(Sample(index: all.count, pts: "\(pts.value)/\(pts.timescale)", dts: dts.isNumeric ? "\(dts.value)/\(dts.timescale)" : "-",
                              ptsFrame: Int((pts.seconds * 30).rounded()), sync: sync, dependsOnOthers: depends))
        }
        var around: [String: [Sample]] = [:]
        for f in frames {
            guard let i = all.firstIndex(where: { $0.ptsFrame == f }) else { continue }
            around["\(f)"] = Array(all[max(0, i - 4)..<min(all.count, i + 6)])
        }
        return Report(file: url.lastPathComponent, naturalTimeScale: ts, minFrameDuration: "\(mfd.value)/\(mfd.timescale)", sampleCount: all.count,
                      reorderedSamples: reordered, maxPtsMinusDtsFrames: maxLead, syncFrames: all.filter { $0.sync }.map { $0.ptsFrame },
                      codec: codec, formatExtensions: ext, firstSamples: Array(all.prefix(n)), samplesAround: around)
    }

    /// composition 비디오 트랙의 구간 대응(대상 시간 범위 → 원본 시간 범위)
    public static func segments(_ comp: AVComposition, trackID: CMPersistentTrackID) -> [[String: String]] {
        guard let t = comp.track(withTrackID: trackID) else { return [] }
        return t.segments.map { s in
            let m = s.timeMapping
            return ["target": "\(m.target.start.value)/\(m.target.start.timescale) +\(m.target.duration.value)/\(m.target.duration.timescale)",
                    "source": "\(m.source.start.value)/\(m.source.start.timescale) +\(m.source.duration.value)/\(m.source.duration.timescale)",
                    "empty": "\(s.isEmpty)", "sourceTrackID": "\(s.sourceTrackID)", "url": s.sourceURL?.lastPathComponent ?? "-"]
        }
    }
}
