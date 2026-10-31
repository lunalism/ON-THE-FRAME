# IMG-LAUNCH-01R — Editor window presentation recovery

2026-10-31. **WINDOW LAUNCH PASS**, limited to the newly built normal signed Debug app and the isolated window/video checks below. The original owner's historical window state could not be inspected: PID 25065 no longer existed when this task attempted inspection. No claim that its exact original startup condition, image preview, or every windowless-scene variant has been reproduced.

## Baseline and process identity

Branch `feature/subtitles`, HEAD/cached upstream `800f468460e6e3f604c349a35374ac40dbe04fb3`, main `44943eadabdf5a37d5242d614e7279813126dfde`; index empty. Read repository instructions, applicable AGENTS inventory from the preceding unchanged preflight, lifecycle/scene/layout/action source, and [IMG-PREVIEW-03](IMG-PREVIEW-03-NORMAL-SIGNED-SMOKE.md). Preserve all existing persistence/import/preview/build work and recovery refs.

The owner reported Dock icon/running dot and accessible menus, with New Project failing to reveal an editor. This was treated as presentation evidence, not proof of a crash, hang or fully responsive main thread.

The attempted read-only LLDB attach to former PID 25065 failed `no such process`; subsequent process inventory contained no running ON THE FRAME. This task did not terminate that process. Fresh, explicitly isolated test instances were then launched; no owner project or preferences suite was used for their editor/session state.

`$BUILD_ROOT` below means the approved internal APFS developer-output root, `$REPO` the repository. Original normal app:

```text
$BUILD_ROOT/DerivedData/IMGPreview02R-20261031-01/Build/Products/Debug/OnTheFrame.app
```

Before rebuilding, preserved all eight original bundle file hashes in a verified, signed copy at `$BUILD_ROOT/AppPreservation/IMGLaunch01R-20261031-01/Before/OnTheFrame.app`. The fixed build was also copied byte-for-byte to the sibling `After/OnTheFrame.app` for unambiguous UI targeting while old test instances remained alive. These are normal `OnTheFrame` target products with original SwiftUI @main, not replacement diagnostic hosts.

## Confirmed action/presentation defect

The app uses singleton SwiftUI `Window("ON THE FRAME", id: "main")`, not WindowGroup. Existing `.restorationBehavior(.disabled)` and EditorLayout geometry policies were left unchanged. ContentView's WindowAccessor calls `attachEditorWindow`; EditorLayout fits saved geometry into the available screen. ProjectStore keeps a weak editorWindow and a presentation-intent flag.

Before the fix:

1. New Project's actual menu closure called `store.requestNewProject()`.
2. That method committed inline text, checked file/project-replacement guards and requested the existing discard transaction. On success, `resetProject` installed `Timeline()` through the existing replacement path, creating a new project UUID/session and clearing old resources/state.
3. **None of that requested a scene or revealed the editor.** Model/session creation was separate from presentation.
4. `ensureEditorVisible()` could deminiaturize/activate an attached window, but New Project did not call it. If editorWindow was nil, the helper only retained `wantsEditorVisible` and returned; it could not create a SwiftUI scene itself. Dock reopen/file-open paths used that helper, with the same nil-window limitation.

### Controlled, actual-menu reproduction

- Directly launched the unchanged signed app with unique `-OTFLayoutSuite ...direct... -OTFLayoutReset`: PID **30152**. Real editor window appeared, and its normal UI was observed.
- Minimized this **empty generated test session** through the real window control. Selected File > New Project through the UI.
- A temporary, read-only debugger breakpoint captured the actual main-thread call stack from the SwiftUI menu closure into `ProjectStore.requestNewProject()` at line 2165. It was then detached.
- After the action, AppKit reported **one window, miniaturized=true, visible=false, onActiveSpace=true, frame {{303,397},{1792,948}}, key=nil, main=nil, modal=nil**. Thus this reproduction was neither an off-screen/different-Space window nor a modal obstruction. The main thread processed real actions; it was not inferred responsive merely from a menu bar.
- The source transaction's clean-project path returns through reset/replacement, but no UUID/session counter was directly read at runtime. An attempted Swift debugger expression could not find the internal ProjectStore type; that debugger command exited 1 and automatically detached, and process state was verified running afterward. This is not an app crash or a passed state assertion.

This confirms an actionable defect: **New Project does not present an existing minimized editor**, and it lacks a UI scene request when none is attached. It does not establish that the owner's absent original process had exactly this minimized state. No preview initialization blocker was observed in the clean isolated launch; pending task internals in the absent original process remain unknown.

## Separate LaunchServices finding

A test launch specifying `open --stdout/--stderr` files in the repository evidence directory returned -10810/exit 1, as in IMG-PREVIEW-03. Removing those two file-redirection options, while keeping the same app and an isolated test suite, returned **exit 0** and created a functioning app instance. Subsequent fixed and video launches without those options also succeeded.

Therefore -10810 from that test invocation must not be generalized into a broken normal app startup path. Log-redirection setup is the controlled distinguishing factor; an exact sandbox/launchd denial mechanism was not traced. No security permission was bypassed, no preference reset outside the dedicated suites, and no existing user app was killed.

## Minimal correction — exact changed source

1. `app/OnTheFrame/ProjectStore.swift`: New Project now calls `ensureEditorVisible()` **after its existing guards**, before discard confirmation. It accepts an optional synchronous scene-presentation callback, called only if no editorWindow is attached. Existing direct/programmatic call sites remain source-compatible via the default nil callback.
2. `app/OnTheFrame/OnTheFrameApp.swift`: the same menu item/shortcut/disabled condition is provided by a small NewProjectButton view, which obtains SwiftUI's documented `openWindow` environment action and supplies `openWindow(id: "main")` to the store.
3. This diagnostic report.

No WindowGroup conversion, new scene, startup/restoration policy change, private scene API or new preview clock. Existing file/replacement guards, dirty-document discard/save/cancel transaction, model UUID semantics, image gate, sandbox, preview/export eligibility and video/audio implementation remain intact. The nil-window callback is a UI-command boundary; direct test/KeyRouting calls still use the default callback. A genuinely zero-window live process and every keyboard/reopen variant were not separately exercised.

## Bounded normal Debug build and signing

Reused the proven dedicated DerivedData and IMG-BUILD-01 process/child guard: jobs 1, batch disabled, unchanged normal Debug conditions `DEBUG OTF_IMAGE_IMPORT`, per-process 3 GiB, aggregate 4 GiB, 300-second stop threshold. No clean/cache/product-directory override or global setting change. No blocked spectrum target or WMO host retry.

**Normal Debug BUILD SUCCEEDED, exit 0, 37.345640 seconds**, no resource stop. Observed process peak **663,618,544 bytes**, kernel lifetime peak **663,749,616 bytes**, aggregate peak **957,222,968 bytes**.

New product and verified After copy preserve identifier `dev.ontheframe.app`, normal @main and intended ad-hoc signing. Code-sign strict verification, identity extraction and effective-entitlement extraction all exited **0**. Effective app-sandbox, user-selected.read-write, bookmarks.app-scope and Debug get-task-allow remain true. No Developer ID/notarization claim. Fixed debug-dylib SHA-256:

```text
d7e8f49f774d1798c7274b6597acfec00f2abb6dd519a0cb2590122ffbfed36e
```

## Actual fixed window and transaction validation

Fixed fresh test PID **30976**, After bundle, dedicated `...fixed...` settings suite, no restored project or image runtime opt-in:

- Normal LaunchServices launch without app stdout redirection: **exit 0**.
- Actual editor observed through native accessibility and a screenshot, including normal media list, preview, timeline and toolbar. This was not just a process-start/signature assertion.
- Minimize → actual File > New Project: the editor changed from minimized/dialog accessibility state back to a visible standard window. The original failing presentation behavior was corrected.
- Three additional Cmd-N actions: editor retained; no duplicate editor observed.
- Read-only AppKit inspection: **one `identifier=main` SwiftUI.AppKitWindow**, visible, unminimized, on the active Space, with non-nil key/main window and no modal. Total NSApplication.windows was two: the other was a **66×20 NSLocalWindowSharingWindow, identifier `_NS:8`**, not a second editor. Raw total was not silently reported as one. Full class/identifier/frame evidence retained.
- Added a disposable V2 lane, minimized the dirty window, invoked New Project: editor surfaced and the original unsaved-changes sheet appeared. Chose **Cancel**; V2 and dirty state remained. Undo removed only that test lane and restored the clean session. No Save/Open panel or permission prompt was accepted, and no project was written.

These graphical actions were automated against generated/empty test sessions, not owner-operated panel validation. The owner's original preferences/Space/windowless state still needs an owner recheck because its process was already gone.

## Existing video-only workflow

Ran the **existing PreviewSelfTest in the newly built normal signed app**, using LaunchServices folder delivery and unique suite/`-OTFPreviewTest`, with copied generated otf-A/otf-B fixtures. No WMO compilation, alternative @main or image/export path. The test app terminated itself through its original completion path; no owner process was terminated.

- App launch/wait: **exit 0**, 3.557521 seconds, no resource/time stop; manifest produced.
- Native test process PID **31034**: observed physical peak **273,712,280 bytes**, kernel lifetime peak **274,564,248 bytes**.
- Existing `otf-dev verify-preview`: **exit 0, OVERALL PASS** — **5 state checks plus 14 captured-frame identity checks**, zero failed checks. Includes split/trim/move/delete/undo/redo/ripple/rapid edits and stale-result exclusion.
- The verifier reads AVPlayerItemVideoOutput captures. It is **not** an exact displayed AVPlayerLayer hash test.

Also exercised the visible fixed normal app: file-open delivery of a generated 1920×1080/30fps, four-second otf-A MP4, UI + insertion into linked V1/A1, Play. Accessibility showed advancing time and Pause state; the actual preview screenshot displayed the generated A/frame-code pattern. This is visual smoke evidence, not synchronized raw surface identity or audible audio-quality measurement. The visible test session now contains only this generated clip, unsaved; no owner media or project was loaded.

No Release build or broad engine rerun was needed for this localized app lifecycle change. No image import/preview acceptance, image export, actual media export, GPU benchmark, spectrum diagnostic or blocked WMO test-host run.

## Limits and safe next task

- Exact original owner window count/Space/modal/task state is unavailable; no crash or hang is assigned to it. App-specific crash-report inventory found no new OnTheFrame report since this task's preflight.
- Fresh startup, minimized-window recovery, repeated New Project, dirty Cancel protection and generated video-only workflow passed. True zero-attached-window callback execution, all Dock reopen/keyboard variants, owner original-state recovery, native Open/Save and audio listening remain additional checks.
- Existing compiler blockers remain separate. Image preview smoke A–P from IMG-PREVIEW-03 is still incomplete; this launch result does not close that gate.
- Recommended next task: resume bounded normal signed-app image-preview smoke on this known-visible build, using fresh disposable data, explicit internal runtime gate and **no app stdout-file launch redirection**. Owner should first confirm New Project reveals the editor in the original environment without resetting owner preferences. Record a genuinely windowless case separately if it persists.

## Evidence, Git and data preservation

Ignored evidence at `$REPO/app/selftest-work/img-launch01r-20261031-01/`: preflight file/ref hashes and source snapshots, failed old-PID attach, original/fixed AppKit states, actual menu-entry breakpoint, launch comparison, source-compatible normal build command/resource samples, original/After bundle hashes/signing, UI observations, video manifest/raw captures/verifier log and final checks. Native AX/screenshot observations also remain in the task transcript. The initial UI metadata's raw-window-count description was corrected after classifying the sharing helper; its earlier version and raw debugger logs were preserved.

Original runnable Before app remains hash-verified; other historical apps/logs/recovery refs and all earlier uncommitted image work remain preserved. Test-launched control instances were not force-terminated; fixed PID 30976 remains available for inspection with generated test data. No owner media/project/output modification or owner preferences-suite reset. No public image activation, image export, Stage 3C-2/spectrum change, staging, commit, push, reset, clean or deleted build products. Final source/privacy/link/index/ref checks are recorded in `final-checks.json`.
