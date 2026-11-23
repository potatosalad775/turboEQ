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

## Edge ramps

Three more files, for `seedEdges`. They are inputs to `tools/wasm_smoke/smoke.mjs` and not
parity cases: the option is not upstream's, so there is no recorded output to hold it to.

| File                        | Why this one                                                                                                                                                                                                                     |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bass_ramp_iem.txt`         | A bass boost that keeps rising to the first sample: +9.6 dB at 20–40 Hz relative to 200 Hz–2 kHz, with no peak for `init()` to find. Against a flat target, a peaking-only fit leaves it uncorrected. 481 points at 1/48 octave. |
| `bass_rolloff_overear.txt`  | The same shape as a deficit: an open-back's roll-off, 9.5 dB short of Harman's over-ear target at 20–40 Hz, relative to 200 Hz–2 kHz. A peaking-only exact fit puts its lowest band above 1 kHz. 955 points at 1/96 octave.      |
| `target_harman_oe_2018.txt` | Harman over-ear 2018, the target the roll-off is measured against. From AutoEq's `targets/`, unmodified.                                                                                                                         |

The two measurements are by potatosalad775, from the same rigs, unmodified.

Upstream fails the same way. AutoEq v4.1.2's `10_PEAKING` on `bass_ramp_iem.txt` against a flat
target ends at an RMSE of 3.0 dB with its lowest band near 290 Hz; `8_PEAKING_WITH_SHELVES`
reaches 0.2.

They are not in `curves.REAL_CASES` yet. Generated as parity cases, `bass_ramp_iem.txt` has
turboEQ's shelved fits landing above upstream's loss (`8_PEAKING_WITH_SHELVES` 0.271 against
0.096), which has nothing to do with seeding and wants looking into before the case is pinned.

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
