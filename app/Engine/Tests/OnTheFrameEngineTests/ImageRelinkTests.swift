import XCTest
@testable import OnTheFrameEngine

final class ImageRelinkTests: XCTestCase {
    @MainActor
    private func exerciseSecondRead(_ expected: InternalImagePreview.SecondReadFailure?,
                                    change: @escaping @MainActor (URL) throws -> Void) async throws {
        let image = try await ImageModelFixture.image()
        let timeline = try OperationalProjectAdapter.restore(ImageModelFixture.project(image)).timeline
        let id = try XCTUnwrap(timeline.clips.first?.mediaID)
        var events: [Bool] = []
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.url.path) }
        do {
            _ = try await InternalImagePreview.plan(timeline, media: [:], enabled: true, resolvedImages: [id: image.url]) { key, available in
                XCTAssertEqual(key, id)
                events.append(available)
                if available {
                    do { try change(image.url) } catch { XCTFail("fixture operation failed: \(error)") }
                }
            }
            XCTFail("failed source must not produce a preview plan")
        } catch is CancellationError {
            XCTAssertNil(expected)
        } catch let error as InternalImagePreview.SecondReadFailure {
            XCTAssertEqual(error, expected)
        }
        XCTAssertEqual(events, expected == nil ? [true] : [true, false])
    }

    func testMoveBetweenProbeAndDecode() async throws {
        try await exerciseSecondRead(.missing) { url in
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("moved"))
        }
    }

    func testReplacementRejectedOnSecondRead() async throws {
        try await exerciseSecondRead(.changed) { url in
            try Data("invalid replacement".utf8).write(to: url, options: .atomic)
        }
        try await exerciseSecondRead(.changed) { url in
            let sameImage = try Data(contentsOf: url)
            try sameImage.write(to: url, options: .atomic)
        }
    }

    func testReadPermissionLostBetweenProbeAndDecode() async throws {
        try await exerciseSecondRead(.inaccessible) { url in
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        }
    }

    func testCancellationSuppressesSecondReadFailure() async throws {
        try await exerciseSecondRead(nil) { url in
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("moved"))
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func testUnchangedSourceDecoderFailureIsNotMissing() async throws {
        let image = try await ImageModelFixture.image()
        XCTAssertThrowsError(try InternalImagePreview.decodedImage(at: image.url, descriptor: image.descriptor,
                                                                   read: { _, _ in nil })) { error in
            XCTAssertEqual(error as? InternalImagePreview.SecondReadFailure, .decoder)
        }
        XCTAssertFalse(InternalImagePreview.SecondReadFailure.decoder.sourceUnavailable)
        XCTAssertFalse(InternalImagePreview.SecondReadFailure.resources.sourceUnavailable)
        let uncertain = InternalImagePreview.SecondReadFailure.fromErrno(EIO)
        XCTAssertEqual(uncertain, .unverified(EIO))
        XCTAssertFalse(uncertain.sourceUnavailable)
    }

    func testRevisionsUndoRedoAndCrossFormatPreserveEdits() async throws {
        let png=try await ImageModelFixture.image(), jpeg=try await ImageModelFixture.image("jpg",width:4,height:2,orientation:6)
        var model=try ImageModelFixture.project(png)
        model.videoClips.append(model.videoClips[0].with(start:150,id:UUID()))
        let original=try OperationalProjectAdapter.restore(model)
        let t=original.timeline, id=t.clips[0].mediaID
        let project=try ProjectPersistence.make(timeline:t,projectID:model.projectID)
        let revision=ProjectPersistence.imageRevision(t,mediaID:id)
        let (linked,change)=try await ProjectPersistence.relinkImage(project,mediaID:id,to:jpeg.url)
        XCTAssertTrue(change.requiresNotification)
        XCTAssertEqual(change.newOrientation,6)
        XCTAssertEqual(linked.projectID,project.projectID)
        XCTAssertEqual(linked.timeline.clips,t.clips)
        XCTAssertEqual(linked.timeline.audioClips,t.audioClips)
        XCTAssertEqual(linked.timeline.subtitles,t.subtitles)
        XCTAssertEqual(linked.timeline.spectra,t.spectra)
        XCTAssertNotEqual(revision,ProjectPersistence.imageRevision(linked.timeline,mediaID:id))
        var history=EditHistory(t);history.apply(linked.timeline,focus:t.clips[0].id)
        history.undo();XCTAssertEqual(history.timeline,t)
        XCTAssertEqual(ProjectPersistence.imageRevision(history.timeline,mediaID:id),revision)
        history.redo();XCTAssertEqual(history.timeline,linked.timeline)
        let dest=jpeg.url.deletingLastPathComponent().appendingPathComponent("roundtrip.ontheframe")
        let decoded=try ProjectPersistence.decode(ProjectPersistence.encode(linked,at:dest))
        XCTAssertEqual(decoded.timeline.clips,t.clips)
        XCTAssertEqual(decoded.media[0].path,jpeg.url.path)
        let (back,_)=try await ProjectPersistence.relinkImage(linked,mediaID:id,to:png.url)
        XCTAssertEqual(back.timeline.clips,t.clips)
        let (_,same)=try await ProjectPersistence.relinkImage(project,mediaID:id,to:png.url)
        XCTAssertFalse(same.requiresNotification)
    }
    func testUnavailableProofAndValidatedRevisionAreDistinct() async throws {
        let source=try await ImageModelFixture.image()
        let model=try ImageModelFixture.project(source)
        let original=try OperationalProjectAdapter.restore(model)
        let id=original.timeline.clips[0].mediaID
        let p=try ProjectPersistence.make(timeline:original.timeline,projectID:model.projectID)
        let (linked,_)=try await ProjectPersistence.relinkImage(p,mediaID:id,to:source.url)
        XCTAssertNotEqual(ProjectPersistence.imageRevision(original.timeline,mediaID:id),ProjectPersistence.imageRevision(linked.timeline,mediaID:id))
    }
    func testMixedRelinkPreservesAudioLineageSubtitleSpectrumAndUnrelatedMedia() async throws {
        let state=try await OperationalProjectAdapterTests().mixed()
        let before=state.timeline,id=try XCTUnwrap(before.stillImageIDs.first)
        let p=try ProjectPersistence.make(timeline:before,projectID:state.projectID)
        let source=try await ImageModelFixture.image("jpg",width:4,height:5,orientation:6)
        let (next,_)=try await ProjectPersistence.relinkImage(p,mediaID:id,to:source.url)
        XCTAssertEqual(next.timeline.clips,before.clips)
        XCTAssertEqual(next.timeline.audioClips,before.audioClips)
        XCTAssertEqual(next.timeline.subtitles,before.subtitles)
        XCTAssertEqual(next.timeline.spectra,before.spectra)
        XCTAssertEqual(next.timeline.lanes,before.lanes)
        XCTAssertEqual(next.timeline.durationFrames,before.durationFrames)
        XCTAssertEqual(next.timeline.mediaCatalog.filter{$0.id != id},before.mediaCatalog.filter{$0.id != id})
        XCTAssertEqual(next.projectID,state.projectID)
    }
    func testMissingLocationHintRebasesAfterSaveAs() throws {
        let originalProject=URL(fileURLWithPath:"/generated/first/project.ontheframe")
        let hint="../media/missing.png"
        let originalSource=originalProject.deletingLastPathComponent().appendingPathComponent(hint).standardizedFileURL
        let savedAs=URL(fileURLWithPath:"/generated/elsewhere/deep/project.ontheframe")
        let rebased=try XCTUnwrap(ProjectPersistence.relativePath(to:originalSource,from:savedAs))
        XCTAssertEqual(savedAs.deletingLastPathComponent().appendingPathComponent(rebased).standardizedFileURL,originalSource)
        XCTAssertNotEqual(rebased,hint)
    }
    func testCorruptAndOversizedCandidatesPreserveProject() async throws {
        let source=try await ImageModelFixture.image(),model=try ImageModelFixture.project(source)
        let p=try ProjectPersistence.make(timeline:OperationalProjectAdapter.restore(model).timeline,projectID:model.projectID)
        let id=p.media[0].id
        for size in [32,8*1024*1024+1] {
            let url=source.url.deletingLastPathComponent().appendingPathComponent("bad-\(size).png")
            try Data(repeating:0,count:size).write(to:url,options:.withoutOverwriting)
            do {_ = try await ProjectPersistence.relinkImage(p,mediaID:id,to:url);XCTFail("accepted invalid candidate")}
            catch { }
            XCTAssertEqual(p.media[0].path,source.url.path)
            XCTAssertEqual(p.timeline.clips,model.videoClips)
        }
    }
}
