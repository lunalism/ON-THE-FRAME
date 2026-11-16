# IMG-CP-08 — Gated image checkpoint audit

TASK ID: IMG-CP-08
STATUS: PUBLICATION READY
Date: 2026-10-31 Asia/Seoul

Publication readiness means an explicitly limited development checkpoint, not completed public image support, signed-sandbox acceptance or resolution of every known blocker. No implementation correction was made during this audit. Known limitations below remain open.

## Git and preservation

Repository identity verified at the requested repository. Branch `feature/subtitles`; HEAD/cached upstream `800f468460e6e3f604c349a35374ac40dbe04fb3`; main `44943eadabdf5a37d5242d614e7279813126dfde`. Ahead/behind 0/0; index empty. No live remote query/fetch. Initial inventory: 17 tracked modifications plus 42 individual untracked files = 59 paths. All were classified; no directory was assumed safe wholesale.

CLAUDE, applicable ancestor/repository instruction inventory, ROADMAP/HANDOFF, current code and persistence/import/preview/build/window diagnostic evidence reviewed. No applicable AGENTS file found. No new agent/delegation, product feature or policy decision.

`$REPO` denotes repository root; `$BUILD_ROOT` the dedicated managed Developer/ON-THE-FRAME output root. New ignored evidence `$E` is `app/selftest-work/img-cp08-20261031-01`; bounded generation fixtures are in sibling `img-cp08-generation-20261031-01`. `$E/before.json` records pre-audit file hashes, refs and the complete original Git inventory. No excluded artifact was deleted.

## Final-source consistency review

| Boundary | Finding |
| --- | --- |
| Persistence | ProjectStore uses ProjectPersistence, not a lossy temporal-only serialization. Complete catalog with any used/unused still image writes 9; image-free content retains conditional 5–8. Reader delegates legacy 1–8 to existing codec/adapter. IDs, locations, image descriptors, audio lineage, subtitles and spectrum retained. No schema edits here. |
| Save safety | Candidate encode/decode semantic comparison, source path/hardlink/symlink protection, Cocoa replacement directory, same-volume rename and exclusive first-create are present. Precommit cancellation/identity checks and postcommit warning are distinguished; no claim of rollback after successful replacement. OS native-panel/volume grants and hostile filesystem race exhaustiveness remain outside this checkpoint. |
| Open safety | Candidate scopes, bookmarks and validated availability built locally; old session retained until final epoch/session/model checks. Missing images retain unverified metadata and clip structure, not fabricated availability. Candidate failure/cancel paths retire acquired scopes. Save As rebases relative hints from resolved or old-project locations. |
| Import gate | Menu, request and asynchronous mutation entry each enforce compile OTF_IMAGE_IMPORT plus runtime -OTFEnableImageImport. Default build conditions do not define it. File extension only routes; full probe controls actual admission. Registration/insertion are a local candidate committed as one history change; IDs and sourceIn 0/length150 remain real model invariants. No fake source frame count/duration. |
| Preview gate | ProjectStore selects InternalImagePreview only under the same explicit gate. Engine API additionally requires enabled=true; it is a deliberate internal capability, not a sandbox security boundary against arbitrary linked code. Ordinary CompositionPlanner/ProductionContent still reject the entire still-image catalog. |
| Source validation | All catalog images, including hidden/unused, require a fresh bounded probe; stored size/modified time/descriptor must agree. A restored unverified descriptor alone has no usable source proof. Decode checks identity again before upload. Missing/changed source fails closed rather than silently dropping a layer. This is not a cryptographic source-content authenticity guarantee. |
| Native playback | Temporary carrier is not registered as media or serialized, and is not passed as a visual shader input. Native AVPlayer, audio projection and existing item/seek-token overlay contract retained. Exact terminal prefetch cancels only at project end; visual intervals stay half-open. Video-only branch retains original planner. |
| Export | App full-catalog refusal, ordinary planner refusal and ExportService preview-only-plan refusal retained before output writes. No image export or spectrum export added. Video-only export implementation unchanged except additional false-by-default preview capability guard. No actual export rerun here. |
| Ownership | Preview tasks cancel/chain serially; generation/session fences prevent stale publication. Compositor admission bounds five outstanding requests; completion capture holds GPU wrappers until observed completion and timeout quarantines renderer. Normal-app cancellation/drain coverage remains incomplete; engine/experimental lease PASS is not substituted. |
| Subtitle/spectrum | Existing item binding, stale seek token, paused spectrum layering and source lineage retained. No Stage3C-2/continuous spectrum implementation or export. Normal runtime spectrum code not excluded by diagnostics membership change. |
| Window transaction | NewProjectButton supplies main-scene open action; ProjectStore still checks command/replacement guards and retains dirty Save/Don't Save/Cancel flow. Minimized-window recovery was observed previously; automatic zero-window creation is still unresolved, not declared fixed here. |
| Build split | Only diagnostic body is guarded DEBUG && OTF_SPECTRUM_DIAGNOSTICS. Separate Debug target/scheme and three launchers preserve original 97 checks. Normal app no longer compiles that body. Diagnostic target still fails compiler budget and WMO host still blocked. This is incomplete developer capability, explicitly retained rather than presented as repaired. |

No new confirmed material correctness/data-safety defect was identified in this bounded review. This is source review plus selected regression evidence, not proof over all filesystem, decoder, concurrency or graphical paths.

## Exact publication inventory

The authoritative relative path set is [IMG-CP-08-MANIFEST.txt](IMG-CP-08-MANIFEST.txt): **57 distinct existing regular files**. Initial59 minus four personal/environment paths plus two audit/preparation files =57. No source expansion to fill a target count.

Every candidate's final SHA-256, byte length and intended Git mode is recorded in `$E/publication-hashes.json`, including the manifest and this report. Keeping the hash receipt outside the manifest avoids a self-referential document digest. It contains no file payloads; preserve it for publication preflight and compare exact bytes before staging. Any later edit invalidates that receipt. Existing tracked executable modes are preserved; only executable candidate is the shell launcher set according to recorded actual/index modes, not Python shebang inference.

### Engine implementation — 7

- `app/Engine/Sources/OnTheFrameEngine/CompositionPlanner.swift`
- `app/Engine/Sources/OnTheFrameEngine/ExportService.swift`
- `app/Engine/Sources/OnTheFrameEngine/ImagePreviewMetal.swift`
- `app/Engine/Sources/OnTheFrameEngine/InternalImagePreview.swift`
- `app/Engine/Sources/OnTheFrameEngine/ProductionContent.swift`
- `app/Engine/Sources/OnTheFrameEngine/ProjectPersistence.swift`
- `app/Engine/Sources/OnTheFrameEngine/StillImageImport.swift`

### Focused regression/experimental tests — 8

- `app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/GenerationRecoveryTests.swift`
- `app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/MetalNV12Experiment.swift`
- `app/Engine/Tests/OnTheFrameEngineTests/IMGPreview01/CarrierDurationTests.swift`
- `app/Engine/Tests/OnTheFrameEngineTests/IMGPreview01/ClockCarrierCompatibilityTests.swift`
- `app/Engine/Tests/OnTheFrameEngineTests/IMGPreview01/ProductImagePreviewTests.swift`
- `app/Engine/Tests/OnTheFrameEngineTests/IMGPreview02R/EndTimelinePlaybackTests.swift`
- `app/Engine/Tests/OnTheFrameEngineTests/ProjectPersistenceTests.swift`
- `app/Engine/Tests/OnTheFrameEngineTests/StillImageImportTests.swift`

### Build configuration/script — 6

- `app/OnTheFrame.xcodeproj/project.pbxproj`
- `app/OnTheFrame.xcodeproj/xcshareddata/xcschemes/OnTheFrameSpectrumDiagnostics.xcscheme`
- `app/scripts/build-spectrum-diagnostics.sh`
- `app/scripts/spectrum-lane-manual.sh`
- `app/scripts/spectrum-lane-test.sh`
- `app/scripts/spectrum-project-manual.sh`

### App implementation/diagnostic membership — 6

- `app/OnTheFrame/ContentView.swift`
- `app/OnTheFrame/EditorLayout.swift`
- `app/OnTheFrame/OnTheFrameApp.swift`
- `app/OnTheFrame/ProjectStore.swift`
- `app/OnTheFrame/SpectrumLaneSelfTest.swift`
- `app/OnTheFrame/TimelineView.swift`

### Diagnostic harness/tool — 13

- `app/diagnostics/IMGBuild01/compiler_budget.py`
- `app/diagnostics/IMGImport01/GateDisabledAppTests.swift`
- `app/diagnostics/IMGImport01/ImageImportAppTests.swift`
- `app/diagnostics/IMGImport01/build-signed-app.py`
- `app/diagnostics/IMGImport01/run-tests.py`
- `app/diagnostics/IMGPersist01/PersistenceAppTests.swift`
- `app/diagnostics/IMGPersist01/run-tests.py`
- `app/diagnostics/IMGPreview01/ClockCarrierAppTests.swift`
- `app/diagnostics/IMGPreview01/run-tests.py`
- `app/diagnostics/IMGPreview02/ProductImagePreviewAppTests.swift`
- `app/diagnostics/IMGPreview02/run-tests.py`
- `app/diagnostics/IMGPreview02R/EndTimelineAppTests.swift`
- `app/diagnostics/IMGPreview02R/run-tests.py`

### Documentation/preparation — 17

- `docs/HANDOFF.md`
- `docs/ROADMAP.md`
- `docs/diagnostics/IMG-BUILD-01-COMPILER-MEMORY.md`
- `docs/diagnostics/IMG-BUILD-02-MEMBERSHIP-RECOVERY.md`
- `docs/diagnostics/IMG-CP-08-CHECKPOINT-AUDIT.md`
- `docs/diagnostics/IMG-CP-08-MANIFEST.txt`
- `docs/diagnostics/IMG-IMPORT-01-GATED-IMPORT.md`
- `docs/diagnostics/IMG-LAUNCH-01R-WINDOW-PRESENTATION.md`
- `docs/diagnostics/IMG-PERSIST-01-TRANSACTIONAL-PERSISTENCE.md`
- `docs/diagnostics/IMG-PERSIST-02-SIGNED-SANDBOX.md`
- `docs/diagnostics/IMG-PREVIEW-01-CLOCK-CARRIER-COMPATIBILITY.md`
- `docs/diagnostics/IMG-PREVIEW-01G-GENERATION-RECOVERY.md`
- `docs/diagnostics/IMG-PREVIEW-01R-SURFACE-OBSERVATION.md`
- `docs/diagnostics/IMG-PREVIEW-02-GATED-PRODUCT-PREVIEW.md`
- `docs/diagnostics/IMG-PREVIEW-02R-END-OF-TIMELINE.md`
- `docs/diagnostics/IMG-PREVIEW-03-NORMAL-SIGNED-SMOKE.md`
- `docs/diagnostics/IMG-PREVIEW-03R-NORMAL-SIGNED-VALIDATION.md`

## Exclusions and reproducibility

Exact nonignored exclusions: `.DS_Store`, `app/.DS_Store`, `design/.DS_Store` (Finder metadata), `.claude/settings.json` (personal agent environment). They remain untouched and untracked. No unrelated source path was found in the initial59.

Generated fixtures/media/projects/raw planes, logs/JSON observations, app bundles, DerivedData and object/cache files remain outside the manifest: `app/selftest-work/`, `app/.build/`, Engine/experiment build/artifact roots and `$BUILD_ROOT`. No broad directory staging or cleanup. Original ignored evidence/failure logs and runnable apps preserved.

Reproducibility limits: carrier/GPU tests require generated bottom.mov/top.mov/middle.png fixture set (frozen digest asserted in GenerationRecoveryTests), plus generated aud-wav48s.wav. This run reused their existing ignored generated copies; these are not owner files or publication payloads. Fresh checkout must regenerate those via retained dev/experimental fixture helpers before setting OTF_CLOCK_SOURCE/OTF_IMG_GPU01_FIXTURES; do not point at personal media or relax digests. otf-dev fixture generation supplies normal video/audio tests. Original diagnostic reports identify exact retained source locations and expected digests.

Isolated app drivers depend on matching prior SwiftPM/test object layouts under `$BUILD_ROOT/IMG1A-build`, SDK/XCTest paths from Xcode and arm64 macOS15 target. Release localization modifies only a disposable object copy and verifies original/global symbols. They are environment-sensitive diagnostic harnesses, not portable CI or current normal-app tests. The WMO drivers and explicit spectrum target must not be run unbounded; their known compiler resource failures remain. IMGImport01's historical immediate nil-preview assertion describes the pre-preview stage/transient state and is not valid current enabled-preview readiness evidence. PERSIST harness intentionally exercises gate-off safety. No historical harness PASS is relabeled as current preview validation.

Publication privacy scan covers every candidate: UTF-8/no NUL, no symlink/external traversal, personal absolute locations, common credential/private-key patterns and size/mode checks. Generic scan-pattern examples such as /Users/ and /Volumes/ in a historical report are not actual personal paths; preserved. No personal-path sanitization was needed. Historical measured values, failures and verdicts were not changed.

## Newly executed validation

- Bounded Debug engine: **69 executed PASS, zero FAIL, zero SKIP, exit0**. XCTest84.186 seconds; driver87.134750459 seconds. Existing single-job scratch root, 3GiB process/4GiB aggregate guard, 240-second bound; no safety stop. Process peak282018824 bytes, aggregate339937056, kernel lifetime293110792. Exact command/environment in `$E/engine-tests.py` and `engine-debug/command.json`; full output and resource samples retained.
- Classes: ClockCarrierCompatibility1, EndTimelinePlayback3, GenerationRecovery1, InFlightLease4, OperationalProjectAdapter9, OperationalStillImage9, ProductImagePreview2, ProductionContentSafety4, ProjectFile6, ProjectPersistence7, SpectrumModel12, StillImageImport2, SubtitleModel9.
- Exact PTS/raw frozen CPU Y/UV and existing >=40dB/flat<=3 contracts retained; engine GPU drain assertions executed. Export tests only exercise refusal/sentinel protection, not media export. CarrierDurationTests was reviewed but not selected anew; 150-frame product/end tests cover the selected duration/end route. No expensive90-frame workloads or broad export tests.
- **Release NOT RUN**. Normal Debug app build NOT RUN anew: source unchanged from the prior source-verified normal bundle, only documentation/preparation changed. No need to overwrite/rebuild it for this audit. No spectrum diagnostic or WMO app-host compilation retry. No new native GUI/panel or signed-app observation.
- Project pbxproj lint and changed zsh script syntax checks exited0. Python AST and shared-scheme XML checks, manifest/hash/mode, relative Markdown links, privacy/binary checks and git diff --check results are retained in final-checks.json. Initial document-link scan preceded creation of the two audit files and reported those four pending links; final scan must resolve them, not hide the initial observation.

## Reused signed-app evidence and history

[IMG-PERSIST-01](IMG-PERSIST-01-TRANSACTIONAL-PERSISTENCE.md) bounded persistence integration PASS, [PERSIST-02](IMG-PERSIST-02-SIGNED-SANDBOX.md) AUTOMATED PASS / OWNER TEST REQUIRED, [IMPORT-01](IMG-IMPORT-01-GATED-IMPORT.md) gated import PASS remain separate. Native Open/Save acceptance was not established by CLI or Finder delivery.

[PREVIEW-01](IMG-PREVIEW-01-CLOCK-CARRIER-COMPATIBILITY.md) PARTIAL and original surface failure are preserved; [01R](IMG-PREVIEW-01R-SURFACE-OBSERVATION.md) harness correction and [01G](IMG-PREVIEW-01G-GENERATION-RECOVERY.md) bounded generation PASS do not erase them. [02 BLOCKED](IMG-PREVIEW-02-GATED-PRODUCT-PREVIEW.md) and [02R PARTIAL](IMG-PREVIEW-02R-END-OF-TIMELINE.md) preserve end-prefetch failure and later endpoint/readiness correction. [BUILD-01](IMG-BUILD-01-COMPILER-MEMORY.md) phase isolation and [BUILD-02 BLOCKED](IMG-BUILD-02-MEMBERSHIP-RECOVERY.md) preserve resource-stop evidence and diagnostic capability limits.

[LAUNCH-01R](IMG-LAUNCH-01R-WINDOW-PRESENTATION.md) normal Debug build37.345640s exit0 and minimized-window/dirty-Cancel/video checks are reused. [PREVIEW-03 BLOCKED](IMG-PREVIEW-03-NORMAL-SIGNED-SMOKE.md) is not rewritten after [03R PARTIAL](IMG-PREVIEW-03R-NORMAL-SIGNED-VALIDATION.md): owner-assisted visible PID32976, actual JPEG/PNG/alpha surface, 0/149 seeks, five-second end/replay, layer transform/split/trim, mixed video with linked audio, subtitles/paused spectrum, missing/corrupt refusal, export guard and video-only recovery were observed then. Normal surface screenshots/AX are distinct from exact engine buffer hashes. Real import scope transfers/failure release/reset scopedURLs0 were observed in03R; normal product GPU in-flight race/drain and audible sound were not.

## Documentation and known limits

ROADMAP/HANDOFF now lead with current implemented versus automated versus actual-app versus owner-pending status. Older summaries explicitly remain dated historical states, including format9 disabled at earlier checkpoints. No prior diagnostic was edited to remove BLOCKED/PARTIAL/FAIL. Public image import remains disabled; image export/relink UI not implemented; image support is not product-complete.

Open limitations: automatic editor window creation; owner native Open/Save/cancel/replace and bookmark relaunch; actual speaker audio; normal product GPU cancel/drain; spectrum diagnostics compiler issue; WMO host compiler issue; provisional encoded8MiB/dimension2048/pixels4194304/estimateddecode128MiB admission. Internal preview additionally limits FHD30, eight simultaneous visual layers, aggregate64MiB uploaded image pixels; this is not measured total allocation safety or high-resolution photo approval. Temporary generated carrier lifetime/cache and repeated-session/long-duration resource behavior are not exhaustively tested. Existing misleading internal preview-unsupported UI wording is noted, not fixed in this audit.

Stage3C-2, spectrum export, image export and public image activation unchanged. Owner media/project/output unchanged. No staging/commit/push/history rewrite/cleanup. Proposed single development checkpoint subject: `feat: checkpoint gated image persistence import and preview`. It must retain these limits and historical failure documents; publishing requires a separate explicit instruction and exact hash/scope recheck.

Recommended next product task: bounded automatic editor-window presentation reproduction and correction preserving dirty-session transaction guards; then owner-only generated-fixture native-panel/audio acceptance. No new architecture or export work is authorized by this audit.

## Final verification receipt

Final57 candidates total 1,110,769 bytes before this final receipt paragraph; exact final per-file sizes/digests are authoritative in publication-hashes.json. All candidates regular UTF-8 text, no private-path/obvious-secret/binary/size violations; relative Markdown links resolve. Python AST, scheme XML, project plist and zsh syntax checks passed. No new SwiftPM unhandled-file warnings appeared in this incremental selected Debug run; a clean discovery/build was not rerun.

All506 baseline file hashes checked: only authorized ROADMAP/HANDOFF edits; all other preexisting source/tests/reports/settings unchanged. All Git refs unchanged, index empty, main unchanged, HEAD/upstream0/0. Final worktree17 tracked modifications and44 individual untracked files:57 publication candidates plus4 preserved excluded metadata/settings files. Ignored inventory records13,298 paths; no excluded path was deleted. Managed build/selftest/app-build and three experiment artifact roots measured10,408,308 KiB allocated (about9.93GiB), below20GiB; no exhaustive system-storage claim. Final diff/privacy/link/manifest checks exited0. No new application/test-host crash, timeout, compiler failure or resource stop occurred in this audit's selected tests. Release/app/owner checks remain NOT RUN anew.
