const std = @import("std");
const Config = @import("Config.zig");
const BobrWhisperXCFramework = @import("BobrWhisperXCFramework.zig");

pub const BobrWhisperXcodebuild = @This();

pub const Target = enum { macos, ios };

step: *std.Build.Step,

const VAD_MODEL_URL = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin";
const VAD_MODEL_PATH = "resources/silero-v6.2.0.bin";

pub fn init(
    b: *std.Build,
    config: *const Config,
    xcframework: *const BobrWhisperXCFramework,
    target: Target,
) BobrWhisperXcodebuild {
    const configuration = config.xcodebuildConfiguration();

    const xcodebuild = switch (target) {
        .macos => b.addSystemCommand(&.{
            "xcodebuild",
            "-project",
            "macos/BobrWhisper.xcodeproj",
            "-scheme",
            "BobrWhisper",
            "-configuration",
            configuration,
            "build",
            "ARCHS=arm64",
        }),
        .ios => b.addSystemCommand(&.{
            "xcodebuild",
            "-project",
            "ios/BobrWhisper.xcodeproj",
            "-scheme",
            "BobrWhisper",
            "-configuration",
            configuration,
            "-sdk",
            "iphoneos",
            "CODE_SIGN_IDENTITY=-",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        }),
    };

    xcodebuild.step.dependOn(xcframework.step);

    const vad_download = b.addSystemCommand(&.{
        "sh",
        "-c",
        "mkdir -p resources && [ -f " ++ VAD_MODEL_PATH ++ " ] || curl -fsSL -o " ++ VAD_MODEL_PATH ++ " " ++ VAD_MODEL_URL,
    });
    xcodebuild.step.dependOn(&vad_download.step);

    return .{ .step = &xcodebuild.step };
}

pub fn addRunStep(b: *std.Build, xcodebuild: *const BobrWhisperXcodebuild) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "BobrWhisper.app" -path "*/Debug/*" 2>/dev/null | head -1)
        \\if [ -z "$APP_PATH" ]; then
        \\    echo "Error: BobrWhisper.app not found in DerivedData"
        \\    exit 1
        \\fi
        \\exec "$APP_PATH/Contents/MacOS/BobrWhisper"
        ,
    });
    run.step.dependOn(xcodebuild.step);
    return run;
}
