# ON THE FRAME (온더프레임)

A macOS video editor for timeline editing, audio spectrum visualization, subtitles, and video export.

ON THE FRAME은 음악·플레이리스트 영상 제작과 일반 컷 편집을 위한 macOS 데스크톱 영상 편집기다. 영상·이미지·오디오를 타임라인에서 편집하고, 선택한 오디오를 따라 움직이는 오디오 스펙트럼과 수동 입력 자막을 얹어 영상으로 내보내는 것을 목표로 한다.

## 핵심 기능 (기획 brief 명시 요구사항)

- 영상·이미지·오디오 가져오기, 타임라인 편집(트림, 분할, 이동, 복사, 붙여넣기, 삭제), 실행 취소/다시 실행
- 오디오 스펙트럼 시각화 (After Effects의 Audio Spectrum을 참고)
- 수동 입력 자막 (타이밍, 폰트, 크기, 색상, 정렬, 위치)
- 영상 내보내기 (진행률, 취소, 실패 처리)
- 비파괴 편집, 프로젝트 저장/다시 열기, 누락 미디어 재연결

자세한 내용과 각 요구사항의 출처 구분(명시/파생)은 [docs/PRODUCT.md](docs/PRODUCT.md)를 참조한다.

## 제품 방향 (소유자 확인, 2026-10-09)

- 처음에는 소유자의 Mac에서 쓰는 개인용 앱으로 시작하고, 성공하면 상업 배포를 검토한다. 배포 채널, 라이선스, 활성화, 업데이트 권한, 결제는 미정이다.
- 가격 아이디어(약 20,000원, 일회 구매·평생 라이선스)는 잠정이며 확정이 아니다.
- 최대 3시간 프로젝트와 4K 편집·내보내기는 **지원 목표**다. 아직 구현·검증되지 않았다. 4K의 프레임레이트·HDR 등 세부는 미정이다.

## 현재 상태

**기획·실험 단계에서 편집기를 만드는 중이다(2026-10-11).** 정본 상태 체크리스트는 [docs/ROADMAP.md](docs/ROADMAP.md) §S, 짧은 인계 요약은 [docs/HANDOFF.md](docs/HANDOFF.md)에 있다.

- **편집기([app/](app/)):** M1(2026-10-10 완료) 뒤 작업 승인별로 넓혔다. 영상(H.264·HEVC, 고정·가변 프레임레이트)과 소리 파일(WAV·AIFF·M4A, MP3는 실제 파일 미검증) 가져오기, 여러 영상·오디오 레인, 연결된 영상·소리, 자르기·트림·옮기기·빈틈 삭제·리플 삭제, 실행 취소·다시 실행, 영상 클립 크기·위치, 소리 클립·레인 음량·음소거·페이드, 타임라인 클립 복사·붙여넣기, 프로젝트 저장·열기(`.ontheframe`, 형식 5)·재연결·최근 목록, 진행 표시, FHD 30 fps SDR H.264/AAC MP4 내보내기(진행률·취소·실패 처리·출력 보호).
- **아직 없는 것:** 이미지 가져오기(원 요구사항), 자막, 오디오 스펙트럼, 4K 출력. 다음 순서(소유자 결정 D-028): 단축키 목록 정리와 V·C 도구 전환 → 자막(T 포함) → 오디오 스펙트럼 → 프로젝트 보호·안정화 → 개인 사용 검증.
- **실험:** E1(짧은 FHD)과 E3-1(10분 FHD)은 각자의 실험 범위 안에서 완료, E2(짧은 4K)는 사용자 정의 합성기의 원본 프레임 불일치로 미완료, E3-2 이후(60분·3시간·4K 길이)는 시작하지 않았다. 실험의 자막·스펙트럼 렌더링은 편집기 기능이 아니다.
- **지원 목표:** 최대 3시간 프로젝트와 4K는 받아들인 지원 목표이며 아직 입증되지 않았다.
- **미정:** 기술 스택 확정, 최소 macOS 버전, 입출력 포맷 정책, 성능 기준, 배포 방식, 라이선스. 상업 배포는 개인 사용이 성공한 뒤에만 검토하고, 활성화·결제·라이선스 인프라는 개인 사용 단계에 넣지 않는다.
- 알려진 열린 문제(A-010 프리뷰 프레임 0 불일치, 간헐 테스트 실패, 실제 MP3 미검증 등)는 [docs/ROADMAP.md](docs/ROADMAP.md) §S.6에 있다.

## 문서

- [docs/PRODUCT.md](docs/PRODUCT.md) — 제품 방향·지원 목표, 주요 워크플로, 명시·파생 요구사항, 열린 질문
- [docs/DECISIONS.md](docs/DECISIONS.md) — 확정 결정, 제안, 미결정 사항
- [docs/ROADMAP.md](docs/ROADMAP.md) — 현재 상태 체크리스트(정본, §S)와 제안 개발 단계·완료 기준
- [docs/HANDOFF.md](docs/HANDOFF.md) — 짧은 인계 요약(기준 커밋, 브랜치, 알려진 문제, 다음 작업)
- [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) — 관찰된 개발 환경
- [docs/TECHNOLOGY-EVALUATION.md](docs/TECHNOLOGY-EVALUATION.md) — 기술 방식 비교, macOS/CPU 정책 제안, 초기 통합 실험(E1) 상세
- [docs/EDITOR-PLAN.md](docs/EDITOR-PLAN.md) — 편집기 UI 첫 계획(화면 배치, 조작, 첫 마일스톤, 엔진 재사용, 앱 구조 제안 — 미승인)
- [app/README.md](app/README.md) — 편집기 구현 기록(M1과 그 뒤 작업 §1–§25): 빌드·실행 방법, 동작, 검증 결과, 소유자 확인, 한계
- [docs/diagnostics/A-010-preview-frame0.md](docs/diagnostics/A-010-preview-frame0.md) — A-010 프리뷰 경로 프레임 0 불일치 진단 요약(미해결)
- [docs/EXPERIMENT-PLAN.md](docs/EXPERIMENT-PLAN.md) — 단계별 실험 계획(FHD → 4K → 3시간), 메모리·디스크 구조 제안
- [experiments/e1-fhd/README.md](experiments/e1-fhd/README.md) — E1 실험 재현 명령, 결과, 소유자 관찰 체크리스트, 한계
- [experiments/e3-fhd-10min/README.md](experiments/e3-fhd-10min/README.md) — E3-1 실험(10분 FHD) 재현 명령, 결과, 메모리·디스크 측정, 소유자 확인, 한계
- [experiments/e2-4k/README.md](experiments/e2-4k/README.md) — E2 실험(짧은 4K 컷 편집) 재현 명령, 결과, 열린 결함, 소유자 관찰 체크리스트, 한계
- [CLAUDE.md](CLAUDE.md) — 코딩 에이전트 작업 규칙

## 라이선스

미정. ([docs/DECISIONS.md](docs/DECISIONS.md) 참조)
