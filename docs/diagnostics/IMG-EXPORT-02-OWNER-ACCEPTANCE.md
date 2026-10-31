# IMG-EXPORT-02 — Owner-guided signed-app acceptance

2026-10-31. **OWNER EXPORT ACCEPTANCE PASS**, limited to the disposable cases below. This is not public activation or complete lifecycle qualification.

## Environment and evidence

- Branch `feature/subtitles`; HEAD/upstream `65c4d876fe463d663fd30bef6ba43e2ed830a42c`; main `44943eadabdf5a37d5242d614e7279813126dfde`.
- `$APP_ROOT` = `$HOME/Library/Developer/ON-THE-FRAME/AppPreservation/IMGBuild03-20261031-01/After2/OnTheFrame.app`.
- `$EVIDENCE` = `$REPO/app/selftest-work/img-export02-20261031-01` (ignored; retained).
- Exact eight app hashes matched retained BUILD-03 hashes. Executable SHA-256 `885d65a6f825a9f44af9b924372b737499b51f6c0392d2bab437e5f2344d087b`.
- Newly verified signature and entitlements: ad-hoc development signing, identifier `dev.ontheframe.app`, sandbox, user-selected read/write, app-scoped bookmarks, get-task-allow. No distribution-signing claim.
- Owner launched PID 53263 with `-OTFEnableImageImport -OTFLayoutSuite dev.ontheframe.export02.20261031.01 -OTFLayoutReset`; exact process path/arguments checked. Existing BUILD-03 symbols/hashes establish image-aware export dispatch presence; symbol tests were not rerun.

## Actual owner actions

Owner operated all native selection/save/export panels and output playback. No automated panel acceptance.

1. Menu appeared; automatic editor window did not. **New Project displayed the editor**. Automatic presentation remains unresolved.
2. Imported generated `fixtures/portrait.jpg`; observed five-second clip, red-top/green-bottom oriented portrait with black sides.
3. Imported generated `tone-5s.wav`, placed audio, added `IMG-EXPORT-02` subtitle; confirmed expected image/audio/subtitle playback.
4. Native Save As `projects/owner-image.ontheframe`; reopened, replayed, Save As `owner-image-reopened.ontheframe`. All serialized fields except bookmark bytes were exactly equal, including project/media/clip/subtitle UUIDs, timings and styles. Both media retained bookmarks. Format 9, 150 frames; subtitle start 30, length 90.
5. Native export `exports/owner-image-01.mp4`; owner played/listened and confirmed video, subtitle and sound matched preview.
6. New project: imported generated four-second `video-A.mp4` with linked audio. Added upper video lane, imported generated `alpha.png` at zero. Owner confirmed translucent red over video and the final image-only second.
7. Native Save As `projects/owner-mixed.ontheframe`, export `exports/owner-mixed-01.mp4`; owner confirmed output video and sound matched preview.
8. Reopened export panel then **cancelled the panel**; owner confirmed project layout and playback remained normal. This does not test cancellation during encoding.

## Newly executed output inspection

Both owner-triggered MP4s were read without modification. Standalone ignored `Inspection.swift` links existing Debug engine objects; it compares decoded output with shared preview composition plus existing subtitle footprint, sampling Y/Cb/Cr every eight pixels. This is a lossy-codec comparison, not screenshot equality or independent compositor arithmetic proof.

| Property | Portrait/audio/subtitle | Video/alpha/audio |
|---|---|---|
| Codec/canvas/rate | H.264, 1920×1080, 30fps | same |
| Decoded frames/duration | 150 / 5s | 150 / 5s |
| Every decoded PTS | exact k/30, k=0…149 | same |
| First/last PTS | 0 / 149⁄30s | same |
| Color attachments | Rec.709 primaries/transfer/matrix, video range SDR | same |
| Audio | AAC stereo 48kHz, 0…5s | AAC stereo 48kHz, 0…4s |
| Minimum sampled YUV PSNR | 54.23547462728533dB | 40.53709773754779dB |
| Read-only inspection exit | 0 | 0 |

First output SHA-256 `b19d0f418611ce9debb3a83e989377284790df981585ff1a6e4d8544fe6d5327` (71,760 bytes); mixed `252171a25d03913892370b34cd74a7ce1d58cf97e37458a22eff0737c55dec10` (4,919,978 bytes). Existing raw QA-02 40dB/flat-error≤3 contract was not changed; post-H.264 edge errors are not judged by raw flat-error limits.

### Inspection-tool failures retained

- First compile exit 1: optional CFDictionary needed explicit handling. Corrected only ignored helper. A monitoring launch was blocked by sandbox `ps`; subsequent collision with its preserved directory failed before compilation. Fresh directory compilation exit 0 (1.414s).
- First inspection exit 1: sandbox Metal unavailable. Authorized normal GPU access used subsequently.
- Next inspection exit 1: helper had not consumed reference EOF. Added one read requiring nil and kept both decoder-completed assertions. Recompile exit 0 (1.409s); both output inspections exit 0. No product fix or weakened frame assertion.
- No observed crash or timeout. No app build, engine regression suite, GPU benchmark or export workload was rerun by automation in this task. Outputs above were created by the owner in the normal app.

## Boundaries and preservation

Native encoding-progress cancellation, induced failure, replacement rollback, active security-scope counts and product GPU lease/drain were **NOT RUN / unverified** here. Prior IMG-EXPORT-01 automated protection evidence is prior evidence only. Session reopen/bookmark presence passed; long-term bookmark access is unresolved. No spectrum content was added and spectrum rejection was not rerun. Opaque PNG fixture was prepared, not imported in this session.

Automatic window presentation, long-term bookmarks, product GPU races/drain, Subtitle/Spectrum/WMO diagnostic compiler blockers, provisional image limits and Spectrum Stage 4 export remain open. Public support remains disabled. Current acceptance is the observed short gated workflow only.

Only this diagnostic document is a new publication candidate. Ignored fixture/tool/log/output files remain under `$EVIDENCE`. All preexisting source/document hashes were preserved; `app/.DS_Store` changed during the GUI session (origin not attributed), and was neither reverted nor staged. Recovery backup refs remained equal and the index remained empty. No production edits, schema changes, owner personal-media/project/output changes, staging, commit, push or cleanup occurred.

Recommended next task: bounded automatic editor-window presentation recovery, followed separately by explicit product cancellation/drain validation.
