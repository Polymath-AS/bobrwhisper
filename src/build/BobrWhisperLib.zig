const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");
const LibtoolStep = @import("LibtoolStep.zig");

pub const BobrWhisperLib = @This();

step: *std.Build.Step,
output: std.Build.LazyPath,
lib: ?*std.Build.Step.Compile = null,

pub fn init(b: *std.Build, deps: *const SharedDeps) !BobrWhisperLib {
    // Force ReleaseFast for library - ggml uses pointer arithmetic patterns that
    // trigger Zig's runtime safety checks (null pointer offset) in Debug mode
    const lib_optimize: std.builtin.OptimizeMode = if (deps.optimize == .Debug) .ReleaseFast else deps.optimize;

    const lib = b.addLibrary(.{
        .name = "bobrwhisper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = deps.target,
            .optimize = lib_optimize,
        }),
        .linkage = .static,
    });

    try deps.link(b, lib);

    return .{
        .step = &lib.step,
        .output = lib.getEmittedBin(),
        .lib = lib,
    };
}

pub fn initStatic(b: *std.Build, deps: *const SharedDeps) !BobrWhisperLib {
    // Force ReleaseFast for library - ggml uses pointer arithmetic patterns that
    // trigger Zig's runtime safety checks (null pointer offset) in Debug mode
    const lib_optimize: std.builtin.OptimizeMode = if (deps.optimize == .Debug) .ReleaseFast else deps.optimize;

    const lib = b.addLibrary(.{
        .name = "bobrwhisper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = deps.target,
            .optimize = lib_optimize,
        }),
        .linkage = .static,
    });

    try deps.link(b, lib);
    lib.bundle_compiler_rt = true;

    const libtool = LibtoolStep.create(b, .{
        .name = "bobrwhisper",
        .sources = &.{
            lib.getEmittedBin(),
            deps.whisper.lib.getEmittedBin(),
            deps.llama.lib.getEmittedBin(),
            deps.llama.ggml.getEmittedBin(),
        },
    });
    libtool.step.dependOn(&lib.step);

    return .{
        .step = libtool.step,
        .output = libtool.output,
    };
}

pub fn install(self: *const BobrWhisperLib, b: *std.Build) void {
    b.getInstallStep().dependOn(self.step);
}
