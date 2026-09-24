/**
 * turboEQ — the JavaScript side of the wasm boundary.
 *
 * Dependency-free ES module, no build step, no bundler assumptions. It is the
 * only place outside `src/wasm.zig` that knows the ABI, so the two files are
 * the whole contract; a host that reimplements the layout instead of using
 * this one has signed up to keep a third copy in step.
 *
 * Usage:
 *
 *     import { TurboEQ } from 'turboeq';
 *
 *     const eq = await TurboEQ.load();
 *     const { filters, rmse } = eq.run(sourcePoints, targetPoints, {
 *         sampleRate: 48000,
 *         peaking: 6,
 *         shelves: true
 *     });
 *
 * Curves are arrays of `[frequency, dB]` pairs, or a flat `Float64Array` of
 * the same pairs interleaved. They are sorted by frequency if they are not
 * already, the way AutoEq sorts its own input; two points at one frequency are
 * an error. Everything else — the target's own axis, the grid, the smoothing —
 * the module handles.
 *
 * **Band count.** Said once, here, because getting it wrong is an off-by-two
 * nobody notices: `peaking` counts peaking bands *only*. `shelves: true` adds
 * two more, so the default fit returns ten filters for `peaking: 8`. This is
 * how AutoEq writes `PEQ_CONFIGS['N_PEAKING_WITH_SHELVES']`. A host whose UI
 * counts shelves inside its own total either subtracts two at the one place it
 * builds options, or — better — describes the bank outright with `banks`, where
 * the filter list is the count and there is nothing to subtract. `result`'s
 * `filters.length` is always exactly what was asked for.
 *
 * turboEQ is MPL-2.0. Derived from AutoEq (MIT, Jaakko Pasanen).
 */

/** Bumped when the meaning of an existing slot changes. Appending does not. */
export const ABI_VERSION = 1;

/**
 * The cap a host applies when its own model says "as many bands as you like".
 * There is no unlimited fit: every filter is three more variables for the
 * solver and three more rows in whatever the result is written into. 32 is
 * past anything a listener can hear apart and still fits in a few milliseconds
 * of solver time. `peakingBank` and `graphicBank` refuse more than this.
 */
export const MAX_FILTERS = 32;

/**
 * A module holding one simd128 instruction, `i8x16.popcnt`, and nothing else.
 * An engine that validates it can run `turboeq-simd.wasm`.
 */
const SIMD_PROBE = new Uint8Array([
	0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 123, 3, 2, 1, 0, 10, 10, 1, 8, 0, 65, 0, 253, 15,
	253, 98, 11
]);

/**
 * Option name to slot. Positional and append-only; `src/wasm.zig` holds the
 * same list as an enum. An option left out takes turboEQ's default, which is
 * upstream AutoEq's default.
 */
const OPTION_SLOTS = {
	/** Hz. Upstream's 44100 unless the host's chain runs at something else. */
	sampleRate: 0,
	/** Free peaking bands. The shelves below are *not* counted here. */
	peaking: 1,
	/** Add a low shelf at 105 Hz and a high shelf at 10 kHz, gain-only. */
	shelves: 2,
	/** dB added to the equalization before the fit, so the bands absorb it. */
	preamp: 3,
	/** Align by mean error over 100 Hz to 10 kHz rather than pinning 1 kHz. */
	minMeanError: 4,

	/** Hard ceiling on positive gain in the equalization curve, dB. */
	maxGain: 5,
	/** Slope ceiling, dB per octave. */
	maxSlope: 6,
	/** Scales equalization in the treble, both directions. 1 leaves it be. */
	trebleGainK: 7,
	/** Do the measurements carry the narrow ~9 kHz concha dip? */
	conchaInterference: 8,

	bassBoostGain: 9,
	bassBoostFc: 10,
	bassBoostQ: 11,
	trebleBoostGain: 12,
	trebleBoostFc: 13,
	trebleBoostQ: 14,
	/** Target tilt, dB per octave. */
	tilt: 15,

	peakingMinFc: 16,
	peakingMaxFc: 17,
	peakingMinQ: 18,
	peakingMaxQ: 19,
	peakingMinGain: 20,
	peakingMaxGain: 21,

	shelfMinFc: 22,
	shelfMaxFc: 23,
	shelfMinQ: 24,
	shelfMaxQ: 25,
	shelfMinGain: 26,
	shelfMaxGain: 27,

	maxIterations: 28,
	maxEvaluations: 29,
	/** Stop once the loss reaches this. Off by default, and worth leaving off. */
	targetLoss: 30,
	/** Stop once the loss stops moving. Off by default; it costs quality. */
	minStd: 31,

	/**
	 * The band the loss is measured over. Not the same as `peakingMinFc` and
	 * `peakingMaxFc`: those say where a band may sit, these say which error it
	 * is scored against.
	 */
	lossMinF: 32,
	lossMaxF: 33,

	/** Apply each bank's recorded upstream `minStd`. Only `banks` carries one. */
	upstreamStopRules: 34,

	/** Smoothing window, octaves. Upstream's `--window-size`. */
	windowSize: 35,
	/** Smoothing window above the transition band, octaves. */
	trebleWindowSize: 36,
	/** Lower and upper bounds of the transition band, Hz. */
	trebleFLower: 37,
	trebleFUpper: 38,
	/** Per-octave decay of the slope limit inside a clipped region. */
	maxSlopeDecay: 39,
	/** Smoothing for the sound signature, octaves. Goes with `soundSignature`. */
	soundSignatureSmoothing: 40,
	/**
	 * Upstream's `optimize_fixed_band_eq(gain_range=...)`, dB. Replaces every
	 * filter's gain bounds with a window of this half-width centred on the
	 * equalization curve read at that filter's own `fc`. Needs every `fc`
	 * pinned; zero leaves the bounds alone.
	 */
	gainRange: 41,
	/**
	 * Hz above which the loss compares only the mean level of each curve.
	 * 10000 is AutoEq's; `Infinity` scores the treble's shape as well. A
	 * departure from upstream's objective, so off unless asked for.
	 */
	lossFlattenF: 42
};

const OPTION_COUNT = 43;

/**
 * Options that describe the built-in bank, and so say nothing once `banks`
 * does. Passing both is a contradiction rather than a precedence question, so
 * `run` refuses it instead of quietly dropping one.
 */
const BANK_OPTIONS = [
	'peaking',
	'shelves',
	'peakingMinFc',
	'peakingMaxFc',
	'peakingMinQ',
	'peakingMaxQ',
	'peakingMinGain',
	'peakingMaxGain',
	'shelfMinFc',
	'shelfMaxFc',
	'shelfMinQ',
	'shelfMaxQ',
	'shelfMinGain',
	'shelfMaxGain'
];

/**
 * The filter descriptor the module reads and writes. `src/wasm.zig` holds the
 * same two constants; `teq_config_len` sizes the buffer from them.
 */
const BANK_SLOTS = 4;
const FILTER_SLOTS = 10;

/** Slot within a bank header. */
const BANK = { filterCount: 0, minF: 1, maxF: 2, minStd: 3 };

/**
 * Slot within a filter descriptor. `kind` is an index into `FILTER_KINDS`;
 * every other slot is optional and NaN means "not given". Supplying `fc`, `q`
 * or `gain` pins that parameter, which is how AutoEq's own configs say it.
 */
const FILTER = {
	kind: 0,
	fc: 1,
	q: 2,
	gain: 3,
	minFc: 4,
	maxFc: 5,
	minQ: 6,
	maxQ: 7,
	minGain: 8,
	maxGain: 9
};

/** The six bounds `teq_default_limits` writes, in its order. */
const LIMIT_NAMES = ['minFc', 'maxFc', 'minQ', 'maxQ', 'minGain', 'maxGain'];

/** Header slots ahead of the per-filter block, and their meanings. */
const OUT = {
	filterCount: 0,
	loss: 1,
	rmse: 2,
	maxGain: 3,
	preamp: 4,
	iterations: 5,
	evaluations: 6,
	status: 7
};
const OUT_HEADER = 8;
const OUT_PER_FILTER = 4;

/** Mirrors `biquad.Kind`. */
const FILTER_KINDS = ['peaking', 'low_shelf', 'high_shelf'];

/** Mirrors `lbfgs.Status`. Why the fit stopped, for diagnostics only. */
const STATUSES = [
	'gradient_tolerance',
	'function_tolerance',
	'max_iterations',
	'max_evaluations',
	'line_search',
	'early_stop'
];

const ERRORS = {
	'-1': 'out of wasm heap',
	'-2': 'bad curve: needs at least two points on a positive, finite axis, no frequency twice',
	'-3': 'no bands requested',
	'-4': 'output buffer too small',
	'-5': 'bad arguments',
	'-6': 'malformed filter descriptor',
	'-7': 'gainRange needs every filter to have its fc pinned',
	'-8': 'smoothing window is narrower than 3 samples or wider than the whole curve'
};

export class TurboEQError extends Error {
	/** @param {string} message */
	constructor(message) {
		super(message);
		this.name = 'TurboEQError';
	}
}

/**
 * Number of `[f, dB]` points in a curve given in either accepted shape.
 * @param {ArrayLike<number> | ArrayLike<[number, number]>} points
 */
function pointCount(points) {
	if (!points || typeof points.length !== 'number') {
		throw new TurboEQError('curve must be an array of [frequency, dB] pairs');
	}
	return typeof points[0] === 'number' ? points.length / 2 : points.length;
}

/**
 * Copy a curve into wasm memory as interleaved pairs.
 * @param {Float64Array} view
 * @param {ArrayLike<number> | ArrayLike<[number, number]>} points
 */
function writePairs(view, points) {
	if (typeof points[0] === 'number') {
		view.set(/** @type {ArrayLike<number>} */ (points));
		return;
	}
	const pairs = /** @type {ArrayLike<[number, number]>} */ (points);
	for (let i = 0; i < pairs.length; i++) {
		view[i * 2] = pairs[i][0];
		view[i * 2 + 1] = pairs[i][1];
	}
}

/**
 * @typedef {object} Filter
 * @property {'peaking' | 'low_shelf' | 'high_shelf'} type
 * @property {number} fc Centre or transition frequency, Hz.
 * @property {number} q
 * @property {number} gain dB.
 */

/**
 * Lay a bank list out as the descriptor `teq_run_config` reads: the bank count,
 * then one header per bank, then every filter in bank order. NaN is how the
 * descriptor spells "not given", so the view starts filled with it.
 *
 * @param {Float64Array} view
 * @param {BankSpec[]} banks
 */
function writeBanks(view, banks) {
	view.fill(NaN);
	view[0] = banks.length;

	let at = 1;
	for (const bank of banks) {
		view[at + BANK.filterCount] = bank.filters.length;
		if (bank.minF !== undefined) view[at + BANK.minF] = bank.minF;
		if (bank.maxF !== undefined) view[at + BANK.maxF] = bank.maxF;
		if (bank.minStd !== undefined) view[at + BANK.minStd] = bank.minStd;
		at += BANK_SLOTS;
	}

	for (const bank of banks) {
		for (const filt of bank.filters) {
			const kind = FILTER_KINDS.indexOf(filt.type);
			if (kind < 0) throw new TurboEQError(`unknown filter type "${filt.type}"`);
			view[at + FILTER.kind] = kind;
			for (const [name, slot] of Object.entries(FILTER)) {
				if (name === 'kind') continue;
				const value = /** @type {Record<string, number | undefined>} */ (filt)[name];
				if (value !== undefined && value !== null) view[at + slot] = value;
			}
			at += FILTER_SLOTS;
		}
	}
}

/**
 * Narrow `[lo, hi]` to what `defaults` allows, or take it as given.
 *
 * Intersecting is the default because a host's own window is usually wider
 * than AutoEq's — a device profile allowing Q 0.1 to 10 against upstream's
 * 0.18248 to 6 — and quietly loosening the defaults is a change to the
 * objective rather than to how the fit is asked for. A caller that means the
 * wider window says `bounds: 'as-given'` and owns the result.
 *
 * @param {string} what Names the range in the error, e.g. 'Q' or 'Gain'.
 * @param {number | undefined} lo
 * @param {number | undefined} hi
 * @param {number} defaultLo
 * @param {number} defaultHi
 * @param {'intersect' | 'as-given'} mode
 * @returns {[number, number]}
 */
function resolveRange(what, lo, hi, defaultLo, defaultHi, mode) {
	let low = lo ?? defaultLo;
	let high = hi ?? defaultHi;
	if (mode === 'intersect') {
		low = Math.max(low, defaultLo);
		high = Math.min(high, defaultHi);
	}
	if (!(low <= high)) {
		throw new TurboEQError(
			`${what} range [${lo}, ${hi}] does not meet turboEQ's [${defaultLo}, ${defaultHi}]; ` +
				`pass bounds: 'as-given' to use it anyway`
		);
	}
	return [low, high];
}

/**
 * One filter in a bank. Everything but `type` is optional: a value given pins
 * that parameter, a bound left out takes AutoEq's default for the type, and a
 * bound pair collapsed to a point pins the parameter too.
 *
 * @typedef {object} FilterSpec
 * @property {'peaking' | 'low_shelf' | 'high_shelf'} type
 * @property {number} [fc]
 * @property {number} [q]
 * @property {number} [gain]
 * @property {number} [minFc]
 * @property {number} [maxFc]
 * @property {number} [minQ]
 * @property {number} [maxQ]
 * @property {number} [minGain]
 * @property {number} [maxGain]
 */

/**
 * One of upstream's `PEQ_CONFIGS` entries. Banks are fitted in order and each
 * one fits the residual the last one left.
 *
 * @typedef {object} BankSpec
 * @property {FilterSpec[]} filters
 * @property {number} [minF] Lower bound of the band the loss is measured over.
 * @property {number} [maxF] Upper bound of it.
 * @property {number} [minStd] Upstream's early stop. Needs `upstreamStopRules`.
 */

/**
 * The bounds a host may put on every band of a bank it asks for. Each is
 * intersected with AutoEq's defaults for the filter type unless `bounds` says
 * otherwise.
 *
 * @typedef {object} BandLimits
 * @property {number} [minFc]
 * @property {number} [maxFc]
 * @property {number} [minQ]
 * @property {number} [maxQ]
 * @property {number} [minGain]
 * @property {number} [maxGain]
 */

/**
 * @typedef {object} Result
 * @property {Filter[]} filters
 * @property {number} rmse Fit error against the equalization curve, dB.
 * @property {number} loss The optimizer's own objective, penalties included.
 * @property {number} maxGain Largest boost the cascade applies, dB.
 * @property {number} preamp `-max(0, maxGain)`, what a player should be set to.
 * @property {number} iterations
 * @property {number} evaluations
 * @property {string} status Why the fit stopped.
 */

export class TurboEQ {
	/**
	 * @param {WebAssembly.Instance} instance
	 * @private
	 */
	constructor(instance) {
		/** @type {any} */
		this.exports = instance.exports;
		const version = this.exports.teq_abi_version();
		if (version !== ABI_VERSION) {
			throw new TurboEQError(
				`turboeq.wasm speaks ABI ${version}, this module speaks ${ABI_VERSION}`
			);
		}
	}

	/**
	 * `source` is anything `WebAssembly.instantiateStreaming` or
	 * `WebAssembly.instantiate` accepts: a `Response`, a promise of one, a
	 * `BufferSource`, or a compiled `Module`. The module imports nothing, so
	 * there is no import object to supply.
	 *
	 * @param {Response | PromiseLike<Response> | BufferSource | WebAssembly.Module} source
	 * @returns {Promise<TurboEQ>}
	 */
	static async instantiate(source) {
		const awaited = await source;
		if (awaited instanceof WebAssembly.Module) {
			return new TurboEQ(await WebAssembly.instantiate(awaited, {}));
		}
		if (typeof Response !== 'undefined' && awaited instanceof Response) {
			// Falls back when the server does not send application/wasm, which
			// static hosts routinely do not.
			try {
				const streamed = await WebAssembly.instantiateStreaming(awaited, {});
				return new TurboEQ(streamed.instance);
			} catch {
				const bytes = await awaited.clone().arrayBuffer();
				const { instance } = await WebAssembly.instantiate(bytes, {});
				return new TurboEQ(instance);
			}
		}
		const { instance } = await WebAssembly.instantiate(/** @type {BufferSource} */ (awaited), {});
		return new TurboEQ(instance);
	}

	/**
	 * Whether this engine runs WebAssembly SIMD, which is what `load` asks
	 * before choosing a build.
	 *
	 * @returns {boolean}
	 */
	static supportsSimd() {
		try {
			return WebAssembly.validate(SIMD_PROBE);
		} catch {
			return false;
		}
	}

	/**
	 * Instantiate a module that ships beside this file: fetched in a browser
	 * or worker, read from disk under Node. `turboeq-simd.wasm` where the
	 * engine supports SIMD, `turboeq.wasm` where it does not. The two return
	 * bit-identical fits; the first is faster. `simd` overrides the choice.
	 *
	 * Vite and webpack see each `new URL(..., import.meta.url)` and emit both
	 * files as assets; only the chosen one is fetched. A host that serves the
	 * module from somewhere else passes it to `instantiate`.
	 *
	 * @param {{ simd?: boolean }} [options]
	 * @returns {Promise<TurboEQ>}
	 */
	static async load({ simd = TurboEQ.supportsSimd() } = {}) {
		const url = simd
			? new URL('./turboeq-simd.wasm', import.meta.url)
			: new URL('./turboeq.wasm', import.meta.url);
		if (url.protocol === 'file:') {
			// A variable specifier behind both ignore comments, so a browser
			// bundle neither resolves nor stubs a module it never calls.
			const fs = 'node:fs/promises';
			const { readFile } = await import(/* webpackIgnore: true */ /* @vite-ignore */ fs);
			return TurboEQ.instantiate(await readFile(url));
		}
		return TurboEQ.instantiate(fetch(url));
	}

	/** Bytes of arena the module holds. */
	get heapSize() {
		return this.exports.teq_heap_size();
	}

	/** High-water mark since the last run, in bytes. Diagnostic. */
	get heapUsed() {
		return this.exports.teq_heap_used();
	}

	/**
	 * Fit a parametric EQ taking `source` to `target`.
	 *
	 * The default bank is `peaking` free peaking bands plus the two pinned
	 * shelves — upstream's `N_PEAKING_WITH_SHELVES`. Pass `banks` instead to
	 * say exactly which filters to fit and what each one may do, which is
	 * AutoEq's `PEQ.from_dict` over a list of configs: per-filter bounds,
	 * per-filter pinning, and a cascade where each bank fits what the last one
	 * left. The two describe the same thing, so passing both is refused.
	 *
	 * @param {ArrayLike<number> | ArrayLike<[number, number]>} source
	 * @param {ArrayLike<number> | ArrayLike<[number, number]>} target
	 * @param {RunOptions} [options]
	 * @returns {Result}
	 */
	run(source, target, options = {}) {
		const { banks = null, soundSignature = null, ...slots } = options;
		if (banks !== null) {
			if (!Array.isArray(banks) || banks.length === 0) {
				throw new TurboEQError('banks must be a non-empty array of filter banks');
			}
			for (const bank of banks) {
				if (!bank || !Array.isArray(bank.filters) || bank.filters.length === 0) {
					throw new TurboEQError('every bank needs at least one filter');
				}
			}
			const overlap = BANK_OPTIONS.filter((name) => slots[name] !== undefined);
			if (overlap.length > 0) {
				throw new TurboEQError(
					`banks already says what ${overlap.join(', ')} would: drop one of the two`
				);
			}
		}
		return this.#fit(source, target, slots, banks, soundSignature);
	}

	/**
	 * AutoEq's `global_filter_defaults` for one filter type: the window a
	 * parameter is optimized in when nothing narrows it, and what the bank
	 * builders below intersect a host's own ranges with.
	 *
	 * @param {'peaking' | 'low_shelf' | 'high_shelf'} type
	 * @returns {Required<BandLimits>}
	 */
	defaultLimits(type) {
		const kind = FILTER_KINDS.indexOf(type);
		if (kind < 0) throw new TurboEQError(`unknown filter type "${type}"`);
		const wasm = this.exports;
		const buf = wasm.teq_alloc(LIMIT_NAMES.length * 8);
		if (!buf) throw new TurboEQError(ERRORS['-1']);
		const written = wasm.teq_default_limits(kind, buf, LIMIT_NAMES.length);
		if (written < 0) {
			throw new TurboEQError(ERRORS[String(written)] ?? `turboeq failed with ${written}`);
		}
		const view = new Float64Array(wasm.memory.buffer, buf, written);
		return /** @type {Required<BandLimits>} */ (
			Object.fromEntries(LIMIT_NAMES.map((name, i) => [name, view[i]]))
		);
	}

	/**
	 * A bank of `peaking` free peaking bands, optionally behind the two pinned
	 * shelves, with every band held to `limits`. This is the built-in bank
	 * spelled out, and it is what a host with a device profile wants: the
	 * profile's own frequency, Q and gain windows become the bounds the fit
	 * lands inside, rather than a clamp applied to the answer afterwards.
	 *
	 * @param {object} [spec]
	 * @param {number} [spec.peaking] Peaking bands. Shelves are not counted here.
	 * @param {boolean} [spec.shelves] Pinned 105 Hz and 10 kHz shelves, gain free.
	 * @param {BandLimits} [spec.limits] Applied to the peaking bands.
	 * @param {BandLimits} [spec.shelfLimits] Applied to the shelves. Gain only,
	 *   since their fc and Q are pinned. Defaults to `limits`'s gain window.
	 * @param {'intersect' | 'as-given'} [spec.bounds] What to do where `limits`
	 *   is wider than AutoEq's defaults. Intersects by default.
	 * @returns {BankSpec}
	 */
	peakingBank({
		peaking = 8,
		shelves = true,
		limits = {},
		shelfLimits = undefined,
		bounds = 'intersect'
	} = {}) {
		const count = Math.floor(peaking);
		if (!Number.isFinite(count) || count < 0) {
			throw new TurboEQError(`peaking must be a non-negative count, got ${peaking}`);
		}
		const total = count + (shelves ? 2 : 0);
		if (total === 0) throw new TurboEQError(ERRORS['-3']);
		if (total > MAX_FILTERS) {
			throw new TurboEQError(`${total} filters is past MAX_FILTERS (${MAX_FILTERS})`);
		}

		/** @type {FilterSpec[]} */
		const filters = [];
		if (shelves) {
			const gains = shelfLimits ?? { minGain: limits.minGain, maxGain: limits.maxGain };
			const shelf = this.defaultLimits('low_shelf');
			const [minGain, maxGain] = resolveRange(
				'shelf gain',
				gains.minGain,
				gains.maxGain,
				shelf.minGain,
				shelf.maxGain,
				bounds
			);
			// fc and Q pinned, which is what every shipped upstream preset does;
			// a pinned parameter needs no bounds, so none are written.
			filters.push({ type: 'low_shelf', fc: 105, q: 0.7, minGain, maxGain });
			filters.push({ type: 'high_shelf', fc: 10000, q: 0.7, minGain, maxGain });
		}

		const peak = this.defaultLimits('peaking');
		const range = (what, lo, hi) =>
			resolveRange(what, lo, hi, peak[`min${what}`], peak[`max${what}`], bounds);
		const [minFc, maxFc] = range('Fc', limits.minFc, limits.maxFc);
		const [minQ, maxQ] = range('Q', limits.minQ, limits.maxQ);
		const [minGain, maxGain] = range('Gain', limits.minGain, limits.maxGain);
		for (let i = 0; i < count; i++) {
			filters.push({ type: 'peaking', minFc, maxFc, minQ, maxQ, minGain, maxGain });
		}
		return { filters };
	}

	/**
	 * A graphic EQ: one peaking band per frequency, fc and Q pinned, gain the
	 * only free parameter. `10_BAND_GRAPHIC_EQ` is exactly this shape.
	 *
	 * Fitting on the grid beats fitting freely and snapping each band to the
	 * nearest slider afterwards, which moves every filter off the frequency it
	 * was optimized at. Snapping still has a place for hand-edited filters; it
	 * has none here.
	 *
	 * @param {ArrayLike<number>} frequencies Hz, one band each.
	 * @param {object} [spec]
	 * @param {number} [spec.q] Pinned for every band. AutoEq's own grids use
	 *   sqrt(2) for octave bands and 4.318473 for third-octave ones.
	 * @param {number} [spec.minGain]
	 * @param {number} [spec.maxGain]
	 * @param {'intersect' | 'as-given'} [spec.bounds]
	 * @returns {BankSpec}
	 */
	graphicBank(frequencies, { q = Math.SQRT2, minGain, maxGain, bounds = 'intersect' } = {}) {
		const fcs = Array.from(frequencies, Number);
		if (fcs.length === 0) throw new TurboEQError(ERRORS['-3']);
		if (fcs.length > MAX_FILTERS) {
			throw new TurboEQError(`${fcs.length} bands is past MAX_FILTERS (${MAX_FILTERS})`);
		}
		const peak = this.defaultLimits('peaking');
		const [low, high] = resolveRange('gain', minGain, maxGain, peak.minGain, peak.maxGain, bounds);
		return {
			// fc and Q are pinned, so neither takes bounds — a slider at 16 kHz
			// sits outside AutoEq's default fc window and is meant to.
			filters: fcs.map((fc) => ({
				type: /** @type {const} */ ('peaking'),
				fc,
				q,
				minGain: low,
				maxGain: high
			}))
		};
	}

	/**
	 * The body every fit goes through. `banks` null runs the built-in bank
	 * `peaking` and `shelves` describe.
	 *
	 * @param {ArrayLike<number> | ArrayLike<[number, number]>} source
	 * @param {ArrayLike<number> | ArrayLike<[number, number]>} target
	 * @param {Partial<Record<string, number | boolean>>} options
	 * @param {BankSpec[] | null} banks
	 * @param {ArrayLike<number> | ArrayLike<[number, number]> | null} soundSignature
	 * @returns {Result}
	 */
	#fit(source, target, options, banks, soundSignature) {
		const wasm = this.exports;
		const srcLen = pointCount(source);
		const tgtLen = pointCount(target);
		if (!Number.isInteger(srcLen) || !Number.isInteger(tgtLen)) {
			throw new TurboEQError('an interleaved curve needs an even number of values');
		}

		const sigLen = soundSignature ? pointCount(soundSignature) : 0;
		if (!Number.isInteger(sigLen)) {
			throw new TurboEQError('an interleaved curve needs an even number of values');
		}

		let bands = 0;
		let specLen = 0;
		if (banks) {
			for (const bank of banks) bands += bank.filters.length;
			specLen = wasm.teq_config_len(banks.length, bands);
		} else {
			bands = this.#bandCount(options);
		}

		// One arena per call: the previous call's buffers are not wanted and
		// the module has no other state to lose.
		wasm.teq_reset();
		const cap = wasm.teq_output_len(bands);
		const src = wasm.teq_alloc(srcLen * 2 * 8);
		const tgt = wasm.teq_alloc(tgtLen * 2 * 8);
		const opt = wasm.teq_alloc(OPTION_COUNT * 8);
		const spec = specLen ? wasm.teq_alloc(specLen * 8) : 0;
		const sig = sigLen ? wasm.teq_alloc(sigLen * 2 * 8) : 0;
		const out = wasm.teq_alloc(cap * 8);
		if (!src || !tgt || !opt || !out || (specLen && !spec) || (sigLen && !sig)) {
			throw new TurboEQError(ERRORS['-1']);
		}

		// Views are taken after the last allocation: growing the memory would
		// detach any taken earlier.
		const memory = wasm.memory.buffer;
		writePairs(new Float64Array(memory, src, srcLen * 2), source);
		writePairs(new Float64Array(memory, tgt, tgtLen * 2), target);

		const opts = new Float64Array(memory, opt, OPTION_COUNT).fill(NaN);
		for (const [name, value] of Object.entries(options)) {
			const slot = OPTION_SLOTS[/** @type {keyof typeof OPTION_SLOTS} */ (name)];
			if (slot === undefined) throw new TurboEQError(`unknown option "${name}"`);
			if (value === undefined || value === null) continue;
			opts[slot] = typeof value === 'boolean' ? (value ? 1 : 0) : value;
		}

		if (banks) writeBanks(new Float64Array(memory, spec, specLen), banks);
		if (sigLen) {
			writePairs(new Float64Array(memory, sig, sigLen * 2), /** @type {any} */ (soundSignature));
		}

		const written = banks
			? wasm.teq_run_config(
					src,
					srcLen,
					tgt,
					tgtLen,
					opt,
					OPTION_COUNT,
					spec,
					specLen,
					sig,
					sigLen,
					out,
					cap
				)
			: wasm.teq_run(src, srcLen, tgt, tgtLen, opt, OPTION_COUNT, out, cap);
		if (written < 0) {
			throw new TurboEQError(ERRORS[String(written)] ?? `turboeq failed with ${written}`);
		}

		const slots = new Float64Array(wasm.memory.buffer, out, written);
		const filters = [];
		for (let i = 0; i < slots[OUT.filterCount]; i++) {
			const at = OUT_HEADER + i * OUT_PER_FILTER;
			filters.push({
				type: FILTER_KINDS[slots[at]],
				fc: slots[at + 1],
				q: slots[at + 2],
				gain: slots[at + 3]
			});
		}
		return {
			filters: /** @type {Filter[]} */ (filters),
			rmse: slots[OUT.rmse],
			loss: slots[OUT.loss],
			maxGain: slots[OUT.maxGain],
			preamp: slots[OUT.preamp],
			iterations: slots[OUT.iterations],
			evaluations: slots[OUT.evaluations],
			status: STATUSES[slots[OUT.status]] ?? 'unknown'
		};
	}

	/**
	 * How many bands the fit will return, which is what sizes the output
	 * buffer. The defaults here mirror `pipeline.Config`; see the band-count
	 * note at the top of this file.
	 * @param {Partial<Record<string, number | boolean>>} options
	 */
	#bandCount(options) {
		const peaking = options.peaking === undefined ? 8 : Number(options.peaking);
		const shelves = options.shelves === undefined ? true : Boolean(options.shelves);
		const total = Math.max(0, Math.floor(peaking)) + (shelves ? 2 : 0);
		if (total === 0) throw new TurboEQError(ERRORS['-3']);
		return total;
	}
}

/**
 * Everything `run` takes: the scalar options above, plus the two that are
 * structure rather than a number.
 *
 * @typedef {Partial<Record<keyof typeof OPTION_SLOTS, number | boolean>> & {
 *   banks?: BankSpec[] | null,
 *   soundSignature?: ArrayLike<number> | ArrayLike<[number, number]> | null
 * }} RunOptions
 */
