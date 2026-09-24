//! The filter kernel.
//!
//! Peaking, low shelf and high shelf biquads, their magnitude response, and
//! the two optimizer penalties that hang off a single filter.
//!
//! Derived from AutoEq (MIT, Jaakko Pasanen), autoeq/peq.py.

const std = @import("std");
const math = std.math;
const util = @import("util.zig");

pub const Kind = enum { peaking, low_shelf, high_shelf };

/// Coefficients exactly as `PEQFilter.biquad_coefficients()` returns them:
/// normalised by the raw `a0`, with `a1` and `a2` already negated. `fr()`
/// negates them back before evaluating, and so does `magnitude` below.
pub const Coefficients = struct {
    a0: f64,
    a1: f64,
    a2: f64,
    b0: f64,
    b1: f64,
    b2: f64,
};

pub const Filter = struct {
    kind: Kind,
    fc: f64,
    q: f64,
    gain: f64,

    pub fn coefficients(self: Filter, fs: f64) Coefficients {
        return switch (self.kind) {
            .peaking => peakingCoefficients(self.fc, self.q, self.gain, fs),
            .low_shelf => lowShelfCoefficients(self.fc, self.q, self.gain, fs),
            .high_shelf => highShelfCoefficients(self.fc, self.q, self.gain, fs),
        };
    }

    /// Magnitude response in dB, one entry per frequency.
    pub fn response(self: Filter, f: []const f64, fs: f64, out: []f64) void {
        magnitude(self.coefficients(fs), f, fs, out);
    }
};

pub fn peakingCoefficients(fc: f64, q: f64, gain: f64, fs: f64) Coefficients {
    const a = math.pow(f64, 10.0, gain / 40.0);
    const w0 = 2.0 * math.pi * fc / fs;
    const alpha = @sin(w0) / (2.0 * q);

    const a0 = 1.0 + alpha / a;
    return .{
        .a0 = 1.0,
        .a1 = -(-2.0 * @cos(w0)) / a0,
        .a2 = -(1.0 - alpha / a) / a0,
        .b0 = (1.0 + alpha * a) / a0,
        .b1 = (-2.0 * @cos(w0)) / a0,
        .b2 = (1.0 - alpha * a) / a0,
    };
}

pub fn lowShelfCoefficients(fc: f64, q: f64, gain: f64, fs: f64) Coefficients {
    const a = math.pow(f64, 10.0, gain / 40.0);
    const w0 = 2.0 * math.pi * fc / fs;
    const alpha = @sin(w0) / (2.0 * q);
    const cw = @cos(w0);
    const sqrt_a = @sqrt(a);

    const a0 = (a + 1.0) + (a - 1.0) * cw + 2.0 * sqrt_a * alpha;
    return .{
        .a0 = 1.0,
        .a1 = -(-2.0 * ((a - 1.0) + (a + 1.0) * cw)) / a0,
        .a2 = -((a + 1.0) + (a - 1.0) * cw - 2.0 * sqrt_a * alpha) / a0,
        .b0 = (a * ((a + 1.0) - (a - 1.0) * cw + 2.0 * sqrt_a * alpha)) / a0,
        .b1 = (2.0 * a * ((a - 1.0) - (a + 1.0) * cw)) / a0,
        .b2 = (a * ((a + 1.0) - (a - 1.0) * cw - 2.0 * sqrt_a * alpha)) / a0,
    };
}

pub fn highShelfCoefficients(fc: f64, q: f64, gain: f64, fs: f64) Coefficients {
    const a = math.pow(f64, 10.0, gain / 40.0);
    const w0 = 2.0 * math.pi * fc / fs;
    const alpha = @sin(w0) / (2.0 * q);
    const cw = @cos(w0);
    const sqrt_a = @sqrt(a);

    const a0 = (a + 1.0) - (a - 1.0) * cw + 2.0 * sqrt_a * alpha;
    return .{
        .a0 = 1.0,
        .a1 = -(2.0 * ((a - 1.0) - (a + 1.0) * cw)) / a0,
        .a2 = -((a + 1.0) - (a - 1.0) * cw - 2.0 * sqrt_a * alpha) / a0,
        .b0 = (a * ((a + 1.0) + (a - 1.0) * cw + 2.0 * sqrt_a * alpha)) / a0,
        .b1 = (-2.0 * a * ((a - 1.0) + (a + 1.0) * cw)) / a0,
        .b2 = (a * ((a + 1.0) + (a - 1.0) * cw - 2.0 * sqrt_a * alpha)) / a0,
    };
}

/// `phi = 4*sin(w/2)^2`, the only thing in the magnitude that depends on the
/// frequency axis rather than on the filter. A caller evaluating many filters
/// on one axis computes it once and hands it to `magnitudeFromPhi`.
pub fn phiFor(f: []const f64, fs: f64, out: []f64) void {
    std.debug.assert(f.len == out.len);
    for (f, out) |fv, *o| {
        const w = 2.0 * math.pi * fv / fs;
        const s = @sin(w / 2.0);
        o.* = 4.0 * s * s;
    }
}

/// The parts of `PEQFilter.fr` that depend only on the coefficients, hoisted
/// out of the per-frequency loop.
pub const Terms = struct {
    b_sum: f64,
    a_sum: f64,
    b_mix: f64,
    a_mix: f64,
    b_prod: f64,
    a_prod: f64,

    pub fn of(c: Coefficients) Terms {
        // fr() undoes the negation biquad_coefficients() applied.
        const a0 = c.a0;
        const a1 = -c.a1;
        const a2 = -c.a2;
        return .{
            .b_sum = (c.b0 + c.b1 + c.b2) * (c.b0 + c.b1 + c.b2),
            .a_sum = (a0 + a1 + a2) * (a0 + a1 + a2),
            .b_mix = c.b1 * (c.b0 + c.b2) + 4.0 * c.b0 * c.b2,
            .a_mix = a1 * (a0 + a2) + 4.0 * a0 * a2,
            .b_prod = c.b0 * c.b2,
            .a_prod = a0 * a2,
        };
    }

    pub fn at(self: Terms, phi: f64) f64 {
        const num = self.b_sum + (self.b_prod * phi - self.b_mix) * phi;
        const den = self.a_sum + (self.a_prod * phi - self.a_mix) * phi;
        return 10.0 * math.log10(num) - 10.0 * math.log10(den);
    }
};

/// `PEQFilter.fr`. The `phi = 4*sin(w/2)^2` form, which evaluates the
/// magnitude without ever forming a complex number.
pub fn magnitude(c: Coefficients, f: []const f64, fs: f64, out: []f64) void {
    std.debug.assert(f.len == out.len);
    const terms = Terms.of(c);
    for (f, out) |fv, *o| {
        const w = 2.0 * math.pi * fv / fs;
        const s = @sin(w / 2.0);
        o.* = terms.at(4.0 * s * s);
    }
}

/// `magnitude` against an axis whose `phi` is already in hand.
pub fn magnitudeFromPhi(c: Coefficients, phi: []const f64, out: []f64) void {
    std.debug.assert(phi.len == out.len);
    const terms = Terms.of(c);
    for (phi, out) |p, *o| o.* = terms.at(p);
}

/// Sum of the member responses, in dB. `PEQ.fr`.
pub fn cascade(filters: []const Filter, f: []const f64, fs: f64, out: []f64, scratch: []f64) void {
    std.debug.assert(out.len == f.len);
    std.debug.assert(scratch.len == f.len);
    @memset(out, 0.0);
    for (filters) |filt| {
        filt.response(f, fs, scratch);
        for (out, scratch) |*o, s| o.* += s;
    }
}

/// `Peaking.sharpness_penalty`. Zero for shelves, which overshoot long
/// before they approach 18 dB/octave.
///
/// `fr` is the filter's own response, already evaluated.
pub fn sharpnessPenalty(kind: Kind, q: f64, gain: f64, fr: []const f64) f64 {
    if (kind != .peaking) return 0.0;
    // Polynomial fit for the peaking gain that reaches an 18 dB/octave
    // maximum derivative. Accurate near 18 dB/oct, which is all it is for.
    const gain_limit = -0.09503189270199464 + 20.575128011847003 * (1.0 / q);
    const x = gain / gain_limit - 1.0;
    const coefficient = 1.0 / (1.0 + math.pow(f64, math.e, -x * 100.0));
    var sum: f64 = 0.0;
    for (fr) |v| {
        const t = v * coefficient;
        sum += t * t;
    }
    return sum / @as(f64, @floatFromInt(fr.len));
}

/// `PEQFilter.band_penalty`. Mean squared error between the two sides of the
/// response about `fc`, which grows as the transition band runs off the end
/// of the usable range.
///
/// The right-hand bound is `argmin(abs(f - fs))`, not the index of 10 kHz.
/// Upstream names the property `ix10k` but compares against the sample rate,
/// so on a 20 Hz to 20 kHz axis it is always the last index. Reproduced
/// deliberately: changing it would change every penalty value.
pub fn bandPenalty(kind: Kind, fc: f64, gain: f64, f: []const f64, fs: f64, fr: []const f64) f64 {
    const fc_ix = util.argminAbs(f, fc);
    const ix10k = util.argminAbs(f, fs);
    if (ix10k <= fc_ix) return 0.0;
    const n = @min(fc_ix, ix10k - fc_ix);
    if (n == 0) return 0.0;

    var sum: f64 = 0.0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const left = fr[fc_ix - n + k];
        const right = fr[fc_ix + n - 1 - k];
        const d = switch (kind) {
            .peaking => left - right,
            .low_shelf, .high_shelf => left - (gain - right),
        };
        sum += d * d;
    }
    return sum / @as(f64, @floatFromInt(n));
}

test "a zero gain shelf is transparent" {
    const f = [_]f64{ 20.0, 100.0, 1000.0, 10000.0, 19000.0 };
    var out: [5]f64 = undefined;
    const filt = Filter{ .kind = .low_shelf, .fc = 105.0, .q = 0.7, .gain = 0.0 };
    filt.response(&f, 44100.0, &out);
    for (out) |v| try std.testing.expectApproxEqAbs(@as(f64, 0.0), v, 1e-12);
}

test "a cascade sums its members in dB" {
    const f = [_]f64{ 50.0, 200.0, 1000.0, 8000.0 };
    const fs = 44100.0;
    const filters = [_]Filter{
        .{ .kind = .low_shelf, .fc = 105.0, .q = 0.7, .gain = 6.0 },
        .{ .kind = .peaking, .fc = 1000.0, .q = 1.41, .gain = -6.0 },
        .{ .kind = .high_shelf, .fc = 10000.0, .q = 0.7, .gain = 3.0 },
    };
    var out: [4]f64 = undefined;
    var scratch: [4]f64 = undefined;
    cascade(&filters, &f, fs, &out, &scratch);

    var want: [4]f64 = @splat(0.0);
    for (filters) |filt| {
        filt.response(&f, fs, &scratch);
        for (&want, scratch) |*w, s| w.* += s;
    }
    for (want, out) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-12);
    // The low shelf dominates well below its corner.
    try std.testing.expect(out[0] > 5.0);
}

test "a peaking filter hits its gain at fc" {
    const f = [_]f64{1000.0};
    var out: [1]f64 = undefined;
    const filt = Filter{ .kind = .peaking, .fc = 1000.0, .q = 1.41, .gain = -6.0 };
    filt.response(&f, 44100.0, &out);
    try std.testing.expectApproxEqAbs(@as(f64, -6.0), out[0], 1e-9);
}
