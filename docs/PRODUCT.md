# 제품 정의 — ON THE FRAME (온더프레임)

> 상태: 원 brief 요구사항과 **2026-11-17 DOC-ALIGN-01 소유자 방향 보완**. 구현·검증·공개 범위는 별도다.
> - **명시 요구사항(R-)**: 소유자의 원 기획 brief에 직접 적힌 내용. 소유자가 제시한 범위다.
> - **제품 방향(PD-)·지원 목표(T-)**: 소유자가 2026-10-09에 확인한 방향과 목표. **목표일 뿐 구현·검증된 능력이 아니다.**
> - **파생 요구사항(DR-)**: 명시 요구사항을 실현하는 데 필요하다고 판단해 Claude Code가 도출한 내용. 소유자가 별도로 승인하지 않았으며 검토 대상이다.
> - **열린 질문(Q-)**: 아직 결정되지 않은 사항.
>
> 결정 이력은 [DECISIONS.md](DECISIONS.md)에서, 구현 현황(요구사항별 완료·남은 것)은 [ROADMAP.md](ROADMAP.md) §S에서 관리한다. 제품 방향 확인은 기존 제안(P-001~P-005)의 승인을 뜻하지 않는다.

## 현행 프로젝트 형식과 기능 경계

**기준:** feature/subtitles의 게시 체크포인트 `f2b80444b439ad59a3870da3350a1385d388552a`. 문서 브랜치는 이 기준에서 시작한다. 아래는 현재 소스 경계의 설명이며 이번 문서 작업에서 새 빌드·제품 테스트를 실행한 결과가 아니다. 구현·과거 자동 검증·owner manual acceptance·게시 상태는 [ROADMAP의 현행 표](ROADMAP.md#현행-기능과-검증-경계)에서 구분한다.

`.ontheframe`은 D-023의 버전 있는 JSON이다. 아래 형식 표에는 FX 브랜치의 Format 11 Spectrum 저장 계약을 반영했다. [Softness 계약](DECISIONS.md#2026-11-19-spectrum-softness-모델과-저장-계약)

| 경로/내용 | 현행 동작 | 경계 |
|---|---|---|
| 앱 열기 | `ProjectStore` → `ProjectPersistence.decode` → `OperationalProjectAdapter` → image-aware codec. 유효한 legacy 1–8과 형식 9–11을 해당 schema에 따라 복원한다 | 지원 렌더 설정·형식별 구조/값 검사와 원본 접근 확인을 거친다. 저장된 이미지 metadata는 현재 접근/렌더 승인 증거가 아니며, 파일을 읽는 능력이 이미지 gate나 public Export를 켜지 않는다 |
| 앱 저장·실제 Spectrum 항목 있음 | 이미지 유무와 무관하게 Format 11. Softness 0은 appearance v2, 1–100은 v3 | Inside RGB, 공통 alpha, Outside RGB, Hue, 반응 강도와 기존 milli 정밀도를 보존한다. Softness 기능은 v1.1로 유보돼도 저장된 양수 값을 지우지 않는다 |
| 앱 저장: 이미지 catalog 있음, 실제 Spectrum 항목 없음 | 9 | 이미지 원본 참조·종류/metadata를 보존한다. 이미지마다 가짜 duration/frameCount/영상 트랙을 저장하지 않는다 |
| 앱 저장: 이미지도 실제 Spectrum 항목도 없음 | 빈 Spectrum 레인 또는 소리 계보가 있으면 8, 그 밖은 켜진 자막 효과 7 / 자막·자막 레인 6 / 자막 없음 5 | 콘텐츠에 맞는 형식을 고르며, 새 스키마 값이 있는 문서를 더 낮은 형식으로 조용히 저장하지 않는다 |
| raw `ProjectFile.decode` | temporal 문서의 1–8과 조건에 맞는 10·11을 읽는다 | 형식 9와 이미지 `kind`/`image`를 가진 문서는 이미지 인식 경로를 사용한다 |
| raw `ProjectFile.encode` | 지원되는 temporal Timeline의 내용에 따라 5/6/7/8/11 선택 | 이미지 catalog의 저장은 위 application persistence/image-aware 경로를 사용한다 |

근거 소스: [ProjectPersistence](../app/Engine/Sources/OnTheFrameEngine/ProjectPersistence.swift), [ProjectFile](../app/Engine/Sources/OnTheFrameEngine/ProjectFile.swift), [OperationalProjectAdapter](../app/Engine/Sources/OnTheFrameEngine/OperationalProjectAdapter.swift), [StillImageProjectCodec](../app/Engine/Sources/OnTheFrameEngine/StillImageProjectCodec.swift). 형식 5/6/7/8/9의 과거 결정·검증 기록은 각각의 도입 이정표로 보존한다. legacy 파일의 의미를 복원하는 것과 이전 앱이 최신 문서를 읽는 것은 다르다. 임의의 파일·렌더 설정·원본 상태까지 호환된다고 보장하지 않는다.

| 기능 | 현행 구현/노출 경계 |
|---|---|
| 영상·오디오·타임라인 | 기존 가져오기·여러 레인·트림/분할/이동/복사/붙여넣기/삭제·Undo/Redo 경로가 있다. 영상·소리의 기존 비리플 배치/리플 명령 의미를 유지한다 |
| 이미지 | `DEBUG && OTF_IMAGE_IMPORT`와 `-OTFEnableImageImport`가 모두 필요한 제한된 가져오기·등록/명시적 + 배치·편집·Preview다. 일반 Debug가 자동으로 켜지는 기능도 public Release 지원도 아니다. 파일 8 MiB·각 변 4096 px·총 16,777,216픽셀과 검증된 주영상/색상 정책 범위다. 원본 descriptor·소스는 보존하지만 일시적 검증/Preview 표현은 최대 변 2048 px proxy를 사용하므로 전체 원본 해상도의 4K Preview/Export 지원 주장과 구분한다. 지원 Display P3는 원본을 보존하고 Preview 작업 표현을 sRGB로 변환하며, HDR 출력·임의 프로필 지원을 뜻하지 않는다 |
| 자막 | 기존 생성·직접 편집·타이밍/모양·효과·Undo/Redo와 일반 자막 Export 경로가 있다. 완전한 모든 Preview/Export parity를 입증했다는 뜻은 아니다 |
| Spectrum | 만들기는 2026-11-23부터 Debug·Release 공통이다(오디오 클립 문맥 메뉴, 클립 조정 패널 단추 — Debug 자동 검증 통과, 소유자 수동 확인 9/9 PASS, 실제 Release 구성 빌드 없음, [결정](DECISIONS.md#2026-11-23-공개-spectrum-만들기저장-형식-안내내보내기-사전-차단) · [체크포인트](DECISIONS.md#2026-11-23-공개-spectrum-ux-체크포인트소유자-수동-99-pass)). Spectrum 항목이 있는 프로젝트는 형식 11로 저장되며 처음 올릴 때 확인을 받는다. 기존 항목 고르기/소스/편집, Digital/Analog, 선택 소스 계보, 정수 UI와 직접 numeric scrubbing을 별도로 구분한다. 유효하게 완료된 Digital 0높이는 기존 위치/밴드 수/두께/색/알파의 최소 원이며 missing/pending/stale나 비활성 항목의 대체 그림이 아니다 |
| Preview 전환 | temporary timing nil의 유효 작업 보존과 generation/session에 묶인 이미지 reconstruction 중 Play 의도 처리가 구현됐다. 새 frame/source/정확 PTS 검사를 통과해야 표시·재생하며 과거 그림을 현재로 취급하지 않는다. owner 수락은 시험한 조건에 한정한다 |
| Export | 일반 영상/소리/자막 Export, gate가 켜진 제한된 내부 이미지 Export, 내부 Debug Spectrum slice는 서로 다른 경로다. **public Spectrum Export는 비활성**이며 내부 공유 renderer·제한된 래스터 비교가 전체 parity나 공개 지원을 뜻하지 않는다. 소리 파일만의 Preview가 일반 검정 영상 Export 지원 승인인 것도 아니다 |

근거: [ProjectStore](../app/OnTheFrame/ProjectStore.swift), [Spectrum numeric control](../app/OnTheFrame/SpectrumNumericField.swift), [shared Spectrum renderer](../app/Engine/Sources/OnTheFrameEngine/SpectrumRenderer.swift), [ExportService](../app/Engine/Sources/OnTheFrameEngine/ExportService.swift). 공개 여부는 데이터 형식만으로 판단하지 않는다. Native Inspector **7 FAIL/4 SKIP**, 내부 Undo/Redo Seek 지연 조사, 장시간·다른 하드웨어·전체 Preview/Export parity 미검증과 public Spectrum Export 비활성은 유지한다.

### Spectrum 버전 범위 (소유자 결정, 2026-11-20)

[Softness v1.1 유보 결정](DECISIONS.md#2026-11-20-spectrum-softness-v11-유보)에 따른 구분이다. v1.1은 목표이며 출시 약속이 아니다.

| 구분 | 내용 |
|---|---|
| v1.0 필요 | 기존 Digital·Analog Spectrum, 색상·Hue, 위치·크기, 오디오 반응, 정확한 오디오 동기화, 안정적인 기본 Spectrum Preview, 기본 Spectrum Export 통합, 핵심 편집기 완성. **기본 Spectrum Export는 미완료**(공개 Export 비활성) |
| 구현됐으나 미검증 | `feature/spectrum-effects`의 `f208e2c`: Softness 모델·Format 11 appearance v3 저장, DEBUG 전용 Digital Softness Preview pilot, DEBUG 전용 요청 시간 계측, Feather 최적화 A와 oracle 시험. 컴파일·시험하지 않았고 pilot은 제품 기능이 아니다 |
| v1.1로 유보 | Softness 정수 0–100, Digital 안쪽 feather, Analog 바깥 feather 재검토, 성능 최적화, Inspector 통합, Preview·Export 일치, 저장 호환 검증. 앞서 유보한 UX-02도 계획된 v1.1이다 |
| 향후 후보 | SPECTRUM-SHADOW-01 등 기존 미승인 제안. 이 결정으로 승인되지 않는다 |

**2026-11-21 재생 안정화 경계.** v1.0의 "안정적인 기본 Spectrum Preview" 중 이미지 없는 영상 기반 프로젝트의 재생 시작·반복 영상 프레임·자연 종료는 소유자 실제 MP4 한 종류에서 수락됐다([기록](DECISIONS.md#2026-11-21-fx-02c-재생-안정화-실제-mp4-수락)). 모든 영상 형식(여러·앞쪽 자르기 편집 목록, VFR, 24/25 fps 등)이나 이미지 기반 Spectrum 재생 깜박임의 해결을 뜻하지 않는다. Digital Hue 보간의 저진폭 점은 별도 OPEN 시각 품질 문제다([기록](DECISIONS.md#2026-11-21-digital-spectrum-hue-보간의-저진폭-점open)).

**2026-11-22 이미지 기반 재생·Pause 경계.** 시험한 정지 이미지 + 오디오 프로젝트의 재생 시작·자연 종료와, 이미지·영상 프로젝트의 수동 Pause 깜박임은 소유자 수동 시험에서 PASS였다([기록](DECISIONS.md#2026-11-22-fx-02c-이미지-기반-재생과-수동-pause-안정화-체크포인트)). 빠른 Pause → Play의 자동 측정 공백과 간헐적 MP4 프레임 지연은 미해결이며, 모든 이미지·영상 조건의 수락을 뜻하지 않는다.

v1.0에서 저장된 양수 Softness는 보이지 않게 보존되며, 이후 Softness가 켜지면 렌더 결과를 바꿀 수 있다. 이는 활성화 단계의 호환·UX 검토 사항이며 현재 동작을 바꾸는 승인이 아니다.

## 1. 개요

- 제품명: ON THE FRAME / 온더프레임
- 플랫폼: macOS 데스크톱 앱
- 현행 방향: macOS **Composition-first Music Visual Editor**. 음악을 중심으로 이미지·영상·오디오를 배치하고 합성하며 자막·오디오 반응형 Spectrum·Preview·최종 영상 Export를 연결한다(2026-11-17 DOC-ALIGN-01).
  - 기존 음악·플레이리스트 제작과 기본 컷 편집(PD-04)을 이 주된 흐름으로 정렬한다. 전체 Composition 시스템이 이미 구현됐다는 뜻이 아니며 현재 기능 gate와 검증 범위는 위 표를 따른다.
  - After Effects는 Composition 편집 개념·Audio Spectrum 속성·숫자 컨트롤과 편집 경험의 참고다. 전체 기능·완전 호환이나 첫 릴리스 기능 집합을 약속하지 않는다. 고급 전환은 **Deferred**다([방향 보완](DECISIONS.md#2026-11-17-doc-align-01-현행-방향과-문서-정렬)).

## 2. 제품 방향과 지원 목표 (소유자 확인, 2026-10-09)

### 2.1 제품 방향

| ID | 내용 | 해석 범위 |
| --- | --- | --- |
| PD-01 | 처음에는 소유자의 Mac에서 쓰는 개인용 앱으로 시작한다. | 초기 사용자는 소유자 1명. 초기 구현에 라이선스 인프라(활성화, 결제, 업데이트 권한 관리)를 넣지 않는다(D-017) |
| PD-02 | 개인 사용이 성공하면 다른 사용자에게 상업적으로 배포한다. | 향후 방향. "성공"의 기준, 시기, 배포 채널, 소스 코드 라이선스, 활성화, 업데이트 권한, 결제 처리는 미정(Q-08, Q-14~Q-18) |
| PD-03 | 가격 아이디어: 약 20,000원, 일회 구매, 평생 라이선스. | **잠정 아이디어이며 확정 가격이 아니다.** "평생 라이선스"의 권리 범위(메이저 업데이트 포함 여부 등)는 미정(Q-17, Q-19). 가격은 기능 범위를 승인하거나 정하지 않는다 |
| PD-04 | 음악·플레이리스트 영상 제작과 일반 컷 편집을 모두 지원한다. | 2026-10-09 방향은 보존하며, 2026-11-17 DOC-ALIGN-01의 음악 중심 합성을 주된 흐름으로 보완한다. 여러 레인·리플 명령의 기존 승인은 유지한다. 그 밖의 일반 컷 편집 추가 범위는 Q-13, 고급 전환은 Deferred다 |

### 2.2 지원 목표 (미입증)

아래는 **목표**다. 실험과 테스트로 확인되기 전에는 "지원한다"고 주장하지 않는다. 검증 계획은 [EXPERIMENT-PLAN.md](EXPERIMENT-PLAN.md)에 있다.

| ID | 목표 | 정해지지 않은 것 |
| --- | --- | --- |
| T-01 | 최대 3시간 길이의 프로젝트를 편집하고 내보낼 수 있다. | 3시간에서의 성능 기준(내보내기 시간, 프리뷰 반응성), 필요한 디스크 공간 안내 방식(Q-09) |
| T-02 | 4K 편집과 내보내기를 제품 목표에 포함한다. | 4K의 정확한 크기(3840×2160 / 4096×2160), 프레임레이트, 코덱, HDR·색 처리 정책, 입력 포맷(Q-03, Q-04). **"4K 지원"은 4K60이나 HDR의 승인이 아니다** |

최소 macOS 버전과 CPU 지원 범위도 미정이다(Q-01).

## 3. 목표

1. 음악 중심의 이미지·영상·오디오 합성 흐름에 기본 편집, 오디오 반응형 Spectrum, 수동 자막, Preview와 최종 영상 Export를 제공한다. 기존 컷 편집 의미는 유지하되 전체 Composition/After Effects 기능이 구현됐다고 주장하지 않는다.
2. 프리뷰와 내보낸 영상이 구성·타이밍 면에서 일치하도록 한다.
3. 원본 미디어를 보호하는 비파괴 편집을 보장한다.
4. 지원 목표 T-01(3시간), T-02(4K)를 단계적 실험으로 검증한 뒤에만 지원 범위로 선언한다.

### 비목표

- After Effects 전체를 대체하는 범용 모션 그래픽 도구. After Effects의 Audio Spectrum은 참고 대상일 뿐이다.
- 초기 구현의 라이선스·결제·활성화 인프라 (D-017).

## 4. 주요 워크플로

괄호 안은 근거가 되는 요구사항 ID다.

1. **프로젝트 생성/열기** — 새 프로젝트를 만들거나 저장된 프로젝트를 연다. 원본 미디어가 누락되면 재연결한다. (R-41, R-42)
2. **미디어 가져오기** — 영상, 이미지, 오디오 파일을 추가한다. 원본 파일은 수정하지 않는다. (R-01, R-40)
3. **타임라인 편집** — 트림, 분할, 이동, 복사, 붙여넣기, 삭제와 undo/redo. 음악 영상과 일반 컷 편집 모두에 쓴다. (R-02, R-03, PD-04)
4. **스펙트럼 추가·편집** — 선택한 오디오 계보를 따르며 타임라인 전체 믹스와 구분한다. 기존 Digital/Analog·소스/스타일·정수 입력/scrubbing과 유효 0높이 점의 승인·구현은 유지한다. 만들기의 Debug gate와 공개 Export 차단, 남은 defaults/FX 결정은 현행 표·Q-05·Q-12에서 구분한다. (R-10, R-11, DR-09)
5. **자막 추가** — 자막을 직접 입력하고 타이밍, 폰트, 크기, 색상, 정렬, 위치를 지정한다. (R-20, R-21)
6. **프리뷰** — 합성 결과를 재생해 확인한다. (R-30, DR-01)
7. **내보내기** — 진행률 확인, 취소, 실패 처리. (R-31, DR-03, DR-04, DR-10)
8. **저장** — 프로젝트를 저장하고 다시 연다. (R-41)

## 5. 명시 요구사항 (원 brief)

"brief 근거"는 원 기획 brief의 해당 항목이다.

| ID | 요구사항 | brief 근거 |
| --- | --- | --- |
| R-01 | 영상, 이미지, 오디오를 가져올 수 있다. 지원 포맷은 미정(Q-03). | Import video/images/audio |
| R-02 | 타임라인에서 트림, 분할, 이동, 복사, 붙여넣기, 삭제를 할 수 있다. | Timeline editing, trim/split/move/copy/paste/delete |
| R-03 | 편집 작업은 undo/redo할 수 있다. | undo/redo |
| R-10 | 오디오 스펙트럼 시각화를 제공한다. After Effects의 Audio Spectrum을 참고하되 그 범위로 확장하지 않는다. | Audio spectrum visualization; AE reference |
| R-11 | 스펙트럼은 사용자가 선택한 오디오를 따른다. | follow the selected audio |
| R-12 | 오디오 클립을 트림하거나 이동한 뒤에도 스펙트럼은 해당 오디오와 동기화를 유지한다. | synchronized after trims/moves |
| R-20 | 자막은 사용자가 직접 입력한다. | Manually entered captions |
| R-21 | 자막은 타이밍, 폰트, 크기, 색상, 정렬, 위치를 조정할 수 있다. | timing, font, size, color, alignment, position |
| R-30 | 내보내기는 오디오, 자막, 스펙트럼을 포함하며, 프리뷰와 구성·타이밍이 일치해야 한다. | Export ... consistent with preview |
| R-31 | 내보내기는 진행률 표시, 취소, 실패 처리를 지원한다. | progress, cancellation, failure handling |
| R-40 | 비파괴 편집: 원본 미디어를 덮어쓰거나 삭제하지 않는다. | Non-destructive editing |
| R-41 | 프로젝트를 저장하고 다시 열 수 있다. 파일 포맷은 D-023(`.ontheframe` JSON, Q-06 해결). | Project save/reopen |
| R-42 | 원본 미디어가 누락되면 재연결(relink)할 수 있다. | source-media relinking |

### 5.1 소유자 승인 추가 요구사항

원 brief 뒤에 소유자가 명시적으로 승인한 요구사항이다. 원 brief에 있던 것으로 소급하지 않는다.

| ID | 요구사항 | 근거 |
| --- | --- | --- |
| R-50 | **화면 독립성(필수).** 지원하는 macOS 화면 환경(내장·외장, HiDPI·비 HiDPI, backing scale 1·2)에서 올바르게 동작하며, 사용자에게 특정 모니터·해상도·HiDPI 모드·backing scale·ICC 프로필을 고르게 하지 않는다. 편집 의미, Preview 기하(논리 좌표·물리 화소), 창 이동·화면 연결/분리 시 상태와 데이터 보존, 화면과 무관한 내보내기, 색 관리되는 Preview를 포함한다. 화면마다 같은 물리 휘도나 raw 화면 RGB를 요구하지 않는다. 내보내기 일관성은 파일 해시가 아니라 내용·시각·기하·색 메타데이터·허용 오차로 판단한다. 세부 항목 A–I와 검증 계획은 [DISPLAY-INDEPENDENCE.md](DISPLAY-INDEPENDENCE.md) | 소유자 승인 2026-11-27(SP-EXPORT-E4D-DISPLAY-INDEPENDENCE-107), [D-043](DECISIONS.md#2026-11-27-화면-독립성-제품-요구사항소유자-승인-sp-export-e4d-display-independence-107). 구현·검증 상태는 미검증(코드 감사만) |

## 6. 파생 요구사항 (소유자 미승인)

명시 요구사항을 충족하려면 필요하다고 Claude Code가 판단한 항목이다. **소유자가 별도로 승인한 요구사항이 아니다.** 검토 후 채택·수정·삭제할 수 있다.

이 절은 원 제안(P-005)의 출처를 유지한다. 이후 개별 작업에서 소유자가 승인한 내용은 [현행 결정 보완](DECISIONS.md#2026-11-17-doc-align-01-현행-방향과-문서-정렬)으로 연결하며 DR 목록 전체를 소급 승인하지 않는다.

| ID | 파생 요구사항 | 도출 근거 |
| --- | --- | --- |
| DR-01 | 편집 중 합성 결과를 재생하는 프리뷰가 있다. | R-30이 프리뷰의 존재를 전제함 |
| DR-02 | undo/redo는 자막·스펙트럼 편집에도 적용된다. | R-03 ("편집 작업")의 범위 해석 |
| DR-03 | 내보내기를 취소하거나 실패하면 불완전한 출력 파일을 최종 경로에 남기지 않고, 임시 파일을 정리하며, 원본 미디어는 변경하지 않는다. | R-31 + R-40 |
| DR-04 | 내보내기 실패 시 사용자에게 실패 사실과 확인 가능한 원인을 알린다. | R-31 "실패 처리" |
| DR-05 | 원 제안: 선택 소스의 트림 구간과 위치에서 원본 시각 `s_in + (t − t_start)`를 계산한다. **2026-11-17 색인 보완:** 계보·clip/lane 음량/음소거/페이드 반영은 후속 승인 범위다. FFT 창/offset·표본 대응과 실제 채널 결합 구현을 유지하며, 미래 FX·다중 소스 확대는 별도 결정(Q-12)이다. | R-11, R-12; 원 제안과 후속 개별 승인을 구분 |
| DR-06 | 선택 소스가 무음이거나 해당 시점에 선택 소스가 배치되어 있지 않으면 스펙트럼은 일관된 무음 상태(최소값)를 표시한다. | R-12 동기화의 경계 조건 |
| DR-07 | 자막은 한글을 올바르게 표시한다(프리뷰와 내보내기 모두). | 제품명·주 사용자 언어로부터 추정. UI 언어(Q-07)와는 별개 |
| DR-08 | 재연결 후에도 해당 미디어의 기존 편집 정보(트림, 위치 등)가 유지된다. | R-42 |
| DR-09 | 스펙트럼은 선택 소스만 반영한다. 타임라인의 다른(무관한) 오디오 트랙은 선택 소스에 연결된 스펙트럼에 영향을 주지 않는다. | R-11 "선택한 오디오"의 해석. 타임라인 전체 믹스와 구분 |
| DR-10 | 내보내기는 출력 경로의 기존 파일을 사용자 확인 없이 덮어쓰지 않고, 출력 경로가 원본 미디어 경로와 같으면 거부한다. 완료 전 취소·실패 시 기존 파일은 그대로 남는다. | R-40의 확장 해석 + R-31 |

## 7. 선택 후보 (첫 릴리스 요구사항 아님)

- 자동 자막 생성
- 고급 애니메이션
- 원형(circular) 스펙트럼 시각화

## 8. 열린 질문

결정되면 [DECISIONS.md](DECISIONS.md)에 기록한다. 기술 관련 항목의 검토 자료는 [TECHNOLOGY-EVALUATION.md](TECHNOLOGY-EVALUATION.md)와 [EXPERIMENT-PLAN.md](EXPERIMENT-PLAN.md)에 있다.

| ID | 질문 |
| --- | --- |
| Q-01 | 최소 macOS 버전과 지원 CPU 아키텍처 |
| Q-02 | 기술 스택과 아키텍처 |
| Q-03 | 입력 포맷과 출력 코덱/컨테이너 (4K 소스·출력 포함) |
| Q-04 | 내보내기 해상도, 프레임레이트, 색 처리, HDR 정책. T-02(4K)의 정확한 크기와 프레임레이트(4K60 포함 여부)도 여기서 정한다 |
| Q-05 | **일부 결정됨:** 기존 Digital/Analog·방향·정수 입력/직접 scrubbing·유효 0높이 점의 승인과 구현은 유지한다. 잠정 분석 기본값(D-S5)의 제품 확정 및 미래 FX/두 색/부드러움 등의 의미·범위는 열림 |
| Q-06 | **해결: D-023 및 후속 형식 승인.** 현행 최대 10, 콘텐츠별 저장과 application persistence/raw codec 차이는 [형식 표](#현행-프로젝트-형식과-기능-경계). 형식 5/6/7/8/9 이력은 보존 |
| Q-07 | UI 언어 (한국어, 영어 등) |
| Q-08 | 배포 방식과 라이선스 (총괄. 세부는 Q-14~Q-19) |
| Q-09 | 성능 기준. 길이 목표는 T-01(최대 3시간)로 정해졌으나, 내보내기 시간·프리뷰 반응성·디스크 사용 기준은 미정 |
| Q-10 | 접근성(VoiceOver, 키보드 조작 등) 지원 수준 — 기존 로드맵 초안에 근거 없이 포함되어 있던 항목을 질문으로 이동 |
| Q-11 | 프리뷰/내보내기 "일치"의 판정 기준(허용 오차) — R-30을 검증 가능한 기준으로 만들기 위해 필요 |
| Q-12 | **일부 결정됨:** 선택 단위는 오디오 계보이며 자르기 연결/복사 독립·clip/lane 음량/음소거/페이드 반영·로그 밴드를 유지한다. 현재 채널 에너지 평균 구현은 측정 근거와 구분한다. 미래 FX 처리 의미·다중 소스 연결/합산 확대·지원 범위의 확정은 열림 |
| Q-13 | 일반 컷 편집(PD-04)에 필요한 추가 기능 범위: 다중 비디오 트랙, 전환 효과, 리플/롤 편집, 클립 오디오 처리 등. 여러 레인(D-024), 빈틈·리플 삭제(D-020), 클립 음량·페이드(D-026)는 작업별로 정했고, 전환·롤 편집 등 나머지 범위는 미정 |
| Q-14 | 상업 배포 채널 (Mac App Store, 직접 배포 등) |
| Q-15 | 소스 코드 라이선스 (비공개, 오픈소스 등) |
| Q-16 | 활성화·라이선스 확인 방식 (상업 배포 시) |
| Q-17 | 업데이트 권한 범위 ("평생 라이선스"에 포함되는 업데이트) |
| Q-18 | 결제 처리 방식 |
| Q-19 | 최종 가격과 구매 권리 세부 (PD-03은 잠정 아이디어) |

2026-11-17 소유자가 정한 후속 **계획 순서**는 `SPECTRUM-UX-02 → SPECTRUM-FX-01 → SPECTRUM-FX-02 → SPECTRUM-SHADOW-01`이다. 아직 구현된 효과 목록이 아니며 각 기능의 착수·설계 범위는 별도 지시가 필요하다. 승인되지 않은 FX 파라미터를 이 순서로부터 만들지 않는다.
