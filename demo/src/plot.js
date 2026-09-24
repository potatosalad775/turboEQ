/**
 * A log-frequency line plot as an SVG string. Sized to its container in
 * pixels rather than scaled through a viewBox, so labels stay legible on a
 * phone. Colours come from CSS classes on each series.
 */

const F_MIN = 20;
const F_MAX = 20000;
const X_TICKS = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];
const Y_STEPS = [1, 2, 5, 10, 20, 50];

/**
 * @typedef {{ values: Float64Array, className: string }} Series
 *
 * @param {HTMLElement} el
 * @param {Float64Array} grid
 * @param {Series[]} series
 * @param {{ minSpan?: number, includeZero?: boolean, range?: [number, number] }} [options]
 *   `range` fixes the y axis, dB, so it holds still from one fit to the next;
 *   without it the axis fits the data.
 */
export function renderPlot(el, grid, series, options = {}) {
	const { minSpan = 10, includeZero = false, range = null } = options;
	const width = Math.max(el.clientWidth, 240);
	const height = el.clientHeight || 260;
	const m = { left: 40, right: 12, top: 10, bottom: 24 };
	const plotW = width - m.left - m.right;
	const plotH = height - m.top - m.bottom;

	let lo = range ? range[0] : includeZero ? 0 : Infinity;
	let hi = range ? range[1] : includeZero ? 0 : -Infinity;
	for (const { values } of range ? [] : series) {
		for (const v of values) {
			if (v < lo) lo = v;
			if (v > hi) hi = v;
		}
	}
	if (hi - lo < minSpan) {
		const mid = (hi + lo) / 2;
		lo = mid - minSpan / 2;
		hi = mid + minSpan / 2;
	}
	const step = Y_STEPS.find((s) => (hi - lo) / s <= 7) ?? 100;
	lo = Math.floor(lo / step) * step;
	hi = Math.ceil(hi / step) * step;

	const x = (f) => m.left + (Math.log(f / F_MIN) / Math.log(F_MAX / F_MIN)) * plotW;
	const y = (v) => m.top + ((hi - v) / (hi - lo)) * plotH;

	// A fixed axis can be narrower than the data; lines stop at its edge.
	const clip = `clip-${el.id}`;
	const parts = [
		`<clipPath id="${clip}"><rect x="${m.left}" y="${m.top}" width="${plotW}" height="${plotH}"/></clipPath>`
	];
	for (const f of X_TICKS) {
		const px = x(f).toFixed(1);
		const label = f >= 1000 ? `${f / 1000}k` : String(f);
		parts.push(
			`<line class="grid" x1="${px}" x2="${px}" y1="${m.top}" y2="${m.top + plotH}"/>`,
			`<text class="tick" x="${px}" y="${height - 6}" text-anchor="middle">${label}</text>`
		);
	}
	for (let v = lo; v <= hi + 1e-9; v += step) {
		const py = y(v).toFixed(1);
		parts.push(
			`<line class="grid${v === 0 ? ' zero' : ''}" x1="${m.left}" x2="${m.left + plotW}" y1="${py}" y2="${py}"/>`,
			`<text class="tick" x="${m.left - 6}" y="${py}" text-anchor="end" dominant-baseline="middle">${v}</text>`
		);
	}
	for (const { values, className } of series) {
		let d = '';
		for (let i = 0; i < grid.length; i++) {
			d += `${i ? 'L' : 'M'}${x(grid[i]).toFixed(1)},${y(values[i]).toFixed(1)}`;
		}
		parts.push(`<path class="series ${className}" clip-path="url(#${clip})" d="${d}"/>`);
	}

	el.innerHTML = `<svg width="${width}" height="${height}" role="img">${parts.join('')}</svg>`;
}
