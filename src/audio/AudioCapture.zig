//! Audio capture using CoreAudio (macOS)

const std = @import("std");
const builtin = @import("builtin");

const simd = @import("../simd.zig");

const c = if (builtin.os.tag == .macos) MacAudio else struct {};

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
    pub extern "c" fn AudioQueueStop(inAQ: AudioQueueRef, inImmediate: u8) OSStatus;
    pub extern "c" fn AudioQueueDispose(inAQ: AudioQueueRef, inImmediate: u8) OSStatus;
};

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

// CoreAudio handles (macOS only)
audio_queue: if (builtin.os.tag == .macos) c.AudioQueueRef else void =
    if (builtin.os.tag == .macos) null else {},

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
};

pub fn init(allocator: std.mem.Allocator) !AudioCapture {
    return initWithConfig(allocator, .{});
}

pub fn initWithConfig(allocator: std.mem.Allocator, config: Config) !AudioCapture {
    return .{
        .allocator = allocator,
        .sample_rate = config.sample_rate,
        .buffer_duration_ms = config.buffer_duration_ms,
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
    } else {
        return error.UnsupportedPlatform;
    }

    self.is_recording = true;
}

pub fn stop(self: *AudioCapture) void {
    if (!self.is_recording) return;

    if (builtin.os.tag == .macos) {
        self.stopCoreAudio();
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

pub fn detectVoiceActivity(samples: []const f32, threshold: f32) bool {
    if (samples.len == 0) return false;

    const energy = simd.sumOfSquares(samples) / @as(f32, @floatFromInt(samples.len));
    return energy > threshold;
}

pub const TrimBounds = struct {
    start: usize,
    end: usize,
};

pub fn trimSilenceBounds(samples: []const f32, threshold: f32) TrimBounds {
    if (samples.len == 0) return .{ .start = 0, .end = 0 };

    const window_size: usize = 160;

    var start_idx: usize = 0;
    while (start_idx + window_size < samples.len) {
        if (detectVoiceActivity(samples[start_idx .. start_idx + window_size], threshold)) {
            break;
        }
        start_idx += window_size / 2;
    }

    var end_idx: usize = samples.len;
    while (end_idx > start_idx + window_size) {
        if (detectVoiceActivity(samples[end_idx - window_size .. end_idx], threshold)) {
            break;
        }
        end_idx -= window_size / 2;
    }

    // Keep 0.5s of trailing context so whisper can finalize the last token
    const tail_padding: usize = 8000;
    end_idx = @min(samples.len, end_idx + tail_padding);

    return .{ .start = start_idx, .end = end_idx };
}

/// Estimate ambient noise floor from the first ~0.5s of audio.
/// Returns the RMS energy of a leading window, useful for deriving
/// an adaptive silence-trim threshold (e.g. 3× noise floor).
pub fn computeNoiseFloor(samples: []const f32) f32 {
    if (samples.len == 0) return 0;

    const window: usize = @min(8000, samples.len);
    const energy = simd.sumOfSquares(samples[0..window]);
    return @sqrt(energy / @as(f32, @floatFromInt(window)));
}

/// In-place peak normalization. Scales `samples` so the largest absolute
/// amplitude becomes `target_peak` (typically 0.95 to avoid hard clipping).
/// Returns the gain factor that was applied. Only ever scales up: if the
/// input is already at or above `target_peak` the buffer is unchanged.
/// Silent buffers (peak < 1e-4) are also left alone to avoid amplifying noise.
///
/// Whispered speech routinely has peaks of ~0.25 vs. ~0.6 for normal voice,
/// which produced a 4–7× WER improvement in the `tune` experiments. Applying
/// this before trimming and transcription is safe for normal voice (the gain
/// factor stays near 1.0) but materially helps quiet audio.
pub fn peakNormalize(samples: []f32, target_peak: f32) f32 {
    std.debug.assert(target_peak > 0.0);
    std.debug.assert(target_peak <= 1.0);
    if (samples.len == 0) return 1.0;

    const peak = simd.maxAbs(samples);
    if (peak < 1e-4 or peak >= target_peak) return 1.0;

    const gain = target_peak / peak;
    simd.scale(samples, gain);
    return gain;
}

pub fn resample(allocator: std.mem.Allocator, samples: []const f32, from_rate: f64, to_rate: f64) ![]f32 {
    if (from_rate == to_rate) {
        return allocator.dupe(f32, samples);
    }

    const ratio = from_rate / to_rate;
    const new_len: usize = @intFromFloat(@as(f64, @floatFromInt(samples.len)) / ratio);

    const output = try allocator.alloc(f32, new_len);

    for (0..new_len) |i| {
        const src_idx = @as(f64, @floatFromInt(i)) * ratio;
        const idx: usize = @intFromFloat(src_idx);
        const frac = src_idx - @as(f64, @floatFromInt(idx));

        if (idx + 1 < samples.len) {
            output[i] = samples[idx] * @as(f32, @floatCast(1.0 - frac)) +
                samples[idx + 1] * @as(f32, @floatCast(frac));
        } else {
            output[i] = samples[idx];
        }
    }

    return output;
}

test "voice activity detection" {
    const silence = [_]f32{0.0} ** 100;
    const voice = [_]f32{0.5} ** 100;

    try std.testing.expect(!detectVoiceActivity(&silence, 0.01));
    try std.testing.expect(detectVoiceActivity(&voice, 0.01));
}

test "compute noise floor" {
    const silence = [_]f32{0.0} ** 100;
    const noise = [_]f32{0.1} ** 100;

    try std.testing.expectEqual(@as(f32, 0), computeNoiseFloor(&silence));
    try std.testing.expect(computeNoiseFloor(&noise) > 0.09);
    try std.testing.expect(computeNoiseFloor(&noise) < 0.11);
    try std.testing.expectEqual(@as(f32, 0), computeNoiseFloor(&[_]f32{}));
}

test "peakNormalize boosts quiet audio" {
    var samples = [_]f32{ 0.1, -0.2, 0.05, -0.1 };
    const gain = peakNormalize(&samples, 0.95);
    try std.testing.expectApproxEqAbs(@as(f32, 4.75), gain, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.95), samples[1], 0.001);
}

test "peakNormalize leaves loud audio unchanged" {
    var samples = [_]f32{ 0.5, -0.95 };
    const gain = peakNormalize(&samples, 0.95);
    try std.testing.expectEqual(@as(f32, 1.0), gain);
    try std.testing.expectEqual(@as(f32, 0.5), samples[0]);
}

test "peakNormalize handles silence" {
    var silence = [_]f32{0.0} ** 8;
    const gain = peakNormalize(&silence, 0.95);
    try std.testing.expectEqual(@as(f32, 1.0), gain);
}

test "peakNormalize empty buffer" {
    var empty: [0]f32 = .{};
    const gain = peakNormalize(&empty, 0.95);
    try std.testing.expectEqual(@as(f32, 1.0), gain);
}
