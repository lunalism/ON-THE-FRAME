# IMG-WINDOW-01 — Automatic editor presentation

TASK ID: IMG-WINDOW-01
STATUS: WINDOW AUTO-PRESENTATION PASS
Date: 2026-11-01 Asia/Seoul (investigation started 2026-10-31)

Limited to the normal signed Debug app, disposable sessions and observed checks below. The historical owner's exact restoration state and every macOS window/Space configuration are not claimed reproduced.

## Baseline and scope

Branch `feature/subtitles`; HEAD/cached upstream `faace37a7caef001294ef37b79101b18c3e6be24`; main `44943eadabdf5a37d5242d614e7279813126dfde`. Initial tracked worktree/index clean, four excluded metadata/settings files retained. CLAUDE and applicable AGENTS inventory, current scene/store/layout/commands and LAUNCH-01R/PREVIEW-03/03R reports reviewed. No applicable AGENTS found in the unchanged instruction inventory.

`$REPO` is repository root; `$BUILD_ROOT` is the managed `$HOME/Library/Developer/ON-THE-FRAME` root. New ignored evidence `$E` is `$REPO/app/selftest-work/img-window01-20261031-01`; `before.json` contains refs, original status, source and excluded-file hashes. The preserved app root is `$BUILD_ROOT/AppPreservation/IMGWindow01-20261031-01`.

Preflight process inventory found no existing ON THE FRAME process. Later test PIDs were created in this task; no pre-existing owner app was killed. Original runnable normal app was copied and all eight file hashes checked in `Before/OnTheFrame.app` before rebuilding. Intermediate `After`, `Trace`, `Trace2`, `Recovery`, `Scene` and final `Final` bundles remain preserved. No old evidence or app bundle was deleted.

## Confirmed app-owned defect and remaining OS uncertainty

The app uses singleton SwiftUI `Window("ON THE FRAME", id: "main")`, not WindowGroup. Geometry is managed by EditorLayout; system scene restoration was already disabled. The scene definition alone did not reliably instantiate an editor in the tested LaunchServices runs.

1. Published control PID57093 displayed an editor; subsequent gated control PID57377 had an empty NSApplication window array, nil key/main/modal windows and a running main event loop. It was not an off-screen or minimized editor. The scalar `po` count printed nil; the empty array is the unambiguous observation.
2. Explicit `.defaultLaunchBehavior(.presented)` alone built successfully but PID57655 still had **zero windows while active and running**. This failed attempt remains evidence, not a PASS.
3. A read-only breakpoint in that zero-window PID captured actual `NSApplication _handleAEReopen:` → `AppDelegate.applicationShouldHandleReopen` on the main thread. The original callback called `ensureEditorVisible()` then always returned false. With `editorWindow == nil`, that helper merely retained intent and could not create a SwiftUI scene; returning false also suppressed default reopen.
4. Trace PID58799 confirmed `scene body` → `willFinishLaunching` → `didFinishLaunching windows=0`, all on the main thread. No editor attach occurred at launch. Initial helper intent plus default launch policy still did not create a scene.
5. Allowing default reopen when no editor was attached recovered that same process: actual reopen at00:11:07.110, attach at00:11:07.219. This independently confirms the missing-window fallback defect.
6. The final startup connection supplies the **existing** SwiftUI main-scene action from the command environment and requests it once after launch. PID59934 logged registration before launch completion, completion with0 windows, initial scene request at00:13:48.131, attach at00:13:48.233, with no intervening UI command. A real editor screenshot and responsive panel toggle followed.

Thus the confirmed app boundary was **window creation versus ordering**: startup lacked an explicit scene request in the observed zero-window path; reopen denied the framework fallback. There was no observed preview initialization hang or project-model error. Why macOS/SwiftUI sometimes completed automatic restoration without creating the scene is not fully traced; logs indicated persistent restoration state, but that is not proof of a private framework defect. No owner restoration preferences were cleared to force success.

[Apple's defaultLaunchBehavior documentation](https://developer.apple.com/documentation/SwiftUI/Scene/defaultLaunchBehavior%28_%3A%29) describes the explicit launch policy; the SDK interface confirms macOS15 availability. That policy alone was empirically insufficient here, so it is not presented as the complete fix.

## Exact correction

- `app/OnTheFrame/OnTheFrameApp.swift`: explicit initial scene policy; NewProjectButton registers its existing `openWindow(id:"main")` action (captures the action, not the store/view); launch completion requests initial presentation; nil-window reopen permits default handling, and minimized editors are checked independently of AppKit's visible flag. Debug-only `-OTFWindowLifecycleTrace` logs bounded public event/state metadata, no paths or project contents.
- `app/OnTheFrame/ProjectStore.swift`: one-shot registration/pending initial presentation, dispatched after scene/command setup. It opens the same main scene only if no editor is attached, then uses existing visibility handling. It refuses during modal/sheet, user-close or discard-confirmed states; it does not poll, repeat during Save As, reset a project, import media or replace a session. One bounded attach trace was added.
- `docs/ROADMAP.md`, `docs/HANDOFF.md`: latest bounded window result added; historical failure/partial entries retained.
- This report.

Existing New Project dirty/save/cancel transaction, WindowCloseGuard, geometry/restoration policy, singleton scene identity, media/persistence/preview/export/gate implementations remain unchanged. No manual NSWindow replacement, extra editor scene or alternate app main was introduced.

## Normal Debug builds and signature

Same existing DerivedData root `DerivedData/IMGPreview02R-20261031-01`; normal OnTheFrame scheme, Debug `DEBUG OTF_IMAGE_IMPORT`, jobs1, batch/index store disabled, inherited -j1, per-process3GiB/aggregate4GiB monitoring and300s bound. No clean/cache relocation, spectrum/subtitle diagnostic target or WMO host invocation.

| Build | Seconds | Observed peak process bytes | Exit |
|---|---:|---:|---:|
| Launch policy only |9.063231833|303612744|0|
| Initial diagnostic trace |11.551427333|314082144|0|
| Nil-safe trace |5.50360375|312869704|0|
| Public event trace |9.274073375|369345328|0|
| Default reopen/initial intent |11.10628625|342721280|0|
| Explicit initial scene connection |59.002287708|303956808|0|
| Final minimized-reopen/capture correction |7.3651610839999995|316834560|0|

All builds exited0, no resource stop or compiler crash. Build success is separate from the failed intermediate window observations. The initial NSLog fields were private/redacted in unified logs; public os.Logger event metadata made the trace readable. An unsafe possible nil NSApp trace access was corrected before launching that variant; no resulting runtime trap occurred.

Final app: **`$BUILD_ROOT/AppPreservation/IMGWindow01-20261031-01/Final/OnTheFrame.app`**. Eight bundle file hashes match the final product (`$E/final-app.json`). Final strict codesign, identity and entitlements checks each exit0: ad-hoc development identifier `dev.ontheframe.app`, sandbox, user-selected read/write, app-scope bookmarks and Debug get-task-allow. No distribution/notarization claim. The entitlement extraction emitted only the retained deprecated-colon syntax warning.

## Actual window and session validation

Final source PID60880 launched through LaunchServices with only fresh isolated layout suite/reset, **no trace/selftest/image opt-in**. Before selecting it in the UI tool, read-only AppKit inspection showed one `main` SwiftUI.AppKitWindow, visible=true, miniaturized=false, active Space, frame {{384,259},{1792,948}}, non-nil key/main and no modal. Actual native UI confirmed a visible editor and responsive panel toggles.

| Scenario | Observation |
|---|---|
| Fresh normal launch | PASS: final no-trace PID60880 visible/responsive without New Project or Window command. |
| Same suite relaunch | PASS: prior test process exited; PID61080 launched with the same suite **without reset**, automatically displayed one visible main editor and was observed via native UI. This is not project-file restoration across quit. |
| Reopen existing session | PASS: same PID60880 retained dirty V2 test session after normal reopen; no new PID/project reset. |
| Minimize/restore | PASS: actual minimize followed by New Project restored host and its dirty confirmation; normal reopen after final correction restored it too. |
| Hidden New Project | PASS: hide → Cmd+N revealed dirty confirmation; Cancel preserved V2 and dirty indication. |
| Repeated Cmd+N | PASS: three additional commands in both scene and final normal UI retained one main editor. |
| Dirty Cancel | PASS: existing confirmation appeared, Cancel preserved V2. Scene-build native Save panel was opened through the confirmation and **cancelled without writing**; dirty state and status remained. Final FileGuard provides separate programmatic save/cancel coverage. |
| Window menu | PASS for actual “Bring All to Front” in Scene and final PID61080, retaining editor. A direct editor-title selector was not exposed by AX, so that specific owner menu route is not claimed tested. |
| Duplicate windows | One editor. Later total NSApplication.windows=2 included a66×20 `NSLocalWindowSharingWindow`, identifier `_NS:8`, not a second editor. Raw counts were not conflated. |
| Session/UUID safety | Final FileGuard tests compare timeline/project UUID/history/file state under modal, discard and stale-session scenarios; all21 checks passed. |

Native Save confirmation was never accepted automatically. The Save panel showed its existing default location; no personal item was selected or opened. A keyboard Undo cleanup attempt did not visibly remove the generated lane and is not counted as an editing PASS; the task-owned disposable session was subsequently closed through the real quit/discard flow.

### UI tool limitation retained

After quitting PID60880's disposable session, an immediate AX-state request auto-launched an empty new PID61023 **without arguments**. This was detected by process-path/argument inspection, excluded from isolated test evidence and quit immediately without loading media/projects or additional data actions. Standard AppKit/window preference side effects of that automatic launch were not independently proven absent; no explicit owner preference reset/write was issued. Subsequent termination verification used process inventory rather than querying a stopped app's UI. PID61080 was then explicitly launched with the known isolated suite and no reset.

## Newly executed regressions

| Run | Result | Process/wait exit |
|---|---|---:|
| Debug engine ProjectFile/ProductionContentSafety/OperationalStillImage |19 PASS,0 FAIL/SKIP; driver7.788087584s|0|
| Final normal app FileGuard |21/21 checks PASS, generated fixtures, actual NSAlert and panel overrides;62.021213375s|0|
| Final video-only PreviewSelfTest |5 state +14 VideoOutput frame checks PASS; launch4.10386575s, verifier0|0|
| Final internal image export/import smoke enabled |7/7 checks true;2.160739291s; actual disposable150-frame MP4, unchanged project, progress and scope-array checks|0|
| Final runtime gate disabled |2/2 checks true;0.6691318339999999s; mutation/export refusal|0|

All above are newly executed; prior EXPORT-02 owner acceptance is not substituted. Gate-on/off are app smoke checks, not XCTest cases or native-panel acceptance. Video captures are AVPlayerItemVideoOutput, not displayed-layer hash equality. No renderer/export implementation changed. No GPU benchmarks, broad export suite, blocked diagnostic build or Release run.

No test timeout or observed app crash in final runs. Initial LLDB observation exited1 on an Objective-C expression syntax error and auto-detached; corrected probes exit0. Scalar po/p formatting warnings were retained. One UI connection timeout occurred against the intermediate zero-window app. The first old control process later disappeared; its exact termination origin is not established and is not relabeled a product crash.

Exact commands, resource samples, results, generated source/output fixtures and debugger traces are retained under `$E`. No failed log was overwritten to hide an outcome.

## Limits and safety

Owner-only extension: original personal settings, alternate Spaces/external monitor arrangements and repeated OS restoration combinations, plus direct editor-title Window-menu selection if present. These are outside the observed isolated validation; bounded auto-presentation PASS does not claim every macOS variant.

Long-term bookmarks, product GPU drain/cancellation, native export replacement/cancellation and subtitle/spectrum/WMO compiler blockers retain prior status. No image rendering/export change, public activation, format migration, Stage3C-2 or Spectrum Stage4 implementation. All engine/source schema files outside the two lifecycle files remain byte-identical to preflight. Owner media/project/output files were not changed. Index remains empty; no staging, commit, push, history manipulation or cleanup. Existing recovery refs, excluded settings and prior evidence remain preserved.

Recommended next task: bounded signed-app in-encoding cancellation/replacement recovery and product scope/GPU-drain validation, separate from this window lifecycle fix.

Final empty isolated editor PID61080 remains available. Earlier task-created control/intermediate PIDs57377,57655,58046,58331,58390,58799,59934 were left untouched rather than treated as owner instances to terminate; identify them by the retained `$E/final-process-inventory.txt` when reviewing. They are separate processes, not duplicate windows in PID61080. No build or test remains running.
