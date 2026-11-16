# IMG-BOOKMARK-01 — Cross-process image bookmark restoration

TASK ID: IMG-BOOKMARK-01
STATUS: CROSS-PROCESS BOOKMARK PASS
Date: 2026-11-01 Asia/Seoul

Bounded to this Mac, local filesystem, generated JPEG/PNG/WAV and the cases below. Not long-term access qualification for every OS/filesystem.

## Baseline, isolation and retained work

Branch `feature/subtitles`; HEAD/cached upstream `faace37a7caef001294ef37b79101b18c3e6be24`; main `44943eadabdf5a37d5242d614e7279813126dfde`. Index empty. Existing WINDOW-01 and SAFETY-01 source/document changes, excluded metadata/settings, recovery refs and raw evidence retained. CLAUDE, applicable instruction locations (no applicable AGENTS), ROADMAP/HANDOFF, persistence/import/safety/window reports and current open/save/probe/scope paths reviewed.

`$E` = `$REPO/app/selftest-work/img-bookmark01-20261101-01`. `$BUILD_ROOT` = managed Developer/ON-THE-FRAME root. Preflight found no ON THE FRAME process, including stale PID84441, or running build/test. No existing app was terminated by the agent. Source copies are under `$E/owner/fixtures`; projects under `$E/owner/projects`. Media bytes, metadata, Git refs and source hashes recorded before testing. No personal media/projects/outputs used.

Owner A/B app is the preserved `$BUILD_ROOT/AppPreservation/IMGSafety01-20261101-01/Final/OnTheFrame.app`. All eight hashes match its retained receipt. New diagnostic bundles Validation/Final/Final2/Recovery remain under `$BUILD_ROOT/AppPreservation/IMGBookmark01-20261101-01`. Copies hash-verified. Strict signature and effective entitlements verified: development ad-hoc identifier dev.ontheframe.app, sandbox, user-selected read/write, app-scope bookmarks, get-task-allow. No distribution/notarization claim. Both compile-time and explicit runtime internal image gates used; no public default activation.

## Genuine owner-operated process A → B

Same preserved signed app and isolated suite `dev.ontheframe.bookmark01.owner.20261101.01`:

1. **A PID86992** launched fresh with suite reset. Owner selected generated portrait.jpg and alpha.png through internal native pickers, observed JPEG and PNG compositing; added generated WAV and subtitle IMG-BOOKMARK-01. Native Save As created process-a.ontheframe.
2. Owner quit A with Cmd+Q. `ps -p86992` exit1/empty output confirmed A was gone before B launched; receipt retained.
3. **B PID88002** launched with the same binary and same suite, **without reset**. Owner used native Open for process-a.ontheframe, reported successful open with all sources retained, then used native Save As to process-b.ontheframe.
4. A and B files are **byte-identical**, including all three bookmarks:9,850 bytes, SHA-256 `ad86e41516d83907b4700495302d3198bd3d773069955810dee5e5bb41d286ce`. Original A copy preserved.
5. Owner cancelled a native Open panel; current project remained. Owner normally quit B; `ps -p88002` confirmed exit before automated signed work began.

This is genuine fresh-process restoration, not ProjectStore reinitialization. Native panel actions and visual observations are owner reports; file comparison/PID proof are automated measurements. No automatic panel/permission acceptance.

Project UUID `F0DB0D2C-6712-46DF-95F3-956750BE69BC`, all three media UUIDs, two visual clip UUIDs and lanes, audio clip UUID, subtitle UUID/style/text retained. Images/audio start0,length150,sourceIn0; subtitle start30,length90. Image transforms were the default/absent values and remained so; no owner non-default transform case claimed. Full values in process-a-manifest.json and cross-process-comparison.json, without publishing bookmark payloads. Audio metadata preservation is not a new speaker-listening qualification.

A/B used the pre-correction product; the correction below affects fallback admission only. The later new signed Recovery process validates actual corrected open/save/bookmark/probe paths; its opening is programmatic, not a repeated native-panel owner PASS.

## Confirmed scope-lifetime defect

First automated signed **PID88537**, preserved Final2 bundle, invoked actual ProjectStore.openProject/writeProject with the copied owner project. The diagnostic wraps existing scope hooks around **real** URL.startAccessingSecurityScopedResource/stopAccessingSecurityScopedResource. It does not pretend acquisition succeeded. Resolver hook calls actual URL bookmark resolution and records actual stale flags; it does not return a fabricated URL.

Normal bookmark restoration, full image probes, native AVPlayerItem readiness, full timeline equality, save, failed open and candidate cancellation/failure passed. The first missing-bookmark fallback then failed:

- Current valid session owned portrait.jpg, alpha.png and tone-5s.wav scopes.
- A candidate lacking image bookmarks was probed through absolute fallback URLs while the old image scopes still granted access.
- Old scopes were stopped on commit. The candidate retained only the WAV scope: `missing=0`, `owned=1`, `active=1`.
- A fresh full image validation **after commit** threw `unreadable`. Thus images were marked available without access surviving the transaction.
- Failure cleanup balanced10 real starts/10 stops; no project bytes were lost or clips discarded. App/launcher exited0; diagnostic driverexit1 due failed assertion,2.777s. No crash/timeout.

This is a reproduced product lifetime defect, not merely invalid bookmark rejection. Original binary, source baseline hashes, result/events and logs retained under `$E/signed` and signed-run-result.json.

## Minimal correction and exact task changes

- `app/OnTheFrame/ProjectStore.swift`: only the image candidate branch changes. A fallback matching an existing session-owned scoped URL acquires an **independent candidate scope on that URL before probing**. Failure to reacquire skips the candidate. Successful validation transfers that new lease; failure/cancellation releases it through existing paths. Old session release is unchanged. Temporal video/audio candidate handling is unchanged.
- `app/OnTheFrame/OnTheFrameApp.swift`: four-line Debug-only explicit `-OTFImageBookmarkTest` dispatch to the diagnostic. Existing WINDOW-01 work preserved.
- New `app/OnTheFrame/ImageBookmarkSelfTest.swift`: isolated signed regression, real scope accounting/resolution, post-commit fresh probes, file comparisons and controlled existing candidate hooks. Uses existing GPU counters through Debug @testable access. No production instrumentation API or relink UI.
- This report.

Existing SAFETY-01 ImageExportSelfTest and historical reports are unchanged. No Media/Timeline/ProjectFile/schema, source duration/frameCount, image format policy, renderer/export, spectrum, public feature or scene architecture change.

## Corrected signed regression

**Recovery PID88775**, fresh isolated suite, same generated input bytes. **34 assertions PASS**, app/launcher/driverexit0,4.863s, physical peak269,730,920 bytes, no crash/timeout. Original failed assertion retained and passes after correction.

| Case | Observed behavior |
|---|---|
| Valid bookmarks | Three real source scopes acquired; fresh full JPEG/PNG validation; AVPlayerItem ready; exact timeline/project identity and saved metadata retained. |
| Missing image bookmarks | Absolute fallback remains accessible after old-session release; missing0/owned3/active3; exact clips/IDs preserved. |
| Invalid bookmark bytes | Actual resolver failures fall back; fresh valid sources checked after commit; missing0/owned3/active3. This is valid fallback, not accepting corrupt data as a validation proof. |
| Missing image sources | Both image references/clips retained unverified; missing2/owned1/active1 (WAV only). No fabricated image validation. |
| Explicit revalidation | Reopening the original valid project restores source access, IDs and clips using the real probe. |
| Moved image copy | Only a new task-owned copy is renamed. Actual resolver returned moved-copy.jpg with **stale=true**; document retained and source found. No symlink, permission change or owner-source move. |
| Temporarily missing copy | Same generated copy's old path with no bookmark is safely marked missing; returning it and reopening triggers fresh successful validation. Copy bytes preserved. |
| Failed open | Invalid project rejects without changing current timeline/UUID/access. |
| Cancelled candidate | Existing candidate hook calls cancelOpen after real scope acquisition; candidate scopes released, original session preserved. This is not native panel cancellation. |
| Failed candidate | Existing hook throws after acquisition; temporary leases released and original session preserved. |
| Late session callback | New session created during candidate validation wins; old candidate is rejected and its real scopes released. No stale timeline publication. |
| Session replacement/drain | Application-owned scopes balance; existing GPU active/resources and compositor outstanding all observed0 after reset/drain. |
| Normal process closure | Harness reopens a valid session, records3 live scopes, then calls normal NSApp.terminate. Actual applicationWillTerminate → stopAllScopes records final **38 starts /38 stops /active0**, no unmatched stop. |

bookmark-result.json intentionally records the three live scopes **before** termination (38 starts/35 stops). termination-scopes.json records the subsequent normal lifecycle release. Process exit alone is not the scope proof. These are app-owned API acquisition counts, not OS-wide scope introspection, every decoder allocation, or long-duration GPU leak proof. Save-local acquisition attempts that returnfalse are reported as false, not counted as acquired scopes.

The moved/stale case is a real local filesystem observation. OS permission revocation, inaccessible volumes, network moves and every stale bookmark state were not synthesized. No arbitrary chmod or privacy-setting changes. No new image relink UI was introduced; restoration uses existing bookmark/fallback/probe paths only.

## Builds and bounded regressions

All normal Debug builds used the established dedicated DerivedData, jobs1, batch/index-store disabled,3GiB process/4GiB aggregate monitoring; no clean or output/cache relocation. Durations7.679,5.745,6.211,6.404 and7.123 seconds, all exit0 and no resource stop. Last build physical peak359,777,024 bytes. Intermediate bundles retained. Existing simulator-version warning is unrelated to this macOS target.

New Debug engine regression: **24 PASS,0 FAIL/SKIP,exit0** — ProjectPersistence7, OperationalProjectAdapter9, ProjectFile6, StillImageImport2. Engine sources did not change after this execution. Signed Recovery regression covers the app correction directly.

Existing signed Recovery app FileGuard regression: **21/21 PASS,exit0**,62.022s, no timeout/resource stop; `$E/fileguard-summary.json`. Native Save confirmation is not automated by that harness. No WMO standalone host, blocked subtitle/spectrum diagnostics, Release suite, GPU benchmark or export workload selected for this task. Prior milestones remain historical evidence, not new executions.

## Boundaries, checkpoint and next step

No data-loss/migration issue was observed. Actual missing-bookmark access loss was fixed narrowly and its failing evidence retained. Normal native A/B restoration, exact metadata preservation, corrected signed real-scope lifecycle and relevant regressions support this bounded PASS.

Normal source closure, session replacement and candidate aborts are measured at application scope calls. No OS-wide drained-scope claim. Cross-process persistence covers a short interval on one Mac; long-term permission changes/volumes and non-default owner transform scenarios remain unverified. Existing missing-image alert text still contains older general unsupported-preview wording; no new relink/product UI added in this task.

This is ready for a checkpoint **review**, not an approved combined publication manifest or public release. Existing WINDOW/SAFETY work must remain part of a separate explicit inventory/hash audit before any publication. Recommended next task: bounded checkpoint audit of WINDOW-01, SAFETY-01 and BOOKMARK-01, preserving the original failure and corrected regression evidence.

Final preservation/status/privacy checks are in `$E/final-checks.json`. No staging, commit, push, reset, clean, branch/history change or owner media/project/output modification. All previous evidence and recovery refs preserved.

Final managed artifact allocation: about10.786GiB across the six existing managed roots, within20GiB. Final index empty; branch/HEAD/upstream/main unchanged and upstream divergence0/0.
