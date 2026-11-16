TASK ID: IMG-PROBE-04
STATUS: BLOCKED

2026-10-29 Asia/Tokyo. 실제 sandbox lifecycle은 통과했지만 새 PNG 압축 종료 회귀에서 추가 바이트의 잘못된 수용을 확인했다. Foundation checkpoint 준비 완료를 선언하지 않는다.

## 1. Git·preflight

REPO=ON-THE-FRAME 루트. feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2. main 기준은 기존 44943eadabdf5a37d5242d614e7279813126dfde. CLAUDE.md와 probe source/tests, PROBE-02/03 진단, 이전 PROBE-01 fixture·실행 기록 및 GPU-02E 증거를 검토했다. 독립 IMG-PROBE-01 보고서 파일은 docs에서 발견되지 않아 기존 기록과 회귀 결과를 사용했다. 적용 AGENTS.md는 발견되지 않았다. 기존 untracked GPU/probe와 환경 파일은 보존했다.

## 2. Validator 검토

- immutable Data에만 접근한다. encoded read는 fileBytes+1로 제한하고 입출력 FileIdentity를 확인한다.
- chunk 반복은 k+12<=count 이후 UInt32 길이를 읽고 n<=count-k-12를 확인하므로 해당 slice와 k 증가가 데이터 범위 안이다. CRC/IHDR/IEND 검사는 기존 inspect에서 수행한다. metadata 내부 Data는 외부에서 주입하지 못한다.
- PNG 치수는 양수이며 multipliedReportingOverflow로 pixel·24배 추정량을 검사한다. 현재 기본2048/4,194,304 제한에서 row 크기·Adam7 ceil 계산·누적·expected+1은 Int 범위 안이다. 임의 확장된 제품 한도를 승인하지 않는다.
- 연속 IDAT 조각은 허용하고 ancillary 뒤 다시 시작한 IDAT는 거부한다. zlib header/dictionary, checksum, 출력 길이/filter 검사와 고정 출력 버퍼를 확인했다.
- 기본8-bit RGB 최대 scanline 출력은 약12MiB이고 +1 sentinel로 초과를 구분한다. encoded/IDAT 복사는 기존8MiB 상한 안이다. 실제 메모리 상한을 OS로 강제하는 decoder sandbox라는 주장은 아니다.
- cancellation은 chunk/Compression process 반복과 최종 검증에서 확인한다. checksum·filter 반복 및 C/ImageIO 단일 호출 내부의 즉시 취소는 보장하지 않는다. 기본 크기로 유한하며 scope는 작업 반환까지 보유한다.
- 전후 FileIdentity guard는 유지한다. 파일 snapshot 이후 교체를 changed로 거부하는 회귀가 통과했다. 마지막 identity 검사 이후의 모든 외부 파일 변경까지 막는다는 주장은 아니다.
- pointer는 withUnsafeBytes/BufferPointer 수명 안에만 사용하며 compression stream destroy가 defer에 있다. 검토·실행 범위에서 OOB나 crash는 발견하지 않았다. sanitizer/fuzzing을 했다는 뜻은 아니다.
- **확인된 결함:** raw DEFLATE END와 src_size==0으로 실제 stream 경계를 보증할 수 없다. 아래 시험에서 종료 후 추가 byte까지 Apple Compression이 소비한 것으로 관찰됐다. 별도 종료 경계 증명 없이 완전 integrity PASS를 선언할 수 없다.

## 3. 변경 파일

- app/Engine/Tests/OnTheFrameEngineTests/StillImageProbeTests.swift: testPNGStreamBoundariesAndAdam7 추가.
- app/diagnostics/IMGProbe02/ScopeHarness.swift: 실제 JPEG 성공·기존 손상 PNG malformed 거부 및 scope count 검사 추가.
- docs/diagnostics/IMG-PROBE-04-SAFETY-SANDBOX.md: 새 보고서.

StillImageProbe.swift는 **변경하지 않았다**. 범위를 넓힌 parser 교체나 근거 없는 checksum 보정은 하지 않았다. 정확한 종료 위치를 노출하지 않는 Compression API 대신 사용할 검증 방법은 별도 한정 설계·검증이 필요하므로 BLOCKED로 중단한다. 실패 assertion은 남긴다.

## 4. PNG integrity·지원 경계

새 한 테스트의 소검사: 연속 IDAT PASS, 비연속 IDAT 거부 PASS, 출력 1byte 초과 거부 PASS, UInt32.max chunk 길이 거부 PASS, Adam7 1×1 빈 pass 및9×9 전체7pass 유효 RGB control PASS. 그러나 valid DEFLATE 종료와 Adler 사이에00 한 바이트를 추가한 trailing-deflate.png는 수용되어 assertion FAIL했다. 이 오류는 XCTest assertion이므로 뒤의 Adam7 검사도 실행됐다.

실패 fixture: EVIDENCE/probe-tests/testPNGStreamBoundariesAndAdam7/trailing-deflate.png. 독립 Python raw zlib 검사는 independent-trailing-check.json에 eof·unused_data를 기록한다. CRC와 Adler 및 pixel bytes는 유효하므로 추가 압축 데이터의 경계 검증 결함으로 구분한다. 기존 원본780100의 incomplete stream과 동일한 실패라고 바꾸어 설명하지 않는다.

현재 정책은 JPEG/단일PNG, RGB/Gray/Indexed, 기본8bit와 indexed1/2/4/8, SDR sRGB 제한이며 APNG·16bit·HDR·광색역 등은 의도적으로 거부한다. Adam7 RGB 두 tiny fixture 통과는 모든 interlace/depth/palette 조합 지원 검증이 아니다. PNG 전체 specification coverage는 주장하지 않는다.

## 5. 실제 sandbox

EVIDENCE=REPO/app/selftest-work/img-probe04-20261029-01. 이전 실행 앱을 덮어쓰지 않고 현재 validator로 새 ScopeHarness.app를 만들었다. 별도 bundle ID dev.ontheframe.probe04-harness, ad-hoc 서명, app-sandbox=true/user-selected.read-only=true/bookmarks.app-scope=true. codesign verify 종료0. 정상 제품 앱을 실행하거나 종료하지 않았다.

CUA로 실제 NSOpenPanel에서 지정된 생성 fixture만 선택했다. 선택 전 good.png read=false. 선택 후 PNG 성공3회 starts3/ends3/active0. async gate에서 cancel 후 active1/ends3을 보유하고 반환 후 starts4/ends4/active0. generation 교체 후 active1/ends4 보유, stale 결과 거부 후 starts5/ends5/active0. JPEG 선택 성공 starts1/ends1/active0. 보존 원본과 동일 bytes의 decode-invalid.png 선택은 malformed로 거부되며 starts1/ends1/active0. invalid.png는 invalidSignature와 동일한 scope drain. 마지막 panel은 Escape 취소, acquisition0.

actual-sandbox.log 최종 ACTUAL-SANDBOX-LIFECYCLE-PASS, published4(PNG3+JPEG1), 앱 종료0. 모든 그룹 active0. 이는 실제 Mac 자동화 결과이며 소유자 수동 검증은 아니다. 중간 C decoder 내부 강제 취소·OS permission revoke·bookmark 재실행은 미검증이다. UI 제어 최초 inventory가 약190초 걸렸으나 앱 crash나 test timeout은 없었다. 서명 검사에 사용한 entitlements 출력 colon 문법 deprecation warning은 validator와 무관하다.

원본 손상 PNG SHA-256: 68859130891b0a84d8bd8ff2e14cfdd6b9461eac0f215e4da86513d7e807d3dd. GUI는 원본의 disposable copy를 선택했으며 원본은 그대로 보존했다.

## 6. 회귀 결과

Release 빌드 성공. 최초 통합22개:20 PASS/2 FAIL/0 SKIP, 종료1. probe8개 중 기존7 PASS/새1 FAIL. 기존 JPEG orientation1–8, ICC/무프로필·정책 거부, 투명PNG/indexed+tRNS, 원본corrupt 거부, cancel/identity/no-mutation은 PASS. ProjectFile5/InputCompatibility1/SpectrumModel2/SubtitleModel1의 기존9개 모두 PASS.

나머지 lifecycle 실패1은 잘못된 fixture 폴더 선택으로 decode-invalid.png가 이미 존재하여 보호 guard denied 발생. validator 문제와 구분한다. 폴더를 새로 분리한 skip-build lifecycle 재실행은5 PASS/0 FAIL/0 SKIP, 종료0. 원래 실패 로그와 fixture를 삭제하거나 재사용하지 않았다.

## 7. 실행 명령

BUILD_ROOT는 기존 APFS Library/Developer/ON-THE-FRAME/IMG1A-build. DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.

```sh
OTF_STILL_PROBE_RUN="$EVIDENCE/probe-tests" \
OTF_PROBE03_CORRUPT="$REPO/app/selftest-work/img-probe02-20261029-01/fixtures/decode-invalid.png" \
OTF_PROBE02_FIXTURE="$EVIDENCE/fixtures/good.png" \
OTF_PROBE02_OUTPUT="$EVIDENCE/identity-copy" \
swift test -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE \
 --package-path "$REPO/app/Engine" --scratch-path "$BUILD_ROOT" --filter '<FILTER>'
```

FILTER:

```text
StillImageProbeTests|ProbeScopeLifecycleTests|ProjectFileTests.test(RoundTrip|Rejects|FrameLimit|Relink)|SubtitleModelTests.testFormatVersionRoundTripAndRejects|SpectrumModelTests.testPersistenceVersionsAndCompatibility|SpectrumModelTests.testLegacyFragmentsKeepIdentitiesAndFormat|InputCompatibilityTests.testProbeAnalysesNonThirtyTiming
```

별도 lifecycle은 --skip-build/filter ProbeScopeLifecycleTests, FIXTURE=EVIDENCE/scope-only/good.png, OUTPUT=EVIDENCE/scope-only/identity로 실행했다. 로그 regressions.log 및 scope-corrected-fixture.log.

Standalone harness compile: xcrun swiftc `-swift-version 5 -parse-as-library -D SCOPE_HARNESS -O`, Media.swift/RenderSettings.swift/StillImageProbe.swift/ProbeScopeSession.swift/ScopeHarness.swift를 입력해 EVIDENCE의 새 app/Contents/MacOS/ScopeHarness로 출력. harness-build.log 종료0. codesign --force --sign - --entitlements EVIDENCE/sandbox.plist EVIDENCE/ScopeHarness.app, verify 종료0. 바이너리 인자는 EVIDENCE/fixtures/good.png. 실제 실행 종료0.

## 8. 자원·위험

큰 미디어·GPU workload·export는 실행하지 않았다. 최대2048 JPEG 회귀의 기록점 RSS156,254,208 bytes(프로세스 전체)이며 추정 decode admission128MiB와 동일한 지표는 아니다. 신규 PNG fixture는 최대9×9다. 프로세스 crash·timeout·확인된 OOB 없음. 압축 종료 후 추가 byte 수용은 미해결 correctness 결함이며 이를 보완하기 전 완전한 PNG 무결성 검증으로 취급하지 않는다. 임시 지원·메모리 정책은 소유자 미승인 상태를 유지한다.

## 9. Checkpoint 준비 여부

**아니오.** 실제 scope 회귀는 닫혔지만 새 negative regression이 실패한다. 실패를 감추거나 기존 PROBE-03 보고서를 덮어쓰지 않는다. 알려진 실패를 실험 증거로 보존할 수는 있으나 probe foundation validated checkpoint로 발표하면 안 된다. staging/commit/push는 하지 않았다.

## 10. 다음 한정 작업

PNG zlib의 정확한 stream 종료·trailing data 검증 방법을 별도 검토하고, 보존된 trailing-deflate.png를 거부하면서 정상 대조군을 유지하는 최소 보정을 승인 범위 안에서 검증한다. 정상 import UI 연결은 이 결함을 닫은 후 별도 결정한다.

## 11. 최종 Git·보존

branch/HEAD/upstream 유지, 빈 index. 새 evidence는 ignored EVIDENCE에만 추가한다. freeze/preservation.json으로 기존 파일과 refs를 대조한다. 정상 이미지 import 미활성, MediaAsset/Media.swift·Timeline·ProjectFile/ProjectStore 미변경, GPU renderer/lease/scheduler·spectrum 미변경. format9·Stage3C-2·spectrum export 미변경. 소유자 미디어/프로젝트/출력 미사용·미수정. staging/commit/push 없음. 이전 GPU/probe 증거 보존.

최종 확인: 기존3,585개 파일 중 허용된 tests/harness 두 파일만 변경, 누락0, 모든 refs 동일, index empty. git diff --check 종료0 및 새 publication3파일 whitespace/private-path 검사0. 관리 할당량 app5,098,620KiB+experiments1,683,992KiB+개발전용1,763,880KiB=8,546,492KiB(약8.15GiB), 20GiB 이내. 새 실패 fixture SHA-256 a273c7e74ddc9402b3b42c8ec86738b4ea301b2f6a06a2a1ee585de42ef44a09, 독립 raw zlib eof=true/unused_data=00/decoded=00000000.
