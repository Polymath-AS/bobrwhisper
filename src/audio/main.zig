//! Audio processing: everything between a capture device and an ASR engine.
//!
//! This module is deliberately dependency-free — no whisper.cpp, no ggml, no
//! platform audio APIs, not even libc beyond what Zig's standard library uses.
//! That is what makes it the easiest part of the project to work on and to test:
//! `zig build test-audio` needs no model, no microphone and no Xcode.
//!
//! The ASR library does not depend on this one. libwhisper takes 16 kHz mono
//! float PCM and nothing else, which keeps it embeddable by callers who already
//! have audio in that form. This module is what capture backends and file-based
//! tools use to *get* there.

const std = @import("std");

pub const simd = @import("simd.zig");
pub const wav = @import("wav.zig");
pub const vad = @import("vad.zig");
pub const level = @import("level.zig");
pub const Chunker = @import("Chunker.zig");

const resample_impl = @import("resample.zig");

pub const asr_sample_rate = resample_impl.asr_sample_rate;
pub const resample = resample_impl.resample;
pub const downmix = resample_impl.downmix;
pub const toAsrFormat = resample_impl.toAsrFormat;

// Flattened for the common calls, so a caller does not have to remember which
// file each one lives in.
pub const detectVoiceActivity = vad.detectVoiceActivity;
pub const trimSilenceBounds = vad.trimSilenceBounds;
pub const computeNoiseFloor = vad.computeNoiseFloor;
pub const TrimBounds = vad.TrimBounds;
pub const peakNormalize = level.peakNormalize;
pub const measureLevel = level.measure;
pub const Level = level.Level;

/// The preprocessing the app applies before transcription, in one call: boost
/// quiet input, estimate the noise floor, then trim to the speech. Returns a
/// slice of `samples`, which is modified in place by the normalization.
///
/// The threshold is derived from the measured noise floor rather than fixed,
/// because a fixed one either clips quiet speech or fails to trim a noisy room.
pub fn prepareForAsr(samples: []f32, options: PrepareOptions) Prepared {
    const gain = if (options.normalize) peakNormalize(samples, options.target_peak) else 1.0;
    const noise_floor = computeNoiseFloor(samples);
    const threshold = @max(options.min_threshold, noise_floor * noise_floor * options.noise_multiplier);
    const bounds = trimSilenceBounds(samples, threshold);
    return .{
        .samples = samples[bounds.start..bounds.end],
        .gain = gain,
        .noise_floor = noise_floor,
        .threshold = threshold,
        .bounds = bounds,
    };
}

pub const PrepareOptions = struct {
    normalize: bool = true,
    target_peak: f32 = 0.95,
    /// Multiplier on the squared noise floor. 9 is 3x in amplitude terms.
    noise_multiplier: f32 = 9.0,
    /// Floor for the derived threshold, so near-silent input still trims.
    min_threshold: f32 = 0.0001,
};

pub const Prepared = struct {
    samples: []f32,
    gain: f32,
    noise_floor: f32,
    threshold: f32,
    bounds: TrimBounds,
};

test {
    // Pull in every submodule's tests. Referencing the files directly rather
    // than via refAllDecls, which does not recurse in 0.16 and so would silently
    // skip them.
    _ = simd;
    _ = wav;
    _ = vad;
    _ = level;
    _ = Chunker;
    _ = resample_impl;
}

test "prepareForAsr normalizes and trims to the speech" {
    var samples = [_]f32{0.0} ** 32000;
    // A quiet burst of speech in the middle of two seconds of silence.
    @memset(samples[16000..16800], 0.05);

    const prepared = prepareForAsr(&samples, .{});

    try std.testing.expect(prepared.gain > 1.0);
    try std.testing.expect(prepared.samples.len < samples.len);
    try std.testing.expect(prepared.samples.len > 800);
    try std.testing.expect(prepared.bounds.start < 16000);
    try std.testing.expect(prepared.bounds.end > 16800);
}

test "prepareForAsr can skip normalization" {
    var samples = [_]f32{0.0} ** 16000;
    @memset(samples[8000..8400], 0.05);
    const prepared = prepareForAsr(&samples, .{ .normalize = false });
    try std.testing.expectEqual(@as(f32, 1.0), prepared.gain);
}

test "prepareForAsr on silence yields a usable empty-ish range" {
    var samples = [_]f32{0.0} ** 16000;
    const prepared = prepareForAsr(&samples, .{});
    try std.testing.expect(prepared.bounds.start <= prepared.bounds.end);
    try std.testing.expect(prepared.samples.len <= samples.len);
}

test "a capture-shaped buffer converts and chunks end to end" {
    const allocator = std.testing.allocator;

    // 48 kHz stereo, as a device would deliver it.
    const interleaved = [_]f32{ 0.4, 0.6 } ** 4800;
    const mono16k = try toAsrFormat(allocator, &interleaved, 2, 48000);
    defer allocator.free(mono16k);
    try std.testing.expectEqual(@as(usize, 1600), mono16k.len);

    var chunker = Chunker.init(allocator, .{ .chunk_len = 512 });
    defer chunker.deinit();
    try chunker.push(mono16k);

    var chunks: usize = 0;
    while (chunker.next()) |chunk| {
        try std.testing.expectEqual(@as(usize, 512), chunk.len);
        chunks += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), chunks);
    try std.testing.expectEqual(@as(usize, 64), chunker.flush().len);
}
