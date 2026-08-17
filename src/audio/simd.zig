//! Hand-vectorized primitives for the audio hot paths.
//!
//! Every function here is the same five steps, from
//! https://mitchellh.com/writing/everyone-should-know-simd:
//!
//!   1. Broadcast the loop constants across lanes with `@splat`.
//!   2. Step the loop by a whole vector instead of one element.
//!   3. Do the arithmetic on every lane in one instruction.
//!   4. Reduce the lanes back down to a scalar with `@reduce`.
//!   5. Run the original scalar loop over the tail.
//!
//! Step 5 doubles as the entire implementation on a target with no vector
//! register for the element type, where `lanes` is null and the vector body is
//! never compiled at all.
//!
//! These loops run over whole recordings — 16 kHz × minutes is millions of
//! samples — which is the size where a 4× (NEON) to 16× (AVX-512) lane count
//! pays for the extra lines. LLVM already auto-vectorizes some of this some of
//! the time; writing it out is what keeps it from silently regressing when the
//! optimizer changes its mind.
//!
//! Summing in lanes accumulates in a different order than the scalar loop, so
//! a reduced sum can differ from the scalar one in the last ulp. Both are
//! approximations of the same real number (the lane-wise one is usually the
//! closer of the two, being effectively partial pairwise summation), and every
//! caller compares the result against a tuned threshold, so this is not a
//! behavior change any of them can observe.

const std = @import("std");

/// Lanes to use for `T`, or null when the target has no vector register worth
/// using for it. Callers need the scalar tail either way, so null simply means
/// the tail does all the work.
fn lanes(comptime T: type) ?comptime_int {
    return std.simd.suggestVectorLength(T);
}

/// Σ s² over `samples`. Callers divide by the length and take the square root
/// to get RMS; keeping the division out of here lets `trimSilenceBounds`
/// compare raw energies across equal-sized windows without the sqrt.
pub fn sumOfSquares(samples: []const f32) f32 {
    var total: f32 = 0;
    var i: usize = 0;

    if (comptime lanes(f32)) |n| {
        const V = @Vector(n, f32);
        var acc: V = @splat(0);
        while (i + n <= samples.len) : (i += n) {
            const v: V = samples[i..][0..n].*;
            acc += v * v;
        }
        total = @reduce(.Add, acc);
    }

    for (samples[i..]) |s| total += s * s;
    return total;
}

/// `sumOfSquares` accumulated in f64. The offline tuning paths sum whole files
/// at once and report the RMS to four decimals, which is where an f32
/// accumulator starts losing digits to its own rounding.
pub fn sumOfSquaresWide(samples: []const f32) f64 {
    var total: f64 = 0;
    var i: usize = 0;

    if (comptime lanes(f64)) |n| {
        const V = @Vector(n, f64);
        var acc: V = @splat(0);
        while (i + n <= samples.len) : (i += n) {
            const narrow: @Vector(n, f32) = samples[i..][0..n].*;
            const v: V = @floatCast(narrow);
            acc += v * v;
        }
        total = @reduce(.Add, acc);
    }

    for (samples[i..]) |s| total += @as(f64, s) * @as(f64, s);
    return total;
}

pub const Energy = struct {
    sum_of_squares: f32,
    /// True only if every sample is bit-exact zero.
    all_zero: bool,
};

/// `sumOfSquares` with a bit-exact zero check fused into the same pass, for the
/// audio callback: it needs the RMS for the level meter and the zero check to
/// spot a stuck microphone, and the buffer is only walked once. The check is
/// not folded into `sumOfSquares` because voice-activity detection runs that
/// one over every window of every recording and should not pay for a compare
/// and an or per lane that it would throw away.
pub fn energy(samples: []const f32) Energy {
    var total: f32 = 0;
    var nonzero = false;
    var i: usize = 0;

    if (comptime lanes(f32)) |n| {
        const V = @Vector(n, f32);
        const zero: V = @splat(0);
        var acc: V = @splat(0);
        var nonzero_lanes: @Vector(n, bool) = @splat(false);
        while (i + n <= samples.len) : (i += n) {
            const v: V = samples[i..][0..n].*;
            acc += v * v;
            nonzero_lanes = @select(bool, v != zero, @as(@Vector(n, bool), @splat(true)), nonzero_lanes);
        }
        total = @reduce(.Add, acc);
        nonzero = @reduce(.Or, nonzero_lanes);
    }

    for (samples[i..]) |s| {
        total += s * s;
        if (s != 0) nonzero = true;
    }

    return .{ .sum_of_squares = total, .all_zero = !nonzero };
}

/// Largest absolute amplitude in `samples`, or 0 for an empty slice.
pub fn maxAbs(samples: []const f32) f32 {
    var peak: f32 = 0;
    var i: usize = 0;

    if (comptime lanes(f32)) |n| {
        const V = @Vector(n, f32);
        var acc: V = @splat(0);
        while (i + n <= samples.len) : (i += n) {
            const v: V = samples[i..][0..n].*;
            acc = @max(acc, @abs(v));
        }
        peak = @reduce(.Max, acc);
    }

    for (samples[i..]) |s| peak = @max(peak, @abs(s));
    return peak;
}

/// Multiply every sample by `gain`, in place.
pub fn scale(samples: []f32, gain: f32) void {
    var i: usize = 0;

    if (comptime lanes(f32)) |n| {
        const V = @Vector(n, f32);
        const g: V = @splat(gain);
        while (i + n <= samples.len) : (i += n) {
            const v: V = samples[i..][0..n].*;
            samples[i..][0..n].* = v * g;
        }
    }

    for (samples[i..]) |*s| s.* *= gain;
}

/// Multiply every sample by `gain` and clamp the result into [-1, 1], in place.
pub fn scaleClamped(samples: []f32, gain: f32) void {
    var i: usize = 0;

    if (comptime lanes(f32)) |n| {
        const V = @Vector(n, f32);
        const g: V = @splat(gain);
        const min: V = @splat(-1.0);
        const max: V = @splat(1.0);
        while (i + n <= samples.len) : (i += n) {
            const v: V = samples[i..][0..n].*;
            samples[i..][0..n].* = @min(max, @max(min, v * g));
        }
    }

    for (samples[i..]) |*s| s.* = std.math.clamp(s.* * gain, -1.0, 1.0);
}

/// Decode little-endian 16-bit PCM frames into normalized floats, keeping the
/// first channel of each frame. `frame_bytes` is `2 * channels`, so anything
/// but mono is an interleaved read that no vector load can express without a
/// gather; those fall through to the scalar loop, which is also what runs on a
/// big-endian target. `out` must hold `raw.len / frame_bytes` samples.
pub fn dequantizeFromI16(raw: []const u8, frame_bytes: usize, out: []f32) void {
    std.debug.assert(frame_bytes >= 2);
    const count = raw.len / frame_bytes;
    std.debug.assert(out.len >= count);

    var i: usize = 0;

    if (comptime lanes(i16)) |n| {
        if (frame_bytes == 2 and @import("builtin").cpu.arch.endian() == .little) {
            const inv_full_scale: @Vector(n, f32) = @splat(1.0 / 32768.0);
            while (i + n <= count) : (i += n) {
                // Copied out as an array first: `raw` is byte-aligned, and the
                // copy is what lets the backend pick an unaligned load.
                const bytes: [n * 2]u8 = raw[i * 2 ..][0 .. n * 2].*;
                const quantized: @Vector(n, i16) = @bitCast(bytes);
                const v: @Vector(n, f32) = @floatFromInt(quantized);
                out[i..][0..n].* = v * inv_full_scale;
            }
        }
    }

    while (i < count) : (i += 1) {
        const quantized = std.mem.readInt(i16, raw[i * frame_bytes ..][0..2], .little);
        out[i] = @as(f32, @floatFromInt(quantized)) / 32768.0;
    }
}

/// Convert normalized float samples to 16-bit PCM, clamping out-of-range
/// values instead of wrapping them. `out` must be at least as long as
/// `samples`; only `out[0..samples.len]` is written.
pub fn quantizeToI16(samples: []const f32, out: []i16) void {
    std.debug.assert(out.len >= samples.len);
    var i: usize = 0;

    if (comptime lanes(f32)) |n| {
        const V = @Vector(n, f32);
        const min: V = @splat(-1.0);
        const max: V = @splat(1.0);
        const full_scale: V = @splat(32767.0);
        while (i + n <= samples.len) : (i += n) {
            const v: V = samples[i..][0..n].*;
            const clamped = @min(max, @max(min, v));
            const quantized: @Vector(n, i16) = @intFromFloat(clamped * full_scale);
            out[i..][0..n].* = quantized;
        }
    }

    for (samples[i..], out[i..samples.len]) |s, *o| {
        o.* = @intFromFloat(std.math.clamp(s, -1.0, 1.0) * 32767.0);
    }
}

fn stereoShuffleMask(comptime n: comptime_int, comptime channel: comptime_int) @Vector(n, i32) {
    var mask: [n]i32 = undefined;
    for (0..n) |lane| {
        const source = lane * 2 + channel;
        mask[lane] = if (source < n)
            @intCast(source)
        else
            ~@as(i32, @intCast(source - n));
    }
    return @bitCast(mask);
}

/// Average interleaved stereo frames into `out`. Two vector loads cover `n`
/// frames; `@shuffle` then deinterleaves their left and right lanes before the
/// lane-wise mean produces a full vector of mono samples. This is preferable
/// to a gather: stereo is both the overwhelmingly common multichannel capture
/// format and the one whose fixed stride maps cleanly onto a shuffle.
pub fn downmixStereo(interleaved: []const f32, out: []f32) void {
    std.debug.assert(interleaved.len % 2 == 0);
    const frames = interleaved.len / 2;
    std.debug.assert(out.len >= frames);

    var frame: usize = 0;
    if (comptime lanes(f32)) |n| {
        const V = @Vector(n, f32);
        const left_mask = comptime stereoShuffleMask(n, 0);
        const right_mask = comptime stereoShuffleMask(n, 1);
        const half: V = @splat(0.5);

        while (frame + n <= frames) : (frame += n) {
            const offset = frame * 2;
            const low: V = interleaved[offset..][0..n].*;
            const high: V = interleaved[offset + n ..][0..n].*;
            const left = @shuffle(f32, low, high, left_mask);
            const right = @shuffle(f32, low, high, right_mask);
            // Halve first so two same-sign finite f32 values cannot overflow
            // before their mean is taken.
            out[frame..][0..n].* = left * half + right * half;
        }
    }

    for (frame..frames) |i| {
        out[i] = interleaved[i * 2] * 0.5 + interleaved[i * 2 + 1] * 0.5;
    }
}

// Every test below runs lengths 0..64 so that the vector body and the scalar
// tail are both exercised on any lane count a target might pick, including the
// lengths where one of the two does nothing at all.
const max_test_len = 64;

fn testSamples(buf: []f32) []f32 {
    var seed: u32 = 0x9e3779b9;
    for (buf) |*s| {
        seed = seed *% 1664525 +% 1013904223;
        // Spread over [-1.25, 1.25) so the quantizer's clamp is reached too.
        s.* = (@as(f32, @floatFromInt(seed >> 8)) / 8388608.0 - 1.0) * 1.25;
    }
    return buf;
}

test "sumOfSquares matches the scalar loop" {
    var buf: [max_test_len]f32 = undefined;
    const all = testSamples(&buf);

    for (0..all.len + 1) |len| {
        const samples = all[0..len];
        var expected: f32 = 0;
        for (samples) |s| expected += s * s;
        try std.testing.expectApproxEqRel(expected, sumOfSquares(samples), 1e-5);
    }
}

test "energy matches the scalar loop and flags all-zero buffers" {
    var buf: [max_test_len]f32 = undefined;
    const all = testSamples(&buf);

    for (0..all.len + 1) |len| {
        const samples = all[0..len];
        var expected: f32 = 0;
        for (samples) |s| expected += s * s;

        const result = energy(samples);
        try std.testing.expectApproxEqRel(expected, result.sum_of_squares, 1e-5);
        try std.testing.expectEqual(len == 0, result.all_zero);
    }

    var zeros: [max_test_len]f32 = @splat(0);
    for (0..zeros.len + 1) |len| {
        try std.testing.expect(energy(zeros[0..len]).all_zero);
    }

    // A single non-zero sample must defeat the check from any position,
    // including one only the tail sees.
    for (0..zeros.len) |idx| {
        zeros[idx] = 1e-9;
        try std.testing.expect(!energy(&zeros).all_zero);
        zeros[idx] = 0;
    }
}

test "sumOfSquaresWide matches the scalar loop" {
    var buf: [max_test_len]f32 = undefined;
    const all = testSamples(&buf);

    for (0..all.len + 1) |len| {
        const samples = all[0..len];
        var expected: f64 = 0;
        for (samples) |s| expected += @as(f64, s) * @as(f64, s);
        try std.testing.expectApproxEqRel(expected, sumOfSquaresWide(samples), 1e-12);
    }
}

test "maxAbs matches the scalar loop" {
    var buf: [max_test_len]f32 = undefined;
    const all = testSamples(&buf);

    for (0..all.len + 1) |len| {
        const samples = all[0..len];
        var expected: f32 = 0;
        for (samples) |s| expected = @max(expected, @abs(s));
        try std.testing.expectEqual(expected, maxAbs(samples));
    }
}

test "downmixStereo matches the scalar loop including every tail length" {
    var interleaved: [max_test_len * 2]f32 = undefined;
    _ = testSamples(&interleaved);
    var actual: [max_test_len]f32 = undefined;

    for (0..max_test_len + 1) |frames| {
        downmixStereo(interleaved[0 .. frames * 2], actual[0..frames]);
        for (0..frames) |frame| {
            const expected = interleaved[frame * 2] * 0.5 + interleaved[frame * 2 + 1] * 0.5;
            try std.testing.expectEqual(expected, actual[frame]);
        }
    }
}

test "downmixStereo does not overflow while averaging finite samples" {
    const largest = std.math.floatMax(f32);
    const interleaved = [_]f32{ largest, largest, -largest, -largest };
    var actual: [2]f32 = undefined;
    downmixStereo(&interleaved, &actual);
    try std.testing.expectEqual(largest, actual[0]);
    try std.testing.expectEqual(-largest, actual[1]);
}

test "scale matches the scalar loop" {
    var buf: [max_test_len]f32 = undefined;
    const all = testSamples(&buf);

    for (0..all.len + 1) |len| {
        var expected: [max_test_len]f32 = undefined;
        var actual: [max_test_len]f32 = undefined;
        for (all[0..len], 0..) |s, i| {
            expected[i] = s * 0.75;
            actual[i] = s;
        }
        scale(actual[0..len], 0.75);
        try std.testing.expectEqualSlices(f32, expected[0..len], actual[0..len]);
    }
}

test "scaleClamped matches the scalar loop" {
    var buf: [max_test_len]f32 = undefined;
    const all = testSamples(&buf);

    for (0..all.len + 1) |len| {
        var expected: [max_test_len]f32 = undefined;
        var actual: [max_test_len]f32 = undefined;
        for (all[0..len], 0..) |s, i| {
            // A gain of 1.5 pushes the generated samples past 1.0, so the
            // clamp is what is actually being compared here.
            expected[i] = std.math.clamp(s * 1.5, -1.0, 1.0);
            actual[i] = s;
        }
        scaleClamped(actual[0..len], 1.5);
        try std.testing.expectEqualSlices(f32, expected[0..len], actual[0..len]);
    }
}

test "dequantizeFromI16 matches the scalar loop for mono and interleaved input" {
    const max_frame_bytes = 6;
    var raw: [max_test_len * max_frame_bytes]u8 = undefined;
    var seed: u32 = 0x1234567;
    for (&raw) |*b| {
        seed = seed *% 1664525 +% 1013904223;
        b.* = @truncate(seed >> 16);
    }

    for ([_]usize{ 2, 4, 6 }) |frame_bytes| {
        for (0..max_test_len + 1) |count| {
            const used = raw[0 .. count * frame_bytes];

            var expected: [max_test_len]f32 = undefined;
            for (0..count) |i| {
                const quantized = std.mem.readInt(i16, used[i * frame_bytes ..][0..2], .little);
                expected[i] = @as(f32, @floatFromInt(quantized)) / 32768.0;
            }

            var actual: [max_test_len]f32 = undefined;
            dequantizeFromI16(used, frame_bytes, &actual);
            try std.testing.expectEqualSlices(f32, expected[0..count], actual[0..count]);
        }
    }
}

test "quantizeToI16 matches the scalar loop and clamps" {
    var buf: [max_test_len]f32 = undefined;
    const all = testSamples(&buf);

    for (0..all.len + 1) |len| {
        var expected: [max_test_len]i16 = undefined;
        var actual: [max_test_len]i16 = undefined;
        for (all[0..len], 0..) |s, i| {
            expected[i] = @intFromFloat(std.math.clamp(s, -1.0, 1.0) * 32767.0);
        }
        quantizeToI16(all[0..len], &actual);
        try std.testing.expectEqualSlices(i16, expected[0..len], actual[0..len]);
    }

    var extremes = [_]f32{ 2.0, -2.0, 1.0, -1.0, 0.0, 0.5 };
    var quantized: [extremes.len]i16 = undefined;
    quantizeToI16(&extremes, &quantized);
    try std.testing.expectEqualSlices(i16, &.{ 32767, -32767, 32767, -32767, 0, 16383 }, &quantized);
}
