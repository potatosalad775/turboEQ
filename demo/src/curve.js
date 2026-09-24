/**
 * Curve files in, display arrays out. Nothing here reaches the fit: turboEQ
 * takes the parsed pairs as they are and does its own resampling.
 */

/**
 * Any text file of frequency and dB columns: AutoEq's `frequency,raw` CSV, a
 * tab-separated REW or squiglink export, with or without a header. Rows whose
 * first two fields are not numbers are skipped, and further columns ignored.
 *
 * @param {string} text
 * @returns {[number, number][]}
 */
export function parseCurve(text) {
	const points = [];
	for (const line of text.split(/\r?\n/)) {
		const cols = line.trim().split(/[\s,;]+/);
		if (cols.length < 2) continue;
		const f = Number(cols[0]);
		const db = Number(cols[1]);
		if (cols[0] === '' || !Number.isFinite(f) || !Number.isFinite(db) || f <= 0) continue;
		points.push([f, db]);
	}
	if (points.length < 2) throw new Error('no frequency and dB columns found');
	return points.sort((a, b) => a[0] - b[0]);
}

/** `n` frequencies spaced evenly in log from 20 Hz to 20 kHz. */
export function logGrid(n) {
	const out = new Float64Array(n);
	for (let i = 0; i < n; i++) out[i] = 20 * 1000 ** (i / (n - 1));
	return out;
}

/**
 * `curve` read at each frequency of `grid`, linear in log frequency and held
 * flat past either end, the same rule turboEQ resamples by.
 *
 * @param {[number, number][]} curve sorted by frequency
 * @param {Float64Array} grid ascending
 */
export function interpolate(curve, grid) {
	const out = new Float64Array(grid.length);
	let j = 0;
	for (let i = 0; i < grid.length; i++) {
		const f = grid[i];
		while (j < curve.length - 2 && curve[j + 1][0] < f) j++;
		const [f0, y0] = curve[j];
		const [f1, y1] = curve[j + 1];
		if (f <= f0) out[i] = y0;
		else if (f >= f1) out[i] = y1;
		else out[i] = y0 + ((y1 - y0) * Math.log(f / f0)) / Math.log(f1 / f0);
	}
	return out;
}

/**
 * The shift that puts `from` on top of `onto` across 100 Hz to 10 kHz, as
 * AutoEq aligns a target before fitting. For drawing only.
 */
export function alignment(from, onto, grid) {
	let sum = 0;
	let n = 0;
	for (let i = 0; i < grid.length; i++) {
		if (grid[i] < 100 || grid[i] > 10000) continue;
		sum += onto[i] - from[i];
		n++;
	}
	return n ? sum / n : 0;
}
