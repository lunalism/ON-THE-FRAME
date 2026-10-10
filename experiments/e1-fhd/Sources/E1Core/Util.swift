import Darwin
import Foundation

public enum E1Error: Error, CustomStringConvertible {
    case reader(String)
    case writer(String)
    case invalidSource(String)
    case destinationExists(String)
    case destinationIsSource(String)
    case destinationParentMissing(String)
    case destinationParentNotWritable(String)
    case promotionConflict(String)
    case verificationFailed(String)
    case injectedFailure(Int)
    case render(String)
    case budgetExceeded(String)

    public var description: String {
        switch self {
        case .reader(let s): return "reader: \(s)"
        case .writer(let s): return "writer: \(s)"
        case .invalidSource(let s): return "invalidSource: \(s)"
        case .destinationExists(let s): return "destinationExists: \(s)"
        case .destinationIsSource(let s): return "destinationIsSource: \(s)"
        case .destinationParentMissing(let s): return "destinationParentMissing: \(s)"
        case .destinationParentNotWritable(let s): return "destinationParentNotWritable: \(s)"
        case .promotionConflict(let s): return "promotionConflict: \(s)"
        case .verificationFailed(let s): return "verificationFailed: \(s)"
        case .injectedFailure(let n): return "injectedFailure at frame \(n)"
        case .render(let s): return "render: \(s)"
        case .budgetExceeded(let s): return "budgetExceeded: \(s)"
        }
    }

    /// 실패 원인 분류(보고용)
    public var kind: String { String(description.prefix { $0 != ":" && $0 != " " }) }
}

public enum Memory {
    /// 현재 프로세스의 phys_footprint(바이트). Activity Monitor의 "메모리"와 같은 계열의 값.
    public static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

public enum Clock {
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    public static func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(Int64(b) - Int64(a)) / 1e6 }
}

public enum DiskUsage {
    /// 디렉터리 아래 파일의 할당 크기 합(바이트). 없으면 0.
    public static func allocatedBytes(_ url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
        var sum: UInt64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                sum += UInt64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return sum
    }
}

/// 결과를 시험한 구현에 귀속시키기 위한 식별 정보. 소스는 아직 커밋되지 않았으므로 파일 해시로 남긴다.
public enum BuildIdentity {
    /// root(실험 디렉터리) 아래 Package.swift, Sources/**, Tests/**의 .swift 파일별 SHA-256과 전체 트리 해시.
    public static func sourceTree(root: URL) -> [String: Any] {
        var files: [String] = ["Package.swift"]
        for dir in ["Sources", "Tests"] {
            let base = root.appendingPathComponent(dir)
            if let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
                while let u = e.nextObject() as? URL {
                    if u.pathExtension == "swift" { files.append(dir + "/" + String(u.path.dropFirst(base.path.count + 1))) }
                }
            }
        }
        files.sort()
        var perFile: [String: String] = [:]
        var tree = ""
        for f in files {
            let h = (try? Hashing.sha256(file: root.appendingPathComponent(f))) ?? "unreadable"
            perFile[f] = h
            tree += "\(h)  \(f)\n"
        }
        return ["treeSha256": Hashing.sha256(Data(tree.utf8)), "files": perFile, "fileCount": files.count]
    }

    public static func executable() -> [String: Any] {
        let path = CommandLine.arguments[0]
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var d: [String: Any] = ["name": url.lastPathComponent, "sha256": (try? Hashing.sha256(file: url)) ?? "unreadable"]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            d["bytes"] = attrs[.size] as? UInt64 ?? 0
            d["modified"] = (attrs[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "-"
        }
        #if DEBUG
        d["configuration"] = "debug"
        #else
        d["configuration"] = "release"
        #endif
        return d
    }
}

/// 잠금으로 보호한 값 상자(테스트 훅이 다른 큐에서 값을 바꿀 때 사용).
/// 안전성(@unchecked Sendable의 근거): `value`는 `lock` 안에서만 읽고 쓴다.
public final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    public init(_ v: T) { value = v }
    public func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    public func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    @discardableResult public func update<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}
