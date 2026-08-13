//! Audio capture using CoreAudio (macOS)

const std = @import("std");
const builtin = @import("builtin");

const simd = @import("simd.zig");
const vad = @import("vad.zig");
const level = @import("level.zig");
const resample_mod = @import("resample.zig");

const c = if (builtin.os.tag == .macos) MacAudio else if (builtin.os.tag == .linux) LinuxAudio else struct {};

/// Minimal CoreAudio/AudioQueue ABI surface used by this module.
///
/// Zig 0.16 deprecated @cImport in favor of build-system C translation, and
/// Apple's modern AudioToolbox headers use Clang blocks that translate-c cannot
/// consume reliably. Keeping this narrow extern surface avoids translating the
/// entire SDK while preserving the exact C ABI for the hot audio callback path.
const MacAudio = struct {
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

    pub const kCFStringEncodingUTF8: UInt32 = 0x08000100;
};

const LinuxAudio = struct {
    pub const SndPcm = opaque {};
    pub const SND_PCM_STREAM_CAPTURE: c_int = 1;
    pub const SND_PCM_ACCESS_RW_INTERLEAVED: c_int = 3;
    pub const SND_PCM_FORMAT_FLOAT_LE: c_int = 10;

    pub extern "asound" fn snd_pcm_open(pcm: *?*SndPcm, name: [*:0]const u8, stream: c_int, mode: c_int) c_int;
    pub extern "asound" fn snd_pcm_set_params(
        pcm: ?*SndPcm,
        format: c_int,
        access: c_int,
        channels: u32,
        rate: u32,
        soft_resample: c_int,
        latency: u32,
    ) c_int;
    pub extern "asound" fn snd_pcm_readi(pcm: ?*SndPcm, buffer: *anyopaque, size: usize) isize;
    pub extern "asound" fn snd_pcm_recover(pcm: ?*SndPcm, err: c_int, silent: c_int) c_int;
    pub extern "asound" fn snd_pcm_drop(pcm: ?*SndPcm) c_int;
    pub extern "asound" fn snd_pcm_close(pcm: ?*SndPcm) c_int;
};

inline fn fourCC(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

const AudioCapture = @This();

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

allocator: std.mem.Allocator,
is_recording: bool = false,
sample_rate: f64 = 16000.0,
buffer_duration_ms: u32 = 30,
device_uid: ?[]const u8 = null,
device_name: ?[]const u8 = null,

// CoreAudio handles (macOS only)
audio_queue: if (builtin.os.tag == .macos) c.AudioQueueRef else void =
    if (builtin.os.tag == .macos) null else {},
linux_pcm: if (builtin.os.tag == .linux) ?*c.SndPcm else void =
    if (builtin.os.tag == .linux) null else {},
linux_thread: if (builtin.os.tag == .linux) ?std.Thread else void =
    if (builtin.os.tag == .linux) null else {},
linux_stop: if (builtin.os.tag == .linux) std.atomic.Value(bool) else void =
    if (builtin.os.tag == .linux) std.atomic.Value(bool).init(false) else {},

// Buffer for captured audio (protected by mutex for thread safety)
buffer: std.ArrayListUnmanaged(f32),
mutex: SpinMutex = .{},
// RMS audio level from the most recent callback buffer, updated under mutex
audio_level: f32 = 0,
// Stuck-mic detection: count of trailing samples whose CoreAudio callback
// delivered an exactly-zero buffer. Reset to 0 the moment any non-zero sample
// arrives. Exact-zero input is a strong signal for dead audio routes.
consecutive_zero_samples: usize = 0,

pub const Config = struct {
    sample_rate: f64 = 16000.0,
    channels: u32 = 1,
    buffer_duration_ms: u32 = 30,
    device_uid: ?[]const u8 = null,
    device_name: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator) !AudioCapture {
    return initWithConfig(allocator, .{});
}

pub fn initWithConfig(allocator: std.mem.Allocator, config: Config) !AudioCapture {
    return .{
        .allocator = allocator,
        .sample_rate = config.sample_rate,
        .buffer_duration_ms = config.buffer_duration_ms,
        .device_uid = config.device_uid,
        .device_name = config.device_name,
        .buffer = .empty,
    };
}

pub fn deinit(self: *AudioCapture) void {
    if (self.is_recording) {
        self.stop();
    }
    self.buffer.deinit(self.allocator);

    if (builtin.os.tag == .macos) {
        if (self.audio_queue != null) {
            _ = c.AudioQueueDispose(self.audio_queue, 1);
        }
    }
}

pub fn start(self: *AudioCapture) !void {
    if (self.is_recording) return;

    self.buffer.clearRetainingCapacity();
    self.consecutive_zero_samples = 0;
    try self.buffer.ensureTotalCapacity(self.allocator, 16000 * 30);

    if (builtin.os.tag == .macos) {
        try self.startCoreAudio();
    } else if (builtin.os.tag == .linux) {
        try self.startLinux();
    } else {
        return error.UnsupportedPlatform;
    }

    self.is_recording = true;
}

pub fn stop(self: *AudioCapture) void {
    if (!self.is_recording) return;

    if (builtin.os.tag == .macos) {
        self.stopCoreAudio();
    } else if (builtin.os.tag == .linux) {
        self.stopLinux();
    }

    self.is_recording = false;
    self.audio_level = 0;
}

pub fn isRecording(self: *AudioCapture) bool {
    return self.is_recording;
}

/// Returns a slice into the internal buffer. Only safe to call when recording is stopped,
/// as the slice is invalidated if the CoreAudio callback triggers a reallocation.
pub fn getSamples(self: *AudioCapture) []const f32 {
    std.debug.assert(!self.is_recording);
    return self.buffer.items;
}

/// Mutable view into the captured samples. Same lifetime constraints as `getSamples`;
/// only safe when recording is stopped. Used by callers that want to apply in-place
/// preprocessing such as peak normalization before transcription.
pub fn getSamplesMut(self: *AudioCapture) []f32 {
    std.debug.assert(!self.is_recording);
    return self.buffer.items;
}

pub fn copySamples(self: *AudioCapture, allocator: std.mem.Allocator) ![]f32 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return allocator.dupe(f32, self.buffer.items);
}

/// Copy only samples from the given offset onward, avoiding full-buffer duplication.
/// Returns a tuple of the copied slice and the total sample count at time of copy.
pub fn copySamplesFrom(self: *AudioCapture, allocator: std.mem.Allocator, offset: usize) !struct { samples: []f32, total: usize } {
    self.mutex.lock();
    defer self.mutex.unlock();
    const total = self.buffer.items.len;
    const from = @min(offset, total);
    return .{
        .samples = try allocator.dupe(f32, self.buffer.items[from..]),
        .total = total,
    };
}

pub fn getAudioLevel(self: *AudioCapture) f32 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.audio_level;
}

pub fn getSampleCount(self: *AudioCapture) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.buffer.items.len;
}

/// Trailing run of bit-exact-zero samples reported by CoreAudio. Crosses the
/// stuck-mic threshold (~5 s = 80000 samples at 16 kHz) when the input device
/// stops delivering real audio. Resets to 0 on any non-zero sample.
pub fn getConsecutiveZeroSamples(self: *AudioCapture) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.consecutive_zero_samples;
}

pub fn clearBuffer(self: *AudioCapture) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.buffer.clearRetainingCapacity();
}

fn startCoreAudio(self: *AudioCapture) !void {
    if (builtin.os.tag != .macos) return;

    // A stopped AudioQueue remains bound to its original device. Recreate it
    // for each recording so a Settings change takes effect without touching
    // macOS's global input device.
    if (self.audio_queue != null) {
        _ = c.AudioQueueDispose(self.audio_queue, 1);
        self.audio_queue = null;
    }

    // Audio format: 16kHz, mono, float32
    var format = c.AudioStreamBasicDescription{
        .mSampleRate = self.sample_rate,
        .mFormatID = c.kAudioFormatLinearPCM,
        .mFormatFlags = c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked,
        .mBytesPerPacket = @sizeOf(f32),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = @sizeOf(f32),
        .mChannelsPerFrame = 1,
        .mBitsPerChannel = 32,
        .mReserved = 0,
    };

    // Create audio queue for input
    var status = c.AudioQueueNewInput(
        &format,
        audioInputCallback,
        self,
        null,
        null,
        0,
        &self.audio_queue,
    );

    if (status != c.noErr) {
        std.log.err("AudioQueueNewInput failed: {}", .{status});
        return error.AudioQueueCreationFailed;
    }

    if (self.device_uid) |device_uid| {
        const device_uid_ref = c.CFStringCreateWithBytes(
            null,
            device_uid.ptr,
            @intCast(device_uid.len),
            c.kCFStringEncodingUTF8,
            0,
        ) orelse return error.InvalidInputDevice;
        defer c.CFRelease(device_uid_ref);
        var property_value: c.CFStringRef = device_uid_ref;
        status = c.AudioQueueSetProperty(
            self.audio_queue,
            comptime fourCC("aqcd"),
            @sizeOf(c.CFStringRef),
            @ptrCast(&property_value),
        );
        if (status != c.noErr) {
            std.log.err("AudioQueueSetProperty(current device) failed: {}", .{status});
            return error.AudioDeviceSelectionFailed;
        }
    }

    // Allocate and enqueue buffers
    const buffer_duration_sec = @as(f64, @floatFromInt(self.buffer_duration_ms)) / 1000.0;
    const buffer_size: u32 = @intFromFloat(self.sample_rate * buffer_duration_sec * @sizeOf(f32));
    var buffers: [3]c.AudioQueueBufferRef = undefined;

    for (&buffers) |*buf| {
        status = c.AudioQueueAllocateBuffer(self.audio_queue, buffer_size, buf);
        if (status != c.noErr) {
            std.log.err("AudioQueueAllocateBuffer failed: {}", .{status});
            return error.BufferAllocationFailed;
        }

        status = c.AudioQueueEnqueueBuffer(self.audio_queue, buf.*, 0, null);
        if (status != c.noErr) {
            std.log.err("AudioQueueEnqueueBuffer failed: {}", .{status});
            return error.BufferEnqueueFailed;
        }
    }

    // Start recording
    status = c.AudioQueueStart(self.audio_queue, null);
    if (status != c.noErr) {
        std.log.err("AudioQueueStart failed: {} (check microphone permissions in System Settings)", .{status});
        return error.AudioQueueStartFailed;
    }
    std.log.info("AudioQueue started successfully", .{});
}

fn startLinux(self: *AudioCapture) !void {
    if (builtin.os.tag != .linux) return;
    const device = self.device_name orelse "default";
    var name_buf: [256:0]u8 = undefined;
    if (device.len >= name_buf.len) return error.InvalidInputDevice;
    @memcpy(name_buf[0..device.len], device);
    name_buf[device.len] = 0;

    var pcm: ?*c.SndPcm = null;
    if (c.snd_pcm_open(&pcm, &name_buf, c.SND_PCM_STREAM_CAPTURE, 0) < 0) return error.AudioDeviceOpenFailed;
    errdefer _ = c.snd_pcm_close(pcm);
    if (c.snd_pcm_set_params(
        pcm,
        c.SND_PCM_FORMAT_FLOAT_LE,
        c.SND_PCM_ACCESS_RW_INTERLEAVED,
        1,
        @intFromFloat(self.sample_rate),
        1,
        self.buffer_duration_ms * 1000,
    ) < 0) return error.AudioDeviceConfigurationFailed;
    self.linux_pcm = pcm;
    self.linux_stop.store(false, .seq_cst);
    self.linux_thread = try std.Thread.spawn(.{}, linuxCaptureLoop, .{self});
}

fn stopLinux(self: *AudioCapture) void {
    if (builtin.os.tag != .linux) return;
    self.linux_stop.store(true, .seq_cst);
    if (self.linux_pcm) |pcm| _ = c.snd_pcm_drop(pcm);
    if (self.linux_thread) |thread| thread.join();
    self.linux_thread = null;
    if (self.linux_pcm) |pcm| _ = c.snd_pcm_close(pcm);
    self.linux_pcm = null;
}

fn linuxCaptureLoop(self: *AudioCapture) void {
    var samples: [480]f32 = undefined;
    while (!self.linux_stop.load(.seq_cst)) {
        const read = c.snd_pcm_readi(self.linux_pcm, &samples, samples.len);
        if (read < 0) {
            if (c.snd_pcm_recover(self.linux_pcm, @intCast(read), 1) < 0) break;
            continue;
        }
        const count: usize = @intCast(read);
        if (count == 0) continue;
        self.mutex.lock();
        self.buffer.appendSlice(self.allocator, samples[0..count]) catch {
            std.log.err("Failed to append ALSA samples", .{});
        };
        const energy = simd.energy(samples[0..count]);
        self.audio_level = @sqrt(energy.sum_of_squares / @as(f32, @floatFromInt(count)));
        if (!energy.all_zero) self.consecutive_zero_samples = 0 else self.consecutive_zero_samples +|= count;
        self.mutex.unlock();
    }
}

fn stopCoreAudio(self: *AudioCapture) void {
    if (builtin.os.tag != .macos) return;
    if (self.audio_queue == null) return;

    // Use non-immediate stop so CoreAudio can deliver the final input buffer
    // and avoid truncating the last spoken words on key release.
    _ = c.AudioQueueStop(self.audio_queue, 0);
}

// CoreAudio callback
fn audioInputCallback(
    userdata: ?*anyopaque,
    queue: c.AudioQueueRef,
    buffer: c.AudioQueueBufferRef,
    _: *const c.AudioTimeStamp,
    num_packets: u32,
    _: ?*const c.AudioStreamPacketDescription,
) callconv(.c) void {
    const self: *AudioCapture = @ptrCast(@alignCast(userdata orelse return));

    if (num_packets > 0 and buffer.*.mAudioData != null) {
        const samples: [*]const f32 = @ptrCast(@alignCast(buffer.*.mAudioData));
        const sample_count = num_packets;

        self.mutex.lock();
        defer self.mutex.unlock();
        self.buffer.appendSlice(self.allocator, samples[0..sample_count]) catch {
            std.log.err("Failed to append audio samples", .{});
        };

        // Single pass: RMS energy + exact-zero detection. The zero check
        // surfaces a stuck microphone (dead route, denied permission at the
        // system level, suspended driver). RMS alone is too noisy: a quiet mic
        // still produces sub-1e-6 jitter, but a dead route is bit-exact zero.
        // Vectorized because this runs on the realtime audio thread, under the
        // mutex, for every buffer the device hands us.
        const energy = simd.energy(samples[0..sample_count]);
        self.audio_level = @sqrt(energy.sum_of_squares / @as(f32, @floatFromInt(sample_count)));
        if (!energy.all_zero) {
            self.consecutive_zero_samples = 0;
        } else {
            self.consecutive_zero_samples +|= sample_count;
        }
    }

    _ = c.AudioQueueEnqueueBuffer(queue, buffer, 0, null);
}

// Signal processing moved to the audio library, which has no platform
// dependencies and is tested on its own (`zig build test-audio`). Re-exported
// here so existing callers keep working and there is still one implementation.
pub const detectVoiceActivity = vad.detectVoiceActivity;
pub const TrimBounds = vad.TrimBounds;
pub const trimSilenceBounds = vad.trimSilenceBounds;
pub const computeNoiseFloor = vad.computeNoiseFloor;
pub const peakNormalize = level.peakNormalize;
pub const resample = resample_mod.resample;
