TASK ID: IMG-B-QA-02

> IMG-CP-02 게시 준비: `$REPO`는 저장소 루트, `$SELFTEST_ROOT`는 `$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 실험의 전용 내부 APFS SwiftPM scratch 디렉터리다. 아래 `$VAR`는 실제 실행 전에 해당 경로로 설정한다. 개인 절대경로만 비식별화했으며 원래 명령·실패 재현에서의 경로 역할과 하위 상대경로는 유지했다. 원본 로그는 변경하지 않았다.

MEASUREMENT: VALIDATED
REASSESSMENT: PASS

검증 범위는 **qa02-left-linear-icc-v1의 명시적 진단 계약과 보존된 동일6프레임**이다. 역사적 IMG-B-POC-2의 **EXPORT: QUALITY FAIL**은 변경하지 않는다. 이번 PASS는 Candidate B 제품 채택·전체 edge 무손실·보편적 sampling 정책 승인이 아니다.

1. 실제 Git 상태

저장소 `$REPO`, branch `feature/subtitles`. HEAD/upstream 모두 `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main `44943eadabdf5a37d5242d614e7279813126dfde`. CLAUDE.md를 읽었고 적용 AGENTS.md는 발견하지 못했다. 기존 HANDOFF/ROADMAP 수정과 모든 IMG 실험·문서·.claude/.DS_Store·recovery refs를 보존했다. Git network/switch/reset/clean 작업 없음.

2. 정확한 추가·수정 파일

- 수정: `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/ImageAwareReference.swift` — managed의 NV12 분기2줄만 새 helper 호출로 교체(설명 주석 포함).
- 추가: 같은 디렉터리의 `CanonicalNV12Measurement.swift`, `CanonicalNV12QATests.swift`, `RetainedCanonicalReassessment.swift`.
- 추가: `docs/diagnostics/IMG-B-QA-02-CANONICAL-REASSESSMENT.md` — 이 문서.

새 진단 증거는 `app/selftest-work/img-b-qa02-20261028-01/` 및 `img-b-qa02-20261028-02/`에만 썼다. 첫 root의 preflight.json, original-source/ImageAwareReference.swift, measurement-helper.diff, canonical-at-six-frame-run.swift, canonical-v1-reassessment.json, preservation-check.json, 각 test별 results.json/새 PNG와 log를 보존했다. 기존 fixture/출력은 읽기 전용으로 사용했다. QA01 파일·증거는 변경하지 않았다.

3. 명시적 color/sampling 계약

측정 전 고정 계약(qa02-left-linear-icc-v1): 420v/8bit/video-range, progressive BT.709 primaries/transfer/matrix, Left siting. Y nominal16…235, CbCr16…240/zero128; foot/headroom은 matrix 입력에서 자르지 않고 최종 R′G′B′를0…1로 clamp한다. Kr=.2126,Kb=.0722,Kg=.7152의 역행렬을 Double로 계산한다. Chroma centers=(2i+.5,2j+1), luma centers=(x+.5,y+.5), separable linear interpolation/외곽 tap clamp, Y는 해당 pixel 값이다. 좌표는 top-left raw pixel grid, full clean aperture/identity transform, resize/crop 없이 동일 extent다. 최종 opaque alpha1이며 NV12에 alpha는 없다.

색 관리 계약은 기존 IMG-B의 실제 HDTV ICC→sRGB ICC/relativeColorimetric을 유지한다. BT.709 code values를 source ICC에 지정한 Float32 RGB에서 sRGB RGBA8로 변환한다. 중간 RGB8 quantization 없이 clamp 후 Float32 저장, 마지막 ColorSync8bit quantization이다. Output sRGB의 nonlinear transfer를 사용하며 encoded-sRGB source-over reference는 변경하지 않는다. Actual과 sampled420 reference에 같은 복원/색 관리를 적용한다. 지원하지 않는 format/metadata/ICC/crop/interlace는 거부한다.

규범과 진단 선택을 구분한다. 420v의 range,709 matrix/색 metadata, Apple SDK가 정의하는 Left의 수평 co-sited/수직 centered 위치는 기존 근거다. 샘플 사이의 linear kernel·edge clamp·clamp 시점은 이번 재현 가능한 측정의 명시적 선택이며 BT.709가 유일하게 강제하는 filter나 소유자가 승인한 제품 정책이라고 주장하지 않는다. 근거는 declared sample 좌표를 그대로 보간하고 constants/affine fields를 보존하며 opaque API의 backing별 filter를 피하는 것이다. 다른 reconstruction이 가능하다는 불확실성을 보고한다. 기존40dB/flat≤3, layer/source/geometry/timing 조건은 유지한다. Score를 보고 filter를 고르지 않는다. 먼저 합성 control을 검증한 뒤에만 기존 helper를 연결하고 retained output을 측정한다.

추가로 이전 계약 문서 `IMG-B-POC-1-IMAGE-AWARE-420-GATE.md`는 source chroma nearest, output chroma는2×2 첫 열의 두 세로 sample 평균이라고 명시한다. 이것은 렌더러/source 및 downsampling 규칙이다. NV12를 표시 해상도 RGB로 복원하는 kernel까지 유일하게 정한 것은 아니다. 이번에는 그 렌더러/downsampler를 바꾸지 않고, actual과 reference NV12의 **검사 복원만** 통일했다. Linear는 선언된 Left 위치에서 constant/affine 보존과 재현성이 있는 검사 선택이며, 다른 reconstruction을 BT.709 위반으로 간주하지 않는다. Chroma 경계에는 이 보간에 따른 ramp가 기대되며, unsampled CG sharp edge와의 차이는 별도 보존한다. 새 edge tolerance를 만들지 않았다.

4. 독립 reference 검증

16×16 fixture8개: neutrals(black/white/midgray/추가 gray), red/green/blue/white primary regions, luma step x8/x7, chroma step x8/y8,1pixel fine luma line, 단일 coarse chroma impulse. 정수 polyphase canonical 구현과 별도 triangular basis-function 합산 oracle을 모든 pixel에서 대조했다. Matrix oracle도 독립의 scalar 계수식으로 계산했다. 오차 허용1e−12에서 일치했다.

색 변환은 후보 LUT/렌더러/VideoToolbox를 호출하지 않는다. Canonical Float32 image→sRGB 결과와 별도1pixel CGColor-fill→sRGB oracle의 비교는 모든 패턴에서 **최대0code**였다. 이 둘은 ColorSync를 공유하므로 별개 색 관리 엔진 둘을 검증한 것은 아니다. 실제 source HDTV ICC hash를 강제하여 미지의 curve/primaries를 추정하지 않는다. Source/output ICC 변환은 기존 저장소의 색 계약이고, analytic BT.709 inverse-OETF만으로 ICC를 대체하지 않았다.

손계산 red(Y63,Cb102,Cr240)의 R′=1.0020118721461186, midgray126의 Y′=110/219를 사용했다. Primary flat probes는 red[255,0,0], green[0,255,1], blue[1,0,255], white[255,255,255]였다. 8bit 입력의 primary 근사 오차를 실제 품질 gate 허용치와 구별했다. Chroma x7 UV128/128, y7 Cb112, y8 Cb144와 odd/even luma 위치를 확인했다.

명시적 CI는 source ICC, extendedLinearSRGB working/sRGB output, RGBA8/cacheIntermediates:false/useSoftwareRenderer:true 요청으로 고정했다. 옵션을 sweep하거나 점수에 맞춰 선택하지 않았다.

| control | canonical/독립 oracle max | canonical backing max | CI/canonical max | 기존 VT IOSurface/ordinary max |
|---|---:|---:|---:|---:|
| neutrals | 0 | 0 | 0 | 1 |
| primaries | 0 | 0 | 107 | 215 |
| luma-even | 0 | 0 | 0 | 0 |
| luma-odd | 0 | 0 | 0 | 0 |
| chroma-x | 0 | 0 | 34 | 69 |
| chroma-y | 0 | 0 | 0 | 69 |
| fine-luma | 0 | 0 | 0 | 0 |
| fine-chroma | 0 | 0 | 48 | 110 |

CI backing 차이도 모든 control에서0이다. 그러나 primary 경계107/fine-chroma48 등 canonical과 불일치한다. CI의 explicit color-space 설정만으로 Left 재구성까지 일치한다고 할 수 없다. CI/VT를 정답으로 선택하지 않았고, canonical은 먼저 선언한 sample 좌표/linear algebra에 대한 oracle 검증을 기준으로 채택했다. CI 내부 filter나 phase의 정확한 원인을 확정하지 않았다.

Retained reference의 encoded-sRGB source-over도 frozen CG 구현과 별도 premultiplied integer scalar source-over/opaque top coverage를 **매 프레임 전체 pixel**에서 대조하여 최대0을 얻었다. Source-frame decode/ICC는 기존 BGRA 경로 그대로이며, source-over와 sampled420 downsampler 본문을 변경하지 않았다. 그러므로 codec/BGRA decoder의 내부 reconstruction까지 독립적으로 재구현했다는 주장은 아니다.

5. IOSurface 대 ordinary-buffer

8개 control 모두 active Y/UV bytewise 일치, propagating/non-propagating dictionaries 동일, stride/padding/dimensions/ICC가 같았다.16×16 양쪽 Y/UV strides64, active384bytes, base offsets512/1536, dataSize2048, row padding은 Y768/UV384bytes로 hash도 동일했다. Backing은 A IOSurface/B 일반 allocation으로 다르다.

Retained frame2 regression에서는 actual decode와 ordinary clone 모두420v,1920×1080, Y1920×1080/UV960×540, strides1920/1920, row padding0, offsets512/2074112, dataSize3114720으로 같았다. Active hash `cfc0e1cf6806181ad6fba09770d61c18029ea5427083abdcbc83ef8e41c9ff2d`,709/709/709,top/bottom Left,full aperture,동일 source ICC였다. 두 attachment dictionaries CFEqual=true다. Source/VT ICC hash는 `a1096ca47d80ba9df7f9f8fa87a0b9446d9b6a2c94ab11e4144495616b1eb29b`다. Clean aperture, aspect absence, extended pixels, surface allocation 및 전체 metadata를 JSON에 보존했다.

동일 canonical conversion options/extent에서 최종 helper의 A/B RGB 차이0, 새 canonical 직접 호출 대 기존 managed helper 호출도 전 pixel 차이0이다. 이 검사는 QA01 원래 객체가 아닌 retained MP4 새 decode라는 제한을 유지한다. 단순 ICC·active hash만으로 전체 allocation 같음을 주장하지 않는다.

6. 원래 측정 결함

회귀검사에서 기존 `VTCreateCGImageFromCVPixelBuffer(options:nil)`는 같은 frame2 A/B에서 최대101,위치(1279,539),[146,153,130] 대[45,183,85]를 다시 보였다. QA01은 raw VT CGImage부터95code 차이가 난다는 점을 이미 분리했다. 같은 색 metadata/ICC가 reconstruction을 유일하게 만들지 않아 backing별 결과를 같은 canonical RGB라고 취급한 것이 기존 측정의 결함이다. API 자체의 명세 위반으로 판정하지 않는다. 새 canonical은 active plane/명시적 phase에서만 계산하므로 backing별 opaque 경로를 피한다.

7. 최소 helper 수정과 회귀

독립 control PASS **이후에만** `IBReference.managed`의 NV12 분기를 `return try image(IBCanonicalNV12.bytes(pb))`로 연결했다. BGRA decode/ICC, independent composite/source-over, reference sampled420, renderer/source selection/scheduler/export logic/quality thresholds 본문은 byte-identical이다. Snapshot 대비 자동 exact replacement 검증과 measurement-helper.diff로 범위를 확인했다.

회귀검사는 canonical=managed, surface=ordinary 오차0, 원래 VT101 유지, unsupported matrix/siting/aperture/interlace/aspect 거부, invalid/indefinite CMTime 및 NaN/Infinity 안전 처리를 포함한다. 최종 검토에서 aperture 크기를 intValue 대신 doubleValue로 정확히 비교하도록 좁혔고 fractional aperture16.5 거부도 검사했다. 첫 regression 뒤 이 metadata guard만 강화했으며 실제6-frame 입력의 full integer aperture나 pixel arithmetic은 바뀌지 않았다. 최종 regression을 새02 root에서 통과시켰고6-frame 측정을 불필요하게 반복하지 않았다.

기존 acceptance test나 frozen marker/digest는 갱신하지 않았다. Helper 파일 digest가 바뀌었으므로 과거 Gate2 harness의 frozen-source guard는 그대로 옛 digest를 요구한다. 이를 우회하거나 옛 acceptance test가 새 binary에서 재통과했다고 주장하지 않는다. QA01 결과도 frozen 역사적 증거이며 새 helper와 old VT의 동등성을 전제로 재사용하지 않는다.

8. 보존 MP4의 정체성

기존 보고서/JSON이 기록한 정확한 파일을 사용했다.
`app/selftest-work/img-b-poc2-20261028-01/gate2/six-frames.unvalidated.mp4`

SHA256 `c7781efd86c905b80ed60909bca4df0cae364c0eca85ff580b25a219e93acdf5`,10,763bytes,FHD1920×1080/H.264 avc1/709/video range. 이름을 바꾸거나 validated output으로 승격하지 않았다. Frozen source directory는 `app/selftest-work/img-b-poc1r-20261028-01/reader/`, bottom.mov/top.mov/middle.png의 합성 digest는 `26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1`이다. 각 frame에서 MP4/fixture digest를 전후 확인했다. 재생성/재인코딩/새 MP4 없음.

9. 이전 대 새 프레임별 수치

Primary는 기존의 독립 CG source-over→frozen scalar sampled420 reference와 actual을 **둘 다 같은 canonical NV12 경로**로 바꿔 비교한다. Source BGRA decode, layer/source plan, reference blend/downsample과40dB/flat≤3는 그대로다. Conversion method가 달라졌으므로 옛 점수를 수정한 것이 아니라 버전 분리한 재평가다.

| frame | 과거 PSNR | 과거 flat/max/P99 | canonical PSNR | canonical flat/max/P99 | 새 worst(x,y,channel) |
|---|---:|---|---:|---|---|
| 0 | 52.130106 | 1/28/2 | 56.630054 | 2/15/2 | [34, 55, 2] |
| 1 | 41.458730 | 3/76/3 | 46.259716 | 2/28/2 | [72, 35, 2] |
| 2 | 40.056063 | 3/106/3 | 45.326543 | 2/18/2 | [120, 25, 2] |
| 3 | 39.976343 | 3/103/3 | 47.081484 | 2/20/2 | [982, 566, 2] |
| 4 | 40.091297 | 4/78/4 | 45.737065 | 3/16/3 | [72, 25, 2] |
| 5 | 56.328328 | 2/35/2 | 56.688955 | 2/20/2 | [72, 55, 2] |

**6프레임 모두** PSNR≥40/flat≤3다. 최소 PSNR45.326543dB,최대 flat3. 원래 frame3 39.97634349053969/flat frame4=4/경계106/clone101은 옛 보고서·JSON에 그대로 남아 있다. New aggregate는 canonical-v1-reassessment.json에 따로 기록했다. 과거 QUALITY FAIL을 PASS로 덮어쓰지 않았다.

10. Flat·edge·chroma 오차

Edge-only는 기존 predicate(abs(x−640),abs(x−1280),abs(x−960),abs(y−540) 중≤3)의 union35,973pixel이다. 이 mask의 flat0을 평탄부 통과 증거로 세지 않는다. Flat은 기존의 네100×100 patch 좌표를 그대로 사용했다.

| frame | edge-only PSNR | edge max/P99 | edge worst(x,y,c) | chroma x640/x1280/top-x960/top-y540/prior-crossing max |
|---|---:|---|---|---|
| 0 | 60.691141 | 2/1 | [637, 23, 0] | 2/2/0/0/0 |
| 1 | 46.478264 | 4/3 | [958, 540, 0] | 3/3/4/4/2 |
| 2 | 42.465965 | 9/6 | [960, 540, 2] | 3/7/9/9/7 |
| 3 | 41.005664 | 18/10 | [960, 540, 2] | 2/14/18/18/14 |
| 4 | 46.002414 | 3/3 | [1280, 0, 2] | 2/3/2/3/3 |
| 5 | 61.969408 | 2/2 | [0, 537, 2] | 0/0/0/0/0 |

Frame3 top boundary(960,540,B)의18 및 ID marker 주변 global max28 등 국소 차이는 남는다. 기존106 위치(1279,539)의 frame2 actual/reference는 canonical에서[118,159,148]/[113,156,142], frame3은[116,161,147]/[112,156,143]이다. 모든 ROI의PSNR/P99/worst/actual/reference 값은 frame별 JSON에 있다. Encoder·renderer·reference 기여를 분리할 새 pre-encode canonical buffer가 없으므로 잔여 오차를 한 원인에 귀속하지 않는다.

Unsampled direct CG reference는 별도 보조 비교다. 이 경로는 4:2:0 downsample/reconstruction을 포함하지 않아 primary와 동등한 reference가 아니다. 다음 값을 숨기거나 primary PASS로 대체하지 않는다.

| frame | canonical actual 대 direct CG PSNR | flat/max |
|---|---:|---|
| 0 | 51.194315 | 2/16 |
| 1 | 40.896264 | 3/77 |
| 2 | 40.719271 | 3/90 |
| 3 | 41.455940 | 3/89 |
| 4 | 40.897769 | 3/78 |
| 5 | 56.590387 | 2/31 |

이 보조 경로도 기존 global/flat 수치 기준은 통과하지만 sharp chroma edge 최대90을 포함한다. 이것을 무손실·owner 정성 수용으로 해석하지 않는다. Edge에는 기존 별도 수치 gate가 없으므로 새 tolerance를 도입하거나 실패를 무시한 것이 아니다.

11. Source-frame·layer·geometry·timing

새 read-only 전체 enumeration은 image-bearing decoded samples6개, PTS0…5/30, track/container duration120/600=0.2s,track start0,preferredTransform identity를 확인했다. Invalid/non-numeric time은 비교 전에 거부한다. 압축 packet 수로 presentation count를 대신하지 않았다.

Actual bottom marker0…5,visible top marker2/3가 원래 source decode의 ID와 일치한다. PNG[1,5),top[2,4),top translation(+960,+540),기존 reference geometry와 alpha128/255를 유지했다. PNG가 top을 덮으면 없어지는 translated top marker와 예상 영역/flat probes를 검사했고, CG reference와 scalar oracle coverage가 전 pixel 일치했다.

Final lossy top ROI는 frame2/3 각각518,400Ypixel을 원래 top과 비교했다. Different7484/7810,maxY6/8이다. Bit-identical geometry라고 주장하지 않는다. 원래 frozen pre-encode geometry의 mismatch0 증거는 보존하며 새 MP4가 그 동일 digest라는 사실과 함께 해석한다. 새 측정은 같은 구조/ID/예상 geometry를 뒷받침하며 arbitrary subpixel transform이나 모든 경계의 exact parity를 검증하지 않는다. Source selection/geometry 정책 변경 없음.

12. 명령·exit·fail·SKIP

공통 명령: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/time -l swift test --package-path app/Engine --scratch-path $BUILD_ROOT --filter <filter>`.

Run01/02는 위 새 QA02 directory들의 절대 경로다. `OTF_IMG_B_QA02_RUN=Run01`(최종 metadata regression만Run02), `OTF_IMG_B_QA02_MP4`는8번 MP4 절대 경로, `OTF_IMG_B_QA02_FIXTURES`는8번 reader 절대 경로를 사용했다. Opt-out에는 이 env가 없다.

| log | filter | exit / 결과 |
|---|---|---|
| 01/controls-first.log | CanonicalNV12QATests/testAnalyticalReferenceAndBacking | 0 /1test PASS,0fail,0skip,0.282s |
| 01/helper-regression-first.log | CanonicalNV12QATests/testCorrectedHelperRegressionAndRejections | 0 /1test PASS,0fail,0skip,4.551s |
| 01/retained-six-first.log | CanonicalNV12QATests/testRetainedFrame | 0 /6tests PASS,0fail,0skip,28.935s |
| 01/opt-out.log | CanonicalNV12QATests | 0 /8SKIP,0fail |
| 02/helper-regression-final.log | CanonicalNV12QATests/testCorrectedHelperRegressionAndRejections | 0 /1test PASS,0fail,0skip,4.592s |
| 02/opt-out-final.log | --skip-build, CanonicalNV12QATests | 0 /8SKIP,0fail |

모든 실제 실행을 직렬로 수행했다. Fresh method directory만 허용한다. 전체 production suite·기존 export/playback gate는 실행하지 않았다. Test exit0은 수집/회귀 성공이고 quality PASS는 별도 aggregate 기준으로 결정했다. Opt-out SKIP은 품질 증거가 아니다. 첫 로그 모두 보존했고 compiler/test 첫 실패는 없었다. Existing source freeze mismatch를 새 gate 통과로 우회하지 않았다.

13. Crash·비정상 종료

관찰된 compiler failure/assertion failure/process crash/SIGABRT/tool timeout/sandbox access error는0이다. APFS scratch 접근용 escalation은 승인됐다. Metadata guard 강화는 검토에서 발견한 엄격성 보완이며 실제 fixture의 첫 실패를 숨긴 수정이 아니다. Owner app을 실행·종료하지 않았다. NaN/Infinity JSON은 기존 diagnostics의 string 처리, 오차0 PSNR은999 sentinel을 유지했다(실제999dB가 아님).

14. 자원

Internal APFS IMG1A-build를 사용했고 heavyweight 작업을 병렬 실행하지 않았다. Controls invocation4.91s/maximum RSS466,206,720bytes, 첫 regression8.37s/467,058,688bytes,6-frame invocation33.14s/512,802,816bytes(약489.05MiB),최종 regression9.06s/468,975,616bytes였다. Test-process sampled peak는 retained496,205,824bytes(약473.22MiB)이며 연속 peak 보증은 아니다. 각 frame test 약4.18…5.30s로120s 제한 이내다. 테스트마다 기존 IBDiagnostics의120s/1GiB/512MiB 점검을 수행했다.

보고서 작성 전 새 두 run 할당량1,130,496+32,768=1,163,264bytes(약1.11MiB),repository6,874,943,488+전용 developer root1,515,151,360=약7.81GiB다. 최종 값은 preservation-check.json에 기록한다. 512MiB 추가 artifact/1GiB 관찰 RSS/20GiB combined 이내다. 새 source video/PNG fixture를 생성하지 않았고, 새 PNG는 진단 actual/reference 스냅샷뿐이다.4K/장시간/새 export 없음.

15. 남은 불확실성

Canonical VALIDATED는 명시한 progressive709/Left/full-aperture/지원 ICC와 진단 linear reconstruction 범위다. Linear가 유일한 표준 filter라는 주장은 하지 않는다. CI/VT 내부 boundary reconstruction은 불일치하며,다른 kernel을 쓰는 실제 display/owner 인상까지 이 점수로 보장하지 않는다. Source codec→BGRA decode와 ColorSync는 플랫폼 API에 의존한다. 다른 ICC/HDR/full-range/rotation/crop/interlace/gamut 등은 승인하지 않았고 지원하지 않는 입력을 거부한다. Render/encode/reference 잔여 국소 오차 기여의 정확한 분리는 미해결이다. Sampling ambiguity를 점수에 맞춰 해소한 것이 아니라 predeclared 좁은 계약에 대한 검증/재평가로 한정했다.

16. Candidate B 권고

보존6프레임의 canonical screening은 PASS이며 기존 측정 결함의 제한된 수정은 유지할 근거가 있다. **Candidate B 채택은 보류**한다. 큰 색 경계의 direct-CG 차이,다른 입력·변형·alpha·duration,실제UI/정성 관찰 및 제품 통합은 별개다. 과거 alpha/cache 실패나 모든 Gate1/Gate2를 자동 재승인하지 않는다.

17. 한 가지 제한된 다음 단계

이번 canonical 계약·old/new 표·남은 direct-CG edge 차이를 검토한 뒤,보존된 frame3의 top 경계와 ID marker ROI를 read-only로 좁혀 source raw plane/reference/encoded output의 잔여 오차를 분류하는 후속 진단1건을 권고한다. 새로운 export·AVPlayer·renderer tuning 없이 진행할 수 있다. 이번에는 실행하지 않는다.

18. 최종 Git·보존·금지 범위 확인

Preflight734개 중 허용된 ImageAwareReference.swift만 변경됐다. 다른733개 해시는 모두 일치하며 QA01의 코드·결과·옛 report·실패 logs·MP4·plane dump를 포함한다. 수정 전 helper 전체도 original-source에 hash가 같은 상태로 보존했다. 다른 source 함수는 exact replacement 검증으로 그대로임을 확인했다. Ref 전체는 preflight와 동일,HEAD/upstream/main은1번과 같고 staged diff는 비어 있다. 기존 tracked 변경은 HANDOFF.md/ROADMAP.md 그대로다. 새 Swift 파일들은 기존 untracked IMGBPOC1 디렉터리 안이며 새 Git status 항목은 이 보고서다. 전체 status·최종 hash/할당량은 preservation-check.json에 있다.

역사적 Gate2 QUALITY FAIL·frame3 39.9763·frame4 flat4·boundary106·clone101을 모두 보존했다. Compositor/renderer/source-frame selection/scheduler/independent source-over/export logic 변경 없음. 새 export/AVPlayer 실행,quality threshold 변경,product source 변경,project format/schema 변경,Stage3C-2/spectrum export/image import UI/새 architecture,owner media/project/output 수정,staging/commit/push는 모두 하지 않았다. 보고 후 중단한다.
