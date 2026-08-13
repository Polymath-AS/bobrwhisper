//! ALSA capture backend.
//!
//! ALSA has no callback model worth using from Zig, so this owns a reader thread
//! that blocks in `snd_pcm_readi` and pushes into the ring. That thread is the
//! producer the ring is designed around.
//!
//! The extern surface is kept narrow on purpose: the alternative is translating
//! all of alsa/asoundlib.h, which pulls in a large amount of API this library
//! will never call. It links `asound` directly rather than dlopen'ing it, which
//! is worth revisiting — a host without ALSA currently fails to load the whole
//! library rather than just this backend.

const std = @import("std");
const capture = @import("main.zig");

const c = struct {
    pub const SndPcm = opaque {};
    pub const SND_PCM_STREAM_CAPTURE: c_int = 1;
    pub const SND_PCM_ACCESS_RW_INTERLEAVED: c_int = 3;
    pub const SND_PCM_FORMAT_FLOAT_LE: c_int = 10;

    pub extern "asound" fn snd_pcm_open(
        pcm: *?*SndPcm,
        name: [*:0]const u8,
        stream: c_int,
        mode: c_int,
    ) c_int;
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

/// Frames per read. 1024 at 16 kHz is 64 ms, which keeps the syscall rate low
/// without adding latency a dictation UI would notice.
const frames_per_read = 1024;

const Alsa = struct {
    allocator: std.mem.Allocator,
    ring: *capture.Ring,
    pcm: ?*c.SndPcm = null,
    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = .init(false),
    channels: u16,
    sample_rate: u32,
};

pub fn open(
    allocator: std.mem.Allocator,
    options: capture.Options,
    ring: *capture.Ring,
) capture.Error!capture.Backend {
    const self = allocator.create(Alsa) catch return capture.Error.OutOfMemory;
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .ring = ring,
        .channels = options.channels,
        .sample_rate = options.sample_rate,
    };

    // A device_id is an ALSA name such as "default" or "hw:1,0".
    const name = options.device_id orelse "default";
    const name_z = allocator.dupeZ(u8, name) catch return capture.Error.OutOfMemory;
    defer allocator.free(name_z);

    var pcm: ?*c.SndPcm = null;
    if (c.snd_pcm_open(&pcm, name_z.ptr, c.SND_PCM_STREAM_CAPTURE, 0) < 0) {
        return capture.Error.DeviceNotFound;
    }
    errdefer _ = c.snd_pcm_close(pcm);

    // soft_resample = 1 lets ALSA convert when the device cannot do our rate
    // natively, which is common: many devices are 44.1/48 kHz only.
    if (c.snd_pcm_set_params(
        pcm,
        c.SND_PCM_FORMAT_FLOAT_LE,
        c.SND_PCM_ACCESS_RW_INTERLEAVED,
        options.channels,
        options.sample_rate,
        1,
        100_000, // 100 ms of device-side latency
    ) < 0) {
        return capture.Error.OpenFailed;
    }

    self.pcm = pcm;
    return .{
        .ptr = self,
        .vtable = &.{ .start = start, .stop = stop, .destroy = destroy },
    };
}

fn start(ptr: *anyopaque) capture.Error!void {
    const self: *Alsa = @ptrCast(@alignCast(ptr));
    if (self.thread != null) return capture.Error.AlreadyRunning;
    self.should_stop.store(false, .release);
    self.thread = std.Thread.spawn(.{}, readLoop, .{self}) catch
        return capture.Error.OpenFailed;
}

fn stop(ptr: *anyopaque) void {
    const self: *Alsa = @ptrCast(@alignCast(ptr));
    self.should_stop.store(true, .release);
    if (self.thread) |thread| {
        // Unblock a reader sitting in snd_pcm_readi.
        _ = c.snd_pcm_drop(self.pcm);
        thread.join();
        self.thread = null;
    }
}

fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *Alsa = @ptrCast(@alignCast(ptr));
    stop(ptr);
    if (self.pcm) |pcm| _ = c.snd_pcm_close(pcm);
    allocator.destroy(self);
}

fn readLoop(self: *Alsa) void {
    // Interleaved scratch, sized for the widest channel count we accept.
    var scratch: [frames_per_read * 8]f32 = undefined;
    const wanted = frames_per_read * @as(usize, self.channels);
    const buffer = scratch[0..@min(wanted, scratch.len)];
    const frames = buffer.len / self.channels;

    var mono: [frames_per_read]f32 = undefined;

    while (!self.should_stop.load(.acquire)) {
        const read = c.snd_pcm_readi(self.pcm, buffer.ptr, frames);
        if (read < 0) {
            // Recover from xruns; anything unrecoverable ends the loop rather
            // than spinning on a dead device.
            if (c.snd_pcm_recover(self.pcm, @intCast(read), 1) < 0) return;
            continue;
        }
        const got: usize = @intCast(read);
        if (got == 0) continue;

        if (self.channels == 1) {
            self.ring.write(buffer[0..got]);
        } else {
            // Downmix here rather than in the audio library: this is the
            // real-time path, so it must not allocate.
            const count = @min(got, mono.len);
            for (0..count) |frame| {
                var sum: f32 = 0;
                for (0..self.channels) |ch| sum += buffer[frame * self.channels + ch];
                mono[frame] = sum / @as(f32, @floatFromInt(self.channels));
            }
            self.ring.write(mono[0..count]);
        }
    }
}

pub fn listDevices(allocator: std.mem.Allocator) capture.Error![]capture.Device {
    // Enumerating ALSA properly means walking snd_device_name_hint, which is a
    // wider extern surface than this backend currently justifies. "default"
    // always exists and honours the user's system configuration, so report that
    // and let a caller pass any ALSA name through Options.device_id.
    const devices = allocator.alloc(capture.Device, 1) catch return capture.Error.OutOfMemory;
    errdefer allocator.free(devices);

    const id = allocator.dupe(u8, "default") catch return capture.Error.OutOfMemory;
    errdefer allocator.free(id);
    const name = allocator.dupe(u8, "System default input") catch return capture.Error.OutOfMemory;

    devices[0] = .{ .id = id, .name = name, .is_default = true };
    return devices;
}

test "lists at least the default device" {
    const devices = try listDevices(std.testing.allocator);
    defer capture.freeDevices(std.testing.allocator, devices);

    try std.testing.expect(devices.len >= 1);
    try std.testing.expect(devices[0].is_default);
    try std.testing.expectEqualStrings("default", devices[0].id);
}

// Opening a device is not tested: CI has no sound card, and a test that passes
// only on a developer's laptop is worse than no test. The lifecycle around
// open/start/stop is covered in main.zig through a substitute backend.
