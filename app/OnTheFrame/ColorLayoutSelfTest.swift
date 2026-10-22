#if DEBUG
import AppKit
import OnTheFrameEngine
import SwiftUI

/// 자막 색 칸 배치 검사(2026-10-23, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFColorLayoutTest`.
/// 왼쪽 "클립 조정" 패널과 같은 여백(스크롤 10 + 묶음 8)으로 "모양" 칸을 화면 밖 창에 그려, 패널 폭 160(최소)·200(보통)·280에서
/// 밝은·어두운 모양 그림(PNG)을 남기고, AppKit 조작(색 상자·글 칸)의 자리를 잰다: 가로로 잘리지 않음, 왼쪽 끝 맞춤, 글 칸 높이·가운데 같음.
/// 화면 기록 권한을 쓰지 않는다(보기를 비트맵에 그림). 결과는 <폴더>/colorlayout-result.json, 그림은 <폴더>/color-<폭>-<모양>.png.
@MainActor
enum ColorLayoutSelfTest {
    typealias Check = LaneSelfTest.Check
    static func run(folder: URL) async {
        var checks: [Check] = []
        let s = ProjectStore.shared
        var st = SubtitleStyle.default; st.red = 255; st.green = 214; st.blue = 0   // 팔레트 "노랑"과 같은 색(선택 표시)
        for width in [160.0, 200.0, 268.0, 280.0] {   // 268 = 이 Mac 2560 pt 화면의 기본 창(70%)에서 왼쪽 패널 기본 폭(15%)
            for dark in [false, true] {
                let root = ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        AdjustSection(title: "모양") { SubtitleStyleAdjust(store: s, id: UUID(), stored: st, project: s.projectSession) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(width: width, height: 640)
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 300_000_000)
                host.layoutSubtreeIfNeeded()
                let name = "color-\(Int(width))-\(dark ? "dark" : "light")"
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
                }
                func all<T: NSView>(_ t: T.Type, _ v: NSView) -> [T] { (v as? T).map { [$0] } ?? [] + v.subviews.flatMap { all(t, $0) } }
                let wells = all(NSColorWell.self, host).map { $0.convert($0.bounds, to: host) }
                let fields = all(NSTextField.self, host).filter(\.isEditable).map { ($0.placeholderString ?? "", $0.convert($0.bounds, to: host)) }
                let hexF = all(NSTextField.self, host).first { $0.isEditable && $0.placeholderString == "#RRGGBB" }
                let opF = all(NSTextField.self, host).first { $0.isEditable && $0.placeholderString == "100" }
                let hex = hexF.map { $0.convert($0.bounds, to: host) }, op = opF.map { $0.convert($0.bounds, to: host) }
                let content = CGFloat(width) - 18   // 오른쪽 안쪽 끝(여백 10 + 8)
                let insideAll = (fields.map(\.1) + wells).allSatisfy { $0.maxX <= content + 0.5 && $0.minX >= 17.5 }
                guard let w0 = wells.first, let hx = hex, let o = op, let hf = hexF, let of = opF else {
                    checks.append(Check(name: "layout.\(name)", pass: false, detail: "조작 없음 wells \(wells.count) fields \(fields.map(\.0))")); continue
                }
                let oneRow = abs(w0.midY - hx.midY) < 1 && abs(hx.midY - o.midY) < 1
                let twoRows = hx.minY > w0.maxY && abs(hx.midY - o.midY) < 1
                let notStretched = w0.width <= 44 && abs(hx.width - 70) < 1 && abs(o.width - 36) < 1
                func fits(_ f: NSTextField, _ t: String) -> Bool { NSAttributedString(string: t, attributes: [.font: f.font!]).size().width + 8 <= f.bounds.width }
                let legible = ["#FFD600", "#DDDDDD", "#BDBDBD", "#888888"].allSatisfy { fits(hf, $0) } && fits(of, "100") && (hf.font?.pointSize ?? 0) >= 11 && (of.font?.pointSize ?? 0) >= 11
                let heights = abs(hx.height - o.height) < 0.5 && (twoRows || abs(w0.height - hx.height) <= 1)
                let expect = width >= 268 ? oneRow : (width <= 160 ? twoRows : (oneRow || twoRows))
                checks.append(Check(name: "layout.\(name)", pass: insideAll && expect && notStretched && legible && heights,
                                    detail: "\(oneRow ? "한 줄" : (twoRows ? "두 줄" : "?")) well \(w0) hex \(hx) op \(o) font \(hf.font?.pointSize ?? 0) content 18…\(content) inside \(insideAll) legible \(legible) heights \(heights)"))
            }
        }
        // 지금 색 상자 입력 길(색 패널을 열지 않음): 상자의 동작을 직접 보내면 값이 처리기로 온다(sRGB 변환 포함)
        final class Box { var got: NSColor? }
        let box = Box()
        let wellHost = NSHostingView(rootView: CurrentColorWell(color: .white) { box.got = $0 }.frame(width: 120, height: 22))
        wellHost.frame = NSRect(x: 0, y: 0, width: 120, height: 22); wellHost.layoutSubtreeIfNeeded()
        func wells(_ v: NSView) -> [NSColorWell] { (v as? NSColorWell).map { [$0] } ?? [] + v.subviews.flatMap(wells) }
        if let well = wells(wellHost).first {
            well.color = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 0.5)
            _ = well.sendAction(well.action, to: well.target)
            let st = box.got.map { SubtitleStyleAdjust.styled(.default, from: $0) }
            checks.append(Check(name: "well.actionReachesHandler", pass: st.map { [$0.red, $0.green, $0.blue, $0.alpha] } == [255, 0, 0, 128] && well.toolTip?.contains("휠") == true
                                && well.accessibilityHelp()?.contains("색 패널") == true && well.supportsAlpha,
                                detail: "got \(st.map { [$0.red, $0.green, $0.blue, $0.alpha] } ?? []) tooltip \(well.toolTip ?? "nil")"))
        } else { checks.append(Check(name: "well.actionReachesHandler", pass: false, detail: "색 상자 없음")) }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("colorlayout-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
