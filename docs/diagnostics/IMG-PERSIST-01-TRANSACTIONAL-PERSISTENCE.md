# IMG-PERSIST-01 — Transactional application format-9 persistence

Date: 2026-10-30 (Asia/Tokyo)
Status: PERSISTENCE INTEGRATION PASS (bounded automated validation)

## Baseline and exact scope

Repository `$REPO`; branch `feature/subtitles`; HEAD/cached upstream
`800f468460e6e3f604c349a35374ac40dbe04fb3`; main
`44943eadabdf5a37d5242d614e7279813126dfde`. Published CP-07 contains the exact
28-file CP-06 manifest. Preflight tracked tree/index were clean; four excluded
Finder/environment files remained untracked. CLAUDE.md, applicable instruction
locations, ROADMAP/HANDOFF and CP-06 audit/CP-07 commit were inspected.
No AGENTS.md found. No Git mutation or global configuration change.

Modified:
- app/OnTheFrame/ProjectStore.swift — actual save/open transaction integration,
  full-catalog source protection/missing presentation, candidate scope ownership,
  postcommit diagnostic, stale-session rejection and rendering fence.
- app/Engine/Sources/OnTheFrameEngine/ProductionContent.swift — remove the obsolete
  save-unsupported wording; preview/export guard behavior remains active.
- app/OnTheFrame/EditorLayout.swift — include OTF_PERSIST_TESTS in the existing
  isolated UserDefaults suite condition, so Release tests cannot write owner prefs.
- docs/ROADMAP.md and docs/HANDOFF.md — current persistence status/boundaries.

New:
- app/Engine/Sources/OnTheFrameEngine/ProjectPersistence.swift — product facade,
  validated encoding/decoding, explicit image validation/relink readiness and
  checked filesystem transaction.
- app/Engine/Tests/OnTheFrameEngineTests/ProjectPersistenceTests.swift — seven
  focused persistence/filesystem/compatibility/relink tests.
- app/diagnostics/IMGPersist01/PersistenceAppTests.swift — actual app-source tests.
- app/diagnostics/IMGPersist01/run-tests.py — isolated Debug/Release test driver.
- docs/diagnostics/IMG-PERSIST-01-TRANSACTIONAL-PERSISTENCE.md — this report.

No approved schema or image admission policy changed. No modifications to
ProjectFile legacy codec, operational models/isolated codec/adapter, renderer,
normal import UI, GPU/scheduler, Spectrum implementation or project migration.

## Call graph and format selection

File menus/shortcuts already call ProjectStore.saveProject, which calls
writeProject. Normal Open/Recent/Finder flows already converge on openProject.
Those actual persistence methods now call public ProjectPersistence. It reuses
the validated operational adapter and isolated codec; no test-only alternate
persistence implementation is used.

Any used or unused still reference selects 9. Image-free projects use conditional
5–8. Legacy 1–8 use the original decoder semantics via the validated bridge.
Unsupported future versions fail explicitly with the product maximum 9.
Legacy ProjectFile remains a 1–8 component (currentVersion 8); its direct image
save guard is retained. The product facade, not that legacy component, is now
the app's normal persistence entry point. No existing file is rewritten on open.

Portable state includes project/media/clip UUIDs, settings/duration/lanes,
transforms, audio settings/links/origin/lineage, subtitles/effects, spectrum/source
keys, relative hints and opaque bookmarks. Complete catalog validation precedes
publication. No image temporal duration/frame count or runtime identity is invented.

## Save transaction and filesystem limits

The complete candidate is encoded, decoded and compared semantically before
creating temporary output. Source paths and hard/symbolic link identities are
protected at both app and engine boundaries. App bookmarks/relative hints,
savedTimeline and project URL are candidate-only until verified success.

The temporary file has a unique name in Cocoa's itemReplacementDirectory,
appropriate for the destination, retaining the old app's sandbox-aware safe-save
location convention. A raw sibling is not assumed writable with a file-only
sandbox grant. Temporary bytes are verified before commit. Existing POSIX mode
is copied to the candidate (the 0600 replacement case was executed).

Same-volume POSIX rename replaces an existing destination; first save uses
renamex_np(RENAME_EXCL). There is no cross-volume copy fallback or direct write
to the destination. A destination identity change or cancellation before commit
rejects the candidate. Only this operation's newly created replacement directory
is removed; historical evidence/user output is never cleaned.

Actual first/replacement saves ran on the repository's data volume. Injected
precommit and rename failures preserved old bytes; actual missing-parent/write
failure, cancellation and source-overwrite refusal were exercised. After a
successful rename, a verification error is returned as a committed receipt with
postCommitWarning. The app displays that the file WAS replaced and returns false
without advancing an unsaved-changes discard flow. It does not claim rollback
or previous-file preservation after commit.

This is not a guarantee for every filesystem failure: cross-volume/network
behavior, power-loss durability/fsync, ACL/extended metadata preservation and
external changes in the final identity-check/rename interval are not proven.
POSIX mode preservation is tested; full metadata preservation is not claimed.
An unsupported commit failure remains precommit/fail-closed, without copy fallback.

Save As rebases relative references using the available resolved URL, or the
previous project's relative hint even when unavailable; it does not discard a
useful offline hint merely because the absolute path is unavailable. Rebased
hints are not probe validation or scope grants. Bookmark refresh is local until
commit, and only actually found source URLs are used to refresh image bookmarks.

## Open transaction, availability and access scopes

Read/decode/validate constructs a complete candidate before touching the active
history/session. Media availability is checked separately. Temporal sources retain
the existing MediaProbe/relink-range checks; images use full StillImageProbe and
match the persisted descriptor/size/mtime. Candidate source access stays held
through the async probe. Missing/changed/unreadable images retain their snapshots
and clips as unverified; no automatic geometry migration or fake FileIdentity.

Bookmark resolution retains the legacy relative/absolute fallback for unavailable
OS bookmarks; this is source availability, not a corrupt portable document.
Fatal handler/candidate failures abort with cleanup. A fatal resolver injection
was tested separately. Parsing, invalid/future documents, candidate validation,
cancellation and session conflicts preserve the active model/history/bookmarks.

Candidate scopes and the project-file scope are transferred only at successful
commit; old scopes are released then. On failure/cancel the candidate scopes and
local root scope are released. A successful root scope remains session-owned for
later saves. Reset/next open/termination release owned scopes. Session UUID/epoch
checks prevent stale async publication, including a replacement with an equal
empty Timeline but a different project identity.

Serialized images remain unverified in Timeline even when a source was found;
found URLs are separate session availability data. Encoding metadata does not
grant access. Explicit engine image relink reuses the existing full probe and
JPEG/PNG policy, preserving IDs/timing/transforms and exposing geometry/orientation
change metadata. No new image relink UI is installed: existing missing/error
presentation lists the names and states that image relink UI is unavailable.

## Rendering/export remains unsupported

The full-catalog ProductionContent/planner/InteractivePreview guards remain.
Opening an image project clears the old currentPlan/player item/subtitle stage
at the successful session commit. Metadata refresh preserves image missing flags
without filtering the Timeline or constructing temporal image assets. Preview
preparation exits through the existing unsupported diagnostic. App play with no
item does not start; export is refused before panel/preparation/output, including
unused-only image catalogs. Direct planner rejection is also tested.
No experimental Metal compositor, normal image import action, GPU preview/export,
Stage 3C-2 or spectrum export was enabled.

## Newly executed validation

Evidence: `$REPO/app/selftest-work/img-persist01-20261030-01/` (ignored).
Build root `$BUILD_ROOT`: existing internal APFS IMG1A-build directory.

| Final verified run | PASS | FAIL | SKIP | Exit |
| --- | --- | --- | --- | --- |
| Debug engine | 93 | 0 | 0 | 0 |
| Release engine | 93 | 0 | 0 | 0 |
| Debug actual-app-source persistence groups | 10 | 0 | 0 | compile/run/driver 0 |
| Release actual-app-source persistence groups | 10 | 0 | 0 | compile/run/driver 0 |
| git diff --check/privacy/reference checks | PASS | — | — | 0 |

Each engine run includes seven new ProjectPersistenceTests plus the previous 86
bounded adapter/operational/safety/legacy/Timeline/clipboard/subtitle/spectrum
regressions. App groups exercise actual openProject/writeProject/saveProject:
format9 mixed state, first/replacement/save-as, precommit failures/cancel,
invalid/future open, candidate scopes/fatal resolver/cancel/stale session,
missing and unused-only references/repeated UUIDs, render/export refusal and
legacy 1–8 plus conditional 5–8 saving.

Engine command: swift test -c <debug|release> --package-path app/Engine
--scratch-path $BUILD_ROOT --filter <summary.json filter>. Release adds
-Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE. Fresh OTF_MODEL03_RUN roots
are used. Final logs: debug-verified.log, release-verified.log,
engine-verified-driver.log. Earlier passing subsets are retained, not added again.

App command: python3 app/diagnostics/IMGPersist01/run-tests.py <debug|release>
<fresh output directory>. Final logs: app-debug-verified and app-release-verified.
The runner compiles actual app sources with a disposable @main replacement and
OTF_PERSIST_TESTS. It initializes NSApplication on the main thread and uses a
unique -OTFLayoutSuite for BOTH configurations. No owner preferences/projects,
native save-panel confirmation or normal app UI workflow is used by these tests.

Initial failures retained: app-debug-first failed compilation because the new
test assertion helper lacked a throwing autoclosure; app-debug-02 executed six
groups then failed the scope test's assumption that a CLI minimal bookmark
acquired an OS sandbox scope. The helper was corrected; deterministic resolver
and scope lease hooks test the real production ownership paths. These are
injected lease tests, NOT evidence of an actual sandbox permission grant.
Ordinary app runs also exercise real URL scope calls, but CLI success is not
reported as sandbox UI success. No crash or timeout occurred. Existing compiler
warnings remain. All first-failure/passing logs are preserved.

NOT RUN: actual signed-sandbox Open/Save panels and permissions, GUI end-to-end,
real video/audio playback, image GPU rendering, exports or expensive GPU suite.

## Owner Mac validation still required

Using disposable projects only: select/open from outside the sandbox; verify
actual project/source bookmark grants, cancellation and release; first save and
Save As/replace through the native panel (including an existing destination);
repeat open/save/new/close; test the intended APFS/HFS+ locations and readonly or
unavailable volumes; confirm missing-image notice and blank unsupported preview,
export refusal, UUID/metadata stability and no accidental source overwrite.
The native save panel was not automatically confirmed. No claim of all-volume
atomicity or complete image support is made.

## Final state and next task

ROADMAP/HANDOFF now reflect product persistence integration while retaining all
historic checkpoint findings. Preflight files except the five listed modified
paths retain their hashes. main, HEAD/upstream, backup/recovery refs and index
are unchanged. Managed artifacts remain below 20 GiB; no destructive cleanup.
Recommended next bounded implementation task: a signed-sandbox persistence
validation harness with generated fixtures and owner-confirmed native Save panels,
before a publication checkpoint or image UI.
No owner real media/project/output changes, staging, commit or push.
