//! Single-producer single-consumer sample ring.
//!
//! The producer is a real-time audio callback: CoreAudio's AudioQueue thread or
//! the ALSA reader thread. It must never block and never allocate, so the ring
//! is fixed-size and overruns drop the oldest audio rather than growing or
//! stalling. Dropped samples are counted, because silently losing audio is worse
//! than knowing you lost it.
//!
//! Deliberately not lock-free: a mutex held for a memcpy is fine at these buffer
//! sizes, and getting a lock-free ring subtly wrong is a class of bug that only
//! shows up as rare audio corruption. The lock is uncontended in practice —
//! producer and consumer touch it a few hundred times a second.

const std = @import("std");

const Ring = @This();

/// std.Thread.Mutex does not exist in Zig 0.16, and std.Io.Mutex needs an Io
/// handle a real-time audio callback has no way to obtain. Spinning on
/// std.atomic.Mutex is what the existing capture code does, and the critical
/// section here is a memcpy.
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
samples: []f32,
/// Next write position.
head: usize = 0,
/// Number of valid samples behind `head`.
len: usize = 0,
/// Samples the producer had to discard because the consumer fell behind.
dropped: u64 = 0,
mutex: SpinMutex = .{},

pub fn init(allocator: std.mem.Allocator, capacity: usize) !Ring {
    std.debug.assert(capacity > 0);
    return .{
        .allocator = allocator,
        .samples = try allocator.alloc(f32, capacity),
    };
}

pub fn deinit(self: *Ring) void {
    self.allocator.free(self.samples);
}

/// Producer side. Never fails; on overrun the oldest samples are dropped.
pub fn write(self: *Ring, incoming: []const f32) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    // A push larger than the whole ring can only keep its tail.
    const source = if (incoming.len > self.samples.len) blk: {
        self.dropped += incoming.len - self.samples.len;
        break :blk incoming[incoming.len - self.samples.len ..];
    } else incoming;

    for (source) |sample| {
        self.samples[self.head] = sample;
        self.head = (self.head + 1) % self.samples.len;
        if (self.len < self.samples.len) {
            self.len += 1;
        } else {
            // Overwrote an unread sample.
            self.dropped += 1;
        }
    }
}

/// Consumer side. Copies out up to `out.len` samples, oldest first, and returns
/// how many were written.
pub fn read(self: *Ring, out: []f32) usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    const count = @min(out.len, self.len);
    const start = (self.head + self.samples.len - self.len) % self.samples.len;
    for (0..count) |i| {
        out[i] = self.samples[(start + i) % self.samples.len];
    }
    self.len -= count;
    return count;
}

pub fn available(self: *Ring) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.len;
}

pub fn droppedCount(self: *Ring) u64 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.dropped;
}

pub fn clear(self: *Ring) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.head = 0;
    self.len = 0;
    self.dropped = 0;
}

test "writes and reads in order" {
    var ring = try Ring.init(std.testing.allocator, 8);
    defer ring.deinit();

    ring.write(&[_]f32{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 3), ring.available());

    var out: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 3), ring.read(&out));
    try std.testing.expectEqualSlices(f32, &[_]f32{ 1, 2, 3 }, out[0..3]);
    try std.testing.expectEqual(@as(usize, 0), ring.available());
}

test "reading an empty ring yields nothing" {
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();
    var out: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), ring.read(&out));
}

test "wraps around the end of the buffer" {
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    ring.write(&[_]f32{ 1, 2, 3 });
    var out: [2]f32 = undefined;
    _ = ring.read(&out); // consume 1,2 -> head=3, start=2
    ring.write(&[_]f32{ 4, 5, 6 }); // wraps

    var rest: [4]f32 = undefined;
    const n = ring.read(&rest);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 3, 4, 5, 6 }, rest[0..n]);
    try std.testing.expectEqual(@as(u64, 0), ring.droppedCount());
}

test "overrun drops the oldest samples and counts them" {
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    ring.write(&[_]f32{ 1, 2, 3, 4 });
    ring.write(&[_]f32{ 5, 6 }); // pushes 1,2 out

    try std.testing.expectEqual(@as(u64, 2), ring.droppedCount());
    var out: [4]f32 = undefined;
    const n = ring.read(&out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 3, 4, 5, 6 }, out[0..n]);
}

test "a push larger than the ring keeps the newest audio" {
    var ring = try Ring.init(std.testing.allocator, 3);
    defer ring.deinit();

    ring.write(&[_]f32{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(@as(u64, 2), ring.droppedCount());

    var out: [3]f32 = undefined;
    const n = ring.read(&out);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 3, 4, 5 }, out[0..n]);
}

test "partial reads leave the remainder in order" {
    var ring = try Ring.init(std.testing.allocator, 8);
    defer ring.deinit();

    ring.write(&[_]f32{ 1, 2, 3, 4, 5 });
    var two: [2]f32 = undefined;
    _ = ring.read(&two);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 1, 2 }, &two);

    var rest: [8]f32 = undefined;
    const n = ring.read(&rest);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 3, 4, 5 }, rest[0..n]);
}

test "clear discards everything including the drop count" {
    var ring = try Ring.init(std.testing.allocator, 2);
    defer ring.deinit();
    ring.write(&[_]f32{ 1, 2, 3 });
    ring.clear();
    try std.testing.expectEqual(@as(usize, 0), ring.available());
    try std.testing.expectEqual(@as(u64, 0), ring.droppedCount());
}

test "survives a concurrent producer and consumer" {
    var ring = try Ring.init(std.testing.allocator, 1024);
    defer ring.deinit();

    const Producer = struct {
        fn run(r: *Ring) void {
            var block: [64]f32 = undefined;
            for (0..200) |i| {
                @memset(&block, @floatFromInt(i % 8));
                r.write(&block);
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Producer.run, .{&ring});
    var out: [128]f32 = undefined;
    var total: usize = 0;
    for (0..500) |_| total += ring.read(&out);
    thread.join();
    total += ring.read(&out);

    // Exact counts depend on scheduling; the invariant is that nothing is
    // corrupted and every sample is accounted for as either read or dropped.
    try std.testing.expect(total + ring.droppedCount() + ring.available() == 200 * 64);
}
