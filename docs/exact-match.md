# Exact match

AutoEq is cautious in the treble by design. This page explains that caution, and how to
turn it off when you want a CrinGraph-style exact match to the target.

## What AutoEq does above 8 kHz

Three separate things keep AutoEq from chasing treble detail:

1. **Wide smoothing.** The curve AutoEq fits is smoothed over 1/12 octave in the bass and
   mids, and over two octaves in the treble. The switch happens gradually between 6 and
   8 kHz. Narrow peaks and notches up there are averaged away before the optimizer sees
   them.
2. **A slope limit.** The correction may change by at most 18 dB per octave, which stops it
   from following steep, narrow features.
3. **A mean-only loss above 10 kHz.** Above 10 kHz, the loss compares only the average level
   of the fit and the target. Filters there can set the treble's overall level, but not its
   shape.

All three are deliberate. Treble measurements vary with fit and seating on every rig, and a
narrow feature seen at 12 kHz may not be where the listener's ear puts it. AutoEq corrects
what it can trust.

## Two more things in the objective

Beyond the treble, AutoEq's objective holds a fit back from the curve in two more ways:

4. **A penalty on steep bands.** Every peaking band steeper than about 18 dB per octave adds a
   penalty to the loss, so the optimizer shies away from narrow, deep bands even where the
   curve has a narrow, deep feature.
5. **One last smoothing pass.** After the slope limit, AutoEq smooths the curve the optimizer
   fits over a fifth of an octave. That setting is hardcoded upstream. Anything narrower than
   a fifth of an octave is blurred out of the target before the fit starts.

On measurements whose treble is a row of narrow peaks and notches, these two are what keep a
fit from reaching the treble at all.

## Turning it off

If you trust your measurement to 20 kHz, for example from a B&K 5128, or you want a fit that
matches the graph you are looking at, ask for an exact match:

```js
eq.run(source, target, { fit: 'exact' });
```

That is `EXACT_MATCH_OPTIONS` underneath whatever else you pass, and, with the built-in bank,
peaking bands allowed up to 20 kHz:

```js
eq.run(source, target, {
	lossFlattenF: Infinity, // score the treble's shape, not only its mean
	trebleWindowSize: 1 / 12, // the same smoothing as the rest of the curve
	maxSlope: Infinity, // no slope limit
	sharpnessPenalty: false, // no penalty on steep bands
	equalizationWindowSize: 0, // no last smoothing pass
	peakingMaxFc: 20000
});
```

An option you pass yourself wins over the preset's. With `banks`, the bounds in your banks say
where bands may sit, so set their `maxFc` yourself; `peakingBank` needs `bounds: 'as-given'`
to go past AutoEq's 10 kHz.

`trebleWindowSize` and `maxSlope` are parameters AutoEq itself exposes. The other three change
AutoEq's objective. [Fidelity](fidelity.md) has more on that distinction.

## The boost cap still applies

`maxGain` still caps every boost, at 6 dB by default, and it matters more once the rest is
off. A notch in the measurement gets filled only as far as the cap allows. Raising the cap
fills deeper notches, but it also asks the headphone for more output than you might expect,
and it gives up preamp headroom. Raise it with care.

## Limits on the smoothing window

A `windowSize` or `trebleWindowSize` narrower than about 1/46 octave, or wider than the whole
curve, is refused. `equalizationWindowSize` takes 0 to skip its pass.

## Do not raise `peakingMaxFc` on its own

Raising `peakingMaxFc` past 10 kHz **without** `lossFlattenF` is a trap. Above 10 kHz the
loss sees only the mean, so bands up there can cancel each other out at extreme gains and
still score well. On one of the parity measurements, the fit pairs a +20 dB band at 16 kHz
with cuts below it.

Move `lossFlattenF` whenever you move `peakingMaxFc` above it.
