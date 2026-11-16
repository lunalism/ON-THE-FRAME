TASK ID: IMG-B-PERF-05
STATUS: DRIVER VALIDATED — DEADLINE FAIL

> IMG-CP-02 게시 준비: `$REPO`는 저장소 루트, `$SELFTEST_ROOT`는 `$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 실험의 전용 내부 APFS SwiftPM scratch 디렉터리다. 아래 `$VAR`는 실제 실행 전에 해당 경로로 설정한다. 개인 절대경로만 비식별화했으며 원래 명령·실패 재현에서의 경로 역할과 하위 상대경로는 유지했다. 원본 로그는 변경하지 않았다.


이번에는 driver timing을 독립 calibration하고 renderer 부하에서도 확인했다. Strict absolute producer의 부하 중 arrival lateness는 P95 0.101ms/max0.134ms로 사전 기준을 통과했다. 그러나 fixed intended deadline(A)과 actual-submission 기준 진단(B) 모두3/90 miss였다. 최대 lateness는A5.779ms/B5.706ms다. **Driver는 이90-position 시험에서 검증됐지만 전체 simulated deadline gate는 실패했다.**

PERF04의80/90 DEADLINE FAIL은 그대로 보존한다. 이번3회와 단순 차감해77회가 driver 때문이라고 결론내리지 않는다. 실제 AVPlayer/display PASS나 Candidate B 제품 채택 승인은 아니다.

1. 실제 Git 상태

저장소 `$REPO`,branch `feature/subtitles`. HEAD/upstream은 `8475ca7813ac7348ecd78990ee3ed9992fb69673`,main은 `44943eadabdf5a37d5242d614e7279813126dfde`다. CLAUDE.md,PERF04 driver/evidence,PERF03 Release,PERF02 instrumentation,scheduler/compositor,QA02 계약을 확인했다. 적용 AGENTS.md는 발견하지 못했다. 기존 HANDOFF/ROADMAP 수정,untracked 실험·.claude/.DS_Store 및 recovery refs를 보존했다. reset/clean/fetch/pull/merge/rebase/switch 없음.

2. 정확한 변경 파일

모두 `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/` 안이다.

- 수정 `SustainedThroughputDriver.swift`: 새 strict producer mode 연결과 render 시작/완료 timestamp metadata 추가. 기존 offline/legacy paced mode는 유지했다.
- 추가 `PacedArrivalPlan.swift`: bounded legacy/strict clock producer와 사전 arrival-fidelity 계산.
- 추가 `PacedDriverTimingTests.swift`: no-render90-position calibration.
- 추가 `PacedRendererAttributionTests.swift`: calibration을 선행 조건으로 하는 단 한 번의90-position recheck와 기존 quality 검증.

새 문서는 `docs/diagnostics/IMG-B-PERF-05-DRIVER-TIMING-ATTRIBUTION.md`다. 증거 root는 `app/selftest-work/img-b-perf05-20261029-01/`이며 calibration JSON/criteria,원본 및 실행 source snapshot,diffs,per-position timeline,attribution-summary.json,quality raw samples,logs,preservation-check.json을 보존했다. Renderer/admission/reference/제품 source와 기존 보고서는 수정하지 않았다.

3. 원래 driver의 timing 조사

기존 driver의 nominal targets는 이미 absolute `t0+n/30`이었다. Deadline 산식 오류나 relative-delay 누적을 발견한 것이 아니다. 문제는90개 `asyncAfter` 예약을 정확한 arrival 보장처럼 사용했지만 실제 delivery precision을 검증하지 않았다는 점이다.

Arrival와completion collector는 userInitiated serial control queue를 공유한다. Completion 처리에는 RSS 조회와bounded scheduler snapshot merge가 있어 arrival를 늦출 가능성은 있다. 다만 no-render receiver에서도 큰지연이 재현돼 collector/renderer가 그문제의 필요조건은 아니었다. 특정OS timer coalescing 내부원인을 확정하지 않는다.

Workers는 기존과 같은 concurrent dispatch executor이고 policy는IBAdmission의2active/4pending이다. Callback은 state lock 밖에서 실행되며 collector로 async enqueue한다. 새 wait나I/O를 callback 안에 넣지 않았다. Test thread의 bounded completion wait와 callback blocking을 구분한다. QoS/CPU affinity를 올려 결과를 만들지 않았고 frame 작업을 batch로 생략하지 않았다.

4. No-render calibration

동일90-position,nominal3초,50ms scheduling lead,같은 userInitiated arrival queue를 사용했다. Receiver는timestamp90개를append할 뿐이며 fixture/source decode/render/scheduler/image buffer를 실행하지 않았다. 두 calibration을 각각 한 번 수행했다.

기준은실행전에 predeclared-timing-contract.json 및각criteria-before-run.json에고정했다. Positive arrival lateness P95≤1ms,max≤2ms,early≤0.1ms,한interval(33.333ms)을놓친submission0,마지막jitter와first 대비drift 절댓값≤2ms다. 이것은driver suitability 기준이며presentation deadline slack은계속0이다.

| 시험 | median/P95/max arrival lateness ms | interval window misses | final jitter / drift ms | 적합 |
|---|---:|---:|---:|---|
| legacy no-render | 33.454938/113.067376/141.767959 | 47 | 8.459334/3.695209 | NO |
| strict no-render | 0.059021/0.095416/0.132042 | 0 | 0.064667/-0.028416 | YES |
| strict under renderer load | 0.069126/0.100542/0.134042 | 0 | 0.072542/-0.000375 | YES |

각90개가유일하게도착했다. 0보다늦은arrival는strict에서도90건이며,수십µs 늦은것을“정확히0 lateness”로보고하지않는다. Strict의early arrival는0,놓친submission window도0이다. Legacy는negligible receiver에서도사전기준을크게실패해renderer deadline verdict용으로부적합했다.

5. 격리된 최소 교정

새mode는 `DispatchSourceTimer(flags:.strict)` one-shot에0 requested leeway를주고다음target을매번원래 `t0+n/30` absolute 값으로재설정한다. Relative interval 누적이나busy-wait/catch-up spin을쓰지않는다. 최대90event이며미래timer1개만보유한다. Queue/QoS/deadline/source/worker/admission policy는바꾸지않았다.

Strict도SDK 문서상 best effort이지hard realtime 보장은아니다. 실제적합성은no-render와부하중90개submission에서확인했다. 기존asyncAfter code path를지우거나PERF04 결과를덮어쓰지않았다.

Rendering start/end를찍기위한clock read2개와result metadata만추가했다. 이를제거한driver.frame 본문이원래와같음을 processing-preservation-check.json으로확인했다. 실제compositor·pixel arithmetic·admission 구현은byte-identical이다.

측정후검토에서새timer callback의strong owner capture가 run→plan→callback→run cycle을만들수있어weak capture로해소했다. Test는wait/report/quality 끝까지run을강하게보유하므로90 callback의실행조건은같다. 실행시source는executed-driver-before-lifetime-review.swift로보존했고후검토내용/diff도별도기록했다. 최종compile/opt-out만확인했으며두번째renderer run은하지않았다. 이마지막수정의독립성능재측정을한것으로주장하지않는다.

6. Clock/deadline 정의

모든host timestamp는같은process의 `DispatchTime.uptimeNanoseconds`다. Worker CPU만기존Mach thread user+system time을별도로사용한다. Media PTS는n/30,source PTS는phase/30으로검사하며host clock과서로빼지않는다.

Position n=0…89에대해 intended arrival I=t0+n/30,actual submission S,admission A,active scheduler start W,pixel start R0,pixel completion R1,validated sample ready V,terminal callback T,collector publication P를기록했다. Intended presentation deadline D=t0+(n+1)/30은기존그대로다.

A판정은 P>D다. B진단은 P>S+(D−I)다. B는actual submission부터한interval을넘겼는지분해하는것이며A를대체하거나physical playback PASS로바꾸지않는다. No grace를추가하지않았다. Calibration under load를통과하지못했으면renderer verdict를중단하도록test guard를넣었다.

7. Intended 대 actual arrival

새compositor recheck90개는arrival median0.069126ms/P950.100542ms/max0.134042ms였다. 마지막jitter0.072542ms,first 대비drift−0.000375ms,한submission interval을놓친건수0이다. 사전1ms/2ms 기준을부하중에도통과했다. 원래PERF04 paced의median14.538ms/P9565.501ms/max69.982ms와구별한다. 이번strictno-render calibration을명목상30fps라는이유로검증됐다고가정한것이아니다.

8. Queue/processing/delivery 분포

모두n90,단위ms,nearest-rank ceil(.95*n) P95다. Trimming이나warm-up 제외없다.

| 구간 | median | P95 | max |
|---|---:|---:|---:|
| arrivalLateness | 0.069126 | 0.100542 | 0.134042 |
| admissionOverhead | 0.004667 | 0.007958 | 0.068125 |
| pending | 0.000000 | 0.000000 | 0.000000 |
| dispatch | 0.025979 | 0.039958 | 0.044709 |
| prePixelProcessing | 0.104104 | 0.147917 | 0.246791 |
| pixelProcessing | 28.649438 | 31.710750 | 37.343459 |
| pixelCPU | 28.650000 | 31.703000 | 37.345000 |
| postPixelValidation | 1.081229 | 1.259250 | 1.545166 |
| terminalDelivery | 0.026708 | 0.051875 | 0.066791 |
| collectorDelivery | 0.006229 | 0.012292 | 0.013917 |
| endToEnd | 29.965666 | 33.114708 | 39.039166 |
| intendedEndToEnd | 30.015208 | 33.160792 | 39.112083 |

Pending=0이고maxActive2/maxPending0,overflow0,최종active/pending0이다. 따라서이run의tail을pending queue 증가로설명할근거는없다. PrePixel은cached-source 조회/validation/allocation/test instruction을포함한다. PixelProcessing은원래fused render 함수호출전체이며C/D/E 내부비율은분리하지않았다. PixelCPU는기존동일span의worker CPU다.

PostPixelValidation에는active bytes copy/hash·tag·CMSampleBuffer wrapper/PTS 확인이포함된다. TerminalDelivery는ready→terminal callback,CollectorDelivery는callback→publication이다. 이후JSON/quality 비교는timed run 밖이다. Render 완료시각과검증완료·terminal/publication을동일시하지않았다.

9. Deadline misses/maximum lateness

IntendedA=3/90,max5.778750ms. Actual-submissionB도3/90,max5.705833ms다. Lateness P95는둘다0이지만3/90 tail miss가있으므로PASS가아니다. 평균FPS도마지막publication까지약30.080fps이나deadline fail을지우지않는다. Final output은nominal3초end보다7.951ms 앞서끝났고누적backlog는없었다.

| position / phase | arrival late ms | pixel ms | post-pixel validation ms | intended late ms | pixel end부터늦었나 |
|---|---:|---:|---:|---:|---|
| 0 / 1 | 0.072917 | 37.343459 | 1.284125 | 5.778750 | YES |
| 23 / 4 | 0.099584 | 32.208166 | 1.309834 | 0.468458 | NO |
| 60 / 1 | 0.041083 | 32.145500 | 1.205792 | 0.237709 | NO |

1건은pixel completion부터늦었고다른2건은검증/sample 후처리까지거친뒤deadline을넘었다. “Renderer만3건실패”라고하지않는다. 첫6개에서1miss,나머지84개에서도2miss였다. Warm-up을빼서성공시키지않았다. Diagnostic 비용을빼고A의physical PASS라고부르지도않는다.

10. Offline 비교/한계

새offline saturation run은실행하지않았다. 기존PERF04의90/90,66.726fps,2active/4pending 결과를그대로인용한다. 같은반복source/PNG지만offline은capacity가생길때마다일을주므로paced의deadline 지표와같지않다. 현재는90개를2.992049초에완료했고평균률보다개별3miss가판정상중요하다.

Driver는기존IBAdmission class의별도test instance와기존pixel function을쓴다. Actual AVVideoCompositing callback/context-pool/source-decode cadence가아니다. Stricttimer가그경로를검증한것처럼확대하지않는다.

11. Source/PTS/frame correctness

기존fixture 합성digest `26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1`,PERF02 Debug raw baseline을재사용했다. 실제AVFoundation으로setup에서bottom1…4/top2·3의6buffer를decode한뒤읽기전용으로반복사용했다. Phase=n%4+1,static PNG이며45image-no-top/45image-with-top이다. 90개모두독립render이고final output cache는없다.

90unique requested positions,90success terminal,exactn/30 sample PTS,phase별source IDs/movie time,hash90/90가맞았다. Missing/duplicate/stale logical result/cancelled=0이다. Outputn/30는driver sample wrapper의timestamp이며90개nativeAVFoundation compositionTime 검증이아니다. Completion 순서는parallel로다를수있으나logicalposition/phase/ID로결과를연결했다.

12. Quality 회귀

대표position0,1,2,3,4,88,89의raw를보존하고run 뒤기존QA02 canonical/reference로검사했다. Beginning/end/top overlap 경계와chroma-sensitive 기존points/edge mask를포함한다. Sampled420 PSNR최소46.883781dB/flat최대2,directCG 최소42.250538dB/flat최대1로기존40dB/≤3를통과했다. Top-active 대표의geometry도기존518,400luma pixel mismatch0검사를통과했다.

다른83position은source/PTS/hash를검증했지만개별pixel-quality score를냈다고하지않는다. Sampling/ICC/source-over/geometry/threshold는바꾸지않았다. 기존Gate2 QUALITY FAIL과QA02 별도reassessment PASS는유지했다.

13. Scheduler/cancellation

Admission 구현은수정하지않았다. Active2/pending4 한도를유지하며이번run은maxActive2,maxPending0,terminal90,최종0/0,overflow0이었다. 기존scheduler/cancellation11개도Release에서통과했다. Generation/FIFO/once-only 정책을바꾸거나새callback blocking을넣지않았다. 이번90개에는cancellation injection이없고취소0이모든실제AVFoundation cancel/project-switch race를증명하지않는다.

14. CPU/memory/resource

No-render processCPU는legacy0.004074s,strict0.007998s였다. Callback90회·3초부근의최소receiver이며image/video 작업은없다. Compositor run processCPU2.613751s,accounting wall3.042096s는50ms lead를포함한다. 실제t0→lastpublication은2.992049s다. Source setup/대표quality는별도이며worker CPU를wall wait와혼동하지않았다.

Timed RSS는85,688,320→106,774,528bytes,peak106,774,528bytes다. 대표7개raw를보존한성장과후처리memory를구분한다. Quality뒤sampledpeak485,851,136bytes,renderer invocation maximum494,239,744bytes로관찰된test-process는1GiB 이내다. Compiler를포함한build invocation은2GiB 이상이어서test-host 단독peak로사용하지않았다.

보고서작성전새artifacts 약23.2MB,build를포함한managed 순증가약23.9MB로512MiB 이내,repository+developer root는약8.15GiB로20GiB 이내였다. 최종할당량은preservation-check.json에있다. 큰build/media 실험을병렬실행하지않았다.

Hardware는Apple M4 Pro/Mac16,8/12logical CPU/24GiB RAM,macOS26.6.2/build25G83,Xcode27.1/Swift6.4의기존Release환경이다. `-O`/WMO,DEBUG=false,Release assert configuration,probe on을확인했다. CPU frequency/thermal/background load를고정하지않았다. 종료후pmset은thermal/performance warning과CPU power status가record되지않았다고보고했으나실행중thermal trace나throttling 부재의보장은아니다.

15. 명령/exit/failure/SKIP

공통: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/time -l swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path $BUILD_ROOT --filter <test>`.

| log | filter/조건 | exit/결과 |
|---|---|---|
| legacy-calibration-first.log | -v,PacedDriverTimingTests/testNoRender90;CLOCK=legacy-asyncAfter | 0,1test수집완료,driver fidelity FAIL 기록 |
| strict-calibration-first.log | --skip-build,같은filter;CLOCK=strict-absolute | 0,1test/driver fidelity PASS |
| corrected-release-build-first.log | -v,ReleaseBuildVerificationTests/testOptimizedConfigurationAndOptIn | 0,configuration1PASS |
| renderer-recheck-first.log | --skip-build,PacedRendererAttributionTests/testOneCalibratedPaced90 | 0,90correct/대표7qualityPASS,데이터상A/B3miss |
| scheduler.log | --skip-build,ImageAwareAdmissionTests | 0,11PASS |
| final-build-opt-out.log | -v,PacedDriverTimingTests 또는PacedRendererAttributionTests의regexunion,opt-in없음 | 0,finalcompile성공/2SKIP |

주요env는 `OTF_IMG_B_PERF05_CALIBRATION_RUN`,`OTF_IMG_B_PERF05_CLOCK`,`OTF_IMG_B_PERF05_RUN`,`OTF_IMG_B_PERF05_FIXTURES`,`OTF_IMG_B_PERF05_BASELINE`,`OTF_IMG_B_PERF05_CALIBRATION`이며probe는기존 `OTF_IMG_B_PERF02_PROBE=1`이다. 새고유root만썼고strictcalibration JSON의hash와적합성을renderer실행전에검증했다. Renderer recheck는정확히1회다. 마지막weak-capture 검토후media를재실행하지않았다.

XCTest exit0은수집/정확도 성공이지driver 또는deadline PASS가아니다. Legacy calibration의부적합과현재deadline fail을별도JSON/보고서로유지했다. SKIP은PASS가아니다. Raw/PTS/quality/overflow/resource 오류이면중단하는guards도유지했다.

16. Crash/timeout

Compilation error/assertion failure/host 또는app crash/SIGABRT/deadlock/tool timeout/sandbox failure/resource breach는관찰되지않았다. 첫legacy 부적합·세deadline miss를포함한첫실행기록을보존했다. No busy-wait/unbounded work queue,새media export/AVPlayer 실행없음. No-render2회와조건을통과한renderer1회외에성공률을높이기위한자동재시도는없었다.

17. 이전80miss 귀속

PERF04 원래80miss를동일기록으로분해하면33건은actual submission 이후publication latency가한interval이내였다. 이33건이nominaldeadline을넘으려면arrivallateness의기여가필요하다. 나머지47건은actual submission부터도budget을넘었으며queue/render/검증/전달과burst arrival에따른간접영향이섞인다. 그것을모두renderer CPU시간이라고할수없다.

No-render만으로legacy timing 불량이재현돼driver delivery 문제가실증됐다. 교정후no-render와render부하 모두arrival~0.1ms수준으로개선됐고queuewait도0이었다. 그러나PERF04와이번은thermal/background/arrival분포가다른독립run이므로80−3=77을“driver 원인건수”로확정하지않는다. 이전raw기록의33/47 분해와이번residual3은관측사실이고유일한causal percentage는아니다. 역사적PERF04 DEADLINE FAIL 판정은수정하지않았다.

18. 실제playback 한계

Cached decoded inputs/독립pixel calls/driver-assignedsamplePTS와fixeddeadline simulation이다. 90unique native source decode,actual AVVideoCompositing callback timing,AVPlayer prefetch/display cadence/stale seek,subtitle/spectrum/product preview/export/security-scoped lifetime를검증한것은아니다. Arrival calibration 통과를actualphysical playback PASS라고하지않는다. 이번gate도3miss로실패했고Candidate B 제품채택은보류한다.

19. ONE 다음 권고

**기존fused CPU loop의tail-latency headroom을대상으로한제한된vectorization feasibility gate1건**을권고한다. 현재strictproducer·고정A deadline·rawhash/QA02를유지하고pixel완료와검증후publication을분리해비교해야한다. 이번1건의pure-pixel breach와2건의post-validation breach를모두CPU renderer만의문제라고전제하지않는다. 속도배수를예측하거나전체renderer rewrite/GPU도입을자동추천하지않는다. 이번에는어떤최적화도구현하지않았다.

20. 최종 Git/보존

Preflight931개중허용된test driver1개외930개해시가같다. Renderer/admission/cancellation/reference/QA02/기존SustainedThroughputTests·이전reports/logs/owner/disposable입력은보존했다. 원래driver와실행version·최종diff도별도보존했다. All refs/HEAD/upstream/main은그대로이고staged diff는비어있다. HANDOFF/ROADMAP의기존수정과untracked work/recovery refs를유지했다. 정확한최종status/sourcehash/resources는preservation-check.json에있다.

Renderer algorithm/production source/image import/project format 변경없음. Stage3C-2/spectrum export/new dependency 구현없음. Owner media/project/output 수정없음. Staging/commit/push/reset/cleanup 없음. 모든이전증거를보존했고보고후중단한다.
