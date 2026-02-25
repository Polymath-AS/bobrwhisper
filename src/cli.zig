//! CLI for testing BobrWhisper

const std = @import("std");
const builtin = @import("builtin");
const Transcriber = @import("Transcriber.zig");
const AudioCapture = @import("audio/AudioCapture.zig");

const has_llm = builtin.os.tag == .macos;
const LlamaClient = if (has_llm) @import("llm/LlamaClient.zig") else void;

pub const WhisperModel = enum {
    tiny,
    base,
    small,
    medium,
    large,
    large_turbo,

    pub fn filename(self: WhisperModel) []const u8 {
        return switch (self) {
            .tiny => "ggml-tiny.bin",
            .base => "ggml-base.bin",
            .small => "ggml-small.bin",
            .medium => "ggml-medium.bin",
            .large => "ggml-large-v3.bin",
            .large_turbo => "ggml-large-v3-turbo.bin",
        };
    }

    pub fn url(self: WhisperModel) []const u8 {
        const base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";
        return switch (self) {
            .tiny => base ++ "ggml-tiny.bin",
            .base => base ++ "ggml-base.bin",
            .small => base ++ "ggml-small.bin",
            .medium => base ++ "ggml-medium.bin",
            .large => base ++ "ggml-large-v3.bin",
            .large_turbo => base ++ "ggml-large-v3-turbo.bin",
        };
    }

    pub fn sizeDesc(self: WhisperModel) []const u8 {
        return switch (self) {
            .tiny => "75 MB",
            .base => "142 MB",
            .small => "466 MB",
            .medium => "1.5 GB",
            .large => "3.1 GB",
            .large_turbo => "809 MB",
        };
    }

    pub fn fromString(s: []const u8) ?WhisperModel {
        return std.meta.stringToEnum(WhisperModel, s);
    }

    pub fn getPath(self: WhisperModel, allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        return std.fmt.allocPrint(allocator, "{s}/.bobrwhisper/models/{s}", .{ home, self.filename() });
    }

    pub fn ensureDownloaded(self: WhisperModel, allocator: std.mem.Allocator) ![]const u8 {
        const path = try self.getPath(allocator);
        errdefer allocator.free(path);

        std.fs.accessAbsolute(path, .{}) catch {
            std.debug.print("Model '{s}' not found. Downloading ({s})...\n", .{ @tagName(self), self.sizeDesc() });
            try downloadWhisperModel(self, path);
        };

        return path;
    }
};

pub fn getVadModelPath(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const path = std.fmt.allocPrint(allocator, "{s}/.bobrwhisper/models/silero-v6.2.0.bin", .{home}) catch return null;

    std.fs.accessAbsolute(path, .{}) catch {
        allocator.free(path);
        return null;
    };

    return path;
}

pub const LlamaModel = enum {
    @"llama3.2-1b",
    @"llama3.2-3b",
    @"qwen2.5-0.5b",
    @"qwen2.5-1.5b",

    pub fn filename(self: LlamaModel) []const u8 {
        return switch (self) {
            .@"llama3.2-1b" => "llama-3.2-1b-q4_k_m.gguf",
            .@"llama3.2-3b" => "llama-3.2-3b-q4_k_m.gguf",
            .@"qwen2.5-0.5b" => "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            .@"qwen2.5-1.5b" => "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        };
    }

    pub fn url(self: LlamaModel) []const u8 {
        return switch (self) {
            .@"llama3.2-1b" => "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            .@"llama3.2-3b" => "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            .@"qwen2.5-0.5b" => "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf",
            .@"qwen2.5-1.5b" => "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
        };
    }

    pub fn sizeDesc(self: LlamaModel) []const u8 {
        return switch (self) {
            .@"llama3.2-1b" => "700 MB",
            .@"llama3.2-3b" => "2.0 GB",
            .@"qwen2.5-0.5b" => "400 MB",
            .@"qwen2.5-1.5b" => "1.1 GB",
        };
    }

    pub fn fromString(s: []const u8) ?LlamaModel {
        return std.meta.stringToEnum(LlamaModel, s);
    }

    pub fn getPath(self: LlamaModel, allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        return std.fmt.allocPrint(allocator, "{s}/.bobrwhisper/models/{s}", .{ home, self.filename() });
    }

    pub fn ensureDownloaded(self: LlamaModel, allocator: std.mem.Allocator) ![]const u8 {
        const path = try self.getPath(allocator);
        errdefer allocator.free(path);

        std.fs.accessAbsolute(path, .{}) catch {
            std.debug.print("LLM '{s}' not found. Downloading ({s})...\n", .{ @tagName(self), self.sizeDesc() });
            try downloadLlamaModel(self, path);
        };

        return path;
    }
};

fn downloadWhisperModel(model: WhisperModel, dest_path: []const u8) !void {
    try downloadFile(model.url(), dest_path);
}

fn downloadLlamaModel(model: LlamaModel, dest_path: []const u8) !void {
    try downloadFile(model.url(), dest_path);
}

fn setupMetalResources(allocator: std.mem.Allocator) void {
    // Skip if already set
    if (std.posix.getenv("GGML_METAL_PATH_RESOURCES") != null) return;

    // Get executable path and derive ../share from it
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&buf) catch return;

    const exe_dir = std.fs.path.dirname(exe_path) orelse return;
    const share_path_slice = std.fmt.allocPrint(allocator, "{s}/../share\x00", .{exe_dir}) catch return;
    defer allocator.free(share_path_slice);
    const share_path: [*:0]const u8 = @ptrCast(share_path_slice.ptr);

    // Verify the shader file exists
    const metal_path = std.fmt.allocPrint(allocator, "{s}/ggml-metal.metal", .{share_path_slice[0 .. share_path_slice.len - 1]}) catch return;
    defer allocator.free(metal_path);

    std.fs.accessAbsolute(metal_path, .{}) catch return;

    // Set env var for ggml via extern C
    _ = setenv("GGML_METAL_PATH_RESOURCES", share_path, 0);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn downloadFile(url: []const u8, dest_path: []const u8) !void {
    const dir_path = std.fs.path.dirname(dest_path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var child = std.process.Child.init(&.{
        "curl",
        "-L",
        "--progress-bar",
        "-o",
        dest_path,
        url,
    }, std.heap.page_allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    _ = try child.spawnAndWait();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Auto-detect Metal shader path if not set
    setupMetalResources(allocator);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "transcribe")) {
        try transcribeCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "transcribe-raw")) {
        try transcribeRawCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "record")) {
        try recordCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "live")) {
        try liveCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "models")) {
        try modelsCommand(allocator);
    } else if (std.mem.eql(u8, command, "languages")) {
        languagesCommand();
    } else if (std.mem.eql(u8, command, "help")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    const usage =
        \\BobrWhisper CLI - Local voice-to-text
        \\
        \\Usage: bobrwhisper-cli <command> [options]
        \\
        \\Commands:
        \\  live [--format] [model]         Live transcription (auto-downloads model)
        \\  transcribe <model> <audio.wav>  Transcribe a WAV file
        \\  transcribe-raw <model> <file>   Transcribe raw f32 audio
        \\  record <duration_secs>          Record audio from microphone
        \\  models                          List available models
        \\  languages                       List supported languages
        \\  help                            Show this help
        \\
        \\Whisper Models (auto-downloaded on first use):
        \\  tiny   (75 MB)   - Fastest, lower accuracy
        \\  base   (142 MB)  - Fast, decent accuracy
        \\  small  (466 MB)  - Good balance (default, recommended)
        \\  medium (1.5 GB)  - High accuracy
        \\  large       (3.1 GB)  - Best accuracy
        \\  large_turbo (809 MB)  - Near-large accuracy, ~4x faster
        \\
        \\LLM Models (for --format, auto-downloaded):
        \\  llama3.2-1b  (700 MB)  - Fast, good quality (default, recommended)
        \\  llama3.2-3b  (2.0 GB)  - Better quality
        \\  qwen2.5-0.5b (400 MB)  - Fastest, basic formatting
        \\  qwen2.5-1.5b (1.1 GB)  - Balanced
        \\
        \\Options:
        \\  --format [llm-model]            Clean up transcription with local LLM
        \\
        \\Examples:
        \\  bobrwhisper-cli live            # Uses small whisper model
        \\  bobrwhisper-cli live tiny       # Uses tiny model (faster, less accurate)
        \\  bobrwhisper-cli live --format   # With LLM formatting (llama3.2-1b)
        \\  bobrwhisper-cli live --format qwen2.5-0.5b  # Faster LLM
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn transcribeCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: bobrwhisper-cli transcribe <model_path> <audio.wav>\n", .{});
        return;
    }

    const model_path = args[0];
    const audio_path = args[1];

    const vad_path = getVadModelPath(allocator);
    defer if (vad_path) |p| allocator.free(p);

    std.debug.print("Loading model: {s}\n", .{model_path});
    if (vad_path != null) std.debug.print("VAD: enabled\n", .{});

    var transcriber = try Transcriber.init(allocator, .{
        .model_path = model_path,
        .language = "en",
        .n_threads = 4,
        .vad_enabled = vad_path != null,
        .vad_model_path = vad_path,
    });
    defer transcriber.deinit();

    std.debug.print("Loading audio: {s}\n", .{audio_path});

    // Load WAV file
    const samples = try loadWavFile(allocator, audio_path);
    defer allocator.free(samples);

    std.debug.print("Transcribing {d} samples...\n", .{samples.len});

    const text = try transcriber.transcribe(samples);
    defer allocator.free(text);

    std.debug.print("\n--- Transcription ---\n{s}\n", .{text});
}

fn transcribeRawCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: bobrwhisper-cli transcribe-raw <model_path> <audio.raw>\n", .{});
        return;
    }

    const model_path = args[0];
    const audio_path = args[1];

    const vad_path = getVadModelPath(allocator);
    defer if (vad_path) |p| allocator.free(p);

    std.debug.print("Loading model: {s}\n", .{model_path});
    if (vad_path != null) std.debug.print("VAD: enabled\n", .{});

    var transcriber = try Transcriber.init(allocator, .{
        .model_path = model_path,
        .language = "en",
        .n_threads = 4,
        .vad_enabled = vad_path != null,
        .vad_model_path = vad_path,
    });
    defer transcriber.deinit();

    std.debug.print("Loading raw audio: {s}\n", .{audio_path});

    const file = try std.fs.cwd().openFile(audio_path, .{});
    defer file.close();

    const stat = try file.stat();
    const num_samples = stat.size / @sizeOf(f32);

    const samples = try allocator.alloc(f32, num_samples);
    defer allocator.free(samples);

    const bytes = std.mem.sliceAsBytes(samples);
    _ = try file.readAll(bytes);

    std.debug.print("Transcribing {d} samples ({d:.2}s)...\n", .{
        samples.len,
        @as(f64, @floatFromInt(samples.len)) / 16000.0,
    });

    const text = try transcriber.transcribe(samples);
    defer allocator.free(text);

    std.debug.print("\n--- Transcription ---\n{s}\n", .{text});
}

fn recordCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const duration_secs: u64 = if (args.len > 0)
        std.fmt.parseInt(u64, args[0], 10) catch 5
    else
        5;

    std.debug.print("Recording for {d} seconds...\n", .{duration_secs});
    std.debug.print("(Press Ctrl+C to stop early)\n", .{});

    var audio = try AudioCapture.init(allocator);
    defer audio.deinit();

    try audio.start();

    std.Thread.sleep(duration_secs * std.time.ns_per_s);

    audio.stop();

    const samples = audio.getSamples();
    std.debug.print("Recorded {d} samples ({d:.2}s)\n", .{
        samples.len,
        @as(f64, @floatFromInt(samples.len)) / 16000.0,
    });

    const output_path = "recording.raw";
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    const bytes = std.mem.sliceAsBytes(samples);
    try file.writeAll(bytes);

    std.debug.print("Saved raw audio to: {s}\n", .{output_path});
}

fn liveCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse args - defaults match macOS app
    var use_format = false;
    var selected_whisper: WhisperModel = .small;
    var selected_llm: LlamaModel = .@"llama3.2-1b";
    var expect_llm_model = false;

    for (args) |arg| {
        if (expect_llm_model) {
            selected_llm = LlamaModel.fromString(arg) orelse {
                std.debug.print("Unknown LLM model: {s}\n", .{arg});
                std.debug.print("Available: llama3.2-1b, llama3.2-3b, qwen2.5-0.5b, qwen2.5-1.5b\n", .{});
                return;
            };
            expect_llm_model = false;
        } else if (std.mem.eql(u8, arg, "--format")) {
            use_format = true;
            expect_llm_model = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            selected_whisper = WhisperModel.fromString(arg) orelse {
                std.debug.print("Unknown model: {s}\n", .{arg});
                std.debug.print("Available: tiny, base, small, medium, large\n", .{});
                return;
            };
        }
    }

    std.debug.print("Live transcription mode\n", .{});
    if (use_format) {
        std.debug.print("LLM formatting: enabled ({s})\n", .{@tagName(selected_llm)});
    }

    const model_path = selected_whisper.ensureDownloaded(allocator) catch |err| {
        std.debug.print("Failed to get whisper model: {}\n", .{err});
        return;
    };
    defer allocator.free(model_path);

    const vad_path = getVadModelPath(allocator);
    defer if (vad_path) |p| allocator.free(p);

    std.debug.print("Loading whisper model: {s}\n", .{model_path});
    if (vad_path != null) std.debug.print("VAD: enabled\n", .{});

    var transcriber = Transcriber.init(allocator, .{
        .model_path = model_path,
        .language = "en",
        .n_threads = 4,
        .vad_enabled = vad_path != null,
        .vad_model_path = vad_path,
    }) catch |err| {
        std.debug.print("Failed to load whisper model: {}\n", .{err});
        return;
    };
    defer transcriber.deinit();

    // Load LLM if formatting enabled
    var llama: ?if (has_llm) LlamaClient else void = if (has_llm) null else {};
    if (has_llm and use_format) {
        const llm_model_path = selected_llm.ensureDownloaded(allocator) catch |err| {
            std.debug.print("Failed to get LLM model: {} (continuing without formatting)\n", .{err});
            return;
        };
        defer allocator.free(llm_model_path);

        std.debug.print("Loading LLM: {s}\n", .{llm_model_path});
        if (LlamaClient.init(allocator, .{
            .model_path = llm_model_path,
            .n_ctx = 512,
            .n_threads = 4,
        })) |l| {
            llama = l;
        } else |err| {
            std.debug.print("Failed to load LLM: {} (continuing without formatting)\n", .{err});
        }
    }
    defer if (has_llm) {
        if (llama) |*l| l.deinit();
    };

    std.debug.print("Models loaded. Starting audio capture...\n", .{});
    std.debug.print("Speak now! (Ctrl+C to stop)\n\n", .{});

    var audio = try AudioCapture.init(allocator);
    defer audio.deinit();

    try audio.start();

    // Streaming: transcribe rolling window every 2 seconds
    const sample_rate: usize = 16000;
    const chunk_ms: usize = 2000; // 2 second chunks
    const chunk_samples: usize = sample_rate * chunk_ms / 1000;
    const overlap_ms: usize = 500; // 500ms overlap for context
    const overlap_samples: usize = sample_rate * overlap_ms / 1000;

    var last_end: usize = 0;

    while (true) {
        std.Thread.sleep(100 * std.time.ns_per_ms);

        const sample_count = audio.getSampleCount();
        if (sample_count < last_end + chunk_samples) continue;

        const samples = audio.copySamples(allocator) catch continue;
        defer allocator.free(samples);

        // Take chunk with overlap from previous
        const start = if (last_end > overlap_samples) last_end - overlap_samples else 0;
        const chunk = samples[start..];

        const text = transcriber.transcribe(chunk) catch |err| {
            std.debug.print("\rError: {}\n", .{err});
            last_end = samples.len;
            continue;
        };
        defer allocator.free(text);

        const trimmed = std.mem.trim(u8, text, " \t\n");
        if (trimmed.len > 0 and !isHallucination(trimmed)) {
            const stdout_fd = std.posix.STDOUT_FILENO;

            // Format with LLM if available
            if (has_llm) {
                if (llama) |*l| {
                    const formatted = l.formatTranscript(trimmed) catch {
                        _ = std.posix.write(stdout_fd, trimmed) catch {};
                        _ = std.posix.write(stdout_fd, "\n") catch {};
                        last_end = samples.len;
                        continue;
                    };
                    defer allocator.free(formatted);
                    const fmt_trimmed = std.mem.trim(u8, formatted, " \t\n");
                    _ = std.posix.write(stdout_fd, fmt_trimmed) catch {};
                } else {
                    _ = std.posix.write(stdout_fd, trimmed) catch {};
                }
            } else {
                _ = std.posix.write(stdout_fd, trimmed) catch {};
            }
            _ = std.posix.write(stdout_fd, "\n") catch {};
        }

        last_end = samples.len;
    }
}

fn isHallucination(text: []const u8) bool {
    const hallucinations = [_][]const u8{
        "you",
        "Thank you.",
        "Thanks for watching!",
        "Thanks for watching.",
        "Thank you for watching.",
        "Thank you for watching!",
        "Bye.",
        "Bye!",
        "[BLANK_AUDIO]",
        "(silence)",
        "...",
    };
    for (hallucinations) |h| {
        if (std.ascii.eqlIgnoreCase(text, h)) return true;
    }
    return false;
}

fn modelsCommand(allocator: std.mem.Allocator) !void {
    _ = allocator;

    const models =
        \\Whisper Models (download to ~/.bobrwhisper/models/):
        \\
        \\  tiny    (75 MB)   - Fastest, lower accuracy
        \\  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin
        \\
        \\  base    (142 MB)  - Fast, decent accuracy
        \\  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
        \\
        \\  small   (466 MB)  - Good balance (recommended)
        \\  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
        \\
        \\  medium  (1.5 GB)  - High accuracy
        \\  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin
        \\
        \\  large       (3.1 GB)  - Best accuracy
        \\  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin
        \\
        \\  large_turbo (809 MB)  - Near-large accuracy, ~4x faster
        \\  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
        \\
        \\Download example:
        \\  mkdir -p ~/.bobrwhisper/models
        \\  curl -L -o ~/.bobrwhisper/models/ggml-small.bin \
        \\    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
        \\
    ;
    std.debug.print("{s}", .{models});
}

fn languagesCommand() void {
    std.debug.print("Supported languages ({d}):\n\n", .{Transcriber.getSupportedLanguages().len});

    for (Transcriber.getSupportedLanguages(), 0..) |lang, i| {
        std.debug.print("{s:>4}", .{lang});
        if ((i + 1) % 10 == 0) {
            std.debug.print("\n", .{});
        } else {
            std.debug.print(" ", .{});
        }
    }
    std.debug.print("\n", .{});
}

fn loadWavFile(allocator: std.mem.Allocator, path: []const u8) ![]f32 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Read WAV header
    var header: [44]u8 = undefined;
    _ = try file.readAll(&header);

    // Verify WAV format
    if (!std.mem.eql(u8, header[0..4], "RIFF") or !std.mem.eql(u8, header[8..12], "WAVE")) {
        return error.InvalidWavFile;
    }

    // Get format info
    const channels: u16 = std.mem.readInt(u16, header[22..24], .little);
    const sample_rate: u32 = std.mem.readInt(u32, header[24..28], .little);
    const bits_per_sample: u16 = std.mem.readInt(u16, header[34..36], .little);

    std.debug.print("WAV: {d}Hz, {d}ch, {d}bit\n", .{ sample_rate, channels, bits_per_sample });

    if (bits_per_sample != 16) {
        std.debug.print("Warning: Only 16-bit WAV supported, got {d}-bit\n", .{bits_per_sample});
        return error.UnsupportedBitDepth;
    }

    // Read audio data
    const data_size: u32 = std.mem.readInt(u32, header[40..44], .little);
    const num_samples = data_size / (@as(u32, channels) * 2);

    var samples = try allocator.alloc(f32, num_samples);
    errdefer allocator.free(samples);

    // Read and convert samples
    var buf: [2]u8 = undefined;
    for (0..num_samples) |i| {
        // Read sample(s) and take first channel
        _ = try file.readAll(&buf);
        const sample_i16: i16 = std.mem.readInt(i16, &buf, .little);
        samples[i] = @as(f32, @floatFromInt(sample_i16)) / 32768.0;

        // Skip other channels
        if (channels > 1) {
            for (1..channels) |_| {
                _ = try file.readAll(&buf);
            }
        }
    }

    // Resample to 16kHz if needed
    if (sample_rate != 16000) {
        std.debug.print("Resampling from {d}Hz to 16000Hz\n", .{sample_rate});
        const resampled = try AudioCapture.resample(
            allocator,
            samples,
            @floatFromInt(sample_rate),
            16000.0,
        );
        allocator.free(samples);
        return resampled;
    }

    return samples;
}
