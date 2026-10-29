# TASK ID: IMG-1A-4

**STATUS: REJECT** — 현재의 짧은 ProRes 캐시를 범용 JPEG/투명 PNG의 기본 렌더링 아키텍처로 채택하지 않을 것을 권고한다. 이미지 지원이나 ProRes 코덱 전체를 거부한다는 뜻은 아니다. 재현된 alpha source-over 실패에 제한된 수정 방법을 확인하지 못했으므로 이 후보의 추가 튜닝을 여기서 멈춘다.

> IMG-CP-02 게시 준비: `$REPO`는 저장소 루트, `$SELFTEST_ROOT`는 `$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 실험의 전용 내부 APFS SwiftPM scratch 디렉터리다. 아래 `$VAR`는 실제 실행 전에 해당 경로로 설정한다. 개인 절대경로만 비식별화했으며 원래 명령·실패 재현에서의 경로 역할과 하위 상대경로는 유지했다. 원본 로그는 변경하지 않았다.


## 1. 상태와 보존

저장소 `$REPO`, branch `feature/subtitles`, HEAD/upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main `44943eadabdf5a37d5242d614e7279813126dfde`에서 시작했다. 기존 ROADMAP/HANDOFF 미커밋 변경·실험 파일·`.claude/`·`.DS_Store`를 유지했다. fetch/pull/reset/clean/branch 변경/staging/commit/push 없음.

이번 추가 파일은 격리 테스트 `app/Engine/Tests/OnTheFrameEngineTests/IMG1A/ImageAlphaDecisionTests.swift`, [사전 조건](IMG1A-4-BOUNDED-CONDITIONS.md), 이 보고서다. 이전 소스/문서11개와 이전 증거145개를 SHA256으로 시작/종료 대조한다. [원래 계약](IMG1A-CONTRACT.md), [IMG-1A](IMG1A-STATIC-IMAGE-CACHE.md), [IMG-1A-2](IMG1A-2-QUALITY-GEOMETRY.md), [IMG-1A-3](IMG1A-3-SAMPLING-QUALITY.md)를 덮어쓰지 않았다.

생산 CompositionPlanner/ExportService/SubtitleExport/PlayerNSView/Media/Timeline/ProjectFile/spectrum/save 코드는 그대로다. Import UI·format9·Stage3C-2·spectrum export를 시작하지 않았다. 소유자 미디어나 프로젝트를 사용/수정하지 않았다.

## 2. 계약과 실험 범위

**40dB, 평탄부 최대3은 그대로다.** Pixel-center bilinear 제안은 여전히 미승인이고 이전 CG/bilinear 점수 모두 보존한다. 이번 조사는 이미지 source와 output을 FHD1920×1080 **1:1**로 두어 그 sampling 정책 차이가 alpha 결론을 좌우하지 않도록 했다.

조건은 macOS26.6.2, Xcode27.1, arm64 Debug XCTest, 기존 내부APFS `IMG1A-build`다. 생성 source는 실제 sRGB ICC의 RGBA8 PNG이며 다음 다섯 경우다. RGB는 (204,51,26), alpha는 실제 정수 성분으로 정하고 `(RGB*alpha+127)/255`로 premultiply했다.

| 경우 | Alpha |
|---|---|
| A opaque | 255 |
| B transparent | 0 |
| C half | 128 |
| D gradient | x방향0…255 |
| E sharp boundary | x<640:0, 640…1279:128, 1280이후255 |

기존 생성 opaque H.264 청색 판을 아래 영상으로 재사용했다. 아래 reference는 파일의 tag를 적용해 읽은 sRGB 색이다. 청색 판은 균일하며 작은 기존 codec residual만 있다. Reference 확대는 독립 nearest 확장으로 하고, B transparent control로 그 잔차를 측정했다. Alpha 이미지 자체는 확대하지 않는다.

독립 reference는 premultiplied encoded-sRGB Porter-Duff source-over이며 CG의 동일 크기 source-over와 비교했다. 다섯 경우 모두 **차이0**이었다. 따라서 이 제한된 실험의 alpha 실패는 미승인 bilinear reference를 골라 만든 결론이 아니다. Linear-light source-over는 다른 모델로 별도 기록했다.

Cache는1초/30 sample의 ProRes4444 MOV, input BGRA8·sRGB attachment, primaries/matrix709·transfer IEC_sRGB다. Final은 기존 ExportService의2초 FHD30 H.264다. 사전에 정한 다섯 기본 경우, half의 alpha 표기 두 대조, 고정 배경 선합성 세 대조만 실행했다: **cache10개/export10개**. 재분석은 같은 파일을 읽었고 export를 반복하지 않았다. 무작위 parameter sweep·장시간/4K 실험 없음.

## 3. 진단 색 해석 정정

첫 matrix에서 opaque native-buffer 비교가34.30dB인데 generator는50.32dB인 불일치를 발견했다. 해당 native buffer에는 `CGColorSpace`가 없고 709 primaries/transfer/matrix만 있었다. 실험 helper가 ICC가 없다는 이유로 sRGB로 가정한 것이 잘못이었다.

새 helper는 `CVImageBufferCreateColorSpaceFromAttachments`로 선언된 색 속성에서 ICC를 합성한다. 정보가 충분하지 않으면 sRGB를 추정하지 않고 오류를 낸다. 색 공간 합성 API의 Unmanaged 반환 타입 관련 첫 compiler error도 보존했다. 수정 뒤 실제 opaque native와 generator 비교는 **차이0**이었다. 이것은 진단 경로 수정이며 생산 색 처리는 바꾸지 않았다.

아래 최종 native 수치는 정정된 `-02/testReadOnlyFinalEvidence/results.json`을 사용한다. 첫 matrix의 raw/기존 해석 수치도 삭제하지 않았다. 기존 캐시 입력·독립 reference·export 파일은 이 helper 수정으로 바뀌지 않았다.

## 4. Alpha 분기와 수치

| 경우 | 합성 전 CG vs 독립 계산 | cache raw 숫자/alpha | native vs reference | final vs reference |
|---|---:|---|---:|---:|
| A opaque | 차이0 | 작은 양자화 오차 | 50.32dB / 최대2 | 45.17dB / 최대3 |
| B transparent | 차이0 | RGB0, alpha0 보존 | 97.32dB / 최대2 | 43.36dB / 최대4 |
| C half | 차이0 | RGB 최대1, alpha 차이0 | **32.59dB / 최대11** | **33.38dB / 최대11** |
| D gradient | 차이0 | alpha 차이0 | **34.76dB / 최대11** | **34.70dB / 최대12** |
| E edge | 차이0 | alpha 차이0 | **37.29dB / 최대11** | **37.72dB / 최대46** |

B의 native 차이는 드문 기존 영상 잔차이며 final에는 영상 재인코딩 손실이 더해진다. B의 interior window 최대는3이다. C는 모든 평탄부 native 최대11, final interior 최대9다. E의 중간 half 영역도 native 최대11이어서 경계 resampling만으로 설명할 수 없다. D는 공간적으로 변하는 gradient이므로 진단의 left/middle/right window를 실제 flat field로 취급하지 않는다.

원래 IMG-1A-3의 복합 패턴 alpha export38.88dB·flat4–5는 그대로다. 새33.38dB는 **다른 FHD solid 제어군**이므로 개선/악화율로 직접 빼지 않는다. 새 경우는 resampling 없이도 문제를 재현했다는 근거다.

### 최초 관측 지점

PNG round trip과 codec 전 source-over는 독립 계산과 일치한다. Half cache의 BGRA 숫자는 입력 premultiplied 성분과 최대1, alpha는 정확히128이다. 그러나 cache를 native composition에 넣으면 decoded-source로 다시 계산한 source-over와도 **32.66dB/최대10**으로 다르다. Native와 generator composition 관찰이 모두 C에서 같은 실패를 보인다. Final과 native 사이는47.08dB/최대3이므로 **주된 C 실패는 최종 H.264 이전**에 이미 있다.

확인한 범위는 native source-over/색 변환과 alpha 표현의 결합 지점이다. 내부의 정확한 working-space/decoder 함수를 특정하지 않았고, codec quantization 하나만 원인이라고 하지 않는다. Cache raw 숫자가 가깝다는 사실만으로 모든 alpha 의미가 올바르다고 단정하지 않는다.

### Premultiplication 표기 대조

로컬 SDK는 encoder가 명시된 alpha mode나 첫 buffer attachment를 참고하며 미지정이면 premultiplied를 기본으로 삼는다고 설명한다. 실험에서 default와 explicit-premultiplied는 동일하게 실패했다. Straight는 RGB를 unpremultiply하고 StraightAlpha attachment를 넣은 별도 대조다.

| Half 조건 | decoded raw RGBA 첫 픽셀 | native PSNR/최대 | final PSNR/최대 |
|---|---|---:|---:|
| default premultiplied 입력 | 약[103,27,14,128] | 32.59 / 11 | 33.38 / 11 |
| explicit premultiplied | [103,27,14,128] | 32.59 / 11 | 33.38 / 11 |
| explicit straight | [204,53,27,128] | 12.57 / 99 | 12.76 / 97 |

Decoded attachment에는 `StraightAlpha`가 나타나므로 raw BGRA의 숫자와 codec/renderer의 alpha-mode 의미를 혼동하지 않는다. Straight cache를 premultiplied CGImage로 해석한 일부 진단 값은 그 **가정 아래의 값**이며 mode의 올바른 의미를 증명하는 값이 아니다. 최종 opaque composite의 큰 실패는 이 가정과 별개다. **어느 표기 대조도 제한된 수정 방법으로 확인되지 않았다.**

### Encoded RGB와 linear-light

두 평탄부 점(100,100), (900,500)에서 input foreground premultiplied=[102,26,13,128], background=[35,98,199,255]다. 독립 encoded-sRGB source-over=[119,75,112], linear-light source-over=[151,79,146], native=[119,79,123]이었다. Native는 단순한 두 모델 어느 쪽과도 flat<=3 안에서 일치하지 않는다. 더 잘 맞는 모델을 찾아 계약을 바꾸는 최적화는 하지 않는다.

## 5. 국소 오차와 손실 분리

| 경로/영역 | 지역PSNR | 최대 | 최악 좌표 |
|---|---:|---:|---|
| Half native middle flat | 32.59 | 11 | (800,200) |
| Half final middle flat | 33.41 | 9 | (800,200) |
| Gradient final middle window (비평탄) | 32.62 | 12 | (862,200) |
| Edge native middle half 영역 | 32.59 | 11 | (800,200) |
| Edge final x640 경계 | 27.33 | 46 | (639,0) |
| Edge final x1280 경계 | 28.18 | 42 | (1279,0) |

C의 큰 평탄부 오차는 geometric sampling이나4:2:0 경계 손실이 아니다. E의 추가 최종 edge 오차는 H.264의 chroma subsampling/encoding 단계와 분리해서 보고한다. Global 점수만으로 수용하지 않는다.

## 6. 고비트 추출 관련성 분류

**분류 A: standalone-generator를 포함하는 현재 후보의 8-bit SDR preview 계약에는 직접 blocker다.** 입력 PNG는 실제8bit sRGB인데 standalone generator는16bit CGImage를 반환하고34.97dB/최대144, 최악(0,505)을 재현했다. 따라서 이를 HDR/고비트 입력만의 제한(B)이라고 할 수 없다.

범위를 분명히 한다: explicit BGRA8 reader는51.64dB/최대2, 해당 cache를 identity로 native composition에 넣고 BGRA8로 읽은 결과도51.27dB/최대2다. **모든 8-bit SDR 지원이 불가능하다는 뜻은 아니다.** 모든 preview 분기를 명시적8bit decode로 제한하는 별도 설계는 가능성이 있지만 제품에 반영/승인하지 않았다. 이번에는 일반 HDR/광색역 개발을 하지 않았다. 기존 AVPlayer56/56 및 물리 화면 검증 한계도 그대로다.

## 7. 한 가지 대안: 알려진 배경에 먼저 합성

같은 독립 source-over 결과를 한 번 opaque 이미지로 만들고, 그 뒤 ProRes cache/native/export를 통과시키는 대안을 Half/gradient/edge에서 시험했다. 영상 전체를 매 프레임 BGRA로 왕복시키는 생산 export를 도입한 것이 아니다.

| 고정 배경 선합성 | native PSNR/최대 | final PSNR/최대 | final interior window 최대 |
|---|---:|---:|---|
| Half | 51.93 / 1 | 46.88 / 4 | 2 |
| Gradient | 50.99 / 2 | 45.04 / 5 | 3–5, 비평탄 window |
| Edge | 51.20 / 2 | 42.12 / 49 | 3/2/3 |

같은 입력/reference에서 native의 alpha 혼합 단계가 없어지면 큰 평탄부 실패가 사라진다는 근거다. 하지만 final edge 최대49와 지역PSNR 약27은 그대로 공개하며 global 점수만으로 완전 수용을 선언하지 않는다.

이 대안은 **이 정확한 알려진 opaque 배경**에서만 유효하다. 하위 영상이 시간에 따라 바뀌거나, 레인이 독립적으로 이동/트림/변형/재연결되면 cache를 그대로 재사용할 수 없다. 매 영상 프레임을 선합성하는 일반화는 다른 비용·품질·취소·preview/export 계약이 필요하며 이번에 구현하지 않았다. 따라서 독립 multi-lane 편집의 일반 대체안으로 채택하지 않는다.

## 8. SIGABRT 회귀와 실제 실행

이전 IMG-1A-3 NaN JSON 직렬화 SIGABRT 로그를 해시로 보존했다. 새 표적 검사는 Double NaN/±infinity, Float NaN, CGFloat infinity, invalid CMTime.seconds, nested NSNumber/array/dictionary를 넣는다. 원 payload가 JSON에 부적합함을 안전한 `isValidJSONObject`로 확인하고, 실제 기존 `jsonSafe`/`note` 경로를 거친 뒤 모든 비유한 값이 명시적 문자열로 남고 JSON round trip이 되는지 검증했다. 위험한 원 serializer를 다시 crash시키지는 않았다.

| 로그 (selftest-work 아래) | 결과 | exit |
|---|---|---:|
| `img1a4-20261028-01/controls-first.log` | 8bit 관련성/NaN 회귀2tests, 실패0 | 0 |
| `-01/alpha-first.log` | bounded matrix1test, assertion실패0; 품질fail은 수치로 기록 | 0 |
| `-02/read-only-first.log` | 색 공간 합성 API의 Unmanaged 반환 compiler error, 실행 전 실패 | 1 |
| `-02/read-only-retry.log` | 반환 소유권 수정 후 기존 파일 재해석1test, 실패0 | 0 |
| `-03/regressions.log` | RGB/linear point·ICC 누락 회귀와 NaN 회귀2tests, 실패0 | 0 |
| `-03/opt-out.log`, `-03/final-opt-out.log` | 재현 입력 경로 옵션 추가 전/후 compile·격리 확인, 각각31tests 전부SKIP·실패0 | 0 |

현재 실행의 예기치 않은 host/app 종료는 관찰하지 않았다. Compiler error는 별도로 보존하며 과거 SIGABRT를 숨기지 않는다. Exit0은 기록된 품질fail을 PASS로 바꾸지 않는다. 무관한 전체 suite·제품 app UI를 실행하지 않았다.

## 9. 자원·재현·판정

기본 cache 생성 wall time은약0.085…0.181초(진단 포함), 기본 cache 크기는약0.92…33.39MB였다. FHD alpha gradient1초 cache가33,392,115bytes였다는 실제 저장 비용도 기록한다. Final export10개는개당약0.333…0.356초, 합계509,553bytes였다. 이는 단순 생성 판의 한 번 측정이고 긴 실제 영상의 성능 예측이 아니다.

새 산출물은약52MiB, 기록 지점 RSS 최대약501.84MiB, build+test invocation 최대RSS561,823,744bytes(compiler/child 범위 포함)다. 관리 산출물 약7.77GiB로20GiB 안이다. 원본/기존 출력/진단 증거 삭제 없음. 4K/3시간 성능 주장 없음.

재현은 기존 내부APFS scratch에서 `ImageAlphaDecisionTests`를 선택한다. `OTF_IMG1A4_RUN`은 새 selftest-work root, `OTF_IMG1A4_SOURCE`는 원래 `img1a-20261027-01`이다. 출력 메서드folder가 이미 있으면 거부한다. 최초 matrix 후 `OTF_IMG1A4_MATRIX`로 해당 directory를 지정해 다시 읽는다. 기본값은 이 기록의`img1a4-20261028-01/testAlphaMatrixAndAlternative`이며 새 export를 하지 않는다. 일반 환경에서는 모든 실험이 SKIP된다.

**REJECT의 이유**는 변경하지 않은 기준에서 FHD1:1 CG와 독립 계산이 일치하는 상황에서도 부분 alpha가 큰 평탄부/global 실패를 보이고, 제한된 alpha-mode 수정이 확인되지 않았기 때문이다. 미승인 bilinear 계약 승인만으로 이 실패를 없앨 수 없다. 별도 generator 분기도 현재 preview 계약을 막는다. 실패를 수용하도록 기준을 낮추거나 제한 없는 추가 튜닝을 하지 않는다.

소유자 결정은 분리한다:

1. 투명 PNG/독립 하위 영상 요구를 유지할지, opaque-only/알려진 정적 배경 선합성으로 MVP를 제한할지. 제한을 조용히 적용하지 않는다.
2. 독립 sampling/coverage/alpha working-space 계약의 수정 제안을 별도로 검토할지. 이번에40dB/flat3 완화를 권고하거나 승인하지 않았다.
3. 모든 preview에 explicit8bit reader를 요구할지, generator 정확도 관문을 유지할지. 어느 것도 생산에 반영하지 않았다.
4. 다음은 현재 cache 튜닝을 계속하는 대신 **정지 이미지 전용 경로의 preview/export 동등 계약·아키텍처 비교 설계**를 별도 승인받을 것을 권고한다. 앞서 반려된 영상 전체 BGRA export를 자동 재도입하지 않는다.

현재 후보 거부와 대안의 제한을 보고하고 여기서 중단한다. 다음 큰 실험·제품 image import·format9·생산 합성 변경을 자동 시작하지 않는다. Stage3C-2/spectrum export·owner data 수정·staging/commit/push 없음.
