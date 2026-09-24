# turboEQ

A Zig port of [AutoEq](https://github.com/jaakkopasanen/AutoEq)'s parametric EQ
optimizer, compiled to WebAssembly so it runs client-side in a browser.
`README.md` is the user-facing description, with depth in `docs/` (fidelity,
custom filters, exact match) and the human contributor guide in
`CONTRIBUTING.md`; this file is for working on it. When a fact here changes
and a user-facing doc states it too, update both.

**Status.** The port is complete and green against the parity harness, and CI
(`.github/workflows/ci.yml`) holds it there. It is packaged for npm as
`turboeq` (npm refuses capitals in new names): the binding, both `.d.ts` files,
both wasm builds and `NOTICE`. `prepack` builds the wasm and copies
`turboeq.wasm` and `turboeq-simd.wasm` into `js/`, where they are gitignored,
so `TurboEQ.load()` finds them beside the binding. CI installs the packed tarball and runs a fit through it.

## Repo layout

| Path                               | What it is                                                                                                                                                    |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AutoEq/`                          | Upstream, as a pinned submodule. **Read-only.** Never edit.                                                                                                   |
| `src/`                             | The Zig implementation. `pipeline.zig` is the entry point, `wasm.zig` the ABI.                                                                                |
| `js/`                              | The JavaScript binding over the wasm ABI, its `.d.ts`, and `eqapo.js`.                                                                                        |
| `tools/parity/`                    | Fixture generator + comparator. The port's ground truth.                                                                                                      |
| `tools/dump_candidate/`            | Zig side of the parity harness. Emits `candidate.json`.                                                                                                       |
| `tools/bench/`                     | `bench` times the whole pipeline, `bench-fit` the fit alone on the fixtures.                                                                                  |
| `tools/wasm_smoke/`, `tools/soak/` | The only checks of the wasm artifact itself: a smoke test, and a soak over real measurements. `soak/compare.mjs` sets two soak runs side by side, fit by fit. |
| `BENCHMARKS.md`                    | Every measured number, with the command that produced it.                                                                                                     |
| `demo/`                            | The GitHub Pages site. Vite, links the root package, fits in a worker.                                                                                        |
| `docs/`                            | User-facing guides the README links to: `fidelity.md`, `custom-filters.md`, `exact-match.md`.                                                                 |

Upstream pin: AutoEq `v4.1.2`, commit `7ae0f56d53074872b028649617a22bbb4232feb7`.
Bump that pin in this file and regenerate fixtures together, never separately.

The pin is recorded three times and the three have to agree: the `AutoEq`
gitlink in this repo's index, `meta.autoeq_commit` in
`tools/parity/fixtures/manifest.json`, and the line above. `tools/parity/pin.py`
checks the first two against a checkout, and both harness scripts warn when
they have drifted. It stays silent when `AutoEq/` is not checked out, which is
the usual case — only regeneration needs upstream.

## The line: faithful to the objective, free above and below it

Everything that decides what a _good fit_ means — the perceptual stage, the
loss, the penalties, the two grids, the `init()` heuristics — is AutoEq's and
stays pinned to recorded upstream output. Everything about _how a caller asks
for a fit_ and _what they do with the answer_ is turboEQ's own: the JavaScript
binding, the wasm ABI, the EqualizerAPO formatters.

That line sorts the work. Per-filter configuration looks like a turboEQ
extension and is actually `PEQ.from_dict`, so it is ported rather than
invented. EqAPO export has no upstream objective behind it, so it lives
outside the core.

**turboEQ owns the whole pipeline** and works as a drop-in replacement for
AutoEq, so it never _requires_ a caller to do work upstream of it. Anything
that departs from upstream — skipping preparation a caller has already done,
a constraint upstream has no equivalent for — goes behind an explicit opt-in,
with the faithful path as the default and the default path fixture-covered.

## Invariants to preserve

1. **One biquad kernel.** Peaking, low shelf and high shelf coefficients
   match upstream, and so does the magnitude response evaluated via the
   `phi = 4*sin(w/2)^2` form. Verified, not assumed. The optimizer's
   `Kernel` in `peq.zig` evaluates the same magnitude as one logarithm of
   the ratio, over `@Vector` lanes, so its last bits differ from
   `biquad.magnitude`. Everything the fixtures check, and `rmse` and
   `maxGain`, go through the latter; only the loss the solver reports and
   steers by comes from the former.
2. **The optimizer is box-constrained only.** Upstream calls `fmin_slsqp`
   with `bounds=` and no constraint functions. `src/lbfgs.zig`, a projected
   L-BFGS, is sufficient. You do not need SLSQP.
3. **The gradients are analytic**, in `peq.zig`. scipy supplies none, so
   upstream spends roughly `3N+1` loss evaluations per iteration
   finite-differencing them. That is most of the 23x to 190x.
4. **Optimizer parity is measured on achieved loss, never on filter
   parameters.** Different solvers land in different local minima of
   near-identical quality. This applies one level up too: in a cascade, each
   bank is scored on the loss _it_ minimized, because a bank scored only to
   10 kHz that fits its window better can hand the next bank a worse residual.
   `compare.py` does it that way.
5. **The solver's bound-width metric is load-bearing, not a tuning knob.**
   `lbfgs.zig` builds its initial Hessian as `gamma * diag(w^2)`, `w` being
   each variable's box width. Without it a decade of centre frequency and a
   decibel of gain look like the same size of step, and the fit lands 60%
   above upstream's loss on one fixture after twenty times the work. The same
   goes for restricting the two-loop recursion to the free set rather than
   masking the direction afterwards. Removing either still passes every check
   upstream of the optimizer. So does shrinking the memory: the solver keeps
   `2n` curvature pairs, and capping that at 64, as it once was, costs
   half again as many evaluations at 20 bands.
6. **The wasm ABI is positional and append-only.** `Opt` in `src/wasm.zig`
   and `OPTION_SLOTS` in `js/turboeq.js` are one list written twice, and so
   are `OutIx`, `lbfgs.Status` and `biquad.Kind` against their arrays in the
   binding. Appending a slot or an export is safe: a slot past the end of what
   the host sent takes the default, and an export an old host never calls
   costs it nothing. Renumbering or repurposing is not, and `teq_abi_version`
   exists to be bumped when that happens. It is still 1.
7. **JavaScript and Markdown are formatted by `.prettierrc`** — tabs, single
   quotes, no trailing commas, 100 columns; code blocks inside Markdown are
   left alone. Keep `prettier --check .` passing, and `zig fmt --check` for Zig.
8. **Python rounds half to even; Zig and JavaScript do not.** A gain of
   exactly -1.25 prints `-1.2` upstream, `-1.3` from `{d:.1}` or `toFixed`.
   `format.zig` and `js/eqapo.js` each carry a `roundHalfEven` that agrees
   with Python on exact binary ties. A value merely _near_ a tie, like 0.35,
   can still differ in the last digit.

## The caller-facing API

One entry point: `eq.run(source, target, options)` in JavaScript,
`pipeline.run` in Zig. `options.banks` replaces the built-in bank with the
filters it names — `PEQ.from_dict` over a list of configs — and says
everything `peaking`, `shelves` and the limit options would, so passing both
is refused rather than resolved by precedence.

**`peaking` counts peaking bands only**, shelves outside the count, as
`N_PEAKING_WITH_SHELVES` has it. Stated in `js/turboeq.js`'s header and in
`README.md`, nowhere else.

**The helpers intersect, the descriptor does not.** `peakingBank` and
`graphicBank` narrow a caller's ranges to AutoEq's defaults unless given
`bounds: 'as-given'`, because a device profile is usually wider — `q 0.1 to 10`
against `0.18248 to 6` — and loosening upstream's window silently changes the
objective. Bounds written into `banks` by hand are taken verbatim, because
that is `from_dict`'s semantics and upstream's own `QUDELIX_5K` sets `min_q`
0.1. `defaultLimits(type)` is `global_filter_defaults`, read out of the module
rather than copied.

`MAX_FILTERS` is 32. It binds in the bank builders, where "as many bands as
you like" arrives, not in `run`, where a caller who spelled out 40 filters has
said what it wants.

**`PEQ_CONFIGS` does not cross the wasm boundary.** `configs.named` is ported,
fixture-checked (`compare.py`'s `peq config <name>`) and reachable from Zig as
`configs.byName`, but nothing in `wasm.zig` references it, so the linker drops
it. Exporting it was tried and reverted, for **staleness, not size** (1.3 KB
gzipped). A device's band count and gain range belong to the
hardware in front of the user, not to a table pinned to v4.1.2. If a caller
ever wants upstream's _names_, generate a JavaScript table from
`configs.named` beside `js/eqapo.js` — the bank descriptor round-trips in
full — rather than exporting it or writing a copy by hand.

## Gotchas, all verified against upstream

- **Sample rate defaults to 44100**, upstream's `DEFAULT_FS`. A caller on a
  48 kHz chain passes its own.
- **Target alignment is `min_mean_error`**: shift to minimize mean error
  across 100 Hz to 10 kHz, not pin at a single frequency.
- **Shelves are supported upstream** with full `init()` heuristics, but every
  _shipped_ preset pins them at 105 Hz / Q 0.7 and 10 kHz / Q 0.7, gain only.
  The heuristics are ported anyway.
- **`gain_range` reads the curve before the preamp.**
  `optimize_fixed_band_eq` derives each fixed band's gain window from
  `self.equalization` on the 1.01 grid; `_optimize_peq_filters` adds the
  preamp afterwards. Its `argmin` lookup is a no-op, so it reduces to reading
  the curve at each band's centre. It needs every `fc` pinned, because
  upstream indexes `filt['fc']` straight out of the config dict.
- **`ix10k` is not the index of 10 kHz.** `PEQFilter.ix10k` computes
  `argmin(abs(f - fs))`, against the _sample rate_, so on a 20 Hz to 20 kHz
  axis it is the last index. Reproduced in `bandPenalty`; do not "fix" it.
- **`limited_rtl_slope` does not flip the frequency axis.** It reverses the
  data, peak indices, mask and start index, then passes the still-ascending
  `x` to the left-to-right limiter. On the log-uniform grid every step and
  distance the walk measures comes out the same, so that is reproduced. The
  exception is `concha_interference`'s quarter slope allowance, the one
  place the walk reads a frequency outright: upstream's right-to-left pass
  applies it at the mirrored 35 to 50 Hz. turboEQ applies it at 8 to
  11.5 kHz. The flag is off by default and no fixture sets it, so the
  faithful path is untouched; 19 of 212 oratory1990 in-ear EQs change with
  it on.
- **An unsorted curve is sorted, not refused**, as `_init_data` does.
  `pipeline.prepareCurve` allocates nothing when the axis is already
  ascending. Duplicate frequencies still fail, as upstream.
- **`AutoEq/peq.yaml` has a config bug.** Its high shelf sets `fc: 10000`
  beside `min_fc`/`max_fc` and a comment saying the optimizer may move it.
  Supplying `fc` sets `optimize_fc=False`, so the bounds are dead. Do not
  reproduce this.
- **Savitzky-Golay is one operation, not two.** scipy's interior convolution
  and edge polyfit both evaluate a degree-2 least squares fit at one index;
  `savgol.quadFitWeights` does both. It solves in a centred, scaled variable
  because raw powers of the index are badly conditioned at the treble
  window's 139 samples.
- **Smoothing window size uses the _average_ frequency step** across the
  whole array. See `AutoEq/autoeq/utils.py`.
- **Interpolation is linear in log10(f)** — `InterpolatedUnivariateSpline`
  with `k=1`, not cubic.
- **Above 10 kHz the loss flattens target and response to their mean.**
- **`band_penalty` is never called.** `_optimizer_loss` sums only
  `sharpness_penalty`. `bandPenalty` is ported because the fixtures record it;
  adding it to the loss would change upstream, not fix it.
- **`HighShelf.init` uses its argmax as an index into `f` directly**, where
  `LowShelf.init` adds `min_ix` back, so it lands `min_ix` samples low.
  Reproduced in `initShelf`.
- **The optimizer runs on a different grid.** `process` leaves the
  equalization on the 1.01 grid; `_optimize_peq_filters` interpolates onto the
  1.02 grid, adds the preamp and fits there.
- **The loss slice is `[min_f_ix:max_f_ix]`, upper end exclusive**, so the
  topmost sample of the 1.02 grid is outside the MSE. The mean above 10 kHz
  still includes it.
- **`teq_run` rewinds the arena, it does not reset it.** Buffers from
  `teq_alloc` survive the call. Only `teq_reset` frees them, and after it
  every pointer the host holds is dangling.
- **The wasm build is stripped and ships ReleaseSmall**, independent of
  `-Doptimize` (`-Dwasm-optimize` overrides). Both wasm modes give
  bit-identical fits; ReleaseSmall is a third smaller for 2% to 3% of run
  time. Unit tests and the parity harness run on the **host** target, so
  `smoke.mjs` and `soak.mjs` are the only checks of the artifact a browser
  gets.
- **There are two wasm builds and they must agree to the bit.**
  `turboeq-simd.wasm` adds simd128; `turboeq.wasm` is the same source for
  engines without it, LLVM splitting each `@Vector` back into scalars.
  `TurboEQ.load()` picks one by validating a one-instruction SIMD module.
  Same operations in the same order give the same fits, and `smoke.mjs`
  fails if they do not: two browsers must never get two EQs. So no
  lane-dependent algorithm, and no vector reduction the scalar build would
  order differently.

## Defaults that differ from upstream

Each is a _stopping rule or a starting layout_, never a change to the
objective, which is what makes them allowed. BENCHMARKS.md has the evidence.

- **Early stopping is off.** Upstream's `min_std` stops on a plateau, within
  a few percent of the work, and costs quality on every real fit measured;
  twenty bands stopped early fit worse than eight run to convergence.
  `stop.min_std`, `target_loss` and `upstream_stop_rules` remain.
- **One bank, not a cascade.** `8_PEAKING_WITH_SHELVES` rather than the CLI's
  `4_PEAKING_WITH_LOW_SHELF,4_PEAKING_WITH_HIGH_SHELF`; one joint fit reaches a
  lower RMSE. The cascade is `configs.autoeq_cli_default`.
- **Shelves stay pinned**, as every shipped preset has them. This one is
  fidelity to upstream's layout, not quality: freeing them, within the
  `DEFAULT_SHELF_FILTER_*` bounds (Q 0.4 to 0.7), lowers the loss on most real
  curves for 1.5x the time. No fixture reaches the free-shelf `init()` path, so
  `peq.zig`'s "free shelves place themselves" test is its only cover.

**`lossFlattenF` is an opt-in departure from the objective.** Upstream's
`_optimizer_loss` flattens both curves to their mean above 10 kHz, which
suits rigs that are not trusted up there. `peq.Options.flatten_f` keeps
10 kHz by default; `Infinity` scores the shape to the top of the grid, for
rigs like the B&K 5128 that are. It applies to every bank of a run. The
free-shelf `init()` still caps its search at 10 kHz, since that is upstream's
heuristic and only sets where the fit starts. Raising `peakingMaxFc` past
10 kHz _without_ it lets bands up there cancel each other in the mean, and
the fit lands far worse.

**There is no `max_time`.** The freestanding build has no clock, and an
evaluation cap is reproducible where a wall-clock budget is not.

**Out of scope:** impulse responses, CSV I/O, the README writer, batch
processing and the Harman preference scores — AutoEq the CLI, not AutoEq the
optimizer. The first would need an FFT costing more wasm than the whole port.

## Working with the parity harness

```sh
zig build test
zig build dump                                 # writes candidate.json
python tools/parity/compare.py candidate.json
```

Green over eight cases, five synthetic and three real measurements from
`tools/parity/real/`. The counts are in BENCHMARKS.md and printed by the
commands above; do not copy them into comments. `BETTER` is a lower loss than
upstream reached, which invariant 4 expects. Unimplemented stages report
`SKIP`; `--strict` fails on them.

Only regeneration needs upstream. Clone blobless and sparse _before_ the
submodule checkout, or `submodule update --init` checks out all 75,797 files
the pin carries:

```sh
git clone --filter=blob:none --sparse https://github.com/jaakkopasanen/AutoEq.git AutoEq
git -C AutoEq sparse-checkout set autoeq
git submodule update --init AutoEq
python -m pip install -r tools/parity/requirements.txt
```

**Adding a case means `dump_fixtures.py --only <id>`, never a blanket
regeneration.** The pipeline stages reproduce anywhere to the rounding floor,
but upstream's optimizer lands in a different local minimum depending on the
BLAS underneath it. That is invariant 4, not drift, but it would bury a real
change in noise across every committed fixture.

**The fixtures cannot judge a change to the solver or its kernel.** They
cover eight cases, and the fit is chaotic: moving the last bit of one
logarithm sends a third of 12-band fits and two thirds of 20-band fits more
than 1% up or down in loss. Run `tools/soak/soak.mjs --tsv` before and after
over a few hundred real measurements, and `tools/soak/compare.mjs` the two.
A change that costs nothing shows a median loss ratio of 1.0000 and a p10 to
p90 spread no wider than a last-bit change alone; BENCHMARKS.md has that
spread.

**Fixture inputs are recorded at full precision; outputs are rounded to 9
decimals.** Rounding an input feeds the candidate different numbers than
upstream saw, and the difference compounds. The output rounding puts a 5e-10
floor under every comparison, so no tolerance in `compare.py` may go below
it. `--self-test` cannot catch either problem.

## Conventions

- **Zig 0.16.0**, pinned in `build.zig.zon`. 0.16 reworked `std.Io`: file
  access goes through `std.Io.Dir` with an explicit `Io`, `main` takes a
  `std.process.Init`, and `GeneralPurposeAllocator` is now `DebugAllocator`.
  Most Zig examples online predate this.
- Every function takes an explicit `std.mem.Allocator` and no module holds
  global state, so the wasm build needs only a `FixedBufferAllocator` over an
  8 MiB static array. Keep it that way.
- **Upstream timings are fit only and run on the fixtures.** `bench-fit` and
  `tools/parity/time_upstream.py` time the same span on the same inputs; keep
  their config lists in step. Re-run both before quoting a ratio.
- **Commit messages stay short**: a subject line, then one or two short
  paragraphs on why. Measurements belong in BENCHMARKS.md, decisions in this
  file or a doc comment, where they can be corrected later.
- turboEQ is MPL-2.0; AutoEq is MIT and SciPy BSD-3-Clause. Keep the
  attribution line in every file derived from either, and keep `NOTICE` in
  anything distributed — both licences require it for binaries too.
