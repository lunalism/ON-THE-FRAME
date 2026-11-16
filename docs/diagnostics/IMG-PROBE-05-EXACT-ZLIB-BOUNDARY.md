TASK ID: IMG-PROBE-05
STATUS: VALIDATION FIX PASS

2026-10-29 Asia/Tokyo. 실험 probe의 제한된 integrity 보정이다. 제품 가져오기 완료나 PNG 전체 명세 검증을 의미하지 않는다.

## 1. 실제 Git·preflight

REPO는 ON-THE-FRAME 저장소 루트. branch feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2, main44943eadabdf5a37d5242d614e7279813126dfde. CLAUDE.md, StillImageProbe.swift/tests, IMG-PROBE-03/04 보고서와 retained fixture를 읽었다. 저장소 내 적용 AGENTS.md 없음. 기존 untracked GPU/probe source·harness·진단 및 환경 파일은 보존했다. fetch/pull/reset/clean/merge/rebase/branch switch 없음.

## 2. 수정 전 재현·digest

정확한 보존 파일:

`app/selftest-work/img-probe04-20261029-01/probe-tests/testPNGStreamBoundariesAndAdam7/trailing-deflate.png`

SHA-256 `a273c7e74ddc9402b3b42c8ec86738b4ea301b2f6a06a2a1ee585de42ef44a09`.

수정 전 기존 testPNGStreamBoundariesAndAdam7을 skip-build로 실행하여 같은 bytes의 fixture가 수용되는 assertion 실패를 재현했다. 1실행/1FAIL/0SKIP, 종료1. 새 재현 fixture와 원본의 digest가 동일하다. 로그 `app/selftest-work/img-probe05-20261029-01/reproduce.log`. 원본은 덮어쓰지 않았다.

독립 Python raw zlib 재확인: eof=true, unused_data=00, decoded=00000000. IDAT hex7801010400fbff000000000000040001. 기존 PROBE-03 불완전780100 실패, PROBE-04 trailing 실패 로그 모두 그대로다.

## 3. 원인·정확한 계약

이전 Apple Compression raw DEFLATE 경로는 zlib header/Adler를 수동 제외하고 END/src_size0을 요구했다. 하지만 보존 입력에서 DEFLATE 종료 뒤00까지 입력을 소비하여 END+src_size0을 충족했다. 따라서 그 API의 관찰된 입력 소비를 마지막 DEFLATE byte 위치와 동일시할 수 없었다. 내부 read-ahead 구현 자체를 분석했다는 주장은 아니다. ImageIO complete/materialization도 압축 무결성의 충분조건이 아니다.

새 계약: **연결한 모든 IDAT payload가 정확히 하나의 완전한 zlib stream이어야 한다.** 플랫폼 inflate가 header부터 Adler까지 포함한 stream을 처리하고 Z_STREAM_END를 반환해야 한다. 그 시점에 offered==전체payload길이, avail_in==0, total_in==전체payload길이를 모두 요구한다. 첫 stream 뒤 추가 payload나 두 번째 stream, 아직 제공되지 않은 tail도 거부한다. PNG chunk framing은 inflate에 전달하지 않으므로 유효 tEXt/IEND 등 IDAT 밖 chunk는 이 조건과 구별된다.

## 4. 변경 파일

- app/Engine/Sources/OnTheFrameEngine/StillImageProbe.swift: import zlib와 PNG 필수 이미지 데이터의 bounded inflate 교체만.
- app/Engine/Tests/OnTheFrameEngineTests/StillImageProbeTests.swift: 정확한 보존 fixture/digest 거부 회귀, stream-after-tail·두stream·별도연속IDAT tail·긴tail·정상post-IDAT ancillary·분할입출력 control 추가.
- docs/diagnostics/IMG-PROBE-05-EXACT-ZLIB-BOUNDARY.md: 새 보고서.

Package.swift·프로젝트 빌드 설정·harness·scope helper·기존 진단·ICC 경로는 수정하지 않았다. Apple SDK의 zlib.modulemap은 link z를 제공하며 기존 SwiftPM 빌드에서 import/link가 성공했다. 새 패키지/서드파티 의존성 없음.

## 5. Decompressor·자원 안전

PNG snapshot은 기존 inspect의 encoded8MiB/dimension2048/pixels4,194,304/추정decode128MiB admission 뒤에만 처리한다. 기존 chunk length/CRC/IHDR/IEND/IDAT continuity와 정확한 noninterlaced/Adam7 scanline 길이 계산을 유지한다. 기본 치수와 overflow 검사 아래 정수·버퍼 offset이 제한된다.

inflateInit_는 zero-initialized z_stream과 SDK ABI 크기를 사용한다. 성공 후 defer inflateEnd가 성공·오류·취소 모든 반환 경로에서 실행된다. next_in/next_out은 Data/Array의 withUnsafe scope 내부에서만 사용하며 C 타입의 mutable input pointer는 API bridge용으로만 제공한다. 원본 bytes를 수정하지 않는다.

입력과 출력은 한 번에 최대4096bytes씩 제공한다. 출력 backing buffer는 expected scanline bytes+1이고, 각 iteration에서 남은 출력 범위를 확인한다. 입력은 snapshot 범위를 넘지 않는다. zlib 기본 window와 내부 상태만 쓰며 dictionary·복구·두 번째 stream 재시작은 하지 않는다. stream.total_out은 이 작은 출력 범위, total_in은 encoded 한도 안이다. 더 큰 사용자 승인 없는 limits를 만들지 않는다.

Z_STREAM_END가 아닌 상태는 Z_OK와 실제 input/output progress를 요구한다. Z_MEM_ERROR는 resourceLimit, dictionary/data/buffer/no-progress 등은 malformed로 실패한다. END는 zlib checksum 검증을 포함하며 기존 별도 Adler 계산도 보존했다. 정확한 output length와 각 filter0–4를 유지한다. 출력이 넘치거나 stream이 끝나지 않으면 거부하고 partial recovery는 하지 않는다.

Task.checkCancellation은 매 inflate/chunk iteration과 기존 전후 위치에 있다. checksum/filter/C단일호출 내부에서 즉시 중단을 보장하지는 않지만 입력·출력은 제한된다. FileIdentity와 caller-owned scope 반환 순서는 변경하지 않았다.

## 6. 양성·음성 회귀

- 정확한 보존 trailing PNG: inspect 성공 후 validate malformed, digest/source bytes 불변.
- 정상 single IDAT, 여러 consecutive IDAT, 유효 tEXt+IEND와 post-IDAT tEXt: 허용.
- DEFLATE 뒤 Adler 전00, 완전 zlib 뒤00, zlib+zlib, 두 번째 연속IDAT의 extra byte, 5000byte tail: 거부.
- 기존 truncated stream, 잘못된block·Adler, 부족/초과scanline, filter5: 거부.
- 정상 RGBA/truecolor tRNS/indexed+tRNS, 기존 JPEG orientation1–8·ICC·무프로필·최대허용크기: 통과.
- Adam7 RGB1×1과9×9: 유지. 정상64×64 PNG의 raw scanline12,352bytes는 입력·출력4096 분할 경로를 실제로 거친다.
- 기존 과대chunk·입력/치수/overflow bounds와 unsupported depth/HDR/APNG/profile/확장자 정책은 유지한다.

## 7. Scope·취소·identity

ProbeScopeLifecycleTests5개가 통과했다. 성공·denied·metadata오류·필수 pixel data 오류·cancel·generation replacement·atomic input replacement 회귀가 유지된다. 작업이 await gate를 반환하기 전 scope를 해제하지 않으며 stale publication을 거부하고 최종 active0을 assert한다. source byte 불변 검사도 유지한다.

실제 sandbox UI는 **이번 작업에서 재실행하지 않았다**. Scope/harness 코드를 수정하지 않았으므로 소유자 지시에 따라 PROBE-04 actual-sandbox.log를 **이전 증거**로만 재사용한다. 새 validator의 새 GUI 실행 PASS라고 주장하지 않는다. 이전 결과는 PNG3/JPEG1 성공, 원본corrupt 거부, cancel/replacement 보유 후drain, 전체active0, 앱종료0이다.

## 8. 정확한 명령·결과

BUILD_ROOT는 기존 APFS Library/Developer/ON-THE-FRAME/IMG1A-build, E1=REPO/app/selftest-work/img-probe05-20261029-01, E2=동일 -02. DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.

수정 전 재현:

```sh
OTF_STILL_PROBE_RUN="$E1/reproduce" swift test --skip-build -c release \
 -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE \
 --package-path "$REPO/app/Engine" --scratch-path "$BUILD_ROOT" \
 --filter StillImageProbeTests/testPNGStreamBoundariesAndAdam7
```

1 FAIL, 종료1. 이는 의도한 기존 결함 재현이며 테스트 host crash가 아니다.

수정 후 두 실행의 공통명령(첫 E=E1, 최종 E=E2):

```sh
OTF_STILL_PROBE_RUN="$E/tests" \
OTF_PROBE03_CORRUPT="$REPO/app/selftest-work/img-probe02-20261029-01/fixtures/decode-invalid.png" \
OTF_PROBE05_TRAILING="$REPO/app/selftest-work/img-probe04-20261029-01/probe-tests/testPNGStreamBoundariesAndAdam7/trailing-deflate.png" \
OTF_PROBE02_FIXTURE="$E/scope-fixtures/good.png" \
OTF_PROBE02_OUTPUT="$E/identity-copy" \
/usr/bin/time -l swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE \
 --package-path "$REPO/app/Engine" --scratch-path "$BUILD_ROOT" --filter '<FILTER>'
```

FILTER:

```text
StillImageProbeTests|ProbeScopeLifecycleTests|ProjectFileTests.test(RoundTrip|Rejects|FrameLimit|Relink)|SubtitleModelTests.testFormatVersionRoundTripAndRejects|SpectrumModelTests.testPersistenceVersionsAndCompatibility|SpectrumModelTests.testLegacyFragmentsKeepIdentitiesAndFormat|InputCompatibilityTests.testProbeAnalysesNonThirtyTiming
```

첫 보정23PASS/0FAIL/0SKIP, 종료0. 최종 분할처리 대조군을 추가한 결과는 아래 최종 검증 기록에 명시한다. 각 실행 fixture는 새 디렉터리이며 이전 결과를 덮어쓰지 않았다. 23개 구성:probe9/lifecycle5/ProjectFile5/InputCompatibility1/SpectrumModel2/SubtitleModel1. 로그 각 E/regressions.log. 컴파일 성공과 XCTest 통과를 구분하며 GPU/전체opt-in media/AVPlayer/export는 실행하지 않았다.

## 9. Crash·timeout·resource

첫 보정 compile+test92.34초, 최대RSS3,050,029,056bytes는 compiler 포함이다. probe 최대2048 JPEG 기록점RSS92,733,440bytes/RGBA16,777,216bytes. 추정decode admission과 process RSS는 별개다. 예기치 않은crash·test-host termination·timeout은 없다. 환경 ps 관찰은 sandbox권한으로 거부되어 사용하지 않았다. 기존 Media.swift deprecated API warning은 별개이며 수정하지 않았다. 새 입력·출력은 tiny fixture와 기존 최대2048 생성fixture만이다.

## 10. 남은 PNG/JPEG 한계

모든 malformed PNG·palette/ancillary 의미·공격 조합 검증이 아니다. Adam7 모든depth/color 조합과 대규모fuzzing/sanitizer 검증은 하지 않았다. 정상 지원 범위나 잠정정책을 확대하지 않았다. JPEG bitstream integrity는 이번 보정 대상이 아니며 기존 ImageIO/metadata 경로다. C호출 중간 강제취소·OS scope revoke·persisted bookmark 재실행은 미검증이다.

## 11. Checkpoint 판단

본 한정 probe foundation의 알려진 PROBE-04 stream boundary blocker를 닫는 체크포인트 후보로 적합하다. 제품 import 완성·renderer 채택·정책승인·형식9 승인은 아니다. 전체 uncommitted GPU/probe publication manifest나 commit 승인을 대신하지 않는다.

## 12. 다음 권장 작업

현재 probe source/tests·scope harness·진단을 대상으로 증거 포함/제외를 명시한 한정 Git checkpoint manifest를 검토한다. 정상 import UI 연결은 별도 승인까지 하지 않는다.

## 13. 최종 Git·데이터 보호

branch/HEAD/upstream/main 동일, index empty. 정상 import 미연결, MediaAsset/Timeline/ProjectFile/ProjectStore 미변경, GPU renderer·spectrum/subtitle 구현 미변경. format9·Stage3C-2·spectrum export 미변경. 소유자 media/project/output 미사용·미변경. staging/commit/push 없음. 기존 모든 IMG evidence와 recovery refs 보존. 최종 freeze 대조와 자원 수치는 아래에 기록한다.

최종 실행 E2/regressions.log: Release 컴파일 성공,23PASS/0FAIL/0SKIP, 종료0, XCTest0.161초, 전체명령69.92초. compile 포함 최대RSS2,544,861,184bytes,2048 JPEG 기록점RSS92,766,208bytes. 기존 input/cancel/identity/lifecycle와 추가4096byte 분할 경로·긴tail 검사가 모두 실행됐다. 실제 sandbox 신규 실행 없음.

최종 보존 검사: freeze3,647개 중 허용된 probe source/tests2개만 변경, 누락0, refs동일/index empty. preservation-final.json에 기록했다. git diff --check 종료0, publication3파일 trailing whitespace0/불필요한 개인절대경로0. 할당량 app5,099,772KiB+experiments1,683,992KiB+전용개발1,765,576KiB=8,549,340KiB(약8.15GiB),20GiB 이내.
