# IMG-MODEL-04T-R — Debug app test-host recovery

Date: 2026-10-30 (Asia/Tokyo)
Status: DEBUG HOST RECOVERY PASS

## Verified baseline and scope

Branch `feature/subtitles`; HEAD/cached upstream
`faca37177b1ce85dbfd0a198cbcd00062f3c7e0a`; main
`44943eadabdf5a37d5242d614e7279813126dfde`.
The existing four modified production files, isolated MODEL-03 files, MODEL-04T
sources/tests/reports and 04S report were retained. CLAUDE.md read; no applicable
AGENTS.md found. No fetch, branch change or Git mutation.

Only the isolated harness `app/diagnostics/IMGModel04T/SafetyGateAppTests.swift`
and this new report changed in this task. run-tests.py is unchanged.

## Actual crash evidence and diagnosis

The original macOS .ips report was inspected and copied, without alteration,
into this task's ignored evidence directory. It records EXC_BREAKPOINT/SIGTRAP
and the triggered main-thread queue, with this stack:

`SafetyGateAppTests.run -> ProjectStore.commit -> cancelPendingPress ->
interruptGesture -> traceGestureDebug -> _assertionFailure`.

The preserved original Debug binary was launched once under LLDB with fresh
generated fixtures. Before entering traceGestureDebug, Swift debugger expressions
reported `NSApp as Any = nil` and `Thread.isMainThread = true`. Continuing
reproduced the same fatal nil unwrap at ProjectStore.swift:1404, NSApp.isActive.
The debugger captured the live stack and exited normally after inspection.
Its exit 0 is NOT a passing test result; the inferior deliberately reproduced
the fatal trap. Original run exit -5 and driver 251 remain in original evidence.

Thus wrong-thread execution is excluded at the failing call. AppKit had no
shared application instance. The original standalone main never initialized
NSApplication.shared. The crash occurs in existing Debug edit tracing while
setting up the edited-project fixture, before the fifth test's unsupported
content checks. No safety-gate implementation frame caused the nil unwrap.
No independent production defect was identified in this incident; this is not
a general audit of unrelated product code.

The installed official AppKit SDK NSApplication.h declares the NSApp global and
sharedApplication class property (Swift NSApplication.shared). The harness now
uses that normal singleton initialization API, on the main thread, before
constructing/exercising ProjectStore. No event loop, window, app delegate
startup, owner project or media session is launched by this standalone test.

## Minimal correction

In @MainActor main, assert Thread.isMainThread, initialize NSApplication.shared,
assert NSApp identity, then execute the original async test body. Immediately
before ProjectStore construction, additionally assert main-thread execution and
non-nil NSApp after async suspension.

Every original test statement, assertion and the lane-rename commit remain.
Removing only the inserted initialization/check statements reconstructs the
pre-task harness SHA-256 exactly (recorded in summary.json). No test skip,
assertion removal, fatal-trap catch or safety-gate weakening was introduced.

## Executed validation

Evidence: `$REPO/app/selftest-work/img-model04tr-20261030-01/`.

| Check | Executed result | Exit |
| --- | --- | --- |
| Corrected Debug actual-app-source harness | 5 PASS, 0 FAIL, 0 SKIP | compile 0, process/driver 0 |
| Corresponding Release harness | 5 PASS, 0 FAIL, 0 SKIP | compile 0, process/driver 0 |
| Debug ProductionContent engine regressions | 5 PASS, 0 FAIL, 0 SKIP | 0 |
| git diff --check | PASS | 0 |

App command: `python3 app/diagnostics/IMGModel04T/run-tests.py <debug|release>
<fresh evidence subdirectory>`. The runner compiles actual app sources with
OTF_SAFETY_TESTS, unchanged assertions and separate generated PNG fixtures.
Both logs explicitly show host initialization and all PASS 1 through PASS 5.
The expected typed unsupported errors are still asserted, including drawList
propagation, cache invalidation, exactly-once pending rejection and real
ProjectStore state/generation preservation.

Engine command: `swift test -c debug --package-path app/Engine --scratch-path
$BUILD_ROOT --filter 'ProductionContent.*Tests'`, with OTF_MODEL03_RUN set to a
fresh generated fixture directory. $BUILD_ROOT is the existing internal APFS
IMG1A-build path. The prior 68-case Debug and Release engine results were reused
as historical compatibility evidence, not counted as new runs.

No post-correction crash or timeout occurred. Existing concurrency/deprecation
compiler warnings remain; no new production source fix was made. No expensive
suite, export, GPU benchmark, AVPlayer playback or normal app UI run occurred.

## Acceptance and remaining boundary

The single missing Debug host validation is recovered. IMG-MODEL-04T is ready
for acceptance within its bounded safety-interface scope, with these new logs
superseding its incomplete Debug result. The historical PARTIAL report remains
unchanged. This is not operational still-image Timeline integration, product
rendering, normal image import or production format-9 support.

The next bounded task is engine-only Media/Timeline image integration using
the central complete-catalog capability interface, with editing and legacy
compatibility tests. Future operational content must populate that interface
before temporal projection or preview filtering.

All pre-task hashed sources and historical evidence other than this authorized
harness edit remain identical. Branch/main/upstream and backup/recovery refs
are unchanged; the index is empty. No source cleanup or history rewriting.
No production edits, image timeline implementation, format-9 activation, normal
image import, GPU/spectrum changes, Stage 3C-2, spectrum export, owner data
modification, staging, commit or push in this task.
