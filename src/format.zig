//! What a caller does with the answer.
//!
//! These are formatters over a filter list and an equalization curve. There
//! is no fitting here and no objective — nothing in this file is parity
//! checked against upstream's *numbers*, only against its text, because the
//! numbers were already checked upstream of it.
//!
//! It is deliberately outside the wasm module — nothing there references it,
//! so the linker drops it. String formatting is one thing a host's own
//! runtime does better than a shipped binary, and every byte spent on it here
//! would be a byte every browser downloads twice over. `js/eqapo.js` is the
//! same two functions for that side.
//!
//! Derived from AutoEq (MIT, Jaakko Pasanen), autoeq/frequency_response.py.

const std = @import("std");
const math = std.math;
const peq = @import("peq.zig");
const curve = @import("curve.zig");
const util = @import("util.zig");

/// `PREAMP_HEADROOM`. Upstream leaves this much room below the loudest
/// sample of a normalized graphic EQ, and does not apply it to the
/// parametric one.
pub const preamp_headroom: f64 = 0.2;

/// `DEFAULT_GRAPHIC_EQ_STEP`. The comment upstream is worth keeping: this
/// produces 127 samples with a greatest frequency of 19871.
pub const graphic_eq_step: f64 = 1.0563;

/// Round to `decimals` places the way Python's `format` does, which is
/// half-to-even rather than Zig's half-away-from-zero. A gain of exactly
/// -1.25 prints as `-1.2` upstream and would print as `-1.3` here without
/// this; both are defensible and only one of them matches the reference.
///
/// The tie is detected after scaling by a power of ten, so this agrees with
/// Python wherever the value is an *exact* binary tie — which is every tie a
/// pinned or bounded parameter produces, and the only kind that arises in
/// practice. A value merely near a tie, such as 0.35 (which is really
/// 0.34999...), can scale onto one and round the other way. That costs one
/// digit in the last place of a display string; matching Python there would
/// mean writing a correct decimal expansion, which this is not.
fn roundHalfEven(v: f64, comptime decimals: comptime_int) f64 {
    if (!math.isFinite(v)) return v;
    const scale = math.pow(f64, 10.0, decimals);
    const scaled = v * scale;
    const floored = @floor(scaled);
    const frac = scaled - floored;
    const rounded = if (frac > 0.5)
        floored + 1.0
    else if (frac < 0.5)
        floored
    else if (@mod(floored, 2.0) == 0.0)
        floored
    else
        floored + 1.0;
    return rounded / scale;
}

/// EqualizerAPO's name for each filter kind.
fn apoType(kind: peq.Kind) []const u8 {
    return switch (kind) {
        .peaking => "PK",
        .low_shelf => "LSC",
        .high_shelf => "HSC",
    };
}

/// `write_eqapo_parametric_eq`, as a string.
///
/// The preamp line is `-max_gain`, where `max_gain` is the largest boost the
/// whole cascade applies — not the largest single filter gain, which is a
/// different and usually smaller number. `pipeline.Result.max_gain` is
/// already that value.
///
/// Upstream writes `-{max_gain:.1f}`, with no headroom and no clamp, so a
/// cascade that only ever cuts produces a *positive* preamp. Reproduced:
/// the alternative is second-guessing a number the caller can clamp itself.
pub fn eqapoParametric(
    allocator: std.mem.Allocator,
    filters: []const peq.Filter,
    max_gain: f64,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "Preamp: {d:.1} dB\n", .{roundHalfEven(-max_gain, 1)});
    for (filters, 1..) |filt, i| {
        try out.print(
            allocator,
            "Filter {d}: ON {s} Fc {d:.0} Hz Gain {d:.1} dB Q {d:.2}\n",
            .{
                i,
                apoType(filt.kind),
                roundHalfEven(filt.fc, 0),
                roundHalfEven(filt.gain, 1),
                roundHalfEven(filt.q, 2),
            },
        );
    }
    return out.toOwnedSlice(allocator);
}

/// `eqapo_graphic_eq`, as a string. `f` and `equalization` are the working
/// grid and the curve on it, which is what `pipeline.Result` carries.
///
/// Three details are upstream's and all three are load-bearing:
///
///   - the axis is `20 * step^n` **truncated to integers and deduplicated**,
///     which is why it is not simply a log grid;
///   - normalizing subtracts `max + PREAMP_HEADROOM`, so the result is
///     entirely non-positive and needs no preamp of its own;
///   - the first sample is clamped to at most 0, to stop a boost below the
///     lowest frequency EqualizerAPO will interpolate from.
pub fn eqapoGraphic(
    allocator: std.mem.Allocator,
    f: []const f64,
    equalization: []const f64,
    opts: struct { normalize: bool = true, preamp: f64 = 0.0 },
) ![]u8 {
    const axis = try graphicAxis(allocator);
    defer allocator.free(axis);

    const y = try allocator.alloc(f64, axis.len);
    defer allocator.free(y);
    try curve.interpolate(allocator, f, equalization, axis, y);

    if (opts.normalize) {
        var peak = -math.inf(f64);
        for (y) |v| peak = @max(peak, v);
        for (y) |*v| v.* -= peak + preamp_headroom;
    }
    // `if preamp:` upstream, so an exact zero is not added at all. The
    // difference is invisible in the output but keeps the branch honest.
    if (opts.preamp != 0.0) {
        for (y) |*v| v.* += opts.preamp;
    }
    if (y.len > 0 and y[0] > 0.0) y[0] = 0.0;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "GraphicEQ: ");
    for (axis, y, 0..) |fv, v, i| {
        if (i != 0) try out.appendSlice(allocator, "; ");
        try out.print(allocator, "{d:.0} {d:.1}", .{ fv, roundHalfEven(v, 1) });
    }
    return out.toOwnedSlice(allocator);
}

/// `20 * f_step ** arange(n)` cast to int, sorted and deduplicated. The cast
/// is a truncation, and it collides at the bottom of the range where the
/// steps are smaller than 1 Hz — which is exactly why the deduplication is
/// there and why the axis is shorter than `n`.
fn graphicAxis(allocator: std.mem.Allocator) ![]f64 {
    const n: usize = @intFromFloat(@ceil(@log(20000.0 / 20.0) / @log(graphic_eq_step)));
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(allocator);
    var last: ?i64 = null;
    for (0..n) |i| {
        const v = 20.0 * math.pow(f64, graphic_eq_step, @floatFromInt(i));
        const truncated: i64 = @intFromFloat(@trunc(v));
        if (last) |prev| {
            if (truncated == prev) continue;
        }
        last = truncated;
        try out.append(allocator, @floatFromInt(truncated));
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "the parametric output is upstream's line for line" {
    const allocator = testing.allocator;
    const filters = [_]peq.Filter{
        .{
            .kind = .low_shelf,
            .fc = 105.0,
            .q = 0.7,
            .gain = -1.25,
            .limits = peq.shelf_limits,
        },
        .{ .kind = .peaking, .fc = 3216.7, .q = 4.187, .gain = -6.66, .limits = peq.peaking_limits },
        .{
            .kind = .high_shelf,
            .fc = 10000.0,
            .q = 0.7,
            .gain = 2.0,
            .limits = peq.shelf_limits,
        },
    };
    const s = try eqapoParametric(allocator, &filters, 6.34);
    defer allocator.free(s);

    try testing.expectEqualStrings(
        \\Preamp: -6.3 dB
        \\Filter 1: ON LSC Fc 105 Hz Gain -1.2 dB Q 0.70
        \\Filter 2: ON PK Fc 3217 Hz Gain -6.7 dB Q 4.19
        \\Filter 3: ON HSC Fc 10000 Hz Gain 2.0 dB Q 0.70
        \\
    , s);
}

test "an exact tie rounds to even, the way Python's format does" {
    // Verified against CPython: '{:.1f}'.format(-1.25) == '-1.2', not '-1.3'.
    try testing.expectEqual(@as(f64, -1.2), roundHalfEven(-1.25, 1));
    try testing.expectEqual(@as(f64, 0.2), roundHalfEven(0.25, 1));
    try testing.expectEqual(@as(f64, 0.8), roundHalfEven(0.75, 1));
    try testing.expectEqual(@as(f64, 2.0), roundHalfEven(2.5, 0));
    try testing.expectEqual(@as(f64, 4.0), roundHalfEven(3.5, 0));
    // Away from a tie it is ordinary rounding.
    try testing.expectEqual(@as(f64, -1.3), roundHalfEven(-1.26, 1));
    try testing.expectEqual(@as(f64, 0.3), roundHalfEven(0.251, 1));
}

test "a cascade that only cuts gets a positive preamp, as upstream writes it" {
    const allocator = testing.allocator;
    const filters = [_]peq.Filter{
        .{ .kind = .peaking, .fc = 1000.0, .q = 1.0, .gain = -3.0, .limits = peq.peaking_limits },
    };
    const s = try eqapoParametric(allocator, &filters, -0.5);
    defer allocator.free(s);
    try testing.expect(std.mem.startsWith(u8, s, "Preamp: 0.5 dB\n"));
}

test "the graphic axis is upstream's 127 integer points" {
    const allocator = testing.allocator;
    const axis = try graphicAxis(allocator);
    defer allocator.free(axis);

    // The comment on `DEFAULT_GRAPHIC_EQ_STEP` promises both of these.
    try testing.expectEqual(@as(usize, 127), axis.len);
    try testing.expectEqual(@as(f64, 20.0), axis[0]);
    try testing.expectEqual(@as(f64, 19871.0), axis[axis.len - 1]);

    // Strictly ascending after the deduplication.
    for (1..axis.len) |i| try testing.expect(axis[i] > axis[i - 1]);
    // Integers, because upstream casts before it sorts.
    for (axis) |v| try testing.expectEqual(@trunc(v), v);
}

test "normalizing leaves the graphic curve at or below zero" {
    const allocator = testing.allocator;
    const f = try curve.standardGrid(allocator);
    defer allocator.free(f);
    const eq = try allocator.alloc(f64, f.len);
    defer allocator.free(eq);
    for (f, eq) |fv, *v| v.* = 4.0 * @sin(math.log10(fv) * 3.0);

    const s = try eqapoGraphic(allocator, f, eq, .{});
    defer allocator.free(s);
    try testing.expect(std.mem.startsWith(u8, s, "GraphicEQ: 20 "));

    // Every value parses, and none of them is positive.
    var it = std.mem.splitSequence(u8, s["GraphicEQ: ".len..], "; ");
    var n: usize = 0;
    var peak = -math.inf(f64);
    while (it.next()) |pair| : (n += 1) {
        var parts = std.mem.splitScalar(u8, pair, ' ');
        _ = parts.next().?;
        const v = try std.fmt.parseFloat(f64, parts.next().?);
        peak = @max(peak, v);
    }
    try testing.expectEqual(@as(usize, 127), n);
    try testing.expect(peak <= 0.0);
    // The headroom means the loudest sample sits below zero, not at it.
    try testing.expect(peak <= -preamp_headroom + 0.05);
}

test "the first sample is clamped rather than allowed to boost" {
    const allocator = testing.allocator;
    const f = try curve.standardGrid(allocator);
    defer allocator.free(f);
    const eq = try allocator.alloc(f64, f.len);
    defer allocator.free(eq);
    // Rising with frequency, so 20 Hz is the quietest point and normalizing
    // by the peak would leave it far below zero — then a big preamp pushes
    // it back above, which is the case the clamp exists for.
    for (f, eq) |fv, *v| v.* = math.log10(fv);

    const s = try eqapoGraphic(allocator, f, eq, .{ .preamp = 20.0 });
    defer allocator.free(s);
    var parts = std.mem.splitScalar(u8, s["GraphicEQ: ".len..], ';');
    const first = parts.next().?;
    try testing.expectEqualStrings("20 0.0", first);
}
