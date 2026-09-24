//! Emit the candidate JSON that `tools/parity/compare.py` diffs against the
//! recorded upstream fixtures.
//!
//!     zig build dump -- [--fixtures DIR] [--out candidate.json]
//!
//! Curve inputs are read back out of the fixture files rather than generated
//! here. One of the cases is seeded numpy noise, which there is no point
//! reproducing in Zig, and reading the inputs keeps both sides fed from
//! exactly the same numbers.
//!
//! Stages the port has not reached yet are simply left out of the output.
//! compare.py reports an absent stage as SKIP, so this stays green while the
//! port is partial.

const std = @import("std");
const turboeq = @import("turboeq");
const util = turboeq.util;
const biquad = turboeq.biquad;
const curve = turboeq.curve;
const equalize = turboeq.equalize;
const peq = turboeq.peq;
const configs = turboeq.configs;

/// Same order as BIQUAD_PROBES in dump_fixtures.py. The comparator matches
/// probes positionally, so this list must not be reordered on its own.
const Probe = struct { kind: biquad.Kind, fc: f64, q: f64, gain: f64 };
const probes = [_]Probe{
    .{ .kind = .peaking, .fc = 100.0, .q = 0.5, .gain = 6.0 },
    .{ .kind = .peaking, .fc = 1000.0, .q = 1.41, .gain = -6.0 },
    .{ .kind = .peaking, .fc = 3000.0, .q = 6.0, .gain = 12.0 },
    .{ .kind = .peaking, .fc = 9000.0, .q = 0.18248, .gain = -3.0 },
    .{ .kind = .peaking, .fc = 20.0, .q = 2.0, .gain = 20.0 },
    .{ .kind = .peaking, .fc = 10000.0, .q = 4.0, .gain = -20.0 },
    .{ .kind = .low_shelf, .fc = 105.0, .q = 0.7, .gain = 6.0 },
    .{ .kind = .low_shelf, .fc = 40.0, .q = 0.4, .gain = -9.0 },
    .{ .kind = .low_shelf, .fc = 300.0, .q = 0.7, .gain = 12.0 },
    .{ .kind = .high_shelf, .fc = 10000.0, .q = 0.7, .gain = 6.0 },
    .{ .kind = .high_shelf, .fc = 5000.0, .q = 0.4, .gain = -9.0 },
    .{ .kind = .high_shelf, .fc = 12000.0, .q = 0.7, .gain = 3.0 },
};

/// Octave widths dump_helpers() records, keyed by Python's repr of the float.
/// Spelled out rather than formatted, because the keys have to match exactly.
const WindowProbe = struct { key: []const u8, octaves: f64 };
const window_probes = [_]WindowProbe{
    .{ .key = "0.08333333333333333", .octaves = 1.0 / 12.0 },
    .{ .key = "0.2", .octaves = 1.0 / 5.0 },
    .{ .key = "0.3333333333333333", .octaves = 1.0 / 3.0 },
    .{ .key = "2.0", .octaves = 2.0 },
};

// ---------------------------------------------------------------------------
// A very small JSON writer. Enough for the flat shape the harness expects.
// ---------------------------------------------------------------------------
const Json = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Json {
        return .{ .buf = .empty, .allocator = allocator };
    }

    fn deinit(self: *Json) void {
        self.buf.deinit(self.allocator);
    }

    fn raw(self: *Json, s: []const u8) !void {
        try self.buf.appendSlice(self.allocator, s);
    }

    fn key(self: *Json, name: []const u8) !void {
        try self.raw("\"");
        try self.raw(name);
        try self.raw("\":");
    }

    /// Shortest decimal form that round-trips. The buffer is oversized
    /// because `{d}` writes out the full decimal expansion, and the sigmoid
    /// helpers reach the 1e-300 range at the bottom of the frequency axis.
    fn number(self: *Json, v: f64) !void {
        if (!std.math.isFinite(v)) return self.raw("null");
        var tmp: [1100]u8 = undefined;
        try self.raw(try std.fmt.bufPrint(&tmp, "{d}", .{v}));
    }

    fn integer(self: *Json, v: anytype) !void {
        var tmp: [32]u8 = undefined;
        try self.raw(try std.fmt.bufPrint(&tmp, "{d}", .{v}));
    }

    fn numbers(self: *Json, vs: []const f64) !void {
        try self.raw("[");
        for (vs, 0..) |v, i| {
            if (i != 0) try self.raw(",");
            try self.number(v);
        }
        try self.raw("]");
    }

    fn indices(self: *Json, vs: []const usize) !void {
        try self.raw("[");
        for (vs, 0..) |v, i| {
            if (i != 0) try self.raw(",");
            try self.integer(v);
        }
        try self.raw("]");
    }

    fn bools(self: *Json, vs: []const bool) !void {
        try self.raw("[");
        for (vs, 0..) |v, i| {
            if (i != 0) try self.raw(",");
            try self.raw(if (v) "true" else "false");
        }
        try self.raw("]");
    }

    fn string(self: *Json, s: []const u8) !void {
        try self.raw("\"");
        try self.raw(s);
        try self.raw("\"");
    }
};

// ---------------------------------------------------------------------------
// Fixture reading
// ---------------------------------------------------------------------------
fn readJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(std.json.Value) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 20));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn asF64(v: std.json.Value) f64 {
    return switch (v) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        else => std.math.nan(f64),
    };
}

fn floatArray(allocator: std.mem.Allocator, v: std.json.Value) ![]f64 {
    const items = v.array.items;
    const out = try allocator.alloc(f64, items.len);
    for (items, out) |item, *o| o.* = asF64(item);
    return out;
}

// ---------------------------------------------------------------------------
// Stages
// ---------------------------------------------------------------------------
fn dumpShared(allocator: std.mem.Allocator, json: *Json, f: []const f64, fs: f64) !void {
    const fr = try allocator.alloc(f64, f.len);
    defer allocator.free(fr);

    try json.key("shared");
    try json.raw("{");
    try json.key("biquad");
    try json.raw("[");
    for (probes, 0..) |p, i| {
        if (i != 0) try json.raw(",");
        const filt = biquad.Filter{ .kind = p.kind, .fc = p.fc, .q = p.q, .gain = p.gain };
        const c = filt.coefficients(fs);
        biquad.magnitude(c, f, fs, fr);

        try json.raw("{");
        try json.key("coefficients");
        try json.raw("{");
        inline for (.{ "a0", "a1", "a2", "b0", "b1", "b2" }, 0..) |name, k| {
            if (k != 0) try json.raw(",");
            try json.key(name);
            try json.number(@field(c, name));
        }
        try json.raw("},");
        try json.key("fr");
        try json.numbers(fr);
        try json.raw(",");
        try json.key("sharpness_penalty");
        try json.number(biquad.sharpnessPenalty(p.kind, p.q, p.gain, fr));
        try json.raw(",");
        try json.key("band_penalty");
        try json.number(biquad.bandPenalty(p.kind, p.fc, p.gain, f, fs, fr));
        try json.raw("}");
    }
    try json.raw("],");

    try json.key("helpers");
    try json.raw("{");
    try json.key("smoothing_window_size");
    try json.raw("{");
    for (window_probes, 0..) |w, i| {
        if (i != 0) try json.raw(",");
        try json.key(w.key);
        try json.integer(util.smoothingWindowSize(f, w.octaves));
    }
    try json.raw("},");

    const sig = try allocator.alloc(f64, f.len);
    defer allocator.free(sig);
    util.logFSigmoid(f, 6000.0, 8000.0, 0.0, 1.0, sig);
    try json.key("log_f_sigmoid_6k_8k");
    try json.numbers(sig);
    try json.raw(",");
    util.logFSigmoid(f, 6000.0, 8000.0, 1.0, 0.5, sig);
    try json.key("log_f_sigmoid_treble_gain_k_0p5");
    try json.numbers(sig);
    try json.raw(",");

    const grid = try curve.standardGrid(allocator);
    defer allocator.free(grid);
    try json.key("generate_frequencies_1p01");
    try json.numbers(grid);
    try json.raw("}}");
}

fn dumpCase(allocator: std.mem.Allocator, json: *Json, case: std.json.Value, fs: f64) !void {
    const input = case.object.get("input").?.object;
    const src_f = try floatArray(allocator, input.get("frequency").?);
    defer allocator.free(src_f);
    const src_raw = try floatArray(allocator, input.get("raw").?);
    defer allocator.free(src_raw);
    const tgt_raw = try floatArray(allocator, input.get("target_raw").?);
    defer allocator.free(tgt_raw);
    // The real measurement cases put the target on its own axis; the synthetic
    // ones share the source's, and their fixtures predate the key.
    const tgt_f = if (input.get("target_frequency")) |v|
        try floatArray(allocator, v)
    else
        try allocator.dupe(f64, src_f);
    defer allocator.free(tgt_f);

    const f = try curve.standardGrid(allocator);
    defer allocator.free(f);

    const raw = try allocator.alloc(f64, f.len);
    defer allocator.free(raw);
    try curve.interpolate(allocator, src_f, src_raw, f, raw);

    try json.raw("{");
    try json.key("stages");
    try json.raw("{");

    try json.key("interpolate");
    try json.raw("{");
    try json.key("frequency");
    try json.numbers(f);
    try json.raw(",");
    try json.key("raw");
    try json.numbers(raw);
    try json.raw("},");

    const shift = try curve.center(allocator, f, raw, 1000.0);
    try json.key("center");
    try json.raw("{");
    try json.key("shift_db");
    try json.number(shift);
    try json.raw(",");
    try json.key("raw");
    try json.numbers(raw);
    try json.raw("},");

    const target_prepared = try allocator.alloc(f64, f.len);
    defer allocator.free(target_prepared);
    try curve.prepareTarget(allocator, tgt_f, tgt_raw, f, target_prepared);

    const target = try allocator.alloc(f64, f.len);
    defer allocator.free(target);
    const err_curve = try allocator.alloc(f64, f.len);
    defer allocator.free(err_curve);
    curve.compensate(
        f,
        raw,
        target_prepared,
        .{ .fs = fs, .min_mean_error = true },
        target,
        err_curve,
    );

    try json.key("compensate");
    try json.raw("{");
    try json.key("target");
    try json.numbers(target);
    try json.raw(",");
    try json.key("error");
    try json.numbers(err_curve);
    try json.raw("},");

    const smoothed = try allocator.alloc(f64, f.len);
    defer allocator.free(smoothed);
    const error_smoothed = try allocator.alloc(f64, f.len);
    defer allocator.free(error_smoothed);
    try curve.smoothen(allocator, f, raw, .{}, smoothed);
    try curve.smoothen(allocator, f, err_curve, .{}, error_smoothed);

    try json.key("smoothen");
    try json.raw("{");
    try json.key("smoothed");
    try json.numbers(smoothed);
    try json.raw(",");
    try json.key("error_smoothed");
    try json.numbers(error_smoothed);
    try json.raw("},");

    var eq = try equalize.equalize(allocator, f, err_curve, .{});
    defer eq.deinit();

    try json.key("equalize");
    try json.raw("{");
    try json.key("peak_inds");
    try json.indices(eq.peak_inds);
    try json.raw(",");
    try json.key("dip_inds");
    try json.indices(eq.dip_inds);
    try json.raw(",");
    try json.key("rtl_start");
    try json.integer(eq.rtl_start);
    try json.raw(",");
    try json.key("limit_free_mask");
    try json.bools(eq.limit_free_mask);
    try json.raw(",");
    try json.key("clipped_ltr");
    try json.bools(eq.clipped_ltr);
    try json.raw(",");
    try json.key("clipped_rtl");
    try json.bools(eq.clipped_rtl);
    try json.raw(",");
    try json.key("limited_ltr");
    try json.numbers(eq.limited_ltr);
    try json.raw(",");
    try json.key("limited_rtl");
    try json.numbers(eq.limited_rtl);
    try json.raw(",");
    try json.key("equalization");
    try json.numbers(eq.equalization);
    try json.raw("}");

    try json.raw("},");
    try dumpPeq(allocator, json, case, fs);
    try json.raw(",");
    try dumpPeqCascade(allocator, json, case, fs);
    try json.raw("}");
}

/// `_optimize_peq_filters` over a list of configs. The banks run in the order
/// the fixture names them and each fits the residual the last one left, which
/// is `pipeline.run`'s loop with the curve preparation already done.
fn dumpPeqCascade(allocator: std.mem.Allocator, json: *Json, case: std.json.Value, fs: f64) !void {
    try json.key("peq_cascade");
    try json.raw("{");

    const cases = (case.object.get("peq_cascade") orelse {
        try json.raw("}");
        return;
    }).object;

    var it = cases.iterator();
    var n: usize = 0;
    while (it.next()) |entry| : (n += 1) {
        const f = try floatArray(allocator, entry.value_ptr.object.get("frequency").?);
        defer allocator.free(f);
        const target = try floatArray(allocator, entry.value_ptr.object.get("target").?);
        defer allocator.free(target);

        const names = entry.value_ptr.object.get("configs").?.array;
        const residual = try allocator.dupe(f64, target);
        defer allocator.free(residual);
        const combined = try allocator.alloc(f64, f.len);
        defer allocator.free(combined);
        @memset(combined, 0);

        if (n != 0) try json.raw(",");
        try json.key(entry.key_ptr.*);
        try json.raw("{");
        try json.key("banks");
        try json.raw("[");

        for (names.items, 0..) |name_value, bank_ix| {
            const name = name_value.string;
            const bank = configs.byName(name) orelse return error.UnknownConfig;
            const filters = try bank.build(allocator);
            defer allocator.free(filters);

            var eq = try peq.Peq.init(allocator, f, fs, filters, residual, bank.optimizer orelse .{});
            defer eq.deinit();

            const params = try allocator.alloc(f64, eq.paramCount());
            defer allocator.free(params);
            const bounds = try allocator.alloc(peq.Bound, params.len);
            defer allocator.free(bounds);
            try eq.initialParams(params);
            eq.bounds(bounds);
            const bank_report = try eq.optimize(params, bounds);

            for (combined, eq.fr) |*c, v| c.* += v;
            for (residual, eq.fr) |*r, v| r.* -= v;

            if (bank_ix != 0) try json.raw(",");
            try json.raw("{");
            try json.key("name");
            try json.string(name);
            try json.raw(",");
            try json.key("loss");
            if (params.len == 0) try json.raw("null") else try json.number(bank_report.loss);
            try json.raw(",");
            try json.key("filters");
            try json.raw("[");
            for (eq.filters, 0..) |filt, i| {
                if (i != 0) try json.raw(",");
                try json.raw("{");
                try json.key("type");
                try json.string(typeName(filt.kind));
                try json.raw(",");
                try json.key("fc");
                try json.number(filt.fc);
                try json.raw(",");
                try json.key("q");
                try json.number(filt.q);
                try json.raw(",");
                try json.key("gain");
                try json.number(filt.gain);
                try json.raw("}");
            }
            try json.raw("]}");
        }
        try json.raw("],");

        var sq: f64 = 0;
        var max_gain = -std.math.inf(f64);
        for (residual, combined) |r, c| {
            sq += r * r;
            max_gain = @max(max_gain, c);
        }
        try json.key("fr");
        try json.numbers(combined);
        try json.raw(",");
        try json.key("rmse");
        try json.number(@sqrt(sq / @as(f64, @floatFromInt(residual.len))));
        try json.raw(",");
        try json.key("max_gain");
        try json.number(max_gain);
        try json.raw("}");
    }
    try json.raw("}");
}

/// The optimizer's own frequency axis and target are read back out
/// of the fixture rather than rebuilt here: `dump_fixtures.py` records them
/// with `inarr`, at full precision, precisely so both sides start from the
/// same numbers.
fn dumpPeq(allocator: std.mem.Allocator, json: *Json, case: std.json.Value, fs: f64) !void {
    try json.key("peq");
    try json.raw("{");

    const cases = case.object.get("peq").?.object;
    var it = cases.iterator();
    var n: usize = 0;
    while (it.next()) |entry| : (n += 1) {
        const name = entry.key_ptr.*;
        const f = try floatArray(allocator, entry.value_ptr.object.get("frequency").?);
        defer allocator.free(f);
        const target = try floatArray(allocator, entry.value_ptr.object.get("target").?);
        defer allocator.free(target);

        // Resolved from turboEQ's own `PEQ_CONFIGS` table rather than read
        // back out of the fixture: the resolution is itself under test, and
        // `compare.py` diffs the bank below against the one upstream built.
        const bank = configs.byName(name) orelse return error.UnknownConfig;
        const filters = try bank.build(allocator);
        defer allocator.free(filters);

        var eq = try peq.Peq.init(allocator, f, fs, filters, target, bank.optimizer orelse .{});
        defer eq.deinit();

        const params = try allocator.alloc(f64, eq.paramCount());
        defer allocator.free(params);
        try eq.initialParams(params);
        const init_loss = eq.lossFromResponse();

        const init_params = try allocator.dupe(f64, params);
        defer allocator.free(init_params);

        const bounds = try allocator.alloc(peq.Bound, params.len);
        defer allocator.free(bounds);
        eq.bounds(bounds);
        const report = try eq.optimize(params, bounds);

        if (n != 0) try json.raw(",");
        try json.key(name);
        try json.raw("{");
        try json.key("config");
        try json.raw("{");
        try json.key("filters");
        try json.raw("[");
        for (bank.filters, 0..) |filt, i| {
            if (i != 0) try json.raw(",");
            try json.raw("{");
            try json.key("type");
            try json.string(typeName(filt.kind));
            inline for (.{
                .{ "optimize_fc", filt.optimize_fc },
                .{ "optimize_q", filt.optimize_q },
                .{ "optimize_gain", filt.optimize_gain },
            }) |pair| {
                try json.raw(",");
                try json.key(pair[0]);
                try json.raw(if (pair[1]) "true" else "false");
            }
            // A pinned value is the only one upstream records; an optimized
            // one holds a placeholder on both sides and means nothing.
            inline for (.{
                .{ "fc", filt.optimize_fc, filt.fc },
                .{ "q", filt.optimize_q, filt.q },
                .{ "gain", filt.optimize_gain, filt.gain },
            }) |pair| {
                try json.raw(",");
                try json.key(pair[0]);
                if (pair[1]) try json.raw("null") else try json.number(pair[2]);
            }
            inline for (.{
                .{ "min_fc", filt.limits.min_fc },
                .{ "max_fc", filt.limits.max_fc },
                .{ "min_q", filt.limits.min_q },
                .{ "max_q", filt.limits.max_q },
                .{ "min_gain", filt.limits.min_gain },
                .{ "max_gain", filt.limits.max_gain },
            }) |pair| {
                try json.raw(",");
                try json.key(pair[0]);
                try json.number(pair[1]);
            }
            try json.raw("}");
        }
        try json.raw("],");
        const opt = bank.optimizer orelse peq.Options{};
        try json.key("min_f");
        try json.number(opt.min_f);
        try json.raw(",");
        try json.key("max_f");
        try json.number(opt.max_f);
        try json.raw(",");
        try json.key("min_std");
        if (bank.min_std) |v| try json.number(v) else try json.raw("null");
        try json.raw("},");
        try json.key("init");
        try json.raw("{");
        try json.key("params");
        try json.numbers(init_params);
        try json.raw(",");
        try json.key("loss");
        try json.number(init_loss);
        try json.raw("},");
        try json.key("optimized");
        try json.raw("{");
        try json.key("filters");
        try json.raw("[");
        for (eq.filters, 0..) |filt, i| {
            if (i != 0) try json.raw(",");
            try json.raw("{");
            try json.key("type");
            try json.string(typeName(filt.kind));
            try json.raw(",");
            try json.key("fc");
            try json.number(filt.fc);
            try json.raw(",");
            try json.key("q");
            try json.number(filt.q);
            try json.raw(",");
            try json.key("gain");
            try json.number(filt.gain);
            try json.raw("}");
        }
        try json.raw("],");
        try json.key("loss");
        try json.number(report.loss);
        try json.raw(",");
        try json.key("rmse");
        try json.number(eq.rmse());
        try json.raw(",");
        try json.key("max_gain");
        try json.number(eq.maxGain());
        try json.raw(",");
        try json.key("iterations");
        try json.integer(report.iterations);
        try json.raw(",");
        try json.key("evaluations");
        try json.integer(report.evaluations);
        try json.raw(",");
        try json.key("status");
        try json.string(@tagName(report.status));
        try json.raw("}}");
    }
    try json.raw("}");
}

/// Upstream names its filter classes, not its enum tags.
fn typeName(kind: peq.Kind) []const u8 {
    return switch (kind) {
        .peaking => "Peaking",
        .low_shelf => "LowShelf",
        .high_shelf => "HighShelf",
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var fixtures: []const u8 = "tools/parity/fixtures";
    var out_path: []const u8 = "candidate.json";

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--fixtures")) {
            fixtures = try allocator.dupe(u8, args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = try allocator.dupe(u8, args.next() orelse return error.MissingValue);
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    const shared_path = try std.fs.path.join(allocator, &.{ fixtures, "shared.json" });
    defer allocator.free(shared_path);
    const shared = try readJson(io, allocator, shared_path);
    defer shared.deinit();

    const meta = shared.value.object.get("meta").?.object;
    const fs = asF64(meta.get("fs").?);
    const commit = meta.get("autoeq_commit").?.string;

    const shared_f = try floatArray(allocator, shared.value.object.get("frequency").?);
    defer allocator.free(shared_f);

    var json = Json.init(allocator);
    defer json.deinit();

    try json.raw("{");
    try json.key("meta");
    try json.raw("{");
    try json.key("autoeq_commit");
    try json.string(commit);
    try json.raw(",");
    try json.key("fs");
    try json.number(fs);
    try json.raw("},");

    try dumpShared(allocator, &json, shared_f, fs);
    try json.raw(",");

    const manifest_path = try std.fs.path.join(allocator, &.{ fixtures, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest = try readJson(io, allocator, manifest_path);
    defer manifest.deinit();

    try json.key("cases");
    try json.raw("{");
    for (manifest.value.object.get("cases").?.array.items, 0..) |entry, n| {
        const id = entry.object.get("id").?.string;
        const file = entry.object.get("file").?.string;
        const case_path = try std.fs.path.join(allocator, &.{ fixtures, file });
        defer allocator.free(case_path);
        const case = try readJson(io, allocator, case_path);
        defer case.deinit();

        if (n != 0) try json.raw(",");
        try json.key(id);
        try dumpCase(allocator, &json, case.value, fs);
    }
    try json.raw("}}\n");

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = json.buf.items });
    std.debug.print("wrote {s} ({d} KB)\n", .{ out_path, json.buf.items.len / 1024 });
}
