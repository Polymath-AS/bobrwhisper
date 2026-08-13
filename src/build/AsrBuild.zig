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
    addWhisperBridgeToModule(b, compile.root_module, deps, optimize);
}

/// Module-level variant, needed for `b.addModule` exports: a public module has
/// no Compile step of its own, but must still carry the bridge or every
/// consumer hits undefined `bobrwhisper_whisper_*` symbols.
pub fn addWhisperBridgeToModule(
    b: *std.Build,
    module: *std.Build.Module,
    deps: *const SharedDeps,
    optimize: std.builtin.OptimizeMode,
) void {
    module.addCSourceFiles(.{
        .root = b.path("pkg/asr"),
        .files = &.{"whisper_bridge.c"},
        .flags = bridgeFlags(optimize),
    });
    module.addIncludePath(deps.whisper.include_path);
    module.addIncludePath(deps.llama.ggml_include_path);
}

fn bridgeFlags(optimize: std.builtin.OptimizeMode) []const []const u8 {
    return if (optimize == .Debug)
        &.{ "-O2", "-fno-sanitize=undefined", "-fvisibility=hidden" }
    else
        &.{"-fvisibility=hidden"};
}
