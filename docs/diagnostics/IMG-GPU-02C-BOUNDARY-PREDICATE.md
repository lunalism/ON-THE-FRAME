TASK ID: IMG-GPU-02C
STATUS: ACCOUNTING PASS

2026-10-29. 확인된 parent URL equality 한 조건을 수정하여 기존 A–G와 추가 directory-hint 회귀를 통과했다. GPU gate를 실행하거나 GPU readiness를 판정하지 않았다.

경로 표기: SELFTEST_ROOT는 저장소의 app/selftest-work, BUILD_ROOT는 기존 내부 APFS IMG1A-build scratch다. 새 증거는 SELFTEST_ROOT/img-gpu02c-20261029-01에 기록했다.

### 1. 실제 Git

feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2, main44943eadabdf5a37d5242d614e7279813126dfde. index는 비어 있고 기존 GPU 실험·보고서·환경 파일이 untracked였다. CLAUDE.md, accounting 구현·테스트, GPU02B-R 보고서와 원래 실패를 확인했다. 적용 AGENTS.md는 검색에서 발견되지 않았다. fetch·history·branch 작업 없음.

### 2. 재현한 predicate

기존 작은 fixture의 root는 SELFTEST_ROOT/img-gpu02br-20261029-01/accounting-fixtures/current, 허용 parent는 그 상위 accounting-fixtures다. 기존 폴더를 읽기만 했다. 최초 자동 directory-hint probe는 이미 존재하는 directory이므로 모든 조건이 true였다(predicates.log). 따라서 이것을 원래 실패 재현이라고 보고하지 않는다.

수정 전에 parent를 isDirectory:false로 만들어 기존 테스트가 mkdir 전에 만들었던 URL 표현을 재현했다(confirmed.log). derivedParent absoluteString은 끝 `/`가 있고 parent absoluteString은 없다. 최초 실패 조건은 `r.deletingLastPathComponent()==p`가 false인 것이다. noDotDot=true, unique=true, rootResolvedEqual=true, parentResolvedEqual=true, 실제 directory=true였고 pathParentEqual=true였다.

### 3. 근본 원인

URL은 같은 파일시스템 경로라도 directory hint/trailing slash 표현에 따라 equality가 달라졌다. 원래 테스트는 parent URL을 만든 뒤 mkdir한다. 재현의 resolved/canonical 경로는 원래 경로와 동일하고 대소문자 차이는 없었다. symlink가 containment를 바꾸지 않았으며 parent/root 비교 방향도 맞았다. 파일시스템 위치가 아닌 URL 표현을 parent membership 검사에 사용한 것이 문제였다.

### 4. 정확한 변경 파일

- app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/ArtifactBoundary.swift
- app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/ArtifactBoundaryTests.swift
- docs/diagnostics/IMG-GPU-02C-BOUNDARY-PREDICATE.md

새 ignored 진단 스크립트·로그·freeze·verification은 위 새 증거 루트에 있다. 기존 historical 보고서·helper 이외 코드·원본 로그는 수정하지 않았다.

### 5. 최소 수정

`r.deletingLastPathComponent()==p`만 `r.deletingLastPathComponent().pathComponents==p.pathComponents`로 바꿨다. 단순 문자열 prefix나 case folding으로 바꾸지 않았다. 나머지 guard, symlink resolution equality, directory 존재 검사, 하위 traversal 검사, overflow 및 new/combined budget 코드는 그대로다.

### 6. 회귀 결과

ArtifactBoundaryTests2/2 PASS,0SKIP/0fail,0.008초다. 기존 testSevenAccountingConditions가 정상 child·historical sibling 제외·신규 limit 이하/초과·combined 초과·root equality·missing root·external-to-run symlink·dot-dot 경로 거부를 검사했다. 기존 tiny 데이터는 older128byte/current1byte다.

추가 testExplicitNonDirectoryParentURLRepresentation은 directory hint 없는 parent와 directory child의 URL equality가 실제 false이면서 pathComponents는 동일함을 assert하고 helper가 통과함을 확인했다. 기존 테스트를 삭제·약화하지 않았다.

### 7. 보안 경계

허용 parent의 직접 unique child만 허용한다. root equality·외부 경로·missing directory·symlink resolution 변경은 계속 거부한다. 내부 enumerator도 symlink를 거부하므로 sibling old로의 traversal을 수행하지 않는다. size 조회·열거 오류와 combined 집계 실패는 계속 throw한다. combined budget 검사 및512MiB/20GiB 기본값을 제거하거나 늘리지 않았다.

이 결과는 작은 테스트에서 검증한 accounting 경계다. 적대적 동시 filesystem 교체에 대한 원자적 sandbox/TOCTOU 방어까지 입증한 것은 아니다.

### 8. 명령·종료

수정 전 Foundation Swift probe2회는 종료0이며 두 번째가 실패 predicate를 확정했다. 실제 기존 fixture는 덮어쓰지 않았다.

Release 명령은 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer OTF_GPU02BR_ACCOUNTING=<새 증거 root>/accounting-fixtures swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path "$BUILD_ROOT" --filter ArtifactBoundaryTests`다. tests.log에 보존했다. compile/test 종료0,2실행 PASS다. git diff --check 종료0이다. 기존 첫 실패 로그는 그대로다.

### 9. Crash·timeout

새 compile 오류·test failure·host crash·timeout은 없었다. 이전 accounting FAIL을 삭제하거나 PASS로 다시 쓰지 않았다.

### 10. 한계

실제 GPU·lease 재검증·단일/여섯 프레임·offline90·paced90·AVPlayer·export는 모두 미실행이다. injected combined-limit 검사 통과는 실제 전체 managed-artifact 예산 아래 GPU workload 완료를 뜻하지 않는다. GPU02B/02B-R는 역사적 BLOCKED 상태로 보존한다.

### 11. 다음 한정 단계

별도 지시 후 동일 renderer·lease·품질·deadline을 유지하여 accounting/preconditions부터 bounded GPU02B gate를 재개한다. 이번에는 자동 진행하지 않는다.

### 12. 최종 Git·보존

기존3,316개 파일을 freeze했고 허용한 accounting helper/tests 외 변경이 없음을 verification.json에 기록했다. HEAD/upstream/main·refs·빈 index를 유지했다. 새 보고서를 포함해 작업은 미커밋이다.

GPU workload 미실행, production 변경 없음, project format/image import 변경 없음, owner media/project/output 변경 없음, Stage3C-2/spectrum export 변경 없음, staging/commit/push·cleanup 없음. 모든 이전 증거를 보존했다.
