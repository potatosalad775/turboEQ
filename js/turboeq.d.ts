/**
 * Types for `turboeq.js`. Hand-written, because the module is plain ES with
 * JSDoc and a host with `allowJs: false` would otherwise see `any`.
 *
 * Every option is optional and every one left out takes turboEQ's default,
 * which is upstream AutoEq's default. See `turboeq.js` for what each means.
 */

export declare const ABI_VERSION: number;

/** The cap a host applies when its own model says "as many bands as you like". */
export declare const MAX_FILTERS: number;

export declare class TurboEQError extends Error {
	constructor(message: string);
}

/** A curve: `[frequency, dB]` pairs, or the same pairs interleaved flat. */
export type Curve = ArrayLike<number> | ArrayLike<[number, number]>;

export interface TurboEQOptions {
	sampleRate?: number;
	/** Free peaking bands. The two shelves are not counted here. */
	peaking?: number;
	shelves?: boolean;
	preamp?: number;
	minMeanError?: boolean;

	maxGain?: number;
	maxSlope?: number;
	trebleGainK?: number;
	conchaInterference?: boolean;

	bassBoostGain?: number;
	bassBoostFc?: number;
	bassBoostQ?: number;
	trebleBoostGain?: number;
	trebleBoostFc?: number;
	trebleBoostQ?: number;
	tilt?: number;

	peakingMinFc?: number;
	peakingMaxFc?: number;
	peakingMinQ?: number;
	peakingMaxQ?: number;
	peakingMinGain?: number;
	peakingMaxGain?: number;

	shelfMinFc?: number;
	shelfMaxFc?: number;
	shelfMinQ?: number;
	shelfMaxQ?: number;
	shelfMinGain?: number;
	shelfMaxGain?: number;

	maxIterations?: number;
	maxEvaluations?: number;
	targetLoss?: number;
	minStd?: number;

	/** The band the loss is measured over, not where bands may sit. */
	lossMinF?: number;
	lossMaxF?: number;

	/** Apply each bank's own `minStd`. Only `banks` carries one. */
	upstreamStopRules?: boolean;

	/** Smoothing window in octaves, and the treble transition band. */
	windowSize?: number;
	trebleWindowSize?: number;
	trebleFLower?: number;
	trebleFUpper?: number;
	/** Per-octave decay of the slope limit inside a clipped region. */
	maxSlopeDecay?: number;
	/** Smoothing for the sound signature, octaves. Goes with `soundSignature`. */
	soundSignatureSmoothing?: number;

	/**
	 * Upstream's `optimize_fixed_band_eq(gain_range=...)`, dB. Replaces every
	 * filter's gain bounds with a window of this half-width centred on the
	 * equalization curve at that filter's own `fc`. Every `fc` must be pinned
	 * — use `graphicBank`, or a `banks` descriptor that sets `fc` on each
	 * filter. Zero or omitted leaves the bounds alone.
	 */
	gainRange?: number;

	/**
	 * Hz above which the loss compares only the mean level of each curve,
	 * 10000 in AutoEq, so bands up there can set the treble's overall level
	 * but not its shape. `Infinity` scores the shape all the way up, for
	 * measurements trusted past 10 kHz. Departs from upstream's objective.
	 */
	lossFlattenF?: number;

	/**
	 * Add each peaking band's sharpness penalty to the loss, as AutoEq does.
	 * `false` lets the fit use bands steeper than about 18 dB per octave
	 * without paying for it. Departs from upstream's objective.
	 */
	sharpnessPenalty?: boolean;

	/**
	 * Octaves of the last smoothing pass over the equalization curve. AutoEq
	 * hardcodes 1/5; `0` skips the pass. Departs from upstream's objective.
	 */
	equalizationWindowSize?: number;
}

/**
 * What `fit: 'exact'` stands for. Options passed outright win over these.
 */
export declare const EXACT_MATCH_OPTIONS: Readonly<{
	lossFlattenF: number;
	trebleWindowSize: number;
	maxSlope: number;
	sharpnessPenalty: false;
	equalizationWindowSize: 0;
}>;

/** Everything `run` takes: the scalars above, plus the two that are structure. */
export interface TurboEQRunOptions extends TurboEQOptions {
	/**
	 * `'autoeq'`, the default, is AutoEq's objective. `'exact'` fits the curve
	 * as a graph shows it: `EXACT_MATCH_OPTIONS` underneath whatever else is
	 * passed, and the built-in bank's peaking bands allowed up to 20 kHz.
	 */
	fit?: 'autoeq' | 'exact';
	/**
	 * The filter banks to fit, in order, each against what the last one left.
	 * AutoEq's `PEQ.from_dict` over a list of configs. Says everything the
	 * band-count and limit options would, so passing both is refused.
	 */
	banks?: TurboEQBankSpec[] | null;
	/** A colouration the fit aims at rather than corrects, on its own axis. */
	soundSignature?: Curve | null;
}

/** Per-band bounds a host puts on a bank it asks for. */
export interface TurboEQBandLimits {
	minFc?: number;
	maxFc?: number;
	minQ?: number;
	maxQ?: number;
	minGain?: number;
	maxGain?: number;
}

/**
 * One filter in a bank. Everything but `type` is optional: a value given pins
 * that parameter, a bound left out takes AutoEq's default for the type, and a
 * bound pair collapsed to a point pins the parameter too.
 */
export interface TurboEQFilterSpec {
	type: 'peaking' | 'low_shelf' | 'high_shelf';
	fc?: number;
	q?: number;
	gain?: number;
	minFc?: number;
	maxFc?: number;
	minQ?: number;
	maxQ?: number;
	minGain?: number;
	maxGain?: number;
}

/**
 * One of AutoEq's `PEQ_CONFIGS` entries. Banks are fitted in order, each
 * against the residual the one before it left.
 */
export interface TurboEQBankSpec {
	filters: TurboEQFilterSpec[];
	/** The band this bank's loss is measured over. */
	minF?: number;
	maxF?: number;
	/** Upstream's early stop. Needs `upstreamStopRules` to take effect. */
	minStd?: number;
}

export interface TurboEQFilter {
	type: 'peaking' | 'low_shelf' | 'high_shelf';
	/** Centre frequency for a peak, transition frequency for a shelf. Hz. */
	fc: number;
	q: number;
	/** dB. */
	gain: number;
}

export interface TurboEQResult {
	filters: TurboEQFilter[];
	/** Fit error against the equalization curve, dB. */
	rmse: number;
	/** The optimizer's own objective, sharpness penalties included. */
	loss: number;
	/** Largest boost the cascade applies, dB. */
	maxGain: number;
	/** `-max(0, maxGain)`: what a player's preamp should be set to. */
	preamp: number;
	iterations: number;
	evaluations: number;
	/** Why the fit stopped. Diagnostic. */
	status: string;
}

export declare class TurboEQ {
	static instantiate(
		source: Response | PromiseLike<Response> | BufferSource | WebAssembly.Module
	): Promise<TurboEQ>;

	/** Whether this engine runs WebAssembly SIMD. */
	static supportsSimd(): boolean;

	/**
	 * Instantiate a module shipped beside the binding: `turboeq-simd.wasm`
	 * where the engine supports SIMD, `turboeq.wasm` where it does not. Both
	 * return bit-identical fits. `simd` overrides the choice.
	 */
	static load(options?: { simd?: boolean }): Promise<TurboEQ>;

	readonly heapSize: number;
	readonly heapUsed: number;

	/**
	 * Fit a parametric EQ taking `source` to `target`. The default bank is
	 * `peaking` free peaking bands plus the two pinned shelves; `options.banks`
	 * says exactly which filters to fit instead.
	 */
	run(source: Curve, target: Curve, options?: TurboEQRunOptions): TurboEQResult;

	/** AutoEq's `global_filter_defaults` for one filter type. */
	defaultLimits(type: 'peaking' | 'low_shelf' | 'high_shelf'): Required<TurboEQBandLimits>;

	/** The built-in bank spelled out, with every band held to `limits`. */
	peakingBank(spec?: {
		peaking?: number;
		shelves?: boolean;
		/**
		 * `'pinned'` (default) holds the shelves at 105 Hz / 10 kHz, Q 0.7, as
		 * AutoEq's presets do. `'free'` fits their fc and Q inside `shelfLimits`.
		 */
		shelfPlacement?: 'pinned' | 'free';
		limits?: TurboEQBandLimits;
		shelfLimits?: TurboEQBandLimits;
		bounds?: 'intersect' | 'as-given';
	}): TurboEQBankSpec;

	/** A graphic EQ: one band per frequency, fc and Q pinned, gain free. */
	graphicBank(
		frequencies: ArrayLike<number>,
		spec?: {
			q?: number;
			minGain?: number;
			maxGain?: number;
			bounds?: 'intersect' | 'as-given';
		}
	): TurboEQBankSpec;
}
