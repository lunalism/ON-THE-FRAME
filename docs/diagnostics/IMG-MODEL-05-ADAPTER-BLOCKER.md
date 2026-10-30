# IMG-MODEL-05 — Lossless adapter preflight blocker

Date: 2026-10-30 (Asia/Tokyo)
Status: BLOCKED before implementation.

## Verified baseline

Branch `feature/subtitles`; HEAD/cached upstream
`faca37177b1ce85dbfd0a198cbcd00062f3c7e0a`; main
`44943eadabdf5a37d5242d614e7279813126dfde`. Six tracked source modifications
and all existing untracked MODEL-03/04T/04T-R/04U work were retained. Index empty.
CLAUDE.md and applicable instruction locations reviewed; no AGENTS.md found.
No fetch, reset, branch change or Git mutation.

## Concrete reverse-adapter dependency

The required standalone decoded-model -> operational Timeline transformation
cannot restore missing still-image files with the current construction API:

- Timeline.mediaCatalog has a private setter; a separate adapter file cannot
  install a decoded full catalog. The existing initializer constructs temporal
  MediaRef entries only. rebuilt preserves image entries of an existing Timeline;
  it cannot introduce decoded images into a fresh Timeline.
- The only image insertion path is Timeline.registeringImage(ValidatedImage,id:).
  It requires FileIdentity.of(source.url) == source.descriptor.identity.
- OperationalMedia.StillSource requires ValidatedImage and a full runtime
  StillImageDescriptor. ValidatedImage's initializer is private and inspect
  performs actual metadata/full validation. Decoded ImageInfo is deliberately
  not a file-access or validation capability.
- The isolated codec deliberately supports missing files. Existing
  testMissingMediaAndSaveAsRelativePaths proves model encoding/decoding without
  filesystem probing, preserving a snapshot at /generated/media/photo.png.
  ImageInfo deliberately excludes runtime device/inode identity and scope state.

For a decoded image whose source is missing, fresh probe validation cannot
succeed and FileIdentity.of returns nil. Reusing the only registration API
therefore rejects the supported serialized missing-media state. Even for an
existing file, reprobing is validation/relink work, not a general lossless
restoration of the stored reference/name/descriptor metadata.

This is a static construction/access-control dependency, not a new runtime test
failure. No speculative parser or production behavior change was made.

## Alternatives evaluated

A forward-only exporter would not satisfy the required round-trip. Supplying the
old Timeline as mandatory hidden decode context could reuse its catalog, but
would not restore a decoded project independently or support new missing refs.
Dropping images into the temporal initializer would lose content. Forging runtime
identity/ValidatedImage from JSON would erase the distinction between a portable
reference and current probe validation. None was implemented.

The user explicitly requires: "Do not modify ProjectFile or Timeline behavior
unless a concrete blocker is identified. If such a change is essential, stop
and report." A catalog restoration path is a Timeline construction change,
so implementation stopped as instructed.

## Minimum next bounded scope (proposal only)

Separate portable still-image reference metadata from optional current runtime
validation in OperationalMedia.StillSource. Add a checked internal Timeline
restoration initializer/factory for a complete typed catalog plus clips/lanes,
without exposing its setter. It must preserve missing source references,
validate metadata and clip invariants atomically, and grant no file access or
renderer capability. No fake source timing or frame counts.

Then the new isolated adapter can carry project UUID/settings and per-media
relative paths/bookmarks alongside the Timeline, preserving catalog order,
clips/transforms, audio links/settings/origin, subtitles/effects and spectrum
lineage. Validate both models and reject contradictions with a typed adapter
error before returning any new state. Retain every production safety gate.
Normal ProjectFile version/schema need not change for this proposed solution.

This proposal requires narrow Media/Timeline construction authorization; it is
not implemented and is not approval of a new owner policy.

## Validation, preservation and result

No adapter, source edits, test additions, builds or test runs in this task.
No adapter round-trip or invalid-input PASS is claimed. Existing 04U evidence
(Debug/Release engine 77 each, app 5 each) remains historical, not new validation.
Static Git/diff/path checks and preflight hash preservation checks were performed.
Only this report was created; an ignored preflight hash record is retained at
$REPO/app/selftest-work/img-model05-20261030-01/preflight.json.

ProjectFile.currentVersion remains 8. Existing codecs and safety guards remain
unchanged. Original relative-path/Save As and bookmark behavior was reviewed,
not revalidated by new tests. All prior source/test/report hashes and protected
refs remain unchanged; the index remains empty.

No production format-9 open/save, normal image import, product GPU integration,
Stage 3C-2, spectrum export, owner media/project/output changes, staging, commit
or push. All historical evidence remains preserved.
