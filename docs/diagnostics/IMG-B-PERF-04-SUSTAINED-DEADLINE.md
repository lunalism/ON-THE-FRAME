TASK ID: IMG-B-PERF-04
STATUS: DEADLINE FAIL

> IMG-CP-02 게시 준비: `$REPO`는 저장소 루트, `$SELFTEST_ROOT`는 `$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 실험의 전용 내부 APFS SwiftPM scratch 디렉터리다. 아래 `$VAR`는 실제 실행 전에 해당 경로로 설정한다. 개인 절대경로만 비식별화했으며 원래 명령·실패 재현에서의 경로 역할과 하위 상대경로는 유지했다. 원본 로그는 변경하지 않았다.


Offline saturation은90개를1.348802초/66.726fps로 완료했다. 그러나 고정30fps arrival/deadline simulation에서는90개 중80개가 deadline을 넘었고 최대 lateness71.951ms,최종 drain35.052ms였다. **두 run의 출력 정확도는 통과했지만 이 simulation의 deadline gate는 실패했다.**

해석상 중요한 제한이 있다. Driver는 기존 decoder로 준비한 source buffers를 반복 입력하는 offline admission driver이며 실제 AVVideoCompositing callback/90-frame source decode/playback이 아니다. Paced actual arrival jitter도 median14.538ms/max69.982ms로 컸다. 따라서80miss 모두를 renderer에 귀속하거나 실제 production playback의80drop으로 해석하지 않는다. 수치를 고치기 위해 deadline을 옮기거나 자동 최적화·재실행하지 않았다.

1. 실제 Git 상태

저장소 `$REPO`,branch `feature/subtitles`. HEAD/upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`,main `44943eadabdf5a37d5242d614e7279813126dfde`. CLAUDE.md와PERF02/03·계측·scheduler/cancellation·QA02·이전Reader/AVPlayer 증거를확인했다. 적용AGENTS.md는발견하지못했다. 기존HANDOFF/ROADMAP 수정,untracked IMG 실험·.claude/.DS_Store,recovery refs를보존했다. Reset/clean/fetch/pull/merge/rebase/switch 없음.

2. 정확한 변경 파일

`app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/` 안에서만다음변경을했다.

- `ImageAware420Compositor.swift`: 원래private render를test-internal로노출하는접근범위1줄과설명주석만변경. Pixel body/process/transfer는그대로다.
- 새 `SustainedThroughputDriver.swift`: 기존IBAdmission/기존render를호출하는bounded offline driver.
- 새 `SustainedThroughputTests.swift`: Release/opt-in/입력freeze,두90-position test,대표quality 검증.

새보고서는 `docs/diagnostics/IMG-B-PERF-04-SUSTAINED-DEADLINE.md`다. 증거root는 `app/selftest-work/img-b-perf04-20261028-01/`이며각mode의run-records.json,position-timeline.json,results.json,representative raw planes,전체logs,sustained-summary.json,preflight/isolation/preservation JSON을보존했다. Compositor 원본도original-source에있다. 기존scheduler/reference/QA02/기존Gate1/Gate2/제품코드/Package.swift는수정하지않았다.

3. Release 검증

기존과같은 `-c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE`를사용했다. Verbose compiler 명령에서 `-O`,whole-module optimization,Release path,DEBUG 미정의를확인했다. 기존ReleaseBuildVerificationTests도DEBUG=false,Release assert configuration=true,fast/unchecked assert configuration=false,probeEnabled=true를기록했다. 일반Swift assert 비활성화와달리기존throwing guards/XCTest 검사는실행됐다.

SwiftPM test process를configuration/Reader/offline/paced/scheduler별로분리했다. 내부APFS IMG1A-build의Release binary를쓰며후속명령은 `--skip-build -c release`다. 플래그나pixel 알고리즘을유리한결과에맞춰바꾸지않았다. Probe overhead는차감하지않았고수µs stage의정밀한순위는주장하지않는다.

4. Hardware/software

Apple M4 Pro,Mac16,8,12 logical CPU,24GiB RAM,arm64,macOS26.6.2/build25G83,Xcode27.1/build27A9275,Swift6.4/Swift package language mode5다. SDK/Release 경로는compiler log에있다. CPU affinity/frequency/thermal 상태를고정하지않았다. 종료후 `pmset -g therm`은thermal/performance warning 및CPU power status가record되지않았다고보고했다. 실행중thermal trace나throttling 부재의증명은아니다. 종료후load average는1.52/13.29/19.49였다. 다른background 작업의기여를분리하지못했다.

5. Fixture/workload

기존POC1R reader의bottom.mov/top.mov/middle.png를읽기만했다. 합성digest는 `26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1`로그대로다. Frozen Debug raw baseline도PERF02의원본을사용했다.

각mode는정확히90개position n=0…89,output PTS=n/30,duration1/30,nominal3초다. Local phase=n%4+1로기존frame1/2/3/4를순환한다. Phase1/2는각23회,phase3/4는각22회다. 모두PNG-active이며image-no-top45개/image-with-top45개다. No-image copy sample을image-active 수치에넣지않았다. 원래phase2/3의top(+960,+540)quarter copy는기존알고리즘그대로다.

매mode setup에서실제AVFoundation으로bottom1…4/top2·3의6개source buffer를decode한뒤읽기전용으로재사용했다. Static PNG와LUT도setup에서준비했다. Synthetic source나cached final output은없다. 90개모두기존render를독립호출하고새output buffer를할당했다. Source 반복에따른4주기의같은hash는예상된내용반복이며같은request를중복완료한것이아니다. 새movie/PNG fixture를만들지않았다. 대표raw 파일은새고유root의진단출력이다.

6. 실제 scheduling 방법

같은IBAdmission class의별도test instance를사용했다. Active2/pending FIFO4/pending timeout90s/generation/terminal policy는기존과같다. IB420Compositor의AVFoundation-private admission instance나request callback을직접구동한것은아니다. Test driver는cached sources를직접기존pixel function에주며,그함수의AVFoundation process wrapper/decode/context-pool 경로는대체한다. 기존6-frame Reader control은그실제AVFoundation 경로의회귀로별도수행했다.

Offline은t0에6개logical outstanding window를채우고terminal마다하나를보충한다. Completion은기존state lock밖에서호출되며driver는control queue에기록을enqueue한다. Callback 안의semaphore wait는없다. Test thread만완료signal을최대30초기다린다.

Paced는monotonic t0에고정해90개 `DispatchQueue.asyncAfter`를예약한다. Nominal arrival=t0+n/30,deadline=t0+(n+1)/30으로실행전에고정했다. 첫frame도한interval의처리budget을준다. t0는준비후50ms scheduling lead를둔값이고이lead는elapsed/FPS에서제외한다. Sample의n/30 timestamp는driver가CMSampleBuffer wrapper에부여·검증한다. 실제90개의AVVideoCompositing compositionTime을검증한것처럼주장하지않는다.

Arrival/admission/render-start/worker-entry/ready/terminal callback/publication/deadline은position-timeline.json에모두있다. Deadline 판정은ready 이후hash/sample validation을마친result가control queue에서접수된publishedNs를사용한다. Completion callback 시각도별도로기록했다. Logger/recording 비용이포함된simulation이며display presentation은아니다. Scheduler의256-event trace는변경하지않고매completion snapshot을외부bounded store에서deduplicate해90개timeline을복원했다.

7. Offline throughput

Completed90/90,elapsed1.348802s,effective66.726fps다. 모든source/PTS/raw hash가맞았고최종active/pending0,missing/duplicate/cancelled0,overflow0이다. 따라서이cached-source saturation workload의offline≥30fps 조건은통과했다.

Saturation은미리일을주므로queue latency가크며그것을낮은throughput으로잘못해석하지않는다. Nominal90-frame deadline grid에대한참고비교로첫출력1건이10.509ms 늦었다. Offline은paced arrival이아니므로이수치를offline throughput 실패조건으로쓰지않고그대로남겼다. 실제deadline pass 조건은다음paced run이다.

8. Paced arrival/deadline

| 항목 | 결과 |
|---|---:|
| 완료 | 90/90 |
| t0→마지막publication | 3.035052s |
| Effective FPS | 29.654 |
| Fixed nominal deadline misses | 80/90 |
| Maximum lateness | 71.951ms |
| 3초nominal end에완료/잔여 | 88 / 2 |
| 최종accumulated lateness/drain | 35.052ms |
| 최종active/pending | 0 / 0 |
| Missing/duplicate/cancelled/overflow | 모두0 |

Actual arrival−nominal arrival는median14.538ms/P9565.501ms/max69.982ms였다. Default asyncAfter/OS scheduling/control queue의영향을분리측정하지않았다. 따라서이run이jitter-free30Hz producer를faithfully 흉내냈다고하지않고,miss 모두를renderer에귀속하지않는다. Timer coalescing의정확한원인도확정하지않았다.

참고로actual arrival 이후publication latency 자체가33.333ms를넘은것은47건,pixel loop wall만그간격을넘은것은29건이다. 이진단은원래fixed deadline80miss를대체·완화한판정이아니다. Arrival 문제만으로모든차이를설명할수도없다. Warm-up 첫6개에서3miss,나머지84개에서도77miss였다. Miss를관찰한뒤warm-up을빼거나재실행하지않았다.

9. Processing latency/CPU — median/P95/max

P95는nearest-rank ceil(.95*n)이며trimming 없이전체sample을사용했다. 두run을pool하지않았다.

| metric ms | Offline median/P95/max | Paced median/P95/max | n각각 |
|---|---:|---:|---:|
| activeProcessing | 32.502708/34.027584/40.281917 | 32.075416/39.667166/54.543375 | 90 |
| pixelWall | 31.093562/32.823667/38.658792 | 30.942270/38.160666/52.957666 | 90 |
| pixelCPU | 31.094000/32.823000/38.658000 | 30.942000/38.154000/50.596000 | 90 |
| endToEndPublished | 86.675500/94.212958/99.670750 | 33.547271/62.774542/73.493958 | 90 |
| callbackLatency | 86.658459/94.198792/99.659084 | 33.540937/62.765750/73.476250 | 90 |
| hashAndWrapperWall | 1.124604/1.261958/1.418167 | 1.199041/1.348417/1.508417 | 90 |
| sourceAcquireWall | 0.002000/0.003292/0.008417 | 0.004667/0.012875/0.014500 | 90 |
| allocationWall | 0.048458/0.073041/0.182750 | 0.071625/0.121166/0.132167 | 90 |

Active processing은worker-entry→validated output ready이며hash·test CMSampleBuffer wrapper 비용을포함한다. PixelWall/CPU는기존fused C/D/E+pixel writes 경계다. SourceAcquire는cached buffer 조회이며새video decode 시간이아니다. Allocation은fresh IOSurface CVPixelBufferCreate+test instruction 생성으로AVFoundation context pool과동등하지않다. Dedicated no-image copy는이90개에없으며기존Reader control의frame0/5와분리했다. Top-active quarter copy는fused 측정에포함되고따로분리하지않았다.

| active processing ms | Offline median/P95/max | Paced median/P95/max | n각각 |
|---|---:|---:|---:|
| imageNoTop | 33.534/34.107/40.282 | 35.254/40.284/54.543 | 45 |
| imageWithTop | 25.776/26.660/32.347 | 27.885/31.917/32.908 | 45 |

첫6개/나머지84개의active median은offline32.569/29.659ms,paced30.541/32.075ms다. 추가warm-up render나discard는없다. 전체90개를통과조건과deadline 통계에포함했다. OS cache는flush하지않았고각mode는별도test process다.

10. Queue/backlog

| metric ms | Offline median/P95/max | Paced median/P95/max |
|---|---:|---:|
| pending(n90) | 59.294354/60.268333/74.182375 | 0.000000/27.400167/36.494125 |
| dispatch(n90) | 0.007521/0.013708/0.021958 | 0.017375/0.038958/0.050416 |

Offline high-water는active2/pending4,paced는active2/pending1이다. Paced각1초window의maxPending은모두1이었고단조증가하는queue나overflow는없었다. 3초에입력90개는모두도착했지만출력2개가남았고35.052ms뒤drain됐다. Final backlog는0이다. Offline은고정6-outstanding window의의도된대기이며unbounded backlog가아니다. Queue wait와CPU pixel cost를합쳐pixel processing으로부르지않았다.

11. Frame/PTS/source correctness

각run90개position과90개terminal은모두유일하고각각정확히1회다. 모든driver output sample은n/30과duration1/30을검증했다. 각worker는원래source의movie time phase/30과raw ID pattern을검증하고result의scheduler ID/phase를logical request와대조했다. Consecutive phase가달라져source variation을실제로사용했다.

모든active output Y/UV는각phase의frozen Debug SHA256과일치했다. 원본compositor를90회실행했고final output cache는없다. Completion 순서가parallel 때문에position 순서와다를수있지만result는position별로보관하며동일position에오래된phase/ID가publish되지않도록검사했다. 실제화면의ordered presentation/stale-after-seek까지검증한것은아니다.

기존AVFoundation Reader Gate1 control도별도로1PASS였다. Exact6PTS/source ID와top ROI518,400pixel mismatch0/alpha/layer/native checks가통과했다. 이것을실제AVFoundation90-frame scheduling 증거로확대하지않는다.

12. Color/pixel-quality 회귀

QA02 canonical conversion과기존PSNR≥40dB/flat≤3는수정하지않았다. 대표position0,1,2,3,4,88,89를각run에서따로보존하고timed run 뒤quality를검사했다. 시작/끝,top overlap 진입·이탈,phase순환과원래chroma-sensitive 경계를포함한다. 기존full-frame/flat/edgeMaximum/points와top geometry를검사했다.

| 대표position | local phase | sampled420 PSNR / flat | direct CG PSNR / flat |
|---|---:|---:|---:|
| 0 | 1 | 50.635966 / 2 | 42.732953 / 1 |
| 1 | 2 | 46.883781 / 2 | 42.250538 / 1 |
| 2 | 3 | 50.634639 / 2 | 42.433968 / 1 |
| 3 | 4 | 47.673111 / 2 | 42.670597 / 1 |
| 4 | 1 | 50.635966 / 2 | 42.732953 / 1 |
| 88 | 1 | 50.635966 / 2 | 42.732953 / 1 |
| 89 | 2 | 46.883781 / 2 | 42.250538 / 1 |

두 mode의 대표 수치는 같다. 각run7/90개는독립reference pixel score를통과했다. 다른83개는source/PTS/hash를검증했지만별도의pixel-quality score를낸것처럼표시하지않는다. Source영상과PNG가원래내용그대로라hash 비교도기존evidence와동등하게해석할수있다. 역사적Gate2 QUALITY FAIL과QA02 retained-export reassessment PASS는그대로보존했다. 품질실패를속도로감춘사례는없다.

13. Cancellation/exactly-once

두run에서누락0/중복terminal0/취소0/실패terminal0이며각scheduler는90terminal과active/pending0으로끝났다. Lease의cancel 상태를전후검사하고기존admission generation이terminal을결정한다. Cancellation injection은90-position run에서하지않았다. 별도의기존scheduler/cancellation11개회귀가Release에서통과했다. 모든project-switch/AVFoundation cancel race를검증한것으로일반화하지않는다.

14. CPU/RSS/resource

Setup은offline152.176ms wall/55.227ms processCPU,paced146.788ms/55.879ms다. PNG/LUT/6source decode/입력검사이며t0 전에끝난다. Timed run processCPU는offline2.686949s,paced2.913405s,worker CPU 합계는2.677108/2.899720s다. Run accounting의wall에는50ms lead가있지만위FPS에는제외했다. Multiple worker CPU 합계와elapsed wall은다르다.

Timed RSS first→last/max는offline89,800,704→106,905,600/max106,905,600bytes,paced85,966,848→113,262,592/max116,359,168bytes다. 대표raw7개를보존하면서일부성장했고3초관찰만으로leak 여부를일반화하지않는다. Reference/quality 뒤sampled peak는offline485,949,440,paced495,337,472bytes다. 각각전체test invocation maximum494,338,048/503,726,080bytes로1GiB 이내다. Quality의CG/Float intermediates를실제render memory로혼동하지않는다.

Release build+configuration invocation maximum2,672,574,464bytes는compiler 포함값이다. Media test-process peak와구분한다. 새artifact 할당량은보고서작성전46,346,240bytes,build를포함한managed 순증가48,455,680bytes로512MiB 이내,repository+developer root 합계약8.12GiB로20GiB 이내다. 최종값은preservation-check.json에있다. 모든heavy 작업은직렬이며기존출력을clean하지않았다.

15. 오류/crash/timeout

Compilation error/test assertion failure/host 또는app crash/SIGABRT/sandbox failure/deadlock/bounded timeout/resource breach는관찰되지않았다. Unexpected performance anomaly는paced arrival jitter와deadline misses다. 첫offline/paced logs와모든90개timing을보존했다. Deadline miss만으로중간출력을버리지않았고,결과를좋게만들려는재실행·최적화는없다.

16. 실제 명령/exit/SKIP

공통: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/time -l swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path $BUILD_ROOT --filter <test>`.

| log | filter/env | exit/result |
|---|---|---|
| release-build-first.log | -v,ReleaseBuildVerificationTests/testOptimizedConfigurationAndOptIn;기존PERF03 configuration opt-in | 0,build67.60s,1PASS |
| reader-first.log | --skip-build,ImageAware420GateTests/testInterleavedReaderGate;새Reader root/기존fixture | 0,1PASS,1.294s |
| offline-first.log | --skip-build,SustainedThroughputTests/testOffline90 | 0,1test 완료,90/90 correctness 통과 |
| paced-first.log | --skip-build,SustainedThroughputTests/testPaced90 | 0,1test 완료,90/90 correctness 통과,데이터의DEADLINE FAIL 유지 |
| scheduler.log | --skip-build,ImageAwareAdmissionTests;기존scheduler opt-in | 0,11PASS |
| opt-out.log | --skip-build,SustainedThroughputTests;opt-in 없음 | 0,2SKIP |

주요env는 `OTF_IMG_B_PERF02_PROBE=1`,`OTF_IMG_B_PERF04_RUN=<새root>`,`OTF_IMG_B_PERF04_FIXTURES=<기존POC1R reader>`,`OTF_IMG_B_PERF04_BASELINE=<PERF02 baseline-off/profile/raw-baseline.json>`이다. Test harness의exit0은정상수집/정확도검사성공이며deadline PASS가아니다. 최종판정은fixed deadline의90개기록에서DEADLINE FAIL로별도생성했다. SKIP도PASS로세지않았다. No AVPlayer/new MP4 export.

17. 실제30fps 가능성 평가

Offline capacity는 충분했지만 paced fixed-deadline gate는 실패했다. Image-no-top 처리 P95는 paced40.284ms,max54.543ms로33.333ms보다 크다. Pixel loop P95도38.161ms이며 validation/hash/wrapper overhead도 약1.2ms 존재한다. Queue가 작고 mean throughput이 높아도 요청별 deadline 보장은 되지 않는다.

동시에 arrival jitter가 커서 현재 driver만으로 실제 compositor의 실시간 deadline miss율을 분리하지 못한다. 실제 decode/presentation/security scope/owner UI를 포함한 production playback smoothness,3시간 project,다른 hardware를 주장하지 않는다. Candidate B 제품 채택은 보류한다.

18. 남은 성능 위험

Default asyncAfter의 실제 arrival 정확도,OS scheduling/thermal/background load,diagnostic hash와 serial collector 영향,AVFoundation context pool·source decode cadence와의 차이가 남는다. Worker는 원래 pixel function을 호출하며 기존 AVVideoCompositing process wrapper를 실행하지 않는다. Media-cache workload의 장기 압력이나 frame-exact seek/project switching도 미검증이다. 반복4phase/한 static PNG/고정 integer geometry라 다른 색·변형·여러 image/subtitle/spectrum을 대표하지 않는다. Warm-up6개를 빼도 paced84개 중77miss가 남지만 원인을 단일 renderer 수식에 귀속하지 않는다.

19. ONE bounded 다음 권고

**Renderer를 바꾸지 않고 paced arrival driver의 시간 정확도를 분리 검증하는90-position fidelity gate1건**을 권고한다. 고정 deadline을 유지하면서 producer wake-up 정확도와 collector/worker 부하를 구분하고,검토된 pacing 방식에서 arrival jitter를 기록한 뒤 native AVVideoCompositing 경로의 후속 범위를 판단한다. 이번에는 driver를 수정해 재실행하거나 GPU/vectorization을 구현하지 않았다. 실패를 없애기 위한 deadline 이동도 없다.

20. 최종 Git와 보존

Preflight856개 중 허용된 compositor 접근 범위1줄/주석 외855개 해시는 같다. 접근 범위 변경을 되돌린 문자열이 원래 compositor 전체와 byte-identical임을 확인했다. Scheduler/cancellation/reference/QA02/기존 Gate1/Gate2·IMG1A/IMGC·reports/실패 logs·owner 및 disposable 입력을 보존했다. 원본 compositor는 별도 snapshot으로 남겼다. All refs/HEAD/upstream/main은 그대로이고 staged diff는 비어 있다. 기존 HANDOFF/ROADMAP 수정과 untracked work를 유지했다.

Renderer algorithm/production source/project format/quality policy 변경 없음. Product image import/format9/Stage3C-2/spectrum export 구현 없음. Owner media/project/output 수정 없음. 새 product AVPlayer/export integration·MP4 export 없음. Staging/commit/push/reset/cleanup 없음. 모든 이전 증거를 보존했고 보고 후 중단한다.
