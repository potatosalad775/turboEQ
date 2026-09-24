//! Savitzky-Golay smoothing, matching `scipy.signal.savgol_filter` with
//! `polyorder=2`, `deriv=0` and the default `mode='interp'`.
//!
//! scipy does this in two halves: a convolution with fixed coefficients over
//! the interior, then a separate polynomial fit over the first and last
//! `window_length` samples to cover the edges. Both halves are the same
//! operation underneath, and this file writes them that way: every output
//! sample is a degree-2 least squares fit through a window, read off at one
//! index. `quadFitWeights` produces the weights for that read; the interior
//! reuses one weight vector, the edges need a fresh one per sample.
//!
//! Exact agreement with scipy is not on offer here. Its coefficients come
//! out of a LAPACK least squares solve, so the last bits track the BLAS
//! build. tools/parity holds this stage to 1e-7 dB for that reason.

const std = @import("std");

pub const polyorder = 2;

/// Weights `w` such that `sum(w[j] * y[j])` is the value at `pos` of the
/// degree-2 least squares fit through the `m` equally spaced points
/// `(j, y[j])`, for `j` in `0..m`. `pos` need not be an integer, and need
/// not lie inside the window.
///
/// The fit is solved in a centred, scaled variable `u = (j - c) / s` that
/// runs over -1 to 1. Algebraically that changes nothing; numerically it
/// keeps the 3x3 normal equations well conditioned, which the raw powers of
/// `j` are not once the window reaches the 139 samples the treble pass uses.
pub fn quadFitWeights(m: usize, pos: f64, out: []f64) void {
    std.debug.assert(out.len == m);
    std.debug.assert(m >= polyorder + 1);

    const mf: f64 = @floatFromInt(m);
    const c = (mf - 1.0) / 2.0;
    const s = c;

    // Normal equations. moments[k] = sum_j u_j^k, and the matrix of the
    // system is the Hankel matrix M[p][q] = moments[p + q].
    var moments: [2 * polyorder + 1]f64 = @splat(0.0);
    var j: usize = 0;
    while (j < m) : (j += 1) {
        const u = (@as(f64, @floatFromInt(j)) - c) / s;
        var power: f64 = 1.0;
        for (&moments) |*mom| {
            mom.* += power;
            power *= u;
        }
    }

    var matrix: [polyorder + 1][polyorder + 1]f64 = undefined;
    for (0..polyorder + 1) |p| {
        for (0..polyorder + 1) |q| matrix[p][q] = moments[p + q];
    }

    // Right hand side is the basis evaluated at the query point. Solving
    // `M g = phi(pos)` folds the fit and the read-off into one vector, so
    // the polynomial coefficients never have to be formed.
    const up = (pos - c) / s;
    var g: [polyorder + 1]f64 = .{ 1.0, up, up * up };
    solve3(&matrix, &g);

    j = 0;
    while (j < m) : (j += 1) {
        const u = (@as(f64, @floatFromInt(j)) - c) / s;
        out[j] = g[0] + g[1] * u + g[2] * u * u;
    }
}

/// Gaussian elimination with partial pivoting on a 3x3 system, in place.
/// `b` carries the right hand side in and the solution out.
fn solve3(a: *[polyorder + 1][polyorder + 1]f64, b: *[polyorder + 1]f64) void {
    const n = polyorder + 1;
    for (0..n) |col| {
        var pivot = col;
        for (col + 1..n) |row| {
            if (@abs(a[row][col]) > @abs(a[pivot][col])) pivot = row;
        }
        if (pivot != col) {
            std.mem.swap([n]f64, &a[pivot], &a[col]);
            std.mem.swap(f64, &b[pivot], &b[col]);
        }
        const diag = a[col][col];
        for (col + 1..n) |row| {
            const factor = a[row][col] / diag;
            if (factor == 0.0) continue;
            for (col..n) |k| a[row][k] -= factor * a[col][k];
            b[row] -= factor * b[col];
        }
    }
    var row: usize = n;
    while (row > 0) {
        row -= 1;
        var acc = b[row];
        for (row + 1..n) |k| acc -= a[row][k] * b[k];
        b[row] = acc / a[row][row];
    }
}

/// `savgol_filter(data, window_length, 2)`. `window_length` must be odd and
/// no greater than `data.len`.
pub fn filter(
    allocator: std.mem.Allocator,
    data: []const f64,
    window_length: usize,
    out: []f64,
) !void {
    std.debug.assert(data.len == out.len);
    std.debug.assert(window_length % 2 == 1);
    std.debug.assert(window_length <= data.len);
    std.debug.assert(window_length >= polyorder + 1);

    const weights = try allocator.alloc(f64, window_length);
    defer allocator.free(weights);
    const half = window_length / 2;
    const n = data.len;

    // Interior: one weight vector, slid across.
    quadFitWeights(window_length, @floatFromInt(half), weights);
    var i = half;
    while (i + half < n) : (i += 1) {
        var acc: f64 = 0.0;
        for (weights, data[i - half ..][0..window_length]) |w, y| acc += w * y;
        out[i] = acc;
    }

    // Edges: scipy fits one polynomial to the first `window_length` samples
    // and reads the first `half` outputs off it, then does the same at the
    // far end. Same fit, read at a different index, so the weights change
    // per sample but the window does not.
    const tail = n - window_length;
    i = 0;
    while (i < half) : (i += 1) {
        quadFitWeights(window_length, @floatFromInt(i), weights);
        var head_acc: f64 = 0.0;
        for (weights, data[0..window_length]) |w, y| head_acc += w * y;
        out[i] = head_acc;

        const out_ix = n - half + i;
        quadFitWeights(window_length, @floatFromInt(out_ix - tail), weights);
        var tail_acc: f64 = 0.0;
        for (weights, data[tail..][0..window_length]) |w, y| tail_acc += w * y;
        out[out_ix] = tail_acc;
    }
}

test "interior weights match scipy's savgol_coeffs for a 7 point window" {
    var w: [7]f64 = undefined;
    quadFitWeights(7, 3.0, &w);
    const want = [_]f64{
        -0.09523809523809523, 0.14285714285714304, 0.28571428571428586,
        0.3333333333333336,   0.2857142857142859,  0.14285714285714296,
        -0.09523809523809532,
    };
    for (want, w) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-13);
}

test "a quadratic passes through the filter unchanged" {
    const allocator = std.testing.allocator;
    var data: [40]f64 = undefined;
    for (&data, 0..) |*v, i| {
        const t: f64 = @floatFromInt(i);
        v.* = 3.0 - 0.5 * t + 0.02 * t * t;
    }
    var out: [40]f64 = undefined;
    try filter(allocator, &data, 9, &out);
    for (data, out) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-10);
}

test "edges and interior match scipy on an alternating signal" {
    const allocator = std.testing.allocator;
    // scipy.signal.savgol_filter(x, 5, 2). An alternating signal is the
    // unfriendly case: nothing is locally polynomial, so the edge fits and
    // the interior convolution both have to be right to land here.
    const data = [_]f64{ 0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, -1.0 };
    const want = [_]f64{
        0.40000000000000024, 0.19999999999999954, 0.0,
        -0.6571428571428569, 0.0,                 0.6571428571428569,
        0.0,                 -0.6571428571428569, 0.0,
        0.6571428571428569,  0.22857142857143065, -1.0571428571428567,
    };
    var out: [data.len]f64 = undefined;
    try filter(allocator, &data, 5, &out);
    for (want, out) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-12);
}
