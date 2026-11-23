# Fidelity to AutoEq

turboEQ takes AutoEq's definition of a good fit and looks for that fit with an optimizer of
its own. This page covers what is ported, how that is checked, and how the search differs
from upstream's.

## Three parts

**What a good fit means is AutoEq's.** The perceptual stage, the loss, the penalties, the
grids and the filter `init()` heuristics are ported, and checked against recorded upstream
output. Anything that changes what a fit optimizes is opt-in.

**How the fit is found is turboEQ's.** The solver, when it stops and where it starts from
are its own, and are judged by the result: the loss reached on the same input, against the
loss AutoEq reaches. A turboEQ fit will not have AutoEq's filter parameters. It is meant to
score as well or better by AutoEq's own measure.

**How you ask and what you get back is turboEQ's too**: the JavaScript binding, the wasm
interface, the EqualizerAPO formatter.

turboEQ works as a drop-in replacement for AutoEq's optimizer, so it never _requires_ you
to do work upstream of it.

## What is ported

| turboEQ                   | AutoEq                  | What it does                                                              |
| ------------------------- | ----------------------- | ------------------------------------------------------------------------- |
| `curve.zig`               | `frequency_response.py` | Interpolate onto the log grid, centre, compensate                         |
| `savgol.zig`, `peaks.zig` | `scipy.signal`          | Savitzky-Golay smoothing and peak detection, with scipy's exact semantics |
| `equalize.zig`            | `frequency_response.py` | The perceptual stage: dip protection, 18 dB/oct slope limit, +6 dB cap    |
| `peq.zig`                 | `peq.py`                | Filter `init()` heuristics, loss, sharpness penalty                       |
| `biquad.zig`              | `peq.py`                | Peaking and shelf biquads                                                 |
| `configs.zig`             | `constants.py`          | `PEQ_CONFIGS` and `PEQ.from_dict`                                         |

The pinned upstream is AutoEq v4.1.2.

## Upstream quirks, kept

Some of upstream's behaviour looks like a bug. Each item below is reproduced on purpose,
because each one changes where the fit starts or which samples it sees:

- `ix10k` compares frequency against the sample rate, not against 10 kHz, so on a 20 Hz to
  20 kHz axis it is the last index.
- The right-to-left slope limiter reverses the data but not the frequency axis. On the
  evenly spaced log grid this changes nothing, with one exception, below.
- The high shelf's `init()` drops an offset that the low shelf's `init()` adds back, so it
  starts `min_ix` samples lower than intended.
- `band_penalty` is defined upstream but never added to the loss. turboEQ ports it only
  because the fixtures record it.

Two upstream quirks are **not** reproduced:

- `AutoEq/peq.yaml` gives its high shelf both a fixed `fc` and frequency bounds, and the
  fixed `fc` makes the bounds dead.
- With `conchaInterference` on, the slope limit is meant to drop to a quarter between 8 and
  11.5 kHz. Because the right-to-left pass keeps the frequency axis ascending, upstream
  applies that limit at 35 to 50 Hz on that pass instead. turboEQ applies it at 8 to 11.5 kHz
  on both passes. The option is off by default, so the default path is unchanged.

## How it is checked

`tools/parity` runs upstream AutoEq over nine cases and records every intermediate array.
Five cases are synthetic curves. Four are real measurements, chosen for deep nulls, rough
treble, heavy bass and a bass roll-off. The Zig port is diffed against all of them:

- Every array agrees to within 5e-10, the floor set by the fixtures' own rounding.
- Every discrete decision matches exactly: peak indices, protection masks, clip points.
- The optimizer is judged on the loss it reached, never on filter parameters (see below).

CI runs the comparison on every push. [tools/parity/README.md](../tools/parity/README.md)
has the tolerances per stage and the reasons behind them.

## The search

All of this is how the fit is _searched for_, never what it _optimizes_.

**The solver.** Upstream calls `fmin_slsqp` with bounds and no other constraints, so a
projected L-BFGS solves the same problem. turboEQ also computes gradients analytically,
where upstream finite-differences them. Different solvers land in different local minima of
near-identical quality, so filter parameters will not match upstream's, but on every parity
case the loss is equal or lower. That is why parity is judged on loss.

**Early stopping is off.** Upstream's `min_std` rule stops when the loss plateaus. That
costs fit quality at every band count, and past a dozen bands it makes more filters fit
_worse_. `upstreamStopRules` restores it.

**One bank by default.** The default is `8_PEAKING_WITH_SHELVES`, where AutoEq's CLI fits
the same ten filters as a two-stage cascade. One joint fit reaches a lower RMSE. The cascade
is available as `configs.autoeq_cli_default` in Zig, or as `banks` in JavaScript.

**Shelves stay pinned** at 105 Hz and 10 kHz, Q 0.7, with only their gain fitted. Every
preset AutoEq ships does the same. Freeing them lowers the loss on most real curves, at 1.5x
the fit time, and you can do it with `peakingBank`'s `shelfPlacement: 'free'` or through
[`banks`](custom-filters.md#describing-the-filters-yourself).

**A second start for the ends of the curve.** AutoEq starts each peaking band on a peak or
dip of the curve, and its peak finder never reports the first or last sample. A bass boost
that keeps rising down to 20 Hz, or a roll-off that keeps falling, has no peak to find.
AutoEq's presets leave such a ramp to the low shelf. A fit with no low shelf starts with no
band there, and the solver rarely moves one down: on a real IEM with 10 dB of bass over a
flat target, ten peaking bands leave 7 dB of it in place, in AutoEq as in turboEQ. So
turboEQ also fits from a second start, one that treats a ramp topping out at either end as
half of a peak centred there, and keeps whichever start reaches the lower loss. It can only
match or beat AutoEq's start by the fit's own measure, and where it applies the fit takes
up to twice as long. An end that any bank has a shelf for is left to the shelf, and a band
with a fixed frequency is not seeded, so the default fit, AutoEq's cascade and a graphic EQ
are each fitted once, as before. `seedEdges: false` is AutoEq's start alone.

**No `max_time`.** The wasm build has no clock. `maxEvaluations` caps the work instead, and
unlike a wall-clock budget it gives the same result on every machine.

[BENCHMARKS.md](../BENCHMARKS.md) has the measurements behind each of these.

## Changes to the objective

Three options change what the fit optimizes, and each applies only when you set it:

- `lossFlattenF` moves or removes the line above which AutoEq scores only the mean level,
  10 kHz, for rigs whose treble you trust.
- `sharpnessPenalty: false` drops the penalty AutoEq puts on peaking bands steeper than
  about 18 dB per octave.
- `equalizationWindowSize` changes or removes the fifth-octave smoothing AutoEq hardcodes as
  the last step of building the curve the optimizer fits.

`fit: 'exact'` sets all three. [Exact match](exact-match.md) covers them.

## Out of scope

Impulse responses, CSV I/O, batch processing, the README writer and the Harman preference
scores. Those belong to AutoEq the application, not AutoEq the optimizer. Impulse responses
would also need an FFT, which would cost more wasm than the whole port.
