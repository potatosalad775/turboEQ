import { eqapoParametric } from '@potatosalad775/turboeq/eqapo';
import { filterResponse } from './biquad.js';
import { alignment, interpolate, logGrid, parseCurve } from './curve.js';
import { renderPlot } from './plot.js';

import roughTreble from '../../tools/parity/real/rough_treble_iem.txt?raw';
import deepDip from '../../tools/parity/real/deep_dip_overear.txt?raw';
import bassHeavy from '../../tools/parity/real/bass_heavy_iem.txt?raw';
import harmanIE from '../../tools/parity/real/target_harman_ie_2019v2.txt?raw';

const SOURCES = [
	{ label: 'bass-heavy earphone', curve: parseCurve(bassHeavy) },
	{ label: 'rough-treble earphone', curve: parseCurve(roughTreble) },
	{ label: 'over-ear headphone with deep dip', curve: parseCurve(deepDip) }
];
const TARGETS = [
	{ label: 'Harman IE 2019v2', curve: parseCurve(harmanIE) },
	{
		label: 'Flat',
		curve: [
			[20, 0],
			[20000, 0]
		]
	}
];
const TYPE_LABELS = { peaking: 'Peak', low_shelf: 'Low shelf', high_shelf: 'High shelf' };
const BENCH_RUNS = 50;
const BENCH_BUDGET_MS = 5000;
const GRID = logGrid(480);

const $ = (/** @type {string} */ id) => /** @type {any} */ (document.getElementById(id));

/** The last fit shown, with the inputs it was fitted from. */
let last = null;

/**
 * A preset list plus whatever the user has uploaded, behind one `<select>`.
 * Files arrive through the input or by dropping them on the card.
 */
function picker(name, presets) {
	const entries = [...presets];
	const select = $(`${name}-select`);
	const input = $(`${name}-file`);
	const card = $(`${name}-card`);
	const error = $(`${name}-error`);

	const fill = () => select.replaceChildren(...entries.map((e, i) => new Option(e.label, i)));
	fill();

	/** @param {File} file */
	async function add(file) {
		try {
			entries.push({ label: file.name, curve: parseCurve(await file.text()) });
			fill();
			select.value = String(entries.length - 1);
			error.textContent = '';
			request('fit');
		} catch (e) {
			error.textContent = `${file.name}: ${e.message}`;
		}
	}

	select.addEventListener('change', () => request('fit'));
	input.addEventListener('change', () => {
		if (input.files[0]) add(input.files[0]);
		input.value = '';
	});
	card.addEventListener('dragover', (e) => {
		e.preventDefault();
		card.classList.add('dragging');
	});
	card.addEventListener('dragleave', () => card.classList.remove('dragging'));
	card.addEventListener('drop', (e) => {
		e.preventDefault();
		card.classList.remove('dragging');
		const file = e.dataTransfer.files[0];
		if (file) add(file);
	});

	return () => entries[Number(select.value)].curve;
}

const source = picker('source', SOURCES);
const target = picker('target', TARGETS);

/**
 * Where a band may sit, or null with the reason shown when the two boxes do
 * not make a range. 20 Hz to 20 kHz is the grid the fit runs on.
 *
 * AutoEq mode stops bands at 10 kHz whatever the box says. Its loss sees only
 * the mean level above that, and bands let loose there cancel each other in
 * the mean: +43 dB on one sample measurement, straight into the export.
 */
function frequencyRange() {
	const minFc = Number($('min-fc').value);
	const exact = $('fit-mode').value === 'exact';
	const asked = Number($('max-fc').value);
	const maxFc = exact ? asked : Math.min(asked, 10000);
	let problem = '';
	if (!$('min-fc').value || !$('max-fc').value) problem = 'Enter both ends of the range.';
	else if (!(minFc >= 20 && asked <= 20000)) problem = 'Keep the range within 20 Hz to 20 kHz.';
	else if (!(minFc < asked)) problem = 'The lowest frequency must be below the highest.';
	else if (!(minFc < maxFc))
		problem = 'AutoEq mode stops at 10 kHz. Choose Exact match to go higher.';
	$('range-error').textContent = problem;
	$('range-hint').textContent = problem
		? ''
		: asked > maxFc
			? 'AutoEq mode stops bands at 10 kHz, where its fit stops seeing the shape. ' +
				'Choose Exact match to go higher.'
			: exact && maxFc <= 10000
				? 'Raise the highest filter frequency to correct above 10 kHz.'
				: '';
	return problem ? null : { minFc, maxFc };
}

function options() {
	const range = frequencyRange();
	if (!range) return null;
	const { minFc, maxFc } = range;
	const peaking = Number($('peaking').value);
	const shelves = $('shelves').value;
	const common = {
		maxGain: Number($('max-gain').value),
		sampleRate: Number($('sample-rate').value),
		// AutoEq's treble handling off: no mean-only loss above 10 kHz, the
		// main smoothing window all the way up, no slope limit. The boost cap
		// stays, and is what keeps a dip from being filled with +20 dB.
		...($('fit-mode').value === 'exact'
			? { lossFlattenF: Infinity, trebleWindowSize: 1 / 12, maxSlope: Infinity }
			: {})
	};
	// Pinned shelves ignore the range; every free fc takes it.
	if (shelves !== 'free') {
		return {
			peaking,
			shelves: shelves === 'fixed',
			peakingMinFc: minFc,
			peakingMaxFc: maxFc,
			...common
		};
	}
	// Free shelves are not a built-in layout, so the bank is written out. A
	// filter with no fc or q gets both optimized, fc inside the range above
	// and Q inside AutoEq's own bounds (0.4 to 0.7 for a shelf).
	const filters = [
		{ type: 'low_shelf', minFc, maxFc },
		{ type: 'high_shelf', minFc, maxFc },
		...Array.from({ length: peaking }, () => ({ type: 'peaking', minFc, maxFc }))
	];
	return { banks: [{ filters }], ...common };
}

function syncControls() {
	$('peaking-value').textContent = $('peaking').value;
	$('max-gain-value').textContent = `${$('max-gain').value} dB`;
}

// One request in the worker at a time, and only the newest one waiting behind
// it: a slider dragged across a slow fit skips the positions it passed.
const worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });
let ready = false;
let inFlight = null;
let waiting = null;

function send(message) {
	if (!ready) return;
	if (inFlight) {
		if (waiting?.kind === 'bench') {
			$('bench').disabled = false;
			$('bench-result').textContent = '';
		}
		waiting = message;
		return;
	}
	inFlight = message;
	worker.postMessage(message);
	// Only say so when it is slow enough to notice.
	setTimeout(() => {
		if (inFlight === message && message.kind === 'fit') $('status').textContent = 'Fitting…';
	}, 150);
}

function request(kind) {
	syncControls();
	const opts = options();
	if (opts) send({ kind, source: source(), target: target(), options: opts });
}

worker.onmessage = ({ data }) => {
	if (data.kind === 'ready') {
		ready = true;
		$('load-ms').textContent = `${data.ms.toFixed(0)} ms`;
		const kb = data.bytes ? `${(data.bytes / 1024).toFixed(0)} KB ` : '';
		$('load-detail').textContent = `${kb}wasm, fetched and compiled`;
		$('bench').disabled = false;
		request('fit');
		return;
	}
	if (data.kind === 'failed') {
		$('load-detail').textContent = `failed: ${data.message}`;
		return;
	}

	const sent = inFlight;
	inFlight = null;
	$('status').textContent = '';
	if (data.error) {
		$('fit-error').textContent = data.error;
	} else if (data.kind === 'fit') {
		$('fit-error').textContent = '';
		showFit(sent, data.result, data.ms);
	} else {
		showBench(data.times);
	}
	if (data.kind === 'bench') $('bench').disabled = false;
	if (waiting) {
		const next = waiting;
		waiting = null;
		send(next);
	}
};

function showFit(sent, fit, ms) {
	// Low to high, for the table and the export alike. The filters sum, so
	// their order changes nothing about the response.
	const result = { ...fit, filters: [...fit.filters].sort((a, b) => a.fc - b.fc) };
	last = { result, sampleRate: sent.options.sampleRate, source: sent.source, target: sent.target };

	$('fit-ms').textContent = `${ms.toFixed(1)} ms`;
	$('fit-detail').textContent =
		`${result.iterations} iterations · ${result.evaluations} evaluations`;
	$('rmse').textContent = `${result.rmse.toFixed(2)} dB`;
	$('preamp').textContent = `${result.preamp.toFixed(1)} dB`;
	$('filter-count').textContent = `${result.filters.length} filters`;
	$('bench-result').textContent = '';

	$('filters').replaceChildren(
		...result.filters.map((f, i) => {
			const row = document.createElement('tr');
			for (const text of [
				i + 1,
				TYPE_LABELS[f.type],
				f.fc.toFixed(0),
				f.q.toFixed(2),
				f.gain.toFixed(1)
			]) {
				row.insertCell().textContent = String(text);
			}
			return row;
		})
	);
	$('apo').textContent = eqapoParametric(result);
	draw();
}

function showBench(times) {
	times.sort((a, b) => a - b);
	const median = times[times.length >> 1];
	$('bench-result').textContent =
		`median ${median.toFixed(1)} ms · min ${times[0].toFixed(1)} · ` +
		`max ${times[times.length - 1].toFixed(1)} over ${times.length} runs`;
}

function draw() {
	if (!last) return;
	const { result, sampleRate } = last;
	const tgt = interpolate(last.target, GRID);
	const raw = interpolate(last.source, GRID);
	const shift = alignment(raw, tgt, GRID);
	const measured = raw.map((v) => v + shift);

	const total = new Float64Array(GRID.length);
	const parts = result.filters.map((f) => {
		const r = filterResponse(f, GRID, sampleRate);
		for (let i = 0; i < r.length; i++) total[i] += r[i];
		return { values: r, className: 'part' };
	});
	const equalized = measured.map((v, i) => v + total[i]);

	// What a CrinGraph-style graph shows: the equalized measurement against
	// the target itself, not against AutoEq's smoothed equalization curve.
	let sq = 0;
	for (let i = 0; i < GRID.length; i++) sq += (equalized[i] - tgt[i]) ** 2;
	$('rmse-detail').textContent =
		`against the equalization curve · ${Math.sqrt(sq / GRID.length).toFixed(2)} dB against the target`;

	renderPlot(
		$('fr-plot'),
		GRID,
		[
			{ values: tgt, className: 'target' },
			{ values: measured, className: 'measured' },
			{ values: equalized, className: 'equalized' }
		],
		{ range: [-30, 30] }
	);
	renderPlot($('eq-plot'), GRID, [...parts, { values: total, className: 'eq' }], {
		minSpan: 12,
		includeZero: true
	});
}

syncControls();
for (const id of ['peaking', 'shelves', 'fit-mode', 'max-gain', 'sample-rate']) {
	$(id).addEventListener('input', () => request('fit'));
}
// Typing 16000 passes through 1, 16 and 160 on the way; fit on the whole number.
for (const id of ['min-fc', 'max-fc']) {
	$(id).addEventListener('change', () => request('fit'));
}
$('bench').addEventListener('click', () => {
	const opts = options();
	if (!opts) return;
	$('bench').disabled = true;
	$('bench-result').textContent = 'timing…';
	send({
		kind: 'bench',
		runs: BENCH_RUNS,
		budgetMs: BENCH_BUDGET_MS,
		source: source(),
		target: target(),
		options: opts
	});
});
$('copy').addEventListener('click', async () => {
	await navigator.clipboard.writeText($('apo').textContent);
	$('copy').textContent = 'Copied';
	setTimeout(() => ($('copy').textContent = 'Copy'), 1200);
});
$('download').addEventListener('click', () => {
	const url = URL.createObjectURL(new Blob([$('apo').textContent], { type: 'text/plain' }));
	const a = Object.assign(document.createElement('a'), { href: url, download: 'turboeq.txt' });
	a.click();
	URL.revokeObjectURL(url);
});
new ResizeObserver(draw).observe($('fr-plot'));
