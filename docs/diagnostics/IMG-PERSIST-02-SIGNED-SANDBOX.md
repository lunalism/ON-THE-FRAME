# IMG-PERSIST-02 — Signed-sandbox persistence validation

2026-10-30 Asia/Tokyo.
STATUS: AUTOMATED PASS / OWNER TEST REQUIRED

## Baseline and scope

Repository `$REPO`, branch feature/subtitles, HEAD/cached upstream
800f468460e6e3f604c349a35374ac40dbe04fb3; main
44943eadabdf5a37d5242d614e7279813126dfde. CLAUDE.md, ROADMAP/HANDOFF,
[IMG-PERSIST-01](IMG-PERSIST-01-TRANSACTIONAL-PERSISTENCE.md), actual app lifecycle,
project panel/save/open/scope code, signing configuration and previous isolated
probe/app harnesses were inspected. No applicable AGENTS.md found.

All ten IMG-PERSIST-01 source/test/document hashes match its final summary.
No implementation correction was made. The only new publication file in this
task is this report; earlier tracked/untracked work remains uncommitted.
Evidence and generated fixtures are ignored under
`$REPO/app/selftest-work/img-persist02-20261030-01` (`$EVIDENCE`).
No native permission or save dialog was automatically confirmed/manipulated.
No owner projects/media/output were used.

## Actual application and signing

The existing Xcode OnTheFrame scheme was built in Debug, with the intended
Manual/ad-hoc identity `-`, existing Config/OnTheFrame.entitlements and sandbox
configuration. No signing/configuration source or global setting changed.
A separate CONFIGURATION_BUILD_DIR preserves existing executable products:
`$DERIVED_DATA/Build/Products/IMGPersist02-Debug/OnTheFrame.app`.
`$DERIVED_DATA` is the existing internal APFS ON-THE-FRAME/DerivedData root.
No explicit-module/cache relocation overrides were used.

New build invocation (exact argument array retained in build-command.json):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project app/OnTheFrame.xcodeproj -scheme OnTheFrame \
 -configuration Debug -derivedDataPath "$DERIVED_DATA" \
 CONFIGURATION_BUILD_DIR="$DERIVED_DATA/Build/Products/IMGPersist02-Debug" \
 COMPILER_INDEX_STORE_ENABLE=NO build
```

First attempt: driver timeout at 300 seconds, wrapper exit 1; no compiler error
was established. signed-build.log is retained. Its confirmed orphan compiler
was stopped with SIGTERM, not a user application. Same-setting incremental retry
had a 600-second bound and completed BUILD SUCCEEDED, exit 0
(signed-build-retry.log, build-retry-result.json). This timeout is not a test
failure, crash, or a successful first build.

`codesign --verify --deep --strict --verbose=2`, identity display and embedded
entitlement extraction each exited 0. Actual identifier dev.ontheframe.app,
Signature=adhoc, TeamIdentifier not set; no Developer ID certificate claimed.
CDHash: a6df39ce61dd4e668a9b6cefcffe39323f8cfbac.
Effective embedded entitlements:

- com.apple.security.app-sandbox = true
- com.apple.security.files.user-selected.read-write = true
- com.apple.security.files.bookmarks.app-scope = true
- com.apple.security.get-task-allow = true (Debug development entitlement)

No distribution/hardened-runtime assurance is inferred. Extraction produced the
existing codesign colon-syntax deprecation warning, not a signature failure.
Actual process log also records libsystem_secinit AppSandbox initialization.

## Actual signed application observations

LaunchServices `open -n -a <exact new app> <generated project> --args
-OTFLayoutSuite <unique test suite>` used the original SwiftUI @main and
AppDelegate Finder-open route, not the alternate CLI test main. Each launch
exited 0 and used its own dev.ontheframe.persist02.* settings suite, protecting
owner recents/layout. No Open/Save panel was selected or accepted.

- A: PID 1252 read 11,522 bytes, decoded version 9 / media 4 / clips 5;
  media 3 and 4 (generated images) were found. The two deliberately nonexistent
  video/audio fixtures were missing. `open applied missing=2`, 0.076s.
  signed-runtime.log retains the actual runtime trace. This proves current-run
  access/probing, not the mechanism or persistence of every OS scope grant.
- B: actual header-8 conditional-8.ontheframe, PID 1358: decoded version 8,
  media 0 / clips 0, applied missing=0 in 0.019s. This is an empty legacy-8
  serialization/dispatch check, not real video/audio sandbox probing.
- H: invalid.ontheframe, PID 1324: read then failed at decode (0.013s), with no
  open-applied event. Preservation of an already edited session was tested in
  automated app tests; this signed instance began empty.
- I: missing.ontheframe, PID 1337: decoded version 9 / media 4 / clips 5,
  applied missing=4 in 0.028s. Existing missing-reference behavior remained safe.

First B attempt used legacy-8.ontheframe, but that automated fixture had already
been resaved as conditional version 5. Its trace is retained separately as
signed-B-first-version5.log; it is NOT counted as a version-8 execution. The
replacement fixture's actual JSON header was checked before the final B run.

Only newly created B/H/I disposable instances were intentionally SIGTERM'd after
recording. These are not unexpected crashes or proof of explicit scope drain.
A's generated-project instance was left available for owner inspection; no
pre-existing owner application was terminated. The first pgrep snapshot also
matched the log-stream predicate process; signed runtime identifies A's actual
application PID as 1252, not the log observer.

## Scenario matrix

| Case | Newly executed automated evidence | Actual signed environment / remaining boundary |
| --- | --- | --- |
| A valid format 9 | PASS, full state/IDs | Finder/LaunchServices open applied; native Open panel NEEDS OWNER TEST |
| B legacy 8 | PASS, legacy 1–8 | Actual header-8 open applied, empty fixture; native panel/media workflow NEEDS OWNER TEST |
| C first save | PASS, real filesystem + app method | Actual NSSavePanel/destination sandbox grant NEEDS OWNER TEST |
| D Save As | PASS, new destination/relative hints | Actual NSSavePanel and new sandbox destination NEEDS OWNER TEST |
| E replacement | PASS, real replace + precommit preservation | Sandbox replacement grant/transaction NEEDS OWNER TEST |
| F cancel Open panel | Async candidate cancel/stale-result PASS | Native NSOpenPanel cancellation NOT RUN; NEEDS OWNER TEST |
| G cancel Save panel | Precommit Task cancellation PASS | Native NSSavePanel cancellation NOT RUN; NEEDS OWNER TEST |
| H invalid project | PASS, prior editing state retained | Signed decode rejection observed; edited-session native workflow NEEDS OWNER TEST |
| I missing still source | PASS, structure/UUIDs preserved | Signed missing=4 open applied; native panel workflow NEEDS OWNER TEST |
| J repeated save/open | PASS, IDs and metadata | Signed repeated save/relaunch/readback NEEDS OWNER TEST |
| K bookmarks/ownership | Injected lease transfer PASS; real bookmark bytes | Signed image access observed; persistent scoped bookmarks/relaunch/ownership NOT established |
| L release failure/cancel | Injected call-site lease drain PASS | Actual acquired OS-scope counts/drain NOT measured; NEEDS OWNER TEST/instrumented signed harness |
| M image preview/export gate | PASS, app/direct guards, no export created | No signed preview/export command assertions; NEEDS OWNER TEST; no rendering/export workload run |

A native-panel PASS is not inferred from a URL passed by LaunchServices. Task
cancellation is not panel cancellation. Process termination is not explicit
start/stop ownership verification. No comprehensive SIGNED-SANDBOX PASS claimed.

## Newly executed Debug/Release regressions

| Configuration | Engine | Actual app-source standalone harness |
| --- | --- | --- |
| Debug | 93 PASS, 0 FAIL, 0 SKIP, exit 0 | 10 groups PASS, 0 FAIL, 0 SKIP; compile/run/driver exit 0 |
| Release | 93 PASS, 0 FAIL, 0 SKIP, exit 0 | 10 groups PASS, 0 FAIL, 0 SKIP; compile/run/driver exit 0 |

Engine commands use swift test -c debug/release --package-path app/Engine
--scratch-path "$BUILD_ROOT" --filter <IMG-PERSIST-01 summary.json filter>.
BUILD_ROOT remains the existing APFS IMG1A-build. Release adds -Xswiftc
-enable-testing -Xswiftc -DOTF_PROTO_RELEASE. Fresh OTF_MODEL03_RUN fixture roots
are under EVIDENCE. Logs engine-debug.log and engine-release.log include exact
executed tests. Engine filter covers persistence, model/adapter/codec,
operational/clipboard editing, safety, legacy, subtitle and spectrum regression.

App commands: python3 app/diagnostics/IMGPersist01/run-tests.py <debug|release>
<EVIDENCE/app-configuration>. Compiler command/log and run.log are retained.
These compile actual app sources but replace @main and use OTF_PERSIST_TESTS /
OTF_SAFETY_TESTS; scope ownership uses injected resolver/lease hooks. These are
NOT signed app, native panel, or actual OS-scope PASS evidence. Ten groups are
not ten XCTest test cases. The earlier IMG-PERSIST-01 93+10 results are background
only; the table above describes new executions. No GPU workloads/media exports.
Existing deprecation/Swift-concurrency warnings remain; no new source fixes or
confirmed product defects. No unexpected application/test crash or test timeout.

## Owner-only manual procedure and expected results

Use only EVIDENCE/app-debug/fixtures and EVIDENCE/owner-manual. The ignored
owner-fixture-index.json records exact source paths and SHA-256; never substitute
personal documents. Use the new Debug app with a unique -OTFLayoutSuite argument,
not an existing owner session. Save only inside owner-manual/first-save and
owner-manual/save-as; do not overwrite the generated input fixtures.

1. File > Open, select input.ontheframe, then conditional-8.ontheframe.
   Expect correct format dispatch and known fixture missing-media notices,
   preserved editing metadata, no image playback. The conditional-8 fixture is
   empty; it does not validate temporal media access.
2. In a fresh empty project, invoke Save and manually select a new filename in
   first-save. Reopen input.ontheframe, Save As a distinct filename in save-as,
   then Save to replace that generated output. Confirm resulting format 9,
   UUIDs/complete references unchanged, relative hints rebased and source hashes
   unchanged. First-save of an empty image-free project stays conditional 5.
3. Cancel Open and Save As using the native panels; verify project ID, session,
   URL, dirty state and destination bytes unchanged; subsequent commands work.
   Do not confuse a discard-confirmation cancellation with panel cancellation.
4. With an existing generated session active, open invalid.ontheframe, then
   missing.ontheframe. Invalid must retain the old session; missing must retain
   complete referenced media/clip metadata and offer no fake image validation.
5. Repeat save/reopen and relaunch/Recent using only the generated outputs.
   Verify bookmark access under the actual sandbox, not only readable paths
   during this process. Never grant unrelated directories/files.
6. For K/L, use a bounded signed diagnostic harness/instrumentation if necessary
   to observe real successful scope acquisitions, ownership transfer, and paired
   release on candidate failure/cancel/New/close. Current UI and process exit
   alone cannot prove a final active-scope count of zero. Keep async access until
   validation returns; reject stale sessions. This remains an explicit gap.
7. Invoke preview/play/export commands only far enough to verify unsupported
   image diagnostics and refusal before renderer/output creation. Do not run an
   export workload. Confirm normal image import UI remains absent.

No real panel interaction happened in this task; all these owner checks remain
NEEDS OWNER TEST. Cross-volume/power-loss/ACL/xattr guarantees remain outside
this bounded checkpoint. No approved schema or provisional image limits changed.

## Decision, safety and next boundary

AUTOMATED PASS / OWNER TEST REQUIRED. Actual ad-hoc sandbox application path,
entitlements and selected Finder-open behaviors are verified; native-panel
saving, persistent bookmark behavior and actual OS-scope drain remain open.
IMG-IMPORT-01 may be designed in isolation, but enabling a normal user image
import workflow is not cleared by this task. Recommended next bounded task:
owner-assisted native persistence scenarios plus real-scope instrumentation in
an isolated signed harness, before activating import UI.

Only this report was added outside ignored evidence. No normal import,
GPU preview/export integration, Stage 3C-2 or spectrum export changes; no owner
media/project/output modifications; no staging/commit/push or destructive Git
operation. Existing sources and all historical evidence/recovery refs preserved.
Final index empty; branch/HEAD/upstream/main unchanged. Existing untracked Finder
and .claude environment files remain. git diff --check and publication privacy
checks pass; raw runtime/build logs stay ignored and are not publication files.
