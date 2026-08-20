//! C ABI for the UI-independent libwhisper library.
//!
//! Invariants this file is responsible for, because C callers cannot be
//! trusted to hold them and cannot recover when they are violated:
//!
//!   * Every buffer handed out is NUL-terminated, so `printf("%s")` is safe.
//!     Text always lives in a real allocation, sentinel included, so an empty
//!     transcript is `""` rather than the non-null unmapped pointer a
//!     zero-length Zig allocation would hand back.
//!   * A successful transcription always yields a result. Callers get one
//!     ownership rule and one release function, and never have to null-check
//!     before reading a transcript that happens to be empty.
//!   * Every value crossing the boundary is validated. `Error` is a
//!     non-exhaustive enum: a C caller can hand us any `int`, and switching on
//!     an out-of-range value would abort the embedder's process.
//!   * The library never writes to the embedder's stderr uninvited. std.log is
//!     routed to a caller-installed handler and dropped otherwise.

const std = @import("std");
const asr = @import("asr");

const allocator = std.heap.c_allocator;

/// Route std.log through `libwhisper_set_log_handler` instead of stderr. The
/// level stays at `.debug` so filtering is the embedder's decision; with no
/// handler installed `logFn` returns before doing any formatting work.
pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

const version = "0.2.0";

const Handle = struct {
    adapter: asr.WhisperCppAdapter,
    /// Polled by whisper.cpp's abort callback from the transcribing thread and
    /// set by `libwhisper_cancel` from any thread.
    cancel: std.atomic.Value(bool),
};

const Error = enum(c_int) {
    success = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    model_not_found = 3,
    model_load_failed = 4,
    no_audio = 5,
    transcription_failed = 6,
    cancelled = 7,
    unknown = 255,
    /// C callers can pass any `int`; keeping this open turns an out-of-range
    /// value into a defined result instead of `switch on corrupt value`.
    _,
};

const Config = extern struct {
    /// Must be `sizeof(libwhisper_config_s)`; set by `libwhisper_config_init`.
    /// Lets a future version detect a caller compiled against an older struct
    /// instead of reading past the end of it.
    struct_size: usize,
    model_path: ?[*:0]const u8,
    language: ?[*:0]const u8,
    thread_count: u32,
    use_gpu: bool,
    vad_enabled: bool,
    vad_model_path: ?[*:0]const u8,
    vad_threshold: f32,
    vad_min_speech_ms: i32,
    vad_min_silence_ms: i32,
    vad_speech_pad_ms: i32,
    initial_prompt: ?[*:0]const u8,
};

const TranscribeOptions = extern struct {
    /// Must be `sizeof(libwhisper_transcribe_options_s)`; set by
    /// `libwhisper_transcribe_options_init`.
    struct_size: usize,
    language: ?[*:0]const u8,
    single_segment: bool,
    timestamps: bool,
};

/// What `libwhisper_result_t` points at. Opaque to C, so the layout is ours to
/// change; `magic` is the only part a C caller can affect, and only by handing
/// us something that is not one of these.
const Result = struct {
    magic: u64,
    recognition: asr.Recognition,
};

/// "LWRSLT01". Turns the two mistakes a C caller actually makes — using a freed
/// result, or passing an unrelated pointer — into `invalid_argument` instead of
/// a walk through whatever the allocator has since put there. Best-effort by
/// nature: once the allocator reuses the block, nothing here can help.
const result_magic: u64 = 0x4c57_5253_4c54_3031;

const ResultSummary = extern struct {
    struct_size: usize,
    text_bytes: usize,
    segment_count: usize,
    language: ?[*:0]const u8,
    average_logprobability: f32,
    minimum_token_probability: f32,
    no_speech_probability: f32,
};

const Segment = extern struct {
    struct_size: usize,
    text_offset: usize,
    text_bytes: usize,
    start_ms: i64,
    end_ms: i64,
    average_logprobability: f32,
    no_speech_probability: f32,
};

/// A metric the model did not produce. NaN rather than zero: zero is a valid,
/// maximally-confident log probability, so a caller that forgets to check would
/// read "certain" out of "unknown". NaN at least fails every comparison.
const absent_metric: f32 = std.math.nan(f32);

/// Matches `LIBWHISPER_TIME_ABSENT`.
const absent_time: i64 = -1;

const LogHandler = *const fn (level: c_int, message: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void;

/// `std.Io.Mutex` needs an `Io` handle to block on, and a C ABI gives us nowhere
/// to get one. Both critical sections here are cold — loading a model takes
/// seconds, installing a log handler happens once — so spinning is cheaper than
/// inventing an event loop for the library to own.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

var log_lock: SpinLock = .{};
var log_handler: ?LogHandler = null;
var log_user_data: ?*anyopaque = null;

/// Model loading reaches the process-wide single-threaded `std.Io` instance via
/// the adapter's model-file check, so creation is serialized here. Transcribing
/// on distinct handles touches no shared state and stays lock-free, which is
/// the contract documented in libwhisper.h.
var create_lock: SpinLock = .{};

pub export fn libwhisper_config_init(config: ?*Config) void {
    const out = config orelse return;
    out.* = .{
        .struct_size = @sizeOf(Config),
        .model_path = null,
        .language = "en",
        .thread_count = 4,
        .use_gpu = true,
        .vad_enabled = false,
        .vad_model_path = null,
        .vad_threshold = 0.5,
        .vad_min_speech_ms = 250,
        .vad_min_silence_ms = 100,
        .vad_speech_pad_ms = 30,
        .initial_prompt = null,
    };
}

pub export fn libwhisper_create(config: ?*const Config, out_transcriber: ?*?*Handle) Error {
    const out = out_transcriber orelse return .invalid_argument;
    out.* = null;
    const cfg = config orelse return .invalid_argument;
    if (cfg.struct_size != @sizeOf(Config)) return .invalid_argument;
    const model_path = span(cfg.model_path) orelse return .invalid_argument;
    const language = span(cfg.language) orelse return .invalid_argument;
    if (cfg.thread_count == 0 or cfg.thread_count > std.math.maxInt(i32) or
        cfg.vad_threshold < 0 or cfg.vad_threshold > 1 or
        cfg.vad_min_speech_ms < 0 or cfg.vad_min_silence_ms < 0 or cfg.vad_speech_pad_ms < 0)
    {
        return .invalid_argument;
    }

    const handle = allocator.create(Handle) catch return .out_of_memory;

    create_lock.lock();
    const adapter = asr.WhisperCppAdapter.init(allocator, .{
        .model_path = model_path,
        .language = language,
        .n_threads = cfg.thread_count,
        .use_gpu = cfg.use_gpu,
        .vad_enabled = cfg.vad_enabled,
        .vad_model_path = span(cfg.vad_model_path),
        .vad_threshold = cfg.vad_threshold,
        .vad_min_speech_ms = cfg.vad_min_speech_ms,
        .vad_min_silence_ms = cfg.vad_min_silence_ms,
        .vad_speech_pad_ms = cfg.vad_speech_pad_ms,
        .initial_prompt = span(cfg.initial_prompt),
    });
    create_lock.unlock();

    // `errdefer` would be dead code here: this function returns a plain enum,
    // not an error union, so it never fires. Free explicitly.
    handle.* = .{
        .adapter = adapter catch |err| {
            allocator.destroy(handle);
            return mapError(err);
        },
        .cancel = .init(false),
    };
    handle.adapter.cancel_flag = &handle.cancel.raw;
    out.* = handle;
    return .success;
}

pub export fn libwhisper_destroy(transcriber: ?*Handle) void {
    const handle = transcriber orelse return;
    handle.adapter.deinit();
    allocator.destroy(handle);
}

pub export fn libwhisper_transcribe_options_init(options: ?*TranscribeOptions) void {
    const out = options orelse return;
    out.* = .{
        .struct_size = @sizeOf(TranscribeOptions),
        .language = null,
        .single_segment = false,
        .timestamps = false,
    };
}

pub export fn libwhisper_transcribe(
    transcriber: ?*Handle,
    samples: ?[*]const f32,
    sample_count: usize,
    options: ?*const TranscribeOptions,
    out_result: ?*?*Result,
) Error {
    // Clear the output before anything else, so the documented "safe to inspect
    // after any return value" promise holds even for a rejected handle.
    const out = out_result orelse return .invalid_argument;
    out.* = null;
    const handle = transcriber orelse return .invalid_argument;
    const sample_ptr = samples orelse return .invalid_argument;
    if (sample_count == 0) return .no_audio;
    if (sample_count > std.math.maxInt(i32)) return .invalid_argument;

    var decode: asr.WhisperCppAdapter.DecodeOptions = .{ .language = handle.adapter.language };
    if (options) |opts| {
        if (opts.struct_size != @sizeOf(TranscribeOptions)) return .invalid_argument;
        decode = .{
            .language = span(opts.language) orelse handle.adapter.language,
            .live = opts.single_segment,
            .timestamps = opts.timestamps,
        };
    }

    handle.cancel.store(false, .release);

    var recognition = handle.adapter.transcribeDetailed(sample_ptr[0..sample_count], decode) catch |err| {
        // An aborted whisper_full() surfaces as a generic failure; the flag is
        // the only reliable way to tell cancellation from a real error.
        if (handle.cancel.load(.acquire)) return .cancelled;
        return mapError(err);
    };

    // Cancelling mid-decode leaves whisper.cpp's segments truncated at wherever
    // it gave up, which reads as a complete transcript. Drop it: a partial
    // result the caller cannot distinguish from a whole one is worse than none.
    if (handle.cancel.load(.acquire)) {
        recognition.deinit();
        return .cancelled;
    }

    const result = allocator.create(Result) catch {
        recognition.deinit();
        return .out_of_memory;
    };
    result.* = .{ .magic = result_magic, .recognition = recognition };
    out.* = result;
    return .success;
}

/// Reject anything that is not one of our live results. See `result_magic`.
fn validate(result: ?*const Result) ?*const Result {
    const owned = result orelse return null;
    if (owned.magic != result_magic) return null;
    return owned;
}

pub export fn libwhisper_result_text(result: ?*const Result, out_bytes: ?*usize) ?[*:0]const u8 {
    if (out_bytes) |bytes| bytes.* = 0;
    const owned = validate(result) orelse return null;
    if (out_bytes) |bytes| bytes.* = owned.recognition.text.len;
    return owned.recognition.text.ptr;
}

pub export fn libwhisper_result_segment_count(result: ?*const Result) usize {
    const owned = validate(result) orelse return 0;
    return owned.recognition.segments.len;
}

pub export fn libwhisper_result_summary(result: ?*const Result, out_summary: ?*ResultSummary) Error {
    const out = out_summary orelse return .invalid_argument;
    if (out.struct_size != @sizeOf(ResultSummary)) return .invalid_argument;
    const owned = validate(result) orelse return .invalid_argument;

    const metrics = owned.recognition.metrics;
    out.* = .{
        .struct_size = @sizeOf(ResultSummary),
        .text_bytes = owned.recognition.text.len,
        .segment_count = owned.recognition.segments.len,
        .language = owned.recognition.language.ptr,
        .average_logprobability = metrics.average_log_probability orelse absent_metric,
        .minimum_token_probability = metrics.minimum_token_probability orelse absent_metric,
        .no_speech_probability = metrics.no_speech_probability orelse absent_metric,
    };
    return .success;
}

pub export fn libwhisper_result_segment(
    result: ?*const Result,
    index: usize,
    out_segment: ?*Segment,
) Error {
    const out = out_segment orelse return .invalid_argument;
    if (out.struct_size != @sizeOf(Segment)) return .invalid_argument;
    const owned = validate(result) orelse return .invalid_argument;
    if (index >= owned.recognition.segments.len) return .invalid_argument;

    const segment = owned.recognition.segments[index];
    out.* = .{
        .struct_size = @sizeOf(Segment),
        .text_offset = segment.text_range.offset,
        .text_bytes = segment.text_range.len,
        .start_ms = segment.start_ms orelse absent_time,
        .end_ms = segment.end_ms orelse absent_time,
        .average_logprobability = segment.average_log_probability orelse absent_metric,
        .no_speech_probability = segment.no_speech_probability orelse absent_metric,
    };
    return .success;
}

pub export fn libwhisper_result_free(result: ?*Result) void {
    const owned = result orelse return;
    if (owned.magic != result_magic) return;
    // Before the free, so a second call through the same pointer sees a stale
    // magic rather than re-freeing whatever is there now.
    owned.magic = 0;
    owned.recognition.deinit();
    allocator.destroy(owned);
}

/// Ask an in-flight `libwhisper_transcribe` to stop. Safe to call from another
/// thread. Cancellation is observed between whisper.cpp compute steps, so the
/// transcribe call returns shortly after, with `LIBWHISPER_ERROR_CANCELLED`.
pub export fn libwhisper_cancel(transcriber: ?*Handle) void {
    const handle = transcriber orelse return;
    handle.cancel.store(true, .release);
}

pub export fn libwhisper_set_initial_prompt(transcriber: ?*Handle, prompt: ?[*:0]const u8) Error {
    const handle = transcriber orelse return .invalid_argument;
    handle.adapter.setInitialPrompt(span(prompt)) catch |err| return mapError(err);
    return .success;
}

pub export fn libwhisper_set_log_handler(handler: ?LogHandler, user_data: ?*anyopaque) void {
    log_lock.lock();
    defer log_lock.unlock();
    log_handler = handler;
    log_user_data = user_data;
}

pub export fn libwhisper_error_string(err: Error) [*:0]const u8 {
    return switch (err) {
        .success => "success",
        .invalid_argument => "invalid argument",
        .out_of_memory => "out of memory",
        .model_not_found => "model not found",
        .model_load_failed => "model load failed",
        .no_audio => "no audio data",
        .transcription_failed => "transcription failed",
        .cancelled => "cancelled",
        .unknown => "unknown error",
        _ => "unrecognized error code",
    };
}

pub export fn libwhisper_version() [*:0]const u8 {
    return version;
}

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Copy the handler out and unlock before calling it, so a handler that
    // logs cannot deadlock against itself.
    log_lock.lock();
    const handler = log_handler;
    const user_data = log_user_data;
    log_lock.unlock();

    const callback = handler orelse return;
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    var buf: [1024]u8 = undefined;
    const message: [:0]const u8 = std.fmt.bufPrintZ(&buf, prefix ++ format, args) catch
        "libwhisper: log message too long to format";
    callback(@intFromEnum(level), message.ptr, user_data);
}

/// Treat NULL and "" alike: both mean "not provided". Callers that require a
/// value turn the resulting null into `invalid_argument`.
fn span(value: ?[*:0]const u8) ?[]const u8 {
    const ptr = value orelse return null;
    const result = std.mem.span(ptr);
    return if (result.len == 0) null else result;
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.ModelNotFound, error.FileNotFound => .model_not_found,
        error.WhisperInitFailed => .model_load_failed,
        error.NoAudioData => .no_audio,
        error.TranscriptionFailed, error.NoContext => .transcription_failed,
        else => .unknown,
    };
}

test "config_init fills defaults and stamps struct_size" {
    var config: Config = undefined;
    libwhisper_config_init(&config);
    try std.testing.expectEqual(@sizeOf(Config), config.struct_size);
    try std.testing.expect(config.model_path == null);
    try std.testing.expectEqual(@as(u32, 4), config.thread_count);
    try std.testing.expect(config.use_gpu);
}

test "config_init tolerates a null out pointer" {
    libwhisper_config_init(null);
}

test "create validates arguments" {
    var handle: ?*Handle = undefined;
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_create(null, &handle));
    try std.testing.expect(handle == null);

    // A caller compiled against a different struct layout must be rejected
    // rather than read past the end of its config.
    var stale: Config = undefined;
    libwhisper_config_init(&stale);
    stale.model_path = "/nonexistent/model.bin";
    stale.struct_size = @sizeOf(Config) - 1;
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_create(&stale, &handle));
    try std.testing.expect(handle == null);
}

test "create rejects an empty model path" {
    var config: Config = undefined;
    libwhisper_config_init(&config);
    config.model_path = "";
    var handle: ?*Handle = undefined;
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_create(&config, &handle));
    try std.testing.expect(handle == null);
}

// The missing-model path and the log handler are covered by
// examples/c-smoke/main.c instead of here: `std_options` only takes effect when
// this file is the compilation root, which it is for the shipped library but not
// under `zig test`, where the root is the test runner. Asserting on log routing
// here would test a code path that does not exist in the artifact.

test "transcribe rejects bad arguments and always clears out_result" {
    // Poisoned with a value aligned enough to be a valid `*Result`, so the test
    // proves out_result is cleared rather than that Zig rejected the literal.
    const poison: ?*Result = @ptrFromInt(0xdead_0000);
    var out: ?*Result = poison;
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_transcribe(null, null, 0, null, &out));
    try std.testing.expect(out == null);

    var handle: Handle = undefined;
    const samples = [_]f32{ 0.0, 0.1 };
    out = poison;
    try std.testing.expectEqual(
        Error.invalid_argument,
        libwhisper_transcribe(&handle, null, samples.len, null, &out),
    );
    try std.testing.expect(out == null);

    try std.testing.expectEqual(
        Error.no_audio,
        libwhisper_transcribe(&handle, &samples, 0, null, &out),
    );
    try std.testing.expect(out == null);

    // A caller compiled against a different options layout must be rejected
    // rather than have its struct read past the end.
    var stale: TranscribeOptions = undefined;
    libwhisper_transcribe_options_init(&stale);
    stale.struct_size = @sizeOf(TranscribeOptions) - 1;
    try std.testing.expectEqual(
        Error.invalid_argument,
        libwhisper_transcribe(&handle, &samples, samples.len, &stale, &out),
    );
    try std.testing.expect(out == null);
}

test "transcribe_options_init fills defaults and tolerates null" {
    var options: TranscribeOptions = undefined;
    libwhisper_transcribe_options_init(&options);
    try std.testing.expectEqual(@sizeOf(TranscribeOptions), options.struct_size);
    try std.testing.expect(options.language == null);
    try std.testing.expect(!options.single_segment);
    // Timestamps cost decode time and change the text, so they are opt-in.
    try std.testing.expect(!options.timestamps);
    libwhisper_transcribe_options_init(null);
}

/// Build a result the way `libwhisper_transcribe` does, without a model. Frees
/// with `libwhisper_result_free`, so the accessors are exercised against the
/// exact allocation the real path hands out.
fn testResult(text: []const u8, segments: []const asr.Recognition.Segment) !*Result {
    var builder: asr.Recognition.Builder = .init(allocator);
    errdefer builder.deinit();
    try builder.appendText(text);
    for (segments) |segment| {
        try builder.finishSegment(.{
            .start_ms = segment.start_ms,
            .end_ms = segment.end_ms,
            .no_speech_probability = segment.no_speech_probability,
        });
    }
    const result = try allocator.create(Result);
    result.* = .{ .magic = result_magic, .recognition = try builder.toOwned("en") };
    return result;
}

test "an empty transcript is still a readable result" {
    const result = try testResult("", &.{});
    defer libwhisper_result_free(result);

    var bytes: usize = 12345;
    const text = libwhisper_result_text(result, &bytes);
    // The point of the sentinel allocation: no null check before printf.
    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("", std.mem.span(text.?));
    try std.testing.expectEqual(@as(usize, 0), bytes);
    try std.testing.expectEqual(@as(usize, 0), libwhisper_result_segment_count(result));

    var summary: ResultSummary = undefined;
    summary.struct_size = @sizeOf(ResultSummary);
    try std.testing.expectEqual(Error.success, libwhisper_result_summary(result, &summary));
    // Absent, not zero — zero would read as a maximally confident transcript.
    try std.testing.expect(std.math.isNan(summary.average_logprobability));
    try std.testing.expect(std.math.isNan(summary.minimum_token_probability));
    try std.testing.expect(std.math.isNan(summary.no_speech_probability));
    try std.testing.expectEqualStrings("en", std.mem.span(summary.language.?));
}

test "segment access is bounded and reports absent timestamps" {
    const result = try testResult("abcdef", &.{
        .{
            .text_range = .{ .offset = 0, .len = 0 },
            .start_ms = null,
            .end_ms = null,
            .average_log_probability = null,
            .no_speech_probability = 0.25,
        },
    });
    defer libwhisper_result_free(result);

    var segment: Segment = undefined;
    segment.struct_size = @sizeOf(Segment);
    try std.testing.expectEqual(Error.success, libwhisper_result_segment(result, 0, &segment));
    try std.testing.expectEqual(@as(usize, 0), segment.text_offset);
    try std.testing.expectEqual(@as(usize, 6), segment.text_bytes);
    try std.testing.expectEqual(absent_time, segment.start_ms);
    try std.testing.expectEqual(absent_time, segment.end_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), segment.no_speech_probability, 1e-6);

    // One past the end is an error, not a read of adjacent memory.
    segment.struct_size = @sizeOf(Segment);
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_result_segment(result, 1, &segment));
    segment.struct_size = @sizeOf(Segment);
    try std.testing.expectEqual(
        Error.invalid_argument,
        libwhisper_result_segment(result, std.math.maxInt(usize), &segment),
    );

    // A stale out-struct is rejected before anything is written to it.
    var stale: Segment = undefined;
    stale.struct_size = @sizeOf(Segment) + 8;
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_result_segment(result, 0, &stale));
    try std.testing.expectEqual(@as(usize, @sizeOf(Segment) + 8), stale.struct_size);
}

test "result accessors reject a null or unrecognized handle" {
    try std.testing.expect(libwhisper_result_text(null, null) == null);
    try std.testing.expectEqual(@as(usize, 0), libwhisper_result_segment_count(null));

    var summary: ResultSummary = undefined;
    summary.struct_size = @sizeOf(ResultSummary);
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_result_summary(null, &summary));
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_result_summary(null, null));

    var segment: Segment = undefined;
    segment.struct_size = @sizeOf(Segment);
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_result_segment(null, 0, &segment));

    // Something that is not one of ours: caught by the magic, not dereferenced
    // as if it were a Result.
    var impostor: Result = .{ .magic = 0, .recognition = undefined };
    try std.testing.expect(libwhisper_result_text(&impostor, null) == null);
    try std.testing.expectEqual(@as(usize, 0), libwhisper_result_segment_count(&impostor));
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_result_summary(&impostor, &summary));
    // And a free that would otherwise deinit an undefined Recognition.
    libwhisper_result_free(&impostor);
}

test "result_free tolerates a null result" {
    libwhisper_result_free(null);
}

test "error_string never faults on an unrecognized code" {
    // The reason `Error` is non-exhaustive: C hands us plain ints.
    const bogus: Error = @enumFromInt(42);
    try std.testing.expectEqualStrings("unrecognized error code", std.mem.span(libwhisper_error_string(bogus)));
    try std.testing.expectEqualStrings("no audio data", std.mem.span(libwhisper_error_string(.no_audio)));
    try std.testing.expectEqualStrings("cancelled", std.mem.span(libwhisper_error_string(.cancelled)));
}

test "text and segment ranges address the same buffer" {
    const result = try testResult(" Hello", &.{});
    defer libwhisper_result_free(result);

    var bytes: usize = 0;
    const text = libwhisper_result_text(result, &bytes).?;
    try std.testing.expectEqual(@as(usize, 6), bytes);
    // NUL-terminated at len, which is what makes printf("%s") safe.
    try std.testing.expectEqual(@as(u8, 0), text[bytes]);
    try std.testing.expectEqualStrings(" Hello", text[0..bytes]);

    // out_bytes is optional.
    try std.testing.expect(libwhisper_result_text(result, null) != null);
}

test "version is reported" {
    try std.testing.expectEqualStrings(version, std.mem.span(libwhisper_version()));
}

test "cancel tolerates a null handle" {
    libwhisper_cancel(null);
}

test "log handler install and uninstall is safe" {
    const noop = struct {
        fn handler(level: c_int, message: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void {
            _ = .{ level, message, user_data };
        }
    }.handler;

    libwhisper_set_log_handler(noop, null);
    libwhisper_set_log_handler(null, null);
    try std.testing.expect(log_handler == null);
}

test "log levels match the values documented in libwhisper.h" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(std.log.Level.err));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(std.log.Level.warn));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(std.log.Level.info));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(std.log.Level.debug));
}
