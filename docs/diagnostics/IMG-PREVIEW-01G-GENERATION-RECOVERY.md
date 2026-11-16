# IMG-PREVIEW-01G — Debug generation recovery

- Date: 2026-10-31 (Asia/Seoul)
- Decision: **GENERATION RECOVERY PASS** (bounded experimental validation only).
- Branch: `feature/subtitles`; HEAD and cached upstream: `800f468460e6e3f604c349a35374ac40dbe04fb3`.
- Main: `44943eadabdf5a37d5242d614e7279813126dfde`.
- This does not complete product image preview or approve production clock-carrier adoption.

## Scope and preservation

Only two existing test-target files changed:

1. `app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/GenerationRecoveryTests.swift`
2. `app/Engine/Tests/OnTheFrameEngineTests/IMBGPU01/MetalNV12Experiment.swift`

This report is the only new publication document. No shader arithmetic, lease state machine, admission policy, production source, existing diagnostic report, ROADMAP or HANDOFF was edited in this task. All preexisting tracked and nonignored untracked file hashes were compared with the preflight inventory: only the two files above differ. Existing uncommitted IMG-PERSIST/IMPORT/PREVIEW work remains intact. Protected Git refs, including recovery refs, are unchanged; automatic `refs/codex/*` are excluded from that comparison. No staging, commit, push, reset, cleanup or branch operation occurred.

`$REPO` denotes the repository; `$EVIDENCE` denotes its ignored disposable directory `app/selftest-work/img-preview01g-20261031-01`. Generated fixtures, output, build products and logs remain local and are not publication candidates. Existing source fixtures and previous failure logs were not replaced. No owner media, project or output was accessed or modified.

## First instrumented reproduction: exact failed predicates

The first Debug execution used the original workload, original ordering and original combined assertion, with bounded event instrumentation added. It failed once, normally returning test exit 1 (one test, one failure), rather than crashing or timing out the test host. The combined assertion remained `late completion/stale/drain`.

| Original guard predicate | First Debug result | Corrected runs |
| --- | --- | --- |
| GPU command completed successfully | FALSE: status 5, error | TRUE: status 4 |
| Exactly one canceled old-client terminal | TRUE | TRUE |
| Only new-generation request published | TRUE | TRUE |
| Old lease retired | TRUE | TRUE |
| Old resources empty | TRUE | TRUE |
| Active count zero | TRUE | TRUE |
| Pending count zero | TRUE | TRUE |
| GPU-written byte visible | FALSE: actual 0, expected 71 | TRUE: 71 |

The error was `MTLCommandBufferErrorDomain`, code 2, `Caused GPU Timeout Error (00000002:kIOGPUCommandBufferCallbackErrorTimeout)`. This was a Metal command error; the host did not receive a signal or exceed the external process timeout. No stale publication or resource-drain failure was observed in this trace.

Times below are milliseconds from old-command submission, from the monotonic event trace:

| Event | Debug original order | Release original order | First corrected Debug |
| --- | ---: | ---: | ---: |
| Old logical cancellation | 0.034 | 0.007 | 0.025 |
| Generation replacement | 0.037 | 0.009 | 0.028 |
| New render completes | 8.396 | 8.542 | 8.572 |
| New publication | 11.340 | 11.025 | 11.346 |
| CPU geometry/quality marker starts | 1890.171 | 88.366 | 1968.175 |
| CPU quality finishes | 5060.267 | 244.899 | 5296.801 |
| Old GPU wait event released | 5060.269 | 244.900 | 11.349 |
| Old GPU completion observed | 5001.104 (error) | 245.635 (success) | 11.554 (success) |
| Old lease retirement observed | 5001.115 | 245.640 | 11.563 |
| Original combined guard | 5060.318 | 245.688 | 11.628 |

Canonical RGB conversion precedes the geometry/quality marker. Thus CPU validation occupied substantially more time than the interval between those markers alone. The observed roughly five-second command timeout is specific evidence from this environment, not a promised universal Metal timeout threshold.

## Confirmed cause and minimal correction

The harness held the old submitted command behind an unsignaled `MTLSharedEvent` while doing CPU canonical RGB, geometry and QA-02 measurements. Debug CPU work took long enough for the blocked command to error before its event was released. Release completed the same CPU work quickly enough to avoid that error; this does not make the original synchronization valid.

The correction releases the old GPU event immediately after actual new-generation admission, rendering, raw/PTS/request identity verification and publication. It then observes GPU completion and retirement, executes the unchanged eight-part guard, and performs all original CPU canonical, geometry and quality checks before reporting success. The old command remains submitted and blocked throughout cancellation and new publication. Its four resources remain leased; active high-water is two. Only after observed completion does retirement leave active/pending/resources at 0/0/0.

No arbitrary sleep, increased timeout, retry-until-pass, skip, weakened quality threshold or suppressed error was introduced. The existing ten-second completion wait is unchanged. The test-only renderer adds returned `requestID`/`generationID` diagnostic metadata; no scheduler behavior changed. Bounded trace rows are lock-protected and diagnostics are written from the test task, not concurrently from the Metal callback. Original before-edit and instrumented-before-correction source snapshots are preserved under `$EVIDENCE`.

## New output correctness

All eight corrected generation executions admitted actual request 2 / generation 1 through the unchanged renderer admission path while old request 1 / generation 0 was still blocked. The only published identity was `new-generation1-request2`; old completion remained exactly once with canceled state.

- Frame: 2; intended PTS: `2/30`. In this isolated generation test the PTS is explicitly a test sidecar, **not** an AV callback timestamp. Native AVPlayer output timestamps are checked separately in the carrier compatibility test.
- Frozen CPU and GPU raw SHA-256: `4ea33d39d0dd2a84afa24c2559c644c095cdc58f13b2013022008522490ffad2`.
- Y/Cb/Cr maximum difference: 0/0/0; canonical CPU/GPU RGB maximum difference: 0.
- QA-02 sampled-420 reference: PSNR 46.88378146249797 dB, flat maximum 2.
- CG reference: PSNR 42.250537813325344 dB, flat maximum 1.
- Existing PSNR >=40 dB and flat error <=3 criteria unchanged; layer geometry/visible top-frame identity assertions retained.
- No premature old resource retirement, stale publication, duplicate client terminal or remaining lease was observed.

## Newly executed validation

All results here were executed for IMG-PREVIEW-01G, not reused from IMG-PREVIEW-01/01R. The deliberate original-order Debug failure is retained and is not included as a corrected PASS.

| Execution | Debug | Release |
| --- | --- | --- |
| Instrumented original ordering, before correction | 1 FAIL, exit 1 | 1 PASS, exit 0 |
| Bounded selected engine suite after correction | 111 PASS, 0 FAIL, 0 SKIP, exit 0 | 111 PASS, 0 FAIL, 0 SKIP, exit 0 |
| Corrected generation test, total independent runs | 4/4 PASS, exit 0 each | 4/4 PASS, exit 0 each |
| Native image-only/mixed-audio app surface groups | 2 PASS, 0 FAIL, 0 SKIP, exit 0 | 2 PASS, 0 FAIL, 0 SKIP, exit 0 |
| Native video-only surface control | 1 PASS, 0 FAIL, 0 SKIP, exit 0 | 1 PASS, 0 FAIL, 0 SKIP, exit 0 |
| Diagnostic app compilation | exit 0 | exit 0 |

The 111-test suite includes generation 1, in-flight lease/cancellation 4, native clock-carrier compatibility 1, clipboard 5, input compatibility 1, lane timeline 6, operational adapter 9, operational image 9, content planner 1, content safety 4, ProjectFile 5, persistence 7, spectrum 10, import 2, probe 9, isolated codec 7, isolated image model 6, subtitle 7, timeline 12 and transform 5. Debug took 19.341 seconds and Release 2.623 seconds for the selected suite. Build completion and executed-test success are separately logged.

Corrected generation totals overlap the suite: Debug first corrected standalone + one suite execution + two planned independent repeats; Release one suite execution + three planned independent repeats. The finite repeat plan was recorded before those repeats and stops on any failure. There are eight corrected generation executions, not eight additional suites. Repeats reuse the same compiled binary with fresh direct-child artifact directories; no retry-to-pass loop was used.

The unchanged corrected app harness exercises real `PlayerNSView`/`AVPlayerLayer` surfaces, strict raw frame identity, native subtitle item binding, paused spectrum visibility, layer order, seek/stale-token fences and play/pause behavior. It uses disposable diagnostic windows. It is not a signed normal-app/native panel acceptance test. Surface assertions and the existing overlay synchronization contract were not changed in this task.

Commands used the existing Swift package build root and Debug/Release test configurations, the targeted suite above, and the explicit opt-in `OTF_GPU02E_RUN`, `OTF_GPU02E_MANAGED`, `OTF_IMG_GPU01_FIXTURES` inputs. No test was enabled without its generated fixture root. App driver invocations:

```text
python3 app/diagnostics/IMGPreview01/run-tests.py debug $EVIDENCE/app-debug-validated
python3 app/diagnostics/IMGPreview01/run-tests.py release $EVIDENCE/app-release-validated
```

Video control invokes each resulting diagnostic executable with `OTF_SURFACE_MODE=video-only`, `OTF_SURFACE_DIAG=1` and a separate disposable fixture root. Exact app compiler/linker command lines are preserved in each app directory's `command.txt`; `compile.log` and `run.log` record separate outcomes. No unrelated GPU90 benchmark, export or owner-media workload ran. No new host crashes, external process timeouts or corrected-run test failures occurred; the intentional first original-order GPU command timeout remains preserved.

Evidence index (ignored local data, intentionally not Markdown publication links):

- `$EVIDENCE/before.json`, original source snapshot, instrumented-before-correction snapshot.
- `$EVIDENCE/debug-instrumented-first.log`, `generation/results.json`, exit JSON.
- `$EVIDENCE/release-instrumented-before.log`; separate `app/selftest-work/img-preview01g-release-before-20261031-01/generation/results.json`.
- `$EVIDENCE/debug-fixed-first.log`; separate `app/selftest-work/img-preview01g-debug-fixed-20261031-01/generation/results.json`.
- `$EVIDENCE/validation-plan.json`, `validation-results.json`, `summary.json`.
- `$EVIDENCE/engine-{debug,release}-validated.log`, app/video logs, finite-repeat logs.
- Direct-child artifact roots `app/selftest-work/img-preview01g-{debug,release}-validated-20261031-01` and `img-preview01g-{debug,release}-repeat-20261031-NN` retain each generation trace and accounting output.

## Remaining boundary and next task

The generation-recovery boundary required before IMG-PREVIEW-02 is now validated within this fixture. No demonstrated production scheduler defect required a fix. Finite runs do not prove absence of all concurrency races; these are six-frame FHD experimental cases and one new-generation image render, not long-duration, broad hardware, HDR, arbitrary geometry or real-project acceptance.

Recommended next bounded task: design and validate an internally gated product preview adapter using the native AVPlayer contract, including session replacement and image-only/mixed seek/lifecycle tests, before considering public adoption. Owner Mac end-to-end acceptance and production performance/resource behavior remain open. No normal production preview integration, public image activation, image export, schema/format migration, new preview clock, Stage 3C-2 or spectrum export was added here.

## Final repository checks

`git diff --check` returned 0. The two changed test files and this report matched no `/Users/`, `/Volumes/`, obvious GitHub/AWS token or private-key patterns. This bounded scan is not a claim of exhaustive secret detection. No new absolute personal paths were published. The index remains empty; branch, HEAD, cached upstream and main remain at the baseline above with local/cached-upstream divergence 0/0. No live remote request or Git mutation was required. Ten tracked files are modified in the final working tree, including eight changes already present before this task; all existing untracked work remains present. The tree is intentionally uncommitted, not clean.

Final allocated-size checks (`du -sk`) were 3,548,648 KiB for `app/selftest-work`, 1,683,360 KiB for `app/.build`, 1,683,992 KiB for `experiments`, and 1,870,972 KiB for the existing developer build root, totaling 8,786,972 KiB (about 8.38 GiB), below the 20 GiB managed budget. No prior evidence was deleted. Per-run generated-artifact accounting passed within the existing limits.
