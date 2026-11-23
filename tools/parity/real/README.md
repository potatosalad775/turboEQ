# Real measurement curves

Four files to begin with, used as parity-fixture inputs alongside the synthetic curves in
`curves.py`. They are here because synthetic curves are smooth in ways real
measurements are not, and the branchy parts of the pipeline — peak and dip
detection, the protection mask, the slope limiter, the treble sigmoid — take
their decisions from exactly the structure a generated curve lacks.

Measured by potatosalad775, from the rigs behind
[silicagel.squig.link](https://silicagel.squig.link). Used here with
permission by myself, unmodified.

| File                          | Why this one                                                                                                                                                        |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rough_treble_iem.txt`        | Roughest treble in the set: 1.64 dB mean step between adjacent samples above 8 kHz. 479 points on a ~1/47-octave grid.                                              |
| `deep_dip_overear.txt`        | Deepest narrow null: 27.9 dB below its own 1/3-octave neighbourhood at 9.7 kHz, against 11.9 dB for the synthetic `noisy_narrow_dip`. 956 points at 1/96 octave.    |
| `bass_heavy_iem.txt`          | Largest bass tilt: +16.9 dB at 20–80 Hz relative to 500 Hz, with a 20.5 dB dip on top. Exercises the shelf init heuristics and the slope limiter over the bass.     |
| `target_harman_ie_2019v2.txt` | Harman in-ear 2019, a real target on a different axis from either source, so the two no longer share a grid. AutoEq's `targets/Harman in-ear 2019.csv`, unmodified. |

## Edge ramps

Three more files, added for `seedEdges`, the second start `pipeline.run` tries where no shelf
has an end of the curve. All three are inputs to `tools/wasm_smoke/smoke.mjs`. The roll-off and
its target are also the parity case `real_bass_rolloff`; the ramp is not a case, for the reason
below.

| File                        | Why this one                                                                                                                                                                                                                     |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bass_ramp_iem.txt`         | A bass boost that keeps rising to the first sample: +9.6 dB at 20–40 Hz relative to 200 Hz–2 kHz, with no peak for `init()` to find. Against a flat target, a peaking-only fit leaves it uncorrected. 481 points at 1/48 octave. |
| `bass_rolloff_overear.txt`  | The same shape as a deficit: an open-back's roll-off, 9.5 dB short of Harman's over-ear target at 20–40 Hz, relative to 200 Hz–2 kHz. A peaking-only exact fit puts its lowest band above 1 kHz. 955 points at 1/96 octave.      |
| `target_harman_oe_2018.txt` | Harman over-ear 2018, the target the roll-off is measured against. AutoEq's `targets/Harman over-ear 2018.csv`, unmodified.                                                                                                      |

The two measurements are by potatosalad775, from the same rigs, unmodified.

Upstream fails the same way. AutoEq v4.1.2's `10_PEAKING` on `bass_ramp_iem.txt` against a flat
target ends at an RMSE of 3.0 dB with its lowest band near 290 Hz; `8_PEAKING_WITH_SHELVES`
reaches 0.2.

### Why `bass_ramp_iem.txt` is not a parity case

Generated as a case against a flat target, it fails the comparator on the optimizer and on
nothing else. Every pipeline stage and every `init()` matches upstream. The fits that have a
shelf then end above the loss upstream reached:

| Config                                  | turboEQ | Upstream |
| --------------------------------------- | ------- | -------- |
| `8_PEAKING_WITH_SHELVES`                | 0.2707  | 0.0918   |
| `QUDELIX_5K`                            | 0.2691  | 0.0932   |
| `4_PEAKING_WITH_LOW_SHELF`              | 0.5333  | 0.4613   |
| `4_PEAKING_WITH_HIGH_SHELF`, in cascade | 0.3008  | 0.1336   |

`10_PEAKING` comes out below upstream, 2.618 against 2.974. Seeding has no part in any of
this, since the harness fits from upstream's start alone.

It is a local minimum and not a bug in the port. In `8_PEAKING_WITH_SHELVES`, turboEQ ends
with one band at 196 Hz against the lower bound on Q, where upstream moved the same band down
to 68 Hz. Restarting the solver from where it stopped does not move it. Started from
upstream's filters instead, it reaches 0.0510, below what upstream stopped at. So a better
basin is there and the path from `init()` misses it.

It also looks rare. Over 238 other earphone measurements against Harman in-ear 2019, fitted
from the same optimizer inputs as upstream, neither `4_PEAKING_WITH_SHELVES` nor
`8_PEAKING_WITH_SHELVES` ended above upstream's loss once.

Pinning the case would mean either a solver that finds the better basin or a comparator that
tolerates this one, and the second would be the wrong way round.

## How the first four were picked

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
