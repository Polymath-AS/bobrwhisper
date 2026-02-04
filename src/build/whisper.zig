const std = @import("std");
const AppleSdk = @import("AppleSdk.zig");
const llama_build = @import("llama.zig");

pub const WhisperLib = struct {
    lib: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,
};

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    llama: llama_build.LlamaLib,
) !WhisperLib {
    const whisper_dep = b.dependency("whisper", .{});
    const is_ios_simulator = target.result.os.tag == .ios and target.result.abi == .simulator;
    const has_metal = target.result.os.tag.isDarwin() and !is_ios_simulator;

    const whisper_lib = b.addLibrary(.{
        .name = "whisper",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });

    whisper_lib.addIncludePath(whisper_dep.path("include"));
    whisper_lib.addIncludePath(whisper_dep.path("src"));
    whisper_lib.addIncludePath(llama.ggml_include_path);

    var flags = std.ArrayListUnmanaged([]const u8){};
    defer flags.deinit(b.graph.arena);
    try flags.append(b.graph.arena, "-std=c++17");
    if (target.result.os.tag.isDarwin()) {
        try flags.append(b.graph.arena, "-D_DARWIN_C_SOURCE");
    }
    if (has_metal) {
        try flags.appendSlice(b.graph.arena, &.{
            "-DGGML_USE_METAL",
            "-DGGML_USE_BLAS",
            "-DGGML_USE_CPU",
            "-DGGML_USE_ACCELERATE",
        });
    } else if (target.result.os.tag.isDarwin()) {
        try flags.appendSlice(b.graph.arena, &.{
            "-D_DARWIN_C_SOURCE",
            "-DGGML_USE_BLAS",
            "-DGGML_USE_CPU",
            "-DGGML_USE_ACCELERATE",
        });
    } else {
        try flags.append(b.graph.arena, "-DGGML_USE_CPU");
    }
    try flags.append(b.graph.arena, "-DWHISPER_VERSION=\"1.0.0\"");

    whisper_lib.addCSourceFiles(.{
        .root = whisper_dep.path("src"),
        .files = &.{"whisper.cpp"},
        .flags = flags.items,
    });

    whisper_lib.linkLibrary(llama.lib);

    if (target.result.os.tag.isDarwin()) {
        try AppleSdk.addPaths(b, whisper_lib);
    }

    return .{
        .lib = whisper_lib,
        .include_path = whisper_dep.path("include"),
    };
}

pub fn link(compile: *std.Build.Step.Compile, whisper: WhisperLib) void {
    compile.linkLibrary(whisper.lib);
    compile.addIncludePath(whisper.include_path);
}
