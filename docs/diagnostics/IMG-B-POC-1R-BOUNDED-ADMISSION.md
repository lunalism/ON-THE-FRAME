# TASK ID: IMG-B-POC-1R

**SCHEDULER: PASS**

**GATE 1: PASS**

두 active slot과 pending FIFO를 분리해 원래 admission blocker를 해소했다. Scheduler11개 검사와 기존6-frame Gate1이 통과했다. 이는 이 fixture의 Gate1 한정 결과이며 Candidate B 제품 채택이나 전체 IMG-B-POC-1 완료가 아니다. **AVPlayer/export Gate2는 실행하지 않았다.**

## 1. 저장소·원래 원인

`feature/subtitles`, HEAD/로컬 upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main `44943eadabdf5a37d5242d614e7279813126dfde`. 기존 CLAUDE.md 보호 규칙과 uncommitted ROADMAP/HANDOFF·IMG 소스/문서·`.claude/`·`.DS_Store`·recovery refs를 유지했다. 적용 AGENTS.md 없음.

원래 `startRequest`는 callback 안에서 `inflight`를 올리고, 직렬 worker queue에서 기다리는 요청도 active와 같이 셌다. Slot은 `process`의 defer에서 성공/실패/취소 뒤 반환했다. 별도 pending이 없어서 두 슬롯이 찬 동안 들어온 정상 추가 요청을 바로 Code300 오류로 끝냈다. Callback에 blocking wait는 없었지만 burst를 수용할 경계도 없었다. 원래 worker는 직렬이므로 실제 렌더 병렬성2를 활용하는 구조도 아니었다.

이전 BLOCKED 로그는 메모리 초과를 측정한 것이 아니라 최소3요청 이상 burst를 드러낸 것이다. 이를 renderer 품질 실패로 재분류하지 않는다. 이전 `img-b-poc1-20261028-01`의 source/fixture/log/report를 덮어쓰지 않았다.

## 2. 변경 파일

변경은 `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/`에 제한했다.

- 새 `ImageAwareAdmission.swift`: 독립·테스트 가능한 bounded scheduler.
- 새 `ImageAwareAdmissionTests.swift`: opt-in scheduler 검사11개.
- 수정 `ImageAware420Compositor.swift`: 원래 즉시 거부 admission을 새 scheduler에 연결하고 terminal completion을 한 곳에서 처리.
- 수정 `ImageAware420GateTests.swift`: 기존 fixture를 byte-identical copy로 재사용하는 옵션, 관련 source digest 목록, admission limits 설명만 추가.
- **`ImageAwareReference.swift` 변경 없음.**

새 진단 문서는 이 파일이다. 원래3개 소스의 수정 전 사본은 새 run의 `original-source/`에 보존했다. `unchanged-render-contract.json`에서 renderer/plane helper 본문, reference 전체, `checkQuality` 측정/기준 본문이 byte-identical임을 확인했다. 색 변환/LUT·source-over·geometry·sampling·40dB/flat≤3를 수정하지 않았다.

## 3. Capacity와 ownership

- Active 최대2개. 실제 worker executor는 concurrent queue이며 active reservation보다 많은 work를 시작하지 않는다.
- Pending 최대4개, FIFO. Active가 끝나면 가장 오래 기다린 요청부터 승격한다.
- 근거: 이전 실제 burst는 최소3이므로 pending 최소1이 필요했다. 이번 고정6-frame workload의 한 번 burst 전체를2active+4pending으로 제한 내 수용하도록 정했다. 이전에6개 동시 burst를 측정했다고 주장하지 않는다.
- 실제 Gate1 high-water는 **active2/pending2**, overflow0이었다. 결정적6요청 burst 검사에서는2/4를 확인했다.
- Pending은 framework request와 closure만 보유하고, 원본 `sourceFrame` 조회·별도 output 할당은 active work 시작 뒤에 한다. Framework request 내부가 보유하는 자원까지 없다고 주장하지 않는다. 소유 request 총수는2+4로 제한된다.
- Pending은90초 deadline 뒤 명시적 실패로 종료한다. Timer는 request payload를 capture하지 않고 scheduler weak reference와 ID만 capture한다. 취소된 pending payload는 timer까지 기다리지 않고 해제됨을 weak-reference 검사로 확인했다.
- Overflow는 명시적인 failure completion이다. Silent drop, 무제한 backlog, source buffer의 전체 timeline 보유 없음.

## 4. 상태·race·completion

흐름은 `received → active` 또는 `received → pending → active`, 이후 `success/failure/cancelled`다. Pending에는 별도 cancelled/expired terminal, admission 초과에는 overflow failure가 있다.

짧은 NSLock 임계구역에서 admission·generation·pending/active·terminal claim을 바꾼다. Callback에서 semaphore 대기나 worker queue.sync를 사용하지 않는다. Work와 외부 completion은 state lock 밖에서 호출한다. 따라서 completion의 재진입(snapshot/cancel/new submit)도 state lock을 재획득할 수 있다.

`cancelAll`은 generation을 올리고 pending을 제거·취소한다. Active slot은 worker가 종료/취소를 acknowledge할 때까지 유지해 실제 작업 수 상한을 지킨다. Work가 success를 계산해도 terminal claim 전에 generation이 달라지면 cancelled로 끝낸다. Terminal claim이 cancellation보다 먼저 확정된 완료는 소급 취소하지 않는다. 이 linearization 규칙을 적용하며 cancellation을 false success로 바꾸지 않는다. Callback 자체는 잠금 밖에서 실행한다.

Active 성공·실패·취소가 slot을 반환하며, callback 전에 다음 pending을 active로 예약한다. Pending promotion은 FIFO이고 병렬 worker의 **완료 순서는 FIFO일 필요가 없다**. 중복 executor 호출/중복 expiry는 이미 끝난 ID를 다시 완료하지 않는다. 진단 trace도256개로 제한했다.

## 5. Scheduler 검사

`ImageAwareAdmissionTests` **11/11 PASS, 실패0**. Arbitrary sleep 대신 manual executor와 인과적 semaphore/group barrier를 사용했다. Semaphore 대기는 테스트 barrier에만 있고 AVFoundation callback 안에는 없다.

| 검사 | 실제 검증 |
|---|---|
| A | 단일 요청 success와 slot 반환 |
| B | 두 실제 worker가 동시에 진입한 뒤 barrier로 해제, active2 |
| C | 완료 전6요청 burst, active2/pending4, 모두 success |
| D | Active 완료 순서를 뒤집어도 pending2/3/4 FIFO 승격 |
| E | Active failure 뒤 pending 승격과 slot 반환 |
| F | Pending 취소·제거와 captured payload 즉시 해제; active는 ack 전 유지 |
| G | Active work 중 cancel 후 계산된 late success를 cancelled로 종료 |
| H | 실제 concurrent admission/cancel 경합, generation에 맞는 결과·각1회 완료 |
| I | 중복 executor 호출에도 exactly-once, completion 안 재진입 |
| J | 일곱 번째 요청 overflow를 명시적 failure로 완료 |
| K | Pending deadline transition과 중복 expiry, 나머지 요청 정상 완료 |

90초 실제 wall-clock을 기다린 검사는 아니다. K는 실제 timer가 호출하는 동일한 expiry transition을 명시적으로 실행했다. 모든 가능한 OS interleaving이나 생산 cancellation 전체를 검증한 것은 아니다.

## 6. Gate1 재실행

이전 generated `bottom.mov`, `top.mov`, `middle.png`를 새 `reader/`에 복사했다. 세 입력의 합성 SHA256은 전후 모두 `26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1`이다. 원본 fixture 재생성/재인코딩 없음.

원래 FHD30/6frame, bottom[0,6), PNG[1,5), top[2,4), top(+960,+540)1:1, encoded-sRGB source-over/선언된420 sampling 계약을 그대로 사용했다. PNG alpha128/255도 그대로다.

**Gate1 PASS**: output6개, 요청 PTS0…5/30 정확, bottom sourceID0…5와 visible top sourceID2/3 정확. 원본 movie time의 `20/600`, `40/600` 등은 각각1/30,2/30과 정확한 유리수로 같았다. 두 top frame의 source contribution을 포함해8개 source 관찰이 통과했다.

실제 scheduler terminal6개는 모두 success였고 종료 active0/pending0, overflow0이었다. Pending 승격 순서는 frame2→3→4→5였다. Renderer 완료 순서는0→2→1→3→5→4였지만 reader 출력은0→1→2→3→4→5로 올바른 PTS 순서였다. 이 차이를 stale frame으로 잘못 세지 않았다.

## 7. Geometry·층 순서·alpha

Frame2/3에서 top 영역의 luma를 독립적으로 읽은 원래 top source와 각각518,400pixel 비교해 **다른 pixel0**이었다. 번역된 frame ID도 각각2/3으로 맞았다. PNG가 top 위에 잘못 그려지면 지워지는 marker와 영역을 검사한 것이다. Source timestamp·PNG구간·reference 비교도 함께 통과했다.

대표 sRGB 관찰 RGB(실제/CG reference):

- frame1(100,200), alpha128: `[105,52,65] / [105,52,65]`.
- frame1(800,200), alpha255: `[42,180,80] / [40,180,80]`.
- frame2(1500,800), top이 PNG를 가림: `[211,146,103] / [211,146,103]`.
- frame2의 번역된 ID marker(1000,580): `[0,0,0] / [0,0,0]`.

전체 구간 bottom이 있으므로 empty/black-gap 새 사례는 없다. 임의 fractional transform이나 다른 geometry 일반화를 검증하지 않았다.

## 8. 품질 수치

기존 sampled420 reference와 CG reference를 따로 유지했다. 둘 다 각 frame에서 global≥40dB/flat≤3를 통과했다. 동일 색 공간에서 비교하며 source codec 손실은 원래 decoded source를 reference로 사용해 분리한다. 최종 H.264 export/압축 손실은 이번에 측정하지 않았다.

| frame | sampled420 PSNR | CG PSNR | flat max sampled/CG | global max sampled/CG |
|---|---:|---:|---:|---:|
| 0 | 52.7008 | RGB 차이0 | 1/0 | 30/0 |
| 1 | 42.1564 | 42.5689 | 2/2 | 78/77 |
| 2 | 41.1993 | 41.4229 | 2/2 | 102/102 |
| 3 | 40.7661 | 41.4919 | 2/2 | 100/100 |
| 4 | 41.3778 | 42.3676 | 2/2 | 78/78 |
| 5 | 64.6909 | RGB 차이0 | 0/0 | 35/0 |

JSON의999는 RGB 오차0 PSNR sentinel이지 실제999dB 측정값이 아니다. Global 통과가 edge의 무손실 동등을 뜻하지 않는다. 예를 들어 frame2의(1279,539)에서 실제 `[142,149,125]` 대 두 reference `[40,180,80]`, 최대102다. Frame3 같은 좌표도 최대100이다. Sampled reference 대비 오차3 초과 pixel 수는 frame0…5 순서로575/2664/4925/4869/2708/660이며 p99는1/2/2/2/2/0이다. Region·worst·points는 `reader/results.json`에 남겼다.

이 큰 국소 차이의 source-chroma reconstruction/output conversion/경계 sampling 기여는 이번에 원인 분리하지 않았다. Scheduler 복구 범위를 넘어 renderer나 reference를 튜닝하지 않았다. 미승인 sampling 제안이나 제품 품질 계약을 채택한 것도 아니다.

## 9. Native video-only component 비교

PNG inactive frame0/5 전체와, frame2/3에서 PNG를 가리는 top rectangle을 native compositor 결과와 비교했다.

| frame/영역 | PSNR | flat max | global max |
|---|---:|---:|---:|
| 0 full | 68.1823 | 0 | 13 |
| 2 top ROI | 42.5182 | 3 | 15 |
| 3 top ROI | 48.0718 | 1 | 16 |
| 5 full | 68.6486 | 0 | 19 |

선언한 screening은 통과하지만 bit-identical native parity가 아니다. Source ID marker 등 국소 차이도 보존했다. 실제 video-only 제품 route는 변경하지 않았다.

## 10. 실행·실패·자원

모든 실행은 기존 내부 APFS `IMG1A-build` scratch와 지정 DEVELOPER_DIR를 사용했다. 정확한 filter는 다음과 같다.

| log | filter/환경 | 결과·exit |
|---|---|---|
| scheduler-first.log | `ImageAwareAdmissionTests`, scheduler opt-in | 새 setup 시그니처 compiler error, 실행 전 실패·1 |
| scheduler-retry.log | 같은 filter/opt-in | setup을 async throws로 수정한 뒤11/11 PASS·0 |
| gate1-first.log | `--skip-build --filter ImageAware420GateTests/testInterleavedReaderGate`, 새 RUN/기존 FIXTURES | 1test PASS·0 |
| scheduler-opt-out.log | `--skip-build --filter ImageAwareAdmissionTests`, opt-in 제거 | 11개 모두SKIP/실패0·0 |

Command 본체는 `swift test --package-path app/Engine --scratch-path <기존 APFS scratch> --filter <위 filter>`다. Scheduler opt-in은 `OTF_IMG_B_POC1R_SCHEDULER_RUN`, Gate1은 `OTF_IMG_B_POC1_RUN`과 `OTF_IMG_B_POC1_FIXTURES`다. 모든 출력은 새 `app/selftest-work/img-b-poc1r-20261028-01`에 한정했다. Gate1 wrapper는120초 timeout을 설치했지만 발생하지 않았다.

Compiler 첫 오류는 `setUp()`의 nonthrowing override에 throws를 붙인 harness 선언 오류였다. 최초 log를 남기고 `async throws`로 고쳤다. Scheduler assertions·hang·host/app crash·sandbox 실패·tool timeout 없음. 첫 compile 실패와 opt-out SKIP을 품질 결과와 혼동하지 않는다.

Scheduler 실제 test 약0.016초, 수정 후 build표시2.21초/invocation3.89초. Gate1 test16.470초/wrapper약17.978초. Gate1 관찰 RSS 최대401,719,296bytes(약383.11MiB), invocation maximum RSS426,639,360bytes(약406.88MiB). Scheduler build+test invocation maximum RSS460,570,624bytes(약439.23MiB; compiler/child 범위 포함).

문서 작성 전 새 run 할당량720KiB(약0.70MiB), 저장소와 전용 developer root 합산 약7.80GiB였다.512MiB/1GiB/20GiB 및120초 gate 제한 초과 관찰 없음. Pending90초 timeout은 실제 Gate1에서 발생하지 않았다. Renderer의 PNG frame 작업은 약1.64…2.50초였으므로 이 측정으로 실시간30fps를 주장하지 않는다.

## 11. 남은 범위·다음 작업·최종 Git

원래 admission blocker는 이6-frame gate에서 해결됐다. Scheduler PASS와 Gate1 PASS만 보고한다. 소유자 UI, AVPlayer,0.2초 export, 자막 export, image-only 시계, 다양한 입력/변형/긴 타임라인은 미검증이다. **Gate2 실행0/MP4 export0**을 유지했다.

다음 권고는 별도 승인된 동일6-frame Gate2다. 새 source/fixture digest와 frame plan을 고정하고 AVPlayer6시각/stale 거부 및 최대0.2초 export1개를 검증한다. 이번에는 시작하지 않았다. 위 국소 경계 오차와 native 차이를 숨기거나 제품 Candidate B ACCEPT로 바꾸지 않는다.

생산 소스·제품 image support·프로젝트 형식·Stage3C-2·spectrum export 변경 없음. Owner media/project/output 변경 없음. 이전 보호631개 파일/증거와 refs를 종료에 비교한다. 이전 B 소스 원본도 별도 snapshot으로 보존했다. ROADMAP/HANDOFF·기존 IMG1A/C/B 보고서·최초 실패·`.claude/`·`.DS_Store` 보존. Staging/commit/push 및 reset/clean/fetch/pull/merge/rebase/branch 전환 없음. 여기서 중단한다.
