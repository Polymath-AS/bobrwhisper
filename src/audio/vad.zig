//! Energy-based voice activity detection and silence trimming.
//!
//! This is deliberately not whisper.cpp's VAD. That one runs a Silero model
//! inside the transcription call and needs a model file; these are cheap
//! decisions a caller makes *before* handing audio to an ASR engine — is there
//! any speech here at all, and where does it start and end.

const std = @import("std");
const simd = @import("simd.zig");

/// Mean energy above `threshold` counts as speech. `threshold` is in units of
/// mean square amplitude, so it compares against the square of an amplitude:
/// 0.01 is roughly a 0.1 amplitude floor.
pub fn detectVoiceActivity(samples: []const f32, threshold: f32) bool {
    if (samples.len == 0) return false;

    const mean_square = simd.sumOfSquares(samples) / @as(f32, @floatFromInt(samples.len));
    return mean_square > threshold;
}

pub const TrimBounds = struct {
    start: usize,
    end: usize,
};

/// Locate speech within `samples` by scanning 10 ms windows from both ends.
pub fn trimSilenceBounds(samples: []const f32, threshold: f32) TrimBounds {
    if (samples.len == 0) return .{ .start = 0, .end = 0 };

    const window_size: usize = 160;

    var start_idx: usize = 0;
    while (start_idx + window_size < samples.len) {
        if (detectVoiceActivity(samples[start_idx .. start_idx + window_size], threshold)) {
            break;
        }
        start_idx += window_size / 2;
    }

    var end_idx: usize = samples.len;
    while (end_idx > start_idx + window_size) {
        if (detectVoiceActivity(samples[end_idx - window_size .. end_idx], threshold)) {
            break;
        }
        end_idx -= window_size / 2;
    }

    // Keep context on both sides of the detected speech. In particular, do
    // not cut exactly at the first active window: plosives and very short
    // words can begin below the energy threshold, and losing that onset can
    // turn "I"/"a" into an empty transcript. The trailing context lets
    // Whisper finalize the last token.
    const head_padding: usize = 3200; // 0.2 s at 16 kHz
    const tail_padding: usize = 8000;
    start_idx -|= head_padding;
    end_idx = @min(samples.len, end_idx + tail_padding);

    return .{ .start = start_idx, .end = end_idx };
}

/// Estimate ambient noise floor from the first ~0.5s of audio.
/// Returns the RMS energy of a leading window, useful for deriving
/// an adaptive silence-trim threshold (e.g. 3× noise floor).
pub fn computeNoiseFloor(samples: []const f32) f32 {
    if (samples.len == 0) return 0;

    const window: usize = @min(8000, samples.len);
    const energy = simd.sumOfSquares(samples[0..window]);
    return @sqrt(energy / @as(f32, @floatFromInt(window)));
}

test "voice activity detection" {
    const silence = [_]f32{0.0} ** 100;
    const voice = [_]f32{0.5} ** 100;

    try std.testing.expect(!detectVoiceActivity(&silence, 0.01));
    try std.testing.expect(detectVoiceActivity(&voice, 0.01));
}

test "voice activity detection rejects an empty buffer" {
    try std.testing.expect(!detectVoiceActivity(&[_]f32{}, 0.01));
}

test "silence trimming preserves leading context for short speech" {
    var samples = [_]f32{0.0} ** 8000;
    @memset(samples[4000..4160], 0.5); // A single 10 ms active window.

    const bounds = trimSilenceBounds(&samples, 0.01);

    // Detection overlaps the active window at sample 3920. The 0.2 s head
    // padding must retain the quieter onset/context before it.
    try std.testing.expect(bounds.start <= 720);
    try std.testing.expect(bounds.start < 4000);
    try std.testing.expect(bounds.end > 4160);
}

test "silence trimming of an empty buffer yields an empty range" {
    const bounds = trimSilenceBounds(&[_]f32{}, 0.01);
    try std.testing.expectEqual(@as(usize, 0), bounds.start);
    try std.testing.expectEqual(@as(usize, 0), bounds.end);
}

test "silence trimming never returns a reversed range" {
    // All silence: the backward scan must not walk past the forward one.
    const silence = [_]f32{0.0} ** 8000;
    const bounds = trimSilenceBounds(&silence, 0.01);
    try std.testing.expect(bounds.start <= bounds.end);
    try std.testing.expect(bounds.end <= silence.len);
}

test "compute noise floor" {
    const silence = [_]f32{0.0} ** 100;
    const noise = [_]f32{0.1} ** 100;

    try std.testing.expectEqual(@as(f32, 0), computeNoiseFloor(&silence));
    try std.testing.expect(computeNoiseFloor(&noise) > 0.09);
    try std.testing.expect(computeNoiseFloor(&noise) < 0.11);
    try std.testing.expectEqual(@as(f32, 0), computeNoiseFloor(&[_]f32{}));
}
