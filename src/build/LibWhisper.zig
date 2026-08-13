const std = @import("std");
const AsrBuild = @import("AsrBuild.zig");
const CombineArchivesStep = @import("CombineArchivesStep.zig");
const SharedDeps = @import("SharedDeps.zig");

pub const LibWhisper = @This();

/// Installed file name. Deliberately *not* `whisper`: whisper.cpp installs its
/// own `libwhisper.so` with SONAME `libwhisper.so.0` and a completely different
/// ABI, so sharing the name would make the two unco-installable. The C API keeps
/// the `libwhisper_` symbol prefix, which does not collide with whisper.cpp's
/// `whisper_`.
pub const lib_name = "bobrwhisper";

shared: *std.Build.Step.Compile,
static: *std.Build.Step.Compile,
static_output: std.Build.LazyPath,
pkg_config: std.Build.LazyPath,

pub fn init(b: *std.Build, deps: *const SharedDeps) !LibWhisper {
    // One asr module feeds both linkages, so the whisper bridge and the ASR
    // package are compiled once rather than once per library.
    const asr_module = AsrBuild.createModule(b, deps, deps.target, deps.optimize);

    const shared = try createLibrary(b, deps, asr_module, lib_name, .dynamic);
    if (deps.target.result.ofmt == .elf) {
        shared.setVersionScript(b.path("src/build/libwhisper.map"));
    }
    const static = try createLibrary(b, deps, asr_module, lib_name ++ "-static", .static);
    static.bundle_compiler_rt = true;
    static.root_module.pic = true;

    // The LazyPaths carry the dependency on each producing step.
    const combined = CombineArchivesStep.create(b, .{
        .name = lib_name,
        .ofmt = deps.target.result.ofmt,
        .sources = &.{
            static.getEmittedBin(),
            deps.whisper.lib.getEmittedBin(),
            deps.ggml.lib.getEmittedBin(),
        },
    });

    return .{
        .shared = shared,
        .static = static,
        .static_output = combined.output,
        .pkg_config = pkgConfig(b, deps.target.result.os.tag),
    };
}

fn createLibrary(
    b: *std.Build,
    deps: *const SharedDeps,
    asr_module: *std.Build.Module,
    name: []const u8,
    linkage: std.builtin.LinkMode,
) !*std.Build.Step.Compile {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/libwhisper.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
    });
    root_module.addImport("asr", asr_module);

    const lib = b.addLibrary(.{
        .name = name,
        .root_module = root_module,
        .linkage = linkage,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    AsrBuild.addWhisperBridge(b, lib, deps, deps.optimize);
    try deps.linkWhisper(b, lib);
    return lib;
}

/// Build an executable that links the installed static library, used to exercise
/// the C ABI from an actual C translation unit.
pub fn addCExample(
    self: *const LibWhisper,
    b: *std.Build,
    deps: *const SharedDeps,
    source: []const u8,
    name: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = deps.target,
            .optimize = deps.optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFiles(.{ .files = &.{source} });
    exe.root_module.addIncludePath(b.path("include"));
    self.linkInstalledArchive(exe, deps);
    return exe;
}

/// Same, for a Zig program. `libwhisper.h` is run through translate-c and
/// imported as `libwhisper`, so the consumer still crosses the C ABI and the
/// header still has to be valid C — a C example cannot check that the header
/// survives translate-c, and this cannot check C compiler compatibility, so the
/// two examples cover different things.
pub fn addZigExample(
    self: *const LibWhisper,
    b: *std.Build,
    deps: *const SharedDeps,
    source: []const u8,
    name: []const u8,
) *std.Build.Step.Compile {
    const header = b.addTranslateC(.{
        .root_source_file = b.path("include/libwhisper.h"),
        .target = deps.target,
        .optimize = deps.optimize,
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = deps.target,
            .optimize = deps.optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("libwhisper", header.createModule());
    self.linkInstalledArchive(exe, deps);
    return exe;
}

/// Link the combined archive rather than the Compile step, so an example
/// exercises exactly the file consumers are given.
fn linkInstalledArchive(
    self: *const LibWhisper,
    exe: *std.Build.Step.Compile,
    deps: *const SharedDeps,
) void {
    // The step dependency has to be explicit: an object file added to a module
    // does not order the exe after the Run step that produces it, so a cold
    // cache would link a missing file.
    exe.root_module.addObjectFile(self.static_output);
    self.static_output.addStepDependencies(&exe.step);
    exe.root_module.linkSystemLibrary("c++", .{});
    if (deps.target.result.os.tag.isDarwin()) {
        exe.root_module.linkFramework("Foundation", .{});
        exe.root_module.linkFramework("CoreFoundation", .{});
        exe.root_module.linkFramework("Accelerate", .{});
        exe.root_module.linkFramework("Metal", .{});
        exe.root_module.linkFramework("MetalKit", .{});
    }
}

fn pkgConfig(b: *std.Build, os_tag: std.Target.Os.Tag) std.Build.LazyPath {
    const private_libs = if (os_tag.isDarwin())
        "-lc++ -framework Foundation -framework CoreFoundation -framework Accelerate -framework Metal -framework MetalKit"
    else
        "-lc++ -lm -lpthread";
    return b.addWriteFiles().add(lib_name ++ ".pc", b.fmt(
        \\prefix={s}
        \\includedir=${{prefix}}/include
        \\libdir=${{prefix}}/lib
        \\
        \\Name: libwhisper
        \\URL: https://github.com/polymath-as/bobrwhisper
        \\Description: UI-independent local Whisper transcription library
        \\Version: 0.1.0
        \\Cflags: -I${{includedir}}
        \\Libs: -L${{libdir}} -l{s}
        \\Libs.private: {s}
        \\
    , .{ b.install_prefix, lib_name, private_libs }));
}

pub fn install(self: *const LibWhisper, b: *std.Build, step: *std.Build.Step) void {
    step.dependOn(&b.addInstallArtifact(self.shared, .{}).step);
    step.dependOn(&b.addInstallLibFile(self.static_output, "lib" ++ lib_name ++ ".a").step);
    step.dependOn(&b.addInstallHeaderFile(b.path("include/libwhisper.h"), "libwhisper.h").step);
    step.dependOn(&b.addInstallFileWithDir(
        self.pkg_config,
        .prefix,
        "share/pkgconfig/" ++ lib_name ++ ".pc",
    ).step);
}
