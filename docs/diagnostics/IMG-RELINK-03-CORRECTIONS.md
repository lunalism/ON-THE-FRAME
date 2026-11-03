# IMG-RELINK-03 재연결 수정 검증

2026-11-02 · PARTIAL · 소유자 마우스 메뉴 재검증 대기

기준은 feature/subtitles와 origin/feature/subtitles의 0f32bd6이며 main은 44943ea다. 원래 관찰과 실패는 IMG-RELINK-02-OWNER-ACCEPTANCE.md 및 기존 생성 fixture 디렉터리에 남겼다. 이번 실행 증거는 저장소 아래 app/selftest-work/img-relink03-01에 분리했다.

## 메뉴와 기록

편집 메뉴의 SwiftUI undoRedo 그룹은 menuUndo를 호출한다. 수정 전에는 KeyTrace.note의 일반 String 인자를 만들면서 현재 이벤트의 keyCode를 먼저 읽었다. 마우스 버튼을 놓은 NSEvent로 같은 접근을 실행한 독립 진단이 NSInternalInconsistencyException을 재현했다(mouse.swift, mouse.log). 추적 설정 검사는 그 뒤에 실행되므로 추적이 꺼져도 발생할 수 있다. 해당 인자에서 keyCode 접근만 제거했다. 원래 소유자 프로세스에서 예외 스택이나 당시의 first responder가 기록된 것은 아니다.

키보드 Cmd+Z와 Shift+Cmd+Z는 KeyRouting이 키 이벤트, 편집기 창, 텍스트 입력, 제스처와 history를 확인해 ProjectStore.undo/redo를 호출한다. 메뉴는 editor 대상이면 같은 기록을 사용하고 텍스트 등은 응답자 체인으로 보낸다. 이 모델은 프로젝트 NSUndoManager에 relink를 별도 등록하지 않는다. 초점 조건, 메뉴 활성화 규칙, 등록 방식을 바꾸지 않았다.

서명 앱에서 실제 NSMenuItem을 찾아 활성 상태를 확인하고 NSMenu.performActionForItem으로 실행했다. 누락 이미지와 교체 이미지 사이에서 모델, 저장 소스, 프리뷰, dirty 상태가 일치했다. 키 이벤트를 앱 큐에 게시해 동일 Undo/Redo를 두 번 반복했다. 별도 단축키 앱 검사는 일반 클립 분할, Undo/Redo, 텍스트 응답자 등 44/44였다. 네이티브 메뉴 항목의 프로그램 실행과 사람이 메뉴를 펼쳐 클릭하는 행위를 구분한다. 자동화 프로세스의 AX와 이벤트 게시 권한은 모두 false였다.

## 오류 소유권

누락 이미지 계획 실패가 공용 statusMessage를 덮어썼고 성공 경로에는 이전 오류의 소유자를 식별할 정보가 없었다. 프리뷰 전용 오류 상태를 따로 두고 타임라인 재구성 시작 시 해당 상태만 무효화한다. 실패 게시는 기존 cancellation, generation, projectSession 검사를 통과해야 한다. 일반 상태 줄과 프리뷰 오류는 독립적으로 표시한다.

생성 원본을 이동해 누락 오류와 빈 플레이어를 확인한 뒤 재연결했다. 메뉴 Undo로 오류가 다시 나타났고 Redo에서 준비된 플레이어를 확인했다. 독립 상태 문구가 유지됐으며 저장 기준으로 Undo는 clean, Redo는 dirty이고 닫기 보호가 적용됐다. 후보 취소, 실패, 세션 교체 중 취소와 scope 7회 획득/7회 해제를 검사했다. 모든 GPU 콜백의 인터리빙을 강제한 검사는 아니다.

## 원래 색 실패와 독립 비교

원래 검사 설명은 녹색 상한 40이고 실제 스크립트 조건은 G < 40이다. G=51은 둘 다 실패한다. 세 프레임의 원래 exit 1을 보존했다. generator의 CGColor 성분 리터럴은 파랑 0/0/1, 노랑 1/1/0이다. ImageIO로 실제 PNG를 읽고 sRGB CGContext에 그린 8비트 값은 각각 (4,51,255), (255,251,0)이었다. 원래 검사는 저장된 fixture의 색과 다른 기준을 사용했다.

H.264 avc1, 1920×1080, 30 fps, 150프레임, progressive, 709 원색/전달/행렬, video range, Left 4:2:0. y=540에서 x=480과 1280을 샘플링했다. 96×64 이미지의 fit 구간은 x=150…1769, 색 경계는 x=690이다. 두 점은 각각 그 경계에서 210, 590픽셀 떨어져 크로마 경계의 보간 영향을 피한다.

| 영역 | PNG sRGB | 출력 태그에서 만든 ColorSync RGB′ | 독립 기준 및 실제 인코딩 전 Y/Cb/Cr | MP4 0 / 75 / 149 |
|---|---|---|---|---|
| 노랑 | 255,251,0 | 255,250,0 | 216,18,140 | 216,19,140 / 216,18,140 / 216,18,140 |
| 파랑 | 4,51,255 | 5,45,255 | 60,224,102 | 60,223,102 / 60,224,102 / 60,224,102 |

source-tagged.swift는 실제 709 버퍼 attachment로 만든 프로파일을 사용한다. 8비트 RGB′를 255로 나눈 뒤 Y′=0.2126R′+0.7152G′+0.0722B′, 코드는 round(16+219Y′), round(128+224(B′−Y′)/1.8556), round(128+224(R′−Y′)/1.5748)이다. 기준과 raw의 최대 차이는 0, raw와 MP4는 첫 프레임 Cb만 ±1, 나머지는 0이다. 회귀는 독립 기준의 8비트 중간 반올림과 평탄부 인코딩 양자화에 각각 1코드만 허용한다. 원래 sRGB 출력은 노랑 (254,251,2)/(254,251,1)/(254,251,1), 파랑 (4,51,252)/(4,51,253)/(4,51,253)이다. 원본 대비 파랑 G 차이는 세 번 모두 0이고 전체 RGB 최대 차이는 3이다. 이 비교는 QA-02와 같은 색 도메인에서 평탄부를 비교하는 원칙을 적용한 두 지점 검사이며 전체 영상 PSNR 판정은 수행하지 않았다. 렌더러 변경 없음.

## 실행과 보존

- Debug와 Release 각각 43개 relink/저장·복원 회귀 및 2개 색·영상 컷 내보내기 회귀. 각 45 PASS, 실패·건너뜀 0, 네 명령 exit 0. jobs 1, Release enable-testing 및 OTF_PROTO_RELEASE, 기존 APFS scratch 및 자원 감시를 사용했다.
- 서명 Debug 앱에서 메뉴와 오류 전환을 검사했다. signed-surface-run-result.json이 최종 결과다. 물리 클릭과 소유자 정성 관찰은 미실행이다.
- 마우스 이벤트 독립 재현기는 의도한 AppKit 예외로 종료했다. 샌드박스 내부 최초 AVAssetReader는 시작 실패로 진단 precondition에서 종료했다. 동일 보존 MP4의 호스트 디코드는 exit 0이다. 원래 MP4 SHA256은 a77e2af1984e3a6f1a1a03388877f63dee0743d4ceebe40251f3f617bef0689c다.
- 공개 이미지 기능, 스키마, 스펙트럼, 소유자 데이터나 설정 변경 없음. staging, commit, push 없음.

## 소유자 확인 한 건

저장소 루트에서 다음 명령으로 생성 프로젝트 사본을 연다.

```sh
open -n -a "$PWD/app/selftest-work/img-relink03-01/surface/OnTheFrame.app" "$PWD/app/selftest-work/img-relink03-01/owner/missing.ontheframe" --args -OTFEnableImageImport -OTFLayoutSuite dev.ontheframe.relink03.owner
```

누락 이미지의 재연결에서 같은 owner 폴더의 replacement.png를 선택하고 크기 변경을 승인한다. 텍스트 입력이나 시트가 없는 상태에서 마우스로 편집 메뉴의 실행 취소를 누르면 원래 이름·누락 오류·빈 프리뷰가 돌아와야 한다. 마우스로 다시 실행을 누르면 교체 이름·노랑/파랑 프리뷰가 돌아오고 이미지 오류가 사라져야 한다. 두 번 반복하고 저장하지 않고 닫는다.
