//! Fixed-workload stereo downmix benchmark for external measurement tools.
//!
//! Keep this executable deliberately quiet and argument-free so two builds can
//! be compared directly with `poop before after`. The output buffer is exposed
//! to an optimization barrier on every pass; the compiler therefore has to do
//! the same work as the capture pipeline.

const std = @import("std");
const audio = @import("audio");

const frame_count = 480_000;
const reps = 200;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stereo = try allocator.alloc(f32, frame_count * 2);
    defer allocator.free(stereo);

    var prng = std.Random.DefaultPrng.init(0x5eed_cafe);
    const random = prng.random();
    for (stereo) |*sample| sample.* = random.float(f32) * 2.0 - 1.0;

    for (0..reps) |_| {
        const mono = try audio.downmix(allocator, stereo, 2);
        std.mem.doNotOptimizeAway(mono);
        allocator.free(mono);
    }
}
