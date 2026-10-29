TASK ID: IMG-GPU-02E
STATUS: GENERATION RECOVERY PASS

2026-10-29. 같은 renderer의 lease book에서 구세대 취소 후 신세대 이미지 요청 하나가 실제 Metal 합성을 완료하고, 구세대 실제 completion 뒤 완전히 drain됨을 확인했다. GPU02D의 누락 coverage를 이 한정 검사로 닫는다. 제품 채택이나 장기 안정성 판정은 아니다.

### 1. 실제 Git

feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2, main44943eadabdf5a37d5242d614e7279813126dfde. CLAUDE.md, 기존 GPU02D evidence·보고서와 lease/renderer를 확인했다. 세션 검색에서 적용 AGENTS.md는 발견되지 않았다. 기존 untracked GPU 작업·환경 파일을 보존했고 network/history 작업을 하지 않았다.

### 2. 변경 파일

새 파일은 `app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/GenerationRecoveryTests.swift`와 이 보고서다. renderer·lease state machine·admission·QA02 reference·production은 수정하지 않았다. 새 증거 루트는 app/selftest-work/img-gpu02e-20261029-01 및 -02다. 첫 freeze 대상3,345개 기존 파일에 변경이 없음을 -02/verification.json으로 확인했다.

### 3. 구세대 순서

GMNV12 instance의 기존 leases에 구세대 ticket1/generation0을 admit/submit했다. 실제 Metal blit command가 shared event value1을 기다리게 했다. event0과 command 미완료를 확인한 다음 replaceGeneration했다. 취소 직후 command status2(committed), client terminal canceled1회, active1, resources nonempty였다. 완료가 먼저 일어난 사례를 cancellation race로 주장하지 않는다.

구세대는 별도 command queue를 사용한다. 이로써 event-blocked 구세대 queue가 신세대 queue의 합성을 막지 않지만 admission book은 동일하다. 구세대는4KiB blit payload이며 이미지 합성 요청은 신세대 하나뿐이다.

### 4. 신세대 admission

기존 GMNV12.render를 정확히 한 번 호출했다. 내부 normal admission을 그대로 통과했다. 구세대가 계속 미완료인 동안 highActive2를 확인했고 신세대 반환 뒤 old active1이 남았다. 새 lease book으로 교체하거나 가짜 GPU completion을 호출하지 않았다.

request2/generation1은 비어 있던 book에서 old id1→replaceGeneration1회→유일한 render admission이라는 동결된 코드 순서로 식별했다. renderer가 반환 metadata에 ticket id를 노출하지 않으므로 독립적인 내부 id 계측값으로 포장하지 않는다. 테스트의 publication identity는 new-generation1-request2다.

### 5. Source·PTS·순서

기존 POC1R bottom/top/middle PNG를 사용했다. fixture digest는26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1이다. source phase2의 reader가2/30 PTS를 확인한다. top layer 위치(+960,+540)의518,400 luma pixel 불일치0, visible marker2였다. PNG 및 top-over-image 순서는 frozen full raw 비교에 포함된다.

출력2/30은 기존 direct-CVPixelBuffer 테스트 sidecar다. 실제 AVVideoComposition callback/sample 또는 화면 presentation timestamp를 검사한 것은 아니다.

### 6. CPU/GPU·QA02

동일 입력의 CPU 결과가 frozen phase2 SHA256 `4ea33d39d0dd2a84afa24c2559c644c095cdc58f13b2013022008522490ffad2`와 일치했고 GPU active Y/UV도 같은 hash·완전 동일 bytes였다. Y/Cb/Cr 최대차0, canonical RGB 최대차0이다.

기존 독립 reference의 sampled420 PSNR46.883781dB/flat2, 직접 CG42.250538dB/flat1로 기존≥40dB/flat≤3를 유지했다. 직접 CG 대비 국소 최대87이라는 기존 chroma 경계 오차는 남으며 GPU가 새로 만든 오차는 아니다. 정책·reference를 바꾸지 않았다.

### 7. Exactly-once·stale

신세대 render가 실제 completed 반환한 뒤 테스트 client publication을 한 번 기록했다. 이는 synchronous return 기반 client이며 새 asynchronous 제품 callback을 만든 것이 아니다. 구세대 event를 연 뒤 old completion handler는 retirement만 수행했고 canceled terminal을 다시 전달하지 않았다. 최종 publications는 신세대 하나, old terminal count1이었다.

### 8. Lease·drain

신세대가 완료된 뒤에도 구세대 resources가 유지됨을 assert했다. 이후 event1을 signal하고 실제 old command.status.completed(4)를 기다렸다. old retired=true/resources0, active0/pending0을 확인했다. GPU command hang을 가짜 callback으로 숨기지 않았다.

highActive2/pending0이다. actual GPU timestamp는 신세대0.509875ms, 구세대blit0.009500ms다. 신세대 allocation→완료 반환3.595917ms, wait3.271833ms이며 GPU time과 wait는 겹친다. device.currentAllocatedSize27,803,648바이트는 캐시·persistent PNG/LUT를 포함하며 resident GPU memory나 누수량이 아니다. post-drain lease0은 device allocation0을 뜻하지 않는다.

내부 RSS 관측최대273,645,568바이트로1GiB 미만이다. Release command의 time 최대2,609,201,152/2,512,224,256바이트는 compiler 포함 값이며 test-host RSS와 구분한다. repository allocated6,957,260,800+developer1,803,091,968바이트로20GiB 미만이다. 두 새 증거 root allocated548,864바이트와 작은 소스·보고서, build 증가를 포함한 추가량은512MiB보다 충분히 작다. 기존 evidence를 삭제하지 않았다.

### 9. 실행·종료·실패

공통: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path "$BUILD_ROOT" --filter GenerationRecoveryTests`. BUILD_ROOT는 기존 내부 APFS IMG1A-build scratch다. RUN은 각 고유 증거 root, MANAGED는 기존 developer root, FIXTURES는 기존 POC1R reader 환경변수로 지정했다.

- -01/test-first.log: 종료1,1실행 FAIL. 새 테스트가 phase3 hash를 phase2 예상값으로 잘못 지정했다. CPU-reference setup guard에서 실패했으며 구세대/신세대 command 제출 전이다. 기존 구현 실패나 GPU pixel regression이 아니다.
- frozen 원본 JSON을 대조하여 새 테스트의 예상값만 phase2로 바로잡았다. 당시 컴파일 중인 첫 바이너리는 이전 상수를 사용했으므로 원본 실패를 보존했다.
- -02/test-corrected-fixture.log: 종료0,1실행 PASS,0SKIP. Renderer/lease/reference를 고치거나 실패를 수용하도록 기준을 낮추지 않았다.
- git diff --check 및 기존 파일/ref 보호 검사 통과. opt-out 검사는 별도 실행하지 않았다.

### 10. Crash·timeout·미검증

실제 crash·timeout 없음. old command는 controlled event로 막았으며 uncontrolled hang을 주입하지 않았다. 실제 오래 걸리는 image command 취소·기기 교체·GPU fault·AVPlayer/export·동시 다중 generation 전환은 미검증이다. 90-frame workload는 재실행하지 않았다.

### 11. GPU02D 누락 조건

구세대가 물리적으로 미완료인 상태에서 같은 book의 신세대 실제 이미지 요청 admission→정확한 출력→단일 publication을 확인하고 old late completion 뒤 drain했다. GPU02D의 신세대 제출 누락 조건은 닫혔다. 기존 GPU02D INCONCLUSIVE 보고서는 수정하지 않고 이 후속 증거를 연결한다. 이전90-frame 자원 allocation 장기 plateau 문제까지 해결한 것은 아니다.

### 12. 다음 제품 개발 권고

렌더러 제품 채택을 확정하기 전에 이미지 media probe의 읽기 전용 정보 계약을 정하는 한정 설계 작업을 권고한다. 이미지 지속시간·저장 형식9·제품 routing은 소유자 결정으로 남기며 이번에는 구현하지 않았다.

### 13. 최종 Git·보호

HEAD/upstream/main·recovery refs·빈 index를 유지했다. 새 테스트와 이 보고서만 새 소스/문서다. production·renderer arithmetic·lease/admission·owner media/project/output·project format·image import·Stage3C-2·spectrum export 변경 없음. staging/commit/push·cleanup 없음. 모든 이전 IMG evidence를 보존했다.
