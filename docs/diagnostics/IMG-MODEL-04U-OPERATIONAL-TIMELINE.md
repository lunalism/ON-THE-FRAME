# IMG-MODEL-04U — Operational still-image media and Timeline

Date: 2026-10-30 (Asia/Tokyo)
Status: OPERATIONAL TIMELINE PASS (engine-only)

## Baseline and exact scope

Repository `$REPO`; branch `feature/subtitles`; HEAD and cached upstream
`faca37177b1ce85dbfd0a198cbcd00062f3c7e0a`; main
`44943eadabdf5a37d5242d614e7279813126dfde`. Index was empty. Existing MODEL-03,
04T, 04T-R and 04S uncommitted work was preserved. CLAUDE.md read; no applicable
AGENTS.md found. No remote refresh or Git mutation.

Changed from the task preflight:
- app/Engine/Sources/OnTheFrameEngine/Media.swift
- app/Engine/Sources/OnTheFrameEngine/Timeline.swift
- app/Engine/Sources/OnTheFrameEngine/ProductionContent.swift
- app/Engine/Sources/OnTheFrameEngine/ProjectFile.swift (one boundary guard only)
- app/Engine/Sources/OnTheFrameEngine/CompositionPlanner.swift (three boundary guards only)
- app/OnTheFrame/InteractivePreview.swift (remove duplicate unsupported-error callback)
- app/OnTheFrame/ProjectStore.swift (guard commit and commitLane before history insertion)
- app/diagnostics/IMGModel04T/SafetyGateAppTests.swift (actual operational fixtures/assertions)

New:
- app/Engine/Tests/OnTheFrameEngineTests/OperationalStillImageTests.swift
- docs/diagnostics/IMG-MODEL-04U-OPERATIONAL-TIMELINE.md

The four isolated MODEL-03 files, run-tests.py, old reports, GPU/probe sources,
normal import/relink and export renderers were not changed.

## Operational representation

OperationalMedia is a closed sum of a temporal MediaRef and a StillSource. Kind
is video/audio/stillImage; temporal kind derives from real hasVideo state. Still
payload retains the matching probe descriptor and ImageReference, including
original FileIdentity. It has no temporal payload, frame count, duration,
SourceTiming or video track. hasVideoTrack, hasVisualContent and hasAudio have
separate meanings. Existing MediaAsset and MediaRef initializers remain temporal
and source compatible.

Timeline stores one authoritative ordered mediaCatalog. The existing public media
property is a documented temporal-only projection for legacy callers, not another
mutable catalog. Immutable rebuilt edits merge temporal updates with every image
entry, preserving catalog order, unused references and image UUIDs. No image is
assigned a mediaFrames entry. Video/audio maps explicitly mark images false.

Only internal registeringImage accepts a previously fully validated probe result;
it rechecks cancellation/file identity, rejects duplicate/cross-kind UUIDs and
keeps the original file untouched. Normal app import has no access to this API.
The nonthrowing legacy temporal registering API leaves a colliding image unchanged
rather than replacing it with a temporal source; image relink through the temporal
relink method is rejected. Normal image relink remains out of scope.

## Editing semantics and arithmetic

Explicit insertion uses 150 display frames; custom engine placement accepts at
least one frame, bounded by Timeline.maxFrames. Images require sourceIn 0,
visual lane, no audio/link/origin and no same-lane overlap. Cross-lane order is
unchanged. Display length never clamps against source duration.

Image splitting has a dedicated display-boundary branch: two independent new
clip UUIDs, same media UUID, sourceIn 0, retained transform/lane. It does not
enter temporal source-time split calculations. Copy/paste uses new clip IDs,
retains the catalog and sourceIn 0, and reuses existing lane conflict selection.

Image left/right trims reuse existing ripple/conflict rules. As with the existing
ripple trim API, clip start remains fixed and display length changes; following
content shifts by the length delta. A left trim does not advance sourceIn.
Outward trims can extend beyond the insertion default, up to project limits;
edge operations clamp at minimum one frame. Explicit trimming rejects nonzero
sourceIn. Insertion, placement, trim, relocation and paste bound inputs before
arithmetic; extreme Int inputs are rejected without trapping.

Move, relocation, lift, ripple deletion and EditHistory snapshots retain the full
catalog. Temporal source(atFrame:) explicitly returns nil for images, which have
no source frame. The visual segmentation utility preserves image sourceIn 0.
Images cannot enter audio clips, linked pairs or source-frame maps; spectrum
source enumeration remains based solely on actual audio lineage. Spectrum and
subtitle implementations were not modified.

## Connected production guards and call paths

ProductionContent(Timeline) now obtains image UUIDs from the actual complete
catalog, including unused images. The isolated-model adapter remains for earlier
design tests but is no longer required to detect operational content.

Normal ProjectFile.encode checks before reading the temporal media projection or
creating JSON bytes. Schema, currentVersion 8, legacy 1–8 reading and image-free
5–8 writing are unchanged. A generated existing destination is retained on an
unsupported save. Isolated format-9 codec is unchanged and not exposed.

Normal planner plan, layeredSegments and layerStack check before emptiness,
visibility culling, missing-media lookup, lane selection or native allocation.
Tests include a full-canvas opaque temporal layer over an image with an actual
geometry MediaAsset descriptor; guards still throw before composition/IO.

InteractivePreview's existing central checks now see real operational images.
Legacy begin rejects before decode/cache reuse. Content drawList emits and throws
the typed error; the legacy wrapper no longer emits it twice. Rejection cancels
pending work, clears cache and fences publication by token.

ProjectStore guards complete content before preview filtering, empty/cache
shortcuts, save work and export preparation. Generic commit and commitLane also
reject candidate images before history/selection replacement. Other editing
paths derive from the supported current project; normal project replacement
receives only the unchanged legacy decoder's validated result. Format 9 cannot
enter that route. Export and subtitle export continue through guarded planner
preparation; no renderer changes were needed.

## Executed checks

Evidence: `$REPO/app/selftest-work/img-model04u-20261030-01/` (ignored).
Build root `$BUILD_ROOT`: existing internal APFS IMG1A-build directory.

| Final validation | PASS | FAIL | SKIP | Exit |
| --- | --- | --- | --- | --- |
| Debug engine | 77 | 0 | 0 | 0 |
| Release engine | 77 | 0 | 0 | 0 |
| Debug actual-app-source safety harness | 5 | 0 | 0 | compile/run/driver 0 |
| Release actual-app-source safety harness | 5 | 0 | 0 | compile/run/driver 0 |
| git diff --check | yes | — | — | 0 |

Each engine run comprises nine new OperationalStillImageTests plus the previous
68 bounded safety/model/legacy tests. Covers insertion/minimum/overflow, source
identity, same/cross-lane placement, trim/split/move/paste, ripple conflicts,
delete/undo/redo, invalid audio/spectrum usage, used/unused/occluded save/planner
rejection, legacy 1–8, image-free 5–8 selection, subtitles and audio lineage.

Engine invocation: `swift test -c <debug|release> --package-path app/Engine
--scratch-path $BUILD_ROOT --filter <summary.json filter>`; Release adds
`-Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE`. OTF_MODEL03_RUN uses
separate fresh directories. Final logs: debug-final.log and release-final.log.
Earlier seven-case and 77-case passing runs are retained separately, not counted
again. Final source changes after these runs are explanatory comments only.

App invocation: `python3 app/diagnostics/IMGModel04T/run-tests.py <debug|release>
<fresh output directory>`. Final logs: app-debug-final/run.log and
app-release-final/run.log. The recovered main-thread NSApplication initialization
is retained. Tests now use the actual registered/inserted Timeline, not an
isolated-model-only adapter. They exercise legacy begin rejection, typed and
legacy drawList exactly-once errors, cache clearing, pending callback fencing,
used/unused capability detection, failed generic/lane commits, unchanged project
UUID/history/bookmarks and generation invalidation.

No compilation error, test failure, process crash or timeout occurred. Existing
concurrency/deprecation warnings remain. No full app bundle/UI validation,
AVPlayer playback, native image decode race, GPU benchmark or media export ran.
The deterministic pending task test and seeded CGImage cache are not a claim of
an actual in-flight native rendering race. No expensive opt-in suite was run.

## Preservation, limits and next boundary

All existing preflight files except the eight authorized modified paths retain
their hashes. MODEL-03's historical snapshot has 3,816 unaffected files still
identical, including prior GPU evidence; six current production paths are the
explicit historical-source exceptions. MODEL-03 files and 04S/04T/04T-R reports
remain unchanged. Backup/recovery/main/upstream refs are unchanged; the index
remains empty. Managed allocated data is approximately 8.3 GiB, below 20 GiB.
Ignored generated fixtures/binaries/logs remain local; no destructive cleanup.

Normal image import, production format-9 open/save, product GPU preview/export,
Stage 3C-2 and spectrum export remain disabled/unimplemented. Probe admission
limits are unchanged. Owner Mac UI/product rendering validation is still a
separate future boundary; this PASS means engine editing and safety gates only.

Recommended next bounded task: verify lossless conversion between this operational
catalog and the isolated format-9 model/codec before any production serialization
activation. No owner media/project/output changes, staging, commit or push.
