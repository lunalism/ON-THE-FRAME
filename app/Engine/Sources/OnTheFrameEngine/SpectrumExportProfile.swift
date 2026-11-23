#if DEBUG
import Dispatch
import Foundation
import os

/// DEBUG 전용 내보내기 단계 시간 집계(SP-EXPORT-E4b, 2026-11-23). 제품 동작을 바꾸지 않는다: 순서·스레드·결과는 그대로이고
/// 단계 앞뒤에서 시계를 읽어 고정 크기 칸에 더할 뿐이다. 프레임별 기록·파일·네트워크·백그라운드 감시는 없다.
/// 시간은 모두 벽시계(uptime)다 — CPU 시간이 아니다. 프로세스 전체 CPU 시간은 내보내기 앞뒤의 차이 하나만 따로 담는다.
struct SpectrumExportProfile: Sendable, Equatable {
    /// 겹침: prepareWait ⊇ prepare ⊇ { sourcePreparation, analysis, raster, pixelCount, footprint }. sourceValidation은 prepareWait 안, prepare 밖이다.
    /// sourceFrame·frameCopy·composite·append는 영상 큐에서 차례로 일어나며 서로 겹치지 않고 prepareWait와도 겹치지 않는다.
    /// writerWait는 쓰기 쪽이 준비되지 않아 영상 큐가 쉰 시간이다. 소리 쓰기는 다른 큐에서 동시에 일어나며 재지 않는다.
    enum Stage: Int, CaseIterable, Sendable {
        case prepareWait        // 펌프: 프레임 준비를 맡긴 때부터 영상 큐가 결과를 받은 때까지
        case sourceValidation   // 공급기: 원본 정체 확인(요청 앞뒤)
        case prepare            // 작업자: 프레임 하나의 process 전체
        case sourcePreparation  // 작업자: 원본 열기·조각 계획·필요한 소리 덩어리 디코딩
        case analysis           // 작업자: 층 하나의 밴드 분석(창 복사, FFT, 밴드)
        case raster             // 작업자: 층 하나를 그리고 자르기
        case pixelCount         // 작업자: 칠한 화소 세기와 메모리 장부 검사
        case footprint          // 작업자: 층 하나의 SubtitleFootprint 만들기
        case sourceFrame        // 펌프: 리더에서 영상 프레임 받기
        case frameCopy          // 펌프: 출력 버퍼 받기와 프레임 복사
        case composite          // 펌프: 스펙트럼·자막 발자국 섞기
        case append             // 펌프: 쓰기 쪽에 프레임 넘기기
        case writerWait         // 펌프: 쓰기 쪽이 준비되기를 기다린 시간
    }
    struct Cell: Sendable, Equatable { var count = 0; var totalNanos: UInt64 = 0, maxNanos: UInt64 = 0 }
    private(set) var cells = [Cell](repeating: Cell(), count: Stage.allCases.count)
    /// 스펙트럼을 그린 프레임 수와 층·프레임 수, 실제 내보내기 중 메모리 장부(계산한 상한)의 최고값
    var spectrumFrames = 0, layerFrames = 0, ledgerPeakBytes = 0
    /// ExportService 호출 전체의 벽시계 시간과, 그동안 늘어난 프로세스 CPU 시간(모든 스레드)
    var exportWallNanos: UInt64 = 0, processCPUNanos: UInt64 = 0

    subscript(stage: Stage) -> Cell { cells[stage.rawValue] }
    mutating func add(_ stage: Stage, nanos: UInt64) {
        cells[stage.rawValue].count += 1; cells[stage.rawValue].totalNanos += nanos
        cells[stage.rawValue].maxNanos = max(cells[stage.rawValue].maxNanos, nanos)
    }
    /// 사람이 읽는 줄(시험 실행기 출력용)
    func lines() -> [String] {
        func ms(_ n: UInt64) -> Double { Double(n) / 1_000_000 }
        var out = [String(format: "  profile: export wall %.2f s, process CPU %.2f s, spectrum frames %d, layer-frames %d, ledger peak %.1f MiB",
                          ms(exportWallNanos) / 1000, ms(processCPUNanos) / 1000, spectrumFrames, layerFrames, Double(ledgerPeakBytes) / 1_048_576)]
        for s in Stage.allCases where self[s].count > 0 {
            let c = self[s]
            out.append(String(format: "  profile %@: calls %d total %.1f ms avg %.2f ms max %.2f ms", "\(s)" as NSString, c.count, ms(c.totalNanos),
                              ms(c.totalNanos) / Double(c.count), ms(c.maxNanos)))
        }
        return out
    }
}

/// 여러 큐에서 더한다(작업자 actor, 영상 큐). 잠금 하나, 값은 고정 크기다.
final class SpectrumExportProfiler: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: SpectrumExportProfile())
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    func record(_ stage: SpectrumExportProfile.Stage, since start: UInt64) {
        let end = Self.now()
        state.withLock { $0.add(stage, nanos: end >= start ? end - start : 0) }
    }
    func noteFrame(layers: Int, ledgerPeak: Int) {
        state.withLock { $0.spectrumFrames += 1; $0.layerFrames += layers; $0.ledgerPeakBytes = max($0.ledgerPeakBytes, ledgerPeak) }
    }
    func noteLedger(_ peak: Int) { state.withLock { $0.ledgerPeakBytes = max($0.ledgerPeakBytes, peak) } }
    var snapshot: SpectrumExportProfile { state.withLock { $0 } }
}

extension ExportFrameOverlay {
    /// 집계가 없는 공급기(기존 내부 조각)는 재지 않는다
    var profiler: SpectrumExportProfiler? { nil }
}
#endif
