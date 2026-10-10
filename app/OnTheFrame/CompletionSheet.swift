import AppKit

/// 내보내기 완료 시트(A-011 시각 조정). NSAlert로는 남색 바탕·단추 색을 깔끔히 바꿀 수 없어 AppKit 패널을 시트로 띄운다.
/// 표시·닫기는 AlertPresenter 대기열이 맡는다(SwiftUI 알림 다리·코드로 닫기 없음, 사용자가 단추·키로만 닫음).
/// 단추 번호는 기존 완료 알림과 같다: 0 = "Finder에서 보기", 1 = "닫기". Return·Esc는 "닫기"이고, Finder는 그 단추를 눌러야만 연다.
@MainActor
final class CompletionSheet: NSObject {
    let panel: CompletionPanel
    let finderButton: NSButton
    let closeButton: NSButton
    let fileField: NSTextField
    private let onButton: (Int) -> Void

    static let navy = NSColor(srgbRed: 0x17 / 255, green: 0x23 / 255, blue: 0x34 / 255, alpha: 1)
    static let secondary = NSColor(srgbRed: 0xCB / 255, green: 0xD5 / 255, blue: 0xE1 / 255, alpha: 1)
    static let accent = NSColor(srgbRed: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255, alpha: 1)
    static let accentText = NSColor(srgbRed: 0x08 / 255, green: 0x1A / 255, blue: 0x2B / 255, alpha: 1)
    static let slate = NSColor(srgbRed: 0x33 / 255, green: 0x41 / 255, blue: 0x55 / 255, alpha: 1)
    static let green = NSColor(srgbRed: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255, alpha: 1)
    static let width: CGFloat = 420

    init(title: String, fileName: String, detail: String, onButton: @escaping (Int) -> Void) {
        self.onButton = onButton
        panel = CompletionPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = Self.navy
        panel.isOpaque = true
        panel.appearance = NSAppearance(named: .darkAqua)   // 바탕이 늘 어두우므로 초점 고리·선택 색도 어두운 모양으로
        panel.setAccessibilityLabel(title)

        let icon = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 34, weight: .semibold).applying(.init(paletteColors: [.white, Self.green]))
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "완료")?.withSymbolConfiguration(cfg)
        icon.setAccessibilityLabel("완료")

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center

        // 파일 이름: 읽기 쉽게 줄 바꿈(최대 3줄), 고를 수 있음. 잘리면 도움말·손쉬운 사용 이름으로 전체 이름을 준다.
        fileField = NSTextField(wrappingLabelWithString: fileName)
        fileField.font = .systemFont(ofSize: 14, weight: .medium)
        fileField.textColor = .white
        fileField.alignment = .center
        fileField.isSelectable = true
        fileField.maximumNumberOfLines = 3
        fileField.lineBreakMode = .byCharWrapping
        fileField.cell?.truncatesLastVisibleLine = true
        fileField.preferredMaxLayoutWidth = Self.width - 64
        fileField.toolTip = fileName
        fileField.setAccessibilityLabel("파일 이름 \(fileName)")

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = Self.secondary
        detailLabel.alignment = .center

        finderButton = Self.button("Finder에서 보기", fill: Self.accent, text: Self.accentText)
        closeButton = Self.button("닫기", fill: Self.slate, text: .white)
        closeButton.keyEquivalent = "\r"          // Return = 닫기(기본 동작)
        finderButton.keyEquivalent = ""           // Finder는 명시적으로 눌러야만
        super.init()
        finderButton.target = self; finderButton.action = #selector(pressFinder)
        closeButton.target = self; closeButton.action = #selector(pressClose)
        panel.onCancel = { [weak self] in self?.finish(1) }   // Esc = 닫기

        let stack = NSStackView(views: [icon, titleLabel, fileField, detailLabel, finderButton, closeButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(18, after: detailLabel)
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Self.navy.cgColor   // 창 바탕과 같은 불투명 남색(투명·흐림 없음)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
            fileField.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 56),
            finderButton.widthAnchor.constraint(equalToConstant: Self.width - 56),
            closeButton.widthAnchor.constraint(equalToConstant: Self.width - 56),
        ])
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
        panel.defaultButtonCell = closeButton.cell as? NSButtonCell
        panel.initialFirstResponder = closeButton
    }

    static func button(_ title: String, fill: NSColor, text: NSColor) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .push
        b.controlSize = .large
        b.bezelColor = fill
        b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: text, .font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
        b.setAccessibilityLabel(title)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    @objc private func pressFinder() { finish(0) }
    @objc private func pressClose() { finish(1) }
    private func finish(_ i: Int) { onButton(i) }
}

/// Esc를 "닫기"로 보내는 패널
final class CompletionPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var canBecomeKey: Bool { true }
}
