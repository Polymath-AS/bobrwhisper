//! CoreAudio (AudioQueue) capture backend for macOS and iOS.
//!
//! Ported from src/audio/AudioCapture.zig, which is the version the app still
//! uses. Two behaviours from that code are load-bearing and preserved here:
//!
//!   * The queue is created in `start` and disposed in `stop`, not held open for
//!     the life of the stream. A stopped AudioQueue stays bound to the device it
//!     was created with, so recreating it per run is what lets a device change
//!     take effect without touching the system-wide input selection.
//!   * `stop` is non-immediate, so CoreAudio delivers its final input buffer.
//!     Stopping immediately truncates the last word spoken before key release.
//!
//! The extern surface is narrow deliberately. Zig 0.16 deprecated @cImport in
//! favour of build-system translation, and Apple's AudioToolbox headers use
//! Clang blocks that translate-c cannot consume reliably, so declaring the dozen
//! entry points this needs is more robust than translating the SDK.

const std = @import("std");
const audio = @import("audio");
const capture = @import("main.zig");

const c = struct {
    pub const OSStatus = i32;
    pub const UInt32 = u32;
    pub const Float64 = f64;
    pub const AudioFormatID = UInt32;
    pub const AudioFormatFlags = UInt32;
    pub const AudioQueueRef = ?*opaque {};
    pub const CFStringRef = ?*opaque {};

    pub const AudioStreamBasicDescription = extern struct {
        mSampleRate: Float64,
        mFormatID: AudioFormatID,
        mFormatFlags: AudioFormatFlags,
        mBytesPerPacket: UInt32,
        mFramesPerPacket: UInt32,
        mBytesPerFrame: UInt32,
        mChannelsPerFrame: UInt32,
        mBitsPerChannel: UInt32,
        mReserved: UInt32,
    };

    pub const AudioTimeStamp = opaque {};
    pub const AudioStreamPacketDescription = opaque {};

    pub const AudioQueueBuffer = extern struct {
        mAudioDataBytesCapacity: UInt32,
        mAudioData: ?*anyopaque,
        mAudioDataByteSize: UInt32,
        mUserData: ?*anyopaque,
        mPacketDescriptionCapacity: UInt32,
        mPacketDescriptions: ?*AudioStreamPacketDescription,
        mPacketDescriptionCount: UInt32,
    };
    pub const AudioQueueBufferRef = *AudioQueueBuffer;

    pub const AudioQueueInputCallback = *const fn (
        inUserData: ?*anyopaque,
        inAQ: AudioQueueRef,
        inBuffer: AudioQueueBufferRef,
        inStartTime: *const AudioTimeStamp,
        inNumberPacketDescriptions: UInt32,
        inPacketDescs: ?*const AudioStreamPacketDescription,
    ) callconv(.c) void;

    pub const noErr: OSStatus = 0;
    pub const kAudioFormatLinearPCM: AudioFormatID = 0x6c70636d;
    pub const kAudioFormatFlagIsFloat: AudioFormatFlags = 1 << 0;
    pub const kAudioFormatFlagIsPacked: AudioFormatFlags = 1 << 3;
    pub const kCFStringEncodingUTF8: UInt32 = 0x08000100;

    pub extern "c" fn AudioQueueNewInput(
        inFormat: *const AudioStreamBasicDescription,
        inCallbackProc: AudioQueueInputCallback,
        inUserData: ?*anyopaque,
        inCallbackRunLoop: ?*anyopaque,
        inCallbackRunLoopMode: ?*anyopaque,
        inFlags: UInt32,
        outAQ: *AudioQueueRef,
    ) OSStatus;
    pub extern "c" fn AudioQueueAllocateBuffer(
        inAQ: AudioQueueRef,
        inBufferByteSize: UInt32,
        outBuffer: *AudioQueueBufferRef,
    ) OSStatus;
    pub extern "c" fn AudioQueueEnqueueBuffer(
        inAQ: AudioQueueRef,
        inBuffer: AudioQueueBufferRef,
        inNumPacketDescs: UInt32,
        inPacketDescs: ?*const AudioStreamPacketDescription,
    ) OSStatus;
    pub extern "c" fn AudioQueueStart(inAQ: AudioQueueRef, inStartTime: ?*const AudioTimeStamp) OSStatus;
    pub extern "c" fn AudioQueueSetProperty(
        inAQ: AudioQueueRef,
        inID: UInt32,
        inDataSize: UInt32,
        inData: *const anyopaque,
    ) OSStatus;
    pub extern "c" fn AudioQueueStop(inAQ: AudioQueueRef, inImmediate: u8) OSStatus;
    pub extern "c" fn AudioQueueDispose(inAQ: AudioQueueRef, inImmediate: u8) OSStatus;
    pub extern "c" fn CFStringCreateWithBytes(
        alloc: ?*anyopaque,
        bytes: [*]const u8,
        numBytes: c_long,
        encoding: UInt32,
        isExternalRepresentation: u8,
    ) CFStringRef;
    pub extern "c" fn CFRelease(cf: *const anyopaque) void;
};

inline fn fourCC(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

/// Three buffers in flight is enough to keep the device fed while one is being
/// drained, without adding latency.
const buffer_count = 3;

/// Milliseconds of audio per AudioQueue buffer.
const buffer_duration_ms = 30;

const CoreAudio = struct {
    allocator: std.mem.Allocator,
    ring: *capture.Ring,
    queue: c.AudioQueueRef = null,
    sample_rate: f64,
    channels: u16,
    /// Owned copy of the device UID, since Options borrows it.
    device_uid: ?[]const u8,
    /// Trailing count of samples that arrived bit-exactly zero. A quiet
    /// microphone still jitters below 1e-6; exact zero means a dead route,
    /// a suspended driver, or permission denied at the system level.
    consecutive_zero_samples: std.atomic.Value(usize) = .init(0),
    /// RMS of the most recent buffer, for a level meter.
    level: std.atomic.Value(u32) = .init(0),
};

pub fn open(
    allocator: std.mem.Allocator,
    options: capture.Options,
    ring: *capture.Ring,
) capture.Error!capture.Backend {
    const self = allocator.create(CoreAudio) catch return capture.Error.OutOfMemory;
    errdefer allocator.destroy(self);

    const uid = if (options.device_id) |id|
        allocator.dupe(u8, id) catch return capture.Error.OutOfMemory
    else
        null;

    self.* = .{
        .allocator = allocator,
        .ring = ring,
        .sample_rate = @floatFromInt(options.sample_rate),
        .channels = options.channels,
        .device_uid = uid,
    };

    return .{
        .ptr = self,
        .vtable = &.{ .start = start, .stop = stop, .destroy = destroy },
    };
}

fn start(ptr: *anyopaque) capture.Error!void {
    const self: *CoreAudio = @ptrCast(@alignCast(ptr));
    if (self.queue != null) return capture.Error.AlreadyRunning;

    self.consecutive_zero_samples.store(0, .release);

    var format: c.AudioStreamBasicDescription = .{
        .mSampleRate = self.sample_rate,
        .mFormatID = c.kAudioFormatLinearPCM,
        .mFormatFlags = c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked,
        .mBytesPerPacket = @sizeOf(f32) * self.channels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = @sizeOf(f32) * self.channels,
        .mChannelsPerFrame = self.channels,
        .mBitsPerChannel = 32,
        .mReserved = 0,
    };

    var queue: c.AudioQueueRef = null;
    if (c.AudioQueueNewInput(&format, inputCallback, self, null, null, 0, &queue) != c.noErr) {
        return capture.Error.OpenFailed;
    }
    errdefer _ = c.AudioQueueDispose(queue, 1);

    if (self.device_uid) |uid| {
        const uid_ref = c.CFStringCreateWithBytes(
            null,
            uid.ptr,
            @intCast(uid.len),
            c.kCFStringEncodingUTF8,
            0,
        ) orelse return capture.Error.DeviceNotFound;
        defer c.CFRelease(uid_ref);

        var property: c.CFStringRef = uid_ref;
        // 'aqcd' is kAudioQueueProperty_CurrentDevice.
        if (c.AudioQueueSetProperty(
            queue,
            comptime fourCC("aqcd"),
            @sizeOf(c.CFStringRef),
            @ptrCast(&property),
        ) != c.noErr) {
            return capture.Error.DeviceNotFound;
        }
    }

    const bytes_per_buffer: u32 = @intFromFloat(
        self.sample_rate * (@as(f64, buffer_duration_ms) / 1000.0) *
            @as(f64, @floatFromInt(@sizeOf(f32) * self.channels)),
    );
    for (0..buffer_count) |_| {
        var buffer: c.AudioQueueBufferRef = undefined;
        if (c.AudioQueueAllocateBuffer(queue, bytes_per_buffer, &buffer) != c.noErr) {
            return capture.Error.OpenFailed;
        }
        if (c.AudioQueueEnqueueBuffer(queue, buffer, 0, null) != c.noErr) {
            return capture.Error.OpenFailed;
        }
    }

    // A failure here is usually a denied microphone permission.
    if (c.AudioQueueStart(queue, null) != c.noErr) return capture.Error.OpenFailed;

    self.queue = queue;
}

fn stop(ptr: *anyopaque) void {
    const self: *CoreAudio = @ptrCast(@alignCast(ptr));
    const queue = self.queue orelse return;
    // Non-immediate, so the last input buffer is still delivered.
    _ = c.AudioQueueStop(queue, 0);
    _ = c.AudioQueueDispose(queue, 1);
    self.queue = null;
}

fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *CoreAudio = @ptrCast(@alignCast(ptr));
    stop(ptr);
    if (self.device_uid) |uid| allocator.free(uid);
    allocator.destroy(self);
}

/// Runs on CoreAudio's audio thread. No allocation, no blocking: it writes into
/// the ring (which drops rather than grows) and re-enqueues the buffer.
fn inputCallback(
    userdata: ?*anyopaque,
    queue: c.AudioQueueRef,
    buffer: c.AudioQueueBufferRef,
    _: *const c.AudioTimeStamp,
    num_packets: u32,
    _: ?*const c.AudioStreamPacketDescription,
) callconv(.c) void {
    const self: *CoreAudio = @ptrCast(@alignCast(userdata orelse return));

    if (num_packets > 0) {
        if (buffer.*.mAudioData) |data| {
            const samples: [*]const f32 = @ptrCast(@alignCast(data));
            const frames = num_packets;
            const incoming = samples[0..frames];

            // One pass for RMS and exact-zero detection, vectorized because this
            // is the real-time thread running for every buffer the device hands
            // us. Reuses the audio library rather than open-coding it.
            const energy = audio.simd.energy(incoming);
            const rms = @sqrt(energy.sum_of_squares / @as(f32, @floatFromInt(frames)));
            self.level.store(@bitCast(rms), .release);
            if (energy.all_zero) {
                _ = self.consecutive_zero_samples.fetchAdd(frames, .monotonic);
            } else {
                self.consecutive_zero_samples.store(0, .release);
            }

            self.ring.write(incoming);
        }
    }

    _ = c.AudioQueueEnqueueBuffer(queue, buffer, 0, null);
}

pub fn listDevices(allocator: std.mem.Allocator) capture.Error![]capture.Device {
    // Real enumeration means the CoreAudio HAL — AudioObjectGetPropertyData over
    // kAudioHardwarePropertyDevices — which src/audio/AudioDevice.zig already
    // implements for the app. Porting it here is a separate piece of work; until
    // then report the system default, which is what an unset device_id selects
    // anyway, and let a caller pass a UID through Options.device_id.
    const devices = allocator.alloc(capture.Device, 1) catch return capture.Error.OutOfMemory;
    errdefer allocator.free(devices);

    const id = allocator.dupe(u8, "") catch return capture.Error.OutOfMemory;
    errdefer allocator.free(id);
    const name = allocator.dupe(u8, "System default input") catch return capture.Error.OutOfMemory;

    devices[0] = .{ .id = id, .name = name, .is_default = true };
    return devices;
}

/// Trailing bit-exact-zero sample count, for stuck-microphone detection.
pub fn consecutiveZeroSamples(backend_ptr: *anyopaque) usize {
    const self: *CoreAudio = @ptrCast(@alignCast(backend_ptr));
    return self.consecutive_zero_samples.load(.acquire);
}

/// RMS of the most recent buffer.
pub fn currentLevel(backend_ptr: *anyopaque) f32 {
    const self: *CoreAudio = @ptrCast(@alignCast(backend_ptr));
    return @bitCast(self.level.load(.acquire));
}

test "lists the default device" {
    const devices = try listDevices(std.testing.allocator);
    defer capture.freeDevices(std.testing.allocator, devices);
    try std.testing.expect(devices.len >= 1);
    try std.testing.expect(devices[0].is_default);
}

// Opening an AudioQueue is not tested: it needs a real device and, on macOS, a
// granted microphone permission. The stream lifecycle around this backend is
// covered in main.zig through a substitute backend.
