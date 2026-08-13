//! Fallback backend for hosts without one yet — Windows, and anything else.
//!
//! It exists so the library still compiles and links everywhere: a consumer on
//! an unsupported host gets `error.UnsupportedPlatform` from `open`, which is a
//! diagnosable runtime error, rather than a link failure or a build that refuses
//! to configure. Device enumeration returns an empty list for the same reason.

const std = @import("std");
const capture = @import("main.zig");

/// No backend for this host.
pub const supported = false;

pub fn open(
    allocator: std.mem.Allocator,
    options: capture.Options,
    ring: *capture.Ring,
) capture.Error!capture.Backend {
    _ = .{ allocator, options, ring };
    return capture.Error.UnsupportedPlatform;
}

pub fn listDevices(allocator: std.mem.Allocator) capture.Error![]capture.Device {
    return allocator.alloc(capture.Device, 0) catch capture.Error.OutOfMemory;
}

test "open reports an unsupported platform rather than crashing" {
    var ring = try capture.Ring.init(std.testing.allocator, 16);
    defer ring.deinit();
    try std.testing.expectError(
        capture.Error.UnsupportedPlatform,
        open(std.testing.allocator, .{}, &ring),
    );
}

test "device enumeration yields an empty list" {
    const devices = try listDevices(std.testing.allocator);
    defer capture.freeDevices(std.testing.allocator, devices);
    try std.testing.expectEqual(@as(usize, 0), devices.len);
}
