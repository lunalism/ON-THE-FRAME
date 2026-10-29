TASK ID: IMG-GPU-02B
STATUS: BLOCKED

2026-10-29. 선행 lease·정확도 회귀는 통과했다. 첫 sustained harness 실행은 offline90 제출 전에 공용 진단 helper의 artifact-limit 오류로 중단했다. CPU/GPU pixel 오류나 실제 새 산출물 예산 초과를 관측한 결과가 아니다. 중지 규칙에 따라 자동 재시도하지 않았다.

### 1. 저장소

feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2, main44943eadabdf5a37d5242d614e7279813126dfde. 예상 기존 GPU01/02/02A 미커밋 자료와 환경 파일을 확인했다. CLAUDE.md와 해당 보고서·구현·QA02·PERF05 strict driver를 검토했다. 이전 검사에서 적용 AGENTS.md는 없었다. network/history 작업 없음.

### 2. 새 파일

`app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/SustainedLeaseTests.swift` 및 이 보고서만 새 소스/문서다. 기존 renderer·lease·shader·reference·보고서를 수정하지 않았다. 새 ignored 증거 루트는 `app/selftest-work/img-gpu02b-20261029-01/`이다.

### 3. Fixture·fingerprints

freeze.json에 기존3,292개 파일과 refs의 SHA256를 기록했다. 기존 bottom.mov/top.mov/middle.png digest는26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1이다. 계획은 output n=0…89, PTS n/30, source phase=[1,2,3,4][n%4], sourcePTS=phase/30이다. 모든 계획 위치에서 PNG가 활성화되며 각각 새 GPU render를 호출하도록 작성했다. 하지만 계획 실행과 plan marker 기록에 도달하지 못했으므로 90-frame frame-plan 실행 증거는 없다.

### 4. Lease regression

precondition.log: Release compile 및 InFlightLeaseTests4/4 PASS,0SKIP/0fail,0.031초. 정상/취소 actual Metal command의 completion도 다시 확인했다. 기존2active/4pending·취소·timeout·generation semantics를 바꾸지 않았다.

### 5. 단일·여섯 프레임

regression.log: 기존 testBoundedMetalNV12 실행 PASS. 최소1+기존6프레임 raw/QA02 gate와 기존 helper에 포함된 짧은18pair 확인을 새 하위 루트에 남겼다. 90-frame 실행으로 계산하지 않는다.

### 6. Offline90

NOT RUN. CPU phase1 reference를 준비·검사하는 단계에서 진단 helper가 throw하여 offline loop에 도달하지 못했다. GPU90 completed0이며 throughput 측정값 없음.

### 7. Paced90

NOT RUN. 선행 gate가 완료되지 않아 strict driver를 시작하지 않았다. deadline PASS/FAIL 판정 없음.

### 8. Raw·QA02

선행 regression에서 기존 기준을 유지했다. sustained의 첫 CPU-reference phase1도 품질 record를 작성했으나 곧이어 artifact guard가 실패했다. 이 부분 결과를 sustained 품질 PASS로 올리지 않는다. 90개 출력의 raw equality·QA02 representative coverage는 미검증이다.

### 9. Source·PTS

기존 reader는 source samplePTS를 검사한다. 새로운90위치 매핑은 코드에 선언했지만 실제 출력이 없으므로 all90 source/PTS 정확성을 주장하지 않는다. 직접 버퍼 sidecar와 실제 AV sample timestamp의 기존 구분도 유지한다.

### 10. Generation cancellation

새 driver에는2submitted event-blocked command+4pending의 단일 generation 교체 시나리오를 작성했다. offline 뒤에 위치하므로 이번에는 실행하지 않았다. 선행 GPU02A 회귀 결과를 새 혼합 workload 통과로 대체하지 않는다.

### 11. GPU ownership

신규 sustained command·lease·pool high-water/post-drain 측정 없음. driver는 GPU worker1개, 최대pending4개를 의도했지만 런타임 검증 전이다. 새로운90-frame 자원 plateau 증거가 없다.

### 12. 메모리·실제 예산

첫 sustained 명령의 time 최대RSS304,873,472바이트로1GiB 미만이다. 확인 시 task 증거 logical992,684바이트였다. repository allocated6,953,508,864 + developer1,802,235,904바이트로20GiB 미만이다. 이번 새 소스·보고서·빌드 증가를 포함해512MiB보다 충분히 작다. 실측GPU residency·90frame allocation 추정은 없다.

오류의 원인은 IBDiagnostics.note가 root.deletingLastPathComponent()를 재귀 합산한다는 점이다. regression의 root는 하위 bounded이므로 해당 작업 경계를 계산했지만 새 driver는 task root를 직접 넘겼다. 그 결과 전체 selftest-work logical2,743,879,624바이트를 계산하여536,870,912바이트 guard를 넘었다. 이는 기존 증거까지 합산한 scope 오류이며 새 작업 산출물 초과와 다르다. 기존 증거를 삭제하거나 한도를 높이지 않았다.

### 13. Timing·queue

sustained GPU 실행·submission·sync·latency·arrival jitter·queue wait·deadline 통계는 미측정이다. PERF05 driver와 fidelity 함수를 재사용하는 코드는 작성했으나 실행 증거는 없다. 테스트 실행시간이나 GPU01 속도를90-frame throughput으로 대신하지 않는다.

### 14. 실제 명령·종료

공통은 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path "$BUILD_ROOT"`다. BUILD_ROOT는 기존 내부 APFS IMG1A-build scratch다.

- precondition.log: `OTF_GPU02A=1`, filter InFlightLeaseTests, 종료0,4실행 PASS.
- regression.log: --skip-build, filter MetalNV12ExperimentTests/testBoundedMetalNV12, 종료0,1실행 PASS. RUN은 새 루트/regression, FIXTURES는 기존 POC1R reader.
- sustained-first.log: --skip-build, filter SustainedLeaseTests/testBounded90, `OTF_GPU02B_RUN`은 새 task root, FIXTURES는 동일. 종료1,1실행 FAIL: IMG-B-POC-1 Code300 artifact limit.
- git diff --check 및 보호 파일 해시 검사 통과. 이 작업에서 opt-out SKIP 검사는 별도로 실행하지 않았다.

### 15. 실패·중단

최초 실패 로그와 부분 results.json을 보존했다. crash·GPU hang·timeout은 관측하지 않았다. artifact guard 실패를 우회하여 다음 gate로 진행하지 않았고 renderer나 기준을 튜닝하지 않았다. 이는 harness blocker이며 RESOURCE LIFETIME FAIL·CORRECTNESS FAIL·DEADLINE FAIL로 분류할 근거는 없다.

### 16. Candidate B

GPU01 feasibility 및 GPU02A lease 결과는 유지한다. 이번 sustained gate는 미완료이므로 제품 채택·30fps·장기 안정성의 근거가 추가되지 않았다.

### 17. 다음 단 하나의 작업

진단 출력 root를 task 하위 전용 디렉터리로 한정하는 harness scope 수정 후, 동일 renderer·lease·기준의 GPU02B 순서를 별도 승인하에 다시 수행한다. 원본 실패는 그대로 남긴다.

### 18. 최종 Git·보호

HEAD/upstream/main과 refs/index를 유지했다. freeze 대상3,292개 파일에 변경이 없음을 verification.json에 기록했다. production·image import·project format·Stage3C-2·spectrum export·owner media/project/output 변경 없음. staging/commit/push·cleanup·기존 evidence 삭제 없음. 모든 이전 IMG 증거를 보존했다.
