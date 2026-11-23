#if DEBUG
import AppKit
import ImageIO
import OnTheFrameEngine

/// SpectrumPublicSelfTest 9절: 내보내기 사전 차단(영상 프로젝트 + 스펙트럼, 4개 검사)과 이미지 프로젝트의 사전 차단(별도 진입점, 4개 검사).
/// SP-PUBLIC-UX-IMPLEMENT-04·SP-PUBLIC-VALIDATE-05(2026-11-23). 절마다 작은 함수 하나(컴파일 메모리 — SpectrumPublicSelfTest.swift 머리글).
/// panelHits: 저장 패널을 띄우려 할 때만 올라가는 시험 연결점(exportPanelOverrideForTest)의 횟수. 실제 패널은 띄우지 않는다.
extension SpectrumPublicSelfTest {
    /// 9a. 단추·메뉴·⌘E가 부르는 presentExportPanel이 대상 고르기(저장 패널) 전에 이유를 알린다
    static func checkExportPreflightDirect(_ c: Context, _ panelHits: Counter) async {
        let s = c.s
        let reason = s.spectrumExportBlockReason
        let blockedState = !s.timeline.spectra.isEmpty && !s.canExport && reason != nil && s.exportBlockReason == reason
        s.presentExportPanel()
        let shown = await c.waitAlert()
        let title = s.alert?.title ?? "", message = s.alert?.message ?? ""
        await c.press(0)
        let explained = shown && title == "내보낼 수 없습니다" && message.contains("스펙트럼") && message.contains("삭제")
        let notStarted = panelHits.n == 0 && s.exportPhase == .idle && s.pendingOps.isEmpty
        c.check("export.preflightBeforePicker", blockedState && explained && notStarted, "title '\(title)' hits \(panelHits.n)")
    }

    /// 9b. 메뉴 "내보내기…"(꺼지지 않고 설명을 보임)와 ⌘E
    static func checkExportPreflightMenuAndShortcut(_ c: Context, _ panelHits: Counter) async {
        let s = c.s
        let menuRan = LaneSelfTest.menuItem("내보내기…")
        let shownMenu = await c.waitAlert()
        let menuMessage = s.alert?.message ?? ""
        await c.press(0)
        var keyOK = true, keyDetail = "직접 경로(키 미검사)"
        if !LaneSelfTest.direct {
            _ = await LaneSelfTest.regainFocus(c.w)
            c.w.makeFirstResponder(c.tv)
            await LaneSelfTest.key(14, "e", [.command], c.w)
            let shownKey = await c.waitAlert()
            let keyMessage = s.alert?.message ?? ""
            await c.press(0)
            keyOK = shownKey && keyMessage.contains("스펙트럼")
            keyDetail = "key \(shownKey)"
        }
        let menuOK = menuRan && shownMenu && menuMessage.contains("스펙트럼")
        c.check("export.preflightMenuAndShortcut", menuOK && keyOK && panelHits.n == 0, "menu \(menuRan)/\(shownMenu) \(keyDetail) hits \(panelHits.n)")
    }

    /// 9c. 엔진 거부는 마지막 방어선으로 그대로: 패널을 건너뛰고 startExport를 직접 불러도 대상 파일을 만들거나 바꾸지 않는다
    static func checkExportEngineGuard(_ c: Context) async {
        let s = c.s
        let dest = c.out.appendingPathComponent("public-refused.mp4"), keepBytes = Data("keep".utf8)
        try? keepBytes.write(to: dest)
        s.startExport(.fromSavePanel(dest))
        _ = await LaneSelfTest.waitUntil(60) { s.exportPhase == .idle && s.alerts.isShowing }
        let title = s.alert?.title ?? "", message = s.alert?.message ?? ""
        await dismiss()
        await LaneSelfTest.settle()
        let refused = title == "내보내기 실패" && message.contains("스펙트럼")
        c.check("export.engineGuardPreserved", refused && c.bytes(dest) == keepBytes, "'\(title)' \(message.prefix(80))")
    }

    /// 9d. 스펙트럼이 없으면 기존 그대로: 이유 없음, 패널로 감(실제 패널은 띄우지 않고 기록만). 끝나면 스펙트럼이 있던 상태로 되돌린다.
    static func checkExportWithoutSpectrum(_ c: Context, _ panelHits: Counter) async {
        let s = c.s
        let withSpectra = s.timeline
        for sp in s.timeline.spectra { s.select(sp.id); s.deleteSelection() }
        await LaneSelfTest.settle()
        let hitsBefore = panelHits.n
        s.presentExportPanel()
        await LaneSelfTest.settle()
        let noReason = s.timeline.spectra.isEmpty && s.spectrumExportBlockReason == nil && s.exportBlockReason == nil && s.canExport
        let wentToPanel = !s.alerts.isShowing && panelHits.n == hitsBefore + 1
        c.check("export.noSpectrumUnaffected", noReason && wentToPanel, "block \(s.exportBlockReason ?? "nil") hits \(panelHits.n - hitsBefore) alert \(s.alert?.title ?? "-")")
        await dismiss()
        while s.timeline != withSpectra && s.history.canUndo { s.undo() }
    }

    // MARK: 이미지 프로젝트

    /// 이미지 프로젝트의 내보내기 사전 차단(SP-PUBLIC-VALIDATE-05, 2026-11-23). 이미지 가져오기 gate(OTF_IMAGE_IMPORT 빌드 + `-OTFEnableImageImport`)가 필요하다:
    /// `open -n -W -a OnTheFrame.app <폴더> --args -OTFEnableImageImport -OTFSpectrumImageExportGuardTest`. 생성 PNG(실행 폴더 안)와 생성 fixture(<폴더>/sources/aud-wav48s.wav)만 쓴다.
    /// 이미지 + 소리 + 스펙트럼 프로젝트에서 presentExportPanel(단추·메뉴·⌘E의 경로)과 startExport가 대상 파일을 고르거나 건드리기 전에 막는지 본다.
    /// 성공 경로는 `expectedImageChecks` 4개 + 실행 방식 줄 1개 = 5줄. 결과는 <폴더>/spectrum-image-export-guard-result.json.
    static func runImageExportGuard(folder: URL) async {
        let s = ProjectStore.shared
        let file = "spectrum-image-export-guard-result.json"
        var checks: [Check] = []
        NSApp.activate()
        _ = await LaneSelfTest.waitUntil(5) { s.editorWindow != nil }
        if s.editorWindow == nil {
            checks.append(Check(name: "setup.window", pass: false, detail: ""))
        } else if !ProjectStore.imageImportEnabled {
            checks.append(Check(name: "setup.imageGate", pass: false, detail: "OTF_IMAGE_IMPORT 빌드와 -OTFEnableImageImport가 필요"))
        } else if let audio = await imageGuardProject(s, folder: folder, into: &checks) {
            let reasonBefore = s.exportBlockReason
            checks.append(await imageGuardCreate(s, audio: audio, reasonBefore: reasonBefore))
            checks.append(await imageGuardPreflight(s))
            checks.append(await imageGuardStartExport(s, folder: folder))
            checks.append(await imageGuardAfterDelete(s, reasonBefore: reasonBefore))
        }
        s.exportPanelOverrideForTest = nil
        finish(folder, checks, expected: expectedImageChecks, file: file)
    }

    /// 생성 PNG(64×36, 한 색)와 그 보안 범위 URL(ImageRelinkSelfTest와 같은 방식)
    private static func imageGuardPNG(folder: URL) -> URL? {
        let png = folder.appendingPathComponent("guard-image.png")
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        guard let image = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, image, nil)
        guard CGImageDestinationFinalize(d),
              let data = try? png.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// 이미지 + 소리 프로젝트를 만든다. 실패하면 준비 실패 줄을 적고 nil.
    private static func imageGuardProject(_ s: ProjectStore, folder: URL, into checks: inout [Check]) async -> Clip? {
        guard let imageURL = imageGuardPNG(folder: folder) else {
            checks.append(Check(name: "setup.image", pass: false, detail: "")); return nil
        }
        s.resetProject()
        let imported = await s.importStillImage(at: imageURL)
        let imageID = ProjectPersistence.references(s.timeline).first { $0.kind == .stillImage }?.id
        if let imageID { s.addToTimeline(imageID) }
        s.importFiles([folder.appendingPathComponent("sources/aud-wav48s.wav")])
        _ = await LaneSelfTest.waitUntil(30) { s.assets.contains { $0.name == "aud-wav48s.wav" } && s.importing == 0 }
        _ = await LaneSelfTest.waitUntil(5) { s.importDone == nil }
        if let wav = s.assets.first(where: { $0.name == "aud-wav48s.wav" }) { s.addToTimeline(wav.id) }
        await dismiss()
        await LaneSelfTest.settle()
        let hasImages = InternalImagePreview.containsImages(s.timeline)
        guard imported, hasImages, let audio = s.timeline.audioClips.first else {
            checks.append(Check(name: "setup.imageProject", pass: false,
                                detail: "imported \(imported) images \(hasImages) audio \(s.timeline.audioClips.count) \(s.statusMessage ?? "")"))
            return nil
        }
        return audio
    }

    private static func imageGuardCreate(_ s: ProjectStore, audio: Clip, reasonBefore: String?) async -> Check {
        s.addSpectrum(fromAudioClip: audio.id, session: s.projectSession)
        await LaneSelfTest.settle()
        let made = s.timeline.spectra.count == 1 && s.timeline.spectra.first?.sourceKey == audio.lineageKey
        return Check(name: "image.spectrumCreated", pass: made && InternalImagePreview.containsImages(s.timeline),
                     detail: "spectra \(s.timeline.spectra.count) reasonBefore \(reasonBefore ?? "nil")")
    }

    /// 대상 고르기 전 차단: 패널을 띄우려 하면 기록만 하는 연결점이 한 번도 불리지 않는다
    private static func imageGuardPreflight(_ s: ProjectStore) async -> Check {
        let panelHits = Counter()
        s.exportPanelOverrideForTest = { panelHits.n += 1 }
        s.presentExportPanel()
        let shown = await LaneSelfTest.waitUntil(5) { s.alerts.isShowing }
        let title = s.alert?.title ?? "", message = s.alert?.message ?? ""
        await dismiss()
        await LaneSelfTest.settle()
        let explained = shown && title == "내보낼 수 없습니다" && message == s.spectrumExportBlockReason && message.contains("스펙트럼")
        let notStarted = panelHits.n == 0 && !s.canExport && s.exportPhase == .idle
        return Check(name: "image.preflightBeforePicker", pass: explained && notStarted, detail: "'\(title)' hits \(panelHits.n)")
    }

    /// 패널을 건너뛴 startExport도 이미지 프로젝트는 시작 전에 막는다(대상 파일 그대로, 내보내기 시작 없음)
    private static func imageGuardStartExport(_ s: ProjectStore, folder: URL) async -> Check {
        let dest = folder.appendingPathComponent("guard-refused.mp4"), keep = Data("keep".utf8)
        try? keep.write(to: dest)
        s.startExport(.fromSavePanel(dest))
        let shown = await LaneSelfTest.waitUntil(10) { s.alerts.isShowing }
        let title = s.alert?.title ?? "", message = s.alert?.message ?? ""
        await dismiss()
        await LaneSelfTest.settle()
        let refused = shown && message.contains("스펙트럼") && s.exportPhase == .idle && s.pendingOps.isEmpty
        return Check(name: "image.startExportRefusedKeepsFile", pass: refused && (try? Data(contentsOf: dest)) == keep, detail: "'\(title)' \(message.prefix(60))")
    }

    /// 스펙트럼을 지우면 스펙트럼 사유가 사라진다(남는 사유가 있으면 이미지 프로젝트의 기존 판정 그대로)
    private static func imageGuardAfterDelete(_ s: ProjectStore, reasonBefore: String?) async -> Check {
        for sp in s.timeline.spectra { s.select(sp.id); s.deleteSelection() }
        await LaneSelfTest.settle()
        let cleared = s.timeline.spectra.isEmpty && s.spectrumExportBlockReason == nil && s.exportBlockReason == reasonBefore
        return Check(name: "image.noSpectrumReasonAfterDelete", pass: cleared, detail: "after \(s.exportBlockReason ?? "nil") before \(reasonBefore ?? "nil")")
    }
}
#endif
