//! whisper.cpp backend for the ASR runtime package

const std = @import("std");

const WhisperCppAdapter = @This();
const builtin = @import("builtin");
const bridge = @import("whisper_bridge.zig");

allocator: std.mem.Allocator,
model_path: []const u8,
language: []const u8,
n_threads: u32,
ctx: ?*bridge.Context = null,
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

pub fn init(allocator: std.mem.Allocator, config: Config) !WhisperCppAdapter {
    std.debug.assert(config.model_path.len > 0);
    std.debug.assert(config.language.len > 0);

    // Suppress whisper.cpp logs
    bridge.bobrwhisper_whisper_disable_logging();

    const model_path_z = try allocator.dupeZ(u8, config.model_path);
    defer allocator.free(model_path_z);

    std.fs.accessAbsolute(model_path_z, .{}) catch |err| {
        std.log.err("Model file not found: {s} - {}", .{ model_path_z, err });
        return error.ModelNotFound;
    };

    const ctx = bridge.bobrwhisper_whisper_init(model_path_z.ptr, shouldUseGpu());
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

pub fn deinit(self: *WhisperCppAdapter) void {
    if (self.ctx) |ctx| {
        bridge.bobrwhisper_whisper_free(ctx);
    }
    self.allocator.free(self.model_path);
    self.allocator.free(self.language);
    if (self.vad_model_path) |p| {
        self.allocator.free(p);
    }
}

/// Transcribe audio samples (16kHz, mono, f32)
pub fn transcribe(self: *WhisperCppAdapter, samples: []const f32) ![]u8 {
    return self.transcribeWithLanguage(samples, self.language);
}

/// Transcribe with language override
pub fn transcribeWithLanguage(self: *WhisperCppAdapter, samples: []const f32, language: []const u8) ![]u8 {
    return self.transcribeInternal(samples, language, false);
}

/// Transcribe optimized for live/streaming: single segment, no cross-segment context.
pub fn transcribeLive(self: *WhisperCppAdapter, samples: []const f32, language: []const u8) ![]u8 {
    return self.transcribeInternal(samples, language, true);
}

fn transcribeInternal(self: *WhisperCppAdapter, samples: []const f32, language: []const u8, live: bool) ![]u8 {
    const ctx = self.ctx orelse return error.NoContext;

    if (samples.len == 0) {
        return error.NoAudioData;
    }

    var lang_buf: [8:0]u8 = [_:0]u8{0} ** 8;
    const lang_len = @min(language.len, lang_buf.len - 1);
    @memcpy(lang_buf[0..lang_len], language[0..lang_len]);

    const result = bridge.bobrwhisper_whisper_transcribe(
        ctx,
        samples.ptr,
        @intCast(samples.len),
        lang_buf[0..].ptr,
        @intCast(self.n_threads),
        live,
        self.vad_enabled,
        if (self.vad_model_path) |vad_path| vad_path.ptr else null,
        self.vad_threshold,
        self.vad_min_speech_ms,
        self.vad_min_silence_ms,
        self.vad_speech_pad_ms,
    );
    if (result != 0) {
        std.log.err("whisper_full failed: {}", .{result});
        return error.TranscriptionFailed;
    }

    const n_segments = bridge.bobrwhisper_whisper_segment_count(ctx);
    if (n_segments == 0) {
        return try self.allocator.dupe(u8, "");
    }

    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(self.allocator);

    for (0..@as(usize, @intCast(n_segments))) |i| {
        const segment_text = bridge.bobrwhisper_whisper_segment_text(ctx, @intCast(i));
        if (segment_text) |text_ptr| {
            const text_slice = std.mem.span(text_ptr);
            try output.appendSlice(self.allocator, text_slice[0..text_slice.len]);
        }
    }

    return try output.toOwnedSlice(self.allocator);
}

/// Get detected language after transcription
pub fn getDetectedLanguage(self: *WhisperCppAdapter) []const u8 {
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

pub fn getModelInfo(self: *WhisperCppAdapter) ModelInfo {
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
