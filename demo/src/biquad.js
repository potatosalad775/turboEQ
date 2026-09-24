/**
 * The response of a fitted filter, for drawing it. The wasm returns filter
 * parameters, not curves, so the page evaluates them itself — the same RBJ
 * coefficients and `phi = 4*sin(w/2)^2` magnitude form as `src/biquad.zig`.
 *
 * Derived from AutoEq (MIT, Jaakko Pasanen), autoeq/peq.py.
 */

/**
 * `[b0, b1, b2, a1, a2]` for `1 + a1 z^-1 + a2 z^-2` in the denominator.
 *
 * @param {{ type: string, fc: number, q: number, gain: number }} filter
 * @param {number} fs
 */
function coefficients({ type, fc, q, gain }, fs) {
	const a = 10 ** (gain / 40);
	const w0 = (2 * Math.PI * fc) / fs;
	const alpha = Math.sin(w0) / (2 * q);
	const cw = Math.cos(w0);
	if (type === 'peaking') {
		const a0 = 1 + alpha / a;
		return [
			(1 + alpha * a) / a0,
			(-2 * cw) / a0,
			(1 - alpha * a) / a0,
			(-2 * cw) / a0,
			(1 - alpha / a) / a0
		];
	}
	const s = 2 * Math.sqrt(a) * alpha;
	if (type === 'low_shelf') {
		const a0 = a + 1 + (a - 1) * cw + s;
		return [
			(a * (a + 1 - (a - 1) * cw + s)) / a0,
			(2 * a * (a - 1 - (a + 1) * cw)) / a0,
			(a * (a + 1 - (a - 1) * cw - s)) / a0,
			(-2 * (a - 1 + (a + 1) * cw)) / a0,
			(a + 1 + (a - 1) * cw - s) / a0
		];
	}
	if (type === 'high_shelf') {
		const a0 = a + 1 - (a - 1) * cw + s;
		return [
			(a * (a + 1 + (a - 1) * cw + s)) / a0,
			(-2 * a * (a - 1 + (a + 1) * cw)) / a0,
			(a * (a + 1 + (a - 1) * cw - s)) / a0,
			(2 * (a - 1 - (a + 1) * cw)) / a0,
			(a + 1 - (a - 1) * cw - s) / a0
		];
	}
	throw new Error(`unknown filter type "${type}"`);
}

/**
 * One filter's magnitude in dB at each frequency of `grid`.
 *
 * @param {{ type: string, fc: number, q: number, gain: number }} filter
 * @param {Float64Array} grid
 * @param {number} fs
 */
export function filterResponse(filter, grid, fs) {
	const [b0, b1, b2, a1, a2] = coefficients(filter, fs);
	const bSum = (b0 + b1 + b2) ** 2;
	const aSum = (1 + a1 + a2) ** 2;
	const bMix = b1 * (b0 + b2) + 4 * b0 * b2;
	const aMix = a1 * (1 + a2) + 4 * a2;
	const out = new Float64Array(grid.length);
	for (let i = 0; i < grid.length; i++) {
		const s = Math.sin((Math.PI * grid[i]) / fs);
		const phi = 4 * s * s;
		const num = bSum + (b0 * b2 * phi - bMix) * phi;
		const den = aSum + (a2 * phi - aMix) * phi;
		out[i] = 10 * Math.log10(num / den);
	}
	return out;
}
