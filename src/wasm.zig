//! The `wasm32-freestanding` boundary.
//!
//! No WASI, no imports at all: the module is a pure function of the bytes
//! the host writes into its memory. Everything crossing the boundary is an
//! `f64`, because that is the one type JavaScript and Zig agree on exactly
//! and it lets the host use a single `Float64Array` view for arguments,
//! options and results. No JSON, no strings, no structs.
//!
//! The host's sequence is always the same:
//!
//!     teq_reset();
//!     const src = teq_alloc(n_src * 2 * 8);   // interleaved f, dB
//!     const tgt = teq_alloc(n_tgt * 2 * 8);
//!     const out = teq_alloc(cap * 8);
//!     ... write into memory.buffer ...
//!     const written = teq_run(src, n_src, tgt, n_tgt, opt, n_opt, out, cap);
//!
//! `teq_run` allocates its working memory above whatever the host allocated
//! and rewinds to that mark on the way out, so the input and output buffers
//! stay valid and a second run costs nothing extra. Only `teq_reset`
//! releases the host's own buffers.
//!
//! The heap is one fixed arena and a bump allocator over it, which is all
//! the port needs: every stage takes an explicit allocator and no module
//! holds global state. See CLAUDE.md.

const std = @import("std");
const math = std.math;
const pipeline = @import("pipeline.zig");
const peq = @import("peq.zig");
const configs = @import("configs.zig");
const lbfgs = @import("lbfgs.zig");

/// Freestanding has nowhere to print to, so a panic is a trap. It reaches
/// the host as a WebAssembly RuntimeError thrown from the call that trapped.
pub const panic = std.debug.FullPanic(trap);

fn trap(_: []const u8, _: ?usize) noreturn {
    @trap();
}

/// Far more than a realistic fit needs, and it costs nothing to over-declare:
/// the module declares the pages, the engine commits only those written.
///
/// Read `teq_heap_used` after a run rather than trusting any number written
/// down here. BENCHMARKS.md records what one fit actually peaked at, and when.
const heap_size = 8 * 1024 * 1024;

var heap: [heap_size]u8 align(16) = undefined;
var fba = std.heap.FixedBufferAllocator.init(&heap);
var high_water: usize = 0;

// ---------------------------------------------------------------------------
// Error codes. Negative, so `teq_run`'s return doubles as a length.
// ---------------------------------------------------------------------------

const err_out_of_memory: i32 = -1;
/// Fewer than two points, a repeated frequency, a non-positive frequency, or
/// a NaN anywhere in a curve. An unsorted axis is sorted rather than refused.
const err_bad_curve: i32 = -2;
const err_no_bands: i32 = -3;
/// `out_cap` is smaller than `teq_output_len` says it has to be.
const err_output_too_small: i32 = -4;
/// A null pointer or a zero length where one is not allowed.
const err_bad_args: i32 = -5;
/// The filter descriptor `teq_run_config` was handed is malformed: a bad
/// count, an unknown filter kind, or fewer slots than its own header claims.
const err_bad_config: i32 = -6;
/// `gain_range` was given alongside a filter whose `fc` is free. A gain
/// window is read off the curve at each band's own centre, so there has to
/// be one.
const err_gain_range_fc: i32 = -7;
/// A smoothing window, main or treble, shorter than three samples of the
/// grid or longer than the whole of it. Upstream's scipy raises on both.
const err_bad_smoothing_window: i32 = -8;

// ---------------------------------------------------------------------------
// The options vector
// ---------------------------------------------------------------------------

/// Positional, so it only ever grows at the end and an older host stays
/// compatible with a newer module. A slot the host left off the end, or set
/// to NaN, takes the default — which lets the host fill in the three or four
/// it cares about and leave holes.
///
/// Keep this in step with `OPTION_SLOTS` in `js/turboeq.js`; the two lists
/// are the whole contract.
const Opt = enum(usize) {
    fs = 0,
    /// Free peaking bands. The shelves are not counted here.
    peaking = 1,
    /// Non-zero prepends the two pinned shelves.
    shelves = 2,
    preamp = 3,
    /// Non-zero shifts the error by its mean over 100 Hz to 10 kHz.
    min_mean_error = 4,

    max_gain = 5,
    max_slope = 6,
    treble_gain_k = 7,
    concha_interference = 8,

    bass_boost_gain = 9,
    bass_boost_fc = 10,
    bass_boost_q = 11,
    treble_boost_gain = 12,
    treble_boost_fc = 13,
    treble_boost_q = 14,
    tilt = 15,

    peaking_min_fc = 16,
    peaking_max_fc = 17,
    peaking_min_q = 18,
    peaking_max_q = 19,
    peaking_min_gain = 20,
    peaking_max_gain = 21,

    shelf_min_fc = 22,
    shelf_max_fc = 23,
    shelf_min_q = 24,
    shelf_max_q = 25,
    shelf_min_gain = 26,
    shelf_max_gain = 27,

    /// 0 or NaN keeps the solver default.
    max_iterations = 28,
    max_evaluations = 29,
    /// NaN leaves the early stop off, which is the default; see
    /// `peq.StopRules` on why.
    target_loss = 30,
    min_std = 31,

    /// The band the loss is measured over. Not the same as the fc bounds:
    /// these decide which error the fit is scored against.
    loss_min_f = 32,
    loss_max_f = 33,

    /// Non-zero applies each bank's recorded upstream `min_std`. Only
    /// meaningful alongside `teq_run_config`, since the built-in bank has
    /// none. Off by default; see `peq.StopRules`.
    upstream_stop_rules = 34,

    /// The smoothing stage, which upstream exposes as `--window-size`,
    /// `--treble-window-size`, `--treble-f-lower` and `--treble-f-upper`.
    window_size = 35,
    treble_window_size = 36,
    treble_f_lower = 37,
    treble_f_upper = 38,
    /// `max_slope_decay`. Upstream ships 0.0, which disables it.
    max_slope_decay = 39,

    /// `sound_signature_smoothing_window_size`, octaves. The signature
    /// itself is a curve and travels as `teq_run_config`'s third one; this
    /// is only the scalar that goes with it. Zero or NaN leaves it
    /// unsmoothed, which is upstream's default.
    sound_signature_smoothing = 40,

    /// `optimize_fixed_band_eq`'s `gain_range`, dB. NaN or zero leaves the
    /// filters' own gain bounds alone, which is the default. Every filter
    /// must have its `fc` pinned or the run returns `err_gain_range_fc`.
    gain_range = 41,

    /// Hz above which the loss compares only mean level, 10 kHz upstream.
    /// Infinity, or anything past the top of the grid, scores the treble's
    /// shape too. An opt-in departure from upstream's objective.
    loss_flatten_f = 42,

    /// Zero drops each peaking filter's sharpness penalty from the loss.
    /// Non-zero, or NaN, keeps it, as upstream does. An opt-in departure from
    /// upstream's objective, like `loss_flatten_f`.
    sharpness_penalty = 43,

    /// Octaves of the last smoothing pass over the equalization curve, 1/5
    /// upstream. Zero skips it. An opt-in departure, like `loss_flatten_f`.
    equalization_window_size = 44,

    const count = 45;
};

fn optAt(opts: []const f64, which: Opt, fallback: f64) f64 {
    const i = @intFromEnum(which);
    if (i >= opts.len) return fallback;
    const v = opts[i];
    return if (math.isNan(v)) fallback else v;
}

fn optFlag(opts: []const f64, which: Opt, fallback: bool) bool {
    const i = @intFromEnum(which);
    if (i >= opts.len) return fallback;
    const v = opts[i];
    if (math.isNan(v)) return fallback;
    return v != 0.0;
}

fn optCount(opts: []const f64, which: Opt, fallback: usize) usize {
    const v = optAt(opts, which, @floatFromInt(fallback));
    if (!math.isFinite(v) or v < 0.0) return fallback;
    return @intFromFloat(@floor(v));
}

fn configFrom(opts: []const f64) pipeline.Config {
    const defaults = pipeline.Config{};
    var cfg = defaults;

    cfg.fs = optAt(opts, .fs, defaults.fs);
    cfg.peaking = optCount(opts, .peaking, defaults.peaking);
    cfg.shelves = optFlag(opts, .shelves, defaults.shelves);
    cfg.preamp = optAt(opts, .preamp, defaults.preamp);
    cfg.min_mean_error = optFlag(opts, .min_mean_error, defaults.min_mean_error);

    cfg.equalization = .{
        .max_gain = optAt(opts, .max_gain, defaults.equalization.max_gain),
        .max_slope = optAt(opts, .max_slope, defaults.equalization.max_slope),
        .max_slope_decay = optAt(opts, .max_slope_decay, defaults.equalization.max_slope_decay),
        .concha_interference = optFlag(
            opts,
            .concha_interference,
            defaults.equalization.concha_interference,
        ),
        .window_size = optAt(opts, .window_size, defaults.equalization.window_size),
        .treble_window_size = optAt(
            opts,
            .treble_window_size,
            defaults.equalization.treble_window_size,
        ),
        .treble_f_lower = optAt(opts, .treble_f_lower, defaults.equalization.treble_f_lower),
        .treble_f_upper = optAt(opts, .treble_f_upper, defaults.equalization.treble_f_upper),
        .treble_gain_k = optAt(opts, .treble_gain_k, defaults.equalization.treble_gain_k),
        .equalization_window_size = optAt(
            opts,
            .equalization_window_size,
            defaults.equalization.equalization_window_size,
        ),
    };
    // `smoothen` asserts on a non-ascending transition band, and a host that
    // sent one would trap rather than get an error code back.
    if (!(cfg.equalization.treble_f_upper > cfg.equalization.treble_f_lower)) {
        cfg.equalization.treble_f_lower = defaults.equalization.treble_f_lower;
        cfg.equalization.treble_f_upper = defaults.equalization.treble_f_upper;
    }

    cfg.upstream_stop_rules = optFlag(opts, .upstream_stop_rules, defaults.upstream_stop_rules);
    // Zero is "no window" rather than a zero-width one: a host that clears
    // the slot means to leave the bounds alone.
    cfg.gain_range = blk: {
        const v = optOrNull(opts, .gain_range) orelse break :blk null;
        break :blk if (v == 0.0) null else v;
    };

    cfg.target = .{
        .bass_boost_gain = optAt(opts, .bass_boost_gain, defaults.target.bass_boost_gain),
        .bass_boost_fc = optAt(opts, .bass_boost_fc, defaults.target.bass_boost_fc),
        .bass_boost_q = optAt(opts, .bass_boost_q, defaults.target.bass_boost_q),
        .treble_boost_gain = optAt(opts, .treble_boost_gain, defaults.target.treble_boost_gain),
        .treble_boost_fc = optAt(opts, .treble_boost_fc, defaults.target.treble_boost_fc),
        .treble_boost_q = optAt(opts, .treble_boost_q, defaults.target.treble_boost_q),
        .tilt = optAt(opts, .tilt, defaults.target.tilt orelse 0.0),
    };

    cfg.optimizer = .{
        .min_f = optAt(opts, .loss_min_f, defaults.optimizer.min_f),
        .max_f = optAt(opts, .loss_max_f, defaults.optimizer.max_f),
        .flatten_f = optAt(opts, .loss_flatten_f, defaults.optimizer.flatten_f),
        .sharpness_penalty = optFlag(
            opts,
            .sharpness_penalty,
            defaults.optimizer.sharpness_penalty,
        ),
    };
    if (cfg.optimizer.min_f > cfg.optimizer.max_f) {
        std.mem.swap(f64, &cfg.optimizer.min_f, &cfg.optimizer.max_f);
    }

    cfg.peaking_limits = limitsFrom(opts, defaults.peaking_limits, .peaking_min_fc);
    cfg.shelf_limits = limitsFrom(opts, defaults.shelf_limits, .shelf_min_fc);

    cfg.stop = .{
        .target_loss = optOrNull(opts, .target_loss),
        .min_std = optOrNull(opts, .min_std),
        .solver = .{
            .max_iterations = optCount(opts, .max_iterations, 0),
            .max_evaluations = optCount(opts, .max_evaluations, 0),
        },
    };
    const solver_defaults = lbfgs.Options{};
    if (cfg.stop.solver.max_iterations == 0) {
        cfg.stop.solver.max_iterations = solver_defaults.max_iterations;
    }
    if (cfg.stop.solver.max_evaluations == 0) {
        cfg.stop.solver.max_evaluations = solver_defaults.max_evaluations;
    }
    return cfg;
}

fn optOrNull(opts: []const f64, which: Opt) ?f64 {
    const i = @intFromEnum(which);
    if (i >= opts.len) return null;
    const v = opts[i];
    return if (math.isNan(v)) null else v;
}

/// The six limits sit in a fixed order starting at `first`, which is why the
/// two blocks in `Opt` are laid out identically.
fn limitsFrom(opts: []const f64, fallback: peq.Limits, first: Opt) peq.Limits {
    const base = @intFromEnum(first);
    const at = struct {
        fn get(o: []const f64, ix: usize, d: f64) f64 {
            if (ix >= o.len) return d;
            const v = o[ix];
            return if (math.isNan(v)) d else v;
        }
    }.get;
    var out = peq.Limits{
        .min_fc = at(opts, base + 0, fallback.min_fc),
        .max_fc = at(opts, base + 1, fallback.max_fc),
        .min_q = at(opts, base + 2, fallback.min_q),
        .max_q = at(opts, base + 3, fallback.max_q),
        .min_gain = at(opts, base + 4, fallback.min_gain),
        .max_gain = at(opts, base + 5, fallback.max_gain),
    };
    // A host that hands over an inverted or degenerate box would send the
    // solver into a bound it can never satisfy, so order them here instead.
    if (out.min_fc > out.max_fc) std.mem.swap(f64, &out.min_fc, &out.max_fc);
    if (out.min_q > out.max_q) std.mem.swap(f64, &out.min_q, &out.max_q);
    if (out.min_gain > out.max_gain) std.mem.swap(f64, &out.min_gain, &out.max_gain);
    return out;
}

// ---------------------------------------------------------------------------
// The filter descriptor
// ---------------------------------------------------------------------------

/// `teq_run_config`'s second vector: the filter banks to fit, spelled out.
/// It exists because a filter bank is not a scalar and the positional option
/// vector has nowhere to put one.
///
///     [ n_banks,
///       bank 0: n_filters, min_f, max_f, min_std,     <- `bank_slots` each
///       bank 1: ...,
///       ...,
///       filter 0: kind, fc, q, gain,                  <- `filter_slots` each
///                 min_fc, max_fc, min_q, max_q, min_gain, max_gain,
///       filter 1: ... ]
///
/// Filters run in bank order and are split by the counts in the headers.
/// `kind` is the same code `kindCode` writes back. Every other slot is
/// optional and NaN means "not given", which is upstream's "key absent":
/// a supplied `fc`, `q` or `gain` pins that parameter, and a missing bound
/// falls back to the global default for the filter's type. That is
/// `configs.Spec`, and `configs.fromSpec` is what resolves it, so the rules
/// here are the rules `PEQ_CONFIGS` is written in.
///
/// `teq_config_len` sizes the buffer so the host does not hold a second copy
/// of these constants.
const bank_slots = 4;
const filter_slots = 10;

const BankIx = enum(usize) { filter_count = 0, min_f = 1, max_f = 2, min_std = 3 };
const FilterIx = enum(usize) {
    kind = 0,
    fc = 1,
    q = 2,
    gain = 3,
    min_fc = 4,
    max_fc = 5,
    min_q = 6,
    max_q = 7,
    min_gain = 8,
    max_gain = 9,
};

const ConfigError = error{BadConfig} || std.mem.Allocator.Error;

fn slotOrNull(row: []const f64, which: anytype) ?f64 {
    const v = row[@intFromEnum(which)];
    return if (math.isNan(v)) null else v;
}

/// A non-negative, finite count. Anything else is a malformed descriptor
/// rather than something to clamp.
fn countAt(v: f64) ConfigError!usize {
    if (!math.isFinite(v) or v < 0.0) return error.BadConfig;
    return @intFromFloat(@floor(v));
}

fn kindFrom(code: f64) ConfigError!peq.Kind {
    if (!math.isFinite(code)) return error.BadConfig;
    return switch (@as(i64, @intFromFloat(@floor(code)))) {
        0 => .peaking,
        1 => .low_shelf,
        2 => .high_shelf,
        else => error.BadConfig,
    };
}

fn banksFrom(allocator: std.mem.Allocator, spec: []const f64) ConfigError![]configs.Bank {
    if (spec.len < 1) return error.BadConfig;
    const n_banks = try countAt(spec[0]);
    if (n_banks == 0) return error.BadConfig;
    if (spec.len < 1 + n_banks * bank_slots) return error.BadConfig;

    const banks = try allocator.alloc(configs.Bank, n_banks);
    var n_filters: usize = 0;
    for (banks, 0..) |*bank, i| {
        const row = spec[1 + i * bank_slots ..][0..bank_slots];
        const count = try countAt(row[@intFromEnum(BankIx.filter_count)]);
        if (count == 0) return error.BadConfig;
        n_filters += count;
        // `filters` is patched below, once the total is known and the rest of
        // the descriptor has been checked to hold it.
        bank.* = .{
            .name = "",
            .filters = &.{},
            .optimizer = null,
            .min_std = slotOrNull(row, BankIx.min_std),
        };
        const min_f = slotOrNull(row, BankIx.min_f);
        const max_f = slotOrNull(row, BankIx.max_f);
        if (min_f != null or max_f != null) {
            const d = peq.Options{};
            var opt = peq.Options{ .min_f = min_f orelse d.min_f, .max_f = max_f orelse d.max_f };
            if (opt.min_f > opt.max_f) std.mem.swap(f64, &opt.min_f, &opt.max_f);
            bank.optimizer = opt;
        }
    }

    const filters_at = 1 + n_banks * bank_slots;
    if (spec.len < filters_at + n_filters * filter_slots) return error.BadConfig;

    const filters = try allocator.alloc(peq.Filter, n_filters);
    for (filters, 0..) |*filt, i| {
        const row = spec[filters_at + i * filter_slots ..][0..filter_slots];
        filt.* = configs.fromSpec(.{
            .kind = try kindFrom(row[@intFromEnum(FilterIx.kind)]),
            .fc = slotOrNull(row, FilterIx.fc),
            .q = slotOrNull(row, FilterIx.q),
            .gain = slotOrNull(row, FilterIx.gain),
            .min_fc = slotOrNull(row, FilterIx.min_fc),
            .max_fc = slotOrNull(row, FilterIx.max_fc),
            .min_q = slotOrNull(row, FilterIx.min_q),
            .max_q = slotOrNull(row, FilterIx.max_q),
            .min_gain = slotOrNull(row, FilterIx.min_gain),
            .max_gain = slotOrNull(row, FilterIx.max_gain),
        });
        // An inverted box is the host's typo, not a solver input.
        const lim = &filt.limits;
        if (lim.min_fc > lim.max_fc) std.mem.swap(f64, &lim.min_fc, &lim.max_fc);
        if (lim.min_q > lim.max_q) std.mem.swap(f64, &lim.min_q, &lim.max_q);
        if (lim.min_gain > lim.max_gain) std.mem.swap(f64, &lim.min_gain, &lim.max_gain);
    }

    var at: usize = 0;
    for (banks, 0..) |*bank, i| {
        const count = try countAt(spec[1 + i * bank_slots + @intFromEnum(BankIx.filter_count)]);
        bank.filters = filters[at..][0..count];
        at += count;
    }
    return banks;
}

// ---------------------------------------------------------------------------
// The result vector
// ---------------------------------------------------------------------------

/// Header slots, then four per filter.
const out_header = 8;
const out_per_filter = 4;

const OutIx = enum(usize) {
    filter_count = 0,
    loss = 1,
    rmse = 2,
    /// The largest boost the cascade applies. Negate it for a preamp.
    max_gain = 3,
    /// `-max(0, max_gain)`, which is what upstream writes as `Preamp:`.
    preamp = 4,
    iterations = 5,
    evaluations = 6,
    /// See `statusCode`.
    status = 7,
};

fn statusCode(status: lbfgs.Status) f64 {
    return switch (status) {
        .gradient_tolerance => 0,
        .function_tolerance => 1,
        .max_iterations => 2,
        .max_evaluations => 3,
        .line_search => 4,
        .early_stop => 5,
    };
}

fn kindCode(kind: peq.Kind) f64 {
    return switch (kind) {
        .peaking => 0,
        .low_shelf => 1,
        .high_shelf => 2,
    };
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

/// Bumped whenever the meaning of a slot in `Opt` or `OutIx` changes, which
/// appending to either does not. The host refuses to load a module whose
/// version it does not know.
export fn teq_abi_version() u32 {
    return 1;
}

/// How many `f64` slots a result with `n_filters` bands occupies. The host
/// sizes its output buffer with this rather than with a copy of the layout.
export fn teq_output_len(n_filters: u32) u32 {
    return out_header + n_filters * out_per_filter;
}

/// How many `f64` slots a descriptor for `n_banks` banks holding
/// `n_filters` filters in total occupies. The host sizes its buffer with
/// this rather than with a copy of the layout.
export fn teq_config_len(n_banks: u32, n_filters: u32) u32 {
    return 1 + n_banks * bank_slots + n_filters * filter_slots;
}

/// The six bounds `global_filter_defaults` gives filter kind `kind`, in the
/// order `FilterIx` puts them: min_fc, max_fc, min_q, max_q, min_gain,
/// max_gain. A host narrowing a device profile to AutoEq's defaults reads
/// them here rather than hard-coding six more numbers.
export fn teq_default_limits(kind: u32, out: [*]f64, out_cap: u32) i32 {
    if (out_cap < 6) return err_output_too_small;
    const k = kindFrom(@floatFromInt(kind)) catch return err_bad_config;
    const lim = configs.defaultLimits(k);
    out[0] = lim.min_fc;
    out[1] = lim.max_fc;
    out[2] = lim.min_q;
    out[3] = lim.max_q;
    out[4] = lim.min_gain;
    out[5] = lim.max_gain;
    return 6;
}

export fn teq_heap_size() u32 {
    return heap_size;
}

/// High-water mark since the last `teq_reset`, in bytes. Diagnostic only.
export fn teq_heap_used() u32 {
    return @intCast(@max(high_water, fba.end_index));
}

/// Release everything, including the host's own buffers. Every pointer
/// `teq_alloc` has returned is dangling afterwards.
export fn teq_reset() void {
    fba.reset();
    high_water = 0;
}

/// `len` bytes, 8-byte aligned so the host can view the result as an
/// `Float64Array`. Null — which reaches JavaScript as the offset 0 — means
/// the arena is exhausted.
export fn teq_alloc(len: u32) ?[*]u8 {
    const slice = fba.allocator().alignedAlloc(u8, .@"8", len) catch return null;
    high_water = @max(high_water, fba.end_index);
    return slice.ptr;
}

/// Fit a parametric EQ. Curves are interleaved `[f0, db0, f1, db1, ...]`
/// pairs, so `src_len` and `tgt_len` count *points*, not `f64`s.
///
/// Returns the number of `f64` slots written to `out`, or one of the
/// negative error codes above. Nothing is written on an error.
export fn teq_run(
    src: [*]const f64,
    src_len: u32,
    tgt: [*]const f64,
    tgt_len: u32,
    opts: [*]const f64,
    opts_len: u32,
    out: [*]f64,
    out_cap: u32,
) i32 {
    return runInto(src, src_len, tgt, tgt_len, opts, opts_len, null, 0, null, 0, out, out_cap);
}

/// `teq_run` with the filter banks spelled out, which is what upstream's
/// `PEQ.from_dict` over a list of configs amounts to: per-filter bounds,
/// per-filter pinning of fc, Q or gain, and a cascade where each bank fits
/// what the last one left. `spec` is the vector documented above.
///
/// This is a second export rather than a change to `teq_run` because the
/// latter's signature is full and a filter bank is not a scalar. Adding one
/// keeps the append-only rule at the function level too — a host built
/// against an older module simply never calls it — so `teq_abi_version`
/// stays where it is.
///
/// `peaking`, `shelves` and the two limit blocks in `opts` are ignored here:
/// the descriptor says all of it. Every other option still applies.
///
/// `sig` is the optional `sound_signature`, interleaved like the other two
/// curves; pass a zero `sig_len` for none. It lives here rather than on
/// `teq_run` because that signature is full and a curve is not a scalar —
/// a caller wanting only a signature passes one bank and nothing else.
export fn teq_run_config(
    src: [*]const f64,
    src_len: u32,
    tgt: [*]const f64,
    tgt_len: u32,
    opts: [*]const f64,
    opts_len: u32,
    spec: [*]const f64,
    spec_len: u32,
    sig: [*]const f64,
    sig_len: u32,
    out: [*]f64,
    out_cap: u32,
) i32 {
    if (spec_len == 0) return err_bad_config;
    // The exported pointer is not optional — a host with no signature has to
    // pass something — so the length is the only thing that can say "none".
    const signature: ?[*]const f64 = if (sig_len == 0) null else sig;
    return runInto(
        src,
        src_len,
        tgt,
        tgt_len,
        opts,
        opts_len,
        spec,
        spec_len,
        signature,
        sig_len,
        out,
        out_cap,
    );
}

fn runInto(
    src: [*]const f64,
    src_len: u32,
    tgt: [*]const f64,
    tgt_len: u32,
    opts: [*]const f64,
    opts_len: u32,
    spec: ?[*]const f64,
    spec_len: u32,
    sig: ?[*]const f64,
    sig_len: u32,
    out: [*]f64,
    out_cap: u32,
) i32 {
    if (src_len == 0 or tgt_len == 0 or out_cap < out_header) return err_bad_args;

    // Working memory sits above whatever the host allocated, and the mark
    // goes back on the way out. Repeated runs therefore cost one arena's
    // worth between them, not one per run.
    const mark = fba.end_index;
    defer {
        high_water = @max(high_water, fba.end_index);
        fba.end_index = mark;
    }
    const allocator = fba.allocator();

    const src_pairs = src[0 .. @as(usize, src_len) * 2];
    const tgt_pairs = tgt[0 .. @as(usize, tgt_len) * 2];
    const options = opts[0..@min(@as(usize, opts_len), Opt.count)];

    const src_f = allocator.alloc(f64, src_len) catch return err_out_of_memory;
    const src_db = allocator.alloc(f64, src_len) catch return err_out_of_memory;
    deinterleave(src_pairs, src_f, src_db);

    const tgt_f = allocator.alloc(f64, tgt_len) catch return err_out_of_memory;
    const tgt_db = allocator.alloc(f64, tgt_len) catch return err_out_of_memory;
    deinterleave(tgt_pairs, tgt_f, tgt_db);

    var cfg = configFrom(options);

    if (sig) |ptr| {
        const sig_f = allocator.alloc(f64, sig_len) catch return err_out_of_memory;
        const sig_db = allocator.alloc(f64, sig_len) catch return err_out_of_memory;
        deinterleave(ptr[0 .. @as(usize, sig_len) * 2], sig_f, sig_db);
        cfg.sound_signature = .{ .f = sig_f, .db = sig_db };
        cfg.sound_signature_smoothing_window_size =
            optOrNull(options, .sound_signature_smoothing);
    }

    if (spec) |ptr| {
        cfg.banks = banksFrom(allocator, ptr[0..spec_len]) catch |e| return switch (e) {
            error.OutOfMemory => err_out_of_memory,
            error.BadConfig => err_bad_config,
        };
    }

    var result = pipeline.run(allocator, src_f, src_db, tgt_f, tgt_db, cfg) catch |e| {
        return switch (e) {
            error.OutOfMemory => err_out_of_memory,
            error.BadCurve => err_bad_curve,
            error.NoBands => err_no_bands,
            error.GainRangeNeedsFixedFc => err_gain_range_fc,
            error.BadSmoothingWindow => err_bad_smoothing_window,
        };
    };
    defer result.deinit();

    const needed = out_header + result.filters.len * out_per_filter;
    if (needed > out_cap) return err_output_too_small;

    const slots = out[0..needed];
    slots[@intFromEnum(OutIx.filter_count)] = @floatFromInt(result.filters.len);
    slots[@intFromEnum(OutIx.loss)] = result.loss;
    slots[@intFromEnum(OutIx.rmse)] = result.rmse;
    slots[@intFromEnum(OutIx.max_gain)] = result.max_gain;
    slots[@intFromEnum(OutIx.preamp)] = -@max(0.0, result.max_gain);
    slots[@intFromEnum(OutIx.iterations)] = @floatFromInt(result.iterations);
    slots[@intFromEnum(OutIx.evaluations)] = @floatFromInt(result.evaluations);
    slots[@intFromEnum(OutIx.status)] = statusCode(result.status);

    for (result.filters, 0..) |filt, i| {
        const at = out_header + i * out_per_filter;
        slots[at + 0] = kindCode(filt.kind);
        slots[at + 1] = filt.fc;
        slots[at + 2] = filt.q;
        slots[at + 3] = filt.gain;
    }
    return @intCast(needed);
}

fn deinterleave(pairs: []const f64, out_f: []f64, out_db: []f64) void {
    for (out_f, out_db, 0..) |*fv, *dv, i| {
        fv.* = pairs[i * 2];
        dv.* = pairs[i * 2 + 1];
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// `teq_alloc` as the host uses it, viewed as f64 slots.
fn allocSlots(n: usize) ![*]f64 {
    const raw = teq_alloc(@intCast(n * @sizeOf(f64))) orelse return error.OutOfMemory;
    return @ptrCast(@alignCast(raw));
}

test "the ABI round-trips a curve the way the host drives it" {
    teq_reset();
    defer teq_reset();

    const n = 200;
    const src = try allocSlots(n * 2);
    try testing.expect(@intFromPtr(src) != 0);
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
        const f = math.pow(f64, 10.0, math.log10(20.0) + t * 3.0);
        const u = (math.log10(f) - math.log10(3000.0)) / 0.15;
        src[i * 2] = f;
        src[i * 2 + 1] = 8.0 * @exp(-u * u);
    }

    const tgt = try allocSlots(2 * 2);
    tgt[0] = 20.0;
    tgt[1] = 0.0;
    tgt[2] = 20000.0;
    tgt[3] = 0.0;

    const opts = try allocSlots(Opt.count);
    for (0..Opt.count) |i| opts[i] = math.nan(f64);
    opts[@intFromEnum(Opt.peaking)] = 6;
    opts[@intFromEnum(Opt.shelves)] = 1;

    const cap = teq_output_len(8);
    const out = try allocSlots(cap);

    const written = teq_run(src, n, tgt, 2, opts, Opt.count, out, cap);
    try testing.expectEqual(@as(i32, @intCast(cap)), written);
    try testing.expectEqual(@as(f64, 8), out[@intFromEnum(OutIx.filter_count)]);
    try testing.expectEqual(@as(f64, 1), out[out_header + 0]); // low shelf first
    try testing.expectEqual(@as(f64, 2), out[out_header + out_per_filter]); // then high

    // Some peaking band has to be cutting the 3 kHz bump.
    var found = false;
    for (2..8) |i| {
        const at = out_header + i * out_per_filter;
        if (out[at + 1] > 2000.0 and out[at + 1] < 4500.0 and out[at + 3] < -3.0) found = true;
    }
    try testing.expect(found);
    try testing.expect(out[@intFromEnum(OutIx.rmse)] > 0.0);
    try testing.expect(teq_heap_used() < heap_size);
}

test "a second run does not grow the arena" {
    teq_reset();
    defer teq_reset();

    const n = 64;
    const src = try allocSlots(n * 2);
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
        src[i * 2] = math.pow(f64, 10.0, math.log10(20.0) + t * 3.0);
        src[i * 2 + 1] = 2.0 * t;
    }
    const tgt = try allocSlots(2 * 2);
    tgt[0] = 20.0;
    tgt[1] = 0.0;
    tgt[2] = 20000.0;
    tgt[3] = 0.0;
    const opts = try allocSlots(8);
    opts[0] = 44100.0;
    const cap = teq_output_len(6);
    const out = try allocSlots(cap);

    const first = teq_run(src, n, tgt, 2, opts, 1, out, cap);
    try testing.expect(first < 0 or first > 0);
    const after_first = fba.end_index;
    _ = teq_run(src, n, tgt, 2, opts, 1, out, cap);
    try testing.expectEqual(after_first, fba.end_index);
}

test "bad input is reported, not trapped" {
    teq_reset();
    defer teq_reset();

    const bad = try allocSlots(3 * 2);
    bad[0] = 100.0;
    bad[1] = 0.0;
    bad[2] = 100.0; // the same frequency twice, which is ambiguous
    bad[3] = 0.0;
    bad[4] = 200.0;
    bad[5] = 0.0;
    const tgt = try allocSlots(2 * 2);
    tgt[0] = 20.0;
    tgt[1] = 0.0;
    tgt[2] = 20000.0;
    tgt[3] = 0.0;
    const opts = try allocSlots(Opt.count);
    for (0..Opt.count) |i| opts[i] = math.nan(f64);
    opts[@intFromEnum(Opt.peaking)] = 2;
    const cap = teq_output_len(4);
    const out = try allocSlots(cap);

    try testing.expectEqual(err_bad_curve, teq_run(bad, 3, tgt, 2, opts, Opt.count, out, cap));
    try testing.expectEqual(err_bad_args, teq_run(bad, 0, tgt, 2, opts, Opt.count, out, cap));

    // A capacity too small for the bands asked for is caught on a curve that
    // is otherwise fine, so the code reported is the one under test.
    const ok = try allocSlots(2 * 2);
    ok[0] = 20.0;
    ok[1] = 3.0;
    ok[2] = 20000.0;
    ok[3] = -3.0;
    try testing.expectEqual(
        err_output_too_small,
        teq_run(ok, 2, tgt, 2, opts, Opt.count, out, out_header),
    );
    try testing.expect(teq_run(ok, 2, tgt, 2, opts, Opt.count, out, cap) > 0);
}

test "an option slot left NaN takes the default" {
    var opts: [Opt.count]f64 = @splat(math.nan(f64));
    const cfg = configFrom(&opts);
    const defaults = pipeline.Config{};
    try testing.expectEqual(defaults.fs, cfg.fs);
    try testing.expectEqual(defaults.peaking, cfg.peaking);
    try testing.expectEqual(defaults.shelves, cfg.shelves);
    try testing.expectEqual(defaults.equalization.max_gain, cfg.equalization.max_gain);
    try testing.expectEqual(defaults.peaking_limits.max_q, cfg.peaking_limits.max_q);
    try testing.expectEqual(@as(?f64, null), cfg.stop.min_std);

    // A short vector is the same as a vector of NaN.
    const empty: [0]f64 = .{};
    const short = configFrom(&empty);
    try testing.expectEqual(defaults.fs, short.fs);
    try testing.expectEqual(defaults.peaking_limits.min_fc, short.peaking_limits.min_fc);
}

test "an inverted bound is ordered rather than handed to the solver" {
    var opts: [Opt.count]f64 = @splat(math.nan(f64));
    opts[@intFromEnum(Opt.peaking_min_q)] = 6.0;
    opts[@intFromEnum(Opt.peaking_max_q)] = 0.5;
    const cfg = configFrom(&opts);
    try testing.expectEqual(@as(f64, 0.5), cfg.peaking_limits.min_q);
    try testing.expectEqual(@as(f64, 6.0), cfg.peaking_limits.max_q);
}

/// The curve, target and option buffers every descriptor test starts from.
/// Options are all-NaN, so each one takes turboEQ's default.
fn descriptorFixture(n: usize) !struct { src: [*]f64, tgt: [*]f64, opts: [*]f64 } {
    const src = try allocSlots(n * 2);
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
        const f = math.pow(f64, 10.0, math.log10(20.0) + t * 3.0);
        const u = (math.log10(f) - math.log10(3000.0)) / 0.15;
        src[i * 2] = f;
        src[i * 2 + 1] = 8.0 * @exp(-u * u);
    }
    const tgt = try allocSlots(2 * 2);
    tgt[0] = 20.0;
    tgt[1] = 0.0;
    tgt[2] = 20000.0;
    tgt[3] = 0.0;
    const opts = try allocSlots(Opt.count);
    for (0..Opt.count) |i| opts[i] = math.nan(f64);
    return .{ .src = src, .tgt = tgt, .opts = opts };
}

fn writeFilter(spec: [*]f64, at: usize, kind: f64, fields: anytype) void {
    for (0..filter_slots) |k| spec[at + k] = math.nan(f64);
    spec[at + @intFromEnum(FilterIx.kind)] = kind;
    inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
        spec[at + @intFromEnum(@field(FilterIx, field.name))] = @field(fields, field.name);
    }
}

test "a descriptor pins what it supplies and frees what it does not" {
    teq_reset();
    defer teq_reset();

    const n = 200;
    const fix = try descriptorFixture(n);

    // One bank: a pinned low shelf, then two peaking bands held to a narrow
    // Q window. This is a device preset in miniature.
    const cap = teq_config_len(1, 3);
    try testing.expectEqual(@as(u32, 1 + bank_slots + 3 * filter_slots), cap);
    const spec = try allocSlots(cap);
    for (0..cap) |i| spec[i] = math.nan(f64);
    spec[0] = 1;
    spec[1 + @intFromEnum(BankIx.filter_count)] = 3;

    const base = 1 + bank_slots;
    writeFilter(spec, base, 1, .{ .fc = 105.0, .q = 0.7 });
    writeFilter(spec, base + filter_slots, 0, .{ .min_q = 2.0, .max_q = 2.5 });
    writeFilter(spec, base + 2 * filter_slots, 0, .{ .min_q = 2.0, .max_q = 2.5 });

    const out_cap = teq_output_len(3);
    const out = try allocSlots(out_cap);
    const written = teq_run_config(fix.src, n, fix.tgt, 2, fix.opts, Opt.count, spec, cap, undefined, 0, out, out_cap);
    try testing.expectEqual(@as(i32, @intCast(out_cap)), written);
    try testing.expectEqual(@as(f64, 3), out[@intFromEnum(OutIx.filter_count)]);

    // The shelf kept both of its pinned parameters.
    try testing.expectEqual(@as(f64, 1), out[out_header + 0]);
    try testing.expectEqual(@as(f64, 105.0), out[out_header + 1]);
    try testing.expectEqual(@as(f64, 0.7), out[out_header + 2]);

    // The peaking bands stayed inside the Q window and moved in fc, which
    // the descriptor left free.
    for (1..3) |i| {
        const at = out_header + i * out_per_filter;
        try testing.expectEqual(@as(f64, 0), out[at + 0]);
        try testing.expect(out[at + 2] >= 2.0 - 1e-9 and out[at + 2] <= 2.5 + 1e-9);
        try testing.expect(out[at + 1] >= 20.0 and out[at + 1] <= 10000.0);
    }
}

test "a two bank descriptor cascades and returns both banks' filters" {
    teq_reset();
    defer teq_reset();

    const n = 200;
    const fix = try descriptorFixture(n);

    // Two banks of two free peaking bands each.
    const cap = teq_config_len(2, 4);
    const spec = try allocSlots(cap);
    for (0..cap) |i| spec[i] = math.nan(f64);
    spec[0] = 2;
    spec[1 + @intFromEnum(BankIx.filter_count)] = 2;
    // The first bank is scored to 10 kHz only, the way
    // `4_PEAKING_WITH_LOW_SHELF` is.
    spec[1 + @intFromEnum(BankIx.max_f)] = 10000.0;
    spec[1 + bank_slots + @intFromEnum(BankIx.filter_count)] = 2;

    const base = 1 + 2 * bank_slots;
    for (0..4) |i| writeFilter(spec, base + i * filter_slots, 0, .{});

    const out_cap = teq_output_len(4);
    const out = try allocSlots(out_cap);
    const written = teq_run_config(fix.src, n, fix.tgt, 2, fix.opts, Opt.count, spec, cap, undefined, 0, out, out_cap);
    try testing.expectEqual(@as(i32, @intCast(out_cap)), written);
    try testing.expectEqual(@as(f64, 4), out[@intFromEnum(OutIx.filter_count)]);

    // Four bands fitted in two passes beat the first pass alone.
    const half_cap = teq_config_len(1, 2);
    const half = try allocSlots(half_cap);
    for (0..half_cap) |i| half[i] = math.nan(f64);
    half[0] = 1;
    half[1 + @intFromEnum(BankIx.filter_count)] = 2;
    half[1 + @intFromEnum(BankIx.max_f)] = 10000.0;
    for (0..2) |i| writeFilter(half, 1 + bank_slots + i * filter_slots, 0, .{});

    const half_out_cap = teq_output_len(2);
    const half_out = try allocSlots(half_out_cap);
    _ = teq_run_config(
        fix.src,
        n,
        fix.tgt,
        2,
        fix.opts,
        Opt.count,
        half,
        half_cap,
        undefined,
        0,
        half_out,
        half_out_cap,
    );
    try testing.expect(out[@intFromEnum(OutIx.rmse)] < half_out[@intFromEnum(OutIx.rmse)]);
}

test "a malformed descriptor is reported, not trapped" {
    teq_reset();
    defer teq_reset();

    const n = 64;
    const fix = try descriptorFixture(n);
    const out_cap = teq_output_len(4);
    const out = try allocSlots(out_cap);

    const cap = teq_config_len(1, 1);
    const spec = try allocSlots(cap);

    const run = struct {
        fn go(f: anytype, sp: [*]f64, c: u32, o: [*]f64, oc: u32, points: u32) i32 {
            return teq_run_config(f.src, points, f.tgt, 2, f.opts, Opt.count, sp, c, undefined, 0, o, oc);
        }
    }.go;

    // No banks at all.
    for (0..cap) |i| spec[i] = math.nan(f64);
    spec[0] = 0;
    try testing.expectEqual(err_bad_config, run(fix, spec, cap, out, out_cap, n));

    // A bank count that is not a number.
    spec[0] = math.nan(f64);
    try testing.expectEqual(err_bad_config, run(fix, spec, cap, out, out_cap, n));

    // A bank claiming more filters than the descriptor carries.
    spec[0] = 1;
    spec[1 + @intFromEnum(BankIx.filter_count)] = 9;
    try testing.expectEqual(err_bad_config, run(fix, spec, cap, out, out_cap, n));

    // An unknown filter kind.
    spec[1 + @intFromEnum(BankIx.filter_count)] = 1;
    writeFilter(spec, 1 + bank_slots, 7, .{});
    try testing.expectEqual(err_bad_config, run(fix, spec, cap, out, out_cap, n));

    // A zero-length descriptor never reaches the parser.
    try testing.expectEqual(err_bad_config, run(fix, spec, 0, out, out_cap, n));

    // And a well-formed one still works afterwards, so nothing was corrupted.
    writeFilter(spec, 1 + bank_slots, 0, .{});
    try testing.expectEqual(@as(i32, @intCast(teq_output_len(1))), run(fix, spec, cap, out, teq_output_len(1), n));
}

test "the new option slots reach the perceptual stage" {
    teq_reset();
    defer teq_reset();

    const n = 200;
    const fix = try descriptorFixture(n);
    // The default bank is 8 peaking bands plus the two shelves.
    const cap = teq_output_len(10);
    const out = try allocSlots(cap);

    const baseline = teq_run(fix.src, n, fix.tgt, 2, fix.opts, Opt.count, out, cap);
    try testing.expect(baseline > 0);
    const baseline_rmse = out[@intFromEnum(OutIx.rmse)];

    // Smoothing the whole axis at two octaves flattens the bump the fit was
    // chasing, so the equalization it lands on differs.
    fix.opts[@intFromEnum(Opt.window_size)] = 2.0;
    try testing.expect(teq_run(fix.src, n, fix.tgt, 2, fix.opts, Opt.count, out, cap) > 0);
    try testing.expect(out[@intFromEnum(OutIx.rmse)] != baseline_rmse);

    // An inverted transition band would assert inside `smoothen`; it is
    // replaced rather than passed through.
    fix.opts[@intFromEnum(Opt.window_size)] = math.nan(f64);
    fix.opts[@intFromEnum(Opt.treble_f_lower)] = 9000.0;
    fix.opts[@intFromEnum(Opt.treble_f_upper)] = 1000.0;
    try testing.expect(teq_run(fix.src, n, fix.tgt, 2, fix.opts, Opt.count, out, cap) > 0);
    try testing.expectApproxEqAbs(baseline_rmse, out[@intFromEnum(OutIx.rmse)], 1e-12);
}

test "a sound signature reaches the target through the descriptor export" {
    teq_reset();
    defer teq_reset();

    const n = 200;
    const fix = try descriptorFixture(n);

    const cap = teq_config_len(1, 4);
    const spec = try allocSlots(cap);
    for (0..cap) |i| spec[i] = math.nan(f64);
    spec[0] = 1;
    spec[1 + @intFromEnum(BankIx.filter_count)] = 4;
    for (0..4) |i| writeFilter(spec, 1 + bank_slots + i * filter_slots, 0, .{});

    const out_cap = teq_output_len(4);
    const out = try allocSlots(out_cap);

    // No signature: a zero length is how the host says "none", whatever the
    // pointer holds.
    var written = teq_run_config(
        fix.src,
        n,
        fix.tgt,
        2,
        fix.opts,
        Opt.count,
        spec,
        cap,
        undefined,
        0,
        out,
        out_cap,
    );
    try testing.expect(written > 0);
    const plain_rmse = out[@intFromEnum(OutIx.rmse)];

    // A signature asking for 4 dB more above 5 kHz moves the fit.
    const sig = try allocSlots(3 * 2);
    sig[0] = 20.0;
    sig[1] = 0.0;
    sig[2] = 5000.0;
    sig[3] = 0.0;
    sig[4] = 20000.0;
    sig[5] = 4.0;

    written = teq_run_config(
        fix.src,
        n,
        fix.tgt,
        2,
        fix.opts,
        Opt.count,
        spec,
        cap,
        sig,
        3,
        out,
        out_cap,
    );
    try testing.expect(written > 0);
    try testing.expect(out[@intFromEnum(OutIx.rmse)] != plain_rmse);

    // And the smoothing slot is read rather than ignored.
    fix.opts[@intFromEnum(Opt.sound_signature_smoothing)] = 1.0;
    const unsmoothed = out[@intFromEnum(OutIx.rmse)];
    written = teq_run_config(
        fix.src,
        n,
        fix.tgt,
        2,
        fix.opts,
        Opt.count,
        spec,
        cap,
        sig,
        3,
        out,
        out_cap,
    );
    try testing.expect(written > 0);
    try testing.expect(out[@intFromEnum(OutIx.rmse)] != unsmoothed);
}

test "the default limits are readable rather than transcribed" {
    teq_reset();
    defer teq_reset();

    const out = try allocSlots(6);
    try testing.expectEqual(@as(i32, 6), teq_default_limits(0, out, 6));
    try testing.expectEqual(peq.peaking_limits.min_q, out[2]);
    try testing.expectEqual(peq.peaking_limits.max_q, out[3]);

    try testing.expectEqual(@as(i32, 6), teq_default_limits(2, out, 6));
    try testing.expectEqual(peq.shelf_limits.max_q, out[3]);

    try testing.expectEqual(err_bad_config, teq_default_limits(9, out, 6));
    try testing.expectEqual(err_output_too_small, teq_default_limits(0, out, 5));
}
