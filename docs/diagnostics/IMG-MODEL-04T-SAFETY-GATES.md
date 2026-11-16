# IMG-MODEL-04T — Centralized unsupported still-image safety gate

Date: 2026-10-30 (Asia/Tokyo)
Status: PARTIAL — stopped on an unexpected Debug test-host crash.

## Baseline and scope

`feature/subtitles`, HEAD/cached upstream `faca37177b1ce85dbfd0a198cbcd00062f3c7e0a`;
main `44943eadabdf5a37d5242d614e7279813126dfde`. CLAUDE.md read;
no applicable AGENTS.md found. No remote refresh or Git mutation.
Four pre-existing IMG-MODEL-03 files and the IMG-MODEL-04S report were preserved.

Modified production files:
- app/Engine/Sources/OnTheFrameEngine/ProjectFile.swift
- app/Engine/Sources/OnTheFrameEngine/CompositionPlanner.swift
- app/OnTheFrame/InteractivePreview.swift
- app/OnTheFrame/ProjectStore.swift

New files:
- app/Engine/Sources/OnTheFrameEngine/ProductionContent.swift
- app/Engine/Tests/OnTheFrameEngineTests/ProductionContentSafetyTests.swift
- app/Engine/Tests/OnTheFrameEngineTests/ProductionContentPlannerTests.swift
- app/diagnostics/IMGModel04T/SafetyGateAppTests.swift
- app/diagnostics/IMGModel04T/run-tests.py
- docs/diagnostics/IMG-MODEL-04T-SAFETY-GATES.md

## Central contract

ProductionContent has a private supported Timeline or a sorted immutable set of
unsupported image media UUIDs. The internal isolated-model adapter validates the
complete project catalog and checks every image reference, including unused
references, before obtaining any temporal projection. With images it stores no
production Timeline and throws typed ProductionContent.Unsupported.stillImages.
No fake image frame count, duration, SourceTiming or video asset is created.

Current Timeline/MediaRef cannot represent images. Its public adapter therefore
represents only legacy temporal content. This is a safety interface foundation,
not operational image-model integration. Future canonical media integration MUST
update that adapter to inspect the complete operational catalog; it must not
first discard images into a legacy Timeline. The isolated temporalDocument
remains internal design/validation support, not a normal open/import route.

## Reachable boundaries and propagation

ProjectFile's content overload rejects before returning any serialized Data;
normal legacy encode/decode/currentVersion 8 are unchanged. Transactional app
write still encodes before replacement-directory creation or destination change.
The tests exercise used/unused rejection with a disposable existing destination.

Planner content overloads for plan, layeredSegments and layerStack obtain a
supported Timeline before calling existing code. Occluded images, unused refs,
empty selected lanes, times outside a clip, and missing native assets cannot
bypass the complete-catalog check. Video-only culling and source offsets retain
existing behavior. Original Timeline entry points remain valid because the
current operational type cannot represent image content.

InteractivePreview checks before begin/prefetch, request, and drawList. The
content drawList overload rethrows the typed unsupported error instead of
turning it into nil. Unrelated errors retain legacy optional behavior. Rejection
cancels pending prefetch, invalidates token/activity, clears cache/media, fails
pending callbacks and sends onUnsupported. Test-only cache seeding is guarded by
OTF_SAFETY_TESTS, absent from normal app compilation.

ProjectStore installs that callback. Rejection invalidates the async generation
and preview-input cache, drops the temporary stage, pauses playback if needed,
and sets a diagnostic without replacing project history/media/bookmarks.
Checks precede timelineChanged's missing-media filtering and cached/empty return
branches, beginStill, export preparation, save panel and writeProject work.
Export preparation still goes through planner before ExportService and its
subtitle-bearing SubtitleExporter path. Neither renderer was changed.
The isolated adapter is never installed as ProjectStore project state.

## Executed validation

Evidence: `$REPO/app/selftest-work/img-model04t-20261030-01/` (ignored).
Build root: `$BUILD_ROOT` = existing internal APFS IMG1A-build directory.

Final engine commands used `swift test -c debug|release --package-path app/Engine
--scratch-path $BUILD_ROOT --filter <bounded filter>`; Release added
`-Xswiftc -enable-testing -Xswiftc -DOTF_PROTO_RELEASE`.
OTF_MODEL03_RUN pointed to separate fresh directories under this run.
Exact filter and logs are preserved in summary.json/logs.

| Validation | Result | Exit |
| --- | --- | --- |
| Final Debug engine regression | 68 PASS / 0 FAIL / 0 SKIP | 0 |
| Final Release engine regression | 68 PASS / 0 FAIL / 0 SKIP | 0 |
| Earlier Debug app safety, default valid project | 5 PASS / 0 FAIL / 0 SKIP | compile 0, run 0 |
| Final Release app safety, edited valid project | 5 PASS / 0 FAIL / 0 SKIP | compile 0, run 0 |
| Final Debug app safety, edited valid project | test-host crash; suite incomplete | compile 0, run -5; driver 251 |
| git diff --check | PASS | 0 |

Engine 68 = 5 new safety/planner tests, 13 isolated MODEL-03 tests and 50 existing
Timeline/lane/clipboard/transform/ProjectFile/subtitle/spectrum regressions.
Legacy 1–8 interpretation and image-free conditional 5–8 writer coverage are
included. No actual video export or player session was selected.

App tests compile actual app sources plus the existing SpectrumProto shared
sources and engine objects, replacing only @main in a disposable copy. The
normal app bundle/UI is not launched. Debug uses -Onone/-DDEBUG; Release -O;
both use the test-only flag and whole-module compilation in the final runner.
The pending-prefetch test invalidates a task before source lookup; it is NOT an
actual in-flight AVFoundation decode race. Cache invalidation uses a tiny seeded
CGImage. ProjectStore generation invalidation is asserted; an in-flight native
planner completion was not driven through the app.

## First failures and mandatory stop

An initial sandboxed SwiftPM attempt exited 1 because compiler cache/build paths
were unwritable. The authorized existing internal build path was then used with
elevated tool execution. Earlier standalone app compilation attempts exposed
runner product-path/source-collection omissions and an optional String check in
test code; logs were preserved and these test setup issues corrected.

After an earlier default-project Debug app PASS, the test was strengthened to
create a real edit-history entry by renaming a lane without rebuilding preview.
Release passed all five checks. Debug then terminated with signal 5, logging:
`main/ProjectStore.swift:1404: Fatal error: Unexpectedly found nil while implicitly
unwrapping an Optional value`.

Line 1404 is existing Debug traceGestureDebug, accessing NSApp.isActive. The
standalone runner does not initialize NSApplication.shared before committing an
edit. The log and source indicate a test-host application-lifecycle prerequisite,
not a demonstrated image arithmetic or serialization failure. There is no full
stack trace or further reproduction, and the crash is not dismissed as a PASS.
Per the explicit unexpected-crash stop rule, no correction or test rerun followed.
The failing binary, compile/run logs and original fixtures remain preserved.
No timeout was observed.

## Preservation and remaining boundary

Preflight hashes: all 445 existing files other than the four authorized modified
sources remain identical. MODEL-03's historical snapshot: 3,818 other files remain
identical; its four production files changed only as listed above. The four
MODEL-03 source/tests and 04S document are byte-identical. Non-Codex refs,
including recovery/backup refs, are unchanged. Index remains empty.
Managed allocated data is approximately 8.2 GiB, below 20 GiB; no cleanup occurred.

Recommended next bounded task: initialize the standalone Debug test application's
lifecycle in the harness, preserve this crash evidence, and rerun the failed
five-case validation before approving operational model integration.

No operational image timeline implementation; no normal format-9 open/save;
no image import; no product GPU integration; no Stage 3C-2 or spectrum export;
no owner media/project/output changes; no staging, commit or push.
