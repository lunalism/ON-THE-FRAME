# IMG-PREVIEW-01 — Native clock carrier compatibility checkpoint

2026-10-30 Asia/Tokyo.
STATUS: PARTIAL — native output proxy passed; actual paused surface assertion failed.
Owner requested a safe stop. No further implementation or long tests were started.

## 1. Baseline and approved decision

`$REPO`, feature/subtitles, HEAD/cached upstream
800f468460e6e3f604c349a35374ac40dbe04fb3; main
44943eadabdf5a37d5242d614e7279813126dfde. Index empty. CLAUDE.md and instruction
locations, ROADMAP/HANDOFF, image import/probe/model/persistence evidence and
PlayerNSView/InteractivePreview/planner/Metal/overlay contracts were inspected.
No applicable AGENTS.md found. Prior IMG-IMPORT-01 hashes matched before work.

Initial compatibility review found that the current image planner intentionally
rejects images, source-free temporal Timeline(durationFrames:600) is empty and
rejected, and subtitle/paused-spectrum presentation is tied to AVPlayerItem.
Debug/Release executable clock-boundary diagnostic confirmed those current API
rejections (compile/run0), not impossibility of a new transport.

The owner then explicitly chose Option 1: preserve native AVPlayer and evaluate a
temporary timing-only clock carrier BEFORE adopting production preview architecture.
Independent clock Option 2 was not implemented. Following the actual surface
failure below and the owner's stop request, no further implementation phase or
long-running test was started. No generic preview PASS is claimed.

## 2. Exact task changes

Modified:
- app/OnTheFrame/ProjectStore.swift — installClockCompatibilityForTest, compiled
  ONLY with OTF_PREVIEW_COMPAT_TESTS. Installs an experimental native item/model,
  advances generation/seek token and binds existing subtitle/spectrum machinery.
  It is not installed by normal or IMG-IMPORT-01 builds and does not change normal
  preview eligibility, renderer/export policy or normal project loading.
- app/OnTheFrame/ContentView.swift — exposes existing subtitle test accessors under
  that same isolated test flag in addition to DEBUG; no overlay timing logic change.

New:
- app/Engine/Tests/OnTheFrameEngineTests/IMGPreview01/ClockCarrierCompatibilityTests.swift
- app/diagnostics/IMGPreview01/ClockCarrierAppTests.swift
- app/diagnostics/IMGPreview01/run-tests.py
- docs/diagnostics/IMG-PREVIEW-01-CLOCK-CARRIER-COMPATIBILITY.md

Six task paths total. Previous uncommitted import/persistence work, diagnostic
reports and raw evidence are preserved. ROADMAP/HANDOFF were not changed here:
normal image preview is still unsupported, matching their current implementation
boundary. This is NOT production preview integration.

## 3. Bounded compatibility architecture

The existing GMNV12 Metal experiment is fixed FHD NV12, one PNG, optional translated
upper video and six phases. It is not a general product compositor. The new
TEST-TARGET AVVideoCompositing adapter uses it only for that declared geometry.
One serial render worker admits at most five outstanding requests; epoch checks
before/after rendering cancel stale publication. Existing completion-driven GPU
leases retain resources until observed completion. No GPU arithmetic, lease book,
QA reference, production planner or overlay synchronization implementation changed.

Each plan copies the existing generated six-sample top.mov to a fresh test-owned
transport-only.mov. These are REAL carrier samples, used as a required timing
track, NEVER passed to the image/video renderer. For image-only content the visual
bottom is a separately allocated video-range black buffer. Mixed content uses the
actual bottom/top source frames, not the carrier. Input files are generated prior
fixtures in app/selftest-work/img-b-poc1r-20261028-01/reader; audio is the generated
app/.build/test-work/fixtures/aud-wav48s.wav. No owner media was used.

The operational model contains only true image/video/audio sources. Image sourceIn
is zero, source duration/frameCount/SourceTiming/video track are not invented.
No carrier reference/bookmark/path enters ProjectPersistence model state. Native
transport duration is six frames (0.2s). Source AVURLAssets are retained explicitly.
GPU/reference output tests cover:
- image-only image visibility [1,5), black outside;
- mixed bottom video [0,6), image [1,5), upper video [2,4), real audio [0,6);
- shifted/trimmed image-only [2,6), plus operational split retaining sourceIn0.

The adapter is deliberately not general: an upper video outside the image interval
is rejected by this fixed experiment, not silently misrendered. No general JPEG,
EXIF/transform/cache/reopen/missing-image matrix is delivered by this experiment.
Normal image import/probe/export fences remain in place.

## 4. Newly executed tests and exact results

Existing matching baseline binaries were rerun with fresh generated fixtures:

| Check | Debug | Release |
| --- | --- | --- |
| Engine bounded existing regression | 105 PASS, 0 FAIL/SKIP, exit0 | 105 PASS, 0 FAIL/SKIP, exit0 |
| Existing import app host | 7 groups PASS + 1 default-off PASS, exit0 | same, exit0 |
| Current API clock-boundary diagnostic | compile0/run0, expected rejections | compile0/run0, expected rejections |

Baseline engine command: swift test -c <configuration> --skip-build --package-path
app/Engine --scratch-path "$BUILD_ROOT" --filter <prior 105-case bounded filter>.
Fresh OTF_MODEL03_RUN/OTF_STILL_PROBE_RUN and both preserved corruption fixture
variables were supplied. No SKIPs silently counted as PASS. App baseline used
existing source-matched IMG-IMPORT-01 app-final binaries with fresh fixtures and
unique layout suites; those executions were not new app compilations.

New native carrier Debug test:
- first compile exit1: invalid integer Set subscript, corrected to first;
- second compile exit1: asynchronous predicate required escaping lifetime,
  corrected without removing assertions;
- final compile succeeded, test 1 PASS/0 FAIL/0 SKIP, exit0, 12.523 seconds.
- Three cases above, each six non-monotonic seeks [0,5,1,4,2,3]. Native
  AVPlayerItemVideoOutput PTS exactly matched n/30 and raw Y/UV SHA-256 matched
  the unchanged CPU renderer. Playback advanced through frame4 and paused.
- Mixed composition had one real audio track; no physical audio/speaker sync
  measurement was made. No proof of actual continuously presented playback frames.
- Per-render observed GPU active/pending lease counts returned to zero.
  No controlled in-flight cancellation race was exercised in this new adapter;
  logged stale-cancelled count was zero. Do not infer new race coverage from
  previous GMLeaseBook tests or from non-monotonic seeks alone.

Evidence: native-carrier-debug-first.log, native-carrier-debug-02.log,
native-carrier-debug-03.log and native-carrier-debug-03/observations.json.
New carrier Release compilation/execution was NOT RUN after the later blocker.
No 90-frame benchmark, media export or independent clock phase ran.

## 5. First actual application-surface failure — preserved and unresolved

The isolated host compiles actual app sources with alternate test main plus
OTF_PREVIEW_COMPAT_TESTS, OTF_PERSIST_TESTS and unique layout suite. It links the
experimental test module/SDK XCTest support; it is NOT a signed normal application.
It creates an actual PlayerNSView/AVPlayerLayer in its own disposable NSWindow.
It does not show or accept native Open/Save/permission dialogs.

First link attempt exited1 due to missing XCTestSwiftSupport library search path;
the SDK path/rpath was added and first failure log retained. Second compilation
exited0, but the host process exited1 with:

`CLOCK APP FAIL: Failure(message: "actual paused player surface raw frame 1")`

It reached the image-only plan, native ready item/subtitle-item binding, existing
layer order (native video/image < spectrum < subtitle), and confirmed paused seek
identity, then compared PlayerNSView.playerLayer.displayedPixelBuffer() with the
CPU expected hash. Frame0 passed; frame1 comparison failed. The mixed app case,
actual spectrum pixels, stale-callback test and later playback checks were NOT
reached. Earlier setup assertions passing do not make the whole app test PASS.

The first failure did not record actual/expected hashes or native presentation
timestamps, so the cause is UNCONFIRMED. An old displayed buffer immediately after
seek completion, a format/color discrepancy, and another rendering/lifecycle issue
are hypotheses only. AVPlayerItemVideoOutput proxy success is not equivalent to
this actual layer presentation check. It is not yet proven carrier-specific or an
independent production defect. No assertion, overlay identity guard or timeout
was weakened to conceal it. No rerun after failure was started before the owner's
stop request; no separate preview clock was substituted.

First link log: native-app-debug-first/compile.log.
Actual failure: native-app-debug-02/run.log; compiler log and driver show compile0,
process1. No signal crash or test-host timeout was observed. Window/player cleanup
was in the host's defer; original owner apps were not terminated.
New native app Release test was NOT RUN. No new signed-preview app validation.

## 6. Normal application build — independent result

Normal Xcode Debug build, no image/preview flags, existing internal APFS DerivedData,
separate CONFIGURATION_BUILD_DIR=.../IMGPreview01-Normal-Debug:
BUILD SUCCEEDED, actual xcodebuild exit0. Exact arguments/log/result are retained.
This completed before the later compatibility-only helper/accessor additions;
a final normal rebuild after those additions was NOT RUN. Their compile flag is
absent from normal builds, but that fact is not presented as a later build execution.
No cache reset/override, old product deletion, global signing/config change or
special signed diagnostic bundle was used to claim this normal build result.

## 7. Remaining boundaries and exact safe resume sequence

Production preview integration is not adopted. Public image support and image
export remain disabled; existing subtitle/paused-spectrum contract is unchanged.
No Stage3C-2, spectrum export, format9 schema or image admission policy changes.

1. Read this report and EVIDENCE/summary.json. Verify feature/subtitles, expected
   HEAD/upstream/main, index and current file hashes; preserve all existing changes,
   failure logs, generated carrier copies and recovery refs. Always use NEW output
   roots; current plan construction refuses an existing carrier file through copyItem.
2. Diagnose ONLY native-app-debug-02's first surface mismatch. Add telemetry for
   requested/confirmed frame, native item time, seek token, generation/appliedGeneration,
   actual displayed-buffer pixel format/hash and expected hash. Also compare the
   unchanged video-only path under the same observation timing to distinguish an
   existing native presentation delay from a carrier-specific issue. Do not relax
   assertions or redefine seek completion/overlay authority without evidence.
3. Run one bounded Debug reproduction with generated fixtures only. Record whether
   the actual layer is stale after the confirmed seek, and whether it subsequently
   converges; do not equate a nonnil buffer with proof of the requested frame.
   Keep existing AVPlayerItem/seekToken identity checks.
4. If there is an observable carrier synchronization/lifetime/resource problem,
   report it and stop before any independent-clock architecture. Option1 approval
   is a bounded evaluation approval, not approval to silently switch to Option2.
5. Only after resolving the Debug blocker: compile/test native carrier Release
   with -enable-testing/-DOTF_PROTO_RELEASE, then the app host Release. The latter
   depends on the matching new OnTheFrameEngineTests module/objects. Revalidate
   actual subtitle/spectrum layering, stale callbacks, GPU retirement, normal build
   and source/data preservation before proposing production integration.

Do not adopt the six-phase test compositor as a general product renderer. Full
JPEG/PNG/EXIF/alpha/geometry/mixed-stack validation, signed app/native panels,
project reopen, missing/unverified image handling, continuous frame presentation
and owner workflow are still outstanding. Proposed next task is the isolated
Debug paused-surface mismatch diagnosis, not a new preview clock or image export.

## 8. Git/data safety and stop state

No staging/commit/push/reset/clean/discard/branch switch/history rewrite. All prior
uncommitted work and original logs/evidence/recovery refs preserved. Only the six
listed paths differ from this task's preflight; unrelated files unchanged by hash.
Raw evidence stays ignored in EVIDENCE. No owner image/project/output changes,
normal public feature activation, image export or production GPU integration.
Final git diff --check/privacy/preservation results and exact hashes are recorded
in summary.json. The work is intentionally left uncommitted for safe resumption.
