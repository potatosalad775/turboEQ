//! End-to-end timing for the whole pipeline.
//!
//!     zig build bench -Doptimize=ReleaseFast -- [--reps N] [--csv]
//!
//! The curve is `curves.bumpy` from tools/parity on a 1/48-octave grid: ten
//! alternating features, 479 points, 20 Hz to 20 kHz, against a flat target.
//!
//! `peaking` counts peaking bands only, as `pipeline.Config` does; with
//! shelves on, two more filters are fitted on top of it.
//!
//! This times the whole thing: interpolate, centre, compensate, the
//! perceptual stage and the fit. The comparison against upstream in
//! BENCHMARKS.md times only the fit, so it is not the same measurement.

const std = @import("std");
const turboeq = @import("turboeq");
const pipeline = turboeq.pipeline;

/// `curves.bumpy`: a sum of log-frequency gaussians, `(fc, gain, width)`.
const Peak = struct { fc: f64, gain: f64, width: f64 };
const bumpy = [_]Peak{
    .{ .fc = 60, .gain = -6, .width = 0.12 },
    .{ .fc = 150, .gain = 4, .width = 0.10 },
    .{ .fc = 400, .gain = -3, .width = 0.09 },
    .{ .fc = 900, .gain = 3, .width = 0.08 },
    .{ .fc = 1800, .gain = -4, .width = 0.07 },
    .{ .fc = 3200, .gain = 6, .width = 0.06 },
    .{ .fc = 5000, .gain = -5, .width = 0.06 },
    .{ .fc = 7000, .gain = 4, .width = 0.05 },
    .{ .fc = 9500, .gain = -6, .width = 0.05 },
    .{ .fc = 13000, .gain = 3, .width = 0.07 },
};

fn gaussians(f: f64, peaks: []const Peak) f64 {
    const l = std.math.log10(f);
    var v: f64 = 0;
    for (peaks) |p| {
        const u = (l - std.math.log10(p.fc)) / p.width;
        v += p.gain * @exp(-u * u);
    }
    return v;
}

/// 1/48 octave from 20 Hz, which lands on 479 points below 20 kHz.
fn octave48Grid(allocator: std.mem.Allocator) ![]f64 {
    const step = std.math.pow(f64, 2.0, 1.0 / 48.0);
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(allocator);
    var f: f64 = 20.0;
    while (f <= 20000.0) : (f *= step) try out.append(allocator, f);
    return out.toOwnedSlice(allocator);
}

const Row = struct {
    peaking: usize,
    shelves: bool,
    best_ms: f64,
    median_ms: f64,
    rmse: f64,
    loss: f64,
    evaluations: usize,
};

fn median(xs: []f64) f64 {
    std.sort.insertion(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len / 2];
}

fn runCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    src_f: []const f64,
    src_db: []const f64,
    tgt_f: []const f64,
    tgt_db: []const f64,
    peaking: usize,
    shelves: bool,
    reps: usize,
) !Row {
    const cfg = pipeline.Config{ .peaking = peaking, .shelves = shelves };

    const times = try allocator.alloc(f64, reps);
    defer allocator.free(times);

    var last_rmse: f64 = 0;
    var last_loss: f64 = 0;
    var last_evals: usize = 0;

    for (times) |*t| {
        const started = std.Io.Clock.awake.now(io);
        var result = try pipeline.run(allocator, src_f, src_db, tgt_f, tgt_db, cfg);
        const ns = started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        last_rmse = result.rmse;
        last_loss = result.loss;
        last_evals = result.evaluations;
        result.deinit();
        t.* = @as(f64, @floatFromInt(ns)) / 1.0e6;
    }

    var best: f64 = times[0];
    for (times) |t| best = @min(best, t);
    return .{
        .peaking = peaking,
        .shelves = shelves,
        .best_ms = best,
        .median_ms = median(times),
        .rmse = last_rmse,
        .loss = last_loss,
        .evaluations = last_evals,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var reps: usize = 9;
    var csv = false;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--reps")) {
            reps = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--csv")) {
            csv = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }
    if (reps == 0) return error.InvalidArgument;

    const f = try octave48Grid(allocator);
    defer allocator.free(f);
    const db = try allocator.alloc(f64, f.len);
    defer allocator.free(db);
    for (f, db) |fv, *v| v.* = gaussians(fv, &bumpy);

    const tgt_f = [_]f64{ 20.0, 20000.0 };
    const tgt_db = [_]f64{ 0.0, 0.0 };

    const counts = [_]usize{ 4, 6, 8, 10, 12 };

    if (csv) {
        std.debug.print("peaking,shelves,best_ms,median_ms,rmse,loss,evaluations\n", .{});
    } else {
        std.debug.print(
            "curve: bumpy, {d} points at 1/48 octave, target flat, reps {d}\n\n",
            .{ f.len, reps },
        );
        std.debug.print(
            "| Peaking | Shelves | Filters | best | median | RMSE | evals |\n",
            .{},
        );
        std.debug.print(
            "|---|---|---|---|---|---|---|\n",
            .{},
        );
    }

    for (counts) |peaking| {
        const layouts = [_]bool{ true, false };
        for (layouts) |shelves| {
            const row = try runCase(allocator, io, f, db, &tgt_f, &tgt_db, peaking, shelves, reps);
            if (csv) {
                std.debug.print("{d},{d},{d:.3},{d:.3},{d:.6},{d:.6},{d}\n", .{
                    row.peaking,
                    @intFromBool(row.shelves),
                    row.best_ms,
                    row.median_ms,
                    row.rmse,
                    row.loss,
                    row.evaluations,
                });
            } else {
                std.debug.print("| {d} | {s} | {d} | {d:.2} ms | {d:.2} ms | {d:.4} | {d} |\n", .{
                    row.peaking,
                    if (row.shelves) "yes" else "no",
                    row.peaking + @as(usize, if (row.shelves) 2 else 0),
                    row.best_ms,
                    row.median_ms,
                    row.rmse,
                    row.evaluations,
                });
            }
        }
    }
}
