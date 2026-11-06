# SP-3C2-28 — 내부 이미지 스펙트럼 live-access 및 공백/꼬리

**IMAGE SPECTRUM INTEGRATION PASS — 자동 검증 범위. OWNER MANUAL DEFERRED — NOT PASS.**

기준은 `feature/subtitles` HEAD/upstream/live remote `6c358e650f528b9264186c769875cce2da4b4951`, main `44943eadabdf5a37d5242d614e7279813126dfde`다. SP-3C2-23/24의 소유권 차단은 SP-3C2-25/26에서 해결하고 SP-3C2-27로 게시했다. 그 읽기 전용 설치 계약을 그대로 사용하며 현재 접근을 별도 검증한다. 공개 이미지 게이트는 유지한다.

## 제품 변경 전 측정

먼저 진단 진입점과 새 Debug 검사만 추가한 서명 앱을 빌드했다. ProjectStore, PlaybackSpectrumController, SpectrumPreviewSession, InternalImagePreview의 제품 소스는 게시 HEAD와 일치했으며 지문을 `app/selftest-work/sp3c228/baseline-source.json`에 보존했다. 생성된 12초 WAV는 sourceIn 30, 타임라인 30 fps이고 자막은 0/4/8초에 바뀐다.

| 기준 fixture | 0–4초 FFT/레이어 일치 표본 | 4–8초 | 8–12초 |
| --- | ---: | ---: | ---: |
| 이미지 0–8초 → 오디오 꼬리 | 118 | 120 | 0 |
| 이미지 → 공백 → 이미지 | 119 | 0 | 118 |
| 이미지 → 공백 → 영상 | 119 | 0 | 118 |
| 이미지 → 영상 → 이미지 | 119 | 120 | 120 |
| 이미지 전용 시각 타임라인 + WAV | 119 | 120 | 120 |

실제 item time·composition/item 객체 identity·session/generation·별도 AVPlayerItemVideoOutput PTS·선택 WAV 원본 프레임·스펙트럼 레이어·자막 presentation·중앙 픽셀을 기록했다. 이미지가 덮인 구간은 실제로 작동했고, 공백/꼬리에는 spectrumFrame이 없었다. 단순 코드 도달성 추정이 아니다. 최초 fixture 변환에서 형식9의 temporal media `kind` 누락으로 열기가 거부된 결과도 별도로 보존했다. 정상 기준은 `baseline-valid/`다. 초기 300ms 고정 대기 재개 단언은 일부 실패했으며, 이후 실제 시각 진행을 기다리는 bounded 검사로 수정했다.

## 접근 계약과 소유권

- `ProjectStore.imagePlaybackAccessIsCurrent(for:)`만 live 검증의 생성·취소·만료를 관리한다. 기존 `imagePreviewEligibility`는 계속 읽기 전용이며 설치 당시 증거만 뜻한다.
- live 결과는 **검증 시작부터 1초**까지만 유효하다. 설치된 item/composition, session, generation, access revision, 별도 취소 serial에 묶인다. pending/unknown/failed/expired는 spectrum 재생을 허용하지 않는다. 검사 시간이 1초를 넘으면 성공했어도 만료돼 사용하지 않는다.
- worker는 한 개만 존재한다. 취소해도 실제 worker와 완료 전달이 끝날 때까지 슬롯을 유지한다. 실패 후 재시작도 시작 시각 기준 최대 초당 한 번이다. display-link에서 동기 파일 I/O·probe/decode를 하지 않으며, 일시정지 중 반복 타이머를 만들지 않는다.
- 현재 snapshot의 전체 이미지 catalog에 기존 `ProjectPersistence.validateImageReference`를 사용한다. 검증 worker 안에서 추가 scope 획득을 시도하고 획득했을 때만 균형 있게 해제한다. 상대 URL은 소유자의 디렉터리 grant로 읽을 수 있어 새 URL scope가 없을 수 있다. 기존 이미지 planner와 같이 **실제 전체 읽기 성공**을 반드시 요구한다. 프로젝트 종료는 worker를 취소하고 완료 컨텍스트를 거부한다.
- 재빌드·설치 증거 무효화·알려진 가용성 변경·scope 종료는 lease를 폐기한다. 재연결 후보 시작도 즉시 폐기한다. 일반 seek는 같은 원본의 유효 lease를 보존하지만 controller의 pending-seek 표시 차단은 유지한다.
- 외부 파일 소실/권한 변경은 다음 검사에서 발견한다. 직전 성공 이후부터 만료 전까지의 변화는 즉시 감지되지 않는다. 허용 구간은 1초 lease와 다음 실행 가능한 display tick으로 제한되며 OS 스케줄링을 포함한 hard real-time 보장이 아니다. 파일 이벤트 감시나 영구 접근 승인이 아니다. 알려진 변경은 즉시 무효화한다.
- live 검사 실패는 역사적 설치 증거를 성공적인 현재 접근으로 바꾸지 않는다. cached 이미지 texture가 남아 있어도 스펙트럼은 비운다. 기존 이미지 missing 행 갱신과 planner의 두 번째 읽기 로직은 변경하지 않았다.

## 타이밍과 fallback

재생 중·rate 유효·현재 창/항목·같은 적용 세대·pending seek 없음의 기존 조건을 유지한다. 이미지 프로젝트는 live 접근 확인까지 요구한다. 시각 클립이 덮인 구간에서는 기존 요청/확인된 합성 출력 PTS 일치 경로만 쓴다. 시각 클립이 없는 공백/꼬리에서만 유효한 현재 AVPlayerItem 시각을 쓰며, 표시되는 spectrum의 선택 계보가 그 프레임에 활성이어야 한다. 실제 오디오 원본 접근 검사는 기존 SpectrumPreviewSession을 그대로 사용한다. 영상/이미지 복귀 시 fallback은 거부하고 확인된 출력 시각으로 돌아간다.

새 재생 시계·transport carrier·가짜 시각 클립·이미지 hold/프로젝트 길이·schema·자막 renderer·export 변경은 없다. 요청8개/보관8개/16 MiB/lookahead2 상한은 그대로다.

## 최종 자동 증거

최종 서명 Debug의 `observed/`에서 이미지→공백→이미지는 **서로 다른 녹색 JPEG A와 빨간 PNG B**를 사용했다. 나머지 네 fixture도 별도 복사본이다.

| 검사 | 결과 |
| --- | --- |
| 이미지→오디오 꼬리 | 27/27 |
| 이미지 A→공백→이미지 B, split/trim/move 포함 | 31/31 |
| 이미지→공백→영상 | 27/27 |
| 이미지/영상 혼합 | 27/27 |
| 이미지 전용 시각 타임라인 + WAV | 27/27 |
| live-access 생명주기 | 16/16 |
| 합계 | 155/155 |

- 다섯 fixture 각각 360개 시각 표본, 총1800개를 기록했다. 1783개는 선택 원본 FFT 대역과 해당 프레임의 실제 CALayer contents가 일치했다. 원본은 별도 열기/디코드와 명시적 `sourceFrame = spectrumFrame + 30` 매핑으로 비교하지만 **FFT 알고리즘은 같은 구현**이다.
- 최대 player-time 대 spectrum-frame 차이는 약1.135프레임 미만이었다. 합성 출력 PTS와 covered spectrum-frame 차이는 진단 표본에서1프레임 이내다(서로 다른 출력 소비자의 host-time/item-time 샘플 차이). 물리적 A/V 지연 측정이 아니다.
- 원본 독립 디코드와 출력 중앙 픽셀을 각8개, 총40개 지점에서 비교했다. 영상은 원본 CGImage의 색 공간으로 raw 값 비교, 이미지 허용 오차는 채널당6 이내다. 화면 전체 픽셀·색 정확도·물리 scan-out 검증으로 확대하지 않는다. 자막 presentation의 기대 항목은1800/1800 일치했다.
- 이미지 공백 경계120에서 검정, 복귀240에서 빨간 B 또는 영상 원본 픽셀을 확인했다. 이미지/영상 covered 구간은 확인된 출력 timing을 유지한다. 별도 output 추가 후 기존 subtitle rebinding 메서드를 사용했으며 renderer 변경은 없다.
- pause/seek/resume/end/replay와 선택 해제를 검사했다. 오디오 split/trim/move는 이미지 공백 fixture에서 기존 편집 규칙을 그대로 실행해 왼쪽 `frame+10`, 오른쪽 `frame+30`, 계보 공백을 확인했다. 이미지가 리플 지점을 가로지르는 최초 tail fixture의 거부는 정상 보호 규칙이며 실패 로그를 보존했다.
- live-access16개는 unknown/pending 차단,100회 조회의 단일 작업, 정상 lease, 일반 seek, 원본 이동 후 만료·재생 레이어 비움, 복구 후 새 검증, POSIX 읽기 권한 제거/복구, 이미지 lease가 유효한 동안 WAV 경로 소실 후6개 연속 프레임의 빈 레이어, 재연결·가용성 변경·item/project 교체 뒤 지연 성공 차단을 포함한다. OS 전체 권한 설정을 변경하지 않았다.

### 빈 표본과 증거 경계

SP-3C2-29 감사 정정: 기존의 “빈17표본”은 정확히는 **band/layer 비교 미확인17표본**이다. `bands`/`layer`는 실제 값이나 존재 여부가 아니라 비교 성공 boolean이다. 아래 감사 표가 이전 잠정 원인 분류를 대체한다. 원본 로그는 변경하지 않았다.

## 호환 회귀와 실행 분류

같은 제품 로직의 보존 signed `Regression.app`에서 controller92/92, paused overlay58/58, 설치 계약32/32 및 runtime gate-off3/3, 오디오 전용37/37, lead-in37/37, 영상 공백46/46, 오디오 꼬리23/23을 이번에 실행했다. 최종 앱에 추가한 것은 Debug 관찰 상태뿐이다. 설치 계약 검사는 실패한 image-plan·두 번째 읽기 실패도 포함한다.

변경하지 않은 엔진의 보존 바이너리로 이번에 실행한 집중 Debug/Release는 각각 SpectrumModel12 + FrameCoordinator13 + Scheduler14 =39/39다. Model 검사에는 목적지를 건드리기 전 spectrum export 거부가 포함된다. 새 live-access 앱 경로의 전체 Release 빌드는 하지 않았으며 broad Release/prototype/WMO는 실행하지 않았다. 이미지 엔진 ProductImagePreview 집중 Debug도2/2, 종료0이다. 빌드·실행/판정 코드는 무시된 증거 폴더의 각 codes JSON에 보존한다.

최초 fixture 형식 오류, 새 URL scope를 반드시 요구해 상대 경로를 거부했던 중간 구현, 고정300ms 재개 검사, 선택 상태 누락, 정상 리플 거부, 픽셀 참조의 상하 원점/색 공간 오류, controller가 보관하지 않는 실패 outcome을 기다렸던 검사 오류를 보존했다. 마지막 오류는 특정 enum 결과를 강요하지 않고 실제 재생 중 연속 빈 레이어를 확인하도록 고쳤다. 중간 실패를 성공 실행으로 집계하지 않는다.

## 파일·자원·남은 범위

제품 변경은 ProjectStore와 PlaybackSpectrumController다. OnTheFrameApp은 Debug 진입점, ImageSpectrumSelfTest는 새 생성 fixture 진단, PreviewSelfTest는 기존 오디오 편집 검사 재사용을 위한 접근 범위 변경뿐이다. ROADMAP/HANDOFF와 이 문서에 상태를 기록한다. 생성 프로젝트·미디어·로그·앱·APFS 이미지는 게시 대상이 아니다.

내부 APFS의1,500 MiB 상한 새 볼륨에서 single-job Debug 빌드만 수행했다. 이전 앱/증거와 baseline/회귀용 clone을 보존했다. `du -skx` 최종 측정은 app 9,880,792 + experiments 1,683,992 + 전용 개발 출력 7,854,412 = 19,419,196 KiB, 약18.52/20 GiB(시작17.62에서 약0.90 GiB 증가, 여유1.48 GiB)다. 중첩 APFS mount를 중복 계산하지 않았다. 최종 지문은 `app/selftest-work/sp3c228/final-fingerprints.json`에 보존한다. 정리·staging·commit·push, 공개 이미지 활성화, spectrum MP4 export 구현, schema/소유자 미디어·프로젝트·출력 변경 없음.

1초는 내부 보수적 lease 값이며 제품 SLA가 아니다. 대형 이미지/많은 catalog의 검사가1초를 넘으면 안전하게 계속 비울 수 있으며 그 성능 범위는 미검증이다. Stage 3C-2 전체 수락, 새 경로의 Release 앱 실행, 장기 재검증 비용·프레임 누락률·물리적 A/V 지연, 실제 OS 권한 철회/외장 볼륨의 장기 관찰과 소유자 육안·청취 수락은 남는다. 다음 권장 작업은 이 통합 체크포인트의 소스·증거 감사다.


## SP-3C2-29 체크포인트 감사 (2026-11-06)

**PUBLICATION READY — 내부 체크포인트 한정. OWNER MANUAL DEFERRED — NOT PASS.** 게시 기준은 `6c358e650f528b9264186c769875cce2da4b4951`이며 소스/검사5개와 문서3개 전체를 검토했다. 이 감사에서는 문서3개만 수정했다. 중대한 소유권·원본 보호·시각 권한 결함은 발견하지 않았다. 아래 미확정 표시 원인은 UX 검증 과제로 남으며 모든 refresh의 연속 표시나 무결한 Preview를 승인하지 않는다.

### 소유권과 시각 권한

설치 증거의 정확한 player item/composition/project session/generation/access revision과 live-access cancellation serial을 완료 뒤 다시 검사한다. relink 시작, 가용성/접근 변경, 계획·item·project 교체는 기존 증거/진행 결과를 무효화한다. 취소된 worker 슬롯을 실제 종료까지 유지하여 늦은 결과와 중복 작업을 차단한다. scope를 새로 얻지 못했다는 이유만으로 상대 URL을 거부하지 않지만 기존 validator의 descriptor identity와 실제 읽기는 필수다. 획득한 scope는 종료한다.

covered 이미지/영상의 권한은 확인된 compositor PTS다. item time은 유효 시각·재생 상태·동일 applied generation·seek 없음·시각 클립 없음·활성 선택 오디오 계보와 spectrum 조건을 모두 만족하는 실제 공백/꼬리에서만 허용된다. 오디오 원본의 기존 identity/read 및 source-frame 매핑 검사는 유지하며 다른 오디오로 대체하지 않는다. pending8/retained8/16MiB/lookahead2 제한, schema, 공개 이미지 gate, export 거부는 변경하지 않았다.

### 1초 정책의 정확한 의미

1초는 MainActor 조회에서 검증을 시작하기 직전에 얻은 monotonic 시각부터의 **hard evidence TTL**이며 작업 timeout이 아니다. worker 완료 시각부터 새 1초를 주지 않는다. 전체 이미지 catalog 검사가1초 이상이면 성공 결과도 이미 만료되어 정상 파일인데도 계속 표시를 차단할 수 있다. pending/unknown/expired/failed는 fail closed다. store별 단일 worker이며 취소는 협조적이다. OS I/O가 끝나지 않으면 슬롯도 반환되지 않아 starvation이 길어질 수 있다.

알려진 변경은 즉시 무효화하지만 외부 접근 철회는 알림 없이 즉시 감지하지 않는다. 기존 lease 만료와 이후 실행되는 검사가 필요하며 UI scheduling 정지까지 포함한 절대1초 감지 보장은 없다. display callback에 새 동기 파일 I/O는 없고 검사는 detached worker에서 수행한다. 그러나 MainActor의 catalog/clip 탐색, scheduling, background CPU 경쟁까지 없어진 것은 아니며 stall-free 성능은 미입증이다.

제품 정책 선택지는 현재 보수적 TTL/갱신 공백 유지, 작업 deadline과 freshness budget 분리 및 catalog 비용에 맞는 budget, revision/event 기반 전체 검증과 가벼운 현재 읽기 검사 분리다. 아직 유효한 lease를 유지하며 미리 갱신하는 선택은 현재 pending-fail-closed 계약을 바꾸므로 별도 결정이 필요하다. 이번에는 어느 정책도 변경하지 않았다.

### 17개 비교 미확인 표본

각 행의 재현 증거는 `app/selftest-work/sp3c228/observed/<scenario>/image-spectrum.json`의 해당 playerSeconds/frame이다. 기존 생성 fixture와 `-OTFImageSpectrumTest` 진입점은 재실행 가능하지만 아래 시간은 과거 실행 관측값이며 동일한 race 재현 보장은 없다. 모든 행의 전후 item/composition/session/generation은 일치했다. 다음 일치는 다음 관측 표본이지 실제 빈 화면 지속시간 또는 scan-out 측정이 아니다.

- **A (5개):** 초기 unknown, currentFrame=-1. 예상은 접근 증거 전 차단이고 관측도 일치한다. 안전상 정상 차단, 초기 지연 UX 위험.
- **L (3개):** 예상은 준비된 FFT와 대응 layer 일치. FFT 비교는 true, layer 비교는 false. layer 미할당/다른 contents를 구별할 수 없어 presentation pending 또는 stale layer 원인 확정 불가. 올바른 FFT는 확인됐으나 화면 안전성을 이 표본만으로 확정하지 못하며 UX 위험이다.
- **R (2개):** valid 접근/currentFrame 존재, 두 비교 false. 예상은 결과 준비 후 일치. outcome tag와 실제 bands를 기록하지 않아 analysis pending/실패/잘못된 bands를 구별할 수 없다. 잘못된 FFT의 적극적 증거도 없으며 안전성 미확정·UX 위험이다.
- **T (7개):** valid 접근/currentFrame=-1. 실행 가능한 현재 timing/player 상태일 때만 표시해야 한다. lease 완료 후 다음 tick 대기 또는 timing/player guard 가능성이 있으나 원인 미확정이다. 별도 진단 outputPTS는 controller가 수락한 PTS가 아니므로 compositor 결함/접근 pending으로 단정하지 않는다. 차단은 보수적이나 필요했던 차단인지 미입증이며 UX 위험이다.

| Scenario | Player seconds | Frame | 분류 | Spectrum frame | 다음 일치 seconds |
|---|---:|---:|---|---:|---:|
| gap-image | 0.000000000 | 0 | A | -1 | 0.044706166 |
| gap-image | 4.003549125 | 120 | R | 120 | 4.036984791 |
| gap-image | 5.903642042 | 177 | L | 176 | 5.937143625 |
| gap-image | 6.903990541 | 207 | T | -1 | 6.936782832 |
| gap-video | 0.000000000 | 0 | A | -1 | 0.049403000 |
| gap-video | 4.003680833 | 120 | T | -1 | 4.036943541 |
| gap-video | 7.903388999 | 237 | L | 236 | 7.936527791 |
| gap-video | 8.904373750 | 267 | T | -1 | 8.936965415 |
| image-only | 0.000000000 | 0 | A | -1 | 0.041342333 |
| image-only | 9.903737708 | 297 | T | -1 | 9.936339958 |
| mixed | 0.000000000 | 0 | A | -1 | 0.050516125 |
| mixed | 8.904061625 | 267 | R | 267 | 8.937198708 |
| mixed | 9.904237043 | 297 | T | -1 | 9.937301876 |
| tail | 0.000000000 | 0 | A | -1 | 0.049566958 |
| tail | 6.903816541 | 207 | L | 207 | 6.936453749 |
| tail | 7.903699917 | 237 | T | -1 | 7.936534667 |
| tail | 8.003531542 | 240 | T | -1 | 8.036679167 |

선택 오디오의 정상 무음은 ready zero bands와 nil layer가 일치하면 true/true로 집계된다. 따라서17개를 FFT zero로 분류할 근거는 없다. 나머지1783개에도 정상 zero가 포함될 수 있다. 표본 수집은 성공 또는 frame%3==0일 때 기록하며 프레임당 한 번이므로 성공 쪽으로 편향된다. 구간별 suite 판정도120개 중 최소10개 일치를 요구하므로155/155가 모든 프레임의 정상 표시를 증명하지 않는다. 위17개는 각각 다음 관측 프레임에서 약32–51ms 뒤 일치했지만 그 사이의 layer 내용/원인은 보존 데이터로 복구할 수 없다. 이 미확정성을 감추지 않는 내부 게시에는 차단 결함으로 판단하지 않았으며 제품 UX 수락의 증거로 사용하지 않는다.

### 증거 출처·게시 범위

위 자동 검사 수치는 모두 **SP-3C2-28 과거 실행**이다. final signed observed 앱의155/155(접근16 포함), 픽셀40, 자막1800/1800, FFT/layer1783/1800과 동일 제품 코드의 별도 Regression.app 회귀, 기존 엔진 바이너리 실행을 구별한다. SP-3C2-29는 새 기능 테스트/빌드 없이 저장된 JSON 재집계, 지문·서명·Git·diff 검사만 수행했다. 새 실행으로 과거17개의 누락 필드를 복원할 수 없으므로 임의 재실행을 하지 않았다. 초기 fixture/검사 실패와 중간 구현 실패는 전부 보존했다.

게시 후보는 OnTheFrameApp.swift(진입점), PlaybackSpectrumController.swift(시각/접근 gate), PreviewSelfTest.swift(검사 재사용), ProjectStore.swift(live 접근), ImageSpectrumSelfTest.swift(생성 fixture 검사), ROADMAP.md, HANDOFF.md, 이 문서의8개뿐이다. 정확한 전체 SHA-256/mode 매니페스트는 감사 최종 보고와 무시된 `app/selftest-work/sp3c229/publication-manifest.json`에 보존한다. 자체 hash 순환을 피하기 위해 이 문서에 지문을 복제하지 않는다. 모두 일반 파일100644이며 소스5개는 SP-3C2-28 지문 그대로다. 기존 미추적4개와 복구 refs, 앱/프로젝트/미디어/원시 로그/APFS 이미지는 제외·보존한다. index는 비어 있고 staging/commit/push는 하지 않았다.

관리 산출물은 mount 중복을 제외한 `du -skx`로 약18.52/20GiB, 여유 약1.48GiB다. 정리/새 빌드 없음. Stage 3C-2 전체·소유자 육안/청취·대형 catalog·장기/물리 지연·실제 OS 철회 수락과 새 경로 Release 앱 검증은 남는다. Spectrum Stage4 MP4 export는 미구현이다. 다음 권장 작업은 **lease/tick/outcome/layer presence를 연결한 좁은 관찰로12개 비초기 표본의 원인과 표시 연속성을 검증**하는 것이다.
