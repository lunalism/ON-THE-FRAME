# CLAUDE.md

이 파일은 ON THE FRAME(온더프레임) 저장소에서 작업하는 Claude Code(및 기타 코딩 에이전트)를 위한 작업 규칙이다.

## 역할 분담

- **사용자**: 제품 방향과 결정의 최종 승인자.
- **ChatGPT**: 사용자와 함께 기획하고 Claude Code의 보고를 검토한다.
- **Claude Code**: 사용자의 Mac에서 구현·문서 작업을 수행하고 결과를 보고한다.

Claude Code는 [docs/DECISIONS.md](docs/DECISIONS.md)에 "확정"으로 기록되지 않은 사항을 임의로 확정하지 않는다. 제안이 필요하면 "제안"으로 표시해 문서에 남기고 사용자 승인을 받는다. 리뷰어(ChatGPT)의 지적이나 제안을 반영할 때도, 소유자가 승인하지 않은 내용은 제안·파생 요구사항·열린 질문으로 기록하고 확정 결정으로 옮기지 않는다.

## 현재 단계

- 기획 단계다. 제품 애플리케이션 코드와 Xcode 프로젝트는 만들지 않는다.
- **작업 승인(2026-10-09): E1-a(A-001)와 E1-b(A-002)만 허용했고, 둘 다 완료되었다(E1 완료 2026-10-10, 시험한 Mac의 짧은 FHD 통합 실험에 한함).** 새 실험 단계(E2 등)는 별도 승인 전까지 시작하지 않는다. 실험 코드는 [experiments/e1-fhd/](experiments/e1-fhd/)에만 둔다([docs/DECISIONS.md](docs/DECISIONS.md) §2.1).
  - E1-a: 헤드리스 FHD 합성·내보내기 실험과 짧은 검증 실행.
  - E1-b: 기존 렌더러·타임라인 모델·선택 소스 스펙트럼 캐시를 사용자 정의 합성기로 `AVPlayer`에 연결한 실제 프리뷰, 내보내기와의 비교, 필요한 E1-a 수정, 짧은 검증 실행. 실험 전용 최소 창(재생·일시정지·탐색)은 허용하며 제품 UI가 아니다.
  - 허용: Swift + AVFoundation/AVKit 실험 코드(잠정), 합성 fixture, 10초 FHD 수준의 짧은 내보내기·재생, 빌드·테스트 실행.
  - 산출물: 생성 fixture·캐시·출력·빌드 산출물은 데이터 볼륨의 `experiments/e1-fhd/artifacts/`, `experiments/e1-fhd/.build/`에 두고 Git에서 무시한다. 실험 소유 산출물 합계는 2 GiB 이하이며, 넘기 전에 멈추고 보고한다. 시스템 캐시를 옮기거나 전역 설정(화면 기록 권한 포함)을 바꾸지 않는다. 외부 미디어를 쓰지 않는다.
  - 허용하지 않음: 제품 앱 UI, 프로젝트 저장, 4K, 긴 내보내기·재생, 라이선스 인프라, 도구 설치, commit·push·merge.
  - 소유자 관찰이 필요한 항목이 남아 있는 동안 E1을 완료로 선언하지 않는다.
  - A-001·A-002는 P-001~P-006 승인이나 기술 스택·플랫폼 정책 확정이 아니다. E2 이후 단계는 별도 승인을 받고, 승인 범위에 맞게 이 절을 갱신한 뒤 진행한다. 승인 범위를 넘는 코드는 만들지 않는다.
- 기술 스택, 최소 macOS 버전, 프로젝트 파일 포맷, 라이선스는 미정이다([docs/DECISIONS.md](docs/DECISIONS.md) 참조).
- 기술 비교와 잠정 추천은 [docs/TECHNOLOGY-EVALUATION.md](docs/TECHNOLOGY-EVALUATION.md), 단계별 실험 계획은 [docs/EXPERIMENT-PLAN.md](docs/EXPERIMENT-PLAN.md)에 있으며, 모두 제안일 뿐 확정이 아니다.
- 소유자 확인 방향(2026-10-09): 개인용으로 시작, 성공 시 상업 배포, 최대 3시간·4K는 지원 목표(미입증). 초기 구현에 라이선스 인프라를 넣지 않는다([docs/DECISIONS.md](docs/DECISIONS.md) D-011~D-017). 검증 전에는 3시간·4K 지원을 주장하지 않는다.

## 작업 흐름

1. 작업 전 `git status`로 작업 트리 상태를 확인한다.
2. 편집할 파일은 먼저 읽고, 관련 문서([docs/PRODUCT.md](docs/PRODUCT.md), [docs/DECISIONS.md](docs/DECISIONS.md), [docs/ROADMAP.md](docs/ROADMAP.md))를 확인한다.
3. 요청 범위 안에서만 변경한다. 범위 밖의 개선은 제안으로만 보고한다.
4. 결정이 내려지면 [docs/DECISIONS.md](docs/DECISIONS.md)를 갱신하고, 영향을 받는 다른 문서도 함께 맞춘다.
5. 요구사항은 출처를 구분한다: 소유자 brief에 명시된 것은 `R-`, Claude Code가 도출한 것은 `DR-`(소유자 미승인)로 기록한다. 파생 요구사항을 소유자가 승인한 것처럼 쓰지 않는다.

## 사용자 변경 보호

- 기존 사용자 변경(커밋되지 않은 수정, untracked 파일)을 덮어쓰거나 되돌리거나 삭제하지 않는다.
- `git reset --hard`, `git checkout -- <path>`, `git clean`, 강제 push 등 파괴적 명령은 사용자의 명시적 요청 없이 실행하지 않는다.
- commit, push, merge, 저장소 설정·공개 범위 변경은 사용자가 요청할 때만 수행한다.
- 자격 증명·토큰을 출력하거나 파일에 저장하지 않는다.
- 커밋되는 문서에 사용자 이름, 기기 식별자, 불필요한 개인 경로를 남기지 않는다.

## 제품 원칙 (구현 시 지켜야 할 것)

- 비파괴 편집: 원본 미디어를 덮어쓰거나 삭제하지 않는다.
- 프리뷰와 내보내기는 구성과 타이밍(오디오, 자막, 스펙트럼 포함)이 일치해야 한다.
- After Effects의 오디오 스펙트럼은 참고 대상일 뿐, After Effects 전체 대체를 목표로 하지 않는다.

## 검증 및 보고 규칙

- 실제로 확인하거나 실행한 것만 보고한다. 가정과 미검증 정보는 명시적으로 표시한다.
- 문서 작업: 문서 간 일관성, 로컬 문서 링크, `git diff --check`를 확인한다. 새 파일은 Git tracked diff에 나타나지 않으므로 별도로 검토한다.
- 코드 작업(향후): 관련 빌드·테스트를 실행하고 결과(실패 포함)를 그대로 보고한다.
- 문서 전용 작업에서는 불필요한 앱 빌드·테스트를 실행하지 않는다.
- 보고는 한국어로 하며, 변경 파일, 수행한 검증과 결과, 브랜치/HEAD/작업 트리 상태, 다음 권장 작업을 포함한다.

## 문서

| 문서 | 내용 |
| --- | --- |
| [README.md](README.md) | 제품 개요, 기획 현황, 문서 링크 |
| [docs/PRODUCT.md](docs/PRODUCT.md) | 제품 방향·지원 목표, 주요 워크플로, 명시·파생 요구사항, 열린 질문 |
| [docs/DECISIONS.md](docs/DECISIONS.md) | 확정 결정 / 제안 / 미결정 사항 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 제안 개발 단계와 완료 기준 |
| [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) | 관찰된 개발 환경 |
| [docs/TECHNOLOGY-EVALUATION.md](docs/TECHNOLOGY-EVALUATION.md) | 기술 방식 비교, 잠정 추천, macOS/CPU 정책 제안, 초기 통합 실험(E1) 상세 |
| [docs/EXPERIMENT-PLAN.md](docs/EXPERIMENT-PLAN.md) | 단계별 실험 계획(E1 FHD → E2 4K → E3 3시간), 메모리·디스크 구조 제안, 승인 구분 |
| [experiments/e1-fhd/README.md](experiments/e1-fhd/README.md) | E1 실험(E1-a 내보내기, E1-b 프리뷰) 코드 구성, 재현 명령, 결과·증거 경계, 소유자 관찰 체크리스트, 한계 |
