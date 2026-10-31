# IMG-PREVIEW-03 — Normal signed-app preview smoke

2026-10-31. **BLOCKED**. Signature, effective entitlements, binary identity and compiled internal gate were verified. Actual PlayerNSView/AVPlayerLayer image preview could not be observed or exercised. No preview PASS, no product defect/root-cause claim from the UI connection failure.

## Baseline and exact app

Branch `feature/subtitles`, HEAD/cached upstream `800f468460e6e3f604c349a35374ac40dbe04fb3`, main `44943eadabdf5a37d5242d614e7279813126dfde`, empty index, existing uncommitted persistence/import/preview/build work preserved. No live remote query or branch/history operation. Read CLAUDE, applicable instruction inventory (no repository/ancestor AGENTS found), ROADMAP, HANDOFF and [IMG-BUILD-02](IMG-BUILD-02-MEMBERSHIP-RECOVERY.md).

The exact existing normal bundle was used, **not** the incomplete spectrum diagnostic product, old baseline app or isolated test host:

```text
$BUILD_ROOT/DerivedData/IMGPreview02R-20261031-01/Build/Products/Debug/OnTheFrame.app
```

`$BUILD_ROOT` means the approved internal APFS developer output root; `$REPO` means repository root. IMG-BUILD-02's 62.745-second normal internal Debug build is reused evidence, not a build rerun here. Normal SwiftUI @main, bundle identifier `dev.ontheframe.app`, version 0.1 (1), arm64, Xcode 27B52 / Swift 6.4.2.1.9.

| Identity | SHA-256/value |
| --- | --- |
| `Contents/MacOS/OnTheFrame` | `ce0cd8aed39039bc87e99549334f31191663c703128efbf29188189c7d620d60` |
| `Contents/MacOS/OnTheFrame.debug.dylib` | `660fa5161d5d2aa51d214c27530882bc741283cbc9dfd6df3f0a46cb4b5ef73e` |
| CDHash | `67e76666bd40af62c339071866feae0d098e904c` |
| Signature | intended ad-hoc; no TeamIdentifier; no Developer ID/notarization claim |

New `codesign --verify --deep --strict --verbose=2`, identity extraction and effective-entitlement extraction all exited **0**. Effective app-sandbox, user-selected.read-write, bookmarks.app-scope and Debug get-task-allow are true. These checks establish the signed bundle configuration, not actual image-source permission acquisition or scope lifetime.

## Compiled feature gate

Checked the actual normal app's debug dylib, not just source flags. Its `ProjectStore.imageImportEnabled` getter is present at text offset `0x6feccc`; disassembly calls `NSProcessInfo.processInfo.arguments`, loads the exact `-OTFEnableImageImport` string, and returns the arguments `contains` result. It is not the constant-false compile branch. Thus **the internal image gate is compiled into this exact app**.

Runtime menu/mutation behavior was not observed. No ordinary compile-gate-off app was built or tested here. Source still requires the custom compile flag plus explicit runtime opt-in; it was not edited. A missing runtime argument should return false according to this getter, but that is not reported as a successful UI test.

The Mach-O disassembler unexpectedly emitted the full text section despite the requested symbol filter. Its 209,247,763-byte raw log was retained, then the exact getter was extracted separately. No build or compiler was run. The evidence remains within the existing 20 GiB managed artifact budget; the four-root allocated total measured 10,221,508 KiB (about 9.75 GiB).

## Launch/UI observations and isolation boundary

1. Initial UI inventory had no running ON THE FRAME entry. Selecting the exact app through the UI tool returned a timeout; that API can auto-launch an app in the background. The subsequently observed normal app PID was **25065**, launch time **10:06:57 +0900**. Its argv had no fixture path, internal image opt-in or isolated-suite argument. This first UI-tool launch was therefore **not a dedicated isolated smoke environment**; no fixtures or owner projects were sent to it.
2. A separate explicit `open -n -a "$APP" ... --args -OTFLayoutSuite dev.ontheframe.preview03.disabled.20261031 -OTFLayoutReset` attempt requested a dedicated test instance. It exited **1**, `_LSOpenURLsWithCompletionHandler` error **-10810**. No redirected app stdout/stderr file appeared. This failed before establishing the dedicated instance; it is not a gate-disabled runtime PASS.
3. Exact-path app UI selection timed out three times. Bundle-ID selection was ambiguous among three preserved bundles; no alternate bundle was substituted. Display-name selection failed and an optional launch API was unavailable; neither produced a test result.
4. Finder itself was accessible. Navigated only to the known Debug product folder and invoked the exact normal app's exposed Finder Open action. App UI selection still timed out. No owner document was opened. No permission dialog, NSOpenPanel or NSSavePanel was accepted or manipulated.
5. A one-second read-only sample of PID 25065 showed `__debug_main_executable_dylib_entry_point → OnTheFrameApp.$main → SwiftUI → NSApplicationMain`, waiting in the normal main AppKit event loop. Read-only NSWorkspace metadata reported finishedLaunching=true, active=false. These facts do **not** prove a visible editor window, player readiness, a hang, or a rendering defect. The UI/surface failure cause remains unresolved.

PID 25065 was not terminated or replaced. No other user app instance was terminated. All app-selection/launch failures are kept separate from compiler and preview failures. The native UI observations were not replaced with a CLI mock.

## A–P smoke disposition

| Scenario | Result in this task |
| --- | --- |
| A Internal image gate explicitly enabled | **NOT RUN / NEEDS OWNER TEST**; compiled getter verified separately |
| B Gate disabled in ordinary builds | **NOT RUN**; no ordinary gate-off build or menu observation; isolated runtime-off launch failed |
| C JPEG insertion | **NOT RUN / NEEDS OWNER TEST** |
| D Opaque PNG insertion | **NOT RUN / NEEDS OWNER TEST** |
| E Alpha PNG insertion | **NOT RUN / NEEDS OWNER TEST** |
| F Image clip length 150 frames | **NOT RUN / NEEDS OWNER TEST** |
| G Image-only seek | **NOT RUN / NEEDS OWNER TEST** |
| H Continuous five-second playback | **NOT RUN / NEEDS OWNER TEST** |
| I End-of-item and replay | **NOT RUN / NEEDS OWNER TEST** |
| J Mixed video/image layers | **NOT RUN / NEEDS OWNER TEST** |
| K Audio clock continuity | **NOT RUN / NEEDS OWNER TEST** |
| L Subtitle/spectrum overlay identity | **NOT RUN / NEEDS OWNER TEST** |
| M Edit invalidation | **NOT RUN / NEEDS OWNER TEST** |
| N Project session replacement | **NOT RUN / NEEDS OWNER TEST** |
| O Missing/unverified image state | **NOT RUN / NEEDS OWNER TEST** |
| P Image export blocked | **NOT RUN** dynamically; export implementation/gates unchanged |

No displayed-surface hash, output-frame hash, seek PTS/token, generation publication, lease retirement or source-scope drain was measured. There were **zero executed smoke test cases**: no PASS count invented, no assertion weakened, no arbitrary readiness wait added. The normal app launch was sampled but not tested by a substituted player or harness. Previous engine/app results remain previous evidence only.

Resource observation of the normal process: sample reported 14.7M physical / 15.1M peak at 10:08:30; a later proc rusage read reported physical **21,676,992 bytes**, lifetime physical peak **22,152,128 bytes**, RSS **87,130,112 bytes**. These are snapshots of an idle launch, not a continuous playback resource test or leak proof. No rendering workload, new build, GPU benchmark, media export or expensive diagnostic retry ran. No crash/timeout was observed for a test host because no test host was run; the UI tool itself timed out and the dedicated launcher failed.

## Generated fixtures and owner-only steps

Disposable copies only at:

```text
$REPO/app/selftest-work/img-preview03-20261031-01/fixtures/
  good.jpg
  opaque.png
  alpha.png
  otf-A.mp4
  otf-B.mp4
  aud-wav48s.wav
```

They are copies of existing generated test fixtures, not owner media. No test project or output was created by the app. Original fixture bytes were not edited. Native image-source scope/bookmark behavior remains untested because no import selection occurred.

**NEEDS OWNER TEST**, using only these copies and an empty disposable session:

1. Establish a foreground normal Debug app instance with a dedicated suite. The exact shell recipe below is a proposed owner step, **not an executed PASS**. If LaunchServices again returns -10810 or no editor window appears, record that and stop; do not quit or overwrite an unrelated session.

   ```sh
   APP="$BUILD_ROOT/DerivedData/IMGPreview02R-20261031-01/Build/Products/Debug/OnTheFrame.app"
   open -n -a "$APP" --args -OTFEnableImageImport \
     -OTFLayoutSuite dev.ontheframe.preview03.owner.20261031 -OTFLayoutReset
   ```

2. Confirm the internal image import menu is present. The owner operates the image selection panel for `good.jpg`, then tests `opaque.png` and `alpha.png` in disposable sessions. Confirm each inserted clip has 150 frames and image source metadata has no fabricated duration/frame count. Observe any permission request without automatic acceptance.
3. Seek to frame 0 and frame 149 (149/30 seconds); observe the actual video surface, carrier invisibility and overlay ordering. Play five seconds to the natural end, then replay. Record stalls, previous frames or stale overlays rather than adding waits. UI observation alone does not certify raw Y/UV equality.
4. Use only copied video/audio to construct a disposable mixed timeline, with an image above video and subtitle/spectrum overlays. Check playback/audio continuity, pause/seek, image trim/split boundaries, undo/redo, edit invalidation and project replacement. Owner-operated Save/Open, if used, must target a new file in this disposable directory; no owner projects or output destinations.
5. Verify runtime opt-in absent hides the internal menu in a separate isolated session. A separate ordinary compile-gate-off binary remains an additional unexecuted check. Check missing-source behavior only by moving a **new fixture copy**, retaining the original fixture; image export must remain refused and any existing disposable destination must remain unchanged. No export is required to check a disabled menu/reason.

Exact raw-frame, stale-generation, resource-drain and security-scope lifetime criteria still require observable in-app evidence after launch/UI access is resolved. Do not equate these owner visual steps with those stronger assertions.

## Blockers, changes and checkpoint readiness

- Existing `OnTheFrameSpectrumDiagnostics` compilation blocker and WMO app-host blocker remain outstanding and were **not retried**. No normal preview dependency on those test targets was established; they were not used to replace this smoke validation.
- Current blocker: reliable isolated normal-app foreground/UI/surface access was not obtained. Environment/LaunchServices/UI-tool failure versus product startup behavior is not diagnosed. No product fix is justified by this evidence alone.
- Next bounded task: owner-assisted foreground launch of this exact bundle in the isolated suite, recording whether the actual editor window appears. Resolve that observation before rendering changes or a rebuild. Then execute the A–P smoke matrix and collect exact frame/session/resource evidence through the normal app path.
- **Not ready to label a checkpoint as normal signed-app preview validated.** Source/checkpoint audit may review the unchanged work, but must retain this BLOCKED status and the existing compiler blockers.
- Only publication addition in this task is this report. No source, schema, renderer, build setting, gate or implementation correction. Ignored evidence contains hashes, signature logs, extracted/full disassembly, launch command/error, sample, process/resource/UI observations and generated fixture copies.

Final `git diff --check`, report privacy/link scan, pre-existing file hash comparison, full normal app-bundle hash comparison and recovery-ref/index checks are recorded in `final-checks.json`. All work remains uncommitted. No owner media/project/output modification, image export/public feature activation, spectrum Stage 3C-2/Stage 4 change, staging, commit, push or cleanup.
