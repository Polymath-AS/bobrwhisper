const std = @import("std");
const builtin = @import("builtin");
const c_api = @import("c_api.zig");

const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

const cf = if (is_apple) @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
}) else struct {};

pub const WriteError = error{
    UnsupportedPlatform,
    InvalidUTF8,
    InvalidDomain,
    OutOfMemory,
    SyncFailed,
};

pub fn write(config: c_api.RuntimeConfig, settings: c_api.Settings) WriteError!void {
    std.debug.assert(config.getConfigDomain().len > 0);

    if (comptime builtin.os.tag == .linux or builtin.os.tag == .windows) {
        @compileError("Settings persistence is intentionally unsupported on Linux and Windows for now.");
    }

    if (comptime is_apple) {
        try writeApple(config.getConfigDomain(), settings);
        return;
    }

    return WriteError.UnsupportedPlatform;
}

fn writeApple(domain: []const u8, settings: c_api.Settings) WriteError!void {
    std.debug.assert(domain.len > 0);

    const domain_cf = try makeCFString(domain);
    defer cf.CFRelease(domain_cf);

    const key_tone = try makeCFString("tone");
    defer cf.CFRelease(key_tone);

    const key_remove_filler_words = try makeCFString("removeFillerWords");
    defer cf.CFRelease(key_remove_filler_words);

    const key_auto_punctuate = try makeCFString("autoPunctuate");
    defer cf.CFRelease(key_auto_punctuate);

    const key_use_llm_formatting = try makeCFString("useLlmFormatting");
    defer cf.CFRelease(key_use_llm_formatting);

    var tone_value: i32 = @intFromEnum(settings.tone);
    const tone_number = cf.CFNumberCreate(
        cf.kCFAllocatorDefault,
        cf.kCFNumberSInt32Type,
        &tone_value,
    ) orelse return WriteError.OutOfMemory;
    defer cf.CFRelease(tone_number);

    cf.CFPreferencesSetAppValue(key_tone, tone_number, domain_cf);
    cf.CFPreferencesSetAppValue(
        key_remove_filler_words,
        if (settings.remove_filler_words) cf.kCFBooleanTrue else cf.kCFBooleanFalse,
        domain_cf,
    );
    cf.CFPreferencesSetAppValue(
        key_auto_punctuate,
        if (settings.auto_punctuate) cf.kCFBooleanTrue else cf.kCFBooleanFalse,
        domain_cf,
    );
    cf.CFPreferencesSetAppValue(
        key_use_llm_formatting,
        if (settings.use_llm_formatting) cf.kCFBooleanTrue else cf.kCFBooleanFalse,
        domain_cf,
    );

    const sync_ok = cf.CFPreferencesAppSynchronize(domain_cf);
    if (sync_ok == 0) {
        return WriteError.SyncFailed;
    }
}

fn makeCFString(value: []const u8) WriteError!cf.CFStringRef {
    if (!std.unicode.utf8ValidateSlice(value)) {
        return WriteError.InvalidUTF8;
    }

    const cf_string = cf.CFStringCreateWithBytes(
        cf.kCFAllocatorDefault,
        value.ptr,
        @intCast(value.len),
        cf.kCFStringEncodingUTF8,
        0,
    ) orelse return WriteError.InvalidDomain;

    return cf_string;
}
