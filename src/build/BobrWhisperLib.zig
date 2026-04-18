const std = @import("std");
const AsrBuild = @import("AsrBuild.zig");
const SharedDeps = @import("SharedDeps.zig");
const LibtoolStep = @import("LibtoolStep.zig");

pub const BobrWhisperLib = @This();

step: *std.Build.Step,
output: std.Build.LazyPath,
lib: ?*std.Build.Step.Compile = null,

pub fn init(b: *std.Build, deps: *const SharedDeps) !BobrWhisperLib {
    const asr_module = AsrBuild.createModule(b, deps, deps.target, deps.optimize);
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
    });
    root_module.addImport("asr", asr_module);

    const lib = b.addLibrary(.{
        .name = "bobrwhisper",
        .root_module = root_module,
        .linkage = .static,
    });
    AsrBuild.addWhisperBridge(b, lib, deps, deps.optimize);

    try deps.link(b, lib);

    return .{
        .step = &lib.step,
        .output = lib.getEmittedBin(),
        .lib = lib,
    };
}

pub fn initStatic(b: *std.Build, deps: *const SharedDeps) !BobrWhisperLib {
    const asr_module = AsrBuild.createModule(b, deps, deps.target, deps.optimize);
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
    });
    root_module.addImport("asr", asr_module);

    const lib = b.addLibrary(.{
        .name = "bobrwhisper",
        .root_module = root_module,
        .linkage = .static,
    });
    AsrBuild.addWhisperBridge(b, lib, deps, deps.optimize);

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
