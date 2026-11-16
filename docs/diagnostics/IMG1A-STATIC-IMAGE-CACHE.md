# IMG-1A — 정지 이미지 영상 캐시 타당성 실험 (2026-10-27)

**판정: REVISE / 제품 채택 불가.** 제한된 실험 실행·측정은 끝났지만 품질·기하 관문은 통과하지 않았다. 이미지 가져오기 구현 완료나 최종 아키텍처 승인이 아니다. 원본 기준 `feature/subtitles` HEAD/upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main `44943eadabdf5a37d5242d614e7279813126dfde`. 소유자의 IMG-1A 지시로 격리 실험·생성 fixture·기록만 추가했다. 제품 코드·형식 8·PlayerNSView·ExportService·SubtitleExport는 그대로다.

## 계약·격리·환경

측정 전 [IMG1A-CONTRACT.md](IMG1A-CONTRACT.md)에 정확한 30fps PTS·개수·구간과 PSNR >=40dB, 평탄 영역 최대 RGB 차이 <=3의 실험 screening 기준을 적었다. 이 수치는 기존 자막 품질 계약을 완화하는 소유자 승인이 아니다. 기준 미달은 실패로 유지한다.

- macOS 26.6.2, Xcode 27.1 (27A9275), arm64 Debug XCTest. 한 Mac·각 시나리오 1회. 재실행은 oracle 수정·추가 색 공간 검사 때문이다.
- 소스: `app/Engine/Tests/OnTheFrameEngineTests/IMG1A/ImageCacheFeasibilityTests.swift`.
- 기존 회귀 본문 격리 사본: 같은 디렉터리 `IsolatedBaselineTests.swift`. 원본 `SubtitleExportTests.swift`의 SHA256을 주석에 기록했다. 클래스 이름·opt-in·출력 root·skip 때 nil-safe teardown만 조정했다. 테스트 본문은 같다. 원래 테스트와 기존 fixture를 변경하지 않기 위한 어댑터다.
- 새 산출물: `app/selftest-work/img1a-20261027-01`부터 `-06`, `img1a-20261027-baseline`. 첫 실패·JSON·영상·독립 reference PNG를 보존했다. Git 무시 대상이다.
- 빌드: 승인된 내부 APFS 전용 개발 디렉터리의 `IMG1A-build`. 기본 앱 DerivedData와 과거 증거를 정리하지 않았다. 새 의존성·도구 설치·미디어 업로드 없음.
- 일반 실행에서는 opt-in 환경 변수가 없으면 12개 실험/어댑터 테스트 모두 SKIP, 실패 0. 제품 앱을 실행하거나 소유자 앱을 종료하지 않았다.

## 후보 구조와 fixture

ImageIO로 파일 종류·단일 이미지·완전 디코드 상태를 검사하고 orientation 적용 thumbnail을 만든 뒤 sRGB 8비트 premultiplied RGBA로 정규화한다. 이를 BGRA pixel buffer 한 개에 그려 AVAssetWriter에 30개의 서로 다른 PTS로 넣는다. 단일 샘플을 늘리지 않는다. 캐시는 1초 MOV이며 같은 파일의 구간을 composition track에 반복 삽입한다.

실험 composition은 기본 AVFoundation 합성기와 실제 video track을 사용한다. 시각 레이어는 위쪽 우선, 아래에는 반복 H.264 검정 carrier가 있어 빈 구간과 끝까지 영상 시계를 유지한다. 투명 이미지는 아래 레인을 보존하는 **실험 전용 스택**으로 넣었다. 이는 생산 planner가 이미 alpha를 지원한다는 뜻이 아니다. 같은 `PlannedComposition`을 기존 `ExportService`에 전달해 자막 없음은 session, 자막 있음은 기존 구조 R을 호출했다. 모델·직렬화 우회는 테스트 내부에서만 하며 제품 image media type은 없다.

| 입력 | 실제 형식·저장 크기 | 방향·프로파일·alpha |
|---|---|---|
| jpeg.jpg | JPEG, 960×540, 품질 설정 0.95 | EXIF 1, sRGB, 불투명 |
| png.png | PNG, 960×540, 8비트 RGBA | EXIF 1, sRGB, 모든 alpha 255 |
| alpha.png | PNG, 960×540, 8비트 RGBA | sRGB, alpha 0/부분/255, 반투명 판·가는 선·불투명 marker/gradient |
| orientation.jpg | JPEG 저장 960×540 → 정규화 540×960 | 실제 EXIF 6, sRGB |
| p3.png | PNG, 960×540, 8비트 RGBA | 실제 Display P3 프로파일, 불투명 |

공통 패턴은 비대칭 모서리 표식, 색 판 네 개, 회색 gradient와 1픽셀 가는 선이다. 입력을 다른 포맷으로 대신하지 않았다. 일반 영상 대조군은 생성한 H.264 파란 판, 오디오는 48kHz 모노 16비트 PCM 440Hz WAV다. 외부·개인 미디어 없음.

## 코덱·alpha·orientation

- 후보 ProRes 4444 MOV, 입력 BGRA, 출력 primaries/transfer/matrix 709 선언. JPEG/PNG/P3/portrait 캐시 생성에 성공했다. **태그가 있다는 것과 올바른 색 변환은 구분한다.**
- ProRes alpha 캐시의 실제 BGRA 디코드: alpha 최소 0·최대 255, 부분 alpha 134,400픽셀, 독립 원본 대비 최대 alpha 차이 **0**.
- H.264 alpha 음성 대조군: 실제 디코드 alpha 전부 255, 최대 차이 255. 아래 영상과 합성한 결과 PSNR 약 8.04dB. alpha가 필요할 때 사용할 수 없다.
- EXIF 6: raw JPEG를 독립 CoreGraphics clockwise 변환한 결과와 정규화 결과 최대 byte 차이 **0**. 캐시의 portrait 크기도 540×960이다.
- 실제 생산 `CompositionPlanner.layerStack`에 전체 화면 alpha 상단과 영상 하단을 넣으면 **2개 중 1개만 유지**, 하단 제거. 캐시를 생산 경로에 그대로 등록하는 안은 실패한다. 생산 코드는 고치지 않았다.

## 시간·반복·오디오·자막

30fps 반열린 구간을 정수로 정의하고 각 최종 출력의 모든 decoded sample PTS를 독립 `n/30`과 비교했다. 짧은 120프레임 출력, 90프레임 대조군, 180프레임 오디오 출력, 5,400프레임 출력 모두 개수·PTS·정확한 track duration 검사가 통과했다. 시작 0, 이미지 시작 15, 끝 직전 104, 이미지 다음 105, 전체 끝 119, 캐시의 실제 반복 경계 44/45/46·74/75/76을 검사했다. 검정 빈 구간과 이미지/일반 영상의 순차·상하 레인 사례도 실행했다.

- 짧은 표준 구간: 이미지 [15,105), 전체 [0,120). 검정 carrier가 이미지 앞뒤를 채운다.
- 이미지 [0,90), 오디오 [0,180), 전체 180: 영상 180프레임/6초, 오디오 track 6초. 이미지 끝 뒤 검정이며 오디오가 이어진다.
- 이미지 [0,180), 오디오 [0,90), 전체 180, 자막 포함: 영상 180프레임/6초, 오디오 track 3초. 짧은 오디오가 영상 끝을 자르지 않는다.
- 자막 구간 [30,60): subtitle ROI의 큰 차이 픽셀은 frame29=0, 30=5904, 59=5698, 60=0. 자막이 그 위에 나타나고 구간 밖 사라진다. 자막 밖 경로 간 최대 RGB 차이는 0/13/14/15로, 전체 품질 동등 판정은 아니다.
- 자막 구간 안의 초기 전체-frame reference는 자막을 포함하지 않으므로 그 PSNR은 **이미지 품질 판정에서 제외**한다. 표시 구간은 위 별도 ROI로 판단했다.

정지 이미지의 내용은 반복 프레임마다 같으므로 PTS/개수 검사는 디코드 영상의 모든 원본 프레임 ID를 검증한 것과 같지 않다. 실제 동영상 프레임 ID·첫 재생·디스플레이 타이밍 회귀는 별도 관문이다.

## 색·독립 reference·국소 오차 — 실패

독립 CoreGraphics source-over/수학적 위치 reference와 비교했다. 초기 reader BGRA 숫자와 CGImageGenerator 색 관리 결과를 직접 같은 색 공간인 것처럼 비교하면 혼동할 수 있어 두 단계 결과를 보존했다. **최종 품질 판단은 preview composition과 exported file을 각각 AVAssetImageGenerator로 읽고 동일 sRGB bitmap으로 변환한 비교를 우선한다.** 이는 실제 화면 AVPlayer 검증은 아니다.

| frame30, 공통 sRGB | preview → 독립 reference PSNR | export → 독립 reference PSNR | preview/export 서로 PSNR | 평탄부 최대 차이 (preview/export) |
|---|---:|---:|---:|---:|
| JPEG | 27.07 | 27.65 | 41.24 | 11 / 10 |
| 불투명 PNG | 26.98 | 27.10 | 41.77 | 11 / 10 |
| P3 PNG | 26.99 | 27.67 | 41.13 | 11 / 10 |
| 투명 PNG/영상 | 29.50 | 29.87 | 41.34 | 12 / 11 |

서로 비슷하게 나온다는 것만으로 독립 reference와의 품질 통과를 선언하지 않는다. 공통 sRGB 공간에서도 PSNR·평탄부 기준 미달이다. RGB 입력→writer→709 태그·색 변환 중 어느 지점이 원인인지는 확정하지 않았다. 기존 제품의 601/709 알려진 문제를 이 실험에서 수정하거나 해결됐다고 하지 않는다.

P3 디코드 검증은 별도다. 처음 nominal drawing color를 PNG 저장 성분으로 잘못 가정해 4개 패치가 50/65/26/19 차이로 실패했다(`-03/first-run.log`). fixture 생성 시 CGColor가 해당 프로파일로 변환되므로 nominal 값과 실제 저장 성분이 달랐다. **실제 파일의 P3 성분을 읽어** 독립 P3→XYZ D65→sRGB 행렬 reference와 비교한 재검사(`-04`)는 네 패치 모두 차이 0. 가정 수정 근거와 저장 성분을 JSON에 남겼으며 허용치는 바꾸지 않았다. 행렬 참고: [W3C CSS Color 4 sample conversion code](https://www.w3.org/TR/css-color-4/#color-conversion-code). 이는 wide-gamut 출력이나 HDR 지원 검증이 아니다.

JPEG 입력 손실도 캐시와 분리해 생성 전 독립 패턴과 비교했다: PSNR 37.93dB, 최대 139, p99 16, 평탄부 최대 1. 최종 캐시 품질 문제와 JPEG 자체 손실을 합쳐 설명하지 않는다.

투명 PNG 출력 frame30의 **공통 sRGB** 국소 측정(`-06`; 좌상단 원점 ROI는 JSON 참조):

| 영역 | 최대 RGB 차이 | p99 | RMSE |
|---|---:|---:|---:|
| 완전 투명 부분 아래 배경 | 11 | 11 | 7.19 |
| 반투명 판 내부 | 11 | 11 | 10.68 |
| alpha 경계 | 29 | 29 | 12.74 |
| gradient | 13 | 12 | 8.72 |
| 가는 선 | 16 | 16 | 9.01 |

초기 `localMax`는 단순 넓은 mask이므로 정확한 특징별 ROI와 혼동하지 않는다. 위가 후속 명시적 ROI 결과다. premultiplication의 alpha 채널 자체는 보존됐지만 최종 RGB 합성 품질은 실패다.

기하: portrait fit 중앙행 점유 구간 독립 기대 656…1263, 관측 656…1262. **오른쪽 1픽셀 assertion 실패**를 `-06`에 보존했다. 기존 기본 합성기 경계 규칙/threshold oracle와의 추가 대조가 필요하며 통과 처리하지 않는다. crop은 (-240,-135,2400,1350)으로 출력 밖을 자르는 90프레임 사례를 실행·측정했지만 전체 기하 동등이 증명됐다고 하지 않는다.

## 자원·반복 확장

| 캐시 1초/30샘플 | 파일 bytes | 생성 초 |
|---|---:|---:|
| JPEG → ProRes 4444 | 4,661,615 | 0.219 |
| PNG → ProRes 4444 | 3,339,703 | 0.071 |
| alpha PNG → ProRes 4444 | 4,263,227 | 0.073 |
| P3 → ProRes 4444 | 3,353,623 | 0.072 |
| portrait → ProRes 4444 | 6,431,879 | 0.080 |

입력 정규화 시간 2.36–4.02ms(한 번씩, warm/cold 보장 없음). 3분 출력은 같은 PNG 캐시를 재사용했고 이미지+black carrier **360 insertions / instruction 1**, 5,400프레임/180초 정확, export 약 **22.926초**, 결과 **18,299,309 bytes**. 긴 출력 전체는 시간 검증이며 모든 프레임의 full-frame 픽셀 품질을 계산하지 않았다.

30분은 **composition만 구성**: 3,600 insertions / instruction 1, 약 0.023초. export·재생하지 않았다. segment 수는 시간에 비례하므로 수시간 확장·탐색·준비 비용이 안전하다는 증거는 아니다. 캐시 길이를 늘리면 segment 수와 파일 크기 사이의 교환이 생긴다.

메모리 구분: 첫 본 실행 RSS 표본 최대 212.39MiB, 마지막 205.47MiB. 전체 단계의 기록 지점 RSS 최대 약 301.98MiB. 이는 참 peak가 아니다. `/usr/bin/time -l`의 첫 build+test invocation 최대 RSS 730,660,864 bytes(약 696.81MiB), peak footprint 494,208,464 bytes로 build/child 범위를 포함하며 순수 이미지 캐시 메모리가 아니다. 다른 앱·OS의 메모리를 측정한 값도 아니다. 최종 관리 산출물 할당량은 약 7.68GiB로 20GiB 안이며 실험 새 출력은 512MiB 이내다. 무거운 export는 병렬로 돌리지 않았다. 4K·수시간 성능 주장은 없다.

## 실패·취소·회귀와 한계

- 캐시 생성 frame3에서 제어 취소: partial 파일 제거 확인. 새 이름으로 캐시 재생성 성공.
- malformed PNG·없는 원본 거부. TIFF는 TIFF로 생성한 뒤 지원 외 종류로 거부했다. 지원 외 ICC·읽기 권한 거부·HDR·대형 이미지의 실제 처리·animated PNG는 이번 실행에서 검증하지 않았다.
- 128바이트로 잘린 캐시·없는 캐시 재사용은 AVFoundation 오류로 거부. 프로세스 강제 종료를 실제 재현한 것은 아니다.
- 두 후보 export 경로의 취소(시작 전 Task 취소)와 failAfterFraction 실패: 목적 파일 없음. 기존 sentinel 출력은 미확인 덮어쓰기를 거부하고 byte 보존.
- 기존 자막 export 회귀 본문 3개: `testColorMatchesSessionPath`, `testMixedFpsGapsAndEndThroughR`, `testLifecycleCancelFailureAndDestinationProtection` **3/3 PASS**. 이 검사는 기존 동영상·색/자막 두 경로·중간 취소/실패·임시 정리·목적 보호의 제한된 회귀이며 전체 앱 suite가 아니다.
- 본 실험 첫 실행과 supplement의 XCTest assertion은 각각 0실패. `screenPass=false` 품질 결과가 있으므로 이 exit 0을 후보 품질 PASS로 읽지 않는다.
- `-02/first-run.log`는 보충 소스의 주석 때문에 선언이 빠진 **컴파일 오류**. 수정 뒤 `retry-run.log` 실행. 최초 로그 유지. `-03`은 P3 oracle assertion 4개 실패, 수정 후 `-04`의 관련 assertion 통과. `-06`은 기하 assertion 1개 실패 유지. 타임아웃·앱 crash와 구분한다.
- 실제 앱 실행·예기치 않은 앱 종료·crash는 관찰하지 않았다. 보조 `ps` 조회는 sandbox에서 거부됐고 `/usr/bin/time`과 자체 RSS 표본으로 대체했다. 해당 거부는 테스트 assertion이나 앱 crash가 아니다.
- security-scoped bookmark의 실제 sandbox 수명, 살아 있는 AVPlayer/PlayerNSView의 재생·pause·seek·최초 프레임은 **미검증**. offline generator의 actualTime 검사는 통과했지만 실제 화면과 같다는 증거는 아니다.
- 이미지 원본은 생성 fixture만 사용했다. 앱에서 원본 이미지가 등록되지 않으므로 이미지 원본까지 포함한 생산 ExportService 보호 목록 통합은 아직 없다. 기존 보호 코드 자체는 변경하지 않았다.
- spectrum export 거부 코드는 변경하지 않았다. spectrum export·3C-2·스타일 UI·형식 9·제품 import를 켜지 않았다.

## 재현과 다음 경계 (제안)

`app/Engine`에서 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`와 내부 APFS `--scratch-path`를 지정한다. 각 RUN은 존재하는 결과가 없는 새 `app/selftest-work` 하위 절대 경로여야 한다. `swift test --filter ImageCacheFeasibilityTests/testBoundedExperiment`에 `OTF_IMG1A_RUN`을 전달해 먼저 생성한다. 후속 `testSupplement`, `testGeometryAndColor`, `testColorManagedComparison`, `testLocalizedErrors`는 `OTF_IMG1A_SOURCE`에 첫 RUN을 주고 각각 `OTF_IMG1A_SUPPLEMENT`, `OTF_IMG1A_GEOMETRY`, `OTF_IMG1A_MANAGED`, `OTF_IMG1A_LOCAL`에 서로 다른 새 RUN을 준다. baseline adapter는 `OTF_IMG1A_BASELINE`으로 새 root를 전달하고 위 세 메서드만 filter한다. 모든 필터와 실제 실행 명령은 각 run log 및 세션 명령 기록에 대응한다. 기본 opt-out 검사는 환경 변수 없이 두 클래스만 filter한다.

**권고는 REVISE**다. 짧은 실제 video cache로 시간축·반복·alpha 전달은 가능하다는 근거가 생겼지만, 생산 적용에는 (1) RGB/709 색 처리 원인 분리와 독립 기준 재검사, (2) portrait 경계의 native baseline 대조, (3) alpha-aware visibility 계획, (4) 실제 AVPlayer 검증이 먼저 필요하다. 현재 후보를 IMG-1 제품 렌더링 방식으로 채택하지 않는다. 후속 승인이 있다면 IMG-1A의 이 네 관문에 한정한 추가 실험을 먼저 하고, 그 뒤에 이미지 모델/probe/format 호환성의 IMG-1 경계를 결정한다. 형식 9·초기 길이 등 IMG-0의 소유자 결정은 여전히 미승인이다.
