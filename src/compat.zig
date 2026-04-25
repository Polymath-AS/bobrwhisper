const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn accessAbsolute(path: []const u8) !void {
    return std.Io.Dir.accessAbsolute(io(), path, .{});
}

pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(io(), .real).toMilliseconds();
}

pub fn nanoTimestamp() i128 {
    return @intCast(std.Io.Timestamp.now(io(), .awake).toNanoseconds());
}

pub fn sleepNanoseconds(nanoseconds: u64) void {
    std.Io.sleep(io(), .fromNanoseconds(@intCast(nanoseconds)), .awake) catch {};
}

pub fn getenv(name: [:0]const u8) ?[:0]const u8 {
    const value = getenv_c(name.ptr) orelse return null;
    return std.mem.span(value);
}

const getenv_c: *const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8 = @extern(*const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8, .{ .name = "getenv" });
