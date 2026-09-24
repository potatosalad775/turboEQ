//! Filter banks as data, the way `PEQ.from_dict` reads them.
//!
//! Upstream describes a parametric EQ as a list of filter dicts plus an
//! optional `optimizer` block, and resolves each dict against two layers of
//! defaults: the config's own `filter_defaults`, then a global table keyed
//! by filter type. Supplying a value for `fc`, `q` or `gain` is also how it
//! says "do not optimize this one" — there is no separate flag.
//!
//! `Spec` is that dict and `fromSpec` is that resolution. It exists so the
//! three callers that need it — this file's table, `pipeline.Config`, and
//! the wasm filter descriptor — agree on the rules rather than each
//! reinventing them.
//!
//! `filter_defaults` is not modelled. It is a way to avoid repetition in
//! YAML, and here the table is Zig, so every `Spec` carries its own values
//! and `pinnedShelves` takes the gain range the presets vary.
//!
//! Derived from AutoEq (MIT, Jaakko Pasanen), autoeq/constants.py.

const std = @import("std");
const math = std.math;
const peq = @import("peq.zig");

/// One entry of a config's `filters` list. Every field is optional because
/// upstream's dicts are, and null means "resolve from the global defaults
/// for this filter type".
///
/// Setting `fc`, `q` or `gain` pins that parameter, exactly as supplying the
/// key does upstream.
pub const Spec = struct {
    kind: peq.Kind,
    fc: ?f64 = null,
    q: ?f64 = null,
    gain: ?f64 = null,
    min_fc: ?f64 = null,
    max_fc: ?f64 = null,
    min_q: ?f64 = null,
    max_q: ?f64 = null,
    min_gain: ?f64 = null,
    max_gain: ?f64 = null,
};

/// The `global_filter_defaults` table. Shelves share one row upstream, via
/// a `deepcopy` of the low shelf's.
pub fn defaultLimits(kind: peq.Kind) peq.Limits {
    return switch (kind) {
        .peaking => peq.peaking_limits,
        .low_shelf, .high_shelf => peq.shelf_limits,
    };
}

/// Step 2 of `fromSpec`, kept separate because upstream's order matters: a
/// collapsed bound pair overwrites a supplied value rather than deferring to
/// it. `min_fc == max_fc` with `fc` also given yields the bound, not the
/// `fc`. Nothing shipped exercises it, but reproducing the precedence costs
/// one line.
fn pin(given: ?f64, lo: f64, hi: f64) ?f64 {
    if (lo == hi) return lo;
    return given;
}

/// `from_dict`'s per-filter resolution, verbatim:
///
///   1. Fill missing bounds from the global defaults for the type.
///   2. Where a bound pair has collapsed to a point, that point becomes the
///      value — `min_fc == max_fc` supplies `fc`, and so on.
///   3. A parameter is optimized exactly when no value was supplied.
///
/// Step 2 runs before step 3 upstream, so a collapsed pair pins the
/// parameter as surely as writing it out does.
pub fn fromSpec(spec: Spec) peq.Filter {
    const d = defaultLimits(spec.kind);
    const limits: peq.Limits = .{
        .min_fc = spec.min_fc orelse d.min_fc,
        .max_fc = spec.max_fc orelse d.max_fc,
        .min_q = spec.min_q orelse d.min_q,
        .max_q = spec.max_q orelse d.max_q,
        .min_gain = spec.min_gain orelse d.min_gain,
        .max_gain = spec.max_gain orelse d.max_gain,
    };

    const fc = pin(spec.fc, limits.min_fc, limits.max_fc);
    const q = pin(spec.q, limits.min_q, limits.max_q);
    const gain = pin(spec.gain, limits.min_gain, limits.max_gain);

    return .{
        .kind = spec.kind,
        // An optimized parameter is initialized by `initFilter`, so the
        // placeholder here is never read.
        .fc = fc orelse 0,
        .q = q orelse 0,
        .gain = gain orelse 0,
        .optimize_fc = fc == null,
        .optimize_q = q == null,
        .optimize_gain = gain == null,
        .limits = limits,
    };
}

/// One named entry of `PEQ_CONFIGS`.
pub const Bank = struct {
    name: []const u8,
    /// Templates. `build` copies them; the optimizer writes through its copy.
    filters: []const peq.Filter,
    /// The `min_f` and `max_f` of upstream's `optimizer` block. These decide
    /// which error the fit is scored against, so they are part of the
    /// objective. Null defers to the caller's own `pipeline.Config.optimizer`;
    /// only `4_PEAKING_WITH_LOW_SHELF` sets it.
    optimizer: ?peq.Options = null,
    /// The `min_std` of that same block. Recorded but **not** applied:
    /// turboEQ runs to convergence by default, because stopping early
    /// measured worse (BENCHMARKS.md). `pipeline.Config.upstream_stop_rules`
    /// opts back in for a caller who wants upstream's answer rather than a
    /// better one.
    min_std: ?f64 = null,

    /// A mutable copy for the optimizer to write through. The caller owns it.
    pub fn build(self: Bank, allocator: std.mem.Allocator) ![]peq.Filter {
        return allocator.dupe(peq.Filter, self.filters);
    }
};

// ---------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------

fn repeat(comptime n: usize, comptime spec: Spec) [n]peq.Filter {
    return @splat(fromSpec(spec));
}

/// The pinned pair every shelved preset opens with: 105 Hz and 10 kHz, both
/// Q 0.7, gain the only free parameter. The gain range is what the device
/// presets vary, through their `filter_defaults`.
fn pinnedShelves(comptime min_gain: f64, comptime max_gain: f64) [2]peq.Filter {
    return .{
        fromSpec(.{
            .kind = .low_shelf,
            .fc = 105.0,
            .q = 0.7,
            .min_gain = min_gain,
            .max_gain = max_gain,
        }),
        fromSpec(.{
            .kind = .high_shelf,
            .fc = 10000.0,
            .q = 0.7,
            .min_gain = min_gain,
            .max_gain = max_gain,
        }),
    };
}

const default_shelf_gain_min = peq.shelf_limits.min_gain;
const default_shelf_gain_max = peq.shelf_limits.max_gain;

const ten_band_filters = blk: {
    // `math.pow` is not cheap at comptime and the default quota is 1000.
    @setEvalBranchQuota(20000);
    var out: [10]peq.Filter = undefined;
    for (&out, 0..) |*filt, i| {
        filt.* = fromSpec(.{
            .kind = .peaking,
            .fc = 31.25 * math.pow(f64, 2.0, @floatFromInt(i)),
            .q = math.sqrt2,
            .min_gain = -12.0,
            .max_gain = 12.0,
        });
    }
    break :blk out;
};

const thirty_one_band_filters = blk: {
    // `math.pow` is not cheap at comptime and the default quota is 1000.
    @setEvalBranchQuota(20000);
    var out: [31]peq.Filter = undefined;
    for (&out, 0..) |*filt, i| {
        filt.* = fromSpec(.{
            .kind = .peaking,
            .fc = 20.0 * math.pow(f64, 2.0, @as(f64, @floatFromInt(i)) / 3.0),
            .q = 4.318473,
            .min_gain = -12.0,
            .max_gain = 12.0,
        });
    }
    break :blk out;
};

const spotify_filters = blk: {
    const fcs = [_]f64{ 60.0, 150.0, 400.0, 1000.0, 2400.0, 15000.0 };
    var out: [fcs.len]peq.Filter = undefined;
    for (&out, fcs) |*filt, fc| {
        filt.* = fromSpec(.{ .kind = .peaking, .fc = fc, .q = 1.0 });
    }
    break :blk out;
};

/// A device preset's peaking row: bounded Q and fc, gain from the config's
/// `filter_defaults`.
fn devicePeaking(
    comptime min_q: f64,
    comptime max_q: f64,
    comptime min_fc: f64,
    comptime min_gain: f64,
    comptime max_gain: f64,
) Spec {
    return .{
        .kind = .peaking,
        .min_q = min_q,
        .max_q = max_q,
        .min_fc = min_fc,
        .max_fc = 10000.0,
        .min_gain = min_gain,
        .max_gain = max_gain,
    };
}

const ten_peaking = repeat(10, .{ .kind = .peaking });
const eight_with_shelves =
    pinnedShelves(default_shelf_gain_min, default_shelf_gain_max) ++
    repeat(8, .{ .kind = .peaking });
const four_with_shelves =
    pinnedShelves(default_shelf_gain_min, default_shelf_gain_max) ++
    repeat(4, .{ .kind = .peaking });
const four_with_low_shelf =
    [_]peq.Filter{fromSpec(.{ .kind = .low_shelf, .fc = 105.0, .q = 0.7 })} ++
    repeat(4, .{ .kind = .peaking });
const four_with_high_shelf =
    [_]peq.Filter{fromSpec(.{ .kind = .high_shelf, .fc = 10000.0, .q = 0.7 })} ++
    repeat(4, .{ .kind = .peaking });

const aunbandeq = pinnedShelves(default_shelf_gain_min, default_shelf_gain_max) ++
    repeat(8, devicePeaking(0.182479, 10.0, 20.0, default_shelf_gain_min, default_shelf_gain_max));
const minidsp_2x4hd = pinnedShelves(-16.0, 16.0) ++
    repeat(8, devicePeaking(0.5, 6.0, 20.0, -16.0, 16.0));
const minidsp_il_dsp = pinnedShelves(-16.0, 16.0) ++
    repeat(8, devicePeaking(0.5, 6.0, 20.0, -16.0, 16.0));
const moondrop_free_dsp = repeat(9, devicePeaking(0.5, 6.0, 40.0, -12.0, 3.0));
const neutron = pinnedShelves(-12.0, 12.0) ++
    repeat(8, devicePeaking(0.1, 5.0, 20.0, -12.0, 12.0));
const poweramp = pinnedShelves(-15.0, 15.0) ++
    repeat(8, devicePeaking(0.1, 12.0, 20.0, -15.0, 15.0));
const qudelix_5k = pinnedShelves(-12.0, 12.0) ++
    repeat(8, devicePeaking(0.1, 7.0, 20.0, -12.0, 12.0));
const uapp = pinnedShelves(-20.0, 20.0) ++
    repeat(8, devicePeaking(0.1, 10.0, 20.0, -20.0, 20.0));

/// `PEQ_CONFIGS`, in upstream's order. The `min_std` values are recorded
/// rather than applied; see `Bank.min_std`.
pub const named = [_]Bank{
    .{ .name = "10_BAND_GRAPHIC_EQ", .filters = &ten_band_filters, .min_std = 0.01 },
    .{ .name = "31_BAND_GRAPHIC_EQ", .filters = &thirty_one_band_filters, .min_std = 0.01 },
    .{ .name = "10_PEAKING", .filters = &ten_peaking },
    .{ .name = "8_PEAKING_WITH_SHELVES", .filters = &eight_with_shelves, .min_std = 0.008 },
    .{ .name = "4_PEAKING_WITH_SHELVES", .filters = &four_with_shelves, .min_std = 0.008 },
    // The only config that narrows the loss band. Its partner in the CLI
    // default covers the treble, so this half is scored to 10 kHz only.
    .{
        .name = "4_PEAKING_WITH_LOW_SHELF",
        .filters = &four_with_low_shelf,
        .optimizer = .{ .min_f = 20.0, .max_f = 10000.0 },
    },
    .{ .name = "4_PEAKING_WITH_HIGH_SHELF", .filters = &four_with_high_shelf },
    .{ .name = "AUNBANDEQ", .filters = &aunbandeq, .min_std = 0.008 },
    .{ .name = "MINIDSP_2X4HD", .filters = &minidsp_2x4hd, .min_std = 0.008 },
    .{ .name = "MINIDSP_IL_DSP", .filters = &minidsp_il_dsp, .min_std = 0.008 },
    .{ .name = "MOONDROP_FREE_DSP", .filters = &moondrop_free_dsp, .min_std = 0.008 },
    .{ .name = "NEUTRON_MUSIC_PLAYER", .filters = &neutron, .min_std = 0.008 },
    .{ .name = "POWERAMP_EQUALIZER", .filters = &poweramp, .min_std = 0.008 },
    .{ .name = "QUDELIX_5K", .filters = &qudelix_5k, .min_std = 0.008 },
    .{ .name = "SPOTIFY", .filters = &spotify_filters, .min_std = 0.01 },
    .{ .name = "USB_AUDIO_PLAYER_PRO", .filters = &uapp, .min_std = 0.008 },
};

/// Look a config up by its upstream name. Case-sensitive, as upstream's dict
/// keys are.
pub fn byName(name: []const u8) ?Bank {
    for (named) |bank| {
        if (std.mem.eql(u8, bank.name, name)) return bank;
    }
    return null;
}

/// AutoEq's own CLI default: `4_PEAKING_WITH_LOW_SHELF,4_PEAKING_WITH_HIGH_SHELF`,
/// fitted as a cascade. turboEQ's default is `8_PEAKING_WITH_SHELVES`
/// instead — ten filters either way, but one fit rather than two, which is
/// the shape an interactive caller wants. BENCHMARKS.md has the comparison.
pub const autoeq_cli_default = [_]Bank{
    byName("4_PEAKING_WITH_LOW_SHELF").?,
    byName("4_PEAKING_WITH_HIGH_SHELF").?,
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a bare peaking spec takes the global defaults and optimizes everything" {
    const filt = fromSpec(.{ .kind = .peaking });
    try testing.expect(filt.optimize_fc);
    try testing.expect(filt.optimize_q);
    try testing.expect(filt.optimize_gain);
    try testing.expectEqual(peq.peaking_limits, filt.limits);
}

test "supplying a value pins that parameter and only that one" {
    const filt = fromSpec(.{ .kind = .low_shelf, .fc = 105.0, .q = 0.7 });
    try testing.expect(!filt.optimize_fc);
    try testing.expect(!filt.optimize_q);
    try testing.expect(filt.optimize_gain);
    try testing.expectEqual(@as(f64, 105.0), filt.fc);
    try testing.expectEqual(@as(f64, 0.7), filt.q);
    // Bounds still come from the shelf defaults.
    try testing.expectEqual(peq.shelf_limits.min_gain, filt.limits.min_gain);
}

test "a collapsed bound pair pins the parameter, as from_dict does" {
    const filt = fromSpec(.{ .kind = .peaking, .min_q = 1.5, .max_q = 1.5 });
    try testing.expect(!filt.optimize_q);
    try testing.expectEqual(@as(f64, 1.5), filt.q);
    try testing.expect(filt.optimize_fc);
    try testing.expect(filt.optimize_gain);
}

test "the named table matches upstream's shapes" {
    try testing.expectEqual(@as(usize, 16), named.len);
    try testing.expectEqual(@as(usize, 10), byName("10_PEAKING").?.filters.len);
    try testing.expectEqual(@as(usize, 10), byName("8_PEAKING_WITH_SHELVES").?.filters.len);
    try testing.expectEqual(@as(usize, 5), byName("4_PEAKING_WITH_LOW_SHELF").?.filters.len);
    try testing.expectEqual(@as(usize, 6), byName("SPOTIFY").?.filters.len);
    try testing.expectEqual(@as(usize, 31), byName("31_BAND_GRAPHIC_EQ").?.filters.len);
    try testing.expectEqual(@as(?Bank, null), byName("NOT_A_CONFIG"));
}

test "the low shelf config is the only one that overrides the loss band" {
    for (named) |bank| {
        if (std.mem.eql(u8, bank.name, "4_PEAKING_WITH_LOW_SHELF")) {
            try testing.expectEqual(@as(f64, 10000.0), bank.optimizer.?.max_f);
        } else {
            try testing.expectEqual(@as(?peq.Options, null), bank.optimizer);
        }
    }
}

test "a device preset pins its shelves and bounds its peaks" {
    const bank = byName("QUDELIX_5K").?;
    try testing.expectEqual(@as(usize, 10), bank.filters.len);
    try testing.expectEqual(peq.Kind.low_shelf, bank.filters[0].kind);
    try testing.expect(!bank.filters[0].optimize_fc);
    // filter_defaults reaches the shelves too, not just the peaking bands.
    try testing.expectEqual(@as(f64, -12.0), bank.filters[0].limits.min_gain);
    try testing.expectEqual(@as(f64, 12.0), bank.filters[1].limits.max_gain);
    for (bank.filters[2..]) |filt| {
        try testing.expectEqual(peq.Kind.peaking, filt.kind);
        try testing.expect(filt.optimize_fc);
        try testing.expectEqual(@as(f64, 0.1), filt.limits.min_q);
        try testing.expectEqual(@as(f64, 7.0), filt.limits.max_q);
        try testing.expectEqual(@as(f64, -12.0), filt.limits.min_gain);
    }
}

test "the graphic EQ configs optimize gain alone" {
    for ([_][]const u8{ "10_BAND_GRAPHIC_EQ", "31_BAND_GRAPHIC_EQ", "SPOTIFY" }) |name| {
        for (byName(name).?.filters) |filt| {
            try testing.expect(!filt.optimize_fc);
            try testing.expect(!filt.optimize_q);
            try testing.expect(filt.optimize_gain);
        }
    }
    // 31.25 * 2^9, which upstream computes the same way.
    const ten = byName("10_BAND_GRAPHIC_EQ").?.filters;
    try testing.expectApproxEqAbs(@as(f64, 31.25), ten[0].fc, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 16000.0), ten[9].fc, 1e-9);
}

test "build hands back a writable copy" {
    const bank = byName("10_PEAKING").?;
    const filters = try bank.build(testing.allocator);
    defer testing.allocator.free(filters);
    try testing.expectEqual(bank.filters.len, filters.len);
    filters[0].gain = 3.0;
    try testing.expectEqual(@as(f64, 0.0), bank.filters[0].gain);
}
