//! C ABI for the UI-independent libwhisper library.
//!
//! Invariants this file is responsible for, because C callers cannot be
//! trusted to hold them and cannot recover when they are violated:
//!
//!   * Every buffer handed out is NUL-terminated, so `printf("%s")` is safe.
//!     Zig's zero-length allocations return a non-null unmapped pointer, so an
//!     empty transcript must be reported as `ptr == NULL` rather than passed
//!     through.
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

const version = "0.1.0";

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
    language: ?[*:0]const u8,
    single_segment: bool,
};

const String = extern struct {
    ptr: ?[*:0]u8,
    len: usize,
};

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

pub export fn libwhisper_transcribe(
    transcriber: ?*Handle,
    samples: ?[*]const f32,
    sample_count: usize,
    options: ?*const TranscribeOptions,
    out_text: ?*String,
) Error {
    // Clear the output before anything else, so the documented "safe to inspect
    // after any return value" promise holds even for a rejected handle.
    const output = out_text orelse return .invalid_argument;
    output.* = .{ .ptr = null, .len = 0 };
    const handle = transcriber orelse return .invalid_argument;
    const sample_ptr = samples orelse return .invalid_argument;
    if (sample_count == 0) return .no_audio;
    if (sample_count > std.math.maxInt(i32)) return .invalid_argument;

    handle.cancel.store(false, .release);

    const result = if (options) |opts| blk: {
        const language = span(opts.language) orelse handle.adapter.language;
        break :blk if (opts.single_segment)
            handle.adapter.transcribeLive(sample_ptr[0..sample_count], language)
        else
            handle.adapter.transcribeWithLanguage(sample_ptr[0..sample_count], language);
    } else handle.adapter.transcribe(sample_ptr[0..sample_count]);

    const text = result catch |err| {
        // An aborted whisper_full() surfaces as a generic failure; the flag is
        // the only reliable way to tell cancellation from a real error.
        if (handle.cancel.load(.acquire)) return .cancelled;
        return mapError(err);
    };
    if (handle.cancel.load(.acquire)) {
        allocator.free(text);
        return .cancelled;
    }

    // A zero-length Zig allocation yields a non-null unmapped pointer, which a
    // C caller would happily dereference. Report empty transcripts as NULL.
    if (text.len == 0) {
        allocator.free(text);
        return .success;
    }

    // Grow by one for the NUL terminator; `libwhisper_string_free` frees
    // `len + 1` to match.
    const buf = allocator.realloc(text, text.len + 1) catch {
        allocator.free(text);
        return .out_of_memory;
    };
    buf[text.len] = 0;
    output.* = .{ .ptr = @ptrCast(buf.ptr), .len = text.len };
    return .success;
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

pub export fn libwhisper_string_free(string: String) void {
    const ptr = string.ptr orelse return;
    // Matches the `len + 1` allocation in `libwhisper_transcribe`. The struct
    // must be passed back exactly as it was received.
    allocator.free(ptr[0 .. string.len + 1]);
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

test "transcribe rejects bad arguments and always clears out_text" {
    var out: String = .{ .ptr = @ptrFromInt(0xdead), .len = 99 };
    try std.testing.expectEqual(Error.invalid_argument, libwhisper_transcribe(null, null, 0, null, &out));

    var handle: Handle = undefined;
    const samples = [_]f32{ 0.0, 0.1 };
    try std.testing.expectEqual(
        Error.invalid_argument,
        libwhisper_transcribe(&handle, null, samples.len, null, &out),
    );
    try std.testing.expect(out.ptr == null);
    try std.testing.expectEqual(@as(usize, 0), out.len);

    try std.testing.expectEqual(
        Error.no_audio,
        libwhisper_transcribe(&handle, &samples, 0, null, &out),
    );
}

test "error_string never faults on an unrecognized code" {
    // The reason `Error` is non-exhaustive: C hands us plain ints.
    const bogus: Error = @enumFromInt(42);
    try std.testing.expectEqualStrings("unrecognized error code", std.mem.span(libwhisper_error_string(bogus)));
    try std.testing.expectEqualStrings("no audio data", std.mem.span(libwhisper_error_string(.no_audio)));
    try std.testing.expectEqualStrings("cancelled", std.mem.span(libwhisper_error_string(.cancelled)));
}

test "string_free ignores a null buffer" {
    libwhisper_string_free(.{ .ptr = null, .len = 0 });
}

test "transcribe output round-trips through string_free" {
    // Mirrors what libwhisper_transcribe hands out: len bytes plus a NUL, freed
    // as len + 1. A mismatch here is a heap corruption bug in release builds.
    const text = try allocator.dupe(u8, "hello");
    const buf = try allocator.realloc(text, text.len + 1);
    buf[5] = 0;
    const string: String = .{ .ptr = @ptrCast(buf.ptr), .len = 5 };
    try std.testing.expectEqual(@as(u8, 0), string.ptr.?[string.len]);
    try std.testing.expectEqualStrings("hello", std.mem.span(string.ptr.?));
    libwhisper_string_free(string);
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
