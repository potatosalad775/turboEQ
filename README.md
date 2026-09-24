# turboEQ

[AutoEq](https://github.com/jaakkopasanen/AutoEq)'s parametric EQ optimizer, ported to Zig
and compiled to WebAssembly.

Hand it a measured frequency response and a target curve, get back a parametric EQ — in
milliseconds, in the browser. [Try the demo](https://potatosalad775.github.io/turboEQ/).

## Why

AutoEq is the reference for automatic headphone EQ, but it is a Python program: it runs on a
server or a desktop, not in a web page. turboEQ runs the same optimizer client-side, fast
enough to re-fit on every slider move rather than behind a spinner.

- **An 80 KB wasm module with no imports.** No Python, no scipy, no server round trip. It
  runs in a page, a worker, or anywhere else with a `WebAssembly` global.
- **Analytic gradients.** Upstream estimates them by finite differences, roughly `3N+1`
  loss evaluations per iteration; turboEQ computes them exactly. That, more than Zig
  against Python, makes the fit **23x to 190x faster** than upstream at equal quality, 92x
  at the median.
- **AutoEq's answer, not an approximation.** Every stage that decides what a good fit means
  is ported and checked against recorded upstream output. See
  [how faithful, and where it differs](docs/fidelity.md).

On 1,310 real headphone and IEM measurements, a ten-filter fit through the wasm takes 12 ms
at the median and 103 ms at worst, or 15 ms and 133 ms on an engine without WebAssembly
SIMD. [BENCHMARKS.md](BENCHMARKS.md) has every number and the command behind it.

## Quick start

```sh
npm install @potatosalad775/turboeq
```

```js
import { TurboEQ } from '@potatosalad775/turboeq';

const eq = await TurboEQ.load();

const result = eq.run(source, target, { peaking: 8, shelves: true });
// result.filters: [{ type: 'peaking' | 'low_shelf' | 'high_shelf', fc, q, gain }, ...]
// result.preamp:  what the player's preamp should be set to, dB (never positive)
// result.rmse:    fit error, dB
```

`source` and `target` are arrays of `[frequency, dB]` pairs, or a flat `Float64Array` of
the same pairs. They need not share an axis, sit on AutoEq's grid, or be sorted. Instantiate
once and call `run` as often as you like; the module keeps no state between runs.

The package is a dependency-free ES module with its own types. `TurboEQ.load()` finds the
wasm beside it: Vite and webpack emit it as an asset, and Node reads it from disk. It picks
the SIMD build where the engine supports it; both builds return bit-identical fits.

## Options

Every option defaults to AutoEq's default; [`turboeq.d.ts`](js/turboeq.d.ts) lists them all.
The common ones:

| Option                            | Default   |                                                                 |
| --------------------------------- | --------- | --------------------------------------------------------------- |
| `sampleRate`                      | 44100     | Pass your own if your chain runs at 48 kHz                      |
| `peaking`                         | 8         | Peaking bands                                                   |
| `shelves`                         | `true`    | Add a low shelf at 105 Hz and a high shelf at 10 kHz, gain free |
| `maxGain`                         | 6         | Largest boost the perceptual stage allows, dB                   |
| `maxSlope`                        | 18        | dB per octave                                                   |
| `peakingMinFc` … `peakingMaxGain` | AutoEq's  | Bounds on every peaking band                                    |
| `lossMinF`, `lossMaxF`            | 20, 20000 | The band the error is scored over                               |
| `lossFlattenF`                    | 10000     | Above this only mean level is scored; `Infinity` scores shape   |

**`peaking` counts peaking bands only.** `shelves: true` adds two more filters on top, so
the default returns ten. That is how AutoEq names `N_PEAKING_WITH_SHELVES`.

## Going further

- **[Custom filters](docs/custom-filters.md)**: fit to a device's band count and ranges,
  a graphic EQ, or exactly the filters you list; export EqualizerAPO text; serve the wasm
  yourself.
- **[Exact match](docs/exact-match.md)**: turn off AutoEq's treble caution and fit the
  curve's shape to 20 kHz, CrinGraph-style.
- **[Fidelity](docs/fidelity.md)**: what is ported from AutoEq, which upstream quirks come
  along, how parity is checked, and the few places turboEQ departs on purpose.
- **[Contributing](CONTRIBUTING.md)**: building, tests, the parity harness and benchmarks.

## Using it from Zig

```zig
const turboeq = @import("turboeq");

var result = try turboeq.pipeline.run(allocator, src_f, src_db, tgt_f, tgt_db, .{
    .peaking = 8,
    .shelves = true,
});
defer result.deinit();

// AutoEq's CLI default, the two-stage cascade:
var cli = try turboeq.pipeline.run(allocator, src_f, src_db, tgt_f, tgt_db, .{
    .banks = &turboeq.configs.autoeq_cli_default,
});
defer cli.deinit();
```

`configs.byName` reaches the rest of `PEQ_CONFIGS`, including upstream's device presets.
Every stage underneath `pipeline.run` — `curve`, `equalize`, `peq`, `lbfgs`, `biquad` — is
public, takes an explicit allocator and holds no global state. `format` writes EqualizerAPO
text.

## Licence

MPL-2.0. Derived from [AutoEq](https://github.com/jaakkopasanen/AutoEq) by Jaakko Pasanen
(MIT) and, for peak detection, from [SciPy](https://github.com/scipy/scipy) (BSD-3-Clause).
[NOTICE](NOTICE) carries both licences and ships with every copy, the wasm module included.
