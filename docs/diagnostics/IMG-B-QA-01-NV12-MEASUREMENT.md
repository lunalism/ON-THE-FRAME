TASK ID: IMG-B-QA-01
STATUS: MEASUREMENT DEFECT CONFIRMED

> IMG-CP-02 게시 준비: `$REPO`는 저장소 루트, `$SELFTEST_ROOT`는 `$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 실험의 전용 내부 APFS SwiftPM scratch 디렉터리다. 아래 `$VAR`는 실제 실행 전에 해당 경로로 설정한다. 개인 절대경로만 비식별화했으며 원래 명령·실패 재현에서의 경로 역할과 하위 상대경로는 유지했다. 원본 로그는 변경하지 않았다.


기존 진단 helper의 NV12→RGB 변환이 같은 active plane bytes·선언된 이미지 metadata에서도 backing 표현에 따라 달라진다는 결함을 확인했다. VideoToolbox 자체의 API 명세 위반을 판정한 것은 아니다. **AVPLAYER: PASS / EXPORT: QUALITY FAIL**은 그대로다. 렌더러의 통과나 export 품질 수용을 뜻하지 않는다.

1. 실제 저장소와 Git 상태

저장소는 `$REPO`, branch는 `feature/subtitles`다. HEAD와 upstream은 모두 `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main은 `44943eadabdf5a37d5242d614e7279813126dfde`다. CLAUDE.md를 읽었고 적용되는 AGENTS.md는 발견하지 못했다. 기존 HANDOFF.md/ROADMAP.md 수정, 미추적 실험 코드·문서·.DS_Store/.claude, recovery refs를 보존했다. reset/clean/fetch/pull/merge/rebase/switch를 하지 않았다.

2. 정확한 새 파일과 증거 위치

코드·문서 변경은 다음 세 파일에 한정된다.

- `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/NV12MeasurementReference.swift`
- `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/NV12MeasurementQATests.swift`
- `docs/diagnostics/IMG-B-QA-01-NV12-MEASUREMENT.md` — 이 보고서

격리 실행 증거는 `app/selftest-work/img-b-qa01-20261028-01/`에 새로 추가했다. preflight.json, controls-build-run.log, retained-build-run.log, opt-out-build-run.log, preservation-check.json 및 각 test 메서드 이름의 하위 디렉터리(results.json·A/B/C/D PNG)가 있다. 이전 실행 디렉터리에는 쓰지 않았다. 아래 결과의 기준 파일은 `testIndependentSyntheticControls/results.json`과 `testRetainedFrameRepresentationMatrix/results.json`이다.

3. 원래 clone 관찰의 재현 범위

원래 CVPixelBuffer 객체는 보존되지 않았다. 원래 decode 당시의 전체 stride·padding·IOSurface allocation 기록도 없으므로 동일 객체·전체 allocation 재현을 주장하지 않는다. 보존된 MP4 frame2(PTS 2/30)를 새 AVAssetReader로 읽고, 기존 방식대로 propagating attachments를 복사한 ordinary CVPixelBuffer를 만든 **새 진단 fixture**를 사용했다. 새 decode의 active NV12 bytes는 원래 dump와 bytewise 동일했다.

- MP4: `app/selftest-work/img-b-poc2-20261028-01/gate2/six-frames.unvalidated.mp4`
- MP4 SHA256: `c7781efd86c905b80ed60909bca4df0cae364c0eca85ff580b25a219e93acdf5`
- 원래 dump: `app/selftest-work/img-b-poc2-20261028-02/gate2/original-active-420v.bin`
- 원래·새 decode·새 ordinary clone active bytes: 3,110,400bytes, SHA256 `cfc0e1cf6806181ad6fba09770d61c18029ea5427083abdcbc83ef8e41c9ff2d`

동일 retained 영상 내용과 conversion recipe에서 기존 관찰과 똑같은 최대101, 위치(1279,539), sRGB RGB A=[146,153,130], B=[45,183,85], A/B PSNR41.98816976dB를 얻었다. 수치 관찰을 재현했으나 원래 객체의 미기록 allocation까지 같다고 단정하지 않는다.

4. 바이트·layout·metadata 비교

| 항목 | 새 decode A | ordinary clone B |
|---|---|---|
| format / range | 420v,875704438 / video | 동일 |
| extent | 1920×1080, origin(0,0) | 동일 |
| Y plane | 1920×1080, stride1920, active2,073,600bytes | 동일·bytewise 동일 |
| UV plane | 960×540, stride1920, active1,036,800bytes | 동일·bytewise 동일 |
| row padding | 두 plane 모두0bytes | 동일 |
| plane base offsets | 512 / 2,074,112 | 동일 |
| CV dataSize | 3,114,720bytes | 동일 |
| extended pixels | [0,0,0,0] | 동일 |
| backing | IOSurface 있음 | 없음 |
| allocation | AVAssetReader decode | CVPixelBufferCreate, attrs:nil |

Y SHA256은 `577fbbfa5597d0372ba5f41cecd3657f3a63dd0bfb79370144608813ad0c589b`, UV는 `79d10c26c388a35b5f5d00c18c1d34a9fcbf8573c555c92b362d44cc47ea5273`로 양쪽 동일하다. Row padding과 active bytes를 구분했다. Plane 밖의 allocator bookkeeping/tail bytes 전체를 같다고 주장하지 않는다. A IOSurface의 실제 plane strides도1920이고 allocation3,114,784bytes다. IOSurface의 top-level bytesPerRow2884는 planar pixel stride로 사용하지 않았다.

Propagating / non-propagating attachment dictionaries 모두 CFEqual=true다. 기존 propagating-only clone recipe로도 non-propagating이 빈 dictionary여서 같았다. Primaries/transfer/matrix 모두 ITU_R_709_2, top/bottom chroma location 모두 Left, full clean aperture1920×1080·offset0, fieldCount1, QTMovieTime40/600이 같다. PixelAspectRatio/gamma/chromaSubsampling/displayDimensions는 양쪽 모두 absent다. 없는 aspect attachment를 명시적1:1 attachment와 같다고 기록하지 않았다. 같은 raw pixel grid와 identity 배치로 검사했고 orientation/crop/resize를 적용하지 않았다. Track 변환을 새로 적용한 검사도 아니다.

Raw ICCProfile attachment는 양쪽 absent이고, CGColorSpace attachment와 색 attachment로 얻은 실제 HDTV ICC는 동일하다. Source 및 VT CGImage ICC SHA256은 `a1096ca47d80ba9df7f9f8fa87a0b9446d9b6a2c94ab11e4144495616b1eb29b`다. Full dictionary·plane별 hash·추가 metadata는 JSON에 보존했다. 작은16×16 fixture에서도 두 plane의 stride64·offset512/1536 및 초기화한 row padding hash가 서로 같았다.

5. IOSurface 대 ordinary conversion

A/B는 기존 helper와 같은 `VTCreateCGImageFromCVPixelBuffer(pb, options:nil, imageOut:&cg)`를 호출한다. Working-space/chroma 재구성 옵션은 명시하지 않는다. 두 VT 출력은 status0,1920×1080,8bpc/32bpp, bytesPerRow7680, bitmapInfo8198(32Little/noneSkipLast), 동일 HDTV ICC다. 새 helper가 이 layout에서 RGB channel을 직접 해석한 결과와 기존 sRGB CGContext normalization 이후를 별도로 비교했다. 기존 `IBReference.bytes(IBReference.managed(pb))`와 새 capture의 sRGB 결과는 A/B 각각 전 pixel 오차0으로 경로 일치를 확인했다.

| retained frame2 진단 비교 | 최대 RGB 코드 오차 | PSNR dB | 비고 |
|---|---:|---:|---|
| VT raw A/B, ICC 정규화 전 | 95 | 42.578336 | worst(1279,539), red |
| VT sRGB A/B | 101 | 41.988170 | 기존 clone 차이 재현 |
| C(A)/C(B) | 0 | 무한대 | backing 독립 |
| D(A)/D(B) | 0 | 무한대 | backing 독립 |
| A/C | 39 | 48.947867 | 별도 진단값 |
| B/C | 83 | 42.572364 | 별도 진단값 |
| D/C | 40 | 46.961331 | 두 경로의 동등성 실패 |

JSON의 PSNR999는 오차0 sentinel이며 실제999dB 측정이 아니다. `differentPixels`는 오차>0 pixel 수다. 이전 helper의 다른 threshold count와 직접 섞지 않는다. Global PSNR이 높아도 큰 국소 오차나 conversion 계약 불일치를 해소하지 않는다.

6. 독립 reference와 검증

C는 후보 렌더러의 변환 함수·LUT를 호출하지 않는다. 측정 전에 다음 계약으로 고정했고 결과를 보고 PSNR이 높은 변형을 고르지 않았다.

- Y′=(Ycode−16)/219, Cb/Cr=(code−128)/224. R′=Y′+1.5748Cr, G′=Y′−0.187324Cb−0.468124Cr, B′=Y′+1.8556Cb.
- Left siting은 SDK CVImageBuffer.h의 “수평 왼쪽 luma와 co-sited, 수직 centered” 정의를 따른다. Luma centers(x+.5,y+.5), chroma centers(2i+.5,2j+1). 따라서 chroma 좌표(x/2,y/2−.25), bilinear reconstruction·외곽 clamp다. Bilinear는 이번 진단의 고정 규칙이며 기존 accepted sampling contract 변경이 아니다.
- Double 계산 후 RGB를[0,1]로 clamp, opaque Float32 RGBA/실제 source709 ICC의 CGImage로 만든 뒤 ColorSync/CGContext를 통해 sRGB RGBA8로 변환한다. Matrix 결과를 그대로 sRGB로 retag하지 않는다. 중간8bit 반올림은 없고 최종8bit quantization을 한다.

16×16 다섯 패턴: black/white/midgray/saturated-red patch, luma step x8, luma step x7, chroma step x8, chroma step y8. Patches와 chroma 양쪽 색을 고정했다. 독립 hand arithmetic: midgray126→110/219, red(Y63,Cb102,Cr240)→[1.0020118721461186,0.0022928364318330063,−0.0007702707110241458]. 코드 작성 중 수식으로 검산한 기대값을 첫 실행 전에 넣었다. Black/white의 최종 RGB는0/255, midgray는[139,139,139], saturated red는[255,0,0]이다. Float image 변환과 별도1pixel CGColor-fill/ICC 변환의 gray/red 결과도≤1code로 대조했다. ColorSync를 공유하므로 완전히 별개 색 관리 구현 둘을 검증한 것은 아니다.

독립 sampling 기대값은 x7에서 UV128/128, y7에서112/144, y8에서144/112다. Odd/even luma 경계가 이동 없이 black/white를 유지하는 것도 assert했다. C backing invariance를 모든 패턴과 retained frame에 assert했다.

D는 CIImage에 실제 source ICC를 지정하고, CIContext(useSoftwareRenderer:true, workingColorSpace:extendedLinearSRGB, outputColorSpace:sRGB, cacheIntermediates:false), render RGBA8/full extent를 사용했다. Software는 요청 옵션이며 내부 구현 장치까지 증명한 것은 아니다. D는 backing 독립이지만 Left 수평 chroma 경계에서 C와 일치하지 않아 canonical 대체 경로로 승인하지 않았다.

7. 처음 확인한 divergence

최초로 관찰 가능한 차이는 **VideoToolbox가 반환한 CGImage의 RGB code values, 기존 ICC→sRGB CGContext draw 이전**이다. (1279,539)에서 raw A=[135,142,119], B=[40,174,75], red차95다. ICC normalization 후 A=[146,153,130], B=[45,183,85]로101이 된다. Metadata/ICC 불일치나 마지막 sRGB tag 차이만으로 설명할 수 없다. API 내부의 구체적인 hardware kernel을 추정해 확정하지 않는다.

8. 국소 오차와 색 공간 결과

Luma-only even/odd step에서는 A=B=C=D 오차0이다. Chroma 경계에서는 다르다.

| 합성 패턴 | A/B sRGB 최대 | A/C 최대 | B/C 최대 | D/C 최대 |
|---|---:|---:|---:|---:|
| patches | 92 | 44 | 93 | 45 |
| luma-even8 / luma-odd7 | 0 | 0 | 0 | 0 |
| chroma-x8 | 69 | 1 | 69 | 34 |
| chroma-y8 | 69 | 34 | 35 | 0 |

예를 들어 chroma-y8 y7에서 A는[139,139,139], B는[193,129,70], C/D는[167,134,105]다. 수평/수직 phase 또는 reconstruction 차이라는 설명을 뒷받침하지만 VT의 정확한 filter를 reverse-engineer한 결론은 아니다. A가 모든 Left-siting 경계를 맞추거나 B가 정답이라는 결론도 아니다.

Retained frame의 x636…643 전 높이 ROI에서 A/B max76, A/C max1, B/C max75, D/C max39다. Top 경계 y536…543,x960…1919에서 A/B max101, A/C39, B/C79, D/C39다. 원래 worst 주변8×8에서도 같은101을 확인했다. 최외곽 padding만의 문제가 아니다. 원래 worst pixel의 C=[118,159,148], D=[103,165,119]로 두 explicit 경로도 다르다. 따라서 ICC를 명시했다는 이유만으로 D를 승인하거나 global 점수로 변환 정책을 선택하지 않는다.

9. 신뢰 가능한 기존 증거

원래 MP4·plane dump/hash, 6 presentation frames·PTS·duration, source frame identity, 구조/geometry byte checks, scheduler/admission 결과는 이번 RGB 변환 결함으로 반증되지 않는다. AVPLAYER PASS는 기존 API seek-buffer delivery 범위에서 유지하며 재실행하지 않았다. 기존 PSNR·flat·boundary 수치는 **당시 고정된 conversion 경로가 산출한 역사적 관찰값**으로 신뢰·보존한다. 다만 backing 독립 canonical 화질의 검증값으로 사용할 수는 없다. RGB 정규화를 거치지 않은 바이트/구조 검사를 RGB 화질 점수와 구별한다. 전체 이전 Gate1을 재승인한 것도 아니다.

10. 재평가가 필요한 비교

`IBReference.managed`의 NV12 분기를 통과한 actual/reference 관련 RGB PSNR·flat·edge·native-component 값: Gate1 reader, Gate2 player의 RGB 점수, Gate2 decoded export 대 sampled420/CG reference, post-vs-pre RGB, 최종 native-video RGB 비교가 대상이다. Source/reference 한쪽이 BGRA이고 actual이 IOSurface NV12인 비교도 같은 재구성 계약으로 통일해야 한다. 이미 같은 backing을 사용한 두 결과라도 양쪽 bias가 상쇄된다고 보장하지 않는다. 이 조사만으로 이전 모든 수치가 틀렸다고 단정하지 않는다.

원래 frame3 PSNR39.97634349053969dB, frame4 flat4, 경계106, clone101을 유지했다. Canonical re-score는 하지 않았고 위 C/D 수치는 QA01에 버전 분리한 conversion 진단값이다. 과거 IMG1A ProRes-cache alpha 실패 등 다른 실험은 재판정하지 않았다. **기존40dB/flat≤3 기준과 EXPORT QUALITY FAIL은 유지한다.**

11. 실행 명령·exit·SKIP

공통: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, `/usr/bin/time -l swift test --package-path app/Engine --scratch-path $BUILD_ROOT`. 테스트는 직렬 실행했다. 아래 opt-in의 RUN은 저장소 절대 경로의 `app/selftest-work/img-b-qa01-20261028-01`이다.

| invocation | 추가 env / filter | exit | 결과 |
|---|---|---:|---|
| controls-build-run.log | OTF_IMG_B_QA01_RUN=RUN; --filter NV12MeasurementQATests/testIndependentSyntheticControls | 0 | 1 test PASS,5패턴,0fail/0skip,0.177s |
| retained-build-run.log | RUN 및 아래 MP4/DUMP; --filter NV12MeasurementQATests/testRetainedFrameRepresentationMatrix | 0 | 1 test PASS,0fail/0skip,10.951s |
| opt-out-build-run.log | opt-in env 없음; --filter NV12MeasurementQATests | 0 | 2 tests SKIP,0fail,0.001s |

Retained env:
`OTF_IMG_B_QA01_MP4=$SELFTEST_ROOT/img-b-poc2-20261028-01/gate2/six-frames.unvalidated.mp4`
`OTF_IMG_B_QA01_DUMP=$SELFTEST_ROOT/img-b-poc2-20261028-02/gate2/original-active-420v.bin`

새 출력 디렉터리가 이미 있으면 거부하므로 재실행 때에는 새 RUN을 지정해야 한다. 최초 compilation/test 실패는 없었다. 기존 다른 테스트 파일의 Swift warning은 첫 build 로그에 남아 있다. QA PASS는 진단 assertion 통과이며 export gate PASS가 아니다. 기존 Gate1/Gate2 acceptance 테스트는 재실행하지 않았다.

12. 실패·crash·timeout·자원

관찰된 compiler error/test failure/crash/sandbox failure/tool timeout은0이다. Internal APFS scratch 사용을 위한 sandbox escalation은 승인됐다. Controls invocation5.37s, retained12.66s, opt-out1.78s였다. Test-process sampled RSS는 controls39,010,304bytes(37.20MiB), retained282,558,464bytes(269.47MiB); invocation maximum RSS는 controls465,797,120bytes(444.22MiB, compiler 포함), retained299,122,688bytes(285.27MiB), opt-out124,092,416bytes다. 관찰치이며 연속적인 RSS peak 보증은 아니다.

보고서 작성 직전 새 QA artifacts 할당량569,344bytes(0.54MiB), repository6,873,657,344bytes+전용 developer root1,512,312,832bytes=약7.81GiB였다. 512MiB 추가 artifact/1GiB 관찰 RSS/20GiB combined limit 이내다. C 루프도 단일FHD frame으로 제한했고4K/장시간/동시 heavyweight 작업을 하지 않았다. 기존 IBDiagnostics의 finite JSON 처리와120s/1GiB/512MiB 검사를 사용했다. 오차0 PSNR은999 sentinel, 입력 PTS는 기존 reader의 exact-frame 검사를 사용했다. 최종 재확인 할당량은 preservation-check.json에 기록한다.

13. 정확한 최소 수정 제안 — 미적용

검토 후 `ImageAwareReference.swift`의 `IBReference.managed` **NV12 진단 분기만** options:nil VT 변환 대신 버전이 명시된 canonical NV12→sRGB helper를 호출하도록 바꾸는 안을 제안한다. Helper는420v/709/progressive/Left/full-aperture 계약을 검증하고 active plane를 읽어, C의 고정된 Left bilinear phase·limited matrix·float RGB·실제 source ICC→sRGB8 clamp/quantization을 사용한다. 지원하지 않는 metadata는 조용히 fallback하지 않고 거부한다. BGRA와 renderer·scheduler·threshold는 유지한다. 기존 API가 반환하는 opaque reconstruction이나 ordinary clone의 더 좋은 PSNR을 정답으로 삼지 않는다.

이것은 이번에 검증한 좁은 범위의 **수정 제안**이다. Chroma bilinear 선택과 ICC/clamp 순서를 측정 계약으로 검토해야 하며 모든 색/gamut/interlace/crop에 대한 일반 해법으로 승인하지 않는다. D는 C와 최대40 차이가 있어 최소 수정의 대체 구현으로 제안하지 않는다. 기존 helper/reference/Gate1/Gate2 테스트는 변경하지 않았다. 사용자 지시의 “If an existing helper must change, report the exact proposed fix and stop for review”에 따라 여기서 구현을 멈춘다.

14. 한 가지 제한된 다음 단계 — 미실행

위 canonical 계약 검토 후, 보존된 동일 MP4의6프레임과 frozen source/reference를 **한 번의 직렬 읽기 전용 remeasurement**로 새 디렉터리에 비교하는 후속 작업을 제안한다. Actual과 NV12 reference에 같은 canonical 경로를 적용하고, 원래 기준40dB/flat≤3와 경계/ROI를 모두 유지하며 old/new metrics를 나란히 기록한다. 새 export·AVPlayer는 필요 없다. 이번 조사에서는 실행하지 않았고 Gate2의 판정 변경도 하지 않았다.

15. 최종 Git 및 보존 확인

Preflight에 기록한 기존 tracked source·문서·이전 실험 코드·산출물700개 SHA256 모두 일치한다. 기존 compositor/reference/scheduler/Gate1/Gate2 acceptance test를 포함한다. 모든 refs가 preflight와 동일하며 staged diff는 비어 있다. HEAD/upstream/main은1번과 같다. 기존 tracked 수정은 HANDOFF.md/ROADMAP.md 그대로고, 새로운 Git 표시 차이는 이 QA 보고서뿐이다(새 Swift2개는 기존 untracked IMGBPOC1 디렉터리 안). Git status 전체는 preservation-check.json에 남겼다.

원래 Gate2 QUALITY FAIL 및 이전 first-failure 로그·MP4·plane dump·보고서를 모두 보존했다. Production/experimental renderer 변경, 새 export, AVPlayer 실행, threshold 변경, project format/schema 변경, owner data 수정, product image import/format9, Stage3C-2, spectrum export, staging/commit/push는 모두 하지 않았다. 보고 후 중단한다.
