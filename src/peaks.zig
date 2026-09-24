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

    return right_ip - left_ip;
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
