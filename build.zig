const std = @import("std");
const buildpkg = @import("src/build/main.zig");

pub fn build(b: *std.Build) !void {
    const config = buildpkg.Config.init(b);
    const deps = try buildpkg.SharedDeps.init(b, &config);

    // Steps
    const run_cli_step = b.step("run-cli", "Run CLI");
    const run_step = b.step("run", "Build and run macOS app");
    const xcframework_step = b.step("xcframework", "Build XCFramework for macOS");
    const xcframework_ios_step = b.step("xcframework-ios", "Build XCFramework for iOS");
    const macos_step = b.step("macos", "Build macOS app via Xcode");
    const ios_step = b.step("ios", "Build iOS app via Xcode");
    const test_step = b.step("test", "Run unit tests");

    // Library
    const lib = try buildpkg.BobrWhisperLib.init(b, &deps);
    if (lib.lib) |l| b.installArtifact(l);
    b.installFile("include/bobrwhisper.h", "include/bobrwhisper.h");
    b.installFile("include/module.modulemap", "include/module.modulemap");

    // CLI
    const cli = try buildpkg.BobrWhisperCLI.init(b, &deps);
    cli.install(b);
    run_cli_step.dependOn(&cli.addRunStep(b).step);

    // XCFrameworks
    const macos_xcframework = try buildpkg.BobrWhisperXCFramework.init(b, &config, .macos);
    xcframework_step.dependOn(macos_xcframework.step);

    const ios_xcframework = try buildpkg.BobrWhisperXCFramework.init(b, &config, .ios);
    xcframework_ios_step.dependOn(ios_xcframework.step);

    // Xcode builds
    const macos_app = buildpkg.BobrWhisperXcodebuild.init(b, &config, &macos_xcframework, .macos);
    macos_step.dependOn(macos_app.step);
    run_step.dependOn(&buildpkg.BobrWhisperXcodebuild.addRunStep(b, &macos_app).step);

    const ios_app = buildpkg.BobrWhisperXcodebuild.init(b, &config, &ios_xcframework, .ios);
    ios_step.dependOn(ios_app.step);

    // Tests
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = config.target,
            .optimize = config.optimize,
        }),
    });
    try deps.link(b, lib_tests);
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}
