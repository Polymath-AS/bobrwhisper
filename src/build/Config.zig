const std = @import("std");

pub const Config = @This();

target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
xcode_sign: bool,
apple_team_id: ?[]const u8,
code_sign_identity: ?[]const u8,

pub fn init(b: *std.Build) Config {
    const xcode_sign = b.option(bool, "xcode-sign", "Enable code signing in xcodebuild steps") orelse false;

    return .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .xcode_sign = xcode_sign,
        .apple_team_id = b.option([]const u8, "apple-team-id", "Apple Developer Team ID used for signed builds"),
        .code_sign_identity = b.option([]const u8, "code-sign-identity", "Code signing identity override (for example: Developer ID Application: Name (TEAMID))"),
    };
}

pub fn xcframeworkOptimize(self: *const Config) std.builtin.OptimizeMode {
    return self.optimize;
}

pub fn xcodebuildConfiguration(self: *const Config) []const u8 {
    return if (self.optimize == .Debug) "Debug" else "Release";
}

pub fn requireAppleTeamId(self: *const Config) []const u8 {
    if (self.apple_team_id) |team_id| return team_id;
    @panic("Code signing is enabled but no Team ID was provided. Pass -Dapple-team-id=<TEAMID>.");
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
