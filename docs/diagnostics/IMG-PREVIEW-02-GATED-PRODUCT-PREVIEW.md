# IMG-PREVIEW-02 — Gated product preview integration attempt

2026-10-31, Asia/Seoul. **STATUS: BLOCKED**.

The internal product adapter draws correct paused frames on the real editor's
`PlayerNSView`/`AVPlayerLayer`, but continuous playback fails. It is an unaccepted
prototype behind the existing two-part internal gate, not completed image support.
No separate preview clock was adopted. Following the carrier compatibility stop
condition, no further feature implementation was performed after the playback
failure was confirmed. Compilation and bounded comparisons are separate results.

## Repository and exact task files

Branch `feature/subtitles`; HEAD/cached upstream
`800f468460e6e3f604c349a35374ac40dbe04fb3`; main
`44943eadabdf5a37d5242d614e7279813126dfde`. Empty index at preflight.
CLAUDE.md, instruction locations (no applicable AGENTS.md found), ROADMAP/HANDOFF,
prior persistence/import and preview R/G evidence, native preview/planner,
operational model, probe, Metal, audio and overlay paths were inspected.

Existing files changed in this task:

1. `app/Engine/Sources/OnTheFrameEngine/CompositionPlanner.swift`: internal
   preview-only capability marker on `PlannedComposition`; native planning unchanged.
2. `app/Engine/Sources/OnTheFrameEngine/ExportService.swift`: reject that marker
   before destination validation, temporary files or encoding.
3. `app/OnTheFrame/ProjectStore.swift`: internally gated image plan lifecycle,
   generation/session fences, serialized canceled planning, immediate stale-surface
   clearing, and bypass of the video-only interactive still path for images.

New files:

4. `app/Engine/Sources/OnTheFrameEngine/InternalImagePreview.swift`
5. `app/Engine/Sources/OnTheFrameEngine/ImagePreviewMetal.swift`
6. `app/Engine/Tests/OnTheFrameEngineTests/IMGPreview01/CarrierDurationTests.swift`
7. `app/Engine/Tests/OnTheFrameEngineTests/IMGPreview01/ProductImagePreviewTests.swift`
8. `app/diagnostics/IMGPreview02/ProductImagePreviewAppTests.swift`
9. `app/diagnostics/IMGPreview02/run-tests.py`
10. `docs/diagnostics/IMG-PREVIEW-02-GATED-PRODUCT-PREVIEW.md`

Previous uncommitted source, ROADMAP/HANDOFF and diagnostic reports were preserved;
none of their earlier failures or subsequent fixes was rewritten. Original GPU
renderer/lease tests and frozen QA references were not modified in this task.

## Architecture and boundaries

Image-free projects keep the existing native `CompositionPlanner` and AVPlayer
path. The image adapter is selected only when the preexisting `OTF_IMAGE_IMPORT`
compile flag AND `-OTFEnableImageImport` runtime argument enable internal support.
Normal builds still default off. This does not approve public support.

The separate preview planner retains AVPlayer, native audio mix construction and
source-time/silence/gain/fade rules. Its explicit audio-only projection is transient
and never used as persisted/session state, visibility authorization or export input.
Image tracks/duration/frameCount/SourceTiming are not invented in media models.
A generated 16x16, thirty-real-sample timing-only MOV is a composition dependency,
scaled to the actual timeline duration. Its pixels never enter the visual shader
and its reference never enters the catalog/project. Plan duration is checked
against the model. Six-frame truncation or looping is not used.

A new preview-specific Metal layer adapter generalizes the retained ICC 709/sRGB
component-LUT and left-sited NV12 methodology. It does not copy the experimental
XCTest harness or depend on test targets. It supports inverse transforms and
bottom-to-top lanes without treating a transparent image rectangle as opaque.
Aligned opaque video regions copy native Y/UV to preserve raw video identity;
image regions use premultiplied sRGB alpha and the retained 420 quantization method.
The frozen CPU/GPU references remain independent and unchanged.

The current prototype explicitly rejects unsupported canvas/fps, more than eight
simultaneous visual layers, and more than 64 MiB of uploaded image pixels. Existing
8 MiB/2048-pixel/4,194,304-pixel/128 MiB estimated probe admission is unchanged.
These are internal fail-closed limits, not a newly approved public image policy.
No renderer arithmetic beyond the tested cases is claimed validated.

Each image source needs a fresh full probe and identity/descriptor match. A stored
unverified descriptor alone cannot authorize decoding: an existing runtime-validated
URL or the app's resolved current-session source mapping is required. Decode and
upload occur under source access, off the main actor; only owned texture data
survives access release. Missing/changed input leaves project/clip data intact,
clears the player/overlays and reports an explicit preview failure. The live signed
sandbox/reopen/missing-media matrix is not validated here.

A global serial render worker bounds outstanding compositor requests at five.
Epoch invalidation and publication share a lock; pending stale work is canceled.
GPU completion captures retain source/output wrappers; timeout quarantines that
renderer rather than asserting GPU retirement. App generation and project-session
checks reject late planning/seek callbacks. These implementation mechanisms are
not substitutes for the unfinished new-adapter cancellation/drain tests.

The existing AVPlayerItem-bound subtitle/spectrum contract is retained. No
independent clock, animated spectrum, Stage 3C-2 or spectrum export was introduced.
A preview-only capability marker blocks direct ExportService use, independently
of the app's complete-catalog image export guard.

## Preserved failures, corrections and current blocker

All logs use fresh disposable roots. `$REPO` is the repository and `$EVIDENCE` is
`app/selftest-work/img-preview02-20261031-01` beneath it. Build logs/raw evidence
remain ignored local artifacts, not publication files.

- First engine compile: exit 1 from Swift operator whitespace; corrected. The next
  engine build completed, exit 0. Original compile logs remain.
- First frozen comparison: one test failed with five assertions. The test requested
  frame 5 from a five-frame image-only model by reusing a six-frame experiment's
  observation list. It also found unnecessary video color round trips in mixed
  frames 0/5/2/3. The actual model endpoint is exclusive; the test now validates
  actual duration and all requested frames strictly inside it. Unmodified-video
  copy preservation corrected the pixel differences. Assertions were not relaxed.
- Intermediate exact-PTS waits at the same out-of-range frame timed out. Traces
  established model duration 5/30, not a truncated six-frame product timeline.
  Those failed observations and before-correction source copies remain preserved.
- After correction, frozen image-only and mixed native output matched all eleven
  in-range frame hashes and requested PTS. Image-only model has five valid frames;
  mixed has six. This does not prove continuous playback.
- The separate original-carrier duration test stretched real six-frame transport
  to 150 frames with per-frame instructions. Debug and Release passed. It is a
  different bounded setup and does not validate the product candidate below.

**Current real blocker:** the new product candidate accepts exact in-range seeks,
but native playback prefetch requests the project endpoint. The compositor's
half-open instruction containment rejects it with `carrier time/source missing`.
The containment condition fails at the endpoint; source-frame availability after
that short-circuited condition is not established. The trace records completed
GPU/publication for the final valid frame, then the endpoint error. The player
stops advancing and the existing five-second observation deadline fails.

Final Debug 150-frame case: exact composition duration 5 seconds; native seeks
0, 6, 75, 148, 149 and 1 completed with exact PTS. Seeking to frame 145 and playing
stopped at item time 4.840268708, rate 0, timeControlStatus 0, waiting reason none.
Frames through 149/30 were rendered; time 5 generated the endpoint error.
Release stopped at 4.839962917 with the same endpoint error. No larger timeout,
retry-to-pass, placeholder frame publication or independent clock was introduced.
The endpoint error and playback stop are observed; an alternative endpoint policy
has NOT been implemented and causally revalidated.

The actual product app harness reproduced the same failure after all five paused
image-only surface checks and rapid-seek/stale-token checks passed. It reached
`checkpoint playback image-only`, then exited 1. Its end request was 5/30; the
item stopped near the beginning of playback. Mixed product app surface checks
were not reached. Error/cancel traces and strict surface hashes are preserved.

A further final Release failure is separate and unresolved: the unchanged old
`ClockCarrierCompatibilityTests.testNativeCarrierCompatibility` reported
`native displayed PTS/raw mismatch case=mixed-audio frame=5`. Original Debug passed.
Do not reinterpret old PASS evidence as current Release success or guess this
unlogged hash mismatch's cause.

## Actual evidence by requirement

| Requirement | Observed result and boundary |
| --- | --- |
| Opaque PNG | Native output and five actual product paused surfaces matched frozen raw hashes. |
| JPEG / EXIF / general aspect ratio | Code and generated oriented fixture exist; output assertions lie after the playback blocker and were NOT RUN. |
| Transparent PNG over video | Frozen mixed native output raw parity passed; mixed actual product surface NOT RUN. |
| Transparent PNG over image | Full-FHD canonical measurement PASS before playback: 52.90201615587573 dB, maximum/flat error 1, pixels over 3 = 0. Existing >=40 dB / flat <=3 unchanged. |
| Image-only duration / playback | Plan duration 150 frames/5s and exact seeks PASS; continuous playback FAIL. |
| Audio | Existing native mix reused; generated mixed native item tested. Actual new-product audio synchronization NOT established. |
| Start/end / seek | Eleven frozen in-range output identities PASS; end-prefetch handling FAIL. |
| Trim/split/move/delete/undo/redo | Operational engine regressions ran; complete new product preview-after-edit matrix NOT RUN. |
| Save/open preview regeneration | Test code exists after playback; NOT RUN. |
| Missing / unverified images | Fail-closed implementation reviewed; targeted matrix after playback NOT RUN. |
| Session replacement / stale results | Actual app rapid seek/stale-token assertion passed; full new-adapter project replacement matrix NOT RUN. |
| Lease / cancellation | Existing four lease tests and single-new-generation recovery passed in Debug/Release. New adapter's complete controlled in-flight and post-drain matrix NOT reached. |
| Video-only | Actual product surface, six strict frames, rapid seeks and playback PASS in Debug/Release. |
| Subtitle / spectrum | Item binding and layer order passed on image-only/video control; new mixed paused spectrum path NOT reached. No animated spectrum claim. |
| Export separation | Direct preview-plan ExportService rejected before destination modification; disposable sentinel unchanged. App image export guard remained active. |
| Default-off gate | Code review confirms existing compile+runtime gate unchanged. No new normal public activation; fresh default-off manual runtime workflow NOT performed. |

## Final execution results

These are newly executed in this task, not reused IMG-PREVIEW-01R/G PASS counts.

- Debug final selected engine: 121 executed, 120 PASS, 1 FAIL, 0 SKIP, exit 1.
  Failure: new product 150-frame playback timeout.
- Release final selected engine: 120 executed, 118 PASS, 2 FAIL, 0 SKIP, exit 1.
  Failures: new product playback timeout and old mixed-audio frame-5 identity.
- Product app diagnostic compilation: Debug 0 / Release 0. Each image app run
  exited 1 after five strict paused image surfaces and rapid seeks passed, then
  continuous playback timed out. No completed image/mixed group PASS is claimed.
- Separate video-only product control: each configuration 1 PASS, 0 FAIL/SKIP,
  exit 0. These runs are separate from the failing image app cases.
- No host signal crashes or external test process timeouts occurred. Five-second
  assertion deadlines failed normally and are FAIL, never PASS.

Validation scope mistake retained explicitly: the Debug class-level selection
included both `InputCompatibilityTests.testNonThirtySourcesEditExportAndPreview`
and `testTimedSourcesUnchanged`, which perform generated-video exports. They
passed but were outside the intended bounded scope. After Debug completed, the
parent orchestration was paused while its child app harness finished normally.
No running build/test was killed. The scheduling parent then exited 143. A new
anchored Release filter excluded the first method but mistakenly still included
`testTimedSourcesUnchanged`, so one generated-video export test also ran in Release.
This accounts for the 121 versus 120 count difference, not an additional SKIP.
The two Debug tests and one Release test used freshly created UUID output folders;
their existing teardown deleted same-run output files. Thus their **logs**, not
those temporary exported payloads, remain available. No owner output or historical
experiment artifact was deleted. No additional tests were started after this second
scope error was identified. Any future selection must exclude BOTH export methods,
or explicitly select only `testProbeAnalysesNonThirtyTiming` from that class.
No GPU90 benchmark or image export was run. Do not interpret this task as having
executed no export workloads; the three unintended video-export test executions
are an explicit validation limitation.

Exact commands, configuration flags, exit codes and bounded time limits are in
`$EVIDENCE/final-tests.py`, `finish-validation.py` and `final-results.json`.
SwiftPM used the existing approved build cache; Release enabled testability.
Original GPU artifact budgets/fixtures and probe corruption inputs were retained.
App compiler/linker commands are in each diagnostic directory's `command.txt`.
No special diagnostic executable is counted as normal signed-app validation.

## Resume boundary

Do not adopt or publish this as completed preview support. Recommended next task:
**bounded native compositor end-of-item request recovery**. Reproduce the request
at exactly duration, determine the supported native completion/cancellation policy,
and preserve half-open visible clip identity without returning a fatal endpoint
error or weakening raw/PTS assertions. Compare native video-only carrier behavior,
repeat exact real-surface play/pause/replay at five- and 150-frame lengths, and
separately diagnose the old Release mixed-audio frame-5 failure. Continue the JPEG,
EXIF, edits, reopen, missing-image and controlled resource-drain matrix only after
that compatibility gate passes. A separate preview clock is not authorized/adopted.

Owner Mac manual validation is still required after correction: launch the normal
internal build with its runtime opt-in, use disposable JPEG/opaque/alpha PNG and
video/audio fixtures, verify import/seek/play/replay and lane/transform boundaries,
edit/undo/redo, save/open/missing source, subtitle/paused-spectrum layering, and
export/default-off fences. Do not ask the owner to accept this failing prototype
as a completed workflow; native panel/sandbox and perceptual audio checks remain
separate from automated diagnostic surfaces.

## Normal signed internal app build — not completed

A normal Xcode `OnTheFrame` target Debug build, with `DEBUG OTF_IMAGE_IMPORT`, was
attempted using the existing approved DerivedData and a separate internal output
name. It reached Swift compilation/module emission but exceeded the recorded
180-second bound. The task-owned process group received SIGINT, Xcode recorded
`BUILD INTERRUPTED` and exited **75**. Its interruption diagnostics include an
Xcode stack; this is not an app test-host signal crash. No remaining task compiler
or app process was observed afterward. No second build was started.

Therefore normal signed internal build, effective code-signature/entitlements
verification and normal-app launch are **NOT VALIDATED**. Codesign follow-up was
not run because the build did not succeed. Source entitlements declare App Sandbox,
user-selected read/write and app-scope bookmarks; a source plist is not proof of
effective signed entitlements. The two successfully compiled diagnostic hosts are
not substitutes for this normal build result.

**Preservation exception:** using the same DerivedData with a changed product
output directory triggered Xcode stale-product pruning. The log names the prior
`DerivedData/Build/Products/IMGPreview01-Normal-Debug/OnTheFrame.app`, engine object
and module products as removed; that prior app path is now absent. The preflight
inventory did not hash ignored build products, so their exact previous content
cannot be reconstructed/verified from it. No manual clean/delete command was run,
but it would be incorrect to claim all previous build artifacts were preserved.
This is a build-output preservation limitation caused by the build invocation,
not an owner media/project/output deletion.

The surviving older `SP3B1Baseline` Debug app was copied to the task's ignored
`retained-prior-SP3B1-Debug.app`; all eight file/symlink hashes were verified equal
and source unchanged. This preserves a prior Debug app outside future DerivedData
pruning, **not** a recovery of the removed IMG-PREVIEW-01 app and **not** a current
image-preview build. `preserved-debug-backup.json` records the verification.
Historical source, reports, original failure logs, raw experiment evidence and
recovery refs remain preserved. No cache deletion, Git cleanup, staging, commit,
push, owner app termination or owner data operation was performed.

## Final checks and Git state

`git diff --check` returned 0. All ten task source/test/report files passed a bounded
text/personal-path/obvious-token/private-key scan; Python driver syntax parsed.
No binary/generated media is among these ten task files. This is not an exhaustive
secret audit. All preexisting nonignored source/document/user-file hashes matched
preflight except the three authorized existing files above. Protected refs matched
preflight (automatic Codex refs excluded). HEAD/upstream/main stayed at baseline,
index is empty, and prior modified/untracked work remains uncommitted. This is not
a clean working tree. No staging, commit, push or Git history operation occurred.

Final allocated `du -sk`: selftest-work 3,737,680 KiB; app/.build 1,683,360 KiB;
experiments 1,683,992 KiB; existing developer build root 2,340,880 KiB. Total
9,445,912 KiB (about 9.01 GiB), below the 20 GiB managed budget. Tiny task-generated
clock MOVs under temporary directories are additional to this subtotal. All known
source, diagnostic, first-failure and recovery evidence is preserved, subject to
the explicitly recorded Xcode build-product pruning and same-run test teardown.
No owner media/project/output, public image activation, image export, format-9
schema, Stage 3C-2 or spectrum export change occurred.
