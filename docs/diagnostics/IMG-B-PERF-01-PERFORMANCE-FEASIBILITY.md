TASK ID: IMG-B-PERF-01
STATUS: INCONCLUSIVE

> IMG-CP-02 게시 준비: `$REPO`는 저장소 루트, `$SELFTEST_ROOT`는 `$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 실험의 전용 내부 APFS SwiftPM scratch 디렉터리다. 아래 `$VAR`는 실제 실행 전에 해당 경로로 설정한다. 개인 절대경로만 비식별화했으며 원래 명령·실패 재현에서의 경로 역할과 하위 상대경로는 유지했다. 원본 로그는 변경하지 않았다.


기존 CPU prototype의 이미지 frame 지연은30fps 간격을 크게 넘는다. 다만 요구한 단계별 CPU/queue 비용이 기존 증거에 없고,이를 분리하려면 금지된 기존 구현 내부 계측이 필요하다. 따라서 FEASIBLE이나 PERFORMANCE BLOCKED를 확정할 근거가 부족하다. **요청 §8의 중단 조건에 따라 새 media 성능 실행·최적화를 하지 않고**,보존된 실제 timing의 읽기 전용 audit과 미적용 계측 patch만 제공한다. 제품 채택은 승인하지 않는다.

1. 실제 저장소와 Git

`$REPO`,branch `feature/subtitles`. HEAD/upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`,main `44943eadabdf5a37d5242d614e7279813126dfde`. CLAUDE.md와 기존 POC-1R/POC-2/QA-02 증거 및 관련 compositor/reference/scheduler를 확인했다. 적용 AGENTS.md는 발견하지 못했다. HANDOFF/ROADMAP 수정,untracked IMG 소스·보고서·.claude/.DS_Store 및 recovery refs를 보존했다. reset/clean/fetch/pull/merge/rebase/switch 없음.

2. 정확한 새 파일

- `app/scripts/PerformanceEvidenceAudit.py`: 기존 JSON/log만 읽는 표준 라이브러리 기반 분석기.
- `docs/diagnostics/PERF01-Instrumentation-Proposal.patch`: **미적용·미컴파일** unified diff. 기존 renderer/scheduler 파일을 실제로 수정하지 않았다.
- `docs/diagnostics/IMG-B-PERF-01-PERFORMANCE-FEASIBILITY.md`: 이 보고서.

새 증거 root는 `app/selftest-work/img-b-perf01-20261028-01/`다. preflight.json,retained-timing-audit.json,retained-timing-audit-confirmed.json,audit-first.log,audit-accounting-retry.log,preservation-check.json에 원본 hash·통계·실패·보존 검사를 기록했다. 기존 파일 수정0,기존 Swift 코드 변경0이다.

3. Hardware/software 조건

현재 읽기 확인 환경: Apple M4 Pro,Mac16,8,12 logical CPU,24GiB memory,arm64,macOS26.6.2/build25G83,Apple Swift6.4(swiftlang-6.4.0.34.1),Xcode의 지정 DEVELOPER_DIR. Hardware 조회는 개인 기기 serial/UUID를 수집하지 않았다. 기존 내부 APFS scratch는 `~/Library/Developer/ON-THE-FRAME/IMG1A-build`이며 debug 산출물이 남아 있다. 이번에는 Swift build를 하지 않았다.

과거 timing은 기존 SwiftPM test 명령의 개발용 실행이며 release/배포 최적화 성능 자료가 아니다. 현재 hardware 정보만으로 과거 실행의 thermal 상태·background load·clock·동일 compiler 산출물까지 재구성하지 않는다. 이번 audit와 과거 media 측정을 구분한다. 다른 Mac/4K/장시간으로 외삽하지 않는다.

4. 계측 경계와 정확한 blocker

기존 `process`는 admission worker가 실행된 후 `Date()`를 저장하고,sourceFrame lookup·타임스탬프/ID/format 검증·context.newPixelBuffer·private render·output tag·취소 검사를 마친 뒤 seconds를 기록한다. Pending wait와 framework의 source predecode,PNG decode/LUT setup,reference/quality/PNG/JSON 비용은 이 seconds 밖이다. Worker가 deschedule된 시간은 포함하며 CPU time이 아니다. 기존 `Date()`는 monotonic clock도 아니다.

`render` 내부는2×2 block마다 source NV12 읽기,709 matrix,LUT→sRGB,alpha source-over,LUT→709,luma·chroma와420v writes를 한 private loop에서 수행한다. R/G/B 각 expression도 forward conversion/blend/inverse conversion을 함께 포함한다. 외부 harness는 이 private 경계 안에 timer를 넣을 수 없고,scheduler events에는 timestamp가 없다. Thread CPU snapshot도 없다. 함수 밖 timer나 전체 test duration을 빼서 C/D/E 비용을 만들 수 없다. Source accessor 호출 시간과 AVFoundation predecode도 같지 않다.

요청 §8: “If instrumentation cannot be isolated without altering those implementations, stop and provide the smallest proposed instrumentation patch for separate review.” 이 조건을 적용했다. Shadow renderer를 복제하거나 픽셀 처리를 줄여 성능값을 만들지 않았고,샘플 profiler/새 engine으로 엄격한 단계별 비용을 얻었다고 주장하지 않는다.

5. Setup 대 per-frame 비용

| 구간 | 보존 증거 | 현재 결론 |
|---|---|---|
| A source acquisition | process 안에 포함; framework predecode는 밖 | 단독 wall/CPU 분리 불가 |
| B PNG decode/cache 준비 | loadPNG→premultiplied RGBA/IBImage,plan마다 IBTransfer LUT 생성 | setup 경로 확인,소요 시간 없음 |
| C pixel conversion | fused loop 안의 matrix와6개 LUT lookup/pixel | 독립 비용 없음 |
| D alpha source-over | 같은 LUT expression 안 | 독립 비용 없음 |
| E chroma/420v 출력 | source nearest/output Left vertical mean; 같은 loop | 독립 비용 없음 |
| F allocation/copy | context allocation과copy fast branch 포함 | 각각 분리 불가 |
| G scheduling/wait | active/pending count와순서 | wait timestamp 없음 |
| H reference/진단 | process 밖,전체 test 안 | 단독 wall/CPU 분리 불가 |

PNG decode와4097-point ICC LUT는 이미 per-frame inner loop 밖이다. 따라서 전체 지연을 매 frame PNG decode라고 설명할 수 없다. Transformed static data caching 가능성은 별도 분석이지 실제 시간이 측정된 병목 확정이 아니다.

6. Wall/CPU breakdown — 과거 실행과 새 audit 구분

| 기존 invocation | 전체 wall s | user CPU s | system CPU s | maximum RSS bytes |
|---|---:|---:|---:|---:|
| Gate1 | 18.00 | 23.77 | 0.71 | 426,639,360 |
| Gate2 | 48.65 | 50.93 | 1.02 | 488,980,480 |

이 CPU는 당시 invocation 전체의 accounting으로 compositor/worker별 CPU가 아니다. Media decode,reference,diagnostics/framework 작업이 섞여 있다. User+sys가wall보다 클 수 있는 병렬 실행을 순수 single-frame 계산으로 바꾸지 않는다. Process per-frame CPU 비율·core 사용률·stage 비용은 NOT MEASURED다.

새 읽기 전용 audit는0.05s wall/0.04s user/0.01s sys,maximum RSS21,184,512bytes였다. 이는 Python 분석 비용이며 renderer 성능값이 아니다.

7. Decode·blend·conversion·write 비용

세 경로의 이미지 활성 frame1…4와 no-image frame0/5에서 기존 process wall time 차이는 크다. 이는 image-active branch가 비용 조사 우선순위라는 근거다. 그 차이 전체를 blend만의 비용으로 부르지는 않는다. 서로 다른 source count/visible top coverage/병렬 contention/플랫폼 준비가 섞인다. PNG가 없는 frame0/5도 validation/context allocation/YUV copy/tag를 실제 수행한 결과다.

Top-active frame2/3에서는 output의 우하단 quarter를 top YUV copy branch로 처리한다. 나머지3/4는 이미지 합성하며,단순한 image-over-video frame1/4와 동일 pixel workload가 아니다. 반복되는 static PNG라도 video background가 변하는 translucent pixel의 최종 합성을 통째로 cache할 수는 없다. Native video-only compositor의 latency는 이 자료에 없다.

8. Queue/scheduling

과거 각 범위의 snapshot high-water는 active2/pending2,capacity active2/pending4,overflow0이었다. Event 순서·promotion은 있으나 timestamp가 없어 pending residence/worker dispatch latency/wait P95를 계산할 수 없다. process seconds를 queue wait로 세지 않는다. Raw trace의 local request IDs를 여러 compositor instance 전체 ID로 합치지 않았다.

Player→detach→export의 requests 배열은 cumulative다. Audit는 export array 앞부분이 after-detach array와 정확히 같은지 확인한 후 suffix의6개 rendered event만 export 표본으로 셌다. Reader의 반복 snapshot은 마지막 gate1-decision의6개만 사용했다. 반복된 snapshot을 표본 수나 throughput으로 부풀리지 않았다.

9. Reference·diagnostic·encoder overhead

QA-02의 canonical conversion·독립 reference·PSNR·PNG snapshot은 화질 검사 경로다. 이 비용을 compositor preview 비용에 넣지 않는다. 과거 전체 test16.470s/47.026s를 frame rendering 시간으로 나누지 않는다. 이번에는 QA-02 화질을 다시 계산하지 않았다.

과거 export session 전체3.474269s/6frames(0.2s timeline)는 encode 전용 비용이 아니다. Decode/render/scheduler/encoder/mux/finalization이 겹치므로3.474269에서 render durations의 합을 빼면 encoder 비용이 되지 않는다. 단순6/session은 약1.73frames/s의 해당 짧은 session 완료율일 뿐 지속 export throughput이 아니다. 새 export0,AVPlayer0이다.

10. Median/P95/max/n — 새 측정이 아닌 보존 timing 재집계

| 기존 범위 | workload | n | median ms | min ms | max ms | P95 |
|---|---|---:|---:|---:|---:|---|
| historicalGate1 | imageActive | 4 | 1865.104 | 1641.202 | 2502.507 | 산출 보류 |
| historicalGate1 | imageOverVideoNoTop | 2 | 2071.855 | 1641.202 | 2502.507 | 산출 보류 |
| historicalGate1 | imageAndTopVideo | 2 | 1865.104 | 1834.364 | 1895.845 | 산출 보류 |
| historicalGate1 | customNoActiveImage | 2 | 21.147 | 20.984 | 21.310 | 산출 보류 |
| historicalPlayer | imageActive | 4 | 730.073 | 631.947 | 831.452 | 산출 보류 |
| historicalPlayer | imageOverVideoNoTop | 2 | 826.802 | 822.152 | 831.452 | 산출 보류 |
| historicalPlayer | imageAndTopVideo | 2 | 634.971 | 631.947 | 637.994 | 산출 보류 |
| historicalPlayer | customNoActiveImage | 2 | 16.967 | 16.688 | 17.245 | 산출 보류 |
| historicalExport | imageActive | 4 | 1462.379 | 1445.242 | 1899.956 | 산출 보류 |
| historicalExport | imageOverVideoNoTop | 2 | 1682.437 | 1464.917 | 1899.956 | 산출 보류 |
| historicalExport | imageAndTopVideo | 2 | 1452.541 | 1445.242 | 1459.841 | 산출 보류 |
| historicalExport | customNoActiveImage | 2 | 23.309 | 22.902 | 23.716 | 산출 보류 |

각 group n2/4라 P95는 보고하지 않았다(audit 기준 n≥20일 때만 nearest-rank 표시). 이것은 새 품질/성능 acceptance threshold가 아니라 작은 표본의 tail 해석을 피하기 위한 보고 규칙이다. 서로 다른 세 실행을 pool해서 표본 수를 늘리지 않는다. Player의 낮은 값과Reader의 높은 값 사이 차이를 warm-cache 효과나 개선으로 원인 확정하지 않는다. Native video-only와 별도image-only timeline은 미측정이다.

11. 메모리·resource·실행 결과

과거 test sampled RSS 최대: Gate1 401,719,296bytes,Gate2 479,854,592bytes. 위 invocation maxima와구별한다. QA-02는 retained read-only 재측정의 sampled496,205,824bytes로 renderer 자원값이 아니다. Live allocation 횟수/worker당 peak/Metal memory는 측정되지 않았다. Current audit RSS 약20.20MiB로1GiB 이내다. 새 artifact/combined 할당량은 preservation-check.json에 기록하며512MiB/20GiB 한도 이내다. 새로운 media memory trace·Swift build·test가 없으므로 그런 peak를 만들지 않는다.

실행 명령은 `python3 app/scripts/PerformanceEvidenceAudit.py --repository <repo> --output <새 selftest-work JSON>`이며 `/usr/bin/time -l`로 감쌌다.

- audit-first.log: 분석/JSON 생성은 완료했으나 time wrapper의 `sysctl kern.clockrate: Operation not permitted`로 최종exit1. Sandbox/accounting 오류이며Python 분석 실패·test assertion·process crash가 아니다. 첫 JSON/log 보존.
- audit-accounting-retry.log: 동일 read-only 분석을 새 confirmed JSON으로 실행,accounting 접근 승인 후exit0. 두 JSON의 분석 내용은 일치한다.
- Hardware sysctl도 최초 sandbox 조회가 거부되어 read-only 권한으로 다시 확인했다.
- Swift tests0,SKIP0,compile0,media run0. SKIP을 성능PASS로 사용하지 않았다. Crash/SIGABRT/tool timeout 관찰 없음.

12. 30fps deadline 판단

30fps의 nominal interval은33.333ms다. 보존된 image-active process wall은 최소631.947ms(Player)부터최대2502.507ms(Reader)로,측정 당시 frame latency는 약19…75배 interval을 넘는다. 현재 개발용 CPU prototype이 이 자료에서 realtime을 달성했다고 할 수 없다. 두 active slot이 있어도 무조건 지연을 절반으로 줄이지 못하고,historical latency로 지속 throughput이나deadline miss율을 새로 만들어내지 않는다. Native no-image timing16.688…23.716ms만으로 image project30fps를 주장하지 않는다.

Worker wall latency,지속 throughput,파이프라인 병렬성,실제 playback deadlines,export 완료율은 별개다. Release 최적화 build·thermal-stable 반복·stage thread CPU·queue-time 자료가 없어 기존 CPU 접근의 near-term30fps feasibility를 확정하지 않는다. 4K/장시간/수시간 export 성능 외삽 없음.

13. 근거가 있는 분석 후보 — 구현·속도 예측 없음

| 후보 | 현재 근거/조사 대상 | 색·품질/preview-export 위험 | 자원·취소/필요 검증 |
|---|---|---|---|
| static-image 데이터 전처리 | PNG decoded RGBA와LUT는 이미 setup cache;inner loop는매 pixel byte/alpha 읽기·변환 | alpha128/255,premultiplied encoded-sRGB 의미 유지;translucent 최종색은video 의존 | 추가cache 상한·project-switch lifetime;setup/frame 비용 분리 전 우선 채택 안함 |
| vImage/Accelerate 또는벡터화 | image branch의scalar matrix/LUT/blend/write 합계가 길다는 증거 | nonlinearICC LUT 순서,nearest source와Left downsample,round/clamp를검증;linear-light blend로 바꾸면안됨 | temporary buffers·취소granularity;stage profiling과raw420/QA02 회귀 후 판단 |
| bounded Metal 연산 | 반복적인 per-pixel CPU 경로라는 source 근거뿐,GPU speedup 측정없음 | 실제ICC709↔sRGB,alpha,Left phase/quantization,preview/export 동일 kernel 필요 | IOSurface buffer ownership,fence/pool/generation/cancel;작은실험 별도 승인 필요 |
| output buffer reuse | context.newPixelBuffer가현재포함됨;allocation 단독비용미측정 | pooled buffer의stale attachment/pixels·품질 위험 | AVFoundation buffer lifetime/deadline·boundedpool 검증;즉시병목이라고 주장 안함 |
| decode caching | source predecode/lookup이계측되지 않음 | frame-exact seek/source time·stale 방지 | 보안scope·media 변경·project switch·메모리상한;원인측정 전 권고우선순위 아님 |
| redundant conversion 감소 | 코드상709→sRGB→709가필요pixel마다반복됨 | static opaque shortcut/alpha 단순화가색·경계·parity를변경할수있음 | opacity/coverage와cancellation 검증;계측으로기여 확인 전최적화 금지 |

어떤 항목에도 예상 배수나“충분히 빨라진다”는 값을 부여하지 않았다. 지금 전체 renderer rewrite나새 architecture 채택을 권고하지 않는다. Candidate B 비용의어느 stage가 지배하는지 확인하는 것이선행 조건이다.

14. 제품 호환성과 색/parity 위험

기존 video-only native path와 native parity 관찰은 유지한다. Mixed image/video 가속 때문에 video-only routing을 강제로 바꾸면 안 된다. Subtitle-bearing export는 계층 순서와 색 일관성 검증이 별도로 필요하며 이번에 실행하지 않았다. Future spectrum output은 검증된 기능으로 간주하지 않고 Stage3C-2와 spectrum export는 범위 밖이다.

Frame-exact seek/project switch는 요청 generation,source ID/PTS와 stale buffer 방지를 유지해야 한다. Cache/GPU buffer 재사용으로 취소된 요청이 다른 project에 노출되면 안 된다. Non-destructive handling과 security-scoped source lifetime은 decode/GPU가 source를 사용하는 기간까지 유지해야 한다. Export cancellation/failure 보호는 terminal exactly-once,bounded active/pending,미완성 output 보호를 유지해야 한다. 모두 향후 검증 항목이며 현재 제품 통합의 실증 결과가 아니다.

QA-02 canonical 진단은 그대로다. Renderer를 바꾸면 canonical 점수만으로 품질 승인을 대신하지 않고 raw planes,edge,direct CG,native,preview/export를 나누어 검증해야 한다. 이번에는 변환/LUT/alpha/sampling/geometry/threshold를 변경하지 않았다.

15. 남은 불확실성과 미적용 최소 patch

`PERF01-Instrumentation-Proposal.patch`는 검토용이다. 기존 process에 opt-in worker-thread CPU/monotonic spans를 추가하여 source lookup,validation/ID,context allocation,fused render를 구분하고 scheduler event에 monotonic timestamp를 추가하는 최소 첫 계측안이다. 새 IBPerfProbe.swift도 diff 안의 제안일 뿐 실제 Swift 파일로 만들지 않았다. Pixel 표현식과 scheduler 결정 로직을 바꾸지 않고 per-pixel timer도 넣지 않는다.

**이 작은 patch만으로 C/D/E 각각이 분리되지는 않는다.** 다음 계측 범위 검토에서 sampled signpost/Time Profiler와 기여 추정의 한계,또는 최소 expression-boundary 분리의 품질·컴파일러 영향을 함께 결정해야 한다. 실행하지 않은 계측의 성능이나 overhead를 실증값으로 보고하지 않는다. Patch는 미적용·미컴파일이므로 정확성 검증도 미완료다. 향후 적용 시 clock overhead control,CPU 조회 실패 처리,동일6-frame raw-byte/QA02 회귀 및 resource 상한 점검이 필요하다.

기존 구현을 계측하지 않고 정확한 A-H 단계별 wall/thread CPU와 queue waiting을 얻었다고 주장할 수 없다. 다른 build 실행이나 복제 renderer의 측정도 이 blocker의 동등한 대체가 아니다. 현재 결론은 INCONCLUSIVE다.

16. Candidate B 권고

제품 채택은 계속 보류한다. 기존 Reader/scheduler/AVPlayer delivery와 QA02의 제한된 PASS,역사적 Gate2 QUALITY FAIL/native 관찰을 함께 보존한다. 개발용 image frame latency는30fps에 맞지 않는다. 이번 근거만으로 가속 가능성이나 아키텍처상 불가능을 확정하지 않는다. 최적화나 renderer rewrite를 시작하지 않는다.

17. ONE bounded 다음 결정

**미적용 계측 patch와 C/D/E fused-boundary 계측의 허용 범위를 별도 검토하는 결정1건**을 권고한다. 승인될 경우에만 동일6-frame fixture의 bounded wall/thread CPU/queue profiling과 instrumentation parity 검증을 설계한다. 이번에는 patch 적용,새 성능 test,새 export,AVPlayer,최적화를 실행하지 않는다.

18. 최종 Git·증거 보존

Preflight771개 기존 source/report/evidence의 해시를 종료에 모두 비교하고 refs와 staged diff를 확인한다. 정확한 최종 상태는 preservation-check.json에 있다. 기존 renderer/reference(현재 QA02 canonical 포함)/scheduler/Gate1/Gate2 logic은 변경하지 않았고 새 파일은2번의 진단 파일과 보고서뿐이다. HEAD/upstream/main과 기존 HANDOFF/ROADMAP 수정은 그대로다.

Frozen fixture digest `26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1`,보존 MP4 digest `c7781efd86c905b80ed60909bca4df0cae364c0eca85ff580b25a219e93acdf5`를 유지했다. 역사적 QUALITY FAIL(frame3 PSNR39.9763,frame4 flat4,boundary106,clone101),QA02 canonical PASS,PSNR≥40/flat≤3,native parity 관찰과 first-failure logs를 보존한다.

Renderer behavior/product source/project format/quality threshold 변경 없음. 새 media export·AVPlayer·owner media/project/output 수정 없음. Stage3C-2/image import/format9/spectrum export/new dependency/최적화 엔진 없음. Staging/commit/push/reset/cleanup 없음. 보고 후 중단한다.
