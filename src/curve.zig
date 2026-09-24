//! Curve preparation.
//!
//! Resample onto upstream's own log grid, remove the level bias, and build
//! the target and error curves. Everything downstream assumes a curve that
//! has been through here.
//!
//! Derived from AutoEq (MIT, Jaakko Pasanen), autoeq/frequency_response.py.

const std = @import("std");
const math = std.math;
const util = @import("util.zig");
const biquad = @import("biquad.zig");
const savgol = @import("savgol.zig");

/// `DEFAULT_F_MIN`, `DEFAULT_F_MAX`, `DEFAULT_STEP`. Upstream's working grid,
/// roughly 1/70 octave.
pub const f_min: f64 = 20.0;
pub const f_max: f64 = 20000.0;
pub const f_step: f64 = 1.01;

/// `DEFAULT_BIQUAD_OPTIMIZATION_F_STEP`. The optimizer runs on a coarser grid
/// than the pipeline does.
pub const optimizer_f_step: f64 = 1.02;

/// Upstream's default working grid, freshly allocated.
pub fn standardGrid(allocator: std.mem.Allocator) ![]f64 {
    return util.generateFrequencies(allocator, f_min, f_max, f_step);
}

/// `FrequencyResponse.interpolate`. Linear in log10(f), matching
/// `InterpolatedUnivariateSpline(k=1)` despite the class name.
pub fn interpolate(
    allocator: std.mem.Allocator,
    src_f: []const f64,
    src_y: []const f64,
    dst_f: []const f64,
    out: []f64,
) !void {
    std.debug.assert(src_f.len == src_y.len);
    std.debug.assert(dst_f.len == out.len);
    const log_src = try allocator.alloc(f64, src_f.len);
    defer allocator.free(log_src);
    for (src_f, log_src) |fv, *l| l.* = math.log10(fv);
    for (dst_f, out) |x, *o| {
        // Upstream substitutes a small value for a zero frequency so that
        // log10 does not explode.
        const xf = if (x == 0.0) 0.001 else x;
        o.* = util.interpLinearAt(log_src, src_y, math.log10(xf));
    }
}

/// `FrequencyResponse.center`. Returns the shift applied, in dB, which is
/// what upstream returns; the caller adds it to `raw`.
///
/// Upstream resamples a copy onto the default grid before reading the level
/// at `at_hz`, so a curve arriving on a coarser grid is centred on the
/// interpolated value rather than on its own nearest sample. Reproduced.
pub fn centerShift(
    allocator: std.mem.Allocator,
    f: []const f64,
    raw: []const f64,
    at_hz: f64,
) !f64 {
    const grid = try standardGrid(allocator);
    defer allocator.free(grid);
    const resampled = try allocator.alloc(f64, grid.len);
    defer allocator.free(resampled);
    try interpolate(allocator, f, raw, grid, resampled);

    const log_grid = try allocator.alloc(f64, grid.len);
    defer allocator.free(log_grid);
    for (grid, log_grid) |fv, *l| l.* = math.log10(fv);

    const diff = util.interpLinearAt(log_grid, resampled, math.log10(at_hz));
    return -diff;
}

/// Centre a curve in place at `at_hz` and return the shift applied.
pub fn center(
    allocator: std.mem.Allocator,
    f: []const f64,
    raw: []f64,
    at_hz: f64,
) !f64 {
    const shift = try centerShift(allocator, f, raw, at_hz);
    for (raw) |*v| v.* += shift;
    return shift;
}

/// `create_target` inputs. The shipped defaults are all neutral, which makes
/// the whole curve exactly zero; they exist so a caller can ask for a bass
/// shelf or a tilt without reaching into the pipeline.
pub const TargetOptions = struct {
    bass_boost_gain: f64 = 0.0,
    bass_boost_fc: f64 = 105.0,
    bass_boost_q: f64 = 0.7,
    treble_boost_gain: f64 = 0.0,
    treble_boost_fc: f64 = 10000.0,
    treble_boost_q: f64 = 0.7,
    /// dB per octave. Null disables the tilt term entirely.
    tilt: ?f64 = 0.0,
};

/// `FrequencyResponse.create_target`: bass shelf plus treble shelf plus tilt.
pub fn createTarget(
    f: []const f64,
    fs: f64,
    opts: TargetOptions,
    out: []f64,
    scratch: []f64,
) void {
    std.debug.assert(out.len == f.len);
    std.debug.assert(scratch.len == f.len);
    const bass = biquad.Filter{
        .kind = .low_shelf,
        .fc = opts.bass_boost_fc,
        .q = opts.bass_boost_q,
        .gain = opts.bass_boost_gain,
    };
    const treble = biquad.Filter{
        .kind = .high_shelf,
        .fc = opts.treble_boost_fc,
        .q = opts.treble_boost_q,
        .gain = opts.treble_boost_gain,
    };
    bass.response(f, fs, out);
    treble.response(f, fs, scratch);
    for (out, scratch) |*o, s| o.* += s;
    if (opts.tilt) |steepness| {
        util.logTilt(f, steepness, scratch);
        for (out, scratch) |*o, s| o.* += s;
    }
}

pub const CompensateOptions = struct {
    target: TargetOptions = .{},
    fs: f64,
    /// When set, the error is shifted by its own mean across 100 Hz to
    /// 10 kHz instead of being pinned at a single frequency. Upstream's
    /// preference, and turboEQ's default.
    min_mean_error: bool = true,
    /// A sound signature already on `f`, added to the target curve — a
    /// deliberate colouration the fit should aim at rather than correct.
    ///
    /// Upstream interpolates it onto the working grid and optionally smooths
    /// it before this point, and notably does **not** centre it the way it
    /// centres the target: a signature that sits 3 dB up everywhere is a
    /// 3 dB boost, not a no-op. `prepareSoundSignature` does that half.
    sound_signature: ?[]const f64 = null,
};

/// `FrequencyResponse.compensate`. `target_raw` must already be interpolated
/// onto `f` and centred; see `prepareTarget`.
pub fn compensate(
    f: []const f64,
    raw: []const f64,
    target_raw: []const f64,
    opts: CompensateOptions,
    out_target: []f64,
    out_error: []f64,
) void {
    std.debug.assert(f.len == raw.len);
    std.debug.assert(f.len == target_raw.len);
    std.debug.assert(f.len == out_target.len);
    std.debug.assert(f.len == out_error.len);

    createTarget(f, opts.fs, opts.target, out_target, out_error);
    for (out_target, target_raw) |*t, tr| t.* += tr;
    if (opts.sound_signature) |signature| {
        std.debug.assert(signature.len == f.len);
        for (out_target, signature) |*t, v| t.* += v;
    }
    for (out_error, raw, out_target) |*e, r, t| e.* = r - t;

    if (!opts.min_mean_error) return;

    var sum: f64 = 0.0;
    var n: usize = 0;
    for (f, out_error) |fv, e| {
        if (fv >= 100.0 and fv <= 10000.0) {
            sum += e;
            n += 1;
        }
    }
    if (n == 0) return;
    const delta = sum / @as(f64, @floatFromInt(n));
    for (out_error) |*e| e.* -= delta;
    for (out_target) |*t| t.* += delta;
}

/// Put a target curve on the working grid the way `compensate` does:
/// interpolate onto `dst_f`, then centre at 1 kHz.
pub fn prepareTarget(
    allocator: std.mem.Allocator,
    target_f: []const f64,
    target_raw: []const f64,
    dst_f: []const f64,
    out: []f64,
) !void {
    try interpolate(allocator, target_f, target_raw, dst_f, out);
    _ = try center(allocator, dst_f, out, 1000.0);
}

/// Put a sound signature on the working grid the way `compensate` does:
/// interpolate onto `dst_f`, then smooth if a window size was asked for.
///
/// Upstream passes the same size as both `window_size` and
/// `treble_window_size`, which collapses `_smoothen`'s sigmoid crossfade
/// between two identical filters into just that one filter. Reproduced, so
/// the treble transition has no effect here — that is the point.
pub fn prepareSoundSignature(
    allocator: std.mem.Allocator,
    signature_f: []const f64,
    signature_raw: []const f64,
    dst_f: []const f64,
    window_size: ?f64,
    out: []f64,
) !void {
    try interpolate(allocator, signature_f, signature_raw, dst_f, out);
    const size = window_size orelse return;
    // `if sound_signature_smoothing_window_size:` — zero is falsy upstream,
    // and so is None.
    if (size == 0.0) return;
    const smoothed = try allocator.alloc(f64, out.len);
    defer allocator.free(smoothed);
    try smoothen(allocator, dst_f, out, .{
        .window_size = size,
        .treble_window_size = size,
    }, smoothed);
    @memcpy(out, smoothed);
}

/// `_smoothen` inputs. The defaults are upstream's: an eighth-octave window
/// over most of the range, widening to two octaves in the treble where
/// measurement peakiness would otherwise drive the optimizer.
pub const SmoothenOptions = struct {
    window_size: f64 = 1.0 / 12.0,
    treble_window_size: f64 = 2.0,
    treble_f_lower: f64 = 6000.0,
    treble_f_upper: f64 = 8000.0,
};

pub const SmoothenError = error{
    /// A window shorter than three samples or longer than the curve. scipy's
    /// `savgol_filter` raises on both; without the check the release build
    /// runs past `savgol.filter`'s asserts and returns NaN.
    BadSmoothingWindow,
};

/// `smoothing_window_size` in samples, refused where scipy would refuse it.
fn windowLength(f: []const f64, octaves: f64) SmoothenError!usize {
    const n = util.smoothingWindowLength(f, octaves);
    const len: f64 = @floatFromInt(f.len);
    if (!(n >= savgol.polyorder + 1 and n <= len)) return error.BadSmoothingWindow;
    return @intFromFloat(n);
}

/// `FrequencyResponse._smoothen`. Two Savitzky-Golay passes at different
/// window widths, cross-faded by a sigmoid on the log frequency axis.
pub fn smoothen(
    allocator: std.mem.Allocator,
    f: []const f64,
    data: []const f64,
    opts: SmoothenOptions,
    out: []f64,
) !void {
    std.debug.assert(f.len == data.len);
    std.debug.assert(f.len == out.len);
    std.debug.assert(opts.treble_f_upper > opts.treble_f_lower);

    const treble = try allocator.alloc(f64, f.len);
    defer allocator.free(treble);
    const k_treble = try allocator.alloc(f64, f.len);
    defer allocator.free(k_treble);

    try savgol.filter(allocator, data, try windowLength(f, opts.window_size), out);
    try savgol.filter(allocator, data, try windowLength(f, opts.treble_window_size), treble);
    util.logFSigmoid(f, opts.treble_f_lower, opts.treble_f_upper, 0.0, 1.0, k_treble);

    for (out, treble, k_treble) |*o, t, k| {
        const k_normal = k * -1.0 + 1.0;
        o.* = o.* * k_normal + t * k;
    }
}

test "a smoothing window scipy would refuse is an error, not NaN" {
    const allocator = std.testing.allocator;
    const f = try standardGrid(allocator);
    defer allocator.free(f);
    const data = try allocator.alloc(f64, f.len);
    defer allocator.free(data);
    @memset(data, 0);
    const out = try allocator.alloc(f64, f.len);
    defer allocator.free(out);

    // One sample, fewer than the three a quadratic fit needs; wider than the
    // whole grid; and a width that is no width at all.
    for ([_]f64{ 1.0 / 48.0, 20.0, -1.0, math.inf(f64) }) |size| {
        try std.testing.expectError(
            error.BadSmoothingWindow,
            smoothen(allocator, f, data, .{ .window_size = size }, out),
        );
        try std.testing.expectError(
            error.BadSmoothingWindow,
            smoothen(allocator, f, data, .{ .treble_window_size = size }, out),
        );
    }
    // The narrowest window that still spans three samples.
    try smoothen(allocator, f, data, .{ .window_size = 1.0 / 40.0, .treble_window_size = 1.0 / 40.0 }, out);
}

test "a neutral target curve is exactly flat" {
    const allocator = std.testing.allocator;
    const f = try standardGrid(allocator);
    defer allocator.free(f);
    const out = try allocator.alloc(f64, f.len);
    defer allocator.free(out);
    const scratch = try allocator.alloc(f64, f.len);
    defer allocator.free(scratch);
    createTarget(f, 44100.0, .{}, out, scratch);
    for (out) |v| try std.testing.expectEqual(@as(f64, 0.0), v);
}

test "centering a flat curve is a no-op" {
    const allocator = std.testing.allocator;
    const f = try standardGrid(allocator);
    defer allocator.free(f);
    const raw = try allocator.alloc(f64, f.len);
    defer allocator.free(raw);
    @memset(raw, 3.25);
    const shift = try center(allocator, f, raw, 1000.0);
    try std.testing.expectApproxEqAbs(@as(f64, -3.25), shift, 1e-12);
    for (raw) |v| try std.testing.expectApproxEqAbs(@as(f64, 0.0), v, 1e-12);
}
