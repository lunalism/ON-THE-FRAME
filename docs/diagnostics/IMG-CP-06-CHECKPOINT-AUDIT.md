# IMG-CP-06 — Operational image model checkpoint audit

Date: 2026-10-30 (Asia/Tokyo)
Status: PUBLICATION READY

## Baseline and task scope

Repository `$REPO`; branch `feature/subtitles`; HEAD/cached upstream
`faca37177b1ce85dbfd0a198cbcd00062f3c7e0a`; main
`44943eadabdf5a37d5242d614e7279813126dfde`. Published checkpoint message:
`test: checkpoint Metal image rendering and still-image probe`.
Preflight: six tracked source modifications, 22 individual untracked files
(18 relevant files and four excluded environment/Finder files), empty index.
CLAUDE.md read; no applicable AGENTS.md found.
No network refresh or Git mutation. Source files were reviewed but not changed.
Only relevant ROADMAP/HANDOFF image sections and these two audit files changed.

## Exact publication set

[Manifest](IMG-CP-06-MANIFEST.txt): **28 distinct existing repository-relative files**.
Manifest SHA-256: `2c55aa6caceb8aabb58041db29dea686f7770f0a9b783794ca12af5e86af0a8f`.

Composition:
- 10 production engine/app source files (existing safeguards plus engine-only models).
- 6 engine test files.
- 2 standalone app safety harness files (Swift and Python).
- 6 historical diagnostic reports, retained without rewriting their verdicts.
- 2 project summary documents: ROADMAP and HANDOFF.
- 2 preparation files: this audit and its manifest.

File types: 17 Swift, 1 Python, 9 Markdown, 1 text manifest.
Final Git composition: eight tracked modifications and 20 relevant untracked
files, all uncommitted. No broad staging was performed; nothing was staged.
A per-file publication SHA-256 snapshot is retained in ignored audit evidence.
No standalone MODEL-03 report exists in this working tree; its four model/test
files and newly executed regression coverage are included, not an invented report.

## Consistency review

No unresolved material consistency defect was identified in the reviewed scope.
This is a bounded review and regression result, not proof over all possible input.

OperationalMedia has one closed temporal/still payload and a computed kind.
Timeline has one authoritative ordered catalog; legacy media is a temporal
projection. Images have no frame-count/duration/SourceTiming payload and are not
video/audio tracks. Their visual eligibility is explicit. Images never enter
mediaFrames. Default 150-frame insertion is display duration; minimum one frame,
sourceIn zero, checked range limits and same-lane overlap hold.

Split uses a dedicated image display-boundary path and two new clip UUIDs; trim
changes display length with the existing fixed-start ripple/conflict semantics.
Move/copy/paste/delete/undo retain media identity and catalog entries. Complete
catalog retention through rebuilt/excludingMedia prevents unused or filtered
images from disappearing before capability checks.

Persisted references and optional actual probe validation are separate. Restoration
validates the complete model before candidate allocation/normalization, retains
missing sources as unverified and grants no access. Adapter sidecars preserve
paths/bookmark bytes; exact portable model equality covers UUID/settings, lanes,
intervals, transforms, audio links/origin/lineage, subtitles/effects and spectrum
sources. Runtime validation is intentionally not serialized. Invalid states,
unknown registry/sidecar entries and contradictory payloads are explicitly rejected.

The isolated codec retains conditional image-free 5–8 selection, stored relative
hints without Save As, normalized legacy 1–8 meaning, and format 9 for any image
reference. It rejects declared image payload under downgraded legacy headers.
Its image validation delegates shared ImageReference/ImageInfo invariants;
operational restoration uses the same validated project rules. No raw metadata
is upgraded to ValidatedImage or runtime FileIdentity.

Temporal video/audio calculations and spectrum implementation are unchanged.
Existing audio lineage remains authoritative even where UUID namespaces coincide;
image audio/spectrum sources are rejected. Legacy missing spectrum-source warning
semantics are retained rather than converted into a new document error.

## Production boundaries

Normal ProjectFile currentVersion remains 8 and reading format 9 still fails.
Normal encode rejects the whole image catalog before JSON creation. Planner plan,
layeredSegments and layerStack reject before culling, media filtering or track
construction. Hidden and unused images are included in this check.

Interactive preview checks before decode/cache reuse, clears stale state and
propagates unsupported errors exactly once. ProjectStore rejects candidate image
commits before history mutation, checks before missing/cache/empty preview paths,
and retains its transactional save/open behavior. Export preparation reaches the
guarded planner before ExportService and SubtitleExporter. Rendering arithmetic,
normal import/relink and existing GPU/spectrum product integration were not added.

One canonical operational payload and a separate portable serialization payload
are intentional; the adapter explicitly maps between them. A temporal-only
projection must never be used as the complete project at a new future boundary.

## Newly executed validation

Evidence: `$REPO/app/selftest-work/img-cp06-20261030-01/` (ignored).
Build root `$BUILD_ROOT`: existing internal APFS IMG1A-build directory.

| New CP-06 run | PASS | FAIL | SKIP | Exit |
| --- | --- | --- | --- | --- |
| Debug engine regressions | 86 | 0 | 0 | 0 |
| Release engine regressions | 86 | 0 | 0 | 0 |
| Debug actual-app-source safety harness | 5 | 0 | 0 | compile/run/driver 0 |
| Release actual-app-source safety harness | 5 | 0 | 0 | compile/run/driver 0 |
| git diff --check | yes | — | — | 0 |

Engine command: swift test -c <debug|release> --package-path app/Engine
--scratch-path $BUILD_ROOT --filter <bounded filter in summary.json>. Release
adds -Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE. OTF_MODEL03_RUN uses
fresh per-configuration fixture roots. Exact invocations/logs are retained.
Coverage includes both Operational suites, production content guards, isolated
model/codec, ProjectFile legacy, Timeline/lane/clipboard/transform, subtitles and
spectrum/audio lineage. Compilation success and executed test PASS are distinct.

App command: python3 app/diagnostics/IMGModel04T/run-tests.py <debug|release>
<fresh output directory>. Matching engine objects are built first. The existing
main-thread NSApplication initialization is retained. All five checks executed:
legacy preview, actual operational image refusal/cache clear, typed error/one
callback, pending-result invalidation and real ProjectStore state preservation.
No normal app UI/session or media project was opened. The deterministic pending
task and seeded cache tests are not actual native decode race tests.

No new compilation errors, crashes or timeouts. Existing deprecation/concurrency
warnings remain. No SwiftPM unhandled-file warning was observed in these runs;
the Python support file is outside SwiftPM source/test discovery.

Historical evidence is separate: 04S BLOCKED; 04T PARTIAL with signal-5 host crash;
04T-R recovery PASS; 04U operational PASS; 05 BLOCKED; 05R adapter PASS with its
first-failure/fix logs. These reports were not rewritten. GPU, sandbox UI, owner
Mac observations and earlier test counts were not rerun or counted in CP-06.

## Privacy, references and exclusions

Manifest path/existence/uniqueness, UTF-8/nonbinary scope, private absolute path,
obvious secret, local Markdown reference and source/dependency checks passed.
No generated fixture, log, JSON, binary, media or build artifact is included.
Harness dependencies are repository sources already in this checkpoint or the
published baseline; fixtures are generated in fresh directories. The fixed
$BUILD_ROOT convention and matching test-enabled Release engine build are stated
reproduction requirements, not local-only media dependencies.

Excluded but retained:
- .DS_Store, app/.DS_Store, design/.DS_Store — Finder metadata.
- .claude/settings.json — personal environment settings.
- app/selftest-work/ — generated fixtures, raw/JSON/logs, crash binaries and history.
- app/.build/, app/Engine/.build/ — local build/test output.
- experiments/e1-fhd/artifacts/, experiments/e2-4k/artifacts/,
  experiments/e3-fhd-10min/artifacts/ — historical generated experiment evidence.
- $BUILD_ROOT and other internal ON-THE-FRAME Developer outputs — compilation output.
- Owner media/projects/exports and recovery refs — never publication files.

No excluded path was deleted or modified. Existing source/test/report/environment
hashes remain unchanged except the two authorized summary documents. Protected
branch/main/upstream/backup/recovery refs are unchanged; the index remains empty.
Managed allocated artifacts remain below the 20 GiB budget; no cleanup occurred.

## Documentation and publication recommendation

ROADMAP/HANDOFF now distinguish implemented engine image editing and isolated
format-9 adapter PASS from disabled normal format-9 open/save, missing import UI,
unsupported product preview/export and unverified actual Mac end-to-end workflow.
Their previous GPU/probe preparation paragraph is explicitly historical and notes
the published faca371 checkpoint. Historic CPU findings/numbers/verdicts remain.
Stage 3C-2 and spectrum export status are unchanged.

A single checkpoint commit is suitable for the exact manifest, subject to a
separate explicit publication instruction. Proposed message:
`feat: checkpoint engine still-image model and isolated format-9 adapter`.
No author/config change, staging, commit or push was performed.

Remaining boundaries: normal persistence integration/transactions, image import
UI, real sandbox/bookmark integration, rendering, native in-flight behavior,
end-to-end owner Mac validation and unchanged restrictive probe limits. Stale
runtime proofs fail closed and may reject a candidate; they are not portable
state or permission. No production-complete image support is claimed.
Recommended next product task: bounded transactional format-9 persistence design
and owner Mac acceptance criteria, without enabling a normal image entry point.
No owner media/project/output modifications, destructive cleanup or feature expansion.
