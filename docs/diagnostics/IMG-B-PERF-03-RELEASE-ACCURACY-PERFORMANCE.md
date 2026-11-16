TASK ID: IMG-B-PERF-03
STATUS: RELEASE CORRECTNESS AND PERFORMANCE MEASURED

> IMG-CP-02 게시 준비: `$REPO`는 저장소 루트, `$SELFTEST_ROOT`는 `$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 실험의 전용 내부 APFS SwiftPM scratch 디렉터리다. 아래 `$VAR`는 실제 실행 전에 해당 경로로 설정한다. 개인 절대경로만 비식별화했으며 원래 명령·실패 재현에서의 경로 역할과 하위 상대경로는 유지했다. 원본 로그는 변경하지 않았다.


실제 `-O` Release에서 정확도를 유지한 성능 측정을 완료했다. 기존 Reader Gate1을 통과했고,두 반복 모두6프레임의 active Y/UV SHA256이 frozen Debug 기준선과 일치했다. Image-active fused loop 중앙값은28.833ms(n8)였으나,image-over-video/no-top active 중앙값33.140ms·최대33.843ms로30fps budget에 여유가 거의 없다. **실시간30fps·제품 채택·장시간 export 검증은 아니다.**

1. 저장소와 Git

`$REPO`,branch `feature/subtitles`. HEAD/upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`,main `44943eadabdf5a37d5242d614e7279813126dfde`. CLAUDE.md,PERF02 report/계측,compositor/scheduler/Reader Gate1,QA02 계약을 확인했고 적용 AGENTS.md는 발견하지 못했다. HANDOFF/ROADMAP 수정과 기존 untracked IMG 실험·.claude/.DS_Store·recovery refs를 유지했다. reset/clean/fetch/pull/merge/rebase/switch 없음.

2. 추가·수정 파일

추가 test-only 파일은 `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/ReleaseBuildVerificationTests.swift` 하나다. Opt-in/runtime assertion configuration/probe 활성 여부를 기록하고 Release 조건을 명시적 guard로 검증한다. 기존 소스 수정은0이다.

새 문서는 `docs/diagnostics/IMG-B-PERF-03-RELEASE-ACCURACY-PERFORMANCE.md`다. 새 증거 root는 `app/selftest-work/img-b-perf03-20261028-01/`: preflight.json,source-fixture-freeze.json,compiler command/runtime config/source list/binary fingerprints,첫 실패와retry logs,Gate1/profile/scheduler/opt-out logs와각JSON,release-stage-summary.json,preservation-check.json이다. Fixture나기존 output을 재생성·덮어쓰지 않았다.

3. 실제 Release build 검증

공통 명령: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path $BUILD_ROOT --filter <해당 test>`.

Verbose compiler 명령에서 test module의 **`-O`,whole-module-optimization,`-enable-testing`,Release output path,Swift language mode5**를 확인했다. `-Onone`/`-Ounchecked`/`-DDEBUG`는 없다. 정확한 명령은 optimized-compiler-command.json,컴파일 source 목록은 release-test-source-list.txt에 보존했다. 렌더러·기존 probe·performance harness가 해당 module에 포함됐다.

Runtime configuration test도 DEBUG=false,isDebugAssertConfiguration=false,isReleaseAssertConfiguration=true,isFastAssertConfiguration=false,probeEnabled=true였다. 일반 Swift `assert`가 -O에서 비활성인 것은 정상이다. 기존 품질/PTS/해시 검사는 explicit throwing guard와 XCTest를 사용하며 Release에서도 실제 실행했다. Opt-in gating도13SKIP으로 확인했다.

최초 `-c release`만 사용한 빌드는 기존 spectrum test에서 ProtoSpectrumStyle/ProtoPCMSource 등을 찾지 못해 실패했다(60 compiler diagnostic lines,연쇄 오류 포함). 해당 정의는 기존 `#if DEBUG || OTF_PROTO_RELEASE` 아래에 있다. `docs/SPECTRUM-DESIGN.md`와 prototype source가 이미 문서화한 Release test 플래그를 사용해 복구했다. `OTF_PROTO_RELEASE`는 기존 test prototype2곳에서만 사용되며 IMGB renderer나production source에는 조건부 경로가 없다. 이를 위해 DEBUG를 켜거나 Package.swift/production/test prototype 파일을 바꾸지 않았다. Spectrum tests 자체도 실행하지 않았다.

Debug와Release binary는 같은 APFS scratch의 `out/Products/Debug/...xctest` 및 `out/Products/Release/...xctest`로 분리된다. 각각24,608,080/16,246,600bytes이고 별도SHA256을 separate-test-binaries.json에 기록했다. 이후 모든 측정 명령에 `--skip-build -c release`와 동일 flags를 명시했다. Debug binary를 Release라고 재명명한 것이 아니다.

4. Hardware/software

Apple M4 Pro,Mac16,8,12 logical CPU,24GiB RAM,arm64,macOS26.6.2/build25G83. Xcode27.1/build27A9275,MacOSX27.0 SDK,Apple Swift6.4(swiftlang-6.4.0.34.1),package language mode5다. PERF02의 CPU/OS/compiler와 일치한다. Background load/thermal/frequency를 고정하지 않았으므로 독립 두 run의 통계 비교를 보편적 가속 배수로 일반화하지 않는다. 새 dependency나시스템 cache 설정 변경 없음.

5. Fixture/source freeze

Frozen 입력은 `app/selftest-work/img-b-poc1r-20261028-01/reader/`의bottom.mov/top.mov/middle.png이며 합성SHA256은 `26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1`다. FHD1920×1080/30fps/6frames,bottom[0,6),PNG[1,5),top[2,4),top(+960,+540),alpha128/255,기존ICC·Left·source-over/downsampling 계약을 유지했다.

Compositor/admission/probe/performance harness/reference/canonical/Gate1의7개 source를 순서대로 hash한 값은 `8c08ab951a1b076e200ccd58042ff57065294a2894eaba80b1fe97f4c9790bbf`다. 각 파일이 PERF02 final hash와 같음을 확인했다. 목록/순서는source-fixture-freeze.json에 있다. 추가 configuration test는renderer 연산에 참여하지 않는다. 기존 retained MP4 digest `c7781efd86c905b80ed60909bca4df0cae364c0eca85ff580b25a219e93acdf5`도 유지했고reference-overhead 측정에서 읽기만 했다.

6. Release correctness 먼저 확인

기존 `ImageAware420GateTests/testInterleavedReaderGate`를 먼저 Release로 실행하여1PASS였다. 6개PTS0…5/30,bottom source ID0…5,top visible ID2/3,PNG visibility/top precedence,alpha와 기존 quality guards가 통과했다. Top geometry는frame2/3 각각518,400luma pixel에서 mismatch0이었다. 기존 native video-component4건도 기준을 통과했다. Frame count/geometry/reference/scheduler logic은 수정하지 않았다.

그 뒤 기존 profiling harness를 두 번 실행해 frozen Debug raw hash와 대조했다. 해시가 다르면 harness가 즉시 실패하므로 성능 결론의 선행 조건으로 삼았다. 두 반복이 모두 hash 검사를 통과한 다음 성능을 해석했다. Raw numerical divergence/rounding drift/UB를 근거 없이 허용한 사례는 없다.

7. Debug 대 Release active Y/UV hash

기준은 `img-b-perf02-20261028-01/baseline-off/profile/raw-baseline.json`이다. 각frame은Y2,073,600+UV1,036,800=3,110,400active bytes다. Stride padding/allocator bytes를 pixel 증거로 사용하지 않았다.

| frame | frozen Debug 및 Release 두 반복의 SHA256 |
|---|---|
| 0 | `8ac95d352569416d375313b76a3ca9485c231041dc669114383c934b5a388dc5` |
| 1 | `92b3a26d5007009a7a5bc82b36389cd5566798ac5a3826b1476effd65cf2c78d` |
| 2 | `4ea33d39d0dd2a84afa24c2559c644c095cdc58f13b2013022008522490ffad2` |
| 3 | `2c5e7616c9b09b32857447329b8be9029647ccf847e8177186e57ae8f66debfc` |
| 4 | `ff3295eb162302c9f26e2b834736be8770a1f8c91aae66e44cffd48d0d2fa486` |
| 5 | `b7249744d2076cf57ad9a7f875df90880d498ca99110cdab0a383dcae5a91add` |

비교 결과는6/6×2회 모두동일이다. Debug 원본plane dump 전체를 별도로 보존한 비교는 아니므로,이 증거는 active-plane SHA256 일치와기존구조/색검증이지allocator 전체의독립bytewise 비교는아니다. 해시 불일치가없었으므로 frame/byte 차이 분류는 해당 없음이다.

8. QA02 품질 gate

기존 QA02 canonical contract와PSNR≥40dB/flat maximum≤3를 그대로 사용했다. Release Reader의sampled420/directCG/points 기록은 PERF02 Debug Reader와 정확히 같은JSON 수치였다.

| frame | sampled420 PSNR | flat | direct CG PSNR | flat |
|---|---:|---:|---:|---:|
| 0 | 65.263362 | 0 | 52.720384 | 1 |
| 1 | 50.635966 | 2 | 42.732953 | 1 |
| 2 | 46.883781 | 2 | 42.250538 | 1 |
| 3 | 50.634639 | 2 | 42.433968 | 1 |
| 4 | 47.673111 | 2 | 42.670597 | 1 |
| 5 | 69.445844 | 0 | 68.853385 | 0 |

이것은새Reader regression이며retained export 재수용이 아니다. 역사적Gate2 QUALITY FAIL(frame3 PSNR39.9763,frame4 flat4,boundary106,clone101)과QA02의별도canonical reassessment PASS를그대로보존했다. Threshold나reference 변경없음.

9. 단계별 Release 시간

기존PERF02 probe 위치를 그대로 사용했다. C/D/E와pixel writes는fused loop이고분리하지않았다. Worker CPU는동일동기thread의user+system CPU,wall은monotonic uptime이다. Harness process CPU에는동시worker/framework 작업도포함한다.

| image-active stage | n | wall median/max ms | worker CPU median/max ms |
|---|---:|---:|---:|
| A-sourceFrame-lookup | 8 | 0.002688/0.025917 | 0.002500/0.023000 |
| source-validation-ID-metadata | 8 | 0.018229/0.067250 | 0.018500/0.067000 |
| F-context-buffer-allocation | 8 | 0.072229/0.144625 | 0.072000/0.145000 |
| CDE-and-pixel-writes | 8 | 28.833499/33.735708 | 28.812000/33.704000 |
| output-tags-and-cancel-check | 8 | 0.008896/0.018459 | 0.008500/0.018000 |
| activeTotal | 8 | 28.920751/33.843166 | 28.899000/33.810000 |

| workload | n | fused wall median/max ms | active total median/max ms | active worker CPU median ms |
|---|---:|---:|---:|---:|
| imageNoTop | 4 | 33.047/33.736 | 33.140/33.843 | 33.053 |
| imageWithTop | 4 | 25.348/25.873 | 25.519/25.931 | 25.481 |
| noImage | 4 | 1.504/1.611 | 1.629/1.802 | 1.624 |

ImageWithTop(frame2/3)는원래우하단quarter를YUV copy하며imageNoTop(frame1/4)보다연산량이적다. NoImage(frame0/5)는기존full-copy fast branch다. 처리pixel을새로생략한것이아니다.

10. Debug 대 Release 성능 비교

다음은같은fixture/source/계측경계/표본구성의관측중앙값이다. 첫 run의OS cache/thermal/background 상태까지같게통제한paired benchmark는아니다. Setup이나queue를pixel-loop 개선량에포함하지않고,일반적인가속배수를외삽하지않는다.

| stage/workload | n(각configuration) | Debug wall median ms | Release wall median ms | Debug/Release worker CPU median ms |
|---|---:|---:|---:|---:|
| imageActive/CDE-and-pixel-writes | 8 | 1367.349479 | 28.833499 | 1367.049500/28.812000 |
| noImage/CDE-and-pixel-writes | 4 | 20.222145 | 1.503854 | 20.197500/1.502000 |
| imageActive/A-sourceFrame-lookup | 8 | 0.004333 | 0.002688 | 0.004000/0.002500 |
| imageActive/F-context-buffer-allocation | 8 | 0.062354 | 0.072229 | 0.062000/0.072000 |
| imageActive/activeTotal | 8 | 1367.526271 | 28.920751 | 1367.225500/28.899000 |
| imageNoTop/activeTotal | 4 | 1565.018438 | 33.140375 | 1564.208000/33.053000 |

이번 관측에서 compiler build configuration 차이에 따른 큰 성능 변화와정확한raw hash 보존을확인했다. 미세한source/allocation 단계의차이는clock 비용과작은표본때문에과도하게해석하지않는다. Renderer 코드최적화나rewrite를적용한결과가아니다.

11. Scheduler/queue

두새plan 모두maxActive2/maxPending2,cap2/4,overflow0,종료active0/pending0이다. Release scheduler11개도2active+4pending burst,FIFO,cancel/once-only 등의기존회귀를통과했다.

Pending→promotion은queued6건중앙값25.079ms/max28.062ms다. 즉시active의0 wait6건까지포함하면12건중앙값11.909ms다. Reservation/promotion→render-start dispatch는12건중앙값0.013459ms/max0.026584ms였다. Debug에서는queued8건/전체12건이었으므로queue 표본의상태분포까지같다고가정하지않는다.

두6-frame pipeline은wall157.306/93.433ms,processCPU149.047/134.970ms였다. startReading+framework waiting+raw hash를포함하며display cadence나encoder를측정한값은아니다. Setup/native/reference는별도다. SourceFrame lookup의수µs 값은framework의사전decode latency 전체가아니다.

12. 표본·cold/warm·방법 한계

프로파일은새Release process에서6-frame2회뿐이다. Image-active8,no-image4,imageNoTop4,imageWithTop4,queue12로P95는산출보류했다. Debug PERF02 역시같은8/4표본이며Release correctness는새Gate1에서별도로확인했다.

Cache를flush하지않아true cold 결과는없다. Rep0은새process의첫plan,rep1은같은process의warm 반복이다. PNG preparation wall6.004/4.631ms,plan+ICC LUT setup4.077/1.013ms,reader configuration0.332/0.133ms였다. Plan setup은LUT만의시간이아니다. 기존코드처럼매plan setup을수행했다.

1000회probe init+mark+total calibration은wall1.245917ms/threadCPU1.243ms/processCPU1.242ms였다. Debug calibration과다르게probe 자체도최적화되지만값을stage에서차감하지않았다. 수µs 단계는정밀한순위보다경계확인용이다. CPU 조회실패/async thread 이동은문자열로표시하며worker pixel8건의CPU는모두정상수치다.

별도retained read13.559ms wall/4.833ms processCPU,reference+canonical+stats+JSON156.220ms wall/124.712ms processCPU(n1)는renderer 밖의진단비용이다. 이값을pixel frame latency에넣지않았다. Native video-only reader는시작/decode를포함하는별도비교로JSON에보존했고native kernel time으로혼동하지않았다. Full playback/thermal steady state/장기throughput/encoder 성능은미측정이다.

13. RSS/artifact

Release Gate1 sampled RSS480,673,792bytes(약458.41MiB),profile255,426,560bytes(약243.59MiB)였다. 각각invocation maximum497,270,784/263,700,480bytes로실제media test 관찰치는1GiB 이내다. Continuous peak 보증은아니다.

첫실패build invocation maximumRSS916,029,440bytes,성공한build+configuration invocation은2,899,230,720bytes(약2.70GiB,compiler 포함)였다. 이를test-host 단독peak로해석하거나숨기지않는다. 빌드메모리와실제media test-process RSS를구분했다. 성공build85.58s,Gate1 invocation2.91s,profile2.61s,scheduler1.44s였다.

보고서작성전새diagnostic artifacts1,482,752bytes,Release build를포함한repository+developer root 순증가281,653,248bytes(약268.61MiB)로512MiB 이내였다. Combined managed할당량은약8.08GiB로20GiB 이내다. Debug와이전실험을정리·삭제하지않았다. 최종값은preservation-check.json에있다.

14. 실패·crash·SKIP

| log | 결과 |
|---|---|
| release-build-first.log | exit1,Release compiler 실패. 기존test prototype symbol 미정의;test 실행전실패 |
| release-build-retry.log | exit0,문서화된test-only flags로build83.14s 후configuration test1PASS |
| release-gate1-first.log | exit0,기존Reader Gate1 1PASS,1.310s |
| release-profile-first.log | exit0,기존harness 1PASS/6frames×2/hash 동일,0.633s |
| release-scheduler.log | exit0,기존scheduler11PASS,0.011s |
| release-opt-out.log | exit0,configuration/performance/scheduler13SKIP,0fail |

Build/config command에는 `-v`를사용했고후속은 `--skip-build`였다. Gate1 env는PERF02와같은 `OTF_IMG_B_POC1_RUN`/`OTF_IMG_B_POC1_FIXTURES`,probe는 `OTF_IMG_B_PERF02_PROBE=1`이다. Performance env도PERF02와같은 `OTF_IMG_B_PERF02_RUN`,REPETITIONS=2,FIXTURES,BASELINE,MP4를사용하며새PERF03 하위root로만출력했다. Configuration만 `OTF_IMG_B_PERF03_RUN`을쓴다. Exact command/flags/paths는logs와source-fixture-freeze.json에남겼다.

Raw-hash mismatch/quality assertion failure/실제test-host crash/SIGABRT/sandbox failure/tool timeout은0이다. 첫compiler 실패log와오류목록을보존했다. Opt-out SKIP은PASS가아니다. No error를만들기위해정확도gate를끄거나Debug binary로대체하지않았다.

15. 30fps 평가

33.333ms nominal interval에대해pooled image-active fused median28.833ms/active28.921ms는가까워졌다. 그러나pooled 값에는quarter-copy가있는top frame이포함된다. 더무거운imageNoTop active median33.140ms/max33.843ms는여유가약0.193ms뿐이고최대는interval을넘는다. Lookup/allocation외framework decode,queue,display/presentation,다른효과의비용까지수용한30fps 증거가아니다.

Two active workers와짧은pipeline 완료율을single-frame deadline과섞지않는다. 일부요청의pending25ms도관찰됐으나playback의prefetch lead time이나actual deadline을측정하지않아deadline miss율을추정하지않는다. 현재결론은Release가유망해별도지속검증을할근거가생겼다는것이며30fps 지원확정은아니다. Export/encoder나multi-hour/4K 외삽도없다.

16. ONE bounded 다음 기술 단계

**동일FHD30 mixed-image 조건의짧은3초 sustained-throughput/deadline gate1건**을권고한다. Release·기존색/alpha/geometry/QA02 계약을고정하고warm-up과정상구간을나눠충분한표본의P95/max,active/pending,정확한PTS/sourceID/stale 처리,RSS를검사한다. 별도승인된harness 범위에서실제cadence와prefetch를구분해야한다. 이번에는그gate,새AVPlayer,새export나가속구현을시작하지않았다. 현재수치만으로GPU/vectorization rewrite를자동착수하지않는다.

17. 남은 불확실성

짧은고정fixture와동일hardware에서의관측이다. Raw hash 동등성이모든입력/ICC/HDR/rotation/crop/다른CPU의부동소수점동등성을보장하지않는다. C/D/E는여전히combined이고내부병목비율은미분리다. Release의더낮은계측overhead와cache/OS scheduling 차이도있으므로미세한stage 비율이나일반가속배수를발명하지않는다. Product seek/project-switch/security scope/export cancellation/subtitle/spectrum/owner 정성검증도별개다. Candidate B 제품채택은보류한다.

18. 최종 Git와보존

Preflight818개기존source/report/evidence의해시가모두그대로다. 같은renderer/reference/probe/scheduler/Gate1/Gate2/QA02 및PERF02 logs를보존했다. 기존코드는수정하지않았고새파일은configuration test와이report,새diagnostic artifacts뿐이다. All refs/HEAD/upstream/main은1번과같고staged diff는비어있다. 기존HANDOFF/ROADMAP 수정과untracked work/recovery refs를유지했다. 최종status/hash/resources는preservation-check.json에있다.

Renderer algorithm/production code/project format/quality threshold/Stage3C-2 변경없음. Image import/format9/spectrum export/new dependency/최적화engine 구현없음. 새AVPlayer·MP4 export·owner media/project/output 수정없음. Staging/commit/push/reset/cleanup 없음. 모든이전증거를보존했고보고후중단한다.
