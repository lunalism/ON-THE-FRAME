# IMG-1A-3 measurement contract — proposal, not owner approval

The original IMG1A-CONTRACT.md remains unchanged: global PSNR >=40dB and
flat-interior maximum RGB error <=3. Preserve original CG-reference scores.
This document declares diagnostic comparisons before the new matrix is run;
it does not approve a replacement product quality policy.

Source: actual JPEG/PNG decoded pixels, orientation normalized once, ICC converted
to sRGB RGBA8. JPEG generation losses are separate from cache/render losses.
Project coordinates are top-left; output pixel centers are (x+0.5,y+0.5).
For an axis-aligned rectangle invert its transform, subtract source center 0.5,
bilinearly interpolate the four premultiplied encoded-sRGB RGBA source pixels,
clamp source taps at the edge, then source-over in the declared encoded space.
Compute black background and alpha before comparing RGB. Do not unpremultiply
fully transparent RGB for quality scores. Linear-light interpolation is a
separate hypothesis, not the chosen source of a passing score.

Report two geometry masks: ideal rectangle pixel-center coverage and the prior
native axis-aligned source-edge convention [-0.25,width-0.25) on each axis.
The latter is a diagnostic proposal based on prior native geometry evidence;
compare it against unchanged production planning rather than redefining rules.
Do not generalize it to rotations or arbitrary transforms without testing.

Keep same-sized, same-color-space comparisons separate: standalone cache
extraction, 1:1 composition, scaled composition, final H.264; RGB to 4:2:0
subsampling/quantization is a lossy stage. Report CG reference, analytic reference,
and preview/export values independently. Subtitle footprint pixels are measured
for interval/layering but excluded from image-only reference comparison only in
an explicitly labeled mask; unmasked scores must also remain available.

Report global and named-region PSNR, maximum/p99 channel error, worst-pixel
coordinates/values, flat colors, gradients, fine lines, alpha and portrait edges.
An unapproved reference amendment and any material unexplained discrepancy
prevent architecture ACCEPT. No score-based reference selection or threshold
reduction. AVPlayer evidence is reused; no claim about physical presentation.

Budget: reuse existing fixtures, short sequential FHD30 exports only, no new
multi-minute run, <=512MiB new artifacts, <=1GiB observed RSS, combined20GiB.

## Investigation addendum — hypotheses, not amended acceptance

The source-quarter edge hypothesis above was falsified by a uniform full-frame
2x white reference: it excluded the last output row/column even though their
centers are inside the canvas. Its first scores remain in the evidence. Use ideal
rectangle coverage for the independent full-frame bilinear comparison; report the
portrait fixture's previously measured native [656,1263) mask separately. This is
not a general source-quarter or floor rasterization rule and is not owner approval.

Compressed H.264 reader buffers may include empty media/edit buffers. Enumerate
coded buffers for diagnostics, but count image-bearing decoded samples on the
30fps output grid for display timing. Invalid duration values must remain labeled
nonfinite in evidence rather than being silently rounded or serialized as zero.
