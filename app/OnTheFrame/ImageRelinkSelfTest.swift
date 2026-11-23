#if DEBUG
import AppKit
import CoreImage
import AVFoundation
import ImageIO
@testable import OnTheFrameEngine

/// Explicit isolated diagnostic. Native Open is cancelled, never approved automatically.
@MainActor enum ImageRelinkSelfTest {
    struct Failure: Error { let name:String }
    static func run(folder:URL) async {
        let s=ProjectStore.shared
        var checks=[String:Bool](),starts=0,stops=0
        func check(_ name:String,_ value:Bool)throws {checks[name]=value;if !value{throw Failure(name:name)}}
        func dismiss()async {
            if s.alert != nil {s.alerts.pressButton(s.alert?.cancelIndex ?? 0)}
            let end=Date().addingTimeInterval(3)
            while s.alerts.isShowing,Date()<end{try? await Task.sleep(nanoseconds:10_000_000)}
        }
        func scoped(_ u:URL)throws -> URL {
            let data=try u.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:nil,relativeTo:nil)
            var stale=false
            return try URL(resolvingBookmarkData:data,options:[.withSecurityScope],relativeTo:nil,bookmarkDataIsStale:&stale)
        }
        func image(_ ext:String,_ width:Int,_ height:Int) throws -> URL {
            let u=folder.appendingPathComponent(UUID().uuidString+"."+ext)
            let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
            c.setFillColor(CGColor(red:width == 2 ? 1:0,green:ext == "jpg" ? 1:0,blue:width == 4 && ext == "png" ? 1:0,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
            let d=CGImageDestinationCreateWithURL(u as CFURL,(ext == "png" ? "public.png":"public.jpeg") as CFString,1,nil)!
            CGImageDestinationAddImage(d,c.makeImage()!,nil)
            guard CGImageDestinationFinalize(d) else {throw Failure(name:"generate")};return try scoped(u)
        }
        var failure:String?
        do {
            try check("isolated suite",EditorLayout.shared.suiteName != nil)
            if !ProjectStore.imageImportEnabled {
                let before=s.timeline
                let ok=await s.relinkStillImage(UUID(),to:folder.appendingPathComponent("absent.png"))
                try check("runtime gate rejects mutation",!ok && s.timeline==before)
            } else {
                // Real API acquisition counts, not OS-wide scope introspection.
                s.persistenceScopeStartForTest={u in let ok=u.startAccessingSecurityScopedResource();if ok {starts += 1};return ok}
                s.persistenceScopeStopForTest={u in stops += 1;u.stopAccessingSecurityScopedResource()}
                let a=try image("png",2,3),b=try image("jpg",4,2),c=try image("png",4,2)
                let imported=await s.importStillImage(at:a)
                try check("generated import",imported)
                let id=ProjectPersistence.references(s.timeline)[0].id,projectID=s.projectID
                try check("generated import registers without placement",s.timeline.clips.isEmpty)
                s.addToTimeline(id)
                try check("generated image explicitly inserted",s.timeline.clips.first?.mediaID == id && s.timeline.clips.first?.length == 150)
                let original=s.timeline
                func captureRow(_ phase: String) async throws {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    guard let view = s.editorWindow?.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw Failure(name: phase + " editor capture")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw Failure(name: phase + " PNG encoding")
                    }
                    try png.write(to: folder.appendingPathComponent("row-" + phase + ".png"), options: .withoutOverwriting)
                }
                func relink(_ url:URL,accept:Bool=true,cancelTask:Bool=false,capturePending:Bool=false)async throws->Bool {
                    var done=false,answer=false,sawNotice=false
                    let task=Task { answer=await s.relinkStillImage(id,to:url);done=true }
                    let end=Date().addingTimeInterval(10)
                    while !done,Date()<end {
                        if s.alert?.title == "이미지 크기·방향 변경" {
                            if capturePending && !sawNotice {
                                try check("pending keeps committed missing state", s.pendingImageRelinkID == id && s.missingMedia[id] != nil)
                                try await captureRow("pending")
                            }
                            sawNotice=true
                            if cancelTask { task.cancel() } else { s.alerts.pressButton(accept ? 0:1) }
                        }
                        try await Task.sleep(nanoseconds:10_000_000)
                    }
                    if !done {task.cancel();throw Failure(name:"relink timeout")}
                    checks["notice observed when requested"] = checks["notice observed when requested"] == true || sawNotice
                    return answer
                }
                func waitForPreview(_ failed: Bool) async throws {
                    let deadline = Date().addingTimeInterval(8)
                    while Date() < deadline {
                        if failed ? s.imagePreviewError != nil : (s.imagePreviewError == nil && s.player.currentItem?.status == .readyToPlay) { return }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    throw Failure(name: "preview transition failed=\(failed)")
                }
                func previewRGB() async throws -> [Int] {
                    let ready=Date().addingTimeInterval(5)
                    while s.player.currentItem?.status != .readyToPlay,Date()<ready {try await Task.sleep(nanoseconds:10_000_000)}
                    guard let item=s.player.currentItem else {throw Failure(name:"preview item")}
                    let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                    item.add(output)
                    defer { item.remove(output) }
                    _ = await s.player.seek(to:.zero,toleranceBefore:.zero,toleranceAfter:.zero)
                    var pixel:CVPixelBuffer?
                    let refresh=Date().addingTimeInterval(3)
                    while pixel == nil,Date()<refresh {pixel=output.copyPixelBuffer(forItemTime:.zero,itemTimeForDisplay:nil);try await Task.sleep(nanoseconds:10_000_000)}
                    if let pixel {
                        CVPixelBufferLockBaseAddress(pixel,.readOnly)
                        let ptr=CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to:UInt8.self)
                        let offset=(CVPixelBufferGetHeight(pixel)/2)*CVPixelBufferGetBytesPerRow(pixel)+(CVPixelBufferGetWidth(pixel)/2)*4
                        let rgb = [Int(ptr[offset+2]), Int(ptr[offset+1]), Int(ptr[offset])]
                        CVPixelBufferUnlockBaseAddress(pixel,.readOnly)
                        return rgb
                    } else {throw Failure(name:"preview frame timeout")}
                }
                let frameContext = CIContext()
                func displayedRGB() -> [UInt8] {
                    guard let buffer = s.previewHost?.playerLayer.displayedPixelBuffer() else { return [] }
                    let image = CIImage(cvPixelBuffer: buffer)
                    var rgba = [UInt8](repeating: 0, count: 4)
                    frameContext.render(image, toBitmap: &rgba, rowBytes: 4,
                        bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                    return Array(rgba.prefix(3))
                }
                var availabilityMatches = true
                func record(_ phase: String, source: URL, missing: Bool) async throws {
                    try await waitForPreview(missing)
                    let ref = ProjectPersistence.references(s.timeline).first { $0.id == id }
                    let rgb = missing ? [] : try await previewRGB()
                    let deadline = Date().addingTimeInterval(3)
                    var displayed = displayedRGB()
                    func surfaceMatches() -> Bool {
                        if missing { return displayed.isEmpty }
                        guard displayed.count == 3 else { return false }
                        return source == a ? displayed[0] > 180 && displayed[1] < 80 : displayed[1] > 180 && displayed[0] < 80
                    }
                    while !surfaceMatches(), Date() < deadline {
                        try await Task.sleep(nanoseconds: 20_000_000)
                        displayed = displayedRGB()
                    }
                    let state: [String: Any] = ["mediaID": id.uuidString, "path": ref?.path ?? "",
                        "session": s.projectSession, "generation": s.generation,
                        "missing": s.missingMedia[id] != nil, "reason": s.missingMedia[id] ?? "",
                        "previewError": s.imagePreviewError ?? "", "centerRGB": rgb, "layerRGB": displayed,
                        "emptyPlayer": s.player.currentItem == nil]
                    try JSONSerialization.data(withJSONObject: state, options: .sortedKeys)
                        .write(to: folder.appendingPathComponent(phase + ".json"))
                    try await captureRow(phase)
                    try check(phase + " player layer", surfaceMatches())
                    try check(phase + " identity and preview", ref?.path == source.path && s.projectID == projectID &&
                        s.timeline.clips == original.clips && (missing ? s.player.currentItem == nil :
                            (source == a ? rgb[0] > 180 && rgb[1] < 80 : rgb[1] > 180 && rgb[0] < 80)))
                    availabilityMatches = availabilityMatches && (s.missingMedia[id] != nil) == missing
                }
                try await record("A-import", source: a, missing: false)
                let displaced = folder.appendingPathComponent("displaced.png")
                var boundaryMoveError: Error?
                s.imageSourceValidatedForTest = { validatedID in
                    guard validatedID == id else { return }
                    s.imageSourceValidatedForTest = nil
                    do { try FileManager.default.moveItem(at: a, to: displaced) }
                    catch { boundaryMoveError = error }
                }
                defer { s.imageSourceValidatedForTest = nil }
                s.timelineChanged()
                try await record("A-second-read-moved", source: a, missing: true)
                try check("second read publishes unavailable after validation", boundaryMoveError == nil &&
                    s.missingMedia[id] != nil && s.imagePreviewError?.contains("찾을 수 없습니다") == true)
                try FileManager.default.moveItem(at: displaced, to: a)
                s.timelineChanged()
                try await record("A-second-read-restored", source: a, missing: false)
                try FileManager.default.moveItem(at: a, to: displaced)
                s.timelineChanged()
                try await record("A-moved", source: a, missing: true)
                try await waitForPreview(true)
                try check("missing image reports preview error", s.player.currentItem == nil)
                let rejected=try await relink(b,accept:false)
                try check("notice cancel preserves project",!rejected && s.timeline==original && starts-stops==1)
                let cancelled=try await relink(b,cancelTask:true)
                try check("task cancel releases candidate",!cancelled && s.timeline==original && starts-stops==1)
                await dismiss()
                let jpeg=try await relink(b)
                try check("JPEG cross-format commit",jpeg && s.timeline.clips==original.clips && s.projectID==projectID)
                let linked=s.timeline
                let gen=s.generation
                let linkedSession = s.projectSession
                try await waitForPreview(false)
                try await record("B-linked", source: b, missing: false)
                func menu(_ title: String) throws {
                    guard let edit = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.item(withTitle: title) != nil }),
                          let item = edit.item(withTitle: title) else { throw Failure(name: "missing menu " + title) }
                    edit.update()
                    try check("enabled " + title, item.isEnabled)
                    edit.performActionForItem(at: edit.index(of: item))
                }
                // 메뉴의 실행 취소·다시 실행은 편집기가 메뉴 대상일 때만 타임라인에 적용된다(ProjectStore.menuUndo — 아니면 응답 체인으로 보낸다).
                // 앱이 비활성이면 메뉴 동작이 타임라인을 바꾸지 않으므로, 메뉴를 쓰기 전에 편집기를 대상으로 만들고 그 전제를 검사로 남긴다
                // (SP-PUBLIC-RELINK-UNDO-TRIAGE-12: 앱이 초점을 잃은 채 메뉴 실행 취소가 적용되지 않아 "undo availability"로 잘못 드러났다).
                func focusEditor() async throws {
                    NSApp.activate()
                    s.editorWindow?.makeKeyAndOrderFront(nil)
                    let end=Date().addingTimeInterval(3)
                    while !KeyRouting.menuTargetsEditor(s),Date()<end {try await Task.sleep(nanoseconds:10_000_000)}
                    try check("editor is the menu target", KeyRouting.menuTargetsEditor(s))
                }
                try await focusEditor()
                try menu("실행 취소")
                try await waitForPreview(true)
                try check("undo restores timeline and preview generation",s.timeline==original && s.generation>gen)
                try await record("A-undo", source: a, missing: true)
                let undoFile=folder.appendingPathComponent("undo.ontheframe")
                try check("undo save",s.writeProject(to:undoFile))
                let undo=try ProjectPersistence.decode(Data(contentsOf:undoFile))
                try check("undo save source",undo.media[0].path==a.path)
                s.statusMessage = "independent diagnostic status"
                try menu("다시 실행")
                try await waitForPreview(false)
                try check("redo preserves independent status and dirty state", s.statusMessage == "independent diagnostic status" && s.isDirty)
                try await record("B-redo", source: b, missing: false)
                s.applyImageAvailability(false, id: id, snapshot: original, session: s.projectSession, generation: s.generation)
                try check("old source revision cannot mark B missing", s.missingMedia[id] == nil)
                try check("moved source availability across undo and redo", availabilityMatches)
                guard let window = s.editorWindow else { throw Failure(name: "editor window") }
                for _ in 0..<2 {
                    await ShortcutSelfTest.key(6, "z", [.command], window)
                    try await waitForPreview(true)
                    try check("keyboard undo returns to saved missing source", s.timeline == original && !s.isDirty)
                    await ShortcutSelfTest.key(6, "Z", [.command, .shift], window)
                    try await waitForPreview(false)
                    try check("keyboard redo protects unsaved relink", s.timeline == linked && !s.canCloseWithoutPrompt)
                }
                try FileManager.default.moveItem(at: displaced, to: a)
                try await focusEditor()
                try menu("실행 취소")
                try await record("A-returned", source: a, missing: false)
                try check("returned source revalidated", availabilityMatches)
                s.applyImageAvailability(false, id: id, snapshot: original, session: linkedSession, generation: gen)
                try check("late generation cannot mark returned source missing", s.missingMedia[id] == nil)
                try await focusEditor()
                try await focusEditor()
                try menu("다시 실행")
                try check("redo restores timeline",s.timeline==linked)
                let redoFile=folder.appendingPathComponent("redo.ontheframe")
                try check("redo save",s.writeProject(to:redoFile))
                let redo=try ProjectPersistence.decode(Data(contentsOf:redoFile))
                try check("redo save source",redo.media[0].path==b.path)
                let png=try await relink(c)
                try check("PNG same-dimension commit",png && s.timeline.clips==original.clips)
                let rgb = try await previewRGB()
                try check("preview uses new blue source", rgb[2] > 180 && rgb[0] < 80)
                let exported=folder.appendingPathComponent("relinked.mp4")
                s.startExport(.fromSavePanel(exported))
                let finish=Date().addingTimeInterval(30)
                while s.exportPhase != .idle,Date()<finish {try await Task.sleep(nanoseconds:10_000_000)}
                try check("bounded relink export completes",s.exportPhase == .idle && s.alert?.title == "내보내기 완료")
                let generator=AVAssetImageGenerator(asset:AVURLAsset(url:exported))
                let frame=try generator.copyCGImage(at:.zero,actualTime:nil)
                let bitmap=NSBitmapImageRep(cgImage:frame)
                let color=bitmap.colorAt(x:frame.width/2,y:frame.height/2)!.usingColorSpace(.deviceRGB)!
                try check("export uses new blue source",color.blueComponent>0.7 && color.redComponent<0.3)
                // Completion sheets have Close at index1, unlike error alerts.
                s.alerts.pressButton(1)
                while s.alerts.isShowing {try await Task.sleep(nanoseconds:10_000_000)}
                let stable=s.timeline,owned=starts-stops
                let bad=folder.appendingPathComponent("corrupt.png");try Data("corrupt".utf8).write(to:bad,options:.withoutOverwriting)
                let invalid=await s.relinkStillImage(id,to:try scoped(bad))
                try check("probe failure preserves state and releases",!invalid && s.timeline==stable && starts-stops==owned)
                await dismiss()
                // Only Cancel on our own native Open panel. No permission/Save dialog automation.
                // The external UI automation driver clicks Cancel on this panel.
                // DispatchQueue.main callbacks are not a reliable modal-loop driver.
                if !ProcessInfo.processInfo.arguments.contains("-OTFRelinkMenuRegression") {
                    // 무인 실행에서 끝없이 기다리지 않게(SP-PUBLIC-RELINK-UNDO-TRIAGE-12): 이 검사가 띄운 바로 그 패널만, 패널의 모달 실행 루프 모드에서
                    // 도는 타이머로 취소한다(저장 패널 자체 검사와 같은 방식). 승인(ok)은 하지 않고 다른 창·대화상자는 건드리지 않는다.
                    // 10초 안에 패널이 보이지 않으면 타이머를 멈춘다 — 그때는 사람이 "취소"를 눌러야 하며 실행기가 그 요청을 알린다.
                    var cancelTimer: Timer?
                    s.panelWillRunForTest = { panel in
                        var ticks = 0
                        let timer = Timer(timeInterval: 0.25, repeats: true) { t in
                            MainActor.assumeIsolated {
                                ticks += 1
                                if panel.isVisible { panel.cancel(nil); t.invalidate() }
                                else if ticks >= 40 { t.invalidate() }
                            }
                        }
                        RunLoop.main.add(timer, forMode: .modalPanel)
                        cancelTimer = timer
                    }
                    s.presentImageRelink(id)
                    s.panelWillRunForTest = nil
                    cancelTimer?.invalidate()
                    try check("native Open panel cancel unchanged",s.timeline==stable && starts-stops==owned)
                }
                var done=false,result=true
                let stale=Task {result=await s.relinkStillImage(id,to:a);done=true}
                let end=Date().addingTimeInterval(5)
                while s.alert?.title != "이미지 크기·방향 변경",!done,Date()<end{try await Task.sleep(nanoseconds:10_000_000)}
                s.resetProject()
                stale.cancel()
                while !done,Date()<end{try await Task.sleep(nanoseconds:10_000_000)}
                try check("stale session rejects and releases",done && !result && s.timeline==Timeline() && starts==stops && s.imagePreviewError == nil)
                await dismiss()

                // Open a genuinely missing reference: a bookmark can follow a renamed fixture.
                let absent = folder.appendingPathComponent("missing-row.ontheframe")
                var document = try JSONSerialization.jsonObject(with: Data(contentsOf: undoFile)) as! [String: Any]
                var entries = document["media"] as! [[String: Any]]
                entries[0].removeValue(forKey: "bookmark")
                document["media"] = entries
                try JSONSerialization.data(withJSONObject: document).write(to: absent, options: .withoutOverwriting)
                try FileManager.default.moveItem(at: a, to: displaced)
                let openedMissing = await s.openProject(at: absent)
                try check("open missing row fixture", openedMissing)
                await dismiss()

                EditorLayout.shared.mediaCollapsed = false
                EditorLayout.shared.leftTab = .media
                func checkRow(_ phase: String, missing: Bool, source: URL) async throws {
                    try check(phase + " availability", (s.missingMedia[id] != nil) == missing)
                    try check(phase + " bound source", ProjectPersistence.references(s.timeline).first { $0.id == id }?.name == source.lastPathComponent)
                    try await captureRow(phase)
                }
                try await checkRow("before relink", missing: true, source: a)
                let rowCancelled = try await relink(b, accept: false, capturePending: true)
                try check("missing row cancel", !rowCancelled && s.pendingImageRelinkID == nil)
                try await checkRow("cancel", missing: true, source: a)
                let rowFailed = await s.relinkStillImage(id, to: try scoped(bad))
                try check("failed candidate keeps missing source", !rowFailed && s.pendingImageRelinkID == nil && s.alert?.title == "이미지를 다시 연결할 수 없습니다")
                await dismiss()
                try await checkRow("failed", missing: true, source: a)
                let rowBefore = s.timeline
                let rowLinked = try await relink(b)
                try check("row relink committed", rowLinked)
                try await checkRow("relink", missing: false, source: b)
                let rowRelinked = s.timeline
                // 실행 취소가 실제로 타임라인에 적용됐는지를 먼저 따로 본다(적용되지 않은 것과 적용 뒤 누락 상태가 틀린 것을 구분).
                // 그 다음 누락 상태는 기다리지 않고 바로 본다: 실행 취소는 그 원본 리비전의 접근 정보(누락 사유 포함)를 같은 자리에서 되살려야 한다.
                try await focusEditor()
                try menu("실행 취소")
                try check("row undo restores timeline", s.timeline == rowBefore && rowRelinked != rowBefore)
                try await checkRow("undo", missing: true, source: a)
                try await focusEditor()
                try menu("다시 실행")
                try check("row redo restores timeline", s.timeline == rowRelinked)
                try await checkRow("redo", missing: false, source: b)
                let rowFile = folder.appendingPathComponent("reopen-row.ontheframe")
                try check("save row fixture", s.writeProject(to: rowFile))
                s.resetProject()
                let rowOpened = await s.openProject(at: rowFile)
                try check("reopen relinked image", rowOpened && s.projectID == projectID)
                try await waitForPreview(false)
                try await checkRow("reopen", missing: false, source: b)
                s.applyImageAvailability(false, id: id, snapshot: s.timeline, session: linkedSession, generation: s.generation)
                try check("previous session cannot mark reopened source missing", s.missingMedia[id] == nil)
                let beforeSecond = s.timeline
                let importedSecond = await s.importStillImage(at: c)
                try check("second image available", importedSecond)
                try check("second import preserves occupied timeline",s.timeline.clips == beforeSecond.clips && s.timeline.durationFrames == beforeSecond.durationFrames)
                guard let second = ProjectPersistence.references(s.timeline).first(where: { $0.id != id }) else {
                    throw Failure(name: "second image reference")
                }
                s.addToTimeline(second.id)
                try check("second image explicitly appended",s.timeline.clips.first(where: { $0.mediaID == second.id })?.start == (beforeSecond.clips.map(\.end).max() ?? 0))
                try FileManager.default.moveItem(at: c, to: folder.appendingPathComponent("second-moved.png"))
                s.timelineChanged()
                try await waitForPreview(true)
                try check("only unavailable source is marked", s.missingMedia[second.id] != nil && s.missingMedia[id] == nil)
                try FileManager.default.moveItem(at: folder.appendingPathComponent("second-moved.png"), to: c)
                var resume: CheckedContinuation<Void, Never>?
                let drops = s.imagePreviewStaleDropsForTest
                s.imagePreviewPreparedForTest = { _ in await withCheckedContinuation { resume = $0 } }
                defer { s.imagePreviewPreparedForTest = nil; resume?.resume() }
                s.timelineChanged()
                let gateDeadline = Date().addingTimeInterval(8)
                while resume == nil, Date() < gateDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
                try check("revalidation clears only recovered source", resume != nil && s.missingMedia.isEmpty)
                s.resetProject()
                resume?.resume()
                resume = nil
                let dropDeadline = Date().addingTimeInterval(3)
                while s.imagePreviewStaleDropsForTest == drops, Date() < dropDeadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                try check("late prepared preview discarded after replacement", s.imagePreviewStaleDropsForTest == drops + 1 &&
                    s.timeline.isEmpty && s.missingMedia.isEmpty && s.imagePreviewError == nil && s.player.currentItem == nil)
            }
        } catch {failure=String(describing:error)}
        await dismiss();s.stopAllScopes()
        let result:[String:Any]=["pass":failure==nil,"error":failure as Any? ?? NSNull(),"checks":checks,"scopeStarts":starts,"scopeStops":stops,"ownerPanels":false,"pid":ProcessInfo.processInfo.processIdentifier]
        try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("relink-result.json"))
        s.persistenceScopeStartForTest=nil;s.persistenceScopeStopForTest=nil
        s.discardConfirmedForTest();NSApp.terminate(nil)
    }
}
#endif
