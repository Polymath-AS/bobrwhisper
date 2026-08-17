//! Sample-rate conversion and channel downmixing.
//!
//! Whisper wants 16 kHz mono float. Capture devices hand you 44.1 or 48 kHz,
//! often stereo, so something has to bridge the two — this is that something,
//! and it is the reason an audio library exists separately from the ASR one.

const std = @import("std");
const simd = @import("simd.zig");

/// The rate every ASR path in this project expects.
pub const asr_sample_rate: u32 = 16000;

/// Linear interpolation between neighbouring input samples. Good enough for
/// speech headed into an ASR model, which downmixes to a mel spectrogram
/// anyway; a polyphase filter would cost more than it buys here.
pub fn resample(
    allocator: std.mem.Allocator,
    samples: []const f32,
    from_rate: f64,
    to_rate: f64,
) ![]f32 {
    std.debug.assert(from_rate > 0);
    std.debug.assert(to_rate > 0);
    if (from_rate == to_rate) {
        return allocator.dupe(f32, samples);
    }

    const ratio = from_rate / to_rate;
    const new_len: usize = @intFromFloat(@as(f64, @floatFromInt(samples.len)) / ratio);
    const output = try allocator.alloc(f32, new_len);

    for (0..new_len) |i| {
        const src_idx = @as(f64, @floatFromInt(i)) * ratio;
        const idx: usize = @intFromFloat(src_idx);
        const frac = src_idx - @as(f64, @floatFromInt(idx));

        if (idx + 1 < samples.len) {
            output[i] = samples[idx] * @as(f32, @floatCast(1.0 - frac)) +
                samples[idx + 1] * @as(f32, @floatCast(frac));
        } else {
            output[i] = samples[idx];
        }
    }

    return output;
}

/// Average interleaved channels down to mono. `channels` of 1 is a plain copy.
pub fn downmix(allocator: std.mem.Allocator, interleaved: []const f32, channels: u16) ![]f32 {
    std.debug.assert(channels > 0);
    if (channels == 1) return allocator.dupe(f32, interleaved);
    if (interleaved.len % channels != 0) return error.TruncatedFrame;

    const frames = interleaved.len / channels;
    const output = try allocator.alloc(f32, frames);
    if (channels == 2) {
        simd.downmixStereo(interleaved, output);
        return output;
    }

    for (output, 0..) |*sample, frame| {
        var sum: f64 = 0;
        for (0..channels) |channel| sum += interleaved[frame * channels + channel];
        sample.* = @floatCast(sum / @as(f64, @floatFromInt(channels)));
    }
    return output;
}

/// Downmix then resample to `asr_sample_rate`, the one call a capture backend
/// actually needs. Returns a fresh buffer the caller owns.
pub fn toAsrFormat(
    allocator: std.mem.Allocator,
    interleaved: []const f32,
    channels: u16,
    from_rate: f64,
) ![]f32 {
    const mono = try downmix(allocator, interleaved, channels);
    if (from_rate == @as(f64, @floatFromInt(asr_sample_rate))) return mono;
    defer allocator.free(mono);
    return resample(allocator, mono, from_rate, @floatFromInt(asr_sample_rate));
}

test "resample at the same rate copies" {
    const input = [_]f32{ 0.1, 0.2, 0.3 };
    const output = try resample(std.testing.allocator, &input, 16000, 16000);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(f32, &input, output);
}

test "resample halving the rate halves the length" {
    const input = [_]f32{ 0, 1, 0, 1, 0, 1, 0, 1 };
    const output = try resample(std.testing.allocator, &input, 32000, 16000);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 4), output.len);
}

test "resample 48k to 16k keeps a constant signal constant" {
    const input = [_]f32{0.25} ** 480;
    const output = try resample(std.testing.allocator, &input, 48000, 16000);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 160), output.len);
    for (output) |sample| try std.testing.expectApproxEqAbs(@as(f32, 0.25), sample, 0.0001);
}

test "resample interpolates rather than dropping samples" {
    // Upsampling 2x must place a midpoint between neighbours.
    const input = [_]f32{ 0.0, 1.0 };
    const output = try resample(std.testing.allocator, &input, 16000, 32000);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 4), output.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), output[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), output[1], 0.0001);
}

test "resample of an empty buffer is empty" {
    const output = try resample(std.testing.allocator, &[_]f32{}, 48000, 16000);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "downmix averages stereo" {
    const stereo = [_]f32{ 1.0, 0.0, 0.5, 0.5, -1.0, 1.0 };
    const mono = try downmix(std.testing.allocator, &stereo, 2);
    defer std.testing.allocator.free(mono);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5, 0.0 }, mono);
}

test "downmix of mono copies" {
    const input = [_]f32{ 0.1, 0.2 };
    const mono = try downmix(std.testing.allocator, &input, 1);
    defer std.testing.allocator.free(mono);
    try std.testing.expectEqualSlices(f32, &input, mono);
}

test "downmix rejects a truncated frame" {
    const stereo = [_]f32{ 1.0, 0.0, 0.5 };
    try std.testing.expectError(error.TruncatedFrame, downmix(std.testing.allocator, &stereo, 2));
}

test "toAsrFormat converts 48 kHz stereo in one step" {
    const stereo = [_]f32{ 0.5, 0.5 } ** 480;
    const out = try toAsrFormat(std.testing.allocator, &stereo, 2, 48000);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 160), out.len);
    for (out) |sample| try std.testing.expectApproxEqAbs(@as(f32, 0.5), sample, 0.0001);
}

test "toAsrFormat at 16 kHz mono still returns an owned buffer" {
    const input = [_]f32{ 0.1, 0.2, 0.3 };
    const out = try toAsrFormat(std.testing.allocator, &input, 1, 16000);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(f32, &input, out);
}
