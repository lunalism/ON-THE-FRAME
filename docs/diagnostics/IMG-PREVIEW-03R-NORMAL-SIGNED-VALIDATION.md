# IMG-PREVIEW-03R — Normal signed-app image preview validation

STATUS: PARTIAL
Date: 2026-10-31 (Asia/Seoul)

## Scope and identity

Validation only; no source, build configuration, ROADMAP or HANDOFF edits. The existing normal Debug OnTheFrame target from IMG-LAUNCH-01R was reused, not rebuilt. This was not a diagnostic app host.

Branch `feature/subtitles`; HEAD and cached upstream `800f468460e6e3f604c349a35374ac40dbe04fb3`; main `44943eadabdf5a37d5242d614e7279813126dfde`. All preceding persistence/import/preview/build/window changes were retained.

`$REPO` means the repository; `$BUILD_ROOT` means its dedicated managed Developer/ON-THE-FRAME build root. Disposable evidence root `$E` is `$REPO/app/selftest-work/img-preview03r-20261031-01` (ignored). Generation fixtures use the separate ignored sibling `img-preview03r-generation-20261031-01`.

Exact reused bundle: `$BUILD_ROOT/AppPreservation/IMGLaunch01R-20261031-01/After/OnTheFrame.app`. All eight recorded bundle-file hashes matched the prior preserved build. Debug dylib SHA-256: `d7e8f49f774d1798c7274b6597acfec00f2abb6dd519a0cb2590122ffbfed36e`. Code-signature strict verification, identity and entitlements inspection exited 0. Identifier `dev.ontheframe.app`; ad-hoc development signature, no TeamIdentifier. Effective sandbox, user-selected read/write, app-scoped bookmarks and Debug get-task-allow entitlements were present. This is not a distribution-signing validation.

## Window/process chronology and owner evidence

The existing PID 30152 was left untouched. Initial process matching missed no-argument instances; the later corrected inventory is retained. PID 31750 was launched with the runtime image gate and isolated settings. It initially had zero NSApplication windows, no key window and no modal window. The owner reported a save-changes dialog and that choosing Don't Save produced the editor. That owner action cannot be replaced by an inference from import logs.

31750 subsequently terminated; retained system logs show normal AppKit termination, not an established crash. Its termination origin is unknown. PID 32855 was a gate-off instance. Its observations were excluded from image-preview success evidence. The owner explicitly closed it before the retry.

The tested retry PID 32976 used the exact preserved executable with `-OTFEnableImageImport -OTFLayoutSuite dev.ontheframe.preview03r.retry1.20261031 -OTFLayoutReset`. The owner selected the Window menu and confirmed the editor appeared. Actual File-menu presence of the internal image import action established compile/runtime gates. Startup still required owner-assisted window presentation; automatic initial window creation remains unresolved. No speculative lifecycle fix was made.

## Actual normal editor surface observations

All media were disposable generated fixtures. File URLs were delivered through the normal application open route; native Open/Save panel acceptance was not automated. The colored fixtures came from this run's generated engine fixtures; the initial tiny unfilled-context JPEG was black by construction and was not classified as a preview defect.

| Scenario | Newly observed result |
| --- | --- |
| JPEG, image-only | PASS: 150 frames / 5 seconds, EXIF-oriented portrait red/green image on the actual editor surface. Frame 0 and 149 retained the expected image. |
| Opaque PNG | PASS: blue image, 150-frame clip. |
| Alpha/lane ordering | PASS: half-alpha red on upper V2 over blue V1 produced purple. Carrier content was not observed as a visible layer. |
| Geometry/edit invalidation | PASS: upper image scale 50% produced centered half-size rectangle; split at 75 and end trim to 120 updated preview. Frame 119 retained purple; 120 and 149 showed blue only. |
| Image playback/end/replay | PASS in bounded smoke: actual playback to 5:00, Play state restored, replay advanced again. A temporary breakpoint observed the real end-notification callback in ProjectStore; no simulated notification. Repeated seek/pause exercised. |
| Mixed video/image/audio | PASS for visual timing: native generated A video plus linked A1, V2 alpha image extended duration to 150. Movie frame labels A f=30/90/96 matched selected UI positions. At 120 and 149 the video had ended while image remained. Actual audible output was not independently verified. |
| Subtitle | PASS: generated IMG-03R text appeared at frame 30 and was absent after its interval. |
| Existing spectrum | PASS for supported paused overlay: bars visible at click frame 96 and absent after source ended. Frame 90 silence was expected: fixture click frames are 8,30,62,75,96. Continuous playback spectrum was not claimed. |
| Mixed end/replay | PASS in bounded smoke: reached 5:00 without the prior end stall, replay advanced. |
| Missing image format 9 | PASS: generated missing-image project retained media/clip UUIDs and 150-frame structure; missing/unvalidated source was not rendered. Unavailable warning replaced prior image/movie/overlays. |
| Corrupt image | PASS: generated bad PNG rejected before commit; missing-image session remained intact and scope-release logging reported true, transfer false. |
| Session replacement | PASS: New Project cleared prior generated images and overlays. No stale surface observed at tested points. |
| Video-only recovery | PASS: after image/missing sessions, generated A video re-added as linked V1/A1, actual frame-coded video played, 4-second duration and export eligibility restored. No export was performed. |
| Image export guard | PASS: explicit still-image export refusal; no Save panel or export job. |

These are actual native editor visual/AX observations, not pixel-exact hashes of AVPlayerLayer screenshots. The independently strict engine assertions below remain separate. Tool screenshots were observed during execution; no claim is made that all are persisted as image files.

## Scopes, cancellation and resource boundary

Real import logging recorded scope ownership transfer and sourceIn 0 / length 150. A read-only breakpoint after resetProject.stopAllScopes observed `self.scopedURLs = 0 values {}`. Corrupt-input failure logged scope release. The final generated video-only session was reset via New Project / Don't Save; editor left empty and visible. Only this disposable test session was replaced.

Actual normal-app in-flight GPU cancellation races and lease-counter drain were not instrumented. GenerationRecovery and InFlightLease engine regressions passed, including strict output and observed retirement checks; this does not establish the same counters in the running normal app. No long-duration leak or stability claim is made.

## Newly executed automated checks

Existing SwiftPM tests, one Debug job, existing scratch root; command and environment are retained in `$E/engine-tests.py` and test logs. No app build, Release build, WMO app-host build, spectrum diagnostic target, offline90/paced90 benchmark or media export workload was run.

69 tests executed, 69 PASS, 0 failures, 0 skips; exit 0. XCTest time 85.67 seconds; bounded driver elapsed 88.796263875 seconds. Measured process peak 283,886,672 bytes; aggregate peak 341,919,592 bytes; kernel lifetime peak 293,602,312 bytes. No budget stop.

| Test class | Executed PASS |
| --- | ---: |
| ClockCarrierCompatibility | 1 |
| EndTimelinePlayback | 3 |
| GenerationRecovery | 1 |
| InFlightLease | 4 |
| OperationalProjectAdapter | 9 |
| OperationalStillImage | 9 |
| ProductImagePreview | 2 |
| ProductionContentSafety | 4 |
| ProjectFile | 6 |
| ProjectPersistence | 7 |
| SpectrumModel | 12 |
| StillImageImport | 2 |
| SubtitleModel | 9 |

Engine checks include exact output PTS/raw Y/UV comparisons and existing QA thresholds (40 dB, flat error <=3), source orientation/alpha and generation retirement. Export sentinel checks reject before rendering; they are not executed exports. Prior Debug/Release evidence and prior normal build success remain reused evidence only, not reruns here.

## Errors, limits and outstanding owner work

CUA initial window connection timed out; blind retry loops were avoided and owner assistance obtained. Some stale accessibility IDs were rejected without the intended action. A read-only LLDB metadata expression failed once due to a variable collision (exit 1); its corrected inspection exited 0 but found no host/player-layer ivar, so it supplies no direct audio-track/PTS evidence. These are preserved diagnostic probe failures, not hidden application test passes. Successful debugger probes detached; the app continued normally. No new application crash was established.

Native panel and speaker checks remain NEEDS OWNER TEST: in the isolated gated instance, choose internal image import, select only a generated JPEG/PNG and confirm/cancel; verify resulting clip or unchanged session. Use generated linked audio and listen during mixed playback. Do not use owner files. No native permission prompt was accepted by automation.

Current internal status text still says preview/export unsupported although gated preview is exercised; no wording or public-availability change was made. Startup zero-window recurrence also remains open. These limitations prevent declaring the broader workflow or checkpoint product-complete. Recommend one bounded window-presentation regression/fix task covering isolated launch and New Project before broader owner end-to-end acceptance.

## Safety and checkpoint disposition

Only this report was added to publication files; generated scripts, logs and fixtures stay ignored. All previous failures, media, app bundles and recovery references were retained. No staging, commit, push, reset, clean, schema migration, public image activation, image export, Stage 3C-2 or spectrum export change. No owner media/project/output edits. A full checkpoint publication audit remains necessary; this task supplies actual gated normal-app preview evidence, not approval to publish all current changes.

Final verification: all 505 baseline file hashes unchanged; all refs unchanged; index empty; 17 preceding tracked modifications and 42 individual untracked files (41 preceding plus this report). HEAD/upstream still aligned 0/0; main unchanged. New report personal-path/obvious-token scan and whitespace check passed; git diff --check exited 0. Selected managed build/selftest/experiment roots allocated 8,723,068 KiB (about 8.32 GiB), below 20 GiB; this is the listed roots measurement, not a claim about all system storage. At final process observation PID 32976 remained running, PID 30152 was no longer present; no termination signal was sent to either application by this task. Only the verified task-owned log stream PID 33178 was stopped with SIGINT. All captured logs remain preserved.
