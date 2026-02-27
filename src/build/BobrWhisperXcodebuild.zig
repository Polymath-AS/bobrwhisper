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
    const team_id = if (config.xcode_sign) config.requireAppleTeamId() else config.apple_team_id;
    const development_team_arg = if (team_id) |apple_team_id| b.fmt("DEVELOPMENT_TEAM={s}", .{apple_team_id}) else null;
    const code_sign_identity_arg = if (config.code_sign_identity) |identity| b.fmt("CODE_SIGN_IDENTITY={s}", .{identity}) else null;

    const xcodebuild = switch (target) {
        .macos => if (team_id != null)
            if (config.code_sign_identity != null)
                b.addSystemCommand(&.{
                    "xcodebuild",
                    "-project",
                    "macos/BobrWhisper.xcodeproj",
                    "-scheme",
                    "BobrWhisper",
                    "-configuration",
                    configuration,
                    development_team_arg.?,
                    code_sign_identity_arg.?,
                    "build",
                    "ARCHS=arm64",
                })
            else
                b.addSystemCommand(&.{
                    "xcodebuild",
                    "-project",
                    "macos/BobrWhisper.xcodeproj",
                    "-scheme",
                    "BobrWhisper",
                    "-configuration",
                    configuration,
                    development_team_arg.?,
                    "build",
                    "ARCHS=arm64",
                })
        else
            b.addSystemCommand(&.{
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
        .ios => if (config.xcode_sign)
            if (config.code_sign_identity != null)
                b.addSystemCommand(&.{
                    "xcodebuild",
                    "-project",
                    "ios/BobrWhisper.xcodeproj",
                    "-scheme",
                    "BobrWhisper",
                    "-configuration",
                    configuration,
                    "-sdk",
                    "iphoneos",
                    development_team_arg.?,
                    code_sign_identity_arg.?,
                    "build",
                })
            else
                b.addSystemCommand(&.{
                    "xcodebuild",
                    "-project",
                    "ios/BobrWhisper.xcodeproj",
                    "-scheme",
                    "BobrWhisper",
                    "-configuration",
                    configuration,
                    "-sdk",
                    "iphoneos",
                    development_team_arg.?,
                    "build",
                })
        else
            b.addSystemCommand(&.{
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
