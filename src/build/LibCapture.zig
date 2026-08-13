const std = @import("std");
const AppleSdk = @import("AppleSdk.zig");

pub const LibCapture = @This();

pub const lib_name = "bobrwhisper-capture";

shared: *std.Build.Step.Compile,
static: *std.Build.Step.Compile,
pkg_config: std.Build.LazyPath,

/// Unlike the audio library this one does link a platform audio API, so it is
/// not dependency free — but the backend for a host without one reports a runtime
/// error rather than failing the build, so every target still produces artifacts.
pub fn init(
    b: *std.Build,
    capture_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !LibCapture {
    const shared = try createLibrary(b, capture_module, target, optimize, lib_name, .dynamic);
    if (target.result.ofmt == .elf) {
        shared.setVersionScript(b.path("src/build/libcapture.map"));
    }

    const static = try createLibrary(b, capture_module, target, optimize, lib_name ++ "-static", .static);
    static.bundle_compiler_rt = true;
    static.root_module.pic = true;

    return .{
        .shared = shared,
        .static = static,
        .pkg_config = pkgConfig(b, target.result.os.tag),
    };
}

fn createLibrary(
    b: *std.Build,
    capture_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    linkage: std.builtin.LinkMode,
) !*std.Build.Step.Compile {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/lib_capture.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("capture", capture_module);

    const lib = b.addLibrary(.{
        .name = name,
        .root_module = root_module,
        .linkage = linkage,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });

    if (target.result.os.tag.isDarwin()) {
        try AppleSdk.addPaths(b, lib);
        lib.root_module.linkFramework("AudioToolbox", .{});
        lib.root_module.linkFramework("CoreFoundation", .{});
    }
    return lib;
}

fn pkgConfig(b: *std.Build, os_tag: std.Target.Os.Tag) std.Build.LazyPath {
    const private_libs = if (os_tag.isDarwin())
        "-framework AudioToolbox -framework CoreFoundation"
    else if (os_tag == .linux)
        "-lasound"
    else
        "";
    return b.addWriteFiles().add(lib_name ++ ".pc", b.fmt(
        \\prefix={s}
        \\includedir=${{prefix}}/include
        \\libdir=${{prefix}}/lib
        \\
        \\Name: {s}
        \\URL: https://github.com/polymath-as/bobrwhisper
        \\Description: Microphone capture for local speech recognition
        \\Version: 0.1.0
        \\Requires: bobrwhisper-audio
        \\Cflags: -I${{includedir}}
        \\Libs: -L${{libdir}} -l{s}
        \\Libs.private: {s}
        \\
    , .{ b.install_prefix, lib_name, lib_name, private_libs }));
}

pub fn install(self: *const LibCapture, b: *std.Build, step: *std.Build.Step) void {
    step.dependOn(&b.addInstallArtifact(self.shared, .{}).step);
    step.dependOn(&b.addInstallLibFile(
        self.static.getEmittedBin(),
        "lib" ++ lib_name ++ ".a",
    ).step);
    step.dependOn(&b.addInstallHeaderFile(
        b.path("include/bobrwhisper/capture.h"),
        "bobrwhisper/capture.h",
    ).step);
    step.dependOn(&b.addInstallFileWithDir(
        self.pkg_config,
        .prefix,
        "share/pkgconfig/" ++ lib_name ++ ".pc",
    ).step);
}

pub fn addCExample(
    self: *const LibCapture,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    source: []const u8,
    name: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFiles(.{ .files = &.{source} });
    exe.root_module.addIncludePath(b.path("include"));
    exe.root_module.linkLibrary(self.static);
    return exe;
}
