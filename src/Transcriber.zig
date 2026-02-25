//! Whisper.cpp integration for speech-to-text

const std = @import("std");

const Transcriber = @This();
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("whisper.h");
});

allocator: std.mem.Allocator,
model_path: []const u8,
language: []const u8,
n_threads: u32,
ctx: ?*c.whisper_context = null,
// VAD config
vad_enabled: bool,
vad_model_path: ?[:0]const u8,
vad_threshold: f32,
vad_min_speech_ms: i32,
vad_min_silence_ms: i32,
vad_speech_pad_ms: i32,

pub const Config = struct {
    model_path: []const u8,
    language: []const u8 = "en",
    n_threads: u32 = 4,
    translate: bool = false,
    // VAD
    vad_enabled: bool = true,
    vad_model_path: ?[]const u8 = null,
    vad_threshold: f32 = 0.5,
    vad_min_speech_ms: i32 = 250,
    vad_min_silence_ms: i32 = 100,
    vad_speech_pad_ms: i32 = 30,
};

fn shouldUseGpu() bool {
    if (builtin.os.tag == .ios and builtin.abi == .simulator) {
        return false;
    }
    if (std.posix.getenv("GGML_METAL_DISABLE") != null) {
        return false;
    }
    return true;
}

fn nullLogCallback(_: c.ggml_log_level, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}

pub fn init(allocator: std.mem.Allocator, config: Config) !Transcriber {
    std.debug.assert(config.model_path.len > 0);
    std.debug.assert(config.language.len > 0);

    // Suppress whisper.cpp logs
    c.whisper_log_set(nullLogCallback, null);

    const model_path_z = try allocator.dupeZ(u8, config.model_path);
    defer allocator.free(model_path_z);

    std.fs.accessAbsolute(model_path_z, .{}) catch |err| {
        std.log.err("Model file not found: {s} - {}", .{ model_path_z, err });
        return error.ModelNotFound;
    };

    var cparams = c.whisper_context_default_params();
    cparams.use_gpu = shouldUseGpu();
    const ctx = c.whisper_init_from_file_with_params(model_path_z.ptr, cparams);
    if (ctx == null) {
        std.log.err("Failed to initialize whisper context", .{});
        return error.WhisperInitFailed;
    }
    std.debug.assert(ctx != null);

    return .{
        .allocator = allocator,
        .model_path = try allocator.dupe(u8, config.model_path),
        .language = try allocator.dupe(u8, config.language),
        .n_threads = config.n_threads,
        .ctx = ctx,
        .vad_enabled = config.vad_enabled,
        .vad_model_path = if (config.vad_model_path) |p| try allocator.dupeZ(u8, p) else null,
        .vad_threshold = config.vad_threshold,
        .vad_min_speech_ms = config.vad_min_speech_ms,
        .vad_min_silence_ms = config.vad_min_silence_ms,
        .vad_speech_pad_ms = config.vad_speech_pad_ms,
    };
}

pub fn deinit(self: *Transcriber) void {
    if (self.ctx) |ctx| {
        c.whisper_free(ctx);
    }
    self.allocator.free(self.model_path);
    self.allocator.free(self.language);
    if (self.vad_model_path) |p| {
        self.allocator.free(p);
    }
}

/// Transcribe audio samples (16kHz, mono, f32)
pub fn transcribe(self: *Transcriber, samples: []const f32) ![]u8 {
    return self.transcribeWithLanguage(samples, self.language);
}

/// Transcribe with language override
pub fn transcribeWithLanguage(self: *Transcriber, samples: []const f32, language: []const u8) ![]u8 {
    return self.transcribeInternal(samples, language, false);
}

/// Transcribe optimized for live/streaming: single segment, no cross-segment context.
pub fn transcribeLive(self: *Transcriber, samples: []const f32, language: []const u8) ![]u8 {
    return self.transcribeInternal(samples, language, true);
}

fn transcribeInternal(self: *Transcriber, samples: []const f32, language: []const u8, live: bool) ![]u8 {
    const ctx = self.ctx orelse return error.NoContext;

    if (samples.len == 0) {
        return error.NoAudioData;
    }

    var wparams = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
    wparams.print_realtime = false;
    wparams.print_progress = false;
    wparams.print_timestamps = false;
    wparams.print_special = false;
    wparams.translate = false;
    wparams.no_timestamps = true;
    wparams.n_threads = @intCast(self.n_threads);

    if (live) {
        wparams.single_segment = true;
        wparams.no_context = true;
    }

    // VAD configuration
    wparams.vad = self.vad_enabled;
    if (self.vad_model_path) |vad_path| {
        wparams.vad_model_path = vad_path.ptr;
    }
    wparams.vad_params.threshold = self.vad_threshold;
    wparams.vad_params.min_speech_duration_ms = self.vad_min_speech_ms;
    wparams.vad_params.min_silence_duration_ms = self.vad_min_silence_ms;
    wparams.vad_params.speech_pad_ms = self.vad_speech_pad_ms;

    var lang_buf: [8]u8 = undefined;
    @memset(&lang_buf, 0);
    const lang_len = @min(language.len, lang_buf.len - 1);
    @memcpy(lang_buf[0..lang_len], language[0..lang_len]);
    wparams.language = &lang_buf;

    const result = c.whisper_full(ctx, wparams, samples.ptr, @intCast(samples.len));
    if (result != 0) {
        std.log.err("whisper_full failed: {}", .{result});
        return error.TranscriptionFailed;
    }

    const n_segments = c.whisper_full_n_segments(ctx);
    if (n_segments == 0) {
        return try self.allocator.dupe(u8, "");
    }

    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(self.allocator);

    for (0..@as(usize, @intCast(n_segments))) |i| {
        const segment_text = c.whisper_full_get_segment_text(ctx, @intCast(i));
        if (segment_text != null) {
            const text_slice = std.mem.span(segment_text);
            try output.appendSlice(self.allocator, text_slice);
        }
    }

    return try output.toOwnedSlice(self.allocator);
}

/// Get detected language after transcription
pub fn getDetectedLanguage(self: *Transcriber) []const u8 {
    return self.language;
}

/// Check if model supports a language
pub fn supportsLanguage(language: []const u8) bool {
    for (getSupportedLanguages()) |lang| {
        if (std.mem.eql(u8, lang, language)) {
            return true;
        }
    }
    return false;
}

/// Get list of supported languages
pub fn getSupportedLanguages() []const []const u8 {
    return &.{
        "en", "zh", "de", "es",  "ru", "ko", "fr", "ja", "pt", "tr",
        "pl", "ca", "nl", "ar",  "sv", "it", "id", "hi", "fi", "vi",
        "he", "uk", "el", "ms",  "cs", "ro", "da", "hu", "ta", "no",
        "th", "ur", "hr", "bg",  "lt", "la", "mi", "ml", "cy", "sk",
        "te", "fa", "lv", "bn",  "sr", "az", "sl", "kn", "et", "mk",
        "br", "eu", "is", "hy",  "ne", "mn", "bs", "kk", "sq", "sw",
        "gl", "mr", "pa", "si",  "km", "sn", "yo", "so", "af", "oc",
        "ka", "be", "tg", "sd",  "gu", "am", "yi", "lo", "uz", "fo",
        "ht", "ps", "tk", "nn",  "mt", "sa", "lb", "my", "bo", "tl",
        "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su",
    };
}

pub const ModelInfo = struct {
    name: []const u8,
    size_mb: u32,
};

pub fn getModelInfo(self: *Transcriber) ModelInfo {
    _ = self;
    return .{ .name = "whisper", .size_mb = 0 };
}

test "supported languages" {
    const langs = getSupportedLanguages();
    try std.testing.expect(langs.len > 50);
    try std.testing.expectEqualStrings("en", langs[0]);
}

test "language support check" {
    try std.testing.expect(supportsLanguage("en"));
    try std.testing.expect(!supportsLanguage("xyz"));
}
