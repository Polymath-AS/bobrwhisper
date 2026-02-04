const std = @import("std");

/// Adds Apple SDK paths to a compile step for cross-compilation.
/// Uses xcrun to detect the correct SDK for the target OS.
/// Based on Ghostty's pkg/apple-sdk pattern.
pub fn addPaths(b: *std.Build, step: *std.Build.Step.Compile) !void {
    const target = step.rootModuleTarget();
    if (!target.os.tag.isDarwin()) return;

    const libc = std.zig.LibCInstallation.findNative(.{
        .allocator = b.graph.arena,
        .target = &target,
        .verbose = false,
    }) catch |err| switch (err) {
        error.DarwinSdkNotFound => return,
        else => return err,
    };

    if (libc.include_dir) |dir| {
        step.root_module.addSystemIncludePath(.{ .cwd_relative = dir });
    }
    if (libc.sys_include_dir) |dir| {
        step.root_module.addSystemIncludePath(.{ .cwd_relative = dir });
    }

    // Add framework path (needed for Metal, Foundation, etc.)
    const sdk_path = getSdkPath(target) orelse return;
    step.root_module.addSystemFrameworkPath(.{
        .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk_path}),
    });
    step.root_module.addSystemIncludePath(.{
        .cwd_relative = b.fmt("{s}/usr/include", .{sdk_path}),
    });
    step.root_module.addLibraryPath(.{
        .cwd_relative = b.fmt("{s}/usr/lib", .{sdk_path}),
    });
}

fn getSdkPath(target: std.Target) ?[]const u8 {
    const base = "/Applications/Xcode.app/Contents/Developer/Platforms";
    return switch (target.os.tag) {
        .macos => base ++ "/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
        .ios => if (target.abi == .simulator)
            base ++ "/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        else
            base ++ "/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk",
        else => null,
    };
}
