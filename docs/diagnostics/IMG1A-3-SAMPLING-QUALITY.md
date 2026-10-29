# TASK ID: IMG-1A-3

**STATUS: REVISE** — 제한된 재검증은 끝났지만 이미지 캐시 아키텍처 채택 관문은 통과하지 않았다. 40dB/평탄부 최대3 기준은 유지한다. 새 sampling/coverage 규약은 소유자 검토용 제안이며 승인된 제품 계약이 아니다.

## 1. 기준·변경·보존

시작/종료 저장소는 `feature/subtitles`, HEAD/upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main `44943eadabdf5a37d5242d614e7279813126dfde`. 기존 ROADMAP/HANDOFF 미커밋 변경과 `.DS_Store`·`.claude/`를 보존했다. fetch·브랜치 전환·staging·commit·push 없음.

이번 새 파일 세 개:

- `app/Engine/Tests/OnTheFrameEngineTests/IMG1A/ImageSamplingContractTests.swift`
- [IMG1A-3-SAMPLING-PROPOSAL.md](IMG1A-3-SAMPLING-PROPOSAL.md)
- 이 진단 보고서

[원래 계약](IMG1A-CONTRACT.md), [IMG-1A 보고서](IMG1A-STATIC-IMAGE-CACHE.md), [IMG-1A-2 보고서](IMG1A-2-QUALITY-GEOMETRY.md)와 이전 실험 소스는 바꾸지 않았다. 기존 소스/문서8개와 이전 증거110개의 SHA256을 시작·종료에 대조한다. 첫 실패·host 종료 로그도 삭제하지 않는다. 생산 CompositionPlanner/ExportService/SubtitleExport/Media/Timeline/ProjectFile/PlayerNSView/spectrum/save 코드는 그대로다.

새 증거는 `app/selftest-work/img1a3-20261028-01`…`-06`에 있다. `-01/preflight.json`은 이전 파일/refs/증거 해시, 각 메서드의 `results.json`은 전체/지역 PSNR·최대·p99·최악 좌표와 RGBA·오차 픽셀 비율을 기록한다. 입력은 이전 생성 fixture와 새 일회용 제어군이며 소유자 데이터를 사용하지 않았다.

## 2. 권장 기준과 승인 경계

**권장 정본의 제안**은 다음을 분리하는 것이다.

1. 실제 파일을 ImageIO로 읽고 orientation을 한 번 정규화, ICC를 sRGB RGBA8로 변환한다. JPEG 생성 전 이상적 원본과의 압축 손실은 별도다. Cache 품질의 reference는 실제 decoded JPEG다.
2. Output은 좌상단 원점, pixel center `(x+0.5,y+0.5)`다. 역변환 후 source center0.5를 빼고 네 tap을 bilinear로 계산한다. Premultiplied encoded-sRGB RGBA를 보간하고 source edge에서 clamp한다. 아래 층과 source-over한 뒤 RGB를 비교한다. Native pixels를 복사한 reference가 아니다.
3. Geometry는 이상적 사각형 coverage와 기존 native raster coverage를 구분한다. Portrait native parity는 이전 생산/균일 판 증거의 `[656,1263)`를 따로 적용한 점수를 보고한다. 임의 변형의 일반 floor/quarter 규칙을 승인하지 않는다.
4. Alpha 작업 색 공간과 709 output 변환은 별도 관문이다. encoded-sRGB source-over와 native가 다르면 점수에 맞춰 혼합 공간을 교체하지 않는다.
5. 같은 최종 RGB 공간에서 global PSNR>=40dB, 평탄부 최대<=3을 유지하고 지역 오차도 보고한다. Lossy 4:2:0을 무손실 exact equality로 검사하거나 큰 국소 오차를 평균으로 감추지 않는다.

이는 **제안**이다. 기존 CG reference를 폐기하거나 target을 낮추지 않았다. Reference 정의/geometry mask/alpha 공간의 소유자 검토가 남았고 아래 결과도 모두 통과하지 않았으므로 ACCEPT 불가다.

### 독립성 검증

CG/CI resampler를 호출하지 않는 수식과 후보 영상 없이 계산한 2×2 예제를 대조했다. output(1,1)의 bilinear는 `[159,64,64]`, premultiplied alpha source-over는 `[88,16,183]`, clamp corner는 `[128,0,127]`, crop offset -2의 sample은 `[96,191,64]`로 통과했다. 첫 crop 검사는 offset -1과 -2의 기대 좌표를 혼동해 실패했으며 수정과 최초 로그를 보존했다.

처음 제안한 source-quarter mask는 **반증**됐다. Full-frame white의 마지막 output center도 캔버스 안인데 마지막 행·열을 제외했다. 첫 점수는 `-01`에 남기되 품질 판정에 쓰지 않는다. 재분석은 이상적 full-frame coverage를 사용하고 portrait native coverage만 이전 독립 생산/판 증거와 따로 대조한다. 높은 점수의 filter를 고른 것이 아니라 명백한 좌표 오류를 고친 것이다. 원래 CG 점수는 유지한다.

## 3. Sampling A/B/C/D 비교

같은 normalized image·FHD·배치·색 공간에서 A=기존 CG scaling, B=독립 pixel-center bilinear, C=native composition, D=최종 H.264다. 아래 B는 위 제안 규약이며 아직 승인된 대체 기준이 아니다.

| 입력 | C vs A (기존CG) | D vs A | C vs B | D vs B |
|---|---:|---:|---:|---:|
| JPEG | 34.59 | 34.31 | 48.36 | 42.32 |
| opaque PNG | 34.13 | 33.22 | 48.02 | 41.28 |
| alpha PNG/video | 40.33 | 37.08 | 42.62 | **38.88** |
| Display P3 SDR | 34.00 | 33.93 | 48.42 | 43.15 |
| portrait | 39.29 | 38.92 | 53.41* | 45.00* |

단위 dB. *Portrait B는 이전 native coverage를 별도 적용했다. 이상적 coverage와의 비교도 JSON에 보존했다. CG의1263 coverage와 native의1262까지라는 차이를 지우지 않았다.

CG와 bilinear 차이는 단순히 같은 filter의 양자화 오차가 아니다. 이전 CG low/medium/high 대 native 약34.13, 독립 encoded-bilinear48.02, linear-light 가설36.11 증거도 그대로다. 높은 점수의 reference만 고르지 않고 제안의 수학·좌표·edge 처리를 명시하며 기존 CG 점수와 병렬 보고한다.

## 4. 16-bit standalone extraction

관측 CGImage는960×540, **16-bit half-float, 64bpp, little-endian, noneSkipLast, decode array 없음, shouldInterpolate=true**다. ICC는 QuickTime nclc(1,13,1). Raw provider를 색 변환 전에 직접 해독했다.

| 대조 | PSNR | 최대 오차 | 최악 좌표 |
|---|---:|---:|---|
| raw half→독립 round/clamp와 reader BGRA8 | 34.87 | 144 | (0,505) blue |
| raw half→8bit 재구성+ICC와 source | 34.92 | 144 | (0,505) |
| 원래16→CG8과 source | 34.97 | 144 | (0,505) |
| 원래16→CG8과 재구성8→ICC | 62.68 | 1 | (763,64) |
| 같은 ICC의 독립 synthetic half→CG8 | 무한대 | 0 | 차이 없음 |
| gray control reader8→source | 51.57 | 2 | (900,70) |
| gray control generator16→source | 49.68 | 2 | (895,70) |
| gray generator16과 reader8 | 51.47 | 1 | (0,0) |

Raw 성분 범위는 **-0.054016…1.159180**이다. 최악 픽셀은 reader8 `[255,252,0]` 대비 half 재구성 `[232,245,144]`다. 오차>3 픽셀은 약6.58%로 색 경계에 몰린다. CG interpolation none/low/high와 CI16→8에서도 같은 큰 차이가 남았다.

**최초 확인점은 이미 raw half-float representation이다.** 후속 ICC/8bit 변환이 더한 차이는 최대1이다. 단순 half 양자화·dither·CG16→8·좌표 flip으로144를 설명할 수 없다. Gray에서는 재현되지 않아 색차가 있는 경계의 고비트 추출/재구성 분기에 국한된다는 근거를 얻었다. 내부 chroma filter/decoder를 특정한 것은 아니며 ProRes 사양이나 제품 renderer 전체의 결함으로 단정하지 않는다. Standalone generator를 그대로 제품 drag preview에 도입하는 것은 미승인이다.

## 5. 국소 품질 (같은 B reference)

| 입력/경로·영역 | 지역PSNR | 최대 | 대표 최악 좌표 |
|---|---:|---:|---|
| PNG preview neutral | 50.63 | 1 | (1422,450) |
| PNG preview saturated | 51.14 | 1 | (202,450) |
| PNG export gradient | 52.41 | 2 | (208,160) |
| PNG export fine lines | **33.25** | 17 | (230,870) |
| PNG export edge | **32.99** | 20 | (159,400) |
| alpha preview neutral | 41.31 | **4** | (1422,450) |
| alpha preview saturated | **38.74** | **5** | (200,450) |
| alpha export neutral | **38.92** | **4** | (1420,450) |
| alpha export edge | **33.71** | 13 | (159,400) |
| portrait export left edge | **36.67** | 37 | (656,77) |
| portrait export right edge | **36.65** | 30 | (1263,1039) |
| portrait export interior | **39.26** | 32 | (828,539) |

PNG 전체 export 최대67은(139,1011), alpha 최대80도(139,1011)의 opaque marker 경계다. Portrait 최대61은(830,89)다. 평균만으로 통과라고 하지 않는다. 4:2:0 경계 번짐과 실제 위치 변화를 분리한다. Native transform/geometry는 이전 생산 경로와 같으며 H.264에서 coverage 밖 RGB가 비제로인 것을 새 배치 규칙으로 삼지 않는다.

Alpha 평탄부 모델도 대조했다. 위치(300,500), alpha128/255에서 encoded-sRGB source-over 예측 `[125,86,132]`, output-ICC blend→sRGB 예측 `[132,86,136]`, 실제 preview `[125,87,137]`, export `[123,86,136]`이다. 단순 working-space 교체로 해결됐다고 할 수 없다. 원래 평탄부<=3에도 미달하므로 **global40dB와 별개의 잔여 blocker**다.

오차0인 영역의 최악 좌표는 유일하지 않다. 첫 재분석 zero-error 행은 초기화 좌표(0,0)가 ROI 밖인 metadata 문제가 있어 worst-pixel 근거로 쓰지 않는다. 위 비제로 좌표/최대/PSNR은 ROI 내 실제 값이다. 후속 source는 ROI 시작점으로 초기화하도록 수정했다.

## 6. 수정 tag·visibility·자막 matrix

원래 JPEG/PNG/alpha/P3/EXIF6 파일을 재사용하고 1초30sample의 sRGB-tagged ProRes cache를 만들었다. Alpha 아래 영상 reference는 기존 생성 H.264의 **tag를 해석한 decoded source색**이다. 인코딩 전 CG 청색 판과는 다른 비교다. Opaque PNG는 alpha 전255, partial PNG는 premultiplied 처리, 보수적 visibility는 아래 영상을 유지한다. 생산 coverage 최적화는 바꾸지 않았다.

각 입력에3초 FHD30을 자막 없음/있음으로 총10개 생성했다. 자막은[30,60)이다. 아래 「자막 배경」은 tight glyph drawRect +2 chroma pixels만 제외한 **image-only 비교**이며 전체 화면 종합PASS가 아니다. 제외 rect는(766,914,388,68). Unmasked image-only reference 대 자막 출력 점수도 별도 보존해 비동등 비교를 섞지 않는다.

| 입력 | preview B | 자막 없음frame30 | 자막 배경frame30 | 자막frame29 (자막 없음) |
|---|---:|---:|---:|---:|
| JPEG | 48.36 | 42.32 | 42.69 | 41.97 |
| PNG | 48.02 | 41.28 | 41.57 | 41.29 |
| alpha/video | 42.62 | **38.88** | **38.99** | **38.51** |
| P3 SDR | 48.42 | 43.15 | 43.35 | 43.15 |
| portrait native-parity coverage | 53.41 | 45.00 | 45.02 | 44.96 |

다른 global 수치가 좋아도 native-parity/reference amendment는 미승인이며 alpha·국소 품질·16bit 분기가 남아 있다. 프로젝트 전체·모든 입력의 품질 수용을 선언하지 않는다. Portrait orientation은 이전 raw JPEG 독립 회전 차이0 증거를 유지하고 일반 rounding 규칙을 신설하지 않는다.

## 7. 프레임·반복·AVPlayer

10개 모두 **image-bearing decoded frame90, PTS격자0…89/30 오류0, track duration3초**다. Frame0/29/30/59/60/89가 지정 시각으로 추출됐다. 1초 cache3회 삽입 경계에서 black flash를 나타내는 광범위한 변화는 관찰하지 않았다. 국소 alpha 오차는 별개이며 이를 품질PASS로 대신하지 않는다.

처음 compressed reader의 buffer94개를 frame으로 센 것은 잘못이었다. 네 개는 sample 수0의 empty/edit buffer다. Coded PTS/B-frame 표현과 display PTS도 구분해야 한다. 첫30 assertions 실패를 남기고 decoded 검사를 별도로 실행했다. Decoded duration/DTS도 invalid일 수 있으므로 PTS 유리수 격자와 track duration으로 판정하며 invalid를0/1프레임으로 바꾸지 않는다.

AVPlayer는 **이번에 재실행하지 않았다**. 이전 stale52를 거부한56/56 seek, frame0/119·cache 경계·실제 재생·baked자막 관찰을 재사용한다. 물리 화면·owner-visible UI·owner manual PASS·제품 synchronized 자막층 검증으로 주장하지 않는다. A-010/정지1frame 문제를 닫지 않는다.

## 8. 실행·실패·종료

| 증거log (selftest-work 아래) | 실제 결과 | exit |
|---|---|---:|
| `img1a3-20261028-01/extraction-first.log` | 16bit raw검사1test, assertion실패0; 품질fail은 별도 기록 | 0 |
| `-01/matrix-first.log` | 출력10개 생성. compressed-buffer 오판으로30 assertions실패, quarter가설점수 보존 | 1 |
| `-02/reanalysis-first.log` | **XCTest host SIGABRT/code6 예상 밖 종료**. JSON에 NaN duration을 써 NSInvalidArgumentException | 1 |
| `-03/reanalysis-first.log` | 비유한값 라벨화·decoded/empty 구분. 재분석1test 실패0 | 0 |
| `-04/controls-first.log` | 새 CGFloat initializer 복합식 compiler error; 실행 전 실패 | 1 |
| `-04/controls-retry.log` | 타입을 명시해 half/gray/alpha control1test 실패0 | 0 |
| `-05/final-controls.log` | hand/16bit/기존geometry3tests, crop 손계산 offset 불일치로1assertion실패 | 1 |
| `-05/hand-retry.log` | 1test skip·setup error1: 기존 결과folder를 fresh-root guard가 거부, 증거 보존 | 1 |
| `-06/hand-control.log` | 새folder의 crop-2 손계산control1test 실패0 | 0 |
| `-06/opt-out.log` | 최종source compile,26tests 모두SKIP·실패0 | 0 |

실제 예상 밖 종료가 **한 번 있었다**. 제품 app이 아닌 진단 XCTest host이며 비유한 CMTime의 JSON 기록이 원인이다. NaN을 `nonfinite:nan`으로 라벨화하고 최초 stack trace/log를 보존했다. Compiler error·assertion failure·folder 보호 거부와 구분한다. 제품 앱이나 다른 소유자 앱을 실행/종료하지 않았다.

기존 `TransformModelTests/testExpectedRectHandNumbers`는 이번에 PASS했다. 비싼 무관 suite·전체 app build·장시간 export를 재실행하지 않았다. 최종 historical matrix wrapper는 raw compressed 수치를 진단으로 남기고 표시 판정은 decoded 검사로 분리했다. SamplingProposal의 quarter가설도 addendum으로 반증했으나 최초 설명/점수를 삭제하지 않았다.

## 9. 자원·재현·다음 경계

macOS26.6.2/Xcode27.1 arm64 Debug, 내부APFS의 기존IMG1A-build scratch다. 새 산출물 약25MiB, RSS 기록점 최대398.83MiB, build+test invocation 최대RSS459,309,056bytes(compiler/child 포함, cache 자체 peak 아님)다. 관리 산출물 약7.72GiB로20GiB 이내다. Export는3초10개를 직렬 실행했다. 추가 재분석은 같은 파일 읽기이며 gray cache는1초다. 4K/수시간 성능을 주장하지 않는다.

재현: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path app/Engine --scratch-path <내부APFS IMG1A-build> --filter ImageSamplingContractTests/<method>`. `OTF_IMG1A3_SOURCE`는 원래`img1a-20261027-01`, `OTF_IMG1A3_RUN`은 새 selftest-work root다. Matrix 생성 뒤 `OTF_IMG1A3_MATRIX`로 testControlledMatrix directory를 지정해 다시 읽는다. 기본값은 이 기록의`img1a3-20261028-01/testControlledMatrix`다. 기존 메서드 출력folder를 거부하며 원시 결과를 덮어쓰는 재시도를 하지 않는다.

**권고는REVISE**다. 40dB를 낮추지 않는다. Alpha의 working color/transfer/premultiplication 차이와 고비트 chroma 경계 추출을 먼저 좁히고, 독립 sampler/native coverage/alpha 공간의 reference amendment를 소유자 검토에 올린다. 이후 같은 승인 계약으로 전체 matrix를 통과시킨다. Standalone generator 대신 명시적8bit reader decode를 격리 대조할 여지는 있지만 생산으로 바꾸지 않았다.

**다음 IMG-1 제품 경계 제안**은 위 선행 관문과 소유자 승인 후에만 image kind/probe·구버전 project 호환성 기반을 독립 checkpoint로 만드는 것이다. Import UI·실제 이미지 timeline 편집·생산 composition/export 통합·format9 확정은 이번에 하지 않았다. 현재 IMG-1로 진행하지 않는다. Stage3C-2/spectrum animation/export 미착수, owner media/project 수정 없음, staging/commit/push 없음.
