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
ggml: llama_build.GgmlLib,
llama: llama_build.LlamaLib,
whisper: whisper_build.WhisperLib,
metal_resources: ?MetalResources,

/// Null when whisper.cpp or llama.cpp has not been fetched yet; both are marked
/// lazy in build.zig.zon. Callers must return early rather than declare steps
/// against dependencies that are not on disk — the build runner fetches what
/// `lazyDependency` requested and re-runs this script.
pub fn init(b: *std.Build, config: *const Config) !?SharedDeps {
    return initForTarget(b, config, config.target, config.optimize);
}

pub fn initForTarget(
    b: *std.Build,
    config: *const Config,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !?SharedDeps {
    // Force ReleaseFast for the C/C++ deps in every mode that turns on Zig's
    // undefined-behaviour checks. ggml does pointer arithmetic those checks
    // reject — a ReleaseSafe build traps in ggml_graph_nbytes the moment a model
    // is loaded, and Debug additionally wants the sanitizer runtime linked. Zig
    // code keeps the requested mode, which is the part worth checking anyway.
    const c_optimize: std.builtin.OptimizeMode = switch (optimize) {
        .Debug, .ReleaseSafe => .ReleaseFast,
        .ReleaseFast, .ReleaseSmall => optimize,
    };

    const ggml = try llama_build.buildGgml(b, target, c_optimize) orelse return null;
    const llama = try llama_build.buildWithGgml(b, target, c_optimize, ggml) orelse return null;
    const whisper = try whisper_build.build(b, target, c_optimize, ggml) orelse return null;

    const is_darwin = target.result.os.tag == .macos or target.result.os.tag == .ios;
    const metal_resources: ?MetalResources = if (is_darwin) blk: {
        const llama_dep = b.lazyDependency("llama", .{}) orelse return null;
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
        .ggml = ggml,
        .llama = llama,
        .whisper = whisper,
        .metal_resources = metal_resources,
    };
}

pub fn retarget(self: *const SharedDeps, b: *std.Build, target: std.Build.ResolvedTarget) !?SharedDeps {
    return initForTarget(b, self.config, target, self.optimize);
}

pub fn retargetWithOptimize(
    self: *const SharedDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !?SharedDeps {
    return initForTarget(b, self.config, target, optimize);
}

pub fn link(self: *const SharedDeps, b: *std.Build, compile: *std.Build.Step.Compile) !void {
    whisper_build.link(compile, self.whisper);
    llama_build.link(compile, self.llama);
    try linkAppleFrameworks(b, compile, self.target);
    compile.root_module.linkSystemLibrary("sqlite3", .{});
    compile.root_module.linkSystemLibrary("c", .{});
    if (self.target.result.os.tag.isDarwin()) {
        try AppleSdk.linkCxxRuntime(b, compile);
    } else {
        compile.root_module.linkSystemLibrary("c++", .{});
    }
    if (self.target.result.os.tag == .linux) {
        compile.root_module.linkSystemLibrary("asound", .{});
    }
}

/// Link only the dependencies required by libwhisper. In particular, this
/// excludes app storage (sqlite) and macOS audio capture frameworks.
pub fn linkWhisper(self: *const SharedDeps, b: *std.Build, compile: *std.Build.Step.Compile) !void {
    if (self.target.result.os.tag.isDarwin()) try AppleSdk.addPaths(b, compile);
    self.linkWhisperModule(compile.root_module);
}

/// Module-level variant for `b.addModule` exports, which have no Compile step.
/// Apple SDK paths are omitted because `AppleSdk.addPaths` needs one; a Darwin
/// consumer of the public Zig module supplies them for its own artifact.
pub fn linkWhisperModule(self: *const SharedDeps, module: *std.Build.Module) void {
    module.linkLibrary(self.whisper.lib);
    module.addIncludePath(self.whisper.include_path);
    if (self.target.result.os.tag.isDarwin()) {
        module.linkFramework("Foundation", .{});
        module.linkFramework("CoreFoundation", .{});
        module.linkFramework("Accelerate", .{});
        module.linkFramework("Metal", .{});
        module.linkFramework("MetalKit", .{});
    }
    module.linkSystemLibrary("c", .{});
    module.linkSystemLibrary("c++", .{});
}

fn linkAppleFrameworks(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) !void {
    const os_tag = target.result.os.tag;
    if (os_tag == .macos or os_tag == .ios) {
        try AppleSdk.addPaths(b, compile);

        compile.root_module.linkFramework("Foundation", .{});
        compile.root_module.linkFramework("CoreFoundation", .{});
        compile.root_module.linkFramework("Accelerate", .{});
        compile.root_module.linkFramework("Metal", .{});
        compile.root_module.linkFramework("MetalKit", .{});
    }
    if (os_tag == .macos) {
        compile.root_module.linkFramework("CoreAudio", .{});
        compile.root_module.linkFramework("AudioToolbox", .{});
    }
}
