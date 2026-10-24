import Foundation
@testable import OnTheFrameEngine
import XCTest

// 스펙트럼 타당성 검사 시제품(2026-10-24, docs/SPECTRUM-DESIGN.md §9) — 제품 코드가 아니다. 시험 대상 안에만 있고 기본 실행에서는 건너뛴다
// (OTF_SPECTRUM_PROTO=1일 때만). 편집기 화면·저장 형식에는 연결하지 않았다.

/// 시제품: 오디오 클립의 계보 키(자른 조각은 원래 클립의 키를 이어받고, 붙여 넣은 복사본은 새 키). 제품 제안은 `Clip.origin`(저장되는 값)이다 —
/// 여기서는 타임라인 옆의 표로 흉내 내고, 편집 함수를 감싼 곳에서만 갱신한다.
struct ProtoLinkedTimeline: Equatable {
    var timeline: Timeline
    var origin: [UUID: UUID] = [:]
    func key(of id: UUID) -> UUID { origin[id] ?? id }

    /// 자르기: 오디오 쪽에 새로 생긴 조각은 사라진 조각의 키를 이어받는다(연결된 짝의 새 ID도 같은 규칙으로 찾는다)
    mutating func split(_ id: UUID, at f: Int) throws {
        let before = timeline
        timeline = try timeline.splitting(clip: id, atFrame: f)
        inherit(from: before)
    }
    /// 붙여넣기: 새 클립은 새 키(원래 소스에 조용히 붙지 않음)
    mutating func paste(_ c: ClipboardContent, at f: Int) throws -> [UUID: UUID] {
        let r = try timeline.pasting(c, at: f, newLaneName: { $0 == .video ? "V" : "A" })
        timeline = r.timeline
        return r.ids
    }
    private mutating func inherit(from before: Timeline) {
        let oldIDs = Set(before.audioClips.map(\.id)), newIDs = Set(timeline.audioClips.map(\.id))
        let gone = before.audioClips.filter { !newIDs.contains($0.id) }
        for c in timeline.audioClips where !oldIDs.contains(c.id) {
            if let parent = gone.first(where: { $0.mediaID == c.mediaID && $0.sourceIn <= c.sourceIn && c.sourceOut <= $0.sourceOut }) {
                origin[c.id] = key(of: parent.id)
            }
        }
    }
}

/// 시제품: 키별 조각 색인(편집마다 한 번 만듦). 프레임마다 모든 클립을 훑지 않고 이분 탐색 + 겹침 꼬리만 본다.
struct ProtoSourceIndex {
    struct Piece: Equatable { let id: UUID; let lane: UUID; let start: Int; let end: Int; let sourceIn: Int; let mediaID: UUID }
    enum Resolution: Equatable { case missing, inactive, active(Piece), ambiguous([UUID]) }
    private var byKey: [UUID: (pieces: [Piece], maxEnd: [Int])] = [:]
    init(_ lt: ProtoLinkedTimeline) {
        var groups: [UUID: [Piece]] = [:]
        for c in lt.timeline.audioClips {
            groups[lt.key(of: c.id), default: []].append(Piece(id: c.id, lane: c.lane ?? UUID(), start: c.start, end: c.end, sourceIn: c.sourceIn, mediaID: c.mediaID))
        }
        for (k, ps) in groups {
            let s = ps.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            var m = 0, mx: [Int] = []
            for p in s { m = max(m, p.end); mx.append(m) }
            byKey[k] = (s, mx)
        }
    }
    /// 프레임 f에서 키의 소스: 없음(그 키의 조각이 하나도 없음) / 조각 없음(이 시각을 덮는 조각 없음 — 유효하지만 무음) / 조각 하나 / 겹침(둘 이상, 고르지 않음)
    func resolve(_ key: UUID, frame f: Int) -> Resolution {
        guard let g = byKey[key] else { return .missing }
        var lo = 0, hi = g.pieces.count   // start ≤ f인 마지막 조각
        while lo < hi { let mid = (lo + hi) / 2; if g.pieces[mid].start <= f { lo = mid + 1 } else { hi = mid } }
        var hits: [Piece] = []
        var j = lo - 1
        while j >= 0, g.maxEnd[j] > f { if g.pieces[j].end > f { hits.append(g.pieces[j]) }; j -= 1 }
        switch hits.count { case 0: return .inactive; case 1: return .active(hits[0]); default: return .ambiguous(hits.map(\.id).sorted { $0.uuidString < $1.uuidString }) }
    }
    /// 겹치는 프레임 구간이 있는 키(타임라인 경고·내보내기 판정용)
    func overlaps(_ key: UUID) -> Bool {
        guard let g = byKey[key] else { return false }
        for i in 1..<max(1, g.pieces.count) where g.pieces[i].start < g.maxEnd[i - 1] { return true }
        return false
    }
}

final class SpectrumLinkPrototypeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OTF_SPECTRUM_PROTO"] == "1", "스펙트럼 시제품 검사는 OTF_SPECTRUM_PROTO=1일 때만")
    }
    let m = UUID()
    /// 소리만 있는 미디어 600프레임, 오디오 클립 하나(0…600)
    func base() throws -> (ProtoLinkedTimeline, UUID) {
        let ref = MediaRef(id: m, name: "tone.wav", path: "/media/tone.wav", frameCount: 600, hasAudio: true, size: 1, modifiedNs: 1, codec: "lpcm", width: 0, height: 0, hasVideo: false)
        var t = Timeline(media: [ref], mediaFrames: [m: 600], mediaHasAudio: [m: true], mediaHasVideo: [m: false])
        let a = t.lanes(.audio).first!.id, cid = UUID()
        t = try t.appending(media: m, videoLane: nil, audioLane: a, clipID: cid, audioClipID: cid)
        return (ProtoLinkedTimeline(timeline: t), cid)
    }
    /// 어떤 프레임에서 원본 시각(프레임)
    func source(_ r: ProtoSourceIndex.Resolution, _ f: Int) -> Int? { if case .active(let p) = r { return p.sourceIn + (f - p.start) } else { return nil } }

    func testRepeatedSplitsKeepLinkageAndSourceTime() throws {
        var (lt, cid) = try base()
        let key = lt.key(of: cid)
        try lt.split(cid, at: 200)
        let right = lt.timeline.audioClips.first { $0.start == 200 }!.id
        try lt.split(right, at: 450)
        XCTAssertEqual(lt.timeline.audioClips.count, 3)
        XCTAssertTrue(lt.timeline.audioClips.allSatisfy { lt.key(of: $0.id) == key }, "세 조각 모두 같은 키")
        let ix = ProtoSourceIndex(lt)
        for f in [0, 199, 200, 449, 450, 599] { XCTAssertEqual(source(ix.resolve(key, frame: f), f), f, "frame \(f)") }   // 원래와 같은 원본 시각
        XCTAssertEqual(ix.resolve(key, frame: 600), .inactive)
        XCTAssertFalse(ix.overlaps(key))
    }

    func testMoveTrimCopyDeleteUndoAndOverlap() throws {
        var (lt, cid) = try base()
        let key = lt.key(of: cid)
        try lt.split(cid, at: 300)
        let left = lt.timeline.audioClips.first { $0.start == 0 }!.id, right = lt.timeline.audioClips.first { $0.start == 300 }!.id
        // 옮기기: 오른쪽 조각을 1000으로 → 300…599는 조각 없음(유효·무음), 1000…1299는 원본 300…599
        lt.timeline = try lt.timeline.relocating(clip: right, toStart: 1000)
        var ix = ProtoSourceIndex(lt)
        XCTAssertEqual(ix.resolve(key, frame: 450), .inactive)
        XCTAssertEqual(source(ix.resolve(key, frame: 1000), 1000), 300); XCTAssertEqual(source(ix.resolve(key, frame: 1299), 1299), 599)
        // 트림: 왼쪽 조각 앞을 50 잘라 냄(이 앱의 앞 트림은 리플 — 클립은 0에 있고 원본 시작이 50으로). 원본 0…49는 더 이상 어디에도 없음
        lt.timeline = try lt.timeline.trimmingStart(clip: left, by: 50)
        let lc = try XCTUnwrap(lt.timeline.clip(left))
        XCTAssertEqual(lc.sourceIn, 50)
        ix = ProtoSourceIndex(lt)
        XCTAssertEqual(source(ix.resolve(key, frame: lc.start), lc.start), 50); XCTAssertEqual(source(ix.resolve(key, frame: lc.start + 10), lc.start + 10), 60)
        XCTAssertEqual(ix.resolve(key, frame: lc.end), .inactive)
        // 복사·붙여넣기: 복사본은 새 키 — 원래 키에 붙지 않음
        let ids = try lt.paste(try lt.timeline.copying(clip: left), at: 2000)
        let copy = try XCTUnwrap(ids[left])
        XCTAssertNotEqual(lt.key(of: copy), key)
        ix = ProtoSourceIndex(lt)
        XCTAssertEqual(ix.resolve(key, frame: 2010), .inactive, "원래 키는 복사본 자리에서 소리 없음")
        // 삭제 → 없음(키의 조각이 하나도 없음), 실행 취소(같은 스냅샷) → 다시 이어짐(같은 ID)
        let snapshot = lt
        lt.timeline = try lt.timeline.lifting(clip: left).lifting(clip: right)
        XCTAssertEqual(ProtoSourceIndex(lt).resolve(key, frame: 100), .missing)
        lt = snapshot
        XCTAssertEqual(source(ProtoSourceIndex(lt).resolve(key, frame: lc.start + 100), lc.start + 100), 150)
        // 저장·다시 열기(시제품: 표를 JSON으로 왕복 — 제품은 Clip.origin을 저장)
        let tBack = try ProjectFile.decode(try ProjectFile.encode(lt.timeline, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)).timeline
        let oBack = try JSONDecoder().decode([UUID: UUID].self, from: try JSONEncoder().encode(lt.origin))
        XCTAssertEqual(ProtoLinkedTimeline(timeline: tBack, origin: oBack), lt)
        // 다른 레인으로 옮겨 겹침: 오른쪽 조각을 새 오디오 레인의 100으로 → 100…299는 두 조각이 덮음 → 겹침(고르지 않음)
        lt.timeline = try lt.timeline.addingLane(.audio, name: "A2", outward: true)
        let a2 = lt.timeline.lanes(.audio).last!.id
        lt.timeline = try lt.timeline.relocating(clip: right, toStart: 100, lane: a2)
        ix = ProtoSourceIndex(lt)
        XCTAssertTrue(ix.overlaps(key))
        if case .ambiguous(let ids) = ix.resolve(key, frame: 150) { XCTAssertEqual(Set(ids), [left, right]) } else { XCTFail("겹침이어야 함") }
        XCTAssertEqual(source(ix.resolve(key, frame: 60), 60), 110)   // 겹치지 않는 곳은 그대로(왼쪽 조각, 원본 = 50 + 60)
    }

    /// 조각이 많아도 프레임마다 전체를 훑지 않는다: 오디오 클립 4000개에서 프레임 10만 번 찾기
    func testIndexLookupDoesNotScanAllClips() throws {
        var t = Timeline(mediaFrames: [m: 1_000_000], mediaHasAudio: [m: true], mediaHasVideo: [m: false])
        let a = t.lanes(.audio).first!.id
        var clips = t.audioClips
        for i in 0..<4000 { clips.append(Clip(id: UUID(), mediaID: m, start: i * 30, sourceIn: i * 30, length: 30, lane: a)) }
        t = t.rebuilt(audio: clips)
        var lt = ProtoLinkedTimeline(timeline: t)
        let key = UUID()
        for c in t.audioClips { lt.origin[c.id] = key }   // 모두 한 계보(거듭 자른 결과와 같은 모양)
        let t0 = Date()
        let ix = ProtoSourceIndex(lt)
        let build = Date().timeIntervalSince(t0)
        let t1 = Date()
        var hit = 0
        for k in 0..<100_000 { if case .active = ix.resolve(key, frame: (k * 7919) % 120_000) { hit += 1 } }
        let look = Date().timeIntervalSince(t1)
        print("PROTO index build \(String(format: "%.1f", build * 1000)) ms, 100k lookups \(String(format: "%.1f", look * 1000)) ms, hits \(hit)")
        XCTAssertEqual(hit, 100_000)
        XCTAssertLessThan(look, 0.5)
    }
}
