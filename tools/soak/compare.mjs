// Sets soak runs side by side, fit by fit, against the first one.
//
//     node tools/soak/soak.mjs --wasm before.wasm --tsv before.tsv ... DIR
//     node tools/soak/soak.mjs --wasm after.wasm  --tsv after.tsv  ... DIR
//     node tools/soak/compare.mjs before.tsv after.tsv [more.tsv ...]
//
// Why fit by fit: the solver is chaotic. Moving the last bit of one
// logarithm sends a third of twelve-band fits and two thirds of twenty-band
// fits more than 1% up or down in loss, in both directions, so three curves
// say nothing about quality. Over a few hundred, a change that costs nothing
// shows a median loss ratio of 1.000 and a p10 to p90 spread no wider than
// that noise. BENCHMARKS.md records how wide the noise is.
//
// Time is the sum over every fit the two runs share. Run the builds being
// compared at the same time, or one after another on an idle machine: a
// busy one moves the absolute numbers by 20%.

import { readFileSync } from 'node:fs';
import { basename } from 'node:path';

const paths = process.argv.slice(2);
if (paths.length < 2) {
	console.error('usage: compare.mjs BASE.tsv OTHER.tsv [MORE.tsv ...]');
	process.exit(2);
}

/** Layout, then file, to the fit. */
function load(path) {
	const layouts = new Map();
	for (const line of readFileSync(path, 'utf8').trim().split('\n').slice(1)) {
		const [file, layout, evaluations, loss, rmse, status, ms] = line.split('\t');
		if (!layouts.has(layout)) layouts.set(layout, new Map());
		layouts.get(layout).set(file, {
			evaluations: Number(evaluations),
			loss: Number(loss),
			rmse: Number(rmse),
			status,
			ms: Number(ms)
		});
	}
	return layouts;
}

const quantile = (sorted, p) => sorted[Math.round(p * (sorted.length - 1))];
const sum = (xs) => xs.reduce((a, b) => a + b, 0);
const median = (xs) =>
	quantile(
		[...xs].sort((a, b) => a - b),
		0.5
	);

const base = load(paths[0]);
const columns = [
	'run',
	'layout',
	'fits',
	'time',
	'p50 ms',
	'p99 ms',
	'evals',
	'loss median',
	'loss p10',
	'loss p90',
	'loss geomean',
	'worse >1%',
	'better >1%',
	'capped',
	'rmse median'
];
console.log(`base: ${paths[0]}; time, evals and loss are ratios to it, rmse is not\n`);
console.log(`| ${columns.join(' | ')} |`);
console.log(`| ${columns.map(() => '---').join(' | ')} |`);

for (const path of paths.slice(1)) {
	const other = load(path);
	for (const [layout, baseFits] of base) {
		// The same layout if the other run has it; if it fitted one layout
		// only, that one, which is how two different layouts are compared.
		const otherLayout = other.has(layout) ? layout : other.size === 1 ? [...other.keys()][0] : null;
		if (otherLayout === null) continue;
		const otherFits = other.get(otherLayout);
		const pairs = [...baseFits]
			.filter(([file]) => otherFits.has(file))
			.map(([file, a]) => [a, otherFits.get(file)]);
		if (!pairs.length) continue;
		// Loss is only comparable within one layout: a cascade reports the
		// last bank's. Across layouts, compare the rmse column instead.
		const ratios = pairs.map(([a, b]) => b.loss / a.loss).sort((x, y) => x - y);
		const ms = pairs.map(([, b]) => b.ms).sort((x, y) => x - y);
		const cells = [
			basename(path),
			otherLayout === layout ? layout : `${layout} → ${otherLayout}`,
			pairs.length,
			(sum(pairs.map(([, b]) => b.ms)) / sum(pairs.map(([a]) => a.ms))).toFixed(3),
			quantile(ms, 0.5).toFixed(1),
			quantile(ms, 0.99).toFixed(1),
			(sum(pairs.map(([, b]) => b.evaluations)) / sum(pairs.map(([a]) => a.evaluations))).toFixed(
				3
			),
			quantile(ratios, 0.5).toFixed(4),
			quantile(ratios, 0.1).toFixed(3),
			quantile(ratios, 0.9).toFixed(3),
			Math.exp(sum(ratios.map(Math.log)) / ratios.length).toFixed(4),
			ratios.filter((r) => r > 1.01).length,
			ratios.filter((r) => r < 0.99).length,
			pairs.filter(([, b]) => b.status === 'max_evaluations').length,
			median(pairs.map(([, b]) => b.rmse)).toFixed(4)
		];
		console.log(`| ${cells.join(' | ')} |`);
	}
}
