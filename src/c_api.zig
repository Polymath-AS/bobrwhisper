//! C ABI types matching include/bobrwhisper.h

const std = @import("std");
const asr = @import("asr");

pub const String = extern struct {
    ptr: ?[*]const u8,
    len: usize,

    pub fn fromSlice(slice: []const u8) String {
        return .{
            .ptr = slice.ptr,
            .len = slice.len,
        };
    }

    pub fn toSlice(self: String) []const u8 {
        const ptr = self.ptr orelse return "";
        return ptr[0..self.len];
    }

    pub fn deinit(self: String, alloc: std.mem.Allocator) void {
        const ptr = self.ptr orelse return;
        alloc.free(ptr[0..self.len]);
    }

    pub fn dupeAlloc(self: String, alloc: std.mem.Allocator) !String {
        const slice = self.toSlice();
        const duped = try alloc.dupe(u8, slice);
        return .{
            .ptr = duped.ptr,
            .len = duped.len,
        };
    }
};

pub const ModelRuntime = enum(c_int) {
    whisper_cpp = 0,
    coreml = 1,
    onnx = 2,
    server = 3,

    pub fn fromAsrRuntime(runtime: asr.ModelRuntime) ModelRuntime {
        return switch (runtime) {
            .whisper_cpp => .whisper_cpp,
            .coreml => .coreml,
            .onnx => .onnx,
            .server => .server,
        };
    }
};

pub const ModelCapabilities = u64;

pub const AudioDeviceDescriptor = extern struct {
    id: String,
    name: String,
    kind: String,
};

pub const ModelDescriptor = extern struct {
    id: ?[*:0]const u8,
    display_name: ?[*:0]const u8,
    family: ?[*:0]const u8,
    runtime: ModelRuntime,
    local_filename: ?[*:0]const u8,
    download_url: ?[*:0]const u8,
    size_bytes: u64,
    capabilities: ModelCapabilities,
    available_on_this_device: bool,

    pub fn fromAsrDescriptor(descriptor: asr.ModelDescriptor) ModelDescriptor {
        return .{
            .id = descriptor.id.ptr,
            .display_name = descriptor.display_name.ptr,
            .family = descriptor.family.ptr,
            .runtime = ModelRuntime.fromAsrRuntime(descriptor.runtime),
            .local_filename = descriptor.local_filename.ptr,
            .download_url = if (descriptor.download_url) |download_url| download_url.ptr else null,
            .size_bytes = descriptor.size_bytes,
            .capabilities = descriptor.capabilities,
            .available_on_this_device = descriptor.available_on_this_device,
        };
    }
};

pub const ModelSize = enum(c_int) {
    tiny = 0,
    base = 1,
    small = 2,
    medium = 3,
    large = 4,
    large_turbo = 5,

    pub fn toModelName(self: ModelSize) []const u8 {
        return switch (self) {
            .tiny => "ggml-tiny.bin",
            .base => "ggml-base.bin",
            .small => "ggml-small.bin",
            .medium => "ggml-medium.bin",
            .large => "ggml-large-v3.bin",
            .large_turbo => "ggml-large-v3-turbo.bin",
        };
    }

    pub fn estimatedSizeMB(self: ModelSize) u32 {
        return switch (self) {
            .tiny => 75,
            .base => 142,
            .small => 466,
            .medium => 1500,
            .large => 3100,
            .large_turbo => 809,
        };
    }

    pub fn toModelID(self: ModelSize) []const u8 {
        const descriptor = asr.ModelRegistry.findByLegacyStorageKey(@tagName(self)) orelse unreachable;
        return descriptor.id;
    }
};

pub const Status = enum(c_int) {
    idle = 0,
    recording = 1,
    transcribing = 2,
    formatting = 3,
    ready = 4,
    @"error" = 5,
};

pub const Tone = enum(c_int) {
    neutral = 0,
    formal = 1,
    casual = 2,
    code = 3,

    pub fn toPromptSuffix(self: Tone) []const u8 {
        return switch (self) {
            .neutral => "",
            .formal => " Use formal, professional language.",
            .casual => " Use casual, friendly language.",
            .code => " Format as code or technical documentation.",
        };
    }
};

pub const PostprocessMode = enum(c_int) {
    literal = 0,
    conservative = 1,
    polish = 2,
};

pub const TranscriptPhase = enum(c_int) {
    recognizing = 0,
    cleaning = 1,
    final = 2,
};

pub const RecordingContext = extern struct {
    bundle_id: ?[*:0]const u8,
    window_title: ?[*:0]const u8,
    text_before_cursor: ?[*:0]const u8,
    text_after_cursor: ?[*:0]const u8,
    selected_text: ?[*:0]const u8,
    is_secure: bool,

    pub fn span(value: ?[*:0]const u8) []const u8 {
        return if (value) |ptr| std.mem.span(ptr) else "";
    }
};

pub const TranscriptUpdate = extern struct {
    session_id: u64,
    revision: u64,
    stable_text: String,
    unstable_text: String,
    phase: TranscriptPhase,
};

pub const StatusCallback = *const fn (?*anyopaque, Status) callconv(.c) void;
pub const TranscriptCallback = *const fn (?*anyopaque, String, bool) callconv(.c) void;
pub const TranscriptUpdateCallback = *const fn (?*anyopaque, TranscriptUpdate) callconv(.c) void;
pub const ErrorCallback = *const fn (?*anyopaque, String) callconv(.c) void;
/// Non-fatal warning channel. Used by the App for stuck-mic, Bluetooth-mic,
/// and similar advisories that should NOT flip status to .error.
pub const WarningCallback = *const fn (?*anyopaque, String) callconv(.c) void;

pub const RuntimeConfig = extern struct {
    userdata: ?*anyopaque,

    on_status_change: ?StatusCallback,
    on_transcript: ?TranscriptCallback,
    on_error: ?ErrorCallback,
    on_warning: ?WarningCallback,

    models_dir: ?[*:0]const u8,
    config_path: ?[*:0]const u8,

    llm_model_path: ?[*:0]const u8,
    vad_model_path: ?[*:0]const u8,
    whisper_mode: bool,
    on_transcript_update: ?TranscriptUpdateCallback,

    pub fn getModelsDir(self: RuntimeConfig) []const u8 {
        if (self.models_dir) |ptr| {
            return std.mem.span(ptr);
        }
        return "~/.bobrwhisper/models";
    }

    pub fn getConfigDomain(self: RuntimeConfig) []const u8 {
        if (self.config_path) |ptr| {
            return std.mem.span(ptr);
        }
        return "com.uzaaft.BobrWhisper";
    }

    pub fn getLlmModelPath(self: RuntimeConfig) []const u8 {
        if (self.llm_model_path) |ptr| {
            return std.mem.span(ptr);
        }
        return "~/.bobrwhisper/models/llama-3.2-1b-q4.gguf";
    }

    pub fn getVadModelPath(self: RuntimeConfig) ?[]const u8 {
        if (self.vad_model_path) |ptr| {
            return std.mem.span(ptr);
        }
        return null;
    }
};

pub const RecordingOptions = extern struct {
    language: ?[*:0]const u8,
    postprocess_mode: PostprocessMode,
    tone: Tone,
    whisper_mode: bool,
    context: ?*const RecordingContext,

    pub fn getLanguage(self: RecordingOptions) []const u8 {
        return if (self.language) |ptr| std.mem.span(ptr) else "en";
    }
};

pub const Settings = extern struct {
    tone: Tone,
    remove_filler_words: bool,
    auto_punctuate: bool,
    use_llm_formatting: bool,
    custom_prompt: ?[*:0]const u8,
    whisper_mode: bool,

    pub fn getCustomPrompt(self: Settings) ?[]const u8 {
        if (self.custom_prompt) |ptr| {
            return std.mem.span(ptr);
        }
        return null;
    }
};

pub const TranscribeOptions = extern struct {
    language: ?[*:0]const u8,
    tone: Tone,
    remove_filler_words: bool,
    auto_punctuate: bool,
    use_llm_formatting: bool,
    whisper_mode: bool,

    pub fn getLanguage(self: TranscribeOptions) []const u8 {
        if (self.language) |ptr| {
            return std.mem.span(ptr);
        }
        return "en";
    }
};
