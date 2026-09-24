# Parity harness

Ground truth for the Zig port. `dump_fixtures.py` runs upstream AutoEq and
records every intermediate array to JSON. `compare.py` diffs a candidate
implementation against those recordings, stage by stage.

The point is that you can port **one stage at a time** and keep it green.
Anything the candidate has not implemented reports as `SKIP`, not as a
failure, so partial work still runs clean.

## Setup

Checking a candidate needs neither of these — the fixtures are committed.
This is the setup for _regenerating_ them.

```sh
git clone --filter=blob:none --sparse https://github.com/jaakkopasanen/AutoEq.git AutoEq
git -C AutoEq sparse-checkout set autoeq
git submodule update --init AutoEq
python -m pip install -r tools/parity/requirements.txt
```

The sparse path has to be set before the first checkout, which is why this
clones rather than letting `submodule update --init` do it: the pin carries
75,797 files and the harness reads fifteen of them.

AutoEq itself is not installed as a package. Both scripts add `AutoEq/` to
`sys.path` directly, so the submodule checkout is what gets measured — which
is why it is pinned by gitlink rather than by prose, and why `pin.py` warns
when the checkout has drifted from that gitlink or from the commit the
fixtures were built against. Blobless and sparse because only the `autoeq/`
package is ever read; `measurements/` and `results/` dominate that repo and
nothing here touches them.

## Generating fixtures

```sh
python tools/parity/dump_fixtures.py
python tools/parity/dump_fixtures.py --only real_deep_dip     # one case, the rest left alone
python tools/parity/dump_fixtures.py --fs 44100 --out fixtures-44k1
```

Writes `fixtures/`, roughly 3.4 MB across eight cases plus `shared.json`.
Commit them. They are the contract, and they must not drift silently.

Regenerate **only** when the upstream pin in `CLAUDE.md` moves, and bump the
pin in the same commit. A fixture diff with no pin change means something is
wrong with the environment, not with the port.

### How reproducible they actually are

Not uniformly, and the difference matters when you regenerate.

**The pipeline stages reproduce anywhere**, to the 9-decimal rounding floor.
Regenerating the five synthetic cases on a different machine moved four
values by exactly 1e-9 — one sample sitting on a rounding tie — and one input
value per case by 2e-16, which is the curve generator's last ULP differing
between platform libms.

**Upstream's optimizer output does not.** The same regeneration moved fitted
centre frequencies by up to 584 Hz and achieved losses by up to 0.31%.
`fmin_slsqp` lands in a different local minimum depending on the BLAS
underneath it. That is not drift to be fixed — it is exactly why parity is
measured on achieved loss and never on filter parameters, per `CLAUDE.md`
invariant 4.

The practical consequence: **when adding a case, pass `--only` and generate
just that one.** A blanket regeneration would rewrite every committed fixture
with cosmetically different filter parameters, burying the one real change in
noise. `--only` leaves the other cases, `shared.json` and their manifest
entries exactly as they are.

### The cases

Five synthetic, from `curves.py`: smooth and bumpy sources on a 1/48-octave
grid, one against a Harman-ish target, one with a deliberate 11.9 dB narrow
dip, one on a coarse 1/12-octave grid.

Three real, from `real/`: the roughest treble, the deepest narrow null and
the largest bass tilt in a production measurement set, two of them against a
real target on its own axis. See `real/README.md` for why those three. They
exist because synthetic curves are smooth in ways real ones are not, and the
branchy parts of the pipeline — peak and dip detection, the protection mask,
the slope limiter — decide on structure a generated curve lacks.

## Checking a candidate

```sh
python tools/parity/compare.py candidate.json
python tools/parity/compare.py candidate.json --stage equalize --case bumpy_vs_flat -v
python tools/parity/compare.py --self-test
```

Exit code is 0 when nothing failed. `--strict` also fails on `SKIP`, which is
what CI uses.

`--self-test` diffs the fixtures against themselves. It must always pass, and
it is how you check the comparator after editing it.

## Timing against upstream

```sh
zig build bench-fit -Doptimize=ReleaseFast -- --csv 2> turboeq_fit.csv
python tools/parity/time_upstream.py --turboeq turboeq_fit.csv
```

The fixtures double as a benchmark: each records the optimizer's grid and
target at full precision, so both sides can time the fit alone on identical
inputs. `time_upstream.py` times `PEQ.from_dict` plus `PEQ.optimize`;
`tools/bench/fit.zig` times the same span in turboEQ, stopping at the loss the
fixture recorded. Needs the AutoEq checkout, like regeneration.
BENCHMARKS.md has the result.

## Candidate JSON schema

Emit this from the Zig side. Every key is optional; omitting one yields
`SKIP`.

```jsonc
{
  "meta": { "autoeq_commit": "7ae0f56...", "fs": 44100 },

  "shared": {
    // Same order as BIQUAD_PROBES in dump_fixtures.py.
    "biquad": [
      { "coefficients": { "a0": 1.0, "a1": 0.0, "a2": 0.0,
                          "b0": 0.0, "b1": 0.0, "b2": 0.0 },
        "fr": [0.0],                  // dB, one per shared.frequency entry
        "sharpness_penalty": 0.0,     // optional
        "band_penalty": 0.0 }         // optional
    ],
    "helpers": {
      "smoothing_window_size": { "0.08333333333333333": 9 },
      "log_f_sigmoid_6k_8k": [0.0],
      "log_f_sigmoid_treble_gain_k_0p5": [1.0],
      "generate_frequencies_1p01": [20.0]
    }
  },

  "cases": {
    "bumpy_vs_flat": {
      "stages": {
        "interpolate": { "frequency": [20.0], "raw": [0.0] },
        "center":      { "shift_db": 0.0, "raw": [0.0] },
        "compensate":  { "target": [0.0], "error": [0.0] },
        "smoothen":    { "smoothed": [0.0], "error_smoothed": [0.0] },
        "equalize": {
          "peak_inds": [0], "dip_inds": [0], "rtl_start": 0,
          "limit_free_mask": [false],
          "clipped_ltr": [false], "clipped_rtl": [false],
          "limited_ltr": [0.0], "limited_rtl": [0.0],
          "equalization": [0.0]
        }
      },
      "peq": {
        "8_PEAKING_WITH_SHELVES": {
          "init": { "params": [0.0] },   // optional
          "optimized": {
            "loss": 0.0,                 // required for the loss check
            "filters": [ { "type": "Peaking", "fc": 1000.0,
                           "q": 1.0, "gain": 0.0 } ]
          }
        }
      }
    }
  }
}
```

## How each stage is judged

| Stage                                    | Tolerance     | Why                                                                                                     |
| ---------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------- |
| biquad coefficients and response         | 1e-9 dB       | Deterministic arithmetic. No excuse for drift.                                                          |
| helpers, interpolate, center, compensate | 1e-9 to 1e-12 | Same.                                                                                                   |
| smoothen                                 | 1e-7 dB       | Savitzky-Golay coefficients come from a least squares solve whose last bits depend on the LAPACK build. |
| equalize arrays                          | 1e-6 dB       | Smoothing stacked on peak detection. One index landing differently shifts a whole region.               |
| equalize indices and masks               | exact         | Discrete. Off by one here means the algorithm is wrong, not imprecise.                                  |
| optimizer                                | see below     | Not comparable elementwise.                                                                             |

### Why the optimizer is judged on loss

Filter parameters are **not** compared. Different solvers land in different
local minima of near-identical quality, so a parameter diff fails for reasons
that mean nothing. The harness compares achieved loss instead:

- within 2% of upstream: `PASS`
- more than 2% better: `BETTER`, which is a pass
- more than 2% worse: `FAIL`

Band count _is_ checked exactly. Returning fewer bands than requested fails
silently — the result is still a plausible EQ — so it is asserted, not assumed.

The gain cap is also asserted directly against the `max_gain` parameter,
because "never boost more than 6 dB" is a promise the pipeline makes to the
user, not an incidental property of some array.

## Cases

| Case                | What it is for                                                                                              |
| ------------------- | ----------------------------------------------------------------------------------------------------------- |
| `gentle_vs_flat`    | A well-behaved headphone. The easy path.                                                                    |
| `bumpy_vs_flat`     | Ten alternating features. Exercises band allocation.                                                        |
| `bumpy_vs_harman`   | Non-flat target, so `compensate` does real work.                                                            |
| `noisy_dip_vs_flat` | Noise plus a deep narrow 8.8 kHz dip. **The case that matters.** The pipeline must refuse to fill that dip. |
| `bumpy_coarse_grid` | 1/12-octave input. Exercises the interpolator, since upstream resamples onto its own 1.01 grid.             |

Add cases in `curves.py`. Keep the set small. Every case multiplies fixture
size and review effort, and five already cover the distinct failure modes.

## Suggested porting order

1. `biquad` and `helpers` from `shared.json`. No case data needed.
2. `interpolate`, `center`, `compensate`.
3. `smoothen`.
4. `equalize`, and inside it do peak detection before the slope limiter. The
   limiter consumes those indices, and debugging both at once is miserable.
5. `peq`, init heuristics first, then the solver.
