# Real measurement curves

Four files, used as parity-fixture inputs alongside the synthetic curves in
`curves.py`. They are here because synthetic curves are smooth in ways real
measurements are not, and the branchy parts of the pipeline — peak and dip
detection, the protection mask, the slope limiter, the treble sigmoid — take
their decisions from exactly the structure a generated curve lacks.

Measured by potatosalad775, from the rigs behind
[silicagel.squig.link](https://silicagel.squig.link). Used here with
permission by myself, unmodified.

| File                          | Why this one                                                                                                                                                     |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rough_treble_iem.txt`        | Roughest treble in the set: 1.64 dB mean step between adjacent samples above 8 kHz. 479 points on a ~1/47-octave grid.                                           |
| `deep_dip_overear.txt`        | Deepest narrow null: 27.9 dB below its own 1/3-octave neighbourhood at 9.7 kHz, against 11.9 dB for the synthetic `noisy_narrow_dip`. 956 points at 1/96 octave. |
| `bass_heavy_iem.txt`          | Largest bass tilt: +16.9 dB at 20–80 Hz relative to 500 Hz, with a 20.5 dB dip on top. Exercises the shelf init heuristics and the slope limiter over the bass.  |
| `target_harman_ie_2019v2.txt` | Harman IE 2019v2 - A real target, on a different axis from either source, so the two no longer share a grid.                                                     |

Picked by measurement rather than by taste: `profile.py` in the harness
history ranked every curve in that repo by dip depth, treble roughness, bass
tilt and total span, and these are the extremes.

Two formats appear, and the loader handles both: measurement files are
tab-separated with no header and sometimes carry a third phase column, target
files are comma-separated with a `frequency,raw` header.

Neither measurement grid is AutoEq's 1.01 ratio — they are 1/96 and about
1/47 octave — so the interpolator sees a real resampling rather than a
near-identity one. The target file happens to be on the 1.01 grid already,
which is the useful contrast: within one case, one curve is resampled hard
and the other is not.
