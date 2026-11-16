# IMG-PROBE-03 — Corrupt PNG Validation Hardening

TASK ID: IMG-PROBE-03
STATUS: VALIDATION FIX PASS

2026-10-29, Asia/Tokyo. 정상 이미지 가져오기 완료를 의미하지 않는다.

## 1. 실제 Git 상태

저장소 `$REPO`는 ON-THE-FRAME, 브랜치 `feature/subtitles`. HEAD와 cached upstream은 모두 `e89534d2778295fcfc0ba4094527af25d2cf1cd2`, main은 `44943eadabdf5a37d5242d614e7279813126dfde`. 기존 GPU/probe 소스·진단과 환경 파일은 미추적 상태이며 index는 비어 있다. CLAUDE.md를 읽었고 적용할 AGENTS.md는 발견되지 않았다. fetch 등 원격 동기화는 하지 않았다.

## 2. 원본 재현 fixture

보존된 `$REPO/app/selftest-work/img-probe02-20261029-01/fixtures/decode-invalid.png`.

SHA-256: `68859130891b0a84d8bd8ff2e14cfdd6b9461eac0f215e4da86513d7e807d3dd`.

IDAT는 `780100`으로 zlib/DEFLATE가 끝나지 않는다. 기존 chunk CRC와 메타데이터 검사는 통과한다. 원본 파일은 재생성하거나 덮어쓰지 않았다. 기존 독립 zlib 실패 기록도 보존했다.

## 3. 확인한 원인

수정 전에 정확한 원본으로 기존 validate 성공을 재현했다. 로그: `app/selftest-work/img-probe03-20261029-01/reproduce-actual.log`. 출력은 `imageExists=true sourceStatus=0 frameStatus=0 materializedBytes=4`였다. ImageIO status 0은 complete다.

기존 코드는 metadata만 읽은 것이 아니다. ShouldCacheImmediately CGImage 생성, source/frame status complete 검사, 방향 보정 이미지의 CGContext draw까지 수행했다. 그런데도 이 입력을 수용했다. 따라서 이 환경에서 ImageIO의 복구된 픽셀·complete 상태는 원래 압축 스트림의 완전성을 증명하지 않는다. 디코더 내부 복구 알고리즘 자체를 확인했다는 주장은 하지 않는다.

## 4. 변경 파일

- `app/Engine/Sources/OnTheFrameEngine/StillImageProbe.swift`: PNG 필수 이미지 데이터 검사만 추가.
- `app/Engine/Tests/OnTheFrameEngineTests/StillImageProbeTests.swift`: 원본 fixture 회귀 및 필수 스트림 integrity 대조군 추가.
- `docs/diagnostics/IMG-PROBE-03-PNG-VALIDATION.md`: 이 새 보고서.

기존 lifecycle helper/tests와 이전 진단은 수정하지 않았다. 새 실행 fixture/log는 Git ignored `app/selftest-work/img-probe03-20261029-01`, `-02`, `-03`에만 추가했다.

## 5. 좁은 보정

기존 admission을 통과한 불변 encoded snapshot에 한해 ImageIO 앞에서 PNG IDAT를 검사한다. 연속 IDAT, zlib header/무사전 정책, raw DEFLATE 종료와 입력 완전 소비, 정확한 scanline byte 수, Adler-32, 각 행 filter 0–4를 요구한다. Adam7 pass별 길이를 계산한다. 기존 chunk CRC 검사는 유지된다. Apple Compression을 재사용하며 일반 이미지 디코더나 새 의존성을 추가하지 않았다.

출력 버퍼는 계산한 scanline 크기+1 byte로 제한한다. 임시 버퍼는 독립 함수가 끝난 뒤 기존 ImageIO materialization 전에 해제된다. 입력은 기존 encoded 크기 제한 안이며, 기존 dimension/pixel/추정 decode 한도를 우회하지 않는다. serial validator, cancellation 검사, 전후 FileIdentity 검사와 caller-owned security scope는 유지한다.

필수 stream 오류는 malformed, admission/할당 초기화 제한은 resourceLimit, 기존 unsupported 정책·CancellationError·changed는 별도다. CRC가 유효한 선택적 tEXt 추가는 허용한다. 모든 ancillary 불규칙성을 허용한다는 뜻은 아니다. 기존 profile/HDR 정책은 그대로다.

## 6. PNG 회귀

원본 bad PNG는 inspect 성공 후 validate에서 malformed로 거부된다. 동일 1×1 RGB encoding의 정상 대조군은 허용된다. 추가로 압축 stream truncation, 잘못된 DEFLATE block, Adler 불일치, 부족한 scanline, filter 5를 거부했다. 각 fixture는 chunk CRC를 맞춰 필수 이미지 데이터 검사와 metadata 정책을 구분했다. 유효 opaque/RGBA/truecolor tRNS/indexed+tRNS 및 선택적 tEXt 대조군은 통과했다. 원본 bytes 불변을 검사했다.

## 7. JPEG·metadata

기존 JPEG orientation 1–8 및 2048×2048 admission/decode, sRGB ICC·무프로필, P3·잘못된 ICC·지원하지 않는 PNG depth/HDR/APNG·확장자·한도 거부 회귀가 통과했다. 색/크기 잠정 정책은 변경하지 않았다.

## 8. Scope·취소·identity

기존 ProbeScopeLifecycleTests 5개가 모두 통과했다. 실제 bad compressed pixels 경로도 metadata 후 malformed로 실패하며 acquired=1/end=1/active=0을 assert한다. 새 integrity 검사에서 실패하므로 이 경우 ImageIO까지 진입하지 않는다. 취소와 generation 교체 중 gate가 반환되기 전에 scope를 해제하지 않으며 stale publication을 차단한다. atomic source 교체의 changed 거부, 반복 성공·접근 거부도 통과했다.

실제 sandbox UI 검사는 이번 작업에서 **NOT RERUN**이다. 기존 IMG-PROBE-02 UI 기록과 바이너리는 보존했으며 이번 수정에 대한 새 sandbox UI PASS로 인용하지 않는다. Headless scope 회귀와 실제 OS 권한 검증은 구별한다.

## 9. 명령·건수·종료 코드

`$BUILD_ROOT`는 기존 APFS `Library/Developer/ON-THE-FRAME/IMG1A-build`, `$SELFTEST_ROOT=$REPO/app/selftest-work`다. 새 fixture 경로는 매번 존재하지 않는 경로여야 한다. 모든 실행은 Xcode DEVELOPER_DIR을 지정했다.

공통 명령:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE \
  --package-path "$REPO/app/Engine" --scratch-path "$BUILD_ROOT" --filter StillImageProbeTests
```

수정 전 재현은 `OTF_STILL_PROBE_RUN=$SELFTEST_ROOT/img-probe03-20261029-01/reproduce-fixture`, `OTF_PROBE03_CORRUPT`는 위 보존 원본, `OTF_PROBE03_REPRODUCE=1`, filter `StillImageProbeTests/testPreservedCorruptPNG`. 종료 0, 재현 모드 1 PASS는 **기존 버그 수용 재현**이며 수정 성공 판정이 아니다. 이 모드는 수정 후에는 성공하지 않는 역사 재현용이다.

수정 후 compile+probe: `OTF_STILL_PROBE_RUN=$SELFTEST_ROOT/img-probe03-20261029-02/fixtures`, 동일 CORRUPT 원본, REPRODUCE 미설정. 종료 0, 빌드 성공, 7 PASS/0 FAIL/0 SKIP. 로그 `img-probe03-20261029-02/targeted-compile-corrected.log`.

최종 회귀는 `/usr/bin/time -l`로 공통 명령에 `--skip-build`를 추가했다. 환경:

```sh
export OTF_STILL_PROBE_RUN="$SELFTEST_ROOT/img-probe03-20261029-03/probe-fixtures"
export OTF_PROBE03_CORRUPT="$SELFTEST_ROOT/img-probe02-20261029-01/fixtures/decode-invalid.png"
export OTF_PROBE02_FIXTURE="$SELFTEST_ROOT/img-probe03-20261029-03/lifecycle-fixtures/good.png"
export OTF_PROBE02_OUTPUT="$SELFTEST_ROOT/img-probe03-20261029-03/lifecycle-replace"
```

`good.png`는 이전 생성 fixture를 새 디렉터리에 복사했다. filter의 정확한 문자열:

```text
StillImageProbeTests|ProbeScopeLifecycleTests|ProjectFileTests.test(RoundTrip|Rejects|FrameLimit|Relink)|SubtitleModelTests.testFormatVersionRoundTripAndRejects|SpectrumModelTests.testPersistenceVersionsAndCompatibility|SpectrumModelTests.testLegacyFragmentsKeepIdentitiesAndFormat|InputCompatibilityTests.testProbeAnalysesNonThirtyTiming
```

종료 0. 총21 PASS/0 FAIL/0 SKIP: probe7, lifecycle5, ProjectFile5, InputCompatibility1, SpectrumModel2, SubtitleModel1. 로그 `img-probe03-20261029-03/regressions.log`. 전체 expensive opt-in GPU/media 검사는 실행하지 않았다.

첫 sandbox 기본권한 재현 시도는 APFS scratch/cache 접근 권한 오류로 **테스트 전 종료1** (`-01/reproduce.log`). 이후 승인된 APFS 접근으로 위 재현을 완료했다. 첫 수정 빌드는 compression_stream C struct 초기화 인자 누락으로 **컴파일 종료1, 테스트 미실행** (`-02/targeted.log`). 초기화만 보완한 뒤 위 성공 결과를 얻었다. 모든 첫 로그를 남겼다.

## 10. Crash·timeout·resource

예상하지 못한 test-host/app crash나 timeout은 없었다. compile+test time 최대 RSS 2,561,622,016 bytes는 컴파일러를 포함하므로 probe 메모리로 해석하지 않는다. skip-build 최종 실행 최대 RSS 143,015,936 bytes, 2048 JPEG 측정점의 프로세스 RSS 92,667,904 bytes, RGBA 16,777,216 bytes. 이것은 잠정 128MiB 추정 decode admission과 프로세스 전체 RSS가 동일한 개념이라는 뜻은 아니다. 입력 8MiB/dimension2048/pixels4,194,304/추정decode128MiB 정책은 유지했다. 관리 디스크 전체는 아래 보존 검사와 함께 확인한다.

## 11. 한계

시험한 corruption과 유효 대조군 범위의 PASS다. 모든 PNG 문법·palette index·ancillary 의미·공격 입력 조합을 완전히 검증했다는 주장은 하지 않는다. Adam7 길이 계산은 포함했지만 전용 interlace/depth 전 조합 회귀는 이번에 실행하지 않았다. JPEG 압축 스트림 완전성 정책을 새로 강화하지 않았다. 실제 sandbox UI 재검증은 남아 있다. 정상 UI import·renderer 통합·제품 채택 승인이 아니다.

## 12. 다음 권장 작업

새 validator를 포함한 격리 sandbox harness로 실제 파일 선택→손상 PNG 거부→scope drain을 제한적으로 재검증한다. 정상 가져오기 UI는 별도 승인까지 연결하지 않는다.

## 13. 최종 보존 상태

HEAD/upstream/main과 branch는 작업 전과 같다. index는 비어 있고 staging/commit/push를 하지 않았다. 정상 이미지 import 미활성, MediaAsset/Timeline/ProjectFile/ProjectStore·renderer·spectrum·자막 구현 미변경, format 9·Stage 3C-2·spectrum export 미변경. 소유자 미디어·프로젝트·출력은 사용하거나 수정하지 않았다. 기존 GPU/probe 증거와 recovery refs는 그대로 보존한다. 최종 freeze 대조 결과는 `img-probe03-20261029-03/preservation.json`에 기록한다.

최종 보존 대조: 기존 3,508개 파일 중 허용된 probe source/tests 두 파일만 변경, 누락0. 동일 형식의 for-each-ref 비교로 모든 refs 동일, index empty 확인. 관리 할당량은 app 5,097,428 KiB + experiments 1,683,992 KiB + APFS 전용 개발 디렉터리 1,763,712 KiB = 8,545,132 KiB(약8.15GiB)로 20GiB 안이다. git diff --check 종료0, 세 publication 파일의 별도 trailing whitespace 검사0/불필요한 개인 절대경로0.
