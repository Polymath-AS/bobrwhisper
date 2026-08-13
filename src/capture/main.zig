//! Microphone capture, with one interface over per-OS backends.
//!
//! What a backend must hide: CoreAudio hands you buffers on its own thread via a
//! callback, ALSA wants you to block in a read loop on a thread you own, and
//! WASAPI does something else again. What a caller gets instead is a stream it
//! polls — `read` into your own buffer, whenever suits you.
//!
//! Polling rather than a callback is a deliberate choice for a library with a C
//! ABI. A callback would run on the audio thread, where an embedder that blocks
//! or allocates causes dropouts, and it would be awkward to bind from any
//! language with a runtime. The cost is a fixed-size ring and a bounded latency;
//! the benefit is that no embedder can break the audio thread.
//!
//! Depends on the audio library for format conversion, and on nothing else. The
//! ASR library is not involved: capture produces the 16 kHz mono float that
//! libwhisper consumes, but neither library knows about the other.

const std = @import("std");
const builtin = @import("builtin");
const audio = @import("audio");

pub const Ring = @import("Ring.zig");

/// The backend for this host, chosen at compile time. `unsupported` reports
/// UnsupportedPlatform from `open` rather than failing the build, so the library
/// still compiles and links everywhere — a Windows consumer gets a clear runtime
/// error instead of a missing symbol.
pub const backend = switch (builtin.os.tag) {
    .macos, .ios => @import("coreaudio.zig"),
    .linux => @import("alsa.zig"),
    else => @import("unsupported.zig"),
};

pub const Error = error{
    UnsupportedPlatform,
    DeviceNotFound,
    OpenFailed,
    AlreadyRunning,
    OutOfMemory,
};

pub const Options = struct {
    /// Rate to request from the device. Backends that cannot honour it convert.
    sample_rate: u32 = audio.asr_sample_rate,
    channels: u16 = 1,
    /// How much audio the ring holds. Beyond this the oldest samples are
    /// dropped, which is the right failure for live capture: a consumer that
    /// stalls should lose old audio, not accumulate unbounded memory.
    buffer_ms: u32 = 5000,
    /// Backend-specific device identifier; null selects the default input.
    device_id: ?[]const u8 = null,
};

/// A capture backend, behind a vtable so tests can substitute a fake and so a
/// file or loopback source stays possible without touching this file.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque) Error!void,
        stop: *const fn (ptr: *anyopaque) void,
        destroy: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };
};

pub const Stream = struct {
    allocator: std.mem.Allocator,
    ring: Ring,
    impl: Backend,
    options: Options,
    running: bool = false,

    /// Open the device without starting it. Call `start` to begin capture.
    pub fn open(allocator: std.mem.Allocator, options: Options) Error!*Stream {
        std.debug.assert(options.sample_rate > 0);
        std.debug.assert(options.channels > 0);

        const stream = allocator.create(Stream) catch return Error.OutOfMemory;
        errdefer allocator.destroy(stream);

        const capacity = ringCapacity(options);
        var ring = Ring.init(allocator, capacity) catch return Error.OutOfMemory;
        errdefer ring.deinit();

        stream.* = .{
            .allocator = allocator,
            .ring = ring,
            .impl = undefined,
            .options = options,
        };
        stream.impl = try backend.open(allocator, options, &stream.ring);
        return stream;
    }

    /// Open with a caller-supplied backend. This is how the tests drive a stream
    /// without a microphone, and how a non-device source would plug in.
    pub fn openWithBackend(
        allocator: std.mem.Allocator,
        options: Options,
        make: *const fn (std.mem.Allocator, Options, *Ring) Error!Backend,
    ) Error!*Stream {
        const stream = allocator.create(Stream) catch return Error.OutOfMemory;
        errdefer allocator.destroy(stream);

        var ring = Ring.init(allocator, ringCapacity(options)) catch return Error.OutOfMemory;
        errdefer ring.deinit();

        stream.* = .{
            .allocator = allocator,
            .ring = ring,
            .impl = undefined,
            .options = options,
        };
        stream.impl = try make(allocator, options, &stream.ring);
        return stream;
    }

    pub fn close(self: *Stream) void {
        if (self.running) self.stop();
        self.impl.vtable.destroy(self.impl.ptr, self.allocator);
        self.ring.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Stream) Error!void {
        if (self.running) return Error.AlreadyRunning;
        self.ring.clear();
        try self.impl.vtable.start(self.impl.ptr);
        self.running = true;
    }

    pub fn stop(self: *Stream) void {
        if (!self.running) return;
        self.impl.vtable.stop(self.impl.ptr);
        self.running = false;
    }

    pub fn isRunning(self: *const Stream) bool {
        return self.running;
    }

    /// Copy out up to `out.len` captured samples, oldest first. Returns how many
    /// were written; zero simply means nothing has arrived yet.
    pub fn read(self: *Stream, out: []f32) usize {
        return self.ring.read(out);
    }

    pub fn available(self: *Stream) usize {
        return self.ring.available();
    }

    /// Samples lost because the consumer did not keep up. Non-zero means `read`
    /// is being called too slowly, or `buffer_ms` is too small.
    pub fn dropped(self: *Stream) u64 {
        return self.ring.droppedCount();
    }

    fn ringCapacity(options: Options) usize {
        const per_ms = @as(usize, options.sample_rate) / 1000;
        return @max(1024, per_ms * @max(1, options.buffer_ms));
    }
};

/// Enumerate input devices. The caller owns the returned slice and each name;
/// release with `freeDevices`.
pub fn listDevices(allocator: std.mem.Allocator) Error![]Device {
    return backend.listDevices(allocator);
}

pub fn freeDevices(allocator: std.mem.Allocator, devices: []Device) void {
    for (devices) |device| {
        allocator.free(device.id);
        allocator.free(device.name);
    }
    allocator.free(devices);
}

pub const Device = struct {
    /// Opaque to the caller; pass back as `Options.device_id`.
    id: []const u8,
    name: []const u8,
    is_default: bool,
};

test {
    _ = Ring;
    _ = backend;
}

/// A backend that produces a fixed tone, so the stream lifecycle is testable
/// without a device. Also serves as the reference for what a backend must do.
const TestBackend = struct {
    ring: *Ring,
    started: bool = false,
    stopped: bool = false,

    fn make(allocator: std.mem.Allocator, options: Options, ring: *Ring) Error!Backend {
        _ = options;
        const self = allocator.create(TestBackend) catch return Error.OutOfMemory;
        self.* = .{ .ring = ring };
        return .{
            .ptr = self,
            .vtable = &.{ .start = start, .stop = stop, .destroy = destroy },
        };
    }

    fn start(ptr: *anyopaque) Error!void {
        const self: *TestBackend = @ptrCast(@alignCast(ptr));
        self.started = true;
        // Stand in for an audio callback delivering one buffer.
        var block: [256]f32 = undefined;
        @memset(&block, 0.25);
        self.ring.write(&block);
    }

    fn stop(ptr: *anyopaque) void {
        const self: *TestBackend = @ptrCast(@alignCast(ptr));
        self.stopped = true;
    }

    fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *TestBackend = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

test "stream lifecycle delivers samples a caller can read" {
    const stream = try Stream.openWithBackend(std.testing.allocator, .{}, TestBackend.make);
    defer stream.close();

    try std.testing.expect(!stream.isRunning());
    try std.testing.expectEqual(@as(usize, 0), stream.available());

    try stream.start();
    try std.testing.expect(stream.isRunning());
    try std.testing.expectEqual(@as(usize, 256), stream.available());

    var out: [512]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 256), stream.read(&out));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 0.0001);
    try std.testing.expectEqual(@as(u64, 0), stream.dropped());

    stream.stop();
    try std.testing.expect(!stream.isRunning());
}

test "starting twice is an error rather than a second device open" {
    const stream = try Stream.openWithBackend(std.testing.allocator, .{}, TestBackend.make);
    defer stream.close();

    try stream.start();
    try std.testing.expectError(Error.AlreadyRunning, stream.start());
}

test "stopping an idle stream is harmless" {
    const stream = try Stream.openWithBackend(std.testing.allocator, .{}, TestBackend.make);
    defer stream.close();
    stream.stop();
    stream.stop();
    try std.testing.expect(!stream.isRunning());
}

test "close stops a running stream" {
    const stream = try Stream.openWithBackend(std.testing.allocator, .{}, TestBackend.make);
    try stream.start();
    // close() must not leak the backend or leave the device open.
    stream.close();
}

test "restarting clears audio left from the previous run" {
    const stream = try Stream.openWithBackend(std.testing.allocator, .{}, TestBackend.make);
    defer stream.close();

    try stream.start();
    try std.testing.expectEqual(@as(usize, 256), stream.available());
    stream.stop();

    try stream.start();
    // Not 512: start() clears, so the second run contributes only its own audio.
    try std.testing.expectEqual(@as(usize, 256), stream.available());
}

test "ring capacity follows buffer_ms and has a floor" {
    try std.testing.expectEqual(@as(usize, 16000), Stream.ringCapacity(.{
        .sample_rate = 16000,
        .buffer_ms = 1000,
    }));
    // A tiny request still gets a usable buffer rather than a few samples.
    try std.testing.expectEqual(@as(usize, 1024), Stream.ringCapacity(.{
        .sample_rate = 16000,
        .buffer_ms = 1,
    }));
}

test "a slow consumer loses old audio and can tell" {
    const stream = try Stream.openWithBackend(
        std.testing.allocator,
        .{ .sample_rate = 16000, .buffer_ms = 1 }, // 1024-sample floor
        TestBackend.make,
    );
    defer stream.close();

    try stream.start();
    // Five 256-sample buffers exceed the 1024-sample ring.
    for (0..4) |_| try stream.impl.vtable.start(stream.impl.ptr);
    try std.testing.expect(stream.dropped() > 0);
    try std.testing.expectEqual(@as(usize, 1024), stream.available());
}
