# 로드맵 — ON THE FRAME

> **상태: 제안(Proposed).** 아래 단계 구성과 순서는 사용자 승인 전의 제안이다([DECISIONS.md](DECISIONS.md) P-001). 일정은 정하지 않았다. 각 단계의 완료 기준도 제안이며, DR- 항목은 소유자 미승인 파생 요구사항이다([PRODUCT.md](PRODUCT.md) §6).
>
> 소유자 확인 방향(2026-10-09): 개인용으로 시작해 성공 시 상업 배포(D-011, D-012), 최대 3시간·4K 지원 목표(D-015, D-016, 미입증), 초기 구현에 라이선스 인프라 제외(D-017). 이 방향 확인은 이 로드맵(P-001)의 승인이 아니다.

## S. 현재 상태 체크리스트 (정본, 2026-10-11)

이 절이 작업·상태 목록의 정본이다. 다른 문서의 요약은 이 절을 가리킨다. 아래 1–7절의 단계 구성·완료 기준은 여전히 제안(P-001)이며, 이 체크리스트에 적은 소유자 결정이 그 단계 구성 전체나 완료 기준을 승인하지 않는다. 짧은 인계 요약은 [HANDOFF.md](HANDOFF.md).

**표시:** ✅ 적은 범위 안에서 완료 · ⏳ 일부 구현·조사했지만 해결되지 않음 · ➡️ 시작하지 않음(결정 대기 포함). ⏳는 지금 에이전트가 작업 중이라는 뜻이 아니다.

**출처 표시:** [R] 원 brief 요구사항([PRODUCT.md](PRODUCT.md) §5) · [D] 확정 결정([DECISIONS.md](DECISIONS.md) §1) · [A] 작업 승인(§2.1) · [구현] 코드·커밋으로 확인한 사실 · [제안] 미승인 제안(P-, 리뷰어 권고 포함) · [선택] 첫 릴리스 요구사항이 아닌 후보 · [조건부] 개인 사용 성공 뒤에만.

**기준:** 자막 작업은 브랜치 `feature/subtitles`(첫 자막 기능 로컬 커밋 `04d4b58`(엔진)·`c36923e`(앱)·`81fda71`(조사 시험)·문서 커밋, 푸시하지 않음). 이전 기준 `backup/2026-10-11-editor-work`(`51cef3c`), `main`은 `44943ea` 그대로. 프로젝트 형식: `main`·이전 브랜치 5(형식 1–4 읽기, D-023), `feature/subtitles` 6(자막, 자막이 없으면 5로 씀, D-035). 검증 경계: 자동 검사는 이 Mac 한 대·짧은 생성 fixture, 소유자 확인은 소유자가 보고한 정성 관찰이며 둘을 섞지 않는다.

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
