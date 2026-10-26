import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 스펙트럼 클립 모델·계보·저장(SP-1A 1단계, 2026-10-25, docs/SPECTRUM-DESIGN.md §15). 생성 fixture(otf-TA 영상, aud-wav48s 440 Hz 소리)만 쓴다.
final class SpectrumModelTests: XCTestCase {
    var fixtures: URL { ExportEndToEndTests.root.appendingPathComponent("fixtures") }
    var ta: MediaAsset!, wav: MediaAsset!
    override func setUp() async throws {
        try await DevFixtures.ensureAll(in: fixtures)
        ta = try await MediaProbe.inspect(fixtures.appendingPathComponent("otf-TA.mp4"))
        wav = try await MediaProbe.inspect(fixtures.appendingPathComponent(AudioFixture.wav.file))
    }
    /// 영상 TA 120(연결된 소리 포함) + 둘째 오디오 레인 A2에 WAV 소리 클립(20에서 길이 60 = 20–80, 연결 없음)
    func base() throws -> (Timeline, audioClip: UUID, a2: UUID) {
        let a2 = UUID(), w = UUID()
        var t = Timeline().registering(ta).registering(wav)
        t = try t.inserting(media: ta.id).addingLane(.audio, name: "A2", id: a2)
        t = try t.placing(media: wav.id, at: 20, videoLane: nil, audioLane: a2, clipID: w)
        XCTAssertEqual(t.clip(w)!.length, 60)
        XCTAssertTrue(t.isValid)
        return (t, w, a2)
    }
    func spectrumLane(_ t: Timeline) throws -> (Timeline, UUID) { let l = UUID(); return (try t.addingLane(.spectrum, name: "SP", id: l), l) }

    // MARK: 계보

    func testSplitKeepsLineageCopyIsIndependentAndUndoRestores() throws {
        var (t, w, a2) = try base()
        // 스펙트럼이 없는 보통 프로젝트의 자르기도 계보를 잇는다(P-S1 (나), 2026-10-25)
        let (pl, pr) = (UUID(), UUID())
        let plain = try t.splitting(clip: w, atFrame: 40, newIDs: (pl, pr))
        XCTAssertFalse(plain.needsSpectrumFormat)
        XCTAssertEqual(plain.clip(pl)!.lineageKey, w); XCTAssertEqual(plain.clip(pr)!.lineageKey, w, "스펙트럼이 없어도 두 조각 모두 원래 계보")
        let sl0 = UUID()
        t = try t.addingLane(.spectrum, name: "SP", id: sl0)
        let key = t.clip(w)!.lineageKey
        XCTAssertEqual(key, w)
        let (l1, r1) = (UUID(), UUID())
        t = try t.splitting(clip: w, atFrame: 40, newIDs: (l1, r1))
        XCTAssertEqual(t.clip(l1)!.lineageKey, key); XCTAssertEqual(t.clip(r1)!.lineageKey, key, "자른 두 조각 모두 원래 계보")
        let (l2, r2) = (UUID(), UUID())
        t = try t.splitting(clip: r1, atFrame: 55, newIDs: (l2, r2))
        XCTAssertEqual(Set([l1, l2, r2].map { t.clip($0)!.lineageKey }), [key], "두 번 잘라도 같은 계보")
        // 연결된 쌍(TA 영상+소리): 소리 조각은 계보를 잇고 영상 조각은 계보가 없다
        let tav = t.clips.first!.id, taAudio = t.partner(of: tav)!.id
        let (vl, vr) = (UUID(), UUID())
        let t2 = try t.splitting(clip: tav, atFrame: 60, newIDs: (vl, vr))
        XCTAssertNil(t2.clip(vl)!.origin); XCTAssertNil(t2.clip(vr)!.origin)
        XCTAssertEqual(Set(t2.audioClips.filter { $0.mediaID == ta.id }.map(\.lineageKey)), [taAudio])
        // 옮기기는 계보를 바꾸지 않는다(트림·변형·소리 설정도 같은 with 경로)
        let moved = try t.relocating(clip: l2, toStart: 80, lane: a2)
        XCTAssertEqual(moved.clip(l2)!.lineageKey, key)
        XCTAssertEqual(try moved.settingClipAudio(clip: l2, volumePercent: 40).clip(l2)!.lineageKey, key)
        // 복사·붙여넣기: 새 계보
        let pasted = try t.pasting(try t.copying(clip: l1), at: 100) { _ in "A" }
        let newID = pasted.ids[l1]!
        XCTAssertNil(pasted.timeline.clip(newID)!.origin); XCTAssertEqual(pasted.timeline.clip(newID)!.lineageKey, newID)
        XCTAssertNotEqual(pasted.timeline.clip(newID)!.lineageKey, key, "복사한 소리는 원래 소스에 붙지 않음")
        // 지우면 소스 없음, 실행 취소로 같은 ID·계보가 되살아남
        var withSpec = try t.addingSpectrum(lane: sl0, at: 20, length: 50, sourceKey: key)
        let sid = withSpec.spectra[0].id
        var h = EditHistory(withSpec)
        for id in [l1, l2, r2] { withSpec = try withSpec.lifting(clip: id) }
        h.apply(withSpec, focus: nil)
        XCTAssertEqual(h.timeline.spectrumSourceState(h.timeline.spectrum(sid)!), .missing)
        h.undo()
        XCTAssertEqual(h.timeline.spectrumSourceState(h.timeline.spectrum(sid)!), .ok)
        XCTAssertEqual(h.timeline.spectrumSource(key: key)!.pieces.map(\.id).sorted { $0.uuidString < $1.uuidString }, [l1, l2, r2].sorted { $0.uuidString < $1.uuidString })
    }

    /// P-S1 (나): 스펙트럼이 하나도 없는 타임라인에서 자르기·옮기기·트림·소리 설정·리플·레인 이동이 계보를 지키고, 붙여넣기는 새 계보,
    /// 실행 취소·다시 실행은 같은 계보로 되돌린다.
    func testLineageWithoutSpectrumAcrossEditsCopyUndoRedo() throws {
        var (t, w, a2) = try base()
        XCTAssertFalse(t.needsSpectrumFormat)
        // A. 단독 소리를 두 번 자름: A2 = l1 [20,40) l2 [40,60) r2 [60,80)
        let (l1, r1) = (UUID(), UUID()), (l2, r2) = (UUID(), UUID())
        t = try t.splitting(clip: w, atFrame: 40, newIDs: (l1, r1)).splitting(clip: r1, atFrame: 60, newIDs: (l2, r2))
        XCTAssertFalse(t.needsSpectrumFormat)
        XCTAssertEqual([l1, l2, r2].map { t.clip($0)!.lineageKey }, [w, w, w])
        XCTAssertEqual(t.spectrumSource(key: w)!.pieces.map(\.id), [l1, l2, r2])
        // 연결 쌍(TA 영상+소리 [0,120)): 소리 조각만 계보를 잇고 영상 조각은 계보가 없다
        let tav = t.clips[0].id, taA = t.partner(of: tav)!.id
        let (vl, vr) = (UUID(), UUID())
        t = try t.splitting(clip: tav, atFrame: 90, newIDs: (vl, vr))
        XCTAssertTrue(t.clips.allSatisfy { $0.origin == nil }, "영상 조각에는 계보 없음")
        XCTAssertEqual(t.audioClips.filter { $0.mediaID == ta.id }.count, 2)
        XCTAssertEqual(Set(t.audioClips.filter { $0.mediaID == ta.id }.map(\.lineageKey)), [taA])
        XCTAssertEqual(t.partner(of: vr)!.lineageKey, taA); XCTAssertEqual(t.partner(of: vl)!.lineageKey, taA)
        XCTAssertEqual(t.spectrumSources().count, 2, "계보 둘(WAV·TA 소리), 조각 다섯")
        // B. 편집 뒤에도 남은 모든 소리 조각의 계보가 같다
        let keys = Dictionary(uniqueKeysWithValues: t.audioClips.map { ($0.id, $0.lineageKey) })
        func same(_ name: String, _ x: Timeline, added: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(x.isValid, name, file: file, line: line)
            XCTAssertTrue(x.clips.allSatisfy { $0.origin == nil }, "\(name): 영상 계보 없음", file: file, line: line)
            for c in x.audioClips where keys[c.id] != nil { XCTAssertEqual(c.lineageKey, keys[c.id], "\(name): \(c.id)", file: file, line: line) }
            XCTAssertEqual(x.audioClips.filter { keys[$0.id] != nil }.count, keys.count, "\(name): 원래 조각 모두 남음", file: file, line: line)
            XCTAssertEqual(x.audioClips.count, keys.count + added, name, file: file, line: line)
        }
        let a3 = UUID()
        let moved = try t.relocating(clip: r2, toStart: 100)
        XCTAssertEqual(moved.clip(r2)!.start, 100); same("move", moved)
        let laneMoved = try t.addingLane(.audio, name: "A3", id: a3).relocating(clip: l2, lane: a3)
        XCTAssertEqual(laneMoved.clip(l2)!.lane, a3); same("lane move", laneMoved)
        let trimmedEnd = try t.trimmingEnd(clip: vr, by: -10)
        XCTAssertEqual(trimmedEnd.partner(of: vr)!.length, 20); same("trim end (linked)", trimmedEnd)
        let trimmedStart = try t.trimmingStart(clip: vr, by: 5)
        XCTAssertEqual(trimmedStart.partner(of: vr)!.sourceIn, 95); same("trim start (linked)", trimmedStart)
        let tuned = try t.settingClipAudio(clip: l2, volumePercent: 40, muted: true, fadeInFrames: 5, fadeOutFrames: 5)
        XCTAssertEqual(tuned.clip(l2)!.effectiveAudio.volumePercent, 40); same("audio settings", tuned)
        let rippled = try t.inserting(media: ta.id, at: 0)   // 맨 앞 리플 삽입: 모두 120 밀림
        XCTAssertEqual(rippled.clip(l1)!.start, 140); same("ripple insert", rippled, added: 1)
        let reordered = try t.moving(clip: vr, toIndex: 0)   // 끼워 넣기 이동(리플 삭제 + 리플 삽입)
        XCTAssertEqual(reordered.clip(vr)!.start, 0); same("ripple move", reordered)
        _ = a2
        // C. 자른 조각 복사·붙여넣기: 새 계보, 원래 조각은 그대로. 붙여넣은 조각을 자르면 그 새 계보를 잇는다
        var h = EditHistory(t)
        let pasted = try t.pasting(try t.copying(clip: l2), at: 200) { _ in "A" }
        let p = pasted.ids[l2]!
        h.apply(pasted.timeline, focus: p)
        XCTAssertNil(h.timeline.clip(p)!.origin); XCTAssertEqual(h.timeline.clip(p)!.lineageKey, p)
        XCTAssertEqual([l1, l2, r2].map { h.timeline.clip($0)!.lineageKey }, [w, w, w])
        XCTAssertEqual(h.timeline.spectrumSource(key: w)!.pieces.map(\.id), [l1, l2, r2], "붙여넣은 조각은 원래 소스에 들지 않음")
        let (pl, pr) = (UUID(), UUID())
        let pastedSplit = try h.timeline.splitting(clip: p, atFrame: 210, newIDs: (pl, pr))
        XCTAssertEqual([pl, pr].map { pastedSplit.clip($0)!.lineageKey }, [p, p])
        h.apply(pastedSplit, focus: pr)
        h.undo(); XCTAssertEqual(h.timeline, pasted.timeline)
        h.undo(); XCTAssertEqual(h.timeline, t); XCTAssertNil(h.timeline.clip(p))
        h.redo(); XCTAssertEqual(h.timeline, pasted.timeline); XCTAssertEqual(h.timeline.clip(p)!.lineageKey, p)
        h.redo(); XCTAssertEqual(h.timeline, pastedSplit)
        // 자기 ID와 같은 origin은 nil로 맞춤(키는 같음)
        let self0 = UUID()
        XCTAssertNil(Clip(id: self0, mediaID: wav.id, start: 0, sourceIn: 0, length: 1, origin: self0).origin)
    }

    /// P-S1 (나) 저장: 스펙트럼 없이 자른 소리 → 형식 8 저장·다시 열기·다시 저장이 같다. 실행 취소로 계보가 없어지면 형식 5, 다시 실행하면 8.
    func testLineagePersistenceResaveUndoRedo() throws {
        let (t0, w, _) = try base()
        let pid = UUID()
        func roundTrip(_ t: Timeline) throws -> (timeline: Timeline, version: Int, data: Data) {
            let d = try ProjectFile.encode(t, projectID: pid, settings: .m1, bookmarks: [:], projectURL: nil)
            let r = try ProjectFile.decode(d)
            return (r.timeline, r.document.version, d)
        }
        let (l, r) = (UUID(), UUID())
        let split = try t0.splitting(clip: w, atFrame: 50, newIDs: (l, r))
        let first = try roundTrip(split)
        XCTAssertEqual(first.version, 8); XCTAssertEqual(first.timeline, split)
        let second = try roundTrip(first.timeline)
        XCTAssertEqual(second.version, 8); XCTAssertEqual(second.timeline, split); XCTAssertEqual(second.data, first.data, "다시 저장해도 같은 내용")
        XCTAssertEqual([l, r].map { second.timeline.clip($0)!.lineageKey }, [w, w])
        // 다시 연 뒤 자르기도 같은 계보
        let (l3, r3) = (UUID(), UUID())
        let again = try second.timeline.splitting(clip: r, atFrame: 65, newIDs: (l3, r3))
        XCTAssertEqual([l, l3, r3].map { again.clip($0)!.lineageKey }, [w, w, w])
        // 실행 취소·다시 실행
        var h = EditHistory(t0)
        h.apply(split, focus: r)
        h.undo()
        XCTAssertEqual(h.timeline, t0); XCTAssertEqual(try roundTrip(h.timeline).version, 5, "계보가 없어지면 형식 5")
        h.redo()
        XCTAssertEqual(h.timeline, split)
        let redone = try roundTrip(h.timeline)
        XCTAssertEqual(redone.version, 8); XCTAssertEqual(redone.timeline, split)
        // 스펙트럼을 만들었다 지우고 레인까지 지워도 남은 계보는 형식 8로 남는다
        let (ts, sl) = try spectrumLane(split)
        let withSpec = try ts.addingSpectrum(lane: sl, at: 20, length: 60, sourceKey: w)
        let cleared = try withSpec.liftingSpectrum(withSpec.spectra[0].id).removingLane(sl)
        XCTAssertFalse(cleared.needsSpectrumFormat)
        let back = try roundTrip(cleared)
        XCTAssertEqual(back.version, 8); XCTAssertEqual(back.timeline, cleared); XCTAssertEqual(back.timeline, split)
    }

    /// 이전 파일(계보 없음): 같은 미디어·이어지는 원본 구간의 조각이어도 계보를 추측해 묶지 않는다(소유자 결정 2026-10-25).
    /// 손대지 않고 다시 저장하면 형식·내용이 그대로이고, 그 뒤 자른 조각만 자른 클립의 계보를 잇는다.
    func testLegacyFragmentsKeepIdentitiesAndFormat() throws {
        let (t0, w, a2) = try base()
        // 이전 앱이 자른 모양: WAV [20,40) 원본 0 + [40,80) 원본 20, 계보 없음
        let (x, y) = (UUID(), UUID())
        let legacyT = t0.rebuilt(audio: t0.audioClips.filter { $0.id != w } + [Clip(id: x, mediaID: wav.id, start: 20, sourceIn: 0, length: 20, lane: a2),
                                                                              Clip(id: y, mediaID: wav.id, start: 40, sourceIn: 20, length: 40, lane: a2)])
        XCTAssertTrue(legacyT.isValid)
        let pid = UUID()
        let file = try ProjectFile.encode(legacyT, projectID: pid, settings: .m1, bookmarks: [:], projectURL: nil)
        XCTAssertFalse(String(decoding: file, as: UTF8.self).contains("\"origin\""))
        for v in [5, 6, 7] {   // 같은 내용을 형식 5·6·7로 적은 이전 파일
            var j = try JSONSerialization.jsonObject(with: file) as! [String: Any]; j["version"] = v
            let (opened, doc) = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: j))
            XCTAssertEqual(doc.version, v); XCTAssertEqual(opened, legacyT)
            XCTAssertNotEqual(opened.clip(x)!.lineageKey, opened.clip(y)!.lineageKey, "v\(v): 이전 조각은 따로")
            XCTAssertNil(opened.spectrumSource(key: x)!.pieces.first { $0.id == y })
            // 손대지 않고 다시 저장: 형식 올리지 않음(내용에 맞는 형식 5), 바이트 같음
            let resaved = try ProjectFile.encode(opened, projectID: pid, settings: .m1, bookmarks: [:], projectURL: nil)
            XCTAssertEqual(try ProjectFile.decode(resaved).document.version, 5); XCTAssertEqual(resaved, file)
        }
        // 이전 조각 하나를 자르면: 새 조각 둘은 그 조각의 계보, 다른 이전 조각은 그대로 → 형식 8
        let (yl, yr) = (UUID(), UUID())
        let split = try legacyT.splitting(clip: y, atFrame: 60, newIDs: (yl, yr))
        XCTAssertEqual([yl, yr].map { split.clip($0)!.lineageKey }, [y, y])
        XCTAssertEqual(split.clip(x)!.lineageKey, x); XCTAssertNil(split.clip(x)!.origin)
        XCTAssertEqual(ProjectFile.version(for: split), 8)
        XCTAssertEqual(try ProjectFile.decode(try ProjectFile.encode(split, projectID: pid, settings: .m1, bookmarks: [:], projectURL: nil)).timeline, split)
    }

    /// 스펙트럼을 만들기 전에 자른 조각도 하나의 소스: 그 계보를 고른 스펙트럼은 두 조각을 모두 쓰고, 저장·다시 열기 뒤에도 소스가 맞는다.
    /// 같은 계보 조각이 같은 시각에 겹치면 정상으로 보지 않는다(D-S8).
    func testSpectrumSourceSplitBeforeSpectrumSurvivesSave() throws {
        let (t0, w, _) = try base()
        let (l, r) = (UUID(), UUID())
        let split = try t0.splitting(clip: w, atFrame: 45, newIDs: (l, r))
        let (t1, sl) = try spectrumLane(split)
        let t = try t1.addingSpectrum(lane: sl, at: 20, length: 60, sourceKey: w)
        let s = t.spectra[0]
        XCTAssertEqual(t.spectrumSource(key: w)!.pieces.map(\.id), [l, r])
        XCTAssertEqual(Set(t.spectrumPieces(s).map(\.start)), [20, 45])
        XCTAssertEqual(t.spectrumSourceState(s), .ok); XCTAssertEqual(t.spectrumExportBlockers(), [])
        XCTAssertEqual(try t1.addingSpectrum(fromAudioClip: r, newLaneName: "SP").spectra[0].sourceKey, w, "조각에서 만들어도 같은 소스")
        let (back, doc) = try ProjectFile.decode(try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil))
        XCTAssertEqual(doc.version, 8); XCTAssertEqual(back, t)
        let bs = back.spectrum(s.id)!
        XCTAssertEqual(bs.sourceKey, w); XCTAssertEqual(back.spectrumSourceState(bs), .ok)
        XCTAssertEqual(back.spectrumSource(key: w)!.pieces.map(\.id), [l, r])
        // 오른쪽 조각을 다른 레인으로 옮겨 왼쪽과 겹치게 → 겹침, 내보내기 막음
        let a3 = UUID()
        let o = try back.addingLane(.audio, name: "A3", id: a3).relocating(clip: r, toStart: 30, lane: a3)
        XCTAssertEqual(o.spectrumFrameState(o.spectrum(s.id)!, atFrame: 35), .overlap)
        guard case .overlappingSource(let os)? = o.spectrumExportBlockers().first?.reason else { return XCTFail("\(o.spectrumExportBlockers())") }
        XCTAssertEqual(os.map(\.range), [30..<45])
    }

    // MARK: 레인·편집

    func testSpectrumLanesOrderAndEditing() throws {
        var (t, w, _) = try base()
        let sub = UUID()
        t = try t.addingLane(.subtitle, name: "S", id: sub)
        let (t1, sp1) = try spectrumLane(t)
        let sp2 = UUID()
        t = try t1.addingLane(.spectrum, name: "SP2", id: sp2, outward: true)
        XCTAssertEqual(t.lanes.map(\.kind), [.subtitle, .spectrum, .spectrum, .video, .audio, .audio])
        XCTAssertEqual(t.laneLabel(sp1), "SP1"); XCTAssertEqual(t.laneLabel(sp2), "SP2"); XCTAssertNil(t.pairedLane(of: sp1))
        let nv = UUID()
        let tv = try t.addingLane(.video, name: "V2", id: nv, outward: true)
        XCTAssertEqual(tv.lanes.firstIndex { $0.id == nv }, 3, "새 바깥 영상 레인은 스펙트럼 레인 바로 아래")
        // 잘못된 순서는 불변식이 거부
        XCTAssertFalse(Timeline(clips: t.clips, audioClips: t.audioClips, lanes: [t.lanes[3], t.lanes[1]] + Array(t.lanes[4...]), media: t.media, mediaFrames: t.mediaFrames).isValid)
        // 만들기·옮기기·트림·삭제·소스·모양
        let key = t.clip(w)!.lineageKey
        t = try t.addingSpectrum(lane: sp1, at: 10, length: 40, sourceKey: key)
        let s1 = t.spectra[0].id
        XCTAssertThrowsError(try t.addingSpectrum(lane: sp1, at: 20, sourceKey: nil)) { XCTAssertEqual($0 as? EditError, .spectrumNoRoom) }
        let t5 = try t.addingSpectrum(lane: sp1, at: 0, length: 300, sourceKey: nil)
        XCTAssertEqual(t5.spectra.first { $0.start == 0 }!.length, 10, "다음 스펙트럼 앞까지 줄임")
        XCTAssertThrowsError(try t.addingSpectrum(lane: w, at: 0, sourceKey: nil)) { XCTAssertEqual($0 as? EditError, .laneKindMismatch) }
        XCTAssertThrowsError(try t.addingSpectrum(lane: sp2, at: 0, sourceKey: UUID())) { XCTAssertEqual($0 as? EditError, .spectrumUnknownSource) }
        t = try t.relocatingSpectrum(s1, toStart: 60, lane: sp2)
        XCTAssertEqual(t.spectrum(s1)!.lane, sp2); XCTAssertEqual(t.spectrum(s1)!.start, 60)
        t = try t.trimmingSpectrum(s1, start: 65, end: 90)
        XCTAssertEqual(t.spectrum(s1)!.length, 25)
        XCTAssertThrowsError(try t.trimmingSpectrum(s1, start: 70, end: 70)) { XCTAssertEqual($0 as? EditError, .tooShort) }
        t = try t.settingSpectrumSource(s1, nil)
        XCTAssertEqual(t.spectrumSourceState(t.spectrum(s1)!), .unset)
        XCTAssertThrowsError(try t.settingSpectrumSource(s1, UUID())) { XCTAssertEqual($0 as? EditError, .spectrumUnknownSource) }
        var bad = SpectrumItemStyle.provisionalDefault; bad.thicknessMilli = 0
        XCTAssertThrowsError(try t.settingSpectrumStyle(s1, bad)) { XCTAssertEqual($0 as? EditError, .spectrumStyleRange) }
        bad = .provisionalDefault; bad.highHz = 30_000
        XCTAssertThrowsError(try t.settingSpectrumStyle(s1, bad))
        var analog = SpectrumItemStyle.provisionalDefault; analog.mode = .analog; analog.sides = .below
        t = try t.settingSpectrumStyle(s1, analog)
        XCTAssertEqual(t.spectrum(s1)!.style.renderStyle.mode, .analog)
        XCTAssertEqual(try t.liftingSpectrum(s1).spectra.count, 0)
        // 레인을 지우면 그 스펙트럼도 지운다(스펙트럼 레인은 0개여도 됨)
        let gone = try t.removingLane(sp2)
        XCTAssertNil(gone.spectrum(s1)); XCTAssertTrue(gone.isValid)
        XCTAssertNoThrow(try gone.removingLane(sp1))
        // 소리 클립에서 만들기: 그 클립 구간·계보, 스펙트럼 레인이 없으면 새로
        let (b, w2, _) = try base()
        let made = try b.addingSpectrum(fromAudioClip: w2, newLaneName: "스펙트럼")
        XCTAssertEqual(made.lanes(.spectrum).count, 1)
        XCTAssertEqual(made.spectra[0].start, 20); XCTAssertEqual(made.spectra[0].length, 60); XCTAssertEqual(made.spectra[0].sourceKey, w2)
    }

    /// 리플 편집이 스펙트럼도 민다·당기고, 스펙트럼에 걸친 지점에서는 리플을 거부한다
    /// 2C-1(2026-10-26): 스펙트럼 끌어 옮기기 붙음(snappedSpectrumDelta)과 옮기기(relocatingSpectrum) — 0·클립·다른 스펙트럼 경계, 같은 거리, 음수·넘침,
    /// 자막 경계는 대상 아님, 다른 종류의 붙음은 스펙트럼 경계에 붙지 않음, 옮겨도 ID·소스·모양·다른 내용 그대로
    func testSpectrumMoveSnappingAndRelocation() throws {
        var (t, w, a2) = try base()   // V1·A1 TA 0–120, A2 WAV 20–80
        let wR = UUID()
        t = try t.splitting(clip: w, atFrame: 50, newIDs: (w, wR))   // A2 조각 20–50·50–80(같은 계보)
        let (t1, sp1) = try spectrumLane(t)
        let sp2 = UUID(), sub = UUID(), s1 = UUID(), s2 = UUID()
        var style = SpectrumItemStyle.provisionalDefault; style.mode = .analog
        t = try t1.addingLane(.spectrum, name: "SP2", id: sp2, outward: true).addingLane(.subtitle, name: "T1", id: sub, outward: true)
        t = try t.addingSpectrum(lane: sp1, at: 200, length: 30, sourceKey: t.clip(w)!.lineageKey, style: style, id: s1)   // 200–230
        t = try t.addingSpectrum(lane: sp1, at: 240, length: 20, sourceKey: nil, id: s2)                                    // 240–260
        t = try t.addingSubtitle(lane: sub, at: 300, length: 10, text: "자막")                                                // 300–310(붙음 대상 아님)
        XCTAssertEqual(t.audioClips.filter { $0.lane == a2 }.map { $0.start..<$0.end }, [20..<50, 50..<80])
        // 붙음 없음(거리 0): 반올림만
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: 3.4, threshold: 0) == (3, nil))
        // 0: 시작 200 → 3, 0까지 3
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: -197, threshold: 5) == (-200, 0))
        // 음수 쪽 0 근처: 시작 −3 → 0에 붙음. 멀리 앞(붙을 곳 없음)은 반올림 그대로(0 제한은 부르는 쪽)
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: -203, threshold: 5) == (-200, 0))
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: -500, threshold: 5) == (-500, nil))
        // 소리 조각 경계(자른 계보의 경계 50)와 같은 거리: 시작 55(→50, 5)와 끝 85(→80, 5) — 앞선 후보(시작 쪽)
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: -145, threshold: 6) == (-150, 50))
        // 한 가장자리에서 같은 거리 두 곳: 시작 35는 20·50에서 15 — 작은 위치(차례상 앞)
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: -165, threshold: 15) == (-180, 20))
        // 다른 레인 클립 끝(V1·A1 120): 끝 118.5 → 120
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: -111.5, threshold: 2) == (-110, 120))
        // 이웃 스펙트럼: 끝 238.6 → 240(s2 시작), 그 자리로 옮기면 붙어 있고 겹치지 않음
        let adj = t.snappedSpectrumDelta(s1, delta: 8.6, threshold: 2)
        XCTAssertTrue(adj == (10, 240))
        let tAdj = try t.relocatingSpectrum(s1, toStart: 200 + adj.delta)
        XCTAssertEqual(tAdj.spectrum(s1)!.end, tAdj.spectrum(s2)!.start)
        // 자기 경계·자막 경계는 대상 아님: 시작 299(자막 300) → 붙지 않음
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: 99, threshold: 3) == (99, nil))
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: 0.4, threshold: 3) == (0, nil))
        // 숫자가 아니거나 아주 큰 값: 멈추지 않고 제한
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: .nan, threshold: 3) == (0, nil))
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: .infinity, threshold: 3) == (0, nil))   // 숫자가 아닌 값(무한 포함) = 0
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: 1e300, threshold: 3) == (1_000_000_000, nil))
        XCTAssertTrue(t.snappedSpectrumDelta(s1, delta: -1e300, threshold: 3) == (-1_000_000_000, nil))
        XCTAssertTrue(t.snappedSpectrumDelta(UUID(), delta: 2.6, threshold: 3) == (3, nil))
        // 다른 종류의 붙음은 그대로(스펙트럼 경계 200·230·240·260에 붙지 않음): 소리 조각 50–80의 끝 198 → 붙지 않음, 자막 시작 238 → 붙지 않음
        XCTAssertTrue(t.snappedDelta(clip: wR, delta: 118, threshold: 3) == (118, nil))
        let subID = t.subtitles[0].id
        XCTAssertTrue(t.snappedSubtitleDelta(subID, delta: -62, threshold: 3) == (-62, nil))
        // 옮기기: 다른 스펙트럼 레인, ID·소스·모양 그대로, 클립·자막·다른 스펙트럼 그대로, 끝을 넘으면 길이만 늘어남
        let moved = try t.relocatingSpectrum(s1, toStart: 400, lane: sp2)
        let m = moved.spectrum(s1)!
        XCTAssertEqual([m.lane, m.id], [sp2, s1]); XCTAssertEqual(m.start, 400); XCTAssertEqual(m.length, 30)
        XCTAssertEqual(m.sourceKey, t.spectrum(s1)!.sourceKey); XCTAssertEqual(m.style, style)
        XCTAssertEqual(moved.clips, t.clips); XCTAssertEqual(moved.audioClips, t.audioClips); XCTAssertEqual(moved.subtitles, t.subtitles)
        XCTAssertEqual(moved.spectrum(s2), t.spectrum(s2)); XCTAssertEqual(moved.durationFrames, 430)
        // 거부: 같은 레인 겹침, 스펙트럼 레인이 아님, 0 앞
        XCTAssertThrowsError(try t.relocatingSpectrum(s1, toStart: 230)) { XCTAssertEqual($0 as? EditError, .overlap) }
        XCTAssertThrowsError(try t.relocatingSpectrum(s1, toStart: 0, lane: a2)) { XCTAssertEqual($0 as? EditError, .laneKindMismatch) }
        XCTAssertThrowsError(try t.relocatingSpectrum(s1, toStart: 0, lane: sub)) { XCTAssertEqual($0 as? EditError, .laneKindMismatch) }
        XCTAssertThrowsError(try t.relocatingSpectrum(s1, toStart: -1)) { XCTAssertEqual($0 as? EditError, .badIndex) }
        // 다른 레인에서는 같은 시각이어도 겹치지 않음
        XCTAssertEqual(try t.relocatingSpectrum(s1, toStart: 240, lane: sp2).spectrum(s1)?.start, 240)
    }

    func testRippleShiftAndCrossing() throws {
        // WAV 소리(A1, 0–60) 다음 TA 영상+소리(60–180)
        var t = Timeline().registering(ta).registering(wav)
        let w = UUID()
        t = try t.placing(media: wav.id, at: 0, videoLane: nil, audioLane: t.baseLane(.audio)!.id, clipID: w)
        t = try t.placing(media: ta.id, at: 60, videoLane: t.baseLane(.video)!.id, audioLane: t.baseLane(.audio)!.id)
        let (t1, sl) = try spectrumLane(t)
        t = try t1.addingSpectrum(lane: sl, at: 100, length: 30, sourceKey: nil)
        let s = t.spectra[0].id
        let after = try t.rippleDeleting(clip: w)
        XCTAssertEqual(after.spectrum(s)!.start, 40, "리플 삭제가 뒤의 스펙트럼을 당김")
        let ins = try t.inserting(media: ta.id, at: 0)   // 첫 영상 클립(TA) 시작 60에 120프레임 리플 삽입
        XCTAssertEqual(ins.spectrum(s)!.start, 220, "리플 삽입이 스펙트럼을 밂")
        // 스펙트럼이 걸친 지점(60이 50–80 안)에 리플 삽입은 거부
        let inside = try t.addingSpectrum(lane: sl, at: 50, length: 30, sourceKey: nil)
        XCTAssertThrowsError(try inside.inserting(media: ta.id, at: 0)) { XCTAssertEqual($0 as? EditError, .crossingContent) }
    }

    // MARK: 소스 목록·상태·겹침

    func testSourcesStatesOverlapAndExportBlockers() throws {
        var (t, w, a2) = try base()
        let key = t.clip(w)!.lineageKey
        let (t0, sl) = try spectrumLane(t)
        let (l, r) = (UUID(), UUID())
        t = try t0.splitting(clip: w, atFrame: 45, newIDs: (l, r))
        let sources = t.spectrumSources()
        XCTAssertEqual(sources.count, 2, "TA 소리 계보 + WAV 계보(조각 2개)")
        let ws = try XCTUnwrap(sources.first { $0.key == key })
        XCTAssertEqual(ws.pieces.map(\.id), [l, r]); XCTAssertEqual(ws.range, 20..<80); XCTAssertEqual(ws.mediaID, wav.id)
        t = try t.addingSpectrum(lane: sl, at: 0, length: 120, sourceKey: key)
        let s = t.spectra[0]
        XCTAssertEqual(t.spectrumSourceState(s), .ok); XCTAssertEqual(t.spectrumExportBlockers(), [])
        XCTAssertEqual(t.spectrumFrameState(s, atFrame: 30), .ok); XCTAssertEqual(t.spectrumFrameState(s, atFrame: 130), .notVisible)
        // 오른쪽 조각을 다른 레인(A1의 빈 곳이 없으니 새 레인)으로 옮겨 왼쪽 조각과 같은 시각에 겹치게
        let a3 = UUID()
        var o = try t.addingLane(.audio, name: "A3", id: a3).relocating(clip: r, toStart: 30, lane: a3)
        let ov = o.spectrumOverlaps(key: key)
        XCTAssertEqual(ov.map(\.range), [30..<45]); XCTAssertEqual(Set(ov[0].clipIDs), [l, r])
        XCTAssertEqual(o.spectrumFrameState(o.spectrum(s.id)!, atFrame: 35), .overlap)
        XCTAssertEqual(o.spectrumFrameState(o.spectrum(s.id)!, atFrame: 90), .ok)
        let b = o.spectrumExportBlockers()
        XCTAssertEqual(b.count, 1); XCTAssertEqual(b[0].spectrumID, s.id); XCTAssertEqual(b[0].laneLabel, "SP1"); XCTAssertEqual(b[0].range, 0..<120)
        guard case .overlappingSource(let os) = b[0].reason else { return XCTFail("\(b[0].reason)") }
        XCTAssertEqual(os.map(\.range), [30..<45])
        // 분석도 겹친 창을 고르지 않는다(엔진 분석이 오류)
        XCTAssertThrowsError(try SpectrumAnalysis.chunks(frame: 35, pieces: o.spectrumPieces(o.spectrum(s.id)!), fps: 30, rate: 48_000, settings: s.style.analysisSettings, chunkSamples: 384_000))
        // 스펙트럼 보이는 구간·분석 범위 밖의 겹침은 막지 않는다
        o = try o.trimmingSpectrum(s.id, start: 80, end: 120)
        XCTAssertEqual(o.spectrumExportBlockers(), [])
        // 고르지 않음·소스 없음
        let unset = try t.addingSpectrum(lane: sl, at: 130, length: 10, sourceKey: nil)
        XCTAssertTrue(unset.spectrumExportBlockers().contains { $0.reason == .unsetSource })
        let missing = try t.lifting(clip: l).lifting(clip: r)
        XCTAssertEqual(missing.spectrumSourceState(missing.spectrum(s.id)!), .missing)
        XCTAssertEqual(missing.spectrumExportBlockers().map(\.reason), [.missingSource])
        XCTAssertEqual(missing.spectrumFrameState(missing.spectrum(s.id)!, atFrame: 30), .missing)
        _ = a2
    }

    /// 소스를 옮기거나 트림해도 스펙트럼은 그 소리를 따라간다: 30프레임 옮긴 소스의 프레임 k+30 값 = 옮기기 전 프레임 k 값(실제 분석)
    func testSourceMoveAndTrimMappingThroughAnalysis() async throws {
        let (t0, w, a2) = try base()
        let key = t0.clip(w)!.lineageKey
        let (t1, sl) = try spectrumLane(t0)
        let t = try t1.addingSpectrum(lane: sl, at: 0, length: 150, sourceKey: key)
        let moved = try t.relocating(clip: w, toStart: 50, lane: a2)
        let src = try await SpectrumFileSource.open(url: wav.url, mediaID: wav.id)
        func bands(_ tl: Timeline, _ k: Int) async throws -> [Float] {
            let s = tl.spectra[0], pieces = tl.spectrumPieces(s), st = s.style.analysisSettings
            var d: [Int: [[Float]]] = [:]
            for c in try SpectrumAnalysis.chunks(frame: k, pieces: pieces, fps: 30, rate: 48_000, settings: st, chunkSamples: src.chunkSamples) { d[c] = try await src.decodeChunk(c) }
            return try SpectrumAnalysis.bands(frame: k, pieces: pieces, fps: 30, rate: 48_000, channelCount: src.channelCount, chunkSamples: src.chunkSamples, settings: st) { d[$0] }
        }
        for k in [25, 31, 40, 60] {
            let a = try await bands(t, k), b = try await bands(moved, k + 30)
            XCTAssertEqual(a, b, "옮긴 소스 frame \(k)")
        }
        let before = try await bands(moved, 60)
        XCTAssertGreaterThan(before.max()!, 0.5, "소스 안: 440 Hz")
        let silent = try await bands(t, 10)
        XCTAssertEqual(silent.max()!, 0, "소스 앞(20 전)은 무음")
        // 원본 시작이 0이 아닌 조각(자른 오른쪽 조각 — 트림한 앞 가장자리와 같은 대응): 자르기 전과 같은 타임라인 프레임에서 같은 값
        let (l, r) = (UUID(), UUID())
        let split = try moved.splitting(clip: w, atFrame: 80, newIDs: (l, r))
        XCTAssertEqual(split.clip(r)!.sourceIn, 30)
        XCTAssertEqual(split.spectrumPieces(split.spectra[0]).map { [$0.start, $0.sourceIn, $0.length] }.sorted { $0[0] < $1[0] }, [[50, 0, 30], [80, 30, 30]])
        for k in [78, 80, 81, 95] {
            let a = try await bands(moved, k), b = try await bands(split, k)
            XCTAssertEqual(a, b, "자른 곳·오른쪽 조각 frame \(k)")
        }
    }

    // MARK: 저장(형식 8)

    func testPersistenceVersionsAndCompatibility() throws {
        let (t0, w, _) = try base()
        func mutated(_ data: Data, _ f: (inout [String: Any]) -> Void) -> Data {
            var j = try! JSONSerialization.jsonObject(with: data) as! [String: Any]; f(&j); return try! JSONSerialization.data(withJSONObject: j)
        }
        // 자르지 않은 보통 프로젝트(계보·스펙트럼 없음): 형식 5, 다시 읽으면 같음(지금까지와 같음)
        XCTAssertEqual(ProjectFile.version(for: t0), 5)
        let d0 = try ProjectFile.encode(t0, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        XCTAssertFalse(String(decoding: d0, as: UTF8.self).contains("\"origin\""))
        XCTAssertEqual(try ProjectFile.decode(d0).timeline, t0)
        // 스펙트럼 없이 자른 소리(P-S1 (나)): 계보만으로 형식 8, 계보 그대로 왕복
        let plain = try t0.splitting(clip: w, atFrame: 40)
        XCTAssertFalse(plain.needsSpectrumFormat); XCTAssertEqual(ProjectFile.version(for: plain), 8)
        let dp = try ProjectFile.encode(plain, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        XCTAssertTrue(String(decoding: dp, as: UTF8.self).contains("\"origin\""))
        XCTAssertFalse(String(decoding: dp, as: UTF8.self).contains("\"spectra\""), "스펙트럼이 없으면 spectra 키 없음")
        let rp = try ProjectFile.decode(dp)
        XCTAssertEqual(rp.document.version, 8); XCTAssertEqual(rp.timeline, plain)
        // 계보만 든 형식 8을 형식 5–7로 적으면 거부(계보를 버리지 않음)
        for v in [5, 6, 7] {
            XCTAssertThrowsError(try ProjectFile.decode(mutated(dp) { $0["version"] = v }), "v\(v) with lineage only") {
                XCTAssertEqual($0 as? ProjectFile.LoadError, .invalid("스펙트럼·계보(형식 8 값)"))
            }
        }
        // 스펙트럼 레인이 있는 동안 자른 소리: 계보 → 형식 8, 계보·스펙트럼 그대로 왕복
        let (t1, sl) = try spectrumLane(t0)
        let split = try t1.splitting(clip: w, atFrame: 40)
        XCTAssertTrue(split.audioClips.filter { $0.mediaID == wav.id }.allSatisfy { $0.lineageKey == w })
        var style = SpectrumItemStyle.provisionalDefault; style.mode = .analog; style.sides = .above; style.bands = 48; style.offsetMs = -20
        let withSpec = try split.addingSpectrum(lane: sl, at: 5, length: 70, sourceKey: w, style: style)
        XCTAssertEqual(ProjectFile.version(for: withSpec), 8)
        let d1 = try ProjectFile.encode(withSpec, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        let r1 = try ProjectFile.decode(d1)
        XCTAssertEqual(r1.document.version, 8); XCTAssertEqual(r1.timeline, withSpec)
        // 스펙트럼 레인만(스펙트럼 0개)도 형식 8
        XCTAssertEqual(ProjectFile.version(for: t1), 8)
        // 스펙트럼 레인을 지워도 계보가 남아 있으면 형식 8 그대로(버리지 않음), 왕복 같음
        let noLane = try withSpec.removingLane(sl)
        XCTAssertFalse(noLane.needsSpectrumFormat); XCTAssertEqual(ProjectFile.version(for: noLane), 8)
        XCTAssertEqual(try ProjectFile.decode(try ProjectFile.encode(noLane, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)).timeline, noLane)
        // 소스가 없는 스펙트럼도 연다(소스 없음 상태)
        let pieces = withSpec.audioClips.filter { $0.lineageKey == w }.map(\.id)
        let orphan = try withSpec.lifting(clip: pieces[0]).lifting(clip: pieces[1])
        let r2 = try ProjectFile.decode(try ProjectFile.encode(orphan, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)).timeline
        XCTAssertEqual(r2.spectrumSourceState(r2.spectra[0]), .missing)
        // 형식 7 이하에 형식 8 값이 있으면 거부, 9 이상은 새 버전
        for v in [5, 6, 7] {
            XCTAssertThrowsError(try ProjectFile.decode(mutated(d1) { $0["version"] = v }), "v\(v) with spectra") { e in
                guard case .invalid = e as? ProjectFile.LoadError else { return XCTFail("\(e)") }
            }
        }
        // 계보만 손으로 넣은 형식 5 파일은 거부
        let injected = mutated(d0) { j in
            var a = j["audioClips"] as! [[String: Any]]; a[0]["origin"] = UUID().uuidString; j["audioClips"] = a
        }
        XCTAssertThrowsError(try ProjectFile.decode(injected)) { e in guard case .invalid = e as? ProjectFile.LoadError else { return XCTFail("\(e)") } }
        XCTAssertThrowsError(try ProjectFile.decode(mutated(d1) { $0["version"] = 9 })) { XCTAssertEqual($0 as? ProjectFile.LoadError, .newerVersion(9)) }
        // 형식 8 안의 잘못된 값: 스펙트럼 모양, 영상 클립 계보, 스펙트럼이 다른 종류 레인에
        XCTAssertThrowsError(try ProjectFile.decode(mutated(d1) { j in
            var s = j["spectra"] as! [[String: Any]]; var st = s[0]["style"] as! [String: Any]; st["thicknessMilli"] = 0; s[0]["style"] = st; j["spectra"] = s
        }))
        XCTAssertThrowsError(try ProjectFile.decode(mutated(d1) { j in
            var v = j["videoClips"] as! [[String: Any]]; v[0]["origin"] = UUID().uuidString; j["videoClips"] = v
        }))
        XCTAssertThrowsError(try ProjectFile.decode(mutated(d1) { j in
            var s = j["spectra"] as! [[String: Any]]; s[0]["lane"] = (j["lanes"] as! [[String: Any]]).first { $0["kind"] as? String == "video" }!["id"]!; j["spectra"] = s
        }))
    }

    /// 스펙트럼 내보내기 그리기가 아직 없으므로 내보내기는 대상 파일·임시 폴더 전에 거부한다(조용히 빼고 내보내지 않음)
    func testExportRefusesSpectraBeforeTouchingDestination() async throws {
        let (t0, w, _) = try base()
        let (t1, sl) = try spectrumLane(t0)
        let t = try t1.addingSpectrum(lane: sl, at: 20, length: 50, sourceKey: w)
        let plan = try await CompositionPlanner.plan(t, media: [ta.id: ta, wav.id: wav])
        XCTAssertEqual(plan.spectra.count, 1)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otf-spectrum-export-refuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.mp4")
        let temps = TempBox()
        let o = await ExportService.export(plan, to: .fromSavePanel(dest), sources: [ta, wav], options: .init(onTempDirectory: { temps.set($0) })) { _ in }
        guard case .failed(.export(let msg)) = o else { return XCTFail("\(o)") }
        XCTAssertTrue(msg.contains("스펙트럼"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path)); XCTAssertNil(temps.get(), "임시 폴더를 만들기 전에 거부")
    }
    final class TempBox: @unchecked Sendable {   // 안전성: 잠금으로 보호
        private let l = NSLock(); private var u: URL?
        func set(_ x: URL) { l.lock(); u = x; l.unlock() }
        func get() -> URL? { l.lock(); defer { l.unlock() }; return u }
    }
}
