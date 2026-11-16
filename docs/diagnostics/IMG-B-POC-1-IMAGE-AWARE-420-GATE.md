# TASK ID: IMG-B-POC-1

**STATUS: BLOCKED** — Gate1의 reader가 두 요청 slot이 점유된 동안 추가 custom-compositor 요청을 보냈고, 원형이 이를 명시적 resource-budget 오류로 종료했다. Output sample 비교 전에 멈췄다. 구조/품질 PASS 또는 FAIL을 측정한 결과가 아니며 Candidate B 전체를 기각하지 않는다. Gate2·AVPlayer·export는 실행하지 않았다. 제한 확대·요청 누락·재시도·광범위 matrix 없음.

> IMG-CP-02 게시 준비: `$REPO`는 저장소 루트, `$SELFTEST_ROOT`는 `$REPO/app/selftest-work`, `$BUILD_ROOT`는 기존 실험의 전용 내부 APFS SwiftPM scratch 디렉터리다. 아래 `$VAR`는 실제 실행 전에 해당 경로로 설정한다. 개인 절대경로만 비식별화했으며 원래 명령·실패 재현에서의 경로 역할과 하위 상대경로는 유지했다. 원본 로그는 변경하지 않았다.


## 1. 저장소와 보호

저장소 `$REPO`, branch `feature/subtitles`, HEAD/로컬 upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main `44943eadabdf5a37d5242d614e7279813126dfde`. 기대 상태와 일치했다. 기존 ROADMAP/HANDOFF 변경, untracked IMG1A/IMGCPOC1 소스·문서, `.claude/`·`.DS_Store`·recovery refs를 유지했다. Applicable AGENTS.md 없음. 기존 CLAUDE.md/IMG 아키텍처·품질 검토의 보호 범위를 유지했다.

Swift Package의 testTarget이 하위 Swift 파일을 포함하므로 Package.swift 변경은 필요 없었다. 기존 테스트/실험/생산 파일을 수정하지 않았다.

## 2. 새 파일

실험 소스는 모두 `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/` 아래다.

- `ImageAware420Compositor.swift`: pixel/color 계약, immutable PNG, transfer LUT, frame instructions, bounded AVVideoCompositing 구현.
- `ImageAwareReference.swift`: 별도 원본 decoder/CG reference, reference420, fixture writer, 안전한 진단·통계.
- `ImageAware420GateTests.swift`: opt-in, Gate1, Gate2 및 immutable 입력/source digest 조건.

새 진단 문서는 이 파일 하나다. 이전 보고서를 갱신하지 않았다. 새 로그/fixture/manifest는 `app/selftest-work/img-b-poc1-20261028-01/`에만 썼다.

## 3. 원형 설계

두 real video track을 각각 유지한 test-only AVComposition과 frame별 AVVideoCompositionInstruction을 만든다. 필요한 source track ID로 원본 CVPixelBuffer를 마지막 합성 직전까지 별도로 받는다. PNG는 영상 cache가 아니라 한 번 decode한 immutable premultiplied RGBA8 배열이다.

출력은 FHD420v render-context pixel buffer다. 전체 후보 BGRA 중간 영상을 만들지 않는다. 정수 경계의 opaque 상위 영상은 자기 Y/CbCr 기여를 직접 복사한다. PNG가 없는 하위 영상도 그대로 복사한다. PNG 혼합은 2×2 tile의 float 색 계산 후 출력 평면에 직접 쓴다. PNG/reference 저장용 RGBA 배열과 후보 영상 중간 배열은 구분한다. Reference는 진단용 full-canvas RGBA를 사용하지만 생산 route에 들어가지 않는다.

직렬 작업 queue와 cancellation generation을 사용한다. Queue에 들어가 대기하는 요청도 포함해 admitted in-flight 최대2개다. 초과 요청은 오류로 명시 종료하며 누락하거나 검정 frame으로 대신하지 않는다. 각 분기는 success/error/cancel 중 한 번만 완료하도록 작성했다. 이 admission 정책과 실제 reader의 요청 패턴 사이에서 이번 blocker가 발생했다.

## 4. 측정 전 고정한 계약

`reader/results.json` 첫 record에 다음을 적었다. 이 계약은 제품 sampling 정책 승인이 아니다.

| 항목 | 실험 정의 |
|---|---|
| 입출력 | `420v`, 8-bit video range, 1920×1080·30fps |
| Primaries/transfer/matrix | 709/709/709, source metadata 검사, output attachment 명시 설정 |
| Transfer 계산 | 선언된709 attachment로 합성한 ICC ↔ sRGB의 ColorSync4097-point float LUT. 동일 primaries 가정 |
| Source chroma | Left, 후보는 source chroma block nearest 관찰값 사용 |
| Output chroma | Left: 각2×2 첫 열의 두 세로 float sample 평균 |
| PNG alpha | premultiplied RGBA8, alpha128/255 |
| Source-over | encoded-sRGB 값에서 Porter-Duff source-over |
| Geometry | top-left 정수 좌표, 영상1:1, top(+960,+540), canvas clip |
| 품질 기준 | global PSNR≥40dB, flat RGB maximum≤3. 기존 CG와 reference420 별도 비교 |

Source attachment를 output에 무조건 복사하지 않는다. 형식/크기/색 속성이 선언과 다르면 실패한다. Input/output chroma 처리와 ICC LUT가 실제 미디어 품질 기준을 만족하는지는 **측정 전 중단되어 미검증**이다.

## 5. 생성 fixture와 시각

- `reader/bottom.mov`: FHD H.264 MOV, 30fps, writer6 samples/6÷30초. 매 frame 다른 Y/Cb/Cr 색. 별도 명암3-bit frame ID marker.
- `reader/top.mov`: 같은 규격, 서로 다른 frame별 색과 ID marker.
- `reader/middle.png`: FHD sRGB PNG, x0…639 red alpha128, x640…1279 green alpha255, 나머지 blue alpha128. 색/alpha는 실제 premultiplied byte로 정의했다.

영상 writer는6개의 서로 다른 정수 PTS를 공급하고6/30에서 끝냈다. 최종 output의6 decoded frames/정확한 duration을 검증했다는 뜻은 아니다.

Visual interval은 bottom[0,6), PNG[1,5), top[2,4)다. 두 source track은 timeline0부터 sourceIn0으로 삽입하고 top의 표시만2/3에 켜므로 visible top sourceID는2/3이다. Top은(+960,+540)의1:1 정수 이동으로 하위 영상 일부를 드러낸다. 겹침 순서는 top > PNG > bottom이다.

PNG load의 alpha128/255 검사와 fixture 생성은 끝났다. 실제 원본 source frame별 decode/timestamp 대조는 이번 gate 결과로 완료 처리하지 않는다.

## 6. 독립 reference

별도 AVAssetReaderTrackOutput의 원본 BGRA를 실제 attachment의 ICC로 해석하고 sRGB로 정규화한다. CG로 bottom → PNG → top을 합성한다. Top-left 이동은 독립 Quartz rectangle `y=1080−540−1080`으로 바꾼다. 후보의 blend 함수·후보 output을 reference로 쓰지 않는다.

CG reference 자체와, CG 결과를709 RGBA로 바꾼 뒤 별도의 scalar conversion으로 선언한420 sampling을 적용한 reference를 구분하도록 구현했다. Source codec 손실은 실제 decoded 원본을 기준으로 분리하고, output420 변환과 최종H.264 손실도 별도로 측정하도록 구현했다. 그러나 **media reference 생성/비교는 실행 지점에 도달하지 못했다**.

실제로 수행된 독립 손계산/CG control은 통과했다. Premultiplied foreground[100,25,13,128] over background[40,80,120,255]의 CG 결과는[120,65,73,255]로 독립 rounded 기대값과 RGB 차이0이었다. Opaque200 over40=200, alpha0.5의200 over40=120도 확인했다. 이 제어군 통과는6-frame 품질 PASS가 아니다.

## 7. Gate1의 실제 결과

`testInterleavedReaderGate`를 **한 번** 실행했다. 결과는 exit1, BLOCKED다.

```
Error Domain=IMG-B-POC-1 Code=300
inflight budget exceeded; request explicitly failed
```

남은 request event는 다음 세 개다.

1. `rejected`, reason=`two-request budget`
2. `cancelled-after`, frame0
3. `cancelled-before`, frame1

두 slot이 점유된 동안 추가 admission이 거부됐다는 것은 확인된다. 거부된 요청의 frame 번호는 현재 log에 없으므로 특정하지 않는다. `cancelled-after`는 render 후 publish 전 generation 검사에서 취소한 분기이며 성공 output이 아니다.

첫 output sample을 검사하기 전에 reader가 오류로 끝났다. `frame*-PTS`, geometry, media quality, native-component 비교 record는0개다. `gate1-pass.json`도 없다. Gate1은 통과하지 않았다.

## 8. Gate2

실제 Gate2 실행0, AVPlayer 관찰0, playback 관찰0, 최종 MP4 export0이다. Gate1 실패 뒤 Gate2를 실행하지 않았다.

Gate2 코드는 Gate1 marker 및 소스/fixture digest 일치를 요구하도록 구현했다. 같은 논리 frame plan으로 stale timestamp 거부,6시각 player 관찰,0.2초 export 최대1개, decoded6frame/PTS/duration/품질을 검사하도록 작성했지만 실행하지 않았다. 구현 존재를 동작 검증으로 보고하지 않는다. Product ExportService를 변경하지 않았다.

## 9. Source frame·PTS·geometry·alpha 품질

완료되지 않은 항목은 명확히 구분한다.

| 항목 | 이번 결과 |
|---|---|
| Source frame ID와 movie timestamp | 검사 코드 있음, gate 전체의 보존된 성공 record 없음 |
| Output6개와 n/30 PTS | 미검증 |
| Native 영상 geometry/정수 경계 | 미검증 |
| Visual lane 순서 | 미검증 |
| PNG128/255 decode | 준비 단계 확인 |
| CG 손계산 source-over | 위1pixel control 통과 |
| 미디어 alpha/PSNR/flat/edge/p99/worst | 측정 없음;0오차나 PASS로 기록하지 않음 |
| Native video-only component 비교 | 코드 있음, 실행 안 됨 |
| Black/empty | 전체 구간을 bottom이 덮으므로 fixture에 empty interval 없음 |

기존40dB/flat≤3 기준과 native/CG 계약을 낮추지 않았다. JPEG·임의 scaling·fractional transform·다중 PNG·다른 color metadata·image-only 시계·자막/스펙트럼은 검증 범위 밖이다.

## 10. 실제 명령·실패·SKIP

모두 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, 기존 내부 APFS scratch `$BUILD_ROOT`를 사용했다.

1. `swift test --package-path app/Engine --scratch-path <scratch> --filter ImageAware420GateTests` — opt-in 없음. **exit0**, compile성공,2tests 모두SKIP/실패0. Log=`build-opt-out-first.log`. Build표시2.76초, invocation5.88초. 컴파일 오류 없음.
2. `OTF_IMG_B_POC1_RUN=<새run> swift test --skip-build --package-path app/Engine --scratch-path <scratch> --filter ImageAware420GateTests/testInterleavedReaderGate` — **exit1**,1test 오류1. Log=`gate1-first.log`. XCTest0.811초, bounded wrapper 약3.836초. Python wrapper의120초 timeout은 발생하지 않았다.

`XCTest: 1 failure (1 unexpected)`는 위 NSError가 테스트 밖으로 throw된 **테스트 오류** 표기다. Test-host crash나 app crash가 아니다. Assertion control 실패, compiler error, sandbox 실패, tool timeout은 없었다. 예기치 않은 host/app 종료도 관찰하지 않았다. 제품 앱/소유자 앱을 실행·종료하지 않았다.

Ordinary opt-out SKIP2개는 격리 확인일 뿐 실험 품질 통과가 아니다. Gate1 재시도·fixture 재생성·추가 matrix는 하지 않았다. 첫 오류와 cancellation event를 보존했다. JSON 비유한값은 문자열로 변환하며 고정 치수/pixel format을 검사한다.

## 11. 취소와 자원

Reader 오류 뒤 generation cancellation 경로에서 frame0의 render-after 취소와 frame1의 render-before 취소를 관찰했다. 별도 cancellation race fixture나 요청 ID별 전체 exactly-once audit는 실행하지 않았다. Output promotion이나 생산 export 취소를 검증했다고 하지 않는다.

관찰 test-process RSS 최대90,308,608 bytes(약86.13MiB). Gate1 wrapper invocation maximum RSS169,345,024 bytes(약161.5MiB), build/opt-out invocation457,637,888 bytes(약436.4MiB)다. Invocation 측정은 runner/child 범위이며 test 자체의 sampled RSS와 구분한다.

보고서 작성 전 새 run 할당량160KiB(약0.16MiB). 저장소 전체6,703,360KiB와 전용 developer root1,472,928KiB를 합친 보수적 할당량은약7.80GiB다.512MiB/1GiB/20GiB 및 시간 한도를 넘긴 관찰은 없다. **Blocked 원인은 process 메모리 초과가 아니라 고정된 요청 admission2개 제한**이다. 제한을 늘려 통과시키지 않았다. 무거운 작업은 순차 실행했다.

## 12. 결정·다음 작업·최종 상태

**BLOCKED**는 이 원형의 admission 정책과 AVFoundation reader의 요청 패턴 때문에 Gate1을 수행하지 못했다는 뜻이다. B의 구조적 불가능성이나 renderer 품질 실패가 아니다. 현재 renderer/transfer/reference 구현의 정확성과 성능은 미검증으로 남긴다.

다음 한 가지 권고는 별도 승인된 **2-slot admission/backpressure·취소 설계 리뷰**다. Incoming callback과 rendering/보유 frame의 in-flight 정의를 명확히 하고, framework callback을 기다리게 할 경우의 deadlock·취소 해제·메모리 상한을 검토해야 한다. 무제한 pending queue나 단순 slot 확대를 해법으로 채택하지 않는다. 이번 작업에서는 수정/재실행하지 않는다.

생산 소스·모델·ProjectFile/format8·기존 import/preview/export·spectrum/subtitle 구현은 그대로다. 이미지 import/형식9/Stage3C-2/spectrum export 구현 없음. Owner media/project/output 변경 없음. 기존622개 파일/증거의 preflight hash 및 refs를 종료에 비교한다. ROADMAP/HANDOFF와 이전 IMG 소스/보고서/실패 로그를 보존한다. Staging/commit/push 및 reset/clean/fetch/pull/merge/rebase/branch 전환 없음. 여기서 중단한다.
