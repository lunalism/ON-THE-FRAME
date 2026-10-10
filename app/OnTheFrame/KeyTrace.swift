import AppKit
import Carbon
import os

/// 키 경로 기록(진단용, 기본 꺼짐). `open … --args -OTFKeyTrace`로 켠다.
/// 기록 내용: 층, 키 코드, 수정 키, 창·첫 응답자 종류, 현재 입력 소스 ID, 처리 결과.
/// 글자는 ⌘ 조합과 편집기 단축키 키에만 기록하고(일반 입력 글자는 기록하지 않음), ASCII가 아니면 U+XXXX로 적는다.
@MainActor
enum KeyTrace {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-OTFKeyTrace")
    static let log = Logger(subsystem: "dev.ontheframe.app", category: "keys")
    static let shortcutCodes: Set<UInt16> = [49, 123, 124, 115, 119, 51, 117, 53]

    static func log(_ layer: String, _ e: NSEvent, store: ProjectStore) {
        guard enabled else { return }
        let w = store.editorWindow
        let showChars = e.modifierFlags.contains(.command) || shortcutCodes.contains(e.keyCode)
        let chars = showChars ? "\(esc(e.characters))/\(esc(e.charactersIgnoringModifiers))" : "-"
        let fr = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let msg = "layer=\(layer) code=\(e.keyCode) flags=\(String(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue, radix: 16)) repeat=\(e.isARepeat) chars=\(chars) evWin=\(e.window === w ? "editor" : (e.window.map { String(describing: type(of: $0)) } ?? "nil")) key=\(NSApp.keyWindow === w ? "editor" : (NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")) main=\(NSApp.mainWindow === w) fr=\(fr) src=\(inputSourceID())"
        Self.log.notice("\(msg, privacy: .public)")
    }
    static func decision(_ d: String, _ e: NSEvent) {
        guard enabled else { return }
        Self.log.notice("decision=\(d, privacy: .public) code=\(e.keyCode)")
    }
    static func note(_ s: String) {
        guard enabled else { return }
        Self.log.notice("\(s, privacy: .public)")
    }
    private static func esc(_ s: String?) -> String {
        guard let s else { return "nil" }
        return s.unicodeScalars.map { $0.isASCII && $0.value >= 32 && $0.value < 127 ? String($0) : String(format: "U+%04X", $0.value) }.joined()
    }
    /// 현재 키보드 입력 소스 ID(읽기만 한다)
    static func inputSourceID() -> String {
        let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
}
