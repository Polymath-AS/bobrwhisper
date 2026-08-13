//! Accumulates a capture stream into fixed-size chunks, with optional overlap.
//!
//! Capture backends deliver whatever buffer size the device feels like — 512
//! frames here, 1024 there — while an ASR engine wants windows of a size it
//! chooses. This sits between them.
//!
//! Overlap exists because a word split across a chunk boundary is usually lost
//! by both chunks. Carrying the tail of each chunk into the next gives the
//! decoder the context to finish it; the caller is responsible for reconciling
//! the duplicated text.

const std = @import("std");

const Chunker = @This();

allocator: std.mem.Allocator,
buffer: std.ArrayListUnmanaged(f32),
/// Consumed prefix. Advancing a cursor rather than moving memory on every
/// `next` is what lets a returned chunk stay valid until the following `push`;
/// compacting inside `next` would rewrite the slice it just handed out.
read_pos: usize,
chunk_len: usize,
overlap_len: usize,

pub const Options = struct {
    /// Samples per emitted chunk.
    chunk_len: usize,
    /// Samples of the previous chunk to prepend to the next. Must be less than
    /// `chunk_len`, or a chunk would never make forward progress.
    overlap_len: usize = 0,
};

pub fn init(allocator: std.mem.Allocator, options: Options) Chunker {
    std.debug.assert(options.chunk_len > 0);
    std.debug.assert(options.overlap_len < options.chunk_len);
    return .{
        .allocator = allocator,
        .buffer = .empty,
        .read_pos = 0,
        .chunk_len = options.chunk_len,
        .overlap_len = options.overlap_len,
    };
}

pub fn deinit(self: *Chunker) void {
    self.buffer.deinit(self.allocator);
}

/// Appending invalidates any chunk previously returned by `next`.
pub fn push(self: *Chunker, samples: []const f32) !void {
    self.compact();
    try self.buffer.appendSlice(self.allocator, samples);
}

/// Unconsumed samples.
pub fn available(self: *const Chunker) usize {
    return self.buffer.items.len - self.read_pos;
}

/// The number of whole chunks `next` will yield before returning null.
pub fn ready(self: *const Chunker) usize {
    const have = self.available();
    if (have < self.chunk_len) return 0;
    const advance = self.chunk_len - self.overlap_len;
    return 1 + (have - self.chunk_len) / advance;
}

/// Borrow the next chunk, or null if one is not complete yet. The slice points
/// into the chunker's buffer and stays valid until the next `push` or `reset`.
pub fn next(self: *Chunker) ?[]const f32 {
    if (self.available() < self.chunk_len) return null;

    const chunk = self.buffer.items[self.read_pos..][0..self.chunk_len];
    self.read_pos += self.chunk_len - self.overlap_len;
    return chunk;
}

/// Samples held back because they do not fill a chunk. Use at end of stream,
/// where a short final window is better than dropping the tail.
pub fn flush(self: *Chunker) []const f32 {
    return self.buffer.items[self.read_pos..];
}

pub fn reset(self: *Chunker) void {
    self.buffer.clearRetainingCapacity();
    self.read_pos = 0;
}

/// Drop the consumed prefix. Only called from `push`, where the chunk-validity
/// contract already ends.
fn compact(self: *Chunker) void {
    if (self.read_pos == 0) return;
    const remaining = self.available();
    std.mem.copyForwards(
        f32,
        self.buffer.items[0..remaining],
        self.buffer.items[self.read_pos..],
    );
    self.buffer.items.len = remaining;
    self.read_pos = 0;
}

test "emits nothing until a chunk is full" {
    var chunker = Chunker.init(std.testing.allocator, .{ .chunk_len = 4 });
    defer chunker.deinit();

    try chunker.push(&[_]f32{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 0), chunker.ready());
    try std.testing.expect(chunker.next() == null);

    try chunker.push(&[_]f32{4});
    try std.testing.expectEqual(@as(usize, 1), chunker.ready());
}

test "emits consecutive chunks without overlap" {
    var chunker = Chunker.init(std.testing.allocator, .{ .chunk_len = 3 });
    defer chunker.deinit();

    try chunker.push(&[_]f32{ 1, 2, 3, 4, 5, 6, 7 });
    try std.testing.expectEqual(@as(usize, 2), chunker.ready());

    try std.testing.expectEqualSlices(f32, &[_]f32{ 1, 2, 3 }, chunker.next().?);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 4, 5, 6 }, chunker.next().?);
    try std.testing.expect(chunker.next() == null);
    try std.testing.expectEqualSlices(f32, &[_]f32{7}, chunker.flush());
}

test "overlap repeats the tail of the previous chunk" {
    var chunker = Chunker.init(std.testing.allocator, .{ .chunk_len = 4, .overlap_len = 2 });
    defer chunker.deinit();

    try chunker.push(&[_]f32{ 1, 2, 3, 4, 5, 6 });
    try std.testing.expectEqualSlices(f32, &[_]f32{ 1, 2, 3, 4 }, chunker.next().?);
    // Advance is 2, so the next window starts at sample 3.
    try std.testing.expectEqualSlices(f32, &[_]f32{ 3, 4, 5, 6 }, chunker.next().?);
}

test "ready agrees with how many chunks next actually yields" {
    var chunker = Chunker.init(std.testing.allocator, .{ .chunk_len = 4, .overlap_len = 1 });
    defer chunker.deinit();

    try chunker.push(&[_]f32{0} ** 13);
    const expected = chunker.ready();
    var count: usize = 0;
    while (chunker.next() != null) count += 1;
    try std.testing.expectEqual(expected, count);
}

test "accepts a push larger than the chunk size" {
    var chunker = Chunker.init(std.testing.allocator, .{ .chunk_len = 2 });
    defer chunker.deinit();

    try chunker.push(&[_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try std.testing.expectEqual(@as(usize, 4), chunker.ready());
}

test "reset drops buffered samples" {
    var chunker = Chunker.init(std.testing.allocator, .{ .chunk_len = 4 });
    defer chunker.deinit();

    try chunker.push(&[_]f32{ 1, 2, 3 });
    chunker.reset();
    try std.testing.expectEqual(@as(usize, 0), chunker.flush().len);
    try std.testing.expect(chunker.next() == null);
}

test "empty pushes are harmless" {
    var chunker = Chunker.init(std.testing.allocator, .{ .chunk_len = 2 });
    defer chunker.deinit();
    try chunker.push(&[_]f32{});
    try std.testing.expectEqual(@as(usize, 0), chunker.ready());
}
