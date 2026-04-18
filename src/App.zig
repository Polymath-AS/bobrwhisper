//! Main application state

const std = @import("std");
const builtin = @import("builtin");
const asr = @import("asr");
const c_api = @import("c_api.zig");
const AudioCapture = @import("audio/AudioCapture.zig");
const SettingsStore = @import("SettingsStore.zig");
const LogStore = @import("LogStore.zig");

const has_llm = builtin.os.tag == .macos;
const LlamaClient = if (has_llm) @import("llm/LlamaClient.zig") else void;
const RuntimeAdapter = asr.RuntimeAdapter;
const RuntimeLoadConfig = asr.RuntimeLoadConfig;

const App = @This();

const llm_model_candidates = [_][]const u8{
    "llama-3.2-1b-q4_k_m.gguf",
    "llama-3.2-3b-q4_k_m.gguf",
    "qwen2.5-0.5b-instruct-q4_k_m.gguf",
    "qwen2.5-0.5b-q4_k_m.gguf",
    "qwen2.5-1.5b-instruct-q4_k_m.gguf",
    "qwen2.5-1.5b-q4_k_m.gguf",
    "llama-3.2-1b-q4.gguf",
};

allocator: std.mem.Allocator,
config: c_api.RuntimeConfig,
status: c_api.Status,

transcriber: ?RuntimeAdapter,
live_transcriber: ?RuntimeAdapter,
audio: ?AudioCapture,
llama: if (has_llm) ?LlamaClient else void,
log_store: LogStore,
custom_prompt: ?[]u8 = null,

// Live transcription state
live_thread: ?std.Thread = null,
live_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
last_transcribed_len: usize = 0,
frozen_transcript: std.ArrayListUnmanaged(u8) = .{},
frozen_sample_count: usize = 0,

pub fn init(allocator: std.mem.Allocator, config: c_api.RuntimeConfig) !App {
    const log_store = try LogStore.init(allocator, config.getModelsDir());
    return .{
        .allocator = allocator,
        .config = config,
        .status = .idle,
        .transcriber = null,
        .live_transcriber = null,
        .audio = null,
        .llama = if (has_llm) null else {},
        .log_store = log_store,
    };
}

pub fn deinit(self: *App) void {
    self.stopLiveTranscription();
    self.frozen_transcript.deinit(self.allocator);
    if (self.transcriber) |*t| t.deinit();
    if (self.live_transcriber) |*t| t.deinit();
    if (self.audio) |*a| a.deinit();
    if (has_llm) {
        if (self.llama) |*l| l.deinit();
    }
    if (self.custom_prompt) |cp| self.allocator.free(cp);
    self.log_store.deinit();
}

fn resolveModelDescriptorByID(model_id: []const u8) !asr.ModelDescriptor {
    return asr.ModelRegistry.findByID(model_id) orelse error.UnknownModel;
}

fn getModelPathForDescriptor(
    self: *App,
    descriptor: asr.ModelDescriptor,
    path_buf: *[std.fs.max_path_bytes]u8,
) ![:0]const u8 {
    const models_dir = self.config.getModelsDir();
    return std.fmt.bufPrintZ(path_buf, "{s}/{s}", .{ models_dir, descriptor.local_filename }) catch {
        self.notifyError("Model path too long");
        return error.PathTooLong;
    };
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch {
        return false;
    };
    return true;
}

fn resolveLlmModelPath(self: *App, path_buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    std.debug.assert(has_llm);

    const configured_path = self.config.getLlmModelPath();
    if (std.fs.path.isAbsolute(configured_path) and pathExists(configured_path)) {
        return configured_path;
    }

    const models_dir = self.config.getModelsDir();
    if (!std.fs.path.isAbsolute(models_dir)) {
        std.log.err("Models directory is not absolute: {s}", .{models_dir});
        self.notifyError("Models directory path is invalid.");
        return error.InvalidModelsDirectoryPath;
    }

    for (llm_model_candidates) |filename| {
        const candidate_path = std.fmt.bufPrint(path_buf, "{s}/{s}", .{ models_dir, filename }) catch {
            self.notifyError("LLM model path too long.");
            return error.PathTooLong;
        };
        if (pathExists(candidate_path)) {
            std.log.info("Using LLM model: {s}", .{candidate_path});
            return candidate_path;
        }
    }

    if (std.fs.path.isAbsolute(configured_path)) {
        std.log.warn("Configured LLM model not found: {s}", .{configured_path});
    } else {
        std.log.warn("Configured LLM model path is not absolute: {s}", .{configured_path});
    }
    self.notifyError("LLM model not found. Download a llama or qwen GGUF model.");
    return error.ModelNotFound;
}

fn ensureLlamaLoaded(self: *App) !void {
    if (!has_llm or self.llama != null) {
        return;
    }

    var llm_model_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const llm_model_path = try self.resolveLlmModelPath(&llm_model_path_buf);

    self.llama = LlamaClient.init(self.allocator, .{
        .model_path = llm_model_path,
        .n_ctx = 512,
        .n_threads = 4,
    }) catch |err| {
        std.log.err("Failed to load LLM model ({s}): {}", .{ llm_model_path, err });
        self.notifyError("Failed to load LLM model.");
        return err;
    };

    std.log.info("LLM model loaded: {s}", .{llm_model_path});
}

pub fn loadModelByID(self: *App, model_id: []const u8) !void {
    const descriptor = try resolveModelDescriptorByID(model_id);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = try self.getModelPathForDescriptor(descriptor, &path_buf);

    std.fs.accessAbsolute(model_path, .{}) catch {
        std.log.err("Model not found: {s}", .{model_path});
        self.notifyError("Model not found. Please download it first.");
        return error.ModelNotFound;
    };

    std.log.info("Loading model: {s}", .{model_path});
    self.setStatus(.transcribing);

    self.unloadModel();

    const vad_path = self.config.getVadModelPath();
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const n_threads: u32 = @intCast(@max(4, cpu_count / 2));
    const load_config = RuntimeLoadConfig{
        .model_path = model_path,
        .language = "en",
        .n_threads = n_threads,
        .vad_enabled = vad_path != null,
        .vad_model_path = vad_path,
    };

    self.transcriber = RuntimeAdapter.init(self.allocator, descriptor, load_config) catch |err| {
        std.log.err("Failed to load model: {}", .{err});
        self.notifyError("Failed to load model");
        self.setStatus(.@"error");
        return err;
    };

    if (asr.ModelRegistry.preferredLiveModel(descriptor)) |live_descriptor| {
        var live_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.getModelPathForDescriptor(live_descriptor, &live_path_buf)) |live_model_path| {
            if (std.fs.accessAbsolute(live_model_path, .{})) |_| {
                self.live_transcriber = RuntimeAdapter.init(self.allocator, live_descriptor, .{
                    .model_path = live_model_path,
                    .language = "en",
                    .n_threads = n_threads,
                    .vad_enabled = vad_path != null,
                    .vad_model_path = vad_path,
                }) catch |err| blk: {
                    std.log.info("Live model not available for faster transcription, using main model: {}", .{err});
                    break :blk null;
                };
            } else |_| {}
        } else |_| {}
    }

    std.log.info("Model loaded successfully", .{});
    self.setStatus(.idle);
}

pub fn loadModel(self: *App, size: c_api.ModelSize) !void {
    return self.loadModelByID(size.toModelID());
}

pub fn unloadModel(self: *App) void {
    if (self.live_transcriber) |*t| {
        t.deinit();
        self.live_transcriber = null;
    }
    if (self.transcriber) |*t| {
        t.deinit();
        self.transcriber = null;
    }
}

pub fn isModelLoaded(self: *App) bool {
    return self.transcriber != null;
}

pub fn modelExistsByID(self: *App, model_id: []const u8) bool {
    const descriptor = resolveModelDescriptorByID(model_id) catch return false;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = self.getModelPathForDescriptor(descriptor, &path_buf) catch return false;

    std.fs.accessAbsolute(model_path, .{}) catch {
        return false;
    };
    return true;
}

pub fn modelExists(self: *App, size: c_api.ModelSize) bool {
    return self.modelExistsByID(size.toModelID());
}

pub fn getModelPathByID(self: *App, model_id: []const u8) !c_api.String {
    const descriptor = try resolveModelDescriptorByID(model_id);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = try self.getModelPathForDescriptor(descriptor, &path_buf);

    const duped = try self.allocator.dupeZ(u8, model_path);
    return c_api.String.fromSlice(duped);
}

pub fn getModelPath(self: *App, size: c_api.ModelSize) !c_api.String {
    return self.getModelPathByID(size.toModelID());
}

pub fn startRecording(self: *App) !void {
    if (self.audio == null) {
        self.audio = try AudioCapture.init(self.allocator);
    }

    try self.audio.?.start();
    self.setStatus(.recording);
}

pub fn startRecordingWithLiveTranscription(self: *App, language: []const u8) !void {
    if (self.transcriber == null) {
        self.notifyError("No model loaded");
        return error.ModelNotLoaded;
    }

    if (self.audio == null) {
        self.audio = try AudioCapture.init(self.allocator);
    }

    // Reset state
    self.last_transcribed_len = 0;
    self.frozen_transcript.clearRetainingCapacity();
    self.frozen_sample_count = 0;
    self.live_stop.store(false, .seq_cst);

    try self.audio.?.start();
    self.setStatus(.recording);

    // Store language for the thread
    const lang_copy = try self.allocator.dupeZ(u8, language);

    // Start live transcription thread
    self.live_thread = try std.Thread.spawn(.{}, liveTranscriptionLoop, .{ self, lang_copy });
}

fn liveTranscriptionLoop(self: *App, language: [:0]const u8) void {
    defer self.allocator.free(language);

    const interval_ms: u64 = 200;
    const min_new_samples: usize = 8000; // At least 0.5s of new audio (16kHz)
    const chunk_duration: usize = 16000 * 5; // 5s per chunk

    while (!self.live_stop.load(.seq_cst)) {
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);

        if (self.live_stop.load(.seq_cst)) break;

        const audio: *AudioCapture = if (self.audio) |*a| a else continue;

        const total_samples = audio.getSampleCount();
        if (total_samples < self.last_transcribed_len + min_new_samples) continue;

        // Only copy unfrozen audio instead of the entire buffer
        const result = audio.copySamplesFrom(self.allocator, self.frozen_sample_count) catch continue;
        defer self.allocator.free(result.samples);
        const tail_samples = result.samples;

        var transcriber = if (self.transcriber) |*loaded_transcriber| loaded_transcriber else continue;

        // Finalize completed chunks: transcribe each once, freeze text
        var local_offset: usize = 0;
        while (tail_samples.len - local_offset > chunk_duration) {
            const chunk_end = local_offset + chunk_duration;
            const chunk_text = transcriber.transcribeWithLanguage(
                tail_samples[local_offset..chunk_end],
                language,
            ) catch |err| {
                std.log.warn("Chunk transcription failed: {}", .{err});
                break;
            };
            defer self.allocator.free(chunk_text);

            self.frozen_transcript.appendSlice(self.allocator, chunk_text) catch break;
            local_offset = chunk_end;
            self.frozen_sample_count += chunk_duration;
        }

        self.last_transcribed_len = result.total;

        // Transcribe only the trailing unfrozen audio with live-optimized params
        const tail = tail_samples[local_offset..];
        if (tail.len == 0) {
            if (self.frozen_transcript.items.len > 0) {
                self.notifyTranscript(self.frozen_transcript.items, false);
            }
            continue;
        }

        var live_t = if (self.live_transcriber) |*live_transcriber| live_transcriber else if (self.transcriber) |*loaded_transcriber| loaded_transcriber else continue;
        const tail_text = live_t.transcribeLive(tail, language) catch |err| {
            std.log.warn("Live transcription failed: {}", .{err});
            continue;
        };
        defer self.allocator.free(tail_text);

        // Temporarily extend frozen buffer with tail for combined notification
        const frozen_len = self.frozen_transcript.items.len;
        self.frozen_transcript.appendSlice(self.allocator, tail_text) catch continue;
        self.notifyTranscript(self.frozen_transcript.items, false);
        self.frozen_transcript.shrinkRetainingCapacity(frozen_len);
    }
}

pub fn stopLiveTranscription(self: *App) void {
    self.live_stop.store(true, .seq_cst);
    if (self.live_thread) |thread| {
        thread.join();
        self.live_thread = null;
    }
}

pub fn stopRecording(self: *App) void {
    if (self.audio) |*a| {
        a.stop();
    }
    self.setStatus(.idle);
}

pub fn stopRecordingAndTranscribe(self: *App, options: c_api.TranscribeOptions) !void {
    // Stop live transcription first
    self.stopLiveTranscription();

    if (self.audio) |*a| {
        a.stop();
    }

    // Reuse frozen transcript: only re-transcribe the unfrozen tail with full-quality params
    const has_frozen = self.frozen_transcript.items.len > 0;
    if (has_frozen) {
        try self.transcribeTail(options);
    } else {
        try self.transcribe(options);
    }
}

/// Transcribe only the unfrozen tail and combine with frozen transcript for the final result.
fn transcribeTail(self: *App, options: c_api.TranscribeOptions) !void {
    var transcriber = if (self.transcriber) |*loaded_transcriber| loaded_transcriber else {
        self.notifyError("No model loaded");
        return error.ModelNotLoaded;
    };

    const audio: *AudioCapture = if (self.audio) |*a| a else {
        self.notifyError("No audio recorded");
        return error.NoAudioData;
    };

    self.setStatus(.transcribing);

    const samples = audio.getSamples();
    if (samples.len == 0) {
        self.setStatus(.@"error");
        self.notifyError("No audio data recorded");
        return error.NoAudioData;
    }

    const tail = samples[self.frozen_sample_count..];

    if (tail.len > 0) {
        const bounds = AudioCapture.trimSilenceBounds(tail, 0.001);
        const trimmed = tail[bounds.start..bounds.end];
        const segment = if (trimmed.len > 0) trimmed else tail;

        const tail_text = try transcriber.transcribeWithLanguage(segment, options.getLanguage());
        defer self.allocator.free(tail_text);
        self.frozen_transcript.appendSlice(self.allocator, tail_text) catch {};
    }

    const final_text = try self.allocator.dupe(u8, self.frozen_transcript.items);
    defer self.allocator.free(final_text);

    std.log.info("Transcription complete, text length: {d}", .{final_text.len});

    try self.finalizeTranscript(final_text, options);
}

pub fn isRecording(self: *App) bool {
    return self.status == .recording;
}

pub fn transcribe(self: *App, options: c_api.TranscribeOptions) !void {
    var transcriber = if (self.transcriber) |*loaded_transcriber| loaded_transcriber else {
        self.notifyError("No model loaded");
        return error.ModelNotLoaded;
    };

    const audio: *AudioCapture = if (self.audio) |*a| a else {
        self.notifyError("No audio recorded");
        return error.NoAudioData;
    };

    self.setStatus(.transcribing);

    const samples = audio.getSamples();
    if (samples.len == 0) {
        self.setStatus(.@"error");
        self.notifyError("No audio data recorded");
        return error.NoAudioData;
    }

    const bounds = AudioCapture.trimSilenceBounds(samples, 0.001);
    const trimmed = samples[bounds.start..bounds.end];
    const segment = if (trimmed.len > 0) trimmed else samples;

    const raw_text = try transcriber.transcribeWithLanguage(segment, options.getLanguage());
    defer self.allocator.free(raw_text);

    std.log.info("Transcription complete, text length: {d}", .{raw_text.len});

    try self.finalizeTranscript(raw_text, options);
}

pub fn formatText(
    self: *App,
    input: []const u8,
    tone: c_api.Tone,
    callback: ?c_api.TranscriptCallback,
    userdata: ?*anyopaque,
) !void {
    if (!has_llm) {
        // On iOS, just return raw text (no LLM support yet)
        if (callback) |cb| {
            cb(userdata, c_api.String.fromSlice(input), true);
        }
        self.setStatus(.ready);
        return;
    }

    try self.ensureLlamaLoaded();

    self.setStatus(.formatting);

    const prompt = try self.buildFormattingPrompt(input, tone);
    defer self.allocator.free(prompt);

    const formatted = self.llama.?.generate(prompt, 256) catch |err| {
        std.log.warn("LLM formatting failed: {}, returning raw text", .{err});
        if (callback) |cb| {
            cb(userdata, c_api.String.fromSlice(input), true);
        }
        self.setStatus(.ready);
        return;
    };
    defer self.allocator.free(formatted);

    if (callback) |cb| {
        cb(userdata, c_api.String.fromSlice(formatted), true);
    }

    self.setStatus(.ready);
}

/// Shared finalization for transcribe() and transcribeTail().
/// Sends raw text as a preview, runs LLM formatting if enabled,
/// delivers the final result, and persists both texts to the log store.
fn finalizeTranscript(self: *App, raw_text: []const u8, options: c_api.TranscribeOptions) !void {
    if (!options.use_llm_formatting) {
        self.notifyTranscript(raw_text, true);
        self.log_store.appendTranscript(self.allocator, raw_text, null) catch |err| {
            std.log.warn("Failed to persist transcript: {}", .{err});
        };
        self.setStatus(.ready);
        return;
    }

    // Send raw text as a non-final preview so the UI shows something immediately
    self.notifyTranscript(raw_text, false);

    if (!has_llm) {
        // iOS: no LLM support yet, finalize with raw text
        self.notifyTranscript(raw_text, true);
        self.log_store.appendTranscript(self.allocator, raw_text, null) catch |err| {
            std.log.warn("Failed to persist transcript: {}", .{err});
        };
        self.setStatus(.ready);
        return;
    }

    try self.ensureLlamaLoaded();

    self.setStatus(.formatting);

    const prompt = try self.buildFormattingPrompt(raw_text, options.tone);
    defer self.allocator.free(prompt);

    var stream_context = LlmStreamContext{ .app = self };

    const formatted = self.llama.?.generateStreaming(
        prompt,
        256,
        onLlmFormattingPartial,
        &stream_context,
    ) catch |err| {
        std.log.warn("LLM formatting failed: {}, returning raw text", .{err});
        self.notifyTranscript(raw_text, true);
        self.log_store.appendTranscript(self.allocator, raw_text, null) catch {};
        self.setStatus(.ready);
        return;
    };
    defer self.allocator.free(formatted);

    self.notifyTranscript(formatted, true);
    self.log_store.appendTranscript(self.allocator, raw_text, formatted) catch |err| {
        std.log.warn("Failed to persist transcript: {}", .{err});
    };
    self.setStatus(.ready);
}

fn buildFormattingPrompt(self: *App, input: []const u8, tone: c_api.Tone) ![]u8 {
    if (self.custom_prompt) |cp| {
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}\n\nInput: {s}\n\nOutput:",
            .{ cp, input },
        );
    }

    const base_prompt =
        \\Clean up this transcribed speech. Remove filler words (um, uh, like, you know).
        \\Fix grammar and punctuation. Keep the meaning intact.{s}
        \\
        \\Input: {s}
        \\
        \\Output:
    ;

    return try std.fmt.allocPrint(
        self.allocator,
        base_prompt,
        .{ tone.toPromptSuffix(), input },
    );
}

pub fn getStatus(self: *App) c_api.Status {
    return self.status;
}

pub fn getAudioLevel(self: *App) f32 {
    const audio = if (self.audio) |*a| a else return 0;
    return audio.getAudioLevel();
}

pub fn writeSettings(self: *App, settings: c_api.Settings) !void {
    std.debug.assert(self.config.getConfigDomain().len > 0);
    try SettingsStore.write(self.config, settings);

    if (self.custom_prompt) |cp| {
        self.allocator.free(cp);
        self.custom_prompt = null;
    }
    if (settings.getCustomPrompt()) |prompt| {
        self.custom_prompt = try self.allocator.dupe(u8, prompt);
    }
}

pub fn clearTranscriptLog(self: *App) !void {
    try self.log_store.clear();
}

pub fn appendTranscriptLog(self: *App, transcript: []const u8, formatted_text: ?[]const u8) !void {
    try self.log_store.appendTranscript(self.allocator, transcript, formatted_text);
}

pub fn getTranscriptLogRecentJson(self: *App, limit: usize) !c_api.String {
    const entries = try self.log_store.readRecent(self.allocator, limit);
    defer LogStore.freeEntries(self.allocator, entries);

    var json_buffer: std.ArrayListUnmanaged(u8) = .{};
    errdefer json_buffer.deinit(self.allocator);

    try json_buffer.append(self.allocator, '[');
    for (entries, 0..) |entry, idx| {
        if (idx > 0) {
            try json_buffer.append(self.allocator, ',');
        }
        try json_buffer.append(self.allocator, '{');
        try json_buffer.appendSlice(self.allocator, "\"created_at_unix_ms\":");
        try json_buffer.writer(self.allocator).print("{d}", .{entry.created_at_unix_ms});
        try json_buffer.appendSlice(self.allocator, ",\"text\":");
        try appendJsonEscapedString(&json_buffer, self.allocator, entry.text);
        if (entry.formatted_text) |ft| {
            try json_buffer.appendSlice(self.allocator, ",\"formatted_text\":");
            try appendJsonEscapedString(&json_buffer, self.allocator, ft);
        }
        try json_buffer.append(self.allocator, '}');
    }
    try json_buffer.append(self.allocator, ']');

    const json_slice = try json_buffer.toOwnedSlice(self.allocator);
    return c_api.String.fromSlice(json_slice);
}

fn appendJsonEscapedString(
    buffer: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    try buffer.append(allocator, '"');
    for (text) |ch| {
        switch (ch) {
            '"' => try buffer.appendSlice(allocator, "\\\""),
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            '\n' => try buffer.appendSlice(allocator, "\\n"),
            '\r' => try buffer.appendSlice(allocator, "\\r"),
            '\t' => try buffer.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    try buffer.writer(allocator).print("\\u00{x:0>2}", .{ch});
                } else {
                    try buffer.append(allocator, ch);
                }
            },
        }
    }
    try buffer.append(allocator, '"');
}

const LlmStreamContext = struct {
    app: *App,
};

fn onLlmFormattingPartial(userdata: ?*anyopaque, partial_text: []const u8) void {
    if (partial_text.len == 0) {
        return;
    }
    const ptr = userdata orelse return;
    const context: *LlmStreamContext = @ptrCast(@alignCast(ptr));
    context.app.notifyTranscript(partial_text, false);
}

fn setStatus(self: *App, status: c_api.Status) void {
    self.status = status;
    if (self.config.on_status_change) |cb| {
        cb(self.config.userdata, status);
    }
}

fn notifyTranscript(self: *App, text: []const u8, is_final: bool) void {
    if (self.config.on_transcript) |cb| {
        cb(self.config.userdata, c_api.String.fromSlice(text), is_final);
    }
}

fn notifyError(self: *App, message: []const u8) void {
    if (self.config.on_error) |cb| {
        cb(self.config.userdata, c_api.String.fromSlice(message));
    }
    self.status = .@"error";
}
