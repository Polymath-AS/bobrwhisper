//! RIFF/WAVE decoding, in the narrow shape speech tooling needs.
//!
//! This lived inline in the libwhisper benchmark, which is the wrong home: the
//! test corpus scripts, the benchmark and anything embedding the capture library
//! all need the same conversion, so it belongs where all three can reach it.
//!
//! Supports PCM16 and IEEE float32, any sample rate, any channel count, and
//! always yields mono f32 at a requested rate. Rejected rather than guessed:
//! WAVE_FORMAT_EXTENSIBLE, 24-bit PCM, and the a-law/µ-law companded formats.

const std = @import("std");
const resample = @import("resample.zig");

pub const Error = error{
    NotRiffWave,
    MissingChunk,
    UnsupportedFormat,
    TruncatedFrame,
};

/// What the file says about itself, before any conversion.
pub const Info = struct {
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
    /// Frames, not samples: a stereo frame counts once.
    frames: usize,

    pub fn seconds(self: Info) f64 {
        if (self.sample_rate == 0) return 0;
        return @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

pub const Decoded = struct {
    /// Mono f32 at `sample_rate`.
    samples: []f32,
    sample_rate: u32,
    /// Properties of the file as stored, for reporting.
    source: Info,

    pub fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }
};

const format_pcm: u16 = 1;
const format_ieee_float: u16 = 3;

/// Decode `bytes` to mono f32, resampling to `target_rate` when it differs from
/// the file's rate. Pass `null` to keep the file's own rate.
pub fn decode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    target_rate: ?u32,
) (Error || std.mem.Allocator.Error)!Decoded {
    if (bytes.len < 12 or !eq(bytes[0..4], "RIFF") or !eq(bytes[8..12], "WAVE")) {
        return Error.NotRiffWave;
    }

    var format: u16 = 0;
    var channels: u16 = 0;
    var bits_per_sample: u16 = 0;
    var rate: u32 = 0;
    var data: ?[]const u8 = null;

    var cursor: usize = 12;
    while (cursor + 8 <= bytes.len) {
        const id = bytes[cursor..][0..4];
        const size = std.mem.readInt(u32, bytes[cursor + 4 ..][0..4], .little);
        const body_start = cursor + 8;
        const body_end = std.math.add(usize, body_start, size) catch break;
        if (body_end > bytes.len) break;

        if (eq(id, "fmt ") and size >= 16) {
            const fmt = bytes[body_start..][0..16];
            format = std.mem.readInt(u16, fmt[0..2], .little);
            channels = std.mem.readInt(u16, fmt[2..4], .little);
            rate = std.mem.readInt(u32, fmt[4..8], .little);
            bits_per_sample = std.mem.readInt(u16, fmt[14..16], .little);
        } else if (eq(id, "data")) {
            data = bytes[body_start..body_end];
        }

        // Chunks are word-aligned: an odd size carries a trailing pad byte.
        cursor = body_end + (size & 1);
        if (format != 0 and data != null) break;
    }

    const payload = data orelse return Error.MissingChunk;
    if (format == 0 or rate == 0 or channels == 0) return Error.MissingChunk;

    const pcm16 = format == format_pcm and bits_per_sample == 16;
    const float32 = format == format_ieee_float and bits_per_sample == 32;
    if (!pcm16 and !float32) return Error.UnsupportedFormat;

    const bytes_per_sample: usize = bits_per_sample / 8;
    const frame_size = bytes_per_sample * @as(usize, channels);
    if (payload.len % frame_size != 0) return Error.TruncatedFrame;
    const frames = payload.len / frame_size;

    const info: Info = .{
        .sample_rate = rate,
        .channels = channels,
        .bits_per_sample = bits_per_sample,
        .frames = frames,
    };

    // Decode straight to mono: holding an interleaved copy first would double
    // peak memory for no benefit, and long recordings are already large.
    const mono = try allocator.alloc(f32, frames);
    errdefer allocator.free(mono);
    for (mono, 0..) |*sample, frame| {
        var sum: f64 = 0;
        for (0..channels) |channel| {
            const offset = frame * frame_size + channel * bytes_per_sample;
            sum += if (pcm16)
                @as(f64, @floatFromInt(std.mem.readInt(i16, payload[offset..][0..2], .little))) / 32768.0
            else
                @as(f64, @as(f32, @bitCast(std.mem.readInt(u32, payload[offset..][0..4], .little))));
        }
        sample.* = @floatCast(sum / @as(f64, @floatFromInt(channels)));
    }

    const want = target_rate orelse rate;
    if (want == rate) {
        return .{ .samples = mono, .sample_rate = rate, .source = info };
    }

    defer allocator.free(mono);
    const converted = try resample.resample(
        allocator,
        mono,
        @floatFromInt(rate),
        @floatFromInt(want),
    );
    return .{ .samples = converted, .sample_rate = want, .source = info };
}

/// Encode mono f32 as a 16-bit PCM WAV. Exists mainly so tests and fixtures can
/// round-trip without shelling out to ffmpeg.
pub fn encodePcm16(
    allocator: std.mem.Allocator,
    samples: []const f32,
    sample_rate: u32,
) std.mem.Allocator.Error![]u8 {
    const data_bytes: u32 = @intCast(samples.len * 2);
    const out = try allocator.alloc(u8, 44 + data_bytes);

    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_bytes, .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], format_pcm, .little);
    std.mem.writeInt(u16, out[22..24], 1, .little);
    std.mem.writeInt(u32, out[24..28], sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], sample_rate * 2, .little);
    std.mem.writeInt(u16, out[32..34], 2, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_bytes, .little);

    for (samples, 0..) |sample, i| {
        const clamped = std.math.clamp(sample, -1.0, 1.0);
        const quantized: i16 = @intFromFloat(@round(clamped * 32767.0));
        std.mem.writeInt(i16, out[44 + i * 2 ..][0..2], quantized, .little);
    }
    return out;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "round-trips mono pcm16" {
    const original = [_]f32{ 0.0, 0.5, -0.5, 0.25 };
    const encoded = try encodePcm16(std.testing.allocator, &original, 16000);
    defer std.testing.allocator.free(encoded);

    const decoded = try decode(std.testing.allocator, encoded, null);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 16000), decoded.sample_rate);
    try std.testing.expectEqual(@as(u16, 1), decoded.source.channels);
    try std.testing.expectEqual(@as(usize, 4), decoded.source.frames);
    for (original, decoded.samples) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.0001);
    }
}

test "reports duration from the source header" {
    const samples = [_]f32{0.0} ** 8000;
    const encoded = try encodePcm16(std.testing.allocator, &samples, 16000);
    defer std.testing.allocator.free(encoded);

    const decoded = try decode(std.testing.allocator, encoded, null);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), decoded.source.seconds(), 0.0001);
}

test "resamples to the requested rate" {
    const samples = [_]f32{0.25} ** 480;
    const encoded = try encodePcm16(std.testing.allocator, &samples, 48000);
    defer std.testing.allocator.free(encoded);

    const decoded = try decode(std.testing.allocator, encoded, 16000);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 16000), decoded.sample_rate);
    try std.testing.expectEqual(@as(usize, 160), decoded.samples.len);
    // The source properties still describe the file, not the conversion.
    try std.testing.expectEqual(@as(u32, 48000), decoded.source.sample_rate);
}

test "rejects a non-RIFF file" {
    try std.testing.expectError(Error.NotRiffWave, decode(std.testing.allocator, "not a wav at all", null));
}

test "rejects a truncated header" {
    try std.testing.expectError(Error.NotRiffWave, decode(std.testing.allocator, "RIFF", null));
}

test "rejects a missing data chunk" {
    var header: [44]u8 = undefined;
    const encoded = try encodePcm16(std.testing.allocator, &[_]f32{}, 16000);
    defer std.testing.allocator.free(encoded);
    @memcpy(&header, encoded[0..44]);
    // Rename `data` so the chunk walk never finds a payload.
    @memcpy(header[36..40], "junk");
    try std.testing.expectError(Error.MissingChunk, decode(std.testing.allocator, &header, null));
}

test "rejects an unsupported bit depth" {
    const encoded = try encodePcm16(std.testing.allocator, &[_]f32{ 0.1, 0.2 }, 16000);
    defer std.testing.allocator.free(encoded);
    // Claim 24-bit, which this decoder deliberately does not guess at.
    std.mem.writeInt(u16, encoded[34..36], 24, .little);
    try std.testing.expectError(Error.UnsupportedFormat, decode(std.testing.allocator, encoded, null));
}

test "rejects a truncated frame" {
    // Three 16-bit samples is 6 bytes, which two channels (4 bytes per frame)
    // cannot divide evenly.
    const encoded = try encodePcm16(std.testing.allocator, &[_]f32{ 0.1, 0.2, 0.3 }, 16000);
    defer std.testing.allocator.free(encoded);
    std.mem.writeInt(u16, encoded[22..24], 2, .little);
    try std.testing.expectError(Error.TruncatedFrame, decode(std.testing.allocator, encoded, null));
}

test "decodes stereo down to mono" {
    // Hand-build a stereo file: left 1.0, right 0.0 -> mono 0.5.
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    const frames = 4;
    const data_bytes: u32 = frames * 2 * 2;
    try bytes.appendSlice(std.testing.allocator, "RIFF");
    try bytes.appendNTimes(std.testing.allocator, 0, 4);
    std.mem.writeInt(u32, bytes.items[4..8], 36 + data_bytes, .little);
    try bytes.appendSlice(std.testing.allocator, "WAVEfmt ");
    var scratch: [4]u8 = undefined;
    std.mem.writeInt(u32, &scratch, 16, .little);
    try bytes.appendSlice(std.testing.allocator, &scratch);
    var two: [2]u8 = undefined;
    std.mem.writeInt(u16, &two, format_pcm, .little);
    try bytes.appendSlice(std.testing.allocator, &two);
    std.mem.writeInt(u16, &two, 2, .little); // channels
    try bytes.appendSlice(std.testing.allocator, &two);
    std.mem.writeInt(u32, &scratch, 16000, .little);
    try bytes.appendSlice(std.testing.allocator, &scratch);
    std.mem.writeInt(u32, &scratch, 16000 * 4, .little);
    try bytes.appendSlice(std.testing.allocator, &scratch);
    std.mem.writeInt(u16, &two, 4, .little); // block align
    try bytes.appendSlice(std.testing.allocator, &two);
    std.mem.writeInt(u16, &two, 16, .little); // bits
    try bytes.appendSlice(std.testing.allocator, &two);
    try bytes.appendSlice(std.testing.allocator, "data");
    std.mem.writeInt(u32, &scratch, data_bytes, .little);
    try bytes.appendSlice(std.testing.allocator, &scratch);
    for (0..frames) |_| {
        std.mem.writeInt(i16, &two, 32767, .little);
        try bytes.appendSlice(std.testing.allocator, &two);
        std.mem.writeInt(i16, &two, 0, .little);
        try bytes.appendSlice(std.testing.allocator, &two);
    }

    const decoded = try decode(std.testing.allocator, bytes.items, null);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 2), decoded.source.channels);
    try std.testing.expectEqual(@as(usize, frames), decoded.samples.len);
    for (decoded.samples) |sample| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), sample, 0.001);
    }
}
