//! The end-to-end entry point.
//!
//! `curve`, `equalize`, `peq` and `biquad` are each a faithful port of one
//! piece of upstream, which the parity harness drives individually. This file
//! is the piece upstream spells as `FrequencyResponse.process` followed by
//! `optimize_parametric_eq`: source curve and target curve in, parametric EQ
//! filters out, with nothing left for the caller to sequence.
//!
//! The order is upstream's and is not negotiable, because every stage
//! assumes the grid and the centring the one before it established:
//!
//!   1. `interpolate` the source onto the 1.01 grid, then `center` it.
//!   2. `interpolate` and `center` the target the same way, add the shelves
//!      and tilt `create_target` builds, and subtract to get the error.
//!   3. `equalize`: smooth, protect the dips, limit the slope, cap the gain.
//!   4. Resample the equalization onto the coarser 1.02 optimizer grid.
//!   5. Fit each filter bank to it in turn, subtracting what each one
//!      achieved before the next one starts.
//!
//! Step 5 is a loop because `_optimize_peq_filters` takes a *list* of
//! configs, not one. AutoEq's CLI default is two of them —
//! `4_PEAKING_WITH_LOW_SHELF` then `4_PEAKING_WITH_HIGH_SHELF` — and the
//! second fits the residual the first left. `Config.banks` is that list;
//! leaving it null fits a single bank, which is turboEQ's default.
//!
//! Step 4 is easy to miss reading upstream, because it happens inside
//! `_optimize_peq_filters` rather than in `process`. Fitting on the 1.01
//! grid instead is not wrong, just twice the work for no gain — the whole
//! point of the coarser axis is that the optimizer does not need the
//! resolution the perceptual stage does.
//!
//! Derived from AutoEq (MIT, Jaakko Pasanen), autoeq/frequency_response.py.

const std = @import("std");
const math = std.math;
const util = @import("util.zig");
const curve = @import("curve.zig");
const equalize = @import("equalize.zig");
const peq = @import("peq.zig");
const configs = @import("configs.zig");
const lbfgs = @import("lbfgs.zig");

pub const Config = struct {
    /// Upstream's `DEFAULT_FS`. A caller on a 48 kHz chain passes its own.
    fs: f64 = 44100.0,
    /// The shelves and tilt `create_target` adds on top of the target curve.
    /// All neutral by default, which makes the term exactly zero.
    target: curve.TargetOptions = .{},
    /// Shift the error by its own mean over 100 Hz to 10 kHz rather than
    /// pinning it at 1 kHz. Upstream's `min_mean_error`, and the default
    /// here; see CLAUDE.md on target alignment.
    min_mean_error: bool = true,
    /// The perceptual stage: gain cap, slope limit, dip protection.
    equalization: equalize.Options = .{},
    /// `DEFAULT_PREAMP`. Added to the equalization before the fit, so the
    /// filters absorb it rather than the caller.
    preamp: f64 = 0.0,

    /// `sound_signature`: a colouration added to the target curve, on its own
    /// frequency axis. Upstream takes it as a CSV of as few as two points and
    /// interpolates, so this need not be on any particular grid.
    sound_signature: ?Curve = null,
    /// `sound_signature_smoothing_window_size`, in octaves. Null or zero
    /// leaves the signature unsmoothed, which is upstream's default.
    sound_signature_smoothing_window_size: ?f64 = null,

    /// The filter banks to fit, in sequence. Each is fitted against the
    /// residual the one before it left, which is `_optimize_peq_filters`
    /// over a list of configs — AutoEq's CLI default is the two-bank
    /// cascade `configs.autoeq_cli_default`.
    ///
    /// Null builds the single bank `peaking` and `shelves` describe, which
    /// is turboEQ's default and upstream's `N_PEAKING_WITH_SHELVES`. When
    /// this is set, `peaking`, `shelves`, `peaking_limits` and
    /// `shelf_limits` are all ignored: the banks say everything.
    banks: ?[]const configs.Bank = null,
    /// Apply each bank's recorded upstream `min_std`. Off, because turboEQ
    /// runs to convergence; see `peq.StopRules`. A `stop.min_std` the caller
    /// set explicitly wins over the bank's either way.
    upstream_stop_rules: bool = false,

    /// `optimize_fixed_band_eq`'s `gain_range`, in dB. Replaces every
    /// filter's gain bounds with a window of this half-width centred on the
    /// equalization curve read at that filter's own `fc`, so a fixed band
    /// may only move a little either side of what the curve asks for there.
    ///
    /// Every filter must have its `fc` pinned, which is what "fixed band"
    /// means; upstream reads `filt['fc']` straight out of the config and
    /// raises when it is absent. `GainRangeNeedsFixedFc` is that raise.
    gain_range: ?f64 = null,

    /// Free peaking bands. The two shelves sit outside this count, the way
    /// `PEQ_CONFIGS['N_PEAKING_WITH_SHELVES']` does. Ignored when `banks` is
    /// set.
    peaking: usize = 8,
    /// Prepend a low shelf at 105 Hz and a high shelf at 10 kHz, both Q 0.7
    /// with gain the only free parameter. Every shipped upstream preset
    /// pins them exactly this way.
    shelves: bool = true,
    peaking_limits: peq.Limits = peq.peaking_limits,
    shelf_limits: peq.Limits = peq.shelf_limits,
    /// The band of the curve the loss is measured over,
    /// `DEFAULT_PEQ_OPTIMIZER_MIN_F` and `MAX_F`. Narrowing it is not the
    /// same as narrowing `peaking_limits`: those say where a band may sit,
    /// this says which error it is scored against. Its `flatten_f` applies to
    /// every bank, including one with its own band.
    optimizer: peq.Options = .{},
    stop: peq.StopRules = .{},
};

/// A curve on its own axis, for the inputs that arrive as one rather than as
/// a pair of slices. Ascending, positive and finite, same as any other.
pub const Curve = struct {
    f: []const f64,
    db: []const f64,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    /// Every fitted band, banks concatenated in fitting order. Owned here.
    filters: []peq.Filter,
    /// Where each bank starts in `filters`, with a final entry equal to
    /// `filters.len`, so bank `i` owns `filters[bank_offsets[i]..bank_offsets[i + 1]]`.
    /// A single-bank fit is `.{ 0, filters.len }`.
    bank_offsets: []usize,
    /// The 1.01 working grid and the equalization curve on it, which is what
    /// the perceptual stage produced and what a caller plots.
    f: []f64,
    equalization: []f64,
    /// The 1.02 optimizer grid and the curve actually fitted, which is the
    /// former resampled and offset by `preamp`.
    optimizer_f: []f64,
    optimizer_target: []f64,

    loss: f64,
    rmse: f64,
    max_gain: f64,
    iterations: usize,
    evaluations: usize,
    status: lbfgs.Status,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.filters);
        self.allocator.free(self.bank_offsets);
        self.allocator.free(self.f);
        self.allocator.free(self.equalization);
        self.allocator.free(self.optimizer_f);
        self.allocator.free(self.optimizer_target);
        self.* = undefined;
    }
};

pub const Error = error{
    /// Fewer than two points, a non-positive or non-finite frequency, a
    /// non-finite level, or the same frequency twice. A merely unsorted axis
    /// is not one of these — `prepareCurve` sorts it, as upstream does.
    BadCurve,
    /// No bands asked for, so there is nothing to fit.
    NoBands,
    /// `gain_range` was given alongside a filter whose `fc` is free.
    GainRangeNeedsFixedFc,
} || curve.SmoothenError || std.mem.Allocator.Error;

/// Build the filter bank `Config` describes. The caller owns it; `run` does
/// this itself and hands it back inside `Result`.
pub fn buildFilters(allocator: std.mem.Allocator, cfg: Config) ![]peq.Filter {
    const n_shelves: usize = if (cfg.shelves) 2 else 0;
    if (cfg.peaking + n_shelves == 0) return Error.NoBands;

    const out = try allocator.alloc(peq.Filter, cfg.peaking + n_shelves);
    errdefer allocator.free(out);
    if (cfg.shelves) {
        out[0] = .{
            .kind = .low_shelf,
            .fc = 105.0,
            .q = 0.7,
            .gain = 0,
            .optimize_fc = false,
            .optimize_q = false,
            .limits = cfg.shelf_limits,
        };
        out[1] = .{
            .kind = .high_shelf,
            .fc = 10000.0,
            .q = 0.7,
            .gain = 0,
            .optimize_fc = false,
            .optimize_q = false,
            .limits = cfg.shelf_limits,
        };
    }
    for (out[n_shelves..]) |*filt| {
        filt.* = .{ .kind = .peaking, .fc = 0, .q = 0, .gain = 0, .limits = cfg.peaking_limits };
    }
    return out;
}

/// Source and target are raw measurements on their own frequency axes; they
/// need not share one, and neither need be on upstream's grid.
pub fn run(
    allocator: std.mem.Allocator,
    source_f: []const f64,
    source_db: []const f64,
    target_f: []const f64,
    target_db: []const f64,
    cfg: Config,
) Error!Result {
    // Sorted if the caller handed them over out of order, borrowed if not.
    var source = try prepareCurve(allocator, source_f, source_db);
    defer source.deinit(allocator);
    var target = try prepareCurve(allocator, target_f, target_db);
    defer target.deinit(allocator);

    // 1. The 1.01 working grid, and the source resampled onto it and centred.
    const f = try curve.standardGrid(allocator);
    errdefer allocator.free(f);
    const raw = try allocator.alloc(f64, f.len);
    defer allocator.free(raw);
    try curve.interpolate(allocator, source.f, source.db, f, raw);
    _ = try curve.center(allocator, f, raw, 1000.0);

    // 2. Target through the same two steps, then the error curve.
    const target_raw = try allocator.alloc(f64, f.len);
    defer allocator.free(target_raw);
    try curve.prepareTarget(allocator, target.f, target.db, f, target_raw);

    // The sound signature rides on the target rather than the source, and is
    // interpolated but never centred; see `curve.CompensateOptions`.
    var signature: ?[]f64 = null;
    defer if (signature) |buf| allocator.free(buf);
    if (cfg.sound_signature) |given| {
        var sig = try prepareCurve(allocator, given.f, given.db);
        defer sig.deinit(allocator);
        const buf = try allocator.alloc(f64, f.len);
        signature = buf;
        try curve.prepareSoundSignature(
            allocator,
            sig.f,
            sig.db,
            f,
            cfg.sound_signature_smoothing_window_size,
            buf,
        );
    }

    const target_curve = try allocator.alloc(f64, f.len);
    defer allocator.free(target_curve);
    const error_curve = try allocator.alloc(f64, f.len);
    defer allocator.free(error_curve);
    curve.compensate(f, raw, target_raw, .{
        .target = cfg.target,
        .fs = cfg.fs,
        .min_mean_error = cfg.min_mean_error,
        .sound_signature = signature,
    }, target_curve, error_curve);

    // 3. The perceptual stage.
    var eq = try equalize.equalize(allocator, f, error_curve, cfg.equalization);
    defer eq.deinit();

    const equalization = try allocator.dupe(f64, eq.equalization);
    errdefer allocator.free(equalization);

    // 4. Onto the optimizer's coarser grid. `_optimize_peq_filters` adds the
    //    preamp before resampling; the two commute, and doing it here keeps
    //    `Result.equalization` the curve the perceptual stage produced.
    const optimizer_f = try util.generateFrequencies(
        allocator,
        curve.f_min,
        curve.f_max,
        curve.optimizer_f_step,
    );
    errdefer allocator.free(optimizer_f);
    const optimizer_target = try allocator.alloc(f64, optimizer_f.len);
    errdefer allocator.free(optimizer_target);
    try curve.interpolate(allocator, f, equalization, optimizer_f, optimizer_target);
    if (cfg.preamp != 0.0) {
        for (optimizer_target) |*v| v.* += cfg.preamp;
    }

    // 5. Fit, bank by bank. With one bank this is the single fit it always
    //    was; with several it is `_optimize_peq_filters` over a list of
    //    configs, each one fitted against what the last one left behind.
    var default_bank: [1]configs.Bank = undefined;
    var default_filters: []peq.Filter = &.{};
    defer allocator.free(default_filters);

    const banks: []const configs.Bank = if (cfg.banks) |given| given else blk: {
        default_filters = try buildFilters(allocator, cfg);
        default_bank[0] = .{ .name = "N_PEAKING_WITH_SHELVES", .filters = default_filters };
        break :blk default_bank[0..1];
    };

    var n_filters: usize = 0;
    for (banks) |bank| n_filters += bank.filters.len;
    if (n_filters == 0) return Error.NoBands;

    const filters = try allocator.alloc(peq.Filter, n_filters);
    errdefer allocator.free(filters);
    const bank_offsets = try allocator.alloc(usize, banks.len + 1);
    errdefer allocator.free(bank_offsets);

    // What is left to correct. Each bank's cascade response comes off it,
    // exactly as `fr.equalization -= peq.fr` does upstream.
    const residual = try allocator.dupe(f64, optimizer_target);
    defer allocator.free(residual);

    // `optimize_fixed_band_eq`'s gain window, one centre per filter in the
    // order the banks concatenate — upstream flattens every config's `fc`
    // the same way and interpolates once. It reads `self.equalization`, so
    // the centres come off the 1.01 grid before the preamp, not off
    // `optimizer_target`.
    var gain_centers: []f64 = &.{};
    defer allocator.free(gain_centers);
    if (cfg.gain_range != null) {
        const fcs = try allocator.alloc(f64, n_filters);
        defer allocator.free(fcs);
        var i: usize = 0;
        for (banks) |bank| for (bank.filters) |filt| {
            if (filt.optimize_fc) return Error.GainRangeNeedsFixedFc;
            fcs[i] = filt.fc;
            i += 1;
        };
        gain_centers = try allocator.alloc(f64, n_filters);
        try curve.interpolate(allocator, f, equalization, fcs, gain_centers);
    }

    var loss: f64 = 0;
    var iterations: usize = 0;
    var evaluations: usize = 0;
    var status: lbfgs.Status = .gradient_tolerance;

    var at: usize = 0;
    for (banks, 0..) |bank, bank_ix| {
        bank_offsets[bank_ix] = at;
        const slice = filters[at..][0..bank.filters.len];
        @memcpy(slice, bank.filters);
        if (cfg.gain_range) |range| {
            for (slice, gain_centers[at..][0..slice.len]) |*filt, centre| {
                filt.limits.min_gain = centre - range;
                filt.limits.max_gain = centre + range;
            }
        }
        at += slice.len;

        // A bank may narrow the loss band, but where the loss flattens and
        // whether it penalizes sharp bands are the caller's choice for the
        // whole run; no bank upstream records either.
        var opts = bank.optimizer orelse cfg.optimizer;
        opts.flatten_f = cfg.optimizer.flatten_f;
        opts.sharpness_penalty = cfg.optimizer.sharpness_penalty;
        var fit = try peq.Peq.init(allocator, optimizer_f, cfg.fs, slice, residual, opts);
        defer fit.deinit();

        fit.stop = cfg.stop;
        if (cfg.upstream_stop_rules and fit.stop.min_std == null) fit.stop.min_std = bank.min_std;

        const params = try allocator.alloc(f64, fit.paramCount());
        defer allocator.free(params);
        const bounds = try allocator.alloc(peq.Bound, params.len);
        defer allocator.free(bounds);

        try fit.initialParams(params);
        fit.bounds(bounds);
        const report = try fit.optimize(params, bounds);

        // `loss` and `status` describe the last bank, which for a single
        // bank is what they always described. The counts are totals.
        loss = report.loss;
        status = report.status;
        iterations += report.iterations;
        evaluations += report.evaluations;

        for (residual, fit.fr) |*r, v| r.* -= v;
    }
    bank_offsets[banks.len] = at;

    // `residual` is now the target minus every bank's response, so these two
    // describe the whole EQ rather than the last bank of it. With one bank
    // they are `fit.rmse()` and `fit.maxGain()` to the bit.
    var sq: f64 = 0;
    var max_gain = -math.inf(f64);
    for (residual, optimizer_target) |r, t| {
        sq += r * r;
        max_gain = @max(max_gain, t - r);
    }

    return .{
        .allocator = allocator,
        .filters = filters,
        .bank_offsets = bank_offsets,
        .f = f,
        .equalization = equalization,
        .optimizer_f = optimizer_f,
        .optimizer_target = optimizer_target,
        .loss = loss,
        .rmse = @sqrt(sq / @as(f64, @floatFromInt(residual.len))),
        .max_gain = max_gain,
        .iterations = iterations,
        .evaluations = evaluations,
        .status = status,
    };
}

/// Interpolation is linear in log10(f), so a zero or non-finite axis is not
/// something to discover halfway down the pipeline. Order is not checked
/// here: `prepareCurve` sorts, the way upstream does.
fn checkCurve(f: []const f64, db: []const f64) Error!void {
    if (f.len != db.len) return Error.BadCurve;
    if (f.len < 2) return Error.BadCurve;
    for (f, db) |v, d| {
        if (!math.isFinite(v) or v <= 0.0) return Error.BadCurve;
        if (!math.isFinite(d)) return Error.BadCurve;
    }
}

/// A curve ready for the pipeline: ascending, and owned here if sorting was
/// needed. The borrowed case allocates nothing, which is every well-formed
/// caller.
const Prepared = struct {
    f: []const f64,
    db: []const f64,
    owned_f: ?[]f64 = null,
    owned_db: ?[]f64 = null,

    fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        if (self.owned_f) |buf| allocator.free(buf);
        if (self.owned_db) |buf| allocator.free(buf);
        self.* = undefined;
    }
};

const Point = struct {
    f: f64,
    db: f64,

    fn before(_: void, a: Point, b: Point) bool {
        return a.f < b.f;
    }
};

/// Upstream sorts both curves by frequency before it does anything with
/// them — `FrequencyResponse._init_data` calls `sort_values('frequency')` —
/// so a shuffled or descending axis is ordinary input there. Rejecting it
/// was turboEQ's only known divergence as a drop-in replacement, and under a
/// host that falls back on any failure it reads as "turboEQ never runs".
///
/// Duplicated frequencies still fail, as they do upstream: two rows at the
/// same frequency make the interpolation ambiguous rather than merely
/// disordered.
fn prepareCurve(
    allocator: std.mem.Allocator,
    f: []const f64,
    db: []const f64,
) Error!Prepared {
    try checkCurve(f, db);

    var ascending = true;
    for (f[1..], f[0 .. f.len - 1]) |v, prev| {
        if (v <= prev) {
            ascending = false;
            break;
        }
    }
    if (ascending) return .{ .f = f, .db = db };

    const points = try allocator.alloc(Point, f.len);
    defer allocator.free(points);
    for (points, f, db) |*p, fv, dv| p.* = .{ .f = fv, .db = dv };
    std.sort.pdq(Point, points, {}, Point.before);

    var out: Prepared = .{ .f = &.{}, .db = &.{} };
    errdefer out.deinit(allocator);
    const out_f = try allocator.alloc(f64, f.len);
    out.owned_f = out_f;
    const out_db = try allocator.alloc(f64, f.len);
    out.owned_db = out_db;
    for (points, out_f, out_db) |p, *fv, *dv| {
        fv.* = p.f;
        dv.* = p.db;
    }
    for (out_f[1..], out_f[0 .. out_f.len - 1]) |v, prev| {
        if (v <= prev) return Error.BadCurve;
    }
    out.f = out_f;
    out.db = out_db;
    return out;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// A curve with one broad bump, sampled the way a measurement would be.
fn bumpyCurve(allocator: std.mem.Allocator, n: usize) ![2][]f64 {
    const f = try allocator.alloc(f64, n);
    const db = try allocator.alloc(f64, n);
    const lo = math.log10(20.0);
    const hi = math.log10(20000.0);
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
        f[i] = math.pow(f64, 10.0, lo + t * (hi - lo));
        const u = (math.log10(f[i]) - math.log10(3000.0)) / 0.15;
        db[i] = 8.0 * @exp(-u * u) - 3.0 * @exp(-((math.log10(f[i]) - math.log10(60.0)) / 0.3) *
            ((math.log10(f[i]) - math.log10(60.0)) / 0.3));
    }
    return .{ f, db };
}

test "the full pipeline flattens a bump it was given bands for" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 480);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);

    // A flat target on a two point axis: interpolation in log10(f) makes it
    // flat everywhere in between.
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    var result = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .peaking = 8 });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 10), result.filters.len);
    try testing.expectEqual(peq.Kind.low_shelf, result.filters[0].kind);
    try testing.expectEqual(peq.Kind.high_shelf, result.filters[1].kind);

    // The 8 dB bump at 3 kHz is the thing to correct, so some band has to sit
    // near it with a real cut.
    var found = false;
    for (result.filters[2..]) |filt| {
        if (filt.fc > 2000.0 and filt.fc < 4500.0 and filt.gain < -3.0) found = true;
    }
    try testing.expect(found);

    // And the fit has to be better than doing nothing at all.
    var rms_before: f64 = 0.0;
    var n: usize = 0;
    for (result.optimizer_target) |v| {
        rms_before += v * v;
        n += 1;
    }
    rms_before = @sqrt(rms_before / @as(f64, @floatFromInt(n)));
    try testing.expect(result.rmse < rms_before * 0.5);
}

test "the gain cap holds end to end" {
    const allocator = testing.allocator;
    // A deep narrow notch: the perceptual stage refuses to fill it, and
    // nothing downstream may undo that.
    const n = 480;
    const f = try allocator.alloc(f64, n);
    defer allocator.free(f);
    const db = try allocator.alloc(f64, n);
    defer allocator.free(db);
    const lo = math.log10(20.0);
    const hi = math.log10(20000.0);
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
        f[i] = math.pow(f64, 10.0, lo + t * (hi - lo));
        const u = (math.log10(f[i]) - math.log10(8800.0)) / 0.02;
        db[i] = -12.0 * @exp(-u * u);
    }
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    var result = try run(allocator, f, db, &tgt_f, &tgt_db, .{ .peaking = 6 });
    defer result.deinit();
    for (result.equalization) |v| try testing.expect(v <= 6.0 + 1e-9);
}

test "shelves can be turned off, and the band count is what was asked for" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 200);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    var result = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .peaking = 5,
        .shelves = false,
    });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 5), result.filters.len);
    for (result.filters) |filt| try testing.expectEqual(peq.Kind.peaking, filt.kind);
}

test "a malformed axis is rejected rather than followed into log10" {
    const allocator = testing.allocator;
    const ok_f = [_]f64{ 20.0, 20000.0 };
    const ok_db = [_]f64{ 0.0, 0.0 };

    const zero_f = [_]f64{ 0.0, 20000.0 };
    try testing.expectError(Error.BadCurve, run(allocator, &zero_f, &ok_db, &ok_f, &ok_db, .{}));

    // Two rows at one frequency are ambiguous rather than merely disordered,
    // and upstream fails on them too.
    const dup_f = [_]f64{ 100.0, 100.0, 200.0 };
    const dup_db = [_]f64{ 0.0, 0.0, 0.0 };
    try testing.expectError(Error.BadCurve, run(allocator, &dup_f, &dup_db, &ok_f, &ok_db, .{}));

    const nan_db = [_]f64{ 0.0, math.nan(f64) };
    try testing.expectError(Error.BadCurve, run(allocator, &ok_f, &nan_db, &ok_f, &ok_db, .{}));
}

test "an unsorted axis is sorted, the way upstream sorts its input" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 300);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    var ordered = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .peaking = 4 });
    defer ordered.deinit();

    // The same measurement, handed over descending. A host that reverses a
    // curve, or reads one from a file written top down, gets the same fit.
    const rev_f = try allocator.alloc(f64, src[0].len);
    defer allocator.free(rev_f);
    const rev_db = try allocator.alloc(f64, src[1].len);
    defer allocator.free(rev_db);
    for (rev_f, rev_db, 0..) |*fv, *dv, i| {
        fv.* = src[0][src[0].len - 1 - i];
        dv.* = src[1][src[1].len - 1 - i];
    }

    var shuffled = try run(allocator, rev_f, rev_db, &tgt_f, &tgt_db, .{ .peaking = 4 });
    defer shuffled.deinit();

    try testing.expectEqual(ordered.filters.len, shuffled.filters.len);
    try testing.expectEqual(ordered.loss, shuffled.loss);
    for (ordered.filters, shuffled.filters) |a, b| {
        try testing.expectEqual(a.fc, b.fc);
        try testing.expectEqual(a.q, b.q);
        try testing.expectEqual(a.gain, b.gain);
    }
}

test "a named config drives the pipeline end to end" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 300);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    const banks = [_]configs.Bank{configs.byName("10_PEAKING").?};
    var result = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .banks = &banks });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 10), result.filters.len);
    for (result.filters) |filt| try testing.expectEqual(peq.Kind.peaking, filt.kind);
    try testing.expectEqualSlices(usize, &.{ 0, 10 }, result.bank_offsets);
}

test "a device preset's pinned shelves and bounds survive the fit" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 300);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    const banks = [_]configs.Bank{configs.byName("QUDELIX_5K").?};
    var result = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .banks = &banks });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 10), result.filters.len);
    // The shelves were pinned, so the optimizer may not have moved them.
    try testing.expectEqual(@as(f64, 105.0), result.filters[0].fc);
    try testing.expectEqual(@as(f64, 0.7), result.filters[0].q);
    try testing.expectEqual(@as(f64, 10000.0), result.filters[1].fc);
    for (result.filters) |filt| {
        try testing.expect(filt.gain >= -12.0 - 1e-9 and filt.gain <= 12.0 + 1e-9);
    }
    for (result.filters[2..]) |filt| {
        try testing.expect(filt.q >= 0.1 - 1e-9 and filt.q <= 7.0 + 1e-9);
        try testing.expect(filt.fc >= 20.0 - 1e-9 and filt.fc <= 10000.0 + 1e-9);
    }
}

test "a graphic EQ config moves gain only" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 300);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    const bank = configs.byName("10_BAND_GRAPHIC_EQ").?;
    const banks = [_]configs.Bank{bank};
    var result = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .banks = &banks });
    defer result.deinit();

    for (result.filters, bank.filters) |got, template| {
        try testing.expectEqual(template.fc, got.fc);
        try testing.expectEqual(template.q, got.q);
    }
    var moved = false;
    for (result.filters) |filt| {
        if (@abs(filt.gain) > 0.1) moved = true;
    }
    try testing.expect(moved);
}

test "the cascade fits the residual, and beats its first bank alone" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 300);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    const first_only = [_]configs.Bank{configs.autoeq_cli_default[0]};
    var one = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .banks = &first_only });
    defer one.deinit();

    var both = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .banks = &configs.autoeq_cli_default,
    });
    defer both.deinit();

    // AutoEq's own CLI default: five filters, then five more on the residual.
    try testing.expectEqual(@as(usize, 5), one.filters.len);
    try testing.expectEqual(@as(usize, 10), both.filters.len);
    try testing.expectEqualSlices(usize, &.{ 0, 5, 10 }, both.bank_offsets);
    try testing.expectEqual(peq.Kind.low_shelf, both.filters[0].kind);
    try testing.expectEqual(peq.Kind.high_shelf, both.filters[5].kind);

    // The second bank only ever subtracts from what is left, so it cannot
    // make the whole EQ worse.
    try testing.expect(both.rmse < one.rmse);
}

test "the default path is unchanged by the cascade machinery" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 300);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    var implicit = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .peaking = 8 });
    defer implicit.deinit();

    // The same ten bands named explicitly must land in the same place.
    const banks = [_]configs.Bank{configs.byName("8_PEAKING_WITH_SHELVES").?};
    var explicit = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .banks = &banks });
    defer explicit.deinit();

    try testing.expectEqual(implicit.filters.len, explicit.filters.len);
    try testing.expectEqualSlices(usize, &.{ 0, 10 }, implicit.bank_offsets);
    for (implicit.filters, explicit.filters) |a, b| {
        try testing.expectApproxEqAbs(a.fc, b.fc, 1e-9);
        try testing.expectApproxEqAbs(a.q, b.q, 1e-9);
        try testing.expectApproxEqAbs(a.gain, b.gain, 1e-9);
    }
    try testing.expectApproxEqAbs(implicit.rmse, explicit.rmse, 1e-12);
    try testing.expectApproxEqAbs(implicit.max_gain, explicit.max_gain, 1e-12);
}

test "upstream_stop_rules applies the bank's own min_std" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 300);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    const banks = [_]configs.Bank{configs.byName("8_PEAKING_WITH_SHELVES").?};
    var converged = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .banks = &banks });
    defer converged.deinit();
    var stopped = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .banks = &banks,
        .upstream_stop_rules = true,
    });
    defer stopped.deinit();

    // Upstream's min_std is 0.008 here, so it stops earlier and fits worse.
    // That is the trade turboEQ declines by default.
    try testing.expect(stopped.iterations < converged.iterations);
    try testing.expect(stopped.rmse >= converged.rmse);
}

test "an empty bank list has nothing to fit" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 100);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };
    const none = [_]configs.Bank{};
    try testing.expectError(
        Error.NoBands,
        run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .banks = &none }),
    );
}

test "a sound signature moves the target, not the source" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 300);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    var plain = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .peaking = 8 });
    defer plain.deinit();

    // A 4 dB tilt up across the top two octaves, as few points as upstream
    // allows. The fit should now aim above the target up there.
    const sig_f = [_]f64{ 20.0, 5000.0, 20000.0 };
    const sig_db = [_]f64{ 0.0, 0.0, 4.0 };
    var coloured = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .peaking = 8,
        .sound_signature = .{ .f = &sig_f, .db = &sig_db },
    });
    defer coloured.deinit();

    // Above 5 kHz the signature asks for more output, so the equalization
    // there has to sit higher than it did without one.
    var compared: usize = 0;
    for (plain.f, plain.equalization, coloured.equalization) |fv, a, b| {
        if (fv < 8000.0) continue;
        try testing.expect(b > a);
        compared += 1;
    }
    try testing.expect(compared > 0);

    // Below the signature's own knee nothing asked for a change.
    for (plain.f, plain.equalization, coloured.equalization) |fv, a, b| {
        if (fv > 1000.0) break;
        try testing.expectApproxEqAbs(a, b, 0.75);
    }
}

test "a flat sound signature is not a no-op, because it is never centred" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 200);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    // Upstream centres the target and not the signature, so a signature
    // sitting 1 dB up everywhere raises the whole target by 1 dB, and the
    // equalization with it. `min_mean_error` would take that straight back
    // out, so it is off here.
    //
    // A constant offset commutes with everything else the perceptual stage
    // does — the slope limiter reads gradients, the dip protection reads
    // prominences, the smoothers are linear — so away from the gain cap the
    // shift is exact rather than approximate.
    const sig_f = [_]f64{ 20.0, 20000.0 };
    const sig_db = [_]f64{ 1.0, 1.0 };
    var result = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .peaking = 4,
        .sound_signature = .{ .f = &sig_f, .db = &sig_db },
        .min_mean_error = false,
    });
    defer result.deinit();

    var plain = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .peaking = 4,
        .min_mean_error = false,
    });
    defer plain.deinit();

    var checked: usize = 0;
    for (plain.equalization, result.equalization) |a, b| {
        // The 6 dB ceiling is the one step that does not commute.
        if (a + 1.0 > 5.9) continue;
        try testing.expectApproxEqAbs(a + 1.0, b, 1e-9);
        checked += 1;
    }
    try testing.expect(checked > plain.equalization.len / 2);
}

test "smoothing a sound signature rounds its corners off" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 200);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    // A step. Unsmoothed it stays a kink in the target; smoothed it spreads.
    const sig_f = [_]f64{ 20.0, 999.0, 1001.0, 20000.0 };
    const sig_db = [_]f64{ 0.0, 0.0, 5.0, 5.0 };

    var sharp = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .peaking = 4,
        .sound_signature = .{ .f = &sig_f, .db = &sig_db },
    });
    defer sharp.deinit();
    var soft = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .peaking = 4,
        .sound_signature = .{ .f = &sig_f, .db = &sig_db },
        .sound_signature_smoothing_window_size = 1.0,
    });
    defer soft.deinit();

    // The steepest step between neighbouring samples has to be gentler.
    var sharpest_a: f64 = 0;
    var sharpest_b: f64 = 0;
    for (1..sharp.equalization.len) |i| {
        sharpest_a = @max(sharpest_a, @abs(sharp.equalization[i] - sharp.equalization[i - 1]));
        sharpest_b = @max(sharpest_b, @abs(soft.equalization[i] - soft.equalization[i - 1]));
    }
    try testing.expect(sharpest_b < sharpest_a);

    // Zero means "no smoothing", the way a falsy value does upstream.
    var zero = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .peaking = 4,
        .sound_signature = .{ .f = &sig_f, .db = &sig_db },
        .sound_signature_smoothing_window_size = 0.0,
    });
    defer zero.deinit();
    for (sharp.equalization, zero.equalization) |a, b| {
        try testing.expectApproxEqAbs(a, b, 1e-12);
    }
}

test "a malformed sound signature is rejected like any other curve" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 100);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };
    const bad_f = [_]f64{ -100.0, 50.0 };
    const bad_db = [_]f64{ 0.0, 0.0 };
    try testing.expectError(Error.BadCurve, run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .sound_signature = .{ .f = &bad_f, .db = &bad_db },
    }));

    // A descending signature is sorted like any other curve, not refused.
    const rev_f = [_]f64{ 20000.0, 5000.0, 20.0 };
    const rev_db = [_]f64{ 4.0, 0.0, 0.0 };
    var coloured = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .peaking = 4,
        .sound_signature = .{ .f = &rev_f, .db = &rev_db },
    });
    coloured.deinit();
}

test "gain_range pins each band to a window around the curve at its own fc" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 300);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    const bank = configs.byName("10_BAND_GRAPHIC_EQ").?;
    const banks = [_]configs.Bank{bank};
    const range = 1.5;
    var result = try run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{
        .banks = &banks,
        .gain_range = range,
    });
    defer result.deinit();

    // The centres come off `Result.equalization`, which is the 1.01 grid
    // before the preamp — the same curve upstream reads.
    const fcs = try allocator.alloc(f64, bank.filters.len);
    defer allocator.free(fcs);
    for (bank.filters, fcs) |filt, *fc| fc.* = filt.fc;
    const centers = try allocator.alloc(f64, fcs.len);
    defer allocator.free(centers);
    try curve.interpolate(allocator, result.f, result.equalization, fcs, centers);

    for (result.filters, centers) |filt, centre| {
        try testing.expect(filt.gain >= centre - range - 1e-9);
        try testing.expect(filt.gain <= centre + range + 1e-9);
    }
}

test "gain_range refuses a bank whose fc is free to move" {
    const allocator = testing.allocator;
    const src = try bumpyCurve(allocator, 300);
    defer allocator.free(src[0]);
    defer allocator.free(src[1]);
    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    try testing.expectError(
        Error.GainRangeNeedsFixedFc,
        run(allocator, src[0], src[1], &tgt_f, &tgt_db, .{ .gain_range = 1.5 }),
    );
}
