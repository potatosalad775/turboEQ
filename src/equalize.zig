//! The perceptual pipeline.
//!
//! This is the part that makes the result sound right rather than merely
//! fit well. It takes the error curve and turns it into an equalization
//! target that
//!
//!   - never boosts more than `max_gain`,
//!   - never rises faster than `max_slope` dB per octave, and
//!   - declines to fill narrow dips that sit below their neighbours,
//!     because those are usually resonances of the measurement rig rather
//!     than something a listener would want boosted.
//!
//! The slope limiter runs twice, once in each direction, and the two passes
//! are combined with a minimum. A rise the left-to-right pass has to clip
//! is a rise the right-to-left pass sees as a fall, so between them they
//! catch both sides of every peak.
//!
//! Derived from AutoEq (MIT, Jaakko Pasanen), autoeq/frequency_response.py.

const std = @import("std");
const math = std.math;
const util = @import("util.zig");
const peaks = @import("peaks.zig");
const curve = @import("curve.zig");

pub const Options = struct {
    /// Hard ceiling on positive gain, in dB.
    max_gain: f64 = 6.0,
    /// Slope ceiling, in dB per octave.
    max_slope: f64 = 18.0,
    /// Per-octave decay of the slope limit inside a single clipped region.
    /// Upstream ships 0.0, which disables it.
    max_slope_decay: f64 = 0.0,
    /// Do the measurements carry the narrow ~9 kHz dip that concha
    /// resonance produces? If so that region loses its dip protection and
    /// gets a quarter of the usual slope allowance.
    concha_interference: bool = false,
    window_size: f64 = 1.0 / 12.0,
    treble_window_size: f64 = 2.0,
    treble_f_lower: f64 = 6000.0,
    treble_f_upper: f64 = 8000.0,
    /// Scales gain in the treble, both directions. 1.0 leaves it alone.
    treble_gain_k: f64 = 1.0,
    /// The last smoothing pass, over the limited and capped curve, in
    /// octaves. Upstream hardcodes a fifth of an octave in `equalize`, which
    /// blurs anything narrower out of what the optimizer fits; zero or less
    /// skips the pass. Not one of upstream's parameters, so anything but 1/5
    /// departs from its objective.
    equalization_window_size: f64 = 1.0 / 5.0,
};

/// Everything `FrequencyResponse.equalize` returns. The intermediates are
/// carried out because tools/parity checks each of them separately, and
/// because they are what you look at when the curve comes out wrong.
pub const Result = struct {
    allocator: std.mem.Allocator,
    /// The equalization curve. This is what the optimizer fits.
    equalization: []f64,
    /// The smoothed error the whole stage was derived from.
    smoothed_error: []f64,
    limited_ltr: []f64,
    clipped_ltr: []bool,
    limited_rtl: []f64,
    clipped_rtl: []bool,
    peak_inds: []usize,
    dip_inds: []usize,
    rtl_start: usize,
    limit_free_mask: []bool,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.equalization);
        self.allocator.free(self.smoothed_error);
        self.allocator.free(self.limited_ltr);
        self.allocator.free(self.clipped_ltr);
        self.allocator.free(self.limited_rtl);
        self.allocator.free(self.clipped_rtl);
        self.allocator.free(self.peak_inds);
        self.allocator.free(self.dip_inds);
        self.allocator.free(self.limit_free_mask);
    }
};

/// `FrequencyResponse.equalize`. `error_curve` is the output of
/// `curve.compensate`.
pub fn equalize(
    allocator: std.mem.Allocator,
    f: []const f64,
    error_curve: []const f64,
    opts: Options,
) !Result {
    std.debug.assert(f.len == error_curve.len);
    const n = f.len;

    const smoothed_error = try allocator.alloc(f64, n);
    errdefer allocator.free(smoothed_error);
    try curve.smoothen(allocator, f, error_curve, .{
        .window_size = opts.window_size,
        .treble_window_size = opts.treble_window_size,
        .treble_f_lower = opts.treble_f_lower,
        .treble_f_upper = opts.treble_f_upper,
    }, smoothed_error);

    // The equalization works on the inverse of the smoothed error: what has
    // to be added, not what is wrong.
    const y = try allocator.alloc(f64, n);
    defer allocator.free(y);
    for (y, smoothed_error) |*v, e| v.* = -e;

    const neg_y = try allocator.alloc(f64, n);
    defer allocator.free(neg_y);
    for (neg_y, y) |*v, a| v.* = -a;

    const peak_inds = try peaks.findIndices(allocator, y, 1.0);
    errdefer allocator.free(peak_inds);
    const dip_inds = try peaks.findIndices(allocator, neg_y, 1.0);
    errdefer allocator.free(dip_inds);

    if (peak_inds.len == 0 and dip_inds.len == 0) {
        // A flat line. The inverse error is already a usable target and
        // none of the limiting machinery has anything to bite on.
        const equalization = try allocator.dupe(f64, y);
        const limit_free_mask = try allocator.alloc(bool, n);
        @memset(limit_free_mask, false);
        const clipped_ltr = try allocator.alloc(bool, n);
        @memset(clipped_ltr, false);
        const clipped_rtl = try allocator.alloc(bool, n);
        @memset(clipped_rtl, false);
        return .{
            .allocator = allocator,
            .equalization = equalization,
            .smoothed_error = smoothed_error,
            .limited_ltr = try allocator.alloc(f64, 0),
            .clipped_ltr = clipped_ltr,
            .limited_rtl = try allocator.alloc(f64, 0),
            .clipped_rtl = clipped_rtl,
            .peak_inds = peak_inds,
            .dip_inds = dip_inds,
            .rtl_start = n - 1,
            .limit_free_mask = limit_free_mask,
        };
    }

    const limit_free_mask = try protectionMask(allocator, y, peak_inds, dip_inds);
    errdefer allocator.free(limit_free_mask);
    if (opts.concha_interference) {
        for (f, limit_free_mask) |fv, *m| {
            if (fv >= 8000.0 and fv <= 11500.0) m.* = false;
        }
    }

    const rtl_start = findRtlStart(y, peak_inds, dip_inds);

    const limited_ltr = try allocator.alloc(f64, n);
    errdefer allocator.free(limited_ltr);
    const clipped_ltr = try allocator.alloc(bool, n);
    errdefer allocator.free(clipped_ltr);
    try limitedLtrSlope(allocator, f, y, 0, peak_inds, limit_free_mask, opts, limited_ltr, clipped_ltr);

    const limited_rtl = try allocator.alloc(f64, n);
    errdefer allocator.free(limited_rtl);
    const clipped_rtl = try allocator.alloc(bool, n);
    errdefer allocator.free(clipped_rtl);
    try limitedRtlSlope(allocator, f, y, rtl_start, peak_inds, limit_free_mask, opts, limited_rtl, clipped_rtl);

    // Combine, scale the treble, then cap.
    const combined = try allocator.alloc(f64, n);
    defer allocator.free(combined);
    for (combined, limited_ltr, limited_rtl) |*c, a, b| c.* = @min(a, b);

    const gain_k = try allocator.alloc(f64, n);
    defer allocator.free(gain_k);
    util.logFSigmoid(f, opts.treble_f_lower, opts.treble_f_upper, 1.0, opts.treble_gain_k, gain_k);
    for (combined, gain_k) |*c, k| c.* *= k;
    for (combined) |*c| c.* = @min(c.*, opts.max_gain);

    // A fifth-octave pass takes the kinks the limiter left out of the curve.
    const equalization = try allocator.alloc(f64, n);
    errdefer allocator.free(equalization);
    if (opts.equalization_window_size > 0.0) {
        try curve.smoothen(allocator, f, combined, .{
            .window_size = opts.equalization_window_size,
            .treble_window_size = opts.equalization_window_size,
        }, equalization);
    } else {
        @memcpy(equalization, combined);
    }

    return .{
        .allocator = allocator,
        .equalization = equalization,
        .smoothed_error = smoothed_error,
        .limited_ltr = limited_ltr,
        .clipped_ltr = clipped_ltr,
        .limited_rtl = limited_rtl,
        .clipped_rtl = clipped_rtl,
        .peak_inds = peak_inds,
        .dip_inds = dip_inds,
        .rtl_start = rtl_start,
        .limit_free_mask = limit_free_mask,
    };
}

/// `FrequencyResponse.protection_mask`. Marks the zones around dips that sit
/// lower than the dips on either side of them. Those are the narrow
/// resonant notches the limiter must be allowed to leave unfilled.
pub fn protectionMask(
    allocator: std.mem.Allocator,
    y: []const f64,
    peak_inds: []const usize,
    dip_inds: []const usize,
) ![]bool {
    const n = y.len;
    const mask = try allocator.alloc(bool, n);
    errdefer allocator.free(mask);
    @memset(mask, false);

    // Upstream appends a closing dip so that the last real dip has a right
    // hand neighbour to measure against.
    var inds: std.ArrayList(usize) = .empty;
    defer inds.deinit(allocator);
    var levels: std.ArrayList(f64) = .empty;
    defer levels.deinit(allocator);
    for (dip_inds) |d| {
        try inds.append(allocator, d);
        try levels.append(allocator, y[d]);
    }

    if (peak_inds.len != 0 and (dip_inds.len == 0 or peak_inds[peak_inds.len - 1] > dip_inds[dip_inds.len - 1])) {
        // The curve ends on a peak. Close it off at the minimum that
        // follows.
        const from = peak_inds[peak_inds.len - 1];
        var last_dip = from;
        for (from..n) |i| {
            if (y[i] < y[last_dip]) last_dip = i;
        }
        try inds.append(allocator, last_dip);
        try levels.append(allocator, y[last_dip]);
    } else {
        // The curve ends on a dip. Upstream appends index -1, the last
        // sample, but overrides its level with the minimum of the whole
        // curve, so only the level is ever used.
        var min_y = y[0];
        for (y) |v| min_y = @min(min_y, v);
        try inds.append(allocator, n - 1);
        try levels.append(allocator, min_y);
    }

    if (inds.items.len < 3) return mask;

    for (1..inds.items.len - 1) |i| {
        const dip_ind = inds.items[i];
        const target_left = levels.items[i - 1];
        const target_right = levels.items[i + 1];

        // Last index left of the dip where the curve is still at or above
        // the left neighbour's level, plus one. Upstream raises IndexError
        // if there is no such index; here the zone just starts at 0. The
        // previous dip sits at that level by construction, so neither path
        // is reachable in practice.
        var left_ind: usize = 0;
        var k: usize = dip_ind;
        while (k > 0) {
            k -= 1;
            if (y[k] >= target_left) {
                left_ind = k + 1;
                break;
            }
        }

        // First index right of the dip where it is back at or above the
        // right neighbour's level, minus one. If that is the dip itself the
        // zone is empty, which is why this is signed.
        var right_ind: isize = @as(isize, @intCast(dip_ind)) - 1;
        for (dip_ind..n) |j| {
            if (y[j] >= target_right) {
                right_ind = @as(isize, @intCast(j)) - 1;
                break;
            }
        }

        if (right_ind >= @as(isize, @intCast(left_ind))) {
            for (left_ind..@as(usize, @intCast(right_ind)) + 1) |m| mask[m] = true;
        }
    }
    return mask;
}

/// `FrequencyResponse.find_rtl_start`. Where the right to left pass begins;
/// nothing left of it is limited on that pass.
pub fn findRtlStart(y: []const f64, peak_inds: []const usize, dip_inds: []const usize) usize {
    const n = y.len;
    // With neither peaks nor dips upstream would raise IndexError, but it
    // never gets here: `equalize` takes its flat-line branch first.
    if (peak_inds.len == 0 and dip_inds.len == 0) return n - 1;
    if (peak_inds.len != 0 and (dip_inds.len == 0 or peak_inds[peak_inds.len - 1] > dip_inds[dip_inds.len - 1])) {
        // The last extreme is a peak. Start where the curve next falls back
        // to the level of the last dip.
        const last_peak = peak_inds[peak_inds.len - 1];
        const level = if (dip_inds.len != 0) y[dip_inds[dip_inds.len - 1]] else @max(y[0], y[n - 1]);
        for (last_peak..n) |i| {
            if (y[i] <= level) return i;
        }
        return n - 1;
    }
    return dip_inds[dip_inds.len - 1];
}

const Region = struct { start: usize, end: ?usize };

/// `FrequencyResponse.limited_ltr_slope`. Walks left to right holding the
/// rise to `max_slope` dB per octave.
///
/// A clipped run that never touches a detected peak is rolled back: the
/// limiter only exists to tame peaks, and clipping a stretch with no peak
/// in it would just tilt the curve for no reason.
pub fn limitedLtrSlope(
    allocator: std.mem.Allocator,
    x: []const f64,
    y: []const f64,
    start_index: usize,
    peak_inds: ?[]const usize,
    limit_free_mask: ?[]const bool,
    opts: Options,
    limited: []f64,
    clipped: []bool,
) !void {
    try walkSlope(allocator, x, y, start_index, peak_inds, limit_free_mask, opts, false, limited, clipped);
}

/// The walk behind both limiters. `reversed` says `y` runs high to low in
/// frequency against a still ascending `x`, as `limitedRtlSlope` hands it
/// over, so the concha window has to read the frequency from the other end.
fn walkSlope(
    allocator: std.mem.Allocator,
    x: []const f64,
    y: []const f64,
    start_index: usize,
    peak_inds: ?[]const usize,
    limit_free_mask: ?[]const bool,
    opts: Options,
    reversed: bool,
    limited: []f64,
    clipped: []bool,
) !void {
    std.debug.assert(x.len == y.len);
    std.debug.assert(x.len == limited.len);
    std.debug.assert(x.len == clipped.len);

    var regions: std.ArrayList(Region) = .empty;
    defer regions.deinit(allocator);

    for (0..x.len) |i| {
        if (i <= start_index) {
            limited[i] = y[i];
            clipped[i] = false;
            continue;
        }

        const slope = util.logLogGradient(x[i], x[i - 1], y[i], limited[i - 1]);
        const fi = if (reversed) x[x.len - 1 - i] else x[i];
        var local_limit = if (opts.concha_interference and fi >= 8000.0 and fi <= 11500.0)
            opts.max_slope / 4.0
        else
            opts.max_slope;

        if (clipped[i - 1]) {
            const region_start = regions.items[regions.items.len - 1].start;
            local_limit *= math.pow(f64, 1.0 - opts.max_slope_decay, math.log2(x[i] / x[region_start]));
        }

        const free = if (limit_free_mask) |m| m[i] else false;
        if (slope > local_limit and !free) {
            if (!clipped[i - 1]) try regions.append(allocator, .{ .start = i, .end = null });
            clipped[i] = true;
            const octaves = @log(x[i] / x[i - 1]) / @log(2.0);
            limited[i] = limited[i - 1] + local_limit * octaves;
            continue;
        }

        limited[i] = y[i];
        if (clipped[i - 1]) {
            const last = &regions.items[regions.items.len - 1];
            last.end = i + 1;
            const region_start = last.start;
            var touches_peak = true;
            if (peak_inds) |pk| {
                touches_peak = false;
                for (pk) |p| {
                    if (p >= region_start and p < i) {
                        touches_peak = true;
                        break;
                    }
                }
            }
            if (!touches_peak) {
                for (region_start..i) |k| {
                    limited[k] = y[k];
                    clipped[k] = false;
                }
                _ = regions.pop();
            }
        }
        clipped[i] = false;
    }
}

/// `FrequencyResponse.limited_rtl_slope`: the same walk over reversed data.
///
/// Upstream reverses `y`, the peak indices, the mask and the start index,
/// but leaves the frequency axis ascending. On the log-uniform grid every
/// step and every distance the walk measures comes out the same either way,
/// so that is reproduced as written. The one place it reads a frequency
/// outright is the concha window, which upstream therefore applies at the
/// mirrored 35 to 50 Hz on this pass. turboEQ applies it at 8 to 11.5 kHz,
/// where the flag says it belongs.
pub fn limitedRtlSlope(
    allocator: std.mem.Allocator,
    x: []const f64,
    y: []const f64,
    start_index: usize,
    peak_inds: ?[]const usize,
    limit_free_mask: ?[]const bool,
    opts: Options,
    limited: []f64,
    clipped: []bool,
) !void {
    const n = x.len;

    const flipped_y = try allocator.alloc(f64, n);
    defer allocator.free(flipped_y);
    for (flipped_y, 0..) |*v, i| v.* = y[n - 1 - i];

    var flipped_peaks: ?[]usize = null;
    defer if (flipped_peaks) |p| allocator.free(p);
    if (peak_inds) |pk| {
        const p = try allocator.alloc(usize, pk.len);
        for (pk, p) |src, *dst| dst.* = n - src - 1;
        flipped_peaks = p;
    }

    var flipped_mask: ?[]bool = null;
    defer if (flipped_mask) |m| allocator.free(m);
    if (limit_free_mask) |mask| {
        const m = try allocator.alloc(bool, n);
        for (m, 0..) |*v, i| v.* = mask[n - 1 - i];
        flipped_mask = m;
    }

    try walkSlope(
        allocator,
        x,
        flipped_y,
        n - start_index - 1,
        flipped_peaks,
        flipped_mask,
        opts,
        true,
        limited,
        clipped,
    );

    std.mem.reverse(f64, limited);
    std.mem.reverse(bool, clipped);
}

test "the slope limiter clips a rise that is too steep" {
    const allocator = std.testing.allocator;
    // One octave per sample, so a step in dB is a slope in dB per octave.
    // Reference values are from upstream's own limited_ltr_slope.
    var x: [8]f64 = undefined;
    for (&x, 0..) |*v, i| v.* = 100.0 * math.pow(f64, 2.0, @floatFromInt(i));
    const y = [_]f64{ 0, 0, 30, 0, 0, 0, 0, 0 };
    const peak_inds = [_]usize{2};

    var limited: [8]f64 = undefined;
    var clipped: [8]bool = undefined;
    try limitedLtrSlope(allocator, &x, &y, 0, &peak_inds, null, .{}, &limited, &clipped);

    const want = [_]f64{ 0, 0, 18, 0, 0, 0, 0, 0 };
    for (want, limited) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-9);
    const want_clipped = [_]bool{ false, false, true, false, false, false, false, false };
    try std.testing.expectEqualSlices(bool, &want_clipped, &clipped);
}

test "the right-to-left concha allowance sits at 8 to 11.5 kHz" {
    const allocator = std.testing.allocator;
    // Quarter octaves from 20 Hz: indices 35 and 36 fall in the concha
    // window, and their mirrors, 5 and 4, at 48 and 40 Hz. A fall from a
    // peak at index 34 into the window is a rise on the right-to-left walk.
    var x: [41]f64 = undefined;
    for (&x, 0..) |*v, i| v.* = 20.0 * math.pow(f64, 2.0, @as(f64, @floatFromInt(i)) / 4.0);
    var y = [_]f64{0} ** 41;
    y[34] = 12;
    y[35] = 6;
    const peak_inds = [_]usize{34};

    var limited: [41]f64 = undefined;
    var clipped: [41]bool = undefined;
    const opts: Options = .{ .concha_interference = true };
    try limitedRtlSlope(allocator, &x, &y, 40, &peak_inds, null, opts, &limited, &clipped);

    // 24 dB per octave into index 35 clips to a quarter of 18, and index
    // 34, outside the window, climbs at the full 18 from there. Upstream
    // gives 4.5 and 9, having spent the quarter allowance at 48 Hz.
    try std.testing.expectApproxEqAbs(@as(f64, 1.125), limited[35], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5.625), limited[34], 1e-12);
    try std.testing.expect(clipped[35] and clipped[34] and !clipped[33]);
}

test "a clipped run that touches no peak is rolled back" {
    const allocator = std.testing.allocator;
    var x: [8]f64 = undefined;
    for (&x, 0..) |*v, i| v.* = 100.0 * math.pow(f64, 2.0, @floatFromInt(i));
    const y = [_]f64{ 0, 0, 30, 0, 0, 0, 0, 0 };
    const none = [_]usize{};

    var limited: [8]f64 = undefined;
    var clipped: [8]bool = undefined;
    try limitedLtrSlope(allocator, &x, &y, 0, &none, null, .{}, &limited, &clipped);

    for (y, limited) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-12);
    for (clipped) |c| try std.testing.expect(!c);
}

test "the limiter leaves protected indices alone" {
    const allocator = std.testing.allocator;
    var x: [8]f64 = undefined;
    for (&x, 0..) |*v, i| v.* = 100.0 * math.pow(f64, 2.0, @floatFromInt(i));
    const y = [_]f64{ 0, 0, 30, 0, 0, 0, 0, 0 };
    const peak_inds = [_]usize{2};
    const mask = [_]bool{ false, false, true, false, false, false, false, false };

    var limited: [8]f64 = undefined;
    var clipped: [8]bool = undefined;
    try limitedLtrSlope(allocator, &x, &y, 0, &peak_inds, &mask, .{}, &limited, &clipped);

    for (y, limited) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-12);
    for (clipped) |c| try std.testing.expect(!c);
}
