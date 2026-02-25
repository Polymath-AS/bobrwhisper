//! Audio capture using CoreAudio (macOS)

const std = @import("std");
const builtin = @import("builtin");

const c = if (builtin.os.tag == .macos) @cImport({
    @cInclude("AudioToolbox/AudioToolbox.h");
}) else struct {};

const AudioCapture = @This();

allocator: std.mem.Allocator,
is_recording: bool = false,
sample_rate: f64 = 16000.0,

// CoreAudio handles (macOS only)
audio_queue: if (builtin.os.tag == .macos) c.AudioQueueRef else void =
    if (builtin.os.tag == .macos) null else {},

// Buffer for captured audio (protected by mutex for thread safety)
buffer: std.ArrayListUnmanaged(f32),
mutex: std.Thread.Mutex = .{},
// RMS audio level from the most recent callback buffer, updated under mutex
audio_level: f32 = 0,

pub const Config = struct {
    sample_rate: f64 = 16000.0,
    channels: u32 = 1,
    buffer_duration_ms: u32 = 100,
};

pub fn init(allocator: std.mem.Allocator) !AudioCapture {
    return initWithConfig(allocator, .{});
}

pub fn initWithConfig(allocator: std.mem.Allocator, config: Config) !AudioCapture {
    return .{
        .allocator = allocator,
        .sample_rate = config.sample_rate,
        .buffer = .{},
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
    const buffer_size: u32 = @intFromFloat(self.sample_rate * 0.1 * @sizeOf(f32));
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

    // Flush ensures all in-flight buffers are delivered via the callback
    // before we stop, so we don't lose the final ~100-200ms of audio.
    _ = c.AudioQueueFlush(self.audio_queue);
    _ = c.AudioQueueStop(self.audio_queue, 1);
}

// CoreAudio callback
fn audioInputCallback(
    userdata: ?*anyopaque,
    queue: c.AudioQueueRef,
    buffer: c.AudioQueueBufferRef,
    _: [*c]const c.AudioTimeStamp,
    num_packets: u32,
    _: [*c]const c.AudioStreamPacketDescription,
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

        // Compute RMS audio level from this callback buffer
        var energy: f32 = 0;
        for (samples[0..sample_count]) |s| {
            energy += s * s;
        }
        self.audio_level = @sqrt(energy / @as(f32, @floatFromInt(sample_count)));
    }

    _ = c.AudioQueueEnqueueBuffer(queue, buffer, 0, null);
}

pub fn detectVoiceActivity(samples: []const f32, threshold: f32) bool {
    if (samples.len == 0) return false;

    var energy: f32 = 0;
    for (samples) |s| {
        energy += s * s;
    }
    energy /= @floatFromInt(samples.len);

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
