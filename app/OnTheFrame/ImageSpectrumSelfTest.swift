#if DEBUG
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import OnTheFrameEngine

/// Generated fixtures only; records presentation evidence before and after integration.
@MainActor enum ImageSpectrumSelfTest {
    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var rows = [[String: Any]](), checks = [String: Bool]()
        func wait(_ predicate: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(15)
            while !predicate(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
            return predicate()
        }
        defer {
            let result: [String: Any] = ["checks": checks, "rows": rows]
            try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                .write(to: folder.appendingPathComponent("image-spectrum.json"))
            s.stopAllScopes(); s.discardConfirmedForTest(); NSApp.terminate(nil)
        }
        guard await s.openProject(at: folder.appendingPathComponent("test.ontheframe")),
              await wait({ s.player.currentItem?.status == .readyToPlay && s.appliedGeneration == s.generation && s.previewHost?.window != nil }),
              let item = s.player.currentItem, let plan = s.currentPlan, let view = s.previewHost,
              let entry = s.timeline.spectra.first, let clip = s.timeline.audioClips.first,
              let media = s.mediaByID[clip.mediaID] else { checks["setup"] = false; rows.append(["error": s.alert?.message ?? s.statusMessage ?? s.imagePreviewError ?? "unready", "generation": s.generation, "applied": s.appliedGeneration]); return }
        checks["setup"] = plan.isImagePreviewOnly && s.imagePreviewEligibility(for: item, session: s.projectSession, generation: s.generation) == .validatedAtInstallation
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output); view.spectrumOutputChanged(on: item)
        defer { item.remove(output) }
        do {
            let settings = entry.style.analysisSettings
            let reference = try await Task.detached {
                let source = try await SpectrumFileSource.open(url: media.url)
                let pieces = [SpectrumSourcePiece(start: 0, length: media.frameCount, sourceIn: 0)]
                var chunks = [Int: [[Float]]](), result = [Int: [Float]]()
                for f in 0..<360 {
                    for index in try SpectrumAnalysis.chunks(frame: f + 30, pieces: pieces, fps: 30, rate: source.sampleRate, settings: settings, chunkSamples: source.chunkSamples) where chunks[index] == nil {
                        chunks[index] = try await source.decodeChunk(index)
                    }
                    result[f] = try SpectrumAnalysis.bands(frame: f + 30, pieces: pieces, fps: 30, rate: source.sampleRate, channelCount: source.channelCount, chunkSamples: source.chunkSamples, settings: settings) { chunks[$0] }
                }
                return result
            }.value
            s.seek(to: 0)
            _ = await wait { !view.hasPendingSpectrumSeek }
            s.play()
            var sampled = Set<Int>(), good = [0, 0, 0], pixels = [0, 0, 0], subtitles = [0, 0, 0]
            let end = Date().addingTimeInterval(17)
            while s.isPlaying && Date() < end {
                let time = item.currentTime(), f = s.settings.frame(containing: time)
                let controller = s.spectrumPreview.playback
                let cf = controller.currentFrame
                var bandsMatch = false, layerMatch = false
                if let cf, case let .ready(bands, rendered) = controller.currentOutcome(spectrum: entry.id, frame: cf) {
                    bandsMatch = bands == reference[cf]
                    if let rendered { layerMatch = view.spectrumOverlay.layers[entry.id]?.contents as AnyObject? === rendered.image }
                    else { layerMatch = view.spectrumOverlay.layers[entry.id]?.contents == nil && bands.allSatisfy { $0 == 0 } }
                }
                var pts = CMTime.invalid
                let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &pts)
                var rgb = [Int]()
                if let pixel {
                    CVPixelBufferLockBaseAddress(pixel, .readOnly)
                    let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                    let offset = (CVPixelBufferGetHeight(pixel)/2)*CVPixelBufferGetBytesPerRow(pixel)+(CVPixelBufferGetWidth(pixel)/2)*4
                    rgb = [Int(base[offset+2]), Int(base[offset+1]), Int(base[offset])]
                    CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                }
                if (0..<360).contains(f), !sampled.contains(f), (bandsMatch && layerMatch || f % 3 == 0) {
                    sampled.insert(f)
                    let expected = Set(s.timeline.subtitles(atFrame: f).map { $0.id })
                    let presented = Set(s.timeline.subtitles.filter {
                        guard let layer = view.subtitleLayerForTest($0.id)?.presentation() else { return false }
                        return layer.opacity > 0.5 && layer.contents != nil && !layer.isHidden
                    }.map { $0.id })
                    let covered = s.timeline.clips.contains { $0.start <= f && f < $0.end }
                    rows.append(["frame": f, "playerSeconds": time.seconds, "outputPTS": pts.isNumeric ? pts.seconds : -1,
                        "spectrumFrame": cf ?? -1, "sourceFrame": cf.map { $0 + 30 } ?? -1,
                        "bands": bandsMatch, "layer": layerMatch, "rgb": rgb, "covered": covered,
                        "access": s.imagePlaybackAccessStateForTest,
                        "blankReason": bandsMatch && layerMatch ? "none" : (s.imagePlaybackAccessStateForTest != "valid" ? "access-" + s.imagePlaybackAccessStateForTest : (cf == nil ? "output-time-unconfirmed" : "analysis-or-layer-pending")),
                        "subtitle": expected == presented, "session": s.projectSession, "generation": s.generation,
                        "item": String(describing: ObjectIdentifier(item)), "composition": String(describing: ObjectIdentifier(plan.composition)),
                        "eligibility": String(describing: s.imagePreviewEligibility(for: item, session: s.projectSession, generation: s.generation))])
                    if bandsMatch && layerMatch { good[f/120] += 1 }
                    if !rgb.isEmpty { pixels[f/120] += 1 }
                    if expected == presented { subtitles[f/120] += 1 }
                }
                try? await Task.sleep(nanoseconds: 3_000_000)
            }
            // Compare diagnostic output pixels with independent source decoding.
            let context = CIContext()
            for target in [60, 119, 120, 180, 239, 240, 270, 357] {
                guard let row = rows.first(where: { $0["frame"] as? Int == target }) ?? rows.first(where: { abs(($0["frame"] as? Int ?? -1000) - target) <= 1 }),
                      let f = row["frame"] as? Int, let actual = row["rgb"] as? [Int], actual.count == 3 else {
                    checks["pixel identity sample \(target)"] = false; continue
                }
                var expected = [0, 0, 0]
                if let visual = s.timeline.clips.first(where: { $0.start <= f && f < $0.end }),
                   let ref = ProjectPersistence.references(s.timeline).first(where: { $0.id == visual.mediaID }) {
                    let image: CGImage
                    if ref.kind == .stillImage {
                        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: ref.path) as CFURL, nil),
                              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
                        image = decoded
                    } else {
                        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: ref.path)))
                        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                        image = try generator.copyCGImage(at: s.settings.time(visual.sourceIn + f - visual.start), actualTime: nil)
                    }
                    let ci = CIImage(cgImage: image)
                    var rgba = [UInt8](repeating: 0, count: 4)
                    context.render(ci, toBitmap: &rgba, rowBytes: 4,
                        bounds: CGRect(x: ci.extent.midX, y: ci.extent.height - CGFloat(image.height / 2) - 1, width: 1, height: 1),
                        format: .RGBA8, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
                    expected = rgba.prefix(3).map(Int.init)
                }
                checks["pixel identity \(target)"] = zip(actual, expected).allSatisfy { abs($0 - $1) <= 6 }
                rows.append(["pixelTarget": target, "sampleFrame": f, "actual": actual, "expected": expected])
            }
            for i in 0..<3 {
                checks["FFT and layer interval \(i)"] = good[i] >= 10
                checks["pixel samples interval \(i)"] = pixels[i] >= 1
                checks["subtitle interval \(i)"] = subtitles[i] >= 10
            }
            checks["end"] = !s.isPlaying && s.playhead == 360
            for f in [60, 180, 270] {
                s.seek(to: f)
                checks["seek \(f)"] = await wait { !view.hasPendingSpectrumSeek && view.spectrumOverlay.confirmedFrame == f }
                s.play()
                checks["resume \(f)"] = await wait { s.player.currentTime().seconds > Double(f)/30 + 0.1 }
                s.pause()
            }
            s.seek(to: 360); s.play()
            checks["replay"] = await wait { s.isPlaying && s.player.currentTime().seconds < 1 }
            s.pause()
            s.selection = entry.id
            s.setSpectrumSource(entry.id, key: nil, from: entry.sourceKey, project: s.projectSession)
            _ = await wait { s.appliedGeneration == s.generation && s.player.currentItem?.status == .readyToPlay }
            s.seek(to: 60)
            _ = await wait { !view.hasPendingSpectrumSeek }
            s.play()
            _ = await wait { s.player.currentTime().seconds > 2.2 }
            checks["deselected source blank"] = view.spectrumOverlay.layers.isEmpty
            s.pause()
            s.setSpectrumSource(entry.id, key: entry.sourceKey, from: nil, project: s.projectSession)
            _ = await wait { s.appliedGeneration == s.generation && s.player.currentItem?.status == .readyToPlay }
            if ProcessInfo.processInfo.arguments.contains("-OTFImageSpectrumEdits") {
                try await PreviewSelfTest.checkAudioEdits(s, entry: entry, clip: clip, media: media) { checks[$0] = $1 }
            }
        } catch { checks["exception \(error)"] = false }
    }
    static func runAccess(folder: URL) async {
        let s = ProjectStore.shared
        var checks = [String: Bool](), failure: String?
        var resume: CheckedContinuation<Void, Never>?
        struct Failure: Error { let name: String }
        func check(_ name: String, _ pass: Bool) throws {
            checks[name] = pass
            if !pass { throw Failure(name: name) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            let end = Date().addingTimeInterval(12)
            while !predicate(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
            if !predicate() { throw Failure(name: "bounded wait") }
        }
        func open() async throws {
            let ok = await s.openProject(at: folder.appendingPathComponent("test.ontheframe"))
            try check("fixture opened", ok)
            try await wait { s.player.currentItem.map { s.imagePreviewEligibility(for: $0, session: s.projectSession, generation: s.generation) == .validatedAtInstallation } ?? false }
        }
        do {
            try await open()
            let item = s.player.currentItem!
            let calls = s.imagePlaybackAccessChecksForTest
            try check("unknown access fails closed", !s.imagePlaybackAccessIsCurrent(for: item))
            for _ in 0..<100 { _ = s.imagePlaybackAccessIsCurrent(for: item) }
            try check("single bounded task", s.imagePlaybackAccessChecksForTest == calls + 1)
            try await wait { s.imagePlaybackAccessIsCurrent(for: item) }
            try check("matching live lease", s.imagePlaybackAccessIsCurrent(for: item))
            s.seek(to: 180)
            try check("ordinary seek preserves source lease", s.imagePlaybackAccessIsCurrent(for: item))
            try await wait { s.previewHost?.hasPendingSpectrumSeek == false }
            s.play()
            try await wait { s.spectrumPreview.playback.currentFrame != nil && s.previewHost?.spectrumOverlay.layers.isEmpty == false }
            try check("playing spectrum before source loss", true)
            let ref = ProjectPersistence.references(s.timeline).first { $0.kind == .stillImage }!
            let source = URL(fileURLWithPath: ref.path), displaced = folder.appendingPathComponent("displaced.jpg")
            try FileManager.default.moveItem(at: source, to: displaced)
            defer { if FileManager.default.fileExists(atPath: displaced.path) { try? FileManager.default.moveItem(at: displaced, to: source) } }
            try await Task.sleep(nanoseconds: 1_100_000_000)
            try check("lost source lease expires", !s.imagePlaybackAccessIsCurrent(for: item))
            try await Task.sleep(nanoseconds: 200_000_000)
            try check("lost source read rejected", !s.imagePlaybackAccessIsCurrent(for: item))
            try check("source loss blanks playing spectrum", s.spectrumPreview.playback.currentFrame == nil && s.previewHost?.spectrumOverlay.layers.isEmpty == true)
            s.pause()
            try FileManager.default.moveItem(at: displaced, to: source)
            try await wait { s.imagePlaybackAccessIsCurrent(for: item) }
            try check("restored source freshly validated", s.imagePlaybackAccessIsCurrent(for: item))
            let mode = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions]!
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: source.path) }
            try await Task.sleep(nanoseconds: 1_100_000_000)
            _ = s.imagePlaybackAccessIsCurrent(for: item)
            try await Task.sleep(nanoseconds: 200_000_000)
            try check("read permission failure closed", !s.imagePlaybackAccessIsCurrent(for: item))
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: source.path)
            try await wait { s.imagePlaybackAccessIsCurrent(for: item) }
            // Keep the already-open audio decoder running while its source path vanishes.
            let audio = s.mediaByID[s.timeline.audioClips.first!.mediaID]!.url
            let lostAudio = folder.appendingPathComponent("missing-selected.wav")
            s.seek(to: 60)
            try await wait { s.previewHost?.hasPendingSpectrumSeek == false }
            s.play()
            try await wait { s.previewHost?.spectrumOverlay.layers.isEmpty == false }
            try FileManager.default.moveItem(at: audio, to: lostAudio)
            defer { if FileManager.default.fileExists(atPath: lostAudio.path) { try? FileManager.default.moveItem(at: lostAudio, to: audio) } }
            var missingFrames = Set<Int>()
            try await wait {
                guard s.previewHost?.spectrumOverlay.layers.isEmpty == true else {
                    missingFrames.removeAll(); return false
                }
                let playback = s.spectrumPreview.playback
                guard s.imagePlaybackAccessIsCurrent(for: item), let frame = playback.currentFrame else { return false }
                missingFrames.insert(frame)
                return missingFrames.count >= 6
            }
            try check("missing selected WAV blanks spectrum with valid image lease", true)
            try FileManager.default.moveItem(at: lostAudio, to: audio)
            s.pause()
            let replacement = folder.appendingPathComponent("replacement.jpg")
            try FileManager.default.copyItem(at: source, to: replacement)
            let bookmark = try replacement.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            let linked = await s.relinkStillImage(ref.id, to: url)
            try check("relink revokes old item", linked && !s.imagePlaybackAccessIsCurrent(for: item))
            try await wait { s.player.currentItem.map { s.imagePlaybackAccessIsCurrent(for: $0) } ?? false }
            let linkedItem = s.player.currentItem!
            s.imagePlaybackAccessPreparedForTest = { await withCheckedContinuation { resume = $0 } }
            try await Task.sleep(nanoseconds: 1_100_000_000)
            _ = s.imagePlaybackAccessIsCurrent(for: linkedItem)
            try await wait { resume != nil }
            let drops = s.imagePlaybackAccessStaleForTest
            s.applyImageAvailability(false, id: ref.id, snapshot: s.timeline, session: s.projectSession, generation: s.generation)
            resume?.resume(); resume = nil
            try await wait { s.imagePlaybackAccessStaleForTest > drops }
            try check("availability rejects late access", !s.imagePlaybackAccessIsCurrent(for: linkedItem))
            s.imagePlaybackAccessPreparedForTest = nil
            s.timelineChanged()
            try await wait { s.player.currentItem.map { s.imagePlaybackAccessIsCurrent(for: $0) } ?? false }
            s.imagePlaybackAccessPreparedForTest = { await withCheckedContinuation { resume = $0 } }
            try await Task.sleep(nanoseconds: 1_100_000_000)
            _ = s.imagePlaybackAccessIsCurrent(for: s.player.currentItem!)
            try await wait { resume != nil }
            let itemDrops = s.imagePlaybackAccessStaleForTest
            s.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
            resume?.resume(); resume = nil
            try await wait { s.imagePlaybackAccessStaleForTest > itemDrops }
            try check("item replacement rejects late access", !s.imagePlaybackAccessIsCurrent(for: s.player.currentItem!))
            s.imagePlaybackAccessPreparedForTest = nil
            s.resetProject()
            try await open()
            let previous = s.player.currentItem!
            s.imagePlaybackAccessPreparedForTest = { await withCheckedContinuation { resume = $0 } }
            _ = s.imagePlaybackAccessIsCurrent(for: previous)
            try await wait { resume != nil }
            let projectDrops = s.imagePlaybackAccessStaleForTest
            s.resetProject()
            resume?.resume(); resume = nil
            try await wait { s.imagePlaybackAccessStaleForTest > projectDrops }
            try check("project replacement rejects late access", !s.imagePlaybackAccessIsCurrent(for: previous))
        } catch { failure = String(describing: error) }
        s.imagePlaybackAccessPreparedForTest = nil
        resume?.resume()
        s.stopAllScopes()
        try? JSONSerialization.data(withJSONObject: ["checks": checks, "error": failure as Any? ?? NSNull(), "pass": failure == nil], options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("live-access.json"))
        s.discardConfirmedForTest(); NSApp.terminate(nil)
    }
}
#endif
