const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const BobrWhisperLib = @import("BobrWhisperLib.zig");

pub const BobrWhisperXCFramework = @This();

pub const Target = enum { macos, ios };

step: *std.Build.Step,

pub fn init(b: *std.Build, config: *const Config, target: Target) !BobrWhisperXCFramework {
    return switch (target) {
        .macos => initMacOS(b, config),
        .ios => initIOS(b, config),
    };
}

fn initMacOS(b: *std.Build, config: *const Config) !BobrWhisperXCFramework {
    const opt = config.xcframeworkOptimize();
    const target = Config.macosArm64Target(b);

    const deps = try SharedDeps.initForTarget(b, config, target, opt);
    const lib = try BobrWhisperLib.initStatic(b, &deps);

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "macos/BobrWhisperKit.xcframework/macos-arm64/include" });

    const copy_lib = b.addSystemCommand(&.{"cp"});
    copy_lib.addFileArg(lib.output);
    copy_lib.addArg("macos/BobrWhisperKit.xcframework/macos-arm64/libbobrwhisper.a");
    copy_lib.step.dependOn(lib.step);
    copy_lib.step.dependOn(&mkdir.step);

    const copy_headers = b.addSystemCommand(&.{
        "cp",                                                    "-r", "include/bobrwhisper.h", "include/module.modulemap",
        "macos/BobrWhisperKit.xcframework/macos-arm64/include/",
    });
    copy_headers.step.dependOn(&copy_lib.step);

    const write_plist = b.addSystemCommand(&.{ "sh", "-c", macos_plist });
    write_plist.step.dependOn(&copy_headers.step);

    return .{ .step = &write_plist.step };
}

fn initIOS(b: *std.Build, config: *const Config) !BobrWhisperXCFramework {
    const opt = config.xcframeworkOptimize();

    const ios_deps = try SharedDeps.initForTarget(b, config, Config.iosDeviceTarget(b), opt);
    const sim_deps = try SharedDeps.initForTarget(b, config, Config.iosSimulatorTarget(b), opt);

    const ios_lib = try BobrWhisperLib.initStatic(b, &ios_deps);
    const sim_lib = try BobrWhisperLib.initStatic(b, &sim_deps);

    const mkdir = b.addSystemCommand(&.{
        "sh",                                                                                                                   "-c",
        "mkdir -p ios/BobrWhisperKit.xcframework/ios-arm64/include ios/BobrWhisperKit.xcframework/ios-arm64-simulator/include",
    });

    const copy_ios_lib = b.addSystemCommand(&.{"cp"});
    copy_ios_lib.addFileArg(ios_lib.output);
    copy_ios_lib.addArg("ios/BobrWhisperKit.xcframework/ios-arm64/libbobrwhisper.a");
    copy_ios_lib.step.dependOn(ios_lib.step);
    copy_ios_lib.step.dependOn(&mkdir.step);

    const copy_sim_lib = b.addSystemCommand(&.{"cp"});
    copy_sim_lib.addFileArg(sim_lib.output);
    copy_sim_lib.addArg("ios/BobrWhisperKit.xcframework/ios-arm64-simulator/libbobrwhisper.a");
    copy_sim_lib.step.dependOn(sim_lib.step);
    copy_sim_lib.step.dependOn(&mkdir.step);

    const copy_headers = b.addSystemCommand(&.{
        "sh", "-c",
        "cp -r include/bobrwhisper.h include/module.modulemap ios/BobrWhisperKit.xcframework/ios-arm64/include/ && " ++
            "cp -r include/bobrwhisper.h include/module.modulemap ios/BobrWhisperKit.xcframework/ios-arm64-simulator/include/",
    });
    copy_headers.step.dependOn(&copy_ios_lib.step);
    copy_headers.step.dependOn(&copy_sim_lib.step);

    const write_plist = b.addSystemCommand(&.{ "sh", "-c", ios_plist });
    write_plist.step.dependOn(&copy_headers.step);

    return .{ .step = &write_plist.step };
}

const macos_plist =
    \\cat > macos/BobrWhisperKit.xcframework/Info.plist << 'EOF'
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\    <key>AvailableLibraries</key>
    \\    <array>
    \\        <dict>
    \\            <key>HeadersPath</key>
    \\            <string>include</string>
    \\            <key>LibraryIdentifier</key>
    \\            <string>macos-arm64</string>
    \\            <key>LibraryPath</key>
    \\            <string>libbobrwhisper.a</string>
    \\            <key>SupportedArchitectures</key>
    \\            <array>
    \\                <string>arm64</string>
    \\            </array>
    \\            <key>SupportedPlatform</key>
    \\            <string>macos</string>
    \\        </dict>
    \\    </array>
    \\    <key>CFBundlePackageType</key>
    \\    <string>XFWK</string>
    \\    <key>XCFrameworkFormatVersion</key>
    \\    <string>1.0</string>
    \\</dict>
    \\</plist>
    \\EOF
;

const ios_plist =
    \\cat > ios/BobrWhisperKit.xcframework/Info.plist << 'EOF'
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\    <key>AvailableLibraries</key>
    \\    <array>
    \\        <dict>
    \\            <key>HeadersPath</key>
    \\            <string>include</string>
    \\            <key>LibraryIdentifier</key>
    \\            <string>ios-arm64</string>
    \\            <key>LibraryPath</key>
    \\            <string>libbobrwhisper.a</string>
    \\            <key>SupportedArchitectures</key>
    \\            <array>
    \\                <string>arm64</string>
    \\            </array>
    \\            <key>SupportedPlatform</key>
    \\            <string>ios</string>
    \\        </dict>
    \\        <dict>
    \\            <key>HeadersPath</key>
    \\            <string>include</string>
    \\            <key>LibraryIdentifier</key>
    \\            <string>ios-arm64-simulator</string>
    \\            <key>LibraryPath</key>
    \\            <string>libbobrwhisper.a</string>
    \\            <key>SupportedArchitectures</key>
    \\            <array>
    \\                <string>arm64</string>
    \\            </array>
    \\            <key>SupportedPlatform</key>
    \\            <string>ios</string>
    \\            <key>SupportedPlatformVariant</key>
    \\            <string>simulator</string>
    \\        </dict>
    \\    </array>
    \\    <key>CFBundlePackageType</key>
    \\    <string>XFWK</string>
    \\    <key>XCFrameworkFormatVersion</key>
    \\    <string>1.0</string>
    \\</dict>
    \\</plist>
    \\EOF
;
