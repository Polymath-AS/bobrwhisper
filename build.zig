const std = @import("std");
const builtin = @import("builtin");
const buildpkg = @import("src/build/main.zig");

pub fn build(b: *std.Build) !void {
    const config = buildpkg.Config.init(b);
    // whisper.cpp and llama.cpp are lazy dependencies. On a first run they are
    // not on disk yet: `lazyDependency` has queued the fetch and returned null,
    // and the build runner re-runs this script once it finishes. Declaring no
    // steps at all is the correct response, not an error.
    const deps = try buildpkg.SharedDeps.init(b, &config) orelse return;
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
    const test_audio_step = b.step("test-audio", "Run audio processing library tests (no model or device needed)");
    const test_capture_step = b.step("test-capture", "Run capture library tests (no device needed)");
    const bench_libwhisper_step = b.step("bench-libwhisper", "Benchmark the standalone libwhisper C API");
    const bench_simd_step = b.step("bench-simd", "Benchmark the vectorized audio helpers against their scalar originals");
    const bench_downmix_step = b.step("bench-downmix-poop", "Install the fixed-workload downmix benchmark for comparison with poop");
    const libwhisper_step = b.step("libwhisper", "Build and install the standalone libwhisper C library");
    const libaudio_step = b.step("libaudio", "Build and install the standalone audio processing C library");
    const libcapture_step = b.step("libcapture", "Build and install the standalone capture C library");

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
        // Neither can be null here: SharedDeps.init above already forced the
        // lazy fetch, so returning early cannot strand the steps declared below.
        const macos_xcframework = try buildpkg.BobrWhisperXCFramework.init(b, &config, .macos) orelse return;
        xcframework_step.dependOn(macos_xcframework.step);

        const ios_xcframework = try buildpkg.BobrWhisperXCFramework.init(b, &config, .ios) orelse return;
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

    // Audio processing library. It depends on nothing — no whisper, no ggml, no
    // platform audio API, no model fixture — which is why it has its own test
    // step: it is the one part of this project that can be worked on and
    // verified without an Apple toolchain or a microphone.
    const audio_module = b.addModule("bobrwhisper-audio", .{
        .root_source_file = b.path("src/audio/main.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    const audio_tests = b.addTest(.{ .root_module = audio_module });
    test_audio_step.dependOn(&b.addRunArtifact(audio_tests).step);
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);

    // Capture library. Depends on the audio library for format conversion and on
    // nothing else; the ASR library is not involved in either direction. Links
    // the platform audio API, so unlike the audio library it is not dependency
    // free — but the backend for an unsupported host reports a runtime error
    // rather than failing to build.
    const capture_module = b.addModule("bobrwhisper-capture", .{
        .root_source_file = b.path("src/capture/main.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "audio", .module = audio_module }},
    });
    if (config.target.result.os.tag == .linux) {
        capture_module.linkSystemLibrary("asound", .{});
    }
    const capture_tests = b.addTest(.{ .root_module = capture_module });
    test_capture_step.dependOn(&b.addRunArtifact(capture_tests).step);
    test_step.dependOn(&b.addRunArtifact(capture_tests).step);

    // And its C ABI.
    const libcapture = try buildpkg.LibCapture.init(b, capture_module, config.target, config.optimize);
    libcapture.install(b, libcapture_step);

    const libcapture_abi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib_capture.zig"),
            .target = config.target,
            .optimize = config.optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "capture", .module = capture_module }},
        }),
    });
    test_capture_step.dependOn(&b.addRunArtifact(libcapture_abi_tests).step);
    test_step.dependOn(&b.addRunArtifact(libcapture_abi_tests).step);

    const capture_smoke = libcapture.addCExample(
        b,
        config.target,
        config.optimize,
        "examples/capture-smoke/main.c",
        "bobrwhisper-capture-smoke",
    );
    const run_capture_smoke = b.addRunArtifact(capture_smoke);
    // .inherit rather than an exit-code check: the check variant also inspects
    // stderr, and the ALSA library logs there on a machine with no capture
    // device, which is not a failure of ours. .inherit still fails the step on a
    // non-zero exit, which is the signal that matters.
    run_capture_smoke.stdio = .inherit;
    test_capture_step.dependOn(&run_capture_smoke.step);
    test_step.dependOn(&run_capture_smoke.step);

    // Its C ABI, installed as libbobrwhisper-audio with a header under
    // include/bobrwhisper/, following ghostty's include/ghostty/vt.h layout.
    const libaudio = buildpkg.LibAudio.init(b, audio_module, config.target, config.optimize);
    libaudio.install(b, libaudio_step);

    const libaudio_c_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib_audio.zig"),
            .target = config.target,
            .optimize = config.optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "audio", .module = audio_module }},
        }),
    });
    test_audio_step.dependOn(&b.addRunArtifact(libaudio_c_tests).step);
    test_step.dependOn(&b.addRunArtifact(libaudio_c_tests).step);

    // And from actual C, which is the only thing that checks the header is valid
    // C and that the struct layouts agree.
    const audio_smoke = libaudio.addCExample(
        b,
        config.target,
        config.optimize,
        "examples/audio-smoke/main.c",
        "bobrwhisper-audio-smoke",
    );
    const run_audio_smoke = b.addRunArtifact(audio_smoke);
    run_audio_smoke.expectExitCode(0);
    test_audio_step.dependOn(&run_audio_smoke.step);
    test_step.dependOn(&run_audio_smoke.step);

    // Scalar-vs-vector timings for the audio SIMD helpers. It links nothing —
    // no whisper, no ggml, no libc — so it stays runnable on any host, and it is
    // pinned to ReleaseFast because a Debug build would only be measuring the
    // absence of optimization in both columns.
    const simd_module = b.createModule(.{
        .root_source_file = b.path("src/audio/simd.zig"),
        .target = config.target,
        .optimize = .ReleaseFast,
    });
    const bench_simd = b.addExecutable(.{
        .name = "simd-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/simd-bench/main.zig"),
            .target = config.target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "simd", .module = simd_module }},
        }),
    });
    bench_simd_step.dependOn(&b.addRunArtifact(bench_simd).step);
    // Compile it under the regular test step so it cannot rot unnoticed. It is
    // not run there: a timing loop is not a pass/fail check.
    test_step.dependOn(&bench_simd.step);

    // A quiet, fixed-workload executable intended for whole-process comparison:
    // build the old and new revisions, preserve each binary, then run
    // `poop old/downmix-bench new/downmix-bench`. Keeping measurement outside
    // the process avoids the timer and warm-up pitfalls described in the SIMD
    // article while also exposing memory and hardware-counter regressions.
    const downmix_bench = b.addExecutable(.{
        .name = "downmix-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/downmix-bench/main.zig"),
            .target = config.target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "audio", .module = audio_module }},
        }),
    });
    bench_downmix_step.dependOn(&b.addInstallArtifact(downmix_bench, .{}).step);
    test_step.dependOn(&downmix_bench.step);

    // Keep the benchmark on the public C boundary and link the exact combined
    // static archive that `zig build libwhisper` installs. Arguments after `--`
    // are forwarded to the runner, for example:
    //   zig build bench-libwhisper -Doptimize=ReleaseFast -- model.bin audio.wav
    const bench = libwhisper.addZigExample(
        b,
        &deps,
        "examples/bench/main.zig",
        "libwhisper-bench",
    );
    // The benchmark decodes WAV through the audio library rather than carrying
    // its own parser, which is the first real consumer of that boundary.
    bench.root_module.addImport("audio", audio_module);
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    bench_libwhisper_step.dependOn(&run_bench.step);
    // Compile (but do not run) it with the regular libwhisper checks so C API
    // or build-wiring drift is caught without requiring a model fixture in CI.
    test_libwhisper_step.dependOn(&bench.step);
}
