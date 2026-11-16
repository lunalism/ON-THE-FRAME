# IMG-PREVIEW-01R — Strict paused-surface observation recovery

2026-10-31 Asia/Seoul.
STATUS: HARNESS CORRECTED (surface observation only).
Separate existing Debug generation-recovery regression FAIL remains unresolved.
This is NOT completion or production adoption of image preview.

## Baseline and preservation

Repository `$REPO`, feature/subtitles, HEAD/cached upstream
800f468460e6e3f604c349a35374ac40dbe04fb3; main
44943eadabdf5a37d5242d614e7279813126dfde. Index was empty, with the existing
IMG-PERSIST/IMPORT/PREVIEW working tree intact. CLAUDE.md, applicable instruction
locations (no AGENTS.md found), ROADMAP/HANDOFF, prior preview report, preserved
failure and harness/planner/player/overlay/generation code were inspected.

The old failure `actual paused player surface raw frame 1` and its compile/run
logs remain byte-preserved. It lacked hashes, so its individual historical frame
cannot be retroactively identified. No missing assertion is treated as a pass.
Fresh ignored evidence root: `$REPO/app/selftest-work/img-preview01r-20261031-01`
(EVIDENCE). Separate direct selftest-work children contain bounded generation
artifacts, as required by the existing artifact-boundary predicate. All original
GPU/probe/model/codec/source/owner files remain unchanged.

## Exact task file set

Modified:
- app/diagnostics/IMGPreview01/ClockCarrierAppTests.swift — bounded telemetry,
  equivalent native video-only control, and precise readiness observation before
  the original exact raw-frame assertion.
- app/diagnostics/IMGPreview01/run-tests.py — Release-only test-support link repair;
  no application runtime or assertion suppression.

New:
- docs/diagnostics/IMG-PREVIEW-01R-SURFACE-OBSERVATION.md — this report.

Production ProjectStore/ContentView, preview/render scheduler, image model/schema,
Metal arithmetic/lease implementation and original engine tests were NOT modified.
Old IMG-PREVIEW-01 diagnostics are historical and were not rewritten.

## Initial reproduction and video-only control

One initial instrumented Debug execution preserved the old immediate comparison.
It captured the first surface/hash BEFORE telemetry polling; diagnostic convergence
could not turn that original comparison into PASS. The first frame1 observation
now matched. The same strict observation failed at mixed-audio frame2 instead:

| Value | Observed |
| --- | --- |
| Requested time / item time | 2/30 seconds |
| Expected CPU hash | 4ea33d39d0dd2a84afa24c2559c644c095cdc58f13b2013022008522490ffad2 |
| Video output first hash | same exact expected hash |
| Video output PTS | 2/30 |
| First displayed surface hash | 92b3a26d5007009a7a5bc82b36389cd5566798ac5a3826b1476effd65cf2c78d |
| Previous surface / matching reference | same first surface hash / frame1 |
| Seek token | 14 |
| generation / appliedGeneration | 2 / 2 |
| confirmedFrame | 2 |
| Item status / timeControlStatus | readyToPlay / paused |
| Layer isReadyForDisplay | true |
| Subsequent displayed surface | exact expected frame2 hash |

Surface and video output were both 420v (875704438), 1920x1080,
709 primaries/transfer/matrix, Left top chroma. At the next recorded sample,
16.732ms after the first surface timestamp, the layer already had the correct
hash; completion of the convergence check was recorded at 18.072ms. These are
sampled observation times including read/hash overhead, not exact physical scanout
latency or a performance guarantee. Seek-completion timing is observation of the
existing confirmedFrame marker polled at <=10ms, not a new callback timestamp.

The first Debug run exited1, preserving that FAIL. image-only had passed all six
strict comparisons; mixed failed at frame2. The equivalent video-only run used the
same window, actual PlayerNSView/AVPlayerLayer, seeks and observation point, with
bottom.mov directly as the native item and reader-derived expected hashes. It
passed all six frames and overlay/token checks, exit0. No previous-frame surface
was observed in this particular control run; it does not establish that plain video
can never show presentation latency.

Files: initial-debug/run.log, initial-debug/fixtures/surface-observations.jsonl,
video-only-initial.log and video-only-initial-fixtures/surface-observations.jsonl.
The historical frame1 failure did NOT reproduce at frame1 in this initial run;
its unsupported old details remain unknown. The same nonnil-readiness assumption
was demonstrably invalid in the newly captured mixed frame2 transition.

## Confirmed mechanism and smallest correction

Confirmed: a successful seek/current item time, confirmedFrame and a NONNIL
AVPlayerLayer displayed buffer do not prove that this buffer is the newly requested
frame. Here it was exactly the preceding frame and then converged without a new
seek or content change. This identifies delayed layer presentation plus premature
harness observation. Persistent wrong-frame selection, permanent color conversion
or corrupt carrier output are not supported explanations for this captured event:
the proxy was already exact and the surface became bit-identical with unchanged
format/color tags. This does not prove every possible production transition safe.

Apple documents the distinction for video compositions and the separate
[seekingWaitsForVideoCompositionRendering property](https://developer.apple.com/documentation/avfoundation/avplayeritem/seekingwaitsforvideocompositionrendering).
The current item factory leaves that property at its default; corrected telemetry
records false. No player property, production timing policy or overlay identity
contract was changed. Changing that property in product code is NOT this fix.

Harness correction: after the same seek-completion marker, observe the actual
surface until its raw Y/UV hash EXACTLY equals the unchanged CPU reference, within
the existing five-second bound. Throughout, require the same native item, seek
 token, generation/appliedGeneration and confirmed frame. Identity changes fail;
a permanently wrong hash times out. Then execute the original exact-hash assertion.
No pixel tolerance, reference amendment, assertion removal, visual approximation,
skip, fixed sleep-to-assume-success or capability bypass was introduced.

OTF_SURFACE_STRICT_INITIAL=1 retains the old immediate comparison for diagnosis;
OTF_SURFACE_DIAG=1 enables bounded post-observation logging. Default validation
uses the corrected exact-readiness observation. Telemetry is confined to this
isolated harness: expected/actual/proxy hashes, format/size/color tags, requested
and item times, seek/generation, status, observation timestamps and previous-frame
matches. No raw frames or owner file content are logged.

## Release-only diagnostic linker correction

The first Release app link failed; no Release app test ran in that attempt.
The old runner excluded test_entry_point.o to avoid a duplicate C main. Under
Release optimization that object ALSO contains cross-file Swift specializations
and default-argument support used by other test objects. Excluding it produced
undefined symbols, not a product/rendering compilation defect.

The driver now retains this support object in Release by using Apple nmedit on a
NEW evidence-owned output copy, localizing ONLY its unused global `_main`. The
original object SHA-256 is checked unchanged, and global-symbol sets must differ
only by `_main`. No multiply-defined suppression, source rewrite, assertion change
or test binary modification occurs. Debug linkage is unchanged. The corrected
Release app compiled/linked and executed normally. The original link failure and
localization identity record are preserved under corrected-release and
corrected-release-02 respectively.

## Newly executed validation results

| Check | Debug | Release |
| --- | --- | --- |
| Initial instrumented immediate surface assertion | FAIL at mixed frame2; compile0/process1 | NOT RUN (Debug-only initial reproduction) |
| Initial equivalent video-only | PASS, process0 | NOT RUN as an initial reproduction |
| Corrected original image-only + mixed app checks | 2 groups PASS, compile/process/driver0 | 2 groups PASS after link repair, compile/process/driver0 |
| Corrected equivalent video-only | 1 group PASS, process0 | 1 group PASS, process0 |
| Native carrier engine compatibility | 1 PASS, 0 FAIL/SKIP | 1 PASS, 0 FAIL/SKIP |
| Existing lease/cancellation tests | 4 PASS, 0 FAIL/SKIP | 4 PASS, 0 FAIL/SKIP |
| Existing generation-recovery test | FAIL twice, same aggregate guard | 1 PASS, 0 FAIL/SKIP |

Corrected app checks preserve exact surface assertions for frames0–5, native item
subtitle binding, native video/image < spectrum < subtitle layer order, paused
spectrum visibility and contents for the mixed case, old seek-token rejection,
play/pause, image model invariants and image export blocking. Current playback
spectrum remains hidden as before; Stage3C-2 was not implemented. AVPlayerLayer's
paused-buffer API is checked, not a screen capture or whole-display color proof.

Debug generation details: initial combined run was 4 PASS/1 FAIL, exit1. A single
quiet source-unchanged rerun with carrier was 1 carrier PASS/1 generation FAIL,
exit1. Both failed existing GenerationRecoveryTests.swift:49 with
`late completion/stale/drain`. That is a compound guard; the failed subcondition
was not logged, so no cause (GPU status, resource state, byte visibility, etc.) is
invented. New-generation pixel/quality checks preceding it ran; this does not
make the final drain guard pass. The engine test source was not modified.
Release's corresponding six-test selection (carrier + four lease + generation)
passed, exit0. The repeated Debug failure remains OPEN, not dismissed as noise or
resolved by the Release pass. It prevents a blanket compatibility/resource PASS.

New carrier/cancellation tests are bounded existing six-frame and single-new-request
checks. No 90-frame benchmark, unrelated expensive suite or export was run. No
ordinary SKIPs, signal crashes or test timeouts occurred. Previous IMG-IMPORT and
IMG-PREVIEW passes are background only and are not counted as new executions.

## Evidence and reproducibility

EVIDENCE contains before.json with baseline hashes/refs, original harness copy,
initial-results.json, corrected-debug-results.json, release-results.json (including
first failed link), release-02-results.json, cancellation-debug.log,
debug-carrier-generation-final.log, release-engine.log and summary.json.

App commands use the existing runner with <debug|release> and NEW output path.
OTF_CLOCK_SOURCE is the generated POC1R reader fixture directory, OTF_CLOCK_AUDIO
is the existing generated WAV. A unique OTFLayoutSuite isolates preferences.
OTF_SURFACE_MODE=video-only selects the control. Release requires matching engine
and test objects compiled with -enable-testing/-DOTF_PROTO_RELEASE.

Engine filter: ClockCarrierCompatibilityTests|InFlightLeaseTests|GenerationRecoveryTests.
Debug quiet rerun selected carrier|generation only. OTF_GPU02A=1 enables the four
lease tests; GPU02E uses new direct children of app/selftest-work and the existing
managed APFS developer root, keeping original artifact accounting checks intact.
All original fixture files, first-failure evidence, GPU sources and recovery refs
were preserved. No build products were deleted; existing caches were reused.

## Remaining work and final boundary

HARNESS CORRECTED describes only the demonstrated surface observation defect and
Release diagnostic linkage. It is NOT a completed IMG-PREVIEW-01 preview, signed-app
validation, native panel pass, new synchronization architecture, or all-green
resource gate. Historical frame1's missing hashes cannot be reconstructed.

Recommended next bounded task: instrument the failing compound Debug
GenerationRecoveryTests guard to capture each state plus Metal command status/error
and release times, without changing its assertions or GPU state machine. Resolve
that before adopting the carrier path as product preview. Product item-time versus
presentation policy, transient overlay behavior, general image geometry/EXIF/missing
media, signed app and owner workflow still require explicit validation. No proposed
new native property setting or independent clock was adopted.

Git remains on expected branch/HEAD/upstream/main with empty index and all prior
uncommitted work. Only the two diagnostic harness files above changed and this
report was added. No normal public image activation, export, format migration,
Stage3C-2/spectrum changes, owner data writes, staging, commit, push or destructive
Git operation. Final privacy/hash/ref/process checks are recorded in summary.json.
