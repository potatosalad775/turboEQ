//! Peak detection with scipy's exact semantics.
//!
//! `scipy.signal.find_peaks` is not "where the derivative changes sign". It
//! has specific answers for flat tops, for how far a peak's base search
//! runs, and for which index it reports. The pipeline's dip protection and
//! slope limiter both key off these indices, so an off-by-one here moves
//! whole regions of the equalization curve.
//!
//! Ports `_local_maxima_1d` and `peak_prominences` from
//! scipy/signal/_peak_finding_utils.pyx.
//!
//! Derived from SciPy (BSD-3-Clause, SciPy Developers). See NOTICE.

const std = @import("std");

pub const Peak = struct {
    /// Reported peak position. For a flat top this is the midpoint of the
    /// plateau, rounded down.
    index: usize,
    /// Height above the higher of the two bounding minima.
    prominence: f64,
    /// Index of the lowest sample reached walking left and right until the
    /// curve rises above the peak, or the array ends.
    left_base: usize,
    right_base: usize,
};

/// Local maxima, as `_local_maxima_1d` finds them. The first and last
/// samples can never be peaks, and a plateau is reported once at its
/// midpoint.
pub fn localMaxima(allocator: std.mem.Allocator, y: []const f64) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);
    if (y.len < 3) return out.toOwnedSlice(allocator);

    const i_max = y.len - 1;
    var i: usize = 1;
    while (i < i_max) : (i += 1) {
        if (y[i - 1] >= y[i]) continue;
        // Walk across any plateau at this level.
        var i_ahead = i + 1;
        while (i_ahead < i_max and y[i_ahead] == y[i]) i_ahead += 1;
        if (y[i_ahead] < y[i]) {
            const left_edge = i;
            const right_edge = i_ahead - 1;
            try out.append(allocator, (left_edge + right_edge) / 2);
            i = i_ahead;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// `peak_prominences` with `wlen=None`: the base search runs to the ends of
/// the array, stopping only where the curve rises above the peak.
pub fn prominence(y: []const f64, peak: usize) struct { value: f64, left_base: usize, right_base: usize } {
    const height = y[peak];

    var left_base = peak;
    var left_min = height;
    var i: isize = @intCast(peak);
    while (i >= 0 and y[@intCast(i)] <= height) : (i -= 1) {
        const v = y[@intCast(i)];
        if (v < left_min) {
            left_min = v;
            left_base = @intCast(i);
        }
    }

    var right_base = peak;
    var right_min = height;
    var j: usize = peak;
    while (j < y.len and y[j] <= height) : (j += 1) {
        if (y[j] < right_min) {
            right_min = y[j];
            right_base = j;
        }
    }

    return .{
        .value = height - @max(left_min, right_min),
        .left_base = left_base,
        .right_base = right_base,
    };
}

/// `find_peaks(y, prominence=min_prominence)`. Returns the peaks that clear
/// the threshold, in ascending index order.
pub fn find(
    allocator: std.mem.Allocator,
    y: []const f64,
    min_prominence: f64,
) ![]Peak {
    const maxima = try localMaxima(allocator, y);
    defer allocator.free(maxima);

    var out: std.ArrayList(Peak) = .empty;
    errdefer out.deinit(allocator);
    for (maxima) |m| {
        const p = prominence(y, m);
        if (p.value >= min_prominence) {
            try out.append(allocator, .{
                .index = m,
                .prominence = p.value,
                .left_base = p.left_base,
                .right_base = p.right_base,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Just the indices, which is all the equalizer stage needs.
pub fn findIndices(
    allocator: std.mem.Allocator,
    y: []const f64,
    min_prominence: f64,
) ![]usize {
    const found = try find(allocator, y, min_prominence);
    defer allocator.free(found);
    const out = try allocator.alloc(usize, found.len);
    for (found, out) |p, *o| o.* = p.index;
    return out;
}

test "a plateau is reported at its midpoint" {
    const allocator = std.testing.allocator;
    const y = [_]f64{ 0, 1, 2, 2, 2, 2, 1, 0 };
    const m = try localMaxima(allocator, &y);
    defer allocator.free(m);
    try std.testing.expectEqualSlices(usize, &.{3}, m);
}

test "the first and last samples are never peaks" {
    const allocator = std.testing.allocator;
    const y = [_]f64{ 5, 1, 2, 1, 5 };
    const m = try localMaxima(allocator, &y);
    defer allocator.free(m);
    try std.testing.expectEqualSlices(usize, &.{2}, m);
}

test "the base search runs past intervening peaks" {
    // scipy.signal.peak_prominences([0,3,2,5,0,4,0], [3]) -> 5.0, bases 0 and 4.
    // The walk only stops where the curve rises ABOVE the peak, so the dip at
    // index 2 does not bound it and the base reaches all the way to 0.
    const y = [_]f64{ 0, 3, 2, 5, 0, 4, 0 };
    const p = prominence(&y, 3);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), p.value, 1e-12);
    try std.testing.expectEqual(@as(usize, 0), p.left_base);
    try std.testing.expectEqual(@as(usize, 4), p.right_base);
}

test "find filters on prominence" {
    const allocator = std.testing.allocator;
    // scipy.signal.find_peaks(y, prominence=1) -> [3, 5]; prominence=0 -> [1, 3, 5].
    // Index 1 is bounded on the right by the higher peak at 3, which leaves
    // it a prominence of 0.5.
    const y = [_]f64{ 0, 3, 2.5, 3.2, 0, 8, 0 };
    const strong = try findIndices(allocator, &y, 1.0);
    defer allocator.free(strong);
    try std.testing.expectEqualSlices(usize, &.{ 3, 5 }, strong);
    const all = try findIndices(allocator, &y, 0.0);
    defer allocator.free(all);
    try std.testing.expectEqualSlices(usize, &.{ 1, 3, 5 }, all);
}

/// `peak_widths`, from scipy/signal/_peak_finding_utils.pyx.
///
/// The width is measured at `peak - prominence * rel_height`, walking out
/// from the peak until the curve drops below that level or the prominence
/// base is reached, then interpolating linearly between the two straddling
/// samples. `find_peaks(..., width=0)` calls it with `rel_height=0.5`, which
/// is what the filter init heuristics want.
pub fn width(y: []const f64, peak: usize, prom: f64, left_base: usize, right_base: usize, rel_height: f64) f64 {
    const c = crossings(y, peak, prom, left_base, right_base, rel_height);
    return c.right - c.left;
}

/// `left_ips` and `right_ips`: where the curve crosses the measuring height
/// on each side of the peak, in fractional samples.
pub fn crossings(
    y: []const f64,
    peak: usize,
    prom: f64,
    left_base: usize,
    right_base: usize,
    rel_height: f64,
) struct { left: f64, right: f64 } {
    const height = y[peak] - prom * rel_height;

    var i = peak;
    while (left_base < i and height < y[i]) i -= 1;
    var left_ip: f64 = @floatFromInt(i);
    if (y[i] < height) {
        // The true crossing sits between i and i+1.
        left_ip += (height - y[i]) / (y[i + 1] - y[i]);
    }

    var j = peak;
    while (j < right_base and height < y[j]) j += 1;
    var right_ip: f64 = @floatFromInt(j);
    if (y[j] < height) {
        right_ip -= (height - y[j]) / (y[j - 1] - y[j]);
    }

    return .{ .left = left_ip, .right = right_ip };
}

/// One entry per local maximum, carrying everything the filter init
/// heuristics rank peaks by. This is `find_peaks(y, width=0, prominence=0,
/// height=0)`: no peak is ever filtered out, because every property clears a
/// threshold of zero.
pub const Measured = struct {
    index: usize,
    /// `peak_heights`, the sample value at the peak.
    height: f64,
    prominence: f64,
    /// `widths` at `rel_height=0.5`, in samples.
    width: f64,
};

/// `find_peaks(y, width=0, prominence=0, height=0)`.
pub fn measure(allocator: std.mem.Allocator, y: []const f64) ![]Measured {
    const maxima = try localMaxima(allocator, y);
    defer allocator.free(maxima);

    const out = try allocator.alloc(Measured, maxima.len);
    errdefer allocator.free(out);
    for (maxima, out) |m, *o| {
        const p = prominence(y, m);
        o.* = .{
            .index = m,
            .height = y[m],
            .prominence = p.value,
            .width = width(y, m, p.value, p.left_base, p.right_base, 0.5),
        };
    }
    return out;
}

/// A peak of the reflected curve, with how much of its width lies on the
/// curve itself.
pub const Reflected = struct {
    peak: Measured,
    /// The part of `peak.width` between the first and last sample. Equal to
    /// it for a peak clear of both ends, half of it for one at an end sample.
    inside: f64,
};

/// `measure` on the curve reflected about its first sample, its last, or
/// both, reporting the peaks that fall on the curve itself.
///
/// `find_peaks` never reports an end sample, and a peak one or two samples in
/// from an end has its base search cut off there, which leaves it next to no
/// prominence and so next to no width. Either way a ramp that tops out at
/// 20 Hz or 20 kHz offers `init()` nothing to seed a band on. Reflected, the
/// ramp is the near half of a peak centred on the end, and measures as one. A
/// peak clear of the reflected ends comes out exactly as `measure` has it.
///
/// Not upstream.
pub fn measureReflected(
    allocator: std.mem.Allocator,
    y: []const f64,
    low: bool,
    high: bool,
) ![]Reflected {
    const n = y.len;
    if (n < 3) return allocator.alloc(Reflected, 0);
    const pad_low: usize = if (low) n - 1 else 0;
    const pad_high: usize = if (high) n - 1 else 0;

    const padded = try allocator.alloc(f64, pad_low + n + pad_high);
    defer allocator.free(padded);
    for (0..pad_low) |i| padded[i] = y[pad_low - i];
    @memcpy(padded[pad_low..][0..n], y);
    for (0..pad_high) |i| padded[pad_low + n + i] = y[n - 2 - i];

    const maxima = try localMaxima(allocator, padded);
    defer allocator.free(maxima);

    var out: std.ArrayList(Reflected) = .empty;
    errdefer out.deinit(allocator);
    const first: f64 = @floatFromInt(pad_low);
    const last: f64 = @floatFromInt(pad_low + n - 1);
    for (maxima) |m| {
        if (m < pad_low or m > pad_low + n - 1) continue;
        const p = prominence(padded, m);
        const c = crossings(padded, m, p.value, p.left_base, p.right_base, 0.5);
        try out.append(allocator, .{
            .peak = .{
                .index = m - pad_low,
                .height = padded[m],
                .prominence = p.value,
                .width = c.right - c.left,
            },
            .inside = @min(c.right, last) - @max(c.left, first),
        });
    }
    return out.toOwnedSlice(allocator);
}

test "a ramp to the first sample measures as half of a peak centred there" {
    const allocator = std.testing.allocator;
    // Reflected about index 0 this is [0,0,1,2,1,0,0], whose one peak scipy
    // gives a width of 2.0 at half prominence. `measure` finds nothing.
    const y = [_]f64{ 2, 1, 0, 0 };
    const plain = try measure(allocator, &y);
    defer allocator.free(plain);
    try std.testing.expectEqual(@as(usize, 0), plain.len);

    const r = try measureReflected(allocator, &y, true, false);
    defer allocator.free(r);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqual(@as(usize, 0), r[0].peak.index);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), r[0].peak.width, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r[0].inside, 1e-12);

    const other_end = try measureReflected(allocator, &y, false, true);
    defer allocator.free(other_end);
    try std.testing.expectEqual(@as(usize, 0), other_end.len);
}

test "a shoulder one sample in from the end gets its width back" {
    const allocator = std.testing.allocator;
    // The peak at index 1 has a left base 0.1 below it, so 0.1 of prominence
    // and a sliver of width. Reflected, the base is the far side of the ramp.
    const y = [_]f64{ 4.9, 5, 4, 3, 2, 1, 0, 0 };
    const plain = try measure(allocator, &y);
    defer allocator.free(plain);
    try std.testing.expect(plain[0].width < 1.0);

    const r = try measureReflected(allocator, &y, true, false);
    defer allocator.free(r);
    try std.testing.expectEqual(@as(usize, 1), r[0].peak.index);
    try std.testing.expect(r[0].peak.width > 5.0);
}

test "a peak clear of the ends measures the same reflected" {
    const allocator = std.testing.allocator;
    const y = [_]f64{ 0, 3, 2.5, 3.2, 0, 8, 0 };
    const plain = try measure(allocator, &y);
    defer allocator.free(plain);
    const r = try measureReflected(allocator, &y, true, true);
    defer allocator.free(r);
    try std.testing.expectEqual(plain.len, r.len);
    for (plain, r) |a, b| {
        try std.testing.expectEqual(a.index, b.peak.index);
        try std.testing.expectApproxEqAbs(a.prominence, b.peak.prominence, 1e-12);
        try std.testing.expectApproxEqAbs(a.width, b.peak.width, 1e-12);
        try std.testing.expectApproxEqAbs(a.width, b.inside, 1e-12);
    }
}

test "width is measured at half prominence" {
    // scipy.signal.peak_widths([0,1,2,1,0], [2], rel_height=0.5) -> 2.0
    const y = [_]f64{ 0, 1, 2, 1, 0 };
    const p = prominence(&y, 2);
    try std.testing.expectApproxEqAbs(
        @as(f64, 2.0),
        width(&y, 2, p.value, p.left_base, p.right_base, 0.5),
        1e-12,
    );
}

test "measure reports every local maximum" {
    const allocator = std.testing.allocator;
    // scipy.signal.find_peaks(y, width=0, prominence=0, height=0) over this
    // array returns peaks [1, 3, 5] with heights [3, 3.2, 8].
    const y = [_]f64{ 0, 3, 2.5, 3.2, 0, 8, 0 };
    const m = try measure(allocator, &y);
    defer allocator.free(m);
    try std.testing.expectEqual(@as(usize, 3), m.len);
    try std.testing.expectEqual(@as(usize, 1), m[0].index);
    try std.testing.expectApproxEqAbs(@as(f64, 3.2), m[1].height, 1e-12);
    for (m) |p| try std.testing.expect(p.width > 0);
}
