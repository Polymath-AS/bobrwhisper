//! BobrWhisper - Local-first voice-to-text
//! C ABI exports for Swift/GTK integration

const std = @import("std");
const builtin = @import("builtin");
const asr = @import("asr");
const c = @import("c_api.zig");
const App = @import("App.zig");

pub const version = "0.1.0";

const GPA = std.heap.DebugAllocator(.{});
var gpa: ?GPA = null;
var global_allocator: ?std.mem.Allocator = null;

fn getAllocator() std.mem.Allocator {
    // Release mode: use libc allocator (faster, thread-safe)
    if (comptime builtin.mode != .Debug) {
        if (comptime builtin.link_libc) {
            return std.heap.c_allocator;
        }
    }
    // Debug mode: use GPA for leak detection
    if (gpa) |*g| {
        return g.allocator();
    }
    return std.heap.c_allocator;
}

pub export fn bobrwhisper_init() c_int {
    if (comptime builtin.mode == .Debug) {
        gpa = GPA{};
        std.log.info("bobrwhisper: using GPA allocator (debug mode)", .{});
    } else {
        std.log.info("bobrwhisper: using c_allocator (release mode)", .{});
    }
    global_allocator = getAllocator();
    return 0;
}

pub export fn bobrwhisper_deinit() void {
    global_allocator = null;
    if (gpa) |*g| {
        _ = g.deinit();
        gpa = null;
    }
}

pub export fn bobrwhisper_version() c.String {
    return c.String.fromSlice(version);
}

pub export fn bobrwhisper_app_new(config: ?*const c.RuntimeConfig) ?*App {
    const alloc = global_allocator orelse return null;
    const cfg = config orelse return null;

    const app = App.init(alloc, cfg.*) catch |err| {
        std.log.err("Failed to create app: {}", .{err});
        return null;
    };

    const ptr = alloc.create(App) catch return null;
    ptr.* = app;
    return ptr;
}

pub export fn bobrwhisper_app_free(app: ?*App) void {
    const a = app orelse return;
    const alloc = global_allocator orelse return;
    a.deinit();
    alloc.destroy(a);
}

pub export fn bobrwhisper_start_recording(app: ?*App) bool {
    const a = app orelse return false;
    a.startRecording() catch return false;
    return true;
}

pub export fn bobrwhisper_start_recording_live(app: ?*App, language: ?[*:0]const u8) bool {
    const a = app orelse return false;
    const lang = if (language) |l| std.mem.span(l) else "en";
    a.startRecordingWithLiveTranscription(lang) catch return false;
    return true;
}

pub export fn bobrwhisper_stop_recording(app: ?*App) void {
    const a = app orelse return;
    a.stopRecording();
}

pub export fn bobrwhisper_stop_recording_live(app: ?*App, options: ?*const c.TranscribeOptions) bool {
    const a = app orelse return false;
    const opts = options orelse return false;
    a.stopRecordingAndTranscribe(opts.*) catch return false;
    return true;
}

pub export fn bobrwhisper_is_recording(app: ?*App) bool {
    const a = app orelse return false;
    return a.isRecording();
}

pub export fn bobrwhisper_get_status(app: ?*App) c.Status {
    const a = app orelse return .idle;
    return a.getStatus();
}

pub export fn bobrwhisper_get_audio_level(app: ?*App) f32 {
    const a = app orelse return 0;
    return a.getAudioLevel();
}

pub export fn bobrwhisper_model_count(app: ?*App) usize {
    _ = app;
    return asr.ModelRegistry.count();
}

pub export fn bobrwhisper_model_descriptor_at(
    app: ?*App,
    index: usize,
    out_descriptor: ?*c.ModelDescriptor,
) bool {
    _ = app;
    const descriptor_out = out_descriptor orelse return false;
    const descriptor = asr.ModelRegistry.descriptorAt(index) orelse return false;
    descriptor_out.* = c.ModelDescriptor.fromAsrDescriptor(descriptor);
    return true;
}

pub export fn bobrwhisper_model_exists_id(app: ?*App, model_id: ?[*:0]const u8) bool {
    const a = app orelse return false;
    const id = model_id orelse return false;
    return a.modelExistsByID(std.mem.span(id));
}

pub export fn bobrwhisper_model_path_id(app: ?*App, model_id: ?[*:0]const u8) c.String {
    const a = app orelse return c.String.fromSlice("");
    const id = model_id orelse return c.String.fromSlice("");
    return a.getModelPathByID(std.mem.span(id)) catch return c.String.fromSlice("");
}

pub export fn bobrwhisper_model_load_id(app: ?*App, model_id: ?[*:0]const u8) bool {
    const a = app orelse return false;
    const id = model_id orelse return false;
    a.loadModelByID(std.mem.span(id)) catch return false;
    return true;
}

pub export fn bobrwhisper_model_exists(app: ?*App, size: c.ModelSize) bool {
    const a = app orelse return false;
    return a.modelExists(size);
}

pub export fn bobrwhisper_model_path(app: ?*App, size: c.ModelSize) c.String {
    const a = app orelse return c.String.fromSlice("");
    return a.getModelPath(size) catch return c.String.fromSlice("");
}

pub export fn bobrwhisper_model_load(app: ?*App, size: c.ModelSize) bool {
    const a = app orelse return false;
    a.loadModel(size) catch return false;
    return true;
}

pub export fn bobrwhisper_model_unload(app: ?*App) void {
    const a = app orelse return;
    a.unloadModel();
}

pub export fn bobrwhisper_settings_write(app: ?*App, settings: ?*const c.Settings) bool {
    const a = app orelse return false;
    const s = settings orelse return false;
    a.writeSettings(s.*) catch return false;
    return true;
}

pub export fn bobrwhisper_transcribe(
    app: ?*App,
    options: ?*const c.TranscribeOptions,
) bool {
    const a = app orelse return false;
    const opts = options orelse return false;
    a.transcribe(opts.*) catch return false;
    return true;
}

pub export fn bobrwhisper_format_text(
    app: ?*App,
    input: c.String,
    tone: c.Tone,
    callback: c.TranscriptCallback,
    userdata: ?*anyopaque,
) bool {
    const a = app orelse return false;
    a.formatText(input.toSlice(), tone, callback, userdata) catch return false;
    return true;
}

pub export fn bobrwhisper_log_transcript(app: ?*App, transcript: c.String) bool {
    const a = app orelse return false;
    a.appendTranscriptLog(transcript.toSlice(), null) catch return false;
    return true;
}

pub export fn bobrwhisper_log_recent_json(app: ?*App, limit: usize) c.String {
    const a = app orelse return c.String.fromSlice("[]");
    return a.getTranscriptLogRecentJson(limit) catch c.String.fromSlice("[]");
}

pub export fn bobrwhisper_log_clear(app: ?*App) bool {
    const a = app orelse return false;
    a.clearTranscriptLog() catch return false;
    return true;
}

pub export fn bobrwhisper_string_free(str: c.String) void {
    str.deinit(global_allocator orelse return);
}

test "init and deinit" {
    const result = bobrwhisper_init();
    try std.testing.expectEqual(@as(c_int, 0), result);
    bobrwhisper_deinit();
}

test "version" {
    const v = bobrwhisper_version();
    try std.testing.expectEqualStrings("0.1.0", v.toSlice());
}
