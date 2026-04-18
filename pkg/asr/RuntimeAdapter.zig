const std = @import("std");
const types = @import("types.zig");
const WhisperCppAdapter = @import("WhisperCppAdapter.zig");

pub const ModelDescriptor = types.ModelDescriptor;
pub const ModelCapability = types.ModelCapability;

pub const LoadConfig = struct {
    model_path: []const u8,
    language: []const u8 = "en",
    n_threads: u32 = 4,
    translate: bool = false,
    vad_enabled: bool = true,
    vad_model_path: ?[]const u8 = null,
    vad_threshold: f32 = 0.5,
    vad_min_speech_ms: i32 = 250,
    vad_min_silence_ms: i32 = 100,
    vad_speech_pad_ms: i32 = 30,
};

pub const RuntimeAdapter = union(enum) {
    whisper_cpp: WhisperCppAdapter,

    pub fn init(
        allocator: std.mem.Allocator,
        descriptor: ModelDescriptor,
        config: LoadConfig,
    ) !RuntimeAdapter {
        std.debug.assert(config.model_path.len > 0);

        return switch (descriptor.runtime) {
            .whisper_cpp => .{ .whisper_cpp = try WhisperCppAdapter.init(allocator, .{
                .model_path = config.model_path,
                .language = config.language,
                .n_threads = config.n_threads,
                .translate = config.translate,
                .vad_enabled = config.vad_enabled,
                .vad_model_path = config.vad_model_path,
                .vad_threshold = config.vad_threshold,
                .vad_min_speech_ms = config.vad_min_speech_ms,
                .vad_min_silence_ms = config.vad_min_silence_ms,
                .vad_speech_pad_ms = config.vad_speech_pad_ms,
            }) },
            else => error.UnsupportedRuntime,
        };
    }

    pub fn deinit(self: *RuntimeAdapter) void {
        switch (self.*) {
            inline else => |*adapter| adapter.deinit(),
        }
    }

    pub fn transcribe(self: *RuntimeAdapter, samples: []const f32) ![]u8 {
        return switch (self.*) {
            inline else => |*adapter| adapter.transcribe(samples),
        };
    }

    pub fn transcribeWithLanguage(
        self: *RuntimeAdapter,
        samples: []const f32,
        language: []const u8,
    ) ![]u8 {
        return switch (self.*) {
            inline else => |*adapter| adapter.transcribeWithLanguage(samples, language),
        };
    }

    pub fn transcribeLive(
        self: *RuntimeAdapter,
        samples: []const f32,
        language: []const u8,
    ) ![]u8 {
        return switch (self.*) {
            inline else => |*adapter| adapter.transcribeLive(samples, language),
        };
    }

    pub fn supports(self: RuntimeAdapter, capability: ModelCapability) bool {
        return switch (self) {
            .whisper_cpp => switch (capability) {
                .transcribe, .stream_partial => true,
                else => false,
            },
        };
    }
};
