# SP-3C2-40 — 프리뷰 경계 체크포인트와 Stage 4 계약

2026-11-06. 게시 기준 `c2a6dc2e7a3550be4c783f3622b8e3e47f7f8707`. **STAGE 4 CONTRACT READY**는 아래 설계의 검토 완료이며 export 구현·제품 정책 승인·Stage 3C-2 전체 수락이 아니다. 이번 작업은 감사와 문서 갱신뿐이며 새 빌드/기능 실행은 없다.

## 1. 경계 진단과 증거 구분

SP-3C2-39가 SP-3C2-34 원본 trace를 상관 분석하고, 기존 signed 앱 및 Debug 계측 앱으로 각각 다섯 생성 fixture를 재실행했다. 각 실행 세트 135/135, 자막 1800/1800, 픽셀40/40, 선행 갱신70회·접근 갱신에 의한 내용 있는 레이어 제거0회다. 이는 이번 감사의 새 실행이 아니다. 원본/재현/계측을 혼합해 과거 미기록 값을 채우지 않는다.

| 원본 대상 | 직접 확인된 상태 | 다음 올바른 model-layer 게시 | 분류 |
|---|---|---|---|
| gap-image 시작 | 첫 tick 전, item 0, access unknown | play 명령 후102.516ms | A 준비 상태 |
| gap-video 시작 | 동일 |108.980ms|A|
| image-only 시작 | 동일 |93.410ms|A|
| mixed 시작 | 동일 |103.346ms|A|
| tail 시작 | 동일 |95.893ms|A|
| gap-image 120 | 유효 lease, timing nil 뒤 frame120 재요청·결과 대기 | 관측 후7.776ms | B 프리뷰 표시 공백 |
| gap-video 120 | 유효 lease, current nil | 관측 후10.295ms | B |
| tail 240 | 유효 lease, current nil | 관측 후10.781ms | B |

전환의 실제 model-layer 제거→재게시 시간은16.626/16.663/16.659ms다. 새 계측에서는 표시 목표가 공백의120/240인 반면 fallback item time은 아직 covered119/239여서 두 경로가 모두 nil인 순간을 확인했다. 공백 진입 후 재요청→ready→다음 tick 게시로 회복했다. 원본 trace에는 해당 tick의 세부 PTS가 없으므로 새 입력값을 원본 값으로 주장하지 않는다.

시작 첫 게시 뒤에도 원본에서83.309–91.685ms의 별도 공백이 있다. 새 계측은 음수 요청 시각 및 이후 새 영상 버퍼 대기를 기록했다. 최초 준비 상태(A)와 이 프리뷰 시작 UX 제한(B)을 구분한다. 최초 `.playing` 관측은 정확한 상태 전환 순간이 아니다. 불가피하거나 소유자가 수락한 UX라고 판정하지 않는다.

선택 WAV 매핑은 `sourceIn + k - clip.start`: sourceIn30/start0인 대상에서120→150,240→270,48kHz sample240000/432000이다. 해당 생성 fixture에서 공유 source mapping 결함(C), stale 이미지 게시, 만료 lease 게시는 발견되지 않았다. 다른 오디오 fallback은 사용하지 않는다. 이 fixture에 없는 split/move 조합의 새 검증이나 모든 파일/시간의 정확성 보장은 아니다. 과거 SP-3C2-31/32 추적, 느린 검증 실패와 빌드/harness 실패 기록도 유지한다.

근거는 제외된 `app/selftest-work/sp3c239/`의 `historical-eight-cases.json`, `causal-summary.json`, `replay-analysis.json`, `instrumented-analysis.json`, `build-result.json`, 두 launch-exits 파일 및 원시 capture다. 최초 증거는 `app/selftest-work/sp3c234/`에 그대로 있다. physical scan-out/청취·장시간 drop rate는 측정하지 않았으며 무공백 프리뷰를 주장하지 않는다.

## 2. Debug 변경 감사

후보는 PlaybackSpectrumController.swift의 event23/24 계측과 ImageSpectrumSelfTest.swift의 이벤트 정의 주석이다. Release 전처리 분기를 제거해 공백/주석을 제외한 코드 토큰을 HEAD와 대조하면 동일하다. Debug에서도 원래 output query/copy 및 fallback query의 순서와 반환 선택을 유지하며 원본 접근·lease 계약을 약화하지 않는다. 강제 unwrap은 nil 분기의 short-circuit 뒤에서만 실행된다.

기록은 MainActor에서 기존 preallocated numeric buffer에만 append한다.8192개·2MiB 저장 한도, 초과 시 중단/truncated 유지. recorder에 파일 I/O·잠금·새 task가 없고 event23/24는 시각·frame·enum·boolean만 기록한다. 원본 경로/미디어/자막은 추가 기록하지 않는다. 기존 process-local ID와 hash는 개인 식별자가 아니지만 raw trace는 계속 게시 제외다. 저장은 capture 종료 후다. 전체 callback에는 원래 AVFoundation 호출이 있으므로 전체 callback의 무차단 또는 무오버헤드를 주장하지 않는다. Debug 비활성 상태에도 일부 계산 비용은 남으며, boundary 범위는 이번 fixture용 고정 프레임이다. 전체 프로세스 메모리가2MiB 이하라는 뜻도 아니다.

SP-3C2-39 signed 빌드·두 실행 세트·trace 상한 검증을 재사용한다. 이 감사에서 새 빌드는 없다. 두 소스 지문과 기존 원본 증거 지문을 대조한다. 중대한 후보 차단 결함은 발견되지 않았다.

## 3. 실제 export 구현과 재사용 경계

- `CompositionPlanner.swift`: 타임라인 durationFrames, 영상 composition/videoComposition, 빈 구간 채움, clip audio ramps/audioMix, renderedSubtitles, spectra를 계획에 담는다. spectra를 운반하는 것과 실제로 그리는 것은 다르다.
- `ExportService.swift`: spectrum 포함 계획은 임시 출력 생성 전에 거부한다. 내부 image export도 별도 gate와 spectrum 거부를 유지한다. hasVideo 없는 일반 계획은 거부한다. 원본과 대상 경로/identity 보호, 대치 확인, 같은 볼륨의 임시 디렉터리, 인코딩 후 영상 길이·트랙 수 검증, 승격 전 취소/대상 재검증, 새 대상 RENAME_EXCL/기존 대상 replaceItemAt, 작업 소유 temp 정리가 구현돼 있다. 파일시스템 경쟁의 모든 형태를 원자적으로 해결했다고 확대하지 않는다.
- `SubtitleExport.swift`의 SubtitleExporter: 기본 합성기→420v reader→프레임 k의 t=k/30→footprint 합성→AVAssetWriter. 일반 경로는 PTS≤t인 마지막 reader 표본을 재사용하고 내부 이미지 경로는 strictFrameGrid로 정확한 PTS를 요구한다. 원본 sample 재사용을 spectrum 결과 생략과 혼동하지 않는다.
- audioMix reader는48kHz stereo float PCM을 읽어 AAC writer에 넣는다. 현재 writer 설정은 FHD30/SDR/H.264/AAC MP4다. FootprintWindow는 활성 자막만 보관하고 정해진 입력 순서로 합성한다. 전체 영상 BGRA 왕복 대신 잘린 premultiplied raster의 발자국만420v에 합성한다.
- 기존 reader/writer backpressure·pump error/cancel·finalizing 보호는 재사용 대상이다. 현재 videoStep은 동기 callback이므로 여기에 MainActor 대기나 무기한 semaphore를 넣을 수 없다. async spectrum 준비와 writer callback 연결은 아직 구현되지 않았다.
- 내부 이미지는 InternalImagePreview의 별도 composition·원본 검증 경로를 쓴다. 공개 gate와 strict PTS 계약을 이번 설계로 해제하지 않는다.
- SpectrumAnalysis/FrameMap/SourcePiece/FrameRenderer/FrameCoordinator는 공유 후보다. coordinator는 접근 scope를 소유하지 않으며 기존 scheduler의 dropped 결과는 프리뷰 정책이다. export가 이를 무음으로 취급해서는 안 된다.

## 4. 제안: 결정적 프레임 API

아래는 구현 전 제안이며 새 공개 API/제품 설정 확정이 아니다.

`prepareFrame(jobID, snapshotID, frameIndex: Int, deadline, cancellation) async throws -> PreparedSpectrumFrame`

1. immutable timeline/media identity/style snapshot과 별도 export analysis session을 job에 고정한다.0≤k<N, fps30, 정확한 CMTime(k,30). AVPlayer/display-link/host clock을 프레임 선택에 사용하지 않는다.
2. [start,end) coverage로 보이는 spectrum 항목을 정해진 레인 순서로 선택한다. sourceKey의 모든 조각을 사용하고 clip.start/sourceIn/lineage 및 clip/lane gain·fade·mute를 보존한다. 각 sample은 SpectrumFrameMap의 정수/유리수 매핑으로 계산하며 FFT 창·offsetMs가 조각 경계를 넘으면 각 조각과 zero-fill을 적용한다. 단순히 WAV frame k를 분석하지 않는다.
3. 같은 SpectrumAnalysis 설정과 SpectrumFrameRenderer의1920×1080 canvas, drawRect, 좌표·crop·style·alpha를 사용한다. 반환에는 job/snapshot/k/item identity, bands, optional raster/geometry, 명시적 empty 이유를 포함한다. 소스 조각 없는 시간과 실제 무음은 정상 분석 결과다. 디지털 zero에서 raster nil은 정상일 수 있지만 다른 스타일의 무음을 임의로 빈 그림으로 바꾸지 않는다.
4. ready 또는 의미 있는 정상 empty가 모두 준비돼야 프레임 k를 writer에 넘긴다. notVisible은 해당 항목만 제외한다. unset/missing source·overlap은 승인된 D-S3/D-S8에 따라 preflight 거부한다. mediaUnavailable/analysis/render failure·superseded·unexpected itemMissing·dropped는 명시적 실패다. 늦었다고 이전 그림을 쓰거나 필요한 spectrum을 빼고 성공시키지 않는다.
5. 합성은 기존 video/image 출력→spectrum→subtitle. 자막과 겹치는 픽셀은 자막이 위다(D-S4). SpectrumRenderedFrame에서420v footprint로 연결하는 adapter는 새로 필요하다. 기존 SubtitleFootprint와 수식·premultiplied alpha·crop/chroma 위치를 공유하되 타입/반올림 parity를 시험한다. 기존601 입력의709 태깅 문제를 이 작업에서 해결됐다고 바꾸지 않는다.
6. export job이 원본 scope/read access와 identity를 소유한다. 생성 당시·원본 open/read·승격 전 검증 및 취소 시 해제를 설계한다. path가 같아도 바뀐 파일은 거부한다. preview의1초 lease를 export 권한으로 쓰지 않는다. OS I/O의 강제 중단은 보장하지 않는다.

### 제한·취소 제안(첫 개발 시험의 내부 상한)

- export job1, outstanding frame1, FFT worker1, pending1, waiter1; render 결과1개만 보유하고 append 뒤 해제. 기존 reader current/next와 writer pool도 측정하며 전 프레임 배열 금지.
- scheduler chunk cache32MiB, band cache64개, frame raster16MiB 상한 제안. 현재 scheduler는 최근 chunk1개와 작업이 보유한 chunk가 cache 계수 밖에 남을 수 있다. 따라서 cache32MiB를 전체 메모리 상한으로 주장하지 말고 별도 in-flight byte 계수와 pre-admission 제한을 구현해야 한다. 첫 fixture는48kHz stereo만 허용한다.
- 프레임 준비/원본 open/reader·writer 무진행 각각10초 deadline,12초 fixture job 전체120초 watchdog을 시험용으로 제안한다. 공개 성능 기준이 아니다. 초과는 명시적 timeout 실패·취소로 종료하고 재시도 폭주를 만들지 않는다. 결과 전달은 정확히 한 번, late callback은 job token으로 거부한다.
- async worker 결과를 전용 직렬 pump 상태에 넘겨 writer-ready일 때만 append. MainActor/reader-writer callback을 기다리는 semaphore나 바쁜 polling 금지. 취소/timeout은 producer와 reader/writer를 취소하고 승격을 금지한다. 비협조적 I/O가 남으면 실제 drain까지 scope와 슬롯을 유지하며 다음 job을 겹쳐 시작하지 않는다. bounded 실패 보고와 즉시 OS 작업 회수는 다른 보장이다.
- 전체 process footprint512MiB 증가를 첫 시험 중지 기준으로 제안하고 측정한다(지원 보장 아님). 생성 fixture·진단 출력·build/cache를 포함한20GiB 관리 한도 우선. 구체적인 byte 계수·async bridge·timeout 주입 방법은 구현 전 확인 항목이다.

## 5. 첫 vertical slice와 객관적 검증

**제안 범위:** 생성 영상1개, 선택13초48kHz stereo WAV1개(sourceIn30으로0-offset 착오 검출), spectrum1개, 세 자막 [0,120),[120,240),[240,360),12초/360프레임/FHD30. video 원음은 명시적으로 mute해 WAV 믹스 기준을 단순화한다. 기존 MP4 설정 유지. 첫 slice에 이미지·순수 오디오·다중 spectrum 조합을 포함하지 않는다. 지원하지 않는 조합은 출력 전에 명시적으로 거부하고 기존 일반 export를 보존한다.

검증은 다음과 같이 층을 나눈다.

- 영상/길이:0,1,119,120,121,239,240,241,359 프레임의 생성 frame marker를 독립 decode로 확인. 전체360개 PTS=n/30, 마지막 duration/end12초, video1/audio1 트랙을 전수 확인한다. 기존 최종 length 검사만으로 PTS 전수를 증명하지 않는다.
- spectrum: 독립 WAV PCM 읽기와 source map으로 선택 프레임의 FFT 입력/밴드 참조를 만든다. 같은 공유 분석기를 쓴 비교는 일관성 검사이며 독립 수학 검증은 아니다. 별도 작은 DFT/알려진 tone으로 중심 주파수·무음·window 경계를 검증한다. 인코딩 전 raster와 420v footprint를 참조와 비교하고 bars 높이·좌표·alpha·subtitle occlusion 픽셀을 검사한다.
- 오디오: 인코딩 전 composition PCM에서 sourceIn/gain/mute/ramp와 기준 sample 위치를 확인한다. AAC decode는 손실 압축이므로 PCM bit equality를 요구하지 않는다. 생성 impulse/tone의 상관 분석, priming/edit-list·PTS/끝 길이로 고정 offset을 따로 기록하고 설명되지 않은 시간 이동은 실패로 처리한다. 손실 압축 수치 허용치는 같은 fixture의 spectrum-off 기준에서 사전 고정하고 실패 후 완화하지 않는다.
- 자막/geometry:119/120·239/240에서 이전 자막 제거/새 자막 표시, 공통 canvas 좌표와 잘린 drawRect, 겹침 픽셀에서 자막 우선 확인. paused confirmed preview의 동일 k raster와 비교한다. 연속 프리뷰 지연을 MP4의 허용 누락으로 전파하지 않는다.
- 출력 보호: 기존 sentinel 대상 hash를 고정해 encoding 중 취소, frame wait timeout, source 제거/교체, 분석 실패, 승격 직전 취소·대상 변경을 주입한다. 이전 출력 불변·새 부분 출력 미게시·작업 temp만 정리·늦은 완료 무시를 검사한다. 성공 재실행은 검증 후에만 승격한다. 전체 영상 디코드 파일을 쌓지 않고 선택 표본/해시·짧은 실패 로그만 보관한다.

## 6. 기존 결정과 열린 선택

| 주제 | 기존 계약/권고와 결정 경계 |
|---|---|
| 자막 z-order | D-S4 승인: 자막>스펙트럼>영상 유지. 재승인 불필요. |
| 소스 없음·같은 계보 조각 겹침 | D-S3/D-S8 승인: 대상 변경 전 거부. 무음으로 대체하지 않음. 서로 다른 spectrum 항목의 시각적 겹침과 구분. |
| 여러 spectrum 항목 | 첫 slice는1개. 이후 레인 순서 보존을 권고하나 export 동시 개수·자원 초과 정책/겹침 확대는 별도 범위 확인 필요. |
| 색·alpha | 기존 style와 premultiplied footprint 수식을 보존. 색 공간 정책 변경이나 HDR 확장은 소유자 결정이 필요하며 이번에 확정하지 않음. 현재 색 제한은 유지. |
| 늦음·frame 실패 | 지연 자체는 대기, deadline/실패는 export 실패가 제안. 공개 timeout·오류 UX·재시도 정책은 미확정. silent omission은 허용하지 않음. |
| 순수 오디오 검정 영상 | preview 구현이 export 지원 승인은 아님. hasVideo 거부를 유지하고 별도 slice·출력 계약 승인 필요. |
| 취소·부분 출력 | 기존 취소/실패 시 미승격·원래 출력 보존 유지. 부분 MP4 공개·resume 기능은 새 제품 결정이며 제안하지 않음. |

새 owner 결정 없이 보존할 수 있는 계약과 후속 범위 선택을 분리한다. 이번 감사에서 수동 수락이나 제품 선택을 요청하지 않는다.

## 7. Stage 3C-2 및 자원·다음 작업

영상 backed·lead-in·공백·꼬리·pure-audio, 내부 image-covered/gap/tail·mixed, 선택 계보/시간 매핑, proactive renewal은 구현 및 해당 자동 fixture 검증 범위다. 과거 영상·공백·꼬리 제한 수락만 유지하고 **최신 통합판 OWNER MANUAL DEFERRED**다. 전체 Stage 3C-2 수락은 미완료다.

시작/전환 UX 공백, 느린 access validation starvation, large-catalog, 간헐 image player-layer, full Release app, 장기/물리 timing은 남는다. B는 Stage4 설계·제한된 prototype의 일괄 차단 사유가 아니다. 공유 매핑 C가 새로 발견되면 수정 전 구현 진행을 재평가한다. 최종 release 수락과 prototype 진입은 다르다.

이번 시작 관리량19,041,872KiB(약18.160GiB), 여유 약1.840GiB. 문서 수 KiB만 추가하며 새 빌드/대형 산출물/삭제 없음. 미래 작업은 기존 fixture/엔진 바이너리 재사용, 단일 job, 제한 APFS scratch와 build/cache 포함 사전 예산,20GiB 도달 전 중지 계획이 필요하다. 용량 부족 시 별도 승인된 좁은 cache 정리 또는 증거 의존성 검토 후 artifact 재배치/이미지 관리안을 제안하되 이번에 수행하지 않는다.

다음 권고는 이 체크포인트의 검토·게시 작업을 별도 지시로 수행한 뒤, 본 계약의 비동기 frame bridge/메모리 계수를 구체화한 첫 Stage4 구현 작업이다. 이번에 export rejection을 제거하거나 export를 구현하지 않았다.
