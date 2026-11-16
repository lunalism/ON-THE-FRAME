TASK ID: IMG-GPU-01
STATUS: GPU FEASIBILITY DEMONSTRATED

2026-10-29. 단일 Metal NV12 경로에서 최소 프레임과 기존 여섯 프레임의 정확도를 유지하고 matched Release 완료 지연·CPU 시간을 줄였다. 이 Mac·고정 fixture·직접 버퍼 시험의 feasibility이며 제품 아키텍처 승인·안정된 30fps playback 검증은 아니다.

경로 표기: `$REPO`는 저장소 루트, `$SELFTEST_ROOT=$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 전용 내부 APFS `IMG1A-build` SwiftPM scratch다. 개인 절대경로는 기록하지 않는다. 증거 A는 `$SELFTEST_ROOT/img-gpu01-20261029-01`, B는 `$SELFTEST_ROOT/img-gpu01-20261029-02`다.

### 1. 실제 저장소와 Git 상태

브랜치 `feature/subtitles`, HEAD 및 cached upstream `e89534d2778295fcfc0ba4094527af25d2cf1cd2`, main `44943eadabdf5a37d5242d614e7279813126dfde`였다. index는 비어 있고 기존 .DS_Store 3개와 .claude/settings.json이 untracked였다. CLAUDE.md와 기존 제약을 확인했으며 적용 AGENTS.md는 이전 감사에서 발견되지 않았다. 현재 상태는 기대값과 일치했다. 원격 네트워크 조회·fetch·브랜치 전환은 하지 않았다. refs와 시작 시 기존 파일 3,251개의 해시를 A/preflight.json에 보존했다.

POC1R/POC2, QA02, PERF03–05, OPT01, 기존 Candidate B 픽셀 구현과 native/custom 구조 경계를 검토했다. 과거 33.140ms는 Release의 image-no-top active 중앙값이고 pooled image-active 값과 다르다. 과거 offline66.726fps, calibrated3/90 miss, SIMD wall0.53%는 역사적 관찰로 유지하며 이번 matched 결과의 대조군으로 사용하지 않았다.

### 2. 선택: Metal 하나

Core Image는 작업/출력 색공간과 source-over를 제공한다. 하지만 이 실험에서는 encoded-sRGB premultiplied source-over, 기존 ICC LUT, 제한-range YUV 행렬, 명시적인 Left output chroma를 각각 고정해야 한다. Metal을 선택하면 원래 레이어를 유지하면서 NV12 두 plane을 직접 읽고 쓰는 단일 2×2-block kernel로 같은 수식을 검사할 수 있다. Core Image 구현이나 parameter sweep은 하지 않았다.

Apple의 [CVMetalTextureCacheCreateTextureFromImage](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)) 문서의 plane view API와 [Metal feature tables](https://developer.apple.com/metal/feature-sets/)를 참고했다. Core Image 비교 근거는 [CIContext](https://developer.apple.com/documentation/coreimage/cicontext)와 [outputColorSpace](https://developer.apple.com/documentation/coreimage/cicontextoption/outputcolorspace)다. 실제 interoperability는 아래 실행에서 별도로 확인했다.

앱에서 명시적으로 NV12를 CPU upload하는 경로 없이 CVMetalTextureCache로 R8Unorm/RG8Unorm view를 만든다. PNG는 RGBA8Unorm shared texture에 한 번 upload하며 전체-frame BGRA 출력·ProRes 캐시·CPU fallback은 없다. 드라이버 내부 copy의 부재까지 계측한 주장은 아니다.

### 3. 새 파일

- `app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/MetalNV12Experiment.swift`: 런타임 Metal 소스, pipeline/cache, PNG/LUT resource, NV12 view·출력 할당, completion 동기화.
- `app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/MetalNV12ExperimentTests.swift`: opt-in 최소/여섯 프레임 정확도와 cached-input benchmark, 별도 fresh-decode-to-delivery benchmark.
- `docs/diagnostics/IMG-GPU-01-METAL-FEASIBILITY.md`: 이 보고서.

기존 소스·Package.swift·renderer·scheduler·reference 수정은 없다. 새 증거는 A/B에만 썼다. 주요 파일은 A/predeclared-contract.json, A/bounded/results.json, A/measurement-summary.json, B/predeclared-decode-contract.txt, B/bounded/results.json, B/measurement-summary.json, A/preservation-check.json 및 네 실행 로그다.

### 4. Fixture·색 계약

1920×1080, 30fps grid, 정수 위치·1:1 sampling이다. 기존 POC1R reader의 bottom.mov/top.mov/middle.png 결합 digest는 `26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1`다. bottom[0,6), PNG[1,5), top[2,4), top 이동(+960,+540)을 유지한다. sourceIn0이므로 보이는 top frame ID는2/3이다.

최소 입력은 phase1 bottom과 새 uniform PNG다. PNG는 encoded-sRGB premultiplied RGBA `[100,25,13,128]`, alpha128/255(8-bit에서의 50%)이며 디스크 PNG로 저장 후 다시 decode하여 모든 alpha128을 확인했다. PNG SHA256은 `1c2f85ee1b69604dafbef300096d9a7034e5168b4ae2f209eb10848fc96f630a`다.

비디오는 709 primaries/transfer/matrix, NV12 video range(Y16…235, C16…240,128중립), Left chroma다. 입력 chroma는 기존 baseline의 nearest2×2를 유지한다. source-over는 encoded-sRGB에서 PNG premultiplied RGB + (1−alpha)×background로 수행한다. 기존 ColorSync4097-point Float LUT로 709↔sRGB를 변환하며 LUT를 CPU에서 공통 준비한다. output luma는 각 pixel, Left chroma는 2×2 첫 열 두 수직 sample 평균이다. Float 산술, clipping0…255, 양수 half-away rounding을 명시하고 UNORM store 전에 코드 값을 반올림한다. Metal fastMath는 끄고 FMA를 요청하지 않았다.

QA02 Left-linear-ICC는 진단용 측정 reference다. 이를 범용 제품 sampling 정책으로 승인하지 않았다. 사전 gate는 기존 globalPSNR≥40dB·flatMax≤3·정확한 geometry/order/sourcePTS다. GPU raw 차이는 별도 보고하고 at-most-one code rounding 차이도 독립 RGB 관문을 거치도록 했으나 실제 차이는 모두0이었다.

### 5. 단일 프레임 정확도

먼저 최소 phase1만 실행했다. CPU와 GPU active Y/UV 차이는0, canonical RGB 최대 차이0이었다. 독립 sampled420 reference 대비 PSNR70.389949dB/flat0/edge0/global최대9, 직접 CG reference 대비52.481440dB/flat1/edge1/global최대17로 양쪽 기존 관문을 통과했다. 최초 single-frame 통과를 기록한 뒤에만 확장했다.

전체 버퍼 비교로 layer source-over 결과가 baseline과 동일함을 확인했으며 source marker와 기존 reader의 정확한 samplePTS 검사를 사용했다. minimum-gate-PASS 전에는 성능 benchmark를 실행하지 않았다. correctness 중 얻은 first-use 시간은 gate 통과 뒤 해석했다.

### 6. 확장 여섯 프레임

phase0…5의 CPU/GPU raw 해시가 모두 일치했으며 frozen PERF02 Debug 해시와도 모두 일치했다. Y/Cb/Cr 최대 차이 각0, canonical RGB 최대 차이0이었다. phase2/3의 top 영역 518,400 luma pixel 비교 불일치0, visible marker ID2/3이었다. CPU/GPU paired 성능 시험에서도 모든 결과 해시를 검사했다. missing/stale output은 관측하지 않았다.

단, 이 실험은 직접 CVPixelBuffer 반환이다. source readPTS는 정확히 phase/30을 검사하지만 GPU 출력의 phase/30은 테스트 sidecar이며 실제 AVVideoCompositing callback timestamp·CM sample 출력 검증이 아니다. AVPlayer/export를 새로 실행하지 않았다.

### 7. Alpha·chroma·boundary

확장 PNG의 alpha128/255, x640/1280 이미지 경계, top x960/y540 경계를 포함한다. CPU와 GPU의 canonical edge-region 차이는 모두0이었다. 원본 layer identity를 합성 전까지 유지했고 top 불투명 영역은 원본 Y/UV를 복사한다.

독립 reference 자체에 대한 오차는0이 아니다. sampled420의 전체 최대16, edge최대2, flat최대2였다. 직접 full-resolution CG 대비 경계 최대87이 남는다. 이는 이전 baseline에도 동일하게 존재하는 420 sampling/색차 경계 차이이며 GPU가 새로 만든 차이가 아니다. global·flat gate 통과를 국소 오차 제거로 해석하지 않는다. 최악 좌표·채널·probe 값은 A/bounded/results.json에 보존했다.

### 8. QA02 비교

변경하지 않은 independent decoded-BGRA+ICC, CG source-over 및 독립 sampled420 reference를 사용했다. candidate/baseline 간 RGB 비교는 명시적으로 IBCanonicalNV12.bytes를 사용했다.

| phase | sampled420 PSNR dB | flat max | edge max | global max | 직접 CG PSNR dB / flat max |
|---|---:|---:|---:|---:|---:|
| 0 | 65.263362 | 0 | 2 | 15 | 52.720384 / 1 |
| 1 | 50.635966 | 2 | 2 | 9 | 42.732953 / 1 |
| 2 | 46.883781 | 2 | 2 | 16 | 42.250538 / 1 |
| 3 | 50.634639 | 2 | 2 | 15 | 42.433968 / 1 |
| 4 | 47.673111 | 2 | 2 | 7 | 42.670597 / 1 |
| 5 | 69.445844 | 0 | 0 | 15 | 68.853386 / 0 |

모두 기존 기준을 통과했다. 역사적 Gate2 QUALITY FAIL·QA02 retained-export 재측정 PASS는 별도 이력으로 유지한다. 이번에는 기존 export를 다시 만들거나 과거 판정을 덮어쓰지 않았다.

### 9. Matched Release CPU/GPU 시간

Apple M4 Pro/Mac16,8, RAM24GiB, 논리CPU12, macOS26.6.2(25G83), Swift6.4, 기존 Xcode/APFS scratch에서 -O/WMO/enable-testing/OTF_PROTO_RELEASE로 컴파일했다. opt-in test는 Release assert guard를 통과했다. 실행 뒤 thermal/performance warning 기록 없음은 확인했지만 실행 내내 주파수·열 상태가 같았음을 보장하지 않는다.

같은 입력·출력 allocator 속성으로 AB/BA3×6 paired 실행했다. image-active는 구현당 n12, image-no-top/top/copy는 각각n6이다. 아래는 ms, 중앙값/최대값이다. static PNG/LUT/pipeline 준비는 별도 계측했다.

| 범위 | CPU wall | GPU wall | CPU processCPU | GPU processCPU |
|---|---:|---:|---:|---:|
| cached image-active 완료 전달 | 30.252708 / 34.803125 | 1.411709 / 1.788541 | 30.1885 / 34.503 | 0.4955 / 0.579 |
| cached image-no-top | 33.896042 / 34.803125 | 1.394375 / 1.544417 | 33.8765 / 34.503 | 0.4565 / 0.525 |
| cached image+top | 25.961209 / 27.066708 | 1.413521 / 1.788541 | 25.8835 / 27.046 | 0.5025 / 0.579 |
| cached copy control | 1.349292 / 1.427375 | 0.812813 / 2.075875 | 1.3485 / 1.427 | 0.3945 / 0.510 |
| fresh-decode image-active 전체 | 52.053438 / 57.538334 | 21.565938 / 28.626834 | 36.690 / 43.077 | 7.476 / 10.445 |
| fresh-decode image-no-top | 47.812187 / 54.001542 | 14.901104 / 18.425625 | 38.7215 / 43.077 | 5.0935 / 5.930 |
| fresh-decode image+top | 53.744646 / 57.538334 | 26.662104 / 28.626834 | 35.129 / 35.644 | 10.244 / 10.445 |
| fresh-decode copy control | 15.649271 / 53.191791 | 14.048459 / 15.712000 | 6.1775 / 12.019 | 5.2975 / 6.942 |

cached 완료 전달은 output allocation/tag, GPU plane view/encode/submit/completion/cache flush 또는 CPU instruction/render를 포함한다. fresh-decode 전체는 새 AVURLAsset/Reader 생성·source decode·ID validation부터 완료 NV12 반환까지 실제로 측정했다. 단순 stage 합산 추정이 아니다. 출력 raw validation은 timing 밖에서 매번 수행했다.

image-active paired 개선 중앙값은 cached wall95.3961%/CPU98.4749%, fresh-decode wall59.4650%/CPU79.4484%다. fresh-decode wall 개선 범위45.4680…77.5217%다. 사전 wall≥5% 및 CPU 개선 기준을 충족한다. 서로 다른 workload를 섞지 않았고 n<20이므로 P95를 제시하지 않았다. 과거 CPU 시간과 비교하여 개선율을 계산하지 않았다.

### 10. GPU 실행·transfer·sync·초기화

cached image-active n12의 중앙값/최대값(ms):

| 단계 | 중앙값 | 최대 |
|---|---:|---:|
| 출력 allocation/tag | 0.102646 | 0.145042 |
| NV12 plane view 생성 | 0.131833 | 0.179375 |
| encode | 0.017521 | 0.023042 |
| command submission | 0.007188 | 0.011875 |
| completion wait | 1.175500 | 1.630958 |
| completion 후 전달/cache flush | 0.009667 | 0.022500 |
| GPU timestamp 실행 구간 | 0.626521 | 1.381042 |

GPU 구간은 command의 gpuStartTime/gpuEndTime이고 wait와 겹치므로 서로 더하지 않는다. submit 시간을 완료 latency로 쓰지 않았다. completed handler+semaphore로 command.status==completed/error==nil을 확인하며 timeout10s를 둔다. wrapper와 source/output 수명은 completion까지 유지한다. CPU QA의 shared NV12 lock/read는 timing 밖이며 결과 전달 경로에는 별도 readback copy가 없다.

최소 입력의 first-use(n1)는 CPU완료33.648041ms/CPU33.613ms, GPU완료3.955833ms/CPU3.097ms, GPU실행0.809875ms였다. 그러나 별도 **최초 GPU setup164.932667ms**(pipeline/cache164.148833, resource/LUT0.100167, PNGupload0.683667)가 필요했다. CPU constructor는0.298334ms였다. 최초 공통 LUT+기존PNG준비9.177167ms, 최소PNG생성/저장/decode16.480292ms, 최초 source decode95.316333ms도 별도다. 이 비용을 per-frame GPU값에서 숨기지 않는다.

두 번째 GPU instance setup은1.877667ms로 cache 영향이 있다. 이것을 독립 clean-cold 측정이라고 하지 않는다. fresh reader 시험도 OS 파일/cache를 비우지 않았고 static image/pipeline은 준비된 상태다. cold-start를 포함한 제품 startup 개선이나 cold 전체 latency 우위는 입증하지 않았다.

fresh-decode image-active의 decode+source validation wall 중앙값/최대는 CPU20.909521/31.828792ms, GPU19.688438/27.419959ms다. 순서 교대에도 decode 변동이 있으므로 transfer가 없는 커널 시간만의 배율로 제품 이득을 예측하지 않는다.

### 11. 메모리·GPU resource·예산

첫 실행 내부 RSS 최대601,866,240바이트, /usr/bin/time 최대604,979,200바이트였다. fresh-decode 내부 최대140,214,272, 외부 최대143,327,232바이트로 테스트 프로세스1GiB 미만이다. Release 빌드 명령은 compiler를 포함한 최대3,000,139,776/2,446,032,896바이트였으며 테스트-host RSS와 구분한다.

PNG nominal8,294,400/texture allocated8,486,912바이트, 두 LUT allocated65,536바이트다. NV12 active payload는 프레임당3,110,400바이트다. mappedTextureAllocatedBytes18,688,704는 plane/동일 bottom을 top slot에도 연결하는 alias를 합한 수치이므로 유일 물리 allocation으로 합산하지 않는다. device.currentAllocatedSize 관측 최대는 첫 실행205,340,672, decode 실행246,857,728바이트다. 품질용 CPU 배열도 RSS에 포함된다.

device allocation이 command 반복 중 증가했다. 이번 한정 실행에서 한도를 넘지 않았지만 장기 steady-state 재사용/해제·autorelease 수명을 입증하지 않았다. 다음 단계에서 다뤄야 할 위험이며 GPU 메모리와 unified-memory RSS를 단순 합산하지 않는다.

보고서 작성 직전 repository allocated6,950,735,872 + developer1,800,978,432 =8,751,714,304바이트로20GiB 미만이었다. 새 증거1,277,952바이트, developer 증가1,503,232바이트였다. 새 소스·보고서 여유를 포함한 보수적 증가2,912,256바이트로512MiB 미만이다. 대형 작업은 순차 실행했으며 cleanup하지 않았다.

### 12. 실행 명령·종료·SKIP

공통 명령:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/usr/bin/time -l swift test -v -c release \
 -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE \
 --package-path app/Engine --scratch-path "$BUILD_ROOT" \
 --filter MetalNV12ExperimentTests
```

| 로그 | 결과 |
|---|---|
| A/build-optout.log | 종료0, Release build, 1 SKIP/0fail |
| A/first-gpu-run.log | 종료0, testBoundedMetalNV12 실행PASS, 2.706초 |
| B/build-optout.log | 종료0, decode 계측 테스트 추가 Release build, 2 SKIP/0fail |
| B/first-decode-to-delivery.log | 종료0, testDecodeToDeliveryAfterCorrectness 실행PASS, 1.218초 |

GPU 실행은 같은 -c/Swift flags/scratch에 --skip-build를 사용했다. 첫 실행 환경은 `OTF_IMG_GPU01_RUN="$SELFTEST_ROOT/img-gpu01-20261029-01"`, `OTF_IMG_GPU01_FIXTURES="$SELFTEST_ROOT/img-b-poc1r-20261028-01/reader"`였다. 추가 계측은 RUN을 B로 바꾸고 `OTF_IMG_GPU01_CORRECTNESS="$SELFTEST_ROOT/img-gpu01-20261029-01/bounded/results.json"`를 요구했다. 해당 증거의 여섯 프레임 PASS와 모든 출력 hash를 선행 조건으로 사용했다. 최초 결과를 재실행·덮어쓰지 않았다.

직접 실행 PASS2개와 opt-out SKIP을 구분한다. 기존 미디어 suite 전체는 실행하지 않았다. 첫 GPU 정확도 성공 후 source decode 포함 경계를 추가 측정했으며 후보 kernel 변경·후보 재튜닝은 없었다. 최초 sandbox의 sysctl/pmset 읽기 제한은 별도 읽기 권한으로 해결했고 테스트 실패가 아니다.

### 13. Crash·timeout·실패

컴파일 실패, GPU 오류, correctness FAIL, timeout, crash, unsupported-interoperability, 테스트 자원 한도 초과는 관측하지 않았다. 커널이나 경로를 바꾸는 correctness 재시도는 없었다. 새 helper의 `MTLCompileOptions.fastMathEnabled`에는 macOS15 deprecation warning(mathMode 사용 권고)이 남는다. 실험 도중 math mode를 바꾸지 않았고 fastMath=false로 실행했다. 기존 AVPlayer status deprecation과 unused-value warning도 남는다. 새 테스트 통과가 기존 전체 회귀 해결을 뜻하지 않는다.

### 14. 한계·playback 위험

직접 버퍼·단일 장치·FHD SDR709·정수 geometry·작은 반복 수에 제한된다. arbitrary image/색공간/HDR·scale·rotation을 검증하지 않았다. 90-frame paced deadline, AVPlayer delivery, encoder, 실제 화면 presentation, subtitle/spectrum 혼합을 측정하지 않았다. GPU cancellation·stale command 거부·bounded request admission도 연결하지 않았다. source와 출력 수명은 단일 command completion까지 유지하지만 장기 pool/resource lifetime은 미검증이다.

static 준비와 최초 pipeline 비용은 크다. fresh source decode도 남는다. 한정 시험의28.627ms 최대값이나 높은 평균 이득을 안정30fps로 바꾸어 주장하지 않는다. 기존 PERF05 3/90 실패는 해결 판정으로 변경하지 않는다.

### 15. Candidate B 권고

Metal image-aware NV12 경로는 추가 조사의 가치가 있다. 직접합성의 정확도·완료 전달 비용에 한정해 **GPU FEASIBILITY DEMONSTRATED**로 판정한다. 기존 CPU baseline은 유지하며 제품 경로나 아키텍처로 채택하지 않는다. GPU kernel 속도만이 아니라 fresh-decode 전체 비용에서도 사전 의미 있는 개선 관문을 통과했다는 것이 이번 근거다.

### 16. 단 하나의 다음 작업

별도 승인 후 **동일 Metal 경로의 bounded resource-lifetime 90-frame gate**를 수행한다. command 반복에서 관측한 allocation 증가가 제한된 in-flight buffer/texture 수명으로 안정화되는지를 확인하는 한정 작업으로 두며, 이번에는 구현하지 않는다.

### 17. 최종 Git·보호 확인

HEAD/upstream/main과 모든 기존 refs가 동일하며 index는 비어 있다. 새 IMBGPU01 소스2개·이 보고서·A/B 증거만 추가했다. 기존 파일3,251개의 hash는 모두 유지되었다. A/preservation-check.json에 보존 결과와 예산을 기록했다.

production 소스·기존 Candidate B renderer·admission/scheduler·QA02 reference·과거 측정을 수정하지 않았다. 이미지 import·프로젝트 형식9·Stage3C-2·spectrum export·새 frame-rate 지원 변경은 없다. owner 미디어·프로젝트·출력을 수정하지 않았으며 staging·commit·push·merge·history 변경·artifact 삭제를 하지 않았다.
