const std = @import("std");
const builtin = @import("builtin");
const c_api = @import("c_api.zig");

const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

/// Minimal CoreFoundation ABI surface for CFPreferences.
///
/// Zig 0.16 replaced Clang with Aro for @cImport and Aro cannot translate
/// Apple's mach_msg union types pulled in transitively by CoreFoundation.h.
/// Declaring only the symbols we actually call avoids the translation entirely.
const cf = if (is_apple) struct {
    const CFTypeRef = *anyopaque;
    const CFAllocatorRef = ?*anyopaque;
    const CFStringRef = *anyopaque;
    const CFNumberRef = *anyopaque;
    const CFBooleanRef = *anyopaque;
    const CFIndex = isize;
    const CFStringEncoding = u32;
    const CFNumberType = CFIndex;
    const Boolean = u8;

    const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;
    const kCFNumberSInt32Type: CFNumberType = 3;

    const kCFAllocatorDefault: CFAllocatorRef = null;
    /// C declares `const CFBooleanRef kCFBooleanTrue;` — a global variable
    /// holding a pointer.  `@extern` yields a pointer to that storage, so we
    /// declare `*const CFBooleanRef` and dereference at the use-site.
    const kCFBooleanTrue: *const CFBooleanRef = @extern(*const CFBooleanRef, .{ .name = "kCFBooleanTrue" });
    const kCFBooleanFalse: *const CFBooleanRef = @extern(*const CFBooleanRef, .{ .name = "kCFBooleanFalse" });

    extern "c" fn CFRelease(cf_obj: CFTypeRef) void;

    extern "c" fn CFStringCreateWithBytes(
        alloc: CFAllocatorRef,
        bytes: [*]const u8,
        num_bytes: CFIndex,
        encoding: CFStringEncoding,
        is_external_representation: Boolean,
    ) ?CFStringRef;

    extern "c" fn CFNumberCreate(
        allocator: CFAllocatorRef,
        the_type: CFNumberType,
        value_ptr: *const anyopaque,
    ) ?CFNumberRef;

    extern "c" fn CFPreferencesSetAppValue(
        key: CFStringRef,
        value: ?CFTypeRef,
        application_id: CFStringRef,
    ) void;

    extern "c" fn CFPreferencesAppSynchronize(
        application_id: CFStringRef,
    ) Boolean;
} else struct {};

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

    const key_custom_prompt = try makeCFString("customPrompt");
    defer cf.CFRelease(key_custom_prompt);

    var tone_value: i32 = @intFromEnum(settings.tone);
    const tone_number = cf.CFNumberCreate(
        cf.kCFAllocatorDefault,
        cf.kCFNumberSInt32Type,
        @ptrCast(&tone_value),
    ) orelse return WriteError.OutOfMemory;
    defer cf.CFRelease(tone_number);

    cf.CFPreferencesSetAppValue(key_tone, tone_number, domain_cf);
    cf.CFPreferencesSetAppValue(
        key_remove_filler_words,
        if (settings.remove_filler_words) cf.kCFBooleanTrue.* else cf.kCFBooleanFalse.*,
        domain_cf,
    );
    cf.CFPreferencesSetAppValue(
        key_auto_punctuate,
        if (settings.auto_punctuate) cf.kCFBooleanTrue.* else cf.kCFBooleanFalse.*,
        domain_cf,
    );
    cf.CFPreferencesSetAppValue(
        key_use_llm_formatting,
        if (settings.use_llm_formatting) cf.kCFBooleanTrue.* else cf.kCFBooleanFalse.*,
        domain_cf,
    );

    if (settings.getCustomPrompt()) |prompt| {
        const prompt_cf = try makeCFString(prompt);
        defer cf.CFRelease(prompt_cf);
        cf.CFPreferencesSetAppValue(key_custom_prompt, prompt_cf, domain_cf);
    } else {
        cf.CFPreferencesSetAppValue(key_custom_prompt, null, domain_cf);
    }

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
