//! User-curated phrase list for biasing the Whisper decoder.
//!
//! Stored as a plain text file at `<models_dir>/dictionary.txt`, one phrase
//! per line. Lines starting with `*` (after the leading whitespace) are
//! "starred": they are emitted before unstarred phrases when the prompt is
//! built, so the highest-priority vocabulary fits inside Whisper's ~224-token
//! initial-prompt window even when the file is much larger.
//!
//! Whisper Flow's equivalent (`dictionaryContext` + `starredDictionaryContext`)
//! is the single biggest reason their cloud transcripts spell proper nouns
//! correctly. With a local model we can't match the cloud's contextual
//! richness, but a curated phrase list still moves the needle on names,
//! product terms, and acronyms.
//!
//! Format example:
//!
//!     # comments and blank lines are ignored
//!     * Sourcegraph
//!     * BobrWhisper
//!     Polymath
//!     ExampleProduct
//!     Baseten
//!
//! The file is owner-writable plain text so users can `vim` it. Loading is
//! lazy and best-effort: a missing file yields an empty dictionary, never
//! an error, so dictation works out-of-the-box.

const std = @import("std");
const compat = @import("compat.zig");

const DictionaryStore = @This();

/// Soft cap on the prompt string passed to `whisper.cpp`. Whisper allows
/// ~224 prompt tokens; tokens average ~3.5–4 chars in English, leaving us a
/// 768-byte ceiling that comfortably stays under the limit while leaving
/// headroom for non-ASCII tokenization (e.g. UTF-8 names).
pub const max_prompt_bytes: usize = 768;

allocator: std.mem.Allocator,
/// Owned, allocator-backed strings. Starred phrases come first.
phrases: std.ArrayListUnmanaged([]u8) = .empty,
starred_count: usize = 0,

/// Load `<models_dir>/dictionary.txt`. Missing/unreadable files return an
/// empty store rather than erroring — dictation should not break because the
/// user hasn't created a dictionary yet.
pub fn loadFromModelsDir(allocator: std.mem.Allocator, models_dir: []const u8) !DictionaryStore {
    std.debug.assert(models_dir.len > 0);

    var store: DictionaryStore = .{ .allocator = allocator };
    errdefer store.deinit();

    const path = try std.fmt.allocPrint(allocator, "{s}/dictionary.txt", .{models_dir});
    defer allocator.free(path);

    const file = std.Io.Dir.cwd().openFile(compat.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return store,
        else => {
            std.log.warn("DictionaryStore: failed to open {s}: {}", .{ path, err });
            return store;
        },
    };
    defer file.close(compat.io());

    const stat = file.stat(compat.io()) catch |err| {
        std.log.warn("DictionaryStore: stat failed for {s}: {}", .{ path, err });
        return store;
    };
    // Refuse pathologically large files (>1 MiB) — a sane dictionary is well
    // under 100 KiB and we don't want a runaway file to balloon allocations.
    const max_file_bytes: u64 = 1024 * 1024;
    if (stat.size > max_file_bytes) {
        std.log.warn("DictionaryStore: {s} is {d} bytes, exceeds {d} byte cap", .{ path, stat.size, max_file_bytes });
        return store;
    }

    const raw = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(raw);

    var io_buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(compat.io(), &io_buffer);
    reader.interface.readSliceAll(raw) catch |err| {
        std.log.warn("DictionaryStore: read failed for {s}: {}", .{ path, err });
        return store;
    };

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const starred = line[0] == '*';
        const body_unbounded = if (starred) std.mem.trim(u8, line[1..], " \t") else line;
        if (body_unbounded.len == 0) continue;

        const owned = try allocator.dupe(u8, body_unbounded);
        errdefer allocator.free(owned);

        if (starred) {
            try store.phrases.insert(allocator, store.starred_count, owned);
            store.starred_count += 1;
        } else {
            try store.phrases.append(allocator, owned);
        }
    }

    std.debug.assert(store.starred_count <= store.phrases.items.len);
    std.log.info(
        "DictionaryStore: loaded {d} phrases ({d} starred) from {s}",
        .{ store.phrases.items.len, store.starred_count, path },
    );
    return store;
}

pub fn deinit(self: *DictionaryStore) void {
    for (self.phrases.items) |phrase| {
        self.allocator.free(phrase);
    }
    self.phrases.deinit(self.allocator);
    self.starred_count = 0;
}

/// Build the Whisper `initial_prompt` string by concatenating phrases
/// (starred first) until `max_prompt_bytes` would be exceeded. Returns null
/// when the dictionary is empty so callers can branch on "no prompt to set".
/// Caller owns the returned slice.
pub fn buildPrompt(self: DictionaryStore, allocator: std.mem.Allocator) !?[]u8 {
    if (self.phrases.items.len == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (self.phrases.items) |phrase| {
        std.debug.assert(phrase.len > 0);
        // +2 for ", " separator (only after the first entry)
        const sep_len: usize = if (buf.items.len == 0) 0 else 2;
        if (buf.items.len + sep_len + phrase.len > max_prompt_bytes) break;
        if (sep_len > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, phrase);
    }

    if (buf.items.len == 0) return null;
    std.debug.assert(buf.items.len <= max_prompt_bytes);
    return try buf.toOwnedSlice(allocator);
}

test "empty store builds null prompt" {
    var store: DictionaryStore = .{ .allocator = std.testing.allocator };
    defer store.deinit();
    const prompt = try store.buildPrompt(std.testing.allocator);
    try std.testing.expectEqual(@as(?[]u8, null), prompt);
}

test "starred phrases come before unstarred" {
    var store: DictionaryStore = .{ .allocator = std.testing.allocator };
    defer store.deinit();
    try store.phrases.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "Banana"));
    // simulate one starred insert at front
    try store.phrases.insert(std.testing.allocator, 0, try std.testing.allocator.dupe(u8, "Apple"));
    store.starred_count = 1;

    const prompt = (try store.buildPrompt(std.testing.allocator)) orelse return error.UnexpectedNull;
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("Apple, Banana", prompt);
}

test "prompt respects max_prompt_bytes" {
    var store: DictionaryStore = .{ .allocator = std.testing.allocator };
    defer store.deinit();

    // 100 phrases of 16 chars + 2 sep = ~1800 bytes worth, well over 768.
    const phrase = "ABCDEFGHIJKLMNOP";
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try store.phrases.append(std.testing.allocator, try std.testing.allocator.dupe(u8, phrase));
    }
    const prompt = (try store.buildPrompt(std.testing.allocator)) orelse return error.UnexpectedNull;
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(prompt.len <= max_prompt_bytes);
    try std.testing.expect(prompt.len > 0);
}
