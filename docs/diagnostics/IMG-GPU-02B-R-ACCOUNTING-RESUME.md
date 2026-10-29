TASK ID: IMG-GPU-02B-R
ACCOUNTING: FAIL
GPU GATE: BLOCKED

2026-10-29. 최초 accounting 회귀가 정상 root에서 실패했다. 요청 §7의 accounting이 여전히 잘못되면 중단하며 실패 run을 자동 반복하지 말라는 규칙을 적용했다. 수정 완료나90-frame 결과를 주장하지 않는다.

### 1. 실제 Git

feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2, main44943eadabdf5a37d5242d614e7279813126dfde. 기존 GPU01/02/02A/02B 변경과 evidence를 확인했다. CLAUDE.md를 읽었다. 이전 검사에서 적용 AGENTS.md는 없었다. network/history 작업 없음.

### 2. 변경 파일

새 `app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/ArtifactBoundary.swift`, `ArtifactBoundaryTests.swift` 및 이 보고서. 수정은 같은 디렉터리 `SustainedLeaseTests.swift`의 root/accounting 검사뿐이다. 기존 renderer·shader·lease·reference를 수정하지 않았다. 새 ignored 증거는 `app/selftest-work/img-gpu02br-20261029-01/`에 기록했다.

### 3. 원래 실패

원래 driver는 task root를 IBDiagnostics에 직접 넘겼다. 공용 helper는 부모를 합산하므로 전체 selftest-work 약2.74GB를 신규 산출물로 셌다. 기존 보고서·실패 로그는 그대로 보존했다.

### 4. 시도한 수정과 첫 회귀 실패

출력을 task/sustained 하위로 옮기고, 별도 helper가 task root의 allocated/logical size와 combined du를 검사하도록 작성했다. 제한값은 그대로다. symlink/escape·missing root·집계 실패를 fail-closed 처리하고 작은 fixture/주입 한도로 A–G를 검사하도록 구성했다.

그러나 최초 정상 root 검사에서 Code300 artifact boundary invalid가 발생했다. 첫 guard는 standardized URL의 부모 equality, symlink resolution equality, directory 여부를 함께 검사한다. 유효한 directory URL의 표현·trailing directory 구분을 포함해 이 guard를 추가 분석해야 한다. 어느 하위 조건인지 계측되지 않았으므로 특정 조건이 원인이라고 단정하지 않는다. A–G 전체 PASS는 없다. 조건을 완화하거나 재실행하지 않았다.

### 5. 선행 lease·정확도

이번 작업에서는 재실행하지 않았다. accounting이 첫 관문에서 실패했기 때문이다. GPU02A/02B의 기존4/4 lease와 단일/여섯 프레임 회귀 결과는 역사적 증거로 보존한다.

### 6. Offline90

NOT RUN. 새 accounting 검증을 통과하지 못했다. completed/FPS 미측정.

### 7. Generation 취소

NOT RUN. 기존 시나리오를 변경하지 않았고 새 결과가 없다.

### 8. Paced90

NOT RUN. deadline/jitter 판정 없음.

### 9. Raw·QA02

새 비교 없음. GPU arithmetic/quality threshold/reference는 그대로다. 이전 PASS를 이번 sustained PASS로 확대하지 않는다.

### 10. GPU resource

새 GPU command를 실행하지 않았다. high-water·post-drain·resident GPU memory 미측정.

### 11. 예산·메모리

큰 dummy 없이128byte older 파일과1byte current 파일을 만들었다. guard가 첫 정상 검사에서 실패하여 symlink fixture 생성 단계까지 진행하지 않았다. limits를 늘리거나 기존 산출물을 삭제하지 않았다. combined20GiB 검사 코드는 추가했지만 회귀로 검증되지 않았고 실제 sustained 실행에서도 사용되지 않았으므로 enforcement가 완료됐다고 주장하지 않는다. 이번에는 time RSS 계측을 실행하지 않았다. Release compiler 메모리를 GPU test RSS로 해석하지 않는다.

### 12. 명령·종료

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer OTF_GPU02BR_ACCOUNTING=<새 task root>/accounting-fixtures swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path "$BUILD_ROOT" --filter ArtifactBoundaryTests`.

기존 내부 APFS scratch를 사용했다. accounting.log: Release compile 성공,1실행/1unexpected failure/0SKIP, 종료1. 정상 root 첫 check에서 throw했다. git diff --check는 종료0. 최초 로그·freeze·작은 fixture를 보존했다.

### 13. Crash·중단

crash·GPU hang·예상치 못한 host 종료는 없었다. test assertion 경유 throw에 따른 정상 실패 종료다. 첫 실패 뒤 자동 retry·GPU run은 없다.

### 14. 한계

accounting correction은 미완료이며 fail-closed guard가 정상 root도 거부하는 상태다. 새 helper/driver를 검증된 것으로 사용하면 안 된다. 전체 관리 예산·symlink·초과 조건 A–G의 런타임 통과 여부는 아직 알 수 없다.

### 15. 다음 단 하나의 작업

정상 root의 각 boundary predicate를 개별 진단하여 fail-closed 경로 비교를 수정하고 A–G 회귀만 먼저 통과시키는 한정 작업을 권고한다. 그 뒤에만 GPU 관문 재개를 판단한다.

### 16. 최종 상태·보존

HEAD/upstream/main과 refs/index를 유지했다. 기존 freeze 대상에서 허용된 SustainedLeaseTests.swift 외 변경이 없음을 verification.json에 기록했다. production·렌더링 산술·quality-policy·owner data·image import·project format·Stage3C-2·spectrum export 변경 없음. staging/commit/push·cleanup 없음. 모든 이전 evidence를 보존했다.
