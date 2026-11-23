import AVFoundation
import Foundation
@testable import OnTheFrameEngine
import XCTest

/// E1 시험의 클립 배치. 원본은 2 s(60프레임), 소리는 원본 프레임 30(파일 시각 1.0 s)에서 0.2 s 동안 난다.
struct SourceTimeLayout {
    let name: String
    /// (타임라인 시작, 원본 시작, 길이) — 프레임
    let pieces: [(start: Int, sourceIn: Int, length: Int)]
    /// 원점이 0일 때 손으로 계산한 소리 시작(타임라인 표본) = (start + 30 − sourceIn) · 1600, 소리가 든 조각마다
    let expected: [Int]
    /// 어느 조각도 덮지 않는 타임라인 프레임 구간
    let gaps: [Range<Int>]

    static let whole = SourceTimeLayout(name: "whole", pieces: [(0, 0, 60)], expected: [48_000], gaps: [])
    /// D: 앞뒤를 자름
    static let trimmed = SourceTimeLayout(name: "trimmed", pieces: [(0, 15, 30)], expected: [24_000], gaps: [])
    /// F: 옮김(앞은 빈 구간)
    static let moved = SourceTimeLayout(name: "moved", pieces: [(20, 0, 60)], expected: [80_000], gaps: [0 ..< 20])
    /// E: 원본 프레임 24에서 나눔 — 소리는 둘째 조각에 있다
    static let split = SourceTimeLayout(name: "split", pieces: [(0, 0, 24), (24, 24, 36)], expected: [48_000], gaps: [])
    /// G·H: 같은 원본의 두 조각과 그 사이 빈 구간
    static let lineageWithGap = SourceTimeLayout(name: "lineage+gap", pieces: [(0, 15, 30), (50, 20, 30)], expected: [24_000, 96_000], gaps: [30 ..< 50])
    static let all = [whole, trimmed, moved, split, lineageWithGap]

    func timeline(_ m: MediaAsset) -> Timeline {
        Timeline(audioClips: pieces.map { Clip(mediaID: m.id, start: $0.start, sourceIn: $0.sourceIn, length: $0.length, lane: Lane.audioID) }).registering(m)
    }
    var analysisPieces: [SpectrumSourcePiece] { pieces.map { SpectrumSourcePiece(start: $0.start, length: $0.length, sourceIn: $0.sourceIn) } }
    var endFrame: Int { pieces.map { $0.start + $0.length }.max() ?? 0 }
}

extension SourceTimeOriginTests {
    typealias Layout = SourceTimeLayout

    func wav() async throws -> URL {
        let url = dir.appendingPathComponent("zero.wav")
        if !FileManager.default.fileExists(atPath: url.path) { try await F.write(url, type: .wav, audio: F.lpcm, audioStart: 0, video: false) }
        return url
    }

    /// 한 배치에서: 재생에서 들리는 시작 위치 = 분석이 읽는 시작 위치(± tolerance 표본). absolute면 손 계산값과도 비교한다.
    func compare(_ layout: Layout, media m: MediaAsset, tolerance: Int, absolute: Bool,
                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let label = "\(m.name) \(layout.name)"
        let plan = try await CompositionPlanner.plan(layout.timeline(m), media: [m.id: m])
        let heard = try await F.playback(plan)
        let source = try await SpectrumFileSource.open(url: m.url, mediaID: m.id)
        let analysed = try await F.analysisOnsets(layout.analysisPieces, source: source, timelineFrames: layout.endFrame)
        let played = F.onsets(heard)
        XCTAssertEqual(played.count, layout.expected.count, "\(label): 재생에서 들리는 횟수 \(played)", file: file, line: line)
        XCTAssertEqual(analysed.count, played.count, "\(label): 분석 \(analysed) 재생 \(played)", file: file, line: line)
        for (a, p) in zip(analysed, played) {
            XCTAssertEqual(a, p, accuracy: tolerance, "\(label): 분석과 재생의 시작 위치", file: file, line: line)
        }
        if absolute {
            for (p, e) in zip(played, layout.expected) { XCTAssertEqual(p, e, accuracy: tolerance, "\(label): 손 계산값", file: file, line: line) }
        }
        checkGaps(layout, heard: heard, label: label, file: file, line: line)
    }
    /// H: 조각이 덮지 않는 구간은 재생에서 무음이고 분석도 읽지 않는다
    func checkGaps(_ layout: Layout, heard: [Float], label: String, file: StaticString, line: UInt) {
        let window = 0 ..< SpectrumFrameMap.sample(atFrame: layout.endFrame, fps: 30, rate: F.rate)
        let spans = SpectrumAnalysis.sourceSpans(layout.analysisPieces, window: window, fps: 30, rate: F.rate)
        for gap in layout.gaps {
            let lo = gap.lowerBound * 1_600, hi = min(heard.count, gap.upperBound * 1_600)
            guard lo < hi else { continue }
            XCTAssertLessThan(heard[lo..<hi].map(abs).max() ?? 0, 0.01, "\(label): 빈 구간은 무음", file: file, line: line)
            XCTAssertFalse(spans.contains { $0.timeline.lowerBound < hi && lo < $0.timeline.upperBound }, "\(label): 분석이 빈 구간을 읽지 않는다", file: file, line: line)
        }
    }
}
