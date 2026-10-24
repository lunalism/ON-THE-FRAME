import AVFoundation
import Darwin
import Foundation
import os

/// 내보내기 대상 요청. confirmedReplace는 사용자가 저장 패널에서 기존 파일 대치를 확인했다는 뜻이고,
/// identityAtConfirmation은 그때의 파일 식별이다. 확인 뒤 대상이 바뀌면(다른 파일·크기·시각) 대치하지 않는다.
public struct ExportDestination: Sendable {
    public let url: URL
    public let confirmedReplace: Bool
    public let identityAtConfirmation: FileIdentity?
    public init(url: URL, confirmedReplace: Bool, identityAtConfirmation: FileIdentity?) {
        self.url = url; self.confirmedReplace = confirmedReplace; self.identityAtConfirmation = identityAtConfirmation
    }
    /// 저장 패널이 돌려준 URL에서 만든다(그 시점에 파일이 있으면 패널이 대치를 확인한 것으로 본다).
    public static func fromSavePanel(_ url: URL) -> ExportDestination {
        let id = FileIdentity.of(url)
        return ExportDestination(url: url, confirmedReplace: id != nil, identityAtConfirmation: id)
    }
}

public enum ExportFailure: Error, Equatable, CustomStringConvertible {
    case destinationIsSource
    case destinationExistsUnconfirmed
    case destinationChangedAfterConfirmation
    case destinationAppeared
    case tempUnavailable(String)
    case export(String)
    case verification(String)
    case promotion(String)
    case injected
    public var description: String {
        switch self {
        case .destinationIsSource: return "가져온 원본 파일에는 내보낼 수 없습니다. 다른 이름을 고르세요."
        case .destinationExistsUnconfirmed: return "같은 이름의 파일이 있습니다. 대치를 확인하지 않아 내보내지 않았습니다."
        case .destinationChangedAfterConfirmation: return "대치를 확인한 뒤 대상 파일이 바뀌었습니다. 기존 파일을 그대로 두고 내보내기를 멈췄습니다."
        case .destinationAppeared: return "내보내는 동안 같은 이름의 파일이 생겼습니다. 그 파일을 덮어쓰지 않았습니다."
        case .tempUnavailable(let s): return "임시 위치를 만들 수 없습니다(\(s))."
        case .export(let s): return "내보내기 실패: \(s)"
        case .verification(let s): return "내보낸 파일 확인 실패: \(s)"
        case .promotion(let s): return "결과 파일을 옮기지 못했습니다(\(s))."
        case .injected: return "내보내기 실패(시험용 실패 주입)."
        }
    }
}

public enum ExportOutcome: Sendable, Equatable {
    case completed(URL)
    case cancelled
    case failed(ExportFailure)
}

/// 내보내기(M1): 타임라인 스냅샷의 composition → H.264/AAC MP4(1920×1080, 30 fps).
/// 출력 보호(샌드박스 호환):
/// 1. 대상이 가져온 원본이면 대치 확인이 있어도 거부한다(경로·장치/inode 비교).
/// 2. 기존 파일은 대치를 확인한 경우에만, 그리고 확인 뒤 바뀌지 않았을 때만 바꾼다.
/// 3. 결과는 대상과 같은 볼륨의 대치용 임시 디렉터리(`FileManager.url(for: .itemReplacementDirectory, …, appropriateFor:)`)에 쓰고
///    검증한 뒤 옮긴다: 새 대상은 배타적 이름 바꾸기(RENAME_EXCL), 대치는 `FileManager.replaceItemAt`.
///    대상 옆에 임의 형제 파일을 만들지 않는다(샌드박스는 저장 패널이 고른 파일만 허용).
/// 4. 취소·실패 시 이 내보내기가 만든 임시 디렉터리만 지운다. 기존 대상은 그대로 남는다.
public enum ExportService {
    static let log = Logger(subsystem: "dev.ontheframe.app", category: "export")

    public struct Options: Sendable {
        /// 시험용: 진행률이 이 값을 넘으면 실패를 주입한다.
        public var failAfterFraction: Double?
        /// 시험용: 승격 직전에 호출(대상 변경 시나리오 재현)
        public var beforePromotion: (@Sendable () -> Void)?
        /// 시험용: 이 내보내기가 만든 임시 디렉터리 위치(정리 확인용)
        public var onTempDirectory: (@Sendable (URL) -> Void)?
        public init(failAfterFraction: Double? = nil, beforePromotion: (@Sendable () -> Void)? = nil, onTempDirectory: (@Sendable (URL) -> Void)? = nil) {
            self.failAfterFraction = failAfterFraction; self.beforePromotion = beforePromotion; self.onTempDirectory = onTempDirectory
        }
    }

    public static func validate(_ d: ExportDestination, sources: [MediaAsset]) -> ExportFailure? {
        let dest = d.url.standardizedFileURL.resolvingSymlinksInPath()
        let destID = FileIdentity.of(dest)
        for s in sources {
            if s.url.standardizedFileURL.resolvingSymlinksInPath().path == dest.path { return .destinationIsSource }
            if let did = destID, did.sameFile(as: s.identity) { return .destinationIsSource }
        }
        if let did = destID {
            guard d.confirmedReplace, let c = d.identityAtConfirmation else { return .destinationExistsUnconfirmed }
            if did != c { return .destinationChangedAfterConfirmation }
        }
        return nil
    }

    /// 인코딩 중 보고하는 진행률 상한. 1.0은 출력 검증과 승격(대상 위치로 옮김)이 성공한 뒤에만 보고한다.
    public static let encodingProgressCap = 0.99

    /// progress: 한 내보내기 안에서 순서대로(await) 불린다. 값은 유한하고 [0, 1] 안이며 줄어들지 않는다.
    /// 인코딩 중에는 [0, 0.99], 1.0은 검증·승격 성공 뒤 한 번. 취소·실패에서는 1.0을 보고하지 않는다.
    /// 작업(Task) 취소 = 내보내기 취소.
    /// stage: 인코딩 시작(.encoding)과 인코딩이 끝나 검증·승격에 들어감(.finalizing)을 순서대로 알린다(표시용, 진행률은 바꾸지 않음).
    /// 그리지 못하는 자막(첫 번째). 앱은 내보내기 전에 같은 판정으로 막고 알린다.
    public static func unrenderableSubtitle(_ p: PlannedComposition) -> SubtitleItem? {
        p.subtitles.first { SubtitleRenderer.shared.renderFailed($0) }   // 결과만 기억하는 판정(그림 캐시보다 큰 묶음에서 다시 그리지 않음, §49)
    }
    public static func export(_ p: PlannedComposition, to d: ExportDestination, sources: [MediaAsset],
                              options: Options = Options(), stage: @escaping @Sendable (ExportStage) async -> Void = { _ in },
                              progress: @escaping @Sendable (Double) async -> Void) async -> ExportOutcome {
        if let f = validate(d, sources: sources) { return .failed(f) }
        // A-014: 영상 원본이 하나도 없으면(소리 파일만) 영상 트랙을 만들 수 없다 — 내보내지 않는다(앱은 미리 막는다)
        guard p.hasVideo else { return .failed(.export("영상이 있는 원본이 없습니다. 영상 파일을 하나 이상 가져오세요.")) }
        // 그려야 할 자막을 그리지 못하면(2026-10-23) 임시 파일·대상 파일을 건드리기 전에 거부한다. 빈 자막은 plan.subtitles에 없다.
        if let bad = Self.unrenderableSubtitle(p) {
            return .failed(.export("자막을 그릴 수 없어 내보내지 않았습니다(\(bad.start)프레임에서 시작하는 자막). 글을 줄이거나 글자 크기를 줄인 뒤 다시 내보내세요."))
        }
        let tempDir: URL
        do {
            tempDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: d.url, create: true)
        } catch { return .failed(.tempUnavailable(error.localizedDescription)) }
        log.info("export temp dir created")
        options.onTempDirectory?(tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }   // 이 내보내기가 만든 임시 디렉터리만
        let tempFile = tempDir.appendingPathComponent("output.mp4")

        await stage(.encoding)
        let result: Result<Void, Error>
        if p.subtitles.isEmpty {
            // 자막이 없는 프로젝트: 지금까지의 내보내기 세션 경로 그대로
            let (r, injected) = await encodeWithSession(p, to: tempFile, options: options, progress: progress)
            if injected { return .failed(.injected) }
            result = r
        } else {
            // 자막이 있는 프로젝트: 구조 R(기본 합성기 리더 → 4:2:0 자막 → 쓰기, SubtitleExporter)
            do { try await SubtitleExporter.encode(p, to: tempFile, failAfterFraction: options.failAfterFraction, progress: progress); result = .success(()) }
            catch is SubtitleExporter.Injected { return .failed(.injected) }
            catch let e as ExportFailure { return .failed(e) }
            catch { result = .failure(error) }
        }
        switch result {
        case .failure(let e):
            if e is CancellationError || Task.isCancelled { return .cancelled }
            return .failed(.export(e.localizedDescription))
        case .success:
            break
        }
        if Task.isCancelled { return .cancelled }
        await stage(.finalizing)
        // 승격 전 검증
        do {
            let a = AVURLAsset(url: tempFile)
            let v = try await a.loadTracks(withMediaType: .video)
            guard v.count == 1 else { return .failed(.verification("video tracks \(v.count)")) }
            let r = try await v[0].load(.timeRange)
            let frames = p.settings.nearestFrame(r.duration)
            guard frames == p.durationFrames else { return .failed(.verification("frames \(frames) != \(p.durationFrames)")) }
            // 소리는 섞인 트랙 하나(여러 레인을 따로 쓴 파일은 첫 트랙만 들리므로 승격하지 않는다)
            let au = try await a.loadTracks(withMediaType: .audio)
            guard au.count == (p.hasAudio ? 1 : 0) else { return .failed(.verification("audio tracks \(au.count)")) }
        } catch { return .failed(.verification(error.localizedDescription)) }
        options.beforePromotion?()
        // 마무리(검증) 중 취소(CP-13): 승격 직전에 다시 본다. 취소했으면 결과를 옮기지 않고 임시 파일만 지운다.
        if Task.isCancelled { return .cancelled }
        let outcome = promote(tempFile, to: d, sources: sources)
        if case .completed = outcome { await progress(1) }   // 검증·승격 성공 뒤에만 1.0
        return outcome
    }

    /// 자막 없는 프로젝트의 인코딩(내보내기 세션, AVAssetExportPreset1920x1080). 결과와 실패 주입 여부.
    static func encodeWithSession(_ p: PlannedComposition, to tempFile: URL, options: Options, progress: @escaping @Sendable (Double) async -> Void) async -> (Result<Void, Error>, Bool) {
        guard let session = AVAssetExportSession(asset: p.composition, presetName: AVAssetExportPreset1920x1080) else {
            return (.failure(ExportFailure.export("export session")), false)
        }
        session.videoComposition = p.videoComposition
        session.audioMix = p.audioMix   // 오디오 레인 음량(A-014)
        session.shouldOptimizeForNetworkUse = false
        let injected = OSAllocatedUnfairLock(initialState: false)
        let box = SessionBox(session: session)
        let exportTask = Task { try await box.session.export(to: tempFile, as: .mp4) }
        let watcher = Task {
            var last = 0.0
            for await st in box.session.states(updateInterval: 0.1) {
                if case .exporting(let pr) = st {
                    let f = pr.fractionCompleted
                    // 유한값만, [0, 0.99]로 제한, 줄어들지 않게(세션이 되돌린 값은 보고하지 않음)
                    if f.isFinite {
                        let v = min(max(f, 0), 1) * encodingProgressCap
                        if v >= last { last = v; await progress(v) }
                    }
                    if let ff = options.failAfterFraction, f >= ff {
                        injected.withLock { $0 = true }; exportTask.cancel(); break
                    }
                }
            }
        }
        let result: Result<Void, Error> = await withTaskCancellationHandler {
            do { try await exportTask.value; return .success(()) } catch { return .failure(error) }
        } onCancel: { exportTask.cancel() }
        watcher.cancel()
        _ = await watcher.value   // 진행률 보고가 끝난 뒤에 결과를 정한다(늦은 진행률이 결과 뒤에 오지 않게)
        return (result, injected.withLock { $0 })
    }

    static func promote(_ temp: URL, to d: ExportDestination, sources: [MediaAsset]) -> ExportOutcome {
        // 승격 직전에 다시 확인(원본 보호, 확인 뒤 변경)
        if let f = validate(d, sources: sources) {
            if f == .destinationExistsUnconfirmed { return .failed(.destinationAppeared) }
            return .failed(f)
        }
        if FileIdentity.of(d.url) == nil {
            // 새 대상: 배타적 이름 바꾸기. 그 사이 대상이 생겼으면 덮어쓰지 않는다.
            if renamex_np(temp.path, d.url.path, UInt32(RENAME_EXCL)) == 0 { return .completed(d.url) }
            let e = errno
            if e == EEXIST { return .failed(.destinationAppeared) }
            if e == EXDEV {
                do { try FileManager.default.moveItem(at: temp, to: d.url); return .completed(d.url) }
                catch { return .failed(.promotion(error.localizedDescription)) }
            }
            return .failed(.promotion("rename errno \(e)"))
        }
        do {
            _ = try FileManager.default.replaceItemAt(d.url, withItemAt: temp, backupItemName: nil, options: [])
            return .completed(d.url)
        } catch { return .failed(.promotion(error.localizedDescription)) }
    }
}

/// 안전성(@unchecked Sendable): 내보내기 세션은 설정을 끝낸 뒤에만 넘기고, 이후에는 export·states(문서상 스레드 안전한 진입점)만 부른다.
struct SessionBox: @unchecked Sendable { let session: AVAssetExportSession }
