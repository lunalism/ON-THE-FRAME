TASK ID: IMG-GPU-02
STATUS: BLOCKED

2026-10-29. 자원 소유권 정적 감사에서 중단했다. GPU 누수·use-after-free가 실제 발생했다고 판정한 결과는 아니다. 요청 §4의 안전한 GPU 재사용을 확립할 수 없으면 기존 구현을 보존하고 BLOCKED를 보고하라는 조건을 적용했다. 요청된 실행 관문은 완료하지 못했다.

### 1. 저장소

feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2, main44943eadabdf5a37d5242d614e7279813126dfde. 시작 시 기존 GPU01 소스·보고서와 환경 파일만 untracked였다. 예상 상태와 일치했다. CLAUDE.md를 확인했다. 네트워크 Git 작업은 하지 않았다.

### 2. 기준선 fingerprints

`app/selftest-work/img-gpu02-20261029-01/baseline-fingerprints.json`에 기존 파일·fixture·보고서·ignored evidence의 SHA256와 refs를 기록했다. GPU01 원본 구현과 실행 증거를 변경하지 않았다.

### 3. 소유권 감사

GMNV12가 device/queue/pipeline/cache/PNG/LUT를 소유한다. render의 지역 변수가 source/output CVMetalTexture wrappers와 CVPixelBuffer를 보유한다. command completion handler는 semaphore만 capture한다. 정상 경로는 semaphore 신호, completed/error 검사 뒤 withExtendedLifetime을 거쳐 cache flush 후 반환한다.

반면 10초 timeout은 GPU completion 확인 없이 throw한다. 해당 경로에는 in-flight request owner로의 자원 소유권 이전이나 completion 이후 drain을 추적하는 계약이 없다. Metal의 자체 resource retain 동작만으로 CVMetalTexture wrapper 및 외부 pixel-buffer 수명까지 안전하다고 가정하지 않았다. 이것은 정적 검사에서 확인한 증명 공백이며 실제 조기 해제를 재현했다는 뜻은 아니다.

### 4. 추가·수정 파일

새 파일은 이 보고서와 새 ignored fingerprint 증거다. GPU01 Swift·테스트·기존 문서는 수정하지 않았다.

### 5. Pool/reuse

기존 코드는 프레임마다 출력과 plane view를 생성한다. 2active/4pending admission, output lease pool, generation-aware publication, completion-driven drain을 제공하지 않는다. 안전한 재사용을 입증하기 전에 추측으로 pool을 추가하지 않았다. rising device allocation만으로 leak이라고 판정하지 않았다.

### 6. 취소·exactly-once

GPU command in-flight 취소·pending 취소·generation replacement를 표현하는 인터페이스가 없다. CPU scheduler의 기존 취소 증거는 GPU 수명 증거로 대체할 수 없다. 새 취소 unit test를 실행하지 않았으며 PASS/FAIL 모두 주장하지 않는다.

### 7. 단일·여섯 프레임

이번 재실행 없음. GPU01에서 raw/수치 정확도 통과가 기록되어 있지만 취소·timeout 자원 안전성은 별도다.

### 8. Offline90

NOT RUN. 선행 자원 관문 미완료로 실행하지 않았다. FPS 미측정.

### 9. Paced90

NOT RUN. 기존 PERF05 strict driver를 검토했으나 새 timer나 workload를 만들지 않았다. deadline 판정 없음.

### 10. 품질

새 raw/QA02 측정 없음. 기존 GPU01 CPU/GPU 차이0과 QA02 통과 이력은 보존한다. 품질 threshold 변경 없음.

### 11. Driver

arrival jitter·queue wait·active/pending high-water 미측정. 기존 calibrated3/90 miss를 이번 GPU 결과로 재분류하지 않는다.

### 12. GPU timing

새 kernel/submission/sync 측정 없음. GPU01 결과를 sustained latency로 확대하지 않는다.

### 13. Resources

새 GPU command·pool·decoded cache를 만들지 않았다. GPU residency·post-cancel drain·plateau를 측정하지 않았다. 정상 캐시, 지연 해제, leak을 구별할 런타임 증거가 부족하다.

### 14. 명령·검사

git status/rev-parse, source/reference/report 읽기, SHA256 freeze, git diff --check만 수행했다. 빌드·테스트·patch 실행 없음. SKIP된 테스트도 없으며 미실행을 SKIP/PASS로 계산하지 않는다.

### 15. Crash·timeout

이번 실제 crash·GPU timeout 없음. 코드의 timeout 경로를 발견한 것이며 timeout fault injection을 실행한 것은 아니다.

### 16. 한계

정적 선행 감사까지만 수행했다. 요청된 취소 unit test와 두90-frame 모드는 미완료다. 따라서 RESOURCE LIFETIME FAIL이나 DEADLINE FAIL로 오인하면 안 된다.

### 17. 채택 권고

GPU01 feasibility 결과는 유지하되 sustained/resource gate 통과 전 제품 채택을 권고하지 않는다.

### 18. 다음 한정 작업

동일 shader를 유지한 completion-owned in-flight lease를 별도 test-only adapter로 설계·검증한다. timeout/cancel 때 terminal publication과 실제 GPU 자원 drain을 분리하고 completion까지 lease를 유지하는 취소 unit gate 하나로 제한한다. 이번에는 구현하지 않았다.

### 19. 최종 상태

기존 HEAD/main/refs/index를 유지한다. production·image import·format9·Stage3C-2·spectrum export·owner media/project/output 변경 없음. staging/commit/push·cleanup 없음. 기존 실험 결론과 evidence를 보존했다.
