#if DEBUG
import AppKit
import AVFoundation
@testable import OnTheFrameEngine

/// SP-EXPORT-E4D-INTEGRATION-PILOT-45(2026-11-24): 실험 합성기 fullRectangle을 앱의 실제 계획·프리뷰·내보내기에 넣어 보는 Debug 전용 시범.
/// 명시적 실행 인수로만 돈다: `open -n -a OnTheFrame.app <폴더> --args -OTFCompositorPilot builtin|corrected`.
/// - 계획: `CompositionPlanner.plan` 그대로. corrected일 때 같은 계획의 영상 합성만 `replacingVideoComposition(withExperimental:)`으로 바꾼다.
/// - 프리뷰: 보통 `ProjectStore` 흐름(타임라인 적용 → 항목 생성 → 탐색·재생). 항목이 만들어질 때 기존 진단 훅(`itemCreatedHookForTest`)에서
///   영상 합성을 바꾸고, 대응 검사에서는 `AVPlayerItemVideoOutput`을 붙여 프리뷰 프레임을 읽는다(화면 표시의 증거가 아니다).
/// - 내보내기: 공개 `ExportService.export(plan:)`(자막이 있으면 쓰기 펌프, 없으면 내보내기 세션). 대상 보호·임시 정리는 기존 코드다.
/// builtin은 같은 시험을 기본 합성기로 돌린다 — 확대 가장자리 결함은 그대로 실패로 남는다(증거).
/// <폴더>/sources: gray.mov(320×180), plate-red-640x480.mp4, otf-TA.mp4, otf-TB.mp4, otf-A.mp4, otf-N2997.mp4, aud-wav48s.wav(생성 재료의 사본, 읽기만).
/// 결과: <폴더>/compositor-pilot-result.json(검사 행), <폴더>/compositor-pilot-evidence.json(측정), <폴더>/out/*.mp4. 프로젝트는 저장하지 않는다.
@MainActor
enum CompositorPilotSelfTest {
    typealias Check = LaneSelfTest.Check
    struct Planes { let w: Int, h: Int, y: [UInt8], c: [UInt8]
        func luma(_ x: Int, _ yy: Int) -> Int { Int(y[yy * w + x]) }
        func chroma(_ x: Int, _ yy: Int) -> (cb: Int, cr: Int) { let o = (yy / 2) * w + 2 * (x / 2); return (Int(c[o]), Int(c[o + 1])) } }
    /// 대응 비교의 허용 차: E4-d parity의 빈 곳 허용 차(±16)와 비율(99%)을 그대로 쓴다 — 한쪽은 인코딩 전, 한쪽은 H.264다.
    nonisolated static let tolerance = 16, within = 0.99, black = 24

    @MainActor final class Box {
        var corrected = false, attachOutput = false
        var output: AVPlayerItemVideoOutput?
        let log = ExperimentalCompositorLog()
        var swapped = 0, swapFailures: [String] = []
    }
    @MainActor final class Report {
        let s: ProjectStore, folder: URL
        var checks: [Check] = [], evidence: [String: String] = [:]
        init(s: ProjectStore, folder: URL) { self.s = s; self.folder = folder }
        func check(_ name: String, _ pass: Bool, _ detail: String = "") { checks.append(Check(name: name, pass: pass, detail: detail)) }
        func note(_ key: String, _ value: String) { evidence[key] = value }
        func finish() {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(checks) { try? data.write(to: folder.appendingPathComponent("compositor-pilot-result.json")) }
            if let data = try? encoder.encode(evidence) { try? data.write(to: folder.appendingPathComponent("compositor-pilot-evidence.json")) }
            s.itemCreatedHookForTest = nil
            s.discardConfirmedForTest(); NSApp.terminate(nil)
        }
    }

    static func run(folder: URL, mode: String) async {
        let s = ProjectStore.shared, report = Report(s: s, folder: folder), box = Box()
        // PREVIEW-LIFECYCLE-54: "<builtin|corrected>-lifecycle"는 시나리오 대신 S3 프리뷰 수명 비교(조건 A·B)만 돈다
        let lifecycleMode = mode.hasSuffix("-lifecycle")
        // F1-PRESENTATION-PREP-56: "<builtin|corrected>-f1capture"는 F1만, 자기 창 캡처와 함께 돈다(CompositorWindowCapture)
        let f1CaptureMode = mode.hasSuffix("-f1capture")
        // F1-START-COMPARISON-67: "<builtin|corrected>-f1direct"는 같은 F1 캡처를 26 탐색 없이 돈다(조건 A, 바로 시작). -f1capture는 조건 B(26 → 0)로 그대로다.
        let f1DirectMode = mode.hasSuffix("-f1direct")
        let base = lifecycleMode ? String(mode.dropLast("-lifecycle".count)) : f1CaptureMode ? String(mode.dropLast("-f1capture".count))
            : f1DirectMode ? String(mode.dropLast("-f1direct".count)) : mode
        guard base == "builtin" || base == "corrected" else { report.check("setup.mode", false, mode); report.finish(); return }
        box.corrected = base == "corrected"
        report.note("mode", mode)
        s.itemCreatedHookForTest = { item, _ in
            if box.corrected, let base = item.videoComposition {
                do { item.videoComposition = try ExperimentalComposition.videoComposition(from: base, options: .init(edgeCoverage: .fullRectangle), diagnostics: box.log); box.swapped += 1 }
                catch { box.swapFailures.append("\(error)") }
            }
            if box.attachOutput {
                let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
                item.add(o); box.output = o
            } else { box.output = nil }
        }
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil && s.previewHost?.window != nil }
        guard let view = s.previewHost, let window = s.editorWindow else { report.check("setup.view", false); report.finish(); return }
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
        do {
            let src = folder.appendingPathComponent("sources")
            func inspect(_ name: String) async throws -> MediaAsset {
                let a = try await MediaProbe.inspect(src.appendingPathComponent(name)); s.assetCache[a.url.standardizedFileURL.path] = a; return a
            }
            let gray = try await inspect("gray.mov"), red = try await inspect("plate-red-640x480.mp4"), ta = try await inspect("otf-TA.mp4")
            let tb = try await inspect("otf-TB.mp4"), oa = try await inspect("otf-A.mp4"), ntsc = try await inspect("otf-N2997.mp4"), wav = try await inspect("aud-wav48s.wav")
            report.note("sources", [gray, red, ta, tb, oa, ntsc, wav].map { "\($0.name) \(Int($0.naturalSize.width))x\(Int($0.naturalSize.height)) frames \($0.frameCount) audio \($0.hasAudio)" }.joined(separator: "; "))
            if lifecycleMode { try await lifecycle(report, box: box, ta: ta, red: red); report.finish(); return }
            if f1CaptureMode || f1DirectMode {
                try await f1Capture(report, box: box, view: view, window: window, clips: [ta, tb, oa], music: wav, directStart: f1DirectMode); report.finish(); return
            }
            // 시나리오마다 따로 실행한다: 한 시나리오가 오류를 던져도 기록하고 다음으로 간다(2026-11-24 첫 시범은 S5의 오류로 S6·J가 실행되지 않았다).
            // 각 시나리오는 `<이름>.ran` 행을 남긴다(오류 없이 끝남 = true, 오류 = false와 그 글). 단정은 바꾸지 않았다.
            func independently(_ name: String, _ body: () async throws -> Void) async {
                do { try await body(); report.check("\(name).ran", true) } catch { report.check("\(name).ran", false, "\(error)") }
            }
            await independently("F1") { try await firstPlayback(report, box: box, view: view, clips: [ta, tb, oa], music: wav) }
            box.attachOutput = true
            // 가장자리 대상은 배열 위치가 아니라 클립 ID로 고른다(S5-S6-VALIDATE-51: t.clips는 레인 순서라 레인을 바꾸자 index 1이 otf-TA를 가리켰다).
            // 기대 사각형은 손으로 계산해 적는다: 320×180 → 화면 맞춤 6배 = (0, 0, 1920, 1080), 640×480 → 높이 맞춤 2.25배 = (240, 0, 1440, 1080).
            let s1Clip = UUID(), s2Clip = UUID()
            await independently("S1-scaled320") { try await scenario("S1-scaled320", report, box: box, media: [gray], frames: [5, 20],
                    edgeClip: EdgeTarget(clipID: s1Clip, mediaID: gray.id, lane: Lane.videoID, start: 0, expectedRect: CGRect(x: 0, y: 0, width: 1920, height: 1080)), native: false) {
                try Timeline().registering(gray).inserting(media: gray.id, clipID: s1Clip) } }
            await independently("S2-sidebars640") { try await scenario("S2-sidebars640", report, box: box, media: [red], frames: [5, 20],
                    edgeClip: EdgeTarget(clipID: s2Clip, mediaID: red.id, lane: Lane.videoID, start: 0, expectedRect: CGRect(x: 240, y: 0, width: 1440, height: 1080)), native: false) {
                try Timeline().registering(red).inserting(media: red.id, clipID: s2Clip) } }
            await independently("S3-native1080-audio") { try await scenario("S3-native1080-audio", report, box: box, media: [ta], frames: [5, 60], edgeClip: nil, native: true) {
                try Timeline().registering(ta).inserting(media: ta.id) } }
            await independently("S4-half1080") { try await scenario("S4-half1080", report, box: box, media: [ta], frames: [5, 60], edgeClip: nil, native: false) {
                let id = UUID(); return try Timeline().registering(ta).inserting(media: ta.id, clipID: id).settingTransform(clip: id, ClipTransform(scale: 0.5, x: 100, y: 60)) } }
            // S5 기대 사각형: 320×180 → 맞춤 6배 × 0.5 = 960×540, 가운데 (480, 270) + (300, 150) = (780, 420, 960, 540). 회색은 [20, 80)에 V2(맨 위 영상 레인).
            let second = UUID(), smallID = UUID()
            await independently("S5-lanes-gaps-subtitle") { try await scenario("S5-lanes-gaps-subtitle", report, box: box, media: [ta, gray], frames: [5, 15, 25, 40, 50],
                    edgeClip: EdgeTarget(clipID: smallID, mediaID: gray.id, lane: second, start: 20, expectedRect: CGRect(x: 780, y: 420, width: 960, height: 540)), native: false, gaps: [5]) {
                let secondAudio = UUID(), sub = UUID()
                // 레인 순서(2026-11-24 확인): 계획은 t.lanes(.video)를 배열 차례로 쌓고 첫 레인이 맨 위다(CompositionPlanner.layerStack).
                // outward 없이 더한 영상 레인은 기존 영상 레인 아래에 들어가 화면 전체의 otf-TA에 가려졌다(PILOT-VALIDATE-48: 가운데 밝기 95, 원본 71).
                // outward: true는 영상 묶음의 맨 위에 넣는다 — 회색 클립이 otf-TA 위에 보인다.
                var t = try Timeline().registering(ta).registering(gray).addingLane(.video, name: "V2", id: second, outward: true)
                t = try t.placing(media: ta.id, at: 10, videoLane: Lane.videoID, audioLane: Lane.audioID)
                // gray.mov에는 소리가 있다: Timeline.placing은 소리 레인을 요구한다(2026-11-24 시범 두 번이 여기서 laneKindMismatch로 멈췄다).
                // 연결된 소리는 버리지 않고 둘째 소리 레인에 둔다(A1은 [10, 130)의 otf-TA 소리가 쓰고 있다).
                t = try t.addingLane(.audio, name: "A2", id: secondAudio)
                t = try t.placing(media: gray.id, at: 20, videoLane: second, audioLane: gray.hasAudio ? secondAudio : nil, clipID: smallID)
                t = try t.settingTransform(clip: smallID, ClipTransform(scale: 0.5, x: 300, y: 150))
                t = try t.addingLane(.subtitle, name: "S", id: sub, outward: true).addingSubtitle(lane: sub, at: 30, length: 15, text: "ON THE FRAME", id: UUID())
                return t } }
            await independently("S6-ntsc2997") { try await scenario("S6-ntsc2997", report, box: box, media: [ntsc], frames: [4, 5, 6, 89, 90, 91], edgeClip: nil, native: true) {
                try Timeline().registering(ntsc).inserting(media: ntsc.id) } }
            await independently("J") { try await safety(report, box: box, media: ta) }
            report.check("pilot.compositorSwitch", box.corrected ? (box.swapped > 0 && box.swapFailures.isEmpty) : box.swapped == 0,
                         "mode \(mode), preview items switched \(box.swapped), failures \(box.swapFailures)")
        } catch { report.check("pilot.execution", false, "\(error)") }
        report.finish()
    }

    // MARK: 첫 재생(보통 ProjectStore 흐름)

    /// 세 클립을 이은 영상 레인과 연결된 소리, 둘째 소리 레인의 음악(소리 트랙 둘). 26으로 탐색해 둔 뒤 0으로 탐색하고 바로 재생한다.
    /// 실험 합성기에서는 요청의 수신·완료·취소를 프레임별로 적는다. 기본 합성기에는 요청 기록이 없다. 화면 표시는 증명하지 않는다.
    /// beforeSequence/afterSequence(F1-PRESENTATION-PREP-56, 진단 전용): 준비 뒤·26 탐색 전, 멈춤 뒤에 불린다. 탐색·재생·대기는 그대로다.
    /// beforeSequence가 false를 돌려주면 순서를 시작하지 않는다(F1.sequence 실패로 기록).
    static func firstPlayback(_ report: Report, box: Box, view: PlayerNSView, clips: [MediaAsset], music: MediaAsset,
                              beforeSequence: (@MainActor () async -> Bool)? = nil, afterSequence: (@MainActor () async -> Void)? = nil,
                              directStart: Bool = false) async throws {
        let s = report.s, musicLane = UUID()
        var t = Timeline()
        for c in clips { t = t.registering(c) }
        t = t.registering(music)
        for c in clips { t = try t.inserting(media: c.id) }
        t = try t.addingLane(.audio, name: "Music", id: musicLane).placing(media: music.id, at: 30, videoLane: nil, audioLane: musicLane)
        let before = box.log.receivedTimes.count
        s.loadTimelineForTest(t)
        let applied = await LaneSelfTest.waitUntil(15) { s.appliedGeneration == s.generation && s.player.currentItem?.status == .readyToPlay }
        report.check("F1.ready", applied, "segments \(clips.count), audio tracks \(s.currentPlan?.composition.tracks(withMediaType: .audio).count ?? -1)")
        guard applied else { return }
        if let beforeSequence, !(await beforeSequence()) { report.check("F1.sequence", false, "not started: capture was not ready"); return }
        // F1-START-COMPARISON-67(진단 전용): 순서 앞의 항목 상태와 재생 헤드를 적는다. directStart(조건 A)는 26 탐색과 그 대기만 건너뛴다.
        // 그 뒤의 0.5 s 대기, 0 탐색(실제 정확한 탐색), 0 도착 대기, 재생, 2.5 s, 멈춤은 조건 B와 같다.
        report.note("F1.start", directStart ? "direct (A): no seek to 26; seek 0 -> play" : "historical (B): seek 26 -> seek 0 -> play")
        report.note("F1.initialState", "item status \(s.player.currentItem?.status.rawValue ?? -1); item time frames \(String(format: "%.3f", (s.player.currentItem?.currentTime().seconds ?? -1) * 30)); playhead \(s.playhead); applied generation \(s.appliedGeneration) of \(s.generation); rate \(s.player.rate)")
        if !directStart {
            s.seek(to: 26)
            _ = await LaneSelfTest.waitUntil(5) { s.player.currentTime() == CMTime(value: 26, timescale: 30) }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let start = CACurrentMediaTime()
        s.seek(to: 0)
        let atZero = await LaneSelfTest.waitUntil(5) { s.player.currentTime() == .zero }
        let afterSeek = box.log.receivedTimes.count
        let playAt = CACurrentMediaTime()
        s.play()
        var ticks: [String] = []
        let end = Date().addingTimeInterval(2.5)
        while Date() < end {
            if ticks.count < 60, let item = s.player.currentItem { ticks.append(String(format: "%.0fms:%.2f", (CACurrentMediaTime() - start) * 1000, item.currentTime().seconds * 30)) }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        s.pause()
        let pauseAt = CACurrentMediaTime()
        await afterSequence?()
        // 같은 시계(CACurrentMediaTime = mach 호스트 시계, 초)의 표식: 0으로 탐색, 재생 호출, 멈춤 호출
        report.note("F1.clock", String(format: "seekZero %.6f play %.6f pause %.6f", start, playAt, pauseAt))
        func frame(_ t: CMTime) -> Int { Int((t.seconds * 30).rounded()) }
        report.note("F1.playerTicks", ticks.joined(separator: " "))
        report.check("F1.seekToZero", atZero, "item time \(s.player.currentItem?.currentTime().seconds ?? -1)")
        guard box.corrected else {
            report.check("F1.requests", true, "built-in compositor: no custom request record (player ticks only)")
            return
        }
        let received = Array(box.log.receivedTimes.dropFirst(afterSeek)).map(frame)
        let outcomes = box.log.requestOutcomes
        var never: [Int] = [], cancelled: [Int] = []
        for k in 1..<28 {
            let done = outcomes.contains { frame($0.time) == k && $0.outcome == .finished }
            if done { continue }
            if outcomes.contains(where: { frame($0.time) == k && $0.outcome == .cancelled }) { cancelled.append(k) } else if !received.contains(k) { never.append(k) }
        }
        report.note("F1.requestOrder", "\(Array(box.log.receivedTimes.dropFirst(before)).map(frame).prefix(30))")
        // 증거만(단정 없음): 0으로 탐색한 뒤 그려진 요청의 받은 시각과 그리는 데 든 시간(탐색 시작 기준, ms)
        report.note("F1.requestTiming", box.log.snapshot.entries.filter { $0.received >= start }.prefix(12)
            .map { String(format: "t%d recv %.0f ms render %.1f ms", frame($0.time), ($0.received - start) * 1000, ($0.rendered - $0.received) * 1000) }.joined(separator: " | "))
        report.check("F1.noMissingRequest", never.isEmpty, "never requested \(never); request order after play \(received.prefix(16))")
        report.check("F1.noCancelledFrame", cancelled.isEmpty, "requested but cancelled \(cancelled)")
        report.check("F1.noFailedRequest", !outcomes.contains { $0.outcome == .failed }, "failed \(outcomes.filter { $0.outcome == .failed }.count)")
    }

    // MARK: F1 창 캡처(F1-PRESENTATION-PREP-56, 진단 전용)

    /// F1 순서(26 탐색 → 0 탐색 → 재생 2.5 s)를 그대로 돌리면서, 그 전에 시작해 안정된 자기 창 캡처로 창에 합성된 원본 프레임 번호를 읽는다.
    /// 화면 기록 권한을 요청하지 않는다(currentProcess만 사용). 캡처가 시작·안정되지 않으면 F1 순서도 돌리지 않는다(NOT RUN).
    /// 결과: <폴더>/f1-capture.json(표본·표식·실험 합성기 요청 기록), 요약은 증거 행. 분류는 기록이며 PASS 판정이 아니다.
    static func f1Capture(_ report: Report, box: Box, view: PlayerNSView, window: NSWindow, clips: [MediaAsset], music: MediaAsset, directStart: Bool = false) async throws {
        report.note("capture.screenRecordingPreflight", "\(CompositorWindowCapture.screenRecordingPreflight()) (evidence only; never requested)")
        var capture: CompositorWindowCapture?
        var readiness: CompositorWindowCapture.Readiness?
        // 오류로 F1이 중간에 끝나도 캡처는 멈춘다(정리)
        do { try await firstPlayback(report, box: box, view: view, clips: clips, music: music, beforeSequence: {
            do {
                let c = try await CompositorWindowCapture.start(window: window, view: view)
                capture = c
                report.check("capture.started", true, "stream started; selected window \(c.selectedWindow)")
                report.note("capture.geometry", "\(c.geometry)")
                // READINESS-FIX-58: 준비 = 쓸 수 있는 화소 버퍼가 있는 complete 표본 1개 + 0.3 s 동안 오류·종료 상태 없음(총 3 s 한도).
                // idle·blank·상태 표본은 세지 않는다. 읽을 수 있는 원본 번호는 요구하지 않는다(첫 화면은 검거나 빈 Preview일 수 있다).
                let r = await c.waitReady()
                readiness = r
                report.check("capture.readyBeforeSequence", r.ready, String(format: "%@; first valid complete %@; ready %@; statuses %@; usable pixel %d; readable %d; geometry %@; error %@; terminal %@",
                    r.reason, r.firstValidCompleteAt.map { String(format: "+%.0f ms", ($0 - r.requestedAt) * 1000) } ?? "none",
                    r.readyAt.map { String(format: "+%.0f ms", ($0 - r.requestedAt) * 1000) } ?? "none", "\(r.statusCounts)", r.usablePixelSamples, r.readableSamples,
                    "\(r.geometryStates)", r.error ?? "none", r.terminalStatus ?? "none"))
                if !r.ready { await c.stop() }
                return r.ready
            } catch {
                report.check("capture.started", false, "\(error)")
                return false
            }
        }, afterSequence: { await capture?.stop() }, directStart: directStart) } catch { await capture?.stop(); throw error }
        guard let capture else { report.note("F1capture.classification", "NOT RUN (capture not started; F1 sequence not run)"); return }
        await capture.stop()
        let snap = capture.snapshot()
        let clock = report.evidence["F1.clock"] ?? ""
        let nums = clock.split(separator: " ").compactMap { Double($0) }
        struct Request: Codable { let frame: Int; let received: Double; let rendered: Double }
        struct Output: Codable {
            let mode: String; let clock: String; let geometry: CompositorWindowCapture.Geometry; let selectedWindow: String
            let readiness: CompositorWindowCapture.Readiness?
            let samples: [CompositorWindowCapture.Sample]; let overflow: Int; let error: String?
            let compositorRequests: [Request]
        }
        let requests = box.corrected ? box.log.snapshot.entries.map { Request(frame: Int(($0.time.seconds * 30).rounded()), received: $0.received, rendered: $0.rendered) } : []
        let out = Output(mode: box.corrected ? "corrected" : "builtin", clock: clock, geometry: capture.geometry, selectedWindow: capture.selectedWindow,
                         readiness: readiness, samples: snap.samples, overflow: snap.overflow, error: snap.error, compositorRequests: requests)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(out).write(to: report.folder.appendingPathComponent("f1-capture.json"))
        guard readiness?.ready == true else {
            report.note("F1capture.classification", "NOT RUN (capture readiness failed: \(readiness?.reason ?? "no readiness result"); F1 sequence not run)"); return
        }
        // F1-CLASSIFIER-66: 분류는 F1CaptureClassifier가 한다(같은 소스를 저장된 f1-capture.json에 오프라인으로 다시 돌릴 수 있다).
        // 창 범위는 F1.clock의 표식(0 탐색 → 재생 → 멈춤)으로 정한다. 이전 분류는 재생 −100 ms부터 보아서, 0 탐색 직후에도 남아 있던
        // 프레임 26을 "처음 ≥2"로 골라 0→2 간격을 계산하지 못했다(두 실행 모두 INCONCLUSIVE로 잘못 기록).
        let markers = nums.count == 3 ? F1CaptureClassifier.Markers(seekZero: nums[0], play: nums[1], pause: nums[2]) : nil
        let input = snap.samples.map { F1CaptureClassifier.Sample(seq: $0.seq, status: $0.status, time: $0.displayTime ?? $0.arrival, confident: $0.confident,
                                                                 sourceID: $0.sourceID, sourceFrame: $0.sourceFrame) }
        let verdict = F1CaptureClassifier.classify(samples: input, markers: markers, captureError: snap.error, readyAt: readiness?.readyAt)
        try enc.encode(verdict).write(to: report.folder.appendingPathComponent("f1-classification.json"))
        report.note("F1capture.summary", "samples \(snap.samples.count) (overflow \(snap.overflow)); playback window \(verdict.samplesInWindow) \(verdict.statusCounts); complete confident \(verdict.confidentInWindow)/\(verdict.completeInWindow); visible sequence \(verdict.sequence)")
        report.note("F1capture.classification", "\(verdict.verdict.rawValue) (\(verdict.reason)) — capture evidence only; not a playback verdict and not physical display evidence")
    }

    // MARK: 프리뷰·내보내기 대응

    /// 가장자리를 잴 클립(CONTRACT-FIX-52): 클립 ID로 찾고, 원본·레인·시작·사각형을 시나리오가 따로 적은 값과 맞춘다. 없거나 여럿이면 실패다.
    struct EdgeTarget { let clipID: UUID; let mediaID: UUID; let lane: UUID; let start: Int; let expectedRect: CGRect }

    static func scenario(_ name: String, _ report: Report, box: Box, media: [MediaAsset], frames: [Int], edgeClip: EdgeTarget?, native: Bool, gaps: [Int] = [],
                         build: () throws -> Timeline) async throws {
        let s = report.s
        let t = try build()
        s.loadTimelineForTest(t)
        let ready = await LaneSelfTest.waitUntil(15) { s.appliedGeneration == s.generation && s.player.currentItem?.status == .readyToPlay && box.output != nil }
        report.check("\(name).previewReady", ready, "duration \(t.durationFrames)")
        guard ready, let output = box.output else { return }
        // 프리뷰: 멈춘 탐색마다 비디오 출력에서 그 시각의 프레임을 읽는다
        var preview: [Int: Planes] = [:], previewShown: [Int: CMTime] = [:]
        for k in frames {
            s.seek(to: k)
            let want = CMTime(value: CMTimeValue(k), timescale: 30)
            _ = await LaneSelfTest.waitUntil(5) { s.player.currentTime() == want && !s.isPlaying }
            var got: Planes?
            let deadline = Date().addingTimeInterval(3)
            while got == nil && Date() < deadline {
                var shown = CMTime.invalid
                if let pb = output.copyPixelBuffer(forItemTime: want, itemTimeForDisplay: &shown), shown.isNumeric, Int((shown.seconds * 30).rounded()) == k { got = planes(pb); previewShown[k] = shown }
                else { try await Task.sleep(nanoseconds: 30_000_000) }
            }
            report.check("\(name).f\(k).previewFrame", got != nil, got == nil ? "no video-output frame for item time \(k)/30" : "")
            preview[k] = got
        }
        // 내보내기: 같은 타임라인의 실제 계획 → (corrected면 영상 합성만 교체) → 공개 내보내기
        var plan = try await CompositionPlanner.plan(t, media: Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) }))
        let plannerPlan = plan   // 계획기의 지시(맨 위 레이어·변형·원본 구간) 확인용 — 실험 합성기는 같은 계획의 영상 합성만 바꾼다
        if box.corrected { plan = try plan.replacingVideoComposition(withExperimental: .init(edgeCoverage: .fullRectangle)) }
        let out = report.folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = out.appendingPathComponent("\(name).mp4")
        let outcome = await ExportService.export(plan, to: ExportDestination(url: file, confirmedReplace: false, identityAtConfirmation: nil), sources: media, progress: { _ in })
        var completed = false
        if case .completed = outcome { completed = true }
        report.check("\(name).exportCompleted", completed, "\(outcome) path \(plan.subtitles.isEmpty ? "export session" : "writing pump")")
        guard completed else { return }
        var exportPTS: [Int: CMTime] = [:]
        let exported = try await decode(file, frames: Set(frames)) { exportPTS[$0] = $1 }
        let audioTracks = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio).count
        report.note("\(name).audioTracks", "\(audioTracks)")
        if media.contains(where: \.hasAudio) { report.check("\(name).exportHasAudio", audioTracks == 1, "audio tracks \(audioTracks)") }
        let layout = t.clips.map { c in (c, media.first { $0.id == c.mediaID }) }
        // 가장자리 대상 클립: ID로 정확히 하나, 시나리오가 적은 원본·레인·시작·사각형과 같아야 한다. 레인 순서도 기록한다.
        var target: (clip: Clip, asset: MediaAsset, rect: CGRect)?
        if let want = edgeClip {
            let found = t.clips.filter { $0.id == want.clipID }
            let videoLanes = t.lanes(.video).map(\.name)
            report.note("\(name).videoLaneOrder", "top first: \(videoLanes.joined(separator: ", "))")
            if found.count == 1, let c = found.first, let a = media.first(where: { $0.id == c.mediaID }) {
                let r = CompositionPlanner.displayRect(a, c.effectiveTransform, render: CGSize(width: 1920, height: 1080))
                let rectOK = abs(r.minX - want.expectedRect.minX) < 0.5 && abs(r.minY - want.expectedRect.minY) < 0.5
                    && abs(r.width - want.expectedRect.width) < 0.5 && abs(r.height - want.expectedRect.height) < 0.5
                let ok = c.mediaID == want.mediaID && c.lane == want.lane && c.start == want.start && rectOK
                report.check("\(name).edgeClip", ok, "clip \(c.id.uuidString.prefix(8)) media \(a.name) lane \(c.lane.flatMap { t.laneInfo($0)?.name } ?? "?") timeline [\(c.start), \(c.end)) sourceIn \(c.sourceIn) rect \(r) expected \(want.expectedRect)")
                if ok { target = (c, a, r) }
            } else {
                report.check("\(name).edgeClip", false, "clip \(want.clipID.uuidString.prefix(8)) found \(found.count) times (must be exactly once)")
            }
        }
        for k in frames {
            guard let e = exported[k] else { report.check("\(name).f\(k).exportFrame", false, "not decoded"); continue }
            if let p = preview[k] {
                let d = compare(p, e, x0: 0, y0: 0, x1: 1920, y1: 1080)
                report.note("\(name).f\(k).previewVsExport", d.text)
                report.check("\(name).f\(k).previewMatchesExport", d.fraction >= within, d.text)
            }
            if gaps.contains(k) {
                let lit = (0..<(1920 * 1080)).filter { Int(e.y[$0]) > black }.count
                report.check("\(name).f\(k).gapIsBlack", lit == 0, "exported pixels above black \(lit)")
            }
            let subtitleActive = t.renderedSubtitles.contains { $0.start <= k && k < $0.end }
            if let (clip, asset, r) = target, clip.start <= k, k < clip.end {
                let x0 = Int(r.minX.rounded()), y0 = Int(r.minY.rounded()), x1 = Int(r.maxX.rounded()), y1 = Int(r.maxY.rounded())
                let time = CMTime(value: CMTimeValue(k), timescale: 30)
                // ① 계획의 맨 위 레이어: 그 시각의 지시에서 첫 레이어 지시(맨 위)가 이 클립의 원본을 기대 사각형에 그리는가, 원본 구간이 맞는가
                var srcPTS = CMTime.invalid
                let src = try await sourceFrame(asset, timelineFrame: k - clip.start + clip.sourceIn) { srcPTS = $0 }
                let assetStart = try await AVURLAsset(url: asset.url).loadTracks(withMediaType: .video).first?.load(.timeRange).start ?? .zero
                let expectedSourceTime = assetStart + CMTime(value: CMTimeValue(k - clip.start + clip.sourceIn), timescale: 30)
                let instruction = plannerPlan.videoComposition.instructions.compactMap { $0 as? AVVideoCompositionInstruction }.first { $0.timeRange.containsTime(time) }
                if let top = instruction?.layerInstructions.first, let track = plannerPlan.composition.track(withTrackID: top.trackID), let segment = track.segment(forTrackTime: time) {
                    var st = CGAffineTransform.identity, et = CGAffineTransform.identity, ramp = CMTimeRange()
                    _ = top.getTransformRamp(for: time, start: &st, end: &et, timeRange: &ramp)
                    let planned = CGRect(origin: .zero, size: asset.naturalSize).applying(st)
                    let sourceTime = segment.timeMapping.source.start + (time - segment.timeMapping.target.start)
                    let ok = segment.sourceURL?.standardizedFileURL == asset.url.standardizedFileURL && CMTimeCompare(sourceTime, expectedSourceTime) == 0
                        && abs(planned.minX - r.minX) < 0.5 && abs(planned.minY - r.minY) < 0.5 && abs(planned.width - r.width) < 0.5 && abs(planned.height - r.height) < 0.5
                    report.check("\(name).f\(k).planTopLayerIsClip", ok,
                                 "top layer of \(instruction?.layerInstructions.count ?? 0): source \(segment.sourceURL?.lastPathComponent ?? "-") at \(exact(sourceTime)) (expected \(asset.url.lastPathComponent) at \(exact(expectedSourceTime))), planned rect \(planned); chosen source sample \(exact(srcPTS))")
                } else {
                    report.check("\(name).f\(k).planTopLayerIsClip", false, "no planner instruction/top layer/segment at \(exact(time))")
                }
                // 아래 레이어: 같은 프레임에 있는 다른 클립의 원본과 사각형(원본 화소는 그 사각형 안에서만)
                var lower: [(Planes, CGRect)] = []
                for item in layout where item.0.id != clip.id {
                    guard let a = item.1, item.0.start <= k, k < item.0.end else { continue }
                    let rr = CompositionPlanner.displayRect(a, item.0.effectiveTransform, render: CGSize(width: 1920, height: 1080))
                    lower.append((try await sourceFrame(a, timelineFrame: k - item.0.start + item.0.sourceIn), rr))
                }
                func at(_ f: Planes, _ rr: CGRect, _ x: Int, _ y: Int) -> Int? {   // 출력 점 (x, y)에 놓인 원본 화소(사각형 밖이면 nil)
                    guard rr.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) else { return nil }
                    let sx = min(f.w - 1, max(0, Int((Double(x) + 0.5 - rr.minX) * Double(f.w) / rr.width)))
                    let sy = min(f.h - 1, max(0, Int((Double(y) + 0.5 - rr.minY) * Double(f.h) / rr.height)))
                    return f.luma(sx, sy)
                }
                func lowerAt(_ x: Int, _ y: Int) -> Int? { lower.compactMap { at($0.0, $0.1, x, y) }.first }
                // ② 보이는 원본(9×9 격자): 클립 원본과 차 ≤ 허용 차, 아래 원본보다 엄격히 가까움, 판별 가능한 점 ≥ 40. 실패한 점의 좌표를 적는다.
                let grid: [(Int, Int)] = (0..<9).flatMap { gy in (0..<9).map { gx in (x0 + 12 + gx * (x1 - x0 - 25) / 8, y0 + 12 + gy * (y1 - y0 - 25) / 8) } }
                func visibility(_ f: Planes) -> (ok: Bool, text: String) {
                    var discriminating = 0, worst = 0, failed: [String] = []
                    for (x, y) in grid {
                        guard let want = at(src, r, x, y) else { continue }
                        let got = f.luma(x, y), under = lower.compactMap { at($0.0, $0.1, x, y) }
                        guard under.allSatisfy({ abs($0 - want) > tolerance }) else { continue }
                        discriminating += 1; worst = max(worst, abs(got - want))
                        if abs(got - want) > tolerance || under.contains(where: { abs(got - $0) <= abs(got - want) }) {
                            failed.append("(\(x),\(y)) out \(got) clip \(want) lower \(under.map(String.init).joined(separator: "/"))")
                        }
                    }
                    return (discriminating >= 40 && failed.isEmpty,
                            "grid points discriminating \(discriminating)/\(grid.count), failing \(failed.count), max |output − clip source| \(worst), lower layers \(lower.count)"
                            + (failed.isEmpty ? "" : "; failed: " + failed.prefix(24).joined(separator: "; ")))
                }
                let ev = visibility(e)
                func visible(_ f: Planes) -> Bool { f.y.count == e.y.count && visibility(f).ok }
                // 자막 프레임은 글자가 격자 점·끝 줄에 닿을 수 있어 레이어·가장자리 증거가 아니다 — 기록만 하고(판정은 25·50), 그 프레임은 자막 검사가 맡는다
                if subtitleActive {
                    report.note("\(name).f\(k).clipOnTop", "not judged (subtitle active): \(ev.text)")
                    report.note("\(name).f\(k).edges", "not measured: a subtitle is active at this frame")
                } else {
                    report.check("\(name).f\(k).clipOnTop", ev.ok, ev.text)
                    // ③ 끝 열·행(원본 기준 분류): 각 화소를 가장 가까운 기준값으로 나눈다 —
                    //   A 회색(그 줄의 안쪽 4화소 출력값 = 같은 합성기·인코딩을 거친 클립 값, ②가 원본과 맞음을 보였다),
                    //   B 아래 레이어(그 점의 아래 원본 + 사각형 바로 바깥에서 잰 출력−원본 차의 중앙값),
                    //   C 검정(비디오 범위 16; 빈 구간 프레임에서 잰 검정은 24 이하).
                    //   D 압축·색 변환 흔들림: 안쪽 4·6·8화소 출력값의 최대 차(잡음, 최소 1). 기준값끼리의 차가 2×잡음 이하인 화소는 구별하지 못하므로 세지 않는다.
                    //   구별되는 화소가 90% 미만이면 판정 불가(INVALID)로 실패하고, 구별되는 화소가 모두 A일 때만 덮였다고 본다.
                    func classify(_ f: Planes) -> (covered: Bool, invalid: Bool, text: String) {
                        var offsets: [Int] = []
                        for y in stride(from: y0 + 2, to: y1 - 2, by: 8) where x1 + 3 < 1920 { if let u = lowerAt(x1 + 3, y) { offsets.append(f.luma(x1 + 3, y) - u) } }
                        for x in stride(from: x0 + 2, to: x1 - 2, by: 8) where y1 + 3 < 1080 { if let u = lowerAt(x, y1 + 3) { offsets.append(f.luma(x, y1 + 3) - u) } }
                        let offset = offsets.isEmpty ? 0 : offsets.sorted()[offsets.count / 2]
                        var counts = [0, 0, 0], undecided = 0, total = 0, noise = 1, samples: [String] = []
                        var pixels: [(edge: (Int, Int), inner: [(Int, Int)])] = []
                        for y in (y0 + 2)..<(y1 - 2) { pixels.append(((x1 - 1, y), [(x1 - 4, y), (x1 - 6, y), (x1 - 8, y)])) }
                        for x in (x0 + 2)..<(x1 - 2) { pixels.append(((x, y1 - 1), [(x, y1 - 4), (x, y1 - 6), (x, y1 - 8)])) }
                        for px in pixels { let v = px.inner.map { f.luma($0.0, $0.1) }; noise = max(noise, (v.max() ?? 0) - (v.min() ?? 0)) }
                        for px in pixels {
                            total += 1
                            let g = f.luma(px.inner[0].0, px.inner[0].1), out = f.luma(px.edge.0, px.edge.1)
                            var refs = [(0, g), (2, 16)]
                            if let u = lowerAt(px.edge.0, px.edge.1) { refs.append((1, u + offset)) }
                            guard refs.dropFirst().allSatisfy({ abs($0.1 - g) > 2 * noise }) else { undecided += 1; continue }
                            let nearest = refs.min { abs(out - $0.1) < abs(out - $1.1) }!.0
                            counts[nearest] += 1
                            if nearest != 0 && samples.count < 12 { samples.append("(\(px.edge.0),\(px.edge.1)) out \(out) gray \(g)" + (refs.count > 2 ? " lower \(refs[2].1)" : "")) }
                        }
                        let decided = total - undecided
                        let invalid = decided * 10 < total * 9
                        let text = "rect x \(x0)..<\(x1) y \(y0)..<\(y1): edge pixels \(total), gray \(counts[0]), lower layer \(counts[1]), black \(counts[2]), undecided \(undecided); noise \(noise), lower offset \(offset) from \(offsets.count) samples"
                            + (invalid ? "; INVALID evidence: fewer than 90% of edge pixels can be told apart" : "") + (samples.isEmpty ? "" : "; e.g. " + samples.joined(separator: "; "))
                        return (!invalid && counts[1] == 0 && counts[2] == 0, invalid, text)
                    }
                    // ④ 사각형 밖 넘침(따로): 사각형 바로 바깥 한 줄(오른쪽 x1, 아래 y1, 왼쪽 x0−1, 위 y0−1)의 화소가 회색이 아니라 그 자리의 기대값(아래 원본+차, 없으면 검정)에 더 가까운가.
                    //   기대값과 회색이 2×잡음 이하로 붙은 화소는 세지 않는다. 바깥 줄이 없거나 구별되는 화소가 90% 미만이면 NOT VERIFIED(통과로 치지 않음).
                    func outside(_ f: Planes) -> (verified: Bool, clean: Bool, text: String) {
                        var band: [((Int, Int), (Int, Int))] = []   // (바깥 화소, 그 줄의 안쪽 회색 화소)
                        if x1 < 1920 { for y in stride(from: y0 + 2, to: y1 - 2, by: 2) { band.append(((x1, y), (x1 - 4, y))) } }
                        if y1 < 1080 { for x in stride(from: x0 + 2, to: x1 - 2, by: 2) { band.append(((x, y1), (x, y1 - 4))) } }
                        if x0 > 0 { for y in stride(from: y0 + 2, to: y1 - 2, by: 2) { band.append(((x0 - 1, y), (x0 + 3, y))) } }
                        if y0 > 0 { for x in stride(from: x0 + 2, to: x1 - 2, by: 2) { band.append(((x, y0 - 1), (x, y0 + 3))) } }
                        guard !band.isEmpty else { return (false, false, "NOT VERIFIED: the clip rectangle has no outside pixels in the frame") }
                        var offsets: [Int] = []
                        for (o, _) in band where o.0 + 3 < 1920 && o.1 + 3 < 1080 {
                            let q = (o.0 == x1 ? o.0 + 3 : o.0 == x0 - 1 ? o.0 - 3 : o.0, o.1 == y1 ? o.1 + 3 : o.1 == y0 - 1 ? o.1 - 3 : o.1)
                            if q.0 >= 0, q.1 >= 0, let u = lowerAt(q.0, q.1) { offsets.append(f.luma(q.0, q.1) - u) }
                        }
                        let offset = offsets.isEmpty ? 0 : offsets.sorted()[offsets.count / 2]
                        var decided = 0, painted = 0, noise = 1, samples: [String] = []
                        for (_, i) in band { let v = [f.luma(i.0, i.1), f.luma(i.0 == x1 - 4 ? x1 - 6 : i.0 == x0 + 3 ? x0 + 5 : i.0, i.1 == y1 - 4 ? y1 - 6 : i.1 == y0 + 3 ? y0 + 5 : i.1)]; noise = max(noise, abs(v[0] - v[1])) }
                        for (o, i) in band {
                            let g = f.luma(i.0, i.1), out = f.luma(o.0, o.1), expected = lowerAt(o.0, o.1).map { $0 + offset } ?? 16
                            guard abs(expected - g) > 2 * noise else { continue }
                            decided += 1
                            if abs(out - g) <= abs(out - expected) { painted += 1; if samples.count < 12 { samples.append("(\(o.0),\(o.1)) out \(out) gray \(g) expected \(expected)") } }
                        }
                        let verified = decided * 10 >= band.count * 9
                        let text = "outside pixels \(band.count), decided \(decided), closer to the clip \(painted); noise \(noise), lower offset \(offset) from \(offsets.count) samples"
                            + (verified ? "" : "; NOT VERIFIED: fewer than 90% can be told apart") + (samples.isEmpty ? "" : "; e.g. " + samples.joined(separator: "; "))
                        return (verified, painted == 0, text)
                    }
                    for (label, frame) in [("export", Optional(e)), ("preview", preview[k])] {
                        guard let f = frame else { continue }
                        guard visible(f) else {
                            report.check("\(name).f\(k).\(label)FarEdgesCovered", false, "not measurable: the clip is not shown to be the visible top layer in this \(label) frame")
                            report.note("\(name).f\(k).\(label)OutsideRect", "NOT VERIFIED: the clip is not shown to be visible")
                            continue
                        }
                        let c = classify(f)
                        report.check("\(name).f\(k).\(label)FarEdgesCovered", c.covered, c.text)
                        let o = outside(f)
                        if o.verified { report.check("\(name).f\(k).\(label)OutsideRectClean", o.clean, o.text) }
                        else { report.note("\(name).f\(k).\(label)OutsideRect", o.text) }
                    }
                }
            }
            // 자막 프레임: 내보내기에만 자막이 그려진다(프리뷰 비디오 출력에는 자막 층이 없다). 프리뷰와 다른 화소가 조금 있고, 그중 가장 밝은 것이 흰 글자 수준이면
            // 자막이 영상 위에 그려진 것으로 본다. 위치·모양의 정밀 비교는 E4-d parity 시험이 맡는다.
            if subtitleActive, let p = preview[k] {
                var differing = 0, brightest = 0, samples = 0
                for yy in stride(from: 0, to: 1080, by: 2) { for xx in stride(from: 0, to: 1920, by: 2) {
                    samples += 1
                    if abs(e.luma(xx, yy) - p.luma(xx, yy)) > tolerance { differing += 1; brightest = max(brightest, e.luma(xx, yy)) }
                } }
                report.check("\(name).f\(k).subtitleDrawnOverVideo", differing > 0 && differing * 50 < samples && brightest > 200,
                             "export pixels differing from preview \(differing)/\(samples), brightest \(brightest)")
            }
            // 제 크기 한 클립: 내보낸 프레임이 원본의 같은 시각 프레임(트랙 시작 + k/30 이하의 마지막 표본)과 같은가 — 원본 시각 대응
            if native, let asset = media.first {
                var srcPTS = CMTime.invalid
                let src = try await sourceFrame(asset, timelineFrame: k) { srcPTS = $0 }
                let d = compare(src, e, x0: 0, y0: 0, x1: 1920, y1: 1080)
                // 프레임 판별(EVIDENCE-50): 정확한 CMTime(value/timescale)과 화면에 그려진 원본 ID·프레임 번호. 화소 비율이 아니라 코드로 어느 표본인지 본다.
                report.note("\(name).f\(k).identity",
                            "expected source \(exact(srcPTS)) \(frameCode(src)) | export pts \(exportPTS[k].map(exact) ?? "-") \(frameCode(e)) | preview shown \(previewShown[k].map(exact) ?? "-") \(preview[k].map(frameCode) ?? "-")")
                // 결과를 나눈다(CONTRACT-FIX-52): 표본 판별(그려진 원본 번호)과 정확한 시각은 각각의 행, 화소 충실도는 아래 행(exportMatchesSourceTime·previewMatchesExport)이다.
                let want = CMTime(value: CMTimeValue(k), timescale: 30)
                report.note("\(name).f\(k).expectedSourceSample", "\(exact(srcPTS)) drawn \(frameCode(src)) (last sample with PTS <= track start + \(k)/30, exact)")
                report.check("\(name).f\(k).exportSourceIdentity", frameCode(e) == frameCode(src), "export \(frameCode(e)) expected \(frameCode(src))")
                if let p = preview[k] { report.check("\(name).f\(k).previewSourceIdentity", frameCode(p) == frameCode(src), "preview \(frameCode(p)) expected \(frameCode(src))") }
                report.check("\(name).f\(k).exportPTSExact", exportPTS[k].map { CMTimeCompare($0, want) == 0 } ?? false, "decoded \(exportPTS[k].map(exact) ?? "-") requested \(exact(want))")
                if preview[k] != nil { report.check("\(name).f\(k).previewDisplayTimeExact", previewShown[k].map { CMTimeCompare($0, want) == 0 } ?? false, "shown \(previewShown[k].map(exact) ?? "-") requested \(exact(want))") }
                report.check("\(name).f\(k).exportMatchesSourceTime", d.fraction >= within, "pixel fidelity: " + d.text)
            }
        }
    }

    // MARK: S3 프리뷰 수명 비교(PREVIEW-LIFECYCLE-54, 진단 전용)

    /// S3 프리뷰 프레임 불일치(S5-VALIDATE-53: 5/30 표시 시각으로 TA #20이 나옴) 조사. 보통 `ProjectStore` 흐름 그대로이고 탐색·대기 정책은 바꾸지 않는다.
    /// 조건 A: 빈 타임라인(항목 없음, 재생 헤드 0) → S3(otf-TA 한 클립) 적용 → 5로 탐색.
    /// 조건 B: S2(plate-red) 적용 → 20으로 탐색 → S3 적용(재생 헤드 20을 물려받음) → 5로 탐색.
    /// A·B를 번갈아 각 `trials`번. 각 탐색 뒤 비디오 출력이 내준 버퍼를 차례로 적는다(탐색 뒤 ms, 요청 시각, 돌려받은 표시 시각, 그려진 원본 번호,
    /// hasNewPixelBuffer, 플레이어 현재 시각, 재생 상태, 항목·출력 ID, 세대). 판정은 지금 시범과 같은 규칙의 "처음 받아들인 버퍼"이고,
    /// 그 뒤의 버퍼는 증거로만 적는다(최대 1.5 s 또는 40개, 고정 대기로 통과시키지 않는다). 탐색 완료(finished)는 이 파일만으로는 볼 수 없다(PlayerNSView의 비공개 상태).
    /// `-OTFLifecycleHold`가 있으면 각 조건 첫 시행 뒤 3 s 멈춘 채 둔다 — 소유자가 창에서 원본 글자 "TA  f=…"를 읽을 수 있다(화면 기록 아님).
    static func lifecycle(_ report: Report, box: Box, ta: MediaAsset, red: MediaAsset, trials: Int = 8) async throws {
        let s = report.s
        box.attachOutput = true
        let hold = ProcessInfo.processInfo.arguments.contains("-OTFLifecycleHold")
        let expected = frameCode(try await sourceFrame(ta, timelineFrame: 5))
        report.note("lifecycle.expected", "S3 timeline frame 5 -> otf-TA \(expected); trials per condition \(trials); hold \(hold)")
        func id(_ o: AnyObject?) -> String { o.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "nil" }
        func load(_ t: Timeline) async -> Bool {
            box.output = nil   // 앞 항목의 출력이 준비 조건을 채우지 않게(이 진단에서만)
            s.loadTimelineForTest(t)
            return await LaneSelfTest.waitUntil(15) {
                s.appliedGeneration == s.generation && (t.isEmpty ? s.player.currentItem == nil : (s.player.currentItem?.status == .readyToPlay && box.output != nil))
            }
        }
        /// 탐색 하나와 그 뒤 버퍼의 차례. 반환: (처음 받아들인 버퍼의 원본 번호, 기대 번호를 본 적이 있는가, 기록 글)
        func observe(_ k: Int, expect: String?) async -> (first: String?, reached: Bool, text: String) {
            guard let output = box.output, let item = s.player.currentItem else { return (nil, false, "no item/output") }
            let want = CMTime(value: CMTimeValue(k), timescale: 30)
            let before = "playhead \(s.playhead) currentTime \(exact(s.player.currentTime())) item \(id(item)) output \(id(output)) player \(id(s.player)) generation \(s.generation)/\(s.appliedGeneration) status \(item.status.rawValue)"
            s.seek(to: k)
            let t0 = Date()
            var entries: [String] = [], first: String?, reached = false
            while Date().timeIntervalSince(t0) < 1.5 && entries.count < 40 {
                let hasNew = output.hasNewPixelBuffer(forItemTime: want)
                if hasNew || first == nil {
                    var shown = CMTime.invalid
                    if let pb = output.copyPixelBuffer(forItemTime: want, itemTimeForDisplay: &shown), let pl = planes(pb) {
                        let code = frameCode(pl)
                        let accepted = shown.isNumeric && Int((shown.seconds * 30).rounded()) == k
                        if accepted && first == nil { first = code }
                        if code == expect { reached = true }
                        entries.append(String(format: "%.0fms", Date().timeIntervalSince(t0) * 1000) + " new \(hasNew) shown \(exact(shown)) \(code) accepted \(accepted) now \(exact(s.player.currentTime())) tcs \(s.player.timeControlStatus.rawValue) item \(s.player.currentItem === item ? "same" : id(s.player.currentItem))")
                    }
                }
                if reached && first != nil && entries.count >= 2 && Date().timeIntervalSince(t0) > 0.3 { break }   // 기대 번호를 본 뒤 0.3 s 지나면 그만 적는다(판정과 무관)
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return (first, reached, "before seek: \(before) | seek \(exact(want)) | " + entries.joined(separator: " ; "))
        }
        let s3 = { try Timeline().registering(ta).inserting(media: ta.id) }, s2 = { try Timeline().registering(red).inserting(media: red.id) }
        var firstWrong = ["A": 0, "B": 0], neverReached = ["A": 0, "B": 0]
        for i in 0..<trials {
            for cond in ["A", "B"] {
                let name = "lifecycle.\(cond)\(i)"
                if cond == "A" {
                    guard await load(Timeline()) else { report.check("\(name).setup", false, "empty timeline not applied"); continue }
                } else {
                    guard await load(try s2()) else { report.check("\(name).setup", false, "S2 not ready"); continue }
                    _ = await observe(20, expect: nil)
                }
                let inherited = s.playhead
                guard await load(try s3()) else { report.check("\(name).setup", false, "S3 not ready"); continue }
                let o = await observe(5, expect: expected)
                report.note("\(name).sequence", "inherited playhead \(inherited) | \(o.text)")
                report.check("\(name).firstAcceptedIdentity", o.first == expected, "first accepted \(o.first ?? "none") expected \(expected); expected seen later \(o.reached)")
                if o.first != expected { firstWrong[cond]! += 1 }
                if !o.reached { neverReached[cond]! += 1 }
                if hold && i == 0 { report.note("\(name).hold", "held paused 3 s after the readout (owner reads the frame text in the window)"); try? await Task.sleep(nanoseconds: 3_000_000_000) }
            }
        }
        report.note("lifecycle.summary", "first accepted buffer wrong: A \(firstWrong["A"]!)/\(trials), B \(firstWrong["B"]!)/\(trials); expected frame never seen within 1.5 s: A \(neverReached["A"]!), B \(neverReached["B"]!)")
    }

    // MARK: 취소·실패·대상 보호

    static func safety(_ report: Report, box: Box, media: MediaAsset) async throws {
        var plan = try await CompositionPlanner.plan(try Timeline().registering(media).inserting(media: media.id), media: [media.id: media])
        if box.corrected { plan = try plan.replacingVideoComposition(withExperimental: .init(edgeCoverage: .fullRectangle)) }
        let out = report.folder.appendingPathComponent("out", isDirectory: true)
        let sendable = plan
        // 이미 있는 대상: 확인 없이 덮어쓰지 않는다
        let existing = out.appendingPathComponent("J-existing.mp4")
        try Data("keep".utf8).write(to: existing)
        let refused = await ExportService.export(sendable, to: ExportDestination(url: existing, confirmedReplace: false, identityAtConfirmation: nil), sources: [media], progress: { _ in })
        var wasRefused = true
        if case .completed = refused { wasRefused = false }
        report.check("J.existingDestinationProtected", wasRefused && (try? Data(contentsOf: existing)) == Data("keep".utf8), "\(refused)")
        // 실패 주입: 대상이 생기지 않고 임시 폴더가 지워진다
        let failed = out.appendingPathComponent("J-failed.mp4")
        let tempFailed = TempBox()
        let failOutcome = await ExportService.export(sendable, to: ExportDestination(url: failed, confirmedReplace: false, identityAtConfirmation: nil), sources: [media],
                                                     options: .init(failAfterFraction: 0.3, onTempDirectory: { url in tempFailed.set(url) }), progress: { _ in })
        var didFail = false
        if case .failed = failOutcome { didFail = true }
        report.check("J.failureCleansUp", didFail && !FileManager.default.fileExists(atPath: failed.path) && !(tempFailed.get().map { FileManager.default.fileExists(atPath: $0.path) } ?? false),
                     "\(failOutcome) temp \(tempFailed.get()?.lastPathComponent ?? "none")")
        // 취소: 진행 중에 작업을 취소하면 취소로 끝나고 대상이 생기지 않는다
        let cancelled = out.appendingPathComponent("J-cancelled.mp4")
        let tempCancelled = TempBox()
        let task = Task { await ExportService.export(sendable, to: ExportDestination(url: cancelled, confirmedReplace: false, identityAtConfirmation: nil), sources: [media],
                                                     options: .init(onTempDirectory: { url in tempCancelled.set(url) }), progress: { _ in }) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let cancelOutcome = await task.value
        var wasCancelled = false
        if case .cancelled = cancelOutcome { wasCancelled = true }
        report.check("J.cancellationCleansUp", wasCancelled && !FileManager.default.fileExists(atPath: cancelled.path) && !(tempCancelled.get().map { FileManager.default.fileExists(atPath: $0.path) } ?? false),
                     "\(cancelOutcome) temp \(tempCancelled.get()?.lastPathComponent ?? "none")")
        report.check("J.sourceUnchanged", FileIdentity.of(media.url) == media.identity, "")
    }
    final class TempBox: @unchecked Sendable {
        private let lock = NSLock(); private var url: URL?
        func set(_ u: URL) { lock.lock(); url = u; lock.unlock() }
        func get() -> URL? { lock.lock(); defer { lock.unlock() }; return url }
    }

    // MARK: 화소 도우미

    static func exact(_ t: CMTime) -> String { t.isNumeric ? "\(t.value)/\(t.timescale)" : "invalid" }
    /// 판독 가능 생성 재료의 코드 칸(E2 FHD 배치, Spec4K divisor 2): 칸 왼쪽 40, 간격 56, 크기 48. 원본 ID 8비트(y 100), 원본 프레임 16비트(y 170).
    /// 칸 가운데 8×8 밝기 평균이 128을 넘으면 1(켜짐 235, 꺼짐 0 → 비디오 범위 밝기 약 219·16). 판독 가능 재료가 아니면 뜻 없는 값이다.
    static func frameCode(_ p: Planes) -> String {
        guard p.w == 1920, p.h == 1080 else { return "code n/a" }
        func code(_ rowY: Int, _ bits: Int) -> Int {
            var v = 0
            for b in 0..<bits {
                let x0 = 40 + b * 56 + 20, y0 = rowY + 20
                var sum = 0
                for y in y0..<(y0 + 8) { for x in x0..<(x0 + 8) { sum += p.luma(x, y) } }
                v = (v << 1) | (sum / 64 > 128 ? 1 : 0)
            }
            return v
        }
        return String(format: "id%02X#%d", code(100, 8), code(170, 16))
    }
    static func planes(_ pb: CVPixelBuffer) -> Planes? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1), cw = (w / 2) * 2
        var y = [UInt8](repeating: 0, count: w * h), c = [UInt8](repeating: 0, count: w * (h / 2))
        y.withUnsafeMutableBytes { d in for row in 0..<h { memcpy(d.baseAddress! + row * w, yb + row * ybpr, w) } }
        c.withUnsafeMutableBytes { d in for row in 0..<(h / 2) { memcpy(d.baseAddress! + row * w, cb + row * cbpr, cw) } }
        return Planes(w: w, h: h, y: y, c: c)
    }
    static func decode(_ url: URL, frames: Set<Int>, time: (Int, CMTime) -> Void = { _, _ in }) async throws -> [Int: Planes] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [:] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "pilot reader", code: 1) }
        defer { reader.cancelReading() }
        var out: [Int: Planes] = [:]
        while let sample = output.copyNextSampleBuffer() {
            let k = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 30).rounded())
            guard frames.contains(k), out[k] == nil, let pb = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(pb) == 1920, CVPixelBufferGetHeight(pb) == 1080 else { continue }
            out[k] = planes(pb); time(k, CMSampleBufferGetPresentationTimeStamp(sample))
            if out.count == frames.count { break }
        }
        return out
    }
    /// 원본의 타임라인 프레임 k에 보이는 프레임: 표시 시각이 (트랙 시작 + k/30 s) 이하인 마지막 표본(정확한 CMTime 비교)
    static func sourceFrame(_ asset: MediaAsset, timelineFrame k: Int, chosen: (CMTime) -> Void = { _ in }) async throws -> Planes {
        let av = AVURLAsset(url: asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw NSError(domain: "pilot source", code: 1) }
        let range = try await track.load(.timeRange)
        let wanted = range.start + CMTime(value: CMTimeValue(k), timescale: 30)
        let reader = try AVAssetReader(asset: av)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "pilot source", code: 2) }
        defer { reader.cancelReading() }
        var best: Planes?, bestPTS = CMTime.invalid
        while let sample = output.copyNextSampleBuffer() {
            // 정확한 유리수 비교(여유 없음): 표시 시각이 (트랙 시작 + k/30 s) 이하인 마지막 표본. OTFDevSupport의 TimedFixture.frame(atTimelineUnits:)과 같은 규칙이다.
            // 첫 판은 1/600 s 여유를 두어 29.97 fps 원본의 프레임 5에서 다음 표본(5005/30000 s > 5000/30000 s)을 기대값으로 골랐다(PILOT-VALIDATE-48 S6).
            if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), wanted) > 0 { break }
            if let pb = CMSampleBufferGetImageBuffer(sample) { best = planes(pb); bestPTS = CMSampleBufferGetPresentationTimeStamp(sample) }
        }
        guard let best else { throw NSError(domain: "pilot source", code: 3) }
        chosen(bestPTS)
        return best
    }
    struct Diff { var n = 0, ok = 0, maxY = 0, maxC = 0
        var fraction: Double { n == 0 ? 0 : Double(ok) / Double(n) }
        var text: String { String(format: "%d/%d within ±%d (%.2f%%), max dY %d dC %d", ok, n, CompositorPilotSelfTest.tolerance, 100 * fraction, maxY, maxC) } }
    /// 같은 크기의 두 프레임(4화소 간격 표본). 크기가 다르면 비교하지 않는다(n = 0 → 실패).
    static func compare(_ a: Planes, _ b: Planes, x0: Int, y0: Int, x1: Int, y1: Int) -> Diff {
        var d = Diff()
        guard a.w == b.w, a.h == b.h else { return d }
        for y in stride(from: max(0, y0), to: min(a.h, y1), by: 4) { for x in stride(from: max(0, x0), to: min(a.w, x1), by: 4) {
            let dy = abs(a.luma(x, y) - b.luma(x, y)), ca = a.chroma(x, y), cb = b.chroma(x, y)
            let dc = max(abs(ca.cb - cb.cb), abs(ca.cr - cb.cr))
            d.n += 1; d.maxY = max(d.maxY, dy); d.maxC = max(d.maxC, dc)
            if dy <= tolerance && dc <= tolerance { d.ok += 1 }
        } }
        return d
    }
}
#endif
