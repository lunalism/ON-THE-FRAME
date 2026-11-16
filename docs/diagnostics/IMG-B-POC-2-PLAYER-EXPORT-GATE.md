# TASK ID: IMG-B-POC-2

**AVPLAYER: PASS**

**EXPORT: QUALITY FAIL**

AVPlayer API의6시각 seek-buffer gate는 통과했다. Production ExportService를 호출하지 않고0.2초 export를 정확히1회 수행했으며6 decoded presentation frames/PTS/duration은 맞았다. 그러나 고정된 sampled420 reference에서 frame3 PSNR39.9763dB와 frame4 flat maximum4로 기준을 실패했다. 기존 큰 경계 차이는102에서106으로 커졌다. 추가 read-only 진단에서 byte-identical NV12 buffer의 RGB 검사 결과가 representation에 따라 최대101 다르다는 별도 측정 불확실성도 확인했다. **Reference를 교체하거나 점수를 다시 통과시키지 않는다.** Candidate B 채택·제품 이미지 지원 완료 아님.

## 1. 저장소·파일

`feature/subtitles`, HEAD/로컬 upstream `8475ca7813ac7348ecd78990ee3ed9992fb69673`, main `44943eadabdf5a37d5242d614e7279813126dfde`. 기대 상태와 같았다. CLAUDE.md의 보호 범위를 유지했고 적용 AGENTS.md 없음. 기존 ROADMAP/HANDOFF 변경, IMG source/보고서/fixture/log/recovery refs, `.claude/`·`.DS_Store`를 보존했다.

새 실험 파일은 `app/Engine/Tests/OnTheFrameEngineTests/IMGBPOC1/ImageAwarePlayerExportTests.swift` 하나다. 이전 Gate1의5개 파일은 수정하지 않았다. 새 문서는 이 보고서다. Harness는 기존 makePlan/geometry/checkQuality/reference를 호출하되 legacy Gate2 메서드의 production ExportService 호출을 사용하지 않는다. 실제 export는 새 harness의 direct AVAssetExportSession 한 번이다.

초기 실제 실행에 사용한 harness 소스는 첫 run의 `executed-harness.swift`로도 보존했다. 그 뒤 추가한 것은 기존 decoded output의 한 frame을 읽는 clone 진단이며 renderer/reference/scheduler 변경이 아니다.

## 2. Freeze와 최소 precondition

원래 Gate1 marker의 값과 실제 파일의 digest가 모두 일치했다.

- Frozen5-source digest: `abad1880fa5aca180bd716403d156aaeb41d6cefa23bd16c23c9cdb596f95c8d`.
- Fixture digest: `26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1`.
- Plan: `FHD30/6/bottom0:6/png1:5/top2:4/sourceIn0-at0/translation960,540/420v`.

Fixture는 기존 `app/selftest-work/img-b-poc1r-20261028-01/reader/`를 읽었다. 재생성/재인코딩/색·ID·변형 변경 없음. Bottom[0,6), PNG[1,5), top[2,4), FHD30/6frames와709/video-range/Left/ICC+encoded-sRGB/premultiplied128+255/기존 sampling reference를 고정했다.

전체 Gate1을 반복하지 않고 Reader frame2 하나로 바이너리 일관성을 재확인했다. PTS2/30, sourceID2/2, top luma geometry, 동일40dB/flat≤3 검사 통과. Sampled420 PSNR41.1993dB/flat2/최대102로 이전 값과 일치했다. 이후 동일 frozen constructor와 입력으로 player/export plan을 구성했다.

## 3. AVPlayer 결과

무음 headless AVPlayerItem과420v AVPlayerItemVideoOutput을 사용했다. Ready까지약0.080초였다. 비순차 seek로 stale-after-seek를 검사했다.

| 요청 순서 | 요청 시각 | 받아들인 display 시각 | seek 시작→fresh buffer 초 |
|---|---|---|---:|
| 0 | 0/30 | 0/1 | 0.0287 |
| 5 | 5/30 | 5/30 | 0.0375 |
| 1 | 1/30 | 1/30 | 0.8594 |
| 4 | 4/30 | 4/30 | 0.8333 |
| 2 | 2/30 | 2/30 | 0.6484 |
| 3 | 3/30 | 3/30 | 0.6466 |

0/1과0/30은 정확히 같은 시각이다. Seek completion 직후에도 이전 display timestamp가 반복됐다. **112개 stale buffer를 거부**한 뒤 요청 시각과 정확히 같은6개만 받아들였다.6개의 sRGB pixel fingerprint도 모두 달랐다. Source frame guards·top geometry·독립 reference comparison도 통과했다. 임의 display timestamp를 요청 frame에 맞춰 재표기하지 않았다.

Player frame별 sampled420/CG 값은 기존 Gate1과 같았다. Sampled420 최소40.7661dB/flat최대2, CG와의 최대 경계 차이102였다. 이는 API delivery와 고정된 screening의 제한된 통과이며 전체 edge 품질 수용이 아니다.

별도 약0.4초 play 관찰에서는 직전3/30 buffer2건 뒤0/1만 반복됐다. 이 관찰을 여섯 fresh-seek 성공에 섞거나 올바른 연속 재생 증거로 세지 않았다. 지속30fps·실시간 smoothness·physical display presentation·owner manual UI는 검증하지 않았다. Product PlayerNSView/preview 통합도 하지 않았다.

## 4. Export1회와 정확한 출력

필수6시각 player gate 통과 후 direct AVAssetExportSession을1회 호출했다. 기존 ExportService는 실행하지 않았다. Fresh root의 기존 파일 없음 확인 뒤 아래 경로에 썼다.

`app/selftest-work/img-b-poc2-20261028-01/gate2/six-frames.unvalidated.mp4`

Session은약3.474초 뒤 completed였다. 파일10,763bytes, MP4/H.264 avc1,1920×1080, video-range,709/709/709, chromaLeft다. Fixture에는 audio가 없으므로 이 실험은 audio/AAC 경로 검증이 아니다.

독립 AVAssetReaderTrackOutput에서 image-bearing decoded presentation sample만 셌다. **6개, PTS0…5/30, track start0, track duration120/600, container duration120/600**이었다. 둘 다 정확히0.2초이며 container discrepancy 없음. Compressed packet/edit buffer 개수로 frame 수를 대신하지 않았다.

완성 파일이지만 품질 검증을 통과하지 않았으므로 `.unvalidated.mp4` 이름을 유지했다. Validated final output으로 승격하지 않았다. Export retry·bitrate/preset tuning 없음. 파일SHA256은 `c7781efd86c905b80ed60909bca4df0cae364c0eca85ff580b25a219e93acdf5`이며 이후 읽기 진단 전후에도 같았다.

## 5. Source identity·층 순서·geometry

Frozen compositor의 successful source observations에서 bottom0…5와 top2/3가 정확한 source movie time/ID를 유지했다. 완성 파일의 decoded PNG를 별도 standard-library PNG unfilter로 읽어 marker도 검사했다(`decoded-frame-identities.json`).

- Bottom marker ID:0,1,2,3,4,5.
- 번역된 top marker ID: frame2=2, frame3=3.
- Marker의 green-channel black/white bit를128로 구분했다. 이는 색 오차 허용치 변경이 아니라 기존 frame-ID pattern 해독이다.
- Top marker는(+960,+540) 위치에서 PNG 위에 나타났고 PNG가 top을 덮는 잘못된 순서가 아니었다. Bottom marker는 PNG 아래에서 유지됐다.

따라서 presentation 누락/중복과 단순 frame 재사용은 관찰하지 않았다. Player 단계의 top luma geometry는 두 frame에서 각각518,400pixel 불일치0이었다. 최종 lossy output의 모든 RGB 경계를 bit-identical geometry로 증명한 것은 아니다. 최종 ID·예상 위치·layer/reference ROI 대조와 아래 경계 오차를 구분한다.

## 6. 최종 decoded 품질 — 실패 유지

기존 global≥40dB/flat maximum≤3를 그대로 적용했다. 새 edge tolerance를 만들지 않았다.

| frame | sampled420 PSNR | flat | max | p99 | CG PSNR | CG flat | CG max |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0 | 52.1301 | 1 | 28 | 2 | 58.3984 | 1 | 4 |
| 1 | 41.4587 | 3 | 76 | 3 | 41.3663 | 3 | 76 |
| 2 | 40.0561 | 3 | 106 | 3 | 40.3727 | 3 | 106 |
| 3 | **39.9763** | 3 | 103 | 3 | 40.7264 | 3 | 103 |
| 4 | 40.0913 | **4** | 78 | 4 | 40.7361 | 3 | 78 |
| 5 | 56.3283 | 2 | 35 | 2 | 56.8160 | 2 | 18 |

Frame3의39.9763434905를40으로 반올림해 통과 처리하지 않는다. Frame4의flat4도3으로 완화하지 않는다. CG 쪽이 통과했어도 원래sampled420 reference를 버리지 않는다. **EXPORT: QUALITY FAIL**을 유지한다.

모든 frame의worst 좌표/실제RGB/reference RGB·p99·차이pixel 수·PNG 경계x640/x1280·top 경계·prior-worst crossing ROI를`gate2/results.json`에 저장했다. Flat patch가 없는 edge ROI의flat0을 별도 평탄부 품질 증거로 사용하지 않는다.

## 7. Pre-encode·H.264·최종 오차 분리

Player pre-encode 이미지를lossless PNG로 보존하고 최종decoded 이미지와의 차이도 측정했다. Post-vs-pre PSNR은frame0…5 순서로58.3984/45.4285/46.2576/50.4791/47.1912/56.8160dB, flat 최대는1/2/3/2/2/2, global 최대는4/30/17/21/15/18이었다. 고정된RGB 검사 경로의encode/decode 추가 차이이며 아래 buffer 표현 의존성과 구분한다.

기존 최대102의 위치(1279,539)는pre-encode frame2에서 실제RGB[142,149,125] 대reference[40,180,80]이었다. 최종frame2는[146,153,130] 대 같은reference로 최대106이다. Frame3도100→103이었다. 따라서 큰 차이는H.264에서 처음 발생한 것이 아니라 pre-encode부터 존재했고 최종 경로에서 증가했다.

## 8. Raw 경계와 추가 read-only 진단

Pre-encode frame2의 같은(1279,539)에서candidate와reference420의raw Y/Cb/Cr는 모두 **[132,97,73]**이었다. 주변chroma도 큰 차이가 없고 VT의ICC profile hash도 같았다. 그러나 기존RGB 검사값에는102의 차이가 있었다. 명시적nearest709 matrix→ICC의1pixel 진단은 둘 다[40,180,80]이었다. 이nearest 진단을 품질reference로 채택하지 않았다.

추가export나renderer 재실행 없이 기존 완성MP4의frame2를1회 읽고 active plane을 일반CPU buffer에 그대로copy했다.

- Original/clone은 모두FHD420v, active3,110,400bytes 전체 일치·차이0.
- ActiveSHA256: `cfc0e1cf6806181ad6fba09770d61c18029ea5427083abdcbc83ef8e41c9ff2d`。
- Propagating attachment를 같게 했고 VT ICC profile hash도 일치.
- Original은IOSurface-backed, clone은비IOSurface.
- **변경하지 않은IBReference.managed의RGB 결과가 최대101 달랐다**.
- (1279,539)에서original[146,153,130], clone[45,183,85].
- Clone 비교 자체도global41.9882dB/flat1이지만 큰 국소 차이101을 포함한다. Global 통과로 국소 문제를 지우지 않는다.

큰RGB 차이에 buffer representation에 의존하는 검사 변환의 영향이 있다는 실증이다. IOSurface 자체, stride/backing layout, VT 내부 재구성 분기 중 무엇이 직접 원인인지는 특정하지 않았다. 물리 화면에도 같은101의 차이가 난다는 증거는 아니다. 전체102/106을alpha source-over 구현이나H.264에만 귀속할 수도 없다.

추가 진단은`img-b-poc2-20261028-02/gate2/`로 분리했다. 새export0, 기존MP4 변경0. **원래reference·기존score·QUALITY FAIL을 덮어쓰지 않는다.** 절대적 화질 해석과canonical NV12→RGB 측정 계약은 미해결로 남긴다.

## 9. Native 비교·scheduler·취소

최종decoded output의native video component 비교는frame0 full, frame2/3 topROI, frame5 full에서 했다. PSNR57.9498/42.3386/46.0356/56.5700dB, flat1/3/1/2, global 최대16/15/19/26이었다. Screening은 통과하지만 bit parity가 아니고 같은RGB 검사 경로의 영향도 포함한다. Video-only 제품route는 변경하지 않았다.

Scheduler는 고정한2active/pending4 그대로다. 관찰snapshot의 최대active2/pending2, overflow0. 보존한 각scheduler-local trace의 중복terminal claim은 없었다. Player detach 후active0/pending0, terminal13. Export 쪽 마지막snapshot도active0/pending0, terminal6이었다. 다른compositor instance의request ID를global ID로 혼합하지 않았다.

짧은play 관찰 후item detach에서render cancellation record3개를 관찰했다. 별도export cancellation이나 모든race 조건을 검증한 것은 아니다. 취소 검사를 위한 두 번째export도 하지 않았다. 품질 실패 파일은 미검증 이름 그대로 유지했다.

## 10. 명령·exit·실패

기존 내부APFS `IMG1A-build`와 지정DEVELOPER_DIR를 사용했다. Source/fixture와Gate1을 고정한 채 새harness만build했다.

| log | 실행 | exit/결과 |
|---|---|---|
| build-opt-out-first.log | `swift test ... --filter ImageAwareGate2Tests` | 0,1SKIP,compile 성공 |
| build-opt-out-boundary.log | raw 경계 진단 추가 후 같은opt-out | 0,1SKIP |
| gate2-first.log | `--skip-build --filter ImageAwareGate2Tests/testFrozenPlayerThenOneExport` | 0,1test 완료. 데이터의EXPORT QUALITY FAIL 유지 |
| build-readonly-review.log | clone 진단 추가compile | 1,혼합dictionary 추론이 좌표를UInt8로 해석한compiler error |
| build-readonly-review-retry.log | 명시적[String:Any]로 수정,opt-out | 0,2SKIP |
| read-only-boundary.log | `--skip-build --filter ImageAwareGate2Tests/testReadOnlyDecodedBoundaryClone` | 0,1test. 기존file1frame 읽기,export0 |

명령 본체는`swift test --package-path app/Engine --scratch-path <기존APFS scratch> --filter <위filter>`다. Gate2 실행은`OTF_IMG_B_POC2_RUN`과`OTF_IMG_B_POC2_SOURCE`, 추가read-only 진단은`OTF_IMG_B_POC2_REVIEW_FILE`로 기존output도 지정했다. Gate2에는120초wrapper timeout을 설정했으나 발생하지 않았다.

Main test의exit0은 측정 수집의 정상 종료이며 export 품질PASS가 아니다. 최종numericGatePass=false와QUALITY FAIL을JSON에 기록했다. Opt-out SKIP도 품질 증거가 아니다. 보조compile의 첫error log, 실제 실행harness, 실패 수치를 보존했다. Test assertion failure/host crash/app crash/SIGABRT/sandbox failure/tool timeout은 관찰하지 않았다. Owner app을 실행·종료하지 않았다.

## 11. 시간·자원·결론

Main Gate2 test47.026초, wrapper약48.622초, invocation48.65real/50.93user/1.02sys였다. Export session약3.474초. 주test sampled RSS 최대479,854,592bytes(약457.63MiB), invocation 최대488,980,480bytes(약466.33MiB). 보조clone test약1.039초, invocation2.48초. CPU 원형의 지속30fps나 장시간 성능을 주장하지 않는다.

보고서 작성 전 새2run 할당량은1,392+6,200=7,592KiB(약7.41MiB)였다. Repository 전체와 전용developer root의 보수적 합계는약7.81GiB.512MiB/1GiB/20GiB 및 시간limit 초과 관찰 없음.4K/장시간/복수의 무거운export 없음.

**AVPLAYER PASS는API-buffer6시각 검증에 한정한다. EXPORT QUALITY FAIL은 고정한 비교 기준의 결과다. 큰 경계 차이의 원인 분류와buffer 표현 의존RGB 측정 계약은 미해결이다.** 다음bounded 작업은renderer/bitrate 최적화보다 먼저 동일NV12의canonical RGB 검사 계약을 결정하는 리뷰를 권고한다. 이번reference와 기준은 변경하지 않으며 다음export도 시작하지 않는다.

Production source/ExportService/preview route/Media/Timeline/ProjectFile 변경 없음. 이미지import/format9/Stage3C-2/spectrum export 구현 없음. Owner media/project/output 변경 없음. Staging/commit/push와fetch/pull/merge/rebase/reset/clean/branch 변경 없음. 기존666개source/report/evidence hash와refs를 종료에 비교한다. 여기서 중단한다.
