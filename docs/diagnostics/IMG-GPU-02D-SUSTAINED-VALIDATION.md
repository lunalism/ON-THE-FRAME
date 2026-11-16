TASK ID: IMG-GPU-02D
STATUS: INCONCLUSIVE

2026-10-29. Accounting·lease·정확도 선행 검사와 offline90/paced90이 완료됐고 paced deadline은0/90 miss였다. 다만 동결된 mixed-generation 시나리오는 신세대 요청의 실제 제출·결과 확인을 포함하지 않는다. 요청의 전체 generation gate까지 PASS로 선언하지 않으며 부분 결과를 보존한다. 기존 코드의 의미를 바꾸거나 재시도하지 않았다.

### 1. 실제 Git

feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2, main44943eadabdf5a37d5242d614e7279813126dfde. 기존 GPU01/02/02A/02B/02B-R/02C 소스·보고서와 CLAUDE.md·QA02·PERF05 계약을 확인했다. 세션의 AGENTS.md 검색에서는 적용 파일이 없었다. 원격 조회·fetch·branch/history 변경 없음. 기존3,325개 파일과 refs를 freeze.json으로 보존했다.

새 파일은 이 보고서와 고유 disposable 증거뿐이다. 주 증거 루트는 app/selftest-work/img-gpu02d-20261029-01이다. accounting tiny fixture는 private/tmp의 고유 img-gpu02d-accounting-20261029-01 및 -hint 디렉터리다. 의도적인 symlink rejection fixture가 실제 sustained accounting root에 포함되지 않도록 분리했다. 삭제하지 않았다.

### 2. Accounting

기존 corrected pathComponents parent 비교를 그대로 사용했다. ArtifactBoundaryTests2/2 PASS: valid child·directory hint·old sibling 제외·new limit 이하/초과·combined 초과·missing/root equality·symlink/path traversal 거부. 실제 driver의 task/sustained root와 task-root accounting을 사용했다. Combined du는 repository+전용 developer root를 별도로 검사했다. helper와 limits는 수정하지 않았다.

### 3. Lease·단일/여섯 프레임

InFlightLeaseTests4/4 PASS,0SKIP/0fail. 실제 Metal 정상 및 event-controlled cancellation completion도 통과했다. 기존 testBoundedMetalNV121/1 PASS: 최소1+여섯 프레임 raw·canonical RGB·독립 QA02·geometry/source 검사 통과. 기존 테스트에 포함된 짧은18pair도 실행됐지만 sustained90에 합산하지 않았다.

### 4. Offline90

새 GPU 합성90/90 완료,0.181326166초,496.343fps. 각 출력은 새 render 호출이며 완성된 프레임 replay가 아니다. output position0…89의 n/30 sidecar와 source phase=[1,2,3,4][n%4]를 기록했다. sourcePTS=phase/30이며 decoder가 정확한 sourcePTS를 검사한다. 모든 phase는 PNG[1,5) 안이므로90개 모두 image-active다. source 6개 decoded buffer를 공통 캐시에 두었다.

90개 raw hash가 matching CPU reference와 일치했다. 이 검사는 PNG visibility와 layer 결과를 포함한다. 실제90프레임 media sample/AV callback을 생성한 것이 아니므로 n/30은 테스트의 intended presentation metadata이며 실제 화면 timestamp 검증이 아니다.

Offline active-high1/pending-high0, 각 frame 뒤 lease active/pending0이었다. saturation producer는 직렬 worker1개이며 최대2개를 채워 성능을 측정한 것은 아니다.

### 5. Generation 취소

실제 Metal event로 막은2submitted command와4pending ticket을 한 번 준비한 뒤 replaceGeneration을 호출했다. client canceled6, published0, pending 즉시0, submitted2의 resources 유지, 실제 command completion 뒤 active0/pending0/resources empty를 확인했다. GPU completion을 가짜 callback으로 대체하지 않았다.

하지만 이 시나리오는 여기서 끝나므로 신세대 request를 다시 admit/submit하고 그 결과를 확인하지 않는다. GPU02A 선행 fake/state 테스트의 재-admission 검증은 있지만 이를 이번 실제 mixed 신세대 출력 검증으로 대체할 수 없다. 이 누락 때문에 전체 요청 판정은 INCONCLUSIVE다. frozen driver를 변경하는 것이 금지되어 보완 실행하지 않았다.

### 6. Paced90

offline 및 기존 mixed assertions가 통과한 뒤 같은 driver 내 strict absolute IBPacedArrivalPlan을 한 번 실행했다. output90/90,2.973208834초,30.2703fps, deadline miss0/90, 최대lateness0ms다. driver fidelityValidated=true, arrival lateness P95 0.102667ms/max0.119459ms, final jitter0.076084ms, drift−0.006166ms, early0, missed-window0이었다. driver lateness를 빼서 miss를 재분류하지 않았다.

n/30 위치는90개 unique이며 raw comparison·GPU completion 후 client completion을 기록했다. queue pending-high0, lease active-high1, post-drain active/pending0이다. 하위 command timestamp·submission/wait spans는 raw rows에 있다. admission 시각과 lease retirement의 독립 absolute trace는 없으며 start/return 및 post-drain assertion으로 관찰했다.

단위ms, n90 각각의 중앙값/P95/최대:

| 구간 | Offline | Paced |
|---|---:|---:|
| arrival→client 완료(hash 검사 포함) | 2.052604 / 2.285042 / 4.925625 | 6.587646 / 8.619958 / 10.699750 |
| queue wait | 0.000042 / 0.000084 / 0.000875 | 0.038438 / 0.051791 / 0.410291 |
| GPU timestamp 실행 | 0.457521 / 0.580625 / 0.673292 | 0.583146 / 0.624292 / 0.808167 |
| GPU completion wait | 0.763896 / 0.910125 / 3.166000 | 1.736375 / 1.948375 / 2.332584 |
| command submission | 0.003375 / 0.008208 / 0.050208 | 0.029896 / 0.040167 / 0.046000 |

GPU execution은 wait 안에 포함되므로 둘을 합하지 않는다. source decode·staticPNG/LUT·pipeline 준비는 plan record에 따로 기록했으며 위 timed workload에는 cached source를 쓴다. P95는 각n90의 nearest-rank이며 서로 다른 mode를 합치지 않았다. Nominal30fps 도달과 실제 AVPlayer smoothness는 다르다.

원본 driver는 intended+floor(1e9/30)로 deadline을 계산한다. 일부 position에서 t0+floor((n+1)1e9/30)보다1ns 빠른 보수적 차이가 있으나 코드를 바꾸지 않았다.0miss 결과를 얻기 위해 deadline slack을 주지 않았다.

### 7. Resources

두 workload 모두 각 frame 완료 뒤 active/pending0을 assert했다. mixed high-water2/4, drain0/0이다. renderer는 기존 동기 command completion 확인 뒤 반환하고 lease resources를 retire한다. 실험은 fresh output을 쓰며 동시에 writable output은1개이므로 in-flight output aliasing은 발생하지 않는다. GPU command/resources를 새 pool로 재사용하지 않았다.

device.currentAllocatedSize 관찰:

| 구간 | 최초 | 마지막 | 최대 |
|---|---:|---:|---:|
| Offline frame 시점 | 21,544,960 | 609,861,632 | 609,861,632 |
| Paced frame 시점 | 616,120,320 | 240,599,040 | 728,776,704 |

완료된 command와 lease가0이어도 device allocated가0은 아니다. PNG/LUT/pipeline·캐시·driver 지연 해제가 남을 수 있다. Offline 증가 후 paced에서 감소했지만 장기 plateau나 누수 부재를 입증하지 않는다. 이는 allocation API 수치이며 실제 resident GPU memory가 아니다.

사용 중 resource 추정은 command1, CV plane wrapper6 및 texture binding7(PNG 포함), LUT buffer2다. bottom이 top slot에도 연결되는 alias가 있어 유일 물리 allocation count와 다르다. post-drain lease 소유 임시 resources는0이지만 모든 device 캐시 texture의 개별 개수는 측정하지 않았다. CPU decoded cache active payload는6×3,110,400=18,662,400바이트다.

sustained 프로세스 time 최대RSS699,777,024바이트, row 관찰최대699,744,256바이트로1GiB 미만이었다. repository allocated6,956,670,976바이트, developer1,802,661,888바이트(du 출력 기준)로 합계20GiB 미만이다. 주 증거 allocated1,945,600바이트와 tiny fixture8,192바이트, 새 보고서를 포함한 추가량은512MiB 미만이다. 기존 driver의131,072바이트 extra margin은 이 작은 외부 fixture·새 보고서보다 크다. build 재실행은 없었다. 기존 증거·캐시는 삭제하지 않았다.

### 8. QA02

90개마다 raw equality를 검사했다. 독립 reference는 공통 source phase1…4를 준비할 때 각각 CG/source-over 및 sampled420로 평가했다. 따라서 first/last 및 반복 overlap·alpha·chroma-sensitive 입력 전부가 unique-input reference coverage에 포함되지만180개 출력마다 독립 reference를 다시 계산한 것은 아니다.

phase1…4의 sampled420 PSNR은50.635966/46.883781/50.634639/47.673111dB, flat max2로 기존≥40/≤3를 통과한다. canonical 변환·품질 정책을 바꾸지 않았다. 이전 baseline의 국소 chroma 경계 오차를 제거했다고 주장하지 않는다. 별도 선행 회귀의 CPU/GPU canonical RGB 차이는0이었다.

### 9. 명령·종료

공통: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-build -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path "$BUILD_ROOT" --filter <filter>`.

- accounting.log: ArtifactBoundaryTests, OTF_GPU02BR_ACCOUNTING=새tinyfixture, 종료0,2PASS.
- lease.log: InFlightLeaseTests, OTF_GPU02A=1, 종료0,4PASS.
- regression.log: MetalNV12ExperimentTests/testBoundedMetalNV12, OTF_IMG_GPU01_RUN=새주root/regression, FIXTURES=기존POC1R reader, 종료0,1PASS.
- sustained-first.log: SustainedLeaseTests/testBounded90, OTF_GPU02B_RUN=새주root, OTF_GPU02BR_MANAGED=기존전용developer root, FIXTURES 동일, 종료0,1PASS,4.897초.

총8개 XCTest 실행 PASS,0SKIP/0fail. XCTest 종료0은 frozen assertions 통과를 뜻하며 문서에 요구된 누락 coverage까지 보증하지 않는다. summary.json에 산출 통계, sustained/results.json에 plan·원본90+90rows·mixed 기록, verification.json에 보존 검사 결과가 있다. git diff --check 종료0.

### 10. Crash·timeout

이번 실행에서는 compile/test 오류·crash·timeout·overflow·raw mismatch가 없었다. automatic retry는 없었다. 기존 BLOCKED 보고서와 실패 로그는 변경하지 않았다.

### 11. 한계·위험

신세대 실제 요청/출력 coverage가 빠져 전체 gate PASS는 보류한다. 자원 pool/장기 residency 안정성, 동시2개 합성 throughput, AV callback/presentation, 실제 GPU hang도 검증하지 않았다. source/PTS는 반복6프레임 미디어의 선택과 intended90위치 metadata이며 unique90프레임 원본 미디어가 아니다. arrival jitter 통과와0deadline miss는 이 한 번의cached-workload/Mac 관찰이다.

### 12. 다음 단 하나의 작업

기존 mixed gate의 drain 후 신세대 실제 Metal 요청1개를 제출하여 새 generation 결과와 admission 회복을 확인하는 bounded coverage 보완을 별도 승인하에 수행한다. 성능 최적화나90frame 재시도보다 이 누락을 먼저 닫는다.

### 13. 최종 Git·보호

HEAD/upstream/main·refs·빈 index를 유지했다. freeze 대상3,325개 모두 hash가 같다. 새 보고서와 disposable output만 추가했다. product source·renderer/accounting/lease behavior·owner media/project/output 변경 없음. image import·format9·Stage3C-2·spectrum export 변경 없음. staging/commit/push·cleanup 없음. 모든 이전 증거를 보존했다.
