# IMG-CP-10 — Image export and signed-app acceptance checkpoint audit

TASK ID: IMG-CP-10
STATUS: PUBLICATION READY
Date: 2026-10-31 Asia/Seoul

Readiness is for one bounded internal development checkpoint, not public image support or complete product qualification. No implementation changes were made during this audit.

## Baseline and preservation

Repository `$REPO`; branch `feature/subtitles`; HEAD/cached upstream `65c4d876fe463d663fd30bef6ba43e2ed830a42c`; main `44943eadabdf5a37d5242d614e7279813126dfde`. Origin is the expected lunalism/ON-THE-FRAME GitHub repository. Local upstream divergence 0/0; index empty. No live remote query, fetch or history operation. A future publisher must verify live remote state before pushing.

CLAUDE and applicable instruction inventory reviewed; no applicable AGENTS found. Current diffs, ROADMAP/HANDOFF and EXPORT-01, BUILD-03, EXPORT-02 reports reviewed. Original BLOCKED/PARTIAL findings remain unchanged. New ignored evidence root `$E` = `$REPO/app/selftest-work/img-cp10-20261031-01`; initial hashes, complete tracked/untracked inventory and refs are in `$E/before.json`.

Initial inventory: **10 tracked modifications + 11 individual untracked files**. Four metadata/environment files are excluded; 17 relevant candidates plus this report and manifest yield **19 files**. No source or unrelated directory was broadly included.

## Source review

| Boundary | Reviewed result |
|---|---|
| Gate | ProjectStore eligibility, start and actual dispatch require compile `OTF_IMAGE_IMPORT` plus runtime `-OTFEnableImageImport`. Default project conditions do not enable the image flag. Engine `enabled` is an explicit internal capability, not an OS security boundary. No public activation. |
| Image admission | Every image catalog entry, including hidden/unused, must resolve to a current file. Shared planner performs fresh bounded probe, persisted descriptor comparison, identity recheck and guarded decode; restored metadata alone is insufficient. Missing/unverified inputs fail closed. No fake image source frame count, duration or SourceTiming. |
| Composition | Export uses existing image-aware planner/Metal composition and Reader→subtitle footprint→H.264/AAC Writer. Visual intervals/lane order/EXIF transforms/alpha remain shared with preview. Carrier is timing only, not persisted media or a shader layer. Native audio-only projection retains source timing, gain/mute/fades and lineage. |
| Video-only compatibility | Existing session export remains selected for image-free, subtitle-free plans. Existing subtitle path defaults `strictFrameGrid=false`; image export alone requires exact current reader PTS k/30. Ordinary direct export of preview-only plans remains refused. |
| Unsupported content | Both app and engine explicitly reject spectrum-containing image export before temporary output. General spectrum refusal remains. No spectrum layer is silently dropped. Subtitle renderability is checked before writes. |
| Transaction | Image-source canonical path/inode and identities checked before temporary output and again before promotion. Existing destination confirmation, identity recheck, exclusive first-create and confirmed replacement retained. Cocoa replacement directory is task-owned and removed by defer only for that export. Cancellation checked before promotion; progress1 follows successful verification/promotion only; errors reach app failure presentation. |
| Limits | Same-volume/native sandbox behavior is prior bounded evidence, not proof against all adversarial filesystem races, power loss or storage failures. Source checks are file-identity checks, not cryptographic content authentication. Product GPU cancellation/drain remains incompletely observed. |
| Schema/scope | No Media/Timeline/format-9 schema, GPU arithmetic/lease/scheduler, Stage3C-2 or spectrum implementation changes in this checkpoint. |

No new material correctness/data-safety defect was confirmed. This is bounded review and regression evidence, not exhaustive verification.

## Build and diagnostic separation

`SubtitleSelfTest.swift` differs from published HEAD only in the first conditional line (`DEBUG && OTF_SUBTITLE_DIAGNOSTICS`). Every subsequent byte and all 84 ordered literal check calls are preserved. AppDelegate directs the developer mode to the dedicated target; normal Debug reports the required target rather than pretending to execute it. The separate Debug target/scheme shares normal source/engine/sandbox dependencies and does not enable spectrum diagnostics or WMO.

The developer build script uses single-job monitored compilation with existing limits. The launcher checks actual executable presence before generating fixtures or launching. Its historical default successful-run cleanup is unchanged; use `KEEP=1` when retaining future diagnostic evidence. No launcher/build was executed here. Dedicated subtitle compilation remains blocked by the retained approximately 3.24GB safety-stop evidence; original UI checks are NOT RUN. Spectrum diagnostic and WMO host blockers remain separate and were not retried.

Existing normal signed Debug app was **not rebuilt or launched here**. Eight preserved app file hashes matched the BUILD-03 receipt. New codesign verification, identity and entitlement extraction each exited0. Ad-hoc development signature `dev.ontheframe.app`, sandbox, user-selected read/write, app-scoped bookmarks and Debug get-task-allow remain present. No distribution/notarization claim.

## Evidence classes — do not interchange

| Class | Evidence and limit |
|---|---|
| A: engine automation | EXPORT-01 Debug/Release each 69 distinct selected cases across overlapping runs; this audit newly executes 69 Debug cases below. Non-sandbox engine success is not native-panel acceptance. |
| B: normal signed Debug | BUILD-03 normal build exit0, gate-on7/gate-off2 app checks and video-only5 state/14 VideoOutput checks. Existing results reused, not rerun. Initial completion-sheet timeout and harness-only correction retained. |
| C: native dialogs | EXPORT-02 owner actually imported, Save As, reopened, exported both short projects and cancelled an export selection panel. No automatic native permission acceptance. Not repeated in this audit. |
| D: owner visual/audio | Owner reported portrait orientation/letterboxing, music/subtitle timing, transparent PNG over video and output sound/appearance matching preview. These are observations, not raw surface hashes or sample-exact audio proofs. |
| E: output measurement | Retained actual owner MP4 inspection: both150 frames/5s, H.264 FHD30 Rec.709 SDR, all PTS k/30; AAC48k stereo for5s and4s respectively; minimum sampled YUV PSNR54.23547462728533 and40.53709773754779dB. Saved/reopened non-bookmark serialized fields and UUIDs equal. No new output inspection claimed here. |

**Owner did not test in-encoding cancellation or replacement failure.** Actual panel cancellation is narrower. Engine automated cancellation/writer-failure/output protection does not close those owner-app gates. Long-term bookmark access and actual product scope/GPU retirement are not inferred from bookmark presence or engine counters.

## Newly executed bounded validation

Driver: `$E/run-debug.py`, derived from retained EXPORT-01 runner with fresh output/fixture roots and added ProductImagePreview selection. Command is `swift test --package-path app/Engine --scratch-path "$BUILD_ROOT/IMG1A-build" --jobs 1 -c debug --filter <explicit selected suites>`; exact argv/environment and logs are retained in `$E/regression3-debug`. `$BUILD_ROOT` is the existing managed `$HOME/Library/Developer/ON-THE-FRAME` root. No new cache/output override, clean or WMO app-host invocation.

**69 executed PASS, 0 FAIL, 0 SKIP, exit0.** Driver35.435894958s; tests32.556s; observed peak process586,597,504 bytes, aggregate645,318,600 bytes; no safety stop, crash or timeout. Build completed incrementally in0.29s; this is not a new normal-app build.

| Selection | Executed PASS |
|---|---:|
| GatedImageExport |4|
| ProductImagePreview raw/QA |2|
| AudioMix unity/adjusted/muted |3|
| HEVC video-only export |1|
| Styled subtitle export |1|
| OperationalProjectAdapter |9|
| OperationalStillImage |9|
| ProductionContentSafety |4|
| ProjectFile |6|
| ProjectPersistence |7|
| StillImageImport |2|
| SpectrumModel |12|
| SubtitleModel |9|

The audio test intentionally rejects a two-audio-track control; its logged failure outcome is an expected assertion, not an unexpected test failure. Tests include actual small image/mixed MP4s, frame/PTS/color/audio checks, invalid/unverified/spectrum refusal, encoding cancellation, writer initialization failure, disposable destination/source preservation and replacement. No GPU90 benchmark or unrelated export workload selected.

New codesign/static checks, script syntax, project plist, scheme XML, manifest paths/modes, text/binary/privacy and local Markdown references checked. `git diff --check` passes. **Release, owner GUI and normal app rebuild/runtime: NOT RUN during this audit.** Earlier evidence is explicitly historical.

## Exact proposed manifest

[IMG-CP-10-MANIFEST.txt](IMG-CP-10-MANIFEST.txt) is authoritative: **19 distinct existing repository-relative regular files**.

- Engine implementation2: `ExportService.swift`, `SubtitleExport.swift`.
- Engine focused tests1: `GatedImageExportTests.swift`.
- App source/harness5: `ContentView.swift`, `ImageExportSelfTest.swift`, `OnTheFrameApp.swift`, `ProjectStore.swift`, `SubtitleSelfTest.swift`.
- Build configuration/scripts4: project.pbxproj, subtitle diagnostic scheme, `subtitle-test.sh`, `build-subtitle-diagnostics.sh`.
- Documentation5: ROADMAP, HANDOFF and three historical reports (EXPORT-01, BUILD-03, EXPORT-02).
- Preparation2: this report and exact manifest.

Each candidate's SHA-256, byte size and intended Git mode is stored in **`$E/publication-hashes.json`**, outside the publication set to avoid self-reference. Both shell scripts are100755; all other candidates100644. Existing tracked modes preserved. Any subsequent candidate edit invalidates the receipt; a publisher must compare every digest and mode before staging.

## Exclusions, privacy and reproducibility

Excluded and preserved: `.DS_Store`, `app/.DS_Store`, `design/.DS_Store`, `.claude/settings.json`; ignored `app/.build/`, `app/Engine/.build/`, `app/selftest-work/`, and the three `experiments/e*-*/artifacts/` roots. Generated source media/projects/MP4s, binary apps, raw logs, pixel/JSON evidence and machine configuration are not candidates. No excluded file was removed.

Candidate contents contain no unnecessary personal absolute paths, obvious credential/private-key patterns, NUL/binary payloads, generated media or invalid local Markdown references. This is a bounded heuristic secret scan, not proof against arbitrary embedded secrets. No historical diagnostic rewrite or path sanitization was needed. The EXPORT-02 report's `$HOME`/`$REPO` placeholders are retained.

Opt-in tests require generated fixtures and environment variables: `OTF_EXPORT_FIXTURES`, `OTF_IMAGE_EXPORT_RUN`, `OTF_PRODUCT_IMAGE_PREVIEW_RUN`, `OTF_CLOCK_SOURCE`, `OTF_MODEL03_RUN`. Old absolute fixture locations are not embedded in publishable source. Standard `otf-dev fixtures` provides export inputs; ClockCarrierCompatibility fixture helpers/previous generated reader provide clock inputs. New writable run roots must be unique. These dependencies and exact local audit execution remain in the ignored driver/command receipt, not as shipped media. No owner media is required. Default opt-in SKIPs must not be called executed PASS.

## Documentation and remaining work

Only relevant ROADMAP/HANDOFF sections updated: implemented gated export, engine MP4 automation, signed-app evidence, bounded owner acceptance and untested owner encoding-cancel/replacement failures are distinguished. Historical PARTIAL/BLOCKED records remain. Public image gate, provisional8MiB/2048px/4,194,304pixel/128MiB decode policy,64MiB upload/eight layers, automatic window issue, long-term bookmarks, product GPU drain, diagnostic compiler blockers and Spectrum Stage4 export remain open.

Proposed single commit subject: `feat: checkpoint gated image export and signed-app acceptance`.

Recommended next task: bounded automatic editor-window presentation recovery; then separately close actual app encoding-cancellation/replacement-failure and scope/GPU drain validation. Publishing still needs a separate explicit commit/push instruction.

No staging, commit, push, public image activation, new functionality, schema migration, spectrum export or owner personal data modification. Existing uncommitted source, historical evidence and recovery references preserved; working tree remains uncommitted, with excluded local files present.
