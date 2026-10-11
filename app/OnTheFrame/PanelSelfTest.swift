#if DEBUG
import AppKit
import OnTheFrameEngine

/// 왼쪽 패널 탭·클립 조정·오른쪽 읽기 전용 정보 자체 검사(2026-10-11, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFPanelTest`.
/// SwiftUI 칸 뒤의 실제 AppKit 컨트롤(분할 단추·글자 칸·팝업 단추·체크 상자·슬라이더)을 찾아 쓴다. 결과는 <폴더>/panel-result.json.
/// 합성 이벤트 검사이며 실제 키보드·한글 입력기 확인이 아니다(한글 조합은 필드 편집기의 setMarkedText·insertText로 흉내 냄).
@MainActor
enum PanelSelfTest {
    typealias Check = LaneSelfTest.Check

    static func run(folder: URL) async {
        let s = ProjectStore.shared, L = EditorLayout.shared
        var checks: [Check] = []
        func check(_ n: String, _ p: Bool, _ d: String = "") { checks.append(Check(name: n, pass: p, detail: d)); LaneSelfTest.checkCountForMode = checks.count }
        let src = folder.appendingPathComponent("sources")
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        guard let w = s.editorWindow, let cv = w.contentView else { return finish(folder, [Check(name: "setup.window", pass: false, detail: "")]) }
        w.makeKeyAndOrderFront(nil)
        if !(await LaneSelfTest.regainFocus(w)) { LaneSelfTest.direct = true }
        L.leftTab = .media
        s.importFiles(["otf-TA.mp4", "otf-TB.mp4", "aud-wav48s.wav"].map { src.appendingPathComponent($0) })
        _ = await LaneSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 3 }
        let by = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.name, $0) })
        guard let ta = by["otf-TA.mp4"], let tb = by["otf-TB.mp4"], let wav = by["aud-wav48s.wav"] else { return finish(folder, [Check(name: "setup.import", pass: false, detail: "")]) }
        s.addToTimeline(ta.id)                                   // V1·A1 [0,120)
        s.addLanePair()                                          // V2·A2
        let v2 = s.timeline.lanes(.video).first!.id, a2 = s.timeline.lanes(.audio).last!.id
        s.placeMedia(tb.id, atFrame: 0, lane: v2)                // V2·A2 [0,90)
        s.placeMedia(wav.id, atFrame: 130, lane: a2)             // A2 [130,190)
        s.addLanePair()                                          // V3·A3(빈 레인)
        let v3 = s.timeline.lanes(.video).first!.id, a3 = s.timeline.lanes(.audio).last!.id
        guard let tbV = s.timeline.clips(inLane: v2).first?.id, let tbA = s.timeline.partner(of: tbV)?.id,
              let wavC = s.timeline.clips(inLane: a2).first(where: { $0.mediaID == wav.id })?.id else { return finish(folder, [Check(name: "setup.timeline", pass: false, detail: "\(s.timeline.lanes.map(\.name))")]) }
        s.select(nil); s.selectLane(nil)
        await LaneSelfTest.settle()

        // 패널 사각형(창 좌표): 왼쪽 [0, media], 오른쪽 [너비 − inspector, 너비]
        func split() -> EditorLayout.Split? { L.lastSplit }
        // 위 패널 영역만(아래 타임라인은 창 전체 너비라 제외). 창 좌표는 아래가 원점. 위 끝은 프리뷰 화면의 위 끝(도구 막대가 내용 위에 겹침),
        // 아래 끝은 타임라인 영역의 위 끝 — 실제 보기에서 잰다.
        func upperBand() -> (y0: CGFloat, y1: CGFloat) {
            let top = LaneSelfTest.find(PlayerNSView.self, cv).map { frameInWindow($0).maxY } ?? cv.bounds.height
            return (top - (split()?.upper ?? 0) + 1, cv.bounds.height)   // 위: 도구 막대 아래 내용 끝까지(패널 첫 줄 포함)
        }
        func leftRect() -> NSRect { let b = upperBand(); return NSRect(x: 0, y: b.y0, width: split()?.media ?? 0, height: b.y1 - b.y0) }
        func rightRect() -> NSRect { let b = upperBand(), i = split()?.inspector ?? 0; return NSRect(x: cv.bounds.width - i, y: b.y0, width: i, height: b.y1 - b.y0) }
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        func frameInWindow(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }
        func views<T: NSView>(_ t: T.Type, in r: NSRect) -> [T] {
            all(cv).compactMap { $0 as? T }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil && r.insetBy(dx: -1, dy: -1).contains(NSPoint(x: frameInWindow($0).midX, y: frameInWindow($0).midY)) }
        }
        /// 왼쪽 패널의 보기: 보이는 영역 안 + 왼쪽 스크롤 보기 안(스크롤 밖으로 밀린 칸 포함 — 클립 조정 탭이 길어 짝 레인 팝업이 아래로 밀림)
        func leftViews<T: NSView>(_ t: T.Type) -> [T] {
            let doc = views(NSScrollView.self, in: leftRect()).compactMap(\.documentView)
            let inScroll = doc.flatMap(all).compactMap { $0 as? T }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
            var seen = Set<ObjectIdentifier>()
            return (views(t, in: leftRect()) + inScroll).filter { seen.insert(ObjectIdentifier($0)).inserted }
        }
        func field(_ placeholder: String) -> NSTextField? { leftViews(NSTextField.self).first { $0.placeholderString == placeholder && $0.isEditable } }
        /// 글자 칸에 값을 넣고 Return(한 단계)
        func typeInto(_ f: NSTextField, _ text: String) async {
            w.makeFirstResponder(f)
            await LaneSelfTest.settle()
            if let ed = w.firstResponder as? NSTextView { ed.selectAll(nil); ed.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            await LaneSelfTest.key(36, "\r", [], w)
        }
        func texts(in r: NSRect) -> [String] { views(NSTextField.self, in: r).map(\.stringValue) }
        /// 접근성 트리의 글자와 창 좌표 사각형(선택할 수 있는 글자 등 AppKit이 내보이는 것만 — SwiftUI 정적 글자는 이 경로로 보이지 않음)
        func axItems(_ e: Any, depth: Int = 0) -> [(text: String, frame: NSRect)] {
            guard depth < 60, let o = e as? NSObject else { return [] }
            var out: [(String, NSRect)] = []
            // 이전 속성 API: 위치는 주 화면 왼쪽 위 원점(아래 +Y) → Cocoa 화면 좌표 → 창 좌표
            if let v = (o.accessibilityAttributeValue(.value) as? String) ?? (o.accessibilityAttributeValue(.title) as? String), !v.isEmpty,
               let pos = (o.accessibilityAttributeValue(.position) as? NSValue)?.pointValue, let size = (o.accessibilityAttributeValue(.size) as? NSValue)?.sizeValue {
                let h0 = NSScreen.screens.first?.frame.height ?? 0
                out.append((v, w.convertFromScreen(NSRect(x: pos.x, y: h0 - pos.y - size.height, width: size.width, height: size.height))))
            }
            var kids = (o as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
            if kids.isEmpty, let c = o.accessibilityAttributeValue(.children) as? [Any] { kids = c }
            for c in kids { out += axItems(c, depth: depth + 1) }
            return out
        }
        /// 한쪽 패널만 펼친 채 읽은 접근성 글자(위치를 쓰지 않음: 다른 쪽 패널을 접어 그 패널 글자를 뺀다. 타임라인 머리는 사용자 정의 그리기라 글자가 없고,
        /// 타임라인 "레인 추가" 팝업 제목만 뺀다)
        func axOnly(left: Bool) async -> [String] {
            if left { L.inspectorCollapsed = true } else { L.mediaCollapsed = true }
            await LaneSelfTest.settle()
            let t = axItems(cv).map(\.text).filter { $0 != "레인 추가" }
            if left { L.inspectorCollapsed = false } else { L.mediaCollapsed = false }
            await LaneSelfTest.settle()
            return t
        }
        /// 접근성 트리의 글자(라벨·값·제목). 새 API와 이전 속성 API를 함께 본다.
        func axTexts(_ e: Any, depth: Int = 0) -> [String] {
            guard depth < 60, let o = e as? NSObject else { return [] }
            var out: [String] = []
            var kids: [Any] = []
            if let p = o as? NSAccessibilityProtocol {
                if let l = p.accessibilityLabel(), !l.isEmpty { out.append(l) }
                if let v = p.accessibilityValue() as? String, !v.isEmpty { out.append(v) }
                kids = p.accessibilityChildren() ?? []
            }
            for a in [NSAccessibility.Attribute.title, .value, .description] {
                if let v = o.accessibilityAttributeValue(a) as? String, !v.isEmpty { out.append(v) }
            }
            if kids.isEmpty, let c = o.accessibilityAttributeValue(.children) as? [Any] { kids = c }
            for c in kids { out += axTexts(c, depth: depth + 1) }
            return out
        }

        // 1. 탭: 미디어(기본) · 클립 조정
        let seg = views(NSSegmentedControl.self, in: leftRect()).first
        let labels = seg.map { sc in (0..<sc.segmentCount).map { sc.label(forSegment: $0) ?? "" } } ?? []
        check("tabs.present", labels == ["미디어", "클립 조정"] && L.leftTab == .media, "labels \(labels) tab \(L.leftTab)")
        func pickTab(_ i: Int) async {
            guard let sc = views(NSSegmentedControl.self, in: leftRect()).first else { return }
            sc.selectedSegment = i; _ = sc.sendAction(sc.action, to: sc.target)
            await LaneSelfTest.settle()
        }
        await pickTab(1)
        check("tabs.switchToAdjust", L.leftTab == .adjust && L.defaults.string(forKey: EditorLayout.leftTabKey) == "adjust", "tab \(L.leftTab)")
        // 빈 상태: 편집 칸·팝업·대상 이름이 없다(안내 문구 자체는 SwiftUI 정적 글자라 이 검사로 읽지 못함 — 화면 확인)
        let leftEditable = views(NSTextField.self, in: leftRect()).filter(\.isEditable).count + views(NSPopUpButton.self, in: leftRect()).count
        let emptyTexts = await axOnly(left: true)
        check("adjust.emptyState", leftEditable == 0 && emptyTexts.filter { !["미디어", "클립 조정"].contains($0) }.isEmpty, "editable \(leftEditable) texts \(emptyTexts)")

        // 2. 클립을 골라도 탭은 그대로(조정 탭 → 그대로, 미디어 탭 → 그대로)
        s.select(tbV)
        await LaneSelfTest.settle()
        let header = await axOnly(left: true)
        check("adjust.showsSelection", L.leftTab == .adjust && field("크기") != nil && header.contains("otf-TB.mp4") && header.contains { $0.contains("V2 · 영상") }, "\(header)")
        await pickTab(0)
        s.select(wavC); await LaneSelfTest.settle(); s.select(tbV); await LaneSelfTest.settle()
        check("tabs.selectionDoesNotSwitch", L.leftTab == .media && field("크기") == nil, "tab \(L.leftTab)")
        await pickTab(1)
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, checks) }

        // 3. 크기·위치 칸(소수): 62.5% → 한 단계, X −120.25
        let d0 = s.history.undoDepth
        if let f = field("크기") { await typeInto(f, "62.5") }
        let afterScale = s.timeline.clip(tbV)?.effectiveTransform
        if let f = field("X") { await typeInto(f, "-120.25") }
        let afterX = s.timeline.clip(tbV)?.effectiveTransform
        check("adjust.transformFields", afterScale?.scaleMicro == 625_000 && afterX?.offsetXMilli == -120_250 && afterX?.scaleMicro == 625_000 && s.history.undoDepth == d0 + 2,
              "scale \(String(describing: afterScale)) x \(String(describing: afterX)) depth \(s.history.undoDepth - d0)")

        // 4. 칸 편집 중 단축키를 가로채지 않음 + 한글 조합(숫자 칸이라 값은 거부, 타임라인 그대로)
        let beforeKeys = s.timeline, ph = s.playhead
        if let f = field("Y") {
            w.makeFirstResponder(f); await LaneSelfTest.settle()
            if let ed = w.firstResponder as? NSTextView {
                ed.selectAll(nil)
                ed.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                let marked = ed.hasMarkedText()
                ed.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
                await LaneSelfTest.key(49, " ", [], w)          // Space → 글자(재생하지 않음)
                await LaneSelfTest.key(40, "k", [.command], w)  // ⌘K → 자르지 않음
                await LaneSelfTest.key(51, "\u{7f}", [], w)     // Delete → 글자 지움(클립을 지우지 않음)
                let typed = (w.firstResponder as? NSTextView)?.string ?? ""
                check(LaneSelfTest.direct ? "adjust.fieldTyping.direct" : "adjust.shortcutsNotIntercepted",
                      marked && KeyRouting.isTextInput(w.firstResponder) && s.timeline == beforeKeys && s.playhead == ph && !s.isPlaying && typed == "한",
                      "typed '\(typed)' marked \(marked)")
            } else { check("adjust.shortcutsNotIntercepted", false, "no field editor") }
            await LaneSelfTest.key(53, "\u{1b}", [], w)
            w.makeFirstResponder(nil); await LaneSelfTest.settle()
            check("adjust.invalidTextKeepsValue", s.timeline.clip(tbV)?.effectiveTransform == afterX, "\(String(describing: s.timeline.clip(tbV)?.effectiveTransform))")
        }

        // 5. 대상 레인: 영상 → V3, 연결된 소리 → A3(팝업 단추)
        func popups() -> [NSPopUpButton] { leftViews(NSPopUpButton.self).sorted { frameInWindow($0).maxY > frameInWindow($1).maxY } }
        func choose(_ p: NSPopUpButton?, prefix: String) async -> Bool {
            guard let p, let i = p.itemArray.firstIndex(where: { $0.title.hasPrefix(prefix) }) else { return false }
            p.menu?.performActionForItem(at: i)   // 메뉴 항목 고르기와 같은 경로(SwiftUI 팝업은 항목 동작으로 값을 받음)
            await LaneSelfTest.settle(); return true
        }
        let pp = popups()
        let c1 = await choose(pp.first, prefix: "V3")
        let videoMoved = s.timeline.clip(tbV)?.lane == v3 && s.timeline.clip(tbA)?.lane == a2
        let c2 = await choose(popups().dropFirst().first, prefix: "A3")
        check("adjust.laneDestination", c1 && c2 && videoMoved && s.timeline.clip(tbA)?.lane == a3 && s.timeline.clip(tbV)?.start == 0 && s.timeline.clip(tbA)?.start == 0,
              "popups \(pp.count) items \(pp.first?.itemTitles ?? []) v \(s.timeline.laneLabel(s.timeline.clip(tbV)?.lane ?? UUID())) a \(s.timeline.laneLabel(s.timeline.clip(tbA)?.lane ?? UUID()))")

        // 6. 소리(2026-10-11 범위 분리): WAV 클립(A2) → "클립 음소거"·"클립 음량"은 이 클립만(레인 그대로), 레인 칸은 보이지 않음.
        //    레인 머리(A2) → "레인 음소거"·"레인 음량"은 A2 레인만.
        s.select(wavC); await LaneSelfTest.settle()
        // 앞 선택(TB, 연결된 소리 A3)의 체크 상자를 SwiftUI가 다시 쓰므로, 패널이 WAV 레인(A2)으로 바뀐 뒤에 누른다
        _ = await LaneSelfTest.waitUntil(3) { popups().first?.titleOfSelectedItem == "A2 · 오디오" && popups().count == 1 }
        await LaneSelfTest.settle()
        /// SwiftUI 체크 상자는 NSButton 제목·접근성 라벨이 비어 있어(관찰) 이름으로 찾지 못한다: 소리 묶음의 유일한 체크 상자 = 팝업이 아닌 첫 NSButton.
        /// 어느 범위의 체크 상자인지는 함께 보이는 숫자 칸("클립 음량"·"레인 음량")으로 가린다.
        func checkbox() -> NSButton? { leftViews(NSButton.self).first { !($0 is NSPopUpButton) } }
        let leftButtons = leftViews(NSButton.self).map { "'\($0.title)' ax '\($0.accessibilityLabel() ?? "")' \(type(of: $0))" }
        let clipScope = field("클립 음량") != nil && field("페이드 인") != nil && field("페이드 아웃") != nil && checkbox() != nil && field("레인 음량") == nil
        check("adjust.clipSelectionShowsClipScope", clipScope, "buttons \(leftButtons)")
        let dM = s.history.undoDepth, lanesBefore = s.timeline.lanes, othersBefore = s.timeline.audioClips.filter { $0.id != wavC }
        /// 실제 클릭(누름·뗌을 한꺼번에 큐에 넣는다: 컨트롤의 추적 루프가 바로 받는다)
        func click(_ v: NSView?) async {
            guard let v else { return }
            let r = frameInWindow(v), p = NSPoint(x: r.midX, y: r.midY)
            if LaneSelfTest.direct { _ = v.accessibilityPerformPress() } else {   // 직접 경로: 접근성 누르기 동작(앱이 앞에 오지 못할 때)
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { await TransformPerfSelfTest.post(t, p, w) }
            }
            await LaneSelfTest.settle()
        }
        let mute = checkbox()
        await click(mute)
        check("adjust.clipMuteOnlyThisClip", mute != nil && s.timeline.clip(wavC)?.effectiveAudio.muted == true && s.timeline.lanes == lanesBefore
              && s.timeline.audioClips.filter { $0.id != wavC } == othersBefore && s.history.undoDepth == dM + 1,
              "muted \(s.timeline.clip(wavC)?.effectiveAudio.muted ?? false) lanes same \(s.timeline.lanes == lanesBefore) depth \(s.history.undoDepth - dM)")
        await click(checkbox())
        let dV = s.history.undoDepth
        if let f = field("클립 음량") { await typeInto(f, "45") }
        check("adjust.clipVolumeOnlyThisClip", s.timeline.clip(wavC)?.effectiveAudio.volumePercent == 45 && s.timeline.lanes == lanesBefore
              && s.timeline.audioClips.filter { $0.id != wavC } == othersBefore && s.history.undoDepth == dV + 1,
              "clip \(s.timeline.clip(wavC)?.effectiveAudio.volumePercent ?? -1)% depth \(s.history.undoDepth - dV)")
        w.makeFirstResponder(nil)
        s.selectLane(a2); await LaneSelfTest.settle()
        let laneScope = field("레인 음량") != nil && checkbox() != nil && field("클립 음량") == nil && field("페이드 인") == nil
        let dL = s.history.undoDepth, clipsBefore = s.timeline.audioClips
        if let f = field("레인 음량") { await typeInto(f, "45") }
        let laneButtons = leftViews(NSButton.self).map { "'\($0.title)' ax '\($0.accessibilityLabel() ?? "")'" }
        check("adjust.laneHeaderShowsLaneScope", laneScope && s.timeline.laneInfo(a2)?.volumePercent == 45 && s.timeline.laneInfo(Lane.audioID)?.volumePercent == 100
              && s.timeline.laneInfo(a3)?.volumePercent == 100 && s.timeline.audioClips == clipsBefore && s.history.undoDepth == dL + 1,
              "scope \(laneScope) A2 \(s.timeline.laneInfo(a2)?.volumePercent ?? -1)% depth \(s.history.undoDepth - dL) buttons \(laneButtons)")
        w.makeFirstResponder(nil)

        // 7. 레인 설정: A2 레인 머리 → 이름 칸 한글 조합 → Return 한 단계, 편집 중 단축키 가로채지 않음
        s.selectLane(a2); await LaneSelfTest.settle()
        if let f = field("레인 이름") {
            let dN = s.history.undoDepth, before = s.timeline
            w.makeFirstResponder(f); await LaneSelfTest.settle()
            if let ed = w.firstResponder as? NSTextView {
                ed.selectAll(nil)
                ed.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                ed.setMarkedText("효", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                ed.insertText("효", replacementRange: NSRange(location: NSNotFound, length: 0))
                ed.insertText("과음", replacementRange: NSRange(location: NSNotFound, length: 0))
                await LaneSelfTest.key(40, "k", [.command], w)
                let untouched = s.timeline == before
                await LaneSelfTest.key(36, "\r", [], w)
                check("adjust.laneRenameKorean", untouched && s.timeline.laneInfo(a2)?.name == "효과음" && s.timeline.laneLabel(a2) == "A2" && s.history.undoDepth == dN + 1,
                      "name \(s.timeline.laneInfo(a2)?.name ?? "-")")
            } else { check("adjust.laneRenameKorean", false, "no field editor") }
            w.makeFirstResponder(nil)
        } else { check("adjust.laneRenameKorean", false, "no lane name field") }

        // 8. 오른쪽 클립 정보: 읽기 전용(편집 칸 없음), 메타데이터 항목
        guard await LaneSelfTest.regainFocus(w) else { return finish(folder, checks) }
        s.select(tbV); await LaneSelfTest.settle()
        let rr = rightRect()
        let editable = views(NSTextField.self, in: rr).filter(\.isEditable).count + views(NSPopUpButton.self, in: rr).count + views(NSSlider.self, in: rr).count
            + views(NSStepper.self, in: rr).count + views(NSSegmentedControl.self, in: rr).count + views(NSButton.self, in: rr).filter { $0.bezelStyle != .toolbar }.count
        // 값(독립 계산): 원본 이름·종류·해상도·프레임레이트·원본/타임라인 구간·길이·레인·연결·짝 레인·크기·위치
        let rightText = await axOnly(left: false)
        let tcf = s.settings.timecode
        let expected = ["otf-TB.mp4", "영상 클립", "1920×1080", tb.timing.label, "\(tcf(0)) – \(tcf(90))", tcf(90),
                        "V3 · 영상", "연결됨 · 동기 맞음", "A3 · 오디오", "62.5% · X -120.25 · Y 0"]
        let missing = expected.filter { !rightText.contains($0) }
        let rightDump = (views(NSTextField.self, in: rr).filter(\.isEditable).map { "TF \($0.stringValue)" } + views(NSButton.self, in: rr).map { "BTN '\($0.title)' \(type(of: $0)) \(frameInWindow($0))" }
            + views(NSPopUpButton.self, in: rr).map { _ in "POP" } + views(NSSlider.self, in: rr).map { _ in "SL" }).joined(separator: "; ")
        let axCount = axTexts(cv).count
        check("inspector.readOnly", editable == 0 && missing.isEmpty,
              "editable \(editable) missing \(missing) dump [\(rightDump)] texts \(rightText) ax \(axCount) right \(rr) cv \(cv.bounds.size)")
        s.selectLane(a2); await LaneSelfTest.settle()
        let laneEditable = views(NSTextField.self, in: rr).filter(\.isEditable).count + views(NSSlider.self, in: rr).count + views(NSButton.self, in: rr).count
        let laneTexts = await axOnly(left: false)
        check("inspector.laneReadOnly", laneEditable == 0 && laneTexts.contains("A2 · 효과음") && laneTexts.contains("음량 45%"), "editable \(laneEditable) \(laneTexts)")

        // 9. 좁은 왼쪽 패널(최소 160pt): 조정 칸이 패널 안에 들어감(가로 넘침 없음), 세로 스크롤
        let saved = L.mediaFraction
        L.mediaFraction = 0.01
        s.select(tbV); await LaneSelfTest.settle(); await LaneSelfTest.settle()
        let lr = leftRect()
        let controls: [NSView] = views(NSTextField.self, in: lr).filter(\.isEditable) + views(NSPopUpButton.self, in: lr) + views(NSButton.self, in: lr) + views(NSStepper.self, in: lr) + views(NSSegmentedControl.self, in: lr)
        let overflow = controls.filter { frameInWindow($0).maxX > lr.maxX + 0.5 || frameInWindow($0).minX < lr.minX - 0.5 }
        let scroll = views(NSScrollView.self, in: lr).first { $0.hasVerticalScroller || $0.verticalScroller != nil }
        check("layout.narrowLeftFits", (split()?.media ?? 0) <= EditorLayout.minMedia + 0.5 && !controls.isEmpty && overflow.isEmpty && scroll != nil,
              "width \(split()?.media ?? 0) controls \(controls.count) overflow \(overflow.map { "\(type(of: $0)) \(frameInWindow($0))" })")
        L.mediaFraction = saved; await LaneSelfTest.settle()

        // 10. 접기·펼치기: 탭 유지, 프리뷰 폭은 접기 전과 같음
        let previewBefore = split()?.preview ?? 0
        L.toggleMedia(); await LaneSelfTest.settle()
        let collapsedPreview = split()?.preview ?? 0
        L.toggleMedia(); await LaneSelfTest.settle()
        check("layout.collapseKeepsTabAndPreview", L.leftTab == .adjust && collapsedPreview > previewBefore && abs((split()?.preview ?? 0) - previewBefore) < 0.5,
              "preview \(previewBefore) collapsed \(collapsedPreview) after \(split()?.preview ?? 0)")
        _ = tb; _ = a3
        finish(folder, checks)
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: LaneSelfTest.direct ? "앱을 활성화할 수 없어 키는 같은 저장소 동작·텍스트 칸 명령으로 보냄(KeyRouting 경로 검사 안 함)" : "합성 이벤트를 앱 이벤트 큐로 보냄")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("panel-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
