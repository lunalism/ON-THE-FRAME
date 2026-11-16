# IMG-1A experiment contract

Isolated development test; no application integration. Run only with
`OTF_IMG1A_RUN` pointing to a fresh directory in `app/selftest-work`.
No existing fixture is regenerated. No product architecture is approved here.

Before measurement: require exact 30 fps PTS, sample count and half-open visual
intervals. Missing/duplicate samples, early end, wrong layer, alpha loss or wrong
orientation are critical failures. Compare with independent CoreGraphics source
over references, not a decoded cache used as its own reference.

Pixel screening thresholds (experimental, not an owner-approved relaxation of
the existing quality contract): flat interior maximum RGB error <= 3; whole-frame
PSNR >= 40 dB; local alpha/edge/gradient errors reported separately, including
maximum and p99. A failing threshold remains a failure, even if mean error is low.
Lossy JPEG input error is measured separately from cache/export error. Pixel
thresholds alone do not establish production equivalence or owner acceptance.

Budget: sequential exports; source/cache 960x540, output 1920x1080/30 SDR;
short cases <= 6 seconds, representative export 180 seconds, composition-only
1800 seconds. No multi-hour export or 4K. Stop on 20 GiB combined artifact budget;
experiment-specific outputs <= 512 MiB, process footprint stop at 1 GiB.
Evidence including first failures is retained. Live on-screen playback, sandbox
bookmark access and owner visual approval are separate from offline comparison.
