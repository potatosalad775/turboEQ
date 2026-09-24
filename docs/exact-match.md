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

## Turning it off

If you trust your measurement to 20 kHz, for example from a B&K 5128, or you want a fit
that matches the graph you are looking at, turn all three off and let bands reach the top
of the range:

```js
eq.run(source, target, {
	lossFlattenF: Infinity, // score the treble's shape, not only its mean
	trebleWindowSize: 1 / 12, // the same smoothing as the rest of the curve
	maxSlope: Infinity, // no slope limit
	peakingMaxFc: 20000
});
```

Of these, only `lossFlattenF` changes AutoEq's objective. The other three are parameters
AutoEq itself exposes. [Fidelity](fidelity.md) has more on that distinction.

## The boost cap still applies

`maxGain` still caps every boost, at 6 dB by default, and it matters more once the rest is
off. A notch in the measurement gets filled only as far as the cap allows. Raising the cap
fills deeper notches, but it also asks the headphone for more output than you might expect,
and it gives up preamp headroom. Raise it with care.

## Limits on the smoothing window

A window narrower than 1/12 octave buys nothing, since no band is sharper than Q 6. A window
narrower than about 1/46 octave, or wider than the whole curve, is refused.

## Do not raise `peakingMaxFc` on its own

Raising `peakingMaxFc` past 10 kHz **without** `lossFlattenF` is a trap. Above 10 kHz the
loss sees only the mean, so bands up there can cancel each other out at extreme gains and
still score well. On one of the parity measurements, the fit pairs a +20 dB band at 16 kHz
with cuts below it.

Move `lossFlattenF` whenever you move `peakingMaxFc` above it.
