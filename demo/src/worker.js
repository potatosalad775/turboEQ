/**
 * The fit, off the main thread. A thirty-band fit runs for seconds, and a
 * slider has to keep moving while it does. Times are taken here, around
 * `run` alone, so they measure turboEQ and not the message round trip.
 */

import { TurboEQ } from '@potatosalad775/turboeq';

const t0 = performance.now();
const ready = TurboEQ.load().then(
	(eq) => {
		const entry = performance
			.getEntriesByType('resource')
			.find((r) => r.name.split('?')[0].endsWith('.wasm'));
		postMessage({
			kind: 'ready',
			ms: performance.now() - t0,
			bytes: entry ? entry.decodedBodySize : 0
		});
		return eq;
	},
	(e) => {
		postMessage({ kind: 'failed', message: e.message });
		throw e;
	}
);

onmessage = async ({ data }) => {
	const eq = await ready;
	const { id, kind, source, target, options } = data;
	try {
		if (kind === 'fit') {
			const start = performance.now();
			const result = eq.run(source, target, options);
			postMessage({ id, kind, result, ms: performance.now() - start });
		} else if (kind === 'bench') {
			// A count and a time budget, whichever runs out first: fifty
			// thirty-band fits would be minutes.
			const times = [];
			const until = performance.now() + data.budgetMs;
			while (times.length < data.runs && (times.length < 3 || performance.now() < until)) {
				const start = performance.now();
				eq.run(source, target, options);
				times.push(performance.now() - start);
			}
			postMessage({ id, kind, times });
		}
	} catch (e) {
		postMessage({ id, kind, error: e.message });
	}
};
