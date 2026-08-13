//! Amplitude measurement and gain.

const std = @import("std");
const simd = @import("simd.zig");

/// Loudness of a buffer, in the two forms callers actually want: peak amplitude
/// for headroom decisions and RMS for perceived level.
pub const Level = struct {
    peak: f32,
    rms: f32,
};

pub fn measure(samples: []const f32) Level {
    if (samples.len == 0) return .{ .peak = 0, .rms = 0 };
    return .{
        .peak = simd.maxAbs(samples),
        .rms = @sqrt(simd.sumOfSquares(samples) / @as(f32, @floatFromInt(samples.len))),
    };
}

/// In-place peak normalization. Scales `samples` so the largest absolute
/// amplitude becomes `target_peak` (typically 0.95 to avoid hard clipping).
/// Returns the gain factor that was applied. Only ever scales up: if the
/// input is already at or above `target_peak` the buffer is unchanged.
/// Silent buffers (peak < 1e-4) are also left alone to avoid amplifying noise.
///
/// Whispered speech routinely has peaks of ~0.25 vs. ~0.6 for normal voice,
/// which produced a 4–7× WER improvement in the `tune` experiments. Applying
/// this before trimming and transcription is safe for normal voice (the gain
/// factor stays near 1.0) but materially helps quiet audio.
pub fn peakNormalize(samples: []f32, target_peak: f32) f32 {
    std.debug.assert(target_peak > 0.0);
    std.debug.assert(target_peak <= 1.0);
    if (samples.len == 0) return 1.0;

    const peak = simd.maxAbs(samples);
    if (peak < 1e-4 or peak >= target_peak) return 1.0;

    const gain = target_peak / peak;
    simd.scale(samples, gain);
    return gain;
}

test "measure reports peak and rms" {
    const samples = [_]f32{ 0.5, -0.5, 0.5, -0.5 };
    const level = measure(&samples);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), level.peak, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), level.rms, 0.0001);
}

test "measure of an empty buffer is zero" {
    const level = measure(&[_]f32{});
    try std.testing.expectEqual(@as(f32, 0), level.peak);
    try std.testing.expectEqual(@as(f32, 0), level.rms);
}

test "peakNormalize boosts quiet audio" {
    var samples = [_]f32{ 0.1, -0.2, 0.05, -0.1 };
    const gain = peakNormalize(&samples, 0.95);
    try std.testing.expectApproxEqAbs(@as(f32, 4.75), gain, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.95), samples[1], 0.001);
}

test "peakNormalize leaves loud audio unchanged" {
    var samples = [_]f32{ 0.5, -0.95 };
    const gain = peakNormalize(&samples, 0.95);
    try std.testing.expectEqual(@as(f32, 1.0), gain);
    try std.testing.expectEqual(@as(f32, 0.5), samples[0]);
}

test "peakNormalize handles silence" {
    var silence = [_]f32{0.0} ** 8;
    const gain = peakNormalize(&silence, 0.95);
    try std.testing.expectEqual(@as(f32, 1.0), gain);
}

test "peakNormalize empty buffer" {
    var empty: [0]f32 = .{};
    const gain = peakNormalize(&empty, 0.95);
    try std.testing.expectEqual(@as(f32, 1.0), gain);
}

test "peakNormalize never exceeds the target" {
    var samples = [_]f32{ 0.01, -0.003, 0.007 };
    _ = peakNormalize(&samples, 0.95);
    try std.testing.expect(simd.maxAbs(&samples) <= 0.95 + 0.0001);
}
