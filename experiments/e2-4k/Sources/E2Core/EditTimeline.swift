import CoreMedia
import E1Core
import Foundation

/// 최소 편집 타임라인(실험 범위): 비디오 트랙 1개에 클립이 빈틈 없이 순서대로 놓이는 하드 컷만 다룬다.
/// 이것은 E2 실험의 범위 제한이며 제품 제한이 아니다. 모든 위치·길이는 30 fps 프레임 단위 정수다.
/// 클립의 오디오(소스 영상에 들어 있는 오디오)는 클립과 함께 움직인다.
public struct EditClip: Codable, Sendable, Equatable {
    public let name: String         // 편집 기록용 이름(예: "B.1")
    public let source: String       // 소스 키("A", "B", "C")
    public let sourceIn: Int        // 소스 프레임
    public let length: Int          // 프레임 수
    public init(name: String, source: String, sourceIn: Int, length: Int) {
        self.name = name; self.source = source; self.sourceIn = sourceIn; self.length = length
    }
}

/// 타임라인 위 구간: [start, start + length) 타임라인 프레임 → 소스 프레임 sourceIn + (n − start)
public struct EditSegment: Codable, Sendable, Equatable {
    public let start: Int, length: Int, source: String, sourceIn: Int, clip: String
}

public enum EditError: Error, CustomStringConvertible {
    case badIndex(Int), outOfSource(String), emptyClip(String), badSplit(Int), unknownSource(String)
    public var description: String {
        switch self {
        case .badIndex(let i): return "edit: bad clip index \(i)"
        case .outOfSource(let s): return "edit: range outside source \(s)"
        case .emptyClip(let s): return "edit: empty clip \(s)"
        case .badSplit(let n): return "edit: split point \(n) not inside a clip"
        case .unknownSource(let s): return "edit: unknown source \(s)"
        }
    }
}

public struct EditTimeline: Codable, Sendable {
    public private(set) var clips: [EditClip] = []
    /// 소스 키 → 소스 길이(프레임). 범위 검사에 쓴다.
    public let sourceLengths: [String: Int]
    /// 편집 기록(결과 JSON에 남긴다)
    public private(set) var log: [String] = []

    public init(sourceLengths: [String: Int]) { self.sourceLengths = sourceLengths }

    func check(_ c: EditClip) throws {
        guard let len = sourceLengths[c.source] else { throw EditError.unknownSource(c.source) }
        guard c.length > 0 else { throw EditError.emptyClip(c.name) }
        guard c.sourceIn >= 0, c.sourceIn + c.length <= len else { throw EditError.outOfSource("\(c.name) [\(c.sourceIn), \(c.sourceIn + c.length)) of \(len)") }
    }

    /// 소스 전체를 끝에 붙인다.
    public mutating func append(source: String, name: String) throws {
        guard let len = sourceLengths[source] else { throw EditError.unknownSource(source) }
        let c = EditClip(name: name, source: source, sourceIn: 0, length: len)
        try check(c)
        clips.append(c)
        log.append("append \(name) = \(source)[0, \(len))")
    }

    /// 클립의 소스 구간을 [newIn, newIn + newLength)로 바꾼다. 뒤 클립은 앞으로 당겨진다(빈틈 없음).
    public mutating func trim(_ index: Int, sourceIn newIn: Int, length newLength: Int) throws {
        guard clips.indices.contains(index) else { throw EditError.badIndex(index) }
        let old = clips[index]
        let c = EditClip(name: old.name, source: old.source, sourceIn: newIn, length: newLength)
        try check(c)
        clips[index] = c
        log.append("trim \(old.name): \(old.source)[\(old.sourceIn), \(old.sourceIn + old.length)) → [\(newIn), \(newIn + newLength))")
    }

    /// 타임라인 프레임 at에서 클립을 둘로 나눈다. at은 클립 내부(시작 초과, 끝 미만)여야 한다.
    public mutating func split(atTimelineFrame at: Int, names: (String, String)) throws {
        var start = 0
        for (i, c) in clips.enumerated() {
            if at > start && at < start + c.length {
                let k = at - start
                let a = EditClip(name: names.0, source: c.source, sourceIn: c.sourceIn, length: k)
                let b = EditClip(name: names.1, source: c.source, sourceIn: c.sourceIn + k, length: c.length - k)
                clips.replaceSubrange(i...i, with: [a, b])
                log.append("split \(c.name) at timeline \(at) → \(a.name) \(c.source)[\(a.sourceIn), \(a.sourceIn + a.length)), \(b.name) \(c.source)[\(b.sourceIn), \(b.sourceIn + b.length))")
                return
            }
            start += c.length
        }
        throw EditError.badSplit(at)
    }

    /// 클립을 다른 순서 위치로 옮긴다(나머지는 빈틈 없이 다시 이어진다).
    public mutating func move(from: Int, to: Int) throws {
        guard clips.indices.contains(from), (0..<clips.count).contains(to) else { throw EditError.badIndex(from) }
        let c = clips.remove(at: from)
        clips.insert(c, at: to)
        log.append("move \(c.name) from index \(from) to \(to)")
    }

    public var durationFrames: Int { clips.reduce(0) { $0 + $1.length } }
    public var duration: CMTime { CMTime(value: CMTimeValue(durationFrames), timescale: Spec4K.fps) }

    public var segments: [EditSegment] {
        var out: [EditSegment] = []
        var start = 0
        for c in clips {
            out.append(EditSegment(start: start, length: c.length, source: c.source, sourceIn: c.sourceIn, clip: c.name))
            start += c.length
        }
        return out
    }

    /// 타임라인 프레임 n의 (소스, 소스 프레임). 범위 밖이면 nil.
    public func sourceFrame(at n: Int) -> (source: String, frame: Int)? {
        for s in segments where n >= s.start && n < s.start + s.length { return (s.source, s.sourceIn + n - s.start) }
        return nil
    }

    /// 마지막 유효 프레임(D-018): E1의 FrameGrid로 타임라인 길이에서 유도한다. 빈 타임라인이면 nil.
    public var lastValidFrame: Int? { FrameGrid.lastValidFrame(duration: duration, frameDuration: Spec4K.frameDuration) }

    /// E2 실험의 편집 순서(소스 A 8 s, B 8 s, C 6 s):
    /// 1) A, B, C를 붙인다(22 s)  2) A를 [30, 120)으로 트림  3) 타임라인 150에서 B를 B.1/B.2로 나눔
    /// 4) B.2를 [150, 210)으로 트림  5) C를 [20, 110)으로 트림  6) C를 A 다음(순서 1)으로 이동 → 10 s
    public static func e2Experiment() throws -> EditTimeline {
        var t = EditTimeline(sourceLengths: Dictionary(uniqueKeysWithValues: SourceVideoSpec.all.map { ($0.key, $0.frames) }))
        try t.append(source: "A", name: "A")
        try t.append(source: "B", name: "B")
        try t.append(source: "C", name: "C")
        try t.trim(0, sourceIn: 30, length: 90)
        try t.split(atTimelineFrame: 150, names: ("B.1", "B.2"))
        try t.trim(2, sourceIn: 150, length: 60)
        try t.trim(3, sourceIn: 20, length: 90)
        try t.move(from: 3, to: 1)
        return t
    }
}

/// 타임라인 자막(시간 구간은 반열린 [start, end), 프레임 단위)
public struct TimedCaption: Codable, Sendable {
    public let text: String
    public let startFrame: Int, endFrame: Int
    public let alignment: CaptionAlignment
    public init(text: String, startFrame: Int, endFrame: Int, alignment: CaptionAlignment) {
        self.text = text; self.startFrame = startFrame; self.endFrame = endFrame; self.alignment = alignment
    }
    public static let e2: [TimedCaption] = [
        TimedCaption(text: "첫째 자막 — 왼쪽", startFrame: 15, endFrame: 75, alignment: .left),        // [0.5, 2.5) s
        TimedCaption(text: "둘째 자막 — 가운데", startFrame: 75, endFrame: 165, alignment: .center),   // [2.5, 5.5) s, 컷 90을 걸침
        TimedCaption(text: "셋째 자막 — 오른쪽", startFrame: 210, endFrame: 270, alignment: .right),   // [7.0, 9.0) s, 컷 240을 걸침
    ]
}

/// 선택 오디오(음악) 배치: 원본 [sourceIn, sourceIn + duration)을 타임라인 timelineStart부터 놓는다.
/// 2026-10-10(A-004): E3의 0.5 s 배치를 위해 초 단위 정수에서 밀리초 단위 정수로 바꿨다. E2 값은 같다.
public struct MusicPlacement: Codable, Sendable {
    public let sourceInMs: Int, durationMs: Int, timelineStartMs: Int
    public init(sourceInMs: Int, durationMs: Int, timelineStartMs: Int) {
        self.sourceInMs = sourceInMs; self.durationMs = durationMs; self.timelineStartMs = timelineStartMs
    }
    public static let e2 = MusicPlacement(sourceInMs: 2_000, durationMs: 9_000, timelineStartMs: 1_000)
    /// 타임라인 프레임 n → 음악 원본 시각(배치 밖이면 nil). 정수 유리수 연산.
    public func sourceTime(frame n: Int) -> CMTime? {
        let t = Spec4K.frameTime(n)
        let a = CMTime(value: CMTimeValue(timelineStartMs), timescale: 1000)
        guard t >= a, t < a + CMTime(value: CMTimeValue(durationMs), timescale: 1000) else { return nil }
        return t - a + CMTime(value: CMTimeValue(sourceInMs), timescale: 1000)
    }
}
