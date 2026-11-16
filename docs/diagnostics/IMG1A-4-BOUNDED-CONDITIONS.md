# IMG-1A-4 bounded conditions (before measurement)

No original contract amendment: PSNR >=40dB and flat-field maximum <=3.
The proposed bilinear reference remains unapproved; old CG scores are preserved.

Five FHD 1920x1080 RGBA8 sources at identity scale over the same existing generated
opaque video: opaque, transparent, alpha128/255 solid, horizontal alpha gradient,
sharp alpha0/128/255 boundary. Actual source bytes define premultiplication;
rounding is explicit. The independent encoded-sRGB Porter-Duff calculation is
cross-checked against 1:1 CG source-over, with linear-light blending separately
reported. No spatial resampling or source replacement to improve scores.

Trace source PNG round trip, writer BGRA, decoded ProRes BGRA+ICC, independent
composition of decoded sources, native composition BGRA+ICC, generator preview,
and final H.264. Record global/local maxima, PSNR and worst coordinates. Final
chroma loss and pre-export blending error are separate stages.

Bounded correction controls: only explicit premultiplied/straight alpha input
metadata for the 50% case, with bytes adjusted to the declared representation.
No further tuning sweep. One alternative: precompose the half/gradient/edge cases
against this fixed known background before the opaque video cache. This cannot
stand in for independently editable/moving/video backgrounds.

Maximum ten 2-second final exports and ten 1-second caches, sequential. No long
export. <=512MiB experiment outputs, combined20GiB, observed RSS stop at1GiB.
Reuse earlier AVPlayer evidence. One targeted high-bit relevance check; no HDR.
Stop after this matrix, metadata controls, alternative and report evidence suffice.
