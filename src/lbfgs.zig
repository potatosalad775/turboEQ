//! A box-constrained limited-memory quasi-Newton minimizer.
//!
//! Upstream calls `fmin_slsqp` with `bounds=` and no constraint functions at
//! all, so the problem is box-constrained and nothing more. SLSQP is not
//! needed for that; a projected L-BFGS is, and it is a few hundred lines
//! rather than a few thousand. See CLAUDE.md invariant 2.
//!
//! The search direction comes from the usual two-loop recursion, restricted
//! at each iteration to the variables not pinned against a bound by their own
//! gradient, and built on an initial Hessian scaled by how wide each
//! variable's box is. The line search is Armijo along the *projection arc*:
//! each trial point is clamped back into the box before the objective sees
//! it, which is what keeps the iterates feasible when a step would otherwise
//! leave the region.
//!
//! Those two details are not incidental. A box-constrained problem whose
//! variables span different orders of magnitude — here a decade of centre
//! frequency alongside tens of decibels of gain — crawls without them.
//!
//! Parity is measured on achieved loss, never on the parameters this lands
//! on. Different solvers settle into different local minima of near-identical
//! quality; see CLAUDE.md invariant 4.

const std = @import("std");
const math = std.math;

pub const Bound = struct {
    lo: f64,
    hi: f64,
};

pub const Options = struct {
    /// Quasi-Newton correction pairs retained, or 0 to size it from the
    /// problem. A parametric EQ has a few dozen free parameters at most, so
    /// the automatic choice keeps enough pairs to span them and the method
    /// behaves as full BFGS. Measured over the parity fixtures, going from
    /// ten pairs to that costs nothing in memory worth counting and cuts the
    /// work by more than an order of magnitude.
    ///
    /// The cap sits above what 32 filters need. At 64 it bound from ten
    /// bands up, and at 20 bands (62 variables) lifting it cut evaluations
    /// by a third at no cost in loss. Four pairs per variable bought nothing
    /// more.
    memory: usize = 0,
    max_iterations: usize = 20000,
    max_evaluations: usize = 20000,
    /// Stop when the infinity norm of the projected gradient falls below it.
    gradient_tolerance: f64 = 1e-9,
    /// Stop when a successful step moves the objective less than this,
    /// relative to its own magnitude.
    function_tolerance: f64 = 1e-12,
    /// Armijo sufficient-decrease constant.
    armijo: f64 = 1e-4,
    /// Trial steps allowed before a line search is abandoned.
    max_backtracks: usize = 40,

    fn memoryFor(self: Options, n: usize) usize {
        if (self.memory != 0) return self.memory;
        return math.clamp(2 * n, 8, 256);
    }
};

pub const Status = enum {
    /// Projected gradient is small enough.
    gradient_tolerance,
    /// A step was taken but barely moved the objective.
    function_tolerance,
    max_iterations,
    max_evaluations,
    /// The line search could not find a decrease even along the steepest
    /// descent direction. On a smooth problem this means we are at a minimum
    /// to within floating point.
    line_search,
    /// `ctx.shouldStop` asked to finish early.
    early_stop,
};

pub const Result = struct {
    loss: f64,
    iterations: usize,
    evaluations: usize,
    status: Status,
};

/// Minimize `ctx.evaluate(x, grad)` over the box `bounds`, starting from `x`
/// and leaving the best point found in `x`.
///
/// `ctx` is anything with `fn evaluate(self, x: []const f64, grad: []f64) f64`.
/// It may also declare `fn shouldStop(self, loss: f64) bool`, which is asked
/// after every accepted step and ends the run when it answers true; that is
/// where upstream's `_callback` stopping rules live. Every step decreases the
/// objective, so the point we stop at is always the best one seen and there
/// is nothing to restore.
///
/// `bounds` has one entry per element of `x`.
pub fn minimize(
    allocator: std.mem.Allocator,
    ctx: anytype,
    x: []f64,
    bounds: []const Bound,
    opts: Options,
) !Result {
    std.debug.assert(x.len == bounds.len);
    const n = x.len;
    if (n == 0) return .{ .loss = 0, .iterations = 0, .evaluations = 0, .status = .gradient_tolerance };

    const m = opts.memoryFor(n);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const g = try arena.alloc(f64, n);
    const pg = try arena.alloc(f64, n);
    const d = try arena.alloc(f64, n);
    const free = try arena.alloc(f64, n);
    @memset(free, 1.0);
    const x_trial = try arena.alloc(f64, n);
    const g_trial = try arena.alloc(f64, n);
    const s_store = try arena.alloc(f64, m * n);
    const y_store = try arena.alloc(f64, m * n);
    const alpha_buf = try arena.alloc(f64, m);
    // Each pair's `s . y` over the free set, which only changes when the
    // free set does. NaN marks an entry to recompute.
    const sy_buf = try arena.alloc(f64, m);
    @memset(sy_buf, math.nan(f64));
    const metric = try arena.alloc(f64, n);
    boundMetric(metric, bounds);

    for (x, bounds) |*v, b| v.* = math.clamp(v.*, b.lo, b.hi);

    var evaluations: usize = 1;
    var f = ctx.evaluate(x, g);

    // Ring buffer of correction pairs: `stored` counts what is valid, `head`
    // is where the next pair goes.
    var stored: usize = 0;
    var head: usize = 0;

    // Consecutive steps that barely moved the objective. One of those is not
    // yet a verdict: it usually means the curvature model has gone stale, and
    // dropping it lets the next iteration make real progress again.
    var stalls: usize = 0;

    var iter: usize = 0;
    while (iter < opts.max_iterations) : (iter += 1) {
        if (freeSet(free, x, g, bounds)) @memset(sy_buf, math.nan(f64));
        project(pg, g, free);
        if (infNorm(pg) <= opts.gradient_tolerance) {
            return .{ .loss = f, .iterations = iter, .evaluations = evaluations, .status = .gradient_tolerance };
        }

        twoLoop(d, pg, free, metric, s_store, y_store, alpha_buf, sy_buf, stored, head, m, n);
        var descent = dot(d, pg);
        if (!(descent < 0)) {
            // The curvature estimate is not usable here. Fall back on the
            // projected gradient, which always descends.
            for (d, pg) |*dv, p| dv.* = -p;
            descent = dot(d, pg);
            if (!(descent < 0)) {
                return .{ .loss = f, .iterations = iter, .evaluations = evaluations, .status = .gradient_tolerance };
            }
        }

        // Armijo backtracking along the projection arc. A unit step first,
        // because that is what a quasi-Newton direction is scaled for; with
        // no curvature yet, scale the gradient step down to something sane.
        var step: f64 = if (stored == 0) @min(1.0, 1.0 / infNorm(d)) else 1.0;
        var accepted = false;
        var f_trial: f64 = f;
        var back: usize = 0;
        while (back < opts.max_backtracks) : (back += 1) {
            for (x_trial, x, d, bounds) |*t, xv, dv, b| {
                t.* = math.clamp(xv + step * dv, b.lo, b.hi);
            }
            // The clamp can leave the trial point exactly where we started,
            // in which case no smaller step will help either.
            if (samePoint(x_trial, x)) break;

            f_trial = ctx.evaluate(x_trial, g_trial);
            evaluations += 1;
            // Directional decrease measured on the realised displacement, not
            // on `step * d`, since the projection may have shortened it.
            var slope: f64 = 0;
            for (g, x_trial, x) |gv, t, xv| slope += gv * (t - xv);
            if (f_trial <= f + opts.armijo * slope) {
                accepted = true;
                break;
            }
            if (evaluations >= opts.max_evaluations) break;
            step *= backtrackFactor(f, f_trial, slope);
        }

        if (!accepted) {
            if (evaluations >= opts.max_evaluations) {
                return .{ .loss = f, .iterations = iter, .evaluations = evaluations, .status = .max_evaluations };
            }
            if (stored != 0) {
                // The quasi-Newton model misled us. Drop it and retry the
                // same iteration on the projected gradient alone.
                stored = 0;
                head = 0;
                continue;
            }
            return .{ .loss = f, .iterations = iter, .evaluations = evaluations, .status = .line_search };
        }

        // Curvature pair, kept only when it is positive enough to be useful.
        // Measured before it is stored: once the ring is full, `head` holds
        // the oldest pair still in use, and a rejected pair must not replace it.
        var sy: f64 = 0;
        var ss: f64 = 0;
        var yy: f64 = 0;
        for (x_trial, x, g_trial, g) |t, xv, gt, gv| {
            const sv = t - xv;
            const yv = gt - gv;
            sy += sv * yv;
            ss += sv * sv;
            yy += yv * yv;
        }
        if (sy > 1e-12 * @sqrt(ss * yy)) {
            const slot = head * n;
            for (s_store[slot..][0..n], y_store[slot..][0..n], x_trial, x, g_trial, g) |*so, *yo, t, xv, gt, gv| {
                so.* = t - xv;
                yo.* = gt - gv;
            }
            sy_buf[head] = math.nan(f64);
            head = (head + 1) % m;
            if (stored < m) stored += 1;
        }

        const df = f - f_trial;
        @memcpy(x, x_trial);
        @memcpy(g, g_trial);
        f = f_trial;

        if (comptime hasStopHook(@TypeOf(ctx))) {
            if (ctx.shouldStop(f)) {
                return .{ .loss = f, .iterations = iter + 1, .evaluations = evaluations, .status = .early_stop };
            }
        }
        if (df <= opts.function_tolerance * @max(1.0, @abs(f))) {
            stalls += 1;
            if (stalls > 1) {
                return .{ .loss = f, .iterations = iter + 1, .evaluations = evaluations, .status = .function_tolerance };
            }
            stored = 0;
            head = 0;
        } else {
            stalls = 0;
        }
        if (evaluations >= opts.max_evaluations) {
            return .{ .loss = f, .iterations = iter + 1, .evaluations = evaluations, .status = .max_evaluations };
        }
    }

    return .{ .loss = f, .iterations = iter, .evaluations = evaluations, .status = .max_iterations };
}

/// How far to shrink a rejected trial step.
///
/// The quadratic through `f(0)`, `f'(0)` and `f(step)` has its minimum at a
/// known fraction of `step`, which is usually a much better next guess than
/// halving. Safeguarded to the range [0.1, 0.5] so a badly nonquadratic
/// segment cannot stall the search or barely move it.
fn backtrackFactor(f0: f64, f_trial: f64, slope: f64) f64 {
    const denom = 2.0 * (f_trial - f0 - slope);
    if (!(denom > 0)) return 0.5;
    return math.clamp(-slope / denom, 0.1, 0.5);
}

/// Contexts are usually passed by pointer, so look through one level of it
/// before asking whether the optional hook is declared.
fn hasStopHook(comptime C: type) bool {
    const Base = switch (@typeInfo(C)) {
        .pointer => |p| p.child,
        else => C,
    };
    return @hasDecl(Base, "shouldStop");
}

/// The diagonal metric the initial Hessian is built on: each variable
/// weighted by the square of the width of its own box, normalised to average
/// one so it only redistributes scale rather than changing it.
///
/// Without this the initial Hessian is isotropic, which on a parametric EQ
/// means treating one decade of centre frequency as interchangeable with one
/// decibel of gain. Measured over the parity fixtures it is the difference
/// between landing near upstream's loss and landing well short of it: the
/// fits it produces are better at every band count, not merely cheaper.
///
/// A variable with no finite box keeps unit weight.
fn boundMetric(metric: []f64, bounds: []const Bound) void {
    var mean: f64 = 0;
    for (metric, bounds) |*mv, b| {
        const w = b.hi - b.lo;
        mv.* = if (math.isFinite(w) and w > 0) w * w else 1.0;
        mean += mv.*;
    }
    mean /= @floatFromInt(metric.len);
    if (mean > 0) {
        for (metric) |*mv| mv.* /= mean;
    }
}

/// Which variables the quasi-Newton model is allowed to move: everything
/// except those resting on a bound with the gradient pointing further out.
/// Those are optimal where they are, and including them would let stale
/// curvature information fight the constraint.
///
/// Written as a mask of ones and zeros rather than booleans, so the two-loop
/// recursion can multiply by it instead of branching. Returns whether the
/// set changed.
fn freeSet(free: []f64, x: []const f64, g: []const f64, bounds: []const Bound) bool {
    var changed = false;
    for (free, x, g, bounds) |*fv, xv, gv, b| {
        const now: f64 = if ((xv <= b.lo and gv > 0) or (xv >= b.hi and gv < 0)) 0.0 else 1.0;
        changed = changed or now != fv.*;
        fv.* = now;
    }
    return changed;
}

/// Gradient restricted to the free set. Its infinity norm is the first-order
/// optimality measure for a box-constrained problem.
fn project(out: []f64, g: []const f64, free: []const f64) void {
    for (out, g, free) |*o, gv, fv| o.* = if (fv != 0) gv else 0;
}

/// `d = -H * pg` by the standard two-loop recursion, restricted to the free
/// set. The initial Hessian is `gamma * diag(metric)`, with `gamma` read off
/// the most recent usable curvature pair.
///
/// Restricting matters: a stored pair records how the gradient responded to a
/// displacement made when a different set of variables was free, and letting
/// those components leak into the direction is what makes a naive projected
/// L-BFGS crawl once several variables have reached their bounds.
///
/// `d` starts as the projected gradient and every update to it is masked, so
/// it stays zero off the free set and a plain dot product against it is
/// already restricted. Only `s . y` needs the mask, and `sy` caches it.
fn twoLoop(
    d: []f64,
    pg: []const f64,
    free: []const f64,
    metric: []const f64,
    s_store: []const f64,
    y_store: []const f64,
    alpha: []f64,
    sy: []f64,
    stored: usize,
    head: usize,
    m: usize,
    n: usize,
) void {
    for (d, pg) |*dv, p| dv.* = p;
    if (stored == 0) {
        for (d, metric) |*dv, mv| dv.* = -dv.* * mv;
        return;
    }

    var gamma: f64 = 1.0;
    var used: usize = 0;

    // Newest pair first, walking backwards from the write head.
    var k: usize = 0;
    while (k < stored) : (k += 1) {
        const idx = (head + m - 1 - k) % m;
        const s = s_store[idx * n ..][0..n];
        const y = y_store[idx * n ..][0..n];
        if (math.isNan(sy[idx])) sy[idx] = dotFree(s, y, free);
        const sy_k = sy[idx];
        if (!(sy_k > 0)) {
            alpha[idx] = 0;
            continue;
        }
        if (used == 0) {
            var yy: f64 = 0;
            for (y, metric, free) |yv, mv, fv| {
                if (fv != 0) yy += yv * yv * mv;
            }
            if (yy > 0) gamma = sy_k / yy;
        }
        used += 1;
        const a = dot(s, d) / sy_k;
        alpha[idx] = a;
        for (d, y, free) |*dv, yv, fv| dv.* -= a * yv * fv;
    }

    for (d, free, metric) |*dv, fv, mv| dv.* = if (fv != 0) dv.* * gamma * mv else 0;

    k = stored;
    while (k > 0) {
        k -= 1;
        const idx = (head + m - 1 - k) % m;
        if (alpha[idx] == 0) continue;
        const sy_k = sy[idx];
        if (!(sy_k > 0)) continue;
        const s = s_store[idx * n ..][0..n];
        const y = y_store[idx * n ..][0..n];
        const beta = dot(y, d) / sy_k;
        const c = alpha[idx] - beta;
        for (d, s, free) |*dv, sv, fv| dv.* += c * sv * fv;
    }

    for (d) |*dv| dv.* = -dv.*;
}

fn dot(a: []const f64, b: []const f64) f64 {
    const V = @Vector(4, f64);
    var acc: V = @splat(0);
    var i: usize = 0;
    while (i + 4 <= a.len) : (i += 4) {
        const av: V = a[i..][0..4].*;
        const bv: V = b[i..][0..4].*;
        acc += av * bv;
    }
    var sum = @reduce(.Add, acc);
    while (i < a.len) : (i += 1) sum += a[i] * b[i];
    return sum;
}

fn dotFree(a: []const f64, b: []const f64, free: []const f64) f64 {
    var sum: f64 = 0;
    for (a, b, free) |av, bv, fv| {
        if (fv != 0) sum += av * bv;
    }
    return sum;
}

fn infNorm(a: []const f64) f64 {
    var best: f64 = 0;
    for (a) |v| best = @max(best, @abs(v));
    return best;
}

fn samePoint(a: []const f64, b: []const f64) bool {
    for (a, b) |av, bv| if (av != bv) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Quadratic = struct {
    /// f(x) = sum (x_i - c_i)^2 * w_i
    c: []const f64,
    w: []const f64,

    fn evaluate(self: Quadratic, x: []const f64, grad: []f64) f64 {
        var f: f64 = 0;
        for (x, self.c, self.w, grad) |xv, cv, wv, *gv| {
            f += wv * (xv - cv) * (xv - cv);
            gv.* = 2 * wv * (xv - cv);
        }
        return f;
    }
};

test "an unconstrained quadratic lands on its minimum" {
    const c = [_]f64{ 1.0, -3.0, 7.5 };
    const w = [_]f64{ 1.0, 4.0, 0.25 };
    var x = [_]f64{ 0.0, 0.0, 0.0 };
    const bounds = [_]Bound{.{ .lo = -100, .hi = 100 }} ** 3;
    const r = try minimize(std.testing.allocator, Quadratic{ .c = &c, .w = &w }, &x, &bounds, .{});
    try std.testing.expect(r.loss < 1e-12);
    for (x, c) |xv, cv| try std.testing.expectApproxEqAbs(cv, xv, 1e-6);
}

test "bounds hold and the active set is recognised as optimal" {
    const c = [_]f64{ 5.0, -5.0 };
    const w = [_]f64{ 1.0, 1.0 };
    var x = [_]f64{ 0.0, 0.0 };
    const bounds = [_]Bound{ .{ .lo = -1, .hi = 1 }, .{ .lo = -1, .hi = 1 } };
    const r = try minimize(std.testing.allocator, Quadratic{ .c = &c, .w = &w }, &x, &bounds, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), x[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), x[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 32.0), r.loss, 1e-12);
}

const Rosenbrock = struct {
    fn evaluate(_: Rosenbrock, x: []const f64, grad: []f64) f64 {
        var f: f64 = 0;
        @memset(grad, 0);
        var i: usize = 0;
        while (i + 1 < x.len) : (i += 1) {
            const a = 1 - x[i];
            const b = x[i + 1] - x[i] * x[i];
            f += a * a + 100 * b * b;
            grad[i] += -2 * a - 400 * x[i] * b;
            grad[i + 1] += 200 * b;
        }
        return f;
    }
};

test "a curved valley is followed to its floor" {
    var x = [_]f64{ -1.2, 1.0, -1.2, 1.0 };
    const bounds = [_]Bound{.{ .lo = -10, .hi = 10 }} ** 4;
    const r = try minimize(std.testing.allocator, Rosenbrock{}, &x, &bounds, .{});
    try std.testing.expect(r.loss < 1e-10);
    for (x) |v| try std.testing.expectApproxEqAbs(@as(f64, 1.0), v, 1e-4);
}

test "variables of wildly different size converge together" {
    // Minimum at (1000, 0.001), with the two variables' natural sizes six
    // orders of magnitude apart and each one's box sized to match. The
    // problem is perfectly conditioned once read in those units, and badly
    // conditioned in raw ones, which is exactly what the bound metric is for.
    const Skewed = struct {
        const scale = [2]f64{ 1000.0, 0.001 };
        fn evaluate(_: @This(), x: []const f64, grad: []f64) f64 {
            var f: f64 = 0;
            for (x, scale, grad) |xv, s, *gv| {
                const u = xv / s - 1.0;
                f += u * u;
                gv.* = 2 * u / s;
            }
            return f;
        }
    };
    var x = [_]f64{ 0.0, 0.0 };
    const bounds = [_]Bound{ .{ .lo = -2000, .hi = 2000 }, .{ .lo = -0.002, .hi = 0.002 } };
    const r = try minimize(std.testing.allocator, Skewed{}, &x, &bounds, .{});
    try std.testing.expectApproxEqRel(@as(f64, 1000.0), x[0], 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 0.001), x[1], 1e-9);
    try std.testing.expect(r.iterations < 20);
}

test "an infinite bound keeps unit weight in the metric" {
    var metric: [3]f64 = undefined;
    const bounds = [_]Bound{
        .{ .lo = -1, .hi = 1 },
        .{ .lo = -math.inf(f64), .hi = math.inf(f64) },
        .{ .lo = 0, .hi = 3 },
    };
    boundMetric(&metric, &bounds);
    // Raw weights are 4, 1 and 9, so the mean is 14/3.
    const mean = 14.0 / 3.0;
    try std.testing.expectApproxEqRel(4.0 / mean, metric[0], 1e-12);
    try std.testing.expectApproxEqRel(1.0 / mean, metric[1], 1e-12);
    try std.testing.expectApproxEqRel(9.0 / mean, metric[2], 1e-12);
}
