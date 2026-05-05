//! Snippet recorder - capture labeled audio for the test corpus.
//!
//! The CLI does NOT transcribe; it only records audio plus end-user metadata.
//! Each snippet is written as a sibling pair so experiment code can mmap one
//! and read the other:
//!
//!   <out>/<id>.wav   16 kHz mono 16-bit PCM WAV
//!   <out>/<id>.json  ground truth label + whisper flag + audio stats
//!
//! Default output dir is `~/.bobrwhisper/snippets`.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const AudioCapture = @import("audio/AudioCapture.zig");
const AudioDevice = @import("audio/AudioDevice.zig");

const sample_rate: u32 = 16000;

pub const Args = struct {
    label: ?[]const u8 = null,
    whisper: ?bool = null,
    out_dir: ?[]const u8 = null,
    duration_secs: ?u64 = null,
    device: ?[]const u8 = null,
    device_kind: ?AudioDevice.Kind = null,
    tags: []const []const u8 = &.{},
};

const ParseError = error{
    UnknownArg,
    MissingValue,
    InvalidDuration,
    InvalidDeviceKind,
    ConflictingFlags,
    HelpRequested,
    OutOfMemory,
};

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8, tags_out: *std.ArrayListUnmanaged([]const u8)) ParseError!Args {
    var out: Args = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, a, "--label")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.label = args[i];
        } else if (std.mem.eql(u8, a, "--whisper")) {
            if (out.whisper) |w| if (!w) return error.ConflictingFlags;
            out.whisper = true;
        } else if (std.mem.eql(u8, a, "--no-whisper")) {
            if (out.whisper) |w| if (w) return error.ConflictingFlags;
            out.whisper = false;
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.out_dir = args[i];
        } else if (std.mem.eql(u8, a, "--duration")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.duration_secs = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidDuration;
        } else if (std.mem.eql(u8, a, "--device")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.device = args[i];
        } else if (std.mem.eql(u8, a, "--device-kind")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.device_kind = AudioDevice.Kind.fromString(args[i]) orelse return error.InvalidDeviceKind;
        } else if (std.mem.eql(u8, a, "--tag")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            try tags_out.append(allocator, args[i]);
        } else {
            std.debug.print("snippet: unknown argument '{s}'\n", .{a});
            return error.UnknownArg;
        }
    }
    out.tags = tags_out.items;
    return out;
}

pub fn run(allocator: std.mem.Allocator, raw_args: []const []const u8) !void {
    var tag_list = std.ArrayListUnmanaged([]const u8).empty;
    defer tag_list.deinit(allocator);

    const parsed = parseArgs(allocator, raw_args, &tag_list) catch |err| switch (err) {
        error.HelpRequested => {
            printUsage();
            return;
        },
        else => {
            std.debug.print("\n", .{});
            printUsage();
            return err;
        },
    };

    if (builtin.os.tag != .macos) {
        std.debug.print("snippet: audio capture is only supported on macOS\n", .{});
        return error.UnsupportedPlatform;
    }

    // Resolve metadata: prompt for anything not passed on the CLI.
    var label_storage: ?[]u8 = null;
    defer if (label_storage) |s| allocator.free(s);
    const label: []const u8 = blk: {
        if (parsed.label) |l| break :blk l;
        label_storage = try promptLine(allocator, "Ground truth label (what will you say?): ");
        break :blk label_storage.?;
    };
    if (label.len == 0) {
        std.debug.print("snippet: label cannot be empty\n", .{});
        return error.EmptyLabel;
    }

    const whisper: bool = parsed.whisper orelse try promptYesNo("Whispered? [y/N]: ", false);

    // Resolve audio device: explicit CLI override takes priority; otherwise
    // probe CoreAudio for the default input. detected_info is null on non-macOS
    // or when CoreAudio refuses (no device, headless), in which case we leave
    // the device fields null in the metadata.
    const detected_info: ?AudioDevice.Info = AudioDevice.detectDefaultInput(allocator);
    defer if (detected_info) |d| d.deinit(allocator);

    const device: ?[]const u8 = parsed.device orelse if (detected_info) |d| d.name else null;
    const device_kind: ?AudioDevice.Kind = parsed.device_kind orelse if (detected_info) |d| d.kind else null;

    // Resolve output directory.
    var out_dir_storage: ?[]u8 = null;
    defer if (out_dir_storage) |s| allocator.free(s);
    const out_dir: []const u8 = blk: {
        if (parsed.out_dir) |d| break :blk d;
        const home = compat.getenv("HOME") orelse {
            std.debug.print("snippet: HOME is unset; pass --out <dir>\n", .{});
            return error.MissingHome;
        };
        out_dir_storage = try std.fmt.allocPrint(allocator, "{s}/.bobrwhisper/snippets", .{home});
        break :blk out_dir_storage.?;
    };
    try ensureDir(out_dir);

    // Build the snippet ID from the wall-clock timestamp.
    const created_at_ms = compat.milliTimestamp();
    const id = try formatSnippetId(allocator, created_at_ms);
    defer allocator.free(id);

    const wav_path = try std.fmt.allocPrint(allocator, "{s}/{s}.wav", .{ out_dir, id });
    defer allocator.free(wav_path);
    const json_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ out_dir, id });
    defer allocator.free(json_path);

    std.debug.print("\nSnippet: {s}\n", .{id});
    std.debug.print("  label:    {s}\n", .{label});
    std.debug.print("  whisper:  {}\n", .{whisper});
    std.debug.print("  device:   {s} ({s})\n", .{
        device orelse "(unknown)",
        if (device_kind) |k| @tagName(k) else "unknown",
    });
    if (parsed.tags.len > 0) {
        std.debug.print("  tags:     ", .{});
        for (parsed.tags, 0..) |t, idx| {
            if (idx > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{t});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("  out:      {s}\n\n", .{out_dir});

    // Start recording.
    var audio = try AudioCapture.init(allocator);
    defer audio.deinit();
    try audio.start();

    if (parsed.duration_secs) |secs| {
        std.debug.print("Recording for {d}s...\n", .{secs});
        try recordFixed(&audio, secs);
    } else {
        std.debug.print("Recording... press 'q' then Enter to stop.\n", .{});
        try recordUntilQ(&audio);
    }

    audio.stop();

    const samples = audio.getSamples();
    if (samples.len == 0) {
        std.debug.print("snippet: no audio captured; aborting\n", .{});
        return error.NoAudio;
    }

    const duration_seconds = @as(f64, @floatFromInt(samples.len)) / @as(f64, @floatFromInt(sample_rate));
    const noise_floor = AudioCapture.computeNoiseFloor(samples);

    std.debug.print("\nCaptured {d} samples ({d:.2}s, noise floor {d:.6})\n", .{ samples.len, duration_seconds, noise_floor });

    try writeWav(wav_path, samples);
    try writeMetadata(allocator, json_path, .{
        .id = id,
        .label = label,
        .whisper = whisper,
        .audio_file = std.fs.path.basename(wav_path),
        .duration_seconds = duration_seconds,
        .sample_rate = sample_rate,
        .channels = 1,
        .num_samples = samples.len,
        .noise_floor_rms = noise_floor,
        .created_at_unix_ms = created_at_ms,
        .device = device,
        .device_kind = device_kind,
        .tags = parsed.tags,
    });

    std.debug.print("\nSaved:\n  {s}\n  {s}\n", .{ wav_path, json_path });
}

const Metadata = struct {
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
    /// Free-form device label (e.g. "MacBook Pro Microphone", "AirPods Pro").
    device: ?[]const u8,
    /// Coarse device classification for slicing the test corpus.
    device_kind: ?AudioDevice.Kind,
    /// Free-form tags so experiments can group snippets by content/condition.
    tags: []const []const u8,
};

fn writeMetadata(allocator: std.mem.Allocator, path: []const u8, meta: Metadata) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, meta, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const file = try std.Io.Dir.cwd().createFile(compat.io(), path, .{});
    defer file.close(compat.io());
    try file.writeStreamingAll(compat.io(), json);
    try file.writeStreamingAll(compat.io(), "\n");
}

/// Encode 32-bit float mono samples to a 16-bit PCM WAV file at `sample_rate`.
fn writeWav(path: []const u8, samples: []const f32) !void {
    const channels: u16 = 1;
    const bits_per_sample: u16 = 16;
    const byte_rate: u32 = sample_rate * channels * (bits_per_sample / 8);
    const block_align: u16 = channels * (bits_per_sample / 8);
    const data_size: u32 = @intCast(samples.len * @sizeOf(i16));
    const riff_size: u32 = 36 + data_size;

    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], riff_size, .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little); // PCM fmt chunk size
    std.mem.writeInt(u16, header[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, header[22..24], channels, .little);
    std.mem.writeInt(u32, header[24..28], sample_rate, .little);
    std.mem.writeInt(u32, header[28..32], byte_rate, .little);
    std.mem.writeInt(u16, header[32..34], block_align, .little);
    std.mem.writeInt(u16, header[34..36], bits_per_sample, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_size, .little);

    const file = try std.Io.Dir.cwd().createFile(compat.io(), path, .{});
    defer file.close(compat.io());

    try file.writeStreamingAll(compat.io(), &header);

    // Stream-convert samples in chunks to bound stack/heap usage.
    var chunk: [4096]i16 = undefined;
    var i: usize = 0;
    while (i < samples.len) {
        const n = @min(chunk.len, samples.len - i);
        for (0..n) |k| {
            const clamped = std.math.clamp(samples[i + k], -1.0, 1.0);
            chunk[k] = @intFromFloat(clamped * 32767.0);
        }
        try file.writeStreamingAll(compat.io(), std.mem.sliceAsBytes(chunk[0..n]));
        i += n;
    }
}

fn ensureDir(path: []const u8) !void {
    std.debug.assert(std.fs.path.isAbsolute(path));
    std.Io.Dir.cwd().createDirPath(compat.io(), path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
}

fn formatSnippetId(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const millis: u64 = @intCast(@mod(ms, 1000));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch_seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const ds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}{d:0>3}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        millis,
    });
}

fn promptLine(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(compat.io(), prompt);

    const stdin = std.Io.File.stdin();
    var io_buf: [4096]u8 = undefined;
    var reader = stdin.readerStreaming(compat.io(), &io_buf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return error.NoInput,
        else => return err,
    };
    return allocator.dupe(u8, std.mem.trim(u8, line, " \t\r"));
}

fn promptYesNo(prompt: []const u8, default_yes: bool) !bool {
    var tiny_alloc_buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tiny_alloc_buf);
    const reply = try promptLine(fba.allocator(), prompt);
    if (reply.len == 0) return default_yes;
    return reply[0] == 'y' or reply[0] == 'Y';
}

fn recordFixed(audio: *AudioCapture, duration_secs: u64) !void {
    const total_ns = duration_secs * std.time.ns_per_s;
    const tick_ns: u64 = 100 * std.time.ns_per_ms;
    var elapsed_ns: u64 = 0;
    while (elapsed_ns < total_ns) {
        compat.sleepNanoseconds(tick_ns);
        elapsed_ns += tick_ns;
        printLevel(audio);
    }
    std.debug.print("\n", .{});
}

pub fn recordUntilQ(audio: *AudioCapture) !void {
    const stdin_fd: c_int = @intCast(std.Io.File.stdin().handle);
    const flags = fcntl(stdin_fd, F_GETFL);
    _ = fcntl(stdin_fd, F_SETFL, flags | O_NONBLOCK);
    defer _ = fcntl(stdin_fd, F_SETFL, flags);

    var stop = false;
    while (!stop) {
        compat.sleepNanoseconds(100 * std.time.ns_per_ms);
        printLevel(audio);

        var buf: [16]u8 = undefined;
        const n = read_c(stdin_fd, &buf, buf.len);
        if (n > 0) {
            for (buf[0..@intCast(n)]) |byte| {
                if (byte == 'q' or byte == 'Q') {
                    stop = true;
                    break;
                }
            }
        }
    }
    std.debug.print("\n", .{});
}

fn printLevel(audio: *AudioCapture) void {
    const level = audio.getAudioLevel();
    const bar_len: usize = @intFromFloat(@min(level * 200.0, 40.0));
    var bar: [40]u8 = [_]u8{'.'} ** 40;
    for (0..bar_len) |i| bar[i] = '#';
    const sample_count = audio.getSampleCount();
    std.debug.print("\r  level [{s}] {d:.4} samples={d}    ", .{ &bar, level, sample_count });
}

fn printUsage() void {
    const usage =
        \\Usage: bobrwhisper-cli snippet [options]
        \\
        \\Records a single audio snippet with end-user metadata for the
        \\test corpus. Does NOT transcribe.
        \\
        \\Options:
        \\  --label <text>          Ground truth label (interactive if omitted)
        \\  --whisper               Mark snippet as whispered audio
        \\  --no-whisper            Mark snippet as normal voice
        \\  --duration <secs>       Record fixed duration; otherwise stop on 'q'
        \\  --out <dir>             Output directory (default: ~/.bobrwhisper/snippets)
        \\  --device <name>         Override auto-detected device label
        \\  --device-kind <kind>    internal | bluetooth | usb | unknown
        \\  --tag <name>            Add a tag (repeatable)
        \\
        \\Saves <out>/<id>.wav (16 kHz mono 16-bit PCM) and <out>/<id>.json.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
const read_c = read;
const F_GETFL = 3;
const F_SETFL = 4;
const O_NONBLOCK = 0x0004; // macOS

test "parseArgs basic" {
    var tags = std.ArrayListUnmanaged([]const u8).empty;
    defer tags.deinit(std.testing.allocator);
    const args = [_][]const u8{ "--label", "hello", "--whisper", "--duration", "5" };
    const parsed = try parseArgs(std.testing.allocator, &args, &tags);
    try std.testing.expectEqualStrings("hello", parsed.label.?);
    try std.testing.expectEqual(true, parsed.whisper.?);
    try std.testing.expectEqual(@as(u64, 5), parsed.duration_secs.?);
}

test "parseArgs no-whisper default" {
    var tags = std.ArrayListUnmanaged([]const u8).empty;
    defer tags.deinit(std.testing.allocator);
    const args = [_][]const u8{ "--label", "x", "--no-whisper" };
    const parsed = try parseArgs(std.testing.allocator, &args, &tags);
    try std.testing.expectEqual(false, parsed.whisper.?);
}

test "parseArgs conflicting flags" {
    var tags = std.ArrayListUnmanaged([]const u8).empty;
    defer tags.deinit(std.testing.allocator);
    const args = [_][]const u8{ "--whisper", "--no-whisper" };
    try std.testing.expectError(error.ConflictingFlags, parseArgs(std.testing.allocator, &args, &tags));
}

test "parseArgs device + tags" {
    var tags = std.ArrayListUnmanaged([]const u8).empty;
    defer tags.deinit(std.testing.allocator);
    const args = [_][]const u8{
        "--label", "x",
        "--device", "AirPods Pro",
        "--device-kind", "bluetooth",
        "--tag", "whispered",
        "--tag", "technical",
    };
    const parsed = try parseArgs(std.testing.allocator, &args, &tags);
    try std.testing.expectEqualStrings("AirPods Pro", parsed.device.?);
    try std.testing.expectEqual(AudioDevice.Kind.bluetooth, parsed.device_kind.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.tags.len);
    try std.testing.expectEqualStrings("whispered", parsed.tags[0]);
    try std.testing.expectEqualStrings("technical", parsed.tags[1]);
}

test "parseArgs invalid device kind" {
    var tags = std.ArrayListUnmanaged([]const u8).empty;
    defer tags.deinit(std.testing.allocator);
    const args = [_][]const u8{ "--device-kind", "carrier-pigeon" };
    try std.testing.expectError(error.InvalidDeviceKind, parseArgs(std.testing.allocator, &args, &tags));
}

test "formatSnippetId is sortable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try formatSnippetId(arena.allocator(), 1_700_000_000_000);
    const b = try formatSnippetId(arena.allocator(), 1_700_000_001_500);
    try std.testing.expect(std.mem.lessThan(u8, a, b));
    try std.testing.expectEqual(@as(usize, 19), a.len); // YYYYMMDDTHHMMSSmmmZ
}
