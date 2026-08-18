const std = @import("std");

/// Adds Apple SDK paths to a compile step for cross-compilation.
/// Uses Zig's native libc discovery to detect the selected Apple SDK.
/// Based on Ghostty's pkg/apple-sdk pattern.
pub fn addPaths(b: *std.Build, step: *std.Build.Step.Compile) !void {
    const target = step.rootModuleTarget();
    if (!target.os.tag.isDarwin()) return;

    var libc = std.zig.LibCInstallation.findNative(b.graph.arena, b.graph.io, .{
        .target = &target,
        .environ_map = &b.graph.environ_map,
        .verbose = false,
    }) catch |err| switch (err) {
        error.DarwinSdkNotFound => return,
        else => return err,
    };

    // Xcode 27's math.h asks Clang's float.h for infinity and NaN through the
    // __need_infinity_nan protocol. Zig 0.16's bundled Clang resource headers
    // predate that protocol, so compiling Zig's bundled libc++ against the new
    // SDK otherwise fails with an undeclared INFINITY. Ghostty works around the
    // same toolchain mismatch by putting a forwarding compatibility header
    // between Zig's resource headers and the selected SDK.
    libc.include_dir = b.path("src/build/apple-sdk-include").getPath(b);

    // Supplying individual include paths is not enough: Zig also builds parts
    // of its bundled libc++ in a child compilation. Render the discovered SDK
    // as a libc configuration and attach it to the whole compile step so those
    // child compilations inherit the same Apple sysroot.
    var rendered: std.Io.Writer.Allocating = .init(b.graph.arena);
    defer rendered.deinit();
    try libc.render(&rendered.writer);
    const generated = b.addWriteFiles();
    step.setLibCFile(generated.add("apple-libc.txt", rendered.written()));

    // Zig 0.16's libc++ configuration expects this setting as a compiler
    // define. It makes newer libc++ headers use inline compatibility paths for
    // symbols unavailable in the deployment target's system libc++.
    step.root_module.addCMacro(
        "_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS",
        "1",
    );

    // Use the SDK selected by Zig/Xcode rather than assuming that Xcode is
    // installed at /Applications/Xcode.app. This also respects DEVELOPER_DIR
    // and xcode-select (for example, when Xcode-beta is active).
    const sdk_path = getSdkPath(libc) orelse return;
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
