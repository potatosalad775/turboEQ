// Drives the freestanding module through `js/turboeq.js`, the same binding a
// browser uses, without a browser.
//
//     zig build wasm && node tools/wasm_smoke/smoke.mjs
//
// It checks the four things the unit tests cannot: that the module imports
// nothing, that the binding and the ABI agree on the version, that a real fit
// comes back through the boundary intact, and that turboeq-simd.wasm returns
// the very same fits as turboeq.wasm.

import { readFile } from 'node:fs/promises';
import { EXACT_MATCH_OPTIONS, TurboEQ } from '../../js/turboeq.js';

const bytes = await readFile(new URL('../../zig-out/bin/turboeq.wasm', import.meta.url));
const module = await WebAssembly.compile(bytes);

const imports = WebAssembly.Module.imports(module);
console.log('imports:', imports.length === 0 ? 'none' : imports);
if (imports.length !== 0) {
	console.error('the module must be a pure function of its own memory');
	process.exitCode = 1;
}

const eq = await TurboEQ.instantiate(module);
console.log('heap:', (eq.heapSize / 1024 / 1024).toFixed(0), 'MiB');

// `curves.bumpy` from tools/parity, on a 1/48-octave grid.
const source = [];
for (let f = 20; f <= 20000; f *= 2 ** (1 / 48)) {
	const l = Math.log10(f);
	const g = (fc, gain, width) => gain * Math.exp(-(((l - Math.log10(fc)) / width) ** 2));
	source.push([
		f,
		g(60, -6, 0.12) +
			g(150, 4, 0.1) +
			g(400, -3, 0.09) +
			g(900, 3, 0.08) +
			g(1800, -4, 0.07) +
			g(3200, 6, 0.06) +
			g(5000, -5, 0.06) +
			g(7000, 4, 0.05) +
			g(9500, -6, 0.05) +
			g(13000, 3, 0.07)
	]);
}
const target = [
	[20, 0],
	[20000, 0]
];

for (const bands of [3, 5, 8, 10]) {
	const t0 = performance.now();
	const r = eq.run(source, target, { peaking: bands - 2, shelves: true });
	const ms = performance.now() - t0;

	if (r.filters.length !== bands) {
		console.error(`asked for ${bands} bands, got ${r.filters.length}`);
		process.exitCode = 1;
	}
	console.log(
		`${String(bands).padStart(2)} bands  ${ms.toFixed(1).padStart(6)} ms  ` +
			`RMSE ${r.rmse.toFixed(4)}  preamp ${r.preamp.toFixed(1)} dB  ` +
			`${r.evaluations} evals  (${r.status})`
	);
	for (const f of r.filters) {
		console.log(
			`        ${f.type.padEnd(10)} ${f.fc.toFixed(0).padStart(6)} Hz  ` +
				`Q ${f.q.toFixed(2)}  ${f.gain >= 0 ? '+' : ''}${f.gain.toFixed(2)} dB`
		);
	}
}

// The filter-descriptor export. Same curve, but AutoEq's own CLI default:
// a low shelf and four peaking bands scored to 10 kHz, then a high shelf and
// four more fitted to whatever the first bank left behind.
const peaking = () => ({ type: 'peaking' });
const cliDefault = [
	{
		filters: [{ type: 'low_shelf', fc: 105, q: 0.7 }, ...Array.from({ length: 4 }, peaking)],
		maxF: 10000
	},
	{ filters: [{ type: 'high_shelf', fc: 10000, q: 0.7 }, ...Array.from({ length: 4 }, peaking)] }
];

const t0 = performance.now();
const cascaded = eq.run(source, target, { banks: cliDefault });
const cascadeMs = performance.now() - t0;
if (cascaded.filters.length !== 10) {
	console.error(`cascade returned ${cascaded.filters.length} filters, expected 10`);
	process.exitCode = 1;
}
console.log(
	`
cascade   ${cascadeMs.toFixed(1).padStart(6)} ms  RMSE ${cascaded.rmse.toFixed(4)}  ` +
		`preamp ${cascaded.preamp.toFixed(1)} dB  (AutoEq's CLI default, 4+1 then 4+1)`
);
for (const f of cascaded.filters) {
	console.log(
		`        ${f.type.padEnd(10)} ${f.fc.toFixed(0).padStart(6)} Hz  ` +
			`Q ${f.q.toFixed(2)}  ${f.gain >= 0 ? '+' : ''}${f.gain.toFixed(2)} dB`
	);
}

// A device preset: pinned shelves, peaking bands held to the hardware's own
// Q and gain range. Nothing may come back outside those bounds.
const qudelix = [
	{
		filters: [
			{ type: 'low_shelf', fc: 105, q: 0.7, minGain: -12, maxGain: 12 },
			{ type: 'high_shelf', fc: 10000, q: 0.7, minGain: -12, maxGain: 12 },
			...Array.from({ length: 8 }, () => ({
				type: 'peaking',
				minQ: 0.1,
				maxQ: 7,
				minFc: 20,
				maxFc: 10000,
				minGain: -12,
				maxGain: 12
			}))
		]
	}
];
const device = eq.run(source, target, { banks: qudelix });
const withinBounds = device.filters.every(
	(f, i) =>
		f.gain >= -12 - 1e-9 &&
		f.gain <= 12 + 1e-9 &&
		(i < 2 || (f.q >= 0.1 - 1e-9 && f.q <= 7 + 1e-9 && f.fc >= 20 && f.fc <= 10000))
);
const shelvesPinned =
	device.filters[0].fc === 105 && device.filters[0].q === 0.7 && device.filters[1].fc === 10000;
if (!withinBounds || !shelvesPinned) {
	console.error('a device preset came back outside its own constraints');
	process.exitCode = 1;
}
console.log(
	`preset    ${'—'.padStart(6)}     RMSE ${device.rmse.toFixed(4)}  ` +
		`bounds held: ${withinBounds && shelvesPinned}  (QUDELIX_5K)`
);

// A sound signature: a colouration the fit aims at rather than corrects.
const signature = [
	[20, 0],
	[5000, 0],
	[20000, 4]
];
const coloured = eq.run(source, target, { banks: qudelix, soundSignature: signature });
if (coloured.rmse === device.rmse) {
	console.error('the sound signature did not reach the target curve');
	process.exitCode = 1;
}
console.log(
	`signature ${'—'.padStart(6)}     RMSE ${coloured.rmse.toFixed(4)}  ` +
		`(+4 dB above 5 kHz, vs ${device.rmse.toFixed(4)} without)`
);

console.log('heap used:', (eq.heapUsed / 1024).toFixed(0), 'KiB');

// A malformed descriptor has to come back as an error, not a trap.
let rejected = false;
try {
	eq.run(source, target, { banks: [{ filters: [{ type: 'not_a_filter' }] }] });
} catch {
	rejected = true;
}
if (!rejected) {
	console.error('an unknown filter type was accepted');
	process.exitCode = 1;
}

// The bank builders a host maps its own constraint model through. A device
// profile is wider than AutoEq's defaults on both Q and fc, and intersecting
// is what keeps upstream's window authoritative.
const profile = { minFc: 20, maxFc: 20000, minQ: 0.1, maxQ: 10, minGain: -12, maxGain: 12 };
const intersected = eq.peakingBank({ peaking: 8, shelves: true, limits: profile });
const peakOne = intersected.filters[2];
const defaults = eq.defaultLimits('peaking');
if (
	intersected.filters.length !== 10 ||
	peakOne.maxQ !== defaults.maxQ ||
	peakOne.maxFc !== defaults.maxFc ||
	peakOne.minGain !== -12
) {
	console.error('peakingBank did not intersect the device profile with the defaults');
	process.exitCode = 1;
}
const asGiven = eq.peakingBank({ peaking: 8, limits: profile, bounds: 'as-given' });
if (asGiven.filters[2].maxQ !== 10) {
	console.error("bounds: 'as-given' did not keep the device's own window");
	process.exitCode = 1;
}
const constrained = eq.run(source, target, { banks: [intersected] });
const heldIn = constrained.filters
	.slice(2)
	.every((f) => f.q <= defaults.maxQ + 1e-9 && f.gain >= -12 - 1e-9 && f.gain <= 12 + 1e-9);
console.log(
	`profile   ${'—'.padStart(6)}     RMSE ${constrained.rmse.toFixed(4)}  ` +
		`bounds held: ${heldIn}  (q 0.1-10 intersected to ${defaults.minQ}-${defaults.maxQ})`
);
if (!heldIn) process.exitCode = 1;

// `fit: 'exact'` is shorthand and nothing more: the same run as its options
// spelled out. The sharpness penalty is the one of them the smoke otherwise
// never reaches, so dropping it has to change the fit.
const spelled = eq.run(source, target, {
	...EXACT_MATCH_OPTIONS,
	peakingMaxFc: 20000,
	sampleRate: 48000
});
const preset = eq.run(source, target, { fit: 'exact', sampleRate: 48000 });
const penalized = eq.run(source, target, {
	...EXACT_MATCH_OPTIONS,
	sharpnessPenalty: true,
	peakingMaxFc: 20000,
	sampleRate: 48000
});
const presetSame = JSON.stringify(spelled.filters) === JSON.stringify(preset.filters);
const penaltyMatters = JSON.stringify(spelled.filters) !== JSON.stringify(penalized.filters);
console.log(
	`exact     ${'—'.padStart(6)}     RMSE ${preset.rmse.toFixed(4)}  ` +
		`preset = spelled out: ${presetSame}  penalty changes the fit: ${penaltyMatters}`
);
if (!presetSame || !penaltyMatters) process.exitCode = 1;

// Free shelves fit fc and Q as well as gain, inside their own window.
const shelfWindow = { minFc: 20, maxFc: 20000, minQ: 0.4, maxQ: 0.7, minGain: -12, maxGain: 12 };
const freeBank = eq.peakingBank({
	peaking: 3,
	shelfPlacement: 'free',
	limits: profile,
	shelfLimits: shelfWindow,
	bounds: 'as-given'
});
const free = eq.run(source, target, { banks: [freeBank], fit: 'exact', sampleRate: 48000 });
const shelvesFree = free.filters.slice(0, 2);
const shelvesHeld = shelvesFree.every(
	(f) =>
		f.fc >= shelfWindow.minFc - 1e-9 &&
		f.fc <= shelfWindow.maxFc + 1e-9 &&
		f.q >= shelfWindow.minQ - 1e-9 &&
		f.q <= shelfWindow.maxQ + 1e-9
);
const shelvesMoved = shelvesFree[0].fc !== 105 || shelvesFree[1].fc !== 10000;
console.log(
	`free      ${'—'.padStart(6)}     RMSE ${free.rmse.toFixed(4)}  ` +
		`shelves inside their window: ${shelvesHeld}  moved off 105 Hz / 10 kHz: ${shelvesMoved}`
);
if (!shelvesHeld || !shelvesMoved || free.filters.length !== 5) process.exitCode = 1;

// A graphic EQ fits on its own grid rather than being snapped onto it, so
// every band comes back on the frequency the slider actually has.
const sliders = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
const graphic = eq.run(source, target, {
	banks: [eq.graphicBank(sliders, { minGain: -12, maxGain: 12 })]
});
const onGrid = graphic.filters.every((f, i) => f.fc === sliders[i] && Math.abs(f.q - Math.SQRT2) < 1e-12); // prettier-ignore
if (!onGrid || graphic.filters.length !== sliders.length) {
	console.error('a graphic bank moved off its own grid');
	process.exitCode = 1;
}
console.log(
	`graphic   ${'—'.padStart(6)}     RMSE ${graphic.rmse.toFixed(4)}  ` +
		`on grid: ${onGrid}  (10 sliders, fc and Q pinned)`
);

// An unsorted curve is sorted rather than refused, which is what upstream
// does and what a host falling back on any failure needs.
const reversed = [...source].reverse();
const sorted = eq.run(reversed, target, { peaking: 8, shelves: true });
if (Math.abs(sorted.rmse - 0.3306) > 1e-3) {
	console.error(`a reversed curve fitted differently: RMSE ${sorted.rmse}`);
	process.exitCode = 1;
}
console.log(
	`sorted    ${'—'.padStart(6)}     RMSE ${sorted.rmse.toFixed(4)}  (same curve, reversed)`
);

// Saying the same thing twice is a contradiction, not a precedence question.
let refused = false;
try {
	eq.run(source, target, { banks: [intersected], peaking: 4 });
} catch {
	refused = true;
}
if (!refused) {
	console.error('banks and peaking were accepted together');
	process.exitCode = 1;
}

// The SIMD build does the same arithmetic in the same order, so its fits are
// bit-identical, not merely close. Anything less means the two builds would
// hand users on different browsers different EQs.
if (TurboEQ.supportsSimd()) {
	const simdModule = await WebAssembly.compile(
		await readFile(new URL('../../zig-out/bin/turboeq-simd.wasm', import.meta.url))
	);
	if (WebAssembly.Module.imports(simdModule).length !== 0) {
		console.error('turboeq-simd.wasm imports something');
		process.exitCode = 1;
	}
	const simd = await TurboEQ.instantiate(simdModule);
	const cases = [
		...[1, 3, 6, 8, 12, 20].map((peaking) => ({ peaking, shelves: true })),
		{ banks: qudelix },
		{ banks: cliDefault }
	];
	const differ = cases.filter((options) => {
		const a = eq.run(source, target, options);
		const b = simd.run(source, target, options);
		return JSON.stringify(a) !== JSON.stringify(b);
	});
	console.log(
		`simd      ${'—'.padStart(6)}     ${cases.length - differ.length}/${cases.length} fits identical`
	);
	if (differ.length) {
		console.error('turboeq-simd.wasm fitted differently:', differ);
		process.exitCode = 1;
	}
} else {
	console.log('simd      skipped: this engine has no WebAssembly SIMD');
}

console.log('checks:', process.exitCode ? 'FAILED' : 'all passed');
