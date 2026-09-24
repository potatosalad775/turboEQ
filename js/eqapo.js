/**
 * EqualizerAPO text, from a `TurboEQ` result.
 *
 * A deliberate sibling of `turboeq.js` rather than part of it, because it is
 * optional. Import it only if you want the text.
 *
 * Nothing here talks to the wasm module. These are formatters over a filter
 * list and a curve, which is work a JavaScript runtime does better than a
 * shipped binary — so the wasm module does not carry them at all.
 * `src/format.zig` is the same two functions for a Zig caller.
 *
 * Derived from AutoEq (MIT, Jaakko Pasanen), autoeq/frequency_response.py.
 */

/** `PREAMP_HEADROOM`. Room left below the loudest sample when normalizing. */
export const PREAMP_HEADROOM = 0.2;

/** `DEFAULT_GRAPHIC_EQ_STEP`: 127 samples topping out at 19871 Hz. */
export const GRAPHIC_EQ_STEP = 1.0563;

const APO_TYPES = { peaking: 'PK', low_shelf: 'LSC', high_shelf: 'HSC' };

/**
 * JavaScript's `toFixed` rounds half away from zero; Python's `format` rounds
 * half to even, and upstream is Python. A gain of exactly -1.25 is `-1.2`
 * there and would be `-1.3` here.
 *
 * The tie is detected after scaling, so this matches wherever the value is an
 * exact binary tie — every tie a pinned or bounded parameter produces. A value
 * merely near one, such as 0.35 (really 0.34999...), can still differ in the
 * last digit.
 *
 * @param {number} value
 * @param {number} decimals
 */
function toFixedHalfEven(value, decimals) {
	if (!Number.isFinite(value)) return String(value);
	const scale = 10 ** decimals;
	const scaled = value * scale;
	const floored = Math.floor(scaled);
	const frac = scaled - floored;
	let rounded;
	if (frac > 0.5) rounded = floored + 1;
	else if (frac < 0.5) rounded = floored;
	else rounded = floored % 2 === 0 ? floored : floored + 1;
	return (rounded / scale).toFixed(decimals);
}

/**
 * `write_eqapo_parametric_eq`. The preamp line is `-maxGain`, the largest
 * boost the whole cascade applies rather than the largest single filter gain.
 *
 * Upstream applies no headroom and no clamp here, so a cascade that only cuts
 * yields a positive preamp. Reproduced rather than second-guessed.
 *
 * @param {{ filters: { type: string, fc: number, q: number, gain: number }[], maxGain: number }} result
 * @returns {string}
 */
export function eqapoParametric(result) {
	const lines = [`Preamp: ${toFixedHalfEven(-result.maxGain, 1)} dB`];
	result.filters.forEach((filt, i) => {
		const kind = APO_TYPES[filt.type];
		if (!kind) throw new Error(`unknown filter type "${filt.type}"`);
		lines.push(
			`Filter ${i + 1}: ON ${kind} Fc ${toFixedHalfEven(filt.fc, 0)} Hz ` +
				`Gain ${toFixedHalfEven(filt.gain, 1)} dB Q ${toFixedHalfEven(filt.q, 2)}`
		);
	});
	return lines.join('\n') + '\n';
}

/**
 * `20 * step ** n`, truncated to integers and deduplicated — which is why the
 * axis is 127 points rather than the 137 the exponent count suggests. The
 * collisions are all at the bottom, where a step is under 1 Hz.
 *
 * @returns {number[]}
 */
export function graphicAxis() {
	const n = Math.ceil(Math.log(20000 / 20) / Math.log(GRAPHIC_EQ_STEP));
	const out = [];
	for (let i = 0; i < n; i++) {
		const value = Math.trunc(20 * GRAPHIC_EQ_STEP ** i);
		if (out.length === 0 || value !== out[out.length - 1]) out.push(value);
	}
	return out;
}

/**
 * `eqapo_graphic_eq`. `f` and `equalization` are the working grid and the
 * curve on it — `TurboEQ` does not return those, so this is for a caller that
 * has them (a Zig host, or one plotting the curve already).
 *
 * Normalizing subtracts `max + PREAMP_HEADROOM`, leaving the whole curve at or
 * below zero, and the first sample is clamped to at most 0 to stop a boost
 * below the lowest frequency EqualizerAPO interpolates from.
 *
 * @param {ArrayLike<number>} f
 * @param {ArrayLike<number>} equalization
 * @param {{ normalize?: boolean, preamp?: number }} [options]
 * @returns {string}
 */
export function eqapoGraphic(f, equalization, options = {}) {
	const { normalize = true, preamp = 0 } = options;
	if (f.length !== equalization.length) {
		throw new Error('f and equalization must be the same length');
	}
	const axis = graphicAxis();
	const y = axis.map((target) => interpolateLog(f, equalization, target));

	if (normalize) {
		const peak = Math.max(...y);
		for (let i = 0; i < y.length; i++) y[i] -= peak + PREAMP_HEADROOM;
	}
	if (preamp) {
		for (let i = 0; i < y.length; i++) y[i] += preamp;
	}
	if (y.length && y[0] > 0) y[0] = 0;

	return 'GraphicEQ: ' + axis.map((fv, i) => `${fv} ${toFixedHalfEven(y[i], 1)}`).join('; ');
}

/**
 * Linear in log10(f), matching `InterpolatedUnivariateSpline(k=1)` — the same
 * rule `curve.zig` uses, and not cubic despite that class's name. Clamped at
 * both ends, as upstream's `ext=3` is.
 *
 * @param {ArrayLike<number>} f
 * @param {ArrayLike<number>} y
 * @param {number} target
 */
function interpolateLog(f, y, target) {
	const x = Math.log10(target === 0 ? 0.001 : target);
	if (x <= Math.log10(f[0])) return y[0];
	const last = f.length - 1;
	if (x >= Math.log10(f[last])) return y[last];
	let lo = 0;
	let hi = last;
	while (hi - lo > 1) {
		const mid = (lo + hi) >> 1;
		if (Math.log10(f[mid]) <= x) lo = mid;
		else hi = mid;
	}
	const x0 = Math.log10(f[lo]);
	const x1 = Math.log10(f[hi]);
	const t = x1 === x0 ? 0 : (x - x0) / (x1 - x0);
	return y[lo] + t * (y[hi] - y[lo]);
}
