# SP-3C2-25 — 적용된 이미지 프리뷰 검증 계약

## 범위와 소유권

기준은 `feature/subtitles`, HEAD/upstream `1c61df249468af09a7e90daf82c8e510e9a06480`이다. SP-3C2-23 조사와 SP-3C2-24 차단 사유는 앱이 설치된 이미지 계획의 검증 성공을 판정할 읽기 전용 계약이 없다는 것이었다. 이미지 catalog 존재, `missingMedia.isEmpty`, 세대 일치만으로는 충분하지 않다.

`ProjectStore`가 검증 증거를 비공개로 만들고 무효화한다. 엔진의 `PlannedComposition.isImagePreviewOnly`는 기존 내부 mode의 읽기 전용 getter이며 자체적으로 자격을 부여하지 않는다. controller와 fallback 동작은 변경하지 않는다.

## 조회 계약

`imagePreviewEligibility(for:session:generation:)`는 MainActor에서 현재 상태를 읽는다. 파일 I/O, 접근 권한 취득, decode, task 생성은 없다. 반환값을 비동기 작업 후 재사용하지 말고 현재 항목·세션·세대로 다시 조회해야 한다.

| 상태 | 의미 |
| --- | --- |
| `absent` | 게이트 꺼짐 또는 이미지 설치 증거 없음 |
| `pending` | 재빌드·초기 설치·후보 재연결 또는 항목 readiness 미확인 |
| `invalidated` | 항목/계획/세션/세대/접근 revision 불일치, 알려진 가용성 변경 또는 초기 seek 미완료 |
| `cancelled` | scope 종료로 작업 취소·증거 폐기 |
| `failed` | 계획/접근 검증 실패 또는 플레이어 항목 실패 |
| `validatedAtInstallation` | 정확히 현재 설치된 이미지 계획이 설치 시 검증을 마쳤음 |

마지막 상태만 **설치 검증 조건**을 충족한다. 정확한 AVPlayerItem과 composition 객체, 프로젝트 세션, 생성·적용 세대, 접근 revision을 모두 검사한다. 플레이어 항목은 ready 상태여야 한다. 별도 새 export 권한이나 재생 허가 플래그가 아니다.

## 접근 및 비동기 경계

기존 planner의 catalog identity, scope 획득, 파일/미디어 검사, 두 번째 읽기·decode 뒤 identity 확인을 그대로 사용한다. planner가 성공한 뒤 접근 revision을 보존하고, 초기 seek의 await 뒤 현재 항목·프로젝트 세션·세대·계획·접근 revision을 재확인한 경우에만 증거를 만든다. 실패하거나 오래된 성공은 증거를 만들지 않는다. 알려진 가용성 변경은 기존 증거를 폐기하며, positive availability callback만으로는 증거를 복구할 수 없다.

이 계약은 **설치 당시 검증**이다. 이미 decode된 이미지 texture를 가진 계획이 남아 있어도 원본 파일이 이후 이동·권한 변경될 수 있다. 조회는 그 변경을 실시간 탐지하지 않는다. 미래 이미지 fallback의 live-access 요구는 별도로 정해야 하며, 필요하면 기존 비동기 미디어 검증을 재사용하고 완료 뒤 같은 컨텍스트를 재검사해야 한다. 디스플레이 링크에서 파일 검사하거나 프레임마다 검증 task를 만들면 안 된다. 현재 fallback의 이미지 제외 조건은 그대로다.

## 전환

- 재빌드 시작: 즉시 pending, 기존 증거 제거. 직렬 task chaining과 generation/session fencing 유지.
- 재빌드 실패: failed. 취소·프로젝트 종료: cancelled와 세대 증가. 정상 비이미지 계획: absent.
- 항목 교체: 실제 설치 항목과 증거가 다르면 invalidated. 계획 교체도 composition identity 검사로 거부.
- 재연결 후보 검사 중: pending. 취소한 후보는 기존 계획을 변경하지 않으므로 기존 증거를 다시 사용할 수 있다. commit 시 timelineChanged가 새 세대·재검증을 시작한다.
- 가용성 revision 변경: 현재 참조 revision/session/generation에 맞는 callback만 반영. 기존 증거는 복구되지 않으며 새 전체 검증이 필요하다.
- 일반 seek·pause·resume: 같은 설치 계획의 증거는 유지한다. 재생 여부·pending seek·유효 시각 등 controller의 표시 조건은 별개다. 초기 설치 seek가 완료되지 않은 계획은 자격을 얻지 않는다.

## 검증 및 한계

**IMAGE ELIGIBILITY CONTRACT PASS (자동 검증).**

| 실행 | 결과 | 종료 코드 |
| --- | --- | --- |
| 제한 APFS Debug 최초/최종 증분 빌드 | 성공/성공 | 각각 0 |
| 최종 서명 앱 eligibility | 32/32 (bounded wait 단언 포함) | 0 |
| 최종 서명 앱 runtime gate-off | 3/3 | 0 |
| 최종 서명 앱 spectrum controller | 92/92 | 0 |
| 최종 서명 앱 paused overlay | 58/58 | 0 |
| 보존 엔진 SpectrumModel/FrameCoordinator/Scheduler | Debug 12+13+14, Release 12+13+14 모두 통과 | 6개 실행 모두 0 |
| 보존 엔진 ProductImagePreview | Debug 2/2 | 0 |
| 최종 앱 strict 서명 검사, diff 공백 검사 | 통과 | 0 |

새 계약의 실제 설치·실패·seek·재연결·stale 검증은 최종 서명 Debug 앱에서 실행했다. 이미지 gate-off는 **컴파일 gate가 켜진 Debug 앱에서 runtime gate를 끈 검사**다. 기존 compile gate 코드는 수정하지 않았다. broad Release/prototype/WMO 컴파일과 새 앱 계약의 Release 실행은 하지 않았다. 보존 엔진 바이너리는 변경 없는 동작의 회귀이며 새 mode getter 컴파일 검증은 최종 Debug 앱 빌드에 포함된다.

증거: 무시된 `app/selftest-work/sp3c225/`의 build 로그·eligibility/controller/overlay 로그·engine 로그와 종료 코드. 생성 계약 fixture는 `app/selftest-work/image-eligibility-20261106T141054Z-KbImlQ/`. 최종 소스·앱 지문은 `sp3c225/final-fingerprints.json`에 보존한다.

관리 할당량은 `du -skx` 기준 app 9,423,788 + experiments 1,683,992 + 전용 개발 출력 7,372,104 = 18,479,884 KiB, 약 **17.62/20 GiB**(시작17.26에서 약0.36 GiB 증가, 여유2.38 GiB). 기존 앱을 덮어쓰지 않고 새 1,500 MiB 상한 APFS sparse volume에서 단일 job으로 빌드했다. 기존 미추적4개와 복구 refs는 지문/값 일치, index 비어 있음. 정리·staging·commit·push 없음.

서명 Debug 앱의 `-OTFImageEligibilityTest`는 격리된 설정 suite와 생성 PNG만 사용하며 export나 실제 파일 패널 승인을 하지 않는다. 기존 엔진의 보존된 Debug/Release 바이너리 회귀는 새 앱 계약의 Release 컴파일 증거와 구분한다.

소유자 수동 육안·청취는 **OWNER MANUAL DEFERRED — NOT PASS**. 이미지 공백/꼬리 fallback, 공개 이미지 활성화, spectrum export, schema 변경은 이 작업에 없다. Stage 3C-2 전체 완료가 아니다.


## SP-3C2-26 체크포인트 감사 (2026-11-06)

**PUBLICATION READY — 자동 증거 기반, 미커밋.** 기준 branch/HEAD/upstream/live remote와 main은 위 기록 그대로이며 원격 HEAD는 main이다. 게시 후보는 CompositionPlanner, ProjectStore, OnTheFrameApp, ImageEligibilitySelfTest, image-eligibility-test.sh, ROADMAP, HANDOFF 및 이 문서의 8개다. 이번 감사는 문서 3개만 갱신했다. 전체 파일 SHA-256과 Git mode의 최종 매니페스트는 SP-3C2-26 최종 보고 및 게시 제외 증거 `app/selftest-work/sp3c226/publication-manifest.json`에 기록한다(이 문서 자체를 포함하므로 문서 안에 자기 해시를 넣지 않는다).

- **소유권:** 증거 구조체·저장 변수·무효화 메서드는 private이다. 현재 유일한 증거 생성 지점은 이미지 planner 성공과 초기 seek 완료 뒤다. mode getter는 읽기 전용이며 기존 내부 flag의 기본값은 false, true를 쓰는 제품 코드는 InternalImagePreview의 성공 반환 한 곳이다. mode만으로는 증거가 생기지 않는다. 새 query를 controller가 사용하거나 이미지 제외 조건을 제거한 변경은 없다.
- **경쟁 조건:** MainActor의 동기 조회/설치 구간에는 await가 없고, planner와 초기 seek의 await 뒤 session/generation/item을 다시 확인한다. 접근 revision은 planner 반환 뒤 보존하고 최종 게시 때 다시 비교한다. 준비 완료 hook에서 지연된 성공·가용성 revision 변경·프로젝트 교체를 보존된 테스트가 검사했다. 재연결 후보의 pending은 기존 증거를 일시적으로 가리며 후보 취소는 설치 계획을 변경하지 않는다. commit은 새 세대의 전체 재검증으로 넘어간다. 알려진 source revision 불일치는 callback에서 제외한다. 일반 seek의 표시 준비 여부는 설치 증거와 별도이며 기존 controller의 pending-seek 조건을 유지해야 한다.
- **fail-closed의 범위:** pending/failed/cancelled/invalidated/absent 및 항목 readiness 미확인은 설치 자격을 주지 않는다. 그러나 외부 파일이 나중에 바뀌어 아직 감지되지 않은 상태까지 이 query가 알아내는 것은 아니다. `validatedAtInstallation`을 현재 접근 승인으로 해석하면 안 된다. 이 한계는 중대한 미보고 결함이 아니라 명시적으로 제한한 계약 범위다.
- **다음 통합 필수 조건:** fallback 허용 전에 이미지 catalog/source revision에 맞는 원본 identity·가용성·접근을 기존 비동기 이미지 검증 경로로 확인해야 한다. 새 계획을 만드는 경우 기존 전체 probe와 두 번째 읽기를 유지한다. 선택 오디오의 기존 `checkPlaybackMedia`는 오디오 원본만 검사하므로 이미지 원본 검증을 대신하지 못한다. 검증 대기/실패/미확인은 fallback을 허용하지 않고, 완료 뒤 정확한 item/composition/session/generation/access revision에 대해 설치 계약을 다시 조회해야 한다. 새 검증은 소유자의 scope 수명 안에서 제한된 작업으로 수행하고, 캐시의 유효기간·무효화와 재검증 시점을 다음 slice에서 명시해야 한다. 영구 접근 보장이나 매 프레임 전체 decode는 허용하지 않는다.
- **증거 분류:** 계약32/32는 대기 단언12개를 포함한다. gate-off3/3은 runtime gate-off이며 compile gate-off 빌드 실행이 아니다. controller92/92, overlay58/58, 엔진 Debug39/39·Release39/39·이미지2/2는 모두 **SP-3C2-25의 과거 실행**이다. 이번에는 source 8개와 signed bundle 전체 지문을 대조하고 저장 JSON/log 판정·종료 코드·strict 서명을 확인했다. 새 기능 테스트·앱 실행·컴파일은 없다. 보존 엔진 Release 결과는 새 앱 계약의 Release 실행 증거가 아니다. 재연결 후보 취소와 readiness 실패의 모든 조합을 독립 실행한 증거로 확대하지 않는다.
- **이번 검사:** Git/원격/복구 refs·빈 index·기존 미추적4개 지문, source/app 지문, 저장 결과 판정, strict 서명, shell 구문, 문서 링크, 전체 변경/파일 형식·mode·민감 경로/자격 증명 패턴, `git diff --check`를 검사했다. 모두 통과(종료0). 새 테스트가 필요한 중대한 감사 공백은 발견하지 않았다.
- **자원/제외:** 감사 시작 `du -skx`는 app 9,423,792 + experiments 1,683,992 + 전용 개발 출력 7,372,104 = 18,479,888 KiB(17.62/20 GiB). APFS mount 중복을 제외했다. 기존 .DS_Store 3개·.claude/settings.json·생성 fixture/프로젝트·서명 앱·로그·캐시·DerivedData·disk image와 기타 사용자 데이터는 보존하고 게시 후보에서 제외한다. 후보에 symlink·바이너리·자격 증명·새 개인 절대 경로·무관한 변경은 없다.

소유자 수동 수락은 계속 **OWNER MANUAL DEFERRED — NOT PASS**. 이미지 gap/tail 통합·새 계약의 Release 앱 실행·장기/물리적 A/V 검증·Stage 3C-2 전체 수락은 남는다. 제안 commit subject: `Add read-only applied image preview eligibility contract`. 공개 이미지 활성화, spectrum MP4 export, schema/소유자 데이터 변경, staging/commit/push 없음.
