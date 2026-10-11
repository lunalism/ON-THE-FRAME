#if DEBUG
import AppKit
import AVFoundation
import OnTheFrameEngine

/// 소리 클립 음량·음소거·페이드 자체 검사(2026-10-11, Debug 전용). `open -n -W -a OnTheFrame.app <폴더> --args -OTFClipAudioTest`.
/// 실제 AppKit 경로: ⌘K 자르기, 음량 슬라이더 끌기(놓기 한 단계·끌기 중 Esc), 타임라인 페이드 손잡이 끌기(놓기 한 단계·Esc), 페이드 초 칸,
/// 칸 편집 중 한글 조합·단축키, 연결된 쌍의 소리, 레인 머리 범위, 실행 취소·다시 실행, 프리뷰 오디오 믹스, 저장·다시 열기. 결과는 <폴더>/clipaudio-result.json.
/// 기대 진폭은 손으로 쓴 식(원본 진폭 0.2 × 클립 음량 × 선형 페이드)에서 계산한다. 합성 이벤트 검사이며 실제 키보드·입력기 확인이 아니다.
@MainActor
enum ClipAudioSelfTest {
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
        L.leftTab = .adjust
        s.importFiles(["aud-steady48s.wav", "otf-TB.mp4"].map { src.appendingPathComponent($0) })
        _ = await LaneSelfTest.waitUntil(30) { s.importing == 0 && s.assets.count == 2 }
        let by = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.name, $0) })
        guard let st = by["aud-steady48s.wav"], let tb = by["otf-TB.mp4"] else { return finish(folder, [Check(name: "setup.import", pass: false, detail: "")]) }
        s.addToTimeline(st.id)                                   // A1 [0,180)
        s.placeMedia(tb.id, atFrame: 200, lane: Lane.videoID)    // V1·A1 [200,290)
        guard let whole = s.timeline.clips(inLane: Lane.audioID).first(where: { $0.mediaID == st.id })?.id,
              let tbV = s.timeline.clips(inLane: Lane.videoID).first?.id, let tbA = s.timeline.partner(of: tbV)?.id,
              let tv = LaneSelfTest.find(TimelineNSView.self, cv) else { return finish(folder, [Check(name: "setup.timeline", pass: false, detail: "")]) }
        s.timelineZoom = 2
        await LaneSelfTest.settle()

        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        func frameInWindow(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }
        func leftRect() -> NSRect { NSRect(x: 0, y: 0, width: L.lastSplit?.media ?? 0, height: cv.bounds.height) }
        func inLeft<T: NSView>(_ t: T.Type) -> [T] {
            all(cv).compactMap { $0 as? T }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil && leftRect().contains(NSPoint(x: frameInWindow($0).midX, y: frameInWindow($0).midY)) }
        }
        func field(_ placeholder: String) -> NSTextField? { inLeft(NSTextField.self).first { $0.placeholderString == placeholder && $0.isEditable } }
        func slider(_ label: String) -> GainSliderView? { inLeft(GainSliderView.self).first { $0.accessibilityLabel() == label } }
        func typeInto(_ f: NSTextField, _ text: String) async {
            w.makeFirstResponder(f); await LaneSelfTest.settle()
            if let ed = w.firstResponder as? NSTextView { ed.selectAll(nil); ed.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            await LaneSelfTest.key(36, "\r", [], w)
            w.makeFirstResponder(nil); await LaneSelfTest.settle()
        }
        func drag(_ from: NSPoint, _ to: NSPoint, escBeforeUp: Bool = false) async {
            await LaneSelfTest.mouse(.leftMouseDown, from, w)
            for k in 1...8 {
                let p = NSPoint(x: from.x + (to.x - from.x) * CGFloat(k) / 8, y: from.y + (to.y - from.y) * CGFloat(k) / 8)
                await LaneSelfTest.mouse(.leftMouseDragged, p, w)
            }
            if escBeforeUp { await LaneSelfTest.key(53, "\u{1b}", [], w) }
            await LaneSelfTest.mouse(.leftMouseUp, to, w)
        }
        func audio(_ id: UUID) -> ClipAudio { s.timeline.clip(id)?.effectiveAudio ?? .default }

        // 1. ⌘K로 자르기(재생 헤드 90): 두 조각, 기본값 그대로
        s.select(whole); s.seek(to: 90)
        _ = await LaneSelfTest.regainFocus(w)
        w.makeFirstResponder(tv)
        await LaneSelfTest.key(40, "k", [.command], w)
        let pieces = s.timeline.clips(inLane: Lane.audioID).filter { $0.mediaID == st.id }.sorted { $0.start < $1.start }
        check("split.twoPieces", pieces.count == 2 && pieces.map(\.start) == [0, 90] && pieces.allSatisfy { $0.audio == nil }, "\(pieces.map { [$0.start, $0.length] })")
        guard pieces.count == 2 else { return finish(folder, checks) }
        let left = pieces[0].id, right = pieces[1].id
        s.select(right); await LaneSelfTest.settle()
        let states0 = s.timeline

        // 2. 클립 음량 슬라이더: 끌다가 Esc → 그대로(기록 없음), 끌고 놓기 → 이 조각만 한 단계
        guard let sl = slider("클립 음량") else { return finish(folder, checks + [Check(name: "slider.present", pass: false, detail: "")]) }
        let sr = frameInWindow(sl)
        let p100 = NSPoint(x: sr.maxX - 6, y: sr.midY), p50 = NSPoint(x: sr.minX + 6 + (sr.width - 12) * 0.5, y: sr.midY)
        let d0 = s.history.undoDepth
        await drag(p100, p50, escBeforeUp: true)
        check("slider.escRestores", s.timeline == states0 && s.history.undoDepth == d0 && sl.value == 100, "value \(sl.value) depth \(s.history.undoDepth - d0)")
        await drag(p100, p50)
        let expectVol = sl.value(atX: sl.convert(p50, from: nil).x)
        check("slider.oneStepThisPieceOnly", audio(right).volumePercent == expectVol && expectVol == 50 && s.timeline.clip(left) == states0.clip(left)
              && s.timeline.clip(tbA) == states0.clip(tbA) && s.timeline.lanes == states0.lanes && s.history.undoDepth == d0 + 1,
              "right \(audio(right).volumePercent) expect \(expectVol) depth \(s.history.undoDepth - d0)")
        let states1 = s.timeline

        // 3. 페이드 초 칸: 페이드 인 1.5초(45프레임), 페이드 아웃 0.5초(15프레임), 각각 한 단계
        if let f = field("페이드 인") { await typeInto(f, "1.5") }
        if let f = field("페이드 아웃") { await typeInto(f, "0.5") }
        check("fields.fadeSeconds", audio(right).fadeIn == .init(length: 45) && audio(right).fadeOut == .init(length: 15) && s.history.undoDepth == d0 + 3
              && s.timeline.clip(left) == states0.clip(left), "in \(audio(right).fadeIn) out \(audio(right).fadeOut) depth \(s.history.undoDepth - d0)")
        let states2 = s.timeline

        // 4. 칸 편집 중 한글 조합·단축키(Space·⌘K·Delete)는 칸이 받는다(타임라인 그대로)
        if let f = field("페이드 아웃") {
            w.makeFirstResponder(f); await LaneSelfTest.settle()
            if let ed = w.firstResponder as? NSTextView {
                ed.selectAll(nil)
                ed.setMarkedText("ㅍ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                let marked = ed.hasMarkedText()
                ed.insertText("페", replacementRange: NSRange(location: NSNotFound, length: 0))
                await LaneSelfTest.key(49, " ", [], w); await LaneSelfTest.key(40, "k", [.command], w); await LaneSelfTest.key(51, "\u{7f}", [], w)
                check(LaneSelfTest.direct ? "fields.koreanTyping.direct" : "fields.koreanAndShortcutsNotIntercepted",
                      marked && s.timeline == states2 && !s.isPlaying && KeyRouting.isTextInput(w.firstResponder), "typed '\((w.firstResponder as? NSTextView)?.string ?? "")'")
            } else { check("fields.koreanAndShortcutsNotIntercepted", false, "no field editor") }
            await LaneSelfTest.key(53, "\u{1b}", [], w)
            w.makeFirstResponder(nil); await LaneSelfTest.settle()
            check("fields.invalidTextKeepsValue", s.timeline == states2, "")
        }

        // 5. 타임라인 페이드 손잡이(오른쪽 조각의 페이드 아웃): 끌다가 Esc → 그대로, 왼쪽으로 30프레임 끌고 놓기 → 한 단계
        _ = await LaneSelfTest.regainFocus(w)
        func handlePoint(_ e: ProjectStore.FadeEdge) -> NSPoint? {
            guard let c = s.timeline.clip(right), let lr = tv.laneRect(c.lane) else { return nil }
            let h = tv.fadeHandleRect(c, e, NSRect(x: tv.x(c.start), y: lr.minY, width: CGFloat(c.length) * tv.pixelsPerFrame, height: lr.height))
            tv.scrollToVisible(h.insetBy(dx: -80, dy: -20))
            return tv.convert(NSPoint(x: h.midX, y: h.midY), to: nil)
        }
        let dH = s.history.undoDepth
        if let hp = handlePoint(.fadeOut) {
            let to = NSPoint(x: hp.x - 30 * tv.pixelsPerFrame, y: hp.y)
            await drag(hp, to, escBeforeUp: true)
            check("handle.escRestores", s.timeline == states2 && s.history.undoDepth == dH, "out \(audio(right).fadeOut)")
            await drag(hp, to)
            check("handle.oneStepThisPieceOnly", audio(right).fadeOut == .init(length: 45) && audio(right).fadeIn == .init(length: 45) && s.history.undoDepth == dH + 1
                  && s.timeline.clip(left) == states0.clip(left), "out \(audio(right).fadeOut) depth \(s.history.undoDepth - dH)")
            // 겹치지 않게 제한: 페이드 인 손잡이를 끝까지 끌어도 90 − 45 = 45프레임
            if let hi = handlePoint(.fadeIn) {
                await drag(hi, NSPoint(x: hi.x + 200 * tv.pixelsPerFrame, y: hi.y))
                check("handle.clampedNoOverlap", audio(right).fadeIn == .init(length: 45) && audio(right).fadeOut == .init(length: 45), "in \(audio(right).fadeIn)")
            }
        } else { check("handle.present", false, "") }
        let states3 = s.timeline

        // 6. 연결된 쌍: 영상 클립을 골라도 그 소리 클립에 적용(영상·다른 클립 그대로)
        s.select(tbV); await LaneSelfTest.settle()
        if let f = field("클립 음량") { await typeInto(f, "30") }
        check("linked.adjustsAudioMember", audio(tbA).volumePercent == 30 && s.timeline.clip(tbV)?.audio == nil && s.timeline.clip(right) == states3.clip(right)
              && s.timeline.clip(left) == states3.clip(left), "tbA \(audio(tbA).volumePercent)")
        // 7. 레인 머리: 레인 전체 칸만(클립 칸 없음)
        s.selectLane(Lane.audioID); await LaneSelfTest.settle()
        check("scope.laneHeader", field("레인 음량") != nil && field("클립 음량") == nil && field("페이드 인") == nil && slider("레인 음량") != nil && slider("클립 음량") == nil)
        s.select(right); await LaneSelfTest.settle()
        check("scope.clip", field("클립 음량") != nil && field("레인 음량") == nil && slider("클립 음량") != nil)
        // 화면 확인용 창 그림(판정 아님): 오른쪽 조각 선택 — 페이드 경사·손잡이·클립 조정 칸
        if let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
            cv.cacheDisplay(in: cv.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("clipaudio-window.png"))
        }
        let states4 = s.timeline

        // 8. 실행 취소·다시 실행: 단계마다 정확히 같은 상태
        var undone: [Timeline] = []
        for _ in 0..<5 { s.undo(); undone.append(s.timeline) }
        // 되돌리는 순서: 연결 음량 → 손잡이(페이드 아웃) → 페이드 아웃 칸 → 페이드 인 칸 → 슬라이더. 바꾼 것이 없는 끌기(제한된 페이드 인)는 단계가 아니다.
        let undoOK = undone[0] == states3 && undone[1] == states2 && undone[3] == states1 && undone[4] == states0
        for _ in 0..<5 { s.redo() }
        check("history.undoRedoExact", undoOK && s.timeline == states4, "undo \(zip(undone, [states3, states2, nil, states1, states0]).map { $1 == nil ? "-" : ($0 == $1! ? "ok" : "x") }) redo \(s.timeline == states4)")

        // 9. 프리뷰 오디오 믹스(프리뷰 항목과 같은 composition·믹스): 손 계산 진폭
        _ = await LaneSelfTest.waitUntil(15) { s.appliedGeneration == s.generation && s.currentPlan != nil }
        if let plan = s.currentPlan {
            let x = (try? await readMix(plan)) ?? []
            func amp(_ f: Double) -> Double {
                let n = Int(f * 1_600), lo = max(0, n - 24), hi = min(x.count, n + 24)
                guard hi > lo else { return -1 }
                var i = 0.0, q = 0.0
                for k in lo..<hi { let ph = 2 * Double.pi * 1_000 * Double(k) / 48_000; i += Double(x[k]) * cos(ph); q += Double(x[k]) * sin(ph) }
                return 2 * (i * i + q * q).squareRoot() / Double(hi - lo)
            }
            // 손 계산: 왼쪽 [0,90) 0.2, 오른쪽 [90,180) 0.2 × 0.5 × min(1,(f−90)/45) × min(1,(180−f)/45)
            let probes: [(Double, Double)] = [(45, 0.2), (89.5, 0.2), (90.5, 0.1 * 0.5 / 45), (112.5, 0.05), (135, 0.1), (157.5, 0.05), (179.5, 0.1 * 0.5 / 45)]
            let bad = probes.filter { abs(amp($0.0) - $0.1) > 0.003 }
            check("preview.mixFollowsSettings", !x.isEmpty && bad.isEmpty, bad.map { String(format: "f%.1f %.4f vs %.4f", $0.0, amp($0.0), $0.1) }.joined(separator: ", "))
        } else { check("preview.mixFollowsSettings", false, "no plan") }

        // 10. 저장·다시 열기: 모든 클립 설정 그대로(형식 5)
        let p = folder.appendingPathComponent("clipaudio.ontheframe")
        let saved = s.writeProject(to: p)
        let ver = (try? Data(contentsOf: p)).flatMap { try? ProjectFile.decode($0).document.version }
        s.resetProject(); await LaneSelfTest.settle()
        let opened = await s.openProject(at: p)
        let same = [left, right, tbA].allSatisfy { s.timeline.clip($0)?.audio == states4.clip($0)?.audio } && s.timeline.lanes == states4.lanes
        check("project.saveReopen", saved && opened && ver == 5 && same, "saved \(saved) opened \(opened) version \(ver ?? -1)")
        finish(folder, checks)
    }

    /// 프리뷰 항목과 같은 입력(composition의 모든 소리 트랙 + 오디오 믹스)을 48 kHz 스테레오로 섞어 읽은 왼쪽 채널
    static func readMix(_ p: PlannedComposition) async throws -> [Float] {
        let r = try AVAssetReader(asset: p.composition)
        let o = AVAssetReaderAudioMixOutput(audioTracks: try await p.composition.loadTracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        o.audioMix = p.audioMix
        r.add(o)
        guard r.startReading() else { return [] }
        var out: [Float] = []
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            var i = 0
            while i + 1 < n { out.append(chunk[i]); i += 2 }
        }
        return out
    }

    static func finish(_ folder: URL, _ checks: [Check]) {
        let checks = checks + [Check(name: LaneSelfTest.direct ? "mode.direct" : "mode.events", pass: true,
                                     detail: LaneSelfTest.direct ? "앱을 활성화할 수 없어 마우스는 보기에 직접, 키는 같은 저장소 동작·텍스트 칸 명령으로 보냄(KeyRouting 경로 검사 안 함)" : "합성 이벤트를 앱 이벤트 큐로 보냄")]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(checks) { try? d.write(to: folder.appendingPathComponent("clipaudio-result.json")) }
        ProjectStore.shared.discardConfirmedForTest()
        NSApp.terminate(nil)
    }
}
#endif
