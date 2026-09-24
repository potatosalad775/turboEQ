// Runs the shipped wasm over a directory of real measurements and reports the
// latency distribution, plus every fit that broke a promise.
//
//     zig build wasm
//     node tools/soak/soak.mjs [--target FILE] [--peaking N[,N...]] [--no-shelves]
//                              [--banks FILE] [--options JSON]
//                              [--wasm FILE] [--tsv FILE] PATH...
//
// PATH is a measurement file or a directory searched recursively for `.txt`
// and `.csv`. Files are read the way tools/parity/curves.py reads them: one
// point per line, tab- or comma-separated, frequency then dB, with header and
// blank lines skipped and any further columns ignored. `--target` defaults to
// flat.
//
// The measurement set BENCHMARKS.md quotes is not in the repo, so this is the
// script rather than the data. `node tools/soak/soak.mjs tools/parity/real`
// runs it over the three curves that are.
//
// A fit breaks a promise when it returns a different number of filters than
// the bank has, leaves a bound, returns a non-finite number, or asks for a
// positive preamp. Any of those exits non-zero.
//
// `--banks` fits the banks in a JSON file, an array of bank descriptors as
// `options.banks` takes them, instead of `peaking` bands; bounds left out are
// checked against `defaultLimits`. `--options` is merged into every run's
// options, e.g. '{"minStd":0.008}'.
//
// `--wasm` runs another module, `zig-out/bin/turboeq.wasm` by default.
// `--tsv` writes one row per fit, which is what tools/soak/compare.mjs reads
// to set two builds side by side.

import { readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { TurboEQ } from '../../js/turboeq.js';

const args = process.argv.slice(2);
let targetPath = null;
let peakingCounts = [8];
let shelves = true;
let wasmPath = new URL('../../zig-out/bin/turboeq.wasm', import.meta.url);
let tsvPath = null;
let banksPath = null;
let extra = {};
const paths = [];
for (let i = 0; i < args.length; i++) {
	if (args[i] === '--target') targetPath = args[++i];
	else if (args[i] === '--peaking') peakingCounts = String(args[++i]).split(',').map(Number);
	else if (args[i] === '--no-shelves') shelves = false;
	else if (args[i] === '--wasm') wasmPath = args[++i];
	else if (args[i] === '--tsv') tsvPath = args[++i];
	else if (args[i] === '--banks') banksPath = args[++i];
	else if (args[i] === '--options') extra = JSON.parse(args[++i]);
	else paths.push(args[i]);
}
if (paths.length === 0 || !peakingCounts.every((n) => Number.isInteger(n) && n >= 0)) {
	console.error(
		'usage: soak.mjs [--target FILE] [--peaking N[,N...]] [--no-shelves] ' +
			'[--banks FILE] [--options JSON] [--wasm FILE] [--tsv FILE] PATH...'
	);
	process.exit(2);
}

async function collect(path, out) {
	if ((await stat(path)).isDirectory()) {
		for (const name of (await readdir(path)).sort()) await collect(join(path, name), out);
	} else if (/\.(txt|csv)$/i.test(path) && path !== targetPath) {
		out.push(path);
	}
	return out;
}

async function readCurve(path) {
	const points = [];
	for (const raw of (await readFile(path, 'utf8')).split('\n')) {
		const line = raw.trim().replace(/^﻿/, '');
		if (!line || !/^[0-9.+-]/.test(line)) continue;
		const [f, db] = line.split(/[\t,]/).map(Number);
		points.push([f, db]);
	}
	return points;
}

function percentile(sorted, p) {
	return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
}

const files = [];
for (const p of paths) await collect(p, files);
const target = targetPath
	? await readCurve(targetPath)
	: [
			[20, 0],
			[20000, 0]
		];

const eq = await TurboEQ.instantiate(await readFile(wasmPath));

const within = (v, lo, hi, pinned) =>
	pinned !== undefined ? v === pinned : v >= lo - 1e-9 && v <= hi + 1e-9;

const rows = [];
const broken = [];
let heapHigh = 0;

// Each layout to fit: a label for the report, the banks, and every filter's
// bounds in the order the result returns them.
const layouts = banksPath
	? [
			{
				label: banksPath
					.split('/')
					.pop()
					.replace(/\.json$/, ''),
				banks: JSON.parse(await readFile(banksPath, 'utf8'))
			}
		]
	: peakingCounts.map((peaking) => ({
			label: String(peaking),
			// The bank written out, so every filter's bounds are known to check against.
			banks: [eq.peakingBank({ peaking, shelves })]
		}));

console.log(
	`${files.length} curves, ` +
		(banksPath
			? `banks ${banksPath}`
			: `${peakingCounts.join(', ')} peaking${shelves ? ' + 2 shelves' : ''}`) +
		`${Object.keys(extra).length ? `, options ${JSON.stringify(extra)}` : ''}, target ${targetPath ?? 'flat'}`
);

for (const { label, banks } of layouts) {
	const specs = banks.flatMap((b) => b.filters.map((f) => ({ ...eq.defaultLimits(f.type), ...f })));
	const times = [];
	const evals = [];
	const statuses = new Map();

	for (const file of files) {
		let result;
		const curve = await readCurve(file);
		const started = performance.now();
		try {
			result = eq.run(curve, target, { ...extra, banks });
		} catch (err) {
			broken.push(`${file} (${label}): threw ${err.message}`);
			continue;
		}
		const ms = performance.now() - started;
		times.push(ms);
		evals.push(result.evaluations);
		statuses.set(result.status, (statuses.get(result.status) ?? 0) + 1);
		heapHigh = Math.max(heapHigh, eq.heapUsed);
		rows.push([file, label, result.evaluations, result.loss, result.rmse, result.status, ms]);

		const problems = [];
		if (result.filters.length !== specs.length) {
			problems.push(`${result.filters.length} filters, asked for ${specs.length}`);
		}
		result.filters.forEach((f, i) => {
			const spec = specs[i];
			if (!spec) return;
			if (![f.fc, f.q, f.gain].every(Number.isFinite)) problems.push(`filter ${i} not finite`);
			if (
				!within(f.fc, spec.minFc, spec.maxFc, spec.fc) ||
				!within(f.q, spec.minQ, spec.maxQ, spec.q) ||
				!within(f.gain, spec.minGain, spec.maxGain, spec.gain)
			) {
				problems.push(`filter ${i} out of bounds`);
			}
		});
		if (!Number.isFinite(result.rmse)) problems.push('rmse not finite');
		if (!(result.preamp <= 0)) problems.push(`preamp ${result.preamp}`);
		if (problems.length) broken.push(`${file} (${label}): ${problems.join(', ')}`);
	}

	const fmt = (xs, digits) => {
		const s = [...xs].sort((a, b) => a - b);
		return [50, 90, 99]
			.map((p) => percentile(s, p).toFixed(digits))
			.concat(s.at(-1).toFixed(digits));
	};
	if (times.length) {
		console.log(`\n${banksPath ? label : `${label} peaking`}\n`);
		console.log('|                  | p50 | p90 | p99 | max |');
		console.log('| ---------------- | --- | --- | --- | --- |');
		console.log(`| Time, ms         | ${fmt(times, 1).join(' | ')} |`);
		console.log(`| Loss evaluations | ${fmt(evals, 0).join(' | ')} |`);
		console.log(`\nstatus: ${[...statuses].map(([k, v]) => `${k} ${v}`).join(', ')}`);
	}
}

console.log(`\nheap high water: ${Math.ceil(heapHigh / 1024)} KiB`);
console.log(`broken: ${broken.length}`);
for (const line of broken) console.log(`  ${line}`);
if (broken.length) process.exitCode = 1;

if (tsvPath) {
	const header = ['file', 'layout', 'evaluations', 'loss', 'rmse', 'status', 'ms'];
	await writeFile(tsvPath, [header, ...rows].map((r) => r.join('\t')).join('\n') + '\n');
}
