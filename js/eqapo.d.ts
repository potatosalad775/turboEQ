/**
 * Types for `eqapo.js`. Hand-written, like `turboeq.d.ts`.
 */

/** Room left below the loudest sample when normalizing, dB. */
export declare const PREAMP_HEADROOM: number;

/** Ratio between neighbouring frequencies on the GraphicEQ axis. */
export declare const GRAPHIC_EQ_STEP: number;

/** EqualizerAPO `Preamp:` and `Filter N:` lines for a `TurboEQ` result. */
export declare function eqapoParametric(result: {
	filters: ArrayLike<{ type: string; fc: number; q: number; gain: number }>;
	maxGain: number;
}): string;

/** The 127 frequencies EqualizerAPO's GraphicEQ line is written on, Hz. */
export declare function graphicAxis(): number[];

/** One `GraphicEQ:` line for a curve on its own axis. */
export declare function eqapoGraphic(
	f: ArrayLike<number>,
	equalization: ArrayLike<number>,
	options?: { normalize?: boolean; preamp?: number }
): string;
