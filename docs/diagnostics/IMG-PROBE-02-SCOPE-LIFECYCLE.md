TASK ID: IMG-PROBE-02
STATUS: PARTIAL

2026-10-29. 실제 App Sandbox에서 선택 파일의 scope 획득·async 보유·취소/세션 교체 뒤 해제를 확인했다. 그러나 추가 손상 pixel-stream 음성 검사에서 기존 probe가 불완전한 PNG 압축 데이터를 승인했다. Scope 회수는 성공했지만 unsupported-input 회귀 조건은 실패했으므로 전체 LIFECYCLE PASS를 선언하지 않는다. 보호된 production probe를 수정하지 않고 최초 실패에서 중단했다.

경로 표기: REPO는 저장소 루트, EVIDENCE는 REPO/app/selftest-work/img-probe02-20261029-01, BUILD_ROOT는 기존 내부 APFS IMG1A-build scratch다.

### 1. Git

feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2. CLAUDE.md, Media/FileIdentity·ProjectFile·ProjectStore scope/session 동작, 기존 probe/tests 및 GPU 증거를 확인했다. 세션 AGENTS.md 검색에서는 적용 파일이 없었다. index는 비어 있고 기존 미커밋 파일을 보존했다. network/history 작업 없음.

### 2. 새 파일

- app/Engine/Tests/OnTheFrameEngineTests/IMGProbe02/ProbeScopeSession.swift
- app/Engine/Tests/OnTheFrameEngineTests/IMGProbe02/ProbeScopeLifecycleTests.swift
- app/diagnostics/IMGProbe02/ScopeHarness.swift
- docs/diagnostics/IMG-PROBE-02-SCOPE-LIFECYCLE.md

기존 파일 수정은 없다. 생성 app bundle·Info.plist·entitlements·fixture·로그·freeze는 EVIDENCE에만 있다. 새 standalone harness는 normal OnTheFrame target의 OnTheFrame synchronized group 밖이다.

### 3. Harness·sandbox

Headless XCTest와 별도 AppKit 앱을 구분했다. 별도 앱은 기존 StillImageProbe.swift/Media.swift/RenderSettings.swift를 그대로 컴파일하여 diagnostic caller와 링크했다. SCOPE_HARNESS flag는 helper의 모듈 import만 선택한다. 제품 import 코드를 바꾸지 않는다.

앱 bundle ID는 dev.ontheframe.probe02-harness다. Ad-hoc signature와 com.apple.security.app-sandbox=true, user-selected.read-only=true, bookmarks.app-scope=true를 사용했다. codesign 확인과 실제 실행을 수행했다. Bookmark 저장·제품 프로젝트 열기는 하지 않았다.

### 4. 소유권 모델

ProbeScopeSession은 caller-side adapter다. begin이 실제 scope 획득에 성공한 뒤에만 probe를 시작하고 defer로 await validation이 끝난 다음 end를 한 번 호출한다. begin=false/throw는 소유권을 획득하지 않은 상태이므로 end를 호출하지 않는다. 이 strict diagnostic 처리와 모든 bare URL의 일반 접근 정책을 동일시하지 않는다.

Cancellation은 Task 결과를 무효화할 뿐 in-flight await를 건너뛰어 scope를 해제하지 않는다. Session generation을 바꾸어도 기존 작업의 scope는 작업 반환까지 유지하고 결과 publication만 거부한다. 임의 sleep 대신 actor continuation gate의 enter/observe/open 순서로 경합을 제어했다.

### 5. 실제 성공 관찰

actual-sandbox.log에서 선택 전 generated good.png 읽기는 false였다. 실제 NSOpenPanel에서 그 파일을 선택한 뒤 성공 probe3회에 대해 starts3/ends3/active0/high1을 기록했다. Metadata와 실제 validation decode가 이 소유권 안에서 끝났다.

다른 파일을 실수로 선택하면 expected disposable URL과 다르다는 이유로 읽지 않고 거부하도록 했다. 실제 선택은 새 generated good.png와 invalid.png뿐이다.

### 6. 취소·실패

실제 sandbox Task 취소는 gate에 도달한 뒤 cancel하고 scope가 active1/ends3으로 남아 있는 것을 확인했다. Gate를 연 뒤 CancellationError와 starts4/ends4/active0을 확인했다. 이는 validation 직전 async gate에서의 취소이며 synchronous ImageIO 내부를 강제로 중단한 시험은 아니다.

실제 invalid.png는 scope starts1/ends1/active0, invalidSignature로 거부됐다. 마지막 NSOpenPanel은 Escape로 취소했고 scope acquisition0이었다. 취소 이벤트가 새 probe를 시작하지 않았다.

추가 실제 decode-failure 음성 fixture는 아래 §8의 별도 실패다. Metadata 오류와 decode 오류를 같은 성공 사례로 합치지 않는다.

### 7. Identity·stale result

Headless deterministic test에서 새 disposable copy를 validation 직전 atomic replacement하여 changed 오류, release1/active0을 확인했다. 원래 fixture는 변경하지 않았다.

실제 sandbox generation 교체는 active scope를 유지한 상태에서 이루어졌다. 취소하지 않은 validation이 gate 이후 끝나도 stale 결과를 publish하지 않고 starts5/ends5/active0으로 회수됐다. 실제 앱의 published count3은 앞선 성공3회뿐이다.

실제 OS 권한 거부는 선택 전 읽기 실패로 관찰했고 acquire=false는 headless 주입 검사로 확인했다. OS 권한의 강제 revoke나 bookmark 재실행은 미검증이다. stop 호출 뒤 프로세스의 모든 암묵적 Powerbox 권한이 즉시 사라진다고 주장하지 않는다.

### 8. 실행·결과

- lifecycle.log: Release compile, ProbeScopeLifecycleTests의 최초4개4/4 PASS,0SKIP/0fail,0.009초. 성공·반복·denied·invalid metadata·cancel·identity/session 교체 포함.
- regression.log: skip-build로 IMG-PROBE-01의5개와 기존media/project9개14/14 PASS,0SKIP/0fail,0.180초. 기존 임시 limits와 serialization은 그대로다.
- harness-build.log: 기존 실제 probe source와 diagnostic caller/AppKit main standalone compile 종료0.
- codesign.log: 새 진단 앱만 ad-hoc sandbox 서명, 종료0.
- actual-sandbox.log: 실제 GUI 실행 종료0, ACTUAL-SANDBOX-LIFECYCLE-PASS marker. 이는 해당 앱의 scope 조건 marker이며 전체 task의 최종 판정과 구분한다.
- decode-failure.log: 추가 testActualDecoderFailureAfterMetadataReleasesScope1실행/1FAIL/0unexpected/0SKIP, 종료1. 컴파일 성공, 실제 negative assertion 실패다.

SwiftPM 공통 명령은 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path "$BUILD_ROOT" --filter <class/method>`다. Lifecycle 환경은 OTF_PROBE02_FIXTURE=EVIDENCE/fixtures/good.png, OTF_PROBE02_OUTPUT=EVIDENCE/replace이며 source probe 회귀는 OTF_STILL_PROBE_RUN=EVIDENCE/probe-regression이었다.

Standalone compile은 `xcrun swiftc -swift-version 5 -parse-as-library -D SCOPE_HARNESS -O`에 변경하지 않은 Media.swift·RenderSettings.swift·StillImageProbe.swift와 새 ProbeScopeSession.swift·ScopeHarness.swift를 전달했다. 실제 NSOpenPanel은 CUA로 generated good.png, generated invalid.png를 선택하고 마지막 panel을 취소했다. Owner 수동 관찰을 했다고 기록하지 않는다.

추가 실패의 정확한 내용: PNG header와 chunk CRC를 유지하면서 IDAT만780100으로 만든 tiny fixture는 metadata inspection을 통과했다. 이어 실제 ImageIO 경로와 probe validation이 예외 없이 결과를 반환하여 `bad compressed pixels accepted` assertion이 실패했다. Scope counter는 starts1/ends1/active0으로 정상 정리됐다. 독립 Python zlib.decompress는 incomplete or truncated stream 오류를 반환했다(independent-deflate-check.json). 따라서 malformed 압축 데이터가 실제로 승인된 것이며 scope leak이나 fixture가 정상인 경우로 재해석하지 않는다.

원래 IMG-PROBE-01의5개 통과는 당시 coverage 결과로 보존한다. 그 결과가 이 추가 손상 IDAT 사례를 보증하지 않았음이 확인됐다. Production probe 수정은 이번 범위 밖이므로 첫 실패 뒤 재시도·fixture 변경·정책 완화를 하지 않았다.

### 9. Mac UI 관찰·한계

실제 sandbox GUI 동작과 API scope 획득을 관찰했으므로 headless만으로 PASS를 주장한 것은 아니다. 자동화된 실제 Mac 검증이며 소유자 수동 UI 검증은 미실행이다. 실제 sandbox fixture는 작은 PNG였고 실제 JPEG 선택·지속 bookmark·대용량 C decoder 중간 취소는 검사하지 않았다.

### 10. Crash·resource

Host crash·test deadlock·앱 hang은 없었다. 마지막 Escape 후 앱 정상 종료로 이어지며 CUA의 후속 AX 관찰은 timeoutReached(-10005)를 냈다. 앱 process 종료0와 마지막 marker를 확인했으므로 이를 앱 timeout으로 분류하지 않는다.

회귀 test-process time 최대RSS142,786,560바이트로1GiB 미만이었다. 추가 테스트 build 명령 최대2,546,630,656바이트는 compiler 포함 값이며 실제 GUI RSS는 별도 계측하지 않았다. 이번 GUI는 tiny 입력만 사용했다.

최종 repository allocated6,959,763,456 + developer1,804,804,096바이트로20GiB 미만이고, 새 evidence allocated1,134,592바이트 및 작은 source/report/build 증가를 포함해512MiB 미만이다. 새 sandbox container의 OS-managed preference/cache가 생성될 수 있지만 기존 owner 데이터나 시스템 설정을 수정·정리하지 않았다.

### 11. 미해결 결정·의존성

scope 소유권 패턴은 실제 환경에서 확인했지만 malformed compressed PNG 승인 문제를 해결하기 전 probe를 normal import에 연결하면 안 된다. 현재 whitelist·encoded/pixel/memory limits는 여전히 임시다. 이미지 모델·기본 길이·형식9·renderer 채택도 미승인이다. ProjectStore 재설계나 제품 scope 통합을 하지 않았다.

### 12. 다음 한정 구현

별도 승인으로 StillImageProbe의 압축 pixel-stream 완결성 검증을 강화하고 이번 동일 fixture를 명시적 malformed로 거부하는 회귀를 닫는다. Scope helper나 제품 UI를 먼저 넓히지 않는다.

### 13. 최종 Git·보존

HEAD/cached upstream·refs·빈 index를 유지했다. 기존3,460개 파일 hash에 변경이 없음을 preservation.json에 기록했다. Production probe를 포함한 기존 파일은 그대로다.

Normal image import 미활성화, MediaAsset/Timeline/ProjectFile 변경 없음, renderer/spectrum 변경 없음, format9·image timeline·Stage3C-2·spectrum export 구현 없음, owner media/project/output 변경 없음, staging/commit/push·cleanup 없음. 모든 이전 GPU evidence를 보존했다.
