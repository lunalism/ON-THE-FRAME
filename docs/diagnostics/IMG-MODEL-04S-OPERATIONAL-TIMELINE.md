# IMG-MODEL-04S — Operational timeline preflight

Date: 2026-10-30 (Asia/Tokyo)
Verdict: BLOCKED before implementation.

## Verified baseline

Repository: `$REPO`; branch `feature/subtitles`; HEAD and cached upstream
`faca37177b1ce85dbfd0a198cbcd00062f3c7e0a`; main
`44943eadabdf5a37d5242d614e7279813126dfde`.
Index and tracked working tree were clean. The four untracked IMG-MODEL-03
source/test files remain unchanged. No network Git operation was performed.
CLAUDE.md was read; no applicable AGENTS.md was found.

## Confirmed call-graph boundary

The newly authorized CompositionPlanner guards could protect `plan`,
`layeredSegments` and `layerStack`, including visibility culling. However,
interactive preview has a direct decoding path before those guards:

1. ProjectStore.beginStill calls InteractivePreview.begin.
2. InteractivePreview.begin builds temporal frame keys directly from clips,
   looks up MediaAsset values and calls InteractivePreview.decode.
3. decode creates AVURLAsset/AVAssetImageGenerator and requests a video frame.
4. Only later does drawList call CompositionPlanner.layerStack; its `try?`
   converts every planner error into nil. show/request propagate only false.

An absent image MediaAsset is skipped by begin, not explicitly rejected.
Adding the requested typed error solely in CompositionPlanner cannot prevent
this earlier direct decode path or deliver a clear error through this caller.
There is no claim that an image GPU/native decode was executed: this is static
control-flow inspection, before operational image support exists.

The minimum additional dependency is an early capability check in
InteractivePreview.begin/request with an explicit failure route to the caller;
ProjectStore.beginStill/stillRebuild must handle that failure visibly and
preserve state. Both files are explicitly prohibited in this task.
No workaround using fake temporal fields, crashing getters or hidden side
effects was introduced. Per sections 1 and 10, implementation stopped.

## Other reviewed paths and remaining review

ProjectStore preview preparation and export preparation call planner.plan.
ExportService receives PlannedComposition; subtitle-bearing export routes to
SubtitleExporter from that plan, rather than receiving the original Timeline.
ProjectStore.timelineChanged also has empty-snapshot and cached-video-input
returns before planner.plan. Its previewVideoInputs helper (in
PausedSpectrumOverlay.swift) reconstructs a Timeline from the existing media
projection; any future canonical media representation must be retained there
or explicitly checked before this shortcut. This is an integration concern,
not a demonstrated runtime regression of current video/audio projects.

Existing Timeline clipboard/editing and isolated model were located. Exhaustive
operational editing/spectrum/undo compatibility verification was not completed
after the mandatory stop; no coverage is claimed for those requirements.

## Validation and scope

No source files changed. No tests, builds, GPU workloads, playback sessions or
exports ran. Prior IMG-MODEL-03 results are historical evidence, not new PASS
results. Only this diagnostic document was created. Production format 9,
normal image import and Metal preview/export remain disabled/unintegrated.
No Stage 3C-2, spectrum, owner data, staging, commit or push changes.

Recommended next bounded task: authorize only preview capability-error
propagation in InteractivePreview and ProjectStore, review cached/empty preview
branches against the complete catalog, then implement operational model edits
and the three planner guards together with focused Debug/Release regressions.
