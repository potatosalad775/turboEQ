//! Fit-only timing against upstream AutoEq, on the parity fixtures.
//!
//!     zig build bench-fit -Doptimize=ReleaseFast -- [--reps N] [--csv] [--fixtures DIR]
//!
//! Every fixture case records, per `PEQ_CONFIGS` entry, the optimizer's own
//! 1.02 grid and target at full precision and the loss upstream's
//! `PEQ.optimize` reached on them. This times turboEQ's fit from those same
//! numbers twice: stopping as soon as it reaches upstream's loss, which
//! compares the two at equal quality, and running to convergence, which is
//! turboEQ's default.
//!
//! The timed span is what `PEQ.from_dict` followed by `PEQ.optimize` covers
//! upstream: build the filters, run the `init()` heuristics, fit. The
//! perceptual stage is not in it — it is the same code on both sides.
//!
//! `tools/parity/time_upstream.py` times upstream on the same inputs and
//! joins the two with `--turboeq` on this program's `--csv` output.

const std = @import("std");
const turboeq = @import("turboeq");
const peq = turboeq.peq;
const configs = turboeq.configs;

/// The configs the comparison reports. The others in the fixtures are
/// covered by parity; these are the three shapes worth a timing.
const timed = [_][]const u8{ "4_PEAKING_WITH_SHELVES", "8_PEAKING_WITH_SHELVES", "10_PEAKING" };

const Timing = struct {
    median_ms: f64,
    loss: f64,
    evaluations: usize,
};

fn median(xs: []f64) f64 {
    std.sort.insertion(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len / 2];
}

fn asF64(v: std.json.Value) f64 {
    return switch (v) {
        .float => |x| x,
        .integer => |x| @floatFromInt(x),
        else => unreachable,
    };
}

fn floatArray(allocator: std.mem.Allocator, v: std.json.Value) ![]f64 {
    const items = v.array.items;
    const out = try allocator.alloc(f64, items.len);
    for (items, out) |item, *o| o.* = asF64(item);
    return out;
}

fn readJson(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 20));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

/// One fit, from scratch: the filters are written through as the optimizer
/// runs, so every repetition starts from a fresh copy of the bank.
fn fitOnce(
    allocator: std.mem.Allocator,
    bank: configs.Bank,
    f: []const f64,
    target: []const f64,
    fs: f64,
    target_loss: ?f64,
) !peq.Report {
    const filters = try bank.build(allocator);
    defer allocator.free(filters);

    var eq = try peq.Peq.init(allocator, f, fs, filters, target, bank.optimizer orelse .{});
    defer eq.deinit();
    eq.stop.target_loss = target_loss;

    const params = try allocator.alloc(f64, eq.paramCount());
    defer allocator.free(params);
    const bnds = try allocator.alloc(peq.Bound, params.len);
    defer allocator.free(bnds);
    try eq.initialParams(params);
    eq.bounds(bnds);
    return eq.optimize(params, bnds);
}

fn time(
    allocator: std.mem.Allocator,
    io: std.Io,
    bank: configs.Bank,
    f: []const f64,
    target: []const f64,
    fs: f64,
    target_loss: ?f64,
    reps: usize,
) !Timing {
    const times = try allocator.alloc(f64, reps);
    defer allocator.free(times);
    var report: peq.Report = undefined;
    for (times) |*t| {
        const started = std.Io.Clock.awake.now(io);
        report = try fitOnce(allocator, bank, f, target, fs, target_loss);
        const ns = started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        t.* = @as(f64, @floatFromInt(ns)) / 1.0e6;
    }
    return .{ .median_ms = median(times), .loss = report.loss, .evaluations = report.evaluations };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var reps: usize = 9;
    var csv = false;
    var fixtures: []const u8 = "tools/parity/fixtures";
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--reps")) {
            reps = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--csv")) {
            csv = true;
        } else if (std.mem.eql(u8, arg, "--fixtures")) {
            fixtures = args.next() orelse return error.MissingValue;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }
    if (reps == 0) return error.InvalidArgument;

    const manifest_path = try std.fs.path.join(allocator, &.{ fixtures, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest = try readJson(io, allocator, manifest_path);
    defer manifest.deinit();
    const fs = asF64(manifest.value.object.get("meta").?.object.get("fs").?);

    if (csv) {
        std.debug.print("case,config,upstream_loss,equal_ms,equal_loss,equal_evals,converged_ms,converged_loss,converged_evals\n", .{});
    } else {
        std.debug.print("fit only, fixture inputs, median of {d}\n\n", .{reps});
        std.debug.print("| Case | Config | Upstream loss | To upstream's loss | To convergence | Converged loss |\n", .{});
        std.debug.print("|---|---|---|---|---|---|\n", .{});
    }

    for (manifest.value.object.get("cases").?.array.items) |entry| {
        const id = entry.object.get("id").?.string;
        const case_path = try std.fs.path.join(allocator, &.{ fixtures, entry.object.get("file").?.string });
        defer allocator.free(case_path);
        const case = try readJson(io, allocator, case_path);
        defer case.deinit();
        const cases = case.value.object.get("peq").?.object;

        for (timed) |name| {
            const fixture = (cases.get(name) orelse continue).object;
            const bank = configs.byName(name) orelse return error.UnknownConfig;
            const f = try floatArray(allocator, fixture.get("frequency").?);
            defer allocator.free(f);
            const target = try floatArray(allocator, fixture.get("target").?);
            defer allocator.free(target);
            const upstream_loss = asF64(fixture.get("optimized").?.object.get("loss").?);

            // A fit that never gets down to upstream's loss runs on to
            // convergence instead, and its row says so through `equal.loss`.
            const equal = try time(allocator, io, bank, f, target, fs, upstream_loss, reps);
            const converged = try time(allocator, io, bank, f, target, fs, null, reps);

            if (csv) {
                std.debug.print("{s},{s},{d:.9},{d:.4},{d:.9},{d},{d:.4},{d:.9},{d}\n", .{
                    id,                    name,
                    upstream_loss,         equal.median_ms,
                    equal.loss,            equal.evaluations,
                    converged.median_ms,   converged.loss,
                    converged.evaluations,
                });
            } else {
                const reached = equal.loss <= upstream_loss;
                std.debug.print("| {s} | {s} | {d:.4} | {d:.2} ms{s} | {d:.2} ms | {d:.4} |\n", .{
                    id,
                    name,
                    upstream_loss,
                    equal.median_ms,
                    if (reached) "" else " (not reached)",
                    converged.median_ms,
                    converged.loss,
                });
            }
        }
    }
}
