//! Small numeric helpers shared by every stage.
//!
//! Each one mirrors a specific upstream function; the names in the doc
//! comments are the AutoEq originals so a reader can diff them by eye.
//! Derived from AutoEq (MIT, Jaakko Pasanen), autoeq/utils.py.

const std = @import("std");
const math = std.math;

/// numpy's `argmin(abs(arr - x))`: the *first* index attaining the minimum.
pub fn argminAbs(arr: []const f64, x: f64) usize {
    var best: usize = 0;
    var best_d = math.inf(f64);
    for (arr, 0..) |v, i| {
        const d = @abs(v - x);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

/// Round half to even, which is what Python's `round()` and `np.round()` do.
/// `@round` rounds half away from zero, so it is not a substitute.
pub fn roundHalfEven(x: f64) f64 {
    const f = @floor(x);
    const frac = x - f;
    if (frac > 0.5) return f + 1;
    if (frac < 0.5) return f;
    return if (@mod(f, 2.0) == 0.0) f else f + 1;
}

/// scipy.special.expit, the logistic function, in the branch-split form that
/// avoids overflowing `exp` for large negative input.
pub fn expit(x: f64) f64 {
    if (x >= 0) return 1.0 / (1.0 + @exp(-x));
    const e = @exp(x);
    return e / (1.0 + e);
}

/// `utils.generate_frequencies`. Repeated multiplication, not `pow`, because
/// the accumulated rounding is part of the grid upstream produces.
pub fn generateFrequencies(
    allocator: std.mem.Allocator,
    f_min: f64,
    f_max: f64,
    f_step: f64,
) ![]f64 {
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(allocator);
    var f = f_min;
    while (f <= f_max) : (f *= f_step) {
        try out.append(allocator, f);
    }
    return out.toOwnedSlice(allocator);
}

/// `utils.smoothing_window_size`. The window is derived from the *average*
/// frequency ratio across the whole array, never a per-point ratio.
pub fn smoothingWindowSize(f: []const f64, octaves: f64) usize {
    return @intFromFloat(smoothingWindowLength(f, octaves));
}

/// `smoothingWindowSize` before the cast, so a caller can check the length
/// first: a negative, infinite or NaN one has no integer to become.
pub fn smoothingWindowLength(f: []const f64, octaves: f64) f64 {
    const k = math.pow(f64, 2.0, octaves);
    var sum: f64 = 0.0;
    var i: usize = 1;
    while (i < f.len) : (i += 1) sum += f[i] / f[i - 1];
    const step_size = sum / @as(f64, @floatFromInt(f.len - 1));
    var n = roundHalfEven(@log(k) / @log(step_size));
    if (@mod(n, 2.0) == 0.0) n += 1;
    return n;
}

/// `utils.log_f_sigmoid`. Blends `a_normal` into `a_treble` across the
/// transition band, on a log frequency axis.
pub fn logFSigmoid(
    f: []const f64,
    f_lower: f64,
    f_upper: f64,
    a_normal: f64,
    a_treble: f64,
    out: []f64,
) void {
    std.debug.assert(out.len == f.len);
    const center_hz = @sqrt(f_upper / f_lower) * f_lower;
    const f_center = math.log10(center_hz);
    const half_range = math.log10(f_upper) - f_center;
    for (f, out) |fv, *o| {
        const a = expit((math.log10(fv) - f_center) / (half_range / 4));
        o.* = a * -(a_normal - a_treble) + a_normal;
    }
}

/// `utils.log_tilt`. Slope in dB per octave about the log-centre of 20 Hz to
/// 20 kHz.
pub fn logTilt(f: []const f64, steepness: f64, out: []f64) void {
    std.debug.assert(out.len == f.len);
    const c = 20.0 * @sqrt(20000.0 / 20.0);
    for (f, out) |fv, *o| o.* = math.log2(fv / c) * steepness;
}

/// `utils.log_log_gradient`, in dB per octave.
pub fn logLogGradient(f0: f64, f1: f64, g0: f64, g1: f64) f64 {
    const octaves = @log(f1 / f0) / @log(2.0);
    return (g1 - g0) / octaves;
}

/// Linear interpolation at one point, matching
/// `InterpolatedUnivariateSpline(..., k=1)`: outside the source range it
/// extrapolates along the first or last segment rather than clamping.
///
/// `src_x` must be strictly increasing and hold at least two points.
pub fn interpLinearAt(src_x: []const f64, src_y: []const f64, x: f64) f64 {
    std.debug.assert(src_x.len >= 2);
    const seg = segmentFor(src_x, x);
    const x0 = src_x[seg];
    const x1 = src_x[seg + 1];
    const y0 = src_y[seg];
    const y1 = src_y[seg + 1];
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
}

/// Index of the segment `[i, i+1]` covering `x`, clamped to the ends so that
/// out-of-range input extrapolates along the terminal segment.
fn segmentFor(src_x: []const f64, x: f64) usize {
    const last = src_x.len - 2;
    // Upper bound: first index whose value is strictly greater than x.
    var lo: usize = 0;
    var hi: usize = src_x.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (src_x[mid] <= x) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return 0;
    return @min(lo - 1, last);
}

test "roundHalfEven breaks ties toward even" {
    try std.testing.expectEqual(@as(f64, 2.0), roundHalfEven(2.5));
    try std.testing.expectEqual(@as(f64, 4.0), roundHalfEven(3.5));
    try std.testing.expectEqual(@as(f64, -2.0), roundHalfEven(-2.5));
    try std.testing.expectEqual(@as(f64, 3.0), roundHalfEven(2.7));
}

test "interpLinearAt extrapolates along the terminal segments" {
    // Same values scipy's InterpolatedUnivariateSpline(k=1) returns for this
    // data, including the two queries outside the knot range.
    const x = [_]f64{ 1.0, 2.0, 3.0, 5.0 };
    const y = [_]f64{ 10.0, 12.0, 9.0, 1.0 };
    const q = [_]f64{ -3.0, 1.5, 3.0, 4.0, 7.0 };
    const want = [_]f64{ 2.0, 11.0, 9.0, 5.0, -7.0 };
    for (q, want) |query, w| {
        try std.testing.expectApproxEqAbs(w, interpLinearAt(&x, &y, query), 1e-12);
    }
}

test "generateFrequencies matches the 1.01 grid extent" {
    const f = try generateFrequencies(std.testing.allocator, 20.0, 20000.0, 1.01);
    defer std.testing.allocator.free(f);
    try std.testing.expectEqual(@as(f64, 20.0), f[0]);
    try std.testing.expect(f[f.len - 1] <= 20000.0);
    try std.testing.expect(f[f.len - 1] * 1.01 > 20000.0);
}
