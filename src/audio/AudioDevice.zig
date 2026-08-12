//! Input-device discovery shared by the core and its frontends.
//!
//! Tags each recorded snippet with the audio source (built-in mic, AirPods,
//! USB interface, ...) so the test corpus can be sliced by hardware. Keeps
//! the CoreAudio surface small: three property reads on the system + device
//! objects, no full SDK translation.

const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    internal,
    bluetooth,
    usb,
    unknown,

    pub fn fromString(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }
};

pub const Info = struct {
    /// Heap-allocated. Caller owns; free with `deinit`.
    name: []u8,
    kind: Kind,
    /// Stable native device identifier: a CoreAudio device UID on macOS and
    /// an ALSA device name on Linux.
    id: []u8,

    pub fn deinit(self: Info, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.id);
    }
};

pub fn listInputDevices(allocator: std.mem.Allocator) ![]Info {
    if (comptime builtin.os.tag == .linux) {
        var devices = try allocator.alloc(Info, 1);
        errdefer allocator.free(devices);
        const id = try allocator.dupe(u8, "default");
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, "System default");
        devices[0] = .{
            .id = id,
            .name = name,
            .kind = .unknown,
        };
        return devices;
    }
    if (comptime builtin.os.tag != .macos) return allocator.alloc(Info, 0);
    return listMacosInputDevices(allocator);
}

pub fn freeList(allocator: std.mem.Allocator, devices: []Info) void {
    for (devices) |device| device.deinit(allocator);
    allocator.free(devices);
}

const c = if (builtin.os.tag == .macos) MacCoreAudio else struct {};

const MacCoreAudio = struct {
    pub const OSStatus = i32;
    pub const UInt32 = u32;
    pub const AudioObjectID = UInt32;

    pub const AudioObjectPropertyAddress = extern struct {
        mSelector: UInt32,
        mScope: UInt32,
        mElement: UInt32,
    };

    pub const CFStringRef = ?*opaque {};
    pub const CFTypeRef = ?*anyopaque;

    pub extern "c" fn AudioObjectGetPropertyData(
        inObjectID: AudioObjectID,
        inAddress: *const AudioObjectPropertyAddress,
        inQualifierDataSize: UInt32,
        inQualifierData: ?*const anyopaque,
        ioDataSize: *UInt32,
        outData: *anyopaque,
    ) OSStatus;

    pub extern "c" fn AudioObjectGetPropertyDataSize(
        inObjectID: AudioObjectID,
        inAddress: *const AudioObjectPropertyAddress,
        inQualifierDataSize: UInt32,
        inQualifierData: ?*const anyopaque,
        outDataSize: *UInt32,
    ) OSStatus;

    pub extern "c" fn CFStringGetCString(
        theString: CFStringRef,
        buffer: [*]u8,
        bufferSize: c_long,
        encoding: u32,
    ) i32;

    pub extern "c" fn CFRelease(cf: CFTypeRef) void;

    pub const kAudioObjectSystemObject: AudioObjectID = 1;
    pub const kAudioObjectPropertyElementMain: UInt32 = 0;
    pub const kCFStringEncodingUTF8: u32 = 0x08000100;
};

inline fn fourCC(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

/// Best-effort default-input device label. Returns null when we are not on
/// macOS or CoreAudio refuses to cooperate (e.g. no input device, headless
/// CI). Caller owns the returned `Info.name`.
pub fn detectDefaultInput(allocator: std.mem.Allocator) ?Info {
    if (comptime builtin.os.tag != .macos) return null;
    return detectMacos(allocator) catch null;
}

/// Resolves an app-selected input device without changing the system default.
/// A null or empty identifier follows the current system default.
pub fn detectInput(allocator: std.mem.Allocator, selected_id: ?[]const u8) ?Info {
    const id = selected_id orelse return detectDefaultInput(allocator);
    if (id.len == 0) return detectDefaultInput(allocator);

    const devices = listInputDevices(allocator) catch return null;
    defer freeList(allocator, devices);
    for (devices) |device| {
        if (!std.mem.eql(u8, device.id, id)) continue;
        const name = allocator.dupe(u8, device.name) catch return null;
        const id_copy = allocator.dupe(u8, device.id) catch {
            allocator.free(name);
            return null;
        };
        return .{ .name = name, .kind = device.kind, .id = id_copy };
    }
    return null;
}

fn detectMacos(allocator: std.mem.Allocator) !Info {
    const device_id = try defaultInputDeviceId();
    const name = try deviceName(allocator, device_id);
    errdefer allocator.free(name);
    const kind = transportKind(device_id);
    const id = try deviceUid(allocator, device_id);
    return .{ .name = name, .kind = kind, .id = id };
}

fn listMacosInputDevices(allocator: std.mem.Allocator) ![]Info {
    const addr = c.AudioObjectPropertyAddress{
        .mSelector = comptime fourCC("dev#"),
        .mScope = comptime fourCC("glob"),
        .mElement = c.kAudioObjectPropertyElementMain,
    };
    var size: c.UInt32 = 0;
    if (c.AudioObjectGetPropertyDataSize(c.kAudioObjectSystemObject, &addr, 0, null, &size) != 0) {
        return error.DeviceEnumerationFailed;
    }
    const count = size / @sizeOf(c.AudioObjectID);
    const ids = try allocator.alloc(c.AudioObjectID, count);
    defer allocator.free(ids);
    if (c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &addr, 0, null, &size, ids.ptr) != 0) {
        return error.DeviceEnumerationFailed;
    }

    var result = std.ArrayListUnmanaged(Info).empty;
    errdefer {
        for (result.items) |device| device.deinit(allocator);
        result.deinit(allocator);
    }
    for (ids) |device_id| {
        if (!hasInputChannels(device_id)) continue;
        const name = deviceName(allocator, device_id) catch continue;
        const id = deviceUid(allocator, device_id) catch {
            allocator.free(name);
            continue;
        };
        result.append(allocator, .{
            .name = name,
            .id = id,
            .kind = transportKind(device_id),
        }) catch {
            allocator.free(name);
            allocator.free(id);
            return error.OutOfMemory;
        };
    }
    return result.toOwnedSlice(allocator);
}

fn hasInputChannels(device_id: c.AudioObjectID) bool {
    const addr = c.AudioObjectPropertyAddress{
        .mSelector = comptime fourCC("stm#"),
        .mScope = comptime fourCC("inpt"),
        .mElement = c.kAudioObjectPropertyElementMain,
    };
    var size: c.UInt32 = 0;
    if (c.AudioObjectGetPropertyDataSize(device_id, &addr, 0, null, &size) != 0) return false;
    return size != 0;
}

fn defaultInputDeviceId() !c.AudioObjectID {
    const addr = c.AudioObjectPropertyAddress{
        .mSelector = comptime fourCC("dIn "),
        .mScope = comptime fourCC("glob"),
        .mElement = c.kAudioObjectPropertyElementMain,
    };
    var device_id: c.AudioObjectID = 0;
    var size: c.UInt32 = @sizeOf(c.AudioObjectID);
    const status = c.AudioObjectGetPropertyData(
        c.kAudioObjectSystemObject,
        &addr,
        0,
        null,
        &size,
        @ptrCast(&device_id),
    );
    if (status != 0 or device_id == 0) return error.NoDefaultInput;
    return device_id;
}

fn deviceName(allocator: std.mem.Allocator, device_id: c.AudioObjectID) ![]u8 {
    return stringProperty(allocator, device_id, comptime fourCC("lnam"));
}

fn deviceUid(allocator: std.mem.Allocator, device_id: c.AudioObjectID) ![]u8 {
    return stringProperty(allocator, device_id, comptime fourCC("uid "));
}

fn stringProperty(allocator: std.mem.Allocator, device_id: c.AudioObjectID, selector: u32) ![]u8 {
    const addr = c.AudioObjectPropertyAddress{
        .mSelector = selector,
        .mScope = comptime fourCC("glob"),
        .mElement = c.kAudioObjectPropertyElementMain,
    };
    var name_ref: c.CFStringRef = null;
    var size: c.UInt32 = @sizeOf(c.CFStringRef);
    const status = c.AudioObjectGetPropertyData(
        device_id,
        &addr,
        0,
        null,
        &size,
        @ptrCast(&name_ref),
    );
    if (status != 0 or name_ref == null) return error.NoStringProperty;
    defer c.CFRelease(name_ref);

    // Device names are short. 256 bytes covers everything Apple ships and any
    // reasonable third-party label without bringing CFStringGetMaximumSizeForEncoding in.
    var buf: [256]u8 = undefined;
    if (c.CFStringGetCString(name_ref, &buf, buf.len, c.kCFStringEncodingUTF8) == 0) {
        return error.NameDecode;
    }
    const slice = std.mem.sliceTo(&buf, 0);
    return allocator.dupe(u8, slice);
}

fn transportKind(device_id: c.AudioObjectID) Kind {
    const addr = c.AudioObjectPropertyAddress{
        .mSelector = comptime fourCC("tran"),
        .mScope = comptime fourCC("glob"),
        .mElement = c.kAudioObjectPropertyElementMain,
    };
    var transport: c.UInt32 = 0;
    var size: c.UInt32 = @sizeOf(c.UInt32);
    const status = c.AudioObjectGetPropertyData(
        device_id,
        &addr,
        0,
        null,
        &size,
        @ptrCast(&transport),
    );
    if (status != 0) return .unknown;

    return switch (transport) {
        comptime fourCC("bltn") => .internal,
        comptime fourCC("blue"), comptime fourCC("blea") => .bluetooth,
        comptime fourCC("usb ") => .usb,
        else => .unknown,
    };
}

test "Kind.fromString round-trip" {
    try std.testing.expectEqual(Kind.internal, Kind.fromString("internal").?);
    try std.testing.expectEqual(Kind.bluetooth, Kind.fromString("bluetooth").?);
    try std.testing.expectEqual(Kind.usb, Kind.fromString("usb").?);
    try std.testing.expectEqual(Kind.unknown, Kind.fromString("unknown").?);
    try std.testing.expectEqual(@as(?Kind, null), Kind.fromString("nope"));
}
