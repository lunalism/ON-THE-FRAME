# ON THE FRAME (온더프레임)

A macOS Composition-first Music Visual Editor.

ON THE FRAME은 음악을 중심으로 이미지·영상·오디오를 배치하고, 자막과 오디오 반응형 Spectrum을 더해 Preview와 최종 영상 내보내기로 연결하는 macOS Composition-first Music Visual Editor다. 현재 구현은 타임라인 기반 편집기이며 완전한 Composition 시스템이 구현된 상태는 아니다.

## 핵심 기능 (기획 brief 명시 요구사항)

- 영상·이미지·오디오 가져오기, 타임라인 편집(트림, 분할, 이동, 복사, 붙여넣기, 삭제), 실행 취소/다시 실행
- 오디오 스펙트럼 시각화 (After Effects의 Audio Spectrum을 참고)
- 수동 입력 자막 (타이밍, 폰트, 크기, 색상, 정렬, 위치)
- 영상 내보내기 (진행률, 취소, 실패 처리)
- 비파괴 편집, 프로젝트 저장/다시 열기, 누락 미디어 재연결

자세한 내용과 각 요구사항의 출처 구분(명시/파생)은 [docs/PRODUCT.md](docs/PRODUCT.md)를 참조한다.

## 제품 방향 (소유자 확인, 2026-11-17 DOC-ALIGN-01)

- 음악 중심의 영상 구성과 편집을 우선한다. After Effects는 Composition 편집 개념·Audio Spectrum 속성·숫자 조작 경험의 참고이며, 전체 기능을 구현했거나 첫 출시 범위로 계획했다는 뜻이 아니다. 고급 전환 효과는 유보한다.
- 처음에는 소유자의 Mac에서 쓰는 개인용 앱으로 시작하고, 성공하면 상업 배포를 검토한다. 배포 채널, 라이선스, 활성화, 업데이트 권한, 결제는 미정이다.
- 가격 아이디어(약 20,000원, 일회 구매·평생 라이선스)는 잠정이며 확정이 아니다.
- 최대 3시간 프로젝트와 4K 편집·내보내기는 **지원 목표**다. 아직 구현·검증되지 않았다. 4K의 프레임레이트·HDR 등 세부는 미정이다.

## 현재 상태

**2026-11-18 게시된 main 기준:** `90ce4db48ea07e216afe709a5f920628f005eb2a`에 Spectrum 체크포인트와 문서 정렬이 통합됐다. 아래 기능 설명은 이 게시본 기준이다. 로컬 개발 브랜치의 구현·수락 범위는 [날짜별 인계](docs/HANDOFF.md), 기능별 검증 기록은 [로드맵](docs/ROADMAP.md#현행-기능과-검증-경계), 저장·읽기 경계는 [형식 표](docs/PRODUCT.md#현행-프로젝트-형식과-기능-경계)를 참조한다.

- **편집기([app/](app/)):** 영상·오디오 가져오기, 여러 레인·연결·트림·분할·이동·복사/붙여넣기·Undo/Redo, 영상 변형·오디오 gain/mute/fade, 자막·효과·자막 포함 FHD 30 fps SDR H.264/AAC MP4 내보내기, 프로젝트 저장/열기·재연결이 구현돼 있다. `.ontheframe`은 콘텐츠와 경로에 따라 형식을 선택한다(자막·효과·소리 계보·이미지·Spectrum 유무에 따라 정해진다). 현재 앱이 읽고 쓰는 최신 형식은 Format 11이며 실제 Spectrum 항목이 있을 때 쓴다([형식 표](docs/PRODUCT.md#현행-프로젝트-형식과-기능-경계)).
- **이미지:** 사용자 정의 Debug 빌드 조건과 명시적 실행 인수가 필요한 내부 경로다. 한정된 고해상도·Display P3 입력을 허용하고 Preview 표현을 sRGB로 정규화하지만, 임의 해상도·모든 이미지·공개 Release 지원을 뜻하지 않는다.
- **Spectrum:** 생성은 2026-11-23부터 Debug·Release 공통이다(오디오 클립 문맥 메뉴와 클립 조정 패널 단추 — Debug 자동 검증 통과, 소유자 수동 확인 9/9 PASS, 실제 Release 구성 빌드는 아직 없음, [인계](docs/HANDOFF.md)). 기존 항목 편집·소스 계보·Digital/Analog·정수 숫자와 직접 mouse scrubbing·live Preview·Undo/Redo가 구현돼 있다. 유효하게 완료된 Digital 0높이 분석은 밴드별 최소 점을 그린다. Seek 연속성과 이미지 재구성 중 playback intent 수정도 게시됐다. **공개 Spectrum Export는 비활성**이며 내부 공유 렌더링 검증과 구분한다.
- **수락과 게시:** scrubbing과 ZERO의 소유자 수락은 각각 시험한 조건의 **6/6 PASS**이며 관련 체크포인트는 feature에 게시됐다. 이전 자동 검증·소유자 수락·커밋/푸시는 서로 다른 상태다. 이번 문서 작업에서 제품 검사를 재실행하지 않았다.
- **후속 개발:** 2026-11-17에 제안한 순서는 `SPECTRUM-UX-02 → SPECTRUM-FX-01 → SPECTRUM-FX-02 → SPECTRUM-SHADOW-01`이었다. 이후의 UX-02 유보와 로컬 FX 진행 상태는 인계에 기록했다.
- **실험:** E1(짧은 FHD)과 E3-1(10분 FHD)은 각 실험 범위에서 완료, E2(짧은 4K)는 원본 프레임 불일치로 미완료다. E3-2 이후는 시작하지 않았고 과거 실험의 통과가 현재 제품 전체의 수락은 아니다.
- **지원 목표:** 최대 3시간 프로젝트와 4K는 받아들인 지원 목표이며 아직 입증되지 않았다.
- **미정:** 기술 스택 확정, 최소 macOS 버전, 입출력 포맷 정책, 성능 기준, 배포 방식, 라이선스. 상업 배포는 개인 사용이 성공한 뒤에만 검토하고, 활성화·결제·라이선스 인프라는 개인 사용 단계에 넣지 않는다.
- **열린 제한:** Native Inspector 7 FAIL/4 SKIP, 내부 Undo/Redo Seek 지연 조사, 장시간·다른 하드웨어·전체 Preview/Export parity 미검증은 유지한다. A-010·그 밖의 기존 문제도 [ROADMAP §S.6](docs/ROADMAP.md#s6-프로젝트-보호안정화-단계-6--열린-문제-목록)을 따른다. 빌드·시험은 [현재 실행 승인과 자원 안전](app/README.md#현재-실행-승인과-자원-안전)에 맞는 절차를 먼저 선택해야 한다.

## 문서

- [docs/PRODUCT.md](docs/PRODUCT.md) — 제품 방향·지원 목표, 주요 워크플로, 명시·파생 요구사항, 열린 질문
- [docs/DECISIONS.md](docs/DECISIONS.md) — 확정 결정, 제안, 미결정 사항
- [docs/ROADMAP.md](docs/ROADMAP.md) — 현재 상태 체크리스트(정본, §S)와 제안 개발 단계·완료 기준
- [docs/HANDOFF.md](docs/HANDOFF.md) — 짧은 인계 요약(기준 커밋, 브랜치, 알려진 문제, 다음 작업)
- [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) — 관찰된 개발 환경
- [docs/TECHNOLOGY-EVALUATION.md](docs/TECHNOLOGY-EVALUATION.md) — 기술 방식 비교, macOS/CPU 정책 제안, 초기 통합 실험(E1) 상세
- [docs/EDITOR-PLAN.md](docs/EDITOR-PLAN.md) — 편집기 UI 첫 계획(화면 배치, 조작, 첫 마일스톤, 엔진 재사용, 앱 구조 제안 — 미승인)
- [app/README.md](app/README.md) — 승인된 실행 절차의 경계와 역사적 구현·검증 기록
- [docs/diagnostics/A-010-preview-frame0.md](docs/diagnostics/A-010-preview-frame0.md) — A-010 프리뷰 경로 프레임 0 불일치 진단 요약(미해결)
- [docs/EXPERIMENT-PLAN.md](docs/EXPERIMENT-PLAN.md) — 단계별 실험 계획(FHD → 4K → 3시간), 메모리·디스크 구조 제안
- [experiments/e1-fhd/README.md](experiments/e1-fhd/README.md) — E1 실험 재현 명령, 결과, 소유자 관찰 체크리스트, 한계
- [experiments/e3-fhd-10min/README.md](experiments/e3-fhd-10min/README.md) — E3-1 실험(10분 FHD) 재현 명령, 결과, 메모리·디스크 측정, 소유자 확인, 한계
- [experiments/e2-4k/README.md](experiments/e2-4k/README.md) — E2 실험(짧은 4K 컷 편집) 재현 명령, 결과, 열린 결함, 소유자 관찰 체크리스트, 한계
- [AGENTS.md](AGENTS.md) — Codex 시작 지침과 필수 읽기 순서
- [CLAUDE.md](CLAUDE.md) — 프로젝트별 승인·작업 규칙
- [공통 작업 절차](docs/AGENT-WORKFLOW.md) — Git 사전 확인, 작업별 권한, 소유자 데이터, 검증과 작업 프롬프트

## 라이선스

미정. ([docs/DECISIONS.md](docs/DECISIONS.md) 참조)
