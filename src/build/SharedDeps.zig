const std = @import("std");
const AppleSdk = @import("AppleSdk.zig");
const Config = @import("Config.zig");
const llama_build = @import("llama.zig");
const whisper_build = @import("whisper.zig");

pub const SharedDeps = @This();

pub const MetalResources = struct {
    shader: std.Build.LazyPath,
    common_header: std.Build.LazyPath,
    impl_header: std.Build.LazyPath,
};

config: *const Config,
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
llama: llama_build.LlamaLib,
whisper: whisper_build.WhisperLib,
metal_resources: ?MetalResources,

pub fn init(b: *std.Build, config: *const Config) !SharedDeps {
    return initForTarget(b, config, config.target, config.optimize);
}

pub fn initForTarget(
    b: *std.Build,
    config: *const Config,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !SharedDeps {
    // Force ReleaseFast for ggml/whisper/llama - they use pointer arithmetic patterns
    // that trigger Zig's runtime safety checks (null pointer offset) in Debug mode
    const lib_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;

    const llama = try llama_build.build(b, target, lib_optimize);
    const whisper = try whisper_build.build(b, target, lib_optimize, llama);

    const is_darwin = target.result.os.tag == .macos or target.result.os.tag == .ios;
    const metal_resources: ?MetalResources = if (is_darwin) blk: {
        const llama_dep = b.dependency("llama", .{});
        break :blk .{
            .shader = llama_dep.path("ggml/src/ggml-metal/ggml-metal.metal"),
            .common_header = llama_dep.path("ggml/src/ggml-common.h"),
            .impl_header = llama_dep.path("ggml/src/ggml-metal/ggml-metal-impl.h"),
        };
    } else null;

    return .{
        .config = config,
        .target = target,
        .optimize = optimize,
        .llama = llama,
        .whisper = whisper,
        .metal_resources = metal_resources,
    };
}

pub fn retarget(self: *const SharedDeps, b: *std.Build, target: std.Build.ResolvedTarget) !SharedDeps {
    return initForTarget(b, self.config, target, self.optimize);
}

pub fn retargetWithOptimize(
    self: *const SharedDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !SharedDeps {
    return initForTarget(b, self.config, target, optimize);
}

pub fn link(self: *const SharedDeps, b: *std.Build, compile: *std.Build.Step.Compile) !void {
    whisper_build.link(compile, self.whisper);
    llama_build.link(compile, self.llama);
    try linkAppleFrameworks(b, compile, self.target);
    compile.linkLibC();
    compile.linkLibCpp();
}

fn linkAppleFrameworks(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) !void {
    const os_tag = target.result.os.tag;
    if (os_tag == .macos or os_tag == .ios) {
        try AppleSdk.addPaths(b, compile);

        compile.linkFramework("Foundation");
        compile.linkFramework("Accelerate");
        compile.linkFramework("Metal");
        compile.linkFramework("MetalKit");
    }
    if (os_tag == .macos) {
        compile.linkFramework("CoreAudio");
        compile.linkFramework("AudioToolbox");
    }
}
