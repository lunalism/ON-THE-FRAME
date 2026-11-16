# SP-4A-04 — 내부 spectrum export 마무리·실패 안전성

2026-11-06. **EXPORT SAFETY PASS — 아래 생성 fixture/시험 범위.** 생성 fixture·내부 Debug 12초 slice에 한정한다. 공개 export/이미지 활성화, schema 변경, 소유자 데이터 변경, staging/commit/push는 없다. **OWNER MANUAL DEFERRED — NOT PASS.**

## 기준 및 실제 생명주기

기준 branch `feature/subtitles`, HEAD/upstream/live remote `e96b8570d286d7fb82258907e81c971cbd39dd62`, main `44943eadabdf5a37d5242d614e7279813126dfde`. 시작 tracked/index clean, 기존 미추적4개와 복구 refs3개 보존. 시작 관리량19,325,548KiB(약18.430GiB). [이전 구현·감사](SP-4A-01-SPECTRUM-EXPORT.md), [설계 계약](SP-3C2-40-EXPORT-CONTRACT.md)의 범위와 기존 한계를 유지한다.

1. immutable timeline/media identity snapshot → job scope/전역1-slot 획득 → composition 생성.
2. 0..<360 프레임을 한 worker가 순서대로 준비. 선택 lineage/sourceIn/common FFT·renderer 유지. reader 영상 → spectrum → subtitle → writer append(k/30).
3. frame deadline/job watchdog은 pump 오류를 기록하고 두 입력 큐를 깨운다. 취소도 같은 경로다. 각 입력 종료·callback group 완료 뒤 reader/writer 취소와 temp 정리가 가능해진다.
4. 정상 pump 종료 뒤 endSession(12초) → finishWriting → 완료 상태 확인.
5. ExportService에서 영상/오디오 트랙·길이 확인 → 승격 직전 취소/원본/대상 재검증 → 기존 promote → 성공 progress1.
6. 작업 소유 temp만 defer 정리. 비협조적 준비 작업은 실제 drain까지 scope/slot을 보유하며 늦은 callback은 videoDone에서 버린다.

기존 마지막 취소 검사와 native finish 호출 사이에는 경합이 있었다. API 취소 요청과 native 작업의 실제 종료는 서로 다른 시점이다.

## 직접 재현한 결함과 최소 수정

Debug 전용 checkpoint에서 finalization 진입을 보류한 뒤 Task.cancel을 호출하고 보류를 해제했다. 기존 cancellation handler가 writer를 취소했는데 이어서 finishWriting을 호출해 다음 Objective-C 예외로 프로세스가 종료됐다.

`NSInternalInconsistencyException: finishWritingWithCompletionHandler: Cannot call method when status is 4`

기준 계측 실행 exit−6, wall45.35초. 기존 성공 출력 SHA는 그대로였다. 이 crash는 Swift catch로 회수되지 않아 정상 defer cleanup을 주장할 수 없다. 당시 temp 경로는 개별 기록되지 않았으므로 crash temp의 제거 여부는 미확인이고, 추정 경로를 찾아 삭제하지 않았다. 원본 실행 로그·바이너리·계측 소스·출력 해시 증거를 모두 보존했다.

**수정은 이 경합에 한정:** `SubtitleExporter.WriterFinalization`이 finish 시작과 cancel을 같은 NSLock으로 직렬화한다. `.writing`일 때만 native finish를 시작하며 이미 취소/실패/완료 상태이면 호출하지 않고 continuation을 반환한다. cancel은 finish 시작 전의 writing 상태에만 호출한다. 이미 finish가 시작됐으면 native cancel을 호출하지 않고 실제 completion까지 drain한다. 실제 finish completion callback은 기존처럼 await하며, 취소는 CancellationError, deadline은 명시적 finalization failure, 정상 완료는 writer.status로 구분한다. lock은 await를 가로질러 보유하지 않는다. 일반 subtitle export의 nil-spectrum finish 분기는 그대로다.

초기 수정 재실행은 같은 취소를 `.cancelled`로 반환했고, 기존 출력 SHA 보존·현재 temp 제거·worker idle까지 통과했다. 그러나 실제 finish/cancel 호출 경합 검사에서 두 번째 정지를 발견했다. finish 시작 뒤 cancelWriting이 반환했는데 status=1(.writing)이고 completion 대기가 끝나지 않았다. 첫 실행은 스택 보존 뒤 자체 검사 프로세스만100.34초에 종료(exit−15), 상세 재현은10초 한도에서11.05초에 종료(exit−15)했다. 둘 다 기존 출력 SHA는 보존됐다. 스택은 native 작업 강제 종료 가능성을 입증하지 않으며, 이때 caller continuation이 완료되지 않은 사실과 cancel 반환 status 로그를 근거로 삼는다.

최종 수정은 같은 잠금 아래 finishStarted를 기록하고, 시작 전 취소와 시작 후 drain을 구분한다. 진행 중 native finish에 cancelWriting을 재호출하지 않아 이 정지를 피한다. 실제 native 호출12회(취소 전/경합/완료 후 각4회)가 최종 코드에서 exit0으로 통과했다. 시작 후 취소라도 promotion 전 Task.checkCancellation으로 `.cancelled` 처리하며, deadline도 완료 후 명시적 실패로 처리한다. native finish 자체가 끝내 반환하지 않는 경우의 hard termination이나 deadline 내 반환은 보장하지 않는다. major encoder 재설계나 기능 범위 확대는 없다.

## 시험 지점과 소유권

`SpectrumExportCheckpoint`와 optional hook/writer-pause는 모두 DEBUG 전용이며 internal API controls에만 존재한다. 기존 호출의 기본 동작은 hook 없음이다. framePreparation/analysis, beforeFinalization/finalizationPending/afterFinalization, promotionPreparation/promoted를 관측·보류한다. 시험은 actor continuation으로 멈추며 MainActor를 sleep/semaphore로 막지 않는다. writer-pause는 입력 큐를 반환시켜 쓰기 진전이 없는 상황을 만든다.

finalizationPending 재현은 cancellation handler가 설치됐고 native finish 시작 전인 경계다. 이를 native codec 내부가 임의로 멎은 시험으로 부르지 않는다. 별도의 실제 AVAssetWriter 호출 순서 경합 검사로 취소-before-finish/경합/finish-before-cancel을 보강한다. 이 native 단위 검사는 생성1프레임 writer fixture이며 새 export API나 지원 길이를 추가한 것이 아니다. 비협조적 native I/O의 강제 중단 보장은 여전히 없다.

원본 교체는 생성 WAV를 보존 이름으로 이동한 뒤 같은 바이트를 다른 inode로 복사한다. 소실은 이동만 한다. 이후 새 파일도 별도 보존 이름으로 옮기고 원래 inode를 복구한다. 원본/영상/생성 프로젝트 해시와 원래 FileIdentity 복원을 확인한다. owner 파일은 사용하지 않는다.

모든 실패 사례의 기존 대상은 SP-4A-01 최종 성공 MP4의 사본이다. 기준 SHA-256은 `04c346e4edcc1e442eb60cfb9e4a362b47f8d44e7e2dda068131640b421c4745`. 각 결과에 destinationBefore/After를 기록한다. 작업별 owned-temp-path와 결과를 기록하며 다른 작업의 temp는 정리하지 않는다.

### 취소의 승격 경계

promotionPreparation 시험은 마지막 취소/원본 검사 전에 주입한다. 여기서 취소되면 승격하지 않는다. 새 파일의 성공 rename 또는 기존 파일의 성공 replace가 비가역적 게시 시점이다. `promoted` hook은 그 성공 뒤다. 그때 도착한 취소는 이미 게시된 파일을 rollback하지 않으며 결과는 completed다. 마지막 검사와 파일시스템 연산 사이의 모든 OS 경쟁을 원자적으로 해결했다는 뜻은 아니다.

## 증거 위치와 실행 범위

원시 증거는 Git 제외 `app/selftest-work/sp4a04/`에 있다. `baseline/`·`matrix-baseline.json`·`baseline-crash-output.json`은 재현 실패, `fixed/`와 `matrix-fixed.json`은 수정 후 각 사례, 추가 retry/native 검사는 별도 폴더, 정상 회귀는 `regression/`에 보존한다. 최종 전체 행렬은 `final/`·`matrix-final.json`, native 보강은 `drain-native/`, 진행 후 writer 정지는 별도 `progress/`에 기록한다. 이전 SP-4A-01/02 증거는 삭제하거나 새 결과로 덮어쓰지 않는다.

새 `app/scripts/SpectrumExportSafetyCheck.swift`는 새 disposable fixture 폴더와 case 이름을 받는 CLI다. 기존 generated video/WAV/성공 MP4를 사본으로 공급한다. 새 프로젝트가 이미 있으면 재실행을 거부한다. 실제 호출/자원 감시는 제외된 run-matrix.py에 기록한다. 기존 `SpectrumExportSliceCheck.swift` 및 `SpectrumExportDFTCheck.py`는 수정하지 않고 새 Engine 산출물과 생성 사본으로 회귀한다.

## 제한

시험 controls의 step10초/job120초와 stall용 짧은 값은 제품 약속이 아니다. 기존 deadline은 encoder pump/finish 범위이며 planner·원본 사전 검사·최종 verification/promotion 전체의 hard timeout이 아니다. native API가 블록되거나 completion을 돌려주지 않는 상황에서 lock/취소 호출이 즉시 반환한다고 보장하지 않는다. 실제 권한 철회, 디스크 고장, 모든 취소 interleaving, 장시간/전체 Release는 미검증이다.

공개 spectrum export, image-spectrum, pure audio, 다중 spectrum, 새 스타일/포맷, schema는 추가하지 않았다. owner 시각/청취 및 최종 preview/export parity 수락, Stage4 전체 완료를 주장하지 않는다.


## 최종 안전성 행렬 — 이번 새 실행

최종 Engine에서 기본18개 + 이미8프레임 진행 후 writer 정지2개 = **20/20 통과**, 각 process exit0. 별도 실제 native finish/cancel 호출 순서 **12/12 통과**(각 순서4회), exit0. 성공 승격 뒤 취소1개를 제외한19개 사례에서 기존 출력 SHA는 위 기준과 동일하다. 대상 파일을 원본 WAV로 지정한 거부도 WAV 해시/identity로 함께 확인했다. 20개 사례에서 기록한 작업 소유 temp18개가 모두 제거됐고, 각각 worker idle 및 source 복원을 확인했다.

| 사례 | 결과 | 주입 뒤 결과까지(초) |
| --- | --- | --- |
| `cancel-finalization-pending` | cancelled | 0.0113 |
| `cancel-before-finalization` | cancelled | 0.0245 |
| `cancel-after-finalization` | cancelled | 0.0017 |
| `cancel-promotion-preparation` | cancelled | 0.0007 |
| `replace-before-preparation` | failed | 0.0011 |
| `disappear-before-preparation` | failed | 0.0010 |
| `replace-processing` | failed | 0.0801 |
| `disappear-processing` | failed | 0.0121 |
| `replace-pending-fft` | failed | 0.1200 |
| `replace-before-promotion` | failed | 0.0621 |
| `analysis-stall` | failed | 0.1099 |
| `frame-stall` | failed | 0.1108 |
| `writer-stall` | failed | 1.0116 |
| `cancel-analysis-stall` | cancelled | 0.0035 |
| `cancel-writer-stall` | cancelled | 0.0035 |
| `source-destination` | failed | 0.0029 |
| `cancel-after-promotion` | completed (이미 승격) | 0.0006 |
| `cancel-analysis-stall-retry` | cancelled | 0.0035 |
| `writer-stall-after-progress` | failed | 1.0672 |
| `cancel-writer-stall-after-progress` | cancelled | 0.0092 |

100ms step 제한의 분석/프레임 보류는 명시적 frame deadline failure다. writer 시작 시 정지는1초 job 제한, frame8 뒤 정지는2초 job 제한을 사용했다. 뒤의1.067초는 정지 신호 이후의 시간이며 전체 job 시작 이후2초 한도와 구분한다. 취소는 실패 문자열로 바꾸지 않고 cancelled다. non-cooperative Hold가 남아 있을 때 slot을 유지하고 새 요청을 still-draining으로 거부한 뒤, Hold 해제/늦은 callback 처리 후 idle을 확인했다. `cancel-analysis-stall-retry`에서는 같은 프로세스에서 새 정상 export를 실행해360장 전체 decode/PTS를 확인했다. 이는 OS scope 철회 실험이 아니다.

실제 native 순서 결과: cancel-before-finish는 cancelled(status4)4회, 경합은 drain 후 completed(status2)4회, finish-before-cancel도 completed4회다. helper의 native 완료 상태와 ExportService가 Task 취소를 최종 cancelled로 반환하는 것은 별개다. callback이 돌아오기 전 자원을 놓거나 temp를 지워 성공으로 표시하지 않는다.


## 정상 회귀·검증 결과

SP-4A-04에서 최종 Engine을 링크해 기존 SpectrumExportSliceCheck를 **새 실행**했다(exit0). 정상 spectrum MP4360장/정확한k/30 PTS/12초/모든 영상 marker, 인코딩 전 Y·CbCr 참조 오차0, 최종 decoded Y 전체화면 평균 최대0.0465022, 자막119/120·239/240/마지막359 표본 통과. PCM sourceIn1초 비교 오차0, AAC1,152,000 sample values/RMS 최대0.00197914. 일반 자막 경로도360장 전체 decode/PTS 통과. enabled=false·일반 spectrum·pure audio·다중 spectrum·missing source·image gate-off 거부, 기존 실패/취소/timeout/writer초기화/promotion/source소실6종 및 temp5개 정리도 다시 통과했다.

기존 DFT 스크립트를 새 fixture에 실행해220/440/880Hz→밴드33/42/52, pulse8/16/12를 확인했다(exit0). 기존 SP-4A-02 읽기 바이너리도 새 MP4에 실행해 영상360 PTS·오디오0–12초 연속576,000 stereo sample frames와 대표3프레임 spectrum색 영역을 확인했다(exit0). Y/CbCr 오차0은 pre-encode 수치이며 최종 H.264/AAC 무손실이나 독립 renderer 수락으로 해석하지 않는다.

SP-4A-04의 Engine Debug 제한 빌드3회(계측 기준/첫 수정/최종 수정) exit0, 각 CLI 컴파일 exit0. 기존 CoreSimulator 버전 진단은 있었으나 BUILD SUCCEEDED이며 앱/Release/prototype/WMO 빌드는 없다. 이전 결과를 새 실행으로 바꾸지 않는다. 처음 계측 기준 crash−6과 첫 수정 뒤 native 정지 종료−15 두 건은 그대로 보존한다. 최종 코드에서20개 안전성 사례·native12회·정상 회귀 suite·DFT·읽기 검사는 모두 SP-4A-04의 새 실행이었다. 아래 SP-4A-05 감사에서 재실행한 것은 아니다.

## 정확한 변경과 자원

- `app/Engine/Sources/OnTheFrameEngine/SubtitleExport.swift`: 재현된 finalization 경합의 직렬화/시작 후 drain, Debug checkpoint/writer-pause.
- `app/Engine/Sources/OnTheFrameEngine/ExportService.swift`: Debug 승격 전후 관측 hook만 추가, 보호/승격 규칙 불변.
- `app/Engine/Sources/OnTheFrameEngine/SpectrumExport.swift`: Debug 시험 enum/optional controls, 준비/분석 관측 hook.
- `app/scripts/SpectrumExportSafetyCheck.swift`: 새 생성 fixture 안전성/재시도/native 경합 CLI.
- 이 문서와 `docs/ROADMAP.md`, `docs/HANDOFF.md`: 재현·수정·검증·남은 한계 기록.

이전 회귀 스크립트2개와 이전 최종 MP4/fixture/evidence 해시, 기존 미추적4개·복구 refs는 유지한다. **엔진3 + 새 검사1 + 문서3 = 총7개** 변경이다.

기존1GiB 한정 APFS scratch·Engine 산출물/cache를 재사용하고 single-job 빌드, 관리량19.8GiB/scratch여유50,000KiB 조기 중지 감시를 유지했다. 관리 root 합계의 시작은18.430GiB, 최종 시험 관측 최고19,520,968KiB(약18.617GiB)로20GiB 이하다. 추가량 약0.186GiB는 새 생성 사본·실패 증거·검사 바이너리·빌드 갱신을 포함한다. 기존 evidence/앱/캐시를 정리하지 않았다. 이 숫자는 프로세스 메모리 한도가 아니다.

**OWNER MANUAL DEFERRED — NOT PASS.** 다음 권고는 **SP-4A-05 — finalization/failure safety checkpoint audit**다. 특히 native finish drain의 완료 의존성과 deadline 해석을 감사하고, 더 강한 hard timeout/격리가 필요하면 별도 설계 범위로 결정한다. 공개 기능 활성화나 Stage4 전체 완료를 의미하지 않는다.

새 정상 출력 SHA-256: `522cd007df87764bf7cc558849a5ecfee405bda5f22f2971dd793d828f73e5f2`. 정상 회귀 wall114.47초/관측 peakRSS368,480KiB(하네스 참조 버퍼 포함). 개별 실패 대상 before/after SHA는 제외된 safety-summary.json 및 각 result.json에 보존한다.

검사 CLI는 증분 확장했다. 기본18개/최종 native12회는 spectrum-safety-drain, frame8 보강2개는 spectrum-safety-progress-recorded로 실행했다. 두 바이너리는 같은 최종 Engine.o를 링크하며, 마지막 하네스 소스 하나로20개를 한 번에 재실행했다고 주장하지 않는다. 정상 회귀는 spectrum-regression-final이다.


## SP-4A-05 — finalization 안전성 게시 감사 (2026-11-06)

**PUBLICATION READY — 현재 제한된 내부 checkpoint. 일반 출시 준비 완료는 아니다.** 정확한7개 후보를 전체 검토하고 SP-4A-04 최종 매니페스트의 후보/기록된 바이너리/정상 MP4 해시와 대조했다. 시작 시 모두 일치했다. 이번 변경은 이 문서와 ROADMAP/HANDOFF뿐이며 엔진3개·검사1개는 그대로다. 예기치 않은 tracked 변경, staging, symlink 대체는 없다. branch/HEAD/upstream/live remote/main·복구 refs3개·기존 미추적4개는 기준과 같다.

### Finalization과 완료의 근거

현재 encode 호출당 WriterFinalization 하나를 만들고 finish를 한 번 부른다. 같은 잠금 안에서 finishStarted를 세우고 native 호출을 시작하므로, cancel이 먼저 writer를 종료시키면 finish는 상태 검사에서 빠져나온다. finish가 먼저 시작됐으면 후속 취소와 deadline은 native cancel을 중첩 호출하지 않는다. 반복 cancel은 이 상태/잠금으로 직렬화되며 완료 상태를 다시 취소하지 않는다.

현재 한 번의 finish 호출에는 continuation의 즉시 반환 경로 또는 native completion 경로 중 하나만 선택된다. callback은 continuation.resume만 수행하며 같은 잠금을 다시 획득하지 않는다. 현재 호출 그래프에서 앱 수준 중복 resume·재진입 잠금 순환·중복 cleanup 결함은 발견하지 않았다. 다만 helper는 여러 번 finish를 호출해도 되는 일반 목적 idempotent API가 아니며, native callback이 계약대로 한 번 도착한다는 가정까지 앱이 독립적으로 강제하지는 않는다. native12회는 관측된 호출 순서의 증거이지 가능한 모든 interleaving의 증명은 아니다.

영상/소리 callback은 각각 직렬 큐의 done 플래그로 group.leave를 한 번만 수행한다. watcher와 wake closure는 group 종료 뒤 정리된다. 취소된 분석 Task는 완료까지 provider를 붙잡고, 늦은 준비 callback은 videoDone에서 버려 새 job에 게시하지 않는다. reader/writer 입력 종료와 native finish 완료를 기다리는 동안 호출 스택·writer box·source provider·temp defer가 살아 있으므로 정상 경로에서 조기 해제/중복 temp 삭제는 없다. OS 내부 자원의 모든 수명과 crash cleanup을 직접 계측했다는 뜻은 아니다. 기준 crash의 temp 제거 미확인 기록은 유지한다.

### 취소·deadline의 한계와 출시 분류

finish 이후 취소는 **native 완료를 기다린 후** Task.checkCancellation에서 반환한다. native finish가 영구 정지하면 성공/승격하지 않지만, job 반환·temp 정리·scope/slot 해제도 완료되지 않는다. deadline 플래그는 이를 강제로 끝내지 못한다. 현재의 명시적 Debug/test gate·생성12초 검증 범위에서 이 알려진 liveness 한계는 checkpoint 게시 차단 사유로 판단하지 않았다. **일반 출시의 bounded cancellation/복구·가용성 준비에는 차단 사항**이며, 별도 설계/수락 없이 일반 export를 활성화할 수 없다.

MainActor에 분석/렌더를 강제 배치하지 않고 await를 가로지르는 잠금이나 semaphore 대기는 없다. 그러나 onCancel은 취소 요청 스레드에서 실행될 수 있고 lock 안의 native cancel/finish 시작 호출이 항상 짧게 반환한다는 보장은 없다. MainActor에서 취소를 요청해도 언제나 무차단이라는 보장은 아니다. 현재 내부 CLI 경로의 시험과 미래 UI의 응답성 수락을 구분한다.

waitingSince부터 frame 준비 결과까지를 step deadline으로 관찰하며, worker를 강제 중단하는 대신 pump에 실패를 기록한다. 비협조적 worker는 실제 drain까지 slot/scope를 유지한다. 시험의1초/2초 writer 정지는 **전체 encoder job 경과시간**으로 감지한 것이다. 마지막 written 값 이후 무진전 시간을 재는 전용 idle timer는 없다. 10초/120초는 잠정 호출 controls이며 planner·사전 접근 검증·최종 파일 검증·promotion 전체의 wall-clock 한도가 아니다. watcher의 progress callback이나 native 입력 큐가 반환하지 않는 경우에도 즉시 실패 반환을 보장하지 않는다.

### 원본·승격의 TOCTOU 경계

lineage 선택, sourceIn/start, 공유 FFT/renderer, gain/zero-fill 규칙은 변경하지 않았다. 초기·frame 준비 전후·승격 전의 FileIdentity(device/inode/size/mtime)와 readability를 검사하며 무관한 소스로 fallback하지 않는다. 생성 fixture는 검사 지점에 남아 있는 교체/소실을 검출했다. Timeline snapshot은 불변 값이지만 파일 bytes가 고정되거나 파일 접근 권한이 영구 보장되는 것은 아니다.

stat/readability 확인과 실제 AVFoundation open/read, 마지막 source 검사와 promotion 사이에는 TOCTOU가 있다. 같은 inode/크기/mtime를 유지한 byte 변경이나 검사 사이 교체 후 복원, 외부 권한 철회를 모두 검출하지는 못한다. 대상도 최종 validate와 replace 사이의 외부 변경을 완전히 원자적으로 배제하지 못한다. 새 대상의 RENAME_EXCL과 기존 보호 규칙을 그대로 유지하며, 보편적 filesystem/sandbox 보장으로 확대하지 않는다.

마지막 Task.isCancelled 검사에서 인식한 취소는 promotion을 막는다. 그 검사 이후 source/destination 검증 및 실제 파일시스템 게시 사이에 새로 도착한 취소까지 원자적으로 차단하지는 않는다. 취소 요청 시각 자체가 파일 게시와 같은 잠금에 묶인 것은 아니다. 성공 rename/replace가 비가역적 게시 시점이며, 그 뒤 취소에 rollback을 주장하지 않는다. 동시 실패·취소에서는 pump의 첫 오류가 유지될 수 있고 모든 경합에서 cancelled가 실패보다 우선한다는 보장도 없다.

### 증거·게시 범위

SP-4A-04의20/20, native12/12, 실패/취소19개 destination 해시, temp18개 정리 단언, 같은 프로세스 재시도360장, 정상360장/DFT/PCM/AAC/자막/일반 export/gate 결과를 재집계했다. 현재19개 실패 대상 파일의 실제 SHA도 기록과 일치했다. 단일 owned-temp-path 기록은 현재 부재를 다시 확인했고, 재시도의 추가 temp 등 전체18개는 당시 결과 단언으로 확인했다. prior exit−6 및−15 두 건을 보존했다. 이번에는 기능 시험·새 decode·빌드를 실행하지 않았으며, 읽기 전용 해시/JSON/소스/인벤토리 검증과 diff/link 검사를 수행했다.

Y/CbCr 오차0은 pre-encode 참조 비교, 최종 H.264는 별도 Y 평균 비교, PCM과 손실 AAC는 별도 검사다. 독립 DFT는 알려진3개 tone의 peak 검증이며 모든 band/renderer/preview parity의 독립 증명은 아니다. 최신 하네스의 단일 바이너리 일괄20회 재실행으로 바꾸어 쓰지 않는다.

게시 후보는 기존 정확한7개, 모두 일반 파일100644다. 전체 SHA-256·목적은 SP-4A-05 최종 보고와 제외된 `app/selftest-work/sp4a05/publication-manifest.json`에 기록한다. MP4·생성 미디어/프로젝트·로그·원시 실패 증거·test binaries·빌드/cache·서명 앱·APFS 이미지와 기존 사용자 파일은 게시 제외·보존한다. 일반 spectrum/image/pure-audio/다중 spectrum gate, public image, schema, video→spectrum→subtitle 순서, 일반 subtitle nil-spectrum 분기는 유지됐다.

시작 관리량19,521,028KiB(18.617GiB), 새 대형 산출물/삭제 없이 문서·작은 감사 매니페스트만 추가했다. **OWNER MANUAL DEFERRED — NOT PASS.** full Release·장시간·실제 sandbox 철회·최종 preview/export parity·Stage4 전체 수락은 미완료다.

제안 commit subject: `Serialize spectrum export finalization and verify failure safety`. 다음 권고는 별도 지시에 따른 이7개 파일의 좁은 게시 checkpoint이며, 일반 출시 전 native finish liveness/복구 정책은 별도 설계·검증 과제로 남긴다. 이번에는 staging/commit/push를 수행하지 않았다.
