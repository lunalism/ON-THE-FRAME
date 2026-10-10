# 기술 평가 — ON THE FRAME

> **상태: 검토 자료(제안).** 이 문서의 추천, 지원 정책, 실험 설정과 판정 기준은 모두 제안이며 확정이 아니다([DECISIONS.md](DECISIONS.md) P-002~P-004). 기술 스택은 미결정(O-02)이다. 리뷰어(ChatGPT 등)의 제안을 반영한 내용도 소유자가 승인하기 전까지는 제안이다.
>
> 표기 규칙:
> - **[문서]** 1차 공식 문서에서 확인한 사실 (출처 번호는 §8)
> - **[SDK]** 이 개발 기기에 설치된 Xcode SDK 파일에서 직접 확인한 사실 (§5.2)
> - **[추론]** 문서를 바탕으로 한 설계상 추론. 검증되지 않음
> - **[실험]** 실험으로 확인해야 하는 항목
> - **[미확인]** 출처에 접근하지 못했거나 2차 출처만 확인한 정보
>
> 성능 수치는 측정하지 않았다. 이 문서에 성능 약속은 없다.
>
> 2026-10-09 소유자 확인 방향: 개인용으로 시작해 성공 시 상업 배포(D-011, D-012), 최대 3시간·4K 지원 목표(D-015, D-016, 미입증), 음악 영상과 일반 컷 편집(D-014). 이 확인은 P-002~P-004의 승인이 아니다. 단계별 실험 계획은 [EXPERIMENT-PLAN.md](EXPERIMENT-PLAN.md)(P-006)에 있다.

## 1. 평가 대상 요구사항

[PRODUCT.md](PRODUCT.md)의 명시 요구사항 중 기술 선택에 가장 큰 영향을 주는 것:

- R-02/R-03 타임라인 편집과 undo/redo
- R-11/R-12 선택한 오디오를 따르고 트림·이동 후에도 동기화되는 스펙트럼
- R-21 자막 스타일·타이밍 (한글 표시는 파생 요구사항 DR-07)
- R-30 프리뷰와 내보내기 일치
- R-31 내보내기 진행률·취소·실패 처리
- R-40 비파괴 편집

지원 목표 T-01(최대 3시간)과 T-02(4K)는 메모리·디스크·동기화 드리프트 측면의 위험을 키운다(§3.6, [EXPERIMENT-PLAN.md](EXPERIMENT-PLAN.md) §4).

가장 큰 기술 위험은 **R-30(프리뷰/내보내기 일치)**이다. 프리뷰 경로와 내보내기 경로가 서로 다른 렌더러를 쓰면 자막·스펙트럼의 위치·타이밍이 어긋날 수 있다. 따라서 "한 합성 함수를 두 경로가 공유할 수 있는가"를 핵심 평가 기준으로 삼는다. 다만 합성 함수 공유는 일치의 **필요조건일 뿐 충분조건이 아니다**. 재생 시 프레임 선택, 스케일링, 색 변환, 인코딩, 오디오/비디오 다중화(mux)는 합성 함수 밖에서 일어난다(§6.4).

## 2. 비교 대상

| 방식 | 구성 | 요약 |
| --- | --- | --- |
| **A. 네이티브 AVFoundation** | Swift, SwiftUI/AppKit, AVFoundation(composition·재생·읽기/쓰기), Accelerate(vDSP FFT), Core Text, Metal 또는 Core Image | macOS 기본 프레임워크만 사용 |
| **B. 네이티브 UI + FFmpeg 엔진** | Swift, SwiftUI/AppKit, FFmpeg 라이브러리(libavformat/libavcodec 등, 디코딩·인코딩), 자체 Metal 합성기, 자체 재생 시계(오디오 출력은 AVAudioEngine/Core Audio) | 디코딩·인코딩·타이밍을 앱이 직접 관리 |
| **C. 크로스플랫폼 Qt + MLT** | C++, Qt 6, MLT 프레임워크, FFmpeg | Shotcut 등 기존 오픈소스 편집기 계열의 구성 |

검토 후 제외한 후보: Electron/웹 기술 기반(WebCodecs 등)은 이번에 1차 문서를 조사하지 않았다 **[미확인]**. 네이티브 macOS 미디어 통합과 내보내기 제어 면에서 A/B보다 이점이 있다는 근거를 찾지 못해 비교에서 뺐다. 필요하면 별도로 조사한다.

## 3. 항목별 비교

### 3.1 타임라인과 미디어 재생

- **A**
  - [문서] `AVMutableComposition`은 composition track을 추가·삭제하고, 시간 범위를 삽입(`insertTimeRange(_:of:at:)`)·삭제(`removeTimeRange`)·스케일할 수 있다. 불변 사본을 `AVPlayerItem`으로 재생할 수 있다 [S9].
  - [추론] 트림·분할·이동은 앱의 타임라인 모델에서 처리하고, 변경 시 composition을 다시 만드는 구조가 적합하다. 원본 파일은 참조만 하므로 R-40과 맞다.
  - [실험] 정지 이미지(배경)를 composition에 넣는 방법(합성기에서 직접 그리기 vs 영상 트랙 생성)과, 편집할 때마다 composition을 다시 만들 때 프리뷰가 끊기는 정도.
- **B**
  - [추론] 타임라인 모델, 프레임 탐색(seek), 오디오/비디오 동기화 재생을 모두 직접 구현해야 한다. 자유도는 높지만 구현량과 동기화 버그 위험이 가장 크다.
- **C**
  - [문서] MLT는 방송·영상 편집기용 멀티미디어 프레임워크이며 Shotcut, Kdenlive, Flowblade가 관련 앱으로 소개되어 있다 [S16]. Qt Multimedia 6.12 문서는 재생·캡처·녹화를 다루고 편집·합성 기능은 언급하지 않는다 [S18].
  - [추론] 편집 모델은 MLT의 playlist/tractor 개념을 따르게 된다. macOS 네이티브 UI 관례와는 거리가 생긴다.

### 3.2 프리뷰와 내보내기의 공유 합성 로직 (R-30)

- **A**
  - [문서] 커스텀 합성기(`AVVideoCompositing`)는 `AVPlayerItem`, `AVAssetExportSession`, `AVAssetImageGenerator`, `AVAssetReaderVideoCompositionOutput`에서 같은 방식으로 생성·사용된다 [S1]. 즉 프리뷰와 내보내기가 **같은 합성기 클래스**를 쓸 수 있다.
  - [문서] Core Animation 기반 대안도 있다. 재생 중에는 `AVSynchronizedLayer` [S10], 내보내기에는 `AVVideoCompositionCoreAnimationTool` [S11]을 쓴다. 하지만 이는 **두 개의 다른 경로**다.
  - [추론] R-30을 위해 자막·스펙트럼을 Core Animation 레이어가 아니라 커스텀 합성기 안에서 직접 그리는 방식을 제안한다. `render(timelineState, compositionTime) → frame`이라는 하나의 결정적(deterministic) 함수를 프리뷰와 내보내기가 공유하는 구조다.
  - [추론] 같은 함수가 같은 입력에 같은 버퍼를 만든다는 것은 **합성 단계**의 일치만 보여 준다. 실제 재생·내보내기 경로 전체가 일치한다는 근거가 되지 않으므로 통합 검사를 따로 한다(§6.4.2).
- **B**
  - [추론] 합성기를 직접 만들기 때문에 공유 구조는 설계로 보장할 수 있다. 다만 재생 경로의 프레임 선택(드롭·반복)과 오디오 시계 동기화는 직접 검증해야 한다.
- **C**
  - [추론] MLT가 프리뷰와 렌더링에 같은 필터 그래프를 쓰는 구조라면 일치에 유리하다. 이번 조사에서 해당 설계를 문서로 확인하지는 않았다 **[미확인]**.

### 3.3 오디오 분석과 스펙트럼 렌더링 (R-10~R-12)

#### 3.3.1 분석 대상: 선택 소스 vs 타임라인 전체 믹스

- **선택 소스(selected source)**: 사용자가 스펙트럼에 연결한 오디오. 타임라인 전체 믹스와 다르다.
- **타임라인 전체 믹스**: 재생 시 들리는 모든 오디오 트랙의 합.
- 원 brief는 "선택한 오디오를 따른다"(R-11)고만 한다. 따라서 **들리는 모든 트랙이 스펙트럼을 움직인다고 가정하지 않는다.** 무관한 오디오 트랙(예: 효과음, 내레이션)은 선택 소스에 연결된 스펙트럼에 영향을 주지 않아야 한다는 것이 이 문서의 해석이다(파생 요구사항 DR-09, 미승인).
- 선택의 단위(클립 1개, 트랙, 같은 원본의 여러 클립)는 미정이다(Q-12).

#### 3.3.2 트림·타임라인 오프셋 적용 (DR-05 제안)

선택 소스가 타임라인 클립 하나라고 할 때 다음과 같이 시간을 대응시킨다.

- 클립 속성: 원본 in-point `s_in`, 길이 `d`, 타임라인 시작 위치 `t_start`
- 타임라인 시각 `t`에서
  - `t_start ≤ t < t_start + d`이면 원본 시각 `s = s_in + (t − t_start)` 부근의 샘플을 분석한다.
  - 그 밖이면 선택 소스의 신호가 없다고 본다(무음 처리는 DR-06).
- 구간은 반열린 구간 `[t_start, t_start + d)`로 정의한다(경계 프레임 판정을 명확히 하기 위함).
- 분석 창(FFT window) 크기, 홉(hop), 창을 시각 `s`의 앞/가운데/뒤 중 어디에 맞출지는 실험 변수로 기록한다. 창 정렬 방식에 따라 스펙트럼 반응이 수십 ms 앞서거나 늦어질 수 있다 [추론].

#### 3.3.3 미결정으로 남기는 동작 (Q-12)

다음은 승인된 내용이 없으므로 **미결정**이다. 실험에서는 모두 "적용하지 않음(원본 샘플 그대로)"으로 고정하고, 그 선택이 제품 결정이 아님을 기록한다.

- 클립 게인·볼륨 조절이 스펙트럼 크기에 반영되는가
- 트랙/클립 음소거 시 스펙트럼이 멈추는가
- 페이드·이펙트(EQ 등) 적용 후 신호를 분석하는가, 적용 전 신호를 분석하는가
- 여러 소스를 하나의 스펙트럼에 연결할 수 있는가, 그 경우 합산 방식
- 스테레오 채널 처리(합산/평균/채널별)

#### 3.3.4 방식별 구현

- **A**
  - [문서] `AVAssetReader`는 파일 기반 미디어와 `AVComposition`을 읽을 수 있다 [S7]. `AVAssetReaderAudioMixOutput`은 하나 이상의 트랙을 믹스한 샘플을 읽는다 [S8]. `vDSP.FFT`는 1D FFT를 제공한다(macOS 10.15+) [S12].
  - [추론] 선택 소스만 분석하려면 (1) 원본 asset을 `s_in`~`s_in + d` 범위로 읽거나, (2) 선택 클립만 들어 있는 별도 composition을 읽는다. 재생용 전체 composition의 믹스 출력을 그대로 분석하면 무관한 트랙이 섞이므로 쓰지 않는다.
  - [추론] 분석 결과(프레임별 밴드 값)를 원본 시간 기준으로 캐시하면, 트림·이동 시 재분석 없이 위 대응식으로 조회할 수 있다. 합성기는 프레임 시각으로 이 캐시를 조회하므로 프리뷰와 내보내기가 같은 값을 쓴다.
  - [추론] 크기 추정(계산값, 측정 아님): 밴드 64개 × float32 × 30fps × 3600초 ≈ 27.6MB/시간.
- **B**
  - [추론] FFmpeg로 원본을 디코딩해 vDSP FFT를 적용한다. 대응식은 A와 같다.
- **C**
  - [추론] MLT에 오디오 스펙트럼 계열 필터가 있을 가능성이 있으나 확인하지 않았다 **[미확인]**. 선택 소스만 분석하는 구성이 가능한지도 확인하지 않았다.

### 3.4 한글 자막 렌더링 (R-21, DR-07)

- **A, B**
  - [문서] Core Text는 문자→글리프 변환, 합자, 커닝, 자동 폰트 대체(cascading)를 제공한다. 레이아웃 객체(CTFramesetter, CTLine 등)는 한 작업/스레드 안에서만 써야 한다 [S13].
  - [추론] 합성기 안에서 Core Text로 그리면 프리뷰와 내보내기가 같은 레이아웃 코드를 쓴다. 합성기가 여러 스레드에서 호출될 수 있으므로 레이아웃 객체를 공유하지 않도록 설계해야 한다.
  - [실험] 한글·영문·숫자 혼합 문장, 폰트 대체 발생 시 결과(§6.4.1).
- **C**
  - [추론] Qt의 텍스트 렌더링 또는 MLT 텍스트 필터를 쓰게 된다. macOS 시스템 한글 폰트와의 결과 차이는 확인하지 않았다 **[미확인]**.

### 3.5 내보내기 진행률, 취소, 출력 보호 (R-31, DR-03, DR-10)

- **A**
  - [문서] `AVAssetExportSession.export(to:as:isolation:)`는 async 메서드이며, 이를 시작한 `Task`를 `cancel()`해서 취소한다. 진행률은 `states(updateInterval:)`로 확인한다 [S2][S3][S4].
  - [SDK] 설치된 macOS 27.0 SDK에서 `progress`와 `cancelExport()`는 Swift에서 deprecated(macOS 10.7~27.0, 대체: `states(updateInterval:)`, `Task.cancel()`)로 표시되어 있다. `states(updateInterval:)`는 macOS 15 이상, `export(to:as:isolation:)`는 macOS 10.15 이상(`@backDeployed(before: macOS 26.0)`)이다.
  - [문서] `AVAssetWriter.cancelWriting()`은 쓰기 중 생성한 출력 파일을 삭제한다. 이미 `failed`/`completed` 상태면 효과가 없고, 취소가 끝날 때까지 호출 스레드를 막는다 [S6].
  - [추론] `AVAssetReader` + `AVAssetWriter` 직접 파이프라인을 쓰면 진행률은 쓴 프레임 수/전체 프레임 수로 계산할 수 있고, `states(updateInterval:)`가 필요 없다(§5 참고).
- **B, C**
  - [추론] B는 인코딩 루프를 직접 돌리므로 진행률·취소는 단순하지만 파일 정리는 앱 책임이다. C는 MLT consumer의 진행 콜백과 중지 기능에 의존한다 **[미확인]**.

#### 3.5.1 임시 출력과 완료 후 승격 (제안)

방식과 무관하게 다음 처리를 제안한다(DR-03, DR-10 제안, 미승인).

1. **경로 검증(시작 전)**: 출력 경로가 프로젝트의 원본 미디어 파일 경로와 같으면 거부한다. 출력 경로에 파일이 이미 있으면 덮어쓰기 여부를 사용자에게 묻는다(확인 UI의 형태는 미정).
2. **임시 출력**: 최종 경로가 아니라 출력 대상과 같은 볼륨의 임시 위치에 쓴다.
   - [문서] `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor:create:)`는 `appropriateFor` URL의 볼륨에 맞는 임시 디렉터리를 만든다. 이 디렉터리는 앱 종료 후 존재를 보장하지 않으며, 사용 후 삭제가 권장된다 [S21].
3. **완료 검증**: 쓰기가 성공하면 임시 파일을 다시 열어 읽을 수 있는지, 길이가 기대값과 맞는지 확인한다.
4. **승격(promotion)**:
   - 최종 경로에 파일이 없으면 임시 파일을 최종 경로로 이동한다.
   - 기존 파일 덮어쓰기를 사용자가 승인했으면 `FileManager.replaceItemAt(_:withItemAt:backupItemName:options:)`를 쓴다. [문서] 이 메서드는 데이터 손실이 없도록 교체하며, 두 경로가 같은 볼륨에 있어야 한다 [S22].
5. **취소·실패**: 임시 파일과 임시 디렉터리를 삭제한다. 최종 경로의 기존 파일과 원본 미디어는 건드리지 않는다.
6. **비정상 종료**: 앱이 강제 종료되면 임시 파일이 남을 수 있다. 다음 실행 시 정리할지는 제안 단계에서 열어 둔다.

### 3.6 긴 영상의 메모리 사용과 디스크 스트리밍

- **A**
  - [문서] `AVAssetReader`는 asset에서 샘플을 읽고, `AVAssetWriter`는 컨테이너 파일에 미디어를 쓰며 트랙을 자동으로 인터리빙한다 [S5][S7].
  - [추론] 샘플 단위로 읽고 쓰는 구조이므로 메모리 사용이 영상 길이에 비례하지 않도록 설계할 수 있다. 실제로 그런지는 측정 전까지 알 수 없다.
  - [실험] 길이가 다른 내보내기에서 최대 메모리 사용량이 길이에 따라 증가하는지.
  - [SDK] 내보내기 쓰기 측 back-pressure API(`isReadyForMoreMediaData`, `requestMediaDataWhenReady`)는 SDK 27에서 deprecated이고, 대체 API(입력 receiver의 async `append`)는 macOS 26.0 이상이다. 제한된 버퍼링 구조 제안과 3시간·4K 검증 단계는 [EXPERIMENT-PLAN.md](EXPERIMENT-PLAN.md) §4, §7.
- **B**
  - [추론] 버퍼 관리를 직접 하므로 통제할 수 있지만, 누수·과다 버퍼링 위험도 앱 책임이다.
- **C**
  - [추론] MLT의 프레임 단위 처리에 의존한다. 측정 필요.

### 3.7 macOS/CPU 호환성

§5에서 다룬다. 요약: 이번에 확인한 핵심 미디어 API는 macOS 10.7~10.15에 도입되었고, `states(updateInterval:)`만 macOS 15 이상이다. 따라서 미디어 API만으로는 최소 macOS를 15 이상으로 올릴 근거가 없다 [SDK][문서].

### 3.8 배포, 의존성, 라이선스, 유지보수

- **A**
  - [추론] OS 프레임워크만 사용하므로 서드파티 라이선스 의무가 거의 없고 앱 크기가 작다. 형식 지원 범위는 macOS가 디코딩할 수 있는 포맷으로 제한된다. 지원 포맷 목록은 이번에 확인하지 않았다 **[미확인]** (O-03).
  - [추론] OS 업데이트에 따른 API deprecation을 따라가야 한다(예: SDK 27에서 `AVAssetExportSession.progress`, `cancelExport()` deprecated [SDK]).
- **B**
  - [문서] FFmpeg 기본 라이선스는 LGPL 2.1 이상이다. GPL 구성 요소를 켜면 FFmpeg 전체에 GPL이 적용된다. LGPL 준수 체크리스트에는 동적 링크, 사용한 소스와 빌드 설정 배포, 문서·About 화면 표기, libx264 같은 GPL 라이브러리 미사용이 포함된다. 특허 문제는 FFmpeg도 판단할 수 없으며 상용 제품은 MPEG 관련 기술 라이선스 요구를 받을 수 있다고 적혀 있다 [S15].
  - [추론] 앱 번들에 동적 라이브러리를 포함하고 서명·공증해야 하며, FFmpeg 보안 업데이트를 직접 추적해야 한다.
- **C**
  - [문서] MLT는 LGPL 2.1이다 [S17]. Qt Multimedia는 상용 라이선스 또는 LGPLv3/GPLv2로 제공된다. H.264 등 코덱 특허 비용은 Qt 라이선스가 다루지 않는다 [S18].
  - [추론] 의존성(Qt, MLT, FFmpeg)이 가장 많고, 각각의 라이선스·업데이트를 관리해야 한다. 크로스플랫폼은 현재 요구사항이 아니다(D-002).

## 4. 잠정 추천 (제안, 미승인)

### 4.1 잠정 추천: 방식 A (Swift + AVFoundation 네이티브)

- 주요 근거
  - [문서] 하나의 커스텀 합성기를 재생과 내보내기 양쪽에서 쓸 수 있다 [S1]. R-30의 합성 단계 일치에 가장 직접적으로 대응한다(경로 전체 일치는 별도 검증 필요).
  - [문서] 원본 asset이나 별도 composition을 지정 범위로 읽을 수 있어 [S7], 선택 소스만 분석하는 구성(§3.3)이 가능하다고 본다 [추론].
  - [문서] `AVAssetWriter.cancelWriting()`의 출력 파일 삭제 [S6], `FileManager`의 같은 볼륨 임시 디렉터리·교체 기능 [S21][S22]으로 출력 보호 절차를 구성할 수 있다.
  - [추론] 서드파티 의존성과 라이선스 부담이 가장 적다(O-08 결정이 단순해진다).
- 주요 트레이드오프와 위험
  - 지원 포맷이 macOS 코덱으로 제한된다(O-03에 따라 문제가 될 수 있다) **[미확인]**.
  - 커스텀 합성기의 스레드·타이밍 동작, 정지 이미지 배경 처리, composition 재생성 비용은 실험으로 확인해야 한다 **[실험]**.
  - AVFoundation 내부 동작(재생 시 프레임 선택, 인코더 지연 등)을 바꿀 수 없어, 문제가 생기면 우회가 어렵다.

### 4.2 대안: 방식 B (네이티브 UI + FFmpeg 엔진 + 자체 합성)

- A의 실험에서 포맷 지원이 부족하거나 합성기 공유가 불가능한 것으로 나타나면 전환을 검토한다.
- [추론] A에서 합성 함수(`render(timelineState, time)`)와 스펙트럼 분석을 AVFoundation과 독립적으로 설계해 두면, B로 전환할 때 UI·타임라인 모델·합성·스펙트럼·자막 코드를 재사용하고 디코딩/인코딩/재생 계층만 바꿀 수 있다.
- 트레이드오프: 구현량 증가(재생 동기화 직접 구현), LGPL 준수와 코덱 특허 검토 필요 [S15].

### 4.3 방식 C를 추천하지 않는 이유

크로스플랫폼은 요구사항이 아니며(D-002), 의존성과 라이선스 관리가 가장 무겁고, macOS 네이티브 UI 관례와 거리가 있다. 다만 Windows/Linux 지원이 요구사항이 되면 다시 검토할 가치가 있다.

## 5. macOS/CPU 지원 정책 제안 (P-004, 미승인)

### 5.1 용어

- **목표 호환성(target compatibility)**: 제품이 지원한다고 선언하려는 범위. 빌드 설정(deployment target, 아키텍처)으로 표현된다.
- **검증된 호환성(tested compatibility)**: 실제로 실행·테스트한 OS 버전과 하드웨어. 릴리스 시 목표 범위와 별도로 기록한다.
- 테스트 환경이 없다는 이유만으로 목표 최소 버전을 올리지 않는다. 목표 범위 중 검증하지 못한 부분은 "미검증 위험"으로 기록하고, 릴리스 전 검증 방법(별도 기기, 가상 머신, 외부 테스터 등)을 정한다.

### 5.2 로컬 SDK와 문서에서 확인한 사실

| 항목 | 값 | 확인 방법 |
| --- | --- | --- |
| 설치된 macOS SDK | MacOSX27.0.sdk (Xcode 27.0) | `xcrun --sdk macosx --show-sdk-path` [SDK] |
| 유효 deployment target | 12.0 ~ 27.0 (`MinimumDeploymentTarget` 12.0, `ValidDeploymentTargets`에 12.x, 13.x, 14.x, 15.x, 26.x, 27.0) | SDK의 `SDKSettings.json` [SDK] |
| SDK가 지원하는 아키텍처 | x86_64, x86_64h, arm64, arm64e 등 | SDK의 `SDKSettings.json` [SDK] |
| `AVMutableComposition` | macOS 10.7+ | 헤더 `AVComposition.h` [SDK], [S9] |
| `AVAssetWriter`, `AVAssetReaderAudioMixOutput` | macOS 10.7+ | 헤더 `AVAssetWriter.h`, `AVAssetReaderOutput.h` [SDK] |
| `AVVideoCompositing` | macOS 10.9+ | 헤더 `AVVideoCompositing.h` [SDK], [S1] |
| `vDSP.FFT` | macOS 10.15+ | [S12] |
| `AVAssetExportSession.export(to:as:isolation:)` | macOS 10.15+, `@backDeployed(before: macOS 26.0)` | Swift interface `arm64e-apple-macos.swiftinterface` [SDK], [S3] |
| `AVAssetExportSession.states(updateInterval:)` | macOS 15+ | Swift interface [SDK], [S4] |
| `FileManager.replaceItemAt(...)` | macOS 10.10+ | [S22] |
| `AVAssetWriterInput.isReadyForMoreMediaData`, `requestMediaDataWhenReady(on:using:)` | macOS 10.7+, SDK 27에서 deprecated(대체: 입력 receiver의 async `append`) | 헤더 `AVAssetWriterInput.h` [SDK] |
| `AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)`, `AVAssetWriterInput.PixelBufferReceiver` | macOS 26.0+ | Swift interface [SDK] |

해석 [추론]:

- Xcode 27.0으로는 deployment target을 macOS 12.0까지 낮출 수 있다. 11 이하는 이 Xcode로 지원할 수 없다.
- 실험·추천 구조(§3, §6)의 핵심 API 중 macOS 15를 요구하는 것은 `states(updateInterval:)`뿐이다. 이 API는 `AVAssetExportSession`을 쓸 때만 필요하고, `AVAssetReader`/`AVAssetWriter` 파이프라인이나 가용성 분기(`if #available`)로 피할 수 있다.
- SDK가 x86_64를 포함하므로 Intel용 빌드(Universal binary)는 기술적으로 가능해 보인다. 하지만 Intel 하드웨어에서 실행해 본 적은 없다.
- SwiftUI/AppKit 등 UI API의 버전 요구는 아직 조사하지 않았다 **[미확인]**. UI 구현 방식이 정해지면 최소 버전 판단에 영향을 줄 수 있다.
- `AVAssetWriter`에 프레임을 공급하는 새 async receiver API는 macOS 26 이상이다. 목표 최소 버전이 26보다 낮으면 deprecated API를 가용성 분기로 함께 써야 한다. 이는 구현 부담이지 최소 버전을 올릴 근거는 아니다.
- Rosetta는 Apple silicon에서 Intel 바이너리를 실행하는 번역 환경이다. Intel 하드웨어 지원이나 Intel 네이티브 앱 지원의 근거가 아니므로 이 정책의 근거로 쓰지 않는다.

### 5.3 제안

| 항목 | 제안 (미승인) | 근거와 트레이드오프 |
| --- | --- | --- |
| 목표 CPU | **arm64(Apple silicon) 전용** | 빌드·테스트 범위가 줄어든다. Intel 지원(x86_64 포함 Universal binary)은 SDK상 빌드 가능해 보이지만 Intel 테스트 하드웨어가 없고, 실행 성능·Metal 동작을 확인할 수 없다. Intel Mac의 최신 지원 macOS가 26이라는 내용은 2차 출처로만 확인 [S19][S20] **[미확인]**. 사용자 범위 축소가 트레이드오프이며 소유자 결정 사항이다 |
| 목표 최소 macOS | **macOS 14 또는 15 중 선택 (잠정 제안: 15)** | 핵심 미디어 API는 15를 요구하지 않는다(§5.2). 15를 잠정안으로 둔 이유는 `AVAssetExportSession`을 쓸 경우 non-deprecated 진행률 API를 분기 없이 쓸 수 있다는 점 하나뿐이며, 이것은 강한 근거가 아니다. UI API 조사와 실험 후 14로 낮출 수 있다. 사용자 OS 분포 데이터는 확인하지 않았다 **[미확인]** |
| 검증된 호환성(현재) | macOS 26.6.2, Apple M2 1대만 | [ENVIRONMENT.md](ENVIRONMENT.md). 목표 범위의 다른 버전은 미검증 |
| 미검증 범위 처리 | 위험으로 기록하고 릴리스 전 검증 방법을 정함 | 테스트 환경 부재를 이유로 목표 최소 버전을 자동으로 올리지 않는다 |

결정 대상: O-01. 실험(§6)은 개발 기기(macOS 26.6.2)에서 진행하며, 실험 결과는 다른 OS 버전의 호환성을 증명하지 않는다.

## 6. 초기 통합 실험 제안 (P-002, 미승인)

이 절은 [EXPERIMENT-PLAN.md](EXPERIMENT-PLAN.md)의 단계 E1(짧은 FHD 통합 실험)의 상세다. 4K(E2)와 길이 확대(E3)는 그 문서에 있다.

> 아래 fixture 설정, 측정 방법, 판정 기준은 모두 **실험용 제안**이며 제품 사양·한계·합격 기준이 아니다. 실험 코드는 버리는 코드로 취급한다. 실험 착수는 소유자 승인 후다.
>
> 진행 상황(2026-10-10): E1-a(헤드리스)와 E1-b(실제 `AVPlayer` 프리뷰, 사용자 정의 합성기)를 실행했다. §6.4.1~§6.4.4의 결과, 합성기를 공유하는 내보내기 경로, 증거 경계(자동 확인은 `AVPlayerLayer` 표시 버퍼까지, 실제 화면 모습·청각 동기는 소유자 확인 필요)는 [experiments/e1-fhd/README.md](../experiments/e1-fhd/README.md)에 있다. 첫 구성은 소유자 관찰에서 화면이 검게 나와 실패했고, 원인(빈 비디오 트랙)을 고쳤으며, 수정된 창은 소유자 재확인에서 정성적으로 통과했다(측정 아님). 끝 프레임 유지(D-018)를 구현했고 소유자 재확인을 거쳐 E1을 완료했다(2026-10-10, 시험한 Mac의 짧은 FHD 통합에 한함). E2(짧은 4K 컷 편집, A-003)도 실행했다: 실제 소스 영상 디코딩·합성의 내보내기 경로는 기대값과 같았고, 프리뷰 재생 시작 시 소스 프레임이 어긋나던 현상은 프레임 타이밍을 비디오 트랙 샘플에서 얻도록 바꾼 뒤 원래 조건에서 나타나지 않았다(관찰된 완화, 내부 원인은 추정). 변경 뒤 1회 관찰된 불일치는 해결되지 않았다( [experiments/e2-4k/README.md](../experiments/e2-4k/README.md)). 방식 A 판단(P-003)은 아직 제안이다.

### 6.1 목적

방식 A로 다음을 확인한다.

1. 하나의 결정적 합성 함수를 프리뷰와 내보내기 경로가 공유할 수 있는가 (합성 단계)
2. 실제 재생·내보내기 경로에서 구성·타이밍이 기대와 맞는가 (통합 단계)
3. 선택 소스의 트림·오프셋을 반영한 스펙트럼이 동기화되고, 무관한 트랙에 영향받지 않는가
4. 한글 자막이 두 경로에서 같게 보이는가
5. 내보내기 진행률·취소·실패 처리와 출력 보호가 동작하는가

### 6.2 Fixture (실험용 제안)

| 항목 | 제안 설정 |
| --- | --- |
| 배경 | 정지 이미지 1장, 1920×1080 PNG (단색 + 위치 확인용 격자), sRGB 태그 |
| 선택 소스 오디오 (S) | 48kHz 스테레오 WAV(LPCM), 약 20초. 구간별 사인 톤(예: 100Hz, 1kHz), 짧은 클릭(시점 측정용), 3초 이상 무음 구간 포함 |
| 무관 오디오 (U) | 48kHz 스테레오 WAV, S와 다른 주파수(예: 5kHz 톤)와 다른 시점의 클릭. S가 무음인 구간에도 소리가 나도록 배치 |
| 자막 | 한글 자막 1개: "온더프레임 테스트 — 가나다 ABC 123", 시스템 한글 폰트, 지정 크기·색상·가운데 정렬·하단 위치, 표시 구간 [2.0s, 8.0s) |
| 스펙트럼 | 막대형 1개, 밴드 32개, 선택 소스 S에만 연결. 게인·음소거·이펙트 미적용(§3.3.3, 제품 결정 아님) |
| 출력 | 1920×1080, 30fps(정수, timescale 30 또는 600), 10초. 주 출력 H.264 + AAC .mp4, 대조 출력 H.264 + LPCM .mov (AAC 지연 분리용). 모두 실험용이며 제품 포맷은 O-03/O-04 |

fixture 파일은 OS 기본 도구나 실험 코드로 생성한다(도구 설치 없음). 생성 파라미터와 SHA-256을 기록한다.

### 6.3 테스트 케이스

1. **기본** — S를 타임라인 0초에 트림 없이 배치.
2. **트림** — S의 in-point를 5.0초로 트림.
3. **타임라인 오프셋** — S를 타임라인 2.0초에 배치(앞 2초는 S 신호 없음).
4. **트림 + 오프셋** — 2와 3을 함께 적용.
5. **격리(isolation)** — 케이스 1~4 각각에 무관 트랙 U를 추가. U가 있을 때와 없을 때 스펙트럼 밴드 값이 같아야 한다.
6. **무음** — S의 무음 구간, S가 배치되지 않은 구간(케이스 3의 0~2초).
7. **취소** — 내보내기 중간(진행률 약 50%)에 취소. 최종 경로에 파일이 없는 경우와 기존 파일이 있는 경우 각각.
8. **실패** — 쓰기 불가 디렉터리로 내보내기, 내보내기 중 원본 fixture 접근 불가(예: 파일 이름 변경).
9. **대상 충돌** — 최종 경로에 기존 파일이 있음(덮어쓰기 거부/승인 각각), 최종 경로 = 원본 미디어 경로.

### 6.4 검사 계층

#### 6.4.1 결정적 렌더링 검사 (합성 단계)

합성 함수 `render(timelineState, t)`를 재생·인코딩 없이 직접 호출해 검사한다.

**비교 조건** (실험용 제안, 모든 비교에서 고정):

| 조건 | 값 |
| --- | --- |
| 시각 | 프레임 번호 n에 대해 `CMTime(value: n, timescale: 30)`, 즉 정확히 n/30초. 부동소수점 초 값으로 시각을 전달하지 않는다 |
| 크기 | 1920×1080, 스케일링 없음 |
| 픽셀 포맷 | `kCVPixelFormatType_32BGRA`, 8bit, premultiplied alpha 여부 기록 |
| 색 공간 | sRGB(또는 실험 시작 시 하나로 고정한 공간)로 태그하고, 비교 전후로 색 변환을 하지 않는다 |
| 대상 | 같은 기기·같은 빌드에서의 결과. 다른 GPU/OS 사이의 비트 일치는 기대하지 않는다 |

**검사 항목** (각각 따로 판정):

| 항목 | 방법 | 제안 기준 |
| --- | --- | --- |
| 결정성 | 같은 입력으로 2회 호출, 프리뷰용/내보내기용 합성기 설정으로 각 1회 호출 | 버퍼 비트 단위 동일 |
| 자막 위치 | 배경과 다른 픽셀의 경계 상자를 레이아웃 엔진이 계산한 기대 사각형과 비교 | 각 변 ±1px |
| 글리프 모양 | 자막 영역을 기준 이미지(최초 실행 결과를 육안 확인 후 고정)와 비교, 대체 문자(□ 등) 유무 육안 확인 | 기준과 동일, 누락·대체 없음 |
| 표시 경계 | 반열린 구간 [2.0s, 8.0s) 기준으로 프레임 59, 60, 239, 240 확인 | 60~239에서만 표시 |
| 스펙트럼 밴드 값 | 합성기가 조회한 밴드 값 배열을 숫자로 기록, 톤 구간에서 해당 주파수 밴드가 최대인지 확인 | 기대 밴드가 최대 |
| 막대 그리기 | 밴드 값으로부터 기대 막대 높이를 계산해 그려진 막대 높이와 비교 | ±1px |
| 격리 | 케이스 5에서 U 유무에 따른 밴드 값 배열 비교 | 수치 동일 |
| 트림·오프셋 대응 | 케이스 1~4에서 같은 원본 시각 `s`에 해당하는 프레임의 밴드 값 비교 | 수치 동일 |

이 계층의 통과는 **합성 함수가 결정적이고 입력을 올바르게 해석한다는 것**만 보여 준다. 실제 프리뷰 화면이나 내보낸 파일이 일치한다는 근거로 쓰지 않는다.

#### 6.4.2 재생·내보내기 통합 검사 (경로 단계)

- **내보내기 경로**: 실제 내보내기 파일을 디코딩해 프레임별 PTS와 픽셀을 얻는다.
  - 프레임 수·PTS가 기대값(0, 1/30, 2/30, …)과 일치하는지.
  - 디코딩한 프레임을 6.4.1의 같은 프레임 번호 버퍼와 비교한다. 이때 인코딩에 의한 색 공간(예: YUV 변환)·압축 차이가 있으므로 비트 일치는 기대하지 않는다.
  - **PSNR(예: 35dB)은 잠정 진단 지표로만 기록한다.** PSNR이 높아도 자막 1프레임 어긋남, 막대 하나 누락 같은 국소 오류를 놓칠 수 있으므로 정확성 판정 기준이 아니다. 정확성은 아래 영역별 검사로 판정한다.
  - 영역별 검사: 자막 표시 시작·종료 프레임, 자막 경계 상자(압축 오차를 고려해 허용치 기록), 막대 높이(허용치 기록).
  - 출력 파일의 색 공간 태그와 픽셀 포맷을 기록한다.
- **프리뷰 경로**: `AVPlayer` 재생 중 합성기가 요청받은 composition 시각을 기록하고, 가능하면 출력 프레임을 캡처해(예: `AVPlayerItemVideoOutput` — 방법은 [실험]) 그 시각의 6.4.1 버퍼와 비교한다.
  - 재생 중에는 프레임 드롭·반복이 정상적으로 발생할 수 있다. 따라서 "모든 프레임 일치"가 아니라 "표시된 프레임이 그 시각의 올바른 합성 결과인가"를 본다.
  - 화면에 실제로 보이는 시점과 스피커 출력 지연은 이 실험에서 측정하지 않는다(범위 밖, 기록만).

#### 6.4.3 타이밍 측정과 "1프레임"의 정의

- **측정 대상**: 내보낸 파일에서 오디오 이벤트(클릭)와 영상 이벤트(스펙트럼 반응, 자막 표시)의 상대 위치.
- **오디오 이벤트 시각** `t_a`: 디코딩한 오디오에서 클릭 시작 샘플의 표시 시각.
- **AAC 지연 처리**: AAC 인코딩은 앞부분에 priming(지연) 샘플을 추가할 수 있다 [추론, 일반 지식 — 실험에서 확인]. 그래서:
  1. 디코더/파일의 편집 정보(edit list, priming 정보)를 반영한 표시 시각으로 `t_a`를 구한다.
  2. 같은 프로젝트를 LPCM .mov로도 내보내 `t_a`를 구한다(코덱 지연 없음 대조군).
  3. 두 값의 차이를 AAC 경로 지연으로 기록한다. 차이가 0이 아니면 판정은 LPCM 기준과 AAC 기준 각각으로 보고한다.
- **기대 영상 프레임** `n_exp`: `t_a`가 속하는 프레임 번호 `floor(t_a × 30)`. 이 값에 분석 창 정렬로 생기는 고정 지연을 더한다(창 크기·정렬은 실험 변수로 기록, §3.3.2).
- **관찰 영상 프레임** `n_obs`: 지정 밴드 값이 문턱값(실험용으로 정함)을 처음 넘는 프레임.
- **"1프레임 이내"의 의미**: `|n_obs − n_exp| ≤ 1`, 즉 30fps에서 약 ±33ms다. 실제 재생 화면과 스피커 사이의 지연은 포함하지 않는다.
- 자막은 오디오와 무관하게 지정 구간 기준으로 `n_obs`(첫/마지막 표시 프레임)를 기대 프레임 60, 239와 비교한다.

#### 6.4.4 진행률·취소·실패·출력 보호

시간을 세 가지로 나눠 측정한다.

| 측정값 | 정의 |
| --- | --- |
| T_ack (UI 확인 지연) | 사용자의 취소 입력부터 UI가 "취소 중" 상태를 표시할 때까지 |
| T_stop (작업 종료 시간) | 취소 입력부터 내보내기 작업이 더 이상 샘플을 쓰지 않고 작업 Task가 끝날 때까지 |
| T_cleanup (정리 시간) | 작업 종료부터 임시 파일·디렉터리 삭제 완료까지 |

검사 항목:

- 진행률: 0에서 1로 단조 증가, 완료 시 1.
- 취소(케이스 7): 최종 경로에 새 파일이 생기지 않는다. 기존 파일이 있던 경우 그 파일의 SHA-256이 취소 전후 동일하다. 임시 파일이 남지 않는다.
- 실패(케이스 8): 오류가 보고되고 원인을 구분할 수 있다. 최종 경로·기존 파일·원본은 변경되지 않는다. 임시 파일이 남지 않는다.
- 대상 충돌(케이스 9): 덮어쓰기 거부 시 기존 파일 불변. 승인 시 완료 후에만 교체되며, 완료 전 실패·취소 시 기존 파일 불변. 최종 경로 = 원본 경로는 시작 전에 거부된다.
- 원본 보호: 모든 케이스에서 fixture 원본의 SHA-256 불변.

### 6.5 측정 조건

- 개발 기기 1대(macOS 26.6.2, Apple M2, 16GB — [ENVIRONMENT.md](ENVIRONMENT.md)), Xcode 27.0, Release 빌드.
- 전원 연결, 다른 무거운 작업 없음. 시간 측정은 각 3회 이상 반복하고 모든 값을 기록한다.
- 결과는 다른 기기·OS 버전·하드웨어에 일반화하지 않는다.

### 6.6 판정 기준 요약 (실험용 제안)

| 항목 | 제안 기준 | 성격 |
| --- | --- | --- |
| 결정적 렌더링 | 6.4.1 표의 각 항목 | 합성 단계 판정 |
| 내보내기 프레임 수·PTS | 기대값과 정확히 일치 | 통합 판정 |
| 자막 표시 경계(내보내기) | 첫/마지막 표시 프레임이 60/239 | 통합 판정 |
| 스펙트럼 타이밍(내보내기) | `|n_obs − n_exp| ≤ 1` (LPCM 기준, AAC 기준 각각 보고) | 통합 판정 |
| 격리 | U 추가 전후 밴드 값 동일 (합성 단계), 내보내기 막대 높이 차이 없음(허용치 기록) | 합성 + 통합 |
| 무음 | 신호 없음 구간 진입 후 정해진 감쇠 시간 안에 최소값 도달·유지 (감쇠 시간은 실험 변수) | 합성 단계 판정 |
| PSNR | 기록만 함. 잠정 진단 지표(예: 35dB 미만이면 원인 조사) | 진단, 판정 아님 |
| T_ack | 제안: 0.1초 이내 | 실험용 제안 |
| T_stop + T_cleanup | 제안: 1초 이내 | 실험용 제안, 미승인 |
| 출력 보호 | 6.4.4 항목 모두 충족 | 통합 판정 |

기준을 하나라도 만족하지 못하면 원인과 우회 가능성을 기록하고, 방식 B 전환 여부를 소유자와 검토한다. 실험 기준은 O-11(일치 판정 기준) 결정의 참고 자료일 뿐 제품 기준이 아니다.

## 7. 소유자 결정이 필요한 항목

- P-002: 초기 통합 실험 착수 여부와 범위(§6). 승인 시 [CLAUDE.md](../CLAUDE.md)의 현재 단계 규칙을 갱신한다.
- P-003: 잠정 방향(A, 대안 B) 수용 여부
- P-004 / O-01: arm64 전용 여부, 목표 최소 macOS(14 또는 15)
- P-005: 파생 요구사항 DR-01~DR-10 채택 여부
- O-03: 필요한 입력 포맷(특히 macOS가 기본 디코딩하지 않는 포맷 필요 여부 — A/B 선택에 직접 영향)
- O-08, O-14~O-19: 상업 배포 시의 채널(Mac App Store 여부 등), 소스 코드 라이선스, 활성화, 업데이트 권한, 결제, 최종 가격 — B/C 선택 시 LGPL·특허 검토 필요. 초기 개인용 단계에는 라이선스 인프라를 넣지 않음(D-017)
- O-04: 4K의 정확한 크기·프레임레이트·색 처리 (D-016은 4K60·HDR 승인이 아님)
- O-09: 성능 기준 (길이 목표는 D-015의 최대 3시간)
- P-006: 단계적 실험 계획([EXPERIMENT-PLAN.md](EXPERIMENT-PLAN.md))
- O-12: 스펙트럼 선택 단위와 게인·음소거·이펙트·다중 소스 처리

## 8. 출처

웹 출처의 접근일은 모두 **2026-10-09**이다. Apple 문서는 HTML 페이지 대신 같은 경로의 문서 데이터(`developer.apple.com/tutorials/data/documentation/...json`)를 조회해 내용을 확인했다. 아래에는 사람이 읽는 페이지 URL을 적었다. [SDK] 표시 항목은 같은 날 로컬 SDK 파일에서 확인했다(§5.2).

| ID | 출처 | 확인 상태 |
| --- | --- | --- |
| S1 | Apple, AVVideoCompositing — https://developer.apple.com/documentation/avfoundation/avvideocompositing | 확인 |
| S2 | Apple, AVAssetExportSession — https://developer.apple.com/documentation/avfoundation/avassetexportsession | 확인 |
| S3 | Apple, AVAssetExportSession.export(to:as:isolation:) — https://developer.apple.com/documentation/avfoundation/avassetexportsession/export(to:as:isolation:) | 확인 |
| S4 | Apple, AVAssetExportSession.states(updateInterval:) — https://developer.apple.com/documentation/avfoundation/avassetexportsession/states(updateinterval:) | 확인 |
| S5 | Apple, AVAssetWriter — https://developer.apple.com/documentation/avfoundation/avassetwriter | 확인 |
| S6 | Apple, AVAssetWriter.cancelWriting() — https://developer.apple.com/documentation/avfoundation/avassetwriter/cancelwriting() | 확인 |
| S7 | Apple, AVAssetReader — https://developer.apple.com/documentation/avfoundation/avassetreader | 확인 |
| S8 | Apple, AVAssetReaderAudioMixOutput — https://developer.apple.com/documentation/avfoundation/avassetreaderaudiomixoutput | 확인 |
| S9 | Apple, AVMutableComposition — https://developer.apple.com/documentation/avfoundation/avmutablecomposition | 확인 |
| S10 | Apple, AVSynchronizedLayer — https://developer.apple.com/documentation/avfoundation/avsynchronizedlayer | 확인 |
| S11 | Apple, AVVideoCompositionCoreAnimationTool — https://developer.apple.com/documentation/avfoundation/avvideocompositioncoreanimationtool | 확인 |
| S12 | Apple, vDSP.FFT — https://developer.apple.com/documentation/accelerate/vdsp/fft | 확인 |
| S13 | Apple, Core Text — https://developer.apple.com/documentation/coretext | 확인 |
| S15 | FFmpeg, License and Legal Considerations — https://ffmpeg.org/legal.html | 확인 |
| S16 | MLT Multimedia Framework — https://www.mltframework.org/ | 확인 (라이선스 표기는 이 페이지에 없음) |
| S17 | MLT 저장소 COPYING — https://github.com/mltframework/mlt/blob/master/COPYING | 확인 (LGPL 2.1) |
| S18 | Qt 6.12, Qt Multimedia — https://doc.qt.io/qt-6/qtmultimedia-index.html | 확인 |
| S19 | MacRumors, "Apple Says macOS 27 Won't Be Compatible With These Macs" (2026-06-03) — https://macrumors.com/2026/06/03/macos-27-wont-run-on-these-macs/ | **미확인**: 2차 출처, 검색 결과 요약만 확인 |
| S20 | PetaPixel, "macOS 26 Tahoe Is the End of the Road for Intel Macs" (2025-06-10) — https://petapixel.com/2025/06/10/macos-26-tahoe-is-the-end-of-the-road-for-intel-macs/ | **미확인**: 2차 출처, 검색 결과 요약만 확인 |
| S21 | Apple, FileManager.url(for:in:appropriateFor:create:) — https://developer.apple.com/documentation/foundation/filemanager/url(for:in:appropriatefor:create:) | 확인 |
| S22 | Apple, FileManager.replaceItemAt(_:withItemAt:backupItemName:options:) — https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:) | 확인 |

S14(Apple, Rosetta 문서)는 이전 판에서 CPU 정책 근거로 인용했으나, Rosetta 제공 기간은 Intel 하드웨어 지원의 근거가 아니므로 이번 판에서 제거했다. ID는 재사용하지 않는다.

조사하지 않은 항목(**미확인**): AVFoundation 지원 입력 포맷 목록, Apple 지원 페이지의 macOS 호환 기종 목록, SwiftUI/AppKit API의 버전 요구, AAC priming 샘플의 실제 값과 AVFoundation의 처리 방식, MLT의 스펙트럼·텍스트 필터와 진행률 API, Qt 전체(Multimedia 외) 라이선스 조건, Electron/웹 기반 접근, macOS 사용자 OS 버전 분포.
