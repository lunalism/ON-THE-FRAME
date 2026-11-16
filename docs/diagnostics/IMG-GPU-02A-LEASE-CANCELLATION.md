TASK ID: IMG-GPU-02A
STATUS: LEASE AND CANCELLATION PASS

2026-10-29. 격리 ownership adapter의 결정적 검사, 두 실제 Metal command, 기존 합성 경로의 제한된 정확도 회귀를 통과했다. sustained90·제품 playback·장기 안정성 통과가 아니다.

### 1. 실제 상태

feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2, main44943eadabdf5a37d5242d614e7279813126dfde. 기존 GPU01/02 미커밋 파일과 ignored 증거를 확인하고 보존했다. CLAUDE.md, GPU01/02 보고서·구현·테스트, 기존 admission/cancellation 및 QA02 계약의 세션 검토를 따랐다. 이전 검사에서 적용 AGENTS.md는 발견되지 않았다. Git network/history 작업 없음.

### 2. 파일

새 파일: `app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/InFlightLease.swift`, 같은 디렉터리의 `InFlightLeaseTests.swift`, 이 보고서. 수정: 같은 디렉터리의 `MetalNV12Experiment.swift`의 ownership/timeout wrapper만. shader·색·alpha·chroma·geometry 식은 변경하지 않았다. 증거 루트는 `app/selftest-work/img-gpu02a-20261029-01/`이며 freeze.json에 기존3,275개 파일과 refs를 fingerprint했다.

### 3. 소유권·상태

GMLeaseBook은 최대2active/4pending Ticket을 보유한다. Ticket은 고유id/generation, state, 단일 terminal, submitted/retired 플래그와 resources를 갖는다. created→admitted→submitted 뒤 completed/failed 또는 논리 canceled/timedOut으로 진행한다. retired는 별도 물리 상태다. completed-but-not-retired는 completion lock 안에서만 존재하고 밖에 남지 않는다.

Metal render는 command, input/output PB, CVMetalTexture wrappers와 MTLTextures, cache, PNG/LUT, pipeline/queue/device를 lease에 보유한다. command completion handler가 book/ticket을 강하게 소유하므로 호출자가 timeout으로 돌아가더라도 실제 completion까지 수명이 이어진다. completion 뒤 resources를 비워 command-handler 소유권 고리를 해제한다.

### 4. 논리 종료와 회수

client terminal은 lock 안에서 단 한 번 선택하고 callback은 lock 밖에서 호출한다. 중복 callback과 재진입은 같은 terminal을 재발행하지 않는다. submitted 작업의 cancel/timeout은 자원·active slot을 회수하지 않는다. 실제 completion만 회수한다. pending 또는 미제출 작업은 GPU가 사용하지 않으므로 즉시 회수한다.

timeout은 GPU 완료가 아니다. 기존 render의10초 wait 실패는 timedOut 처리 후 book 전체를 quarantine한다. 신규 admission을 거부하고 아직 실행 중인 자원은 보유한다. GPU가 영원히 응답하지 않으면 최대 제한된 active 자원을 계속 격리하며 재개하지 않는다. 이를 자동 복구나 leak 해결로 주장하지 않는다.

### 5. 취소·timeout

결정적 검사에서 정상 완료, 제출 전 cancel/failure, 제출 후 cancel/timeout/failure, canceled 뒤 늦은 completion, generation replacement, pending cancel, duplicate completion, 완료/timeout race를 검사했다. submitted 취소 뒤 active 유지와 payload 약한 참조 생존, completion 뒤 약한 참조 소멸을 확인했다. 미완료 ticket 자원은 재사용하지 않으며 이번에는 pool 자체를 만들지 않았다.

### 6. 결정적 테스트

세 XCTest 메서드가 통과했다. terminal4종 매트릭스, 제출 전2종, capacity6tickets+overflow거부, generation 교체와 재-admission, quarantine, 32회의3-way completion/timeout race를 포함한다. 정확히 한 callback, retire 후 resources empty, drain 뒤 active/pending0을 assert했다. callback이 counts를 재진입하여 deadlock 없이 완료했다. 임의 sleep을 쓰지 않았다.

### 7. 실제 Metal

네 번째 XCTest에서 blit fill command2개를 실행했다. 정상 command와 controlled cancel command 모두 실제 status.completed를 관찰했다. shared event를1/2로 기다리게 하여 취소 검사의 command가 제출 뒤 완료되기 전에 논리 취소를 확실히 수행하고, 그 뒤 event를 열었다. 따라서 GPU가 먼저 끝난 사례를 취소 성공으로 포장하지 않았다.

정상 client terminal completed, 취소 terminal canceled 각각1회이며 late callback은 취소를 바꾸지 않았다. completion 뒤 active0/resources empty, buffer fill93을 확인했다. GPU timestamp 실행 구간은 정상7.833325µs, 취소6.375005µs였다. 이는 end-to-end latency가 아니다. 실제 NV12 합성 timeout10초나 GPU fault를 주입하지 않았다. 실제 gate는 adapter의 command/buffer 소유권과 completion을 확인하며, CVMetalTexture 경로는 다음 회귀에서 정상 completion을 확인한다.

### 8. 단일·여섯 프레임 회귀

기존 testBoundedMetalNV12를 새 출력 루트에서 실행하여 최소1+기존6프레임을 검사했다. 모두 raw Y/Cb/Cr 최대차0, canonical RGB 최대차0, 기존 독립 QA02 PSNR≥40/flat≤3 통과, top geometry/sourceID 통과다. reader가 sourcePTS를 검사하며 outputPTS는 직접 버퍼의 테스트 sidecar라는 기존 한계는 같다.

기존 테스트에 포함된 짧은3×6 matched 확인도 실행됐다. 이번 목적의 새로운 성능 판정으로 쓰지 않는다. 90-frame workload와 decode benchmark는 실행하지 않았다. 기존 GPU01/02 증거를 덮어쓰지 않았다.

### 9. Resource 관측

결정적 high-water는 active2/pending4, 실제 Metal은 순차 command1개씩이었다. 정상/취소 drain 뒤 active/pending0을 assert했다. quarantine 중 submitted1을 유지하며 신규 admission을 거부하고 completion 뒤0으로 돌아왔다. 실제 residency나 장기 plateau를 입증한 수치는 아니다.

회귀 내부 RSS 최대604,880,896바이트, 외부 time 최대607,993,856바이트로1GiB 미만이다. retry 빌드 time 최대2,527,117,312바이트는 compiler 포함 값으로 테스트 RSS와 구분한다. repository allocated6,952,402,944+developer1,801,748,480바이트로20GiB 미만이며 새 증거 약1.06MB다. 이 작업 전 GPU01 developer 관측1,800,978,432와 비교한 build 증가 약0.77MB 및 새 소스/보고서를 포함해512MiB보다 충분히 작다.

### 10. 실제 명령·종료

공통: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path "$BUILD_ROOT" --filter InFlightLeaseTests`, opt-in은 `OTF_GPU02A=1`이다. BUILD_ROOT는 기존 내부 APFS IMG1A-build 경로다.

- tests.log: 최초 종료1. XCTest setUp의 throwing override 서명 오류로 컴파일 실패, 실행 없음. setUpWithError로 수정했다.
- tests-retry.log: 종료0. Release build와4/4실행 PASS(0.060초).
- regression.log: --skip-build, filter MetalNV12ExperimentTests/testBoundedMetalNV12, 종료0,1실행 PASS(2.481초). RUN은 새 증거 루트/regression, FIXTURES는 기존 img-b-poc1r-20261028-01/reader다.
- optout.log: --skip-build, opt-in 없이4SKIP/0fail, 종료0.
- git diff --check 및 기존 파일 보호 해시 검사 통과.

### 11. 실패·crash

위 최초 compile 오류와 원본 로그를 보존했다. 실행 검사에서는 오류·crash·timeout·stale publication·중복 callback·조기 회수를 관측하지 않았다. 실제 hung GPU를10초 기다려 강제로 시험한 것은 아니다. rendering fastMathEnabled 및 기존 AVPlayer deprecation warning은 남는다.

### 12. 한계

fake completion은 상태 전이를 실제 timing과 분리해 검사한다. 실제 fault injection·GPU hang·동시2GPU 합성·project 교체 UI·AVPlayer integration은 미검증이다. helper는 generation과 pending을 제공하지만 동기 render는 즉시 active slot을 얻지 못하면 명시적으로 실패하며 pending을 자동 대기시키는 제품 adapter가 아니다. submitted command를 강제로 중단시키지 않는다. 취소 후 실행이 끝나면 결과를 publish하지 않고 자원만 회수한다.

### 13. 다음 한정 작업

동일 lease와 shader를 사용한 기존 IMG-GPU-02의 bounded90-frame resource-lifetime gate 재개를 권고한다. 별도 승인 전 실행하지 않는다. 이 PASS는 제품 채택·지속30fps·성능 PASS가 아니다.

### 14. 최종 Git·보존

HEAD/main/refs와 index를 유지했다. 허용된 Metal wrapper 외 기존3,275개 중 다른 파일 변경은 없으며 verification.json에 기록했다. production·project format·image import·Stage3C-2·spectrum export·owner media/project/output 변경 없음. staging/commit/push·cleanup 없음. 기존 IMG 증거와 보고서를 보존했다.
