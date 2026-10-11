#if DEBUG
import AppKit

/// 창·편집기 배치 자체 검사(A-012, Debug 전용). scripts/layout-test.sh가 따로 둔 저장소(-OTFLayoutSuite)로 세 번 실행한다.
/// - first: 저장값 없음 → 바깥 창 = 쓸 수 있는 영역의 70%, 그 가운데. 나눔 70/30, 20/60/20. 나눔선을 실제 마우스로 끌어 비율을 바꾸고,
///   창 위치·크기를 바꿔 저장(사용자가 크기 조절을 끝낸 것과 같은 저장 함수)한다.
/// - restore: 저장한 창 위치·크기·비율을 되살린다.
/// - offscreen: 화면 밖 저장값(-OTFLayoutInject로 넣음)을 쓸 수 있는 영역 안으로 옮기고 줄인다.
/// 결과는 <폴더>/layout-<단계>.json. 마지막 단계는 따로 둔 저장소를 지운다.
@MainActor
enum LayoutSelfTest {
    struct Check: Codable { let name: String; let pass: Bool; let detail: String }

    static func run(folder: URL, phase: String) async {
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)) }
        let s = ProjectStore.shared, L = EditorLayout.shared
        _ = await waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow, let vf = w.screen?.visibleFrame else { check("setup.window", false); return finish(folder, phase, checks) }
        _ = await waitUntil(3) { L.lastSplit != nil }
        try? await Task.sleep(nanoseconds: 400_000_000)   // 다음 차례 재적용·SwiftUI 배치가 끝나기를
        let f = w.frame
        func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1.5) -> Bool { abs(a - b) <= tol }
        let minOK = w.contentMinSize.width <= vf.width && w.contentMinSize.height <= vf.height
        check("window.minSizeFitsScreen", minOK, "min \(w.contentMinSize) visible \(vf.size)")
        check("window.insideVisible", vf.contains(f), "frame \(f) visible \(vf)")

        switch phase {
        case "first":
            check("window.initial70Centered", L.restoredFrom == "initial-70" && near(f.width, (vf.width * 0.7).rounded()) && near(f.height, (vf.height * 0.7).rounded())
                  && near(f.midX, vf.midX) && near(f.midY, vf.midY),
                  String(format: "source %@ frame %.0f×%.0f mid(%.0f,%.0f) visible %.0f×%.0f mid(%.0f,%.0f)", L.restoredFrom, f.width, f.height, f.midX, f.midY, vf.width, vf.height, vf.midX, vf.midY))
            if let sp = L.lastSplit {
                let H = L.lastContentSize.height - EditorLayout.divider, W = L.lastContentSize.width - 2 * EditorLayout.divider
                check("split.initial", near(sp.upper, (H * 0.7).rounded()) && near(sp.timeline, H - sp.upper) && near(sp.media, (W * 0.15).rounded())
                      && near(sp.inspector, (W * 0.15).rounded()) && near(sp.preview, W - sp.media - sp.inspector) && !L.mediaCollapsed && !L.inspectorCollapsed,
                      String(format: "content %.0f×%.0f upper %.0f timeline %.0f media %.0f preview %.0f inspector %.0f", L.lastContentSize.width, L.lastContentSize.height, sp.upper, sp.timeline, sp.media, sp.preview, sp.inspector))
                // 접기·펼치기(보기 메뉴): 접으면 0, 남는 폭(패널 + 나눔선)은 프리뷰, 펼치면 이전 너비
                let frame0 = w.frame
                func current() async -> EditorLayout.Split? { try? await Task.sleep(nanoseconds: 300_000_000); return L.lastSplit }
                _ = menu("왼쪽 패널 접기")
                let mc = await current()
                _ = menu("왼쪽 패널 펼치기")
                let me = await current()
                check("collapse.media", mc?.media == 0 && mc.map { near($0.preview, sp.preview + sp.media + EditorLayout.divider) } == true && me == sp && L.mediaCollapsed == false,
                      "collapsed media \(mc?.media ?? -1) preview \(mc?.preview ?? -1) → expanded media \(me?.media ?? -1)")
                _ = menu("클립 정보 접기")
                let ic = await current()
                _ = menu("클립 정보 펼치기")
                let ie = await current()
                check("collapse.inspector", ic?.inspector == 0 && ic.map { near($0.preview, sp.preview + sp.inspector + EditorLayout.divider) } == true && ie == sp,
                      "collapsed inspector \(ic?.inspector ?? -1) preview \(ic?.preview ?? -1) → expanded \(ie?.inspector ?? -1)")
                _ = menu("왼쪽 패널 접기"); _ = menu("클립 정보 접기")
                let both = await current()
                check("collapse.both", both.map { $0.media == 0 && $0.inspector == 0 && near($0.preview, L.lastContentSize.width) } == true, "preview \(both?.preview ?? -1)")
                // 바꾼 상태에서 "기본 배치로 재설정": 비율·펼침만, 창 위치·크기는 그대로
                L.upperFraction = 0.55; L.mediaFraction = 0.3; L.saveFractions()
                let resetOK = menu("기본 배치로 재설정")
                let rs = await current()
                check("reset.defaultLayout", resetOK && rs == sp && !L.mediaCollapsed && !L.inspectorCollapsed && L.upperFraction == 0.7 && L.mediaFraction == 0.15
                      && L.inspectorFraction == 0.15 && w.frame == frame0 && L.defaults.double(forKey: EditorLayout.mediaKey) == 0.15,
                      "split \(rs.map { "\($0.media)/\($0.preview)/\($0.inspector) \($0.upper)/\($0.timeline)" } ?? "nil") frame same \(w.frame == frame0)")
                // 목록·프리뷰 사이 나눔선을 실제 마우스로 +60 pt 끈다
                let cl = w.contentLayoutRect                       // 툴바 아래 내용 영역(창 좌표, 아래쪽 원점)
                let y = cl.maxY - sp.upper / 2
                let x0 = cl.minX + sp.media + EditorLayout.divider / 2
                let before = L.mediaFraction
                await mouse(.leftMouseDown, NSPoint(x: x0, y: y), w)
                for k in 1...6 { await mouse(.leftMouseDragged, NSPoint(x: x0 + CGFloat(k) * 10, y: y), w) }
                await mouse(.leftMouseUp, NSPoint(x: x0 + 60, y: y), w)
                try? await Task.sleep(nanoseconds: 200_000_000)
                let saved = L.defaults.double(forKey: EditorLayout.mediaKey)
                check("split.dragAndRemember", L.mediaFraction > before + 0.02 && abs(saved - L.mediaFraction) < 1e-9,
                      String(format: "media %.3f → %.3f saved %.3f", before, L.mediaFraction, saved))
                // 타임라인 높이 비율도 바꿔 저장(나눔선 끝과 같은 저장 함수)
                L.upperFraction = 0.62; L.saveFractions()
                L.toggleInspector()   // 접힘 상태도 저장되어 다음 실행에 남는지(restore)
            } else { check("split.initial", false, "no split") }
            // 사용자가 창을 옮기고 크기를 바꾼 것으로 보고 저장
            let target = NSRect(x: vf.minX + 40, y: vf.minY + 30, width: (vf.width * 0.6).rounded(), height: (vf.height * 0.62).rounded())
            w.setFrame(target, display: true)
            L.saveFrame(w)
            check("window.saved", L.defaults.string(forKey: EditorLayout.frameKey) == NSStringFromRect(w.frame), L.defaults.string(forKey: EditorLayout.frameKey) ?? "nil")
        case "restore":
            let saved = L.defaults.string(forKey: EditorLayout.frameKey).map(NSRectFromString) ?? .zero
            check("window.restored", L.restoredFrom == "restored" && near(f.minX, saved.minX) && near(f.minY, saved.minY) && near(f.width, saved.width) && near(f.height, saved.height),
                  "source \(L.restoredFrom) frame \(f) saved \(saved)")
            if let sp = L.lastSplit {
                let H = L.lastContentSize.height - EditorLayout.divider
                check("split.restored", abs(L.upperFraction - 0.62) < 1e-9 && L.mediaFraction > 0.17 && near(sp.upper, (H * 0.62).rounded())
                      && L.inspectorCollapsed && sp.inspector == 0,
                      String(format: "upper %.3f media %.3f upperH %.0f inspector %.0f collapsed %@", L.upperFraction, L.mediaFraction, sp.upper, sp.inspector, L.inspectorCollapsed ? "yes" : "no"))
                // 펼치면 저장된 비율(15%)의 너비로 돌아온다
                L.toggleInspector()
                try? await Task.sleep(nanoseconds: 300_000_000)
                let W = L.lastContentSize.width - 2 * EditorLayout.divider
                check("collapse.expandRestoresWidth", (L.lastSplit?.inspector).map { near($0, (W * 0.15).rounded()) } == true, "inspector \(L.lastSplit?.inspector ?? -1)")
                // 작은 창: 최소 폭(목록 160·정보 180·프리뷰 320)이 비율보다 앞선다
                let keep = w.frame
                w.setContentSize(w.contentMinSize)
                try? await Task.sleep(nanoseconds: 400_000_000)
                if let m = L.lastSplit {
                    check("split.minimumsOnSmallWindow", m.media >= EditorLayout.minMedia - 0.5 && m.inspector >= EditorLayout.minInspector - 0.5 && m.preview >= EditorLayout.minPreview - 0.5
                          && m.upper >= EditorLayout.minUpper - 0.5 && m.timeline >= EditorLayout.minTimeline - 0.5,
                          "content \(L.lastContentSize) media \(m.media) preview \(m.preview) inspector \(m.inspector) upper \(m.upper) timeline \(m.timeline)")
                }
                w.setFrame(keep, display: true)
            } else { check("split.restored", false, "no split") }
        case "offscreen":
            check("window.offscreenAdjusted", L.restoredFrom == "restored-adjusted" && vf.contains(f) && f.width <= vf.width && f.height <= vf.height,
                  "source \(L.restoredFrom) frame \(f) visible \(vf)")
            if let suite = L.suiteName { L.defaults.removePersistentDomain(forName: suite) }   // 검사용 저장소 정리
        default:
            check("phase", false, phase)
        }
        finish(folder, phase, checks)
    }

    /// 주 메뉴 항목 실행(메뉴를 여는 것과 같은 갱신 뒤)
    static func menu(_ title: String) -> Bool {
        func all(_ m: NSMenu?) -> [NSMenuItem] { guard let m else { return [] }; return m.items.flatMap { [$0] + all($0.submenu) } }
        for m in Set(all(NSApp.mainMenu).compactMap(\.submenu)) { m.delegate?.menuNeedsUpdate?(m) }
        guard let it = all(NSApp.mainMenu).first(where: { $0.title == title }), let m = it.menu, let i = m.items.firstIndex(of: it), it.isEnabled else { return false }
        m.performActionForItem(at: i)
        return true
    }
    static func mouse(_ t: NSEvent.EventType, _ p: NSPoint, _ w: NSWindow) async {
        if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1) {
            NSApp.postEvent(e, atStart: false)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
    }
    static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    static func finish(_ folder: URL, _ phase: String, _ checks: [Check]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("layout-\(phase).json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
