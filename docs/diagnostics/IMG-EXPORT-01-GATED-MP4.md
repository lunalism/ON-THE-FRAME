# IMG-EXPORT-01 — Gated image-aware MP4 export

TASK ID: IMG-EXPORT-01
STATUS: PARTIAL
Date: 2026-10-31 Asia/Seoul

The engine produces and decodes valid bounded image-aware MP4s in Debug and Release. Normal ProjectStore export integration and a focused normal-app self-test were added, but the required normal signed Debug build stopped at the compiler memory safety threshold. No newly signed-app execution or owner acceptance is claimed. This is not full product image support.

## Baseline, instructions and preservation

Branch `feature/subtitles`; HEAD/cached upstream `65c4d876fe463d663fd30bef6ba43e2ed830a42c`; main `44943eadabdf5a37d5242d614e7279813126dfde`. Initial tracked worktree/index clean; four excluded untracked metadata/settings files remain. CLAUDE/applicable instruction inventory, ROADMAP/HANDOFF, IMG-CP-08 audit and IMG-CP-09 publication metadata reviewed. No applicable AGENTS file found. CP-09 has a retained publication receipt/transcript rather than a separate Markdown report. No fetch/branch/history operation.

`$REPO` denotes repository root; `$BUILD_ROOT` the dedicated managed Developer/ON-THE-FRAME output root. All new disposable evidence is ignored under `$REPO/app/selftest-work/img-export01-20261031-01` (`$E`). Before hashes and refs are in `$E/before.json`. Original runnable normal app copied before rebuilding to `$BUILD_ROOT/AppPreservation/IMGExport01-20261031-01/Before/OnTheFrame.app`; eight file hashes matched. Previous After/Before bundles, old raw evidence and recovery refs were not deleted.

## Exact implementation changes

- `app/Engine/Sources/OnTheFrameEngine/ExportService.swift`: new explicit `exportImages` admission; current source access and identity retention, spectrum refusal, shared image planner, source/destination protection before temporary writes and immediately before promotion. Ordinary `export(previewPlan)` still refuses. Private shared transaction retains existing output confirmation/progress/promotion policy.
- `app/Engine/Sources/OnTheFrameEngine/SubtitleExport.swift`: existing Reader/Writer path accepts an internal strict-frame-grid flag. Only image export requires exact current reader PTS k/30; it fails rather than repeating a stale frame. Ordinary video/subtitle sparse-reader behavior defaults unchanged.
- `app/OnTheFrame/ProjectStore.swift`: actual start/begin export and eligibility use the existing two-part internal image gate; image-only export no longer requires a fabricated video media entry. Existing image import messages updated to avoid claiming the internal export route is unsupported. No normal gate activation.
- `app/OnTheFrame/ContentView.swift`: internal-gated status wording only; default-off wording retained.
- `app/OnTheFrame/OnTheFrameApp.swift`: Debug-only explicit generated-fixture export self-test dispatch.
- New `app/OnTheFrame/ImageExportSelfTest.swift`: normal AppDelegate/ProjectStore import-to-export test and runtime-off refusal test, unique generated source/destination and isolated settings required; no native panel automation. Execution NOT RUN because normal app build failed.
- New `app/Engine/Tests/OnTheFrameEngineTests/GatedImageExportTests.swift`: opt-in streaming MP4 metadata/timing/color/audio, shared preview reference, cancellation, real writer initialization failure, destination/source preservation and negative admission tests.
- `docs/ROADMAP.md`, `docs/HANDOFF.md`: bounded current state and new build blocker.
- This diagnostic report.

No ImagePreviewMetal arithmetic, InternalImagePreview geometry/layer logic, media/timeline schema, format9 codec, GPU lease/scheduler or spectrum implementation was changed.

## Architecture and gate

The app requires compile `OTF_IMAGE_IMPORT` AND runtime `-OTFEnableImageImport`, at mutation/export entry as well as UI eligibility. Ordinary configuration does not define the flag. Engine API's enabled argument is an explicit caller capability, not an OS security boundary; the app must supply its verified gate. Tests passing enabled=true do not prove a default app opted in.

`exportImages` rejects disabled, invalid/empty/non-image and spectrum-containing timelines before temporary output. It resolves every catalog image (including hidden/unused) from current validated URLs or caller-resolved URLs, acquires any available security scope and records file identity. The unchanged shared planner performs fresh bounded full probing/descriptor comparison and guarded decode. Restored metadata alone is insufficient. Scopes remain held across encoding/validation/promotion and are paired by defer on all exits. Video/audio session access remains owned by existing ProjectStore transaction guards.

The shared image-aware Metal compositor supplies the same geometry, EXIF orientation, transforms, layer order, premultiplied alpha and SDR color semantics as preview. Its temporary native clock carrier is scheduling only, never a media catalog entry or visual shader layer. No still-image source duration/frame count/SourceTiming/video-media track was invented or persisted.

Image exports use the existing SubtitleExporter Reader -> 420v subtitle footprint -> H.264/AAC Writer route even without subtitles. No independent renderer or new output format. Existing audio-only projection preserves native selected source tracks, gain/mute/fades and lineage. Subtitle footprint policy is unchanged. Exact half-open clip boundaries remain in the shared planner. Strict image-grid writing rejects missing/mismatched PTS instead of extending a prior sample.

## Actual MP4 output and preview comparison

New generated fixtures only: blue opaque PNG, half-alpha red PNG, EXIF6 portrait JPEG, generated A video and generated 48kHz stereo tone/click WAV. Three visual lanes, split image, scale0.5/translation(120,40), JPEG interval[2,14), alpha interval[1,n-1), base duration n. All encoded/decoded frames are streamed; no frame sequence or large raw dump retained. The comparison reads the preview composition through AVAssetReader, not an AVPlayer screenshot. Existing frozen CPU/raw preview QA is independently rerun.

Final Debug and Release results are identical for these metrics:

| File / scenario | Frames | Duration | Audio tracks | Minimum sampled Y/Cb/Cr PSNR dB | Maximum sampled code error |
| --- | ---: | ---: | ---: | ---: | ---: |
| five-second.mp4, image-only | 150 | 5.0s | 0 | 59.27030493569927 | 6 |
| existing.mp4, confirmed disposable replacement | 150 | 5.0s | 0 | 59.27030493569927 | 6 |
| music.mp4, images/music/subtitle | 60 | 2.0s | 1 | 55.37043091574914 | 22 |
| mixed.mp4, video/images/music/subtitle | 60 | 2.0s | 1 | 40.86512398226407 | 54 |

Actual video track: H.264 (`avc1`),1920x1080,30fps, starts0; exact decoded sample PTS k/30 and total frame count checked for every frame. Final visible PTS149/30 for five-second files,59/30 for two-second files; durations exactly150/30 and60/30. One AAC 48kHz stereo track where audio is present; image-only no audio track is valid. Existing Writer settings remain SDR709,10Mb/s H.264 High and192kb/s AAC. No codec/resolution option added. Metrics and every frame's comparison row are in `final-color-fixtures-{debug,release}/.../*.mp4.metrics.json`.

H.264 is lossy. The >=40dB sampled plane criterion is a separate encoded-output check; sampling covers Y and BOTH interleaved chroma components every eight pixels/rows, not all pixels. Large maximum errors occur near detailed video/subtitle edges and are reported, not called exact identity. Existing pre-encode frozen CPU raw Y/UV equality and canonical >=40dB/flat<=3 thresholds remain unchanged and passed in ProductImagePreviewTests. The encoded edge maximum is not mislabeled as satisfying flat<=3. No displayed AVPlayerLayer screenshot raw equivalence is claimed.

Subtitle expected footprints are applied to the shared preview reference at the proper frames before codec comparison; new image subtitle interval[12,30) and existing styled subtitle export regression passed. This tests the existing export subtitle contract, not an exact hash of the normal app's separate displayed overlay.

## Audio, progress and transaction tests

Selected WAV clip starts5, ends30, gain50%; following clip[30,60) muted. Decoded AAC RMS matched native preview within0.02 and independent sine expectation0.1/sqrt(2). Frame10 RMS0.07075843851228411 versus preview0.07056092101613327; frame20 RMS0.07054545756884599 versus0.07052769234569024. Frame1 before start and40/55 after mute decoded0. Source UUID/lineage and timeline unchanged. Existing video-only unity/adjusted/muted lane exports independently checked selected sources and audio mixing. Actual speaker listening is NOT RUN.

Progress is finite, monotonic,[0,1], with exactly one1 only after success. Cancellation requested from real encoding progress>0.1 returned cancelled, preserved existing disposable sentinel bytes, reported no1 and removed only its own temporary directory. A real AVAssetWriter initialization file-exists failure was caused inside the unique task-owned temporary directory using the existing directory-observation hook; no fake successful writer result. It preserved prior destination and retired its temporary directory. This is not disk-full/encoder-hardware/append-failure coverage.

Confirmed replacement produced a valid MP4 only on success. Image original destination was rejected and original source bytes preserved. Existing same-volume replacement/exclusive first-write flow remains; no native replacement panel was accepted. Source identities are checked again before promotion. This is not an exhaustive adversarial filesystem-race or power-loss durability proof.

Valid spectrum content with an actual audio lineage was explicitly refused before writing. No spectrum layer is silently omitted, no Stage4/3C-2 work. Unverified/restored source without a resolved URL and direct preview-plan export were refused; existing fresh-missing-source preview test also passed.

## Newly executed tests and failures retained

| Run | Result / exit | Driver seconds | Observed peak process bytes |
| --- | --- | ---: | ---: |
| First new Debug compile | compile FAIL1, async-in-XCTest autoclosure |16.468537|345981792|
| Second new Debug compile | compile FAIL1, second same autoclosure location |12.633 (rounded)|346719072|
| First runtime new Debug |3 PASS/1 FAIL, exit1; spectrum fixture omitted valid lineage |19.704844417|626017504|
| Corrected new Debug |4 PASS,0 FAIL/SKIP,exit0 |8.572 (rounded)|541099088|
| First broad Debug |test-host fatal nil trap,exit1; runner omitted required OTF_MODEL03_RUN |14.127136083|619463856|
| Corrected bounded Debug regression |67 PASS,0 FAIL/SKIP,exit0 |18.442489042|583746688|
| First Release compile |FAIL1; existing prototypes require OTF_PROTO_RELEASE |31.290037833|726205784|
| Corrected bounded Release regression |67 PASS,0 FAIL/SKIP,exit0 |98.777756875|2109540848|
| Final-source focused Debug, before both-chroma measurement improvement |6 PASS,exit0 |20.104936125|559170688|
| Final-source focused Release, before both-chroma measurement improvement |6 PASS,exit0 |94.23190425|2058832344|
| Final both-chroma/audio focused Debug |6 PASS,0 FAIL/SKIP,exit0 |26.347820208|558679120|
| Final both-chroma/audio focused Release |6 PASS,0 FAIL/SKIP,exit0 |90.604519625|2070825432|

The67-case regression includes new image export4; video-only HEVC1; styled subtitle export1; AudioMix unity/adjusted/muted3; adapter9; operational image9; ProductionContent4; ProjectFile6; persistence7; import2; spectrum model12; subtitle model9. Final6 adds the two existing raw/QA preview tests and repeats the new4; counts are overlapping executions, not73 distinct cases. Each configuration has69 distinct successful cases across those selections. The final product change after67 was only the additional invalid-timeline admission guard, covered by final-source compilation/reruns; final test improvement added both Cb/Cr samples and independent audio RMS recording. No prior PASS is substituted for a new execution. No spectrum export test or90-frame GPU benchmark selected.

Release uses the established test-only `-enable-testing -DOTF_PROTO_RELEASE` without DEBUG. Initial missing-flag compile errors and runner-induced nil trap are preserved, not product regressions or SKIPs. Two test compilation errors were corrected without weakening assertions. No corrected run timeout/crash or safety stop. Exact commands/environments/scripts, compiler logs, MP4s, per-frame metrics, PCM RMS rows and process samples remain under `$E`; neither fixture nor failed log was overwritten by a later run directory.

## Normal signed Debug build: BLOCKED / not launch PASS

Prior normal app copied and hash-verified BEFORE the build. Used the existing dedicated `$BUILD_ROOT/DerivedData/IMGPreview02R-20261031-01`, normal OnTheFrame scheme, Debug `DEBUG OTF_IMAGE_IMPORT`, jobs1, batch disabled, compiler index store disabled, inherited -j1. No clean/cache/product-output override. Did not build spectrum diagnostic target or the known WMO app host.

**Build exit65, sampled per-process footprint safety stop,54.870756042s.** Primary was `SubtitleSelfTest.swift`, not SpectrumLaneSelfTest or the new export helper. Observed compiler peak3296791456 bytes, aggregate3534493768. Per-process threshold3GiB/aggregate4GiB, polling0.1s: slight threshold overshoot is expected. Owned build/compiler work was interrupted; no owner application was terminated and no OS OOM crash is inferred. Highest compiler command and full evidence retained in `normal-debug-build/`.

No new signed product was accepted as built; no new codesign/entitlement success or normal-app self-test result. `run-normal-app.py` was prepared but NOT executed. ImageExportSelfTest and its dispatch remain pending actual signed build/runtime validation, including app progress and runtime-off refusal. Existing sandbox entitlements were not edited. Old signed app observations are prior evidence only and cannot validate this new export implementation.

The exact LLVM/root cause of this additional primary-file resource case is unconfirmed. No source exclusion, assertion removal, optimization workaround, higher memory limit or broad test refactor was attempted to force a build. The next task is a bounded compiler isolation/recovery for this normal-build primary, then rebuild/sign/execute the prepared normal app tests with only generated fixtures. Do not replay blocked full builds unbounded.

## Resource/security boundaries and owner work

All normal engine writes go through existing isolated temporary destination validation/promotion. Shared GPU counters in final engine tests returned outstanding0, active0, resources0; completion-owned resources and existing timeout quarantine semantics unchanged. New engine test process physical peak was below0.63GB in Debug; Release whole-module test compilation peaked about2.11GB, not a runtime memory measure. Full production UI cancellation races, long-duration memory stability and native scope transitions remain additional work.

Image scope attempts are paired through planning/encoding/finalization. Non-sandbox engine success is not OS permission-grant proof. Because signed app build failed, native Save/Open/destination grants, bookmark relaunch, actual app export scope lifetime and owner speaker/manual MP4 acceptance remain NEEDS OWNER TEST after build recovery. Do not operate native permission or Save panels automatically. Provisional8MiB/2048px/4194304pixels/estimated128MiB and shared preview64MiB image upload/eight-layer/FHD30 limits unchanged; not high-resolution photo approval.

Current known automatic-window presentation issue, spectrum diagnostics compiler blocker and WMO app-host compiler blocker remain. This task adds the observed normal SubtitleSelfTest primary resource stop, not a proven common root cause. No public image support, schema migration, transitions, spectrum export or Stage3C-2. No staging/commit/push, owner media/project/output change or destructive cleanup. All work stays uncommitted. Final Git/ref/source/bundle/privacy/link checks recorded separately in `$E/final-checks.json`.

## Final checks and safe resume

`git diff --check`, changed app-source syntax-only parsing, privacy and local Markdown-path checks exited0. Syntax parsing is not app typechecking/link/signing or runtime PASS. Preserved Before bundle strict code-sign verification exited0 and all eight hashes still match. Existing nonallowed file hashes and all Git refs unchanged; index empty. Final HEAD/upstream remains65c4d876fe463d663fd30bef6ba43e2ed830a42c (0/0); main44943eadabdf5a37d5242d614e7279813126dfde. Seven tracked files modified; three new source/test/report files; four preceding excluded untracked metadata/settings files remain. Only generated disposable outputs were used. Measured six managed build/selftest/app-build/experiment artifact roots total10,475,728 KiB allocated (about9.99GiB), within20GiB; not an exhaustive system-storage measurement.

For safe resume, read this report and retained normal-debug-build command/resource samples. First isolate the unchanged SubtitleSelfTest primary under the same3GiB/4GiB limits; do not raise limits or broadly remove diagnostic membership. After an approved bounded correction, re-run the normal build driver with a fresh evidence output directory, verify new signature/effective entitlements and preserve old app copies. Only then execute the prepared run-normal-app.py in new generated fixture/suite roots. Its enabled route calls actual ProjectStore.startExport; its disabled route rejects before mutation/output. No native panel confirmation is automated. Then owner confirms a NEW disposable Save destination, bookmark lifecycle and audible output. Sample-exact audio onset/packet coverage beyond the new coarse PCM windows should remain separate from speaker acceptance and the existing video-only audio onset regressions. Do not reuse the old signed bundle as proof of new export behavior.
