# IMG-BUILD-02 — SpectrumLaneSelfTest membership and compiler recovery

2026-10-31. **BLOCKED** overall. The normal internal Debug app built and its signature/entitlements verified, but the explicit spectrum diagnostic app and isolated app-test host did not compile within the resource budget. This is not a preview/export acceptance PASS.

## 1. Baseline and responsibility

Branch `feature/subtitles`; HEAD and cached upstream `800f468460e6e3f604c349a35374ac40dbe04fb3`, main `44943eadabdf5a37d5242d614e7279813126dfde`. No fetch/live-remote update or Git mutation. Index empty; pre-existing persistence/import/preview/GPU/doc changes retained.

Read CLAUDE, applicable-instruction inventory (no AGENTS found for this repository), ROADMAP, HANDOFF, [IMG-BUILD-01](IMG-BUILD-01-COMPILER-MEMORY.md), original source and retained compiler commands/logs. Compiler remains Swift 6.4.2.1.9, Xcode 27B52. Machine RAM 24 GiB, 12 cores, initial memory query 84% free; no compiler was running at preflight.

**Classification B: required by supported developer diagnostic modes, not production runtime logic.** `SpectrumLaneSelfTest` has exactly three external Swift call sites, all in AppDelegate's existing `#if DEBUG` URL-opening dispatch:

| Argument | Entry point | Existing launcher |
| --- | --- | --- |
| `-OTFSpectrumLaneTest` | `run(folder:)` | `spectrum-lane-test.sh` |
| `-OTFSpectrumLaneManual` | `runManual(folder:)` | `spectrum-lane-manual.sh` |
| `-OTFMakeSpectrumProjects` | `makeManualProjects(folder:)` | `spectrum-project-manual.sh` |

Its `Check` alias reuses `LaneSelfTest.Check`; fixture creation, UI checks and termination helpers are internal to this diagnostic. No normal editor, renderer, media model or engine code calls the enum. Normal spectrum implementation resides elsewhere and is not excluded.

## 2. Actual membership mechanism and retained change

The hand-maintained Xcode project has a `PBXFileSystemSynchronizedRootGroup` for `app/OnTheFrame`. The app target references this group, automatically discovering its Swift files. Its PBXSourcesBuildPhase has no individually enumerated files. There is no project.yml/generated source manifest or SwiftPM target that adds this particular file to the app; the local Engine package is a separate dependency. Original `#if DEBUG` included the complete diagnostic body in every normal Debug app build.

Retained bounded separation:

- File body now uses `#if DEBUG && OTF_SPECTRUM_DIAGNOSTICS`. The file still appears in automatic discovery; **the diagnostic body and symbols are conditionally compiled only for the explicit diagnostic target**. This is not a filesystem-membership exclusion.
- New `OnTheFrameSpectrumDiagnostics` app target and shared scheme share the app source group and engine package, with separate executable, bundle identifier `dev.ontheframe.spectrumdiagnostics`, product path and Debug-only target configuration. It defines `OTF_SPECTRUM_DIAGNOSTICS`, retains DEBUG/`-Onone`, assertions and signing/sandbox settings. WMO was evaluated for this target and remains a documented, unsuccessful diagnostic configuration; it is not a proven compiler fix.
- All three original call sites remain under that flag. A normal Debug app receiving one of these diagnostic arguments explicitly logs the required target and terminates without treating the folder as ordinary media. Other diagnostic dispatch remains unchanged.
- Three existing launchers default to the explicit diagnostic product and name the new build script when absent. Their fixture/check bodies and APP override remain intact. They were not executed, so their existing cleanup operations did not run.
- New `build-spectrum-diagnostics.sh` invokes the explicit scheme with jobs 1 and the IMG-BUILD-01 process/child monitor, retaining fresh logs. Its header explicitly states the current compiler blocker. This is a recovery work-in-progress, not a working diagnostic-build guarantee.

The 1,378 lines after SpectrumLaneSelfTest's first conditional line are byte-for-byte identical to the pre-task snapshot, including **97 ordered check calls**, all three entry points, export guards and early exits. No assertion or feature was deleted. However, current diagnostic executable availability remains **unverified/blocked**; source preservation alone does not satisfy the no-capability-loss completion gate.

## 3. Exact files changed in this task

Modified:

1. `app/OnTheFrame.xcodeproj/project.pbxproj`
2. `app/OnTheFrame/OnTheFrameApp.swift` — only diagnostic-dispatch guards/fallback added to pre-existing changes
3. `app/OnTheFrame/SpectrumLaneSelfTest.swift` — first conditional line only
4. `app/scripts/spectrum-lane-test.sh` — default app/build hint only
5. `app/scripts/spectrum-lane-manual.sh` — default app/build hint only
6. `app/scripts/spectrum-project-manual.sh` — default app/build hint only

Added:

7. `app/OnTheFrame.xcodeproj/xcshareddata/xcschemes/OnTheFrameSpectrumDiagnostics.xcscheme`
8. `app/scripts/build-spectrum-diagnostics.sh` (executable)
9. This report

No engine/renderer/timeline/schema/image gate or normal export implementation was changed in this task. All earlier uncommitted work is preserved; original snapshots and trial logs are ignored evidence, not publication files.

## 4. Build and resource results

Budget unchanged: one compiler/build job, per-process physical footprint 3 GiB, aggregate 4 GiB, 0.1-second polling. Individual probes 120 seconds, Xcode jobs 300 seconds, engine regression 240 seconds. Thresholds are sampled safety stops, not hard OS allocation limits. Only newly launched owned processes/children were stopped; no owner application was terminated.

| Newly executed operation | Seconds | Observed peak process / aggregate bytes | Result |
| --- | ---: | ---: | --- |
| Normal-condition single-primary SpectrumLane file | 0.128 | 2441648 / 2441648 | exit 0; object emitted. Very short run: sampled peak is incomplete, not an exact full-lifetime maximum |
| Normal internal Debug Xcode app | 62.745 | 439190464 / 676614512 | **exit 0, BUILD SUCCEEDED**, no safety stop |
| Explicit diagnostic Debug Xcode app, WMO | 26.484 | 3265416576 / 3486947232 | **exit 65 after physical-limit safety stop**; no diagnostic app PASS |
| Single-primary diagnostic optimized probe, DEBUG and Debug assertion configuration retained | 14.948 | 3258190800 / 3258190800 | exit -2, physical-limit safety stop; not adopted |
| Diagnostic no-symbol WMO frontend probe, DEBUG and `-Onone` retained | 18.428 | 3260615944 / 3260615944 | exit -2, physical-limit safety stop; not adopted |
| Selected Debug engine tests | 78.167 | 266437616 / 338659272 | exit 0; **67 PASS, 0 FAIL, 0 SKIP** |
| Existing isolated Debug app-host driver | 15.405 | 3300838472 / 3319549792 | exit -2, physical-limit safety stop during compilation; runtime tests NOT RUN |

Normal build reused the existing dedicated `$BUILD_ROOT/DerivedData/IMGPreview02R-20261031-01`; no new large DerivedData tree, cache override, product-output override or clean. Invocation:

```sh
xcodebuild -project OnTheFrame.xcodeproj -scheme OnTheFrame \
  -configuration Debug -destination platform=macOS,arch=arm64 \
  -derivedDataPath "$BUILD_ROOT/DerivedData/IMGPreview02R-20261031-01" \
  -jobs 1 COMPILER_INDEX_STORE_ENABLE=NO SWIFT_ENABLE_BATCH_MODE=NO \
  'OTHER_SWIFT_FLAGS=$(inherited) -j1' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG OTF_IMAGE_IMPORT' build
```

Xcode's generated driver still prints its own later `-j12`; the build scheduler was limited to one job, and process samples confirmed **maximum observed concurrent swift-frontend count 1**. Normal compiler kernel lifetime peak was 440894400 bytes. Assertions/DEBUG conditions were not removed. No global settings changed.

An initial edited-project syntax error was detected before building, corrected and revalidated with `plutil -lint` and real `xcodebuild -list`; it is not hidden as a successful first check. Existing CoreSimulator-version warnings are unrelated to the macOS destination and remain in logs.

## 5. Normal bundle, signing and feature boundary

Actual bundle: `$BUILD_ROOT/DerivedData/IMGPreview02R-20261031-01/Build/Products/Debug/OnTheFrame.app`, with normal SwiftUI @main. `codesign --verify --deep --strict` and signature/entitlement extraction all exited 0. Identity is the intended **ad-hoc signature**, identifier `dev.ontheframe.app`, no TeamIdentifier; no Developer ID/notarization claim.

Effective entitlements: app-sandbox=true, user-selected.read-write=true, bookmarks.app-scope=true, get-task-allow=true (Debug). Signature validity was checked again after the diagnostic build stopped. This verifies the signed bundle, not owner native-panel workflow.

Normal binary symbol checks found ProjectStore, PlayerNSView, importFiles, startExport, SpectrumOverlay and requestStillImageImport, and **no SpectrumLaneSelfTest symbol**. This is inclusion evidence, not a substitute for runtime tests. Existing image gate still requires both `OTF_IMAGE_IMPORT` and runtime `-OTFEnableImageImport`; the build enabled the internal compile flag, not the normal public feature. Gate implementation and UI conditions were unchanged.

## 6. Regression results and explicit NOT RUNs

New Debug XCTest results:

| Class | PASS |
| --- | ---: |
| ClockCarrierCompatibilityTests | 1 |
| EndTimelinePlaybackTests | 3 |
| GenerationRecoveryTests | 1 |
| InFlightLeaseTests | 4 |
| OperationalProjectAdapterTests | 9 |
| OperationalStillImageTests | 9 |
| ProductionContentSafetyTests | 4 |
| ProjectFileTests | 6 |
| ProjectPersistenceTests | 7 |
| SpectrumModelTests | 12 |
| StillImageImportTests | 2 |
| SubtitleModelTests | 9 |
| **Total** | **67** |

All 67 executed; zero failures/skips, XCTest exit 0. Fresh generated fixture paths were supplied to opt-in cases. These include actual bounded carrier playback and generation recovery, not offline90/paced90 or benchmarks. No image export was enabled or run. No broad InputCompatibility export class was selected.

The existing IMGPreview02R isolated actual-PlayerNSView app host was attempted under the same memory cap; its WMO compilation stopped before creating an executable. Therefore image surface checks, video-only/legacy-mixed surface controls and the later compiled-gate-disabled app host are **NOT RUN**, not PASS/FAIL test assertions. The driver stopped after compilation failed and did not execute later test phases. The native spectrum-lane 97-check diagnostic and manual/project-generation modes are also **NOT RUN**, because that app target did not build. Earlier reports remain prior evidence only.

No spontaneous compiler/test-host crash or timeout occurred. The monitored interrupts caused exit -2 or Xcode exit 65; KeyboardInterrupt/cancellation stack text in the harness log reflects our safety stop. **Release NOT RUN**: required Debug diagnostic/app-host compilation remains blocked, so further build/test breadth was not started.

## 7. Decision, preservation and next bounded task

Normal runtime spectrum implementation and source lineage were not edited, symbols remain included, and 12 spectrum plus 9 subtitle model regressions passed. But the required developer diagnostic is not yet buildable inside budget. The existing WMO app host also exceeds the cap even without the excluded SpectrumLane body, so its failure must not be attributed solely to that body. There is **no claim that all diagnostic capabilities have been validated**, no normal image-preview acceptance, and no image export completion.

Next task: reduce the original diagnostic single-primary async/LLVM reproducer to a safe behavior-preserving compiler workaround, and separately inspect the retained WMO app-host invocation. Keep the same memory caps and all assertions; do not raise limits or rerun a full build by default. Only after an explicit diagnostic app builds and runs its original checks, and the app surface/control tests execute, may this checkpoint be considered NORMAL APP BUILD PASS overall. No independent preview clock, schema migration or renderer expansion is indicated by these compiler failures.

Ignored evidence: `$REPO/app/selftest-work/img-build02-20261031-01/` contains preflight hashes/refs, original source/project snapshots, exact commands, limits, process identity/samples, outputs and results; generated generation fixture evidence is in the unique sibling `img-build02-generation-20261031-01`. Existing IMG-BUILD-01/preview logs and app bundles were preserved. `$BUILD_ROOT` denotes the approved internal APFS developer-output root; no personal absolute paths belong in publication text.

Final preservation/privacy/diff checks are recorded in `final-checks.json`. No owner media/project/output modification, public image activation, image export, Stage 3C-2/spectrum export change, staging, commit, push, reset, cleanup or history rewrite. Work remains uncommitted with excluded local files intact.
