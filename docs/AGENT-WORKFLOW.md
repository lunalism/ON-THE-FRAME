# 공통 에이전트 작업 절차

Codex와 Claude Code는 같은 체크아웃에서 이 절차를 사용한다. 작업 범위는 소유자의 요청을 따르고, 제품 결정과 구현 상태는 [문서 우선순위](../CLAUDE.md#문서의-권위와-제품-방향)에 따라 해당 브랜치에서 확인한다. [결정 기록](DECISIONS.md)에서는 후속 정정까지, [로드맵](ROADMAP.md)에서는 관련 기능과 열린 문제까지 읽는다.

## Git 사전 확인

작업을 시작할 때 아래 네 명령을 실행한다. 이전 세션의 브랜치나 인계 문서의 SHA를 현재값으로 재사용하지 않는다.

```sh
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git status --short
```

실제 루트와 브랜치를 요청의 저장소 및 Required branch와 대조하고, Expected HEAD가 지정됐으면 전체 SHA를 확인한다. 불일치하거나 HEAD가 분리돼 있으면 실제값과 기대값을 보고하고 변경 전에 멈춘다. 자동으로 브랜치를 바꾸지 않는다. 전환을 명시적으로 승인한 작업은 지정된 **출발 상태**부터 확인하고, 전환 직후 목적 브랜치와 HEAD를 다시 확인한다. 원격 기준이 필요한 작업은 원격 참조를 직접 조회하고 로컬 추적 참조와 구별한다.

기존 staged·unstaged 변경과 untracked 파일을 구분한다. 필요한 경우 `git status --short --untracked-files=all`로 디렉터리 안의 파일명도 확인한다. 기존 수정과 겹치면 해당 내용을 보존하고 범위 충돌을 보고한다. 작업 트리를 비우기 위해 reset, clean, stash, restore를 실행하지 않는다.

## 작업별 권한

다음 권한은 각각 독립적이다. 요청에서 승인한 행동·대상·경로만 수행한다. 이미 받은 승인은 지정된 범위 안에서 유효하다.

| 행동 | 실행할 때 확인할 내용 |
| --- | --- |
| 파일 편집 | 허용한 파일·목적과 기존 사용자 변경 |
| 스테이징 | 승인 경로를 개별 지정하고 전체 staged diff, 파일 목록, `git diff --cached --check` 확인 |
| 로컬 커밋 | 승인된 내용·제목과 유효한 author/committer 확인. 커밋 후 SHA·부모·경로 확인 |
| Push | 승인된 원격·브랜치·커밋과 실시간 원격 기준 확인. 게시 후 원격 SHA 재조회 |
| PR 생성 | 승인된 base/head, 커밋·파일 범위 확인. 생성 후 PR 번호와 상태 확인 |
| 병합 | 승인된 대상·방법·부모 기준 확인. 병합 후 결과와 원본 커밋의 계보 확인 |
| 브랜치 삭제 | 로컬·원격 여부와 삭제할 정확한 참조 확인 |
| 이력 재작성 | 대상 참조와 방식에 대한 명시적 승인 확인. amend, rebase, 강제 push도 해당 |

브랜치 생성·전환은 작업에서 명시적으로 허가한 경우에만 수행한다. 저장소 설정·공개 범위 변경도 별도 승인을 따른다. 커밋에는 저장소에서 확인한 소유자의 유효한 Git identity를 사용하며 AI 공동저자 트레일러를 추가하지 않는다. 기존 귀속과 자격 증명에 관한 규칙은 [사용자 변경 보호](../CLAUDE.md#사용자-변경-보호)를 따른다.

## 소유자 데이터와 수동 시험

소유자의 원본 미디어와 저장 프로젝트는 읽기 전용으로 취급한다. 작업·저장·재열기 검증은 격리된 프로젝트 사본과 별도 출력에서 한다. 원본을 이동·개명·삭제·덮어쓰기하지 않는다. 보호된 untracked 파일, ignored 진단 증거, 서명된 Debug 앱과 복구 참조를 보존한다. 실행 중인 소유자 앱은 명시적 허락 없이 종료하거나 교체하지 않으며, 미저장 세션과 실제 저장 패널을 조작하지 않는다.

소유자가 지정한 **수동 수락 시험** 원본은 다음 두 파일이다.

| 용도 | 읽기 전용 참조 |
| --- | --- |
| 오디오 | `~/Desktop/01 交差点.wav` |
| 이미지 | `~/Desktop/IMG_1749.jpg` |

관련 시험마다 지정 경로의 존재·가독성·실제 파일 형식을 확인한다. 파일이 없거나 형식이 다르면 해당 시험의 차단 사유를 보고한다. 다른 미디어를 임의로 대체하거나 과거 자동·합성 fixture를 바꾸지 않는다. 서명된 Sandbox 앱에는 해당 빌드에서 지원하는 네이티브 파일 선택 또는 실제 제공되는 재연결 동작으로 접근 권한을 부여한다. helper의 읽기 성공이나 helper가 만든 bookmark만으로 앱의 접근을 판정하지 않는다. 공유 문서와 커밋에는 개인 절대 경로, 개인 파일 해시, 보안 bookmark, 비공개 진단 메타데이터를 싣지 않는다.

## 검증과 보고

빌드·제품 검사를 실행하기 전에 [앱 README의 현재 실행 승인과 자원 안전](../app/README.md#현재-실행-승인과-자원-안전)을 직접 읽는다. 정확한 한도와 중지 조건은 그 절에서 관리한다. 승인된 실행 절차에서 작업·컴파일러 동시성, 개별·합계 RSS, 증가 예측, 메모리 압력과 감시 상실, 관리 산출물 전체의 할당 디스크·여유 공간을 확인한다. 중단·실패한 빌드는 자동 재시도하지 않는다. 원래 명령의 종료 상태, 전체 로그와 성공 표식, 감시·중지 기록을 함께 확인한다. 서명 Debug 앱을 검증할 때는 소스 fingerprint, 빌드 구성, 실제 번들·서명·entitlement와 실행 인수를 연결한다.

문서 변경은 내용의 일관성, 상대 링크와 앵커, `git diff --check`를 검사하고 untracked 새 문서도 별도로 검토한다. 코드 변경에는 영향받는 경로의 승인된 검사를 적용한다. 최종 보고는 한국어로 작성하고, 실제로 읽은 지침과 절, 변경 경로, 이번에 수행한 검증, 남은 제한, 최종 브랜치·HEAD·작업 트리와 다음 승인 범위를 기록한다.

| 보고 상태 | 필요한 근거 |
| --- | --- |
| 구현 완료 | 해당 브랜치의 소스에서 확인한 범위 |
| 자동 검증 통과 | 대상 소스·fixture·suite, 실제 실행 시점과 PASS/FAIL/SKIP. 실패나 생략 범위 명시 |
| 서명 Debug 빌드 완료 | 대응하는 소스와 번들, 빌드·자원·서명 검증 결과 |
| 소유자 물리 수락 통과 | 소유자가 특정 빌드에서 직접 시험하고 보고한 시나리오별 결과 |
| 기능 수락 | 합의한 완료 조건을 충족한 범위, 남은 제한과 소유자의 수락 |
| 로컬 커밋 완료 | 브랜치, 커밋 SHA·부모·파일 목록 |
| 원격 게시 완료 | 원격 이름, 실시간 브랜치 SHA. PR 생성·병합 여부는 별도 기록 |

각 상태는 자체 근거가 있을 때만 표시한다. 과거 결과에는 시점·출처를 붙이고 이번 실행과 구분한다. 자동 UI 입력과 합성 검사는 자동 검증에 기록한다. 소유자가 시험하지 않은 빌드·하드웨어·조건은 미검증으로 남긴다.

## 짧은 작업 프롬프트

```text
Task ID: <id>
Repository: <path>
Required branch: <starting branch>
Expected HEAD (when pinned): <full SHA>
Goal: <observable outcome>
Scope: <allowed paths and actions, including any Git operations>
Constraints: <task-specific exceptions and safeguards>
Validation: <checks and evidence>
Completion criteria: <what must be true at the end>
Required report: <deliverables, checks performed, limitations and final Git state>

Open CLAUDE.md, docs/AGENT-WORKFLOW.md and applicable AGENTS.md. Read the
references required for this task and report which instructions you read.
Verify the repository, branch and any pinned HEAD before changes.
If instructions are missing, unreadable or contradictory, identify the gap.
Apply the owner's scope and available guidance in their documented order.
Continue safe read-only checks. Ask before any action whose authorization
or safety remains unclear.
```
