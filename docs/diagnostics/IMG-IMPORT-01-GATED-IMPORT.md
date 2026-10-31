# IMG-IMPORT-01 — Gated still-image import

2026-10-30 Asia/Tokyo. Status: GATED IMAGE IMPORT PASS (bounded internal workflow).

## Baseline and preserved work

`$REPO` branch feature/subtitles, HEAD/cached upstream
800f468460e6e3f604c349a35374ac40dbe04fb3; main
44943eadabdf5a37d5242d614e7279813126dfde. CLAUDE.md and applicable instruction
locations, ROADMAP/HANDOFF, probe/model/adapter/persistence/sandbox reports and
actual import, mutation/history, scope, panel and safety code were reviewed.
No applicable AGENTS.md. No Git history/index/branch mutation or network refresh.
IMG-PERSIST-01/02 code and evidence remain; the ProjectStore integration below
extends that uncommitted work without discarding it.

EVIDENCE is `$REPO/app/selftest-work/img-import01-20261030-01`, ignored. BUILD_ROOT
is the existing internal APFS IMG1A-build and DERIVED_DATA the existing app
DerivedData root. No cache relocation, installation or global configuration edit.

## Exact task file set

Modified existing files:
- app/OnTheFrame/ProjectStore.swift — gated single-image transaction/panel/action,
  scope/bookmark ownership and cancellation/session fences; permit existing
  operational editing only in the explicitly enabled build; clear stale preview;
  filter undo-inactive location sidecars at save time.
- app/OnTheFrame/OnTheFrameApp.swift — gated internal menu/cancel action and single
  JPEG/PNG Finder-open routing. Existing video/audio panel and normal paths remain.
- app/OnTheFrame/TimelineView.swift — display names from the complete catalog,
  retaining temporal names and including images without fake MediaAsset objects.
- app/OnTheFrame/ContentView.swift — replace the misleading empty-media text for
  an image-only project with a timeline-editing/unsupported-preview explanation.
- docs/ROADMAP.md and docs/HANDOFF.md — current internal-only status; old findings retained.

New files:
- app/Engine/Sources/OnTheFrameEngine/StillImageImport.swift
- app/Engine/Tests/OnTheFrameEngineTests/StillImageImportTests.swift
- app/diagnostics/IMGImport01/ImageImportAppTests.swift
- app/diagnostics/IMGImport01/GateDisabledAppTests.swift
- app/diagnostics/IMGImport01/run-tests.py
- app/diagnostics/IMGImport01/build-signed-app.py
- docs/diagnostics/IMG-IMPORT-01-GATED-IMPORT.md

No Media/Timeline/ProjectFile/schema/codec/adapter/StillImageProbe/GPU/spectrum
source edits. The engine facade delegates to existing validated proof registration
and placement; it does not expose fake source duration, frames or SourceTiming.

## Gate, UI and transaction

Both custom compilation condition OTF_IMAGE_IMPORT and launch argument
-OTFEnableImageImport are required. Normal Debug/Release builds are off, even if
the argument is supplied. This is not a default DEBUG-only enable switch.
The menu, request action and asynchronous mutation method each enforce the gate.

File > 내부 시험 이미지 가져오기… uses a real NSOpenPanel, [.jpeg,.png], files
only, single selection. Cancel returns before probing/model mutation. Finder
routes exactly one jpg/jpeg/png URL only when gated; extension merely routes to
the strict probe, never authorizes content. Existing [.movie,.audio] import panel
and media queue remain. Multiple-image Finder/batch import is not implemented.

StillImageImport.prepare performs the existing full probe off the main actor and
awaits its serial validator. Limits remain encoded <=8 MiB, longest dimension
<=2048, source pixels <=4,194,304, estimated decode <=128 MiB; no policy expansion.
Metadata/signature inspection is not approval until strict full validation returns.
JPEG/PNG variants rejected by the existing probe remain rejected, including
unsupported animation/color/depth. No new format acceptance was added.

One app image transaction runs at a time. Access is acquired before asynchronous
work and retained until the child probe returns, including cancellation. Cancellation
propagates to the detached task; synchronous C/ImageIO work is bounded but not
claimed instantly interruptible. A real scoped bookmark must be created before
insertion; failure aborts. Registration and placement occur in a local candidate,
then epoch/session/timeline/open/gesture/cancellation checks fence publication.
No media or clip is registered on validation/permission/overlap/stale failure.

Success creates a fresh media UUID and clip UUID, default display length 150,
sourceIn=0, with no temporal registry entry/audio eligibility. Selected lane/default
video lane, existing ordering and overlap rules apply. The whole candidate enters
normal history once. Existing split/trim/minimum-one-frame/move/copy/ripple and
undo/redo operate through the existing engine. Repeated import gets distinct IDs;
undo/redo/persistence retain those identities.

A successful acquired scope transfers to project-session ownership; it stays held
for undo/redo and is released by existing stopAllScopes on replacement/close.
Undo may remove a reference while redo still needs it. Session URL/lease retention
is intentional; save only publishes currently active reference sidecars, preventing
orphan-bookmark errors after undo. Redo can refresh bookmarks from retained URLs.
Failure/cancel/stale operations release their local acquisition exactly once.
No source copy, write, overwrite, or silent revalidation/migration occurs.

## Preview/export safety and UI boundary

The renderer/planner guards remain unconditional. Only mutation guards are relaxed
by the explicit internal gate. Unsupported content invalidates generations,
interactive frames and overlays, clears the old plan/player item/subtitles, pauses
and updates document dirty state. Experimental Metal composition is not installed.
An image-only project has no native playback item; export remains blocked.

Timeline names use full references. The existing media list is still temporal-only;
images are edited through their timeline clips, not fake video rows. Image media
list/relink UI is not delivered here. Initial actual AX inspection showed a 5-second
image timeline and disabled export, but misleading empty-media text; the localized
message correction above addresses that. No broad UI redesign.

## Newly executed automated checks

Engine Debug and Release each initially executed 105 selected XCTest cases:
103 PASS, 2 SKIP, 0 FAIL, exit 0. The two SKIPs required preserved corruption
fixture environment variables. A separate --skip-build run supplied both original
generated fixtures and executed those two cases: 2 PASS, 0 SKIP, 0 FAIL, exit 0
in each configuration. Thus all 105 distinct selected engine cases have executed
PASS evidence; the initial skips are retained, not relabeled as executed passes.

Filter: IMG-PERSIST-01's 93-case filter plus StillImageImportTests,
StillImageProbeTests and InputCompatibilityTests.testProbeAnalysesNonThirtyTiming.
Fresh OTF_MODEL03_RUN/OTF_STILL_PROBE_RUN roots. Release adds -Xswiftc
-enable-testing -Xswiftc -DOTF_PROTO_RELEASE. No media export/GPU tests selected.
The preserved decode-invalid/trailing-deflate files are read-only historical
fixtures; the app tests additionally generate disposable corrupt/dimension/size
fixtures. No original evidence was rewritten.

App tests compile actual app sources with a disposable alternate test main, using
OTF_PERSIST_TESTS/OTF_SAFETY_TESTS. These are not signed-sandbox or panel tests.
- Internal Debug/Release: 7 groups PASS, 0 FAIL, 0 SKIP, compile/driver/process exit 0.
- Same compiled internal executable without the launch opt-in: 1 gate group PASS
  per configuration, with no source mutation.
- Normal compile without OTF_IMAGE_IMPORT, even with runtime opt-in: 1 gate group
  PASS per Debug/Release, no scope call and no panel/model mutation.
- Existing IMG-PERSIST-01 app regression rerun: 10 groups PASS per Debug/Release,
  compile/driver/process exit 0; no test was substituted with an ordinary SKIP.

Coverage: JPEG, opaque/alpha PNG, signature/corruption/limit rejection, permission
bookmark failure, placement conflict, repeated IDs, source bytes unchanged,
undo/redo, 1-frame trim/split/move/copy/ripple, UI names, save after undo and full
format9 metadata/bookmarks; before-validation and pending-result cancellation,
pre-cancelled task, simultaneous admission rejection, scope retention/drain and
project replacement/stale result. Existing video/audio import runs with disposable
copies of known generated otf-A.mp4/aud-wav48s.wav, without placing/exporting them.
Probe regressions separately exercise cancellation at the validator seam. No claim
of interrupting an actual in-progress C decoder instruction is made.

Harness scope accounting uses injected successful leases and minimal bookmarks at
the actual production call sites; final project replacement yields starts==stops,
active zero. Real scope observations below are separate. The initial extra editing
harness compilation failed because it directly assigned private-set playhead;
the harness was fixed to call actual seek(to:) and original assertions retained.
import-final-debug/compile.log preserves that first failure. There was no runtime
crash or ignored assertion. Earlier six-group passes precede the broadened final
seven-group runs and are not added to final counts.

Commands: python3 app/diagnostics/IMGImport01/run-tests.py <debug|release>
<fresh evidence path>; OTF_IMPORT_GATE_ONLY=1 selects the normal-compile check.
Existing persistence command remains its original run-tests.py. All compiler
commands/run logs and driver exits are preserved under EVIDENCE.

## Actual signed application observations

The attempted Xcode Debug internal build (custom OTF_IMAGE_IMPORT, separate product
directory, whole-module mode) hit its 480-second bound. It is NOT BUILD PASS.
No compiler error was established, no orphan compiler remained at the later check,
and the full original log/argument array/result were retained. No cache reset or
source workaround was used to conceal the timeout.

build-signed-app.py then compiled the ORIGINAL SwiftUI @main and AppDelegate with
all actual app sources, DDEBUG/OTF_IMAGE_IMPORT, Swift5/strict concurrency/macOS15,
and matching built Debug engine objects. It creates an isolated validation bundle
with the repository Info.plist resolved for dev.ontheframe.import01-validation,
and signs with the unchanged Config/OnTheFrame.entitlements. It is a source-built
real app/UI validation bundle, not the alternate test host or a successful normal
Xcode packaging regression. No public default/signing configuration was changed.

Compile, ad-hoc signing, deep/strict verification, identity/entitlement display
exited 0. Effective sandbox, user-selected.read-write and bookmarks.app-scope are
true; TeamIdentifier not set, no Developer ID/distribution assurance claimed.
Per-launch unique layout suites and isolated bundle ID prevent owner preferences
and recents changes. Original SwiftUI scene/AppDelegate Finder route ran.

Initial actual app executions through LaunchServices (not NSOpenPanel):
- Without launch opt-in, a generated JPEG went through unchanged temporal rejection;
  no internal image commit event occurred.
- JPEG, opaque PNG and alpha PNG each committed one distinct media/clip pair,
  sourceIn 0, length 150, scopeTransferred=true, sessionScopes=1, bookmarks=1.
  These are real scope acquisitions and real .withSecurityScope bookmark creation,
  not injected leases. The held scope is deliberate session ownership.
- Corrupt PNG was rejected before commit; scopeReleased=true, scopeTransferred=false.
- All selected generated source SHA-256 values remained unchanged.

actual-*.log and actual-results.json retain those observations. Only newly launched
disposable instances were intentionally terminated; process exit is not explicit
scope-drain evidence. The alpha test instance was retained for read-only UI
inspection. CUA inspection took about 86 seconds; it was not a test-host timeout.
No native Open/Save or permission dialog was automatically operated or confirmed.

Final message-corrected source bundle: signed-final-app, compile/sign/verify exits
0, CDHash e3f65930c845f9039ef5d1ba3c826ce20a6f52c3. Actual final alpha import
again committed length150/sourceIn0, real scopeTransferred=true/sessionScopes1/
bookmarks1; final corrupt input was rejected with scopeReleased=true. Logs are
actual-final-alpha.log and actual-final-invalid.log. The final alpha instance
PID3471 remains available for owner inspection; the earlier inspection instance
PID3163 was intentionally retired, without touching pre-existing owner apps.
Final read-only CUA state confirmed the corrected image explanation, 00:00:05:00
project duration, edited document and disabled export button. No panel was operated.
Final Debug/Release app logs app-final-debug/app-final-release each show 7 groups
PASS plus 1 default-off group PASS, compile/process/driver0. Earlier normal-gate
and persistence regression evidence remains applicable; the final UI/cancel text
changes did not alter those gate/persistence policies. summary.json records final
hashes, file set, evidence paths and preservation results.
No generic SIGNED-SANDBOX PASS or native-panel PASS is inferred. Real OS scope
cancellation/New/close and bookmark persistence across native save/relaunch still
need owner-assisted verification; injected drain evidence is labeled accordingly.

## Exact owner Mac manual procedure

Use only the final generated ImageImportInternal.app under EVIDENCE/signed-final-app
and EVIDENCE/import-verified-debug/fixtures-enabled. Never substitute personal
images/projects. Native Save confirmation is performed by the owner only.

1. Launch the internal bundle with -OTFEnableImageImport -OTFLayoutSuite
   dev.ontheframe.import-owner.<unique>. Without the first argument the internal
   image menu must be absent; a normal build ignores even that argument.
2. File > 내부 시험 이미지 가져오기…; manually choose good.jpg. Expect a named
   V1 visual clip [0,150), 5-second timeline, dirty document, unsupported-preview
   explanation and blocked export. Original source bytes must remain unchanged.
3. Move the playhead to End (150), import opaque.png; repeat at End with alpha.png.
   Expect three references/unique clips. At frame 0 import again: overlap must
   report failure with unchanged timeline/history, without an orphan reference.
4. Split/trim to minimum one frame, move, copy/paste, ripple delete and undo/redo.
   Verify no image audio/spectrum eligibility. Images are not temporal media-list
   rows; edit their timeline clips. No image pixel preview is expected.
5. Select bad.png, dimension.png (2049 px), limit.png (>8 MiB): reject each, retain
   prior project. Cancel the actual selection panel with Escape: no session change.
6. Use 내부 이미지 가져오기 취소 while validation is pending; if it already finished,
   do not claim an actual cancellation race. Deterministic async seams in the app
   and probe tests cover the bounded race; inspect paired real scope calls in an
   instrumented owner run to close the remaining OS lifecycle observation gap.
7. During pending import request a new/opened disposable project; stale results
   must not publish. Confirm responsiveness, no old frame/overlay reuse and no
   leaked local lease; real OS counts need instrumentation rather than UI inference.
8. Owner-confirm Save As into a NEW EVIDENCE/owner-save directory, then repeat
   Save/Open/relaunch. Check format9, UUIDs/unused references/bookmarks unchanged,
   correct relative paths, missing source preservation, no source overwrite.
   Undo image import, save image-free state, redo and save again must work.
9. Test existing generated video/audio selection separately. Do not run media
   exports or GPU workloads. No real panel scenario is claimed passed beforehand.

## Remaining limits and decision boundary

This is internal gated import, not public/general image support. Image media-list
rows/relink UI, image preview/export, high-resolution policy expansion and complete
owner workflow remain out of scope. Format9 schema is unchanged. Regular Xcode
internal packaging has a recorded timeout; the real source-built signed validation
bundle is independently verified. No claim of release packaging or production
adoption, complete PNG coverage, or all-volume durability is made.

Recommended next implementation task (proposal): gated image catalog display and
safe explicit relink UI, retaining preview/export fences and the existing probe
limits; owner native-panel/lifecycle checks should precede broadening exposure.

No staging, commit, push, branch/history rewrite, user media/project/output write,
public activation, GPU integration, Stage 3C-2 or spectrum export change. No old
reports/logs/evidence deleted. Exact final file hashes, privacy/reference checks,
recovery-ref preservation and Git state are recorded in summary.json.
