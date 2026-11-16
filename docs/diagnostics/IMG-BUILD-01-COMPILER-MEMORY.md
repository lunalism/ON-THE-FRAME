# IMG-BUILD-01 — Swift/LLVM compiler memory isolation

2026-10-31. **ROOT CAUSE IDENTIFIED (source/invocation/phase isolated); normal app build recovery remains incomplete.** No new preview acceptance or signed-app PASS.

## Baseline and preservation

- Repository `$REPO`, branch `feature/subtitles`; HEAD and cached upstream `800f468460e6e3f604c349a35374ac40dbe04fb3`, main `44943eadabdf5a37d5242d614e7279813126dfde`. Ahead/behind 0/0; no live remote query or Git mutation.
- Read CLAUDE, ROADMAP, HANDOFF, IMG-PREVIEW-02R and retained compiler evidence; no applicable AGENTS file found.
- All existing tracked/untracked persistence, import, preview and diagnostic work remains intact. Preflight file SHA-256 comparison: zero mismatches. All refs, including recovery refs: exact preflight equality. Two existing runnable app bundles: zero file-hash mismatches against preserved IMG-PREVIEW-02R inventory.
- Only retained additions: `app/diagnostics/IMGBuild01/compiler_budget.py` and this report. No retained app/engine/build-setting change. Failed source variants were saved privately and the touched self-test was restored byte-for-byte from its pre-task snapshot, not from Git.

## Original failure and responsible compilation

Prior IMG-PREVIEW-02R sample reports physical footprint **47.0 GB**, peak **66.6 GB**, build exit **75** after approximately 463 seconds. These are reused observations, not new measurements. Original stack: LLVM `CoroCleanupPass` → `SimplifyCFGPass` → `removeUnreachableBlocks`/`DeleteDeadBlocks`, after SIL/IR generation. Signing was never reached.

The normal app module is **OnTheFrame**, Swift 6.4.2.1.9 (Xcode 27B52). Debug command retained `-Onone -g -D DEBUG -D OTF_IMAGE_IMPORT`, batch mode, incremental compilation and `-j12`. The expensive retained primary batch included `SaveTrace.swift`, `SelfTest.swift`, `ShortcutSelfTest.swift`, `SpectrumLaneSelfTest.swift`: the first three objects existed; the last object did not. Image preview, ProjectStore and ContentView object outputs had already been generated.

Driver planning with `-j1`, batch disabled, incremental removed and `-driver-print-jobs` produced 56 jobs from 55 source files. The actual object-code isolation used that planned **single-primary SpectrumLaneSelfTest.swift** invocation, retaining normal Debug conditions and all other app sources as non-primary inputs. A control used the same module/options with SelfTest.swift primary instead. Explicit module map and exact argv are preserved in ignored evidence; dependency/object outputs went only into a small child of the existing interrupted DerivedData, without a new cache override or large DerivedData tree.

`SpectrumLaneSelfTest.swift` is intentionally part of Debug app discovery under `#if DEBUG`, including normal @main builds. This is not accidental inclusion of the isolated image diagnostic harness. Release excludes this Debug body and has different optimization settings; that does not establish Release build success. Inspection gives no evidence that new SwiftUI/generic image expressions are responsible for this particular runaway invocation.

## Safety budget and runner

Machine: 24 GiB physical RAM, 12 CPU cores; initial memory-pressure query reported 84% free. No competing compiler at preflight. Isolation runs one compiler at a time, with **3 GiB per-process physical footprint, 4 GiB aggregate, 120-second limit**, 0.1-second sampling. This is an observed stop threshold, not a hard OS allocation cap: polling permits a small overshoot.

`compiler_budget.py` records PID/start identity, argv, elapsed time, RSS, current physical footprint and kernel lifetime footprint via SDK `rusage_info_v4`. It follows descendants and new marker-matched Xcode compiler children, not merely the parent. On limit it signals only its newly launched job and verified owned children; unrelated applications and pre-existing services are excluded. No global Xcode/Swift settings changed. No owner app was terminated.

Final managed allocated disk usage: 9,947,300 KiB (about 9.49 GiB) across managed developer output, selftest-work, app/.build and experiments, within 20 GiB. Existing artifacts were not deleted.

## New measurements

Peak below is observed per-process physical bytes, except explicitly marked kernel peak. All runs are compilation diagnostics, **not test cases**. Exit -2 denotes our resource-stop SIGINT, not a spontaneous compiler crash.

| Run | Seconds | Peak bytes | Exit / result |
| --- | ---: | ---: | --- |
| Driver print-jobs | 0.372 | 178602800 (kernel) | 0; planning only |
| Original SelfTest primary control | 2.566 | 696009760 | 0; object emitted |
| Original SpectrumLane primary | 7.429 | 3235679208 | -2; physical limit |
| Original raw SILGen | 1.822 | 161759976 | 0; SIL only |
| Three-stage split object | 6.772 | 3303902184 | -2; physical limit |
| First six-stage split | 1.351 | 142885608 | 1; two introduced scope/type errors |
| Corrected six-stage object | 6.294 | 3306490808 | -2; physical limit |
| Corrected six-stage SILGen | 1.717 | 159400680 | 0; SIL only |
| Corrected six-stage pre-optimization IRGen | 2.070 | 230654744 | 0; IR only |
| New-PM trace option probe | 0.132 | 2113944 | 1; unsupported `-debug-pass-manager` option |
| Original line-table-only debug info | 7.319 | 3232009168 | -2; physical limit |
| Original legacy LLVM trace option | 7.434 | 3254438888 | -2; no useful per-pass trace |
| Original diagnostic `-disable-llvm-optzns` | 7.567 | 3285273624 | -2; physical limit |

No timeout, spontaneous crash or assertion/test failure was observed in these runs. The two exit-1 diagnostics above are retained, not hidden. Existing deprecation warnings remain in compiler logs.

## Confirmed findings and unresolved mechanism

1. One original SpectrumLane primary alone exceeds the safety threshold while the equivalent SelfTest control completes below 0.7 GB. Concurrent `-j12` work can add pressure but is **not required** to reproduce the runaway. Linking/module emission is not the isolated failing operation.
2. Original `run(folder:)` raw SIL is 44,831 lines. Six coherent async stages reduce the largest SIL function to 8,926 lines, but object-code compilation still exceeds the same limit. All 97 ordered `check` labels were retained in the trial. The trial is not a validated fix and was not retained in source.
3. Six-stage pre-optimization IR (20,402,263 bytes) is emitted within approximately 0.23 GB observed physical footprint. Its largest async function is 52,872 IR lines. Together with the original sampled stack, evidence locates the expensive work in subsequent LLVM coroutine processing/CFG cleanup rather than type-checking or initial IR generation.
4. Reducing debug information and diagnostically disabling optional LLVM optimization both still exceed the bound. Neither was adopted as a build setting. Neither demonstrates a general fix.
5. A Swift/LLVM coroutine-lowering/cleanup pathological case is strongly suspected. The exact allocation mechanism, individual hot coroutine, minimal independent compiler reproducer, and a safe source workaround remain unconfirmed. Large async control-flow size is a candidate trigger, not a proven sole cause. No claimed compiler upstream bug identification.

The confirmed source/phase isolation is the basis for **ROOT CAUSE IDENTIFIED** status; it does not mean a repair, normal app build, or preview acceptance has passed.

## Validation boundary and safe resume

- **Normal Debug app: NOT RUN anew.** No trial correction survived the single-primary resource gate, so a full retry would repeat a known unsafe path. Original interrupted build remains a failure/incomplete build.
- **Release normal app: NOT RUN.** Debug recovery has not established the requested safe normal-build path; Release exclusion of the test body is not a substitute for Debug validation.
- **New signing/effective sandbox entitlements/internal gate validation: NOT RUN.** No new app bundle exists. Existing apps were preserved, not represented as builds of this working tree.
- **New Debug/Release preview/video/import tests: NOT RUN.** No production correction was retained. Prior IMG-PREVIEW-02R engine/app/control results remain prior evidence only; see [its report](IMG-PREVIEW-02R-END-OF-TIMELINE.md).
- Runner Python syntax check passed; pre-task source hashes and original app hashes passed; `git diff --check` and new-publication-file privacy checks passed. No public image activation/export, new clock, Stage 3C-2, spectrum export, or owner-data change.

Next bounded task: reduce the preserved single-primary case to the specific coroutine/CFG trigger using private source variants and the same 3/4 GiB limits. Retain all assertions; prefer small coherent helpers with explicit context only after the exact trigger is demonstrated. Do not launch normal Xcode build until the original-condition single-primary object compile completes inside budget. Then one `-jobs 1` normal internal Debug build in the existing dedicated DerivedData (no output-directory/cache overrides), verify app signature/effective entitlements/runtime gate, and run the focused preview, video-only and import-safety regressions. Release follows only within a demonstrated budget. Native owner UI checks and full image-preview acceptance remain outstanding.

## Evidence and reproduction locations

Use `$REPO` for repository root and `$BUILD_ROOT` for the approved managed developer output root. Personal absolute paths occur only in ignored raw command/log evidence, not this publication report.

- `$REPO/app/selftest-work/img-build01-20261031-01/`: `before.json`, `preservation-check.json`, exact original `SpectrumLaneSelfTest-original.swift`, failed split snapshots, `original-driver.json`, `single-primary-original.json`, explicit module map, per-run `command.json`, `limits.json`, `result.json`, `processes.json`, `samples.json`, `output.log`, and driver scripts.
- `$BUILD_ROOT/DerivedData/IMGPreview02R-20261031-01/IMGBuild01-diagnostic/`: isolated object/dependency outputs, original/split SIL and pre-optimization IR. No app product path was used.
- Original failure retained at `$REPO/app/selftest-work/img-preview02r-20261031-01/`, including `normal-signed-internal-build.log`, `normal-compiler-sample.txt` and resource-stop evidence.
- Runner usage: load `run` from `app/diagnostics/IMGBuild01/compiler_budget.py`; supply the saved exact argv, a **fresh** evidence output directory, app cwd and owned-output marker. Diagnostic variants must remain private; do not replay absolute command paths on another machine without regenerating the driver plan from that machine's SDK/dependency map.

No staging, commit, push, history rewrite, cleanup or owner-media/project/output modification. Previous evidence and recovery references preserved. Worktree remains dirty from pre-existing work; index remains empty.
