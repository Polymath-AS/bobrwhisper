const std = @import("std");

pub const Config = @This();

target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,

pub fn init(b: *std.Build) Config {
    return .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };
}

pub fn xcframeworkOptimize(self: *const Config) std.builtin.OptimizeMode {
    // Always use ReleaseFast for xcframework - ggml uses pointer arithmetic
    // that triggers safety checks in Debug/ReleaseSafe modes
    _ = self;
    return .ReleaseFast;
}

pub fn xcodebuildConfiguration(self: *const Config) []const u8 {
    return if (self.optimize == .Debug) "Debug" else "Release";
}

pub fn macosArm64Target(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
}

pub fn iosDeviceTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_m1 },
    });
}

pub fn iosSimulatorTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .simulator,
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_m1 },
    });
}
