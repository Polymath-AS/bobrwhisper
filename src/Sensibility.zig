//! Local "is this transcript nonsense?" heuristic.
//!
//! Whisper has well-known failure modes on silence, breath noise, music, and
//! short out-of-distribution input. The model is overconfident: it produces
//! grammatically clean but semantically empty strings ("Thanks for watching!",
//! "Subtitles by Amara.org community", looping single tokens, ...). We don't
//! want to spend a local LLM call (or interrupt the user) on text we can detect
//! as garbage with simple pattern matching.
//!
//! `isNonsense` returns true when *any* of three signals fire:
//!
//!   1. Exact (case-insensitive, punctuation-insensitive) match against a
//!      known-bad list seeded from observed Whisper failure outputs.
//!   2. Single-token loop: the same word repeated >= `max_token_repeat` times
//!      in a row anywhere in the transcript.
//!   3. Trigram loop: any 3-word window repeated >= `max_trigram_repeat`
//!      times in the entire transcript.
//!
//! All three are pure, allocation-free, and run in O(n) over token count.
//! False positives have a real cost (lost transcript), so the thresholds are
//! deliberately loose — only "obviously broken" output is rejected.

const std = @import("std");

/// Same single token repeated this many times in a row → loop.
const max_token_repeat: usize = 5;
/// Same trigram repeated this many times anywhere in the transcript → loop.
const max_trigram_repeat: usize = 3;

/// Strings that Whisper emits during silence / non-speech audio. Compared
/// case-insensitively after stripping punctuation and collapsing whitespace.
const known_bad: []const []const u8 = &.{
    "thanks for watching",
    "thank you for watching",
    "thanks for watching the video",
    "thank you so much for watching",
    "please subscribe",
    "subtitles by the amara org community",
    "subtitles by",
    "transcribed by",
    "music",
    "applause",
    "silence",
    "you",
    "thank you",
    "bye",
    "okay",
    "hmm",
    "uh",
    "um",
};

/// Returns true when the transcript looks like Whisper hallucinated nonsense
/// over silence/non-speech audio. Pure function; no allocation.
pub fn isNonsense(text: []const u8) bool {
    var trim_buf: [512]u8 = undefined;
    const trimmed = trimAndCanonicalize(text, &trim_buf);
    if (trimmed.len == 0) return true;

    if (matchesKnownBad(trimmed)) return true;

    // Token-level loop checks operate on the original text so we keep word
    // boundaries intact (the canonicalizer collapsed punctuation but tokens
    // are easier to reason about by splitting on whitespace).
    if (hasTokenLoop(trimmed, max_token_repeat)) return true;
    if (hasTrigramLoop(trimmed, max_trigram_repeat)) return true;

    return false;
}

/// Lowercase, strip ASCII punctuation, collapse internal whitespace into
/// single spaces, trim leading/trailing whitespace. Writes into `buf` and
/// returns a slice of the prefix actually used. Truncates silently when the
/// input would overflow the buffer — fine because all subsequent checks
/// operate on the canonicalized prefix.
fn trimAndCanonicalize(text: []const u8, buf: []u8) []const u8 {
    std.debug.assert(buf.len > 0);
    var out_len: usize = 0;
    var prev_space = true; // suppress leading whitespace
    for (text) |raw| {
        if (out_len == buf.len) break;
        const lower = std.ascii.toLower(raw);
        const is_alnum = std.ascii.isAlphanumeric(lower);
        if (is_alnum) {
            buf[out_len] = lower;
            out_len += 1;
            prev_space = false;
        } else if (!prev_space) {
            buf[out_len] = ' ';
            out_len += 1;
            prev_space = true;
        }
    }
    // strip trailing space introduced by canonicalization
    while (out_len > 0 and buf[out_len - 1] == ' ') : (out_len -= 1) {}
    return buf[0..out_len];
}

fn matchesKnownBad(canonical: []const u8) bool {
    for (known_bad) |needle| {
        if (std.mem.eql(u8, canonical, needle)) return true;
    }
    return false;
}

fn hasTokenLoop(canonical: []const u8, threshold: usize) bool {
    std.debug.assert(threshold >= 2);
    var iter = std.mem.splitScalar(u8, canonical, ' ');
    var prev: ?[]const u8 = null;
    var run: usize = 1;
    while (iter.next()) |tok| {
        if (tok.len == 0) continue;
        if (prev) |p| {
            if (std.mem.eql(u8, tok, p)) {
                run += 1;
                if (run >= threshold) return true;
            } else {
                run = 1;
            }
        }
        prev = tok;
    }
    return false;
}

fn hasTrigramLoop(canonical: []const u8, threshold: usize) bool {
    std.debug.assert(threshold >= 2);

    // Cap analyzed token count to bound work on pathologically long input.
    const max_tokens: usize = 512;
    var tokens: [max_tokens][]const u8 = undefined;
    var n: usize = 0;

    var iter = std.mem.splitScalar(u8, canonical, ' ');
    while (iter.next()) |tok| {
        if (tok.len == 0) continue;
        if (n == max_tokens) break;
        tokens[n] = tok;
        n += 1;
    }

    if (n < 3 * threshold) return false;

    // Fixed-size O(n^2 / 9) comparison: for each starting position i, count
    // how many times the trigram (tokens[i], tokens[i+1], tokens[i+2])
    // appears at later non-overlapping positions. With n capped at 512 this
    // is at most ~30k comparisons.
    var i: usize = 0;
    while (i + 2 < n) : (i += 1) {
        const t0 = tokens[i];
        const t1 = tokens[i + 1];
        const t2 = tokens[i + 2];
        var count: usize = 1;
        var j: usize = i + 3;
        while (j + 2 < n) : (j += 1) {
            if (std.mem.eql(u8, tokens[j], t0) and
                std.mem.eql(u8, tokens[j + 1], t1) and
                std.mem.eql(u8, tokens[j + 2], t2))
            {
                count += 1;
                if (count >= threshold) return true;
                j += 2; // skip past the matched window
            }
        }
    }
    return false;
}

test "blank and whitespace are nonsense" {
    try std.testing.expect(isNonsense(""));
    try std.testing.expect(isNonsense("   "));
    try std.testing.expect(isNonsense("\n\t .. "));
}

test "known-bad list" {
    try std.testing.expect(isNonsense("Thanks for watching!"));
    try std.testing.expect(isNonsense("THANKS FOR WATCHING."));
    try std.testing.expect(isNonsense(" thanks   for   watching "));
    try std.testing.expect(isNonsense("Subtitles by the Amara.org community"));
    try std.testing.expect(isNonsense("[Music]"));
    try std.testing.expect(isNonsense("you"));
}

test "real sentences are not nonsense" {
    try std.testing.expect(!isNonsense("Hello, please open the file in the editor."));
    try std.testing.expect(!isNonsense("The quick brown fox jumps over the lazy dog."));
    try std.testing.expect(!isNonsense("Let me think about this for a second."));
}

test "token loop is nonsense" {
    try std.testing.expect(isNonsense("okay okay okay okay okay"));
    try std.testing.expect(isNonsense("yes yes yes yes yes please"));
    try std.testing.expect(!isNonsense("yes yes please"));
}

test "trigram loop is nonsense" {
    try std.testing.expect(isNonsense("thanks for watching thanks for watching thanks for watching"));
    try std.testing.expect(!isNonsense("thanks for watching this short clip"));
}
