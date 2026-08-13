const std = @import("std");

pub const LibAudio = @This();

/// Installed file name. Prefixed for the same reason libbobrwhisper is: a bare
/// `libaudio` would be asking for a collision.
pub const lib_name = "bobrwhisper-audio";

shared: *std.Build.Step.Compile,
static: *std.Build.Step.Compile,
pkg_config: std.Build.LazyPath,

/// No whisper, no ggml, no platform frameworks — this library links nothing but
/// libc, so it needs none of the SharedDeps plumbing the ASR library does. That
/// is the whole point of it being separate.
pub fn init(
    b: *std.Build,
    audio_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) LibAudio {
    const shared = createLibrary(b, audio_module, target, optimize, lib_name, .dynamic);
    if (target.result.ofmt == .elf) {
        shared.setVersionScript(b.path("src/build/libaudio.map"));
    }

    const static = createLibrary(b, audio_module, target, optimize, lib_name ++ "-static", .static);
    static.bundle_compiler_rt = true;
    static.root_module.pic = true;

    return .{
        .shared = shared,
        .static = static,
        .pkg_config = pkgConfig(b),
    };
}

fn createLibrary(
    b: *std.Build,
    audio_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    linkage: std.builtin.LinkMode,
) *std.Build.Step.Compile {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/lib_audio.zig"),
        .target = target,
        .optimize = optimize,
        // c_allocator backs the buffers handed to C.
        .link_libc = true,
    });
    root_module.addImport("audio", audio_module);

    return b.addLibrary(.{
        .name = name,
        .root_module = root_module,
        .linkage = linkage,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
}

fn pkgConfig(b: *std.Build) std.Build.LazyPath {
    return b.addWriteFiles().add(lib_name ++ ".pc", b.fmt(
        \\prefix={s}
        \\includedir=${{prefix}}/include
        \\libdir=${{prefix}}/lib
        \\
        \\Name: {s}
        \\URL: https://github.com/polymath-as/bobrwhisper
        \\Description: Audio processing for local speech recognition
        \\Version: 0.1.0
        \\Cflags: -I${{includedir}}
        \\Libs: -L${{libdir}} -l{s}
        \\
    , .{ b.install_prefix, lib_name, lib_name }));
}

pub fn install(self: *const LibAudio, b: *std.Build, step: *std.Build.Step) void {
    step.dependOn(&b.addInstallArtifact(self.shared, .{}).step);
    // Installed under the plain name rather than the Compile step's, which
    // carries a `-static` suffix only to keep the two artifacts distinct in the
    // build graph. A consumer links -lbobrwhisper-audio either way.
    step.dependOn(&b.addInstallLibFile(
        self.static.getEmittedBin(),
        "lib" ++ lib_name ++ ".a",
    ).step);
    step.dependOn(&b.addInstallHeaderFile(
        b.path("include/bobrwhisper/audio.h"),
        "bobrwhisper/audio.h",
    ).step);
    step.dependOn(&b.addInstallFileWithDir(
        self.pkg_config,
        .prefix,
        "share/pkgconfig/" ++ lib_name ++ ".pc",
    ).step);
}

/// Build a C program against the static library, to check the header actually
/// compiles as C and the ABI matches.
pub fn addCExample(
    self: *const LibAudio,
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
