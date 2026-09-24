# Custom filters

By default `run` fits AutoEq's own bank: eight free peaking bands between two pinned
shelves. This page covers fitting something else: a device's limits, a graphic EQ, or
exactly the filters you describe. It also covers EqualizerAPO export and serving the wasm
yourself.

## Fitting to a device

A hardware or software EQ usually has its own band count and ranges. `peakingBank` builds a
bank that fits inside them:

```js
// A device that allows 10 bands, Q 0.1 to 10, ±12 dB.
const bank = eq.peakingBank({
	peaking: 8,
	shelves: true,
	limits: { minQ: 0.1, maxQ: 10, minGain: -12, maxGain: 12 }
});

eq.run(source, target, { banks: [bank] });
```

The limits become the bounds the optimizer searches within. This is better than fitting
freely and clamping the answer afterwards, because a clamped filter is no longer the one
the optimizer chose.

`shelfLimits` sets the shelves' gain window separately. Without it, the shelves take the
gain window from `limits`.

## Graphic EQ

`graphicBank` pins `fc` and Q to the sliders and fits only the gains:

```js
const bank = eq.graphicBank([31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]);

eq.run(source, target, { banks: [bank] });
```

Q defaults to `Math.SQRT2`, which suits octave bands. AutoEq's third-octave grids use
4.318473; pass it as `{ q }`.

Fitting on the grid beats fitting freely and snapping each band to the nearest slider
afterwards, which moves every filter off the frequency it was optimized at.

`gainRange` is AutoEq's `optimize_fixed_band_eq(gain_range=...)`. It replaces each band's
gain bounds with a window of that half-width, centred on the correction the curve needs at
that band. It needs every `fc` pinned, so it goes with `graphicBank` or a `banks` descriptor
that sets `fc` on every filter.

## Helper bounds intersect by default

A device usually allows more than AutoEq would use: Q 0.1 to 10, say, against AutoEq's
0.18248 to 6. Widening AutoEq's window changes what the fit is aiming for, so both helpers
**intersect** your ranges with AutoEq's defaults. You get whichever range is narrower, per
parameter.

Pass `bounds: 'as-given'` to use your ranges verbatim. `eq.defaultLimits(type)` returns
AutoEq's defaults for a filter type, if you want to see what you are intersecting with.

Both helpers refuse more than `MAX_FILTERS` (32) bands.

## Describing the filters yourself

`banks` fits exactly the filters you list. It is AutoEq's `PEQ.from_dict`. For each
parameter:

- give `fc`, `q` or `gain` to pin it,
- give `min*`/`max*` to bound it,
- leave it out and the optimizer chooses it within AutoEq's default bounds for that filter
  type.

```js
eq.run(source, target, {
	banks: [
		{
			filters: [
				{ type: 'low_shelf', fc: 105, q: 0.7 }, // only gain is fitted
				{ type: 'peaking', minFc: 40, maxFc: 10000, maxGain: 6 },
				{ type: 'peaking', minFc: 40, maxFc: 10000, maxGain: 6 }
			],
			maxF: 10000 // score this bank's error up to 10 kHz only
		}
	]
});
```

Bounds written into `banks` directly are always taken as given, with no intersection. That
matches `from_dict`, and upstream's own device presets rely on it.

`banks` says everything `peaking`, `shelves` and the peaking and shelf bound options would,
so passing both is an error rather than a guess.

### Free shelves

Every shipped AutoEq preset pins the shelves. To let the optimizer move them, leave out
`fc` and `q`, as in `{ type: 'low_shelf' }`. They then range over AutoEq's default shelf
bounds (Q 0.4 to 0.7).

Unpinned shelves place themselves with AutoEq's own `init()` heuristics. This lowers the
loss on most real curves, at about 1.5x the fit time.

### Cascades

With several banks, they are fitted in order, each against what the one before it left.
Each bank's `minF` and `maxF` set the band its error is scored over. AutoEq's CLI works
this way: four peaking bands and a low shelf scored to 10 kHz, then four more and a high
shelf on the residual. One joint fit of all ten usually reaches a lower RMSE, which is why
it is turboEQ's default.

## EqualizerAPO text

A separate, optional module:

```js
import { eqapoParametric } from '@potatosalad775/turboeq/eqapo';

const text = eqapoParametric(result);
```

Numbers round half to even, as AutoEq's Python output does, so a gain of exactly -1.25
prints `-1.2` in both.

## Serving the wasm yourself

`TurboEQ.load()` covers bundlers and Node. From a CDN, or without a bundler, use
`TurboEQ.instantiate`. It takes a `fetch` response, the bytes, or a compiled
`WebAssembly.Module`.

The package ships two builds. `turboeq-simd.wasm` uses WebAssembly SIMD and is faster;
`turboeq.wasm` runs on engines without it. Serve both and pick the same way `load()` does:

```js
import simdUrl from '@potatosalad775/turboeq/turboeq-simd.wasm?url'; // Vite; or any URL you serve them at
import plainUrl from '@potatosalad775/turboeq/turboeq.wasm?url';

const eq = await TurboEQ.instantiate(fetch(TurboEQ.supportsSimd() ? simdUrl : plainUrl));
```

Both builds return bit-identical fits, so users on different browsers get the same EQ.
