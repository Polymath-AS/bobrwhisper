//! C ABI for the capture library.
//!
//! Same boundary rules as the other two: non-exhaustive error enum, options with
//! a `struct_size`, outputs cleared before any work, every entry point tolerant
//! of NULL.
//!
//! The API is polled rather than callback-driven, which matters most here. A
//! callback would run on the audio thread, where an embedder that blocks,
//! allocates or takes a lock causes dropouts — and across a C ABI there is no
//! way to stop one from doing exactly that. Instead the backend fills a ring and
//! `read` drains it whenever the caller likes. Falling behind costs you old
//! audio, reported by `dropped_samples`, not a glitch in the recording.

const std = @import("std");
const capture = @import("capture");

const allocator = std.heap.c_allocator;

const version = "0.1.0";

const Error = enum(c_int) {
    success = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    unsupported_platform = 3,
    device_not_found = 4,
    open_failed = 5,
    already_running = 6,
    unknown = 255,
    _,
};

const Options = extern struct {
    struct_size: usize,
    sample_rate: u32,
    channels: u16,
    buffer_ms: u32,
    /// NUL-terminated, backend-specific. NULL selects the default input.
    device_id: ?[*:0]const u8,
};

const DeviceList = extern struct {
    devices: ?[*]Device,
    count: usize,
};

const Device = extern struct {
    /// NUL-terminated; pass back through `Options.device_id`.
    id: [*:0]const u8,
    name: [*:0]const u8,
    is_default: bool,
};

pub export fn bobrwhisper_capture_version() [*:0]const u8 {
    return version;
}

pub export fn bobrwhisper_capture_error_string(err: Error) [*:0]const u8 {
    return switch (err) {
        .success => "success",
        .invalid_argument => "invalid argument",
        .out_of_memory => "out of memory",
        .unsupported_platform => "audio capture is not implemented for this platform",
        .device_not_found => "audio input device not found",
        .open_failed => "could not open the audio input device",
        .already_running => "capture is already running",
        .unknown => "unknown error",
        _ => "unrecognized error code",
    };
}

/// True when this build has a real backend. A caller can use it to disable a
/// recording UI up front rather than discovering it at `open`.
pub export fn bobrwhisper_capture_is_supported() bool {
    return capture.backend.supported;
}

pub export fn bobrwhisper_capture_options_init(options: ?*Options) void {
    const out = options orelse return;
    const defaults: capture.Options = .{};
    out.* = .{
        .struct_size = @sizeOf(Options),
        .sample_rate = defaults.sample_rate,
        .channels = defaults.channels,
        .buffer_ms = defaults.buffer_ms,
        .device_id = null,
    };
}

pub export fn bobrwhisper_capture_open(
    options: ?*const Options,
    out_stream: ?*?*capture.Stream,
) Error {
    const out = out_stream orelse return .invalid_argument;
    out.* = null;

    var zig_options: capture.Options = .{};
    if (options) |opts| {
        if (opts.struct_size != @sizeOf(Options)) return .invalid_argument;
        if (opts.sample_rate == 0 or opts.channels == 0) return .invalid_argument;
        zig_options = .{
            .sample_rate = opts.sample_rate,
            .channels = opts.channels,
            .buffer_ms = opts.buffer_ms,
            .device_id = if (opts.device_id) |id| std.mem.span(id) else null,
        };
    }

    const stream = capture.Stream.open(allocator, zig_options) catch |err| return mapError(err);
    out.* = stream;
    return .success;
}

pub export fn bobrwhisper_capture_close(stream: ?*capture.Stream) void {
    const handle = stream orelse return;
    handle.close();
}

pub export fn bobrwhisper_capture_start(stream: ?*capture.Stream) Error {
    const handle = stream orelse return .invalid_argument;
    handle.start() catch |err| return mapError(err);
    return .success;
}

pub export fn bobrwhisper_capture_stop(stream: ?*capture.Stream) void {
    const handle = stream orelse return;
    handle.stop();
}

pub export fn bobrwhisper_capture_is_running(stream: ?*capture.Stream) bool {
    const handle = stream orelse return false;
    return handle.isRunning();
}

/// Copy out up to `max_samples` captured samples, oldest first. Returns how many
/// were written; 0 means nothing has arrived yet, which is not an error.
pub export fn bobrwhisper_capture_read(
    stream: ?*capture.Stream,
    out_samples: ?[*]f32,
    max_samples: usize,
) usize {
    const handle = stream orelse return 0;
    const out = out_samples orelse return 0;
    return handle.read(out[0..max_samples]);
}

pub export fn bobrwhisper_capture_available(stream: ?*capture.Stream) usize {
    const handle = stream orelse return 0;
    return handle.available();
}

/// Samples lost because the consumer did not keep up. Non-zero means read is
/// being called too slowly, or buffer_ms is too small.
pub export fn bobrwhisper_capture_dropped_samples(stream: ?*capture.Stream) u64 {
    const handle = stream orelse return 0;
    return handle.dropped();
}

/// Enumerate input devices. Release with `bobrwhisper_capture_free_devices`.
pub export fn bobrwhisper_capture_list_devices(out_list: ?*DeviceList) Error {
    const out = out_list orelse return .invalid_argument;
    out.* = .{ .devices = null, .count = 0 };

    const found = capture.listDevices(allocator) catch |err| return mapError(err);
    defer capture.freeDevices(allocator, found);
    if (found.len == 0) return .success;

    // Re-copy into NUL-terminated C strings; the Zig side uses slices.
    const devices = allocator.alloc(Device, found.len) catch return .out_of_memory;
    var filled: usize = 0;
    errdefer {
        for (devices[0..filled]) |device| {
            allocator.free(std.mem.span(device.id));
            allocator.free(std.mem.span(device.name));
        }
        allocator.free(devices);
    }

    for (found, 0..) |device, i| {
        const id = allocator.dupeZ(u8, device.id) catch return .out_of_memory;
        errdefer allocator.free(id);
        const name = allocator.dupeZ(u8, device.name) catch return .out_of_memory;
        devices[i] = .{ .id = id.ptr, .name = name.ptr, .is_default = device.is_default };
        filled += 1;
    }

    out.* = .{ .devices = devices.ptr, .count = found.len };
    return .success;
}

pub export fn bobrwhisper_capture_free_devices(list: DeviceList) void {
    const devices = list.devices orelse return;
    for (devices[0..list.count]) |device| {
        allocator.free(std.mem.span(device.id));
        allocator.free(std.mem.span(device.name));
    }
    allocator.free(devices[0..list.count]);
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.UnsupportedPlatform => .unsupported_platform,
        error.DeviceNotFound => .device_not_found,
        error.OpenFailed => .open_failed,
        error.AlreadyRunning => .already_running,
        else => .unknown,
    };
}

test "error_string never faults on an unrecognized code" {
    const bogus: Error = @enumFromInt(9001);
    try std.testing.expectEqualStrings(
        "unrecognized error code",
        std.mem.span(bobrwhisper_capture_error_string(bogus)),
    );
    try std.testing.expectEqualStrings(
        "audio capture is not implemented for this platform",
        std.mem.span(bobrwhisper_capture_error_string(.unsupported_platform)),
    );
}

test "null arguments are rejected rather than dereferenced" {
    try std.testing.expectEqual(Error.invalid_argument, bobrwhisper_capture_open(null, null));
    try std.testing.expectEqual(Error.invalid_argument, bobrwhisper_capture_start(null));
    try std.testing.expectEqual(Error.invalid_argument, bobrwhisper_capture_list_devices(null));
    try std.testing.expect(!bobrwhisper_capture_is_running(null));
    try std.testing.expectEqual(@as(usize, 0), bobrwhisper_capture_available(null));
    try std.testing.expectEqual(@as(u64, 0), bobrwhisper_capture_dropped_samples(null));
    try std.testing.expectEqual(@as(usize, 0), bobrwhisper_capture_read(null, null, 0));
    bobrwhisper_capture_close(null);
    bobrwhisper_capture_stop(null);
    bobrwhisper_capture_options_init(null);
    bobrwhisper_capture_free_devices(.{ .devices = null, .count = 0 });
}

test "options_init stamps struct_size and a stale one is rejected" {
    var options: Options = undefined;
    bobrwhisper_capture_options_init(&options);
    try std.testing.expectEqual(@sizeOf(Options), options.struct_size);
    try std.testing.expectEqual(@as(u32, 16000), options.sample_rate);
    try std.testing.expect(options.device_id == null);

    var stream: ?*capture.Stream = @ptrFromInt(0x1000);
    options.struct_size -= 1;
    try std.testing.expectEqual(Error.invalid_argument, bobrwhisper_capture_open(&options, &stream));
    try std.testing.expect(stream == null);
}

test "nonsense options are rejected" {
    var options: Options = undefined;
    bobrwhisper_capture_options_init(&options);
    var stream: ?*capture.Stream = null;

    options.sample_rate = 0;
    try std.testing.expectEqual(Error.invalid_argument, bobrwhisper_capture_open(&options, &stream));

    bobrwhisper_capture_options_init(&options);
    options.channels = 0;
    try std.testing.expectEqual(Error.invalid_argument, bobrwhisper_capture_open(&options, &stream));
}

test "device enumeration round-trips through C strings" {
    var list: DeviceList = .{ .devices = @ptrFromInt(0x1000), .count = 42 };
    try std.testing.expectEqual(Error.success, bobrwhisper_capture_list_devices(&list));
    defer bobrwhisper_capture_free_devices(list);

    // Every backend reports at least a default entry, except the unsupported one.
    if (list.count > 0) {
        const first = list.devices.?[0];
        // Reachable as a C string, which is the point of the re-copy.
        _ = std.mem.span(first.id);
        try std.testing.expect(std.mem.span(first.name).len > 0);
    }
}

test "an unsupported platform says so rather than failing obscurely" {
    // Deliberately does not open a device on a host that has a backend: that
    // outcome depends on whether the machine has a sound card and, on macOS, on a
    // granted microphone permission, and it makes the ALSA library log to stderr.
    // examples/capture-smoke covers the supported path, tolerantly.
    if (bobrwhisper_capture_is_supported()) return;

    var stream: ?*capture.Stream = null;
    try std.testing.expectEqual(Error.unsupported_platform, bobrwhisper_capture_open(null, &stream));
    try std.testing.expect(stream == null);
}
