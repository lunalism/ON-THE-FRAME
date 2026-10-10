import AVFoundation
import E2Core
import Foundation
@testable import OnTheFrameEngine
import OTFDevSupport
import XCTest

/// 프로젝트 파일(.ontheframe, A-013): 저장 → 다시 읽기 왕복, 잘못된·더 새로운 파일 거부, 재연결 검사, 복원한 타임라인의 내보내기 판정.
final class ProjectFileTests: XCTestCase {
    let ma = UUID(), mb = UUID()
    func ref(_ id: UUID, _ name: String, frames: Int, audio: Bool = true) -> MediaRef {
        MediaRef(id: id, name: name, path: "/media/\(name)", frameCount: frames, hasAudio: audio, size: 1234, modifiedNs: 5678, codec: "avc1", width: 1920, height: 1080)
    }
    /// 빈틈·어긋난 소리·연결·바꾼 레인 이름이 있는 타임라인
    func sample() throws -> Timeline {
        var t = Timeline(media: [ref(ma, "a.mp4", frames: 100), ref(mb, "b.mp4", frames: 60)], mediaFrames: [ma: 100, mb: 60], mediaHasAudio: [ma: true, mb: true])
        t = try t.inserting(media: ma).inserting(media: mb)
        let right = UUID()
        t = try t.splitting(clip: t.clips[0].id, atFrame: 40, newIDs: (UUID(), right))
        let ra = try XCTUnwrap(t.partner(of: right)).id
        t = try t.unlinking(clip: right).lifting(clip: t.clips[2].id)              // B 쌍 지움 → 빈틈 [100,160)
        t = try t.movingFree(clip: ra, toStart: 55).linking(right, ra)           // 소리 +15, 다시 연결
        t = try t.renamingLane(Lane.videoID, to: "인터뷰 영상").renamingLane(Lane.audioID, to: "현장음")
        XCTAssertTrue(t.isValid); XCTAssertEqual(t.syncOffset(of: right), 15); XCTAssertEqual(t.durationFrames, 160)
        return t
    }

    func testRoundTripPreservesEverything() throws {
        let t = try sample(), pid = UUID()
        let bm = Data([1, 2, 3, 4])
        let data = try ProjectFile.encode(t, projectID: pid, settings: .m1, bookmarks: [ma: bm], projectURL: URL(fileURLWithPath: "/media/projects/p.ontheframe"))
        let (back, doc) = try ProjectFile.decode(data)
        XCTAssertEqual(back, t)                                            // 클립·연결·레인·미디어·길이(빈틈 포함) 모두 같음
        XCTAssertEqual(doc.projectID, pid)
        XCTAssertEqual(doc.version, 1); XCTAssertEqual(doc.format, "dev.ontheframe.project")
        XCTAssertEqual(doc.settings, .init(width: 1920, height: 1080, fps: 30))
        XCTAssertEqual(doc.media.first { $0.ref.id == ma }?.bookmark, bm)
        XCTAssertEqual(doc.media.first { $0.ref.id == ma }?.relativePath, "../a.mp4")
        XCTAssertEqual(back.syncOffset(of: back.clips[1].id), 15)
        XCTAssertEqual(back.lanes.map(\.name), ["인터뷰 영상", "현장음"]); XCTAssertEqual(back.lanes.map(\.id), [Lane.videoID, Lane.audioID])
        // 시각은 정수만: JSON에 소수점 숫자가 없다(북마크는 base64 문자열)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertNil(text.range(of: #":\s*-?\d+\.\d+"#, options: .regularExpression), "floating value in project")
        // 다시 저장해도 같은 내용(결정적)
        XCTAssertEqual(try ProjectFile.encode(back, projectID: pid, settings: .m1, bookmarks: [ma: bm], projectURL: URL(fileURLWithPath: "/media/projects/p.ontheframe")), data)
    }

    func testRejectsMalformedNewerAndInvalid() throws {
        let t = try sample()
        let good = try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: nil)
        func json(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var o = try JSONSerialization.jsonObject(with: good) as! [String: Any]
            edit(&o); return try JSONSerialization.data(withJSONObject: o)
        }
        func reject(_ d: Data, _ check: (ProjectFile.LoadError) -> Bool, _ msg: String) {
            do { _ = try ProjectFile.decode(d); XCTFail("accepted: \(msg)") }
            catch let e as ProjectFile.LoadError { XCTAssertTrue(check(e), "\(msg): \(e)") }
            catch { XCTFail("\(msg): \(error)") }
        }
        reject(Data("not json".utf8), { if case .malformed = $0 { return true }; return false }, "garbage")
        reject(try json { $0["format"] = "other" }, { $0 == .notAProject }, "format")
        reject(try json { $0["version"] = 99 }, { $0 == .newerVersion(99) }, "newer")
        XCTAssertTrue(ProjectFile.LoadError.newerVersion(99).description.contains("더 새로운 버전"))
        reject(try json { $0["version"] = 0 }, { $0 == .unsupportedVersion(0) }, "older")
        reject(try json { $0.removeValue(forKey: "videoClips") }, { if case .malformed(let s) = $0 { return s.contains("videoClips") }; return false }, "missing key")
        reject(try json { $0["settings"] = ["width": 3840, "height": 2160, "fps": 30] }, { if case .invalid = $0 { return true }; return false }, "settings")
        reject(try json { $0["durationFrames"] = 10 }, { if case .invalid = $0 { return true }; return false }, "duration shorter than clips")
        reject(try json { var v = $0["videoClips"] as! [[String: Any]]; v[1]["start"] = 10; $0["videoClips"] = v }, { if case .invalid = $0 { return true }; return false }, "overlap")
        reject(try json { var v = $0["videoClips"] as! [[String: Any]]; v[1]["id"] = v[0]["id"]; $0["videoClips"] = v }, { if case .invalid = $0 { return true }; return false }, "duplicate id")
        reject(try json { var v = $0["videoClips"] as! [[String: Any]]; v[0]["mediaID"] = UUID().uuidString; $0["videoClips"] = v }, { if case .invalid = $0 { return true }; return false }, "unknown media")
        reject(try json { var v = $0["videoClips"] as! [[String: Any]]; v[0]["length"] = 1000; $0["videoClips"] = v }, { if case .invalid = $0 { return true }; return false }, "source range")
        reject(try json { var a = $0["audioClips"] as! [[String: Any]]; a[0].removeValue(forKey: "link"); $0["audioClips"] = a }, { if case .invalid = $0 { return true }; return false }, "half link")
        reject(try json { var l = $0["lanes"] as! [[String: Any]]; l[1]["name"] = "  "; $0["lanes"] = l }, { if case .invalid = $0 { return true }; return false }, "empty lane name")
    }

    func testRelinkValidatesRangesAndAudioAndKeepsClips() throws {
        let t = try sample()
        let short = ref(ma, "a2.mp4", frames: 80)                          // 클립이 원본 [0,100)을 씀 → 거부
        XCTAssertThrowsError(try t.relinking(media: ma, to: short)) { XCTAssertEqual($0 as? OnTheFrameEngine.EditError, .relinkTooShort(need: 100, have: 80)) }
        XCTAssertThrowsError(try t.relinking(media: ma, to: ref(ma, "silent.mp4", frames: 100, audio: false))) { XCTAssertEqual($0 as? OnTheFrameEngine.EditError, .relinkNoAudio) }
        let ok = try t.relinking(media: ma, to: ref(ma, "moved/a.mp4", frames: 120))
        XCTAssertEqual(ok.clips, t.clips); XCTAssertEqual(ok.audioClips, t.audioClips)    // 클립·ID·위치 그대로
        XCTAssertEqual(ok.media.first { $0.id == ma }?.path, "/media/moved/a.mp4"); XCTAssertNotEqual(ok, t)
        // 프리뷰용 사본: 쓸 수 없는 원본의 클립만 빠지고 길이는 그대로
        let pv = t.excludingMedia([ma])
        XCTAssertTrue(pv.clips.isEmpty && pv.audioClips.isEmpty); XCTAssertEqual(pv.durationFrames, 160)
        // 가져오기는 실행 취소로 사라지지 않는다(모든 단계에 적용)
        var h = EditHistory(t)
        h.apply(try t.lifting(clip: t.clips[0].id), focus: nil)
        h.mapAll { $0.registering(fakeAsset()) }
        h.undo()
        XCTAssertTrue(h.timeline.media.contains { $0.name == "late.mp4" })
    }
    func fakeAsset() -> MediaAsset {
        let u = URL(fileURLWithPath: "/media/late.mp4")
        return MediaAsset(id: UUID(), url: u, name: "late.mp4", frameCount: 30,
                          timing: SourceTiming(sampleCount: 30, isVariable: false, frameDurationValue: 1, frameDurationTimescale: 30, averageFPS: 30, minInterval: 1.0 / 30, maxInterval: 1.0 / 30),
                          naturalSize: CGSize(width: 64, height: 64), displaySize: CGSize(width: 64, height: 64), preferredTransform: .identity, hasAudio: false, codec: "avc1",
                          identity: FileIdentity(device: 1, inode: 2, size: 3, modifiedNs: 4))
    }

    /// 생성 fixture: 저장 → 다시 읽은 타임라인을 프리뷰 구성·내보내기에 쓰고, 기대값은 편집 표에서 직접(ExportJudge)
    func testRestoredProjectExportsSameFramesAndAudio() async throws {
        let fx = ExportEndToEndTests.root.appendingPathComponent("fixtures")
        try await DevFixtures.ensureAll(in: fx)
        let out = ExportEndToEndTests.root.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let ta = try await MediaProbe.inspect(fx.appendingPathComponent("otf-TA.mp4")), tb = try await MediaProbe.inspect(fx.appendingPathComponent("otf-TB.mp4"))
        var t = Timeline().registering(ta).registering(tb)
        t = try t.inserting(media: ta.id).inserting(media: tb.id)
        let right = UUID()
        t = try t.splitting(clip: t.clips[0].id, atFrame: 60, newIDs: (UUID(), right))
        let ra = try XCTUnwrap(t.partner(of: right)).id
        let tbA = try XCTUnwrap(t.partner(of: t.clips[2].id)).id
        t = try t.unlinking(clip: right).unlinking(clip: tbA).lifting(clip: tbA).movingFree(clip: ra, toStart: 75).linking(right, ra)
        t = try t.renamingLane(Lane.audioID, to: "현장음")
        let data = try ProjectFile.encode(t, projectID: UUID(), settings: .m1, bookmarks: [:], projectURL: out.appendingPathComponent("p.ontheframe"))
        let (back, doc) = try ProjectFile.decode(data)
        XCTAssertEqual(back, t)
        // 다시 연 미디어: 저장된 id로 다시 검사(경로에서)
        var media: [UUID: MediaAsset] = [:]
        for e in doc.media { media[e.ref.id] = try await MediaProbe.inspect(URL(fileURLWithPath: e.ref.path)).withID(e.ref.id) }
        let plan = try await CompositionPlanner.plan(back, media: media)
        let dest = out.appendingPathComponent("restored.mp4")
        let outcome = await ExportService.export(plan, to: .fromSavePanel(dest), sources: Array(media.values)) { _ in }
        XCTAssertEqual(outcome, .completed(dest))
        let video: [ExportJudge.ClipRef] = [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 60), .init(file: "otf-TA.mp4", start: 60, sourceIn: 60, length: 60),
                                            .init(file: "otf-TB.mp4", start: 120, sourceIn: 0, length: 90)]
        let audio: [ExportJudge.ClipRef] = [.init(file: "otf-TA.mp4", start: 0, sourceIn: 0, length: 60), .init(file: "otf-TA.mp4", start: 75, sourceIn: 60, length: 60)]
        let v = try await ExportJudge.judge(dest, clips: video, audioClips: audio, durationFrames: 210, toneCheck: true)
        XCTAssertTrue(v.pass, "\(v)")
        XCTAssertEqual(v.expectedOnsets, [30, 50, 90, 115].map { $0 * DevFixtures.samplesPerFrame })
        // 프리뷰 경로(같은 composition) 경계 프레임
        let (expected, _) = try ExportJudge.expectations(video, durationFrames: 210)
        let probe = [59, 60, 119, 120, 209]
        let preview = try await PreviewProbe.frames(plan, at: probe)
        let exportPixels = try await FrameCompare.decode(dest, frames: Set(probe))
        let cmp = PreviewExportCompare.check(preview: preview, export: exportPixels, expected: expected, probes: probe)
        XCTAssertTrue(cmp.failures.isEmpty, cmp.failures.joined(separator: "; "))
    }
}
