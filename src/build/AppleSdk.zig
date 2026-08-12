const std = @import("std");

/// Adds Apple SDK paths to a compile step for cross-compilation.
/// Uses Zig's native libc discovery to detect the selected Apple SDK.
/// Based on Ghostty's pkg/apple-sdk pattern.
pub fn addPaths(b: *std.Build, step: *std.Build.Step.Compile) !void {
    const target = step.rootModuleTarget();
    if (!target.os.tag.isDarwin()) return;

    const libc = std.zig.LibCInstallation.findNative(b.graph.arena, b.graph.io, .{
        .target = &target,
        .environ_map = &b.graph.environ_map,
        .verbose = false,
    }) catch |err| switch (err) {
        error.DarwinSdkNotFound => return,
        else => return err,
    };

    // Use the SDK selected by Zig/Xcode rather than assuming that Xcode is
    // installed at /Applications/Xcode.app. This also respects DEVELOPER_DIR
    // and xcode-select (for example, when Xcode-beta is active).
    const sdk_path = getSdkPath(libc) orelse return;
    if (libc.include_dir) |dir| {
        step.root_module.addSystemIncludePath(.{ .cwd_relative = dir });
    }
    if (libc.sys_include_dir) |dir| {
        step.root_module.addSystemIncludePath(.{ .cwd_relative = dir });
    }
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

/// Links the C++ runtime shipped by the selected Apple SDK. Asking Zig to
/// `linkSystemLibrary("c++")` instead builds Zig's bundled libc++, which can be
/// incompatible with newer Apple SDK headers.
pub fn linkCxxRuntime(b: *std.Build, step: *std.Build.Step.Compile) !void {
    const target = step.rootModuleTarget();
    if (!target.os.tag.isDarwin()) return;

    const libc = std.zig.LibCInstallation.findNative(b.graph.arena, b.graph.io, .{
        .target = &target,
        .environ_map = &b.graph.environ_map,
        .verbose = false,
    }) catch |err| switch (err) {
        error.DarwinSdkNotFound => return,
        else => return err,
    };
    const sdk_path = getSdkPath(libc) orelse return;
    step.root_module.addObjectFile(.{
        .cwd_relative = b.fmt("{s}/usr/lib/libc++.tbd", .{sdk_path}),
    });
}

fn getSdkPath(libc: std.zig.LibCInstallation) ?[]const u8 {
    const include_dir = libc.sys_include_dir orelse libc.include_dir orelse return null;
    const suffix = "/usr/include";
    if (!std.mem.endsWith(u8, include_dir, suffix)) return null;
    return include_dir[0 .. include_dir.len - suffix.len];
}
