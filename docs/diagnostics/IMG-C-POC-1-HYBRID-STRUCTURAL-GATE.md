# TASK ID: IMG-C-POC-1

**STATUS: INCONCLUSIVE** — Candidate C의 전체 구조 gate 통과도, 필요한 정보의 손실에 의한 전체 실패도 확정하지 않는다. BGRA 관찰 경계의 조건부 성공과 native 420v의 실제 RGB 복원 충돌을 분리한다. 전체 color/alpha/export/performance matrix는 시작하지 않는다. 제품 채택·이미지 import 완료가 아니다.

## 1. 저장소·범위

`feature/subtitles`, HEAD/로컬 upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main `44943eadabdf5a37d5242d614e7279813126dfde`. 기존 ROADMAP/HANDOFF 수정, IMG1A 소스·문서·실험 출력, recovery refs, `.claude/`·`.DS_Store`를 보존했다. 네트워크 Git 동기화나 브랜치 전환 없음. CLAUDE.md와 앞선 IMG-ARCH-01 검토의 기존 코드/진단 근거를 유지한다. 적용 AGENTS.md 없음.

추가 소스는 `app/Engine/Tests/OnTheFrameEngineTests/IMGCPOC1/HybridImageStructuralGateTests.swift` 하나다. 기존 생산 파일·기존 테스트·이전 IMG1A 보고서는 변경하지 않았다. 새 문서는 이 보고서 하나다. 실험 산출물은 Git 무시 대상 `app/selftest-work/img-c-poc1-20261028-01`…`-05`에 있다.

`-01/preflight.json`에 기존 tracked 파일과 이전 IMG1A 소스/문서/증거의 해시 569개 및 refs를 기록했다. 종료 `preservation-check.json`은 569개 일치, refs 일치다. 이 보존 수치는 모든 사용자 파일의 전수 검증을 뜻하지 않는다.

## 2. 정확한 구현과 경계

생산 planner를 고치지 않고 테스트 안에서 실제 두 영상 track을 가진 AVComposition/네이티브 AVVideoComposition을 구성했다. 상위 영상은 [1,5), 하위 영상은 [0,6), PNG 단계는 [2,5)다. 시간 단위는 30fps 정수 frame이다.

주 실험의 후보는 다음과 같다.

1. 두 영상을 native 합성한 단일 BGRA8 결과를 읽는다.
2. 별도의 uniform-white-over-black native probe에서 그 변형의 coverage를 관찰한다.
3. 상위 영상에 가려지지 않는 픽셀에만 PNG의 실제 premultiplied 성분으로 source-over한다.

이것은 **native probe로 보정한 mask를 사용하는 격리 원형**이다. 일반적인 mask 생성 알고리즘을 구현/검증한 것이 아니다. BGRA 배열은 테스트 관찰·독립 계산용이며, 생산 전체 BGRA 왕복 export를 도입하지 않았다. 실제 AVPlayer/PlayerNSView, spectrum, subtitle export, 저장/열기/relink를 연결하지 않았다.

Native 420v는 별도 두 boundary 관찰 및 하나의 사전 선언된 충돌 쌍으로만 확인했다. BGRA 결과를 구조 R의 420v 결과로 간주하지 않았다.

## 3. Fixture

모든 입력은 새 고유 실험 폴더의 생성 미디어다. 소유자 미디어/프로젝트 없음.

| 종류 | 저장 크기·형식 | 내용 |
|---|---|---|
| bottom/top | 960×540, 8-bit SDR H.264 MOV, 30fps, 6개 writer sample/0.2초 | frame별 서로 다른 명암, 좌상/우하 spatial marker |
| portrait top | 540×960, 같은 H.264 조건 | 세로 방향 marker |
| rotated top | 960×540, 같은 H.264 조건 | 실제 writer transform 90° metadata |
| coverage probe | 960×540 및 540×960, H.264 | opaque white/black |
| PNG controls | 1920×1080 RGBA8, sRGB PNG | alpha 0/128/255. 디코드 premultiplied gray 0/50/100, alpha 동일. PNG roundtrip byte 일치 |
| color witness | 960×540 H.264, 6 samples | frame별 blue 계열 하위/다른 red 계열 상위와 spatial marker |
| collision pair | 960×540 H.264, 6 samples | 420v writer Y=85 공통, A Cb/Cr=101/190, B=140/90 |

출력 composition canvas는 항상 1920×1080·30fps다. 최종 MP4 export는 0개다. Source writer/reader에는 709 primaries/transfer/matrix를 명시했으며 실제 420v attachment는 709/709/709, ChromaLocation=Left였다. 색 태그가 정답을 증명한다는 가정은 하지 않았다.

## 4. Reference와 수학

Reference는 합성 전 각 원본 video를 따로 BGRA8 decode한 값과 실제 PNG premultiplied byte를 유지해 계산한다. 픽셀 중심을 역변환하고 독립 bilinear/clamp로 source를 읽는다. 아래 영상 → PNG → 불투명 상위 영상 순이다. 후보의 native flattened RGB를 reference로 쓰지 않는다.

단, reference와 후보는 별도 native white/black probe에서 구한 coverage를 공유한다. 그러므로 source-over/source 값 비교는 독립이지만 **geometry oracle까지 독립인 검증은 아니다**. 기존 CG reference나 미승인 sampling 정책을 대체하지 않는다. 여기의 RGB 수식은 encoded code-domain 구조 검사이며 완전한 sRGB/709 색 검증이 아니다.

손계산 assertion: opaque `200 over 40 = 200`; alpha0.5 `200 over 40 = 120`; middle `100 over 40 = 70`; coverage0.25 top200 over middle70 =102.5. 모두 통과했다.

일반 부분 coverage의 수학은 `F=cT+(1-c)B`, 삽입 후 `G=cT+(1-c)(aI+(1-a)B)`다. c가 0/1이면 mask로 분기할 수 있지만, 0<c<1일 때 F만으로 T/B를 일반 복원할 수 없다. 이 수학적 예시는 실제 지원 조건의 부분 coverage 재현을 대신하지 않는다.

## 5. 여섯 변형의 BGRA 결과

각 변형은 frame0/1/2/4/5 × PNG alpha0/128/255, 15개 full-canvas 비교다. 총90개, 186,624,000 pixel 비교에서 RGB 오차3 초과 pixel은0, 최대 오차는1이다. 임의의 일반 변형 또는 전체 품질 PASS가 아니다.

| 사례 | transform | native covered pixels | ideal pixel-center coverage와 다른 pixels | 관찰 중간 명암 probe pixels | 비교 최대/오차3 초과 |
|---|---|---:|---:|---:|---:|
| A integer | scale1, tx240 ty180 | 518400 | 0 | 0 | 1 / 0 |
| B fractional | scale1, tx240.5 ty180.5 | 518400 | 0 | 0 | 1 / 0 |
| C aspect-fit 후 축소 | scale1.25, tx360 ty202.5 | 808800 | 1200 | 0 | 1 / 0 |
| D crop | scale2.5, tx−1200 ty−600 | 898051 | 1949 | 0 | 1 / 0 |
| E portrait fit | scale1.125, tx656.25 ty0 | 655560 | 1080 | 0 | 1 / 0 |
| F rot90 fit | a0,b1.125,c−1.125,d0,tx1263.75,ty0 | 655560 | 1080 | 0 | 1 / 0 |

中間明暗은 gray code 4…251 검사다. 이 검사는 sub-quantization coverage까지 없다는 증명이 아니다. Pixel threshold를 alpha coverage와 동일시하지 않는다. C/D/E/F의 ideal mask 차이를 생산 geometry 결함으로 분류하거나 소수 좌표를 임의 이진 근사해 동등 처리하지 않았다.

관찰한 모든 reader sample은 요청한 유리수 PTS와 일치했다. image 출현2, 직전1, 마지막4, 소멸5와 top 출현1/소멸5를 검사했다. 연속 실제 화면 표시·모든 decoded source frame·독립적으로 다른 종료시각·긴 clip duration을 검증한 것은 아니다.

별도 fractional color witness frame2 전체 화면도 최대1, 오차3 초과0이었다. 영상 경계 근처 최대1, 그 밖 최대1. 이 비교도 BGRA/native-calibrated mask/code-domain의 제한을 갖는다.

## 6. Native 420v 관찰

동일 color witness의 12점을 읽었다. tx240.5/ty180.5 사례의 관찰점 최대 차이는1이었다. 이어 tx241/ty181의 홀수 경계 12점을 읽었고 다음을 재현했다.

| xy | 상위 영상 coverage | native Y/Cb/Cr | nearest-2×2 진단 RGB 후보 | unflattened RGB reference | 최대 차이 |
|---|---|---|---|---|---:|
| 241,400 | 있음 | 85/128/115 | 57/87/80 | 192/54/24 | 135 |
| 242,400 | 있음 | 85/101/190 | 191/53/23 | 192/54/24 | 1 |
| 1201,400 | 없음 | 57/101/190 | PNG 후129/60/50 | PNG 후62/77/73 | 67 |

이는 native BGRA coverage가 hard해 보여도 420v의 공유 색차 표본이 같은 방식으로 레이어별 분리된다고 볼 수 없다는 실제 근거다. 하지만 nearest-2×2 복원과 full-resolution RGB reference의 차이는 승인된 같은 최종 sampling 계약에서의 비교가 아니다. 따라서135/67을 곧바로 PNG 구조 실패나 기존40dB/flat3 실패 수치로 올리지 않는다. 이 단계의 관찰점 수는12개씩이며 전체-frame mismatch count는 측정하지 않았다.

## 7. 실제 RGB 복원 충돌과 판정 한계

마지막 한 쌍만 실행했다. 상위 opaque video를 tx1919/ty0으로 옮겨 오른쪽1열만 canvas에 보이게 했다. Native white probe에서 (1919,400)=255로 실제 coverage를 확인했다. 하위 영상과 중간 alpha128 PNG는 같고, 상위 영상만 A/B다.

- PTS2/30, native 420v 활성 Y/CbCr 전체3,110,400 bytes: **다른 byte0, 최대 차이0**.
- 두 dump의 SHA256은 모두 `5a28e768b134ee9d3bbe0ab7f3a93428badb76e22eabe6d1ead61aca463461ac`.
- 해당 점의 native420은 A/B 모두 `[85,128,115]`.
- 독립 decoded 상위 원본 RGB는 A `[191,53,23]`, B `[12,98,105]`, 최대 차이179.
- A의 native BGRA 관찰도 `[191,53,23]`로 상위 색을 유지했다.

따라서 단일 flattened420+같은 mask만으로 원래 full-resolution RGB를 항상 복원할 수 없다는 **실제 충돌**은 확인했다. 다시 원본을 decode하거나 layer별 native 결과를 따로 유지하면 입력 경계를 바꾸는 것이다.

그러나 **중간 이미지 삽입 후 요구되는 최종420 결과가 서로 달라야 하는 실제 충돌은 아직 확인하지 않았다.** 검사점은 상위 opaque video가 PNG를 완전히 가리는 곳이다. 최종 subsampling 자체가 두 색을 구분하지 못할 가능성도 분리해야 한다. 따라서 이 결과만으로 Candidate C 전부가 요구 semantics를 잃는다고 결론 내리지 않는다.

최초 `-05/structural/results.json`과 `native420-collision.log`에는 자동 분류 `STRUCTURAL FAIL`이 있다. 그 분류는 **RGB 복원 불가의 좁은 사실을 전체 구조 실패로 과대 확장**하므로 최종 판정에 쓰지 않는다. 최초 파일/로그를 덮어쓰지 않았다. 최종 소스는 이 제한을 명시해 같은 witness를 INCONCLUSIVE로 분류하도록 수정했고 opt-out compile만 확인했다. Fixture/측정 재실행이나 parameter tuning은 하지 않았다.

## 8. 실제 실행·exit·종료

모든 실행은 기존 내부 APFS `IMG1A-build`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, `swift test --package-path app/Engine --scratch-path ... --filter HybridImageStructuralGateTests[/method]`로 했다. Run root opt-in은 `OTF_IMG_C_POC1_RUN`, 기존 생성 입력은 `OTF_IMG_C_POC1_PREVIOUS`/`OTF_IMG_C_POC1_COLOR`, 홀수420 관찰만 `OTF_IMG_C_POC1_ODD=1`이다. 새 root의 `structural`이 이미 있으면 거부한다.

| log (-01 아래) | 내용 | exit |
|---|---|---:|
| first-run.log | 새 테스트 async 호출을 XCTUnwrap autoclosure 안에 둔 컴파일 오류. 실행 전 실패 | 1 |
| retry-run.log | 여섯 변형90개 비교, XCTest1개/assertion 실패0, 약296.6초 test | 0 |
| color-witness.log | 새 color witness1개, assertion 실패0 | 0 |
| native420-witness.log | 기존 입력 재사용, 12점420 관찰1개 | 0 |
| native420-odd-witness.log | 같은 입력, 홀수 경계12점1개 | 0 |
| native420-collision.log | 사전 선언한 충돌쌍1개, assertion 실패0; 과도한 자동 분류는 위에서 제한 | 0 |
| final-opt-out.log | 최종 소스 compile, opt-in 없음:4개 모두SKIP/실패0 | 0 |

관찰된 예기치 않은 test-host/app crash, SIGABRT, 앱 종료, sandbox 실패, tool timeout 없음. 제품 앱/소유자 앱을 실행·종료하지 않았다. 첫 compiler 오류와 기존 실패 로그를 보존했다. 진단 JSON은 비유한 NSNumber를 문자열로 바꾸며, 고정 fixture 치수·pixel format을 검사한다. Exit0을 전체 구조/품질 PASS로 읽지 않는다.

## 9. 자원·미수행

주 실험의 관찰 RSS 최대141,770,752 bytes(약135.2MiB). Build+test invocation 최대 RSS 관찰452,526,080 bytes(약431.6MiB; compiler/child 범위 포함, 순수 renderer peak 아님). 새 run 출력 합계 약7.18MiB다. 저장소 전체와 전용 developer build root를 함께 잰 보수적 할당량은 약7.8GiB로20GiB 안이었다. 새 출력512MiB/RSS1GiB 초과 관찰 없음. 무거운 작업은 순차 실행했다.

최종 export0, subtitle/spectrum export0, 장시간 benchmark0, 실제 AVPlayer 관찰0, 4K/수시간 주장0. 전체 color/alpha 품질 matrix나 기존 전체 suite·Debug/Release 앱 빌드는 실행하지 않았다. 40dB/평탄부 최대3은 이후 품질 검증 기준으로 유지한다.

## 10. 결정과 다음 경계

**최종 INCONCLUSIVE.** BGRA8와 native-calibrated coverage에서 시험한 레인 순서는 일치했다. Native420에서 실제 원래 RGB 정보 손실도 확인했다. 하지만 동일한 최종420 sampling/색 계약 아래 **PNG 삽입으로 달라져야 할 결과의 분리 불가능성**까지 증명하지 않았고, 일반적인 coverage 생성도 검증하지 않았다.

Candidate C는 조건부 연구 후보로 남지만 현재 one-flattened420+binary-mask 구성을 채택하거나 전체 matrix로 확장하지 않는다. BGRA subset 결과를 반려된 전체 BGRA 생산 export의 재도입 근거로 쓰지 않는다.

다음 권고는 별도 승인된 **출력 계약/반례 설계 리뷰**다. 원본 RGB → 이미지 source-over → 동일420 sampling을 reference로 고정하고, 같은 flattened420에서 중간 이미지 삽입 후 필요한420 결과가 달라지는 쌍을 만들 수 있는지 범위를 먼저 정의한다. 재구성 가정과 native sampling 차이를 해결하지 않은 채 수치를 FAIL/PASS로 올리지 않는다. 필요한 layer 정보가 없다고 확정되면 영상 band를 따로 native 합성하는 revised hybrid와 image-aware Candidate B를 비교한다. 네이티브 합성기 중첩 호출이 자동 지원된다고 가정하지 않는다.

여기서 중단한다. 생산 코드·이미지 import·timeline 편집·형식9·Stage3C-2·spectrum export·owner media/project 변경 없음. staging/commit/push 및 reset/clean/fetch/pull/merge/rebase/브랜치 전환 없음. 최종 tracked 변경은 시작의 ROADMAP/HANDOFF뿐이며 새 untracked 소스/보고서만 추가했다.
