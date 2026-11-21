# CLAUDE.md

이 파일은 ON THE FRAME(온더프레임)의 프로젝트별 작업 규칙이다. Claude Code와 Codex는 작업을 시작할 때 [공통 작업 절차](docs/AGENT-WORKFLOW.md)를 직접 열어 적용한다. Codex의 저장소 진입점은 [AGENTS.md](AGENTS.md)다.

## 역할 분담

- **사용자**: 제품 방향과 결정의 최종 승인자.
- **ChatGPT**: 사용자와 함께 기획하고 Claude Code의 보고를 검토한다.
- **Claude Code**: 사용자의 Mac에서 구현·문서 작업을 수행하고 결과를 보고한다.

Claude Code는 [docs/DECISIONS.md](docs/DECISIONS.md)에 "확정"으로 기록되지 않은 사항을 임의로 확정하지 않는다. 제안이 필요하면 "제안"으로 표시해 문서에 남기고 사용자 승인을 받는다. 리뷰어(ChatGPT)의 지적이나 제안을 반영할 때도, 소유자가 승인하지 않은 내용은 제안·파생 요구사항·열린 질문으로 기록하고 확정 결정으로 옮기지 않는다.

## 문서의 권위와 제품 방향

소유자의 명시적 승인 방향 → 이 파일의 저장소 작업 규칙 → DECISIONS의 최신 승인·정정 → ROADMAP의 현재 구현 상태 → PRODUCT의 요구사항 → 승인 설계 → 날짜가 붙은 역사적 진단 순으로 적용한다. 과거 제안을 승인으로 승격하지 않고, 이전 결정은 후속 amendment와 연결해 보존한다.

소유자 승인 방향(DOC-ALIGN-01, 2026-11-17)은 macOS **Composition-first Music Visual Editor**다. 음악 중심의 이미지·영상·오디오 구성, 자막·오디오 반응형 Spectrum, Preview와 최종 영상 내보내기에 집중한다. After Effects는 Composition 개념·Spectrum 속성·숫자 편집 경험의 참고이며 전체 기능이나 첫 출시 범위를 약속하지 않는다. 현재 완전한 Composition 시스템이 구현됐다고 쓰지 않으며 고급 전환은 유보한다.

## 현재 단계

- **현재 상태의 정본은 [docs/ROADMAP.md](docs/ROADMAP.md#현행-기능과-검증-경계)**와 §S, 짧은 인계는 [docs/HANDOFF.md](docs/HANDOFF.md)다. 구현·자동 검증 보고·소유자 수동 수락·커밋/게시·부분·미해결·미구현·유보를 구분한다. 결정 이력은 [docs/DECISIONS.md](docs/DECISIONS.md), 역사적 구현 기록은 [app/README.md](app/README.md)다.
- **2026-11-17 검증 기준:** 게시 feature는 `f2b80444b439ad59a3870da3350a1385d388552a`이며 문서 브랜치 `docs/audit-alignment-20261117`이 이 커밋에서 시작했다. local main `44943eadabdf5a37d5242d614e7279813126dfde`와 live remote main `fe79fd91997eebb951315a9e398942e6711ec2ae`를 구분하며 main을 자동 갱신하지 않는다. 이전 자막·Spectrum 체크포인트도 feature에 게시됐다. 형식은 [현행 persistence/codec 표](docs/PRODUCT.md#현행-프로젝트-형식과-기능-경계)를 따르며 새 스키마를 도입한 것이 아니다.
- 영상·오디오·자막·타임라인/Undo/Redo와 후속 Spectrum 편집·정수 scrubbing·valid-zero 점·Seek/image playback 수정은 구현돼 있다. 이미지 가져오기는 사용자 정의 Debug 빌드와 실행 인수 gate, Spectrum 생성은 Debug 전용이다. 공개 Spectrum Export는 비활성이며 내부 검증과 Release 지원을 혼동하지 않는다.
- 향후 스키마 변경은 명시적으로 버전을 올리고 이전 파일 읽기를 유지한다. 이번 문서 정렬은 형식·모델을 바꾸는 승인이 아니다.
- **2026-11-17 당시 개발 제안(DOC-ALIGN-01):** SPECTRUM-UX-02 → SPECTRUM-FX-01 → SPECTRUM-FX-02 → SPECTRUM-SHADOW-01. 당시 미구현으로 기록된 제안이다. 이후 브랜치별 구현·수락·유보 상태는 [인계](docs/HANDOFF.md)와 해당 브랜치의 로드맵에서 확인한다. D-028의 이전 순서와 P-010의 제안은 역사로 보존하며 P-001 전체 승인으로 해석하지 않는다. 범위가 승인된 작업만 한 번에 하나씩 진행한다.
- **단축키(D-019, D-027):** 대응 기능에는 흔히 쓰는 기본 단축키를 쓴다. 사용자에게 보이는 이름·도움말은 ON THE FRAME의 기능과 키로 설명하고 다른 회사 제품 비교 상표를 쓰지 않는다. 완전 호환을 주장하지 않는다. 더 넓은 도구·단축키는 각 기능과 함께 넣고(단축키만의 자리 표시 없음), 단축키 사용자 지정·프리셋은 없다. 텍스트 입력의 표준 편집 단축키를 가로채지 않고, 한국어 입력 소스에서도 키 코드로 같은 동작을 한다.
- **유지되는 제약:** 앱 자동 검증에는 짧은 생성 fixture와 일회용 폴더를 사용한다. 소유자 수동 시험에는 [지정 미디어와 격리 사본](docs/AGENT-WORKFLOW.md#소유자-데이터와-수동-시험) 규칙을 적용한다. 그 밖의 소유자 경로는 세션에서 허락받은 것만 사용하며 개인 폴더를 탐색하지 않는다. 실제 저장 패널을 자동으로 확인(저장)하지 않는다. FFmpeg 설치·새 의존성·개인 미디어 트랜스코딩은 하지 않는다.
- 빌드·임시 출력·실험 산출물에는 [앱 README의 관리 예산과 중지 조건](app/README.md#현재-실행-승인과-자원-안전)을 적용하고 고유 증거와 실행 가능한 Debug 앱을 보존한다. 크기 감시는 조기 경고일 뿐 강제 상한이 아니다. 2026-10-24 빌드 중 약 37 GB 컴파일 캐시 증가는 비정상·미해결이며, 그 두 실패 빌드의 명시적 모듈·캐시 덮어쓰기 설정을 다시 쓰지 않는다(기본 `app/scripts/build.sh` 설정 사용). 빌드 산출물은 외부 APFS 볼륨에 둔다(2026-11-21 소유자 정책, [결정](docs/DECISIONS.md#2026-11-21-빌드-산출물을-외부-apfs-볼륨으로)): DerivedData는 `/Volumes/Data/ON-THE-FRAME-Builds/DerivedData/<작업별 이름>`, 결과·로그는 `/Volumes/Data/ON-THE-FRAME-Builds/Results/<작업별 이름>`, 보관본은 `/Volumes/Data/ON-THE-FRAME-Archives/`다. 새 빌드에 내부 `~/Library/Developer/ON-THE-FRAME/`을 쓰지 않고, 볼륨이 없거나 쓸 수 없으면 내부 디스크로 대체하지 않고 멈춘다(`app/scripts/derived-data.sh`). DerivedData·Results는 예산에 포함하며 할당 크기로 센다. 보관본은 따로 측정하고 예산을 맞추려고 지우지 않는다. 전역 Xcode 설정은 바꾸지 않는다. 이전 내부 APFS 위치(2026-10-24 승인, 당시 데이터 볼륨 HFS+)는 이력이다. 저장소·원본 미디어·증거는 데이터 볼륨에 둔다.
- 출력은 FHD 30 fps SDR H.264/AAC MP4이며 ProRes·4K·MKV 등 넓은 호환은 목표로만 기록하고 지원을 주장하지 않는다. 자동 검사·코드 리뷰·소유자 정성 관찰을 구분해 보고하고, 부분 검증을 완료로 표시하지 않는다.
- 알려진 열린 문제(A-010 프리뷰 프레임 0 불일치, Native Inspector 7 FAIL/4 SKIP, 내부 Undo/Redo Seek 지연, 간헐 자체 검사 실패, 실제 MP3 미검증 등)는 [docs/ROADMAP.md](docs/ROADMAP.md) §S.6에 있다. 과거 ClipAudioTests 소리 비교 실패는 D-034의 기대값 정정·해당 회귀 기록과 구분한다. 그 정정을 새 전체 suite 통과로 확대하거나 다른 열린 문제를 근거 없이 닫지 않는다.
- **작업 승인: E1-a(A-001)·E1-b(A-002)는 완료(E1 완료 2026-10-10, 시험한 Mac의 짧은 FHD 통합 실험에 한함). E2(A-003, 2026-10-10)는 열린 정확도 결함 때문에 미완료이고, E3-1(A-004)은 완료(2026-10-10, 시험한 Mac의 10분 FHD 첫 실행에 한함).** 실험 코드는 [experiments/e1-fhd/](experiments/e1-fhd/), [experiments/e2-4k/](experiments/e2-4k/), [experiments/e3-fhd-10min/](experiments/e3-fhd-10min/)에만 둔다([docs/DECISIONS.md](docs/DECISIONS.md) §2.1). E3-2 이후 하위 단계 등 다른 단계는 별도 승인 전까지 시작하지 않는다.
  - E3-1: [docs/EXPERIMENT-PLAN.md](docs/EXPERIMENT-PLAN.md) §7.6의 10분 FHD 첫 실행. 1920×1080, 30fps, SDR, H.264/AAC, 생성 미디어만(짧은 소스 반복), 실제 소스 영상 디코딩·합성, 컷·자막·선택 오디오 스펙트럼, E2 방식의 공유 composition으로 프리뷰·내보내기, 대표 취소·실패·출력 보호. 검증한 10분 내보내기는 소유자 확인용으로 보관한다. 렌더링·분석·디코딩·검증은 스트리밍으로 하며 디코딩된 프레임 전체나 무압축 10분 영상을 남기지 않는다. 8 GiB footprint와 단계 시간 한도는 실험 중지 조건일 뿐이다. 60분·3시간 실행, 4K60, HDR, 디스크 부족 시뮬레이션, 개인 미디어는 허용하지 않는다. E2의 해결되지 않은 소스 프레임 불일치는 E3-1 진행으로 해소되지 않는다.
  - E2: 짧은 4K 컷 편집 실험. 3840×2160, 30fps, SDR, H.264/AAC, 최종 타임라인 10초, 생성 fixture만. 실제 소스 영상 디코딩·합성, 트림·분할·이동(비디오 트랙 1개 순차 하드 컷, 실험 범위), 자막 3개, 선택 오디오 스펙트럼, 같은 타임라인 해석의 프리뷰·내보내기, 출력 보호·취소·실패. E1 부품은 패키지 전체를 복제하지 않고 재사용한다. 실험 전용 최소 창 허용. 성능은 측정만 하고 제품 기준을 만들지 않는다. 60분·3시간 실행, 4K60, HDR은 허용하지 않는다.
  - E1-a: 헤드리스 FHD 합성·내보내기 실험과 짧은 검증 실행.
  - E1-b: 기존 렌더러·타임라인 모델·선택 소스 스펙트럼 캐시를 사용자 정의 합성기로 `AVPlayer`에 연결한 실제 프리뷰, 내보내기와의 비교, 필요한 E1-a 수정, 짧은 검증 실행. 실험 전용 최소 창(재생·일시정지·탐색)은 허용하며 제품 UI가 아니다.
  - 허용: Swift + AVFoundation/AVKit 실험 코드(잠정), 합성 fixture, 10초 FHD 수준의 짧은 내보내기·재생, 빌드·테스트 실행.
  - 산출물: 생성 fixture·캐시·출력·빌드 산출물은 데이터 볼륨의 각 실험 디렉터리 `artifacts/`, `.build/`에 두고 Git에서 무시한다. 실험 소유 산출물과 앱 빌드·검증 산출물의 할당량을 합산하고 [관리 예산](app/README.md#현재-실행-승인과-자원-안전)을 넘기 전에 멈춰 보고한다. 시스템 캐시를 옮기거나 전역 설정(화면 기록 권한 포함)을 바꾸지 않는다. 외부 미디어를 쓰지 않는다.
  - 허용하지 않음(실험 코드 안에서): 제품 앱 UI, 프로젝트 저장, E2 범위 밖의 4K, E3-1 범위(10분)를 넘는 긴 내보내기·재생, 라이선스 인프라, 도구 설치, commit·push·merge.
  - 소유자 관찰이 필요한 항목이 남아 있는 동안 그 실험(E1, E2, E3-1)을 완료로 선언하지 않는다. "실행 완료"(계획한 측정을 했거나 이유와 함께 멈춤)와 "정확도 통과"(관련 정확도 검사 통과)를 구분하고, 정확도 실패가 있는 실행을 성공한 검증이라고 하지 않는다. 성능 측정값은 제품 기준 없는 기록(RECORD)이다.
  - A-001~A-004는 P-001~P-006 승인이나 기술 스택·플랫폼 정책 확정이 아니다. E3-2 이후 단계는 별도 승인을 받고, 승인 범위에 맞게 이 절을 갱신한 뒤 진행한다. 승인 범위를 넘는 코드는 만들지 않는다.
- 기술 스택, 최소 macOS 버전, 입출력 포맷 정책, 성능 기준, 배포 방식, 라이선스는 미정이다. 프로젝트 파일 포맷은 D-023으로 정해졌다([docs/DECISIONS.md](docs/DECISIONS.md) 참조).
- 기술 비교와 잠정 추천은 [docs/TECHNOLOGY-EVALUATION.md](docs/TECHNOLOGY-EVALUATION.md), 단계별 실험 계획은 [docs/EXPERIMENT-PLAN.md](docs/EXPERIMENT-PLAN.md)에 있으며, 모두 제안일 뿐 확정이 아니다.
- 소유자 확인 방향(2026-10-09): 개인용으로 시작, 성공 시 상업 배포, 최대 3시간·4K는 지원 목표(미입증). 초기 구현에 라이선스 인프라를 넣지 않는다([docs/DECISIONS.md](docs/DECISIONS.md) D-011~D-017). 검증 전에는 3시간·4K 지원을 주장하지 않는다.

## 작업 흐름

빌드·제품 검사 전에는 [현재 실행 승인과 자원 안전](app/README.md#현재-실행-승인과-자원-안전)의 한도와 중지 조건을 모두 적용하는 절차를 선택한다. `build.sh`의 모듈·캐시 설정을 쓰더라도 별도 감시가 필요하다. 문서 전용 작업에서는 제품 빌드·검사를 실행하지 않는다.

1. [Git 사전 확인](docs/AGENT-WORKFLOW.md#git-사전-확인)을 실행하고 작업에 허용된 행동과 경로를 대조한다.
2. 편집할 파일은 먼저 읽고, 관련 문서([docs/PRODUCT.md](docs/PRODUCT.md), [docs/DECISIONS.md](docs/DECISIONS.md), [docs/ROADMAP.md](docs/ROADMAP.md))를 확인한다.
3. 요청 범위 안에서만 변경한다. 범위 밖의 개선은 제안으로만 보고한다.
4. 결정이 내려지면 [docs/DECISIONS.md](docs/DECISIONS.md)를 갱신하고, 영향을 받는 다른 문서도 함께 맞춘다.
5. 요구사항은 출처를 구분한다: 소유자 brief에 명시된 것은 `R-`, Claude Code가 도출한 것은 `DR-`(소유자 미승인)로 기록한다. 파생 요구사항을 소유자가 승인한 것처럼 쓰지 않는다.

## 사용자 변경 보호

- 기존 사용자 변경(커밋되지 않은 수정, untracked 파일)을 덮어쓰거나 되돌리거나 삭제하지 않는다.
- `git reset --hard`, `git checkout -- <path>`, `git clean`, 강제 push 등 파괴적 명령은 사용자의 명시적 요청 없이 실행하지 않는다.
- 편집·스테이징·커밋·게시를 포함한 Git 작업은 [작업별 권한](docs/AGENT-WORKFLOW.md#작업별-권한)에 따라 수행한다. 저장소 설정·공개 범위 변경은 사용자가 요청할 때만 수행한다.
- 커밋은 저장소에서 확인한 소유자의 유효 Author/Committer identity를 사용한다(`git var GIT_AUTHOR_IDENT`, `git var GIT_COMMITTER_IDENT`로 확인). AI co-author trailer를 추가하거나 저자 귀속을 꾸며내지 않는다. 기존 공개 공동저자 이력은 별도 변경 승인 없이 수정하지 않으며, 문서 정정으로 GitHub Contributors 표시가 제거된다고 주장하지 않는다.
- 자격 증명·토큰을 출력하거나 파일에 저장하지 않는다.
- 커밋되는 문서에 사용자 이름, 기기 식별자, 불필요한 개인 경로를 남기지 않는다.

## 제품 원칙 (구현 시 지켜야 할 것)

- 비파괴 편집: 원본 미디어를 덮어쓰거나 삭제하지 않는다.
- 프리뷰와 내보내기는 구성과 타이밍(오디오, 자막, 스펙트럼 포함)이 일치해야 한다.
- After Effects는 Composition 편집 개념·Audio Spectrum 속성·숫자 조작 경험의 참고다. 전체 대체나 첫 출시의 전체 기능 구현 계획을 뜻하지 않는다.

## 검증 및 보고 규칙

문서·코드 검증과 한국어 보고는 [검증과 보고](docs/AGENT-WORKFLOW.md#검증과-보고)를 따른다. 실제로 확인하거나 실행한 결과와 가정·미검증 항목을 구분한다.

## 문서

| 문서 | 내용 |
| --- | --- |
| [README.md](README.md) | 제품 개요, 기획 현황, 문서 링크 |
| [docs/PRODUCT.md](docs/PRODUCT.md) | 제품 방향·지원 목표, 주요 워크플로, 명시·파생 요구사항, 열린 질문 |
| [docs/DECISIONS.md](docs/DECISIONS.md) | 확정 결정 / 제안 / 미결정 사항 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 현재 상태 체크리스트(정본, §S)와 제안 개발 단계·완료 기준 |
| [docs/HANDOFF.md](docs/HANDOFF.md) | 짧은 인계 요약: 기준 커밋·브랜치, 알려진 문제, 다음 작업, 정본 문서 링크 |
| [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) | 관찰된 개발 환경 |
| [docs/TECHNOLOGY-EVALUATION.md](docs/TECHNOLOGY-EVALUATION.md) | 기술 방식 비교, 잠정 추천, macOS/CPU 정책 제안, 초기 통합 실험(E1) 상세 |
| [docs/EDITOR-PLAN.md](docs/EDITOR-PLAN.md) | 편집기 UI 첫 계획(화면 배치, 조작, 첫 마일스톤 M1, 엔진 재사용, 앱 구조 제안 — 미승인) |
| [app/README.md](app/README.md) | 현재 실행 승인·자원 안전과 역사적 구현·검증 기록 |
| [docs/diagnostics/A-010-preview-frame0.md](docs/diagnostics/A-010-preview-frame0.md) | A-010 프리뷰 경로 프레임 0 불일치 진단 요약(미해결, 재현 기록·확인된 사실·가설) |
| [docs/EXPERIMENT-PLAN.md](docs/EXPERIMENT-PLAN.md) | 단계별 실험 계획(E1 FHD → E2 4K → E3 3시간), 메모리·디스크 구조 제안, 승인 구분 |
| [experiments/e1-fhd/README.md](experiments/e1-fhd/README.md) | E1 실험(E1-a 내보내기, E1-b 프리뷰) 코드 구성, 재현 명령, 결과·증거 경계, 소유자 관찰 체크리스트, 한계 |
| [experiments/e3-fhd-10min/README.md](experiments/e3-fhd-10min/README.md) | E3-1 실험(10분 FHD) 코드 구성, 재현 명령, 결과·증거 경계, 소유자 확인, 한계 |
| [experiments/e2-4k/README.md](experiments/e2-4k/README.md) | E2 실험(짧은 4K 컷 편집) 코드 구성, 재현 명령, 결과·증거 경계, 열린 결함, 소유자 관찰 체크리스트, 한계 |
