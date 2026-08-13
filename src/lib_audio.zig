//! C ABI for the audio processing library.
//!
//! Same boundary rules as src/libwhisper.zig, for the same reasons:
//!
//!   * An owned buffer is reported as `ptr == NULL` when empty. Zig's
//!     zero-length allocations return a non-null unmapped pointer, which a C
//!     caller would happily dereference.
//!   * The error enum is non-exhaustive. C can hand us any `int`, and switching
//!     exhaustively on an out-of-range value aborts the embedder's process.
//!   * Options structs carry a `struct_size`, so growing one later is detectable
//!     rather than silent.
//!
//! Unlike libwhisper there is no log handler, because nothing here logs: every
//! function is pure computation over caller-provided memory.

const std = @import("std");
const audio = @import("audio");

const allocator = std.heap.c_allocator;

const version = "0.1.0";

const Error = enum(c_int) {
    success = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    not_riff_wave = 3,
    missing_chunk = 4,
    unsupported_format = 5,
    truncated_frame = 6,
    unknown = 255,
    _,
};

/// An owned buffer of mono f32 samples. Release with
/// `bobrwhisper_audio_buffer_free`; `ptr == NULL` means empty and needs no
/// release.
const Buffer = extern struct {
    ptr: ?[*]f32,
    len: usize,

    const empty: Buffer = .{ .ptr = null, .len = 0 };

    /// Hand a Zig-owned slice to C, collapsing the zero-length case to NULL.
    fn take(samples: []f32) Buffer {
        if (samples.len == 0) {
            allocator.free(samples);
            return .empty;
        }
        return .{ .ptr = samples.ptr, .len = samples.len };
    }
};

const WavInfo = extern struct {
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
    frames: usize,
};

const Level = extern struct {
    peak: f32,
    rms: f32,
};

const TrimBounds = extern struct {
    start: usize,
    end: usize,
};

const PrepareOptions = extern struct {
    struct_size: usize,
    normalize: bool,
    target_peak: f32,
    noise_multiplier: f32,
    min_threshold: f32,
};

const Prepared = extern struct {
    /// Range within the input buffer, which `prepare_for_asr` modified in place.
    bounds: TrimBounds,
    gain: f32,
    noise_floor: f32,
    threshold: f32,
};

pub export fn bobrwhisper_audio_version() [*:0]const u8 {
    return version;
}

pub export fn bobrwhisper_audio_asr_sample_rate() u32 {
    return audio.asr_sample_rate;
}

pub export fn bobrwhisper_audio_error_string(err: Error) [*:0]const u8 {
    return switch (err) {
        .success => "success",
        .invalid_argument => "invalid argument",
        .out_of_memory => "out of memory",
        .not_riff_wave => "not a RIFF/WAVE file",
        .missing_chunk => "missing fmt or data chunk",
        .unsupported_format => "unsupported sample format",
        .truncated_frame => "truncated audio frame",
        .unknown => "unknown error",
        _ => "unrecognized error code",
    };
}

pub export fn bobrwhisper_audio_buffer_free(buffer: Buffer) void {
    const ptr = buffer.ptr orelse return;
    allocator.free(ptr[0..buffer.len]);
}

/// Decode a RIFF/WAVE file to mono f32. `target_rate` of 0 keeps the file's own
/// rate. `out_info` is optional and describes the file as stored.
pub export fn bobrwhisper_audio_decode_wav(
    bytes: ?[*]const u8,
    len: usize,
    target_rate: u32,
    out_samples: ?*Buffer,
    out_info: ?*WavInfo,
) Error {
    const out = out_samples orelse return .invalid_argument;
    out.* = .empty;
    if (out_info) |info| info.* = .{ .sample_rate = 0, .channels = 0, .bits_per_sample = 0, .frames = 0 };
    const data = bytes orelse return .invalid_argument;

    const decoded = audio.wav.decode(
        allocator,
        data[0..len],
        if (target_rate == 0) null else target_rate,
    ) catch |err| return mapError(err);

    if (out_info) |info| info.* = .{
        .sample_rate = decoded.source.sample_rate,
        .channels = decoded.source.channels,
        .bits_per_sample = decoded.source.bits_per_sample,
        .frames = decoded.source.frames,
    };
    out.* = Buffer.take(decoded.samples);
    return .success;
}

/// Downmix interleaved channels and resample to the ASR rate in one step.
pub export fn bobrwhisper_audio_to_asr_format(
    interleaved: ?[*]const f32,
    len: usize,
    channels: u16,
    from_rate: f64,
    out_samples: ?*Buffer,
) Error {
    const out = out_samples orelse return .invalid_argument;
    out.* = .empty;
    const input = interleaved orelse return .invalid_argument;
    if (channels == 0 or !(from_rate > 0)) return .invalid_argument;

    const converted = audio.toAsrFormat(allocator, input[0..len], channels, from_rate) catch |err|
        return mapError(err);
    out.* = Buffer.take(converted);
    return .success;
}

pub export fn bobrwhisper_audio_resample(
    samples: ?[*]const f32,
    len: usize,
    from_rate: f64,
    to_rate: f64,
    out_samples: ?*Buffer,
) Error {
    const out = out_samples orelse return .invalid_argument;
    out.* = .empty;
    const input = samples orelse return .invalid_argument;
    if (!(from_rate > 0) or !(to_rate > 0)) return .invalid_argument;

    const converted = audio.resample(allocator, input[0..len], from_rate, to_rate) catch |err|
        return mapError(err);
    out.* = Buffer.take(converted);
    return .success;
}

pub export fn bobrwhisper_audio_measure(samples: ?[*]const f32, len: usize) Level {
    const input = samples orelse return .{ .peak = 0, .rms = 0 };
    const measured = audio.measureLevel(input[0..len]);
    return .{ .peak = measured.peak, .rms = measured.rms };
}

/// In-place. Returns the gain applied; 1.0 means the buffer was left alone.
pub export fn bobrwhisper_audio_peak_normalize(
    samples: ?[*]f32,
    len: usize,
    target_peak: f32,
) f32 {
    const input = samples orelse return 1.0;
    if (!(target_peak > 0) or target_peak > 1.0) return 1.0;
    return audio.peakNormalize(input[0..len], target_peak);
}

pub export fn bobrwhisper_audio_detect_voice(
    samples: ?[*]const f32,
    len: usize,
    threshold: f32,
) bool {
    const input = samples orelse return false;
    return audio.detectVoiceActivity(input[0..len], threshold);
}

pub export fn bobrwhisper_audio_noise_floor(samples: ?[*]const f32, len: usize) f32 {
    const input = samples orelse return 0;
    return audio.computeNoiseFloor(input[0..len]);
}

pub export fn bobrwhisper_audio_trim_silence(
    samples: ?[*]const f32,
    len: usize,
    threshold: f32,
) TrimBounds {
    const input = samples orelse return .{ .start = 0, .end = 0 };
    const bounds = audio.trimSilenceBounds(input[0..len], threshold);
    return .{ .start = bounds.start, .end = bounds.end };
}

pub export fn bobrwhisper_audio_prepare_options_init(options: ?*PrepareOptions) void {
    const out = options orelse return;
    const defaults: audio.PrepareOptions = .{};
    out.* = .{
        .struct_size = @sizeOf(PrepareOptions),
        .normalize = defaults.normalize,
        .target_peak = defaults.target_peak,
        .noise_multiplier = defaults.noise_multiplier,
        .min_threshold = defaults.min_threshold,
    };
}

/// Normalize, measure the noise floor, and locate the speech, modifying
/// `samples` in place. Pass NULL options for the defaults.
pub export fn bobrwhisper_audio_prepare_for_asr(
    samples: ?[*]f32,
    len: usize,
    options: ?*const PrepareOptions,
    out_result: ?*Prepared,
) Error {
    const out = out_result orelse return .invalid_argument;
    out.* = .{ .bounds = .{ .start = 0, .end = 0 }, .gain = 1.0, .noise_floor = 0, .threshold = 0 };
    const input = samples orelse return .invalid_argument;

    var zig_options: audio.PrepareOptions = .{};
    if (options) |opts| {
        if (opts.struct_size != @sizeOf(PrepareOptions)) return .invalid_argument;
        if (!(opts.target_peak > 0) or opts.target_peak > 1.0) return .invalid_argument;
        zig_options = .{
            .normalize = opts.normalize,
            .target_peak = opts.target_peak,
            .noise_multiplier = opts.noise_multiplier,
            .min_threshold = opts.min_threshold,
        };
    }

    const prepared = audio.prepareForAsr(input[0..len], zig_options);
    out.* = .{
        .bounds = .{ .start = prepared.bounds.start, .end = prepared.bounds.end },
        .gain = prepared.gain,
        .noise_floor = prepared.noise_floor,
        .threshold = prepared.threshold,
    };
    return .success;
}

pub export fn bobrwhisper_audio_chunker_create(
    chunk_len: usize,
    overlap_len: usize,
    out_chunker: ?*?*audio.Chunker,
) Error {
    const out = out_chunker orelse return .invalid_argument;
    out.* = null;
    if (chunk_len == 0 or overlap_len >= chunk_len) return .invalid_argument;

    const chunker = allocator.create(audio.Chunker) catch return .out_of_memory;
    chunker.* = audio.Chunker.init(allocator, .{
        .chunk_len = chunk_len,
        .overlap_len = overlap_len,
    });
    out.* = chunker;
    return .success;
}

pub export fn bobrwhisper_audio_chunker_destroy(chunker: ?*audio.Chunker) void {
    const handle = chunker orelse return;
    handle.deinit();
    allocator.destroy(handle);
}

pub export fn bobrwhisper_audio_chunker_push(
    chunker: ?*audio.Chunker,
    samples: ?[*]const f32,
    len: usize,
) Error {
    const handle = chunker orelse return .invalid_argument;
    const input = samples orelse return .invalid_argument;
    handle.push(input[0..len]) catch return .out_of_memory;
    return .success;
}

/// Borrow the next chunk. Returns false when one is not complete yet. The
/// samples stay valid until the next push or reset.
pub export fn bobrwhisper_audio_chunker_next(
    chunker: ?*audio.Chunker,
    out_samples: ?*[*]const f32,
    out_len: ?*usize,
) bool {
    const handle = chunker orelse return false;
    const chunk = handle.next() orelse return false;
    if (out_samples) |ptr| ptr.* = chunk.ptr;
    if (out_len) |len| len.* = chunk.len;
    return true;
}

/// Samples that do not fill a chunk, for end of stream. Borrowed, same lifetime
/// rules as `chunker_next`.
pub export fn bobrwhisper_audio_chunker_flush(
    chunker: ?*audio.Chunker,
    out_samples: ?*[*]const f32,
    out_len: ?*usize,
) usize {
    const handle = chunker orelse return 0;
    const rest = handle.flush();
    if (out_samples) |ptr| ptr.* = rest.ptr;
    if (out_len) |len| len.* = rest.len;
    return rest.len;
}

pub export fn bobrwhisper_audio_chunker_ready(chunker: ?*audio.Chunker) usize {
    const handle = chunker orelse return 0;
    return handle.ready();
}

pub export fn bobrwhisper_audio_chunker_reset(chunker: ?*audio.Chunker) void {
    const handle = chunker orelse return;
    handle.reset();
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.NotRiffWave => .not_riff_wave,
        error.MissingChunk => .missing_chunk,
        error.UnsupportedFormat => .unsupported_format,
        error.TruncatedFrame => .truncated_frame,
        else => .unknown,
    };
}

test "error_string never faults on an unrecognized code" {
    const bogus: Error = @enumFromInt(4242);
    try std.testing.expectEqualStrings(
        "unrecognized error code",
        std.mem.span(bobrwhisper_audio_error_string(bogus)),
    );
    try std.testing.expectEqualStrings(
        "not a RIFF/WAVE file",
        std.mem.span(bobrwhisper_audio_error_string(.not_riff_wave)),
    );
}

test "null arguments are rejected rather than dereferenced" {
    var buffer: Buffer = .{ .ptr = @ptrFromInt(0xdeadbee0), .len = 99 };
    try std.testing.expectEqual(
        Error.invalid_argument,
        bobrwhisper_audio_decode_wav(null, 0, 0, &buffer, null),
    );
    try std.testing.expect(buffer.ptr == null);
    try std.testing.expectEqual(@as(usize, 0), buffer.len);

    try std.testing.expectEqual(
        Error.invalid_argument,
        bobrwhisper_audio_decode_wav(null, 0, 0, null, null),
    );
    try std.testing.expectEqual(@as(f32, 1.0), bobrwhisper_audio_peak_normalize(null, 0, 0.95));
    try std.testing.expect(!bobrwhisper_audio_detect_voice(null, 0, 0.01));
    try std.testing.expectEqual(@as(f32, 0), bobrwhisper_audio_noise_floor(null, 0));
    bobrwhisper_audio_buffer_free(.empty);
    bobrwhisper_audio_chunker_destroy(null);
    bobrwhisper_audio_prepare_options_init(null);
}

test "an empty result is reported as a null pointer, not a dangling one" {
    var buffer: Buffer = .{ .ptr = @ptrFromInt(0xdeadbee0), .len = 99 };
    // Resampling nothing produces nothing; the C caller must not receive Zig's
    // non-null zero-length pointer.
    try std.testing.expectEqual(
        Error.success,
        bobrwhisper_audio_resample(&[_]f32{}, 0, 48000, 16000, &buffer),
    );
    try std.testing.expect(buffer.ptr == null);
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
    bobrwhisper_audio_buffer_free(buffer);
}

test "decode_wav round-trips and reports the source format" {
    const samples = [_]f32{ 0.0, 0.5, -0.5, 0.25 };
    const encoded = try audio.wav.encodePcm16(std.testing.allocator, &samples, 16000);
    defer std.testing.allocator.free(encoded);

    var buffer: Buffer = .empty;
    var info: WavInfo = undefined;
    try std.testing.expectEqual(
        Error.success,
        bobrwhisper_audio_decode_wav(encoded.ptr, encoded.len, 0, &buffer, &info),
    );
    defer bobrwhisper_audio_buffer_free(buffer);

    try std.testing.expectEqual(@as(u32, 16000), info.sample_rate);
    try std.testing.expectEqual(@as(u16, 1), info.channels);
    try std.testing.expectEqual(@as(usize, 4), buffer.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buffer.ptr.?[1], 0.001);
}

test "decode_wav rejects a non-wav and leaves the output empty" {
    var buffer: Buffer = .{ .ptr = @ptrFromInt(0xdeadbee0), .len = 7 };
    const junk = "definitely not a wav";
    try std.testing.expectEqual(
        Error.not_riff_wave,
        bobrwhisper_audio_decode_wav(junk.ptr, junk.len, 0, &buffer, null),
    );
    try std.testing.expect(buffer.ptr == null);
}

test "prepare_options_init stamps struct_size and a stale one is rejected" {
    var options: PrepareOptions = undefined;
    bobrwhisper_audio_prepare_options_init(&options);
    try std.testing.expectEqual(@sizeOf(PrepareOptions), options.struct_size);

    var samples = [_]f32{0.0} ** 100;
    var result: Prepared = undefined;
    options.struct_size -= 1;
    try std.testing.expectEqual(
        Error.invalid_argument,
        bobrwhisper_audio_prepare_for_asr(&samples, samples.len, &options, &result),
    );
}

test "prepare_for_asr accepts null options as defaults" {
    var samples = [_]f32{0.0} ** 32000;
    @memset(samples[16000..16800], 0.05);

    var result: Prepared = undefined;
    try std.testing.expectEqual(
        Error.success,
        bobrwhisper_audio_prepare_for_asr(&samples, samples.len, null, &result),
    );
    try std.testing.expect(result.gain > 1.0);
    try std.testing.expect(result.bounds.end > result.bounds.start);
}

test "chunker drives through the C surface" {
    var chunker: ?*audio.Chunker = null;
    try std.testing.expectEqual(Error.invalid_argument, bobrwhisper_audio_chunker_create(0, 0, &chunker));
    try std.testing.expectEqual(Error.invalid_argument, bobrwhisper_audio_chunker_create(4, 4, &chunker));
    try std.testing.expectEqual(Error.success, bobrwhisper_audio_chunker_create(4, 0, &chunker));
    defer bobrwhisper_audio_chunker_destroy(chunker);

    const samples = [_]f32{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expectEqual(Error.success, bobrwhisper_audio_chunker_push(chunker, &samples, samples.len));
    try std.testing.expectEqual(@as(usize, 1), bobrwhisper_audio_chunker_ready(chunker));

    var ptr: [*]const f32 = undefined;
    var len: usize = 0;
    try std.testing.expect(bobrwhisper_audio_chunker_next(chunker, &ptr, &len));
    try std.testing.expectEqual(@as(usize, 4), len);
    try std.testing.expectEqual(@as(f32, 1), ptr[0]);
    try std.testing.expect(!bobrwhisper_audio_chunker_next(chunker, &ptr, &len));

    try std.testing.expectEqual(@as(usize, 2), bobrwhisper_audio_chunker_flush(chunker, &ptr, &len));
}

test "to_asr_format converts 48 kHz stereo across the boundary" {
    const stereo = [_]f32{ 0.5, 0.5 } ** 480;
    var buffer: Buffer = .empty;
    try std.testing.expectEqual(
        Error.success,
        bobrwhisper_audio_to_asr_format(&stereo, stereo.len, 2, 48000, &buffer),
    );
    defer bobrwhisper_audio_buffer_free(buffer);
    try std.testing.expectEqual(@as(usize, 160), buffer.len);
    try std.testing.expectEqual(@as(u32, 16000), bobrwhisper_audio_asr_sample_rate());
}

test "to_asr_format rejects nonsense parameters" {
    const mono = [_]f32{ 0.1, 0.2 };
    var buffer: Buffer = .empty;
    try std.testing.expectEqual(
        Error.invalid_argument,
        bobrwhisper_audio_to_asr_format(&mono, mono.len, 0, 48000, &buffer),
    );
    try std.testing.expectEqual(
        Error.invalid_argument,
        bobrwhisper_audio_to_asr_format(&mono, mono.len, 1, 0, &buffer),
    );
}
