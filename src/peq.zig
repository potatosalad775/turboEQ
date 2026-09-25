//! The parametric EQ optimizer.
//!
//! Ports `autoeq/peq.py`: the filter `init()` heuristics, the ordering in
//! `_init_optimizer_params`, the optimizer loss, and the fit itself.
//!
//! Three things differ from upstream on purpose.
//!
//! 1. The solver is a projected L-BFGS (`lbfgs.zig`), not SLSQP. Upstream
//!    passes `bounds=` and no constraint functions, so the problem is
//!    box-constrained and nothing more. CLAUDE.md invariant 2.
//! 2. The gradients are analytic. scipy has none to work with, so upstream
//!    spends roughly `3N+1` full loss evaluations per iteration
//!    finite-differencing them. That is where most of the speedup lives.
//! 3. Early stopping is off by default. Measured upstream it costs real
//!    quality — with `min_std=0.008`, 12 bands scored worse than 10 — and
//!    analytic gradients make running to convergence cheap enough that there
//!    is no reason to accept that. The knobs are still here.
//!
//! Parity for this stage is measured on achieved loss, never on the filter
//! parameters. CLAUDE.md invariant 4.
//!
//! Derived from AutoEq (MIT, Jaakko Pasanen), autoeq/peq.py.

const std = @import("std");
const math = std.math;
const util = @import("util.zig");
const biquad = @import("biquad.zig");
const peaks = @import("peaks.zig");
const lbfgs = @import("lbfgs.zig");

pub const Kind = biquad.Kind;
pub const Bound = lbfgs.Bound;

/// Box constraints for one filter, in the units the user thinks in. The
/// optimizer sees log10(fc) rather than fc; `bounds` does that conversion.
pub const Limits = struct {
    min_fc: f64,
    max_fc: f64,
    min_q: f64,
    max_q: f64,
    min_gain: f64,
    max_gain: f64,
};

/// `DEFAULT_PEAKING_FILTER_*`. The Q floor is AUNBandEq's five-octave
/// maximum bandwidth.
pub const peaking_limits: Limits = .{
    .min_fc = 20.0,
    .max_fc = 10000.0,
    .min_q = 0.18248,
    .max_q = 6.0,
    .min_gain = -20.0,
    .max_gain = 20.0,
};

/// `DEFAULT_SHELF_FILTER_*`. Shelves overshoot below Q 0.4 and above Q 0.7,
/// which is where those two bounds come from.
pub const shelf_limits: Limits = .{
    .min_fc = 20.0,
    .max_fc = 10000.0,
    .min_q = 0.4,
    .max_q = 0.7,
    .min_gain = -20.0,
    .max_gain = 20.0,
};

/// One band. A parameter is optimized unless the caller pinned it, which is
/// what `from_dict` decides by whether the config supplied a value.
pub const Filter = struct {
    kind: Kind,
    fc: f64,
    q: f64,
    gain: f64,
    optimize_fc: bool = true,
    optimize_q: bool = true,
    optimize_gain: bool = true,
    limits: Limits,

    pub fn paramCount(self: Filter) usize {
        return @as(usize, @intFromBool(self.optimize_fc)) +
            @intFromBool(self.optimize_q) +
            @intFromBool(self.optimize_gain);
    }

    pub fn asBiquad(self: Filter) biquad.Filter {
        return .{ .kind = self.kind, .fc = self.fc, .q = self.q, .gain = self.gain };
    }
};

/// `PEQ_CONFIGS['N_PEAKING']`: N fully free peaking bands.
pub fn peakingConfig(allocator: std.mem.Allocator, n: usize) ![]Filter {
    const out = try allocator.alloc(Filter, n);
    for (out) |*filt| {
        filt.* = .{ .kind = .peaking, .fc = 0, .q = 0, .gain = 0, .limits = peaking_limits };
    }
    return out;
}

/// `PEQ_CONFIGS['N_PEAKING_WITH_SHELVES']`: a low shelf pinned at 105 Hz, a
/// high shelf pinned at 10 kHz, both at Q 0.7 with only gain free, then N
/// free peaking bands.
///
/// Every shipped upstream preset pins the shelves this way. The `init()`
/// heuristics for free shelves are ported all the same, because turboEQ may
/// want to offer them; see `initFilter`.
pub fn peakingWithShelvesConfig(allocator: std.mem.Allocator, n: usize) ![]Filter {
    const out = try allocator.alloc(Filter, n + 2);
    out[0] = .{
        .kind = .low_shelf,
        .fc = 105.0,
        .q = 0.7,
        .gain = 0,
        .optimize_fc = false,
        .optimize_q = false,
        .limits = shelf_limits,
    };
    out[1] = .{
        .kind = .high_shelf,
        .fc = 10000.0,
        .q = 0.7,
        .gain = 0,
        .optimize_fc = false,
        .optimize_q = false,
        .limits = shelf_limits,
    };
    for (out[2..]) |*filt| {
        filt.* = .{ .kind = .peaking, .fc = 0, .q = 0, .gain = 0, .limits = peaking_limits };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Coefficients and their derivatives
// ---------------------------------------------------------------------------

/// Which optimizer parameter a derivative is taken with respect to.
const Wrt = enum(usize) { log_fc = 0, q = 1, gain = 2 };

/// The five coefficients `magnitude()` evaluates (`a0` is always 1), each
/// with its partial derivatives with respect to log10(fc), Q and gain.
///
/// These are the same numbers `biquad.coefficients()` produces, in the sign
/// convention `magnitude()` uses internally: the negation that
/// `biquad_coefficients()` applies to `a1` and `a2` is already undone.
const Jet = struct {
    a1: f64,
    a2: f64,
    b0: f64,
    b1: f64,
    b2: f64,
    /// Indexed by `Wrt`.
    d: [3]Partial,

    const Partial = struct { a1: f64 = 0, a2: f64 = 0, b0: f64 = 0, b1: f64 = 0, b2: f64 = 0 };
};

fn jet(kind: Kind, fc: f64, q: f64, gain: f64, fs: f64) Jet {
    const amp = math.pow(f64, 10.0, gain / 40.0);
    const w0 = 2.0 * math.pi * fc / fs;
    const cw = @cos(w0);
    const sw = @sin(w0);
    const alpha = sw / (2.0 * q);

    // Everything downstream depends on the parameters only through
    // (cos w0, alpha, A), so seeding those three differentials is enough.
    // fc enters the optimizer as log10(fc), hence the ln(10) factor.
    const dw_dlogfc = w0 * math.ln10;
    const seeds = [3][3]f64{
        .{ -sw * dw_dlogfc, cw * dw_dlogfc / (2.0 * q), 0.0 },
        .{ 0.0, -alpha / q, 0.0 },
        .{ 0.0, 0.0, amp * math.ln10 / 40.0 },
    };

    var out: Jet = undefined;
    switch (kind) {
        .peaking => {
            const r = alpha / amp;
            const t = alpha * amp;
            const den = 1.0 + r;
            const x = [5]f64{ -2.0 * cw, 1.0 - r, 1.0 + t, -2.0 * cw, 1.0 - t };
            var c: [5]f64 = undefined;
            for (&c, x) |*cv, xv| cv.* = xv / den;
            out = .{ .a1 = c[0], .a2 = c[1], .b0 = c[2], .b1 = c[3], .b2 = c[4], .d = undefined };

            for (seeds, 0..) |seed, k| {
                const dc = seed[0];
                const dal = seed[1];
                const da = seed[2];
                const dr = dal / amp - alpha * da / (amp * amp);
                const dt = dal * amp + alpha * da;
                const dden = dr;
                const dx = [5]f64{ -2.0 * dc, -dr, dt, -2.0 * dc, -dt };
                var p: [5]f64 = undefined;
                for (&p, dx, c) |*pv, dxv, cv| pv.* = (dxv - cv * dden) / den;
                out.d[k] = .{ .a1 = p[0], .a2 = p[1], .b0 = p[2], .b1 = p[3], .b2 = p[4] };
            }
        },
        .low_shelf, .high_shelf => {
            // The two shelves are the same expressions with one sign flipped
            // on every term carrying (A - 1) * cos(w0).
            const sig: f64 = if (kind == .low_shelf) 1.0 else -1.0;
            const p_ = amp + 1.0;
            const m_ = amp - 1.0;
            const sq = @sqrt(amp);
            const t_ = 2.0 * sq * alpha;

            const den = p_ + sig * m_ * cw + t_;
            const x = [5]f64{
                -2.0 * (sig * m_ + p_ * cw),
                p_ + sig * m_ * cw - t_,
                amp * (p_ - sig * m_ * cw + t_),
                2.0 * amp * (sig * m_ - p_ * cw),
                amp * (p_ - sig * m_ * cw - t_),
            };
            var c: [5]f64 = undefined;
            for (&c, x) |*cv, xv| cv.* = xv / den;
            out = .{ .a1 = c[0], .a2 = c[1], .b0 = c[2], .b1 = c[3], .b2 = c[4], .d = undefined };

            for (seeds, 0..) |seed, k| {
                const dc = seed[0];
                const dal = seed[1];
                const da = seed[2];
                const dp = da;
                const dm = da;
                const dsq = da / (2.0 * sq);
                const dt = 2.0 * (dsq * alpha + sq * dal);
                const dmc = dm * cw + m_ * dc; // d[(A-1) cos w0]

                const dden = dp + sig * dmc + dt;
                const dx = [5]f64{
                    -2.0 * (sig * dm + dp * cw + p_ * dc),
                    dp + sig * dmc - dt,
                    da * (p_ - sig * m_ * cw + t_) + amp * (dp - sig * dmc + dt),
                    2.0 * da * (sig * m_ - p_ * cw) + 2.0 * amp * (sig * dm - dp * cw - p_ * dc),
                    da * (p_ - sig * m_ * cw - t_) + amp * (dp - sig * dmc - dt),
                };
                var p: [5]f64 = undefined;
                for (&p, dx, c) |*pv, dxv, cv| pv.* = (dxv - cv * dden) / den;
                out.d[k] = .{ .a1 = p[0], .a2 = p[1], .b0 = p[2], .b1 = p[3], .b2 = p[4] };
            }
        },
    }
    return out;
}

/// Which `Wrt` each of a filter's optimizer parameters corresponds to, in the
/// order they appear in the parameter vector.
const ParameterRows = struct {
    items: [3]Wrt = undefined,
    len: usize = 0,

    fn slice(self: *const ParameterRows) []const Wrt {
        return self.items[0..self.len];
    }
};

fn parameterRows(filt: Filter) ParameterRows {
    var rows: ParameterRows = .{};
    if (filt.optimize_fc) {
        rows.items[rows.len] = .log_fc;
        rows.len += 1;
    }
    if (filt.optimize_q) {
        rows.items[rows.len] = .q;
        rows.len += 1;
    }
    if (filt.optimize_gain) {
        rows.items[rows.len] = .gain;
        rows.len += 1;
    }
    return rows;
}

/// One filter's magnitude response and its parameter derivatives, sample by
/// sample, with everything that depends only on the coefficients hoisted.
///
/// `phi` is the frequency axis in the form the magnitude actually uses; see
/// `biquad.phiFor`. It is the same for every filter, so the caller computes it
/// once and the trig never appears in the optimizer's inner loop.
/// Samples the optimizer's kernel works on at once. Two f64 lanes is what
/// wasm's simd128 holds; without it LLVM splits the vector back into scalars.
const lanes = 2;
const Lane = @Vector(lanes, f64);

/// Natural logarithm of every lane at once. `@log` on a vector calls the
/// scalar routine once per lane, and in the optimizer's kernel that is a
/// fifth of the fit.
///
/// fdlibm's `e_log.c` reduction and polynomial, which is under one ulp.
/// Lanes that are not positive normal numbers go to `@log` instead; the
/// kernel never produces one.
fn logLanes(x: Lane) Lane {
    const U = @Vector(lanes, u64);
    const I = @Vector(lanes, i64);
    const ok = @reduce(.And, x >= @as(Lane, @splat(math.floatMin(f64)))) and
        @reduce(.And, x <= @as(Lane, @splat(math.floatMax(f64))));
    if (!ok) return @log(x);

    const bits: U = @bitCast(x);
    var hx = bits >> @splat(32);
    var k: I = @as(I, @intCast(hx >> @splat(20))) - @as(I, @splat(1023));
    hx &= @splat(0x000fffff);
    // Normalize the mantissa into [sqrt(2)/2, sqrt(2)).
    const i = (hx + @as(U, @splat(0x95f64))) & @as(U, @splat(0x100000));
    const hi = hx | (i ^ @as(U, @splat(0x3ff00000)));
    k += @intCast(i >> @splat(20));
    const m: Lane = @bitCast((hi << @splat(32)) | (bits & @as(U, @splat(0xffffffff))));

    const f = m - lv(1.0);
    const s = f / (lv(2.0) + f);
    const z = s * s;
    const w = z * z;
    const t1 = w * (lv(3.999999999940941908e-01) + w * (lv(2.222219843214978396e-01) + w * lv(1.531383769920937332e-01)));
    const t2 = z * (lv(6.666666666666735130e-01) + w * (lv(2.857142874366239149e-01) + w * (lv(1.818357216161805012e-01) + w * lv(1.479819860511658591e-01))));
    const r = t2 + t1;
    const hfsq = lv(0.5) * f * f;
    const dk: Lane = @floatFromInt(k);
    return dk * lv(6.93147180369123816490e-01) - ((hfsq - (s * (hfsq + r) + dk * lv(1.90821492927058770002e-10))) - f);
}

inline fn lv(comptime x: f64) Lane {
    return @splat(x);
}

const Kernel = struct {
    j: Jet,
    rows: ParameterRows,
    /// `j.d` picked out in parameter-vector order, so the inner loop never
    /// indexes by `Wrt`.
    q: [3]Jet.Partial,
    sb: f64,
    sa: f64,
    b_mix: f64,
    a_mix: f64,

    const scale = 10.0 / math.ln10;

    fn init(filt: Filter, fs: f64) Kernel {
        const j = jet(filt.kind, filt.fc, filt.q, filt.gain, fs);
        const rows = parameterRows(filt);
        var q: [3]Jet.Partial = @splat(.{});
        for (rows.slice(), 0..) |wrt, k| q[k] = j.d[@intFromEnum(wrt)];
        return .{
            .j = j,
            .rows = rows,
            .q = q,
            .sb = j.b0 + j.b1 + j.b2,
            .sa = 1.0 + j.a1 + j.a2,
            .b_mix = j.b1 * (j.b0 + j.b2) + 4.0 * j.b0 * j.b2,
            .a_mix = j.a1 * (1.0 + j.a2) + 4.0 * j.a2,
        };
    }

    /// Every per-sample function takes `p` either as one `f64` or as a
    /// `@Vector` of them, and is the same arithmetic either way.
    inline fn splat(comptime T: type, x: f64) T {
        return if (@typeInfo(T) == .vector) @splat(x) else x;
    }

    inline fn num(self: Kernel, p: anytype) @TypeOf(p) {
        const T = @TypeOf(p);
        return splat(T, self.sb * self.sb) + (splat(T, self.j.b0 * self.j.b2) * p - splat(T, self.b_mix)) * p;
    }

    inline fn den(self: Kernel, p: anytype) @TypeOf(p) {
        const T = @TypeOf(p);
        return splat(T, self.sa * self.sa) + (splat(T, self.j.a2) * p - splat(T, self.a_mix)) * p;
    }

    /// Response in dB. One logarithm of the ratio rather than a difference of
    /// two: the last bits move, the magnitude does not.
    inline fn response(self: Kernel, p: anytype) @TypeOf(p) {
        const ratio = self.num(p) / self.den(p);
        const ln = if (@typeInfo(@TypeOf(p)) == .vector) logLanes(ratio) else @log(ratio);
        return splat(@TypeOf(p), scale) * ln;
    }

    /// Derivative of `response(p)` with respect to the first `rows` of the
    /// filter's optimizer parameters, in parameter-vector order. `rows` is
    /// comptime so the result stays in registers.
    inline fn derivatives(self: Kernel, comptime rows: usize, p: anytype) [rows]@TypeOf(p) {
        const T = @TypeOf(p);
        const j = self.j;
        const n = self.num(p);
        const d = self.den(p);
        // One division for both reciprocals.
        const r = splat(T, 1.0) / (n * d);
        const inv_num = d * r;
        const inv_den = n * r;

        // Partials of num and den with respect to the coefficients.
        const sb2 = splat(T, 2.0 * self.sb);
        const sa2 = splat(T, 2.0 * self.sa);
        const dn_db0 = sb2 + (splat(T, j.b2) * p - splat(T, j.b1 + 4.0 * j.b2)) * p;
        const dn_db1 = sb2 - splat(T, j.b0 + j.b2) * p;
        const dn_db2 = sb2 + (splat(T, j.b0) * p - splat(T, j.b1 + 4.0 * j.b0)) * p;
        const dd_da1 = sa2 - splat(T, 1.0 + j.a2) * p;
        const dd_da2 = sa2 + (p - splat(T, j.a1 + 4.0)) * p;

        var out: [rows]T = undefined;
        inline for (&out, self.q[0..rows]) |*o, q| {
            const dnum = dn_db0 * splat(T, q.b0) + dn_db1 * splat(T, q.b1) + dn_db2 * splat(T, q.b2);
            const dden = dd_da1 * splat(T, q.a1) + dd_da2 * splat(T, q.a2);
            o.* = splat(T, scale) * (dnum * inv_num - dden * inv_den);
        }
        return out;
    }
};

/// Magnitude response and, for each optimizable parameter of this filter, its
/// derivative. `derivs` is written in the same order the parameters appear in
/// the optimizer vector, so it holds `filt.paramCount()` rows of `phi.len`.
///
/// The optimizer never materializes these rows; `Peq.lossAndGradient` folds
/// each derivative into the gradient as it is produced. This is the same
/// arithmetic laid out for inspection.
fn responseAndDerivatives(
    filt: Filter,
    phi: []const f64,
    fs: f64,
    fr: []f64,
    derivs: []f64,
) void {
    std.debug.assert(fr.len == phi.len);
    const kern = Kernel.init(filt, fs);
    const rows = kern.rows.len;
    std.debug.assert(derivs.len >= rows * phi.len);
    for (phi, 0..) |p, i| {
        fr[i] = kern.response(p);
        switch (rows) {
            0 => {},
            inline 1...3 => |r| {
                const dv = kern.derivatives(r, p);
                inline for (0..r) |k| derivs[k * phi.len + i] = dv[k];
            },
            else => unreachable,
        }
    }
}

// ---------------------------------------------------------------------------
// The equalizer
// ---------------------------------------------------------------------------

/// `DEFAULT_PEQ_OPTIMIZER_MIN_F` and `MAX_F`, and where the loss stops
/// seeing shape.
pub const Options = struct {
    min_f: f64 = 20.0,
    max_f: f64 = 20000.0,
    /// Above this the loss compares only the mean of each curve. 10 kHz is
    /// upstream's, hardcoded in `_optimizer_loss`; anything else departs from
    /// it. Past the top of the grid, infinity included, nothing is flattened
    /// and every sample up to `max_f` is its own residual.
    flatten_f: f64 = 10000.0,
    /// Add each peaking filter's sharpness penalty to the loss, as upstream's
    /// `_optimizer_loss` does. Turning it off departs from the objective:
    /// nothing then discourages a band steeper than about 18 dB/octave, which
    /// is what a fit judged against the curve on a graph wants and what a fit
    /// judged by ear usually does not.
    sharpness_penalty: bool = true,
};

/// The first index `squaredLoss` flattens: `argmin(abs(f - 10000))` upstream,
/// or one past the end when `flatten_f` lies beyond the grid, since the
/// nearest sample to infinity would otherwise be the first.
fn flatIndex(f: []const f64, flatten_f: f64) usize {
    if (flatten_f > f[f.len - 1]) return f.len;
    return util.argminAbs(f, flatten_f);
}

/// Early-stop rules, all off by default.
///
/// Upstream ships `min_std = 0.002`, or `0.008` for the shelved presets, and
/// it costs measurable quality: 12 bands landed a worse loss than 10 because
/// the fit was cut short. With analytic gradients an iteration is cheap, so
/// the default here is to run to convergence.
///
/// There is no wall-clock budget. The freestanding wasm build has no clock,
/// and a deterministic cap on evaluations is reproducible in a way a time
/// limit never is.
pub const StopRules = struct {
    /// Stop once the loss reaches this. `DEFAULT_PEQ_OPTIMIZER_TARGET_LOSS`.
    target_loss: ?f64 = null,
    /// Stop once the last 8 losses vary less than this, or the last 4 vary
    /// less than half of it. `DEFAULT_PEQ_OPTIMIZER_MIN_STD`.
    min_std: ?f64 = null,
    solver: lbfgs.Options = .{},
};

pub const Report = struct {
    loss: f64,
    iterations: usize,
    evaluations: usize,
    status: lbfgs.Status,
};

pub const Peq = struct {
    allocator: std.mem.Allocator,
    f: []const f64,
    fs: f64,
    target: []const f64,
    filters: []Filter,

    min_f_ix: usize,
    max_f_ix: usize,
    flat_ix: usize,
    /// `Options.sharpness_penalty`.
    sharpness: bool,

    /// `4*sin(w/2)^2` for each frequency. Fixed for the life of the fit, so
    /// the magnitude's only transcendental never enters the inner loop.
    phi: []f64,
    /// Cascade response, kept in step with `filters`.
    fr: []f64,
    /// Per-filter responses, `filters.len` rows of `f.len`.
    filt_fr: []f64,
    /// dMSE/d(cascade response), one entry per frequency.
    weights: []f64,
    /// Each filter's hoisted coefficients from the last `lossAndGradient`,
    /// so the gradient pass need not recompute them.
    kernels: []Kernel,

    /// Early-stop bookkeeping, mirroring `PEQ._callback`.
    stop: StopRules = .{},
    history: [8]f64 = @splat(0),
    history_len: usize = 0,
    /// Total accepted steps seen, which is what upstream's window guards
    /// count rather than the length of the window itself.
    seen: usize = 0,

    /// `filters` and `target` are borrowed, not copied; `filters` is written
    /// through as the optimizer runs.
    pub fn init(
        allocator: std.mem.Allocator,
        f: []const f64,
        fs: f64,
        filters: []Filter,
        target: []const f64,
        opts: Options,
    ) !Peq {
        std.debug.assert(f.len == target.len);

        const phi = try allocator.alloc(f64, f.len);
        errdefer allocator.free(phi);
        biquad.phiFor(f, fs, phi);

        return .{
            .allocator = allocator,
            .f = f,
            .fs = fs,
            .target = target,
            .filters = filters,
            .min_f_ix = util.argminAbs(f, opts.min_f),
            .max_f_ix = util.argminAbs(f, opts.max_f),
            .flat_ix = flatIndex(f, opts.flatten_f),
            .sharpness = opts.sharpness_penalty,
            .phi = phi,
            .fr = try allocator.alloc(f64, f.len),
            .filt_fr = try allocator.alloc(f64, filters.len * f.len),
            .weights = try allocator.alloc(f64, f.len),
            .kernels = try allocator.alloc(Kernel, filters.len),
        };
    }

    pub fn deinit(self: *Peq) void {
        self.allocator.free(self.phi);
        self.allocator.free(self.fr);
        self.allocator.free(self.filt_fr);
        self.allocator.free(self.weights);
        self.allocator.free(self.kernels);
        self.* = undefined;
    }

    pub fn paramCount(self: Peq) usize {
        var n: usize = 0;
        for (self.filters) |filt| n += filt.paramCount();
        return n;
    }

    /// `_init_optimizer_bounds`. fc is bounded in log10, which is the space
    /// the optimizer works in.
    pub fn bounds(self: Peq, out: []Bound) void {
        var i: usize = 0;
        for (self.filters) |filt| {
            if (filt.optimize_fc) {
                out[i] = .{ .lo = math.log10(filt.limits.min_fc), .hi = math.log10(filt.limits.max_fc) };
                i += 1;
            }
            if (filt.optimize_q) {
                out[i] = .{ .lo = filt.limits.min_q, .hi = filt.limits.max_q };
                i += 1;
            }
            if (filt.optimize_gain) {
                out[i] = .{ .lo = filt.limits.min_gain, .hi = filt.limits.max_gain };
                i += 1;
            }
        }
        std.debug.assert(i == out.len);
    }

    /// `_parse_optimizer_params`.
    pub fn setParams(self: *Peq, params: []const f64) void {
        var i: usize = 0;
        for (self.filters) |*filt| {
            if (filt.optimize_fc) {
                filt.fc = math.pow(f64, 10.0, params[i]);
                i += 1;
            }
            if (filt.optimize_q) {
                filt.q = params[i];
                i += 1;
            }
            if (filt.optimize_gain) {
                filt.gain = params[i];
                i += 1;
            }
        }
    }

    /// The inverse: current filter state as an optimizer vector.
    pub fn getParams(self: Peq, out: []f64) void {
        var i: usize = 0;
        for (self.filters) |filt| {
            if (filt.optimize_fc) {
                out[i] = math.log10(filt.fc);
                i += 1;
            }
            if (filt.optimize_q) {
                out[i] = filt.q;
                i += 1;
            }
            if (filt.optimize_gain) {
                out[i] = filt.gain;
                i += 1;
            }
        }
    }

    /// Recompute every filter response and their sum. `PEQ.fr`.
    pub fn refresh(self: *Peq) void {
        const n = self.f.len;
        @memset(self.fr, 0);
        for (self.filters, 0..) |filt, k| {
            const row = self.filt_fr[k * n ..][0..n];
            biquad.magnitudeFromPhi(filt.asBiquad().coefficients(self.fs), self.phi, row);
            for (self.fr, row) |*o, v| o.* += v;
        }
    }

    /// Like `refresh`, but through the optimizer's own kernel, whose
    /// coefficients it keeps for the gradient pass that follows.
    fn refreshWithKernels(self: *Peq) void {
        const n = self.f.len;
        @memset(self.fr, 0);
        for (self.filters, self.kernels, 0..) |filt, *kern, k| {
            const row = self.filt_fr[k * n ..][0..n];
            kern.* = Kernel.init(filt, self.fs);
            var i: usize = 0;
            while (i + lanes <= n) : (i += lanes) {
                const p: Lane = self.phi[i..][0..lanes].*;
                row[i..][0..lanes].* = kern.response(p);
            }
            while (i < n) : (i += 1) row[i] = kern.response(self.phi[i]);
            for (self.fr, row) |*o, v| o.* += v;
        }
    }

    /// Largest boost the cascade applies. `PEQ.max_gain`.
    pub fn maxGain(self: Peq) f64 {
        var best = -math.inf(f64);
        for (self.fr) |v| best = @max(best, v);
        return best;
    }

    /// Root mean squared error against the target, across the whole axis.
    pub fn rmse(self: Peq) f64 {
        var sum: f64 = 0;
        for (self.fr, self.target) |a, b| sum += (a - b) * (a - b);
        return @sqrt(sum / @as(f64, @floatFromInt(self.f.len)));
    }

    /// `_optimizer_loss`. Mean squared error between min_f and max_f, with
    /// both curves flattened to their mean above `Options.flatten_f`, 10 kHz
    /// upstream, because only total energy matters up there, plus each
    /// filter's sharpness penalty unless `Options.sharpness_penalty` is off.
    /// The square root is taken last, exactly as upstream does.
    ///
    /// `refresh()` must have run for the current parameters.
    pub fn lossFromResponse(self: Peq) f64 {
        return @sqrt(self.squaredLoss());
    }

    fn squaredLoss(self: Peq) f64 {
        const n = self.f.len;
        if (self.max_f_ix <= self.min_f_ix) return 0;

        // The flattened value each curve takes above flatten_f. Note the mean
        // runs to the end of the array, past max_f_ix. With nothing flattened
        // both means are 0/0, and neither is read: max_f_ix < n = flat_ix.
        const hi_count: f64 = @floatFromInt(n - self.flat_ix);
        var fr_hi: f64 = 0;
        var tgt_hi: f64 = 0;
        for (self.fr[self.flat_ix..], self.target[self.flat_ix..]) |a, b| {
            fr_hi += a;
            tgt_hi += b;
        }
        fr_hi /= hi_count;
        tgt_hi /= hi_count;

        var sum: f64 = 0;
        for (self.min_f_ix..self.max_f_ix) |k| {
            const t = if (k >= self.flat_ix) tgt_hi else self.target[k];
            const r = if (k >= self.flat_ix) fr_hi else self.fr[k];
            sum += (t - r) * (t - r);
        }
        var value = sum / @as(f64, @floatFromInt(self.max_f_ix - self.min_f_ix));

        if (!self.sharpness) return value;
        for (self.filters, 0..) |filt, k| {
            const row = self.filt_fr[k * n ..][0..n];
            value += biquad.sharpnessPenalty(filt.kind, filt.q, filt.gain, row);
        }
        return value;
    }

    /// Loss at `params`, leaving the filters set to them.
    pub fn loss(self: *Peq, params: []const f64) f64 {
        self.setParams(params);
        self.refresh();
        return self.lossFromResponse();
    }

    /// Loss and its analytic gradient at `params`.
    ///
    /// The chain runs loss -> cascade response -> one filter's response ->
    /// that filter's biquad coefficients -> log10(fc), Q, gain. Upstream has
    /// scipy finite-difference this instead, at roughly `3N+1` full loss
    /// evaluations per iteration.
    pub fn lossAndGradient(self: *Peq, params: []const f64, grad: []f64) f64 {
        self.setParams(params);
        self.refreshWithKernels();
        const squared = self.squaredLoss();
        const value = @sqrt(squared);

        const n = self.f.len;
        @memset(self.weights, 0);
        if (self.max_f_ix > self.min_f_ix) {
            const count: f64 = @floatFromInt(self.max_f_ix - self.min_f_ix);
            const hi_count: f64 = @floatFromInt(n - self.flat_ix);
            var fr_hi: f64 = 0;
            var tgt_hi: f64 = 0;
            for (self.fr[self.flat_ix..], self.target[self.flat_ix..]) |a, b| {
                fr_hi += a;
                tgt_hi += b;
            }
            fr_hi /= hi_count;
            tgt_hi /= hi_count;

            // Below flatten_f each sample is its own residual.
            var flat_residual: f64 = 0;
            for (self.min_f_ix..self.max_f_ix) |k| {
                if (k >= self.flat_ix) {
                    flat_residual += tgt_hi - fr_hi;
                } else {
                    self.weights[k] = -2.0 * (self.target[k] - self.fr[k]) / count;
                }
            }
            // Above it, every sample from flat_ix on shares one residual
            // through the mean, including samples past max_f_ix.
            if (flat_residual != 0) {
                const share = -2.0 * flat_residual / (count * hi_count);
                for (self.weights[self.flat_ix..]) |*w| w.* += share;
            }
        }

        var i: usize = 0;
        for (self.filters, 0..) |filt, k| {
            const rows = filt.paramCount();
            if (rows == 0) continue;
            const row = self.filt_fr[k * n ..][0..n];

            // The sharpness penalty depends on the filter's own response and,
            // through its sigmoid coefficient, directly on Q and gain.
            const coef = sharpnessCoefficient(filt);
            const dcoef = sharpnessCoefficientDerivatives(filt);
            var fr_sq_sum: f64 = 0;
            for (row) |v| fr_sq_sum += v * v;
            const nf: f64 = @floatFromInt(n);
            const wrt = parameterRows(filt);

            // Each derivative is folded into its dot products as it is
            // produced, so the rows are never written out.
            var dot_w: [3]f64 = undefined;
            var dot_fr: [3]f64 = undefined;
            switch (rows) {
                inline 1...3 => |r| derivativeDots(r, self.kernels[k], self.phi, self.weights, row, dot_w[0..r], dot_fr[0..r]),
                else => unreachable,
            }

            for (0..rows) |j| {
                var g = dot_w[j];
                if (self.sharpness and filt.kind == .peaking) {
                    // d/dp mean((fr * coef)^2), both factors varying.
                    g += 2.0 * coef * coef * dot_fr[j] / nf;
                    g += 2.0 * coef * dcoef[@intFromEnum(wrt.slice()[j])] * fr_sq_sum / nf;
                }
                // The loss is the square root of everything above.
                grad[i + j] = if (squared > 0) g / (2.0 * value) else 0;
            }
            i += rows;
        }
        std.debug.assert(i == grad.len);
        return value;
    }

    /// Dot products of each derivative row with the loss weights and with the
    /// filter's own response, without ever writing a row out.
    fn derivativeDots(
        comptime rows: usize,
        kern: Kernel,
        phi: []const f64,
        weights: []const f64,
        fr: []const f64,
        dot_w: *[rows]f64,
        dot_fr: *[rows]f64,
    ) void {
        var acc_w: [rows]Lane = @splat(@splat(0));
        var acc_fr: [rows]Lane = @splat(@splat(0));
        var i: usize = 0;
        while (i + lanes <= phi.len) : (i += lanes) {
            const p: Lane = phi[i..][0..lanes].*;
            const w: Lane = weights[i..][0..lanes].*;
            const v: Lane = fr[i..][0..lanes].*;
            const dv = kern.derivatives(rows, p);
            inline for (0..rows) |j| {
                acc_w[j] += w * dv[j];
                acc_fr[j] += v * dv[j];
            }
        }
        inline for (0..rows) |j| {
            dot_w[j] = @reduce(.Add, acc_w[j]);
            dot_fr[j] = @reduce(.Add, acc_fr[j]);
        }
        while (i < phi.len) : (i += 1) {
            const dv = kern.derivatives(rows, phi[i]);
            inline for (0..rows) |j| {
                dot_w[j] += weights[i] * dv[j];
                dot_fr[j] += fr[i] * dv[j];
            }
        }
    }

    /// `_init_optimizer_params`. Filters are initialized in a fixed order —
    /// fully free peaking bands first, most constrained shelves last — and
    /// each one is fitted to what the ones before it left behind.
    pub fn initialParams(self: *Peq, out: []f64) !void {
        const n = self.f.len;
        const remaining = try self.allocator.alloc(f64, n);
        defer self.allocator.free(remaining);
        @memcpy(remaining, self.target);

        const order = try self.allocator.alloc(usize, self.filters.len);
        defer self.allocator.free(order);
        for (order, 0..) |*o, i| o.* = i;
        // Descending by init rank, stably, which is what Python's
        // `sorted(..., reverse=True)` gives.
        std.sort.insertion(usize, order, self.filters, struct {
            fn lessThan(filters: []const Filter, a: usize, b: usize) bool {
                return initRank(filters[a]) > initRank(filters[b]);
            }
        }.lessThan);

        const scratch = self.filt_fr[0..n];
        for (order) |ix| {
            try initFilter(self.allocator, &self.filters[ix], self.f, self.fs, remaining);
            self.filters[ix].asBiquad().response(self.f, self.fs, scratch);
            for (remaining, scratch) |*r, v| r.* -= v;
        }

        self.getParams(out);
        self.refresh();
    }

    /// Fit the filters. `initialParams` must have run, or the caller must
    /// have supplied a starting point through `setParams`.
    pub fn optimize(self: *Peq, params: []f64, bnds: []const Bound) !Report {
        self.history_len = 0;
        self.seen = 0;
        if (params.len == 0) {
            // Every parameter is pinned, so there is nothing to fit.
            // `PEQ.optimize` returns immediately in the same case.
            self.refresh();
            return .{
                .loss = self.lossFromResponse(),
                .iterations = 0,
                .evaluations = 0,
                .status = .gradient_tolerance,
            };
        }
        const result = try lbfgs.minimize(self.allocator, self, params, bnds, self.stop.solver);
        self.setParams(params);
        self.refresh();
        return .{
            .loss = result.loss,
            .iterations = result.iterations,
            .evaluations = result.evaluations,
            .status = result.status,
        };
    }

    /// The objective `lbfgs.minimize` calls.
    pub fn evaluate(self: *Peq, x: []const f64, grad: []f64) f64 {
        return self.lossAndGradient(x, grad);
    }

    /// `PEQ._callback`'s stopping rules, checked after each accepted step.
    pub fn shouldStop(self: *Peq, value: f64) bool {
        if (self.stop.target_loss) |limit| {
            if (value <= limit) return true;
        }
        const min_std = self.stop.min_std orelse return false;

        if (self.history_len == self.history.len) {
            std.mem.copyForwards(f64, self.history[0 .. self.history.len - 1], self.history[1..]);
            self.history[self.history.len - 1] = value;
        } else {
            self.history[self.history_len] = value;
            self.history_len += 1;
        }
        // Upstream counts every callback, not just the ones inside the
        // window, so the guards are on the total seen.
        self.seen +|= 1;
        if (self.seen > 8 and stdDev(self.history[0..self.history_len]) < min_std) return true;
        if (self.seen > 4) {
            const tail = self.history[self.history_len -| 4..self.history_len];
            if (stdDev(tail) < min_std / 2.0) return true;
        }
        return false;
    }
};

/// Population standard deviation, which is `np.std`'s default.
fn stdDev(xs: []const f64) f64 {
    if (xs.len == 0) return 0;
    const n: f64 = @floatFromInt(xs.len);
    var mean: f64 = 0;
    for (xs) |v| mean += v;
    mean /= n;
    var acc: f64 = 0;
    for (xs) |v| acc += (v - mean) * (v - mean);
    return @sqrt(acc / n);
}

/// The sigmoid coefficient in `Peaking.sharpness_penalty`.
fn sharpnessCoefficient(filt: Filter) f64 {
    if (filt.kind != .peaking) return 0;
    const gain_limit = -0.09503189270199464 + 20.575128011847003 * (1.0 / filt.q);
    const x = filt.gain / gain_limit - 1.0;
    return 1.0 / (1.0 + math.pow(f64, math.e, -x * 100.0));
}

/// That coefficient's derivatives, indexed by `Wrt`. It does not depend on
/// fc at all.
fn sharpnessCoefficientDerivatives(filt: Filter) [3]f64 {
    if (filt.kind != .peaking) return .{ 0, 0, 0 };
    const gain_limit = -0.09503189270199464 + 20.575128011847003 * (1.0 / filt.q);
    const k = sharpnessCoefficient(filt);
    const dk_dx = 100.0 * k * (1.0 - k);
    // gain_limit = c0 + c1/q, so d(gain_limit)/dq = -c1/q^2.
    const dlimit_dq = -20.575128011847003 / (filt.q * filt.q);
    const dx_dq = -filt.gain * dlimit_dq / (gain_limit * gain_limit);
    const dx_dgain = 1.0 / gain_limit;
    return .{ 0, dk_dx * dx_dq, dk_dx * dx_dgain };
}

/// The 12-way ordering key from `_init_optimizer_params`. Filters are
/// initialized in descending order of this, so the most constrained ones go
/// first and the free peaking bands pick over what is left.
fn initRank(filt: Filter) f64 {
    const type_ix: usize = switch (filt.kind) {
        .peaking => 0,
        .low_shelf => 1,
        .high_shelf => 2,
    };
    const group: usize = (if (filt.optimize_fc) @as(usize, 0) else 2) +
        (if (filt.optimize_q) @as(usize, 0) else 1);
    var val: f64 = @floatFromInt((group * 3 + type_ix) * 100);
    if (filt.optimize_fc) {
        val += 1.0 / math.log2(filt.limits.max_fc / filt.limits.min_fc);
    }
    return val;
}

// ---------------------------------------------------------------------------
// Filter init heuristics
// ---------------------------------------------------------------------------

fn initFilter(
    allocator: std.mem.Allocator,
    filt: *Filter,
    f: []const f64,
    fs: f64,
    target: []const f64,
) !void {
    switch (filt.kind) {
        .peaking => try initPeaking(allocator, filt, f, target),
        .low_shelf, .high_shelf => try initShelf(allocator, filt, f, fs, target),
    }
}

/// `Peaking.init`. Rank every peak and dip of the remaining target by width
/// times height, take the biggest, and match a filter to it: centre on the
/// peak, set Q so the filter's bandwidth equals the peak's width, and set
/// gain to the peak's height.
fn initPeaking(
    allocator: std.mem.Allocator,
    filt: *Filter,
    f: []const f64,
    target: []const f64,
) !void {
    const min_fc_ix = util.argminAbs(f, filt.limits.min_fc);
    const max_fc_ix = util.argminAbs(f, filt.limits.max_fc);

    const clipped = try allocator.alloc(f64, target.len);
    defer allocator.free(clipped);

    // Peaks of the target, then peaks of its negation: `find_peaks` on
    // `clip(target, 0, None)` and on `clip(-target, 0, None)`.
    var best_size = -math.inf(f64);
    var best: ?peaks.Measured = null;
    for ([2]f64{ 1.0, -1.0 }) |sign| {
        for (clipped, target) |*c, t| c.* = @max(sign * t, 0.0);
        const found = try peaks.measure(allocator, clipped);
        defer allocator.free(found);
        for (found) |p| {
            if (p.index < min_fc_ix or p.index > max_fc_ix) continue;
            const size = p.width * p.height;
            if (size > best_size) {
                best_size = size;
                best = p;
            }
        }
    }

    if (best == null) {
        // Nothing usable in range. Upstream parks the filter in the middle of
        // its allowed band and leaves it flat.
        if (filt.optimize_fc) filt.fc = f[(min_fc_ix + max_fc_ix) / 2];
        if (filt.optimize_q) filt.q = math.sqrt2;
        if (filt.optimize_gain) filt.gain = 0.0;
        return;
    }

    const p = best.?;
    if (filt.optimize_fc) {
        filt.fc = math.clamp(f[p.index], filt.limits.min_fc, filt.limits.max_fc);
    }
    if (filt.optimize_q) {
        // Bandwidth in octaves that spans `width` samples of this grid.
        const f_step = math.log2(f[1] / f[0]);
        const bw = f_step * p.width;
        const two_bw = math.pow(f64, 2.0, bw);
        filt.q = math.clamp(@sqrt(two_bw) / (two_bw - 1.0), filt.limits.min_q, filt.limits.max_q);
    }
    if (filt.optimize_gain) {
        const g = if (target[p.index] > 0) p.height else -p.height;
        filt.gain = math.clamp(g, filt.limits.min_gain, filt.limits.max_gain);
    }
}

/// `LowShelf.init` and `HighShelf.init`. Search for the transition point that
/// maximises the mean level on the shelf's own side, then set gain to a
/// weighted average of the target with a 1 dB shelf as the weight vector.
///
/// Every shipped upstream preset pins shelf fc and Q, so in practice only the
/// gain branch runs. The fc search is ported because turboEQ may offer free
/// shelves, and it is where upstream's own quirk lives: the high shelf uses
/// the argmax over its candidate range directly as an index into `f`, without
/// adding the range's own start offset the way the low shelf does.
fn initShelf(
    allocator: std.mem.Allocator,
    filt: *Filter,
    f: []const f64,
    fs: f64,
    target: []const f64,
) !void {
    if (filt.optimize_fc) {
        const min_ix = countBelow(f, @max(40.0, filt.limits.min_fc));
        const max_ix = countBelow(f, @min(10000.0, filt.limits.max_fc));
        var best = -math.inf(f64);
        var best_k: usize = 0;
        var k = min_ix;
        while (k < max_ix) : (k += 1) {
            const slice = if (filt.kind == .high_shelf) target[k..] else target[0 .. k + 1];
            var sum: f64 = 0;
            for (slice) |v| sum += v;
            const score = @abs(sum / @as(f64, @floatFromInt(slice.len)));
            if (score > best) {
                best = score;
                best_k = k;
            }
        }
        // Reproduced verbatim: the low shelf converts the argmax back into an
        // index of `f`, the high shelf does not.
        const ix = if (filt.kind == .high_shelf) best_k - min_ix else best_k;
        filt.fc = math.clamp(f[ix], filt.limits.min_fc, filt.limits.max_fc);
    }
    if (filt.optimize_q) {
        filt.q = math.clamp(0.7, filt.limits.min_q, filt.limits.max_q);
    }
    if (filt.optimize_gain) {
        const unit = try allocator.alloc(f64, f.len);
        defer allocator.free(unit);
        const probe = biquad.Filter{ .kind = filt.kind, .fc = filt.fc, .q = filt.q, .gain = 1.0 };
        probe.response(f, fs, unit);
        var num: f64 = 0;
        var den: f64 = 0;
        for (target, unit) |t, u| {
            num += t * u;
            den += u;
        }
        filt.gain = math.clamp(num / den, filt.limits.min_gain, filt.limits.max_gain);
    }
}

/// `np.sum(f < x)`, which on an ascending axis is the index of the first
/// sample at or above `x`.
fn countBelow(f: []const f64, x: f64) usize {
    var n: usize = 0;
    for (f) |v| {
        if (v < x) n += 1 else break;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testGrid(allocator: std.mem.Allocator) ![]f64 {
    return util.generateFrequencies(allocator, 20.0, 20000.0, 1.02);
}

test "logLanes agrees with @log to within an ulp" {
    var prng = std.Random.DefaultPrng.init(0x1f0e);
    const rand = prng.random();
    var worst: u64 = 0;
    for (0..200000) |_| {
        // Log-uniform over a range much wider than any magnitude ratio,
        // and a cluster around 1 where the reduction is most delicate.
        const a = math.pow(f64, 10.0, (rand.float(f64) - 0.5) * 40.0);
        const b = 1.0 + (rand.float(f64) - 0.5) * 1e-6;
        const got: [lanes]f64 = logLanes(.{ a, b });
        for ([_]f64{ a, b }, got) |x, g| {
            const gb: i64 = @bitCast(g);
            const wb: i64 = @bitCast(@log(x));
            worst = @max(worst, @abs(gb - wb));
        }
    }
    try std.testing.expect(worst <= 1);
    const edge = logLanes(.{ 1.0, math.floatMin(f64) / 4.0 });
    try std.testing.expectEqual(@as(f64, 0.0), edge[0]);
    try std.testing.expectEqual(@log(math.floatMin(f64) / 4.0), edge[1]);
}

test "coefficient jets agree with the biquad kernel" {
    const cases = [_]Filter{
        .{ .kind = .peaking, .fc = 1000.0, .q = 1.41, .gain = -6.0, .limits = peaking_limits },
        .{ .kind = .low_shelf, .fc = 105.0, .q = 0.7, .gain = 6.0, .limits = shelf_limits },
        .{ .kind = .high_shelf, .fc = 10000.0, .q = 0.4, .gain = -9.0, .limits = shelf_limits },
    };
    for (cases) |filt| {
        const j = jet(filt.kind, filt.fc, filt.q, filt.gain, 44100.0);
        const c = filt.asBiquad().coefficients(44100.0);
        // `magnitude()` undoes the negation `biquad_coefficients()` applies.
        try std.testing.expectApproxEqRel(-c.a1, j.a1, 1e-12);
        try std.testing.expectApproxEqRel(-c.a2, j.a2, 1e-12);
        try std.testing.expectApproxEqRel(c.b0, j.b0, 1e-12);
        try std.testing.expectApproxEqRel(c.b1, j.b1, 1e-12);
        try std.testing.expectApproxEqRel(c.b2, j.b2, 1e-12);
    }
}

test "response derivatives match central differences" {
    const f = [_]f64{ 20.0, 100.0, 1000.0, 5000.0, 12000.0, 19000.0 };
    const fs = 44100.0;
    const cases = [_]Filter{
        .{ .kind = .peaking, .fc = 3000.0, .q = 2.5, .gain = -5.0, .limits = peaking_limits },
        .{ .kind = .peaking, .fc = 80.0, .q = 0.5, .gain = 8.0, .limits = peaking_limits },
        .{ .kind = .low_shelf, .fc = 105.0, .q = 0.7, .gain = 4.0, .limits = shelf_limits },
        .{ .kind = .high_shelf, .fc = 9000.0, .q = 0.55, .gain = -3.0, .limits = shelf_limits },
    };
    var phi: [6]f64 = undefined;
    var fr: [6]f64 = undefined;
    var derivs: [18]f64 = undefined;
    var plus: [6]f64 = undefined;
    var minus: [6]f64 = undefined;

    for (cases) |filt| {
        biquad.phiFor(&f, fs, &phi);
        responseAndDerivatives(filt, &phi, fs, &fr, &derivs);
        for (0..3) |p| {
            // Well below 100 Hz the response is a difference of two nearly
            // equal logarithms, so the *reference* here is the imprecise
            // side: a smaller step makes the comparison worse, not better.
            const h: f64 = 1e-4;
            var a = filt;
            var b = filt;
            switch (p) {
                0 => {
                    a.fc = math.pow(f64, 10.0, math.log10(filt.fc) + h);
                    b.fc = math.pow(f64, 10.0, math.log10(filt.fc) - h);
                },
                1 => {
                    a.q = filt.q + h;
                    b.q = filt.q - h;
                },
                else => {
                    a.gain = filt.gain + h;
                    b.gain = filt.gain - h;
                },
            }
            a.asBiquad().response(&f, fs, &plus);
            b.asBiquad().response(&f, fs, &minus);
            for (plus, minus, 0..) |pv, mv, i| {
                const want = (pv - mv) / (2 * h);
                try std.testing.expectApproxEqAbs(want, derivs[p * f.len + i], 1e-5);
            }
        }
    }
}

test "the loss gradient matches central differences" {
    const allocator = std.testing.allocator;
    const f = try testGrid(allocator);
    defer allocator.free(f);

    const target = try allocator.alloc(f64, f.len);
    defer allocator.free(target);
    for (f, target) |fv, *t| {
        t.* = 3.0 * @sin(math.log10(fv) * 4.0) - 1.5 * math.log10(fv / 1000.0);
    }

    // Upstream's flattening above 10 kHz and none at all, each with and
    // without the sharpness penalty.
    for ([_]f64{ 10000.0, math.inf(f64), 10000.0, math.inf(f64) }, 0..) |flatten_f, case| {
        const filters = try peakingWithShelvesConfig(allocator, 3);
        defer allocator.free(filters);

        var peq = try Peq.init(allocator, f, 44100.0, filters, target, .{
            .flatten_f = flatten_f,
            .sharpness_penalty = case < 2,
        });
        defer peq.deinit();

        const params = try allocator.alloc(f64, peq.paramCount());
        defer allocator.free(params);
        try peq.initialParams(params);

        const grad = try allocator.alloc(f64, params.len);
        defer allocator.free(grad);
        _ = peq.lossAndGradient(params, grad);

        const probe = try allocator.dupe(f64, params);
        defer allocator.free(probe);
        for (params, 0..) |p0, i| {
            const h = 1e-6 * @max(1.0, @abs(p0));
            probe[i] = p0 + h;
            const up = peq.loss(probe);
            probe[i] = p0 - h;
            const down = peq.loss(probe);
            probe[i] = p0;
            const want = (up - down) / (2 * h);
            try std.testing.expectApproxEqAbs(want, grad[i], 1e-6 + 1e-4 * @abs(want));
        }
    }
}

test "a treble peak reaches the loss only once flattening is off" {
    const allocator = std.testing.allocator;
    const f = try testGrid(allocator);
    defer allocator.free(f);

    // A peak and a dip above 10 kHz that cancel in the mean.
    const target = try allocator.alloc(f64, f.len);
    defer allocator.free(target);
    for (f, target) |fv, *t| {
        const l = math.log10(fv);
        t.* = 6.0 * @exp(-((l - 4.1) * (l - 4.1)) / 0.001) - 6.0 * @exp(-((l - 4.25) * (l - 4.25)) / 0.001);
    }

    var losses: [2]f64 = undefined;
    for ([_]f64{ 10000.0, math.inf(f64) }, &losses) |flatten_f, *out| {
        const filters = try peakingConfig(allocator, 1);
        defer allocator.free(filters);
        // A flat filter, so the loss is the target's error alone.
        filters[0].fc = 1000.0;
        filters[0].q = 1.0;
        var peq = try Peq.init(allocator, f, 44100.0, filters, target, .{ .flatten_f = flatten_f });
        defer peq.deinit();
        peq.refresh();
        out.* = peq.lossFromResponse();
    }
    try std.testing.expect(losses[1] > 10.0 * losses[0]);
}

test "without the sharpness penalty the loss is the error alone" {
    const allocator = std.testing.allocator;
    const f = try testGrid(allocator);
    defer allocator.free(f);

    // A flat target and one steep band, far past 18 dB/octave.
    const target = try allocator.alloc(f64, f.len);
    defer allocator.free(target);
    @memset(target, 0);

    var losses: [2]f64 = undefined;
    for ([_]bool{ true, false }, &losses) |sharpness, *out| {
        const filters = try peakingConfig(allocator, 1);
        defer allocator.free(filters);
        filters[0].fc = 3000.0;
        filters[0].q = 10.0;
        filters[0].gain = 15.0;
        var peq = try Peq.init(allocator, f, 44100.0, filters, target, .{
            .flatten_f = math.inf(f64),
            .sharpness_penalty = sharpness,
        });
        defer peq.deinit();
        peq.refresh();
        out.* = peq.lossFromResponse();

        if (!sharpness) {
            var sum: f64 = 0;
            for (peq.min_f_ix..peq.max_f_ix) |k| sum += peq.fr[k] * peq.fr[k];
            const mse = sum / @as(f64, @floatFromInt(peq.max_f_ix - peq.min_f_ix));
            try std.testing.expectApproxEqRel(@sqrt(mse), out.*, 1e-12);
        }
    }
    try std.testing.expect(losses[0] > losses[1]);
}

test "optimizing lowers the loss and respects the bounds" {
    const allocator = std.testing.allocator;
    const f = try testGrid(allocator);
    defer allocator.free(f);

    const target = try allocator.alloc(f64, f.len);
    defer allocator.free(target);
    for (f, target) |fv, *t| {
        const l = math.log10(fv);
        t.* = 4.0 * @exp(-((l - 3.0) * (l - 3.0)) / 0.02) - 2.0 * @exp(-((l - 2.0) * (l - 2.0)) / 0.05);
    }

    const filters = try peakingConfig(allocator, 4);
    defer allocator.free(filters);

    var peq = try Peq.init(allocator, f, 44100.0, filters, target, .{});
    defer peq.deinit();

    const params = try allocator.alloc(f64, peq.paramCount());
    defer allocator.free(params);
    try peq.initialParams(params);
    const before = peq.lossFromResponse();

    const bnds = try allocator.alloc(Bound, params.len);
    defer allocator.free(bnds);
    peq.bounds(bnds);

    const report = try peq.optimize(params, bnds);
    try std.testing.expect(report.loss < before);
    for (params, bnds) |p, b| {
        try std.testing.expect(p >= b.lo and p <= b.hi);
    }
    for (peq.filters) |filt| {
        try std.testing.expect(filt.q >= peaking_limits.min_q - 1e-12);
        try std.testing.expect(filt.q <= peaking_limits.max_q + 1e-12);
    }
}

test "a flat target needs no correction" {
    const allocator = std.testing.allocator;
    const f = try testGrid(allocator);
    defer allocator.free(f);
    const target = try allocator.alloc(f64, f.len);
    defer allocator.free(target);
    @memset(target, 0);

    const filters = try peakingConfig(allocator, 2);
    defer allocator.free(filters);
    var peq = try Peq.init(allocator, f, 44100.0, filters, target, .{});
    defer peq.deinit();

    const params = try allocator.alloc(f64, peq.paramCount());
    defer allocator.free(params);
    try peq.initialParams(params);
    const bnds = try allocator.alloc(Bound, params.len);
    defer allocator.free(bnds);
    peq.bounds(bnds);
    const report = try peq.optimize(params, bnds);
    try std.testing.expect(report.loss < 1e-6);
}

test "the early-stop rules cut the fit short" {
    const allocator = std.testing.allocator;
    const f = try testGrid(allocator);
    defer allocator.free(f);

    const target = try allocator.alloc(f64, f.len);
    defer allocator.free(target);
    for (f, target) |fv, *t| {
        const l = math.log10(fv);
        t.* = 5.0 * @exp(-((l - 3.2) * (l - 3.2)) / 0.03) - 3.0 * @exp(-((l - 2.2) * (l - 2.2)) / 0.04);
    }

    const filters = try peakingConfig(allocator, 5);
    defer allocator.free(filters);

    const params = try allocator.alloc(f64, 15);
    defer allocator.free(params);
    const bnds = try allocator.alloc(Bound, params.len);
    defer allocator.free(bnds);

    var full: Report = undefined;
    {
        var eq = try Peq.init(allocator, f, 44100.0, filters, target, .{});
        defer eq.deinit();
        try eq.initialParams(params);
        eq.bounds(bnds);
        full = try eq.optimize(params, bnds);
    }

    // Upstream's own rule: stop once the last handful of losses stop moving.
    var early: Report = undefined;
    {
        var eq = try Peq.init(allocator, f, 44100.0, filters, target, .{});
        defer eq.deinit();
        eq.stop.min_std = 0.008;
        try eq.initialParams(params);
        eq.bounds(bnds);
        early = try eq.optimize(params, bnds);
    }
    try std.testing.expect(early.iterations < full.iterations);
    // Cheaper, and measurably worse: this is the trade BENCHMARKS.md records.
    try std.testing.expect(early.loss > full.loss);

    // A target loss stops as soon as it is reached, never before.
    {
        var eq = try Peq.init(allocator, f, 44100.0, filters, target, .{});
        defer eq.deinit();
        eq.stop.target_loss = full.loss + 0.05;
        try eq.initialParams(params);
        eq.bounds(bnds);
        const hit = try eq.optimize(params, bnds);
        try std.testing.expect(hit.loss <= full.loss + 0.05);
        try std.testing.expect(hit.iterations <= full.iterations);
    }
}

test "a fully pinned bank reports its loss without fitting anything" {
    const allocator = std.testing.allocator;
    const f = try testGrid(allocator);
    defer allocator.free(f);
    const target = try allocator.alloc(f64, f.len);
    defer allocator.free(target);
    @memset(target, 0);

    var filters = [_]Filter{.{
        .kind = .peaking,
        .fc = 1000.0,
        .q = 1.0,
        .gain = 3.0,
        .optimize_fc = false,
        .optimize_q = false,
        .optimize_gain = false,
        .limits = peaking_limits,
    }};
    var eq = try Peq.init(allocator, f, 44100.0, &filters, target, .{});
    defer eq.deinit();

    const report = try eq.optimize(&.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), report.evaluations);
    eq.refresh();
    try std.testing.expectApproxEqAbs(eq.lossFromResponse(), report.loss, 1e-15);
    try std.testing.expect(report.loss > 0);
    // The 1.02 grid has no sample exactly at 1 kHz, so the peak reads just
    // under the filter's nominal gain.
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), eq.maxGain(), 0.01);
}

test "free shelves place themselves and stay inside their bounds" {
    // Every shipped upstream preset pins shelf fc and Q, so `initShelf`'s
    // search and its weighted-average gain run in no fixture. turboEQ offers
    // free shelves as an option, which makes this the only cover that path
    // has. See CLAUDE.md on `HighShelf.init` landing `min_ix` samples low —
    // that quirk is reproduced, so this checks the bounds and the direction
    // rather than an exact frequency.
    const allocator = std.testing.allocator;
    const f = try testGrid(allocator);
    defer allocator.free(f);

    // A curve wanting bass cut and treble boost: the low shelf has to go
    // negative and the high shelf positive.
    const target = try allocator.alloc(f64, f.len);
    defer allocator.free(target);
    for (f, target) |fv, *t| {
        t.* = if (fv < 200.0) -6.0 else if (fv > 6000.0) 4.0 else 0.0;
    }

    var filters = [_]Filter{
        .{ .kind = .low_shelf, .fc = 0, .q = 0, .gain = 0, .limits = shelf_limits },
        .{ .kind = .high_shelf, .fc = 0, .q = 0, .gain = 0, .limits = shelf_limits },
    };
    for (&filters) |*filt| {
        try std.testing.expect(filt.optimize_fc and filt.optimize_q and filt.optimize_gain);
    }

    var eq = try Peq.init(allocator, f, 44100.0, &filters, target, .{});
    defer eq.deinit();

    const params = try allocator.alloc(f64, eq.paramCount());
    defer allocator.free(params);
    const bounds = try allocator.alloc(Bound, params.len);
    defer allocator.free(bounds);

    // Three free parameters each, which is what a pinned shelf does not have.
    try std.testing.expectEqual(@as(usize, 6), params.len);
    try eq.initialParams(params);

    // `init()` placed both before the solver ran: inside the fc window, at
    // upstream's 0.7 starting Q, and already pointing the right way.
    for (filters) |filt| {
        try std.testing.expect(filt.fc >= shelf_limits.min_fc and filt.fc <= shelf_limits.max_fc);
        try std.testing.expectApproxEqAbs(@as(f64, 0.7), filt.q, 1e-12);
    }
    try std.testing.expect(filters[0].gain < 0);
    try std.testing.expect(filters[1].gain > 0);

    eq.bounds(bounds);
    const before = eq.lossFromResponse();
    const report = try eq.optimize(params, bounds);
    try std.testing.expect(report.loss < before);

    for (filters) |filt| {
        try std.testing.expect(filt.fc >= shelf_limits.min_fc - 1e-9);
        try std.testing.expect(filt.fc <= shelf_limits.max_fc + 1e-9);
        try std.testing.expect(filt.q >= shelf_limits.min_q - 1e-9);
        try std.testing.expect(filt.q <= shelf_limits.max_q + 1e-9);
        try std.testing.expect(filt.gain >= shelf_limits.min_gain - 1e-9);
        try std.testing.expect(filt.gain <= shelf_limits.max_gain + 1e-9);
    }
    // Still pointing the right way once fitted.
    try std.testing.expect(filters[0].gain < 0);
    try std.testing.expect(filters[1].gain > 0);
}
