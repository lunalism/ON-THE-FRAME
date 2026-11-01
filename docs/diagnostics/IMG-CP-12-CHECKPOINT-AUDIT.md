# IMG-CP-12 — Window, export safety and bookmark checkpoint audit

TASK ID: IMG-CP-12
STATUS: PUBLICATION READY
Date: 2026-11-01 Asia/Seoul

Internal development checkpoint preparation only; no publication or public feature approval.

## Baseline and inventory

Repository `$REPO`, branch `feature/subtitles`; HEAD and cached upstream `faace37a7caef001294ef37b79101b18c3e6be24`; main `44943eadabdf5a37d5242d614e7279813126dfde`; divergence0/0 and empty index. No fetch/live remote query or history operation was needed for this local audit. Verify the live remote again in a separately authorized publication task. CLAUDE and applicable instruction inventory reviewed; no applicable AGENTS found.

`$E` = `$REPO/app/selftest-work/img-cp12-20261101-01`. Preflight before.json records refs, status and SHA-256 of all tracked/nonignored untracked files. All prior work is retained.

Initial tracked modifications (5):

- app/OnTheFrame/ImageExportSelfTest.swift
- app/OnTheFrame/OnTheFrameApp.swift
- app/OnTheFrame/ProjectStore.swift
- docs/HANDOFF.md
- docs/ROADMAP.md

Initial nonignored untracked files (8):

- app/OnTheFrame/ImageBookmarkSelfTest.swift
- docs/diagnostics/IMG-BOOKMARK-01-CROSS-PROCESS.md
- docs/diagnostics/IMG-SAFETY-01-SIGNED-EXPORT.md
- docs/diagnostics/IMG-WINDOW-01-AUTO-PRESENTATION.md
- .DS_Store
- .claude/settings.json
- app/.DS_Store
- design/.DS_Store

This audit adds only this report and IMG-CP-12-MANIFEST.txt, and prepends the current summary to ROADMAP/HANDOFF. No Swift source or historical report edits. Final publication set is **11 files**: four app source/test files, two summaries, three historical reports, two preparation documents. The adjacent [exact manifest](IMG-CP-12-MANIFEST.txt) is authoritative. All intended modes are100644. No helper scripts need relocation or publication: the two Debug self-tests are app sources in the existing synchronized app group; no SwiftPM source-discovery change. Local execution drivers remain evidence, using the existing tracked compiler_budget.py helper.

## Combined review

Reviewed final OnTheFrameApp/ProjectStore changes, both self-tests, scene/window command routes, open candidate/commit and dirty-discard paths, image import/preview generations and export scope/transaction handling. No new material consistency defect was identified in this bounded review.

- **Creation versus ordering:** singleton SwiftUI Window id main is unchanged. Explicit initial policy and command-environment presenter request the same scene once, only when no editor is attached. Presentation does not construct a new project. Modal/sheet, user-close and discard-confirmed guards remain. Reopen permits framework handling for nil editor and restores actual minimized editor. No second editor type or polling architecture.
- **Dirty/session boundary:** New Project still passes fileCommandBlocked, projectReplaceBlocked and requestDiscard. Initial presentation never calls resetProject. Open validates a complete candidate before transfer; failure, cancellation or changed timeline/session/UUID rejects it and releases candidate scopes. Existing save/cancel protection is unchanged.
- **Image fallback correction:** when a fallback URL matches an existing session-owned URL, the candidate independently starts access before probing. Failed reacquisition rejects that candidate. Probe failure/cancellation releases the newly acquired lease; successful candidate commit releases old scopes only after validation and transfers candidate ownership. Video/audio semantics and schema are unchanged. This fixes the actually reproduced same-path fallback defect; it is not a proof for every alias, directory grant or OS permission transition.
- **Import/preview ownership:** existing import epoch/session checks and preview generation/session/item/seek checks reject stale results. Session release cancels preview construction and increments generation before access ends. Image preparation and export use their own paired start/defer-stop paths. This review does not equate Task cancellation with synchronous GPU completion; retained command counters are classified below.
- **Export boundary:** normal New/Open replacement is rejected while export is active. The supported discard/closure path waits for cancellation completion. Export retains its snapshot, validates output, rechecks cancellation and source safety before promotion, and reports1 only after successful replacement. Transaction-owned temporary cleanup is unchanged. The task does not claim forced private reset during export is supported, or add a generation token to export where admission serialization is the existing contract.
- **Gates/schema:** no changes to Media/Timeline/ProjectFile, renderer arithmetic, format9 schema, public image activation or spectrum. Both Debug diagnostic routes require explicit invocation and isolated suite/internal gate. No normal menu or permission automation was added.

## Evidence classification and retained failures

| Evidence | Retained result; not rerun here |
|---|---|
| WINDOW-01 normal signed app | Actual visible/responsive editor on fresh isolated launch and same-suite relaunch; minimize/hide/reopen, repeated Cmd+N, dirty Cancel and one editor observed. Engine19, FileGuard21, video5 state/14 VideoOutput checks, image gate-on7/off2. VideoOutput is not raw displayed-surface equality. |
| SAFETY-01 owner native dialogs | Generated30s image project: encoding cancellation around80%, unchanged existing destination hash; separate replacement completed; later export Save-panel cancellation retained project/output. Owner operated Save/Replace/Cancel; no automation approval. |
| SAFETY-01 signed automated | Final six cases PASS: encoding cancel, writer failure/init failure, prepublication cancel, promotion failure, success. Session scope1 retained during exports then0; GPU active/resources/admission observed0. Exact specific in-flight GPU cancellation race and OS-wide scope count not established. |
| BOOKMARK-01 owner A→B | A exited before fresh B, same app/suite, native Open/Save As; project A/B byte-identical including3 bookmarks, all media/clip UUID/edit values retained. Visual reports and file measurements distinguished. No new speaker-listening claim. |
| BOOKMARK-01 corrected signed app | 34 assertions PASS; real fallback post-commit full probes, missing/invalid/moved/stale sources, failed/cancelled candidate and late-session rejection; normal termination38 starts/38 stops/active0, no unmatched stop. Final FileGuard21 PASS. |

Owner bookmark A/B used the pre-fix app. Corrected signed Recovery runs use real ProjectStore and actual OS scope APIs programmatically, **not** a repeated owner-native-panel PASS. Before termination its result deliberately records3 live scopes (38/35); the termination receipt records38/38/0. Process exit alone is not the proof.

Historical reports are unchanged: WINDOW launch-policy-only zero-window failure and UI-tool accidental unconfigured launch limitation; SAFETY initial alert-harness failure/90s wait timeout and test-only compile error; BOOKMARK original fallback unreadable failure remain. Later passing results do not erase them. Historical references to still-running disposable PIDs or next tasks describe those report times, not current running processes or outstanding tasks.

Original BOOKMARK failure: candidate marked missing0 but retained only WAV owned1/active1; a post-commit image probe was unreadable after old scope release. Corrected signed run retained owned3/active3 and fresh probes passed. This is a product lifetime correction, not only a test adjustment.

Prior EXPORT-02 owner-generated JPEG/alpha/video/audio/subtitle export acceptance and actual listening remain earlier evidence. Public support is not complete.

## Newly executed validation

**Debug engine37 PASS,0 failures,0 skips,exit0**. ProjectPersistence7 + OperationalProjectAdapter9 + ProjectFile6 + StillImageImport2 + OperationalStillImage9 + ProductionContentSafety4. Driver8.1447045s, selected XCTest5.078s; monitored process peak140198824 bytes/aggregate200132336 bytes; no safety stop, crash or timeout. No unhandled-file warning in this run.

Command via existing resource monitor, with fresh output roots and existing generated fixture inputs:

```sh
swift test --package-path app/Engine --scratch-path "$BUILD_ROOT/IMG1A-build" --jobs 1 -c debug --filter '^OnTheFrameEngineTests\.(ProjectPersistenceTests/|OperationalProjectAdapterTests/|ProjectFileTests/|StillImageImportTests/|OperationalStillImageTests/|ProductionContentSafetyTests/)'
```

`$BUILD_ROOT` = `$HOME/Library/Developer/ON-THE-FRAME`. DEVELOPER_DIR selects the installed Xcode Developer directory. OTF_MODEL03_RUN and OTF_PRODUCT_IMAGE_PREVIEW_RUN point to fresh subdirectories of `$E`; OTF_CLOCK_SOURCE points to the retained generated img-b-poc1r reader fixtures; OTF_EXPORT_FIXTURES to the existing generated app/.build/test-work/fixtures. The retained `$E/run-engine.py` records exact environment/command and300s,3GiB process/4GiB aggregate bounds. Reproduction requires generated test fixtures; none is an owner asset or publication candidate.

Reverified actual preserved BOOKMARK Recovery app: all8 bundle hashes match its receipt; strict codesign verification, identity and effective entitlements commands exit0. Development ad-hoc dev.ontheframe.app, sandbox, user-selected read/write, app-scope bookmarks and get-task-allow; not distribution/notarization. Retained final normal Debug build exit0/7.123051875s, final signed34 and FileGuard21 are reused evidence. No normal app rebuild needed for this documentation-only audit; no new signed app launch or GUI/export test.

NOT RUN: Release, GPU benchmarks, long export, blocked subtitle/spectrum/WMO diagnostic builds, new owner panels, broad suites. Existing normal Debug success does not resolve diagnostic compiler blockers.

Additional checks: git diff --check; Python execution-driver/compiler-budget syntax parsing; manifest existence/uniqueness/canonical containment, regular text files and intended modes; local Markdown target validation; personal absolute path and obvious credential patterns. Exact machine-readable receipts and publication-hashes.json remain under `$E`, excluded from Git. Hash record includes this final report and manifest; do not modify candidates after that record without a new explicit audit.

## Publication and safety

Excluded and preserved: the four nonignored metadata/settings paths listed above; ignored app/selftest-work evidence/media/project fixtures/logs, app/.build products, managed DerivedData/AppPreservation bundles, experiment artifacts, recovery refs and all unrelated data. No generated media, bookmark payload, binary or private environment file is in the manifest. Publication documents use `$REPO`, `$E`, `$BUILD_ROOT` and `$HOME` rather than personal absolute paths. Pattern scanning is a bounded privacy check, not a claim to detect every possible secret.

The manifest/hash/mode and final preservation checks are recorded separately under `$E`. All preexisting source and historical report bytes must match preflight; only the two summaries are intentionally edited. Recovery refs/index/HEAD/main remain unchanged; excluded metadata/settings unchanged. No staging, commit, push, reset, clean, owner data edit, app termination or destructive cleanup.

A single checkpoint is suitable: lifecycle fixes and the corresponding isolated regressions/evidence form one bounded internal safety checkpoint. Proposed subject only: `fix: checkpoint editor window and image lifecycle safety`. Publishing requires separate owner authorization and a fresh exact hash/index/live-remote check.

## Remaining limits and next task

- Internal compile/runtime gates remain; no public image availability decision.
- Provisional encoded8MiB,2048px,4194304pixels, estimated decode128MiB; upload64MiB and8 simultaneous layers. Not high-resolution photo qualification.
- Image relink UI missing; missing-image alert retains older general unsupported-preview wording, documented rather than silently fixed here.
- Subtitle/spectrum diagnostic and WMO host compiler blockers remain. Spectrum Stage3C-2 not implemented; Stage4 export unsupported.
- External/network volumes, long-term bookmarks, permission revocation, disk-full/power-loss and long-duration/repeated large workloads not validated. All GPU/decoder allocations and exact in-flight races are not established by the sampled counters.
- Window validation covers observed isolated conditions, not every personal restoration state/Space/external monitor.

Recommended next bounded product task: safe still-image relink design/implementation with per-candidate validation, independent access ownership, atomic session commit and preserved UUID/edit structure. Do not enlarge image limits or activate public support as a side effect.
