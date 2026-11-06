#if DEBUG
import AppKit
import AVFoundation
import OnTheFrameEngine

/// 편집 뒤 프리뷰 갱신 자체 검사(완료 기준 4, Debug 전용, 일반 화면에 없음).
/// `open -n -W -a OnTheFrame.app <폴더> --args -OTFPreviewTest`. 내보내기는 하지 않는다.
/// 실제 앱 경로(ProjectStore 편집 → timelineChanged → 프리뷰 AVPlayer 항목 교체)를 쓰고, 고정 재생 헤드(프레임 100)에서
/// 프리뷰 항목의 프레임을 비디오 출력(AVPlayerItemVideoOutput)으로 받아 <폴더>/preview/에 BGRA로 저장한다.
/// 판정은 앱 밖의 `otf-dev verify-preview`가 화면 코드(원본 ID·원본 프레임) 또는 검정으로 하고, 기대값은 아래에 손으로 적었다.
@MainActor
enum PreviewSelfTest {
    struct Step: Codable { let name: String; let file: String?; let expected: String; let playhead: Int; let generation: Int; let applied: Int }
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }
    struct Manifest: Codable { let width: Int; let height: Int; var steps: [Step]; var checks: [Check] }

    static func runSpectrum(folder: URL) async {
        let store = ProjectStore()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = PlayerNSView()
        view.playerLayer.player = store.player
        window.contentView = view
        store.previewHost = view
        window.orderFront(nil)
        var lines: [String] = []
        func check(_ name: String, _ passed: Bool) { lines.append("\(passed ? "PASS" : "FAIL") \(name)") }
        defer {
            try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("spectrum-playback.txt"), atomically: true, encoding: .utf8)
            window.orderOut(nil)
            NSApp.terminate(nil)
        }
        let urls = ["otf-A.mp4", "aud-wav48s.wav"].map { folder.appendingPathComponent($0) }
        store.importFiles(urls)
        guard await waitUntil(15, { store.importing == 0 && store.assets.count == 2 }),
              let video = store.assets.first(where: { $0.url.lastPathComponent == "otf-A.mp4" }),
              let audio = store.assets.first(where: { $0.id != video.id }) else { check("fixtures", false); return }
        store.addToTimeline(video.id)
        store.addLane(.audio)
        store.seek(to: 0)
        store.addToTimeline(audio.id)
        guard let clip = store.timeline.audioClips.first(where: { $0.mediaID == audio.id }) else { check("selected WAV", false); return }
        store.addSpectrum(fromAudioClip: clip.id, session: store.projectSession)
        guard let entry = store.timeline.spectra.first,
              await waitUntil(15, { store.appliedGeneration == store.generation && store.player.currentItem?.status == .readyToPlay }) else { check("setup", false); return }
        store.seek(to: clip.start)
        check("paused", await waitUntil(5) { view.spectrumOverlay.layers[entry.id]?.contents != nil })
        store.play()
        var frames = Set<Int>()
        func sample() -> Bool {
            if let f = store.spectrumPreview.playback.currentFrame, view.spectrumOverlay.layers[entry.id]?.contents != nil,
               frames.insert(f).inserted {
                lines.append("timeline=\(f) source=\(clip.sourceIn + f - clip.start) playerSeconds=\(store.player.currentTime().seconds)")
            }
            return frames.count >= 5
        }
        check("continuous distinct frames", await waitUntil(4, sample))
        store.pause()
        check("pause confirmation", await waitUntil(3) { view.spectrumOverlay.confirmedFrame == store.playhead && view.spectrumOverlay.layers[entry.id]?.contents != nil })
        store.seek(to: 45); store.seek(to: 12)
        check("latest seek", await waitUntil(3) { view.spectrumOverlay.confirmedFrame == 12 && view.spectrumOverlay.layers[entry.id]?.contents != nil })
        frames.removeAll()
        store.play()
        check("resume", await waitUntil(4, sample))
        check("end", await waitUntil(12) { !store.isPlaying && store.playhead == store.timeline.durationFrames && view.spectrumOverlay.layers.isEmpty })
        store.seek(to: 0); store.play(); store.resetProject()
        check("replace", await waitUntil(3) { store.player.currentItem == nil && store.spectrumPreview.playback.currentFrame == nil && view.spectrumOverlay.layers.isEmpty })
    }

    enum AudioIntervalFixture: String {
        case tail = "audio-tail", gap = "video-gap", lead = "audio-lead", audio = "pure-audio"
    }

    /// Each 30 fps fixture uses a 12-second selected WAV clip trimmed by one second.
    static func runAudioInterval(folder: URL, fixture: AudioIntervalFixture) async {
        let videoRanges: [Range<Int>], targets: [Int], pauseFrame: Int, seekFrames: [Int]
        switch fixture {
        case .audio:
            videoRanges = []
            targets = [15, 60, 90, 120, 180, 240, 270, 300, 330, 357]
            pauseFrame = 60
            seekFrames = [300, 90, 330, 270]
        case .lead:
            videoRanges = [120..<360]
            targets = [15, 60, 117, 120, 123, 180, 240, 300, 357]
            pauseFrame = 60
            seekFrames = [180, 60, 120, 300]
        case .gap:
            videoRanges = [0..<120, 240..<360]
            targets = [117, 120, 123, 180, 237, 240, 243, 270, 357]
            pauseFrame = 180
            seekFrames = [180, 90, 120, 270, 180, 240, 90]
        case .tail:
            videoRanges = [0..<120, 120..<240]
            targets = [239, 240, 245, 270, 330]
            pauseFrame = 270
            seekFrames = [270, 300, 90, 330]
        }
        let store = ProjectStore.shared
        var log: [String] = []
        func check(_ name: String, _ pass: Bool) { log.append("\(pass ? "PASS" : "FAIL") \(name)") }
        defer {
            try? log.joined(separator: "\n").write(to: folder.appendingPathComponent(fixture.rawValue + ".txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        guard await store.openProject(at: folder.appendingPathComponent("test.ontheframe")),
              await waitUntil(15, { store.player.currentItem?.status == .readyToPlay && store.previewHost?.window != nil }),
              let view = store.previewHost, let item = store.player.currentItem,
              let entry = store.timeline.spectra.first, let clip = store.timeline.audioClips.first,
              entry.sourceKey == clip.lineageKey, let media = store.mediaByID[clip.mediaID] else { check("setup", false); return }
        let controller = store.spectrumPreview.playback
        do {
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            var ends: [Double] = []
            for track in tracks { ends.append(try await track.load(.timeRange).end.seconds) }
            log.append("itemSeconds=\(item.duration.seconds) audioTrackEnds=\(ends) visualEnd=\(store.timeline.clips.map(\.end).max() ?? -1) source=\(clip.lineageKey)")
            let ranges = store.timeline.clips.sorted { $0.start < $1.start }.map { $0.start..<$0.end }
            check("duration", item.duration.seconds == 12 && ends.contains(12) &&
                  ranges == videoRanges)
            if fixture != .tail {
                var wavMappings: [CMTimeMapping] = []
                for track in tracks {
                    for segment in try await track.load(.segments) where !segment.isEmpty {
                        guard let source = (segment as? AVCompositionTrackSegment)?.sourceURL,
                              source.standardizedFileURL == media.url.standardizedFileURL else { continue }
                        wavMappings.append(segment.timeMapping)
                    }
                }
                check("selected WAV spans both boundaries without a splice", wavMappings.count == 1 &&
                      wavMappings.first?.source == CMTimeRange(start: store.settings.time(30), duration: item.duration) &&
                      wavMappings.first?.target == CMTimeRange(start: .zero, duration: item.duration))
                if fixture == .audio {
                    let videos = try await item.asset.loadTracks(withMediaType: .video)
                    check("no video track or composition", videos.isEmpty && item.videoComposition == nil && !InternalImagePreview.containsImages(store.timeline))
                    check("black preview background", view.layer?.backgroundColor == NSColor.black.cgColor && !view.isShowingStill && view.window?.isVisible == true)
                } else {
                    log += try await recordIntervalPictures(store, item: item, folder: folder, targets: targets, videoRanges: videoRanges)
                }
            }
            let settings = entry.style.analysisSettings
            let reference = try await Task.detached {
                let source = try await SpectrumFileSource.open(url: media.url)
                var chunks: [Int: [[Float]]] = [:]
                let pieces = [SpectrumSourcePiece(start: 0, length: media.frameCount, sourceIn: 0)]
                var values: [Int: [Float]] = [:]
                for frame in targets {
                    let needed = try SpectrumAnalysis.chunks(frame: frame + 30, pieces: pieces, fps: 30,
                        rate: source.sampleRate, settings: settings, chunkSamples: source.chunkSamples)
                    for index in needed where chunks[index] == nil { chunks[index] = try await source.decodeChunk(index) }
                    values[frame] = try SpectrumAnalysis.bands(frame: frame + 30, pieces: pieces, fps: 30,
                        rate: source.sampleRate, channelCount: source.channelCount, chunkSamples: source.chunkSamples,
                        settings: settings) { chunks[$0] }
                }
                return values
            }.value
            store.seek(to: fixture == .tail ? 220 : 0)
            _ = await waitUntil(3) { !view.hasPendingSpectrumSeek }
            store.play()
            var seen = Set<Int>()
            var awaitingDisplay = Set<Int>()
            let deadline = Date().addingTimeInterval(fixture == .tail ? 8 : 16)
            while store.isPlaying && Date() < deadline {
                if let frame = controller.currentFrame, let expected = reference[frame], !seen.contains(frame),
                   case let .ready(bands, rendered) = controller.currentOutcome(spectrum: entry.id, frame: frame) {
                    let displayed = view.spectrumOverlay.layers[entry.id]?.contents
                    if rendered != nil && displayed == nil {
                        if awaitingDisplay.insert(frame).inserted {
                            log.append("awaiting display frame=\(frame) playerSeconds=\(item.currentTime().seconds)")
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        continue
                    }
                    let matchesDisplay: Bool
                    if let rendered {
                        matchesDisplay = displayed as AnyObject? === rendered.image
                    } else {
                        matchesDisplay = displayed == nil && expected.allSatisfy { $0 == 0 }
                    }
                    seen.insert(frame)
                    let time = item.currentTime()
                    log.append("timeline=\(frame) source=\(frame + 30) playerSeconds=\(time.seconds) visible=\(displayed != nil) peak=\(bands.max() ?? -1)")
                    check("display, bands and clock \(frame)", matchesDisplay && bands == expected && abs(time.seconds * 30 - Double(frame)) < 2)
                    if frame == pauseFrame || (fixture == .audio && frame == 270) {
                        store.pause()
                        let stopped = store.playhead
                        let settled = await waitUntil(2) { view.spectrumOverlay.confirmedFrame == stopped && view.spectrumOverlay.layers[entry.id]?.contents != nil }
                        check("pause at target", abs(stopped - frame) <= 1 && settled && controller.currentFrame == nil)
                        store.play()
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            let boundary = (fixture == .lead || fixture == .audio) ? 120 : 240
            let following = fixture == .audio ? 240 : boundary + (fixture == .tail ? 5 : 3)
            check("continuous interval", seen == Set(targets) && reference[boundary] != reference[following])
            let drained = await waitUntil(2) { controller.pendingCount == 0 }
            check("end", drained && !store.isPlaying && store.playhead == 360 && controller.currentFrame == nil && view.spectrumOverlay.layers.isEmpty)
            for frame in seekFrames {
                store.seek(to: frame)
                check("paused \(frame)", await waitUntil(3) { view.spectrumOverlay.confirmedFrame == frame && view.spectrumOverlay.layers[entry.id]?.contents != nil })
                store.play()
                check("resume \(frame)", await waitUntil(2) {
                    guard let current = controller.currentFrame else { return false }
                    return (frame..<frame + 12).contains(current) && view.spectrumOverlay.layers[entry.id]?.contents != nil
                })
                store.pause()
                let frozen = store.playhead
                check("freeze \(frozen)", await waitUntil(2) { view.spectrumOverlay.confirmedFrame == frozen && controller.currentFrame == nil })
            }
            if fixture == .audio {
                store.seek(to: 360)
                _ = await waitUntil(3) { !view.hasPendingSpectrumSeek }
                store.play()
                check("audio-only replay", await waitUntil(3) { (controller.currentFrame ?? -1) > 0 && (controller.currentFrame ?? 360) < 30 })
                store.pause()
            }
            store.selection = entry.id
            store.setSpectrumSource(entry.id, key: nil, from: store.timeline.spectrum(entry.id)?.sourceKey, project: store.projectSession)
            let unsetFrame = fixture == .tail ? 300 : pauseFrame
            store.seek(to: unsetFrame)
            _ = await waitUntil(2) { !view.hasPendingSpectrumSeek }
            store.play()
            let advanced = await waitUntil(2) { store.settings.frame(containing: item.currentTime()) >= unsetFrame + 10 }
            let expectedClock = (fixture == .lead || fixture == .audio) ? controller.currentFrame == nil : controller.currentFrame != nil
            check("unset source stays blank while WAV plays", advanced && expectedClock && store.timeline.spectrum(entry.id)?.sourceKey == nil &&
                  controller.retainedCount == 0 && view.spectrumOverlay.layers.isEmpty)
            if fixture == .audio {
                store.pause()
                store.setSpectrumSource(entry.id, key: entry.sourceKey, from: nil, project: store.projectSession)
                try await checkAudioEdits(store, entry: entry, clip: clip, media: media, check: check)
            }
            store.resetProject()
            check("replacement", await waitUntil(3) { store.player.currentItem == nil && controller.pendingCount == 0 && view.spectrumOverlay.layers.isEmpty })
        } catch { check(String(describing: error), false) }
    }

    /// Real store edits on the disposable audio-only project; oracle mapping is explicit.
    private static func checkAudioEdits(_ store: ProjectStore, entry: SpectrumItem, clip: Clip,
                                        media: MediaAsset, check: (String, Bool) -> Void) async throws {
        let left = UUID(), right = UUID()
        store.commit({ timeline in
            // Existing ripple trim rejects overlays crossing the cut. Prepare this edit
            // fixture without overlays, then restore the selected spectrum after editing.
            var bare = try timeline.liftingSpectrum(entry.id)
            for subtitle in timeline.subtitles { bare = try bare.liftingSubtitle(subtitle.id) }
            let split = try bare.splitting(clip: clip.id, atFrame: 180, newIDs: (left, right))
            let trimmed = try split.trimmingStart(clip: left, by: 10).trimmingEnd(clip: left, by: -30)
            let moved = try trimmed.relocating(clip: right, toStart: 180, lane: clip.lane)
                .relocating(clip: left, toStart: 30, lane: clip.lane)
            return try moved.addingSpectrum(lane: entry.lane, at: 0, length: 360,
                                           sourceKey: entry.sourceKey, style: entry.style, id: entry.id)
        }, focus: left)
        guard await waitUntil(10, { store.appliedGeneration == store.generation && store.player.currentItem?.status == .readyToPlay }),
              let view = store.previewHost else { check("edited audio setup", false); return }
        check("split trim move lineage", store.timeline.clip(left)?.lineageKey == clip.lineageKey &&
              store.timeline.clip(right)?.lineageKey == clip.lineageKey && store.timeline.clip(left)?.sourceIn == 40 &&
              store.timeline.clip(left)?.start == 30 && store.timeline.clip(right)?.sourceIn == 210)
        let settings = entry.style.analysisSettings
        let expected = try await Task.detached {
            let source = try await SpectrumFileSource.open(url: media.url)
            let pieces = [SpectrumSourcePiece(start: 0, length: media.frameCount, sourceIn: 0)]
            var chunks: [Int: [[Float]]] = [:], result: [Int: [Float]] = [:]
            for frame in Array(80...95) + Array(240...255) {
                let sourceFrame = frame < 180 ? frame + 10 : frame + 30
                for index in try SpectrumAnalysis.chunks(frame: sourceFrame, pieces: pieces, fps: 30, rate: source.sampleRate, settings: settings, chunkSamples: source.chunkSamples) where chunks[index] == nil {
                    chunks[index] = try await source.decodeChunk(index)
                }
                result[frame] = try SpectrumAnalysis.bands(frame: sourceFrame, pieces: pieces, fps: 30, rate: source.sampleRate, channelCount: source.channelCount, chunkSamples: source.chunkSamples, settings: settings) { chunks[$0] }
            }
            return result
        }.value
        for target in [80, 240] {
            store.seek(to: target)
            _ = await waitUntil(3) { !view.hasPendingSpectrumSeek }
            store.play()
            check("edited selected FFT and visible layer \(target)", await waitUntil(3) {
                let controller = store.spectrumPreview.playback
                guard let frame = controller.currentFrame, (target...target + 15).contains(frame),
                      case let .ready(bands, rendered?) = controller.currentOutcome(spectrum: entry.id, frame: frame) else { return false }
                return bands == expected[frame] && view.spectrumOverlay.layers[entry.id]?.contents as AnyObject? === rendered.image
            })
            store.pause()
        }
        store.seek(to: 175) // Gap between edited pieces: no selected coverage.
        _ = await waitUntil(3) { !view.hasPendingSpectrumSeek }
        store.play()
        check("edited source gap blank", await waitUntil(1) {
            let frame = store.settings.frame(containing: store.player.currentTime())
            return (175..<180).contains(frame) && store.spectrumPreview.playback.currentFrame == nil && view.spectrumOverlay.layers.isEmpty
        })
        store.pause()
    }

    static func runSubtitleBoundaries(folder: URL) async {
        let store = ProjectStore.shared
        var rows: [String] = []
        defer {
            try? rows.joined(separator: "\n").write(to: folder.appendingPathComponent("boundary.tsv"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        guard await store.openProject(at: folder.appendingPathComponent("test.ontheframe")),
              await waitUntil(10, { store.previewHost?.window != nil }), let view = store.previewHost,
              await waitUntil(15, { store.player.currentItem?.status == .readyToPlay && view.subtitleBoundItem === store.player.currentItem }) else {
            rows.append("setup failed"); return
        }
        let targets = [0, 117, 120, 123, 150, 180, 237, 240, 243, 270, 357, 360]
        for entry in store.timeline.subtitles {
            rows.append("item \(entry.id) \(entry.text) [\(entry.start),\(entry.end))")
        }
        rows.append("phase\ttarget\tplayerSeconds\tframe\tgeneration\tbound\texpected\tpresented\topacities\traster\tspectrumFrame")
        func record(_ phase: String, _ target: Int) {
            let time = store.player.currentTime(), f = store.settings.frame(containing: time)
            let entries = store.timeline.subtitles
            let layers = entries.map { view.subtitleLayerForTest($0.id) }
            let alpha = layers.map { $0?.presentation()?.opacity ?? -1 }
            let present = entries.indices.filter { alpha[$0] > 0.5 && layers[$0]?.presentation()?.contents != nil && layers[$0]?.presentation()?.isHidden == false }
            let expected = store.timeline.subtitles(atFrame: f).map { $0.id.uuidString }
            let fields = [phase, String(target), String(time.seconds), String(f), String(view.subtitleGenerationForTest),
                          String(view.subtitleBoundItem === store.player.currentItem), expected.joined(separator: ","),
                          present.map { entries[$0].id.uuidString }.joined(separator: ","), String(describing: alpha),
                          String(describing: layers.map { $0?.contents != nil }), String(store.spectrumPreview.playback.currentFrame ?? -1)]
            rows.append(fields.joined(separator: "\t"))
        }
        for frame in targets + [180, 61, 0] {
            store.seek(to: frame)
            guard await waitUntil(4, { !view.hasPendingSpectrumSeek }) else { rows.append("seek timeout"); return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            record("seek", frame)
        }
        func play() {
            store.play()
            if ProcessInfo.processInfo.arguments.contains("-OTFDisableSpectrumTicks") { view.spectrumOverlay.stopPlaybackLink() }
        }
        play()
        for frame in targets {
            _ = await waitUntil(6) { store.settings.frame(containing: store.player.currentTime()) >= frame }
            record("play", frame)
        }
        _ = await waitUntil(2) { !store.isPlaying }
        play()
        _ = await waitUntil(3) { store.isPlaying && store.playhead > 1 && store.playhead < 30 }
        record("replay", 0)
        store.pause()
        for frame in [180, 61, 270] {
            store.seek(to: frame)
            guard await waitUntil(4, { !view.hasPendingSpectrumSeek }) else { rows.append("seek timeout"); return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            record("postPlaybackSeek", frame)
            play()
            _ = await waitUntil(3) { store.playhead >= frame + 3 }
            record("resume", frame + 3)
            store.pause()
        }
    }

    static let P = 100

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        let src = folder.appendingPathComponent("sources"), out = folder.appendingPathComponent("preview")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var m = Manifest(width: 1920, height: 1080, steps: [], checks: [])
        func check(_ n: String, _ p: Bool, _ d: String = "") { m.checks.append(Check(name: n, pass: p, detail: d)) }

        s.importFiles([src.appendingPathComponent("otf-A.mp4"), src.appendingPathComponent("otf-B.mp4")])
        _ = await waitUntil(30) { s.assets.count == 2 && s.importing == 0 }
        guard let a = s.assets.first(where: { $0.name == "otf-A.mp4" }), let b = s.assets.first(where: { $0.name == "otf-B.mp4" }) else {
            check("setup.import", false); return finish(folder, m)
        }
        // A(120)@0, B(90)@120, 재생 헤드 100
        s.addToTimeline(a.id); s.addToTimeline(b.id)
        s.seek(to: P)
        let output = Output()

        /// 현재 상태가 적용되기를 기다려 프레임 P를 저장하고 기대값을 기록한다
        func capture(_ name: String, _ expected: String) async {
            let ready = await waitUntil(20) { s.appliedGeneration == s.generation && s.player.currentItem?.status == .readyToPlay }
            let file = ready ? await output.grab(s, frame: P, to: out.appendingPathComponent("\(m.steps.count)-\(name).bgra")) : nil
            m.steps.append(Step(name: name, file: file?.lastPathComponent, expected: expected, playhead: s.playhead,
                                generation: s.generation, applied: s.appliedGeneration))
        }
        let A = { (f: Int) in String(format: "id%02X#%d", 0x2D, f) }

        await capture("initial", A(100))
        let aClip = s.timeline.clips[0].id
        s.selection = aClip; s.splitAtPlayhead()                              // A[0,100)@0, A[100,120)@100, B@120
        await capture("split", A(100))
        let L = s.timeline.clips[0].id, R = s.timeline.clips[1].id, B = s.timeline.clips[2].id
        s.beginGesture(select: R); s.updateTrim(R, edge: .start, delta: 5); s.commitGesture()   // R = A[105,120)@100
        await capture("trimStart", A(105))
        s.beginGesture(select: B); s.updateMove(B, toIndex: 0); s.commitGesture()               // B@0, L@90, R@190
        await capture("move", A(10))
        s.selection = L; s.deleteSelection(ripple: false)                      // 빈틈 [90,190)
        await capture("normalDelete", "black")
        s.undo(); await capture("undoDelete", A(10))
        s.redo(); await capture("redoDelete", "black")
        s.undo(); await capture("undoAgain", A(10))
        s.selection = B; s.deleteSelection(ripple: true)                       // L@0, R@100
        await capture("rippleDelete", A(105))
        s.undo(); await capture("undoRipple", A(10))
        s.redo(); await capture("redoRipple", A(105))

        // 빠른 연속 편집: 같은 차례에서 여러 편집을 하고, 앞 세대의 재구성을 일부러 늦게 끝나게 한다.
        // 늦게 끝난 오래된 결과가 마지막 타임라인을 덮으면 안 된다.
        let dropped0 = s.staleRebuildsDropped
        s.testRebuildDelay = [s.generation + 1: 800_000_000, s.generation + 2: 400_000_000]
        s.undo(); s.redo(); s.undo()                                           // 마지막: rippleDelete 전(L@90, R@190 → A#10)
        await capture("rapidBurst1", A(10))
        let dropped1 = s.staleRebuildsDropped
        s.selection = L
        s.testRebuildDelay = [s.generation + 2: 800_000_000]
        s.deleteSelection(ripple: false); s.undo(); s.redo()                   // 마지막: 빈틈 → 검정
        await capture("rapidBurst2", "black")
        _ = dropped1
        let itemBefore = s.player.currentItem                                  // 늦은 오래된 결과가 도착하기 전의 프리뷰 항목
        _ = await waitUntil(3) { s.staleRebuildsDropped >= dropped0 + 4 }       // 늦춘 오래된 결과가 모두 도착해 버려질 때까지
        await capture("afterLateStale", "black")
        check("lateStale.itemNotReplaced", s.player.currentItem === itemBefore)
        s.testRebuildDelay = [:]
        check("stale.dropped", s.staleRebuildsDropped - dropped0 >= 4, "dropped \(s.staleRebuildsDropped - dropped0)")
        check("playhead.fixed", m.steps.allSatisfy { $0.playhead == P }, m.steps.map { "\($0.name)=\($0.playhead)" }.joined(separator: ","))
        check("applied.latest", m.steps.allSatisfy { $0.applied == $0.generation })
        check("frames.captured", m.steps.allSatisfy { $0.file != nil })
        finish(folder, m)
    }

    /// 현재 프리뷰 항목에 비디오 출력을 붙여 정확히 frame 시각의 새 버퍼를 받는다.
    @MainActor final class Output {
        private var attached: (AVPlayerItem, AVPlayerItemVideoOutput)?
        func grab(_ s: ProjectStore, frame: Int, to url: URL) async -> URL? {
            guard let item = s.player.currentItem else { return nil }
            if attached?.0 !== item {
                let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(o); attached = (item, o)
            }
            let o = attached!.1, t = s.settings.time(frame)
            await s.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            let start = Date(), end = start.addingTimeInterval(3)
            while Date() < end {
                // 같은 항목·같은 시각을 다시 읽을 때는 새 버퍼가 없다. 1초 뒤에는 현재 버퍼를 표시 시각을 확인해 읽는다.
                if o.hasNewPixelBuffer(forItemTime: t) || Date().timeIntervalSince(start) > 1 {
                    var shown = CMTime.invalid
                    if let pb = o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown), shown.isNumeric, abs((shown - t).seconds) < 0.0005 {
                        return (try? PreviewSelfTest.writePicture(pb, to: url)) != nil ? url : nil
                    }
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return nil
        }
    }

    private static func writePicture(_ pb: CVPixelBuffer, to url: URL) throws {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        var d = Data(count: w * h * 4)
        d.withUnsafeMutableBytes { dst in
            let base = CVPixelBufferGetBaseAddress(pb)!
            for y in 0..<h { memcpy(dst.baseAddress! + y * w * 4, base + y * bpr, w * 4) }
        }
        try d.write(to: url)
    }

    /// A black composition image can remain current across the gap without a new video sample.
    /// Defer readback of these nine FHD samples until paused so diagnostic I/O cannot skip a boundary.
    private static func recordIntervalPictures(_ store: ProjectStore, item: AVPlayerItem, folder: URL, targets: [Int], videoRanges: [Range<Int>]) async throws -> [String] {
        let pictures = folder.appendingPathComponent("preview")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        defer { item.remove(output) }
        var latest: CVPixelBuffer?
        var shown = CMTime.invalid
        var rows: [String] = []
        var manifest = Manifest(width: 1920, height: 1080, steps: [], checks: [])
        store.play()
        var snapshots: [(CVPixelBuffer, URL)] = []
        for target in targets {
            let time = store.settings.time(target)
            let deadline = Date().addingTimeInterval(5)
            var now = item.currentTime()
            while Date() < deadline {
                now = item.currentTime()
                if output.hasNewPixelBuffer(forItemTime: now) {
                    var display = CMTime.invalid
                    if let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &display) {
                        latest = buffer
                        shown = display
                    }
                }
                if now >= time { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let clip = videoRanges.first { $0.contains(target) }
            let blackStart = videoRanges.last { $0.upperBound <= target }?.upperBound ?? 0
            let displayFrame = shown.isNumeric ? store.settings.frame(containing: shown) : -1
            let onTime = store.settings.frame(containing: now) == target
            let valid = onTime && (clip == nil ? (blackStart...target).contains(displayFrame) : displayFrame == target)
            let name = "picture-\(target).bgra"
            if let latest { snapshots.append((latest, pictures.appendingPathComponent(name))) }
            let expected = clip.map { "id33#\(target - $0.lowerBound)" } ?? "black"
            manifest.steps.append(Step(name: String(target), file: latest == nil ? nil : name, expected: expected,
                                       playhead: target, generation: store.generation, applied: store.appliedGeneration))
            rows.append("\(valid ? "PASS" : "FAIL") video target=\(target) player=\(now.seconds) outputFrame=\(displayFrame)")
        }
        store.pause()
        for (buffer, url) in snapshots { try writePicture(buffer, to: url) }
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("preview-manifest.json"))
        return rows
    }

    private static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    private static func finish(_ folder: URL, _ m: Manifest) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(m) { try? d.write(to: folder.appendingPathComponent("preview-manifest.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
