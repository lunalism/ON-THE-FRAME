#if DEBUG
import AppKit
import OnTheFrameEngine

/// Disposable fixtures only. Real ProjectStore transaction + real coordinator/file source.
/// Gates hold candidate validation and source opening; sleeps never determine race ordering.
@MainActor
enum SpectrumLifecycleSelfTest {
    typealias Check = LaneSelfTest.Check

    @MainActor final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        private var released = false
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    final class Results {
        var values: [String] = []
        func append(_ outcome: SpectrumFrameOutcome) {
            switch outcome {
            case .ready: values.append("ready")
            case .superseded: values.append("superseded")
            case .cancelled: values.append("cancelled")
            case .itemMissing: values.append("itemMissing")
            case let .failed(e): values.append("failed: \(e)")
            default: values.append("unavailable")
            }
        }
    }

    static func run(folder: URL) async {
        var checks: [Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            checks.append(Check(name: name, pass: pass, detail: detail))
            LaneSelfTest.checkCountForMode = checks.count
        }
        func finish() {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(checks) { try? data.write(to: folder.appendingPathComponent("spectrum-lifecycle-result.json")) }
            ProjectStore.shared.discardConfirmedForTest()
            NSApp.terminate(nil)
        }
        let sourceGate = Gate()
        let session = SpectrumPreviewSession(coordinator: SpectrumFrameCoordinator(deliveryQueue: .main) { asset in
            await sourceGate.wait()
            return try await SpectrumFrameCoordinator.fileOpener(asset)
        })
        let s = ProjectStore(spectrumPreview: session)
        defer { sourceGate.release(); s.candidatePreparedForTest = nil; s.stopAllScopes(); s.spectrumLifecycleEventForTest = nil }
        func dismissAlert() async {
            _ = await LaneSelfTest.waitUntil(5) { s.alerts.isShowing }
            s.alerts.pressButton(0)
            _ = await LaneSelfTest.waitUntil(5) { !s.alerts.isShowing }
        }
        var events: [(String, Int)] = []
        s.spectrumLifecycleEventForTest = { events.append(($0, $1)) }
        do {
            let source = folder.appendingPathComponent("sources/aud-wav48s.wav")
            let replacement = folder.appendingPathComponent("sources/relinked.wav")
            let a = try await MediaProbe.inspect(source)
            let clip = UUID(), lane = UUID(), spectrum = UUID()
            var t = try Timeline().registering(a).placing(media: a.id, at: 0, videoLane: nil, audioLane: Lane.audioID, clipID: clip)
            guard let key = t.clip(clip)?.lineageKey else {
                check("fixture.audio", false); finish(); return
            }
            t = try t.addingLane(.spectrum, name: "SP", id: lane).addingSpectrum(lane: lane, at: 0, length: 120, sourceKey: key, id: spectrum)
            // Actual security-scoped bookmark, not a fake start/stop implementation.
            let bookmark = try source.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let candidate = folder.appendingPathComponent("candidate-\(UUID().uuidString).ontheframe")
            try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [a.id: bookmark], projectURL: candidate).write(to: candidate, options: .withoutOverwriting)
            let first = await s.openProject(at: candidate)
            check("setup.openAuthorizedProject", first && s.timeline == t && s.assets.count == 1 && !s.scopedURLs.isEmpty,
                  "scopes \(s.scopedURLs.count), events \(events.map(\.0))")
            guard first, !s.scopedURLs.isEmpty else { finish(); return }
            let initialEpoch = session.epoch, initialRevision = session.revision
            let oldSession = s.projectSession, oldScopes = s.scopedURLs, oldTimeline = s.timeline
            let pending = Results()
            session.request(spectrum: spectrum, frame: 30) { pending.append($0) }
            let entered = await LaneSelfTest.waitUntil(10) { sourceGate.entered }
            check("analysis.deferredBeforeReplacement", entered && pending.values.isEmpty)
            guard entered else { finish(); return }

            // Decode failure happens before any candidate scope exists.
            let bad = folder.appendingPathComponent("bad-\(UUID().uuidString).ontheframe")
            try Data("{ invalid".utf8).write(to: bad, options: .withoutOverwriting)
            events = []
            let badOK = await s.openProject(at: bad)
            check("failure.currentProjectAndPendingAnalysisPreserved", !badOK && session.epoch == initialEpoch && session.revision == initialRevision && s.projectSession == oldSession
                  && s.timeline == oldTimeline && s.scopedURLs == oldScopes && events.isEmpty && pending.values.isEmpty)
            await dismissAlert()

            // Cancellation AFTER candidate access and validation; old access/session stays alive.
            let cancelledGate = Gate()
            var preparedScopes = 0
            s.candidatePreparedForTest = { count in preparedScopes = count; await cancelledGate.wait() }
            events = []
            let cancelTask = Task { await s.openProject(at: candidate) }
            let cancelEntered = await LaneSelfTest.waitUntil(10) { cancelledGate.entered }
            check("cancel.prepareKeepsOldAccess", cancelEntered && preparedScopes > 0 && s.scopedURLs == oldScopes && session.epoch == initialEpoch && pending.values.isEmpty)
            s.cancelOpen(); cancelledGate.release()
            let cancelledOK = await cancelTask.value
            check("cancel.releasesOnlyCandidateAccess", !cancelledOK && s.timeline == oldTimeline && s.projectSession == oldSession && s.scopedURLs == oldScopes
                  && session.epoch == initialEpoch && session.revision == initialRevision && events.map(\.0) == ["candidateScopesReleased"] && events.first?.1 == preparedScopes)
            s.candidatePreparedForTest = nil

            // Existing edit during validation rejects candidate, preserving the edited project.
            let editGate = Gate()
            s.candidatePreparedForTest = { count in preparedScopes = count; await editGate.wait() }
            events = []
            let editTask = Task { await s.openProject(at: candidate) }
            let editEntered = await LaneSelfTest.waitUntil(10) { editGate.entered }
            check("conflict.prepared", editEntered && preparedScopes > 0)
            s.addLane(.subtitle)
            let edited = s.timeline, editedRevision = session.revision
            editGate.release()
            let editedOK = await editTask.value
            check("conflict.preservesEditAndOldScopes", !editedOK && s.timeline == edited && edited != oldTimeline && s.scopedURLs == oldScopes
                  && s.projectSession == oldSession && session.epoch == initialEpoch && session.revision == editedRevision && events.map(\.0) == ["candidateScopesReleased"])
            await dismissAlert(); s.candidatePreparedForTest = nil
            // The ordinary edit updates revision but does not reset the engine project epoch.
            check("edit.noProjectReset", session.epoch == initialEpoch)

            // Commit replacement while old source opening remains blocked.
            events = []
            var fencedBeforeRelease = false
            s.spectrumLifecycleEventForTest = { name, count in
                events.append((name, count))
                if name == "oldInvalidated" { fencedBeforeRelease = session.epoch == initialEpoch + 1 && s.scopedURLs == oldScopes }
            }
            let replaced = await s.openProject(at: candidate)
            check("replacement.commitOrder", replaced && fencedBeforeRelease && events.map(\.0) == ["oldInvalidated", "oldScopesReleased", "candidateScopesTransferred", "projectInstalled"], "\(events)")
            check("replacement.authorizedMappingInstalled", s.projectSession == oldSession + 1 && s.assets.map(\.id) == [a.id] && !s.scopedURLs.isEmpty && s.timeline == t)
            _ = await LaneSelfTest.waitUntil(10) { !pending.values.isEmpty }
            check("replacement.oldCompletionCannotBeReady", pending.values == ["superseded"], "\(pending.values)")
            sourceGate.release()
            let fresh = Results()
            session.request(spectrum: spectrum, frame: 30) { fresh.append($0) }
            _ = await LaneSelfTest.waitUntil(15) { !fresh.values.isEmpty }
            check("replacement.newCoordinatorUsable", fresh.values == ["ready"], "\(fresh.values)")
            check("replacement.noDuplicateOldTerminal", pending.values == ["superseded"], "\(pending.values)")

            // Fail/cancel after a ready request also leaves the same coordinator usable.
            var stableEpoch = session.epoch
            _ = await s.openProject(at: bad); await dismissAlert()
            let afterFailure = Results()
            session.request(spectrum: spectrum, frame: 31) { afterFailure.append($0) }
            _ = await LaneSelfTest.waitUntil(10) { !afterFailure.values.isEmpty }
            check("failure.coordinatorStillUsable", session.epoch == stableEpoch && afterFailure.values == ["ready"])

            s.candidatePreparedForTest = { _ in s.cancelOpen() }
            let cancelledAgain = await s.openProject(at: candidate)
            s.candidatePreparedForTest = nil
            let afterCancel = Results()
            session.request(spectrum: spectrum, frame: 32) { afterCancel.append($0) }
            _ = await LaneSelfTest.waitUntil(10) { !afterCancel.values.isEmpty }
            check("cancel.coordinatorStillUsable", !cancelledAgain && session.epoch == stableEpoch && afterCancel.values == ["ready"])

            let replacementDeliveryGate = Gate(), queuedBeforeReplacement = Results()
            var replacementWasReady = false
            session.beforeDeliveryForTest = { outcome in
                if case .ready = outcome { replacementWasReady = true }
                await replacementDeliveryGate.wait()
            }
            session.request(spectrum: spectrum, frame: 30) { queuedBeforeReplacement.append($0) }
            let replacementDeliveryEntered = await LaneSelfTest.waitUntil(10) { replacementDeliveryGate.entered }
            check("replacement.readyDeferredAtAppBoundary", replacementDeliveryEntered && replacementWasReady && queuedBeforeReplacement.values.isEmpty)
            session.beforeDeliveryForTest = nil
            let reopened = await s.openProject(at: candidate)
            replacementDeliveryGate.release()
            _ = await LaneSelfTest.waitUntil(10) { !queuedBeforeReplacement.values.isEmpty }
            check("replacement.rejectsAlreadyProducedOldReady", reopened && session.epoch == stableEpoch + 1 && queuedBeforeReplacement.values == ["superseded"])
            stableEpoch = session.epoch

            // Engine has already produced ready: delay only application acceptance, then relink.
            // This explicitly proves safety beyond cancellation/coordinator Plan checking.
            let deliveryGate = Gate(), queued = Results()
            var queuedWasReady = false
            session.beforeDeliveryForTest = { outcome in
                if case .ready = outcome { queuedWasReady = true }
                await deliveryGate.wait()
            }
            session.request(spectrum: spectrum, frame: 30) { queued.append($0) }
            let deliveryEntered = await LaneSelfTest.waitUntil(10) { deliveryGate.entered }
            check("relink.readyOutcomeDeferredAtAppBoundary", deliveryEntered && queuedWasReady && queued.values.isEmpty)
            session.beforeDeliveryForTest = nil

            // Real relink installs the inspected asset identity via refreshAssets, without reset.
            let beforeRevision = session.revision
            let relinked = await s.relinkMedia(a.id, to: replacement)
            check("relink.currentAuthorizedIdentity", relinked && s.mediaByID[a.id]?.url.standardizedFileURL == replacement.standardizedFileURL
                  && session.epoch == stableEpoch && session.revision > beforeRevision)
            deliveryGate.release()
            _ = await LaneSelfTest.waitUntil(10) { !queued.values.isEmpty }
            check("relink.rejectsAlreadyProducedOldReady", queued.values == ["superseded"], "\(queued.values)")
            let afterRelink = Results()
            session.request(spectrum: spectrum, frame: 30) { afterRelink.append($0) }
            _ = await LaneSelfTest.waitUntil(10) { !afterRelink.values.isEmpty }
            check("relink.newSourceUsable", afterRelink.values == ["ready"], "\(afterRelink.values)")

            // An already-produced ready also cannot survive reset-to-empty.
            let resetDeliveryGate = Gate(), queuedBeforeReset = Results()
            var resetWasReady = false
            session.beforeDeliveryForTest = { outcome in
                if case .ready = outcome { resetWasReady = true }
                await resetDeliveryGate.wait()
            }
            session.request(spectrum: spectrum, frame: 30) { queuedBeforeReset.append($0) }
            let resetDeliveryEntered = await LaneSelfTest.waitUntil(10) { resetDeliveryGate.entered }
            check("newProject.readyDeferredAtAppBoundary", resetDeliveryEntered && resetWasReady && queuedBeforeReset.values.isEmpty)
            session.beforeDeliveryForTest = nil
            s.resetProject()
            resetDeliveryGate.release()
            _ = await LaneSelfTest.waitUntil(10) { !queuedBeforeReset.values.isEmpty }
            check("newProject.rejectsAlreadyProducedOldReady", queuedBeforeReset.values == ["superseded"])
            check("newProject.clearsMappingAndInvalidates", s.timeline.isEmpty && s.assets.isEmpty && s.scopedURLs.isEmpty && session.epoch == stableEpoch + 1)
            let missing = Results()
            session.request(spectrum: spectrum, frame: 30) { missing.append($0) }
            _ = await LaneSelfTest.waitUntil(5) { !missing.values.isEmpty }
            check("newProject.oldItemUnavailable", missing.values == ["itemMissing"])
        } catch { check("fixture.orExecution", false, "\(error)") }
        finish()
    }
}
#endif
