# IMG-MODEL-05R — Lossless adapter and missing-image restoration

Date: 2026-10-30 (Asia/Tokyo)
Status: LOSSLESS ADAPTER PASS — isolated engine scope

## Baseline and exact changes

`feature/subtitles`; HEAD/cached upstream `faca37177b1ce85dbfd0a198cbcd00062f3c7e0a`;
main `44943eadabdf5a37d5242d614e7279813126dfde`. Index empty. Existing uncommitted
03/04T/04T-R/04U/05 work retained. CLAUDE.md read; no applicable AGENTS.md found.
No fetch, reset, clean, merge, rebase, branch change or Git mutation.

Modified:
- app/Engine/Sources/OnTheFrameEngine/Media.swift
- app/Engine/Sources/OnTheFrameEngine/Timeline.swift
- app/Engine/Sources/OnTheFrameEngine/StillImageProjectModel.swift
- app/Engine/Sources/OnTheFrameEngine/StillImageProjectCodec.swift
- app/Engine/Tests/OnTheFrameEngineTests/OperationalStillImageTests.swift

Added:
- app/Engine/Sources/OnTheFrameEngine/OperationalProjectAdapter.swift
- app/Engine/Tests/OnTheFrameEngineTests/OperationalProjectAdapterTests.swift
- docs/diagnostics/IMG-MODEL-05R-LOSSLESS-ADAPTER.md

The existing operational test changes only descriptor.identity to
optional descriptor?.identity, retaining the original identity assertion.
ProjectFile, ProductionContent, ProjectStore, InteractivePreview, planner,
renderers, GPU/spectrum sources, app harness and historical reports are unchanged
from this task's preflight hashes.

## Persisted reference versus runtime validation

StillSource always holds the portable ImageReference/ImageInfo. Optional
ValidatedImage is separate: persisted-only sources are unverified and have no
runtime descriptor/FileIdentity. A runtime proof can only originate from the
existing full StillImageProbe pipeline. Supplying one during restoration requires
matching stored path, descriptor, size/mtime and current actual file identity.
No decoded metadata manufactures a proof, source frame count or SourceTiming.

Unverified means not checked, not a false claim that a file is missing or present.
Restoration does no filesystem probing when no runtime proofs are supplied.
Known absent source paths restore successfully. Explicit revalidation then
reports a typed sourceUnavailable error while the document remains valid and
unchanged. Serialized bookmark bytes grant no access; callers still own scopes.

ImageReference.validate is shared by model validation and persisted construction,
retaining existing provisional probe limits. Timeline.restoring validates the
complete model before dictionary creation, arithmetic or normalization, builds
the full catalog and candidate Timeline, then checks operational invariants.
Malformed references, duplicate IDs, bad lanes/overlap, temporal bounds, image
sourceIn/audio/origin/link and forbidden image spectrum sources fail atomically.
It preserves the legacy rule that an absent audio lineage source may be a warning
state, not automatically document corruption. Coincident UUID namespaces retain
the existing authoritative audio-lineage interpretation.

## Adapter and semantic contract

OperationalProjectAdapter.State contains project UUID/settings, immutable
Timeline and per-media relative-path/bookmark sidecars. Unknown sidecar or
capability entries, frame-only catalogs and contradictory frame/capability maps
are explicitly rejected, not dropped. Candidate creation returns typed Failure;
it never mutates the caller or writes output files.

The adapter maps every catalog entry in order, clips/intervals, lane metadata,
transforms, audio settings/links/origin, subtitles/effects and spectrum source
keys. Complete portable model equality is asserted across operational -> model
-> codec -> decoded model -> restored operational state -> model, including
used and unused images, split/trim/copied states and mixed media/layers.

Runtime proof identity/profile display metadata and file-access ownership are
not part of the existing portable schema and are never serialized or fabricated.
Decoding resets validation to unverified; this is deliberate capability handling,
not loss of ImageInfo. Empty absent overlay arrays and clip ordering follow the
existing canonical lane/content semantics. JSON object-key formatting is not a
new byte-identity requirement. Save As recomputes relative hints; absent a new
destination, stored hints and opaque bookmark data are retained.

Relink/revalidate are internal explicit operations, not UI actions. Full probe
validation is required. JPEG->PNG and PNG->JPEG are supported, preserving media
UUID, clip UUID/timing/transform and providing dimension/orientation change
metadata. Relink clears old path/bookmark hints according to the existing model
contract. Existing-path revalidation requires the stored snapshot to match;
changed content is not silently migrated. Retained runtime proofs are checked
fail-closed; stale proofs can reject a candidate atomically rather than grant
access to unavailable data.

## Demonstrated compatibility corrections (isolated codec only)

1. hint-first.log: one executed failure confirmed that image-free encoding with
   no destination dropped a stored relative hint, while bookmark bytes survived.
   The isolated codec now retains only those hints in the already-supported
   legacy Document after using the unchanged production writer. Save As retains
   the normal relative-path computation and conditional 5–8 selection.
2. debug-adapter.log: seven PASS and one failure from a new test fixture adding a
   subtitle beyond its zero project duration. The fixture duration was corrected;
   no product duration rule was relaxed.
3. legacy-first.log: one executed failure confirmed valid format-1 reversed lane
   order/lane-less clips were rejected when the isolated model used raw Document
   ordering. It now uses the existing decoder's normalized lanes/clips. Legacy
   transforms and original temporal meaning remain delegated to that decoder.
4. header-first.log: one executed failure confirmed that changing a format-9
   header to 8 and supplying temporal fields could erase the declared image kind.
   The isolated codec now rejects kind/image declarations under legacy headers
   before the permissive legacy decoder. Genuine formats 1–8 have no such fields.

These are minimal semantic fixes without schema or production reader changes.
All first-failure logs remain intact. Production currentVersion remains 8; normal
format-9 open fails newerVersion(9). Restored image catalogs still fail the normal
save/preview/export capability guards. No normal app path calls the adapter.

## Executed validation

Evidence: `$REPO/app/selftest-work/img-model05r-20261030-01/` (ignored).
Build root `$BUILD_ROOT`: existing internal APFS IMG1A-build directory.

| Final check | PASS | FAIL | SKIP | Exit |
| --- | --- | --- | --- | --- |
| Debug engine regression | 86 | 0 | 0 | 0 |
| Release engine regression | 86 | 0 | 0 | 0 |
| git diff --check | yes | — | — | 0 |

Each final run = 9 new adapter tests + 77 existing safety/operational/isolated/
Timeline/lane/clipboard/transform/ProjectFile/subtitle/spectrum tests. Earlier
failed and passing targeted runs are separate evidence, not added again.
Exact commands and fresh fixture paths are in debug-command.json and
release-command.json. Logs: debug-final.log, release-final.log, final-driver.log.
Invocation uses swift test -c <debug|release>, app/Engine, the existing scratch
root and the bounded filter in summary.json. Release adds -enable-testing and
-DOTF_PROTO_RELEASE. OTF_MODEL03_RUN points to separate fresh generated roots.

Coverage includes portable mixed-state equality, used/unused missing references,
invalid descriptors, corrupt bytes, dangling/duplicate media and clip IDs,
sourceIn != 0, Int overflow, wrong lanes/overlap, image audio/spectrum rejection,
atomic candidate failure, relative hints/bookmarks/Save As, explicit revalidation,
cross-format relink, legacy 1–8 and conditional 5–8, normal reader rejection and
normal image-save/planner protection.

No compilation error, process crash or timeout occurred. Initial regression
failures above were observed, fixed and retained. Existing compiler warnings
remain. NOT RUN: normal app UI/bundle tests, sandbox/bookmark lifecycle, actual
product playback/export, GPU benchmarks and the expensive opt-in media suite.
Prior app/GPU/sandbox evidence is preserved, not claimed as newly executed.

## Preservation and remaining boundary

All preflight source/test/report/environment hashes except the five authorized
modified paths are unchanged; branch/main/upstream and backup/recovery refs
are unchanged. Original fixtures and failure evidence remain local and intact.
Managed allocated data remains approximately 8.3 GiB, below 20 GiB; no cleanup.

Normal format-9 open/save, image import UI, product GPU preview/export, Stage
3C-2 and spectrum export remain disabled/unimplemented. This is a data/model
adapter PASS, not product image-project usability or renderer validation.

Recommended next bounded task: review transactional persistence integration and
owner Mac validation criteria before enabling any normal format-9 entry point.
No owner media/project/output changes, staging, commit or push.
