# 로드맵 — ON THE FRAME

**SP-5B-04 · 두께·방향·모드 체크포인트 / 커밋 승인 준비.** 기존 SpectrumStyleDraft·Apply/Cancel·guarded setter를 확장했다. 두께는 기존 thicknessMilli의 0.5–64 px inclusive이며 소수점 이하 최대 3자리의 정확한 milli 변환·왕복을 지원한다. 비숫자·NaN/Infinity·범위 밖·초과 정밀도·overflow는 clamp 없이 거부한다. 방향은 above/mirrored/below, 모드는 digital/analog의 기존 enum과 명시적 Picker tag를 사용한다. 방향은 시작→끝 기준선의 수직 방향이며 항상 화면 위·아래를 뜻하지 않는다. 선택/session/generation·작업 제한, no-op·Cancel·한 Apply/Undo 거래, dirty-state·Preview 무효화·저장 표현·계보/타이밍을 유지한다. 위치·높이·RGB와 숨은 alpha·분석 설정을 보존하며 renderer·형식·entitlement·공개 export 게이트는 바꾸지 않았다.

**기존 자동 실행 — SP-5B-02.** Xcode 27.2 matching SDK·기존 APFS DerivedData·단일 작업 Debug 빌드 exit 0, strict signing PASS, 집중 SwiftPM **7/7 PASS**·exit 0이다. 두께 0.5/3.125/64 × 세 방향 × 두 모드의 18조합에서 모델·no-op·한 단계 Undo/Redo·형식 8 저장 복원·다른 속성/계보 보존을 검사했고, 무효 두께와 세 속성의 요청 무효화도 포함했다. 관측 자원 위반은 없었다. 당시 빌드 종료의 ibtoold 잔존 기록은 유지하며 종료시켰다고 주장하지 않는다. 증거는 `app/selftest-work/sp5b02-20261112/`에 보존한다. 이번 문서 작업에서 빌드·서명 검사·테스트를 재실행하지 않았다.

**소유자 관찰 — SP-5B-02M/RESUME.** A–I·K PASS: 컨트롤 표시, 최소/소수/최대 두께 변화, 0.499·64.001·3.1234·abc 거부와 Cancel 복원, 세 방향 차이, digital 막대/analog 연결선, 묶음 draft Cancel, 한 Apply·Undo·Redo로 세 속성/Preview 동시 복원, 재생 중 Apply 즉시 정지·갱신 및 안정 후 이전 스타일 잔상 없음을 확인했다. 재개 작업은 저장 금지였으므로 J는 당시 NOT TESTED / DEFERRED였고 baseline 파일 해시도 유지됐다. 이는 자동 검사가 아닌 소유자 보고다.

**별도 지속성 — SP-5B-02P PASS.** 승인 후 현재 두께 6 편집을 소유자가 같은 폴더의 새 `app/selftest-work/sp5a06-owner-manual-20261112/fixture-sp5b02p-20261112-01.ontheframe`에 다른 이름으로 저장했다. 새 파일에서 3.125 px·mirrored·analog를 함께 적용하고 그 파일만 저장·닫기·재열기하여 값·Preview·영상/소리 유지, 누락 경고 없음·dirty 표시 해제를 확인했다. 저장 파일 검사에서도 thicknessMilli=3125, sides=mirrored, mode=analog, 높이 400·alpha 192·좌표 (320,600)–(1600,600)·RGB (255,80,80)·분석 설정·형식 8 보존을 확인했다. 프로젝트 UUID `0F3F7EFB-0FB0-4141-A049-F3BD438D9492`, Spectrum ID `A987C93B-3615-4C7F-A68B-9C555773A0A6`, sourceKey `699350C6-A1D1-4E9E-8EC3-CA62D73AE839`와 미디어 ID/참조는 유지됐다. 새 파일 SHA-256은 `66e047b485cbccbf37cc56ecc123c64fd78fad213d64fa30b6924332502beef8`, 보호 baseline `fixture.ontheframe`은 `508281c62011a9f2205db8be61979ff046bb61b1dd3012454b0601d3192fbed2`로 유지됐다. 원본·미디어·역사 증거도 보존했다. 별도 J PASS를 이전 no-save 세션의 실행으로 소급하지 않는다.

**남은 한계·후속 승인.** 새 두께 문자열 parser, 전체 ProjectStore 경계의 숨은 속성 거부·stale selection/project 요청에 대한 새 자동 실행 검증은 남아 있다. 엔진 검사와 소유자 관찰이 그 전체 경계를 독립 계측하지는 않는다. 전체 Preview/export·물리 화면/오디오 parity 미검증, 공개 Spectrum export 게이트 유지, Release 준비 미승인, SP-4B 시작 공백 미해결이다. 이전 baseline 높이 350→400 저장 변경 원인은 미확정이며 400은 승인된 재개 기준이다. Stage 5 전체나 Spectrum export 완료가 아니다. 후보는 제품/테스트 네 파일과 두 문서이며 로컬 진단·소유자 파일·시험 프로젝트/미디어·빌드·raw evidence는 제외한다. 이번 작업은 문서만 수정하고 staging·commit·push하지 않는다. 아래 SP-5A-11 승인 대기는 당시 기록이고 해당 체크포인트는 `db4390e`로 게시됐다.

**SP-5A-11 · Spectrum 모양 편집 체크포인트 / 소유자 커밋 승인 준비.** SP-5A-10의 제한된 소스·증거 검토는 READY FOR CHECKPOINT PREPARATION이다. 후보는 제품 Swift 2개·엔진 테스트 2개·ROADMAP/HANDOFF 총 6개다. 구현은 미커밋이며 staging·commit·push는 별도 소유자 승인 대상이다. 이 작업에서는 두 문서만 수정하고 빌드·앱 실행·테스트를 재수행하지 않았다. 아래 SP-4B-21 게시 승인 대기 문구는 당시 기록이며, 해당 체크포인트는 이후 `9a7216f`로 게시되었다.

**구현 범위 — 개별 숫자 입력란 8개.** 선택한 기존 Spectrum 클립의 startX·startY·endX·endY·maxHeight·red·green·blue를 편집한다(7개가 아니라 8개). 좌표·높이는 소수점 이하 최대 3자리 px를 기존 milli-unit에 정확히 변환한다. 좌표 ±10,000 px, 최대 높이 0–1080 px, 기준선 길이 1 px 이상, RGB 정수 0–255를 검사하며 유한하지 않은 값·잘못된 숫자·범위 밖 값을 조용히 clamp하지 않는다. alpha·thickness·mode·sides·bands·주파수 범위·window·offset·floor dB는 이 UI에서 편집하지 않고 보존한다.

입력은 로컬 draft이며 Apply 전 프로젝트를 바꾸지 않는다. Cancel은 현재 스타일로 draft만 복원한다. setter는 선택 ID·선택 revision·프로젝트 session·generation·원래 스타일과 기존 alert/gesture/import/relink/export 제한을 확인한다. 유효한 변경 Apply 한 번은 기존 commit/history를 통한 Undo 거래 한 번이고, no-op Apply·Cancel은 history/dirty 상태를 변경하지 않는다. 기존 dirty-state·저장/복원·pause-for-edit·Preview 무효화 경로를 재사용한다. sourceKey·소리 계보·타이밍과 숨은 스타일을 보존하며 기존 형식 8·모델·renderer를 사용한다. renderer 수학·entitlement·공개 export 게이트는 변경하지 않았다.

**기존 자동 실행 증거 — SP-5A-05.** 실제 parser/setter와 선택 observer를 추출한 진단 assertions **62/62 PASS**, syntax/compiler/assertions exit 0, 집중 SwiftPM 엔진 테스트 **6/6 PASS**·exit 0이다. Xcode 27.2와 일치하는 macOS SDK를 명시하고 충돌하는 상속 SDKROOT는 해당 프로세스에서만 제거했다. PID/시작 신원 기반 자원 관측에서 승인 임계값 위반은 관측되지 않았다. 성공 검증 작업 중 제품 구현은 바뀌지 않았다. 진단은 실제 엔진 Timeline/EditHistory를 쓰지만 ProjectStore 주변 commit/invalidation에는 test double을 사용하므로 전체 store·UI 통합 검증으로 확대하지 않는다. 기존 로그는 `app/selftest-work/sp5a05-20261112/`에 보존하며 이번 문서 작업에서 새 테스트는 실행하지 않았다.

**소유자 관찰 — SP-5A-08/09, 자동 테스트와 별도.** 별도 시험 복사본의 video/WAV를 소유자가 정상 선택창에서 재연결했고 저장·재열기 후 영상·소리가 유지됐다. A–K 수동 확인 PASS: 기존 Spectrum 선택·8개 입력란 표시, 기준선 양끝/폭 변경, 최대 높이 변경, RGB 적용, Cancel 복원·Preview 유지, Apply의 Preview 변경, 한 단계 Undo/Redo, 저장·재열기 스타일/미디어 유지, 무효 입력 거부, 선택 변경 후 오래된 draft 제거, 재생 중 Apply 즉시 일시정지·Preview 갱신이다. 위치는 (192,600)–(1728,600)에서 (320,600)–(1600,600), 높이는 420→300→350, RGB는 (255,195,50)→(255,80,80)으로 확인했다. 이는 해당 시험 조건의 소유자 보고이며 전체 물리적 화면/오디오 parity 수락이 아니다.

**한계·보존 상태.** F 관찰 전부터 문서 수정 표시가 존재했다. 무효 입력의 내부 history는 독립 계측하지 않았고 stale draft 수동 검증은 선택 변경 경로였다. 전체 Preview/export parity·물리적 display/audio parity는 미검증, 공개 spectrum export는 계속 게이트 뒤, Release 준비는 승인되지 않았다. 기존 SP-4B 시작 모델 공백 108.33 ms·첫 관측→첫 이미지 약 172.31 ms와 기타 아래 Preview 한계는 미해결이다. 시험 복사본의 저장된 높이는 **350**, 마지막 소유자 보고의 미저장 앱 높이는 **400**이며 현재 앱 메모리 상태는 알 수 없다. 이번 작업에서 시험 프로젝트를 저장하거나 변경하지 않았다.

**진단 제외 — SP-5A-10 검토 결정.** `app/diagnostics/spectrum-style-edit-check.py`는 고정 로컬 toolchain/SDK 경로, 기존 엔진 빌드 산출물 의존, 소스 문자열 추출의 취약성과 제한된 이식성 때문에 untracked 로컬 진단으로 보존하고 체크포인트에서 제외한다. 삭제·수정·staging하지 않으며 기존 62/62 실행 증거는 유효한 역사 기록으로 유지한다. 소유자 파일·시험 프로젝트·미디어·빌드·raw evidence도 게시 대상이 아니다.

**SP-4B-21 · 문서 정리 / 소유자 게시 승인 대기.** SP-4B-20 읽기 전용 검토는 **READY FOR OWNER COMMIT APPROVAL**로 판정했다. 후보는 Swift 6개·Python 런처 1개·문서 2개 총 9개이며, staging·commit·push에는 별도 명시적 소유자 승인이 필요하다. SP-4B-21에서는 HANDOFF/ROADMAP만 갱신하고 빌드·앱 실행·시험을 재수행하지 않았다.

**기존 SP-4B-17 실행 증거.** Xcode 27.2 / macOS arm64 증분 Debug 빌드 exit 0, strict 서명 PASS, 기존 Sandbox entitlements 유지, 시작 프레임 선택 회귀 **17/17 PASS**. 회귀 직접 자식의 종료 자격·identity 확인 후 SIGTERM과 exit −15를 검증했다. 연속 검사는 선택 대기 180초 만료였으나, 소유자는 당시 선택창이 보였다고 확인했다. 이 결과는 이번 문서 작업에서 재현한 시험이 아니다.

**기존 SP-4B-19 — 내부 진단 capture·transport INTEGRATION PASS.** 소유자가 원본 fixture 폴더를 직접 선택했고 `scopeStarted=true`, 프로젝트 열기와 실제 읽기가 성공했다. 프로젝트 UUID `0F3F7EFB-0FB0-4141-A049-F3BD438D9492`, session/generation 1/2, 미디어 12초·종료 frame 360·경과 12.265초·728행이다. 관측된 PTS/source/64-band/image identity/geometry 불일치는 0이며 자막 전환은 미디어 시각 4.009937초·8.009949초다. 단일 OTFContinuous v1 PASS record는 result 408,619 bytes, trace 209,562 bytes·4,405 events이고 UUID·길이·SHA-256·EOF 검증을 통과했으며 trace truncation은 없다. 원본 네 해시·과거 증거는 보존됐다. 관측자·출력 정리는 `ownedResourcesReleased=true`; 획득한 폴더 scope는 최종 해시 검사·전송 뒤 defer로 해제하는 구조다. 개별 scope-stop 호출을 별도 계측한 결과로 확대하지 않는다. 종료 자격·시작 identity 재확인 후 직접 자식에 SIGTERM을 보내 exit −15를 회수했으며 잔존 직접 자식은 없었다.

**미해결 Preview 한계.** 역사적 시작 모델 레이어 공백 108.33 ms와 신규 첫 관측→첫 이미지 약 172.31 ms는 시간 정의가 같다고 가정하지 않는다. ready-empty 34행(ready 결과의 이미지 없음), no-selected-frame 12행, waiting 3행, 종료 경계 자막 관측 2행을 보존한다. 원인을 확정하지 않았으며 모델 관측은 물리 화면·오디오 수락이 아니다. 전체 Preview 시각 품질 PASS·무공백·전체 Preview/export parity·Release 준비를 주장하지 않는다. 공개 이미지·스펙트럼 export 활성화는 계속 게이트 뒤에 있다. **OWNER MANUAL ACCEPTANCE: DEFERRED — NOT PASS.**

**현재 Debug 계약·제한.** 전용 런처가 직접 자식에 socket FD와 run UUID를 상속한다. 소유자는 NSOpenPanel에서 원본 `app/selftest-work/sp4a01/color` 폴더 자체를 선택해야 한다. selection 신호는 실제 패널 가시성보다 앞설 수 있으므로 소유자 관측과 구분한다. PID·PPID·UID·실행 경로·시작 identity 및 종료 자격을 확인하고, 실패·timeout에서는 bounded wait·잔존 상태를 기록하며 자동 재시도하지 않는다. 현재 경로 검사는 고정 fixture 위치·승인 관리 루트를 전제로 하므로 범용 이식성을 주장하지 않는다. 빌드에는 기존 내부 APFS `$HOME/Library/Developer/ON-THE-FRAME/DerivedData-SP4B`와 Xcode 27.2의 process-local `DEVELOPER_DIR`을 사용한다. 전역 xcode-select는 변경하지 않는다. 새 실행은 별도 승인·자원 게이트를 따른다.

현재 호출 형식(이번 작업에서는 미실행): `python3 app/scripts/continuous-preview-check.py APP FIXTURE --output FRESH_DIR`; 독립 회귀는 `python3 app/scripts/continuous-preview-check.py APP --regression --output FRESH_DIR`. APP는 검증한 signed Debug 앱, FIXTURE는 원본 고정 폴더, FRESH_DIR은 승인 관리 루트 안에 미리 마련한 비어 있는 소유자 소유 고유 증거 디렉터리다. 호스트가 배타적으로 증거를 쓰며 역사적 결과·trace·실패 로그·앱·미디어를 덮어쓰거나 삭제하지 않는다. OTFContinuous v1 결과→trace 순서·bounded 길이·해시·EOF 계약을 유지한다.

기존 증거(저장소 기준·Git 게시 제외): `app/selftest-work/sp4b17-20261112/`의 build-result·regression/outcome, `app/selftest-work/sp4b19-20261112/integration/`의 header·report·trace·outcome·analysis. SP-4B-19 report SHA-256 `31d3ae5edd2dc49d6ba0ef2dd9c80fb94473a7551f6481fc0ebd875cfeb8962b`, trace SHA-256 `6390462dcdf03e72f979dc213e11a9001ba28df9b6e644b75bc9136ffc3a6ca6`. 다음은 최종 9개 파일 manifest에 대한 별도 소유자 게시 승인이다. 아래 SP-4B-16 및 이전 상태·검증 계획은 각 작업 당시 이력이며 현재 실행 예시·다음 지시를 대신하지 않는다.

**SP-4B-16 당시 기록 · PATCH READY — RUNTIME DEFERRED.** 연속 Debug 검사는 자식 앱의 소유자 조작 폴더 선택 후 선택 URL과 획득한 scope를 최종 해시 확인까지 유지한다. 고정 fixture 경로·해시 및 descriptor 기준 읽기 검사를 추가했다. OTFContinuous v1 결과/trace는 유지하고 stderr의 제한된 단계 메시지로 시작·선택·재생·전송 시간을 구분한다. Python 런처는 PPID/UID를 분리하고 모든 종료 경로에서 직접 자식을 제한 시간 기다리며 잔존 상태를 보고한다. `--regression`은 기존 17개 선택 검사를 새로 작성하지 않고 직접 자식에서 실행하고 호스트의 고유 폴더에 결과를 쓴다. Swift Debug/default 구문·Python AST·diff와 소유권 경로를 정적으로 검토했다. 빌드·앱 실행·새 17/17 판정은 없으며 SP-4B-14의 signed 앱·권한 실패 증거는 보존했다. 당시 계획했던 실행의 후속 결과는 위 현재 요약을 따른다. 시작 모델 공백 108.33 ms와 OWNER MANUAL DEFERRED — NOT PASS는 유지한다.

**SP-4B-09 · SIMPLIFICATION PATCH READY.** Debug 연속 관측은 staging 파일과 rename 게시를 제거하고 전용 런처가 상속한 소켓으로 결과·trace를 한 번 전달한다. 런처는 디스크에 증거를 쓰지 않는다. Swift/Python 구문과 diff를 확인했다. 앱 빌드·실행은 보류했다. 과거 12초 관측의 108.33 ms 시작 모델 공백과 실제 화면 수동 판정은 미해결이다.

**SP-4B-08 · BLOCKED.** 실패 정리의 삭제는 제거됐으나 JSON 쓰기와 최종 rename은 staging 이름을 다시 해석한다. 첫 쓰기 후 이 이름이 심볼릭 링크로 교체되면 다른 디렉터리에 trace를 만들 수 있고, 게시 직전 소스가 교체되면 빈 목적지에 교체 객체를 게시할 수 있다. 캐시 삭제 전 소스 검토에서 중지했다. 빌드와 A–J·E1–E4는 미실행이며 게시 감사는 보류한다.

**SP-4B-07 · PATCH READY — TESTS DEFERRED.** SP-4B-06에서 발견한 연속 진단의 실패 정리에서 JSON 삭제와 staging 디렉터리 삭제를 모두 제거했다. 배타적 게시 실패 시 stderr에 실행 UUID와 FAIL을 기록한다. staging을 만든 경우 생성 당시 이름을 가능한 잔여 위치로 보고하고 그대로 보존한다. Debug·기본 조건 Swift 구문 및 diff 검사를 수행했다. 타입 검사와 실행 검증은 보류했다. 이전 시작 계약 17/17 및 12초 관측의 108.33 ms 모델 공백은 기존 결과다.

**SP-4B-06 · BLOCKED.** 연속 진단의 실패 정리는 생성한 파일의 URL만 기억한다. 게시 전 같은 경로의 항목이 교체되면 다른 항목을 재귀 삭제할 수 있다. 경로 교체 시 소유권이 불확실한 임시 항목을 보존하도록 수정하고 재감사해야 한다. 소스 검토에서 중지하여 캐시 삭제·빌드·A–J 실행은 없었다.

**2026-11-08 · SP-4B-05 — PATCH READY — TESTS DEFERRED.** SP-4B-04의 두 게시 차단 경로를 Debug 소스에서 수정했다. 연속 진단은 지정 폴더의 기존 결과·trace 충돌을 거부하고 같은 실행 UUID의 결과를 새 `continuous-evidence/`에 배타적 rename으로 게시한다. 시작 계약 단독 검사는 앱 종료를 런처에 맡기며 결과 쓰기 실패를 stderr에 JSON으로 남긴다. Swift 구문 검사와 diff 검사를 마쳤다. 빌드 시작 여유가 부족해 타입 검사와 A–J 실행은 보류했다. 기존 12초 관측과 17/17 결과는 수정 전 기록이며 시작 모델 공백 108.33 ms와 실제 화면 판정은 미해결이다.

**SP-4B-04 · 게시 보류.** SP-4A-24 정지 프레임 비교를 게시했고, SP-4B-01은 12초 연속 재생을 관측했으며 SP-4B-03 선택 계약은 17/17 통과했다. 연속 진단의 기존 trace 덮어쓰기와 단독 검사의 세션 소유권 확인 없는 종료 요청을 수정해야 한다. 시작 모델 공백 108.33 ms, 실제 화면·오디오 제시, Preview/내보내기 전체 색상 동등성, Release 앱 전체 검증, native finishWriting 정지 복구, 장시간 스펙트럼 내보내기, 실제 sandbox 접근 철회, 공개 스펙트럼 내보내기 활성화는 미해결이다. 소유자 수동 판정은 DEFERRED — NOT PASS.

**2026-11-07 · SP-4B-03 — FRAME SELECTION CONTRACT PASS.** Debug 단일 회귀 검사 17/17 통과. SP-4B-01에서 관측한 시작 구간의 스펙트럼 모델 공백 108.33 ms는 남아 있다. 오프라인 결정적 내보내기와 별도로, 다음 제품 검토에서 실제 디스플레이의 시작 구간을 확인한다. 소유자 수동 판정은 DEFERRED — NOT PASS.

**2026-11-07 · SP-4A-22 — HARNESS VALIDATION PASS.** SP-4A-21 수정본의 증분 Debug 빌드와 A–J 검증을 마쳤다. 119→120과 원본 15개 정지 프레임을 다시 통과했다. 다음 단계는 여섯 후보 파일의 게시 전 재감사다. [시험 기록과 범위](diagnostics/SP-4A-10-STILL-FRAME-PARITY.md).

**2026-11-07 · SP-4A-21 — PATCH READY — TESTS DEFERRED.** Debug 하네스의 교체 관찰자 설치와 result.json 검증을 수정했다. 빌드 시작 여유 부족으로 새 패치의 실행 검증과 게시 판정은 보류한다. [수정과 검증 계획](diagnostics/SP-4A-10-STILL-FRAME-PARITY.md).

**2026-11-07 · SP-4A-20 — 게시 보류.** SP-4A-19의 소유 출력 정리, 필수 래스터 실패 판정, 15/15 회귀 기록을 재확인했다. 교체 시험에서 새 세션의 관찰자 슬롯을 덮어쓸 수 있는 경로와 기준 JSON 형식 오류 시 강제 캐스팅 종료가 남았다. [상세 근거](diagnostics/SP-4A-10-STILL-FRAME-PARITY.md).

**2026-11-07 · SP-4A-19 — HARNESS SAFETY PASS.** 동일 생성 fixture의 Debug 하네스 소유권·실패 판정 A–H, 119→120 및 전체 15/15 회귀를 확인했다. [범위와 한계](diagnostics/SP-4A-10-STILL-FRAME-PARITY.md).

**2026-11-07 · SP-4A-18 — 게시 보류.** Stage 4 정지 프레임 검증 SP-4A-16·17에서 동일 fixture의 119→120 전환과 15/15 정지 프레임, 독립 DFT 및 짧은 실행의 RSS 표본 기준을 확인했다. 프로젝트 교체 시 공유 저장소를 정리하는 종료 경로가 남았다. [결과와 게시 차단 사유](diagnostics/SP-4A-10-STILL-FRAME-PARITY.md).

**2026-11-06 · SP-4A-10 — PARTIAL.** 동일 SP-4A-01 프로젝트용 Debug 정지 프레임 parity 하네스 초안을 추가했다. 원본4개 SHA는 일치하지만 격리 Debug 빌드가 scratch 여유 중지선에 도달해 exit−15로 중단됐다. 새 하네스 컴파일·앱 실행·15개 프레임 검증은 NOT RUN. 기존 export/Preview 결과를 새 parity PASS로 사용하지 않는다. 공개 gate/schema/finalization 불변, OWNER MANUAL DEFERRED — NOT PASS. [범위·중단 증거·다음 단계](diagnostics/SP-4A-10-STILL-FRAME-PARITY.md).

> **상태: 제안(Proposed).** 아래 단계 구성과 순서는 사용자 승인 전의 제안이다([DECISIONS.md](DECISIONS.md) P-001). 일정은 정하지 않았다. 각 단계의 완료 기준도 제안이며, DR- 항목은 소유자 미승인 파생 요구사항이다([PRODUCT.md](PRODUCT.md) §6).
>
> 소유자 확인 방향(2026-10-09): 개인용으로 시작해 성공 시 상업 배포(D-011, D-012), 최대 3시간·4K 지원 목표(D-015, D-016, 미입증), 초기 구현에 라이선스 인프라 제외(D-017). 이 방향 확인은 이 로드맵(P-001)의 승인이 아니다.

## S. 현재 상태 체크리스트 (정본, 2026-10-11)

**2026-11-06 · SP-4A-05 — PUBLICATION READY (내부 안전성 checkpoint 감사·미커밋).** 정확한7개 후보와 SP-4A-04 소스/바이너리/출력 해시·20/20 안전성·native12/12·실패 대상19개·temp18개 증거를 대조했다. 현재 단일 finish 호출 경로의 중대한 게시 차단 결함은 발견하지 않았다. 이번에는 문서3개만 수정했고 새 빌드/기능 시험은 없다. crash−6·정지 종료−15 두 건은 보존한다.

native finish 정지 시 job/temp/scope/slot도 계속 대기하므로 hard timeout·강제 회수는 보장하지 않는다. **제한된 Debug checkpoint는 게시 가능하지만 일반 출시의 bounded cancellation/복구 준비는 차단**이다. writer 정지는 전용 idle timer가 아닌 전체 job deadline이며, source 검사/open/read/promotion 사이와 마지막 취소 검사 이후에는 TOCTOU/취소 경쟁 구간이 남는다. gate/schema/합성 순서 불변, **OWNER MANUAL DEFERRED — NOT PASS**, full Release·장시간·실제 sandbox 철회·preview/export parity·Stage4 전체 미완료를 유지한다.

기준 HEAD/upstream/live remote `e96b8570d286d7fb82258907e81c971cbd39dd62`, main/복구 refs/기존 사용자 파일 보존, index 비어 있음. 관리 약18.617/20GiB, 정리·staging/commit/push 없음. 다음 권고는 별도 지시에 따른7개 파일의 좁은 게시 checkpoint다. [상태 머신·single-call 가정·native 한계·TOCTOU·증거·게시 범위](diagnostics/SP-4A-04-EXPORT-SAFETY.md#sp-4a-05--finalization-안전성-게시-감사-2026-11-06)

**2026-11-06 · SP-4A-04 — EXPORT SAFETY PASS (생성 fixture 자동 검증·미커밋).** finalization 취소 후 finishWriting 호출이 예외로 종료되는 경합을 재현했다(exit−6). 첫 수정의 실제 native finish/cancel 경합에서도 완료 대기가 멎는 것을 재현/보존했다(exit−15 두 건). 최종 수정은 finish 시작/취소를 직렬화하고 시작 전에는 취소, 시작 뒤에는 native 완료를 기다린 후 취소/timeout을 반환하여 승격을 막는다. native 완료 자체의 hard timeout/강제 종료 보장은 아니다.

최종 코드에서 안전성20/20·native 호출 순서12/12, 정리 후 같은 프로세스 재시도360장, 정상 spectrum/일반 자막360장·12초·전체PTS·자막/합성·PCM/AAC·독립DFT·gate 회귀, 기존 읽기 도구의 오디오0–12초 확인이 새 실행으로 통과했다(exit0). 실패/취소19개 기존 출력 SHA 보존, 기록된 현재 작업 temp18개 정리 및 worker drain 확인. 성공 승격 뒤 취소는 rollback 없이 completed다. Engine Debug만 단일 job으로 빌드, 관리 약18.617/20GiB, 이전 증거/앱/캐시 정리 없음.

**OWNER MANUAL DEFERRED — NOT PASS.** 일반/image/pure-audio/다중 spectrum export·공개 이미지·schema는 그대로이며 Stage4 전체/preview-export parity·full Release·장시간·실제 sandbox 철회 수락은 미완료다. 기준 HEAD/upstream/live remote `e96b8570d286d7fb82258907e81c971cbd39dd62`, main/복구 refs/사용자 파일 보존, index 비어 있음. staging/commit/push 없음. 다음 권고는 **SP-4A-05 safety checkpoint audit**다. [생명주기·두 재현 실패·최종 행렬·정확한 파일·native 한계](diagnostics/SP-4A-04-EXPORT-SAFETY.md)

**2026-11-06 · SP-4A-02 — PUBLICATION READY (감사·미커밋).** SP-4A-01 후보8개와 최종 미디어/증거 해시를 대조했고 내부 첫 slice의 중대한 게시 차단 결함을 발견하지 않았다. 엔진/검사5개는 변경하지 않고 문서3개만 갱신했다. Y/Cb/Cr 오차0은 pre-encode 합성 비교이며 lossless H.264/AAC나 독립 renderer 검증이 아니다. 이전 통합2회·DFT·취소/출력보호 PASS를 재사용했고 이번에는 기존 MP4의360 PTS, 오디오0–12초/576,000 stereo sample frames, 대표 spectrum색 영역을 읽기 전용 CLI로 보강 확인했다(exit0; sandbox decoder 시작 실패2회 exit133 보존). 새 export·앱/엔진 빌드 없음.

일반 spectrum·이미지-spectrum·pure audio·다중 spectrum·공개 이미지·schema gate 유지. **OWNER MANUAL DEFERRED — NOT PASS**, full Release·장시간·실제 sandbox 철회·최종 preview/export parity·Stage4 전체 수락은 미완료다. 관리 약18.430/20GiB, 기준 HEAD/upstream/live remote `a8abc89a3433918478ce3957bc71c802e2f63d7b`와 main/복구 refs/기존 파일 보존, index 비어 있음. staging/commit/push 없음. 다음 개발 권고는 기존12초 경로의 finalizing 취소/source 교체/fault matrix 강화다. [감사·비교 단계·게시 범위·한계](diagnostics/SP-4A-01-SPECTRUM-EXPORT.md#sp-4a-02--게시-체크포인트-감사-2026-11-06)

**2026-11-06 · SP-4A-01 — FIRST SPECTRUM MP4 PASS (생성 fixture 자동 검증·미커밋).** 기존 SubtitleExporter의 reader/420v compositor/writer에 한 프레임씩 비동기 spectrum 준비를 연결했다. 별도 encoder·preview clock 없이 공통 FFT/renderer와 immutable source snapshot을 사용한다. `#if DEBUG` internal API + 명시적 gate/시험 deadline만 허용하며 일반 spectrum rejection·이미지 제한·schema는 유지한다.

생성 FHD30 H.264/AAC MP4 12초/360장 전체 decode·정확한 k/30 PTS·영상 표식 통과. video→spectrum→subtitle의 별도 Y/CbCr 수식 비교 오차0, 자막120/240 경계 포함 검증. sourceIn1초 PCM 오차0, AAC frame RMS 최대0.00197914, 독립 DFT220/440/880Hz 및 slow/fast/medium 펄스8/16/12 통과. 취소·쓰기 실패·원본 소실·시간 제한·승격 충돌에서 기존 출력/원본 보호 및 현재 temp5개 정리, worker drain, 일반 자막 export360장 회귀 통과. Engine Debug·최종 CLI·통합·독립 DFT exit0; 중간 fixture/하네스 실패는 보존했다.

**OWNER MANUAL DEFERRED — NOT PASS.** Stage4 전체/공개 export·이미지-spectrum·pure-audio·다중 spectrum·full Release·장기/모든 native I/O 취소 타이밍은 미검증이다. 기존 Stage3C-2 preview 한계도 남는다. 시작18.160GiB → 최종 약18.43/20GiB, 기존 산출물 삭제 없음. HEAD/upstream/live remote `a8abc89a3433918478ce3957bc71c802e2f63d7b`, main 불변, index 비어 있음. 소유자 데이터 수정·공개 활성화·staging/commit/push 없음. 다음 권고는 **SP-4A-02 export checkpoint audit**다. [구조·정확한 파일·생성 미디어·검사/중간 실패·재현·자원·한계](diagnostics/SP-4A-01-SPECTRUM-EXPORT.md)

**2026-11-06 - SP-3C2-40: STAGE 4 CONTRACT READY**

영상 backed·lead-in·공백·꼬리·pure-audio, 내부 image-covered/gap/tail·mixed, 선택 계보/시간 매핑, proactive renewal은 구현 및 해당 자동 fixture 검증 범위다. 과거 영상·공백·꼬리 제한 수락만 유지하고 **최신 통합판 OWNER MANUAL DEFERRED**다. 전체 Stage 3C-2 수락은 미완료다.

시작/전환 UX 공백, 느린 access validation starvation, large-catalog, 간헐 image player-layer, full Release app, 장기/물리 timing은 남는다. B는 Stage4 설계·제한된 prototype의 일괄 차단 사유가 아니다. 공유 매핑 C가 새로 발견되면 수정 전 구현 진행을 재평가한다. 최종 release 수락과 prototype 진입은 다르다.

이번 시작 관리량19,041,872KiB(약18.160GiB), 여유 약1.840GiB. 문서 수 KiB만 추가하며 새 빌드/대형 산출물/삭제 없음. 미래 작업은 기존 fixture/엔진 바이너리 재사용, 단일 job, 제한 APFS scratch와 build/cache 포함 사전 예산,20GiB 도달 전 중지 계획이 필요하다. 용량 부족 시 별도 승인된 좁은 cache 정리 또는 증거 의존성 검토 후 artifact 재배치/이미지 관리안을 제안하되 이번에 수행하지 않는다.

다음 권고는 이 체크포인트의 검토·게시 작업을 별도 지시로 수행한 뒤, 본 계약의 비동기 frame bridge/메모리 계수를 구체화한 첫 Stage4 구현 작업이다. 이번에 export rejection을 제거하거나 export를 구현하지 않았다.


[SP-3C2-40: boundary audit and proposed export contract](diagnostics/SP-3C2-40-EXPORT-CONTRACT.md)

**2026-11-06 · SP-3C2-35 — PUBLICATION READY (감사·미커밋).** 선행 갱신과 Debug trace를 전체8개 후보로 감사했고 중대한 게시 차단 결함을 발견하지 않았다. 소스5개·앱·증거 지문을 확인했으며 이번 변경은 문서3개뿐이다. 아래 자동 결과는 SP-3C2-34 과거 실행이며 새 빌드/기능 테스트는 없다. TTL1초/선행100ms는 잠정 B 정책이고, 현재 유효 lease만 pending 중 유지한다. 실패는 MainActor 처리 시 즉시 철회하고 만료는 실행 가능한 tick에서 차단한다. trace는 Debug·명시적 기록,8,192개/2MiB 제한으로 보존 가능하며 다중 store/spectrum 상관·무오버헤드는 보장하지 않는다. 비교 미확인8개, 느린 검증 starvation, 과거 이미지 player-layer 간헐 문제·OS 철회·장기/물리 지연·전체 Release 앱 차단은 남는다. **OWNER MANUAL DEFERRED — NOT PASS.** Stage 3C-2 전체 수락과 Stage4 export 미완료. 관리 약19.48/20GiB, index 비어 있음, 삭제/staging/commit/push 없음. 다음 개발 권고는 공백/꼬리 경계3개 timing/분석 지연 진단이다. [계약·trace 경계·게시 감사](diagnostics/SP-3C2-28-IMAGE-SPECTRUM.md#sp-3c2-35--선행-갱신debug-trace-게시-감사-2026-11-06)

**2026-11-06 · SP-3C2-34 — PROACTIVE RENEWAL PASS (자동 검증·미커밋).** 게시 HEAD/upstream `844f2e485c0873bd875a0ae865cf0e151cb166e3`. 승인된 잠정 TTL1초/선행100ms를 적용했다. 기존 lease는 갱신 pending 중에도 원래 만료 전까지 허용하며, 성공은 시작+1초 이전·동일 컨텍스트에서만 게시한다. 실패/무효화는 즉시 철회하고 worker는 취소 후 종료까지 슬롯을 유지한다. 시작 간격0.9초, 실패/만료 성공 뒤1초 제한은 교체·무효화에도 유지한다. 기존 Debug 계측 보존. 새 signed 재생135/135·픽셀40·자막1800/1800·FFT/layer1792/1800, 선행 갱신70회에서 접근 갱신에 의한 layer 제거0회. 초기5개와 공백/꼬리 경계3개 미확인 표본은 남는다. 계약19/19·접근16/16·합성 지연3/3·controller92/92·overlay58/58·eligibility32/32/gate-off3/3·오디오37/37·lead37/37·gap46/46·tail23/23, 보존 엔진 Debug/Release 새 실행39/39씩. 1.1초 지연의 starvation은 fail closed로 남으며 무공백/물리 scan-out/지속 접근을 보장하지 않는다. **OWNER MANUAL DEFERRED — NOT PASS.** 관리 약19.48/20GiB, index 비어 있음, 정리·staging/commit/push 없음. 다음은 선행 갱신 체크포인트 감사다. [정책·검증·실패 보존·남은 범위](diagnostics/SP-3C2-28-IMAGE-SPECTRUM.md#sp-3c2-34--선행-이미지-접근-갱신-2026-11-06)

**2026-11-06 · SP-3C2-29 — PUBLICATION READY (내부 체크포인트 감사·미커밋).** 전체8개 후보 감사에서 중대한 차단 결함을 발견하지 않았다. 이번에는 문서3개와 읽기 전용 증거 재집계만 수행했으며 아래 자동 PASS는 SP-3C2-28 과거 실행이다. “빈17개”는 비교 미확인 표본으로 정정한다: 초기 접근 차단5, FFT 일치/layer 불일치3, 결과 비교 미확인2, currentFrame 없는 valid-access7. 비초기12개의 정확한 원인·실제 layer 존재는 로그로 확정할 수 없고 UX 위험이 남는다. 1초는 시작 시각 기준 TTL이며 작업 timeout이 아니다. 느린 catalog는 starvation, 외부 철회는 다음 검사까지 지연될 수 있다. **OWNER MANUAL DEFERRED — NOT PASS.** Stage 3C-2 전체 수락과 Stage4 export는 미완료다. 관리 약18.52/20GiB, index 비어 있음, 소스5개·제외4개·복구 refs·과거 실패 보존. staging/commit/push 없음. 다음은 lease/tick/outcome/layer 연결 관찰을 통한 비초기12개 원인 검증이다. [17개 상세 분류·정책·게시 감사](diagnostics/SP-3C2-28-IMAGE-SPECTRUM.md#sp-3c2-29-체크포인트-감사-2026-11-06)

**2026-11-06 · SP-3C2-28 — IMAGE SPECTRUM INTEGRATION PASS (자동 검증·미커밋).** 기준 HEAD/upstream/live remote `6c358e650f528b9264186c769875cce2da4b4951`, main 불변. 게시된 설치 계약에 현재 원본 접근의1초 bounded lease를 추가했다. MainActor 조회는 파일 I/O 없이 한 worker만 요청하고, 취소된 worker도 종료까지 슬롯을 유지한다. 기존 이미지 전체 probe/scope·실제 읽기를 재사용하며 item/composition/session/generation/access revision/serial을 완료 뒤 재검사한다. pending/실패/만료는 비운다. 이미지/영상 covered 구간은 확인된 합성 출력 PTS를 유지하고, 시각 클립 없는 공백/꼬리만 활성 선택 오디오와 유효 item time을 쓴다. 설치 성공도 lease도 영구 파일 접근 보장이 아니다.

제품 변경 전 signed 기준 측정에서 이미지 covered FFT/레이어는 작동하고 공백/꼬리는0표본이었다. 최종 signed 자동 검사155/155(다섯 재생 fixture139 + 접근16), 원본 중앙 픽셀40지점·자막1800표본, FFT/레이어1783/1800 일치. 비교 미확인17표본을 보존했으며(원인 확정 범위는 SP-3C2-29 감사 참조) 무공백/물리 scan-out을 주장하지 않는다. 녹색 이미지→검정 공백→빨간 이미지/영상, seek/resume/end/replay·선택 해제·오디오 split/trim/move, 이미지 소실·POSIX 읽기 실패·WAV 소실·relink·늦은 item/project 교체를 검사했다. 같은 제품 로직 signed 회귀 controller92/92·overlay58/58·설치32/32/gate-off3/3·오디오37/37·선행37/37·영상공백46/46·꼬리23/23; 기존 엔진 바이너리로 이번 실행한 Debug/Release 각각39/39·이미지2/2, 종료모두0. 새 앱 경로의 전체 Release·대형 catalog 재검증 성능·장기/물리 지연·Stage 3C-2 전체 수락은 미완료다. **OWNER MANUAL DEFERRED — NOT PASS.** 관리18.52/20 GiB, 기존 앱/증거/미추적4개/복구 refs 보존, index비어 있음. 공개 이미지·export·schema·소유자 데이터 변경·staging/commit/push 없음. 다음 제안은 통합 체크포인트 감사다. [계약·기준/최종 측정·빈 표본·중간 실패·검증 경계](diagnostics/SP-3C2-28-IMAGE-SPECTRUM.md)

**2026-11-06 · SP-3C2-26 — PUBLICATION READY (감사·미커밋).** SP-3C2-25의 설치 검증 계약·생명주기·실제 8개 후보와 보존된 source/app/시험 증거를 대조했고 중대한 차단 결함을 발견하지 않았다. 이번은 문서 3개 갱신과 읽기 전용 감사이며 빌드/기능 재실행은 없다. 아래32/32(대기12 포함)·3/3·92/92·58/58·엔진39/39씩·이미지2/2는 SP-3C2-25 과거 실행이다. 설치 검증은 현재 원본 접근을 보장하지 않는다. 다음 통합에는 이미지 원본의 비동기 접근 확인과 선택 오디오 기존 검증, 완료 후 현재 설치 컨텍스트 재확인이 필요하다. **OWNER MANUAL DEFERRED — NOT PASS.** 기준 HEAD/upstream/live remote `1c61df249468af09a7e90daf82c8e510e9a06480`, main/원격 HEAD 불변. 관리17.62/20 GiB, index 비어 있음, 기존 미추적4개·복구 refs·앱/증거 보존. 이미지 fallback/공개 활성화·export·schema·소유자 데이터 수정·staging/commit/push 없음. 정확한 8개 파일 SHA-256/mode는 이번 최종 보고의 매니페스트를 따른다. [소유권·경쟁 조건·접근 한계·게시 감사](diagnostics/SP-3C2-25-IMAGE-ELIGIBILITY.md#sp-3c2-26-체크포인트-감사-2026-11-06)

**2026-11-06 · SP-3C2-25 — IMAGE ELIGIBILITY CONTRACT PASS (자동 검증·미커밋).** SP-3C2-22 게시 후 기준 HEAD/upstream/live remote는 `1c61df249468af09a7e90daf82c8e510e9a06480`, main은 `44943eadabdf5a37d5242d614e7279813126dfde`다. SP-3C2-23/24에서 확인한 설치 소유권/API 차단을 해소했다. `ProjectStore`가 정확한 item/composition·project session·generation·access revision에 묶인 비공개 증거를 만들고 읽기 전용 상태를 제공한다. 전체 이미지 검사와 초기 seek 완료 뒤에만 설치 검증을 인정하고 재빌드·실패·교체·알려진 접근 변경을 거부한다. 같은 계획의 일반 seek는 증거를 유지한다. **설치 당시 검증이며 현재 파일 접근 가능성 보장이 아니다.** 미래 fallback의 live-access 조건은 별도 검증이 필요하다. controller의 이미지 제외는 유지한다.

최종 signed Debug 계약32/32(대기 단언 포함), runtime gate-off3/3, controller92/92, overlay58/58; 보존 엔진 Debug/Release 각각39/39·이미지 Debug2/2, 종료 코드 모두0. 새 계약의 Release 앱 실행·broad Release 빌드는 하지 않았다. 관리 할당량17.62/20 GiB(증가0.36), 기존 앱·증거·미추적4개·복구 refs 보존. **OWNER MANUAL DEFERRED — NOT PASS.** 이미지 fallback·공개 이미지·spectrum export·schema·소유자 데이터 변경·staging/commit/push 없음. 다음 제안은 이 계약의 체크포인트 감사 후 이미지 통합에서 필요한 live-access/오디오 시각 조건을 별도 검증하는 것이다. [계약·상태표·전환·검증 경계](diagnostics/SP-3C2-25-IMAGE-ELIGIBILITY.md)

이 절이 작업·상태 목록의 정본이다. 다른 문서의 요약은 이 절을 가리킨다. 아래 1–7절의 단계 구성·완료 기준은 여전히 제안(P-001)이며, 이 체크리스트에 적은 소유자 결정이 그 단계 구성 전체나 완료 기준을 승인하지 않는다. 짧은 인계 요약은 [HANDOFF.md](HANDOFF.md).

**표시:** ✅ 적은 범위 안에서 완료 · ⏳ 일부 구현·조사했지만 해결되지 않음 · ➡️ 시작하지 않음(결정 대기 포함). ⏳는 지금 에이전트가 작업 중이라는 뜻이 아니다.

**출처 표시:** [R] 원 brief 요구사항([PRODUCT.md](PRODUCT.md) §5) · [D] 확정 결정([DECISIONS.md](DECISIONS.md) §1) · [A] 작업 승인(§2.1) · [구현] 코드·커밋으로 확인한 사실 · [제안] 미승인 제안(P-, 리뷰어 권고 포함) · [선택] 첫 릴리스 요구사항이 아닌 후보 · [조건부] 개인 사용 성공 뒤에만.

**기준:** 자막 작업은 브랜치 `feature/subtitles`(첫 자막 기능 로컬 커밋 `04d4b58`(엔진)·`c36923e`(앱)·`81fda71`(조사 시험)·문서 커밋, 푸시하지 않음). 이전 기준 `backup/2026-10-11-editor-work`(`51cef3c`), `main`은 `44943ea` 그대로. 프로젝트 형식: `main`·이전 브랜치 5(형식 1–4 읽기, D-023), `feature/subtitles` 6(자막, 자막이 없으면 5로 씀, D-035). 검증 경계: 자동 검사는 이 Mac 한 대·짧은 생성 fixture, 소유자 확인은 소유자가 보고한 정성 관찰이며 둘을 섞지 않는다.

**2026-11-06 · SP-3C2-21 — PUBLICATION READY (감사·게시 준비, 미커밋).** SP-3C2-20의 네 Swift 파일과 ROADMAP/HANDOFF 전체 변경을 published HEAD `d2e1e7c2ed61d07913e41d5a69feb8b7dbea0f54`에 대조했다. branch `feature/subtitles`, 로컬 upstream·실제 원격도 같은 값이고 main/원격 HEAD는 `44943eadabdf5a37d5242d614e7279813126dfde`다. 감사 범위의 중대한 정확성·데이터 안전 차단 결함은 발견하지 않았다. **AUTOMATED PASS / OWNER MANUAL DEFERRED — NOT PASS.** Stage 3C-2 전체 또는 전체 Release 앱의 통과가 아니다.

- **코드/소스 안전:** 기존 재생 중 AVPlayerItem의 numeric·epoch 0·범위 내 시각과 선택 활성 계보를 사용한다. 영상이 없는 경우 `firstVideoFrame = Int.max`는 모든 요청에 계보 필터를 적용하는 경계값이며 시계·길이 값이 아니다. 가짜 영상/carrier·독립 시계·duration 정책·schema·export 변경은 없다. 첫 영상부터 기존 확인된 출력 시각 경로를 유지한다. 프로젝트 갱신은 session revision을 올리고 요청/보관 결과를 무효화하며, 취소된 요청도 종료 전달까지 8개 슬롯에 포함한다. 보관 8개/16 MiB, lookahead 2프레임과 원본 identity/읽기 검증을 유지한다. Debug 주입은 `.itemMissing`이고 구성된 playbackTimeline이 없는 합성 검사에만 허용된다. 실제 미디어 오류를 주입값으로 바꾸지 않으며, 지연 뒤 epoch/revision 검사를 다시 한다.
- **증거 재사용과 대응:** 아래 SP-3C2-20 수치는 모두 이전 실행이다. `final-fingerprints.json`의 당시 여섯 파일·서명 앱 구성 파일·프로젝트 fixture 해시가 감사 시작 시 모두 일치했고 strict 서명도 확인했다. 최종 controller 검사와 앞선 동일 제품 소스의 pure-audio/호환 회귀를 구별했다. 이번에는 저장 로그·TSV 판정, 해시·서명·소스·문서 검사를 수행했으며 기능 테스트·앱 실행·엔진 실행·빌드는 하지 않았다. 이후 이 두 문서만 감사 기록으로 갱신했으므로 SP-3C2-20의 문서 지문은 과거 기록이며 게시 지문은 SP-3C2-21 최종 매니페스트를 따른다.
- **증거 경계:** signed-app 검사는 창 표시 상태·검정 NSView 배경 속성·영상 트랙 부재·스펙트럼 CALayer 내용과 계산 결과의 동일성을 확인한 자동 단언이다. 화면 전체 픽셀 readback이나 물리적 scan-out·스피커 청취 수락으로 확대하지 않는다. PCM 768,000바이트 일치, 원본 프레임 매핑, 동일 알고리즘의 FFT 대역 비교, 엔진 회귀와 소유자 관찰은 별개다. 편집 fixture는 리플 보호 규칙을 유지한 채 오버레이를 제거하고 편집 후 복원했으며, 왼쪽 `frame+10`·오른쪽 `frame+30`, 170..<180 조각 공백을 검사했다. 변경 전/중간 실패와 기존 경계 빈 표본·약한 재개 깜빡임·원인 미확인 이미지 레이어 실패는 보존한다.
- **게시/자원:** 후보는 네 Swift 파일과 ROADMAP/HANDOFF 총 6개, 모두 일반 파일·Git mode 100644이며 정확한 전체 SHA-256·목적은 SP-3C2-21 최종 보고에 기록한다. 무관한 추적 변경·바이너리·개인 경로/자격 증명 패턴·schema 변경 없음. index는 계속 비어 있으며 기존 미추적 파일 4개와 복구 참조를 보존한다. `du -skx` 재측정은 app 9,413,852 + experiments 1,683,992 + 전용 개발 출력 7,005,508 = 18,103,352 KiB(약17.26/20 GiB, 여유 약2.74 GiB; 중첩 mount 중복 제외). 캐시·앱·미디어·프로젝트·raw 로그·APFS 이미지는 보존하고 게시에서 제외한다. staging/commit/push·제품 기능/소유자 데이터 변경·공개 이미지 활성화 없음. 남은 통합·이미지 공백/꼬리·export·Release·장기/물리적 지연 제한과 다음 개발 제안은 아래 SP-3C2-20 기록 그대로다.

**2026-11-06 · SP-3C2-20 — PURE AUDIO PREVIEW PASS (자동 검증, 미커밋).** 영상·이미지 클립이 없는 30 fps·12초 선택 WAV 프로젝트의 연속 스펙트럼 프리뷰를 지원했다. **OWNER MANUAL DEFERRED — NOT PASS.** 기준 HEAD/upstream/live remote는 `d2e1e7c2ed61d07913e41d5a69feb8b7dbea0f54`, main은 `44943eadabdf5a37d5242d614e7279813126dfde`다. 아래 과거 체크포인트의 오디오 전용 미지원 표시는 당시 상태다.

- **변경 전 확인:** 보존된 signed 앱에서 오디오 전용 프로젝트 열기·AVPlayer 진행·34개 자막/탐색/재시작 행은 정상이었지만 재생 스펙트럼 프레임은 없었다. 기존 planner는 비어 있는 영상 트랙을 제거하고 앱은 videoComposition을 연결하지 않는다. 원래 검정 NSView 배경을 사용하며 새 영상·carrier·독립 시계나 프로젝트 길이 정책이 필요하지 않았다. 컴포지션 0–4초 PCM 768,000바이트가 WAV 원본 1–5초와 일치했다(스피커 음향 측정은 아님).
- **구현:** 기존 AVPlayerItem 유효 시각 fallback의 영상 존재 제한을 제거했다. 영상이 없으면 전체 구간에서 각 스펙트럼의 활성 선택 계보를 검사한다. 영상 복귀 시 확인된 출력 프레임 경로, 내부 이미지 제외, 원본 identity/읽기 검사, epoch/revision/serial, 취소·stale 보호, 요청 8개·결과 8개·16 MiB 상한을 유지한다. 제품 composition·duration·export·schema 변경 없음.
- **이번 실행 증거:** `app/selftest-work/sp3c220/`의 final-audio-2에서 signed Debug **37/37**: 영상 트랙/합성 없음·검정 배경·10개 표본의 모든 FFT 대역/레이어 내용 일치·2/9초 정지·10→3→11초 탐색·재개·종료/재시작·선택 해제·교체, 분할/트림/이동 후 추가 두 표본과 선택 계보 공백. 원본 읽기와 명시적 매핑을 별도로 계산하지만 FFT 알고리즘은 같은 구현이다. 자막 34/34, missing-lineage fixture의 자막 34행과 무관한 오디오 재생 중 spectrumFrame -1 확인. 실제 화면 scan-out이나 물리적 소리/화면 지연 측정은 아니다.
- **호환 회귀:** 최종 signed 컨트롤러 92/92(오디오 전용 합성 fixture의 캐시·취소·stale 보호 포함). 같은 제품 소스의 signed 앱에서 영상 구간 7/7, 선행 37/37·픽셀 9/9, 공백 46/46·픽셀 9/9, 꼬리 23/23, 영상 전용 19/19, 정지 오버레이 58/58. 집중 엔진은 기존 유효 바이너리로 이번에 재실행: SpectrumModelTests 12 + SpectrumFrameCoordinatorTests 13 + SpectrumSchedulerTests 14 = Debug/Release 각각 39/39, 이미지 프리뷰 Debug 2/2, 종료 코드 모두 0. 엔진 source/test 변경 없음, broad Release/prototype/WMO 컴파일 없음.
- **중간 실패 보존:** 테스트 초기화 컴파일 오류를 수정했다. 동일 박자 FFT가 달라야 한다는 잘못된 단언을 서로 다른 박자 표본으로 고쳤다. 편집 fixture의 최초 리플 트림은 걸쳐 있는 오버레이 보호 규칙으로 거부됐다. fixture에서 오버레이를 제거하고 편집 후 선택 스펙트럼을 복원해 검사했으며 제품 편집 규칙은 변경하지 않았다. 오디오 전용→영상 합성 fixture 전환에서 세션 초기화를 빠뜨린 검사 오류도 수정해 컨트롤러 92/92를 재확인했다. 실패 로그와 앞선 앱/fixture는 보존한다.
- **산출물/안전:** 새 빌드는 단일 job·2 GiB 상한 내부 APFS sparse volume에 격리했다. 최종 관리 할당량 app 9,413,848 KiB + experiments 1,683,992 KiB + 전용 개발 출력 7,005,508 KiB = 18,103,348 KiB(약 17.26 GiB), 20 GiB 중 약 2.74 GiB 여유. 기존 증거/앱·미추적 파일 4개·복구 참조 유지. index 비어 있음, staging/commit/push·소유자 데이터 변경·공개 이미지 활성화 없음. `git diff --check`와 문서 링크 검사 통과. 최종 소스/앱/fixture 지문은 제외된 증거 폴더의 `final-fingerprints.json`에 기록한다.
- **한계/다음:** 내부 이미지 프리뷰 공백·꼬리, Stage 3C-2 통합 수락, spectrum MP4 export, 전체 Release prototype 컴파일, 장시간 timing/drop-rate 및 물리적 A/V 지연은 남는다. 과거 공백/꼬리 경계 빈 표본, 재개 깜빡임과 간헐 이미지 레이어 문제도 미해결이다. 전체 Stage 3C-2 완료가 아니다. 다음 제안은 별도 지시로 내부 이미지 프리뷰의 선택 오디오 공백·꼬리 범위를 검토하는 것이다. 공개 이미지 게이트는 유지한다.

**2026-11-06 · SP-3C2-18 — PUBLICATION READY (게시 준비, 미커밋).** SP-3C2-16의 첫 영상 전 선택 오디오 스펙트럼을 소스·보존 증거로 감사했다. 기준은 `feature/subtitles` HEAD/로컬 upstream/실제 원격 `3990f2804ce0cc59cee254b46c1b5a373badddd8`, main/원격 HEAD `44943eadabdf5a37d5242d614e7279813126dfde`이며 lead-in 범위의 중대한 차단 결함은 발견하지 않았다. 아래 과거 체크포인트는 당시 상태다.

- **AUTOMATED PASS / OWNER MANUAL DEFERRED.** 소유자가 이번 선행 구간의 수동 수락을 명시적으로 유예하고 자동 검증 우선 감사를 승인했다. 0–4초 검정 배경의 선택 WAV 스펙트럼, 4초 첫 영상 복귀, 소스 프레임·FFT 대조, 정지·탐색·재개·종료·재시작과 집중 Debug/Release 회귀는 자동 증거다. 소유자 육안·청취 PASS가 아니다.
- **소스 감사.** `PlaybackSpectrumController.swift`는 실제 재생 중인 항목의 유효한 CMTime(30 fps, epoch 0, 범위 내)을 사용하며 첫 영상부터 요청/표시 영상 프레임 일치 경로로 돌아간다. 선행 구간은 보이는 스펙트럼의 선택 계보가 활성일 때만 허용하고 항목별 요청도 같은 계보로 제한한다. 기존 원본 identity/읽기 검증과 프로젝트 접근 소유권, epoch/revision/serial 취소·오래된 결과 차단, 요청 8개·결과 8개·16 MiB·미리 읽기 2프레임 상한을 유지한다. 독립 재생 시계·다른 오디오 분석·스키마 변경은 없다. `OnTheFrameApp.swift`는 검사 진입점, `PreviewSelfTest.swift`는 선행/공백/꼬리 fixture 분기, `SpectrumPlaybackSelfTest.swift`는 경계·무관한 계보·다중 소스 검사를 추가했다. 영상·자막 경로와 내부 이미지 제외 조건은 유지된다.
- **재사용 증거(새 기능 테스트 아님).** `app/selftest-work/sp3c216-4hzXoY/`의 SP-3C2-16 기록: signed Debug 선행 37/37, 선행 영상 픽셀 9/9, 영상 구간 7/7, 내부 공백 46/46·픽셀 9/9, 꼬리 23/23, 영상 전용 19/19, 자막 경계 34/34, 컨트롤러 89/89, 정지 오버레이 58/58. 엔진 `SpectrumModelTests` 12 + `SpectrumFrameCoordinatorTests` 13 + `SpectrumSchedulerTests` 14 = Debug/집중 Release 각각 39/39, `ProductImagePreviewTests` Debug 2/2, 당시 종료 코드 모두 0. 엔진은 당시 기존 바이너리로 실행했으며 이번에도 새 빌드 증거로 바꾸지 않는다.
- **최종 소스/fixture 대응.** 구현 보고와 signed/final build 로그, 현재 네 파일 및 검사 본문을 대조했다. 최종 빌드는 수정된 두 self-test 파일을 재컴파일했고 최종 lead/gap/tail/controller 결과를 남겼다. 다른 회귀는 앞선 signed 빌드 결과를 재사용한다(최종 변경은 해당 fixture/검사 보정이며 제품 timing 구현은 동일). 엔진 소스/시험은 변경되지 않았다. final-lead fixture는 영상 120..<360, WAV 0..<360·sourceIn 30·선택 sourceKey 일치다. 9개 FFT 표본은 별도 원본 읽기와 명시적 +30 매핑을 사용하지만 동일 FFT 구현을 쓰므로 독립 FFT 알고리즘 검증은 아니다. PCM 768,000바이트는 원본 1–5초와 일치했고 4.001019초에 첫 영상 원본 프레임 0을 확인했다. 이번 감사는 저장 로그 판정 재실행·fixture 대조·strict 서명 확인·정적 검사만 수행했으며 앱/엔진 기능 실행이나 재빌드는 하지 않았다.
- **OWNER ACCEPTED PREVIOUS SLICES.** 영상 재생 구간(SP-3C2-05), 마지막 영상 뒤 오디오 꼬리(SP-3C2-09), 영상 사이 공백(SP-3C2-13)의 기존 소유자 수락을 유지한다. 선행 구간에 확대 적용하지 않는다.
- **STILL INCOMPLETE.** 순수 오디오 프로젝트, 내부 이미지 프리뷰 공백·꼬리, Stage 3C-2 통합 수락, 스펙트럼 MP4 내보내기, 전체 Release prototype 컴파일, 장시간 타이밍·누락률 검증, 물리적 소리·화면 지연 측정은 남아 있다. Stage 3C-2 전체 완료가 아니다. 공백 4.006695초 빈 레이어→4.010255초 프레임 120, 꼬리 8.003941초 빈 표본, 6초 재개 시 소유자가 수용한 약한 깜빡임과 이미지 원본 복귀 직후 과거 간헐 레이어 실패는 원인 미확인 상태로 보존한다.
- **게시 범위/안전.** 후보는 위 네 Swift 파일과 `docs/ROADMAP.md`, `docs/HANDOFF.md` 총 6개, 모두 Git mode `100644`다. 정확한 전체 파일 SHA-256은 SP-3C2-18 최종 보고의 매니페스트에 고정한다. index는 비어 있고 기존 미추적 `.DS_Store` 3개와 `.claude/settings.json`, 복구 참조·생성 프로젝트·미디어·앱·로그를 보존했다. 개인 경로/자격 증명 패턴·바이너리·무관한 변경 검사를 수행하며 생성 증거는 게시하지 않는다. 관리 할당량은 `du -skx` 기준 app 9,139,928 KiB + experiments 1,683,992 KiB + 전용 개발 출력 6,562,112 KiB = 17,386,032 KiB(16.58 GiB), 20 GiB 이하(중첩 APFS mount 중복 계산 제외). 새 컴파일·정리·staging·commit·push·소유자 데이터 수정·export 구현·공개 이미지 활성화 없음.
- **다음 개발 제안(별도 지시 필요).** 순수 오디오 프로젝트의 프리뷰 구성·종료/재시작 계약을 먼저 확인하고 선택 소스 스펙트럼 지원을 별도 한정 slice로 진행한다. 선행 구간 owner 수락은 유예 상태로 남긴다.

**2026-11-04 · SP-3C2-14.** 선택 오디오의 연속 스펙트럼 프리뷰는 영상 재생 구간(SP-3C2-05), 마지막 영상 뒤 오디오 꼬리(SP-3C2-09), 영상 사이 공백과 다음 영상으로의 복귀(SP-3C2-13)에서 각각 소유자 수동 확인을 마쳤다.

- **소유자 관찰(SP-3C2-13).** 0–4초 영상 A, 4–8초 검정, 8–12초 영상 B에서 선택한 WAV의 박자에 맞춰 막대가 움직였다. 4초·8초에 자막이 바뀌었고, 보통 속도로 4초 경계를 지날 때 눈에 띄는 끊김이나 8초에 남은 이전 영상은 보이지 않았다. 6초 정지·재개 때 소리와 막대가 함께 멎고 재개됐다. 재개 순간 약간 깜빡인 느낌은 소유자가 수용했으며 원인은 미확인이다. 9초 → 5초 → 2초 → 10초 탐색에서 각 위치의 영상·자막·막대를 확인했고, 12초 종료 후 처음부터 다시 재생됐다.
- **자동 관찰(SP-3C2-12).** 공백에서는 유효한 재생 항목 시각으로 선택 소스의 프레임을 구하고 다음 영상 시작부터 다시 영상 출력 시각을 확인한다. 4.006695초에는 막대 레이어가 비었고 4.010255초에는 올바른 프레임 120이 보였다. 8.002645초에 영상 B의 첫 픽셀을 확인했다. 3.9초·11.9초는 원본 WAV가 무음이고 모든 FFT 대역이 0이어서 막대가 없었다. 서명 Debug 공백 46/46, 픽셀 9/9, 자막 34/34, 꼬리 23/23, 영상 전용 19/19, 컨트롤러 85/85, 정지 오버레이 58/58, 집중 스펙트럼 Debug·Release 각각 39/39, 이미지 프리뷰 엔진 2/2. 이번 감사에서는 기존 결과를 대조했다.
- **SP-3C2-14 당시 남은 범위.** 순수 오디오 프로젝트, 첫 영상 전의 선택 오디오, 내부 이미지 프리뷰의 공백·꼬리, 스펙트럼 MP4 내보내기는 미지원이다. Stage 3C-2 전체 통합 검증, 장시간 타이밍·누락률, 물리적 오디오·화면 지연 정량 측정이 남아 있고 전체 Release 프로토타입 컴파일은 차단 상태다.

**2026-11-04 · SP-3C2-10.** 영상 프레임이 확인되는 구간(SP-3C2-05)과 마지막 영상 뒤로 선택한 오디오가 이어지는 구간(SP-3C2-09)은 구현과 소유자 시청·청취 확인을 마쳤다. Stage 3C-2는 부분 완료다.

- **소유자 관찰(SP-3C2-09).** 생성한 12초 프로젝트에서 0·4·8초에 느린·빠른·중간 박자 자막과 막대가 바뀌었다. 8초 영상 종료 경계에서 보통 속도로 볼 때 깜빡임을 보지 못했다. 9초 부근에서 정지하자 소리와 막대가 멎었고 재개하자 함께 움직였다. 11초 → 3초 → 11초 탐색 뒤에도 자막이 해당 위치에 맞았고 11초에서 재생하자 선택한 rhythm.wav의 중간 박자와 막대가 함께 이어졌다. 12초 끝에서 재생이 멎고 마지막 자막이 남았으며 재생을 누르자 처음부터 다시 시작했다.
- **자동 증거(SP-3C2-08).** 서명 앱 꼬리 23/23, 자막 경계 30/30, 컨트롤러 82/82, 정지 오버레이 58/58, 영상 프리뷰 19/19, 집중 스펙트럼 엔진 Debug·Release 각각 39/39, 이미지 프리뷰 엔진 2/2. 경계 검사에서 8.003941초에 막대가 없는 표본이 한 번 있었고 별도 WAV 대조 검사에서 8.016871초에 프레임 240을 확인했다. SP-3C2-10은 기존 결과를 감사했다.
- **SP-3C2-10 당시 남은 범위.** 순수 오디오 프로젝트, 영상 클립 사이 공백, 내부 이미지 프리뷰의 오디오 꼬리, 스펙트럼 MP4 내보내기는 미지원이다. 전체 Release prototype 컴파일은 차단돼 있고 물리적 소리·화면 지연 정량 측정과 장시간 타이밍·누락률 검증은 남아 있다.

**2026-11-04 · 스펙트럼 Stage 3C-2 첫 범위 완료 (SP-3C2-06).** 영상 출력 프레임을 확인할 수 있는 구간에서 선택한 오디오 계보의 연속 스펙트럼 프리뷰를 구현했다. SP-3C2-05에서 소유자가 12초 생성 WAV의 느린·빠른·중간 박자와 막대 움직임, 4초·8초 자막 전환, 정확한 6초 정지와 약 2초 뒤로 탐색 후 재개, 끝 표시와 재시작을 확인했다. 약 2초로 처음 탐색했을 때 도착 시각은 미확인이었고, 정확히 2초로 재검사해 느린 박자를 확인했다.

- **구현과 회귀.** AVPlayer 항목의 영상 출력 시각에 맞춰 기존 분석기를 사용한다. SP-3C2-03에서 두 번째·세 번째 자막이 사라졌던 문제는 영상 출력을 연결하거나 제거할 때 같은 항목의 자막 동기 레이어를 다시 바인딩해 수정했다. SP-3C2-04의 서명 앱에서 스펙트럼 켬·끔·영상 전용 각각 30/30, 컨트롤러 77/77, 정지 오버레이 58/58, 영상 프리뷰 19/19를 확인했다. 이전 집중 Release 스펙트럼은 59/59, Debug·집중 Release 자막 엔진은 각각 19/19였다.
- **실패 이력.** 초기 컨트롤러 13건 실패는 합성 검사와 실제 소스 검증을 분리해 복구했다. 이미지 fixture 경로를 바로잡아 이미지 프리뷰 2/2를 확인했다. 데이터 볼륨 컴파일 캐시가 관리 예산을 넘긴 뒤 승인된 37 GiB 캐시만 제거하고 내부 APFS 격리 전략으로 전환했다. 이미지 원본 복귀 직후 플레이어 레이어 검사 1회 실패 원인은 미해결이며 이전 단독 재검사는 71/71이었다.
- **SP-3C2-06 당시 남은 범위.** 오디오 전용 구간, 영상 끝 뒤 오디오 꼬리, 전체 Release prototype 컴파일, 장시간 타이밍·프레임 누락률, 물리적 오디오·화면 지연 정량 측정, Stage 4 스펙트럼 MP4 내보내기는 미완료다. 아래 날짜별 기록은 각 체크포인트 당시의 상태다.

**2026-11-03 IMG-CP-14F · 내부 체크포인트 PUBLICATION READY.** CP-14의 이동 원본 Undo 불일치와 CP-14R의 두 번째 읽기 실패는 각각 RELINK-05/06에서 수정됐고 두 원래 시퀀스를 다시 통과했다. Debug·Release 각각 51/51, 서명 앱 71/71, scope 12/12. 소유자 네이티브 재연결과 마우스 Undo/Redo는 이전 관찰이며 이번 캡처는 자동 검사다. 가용성은 프리뷰 재검증 때 갱신된다. 공개 게이트는 꺼져 있고 장기·외장 볼륨·OS 권한 변경은 미검증이다. [최종 감사와 24개 후보](diagnostics/IMG-CP-14F-FINAL-AUDIT.md)

**IMG-RELINK-06 · 두 번째 읽기 일관성 통과.** probe 직후 원본을 이동시킨 CP-14R 단언이 Debug·Release에서 모두 통과했다. 확인된 소실·권한 거부·교체만 해당 참조의 가용성을 낮추며, 같은 원본의 디코드·자원 오류와 확인 불가 상태는 프리뷰 오류로 남는다. 서명 앱에서 경고 행과 빈 표시 버퍼, 원본 복구 뒤 정상 행과 빨간 프레임을 확인했다. 두 차단 매니페스트는 이전 기록이며 게시 전 새 감사가 필요하다. [재현 및 검증](diagnostics/IMG-RELINK-06-SECOND-READ.md)

**IMG-CP-14R · 게시 보류.** 이전 CP-14의 이동 원본 Undo 불일치는 RELINK-05 수정 뒤 재감사에서 정상화됐다. 서명 앱 66/66, 원본별 scope 12/12이며 소유자 마우스 Undo/Redo 확인은 RELINK-03 수정판의 관찰이다. 가용성은 기존 프리뷰 재검증 시 갱신한다. 이번 Debug·Release 검사에서 probe 성공 직후부터 디코드 전까지 원본이 이동하면 디코드 실패 뒤에도 마지막 가용성이 true인 별도 결함을 재현했다. 공개 게이트는 꺼져 있다. 2048 px 초과·장기 세션·외장 볼륨·OS 권한은 미검증이며 자막·스펙트럼·WMO 진단 컴파일 차단, 스펙트럼 Stage 3C-2/4 미구현 상태를 유지한다. [재감사 결과와 새 후보 목록](diagnostics/IMG-CP-14R-RELINK-RE-AUDIT.md)

**2026-11-02 IMG-RELINK-05 · 이동 원본 Undo 일관성 통과.** 열린 세션에서 이동한 이미지의 원본 검증 결과를 현재 참조의 가용성과 Undo 복원 정보에 반영했다. 서명 앱에서 Undo의 누락 경고·빈 화면, Redo의 정상 행·교체 프레임, 원위치 복구 후 재검증을 확인했다. CP-14 매니페스트는 이전 차단 시점 기록이며 게시 전 최종 재감사가 필요하다. [재현·수정·검증 기록](diagnostics/IMG-RELINK-05-MOVED-SOURCE.md)

**2026-11-02 IMG-CP-14 · 게시 보류.** 내부 JPEG/PNG 재연결, 소유자 마우스 Undo/Redo, 프리뷰 전용 오류 분리 및 누락/교체 행 구분을 감사했다. 열 때부터 누락된 프로젝트는 통과했으나 열린 세션에서 원본이 이동한 뒤 Undo하면 프리뷰 오류와 일반 교체 행이 함께 남는다. 파랑 G=51은 원본 PNG와 일치하며 원래 임계값 실패를 보존했다. 공개 게이트는 꺼져 있고 고해상도·장기 세션·OS 권한 변화 및 스펙트럼 Stage 3C-2/4는 미검증 또는 미구현이다. [감사 결과와 증거 구분](diagnostics/IMG-CP-14-RELINK-AUDIT.md)

**2026-11-02 IMG-RELINK-04 · 미디어 목록.** 소유자가 IMG-RELINK-03 수정판에서 마우스 메뉴 Undo/Redo 동작을 확인했다. 재연결 성공 뒤에도 남던 주황 배경은 사용 가능한 이미지까지 경고 영역에 포함한 표시 오류였다. 이제 누락 행에는 재연결, 사용 가능한 이미지에는 교체를 표시한다. 생성 프로젝트로 누락·취소·실패·성공·Undo/Redo·저장 후 다시 열기의 목록 상태를 확인했다.

**2026-11-02 IMG-RELINK-03 · PARTIAL.** 재연결 메뉴 Undo의 마우스 이벤트 접근과 프리뷰 오류 소유권을 수정했다. 생성 PNG의 실제 파랑 G는 51이었다. 서명 앱 메뉴 항목 호출과 키 이벤트는 통과했고 소유자 마우스 재확인은 남았다. [수정 기록과 검증 절차](diagnostics/IMG-RELINK-03-CORRECTIONS.md)

**2026-11-01 IMG-RELINK-01 — GATED IMAGE RELINK PASS(미커밋, 자동 검증 한정):** [구현·검사·실패와 한계](diagnostics/IMG-RELINK-01-GATED-RELINK.md). 기준 HEAD/upstream `0f32bd6`, main `44943ea`. 내부 compile+runtime 게이트에서 JPEG/PNG 재연결 UI, 크기/방향 변경 확인, 독립 scope·원자적 후보 교체 및 undo/redo의 원본/bookmark 복원을 연결했다. UUID·편집·오디오/자막/spectrum 보존, 기존 엄격한 probe와 잠정 제한 유지.
- 새 Debug/Release 엔진 각각 **43 PASS·FAIL/SKIP0·exit0**, 정상 signed Debug 앱 **19 PASS·scope7/7·exit0**, 앞선 runtime-off **2 PASS**. 새 원본의 preview/짧은 export 반영 확인. Native Open 취소는 도구 자동 조작이며 소유자 패널 관찰이 아니다.
- 소유자는 이번 자동 검증만 선택했다. 실제 파일 선택·크기/방향 승인·재연결 후 새 프로세스 Save/Open은 **owner NOT RUN**. 중간 fixture 오류·launcher timeout과 후속 정상 실행 기록을 보존한다. 장기 반복 재연결의 session-owned scope 누적·외장 볼륨·OS 권한 변화·특정 GPU race는 미검증이다. 공개 활성화·형식9 schema·spectrum 구현 변경 없음. 아래 과거 미구현/감사 기록은 당시 상태로 보존한다.

**2026-11-01 IMG-CP-12 — 창·export 안전·bookmark 통합 체크포인트 감사(미커밋), PUBLICATION READY:** [감사·증거 경계](diagnostics/IMG-CP-12-CHECKPOINT-AUDIT.md), [정확한 11개 manifest](diagnostics/IMG-CP-12-MANIFEST.txt). 기준 HEAD/upstream `faace37`, main `44943ea`. 공개 이미지 지원 완료나 공개 활성화 승인이 아니다.
- 창: WINDOW-01의 정상 signed Debug 자동 표시·반복 Cmd+N·최소화/숨김 복구·dirty Cancel·단일 editor 검증을 재사용한다. 원래 zero-window 실패와 중간 실패는 보존한다. 개인 Spaces/외부 모니터 조합 전체를 검증한 것은 아니다.
- Export: EXPORT-02의 owner native import/save/reopen/export·영상/음성 수락에 더해 [SAFETY-01](diagnostics/IMG-SAFETY-01-SIGNED-EXPORT.md)의 실제 인코딩 약80% 취소·기존 출력 해시 보존, 대치 성공·패널 취소를 구별한다. signed 자동6개 시나리오와 GPU active/resources/admission 0, 세션 scope1→0 관측은 한정 증거이며 특정 GPU command in-flight race나 OS 전체 scope 수 증명이 아니다.
- Bookmark: [BOOKMARK-01](diagnostics/IMG-BOOKMARK-01-CROSS-PROCESS.md) owner A 종료→새 B에서 native Open/Save As 후 JPEG/PNG/WAV·자막·UUID/편집 값 및 bookmark 포함 파일 바이트 동일. 이후 발견한 fallback의 이전 세션 접근 빌림 결함은 독립 candidate scope 획득으로 보정했다. 수정 후 signed34 assertions 및 실제 정상 종료38 starts/38 stops/active0, FileGuard21 PASS를 재사용한다. owner A/B는 보정 전 앱이며 보정 후 native 패널 재실행으로 표시하지 않는다.
- 이번 감사: Debug 엔진37 PASS·FAIL/SKIP0·exit0. 보존된 최종 앱8개 파일 해시와 strict 서명·sandbox entitlement 재확인. 앱 재빌드·GUI·export·Release·GPU benchmark·blocked subtitle/spectrum/WMO diagnostic은 NOT RUN. 소스 변경 없이 문서/manifest만 정리했다.
- 남은 경계: provisional encoded8MiB·2048px·4,194,304pixels·추정 decode128MiB, upload64MiB·동시8층; 이미지 relink UI 없음(누락 경고의 과거 일반 preview 미지원 문구도 남음). subtitle/spectrum/WMO compiler blocker, Stage3C-2 미구현·Spectrum Stage4 export 미지원, 장기/외부·네트워크 volume/권한 회수/전원·디스크 장애·모든 GPU race 미검증. 내부 compile+runtime gate 유지. 아래 날짜별 미해결·PARTIAL/BLOCKED 기록은 당시 결과다.

**2026-11-01 IMG-WINDOW-01 — WINDOW AUTO-PRESENTATION PASS(미커밋, 격리 정상 Debug 한정):** [원인·중간 실패·최종 검증](diagnostics/IMG-WINDOW-01-AUTO-PRESENTATION.md). 실제 launch 완료 시 AppKit 창0 상태와 zero-window reopen callback을 확인했다. 기존 helper는 창 생성 없이 붙은 창만 표시하고, delegate는 기본 reopen까지 차단했다. 동일한 SwiftUI `main` scene action을 초기 launch에 한 번 연결하고 nil-window default reopen 및 실제 최소화 상태를 처리했다. 프로젝트 reset/저장 보호·renderer/export·schema 변경 없음.
- 최종 정상 signed Debug 빌드 exit0, 기존3GiB/4GiB·jobs1 한도 준수. trace/selftest/image gate 인자 없는 새 격리 실행과 같은 suite의 reset 없는 재실행에서 실제 편집기 visible/key/main·응답성 확인. 반복 Cmd+N·최소화/숨김 New Project·dirty 취소, 재열기 시 세션 유지와 main 편집기1개 확인. OS sharing helper를 중복 편집기로 세지 않는다.
- 새 Debug 엔진19 PASS, 정상 앱 FileGuard21 PASS(패널 대체와 실제 NSAlert), 영상 상태5/캡처14 PASS, 이미지 gate-on7/gate-off2 PASS. 실제 Save 패널은 표시 후 취소만 했으며 자동 저장 승인은 없다. Release·blocked subtitle/spectrum/WMO diagnostic 재시도 없음. 소유자 개인 환경의 다른 Spaces/외부 모니터·장기 복원 조합은 추가 확인 경계다. 아래 과거 자동 창 미해결 표시는 당시 결과로 유지한다.

**2026-10-31 IMG-CP-10 — 내부 이미지 export 체크포인트 감사(미커밋), PUBLICATION READY:** [감사·증거 분류](diagnostics/IMG-CP-10-CHECKPOINT-AUDIT.md), [정확한 19개 manifest](diagnostics/IMG-CP-10-MANIFEST.txt). 기준 HEAD/upstream `65c4d87`, main `44943ea`. 공개 이미지 지원 완료나 활성화 승인이 아니다.
- **구현/자동 검증:** 이미지 export는 기존 이중 내부 게이트 아래 공유 image-aware composition·자막 footprint·H.264/AAC Writer를 사용한다. 일반 영상 export 경로, 원본/대상 보호, 임시 출력 소유권, 취소/실패 처리를 보존한다. 이번 Debug 엔진 **69 PASS·FAIL/SKIP 0·exit 0**. 이미지/혼합 MP4·raw QA·음량/자막·legacy·spectrum 거부 포함. Release·정상 앱 재빌드·owner GUI 재검사는 이번 감사에서 NOT RUN이다.
- **이전 signed 앱/owner 수락:** [BUILD-03](diagnostics/IMG-BUILD-03-NORMAL-RECOVERY.md) 정상 Debug 빌드/앱 gate on·off 검증과 [EXPORT-02 한정 OWNER EXPORT ACCEPTANCE PASS](diagnostics/IMG-EXPORT-02-OWNER-ACCEPTANCE.md)를 구분한다. 소유자가 생성 JPEG/투명 PNG·음악·자막을 import하고 실제 native Save As·reopen·MP4 export·재생/청취했다. UUID·편집 값 유지, 두 출력150프레임/5초·전 PTS·Rec.709 SDR·AAC 확인, 표본 YUV 최소 PSNR54.24/40.54dB. 이번에는 보존 앱8개 해시와 서명/sandbox를 재확인했으며 GUI 수락을 재실행한 것은 아니다.
- **남은 경계:** owner 확인은 export 패널 취소까지이며 **인코딩 중 취소·대치 실패는 owner 미검증**(엔진 자동 검증과 구별). 장기 bookmark·제품 GPU cancellation/drain·자동 editor 창 생성, subtitle/spectrum diagnostic 및 WMO compiler blocker가 남는다. 자막 진단84개 원본 검사 본문 보존은 실행 PASS가 아니다. encoded8MiB·2048px·4,194,304pixels·추정 decode128MiB, upload64MiB·동시8층은 잠정 내부 제한이다. 공개 이미지 활성화·format9 schema 변경·Stage3C-2·Spectrum Stage4 export 구현 없음.
- 다음 제안: 자동 editor 창 표시 복구를 별도 bounded 작업으로 수행하고, 실제 앱 인코딩 취소/대치 실패와 scope/GPU drain 검증은 별도로 닫는다. 아래 날짜별 PARTIAL/BLOCKED는 당시 결과를 유지하며 현재 검증 범위는 이 요약과 후속 보고서를 따른다.

**2026-10-31 IMG-BUILD-03 — NORMAL APP BUILD PASS(미커밋):** [분류·빌드·실행·진단 제한](diagnostics/IMG-BUILD-03-NORMAL-RECOVERY.md). `SubtitleSelfTest`는 정상 실행 의존성이 없는 기존 개발 명령 전용이다. 첫 conditional만 별도 `OTF_SUBTITLE_DIAGNOSTICS`로 분리하고 원래 검사 본문·84개 ordered check 호출을 보존했다. 전용 target/scheme/build script와 기존 subtitle-test 명령을 연결했다.
- 정상 내부 Debug 빌드 **exit0 / 72.36초 / compiler peak 약1.27GB**. 최종 서명·sandbox entitlement 확인, 집중 엔진 **24 PASS·FAIL/SKIP0**. 실제 정상 signed 앱의 gated 이미지 MP47개·runtime-off2개 검사와 영상-only 상태5개/프레임14개 검사가 통과했다. 초기 시험 종료는 자체 export 완료 시트 때문에 막혔고, 격리 harness의 완료 시트 해제만 보정해 incremental build·정상 종료를 재검증했다. 제품 export 구현은 변경하지 않았다.
- **자막 diagnostic은 BLOCKED:** 실제 전용 빌드도 해당 primary에서 약3.24GB로 안전 중단(exit65), 원래 UI 검사는 NOT RUN이다. spectrum diagnostic/WMO host도 기존 blocker 그대로이며 재시도하지 않았다. 정상 앱 성공과 전체 진단 복구를 구별한다.
- Native Save/Open·bookmark·실제 음성·owner workflow·자동 창 생성·장기 GPU 취소/drain 검증은 남는다. 공개 이미지 활성화·spectrum export·형식9 schema 변경 없음. 다음 제품 작업 제안은 생성 fixture로 owner-operated native 패널을 포함한 signed 앱 image export 검증이다. 아래 IMG-EXPORT-01 PARTIAL은 그 작업 당시 기록이며 정상 빌드/제한된 앱 실행의 후속 보완은 이번 기록을 따른다.

**2026-10-31 IMG-EXPORT-01 — 내부 게이트 이미지 MP4 export 통합(미커밋), PARTIAL:** [구현·새 검증·실패·한계](diagnostics/IMG-EXPORT-01-GATED-MP4.md). 엔진은 기존 image-aware preview/Metal과 Reader→기존 자막 footprint→H.264/AAC Writer를 공유한다. 앱 export 진입점은 기존 compile+runtime 이중 게이트를 요구하며 기본 공개 경로는 꺼져 있다. 원본 source duration/frame count/SourceTiming·형식9 schema·probe 제한 변경 없음.
- **새 자동 검증:** Debug/Release 각각 관련67 PASS + 최종 export/preview6 PASS(중복 포함, 고유69, FAIL/SKIP0). 실제150프레임·5초 이미지 MP4와60프레임·2초 영상/이미지/음악/자막 MP4를 디코딩해 전 프레임 PTS·표본 Y/Cb/Cr을 비교했다. 무압축 raw/QA 계약과 H.264 손실 오차를 구분한다. 취소·writer 초기화 실패·기존 출력/원본 보호·spectrum 거부를 확인했다.
- **정상 앱은 미검증:** 단일-job 정상 Debug 빌드가 `SubtitleSelfTest.swift` primary의 약3.30GB footprint에서 안전 중단(exit65)됐다. 새 signed 앱 실행·native Save/Open·bookmark·실제 음성·제품 UI export/scope 검증은 NOT RUN/owner 대기다. 기존 앱은 복사·해시 보존했다. 한도 상향·테스트 제외·spectrum/WMO host 재시도 없음. 공개 이미지 지원이나 정상 signed export PASS가 아니다.
- 이미지 export는 **엔진 내부 게이트 경로만 한정 검증**, 앱 경로 소스 통합 뒤 빌드 blocker가 남는다. spectrum export·Stage3C-2·공개 이미지 활성화 없음. 기존 창 생성·두 compiler blocker·장기 GPU 취소/drain 한계도 유지한다. 다음은 정상 빌드의 해당 primary를 bounded 진단/복구한 뒤 준비된 generated-fixture 앱 검증이다.

**2026-10-31 IMG-CP-08 — gated persistence/import/preview 체크포인트 감사(미커밋):** HEAD/upstream `800f468`, main `44943ea`. [최종 감사·전체 목록](diagnostics/IMG-CP-08-CHECKPOINT-AUDIT.md), [정확한 manifest](diagnostics/IMG-CP-08-MANIFEST.txt). 제품 이미지 지원 완료나 공개 활성화 승인이 아니다.

- **구현:** 정상 앱의 transaction 기반 format-9 open/save, 이미지 없는 조건부 5–8 writer와 legacy 1–8 reader, 운영 still-image 편집을 연결했다. 내부 import와 image-aware Metal preview는 `OTF_IMAGE_IMPORT` 빌드 조건 + `-OTFEnableImageImport` 실행 인자를 모두 요구한다. 기본 공개 경로는 꺼져 있다. carrier는 AVPlayer timing 전용이며 이미지 모델에 duration/frameCount/SourceTiming을 만들지 않는다. 일반 planner/export의 전체 이미지 카탈로그 차단과 preview-only plan export 거부를 유지한다.
- **자동 검증과 과거 증거:** 이번 bounded Debug 엔진은 69 PASS·FAIL/SKIP 0·exit 0이다. Release는 이번 작업에서 NOT RUN이다. PERSIST-02의 Debug/Release 엔진 93·앱 10그룹 PASS, IMPORT-01 gate on/off 검사, PREVIEW-01R surface 보정·01G generation PASS·02R end/replay 회귀는 각각 당시 증거다. 과거 BLOCKED/PARTIAL/FAIL은 유지한다.
- **실제 정상 signed 앱 관찰(재실행 아님):** [PREVIEW-03R PARTIAL](diagnostics/IMG-PREVIEW-03R-NORMAL-SIGNED-VALIDATION.md)에서 JPEG/PNG/alpha, 150프레임, seek0/149·5초 종료/replay, mixed 영상/이미지, transform·split/trim, 자막·기존 paused spectrum, missing/unverified 거부, export 차단과 영상 전용 복귀를 관찰했다. 화면 관찰을 raw surface hash 일치로 바꾸지 않는다. 서명은 개발용 ad-hoc/sandbox이며 배포 검증이 아니다.
- **미해결/owner 대기:** 자동 editor 창 생성(03R에서 owner Window 메뉴 필요), native Open/Save·권한·재실행 bookmark 검증, 실제 스피커 음성, 정상 제품 GPU in-flight cancellation/drain 계측, spectrum diagnostics target 및 WMO app-host compiler 문제가 남는다. [BUILD-02 BLOCKED](diagnostics/IMG-BUILD-02-MEMBERSHIP-RECOVERY.md)와 [LAUNCH-01R 한정 PASS](diagnostics/IMG-LAUNCH-01R-WINDOW-PRESENTATION.md)를 구별한다. 정상 Debug 빌드 성공이 두 diagnostic 빌드 성공을 뜻하지 않는다.
- **제한:** JPEG/단일 PNG, encoded 8 MiB·최대 2048 px·4,194,304 pixels·추정 decode 128 MiB는 잠정 제한이다. 내부 preview는 FHD30·동시 시각 8층·이미지 upload 합계 64 MiB 한정이며 고해상도 정책·실제 장기 allocation 안정성 검증이 아니다. 이미지 export·이미지 재연결 UI는 미구현이다. Stage 3C-2·spectrum export 상태는 변경하지 않는다.

아래 날짜별 요약은 해당 작업 당시 상태다. 현재 구현/검증 범위는 위 IMG-CP-08과 개별 후속 보고서를 따른다.

**2026-10-30 IMG-IMPORT-01 — 개발 게이트 이미지 import(미커밋):** `OTF_IMAGE_IMPORT` 빌드 플래그와 `-OTFEnableImageImport` 실행 인자를 모두 요구하는 내부 JPEG/PNG 선택·검증·150프레임 삽입 경로를 추가했다. 기본 앱은 꺼져 있으며 mutation 진입점도 차단한다. [검증·한계·owner 절차](diagnostics/IMG-IMPORT-01-GATED-IMPORT.md).
- 운영 catalog/클립을 한 undo 단계로 반영하고 이미지 clip 편집·format-9 저장을 연결한다. 잠정 8 MiB·2048 px·4,194,304 pixels·추정 decode 128 MiB·직렬 검증 정책은 그대로이며 공개 제품 정책 승인이 아니다.
- 실제 서명한 원본 SwiftUI main 검증 번들의 Finder 경로에서 JPEG/불투명·알파 PNG 삽입과 scope 이관·북마크 생성, 손상 파일 거부·scope 해제를 관찰했다. 별도 source-built 검증 번들이며 이번 정규 Xcode 빌드는 시간 제한에 걸렸다. native Open/Save 패널 owner 검증은 남아 있다.
- **일반 공개 이미지 import는 활성화하지 않았다.** 이미지 목록/재연결 UI·제품 이미지 preview/export는 미구현이며 GPU renderer 통합도 없다. 미지원 preview는 기존 영상/overlay를 비우고 안내한다. Stage 3C-2·spectrum export 상태는 변경하지 않았다.

**2026-10-30 IMG-PERSIST-01 — 정상 format-9 persistence 통합(미커밋):** HEAD/upstream `800f468`, main `44943ea`. [transaction·scope·검증 기록](diagnostics/IMG-PERSIST-01-TRANSACTIONAL-PERSISTENCE.md).

- 정상 앱 `saveProject/writeProject/openProject`가 새 `ProjectPersistence` facade를 사용한다. 전체 카탈로그에 used/unused 이미지가 있으면 9, 이미지가 없으면 기존 조건부 5–8로 쓰고 legacy 1–8도 읽는다. 승인된 format-9 schema는 변경하지 않았으며 기존 `ProjectFile`은 legacy codec으로 유지한다.
- 저장 후보를 완전히 검증한 뒤 기존 Cocoa replacement-directory 관례와 same-volume rename으로 반영한다. 교체 전 실패·취소와 교체 후 확인 경고를 구별한다. 누락 이미지도 unverified 참조로 열고 다시 저장하며, 재연결 metadata/UUID 정책을 유지한다. 정상 이미지 재연결 UI는 아직 없다.
- **정상 image import UI·제품 GPU preview/export는 미구현/미지원**이다. 이미지 프로젝트를 열어도 이전 player item을 지우고 전체 카탈로그의 preview/export 게이트를 유지한다. Stage 3C-2·spectrum export 변경 없음.
- 이번 Debug/Release 자동 검증은 각각 엔진 93 PASS·앱 persistence 10개 그룹 PASS(FAIL/SKIP 0, exit 0)다. 실제 sandbox 권한 부여는 CLI와 동일시하지 않으며, source scope 소유권의 결정적 주입 검증과 실제 파일 transaction 검증을 구별한다. Owner Mac의 native Open/Save 패널·실제 sandbox/volume·전체 수동 workflow는 추가 검증이 필요하다. 소유자 실제 파일은 사용하지 않았다.

**2026-10-30 운영 이미지 모델 체크포인트 감사 당시 기록 — IMG-MODEL-05R / IMG-CP-06:** 당시 HEAD/upstream `faca371`, main `44943ea`. 아래 체크포인트는 IMG-CP-07에서 `800f468`로 게시됐다. 이후 정상 persistence 변경은 위 최신 기록과 구별한다. [감사·검증 결과](diagnostics/IMG-CP-06-CHECKPOINT-AUDIT.md), [정확한 공개 후보 manifest](diagnostics/IMG-CP-06-MANIFEST.txt).

- **엔진 still-image 편집 구현:** 원본 source duration/frame count 없이 명시적 stillImage 카탈로그와 visual Clip을 사용한다. 소유자 승인 범위의 기본 150프레임·최소 1프레임·sourceIn 0, trim/split/move/copy/ripple/undo를 지원한다. [04U 범위와 증거](diagnostics/IMG-MODEL-04U-OPERATIONAL-TIMELINE.md).
- **격리 format-9 adapter round-trip PASS:** used/unused·missing 이미지 참조, UUID·clip timing·transform·자막 효과·audio origin/lineage·spectrum·상대 경로/북마크를 보존한다. 저장된 참조와 runtime probe 검증을 분리하며 복원은 unverified 상태다. [05 BLOCKED](diagnostics/IMG-MODEL-05-ADAPTER-BLOCKER.md) 뒤 [05R 복원·호환성 보정](diagnostics/IMG-MODEL-05R-LOSSLESS-ADAPTER.md)을 기록한다.
- **정상 format-9 open/save는 비활성**, normal image import UI는 미구현이다. 이미지가 포함된 정상 저장·제품 preview/export는 전체 카탈로그 검사로 거부한다. [04S BLOCKED](diagnostics/IMG-MODEL-04S-OPERATIONAL-TIMELINE.md), [04T PARTIAL/Debug host crash](diagnostics/IMG-MODEL-04T-SAFETY-GATES.md), [04T-R host recovery PASS](diagnostics/IMG-MODEL-04T-R-DEBUG-HOST-RECOVERY.md)를 구별한다.
- **실제 Mac end-to-end 이미지 workflow는 미검증**이며 제품 이미지 지원 완료가 아니다. 제품 GPU preview/export 통합 없음. 이번 감사에서 Debug/Release 각각 엔진 86 PASS·앱 안전 검사 5 PASS(FAIL/SKIP 0, exit 0)를 새로 실행했다. 이전 GPU/sandbox 증거는 재실행하지 않은 별도 기록이다. 잠정 probe 제한은 확대하지 않았고 Stage 3C-2·spectrum export 상태도 변경하지 않았다.

**2026-10-30 GPU·image probe 체크포인트 준비 당시 기록 — IMG-GPU-02E / IMG-PROBE-05까지:** 당시 HEAD/upstream `e89534d`, main `44943ea`. 아래 격리 실험·probe foundation은 이후 `faca371`로 게시됐으며 제품 채택 승인은 아니다. [공개 준비와 정확한 manifest](diagnostics/IMG-CP-04-PUBLICATION-PREPARATION.md).

- [Metal feasibility](diagnostics/IMG-GPU-01-METAL-FEASIBILITY.md), accounting·lease 보정 후 [GPU-02D](diagnostics/IMG-GPU-02D-SUSTAINED-VALIDATION.md)의 제한된 offline 90/90·496.343fps, paced 90/90·deadline miss0/90을 기록했다. GPU-02D의 신세대 제출 누락은 [GPU-02E GENERATION RECOVERY PASS](diagnostics/IMG-GPU-02E-GENERATION-RECOVERY.md)로 보완했다. 한 Mac·고정 FHD SDR fixture·직접 buffer 시험이며 실제 제품 AVPlayer playback/export·장기 메모리 안정성은 미검증이다. 이전 BLOCKED/INCONCLUSIVE 기록은 보존한다.
- StillImageProbe는 정상 import와 분리된 내부 기반이다. [PROBE-02](diagnostics/IMG-PROBE-02-SCOPE-LIFECYCLE.md)의 손상 IDAT 수용은 [PROBE-03](diagnostics/IMG-PROBE-03-PNG-VALIDATION.md)에서 보정했고, [PROBE-04](diagnostics/IMG-PROBE-04-SAFETY-SANDBOX.md)의 trailing-byte 결함은 [PROBE-05](diagnostics/IMG-PROBE-05-EXACT-ZLIB-BOUNDARY.md)의 플랫폼 zlib 종료·잔여입력 검사로 보정했다. PROBE-04 실제 sandbox UI 회귀와 PROBE-05 자동 회귀는 별도 증거다. 과거 FAIL은 삭제하지 않는다.
- JPEG/단일 PNG·SDR sRGB·encoded8MiB·dimension2048·pixels4,194,304·추정decode128MiB는 **잠정 제한**이다. 전체 PNG 변형·JPEG 무결성·제품 준비 완료를 주장하지 않는다. 당시 이미지 media model·기본 지속시간·형식9는 소유자 결정 대기였다. 당시에는 normal image import·제품 GPU 통합·정상 형식9 open/save가 미구현이었다. 후속 구현은 위 IMG-CP-08 최신 기록을 따른다. Stage 3C-2와 spectrum export 상태는 기존 기록 그대로다.

**2026-10-29 이미지 CPU 실험 당시 요약 — IMG-B-OPT-01까지:** HEAD/upstream `8475ca7`, main `44943ea` 기준의 격리 실험이며 제품 채택 승인이 아니다.

- 범용 ProRes general-alpha cache는 **REJECT**([최종 alpha 조사](diagnostics/IMG1A-4-ALPHA-DECISION.md)). [sampling 계약](diagnostics/IMG1A-3-SAMPLING-PROPOSAL.md)은 미승인 제안이다. Candidate C는 **구조적 불확실성 / INCONCLUSIVE**([구조 gate](diagnostics/IMG-C-POC-1-HYBRID-STRUCTURAL-GATE.md)).
- Candidate B는 최초 admission/scheduler 제한과 수정 이력을 거쳐 **제한된 Reader Gate 1 PASS**([POC1R](diagnostics/IMG-B-POC-1R-BOUNDED-ADMISSION.md)). **AVPlayer 여섯 프레임 delivery PASS**는 제한된 관찰이다. 역사적 Gate 2 export **QUALITY FAIL**은 유지한다([POC2](diagnostics/IMG-B-POC-2-PLAYER-EXPORT-GATE.md)). [QA-02 canonical 재측정 PASS](diagnostics/IMG-B-QA-02-CANONICAL-REASSESSMENT.md)는 측정 경로를 바로잡은 결과이며 과거 FAIL을 전체 PASS로 바꾸지 않는다.
- [PERF-02 Debug 계측](diagnostics/IMG-B-PERF-02-CONTROLLED-INSTRUMENTATION.md)과 [PERF-03 최적화 Release 측정](diagnostics/IMG-B-PERF-03-RELEASE-ACCURACY-PERFORMANCE.md)을 구분한다. [PERF-04 DEADLINE FAIL](diagnostics/IMG-B-PERF-04-SUSTAINED-DEADLINE.md), [PERF-05 calibrated A/B 각각 3/90 deadline misses](diagnostics/IMG-B-PERF-05-DRIVER-TIMING-ATTRIBUTION.md)를 유지한다. [OPT-01](diagnostics/IMG-B-OPT-01-CPU-VECTORIZATION.md)은 정확도 유지·**의미 있는 성능 개선 없음**(image-active paired wall 개선 중앙값 0.53%, CPU 0.59%, 사전 5% gate 미달), 조건부 90-frame 시험 미실행이다.
- 이미지 import는 구현되지 않았고 Candidate B는 제품 승인·실시간 30fps 검증 완료 상태가 아니다. 당시 GPU 성능·실시간 합성·제품 통합은 미검증이었다. 후속 GPU 한정 결과는 위 최신 기록과 구별한다. 이미지 media model·기본 지속시간·프로젝트 형식 9는 소유자 결정 대기다. Stage 3C-2와 spectrum export 상태는 아래 기존 기록 그대로이며 이번 이미지 실험으로 변경하지 않는다. 격리 소스·문서는 미커밋이고 아래 IMG-1A 초기 요약은 당시 기록이다.

**2026-10-27 IMG-1A 격리 실험:** 실행·측정 종료, **REVISE / 제품 채택 불가**. 1초 ProRes 4444 캐시의 alpha 보존·30fps/3분 출력 시간은 확인했지만 공통 sRGB 품질 기준 미달, portrait 오른쪽 경계 1픽셀 assertion 실패, 생산 visibility culler는 투명 상단 아래 레인을 제거함. 기존 export 회귀 3/3 PASS. [실험 증거](diagnostics/IMG1A-STATIC-IMAGE-CACHE.md). 이미지 import·모델·형식 9·생산 렌더링 변경 없음, IMG-1·3C-2 미착수. 소유자 후속 결정 대기.

**2026-10-27 3C-1 퇴출 복구 최종:** **READY WITH DOCUMENTED LIMITATIONS / 구현 완료 후보**. 기존 completed/eviction blocker를 원본에서 실행 재현(57개 중 4 FAIL), 복구 제거 mutation도 검출(77개 중 6 FAIL), 정상 복원 소스 **77/77 PASS**. current 승격 시 한 번 복구·nil/실패 안정성·8 pending/8 retained/16 MiB·명시적 budget failure, 기존 회귀와 Debug/Release 통과. [SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §15.18.1. 3C-2/연속 표시 미착수·Stage 3C 전체 미완료, commit/push 없음. 아래는 이전 시점 기록이다.

**2026-10-27 Stage 3C-1 기반:** `8d33512` 위에서 playback video-output timing adapter·current/+2 bounded controller 구현(미커밋). pending 8·retained 8/16 MiB, cancelled terminal까지 슬롯 유지, epoch/revision/프레임 결과 거부·seek/pause/view/project 무효화. 자동 display link와 연속 표시 없음. 새 결정적/real-WAV 검사 48/48, paused 58/58·수명 25/25·레인 98/98·자막 56/56·preview 5+14·engine 39 PASS, Debug/Release 성공 — 3C-1 구현 완료 후보(한계 포함). [SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §15.18. audio-only·video tail은 unknown, 3C-2 UI 통합·실제 표시 timing 검증 남음, Stage 3C 전체 미완료. 아래 3B-1 미착수 표시는 당시 기록이다.

**2026-10-27 최종 owner 검증·체크포인트:** **READY WITH DOCUMENTED LIMITATIONS**(3B-1 한정). 소유자 실제 Mac 보고로 19/20/30/99/100/119/120, Delete/Undo/Redo, 빠른 seek, 고유 Desktop Save As 후 앱 재실행·정확한 파일 재열기, 프로젝트 전환·복귀, 앱 생성 D-S8 fixture의 46/47/62/63 PASS를 기록했다. 자동 증거는 기존 overlay 58/58·수명 25/25·레인 98/98·자막 56/56·preview 5+16·엔진 39·Debug/Release 성공을 재사용했으며 이번 재실행은 없다. CLI D-S8 sandbox 접근 실패·앱 생성 성공을 함께 보존한다. 수동 relink 미확인, Play→Pause/한 프레임 차이·OpenFlow 13/15·Debug crash/CUA 도구 실패 이력·4K 성능 한계 유지. [SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §15.17. 3C 미착수, Stage 3 통합·소유자 검증 뒤 독립 Codex 리뷰 계획 유지. 아래는 이전 시점 기록이다.

**2026-10-27 소유자 확인·안전 검증 최신:** 소유자 보고로 19/20 출현 경계, 30의 영상/spectrum/자막 층 순서, high 변경 후 low 유지가 부분 확인됨(특정 Delete/Undo로 확대하지 않음). 실제 TA 샘플 120개·video [0,120)/project 180 → frame 120은 정상 검정 tail, 큰 적·녹 무늬는 source 내장 질감으로 확인. 추가 overlay 58/58·수명 25/25 및 Debug/Release 성공. 이전 98/56/preview·OpenFlow 증거는 이번 재실행 아님. 3B-1 정지 프레임 구현 체크포인트 후보, 나머지 owner 전환/relink/rapid seek/Save As·D-S8 수동 확인 대기. [SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §15.16. 3B 전체/Stage 3 완료 아님, 3C 미착수.

**직전 정지 overlay continuation 기록(2026-10-27):** ⏳ 3B-1 정지 spectrum 층 연결·확정 seek identity·stale/teardown 보호 구현(미커밋). focused 54/54, 수명 25/25·레인 98/98·영상 프리뷰(내부 5+프레임 16)·자막 시간 창 56/56, Debug·Release 빌드 성공. 일반 Play→Pause 뒤에는 확인 frame이 없어 숨기고 다음 명시적 seek에서 표시한다. 기존 one-frame pause 한계는 그대로, 소유자 수동 PASS 대기. 실화면 읽기 CUA timeout으로 에이전트 화면 정성 확인도 미완료(앱 충돌 증거 없음), 고유 수동 프로젝트 준비됨. 현재 구조·검증·한계·수동 절차는 [SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §15.15. 3B 전체·3단계 전체 완료 아님.

**직전 수명 부분 기록(2026-10-27):** HEAD·로컬 upstream `5a09bc6`, main `44943ea`. ⏳ 3B-1 중 coordinator 수명 관리만 부분 구현(커밋 안 함). 후보 검증 중 기존 접근/분석 유지 → 교체 확정 때 분석 무효화 후 옛 접근 해제 → 후보 접근 인계 → 현재 media update. 수명 검사 25/25·관련 엔진 39/39 PASS. 실제 정지 spectrum 화면·프레임/seek/view identity 연결은 남아 있으며 3B-1 완료가 아니다. Debug·Release 빌드 성공, 기존 스펙트럼 레인 검사 98/98 PASS. 기존 OpenFlow의 두 실패는 변경 전 HEAD에서도 동일 재현(원인 미확정). 기존 앱 회귀 실패와 빌드 결과·증거는 [SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §15.14. 아래 과거 기록은 당시 상태다.

### S.1 기획·정책 결정

- ✅ 제품 정의·결정 기록·로드맵·환경 문서 작성(0단계 문서). [D] 제품 방향 D-011~D-017.
- ➡️ 로드맵 단계 구성과 각 완료 기준 승인(P-001, 제안 그대로).
- ➡️ 기술 스택(O-02)·최소 macOS·CPU(O-01). 현재 구현은 Swift + AVFoundation, 배포 대상 macOS 15(잠정, M1 선택)이며 P-003·P-004 승인이 아니다.
- ➡️ 입출력 포맷·해상도·프레임레이트·HDR 정책(O-03, O-04), 성능 기준(O-09), 프리뷰·내보내기 일치 판정 기준(O-11; M1은 블록 PSNR 방법을 적용, A-009), UI 언어(O-07), 접근성(O-10), 일반 컷 편집 추가 범위(O-13), 스펙트럼 모양·소스 세부(O-05, O-12).
- ✅ 프로젝트 파일 포맷(O-06 → D-023): `.ontheframe` 버전 있는 JSON. 이후 스키마 결정은 따로 없다.
- [D] 지원 목표: 최대 3시간 프로젝트(D-015)와 4K 편집·내보내기(D-016)는 받아들인 **지원 목표**이며 입증된 능력이 아니다. 선택 확장 후보가 아니다. 검증(§S.2의 E3) 전에는 지원을 주장하지 않는다.

### S.2 기술 검증 실험 (실험 코드, 제품 코드 아님)

- ✅ E1 FHD 통합(A-001, A-002): 시험한 Mac의 10초 FHD에 한함. 높은 부하의 프리뷰 프레임 누락은 미해결 후속(§S.6).
- ⏳ E2 짧은 4K(A-003): 헤드리스 검사 통과, 소유자 화면 정성 통과. 사용자 정의 합성기의 원본 프레임 불일치가 해결되지 않아 **미완료**([experiments/e2-4k/README.md](../experiments/e2-4k/README.md)).
- ✅ E3-1 10분 FHD(A-004): 시험한 Mac의 첫 실행에 한함. 프리뷰 관찰기에 오지 않은 고유 프레임 9개는 원인 미확인.
- ➡️ E3-2(FHD 60분) · E3-3(4K 10분) · E3-4(4K 60분) · E3-5(FHD 3시간, 저장·다시 열기 포함) · E3-6(4K 3시간 복합): 각각 별도 승인 필요. 단계 계획은 [EXPERIMENT-PLAN.md](EXPERIMENT-PLAN.md) §7 그대로.
- 실험의 자막·스펙트럼 렌더링은 실험 기록일 뿐이며 편집기 기능이 아니다.

### S.3 편집 기반 (단계 2) — 전체 ⏳ (R-01의 이미지 가져오기 미충족)

자세한 동작·검증은 [app/README.md](../app/README.md) 각 절.

- ✅ M1(A-005~A-009, `80e84b6`): 영상 가져오기·배치·선택·분할·트림·이동·삭제·실행 취소·프리뷰·내보내기, 닫기·종료 경고. 자동 검증 + 소유자 최종 정성 확인. M1 당시 한계(프로젝트 저장 없음, 영상 트랙 1개 등)는 그 뒤 작업으로 바뀌었다(app/README §9는 M1 당시 기록).
- ⏳ 입력 호환(A-010, `439248e`): 29.97·25·23.976·59.94 고정·가변 프레임레이트, 출력 FHD 30 fps. 실제 29.97 영상은 소유자 정성 통과. 자동 프리뷰 경로 프레임 0 불일치 미해결.
- ✅ 가져오기·내보내기 진행 카드(A-011, `439248e`): 자동 검증, 모양은 소유자 시각 승인. 취소·Finder·키보드 동작은 소유자 미보고.
- ✅ 영상·원본 소리 레인, 연결·해제, 레인 이름, 창 배치(A-012, D-021, D-022, `ef82928`).
- ✅ 프로젝트 저장·열기·최근 목록·재연결(A-013, D-023, `44943ea`). 저장·다시 열기 소유자 정성 확인.
- ✅ 여러 레인과 소리 파일 가져오기·레인 음소거·음량(A-014, D-024), 영상 클립 크기·위치(A-015, D-025), 소유자 보고 편집 수정·여러 오디오 레인 내보내기 믹스, 변형 끌기·패널 재배치(형식 4), 소리 클립 음량·음소거·페이드(D-026, 형식 5) — `cc2724c`(작업 백업)·`8b01322`(체크포인트). 소리 클립 음량·페이드는 소유자 정성 확인.
  - ⏳ 실제 MP3 파일 검증: 이 Mac에서 MP3를 만들 수 없어 생성 fixture 검증이 없다.
- ✅ 열기·가져오기 멈춤 회귀 수정과 가져오기 전체 진행 막대(`cc2724c`, `8b01322`): 소유자 정성 확인(빨리 열림·빨리 가져옴·진행 막대). 자동 측정 아님.
- ✅ 체크포인트 전 리뷰 결함 수정(`8b01322`).
- ✅ 프로젝트 열기 ↔ 저장하지 않은 변경 확인 흐름(`9d14a9f`): 소유자가 처음 보고한 저장·열기 증상이 해결되었다고 정성 보고. 실제 저장 패널 확인 뒤 열기 경로는 자동 검사하지 않았다(모의 결과만).
- ✅ 타임라인 클립 복사·붙여넣기(`51cef3c`, R-02): 단일 선택 + 연결된 짝, 앱 안 클립보드. 소유자 정성 보고 네 가지(재생 헤드에 연결 쌍 붙여넣기, 실행 취소·다시 실행, 같은 위치 반복 붙여넣기가 겹치지 않는 맞는 레인 사용, 텍스트 칸 복사·붙여넣기). 엔진 전체 테스트는 통과가 아니다(§S.6).
- ➡️ 이미지 가져오기와 배치(R-01): **정상 import UI는 미구현이며 원 요구사항은 미충족**. 엔진 편집·정상 format-9 persistence와 내부 게이트 import/preview를 구현·한정 검증했다. 공개 import UI·이미지 export는 미지원이며 owner native-panel/음성·전체 workflow와 창 생성 문제는 남아 있다(상단 IMG-CP-08 최신 기록).
- 단계 2 완료 기준(아래 §2, 제안) 가운데 이미지 가져오기가 남아 있어 단계 2는 완료가 아니다.

### S.4 소유자 승인 순서 (D-028, D-029)와 그 뒤

1. ✅ 타임라인 클립 복사·붙여넣기(§S.3).
2. ✅ 단축키 목록 정리와 V·C 도구 전환(D-027, D-030, 2026-10-11 커밋, [app/README.md](../app/README.md) §27). 자동: `tool-test` 32개(합성 이벤트)·관련 회귀·엔진 분할 테스트 통과(엔진 전체는 통과로 확인되지 않음). 소유자 수동 확인 다섯 가지 통과(소유자 보고: 툴바·가위 커서, 안내선, 연결 쌍 자르기·실행 취소, V 동작, 실제 한국어 입력 소스·텍스트 칸). 범위는 선택·자르기 도구이며, 더 넓은 도구·단축키는 각 기능과 함께 넣는다(D-027). 흔히 쓰는 기본 단축키를 대응 기능에 쓰고, 사용자에게 보이는 이름·도움말은 ON THE FRAME의 기능과 키로 설명한다(비교 상표 없이, 완전 호환 주장 없음). 각 도구의 정확한 동작은 그 작업에서 정한다.
   - ⏳ 안정화 체크포인트(D-029): V·C 뒤, 자막 전. 우선 네 항목 CP-01·CP-02·CP-03·CP-04는 해결(2026-10-12, §S.6). 자막 전 기준은 D-033: CP-08 해결(✅), 엔진 실패 진단·정정(✅, D-034, 엔진 전체 한 번 통과). D-033 자막 전 최소 기준은 게시한 변경으로 채워졌다(엔진 전체 한 번: 89개, 86개 통과, 선택 실행 진단 3개 건너뜀, 실패 0, exit 0). 반복 통과는 확인하지 않았고, 안정화 전체 완료는 아니다. 그 밖의 CP·DOC·검증 빈틈은 열려 있다.
3. ⏳ 자막(R-20, R-21)과 T 도구. 자막의 프리뷰·내보내기 일치(R-30) 포함. 설계 검토 제안(2026-10-12, P-013, 소유자 미승인): [SUBTITLE-DESIGN.md](SUBTITLE-DESIGN.md) — 단계 S1(사용자 정의 합성기 동등성)~S6, CP-07·CP-10~CP-13 배정. S1 조사(2026-10-12, 브랜치 `feature/subtitles`, 커밋하지 않음, 설계 §14): 실험 합성기가 섞인 fps·여러 레인·빈틈에서 기본과 비트 단위로 같고 회전·격자·경계도 맞았지만, 소수 픽셀 위치의 레이어 경계 그리기가 달라 동등은 성립하지 않았다(다음 한정 조사 S1b 제안). 앱은 기본 합성기 그대로. S1b(같은 날, 설계 §15): 경계는 경험 규칙(화소 가운데가 원본 [0, 크기 − 0.25) 안) 보정으로 측정한 60개 가장자리가 모두 맞음. 새 프로세스 첫 재생 12회의 표시 프레임이 모두 맞음. 실제 취소 경로 검사 완료. 크기 조절 보간 필터(세부 PSNR 약 28–29 dB)와 SD·HD 섞인 원본의 출력 색 공간 선택은 여전히 달라 동등 미성립 → 겉모습 차이를 받아들일지 소유자 결정. 엔진 전체 exit 0(101개, 94개 통과, 건너뜀 7, 실패 0). S1b 재검토(2026-10-21, 설계 §16): 경계 규칙이 배율·회전 20경우에서 맞음. 밝기 보간은 같고(최대 2), 남은 차이는 색 세부의 색차(미해결)와 사용자 정의 합성기 경로의 프리뷰 재생 시작 프레임 하나 빠짐(E2 조건 9/9, 원본 오류 0). 동등 미성립 → 겉모습 차이 수용 여부 소유자 결정. 엔진 전체 exit 0(104개, 95개 통과, 건너뜀 9, 실패 0). 첫 자막 기능(2026-10-22, 소유자 지시, 커밋하지 않음, 설계 §42·§43, [app/README.md](../app/README.md) §35): 모델·형식 6·T 도구·글 입력·모양·타임라인 편집·동기 층 프리뷰·자막 있는 내보내기만 구조 R. 자동 검사 통과(`subtitle-test` 24개, 엔진 자막 테스트). 프리뷰 화면 보임·재생 중 시각·IME 실제 입력은 소유자 관찰 남음 → 완료 아님. 소유자 정정(D-036, 설계 §44): 글 작업을 프리뷰 위로 옮김(T 누름 = 그 자리 만들기·쓰기, V 고르기·끌기·두 번 눌러 고치기, 타임라인 누름으로 만들지 않음), [app/README.md](../app/README.md) §36. 즉시 만들기·빈 자막·끌기 부드러움·색 고르개(D-037·D-038, 설계 §45, [app/README.md](../app/README.md) §37). 색 팔레트 20색·색 조정 세션(D-039, 설계 §46, §38). 소유자 일반 확인(2026-10-23, 최근 자막 동작 의도대로 — 항목별 통과 아님). 체크포인트(설계 §47, [app/README.md](../app/README.md) §39): 소유자 수동 확인(저장 다시 열기·내보낸 MP4 겉모습·소리 포함), 최종 리뷰 결함 넷 고침, 로컬 커밋·게시(`e0d83dd`). 자막 효과 외곽선·그림자·배경(D-040, 설계 §48, §40): 소유자 수동 확인(겉모습·저장 다시 열기·내보낸 MP4), 체크포인트 검토 고침(§48.5). 다음: 오디오 스펙트럼(D-028 순서, 아래 4).
4. ⏳ 오디오 스펙트럼(R-10~R-12). 모양·소스 세부는 O-05·O-12 결정 필요. 설계·시제품·SP-0 Debug 실험은 [SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §9·§10(관문 G-P 부분 확인, 멈춤·표시 단계 닫음 §10.19). 프리뷰 통합은 2026-10-25 소유자 결정으로 진행한다(멈춘 뒤 간헐 한 프레임 어긋남은 받아들인 한계로 추적, G-P 부분 확인 그대로, 멈춤 뒤 정밀 탐색·미루는 멈춤 미채택). SP-0 (3) 엔진 분석·일정 부품과 기본 시험(2026-10-24~25, §11·§11.1) — 앱·프리뷰·내보내기·저장 형식 연결 없음, 사용자 기능 아님. 엔진 수준 내보내기 점검(2026-10-25, §12 — 시험 대상 안의 따로 둔 구조 R 경로, 생성 fixture, 인코딩 2조합·기하 6조합)과 한 색 그리기 부품(엔진 package API, §13). 제품 내보내기·프리뷰 연결 없음. 기본 모양 값은 잠정(D-S5), 두 색·부드러움은 SP-2(D-S6). D-S8 승인(2026-10-25: 겹침 경고·내보내기 거부). SP-1A 1단계(2026-10-25, §15): 엔진 스펙트럼 모델·소리 계보·형식 8·판정·편집과 안전 장치 — 앱 UI·프리뷰·내보내기 그리기는 2–4단계, 사용자 기능 아님. P-S1 (나) 승인·구현(2026-10-25, §15.1 — 자동 검증 통과, 소유자 손 조작 확인 남음): 소리 자르기는 늘 계보, 계보가 있으면 형식 8(이전 앱이 열지 못함 — 알림 UX는 따로 결정), 이전 조각 추측 묶기 없음. 1단계 체크포인트 커밋 `024703f`(처음 로컬 커밋 — 게시본 `bc174dd`, 같은 트리·작성자 메타데이터만 다름). 2A 타임라인 스펙트럼 레인 표시(2026-10-25, §15.2 — 자동 검증 통과, 소유자 보고 수동 확인 9/9 PASS §15.4, 로컬 체크포인트 커밋): 레인 종류 정리·읽기 전용 항목 표시, 자체 검사 `spectrum-lane-test` — 사용자가 만들 길은 아직 없음(안전 장치 그대로); 소유자 화면 확인용 Debug 수동 창 `spectrum-lane-manual.sh`(2026-10-26, §15.3). 소유자 보고 수동 확인 9/9 PASS(§15.4, Debug 전용 fixture — 보통 사용자 경로 아님). 2B 정책 일곱 가지 승인(DECISIONS 2026-10-26). 2B-1 스펙트럼 프로젝트 열기·읽기 전용 복원(2026-10-26, §15.5 — 자동 검증 통과, 소유자 확인 남음, 커밋 안 함): 1단계 임시 열기 거부를 뺌, 내보내기 거부·읽기 전용 그대로. 2B-2 소리 클립 문맥 메뉴로 만들기(Debug 전용)·누르면 고르기·Delete 삭제(Debug·Release)(2026-10-26, §15.6 — 자동 검증 통과, 커밋 안 함). 소유자 손 확인은 2B 통합 확인으로 미룸(2B-1 포함, 통과 아님). 2B-3 클립 조정 패널 오디오 소스 드롭다운(값 = 계보 키)·늘 보이는 소스 경고(고르지 않음·지워진 소스·원본 파일 없음·조각 겹침, 타임라인 표시 포함)(2026-10-26, §15.7 — 자동 검증 통과, 커밋 안 함). 2B 통합 소유자 확인(2B-1~2B-3, 2026-10-26, 소유자 보고, §15.8): 만들기·고르기·소스 드롭다운·소스 바꾸기 실행 취소/다시 실행·저장 다시 열기·스펙트럼을 모두 지운 뒤 내보내기·내보내기 막음 알림·소스 경고 넷 PASS로 검토됨 — 저장된 sourceKey 바이트·실패 내보내기 대상 파일 보존·Release 손 조작·삭제 실행 취소 각 단계·재연결·형식 8 호환 경우 전체는 손으로 확인 안 함. 2B 로컬 체크포인트 커밋 `6d50a9b`(처음 로컬 커밋 — 게시본 `a5cd7d1`, 같은 트리; 2A는 `e16bd5e` → `81da6bd`). 2C 정책 여섯 가지 승인(DECISIONS 2026-10-26): 차례 2C-1 옮기기 → 2C-2 트림 → 3 프리뷰 → 2C-3 모양 UI → 4 내보내기, 옮기기·트림은 Debug·Release, 만들기는 Debug 전용 그대로, 스펙트럼 전용 붙음. 2C-1 스펙트럼 끌어 옮기기(2026-10-26, §15.9 — 자동 검증 통과, 소유자 수동 확인 §15.9.3, 기준 커밋 `6d50a9b` 위의 작업, 게시 체크포인트 `9dc4239`): 기존 누름 대기·끌기 수명 그대로, 스펙트럼 레인 사이 이동, 같은 레인 겹침 거부(빨간 제안), 엔진 `snappedSpectrumDelta`, `spectrum-lane` 77/77. 소유자 실제 ⌘Tab(§15.9.1): 처음 FAIL(끄는 중 ⌘Tab이 놓기처럼 끈 자리에 확정), 기록을 받은 재확인 PASS(스펙트럼·영상 클립 — 버튼을 누른 채 비활성 → 취소, 늦은 실제 놓기 무시, 확정 없음). 처음 FAIL의 순서는 기록이 없어 모름 — 간헐 끌기 확정 이상으로 미해결 추적, 재현 가능한 제품 결함 미확인, 제품 고침 없음. 소유자 PASS(§15.9.3): 같은 레인·다른 스펙트럼 레인 옮기기, 겹침 막기, 실행 취소·다시 실행, Esc 취소(명시 확인), 옮긴 뒤 소스 경고, 통제된 다른 이름으로 저장·다시 열기, 옮긴 뒤 내보내기 막음. 앞선 다시 실행·다시 열기 불일치(원래 자리로 보임)는 원인 미확정 — 소유자 확인 스크립트가 고정 fixture를 지우고 다시 만든다는 것은 스크립트로 확인, 그 시험이 다시 만든 파일을 열었는지는 증명 안 됨. Release GUI·모든 저장 경로·출력 바이트 보존은 손으로 확인 안 함. Debug 끌기 진단 다듬음(대상 종류·확정/취소·기록 깊이·⌘ 추적 되돌림, §15.9.2). 2C-2 스펙트럼 가장자리 트림·무음 구간 안내(2026-10-26, §15.10 — 자동 검증 통과, 소유자 수동 확인 §15.10.1: 12항목 PASS, 최소 길이 제한은 관찰됨 — 정확한 1프레임 경계는 소유자가 따로 재지 않음(자동 검사만), 구현 선택 넷 소유자 승인(DECISIONS 2026-10-26 "2C-2 구현 선택"), `9dc4239` 바로 다음 체크포인트 커밋(2026-10-26 소유자 지시로 커밋·게시 — SHA는 `git log`)): 엔진 `trimmingSpectrum` 그대로, 스펙트럼 전용 가장자리 판정(clipHit 밖), 기존 트림 끌기 수명, 같은 레인 겹침 거부(빨간 제안·스펙트럼 트림 문구), 소스 밖으로 늘이기 허용·조각이 없는 프레임은 무음 — 패널 정보 안내와 트림 뒤 상태 줄 안내(경고·내보내기 막음 판정 그대로), Debug·Release. 2C-1 ⌘Tab 처음 FAIL은 그대로 미해결. 3 프리뷰, 2C-3 모양 UI, 4 내보내기 그리기, 형식 8 알림·열기 때 모아 알리는 경고(결정 대기)는 시작 안 함. 3단계 뒤 독립 Codex 리뷰 계획. 3A-1 공개 그리기 입구(2026-10-26, [SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §15.12 — 엔진만, 자동 검증, 커밋 안 함): `SpectrumFrameRenderer`·`SpectrumRenderedFrame`(내부 그리기와 바이트 같음, 결과 화소는 캔버스에서 새 `Data`로 복사해 소유 — 검토 지적(비트맵 할당 실패 대체 경로, 재현 안 됨)에 따라 공급자 대신 캔버스에서 복사하도록 고침 §15.12.1), 앱 연결·프리뷰 UI 없음. 3A-2 분석·프레임 조율(2026-10-26~27, §15.13 — 엔진만, 자동 검증, 커밋 안 함): `SpectrumFrameCoordinator` — 기존 계보·조각·판정 함수로 분석 요청을 만들고 일정 밴드를 3A-1 입구로 그림, 입력 비교로 오래된 결과 거부(미리 끝내기 + 완료 때 비교), 프로젝트 교체·재연결 처리, 조율 시험 11개·엔진 전체 260개(건너뜀 58) 실패 0, 기준 측정 한 번(1080p·4K, 30/60 Hz 부하 — CA·디스플레이 링크는 미측정). 프레임레이트 조사(§15.13.1): 타임라인 격자는 30 fps뿐, 조율이 다른 fps를 잘못 읽던 잠재 결함을 거부로 고침(제품 경로 영향 없음). 앱 연결·보이는 프리뷰(3B) 남음. SP-1A 완료 아님.
5. ➡️ 프로젝트 보호·안정화(§S.6의 열린 문제, 누락 미디어·오류 처리 등).
6. ➡️ 개인 사용 검증(D-011, 소유자의 실제 사용).
- 더 넓은 도구와 그 단축키는 각 기능과 함께 넣는다. 단축키만 먼저 만드는 자리 표시는 하지 않는다(D-027).
- [제안] 이미지 가져오기를 2와 3 사이에 두기: 리뷰어(ChatGPT) 권고이며 소유자가 받아들인 순서가 아니다(P-010). 이미지 가져오기는 순서와 관계없이 남은 원 요구사항이다.

### S.5 통합 내보내기 (단계 5)

- ✅ 지금 내용(영상 레인·소리 레인·변형·클립 소리)의 FHD 30 fps SDR H.264/AAC MP4 내보내기: 진행률·취소·실패 안내·출력 보호·섞인 소리 트랙 하나.
- ➡️ 자막·스펙트럼을 포함한 내보내기(§S.4의 3·4에 따름), 일치 판정 기준(O-11), 출력 정책(O-03, O-04).
- 한계(소스 확인): 영상 원본 없이 소리 파일만 있으면 내보내기를 막는다.

### S.6 프로젝트 보호·안정화 (단계 6) — 열린 문제 목록

- ⏳ A-010 프리뷰 경로 프레임 0 불일치(가끔, 원인 미확정, E2와 별개): [diagnostics/A-010-preview-frame0.md](diagnostics/A-010-preview-frame0.md).
- ⏳ E2 사용자 정의 합성기 원본 프레임 불일치(편집기는 기본 합성기를 써서 그 경로를 지나지 않음).
- ✅ `ClipAudioTests.testPreviewAndExportFollowHandEnvelope`(2026-10-12 정정, D-034, [app/README.md](../app/README.md) §34: 다시 열기 비교를 모델·계획 정확 비교 + 두 채널 표본 차이 ≤ 1×10⁻⁶로 바꿈, 변이 검사 추가, 엔진 전체 한 번 exit 0 — 89개 중 86개 통과·건너뜀 3·실패 0). 이전 기록: 복사·붙여넣기 변경 빌드와 바꾸지 않은 HEAD 모두에서 실패 관찰. 2026-10-12 기준선([app/README.md](../app/README.md) §31.1): 실패하는 단언은 `ClipAudioTests.swift:258`(다시 연 믹스가 표본 단위로 정확히 같음)이고, 차이는 페이드 아웃 구간의 1–2×10⁻⁸뿐이다. 같은 코드로 6번 중 3번 실패. 엔진 전체는 exit 1(85개 중 이 1개 실패)이라 통과가 아니다. 진단(2026-10-12, [app/README.md](../app/README.md) §33): 저장·다시 열기는 원인이 아니다(모델·경사·composition·믹스 값이 같고, 같은 원래 계획을 두 번 읽어도 다르게 나옴). 오디오 믹스 없이 읽으면 늘 같다. 차이는 AVFoundation 오디오 믹스가 페이드 아웃 경사(0.4 → 0)를 적용하는 단계에서만, 몇 가지 정해진 결과로 생긴다(2⁻²⁷·2⁻²⁶). 무엇이 그 결과를 정하는지는 미확인. 테스트 수정 제안 P-012(소유자 미승인, 적용 안 함).
- ⏳ 간헐 자체 검사 실패: `transform-test`의 끌기 시작(`drag.escRestores`·`drag.cornerResize`, "began false"), `close-test`의 `hidden.quitPromptVisible`. 원인 미확인.
- ✅ 끌기 중 창이 초점을 잃는 경우(마우스 놓기 없음): CP-01·D-031에서 다뤘다([app/README.md](../app/README.md) §28). 근거: 앱 안 실제 키 창 바뀜·직접 보낸 비활성 알림(`gestureguard-test`), Finder로 활성화를 넘기는 실제 앱 비활성(`gestureswitch-test`, 합성 마우스), 소유자 손 조작 ⌘Tab 확인(트림·옮기기·프리뷰 끌기·창 밖 놓기). 한계: 손 마우스는 소유자 확인뿐이고 페이드 손잡이 끌기는 손으로 보지 않았다.
- ⏳ 손으로 만든 파일의 항등 변형 값은 빈 실행 취소 단계·저장하지 않은 상태를 만들 수 있다(낮음).
- ⏳ 확인 시트 직후 대기 중이던 다른 알림이 2 s 안에 닫히지 않으면 저장·열기 이어짐이 안전하게 중단된다(데이터 그대로, 다시 시도 필요, 낮음).
- ⏳ 실제 MP3 파일 검증.
- ⏳ `openflow-test` 13/15: `untitled.simulatedSaveThenOpenPanel`·`repeat.requestsStillWork` 실패(처음 기록 [app/README.md](../app/README.md) §35.2, 2026-10-26 변경 없는 `e16bd5e`(게시본 `81da6bd`와 같은 트리) 빌드에서도 같음 — [SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §15.6). 원인 미조사. `openimport-test`는 진단 fixture `long-180s.mp4`가 없어 최근 실행하지 않았다.
- ⏳ Debug 자체 검사 충돌 이력(2026-10-26 조사, [SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §15.11): 진단 보고서 5개 — 제품 AppKit 충돌 1(2026-10-23, 고침), 자체 검사 배열 첨자 함정 4(`TimelineDrawSelfTest` 2026-10-23 둘, `SpectrumLaneSelfTest` 2026-10-26 둘). T-H1(커밋 안 함)이 그 두 검사의 확인 없는 접근을 실패 항목으로 바꿨다(잘못된 fixture 3가지로 충돌 없이 실패 확인). 다른 검사 파일은 검토하지 않았고, Debug 검사 전반이 충돌하지 않는다고 보지 않는다. 2026-10-26 00:17 SIGTERM 1번은 원인 모름.
- ⏳ 엔진 내보내기 시험이 매우 느림(2026-10-25 관찰): `MultiLaneExportTests.testAudioLanesMixMuteVolumeExportAndPreview` 4.4 s(2026-10-24 실행) → 1016 s(전체 실행)·972 s(단독 다시 실행), `SubtitleExportTests.testMultilayerThroughR` 6.1 → 907 s(전체) → 5.8 s(단독). 둘 다 통과. 그때 주 화면이 잠들어 있었다(가설 원인, 확인 안 함). 그 시험·내보내기 코드는 스펙트럼 코드를 쓰지 않는다([SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §11.1).
  - 조사(2026-10-25 01:21 KST, 한 번만):
    - 같은 현재 코드로 단독 실행(150 s 상한·60 s에 표본 계획) → 4.40 s 통과. 이전 정상 4.35 s와 같고, 표본은 뜨지 않았다.
    - 단계 시간(시험에 넣은 출력 `MLX`):
      - 원본 검사·계획 0.03 s
      - 내보내기 0.73 s(진행 0→0.76 0.32 s, 마무리까지 0.76 s)
      - 디코딩 0.38 s
      - composition 읽기 2번 0.14·0.16 s
      - 독립 판정 2.14 s(마지막 단계)
    - 그때 상태: 주 화면 깨어 있음(사용자 4분 전 활동), 전원 어댑터, 열 경고 없음, 기본 출력 내장 스피커.
    - 느렸을 때(00:00–00:31): 주 화면 잠듦. 전원 기록에 coreaudiod·AirPlayXPCHelper 소리 문맥 약 36분(00:31:56에 놓음)이 있으나 이 시험은 소리를 재생하지 않는다(코드 확인). 통합 로그에 그 시간 xctest 기록은 남아 있지 않았다.
  - 다시 관찰(2026-10-25, P-S1 구현 검증 중 엔진 전체 1회째): `SpectrumExportCheckpointTests.testAnalogAboveExport`의 펌프가 약 536 s 멈춰 감시 취소로 실패(정상 약 11 s). 주 화면이 꺼진 시간(10:45:50–10:54:50)과 겹쳤다. 단독 다시 실행 통과, `caffeinate -di`로 화면을 깨워 둔 엔진 전체 2회째는 실패 0(332 s). 화면 잠듦 가설과 맞지만 원인 확인은 아니다([SPECTRUM-DESIGN.md](SPECTRUM-DESIGN.md) §15.1).
  - 판단: 같은 코드가 지금은 정상이므로 코드 변경 때문이라는 근거는 없다. 실행 환경(그때의 화면·유휴 상태 등)에 따른 것으로 보이지만 원인은 확인하지 못했다 — 화면 잠듦이 원인이라고 하지 않는다.
  - HEAD `2d843a0` 비교는 하지 않았다. 지금 환경에서는 현재 코드도 정상이라, 같은 환경의 비교로는 느림을 가를 수 없다.
  - 다음 진단(제안): 느림이 다시 나면 단계 출력이 남는다. 같은 단독 명령을 화면이 잠든 상태에서(소유자가 그렇게 둘 때) 150 s 상한 + `sample`로 돌려 멈춘 스택을 잡는다. 화면·전원 설정은 바꾸지 않는다.
- ⏳ 높은 부하의 프리뷰 프레임 누락(E1), 표시 레이어 갱신 지연(E2·E3-1의 기록 범위), E3-1 미전달 프레임 9개.
- ⏳ 한국어 입력 소스 단축키: 소유자 보고로 동작, 원래 원인 미확정.
- ⏳ 검사 안전 사고(2026-10-11): 초기 검사 판이 실제 저장 패널을 자동 확인해 일회용 폴더 밖(마지막으로 쓴 사용자 폴더)에 검사 프로젝트를 저장했다. 그 파일은 그대로 두었고, 같은 이름의 이전 소유자 파일이 대체되었는지는 알 수 없다. 이후 검사는 실제 저장 패널을 확인하지 않는다.
- ⏳ 2026-10-11 체크포인트 리뷰 지적([reviews/2026-10-11-checkpoint.md](reviews/2026-10-11-checkpoint.md), 코드 읽기 기준·재현하지 않음). 해결하면 여기서 ID별로 고친 커밋과 검증을 적는다(리뷰 문서는 고치지 않음).
  - ✅ CP-01(2026-10-11~12, CP-01 커밋, [app/README.md](../app/README.md) §28):
    - 멈춤 경로: 합성 이벤트로 재현(끌기 중 문맥 메뉴 "연결 해제" → `Timeline.swift:892` precondition 실패, 메뉴가 놓기를 먹어 끌기가 끝나지 않음, 끝나지 않은 끌기에서 `unlinkSelection` → 같은 멈춤). `commit()`·`renameLane` 끌기 중 무시, 끌기 중 문맥 메뉴 안 띄움(고치기 전 코드에서는 검사가 실패).
    - 끊긴 끌기: D-031(창 키 상태 잃음·앱 비활성·남은 끌기 위의 새 누름 → 취소).
    - 옮기기 누름 대기(§28.6): 4 pt 전 누름 대기가 초점 잃음 뒤에도 남아, 같은 누름의 늦은 끌기가 옮기기를 시작·확정하던 결함. 창·앱 상태 바뀜에서 저장소 끌기가 없어도 보기 끌기 상태를 지운다(재현·회귀 검사 있음).
    - 자동: `gestureguard-test` 21개(합성 이벤트, 앱 안 실제 키 창 바뀜, 직접 보낸 비활성 알림), `gestureswitch-test` 5종(Finder로 활성화를 넘기는 실제 앱 비활성, 합성 마우스), 관련 회귀 통과.
    - 소유자 보고(손 조작 ⌘Tab, 정성): 처음에는 트림 통과·옮기기 실패·프리뷰 실패·창 밖 놓기 통과. 수정 뒤 옮기기·프리뷰 중단 통과. 소유자 제공 Debug 기록으로 뒷받침되며, 그 기록에는 비활성 전에 보통 놓기로 확정된 프리뷰 끌기도 하나 있다.
    - 처음 실패의 원인을 누름 대기 결함으로 결론 내리지 않는다. 진단은 Debug 전용이다.
  - ✅ CP-03·CP-02(2026-10-12, CP-02·CP-03 커밋, [app/README.md](../app/README.md) §29): 고침. 자동 검사 통과. 소유자 확인(손 조작)도 통과: 저장 → 새로, 저장 안 함 → 열기, 저장 패널 중 메뉴 꺼짐, 레인 삭제·실행 취소·취소. 확인 중 메뉴 꺼짐은 화면 사진으로 봤다. 확인 중 단축키 막힘은 자동 검사로만 봤다.
    - CP-03: 알림·시트·앱 모달·패널 중 파일 명령(새로·열기·최근·가져오기·내보내기·저장·다른 이름으로 저장·재연결)의 메뉴·단추를 끄고 저장소 진입점도 막는다(경고음·상태 문구). 창 초점만 잃은 것은 막지 않는다. 이어지는 저장 → 새로·열기 흐름은 그대로.
    - CP-02: 레인 삭제 확인을 프로젝트 회차·레인·클립 집합에 묶어, 그사이 프로젝트가 바뀌었거나(같은 파일 다시 열기 포함) 대상이 달라졌으면 지우지 않는다.
    - 증거 경계: 생성 fixture, 실제 NSAlert 시트, 검사용 창 runModal(실제 저장·열기 패널 아님), 주 메뉴 항목 실행, 합성 ⌘ 키. 실제 저장·열기 패널이 떠 있을 때의 메뉴 모양과 손 조작은 보지 않았다.
  - ✅ CP-04(2026-10-12, CP-04 커밋, [app/README.md](../app/README.md) §30): 고침. 자동 검사 `relinkguard-test` 통과. 소유자 수동 확인 통과(소유자 보고, §30.6): 생성 fixture와 명시한 Debug 지연 20초로 확인 중 ⌘O 거절, 재연결 정상 완료, 실행 취소 한 번에 원래 상태, 끝난 뒤 열기 정상.
    - 재연결 확인 중 프로젝트 교체 요청(새로·열기·최근·Finder)을 거절한다(D-032, 미루지 않음·재연결 취소 없음).
    - 늦은 재연결 결과는 회차·열기 상태·대상으로 따로 거른다. 겹친 재연결은 시작하지 않는다.
    - 증거 경계: 지연 훅으로 늦춘 합성 검사, 열기 패널은 검사 대체. 손으로 본 교체 경로는 ⌘O뿐이고(새로·최근·Finder·겹친 재연결·늦은 결과는 자동 검사로만), 실제 큰 파일의 확인 성능은 보지 않았다. 수동 확인 인자는 Debug 전용·명시할 때만.
  - D-029 우선 네 항목(CP-01~CP-04)은 해결했지만 안정화가 끝난 것은 아니다. CP-05~CP-14, DOC-01~DOC-11, 앞의 검증 빈틈(A-010, `ClipAudioTests`, 간헐 자체 검사 실패, TC-05 등)은 그대로 열려 있다.
  - ⏳ 그 밖: CP-05~CP-14(낮음). 2026-10-12 `d891f89`에서 코드 읽기로 다시 확인(재현 없음, [app/README.md](../app/README.md) §31.2): CP-05는 가져오기 쪽만 남음(내보내기 쪽은 CP-03 보호로 막힘), CP-06~CP-14는 남음. CP-08은 CP-01로 닫히지 않았다. 문서 불일치 DOC-01~DOC-11은 나중 문서 정리에서 다룬다.
  - ⏳ 앞선 기본 리뷰의 `swift test` exit 1(TC-05): 실패한 테스트 이름이 남지 않았다. 엔진 코드가 그 뒤 바뀌지 않았고 2026-10-12 전체 실행의 유일한 실패가 `ClipAudioTests.swift:258`이라 같은 실패일 가능성이 높지만 증명되지 않았다.
  - ✅ **자막 전 기준(D-033, P-011 채택 2026-10-12)** — 2026-10-12 두 항목 채움(CP-08 §32, 엔진 실패 §33·§34·D-034). 처음 적은 내용: CP-08 수정(회귀 검사 + 소유자 손 확인)과 엔진 기준선 정리(`ClipAudioTests.swift:258`을 먼저 진단하고 테스트 기대·제품 중 무엇을 고칠지 정함, 오디오 단언 약화는 허락되지 않음). 나머지는 막지 않고 추적하며 CP-07·CP-10·CP-11·CP-12·CP-13은 관련 자막 작업에서 함께 다룬다. 안정화 완료 선언이 아니다.
  - ✅ CP-08(2026-10-12, CP-08 커밋, [app/README.md](../app/README.md) §32): 고침. 자동 검사 `pendingpress-test` 통과(고치기 전 코드에서는 5개 실패로 재현). 소유자 손 확인 네 항목 통과(소유자 보고, §32.5: Delete·⌘Z·⌘V 뒤 이어 끌기, 새 끌기와 실행 취소). 편집 명령 직전에 누름 대기를 지워, 같은 누름의 늦은 끌기가 지운·사라진 클립을 고르거나 원래 클립을 옮기지 않는다. 증거 경계: 자동은 합성 마우스·키(앱 이벤트 큐), ⌘K 등 다른 명령은 자동 검사로만.
- 앱 전체 검토(Codex, 2026-10-23, [app/README.md](../app/README.md) §41, 성능·안정화 체크포인트):
  - ✅ 고침(자동 검사): 손댄 파일의 넘치는 정수로 열기 멈춤, 숫자 칸 큰 값·숫자 아님 멈춤, 자막 레인이 있을 때 새 영상 레인 실패, 조정 세션 중 붙여넣기, 캐시 바이트 예산의 다시 그리기 회귀(되돌림), 자르기 도구 화면 밖 커서 사각형 멈춤(검증 중 발견), 재생·스크롤 중 타임라인 전체 그리기(보이는 영역만, 화소 비교 57/57, 500쌍 재생 중 가장 긴 멈춤 648 → 23 ms).
  - ⏳ 남음(측정됨): 구성 계획 재구성이 클립 수에 거의 제곱(2000개 117 ms, 주 스레드 밖), 재생 중 고정 부하(그리기 한 번 약 12 ms, 주 실행 루프 약 37%).
  - ✅ 프리뷰 자막 그림 메모리(설계 §49, [app/README.md](../app/README.md) §42, 자막 메모리 체크포인트 2026-10-24, 소유자 수동 관찰 포함): 그림 자르기 + 시간 창 + 캐시 LRU로 500개 +975 → +45 MB, 2000개 +3.8 GB → +62 MB(측정). 재생·탐색 중 가장 긴 멈춤 약 10~20 ms 늘어남, 실제 화면 소유자 확인 남음.
  - ⏳ 남음(측정 안 한 가설): 실행 취소 기록 상한 없음·가져오기 때 지난 기록 전체 고침, 저장·열기 일부 주 스레드, 쓰기가 막힌 채 내보내기 취소가 끝나지 않을 수 있음, 지난 프리뷰 재구성 작업을 취소하지 않음, 탐색 요청을 묶지 않음.
- ➡️ 성능 기준(O-09)과 3시간·4K 검증(E3-2~E3-6).
- ➡️ 소유자 요청(2026-10-12, 미구현, CP-01과 따로): 타임라인을 가장 작은 확대로 줄이면 시각 0부터 모든 레인의 가장 늦은 클립 끝까지가 보이는 영역 안에 끝에 작은 여백을 두고 들어오게 한다. 가로 스크롤을 그 범위가 보이게 되돌리고, 보이는 영역 크기가 바뀌어도 맞춘다. 작업 지시가 있을 때 한다.
- 현재 없는 것(2026-10-11 소스로 확인): 타임라인 썸네일, 파형 표시(목록의 파형 아이콘·소리 클립의 음량·페이드 선은 있음), 소리 레벨 미터, 재생 중 재생 헤드 따라 스크롤(끌기 중 자동 스크롤만 있음), 소리 파일만 있는 내보내기. 첫 릴리스에 필요한지는 정하지 않았다.

### S.7 첫 릴리스 필수로 정하지 않은 것

- [선택] 원 brief의 선택 후보: 자동 자막, 고급 애니메이션, 원형 스펙트럼.
- 자동으로 첫 릴리스 요구사항이 되지 않는 것(소유자, 2026-10-11): 회전, 불투명도, 전환, 키프레임, 고급 효과, 여러 개 선택, 잘라내기(Cut), 다른 프로젝트로 붙여넣기, 여러 창, 정규화·리미터, 단축키 사용자 지정.

### S.8 상업 배포 준비 [조건부]

- ➡️ 개인 사용이 성공했다고 소유자가 판단한 뒤에만(D-012): 배포 채널(O-14), 소스 코드 라이선스(O-15), 활성화(O-16), 업데이트 권한(O-17), 결제(O-18), 최종 가격(O-19), 지원 macOS·CPU 범위(O-01). 활성화·결제·라이선스 인프라는 개인 사용 단계에 넣지 않는다(D-017).

## 단계 개요

| 단계 | 이름 | 목적 |
| --- | --- | --- |
| 0 | 기획 | 요구사항·열린 질문 정리 |
| 1 | 기술 검증 | 작은 end-to-end 실험으로 핵심 통합 위험 확인, 스택 결정 |
| 2 | 편집 기반 | 프로젝트 모델, 미디어 가져오기, 타임라인 편집, undo/redo, 저장 |
| 3 | 자막 | 수동 자막 입력과 스타일·타이밍 |
| 4 | 스펙트럼 | 선택 오디오 기반 스펙트럼과 동기화 |
| 5 | 통합 내보내기 | 프리뷰와 일치하는 최종 내보내기 |
| 6 | 안정화 (개인 사용) | 오류 처리, 성능, 재연결, 3시간·4K 목표 검증 완료, 소유자 개인 사용 |
| 7 | 상업 배포 준비 (조건부) | 개인 사용 성공 후에만. 배포 채널, 라이선스, 활성화, 결제 등 |

## 0. 기획

- 내용: 제품 정의, 결정 기록, 로드맵, 개발 환경 문서 작성.
- 완료 기준:
  - [PRODUCT.md](PRODUCT.md), [DECISIONS.md](DECISIONS.md), [ROADMAP.md](ROADMAP.md), [ENVIRONMENT.md](ENVIRONMENT.md)가 작성되고 사용자가 검토했다.
  - 기술 검증에 필요한 최소 결정(O-01 최소 macOS 버전·아키텍처의 잠정안, 검증할 스택 후보)이 정리되었다.

## 1. 기술 검증 (초기 end-to-end 실험)

작고 버릴 수 있는 실험으로 가장 위험한 통합 지점을 먼저 확인한다([DECISIONS.md](DECISIONS.md) P-002). 실험 코드는 제품 코드로 간주하지 않는다. 단계별 실험 계획(E1 FHD 통합 → E2 짧은 4K → E3 길이 확대)은 [EXPERIMENT-PLAN.md](EXPERIMENT-PLAN.md)(P-006), E1의 상세 검사 방법은 [TECHNOLOGY-EVALUATION.md](TECHNOLOGY-EVALUATION.md) §6에 있다. 이 단계에서는 E1과 E2까지를 대상으로 하고, 긴 내보내기(E3)는 편집 기반이 갖춰진 뒤 진행하는 것을 제안한다.

- 실험 범위(제안):
  - 오디오 1개 + 배경 이미지 또는 영상 1개 + 자막 1개 + 단순 막대형 스펙트럼 1개
  - 프리뷰 재생과 짧은 영상 파일 내보내기
  - 오디오 클립을 트림·이동한 뒤 스펙트럼 동기화 확인
  - 내보내기 진행률과 취소 동작 확인
- 확인할 위험:
  - 프리뷰와 내보내기에서 같은 합성 경로를 쓸 수 있는지, 결과가 일치하는지
  - 오디오 분석(FFT 등) 결과를 타임라인 시간과 프레임 단위로 정확히 맞출 수 있는지
  - 자막 텍스트 렌더링(한글 포함)이 프리뷰와 내보내기에서 같은지
  - 목표 길이 영상에서의 메모리·처리 시간 (O-09 결정에 참고)
- 진행 상황(2026-10-10): E1-a(헤드리스 FHD 합성·내보내기, A-001)와 E1-b(실제 `AVPlayer` 프리뷰 통합, A-002)를 실행했다. E1-b는 첫 소유자 관찰에서 화면 표시가 실패해 수정했고, 수정된 창은 소유자 재확인에서 정성적으로 통과했다. 끝 프레임 유지(D-018)를 구현했고 소유자 재확인도 통과해 E1을 완료했다(2026-10-10). 범위는 시험한 Mac의 짧은 FHD 통합이며, 높은 부하의 프레임 누락은 안정화 단계 후속 과제다. 결과는 [experiments/e1-fhd/README.md](../experiments/e1-fhd/README.md). E2(짧은 4K 컷 편집, A-003)는 2026-10-10 실행했다: 헤드리스 검사 통과, 프리뷰 재생 시작 현상 완화(관찰), 변경 뒤 1회 관찰된 소스 프레임 불일치는 해결되지 않음, 소유자 화면 관찰은 정성적 통과, E2 미완료([experiments/e2-4k/README.md](../experiments/e2-4k/README.md)). E3-1(10분 FHD, A-004)은 2026-10-10 실행해 완료했다: 실행 완료, 정확도 통과(수정된 검사 기준), 소유자 정성 관찰 정상, 범위는 시험한 Mac의 10분 FHD 첫 실행([experiments/e3-fhd-10min/README.md](../experiments/e3-fhd-10min/README.md)). E3-2 이후는 미착수다(§S.2).
- 완료 기준:
  - 실험 결과(성공/실패, 측정값, 발견한 제약)가 문서로 정리되었다.
  - 기술 스택과 아키텍처(O-02)에 대한 제안이 근거와 함께 작성되고, 사용자가 결정했다. (비교 자료: [TECHNOLOGY-EVALUATION.md](TECHNOLOGY-EVALUATION.md))

## 2. 편집 기반

- 편집기 UI 첫 계획(제안, 미승인): [EDITOR-PLAN.md](EDITOR-PLAN.md). 소유자 방향(2026-10-10)에 따라 이 단계의 UI 작업은 장시간 실험(E3-2 이후)과 나란히 진행할 수 있다. M1(A-005~A-009)은 2026-10-10 완료했고(30 fps·1080p 이하 입력과 FHD 출력에 한함, [app/README.md](../app/README.md) §11), 그 뒤 작업 승인별로 입력 호환·진행 표시·레인·저장·열기·여러 레인·변형·클립 소리·복사·붙여넣기를 구현했다. 현재 상태와 남은 항목은 §S.3·§S.4.
- 내용: 프로젝트 데이터 모델, 미디어 가져오기(영상·이미지·오디오), 타임라인(트림·분할·이동·복사·붙여넣기·삭제), undo/redo, 프로젝트 저장/열기, 프리뷰 재생. 음악 영상과 일반 컷 편집(D-014) 모두에 쓰이며, 일반 컷 편집의 추가 범위는 O-13 결정에 따름.
- 완료 기준:
  - R-01~R-03, R-40, R-41이 동작한다.
  - 편집 후 원본 미디어 파일이 변경되지 않음을 확인했다.
  - 저장 → 다시 열기 후 타임라인이 동일하다.
  - 핵심 편집 동작에 대한 자동 테스트가 있다.

## 3. 자막

- 내용: 자막 입력, 표시 구간, 폰트·크기·색상·정렬·위치 조정, 프리뷰 표시.
- 완료 기준:
  - R-20, R-21이 동작한다. (DR-02, DR-07 채택 시 undo/redo 포함과 한글 표시도 확인)
  - 자막 타이밍이 프리뷰에서 지정한 구간과 일치한다.

## 4. 스펙트럼

- 내용: 오디오 선택, 스펙트럼 렌더링. 초기 모양과 컨트롤 항목은 O-05 결정에 따름.
- 완료 기준:
  - R-10~R-12가 동작한다. (DR-05, DR-06, DR-09 채택 시 함께 확인. 소스 세부 동작은 O-12 결정에 따름)
  - 오디오 클립 트림·이동 후에도 스펙트럼이 해당 오디오와 동기화됨을 테스트로 확인했다.

## 5. 통합 내보내기

- 내용: 영상·이미지·오디오·자막·스펙트럼을 합성한 최종 내보내기. 진행률, 취소, 실패 처리.
- 완료 기준:
  - R-30, R-31이 동작한다.
  - 같은 프로젝트의 프리뷰와 내보낸 결과가 구성·타이밍 면에서 일치함을 비교 절차(예: 특정 프레임 비교, 오디오 오프셋 측정)로 확인했다.
  - 취소·실패 시 원본 미디어가 변경되지 않는다(R-40). 불완전한 출력 파일 처리, 원인 안내, 기존 출력 파일 보호는 DR-03, DR-04, DR-10 채택 시 확인.
  - 일치 판정 기준(O-11)이 결정되어 적용되었다.
  - 출력 포맷·해상도·프레임레이트 정책(O-03, O-04)이 결정되어 반영되었다.

## 6. 안정화

- 현재 열린 문제 목록은 §S.6.
- 내용: 누락 미디어 재연결, 오류 메시지, 성능 개선, 지역화(O-07). 접근성 지원 범위는 미정(O-10). 대상은 소유자의 개인 사용(D-011)이다.
- E1에서 넘어온 후속 과제(소유자 결정 2026-10-10, E1 차단 요소 아님): 높은 부하에서의 프리뷰 프레임 누락. 합성기 요청·전달 버퍼·실제 화면 표시를 구분해 조사한다([experiments/e1-fhd/README.md](../experiments/e1-fhd/README.md) §6.7). 해결되었다고 보지 않는다.
- 완료 기준:
  - R-42가 동작한다.
  - [EXPERIMENT-PLAN.md](EXPERIMENT-PLAN.md) E3의 3시간 4K 복합 케이스를 포함한 길이 확대 검사를 통과했다. 통과 전에는 3시간·4K 지원을 주장하지 않는다.
  - 성능 기준(O-09)이 결정되었고 이를 만족한다.

## 7. 상업 배포 준비 (조건부)

- 전제: 소유자가 개인 사용이 성공했다고 판단한 경우에만 진행한다(D-012).
- 내용: 배포 채널(O-14), 소스 코드 라이선스(O-15), 활성화(O-16), 업데이트 권한(O-17), 결제(O-18), 최종 가격(O-19), 지원 macOS·CPU 범위(O-01)의 검증된 호환성 확보.
- 라이선스 인프라는 이 단계 전에는 구현하지 않는다(D-017).
- 완료 기준: 위 항목이 결정되어 반영되었다.

## 선택 후보 (일정 미배정)

자동 자막, 고급 애니메이션, 원형 스펙트럼은 첫 릴리스 확정 범위가 아니다. 포함 여부는 별도로 결정한다.
