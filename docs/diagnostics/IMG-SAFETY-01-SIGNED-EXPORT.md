# IMG-SAFETY-01 — Signed-app export cancellation and replacement safety

TASK ID: IMG-SAFETY-01
STATUS: SIGNED EXPORT SAFETY PASS
Date: 2026-11-01

Bounded to the generated fixtures, observed owner scenarios and existing safe fault hooks below. Not exhaustive failure, long-duration or GPU in-flight race qualification.

## Baseline and isolation

Branch `feature/subtitles`, HEAD/cached upstream `faace37a7caef001294ef37b79101b18c3e6be24`, main `44943eadabdf5a37d5242d614e7279813126dfde`. Preserve the four tracked IMG-WINDOW-01 edits, its untracked report, excluded settings/metadata and recovery refs. No staging/commit/push or history operations. CLAUDE and applicable instruction inventory reviewed; no applicable AGENTS found. Preflight found no running ON THE FRAME app/build/test.

`$E` = `$REPO/app/selftest-work/img-safety01-20261101-01`; ignored generated inputs, outputs, scripts, hashes and logs are retained. `$BUILD_ROOT` = managed Developer/ON-THE-FRAME directory. Existing Window01 Final eight bundle hashes remain unchanged. New preserved Validation, Validation2, Validation3 and Final bundles are under `$BUILD_ROOT/AppPreservation/IMGSafety01-20261101-01`; all have verified eight-file copies. Effective development ad-hoc signing, sandbox, user-selected read/write, app-scoped bookmarks and get-task-allow verified. Not distribution signing.

Only copied generated JPEG/PNG and prior generated MP4 are used. Owner fixtures and separate destinations live under `$E/owner`. The initial bookmark-free generated project, all failed runs and unpublished output retained. Native permission/Save/Replace/Cancel dialogs are owner-operated, one scenario at a time.

## Test-only change

`app/OnTheFrame/ImageExportSelfTest.swift` adds an explicit Debug `-OTFImageExportSafety` submode of the existing `-OTFImageExportTest` entry. It requires the existing isolated settings suite and internal image capability. It calls actual ProjectStore import/startExport/cancelExport and existing ExportService Options hooks. It does not change renderer, transaction, gates, schema or normal UI behavior. No new fault-injection primitive was added.

The six cases use a copied valid existing MP4 sentinel, a separate destination and observed transaction-owned replacement directory for each case. On final-publication failure the existing beforePromotion hook moves only the newly encoded temporary MP4 to the case's retained-unpublished file. The destination is never altered by the injector. This checks a missing temporary source at real replacement, not power loss, disk full or every filesystem failure.

## Newly executed automated evidence

- Bounded Debug engine: GatedImageExportTests4 + ProductionContentSafetyTests4 + ProjectFileTests6 = **14 PASS**, zero failures/skips, exit0. Driver15.631s, process physical peak558,531,664 bytes. Existing source/destination protection, image MP4/audio/subtitles, admission and compatibility tested; no GPU benchmark.
- First normal Debug build: exit0,8.653s, peak303,809,352 bytes. Corrected harness build: exit0,6.186s, peak316,654,336 bytes. Same established jobs1, non-batch,3GiB process/4GiB aggregate limits. No blocked subtitle/spectrum/WMO build.
- First signed run PID83386: five protection cases passed; successful replacement generated a valid150-frame MP4 and progress1, but final alert assertion failed. Harness dismissed only completion sheets, leaving earlier NSAlert failures queued; it therefore read the earlier failure title. Retained result is FAIL, launch wait timed out90s and was terminated(-15), driverexit1. The app was not crashed/killed by the timeout. Test-only error notifications were dismissed; owner later chose Don't Save in its quit dialog and observed exit. Original logs/app retained.
- Minimal harness correction closes the actual error alert button0 or completion button1, awaiting dismissal before next case. No assertion removed. Fresh signed run PID84357: **six cases PASS**, normal launchwait/driverexit0,6.300s, no timeout, physical peak612,337,056 bytes.

| Corrected signed case | Observed result |
|---|---|
| In-encoding cancellation | Progress `[0,0.1452]`, actual cancelExport, cancelling state observed, cancellation status, no1, destination identical. |
| During-writing injected failure | Existing failAfterFraction0.1, positive encoding progress, failure alert, no1, destination identical. |
| Writer initialization failure | Directory at own temporary output.mp4; real writer initialization error, failure alert, destination identical. |
| Cancel immediately before publication | Existing beforePromotion reached; cancel current task; cancelled status, no1, destination identical. |
| Publication failure | Existing hook retained/moved new temporary MP4; actual promotion failure alert, no1, destination identical. |
| Replacement success | Existing sentinel replaced with valid150-frame H.264 MP4, exactly one progress1, completion sheet. |

All cases checked unchanged timeline/project UUID/source bytes, finite monotonic progress, unchanged session scope count, and removal of the exact transaction-owned temporary directory. MainActor polling advanced during each run; this is automated responsiveness evidence, not owner GUI observation.

Every failed/cancelled destination SHA-256 stayed `b19d0f418611ce9debb3a83e989377284790df981585ff1a6e4d8544fe6d5327` (71,760 bytes). Successful replacement SHA-256 `fa2f4b7ab9de826730c44242d6305ad265cd54b0d6812fc076f888491985b12f`. Exact progress, timing and temporary path records are in `$E/signed-automated2/safety-cases.json`.

## Resource and session evidence: initial limitations and later measurement

The automated signed harness began with session scope count0; all cases retained0 and explicit final session teardown ended0. This does **not** prove a nonzero OS scope was released. ExportService pairs acquired image scopes by defer, while the live ProjectStore session deliberately retains source access. Writer failure/cancel paths call cancelWriting/cancelReading and retire their own temporary directory; direct writer allocation counts were not measured.

GPU admission/ownership counters are internal and not exposed by this app harness. Read-only LLDB attempts on owner-test PID84441 failed to resolve ProjectStore despite module imports (both exit1); they are instrumentation limitations, not app crashes or measured zero counts. At that point GPU drain was **NOT VERIFIED**; the later in-process measurements below close only the specified counter checks. Engine observations and process exit are not substituted for them.

Code review: projectReplaceBlocked rejects normal New/Open during export; discard continuation waits for export idle after cancellation; encoding watcher is awaited before returning its outcome. The final harness tests the normal admission guard and post-drain replacement below. A forced bypass of that guard or exhaustive scheduler race is not claimed.

## Owner sequence (completed bounded scenarios)

1. Owner closed the first disposable harness via Don't Save, retaining generated output/logs.
2. Bookmark-free generated30s project opened with missing portrait.jpg warning. File existed and size837/mtime matched metadata; native source access was not established. Do not label that initial open successful image access or a confirmed parser defect.
3. Owner created a fresh project and selected copied portrait.jpg in the internal native image picker: image displayed.
4. Owner saved new `owner-seed.ontheframe`; format9, image bookmark and five-second clip verified. Seed SHA-256 `eb76f3660a3fc4d7a2ce9c90a7ce0e2bffb51c259c86c5160d3aae8319d1bf16` retained. A separate generated copy changes only project UUID and timeline/clip length900, keeping the seed unchanged.
5. Owner opened `scoped-cancel-30s.ontheframe`: no warning,30s clip, red above green displayed. This is bounded same-session bookmark access, not long-term relaunch qualification.
6. Owner selected Save/Replace for `cancel-existing.mp4` and clicked the app cancellation control at approximately80%. Owner reported unchanged project, but did not notice a cancellation message. Agent subsequently observed AX status “내보내기를 취소했습니다(경과 00:03). 대상 파일은 만들지 않았습니다.”, same scoped-cancel-30s editor and30s duration. Destination71,760 bytes and SHA-256 remained identical; source JPEG and seed hashes also remained unchanged. This is actual in-encoding cancellation, not panel cancellation.
7. Owner selected Save/Replace for separate `replace-existing.mp4`, observed completion and subsequent project playback. New SHA-256 `b7acbad1a832fbe3a3c0cd65e0f9704425f3c8bf3a2a8244d883dfc8778ae8ce`,137,011 bytes. Existing otf-dev MediaProbe read-only inspection exited0:900frames,30/1fps CFR. This is metadata inspection, not a new full decoded-output quality comparison.
8. Owner then cancelled only the native export Save panel; project remained. Both output hashes remained equal to their preceding values. This separate panel case is not substituted for step6.

Owner performed every native Save/Replace/Cancel action. No additional owner interaction is required for the bounded cases above. No native permission prompt was accepted by automation. Owner test PID84441 is deliberately left running with the disposable project; unrelated app instances were not terminated.

No personal media/project/output is used. Public image availability, schema, image renderer/export implementation and spectrum are unchanged. Existing uncommitted window work is retained.

## Final resource/session validation

The Debug-only harness uses @testable access to the **existing**, unchanged engine counters; no public instrumentation API, new renderer or lease policy was added. It optionally opens a copied generated project with the owner's newly created image bookmark. Normal application execution is unchanged.

- Instrumentation build initially failed exit65 at a test-only `OperationalMedia.path` member access; corrected to its still-image reference path. This is a compile error, not a runtime crash. Corrected build exit0,7.089s. Existing simulator-version warning is unrelated to the macOS target.
- Signed scoped run PID85570: six cases PASS,6.162s,exit0. Actual session scope1 retained across every export; explicit session teardown0. Each case measured GPU active0, resources0 and compositor outstanding0 after completion.
- Final harness adds New Project rejection immediately after actual encoding cancellation is requested, requiring original timeline/UUID and the expected busy alert. After all cases and alert dismissal, it requests a clean new session and observes unchanged new UUID/timeline/status, idle export and no alert over200ms. This validates the supported transaction boundary, not arbitrary private reset during export.
- Final normal Debug build exit0,6.124s, peak314,721,096 bytes. Final preserved app signature/entitlements verified. Final signed run PID86095 **six cases PASS**,6.864s,exit0, no timeout; peak604,063,088 bytes. `postDrainSessionStable=true`, initial scope1, final scope0. All six final GPU counter checks0/0/0. No assertion weakened.
- Existing signed app FileGuard regression on Validation3 (same product implementation): **21/21 PASS**,exit0,62.095s; no native Save acceptance, only existing test overrides/NSAlerts. Final changes afterward were test harness assertions only. This is separate from owner panel evidence.

These are repeated six-case executions, not18 distinct scenarios. Relevant engine14 and FileGuard21 checks were newly executed. Prior EXPORT-01/02 and WINDOW-01 evidence is historical, not rerun in its entirety. Release, GPU benchmarks, spectrum/subtitle/WMO diagnostic targets and broad suites were not run.

The counters track command-owned resources/admission, not every Metal cache allocation or OS security-scope reference. Session ownership1→1 after exports→0 on session replacement/teardown is directly observed. Export-local scope pairing is supported by unchanged defer structure and successful continued source access; no global OS scope reference count is exposed. Actual cancellation while a specific GPU command was still in flight is not asserted by this test.

## Final safety and limitations

New changes for this task: only `app/OnTheFrame/ImageExportSelfTest.swift` and this report. All four prior tracked WINDOW-01 edits and its untracked report are retained. No product implementation correction was needed. Normal public image gates, image export arithmetic/policy, schema, spectrum and Stage3C-2 are unchanged.

Data-loss risk was not reproduced. Existing destinations survived every unsuccessful tested operation; successful replacement changed only its designated generated destination. Each own temporary directory was retired, and the intentionally retained unpublished MP4 remains evidence. Historical apps/logs/fixtures were not deleted. First harness failure/90s wait timeout and instrumentation compile error remain recorded. No observed app crash; corrected/final runs had no timeout or safety stop.

Remaining untested conditions: disk-full/power-loss/real hardware writer fault, arbitrary filesystem races, repeated long-duration exports, exact GPU in-flight cancellation timing, global OS scope reference counts and long-term bookmark relaunch. Safe fault hooks do not establish all such failures. No owner-specific project/media/output was used.

Recommended next bounded task: fresh-process bookmark recovery and scope lifetime validation using the saved disposable project and owner-operated grants, with explicit per-export access accounting if needed. Public release remains a separate decision.

Final Git/status/hash/privacy results are retained in `$E/final-checks.json`; index remains empty and HEAD/upstream/main unchanged. Six managed artifact roots total about10.674GiB allocated, within20GiB. No staging, commit, push, reset, clean or destructive cleanup.
