# Measured results

Every number turboEQ quotes, with the command that produced it. The decisions
these numbers support are argued in `CLAUDE.md`; this file is the evidence.

Timings are wall clock on one machine and do not travel. Ratios between rows
do; absolute milliseconds do not. Re-measure rather than trust.

|         |                                    |
| ------- | ---------------------------------- |
| Date    | 2026-09-24                         |
| Machine | Mac Mini (M4), macOS (Darwin 27.2) |
| Zig     | 0.16.0                             |
| Node    | v24.18.1                           |

Everything below was measured on that date, against the build of that date,
except the sections that carry a date of their own. "SIMD" is
`turboeq-simd.wasm`, which `TurboEQ.load()` picks wherever the engine supports
it; "plain" is `turboeq.wasm`, the fallback. The two return bit-identical
fits, so they differ only in time.

**The project has since moved to Zig 0.17.1**, on 2026-11-23, and the dated
sections were measured with it. The compiler changed nothing a fit can see:
over 107 IEMs, the 0.16.0 and 0.17.1 builds of one source returned the same
loss, RMSE and evaluation count on all 749 fits compared (8, 12, 16 and 20
bands with shelves; 5, 8 and 10 without), and `candidate.json` came out
byte for byte the same. Time moved by a few percent in either direction, 0.94
to 1.04 of 0.16.0's by layout. So the
undated sections' losses and counts stand, and their times are as good as
they were.

```sh
node tools/soak/soak.mjs ... --wasm ZIG_0_16.wasm --tsv a.tsv DIR
node tools/soak/soak.mjs ... --wasm ZIG_0_17.wasm --tsv b.tsv DIR
node tools/soak/compare.mjs a.tsv b.tsv      # every loss ratio 1.0000, no fit better or worse
```

---

## Real measurements

```sh
zig build wasm
node tools/soak/soak.mjs --target IEM_TARGET --peaking 8,12,16,20 IEM_DIR
node tools/soak/soak.mjs --target HEADPHONE_TARGET --peaking 8,12,16,20 HEADPHONE_DIR
# add --wasm zig-out/bin/turboeq-simd.wasm for the SIMD build
```

Every measurement in a [silicagel.squig.link](https://silicagel.squig.link) deployment,
each channel on its own: 1,154 IEMs against its Harman IE 2019v2 target and
156 headphones against its Harman 2018 target. Shelves on, so `peaking`
bands plus two. Through `js/turboeq.js` under Node, one fit after another.
The measurements are not in the repo; the script is, and runs on
`tools/parity/real` as it stands.

**IEMs, 1,154**

| Peaking | SIMD p50 | p90     | p99     | max    | plain p50 | p99     | Evals p50 | p99    |
| ------- | -------- | ------- | ------- | ------ | --------- | ------- | --------- | ------ |
| 8       | 12.3 ms  | 26.9 ms | 49.0 ms | 103 ms | 15.8 ms   | 61.8 ms | 377       | 1,566  |
| 12      | 54.4 ms  | 124 ms  | 229 ms  | 368 ms | 68.4 ms   | 289 ms  | 1,214     | 5,120  |
| 16      | 155 ms   | 348 ms  | 558 ms  | 984 ms | 198 ms    | 714 ms  | 2,757     | 10,084 |
| 20      | 359 ms   | 805 ms  | 1.32 s  | 1.43 s | 455 ms    | 1.66 s  | 5,083     | 18,783 |

**Headphones, 156**

| Peaking | SIMD p50 | p90     | p99     | max     | plain p50 | p99     | Evals p50 | p99   |
| ------- | -------- | ------- | ------- | ------- | --------- | ------- | --------- | ----- |
| 8       | 8.8 ms   | 17.4 ms | 27.0 ms | 29.6 ms | 11.1 ms   | 34.7 ms | 266       | 886   |
| 12      | 30.8 ms  | 64.2 ms | 96.2 ms | 118 ms  | 39.4 ms   | 132 ms  | 687       | 2,161 |
| 16      | 74.6 ms  | 154 ms  | 258 ms  | 287 ms  | 94.3 ms   | 330 ms  | 1,209     | 4,377 |
| 20      | 178 ms   | 369 ms  | 544 ms  | 659 ms  | 220 ms    | 620 ms  | 2,337     | 6,674 |

All 5,240 fits returned exactly the filters asked for, inside every bound,
finite, with a non-positive preamp. All but 42 stopped on the function
tolerance; 35 stopped on the line search, and 7 of the 1,154 twenty-band IEM
fits reached the cap of 20,000 evaluations. Plain and SIMD agreed on every
evaluation count, loss and RMSE.

For a ten-filter fit on real input, quote the 8-band rows: 12 ms at the
median with SIMD and 15 ms without, across all 1,310.

---

## Against upstream AutoEq

```sh
zig build bench-fit -Doptimize=fast -- --csv 2> turboeq_fit.csv
python tools/parity/time_upstream.py --turboeq turboeq_fit.csv   # needs AutoEq/
```

Fit only, on every parity fixture's recorded optimizer grid and target: build
the filters, run `init()`, fit. The perceptual stage is the same code on both
sides and is left out. Upstream is AutoEq v4.1.2 under Python 3.14.7, numpy
2.5.3, scipy 1.18.1; turboEQ is native `fast` (ReleaseFast, as Zig 0.16
called it). Median of 5 runs upstream, 9 for turboEQ. The table predates the
ninth parity case, `real_bass_rolloff`, which the commands above now time too.

`turboEQ` is the time to reach the loss upstream recorded in the fixture, so
the two are compared at equal quality. `*` marks rows where upstream found a
slightly lower loss on this machine than the fixture records, which makes
that row a little generous to turboEQ. The last two columns are turboEQ's
default, running to convergence.

| Case              | Config                 | AutoEq   | loss   | turboEQ   | Speedup | turboEQ, converged | loss   |
| ----------------- | ---------------------- | -------- | ------ | --------- | ------- | ------------------ | ------ |
| gentle_vs_flat    | 4_PEAKING_WITH_SHELVES | 22.1 ms  | 0.2384 | 0.95 ms   | 23x     | 3.22 ms            | 0.2067 |
| gentle_vs_flat    | 8_PEAKING_WITH_SHELVES | 53.1 ms  | 0.1566 | 0.58 ms * | 91x     | 43.22 ms           | 0.0494 |
| gentle_vs_flat    | 10_PEAKING             | 233.3 ms | 0.0665 | 3.12 ms * | 75x     | 18.08 ms           | 0.0256 |
| bumpy_vs_flat     | 4_PEAKING_WITH_SHELVES | 20.6 ms  | 1.2039 | 0.29 ms   | 70x     | 0.94 ms            | 1.1894 |
| bumpy_vs_flat     | 8_PEAKING_WITH_SHELVES | 106.4 ms | 0.3384 | 0.79 ms * | 135x    | 3.72 ms            | 0.3302 |
| bumpy_vs_flat     | 10_PEAKING             | 134.3 ms | 0.2198 | 0.70 ms   | 193x    | 7.26 ms            | 0.1528 |
| bumpy_vs_harman   | 4_PEAKING_WITH_SHELVES | 17.2 ms  | 0.9369 | 0.32 ms   | 53x     | 0.98 ms            | 0.9303 |
| bumpy_vs_harman   | 8_PEAKING_WITH_SHELVES | 76.9 ms  | 0.2924 | 0.82 ms   | 94x     | 3.40 ms            | 0.2773 |
| bumpy_vs_harman   | 10_PEAKING             | 74.1 ms  | 3.0843 | 0.70 ms   | 106x    | 11.61 ms           | 0.3716 |
| noisy_dip_vs_flat | 4_PEAKING_WITH_SHELVES | 19.4 ms  | 1.1747 | 0.31 ms   | 63x     | 0.92 ms            | 1.1604 |
| noisy_dip_vs_flat | 8_PEAKING_WITH_SHELVES | 94.5 ms  | 0.3863 | 0.83 ms * | 114x    | 3.78 ms            | 0.3800 |
| noisy_dip_vs_flat | 10_PEAKING             | 122.6 ms | 0.1928 | 1.38 ms   | 89x     | 5.67 ms            | 0.1865 |
| bumpy_coarse_grid | 4_PEAKING_WITH_SHELVES | 17.9 ms  | 1.1982 | 0.28 ms   | 65x     | 1.16 ms            | 1.1807 |
| bumpy_coarse_grid | 8_PEAKING_WITH_SHELVES | 94.5 ms  | 0.3356 | 0.93 ms * | 102x    | 4.09 ms            | 0.3228 |
| bumpy_coarse_grid | 10_PEAKING             | 117.1 ms | 0.2153 | 0.71 ms   | 165x    | 7.69 ms            | 0.1441 |
| real_rough_treble | 4_PEAKING_WITH_SHELVES | 34.6 ms  | 0.3065 | 0.24 ms   | 142x    | 0.80 ms            | 0.2711 |
| real_rough_treble | 8_PEAKING_WITH_SHELVES | 136.6 ms | 0.1259 | 1.95 ms   | 70x     | 11.05 ms           | 0.0989 |
| real_rough_treble | 10_PEAKING             | 312.1 ms | 0.1136 | 7.26 ms   | 43x     | 44.88 ms           | 0.0921 |
| real_deep_dip     | 4_PEAKING_WITH_SHELVES | 20.7 ms  | 0.8853 | 0.21 ms   | 100x    | 1.81 ms            | 0.8264 |
| real_deep_dip     | 8_PEAKING_WITH_SHELVES | 67.8 ms  | 0.4548 | 0.52 ms   | 130x    | 11.82 ms           | 0.3460 |
| real_deep_dip     | 10_PEAKING             | 288.6 ms | 0.5097 | 1.56 ms   | 185x    | 12.18 ms           | 0.4160 |
| real_bass_shelf   | 4_PEAKING_WITH_SHELVES | 23.7 ms  | 0.3842 | 0.36 ms   | 65x     | 1.73 ms            | 0.3654 |
| real_bass_shelf   | 8_PEAKING_WITH_SHELVES | 110.8 ms | 0.1344 | 0.80 ms   | 139x    | 10.37 ms           | 0.0833 |
| real_bass_shelf   | 10_PEAKING             | 150.3 ms | 0.1629 | 1.77 ms   | 85x     | 18.50 ms           | 0.1439 |

**23x to 193x, median 92x**, over 24 fits. Most of it is the gradients:
scipy gets none, so `fmin_slsqp` finite-differences them at roughly `3N+1`
loss evaluations per iteration — 31 at 10 peaking bands. turboEQ's are
analytic.

Running to convergence costs 3x to 75x more than stopping at upstream's loss,
and is still faster than upstream in every row while landing lower in every
row — at `gentle_vs_flat` with 8 peaking bands and shelves, 0.0494
against upstream's 0.1566.

### Loss against upstream on real measurements (2026-11-23)

```sh
python tools/parity/survey_upstream.py --target tools/parity/real/target_harman_ie_2019v2.txt \
    --every 5 --out survey IEM_DIR                               # needs AutoEq/
zig build bench-fit -Doptimize=fast -- --reps 1 --csv --fixtures survey 2> survey.csv
python tools/parity/survey_upstream.py --summarize survey.csv
# again with --second-start after --reps 1
```

The fixtures are nine cases. This is the same comparison, converged loss
against the loss upstream reached on the same optimizer inputs, over every
fifth of the 1,190 IEMs below: 238 curves, Harman IE 2019v2. Upstream is
AutoEq v4.1.2 under Python 3.15.2, numpy 2.5.5, scipy 1.18.1. The ratio is
turboEQ's loss over upstream's, so below 1 is a better fit.

| Config                   | Start             | Ratio, median | p90   | max   | Above upstream | by >10% |
| ------------------------ | ----------------- | ------------- | ----- | ----- | -------------- | ------- |
| `4_PEAKING_WITH_SHELVES` | upstream's        | 0.967         | 0.993 | 1.00  | 0              | 0       |
| `8_PEAKING_WITH_SHELVES` | upstream's        | 0.736         | 0.926 | 0.99  | 0              | 0       |
| `10_PEAKING`             | upstream's        | 0.591         | 0.996 | 13.31 | 15             | 13      |
| `10_PEAKING`             | the better of two | 0.343         | 0.964 | 10.40 | 10             | 10      |

With shelves, turboEQ did not end above upstream once. Without them it did on
15 of 238 from upstream's start, by up to 13x, and the second start below
brings that to 10 and takes the median from 0.59 of upstream's loss to 0.34.
The second start changes nothing in the shelved rows, which is the point of
its gate. The ten left over are ordinary local minima: ten free peaking bands
with nothing pinned have many, and neither solver finds the best of them
every time. `tools/parity/real/README.md` has one shelved curve, against a
flat target, where turboEQ loses to upstream as well.

---

## What the defaults cost and buy

```sh
node tools/soak/soak.mjs --target IEM_TARGET --peaking 8,12,16,20 --tsv default.tsv IEM_DIR
node tools/soak/soak.mjs ... --options '{"minStd":0.008}' --tsv minstd.tsv IEM_DIR
node tools/soak/soak.mjs ... --banks tools/soak/banks/cli-default.json --tsv cascade.tsv IEM_DIR
node tools/soak/soak.mjs ... --banks tools/soak/banks/free-shelves.json --tsv free.tsv IEM_DIR
node tools/soak/compare.mjs default.tsv minstd.tsv cascade.tsv free.tsv
```

The 1,154 IEMs above, SIMD build. RMSE is across the whole axis, not the
loss the solver minimizes, which is what makes it comparable between
layouts; a cascade reports only its last bank's loss.

### Early stopping stays off

Upstream ships `min_std = 0.008` for the shelved presets.

| Peaking | `minStd` | RMSE median | p50     | Evals vs off |
| ------- | -------- | ----------- | ------- | ------------ |
| 8       | off      | **0.3250**  | 12.3 ms |              |
| 8       | 0.008    | 0.4323      | 0.9 ms  | 3.2%         |
| 12      | off      | **0.2622**  | 54.4 ms |              |
| 12      | 0.008    | 0.4117      | 1.1 ms  | 1.0%         |
| 16      | off      | **0.2572**  | 155 ms  |              |
| 16      | 0.008    | 0.4010      | 1.4 ms  | 0.5%         |
| 20      | off      | **0.2663**  | 359 ms  |              |
| 20      | 0.008    | 0.3976      | 1.7 ms  | 0.3%         |

The rule stops within the first few percent of the work, on a plateau. Not
one of the 4,616 fits got better, and 4,614 got more than 1% worse: loss up
60% at the median with 8 bands and 4.8x with 20. Twenty bands stopped early
fit worse than eight run to convergence.

### One bank, not a cascade

Ten filters either way.

| Layout                                                      | RMSE median | p50     |
| ----------------------------------------------------------- | ----------- | ------- |
| `8_PEAKING_WITH_SHELVES`, one bank                          | **0.3250**  | 12.3 ms |
| `4_PEAKING_WITH_LOW_SHELF` then `4_PEAKING_WITH_HIGH_SHELF` | 0.4224      | 3.4 ms  |

The cascade is faster because each half solves a smaller problem, and worse
because neither half sees the whole curve.

### Shelves stay pinned

| Shelves                              | RMSE median | p50     |
| ------------------------------------ | ----------- | ------- |
| Pinned at 105 Hz and 10 kHz, Q 0.7   | 0.3250      | 12.3 ms |
| Free within `DEFAULT_SHELF_FILTER_*` | **0.2778**  | 19.4 ms |

Freeing the shelves fits better: 713 of the 1,154 by more than 1% in loss,
400 worse, for 1.5x the time. The default pins them anyway, because every
preset upstream ships does. A caller who wants them free writes the bank out,
as `tools/soak/banks/free-shelves.json` does.

### A second start where no shelf has the end (2026-11-23)

```sh
node tools/soak/soak.mjs --target IEM_TARGET --peaking 5,8,10 --no-shelves \
    --options '{"seedEdges":false}' --tsv plain.tsv IEM_DIR
node tools/soak/soak.mjs --target IEM_TARGET --peaking 5,8,10 --no-shelves --tsv both.tsv IEM_DIR
node tools/soak/compare.mjs plain.tsv both.tsv
```

`seedEdges`, on by default. The same deployment as above, which has grown to
1,190 IEMs; 156 headphones as before. SIMD build, Zig 0.17.1, no shelves, so
`peaking` bands and nothing else. "Upstream's" is `seedEdges: false`, one fit
from AutoEq's `init()`; "both" fits from that start and from the seeded one
and keeps the lower loss.

**IEMs, 1,190, AutoEq's objective**

| Peaking | RMSE median, upstream's | both      | p50, upstream's | both    | Loss better >1% | worse |
| ------- | ----------------------- | --------- | --------------- | ------- | --------------- | ----- |
| 5       | 1.071                   | **0.910** | 2.2 ms          | 4.5 ms  | 468             | 0     |
| 8       | 0.742                   | **0.623** | 10.7 ms         | 22.1 ms | 619             | 0     |
| 10      | 0.652                   | **0.560** | 25.6 ms         | 53.4 ms | 621             | 0     |

**Headphones, 156, AutoEq's objective**

| Peaking | RMSE median, upstream's | both      | p50, upstream's | both    | Loss better >1% | worse |
| ------- | ----------------------- | --------- | --------------- | ------- | --------------- | ----- |
| 5       | 1.831                   | **1.696** | 1.9 ms          | 3.4 ms  | 52              | 0     |
| 8       | 1.234                   | **1.089** | 7.2 ms          | 14.8 ms | 63              | 0     |
| 10      | 1.033                   | **1.003** | 16.5 ms         | 30.2 ms | 83              | 0     |

**IEMs, 1,190, `fit: 'exact'`**

| Peaking | RMSE median, upstream's | both      | p50, upstream's | both    | Loss better >1% | worse |
| ------- | ----------------------- | --------- | --------------- | ------- | --------------- | ----- |
| 5       | 1.710                   | **1.614** | 1.9 ms          | 3.6 ms  | 375             | 0     |
| 8       | 1.335                   | **1.228** | 7.2 ms          | 14.7 ms | 465             | 0     |
| 10      | 1.200                   | **1.095** | 15.0 ms         | 30.6 ms | 476             | 0     |

A third to a half of peaking-only fits end more than 1% lower in loss, the
8- and 10-band IEM fits at the tenth percentile at a fifth of the loss, for
1.8x to 2.0x the time. No fit of the 7,608 ended higher: the better of two
starts cannot lose to the first. A ramp at the end of the curve is not an
edge case against a Harman target, whose bass shelf leaves one on most
earphones.

The loss is not the RMSE under AutoEq's objective, which penalizes steep
bands and scores only the mean above 10 kHz. So a lower loss came with an RMSE
more than 0.1 dB higher on 9, 33 and 60 of the 1,190 IEM fits at 5, 8 and 10
bands, by 0.73 dB at most, against 296, 335 and 311 that came out more than
0.1 dB lower, by up to 4.35 dB. Under exact match, where the two nearly
coincide, no RMSE rose by more than 0.04 dB.

**The gate is per run.** An end is seeded only if no bank of the run has a
shelf for it, and only bands free to move are. With the gate per bank, as it
first was, each half of AutoEq's CLI cascade was seeded at the end the other
half's shelf is there for. Measured on the build before the gate changed:

| CLI cascade, 1,190 IEMs | RMSE median | Time  |
| ----------------------- | ----------- | ----- |
| One start per bank      | 0.423       | 1.00x |
| Seeded bank by bank     | 0.413       | 1.62x |

That is 0.01 dB for 1.6x, with 8 fits more than 0.1 dB worse in RMSE beside
20 better. Per run, the cascade, the default `8_PEAKING_WITH_SHELVES` and a
graphic EQ are fitted once: the 1,190 cascade fits and the 1,190 default fits
return the same filters after the same number of evaluations as with
`seedEdges: false`.

---

## Before and after the fit-cost work

```sh
node tools/soak/soak.mjs --target tools/parity/real/target_harman_ie_2019v2.txt \
    --peaking 8,12,16,20 --wasm BUILD.wasm --tsv BUILD.tsv MEASUREMENTS_DIR
node tools/soak/compare.mjs before.tsv noise.tsv after.tsv
```

This is the evidence that the fit-cost work cost nothing, on a set anyone
can download: every in-ear measurement in AutoEq's
`measurements/oratory1990/data/in-ear`, 212 curves, Harman IE 2019v2. `before` is the module as of 2026-09-23. `noise` is that
module with only the last bits of its kernel moved, one logarithm and the
reciprocals and nothing else: how far a fit wanders when nothing that matters
changes. Time and evaluations are ratios of the sum over all 212, loss the
ratio fit by fit.

| Build | Peaking | Time  | Evals | Loss median | p10   | p90   | worse >1% | better >1% | Capped |
| ----- | ------- | ----- | ----- | ----------- | ----- | ----- | --------- | ---------- | ------ |
| noise | 12      | 0.687 | 0.983 | 1.0000      | 0.959 | 1.071 | 37        | 39         | 0      |
| noise | 20      | 0.712 | 1.024 | 0.9996      | 0.800 | 1.132 | 63        | 86         | 33     |
| after | 8       | 0.593 | 1.006 | 1.0000      | 1.000 | 1.000 | 9         | 6          | 0      |
| after | 12      | 0.534 | 0.915 | 1.0000      | 0.963 | 1.103 | 37        | 41         | 0      |
| after | 16      | 0.453 | 0.770 | 1.0000      | 0.866 | 1.137 | 53        | 65         | 0      |
| after | 20      | 0.378 | 0.603 | 1.0000      | 0.776 | 1.199 | 71        | 80         | 5      |

`before` hit the 20,000-evaluation cap on 1 sixteen-band and 22 twenty-band
fits. The SIMD build's time ratios are 0.469, 0.418, 0.355 and 0.304 on the
`after` rows; its loss columns are the plain build's. **2.6x faster at 20 bands, 3.3x
with SIMD, at unchanged quality**: the loss ratio's median is 1.0000 at every
band count and its spread is the noise build's. Moving the last bit of one
logarithm sends 36% of 12-band fits and 70% of 20-band fits more than 1% up
or down, which is why a change to the solver is judged over hundreds of
curves and never over three.

### A cheaper evaluation (2026-11-24)

```sh
node tools/soak/soak.mjs --target TARGET --peaking 8,18,28 --options '{"fit":"exact"}' \
    --wasm BUILD.wasm --tsv BUILD.tsv MEASUREMENTS_DIR      # and without --options
node tools/soak/compare.mjs before.tsv after.tsv
```

Two changes, measured together against the build before them. The line
search prices a trial by its value alone and asks for the gradient once the
trial is accepted: 17% of evaluations at 10 filters and 30% at 30 are rejected
trials whose gradient was thrown away. And a fit without the sharpness
penalty, which is `fit: 'exact'`, takes one logarithm per sample for the
whole cascade where it took one per filter, and no longer keeps each filter's
own response, which only the penalty reads.

129 measurements, the sample set modernGraphTool ships
(`defaults/data/phones`, Harman IE 2019v2), SIMD build, before and after
interleaved over three rounds (two for the no-shelf row). The exact rows'
time ratios agreed within 0.015 from round to round. Time and evaluations
are ratios of the sum over all 129, loss the ratio fit by fit.

| Options                | Filters | Time  | Mean fit, before | after  | Evals | Loss median | p10   | p90   | worse >1% | better >1% | Capped |
| ---------------------- | ------- | ----- | ---------------- | ------ | ----- | ----------- | ----- | ----- | --------- | ---------- | ------ |
| exact                  | 8 + 2   | 0.504 | 12 ms            | 6 ms   | 1.038 | 1.0000      | 1.000 | 1.000 | 4         | 4          | 0 → 0  |
| exact                  | 18 + 2  | 0.437 | 243 ms           | 106 ms | 0.984 | 1.0001      | 0.884 | 1.131 | 39        | 33         | 0 → 0  |
| exact                  | 28 + 2  | 0.395 | 1,161 ms         | 458 ms | 0.891 | 1.0003      | 0.867 | 1.104 | 49        | 48         | 10 → 4 |
| exact, no shelves      | 28      | 0.433 | 2,171 ms         | 938 ms | 0.977 | 1.0006      | 0.934 | 1.051 | 42        | 27         | 10 → 9 |
| default (with penalty) | 8 + 2   | 0.953 | 18 ms            | 17 ms  | 1.000 | 1.0000      | 1.000 | 1.000 | 0         | 0          | 0 → 0  |
| default (with penalty) | 18 + 2  | 0.978 | 351 ms           | 343 ms | 1.000 | 1.0000      | 1.000 | 1.000 | 0         | 0          | 0 → 0  |

**With the penalty every fit is the same to the bit**: the same loss, RMSE
and evaluation count on all 258, so the rows above differ only by the
gradients no longer computed, and by less than the rounds differ from each
other (0.93 to 1.01). **Without it a fit takes 0.40 to 0.50 of the time**, and
the loss moves the way a last-bit change moves it: a median of 1.000 and as
many fits better as worse, except the no-shelf row, where 42 ended more than
1% up and 27 down for a geometric mean of 1.007. The plain build's time
ratios on the exact rows are 0.54, 0.46 and 0.41, and it returns the SIMD
build's fits to the bit.

Tried beside these and left out: keeping each filter's numerator and
denominator from the response pass for the gradient pass was the same fits
for 0.95 of the time and two more buffers, and one division per filter per
sample where there are two was no faster at all. The time is in the
logarithms, not the divisions.

---

## wasm module

```sh
zig build wasm                         # the small mode, the default
zig build wasm -Dwasm-optimize=fast
```

Sizes as of 2026-11-23, Zig 0.17.1, which calls the modes `small` and `fast`
where 0.16 had ReleaseSmall and ReleaseFast.

| Build                                  | raw       | gzip -9  |
| -------------------------------------- | --------- | -------- |
| `small`, `turboeq.wasm` (shipped)      | 83,382 B  | 38,015 B |
| `small`, `turboeq-simd.wasm` (shipped) | 83,365 B  | 38,407 B |
| `fast`, `turboeq.wasm`                 | 123,927 B | 46,554 B |
| `fast`, `turboeq-simd.wasm`            | 119,989 B | 45,413 B |

A browser fetches one of the two shipped builds. Over the 1,154 IEMs at 8
and 12 bands, measured with 0.16.0, `fast` was 2% to 3% faster than `small`
in either build and returned the same fits to the bit. Half again the module
for 3% is why `small` is the default.

---

## wasm heap

```sh
zig build wasm && node tools/wasm_smoke/smoke.mjs   # prints "heap used"
```

|                                               |           |
| --------------------------------------------- | --------- |
| Arena declared                                | 8 MiB     |
| High water, 10-filter fit on a 479-point grid | 181 KiB   |
| High water, 156 headphones up to 20 bands     | 282 KiB   |
| High water, 1,154 IEMs up to 20 bands         | 1,957 KiB |

The input curves are the only term that scales with the caller rather than
the working grid, at 16 bytes per point per side. The IEM figure is one
measurement of 54,558 points; the rest of the set has 479 to 957.
Over-declaring the arena costs nothing: the engine commits only the pages
written. `teq_heap_used` includes what a bump allocator cannot reclaim.

---

## Parity harness

```sh
zig build test && zig build dump && python tools/parity/compare.py candidate.json
```

451 pass, 39 better, 0 fail, 0 skip, over nine cases — five synthetic, four
real measurements. `BETTER` means a lower loss than upstream reached, which
invariant 4 expects.
