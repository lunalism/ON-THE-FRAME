import AppKit
import os

/// 앱 알림을 AppKit 시트(NSAlert.beginSheetModal)로 직접 띄운다.
/// 2026-10-10 충돌(app/README.md 충돌 기록): SwiftUI 알림 다리(DeprecatedAlertBridge·AppKitDialogBridge 모두)가
/// 떠 있는 알림을 레이아웃 갱신 안에서 닫을 때 시트 닫기 애니메이션의 중첩 실행 루프에서 충돌했다.
/// 이 경로를 쓰지 않도록 알림은 SwiftUI 상태로 띄우거나 닫지 않는다. 알림은 사용자가 단추를 눌러야만 닫히고,
/// 다음 알림은 AppKit이 앞 시트를 끝낸 뒤(완료 처리, 시트가 아직 붙어 있으면 didEndSheet 알림 뒤) 띄운다.
@MainActor
final class AlertPresenter: NSObject {
    /// buttons[0]이 기본 단추(Return)다. destructiveIndex 단추는 파괴적 동작으로 표시한다.
    /// bringToFront: 붙일 창이 숨겨졌거나 최소화돼 있으면 앱을 다시 보이고 창을 앞으로 가져와 띄운다(사용자가 요청한 닫기·종료 확인).
    /// false면 창이 다시 보일 때까지 기다린다.
    /// cancelIndex 단추는 Esc로 누른다(한국어 "취소"는 NSAlert가 자동으로 Esc에 연결하지 않음).
    struct Request { let title: String; let message: String; let buttons: [String]; var destructiveIndex: Int? = nil; var cancelIndex: Int? = nil; var bringToFront = false
        /// 지정하면 NSAlert 대신 내보내기 완료 시트(CompletionSheet)로 띄운다. 단추는 0 = Finder에서 보기, 1 = 닫기.
        var completion: (fileName: String, detail: String)? = nil
        let onButton: (Int) -> Void }
    private var queue: [Request] = []
    private(set) var current: NSAlert?
    /// 떠 있는 완료 시트(NSAlert 대신)
    private(set) var currentSheet: CompletionSheet?
    private var sheetEndObserver: NSObjectProtocol?
    /// 알림을 붙일 창(편집기 창)
    var windowProvider: (() -> NSWindow?)?
    private var visibilityObservers: [NSObjectProtocol] = []
    /// 시트가 떨어지기를 기다리는 처리기와 그 관찰자
    private var pendingFinish: (() -> Void)?
    private var sheetDetachObserver: NSObjectProtocol?

    override init() {
        super.init()
        // 숨김 해제·최소화 해제·주 창이 됨: 기다리던 알림을 띄운다
        visibilityObservers = [NSApplication.didUnhideNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeMainNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showNext() }
            }
        }
    }

    var isShowing: Bool { current != nil || currentSheet != nil }

    func enqueue(_ r: Request) {
        queue.append(r)
        if current == nil { showNext() }
    }

    private static let log = Logger(subsystem: "dev.ontheframe.app", category: "alerts")
    private func showNext() {
        Self.log.debug("showNext current=\(self.current != nil) queue=\(self.queue.count) waitingSheetEnd=\(self.sheetEndObserver != nil) windows=\(NSApp.windows.map { "\(type(of: $0)) vis=\($0.isVisible) main=\($0.canBecomeMain) sheet=\($0.attachedSheet != nil)" }.joined(separator: ","), privacy: .public)")
        guard current == nil, currentSheet == nil, !queue.isEmpty, sheetEndObserver == nil else { return }
        guard let window = windowProvider?() ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        if !window.isVisible || window.isMiniaturized || NSApp.isHidden {
            // 창이 숨겨졌거나 최소화됨: 닫기·종료 확인이면 앞으로 가져온다. 그 밖의 알림은 다시 보일 때 띄운다.
            guard queue.first?.bringToFront == true else { return }
            if NSApp.isHidden { NSApp.unhide(nil) }
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            guard window.isVisible else { return }
        }
        if window.attachedSheet != nil {
            // 앞 알림 시트가 아직 내려가는 중(완료 처리는 시트가 완전히 떨어지기 전에 불릴 수 있다): 시트가 끝나면 다시 시도
            sheetEndObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let o = self.sheetEndObserver { NotificationCenter.default.removeObserver(o) }
                    self.sheetEndObserver = nil
                    self.showNext()
                }
            }
            return
        }
        let r = queue.removeFirst()
        if let c = r.completion {
            // 내보내기 완료: 사용자 정의 시트. 단추가 시트를 끝내고, 끝난 뒤 처리는 NSAlert와 같은 경로(sheetEnded)로 간다.
            let sheet = CompletionSheet(title: r.title, fileName: c.fileName, detail: c.detail) { [weak window] i in
                guard let window, let p = window.attachedSheet else { return }
                window.endSheet(p, returnCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + i))
            }
            currentSheet = sheet
            window.beginSheet(sheet.panel) { [weak self] resp in
                MainActor.assumeIsolated { self?.sheetEnded(window, r, resp) }
            }
            return
        }
        let a = NSAlert()
        a.messageText = r.title
        a.informativeText = r.message
        for b in r.buttons { a.addButton(withTitle: b) }
        if let c = r.cancelIndex, a.buttons.indices.contains(c) { a.buttons[c].keyEquivalent = "\u{1b}" }
        if let d = r.destructiveIndex, a.buttons.indices.contains(d) {
            a.buttons[d].hasDestructiveAction = true
            // 기본 단추(Return)는 첫 단추(안전한 쪽)로 명시한다. 파괴적 단추에는 키를 주지 않는다.
            a.buttons[0].keyEquivalent = "\r"
            a.buttons[d].keyEquivalent = ""
        }
        current = a
        a.beginSheetModal(for: window) { [weak self] resp in
            MainActor.assumeIsolated { self?.sheetEnded(window, r, resp) }
        }
        // NSAlert가 배치하면서 키를 다시 정할 수 있어, 띄운 뒤에도 기본 단추(Return)를 안전한 첫 단추로 다시 정한다
        if r.destructiveIndex != nil, let first = a.buttons.first {
            first.keyEquivalent = "\r"
            a.window.defaultButtonCell = first.cell as? NSButtonCell
            if let d = r.destructiveIndex, a.buttons.indices.contains(d) { a.buttons[d].keyEquivalent = "" }
            if let c = r.cancelIndex, a.buttons.indices.contains(c) { a.buttons[c].keyEquivalent = "\u{1b}" }
        }
    }

    /// 시트(NSAlert·완료 시트)가 끝났을 때. 처리기는 시트가 창에서 완전히 떨어진 뒤 부른다. 완료 처리 시점에는 시트가 아직
    /// 붙어 있을 수 있어, 그 안에서 창을 닫으면(performClose) 무시된다(자체 검사로 확인).
    private func sheetEnded(_ window: NSWindow, _ r: Request, _ resp: NSApplication.ModalResponse) {
        let i = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        pendingFinish = { [weak self] in
            self?.current = nil
            self?.currentSheet = nil
            r.onButton(i)
            self?.showNext()
        }
        if window.attachedSheet == nil { runPendingFinish(); return }
        // 시트 끝 알림이 이미 지나갔을 수 있어(자체 검사에서 관찰), 알림과 함께 다음 실행 루프 차례마다 다시 확인한다.
        sheetDetachObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPendingFinish() }
        }
        recheckDetach(window, deadline: Date().addingTimeInterval(2))
    }

    /// 완료 시트를 편집기 내용 영역(툴바 아래) 가운데에 놓을 위치. 창 대리자의 willPositionSheet에서 쓴다(다른 시트는 기본 위치).
    func sheetPosition(for window: NSWindow, sheet: NSWindow) -> NSRect? {
        guard let cs = currentSheet, cs.panel === sheet else { return nil }
        let content = window.contentLayoutRect
        let top = min(content.maxY, content.midY + sheet.frame.height / 2)
        return NSRect(x: content.minX, y: top, width: content.width, height: 0)
    }

    /// 시트가 떨어졌는지 다음 차례마다 확인한다. 2초 안에 떨어지지 않으면 그래도 처리기를 부른다(대기열이 멈추지 않게).
    private func recheckDetach(_ window: NSWindow, deadline: Date) {
        DispatchQueue.main.async { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, self.pendingFinish != nil else { return }
                if window?.attachedSheet == nil || Date() > deadline { self.runPendingFinish() }
                else if let window { self.recheckDetach(window, deadline: deadline) }
            }
        }
    }

    private func runPendingFinish() {
        if let o = sheetDetachObserver { NotificationCenter.default.removeObserver(o); sheetDetachObserver = nil }
        let f = pendingFinish; pendingFinish = nil
        f?()
    }

    func windowAvailable() { showNext() }

    /// 대기 중 알림 수(진단 기록용)
    var queuedCount: Int { queue.count }
    #if DEBUG
    /// 자체 검사 전용: 사용자가 단추를 누르는 것과 같은 경로(NSButton 클릭)로 닫는다.
    func pressButton(_ i: Int) { currentButtons[safe: i]?.performClick(nil) }
    var currentButtons: [NSButton] { currentSheet.map { [$0.finderButton, $0.closeButton] } ?? current?.buttons ?? [] }
    #endif
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
