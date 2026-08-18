//! Stable-prefix/revisable-tail session state independent of ASR and UI.

const std = @import("std");
const Postprocess = @import("Postprocess.zig");
const ContextPack = @import("ContextPack.zig");

pub const Lifecycle = enum { capturing, draining, finalizing, completed, cancelled, failed };
pub const Phase = enum(c_int) { recognizing = 0, cleaning = 1, final = 2 };

pub const Snapshot = struct {
    session_id: u64,
    revision: u64,
    stable_text: []const u8,
    unstable_text: []const u8,
    phase: Phase,
};

allocator: std.mem.Allocator,
id: u64,
revision: u64 = 0,
lifecycle: Lifecycle = .capturing,
mode: Postprocess.Mode,
context: ContextPack,
stable: std.ArrayListUnmanaged(u8) = .empty,
unstable: std.ArrayListUnmanaged(u8) = .empty,
previous_hypothesis: std.ArrayListUnmanaged(u8) = .empty,
final_emitted: bool = false,

pub fn init(allocator: std.mem.Allocator, id: u64, mode: Postprocess.Mode, context_input: ContextPack.Input) !@This() {
    return .{ .allocator = allocator, .id = id, .mode = mode, .context = try ContextPack.init(allocator, context_input) };
}

pub fn deinit(self: *@This()) void {
    self.context.deinit();
    self.stable.deinit(self.allocator);
    self.unstable.deinit(self.allocator);
    self.previous_hypothesis.deinit(self.allocator);
}

pub fn cancel(self: *@This()) void {
    if (self.lifecycle != .completed) self.lifecycle = .cancelled;
}

pub fn isActive(self: @This()) bool {
    return switch (self.lifecycle) {
        .capturing, .draining, .finalizing => true,
        else => false,
    };
}

pub fn updateHypothesis(self: *@This(), hypothesis: []const u8) !?Snapshot {
    if (self.lifecycle != .capturing) return null;
    const deterministic = try Postprocess.deterministic(self.allocator, hypothesis, self.mode);
    defer self.allocator.free(deterministic);
    const cleaned = try self.context.applyContextCasing(self.allocator, deterministic);
    defer self.allocator.free(cleaned);

    const old_stable_len = self.stable.items.len;
    const common = commonTokenPrefix(self.previous_hypothesis.items, cleaned);
    const freeze_end = freezeBoundary(cleaned, common);
    if (freeze_end > self.stable.items.len and std.mem.startsWith(u8, cleaned, self.stable.items)) {
        try self.stable.appendSlice(self.allocator, cleaned[self.stable.items.len..freeze_end]);
    }

    const tail_start = @min(self.stable.items.len, cleaned.len);
    const tail = cleaned[tail_start..];
    const projection_changed = self.stable.items.len != old_stable_len or
        !std.mem.eql(u8, self.unstable.items, tail);
    self.unstable.clearRetainingCapacity();
    try self.unstable.appendSlice(self.allocator, tail);
    self.previous_hypothesis.clearRetainingCapacity();
    try self.previous_hypothesis.appendSlice(self.allocator, cleaned);
    if (!projection_changed) return null;
    self.revision += 1;
    return self.snapshot(.recognizing);
}

pub fn beginDraining(self: *@This()) void {
    if (self.lifecycle == .capturing) self.lifecycle = .draining;
}

pub fn beginFinalizing(self: *@This()) void {
    if (self.lifecycle == .draining or self.lifecycle == .capturing) self.lifecycle = .finalizing;
}

pub fn updateCleaning(self: *@This(), text: []const u8) !?Snapshot {
    if (self.lifecycle != .draining and self.lifecycle != .finalizing) return null;
    const deterministic = try Postprocess.deterministic(self.allocator, text, self.mode);
    defer self.allocator.free(deterministic);
    const cleaned = try self.context.applyContextCasing(self.allocator, deterministic);
    defer self.allocator.free(cleaned);
    if (!std.mem.startsWith(u8, cleaned, self.stable.items)) return null;
    self.unstable.clearRetainingCapacity();
    try self.unstable.appendSlice(self.allocator, cleaned[self.stable.items.len..]);
    self.revision += 1;
    return self.snapshot(.cleaning);
}

/// Apply asynchronous clause cleanup only when the session has not advanced
/// since the cleanup input was captured. The stable prefix remains immutable;
/// only the session-owned tail may change.
pub fn updateCleaningAtRevision(self: *@This(), input_revision: u64, text: []const u8) !?Snapshot {
    if (self.lifecycle != .capturing and self.lifecycle != .draining) return null;
    if (self.revision != input_revision) return null;
    const cleaned = try self.context.applyContextCasing(self.allocator, text);
    defer self.allocator.free(cleaned);
    if (!std.mem.startsWith(u8, cleaned, self.stable.items)) return null;

    const tail = cleaned[self.stable.items.len..];
    if (std.mem.eql(u8, tail, self.unstable.items)) return null;
    self.unstable.clearRetainingCapacity();
    try self.unstable.appendSlice(self.allocator, tail);
    self.revision += 1;
    return self.snapshot(.cleaning);
}

pub fn final(self: *@This(), text: []const u8) !?Snapshot {
    if (!self.isActive() or self.final_emitted) return null;
    const deterministic = try Postprocess.deterministic(self.allocator, text, self.mode);
    defer self.allocator.free(deterministic);
    const cleaned = try self.context.applyContextCasing(self.allocator, deterministic);
    defer self.allocator.free(cleaned);
    if (!std.mem.startsWith(u8, cleaned, self.stable.items)) return error.StablePrefixConflict;
    try self.stable.appendSlice(self.allocator, cleaned[self.stable.items.len..]);
    self.unstable.clearRetainingCapacity();
    self.revision += 1;
    self.final_emitted = true;
    self.lifecycle = .completed;
    return self.snapshot(.final);
}

pub fn snapshot(self: @This(), phase: Phase) Snapshot {
    return .{ .session_id = self.id, .revision = self.revision, .stable_text = self.stable.items, .unstable_text = self.unstable.items, .phase = phase };
}

fn commonTokenPrefix(a: []const u8, b: []const u8) usize {
    var i: usize = 0;
    var last_boundary: usize = 0;
    while (i < a.len and i < b.len and a[i] == b[i]) : (i += 1) {
        if (std.ascii.isWhitespace(a[i]) or std.mem.indexOfScalar(u8, ".!?;", a[i]) != null) last_boundary = i + 1;
    }
    return last_boundary;
}

fn freezeBoundary(text: []const u8, common: usize) usize {
    if (common == 0) return 0;
    // Keep the most recent complete clause revisable. A following correction
    // cue ("Sorry, Friday") is allowed to rewrite that clause before final
    // cleanup without violating the append-only stable-prefix contract.
    var previous_terminal: usize = 0;
    var last_terminal: usize = 0;
    for (text[0..common], 0..) |ch, i| if (ch == '.' or ch == '!' or ch == '?' or ch == ';') {
        previous_terminal = last_terminal;
        last_terminal = i + 1;
        while (last_terminal < common and text[last_terminal] == ' ') last_terminal += 1;
    };

    return @max(previous_terminal, revisableTailStart(text[0..common], 24));
}

fn revisableTailStart(text: []const u8, max_words: usize) usize {
    if (max_words == 0) return text.len;
    var words: usize = 0;
    var index = text.len;
    var in_word = false;
    while (index > 0) {
        index -= 1;
        if (std.ascii.isWhitespace(text[index])) {
            if (in_word) {
                words += 1;
                if (words == max_words) {
                    while (index < text.len and std.ascii.isWhitespace(text[index])) index += 1;
                    return index;
                }
            }
            in_word = false;
        } else in_word = true;
    }
    return 0;
}

test "stable prefix only grows and final emits exactly once" {
    var session = try @This().init(std.testing.allocator, 7, .conservative, .{});
    defer session.deinit();
    const first = (try session.updateHypothesis("One complete sentence. Another sentence. changing tail")) orelse return error.MissingUpdate;
    try std.testing.expectEqual(@as(usize, 0), first.stable_text.len);
    const second = (try session.updateHypothesis("One complete sentence. Another sentence. changed tail")) orelse return error.MissingUpdate;
    try std.testing.expectEqualStrings("One complete sentence. ", second.stable_text);
    const stable_copy = try std.testing.allocator.dupe(u8, second.stable_text);
    defer std.testing.allocator.free(stable_copy);
    _ = try session.updateHypothesis("One complete sentence. Another sentence. another tail");
    try std.testing.expectEqualStrings(stable_copy, session.stable.items);
    session.beginDraining();
    session.beginFinalizing();
    const final_update = (try session.final("One complete sentence. Another sentence. final tail")) orelse return error.MissingUpdate;
    try std.testing.expectEqual(.final, final_update.phase);
    try std.testing.expect((try session.final("duplicate")) == null);
}

test "cancelled session ignores late callbacks" {
    var session = try @This().init(std.testing.allocator, 9, .literal, .{});
    defer session.deinit();
    session.cancel();
    try std.testing.expect((try session.updateHypothesis("late")) == null);
    try std.testing.expect((try session.final("late")) == null);
}

test "cleaning cannot rewrite a stable prefix" {
    var session = try @This().init(std.testing.allocator, 10, .conservative, .{});
    defer session.deinit();
    _ = try session.updateHypothesis("Fixed sentence. Another sentence. first tail");
    _ = try session.updateHypothesis("Fixed sentence. Another sentence. second tail");
    const stable = try std.testing.allocator.dupe(u8, session.stable.items);
    defer std.testing.allocator.free(stable);
    session.beginDraining();
    try std.testing.expect((try session.updateCleaning("Rewritten sentence. Another sentence. tail")) == null);
    try std.testing.expectEqualStrings(stable, session.stable.items);
}

test "latest complete clause remains revisable for spoken corrections" {
    var session = try @This().init(std.testing.allocator, 11, .conservative, .{});
    defer session.deinit();

    _ = try session.updateHypothesis("Can you schedule a meeting for Wednesday?");
    _ = try session.updateHypothesis("Can you schedule a meeting for Wednesday?");
    try std.testing.expectEqual(@as(usize, 0), session.stable.items.len);

    session.beginDraining();
    const final_update = (try session.final(
        "Can you schedule a meeting for Wednesday? Sorry, Friday.",
    )) orelse return error.MissingUpdate;
    try std.testing.expectEqualStrings("Can you schedule a meeting for Friday?", final_update.stable_text);
}

test "final rejects a rewrite of an already stable prefix" {
    var session = try @This().init(std.testing.allocator, 12, .conservative, .{});
    defer session.deinit();
    _ = try session.updateHypothesis("First sentence. Second sentence. changing tail");
    _ = try session.updateHypothesis("First sentence. Second sentence. changed tail");
    session.beginDraining();
    try std.testing.expectError(
        error.StablePrefixConflict,
        session.final("Rewritten first sentence. Second sentence. final tail"),
    );
}

test "asynchronous cleaning applies only to its input revision" {
    var session = try @This().init(std.testing.allocator, 13, .conservative, .{});
    defer session.deinit();
    const initial = (try session.updateHypothesis("Schedule this for Friday?")) orelse return error.MissingUpdate;

    const cleaned = (try session.updateCleaningAtRevision(
        initial.revision,
        "Schedule this for Friday.",
    )) orelse return error.MissingUpdate;
    try std.testing.expectEqual(.cleaning, cleaned.phase);
    try std.testing.expectEqualStrings("Schedule this for Friday.", cleaned.unstable_text);

    try std.testing.expect((try session.updateCleaningAtRevision(
        initial.revision,
        "Stale rewrite.",
    )) == null);
}
