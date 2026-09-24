const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const turboeq = b.addModule("turboeq", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Emits the candidate JSON that tools/parity/compare.py diffs against
    // the recorded upstream fixtures.
    const dump = b.addExecutable(.{
        .name = "dump-candidate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dump_candidate/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turboeq", .module = turboeq }},
        }),
    });
    b.installArtifact(dump);

    const run_dump = b.addRunArtifact(dump);
    run_dump.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_dump.addArgs(args);
    b.step("dump", "Write candidate.json from the fixture inputs").dependOn(&run_dump.step);

    // End-to-end timing of the whole pipeline. Build it with
    // -Doptimize=ReleaseFast or the numbers mean nothing.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turboeq", .module = turboeq }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Time the whole pipeline end to end").dependOn(&run_bench.step);

    // Fit-only timing on the parity fixtures' optimizer inputs, the turboEQ
    // half of the comparison tools/parity/time_upstream.py completes.
    const bench_fit = b.addExecutable(.{
        .name = "bench-fit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench/fit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "turboeq", .module = turboeq }},
        }),
    });
    const run_bench_fit = b.addRunArtifact(bench_fit);
    if (b.args) |args| run_bench_fit.addArgs(args);
    b.step("bench-fit", "Time the fit alone against upstream's recorded loss").dependOn(&run_bench_fit.step);

    // -----------------------------------------------------------------------
    // The wasm artifact.
    //
    // Freestanding, no WASI: the module imports nothing and the host drives
    // it through the flat f64 ABI in src/wasm.zig. `-fno-entry` because there
    // is no `main`, `rdynamic` to keep the `export fn`s in the table.
    //
    // ReleaseSmall, and not tied to -Doptimize. It costs 2% to 3% of run time
    // against ReleaseFast and saves a third of the module, and the two produce
    // bit-identical fits — same parameters, same evaluation counts. A third
    // of a module matters more than 3% of a fit. BENCHMARKS.md has the
    // numbers; build the other with -Dwasm-optimize=ReleaseFast.
    // -----------------------------------------------------------------------
    const wasm_optimize = b.option(
        std.builtin.OptimizeMode,
        "wasm-optimize",
        "Optimization mode for the wasm artifact (default ReleaseSmall)",
    ) orelse .ReleaseSmall;

    // Two builds of the same source. `turboeq-simd.wasm` adds simd128, which
    // the optimizer's kernel is written for with `@Vector`; `turboeq.wasm` is
    // for engines without it, where LLVM splits the vectors back into
    // scalars. Both do the same arithmetic in the same order, so they return
    // bit-identical fits, and smoke.mjs checks that they do. The binding
    // picks one at load time.
    const wasm_step = b.step("wasm", "Build turboeq.wasm and turboeq-simd.wasm for the browser");
    for ([_]struct { name: []const u8, simd: bool }{
        .{ .name = "turboeq", .simd = false },
        .{ .name = "turboeq-simd", .simd = true },
    }) |variant| {
        const wasm = b.addExecutable(.{
            .name = variant.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wasm.zig"),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = .wasm32,
                    .os_tag = .freestanding,
                    .cpu_features_add = if (variant.simd)
                        std.Target.wasm.featureSet(&.{.simd128})
                    else
                        .empty,
                }),
                .optimize = wasm_optimize,
                // DWARF is ten times the size of the code here and no browser
                // reads it. Debug a fit on the host target instead.
                .strip = true,
            }),
        });
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);
    }

    // -----------------------------------------------------------------------
    // Tests. The wasm boundary is tested on the host, where a failure prints
    // something; the freestanding build only ever traps.
    // -----------------------------------------------------------------------
    const unit_tests = b.addTest(.{ .root_module = turboeq });
    const run_tests = b.addRunArtifact(unit_tests);

    const wasm_abi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_wasm_abi_tests = b.addRunArtifact(wasm_abi_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_wasm_abi_tests.step);
}
