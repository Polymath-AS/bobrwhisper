const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");

pub const BobrWhisperCLI = @This();

step: *std.Build.Step,
exe: *std.Build.Step.Compile,
metal_resources: ?SharedDeps.MetalResources,

pub fn init(b: *std.Build, deps: *const SharedDeps) !BobrWhisperCLI {
    // Force ReleaseFast for CLI - ggml uses pointer arithmetic patterns that
    // trigger Zig's runtime safety checks (null pointer offset) in Debug mode
    const cli_optimize: std.builtin.OptimizeMode = if (deps.optimize == .Debug) .ReleaseFast else deps.optimize;
    const cli_deps = try deps.retargetWithOptimize(b, deps.target, cli_optimize);

    const exe = b.addExecutable(.{
        .name = "bobrwhisper-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = deps.target,
            .optimize = cli_optimize,
        }),
    });

    try cli_deps.link(b, exe);

    return .{
        .step = &exe.step,
        .exe = exe,
        .metal_resources = cli_deps.metal_resources,
    };
}

pub fn install(self: *const BobrWhisperCLI, b: *std.Build) void {
    b.installArtifact(self.exe);
    if (self.metal_resources) |res| {
        // Merge metal shader with inlined headers
        const merge_cmd = b.addSystemCommand(&.{"scripts/merge-metal.sh"});
        merge_cmd.addFileArg(res.shader);
        merge_cmd.addFileArg(res.common_header);
        merge_cmd.addFileArg(res.impl_header);
        const merged_metal = merge_cmd.addOutputFileArg("ggml-metal.metal");

        const install_shader = b.addInstallFile(merged_metal, "share/ggml-metal.metal");
        b.getInstallStep().dependOn(&install_shader.step);
    }
}

pub fn addRunStep(self: *const BobrWhisperCLI, b: *std.Build) *std.Build.Step.Run {
    const run = b.addRunArtifact(self.exe);
    run.step.dependOn(b.getInstallStep());

    // Set Metal shader path for ggml
    if (self.metal_resources) |_| {
        run.setEnvironmentVariable("GGML_METAL_PATH_RESOURCES", b.getInstallPath(.prefix, "share"));
    }

    if (b.args) |args| {
        run.addArgs(args);
    }
    return run;
}
