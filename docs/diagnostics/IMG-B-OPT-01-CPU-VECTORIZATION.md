TASK ID: IMG-B-OPT-01
STATUS: CORRECT BUT NO MEANINGFUL IMPROVEMENT

> IMG-CP-02 게시 준비: `$REPO`는 저장소 루트, `$SELFTEST_ROOT`는 `$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 실험의 전용 내부 APFS SwiftPM scratch 디렉터리다. 아래 `$VAR`는 실제 실행 전에 해당 경로로 설정한다. 개인 절대경로만 비식별화했으며 원래 명령·실패 재현에서의 경로 역할과 하위 상대경로는 유지했다. 원본 로그는 변경하지 않았다.


2026-10-29, 로컬 Apple M4 Pro에서 수행한 제한된 Release 실험이다. 입력 행렬의 SIMD3 변환은 정확도를 유지했지만 전체 프레임 개선은 사전 기준에 못 미쳤다. 후보를 채택하지 않으며 여기서 실험을 종료한다.

### 1. 실제 저장소와 Git 상태

저장소 `$REPO`, 브랜치 `feature/subtitles`.
HEAD 및 origin/feature/subtitles는 `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main은 `44943eadabdf5a37d5242d614e7279813126dfde`이다. 시작부터 HANDOFF.md와 ROADMAP.md가 수정되어 있었고 기존 실험 소스·보고서 등이 untracked 상태였다. 해당 내용을 보존했다. 전체 시작 상태는 아래 증거 루트의 preflight.json에 기록했다.

### 2. 추가한 파일과 증거

새 소스는 다음 두 개뿐이다. 기존 파일 수정은 없다.

- `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/VectorInputConversion.swift`
- `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/VectorInputConversionTests.swift`

새 보고서는 이 파일 `docs/diagnostics/IMG-B-OPT-01-CPU-VECTORIZATION.md`이다.
증거 루트 A는 `app/selftest-work/img-b-opt01-20261029-01/`, B는 `app/selftest-work/img-b-opt01-20261029-02/`이다. A에는 preflight, 사전 계약, 격리 검증, 첫 실패 포함 실행 로그, 성능 요약, 빌드·보존 검증이 있고 B에는 세 테스트별 results.json이 있다. 모든 경로는 위 저장소 기준이다. 별도 라이브러리·프레임워크·Package.swift 변경은 없다.

### 3. 선택한 단일 연산

픽셀별 forward709 YUV→encoded RGB 입력 행렬만 Swift 표준 SIMD3<Float>로 묶었다. 세 독립 채널의 곱셈·덧셈이 작은 격리 단위이고 전체 렌더러나 LUT를 바꾸지 않고 비교할 수 있어 선택했다. 별도 후보 클래스의 픽셀 함수를 사용하며 baseline은 그대로 호출한다. one-suboperation-isolation.json은 대상 식을 되돌리면 나머지 픽셀 코드가 baseline과 일치함을 기록한다.

### 4. 산술 계약

baseline은 `R=y+1.5748*cr`, `G=y-0.187324*cb-0.468124*cr`, `B=y+1.8556*cb`이다. 후보는 계수 `(1.5748,-0.187324,1.8556)`와 입력 `(cr,cb,cb)`를 SIMD 곱하고 y를 더한 뒤 G에서 `0.468124*cr`을 순차 차감한다. FMA/addingProduct를 요청하지 않았다. 유한 UInt8 코드에서 기존 Float 정규화를 적용한 입력에 대해 중간 Float 비트 및 최종 active YUV의 완전 일치를 요구했다. 근사 오차 허용은 없다. LUT, clipping, alpha source-over, RGB→YUV, 반올림, Left chroma의 수직 평균과 geometry를 유지했다.

### 5. Raw 및 QA-02 정확도

물리적으로 materialize한 256개 Y chunk 각각에서 65,536개의 Cb/Cr 조합을 비교했다. 총 16,777,216 triples, 50,331,648 채널의 Float 비트 차이는 0이다. 총 402,653,184 출력 바이트를 제한된 chunk 버퍼로 비교·해시했고 256개 Y별 서로 다른 해시가 baseline/candidate 간 일치했다.

기존 POC1R reader의 bottom.mov/top.mov/middle.png를 사용했다. 결합 입력 digest는 `26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1`이다. FHD 30fps의 6개 phase를 기존 PTS 검사로 읽고 PERF02 Debug frozen raw 해시와도 비교했다. 프레임마다 active NV12 3,110,400바이트가 모두 일치했으며 Y/Cb/Cr 최대 차이는 각각 0이다. Canonical NV12→sRGB 결과도 RGB 최대 차이 0이다.

변경하지 않은 QA-02 sampled420 기준 PSNR은 phase 순서로 65.2634, 50.6360, 46.8838, 50.6346, 47.6731, 69.4458 dB, flat 최대 차이는 0,2,2,2,2,0이었다. 모두 기존 PSNR≥40/flat≤3를 통과했다. 자세한 raw 해시와 각 기준 비교는 B/testSixFrameRawAndQA02/results.json에 있다.

### 6. Edge·alpha·chroma·geometry

PNG alpha 128/255, 이미지 경계와 평탄부, Left chroma, top-video 경계 및 이동(+960,+540)을 같은 입력으로 확인했다. baseline/candidate 전체 raw 및 canonical 차이가 0이므로 이 영역에서도 후보가 도입한 차이는 없다. 기존 geometry 검사에서 phase 2/3의 top 영역 불일치도 0이었다. 원래의 색 기준 오차가 0이라는 뜻은 아니며 QA-02 수치는 위와 같다. 새로운 alpha 모델이나 chroma 정책을 도입하지 않았다.

### 7. 최적화 Release 구성

Apple M4 Pro / Mac16,8 / 논리 CPU 12 / RAM 24GiB, macOS 26.6.2 (25G83), Xcode 27.1 (27A9275), Swift 6.4, SDK 27.0, Swift language mode 5를 사용했다. verbose 컴파일 명령에서 -O, -whole-module-optimization, -enable-testing, OTF_PROTO_RELEASE를 확인했다. DEBUG 정의 없이 각 opt-in 테스트의 Release assert guard를 통과했다. 관련 명령은 A/build-verification.json에 보존했다. 최적화된 동일 바이너리와 동일 기기에서 순차 실행했으며 CPU 주파수 고정·장기 열 상태 보장은 없다.

### 8. Matched Release 시간

동일 source buffer·PNG·LUT로 6개 phase × 3회 paired 비교했고 AB/BA를 교대했다. 출력은 각각 동일 allocator의 새 버퍼이며 해시·QA는 시간 밖이다. 단위 ms, 중앙값 / 최대값이다.

| 범위 | n/구현 | baseline wall | candidate wall | baseline CPU | candidate CPU |
|---|---:|---:|---:|---:|---:|
| matrix+입력 load/출력 store | 3 | 0.137209 / 0.139208 | 0.150541 / 0.188041 | 0.134 / 0.137 | 0.150 / 0.175 |
| image-active 전체 frame | 12 | 28.843063 / 34.369208 | 28.706250 / 33.767166 | 28.693 / 34.079 | 28.612 / 33.401 |
| image-active pixel 함수 | 12 | 28.728709 / 34.220708 | 28.584313 / 33.690208 | 28.5795 / 33.931 | 28.491 / 33.324 |
| image, top 없음 전체 | 6 | 33.316938 / 34.369208 | 32.898646 / 33.767166 | 33.0155 / 34.079 | 32.6035 / 33.401 |
| image+top 전체 | 6 | 24.704354 / 26.182167 | 25.045438 / 26.049417 | 24.654 / 25.922 | 24.921 / 25.871 |
| image 없는 copy 전체 | 6 | 1.392479 / 1.599959 | 1.364000 / 1.751292 | 1.393 / 1.599 | 1.364 / 1.712 |

micro 입력은 262,144 triples이며 준비·할당·출력 해시는 시간 밖이다. 표본 수가 작으므로 P95는 제시하지 않았고 서로 다른 workload를 합쳐 percentile을 만들지 않았다.

### 9. 연산과 전체 프레임의 구분

matrix microbenchmark는 후보의 개선을 보이지 않았다. image-active paired 전체 wall 개선 중앙값은 0.529141%, CPU는 0.592084%였다. wall 개선 범위는 -5.41148%~+3.21218%, CPU는 -4.97464%~+3.01945%였다. 표의 집단별 중앙값 비율과 paired 개선 중앙값은 서로 다른 통계다. 사전 계약의 wall≥5% 및 CPU 개선 조건을 충족하지 못했다.

전체 frame 시간은 출력 버퍼 할당, 픽셀 렌더링, 태깅을 포함한다. instruction 준비·입력 decode·hash·reference·AVVideoCompositing callback·scheduler·terminal wrapper는 제외한다. micro 결과를 전체 렌더 또는 deadline 개선으로 바꾸어 주장하지 않는다. compiler의 기존 scalar 자동 벡터화 여부나 LUT의 비용 비율은 이번 실험에서 분리 입증하지 않았다.

### 10. CPU·메모리·예산

테스트 내부 관측 RSS 최대는 matrix 31,260,672, correctness 469,237,760, performance 100,745,216바이트였다. skip-build correctness 실행의 /usr/bin/time 최대 RSS는 485,867,520바이트로 1GiB 미만이다. Release build 명령의 최대 RSS 약 2.44GB는 compiler를 포함한 빌드 관측이며 테스트 프로세스 RSS와 구분한다.

최종 보고서 작성 직전 allocated bytes는 repository 6,948,610,048, 전용 developer root 1,799,475,200으로 합계 약 8.15GiB, 20GiB 미만이다. 두 새 증거 루트는 724,992바이트, developer 증가분은 667,648바이트였다. 새 소스·보고서 및 최종 JSON의 작은 증가를 포함해도 512MiB보다 충분히 작다. 대형 작업은 병렬 실행하지 않았고 cleanup은 하지 않았다. CPU 시간도 표에 따로 기록했으며 전력·열·GPU 성능은 측정하지 않았다.

### 11. Calibrated deadline

NOT RUN. 사전 전체 프레임 개선 gate가 실패하여 조건부 90-frame candidate check를 실행하지 않았다. 기존 calibrated driver, deadline 정의 및 threshold를 변경하지 않았다. 더 낮은 최대 frame 시간만으로 deadline PASS를 추론하지 않는다.

### 12. Pixel과 terminal attribution

이번 실험은 직접 픽셀 함수 비교이며 candidate의 paced pixel completion·post-hash·terminal 결과는 측정하지 않았다. 이전 PERF05의 A/B 각 3/90 deadline 실패, core 완료 지연 1개와 post-hash/wrapper 2개 기록은 그대로 남아 있다. 과거 Gate2 export QUALITY FAIL과 QA02 canonical PASS도 재분류하지 않았다.

### 13. 실제 명령과 종료 코드

공통 환경과 명령은 다음과 같다. RUN은 아래 실행별 루트를 의미한다. 로그는 A에 보존했다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
OTF_IMG_B_OPT01_RUN="$RUN" \
swift test -v -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE \
 --package-path app/Engine \
 --scratch-path $BUILD_ROOT \
 --filter VectorInputConversionTests/testAllInputCodeTriples
```

| 로그 | RUN | 종료 | 결과 |
|---|---|---:|---|
| matrix-correctness-first.log | A | 1 | test setup type-check compile failure |
| matrix-correctness-retry.log | A | 0 | 논리 비교 PASS, 물리 연산 증거에서 제외 |
| matrix-materialized-first.log | B | 0 | chunk materialization correctness PASS |
| six-frame-correctness-first.log | B | 0 | 6-frame raw/QA02 PASS |
| matched-performance-first.log | B | 0 | 18 pairs 및 micro, 성능 gate FAIL |
| opt-out.log | RUN 없음 | 0 | 3 SKIP, 0 failures |

마지막 세 실행은 같은 -c/Swift flags/scratch와 --skip-build를 사용했다. correctness와 performance filter는 각각 `VectorInputConversionTests/testSixFrameRawAndQA02`, `VectorInputConversionTests/testMatchedReleasePerformance`였다. 공통 추가 환경은 아래와 같았다.

```sh
OTF_IMG_B_OPT01_FIXTURES=$SELFTEST_ROOT/img-b-poc1r-20261028-01/reader
OTF_IMG_B_OPT01_BASELINE=$SELFTEST_ROOT/img-b-perf02-20261028-01/baseline-off/profile/raw-baseline.json
OTF_IMG_B_OPT01_CORRECTNESS=$SELFTEST_ROOT/img-b-opt01-20261029-02/testSixFrameRawAndQA02/results.json
```

CORRECTNESS 환경은 performance에만 사용했다. opt-out filter는 `VectorInputConversionTests`였다. 각 명령은 /usr/bin/time -l로 계측했다. 최종 `git diff --check`와 보호 해시 검증도 종료 0이다.

### 14. 실패·crash·timeout·SKIP

첫 컴파일은 micro 입력 배열의 복합 map 식 type checker 실패였다. 명시적 loop/지역 변수로 새 테스트 setup만 고쳤으며 산술 후보는 바꾸지 않았다. 첫 실패 로그를 보존했다. 다음 논리 256³ 검사가 약 86.8µs로 끝나 compiler folding을 배제할 수 없어 물리 materialization 검증으로 강화했다. 그 초기 실행은 성능이나 실제 전수 연산의 증거로 사용하지 않았다. 이후 correctness 실패·crash·timeout·자원 초과는 관측하지 않았다. opt-in 환경이 없으면 3개 모두 SKIP됨을 확인했다.

### 15. 남은 한계

단일 기기·작은 반복 수·기존 fixture 한 세트의 제한된 feasibility 실험이다. bit identity는 전수 UInt8 정규화 입력 및 실제 여섯 프레임에서 입증했으며 arbitrary Float, 다른 색공간/HDR·타 해상도·타 CPU까지 확장하지 않는다. AV callback, concurrent request, scheduler/cancellation 통합이나 sustained thermal behavior를 새로 검증하지 않았다. 기존 해당 코드를 보존한 것이 새로운 통합 PASS를 뜻하지 않는다.

### 16. Candidate B 권고

이 SIMD 후보는 채택하지 않는다. baseline을 유지하며 Candidate B의 제품 준비 완료나 deadline 회복을 선언하지 않는다. 정확도 유지와 측정 가능한 의미 있는 성능 개선은 별도 조건이다.

### 17. 단 하나의 다음 결정

이 forward709 SIMD3 최적화 경로를 종료한다. 다른 연산·라이브러리·렌더러 변경은 이번 결과에 이어 자동 실행하지 않는다.

### 18. 최종 Git 및 보존 확인

보호 대상 기존 소스·문서·실험 증거 988개의 SHA256가 모두 시작값과 일치했다. 모든 Git refs가 동일하고 staged diff는 비어 있다. 시작 때의 HANDOFF/ROADMAP 수정과 기존 untracked 자료를 유지했으며 새 파일은 2개 소스와 이 보고서 및 두 증거 루트뿐이다. A/preservation-check.json에 최종 상태를 기록했다.

production 코드, baseline renderer와 scheduler, QA02 reference, Gate1/Gate2, 품질 정책·threshold·schema를 수정하지 않았다. product image import, format 9, Stage 3C-2, spectrum export, 새 AVPlayer/MP4 export를 수행하지 않았다. owner media/project/output을 수정하지 않았다. staging·commit·push를 수행하지 않았으며 모든 과거 증거를 보존했다.
