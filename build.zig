const std = @import("std");
const builtin = @import("builtin");
const buildpkg = @import("src/build/main.zig");

pub fn build(b: *std.Build) !void {
    const config = buildpkg.Config.init(b);
    const deps = try buildpkg.SharedDeps.init(b, &config);
    const asr_module = buildpkg.AsrBuild.createModule(b, &deps, config.target, config.optimize);

    // Steps
    const run_cli_step = b.step("run-cli", "Run CLI");
    const run_step = b.step("run", "Build and run macOS app");
    const xcframework_step = b.step("xcframework", "Build XCFramework for macOS");
    const xcframework_ios_step = b.step("xcframework-ios", "Build XCFramework for iOS");
    const macos_step = b.step("macos", "Build macOS app via Xcode");
    const ios_step = b.step("ios", "Build iOS app via Xcode");
    const test_step = b.step("test", "Run unit tests");
    const test_libwhisper_step = b.step("test-libwhisper", "Run standalone libwhisper tests");
    const libwhisper_step = b.step("libwhisper", "Build and install the standalone libwhisper C library");

    // Public Zig module for dependency consumers. It carries the whisper bridge
    // and its link dependencies, so importing it is sufficient — a bare module
    // would leave every consumer with undefined `bobrwhisper_whisper_*` symbols.
    const public_module = b.addModule("bobrwhisper", .{
        .root_source_file = b.path("pkg/asr/main.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .link_libc = true,
    });
    public_module.addIncludePath(b.path("pkg/asr"));
    buildpkg.AsrBuild.addWhisperBridgeToModule(b, public_module, &deps, config.optimize);
    deps.linkWhisperModule(public_module);

    // Standalone transcription library. Its install step is intentionally
    // separate from the app/XCFramework path and has no Swift requirements.
    const libwhisper = try buildpkg.LibWhisper.init(b, &deps);
    libwhisper.install(b, libwhisper_step);

    // Library
    const lib = try buildpkg.BobrWhisperLib.init(b, &deps);
    if (lib.lib) |l| b.installArtifact(l);
    b.installFile("include/bobrwhisper.h", "include/bobrwhisper.h");
    b.installFile("include/module.modulemap", "include/module.modulemap");

    // CLI
    const cli = try buildpkg.BobrWhisperCLI.init(b, &deps);
    cli.install(b);
    run_cli_step.dependOn(&cli.addRunStep(b).step);

    // Apple application artifacts are not even initialized on other hosts.
    // This keeps the standalone library build free of Xcode/Swift SDK probes.
    if (builtin.os.tag == .macos) {
        const macos_xcframework = try buildpkg.BobrWhisperXCFramework.init(b, &config, .macos);
        xcframework_step.dependOn(macos_xcframework.step);

        const ios_xcframework = try buildpkg.BobrWhisperXCFramework.init(b, &config, .ios);
        xcframework_ios_step.dependOn(ios_xcframework.step);

        const macos_app = buildpkg.BobrWhisperXcodebuild.init(b, &config, &macos_xcframework, .macos);
        macos_step.dependOn(macos_app.step);
        run_step.dependOn(&buildpkg.BobrWhisperXcodebuild.addRunStep(b, &macos_app).step);

        const ios_app = buildpkg.BobrWhisperXcodebuild.init(b, &config, &ios_xcframework, .ios);
        ios_step.dependOn(ios_app.step);
    } else {
        // Fail loudly instead of reporting success for a step that built
        // nothing. These need Xcode and a Swift toolchain; libwhisper does not,
        // which is why it is reachable on every host.
        const unavailable = b.addFail(
            "Apple app and XCFramework targets require a macOS host with Xcode. " ++
                "Use `zig build libwhisper` for the host-independent C library.",
        );
        for ([_]*std.Build.Step{
            xcframework_step,
            xcframework_ios_step,
            macos_step,
            ios_step,
            run_step,
        }) |step| step.dependOn(&unavailable.step);
    }

    // Tests
    const test_root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    test_root_module.addImport("asr", asr_module);
    const lib_tests = b.addTest(.{
        .root_module = test_root_module,
    });
    buildpkg.AsrBuild.addWhisperBridge(b, lib_tests, &deps, config.optimize);
    try deps.link(b, lib_tests);
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const libwhisper_test_module = b.createModule(.{
        .root_source_file = b.path("src/libwhisper.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    libwhisper_test_module.addImport("asr", asr_module);
    const libwhisper_tests = b.addTest(.{ .root_module = libwhisper_test_module });
    buildpkg.AsrBuild.addWhisperBridge(b, libwhisper_tests, &deps, config.optimize);
    try deps.linkWhisper(b, libwhisper_tests);
    const run_libwhisper_tests = b.addRunArtifact(libwhisper_tests);
    test_libwhisper_step.dependOn(&run_libwhisper_tests.step);
    test_step.dependOn(&run_libwhisper_tests.step);

    // Smoke-test the C ABI from a real C translation unit against the installed
    // static archive. The Zig tests cannot catch header/ABI drift on their own.
    const c_smoke = libwhisper.addCExample(
        b,
        &deps,
        "examples/c-smoke/main.c",
        "libwhisper-c-smoke",
    );
    const run_c_smoke = b.addRunArtifact(c_smoke);
    run_c_smoke.expectExitCode(0);
    test_libwhisper_step.dependOn(&run_c_smoke.step);
    test_step.dependOn(&run_c_smoke.step);
}
