//! turboEQ: a Zig port of AutoEq's parametric EQ optimizer.
//!
//! Each piece is checked against recorded upstream output by `tools/parity`.

const std = @import("std");

pub const util = @import("util.zig");
pub const biquad = @import("biquad.zig");
pub const savgol = @import("savgol.zig");
pub const curve = @import("curve.zig");
pub const peaks = @import("peaks.zig");
pub const equalize = @import("equalize.zig");
pub const lbfgs = @import("lbfgs.zig");
pub const peq = @import("peq.zig");
pub const configs = @import("configs.zig");
pub const pipeline = @import("pipeline.zig");
pub const format = @import("format.zig");

/// Upstream's `DEFAULT_FS`. turboEQ follows it; a caller on a 48 kHz chain
/// passes its own rate explicitly rather than relying on this.
pub const default_fs: f64 = 44100.0;

test {
    std.testing.refAllDecls(@This());
    _ = util;
    _ = biquad;
    _ = savgol;
    _ = curve;
    _ = peaks;
    _ = equalize;
    _ = lbfgs;
    _ = peq;
    _ = configs;
    _ = pipeline;
    _ = format;
}
