import AppKit
import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import QuartzCore
import XCTest

/// 방식 B 프리뷰 자막 시각의 소유자 화면 점검 창(2026-10-21, docs/SUBTITLE-DESIGN.md §19, 실험 — 채택 아님).
/// §17과 같은 fixture(otf-TA)·같은 자막 층 구성(`SubtitleApproachBTests.overlay`)·같은 프리뷰 연결(기본 합성기 videoComposition + AVSynchronizedLayer).
/// 애니메이션 시각은 바꾸지 않는다(오프셋 없음). 자막이 보이는지는 소유자가 보고 기록한다 — 이 코드는 판정하지 않는다.
/// 화면 코드 표시: AVPlayerItemVideoOutput이 내준 버퍼의 원본 코드다(화면에 실제로 그려진 프레임의 증명이 아님).
@MainActor final class OwnerTimingWindow: NSObject {
    typealias Caption = SubtitleApproachBTests.Caption
    final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    let plan: PlannedComposition
    let expected: [ExportJudge.Expected]
    let player: AVPlayer, item: AVPlayerItem, output: AVPlayerItemVideoOutput
    let window: NSWindow
    let status = NSTextField(labelWithString: ""), expectation = NSTextField(labelWithString: ""), lastLog = NSTextField(labelWithString: "")
    let logURL: URL
    private var actions: [Action] = []
    /// 진단용 참조(층 트리 확인)
    let videoView: NSView, playerLayer: AVPlayerLayer, hostLayer = CALayer(), syncLayer: AVSynchronizedLayer
    private(set) var captionLayers: [String: CALayer] = [:], staticLayers: [String: CALayer] = [:]
    /// 대조 층(시험 전용, 시각 점검과 따로, 자막 시각 점검을 대신하지 않음). 같은 그림 경로(CoreText → CGImage → contents)로 만든다.
    /// A = 동기 층 밖(host 바로 아래), 애니메이션 없음. B = 동기 층 안, 애니메이션 없음.
    /// C = 동기 층 안, 자막과 같은 애니메이션 설정(모델 불투명도 0, 불연속 keyframe, AVCoreAnimationBeginTimeAtZero, 같은 길이)이지만 값은 늘 1.
    /// 화면에서 A·B·C·자막 중 무엇이 보이는지로 연결 / 동기 층 하위 / 애니메이션 평가 / 시각 대응을 가른다.
    static let staticCaptions: [Caption] = [
        Caption(name: "static-A-outside-sync", text: "정적 대조 A — 동기 층 밖", font: SubtitleApproachBTests.font, size: 44, rgba: (1, 0.3, 0.3, 1), align: .left,
                origin: CGPoint(x: 60, y: 880), width: 820, start: 0, end: 0),
        Caption(name: "static-B-inside-sync", text: "정적 대조 B — 동기 층 안", font: SubtitleApproachBTests.font, size: 44, rgba: (0.3, 1, 0.3, 1), align: .left,
                origin: CGPoint(x: 60, y: 960), width: 820, start: 0, end: 0),
        Caption(name: "static-C-inside-sync-animated", text: "대조 C — 동기 층 안, 같은 애니메이션(늘 1)", font: SubtitleApproachBTests.font, size: 44, rgba: (1, 0.85, 0.2, 1), align: .left,
                origin: CGPoint(x: 60, y: 800), width: 900, start: 0, end: 0),
    ]
    /// 마지막으로 누른 경계(자막, 프레임)와 그 방식
    private(set) var focus: (caption: Caption, frame: Int)?
    private(set) var target: Int?
    private(set) var mode = "시작 전"
    private(set) var shownCode = "-"
    private(set) var reached = false
    private var stopAt: Int?
    private(set) var observations: [String] = []

    init(plan: PlannedComposition, expected: [ExportJudge.Expected], rasters: [SubtitleApproachBTests.Raster], logURL: URL, staticControls: Bool = false) {
        self.plan = plan; self.expected = expected; self.logURL = logURL
        item = AVPlayerItem(asset: plan.composition)
        item.videoComposition = plan.videoComposition   // 기본 합성기 그대로(animationTool 없음)
        item.audioMix = plan.audioMix
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        videoView = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        playerLayer = AVPlayerLayer(player: player)
        // 항목은 readyToPlay 뒤에 연결한다(bindSubtitles). 2026-10-21 조사: 준비 전에 AVSynchronizedLayer(playerItem:)로 묶으면 같은 구성에서
        // 동기 층이 항목에 묶이지 않은 채(speed 1, timeOffset 0 → 자막 층 지역 시각이 끝 4.0에 머물러 모든 자막 숨김) 남는 일이 13번 중 10번 났다.
        // 준비 뒤 연결은 8번 모두 묶였다(docs/SUBTITLE-DESIGN.md §21).
        syncLayer = AVSynchronizedLayer()
        window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 980, height: 900), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "ON THE FRAME — 방식 B 프리뷰 자막 시각 점검(실험, 소유자 관찰)"
        window.isReleasedWhenClosed = false

        // 영상(1/2 크기) + 같은 좌표의 자막 층 트리(1920×1080 → 960×540)
        let video = videoView
        video.wantsLayer = true
        playerLayer.frame = video.bounds
        video.layer!.addSublayer(playerLayer)
        let host = hostLayer
        host.anchorPoint = .zero
        host.bounds = CGRect(origin: .zero, size: plan.videoComposition.renderSize)
        host.position = .zero
        host.setAffineTransform(CGAffineTransform(scaleX: 0.5, y: 0.5))
        video.layer!.addSublayer(host)
        let sync = syncLayer
        sync.frame = host.bounds
        let overlay = SubtitleApproachBTests.overlay(rasters, size: host.bounds.size, durationFrames: plan.durationFrames)
        captionLayers = overlay.layers
        sync.addSublayer(overlay.root)
        host.addSublayer(sync)
        if staticControls {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (c, parent) in zip(Self.staticCaptions, [host, sync, sync] as [CALayer]) {
                let r = SubtitleApproachBTests.raster(c), l = CALayer()
                l.contents = r.image; l.contentsScale = 1; l.contentsGravity = .resize
                l.frame = CGRect(x: r.rect.minX, y: host.bounds.height - r.rect.maxY, width: r.rect.width, height: r.rect.height)
                l.opacity = 1
                if c.name.hasSuffix("animated") {
                    l.opacity = 0
                    let a = CAKeyframeAnimation(keyPath: "opacity")
                    a.calculationMode = .discrete
                    a.values = [1, 1, 1]
                    a.keyTimes = [0, 0.5, 1]
                    a.beginTime = AVCoreAnimationBeginTimeAtZero
                    a.duration = Double(plan.durationFrames) / 30
                    a.isRemovedOnCompletion = false
                    a.fillMode = .both
                    l.add(a, forKey: "visibility")
                }
                parent.addSublayer(l); staticLayers[c.name] = l
            }
            CATransaction.commit()
        }
        video.widthAnchor.constraint(equalToConstant: 960).isActive = true
        video.heightAnchor.constraint(equalToConstant: 540).isActive = true

        func button(_ title: String, _ run: @escaping () -> Void) -> NSButton {
            let a = Action(run); actions.append(a)
            return NSButton(title: title, target: a, action: #selector(Action.fire))
        }
        var rows: [NSView] = [video]
        for f in [status, expectation, lastLog] { f.font = .monospacedSystemFont(ofSize: 12, weight: .regular); f.lineBreakMode = .byWordWrapping; f.maximumNumberOfLines = 3 }
        rows.append(status); rows.append(expectation)
        let names = ["ko-left": "한국어(왼쪽 아래)", "ja-center": "일본어(오른쪽 위)", "mixed-right": "섞인 두 줄(오른쪽 아래)", "overlap-yellow": "노랑 겹침(한국어 위)"]
        for c in SubtitleApproachBTests.captions {
            let label = NSTextField(labelWithString: "\(names[c.name] ?? c.name) [\(c.start), \(c.end))")
            label.widthAnchor.constraint(equalToConstant: 230).isActive = true
            let items: [(String, Int)] = [("시작−1", c.start - 1), ("시작", c.start), ("시작+1", c.start + 1), ("끝−1", c.end - 1), ("끝", c.end), ("끝+1", c.end + 1)]
            let bs = items.map { t, n in button("\(t) \(n)") { [weak self] in self?.seek(n, caption: c, mode: "멈춤 탐색") } }
            rows.append(NSStackView(views: [label] + bs))
        }
        rows.append(NSStackView(views: [
            button("재생 / 멈춤") { [weak self] in self?.togglePlay() },
            button("경계 앞뒤 다시 재생 ×1") { [weak self] in self?.replay(rate: 1) },
            button("경계 앞뒤 다시 재생 ×0.25") { [weak self] in self?.replay(rate: 0.25) },
            button("다른 곳(프레임 100) 갔다 돌아오기") { [weak self] in self?.awayAndBack() },
        ]))
        let paused = NSTextField(labelWithString: "멈춘 화면 관찰:")
        let playing = NSTextField(labelWithString: "재생 중 관찰:")
        rows.append(NSStackView(views: [paused,
            button("이 자막 보임") { [weak self] in self?.record("보임") },
            button("이 자막 안 보임") { [weak self] in self?.record("안 보임") },
            button("판단 못 함") { [weak self] in self?.record("판단 못 함") }]))
        rows.append(NSStackView(views: [playing,
            button("어긋남 못 봄") { [weak self] in self?.record("재생: 어긋남 못 봄") },
            button("어긋남 봄") { [weak self] in self?.record("재생: 어긋남 봄") },
            button("판단 못 함") { [weak self] in self?.record("재생: 판단 못 함") }]))
        rows.append(lastLog)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        window.contentView = stack
        refresh()
    }

    /// 항목이 readyToPlay가 된 뒤 한 번 부른다: 자막 동기 층을 항목에 연결한다
    func bindSubtitles() {
        precondition(item.status == .readyToPlay, "bind after readyToPlay")
        syncLayer.playerItem = item
    }

    static func expectedRow(_ n: Int) -> String {
        SubtitleApproachBTests.captions.map { "\($0.name) \(SubtitleApproachBTests.expectedVisible($0, frame: n) ? "보임" : "숨김")" }.joined(separator: " · ")
    }

    func seek(_ n: Int, caption: Caption?, mode m: String) {
        player.pause(); stopAt = nil
        if let caption { focus = (caption, n) }
        target = n; mode = m; reached = false; shownCode = "탐색 중"
        Task { @MainActor in
            _ = await player.seek(to: CMTime(value: CMTimeValue(n), timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero)
            if mode == m { mode = m + " 끝남" }
            refresh()
        }
        refresh()
    }
    func togglePlay() {
        if player.rate == 0 { stopAt = nil; mode = "재생"; player.play() } else { player.pause(); mode = "멈춤(재생 뒤)"; target = Int((item.currentTime().seconds * 30).rounded()) }
        refresh()
    }
    /// 마지막 경계 프레임 앞 6프레임부터 뒤 6프레임까지 재생하고 멈춘다(멈춤은 표시 갱신 주기 안에서 하므로 1–2프레임 지나갈 수 있다)
    func replay(rate: Float) {
        guard let f = focus else { mode = "먼저 경계 버튼을 누르세요"; refresh(); return }
        let from = max(0, f.frame - 6), to = min(plan.durationFrames - 1, f.frame + 6)
        player.pause(); stopAt = nil
        mode = "다시 재생 ×\(rate) \(from)→\(to)"; target = f.frame; reached = false
        Task { @MainActor in
            _ = await player.seek(to: CMTime(value: CMTimeValue(from), timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero)
            stopAt = to
            player.rate = rate
            refresh()
        }
    }
    func awayAndBack() {
        guard let f = focus else { mode = "먼저 경계 버튼을 누르세요"; refresh(); return }
        player.pause(); stopAt = nil
        mode = "다른 곳 갔다 오는 중"; reached = false
        Task { @MainActor in
            _ = await player.seek(to: CMTime(value: 100, timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero)
            try? await Task.sleep(nanoseconds: 400_000_000)
            seek(f.frame, caption: f.caption, mode: "다른 곳 갔다 돌아온 멈춤 탐색")
        }
        refresh()
    }
    func record(_ what: String) {
        guard let f = focus else { lastLog.stringValue = "기록 안 함: 먼저 경계 버튼을 누르세요"; return }
        let n = f.frame
        let row = String(format: "%@ | 소유자 관찰(수동) | 방식 %@ | 자막 %@ 경계 프레임 %d | 기대 %@ | 관찰 %@ | 요청 프레임 %@ | 비디오 출력 화면 코드 %@ (요청 프레임과 같음: %@) | 플레이어 시각 프레임 %.3f",
                         ISO8601DateFormatter().string(from: Date()), mode, f.caption.name, n,
                         SubtitleApproachBTests.expectedVisible(f.caption, frame: n) ? "보임" : "숨김", what,
                         target.map { "\($0)" } ?? "-", shownCode, reached ? "예" : "아니오", item.currentTime().seconds * 30)
        observations.append(row)
        lastLog.stringValue = "기록함(\(observations.count)): " + row
        try? (["# 방식 B 프리뷰 자막 시각 — 소유자 화면 관찰(수동 증거, 자동 판정 아님)"] + observations).joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// 표시 갱신(주기적으로 부름): 비디오 출력 버퍼의 화면 코드, 다시 재생 멈춤
    func tick() {
        let now = item.currentTime()
        let t = player.rate == 0 ? now : output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: t), let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            let m = E2Metrics.measure(pb)
            shownCode = m.map { m in "\(DevFixtures.readable.values.first { $0.idCode == m.sourceID }?.key ?? m.sourceKey) \(m.sourceFrame)" } ?? "읽지 못함"
            if let n = target, n < expected.count { reached = ExportJudge.matches(m, expected[n]) }
        }
        if let s = stopAt, now.seconds * 30 >= Double(s) {
            player.pause(); stopAt = nil; mode = "다시 재생 끝(멈춤)"
        }
        refresh()
    }
    func refresh() {
        let itemFrame = item.currentTime().seconds * 30
        status.stringValue = "선택 자막(관찰 기록 대상): \(focus.map { "\($0.caption.name) 경계 \($0.frame)" } ?? "-")\n" + String(format: "요청 프레임 %@ | 플레이어 시각 프레임 %.3f | 비디오 출력 화면 코드 %@ | 요청 프레임 도달: %@ | %@ | %@",
                                    target.map { "\($0)" } ?? "-", itemFrame, shownCode,
                                    target == nil ? "-" : (reached ? "예" : "아직"), player.rate == 0 ? "멈춤" : "재생 ×\(player.rate)", mode)
        if let n = target {
            expectation.stringValue = "기대(프레임 \(n), 보임 = [시작, 끝)): " + Self.expectedRow(n) + (player.rate == 0 ? "" : "  — 재생 중에는 기대를 경계 프레임 기준으로 보세요")
        } else { expectation.stringValue = "경계 버튼을 누르면 그 프레임의 기대가 여기 나옵니다" }
    }
}

extension SubtitleApproachBTests {
    @MainActor func ownerWindow(staticControls: Bool = false) async throws -> OwnerTimingWindow {
        let (p, _, expected) = try await plan()
        let rs = Self.captions.map(Self.raster)
        let dir = ExportEndToEndTests.root.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let w = OwnerTimingWindow(plan: p, expected: expected, rasters: rs, logURL: dir.appendingPathComponent("sb-owner-observations-\(stamp).txt"), staticControls: staticControls)
        let deadline = Date().addingTimeInterval(10)
        while w.item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(w.item.status, .readyToPlay)
        w.bindSubtitles()
        return w
    }
    /// 이벤트를 처리하며 condition이 거짓이 될 때까지(또는 limit까지) 기다린다
    @MainActor func pump(while condition: @escaping @MainActor () -> Bool, limit: TimeInterval, tick: @escaping @MainActor () -> Void) async throws {
        let stop = Date().addingTimeInterval(limit)
        while condition(), Date() < stop {
            while let e = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
            tick()
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    /// 소유자 실행(OTF_SB_WINDOW=1): 점검 창을 열고, 소유자가 창을 닫을 때까지(최대 60분, OTF_SB_WINDOW_SECONDS로 바꿈) 기다린다. 아무것도 판정하지 않는다.
    @MainActor func testApproachBOwnerWindow() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB_WINDOW"] == "1", "소유자 점검 창은 OTF_SB_WINDOW=1일 때만")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let w = try await ownerWindow(staticControls: ProcessInfo.processInfo.environment["OTF_SB_CONTROLS"] == "1")
        w.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        print("SB owner window open; observations file: \(w.logURL.path)")
        let limit = ProcessInfo.processInfo.environment["OTF_SB_WINDOW_SECONDS"].flatMap(Double.init) ?? 3600   // 실행 방법 확인용으로 짧게 줄일 수 있음
        try await pump(while: { w.window.isVisible }, limit: limit, tick: w.tick)
        w.player.pause(); w.player.replaceCurrentItem(with: nil); w.window.orderOut(nil)
        note("owner window closed; owner observations recorded: \(w.observations.count) (file \(w.logURL.lastPathComponent)); not judged by this test")
    }

    /// 조작부 자체 점검(OTF_SB=1): 버튼이 부르는 동작이 요청 프레임에 멈추고 비디오 출력이 그 프레임에 닿는지, 다시 재생이 멈추는지,
    /// 다른 곳 갔다 돌아오기가 같은 프레임으로 오는지만 본다. 자막이 보이는지는 판정하지 않는다(소유자 관찰 몫).
    @MainActor func testApproachBOwnerWindowControls() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        _ = NSApplication.shared
        let w = try await ownerWindow()
        w.window.orderFrontRegardless()
        defer { w.player.pause(); w.player.replaceCurrentItem(with: nil); w.window.orderOut(nil) }
        var rows: [String] = [], bad: [String] = []
        for c in Self.captions { for n in [c.start - 1, c.start, c.start + 1, c.end - 1, c.end, c.end + 1] {
            w.seek(n, caption: c, mode: "멈춤 탐색")
            try await pump(while: { !w.reached }, limit: 3, tick: w.tick)
            let itemFrame = w.item.currentTime().seconds * 30
            // 회귀 확인(프로세스 안 상태만, 화면 보임의 증거 아님): 동기 층이 항목 시각을 따르고(speed 0, timeOffset = n/30),
            // 자막 층 presentation 불투명도가 [시작, 끝) 기대와 같은가. 화면에 실제로 보이는지는 소유자 관찰 몫이다.
            let synced = w.syncLayer.speed == 0 && abs(w.syncLayer.timeOffset - Double(n) / 30) < 1e-6
            let wrongVis = Self.captions.filter { k in w.captionLayers[k.name]!.presentation().map { $0.opacity > 0.5 } != Self.expectedVisible(k, frame: n) }.map(\.name)
            rows.append(String(format: "%@ %d: reached %@ code %@ item %.3f rate %.0f | sync speed %.0f timeOffset %.4f | in-process visibility mismatches %@",
                               c.name, n, w.reached ? "yes" : "NO", w.shownCode, itemFrame, w.player.rate, w.syncLayer.speed, w.syncLayer.timeOffset, "\(wrongVis)"))
            if !w.reached || abs(itemFrame - Double(n)) > 0.001 || w.player.rate != 0 || !synced || !wrongVis.isEmpty { bad.append("\(c.name) \(n)") }
        } }
        note("owner window seek controls (24 boundary buttons; also sync binding and in-process caption presentation, not on-screen evidence): bad \(bad)\n  " + rows.joined(separator: "\n  "))
        XCTAssertTrue(bad.isEmpty, "\(bad)")
        // 다시 재생(×1): 마지막 경계(overlap-yellow 46) 앞뒤 → 멈춤
        w.replay(rate: 1)
        try await pump(while: { w.mode.hasPrefix("다시 재생 ×") || w.player.rate != 0 }, limit: 3, tick: w.tick)
        let after = w.item.currentTime().seconds * 30
        note(String(format: "replay ×1 around 46: stopped at item frame %.3f rate %.0f mode %@", after, w.player.rate, w.mode))
        XCTAssertEqual(w.player.rate, 0); XCTAssertGreaterThanOrEqual(after, 52); XCTAssertLessThan(after, 56)
        // 다른 곳 갔다 돌아오기
        w.awayAndBack()
        try await pump(while: { !(w.mode.hasPrefix("다른 곳 갔다 돌아온") && w.reached) }, limit: 4, tick: w.tick)
        note(String(format: "away-and-back: item frame %.3f reached %@ code %@", w.item.currentTime().seconds * 30, w.reached ? "yes" : "NO", w.shownCode))
        XCTAssertTrue(w.reached); XCTAssertEqual(w.item.currentTime().seconds * 30, 46, accuracy: 0.001)
        // 재생/멈춤
        w.togglePlay(); try await pump(while: { true }, limit: 0.3, tick: w.tick); w.togglePlay()
        XCTAssertEqual(w.player.rate, 0)
        note("play/pause toggle ok; mode \(w.mode). Subtitle visibility not judged (owner observation)")
        XCTAssertTrue(w.observations.isEmpty, "this check must not record owner observations")
        // 배치 확인용 그림(조작부만, AVPlayerLayer·자막 층은 이 방식으로 그려지지 않음): diagnostics/sb-owner-window-layout.png
        if let v = w.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: ExportEndToEndTests.root.appendingPathComponent("diagnostics/sb-owner-window-layout.png"))
        }
    }
}

extension SubtitleApproachBTests {
    /// 소유자 창 자막 미표시 조사(OTF_SB=1, 2026-10-21 소유자 화면 사진: 프레임 54–56에서 일본어·두 줄 자막이 보이지 않음).
    /// 소유자 실행과 같은 구성(일반 앱 활성, 앞 창)에 정적 대조 A·B를 더해, 층 연결·좌표·가시성·내용·동기 시각을 기록하고
    /// 프로세스 안 렌더(CALayer.render(in:), 모델 트리와 presentation 트리)를 그림으로 남긴다. 화면에 실제로 보이는지의 증거는 아니다.
    @MainActor func testApproachBOwnerWindowLayerDiagnostics() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SB"] == "1", "실험 실행은 OTF_SB=1일 때만")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let dir = ExportEndToEndTests.root.appendingPathComponent("diagnostics")
        let w = try await ownerWindow(staticControls: ProcessInfo.processInfo.environment["OTF_SB_CONTROLS"] != "0")   // 소유자 실행과 같은 경로
        w.window.makeKeyAndOrderFront(nil); NSApp.activate()
        defer { w.player.pause(); w.player.replaceCurrentItem(with: nil); w.window.orderOut(nil) }
        try await pump(while: { true }, limit: 0.5, tick: w.tick)
        func f(_ r: CGRect) -> String { String(format: "(%.1f, %.1f, %.1f, %.1f)", r.minX, r.minY, r.width, r.height) }
        let vl = w.videoView.layer!
        var rows: [String] = []
        rows.append("window frame \(f(w.window.frame)) backingScale \(w.window.backingScaleFactor) visible \(w.window.isVisible) occlusion visible \(w.window.occlusionState.contains(.visible)) | videoView frame \(f(w.videoView.frame)) in window \(f(w.videoView.convert(w.videoView.bounds, to: nil)))")
        rows.append("videoView.layer \(type(of: vl)) bounds \(f(vl.bounds)) geometryFlipped \(vl.isGeometryFlipped) masksToBounds \(vl.masksToBounds) sublayers \((vl.sublayers ?? []).map { "\(type(of: $0))" })")
        let h = w.hostLayer, s = w.syncLayer
        rows.append("host superlayer is videoView.layer \(h.superlayer === vl) index \(vl.sublayers?.firstIndex(of: h) ?? -1) | playerLayer index \(vl.sublayers?.firstIndex(of: w.playerLayer) ?? -1) | host bounds \(f(h.bounds)) frame \(f(h.frame)) transform \(h.affineTransform()) opacity \(h.opacity) hidden \(h.isHidden) masks \(h.masksToBounds)")
        rows.append("sync superlayer is host \(s.superlayer === h) frame \(f(s.frame)) opacity \(s.opacity) hidden \(s.isHidden) sublayers \(s.sublayers?.count ?? 0)")
        rows.append("sync layer bound to item: \(w.syncLayer.playerItem === w.item)")
        rows.append(String(format: "before seek: item %.4f status %d | sync speed %.2f timeOffset %.4f | ja local %.4f presentation opacity %@",
                           w.item.currentTime().seconds, w.item.status.rawValue, w.syncLayer.speed, w.syncLayer.timeOffset,
                           w.captionLayers["ja-center"]!.convertTime(CACurrentMediaTime(), from: nil), w.captionLayers["ja-center"]!.presentation().map { String(format: "%.2f", $0.opacity) } ?? "nil"))
        for n in [15, 54, 55, 56] {
            w.seek(n, caption: nil, mode: "진단 멈춤 탐색")
            try await pump(while: { !w.reached }, limit: 3, tick: w.tick)
            try await pump(while: { true }, limit: 0.3, tick: w.tick)
            let now = CACurrentMediaTime()
            rows.append(String(format: "f%d: reached %@ code %@ item %.4f | sync model speed %.2f timeOffset %.4f beginTime %.4f | sync presentation %@",
                               n, w.reached ? "yes" : "NO", w.shownCode, w.item.currentTime().seconds, s.speed, s.timeOffset, s.beginTime,
                               s.presentation().map { String(format: "speed %.2f timeOffset %.4f", $0.speed, $0.timeOffset) } ?? "nil"))
            for (name, l) in w.captionLayers.sorted(by: { $0.key < $1.key }) + w.staticLayers.sorted(by: { $0.key < $1.key }) {
                let img = l.contents.map { CFGetTypeID($0 as CFTypeRef) == CGImage.typeID ? "CGImage \(( $0 as! CGImage).width)x\(($0 as! CGImage).height)" : "other" } ?? "nil"
                let a = l.animation(forKey: "visibility") as? CAKeyframeAnimation
                let want = Self.captions.first { $0.name == name }.map { Self.expectedVisible($0, frame: n) ? "보임" : "숨김" } ?? "정적"
                rows.append(String(format: "  %@ (기대 %@): frame %@ in videoView %@ | model opacity %.2f presentation opacity %@ hidden %@ | contents %@ | local time model %.4f presentation %@ | anim begin %@ dur %@ keyTimes %@",
                                   name, want, f(l.frame), f(l.convert(l.bounds, to: vl)), l.opacity, l.presentation().map { String(format: "%.2f", $0.opacity) } ?? "nil",
                                   l.isHidden ? "yes" : "no", img, l.convertTime(now, from: nil), l.presentation().map { String(format: "%.4f", $0.convertTime(now, from: nil)) } ?? "nil",
                                   a.map { "\($0.beginTime)" } ?? "-", a.map { "\($0.duration)" } ?? "-", a.map { "\($0.keyTimes ?? [])" } ?? "-"))
            }
            // 프로세스 안 렌더(화면 증거 아님): 모델 트리와 presentation 트리
            for (tag, layer) in [("model", vl), ("presentation", vl.presentation() ?? vl)] as [(String, CALayer)] {
                let W = Int(vl.bounds.width), H = Int(vl.bounds.height)
                let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.setFillColor(CGColor(gray: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                layer.render(in: ctx)
                let url = dir.appendingPathComponent("sb-owner-window-inprocess-\(tag)-f\(n).png")
                let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
            }
        }
        note("owner-window layer diagnostics (same construction as the owner run + static controls; in-process state only, not on-screen evidence):\n  " + rows.joined(separator: "\n  "))
    }
}
