# TASK ID: IMG-1A-2

**STATUS: REVISE** — 격리 조사 실행 완료, 이미지 캐시 아키텍처 채택 아님. 원래 40dB/평탄부 최대 3 기준은 유지한다. 생산 소스·프로젝트 형식·소유자 미디어는 변경하지 않았다.

## 기준과 보존

- 저장소 `feature/subtitles`, HEAD/upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main `44943eadabdf5a37d5242d614e7279813126dfde`. fetch·브랜치 전환·Git 변경 명령 없음.
- 시작 상태에는 IMG-1A의 미커밋 테스트·문서와 ROADMAP/HANDOFF 변경, 기존 `.DS_Store`·`.claude/`가 있었다. 그대로 보존했다.
- [원래 계약](IMG1A-CONTRACT.md)과 [원래 REVISE 보고서](IMG1A-STATIC-IMAGE-CACHE.md)는 **byte 그대로**다. 과거 증거 manifest의 75개 파일을 시작/종료에 SHA256으로 검증한다. 원래 portrait assertion 실패·compiler 실패·alpha·시간·취소·보호 증거도 남아 있다.
- 이번 추가 소스는 `app/Engine/Tests/OnTheFrameEngineTests/IMG1A/ImageCacheInvestigationTests.swift` 하나, 추가 진단 문서는 이 파일 하나다. 기존 실험 helper를 호출하지만 고치지 않았다. 생산 `CompositionPlanner`, `ExportService`, `SubtitleExport`, `Media`, `ProjectFile`, `PlayerNSView`, spectrum 코드는 변경하지 않았다.
- 새 산출물은 `app/selftest-work/img1a2-20261027-01`…`-06`. 시작 refs/이전 파일 해시는 `-01/preflight.json`, 단계별 metadata/수치는 각 테스트 폴더 `results.json`, 첫 compiler/assertion 실패는 각 log에 있다.

## 실험 범위·환경

같은 Mac/macOS 26.6.2, Xcode 27.1, arm64 Debug XCTest, 내부 APFS의 기존 `IMG1A-build` scratch를 재사용했다. 새 dependency나 외부 업로드 없음. 원래 960×540 생성 PNG/ProRes/영상과 portrait fixture를 재사용했다. source 파일을 다시 생성하지 않았다. 새 cache는 1초/30개 PTS, 새 export는 2초 FHD30뿐이며 순차 실행했다. 3분/30분·4K·장시간 export를 반복하지 않았다.

비교를 구분한다:

A. ImageIO 정규화 → BGRA, codec 없음.
B. ProRes cache decode만: raw code value, 독립 ICC 변환, CoreImage, AVAssetImageGenerator를 구분.
C. 기본 composition, 최종 export 없음.
D. 기존 ExportService의 H.264 출력.

세 encoding 조건: 기존 `legacy709`(sRGB 숫자를 담은 buffer에 색 attachment 없이 output 709 선언), `srgbTag`(sRGB 숫자·sRGB attachment·IEC_sRGB transfer output), `explicit709`(sRGB 역함수→선형→709 OETF 수식을 숫자에 적용하고 709 선언). 후자는 비교용이며 채택된 변환이 아니다. RGB 숫자가 비슷한 것과 같은 의도된 색 공간의 색 일치를 혼동하지 않는다.

## 단계별 색 관찰

| 경계 | 관측 metadata/해석 | 비교 결과 |
|---|---|---|
| 원본 PNG → 정규화 | 실제 sRGB ICC, RGBA8 premultiplied; 원본 direct ImageIO image와 normalized image를 독립적으로 읽어 비교 | 최대 0 |
| A BGRA | 32BGRA, 0…255 RGB 성분; 원래 buffer에 색 attachment 없음 | 최대 0, PSNR 무한대(기록 999) |
| ProRes encode | 실제 format description 12-bit ProRes 4444, primaries 709, matrix 709; transfer는 조건별 709/IEC_sRGB | 태그를 기록했으며 태그만으로 색 변환 성공을 가정하지 않음 |
| B raw BGRA decode | 32BGRA, AlphaChannelIsOpaque/ICC/transfer attachment 기록 | 기존·sRGB 태그 모두 source 대비 최대 2, 51.64dB |
| B 독립 ICC→sRGB | BGRA 데이터를 attachment의 ICC로 명시한 CGImage로 만든 뒤 sRGB 변환; CoreImage 변환도 별도 실행 | 기존 28.13dB/최대12 (CI 28.28); sRGB 태그 51.64dB/최대2 (CI도 동일) |
| B standalone generator | 기존은 HDTV ICC; sRGB 조건은 QuickTime nclc(1,13,1). CGImage가 **16bpc/64bpp**로 나옴 | 기존 27.46dB/최대155; sRGB 태그도 34.97dB/최대144 |
| C full-canvas 2배 확대 | FHD 30fps, 기존 기본 합성기, CGImage metadata/원본 reader buffer attachment 별도 기록 | 기존 CG reference 대비 기존 26.98, sRGB 태그 34.13dB |
| D H.264 | 실제 709/709/709와 HDTV ICC, generator 8bpc/32bpp | 기존 CG reference 대비 기존 27.01, sRGB 태그 33.22dB |

색 공간 이름뿐 아니라 ICC 크기·SHA256, CGImage bpc/bpp/alpha, CV pixel format, attachment, format description을 JSON에 남겼다. RGB buffer의 full-component 범위와 encoded YCbCr 범위를 별개로 보았다. 명시적 **420v reader** 대조에서 Y 최소16·최대236을 관찰했다(명목 video-range 16…235, residual 포함·clamp하지 않음). 이 대조는 전체 변환의 모든 native YCbCr sample을 비트 단위로 검증한 것은 아니다.

기존 opaque·alpha ProRes의 실제 BGRA 비교는 최대 RGB 2, alpha 최대 차이 **0**이다. Alpha 원본은 premultiplied RGBA, writer는 premultiplied BGRA이며, alpha 존재 여부와 source-over 결과를 분리했다. 투명 부분의 RGB를 임의로 unpremultiply해 opaque reference와 비교하지 않았다.

**최초 확인된 큰 색 차이는 A의 숫자 복사나 raw BGRA decode가 아니라, cache의 색 의미를 적용하는 B 단계다.** 기존 sRGB 숫자/709 선언 불일치는 원인 중 하나로 확인됐다. 동일한 raw-code 품질인데 metadata를 맞추면 독립 ICC/CI 변환의 평탄부 차이가 사라진다. ProRes 손실만으로 설명할 수 없다. 단, standalone 16-bit generator의 큰 edge 차이는 아직 별도 불확실성이다.

## 독립 reference와 좌표 검증

원래 reference가 무조건 맞다는 가정을 검토했다.

- ImageIO 원본 대 normalized, codec 없는 BGRA 대 원본은 차이 0이다. 원래 P3 nominal 성분 오류를 다시 도입하지 않고 실제 파일을 읽는다.
- AVFoundation top-left 캔버스와 CoreGraphics bottom-left 좌표가 다르다. 반쪽 캔버스 no-scale 대조의 초기 y=0 reference는 아래 절반에 그려져 **8.86dB**가 나왔다. 이를 codec 실패로 해석하면 안 된다. y를 `1080 - (topY + height)`로 명시한 수정 reference에서는 **57.29dB, 최대2**다. 원래 full-canvas/중앙 portrait는 수직 대칭이라 이 수정으로 기존 실패 수치를 지우지 않는다.
- standalone generator의 EncodedPixels/CleanAperture/ProductionAperture 결과는 각 조건에서 동일했다. 따라서 관찰한 큰 edge 차이를 aperture 선택만으로 설명할 수 없다.
- sRGB cache의 8-bit BGRA를 독립 ICC 변환과 CI로 읽으면 모두 51.64dB인데, 16-bit generator branch는 34.97dB이다. 서로 다른 추출/디코드 정밀도·재구성 경로 차이를 더 조사해야 하며 정확한 내부 원인을 확정하지 않는다.

### 공간 보간 대조 — 정책 변경 제안과 측정은 구분

sRGB 태그 조건 C의 확대를 기존 CG reference와 비교하면 34.13dB로 **원래 gate 미달**이다. CG none은 28.53dB, low/medium/high는 이 fixture에서 모두 34.13dB였다. CI scale 대조는 50.51dB이다. CI가 실제 compositor와 비슷하다는 것만으로 독립 기준으로 채택하지 않았다.

CoreGraphics/CI를 호출하지 않는 독립 수식도 구현했다: output 중심 `(x+0.5)/2-0.5`를 source 중심 좌표로 바꾸고, 경계를 clamp하고, 네 source 픽셀을 bilinear 가중 평균한다. 두 가설을 모두 기록했다.

| 독립 수식 기준 | native composition | CI scale | 이미 생성된 최종 H.264 |
|---|---:|---:|---:|
| sRGB encoded 성분에서 bilinear | **48.02dB**, 최대10, 평탄부1 | **51.61dB**, 최대2 | **41.28dB**, 최대67, 평탄부0 |
| 선형광으로 변환 후 bilinear | 36.11dB | 34.69dB | 34.66dB |

따라서 이 fixture에서는 encoded 성분의 bilinear가 맞는 가설이며 선형광 가설은 지지하지 않는다. 기존 CG 확대와의 큰 공간 차이를 모두 색 전이 결함으로 부르면 안 된다. 다만 **기존 CG reference를 이 수식으로 조용히 교체하지 않는다.** 40dB는 그대로이며, 기준 영상의 샘플러·좌표·필터 정의를 별도로 검토할 정책 제안이다. 위 수식 결과는 아직 새 제품 품질 계약이 아니다. 최종 H.264의 최대67처럼 국소 큰 오차도 숨기지 않는다. 새 조건으로 JPEG/P3/alpha·자막 두 경로 전체를 다시 통과시킨 것도 아니다.

원래 비교를 유지한 D의 국소 오차:

| 조건 | neutral 최대/RMSE | saturated 최대/RMSE | gradient 최대/RMSE | edge 최대/RMSE |
|---|---:|---:|---:|---:|
| 기존709 | 11/10.34 | 10/8.10 | 12/8.99 | 47/13.81 |
| sRGB 태그 | 0/0 | 0/0 | 3/0.63 | 39/9.71 |
| 수식709 대조 | 0/0 | 10/7.07 | 19/5.30 | 32/10.86 |

sRGB 태그는 평탄한 색 차이를 개선하지만 원래 global gate는 여전히 미달이다. 수식709 대조의 D는 30.37dB이므로 해결책으로 채택하지 않는다.

## Portrait 기하 판정

실제 EXIF 6은 960×540에서 540×960으로 정규화되고 cache preferredTransform은 identity다. 정규화 rotation 검사는 원래 IMG-1A의 byte 차이0 증거를 유지한다. encoded/natural 크기와 format extension을 기록했으며 축소 clean aperture가 이 차이의 원인이라는 증거는 없다.

독립 정확 계산: scale `9/8`, 표시 폭 `607.5`, left `2625/4 = 656.25`, right `5055/4 = 1263.75`. 이상적인 pixel-center/CG 면적 coverage를 가정하면 마지막 픽셀1263도 포함된다. 실제 값은:

| 경로 | 중앙행 점유 시작…끝 | x=1263 |
|---|---|---|
| 원래 CG reference | 656…1263 | 원본 색의 약75% |
| 기존 cache의 native composition | 656…1262 | RGB 0 |
| 균일 불투명 portrait 판의 native composition | 656…1262 | RGB 0 |
| **변경하지 않은 생산 CompositionPlanner** | 656…1262 | 같은 경계 |

균일 판의 fractional placement와 integer-native `[656,1263)` placement는 최대1/61.34dB다. JPEG·alpha·EXIF가 없는 판에서도 같고 기존 생산 경로와 일치하므로 **이 사례는 캐시가 새로 만든 위치 결함보다, CG coverage 기대와 기존 native rasterization 관례의 불일치로 분류**한다. 일반적인 임의 변형의 rounding 법칙까지 증명한 것은 아니다. 원래 assertion과 1263 기대를 삭제하지 않았고 생산 geometry 규칙도 바꾸지 않았다. 후속 계약에서 native parity와 이상적 coverage를 구분할 필요가 있다. `uniform-historical-original-JPEG-export` 진단 항목은 이름 그대로 과거 JPEG 출력이며 새 uniform export라는 뜻이 아니다.

## 보수적인 alpha visibility prototype

실험 traversal만 구현했다:

1. 위 레인부터 현재 구간의 레이어를 보존한다.
2. **원본/정규화 이미지가 완전히 불투명함을 증명했고** geometry가 캔버스를 덮을 때만 아래 traversal을 멈춘다.
3. alpha가 있거나 미확인인 경우 아래 레인을 계속 보존한다.

테스트에서는 normalized alpha를 한 번 스캔해 증명했다. 향후 제품에서는 원본 revision·변환·캐시 invalidation과 묶어야 하며 매 프레임 전체 이미지를 스캔하는 제안이 아니다. 불투명 region 일부가 있다는 이유로 full-frame occlusion으로 처리하지 않는다. clip interval·같은 레인 overlap 규칙은 그대로다.

완전 투명 PNG/partial PNG/불투명 PNG/영상 상단/아래 영상 없음 6개 시나리오의 preview·export를 측정했다. partial은 아래 영상을 보존하고 불투명 PNG와 상단 영상은 하단을 생략한다. 투명+영상 결과와 영상만 결과는 색 관리된 export 비교 **차이0**이다. 투명+아래 없음은 검정이며 최종 H.264 최대 RGB2로 원래 평탄부3 이내다. 반투명 판은 아래 영상과 섞이고 opaque 표식은 아래 유무에 관계없이 같은 전경으로 나타났다. 원래 생산 최적화가 하단을 버리는 문제는 **생산에서 수정하지 않았다**.

## 실제 AVPlayer 관찰

제품 앱이나 다른 소유자 앱을 조작하지 않고 음소거 AVPlayer/AVPlayerItemVideoOutput을 만들었다. 이는 **실제 AVPlayer-backed frame 관찰**이며 headless generator와 다르지만 **owner-visible UI/수동 확인은 아니다**.

- image-only·mixed·partial PNG/영상·portrait 네 composition 모두 readyToPlay.
- 첫 실험은 seek completion 직후 첫 buffer를 받아 56개 중 52개가 이전 seek의 display timestamp였다. 이 결과를 성공으로 세지 않는다(`-01/player-run.log`).
- 제한1초 안에서 requested/display CMTime 일치를 요구한 재검사는 stale 52개를 거부한 뒤 **56/56** 일치 프레임을 받았다. frame0·119, 이미지15/104/105, 반복44/45/46·74/75/76 포함. 각 await seek에는 별도5초 timeout이 있다.
- 네 짧은 실제 재생 관찰에서 display frame0…15를 받았다. 이는 전체 재생 동등성 증명은 아니다.
- 이미 export된 자막 MP4도 별도 AVPlayer로 관찰: frame29/30/59/60의 ROI 큰 변화 픽셀 **0/5904/5698/0**. 이는 baked subtitle이며 앱의 synchronized subtitle layer 검증이 아니다.
- 해당 파일을 frame40에서 재생해 display40…88을 관찰했고 실제 반복 경계45·75를 포함했다. owner manual 확인으로 보고하지 않는다.
- GUI automation을 시도하거나 timeout을 앱 crash로 해석한 일은 없다. 실제 제품 창의 색 표시·layering·drag/resize·장시간 재생·pause 문제는 남아 있다. 기존 A-010/정지 한 프레임 문제를 닫지 않는다.

## 실행·실패·exit code

| 로그 (selftest-work 아래) | 결과 | exit |
|---|---|---:|
| `img1a2-20261027-01/first-run.log` | 새 소스의 복잡한 expression type-check compiler 오류; 첫 증거 보존 | 1 |
| `-01/retry-run.log` | alpha·색 단계·portrait 3개 assertion 검사 통과; 품질 screen 실패는 별도 JSON | 0 |
| `-01/player-run.log` | AVPlayer 1개 테스트 실행; 위 stale 관찰 때문에 신선도 gate 통과로 세지 않음 | 0 |
| `-02/first-run.log` | timestamp guard AVPlayer 통과; 손실 H.264 검정에 정확한0을 요구한 oracle가 실제2에서 assertion1개 실패 | 1 |
| `-03/first-run.log` | 좌표/검정 oracle 수정 대조와 baked subtitle·repeat 2개 통과 | 0 |
| `-04/first-run.log` | kernel 1개 + 기존 TransformModelTests 2개 통과 | 0 |
| `-05/first-run.log` | 독립 bilinear·범위/alpha 2개 통과 | 0 |
| `-06/first-run.log` | 같은 독립 수식에 **기존 최종 파일을 읽는 비교만 추가**, export 반복 없음; 1개 통과 | 0 |
| `-05/opt-out.log` | 환경 변수 없음: 기존12+새9=21개 전부 SKIP, 실패0 | 0 |

검정 oracle 수정은 허용치를 낮춘 것이 아니다: 원래 계약의 lossy flat-field <=3을 사용했다. 초기 JSON의 하드코딩된 `maxRGB:0`은 측정으로 유효하지 않으며 assertion log의 실제2와 후속 `measuredMaxRGB:2`를 사용한다. 이 정정도 최초 실패를 지우지 않는다.

기존 두 회귀는 `TransformModelTests/testExpectedRectHandNumbers`, `testSetValidateAndIdentity`다. 이전 IMG-1A의 export 회귀3개·보호/취소 증거는 보존했지만 이번에 비싼 전체 export suite를 다시 실행하지 않았다. compiler 오류·assertion 실패·stale buffer는 별개다. 이번 실행에서 예기치 않은 앱 crash/종료는 관찰하지 않았다. 제품 앱을 실행하거나 소유자 앱을 종료하지 않았다.

## 자원·재현·남은 관문

새 실험 산출물 약8MiB, 관리 할당량 약7.69GiB로 20GiB 이내다. RSS 기록 지점 최대 약369.80MiB(참 peak 아님). build+test invocation의 `/usr/bin/time -l` 최대 RSS 약442MB이며 컴파일/child 범위를 포함한다. 각 단계의 peak footprint·wall time은 log에 보존했다. GUI·4K·수시간 성능을 주장하지 않는다.

재현: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app/Engine --scratch-path <내부 APFS IMG1A-build> --filter ImageCacheInvestigationTests/<method>`. `OTF_IMG1A2_SOURCE`는 원래 `img1a-20261027-01`, `OTF_IMG1A2_RUN`은 매 실행의 새 selftest-work 하위 root다. 처음 `testColorStages`/`testAlphaVisibility`를 실행한 root를 후속에 `OTF_IMG1A2_CONTROL_RUN`으로 전달한다(이 기록의 default는 `img1a2-20261027-01`). 각 메서드 출력 폴더가 이미 있으면 거부한다. 원래 캐시/출력을 덮어쓰지 않는다. 정확한 filter·환경/결과는 위 로그와 세션 실행 명령에 대응한다.

**권고: REVISE 유지.** 입력 transfer metadata 문제와 sampling reference 문제를 상당 부분 분리했고 native portrait parity와 보수적인 alpha strategy, 실제 AVPlayer 관찰 근거를 얻었다. 그러나 standalone 16-bit generator의 edge 차이는 남고, 원래 CG reference gate는 미달이며 새로운 sampling 계약도 승인되지 않았다. 좁은 sRGB PNG 제어군의 수식 기준41.28dB를 전체 아키텍처 승인으로 확대하지 않는다.

다음 제한된 작업은 (제안) 색 공간·transfer·range와 독립 pixel-center/encoded-bilinear 기준을 별도 검토하고, 16-bit extraction branch를 더 좁힌 뒤, 승인된 동일 기준으로 JPEG/P3/alpha 및 자막 유무 경로 전체를 재검증하는 것이다. 이미지 모델·형식9·제품 import로 넘어가지 않는다. spectrum export·Stage3C-2도 그대로 미착수다. 이번 소스/문서에 staging·commit·push 없음.
