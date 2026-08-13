//! Run snippets recorded via `snippet` against the Zig core under several
//! VAD configurations and report normalized word-error rate (WER) vs. the
//! ground truth label.
//!
//! Loads each <id>.json + <id>.wav pair from a directory, sweeps a small set
//! of VAD presets, and prints a per-snippet results table plus a per-preset
//! summary so the operator can pick or refine a config.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const cli = @import("cli.zig");
const simd = @import("simd.zig");
const asr = @import("asr");

const WhisperCppAdapter = asr.WhisperCppAdapter;
const WhisperModel = cli.WhisperModel;

pub const Preset = struct {
    name: []const u8,
    enabled: bool = true,
    threshold: f32 = 0.5,
    min_speech_ms: i32 = 250,
    min_silence_ms: i32 = 100,
    speech_pad_ms: i32 = 30,
};

/// Five VAD presets covering the practical sensitivity range. `no-vad` is the
/// honest baseline; `default` matches whisper.cpp's stock VAD; `whisper`
/// matches the existing `--whisper-mode` defaults; `low-thresh` is what we
/// reach for when whispered speech is being chopped; `balanced` sits in the
/// middle in case neither extreme wins overall.
const default_presets = [_]Preset{
    .{ .name = "no-vad", .enabled = false },
    .{ .name = "default", .threshold = 0.5, .min_speech_ms = 250, .min_silence_ms = 100, .speech_pad_ms = 30 },
    .{ .name = "whisper", .threshold = 0.3, .min_speech_ms = 150, .min_silence_ms = 200, .speech_pad_ms = 100 },
    .{ .name = "low-thresh", .threshold = 0.2, .min_speech_ms = 100, .min_silence_ms = 250, .speech_pad_ms = 150 },
    .{ .name = "balanced", .threshold = 0.4, .min_speech_ms = 200, .min_silence_ms = 150, .speech_pad_ms = 60 },
};

const Snippet = struct {
    id: []const u8,
    label: []const u8,
    whisper: bool,
    audio_file: []const u8,
    duration_seconds: f64,
    sample_rate: u32,
    channels: u32,
    num_samples: usize,
    noise_floor_rms: f32,
    created_at_unix_ms: i64,
    // v2 fields. Optional with null defaults so older snippets still parse.
    device: ?[]const u8 = null,
    device_kind: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
};

const Result = struct {
    snippet_id: []const u8,
    label: []const u8,
    whispered: bool,
    preset: []const u8,
    transcript: []const u8,
    wer: f32,
    device: ?[]const u8,
    device_kind: ?[]const u8,
    tags: []const []const u8,
};

const GroupBy = enum {
    none,
    mode,
    device,
    device_kind,
    tag,

    fn fromString(s: []const u8) ?GroupBy {
        return std.meta.stringToEnum(GroupBy, s);
    }
};

const GainMode = union(enum) {
    none,
    /// Peak-normalize: scale so peak amplitude is 0.95.
    auto,
    /// Multiply samples by a fixed factor.
    fixed: f32,
};

const AudioStats = struct {
    peak: f32,
    rms: f32,
};

fn computeAudioStats(samples: []const f32) AudioStats {
    if (samples.len == 0) return .{ .peak = 0, .rms = 0 };
    // Two vector passes rather than one fused scalar pass. `zig build
    // bench-simd` measures the pair at ~3x the fused loop even on whole files,
    // so the extra trip over the buffer is not worth fusing back together.
    const peak = simd.maxAbs(samples);
    const energy = simd.sumOfSquaresWide(samples);
    return .{
        .peak = peak,
        .rms = @floatCast(@sqrt(energy / @as(f64, @floatFromInt(samples.len)))),
    };
}

fn applyGain(samples: []f32, mode: GainMode, stats: AudioStats) f32 {
    const factor: f32 = switch (mode) {
        .none => 1.0,
        .fixed => |f| f,
        .auto => if (stats.peak > 0.001) 0.95 / stats.peak else 1.0,
    };
    if (factor == 1.0) return 1.0;
    simd.scaleClamped(samples, factor);
    return factor;
}

pub fn run(allocator: std.mem.Allocator, raw_args: []const []const u8) !void {
    var snippets_dir: ?[]const u8 = null;
    var selected_model: WhisperModel = .small;
    var preset_filter: ?[]const u8 = null;
    var gain_mode: GainMode = .none;
    var group_by: GroupBy = .none;

    var i: usize = 0;
    while (i < raw_args.len) : (i += 1) {
        const a = raw_args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, a, "--snippets")) {
            i += 1;
            if (i >= raw_args.len) {
                std.debug.print("tune: --snippets requires a directory\n", .{});
                return error.MissingValue;
            }
            snippets_dir = raw_args[i];
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= raw_args.len) {
                std.debug.print("tune: --model requires a name\n", .{});
                return error.MissingValue;
            }
            selected_model = WhisperModel.fromString(raw_args[i]) orelse {
                std.debug.print("tune: unknown model '{s}'\n", .{raw_args[i]});
                return error.UnknownModel;
            };
        } else if (std.mem.eql(u8, a, "--preset")) {
            i += 1;
            if (i >= raw_args.len) {
                std.debug.print("tune: --preset requires a name\n", .{});
                return error.MissingValue;
            }
            preset_filter = raw_args[i];
        } else if (std.mem.eql(u8, a, "--gain")) {
            i += 1;
            if (i >= raw_args.len) {
                std.debug.print("tune: --gain requires a value (auto, none, or a number)\n", .{});
                return error.MissingValue;
            }
            const v = raw_args[i];
            if (std.mem.eql(u8, v, "none")) {
                gain_mode = .none;
            } else if (std.mem.eql(u8, v, "auto")) {
                gain_mode = .auto;
            } else {
                const factor = std.fmt.parseFloat(f32, v) catch {
                    std.debug.print("tune: invalid --gain value '{s}'\n", .{v});
                    return error.InvalidGain;
                };
                gain_mode = .{ .fixed = factor };
            }
        } else if (std.mem.eql(u8, a, "--group-by")) {
            i += 1;
            if (i >= raw_args.len) {
                std.debug.print("tune: --group-by requires a value (none, mode, device, device_kind, tag)\n", .{});
                return error.MissingValue;
            }
            group_by = GroupBy.fromString(raw_args[i]) orelse {
                std.debug.print("tune: invalid --group-by value '{s}'\n", .{raw_args[i]});
                return error.InvalidGroupBy;
            };
        } else {
            std.debug.print("tune: unknown argument '{s}'\n", .{a});
            printUsage();
            return error.UnknownArg;
        }
    }

    var dir_storage: ?[]u8 = null;
    defer if (dir_storage) |s| allocator.free(s);
    const snippets_path: []const u8 = blk: {
        if (snippets_dir) |d| break :blk d;
        const home = compat.getenv("HOME") orelse {
            std.debug.print("tune: HOME unset; pass --snippets <dir>\n", .{});
            return error.MissingHome;
        };
        dir_storage = try std.fmt.allocPrint(allocator, "{s}/.bobrwhisper/snippets", .{home});
        break :blk dir_storage.?;
    };

    // Filter presets up-front so we don't waste a model load.
    var active_presets = std.ArrayListUnmanaged(Preset).empty;
    defer active_presets.deinit(allocator);
    if (preset_filter) |name| {
        for (default_presets) |p| {
            if (std.mem.eql(u8, p.name, name)) {
                try active_presets.append(allocator, p);
            }
        }
        if (active_presets.items.len == 0) {
            std.debug.print("tune: preset '{s}' not found. Available: ", .{name});
            for (default_presets, 0..) |p, idx| {
                if (idx > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{p.name});
            }
            std.debug.print("\n", .{});
            return error.UnknownPreset;
        }
    } else {
        for (default_presets) |p| try active_presets.append(allocator, p);
    }

    // Discover snippets.
    var snippet_ids = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (snippet_ids.items) |id| allocator.free(id);
        snippet_ids.deinit(allocator);
    }
    try discoverSnippets(allocator, snippets_path, &snippet_ids);
    if (snippet_ids.items.len == 0) {
        std.debug.print("tune: no snippets found in {s}\n", .{snippets_path});
        return error.NoSnippets;
    }
    std.mem.sort([]u8, snippet_ids.items, {}, lessThanString);

    std.debug.print("tune: found {d} snippet(s) in {s}\n", .{ snippet_ids.items.len, snippets_path });
    std.debug.print("tune: model = {s}, presets = ", .{@tagName(selected_model)});
    for (active_presets.items, 0..) |p, idx| {
        if (idx > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{p.name});
    }
    std.debug.print("\n\n", .{});

    // Resolve model paths (auto-download if needed).
    const model_path = try selected_model.ensureDownloaded(allocator);
    defer allocator.free(model_path);
    const vad_path = cli.getVadModelPath(allocator);
    defer if (vad_path) |p| allocator.free(p);
    if (vad_path == null) {
        std.debug.print("tune: WARNING - VAD model not found at ~/.bobrwhisper/models/silero-v6.2.0.bin; VAD presets will be ignored\n\n", .{});
    }

    // Load model once; mutate VAD fields per call.
    var transcriber = try WhisperCppAdapter.init(allocator, .{
        .model_path = model_path,
        .language = "en",
        .n_threads = 4,
        .vad_enabled = false,
        .vad_model_path = vad_path,
    });
    defer transcriber.deinit();

    var results_arena = std.heap.ArenaAllocator.init(allocator);
    defer results_arena.deinit();
    const ra = results_arena.allocator();

    var results = std.ArrayListUnmanaged(Result).empty;
    defer results.deinit(allocator);

    for (snippet_ids.items) |id| {
        var snippet_arena = std.heap.ArenaAllocator.init(allocator);
        defer snippet_arena.deinit();
        const sa = snippet_arena.allocator();

        const meta = loadMeta(sa, snippets_path, id) catch |err| {
            std.debug.print("tune: skipping {s}: failed to load metadata: {}\n", .{ id, err });
            continue;
        };
        const wav_path = try std.fmt.allocPrint(sa, "{s}/{s}", .{ snippets_path, meta.audio_file });
        const samples = loadWav16(allocator, wav_path) catch |err| {
            std.debug.print("tune: skipping {s}: failed to load wav: {}\n", .{ id, err });
            continue;
        };
        defer allocator.free(samples);

        const stats = computeAudioStats(samples);
        const applied_gain = applyGain(samples, gain_mode, stats);

        std.debug.print("Snippet: {s} ({s}, {d:.2}s)\n", .{
            meta.id,
            if (meta.whisper) "whispered" else "normal",
            meta.duration_seconds,
        });
        std.debug.print("  label:  \"{s}\"\n", .{meta.label});
        std.debug.print("  device: {s} ({s})\n", .{
            meta.device orelse "(unknown)",
            meta.device_kind orelse "unknown",
        });
        if (meta.tags) |tags| if (tags.len > 0) {
            std.debug.print("  tags:   ", .{});
            for (tags, 0..) |t, idx| {
                if (idx > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{t});
            }
            std.debug.print("\n", .{});
        };
        std.debug.print("  audio:  peak={d:.4} rms={d:.4} noise_floor={d:.4} gain={d:.2}x\n", .{
            stats.peak,
            stats.rms,
            meta.noise_floor_rms,
            applied_gain,
        });

        // Persist the snippet metadata into the long-lived results arena so
        // results survive past `snippet_arena.deinit()` and we can group/sort.
        const result_id = try ra.dupe(u8, meta.id);
        const result_label = try ra.dupe(u8, meta.label);
        const result_device: ?[]const u8 = if (meta.device) |d| try ra.dupe(u8, d) else null;
        const result_device_kind: ?[]const u8 = if (meta.device_kind) |k| try ra.dupe(u8, k) else null;
        const result_tags: []const []const u8 = blk: {
            const src = meta.tags orelse break :blk &.{};
            const buf = try ra.alloc([]const u8, src.len);
            for (src, 0..) |t, ti| buf[ti] = try ra.dupe(u8, t);
            break :blk buf;
        };

        for (active_presets.items) |preset| {
            const transcript_owned = transcribeWithPreset(allocator, &transcriber, samples, preset) catch |err| {
                std.debug.print("    {s:<12} ERROR: {}\n", .{ preset.name, err });
                continue;
            };
            defer allocator.free(transcript_owned);

            const w = computeWer(allocator, meta.label, transcript_owned) catch |err| {
                std.debug.print("    {s:<12} WER ERROR: {}\n", .{ preset.name, err });
                continue;
            };

            std.debug.print("    {s:<12} WER {d:.2}  -> \"{s}\"\n", .{ preset.name, w, transcript_owned });

            try results.append(allocator, .{
                .snippet_id = result_id,
                .label = result_label,
                .whispered = meta.whisper,
                .preset = preset.name, // static literal from default_presets
                .transcript = try ra.dupe(u8, transcript_owned),
                .wer = w,
                .device = result_device,
                .device_kind = result_device_kind,
                .tags = result_tags,
            });
        }
        std.debug.print("\n", .{});
    }

    try printSummary(allocator, results.items, active_presets.items, group_by);
}

fn transcribeWithPreset(
    allocator: std.mem.Allocator,
    transcriber: *WhisperCppAdapter,
    samples: []const f32,
    preset: Preset,
) ![]u8 {
    transcriber.vad_enabled = preset.enabled;
    transcriber.vad_threshold = preset.threshold;
    transcriber.vad_min_speech_ms = preset.min_speech_ms;
    transcriber.vad_min_silence_ms = preset.min_silence_ms;
    transcriber.vad_speech_pad_ms = preset.speech_pad_ms;
    const raw = try transcriber.transcribe(samples);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    return allocator.dupe(u8, trimmed);
}

fn printSummary(allocator: std.mem.Allocator, results: []const Result, presets: []const Preset, group_by: GroupBy) !void {
    if (results.len == 0) return;

    std.debug.print("=== Summary ===\n\n", .{});

    // Best preset per snippet.
    std.debug.print("Best preset per snippet (lowest WER, ties broken by preset order):\n", .{});
    var seen_ids = std.StringHashMapUnmanaged(void).empty;
    defer seen_ids.deinit(allocator);
    for (results) |r| {
        if (seen_ids.contains(r.snippet_id)) continue;
        try seen_ids.put(allocator, r.snippet_id, {});

        var best_idx: usize = 0;
        var best_wer: f32 = std.math.inf(f32);
        for (results, 0..) |r2, j| {
            if (!std.mem.eql(u8, r2.snippet_id, r.snippet_id)) continue;
            if (r2.wer < best_wer) {
                best_wer = r2.wer;
                best_idx = j;
            }
        }
        const best = results[best_idx];
        std.debug.print("  {s} ({s}): {s:<12} WER {d:.2}  -> \"{s}\"\n", .{
            best.snippet_id,
            if (best.whispered) "whispered" else "normal",
            best.preset,
            best.wer,
            best.transcript,
        });
    }

    std.debug.print("\nPer-preset average WER:\n", .{});
    for (presets) |p| {
        var sum: f32 = 0;
        var count: usize = 0;
        for (results) |r| {
            if (std.mem.eql(u8, r.preset, p.name)) {
                sum += r.wer;
                count += 1;
            }
        }
        if (count == 0) continue;
        const avg = sum / @as(f32, @floatFromInt(count));
        std.debug.print("  {s:<12} avg WER {d:.2}  ({d} snippet(s))\n", .{ p.name, avg, count });
    }

    if (group_by == .none) {
        std.debug.print("\n", .{});
        return;
    }

    // Collect distinct group keys for the chosen axis.
    var groups = std.StringArrayHashMapUnmanaged(void).empty;
    defer groups.deinit(allocator);
    for (results) |r| {
        var keys_buf: [16][]const u8 = undefined;
        const keys = resultGroupKeys(r, group_by, &keys_buf);
        for (keys) |k| try groups.put(allocator, k, {});
    }

    std.debug.print("\nPer-preset average WER, grouped by {s}:\n", .{@tagName(group_by)});
    for (presets) |p| {
        std.debug.print("  {s}\n", .{p.name});
        var it = groups.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            var sum: f32 = 0;
            var count: usize = 0;
            for (results) |r| {
                if (!std.mem.eql(u8, r.preset, p.name)) continue;
                var keys_buf: [16][]const u8 = undefined;
                const keys = resultGroupKeys(r, group_by, &keys_buf);
                var matched = false;
                for (keys) |k| {
                    if (std.mem.eql(u8, k, key)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) continue;
                sum += r.wer;
                count += 1;
            }
            if (count == 0) continue;
            const avg = sum / @as(f32, @floatFromInt(count));
            std.debug.print("    {s:<24} avg WER {d:.2}  ({d})\n", .{ key, avg, count });
        }
    }
    std.debug.print("\n", .{});
}

/// Return the group keys a single `Result` belongs to for the chosen axis.
/// Up to `out_buf.len` keys are returned (16 is plenty: only `tag` can produce
/// multiple). `mode`/`device`/`device_kind` always produce exactly one key.
fn resultGroupKeys(r: Result, group_by: GroupBy, out_buf: []([]const u8)) []const []const u8 {
    return switch (group_by) {
        .none => out_buf[0..0],
        .mode => blk: {
            out_buf[0] = if (r.whispered) "whispered" else "normal";
            break :blk out_buf[0..1];
        },
        .device => blk: {
            out_buf[0] = r.device orelse "(unknown)";
            break :blk out_buf[0..1];
        },
        .device_kind => blk: {
            out_buf[0] = r.device_kind orelse "unknown";
            break :blk out_buf[0..1];
        },
        .tag => blk: {
            if (r.tags.len == 0) {
                out_buf[0] = "(untagged)";
                break :blk out_buf[0..1];
            }
            const n = @min(r.tags.len, out_buf.len);
            for (r.tags[0..n], 0..) |t, i| out_buf[i] = t;
            break :blk out_buf[0..n];
        },
    };
}

fn lessThanString(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn discoverSnippets(allocator: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayListUnmanaged([]u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(compat.io(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("tune: directory not found: {s}\n", .{dir_path});
            return error.NoSnippets;
        },
        else => return err,
    };
    defer dir.close(compat.io());

    var it = dir.iterate();

    while (try it.next(compat.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const id = entry.name[0 .. entry.name.len - ".json".len];
        try out.append(allocator, try allocator.dupe(u8, id));
    }
}

fn loadMeta(arena: std.mem.Allocator, dir_path: []const u8, id: []const u8) !Snippet {
    const json_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ dir_path, id });
    const file = try std.Io.Dir.cwd().openFile(compat.io(), json_path, .{});
    defer file.close(compat.io());
    const stat = try file.stat(compat.io());
    const buf = try arena.alloc(u8, stat.size);
    var io_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(compat.io(), &io_buf);
    try reader.interface.readSliceAll(buf);
    return std.json.parseFromSliceLeaky(Snippet, arena, buf, .{ .ignore_unknown_fields = true });
}

/// Read a 16-bit PCM mono WAV at any sample rate; resample to 16 kHz if needed.
fn loadWav16(allocator: std.mem.Allocator, path: []const u8) ![]f32 {
    const file = try std.Io.Dir.cwd().openFile(compat.io(), path, .{});
    defer file.close(compat.io());

    var header: [44]u8 = undefined;
    var io_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(compat.io(), &io_buf);
    try reader.interface.readSliceAll(&header);
    if (!std.mem.eql(u8, header[0..4], "RIFF") or !std.mem.eql(u8, header[8..12], "WAVE")) {
        return error.InvalidWavFile;
    }
    const channels: u16 = std.mem.readInt(u16, header[22..24], .little);
    const sample_rate: u32 = std.mem.readInt(u32, header[24..28], .little);
    const bits_per_sample: u16 = std.mem.readInt(u16, header[34..36], .little);
    if (bits_per_sample != 16) return error.UnsupportedBitDepth;

    const data_size: u32 = std.mem.readInt(u32, header[40..44], .little);
    const num_samples = data_size / (@as(u32, channels) * 2);
    const frame_bytes = @as(usize, channels) * 2;

    const raw = try allocator.alloc(u8, data_size);
    defer allocator.free(raw);
    try reader.interface.readSliceAll(raw);

    var samples = try allocator.alloc(f32, num_samples);
    errdefer allocator.free(samples);
    simd.dequantizeFromI16(raw, frame_bytes, samples);

    if (sample_rate != 16000) {
        const AudioCapture = @import("audio/AudioCapture.zig");
        const resampled = try AudioCapture.resample(allocator, samples, @floatFromInt(sample_rate), 16000.0);
        allocator.free(samples);
        return resampled;
    }
    return samples;
}

/// Lower-case, strip ASCII punctuation, collapse whitespace.
fn normalize(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, text.len);
    errdefer allocator.free(out);
    var n: usize = 0;
    var prev_space = true;
    for (text) |c| {
        const lower = std.ascii.toLower(c);
        const is_space = std.ascii.isWhitespace(lower);
        const is_punct = isPunct(lower);
        if (is_punct) {
            if (!prev_space) {
                out[n] = ' ';
                n += 1;
                prev_space = true;
            }
            continue;
        }
        if (is_space) {
            if (!prev_space) {
                out[n] = ' ';
                n += 1;
                prev_space = true;
            }
            continue;
        }
        out[n] = lower;
        n += 1;
        prev_space = false;
    }
    while (n > 0 and out[n - 1] == ' ') n -= 1;
    return allocator.realloc(out, n);
}

fn isPunct(c: u8) bool {
    return switch (c) {
        '.', ',', '?', '!', ';', ':', '"', '\'', '(', ')', '[', ']', '{', '}', '-' => true,
        else => false,
    };
}

/// Word-level WER: edit_distance(ref_words, hyp_words) / max(1, ref_words.len).
fn computeWer(allocator: std.mem.Allocator, reference: []const u8, hypothesis: []const u8) !f32 {
    const ref = try normalize(allocator, reference);
    defer allocator.free(ref);
    const hyp = try normalize(allocator, hypothesis);
    defer allocator.free(hyp);

    var ref_words = std.ArrayListUnmanaged([]const u8).empty;
    defer ref_words.deinit(allocator);
    var hyp_words = std.ArrayListUnmanaged([]const u8).empty;
    defer hyp_words.deinit(allocator);

    var it_r = std.mem.tokenizeScalar(u8, ref, ' ');
    while (it_r.next()) |w| try ref_words.append(allocator, w);
    var it_h = std.mem.tokenizeScalar(u8, hyp, ' ');
    while (it_h.next()) |w| try hyp_words.append(allocator, w);

    if (ref_words.items.len == 0) {
        return if (hyp_words.items.len == 0) 0.0 else 1.0;
    }

    const dist = try wordEditDistance(allocator, ref_words.items, hyp_words.items);
    return @as(f32, @floatFromInt(dist)) / @as(f32, @floatFromInt(ref_words.items.len));
}

fn wordEditDistance(allocator: std.mem.Allocator, a: []const []const u8, b: []const []const u8) !usize {
    const n = a.len;
    const m = b.len;
    if (n == 0) return m;
    if (m == 0) return n;

    var prev = try allocator.alloc(usize, m + 1);
    defer allocator.free(prev);
    var cur = try allocator.alloc(usize, m + 1);
    defer allocator.free(cur);

    for (0..m + 1) |j| prev[j] = j;
    for (1..n + 1) |i| {
        cur[0] = i;
        for (1..m + 1) |j| {
            const cost: usize = if (std.mem.eql(u8, a[i - 1], b[j - 1])) 0 else 1;
            const del = prev[j] + 1;
            const ins = cur[j - 1] + 1;
            const sub = prev[j - 1] + cost;
            cur[j] = @min(del, @min(ins, sub));
        }
        const tmp = prev;
        prev = cur;
        cur = tmp;
    }
    return prev[m];
}

fn printUsage() void {
    const usage =
        \\Usage: bobrwhisper-cli tune [options]
        \\
        \\Runs labeled snippets recorded with `snippet` against the Zig core
        \\under several VAD presets and reports WER vs. the ground truth.
        \\
        \\Does NOT modify any files; results are printed to stdout.
        \\
        \\Options:
        \\  --snippets <dir>    Snippet directory (default: ~/.bobrwhisper/snippets)
        \\  --model <name>      Whisper model (default: small)
        \\  --preset <name>     Run a single preset (default: all)
        \\  --gain <mode>       Pre-amplify audio: none (default), auto (peak to 0.95), or a number
        \\  --group-by <axis>   Slice the summary by: none (default), mode, device, device_kind, tag
        \\
        \\Presets: no-vad, default, whisper, low-thresh, balanced
        \\
    ;
    std.debug.print("{s}", .{usage});
}

test "normalize lower-case and punctuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("what is your name", try normalize(a, "What is your name?"));
    try std.testing.expectEqualStrings("hello world", try normalize(a, "  Hello,  WORLD!  "));
    try std.testing.expectEqualStrings("", try normalize(a, "  ...?!  "));
}

test "wer perfect match" {
    const arena_alloc = std.testing.allocator;
    const w = try computeWer(arena_alloc, "What is your name", "what is your name?");
    try std.testing.expectEqual(@as(f32, 0.0), w);
}

test "wer one substitution" {
    const w = try computeWer(std.testing.allocator, "what is your name", "what is the name");
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), w, 0.001);
}

test "wer empty hypothesis" {
    const w = try computeWer(std.testing.allocator, "what is your name", "");
    try std.testing.expectEqual(@as(f32, 1.0), w);
}

test "wer empty reference" {
    const w = try computeWer(std.testing.allocator, "", "anything goes");
    try std.testing.expectEqual(@as(f32, 1.0), w);
}
