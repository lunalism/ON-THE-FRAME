# IMG-RELINK-01 — Gated still-image relink

Date: 2026-11-01
Status: GATED IMAGE RELINK PASS (bounded automated validation; owner GUI NOT RUN)

## Baseline and scope

Repository `$REPO`, branch `feature/subtitles`; HEAD/upstream `0f32bd6b2ee840fd40cf0c356e427ee32f6740c6`; main `44943eadabdf5a37d5242d614e7279813126dfde`. No Git mutation. Existing excluded files and recovery refs preserved. Owner explicitly selected automatic validation only.

Evidence root `$E = $REPO/app/selftest-work/img-relink01-20261101-01`. App preservation `$APP_ROOT = $HOME/Library/Developer/ON-THE-FRAME/AppPreservation/IMGRelink01-20261101-01`; final bundle `Final2/OnTheFrame.app`. These are generated disposable data, not publication candidates. All earlier failure logs/bundles remain.

## Exact changes

- `app/Engine/Sources/OnTheFrameEngine/ProjectPersistence.swift`: opaque exact image revision (including current validation state), existing relative-path helper exposure for undo after Save As; no serialized fields changed.
- `app/OnTheFrame/ProjectStore.swift`: gated relink UI/mutation, independent access lease, candidate validation/notice/revalidation, atomic commit and undo source bindings; accurate missing-image guidance.
- `app/OnTheFrame/ContentView.swift`: existing media warning/action area exposes gated image relink, including images that become unavailable after open.
- `app/OnTheFrame/OnTheFrameApp.swift`: explicit Debug-only isolated selftest dispatch.
- `app/Engine/Tests/OnTheFrameEngineTests/ImageRelinkTests.swift`: five focused tests.
- `app/OnTheFrame/ImageRelinkSelfTest.swift`: signed app automatic regression harness.
- `docs/ROADMAP.md`, `docs/HANDOFF.md`: current bounded status.
- This report.

## Contract and transaction

Both UI and mutation require the existing compile/runtime image gates. NSOpenPanel permits JPEG/PNG, one selection, cancellation with no mutation. No public activation, new codec, format-9 schema change or fabricated temporal source values. Existing StillImageProbe remains unchanged: encoded 8 MiB, longest dimension 2048 px, 4,194,304 pixels, estimated decode budget 128 MiB, concurrency 1. These remain provisional internal limits.

The selected candidate acquires its own real security scope. Full validation constructs a candidate project before changing live state. Dimension/orientation changes display old/new values and explicit Relink/Cancel; equal values need no notice. After any confirmation delay, full validation runs again before committing. Session/operation/timeline identity, cancellation and competing project/import/export work are checked. Failure, rejection, task cancellation and stale completion preserve the old project and release the temporary lease.

Successful commit preserves project/media/clip UUIDs, clip timing/sourceIn/lane/transform, audio lineage, subtitles, spectra and unrelated references. It transfers the lease and real bookmark to session ownership, adds one undo edit, and uses existing preview rebuild/generation invalidation. Undo/redo restores both timeline source revision and access/bookmark/missing/relative-path metadata; relative hints rebase after Save As. Old source scopes intentionally remain session-owned for undo, released on replacement/termination. They are not pruned when individual history entries expire: many repeated relinks in one long session are not resource-qualified.

Existing preview rebuild replaces image resources rather than changing renderer arithmetic. New blue source was observed through AVPlayerItemVideoOutput and in a decoded bounded 5-second MP4. This is source-selection evidence, not raw AVPlayerLayer parity or proof of every in-flight GPU retirement race. Spectrum export remains unsupported.

## New execution evidence

| Check | Result | Exit / evidence |
|---|---|---|
| Final normal Debug app build, single job | PASS, 10.265509083 s, peak process 327418600 B | 0; `debug-build7/result.json` |
| Final Debug engine selection | 43 PASS, 0 FAIL, 0 SKIP; 11.029495875 s overall | 0; `regression5-debug/` |
| Final Release engine selection | 43 PASS, 0 FAIL, 0 SKIP; 90.702459833 s overall; peak process 2098235864 B | 0; `regression5-release/` |
| Final2 signed app, gate on | 19 assertions PASS; actual scope starts/stops 7/7; 8.982464625 s; peak 736183736 B | app/driver 0, no timeout; `enabled5/relink-result.json`, `signed-final4-run-result.json` |
| Earlier final app runtime gate off | 2 assertions PASS; 0.523275458 s | 0; `disabled/`, `signed-disabled-run-result.json`; no claim of final2 rerun |
| Signing | ad-hoc development `dev.ontheframe.app`; strict verification succeeds | `final2-identity.log`, `final2-verify.log` |
| Effective entitlements | sandbox, user-selected read/write, app-scope bookmarks, get-task-allow all true | `final2-entitlements.log` |

Engine commands are retained exactly in `$E/run-debug3.py` and `$E/run-release3.py`: `swift test --package-path app/Engine --jobs 1 -c debug|release`, bounded scratch path and filter selecting ImageRelinkTests, StillImageProbeTests/testRejectionsAndAdmission, ProjectPersistenceTests, OperationalProjectAdapterTests, ProjectFileTests, StillImageImportTests, OperationalStillImageTests, ProductionContentSafetyTests. Release adds `-enable-testing` and `-DOTF_PROTO_RELEASE`. Required generated fixture variables, including `OTF_STILL_PROBE_RUN`, are explicit in those scripts. No expensive diagnostic targets were run. App execution commands/unique settings suites are in driver result JSON. Scope counts wrap actual start/stop API results, not fabricated successes or OS-wide scope introspection.

## Requested regression mapping

| Cases | Evidence / boundary |
|---|---|
| A/B/C JPEG, PNG, cross-format | Debug/Release engine and signed app PASS |
| D/E dimension/orientation notice and no change | Engine EXIF orientation/dimension assertions; signed app notice accept/reject and same-size relink PASS; automatic app alert actions, not owner approval |
| F/G corrupt/unsupported/size admission | Focused corrupt and 8 MiB+1 rejection; existing probe admission cases PASS, original unchanged; no limit expansion |
| H native panel cancel | Actual NSOpenPanel opened; computer-use tool clicked Cancel, no file selected; signed state unchanged PASS |
| I failure/scope | Actual acquired scope released after failed probe, notice/task cancel; stale reset drains all, 7/7 PASS |
| J/K identity/multiple references | Nondefault transform, multiple clips and mixed audio/subtitle/spectrum/unrelated catalog preservation PASS |
| L undo/redo/save/open | Signed undo/redo save and decode verify old/new source; engine codec/restoration/Save As regressions PASS; owner cross-process native relink→Save→Open NOT RUN |
| M stale replacement | Signed pending notice, new session, old callback rejected, scope drained PASS |
| N/O preview/export | New blue frame through item output and decoded generated MP4 PASS; not full displayed-layer raw parity |
| P temporal relink | Existing ProjectFileTests/testRelinkValidatesRangesAndAudioAndKeepsClips PASS in both builds; temporal implementation unchanged |
| Q gate off | Compile/runtime guarded source inspection and signed runtime-off checks; public workflow not exposed. Separate normal non-internal app build NOT RUN |

## Preserved failures and limitations

- Initial app build exit65: internal Timeline.isStillImage was inaccessible from app. Corrected to the public opaque revision query; later normal build succeeds. No test-host crash.
- First signed attempt: after 13 successful checks, fixture harness tried creating a scoped bookmark before creating its corrupt file (Cocoa260). Fixed only fixture ordering; original result/binary retained. No product failure inferred.
- Intermediate regression4 Debug/Release: 41 PASS + 1 SKIP because probe opt-in environment missing. Final regression5 supplies the opt-in and executes all 43; intermediate SKIP is not a PASS.
- First Final app run already passed 19 checks with externally automated native Cancel. Final2 attempt `signed-final2` waited for UI-tool observation and exceeded driver 90 s: driver terminated only its `open -W` launcher (exit -15), not the app. Subsequent actual Cancel let the app produce 19 PASS and terminate. This attempt remains a timeout, not a normal-process PASS.
- `signed-final3` launcher exit1 before starting app because fresh directory did not exist. Retained. `signed-final4` uses an existing fresh directory, same Final2 binary, completes all19 and exits0 in8.98s. No app crash observed.
- Owner explicitly declined manual interaction this task. No owner-native selection, permission/confirmation, visual acceptance or post-relink cross-process bookmark PASS claimed. No automated native Save/Replace or permission acceptance occurred.
- Development ad-hoc sandbox signing is not distribution validation. Long-duration/external-volume/OS-permission-change scenarios and specific GPU in-flight races remain unqualified. Subtitle/spectrum/WMO compiler blockers untouched.
- Existing old-image source modifications during a long undo history still require normal revalidation; stored revision equality is not a new permission or proof of current file contents.

## Safety and next step

No owner source/project/output touched; only disposable fixtures and outputs. Existing excluded `.DS_Store`, `.claude/settings.json`, `app/.DS_Store`, `design/.DS_Store` hashes unchanged. All refs and HEAD/upstream/main unchanged. Index empty; work uncommitted. Final managed allocation 11446032 KiB (about10.92 GiB), below20 GiB; no cleanup. No schema, public image gate, renderer arithmetic or spectrum source change. Historical evidence retained.

Recommended next bounded task: owner-operated generated JPEG/PNG relink, changed-size/orientation confirmation, then save/quit/reopen to verify the new bookmark in another signed process. This is not performed or required from the owner now.
