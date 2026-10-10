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

**기획 단계.** 제품 애플리케이션 코드와 Xcode 프로젝트는 아직 없다. 소유자 작업 승인(A-001, A-002)에 따라 FHD 통합 실험 E1(헤드리스 내보내기 E1-a, 실제 `AVPlayer` 프리뷰 E1-b)을 [experiments/e1-fhd/](experiments/e1-fhd/)에 구현·실행했다. E1-b는 첫 소유자 관찰에서 프리뷰 화면 표시가 실패해 수정했고, 수정된 창은 소유자 재확인에서 정성적으로 통과했다(2026-10-10). 소유자가 끝 프레임 유지(D-018)와 E1 완료 기준을 정했고, 끝 프레임 유지를 구현했다. 끝 프레임 소유자 재확인도 통과해 **E1은 완료되었다(2026-10-10)** — 시험한 Mac 한 대의 짧은(10초) FHD 통합 실험에 한한다. 이 실험 코드는 제품 코드가 아니며, 4K·3시간 지원이나 제품 준비 상태를 입증하지 않는다. 기술 스택, 최소 macOS 버전, 입출력 포맷, 프로젝트 파일 포맷, 배포 방식, 라이선스는 모두 미정이다. 기술 방식 비교와 잠정 추천(미승인)은 [docs/TECHNOLOGY-EVALUATION.md](docs/TECHNOLOGY-EVALUATION.md)에 있다.

## 문서

- [docs/PRODUCT.md](docs/PRODUCT.md) — 제품 방향·지원 목표, 주요 워크플로, 명시·파생 요구사항, 열린 질문
- [docs/DECISIONS.md](docs/DECISIONS.md) — 확정 결정, 제안, 미결정 사항
- [docs/ROADMAP.md](docs/ROADMAP.md) — 제안 개발 단계와 완료 기준
- [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) — 관찰된 개발 환경
- [docs/TECHNOLOGY-EVALUATION.md](docs/TECHNOLOGY-EVALUATION.md) — 기술 방식 비교, macOS/CPU 정책 제안, 초기 통합 실험(E1) 상세
- [docs/EXPERIMENT-PLAN.md](docs/EXPERIMENT-PLAN.md) — 단계별 실험 계획(FHD → 4K → 3시간), 메모리·디스크 구조 제안
- [experiments/e1-fhd/README.md](experiments/e1-fhd/README.md) — E1 실험 재현 명령, 결과, 소유자 관찰 체크리스트, 한계
- [CLAUDE.md](CLAUDE.md) — 코딩 에이전트 작업 규칙

## 라이선스

미정. ([docs/DECISIONS.md](docs/DECISIONS.md) 참조)
