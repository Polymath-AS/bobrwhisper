//! End-to-end benchmark for BobrWhisper's installed C API.
//!
//! It goes through libwhisper.h and links the same combined static archive that
//! `zig build libwhisper` installs, so the numbers include the ABI and
//! allocation overhead an embedding application actually pays. Being written in
//! Zig costs nothing in that respect and buys the header being run through
//! translate-c, which the hand-written C smoke test cannot check.

const std = @import("std");
const c = @import("libwhisper");
const audio = @import("audio");

const sample_rate = 16000;

const Options = struct {
    model_path: ?[:0]const u8 = null,
    audio_path: ?[:0]const u8 = null,
    language: [:0]const u8 = "en",
    vad_model_path: ?[:0]const u8 = null,
    iterations: usize = 5,
    warmup: usize = 1,
    threads: u32 = 4,
    use_gpu: bool = true,
    single_segment: bool = false,
    json: bool = false,
};

const usage_text =
    \\Usage: libwhisper-bench <model.bin> <audio.wav> [options]
    \\
    \\Benchmarks model creation and repeated transcription through the public
    \\libwhisper C ABI. Audio must be 16 kHz PCM16 or float32 WAV.
    \\
    \\Options:
    \\  -n, --iterations <count>  Measured runs (default: 5)
    \\  -w, --warmup <count>      Unmeasured warmup runs (default: 1)
    \\  -t, --threads <count>     Decoder threads (default: 4)
    \\  -l, --language <code>     Language code (default: en)
    \\      --cpu                 Disable GPU acceleration
    \\      --vad-model <path>    Enable VAD with this model
    \\      --single-segment      Use the live/single-segment decoder path
    \\      --json                Emit one JSON object to stdout
    \\  -h, --help                Show this help
    \\
;

/// Emitted verbatim as the `--json` payload, so field names are the output
/// schema.
const Report = struct {
    library_version: []const u8,
    model: []const u8,
    audio: []const u8,
    audio_seconds: f64,
    samples: usize,
    iterations: usize,
    warmup: usize,
    threads: u32,
    gpu: bool,
    vad: bool,
    single_segment: bool,
    model_load_seconds: f64,
    mean_seconds: f64,
    median_seconds: f64,
    min_seconds: f64,
    max_seconds: f64,
    p95_seconds: f64,
    standard_deviation_seconds: f64,
    realtime_factor: f64,
    audio_seconds_per_second: f64,
    transcript_bytes: usize,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    const options = parseOptions(args, stdout, stderr) catch |err| switch (err) {
        error.HelpRequested => return,
        else => return err,
    };

    const samples = try loadWav(gpa, io, options.audio_path.?, stderr);
    defer gpa.free(samples);
    if (samples.len == 0) {
        try stderr.print("audio file contains no samples\n", .{});
        return error.NoAudio;
    }
    const audio_seconds = @as(f64, @floatFromInt(samples.len)) / sample_rate;

    c.libwhisper_set_log_handler(libraryLog, null);
    defer c.libwhisper_set_log_handler(null, null);

    var config: c.libwhisper_config_s = undefined;
    c.libwhisper_config_init(&config);
    config.model_path = options.model_path.?.ptr;
    config.language = options.language.ptr;
    config.thread_count = options.threads;
    config.use_gpu = options.use_gpu;
    config.vad_enabled = options.vad_model_path != null;
    if (options.vad_model_path) |path| config.vad_model_path = path.ptr;

    var transcriber: ?*c.libwhisper_t = null;
    const load_start = std.Io.Timestamp.now(io, .awake);
    const create_error = c.libwhisper_create(&config, &transcriber);
    const load_seconds = secondsSince(io, load_start);
    if (create_error != c.LIBWHISPER_SUCCESS) {
        try stderr.print("libwhisper_create failed: {s}\n", .{c.libwhisper_error_string(create_error)});
        return error.CreateFailed;
    }
    defer c.libwhisper_destroy(transcriber);

    const transcribe_options: c.libwhisper_transcribe_options_s = .{
        .language = options.language.ptr,
        .single_segment = options.single_segment,
    };

    for (0..options.warmup) |i| {
        var text: c.libwhisper_string_s = undefined;
        const err = c.libwhisper_transcribe(transcriber, samples.ptr, samples.len, &transcribe_options, &text);
        if (err != c.LIBWHISPER_SUCCESS) {
            try stderr.print("warmup {d} failed: {s}\n", .{ i + 1, c.libwhisper_error_string(err) });
            return error.TranscribeFailed;
        }
        c.libwhisper_string_free(text);
    }

    const times = try gpa.alloc(f64, options.iterations);
    defer gpa.free(times);

    var last_text: c.libwhisper_string_s = .{ .ptr = null, .len = 0 };
    defer c.libwhisper_string_free(last_text);
    for (times, 0..) |*slot, i| {
        // Release the previous transcript before timing the next run so the free
        // is not attributed to it. The final one is kept for reporting.
        if (i > 0) {
            c.libwhisper_string_free(last_text);
            last_text = .{ .ptr = null, .len = 0 };
        }
        const start = std.Io.Timestamp.now(io, .awake);
        const err = c.libwhisper_transcribe(transcriber, samples.ptr, samples.len, &transcribe_options, &last_text);
        slot.* = secondsSince(io, start);
        if (err != c.LIBWHISPER_SUCCESS) {
            try stderr.print("iteration {d} failed: {s}\n", .{ i + 1, c.libwhisper_error_string(err) });
            return error.TranscribeFailed;
        }
    }

    const stats = Stats.compute(gpa, times) catch |err| {
        try stderr.print("out of memory computing statistics\n", .{});
        return err;
    };
    defer stats.deinit(gpa);

    const report: Report = .{
        .library_version = std.mem.span(c.libwhisper_version()),
        .model = options.model_path.?,
        .audio = options.audio_path.?,
        .audio_seconds = audio_seconds,
        .samples = samples.len,
        .iterations = options.iterations,
        .warmup = options.warmup,
        .threads = options.threads,
        .gpu = options.use_gpu,
        .vad = options.vad_model_path != null,
        .single_segment = options.single_segment,
        .model_load_seconds = load_seconds,
        .mean_seconds = stats.mean,
        .median_seconds = stats.median,
        .min_seconds = stats.min,
        .max_seconds = stats.max,
        .p95_seconds = stats.p95,
        .standard_deviation_seconds = stats.standard_deviation,
        .realtime_factor = stats.mean / audio_seconds,
        .audio_seconds_per_second = audio_seconds / stats.mean,
        .transcript_bytes = last_text.len,
    };

    if (options.json) {
        try std.json.Stringify.value(report, .{}, stdout);
        try stdout.print("\n", .{});
    } else {
        try stdout.print(
            \\libwhisper {s} benchmark
            \\  input:       {d:.3} s ({d} samples)
            \\  config:      {d} threads, {s}, VAD {s}, single segment {s}
            \\  model load:  {d:.3} s
            \\  runs:        {d} measured, {d} warmup
            \\  latency:     {d:.3} s mean ± {d:.3} s (median {d:.3}, min {d:.3}, p95 {d:.3}, max {d:.3})
            \\  throughput:  {d:.3}x realtime (RTF {d:.4})
            \\  transcript:  {s}
            \\
        , .{
            report.library_version,
            report.audio_seconds,
            report.samples,
            report.threads,
            if (report.gpu) "GPU" else "CPU",
            if (report.vad) "on" else "off",
            if (report.single_segment) "on" else "off",
            report.model_load_seconds,
            report.iterations,
            report.warmup,
            report.mean_seconds,
            report.standard_deviation_seconds,
            report.median_seconds,
            report.min_seconds,
            report.p95_seconds,
            report.max_seconds,
            report.audio_seconds_per_second,
            report.realtime_factor,
            if (last_text.ptr) |ptr| std.mem.span(ptr) else "(empty)",
        });
    }
    try stdout.flush();
}

fn secondsSince(io: std.Io, start: std.Io.Timestamp) f64 {
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake));
    return @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s;
}

fn libraryLog(level: c_int, message: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    // Diagnostics go to stderr so --json keeps stdout to a single object.
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(std.Io.Threaded.global_single_threaded.io(), &buf);
    writer.interface.print("libwhisper[{d}]: {s}\n", .{ level, message }) catch return;
    writer.interface.flush() catch {};
}

const Stats = struct {
    mean: f64,
    median: f64,
    min: f64,
    max: f64,
    p95: f64,
    standard_deviation: f64,
    sorted: []f64,

    fn compute(gpa: std.mem.Allocator, times: []const f64) !Stats {
        std.debug.assert(times.len > 0);
        const sorted = try gpa.dupe(f64, times);
        std.mem.sort(f64, sorted, {}, std.sort.asc(f64));

        var total: f64 = 0;
        for (times) |t| total += t;
        const mean = total / @as(f64, @floatFromInt(times.len));

        var variance: f64 = 0;
        for (times) |t| {
            const delta = t - mean;
            variance += delta * delta;
        }

        return .{
            .mean = mean,
            .median = if (times.len % 2 == 0)
                (sorted[times.len / 2 - 1] + sorted[times.len / 2]) / 2
            else
                sorted[times.len / 2],
            .min = sorted[0],
            .max = sorted[times.len - 1],
            .p95 = percentile(sorted, 0.95),
            .standard_deviation = @sqrt(variance / @as(f64, @floatFromInt(times.len))),
            .sorted = sorted,
        };
    }

    fn deinit(self: Stats, gpa: std.mem.Allocator) void {
        gpa.free(self.sorted);
    }
};

fn percentile(sorted: []const f64, fraction: f64) f64 {
    const rank = @ceil(fraction * @as(f64, @floatFromInt(sorted.len)));
    const index: usize = @intFromFloat(@max(1, rank));
    return sorted[@min(index - 1, sorted.len - 1)];
}

fn parseOptions(
    args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (eq(arg, "-h") or eq(arg, "--help")) {
            try stdout.print("{s}", .{usage_text});
            try stdout.flush();
            return error.HelpRequested;
        } else if (eq(arg, "--cpu")) {
            options.use_gpu = false;
        } else if (eq(arg, "--single-segment")) {
            options.single_segment = true;
        } else if (eq(arg, "--json")) {
            options.json = true;
        } else if (eq(arg, "-n") or eq(arg, "--iterations")) {
            options.iterations = try requireCount(args, &index, stderr, .positive);
        } else if (eq(arg, "-w") or eq(arg, "--warmup")) {
            options.warmup = try requireCount(args, &index, stderr, .any);
        } else if (eq(arg, "-t") or eq(arg, "--threads")) {
            const value = try requireCount(args, &index, stderr, .positive);
            if (value > std.math.maxInt(u32)) {
                try stderr.print("invalid thread count: {s}\n", .{args[index]});
                return error.InvalidArgument;
            }
            options.threads = @intCast(value);
        } else if (eq(arg, "-l") or eq(arg, "--language")) {
            options.language = try requireValue(args, &index, stderr);
        } else if (eq(arg, "--vad-model")) {
            options.vad_model_path = try requireValue(args, &index, stderr);
        } else if (arg.len > 0 and arg[0] == '-') {
            try stderr.print("unknown option: {s}\n", .{arg});
            return error.InvalidArgument;
        } else if (options.model_path == null) {
            options.model_path = arg;
        } else if (options.audio_path == null) {
            options.audio_path = arg;
        } else {
            try stderr.print("unexpected argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    if (options.model_path == null or options.audio_path == null) {
        try stderr.print("{s}", .{usage_text});
        return error.InvalidArgument;
    }
    return options;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn requireValue(args: []const [:0]const u8, index: *usize, stderr: *std.Io.Writer) ![:0]const u8 {
    const flag = args[index.*];
    index.* += 1;
    if (index.* >= args.len) {
        try stderr.print("{s} requires a value\n", .{flag});
        return error.InvalidArgument;
    }
    return args[index.*];
}

fn requireCount(
    args: []const [:0]const u8,
    index: *usize,
    stderr: *std.Io.Writer,
    allow: enum { any, positive },
) !usize {
    const flag = args[index.*];
    const text = try requireValue(args, index, stderr);
    const value = std.fmt.parseInt(usize, text, 10) catch {
        try stderr.print("invalid value for {s}: {s}\n", .{ flag, text });
        return error.InvalidArgument;
    };
    if (allow == .positive and value == 0) {
        try stderr.print("{s} must be greater than zero\n", .{flag});
        return error.InvalidArgument;
    }
    return value;
}

/// Decodes 16 kHz PCM16 or float32 RIFF/WAVE, downmixing to mono.
/// Decode via the audio library rather than a parser embedded here: the WAV
/// handling, the 16 kHz requirement and the mono downmix are all things the
/// capture path needs too, so there is one implementation with its own tests.
fn loadWav(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    stderr: *std.Io.Writer,
) ![]f32 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 * 1024 * 1024)) catch |err| {
        try stderr.print("cannot read audio file {s}: {t}\n", .{ path, err });
        return err;
    };
    defer gpa.free(bytes);

    const decoded = audio.wav.decode(gpa, bytes, null) catch |err| {
        try stderr.print("cannot decode {s}: {t}\n", .{ path, err });
        return err;
    };
    // Benchmarking a resample would measure the wrong thing, so require the rate
    // the library is built around instead of silently converting.
    if (decoded.sample_rate != sample_rate) {
        defer decoded.deinit(gpa);
        try stderr.print(
            "{s}: expected {d} Hz, got {d} Hz ({d} channels, {d}-bit)\n",
            .{ path, sample_rate, decoded.sample_rate, decoded.source.channels, decoded.source.bits_per_sample },
        );
        return error.UnsupportedWav;
    }
    return decoded.samples;
}
