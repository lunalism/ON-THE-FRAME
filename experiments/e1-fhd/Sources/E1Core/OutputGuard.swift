import Darwin
import Foundation

/// 이 실험이 만든 임시 디렉터리. 이 값으로만 정리하므로 다른 파일은 지우지 않는다.
public struct OwnedTempDir {
    public static let prefix = ".e1-export-"
    public static let suffix = ".tmp"
    public let url: URL
}

/// 출력 보호(DR-03, DR-10 실험). 이 실험에서는 대상 충돌을 항상 거부한다(덮어쓰기 경로 없음).
public enum OutputGuard {
    /// 시작 전 검사: 원본 경로와 같으면 거부, 이미 있으면 거부, 상위 디렉터리가 없거나 쓸 수 없으면 거부.
    public static func preflight(destination: URL, sources: [URL]) throws {
        let dest = destination.standardizedFileURL.resolvingSymlinksInPath()
        for s in sources {
            let src = s.standardizedFileURL.resolvingSymlinksInPath()
            if src.path == dest.path { throw E1Error.destinationIsSource(dest.path) }
            if let a = try? FileManager.default.attributesOfItem(atPath: src.path),
               let b = try? FileManager.default.attributesOfItem(atPath: dest.path),
               (a[.systemFileNumber] as? Int) == (b[.systemFileNumber] as? Int),
               (a[.systemNumber] as? Int) == (b[.systemNumber] as? Int) {
                throw E1Error.destinationIsSource(dest.path)
            }
        }
        var st = stat()
        if lstat(dest.path, &st) == 0 { throw E1Error.destinationExists(dest.path) }
        let parent = dest.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw E1Error.destinationParentMissing(parent.path)
        }
        guard access(parent.path, W_OK) == 0 else { throw E1Error.destinationParentNotWritable(parent.path) }
    }

    /// 대상과 같은 디렉터리(따라서 같은 볼륨)에 고유한 임시 디렉터리를 만든다. 이미 있으면 실패(mkdir).
    public static func makeTempDir(for destination: URL) throws -> OwnedTempDir {
        let parent = destination.deletingLastPathComponent()
        let url = parent.appendingPathComponent(OwnedTempDir.prefix + UUID().uuidString + OwnedTempDir.suffix)
        guard mkdir(url.path, 0o700) == 0 else {
            let e = errno
            if e == EACCES || e == EPERM || e == EROFS { throw E1Error.destinationParentNotWritable("\(parent.path) (mkdir errno \(e))") }
            throw E1Error.writer("mkdir temp failed errno \(e)")
        }
        return OwnedTempDir(url: url)
    }

    /// 임시 파일을 대상 경로로 원자적으로 옮긴다. 대상이 그 사이 생겼으면 덮어쓰지 않고 실패(RENAME_EXCL).
    public static func promote(_ temp: URL, to destination: URL) throws {
        if renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            let e = errno
            if e == EEXIST { throw E1Error.promotionConflict(destination.path) }
            throw E1Error.writer("renamex_np errno \(e)")
        }
    }

    /// 실험 소유 임시 디렉터리만 삭제한다.
    @discardableResult
    public static func cleanup(_ dir: OwnedTempDir) -> Bool {
        let name = dir.url.lastPathComponent
        guard name.hasPrefix(OwnedTempDir.prefix), name.hasSuffix(OwnedTempDir.suffix) else { return false }
        if FileManager.default.fileExists(atPath: dir.url.path) {
            try? FileManager.default.removeItem(at: dir.url)
        }
        return !FileManager.default.fileExists(atPath: dir.url.path)
    }

    /// 디렉터리에 남은 실험 임시 디렉터리 목록(누수 확인용)
    public static func leftovers(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(OwnedTempDir.prefix) }
    }
}
