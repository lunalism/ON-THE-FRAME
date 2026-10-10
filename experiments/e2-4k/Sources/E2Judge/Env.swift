import E1Core
import E2Core
import Foundation

/// 실행 환경: 경로, fixture(없으면 생성), 편집 타임라인, 선택 오디오 스펙트럼.
public struct E2Env: Sendable {
    public let root: URL, experimentsDir: URL, artifacts: URL, fixtures: URL, cacheDir: URL, resultsDir: URL
    public let sources: [String: URL]
    public let sourceHashes: [String: String]
    public let music: URL
    public let musicHash: String
    public let spectrum: SpectrumCache
    public let timeline: EditTimeline
    public let fixtureInfo: [String: String]

    /// root는 experiments/e2-4k여야 한다.
    /// allowFrameReordering == false이면 진단용 비교 fixture(재정렬 끔)를 쓴다. 기본은 원래 v2 fixture.
    public static func load(root: URL, allowFrameReordering: Bool = true) async throws -> E2Env {
        guard root.lastPathComponent == "e2-4k", FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
            throw E1Error.invalidSource("run from experiments/e2-4k")
        }
        let artifacts = root.appendingPathComponent("artifacts")
        let fixtures = artifacts.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        var info: [String: String] = [:]
        var urls: [String: URL] = [:], hashes: [String: String] = [:]
        for spec in SourceVideoSpec.all {
            let r = try await SourceFixtures.ensure(spec, in: fixtures, allowFrameReordering: allowFrameReordering)
            urls[spec.key] = r.url; hashes[spec.key] = r.sha256
            info[r.url.lastPathComponent] = r.sha256 + (r.created ? String(format: " (created this run, %.1f s)", r.seconds) : "")
        }
        let m = try SourceFixtures.ensureMusic(in: fixtures)
        info[MusicFixture.fileName] = m.sha256 + (m.created ? " (created this run)" : "")
        let cacheDir = artifacts.appendingPathComponent("cache")
        let (cache, _) = try await SpectrumAnalyzer.analyzeSelectedSource(SourceRef(id: m.sha256, path: m.url.path), cacheDir: cacheDir)
        return E2Env(root: root, experimentsDir: root.deletingLastPathComponent(), artifacts: artifacts, fixtures: fixtures, cacheDir: cacheDir,
                     resultsDir: root.appendingPathComponent("results"), sources: urls, sourceHashes: hashes, music: m.url, musicHash: m.sha256,
                     spectrum: cache, timeline: try EditTimeline.e2Experiment(), fixtureInfo: info)
    }

    public var protectedSources: [URL] { Array(sources.values) + [music] }

    public func makeBundle(log: E2Log, timeline t: EditTimeline? = nil, frameTimingFromSourceTrack: Bool = true) async throws -> E2Bundle {
        let overlay = Overlay(spectrum: spectrum, music: .e2, captions: TimedCaption.e2)
        return try await E2CompositionBuilder.build(timeline: t ?? timeline, sources: sources, music: music, placement: .e2, overlay: overlay, log: log,
                                                    frameTimingFromSourceTrack: frameTimingFromSourceTrack)
    }

    public func buildIdentity() -> [String: Any] {
        ["e2SourceTree": BuildIdentity.sourceTree(root: root), "e1SourceTree": BuildIdentity.sourceTree(root: experimentsDir.appendingPathComponent("e1-fhd")),
         "executable": BuildIdentity.executable()]
    }
}
