TASK ID: IMG-B-PERF-02
STATUS: BOTTLENECK IDENTIFIED

> IMG-CP-02 게시 준비: `$REPO`는 저장소 루트, `$SELFTEST_ROOT`는 `$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 실험의 전용 내부 APFS SwiftPM scratch 디렉터리다. 아래 `$VAR`는 실제 실행 전에 해당 경로로 설정한다. 개인 절대경로만 비식별화했으며 원래 명령·실패 재현에서의 경로 역할과 하위 상대경로는 유지했다. 원본 로그는 변경하지 않았다.


새 측정에서 지배 비용은 **변경하지 않은 CPU fused pixel loop(C/D/E 및 pixel writes)**였다. 이미지 활성8요청에서 이 구간은 active wall 합계의99.9897%였고 worker thread CPU도 wall과 거의 같았다. 계측 off/on의 모든 raw Y/UV hash가 같고 기존 Reader Gate1·scheduler 회귀도 통과했다. 이는 Debug prototype의 병목 확인이며30fps 달성·지속 export 성능·Candidate B 제품 채택 승인은 아니다.

1. 실제 Git 상태

저장소 `$REPO`,branch `feature/subtitles`. HEAD/upstream은 `8475ca7813ac7348ecd78990ee3ed9992fb69673`,main은 `44943eadabdf5a37d5242d614e7279813126dfde`. CLAUDE.md 및 PERF01/POC1R/POC2/QA02 자료와 현재 compositor/scheduler/reference를 확인했다. 적용 AGENTS.md는 발견하지 못했다. 기존 HANDOFF/ROADMAP 수정,untracked IMG 실험·문서·.claude/.DS_Store,recovery refs를 유지했다. Git reset/clean/fetch/pull/merge/rebase/switch 없음.

2. 제안 patch 검토와 조정

`docs/diagnostics/PERF01-Instrumentation-Proposal.patch`의 대상 hunk는 현재 process와 scheduler event record에 맞았다. 하지만 그대로 apply하지 않고 최소한의 test-only 구현으로 옮겼다. 원래 patch 파일은 보존했다.

- Opt-in을 `OTF_IMG_B_PERF02_PROBE=1`로 변경. 기본은 off.
- Monotonic uptime clock과 synchronous worker의 thread CPU를 별도로 기록. CPU 조회 실패·clock 역행·harness async thread 이동은0으로 가장하지 않고 unavailable/invalid/thread-migrated로 표시.
- Span5개와 active total을 worker별 local bounded 배열에 기록. Per-pixel timer/전체 frame diagnostic copy/새 global sample store/새callback I/O 없음.
- Source lookup,validation-ID,context allocation,fused render,output tags를 구분. Pixel 표현식은 나누지 않아 C/D/E와 writes는 명시적으로 combined.
- Scheduler에는 opt-in monotonic timestamp key만 추가. Reservation/pending/FIFO/promotion/cancellation/completion 본문은 동일.

새 로그는 기존 IBLog에 frame당 bounded dictionary1개를 보관한다. File/JSON 출력은 harness에서 수행한다. 기존 로그의 NSLock 외 새 scheduler lock이나 callback wait를 만들지 않았다. Clock·dictionary 비용이0이라고 주장하지 않고 calibration/off baseline과 한계를 보고한다.

3. 정확한 수정·추가 파일

모두 `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/` 안이다.

- 수정 `ImageAware420Compositor.swift`: process timing probe와 마지막 bounded 기록만 삽입. private Planes/render/transfer/pixel 본문은 byte-identical.
- 수정 `ImageAwareAdmission.swift`: record event의 timestamp metadata만 추가. 모든 admission/cancel/terminal 본문은 byte-identical.
- 추가 `IBPerfProbe.swift`: bounded probe와 wall/thread/process CPU snapshot helper.
- 추가 `ImageAwarePerformanceTests.swift`: opt-in bounded reader/해시 비교/setup/native/reference timing harness.

새 문서는 `docs/diagnostics/IMG-B-PERF-02-CONTROLLED-INSTRUMENTATION.md`다. Package.swift/기존 Gate1·Gate2 tests/reference/QA02 canonical/helper·품질 기준은 수정하지 않았다. 새 증거 root는 `app/selftest-work/img-b-perf02-20261028-01/`: original-source,preflight.json,isolation-check.json,applied-instrumentation.diff,stage-summary.json,preservation-check.json,각 실행 log와JSON이다.

4. 계측 경계

| 구간 | 실제 경계/의미 |
|---|---|
| A | process entry의 cancellation/time guard부터 sourceFrame lookup 반환까지. AVFoundation의 사전 decode 시간 아님 |
| validation | format/attachments,source movie time,marker ID 검증 |
| F allocation | render-context lock/read,newPixelBuffer와output shape 검증 |
| C/D/E+writes | 원래 render 전체: pixelbuffer locks,source nearest YUV matrix,ICC LUT,encoded-sRGB alpha blend,inverse LUT,luma/chroma accumulation/quantization/writes,copy branches,deadline checks |
| output | output attachment tagging와cancellation check |
| H active | 위 단계 합계. Admission render-start 직후 process 진입부터 마지막 probe까지;worker logging/terminal completion 전체는 포함하지 않음 |
| G queue | pending→promoted의monotonic 차이. Active reservation/promoted→render-start는 별도dispatch |
| B | harness의기존loadPNG/decode+premultipliedRGBA cache 준비. Plan setup은track insert+ICC LUT 등을합친 별도 구간 |
| I | raw active-plane hash,그리고 별도 retained frame의reference/canonical/stats/JSON 비용 |

Worker span은 동일 동기 thread의user+system CPU를 사용한다. Harness process CPU는 다른 worker/framework 작업도 포함한다. Async 경계에서 thread가 바뀌면 그 thread CPU를 보고하지 않는다. Thread CPU API는 microsecond 단위이며 수µs 단계의순위는정밀하게 해석하지 않는다. 실제 clock 호출·span append 비용도 인접 span에 조금 포함되며 차감하지 않았다.

5. 실제 hardware/software

Apple M4 Pro,Mac16,8,12 logical CPU,24GiB RAM,arm64,macOS26.6.2/build25G83,Apple Swift6.4(swiftlang-6.4.0.34.1). Xcode DEVELOPER_DIR를 `/Applications/Xcode.app/Contents/Developer`로 지정했다. 기존 내부 APFS `~/Library/Developer/ON-THE-FRAME/IMG1A-build`를 재사용한 SwiftPM Debug 실행이며 Release 성능은 측정하지 않았다. CPU frequency/thermal/background load를 통제·기록한 장시간 benchmark는 아니다. 도구·dependency 설치나 시스템 cache 변경 없음.

6. Cold/warm setup

OS/filesystem/codec cache를 비우지 않았으므로 true cold-cache 측정은 없다. Instrumented repetition0은 새 test process의첫 plan이고,그 전에 다른 process에서 Gate1/off baseline이 실행되어 OS cache는이미warm일수있다. Repetition1은 같은 process에서직전6-frame 작업을마친뒤 새plan을만든warm 반복이다. 각plan은원래처럼LUT를만들며,cache 최적화를추가하지 않았다.

| 계측 on setup | rep0 wall/process CPU ms | rep1 wall/process CPU ms | n |
| PNGdecodeAndRGBAcache | 6.321/6.320 | 4.221/4.220 | 각1 |
| compositionAndICCLUTPlan | 5.787/5.591 | 2.503/3.628 | 각1 |
| readerConfiguration | 0.342/0.342 | 0.125/0.126 | 각1 |

Plan setup은ICC LUT 단독 시간이 아니다. Source track loading/insertion과composition 구성도포함한다. PNG가매frame decode된것처럼per-frame 비용에넣지 않는다. Native comparison과reference timing은timed custom reader drain 뒤에 수행했다.

7. 단계별 median/max/sample count — 새 측정

다음은instrumented2회×6프레임에서image-active frame1…4의8요청이다. P95는모든render workload의n<20이므로산출보류했다. 작은표본을여러workload와섞어tail 통계로만들지 않았다.

| image-active stage | n | wall median/max ms | thread CPU median/max ms |
|---|---:|---:|---:|
| A-sourceFrame-lookup | 8 | 0.004333/0.011333 | 0.004000/0.011000 |
| source-validation-ID-metadata | 8 | 0.026167/0.051750 | 0.026000/0.052000 |
| F-context-buffer-allocation | 8 | 0.062354/0.199458 | 0.062000/0.200000 |
| CDE-and-pixel-writes | 8 | 1367.349479/1828.658958 | 1367.049500/1827.346000 |
| output-tags-and-cancel-check | 8 | 0.031354/0.047250 | 0.030000/0.046000 |
| activeTotal | 8 | 1367.526271/1828.775708 | 1367.225500/1827.460000 |

Workload별 active total은다음과같다. Top-active frame2/3는우하단quarter를원래YUV copy branch로처리하므로frame1/4와동일연산량이아니다.

| workload | n | active wall median/max ms | thread CPU median/max ms |
|---|---:|---:|---:|
| imageNoTop | 4 | 1565.018/1828.776 | 1564.208/1827.460 |
| imageWithTop | 4 | 1364.905/1405.929 | 1364.064/1404.720 |
| noImage | 4 | 20.431/21.153 | 20.406/21.153 |

Custom no-image frame0/5도실제로full YUV copy/검증/tag를수행한다. 원래native video-only path와는별도다. Native single-frame reader는다음과같다. Decode/startup/native composition을포함하므로위custom worker loop와동등한kernel timing은아니다.

| native video-only frame | n | reader wall median/max ms | process CPU median/max ms |
|---|---:|---:|---:|
| 0 | 2 | 20.146/21.971 | 8.100/8.506 |
| 2 | 2 | 24.863/25.311 | 11.441/12.472 |
| 5 | 2 | 26.018/26.117 | 8.382/8.552 |

8. Queue wait와active render

Pending 요청8건은pending→promotion 중앙값1,372.669ms,최대1,809.979ms다. 즉시active가된0 wait4건을포함한12요청의중앙값은672.350ms다. Active reservation/promotion→worker render-start의dispatch는12건중앙값0.032333ms,최대0.045417ms였다. Pending 대기와CPU pixel time을합쳐“픽셀 연산”으로보고하지 않는다.

각새plan의snapshot은maxActive2/maxPending2,cap2/4,overflow0,종료active0/pending0이다. 기존scheduler11개검사는2active+4pending burst와FIFO/cancellation/once-only를통과했다. Request ID는각snapshot의local ID로분석했고cumulative trace를중복sample로세지않았다.

각6-frame pipeline 전체는rep0 wall3.184198s/process CPU5.851406s,rep1 wall3.220671s/process CPU6.028161s였다. startReading부터6개sample pull+hash를거친구간이며일부parallel worker 작업을포함한다. 단순6/wall 약1.86…1.88 frames/s는이짧은혼합workload 완료율일뿐sustained playback/export 성능은아니다. 새encoder/export 측정은0이다.

9. Memory/resource/diagnostic 비용

Gate1 sampled RSS475,693,056bytes(약453.66MiB),off baseline87,883,776bytes(약83.81MiB),on profile255,213,568bytes(약243.39MiB)였다. Invocation maxima는Gate1 492,290,048bytes(compiler 포함),baseline470,466,560bytes(compiler 포함),profile263,454,720bytes다. 1GiB 관찰상한이내이며연속peak 보증은아니다. Allocation 호출횟수와GPU memory는측정하지 않았다. Probe는full-frame copy를만들지않는다. Harness의active-plane hash는frame당3,110,400bytes를일시적으로읽어복사하며timing도별도로기록한다.

Probe init+mark+total의1000회calibration은aggregate wall2.430209ms/threadCPU2.426ms/processCPU2.424ms였다. 이를per-frame overhead나정밀단일mark 비용으로가정해차감하지 않았다. Off pipeline wall3.217457s 한건과on3.184198/3.220671s 두건은큰체감계측비용을보이지않지만,n이작아overhead0 또는정확한비율을보장하지 않는다.

별도retained MP4 frame2 read는10.382625ms wall/4.818ms process CPU였다. Reference source decode+기존source-over+QA02 canonical+stats+JSON은3,013.568ms wall/2,985.137ms process CPU(n1)다. 이3초는pixel worker 밖의diagnostic 비용이며renderer latency에귀속하지 않는다. Raw hash overhead와개별pull은batch JSON에모두남겼다. 전체Gate1 test24.770초를renderer 시간으로나누지 않는다.

보고서작성직전새artifact 할당량1,146,880bytes(약1.09MiB),repository6,876,446,720+전용developer root1,516,019,712=약7.82GiB로512MiB/20GiB 한도이내였다. 최종값은preservation-check.json에기록한다. Heavy media작업은직렬실행했고fixture 생성/장시간/4K 작업은없다.

10. 기존 Reader Gate1 correctness 회귀

변경하지않은 `ImageAware420GateTests/testInterleavedReaderGate`를먼저실행했다. 기존disposable bottom.mov/top.mov/middle.png를byte-identical copy로재사용했고digest `26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1`가같았다. QA02 canonical helper와기존source-over/reference/PSNR≥40/flat≤3를그대로사용했다.

| frame | sampled420 canonical PSNR | flat max | direct CG PSNR | flat max |
|---|---:|---:|---:|---:|
| 0 | 65.263362 | 0 | 52.720384 | 1 |
| 1 | 50.635966 | 2 | 42.732953 | 1 |
| 2 | 46.883781 | 2 | 42.250538 | 1 |
| 3 | 50.634639 | 2 | 42.433968 | 1 |
| 4 | 47.673111 | 2 | 42.670597 | 1 |
| 5 | 69.445844 | 0 | 68.853385 | 0 |

6개PTS0…5/30,bottom IDs0…5,visible top IDs2/3가정확했다. Top ROI518,400luma pixel/frame은frame2/3각각mismatch0이다. PNG alpha128/255·구간·lane order 검증을포함한기존quality check가모두통과했다. Native video-component 비교4건도기존기준통과다. Scheduler cap2/4를유지했다.

그다음같은instrumented binary에서probe off로6개raw hash를수집했다. Probe on 두반복의모든Y/UV hash가각frame의off hash와같다. Render 본문byte-identical 정적검사와함께출력보존을뒷받침한다. 과거Gate2 QUALITY FAIL과QA02 retained-export PASS는재작성하지않았고,이번Reader 수치는새경로에분리했다. 새Gate1 marker는새디렉터리에만썼다. Gate2·AVPlayer·export를자동실행하지않았다.

11. 30fps 요구와비교

33.333ms/frame 대비image-active fused median1,367.349ms는약41배다. Pure image-over-video(frame1/4) active median1,565.018ms이며copy quarter가있는top frame도1,364.905ms다. Worker CPU가wall과거의같아dominant active 구간은CPU-bound pixel work다. Small source lookup이나allocation 절감만으로이차이를해소할근거는없다.

Two active slots는frame latency를deadline 이내로만들지않는다. Pending wait,active latency,sustained throughput,actual playback deadline,export throughput은각각별개다. Native/no-image의20ms 안팎측정도mixed-image30fps 증거가아니다. Release profiling/긴steady-state/real AVPlayer deadline을검증하지않았으므로현재30fps 지원이나long-duration export 속도를주장하지않는다.

12. 측정 한계

- C input conversion,D blend,E chroma/output conversion,F writes는하나의loop라combined다. 특정LUT나blend 하나가지배한다고비율을발명하지않는다.
- A는이미decode된framework sourceFrame accessor다. Source predecode latency는분리하지못했다. Reader pull/native/retained read에는decode외wait/startup도있다.
- Debug SwiftPM 성능이다. Release/배포성능이나GPU속도추정은없다.
- OS cache를flush하지않았다. Warm 반복2개,n8/n4/n12는tail·thermal·장기throughput 통계에작다. P95는산출보류했다.
- Hash와log는worker밖이지만contention/queue진행에영향을줄수있다. Gate1의reference부하가있는timing은별도증거이며timed reader drain의수치와pool하지않았다.
- CPU stamp 실패/async thread 이동은명시적으로표기한다. Worker image8건의CPU는모두정상수치다. 수µs의작은stage 비교는clock 비용/해상도와같은차수일수있다.
- Cancellation 논리는그대로이고11개회귀를통과했지만새timing이모든OS race interleaving을재현한다는증거는아니다.

13. 지배 병목

확인된병목은**source accessor·buffer allocation·dispatch가아닌CPU fused pixel loop**다. Image8요청의합산wall 기준active의99.9897%다. 그구간의median wall1.367349s/workerCPU1.367050s,max wall1.828659s/CPU1.827346s였다. No-image copy loop median20.222ms와대조된다. 이는정확한경계와CPU/wall을동시에측정했고출력보존/기존gate를확인한결론이다. Loop 안의어떤수식이최대비용인지는별도미해결로남긴다.

14. 최적화 후보2개 — 제안만

1) CPU bulk/vector 처리(Accelerate/vImage와 custom LUT 조합 포함): 측정 대상은 반복 YUV matrix·LUT·alpha·quantization의 scalar loop다. 일반 vImage 변환이 현재 ICC LUT와 같다고 가정하지 않는다. Source nearest,encoded-sRGB/premultiplied alpha,Left 첫 열의 세로 평균,Float/round/clamp 순서를 보존해야 한다. Raw420/QA02/edge/native/preview-export parity,temporary buffer 상한,cancel 응답 검증이 필요하다.

2) Bounded Metal fused kernel: 독립 pixel/block 연산이 지배한다는 근거가 있다. GPU speedup은 측정하지 않았다. 기존 transfer LUT/alpha/chroma/quantization을 재현하고 bounded IOSurface working buffers,fence/lifetime/generation,cancellation과 terminal once-only를 검증해야 한다. Source 접근 scope는 GPU 작업 종료까지 유지하고 preview/export에서 같은 경로를 사용할 수 있는지도 검증해야 한다.

두 후보 모두 구현하지 않았고 예상 가속 배수를 만들지 않았다. Allocation reuse나 PNG decode cache를 현재 지배 병목으로 우선 추천하지 않는다. Release 비용을 먼저 확인하기 전 renderer 전체 rewrite나 architecture 채택을 권고하지 않는다.

15. 명령·exit·failure·SKIP

공통: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/time -l swift test --package-path app/Engine --scratch-path $BUILD_ROOT --filter <filter>`. 모든 RUN은 새 PERF02 root의 하위 경로이며 원본 FIXTURES는 기존 POC1R reader다.

| log | filter / 주요 env | exit / 결과 |
|---|---|---|
| gate1-first.log | ImageAware420GateTests/testInterleavedReaderGate; OTF_IMG_B_PERF02_PROBE=1,OTF_IMG_B_POC1_RUN=…/gate1,OTF_IMG_B_POC1_FIXTURES=기존 reader | 0,1PASS,24.770s |
| baseline-first.log | ImageAwarePerformanceTests/testBoundedReaderProfile; OTF_IMG_B_PERF02_RUN=…/baseline-off,PROBE 없음,FIXTURES=기존 reader | 0,1PASS,3.320s |
| profile-first.log | --skip-build,same performance filter; PROBE=1,RUN=…/probe-on,REPETITIONS=2,BASELINE=…/baseline-off/profile/raw-baseline.json,MP4=기존 retained | 0,1PASS,9.635s |
| scheduler-first.log | --skip-build,ImageAwareAdmissionTests; PROBE=1,OTF_IMG_B_POC1R_SCHEDULER_RUN=…/scheduler-regression | 0,11PASS,0.015s |
| opt-out.log | --skip-build,ImageAwarePerformanceTests 또는 ImageAwareAdmissionTests의 regex union; opt-in 없음 | 0,12SKIP,0fail |

Performance env prefix는 `OTF_IMG_B_PERF02_`다. MP4는 기록된 `app/selftest-work/img-b-poc2-20261028-01/gate2/six-frames.unvalidated.mp4`,digest `c7781efd86c905b80ed60909bca4df0cae364c0eca85ff580b25a219e93acdf5`를 검증했다. Raw 수치/spans/queue timestamps는 각 JSON에 있다. Fresh 출력만 허용하므로 같은 RUN으로 덮어쓰지 않는다. Setup/native/reference는 timed reader drain과 분리했고 arbitrary sleep을 정확성 조건으로 쓰지 않았다. Broad suite/새 export 없음. SKIP은 품질·성능 PASS가 아니다.

16. Crash·예상외 종료

이번 실행의 compilation error/assertion failure/test-host crash/SIGABRT/timeout/sandbox access error는0이다. APFS scratch와 hardware read 권한 요청은 승인됐고 모든 invocation exit0이다. 첫 실행 로그를 덮어쓰지 않았다. 이전 실험 실패는 그대로 보존했다. Non-finite CPU/time은 safe JSON과 명시적 문자열로 처리하며 invalid CMTime은 sample 검사에서 거부한다.

17. ONE bounded 다음 권고

**동일6-frame fixture의 Release build에서 같은 probe·raw hash·QA02 Reader gate를 검증하는 제한된 성능 gate1건**을 권고한다. 코드 최적화·새 engine 도입 없이 Debug 비용과 최적화 build 비용을 분리한 뒤 CPU vector 또는 Metal의 후속 방향을 판단한다. 이번에는 Release build나 최적화를 실행하지 않았다. Candidate B 제품 채택은 계속 보류다.

18. 최종 Git와 보존

Preflight780개 중 허용된 compositor/scheduler2개만 계측 metadata 삽입으로 변경됐다. 나머지778개 해시는 동일하며 기존 reference/QA02 contract,Gate1/Gate2 logic,보고서,실패 로그,PERF01 미적용 patch,입력을 포함한다. 두 파일 원본은 original-source에 보존했다. Render 본문과 admission/cancel/terminal 본문의 byte-identical 검사를 통과했다. All refs/HEAD/upstream/main은 그대로이고 staged diff는 비어 있다. 기존 HANDOFF/ROADMAP 수정과 untracked work를 유지했다. 최종 hash/status/resources는 preservation-check.json에 있다.

Rendering algorithm/production source/제품 image import/format9/quality threshold/QA02 측정 계약/Stage3C-2 변경 없음. 새 AVPlayer·MP4 export·owner media/project/output 수정 없음. Staging/commit/push/reset/clean 없음. 모든 이전 IMG 증거를 보존했고 보고 후 중단한다.
