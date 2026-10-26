import Foundation

// 스펙트럼 클립 모델(2026-10-25, SP-1A 1단계 — docs/SPECTRUM-DESIGN.md §1·§15): 스펙트럼 레인의 독립 항목, 소스 오디오 계보 참조, 상태 판정.
// 이 단계는 엔진 모델·편집·저장(형식 8)·판정까지다. 앱 UI·프리뷰·내보내기 그리기는 다음 단계(§15)다.
// 모양 값의 기본은 잠정(D-S5, 참고 그림 값). 두 색·부드러움은 SP-2(D-S6) — 이 단계는 한 색이다.

/// 스펙트럼 모양·분석 값(저장 단위: 정수 — 위치·높이·두께는 1920×1080 기준 화소의 1/1000, 색 0–255, 주파수 Hz, 시간 ms).
public struct SpectrumItemStyle: Sendable, Equatable, Codable {
    public enum Mode: String, Sendable, Codable { case digital, analog }
    public enum Sides: String, Sendable, Codable { case above, mirrored, below }
    public var mode: Mode
    public var sides: Sides
    public var startXMilli: Int, startYMilli: Int, endXMilli: Int, endYMilli: Int
    public var maxHeightMilli: Int, thicknessMilli: Int
    public var red: Int, green: Int, blue: Int, alpha: Int
    public var bands: Int, lowHz: Int, highHz: Int, windowMs: Int, offsetMs: Int, floorDB: Int
    public init(mode: Mode, sides: Sides, startXMilli: Int, startYMilli: Int, endXMilli: Int, endYMilli: Int, maxHeightMilli: Int, thicknessMilli: Int,
                red: Int, green: Int, blue: Int, alpha: Int, bands: Int, lowHz: Int, highHz: Int, windowMs: Int, offsetMs: Int, floorDB: Int) {
        self.mode = mode; self.sides = sides
        self.startXMilli = startXMilli; self.startYMilli = startYMilli; self.endXMilli = endXMilli; self.endYMilli = endYMilli
        self.maxHeightMilli = maxHeightMilli; self.thicknessMilli = thicknessMilli
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        self.bands = bands; self.lowHz = lowHz; self.highHz = highHz; self.windowMs = windowMs; self.offsetMs = offsetMs; self.floorDB = floorDB
    }
    /// 잠정 기본값(D-S5 미확정, 참고 그림 값 중 한 색 단계에 쓰는 것): 시작/끝 (192,540)/(1728,540), 최대 높이 480, 두께 3, 디지털, 위아래 대칭,
    /// 64밴드, 20–2000 Hz, 분석 90 ms, 오프셋 0, 바닥 −60 dB, 흰색(두 색·부드러움은 SP-2).
    public static let provisionalDefault = SpectrumItemStyle(mode: .digital, sides: .mirrored, startXMilli: 192_000, startYMilli: 540_000, endXMilli: 1_728_000, endYMilli: 540_000,
                                                              maxHeightMilli: 480_000, thicknessMilli: 3_000, red: 255, green: 255, blue: 255, alpha: 255,
                                                              bands: 64, lowHz: 20, highHz: 2000, windowMs: 90, offsetMs: 0, floorDB: -60)
    /// 분석 표본율(엔진 분석 기본 48 kHz)에서 쓸 수 있는가
    public var isValid: Bool {
        guard [red, green, blue, alpha].allSatisfy({ (0...255).contains($0) }) else { return false }
        guard renderStyle.validationError() == nil else { return false }
        return analysisSettings.validationError(rate: 48_000) == nil
    }
    /// 그리기 모양(엔진 SpectrumRenderer, package)
    package var renderStyle: SpectrumStyle {
        SpectrumStyle(start: CGPoint(x: Double(startXMilli) / 1000, y: Double(startYMilli) / 1000), end: CGPoint(x: Double(endXMilli) / 1000, y: Double(endYMilli) / 1000),
                      maxHeight: Double(maxHeightMilli) / 1000, thickness: Double(thicknessMilli) / 1000,
                      mode: mode == .digital ? .digital : .analog, sides: sides == .above ? .above : (sides == .mirrored ? .mirrored : .below),
                      red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: Double(alpha) / 255)
    }
    /// 분석 설정(엔진 SpectrumAnalysis)
    public var analysisSettings: SpectrumAnalysisSettings {
        SpectrumAnalysisSettings(windowMs: windowMs, offsetMs: offsetMs, bands: bands, lowHz: lowHz, highHz: highHz, floorDB: floorDB)
    }
}

/// 스펙트럼 클립: 스펙트럼 레인의 [start, start + length) 정수 프레임에 보인다. sourceKey는 소스 오디오의 계보 키(Clip.lineageKey), nil = 고르지 않음.
/// 그 구간의 프레임 k에서 분석하는 소리는 같은 타임라인 시각(+ 오프셋)에 그 계보의 조각이 내는 소리다(소스를 옮기거나 트림해도 따라감).
public struct SpectrumItem: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let lane: UUID
    public let start: Int
    public let length: Int
    public let sourceKey: UUID?
    public let style: SpectrumItemStyle
    public init(id: UUID = UUID(), lane: UUID, start: Int, length: Int, sourceKey: UUID? = nil, style: SpectrumItemStyle = .provisionalDefault) {
        self.id = id; self.lane = lane; self.start = start; self.length = length; self.sourceKey = sourceKey; self.style = style
    }
    public var end: Int { start + length }
    public func visible(atFrame n: Int) -> Bool { n >= start && n < end }
    public func with(id: UUID? = nil, lane: UUID? = nil, start: Int? = nil, length: Int? = nil, sourceKey: UUID?? = nil, style: SpectrumItemStyle? = nil) -> SpectrumItem {
        SpectrumItem(id: id ?? self.id, lane: lane ?? self.lane, start: start ?? self.start, length: length ?? self.length, sourceKey: sourceKey ?? self.sourceKey, style: style ?? self.style)
    }
}

/// 소스 목록의 한 항목 = 소리 클립 계보 하나(같은 키의 조각들, 시작 순)
public struct SpectrumSource: Sendable, Equatable, Identifiable {
    public let key: UUID
    public let pieces: [Clip]
    public var id: UUID { key }
    public var mediaID: UUID { pieces[0].mediaID }
    /// 전체 타임라인 범위(첫 조각 시작 ~ 마지막 조각 끝)
    public var range: Range<Int> { (pieces.map(\.start).min() ?? 0)..<(pieces.map(\.end).max() ?? 0) }
}

/// 스펙트럼의 소스 상태(§1.5). 원본 파일을 찾을 수 없는지는 앱이 본다(엔진은 파일 접근을 모름).
public enum SpectrumSourceState: Sendable, Equatable { case unset, missing, ok }

/// 같은 계보의 조각이 같은 시각에 겹치는 구간(D-S8 판정): 타임라인 프레임 구간과 그 구간을 덮는 조각 ID들
public struct SpectrumOverlap: Sendable, Equatable { public let range: Range<Int>; public let clipIDs: [UUID] }

/// 프레임 하나의 상태: 안 보임 / 소스 고르지 않음 / 소스 없음 / 겹침 / 정상(조각이 없으면 무음 — 분석이 0을 냄)
public enum SpectrumFrameState: Sendable, Equatable { case notVisible, unset, missing, overlap, ok }

/// 내보내기를 막는 이유(D-S3 소스 없음·고르지 않음, D-S8 겹침): 어느 스펙트럼(레인·구간)인지 밝힌다. 대상 파일을 건드리기 전에 쓴다.
public struct SpectrumExportBlocker: Sendable, Equatable {
    public enum Reason: Sendable, Equatable { case unsetSource, missingSource, overlappingSource([SpectrumOverlap]) }
    public let spectrumID: UUID, lane: UUID, laneLabel: String, range: Range<Int>, reason: Reason
}

extension Timeline {
    /// 새 스펙트럼 기본 길이(만들 때 소스를 고르지 않았을 때): 5초
    public static let defaultSpectrumFrames = 150

    public func spectrum(_ id: UUID) -> SpectrumItem? { spectra.first { $0.id == id } }
    public func spectra(inLane id: UUID) -> [SpectrumItem] { spectra.filter { $0.lane == id } }
    /// 형식 8이 필요한가(스펙트럼 레인 또는 스펙트럼이 있음)
    public var needsSpectrumFormat: Bool { !spectra.isEmpty || !lanes(.spectrum).isEmpty }

    // MARK: 소스 계보

    /// 소스 목록: 소리 클립 계보(같은 lineageKey의 조각 묶음). 차례: 첫 조각 시작, 같으면 레인 순서.
    public func spectrumSources() -> [SpectrumSource] {
        let order = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($1.id, $0) })
        var groups: [UUID: [Clip]] = [:]
        for c in audioClips { groups[c.lineageKey, default: []].append(c) }
        return groups.map { SpectrumSource(key: $0.key, pieces: $0.value.sorted { ($0.start, order[$0.lane ?? UUID()] ?? 0) < ($1.start, order[$1.lane ?? UUID()] ?? 0) }) }
            .sorted { a, b in
                let la = a.pieces.first.flatMap { $0.lane.flatMap { order[$0] } } ?? 0, lb = b.pieces.first.flatMap { $0.lane.flatMap { order[$0] } } ?? 0
                return (a.range.lowerBound, la, a.key.uuidString) < (b.range.lowerBound, lb, b.key.uuidString)
            }
    }
    public func spectrumSource(key: UUID) -> SpectrumSource? {
        let ps = audioClips.filter { $0.lineageKey == key }
        return ps.isEmpty ? nil : SpectrumSource(key: key, pieces: ps.sorted { $0.start < $1.start })
    }
    public func spectrumSourceState(_ s: SpectrumItem) -> SpectrumSourceState {
        guard let k = s.sourceKey else { return .unset }
        return audioClips.contains { $0.lineageKey == k } ? .ok : .missing
    }
    /// 그 계보의 조각이 같은 시각에 둘 이상 덮는 구간(within과 겹치는 것만). 서로 다른 레인에 있을 때만 생긴다(같은 레인은 겹치지 않음).
    public func spectrumOverlaps(key: UUID, within: Range<Int>? = nil) -> [SpectrumOverlap] {
        let ps = audioClips.filter { $0.lineageKey == key }
        guard ps.count > 1 else { return [] }
        let edges = Set(ps.flatMap { [$0.start, $0.end] }).sorted()
        var out: [SpectrumOverlap] = []
        for (a, b) in zip(edges, edges.dropFirst()) where a < b {
            let covering = ps.filter { $0.start <= a && b <= $0.end }
            guard covering.count > 1 else { continue }
            let ids = covering.map(\.id).sorted { $0.uuidString < $1.uuidString }
            if let last = out.last, last.range.upperBound == a, last.clipIDs == ids { out[out.count - 1] = SpectrumOverlap(range: last.range.lowerBound..<b, clipIDs: ids) }
            else { out.append(SpectrumOverlap(range: a..<b, clipIDs: ids)) }
        }
        guard let w = within else { return out }
        return out.filter { $0.range.lowerBound < w.upperBound && w.lowerBound < $0.range.upperBound }
    }
    /// 그 스펙트럼의 분석 창이 닿을 수 있는 타임라인 프레임 범위: 보이는 구간 ± (창 절반 + |오프셋|)을 프레임으로 올림 + 1
    public func spectrumAnalysisReach(_ s: SpectrumItem) -> Range<Int> {
        let ms = s.style.windowMs / 2 + abs(s.style.offsetMs)
        let m = (ms * 30 + 999) / 1000 + 1
        return max(0, s.start - m)..<(s.end + m)
    }
    /// 분석에 넘길 조각(그 계보의 모든 소리 클립, 그 레인의 음량·음소거 포함). 소스가 없으면 빈 배열.
    public func spectrumPieces(_ s: SpectrumItem) -> [SpectrumSourcePiece] {
        guard let k = s.sourceKey else { return [] }
        return audioClips.filter { $0.lineageKey == k }.compactMap { c in
            guard let l = c.lane.flatMap(laneInfo) else { return nil }
            return SpectrumSourcePiece(clip: c, lane: l)
        }
    }
    /// 그 스펙트럼의 소스 원본 미디어(조각이 모두 같은 미디어 — 계보는 자르기로만 생기므로). 소스 없음이면 nil.
    public func spectrumMediaID(_ s: SpectrumItem) -> UUID? { s.sourceKey.flatMap { k in audioClips.first { $0.lineageKey == k }?.mediaID } }
    /// 프레임 n의 상태: 보이지 않음·고르지 않음·소스 없음·겹침(그 프레임 분석 창이 겹친 구간에 닿음)·정상
    public func spectrumFrameState(_ s: SpectrumItem, atFrame n: Int) -> SpectrumFrameState {
        guard s.visible(atFrame: n) else { return .notVisible }
        switch spectrumSourceState(s) {
        case .unset: return .unset
        case .missing: return .missing
        case .ok:
            let ms = s.style.windowMs / 2 + abs(s.style.offsetMs), m = (ms * 30 + 999) / 1000 + 1
            return spectrumOverlaps(key: s.sourceKey!, within: max(0, n - m)..<(n + m + 1)).isEmpty ? .ok : .overlap
        }
    }
    /// 내보내기를 막는 스펙트럼(보이는 구간이 있는 모든 스펙트럼 — 길이 0인 것은 없음). 비어 있으면 스펙트럼 때문에 막지 않는다.
    public func spectrumExportBlockers() -> [SpectrumExportBlocker] {
        spectra.compactMap { s in
            let reason: SpectrumExportBlocker.Reason
            switch spectrumSourceState(s) {
            case .unset: reason = .unsetSource
            case .missing: reason = .missingSource
            case .ok:
                let o = spectrumOverlaps(key: s.sourceKey!, within: spectrumAnalysisReach(s))
                guard !o.isEmpty else { return nil }
                reason = .overlappingSource(o)
            }
            return SpectrumExportBlocker(spectrumID: s.id, lane: s.lane, laneLabel: laneLabel(s.lane), range: s.start..<s.end, reason: reason)
        }
    }

    // MARK: 편집(리플 없음 — 자막과 같은 규칙)

    /// 새 스펙트럼: 스펙트럼 레인의 at에 length로 둔다. 같은 레인의 다음 스펙트럼에 닿으면 그 앞까지 줄이고, at이 다른 스펙트럼 안이거나
    /// 1프레임도 들어가지 않으면 거부. 소스는 이 타임라인의 계보이거나 nil. 끝을 넘으면 타임라인 길이가 늘어난다.
    public func addingSpectrum(lane: UUID, at: Int, length: Int = Timeline.defaultSpectrumFrames, sourceKey: UUID?, style: SpectrumItemStyle = .provisionalDefault,
                               id: UUID = UUID()) throws -> Timeline {
        guard laneInfo(lane)?.kind == .spectrum else { throw EditError.laneKindMismatch }
        guard at >= 0, length >= 1 else { throw EditError.badIndex }
        guard style.isValid else { throw EditError.spectrumStyleRange }
        if let k = sourceKey, !audioClips.contains(where: { $0.lineageKey == k }) { throw EditError.spectrumUnknownSource }
        let inLane = spectra(inLane: lane)
        if inLane.contains(where: { $0.start <= at && at < $0.end }) { throw EditError.spectrumNoRoom }
        let next = inLane.filter { $0.start > at }.map(\.start).min() ?? Int.max
        let len = min(length, next - at)
        guard len >= 1 else { throw EditError.spectrumNoRoom }
        let item = SpectrumItem(id: id, lane: lane, start: at, length: len, sourceKey: sourceKey, style: style)
        return try checked(rebuilt(spectra: spectra + [item], duration: max(durationFrames, item.end)))
    }
    /// 소리 클립에서 만들기: 그 클립의 계보를 소스로, 그 클립 구간 그대로. 알맞은 스펙트럼 레인이 없으면 바깥쪽(자막 바로 아래)에 새 레인을 만든다.
    public func addingSpectrum(fromAudioClip clipID: UUID, style: SpectrumItemStyle = .provisionalDefault, id: UUID = UUID(), newLaneID: UUID = UUID(),
                               newLaneName: String) throws -> Timeline {
        guard let c = audioClips.first(where: { $0.id == clipID }) else { throw EditError.audioNotAudioClip }
        func fits(_ l: UUID) -> Bool { !spectra(inLane: l).contains { $0.start < c.end && c.start < $0.end } }
        if let l = lanesFromBoundary(.spectrum).map(\.id).first(where: fits) {
            return try addingSpectrum(lane: l, at: c.start, length: c.length, sourceKey: c.lineageKey, style: style, id: id)
        }
        return try addingLane(.spectrum, name: newLaneName, id: newLaneID, outward: true)
            .addingSpectrum(lane: newLaneID, at: c.start, length: c.length, sourceKey: c.lineageKey, style: style, id: id)
    }
    /// 소스 바꾸기(정보 패널 목록): 이 타임라인의 계보 키 또는 nil(고르지 않음)
    public func settingSpectrumSource(_ id: UUID, _ key: UUID?) throws -> Timeline {
        guard let i = spectra.firstIndex(where: { $0.id == id }) else { throw EditError.unknownClip }
        if let k = key, !audioClips.contains(where: { $0.lineageKey == k }) { throw EditError.spectrumUnknownSource }
        var s = spectra; s[i] = s[i].with(sourceKey: .some(key))
        return try checked(rebuilt(spectra: s))
    }
    public func settingSpectrumStyle(_ id: UUID, _ style: SpectrumItemStyle) throws -> Timeline {
        guard let i = spectra.firstIndex(where: { $0.id == id }) else { throw EditError.unknownClip }
        guard style.isValid else { throw EditError.spectrumStyleRange }
        var s = spectra; s[i] = s[i].with(style: style)
        return try checked(rebuilt(spectra: s))
    }
    /// 옮기기(리플 없음): 시작과 스펙트럼 레인을 바꾼다. 겹치면 거부. 소스는 따라 움직이지 않는다(독립 클립).
    public func relocatingSpectrum(_ id: UUID, toStart: Int? = nil, lane: UUID? = nil) throws -> Timeline {
        guard let c = spectrum(id) else { throw EditError.unknownClip }
        let l = lane ?? c.lane, st = toStart ?? c.start
        guard laneInfo(l)?.kind == .spectrum else { throw EditError.laneKindMismatch }
        guard st >= 0 else { throw EditError.badIndex }
        let m = c.with(lane: l, start: st)
        if spectra(inLane: l).contains(where: { $0.id != id && $0.start < m.end && m.start < $0.end }) { throw EditError.overlap }
        return try checked(rebuilt(spectra: spectra.map { $0.id == id ? m : $0 }, duration: max(durationFrames, m.end)))
    }
    /// 끌어 옮기기 붙음(2026-10-26, SP-1A 2C-1): 스펙트럼을 delta(포인터에서 잰 소수 프레임)만큼 옮길 때 그 시작·끝이 붙을 곳 — 0, 영상·소리 클립의
    /// 시작·끝, 다른 스펙트럼의 시작·끝, extra — 에서 threshold 프레임 안이면 가장 가까운 곳에 붙인 정수 delta와 붙은 위치를 돌려준다. 없으면 (반올림한 delta, nil).
    /// 규칙은 snappedSubtitleDelta·snappedDelta와 같다(거리는 반올림 전 값, 같은 거리면 앞선 후보 — 시작 쪽, 작은 위치). 자막 경계에는 붙지 않는다(2C 결정 6:
    /// 스펙트럼 전용 계산, 다른 종류의 붙음은 바꾸지 않음). 시작이 0보다 앞서는 붙음은 고르지 않는다. 숫자가 아니거나 아주 큰 delta는 넘치지 않게 제한한다.
    public func snappedSpectrumDelta(_ id: UUID, delta raw: Double, threshold: Double, extra: [Int] = []) -> (delta: Int, snap: Int?) {
        let raw = raw.isFinite ? min(max(raw, -1e9), 1e9) : 0
        let delta = Int(raw.rounded())
        guard let c = spectrum(id), threshold > 0 else { return (delta, nil) }
        var targets = Set([0] + extra)
        for o in clips + audioClips { targets.insert(o.start); targets.insert(o.end) }
        for o in spectra where o.id != id { targets.insert(o.start); targets.insert(o.end) }
        var best: (dist: Double, delta: Int, snap: Int)?
        for edge in [c.start, c.end] {
            for t in targets.sorted() {
                let d = t - edge, dist = abs(Double(edge) + raw - Double(t))
                guard dist <= threshold, c.start + d >= 0 else { continue }
                if best == nil || dist < best!.dist { best = (dist, d, t) }
            }
        }
        return best.map { ($0.delta, $0.snap) } ?? (delta, nil)
    }
    /// 트림(리플 없음): 보이는 구간을 [start, end)로. 최소 1프레임, 겹치면 거부.
    public func trimmingSpectrum(_ id: UUID, start: Int, end: Int) throws -> Timeline {
        guard let c = spectrum(id) else { throw EditError.unknownClip }
        guard end - start >= 1 else { throw EditError.tooShort }
        guard start >= 0 else { throw EditError.badIndex }
        let m = c.with(start: start, length: end - start)
        if spectra(inLane: c.lane).contains(where: { $0.id != id && $0.start < m.end && m.start < $0.end }) { throw EditError.overlap }
        return try checked(rebuilt(spectra: spectra.map { $0.id == id ? m : $0 }, duration: max(durationFrames, m.end)))
    }
    /// 일반 삭제: 빈틈을 남긴다.
    public func liftingSpectrum(_ id: UUID) throws -> Timeline {
        guard spectrum(id) != nil else { throw EditError.unknownClip }
        return rebuilt(spectra: spectra.filter { $0.id != id })
    }
}
