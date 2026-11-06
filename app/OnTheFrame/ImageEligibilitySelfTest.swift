#if DEBUG
import AppKit
import AVFoundation
import ImageIO
import OnTheFrameEngine

/// Disposable fixture only. No export, owner media, or native file-panel approval.
@MainActor enum ImageEligibilitySelfTest {
    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks = [String: Bool]()
        struct Failure: Error { let name: String }
        func check(_ name: String, _ value: Bool) throws {
            checks[name] = value
            if !value { throw Failure(name: name) }
        }
        func state() -> ProjectStore.ImagePreviewEligibility {
            s.imagePreviewEligibility(for: s.player.currentItem, session: s.projectSession, generation: s.generation)
        }
        func wait(_ predicate: () -> Bool) async throws {
            let end = Date().addingTimeInterval(12)
            while !predicate(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
            try check("bounded wait \(checks.count)", predicate())
        }
        func image(_ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name + ".png")
            let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, context.makeImage()!, nil)
            guard CGImageDestinationFinalize(dest) else { throw Failure(name: "fixture") }
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            return try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        var error: String?
        var resume: CheckedContinuation<Void, Never>?
        do {
            try check("isolated suite", EditorLayout.shared.suiteName != nil)
            try check("A absent", state() == .absent)
            if !ProjectStore.imageImportEnabled {
                let before = s.timeline
                let imported = await s.importStillImage(at: folder.appendingPathComponent("nonexistent.png"))
                try check("P gate off no import or plan", !imported && s.timeline == before && state() == .absent)
            } else {
                let a = try image("original"), b = try image("replacement")
                let imported = await s.importStillImage(at: a)
                try check("fixture import", imported)
                try await wait { state() == .validatedAtInstallation }
                let item = s.player.currentItem!, session = s.projectSession, generation = s.generation
                try check("B exact installed image mode", s.currentPlan?.isImagePreviewOnly == true &&
                    s.imagePreviewEligibility(for: item, session: session, generation: generation) == .validatedAtInstallation)
                try check("C wrong item", s.imagePreviewEligibility(for: AVPlayerItem(asset: AVMutableComposition()), session: session, generation: generation) == .invalidated)
                try check("D wrong session", s.imagePreviewEligibility(for: item, session: session + 1, generation: generation) == .invalidated)
                try check("E wrong generation", s.imagePreviewEligibility(for: item, session: session, generation: generation + 1) == .invalidated)
                s.seek(to: 15)
                try check("M seek preserves installation proof", state() == .validatedAtInstallation && s.player.currentItem === item)
                try await Task.sleep(nanoseconds: 200_000_000)
                s.play(); try await Task.sleep(nanoseconds: 200_000_000); s.pause()
                try check("N resume preserves plan", state() == .validatedAtInstallation && s.player.currentItem === item)
                let id = ProjectPersistence.references(s.timeline).first!.id
                s.applyImageAvailability(false, id: id, snapshot: s.timeline, session: session, generation: generation)
                try check("J availability revokes proof", state() == .invalidated)
                s.applyImageAvailability(true, id: id, snapshot: s.timeline, session: session, generation: generation)
                try check("J positive availability cannot grant", state() == .invalidated)
                s.timelineChanged()
                try check("F rebuilding pending", state() == .pending)
                try check("E old generation rejected", s.imagePreviewEligibility(for: item, session: session, generation: generation) == .invalidated)
                try await wait { state() == .validatedAtInstallation }
                let relinkGeneration = s.generation
                let relinked = await s.relinkStillImage(id, to: b)
                try check("J relink invalidates prior generation", relinked && s.generation > relinkGeneration && state() != .validatedAtInstallation)
                try await wait { state() == .validatedAtInstallation }
                let moved = folder.appendingPathComponent("moved.png")
                try FileManager.default.moveItem(at: b, to: moved)
                s.timelineChanged()
                try await wait { s.imagePreviewError != nil }
                try check("G L source validation failure", state() == .failed && s.player.currentItem == nil)
                try FileManager.default.moveItem(at: moved, to: b)
                s.timelineChanged()
                try await wait { state() == .validatedAtInstallation }
                // The second read must still reject a source moved after initial inspection.
                s.imageSourceValidatedForTest = { validatedID in
                    guard validatedID == id else { return }
                    s.imageSourceValidatedForTest = nil
                    try? FileManager.default.moveItem(at: b, to: moved)
                }
                s.timelineChanged()
                try await wait { s.imagePreviewError != nil }
                try check("L second read fails closed", state() == .failed && s.missingMedia[id] != nil)
                try FileManager.default.moveItem(at: moved, to: b)
                s.timelineChanged()
                try await wait { state() == .validatedAtInstallation }
                let replaced = s.player.currentItem!
                s.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
                try check("H item replacement rejects old proof", state() == .invalidated &&
                    s.imagePreviewEligibility(for: replaced, session: s.projectSession, generation: s.generation) == .invalidated)
                // Successful plan held across a known availability revision cannot grant.
                s.imagePreviewPreparedForTest = { _ in await withCheckedContinuation { resume = $0 } }
                s.timelineChanged()
                try await wait { resume != nil }
                s.applyImageAvailability(false, id: id, snapshot: s.timeline, session: s.projectSession, generation: s.generation)
                resume?.resume(); resume = nil
                try await wait { state() == .invalidated }
                try check("J late validation revision rejected", state() != .validatedAtInstallation)
                s.imagePreviewPreparedForTest = nil
                s.timelineChanged()
                try await wait { state() == .validatedAtInstallation }
                let oldSession = s.projectSession, oldGeneration = s.generation, oldItem = s.player.currentItem
                s.imagePreviewPreparedForTest = { _ in await withCheckedContinuation { resume = $0 } }
                s.timelineChanged()
                try await wait { resume != nil }
                let drops = s.imagePreviewStaleDropsForTest
                s.resetProject()
                try check("I project replacement", s.projectSession != oldSession && state() != .validatedAtInstallation &&
                    s.imagePreviewEligibility(for: oldItem, session: oldSession, generation: oldGeneration) == .invalidated)
                resume?.resume(); resume = nil
                try await wait { s.imagePreviewStaleDropsForTest == drops + 1 }
                try check("K cancelled late success cannot resurrect", state() != .validatedAtInstallation && s.player.currentItem == nil)
            }
        } catch let failure { error = String(describing: failure) }
        s.imagePreviewPreparedForTest = nil
        s.imageSourceValidatedForTest = nil
        resume?.resume()
        s.stopAllScopes()
        let result: [String: Any] = ["pass": error == nil, "checks": checks, "error": error as Any? ?? NSNull()]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("eligibility-result.json"))
        s.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
