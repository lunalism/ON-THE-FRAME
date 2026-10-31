# IMG-BUILD-03 — Normal Debug build recovery

TASK ID: IMG-BUILD-03
STATUS: NORMAL APP BUILD PASS
Date: 2026-10-31 Asia/Seoul

Normal internal Debug app build/signing and focused regressions passed. The separate subtitle diagnostic target remains BLOCKED by compiler memory; its original UI checks were NOT executed. This is not full diagnostic recovery, public image support or owner acceptance.

## 1. Baseline and preservation

Repository `$REPO`; branch feature/subtitles; HEAD/cached upstream65c4d876fe463d663fd30bef6ba43e2ed830a42c, main44943eadabdf5a37d5242d614e7279813126dfde. Initial seven tracked modifications plus seven individual untracked files, including four excluded metadata/settings paths. Index empty. CLAUDE, applicable ancestor/repository instructions (no AGENTS found), ROADMAP/HANDOFF and IMG-BUILD-01/02/IMG-EXPORT-01 evidence reviewed. No branch/history/network operation.

`$BUILD_ROOT` means the dedicated managed Developer/ON-THE-FRAME output root. Ignored new evidence `$E` is `$REPO/app/selftest-work/img-build03-20261031-01`. Before source hashes/refs and original SubtitleSelfTest preserved there. Existing uncommitted image export implementation, prior failure logs, runnable apps, generated output and recovery refs retained. Before rebuilding, copied the existing eight-file normal app to `$BUILD_ROOT/AppPreservation/IMGBuild03-20261031-01/Before/OnTheFrame.app` and verified byte hashes. New normal apps preserved separately as After and After2; none overwrote those saved versions.

## 2. Responsibility and exact call graph

Classification: **diagnostic-only implementation required by an existing developer command; not normal product execution**. Whole file was guarded DEBUG. One external Swift symbol call exists: AppDelegate URL dispatch for -OTFSubtitleTest -> SubtitleSelfTest.run(folder:). `app/scripts/subtitle-test.sh` supplies that argument and generated otf-TA source; README references are historical diagnostic records. brightCount/finish/helpers are internal to the enum. No engine/export/UI production code depends on its symbols. LaneSelfTest provides shared helpers and remains included for other commands.

The Xcode project uses PBXFileSystemSynchronizedRootGroup for app/OnTheFrame; source files are auto-discovered rather than individually enumerated. Original normal Debug built the entire large async self-test body. The old exact failing frontend invocation and3GiB resource-stop evidence are retained in IMG-EXPORT-01. That was not a demonstrated type error or export failure. The precise Swift/LLVM allocation mechanism remains unconfirmed.

## 3. Exact task changes

Existing files modified in this task:

1. `app/OnTheFrame/SubtitleSelfTest.swift` — ONLY first conditional line -> DEBUG && OTF_SUBTITLE_DIAGNOSTICS. Every byte after the first newline remains equal to the pre-task snapshot, including84 ordered literal check calls, all assertions/helpers and existing scenarios. No test logic split, removal or weakening.
2. `app/OnTheFrame/OnTheFrameApp.swift` — existing developer dispatch compiles call only with that diagnostic flag. Normal Debug explicitly logs the required target when given that mode; it does not silently import the folder or pretend the test ran. Existing export self-test dispatch retained.
3. `app/OnTheFrame.xcodeproj/project.pbxproj` — narrow Debug-only OnTheFrameSubtitleDiagnostics target, separate product/bundle ID, same source group/engine/signing/sandbox. Does NOT enable spectrum diagnostics or WMO.
4. `app/scripts/subtitle-test.sh` — same developer command and test body; default APP/build hint now target subtitle diagnostics. APP override retained. Checks actual Info.plist executable exists/is executable so a failed build's empty .app directory cannot start a misleading test run. Remaining fixture/assertion/launcher logic retained.
5. `app/OnTheFrame/ImageExportSelfTest.swift` — pre-existing untracked IMG-EXPORT-01 harness; confirmed cleanup-only correction described below. No product export change.
6. `docs/ROADMAP.md`
7. `docs/HANDOFF.md`

Added:

8. `app/OnTheFrame.xcodeproj/xcshareddata/xcschemes/OnTheFrameSubtitleDiagnostics.xcscheme`
9. `app/scripts/build-subtitle-diagnostics.sh` (executable)
10. This report.

All engine implementation, export arithmetic/transaction/progress code, media model/schema, ProjectStore and production subtitle/preview/spectrum source stayed byte-identical to this task's preflight. The existing uncommitted IMG-EXPORT-01 implementation is preserved, not reverted.

## 4. Build boundary and safe probe

The file still belongs to filesystem discovery. Its expensive body is conditionally compiled only in the explicit subtitle Debug target. This is a compilation boundary, not a filesystem deletion or production capability exclusion. Dedicated target was chosen because the existing spectrum diagnostic target has a separate unresolved compiler failure and would pull in unrelated large diagnostics; compatibility/isolation was not assumed.

New bundle ID dev.ontheframe.subtitlediagnostics; product OnTheFrameSubtitleDiagnostics.app, normal SwiftUI main and editor dependencies. Debug assertions/-Onone retained; no whole-module override. Spectrum diagnostic target/configuration unchanged. Developer sequence is build-subtitle-diagnostics.sh then subtitle-test.sh, optionally overriding APP with the matching diagnostic app. This path is configured but CURRENTLY NOT BUILDABLE within budget; do not infer execution from source preservation. Original dated source-header example remains historical; current script selects the dedicated product.

Replayed the exact old SubtitleSelfTest single-primary command under normal conditions after adding the boundary; changed only owned object/dependency/diagnostic outputs to a fresh small child of existing DerivedData. Exit0, emitted object,0.129852833s. Captured4,358,624-byte footprint is an incomplete short-run sample, NOT an exact lifetime maximum. No claim that full compiler peak was only4MB. This safe object probe preceded the normal app build.

## 5. New build/resource measurements

Limits:3GiB per compiler process,4GiB aggregate,0.1s polling, jobs1; normal/diagnostic build300s, object probe120s, engine300s. Owned new child compilers monitored by PID/start/command; unrelated apps not signalled. Sampled thresholds permit small overshoot. Existing DerivedData/cache conventions retained, no clean or global configuration change.

| Operation | Seconds | Peak process bytes | Peak aggregate bytes | Result |
| --- | ---: | ---: | ---: | --- |
| Normal-condition single-primary proof |0.129852833|4358624 (incomplete sample)|4358624|exit0, object emitted|
| Normal internal Debug Xcode build |72.361686792|1266959824|1480822312|BUILD SUCCEEDED,exit0,no safety stop|
| Focused Debug engine |30.691251583|570688640|645580960|24 PASS,0 FAIL/SKIP,exit0|
| Harness cleanup incremental normal build |5.984559958|305038128|598233360|BUILD SUCCEEDED,exit0,no safety stop|
| Dedicated subtitle Debug target |101.441783583|3243314056|3592837312|exit65, per-process physical safety stop; build script exit1|

Normal build: existing `$BUILD_ROOT/DerivedData/IMGPreview02R-20261031-01`, normal OnTheFrame scheme, Debug `DEBUG OTF_IMAGE_IMPORT`, jobs1, batch disabled, index store disabled, inherited -j1. No output/cache override or WMO app-host compilation. Exact argv/limits/process samples/logs retained in `$E/normal-debug-build`, `normal-debug-harness-build`, `normal-primary` and `final-color-debug`.

Final signing verification/identity/effective entitlement extraction each exited0. Intended ad-hoc development signing, identifier dev.ontheframe.app, no TeamIdentifier/Developer ID/notarization claim. Effective app-sandbox, user-selected.read-write, bookmarks.app-scope and Debug get-task-allow true. No entitlement change. Final After2 copy byte-matches the rebuilt normal product.

Normal debug dylib symbol checks: SubtitleSelfTest0; SubtitleRenderer, SubtitlePreviewView, PlayerNSView, ExportService.exportImages, ProjectStore.startExport, SpectrumOverlay present. This supports membership review, not every production runtime scenario. Actual gate-on/off tests below establish the compiled internal gate; ordinary no-OTF_IMAGE_IMPORT source branch is unchanged, not rebuilt separately here.

## 6. Newly executed engine tests

24 executed PASS,0 FAIL,0 SKIP,exit0. GatedImageExport4, ProductImagePreview2, AudioMix unity/adjusted/muted3, video-only HEVC export1, styled subtitle export1, SubtitleModel9, ProductionContentSafety4. Fresh generated fixture/evidence roots; no90-frame benchmark, unrelated expensive media export, spectrum export implementation or WMO isolated app host.

Actual MP4 decode/frame count/PTS and sampled Y/Cb/Cr comparisons passed; image-only/mixed preview output matched frozen CPU raw references, existing canonical40dB/flat<=3 contract retained. Audio gain/mute/selected source and subtitle styling/timing checked. Spectrum-containing image export explicitly rejected. Engine tests are NOT signed-app or native-panel proof. Earlier IMG-EXPORT-01 Debug/Release results remain earlier evidence; **Release NOT RUN in this task** because this correction concerns Debug diagnostic membership.

## 7. Normal signed-app checks and confirmed harness correction

Used original normal SwiftUI/AppDelegate in the preserved signed bundle, generated sources/destinations, unique -OTFLayoutSuite per instance. No alternative app main, native Open/Save/permission prompt or owner project.

First gate-on test PID47936: all seven result checks true, actual150-frame H.264 MP4 produced, but open -W timed out45s (waiter exit-15). Preserved result is not counted as successful process retirement. Read-only AppKit logs explicitly showed `App termination blocked by modal sheet`; native UI showed the test's own export-completion sheet, filename normal-app.mp4. This confirmed a test cleanup defect, NOT encoding failure or an assumed hung main thread. Closed only that generated-output completion sheet through native UI and quit only this isolated test app. Post-quit procNotFound UI response is not an app crash.

Minimal harness correction: close only its own recognized export-completion sheet via the existing Debug alert test helper; await isShowing=false and attachedSheet=nil within3s, record image-export-retirement.json; then use existing test-discard flag and normal terminate. Does not accept Save/Open/permission panels, suppress export errors or remove any of the seven original assertions. A further incremental build was justified by this newly confirmed harness issue. Product export implementation unchanged.

Corrected After2 runs:

| Mode | Actual checks | Launch/process wait | Seconds | Observed app peak bytes |
| --- | --- | --- | ---: | ---: |
| Runtime enabled, PID48561 |7/7 true: normal import, eligibility, export transaction, unchanged project, progress1 once, actual150-frame avc1/FHD/no-audio profile, session scope array retired|exit0,no timeout|2.825345541|709215648|
| Runtime disabled, PID48593 |2/2 true: mutation refused and engine export refused/no destination|exit0,no timeout|0.529103583|43320328|

Both recorded readyToTerminate=true. Initial timeout/GUI/log evidence and old After app remain preserved; no failed observation relabeled. These are nine app checks, not nine XCTest cases or native panel acceptance. Final scope array0 is observed program state, not a complete independent OS-sandbox lease ledger.

Actual signed video-only PreviewSelfTest in the same final normal bundle: launch exit0/no timeout; verifier exit0, **5 state checks +14 AVPlayerItemVideoOutput frame identity checks PASS**. Includes split/trim/move/delete/undo/redo/ripple/rapid edits/stale exclusion. Captured data is not an exact displayed AVPlayerLayer hash. Fresh copied A/B sources and captures remain in `$E/normal-video`. No speaker listening or real owner workflow was inferred.

## 8. Subtitle diagnostic target availability

Executed the new developer build script once, using the same existing DerivedData. It selected OnTheFrameSubtitleDiagnostics, DEBUG + OTF_SUBTITLE_DIAGNOSTICS; highest process was SubtitleSelfTest.swift primary. Confirmed no OTF_SPECTRUM_DIAGNOSTICS and no whole-module optimization. At3,243,314,056 bytes, the budget stopped compilation; Xcode exit65, script exit1. No spontaneous compiler crash, type-error diagnosis or OS OOM claim. Exact LLVM cause remains unresolved.

Evidence is `$REPO/app/selftest-work/subtitle-diagnostics-build-20261031T135705Z-a6771239`; `$E/subtitle-diagnostics.json` records primary/flags/results. Partial .app directory exists but no executable. Original subtitle UI cases were **NOT RUN**. Negative launcher preflight exited2 with the build-first instruction before fixture generation, launch, last-result overwrite or cleanup. A sandbox shell nice permission notice accompanied a syntax/preflight command and is not a successful diagnostic test or compiler failure.

Thus: NORMAL APP BUILD PASS; SUBTITLE DIAGNOSTIC BUILD BLOCKED / RUNTIME NOT RUN. No full diagnostic recovery claim. The prior spectrum diagnostic and WMO app-host blockers remain separate and were NOT retried. The current normal app no longer requires either diagnostic target to build. Do not raise memory caps or silently remove assertions to force diagnostic success.

## 9. Remaining limits and next task

No owner native Save/Open/replace/cancel/bookmark relaunch, audible audio or full UI export workflow acceptance. Image-only signed export smoke passed; richer mixed/audio/subtitle equivalence is new engine evidence, not owner-operated app acceptance. Automatic editor-window presentation, long-duration GPU cancellation/drain and provisional image size limits remain documented. Full subtitle diagnostic keyboard/mouse/IME/UI behavior remains pending because its target cannot compile.

Recommended next product task: generated-fixture signed-app native Save/replace + bookmark/audio validation for internally gated image export, with owner-operated panels. Keep the optional diagnostic compiler recovery tracked separately; do not hide the successful normal app build behind it. No format9 schema, public image activation, spectrum Stage3C-2/4 or owner-data change.

## 10. Safety and final verification

No staging, commit, push, reset, clean, fetch, pull, merge, rebase or branch switch. Existing image export code/previous evidence preserved. Final source/hash/mode/ref/link/privacy, script/project checks and managed artifact sizes are recorded in `$E/final-checks.json`. Worktree remains uncommitted with pre-existing excluded metadata/settings files; do not describe it as clean.

Final receipt: all pre-existing file hashes outside the seven authorized task edits unchanged, including every engine/export implementation file. All84 ordered literal checks and every byte of SubtitleSelfTest after the first conditional newline unchanged. Before/After/After2 preserved bundle hashes unchanged; final signature checks exit0. Markdown paths/privacy scan, scheme XML, project plist and script syntax checks passed (the recorded shell nice notice remains a warning). No staging; index empty; all refs unchanged; HEAD/upstream0/0 and main unchanged. Overall Git worktree now10 tracked modifications and10 individual untracked paths, including four preceding excluded metadata/settings files and inherited IMG-EXPORT-01 work. Six managed roots measured10,742,016 KiB allocated (about10.24GiB), below20GiB; no exhaustive system-storage claim. Test PIDs47936/48561/48593 no longer present; ps exit1 for that query means none present, not a test crash. No owner process was killed or owner data changed.
