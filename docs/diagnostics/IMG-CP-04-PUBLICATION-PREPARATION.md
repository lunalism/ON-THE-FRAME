TASK ID: IMG-CP-04
STATUS: PUBLICATION READY

2026-10-30 Asia/Tokyo. GPU/probe 격리 실험과 진단을 보존하는 체크포인트 준비다. 제품 GPU 채택·normal image import·모든 PNG 변형 지원 승인이 아니다. staging/commit/push는 하지 않는다.

## 1. 저장소·preflight

REPO=ON-THE-FRAME 루트, branch feature/subtitles, HEAD/cached upstream e89534d2778295fcfc0ba4094527af25d2cf1cd2, main44943eadabdf5a37d5242d614e7279813126dfde. 시작 tracked 변경0/index empty. 미추적 파일은 아래 source/doc와 환경4개다. CLAUDE.md를 읽었고 적용 AGENTS.md는 발견되지 않았다. 원격 조회·fetch/pull/reset/clean/rebase/merge/branch 전환 없음. recovery refs도 삭제하거나 수정하지 않는다.

기존 tracked/untracked 및 app/selftest-work의 regular file을 SHA256로 동결했다. 증거 EVIDENCE=REPO/app/selftest-work/img-cp04-20261030-01. symlink fixture를 따라 외부를 읽지 않았다. 전체 ignored generated/build 데이터는 경로·할당량으로 분류하고 역사 evidence 파일은 freeze 대상으로 보존한다. ignored 전체를 공개 manifest로 승격하지 않는다.

## 2. 정확한 publication manifest

[기계 판독용 manifest](IMG-CP-04-MANIFEST.txt)는 아래29개 relative path, 한 줄 한 파일이다. directory staging용 목록이 아니다.

```text
app/Engine/Sources/OnTheFrameEngine/StillImageProbe.swift
app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/ArtifactBoundary.swift
app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/ArtifactBoundaryTests.swift
app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/GenerationRecoveryTests.swift
app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/InFlightLease.swift
app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/InFlightLeaseTests.swift
app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/MetalNV12Experiment.swift
app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/MetalNV12ExperimentTests.swift
app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/SustainedLeaseTests.swift
app/Engine/Tests/OnTheFrameEngineTests/IMGProbe02/ProbeScopeLifecycleTests.swift
app/Engine/Tests/OnTheFrameEngineTests/IMGProbe02/ProbeScopeSession.swift
app/Engine/Tests/OnTheFrameEngineTests/StillImageProbeTests.swift
app/diagnostics/IMGProbe02/ScopeHarness.swift
docs/diagnostics/IMG-GPU-01-METAL-FEASIBILITY.md
docs/diagnostics/IMG-GPU-02-RESOURCE-LIFETIME.md
docs/diagnostics/IMG-GPU-02A-LEASE-CANCELLATION.md
docs/diagnostics/IMG-GPU-02B-R-ACCOUNTING-RESUME.md
docs/diagnostics/IMG-GPU-02B-SUSTAINED-GATE.md
docs/diagnostics/IMG-GPU-02C-BOUNDARY-PREDICATE.md
docs/diagnostics/IMG-GPU-02D-SUSTAINED-VALIDATION.md
docs/diagnostics/IMG-GPU-02E-GENERATION-RECOVERY.md
docs/diagnostics/IMG-PROBE-02-SCOPE-LIFECYCLE.md
docs/diagnostics/IMG-PROBE-03-PNG-VALIDATION.md
docs/diagnostics/IMG-PROBE-04-SAFETY-SANDBOX.md
docs/diagnostics/IMG-PROBE-05-EXACT-ZLIB-BOUNDARY.md
docs/ROADMAP.md
docs/HANDOFF.md
docs/diagnostics/IMG-CP-04-PUBLICATION-PREPARATION.md
docs/diagnostics/IMG-CP-04-MANIFEST.txt

```

구성: GPU Swift8 + probe source/test/scope/harness Swift5 =13 source/helper/test, 역사 GPU8+probe4=12 진단, ROADMAP/HANDOFF2, 이번 보고서와manifest2. **29파일 = 기존tracked2개 수정 + 새파일27개**. 과거 IMG-CP-02의50파일은 이미 HEAD 이전에 checkpoint된 다른 CPU 실험 범위이므로 이번 목록과 합산하지 않는다.

IMG-GPU-01…02E의 최종source8개는 accounting·lease correction까지 포함한다. GPU-02B-R FAIL→02C ACCOUNTING PASS, 02D INCONCLUSIVE→02E GENERATION RECOVERY PASS를 보고서8개로 함께 보존한다.

IMG-PROBE-01은 현재 StillImageProbe source/tests와02…05 보고서의 선행 검증 기록에 남아 있으나, 별도 IMG-PROBE-01 보고서 파일은 찾지 못했다. IMG-MODEL-01 역시 repository의 별도 설계 보고서가 발견되지 않았다. 대화의 설계 검토를 새 확정 문서나 owner 승인으로 재구성하지 않는다. 현재 media model/default duration/format9는 미결정이다.

## 3. 제외 파일·데이터 분류

- .DS_Store, app/.DS_Store, design/.DS_Store: Finder 환경파일.
- .claude/settings.json: 개인/로컬 도구 설정. 공개 제외·미수정.
- app/selftest-work/**: 생성 PNG/JPEG/MOV/MP4, raw dump, JSON·로그·fingerprint·manifest audit, 실제 sandbox app/Info.plist/entitlements/signature 등 실행 증거. **보존하되 공개 제외**.
- app/Engine/.build/**, experiments/**/.build/**, 기존 APFS 개발전용 build/DerivedData/cache: build output. 신규 소스 목록에 포함하지 않는다.
- 기존 user media/project/export, 다른 tracked CPU·subtitle·spectrum 파일: 미수정/이번 manifest 제외. 삭제·정리 없음.
- Git recovery/backup refs: working-tree 파일이 아니며 manifest 제외, 그대로 보존.

Source와 문서는 모두 UTF-8 text이며 binary/generated media를 manifest에 넣지 않는다. runtime Metal shader 문자열은 재현 가능한 Swift 실험 source의 일부다.

## 4. 문서·privacy 검토

이번에 변경한 기존 파일은 docs/ROADMAP.md와 docs/HANDOFF.md의 관련 image section뿐이다. GPU-02E/PROBE-05 최신 요약과 보고서 링크를 추가하고 이전 OPT-01 단락을 당시 CPU 실험 요약으로 구분했다. GPU 제한90프레임 결과·generation recovery, probe 두 corruption 발견→보정, 실제 sandbox와자동검사 차이, 잠정입력한도·제품미구현을 명시했다. Stage3C-2/spectrum export 기록은 그대로다.

이전 GPU/probe 진단12개는 수정하지 않는다. 역사적 BLOCKED/FAIL/INCONCLUSIVE를 그대로 보존하고 최신 결과를 이번 요약에서 연결한다. 기존 문서에 불필요한 개인 절대경로가 발견되지 않아 경로치환을 위한 변경도 없다. $REPO/$BUILD_ROOT/$SELFTEST_ROOT 표기를 유지한다. 새로운 보고서/manifest도 개인경로를 기록하지 않는다.

범용ProRes general-alpha REJECT, CandidateC 구조 불확실성, CandidateB 제한Reader PASS, AVPlayer 여섯프레임 제한PASS, 역사Gate2 QUALITY FAIL, QA02 canonical 재측정PASS, Debug/Release 구분, PERF04 deadline FAIL, PERF05 각3/90miss, OPT01 무의미한개선 기록을 유지했다.

## 5. 증거 판정 경계

- GPU feasibility와02D offline90/90·496.343fps, paced90/90·miss0/90은 이전 고정FHD SDR 단일Mac 직접buffer 관찰이다. output PTS는 test sidecar이며 제품AV callback/화면presentation이 아니다.
- GPU02D 누락조건은02E의 신세대1request admission/render/publication과old retirement로 보완했다. 실제 제품playback/export·장기plateau·device fault·동시다중GPU합성은 미검증이다.
- PROBE02 incomplete IDAT 수용,03 보정,04 trailing 발견,05 zlib exact consumption 보정을 모두 보존한다. 제한PASS를 모든malformed PNG 탐지로 확대하지 않는다.
- 실제sandbox UI는 PROBE04 이전 실행 증거이고 이번에는 **NOT RERUN**. 이번 probe/scope unit검사와 구분한다.
- encoded8MiB/dimension2048/pixels4,194,304/추정decode128MiB·SDR sRGB는 잠정restrictive policy다. normal image import, image media model/기간·format9·production GPU integration은 구현·승인하지 않았다.

## 6. 로컬 의존성과 재현

새GPU source는 HEAD에 이미 있는 IMGBPOC1의 IB420Compositor/IBReference/IBTransfer/IBContract/QA01/IBCanonicalNV12·IBPacedArrivalPlan helper에 의존한다. 별도 신규dependency가 아니며 이 checkpoint에 중복 포함하지 않는다. IBReference.fixture/createPNG 및 ImageAware420GateTests.testInterleavedReaderGate가 생성 입력을 만든다. OTF_IMG_B_POC1_RUN을 **새 고유경로**로 지정하고 OTF_IMG_B_POC1_FIXTURES를 미설정하면 생성 경로를 쓴다. 이 작업에서는 generator/Reader gate를 다시 실행하지 않았다.

GPU fixed-reference 검사는 retained bottom.mov/top.mov/middle.png의 결합digest26bac46cb85992b6e7140cb36cc8f8905c9b700590369af272a506c766db04d1을 요구한다. 다른 OS/encoder에서 재생성한MOV의byte digest가 달라질 수 있으므로 같은 frozen-hash GPU 결과를 자동 재현한다고 약속하지 않는다. 원본생성media는로컬보존이고 공개 제외다. GPU02E/90 gate를 fresh clone에서 실행하려면 이byte-identical generated fixture를 별도 준비하거나 향후검증계획으로freeze를 다시 확립해야 한다. digest검사를 약화하지 않는다.

Probe 대다수 fixture는 tests 자체가 생성한다. 정확한 역사fixture2개 회귀는 env OTF_PROBE03_CORRUPT/OTF_PROBE05_TRAILING에 해당path를 주어야 하며 없으면 그두검사는SKIP한다. 이번실행은 두변수를 모두 지정해SKIP0이었다. 새clone에서는 아래 **정확한 tiny bytes**를 disposable 위치에 재구성해도같은digest가된다. 원본역사fixture는덮어쓰지않는다.

```python
from pathlib import Path
import hashlib
# disposable_root는 새 고유 실행 디렉터리다. 기존 파일 overwrite 금지.
fixtures = {
    'decode-invalid.png': ('89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de0000000349444154780100ba33460b0000000049454e44ae426082',
        '68859130891b0a84d8bd8ff2e14cfdd6b9461eac0f215e4da86513d7e807d3dd'),
    'trailing-deflate.png': ('89504e470d0a1a0a0000000d4948445200000001000000010802000000907753de00000010494441547801010400fbff00000000000004000179a2f94a0000000049454e44ae426082',
        'a273c7e74ddc9402b3b42c8ec86738b4ea301b2f6a06a2a1ee585de42ef44a09')
}
for name, (encoded, expected) in fixtures.items():
    data = bytes.fromhex(encoded)
    assert hashlib.sha256(data).hexdigest() == expected
    with (Path(disposable_root) / name).open('xb') as f:
        f.write(data)
```

ScopeLifecycle용good.png는StillImageProbeTests.testPNGVariantsAndNoMutation의새생성v0.png 등을별도새scope-only폴더로복사한다. scope테스트가decode-invalid.png를직접생성하므로corrupt역사fixture폴더를그대로지정하면보호guard에서거부된다. PROBE04의첫구성오류는해결기록과함께보존한다.

Standalone sandbox harness는SwiftPM source discovery밖의AppKitmain이다. 재현시swiftc **`-swift-version 5 -parse-as-library -D SCOPE_HARNESS -O`**로 Media.swift/RenderSettings.swift/StillImageProbe.swift/ProbeScopeSession.swift/ScopeHarness.swift를별도새.app의Contents/MacOS/ScopeHarness로컴파일한다. Info.plist의CFBundleExecutable=ScopeHarness,별도진단bundleID/APPL와app-sandbox·user-selected.read-only·bookmarks.app-scope entitlements로진단bundle만서명한다. NSOpenPanel은생성good.png/good.jpg/decode-invalid.png/invalid.png만선택하고마지막panel은취소한다. 제품target이나저장panel을자동실행하는절차가아니다. 실제Mac/GUI/서명환경이필요하다는로컬조건을숨기지않는다.

## 7. PNG zlib 안전·호환성 검토

SDK zlib.modulemap은system zlib와link z를제공한다. import zlib는현재macOS15대상·Swift5language mode의Debug/Release에서확인했다. Package.swift/Xcode설정변경·third-party추가없다. 내부StillImageProbe는MediaProbe/normalUI에서호출되지않는다.

z_stream zero init→inflateInit_성공후defer inflateEnd,Data/Array unsafe pointer scope내의유한4096byte입출력,encoded·expected+1한도,각반복cancel,END+offered/avail_in/total_in의완전소비,정확scanline·filter·Adler유지를검토했다. 명백한새수명/compatibility blocker는발견하지않았다. JPEG·ICC경로·scope·identity를변경하지않는다. 모든PNG문법/적대적입력안전성을증명한보안감사나Swift6전환검증은아니다.

## 8. 이번 검증

공통 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer, BUILD_ROOT=기존내부APFS IMG1A-build scratch.

Release bounded tests:

```sh
OTF_STILL_PROBE_RUN="$EVIDENCE/probe-tests" \
OTF_PROBE03_CORRUPT="$SELFTEST_ROOT/img-probe02-20261029-01/fixtures/decode-invalid.png" \
OTF_PROBE05_TRAILING="$SELFTEST_ROOT/img-probe04-20261029-01/probe-tests/testPNGStreamBoundariesAndAdam7/trailing-deflate.png" \
OTF_PROBE02_FIXTURE="$EVIDENCE/scope-fixtures/good.png" \
OTF_PROBE02_OUTPUT="$EVIDENCE/identity-copy" \
OTF_GPU02BR_ACCOUNTING="$EVIDENCE/accounting" OTF_GPU02A=1 \
/usr/bin/time -l swift test --skip-build -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE \
 --package-path "$REPO/app/Engine" --scratch-path "$BUILD_ROOT" \
 --filter 'StillImageProbeTests|ProbeScopeLifecycleTests|ArtifactBoundaryTests|InFlightLeaseTests'
```

release-tests.log: 종료0, **20 PASS/0 FAIL/0 SKIP**. probe9/scope5/accounting2/lease4다. 작은 실제 Metal 정상·controlled cancel 명령의 completion을 실행했다. 90frame·단일/여섯 프레임 합성 benchmark·generation recovery·AVPlayer/export는 이번에 재실행하지 않았다. 기존02E PASS와90frame 수치는 이전 증거다.

Debug 컴파일: `swift build --build-tests -c debug --package-path app/Engine --scratch-path "$BUILD_ROOT"`. debug-build.log 종료0, Build complete9.71초. 컴파일만 했으며 Debug 테스트 PASS로 기록하지 않는다.

Release 컴파일: `swift build --build-tests -c release -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE --package-path app/Engine --scratch-path "$BUILD_ROOT"`. release-build.log 결과는 아래 최종 검증에 기록한다.

SwiftPM unhandled-file 경고는 이번 로그에서 관측하지 않았다. 새 테스트 디렉터리는 Swift 파일뿐이다. Package.swift/ignore 변경 없음. 기존 GPU tests의 async-context wait/non-Sendable capture에 대한 Swift6 전환 경고, 기존 deprecated API/unused/unreachable 경고는 남는다. 현행 package는 Swift5 mode이며 Swift6-ready를 주장하지 않는다. 경고 억제를 위해 source를 바꾸지 않았다.

## 9. 공개 검사·예산

manifest29개 존재/중복/relative path/ignore 제외/UTF8/whitespace, 불필요한 개인 절대경로와 명백한 credential pattern, local Markdown target 존재를 검사한다. 새 untracked는 git diff --check에 나타나지 않아 별도로 검사한다. ignored media/raw/log/build와 환경4파일은 포함하지 않는다. 최종 결과와 freeze 대조는 아래에 기록한다.

Release test-host 명령 최대RSS121,126,912bytes,2048 JPEG 기록점70,778,880bytes. Debug compile 최대RSS741,064,704bytes. crash/timeout 없음. 관리20GiB 유지와 이번 산출물·build 증가512MiB 이하를 확인한다. 기존 output/cache 삭제 없음.

## 10. 권장 commit과 소유자 승인

29개 파일의 단일 checkpoint는 GPU/probe 연구의 실패·수정 이력과 현재 foundation을 함께 보존하는 범위로 적합하다. 제품 기능 완료를 의미하지 않는다. 권장 message: `Checkpoint isolated Metal GPU experiments and still-image probe foundation`.

이번 task는 commit/push를 승인하지 않는다. 다음 publication 지시가 필요하며, 소유자가 exact manifest와 local fixture 제약을 검토할 수 있다. 이미지 duration/model/format9/renderer 채택 결정을 체크포인트 준비 과정에서 확정하지 않는다. 제품 통합은 별도 작업이다.

예상 상태는 기존 docs2개 modified와 새27개 untracked다. 환경4개 untracked와 ignored 증거는 그대로, index는 비어 있고 HEAD/refs는 불변이다. 넓은 디렉터리를 staging하지 않는다.

## 11. 최종 상태

정상 import 미구현, MediaAsset/Timeline/ProjectFile 통합 없음, format9 없음, production GPU 통합 없음, Stage3C-2/spectrum export 변경 없음. 소유자 media/project/output 미변경, destructive cleanup 없음, 모든 역사적 IMG 증거 보존. staging/commit/push 없음.


## 최종 검증 기록

Release compile 종료0, Build complete83.51초. Debug/Release 모두 테스트 타깃까지 컴파일됐으며 Debug 테스트는 실행하지 않았다. Release20개 실제 PASS와 구분한다. SwiftPM unhandled-file 경고0. crash·timeout0. generation-recovery/90frame/actual sandbox는 이번에 재실행하지 않은 이전 증거다.

공개 manifest29개 존재/unique/relative/UTF8/미ignored 확인. whitespace·불필요한 개인 절대경로·명백한 credential pattern·깨진 로컬 Markdown target은 모두0이었다(publication-check.json). 외부 웹링크의 현재 availability나 모든 역사 anchor를 인터넷으로 재검증한 것은 아니다. git diff --check 종료0. Manifest는 actual 파일만 나열하고 glob/디렉터리/환경·generated binary를 포함하지 않는다.

최종 할당량 app5,100,656KiB+experiments1,683,992KiB+전용개발1,779,844KiB=8,564,492KiB(약8.17GiB),20GiB 이내다. 작업 시작 이전 관찰치 대비 새 실험·build 증가 약15MiB로512MiB 이내이며 기존 고유 산출물/Debug 앱을 삭제하지 않았다.

기존 파일 hash 대조와 refs/index 결과는 EVIDENCE/preservation.json, ignored 분류는 ignored-inventory.json에 보존한다. 공개 대상 기존source·tests·GPU/probe 역사보고서는 이번 준비에서 바꾸지 않았다. 새 보고서/manifest와 ROADMAP/HANDOFF 정리만 수행했다. 환경 파일·원본 fixture·실패로그는 남겼다.
