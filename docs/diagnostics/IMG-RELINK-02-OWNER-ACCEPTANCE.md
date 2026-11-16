# IMG-RELINK-02 — Owner-guided image relink and reopen

TASK ID: IMG-RELINK-02
STATUS: PARTIAL
Date: 2026-11-01 Asia/Seoul

## Scope and evidence

Actual owner-operated JPEG→PNG relink, changed-geometry approval, Save As, normal process exit, new-process Open and export succeeded. This is not an unconditional acceptance PASS: mouse-menu undo did not have the observed expected effect, a stale preview failure status was confirmed after keyboard redo, and a supplemental simple RGB threshold check failed. No implementation correction was applied during this validation-first task. These findings remain open.

Branch `feature/subtitles`; HEAD/upstream `0f32bd6b2ee840fd40cf0c356e427ee32f6740c6`, main `44943eadabdf5a37d5242d614e7279813126dfde`, divergence0/0, index empty. All existing IMG-RELINK-01 source/test/document changes preserved. CLAUDE, ROADMAP/HANDOFF, RELINK-01 and BOOKMARK-01 reports reviewed; no applicable AGENTS found.

`$E = $REPO/app/selftest-work/img-relink02-20261101-01`. Signed app reused unchanged from `$HOME/Library/Developer/ON-THE-FRAME/AppPreservation/IMGRelink01-20261101-01/Final2/OnTheFrame.app`: all8 retained file hashes match, strict codesign verification exit0; sandbox, user-selected read/write, app-scope bookmarks and get-task-allow true. Development ad-hoc signing is not distribution qualification. Explicit internal runtime gate enabled; isolated suite `dev.ontheframe.relink02.owner.20261101.01`, reset only for A. No existing ON THE FRAME process at preflight. No app terminated by the agent.

## Owner sequence

1. A PID2642: owner selected generated original.jpg via native internal import, observed expected5s red/green portrait, and saved before-relink.ontheframe.
2. Baseline project/UUIDs/bookmark/hash retained. Only this task's generated JPEG was renamed into retained/original.jpg, bytes unchanged. To avoid macOS following the renamed inode, a **separate generated** missing-relink.ontheframe omitted its image bookmark. All other values retained; owner-saved baseline untouched. This is an explicit missing-reference fixture, not a bookmark failure claim.
3. Owner opened missing-relink, observed actual missing-source warning, then cancelled native Relink file panel. Relink indication remained; no file selected in cancellation case.
4. Owner selected replacement.png, observed notice **64×32/orientation6 →96×64/orientation1 before approval**, then approved. New yellow/blue landscape, same5s clip and missing warning recovery reported.
5. Mouse-menu undo, including after attempted clip selection, had no observed reversal; AX still showed replacement.png and dirty project. Cause unconfirmed: no runtime history-depth/handler-entry capture. Do not infer undo model corruption or stale-frame-only defect from this observation.
6. Owner focused timeline blank space and used keyboard Cmd+Z: original name/missing state restored and preview cleared. Shift+Cmd+Z restored replacement name/yellow-blue preview/5s clip. An actual status-line error from the failed missing-image preview remained. AX captured that error. `rebuildInternalImagePreview` sets statusMessage in catch but does not clear it on successful recovery: confirmed stale-error presentation path. Earlier RELINK-01 direct-method tests did not cover this owner menu path or missing-source status recovery.
7. Owner saved after-relink-a.ontheframe, then normally quit A. `ps -p2642` exit1/empty confirmed absence before starting B.
8. B PID5507: same signed binary/suite, no reset. Owner opened after-relink-a and reported correct image/5s clip/playback. Initial description called the remaining Relink button a warning; owner explicitly clarified **only the button remained, no actual warning**. AX showed empty status and no missing alert. Normal available-image relink affordance is not a missing flag.
9. Owner saved after-relink-b.ontheframe. A/B files are byte-identical including bookmark:3433bytes, SHA256 `9932b02b6304c3d7e1347fbea314cf5728c318d3cea03dd3402fd91b3c3f2330`.
10. Owner exported fresh exports/relinked-b.mp4 via native Save and observed completion, then played output and confirmed normal yellow/blue landscape. No audio in fixture. Owner normally quit B; `ps -p5507` exit1/empty confirms exit. No owner dialog automatically approved.

## Identity and access

Project UUID `CD160DEE-2E21-4181-86BF-7F802EF1C737`; media UUID `285A0279-51AE-48AB-B6F9-A980F369F300`; clip UUID `4127EAA1-76A1-4D20-A3A0-4E7E7C479043`. Start0,length150,sourceIn0, same lane/settings and default/absent transform. All non-media serialized fields identical before/after relink. Only intended media source/descriptor/bookmark changed; media UUID retained. Descriptor PNG96×64/orientation1/8bit RGB/explicit-sRGB. New bookmark serialized and retained identically across A→B. No nondefault transform, multiple-clip, audio/subtitle/spectrum owner case claimed.

New-process successful open/render supports actual access restoration. Current open path requires full probe before accepting an image; no fabricated proof introduced. No per-scope instrumentation was added to the normal owner process: **scope starts/stops and drain counts were not newly measured**. Process exit is not a scope accounting proof. RELINK-01's actual7/7 and BOOKMARK-01's38/38 are prior automated evidence only. Owner same-geometry fixture was prepared but NOT RUN. Probe-failure/stale-session cases also reuse prior evidence, not new owner PASS.

## Output checks and failures

New inspector `$E/inspect-export.swift`, run via Swift/AVFoundation against only generated MP4. Duration5s;1920×1080; sampled frame0/75/149 actual PTS0/2.5/4.966666666666667. Yellow RGB samples254/251/2,254/251/1,254/251/1; blue4/51/252,4/51/253,4/51/253. Its simple criterion expected blue green<40 and failed all3, **exit1**. Original JSON/log/script retained. Threshold not relaxed and no reclassified numerical PASS. This was not canonical NV12/QA-02 measurement: no color conversion root cause or renderer quality verdict established. It identifies a measurement/quality follow-up; observed new source identity and owner qualitative match are separately supported. MP4 SHA256 `a77e2af1984e3a6f1a1a03388877f63dee0743d4ceebe40251f3f617bef0689c`.

No new product builds, engine suites, GPU benchmarks, blocked subtitle/spectrum/WMO targets or broad exports run. Tiny ImageIO fixture generation exit0; signature verification0; exact project comparison0; git diff --check0. No observed app crash/timeout. Final broad preservation assertion failed (exit1 inside Python) due the exceptions below; later shell commands exited0, which does not erase the assertion failure.

## Preservation and remaining work

All generated original/replacement/same-geometry image hashes unchanged; baseline/A/B projects match retained copies. Owner data untouched. No source/schema/feature/spectrum changes, staging, commit, push, reset or cleanup. This report is the only new publication document from this task; raw generated evidence remains ignored.

Pre-existing source/tests/documents and branch/upstream/main/backup refs unchanged. Exceptions: app/.DS_Store bytes changed and Codex internal turn-diffs capture/checkpoint refs were replaced during the multi-turn session. Exact differences retained in final-checks-exceptions.json; not reverted, no causal attribution beyond observed namespace. Thus do not claim all refs or every local file unchanged. Other excluded settings preserved.

Remaining: menu undo dispatch/focus diagnosis, stale preview error clearing with focused regression, canonical color interpretation of supplemental RGB check, owner same-geometry case, measured scope lifecycle after relink/reopen, long-duration/external-volume/permission-change scenarios. Public image support and spectrum remain gated/unchanged.

Recommended next bounded task: diagnose the actual menu undo routing and add a missing-source undo→redo regression that verifies both model state and status presentation, then make only confirmed localized corrections. Preserve this original signed app and owner evidence before any rebuild. Full acceptance remains PARTIAL until unresolved findings are dispositioned.
