//! Main application state

const std = @import("std");
const compat = @import("compat.zig");
const builtin = @import("builtin");
const asr = @import("asr");
const c_api = @import("c_api.zig");
const AudioCapture = @import("audio/AudioCapture.zig");
const AudioDevice = @import("audio/AudioDevice.zig");
const SettingsStore = @import("SettingsStore.zig");
const LogStore = @import("LogStore.zig");
const DictionaryStore = @import("DictionaryStore.zig");
const Sensibility = @import("Sensibility.zig");
const TranscriptSession = @import("TranscriptSession.zig");
const ContextPack = @import("ContextPack.zig");
const Postprocess = @import("Postprocess.zig");

const has_llm = builtin.os.tag == .macos;
const LlamaClient = if (has_llm) @import("llm/LlamaClient.zig") else void;
const RuntimeAdapter = asr.RuntimeAdapter;
const RuntimeLoadConfig = asr.RuntimeLoadConfig;

const App = @This();

const VadTuning = struct {
    threshold: f32,
    min_speech_ms: i32,
    min_silence_ms: i32,
    speech_pad_ms: i32,
};

const default_vad_tuning: VadTuning = .{
    .threshold = 0.5,
    // A word such as "I", "yes", or "no" can be comfortably shorter than
    // Silero's 250 ms default. Requiring that much speech drops the whole
    // utterance before Whisper gets a chance to decode it.
    .min_speech_ms = 100,
    .min_silence_ms = 100,
    .speech_pad_ms = 150,
};

const whisper_vad_tuning: VadTuning = .{
    .threshold = 0.3,
    .min_speech_ms = 100,
    .min_silence_ms = 200,
    .speech_pad_ms = 150,
};

const bluetooth_vad_tuning: VadTuning = .{
    .threshold = 0.25,
    .min_speech_ms = 100,
    .min_silence_ms = 300,
    .speech_pad_ms = 150,
};

const PreparedSegment = struct {
    samples: []const f32,
    bounds: AudioCapture.TrimBounds,
    threshold: f32,
    noise_floor: f32,
};

const ClauseCleanupTask = struct {
    app: *App,
    session_id: u64,
    input_revision: u64,
    source_text: []u8,
    tail_start: usize,
    prompt: []u8,
    mode: Postprocess.Mode,
};

const ClauseCleanupResult = struct {
    session_id: u64,
    input_revision: u64,
    source_text: []u8,
    cleaned_text: []u8,
};

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

const llm_model_candidates = [_][]const u8{
    "qwen2.5-0.5b-instruct-q4_k_m.gguf",
    "llama-3.2-1b-q4_k_m.gguf",
    "llama-3.2-3b-q4_k_m.gguf",
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
llm_model_path_override: ?[]u8 = null,
log_store: LogStore,
dictionary: DictionaryStore,
custom_prompt: ?[]u8 = null,
loaded_model_id: ?[:0]const u8 = null,
selected_input_device: ?[]u8 = null,
current_session: ?TranscriptSession = null,
next_session_id: u64 = 1,
session_language: ?[:0]u8 = null,
session_tone: c_api.Tone = .neutral,
session_whisper_mode: bool = false,

// Live transcription state
live_thread: ?std.Thread = null,
live_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
last_transcribed_len: usize = 0,
frozen_transcript: std.ArrayListUnmanaged(u8) = .empty,
frozen_sample_count: usize = 0,
last_live_hypothesis: std.ArrayListUnmanaged(u8) = .empty,
last_clause_cleanup_input: std.ArrayListUnmanaged(u8) = .empty,
cached_clause_source: std.ArrayListUnmanaged(u8) = .empty,
cached_clause_result: std.ArrayListUnmanaged(u8) = .empty,
clause_cleanup_thread: ?std.Thread = null,
clause_cleanup_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
clause_cleanup_mutex: SpinMutex = .{},
clause_cleanup_result: ?ClauseCleanupResult = null,
// Stuck-mic warning latch: ensures the user is told once per recording session
// when CoreAudio has been delivering bit-exact-zero audio for > 5 s. Reset on
// every fresh start of recording or live transcription.
stuck_mic_warned: bool = false,
// Bluetooth-mic warning latch: ensures the user is told at most once per
// process lifetime that the current input device is a Bluetooth mic
// (typically AirPods), which adds latency and degrades accuracy versus the
// built-in mic.
bluetooth_mic_warned: bool = false,

/// Number of consecutive zero samples that triggers the stuck-mic warning.
/// 5 s at 16 kHz.
const stuck_mic_threshold_samples: usize = 16000 * 5;

pub fn init(allocator: std.mem.Allocator, config: c_api.RuntimeConfig) !App {
    const log_store = try LogStore.init(allocator, config.getModelsDir());
    // Best-effort load: missing dictionary.txt is normal and yields an empty
    // store. We rebuild from disk on every recording start so users can edit
    // the file between sessions without restarting the app.
    const dictionary = try DictionaryStore.loadFromModelsDir(allocator, config.getModelsDir());
    return .{
        .allocator = allocator,
        .config = config,
        .status = .idle,
        .transcriber = null,
        .live_transcriber = null,
        .audio = null,
        .llama = if (has_llm) null else {},
        .log_store = log_store,
        .dictionary = dictionary,
    };
}

pub fn deinit(self: *App) void {
    self.stopLiveTranscription();
    self.frozen_transcript.deinit(self.allocator);
    self.last_live_hypothesis.deinit(self.allocator);
    self.last_clause_cleanup_input.deinit(self.allocator);
    self.cached_clause_source.deinit(self.allocator);
    self.cached_clause_result.deinit(self.allocator);
    if (self.clause_cleanup_result) |result| {
        self.allocator.free(result.source_text);
        self.allocator.free(result.cleaned_text);
    }
    if (self.current_session) |*session| session.deinit();
    if (self.session_language) |language| self.allocator.free(language);
    if (self.transcriber) |*t| t.deinit();
    if (self.live_transcriber) |*t| t.deinit();
    if (self.audio) |*a| a.deinit();
    if (self.selected_input_device) |device_id| self.allocator.free(device_id);
    if (has_llm) {
        if (self.llama) |*l| l.deinit();
    }
    if (self.llm_model_path_override) |path| self.allocator.free(path);
    if (self.custom_prompt) |cp| self.allocator.free(cp);
    if (self.loaded_model_id) |id| self.allocator.free(id);
    self.dictionary.deinit();
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
    compat.accessAbsolute(path) catch {
        return false;
    };
    return true;
}

fn vadTuningForWhisperMode(enabled: bool) VadTuning {
    return if (enabled) whisper_vad_tuning else default_vad_tuning;
}

fn makeLoadConfig(model_path: []const u8, n_threads: u32, vad_path: ?[]const u8, tuning: VadTuning) RuntimeLoadConfig {
    return .{
        .model_path = model_path,
        .language = "en",
        .n_threads = n_threads,
        .vad_enabled = vad_path != null,
        .vad_model_path = vad_path,
        .vad_threshold = tuning.threshold,
        .vad_min_speech_ms = tuning.min_speech_ms,
        .vad_min_silence_ms = tuning.min_silence_ms,
        .vad_speech_pad_ms = tuning.speech_pad_ms,
    };
}

fn prepareSegment(samples: []const f32) PreparedSegment {
    std.debug.assert(samples.len > 0);
    const noise_floor = AudioCapture.computeNoiseFloor(samples);
    const threshold = @max(noise_floor * 3.0, 0.0005);
    const bounds = AudioCapture.trimSilenceBounds(samples, threshold);
    const trimmed = samples[bounds.start..bounds.end];
    return .{
        .samples = if (trimmed.len > 0) trimmed else samples,
        .bounds = bounds,
        .threshold = threshold,
        .noise_floor = noise_floor,
    };
}

fn appendDeduplicated(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, next_raw: []const u8) !void {
    const next = std.mem.trim(u8, next_raw, " \t\r\n");
    if (next.len == 0) return;
    if (buffer.items.len == 0) {
        try buffer.appendSlice(allocator, next);
        return;
    }

    // Compare word spans rather than byte windows. A byte window aligns
    // " bar" against "bar " and therefore misses the normal Whisper overlap.
    const WordSpan = struct { start: usize, end: usize };
    var suffix_words: [16]WordSpan = undefined;
    var suffix_count: usize = 0;
    var cursor = buffer.items.len;
    while (cursor > 0 and suffix_count < suffix_words.len) {
        while (cursor > 0 and std.ascii.isWhitespace(buffer.items[cursor - 1])) cursor -= 1;
        if (cursor == 0) break;
        const end = cursor;
        while (cursor > 0 and !std.ascii.isWhitespace(buffer.items[cursor - 1])) cursor -= 1;
        suffix_words[suffix_count] = .{ .start = cursor, .end = end };
        suffix_count += 1;
    }

    var prefix_words: [16]WordSpan = undefined;
    var prefix_count: usize = 0;
    cursor = 0;
    while (cursor < next.len and prefix_count < prefix_words.len) {
        while (cursor < next.len and std.ascii.isWhitespace(next[cursor])) cursor += 1;
        if (cursor == next.len) break;
        const start = cursor;
        while (cursor < next.len and !std.ascii.isWhitespace(next[cursor])) cursor += 1;
        prefix_words[prefix_count] = .{ .start = start, .end = cursor };
        prefix_count += 1;
    }

    var best_words: usize = 0;
    const max_words = @min(suffix_count, prefix_count);
    var count: usize = 1;
    while (count <= max_words) : (count += 1) {
        var matches = true;
        for (0..count) |word_index| {
            const suffix = suffix_words[count - word_index - 1];
            const prefix = prefix_words[word_index];
            if (!wordsEqual(
                buffer.items[suffix.start..suffix.end],
                next[prefix.start..prefix.end],
            )) {
                matches = false;
                break;
            }
        }
        if (matches) best_words = count;
    }

    var append_start: usize = 0;
    if (best_words != 0) {
        append_start = prefix_words[best_words - 1].end;
        while (append_start < next.len and std.ascii.isWhitespace(next[append_start])) append_start += 1;
    }
    if (append_start == next.len) return;
    if (buffer.items[buffer.items.len - 1] != ' ') try buffer.append(allocator, ' ');
    try buffer.appendSlice(allocator, next[append_start..]);
}

fn wordsEqual(left_raw: []const u8, right_raw: []const u8) bool {
    const punctuation = ",.;:!?()[]{}<>\"'`—";
    const left = std.mem.trim(u8, left_raw, punctuation);
    const right = std.mem.trim(u8, right_raw, punctuation);
    return left.len != 0 and std.ascii.eqlIgnoreCase(left, right);
}

test "overlap stitching deduplicates word suffixes with punctuation changes" {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "Please schedule the meeting for Friday.");
    try appendDeduplicated(&text, std.testing.allocator, "for Friday, at noon");
    try std.testing.expectEqualStrings(
        "Please schedule the meeting for Friday. at noon",
        text.items,
    );
}

fn resolveLlmModelPath(self: *App, path_buf: *[std.fs.max_path_bytes]u8, report_errors: bool) ![]const u8 {
    std.debug.assert(has_llm);

    const configured_path = self.llm_model_path_override orelse self.config.getLlmModelPath();
    if (std.fs.path.isAbsolute(configured_path) and pathExists(configured_path)) {
        return configured_path;
    }
    if (std.mem.startsWith(u8, configured_path, "~/")) {
        if (compat.getenv("HOME")) |home| {
            const expanded = std.fmt.bufPrint(path_buf, "{s}/{s}", .{ home, configured_path[2..] }) catch {
                if (report_errors) self.notifyError("LLM model path too long.");
                return error.PathTooLong;
            };
            if (pathExists(expanded)) return expanded;
        }
    }

    const models_dir = self.config.getModelsDir();
    if (!std.fs.path.isAbsolute(models_dir)) {
        std.log.err("Models directory is not absolute: {s}", .{models_dir});
        if (report_errors) self.notifyError("Models directory path is invalid.");
        return error.InvalidModelsDirectoryPath;
    }

    for (llm_model_candidates) |filename| {
        const candidate_path = std.fmt.bufPrint(path_buf, "{s}/{s}", .{ models_dir, filename }) catch {
            if (report_errors) self.notifyError("LLM model path too long.");
            return error.PathTooLong;
        };
        if (pathExists(candidate_path)) {
            std.log.info("Using LLM model: {s}", .{candidate_path});
            return candidate_path;
        }
    }

    if (report_errors) {
        if (std.fs.path.isAbsolute(configured_path) or std.mem.startsWith(u8, configured_path, "~/")) {
            std.log.warn("Configured LLM model not found: {s}", .{configured_path});
        } else {
            std.log.warn("Configured LLM model path is not absolute: {s}", .{configured_path});
        }
    }
    if (report_errors) self.notifyError("LLM model not found. Download a llama or qwen GGUF model.");
    return error.ModelNotFound;
}

/// Select the local GGUF used for subsequent cleanup. The path is copied so
/// platform adapters may release their temporary C string after this call.
/// Replacing a loaded model is only permitted between recording sessions.
pub fn setLlmModelPath(self: *App, model_path: []const u8) !void {
    if (self.current_session != null or self.live_thread != null) return error.Busy;
    if (!std.fs.path.isAbsolute(model_path) or !pathExists(model_path)) return error.ModelNotFound;

    const owned_path = try self.allocator.dupe(u8, model_path);
    errdefer self.allocator.free(owned_path);

    if (has_llm) {
        if (self.llama) |*llama| llama.deinit();
        self.llama = null;
    }
    if (self.llm_model_path_override) |old_path| self.allocator.free(old_path);
    self.llm_model_path_override = owned_path;
    std.log.info("Selected LLM model: {s}", .{model_path});
}

fn ensureLlamaLoaded(self: *App, report_errors: bool) !void {
    if (!has_llm or self.llama != null) {
        return;
    }

    var llm_model_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const llm_model_path = try self.resolveLlmModelPath(&llm_model_path_buf, report_errors);

    self.llama = LlamaClient.init(self.allocator, .{
        .model_path = llm_model_path,
        .n_ctx = 512,
        .n_threads = 4,
    }) catch |err| {
        std.log.err("Failed to load LLM model ({s}): {}", .{ llm_model_path, err });
        if (report_errors) self.notifyError("Failed to load LLM model.");
        return err;
    };

    std.log.info("LLM model loaded: {s}", .{llm_model_path});
}

pub fn loadModelByID(self: *App, model_id: []const u8) !void {
    const descriptor = try resolveModelDescriptorByID(model_id);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = try self.getModelPathForDescriptor(descriptor, &path_buf);

    compat.accessAbsolute(model_path) catch {
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
    const load_config = makeLoadConfig(
        model_path,
        n_threads,
        vad_path,
        vadTuningForWhisperMode(self.config.whisper_mode),
    );

    self.transcriber = RuntimeAdapter.init(self.allocator, descriptor, load_config) catch |err| {
        std.log.err("Failed to load model: {}", .{err});
        self.notifyError("Failed to load model");
        self.setStatus(.@"error");
        return err;
    };

    if (self.loaded_model_id) |old_id| self.allocator.free(old_id);
    self.loaded_model_id = self.allocator.dupeZ(u8, descriptor.id) catch null;

    if (asr.ModelRegistry.preferredLiveModel(descriptor)) |live_descriptor| {
        var live_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.getModelPathForDescriptor(live_descriptor, &live_path_buf)) |live_model_path| {
            if (compat.accessAbsolute(live_model_path)) |_| {
                self.live_transcriber = RuntimeAdapter.init(self.allocator, live_descriptor, makeLoadConfig(
                    live_model_path,
                    n_threads,
                    vad_path,
                    vadTuningForWhisperMode(self.config.whisper_mode),
                )) catch |err| blk: {
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
    if (self.loaded_model_id) |id| {
        self.allocator.free(id);
        self.loaded_model_id = null;
    }
}

pub fn isModelLoaded(self: *App) bool {
    return self.transcriber != null;
}

pub fn modelExistsByID(self: *App, model_id: []const u8) bool {
    const descriptor = resolveModelDescriptorByID(model_id) catch return false;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const model_path = self.getModelPathForDescriptor(descriptor, &path_buf) catch return false;

    compat.accessAbsolute(model_path) catch {
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

pub fn inputDeviceCount(self: *App) usize {
    const devices = AudioDevice.listInputDevices(self.allocator) catch return 0;
    AudioDevice.freeList(self.allocator, devices);
    return devices.len;
}

pub fn inputDeviceAt(self: *App, index: usize) ?AudioDevice.Info {
    const devices = AudioDevice.listInputDevices(self.allocator) catch return null;
    if (index >= devices.len) {
        AudioDevice.freeList(self.allocator, devices);
        return null;
    }
    const selected = devices[index];
    const name = self.allocator.dupe(u8, selected.name) catch {
        AudioDevice.freeList(self.allocator, devices);
        return null;
    };
    const id = self.allocator.dupe(u8, selected.id) catch {
        self.allocator.free(name);
        AudioDevice.freeList(self.allocator, devices);
        return null;
    };
    const copy = AudioDevice.Info{
        .name = name,
        .id = id,
        .kind = selected.kind,
    };
    AudioDevice.freeList(self.allocator, devices);
    return copy;
}

pub fn setInputDevice(self: *App, device_id: []const u8) !void {
    if (self.isRecording()) return error.RecordingInProgress;
    const copy = if (device_id.len == 0)
        null
    else
        try self.allocator.dupe(u8, device_id);
    if (self.selected_input_device) |old| self.allocator.free(old);
    self.selected_input_device = copy;
    if (self.audio) |*audio| {
        audio.device_uid = self.selected_input_device;
        audio.device_name = self.selected_input_device;
    }
}

pub fn startRecording(self: *App) !void {
    if (self.audio == null) {
        self.audio = try AudioCapture.initWithConfig(self.allocator, .{
            .device_uid = self.selected_input_device,
            .device_name = self.selected_input_device,
        });
    }

    self.stuck_mic_warned = false;
    self.checkInputDevice();
    self.refreshDictionaryPrompt(null);
    try self.audio.?.start();
    self.reportInputFallback();
    self.setStatus(.recording);
}

pub fn startRecordingSession(self: *App, options: c_api.RecordingOptions) !u64 {
    if (self.current_session != null or self.live_thread != null) return error.RecordingInProgress;
    if (self.audio) |*audio| if (audio.isRecording()) return error.RecordingInProgress;

    const context_value = options.context orelse &c_api.RecordingContext{
        .bundle_id = null,
        .window_title = null,
        .text_before_cursor = null,
        .text_after_cursor = null,
        .selected_text = null,
        .is_secure = false,
    };
    const input: ContextPack.Input = if (context_value.is_secure) .{} else .{
        .bundle_id = c_api.RecordingContext.span(context_value.bundle_id),
        .window_title = c_api.RecordingContext.span(context_value.window_title),
        .text_before_cursor = c_api.RecordingContext.span(context_value.text_before_cursor),
        .text_after_cursor = c_api.RecordingContext.span(context_value.text_after_cursor),
        .selected_text = c_api.RecordingContext.span(context_value.selected_text),
    };
    const id = self.next_session_id;
    self.next_session_id +%= 1;
    if (self.next_session_id == 0) self.next_session_id = 1;
    self.current_session = try TranscriptSession.init(
        self.allocator,
        id,
        @enumFromInt(@intFromEnum(options.postprocess_mode)),
        input,
    );
    errdefer {
        self.current_session.?.deinit();
        self.current_session = null;
    }
    self.session_language = try self.allocator.dupeZ(u8, options.getLanguage());
    errdefer {
        if (self.session_language) |language| self.allocator.free(language);
        self.session_language = null;
    }
    self.session_tone = options.tone;
    self.session_whisper_mode = options.whisper_mode;

    self.startRecordingWithLiveTranscription(options.getLanguage()) catch |err| {
        if (self.audio) |*audio| audio.stop();
        self.setStatus(.idle);
        return err;
    };
    return id;
}

pub fn startRecordingWithLiveTranscription(self: *App, language: []const u8) !void {
    if (self.live_thread != null) return error.RecordingInProgress;
    if (self.audio) |*audio| if (audio.isRecording()) return error.RecordingInProgress;
    if (self.transcriber == null) {
        self.notifyError("No model loaded");
        return error.ModelNotLoaded;
    }

    if (self.audio == null) {
        self.audio = try AudioCapture.initWithConfig(self.allocator, .{
            .device_uid = self.selected_input_device,
            .device_name = self.selected_input_device,
        });
    }

    // Reset state
    self.last_transcribed_len = 0;
    self.frozen_transcript.clearRetainingCapacity();
    self.frozen_sample_count = 0;
    self.last_live_hypothesis.clearRetainingCapacity();
    self.last_clause_cleanup_input.clearRetainingCapacity();
    self.cached_clause_source.clearRetainingCapacity();
    self.cached_clause_result.clearRetainingCapacity();
    self.stuck_mic_warned = false;
    self.live_stop.store(false, .seq_cst);

    self.checkInputDevice();
    const context = if (self.current_session) |*session| &session.context else null;
    self.refreshDictionaryPrompt(context);
    try self.audio.?.start();
    self.reportInputFallback();
    self.setStatus(.recording);

    // Store language for the thread
    const lang_copy = try self.allocator.dupeZ(u8, language);

    // Start live transcription thread
    self.live_thread = try std.Thread.spawn(.{}, liveTranscriptionLoop, .{ self, lang_copy });
}

fn reportInputFallback(self: *App) void {
    const audio = if (self.audio) |*value| value else return;
    if (!audio.didFallbackToDefaultDevice()) return;
    self.notifyWarning("Selected microphone was unavailable. Using the system default input.");
}

fn rememberLiveHypothesis(self: *App, text: []const u8) !bool {
    const repeated = std.mem.eql(u8, self.last_live_hypothesis.items, text);
    self.last_live_hypothesis.clearRetainingCapacity();
    try self.last_live_hypothesis.appendSlice(self.allocator, text);
    return repeated;
}

fn endsAtClauseBoundary(text: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n\"'`");
    if (trimmed.len == 0) return false;
    return std.mem.indexOfScalar(u8, ".!?;", trimmed[trimmed.len - 1]) != null;
}

fn scheduleClauseCleanup(self: *App, repeated_hypothesis: bool) void {
    if (!has_llm or self.clause_cleanup_thread != null) return;
    const session = if (self.current_session) |*value| value else return;
    if (session.lifecycle != .capturing or session.mode == .literal) return;

    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(self.allocator);
    source.appendSlice(self.allocator, session.stable.items) catch return;
    source.appendSlice(self.allocator, session.unstable.items) catch return;
    if (!repeated_hypothesis and !endsAtClauseBoundary(source.items)) return;
    if (source.items.len == 0 or std.mem.eql(u8, source.items, self.last_clause_cleanup_input.items)) return;

    const tail_start = boundedTailStart(source.items, 24);
    const prompt = self.buildContextualFormattingPrompt(source.items[tail_start..], self.session_tone) catch return;
    const owned_source = source.toOwnedSlice(self.allocator) catch {
        self.allocator.free(prompt);
        return;
    };
    const task = self.allocator.create(ClauseCleanupTask) catch {
        self.allocator.free(prompt);
        self.allocator.free(owned_source);
        return;
    };
    task.* = .{
        .app = self,
        .session_id = session.id,
        .input_revision = session.revision,
        .source_text = owned_source,
        .tail_start = tail_start,
        .prompt = prompt,
        .mode = session.mode,
    };

    self.last_clause_cleanup_input.clearRetainingCapacity();
    self.last_clause_cleanup_input.appendSlice(self.allocator, task.source_text) catch {
        self.allocator.free(task.prompt);
        self.allocator.free(task.source_text);
        self.allocator.destroy(task);
        return;
    };
    self.clause_cleanup_done.store(false, .release);
    self.clause_cleanup_thread = std.Thread.spawn(.{}, clauseCleanupWorker, .{task}) catch {
        self.last_clause_cleanup_input.clearRetainingCapacity();
        self.allocator.free(task.prompt);
        self.allocator.free(task.source_text);
        self.allocator.destroy(task);
        return;
    };
}

fn clauseCleanupWorker(task: *ClauseCleanupTask) void {
    const self = task.app;
    defer self.clause_cleanup_done.store(true, .release);
    defer self.allocator.free(task.prompt);
    defer self.allocator.free(task.source_text);
    defer self.allocator.destroy(task);

    self.ensureLlamaLoaded(false) catch |err| {
        std.log.info("Clause cleanup fallback: LLM unavailable ({})", .{err});
        return;
    };

    const started = compat.nanoTimestamp();
    const formatted = self.llama.?.generateWithin(
        task.prompt,
        256,
        Postprocess.clause_llm_deadline_ms,
    ) catch |err| {
        std.log.info("Clause cleanup fallback: generation failed ({})", .{err});
        return;
    };
    defer self.allocator.free(formatted);

    const elapsed_ms = @divTrunc(compat.nanoTimestamp() - started, std.time.ns_per_ms);
    const input_tail = task.source_text[task.tail_start..];
    const output_is_valid = Postprocess.validateLlmOutputForMode(input_tail, formatted, task.mode);
    const outcome = Postprocess.evaluateLlm(elapsed_ms, true, output_is_valid);
    if (outcome != .accepted) {
        std.log.info("Clause cleanup: outcome={s}, latency_ms={d}", .{ @tagName(outcome), elapsed_ms });
        return;
    }

    const formatted_tail = std.mem.trim(u8, formatted, " \t\r\n\"`");
    const cleaned = std.fmt.allocPrint(
        self.allocator,
        "{s}{s}",
        .{ task.source_text[0..task.tail_start], formatted_tail },
    ) catch return;
    const source_copy = self.allocator.dupe(u8, task.source_text) catch {
        self.allocator.free(cleaned);
        return;
    };

    self.clause_cleanup_mutex.lock();
    defer self.clause_cleanup_mutex.unlock();
    if (self.clause_cleanup_result) |old| {
        self.allocator.free(old.source_text);
        self.allocator.free(old.cleaned_text);
    }
    self.clause_cleanup_result = .{
        .session_id = task.session_id,
        .input_revision = task.input_revision,
        .source_text = source_copy,
        .cleaned_text = cleaned,
    };
    std.log.info("Clause cleanup: outcome=accepted, latency_ms={d}", .{elapsed_ms});
}

fn finishClauseCleanup(self: *App, wait_for_completion: bool) void {
    const thread = self.clause_cleanup_thread orelse return;
    if (!wait_for_completion and !self.clause_cleanup_done.load(.acquire)) return;
    thread.join();
    self.clause_cleanup_thread = null;
    self.clause_cleanup_done.store(false, .release);

    self.clause_cleanup_mutex.lock();
    const result = self.clause_cleanup_result;
    self.clause_cleanup_result = null;
    self.clause_cleanup_mutex.unlock();
    const completed = result orelse return;
    defer self.allocator.free(completed.source_text);
    defer self.allocator.free(completed.cleaned_text);

    const session = if (self.current_session) |*value| value else return;
    if (session.id != completed.session_id or session.revision != completed.input_revision) {
        std.log.info("Clause cleanup: outcome=stale_revision", .{});
        return;
    }
    const snapshot = session.updateCleaningAtRevision(
        completed.input_revision,
        completed.cleaned_text,
    ) catch return;

    self.cached_clause_source.clearRetainingCapacity();
    self.cached_clause_result.clearRetainingCapacity();
    self.cached_clause_source.appendSlice(self.allocator, completed.source_text) catch return;
    self.cached_clause_result.appendSlice(self.allocator, completed.cleaned_text) catch {
        self.cached_clause_source.clearRetainingCapacity();
        return;
    };
    if (snapshot) |update| self.emitTranscriptSnapshot(update);
}

fn liveTranscriptionLoop(self: *App, language: [:0]const u8) void {
    defer self.allocator.free(language);

    const interval_ms: u64 = 200;
    const min_new_samples: usize = 8000; // At least 0.5s of new audio (16kHz)
    const chunk_duration: usize = 16000 * 5; // 5s per chunk
    const overlap: usize = 16000 / 2; // retain 500 ms across frozen boundaries
    const chunk_advance = chunk_duration - overlap;

    while (!self.live_stop.load(.seq_cst)) {
        compat.sleepNanoseconds(interval_ms * std.time.ns_per_ms);

        self.finishClauseCleanup(false);

        if (self.live_stop.load(.seq_cst)) break;

        const audio: *AudioCapture = if (self.audio) |*a| a else continue;

        self.checkStuckMic(audio);

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

            appendDeduplicated(&self.frozen_transcript, self.allocator, chunk_text) catch break;
            local_offset += chunk_advance;
            self.frozen_sample_count += chunk_advance;
        }

        self.last_transcribed_len = result.total;

        // Transcribe only the trailing unfrozen audio with live-optimized params
        const tail = tail_samples[local_offset..];
        if (tail.len == 0) {
            if (self.frozen_transcript.items.len > 0) {
                const repeated = self.rememberLiveHypothesis(self.frozen_transcript.items) catch false;
                self.notifyTranscript(self.frozen_transcript.items, false) catch |err| {
                    std.log.warn("Transcript update failed: {}", .{err});
                };
                self.scheduleClauseCleanup(repeated);
            }
            continue;
        }

        var live_t = if (self.live_transcriber) |*live_transcriber| live_transcriber else if (self.transcriber) |*loaded_transcriber| loaded_transcriber else continue;
        const tail_text = live_t.transcribeLive(tail, language) catch |err| {
            std.log.warn("Live transcription failed: {}", .{err});
            continue;
        };
        defer self.allocator.free(tail_text);

        // Build a temporary projection so the retained audio overlap is
        // reconciled without mutating the append-only frozen transcript.
        var combined: std.ArrayListUnmanaged(u8) = .empty;
        defer combined.deinit(self.allocator);
        combined.appendSlice(self.allocator, self.frozen_transcript.items) catch continue;
        appendDeduplicated(&combined, self.allocator, tail_text) catch continue;
        const repeated = self.rememberLiveHypothesis(combined.items) catch false;
        self.notifyTranscript(combined.items, false) catch |err| {
            std.log.warn("Transcript update failed: {}", .{err});
        };
        self.scheduleClauseCleanup(repeated);
    }
}

pub fn stopLiveTranscription(self: *App) void {
    self.live_stop.store(true, .seq_cst);
    if (self.live_thread) |thread| {
        thread.join();
        self.live_thread = null;
    }
    self.finishClauseCleanup(true);
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

pub fn stopRecordingSession(self: *App, session_id: u64) !void {
    const session = if (self.current_session) |*value| value else return error.NoActiveSession;
    if (session.id != session_id or !session.isActive()) return error.StaleSession;
    const options: c_api.TranscribeOptions = .{
        .language = if (self.session_language) |language| language.ptr else null,
        .tone = self.session_tone,
        .remove_filler_words = session.mode != .literal,
        .auto_punctuate = session.mode != .literal,
        .use_llm_formatting = session.mode != .literal,
        .whisper_mode = self.session_whisper_mode,
    };

    // Join every producer before changing the session lifecycle. This avoids
    // racing the live and clause-cleanup workers against `beginDraining`.
    self.stopLiveTranscription();
    const draining_session = if (self.current_session) |*value| value else return error.NoActiveSession;
    if (draining_session.id != session_id) return error.StaleSession;
    draining_session.beginDraining();
    if (self.audio) |*audio| audio.stop();

    if (self.frozen_transcript.items.len > 0) {
        try self.transcribeTail(options);
    } else {
        try self.transcribe(options);
    }
}

pub fn cancelRecordingSession(self: *App, session_id: u64) void {
    if (self.current_session) |*session| {
        if (session.id != session_id) return;
    } else return;
    self.stopLiveTranscription();
    if (self.audio) |*audio| audio.stop();
    if (self.current_session) |*session| {
        session.cancel();
        session.deinit();
        self.current_session = null;
    }
    if (self.session_language) |language| self.allocator.free(language);
    self.session_language = null;
    self.setStatus(.idle);
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
        const segment = prepareSegment(tail);
        std.log.info("Tail trim threshold: {d:.6} (noise floor: {d:.6}, whisper_mode: {})", .{ segment.threshold, segment.noise_floor, options.whisper_mode });
        std.log.info("Tail trim bounds: start={d}, end={d}, total={d}", .{ segment.bounds.start, segment.bounds.end, tail.len });

        const tail_text = try transcriber.transcribeWithLanguage(segment.samples, options.getLanguage());
        defer self.allocator.free(tail_text);
        try appendDeduplicated(&self.frozen_transcript, self.allocator, tail_text);
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

    const samples_mut = audio.getSamplesMut();
    if (samples_mut.len == 0) {
        self.setStatus(.@"error");
        self.notifyError("No audio data recorded");
        return error.NoAudioData;
    }

    // Peak-normalize so quiet speech (esp. whispers) is at a similar level to
    // normal voice. Tuning experiments showed this drops avg WER from 0.42 to
    // 0.06 on whispered audio with no degradation on normal voice.
    const applied_gain = AudioCapture.peakNormalize(samples_mut, 0.95);
    std.log.info("Peak-normalize gain: {d:.2}x", .{applied_gain});

    const samples: []const f32 = samples_mut;

    const segment = prepareSegment(samples);
    std.log.info("Trim threshold: {d:.6} (noise floor: {d:.6}, whisper_mode: {})", .{ segment.threshold, segment.noise_floor, options.whisper_mode });
    std.log.info("Trim bounds: start={d}, end={d}, total={d}, trimmed_pct={d:.1}%", .{
        segment.bounds.start,
        segment.bounds.end,
        samples.len,
        @as(f32, @floatFromInt(samples.len - (segment.bounds.end - segment.bounds.start))) / @as(f32, @floatFromInt(samples.len)) * 100.0,
    });

    if (options.whisper_mode) {
        if (self.loaded_model_id) |model_id| {
            if (std.mem.eql(u8, model_id, "whisper-tiny") or std.mem.eql(u8, model_id, "whisper-base")) {
                std.log.warn("Whisper mode is enabled with a small model ({s}), consider using whisper-small or larger for better whisper detection", .{model_id});
            }
        }
    }

    const raw_text = try transcriber.transcribeWithLanguage(segment.samples, options.getLanguage());
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

    try self.ensureLlamaLoaded(true);

    self.setStatus(.formatting);

    const prompt = try self.buildFormattingPrompt(input, tone);
    defer self.allocator.free(prompt);

    const formatted = self.llama.?.generateWithin(prompt, 256, Postprocess.llm_deadline_ms) catch |err| {
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
    defer self.releaseCompletedSession();
    // Drop Whisper hallucinations on silence/non-speech (looped tokens,
    // "Thanks for watching!", etc.) before doing anything else. We deliver an
    // empty final transcript to clear the UI, skip persistence, skip the
    // (expensive) LLM formatting call, and return to .ready. This cheap local
    // heuristic catches the common failure modes without another model call.
    if (Sensibility.isNonsense(raw_text)) {
        std.log.warn("Sensibility: dropping nonsense transcript ({d} bytes)", .{raw_text.len});
        try self.notifyTranscript("", true);
        self.setStatus(.ready);
        return;
    }

    const mode: Postprocess.Mode = if (self.current_session) |session| session.mode else if (options.use_llm_formatting) .conservative else .literal;
    const cleanup = try Postprocess.deterministicDetailed(self.allocator, raw_text, mode);
    const deterministic = cleanup.text;
    defer self.allocator.free(deterministic);

    // Reuse a revision-checked clause result when the final deterministic
    // transcript exactly matches the source cleaned during capture. This keeps
    // model latency off the release-to-final path without applying stale text.
    if (self.cached_clause_result.items.len != 0 and
        std.mem.eql(u8, deterministic, self.cached_clause_source.items))
    {
        try self.notifyTranscript(self.cached_clause_result.items, true);
        self.log_store.appendTranscript(
            self.allocator,
            raw_text,
            self.deliveredFinal(self.cached_clause_result.items),
        ) catch |err| std.log.warn("Failed to persist transcript: {}", .{err});
        self.setStatus(.ready);
        return;
    }

    if (mode == .literal or !options.use_llm_formatting or !has_llm) {
        try self.notifyTranscript(deterministic, true);
        self.log_store.appendTranscript(self.allocator, raw_text, self.deliveredFinal(deterministic)) catch |err| {
            std.log.warn("Failed to persist transcript: {}", .{err});
        };
        self.setStatus(.ready);
        return;
    }

    // Explicit self-corrections are already resolved by the deterministic
    // pass. Finalize immediately rather than spending the LLM latency budget
    // on a result that conservative validation is not allowed to paraphrase.
    if (mode == .conservative and cleanup.resolved_correction) {
        try self.notifyTranscript(deterministic, true);
        self.log_store.appendTranscript(self.allocator, raw_text, self.deliveredFinal(deterministic)) catch |err| {
            std.log.warn("Failed to persist transcript: {}", .{err});
        };
        self.setStatus(.ready);
        return;
    }

    // Deterministic output is immediately available as the cleaning preview.
    self.notifyCleaning(deterministic);

    self.setStatus(.formatting);

    self.ensureLlamaLoaded(false) catch |err| {
        std.log.info("Postprocess fallback: LLM unavailable ({})", .{err});
        try self.notifyTranscript(deterministic, true);
        self.log_store.appendTranscript(self.allocator, raw_text, self.deliveredFinal(deterministic)) catch {};
        self.setStatus(.ready);
        return;
    };

    const tail_start = boundedTailStart(deterministic, 24);
    const cleanup_tail = deterministic[tail_start..];
    const prompt = try self.buildContextualFormattingPrompt(cleanup_tail, options.tone);
    defer self.allocator.free(prompt);
    const input_revision = if (self.current_session) |session| session.revision else 0;
    const started = compat.nanoTimestamp();
    const formatted = self.llama.?.generateWithin(prompt, 256, Postprocess.llm_deadline_ms) catch |err| {
        std.log.info("Postprocess fallback: generation failed ({})", .{err});
        try self.notifyTranscript(deterministic, true);
        self.log_store.appendTranscript(self.allocator, raw_text, self.deliveredFinal(deterministic)) catch {};
        self.setStatus(.ready);
        return;
    };
    defer self.allocator.free(formatted);

    const elapsed_ms = @divTrunc(compat.nanoTimestamp() - started, std.time.ns_per_ms);
    const revision_is_current = if (self.current_session) |session| session.revision == input_revision else input_revision == 0;
    const output_is_valid = Postprocess.validateLlmOutputForMode(cleanup_tail, formatted, mode);
    const outcome = Postprocess.evaluateLlm(elapsed_ms, revision_is_current, output_is_valid);
    const accepted = outcome == .accepted;
    const formatted_tail = std.mem.trim(u8, formatted, " \t\r\n\"`");
    const accepted_text = if (accepted)
        try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ deterministic[0..tail_start], formatted_tail })
    else
        try self.allocator.dupe(u8, deterministic);
    defer self.allocator.free(accepted_text);
    const final_text = accepted_text;
    std.log.info("Postprocess: outcome={s}, latency_ms={d}", .{ @tagName(outcome), elapsed_ms });
    try self.notifyTranscript(final_text, true);
    self.log_store.appendTranscript(self.allocator, raw_text, self.deliveredFinal(final_text)) catch |err| {
        std.log.warn("Failed to persist transcript: {}", .{err});
    };
    self.setStatus(.ready);
}

fn boundedTailStart(text: []const u8, max_words: usize) usize {
    if (max_words == 0) return text.len;
    var words: usize = 0;
    var i = text.len;
    var in_word = false;
    while (i > 0) {
        i -= 1;
        if (std.ascii.isWhitespace(text[i])) {
            if (in_word) {
                words += 1;
                if (words == max_words) {
                    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
                    return i;
                }
            }
            in_word = false;
        } else in_word = true;
    }
    return 0;
}

fn buildContextualFormattingPrompt(self: *App, input: []const u8, tone: c_api.Tone) ![]u8 {
    const base = try self.buildFormattingPrompt(input, tone);
    defer self.allocator.free(base);
    const context = if (self.current_session) |*session|
        try session.context.buildStructuredBlock(self.allocator)
    else
        try self.allocator.dupe(u8, "No focused-field context was supplied.");
    defer self.allocator.free(context);
    return std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ context, base });
}

fn buildFormattingPrompt(self: *App, input: []const u8, tone: c_api.Tone) ![]u8 {
    if (self.custom_prompt) |cp| {
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}\n\nInput: {s}\n\nOutput:",
            .{ cp, input },
        );
    }

    // Two-stage prompt selection. With small local LLMs (1B–3B) the combined
    // "cleanup AND change tone" prompt drives hallucination on short
    // utterances: the model fills the unused style budget with extra
    // commentary or rewords aggressively. For the default neutral tone we use
    // a tighter cleanup-only prompt; for explicit tones we keep the combined
    // prompt.
    if (tone == .neutral) {
        const cleanup_prompt =
            \\Rewrite the transcribed speech below verbatim with two changes only:
            \\remove disfluencies (um, uh, like, you know) and fix obvious grammar
            \\or punctuation mistakes. Do NOT rephrase, summarize, expand, or
            \\add commentary. Preserve every meaningful word.
            \\
            \\Input: {s}
            \\
            \\Output:
        ;
        return try std.fmt.allocPrint(self.allocator, cleanup_prompt, .{input});
    }

    const polish_prompt =
        \\Rewrite the transcribed speech below. Remove disfluencies
        \\(um, uh, like, you know), fix grammar and punctuation, and adjust
        \\style.{s} Preserve the speaker's meaning. Output only the rewritten
        \\text with no commentary.
        \\
        \\Input: {s}
        \\
        \\Output:
    ;

    return try std.fmt.allocPrint(
        self.allocator,
        polish_prompt,
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

    const JsonEntry = struct {
        created_at_unix_ms: i64,
        text: []const u8,
        formatted_text: ?[]const u8,
    };

    const json_entries = try self.allocator.alloc(JsonEntry, entries.len);
    defer self.allocator.free(json_entries);

    for (entries, 0..) |entry, i| {
        json_entries[i] = .{
            .created_at_unix_ms = entry.created_at_unix_ms,
            .text = entry.text,
            .formatted_text = entry.formatted_text,
        };
    }

    const json = try std.json.Stringify.valueAlloc(self.allocator, json_entries, .{});
    return c_api.String.fromSlice(json);
}

fn setStatus(self: *App, status: c_api.Status) void {
    self.status = status;
    if (self.config.on_status_change) |cb| {
        cb(self.config.userdata, status);
    }
}

fn notifyTranscript(self: *App, text: []const u8, is_final: bool) !void {
    if (self.current_session) |*session| {
        const update = if (is_final) blk: {
            session.beginFinalizing();
            break :blk try session.final(text);
        } else try session.updateHypothesis(text);
        if (update) |snapshot| {
            self.emitTranscriptSnapshot(snapshot);
            if (self.config.on_transcript) |legacy| {
                var combined: std.ArrayListUnmanaged(u8) = .empty;
                defer combined.deinit(self.allocator);
                try combined.appendSlice(self.allocator, snapshot.stable_text);
                try combined.appendSlice(self.allocator, snapshot.unstable_text);
                legacy(self.config.userdata, c_api.String.fromSlice(combined.items), is_final);
            }
        }
    } else if (self.config.on_transcript) |cb| {
        cb(self.config.userdata, c_api.String.fromSlice(text), is_final);
    }
}

fn emitTranscriptSnapshot(self: *App, snapshot: TranscriptSession.Snapshot) void {
    if (self.config.on_transcript_update) |cb| cb(self.config.userdata, .{
        .session_id = snapshot.session_id,
        .revision = snapshot.revision,
        .stable_text = c_api.String.fromSlice(snapshot.stable_text),
        .unstable_text = c_api.String.fromSlice(snapshot.unstable_text),
        .phase = @enumFromInt(@intFromEnum(snapshot.phase)),
    });
}

fn deliveredFinal(self: *App, fallback: []const u8) []const u8 {
    if (self.current_session) |*session| {
        if (session.final_emitted) return session.stable.items;
    }
    return fallback;
}

fn releaseCompletedSession(self: *App) void {
    if (self.current_session) |*session| {
        if (!session.final_emitted) return;
        session.deinit();
        self.current_session = null;
    }
    if (self.session_language) |language| self.allocator.free(language);
    self.session_language = null;
}

fn notifyCleaning(self: *App, text: []const u8) void {
    const session = if (self.current_session) |*value| value else {
        self.notifyTranscript(text, false) catch |err| {
            std.log.warn("Transcript cleaning preview failed: {}", .{err});
        };
        return;
    };
    session.beginFinalizing();
    const maybe_snapshot = session.updateCleaning(text) catch return;
    const snapshot = maybe_snapshot orelse return;
    self.emitTranscriptSnapshot(snapshot);
}

/// Reload `dictionary.txt` from disk and push the resulting initial-prompt
/// string into the loaded transcribers. Best-effort: failures are logged and
/// transcription continues with whatever prompt was last set (or none). Runs
/// at the start of every recording so the user can edit the dictionary file
/// without restarting the app.
fn refreshDictionaryPrompt(self: *App, context: ?*const ContextPack) void {
    const fresh = DictionaryStore.loadFromModelsDir(self.allocator, self.config.getModelsDir()) catch |err| {
        std.log.warn("DictionaryStore reload failed: {}", .{err});
        return;
    };
    self.dictionary.deinit();
    self.dictionary = fresh;

    const prompt = (if (context) |pack|
        pack.buildWhisperPrompt(self.allocator, self.dictionary)
    else
        self.dictionary.buildPrompt(self.allocator)) catch |err| {
        std.log.warn("DictionaryStore.buildPrompt failed: {}", .{err});
        return;
    };
    defer if (prompt) |p| self.allocator.free(p);

    if (prompt) |p| {
        std.log.info(
            "Initial prompt: {d} bytes, {d} dictionary phrases active",
            .{ p.len, self.dictionary.phrases.items.len },
        );
    }

    if (self.transcriber) |*t| {
        t.setInitialPrompt(prompt) catch |err| std.log.warn("setInitialPrompt (main) failed: {}", .{err});
    }
    if (self.live_transcriber) |*t| {
        t.setInitialPrompt(prompt) catch |err| std.log.warn("setInitialPrompt (live) failed: {}", .{err});
    }
}

/// Inspect the app-selected input device (or the system default in follow
/// mode) via CoreAudio and surface a
/// one-shot warning when it is a Bluetooth mic (typically AirPods). Uses the
/// OS-reported `kAudioDevicePropertyTransportType`, which is more robust than
/// substring matching the device name (no false negatives across locales or
/// rebadged BT mics, no false positives on devices that happen to contain
/// "airpods" in their label). Latched via `bluetooth_mic_warned` so the
/// notification fires at most once per process.
///
/// Also pushes a BT-friendly VAD bucket into the loaded transcribers when
/// the device is Bluetooth. BT codec compression smears speech onsets and
/// inflates background noise, which makes the default Silero threshold
/// (0.5) overshoot — speech is detected late and trimmed early. Relaxed
/// thresholds + larger pad reduce that. The tuning is applied on every
/// recording start (not latched) so a user who switches to a BT device
/// after launch picks up the new params without restarting.
fn checkInputDevice(self: *App) void {
    const info = AudioDevice.detectInput(self.allocator, self.selected_input_device) orelse return;
    defer info.deinit(self.allocator);
    if (info.kind != .bluetooth) return;

    if (!self.bluetooth_mic_warned) {
        self.bluetooth_mic_warned = true;
        std.log.warn(
            "App input is a Bluetooth device ({s}); BT mics add latency and degrade transcription quality",
            .{info.name},
        );
        self.notifyWarning(
            "Bluetooth mic detected. Built-in or USB mics give better dictation accuracy.",
        );
    }

    self.applyBluetoothVadTuning();
}

/// VAD bucket for Bluetooth input. Threshold is dropped from 0.5/0.3 to
/// 0.25 to avoid clipping the start of utterances; speech_pad_ms is
/// doubled to keep the codec's onset smear inside the speech window;
/// min_silence_ms is raised so the brief micro-gaps inside BT audio don't
/// fragment a single utterance into several. Whisper's own VAD sample-set
/// confirms BT recordings need ~2x the pad of built-in mics.
fn applyBluetoothVadTuning(self: *App) void {
    const vad_path = self.config.getVadModelPath();
    const enabled = vad_path != null;
    const tuning = bluetooth_vad_tuning;

    if (self.transcriber) |*t| {
        t.setVadParams(enabled, tuning.threshold, tuning.min_speech_ms, tuning.min_silence_ms, tuning.speech_pad_ms);
    }
    if (self.live_transcriber) |*t| {
        t.setVadParams(enabled, tuning.threshold, tuning.min_speech_ms, tuning.min_silence_ms, tuning.speech_pad_ms);
    }
    std.log.info(
        "VAD: applied Bluetooth tuning (threshold={d:.2}, min_speech={d}ms, min_silence={d}ms, pad={d}ms)",
        .{ tuning.threshold, tuning.min_speech_ms, tuning.min_silence_ms, tuning.speech_pad_ms },
    );
}

/// Notify the user once per recording session if CoreAudio has stopped
/// delivering real audio. Counts the trailing run of bit-exact-zero samples
/// reported by `AudioCapture` and fires the existing `on_error` callback when
/// it crosses `stuck_mic_threshold_samples`. The latch (`stuck_mic_warned`)
/// prevents the message from spamming every poll.
fn checkStuckMic(self: *App, audio: *AudioCapture) void {
    if (self.stuck_mic_warned) return;
    const zero_run = audio.getConsecutiveZeroSamples();
    if (zero_run < stuck_mic_threshold_samples) return;
    self.stuck_mic_warned = true;
    std.log.warn(
        "Stuck microphone detected: {d} consecutive zero samples (>={d}s)",
        .{ zero_run, zero_run / 16000 },
    );
    self.notifyWarning(
        "Microphone is silent. Check input device and microphone permissions.",
    );
}

/// Deliver a non-fatal advisory through the warning channel. Unlike
/// `notifyError`, this does NOT flip status to .error and does NOT take over
/// the status text, so a recording in progress keeps showing as recording.
fn notifyWarning(self: *App, message: []const u8) void {
    std.debug.assert(message.len > 0);
    if (self.config.on_warning) |cb| {
        cb(self.config.userdata, c_api.String.fromSlice(message));
    } else if (self.config.on_error) |cb| {
        // Backwards-compat: hosts that haven't wired on_warning still see the
        // text via on_error, just without the status hijack.
        cb(self.config.userdata, c_api.String.fromSlice(message));
    }
}

fn notifyError(self: *App, message: []const u8) void {
    if (self.config.on_error) |cb| {
        cb(self.config.userdata, c_api.String.fromSlice(message));
    }
    self.status = .@"error";
}
