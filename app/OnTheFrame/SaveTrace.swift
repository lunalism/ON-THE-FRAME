import Foundation
import os

/// 프로젝트 저장 경로 추적(A-013 저장 실패 조사). 단계마다 컨테이너의 Library/Logs/OnTheFrame-save.log에 한 줄씩 남긴다.
/// 사용자 화면에는 보이지 않는다. 경로는 이 Mac의 로그에만 있고 저장소에 들어가지 않는다.
enum SaveTrace {
    static let log = Logger(subsystem: "dev.ontheframe.app", category: "save")
    static let url: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("OnTheFrame-save.log")
    static func note(_ s: String) {
        log.notice("\(s, privacy: .public)")
        guard let url else { return }
        let line = ISO8601DateFormatter().string(from: Date()) + " " + s + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 크기 제한: 256 KB를 넘으면 비우고 다시 시작한다(진단용 기록이라 오래된 줄은 필요 없음)
        if let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), n > 256 * 1024 { try? FileManager.default.removeItem(at: url) }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}
