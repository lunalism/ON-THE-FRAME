#if DEBUG
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import OnTheFrameEngine

/// Numeric-only bounded Debug trace. No formatting, file I/O or locks in record().
@MainActor enum SpectrumContinuityTrace {
    // Row = monotonic microseconds, kind, a...h (unused fields are zero).
    // 10 lease(id,start,deadline,serial,accessRevision,session,generation,applied)
    // 11 query(lease,1=blocked-pending/2=expired/3=valid-pending/4=early-due,deadline)
    // 12 worker-return(id,valid,cancelled)
    // 13 publication(id,deadline); 14 rejected(id); 15 identity(lease,item,composition)
    // 16 invalidation(lease,serial,accessRevision,session,generation)
    // 20 tick(id,targetHostTime,playhead); 21 guard(tick,1=player/2=access,context)
    // 23 timing(tick,requestedUS,displayUS,requestedFrame,selected,reason,lastFrame)
    // reason: 1 invalid/uncovered, 2 no new buffer, 3 copy failed, 4 select completed.
    // 24 fallback(tick,itemUS,itemFrame,selected,timeControlStatus,covered)
    // 22 chosen(tick,frame,lease); 30 clear(oldFrame,serial,tick); 31 set(frame,serial,tick)
    // 32 request(id,frame,serial,epoch,revision,spectrumHash)
    // 33 delivery(id,frame,serial,outcome); 34 accepted(id,frame,serial,outcome,image,spectrumHash)
    // 35 cancel(id,frame,serial,spectrumHash); 36/37 session(spectrumHash,frame,epoch,revision,outcome)
    // 38 superseded(spectrumHash,frame,epoch,revision)
    // 40 layer(tick,frame,oldImage,newImage,count,lease); zero image means nil contents.
    // 50 observation(timeline,current,bandsMatch,layerMatch,actualImage,playerUS,lease,tick)
    // 60 play / 61 pause / 62 seek(frame,session,generation); 63 end(frame,isPlaying)
    // Outcome: 1 ready image, 2 ready empty, 3 cancelled, 4 superseded, 5 dropped, 6 other.
    // Raw object identifiers are process-local numeric correlation only, never dereferenced.
    struct Event {
        let time, kind, a, b, c, d, e, f, g, h: Int64
        var row: [Int64] { [time, kind, a, b, c, d, e, f, g, h] }
    }
    static let limit = 8192, byteLimit = 2 * 1024 * 1024
    private static var events: [Event] = []
    private(set) static var active = false
    private(set) static var truncated = false
    private static var sequence: Int64 = 0
    static var tick: Int64 = 0
    static var lease: Int64 = 0
    static func id(_ object: AnyObject?) -> Int64 {
        object.map { Int64(bitPattern: UInt64(UInt(bitPattern: ObjectIdentifier($0)))) } ?? 0
    }
    static func next() -> Int64 { guard active else { return 0 }; sequence += 1; return sequence }
    static func begin() {
        active = false; events.removeAll(keepingCapacity: true); events.reserveCapacity(limit)
        sequence = 0; tick = 0; lease = 0; truncated = false; active = true
    }
    static func record(_ kind: Int64, _ a: Int64 = 0, _ b: Int64 = 0, _ c: Int64 = 0,
                       _ d: Int64 = 0, _ e: Int64 = 0, _ f: Int64 = 0, _ g: Int64 = 0, _ h: Int64 = 0) {
        guard active else { return }
        guard events.count < limit else { truncated = true; active = false; return }
        events.append(Event(time: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000),
                            kind: kind, a: a, b: b, c: c, d: d, e: e, f: f, g: g, h: h))
    }
    static func outcome(_ value: SpectrumFrameOutcome) -> Int64 {
        switch value {
        case .ready(_, .some): return 1
        case .ready(_, .none): return 2
        case .cancelled: return 3
        case .superseded: return 4
        case .dropped: return 5
        default: return 6
        }
    }
    static func validate() -> Bool {
        begin()
        for _ in 0..<(limit + 2) { record(99, .min, .max, .min, .max, .min, .max, .min, .max) }
        let valid = events.count == limit && truncated && !active &&
            zip(events, events.dropFirst()).allSatisfy { $0.time <= $1.time } &&
            ((try? JSONSerialization.data(withJSONObject: events.map(\.row)).count) ?? byteLimit) < byteLimit
        active = false
        return valid
    }
    static func finishData(validated: Bool, runID: UUID? = nil) throws -> Data {
        active = false
        // Ten signed Int64 values need at most 212 JSON bytes/row, including delimiters.
        // 8192 rows plus this fixed header remain below 2 MiB, independently of runtime values.
        var payload: [String: Any] = ["version": 1, "events": events.map(\.row),
            "truncated": truncated, "capacity": limit, "byteLimit": byteLimit,
            "tracerValidation": validated, "eventStride": MemoryLayout<Event>.stride]
        if let runID {
            payload["runID"] = runID.uuidString
            payload["eventCount"] = events.count
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        return data
    }

    static func save(_ folder: URL, validated: Bool) {
        do {
            try finishData(validated: validated).write(to: folder.appendingPathComponent("continuity-trace.json"),
                                                       options: .withoutOverwriting)
        } catch {
            NSLog("Continuity trace persistence failed: %@", String(describing: error))
        }
    }
}

/// Generated fixtures only; records presentation evidence before and after integration.
@MainActor enum ImageSpectrumSelfTest {
    static func run(folder: URL) async {
        if ProcessInfo.processInfo.arguments.contains("-OTFProactiveRenewalTest") {
            await runRenewal(folder: folder); return
        }
        let traceEnabled = ProcessInfo.processInfo.arguments.contains("-OTFSpectrumContinuityTrace")
        let traceValidated = traceEnabled ? SpectrumContinuityTrace.validate() : false
        if traceEnabled { SpectrumContinuityTrace.begin() }
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
            if traceEnabled { SpectrumContinuityTrace.save(folder, validated: traceValidated) }
            s.stopAllScopes(); s.discardConfirmedForTest(); NSApp.terminate(nil)
        }
        guard await s.openProject(at: folder.appendingPathComponent("test.ontheframe")),
              await wait({ s.player.currentItem?.status == .readyToPlay && s.appliedGeneration == s.generation && s.previewHost?.window != nil }),
              let item = s.player.currentItem, let plan = s.currentPlan, let view = s.previewHost,
              let entry = s.timeline.spectra.first, let clip = s.timeline.audioClips.first,
              let media = s.mediaByID[clip.mediaID] else { checks["setup"] = false; rows.append(["error": s.alert?.message ?? s.statusMessage ?? s.imagePreviewError ?? "unready", "generation": s.generation, "applied": s.appliedGeneration]); return }
        checks["setup"] = plan.isImagePreviewOnly && s.imagePreviewEligibility(for: item, session: s.projectSession, generation: s.generation) == .validatedAtInstallation
        if traceEnabled && ProcessInfo.processInfo.arguments.contains("-OTFSpectrumTraceSlowCompletion") {
            // Deliberately delay the existing Debug delivery hook, not production I/O or TTL.
            // This models slow validation publication; it is not a large-catalog benchmark.
            s.imagePlaybackAccessPreparedForTest = { try? await Task.sleep(nanoseconds: 1_100_000_000) }
            s.seek(to: 0)
            _ = await wait { !view.hasPendingSpectrumSeek }
            s.play()
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            checks["slow completion remains fail closed"] = s.spectrumPreview.playback.currentFrame == nil && view.spectrumOverlay.layers.isEmpty
            checks["slow completion retries serially"] = s.imagePlaybackAccessChecksForTest >= 3
            s.pause()
            s.imagePlaybackAccessPreparedForTest = nil
            return
        }
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
                    SpectrumContinuityTrace.record(50, Int64(f), Int64(cf ?? -1), bandsMatch ? 1 : 0, layerMatch ? 1 : 0,
                        SpectrumContinuityTrace.id(view.spectrumOverlay.layers[entry.id]?.contents as AnyObject?),
                        Int64(time.seconds * 1_000_000), SpectrumContinuityTrace.lease, SpectrumContinuityTrace.tick)
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
            SpectrumContinuityTrace.record(63, Int64(s.playhead), s.isPlaying ? 1 : 0)
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
    /// Controlled monotonic clock and existing delivery hook; actual image reads remain real.
    static func runRenewal(folder: URL) async {
        let s = ProjectStore.shared
        var checks = [String: Bool](), failure: String?
        var release: CheckedContinuation<Void, Never>?
        struct Failure: Error { let name: String }
        func check(_ name: String, _ pass: Bool) throws { checks[name] = pass; if !pass { throw Failure(name: name) } }
        func wait(_ predicate: () -> Bool) async throws {
            let end = Date().addingTimeInterval(10)
            while !predicate(), Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
            if !predicate() { throw Failure(name: "bounded wait") }
        }
        s.imagePlaybackAccessClockForTest = 1000
        defer {
            s.imagePlaybackAccessPreparedForTest = nil
            release?.resume()
            s.imagePlaybackAccessClockForTest = nil
            s.stopAllScopes(); s.discardConfirmedForTest()
            let result: [String: Any] = ["checks": checks, "error": failure as Any? ?? NSNull(), "pass": failure == nil]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("renewal-contract.json"))
            NSApp.terminate(nil)
        }
        do {
            let opened = await s.openProject(at: folder.appendingPathComponent("test.ontheframe"))
            try check("fixture opened", opened)
            try await wait { s.player.currentItem.map { s.imagePreviewEligibility(for: $0, session: s.projectSession, generation: s.generation) == .validatedAtInstallation } ?? false }
            let item = s.player.currentItem!
            try check("initial unknown denied", !s.imagePlaybackAccessIsCurrent(for: item))
            try await wait { !s.imagePlaybackLeaseForTest.pending }
            try check("initial expiry is start plus TTL", s.imagePlaybackLeaseForTest.until == 1001)
            let initialCount = s.imagePlaybackAccessChecksForTest
            s.imagePlaybackAccessClockForTest = 1000.89
            try check("before lead no renewal", s.imagePlaybackAccessIsCurrent(for: item, allowProactiveRenewal: true) && s.imagePlaybackAccessChecksForTest == initialCount)
            s.imagePlaybackAccessPreparedForTest = { await withCheckedContinuation { release = $0 } }
            s.imagePlaybackAccessClockForTest = 1000.9
            try check("renewal start preserves old lease", s.imagePlaybackAccessIsCurrent(for: item, allowProactiveRenewal: true))
            try await wait { release != nil }
            for _ in 0..<1000 { _ = s.imagePlaybackAccessIsCurrent(for: item, allowProactiveRenewal: true) }
            try check("pending retains original expiry and single worker", s.imagePlaybackLeaseForTest.until == 1001 && s.imagePlaybackAccessChecksForTest == initialCount + 1)
            s.imagePlaybackAccessClockForTest = 1000.95
            release?.resume(); release = nil
            try await wait { !s.imagePlaybackLeaseForTest.pending }
            try check("replacement uses request start not completion", abs(s.imagePlaybackLeaseForTest.until - 1001.9) < 0.000001)
            let beforeSeek = s.imagePlaybackLeaseForTest.until
            s.seek(to: 180)
            try check("ordinary seek never extends lease", s.imagePlaybackLeaseForTest.until == beforeSeek)
            s.imagePlaybackAccessClockForTest = max(beforeSeek - 0.1, s.imagePlaybackLeaseForTest.retry)
            let beforePaused = s.imagePlaybackAccessChecksForTest
            try check("paused query does not renew valid lease", s.imagePlaybackAccessIsCurrent(for: item) && s.imagePlaybackAccessChecksForTest == beforePaused)
            _ = s.imagePlaybackAccessIsCurrent(for: item, allowProactiveRenewal: true)
            try await wait { release != nil }
            s.imagePlaybackAccessClockForTest = beforeSeek
            try check("exact old expiry denied with pending worker", !s.imagePlaybackAccessIsCurrent(for: item, allowProactiveRenewal: true))
            s.imagePlaybackAccessClockForTest = beforeSeek + 0.05
            release?.resume(); release = nil
            try await wait { !s.imagePlaybackLeaseForTest.pending }
            try check("fresh replacement can recover after old expiry", s.imagePlaybackAccessIsCurrent(for: item))
            let fresh = s.imagePlaybackLeaseForTest.until
            s.imagePlaybackAccessClockForTest = max(fresh - 0.1, s.imagePlaybackLeaseForTest.retry)
            _ = s.imagePlaybackAccessIsCurrent(for: item, allowProactiveRenewal: true)
            try await wait { release != nil }
            let slowStart = s.imagePlaybackAccessClockForTest!
            s.imagePlaybackAccessClockForTest = slowStart + 1
            release?.resume(); release = nil
            try await wait { !s.imagePlaybackLeaseForTest.pending }
            try check("success at own expiry is rejected", s.imagePlaybackLeaseForTest.until == 0 && s.imagePlaybackLeaseForTest.retry >= slowStart + 1)
            s.imagePlaybackAccessPreparedForTest = nil
            _ = s.imagePlaybackAccessIsCurrent(for: item)
            try await wait { !s.imagePlaybackLeaseForTest.pending }
            try check("new validation recovers expired success", s.imagePlaybackAccessIsCurrent(for: item))
            let ref = ProjectPersistence.references(s.timeline).first { $0.kind == .stillImage }!
            let source = URL(fileURLWithPath: ref.path), moved = folder.appendingPathComponent("renewal-missing.jpg")
            try FileManager.default.moveItem(at: source, to: moved)
            defer { if FileManager.default.fileExists(atPath: moved.path) { try? FileManager.default.moveItem(at: moved, to: source) } }
            let oldExpiry = s.imagePlaybackLeaseForTest.until
            s.imagePlaybackAccessClockForTest = max(oldExpiry - 0.1, s.imagePlaybackLeaseForTest.retry)
            try check("old lease allowed until failure confirmed", s.imagePlaybackAccessIsCurrent(for: item, allowProactiveRenewal: true))
            try await wait { !s.imagePlaybackLeaseForTest.pending }
            try check("failure immediately revokes unexpired lease and presentation", s.imagePlaybackLeaseForTest.until == 0 && s.previewHost?.spectrumOverlay.layers.isEmpty == true && s.spectrumPreview.playback.currentFrame == nil)
            let failedCount = s.imagePlaybackAccessChecksForTest, throttle = s.imagePlaybackLeaseForTest.retry
            for _ in 0..<1000 { _ = s.imagePlaybackAccessIsCurrent(for: item) }
            try check("failure polling cannot bypass throttle", s.imagePlaybackAccessChecksForTest == failedCount && throttle >= oldExpiry + 0.9 - 0.000001)
            try FileManager.default.moveItem(at: moved, to: source)
            s.imagePlaybackAccessClockForTest = throttle
            _ = s.imagePlaybackAccessIsCurrent(for: item)
            try await wait { !s.imagePlaybackLeaseForTest.pending }
            s.imagePlaybackAccessPreparedForTest = { await withCheckedContinuation { release = $0 } }
            s.imagePlaybackAccessClockForTest = max(s.imagePlaybackLeaseForTest.until - 0.1, s.imagePlaybackLeaseForTest.retry)
            _ = s.imagePlaybackAccessIsCurrent(for: item, allowProactiveRenewal: true)
            try await wait { release != nil }
            let retry = s.imagePlaybackLeaseForTest.retry, calls = s.imagePlaybackAccessChecksForTest, stale = s.imagePlaybackAccessStaleForTest
            s.applyImageAvailability(false, id: ref.id, snapshot: s.timeline, session: s.projectSession, generation: s.generation)
            for _ in 0..<1000 { _ = s.imagePlaybackAccessIsCurrent(for: item) }
            try check("cancelled worker owns slot until drain", s.imagePlaybackLeaseForTest.pending && s.imagePlaybackAccessChecksForTest == calls)
            try check("invalidation preserves throttle", s.imagePlaybackLeaseForTest.retry == retry && s.imagePlaybackLeaseForTest.until == 0)
            release?.resume(); release = nil
            try await wait { !s.imagePlaybackLeaseForTest.pending }
            try check("cancelled success cannot revive lease", s.imagePlaybackAccessStaleForTest == stale + 1 && s.imagePlaybackLeaseForTest.until == 0)
        } catch { failure = String(describing: error) }
    }
    static func runAccess(folder: URL) async {
        let traceEnabled = ProcessInfo.processInfo.arguments.contains("-OTFSpectrumContinuityTrace")
        let traceValidated = traceEnabled ? SpectrumContinuityTrace.validate() : false
        if traceEnabled { SpectrumContinuityTrace.begin() }
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
            // Replacement preserves the start throttle. Drive the request until eligible;
            // the late-success rejection assertion below remains unchanged.
            try await wait {
                _ = s.imagePlaybackAccessIsCurrent(for: previous)
                return resume != nil
            }
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
        s.discardConfirmedForTest(); if traceEnabled { SpectrumContinuityTrace.save(folder, validated: traceValidated) }
        NSApp.terminate(nil)
    }
}
#endif
