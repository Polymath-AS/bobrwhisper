//! Main application state

const std = @import("std");
const builtin = @import("builtin");
const c_api = @import("c_api.zig");
const Transcriber = @import("Transcriber.zig");
const AudioCapture = @import("audio/AudioCapture.zig");

const has_llm = builtin.os.tag == .macos;
const LlamaClient = if (has_llm) @import("llm/LlamaClient.zig") else void;

const App = @This();

allocator: std.mem.Allocator,
config: c_api.RuntimeConfig,
status: c_api.Status,

transcriber: ?Transcriber,
audio: ?AudioCapture,
llama: if (has_llm) ?LlamaClient else void,

// Live transcription state
live_thread: ?std.Thread = null,
live_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
last_transcribed_len: usize = 0,

pub fn init(allocator: std.mem.Allocator, config: c_api.RuntimeConfig) !App {
    return .{
        .allocator = allocator,
        .config = config,
        .status = .idle,
        .transcriber = null,
        .audio = null,
        .llama = if (has_llm) null else {},
    };
}

pub fn deinit(self: *App) void {
    self.stopLiveTranscription();
    if (self.transcriber) |*t| t.deinit();
    if (self.audio) |*a| a.deinit();
    if (has_llm) {
        if (self.llama) |*l| l.deinit();
    }
}

pub fn loadModel(self: *App, size: c_api.ModelSize) !void {
    const models_dir = self.config.getModelsDir();
    const model_name = size.toModelName();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ models_dir, model_name }) catch {
        self.notifyError("Model path too long");
        return error.PathTooLong;
    };

    std.fs.accessAbsolute(model_path, .{}) catch {
        std.log.err("Model not found: {s}", .{model_path});
        self.notifyError("Model not found. Please download it first.");
        return error.ModelNotFound;
    };

    std.log.info("Loading model: {s}", .{model_path});
    self.setStatus(.transcribing);

    const vad_path = self.config.getVadModelPath();
    self.transcriber = Transcriber.init(self.allocator, .{
        .model_path = model_path,
        .language = "en",
        .n_threads = 4,
        .vad_enabled = vad_path != null,
        .vad_model_path = vad_path,
    }) catch |err| {
        std.log.err("Failed to load model: {}", .{err});
        self.notifyError("Failed to load model");
        self.setStatus(.@"error");
        return err;
    };

    std.log.info("Model loaded successfully", .{});
    self.setStatus(.idle);
}

pub fn unloadModel(self: *App) void {
    if (self.transcriber) |*t| {
        t.deinit();
        self.transcriber = null;
    }
}

pub fn isModelLoaded(self: *App) bool {
    return self.transcriber != null;
}

pub fn modelExists(self: *App, size: c_api.ModelSize) bool {
    const models_dir = self.config.getModelsDir();
    const model_name = size.toModelName();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ models_dir, model_name }) catch {
        return false;
    };

    std.fs.accessAbsolute(model_path, .{}) catch {
        return false;
    };
    return true;
}

pub fn getModelPath(self: *App, size: c_api.ModelSize) !c_api.String {
    const models_dir = self.config.getModelsDir();
    const model_name = size.toModelName();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ models_dir, model_name }) catch {
        return error.PathTooLong;
    };

    const duped = try self.allocator.dupeZ(u8, model_path);
    return c_api.String.fromSlice(duped);
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

    const interval_ms: u64 = 1500; // Transcribe every 1.5 seconds
    const min_new_samples: usize = 8000; // At least 0.5s of new audio (16kHz)

    while (!self.live_stop.load(.seq_cst)) {
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);

        if (self.live_stop.load(.seq_cst)) break;

        const audio = self.audio orelse continue;
        const samples = audio.getSamples();

        // Only transcribe if we have enough new audio
        if (samples.len < self.last_transcribed_len + min_new_samples) continue;

        // Transcribe accumulated audio
        var transcriber = self.transcriber orelse continue;
        const text = transcriber.transcribeWithLanguage(samples, language) catch |err| {
            std.log.warn("Live transcription failed: {}", .{err});
            continue;
        };
        defer self.allocator.free(text);

        self.last_transcribed_len = samples.len;

        if (text.len > 0) {
            self.notifyTranscript(text, false); // is_final = false
        }
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

    // Do final transcription
    try self.transcribe(options);
}

pub fn isRecording(self: *App) bool {
    return self.status == .recording;
}

pub fn transcribe(self: *App, options: c_api.TranscribeOptions) !void {
    var transcriber = self.transcriber orelse {
        self.notifyError("No model loaded");
        return error.ModelNotLoaded;
    };

    const audio = self.audio orelse {
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

    const trimmed = try AudioCapture.trimSilence(self.allocator, samples, 0.001);
    defer self.allocator.free(trimmed);

    const raw_text = try transcriber.transcribeWithLanguage(trimmed, options.getLanguage());
    defer self.allocator.free(raw_text);

    std.log.info("Transcription complete, text length: {d}", .{raw_text.len});

    if (options.use_llm_formatting) {
        try self.formatText(raw_text, options.tone, self.config.on_transcript, self.config.userdata);
    } else {
        self.notifyTranscript(raw_text, true);
        self.setStatus(.ready);
    }
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

    if (self.llama == null) {
        self.llama = try LlamaClient.init(self.allocator, .{
            .model_path = self.config.getLlmModelPath(),
            .n_ctx = 512,
            .n_threads = 4,
        });
    }

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

fn buildFormattingPrompt(self: *App, input: []const u8, tone: c_api.Tone) ![]u8 {
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
