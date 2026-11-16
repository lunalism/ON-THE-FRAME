# IMG-PREVIEW-02R — End-of-timeline recovery

2026-10-31, Asia/Seoul. **STATUS: PARTIAL** — end/replay runtime gate validated; normal signed build
was stopped for abnormal compiler resource usage. This checkpoint does not complete or
publicly activate still-image preview.

## Baseline and scope

Repository `$REPO`, branch `feature/subtitles`, HEAD/cached upstream
`800f468460e6e3f604c349a35374ac40dbe04fb3`; main
`44943eadabdf5a37d5242d614e7279813126dfde`. Index empty. CLAUDE.md and applicable
instruction locations, the IMG-PREVIEW-02 report, planner/export boundary, Metal
ownership, product lifecycle, carrier/product tests and preserved failures were
reviewed. No applicable AGENTS.md was found.

`$EVIDENCE` denotes `$REPO/app/selftest-work/img-preview02r-20261031-01`.
`$BUILD_ROOT` is `$HOME/Library/Developer/ON-THE-FRAME`; its `IMG1A-build`
child is the existing SwiftPM cache. All runs used new disposable roots and generated fixtures. Previous source,
reports, failure logs and recovery refs remain separate; the historical
IMG-PREVIEW-02 BLOCKED report was not rewritten to conceal failures.

Modified existing files:

- `app/Engine/Sources/OnTheFrameEngine/InternalImagePreview.swift`: bake exact
  project end into instructions, distinguish endpoint prefetch from visible
  intervals, and cancel only the precise terminal request; independent diagnostics.
- `app/OnTheFrame/ProjectStore.swift`: only `OTF_PREVIEW_COMPAT_TESTS`-conditional
  prepared-plan gate and stale-drop counter for deterministic replacement testing.
  Normal production lifecycle behavior is not changed by these test hooks.
- `app/Engine/Tests/OnTheFrameEngineTests/IMGPreview01/ClockCarrierCompatibilityTests.swift`:
  initial/final PTS/hash/epoch telemetry and exact-PTS readiness within the same
  original five-second budget; original strict PTS/raw assertions retained.
- `app/Engine/Tests/OnTheFrameEngineTests/IMGPreview01/ProductImagePreviewTests.swift`:
  original 150-frame reproduction instrumentation only (native end notification,
  source/carrier durations and last sampled output).

New files:

- `app/Engine/Tests/OnTheFrameEngineTests/IMGPreview02R/EndTimelinePlaybackTests.swift`
- `app/diagnostics/IMGPreview02R/EndTimelineAppTests.swift`
- `app/diagnostics/IMGPreview02R/run-tests.py`
- `docs/diagnostics/IMG-PREVIEW-02R-END-OF-TIMELINE.md`

Eight task files total. ImagePreviewMetal arithmetic/ownership, the existing lease
implementation, CompositionPlanner, ExportService, Media/Timeline/format-9 schema,
subtitle/spectrum logic, ROADMAP/HANDOFF and previous diagnostics were not edited
in this task. No independent clock or new feature policy was introduced.

## Original 150-frame failure reproduced before correction

One newly instrumented original Debug test failed, exit 1, 7.884 seconds, normal
host exit. Original fixture: 64x36 opaque blue PNG on [0,150), alpha PNG on [1,149),
FHD 30fps timeline, duration exactly 150/30 = 5 seconds. It uses the same original
fixture generator and test method, not a substitute shortened timeline.

`original-debug-repro/matrix/lifecycle.json` independently records:

- Carrier source track: 16x16, duration 1 second (30 real samples).
- Carrier composition track and project: both exactly 5 seconds.
- Final visible interval: [149/30,150/30).
- Last valid GPU request: 149/30, inRange=true, carrierPresent=true, published.
- Next native request: exactly 150/30, inRange=false, **carrierPresent=true**.
- It was finished with `carrier time/source missing`, despite carrier availability.
- Player then stopped at 4.840970874, rate 0, timeControlStatus 0, ready item status
  1, item.error absent; no didPlayToEnd notification arrived.

The last explicitly sampled video-output buffer in that original test was frame 1
because its seek order ends at frame 1 before playback. The GPU log identifies the
last valid composed frame as 149. Neither is mislabeled an AVPlayerLayer capture;
actual final AVPlayerLayer identity is verified by the product tests below.

The former combined guard conflated a visible-frame half-open range requirement
with native endpoint scheduling. This was a boundary-classification defect, not
missing carrier data or a fabricated image source-duration issue. The first
failure and instrumented-before-fix source remain preserved.

## Minimal endpoint rule and causal validation

Instructions now contain immutable `projectEnd`, derived from the real Timeline.

1. Numeric time inside the instruction's half-open interval: render normally,
   requiring the actual carrier/source inputs exactly as before.
2. Time exactly equal to projectEnd **and** instruction.end exactly projectEnd:
   finishCancelledRequest once; publish no frame and submit no GPU work.
3. Other invalid/out-of-range times: retain fail-closed error behavior. Negative,
   invalid CMTime, past-end and an inner segment's end are not mapped to the last
   frame. Equivalent rational representations of the exact end are recognized.

The duration, last visible interval, model frame counts/source timing and shader
are unchanged. This is an adapter-specific rule tested against observed native
prefetch, not a claim that every AVFoundation version always requests the endpoint.
Apple documents the request's [cancellation completion API](https://developer.apple.com/documentation/avfoundation/avasynchronousvideocompositionrequest/finishcancelledrequest%28%29);
the safety of this exact-end classification is established by the bounded runs.

The original previously failing Debug test passed immediately after this correction,
exit 0, 3.295 seconds. That original test pauses at frame 149 and therefore is not
used as proof of normal completion. Independent focused tests subsequently ran
full 0-to-5s playback and replay, observing actual native end notifications and
exact currentTime 5. This confirms the former fatal endpoint completion was causal
in the reproduced stall, rather than merely correlated with it.

## Release mixed-audio frame 5 — independent diagnosis

Three bounded instrumented original-readiness Release runs: 1 PASS and 2 FAIL,
exit codes 0/1/1. These deliberately retained the original first-non-nil observation
and strict assertion. Both failures captured:

- Requested/item time: 5/30 = 0.16666666666666666; observed output PTS: 0.
- Expected frame-5 raw SHA-256:
  `b7249744d2076cf57ad9a7f875df90880d498ca99110cdab0a383dcae5a91add`.
- Actual raw SHA-256:
  `8ac95d352569416d375313b76a3ca9485c231041dc669114383c934b5a388dc5`,
  exactly the preceding frame-0 identity.
- Test seek sequence token 2, isolated item identity mixed-audio. At that initial
  observation the compositor log contained completed frame 0 only; frame 5 had
  not yet been supplied. Actual compositor cancellation epoch and completion hash
  are logged independently. This is not evidence of a wrongly rendered frame 5.

The harness now requires output PTS == requested PTS before running the unchanged
raw hash assertion. Initial non-nil evidence is still recorded, and an explicit
`OTF_CLOCK_STRICT_INITIAL=1` preserves the prior immediate-assertion mode. It does
not wait for a desired raw hash to excuse a wrong current frame. One deadline of
five seconds begins at the same observation point; no retry-to-pass or timeout
increase was used. Finite observed recurrence 2/3 is not a universal failure rate.

In a corrected passing Debug run, the same frame-5 check captured initial PTS 0 /
frame-0 hash, followed by exact PTS 5/30 / expected frame-5 hash; compositor
completion also had the correct frame-5 hash. Corrected Release and separate actual
legacy mixed AVPlayerLayer/output controls passed. Product-surface records contain
actual ProjectStore generation and seekToken, distinct from the native unit's
sequence/item identity and compositor epoch. No overlay synchronization contract
or production video scheduler was changed to resolve this harness issue.

## Newly executed final runtime checks

| Final selection | Debug | Release |
| --- | --- | --- |
| Explicitly anchored engine regression | 75 PASS, 0 FAIL/SKIP, exit 0 | 75 PASS, 0 FAIL/SKIP, exit 0 |
| Real product surface groups | 3 PASS, 0 FAIL/SKIP, compile/run 0 | 3 PASS, 0 FAIL/SKIP, compile/run 0 |
| Additional native audio-range confirmation | 1 PASS, exit 0 | 1 PASS, exit 0 |
| Video-only actual product control | 1 PASS after fixture correction | 1 PASS, exit 0 |
| Legacy mixed actual surface/output control | 1 PASS, exit 0 | 1 PASS, exit 0 |

After the 75-case selections, an additional explicit native audio assertion was
added and only the affected mixed case rerun once per configuration (both PASS).
It verified hasAudio, a nonnil audioMix and an actual native audio track spanning
exactly [0,5] seconds; then repeated full playback/end/replay and drain. These
assertion-only additions do not change product behavior. No physical audio or
sample-level synchronization measurement is claimed.

The three product groups are image-only 150 frames, mixed image/video/audio 150
frames, and the retained six-frame mixed source/subtitle/paused-spectrum case.
They invoke actual ProjectStore.timelineChanged, install its product adapter,
and assert actual PlayerNSView/AVPlayerLayer raw identity; they do not merely
inject a successful experimental item and call it product integration.

Focused 150-frame fixtures use original blue/alpha images; mixed video repeats
real six-frame video clips and real two-second audio clips on the Timeline, without
extending their source frame counts/durations. Independent frozen CPU compositing
supplies strict reference hashes, including final frame 149 and half-open image
end. Tests cover exact final valid frame, seek at duration, near-end seek, pause,
full five-second playback, actual end notification, and full replay. Each focused
case observed two native end notifications, exact terminal currentTime 5 and
GPU active/resources/outstanding 0/0/0. Pure boundary tests also reject arbitrary
past-end, negative/invalid and nonterminal segment-end requests.

Actual product tests additionally require final displayed surface == CPU frame
149 after native completion and use ProjectStore.play at the end for replay.
Rapid seeks reject a stale seek callback. A deterministic test-only prepared-plan
continuation replaces the project while the old result is suspended; after
release the existing cancellation/session/generation guard drops it, leaving the
new empty project with no item or plan. The test-only stale-drop count confirms
that the late callback actually resumed and was rejected.

The 75 engine tests include three endpoint tests, old native carrier compatibility,
four in-flight lease tests, single-new-generation GPU recovery, content safety,
operational images/adapter, Timeline/clipboard, ProjectFile and subtitle/spectrum
model regressions. It excludes the entire InputCompatibilityTests class and all
unrelated export/benchmark suites. Export calls here only assert rejection before
any encoding/destination modification; no image export or unrelated video export
workload ran. Carrier MOV/PNG generation is disposable fixture generation.

Earlier executed checks are reported separately, not hidden by the final table:
original Debug 1 FAIL; first corrected original Debug 1 PASS; first focused Debug
3 PASS; original-readiness Release 3 runs with 1 PASS/2 FAIL. The first new Debug
video-only diagnostic failed its five-second binding wait: its fixture omitted
subtitles while asserting a nonempty subtitle synchronized-layer binding. Existing
setSubtitles explicitly leaves that binding nil for empty input. The fixture was
corrected to retain its real subtitle, preserving the assertion and native path;
no production correction was needed. Its failing binary/log and before-correction
harness copy remain. The final Debug control was freshly compiled/executed; already
passing product Debug groups did not need repetition for this control-only change.

No app/test-host signal crash or process timeout occurred in final runtime checks.
Expected pre-correction assertion timeouts are FAIL, never PASS. Exact commands,
filters, durations and exits are in `validation-results.json`, `finish-results.json`
and the task-owned drivers under `$EVIDENCE`. New app hosts are diagnostic alternate
mains with disposable windows, not normal signed-app/manual UI acceptance.

## Remaining boundary

This resolves the tested end-of-timeline gate, not complete product image preview.
The broader edit/undo/reopen/missing-source matrix, owner native-panel/sandbox
workflow, perceptual audio checks, long duration, broad hardware and larger input
policies remain outside these bounded results. Internal compile+runtime image gate
and direct/app image export rejection remain unchanged. No public activation,
format-9 schema migration, owner data operation, independent clock, transition,
Stage 3C-2 or spectrum export implementation was introduced.

After the separate normal-build prerequisite below, a subsequent bounded slice
is generated-fixture edit-to-reopen preview regeneration, including trim/split/undo
and missing-image recovery. Full gated product preview is not accepted here.

## Normal internal app build and resource stop

The real Xcode OnTheFrame Debug target was attempted with its ordinary @main,
`DEBUG OTF_IMAGE_IMPORT`, macOS arm64 destination and intended manual ad-hoc signing
settings. This was not an alternate diagnostic main or signed CLI mock.

To avoid the prior task's stale-product cleanup, a new, previously nonexistent
DerivedData child `$BUILD_ROOT/DerivedData/IMGPreview02R-20261031-01` used its default
product/intermediate paths. No CONFIGURATION_BUILD_DIR, module-cache override,
clean or cache relocation was used. Both preexisting normal app bundles were
inventoried and copied to ignored evidence backups before the build; their
original and backup file hashes match. The older IMG-PREVIEW-02 deleted build
product was already absent at preflight; this is not a claim to recover it.

The build did not complete. A one-second read-only sample of the task-owned
swift-frontend reported **physical footprint 47.0G, peak 66.6G** (tool's own units).
This differs from resident-set reporting and must not be described as measured
resident RAM. The sampled active stack was in LLVM post-SIL code generation,
CoroCleanupPass/SimplifyCFG/removeUnreachableBlocks, not the preview's GPU runtime.
The exact source/compiler cause is not established, and it is not attributed to
this endpoint fix or the older cache-growth incident without evidence.

For safety, only the verified task-owned Xcode process group received SIGINT.
Xcode returned **75 / BUILD INTERRUPTED** after 463.398 seconds; no new normal
build or retry was started. The later small audio-assertion SwiftPM rechecks are
recorded separately above and did not restart the normal Xcode build.
This was an explicit resource stop before the driver's 600-second time limit,
not a successful build and not an app/test-host crash. No remaining task compiler
or test app was observed afterward. The source default signing configuration is
not equivalent to an effective signature: codesign verification and effective
sandbox-entitlement checks were NOT RUN because the build never succeeded.
Normal signed internal app validation therefore remains incomplete, making the
whole task PARTIAL despite the end-of-timeline runtime gate passing.

Logs: `normal-signed-internal-build.log`, `normal-compiler-sample.txt`,
`build-resource-stop.json`, `normal-build-budget.json` and `finish-results.json`.
The sampled managed disk allocation stayed around 9.4 GiB, below the 20 GiB
artifact budget; disk allocation does not bound compiler memory. The log also
contains a CoreSimulator version warning; no simulator destination was used and
no simulator/tool installation was attempted. Compiler deprecation/concurrency
warnings are retained, not suppressed or presented as warning-free builds.

The immediate next prerequisite is a bounded normal-app compiler resource
investigation and signed build, preserving this successful runtime checkpoint.
Whole-module diagnostic hosts compiled successfully, but that is only a comparison
point, not proof that changing normal compilation mode is safe or a verified fix.
After that prerequisite, continue the broader edit-to-reopen preview matrix.

## Final preservation and Git verification

Final `git diff --check` returned 0; the new Python driver parsed and the eight
source/test/report files passed bounded personal-path/obvious-token/private-key
text scans. No binary/generated artifacts are among these eight task files.
All preexisting nonignored file hashes match preflight except the four authorized
files listed above. Both inventoried prior app bundles retain every inventoried
file hash and have verified evidence backups. The fresh normal-build log contains
no stale-product removal record. Prior failed builds, test logs, raw evidence and
recovery refs were not deleted. Automatic Codex refs are excluded from the protected
Git-ref comparison; recovery/branch/upstream/main refs all match preflight.

Branch/HEAD/upstream/main remain at the baseline, ahead/behind 0/0, index empty;
existing modified/untracked work remains uncommitted. No staging, commit, push,
branch/history change, owner media/project/output edit or public image/export
activation occurred. Final sampled allocated artifact subtotal was 9,891,976 KiB
(about 9.43 GiB) across selftest-work, app/.build, experiments and managed developer
root; tiny generated temporary carriers are additional. This disk measurement is
not a memory cap. `summary.json` records final file hashes, execution outcomes,
app/ref preservation and the separate compiler resource interruption.
