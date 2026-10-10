#if DEBUG
import AppKit
import OnTheFrameEngine
import SwiftUI

/// 진행 카드·완료 시트 시각 자체 검사(Debug 전용, 일반 화면에 없음). `open -n -W -a OnTheFrame.app <폴더> --args -OTFVisualTest`.
/// - 보통·최소 창 크기에서 내보내기 진행 카드가 편집기 루트 가운데에 있고 카드 크기만 차지하는지
/// - 완료 시트: 내용 영역 가운데, 단추 순서·기본 단추(Return = 닫기)·Esc, Finder 단추는 눌렀을 때만, 반복 열고 닫기, 대기열 차례
/// - 밝은·어두운 모양에서 창 전체와 카드·시트를 PNG로 그려 <폴더>/visual/에 둔다(사람이 보는 용도, 화면 기록 권한 없이 앱 자신의 보기만 그림)
/// 결과는 <폴더>/visual-result.json.
@MainActor
enum VisualSelfTest {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }

    static func run(folder: URL) async {
        let s = ProjectStore.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)) }
        let vis = folder.appendingPathComponent("visual"), out = folder.appendingPathComponent("out"), src = folder.appendingPathComponent("sources")
        try? FileManager.default.createDirectory(at: vis, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApp.activate()
        _ = await waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow else { check("setup.window", false); return finish(folder, checks) }
        w.makeKeyAndOrderFront(nil)
        s.importFiles([src.appendingPathComponent("otf-A.mp4"), src.appendingPathComponent("otf-B.mp4")])
        _ = await waitUntil(30) { s.assets.count == 2 && s.importing == 0 }
        guard s.assets.count == 2 else { check("setup.import", false); return finish(folder, checks) }
        for _ in 0..<4 { s.addToTimeline(s.assets[0].id); s.addToTimeline(s.assets[1].id) }   // 약 28초 타임라인(내보내기 수 초)
        _ = await waitUntil(10) { s.canPlay }

        // 1. 진행 카드 위치(보통 → 최소 창 크기)
        var revealed: [URL] = []
        s.revealOverrideForTest = { revealed.append($0) }
        s.exportOptions = ExportService.Options()
        let dest = out.appendingPathComponent("visual.mp4")
        s.startExport(.fromSavePanel(dest))
        _ = await waitUntil(10) { if case .running(let p) = s.exportPhase { return p > 0.02 } else { return false } }
        for (name, size) in [("normal", NSSize(width: 1500, height: 940)), ("narrow", NSSize(width: 1100, height: 680))] {
            w.setContentSize(size)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let c = s.progressCardFrame, root = s.editorRootSize
            let dx = abs(c.midX - root.width / 2), dy = abs(c.midY - root.height / 2)
            let ok = c.width > 200 && c.width <= 460 + 0.5 && c.height < root.height / 2 && dx <= 2 && dy <= 2 && c.minX >= 0 && c.maxX <= root.width
            check("card.centered.\(name)", ok && s.exportPhase != .idle, String(format: "card %.0f×%.0f at (%.0f,%.0f) root %.0f×%.0f dx %.1f dy %.1f", c.width, c.height, c.minX, c.minY, root.width, root.height, dx, dy))
            for (ap, an) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                NSApp.appearance = NSAppearance(named: ap)
                try? await Task.sleep(nanoseconds: 250_000_000)
                snapshot(w.contentView, to: vis.appendingPathComponent("window-export-\(name)-\(an).png"))
            }
            NSApp.appearance = nil
        }
        // 카드 상태별 그림(같은 공용 카드): 계산 중, 추정, 마무리, 취소 중, 가져오기(긴 파일 이름), 좁은 폭
        let states: [(String, TaskProgressCard)] = [
            ("export-calculating", .init(title: "내보내는 중", percentText: "3%", infoLines: [], progress: 0.03, timeLine: "경과 00:01 · 남은 시간 계산 중…", cancelTitle: "취소", cancelling: false, onCancel: {})),
            ("export-estimate", .init(title: "내보내는 중", percentText: "42%", infoLines: [], progress: 0.42, timeLine: "경과 00:12 · 남은 시간 약 00:35", cancelTitle: "취소", cancelling: false, onCancel: {})),
            ("export-hour", .init(title: "내보내는 중", percentText: "61%", infoLines: [], progress: 0.61, timeLine: "경과 1:02:03 · 남은 시간 약 39:10", cancelTitle: "취소", cancelling: false, onCancel: {})),
            ("export-finalizing", .init(title: "내보내는 중", percentText: "99%", infoLines: [], progress: 0.99, timeLine: "경과 00:41 · 마무리 중…", cancelTitle: "취소", cancelling: false, onCancel: {})),
            ("export-cancelling", .init(title: "내보내기 취소하는 중…", percentText: "57%", infoLines: [], progress: 0.57, timeLine: "경과 00:20 · 취소 중", cancelTitle: "취소", cancelling: true, onCancel: {})),
            ("import", .init(title: "영상 가져오는 중…", percentText: nil, infoLines: ["아주-긴-파일-이름-2026-10-10-여행-영상-원본-촬영본-최종-수정본.mp4", "2/5개 확인 완료"], progress: nil, timeLine: nil, cancelTitle: "취소", cancelling: false, onCancel: {})),
            ("import-cancelling", .init(title: "가져오기 취소하는 중…", percentText: nil, infoLines: ["2/5개 확인 완료"], progress: nil, timeLine: nil, cancelTitle: "취소", cancelling: true, onCancel: {})),
        ]
        for (n, v) in states {
            for (width, wn) in [(CGFloat(460), "wide"), (CGFloat(320), "narrow")] where n.hasPrefix("export-estimate") || n == "import" || wn == "wide" {
                render(v.frame(width: width).padding(20).background(Color(white: 0.5)), to: vis.appendingPathComponent("card-\(n)-\(wn).png"))
            }
        }
        // 2. 완료 시트(실제 내보내기 성공 뒤)
        _ = await waitUntil(120) { s.exportPhase == .idle }
        _ = await waitUntil(5) { s.alerts.currentSheet != nil }
        if let cs = s.alerts.currentSheet {
            try? await Task.sleep(nanoseconds: 500_000_000)   // 시트 등장 애니메이션
            let b = s.alerts.currentButtons
            let content = w.convertToScreen(w.contentLayoutRect)
            let f = cs.panel.frame
            let dx = abs(f.midX - content.midX), dy = abs(f.midY - content.midY)
            check("sheet.successShown", s.alert?.title == "내보내기 완료" && FileManager.default.fileExists(atPath: dest.path) && cs.fileField.stringValue == "visual.mp4",
                  "title \(s.alert?.title ?? "nil") file \(cs.fileField.stringValue)")
            check("sheet.centeredInContent", dx <= 3 && dy <= 3, String(format: "sheet %.0f×%.0f dx %.1f dy %.1f", f.width, f.height, dx, dy))
            check("sheet.buttons", b.map(\.title) == ["Finder에서 보기", "닫기"] && b[1].keyEquivalent == "\r" && b[0].keyEquivalent.isEmpty
                  && cs.panel.defaultButtonCell === b[1].cell && cs.panel.initialFirstResponder === b[1],
                  "titles \(b.map(\.title)) keys \(b.map { $0.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) } })")
            check("sheet.detail", (s.alert?.message ?? "").contains("걸린 시간 ") , s.alert?.message ?? "")
            for (ap, an) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                NSApp.appearance = NSAppearance(named: ap)
                try? await Task.sleep(nanoseconds: 250_000_000)
                snapshot(cs.panel.contentView, to: vis.appendingPathComponent("sheet-success-\(an).png"))
                snapshot(w.contentView, to: vis.appendingPathComponent("window-after-export-\(an).png"))
            }
            NSApp.appearance = nil
            // Return = 닫기(Finder 열지 않음)
            await key(36, "\r", cs.panel)
            let closedByReturn = await waitUntil(5) { !s.alerts.isShowing }
            check("sheet.returnCloses", closedByReturn && revealed.isEmpty, "revealed \(revealed.count)")
        } else { check("sheet.successShown", false, "no completion sheet, alert \(s.alert?.title ?? "nil")") }

        // 3. 반복 열고 닫기: Esc, 닫기 클릭, Finder 클릭(눌렀을 때만 열림), Return. 두 개를 한꺼번에 넣으면 차례로 뜬다.
        let u = dest
        func present(_ name: String) {
            s.presentAlert(ProjectStore.AlertInfo(title: "내보내기 완료", message: "\(name)\n\n걸린 시간 00:39", revealURL: u, completion: (name, "걸린 시간 00:39")))
        }
        var ok = 0
        let long = "아주-긴-파일-이름-2026-10-10-여행-영상-원본-촬영본-최종-수정본-세로-버전-공유용-1080p.mp4"
        for k in 0..<8 {
            present(k == 0 ? long : "repeat-\(k).mp4")
            guard await waitUntil(5, { s.alerts.currentSheet != nil }), let cs = s.alerts.currentSheet else { continue }
            if k == 0 { try? await Task.sleep(nanoseconds: 400_000_000); snapshot(cs.panel.contentView, to: vis.appendingPathComponent("sheet-long-name.png"))
                check("sheet.longNameAccessible", cs.fileField.toolTip == long && (cs.fileField.accessibilityLabel() ?? "").contains(long) && cs.fileField.isSelectable) }
            let before = revealed.count
            switch k % 4 {
            case 0: await key(53, "\u{1b}", cs.panel)                        // Esc
            case 1: s.alerts.pressButton(1)                                  // 닫기
            case 2: s.alerts.pressButton(0)                                  // Finder에서 보기
            default: await key(36, "\r", cs.panel)                           // Return
            }
            let closed = await waitUntil(5) { s.alerts.currentSheet == nil && !s.alerts.isShowing }
            let revealOK = k % 4 == 2 ? revealed.count == before + 1 && revealed.last == u : revealed.count == before
            if closed && revealOK { ok += 1 }
        }
        check("sheet.repeatOpenClose", ok == 8, "\(ok)/8 revealed \(revealed.count)")
        present("queued-1.mp4"); present("queued-2.mp4")
        let firstUp = await waitUntil(5) { s.alerts.currentSheet?.fileField.stringValue == "queued-1.mp4" }
        let queuedOne = s.alerts.queuedCount == 1
        s.alerts.pressButton(1)
        let secondUp = await waitUntil(5) { s.alerts.currentSheet?.fileField.stringValue == "queued-2.mp4" }
        s.alerts.pressButton(1)
        _ = await waitUntil(5) { !s.alerts.isShowing }
        check("sheet.queuedInOrder", firstUp && queuedOne && secondUp && !s.alerts.isShowing)

        // 4. 취소·실패는 완료 시트가 아니다
        s.startExport(.fromSavePanel(out.appendingPathComponent("cancel.mp4")))
        _ = await waitUntil(10) { if case .running(let p) = s.exportPhase { return p > 0.05 } else { return false } }
        s.cancelExport()
        _ = await waitUntil(30) { s.exportPhase == .idle }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("cancel.noSuccessSheet", s.alerts.currentSheet == nil && !s.alerts.isShowing && (s.statusMessage ?? "").contains("취소"), s.statusMessage ?? "")
        s.exportOptions.failAfterFraction = 0.1
        s.startExport(.fromSavePanel(out.appendingPathComponent("fail.mp4")))
        _ = await waitUntil(60) { s.exportPhase == .idle }
        _ = await waitUntil(5) { s.alerts.isShowing }
        check("failure.noSuccessSheet", s.alerts.currentSheet == nil && s.alert?.title == "내보내기 실패", s.alert?.title ?? "nil")
        if let a = s.alerts.current { snapshot(a.window.contentView, to: vis.appendingPathComponent("failure-alert.png")) }
        s.alerts.pressButton(0)
        _ = await waitUntil(5) { !s.alerts.isShowing }
        s.exportOptions = ExportService.Options()
        finish(folder, checks)
    }

    static func snapshot(_ v: NSView?, to url: URL) {
        guard let v, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    static func render<V: View>(_ v: V, to url: URL) {
        let r = ImageRenderer(content: v)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    static func key(_ code: UInt16, _ chars: String, _ w: NSWindow) async {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { NSApp.postEvent(e, atStart: false) }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    static func finish(_ folder: URL, _ checks: [Check]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("visual-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
