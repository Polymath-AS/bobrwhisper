const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");

pub fn createModule(
    b: *std.Build,
    deps: *const SharedDeps,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const asr_module = b.createModule(.{
        .root_source_file = b.path("pkg/asr/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    asr_module.addIncludePath(b.path("pkg/asr"));
    asr_module.addIncludePath(deps.whisper.include_path);
    asr_module.addIncludePath(deps.llama.ggml_include_path);
    return asr_module;
}

pub fn addWhisperBridge(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    deps: *const SharedDeps,
    optimize: std.builtin.OptimizeMode,
) void {
    compile.root_module.addCSourceFiles(.{
        .root = b.path("pkg/asr"),
        .files = &.{"whisper_bridge.c"},
        .flags = bridgeFlags(optimize),
    });
    compile.root_module.addIncludePath(deps.whisper.include_path);
    compile.root_module.addIncludePath(deps.llama.ggml_include_path);
}

fn bridgeFlags(optimize: std.builtin.OptimizeMode) []const []const u8 {
    return if (optimize == .Debug)
        &.{ "-O2", "-fno-sanitize=undefined" }
    else
        &.{};
}
